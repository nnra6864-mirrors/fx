const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const supported = std.process.can_spawn and switch (builtin.os.tag) {
    .windows, .freestanding, .emscripten, .other => false,
    else => true,
};

/// Owns the only wait for a child. Cancellation must kill before joining, never
/// cancel Child.wait: the POSIX backend discards its PID even on cancellation.
pub const ChildWaiter = struct {
    child: *std.process.Child,
    io: std.Io,
    ready: std.atomic.Value(bool) = .init(false),
    result: std.process.Child.WaitError!std.process.Child.Term = undefined,
    future: ?std.Io.Future(void) = null,

    pub fn init(child: *std.process.Child) ChildWaiter {
        return .{ .child = child, .io = io_mod.getIo() };
    }

    pub fn start(self: *ChildWaiter) !void {
        if (comptime !supported) return error.OperationUnsupported;
        self.future = try std.Io.concurrent(self.io, waitMain, .{self});
    }

    fn waitMain(self: *ChildWaiter) void {
        const protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(protection);
        self.result = self.child.wait(self.io);
        self.ready.store(true, .release);
    }

    pub fn isReady(self: *const ChildWaiter) bool {
        return self.ready.load(.acquire);
    }

    pub fn awaitReady(self: *ChildWaiter) !std.process.Child.Term {
        std.debug.assert(self.isReady());
        self.awaitDiscard();
        return try self.result;
    }

    pub fn awaitDiscard(self: *ChildWaiter) void {
        self.future.?.await(self.io);
    }

    pub fn abort(self: *ChildWaiter, pid: std.process.Child.Id) void {
        if (comptime !supported) unreachable; // start rejects this backend.
        if (!self.isReady()) {
            std.posix.kill(pid, .KILL) catch {};
        }
        self.awaitDiscard();
    }
};

pub const Options = struct {
    argv: []const []const u8,
    stdin: ?[]const u8 = null,
    stdout_limit: usize,
    stderr_limit: usize = 4096,
    timeout_ms: ?u64,
    cancel_flag: ?*const std.atomic.Value(bool) = null,
};

/// Runs a trusted helper with bounded output. All arguments/input are borrowed
/// until return; the caller owns the two returned output buffers, including
/// zeroing them when they contain credentials. Stop owns both child and pipes.
pub fn run(alloc: std.mem.Allocator, options: Options) !std.process.RunResult {
    if (comptime !supported) return error.OperationUnsupported;
    const io = io_mod.getIo();
    try io.checkCancel();
    if (options.cancel_flag) |flag| if (flag.load(.acquire)) return error.Cancelled;
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .stdin = if (options.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    const pid = child.id.?;
    const stdout = child.stdout.?;
    const stderr = child.stderr.?;
    var stdin = child.stdin;
    child.stdout = null;
    child.stderr = null;
    child.stdin = null;
    defer stdout.close(io);
    defer stderr.close(io);
    defer if (stdin) |input| input.close(io);

    var waiter = ChildWaiter.init(&child);
    waiter.start() catch |err| {
        std.posix.kill(-pid, .KILL) catch {};
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        _ = child.wait(io) catch {};
        return err;
    };
    defer {
        if (!waiter.isReady()) std.posix.kill(-pid, .KILL) catch {};
        waiter.abort(pid);
    }

    var input_task: ?std.Io.Future(anyerror!void) = if (stdin) |input|
        try std.Io.concurrent(io, writeInput, .{ input, options.stdin.? })
    else
        null;
    stdin = null;
    defer if (input_task) |*task| task.cancel(io) catch {};

    var storage: std.Io.File.MultiReader.Buffer(2) = undefined;
    var output: std.Io.File.MultiReader = undefined;
    output.init(alloc, io, storage.toStreams(), &.{ stdout, stderr });
    defer {
        // Failed captures can contain credentials too, not only successful ones.
        output.batch.cancel(io);
        for (0..2) |index| std.crypto.secureZero(u8, output.reader(index).buffer);
        output.deinit();
    }
    const deadline: ?std.Io.Clock.Timestamp = if (options.timeout_ms) |timeout_ms| std.Io.Clock.Timestamp.fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(@intCast(timeout_ms)),
    }) else null;
    var output_done = false;
    while (!output_done or !waiter.isReady()) {
        try io.checkCancel();
        if (options.cancel_flag) |flag| if (flag.load(.acquire)) return error.Cancelled;
        if (deadline) |limit| if (std.Io.Clock.Timestamp.compare(.now(io, .awake), .gte, limit)) return error.Timeout;
        if (output_done) {
            try io.sleep(.fromMilliseconds(5), .awake);
        } else {
            output.fill(4096, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(5) } }) catch |err| switch (err) {
                error.EndOfStream => output_done = true,
                error.Timeout => {},
                else => return err,
            };
        }
        if (output.reader(0).bufferedLen() > options.stdout_limit or
            output.reader(1).bufferedLen() > options.stderr_limit) return error.StreamTooLong;
    }
    try output.checkAnyError();
    if (input_task) |*task| try task.await(io);
    const term = try waiter.awaitReady();
    const out = try output.toOwnedSlice(0);
    errdefer {
        std.crypto.secureZero(u8, out);
        alloc.free(out);
    }
    return .{ .term = term, .stdout = out, .stderr = try output.toOwnedSlice(1) };
}

fn writeInput(input: std.Io.File, bytes: []const u8) anyerror!void {
    defer input.close(io_mod.getIo());
    try input.writeStreamingAll(io_mod.getIo(), bytes);
}

test "helper stdin and bounded output preserve binary credential bytes" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const value = "secret\x00with\nnewlines\r\xff" ** 8192;
    const result = try run(std.testing.allocator, .{
        .argv = &.{ "/usr/bin/python3", "-c", "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())" },
        .stdin = value,
        .stdout_limit = value.len,
        .timeout_ms = 10_000,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expectEqualSlices(u8, value, result.stdout);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
}
