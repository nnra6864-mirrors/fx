//! Otty terminal host: renders foreground status through the `otty state`
//! CLI. Each report is a bounded child process; Otty's IPC timeout and a hard
//! child deadline keep a hung CLI from blocking the publisher.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../../core/shared/io.zig");
const debug_trace = @import("../../../core/shared/debug_trace.zig");
const status_mod = @import("../status.zig");

const Status = status_mod.Status;

const native_supported = builtin.os.tag == .macos or builtin.os.tag == .linux;
const session_prefix = "session-id=";
const child_timeout: std.Io.Clock.Duration = .{
    .clock = .awake,
    .raw = .fromMilliseconds(400),
};

const WireState = enum { processing, idle, awaiting, @"error" };

fn wireFor(status: Status) WireState {
    return switch (status.activity) {
        .working => .processing,
        .idle => .idle,
        .waiting => .awaiting,
        .failed => .@"error",
    };
}

pub const Host = struct {
    pid_buffer: [32]u8 = undefined,
    pid_len: usize = 0,

    pub fn shouldEnable(fx_otty: ?[]const u8, term_program: ?[]const u8) bool {
        if (!native_supported) return false;
        if (fx_otty) |value| {
            if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false")) return false;
        }
        return std.mem.eql(u8, term_program orelse return false, "otty");
    }

    pub fn detect(alloc: std.mem.Allocator) ?Host {
        _ = alloc;
        if (comptime !native_supported) return null;
        if (!shouldEnable(io_mod.getenv("FX_OTTY"), io_mod.getenv("TERM_PROGRAM"))) return null;
        var host: Host = .{};
        const pid_arg = std.fmt.bufPrint(&host.pid_buffer, "agent-pid={d}", .{std.c.getpid()}) catch return null;
        host.pid_len = pid_arg.len;
        return host;
    }

    pub fn deinit(self: *Host) void {
        _ = self;
    }

    /// Reports only changes Otty can show: its state or the session.
    pub fn render(self: *Host, prev: ?Status, now: Status) void {
        if (comptime !native_supported) return;
        if (prev) |previous| {
            if (wireFor(previous) == wireFor(now) and status_mod.SessionId.eql(previous.session, now.session)) return;
        }
        var session_buffer: [session_prefix.len + status_mod.SessionId.max_len]u8 = undefined;
        const session_arg: ?[]const u8 = if (now.session) |*session|
            std.fmt.bufPrint(&session_buffer, session_prefix ++ "{s}", .{session.slice()}) catch null
        else
            null;
        var argv_buffer: [9][]const u8 = undefined;
        send(io_mod.getIo(), reportArgv(&argv_buffer, wireFor(now), session_arg, self.pid_buffer[0..self.pid_len]));
    }

    /// Otty clears the custom agent when its process exits.
    pub fn stop(self: *Host) void {
        _ = self;
    }
};

// The returned argv borrows the buffer, the session argument, and the PID argument.
fn reportArgv(buffer: *[9][]const u8, state: WireState, session_arg: ?[]const u8, pid_arg: []const u8) []const []const u8 {
    const state_arg = switch (state) {
        inline else => |tag| "state=" ++ @tagName(tag),
    };
    // The colon shorthand is not recognized after global options.
    // Use the regular subcommand so the global IPC timeout is honored.
    buffer[0..7].* = .{ "otty", "--timeout", "200", "state", "fx", state_arg, pid_arg };
    var len: usize = 7;
    if (session_arg) |arg| {
        buffer[len] = arg;
        len += 1;
    }
    buffer[len] = "label=fx";
    return buffer[0 .. len + 1];
}

const ChildEvent = union(enum) {
    wait: std.process.Child.WaitError!std.process.Child.Term,
    timeout: std.Io.Cancelable!void,
};

fn wait_child(child: *std.process.Child, io: std.Io) std.process.Child.WaitError!std.process.Child.Term {
    return child.wait(io);
}

fn wait_deadline(io: std.Io, deadline: std.Io.Clock.Timestamp) std.Io.Cancelable!void {
    return std.Io.Timeout.sleep(.{ .deadline = deadline }, io);
}

fn schedule_child_wait(select: *std.Io.Select(ChildEvent), child: *std.process.Child) std.Io.ConcurrentError!void {
    const io = select.io;
    select.concurrent(.wait, wait_child, .{ child, io }) catch |err| {
        // No wait task owns the child yet. Child.kill alone can block on SIGTERM.
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        std.posix.kill(child.id.?, .KILL) catch {};
        _ = child.wait(io) catch {};
        return err;
    };
}

// Do not cancel the pending wait before killing: it owns collection of the
// child. Block cancellation until that wait has finished reaping the process.
fn stop_child(select: *std.Io.Select(ChildEvent), pid: std.process.Child.Id) void {
    const io = select.io;
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    std.posix.kill(pid, .KILL) catch {};
    while (select.await()) |event| {
        if (event == .wait) break;
    } else |_| {}
    select.cancelDiscard();
}

fn send(io: std.Io, argv: []const []const u8) void {
    const deadline = std.Io.Clock.Timestamp.fromNow(io, child_timeout);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        debug_trace.logf("otty", "report spawn failed err={s}", .{@errorName(err)});
        return;
    };
    defer child.kill(io);
    const pid = child.id.?;
    var select_buffer: [2]ChildEvent = undefined;
    var select: std.Io.Select(ChildEvent) = .init(io, &select_buffer);
    schedule_child_wait(&select, &child) catch return;
    select.concurrent(.timeout, wait_deadline, .{ io, deadline }) catch {
        stop_child(&select, pid);
        return;
    };
    const event = select.await() catch {
        stop_child(&select, pid);
        return;
    };
    switch (event) {
        .wait => |result| {
            select.cancelDiscard();
            const term = result catch |err| {
                debug_trace.logf("otty", "report wait failed err={s}", .{@errorName(err)});
                return;
            };
            switch (term) {
                .exited => |code| debug_trace.logf("otty", "report exit status={d}", .{code}),
                else => debug_trace.logf("otty", "report terminated unexpectedly", .{}),
            }
        },
        .timeout => {
            debug_trace.logf("otty", "report timed out", .{});
            stop_child(&select, pid);
        },
    }
}

test "otty wait scheduling failure kills and reaps a SIGTERM-ignoring child" {
    if (comptime !native_supported) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; printf ready; exec /bin/sleep 5" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer {
        if (child.id) |pid| std.posix.kill(pid, .KILL) catch {};
        child.kill(io);
    }
    const pid = child.id.?;
    var buffer: [16]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    var ready: [5]u8 = undefined;
    try reader.interface.readSliceAll(&ready);
    try std.testing.expectEqualStrings("ready", &ready);

    var vtable = io.vtable.*;
    vtable.groupConcurrent = struct {
        fn fail(
            _: ?*anyopaque,
            _: *std.Io.Group,
            _: []const u8,
            _: std.mem.Alignment,
            _: *const fn (*const anyopaque) void,
        ) std.Io.ConcurrentError!void {
            return error.ConcurrencyUnavailable;
        }
    }.fail;
    var select_buffer: [2]ChildEvent = undefined;
    var select: std.Io.Select(ChildEvent) = .init(.{ .userdata = io.userdata, .vtable = &vtable }, &select_buffer);
    defer select.cancelDiscard();
    const start = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.ConcurrencyUnavailable, schedule_child_wait(&select, &child));
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 2000);
    try std.testing.expectEqual(null, child.id);
    try std.testing.expectEqual(null, child.stdout);
    var status: c_int = undefined;
    const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(waited));
}

test "otty enablement requires its terminal and respects explicit opt-out" {
    try std.testing.expectEqual(native_supported, Host.shouldEnable(null, "otty"));
    try std.testing.expectEqual(native_supported, Host.shouldEnable("1", "otty"));
    try std.testing.expect(!Host.shouldEnable("0", "otty"));
    try std.testing.expect(!Host.shouldEnable("FaLsE", "otty"));
    try std.testing.expect(!Host.shouldEnable(null, null));
    try std.testing.expect(!Host.shouldEnable("true", "other"));
}

test "otty argv uses fixed arguments and an optional literal session" {
    var buffer: [9][]const u8 = undefined;
    const without_session = reportArgv(&buffer, .@"error", null, "agent-pid=42");
    const expected = [_][]const u8{ "otty", "--timeout", "200", "state", "fx", "state=error", "agent-pid=42", "label=fx" };
    try std.testing.expectEqual(expected.len, without_session.len);
    for (expected, without_session) |want, actual| try std.testing.expectEqualStrings(want, actual);

    const with_session = reportArgv(&buffer, .awaiting, "session-id=a b;$(ignored)", "agent-pid=42");
    try std.testing.expectEqual(@as(usize, 9), with_session.len);
    try std.testing.expectEqualStrings("state=awaiting", with_session[5]);
    try std.testing.expectEqualStrings("session-id=a b;$(ignored)", with_session[7]);
    try std.testing.expectEqualStrings("label=fx", with_session[8]);
}

test "status maps to otty states" {
    try std.testing.expectEqual(WireState.processing, wireFor(.{ .activity = .working }));
    try std.testing.expectEqual(WireState.idle, wireFor(.{ .activity = .idle }));
    try std.testing.expectEqual(WireState.awaiting, wireFor(.{ .activity = .waiting, .attention = .question }));
    try std.testing.expectEqual(WireState.@"error", wireFor(.{ .activity = .failed }));
}
