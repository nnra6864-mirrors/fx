//! Carries out `src/core/recovery/` plans for one model request.
//!
//! The recovery module decides and this file acts. The turn loop reports what
//! happened to the request (`start`, `failed`, `responding`, `succeeded`,
//! `cancel`), and each report becomes one `recovery.step` call on the boot
//! clock. Its plan's status goes to the host, and its send tells the loop to
//! resend. Between sends `waitForSend` delivers `tick` once a second and polls
//! the cancel flag every 25 ms. While a send is on the wire, a ticker keeps the
//! retrying status counting: a thread in threaded builds, or the transport's
//! cooperative pulse in single-threaded ones.
//!
//! The module's state is not thread-safe, so every `step` call holds `mutex`.
//! Statuses are pushed under the same lock, so the host sees them in the order
//! the module produced them.
//!
//! This change does not persist `Plan.save`: fx's recovery checkpoint still
//! owns resume. `Plan.finish` has no record to delete for the same reason.
//!
//! The module retries every transient failure for as long as it lasts, and fx
//! adds no limit of its own: only Esc ends a request whose failures keep
//! coming.

const std = @import("std");
const builtin = @import("builtin");
const recovery = @import("../../recovery/recovery.zig");
const types = @import("../../shared/types.zig");
const io_mod = @import("../../shared/io.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const agent_stream_provider = @import("../stream_provider.zig");
const runtime_deps = @import("deps.zig");

pub const Failure = recovery.Failure;
pub const Send = recovery.Send;

/// The module expects `tick` once a second from `start` until `finish`.
const tick_ms: u64 = 1_000;
/// How often a wait checks for Esc.
const cancel_poll_ms: u64 = 25;
/// Tests run the ticker thread fast; the module still sees the virtual clock.
const ticker_interval_ns: i96 = if (builtin.is_test) 5 * std.time.ns_per_ms else tick_ms * std.time.ns_per_ms;
/// The virtual boot clock tests start at.
const test_epoch_ms: u64 = 1_000_000;

/// The module's failure kind for each of fx's transient causes, and null for
/// a cause that never reaches it. Every failure site in the turn loop reports
/// through this.
pub fn failureKind(cause: types.ModelRecoveryCause) ?Failure.Kind {
    return switch (cause) {
        // A path that is down sent nothing.
        .connectivity_lost, .system_resumed => .offline,
        // A connection that broke after connecting may have sent the request.
        .network_interrupted, .response_interrupted, .provider_stream_timeout => .dropped,
        .provider_unavailable => .server,
        .rate_limited => .rate_limited,
        .authentication, .request_limit_reached, .compaction_prepared => null,
    };
}

pub const RequestRecovery = struct {
    deps: *const runtime_deps.AgentRuntimeDeps,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
    /// Set by the host when the user answers a request that waits for them,
    /// for example with Enter. Null on hosts that cannot ask the user, which
    /// end the turn instead (`canAskUser`).
    continue_flag: ?*std.atomic.Value(bool) = null,
    /// Off in tests unless a test exercises the thread itself.
    ticker_enabled: bool = !builtin.is_test,

    mutex: std.Io.Mutex = .init,
    // Everything below is guarded by `mutex`.
    state: recovery.State = .{},
    /// Sends the module asked for, including the first: its attempt count.
    attempts: u16 = 0,
    /// How the latest send goes out.
    send: Send = .{},
    /// The host showed a status for this request, so a success reports
    /// `recovered`.
    recovery_shown: bool = false,
    /// `responding` was delivered for the current send.
    responded: bool = false,
    /// The host's status line holds a module status right now.
    host_showing: bool = false,
    ticker: ?std.Thread = null,
    ticker_stop: bool = false,
    ticker_wake: std.Io.Condition = .init,
    /// Single-threaded builds tick from the transport's cooperative pulse.
    inner_pulse: ?agent_stream_provider.CooperativePulse = null,
    next_beat_ms: u64 = 0,
    /// Tests run on this virtual boot clock, so a 30-second wait takes no
    /// real time.
    virtual_now_ms: std.atomic.Value(u64) = .init(test_epoch_ms),

    pub fn init(
        deps: *const runtime_deps.AgentRuntimeDeps,
        cancel_flag: *std.atomic.Value(bool),
        trace_ctx: debug_trace.TraceContext,
    ) RequestRecovery {
        return .{ .deps = deps, .cancel_flag = cancel_flag, .trace_ctx = trace_ctx };
    }

    /// Every exit of the request ends here, so a module status the host still
    /// shows is cleared and a retry warning never outlives its request
    /// (`tests/tla/recovery/Recovery.tla` StatusHonest).
    pub fn deinit(self: *RequestRecovery) void {
        self.endSend();
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.clearShownLocked();
    }

    /// A new request. `fast` is the request's Fast selection, which makes
    /// "retrying without Fast" a real option.
    pub fn start(self: *RequestRecovery, fast: bool) !void {
        if (self.deps.begin_route_recovery_request) |begin| begin(self.deps.ctx);
        _ = try self.event(.{ .start = .{ .fast = fast } });
    }

    /// Reports a failed send. Returns the send the module asks for at once,
    /// which only compaction does. Any other kind makes the module wait or
    /// ask the user; the caller then calls `waitForSend`.
    pub fn failed(self: *RequestRecovery, failure: Failure) !?Send {
        // An answer given before this failure answers nothing.
        if (self.continue_flag) |flag| flag.store(false, .seq_cst);
        return self.event(.{ .failed = failure });
    }

    /// Whether the host can answer a request that needs the user. Hosts that
    /// cannot keep fx's own handling and end the turn.
    pub fn canAskUser(self: *const RequestRecovery) bool {
        return self.continue_flag != null;
    }

    /// The user answered a request that waits for them, other than through
    /// the continue flag, for example with a picker choice. Returns the
    /// module's send.
    pub fn userContinue(self: *RequestRecovery) !?Send {
        return self.event(.user_continue);
    }

    /// Waits for the module's next send, delivering `tick` once a second and
    /// `user_continue` when the continue flag is set. Returns null when the
    /// cancel flag is set; the caller then runs its cancel path, which calls
    /// `cancel`.
    pub fn waitForSend(self: *RequestRecovery) !?Send {
        var next_tick_ms = self.nowMs() +| tick_ms;
        while (true) {
            if (self.cancel_flag.load(.seq_cst)) return null;
            if (self.continue_flag) |flag| if (flag.swap(false, .seq_cst)) {
                if (try self.event(.user_continue)) |send| return send;
            };
            const now_ms = self.nowMs();
            if (now_ms < next_tick_ms) {
                self.sleepMs(@min(cancel_poll_ms, next_tick_ms - now_ms));
                continue;
            }
            next_tick_ms = now_ms +| tick_ms;
            if (try self.event(.tick)) |send| return send;
        }
    }

    /// The first output of the current send arrived. Called from the
    /// transport's event callback, which cannot fail, so publication errors
    /// are traced. The check and the step share one hold of `mutex`, because
    /// `stepLocked` resets `responded` for each new send.
    pub fn responding(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.responded) return;
        self.responded = true;
        _ = self.stepLocked(.responding) catch |err| {
            debug_trace.logf("recovery", "responding status publication failed err={s}", .{@errorName(err)});
        };
    }

    /// The response arrived complete. After a request that showed a status,
    /// hosts that report a result get a `recovered` status, which carries
    /// only the attempt that succeeded.
    pub fn succeeded(self: *RequestRecovery) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        _ = try self.stepLocked(.succeeded);
        if (!self.recovery_shown) return;
        self.recovery_shown = false;
        self.host_showing = false;
        try self.deps.push_route_recovery_status(self.deps.ctx, .{
            .kind = .recovered,
            .attempt = self.attempts,
        });
    }

    /// Esc or quitting: ends the request and clears its status.
    pub fn cancel(self: *RequestRecovery) !void {
        _ = try self.event(.user_cancel);
    }

    /// fx's own terminal status replaces the module's on the host. Terminal
    /// failures keep fx's handling and wording in this change. The terminal
    /// status is the request's result, so nothing reports over it.
    pub fn replaceStatus(self: *RequestRecovery, status: types.RouteRecoveryStatus) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.host_showing = false;
        self.recovery_shown = false;
        try self.deps.push_route_recovery_status(self.deps.ctx, status);
    }

    /// The request ended on an error with no success, cancel, or terminal
    /// status of fx's own, for example an HTTP error after a retry or a
    /// resend that never reached the transport. After the host showed a
    /// status, hosts that report a result get `failed`, which also clears the
    /// TUI's status line; otherwise a module status still shown is cleared.
    pub fn endWithError(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.recovery_shown) return self.clearShownLocked();
        self.recovery_shown = false;
        self.host_showing = false;
        self.deps.push_route_recovery_status(self.deps.ctx, .{
            .kind = .failed,
            .attempt = self.attempts,
        }) catch |err| {
            debug_trace.logf("recovery", "failed status publication failed err={s}", .{@errorName(err)});
        };
    }

    fn clearShownLocked(self: *RequestRecovery) void {
        if (!self.host_showing) return;
        self.host_showing = false;
        self.deps.push_event(self.deps.ctx, .clear_route_recovery_status) catch |err| {
            debug_trace.logf("recovery", "stale status clear failed err={s}", .{@errorName(err)});
        };
    }

    /// Sends so far, including the first.
    pub fn attempt(self: *RequestRecovery) u16 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.attempts;
    }

    /// Starts the ticker that keeps the retrying status counting while a
    /// send is on the wire.
    ///
    /// Why calling the host from this second thread is safe. The ticker only
    /// steps `tick` under `mutex`, and while a send is out `tick` can only
    /// refresh the `retrying` status the turn loop already published for it
    /// (`recovery.zig` `onTick`, phase `sending`): no clear, no send. Until
    /// `endSend`, every other route status for the request also comes from
    /// this file under `mutex` (`responding`'s clear), and fx's terminal
    /// statuses go through `replaceStatus` only after the stream returns.
    /// The turn loop keeps calling the host's other callbacks meanwhile, and
    /// each host takes a status from another thread safely:
    ///
    /// - TUI (`app_callbacks.agentPushRouteRecoveryStatus`): copies the event
    ///   with `std.heap.c_allocator` and queues it under `worker_mutex`.
    /// - ACP (`AcpContext.sendModelRecoveryStatus`): formats into a local
    ///   writer and writes one frame under `jsonrpc.Writer.mutex`; libfx's
    ///   writer callback queues under its own mutex. The allocator is the
    ///   server loop's (`processAllocator()` for `fx acp`, `c_allocator` for
    ///   libfx, and `state.alloc` for subagent children), never an arena, and
    ///   the loop thread already shares it with the prompt thread.
    /// - `fx ask` (`pushRouteRecoveryStatus`): writes only its two recovery
    ///   fields. During a send their only other writer is the clear from
    ///   `responding`, under `mutex`, and the result reads them after the
    ///   ticker is joined. It prints only when the kind changes, which a
    ///   `retrying` refresh never does.
    /// - Subagent children and the default deps drop the status.
    ///
    /// Single-threaded builds, such as wasm, tick from the transport's
    /// cooperative pulse on the turn loop's own thread instead.
    pub fn beginSend(self: *RequestRecovery) void {
        if (comptime builtin.single_threaded) {
            self.next_beat_ms = self.nowMs() +| tick_ms;
            return;
        }
        if (!self.ticker_enabled or self.ticker != null) return;
        self.ticker_stop = false;
        self.ticker = std.Thread.spawn(.{}, tickerMain, .{self}) catch |err| {
            // The status then refreshes at the next event instead.
            debug_trace.logf("recovery", "status ticker unavailable err={s}", .{@errorName(err)});
            return;
        };
    }

    pub fn endSend(self: *RequestRecovery) void {
        const thread = self.ticker orelse return;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.ticker_stop = true;
        self.ticker_wake.signal(io);
        self.mutex.unlock(io);
        thread.join();
        self.ticker = null;
    }

    /// Single-threaded builds have no ticker thread, so the transport's
    /// cooperative pulse delivers the in-flight `tick` instead. Threaded
    /// builds get `inner` back unchanged.
    pub fn cooperativePulse(
        self: *RequestRecovery,
        inner: ?agent_stream_provider.CooperativePulse,
    ) ?agent_stream_provider.CooperativePulse {
        if (comptime !builtin.single_threaded) return inner;
        self.inner_pulse = inner;
        return .{ .ctx = self, .run = pulseBeat };
    }

    fn pulseBeat(raw: *anyopaque) anyerror!void {
        const self: *RequestRecovery = @ptrCast(@alignCast(raw));
        const now_ms = self.nowMs();
        if (now_ms >= self.next_beat_ms) {
            self.next_beat_ms = now_ms +| tick_ms;
            _ = self.event(.tick) catch |err| {
                debug_trace.logf("recovery", "status tick publication failed err={s}", .{@errorName(err)});
            };
        }
        if (self.inner_pulse) |inner| try inner.pulse();
    }

    fn tickerMain(self: *RequestRecovery) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.ticker_stop) {
            self.ticker_wake.waitTimeout(io, &self.mutex, .{ .duration = .{
                .raw = .fromNanoseconds(ticker_interval_ns),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
            if (self.ticker_stop) return;
            _ = self.stepLocked(.tick) catch |err| {
                debug_trace.logf("recovery", "status tick publication failed err={s}", .{@errorName(err)});
            };
        }
    }

    fn event(self: *RequestRecovery, value: recovery.Event) !?Send {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.stepLocked(value);
    }

    /// Steps the module and carries out its plan in field order. Returns
    /// the plan's send, which the caller carries out.
    fn stepLocked(self: *RequestRecovery, value: recovery.Event) !?Send {
        const now_ms = self.nowMs();
        const plan = recovery.step(&self.state, value, now_ms);
        if (plan.send) |send| {
            self.attempts +|= 1;
            self.send = send;
            self.responded = false;
        }
        if (plan.send != null or plan.status != null or plan.finish != null) {
            debug_trace.eventf("recovery", "step", self.trace_ctx, "event={s} now_ms={d} attempt={d} send={s} no_fast={} status={s} finish={s}", .{
                @tagName(value),
                now_ms,
                self.attempts,
                if (plan.send != null) "true" else "false",
                self.send.no_fast,
                if (plan.status) |status| @tagName(status.kind) else "none",
                if (plan.finish) |finish| @tagName(finish) else "none",
            });
        }
        if (plan.status) |status| try self.showLocked(status);
        // A cancelled request recovered nothing.
        if (plan.finish) |finish| if (finish == .cancelled) {
            self.recovery_shown = false;
        };
        return plan.send;
    }

    fn showLocked(self: *RequestRecovery, status: recovery.Status) !void {
        if (types.RouteRecoveryStatus.fromRecovery(status, self.attempts)) |shown| {
            self.recovery_shown = true;
            self.host_showing = true;
            try self.deps.push_route_recovery_status(self.deps.ctx, shown);
        } else {
            self.host_showing = false;
            try self.deps.push_event(self.deps.ctx, .clear_route_recovery_status);
        }
    }

    fn nowMs(self: *RequestRecovery) u64 {
        if (comptime builtin.is_test) return self.virtual_now_ms.load(.seq_cst);
        const ns = std.Io.Clock.Timestamp.now(io_mod.getIo(), .boot).raw.toNanoseconds();
        return if (ns <= 0) 0 else @intCast(@divTrunc(ns, std.time.ns_per_ms));
    }

    fn sleepMs(self: *RequestRecovery, ms: u64) void {
        if (comptime builtin.is_test) {
            _ = self.virtual_now_ms.fetchAdd(ms, .seq_cst);
            return;
        }
        io_mod.getIo().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
    }
};

// Tests.

const support = @import("tests/support.zig");

fn statusTexts(fake: *const support.FakeAgentRuntimeDeps, buf: [][]const u8) [][]const u8 {
    var count: usize = 0;
    for (fake.route_recovery_statuses.items) |*status| {
        if (count == buf.len) break;
        buf[count] = status.text.slice();
        count += 1;
    }
    return buf[0..count];
}

test "a transient failure waits with the module's status, then resends" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_statuses.items.len);

    _ = try request.failed(.{ .kind = .dropped });
    const waiting = fake.route_recovery_statuses.items[0];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.waiting, waiting.kind);
    try std.testing.expectEqualStrings("Connection lost · next try in 1s · attempt 1 · 0s", waiting.text.slice());
    try std.testing.expectEqual(@as(usize, 1), waiting.attempt);

    const send = (try request.waitForSend()).?;
    try std.testing.expectEqual(Send{}, send);
    try std.testing.expectEqual(@as(u16, 2), request.attempt());
    const retrying = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.retrying, retrying.kind);
    try std.testing.expect(std.mem.startsWith(u8, retrying.text.slice(), "Connection lost · retrying · attempt 2 · "));
}

test "the first output clears the status and success reports the recovery" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    _ = try request.failed(.{ .kind = .server });
    _ = (try request.waitForSend()).?;
    const shown = fake.route_recovery_statuses.items.len;

    request.responding();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);
    // One `responding` per send.
    request.responding();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);

    try request.succeeded();
    try std.testing.expectEqual(shown + 1, fake.route_recovery_statuses.items.len);
    const recovered = fake.route_recovery_statuses.items[shown];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.recovered, recovered.kind);
    try std.testing.expectEqual(@as(usize, 2), recovered.attempt);
    // `recovered` reports the attempt only.
    try std.testing.expectEqual(@as(usize, 0), recovered.text.len);
}

test "responding from two threads at once delivers one responding" {
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    for (0..50) |_| {
        _ = try request.failed(.{ .kind = .dropped });
        _ = (try request.waitForSend()).?;
        const clears = fake.route_recovery_clear_count;
        const racer = try std.Thread.spawn(.{}, RequestRecovery.responding, .{&request});
        request.responding();
        racer.join();
        // The retrying status clears exactly once per send.
        try std.testing.expectEqual(clears + 1, fake.route_recovery_clear_count);
    }
}

test "a healthy request shows nothing and reports no recovery" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(true);
    request.responding();
    try request.succeeded();
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_statuses.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_clear_count);
}

test "Esc during a wait stops waiting and cancel clears the status" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    var cancel_flag = std.atomic.Value(bool).init(false);
    fake.cancel_on_auto_retry_status = &cancel_flag;
    const deps = fake.deps();
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    _ = try request.failed(.{ .kind = .rate_limited, .retry_after_ms = 20_000 });
    try std.testing.expect(cancel_flag.load(.seq_cst));
    try std.testing.expect(try request.waitForSend() == null);
    try std.testing.expectEqual(@as(u16, 1), request.attempt());

    try request.cancel();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);
    // A cancelled request ignores later events.
    try request.succeeded();
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_statuses.items.len);
}

test "three server errors in a row with Fast on resend without Fast" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(true);
    for (0..2) |_| {
        _ = try request.failed(.{ .kind = .server });
        try std.testing.expectEqual(Send{}, (try request.waitForSend()).?);
    }
    _ = try request.failed(.{ .kind = .server });
    const send = (try request.waitForSend()).?;
    try std.testing.expect(send.no_fast);
    try std.testing.expect(request.send.no_fast);
    const retrying = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, retrying.text.slice(), "Gateway error · retrying without Fast · attempt 4 · "));

    // The rest of the request stays off Fast.
    _ = try request.failed(.{ .kind = .dropped });
    try std.testing.expect((try request.waitForSend()).?.no_fast);
}

test "a server's Retry-After is honored up to the 30 second ceiling" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    _ = try request.failed(.{ .kind = .server, .retry_after_ms = 3_000 });
    try std.testing.expectEqualStrings("Gateway error · next try in 3s · attempt 1 · 0s", fake.route_recovery_statuses.items[0].text.slice());
    var started_ms = request.nowMs();
    _ = (try request.waitForSend()).?;
    try std.testing.expectEqual(@as(u64, 3_000), request.nowMs() - started_ms);

    _ = try request.failed(.{ .kind = .server, .retry_after_ms = 120_000 });
    try std.testing.expect(std.mem.startsWith(u8, fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1].text.slice(), "Gateway error · next try in 30s · attempt 2"));
    started_ms = request.nowMs();
    _ = (try request.waitForSend()).?;
    try std.testing.expectEqual(@as(u64, 30_000), request.nowMs() - started_ms);
}

test "the countdown refreshes once a second while waiting" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    _ = try request.failed(.{ .kind = .rate_limited, .retry_after_ms = 3_000 });
    _ = (try request.waitForSend()).?;
    var buf: [8][]const u8 = undefined;
    const texts = statusTexts(&fake, &buf);
    try std.testing.expectEqual(@as(usize, 4), texts.len);
    try std.testing.expectEqualStrings("Rate limited · next try in 3s · attempt 1 · 0s", texts[0]);
    try std.testing.expectEqualStrings("Rate limited · next try in 2s · attempt 1 · 1s", texts[1]);
    try std.testing.expectEqualStrings("Rate limited · next try in 1s · attempt 1 · 2s", texts[2]);
    try std.testing.expectEqualStrings("Rate limited · retrying · attempt 2 · 3s", texts[3]);
}

test "the in-flight ticker keeps the retrying status counting" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    request.ticker_enabled = true;
    defer request.deinit();

    try request.start(false);
    _ = try request.failed(.{ .kind = .dropped });
    _ = (try request.waitForSend()).?;
    const io = io_mod.getIo();
    request.mutex.lockUncancelable(io);
    const before = fake.route_recovery_statuses.items.len;
    request.mutex.unlock(io);

    request.beginSend();
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    _ = request.virtual_now_ms.fetchAdd(1_000, .seq_cst);
    var waited_ms: usize = 0;
    while (waited_ms < 2_000) : (waited_ms += 5) {
        request.mutex.lockUncancelable(io);
        const count = fake.route_recovery_statuses.items.len;
        request.mutex.unlock(io);
        if (count > before) break;
        io.sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .awake) catch {};
    }
    request.endSend();

    try std.testing.expectEqual(before + 1, fake.route_recovery_statuses.items.len);
    const refreshed = fake.route_recovery_statuses.items[before];
    try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.retrying, refreshed.kind);
    try std.testing.expectEqualStrings("Connection lost · retrying · attempt 2 · 2s", refreshed.text.slice());
}

test "start tells the host a new request begins" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    var deps = fake.deps();
    const Host = struct {
        var begun: usize = 0;
        fn begin(_: *anyopaque) void {
            begun += 1;
        }
    };
    Host.begun = 0;
    deps.begin_route_recovery_request = Host.begin;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var request = RequestRecovery.init(&deps, &cancel_flag, .{});
    defer request.deinit();

    try request.start(false);
    try std.testing.expectEqual(@as(usize, 1), Host.begun);
}

test "an error after a status reports failed and every exit clears the status" {
    var fake = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer fake.deinit();
    const deps = fake.deps();
    var cancel_flag = std.atomic.Value(bool).init(false);

    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        try request.start(false);
        _ = try request.failed(.{ .kind = .server });
        _ = (try request.waitForSend()).?;
        request.endWithError();
        const last = fake.route_recovery_statuses.items[fake.route_recovery_statuses.items.len - 1];
        try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.failed, last.kind);
        try std.testing.expectEqual(@as(usize, 2), last.attempt);
    }
    // `failed` already ended the status, so the exit adds no clear.
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_clear_count);

    const shown = fake.route_recovery_statuses.items.len;
    {
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        try request.start(false);
        _ = try request.failed(.{ .kind = .dropped });
        // fx's terminal status reports the result itself.
        try request.replaceStatus(.{ .kind = .terminal_provider_error, .attempt = 1 });
        request.endWithError();
    }
    try std.testing.expectEqual(shown + 2, fake.route_recovery_statuses.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.route_recovery_clear_count);

    {
        // A request that leaves without an error, such as a compaction handoff,
        // clears the status it still shows.
        var request = RequestRecovery.init(&deps, &cancel_flag, .{});
        defer request.deinit();
        try request.start(false);
        _ = try request.failed(.{ .kind = .dropped });
    }
    try std.testing.expectEqual(@as(usize, 1), fake.route_recovery_clear_count);
}
