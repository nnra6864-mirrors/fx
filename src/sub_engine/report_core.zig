//! The pure core of a terminal's report channel: complete lines framed out
//! of reads of any size.
//!
//! A line ends at a newline, which is not part of it. A line longer than
//! `limit` is dropped whole, up to and including its newline, and so is a
//! line that cannot be buffered. When the writer is gone, `end` drops a
//! partial last line. So the owner only ever sees lines the child finished.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The longest report line delivered, newline excluded.
pub const max_line = 1 << 20;

pub const Emit = struct {
    ctx: *anyopaque,
    /// One complete line. `line` is valid only during the call.
    line: *const fn (ctx: *anyopaque, line: []const u8) void,
};

pub const Lines = struct {
    /// The longest line delivered.
    limit: usize = max_line,
    /// The line being framed, while it has no newline yet.
    buf: std.ArrayList(u8) = .empty,
    /// The line being framed is too long; drop it up to its newline.
    skipping: bool = false,

    pub fn deinit(self: *Lines, gpa: Allocator) void {
        self.buf.deinit(gpa);
        self.* = .{ .limit = self.limit };
    }

    /// Frames `chunk`, calling `emit.line` for each line it completes, in
    /// order.
    pub fn feed(self: *Lines, gpa: Allocator, chunk: []const u8, emit: Emit) void {
        var rest = chunk;
        while (rest.len > 0) {
            const newline = std.mem.findScalar(u8, rest, '\n');
            const part = rest[0 .. newline orelse rest.len];
            if (!self.skipping) {
                if (self.buf.items.len + part.len > self.limit) {
                    self.drop();
                } else if (newline != null and self.buf.items.len == 0) {
                    // A whole line inside this chunk needs no copy.
                    emit.line(emit.ctx, part);
                } else {
                    self.buf.appendSlice(gpa, part) catch self.drop();
                }
            }
            if (newline) |at| {
                if (!self.skipping and self.buf.items.len > 0) emit.line(emit.ctx, self.buf.items);
                self.buf.clearRetainingCapacity();
                self.skipping = false;
                rest = rest[at + 1 ..];
            } else {
                rest = &.{};
            }
        }
    }

    /// The writer is gone: drops a partial last line.
    pub fn end(self: *Lines) void {
        self.buf.clearRetainingCapacity();
        self.skipping = false;
    }

    fn drop(self: *Lines) void {
        self.buf.clearRetainingCapacity();
        self.skipping = true;
    }
};

const testing = std.testing;

const Collected = struct {
    gpa: Allocator,
    lines: std.ArrayList([]u8) = .empty,

    fn emit(self: *Collected) Emit {
        return .{ .ctx = self, .line = line };
    }

    fn line(ctx: *anyopaque, bytes: []const u8) void {
        const self: *Collected = @ptrCast(@alignCast(ctx));
        const copy = self.gpa.dupe(u8, bytes) catch @panic("out of memory");
        self.lines.append(self.gpa, copy) catch @panic("out of memory");
    }

    fn deinit(self: *Collected) void {
        for (self.lines.items) |item| self.gpa.free(item);
        self.lines.deinit(self.gpa);
    }

    fn expect(self: Collected, expected: []const []const u8) !void {
        try testing.expectEqual(expected.len, self.lines.items.len);
        for (expected, self.lines.items) |want, got| try testing.expectEqualStrings(want, got);
    }
};

test "lines split across reads arrive whole and in order" {
    var lines: Lines = .{};
    defer lines.deinit(testing.allocator);
    var got: Collected = .{ .gpa = testing.allocator };
    defer got.deinit();
    for ([_][]const u8{ "fir", "st\nsec", "ond\n", "\nthird\nfour" }) |chunk| {
        lines.feed(testing.allocator, chunk, got.emit());
    }
    try got.expect(&.{ "first", "second", "", "third" });
}

test "a line over the limit is dropped up to its newline" {
    var lines: Lines = .{ .limit = 4 };
    defer lines.deinit(testing.allocator);
    var got: Collected = .{ .gpa = testing.allocator };
    defer got.deinit();
    for ([_][]const u8{ "four\nlo", "ng", "er\nok\nfive5\n", "x\n" }) |chunk| {
        lines.feed(testing.allocator, chunk, got.emit());
    }
    try got.expect(&.{ "four", "ok", "x" });
}

test "a partial line is dropped when the writer is gone" {
    var lines: Lines = .{};
    defer lines.deinit(testing.allocator);
    var got: Collected = .{ .gpa = testing.allocator };
    defer got.deinit();
    lines.feed(testing.allocator, "whole\npart", got.emit());
    lines.end();
    try got.expect(&.{"whole"});
    try testing.expectEqual(@as(usize, 0), lines.buf.items.len);
}

// Random runs drive the core the way a terminal's report channel does: a
// simulated child writes a script of lines one byte at a time and may exit
// mid-line, the reader frames reads of 1 to `read_max` bytes, drains the
// channel and ends the lines when it sees the exit, and the owner may close
// first. After every step the test checks that every delivered line is a
// whole, short line the child finished, in order, and that when the exit is
// reported every such line has been delivered.
//
// With SUB_ENGINE_TRACE_DIR set, each run is also written to that folder as
// JSON lines for checking against a model outside this repository.

/// The longest delivered line and the largest read in a run. The model the
/// traces are checked against uses the same bounds.
const trace_limit = 2;
const read_max = 3;

const Phase = enum { open, exited, closed };

const Run = struct {
    gpa: Allocator,
    script: []const usize,
    stream: []const u8,
    sent: usize = 0,
    read: usize = 0,
    alive: bool = true,
    phase: Phase = .open,
    lines: Lines = .{ .limit = trace_limit },
    got: Collected,

    /// The lines the child has finished that are short enough, in order.
    fn deliverable(self: Run, out: *std.ArrayList(usize)) !void {
        var end: usize = 0;
        for (self.script) |len| {
            end += len + 1;
            if (end <= self.sent and len <= trace_limit) try out.append(self.gpa, len);
        }
    }

    fn check(self: Run) !void {
        var expected: std.ArrayList(usize) = .empty;
        defer expected.deinit(self.gpa);
        try self.deliverable(&expected);
        const got = self.got.lines.items;
        try testing.expect(got.len <= expected.items.len);
        if (self.phase == .exited) try testing.expectEqual(expected.items.len, got.len);
        // Each line is all one letter, so its content shows it is whole.
        for (got, expected.items[0..got.len]) |line, len| {
            try testing.expectEqual(len, line.len);
            if (line.len > 0) for (line) |byte| try testing.expectEqual(line[0], byte);
        }
    }
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
        const file_name = try std.fmt.bufPrint(&name, "Lines--seed-{d}.ndjson", .{seed});
        return .{ .gpa = gpa, .file = try dir.createFile(io, file_name, .{ .truncate = true }) };
    }

    fn line(self: *Trace, value: anytype) !void {
        const file = self.file orelse return;
        const text = try std.json.Stringify.valueAlloc(self.gpa, value, .{});
        defer self.gpa.free(text);
        try file.writePositionalAll(testing.io, text, self.offset);
        self.offset += text.len;
        try file.writePositionalAll(testing.io, "\n", self.offset);
        self.offset += 1;
    }

    fn step(self: *Trace, event: []const u8, run: *const Run) !void {
        if (self.file == null) return;
        var lens: std.ArrayList(usize) = .empty;
        defer lens.deinit(self.gpa);
        for (run.got.lines.items) |item| try lens.append(self.gpa, item.len);
        try self.line(.{
            .event = event,
            .sent = run.sent,
            .alive = run.alive,
            .pipe_len = run.sent - run.read,
            .buf_len = run.lines.buf.items.len,
            .skipping = run.lines.skipping,
            .delivered = lens.items,
            .phase = @tagName(run.phase),
        });
    }

    fn finish(self: *Trace) void {
        if (self.file) |file| file.close(testing.io);
    }
};

fn runRandom(gpa: Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var script: [5]usize = undefined;
    const line_count = random.intRangeAtMost(usize, 1, script.len);
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    for (script[0..line_count], 0..) |*len, index| {
        len.* = random.uintAtMost(usize, trace_limit + 1);
        try stream.appendNTimes(gpa, @intCast('a' + index), len.*);
        try stream.append(gpa, '\n');
    }

    var run: Run = .{
        .gpa = gpa,
        .script = script[0..line_count],
        .stream = stream.items,
        .got = .{ .gpa = gpa },
    };
    defer run.lines.deinit(gpa);
    defer run.got.deinit();
    var trace = try Trace.create(gpa, seed);
    defer trace.finish();
    try trace.line(.{ .event = "Start", .script = run.script });

    while (run.phase == .open) {
        switch (random.uintLessThan(u8, 6)) {
            0, 1 => if (run.alive and run.sent < run.stream.len) {
                run.sent += 1;
                try trace.step("ChildWrite", &run);
            },
            2 => if (run.alive and random.uintLessThan(u8, 4) == 0) {
                run.alive = false;
                try trace.step("ChildExits", &run);
            },
            3, 4 => if (run.read < run.sent) {
                const n = random.intRangeAtMost(usize, 1, @min(read_max, run.sent - run.read));
                run.lines.feed(gpa, run.stream[run.read..][0..n], run.got.emit());
                run.read += n;
                try trace.step("Feed", &run);
            },
            else => if (!run.alive) {
                run.lines.feed(gpa, run.stream[run.read..run.sent], run.got.emit());
                run.read = run.sent;
                run.lines.end();
                run.phase = .exited;
                try trace.step("ReportExit", &run);
            } else if (random.uintLessThan(u8, 8) == 0) {
                run.phase = .closed;
                try trace.step("Close", &run);
            },
        }
        // A child that wrote everything exits.
        if (run.alive and run.sent == run.stream.len and random.boolean()) {
            run.alive = false;
            try trace.step("ChildExits", &run);
        }
        try run.check();
    }
}

test "random runs keep the report channel's rules" {
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) try runRandom(testing.allocator, seed);
}
