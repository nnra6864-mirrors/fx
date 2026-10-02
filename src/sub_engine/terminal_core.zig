//! The pure core of one terminal: its lifecycle, its queue of unsent bytes
//! and the child's exit status. It makes no syscalls and reads no clock.
//!
//! The shell (`terminal.zig`) asks the core before every fd operation and
//! every signal, and reports what the kernel did. The core refuses anything
//! its state does not allow, so the shell cannot use a closed fd, wait for
//! the child twice or signal a reaped child.
//!
//! Transitions: `queue`, `flushed`, `checkOpen` (before a read, write or
//! resize), `reap`, `closeStart`, `kill`, `closeFinish`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Unsent bytes allowed at once. A child that stops reading cannot make the
/// owner buffer without bound.
const max_pending_bytes: usize = 1 << 20;

const Phase = enum { running, closing, closed };

/// How the child ended.
pub const Exit = union(enum) {
    /// The child exited with this status.
    code: u8,
    /// A signal with this number killed the child.
    signal: u8,
};

pub const Core = struct {
    phase: Phase = .running,
    exit: ?Exit = null,
    /// Unsent bytes are `out.items[head..]`, oldest first.
    out: std.ArrayList(u8) = .empty,
    head: usize = 0,

    /// Frees the queue. Safe in any phase.
    pub fn deinit(self: *Core, gpa: Allocator) void {
        self.out.deinit(gpa);
        self.* = undefined;
    }

    /// Adds bytes to the end of the queue. Fails without queueing any of
    /// them when the terminal is closing or the queue would grow past
    /// `max_pending_bytes`.
    pub fn queue(
        self: *Core,
        gpa: Allocator,
        bytes: []const u8,
    ) error{ Closed, QueueFull, OutOfMemory }!void {
        if (self.phase != .running) return error.Closed;
        if (bytes.len > max_pending_bytes - self.pending().len) return error.QueueFull;
        if (self.head > 0) {
            const rest = self.out.items[self.head..];
            std.mem.copyForwards(u8, self.out.items[0..rest.len], rest);
            self.out.shrinkRetainingCapacity(rest.len);
            self.head = 0;
        }
        try self.out.appendSlice(gpa, bytes);
    }

    /// The bytes to write next, oldest first. Empty unless running.
    pub fn pending(self: Core) []const u8 {
        if (self.phase != .running) return &.{};
        return self.out.items[self.head..];
    }

    /// Records that the kernel took the first `n` pending bytes.
    pub fn flushed(self: *Core, n: usize) void {
        std.debug.assert(self.phase == .running);
        std.debug.assert(n <= self.pending().len);
        self.head += n;
        if (self.head == self.out.items.len) {
            self.out.clearRetainingCapacity();
            self.head = 0;
        }
    }

    /// Allows one fd operation (read, write or resize) only while running.
    pub fn checkOpen(self: Core) error{Closed}!void {
        if (self.phase != .running) return error.Closed;
    }

    /// Whether the child may still be waited for: it has not been reaped.
    /// A second wait could reap an unrelated process that reused the id.
    pub fn mayWait(self: Core) bool {
        return self.exit == null;
    }

    /// Records the exit status that waiting returned.
    pub fn reap(self: *Core, exit: Exit) void {
        std.debug.assert(self.mayWait());
        self.exit = exit;
    }

    /// Starts closing: the fd is no longer usable and the unsent bytes are
    /// dropped. Returns how many were dropped.
    pub fn closeStart(self: *Core, gpa: Allocator) error{Closed}!usize {
        if (self.phase != .running) return error.Closed;
        const dropped = self.pending().len;
        self.phase = .closing;
        self.out.clearAndFree(gpa);
        self.head = 0;
        return dropped;
    }

    /// Allows the SIGKILL that ends a close: only while closing and only
    /// before the reap, so the signal cannot reach a process that reused the
    /// child's id.
    pub fn kill(self: Core) error{ NotClosing, Reaped }!void {
        if (self.phase != .closing) return error.NotClosing;
        if (self.exit != null) return error.Reaped;
    }

    /// Finishes closing. Only allowed after the reap.
    pub fn closeFinish(self: *Core) error{ NotClosing, NotReaped }!void {
        if (self.phase != .closing) return error.NotClosing;
        if (self.exit == null) return error.NotReaped;
        self.phase = .closed;
    }
};

const testing = std.testing;

test "the queue keeps every byte in order through short writes" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    for (0..200) |_| {
        var core: Core = .{};
        defer core.deinit(gpa);
        var sent: std.ArrayList(u8) = .empty;
        defer sent.deinit(gpa);
        var received: std.ArrayList(u8) = .empty;
        defer received.deinit(gpa);

        var next: u8 = 0;
        for (0..40) |_| {
            if (random.boolean()) {
                var chunk: [7]u8 = undefined;
                const len = random.intRangeAtMost(usize, 1, chunk.len);
                for (chunk[0..len]) |*byte| {
                    byte.* = next;
                    next +%= 1;
                }
                try core.queue(gpa, chunk[0..len]);
                try sent.appendSlice(gpa, chunk[0..len]);
            } else if (core.pending().len > 0) {
                const n = random.intRangeAtMost(usize, 1, core.pending().len);
                try received.appendSlice(gpa, core.pending()[0..n]);
                core.flushed(n);
            }
        }
        try received.appendSlice(gpa, core.pending());
        core.flushed(core.pending().len);

        try testing.expectEqualSlices(u8, sent.items, received.items);
        try testing.expectEqual(@as(usize, 0), core.pending().len);
    }
}

test "the queue refuses bytes past the limit without taking any" {
    const gpa = testing.allocator;
    var core: Core = .{};
    defer core.deinit(gpa);

    const big = try gpa.alloc(u8, max_pending_bytes);
    defer gpa.free(big);
    @memset(big, 'x');
    try core.queue(gpa, big);
    try testing.expectError(error.QueueFull, core.queue(gpa, "y"));
    try testing.expectEqual(max_pending_bytes, core.pending().len);

    core.flushed(1);
    try core.queue(gpa, "y");
    try testing.expectEqual(max_pending_bytes, core.pending().len);
}

test "closing drops unsent bytes and stops fd use" {
    const gpa = testing.allocator;
    var core: Core = .{};
    defer core.deinit(gpa);

    try core.queue(gpa, "abcdef");
    core.flushed(2);
    try testing.expectEqual(@as(usize, 4), try core.closeStart(gpa));

    try testing.expectError(error.Closed, core.checkOpen());
    try testing.expectError(error.Closed, core.queue(gpa, "x"));
    try testing.expectError(error.Closed, core.closeStart(gpa));
    try testing.expectEqual(@as(usize, 0), core.pending().len);
}

test "the child is reaped once and never signaled after the reap" {
    const gpa = testing.allocator;
    var core: Core = .{};
    defer core.deinit(gpa);

    try testing.expectError(error.NotClosing, core.kill());
    _ = try core.closeStart(gpa);
    try core.kill();
    try testing.expectError(error.NotReaped, core.closeFinish());

    try testing.expect(core.mayWait());
    core.reap(.{ .signal = 9 });
    try testing.expect(!core.mayWait());
    try testing.expectError(error.Reaped, core.kill());

    try core.closeFinish();
    try testing.expectEqual(Phase.closed, core.phase);
    try testing.expectEqual(Exit{ .signal = 9 }, core.exit.?);
    try testing.expectError(error.NotClosing, core.closeFinish());
}

test "a child that exits while running keeps its status through close" {
    const gpa = testing.allocator;
    var core: Core = .{};
    defer core.deinit(gpa);

    core.reap(.{ .code = 3 });
    try core.checkOpen();
    _ = try core.closeStart(gpa);
    try testing.expectError(error.Reaped, core.kill());
    try core.closeFinish();
    try testing.expectEqual(Exit{ .code = 3 }, core.exit.?);
}

// Random runs of the core against a simulated child. After every step the
// test checks that the child is reaped once and never signaled after the
// reap, that no fd is used after close, that no queued byte is lost while
// running, and that close finishes only after the reap.
//
// With SUB_ENGINE_TRACE_DIR set, each run is also written to that folder as
// JSON lines, one per core transition, for checking against a model outside
// this repository. The simulated child's own steps are not written.

const Child = enum { alive, dead, reaped };

/// What one trace line records after a core transition.
const Snapshot = struct {
    core: *const Core,
    child: Child,
    queued_bytes: usize,
    written_bytes: usize,
};

const Trace = struct {
    gpa: Allocator,
    file: ?std.Io.File,
    offset: u64 = 0,

    fn create(gpa: Allocator, seed: u64) !Trace {
        const dir_path = std.c.getenv("SUB_ENGINE_TRACE_DIR") orelse
            return .{ .gpa = gpa, .file = null };
        const io = testing.io;
        var dir = try std.Io.Dir.cwd().openDir(io, std.mem.span(dir_path), .{});
        defer dir.close(io);
        var name: [64]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&name, "Terminal--seed-{d}.ndjson", .{seed});
        return .{ .gpa = gpa, .file = try dir.createFile(io, file_name, .{ .truncate = true }) };
    }

    fn step(self: *Trace, event: []const u8, snapshot: Snapshot) !void {
        const file = self.file orelse return;
        const core = snapshot.core;
        const line = try std.json.Stringify.valueAlloc(self.gpa, .{
            .event = event,
            .phase = @tagName(core.phase),
            .reaped = snapshot.child == .reaped,
            .exit = if (core.exit) |exit| @tagName(exit) else "none",
            .queued_bytes = snapshot.queued_bytes,
            .pending_bytes = core.pending().len,
            .written_bytes = snapshot.written_bytes,
        }, .{});
        defer self.gpa.free(line);
        try file.writePositionalAll(testing.io, line, self.offset);
        self.offset += line.len;
        try file.writePositionalAll(testing.io, "\n", self.offset);
        self.offset += 1;
    }

    fn finish(self: *Trace) void {
        if (self.file) |file| file.close(testing.io);
    }
};

/// Bytes per queued chunk and chunks per run. The model the traces are
/// checked against uses the same bounds.
const chunk_len = 2;
const max_chunks = 6;

fn runRandom(gpa: Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var trace = try Trace.create(gpa, seed);
    defer trace.finish();

    var core: Core = .{};
    defer core.deinit(gpa);
    var child: Child = .alive;
    const ignores_hup = random.boolean();
    var fd_open = true;
    var chunks: usize = 0;
    var queued: usize = 0;
    var written: usize = 0;
    var signaled_after_reap = false;

    var steps: usize = 0;
    while (core.phase != .closed and steps < 60) : (steps += 1) {
        const event: ?[]const u8 = switch (random.uintLessThan(u8, 9)) {
            0 => if (chunks < max_chunks) queue: {
                const chunk = [_]u8{@intCast(chunks)} ** chunk_len;
                core.queue(gpa, &chunk) catch |err| {
                    try testing.expectEqual(error.Closed, err);
                    break :queue null;
                };
                chunks += 1;
                queued += chunk_len;
                break :queue "Queue";
            } else null,
            1 => if (core.pending().len > 0) flush: {
                try core.checkOpen();
                const n = random.intRangeAtMost(usize, 1, core.pending().len);
                core.flushed(n);
                written += n;
                break :flush "Flush";
            } else null,
            2, 3 => |kind| if (core.checkOpen()) used: {
                try testing.expect(fd_open);
                break :used if (kind == 2) "Read" else "Resize";
            } else |_| null,
            // The shell waits only when the core allows it, and the wait
            // reaps only a child that has exited.
            4 => if (core.mayWait() and child == .dead) reap: {
                core.reap(if (random.boolean()) .{ .code = 0 } else .{ .signal = 9 });
                child = .reaped;
                break :reap "Reap";
            } else null,
            5 => if (core.closeStart(gpa)) |_| close_start: {
                fd_open = false;
                break :close_start "CloseStart";
            } else |_| null,
            6 => if (core.kill()) kill: {
                if (child == .reaped) signaled_after_reap = true;
                if (child == .alive) child = .dead;
                break :kill "Kill";
            } else |_| null,
            7 => if (core.closeFinish()) "CloseFinish" else |_| null,
            // The child may exit at any time, and the hangup ends it unless
            // it ignores SIGHUP.
            else => child: {
                if (child == .alive and (random.uintLessThan(u8, 4) == 0 or (!fd_open and !ignores_hup))) {
                    child = .dead;
                }
                break :child null;
            },
        };
        if (event) |name| try trace.step(name, .{
            .core = &core,
            .child = child,
            .queued_bytes = queued,
            .written_bytes = written,
        });

        try testing.expect(!signaled_after_reap);
        try testing.expect(core.phase == .running or !fd_open);
        try testing.expect(written + core.pending().len <= queued);
        if (core.phase == .running) try testing.expectEqual(queued, written + core.pending().len);
        if (core.phase == .closed) try testing.expectEqual(Child.reaped, child);
        try testing.expectEqual(child == .reaped, core.exit != null);
    }
}

test "random runs keep the terminal's lifecycle invariants" {
    for (0..64) |seed| try runRandom(testing.allocator, seed);
}
