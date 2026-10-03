//! Terminal status mirrors fx's foreground status into the terminal hosts it
//! runs inside (herdr, cmux, and Otty). This file is the only front door:
//!
//! - `TerminalStatus.publish` turns one lifecycle event into the next status
//!   (`status.next`) and queues it if anything visible changed. It never
//!   blocks on a host.
//! - One publisher thread renders queued statuses, in order, to every
//!   detected host. Hosts receive only `Status` values.
//! - `Hooks(App, ...)` connects the app's lifecycle hooks, the worker's
//!   foreground observer, and approval-prompt observations to `publish`.
//!
//! Status is a read model. Host failures are dropped; the next status change
//! sends the full current state again.

const std = @import("std");
const host_target = @import("../../core/hosts/target.zig");
const io_mod = @import("../../core/shared/io.zig");
const hooks = @import("../../core/hooks/hooks.zig");
const types = @import("../../core/shared/types.zig");
const status = @import("status.zig");
const herdr = @import("hosts/herdr.zig");
const cmux = @import("hosts/cmux.zig");
const otty = @import("hosts/otty.zig");

pub const Event = status.Event;

const Host = union(enum) {
    herdr: herdr.Host,
    cmux: cmux.Host,
    otty: otty.Host,

    fn render(self: *Host, prev: ?status.Status, now: status.Status) void {
        switch (self.*) {
            inline else => |*host| host.render(prev, now),
        }
    }

    fn stop(self: *Host) void {
        switch (self.*) {
            inline else => |*host| host.stop(),
        }
    }

    fn deinit(self: *Host) void {
        switch (self.*) {
            inline else => |*host| host.deinit(),
        }
    }
};

const max_hosts = @typeInfo(Host).@"union".fields.len;

/// Statuses waiting to be rendered, oldest first. Hosts see every visible
/// transition in order; on overflow only the latest status survives.
const Pending = struct {
    const capacity = 16;

    items: [capacity]status.Status = undefined,
    len: usize = 0,

    fn push(self: *Pending, value: status.Status) void {
        if (self.len == capacity) self.len = 0;
        self.items[self.len] = value;
        self.len += 1;
    }

    fn take(self: *Pending) ?status.Status {
        if (self.len == 0) return null;
        const value = self.items[0];
        std.mem.copyForwards(status.Status, self.items[0 .. self.len - 1], self.items[1..self.len]);
        self.len -= 1;
        return value;
    }

    /// Shutdown renders only the final status so exit stays bounded.
    fn keepLatest(self: *Pending) void {
        if (self.len <= 1) return;
        self.items[0] = self.items[self.len - 1];
        self.len = 1;
    }
};

const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    state: status.State = .{},
    last_published: ?status.Status = null,
    pending: Pending = .{},
    hosts: [max_hosts]Host = undefined,
    host_count: usize = 0,

    /// Caller holds the mutex. Returns the status to render, or null when the
    /// event changed nothing visible.
    fn accept(self: *Runtime, event: Event, session_id: ?[]const u8) ?status.Status {
        const session = if (session_id) |id| status.SessionId.init(id) else null;
        self.state = status.next(self.state, event, session);
        const now = self.state.status();
        if (self.last_published) |previous| {
            if (previous.eql(now)) return null;
        }
        self.last_published = now;
        return now;
    }

    fn run(self: *Runtime) void {
        var rendered: ?status.Status = null;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.pending.len == 0 and !self.stopping) {
                self.wake.waitUncancelable(self.io, &self.mutex);
            }
            const value = self.pending.take();
            self.mutex.unlock(self.io);

            const now = value orelse {
                for (self.hosts[0..self.host_count]) |*host| host.stop();
                return;
            };
            for (self.hosts[0..self.host_count]) |*host| host.render(rendered, now);
            rendered = now;
        }
    }
};

pub const TerminalStatus = struct {
    runtime: ?*Runtime = null,

    /// Detects hosts from the environment and starts the publisher. Leaves
    /// terminal status disabled when no host is present or setup fails. The
    /// runtime is heap-owned, so the struct may move afterwards.
    pub fn init(self: *TerminalStatus, alloc: std.mem.Allocator) void {
        if (comptime host_target.is_wasm) return;
        if (self.runtime != null) return;
        var hosts: [max_hosts]Host = undefined;
        var count: usize = 0;
        if (herdr.Host.detect(alloc)) |host| {
            hosts[count] = .{ .herdr = host };
            count += 1;
        }
        if (cmux.Host.detect(alloc)) |host| {
            hosts[count] = .{ .cmux = host };
            count += 1;
        }
        if (otty.Host.detect(alloc)) |host| {
            hosts[count] = .{ .otty = host };
            count += 1;
        }
        if (count == 0) return;

        const runtime = alloc.create(Runtime) catch {
            for (hosts[0..count]) |*host| host.deinit();
            return;
        };
        runtime.* = .{ .alloc = alloc, .io = io_mod.getIo(), .hosts = hosts, .host_count = count };
        runtime.thread = std.Thread.spawn(.{}, Runtime.run, .{runtime}) catch {
            for (hosts[0..count]) |*host| host.deinit();
            alloc.destroy(runtime);
            return;
        };
        self.runtime = runtime;
    }

    pub fn enabled(self: *const TerminalStatus) bool {
        return self.runtime != null;
    }

    /// Safe from any thread. `session_id` is copied before returning.
    pub fn publish(self: *TerminalStatus, event: Event, session_id: ?[]const u8) void {
        const runtime = self.runtime orelse return;
        runtime.mutex.lockUncancelable(runtime.io);
        defer runtime.mutex.unlock(runtime.io);
        if (runtime.stopping) return;
        const now = runtime.accept(event, session_id) orelse return;
        runtime.pending.push(now);
        runtime.wake.signal(runtime.io);
    }

    /// Renders the final status, clears fx from every host, and joins the
    /// publisher. Later `publish` calls are ignored.
    pub fn deinit(self: *TerminalStatus) void {
        const runtime = self.runtime orelse return;
        runtime.mutex.lockUncancelable(runtime.io);
        runtime.stopping = true;
        runtime.pending.keepLatest();
        runtime.wake.signal(runtime.io);
        runtime.mutex.unlock(runtime.io);
        runtime.thread.?.join();
        for (runtime.hosts[0..runtime.host_count]) |*host| host.deinit();
        const alloc = runtime.alloc;
        alloc.destroy(runtime);
        self.* = .{};
    }
};

/// Connects app lifecycle signals to `app.terminal_status`. `activeSessionId`
/// names the session that worker observer events belong to.
pub fn Hooks(comptime App: type, comptime activeSessionId: fn (*App) ?[]const u8) type {
    return struct {
        /// Must run before the lifecycle runtime is frozen.
        pub fn configure(app: *App) !void {
            app.terminal_status.init(app.alloc);
            if (!app.terminal_status.enabled()) return;
            app.terminal_status.publish(.session_changed, activeSessionId(app));
            try app.lifecycle_runtime.registerPostTurnEnd(.{
                .name = "fx.terminal_status.turn_end",
                .ctx = app,
                .run = turnEnded,
            });
            try app.lifecycle_runtime.registerAttentionRequired(.{
                .name = "fx.terminal_status.attention_required",
                .ctx = app,
                .run = attentionRequired,
            });
            app.worker.foreground_observer = .{
                .context = app,
                .working = foregroundWorking,
                .settled = foregroundSettled,
            };
        }

        /// Called on every worker state sync with the latest approval-prompt
        /// observation. Repeated observations change nothing.
        pub fn sync(app: *App, child_approval_waiting: bool, parent_approval_waiting: bool) void {
            const session_id = activeSessionId(app);
            app.terminal_status.publish(.session_changed, session_id);
            app.terminal_status.publish(.{ .child_approval = .{
                .waiting = child_approval_waiting,
                .parent_waiting = parent_approval_waiting,
            } }, session_id);
        }

        fn foregroundWorking(raw: *anyopaque) void {
            const app: *App = @ptrCast(@alignCast(raw));
            app.terminal_status.publish(.working, activeSessionId(app));
        }

        fn foregroundSettled(raw: *anyopaque, outcome: types.TurnPresentationOutcome) void {
            const app: *App = @ptrCast(@alignCast(raw));
            app.terminal_status.publish(.{ .settled = outcome }, activeSessionId(app));
        }

        fn turnEnded(raw: *anyopaque, input: hooks.PostTurnEndInput) hooks.HandlerError!void {
            if (input.invocation.scope.kind != .interactive) return;
            const app: *App = @ptrCast(@alignCast(raw));
            app.terminal_status.publish(.{ .settled = input.outcome }, input.invocation.scope.session_id);
        }

        fn attentionRequired(raw: *anyopaque, input: hooks.AttentionRequiredInput) hooks.HandlerError!void {
            if (input.invocation.scope.kind != .interactive) return;
            const app: *App = @ptrCast(@alignCast(raw));
            const kind: status.AttentionKind = switch (input.kind) {
                .permission => .permission,
                .question => .question,
                .route_recovery => .recovery,
            };
            app.terminal_status.publish(.{ .attention_opened = kind }, input.invocation.scope.session_id);
        }
    };
}

const testing = std.testing;

test "pending statuses stay ordered and overflow keeps the latest" {
    var pending: Pending = .{};
    pending.push(.{ .activity = .working });
    pending.push(.{ .activity = .idle });
    try testing.expectEqual(status.Activity.working, pending.take().?.activity);
    try testing.expectEqual(status.Activity.idle, pending.take().?.activity);
    try testing.expect(pending.take() == null);

    for (0..Pending.capacity) |_| pending.push(.{ .activity = .working });
    pending.push(.{ .activity = .failed });
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqual(status.Activity.failed, pending.take().?.activity);

    pending.push(.{ .activity = .working });
    pending.push(.{ .activity = .waiting });
    pending.push(.{ .activity = .idle });
    pending.keepLatest();
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqual(status.Activity.idle, pending.take().?.activity);
}

test "the publisher queues only visible status changes" {
    var runtime: Runtime = .{ .alloc = testing.allocator, .io = testing.io };
    try testing.expect(runtime.accept(.session_changed, null) != null);
    try testing.expect(runtime.accept(.session_changed, null) == null);
    try testing.expectEqual(status.Activity.working, runtime.accept(.working, "session").?.activity);
    try testing.expect(runtime.accept(.working, "session") == null);
    try testing.expect(runtime.accept(.session_changed, "session") == null);
    try testing.expect(runtime.accept(.{ .child_approval = .{ .waiting = false, .parent_waiting = false } }, "session") == null);
    try testing.expectEqual(status.Activity.waiting, runtime.accept(.{ .attention_opened = .question }, "session").?.activity);
    try testing.expectEqual(status.Activity.idle, runtime.accept(.{ .settled = .completed }, "session").?.activity);
}

const RecordingPublisher = struct {
    const Record = struct { event: Event, session_id: ?[]const u8 };

    enable_on_init: bool = true,
    is_enabled: bool = false,
    records: [16]Record = undefined,
    count: usize = 0,

    fn init(self: *RecordingPublisher, _: std.mem.Allocator) void {
        self.is_enabled = self.enable_on_init;
    }

    fn enabled(self: *const RecordingPublisher) bool {
        return self.is_enabled;
    }

    fn publish(self: *RecordingPublisher, event: Event, session_id: ?[]const u8) void {
        self.records[self.count] = .{ .event = event, .session_id = session_id };
        self.count += 1;
    }
};

const TestWorker = struct {
    const ForegroundObserver = struct {
        context: *anyopaque,
        working: *const fn (*anyopaque) void,
        settled: *const fn (*anyopaque, types.TurnPresentationOutcome) void,
    };

    foreground_observer: ?ForegroundObserver = null,
};

const TestApp = struct {
    alloc: std.mem.Allocator,
    lifecycle_runtime: hooks.Runtime,
    worker: TestWorker = .{},
    terminal_status: RecordingPublisher = .{},

    fn activeSessionId(_: *TestApp) ?[]const u8 {
        return "active";
    }
};

fn testInvocation(kind: hooks.ScopeKind) hooks.Invocation {
    return .{
        .scope = .{ .kind = kind, .workspace_root = "/tmp/workspace", .session_id = "scoped" },
        .turn_id = 42,
    };
}

test "hooks publish only interactive lifecycle signals" {
    const Wiring = Hooks(TestApp, TestApp.activeSessionId);
    var app: TestApp = .{ .alloc = testing.allocator, .lifecycle_runtime = hooks.Runtime.init(testing.allocator) };
    defer app.lifecycle_runtime.deinit();

    try Wiring.configure(&app);
    const view = app.lifecycle_runtime.freeze();
    try testing.expect(view.hasPostTurnEnd());
    try testing.expect(view.hasAttentionRequired());
    const observer = app.worker.foreground_observer orelse return error.TestExpectedEqual;

    observer.working(observer.context);
    view.runAttentionRequired(.{ .invocation = testInvocation(.acp), .kind = .permission });
    view.runAttentionRequired(.{ .invocation = testInvocation(.interactive), .kind = .route_recovery });
    observer.settled(observer.context, .failed);
    view.runPostTurnEnd(.{ .invocation = testInvocation(.ask), .outcome = .completed });
    view.runPostTurnEnd(.{ .invocation = testInvocation(.interactive), .outcome = .paused });
    Wiring.sync(&app, true, false);

    const records = app.terminal_status.records[0..app.terminal_status.count];
    try testing.expectEqual(@as(usize, 7), records.len);
    try testing.expectEqual(Event.session_changed, records[0].event);
    try testing.expectEqualStrings("active", records[0].session_id.?);
    try testing.expectEqual(Event.working, records[1].event);
    try testing.expectEqual(Event{ .attention_opened = .recovery }, records[2].event);
    try testing.expectEqualStrings("scoped", records[2].session_id.?);
    try testing.expectEqual(Event{ .settled = .failed }, records[3].event);
    try testing.expectEqualStrings("active", records[3].session_id.?);
    try testing.expectEqual(Event{ .settled = .paused }, records[4].event);
    try testing.expectEqual(Event.session_changed, records[5].event);
    try testing.expectEqual(Event{ .child_approval = .{ .waiting = true, .parent_waiting = false } }, records[6].event);
}

test "hooks register nothing when no terminal host is present" {
    const Wiring = Hooks(TestApp, TestApp.activeSessionId);
    var app: TestApp = .{
        .alloc = testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(testing.allocator),
        .terminal_status = .{ .enable_on_init = false },
    };
    defer app.lifecycle_runtime.deinit();

    try Wiring.configure(&app);
    const view = app.lifecycle_runtime.freeze();
    try testing.expect(!view.hasPostTurnEnd());
    try testing.expect(!view.hasAttentionRequired());
    try testing.expect(app.worker.foreground_observer == null);
    try testing.expectEqual(@as(usize, 0), app.terminal_status.count);
}
