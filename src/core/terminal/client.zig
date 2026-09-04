const std = @import("std");
const builtin = @import("builtin");
const host_target = @import("../hosts/target.zig");
const contracts = @import("contracts.zig");
const protocol = @import("protocol.zig");
const host = @import("host.zig");
const policy = @import("host_policy.zig");
const io_mod = @import("../shared/io.zig");
const self_exe = @import("../shared/self_exe.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const process_provider_mod = @import(
    "../execution/process_provider.zig",
);
const ui_projection = @import("ui_projection.zig");

const Allocator = std.mem.Allocator;
const connect_deadline_ms: i64 = 2_000;
const handshake_deadline_ms: i64 = 5_000;
const max_exit_owners: usize = 64;
const owner_exit_timeout_ms: i64 = 350;
pub const AdmissionError =
    contracts.RequestValidationError ||
    Allocator.Error ||
    error{
        DuplicateCorrelation,
        QueueFull,
        RuntimeStopping,
        TerminalUnavailable,
        InvalidCorrelationId,
    };

pub const CompletionKind = enum {
    response,
    cancelled,
    disconnected,
    unavailable,
};

pub const Completion = struct {
    kind: CompletionKind,
    correlation_id: ?contracts.CorrelationId = null,
    incompatibility: ?contracts.ProtocolIncompatibility = null,
    missing_capabilities: u64 = 0,
    frame: ?protocol.DecodedFrame = null,

    pub fn is_missing_capability(
        self: Completion,
        capability: u64,
    ) bool {
        return self.kind == .unavailable and
            self.missing_capabilities & capability != 0;
    }

    pub fn deinit(self: *Completion) void {
        if (self.frame) |*frame| frame.deinit();
        self.* = undefined;
    }
};

inline fn failCompletion(err: anytype) @TypeOf(err)!Completion {
    return @errorCast(failCompletionDynamic(err));
}

noinline fn failCompletionDynamic(err: anyerror) anyerror!Completion {
    return err;
}

test "completion failure writer preserves exact error type and identity" {
    const failure = failCompletion(error.InvalidHostMessage);
    try std.testing.expect(@TypeOf(failure) == error{InvalidHostMessage}!Completion);
    try std.testing.expectError(error.InvalidHostMessage, failure);
}

const Intent = struct {
    correlation_id: contracts.CorrelationId,
    request: contracts.OwnedActionRequest,

    fn deinit(self: *Intent, alloc: Allocator) void {
        self.request.deinit(alloc);
        self.* = undefined;
    }
};

const CompletionSink = struct {
    values: [policy.outcome_capacity]?Completion = @splat(null),
    len: usize = 0,

    fn push(self: *CompletionSink, completion: Completion) void {
        std.debug.assert(completion.correlation_id != null);
        std.debug.assert(self.len < self.values.len);
        self.values[self.len] = completion;
        self.len += 1;
    }

    fn take(self: *CompletionSink) ?Completion {
        return self.removeAt(0);
    }

    fn takeForCorrelation(
        self: *CompletionSink,
        correlation_id: contracts.CorrelationId,
    ) ?Completion {
        for (self.values[0..self.len], 0..) |entry, index| {
            const completion = entry.?;
            const candidate = completion.correlation_id orelse continue;
            if (candidate.value == correlation_id.value) {
                return self.removeAt(index);
            }
        }
        return null;
    }

    fn removeAt(self: *CompletionSink, index: usize) ?Completion {
        if (index >= self.len) return null;
        const completion = self.values[index].?;
        var shift_index = index;
        while (shift_index + 1 < self.len) : (shift_index += 1) {
            self.values[shift_index] = self.values[shift_index + 1];
        }
        self.len -= 1;
        self.values[self.len] = null;
        return completion;
    }
};

pub const Runtime = struct {
    process_provider: process_provider_mod.Provider =
        process_provider_mod.unavailable_provider,
    mutex: std.Io.Mutex = .init,
    completions: CompletionSink = .{},
    live_correlations: policy.PendingRequests = .{},
    alloc: ?Allocator = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    active: [policy.outcome_capacity]?*RequestWorker = @splat(null),
    requests: std.Io.Group = .init,
    exit_owners: [max_exit_owners]?contracts.SessionExitAuthority = @splat(null),
    next_correlation_value: u64 = 1,
    projection: ui_projection.Store = .{},

    pub fn nextCorrelationId(self: *Runtime) contracts.CorrelationId {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const result = contracts.CorrelationId{
            .value = self.next_correlation_value,
        };
        self.next_correlation_value +%= 1;
        if (self.next_correlation_value == 0) self.next_correlation_value = 1;
        return result;
    }

    pub fn init(
        process_provider: process_provider_mod.Provider,
    ) Runtime {
        return .{ .process_provider = process_provider };
    }

    pub fn admit(
        self: *Runtime,
        alloc: Allocator,
        correlation_id: contracts.CorrelationId,
        request: contracts.ActionRequest,
    ) AdmissionError!void {
        if (comptime host_target.is_wasm) return error.TerminalUnavailable;
        if (self.stop_requested.load(.acquire)) return error.RuntimeStopping;
        try correlation_id.validate();
        var intent = Intent{
            .correlation_id = correlation_id,
            .request = try contracts.OwnedActionRequest.init(alloc, request),
        };

        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.stop_requested.load(.acquire)) {
            intent.deinit(alloc);
            return error.RuntimeStopping;
        }
        if (self.alloc) |existing| {
            if (existing.ptr != alloc.ptr or existing.vtable != alloc.vtable) {
                intent.deinit(alloc);
                return error.RuntimeStopping;
            }
        } else {
            self.alloc = alloc;
        }
        if (request == .start) {
            if (request.start.persistence) |persistence| {
                if (persistence.exit_proof) |proof| {
                    self.retainOwnerExitLocked(alloc, .{
                        .session_id = persistence.grant.principal.durable_session_id,
                        .proof = proof,
                    }) catch |err| {
                        intent.deinit(alloc);
                        return err;
                    };
                }
            }
        }
        const worker = (self.registerRequestLocked(intent) catch |err| {
            intent.deinit(alloc);
            return err;
        }) orelse return;
        self.submitRequestLocked(zio, worker);
    }

    fn submitRequestLocked(self: *Runtime, zio: std.Io, worker: *RequestWorker) void {
        const submitted: std.Io.ConcurrentError!void = if (takeoverWorkerStartFailureRequested(worker))
            error.ConcurrencyUnavailable
        else
            self.requests.concurrent(zio, RequestWorker.run, .{worker});
        submitted catch {
            self.finishActiveLocked(worker, .{ .kind = .disconnected, .correlation_id = worker.intent.correlation_id });
            worker.intent.deinit(self.alloc.?);
            self.alloc.?.destroy(worker);
        };
    }

    pub fn cancel(
        self: *Runtime,
        correlation_id: contracts.CorrelationId,
    ) bool {
        correlation_id.validate() catch return false;
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (self.active) |entry| {
            const worker = entry orelse continue;
            if (worker.intent.correlation_id.value != correlation_id.value) {
                continue;
            }
            worker.cancelled.store(true, .release);
            return true;
        }
        return false;
    }

    pub fn takeCompletionFor(
        self: *Runtime,
        correlation_id: contracts.CorrelationId,
    ) ?Completion {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const completion = self.completions.takeForCorrelation(correlation_id) orelse
            return null;
        self.consumeCompletionLocked(completion);
        return completion;
    }

    pub fn terminalProjection(
        self: *Runtime,
        alloc: Allocator,
    ) Allocator.Error!ui_projection.Snapshot {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return self.projection.snapshot(alloc);
    }

    pub fn clearTerminalProjection(self: *Runtime) bool {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        const alloc = self.alloc orelse return false;
        return self.projection.clear(alloc);
    }

    /// Retains a saved session's bounded lifecycle capability, not its jobs or
    /// history. The runtime owns the copied ID until deinit.
    pub fn retainOwnerExit(self: *Runtime, alloc: Allocator, authority: contracts.SessionExitAuthority) AdmissionError!void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.stop_requested.load(.acquire)) return error.RuntimeStopping;
        if (self.alloc) |existing| {
            if (existing.ptr != alloc.ptr or existing.vtable != alloc.vtable) return error.RuntimeStopping;
        } else self.alloc = alloc;
        try self.retainOwnerExitLocked(alloc, authority);
    }

    fn retainOwnerExitLocked(self: *Runtime, alloc: Allocator, authority: contracts.SessionExitAuthority) AdmissionError!void {
        try authority.validate();
        var vacant: ?usize = null;
        for (self.exit_owners, 0..) |entry, index| {
            const existing = entry orelse {
                vacant = vacant orelse index;
                continue;
            };
            if (!std.mem.eql(u8, existing.session_id, authority.session_id)) continue;
            if (!std.crypto.timing_safe.eql([32]u8, existing.proof.bytes, authority.proof.bytes)) return error.TerminalUnavailable;
            return;
        }
        const index = vacant orelse return error.QueueFull;
        self.exit_owners[index] = .{
            .session_id = try alloc.dupe(u8, authority.session_id),
            .proof = authority.proof,
        };
    }

    /// Seals admission and joins request I/O before a caller joins workers
    /// waiting for those requests. Hosted jobs retain their separate lifetime.
    pub fn stopRequests(self: *Runtime) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        self.stop_requested.store(true, .release);
        self.mutex.unlock(zio);
        self.requests.cancel(zio);
        for (self.active) |entry| std.debug.assert(entry == null);
    }

    /// Explicit app exit stops hosted jobs. Ordinary transport deinit does not.
    pub fn shutdownOwners(self: *Runtime) void {
        self.stopRequests();
        const alloc = self.alloc orelse return;
        const zio = io_mod.getIo();
        const deadline = io_mod.milliTimestamp() + owner_exit_timeout_ms;
        const Event = union(enum) { owner: void, deadline: void };
        var events: [max_exit_owners + 1]Event = undefined;
        var pending: std.Io.Select(Event) = .init(zio, &events);
        defer pending.cancelDiscard();
        var count: usize = 0;
        for (self.exit_owners) |entry| {
            const authority = entry orelse continue;
            pending.concurrent(.owner, closeOwner, .{ self, alloc, authority, deadline }) catch {
                closeOwner(self, alloc, authority, deadline);
                continue;
            };
            count += 1;
        }
        if (count == 0) return;
        pending.concurrent(.deadline, awaitExitDeadline, .{deadline}) catch {
            while (count != 0) : (count -= 1) _ = pending.await() catch return;
            return;
        };
        while (count != 0) {
            switch (pending.await() catch return) {
                .owner => count -= 1,
                .deadline => {
                    debug_trace.logf("terminal_client", "owner exit deadline reached pending={d}", .{count});
                    return;
                },
            }
        }
    }

    pub fn deinit(self: *Runtime) void {
        self.stopRequests();
        const alloc = self.alloc orelse {
            self.resetDrainedState();
            return;
        };
        while (self.completions.take()) |completion_value| {
            var completion = completion_value;
            self.consumeCompletionLocked(completion);
            completion.deinit();
        }
        self.projection.deinit(alloc);
        for (&self.exit_owners) |*entry| {
            if (entry.*) |*authority| {
                alloc.free(authority.session_id);
                std.crypto.secureZero(u8, @volatileCast(&authority.proof.bytes));
                entry.* = null;
            }
        }
        self.resetDrainedState();
    }

    noinline fn resetDrainedState(self: *Runtime) void {
        // The drain above already nulls every owned slot. Reset only the
        // observable metadata so teardown does not copy the full runtime.
        self.process_provider = process_provider_mod.unavailable_provider;
        self.mutex = .init;
        self.completions.len = 0;
        self.alloc = null;
        self.stop_requested = .init(false);
        self.requests = .init;
        self.next_correlation_value = 1;
        self.projection = .{};
    }

    fn pushCompletionLocked(self: *Runtime, completion: Completion) void {
        self.completions.push(completion);
    }

    fn consumeCompletionLocked(self: *Runtime, completion: Completion) void {
        const correlation_id = completion.correlation_id orelse return;
        self.releaseCorrelationLocked(correlation_id);
    }

    /// Consumes the intent on acceptance. Allocation failure still publishes
    /// its reserved outcome; a rejected intent remains owned by the caller.
    fn registerRequestLocked(
        self: *Runtime,
        intent: Intent,
    ) error{ DuplicateCorrelation, QueueFull }!?*RequestWorker {
        self.live_correlations.add(intent.correlation_id) catch |err| switch (err) {
            error.DuplicateCorrelation => return error.DuplicateCorrelation,
            error.CapacityExceeded => return error.QueueFull,
        };
        const alloc = self.alloc.?;
        const worker = alloc.create(RequestWorker) catch {
            var accepted = intent;
            accepted.deinit(alloc);
            self.pushCompletionLocked(.{ .kind = .disconnected, .correlation_id = intent.correlation_id });
            return null;
        };
        worker.* = .{ .runtime = self, .intent = intent };
        // Every active worker owns a reserved correlation, so reservation
        // capacity also guarantees an available active slot.
        worker.slot = self.registerWorkerLocked(worker) orelse unreachable;
        return worker;
    }

    fn releaseCorrelationLocked(
        self: *Runtime,
        correlation_id: contracts.CorrelationId,
    ) void {
        std.debug.assert(self.live_correlations.complete(correlation_id));
    }

    fn finishActive(
        self: *Runtime,
        worker: *RequestWorker,
        completion: Completion,
    ) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        self.finishActiveLocked(worker, completion);
    }

    fn finishActiveLocked(self: *Runtime, worker: *RequestWorker, completion: Completion) void {
        std.debug.assert(self.active[worker.slot] == worker);
        self.active[worker.slot] = null;
        self.observeProjectionLocked(worker.intent.request.value, completion);
        self.pushCompletionLocked(completion);
    }

    fn observeProjectionLocked(
        self: *Runtime,
        request: contracts.ActionRequest,
        completion: Completion,
    ) void {
        const frame = completion.frame orelse return;
        const response = switch (frame.message().payload) {
            .response => |value| value,
            else => return,
        };
        self.projection.observe(self.alloc.?, request, response) catch |err| {
            debug_trace.logf(
                "terminal_client",
                "ui projection update failed err={s}",
                .{@errorName(err)},
            );
        };
    }

    fn registerWorkerLocked(self: *Runtime, worker: *RequestWorker) ?usize {
        for (&self.active, 0..) |*entry, index| {
            if (entry.* != null) continue;
            entry.* = worker;
            return index;
        }
        return null;
    }
};

const RequestWorker = struct {
    runtime: *Runtime,
    intent: Intent,
    slot: usize = 0,
    cancelled: std.atomic.Value(bool) = .init(false),
    deadline_ms: ?i64 = null,

    fn run(self: *RequestWorker) void {
        const alloc = self.runtime.alloc.?;
        maybeDelayRequestForTest(self);
        if (self.runtime.stop_requested.load(.acquire) or
            self.cancelled.load(.acquire))
        {
            self.runtime.finishActive(self, .{
                .kind = .cancelled,
                .correlation_id = self.intent.correlation_id,
            });
            self.intent.deinit(alloc);
            alloc.destroy(self);
            return;
        }
        const completion = exchange(self, alloc, &self.intent) catch |err| blk: {
            debug_trace.logf(
                "terminal_client",
                "request failed correlation={d} err={s}",
                .{ self.intent.correlation_id.value, @errorName(err) },
            );
            break :blk Completion{
                .kind = switch (err) {
                    error.ProtocolIncompatible => .unavailable,
                    else => .disconnected,
                },
                .correlation_id = self.intent.correlation_id,
            };
        };
        self.runtime.finishActive(self, completion);
        self.intent.deinit(alloc);
        alloc.destroy(self);
    }
};

fn maybeDelayRequestForTest(worker: *RequestWorker) void {
    const variable = switch (worker.intent.request.value) {
        .start => "FX_TERMINAL_TEST_CLIENT_REQUEST_DELAY_MS",
        .write => |request| if (request.lease == .acquire)
            "FX_TERMINAL_TEST_TAKEOVER_ACQUIRE_DELAY_MS"
        else
            return,
        else => return,
    };
    const value = io_mod.getenv(variable) orelse return;
    var remaining_ms: u64 = @min(
        std.fmt.parseInt(u64, value, 10) catch return,
        30_000,
    );
    while (remaining_ms > 0 and
        !worker.runtime.stop_requested.load(.acquire) and
        !worker.cancelled.load(.acquire))
    {
        const step_ms: u64 = @min(remaining_ms, 10);
        io_mod.sleep(step_ms * std.time.ns_per_ms);
        remaining_ms -= step_ms;
    }
}

fn takeoverWorkerStartFailureRequested(worker: *const RequestWorker) bool {
    const requested = io_mod.getenv("FX_TERMINAL_TEST_TAKEOVER_FAILURE") orelse
        return false;
    if (!std.mem.eql(u8, requested, "worker_start")) return false;
    return switch (worker.intent.request.value) {
        .write => |request| request.lease == .acquire,
        else => false,
    };
}

const Connected = struct {
    stream: std.Io.net.Stream,
    negotiated: contracts.NegotiatedProtocol,
    incompatibility: ?contracts.ProtocolIncompatibility = null,
};

fn awaitExitDeadline(deadline_ms: i64) void {
    const remaining = @max(0, deadline_ms - io_mod.milliTimestamp());
    std.Io.sleep(io_mod.getIo(), .fromMilliseconds(remaining), .awake) catch {};
}

fn closeOwner(runtime: *Runtime, alloc: Allocator, authority: contracts.SessionExitAuthority, deadline_ms: i64) void {
    var intent = Intent{
        .correlation_id = runtime.nextCorrelationId(),
        .request = contracts.OwnedActionRequest.init(alloc, .{ .close_owner = .{
            .authority = authority,
        } }) catch |err| {
            debug_trace.logf("terminal_client", "owner exit allocation failed session={s} err={s}", .{ authority.session_id, @errorName(err) });
            return;
        },
    };
    defer intent.deinit(alloc);
    var worker = RequestWorker{ .runtime = runtime, .intent = intent, .deadline_ms = deadline_ms };
    var completion = exchange(&worker, alloc, &intent) catch |err| {
        if (err != error.FileNotFound) {
            debug_trace.logf("terminal_client", "owner exit failed session={s} err={s}", .{ authority.session_id, @errorName(err) });
        }
        return;
    };
    defer completion.deinit();
    const frame = completion.frame orelse {
        debug_trace.logf("terminal_client", "owner exit unavailable session={s} outcome={s}", .{ authority.session_id, @tagName(completion.kind) });
        return;
    };
    switch (frame.message().payload) {
        .response => |response| switch (response) {
            .success => |success| switch (success) {
                .close_owner => |closed| debug_trace.logf("terminal_client", "owner exit confirmed session={s} stopped={d}", .{ authority.session_id, closed.closed_sessions }),
                else => debug_trace.logf("terminal_client", "owner exit unexpected response session={s}", .{authority.session_id}),
            },
            .failure => |failure| debug_trace.logf("terminal_client", "owner exit rejected session={s} code={s}", .{ authority.session_id, @tagName(failure.code) }),
        },
        else => debug_trace.logf("terminal_client", "owner exit invalid frame session={s}", .{authority.session_id}),
    }
}

fn exchange(
    worker: *RequestWorker,
    alloc: Allocator,
    intent: *const Intent,
) !Completion {
    var connected = try connectAndHandshake(
        alloc,
        worker.runtime.process_provider,
        intent.request.value == .close_owner,
        worker.deadline_ms,
    );
    defer connected.stream.close(io_mod.getIo());
    if (connected.incompatibility) |incompatibility| {
        return .{
            .kind = .unavailable,
            .correlation_id = intent.correlation_id,
            .incompatibility = incompatibility,
        };
    }
    return exchangeConnected(worker, alloc, intent, connected);
}

fn exchangeConnected(
    worker: *RequestWorker,
    alloc: Allocator,
    intent: *const Intent,
    connected: Connected,
) !Completion {
    const required_capabilities = contracts.required_capabilities(
        intent.request.value,
    );
    const missing_capabilities = required_capabilities &
        ~connected.negotiated.capabilities;
    if (missing_capabilities != 0) {
        return .{
            .kind = .unavailable,
            .correlation_id = intent.correlation_id,
            .missing_capabilities = missing_capabilities,
        };
    }

    var write_buffer: [4096]u8 = undefined;
    var writer = connected.stream.writer(io_mod.getIo(), &write_buffer);
    var request_frame = try protocol.encodeFrame(
        alloc,
        connected.negotiated.revision,
        required_capabilities,
        intent.correlation_id,
        .{ .request = intent.request.value },
    );
    defer request_frame.deinit(alloc);
    try protocol.writeFrame(&writer.interface, request_frame);

    while (true) {
        var frame = readCancellableFrame(
            worker,
            alloc,
            connected.stream.socket,
        ) catch |err| switch (err) {
            error.Cancelled => {
                var cancel_frame = try protocol.encodeFrame(
                    alloc,
                    connected.negotiated.revision,
                    0,
                    intent.correlation_id,
                    .cancel,
                );
                defer cancel_frame.deinit(alloc);
                protocol.writeFrame(&writer.interface, cancel_frame) catch {};
                return .{
                    .kind = .cancelled,
                    .correlation_id = intent.correlation_id,
                };
            },
            else => return err,
        };
        const message = frame.message();
        switch (message.payload) {
            .response => {
                const correlation_id = message.envelope.correlation_id.?;
                if (correlation_id.value != intent.correlation_id.value) {
                    frame.deinit();
                    return failCompletion(error.InvalidResponseCorrelation);
                }
                return .{
                    .kind = .response,
                    .correlation_id = correlation_id,
                    .frame = frame,
                };
            },
            .hello, .request, .cancel => {
                frame.deinit();
                return failCompletion(error.InvalidHostMessage);
            },
        }
    }
}

fn readCancellableFrame(
    worker: *RequestWorker,
    alloc: Allocator,
    socket: std.Io.net.Socket,
) !protocol.DecodedFrame {
    var header_bytes: [protocol.header_len]u8 = undefined;
    try receiveCancellable(
        worker,
        socket,
        &header_bytes,
    );
    const header = try protocol.Header.decode(&header_bytes);
    const payload_len: usize = header.envelope.payload_len;
    const total_len = std.math.add(
        usize,
        protocol.header_len,
        payload_len,
    ) catch return error.HostFrameTooLarge;
    var bytes = try alloc.alloc(u8, total_len);
    defer alloc.free(bytes);
    @memcpy(bytes[0..protocol.header_len], &header_bytes);
    try receiveCancellable(
        worker,
        socket,
        bytes[protocol.header_len..],
    );
    return protocol.decodeFrame(alloc, bytes);
}

fn receiveCancellable(
    worker: *RequestWorker,
    socket: std.Io.net.Socket,
    destination: []u8,
) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        if (worker.runtime.stop_requested.load(.acquire) and worker.intent.request.value != .close_owner) {
            return error.RuntimeStopping;
        }
        if (worker.deadline_ms) |deadline| {
            if (io_mod.milliTimestamp() >= deadline) return error.HostConnectTimeout;
        }
        if (worker.cancelled.load(.acquire)) {
            return error.Cancelled;
        }
        const incoming = socket.receiveTimeout(
            io_mod.getIo(),
            destination[offset..],
            .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(50),
            } },
        ) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        if (incoming.data.len == 0) return error.EndOfStream;
        offset += incoming.data.len;
    }
}

fn connectAndHandshake(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    existing_only: bool,
    deadline_ms: ?i64,
) !Connected {
    return connectAndHandshakeOnce(alloc, process_provider, existing_only, deadline_ms) catch |err| switch (err) {
        error.HostClosedBeforeHandshake => connectAndHandshakeOnce(
            alloc,
            process_provider,
            existing_only,
            deadline_ms,
        ),
        else => err,
    };
}

fn connectAndHandshakeOnce(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    existing_only: bool,
    deadline_ms: ?i64,
) !Connected {
    if (!host.isSupported()) return error.TerminalHostUnsupported;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var paths = if (existing_only) try host.Paths.openExisting(alloc, home) else try host.Paths.open(alloc, home);
    defer paths.deinit(alloc);

    var stream = (if (existing_only)
        waitForHost(io_mod.getIo(), paths.endpoint_path, deadline_ms)
    else
        connectOrStart(io_mod.getIo(), alloc, process_provider, &paths)) catch |err| {
        debug_trace.logf(
            "terminal_client",
            "host unavailable err={s}",
            .{@errorName(err)},
        );
        return err;
    };
    errdefer stream.close(io_mod.getIo());

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &write_buffer);
    var hello_frame = try protocol.encodeFrame(
        alloc,
        contracts.compatibility_hello_revision,
        0,
        null,
        .{ .hello = .{
            .range = contracts.local_protocol_range,
            .capabilities = contracts.known_protocol_capabilities,
        } },
    );
    defer hello_frame.deinit(alloc);
    try protocol.writeFrame(&writer.interface, hello_frame);

    var reply = try readHandshakeFrame(alloc, stream.socket, deadline_ms);
    defer reply.deinit();
    const host_hello = switch (reply.message().payload) {
        .hello => |hello| hello,
        else => return error.HandshakeRequired,
    };
    const negotiation = try contracts.negotiate_protocol(
        .{
            .range = contracts.local_protocol_range,
            .capabilities = contracts.known_protocol_capabilities,
        },
        host_hello,
    );
    return switch (negotiation) {
        .compatible => |negotiated| .{
            .stream = stream,
            .negotiated = negotiated,
        },
        .incompatible => |incompatibility| .{
            .stream = stream,
            .negotiated = undefined,
            .incompatibility = incompatibility,
        },
    };
}

fn connectOrStart(
    zio: std.Io,
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    paths: *host.Paths,
) !std.Io.net.Stream {
    const started = io_mod.milliTimestamp();
    var authority_lock = while (true) {
        break io_mod.acquireTimedAdvisoryLock(
            &paths.host_dir,
            host.lock_name,
            0,
        ) catch |err| switch (err) {
            error.LockBusy => {
                if (tryConnect(paths.endpoint_path)) |stream| return stream;
                if (io_mod.milliTimestamp() - started >= connect_deadline_ms) {
                    return error.HostConnectTimeout;
                }
                try std.Io.sleep(zio, .fromMilliseconds(10), .awake);
                continue;
            },
            else => return err,
        };
    };
    const connection: policy.ConnectionEvidence =
        if (endpointExists(paths.endpointDir())) .refused else .endpoint_missing;
    const identity = host.identityEvidence(
        alloc,
        process_provider,
        &paths.host_dir,
    );
    const decision = policy.classifyReconciliation(
        connection,
        .acquired,
        identity,
    );
    switch (decision) {
        .start_host => authority_lock.release(),
        .remove_stale_then_start => {
            host.removeStaleArtifacts(&paths.host_dir, paths.endpointDir());
            authority_lock.release();
        },
        .preserve_identity_conflict => {
            authority_lock.release();
            return error.HostIdentityConflict;
        },
        .reuse_connected, .wait_for_authority, .unavailable => {
            authority_lock.release();
            return error.HostUnavailable;
        },
    }
    try launchHost(alloc);
    return waitForHost(zio, paths.endpoint_path, null);
}

fn tryConnect(endpoint_path: []const u8) ?std.Io.net.Stream {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) {
        const address = std.Io.net.UnixAddress.init(endpoint_path) catch return null;
        return address.connect(io_mod.getIo()) catch null;
    }
    if (endpoint_path.len >= @sizeOf(@FieldType(std.c.sockaddr.un, "path"))) {
        return null;
    }
    const fd = std.c.socket(
        std.c.AF.UNIX,
        std.c.SOCK.STREAM,
        0,
    );
    if (fd < 0) return null;
    var connected = false;
    defer if (!connected) {
        _ = std.c.close(fd);
    };
    if (std.c.fcntl(
        fd,
        std.c.F.SETFD,
        @as(usize, std.c.FD_CLOEXEC),
    ) != 0) return null;
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(usize, 0));
    if (flags < 0) return null;
    const original_flags: usize = @intCast(flags);
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (std.c.fcntl(fd, std.c.F.SETFL, original_flags | nonblock) != 0) return null;

    var socket_address: std.c.sockaddr.un = .{
        .family = std.c.AF.UNIX,
        .path = @splat(0),
    };
    @memcpy(socket_address.path[0..endpoint_path.len], endpoint_path);
    const address_len: std.c.socklen_t = @intCast(
        @offsetOf(std.c.sockaddr.un, "path") + endpoint_path.len + 1,
    );
    if (@hasField(std.c.sockaddr.un, "len")) {
        socket_address.len = @intCast(address_len);
    }
    if (std.c.connect(
        fd,
        @ptrCast(&socket_address),
        address_len,
    ) != 0) return null;
    if (std.c.fcntl(fd, std.c.F.SETFL, original_flags) != 0) return null;
    connected = true;
    return .{ .socket = .{
        .handle = fd,
        .address = .{ .ip4 = .loopback(0) },
    } };
}

fn waitForHost(zio: std.Io, endpoint_path: []const u8, requested_deadline_ms: ?i64) !std.Io.net.Stream {
    const deadline_ms = requested_deadline_ms orelse io_mod.milliTimestamp() + connect_deadline_ms;
    while (io_mod.milliTimestamp() < deadline_ms) {
        if (tryConnect(endpoint_path)) |stream| return stream;
        const remaining_ms = @max(0, deadline_ms - io_mod.milliTimestamp());
        try std.Io.sleep(zio, .fromMilliseconds(@min(remaining_ms, 10)), .awake);
    }
    return error.HostConnectTimeout;
}

fn launchHost(alloc: Allocator) !void {
    const executable = try self_exe.pathForReexec(alloc);
    defer alloc.free(executable);
    const argv = [_][]const u8{ executable, host.internal_mode };
    const child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag == .macos or builtin.os.tag == .linux)
            0
        else
            null,
    });
    var reaper = try std.Thread.spawn(.{}, reapChild, .{child});
    reaper.detach();
}

fn reapChild(child_value: std.process.Child) void {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        const pid = child_value.id orelse return;
        while (true) {
            const waited = std.c.waitpid(pid, null, 0);
            if (waited == pid) return;
            if (std.c.errno(waited) != .INTR) return;
        }
    }
    var child = child_value;
    _ = child.wait(io_mod.getIo()) catch {};
}

fn endpointExists(host_dir: *io_mod.VerifiedDir) bool {
    const stat = host_dir.dir.statFile(
        io_mod.getIo(),
        host.endpoint_name,
        .{ .follow_symlinks = false },
    ) catch return false;
    return stat.kind == .unix_domain_socket;
}

fn readHandshakeFrame(
    alloc: Allocator,
    socket: std.Io.net.Socket,
    requested_deadline_ms: ?i64,
) !protocol.DecodedFrame {
    const deadline_ms = requested_deadline_ms orelse io_mod.milliTimestamp() + handshake_deadline_ms;
    var header_bytes: [protocol.header_len]u8 = undefined;
    try receiveBeforeDeadline(socket, &header_bytes, deadline_ms, .header);
    const header = try protocol.Header.decode(&header_bytes);
    const payload_len: usize = header.envelope.payload_len;
    const total_len = std.math.add(
        usize,
        protocol.header_len,
        payload_len,
    ) catch return error.HostFrameTooLarge;
    const bytes = try alloc.alloc(u8, total_len);
    defer alloc.free(bytes);
    @memcpy(bytes[0..protocol.header_len], &header_bytes);
    try receiveBeforeDeadline(
        socket,
        bytes[protocol.header_len..],
        deadline_ms,
        .payload,
    );
    return protocol.decodeFrame(alloc, bytes);
}

const HandshakeReadPart = enum {
    header,
    payload,
};

fn receiveBeforeDeadline(
    socket: std.Io.net.Socket,
    destination: []u8,
    deadline_ms: i64,
    part: HandshakeReadPart,
) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const remaining_ms = deadline_ms - io_mod.milliTimestamp();
        if (remaining_ms <= 0) return error.HostHandshakeTimeout;
        const poll_ms = @min(remaining_ms, 50);
        const incoming = socket.receiveTimeout(
            io_mod.getIo(),
            destination[offset..],
            .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(poll_ms),
            } },
        ) catch |err| switch (err) {
            error.Timeout => continue,
            error.ConnectionResetByPeer => {
                if (part == .header and offset == 0) {
                    return error.HostClosedBeforeHandshake;
                }
                return error.TruncatedFrame;
            },
            else => return err,
        };
        if (incoming.data.len == 0) {
            if (part == .header and offset == 0) {
                return error.HostClosedBeforeHandshake;
            }
            return error.TruncatedFrame;
        }
        offset += incoming.data.len;
    }
}

fn testIntent(alloc: Allocator, correlation_id: u64) !Intent {
    return .{
        .correlation_id = .{ .value = correlation_id },
        .request = try contracts.OwnedActionRequest.init(
            alloc,
            .{ .screen = .{ .session_id = "terminal-1" } },
        ),
    };
}

fn registerTestRequest(runtime: *Runtime, correlation_id: u64) !*RequestWorker {
    var intent = try testIntent(runtime.alloc.?, correlation_id);
    const zio = io_mod.getIo();
    runtime.mutex.lockUncancelable(zio);
    defer runtime.mutex.unlock(zio);
    return (runtime.registerRequestLocked(intent) catch |err| {
        intent.deinit(runtime.alloc.?);
        return err;
    }) orelse error.TestWorkerAllocationFailed;
}

fn finishTestRequest(runtime: *Runtime, worker: *RequestWorker, kind: CompletionKind) void {
    runtime.finishActive(worker, .{ .kind = kind, .correlation_id = worker.intent.correlation_id });
    worker.intent.deinit(runtime.alloc.?);
    runtime.alloc.?.destroy(worker);
}

fn deinitTestRuntime(runtime: *Runtime) void {
    runtime.requests.cancel(io_mod.getIo());
    for (runtime.active) |entry| if (entry) |worker| finishTestRequest(runtime, worker, .cancelled);
    runtime.deinit();
}

fn checkIntentAllocationFailures(alloc: Allocator) !void {
    var runtime: Runtime = .{ .alloc = alloc };
    defer deinitTestRuntime(&runtime);
    var intent = try testIntent(alloc, 1);
    const worker = (runtime.registerRequestLocked(intent) catch |err| {
        intent.deinit(alloc);
        return err;
    }) orelse {
        try std.testing.expect(runtime.live_correlations.contains(.{ .value = 1 }));
        var completion = runtime.takeCompletionFor(.{ .value = 1 }).?;
        defer completion.deinit();
        try std.testing.expectEqual(CompletionKind.disconnected, completion.kind);
        try std.testing.expect(runtime.takeCompletionFor(.{ .value = 1 }) == null);
        // The runtime handled the failure; expose it only to the allocator
        // sweep after checking that its accepted outcome was delivered.
        return error.OutOfMemory;
    };
    finishTestRequest(&runtime, worker, .response);
    var completion = runtime.takeCompletionFor(.{ .value = 1 }).?;
    defer completion.deinit();
    try std.testing.expectEqual(CompletionKind.response, completion.kind);
    try std.testing.expect(!runtime.live_correlations.contains(.{ .value = 1 }));
}

test "owned admission preserves one outcome through every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkIntentAllocationFailures, .{});
}

test "accepted request scheduling failure produces exactly one retained outcome" {
    const Unavailable = struct {
        fn concurrent(_: ?*anyopaque, _: *std.Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            return error.ConcurrencyUnavailable;
        }
    };
    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer deinitTestRuntime(&runtime);
    const worker = try registerTestRequest(&runtime, 41);
    const zio = io_mod.getIo();
    var vtable = zio.vtable.*;
    vtable.groupConcurrent = Unavailable.concurrent;
    runtime.mutex.lockUncancelable(zio);
    runtime.submitRequestLocked(.{ .userdata = zio.userdata, .vtable = &vtable }, worker);
    runtime.mutex.unlock(zio);
    try std.testing.expect(runtime.live_correlations.contains(.{ .value = 41 }));
    try std.testing.expectError(error.DuplicateCorrelation, registerTestRequest(&runtime, 41));
    var completion = runtime.takeCompletionFor(.{ .value = 41 }).?;
    defer completion.deinit();
    try std.testing.expectEqual(CompletionKind.disconnected, completion.kind);
    try std.testing.expect(runtime.takeCompletionFor(.{ .value = 41 }) == null);
    try std.testing.expect(!runtime.live_correlations.contains(.{ .value = 41 }));
    for (runtime.active) |entry| try std.testing.expect(entry == null);
}

test "completion sink stays FIFO after dequeue and refill" {
    var sink: CompletionSink = .{};
    defer {
        while (sink.take()) |completion_value| {
            var completion = completion_value;
            completion.deinit();
        }
    }
    sink.push(.{ .kind = .response, .correlation_id = .{ .value = 1 } });
    sink.push(.{ .kind = .cancelled, .correlation_id = .{ .value = 2 } });

    var first = sink.take().?;
    try std.testing.expectEqual(CompletionKind.response, first.kind);
    first.deinit();
    sink.push(.{ .kind = .disconnected, .correlation_id = .{ .value = 3 } });

    for ([_]CompletionKind{ .cancelled, .disconnected }) |expected| {
        var completion = sink.take().?;
        try std.testing.expectEqual(expected, completion.kind);
        completion.deinit();
    }
}

test "runtime reserves bounded outcomes until every correlation is consumed" {
    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer deinitTestRuntime(&runtime);
    for (1..policy.outcome_capacity + 1) |id| {
        const worker = try registerTestRequest(&runtime, id);
        finishTestRequest(&runtime, worker, .response);
    }
    try std.testing.expectEqual(@as(usize, policy.outcome_capacity), runtime.completions.len);
    try std.testing.expectError(error.QueueFull, registerTestRequest(&runtime, policy.outcome_capacity + 1));
    try std.testing.expectEqual(@as(usize, policy.outcome_capacity), runtime.completions.len);
    for (1..policy.outcome_capacity + 1) |id| {
        var completion = runtime.takeCompletionFor(.{ .value = id }).?;
        try std.testing.expectEqual(@as(u64, id), completion.correlation_id.?.value);
        completion.deinit();
        try std.testing.expect(runtime.takeCompletionFor(.{ .value = id }) == null);
    }
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.len);
}

test "runtime rejects duplicate active and completed correlations until consumption" {
    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer deinitTestRuntime(&runtime);
    const worker = try registerTestRequest(&runtime, 23);
    try std.testing.expectError(error.DuplicateCorrelation, registerTestRequest(&runtime, 23));
    finishTestRequest(&runtime, worker, .cancelled);
    try std.testing.expectError(error.DuplicateCorrelation, registerTestRequest(&runtime, 23));
    var completion = runtime.takeCompletionFor(.{ .value = 23 }).?;
    completion.deinit();
    try std.testing.expect(!runtime.live_correlations.contains(.{ .value = 23 }));
    const reused = try registerTestRequest(&runtime, 23);
    finishTestRequest(&runtime, reused, .response);
}

test "runtime cancellation before request I/O affects only its correlation" {
    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer deinitTestRuntime(&runtime);
    const first = try registerTestRequest(&runtime, 1);
    const cancelled = try registerTestRequest(&runtime, 2);
    const third = try registerTestRequest(&runtime, 3);
    try std.testing.expect(runtime.cancel(.{ .value = 2 }));
    try std.testing.expect(!first.cancelled.load(.acquire));
    try std.testing.expect(!third.cancelled.load(.acquire));
    try runtime.requests.concurrent(io_mod.getIo(), RequestWorker.run, .{cancelled});
    try runtime.requests.await(io_mod.getIo());
    try std.testing.expect(runtime.live_correlations.contains(.{ .value = 2 }));
    var completion = runtime.takeCompletionFor(.{ .value = 2 }).?;
    defer completion.deinit();
    try std.testing.expectEqual(CompletionKind.cancelled, completion.kind);
    try std.testing.expect(!runtime.live_correlations.contains(.{ .value = 2 }));
    try std.testing.expect(runtime.live_correlations.contains(.{ .value = 1 }));
    try std.testing.expect(runtime.live_correlations.contains(.{ .value = 3 }));
    try std.testing.expect(runtime.takeCompletionFor(.{ .value = 2 }) == null);
}

test "runtime deinit owns active requests and retained correlations" {
    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer deinitTestRuntime(&runtime);
    const completed = try registerTestRequest(&runtime, 1);
    finishTestRequest(&runtime, completed, .response);
    const pending = try registerTestRequest(&runtime, 2);
    pending.cancelled.store(true, .release);
    try runtime.requests.concurrent(io_mod.getIo(), RequestWorker.run, .{pending});
    runtime.deinit();
    try std.testing.expect(runtime.alloc == null);
    try std.testing.expect(!runtime.stop_requested.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), runtime.completions.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.projection.rows.items.len);
    for (runtime.completions.values) |entry| try std.testing.expect(entry == null);
    for (runtime.live_correlations.values) |entry| try std.testing.expect(entry == null);
    for (runtime.active) |entry| try std.testing.expect(entry == null);
    try std.testing.expectEqual(@as(u64, 1), runtime.nextCorrelationId().value);
    runtime.deinit();
    try std.testing.expectEqual(@as(u64, 1), runtime.nextCorrelationId().value);
}

test "lazy runtime has no allocation or request task before first admission" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    try std.testing.expect(runtime.alloc == null);
    try std.testing.expect(runtime.requests.token.load(.acquire) == null);
    for (runtime.active) |entry| try std.testing.expect(entry == null);
}

test "stalled request cancellation emits only the targeted cancel" {
    if (!host.isSupported()) return error.SkipZigTest;
    var handles: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(
        std.c.AF.UNIX,
        std.c.SOCK.STREAM,
        0,
        &handles,
    ) != 0) return error.SocketPairFailed;
    var client_stream = std.Io.net.Stream{ .socket = .{
        .handle = handles[0],
        .address = undefined,
    } };
    defer client_stream.close(io_mod.getIo());
    var host_stream = std.Io.net.Stream{ .socket = .{
        .handle = handles[1],
        .address = undefined,
    } };
    defer host_stream.close(io_mod.getIo());

    var runtime: Runtime = .{ .alloc = std.testing.allocator };
    defer runtime.deinit();
    var worker = RequestWorker{
        .runtime = &runtime,
        .intent = .{
            .correlation_id = .{ .value = 17 },
            .request = try contracts.OwnedActionRequest.init(
                std.testing.allocator,
                .{ .screen = .{ .session_id = "terminal-1" } },
            ),
        },
    };
    const zio = io_mod.getIo();
    runtime.mutex.lockUncancelable(zio);
    try runtime.live_correlations.add(.{ .value = 17 });
    worker.slot = runtime.registerWorkerLocked(&worker).?;
    runtime.mutex.unlock(zio);

    const Exchange = struct {
        worker: *RequestWorker,
        stream: std.Io.net.Stream,
        completion: ?Completion = null,
        failed: bool = false,

        fn run(self: *@This()) void {
            self.completion = exchangeConnected(
                self.worker,
                std.testing.allocator,
                &self.worker.intent,
                .{
                    .stream = self.stream,
                    .negotiated = .{
                        .revision = contracts.current_protocol_revision,
                        .capabilities = contracts.known_protocol_capabilities,
                    },
                },
            ) catch {
                self.failed = true;
                return;
            };
        }
    };
    var exchange_state = Exchange{
        .worker = &worker,
        .stream = client_stream,
    };
    const thread = try std.Thread.spawn(.{}, Exchange.run, .{&exchange_state});

    var host_read_buffer: [4096]u8 = undefined;
    var host_reader = host_stream.reader(io_mod.getIo(), &host_read_buffer);
    var request = try protocol.readFrame(
        std.testing.allocator,
        &host_reader.interface,
    );
    defer request.deinit();
    try std.testing.expectEqual(
        @as(u64, 17),
        request.message().envelope.correlation_id.?.value,
    );
    try std.testing.expect(runtime.cancel(.{ .value = 17 }));
    var cancel = try protocol.readFrame(
        std.testing.allocator,
        &host_reader.interface,
    );
    defer cancel.deinit();
    try std.testing.expectEqual(
        @as(u64, 17),
        cancel.message().envelope.correlation_id.?.value,
    );
    switch (cancel.message().payload) {
        .cancel => {},
        else => return error.TestExpectedCancel,
    }

    thread.join();
    try std.testing.expect(!exchange_state.failed);
    var completion = exchange_state.completion.?;
    defer completion.deinit();
    try std.testing.expectEqual(CompletionKind.cancelled, completion.kind);
    runtime.finishActive(&worker, .{
        .kind = .cancelled,
        .correlation_id = .{ .value = 17 },
    });
    worker.intent.deinit(std.testing.allocator);
}

test "unsupported client platforms remain structural" {
    const host_capabilities = @import("../hosts/host.zig");
    try std.testing.expectEqual(
        host_capabilities.terminalSupportForOs(builtin.os.tag).isSupported(),
        host.isSupported(),
    );
}

test "client retains independent idempotent owner exit capabilities" {
    const Probe = struct {
        fn run(alloc: Allocator) !void {
            var runtime: Runtime = .{};
            defer runtime.deinit();
            var id = "owner-1".*;
            const proof = contracts.HolderProof{ .bytes = @splat(1) };
            try runtime.retainOwnerExit(alloc, .{ .session_id = &id, .proof = proof });
            id[0] = 'x';
            const retained = runtime.exit_owners[0].?;
            try std.testing.expectEqualStrings("owner-1", retained.session_id);
            try runtime.retainOwnerExit(alloc, .{ .session_id = "owner-1", .proof = proof });
            try std.testing.expect(retained.session_id.ptr == runtime.exit_owners[0].?.session_id.ptr);
            try std.testing.expectError(error.TerminalUnavailable, runtime.retainOwnerExit(alloc, .{
                .session_id = "owner-1",
                .proof = .{ .bytes = @splat(2) },
            }));
            try std.testing.expectEqual(proof, runtime.exit_owners[0].?.proof);
            for (runtime.exit_owners[1..]) |entry| try std.testing.expect(entry == null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "client rejects owner exit capacity overflow before starting requests" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    for (0..max_exit_owners) |index| {
        var id_buffer: [32]u8 = undefined;
        try runtime.retainOwnerExit(std.testing.allocator, .{
            .session_id = try std.fmt.bufPrint(&id_buffer, "owner-{d}", .{index}),
            .proof = .{ .bytes = @splat(1) },
        });
    }
    try std.testing.expectError(error.QueueFull, runtime.admit(std.testing.allocator, .{ .value = 42 }, .{ .start = .{
        .cwd = "/workspace",
        .persistence = .{
            .grant = .{
                .principal = .{ .profile_user = "test-user", .durable_session_id = "owner-overflow", .workspace_root = "/workspace", .cwd = "/workspace", .transport_role = .interactive, .backend = .native },
                .actor = .agent,
                .controls = .full(),
                .generation = .{ .value = 1 },
            },
            .proof = .{ .bytes = @splat(1) },
            .exit_proof = .{ .bytes = @splat(1) },
        },
    } }));
    try std.testing.expect(runtime.requests.token.load(.acquire) == null);
    for (runtime.active) |entry| try std.testing.expect(entry == null);
    try std.testing.expect(!runtime.live_correlations.contains(.{ .value = 42 }));
    try runtime.retainOwnerExit(std.testing.allocator, .{ .session_id = "owner-0", .proof = .{ .bytes = @splat(1) } });
}

test "client shutdown seals owner exit capabilities before rejecting late starts" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    try runtime.retainOwnerExit(std.testing.allocator, .{ .session_id = "owner-existing", .proof = .{ .bytes = @splat(1) } });
    runtime.stopRequests();
    try std.testing.expectError(error.RuntimeStopping, runtime.admit(std.testing.allocator, .{ .value = 42 }, .{ .start = .{
        .cwd = "/workspace",
        .persistence = .{
            .grant = .{
                .principal = .{ .profile_user = "test-user", .durable_session_id = "owner-late", .workspace_root = "/workspace", .cwd = "/workspace", .transport_role = .interactive, .backend = .native },
                .actor = .agent,
                .controls = .full(),
                .generation = .{ .value = 1 },
            },
            .proof = .{ .bytes = @splat(1) },
            .exit_proof = .{ .bytes = @splat(1) },
        },
    } }));
    try std.testing.expectEqualStrings("owner-existing", runtime.exit_owners[0].?.session_id);
    for (runtime.exit_owners[1..]) |entry| try std.testing.expect(entry == null);
    for (runtime.active) |entry| try std.testing.expect(entry == null);
    try std.testing.expect(!runtime.live_correlations.contains(.{ .value = 42 }));
}

test "client shutdown cancels its request group after partial HELLO consumption" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var handles: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &handles) != 0) return error.SocketPairFailed;
    const client_stream = std.Io.net.Stream{ .socket = .{ .handle = handles[0], .address = undefined } };
    defer client_stream.close(zio);
    const peer_stream = std.Io.net.Stream{ .socket = .{ .handle = handles[1], .address = undefined } };
    var peer_owned = true;
    defer if (peer_owned) peer_stream.close(zio);
    var hello = try protocol.encodeFrame(alloc, contracts.current_protocol_revision, 0, null, .{ .hello = .{
        .range = contracts.local_protocol_range,
        .capabilities = contracts.known_protocol_capabilities,
    } });
    defer hello.deinit(alloc);
    const Probe = struct {
        expected_allocation: usize,
        client: std.Io.net.Stream,
        peer: std.Io.net.Stream,
        consumed_header: std.Io.Event = .unset,
        release_peer: std.Io.Event = .unset,
        failure: ?anyerror = null,

        fn allocator(self: *@This()) Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
        }
        fn allocate(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const bytes = std.testing.allocator.rawAlloc(len, alignment, address);
            if (bytes != null and len == self.expected_allocation) self.consumed_header.set(io_mod.getIo());
            return bytes;
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, address);
        }
        fn read(self: *@This()) void {
            var frame = readHandshakeFrame(self.allocator(), self.client.socket, null) catch |err| {
                self.failure = err;
                return;
            };
            frame.deinit();
        }
        fn rescue(self: *@This()) void {
            self.release_peer.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(1) } }) catch {};
            self.peer.close(io_mod.getIo());
        }
    };
    var probe: Probe = .{ .expected_allocation = hello.bytes.len, .client = client_stream, .peer = peer_stream };
    var runtime: Runtime = .{};
    defer runtime.deinit();
    defer runtime.requests.cancel(zio);
    try runtime.requests.concurrent(zio, Probe.read, .{&probe});
    var buffer: [protocol.header_len]u8 = undefined;
    var writer = peer_stream.writer(zio, &buffer);
    try writer.interface.writeAll(hello.bytes[0..protocol.header_len]);
    try writer.interface.flush();
    try probe.consumed_header.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
    const rescue = try std.Thread.spawn(.{}, Probe.rescue, .{&probe});
    peer_owned = false;
    const started = io_mod.milliTimestamp();
    runtime.stopRequests();
    const elapsed_ms = io_mod.milliTimestamp() - started;
    probe.release_peer.set(zio);
    rescue.join();
    try std.testing.expect(elapsed_ms < 500);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), probe.failure);
}

test "client connection retry sleeps preserve cancellation after failed connects" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var paths = try host.Paths.open(alloc, home);
    defer paths.deinit(alloc);
    defer if (paths.transport_dir != null) std.Io.Dir.deleteDirAbsolute(zio, paths.transport_root_path) catch {};
    var lock = try io_mod.acquireTimedAdvisoryLock(&paths.host_dir, host.lock_name, 0);
    defer lock.release();
    try std.testing.expectError(error.FileNotFound, paths.endpointDir().dir.access(zio, host.endpoint_name, .{}));
    const Probe = struct {
        var current: ?*@This() = null;
        base: std.Io,
        observed: std.Io,
        paths: *host.Paths,
        locked: bool,
        first_sleep: bool = true,
        reached: std.Io.Event = .unset,
        cancellation_gate: std.Io.Event = .unset,
        failure: ?anyerror = null,

        fn sleep(raw: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
            const self = current.?;
            if (self.first_sleep) {
                self.first_sleep = false;
                self.reached.set(self.base);
                // Hold this real retry-sleep call until cancellation arrives,
                // then deliver it to the original sleep implementation.
                self.cancellation_gate.wait(self.base) catch self.base.recancel();
            }
            return self.base.vtable.sleep(raw, timeout);
        }
        fn run(self: *@This()) void {
            const stream = (if (self.locked)
                connectOrStart(self.observed, std.testing.allocator, process_provider_mod.unavailable_provider, self.paths)
            else
                waitForHost(self.observed, self.paths.endpoint_path, null)) catch |err| {
                self.failure = err;
                return;
            };
            stream.close(self.base);
        }
    };
    var elapsed: [2]i64 = undefined;
    var failures: [2]?anyerror = undefined;
    for ([_]bool{ false, true }, 0..) |locked, index| {
        var vtable = zio.vtable.*;
        vtable.sleep = Probe.sleep;
        var probe: Probe = .{
            .base = zio,
            .observed = .{ .userdata = zio.userdata, .vtable = &vtable },
            .paths = &paths,
            .locked = locked,
        };
        Probe.current = &probe;
        defer Probe.current = null;
        var runtime: Runtime = .{};
        defer runtime.deinit();
        defer runtime.requests.cancel(zio);
        try runtime.requests.concurrent(zio, Probe.run, .{&probe});
        try probe.reached.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(3) } });
        const started = io_mod.milliTimestamp();
        runtime.stopRequests();
        elapsed[index] = io_mod.milliTimestamp() - started;
        failures[index] = probe.failure;
    }
    try std.testing.expectEqual([2]bool{ true, true }, [2]bool{ elapsed[0] < 500, elapsed[1] < 500 });
    try std.testing.expectEqual([2]?anyerror{ error.Canceled, error.Canceled }, failures);
}

test "Linux client connect cannot block shutdown behind a full Unix backlog" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(directory);
    const endpoint = try std.fs.path.join(alloc, &.{ directory, "backlog.sock" });
    defer alloc.free(endpoint);
    const unix_address = try std.Io.net.UnixAddress.init(endpoint);
    var server = try unix_address.listen(zio, .{ .kernel_backlog = 1 });
    defer server.deinit(zio);
    var address: std.c.sockaddr.un = .{ .family = std.c.AF.UNIX, .path = @splat(0) };
    @memcpy(address.path[0..endpoint.len], endpoint);
    const address_len: std.c.socklen_t = @intCast(@offsetOf(std.c.sockaddr.un, "path") + endpoint.len + 1);
    var fillers: [8]?std.c.fd_t = @splat(null);
    defer for (fillers) |fd| if (fd) |value| {
        _ = std.c.close(value);
    };
    var full = false;
    for (&fillers) |*slot| {
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.NONBLOCK | std.c.SOCK.CLOEXEC, 0);
        if (fd < 0) return error.SocketFailed;
        const result = std.c.connect(fd, @ptrCast(&address), address_len);
        if (result == 0) {
            slot.* = fd;
        } else {
            const err = std.c.errno(result);
            _ = std.c.close(fd);
            try std.testing.expectEqual(std.c.E.AGAIN, err);
            full = true;
            break;
        }
    }
    try std.testing.expect(full);
    const Probe = struct {
        endpoint: []const u8,
        listener: std.c.fd_t,
        tid: std.atomic.Value(std.os.linux.pid_t) = .init(0),
        returned: std.atomic.Value(bool) = .init(false),
        rescue_requested: std.Io.Event = .unset,
        shutdown_finished: std.Io.Event = .unset,
        connected: bool = false,

        fn connect(self: *@This()) void {
            self.tid.store(std.os.linux.gettid(), .release);
            if (tryConnect(self.endpoint)) |stream| {
                self.connected = true;
                stream.close(io_mod.getIo());
            }
            self.returned.store(true, .release);
        }
        fn inConnect(self: *@This()) !bool {
            const tid = self.tid.load(.acquire);
            if (tid == 0) return false;
            var path_buffer: [80]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, "/proc/self/task/{d}/syscall", .{tid});
            var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
            defer file.close(io_mod.getIo());
            var buffer: [512]u8 = undefined;
            var reader = file.readerStreaming(io_mod.getIo(), &buffer);
            const bytes = try reader.interface.allocRemaining(std.testing.allocator, .limited(buffer.len));
            defer std.testing.allocator.free(bytes);
            var words = std.mem.tokenizeAny(u8, bytes, " \n");
            const syscall = std.fmt.parseInt(usize, words.next() orelse return false, 10) catch return false;
            return syscall == @intFromEnum(std.os.linux.SYS.connect);
        }
        fn rescue(self: *@This()) void {
            self.rescue_requested.waitUncancelable(io_mod.getIo());
            self.shutdown_finished.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(1) } }) catch {
                const accepted = std.c.accept(self.listener, null, null);
                if (accepted >= 0) _ = std.c.close(accepted);
            };
        }
    };
    var probe: Probe = .{ .endpoint = endpoint, .listener = server.socket.handle };
    var runtime: Runtime = .{};
    defer runtime.deinit();
    const rescue = try std.Thread.spawn(.{}, Probe.rescue, .{&probe});
    defer {
        probe.rescue_requested.set(zio);
        runtime.requests.cancel(zio);
        probe.shutdown_finished.set(zio);
        rescue.join();
    }
    try runtime.requests.concurrent(zio, Probe.connect, .{&probe});
    const observation_deadline = io_mod.milliTimestamp() + 3_000;
    while (!probe.returned.load(.acquire) and !try probe.inConnect()) {
        if (io_mod.milliTimestamp() >= observation_deadline) return error.ConnectNotObserved;
        try std.Io.sleep(zio, .fromMilliseconds(1), .awake);
    }
    probe.rescue_requested.set(zio);
    const started = io_mod.milliTimestamp();
    runtime.stopRequests();
    const elapsed_ms = io_mod.milliTimestamp() - started;
    probe.shutdown_finished.set(zio);
    if (elapsed_ms >= 500 or probe.connected) std.debug.print("backlog shutdown: elapsed_ms={d} connected={}\n", .{ elapsed_ms, probe.connected });
    try std.testing.expect(elapsed_ms < 500);
    try std.testing.expect(!probe.connected);
}

test "client connection probes preserve blocking streams for frame readers" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var paths = try host.Paths.open(alloc, home);
    defer paths.deinit(alloc);
    defer if (paths.transport_dir != null) std.Io.Dir.deleteDirAbsolute(zio, paths.transport_root_path) catch {};
    const address = try std.Io.net.UnixAddress.init(paths.endpoint_path);
    var server = try address.listen(zio, .{});
    defer server.deinit(zio);
    defer paths.endpointDir().dir.deleteFile(zio, host.endpoint_name) catch {};
    const stream = tryConnect(paths.endpoint_path) orelse return error.ConnectFailed;
    defer stream.close(zio);
    const peer = try server.accept(zio);
    defer peer.close(zio);
    const flags = std.c.fcntl(stream.socket.handle, std.c.F.GETFL, @as(usize, 0));
    try std.testing.expect(flags >= 0);
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    try std.testing.expectEqual(@as(usize, 0), @as(usize, @intCast(flags)) & nonblock);
}

test "client host wait honors the shared owner exit deadline" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var paths = try host.Paths.open(alloc, home);
    defer paths.deinit(alloc);
    defer if (paths.transport_dir != null) std.Io.Dir.deleteDirAbsolute(zio, paths.transport_root_path) catch {};
    var elapsed: [2]i64 = undefined;
    for ([_]i64{ owner_exit_timeout_ms, -1 }, 0..) |remaining, index| {
        const started = io_mod.milliTimestamp();
        try std.testing.expectError(error.HostConnectTimeout, waitForHost(zio, paths.endpoint_path, started + remaining));
        elapsed[index] = io_mod.milliTimestamp() - started;
    }
    try std.testing.expectEqual([2]bool{ true, true }, [2]bool{ elapsed[0] < 500, elapsed[1] < 50 });
    try std.testing.expect(elapsed[0] >= owner_exit_timeout_ms);
}
