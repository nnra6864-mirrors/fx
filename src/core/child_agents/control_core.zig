//! The pure core of the subagent runtime: which names hold which children,
//! and what each child has reported.
//!
//! A child is found by its name for tool calls and by its terminal's id for
//! the terminal's events. A name is reserved before its terminal starts, so
//! parallel launches cannot take the same name or pass the limit, and it is
//! freed only after the terminal is closed, so no running child is left
//! without a name.

const std = @import("std");
const sub_engine = @import("sub_engine");
const labels_mod = @import("labels.zig");

const Allocator = std.mem.Allocator;

/// Children alive at once.
pub const max_children = sub_engine.max_terminals;
pub const max_name_bytes = 32;

pub const Phase = enum {
    /// Reserved; the terminal is starting or the task is not typed yet.
    starting,
    ready,
    /// Being stopped; it takes no input.
    stopping,
};

pub const Child = struct {
    name_buf: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    phase: Phase = .starting,
    /// The child's terminal, once it started.
    id: ?sub_engine.Id = null,
    labels: labels_mod.Labels = .{},
    exit: ?sub_engine.Exit = null,
    /// Messages typed into the child.
    typed: u64 = 0,
    /// A tool call is typing into the child. One message is typed at a
    /// time, so two messages never mix.
    typing: bool = false,

    pub fn name(self: *const Child) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// The child can read input, or will never read any.
    pub fn started(self: *const Child) bool {
        return self.exit != null or self.labels.state != .starting;
    }

    /// Every message typed into the child has been reported.
    pub fn delivered(self: *const Child) bool {
        return self.labels.messages_total >= self.typed;
    }

    /// The child exited, or it reported everything typed into it and is
    /// idle or blocked.
    pub fn settled(self: *const Child) bool {
        if (self.exit != null) return true;
        return self.delivered() and (self.labels.state == .idle or self.labels.state == .blocked);
    }
};

/// Lowercase letters, digits, '-' and '_', starting with a letter or digit.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    if (!std.ascii.isLower(name[0]) and !std.ascii.isDigit(name[0])) return false;
    for (name) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}

pub const ReserveError = error{ InvalidName, NameTaken, LimitReached };

pub const Table = struct {
    slots: [max_children]?Child = [_]?Child{null} ** max_children,

    pub fn deinit(self: *Table, gpa: Allocator) void {
        for (&self.slots) |*slot| {
            if (slot.*) |*child| child.labels.deinit(gpa);
            slot.* = null;
        }
    }

    /// Reserves `name` for a child that is about to start.
    pub fn reserve(self: *Table, name: []const u8) ReserveError!usize {
        if (!validName(name)) return error.InvalidName;
        if (self.find(name) != null) return error.NameTaken;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.* != null) continue;
            slot.* = .{};
            const child = &slot.*.?;
            @memcpy(child.name_buf[0..name.len], name);
            child.name_len = name.len;
            return index;
        }
        return error.LimitReached;
    }

    /// The reserved child's terminal started.
    pub fn opened(self: *Table, slot: usize, id: sub_engine.Id) void {
        self.slots[slot].?.id = id;
    }

    /// The child's task was typed, or it exited before it could be.
    pub fn markReady(self: *Table, slot: usize) void {
        self.slots[slot].?.phase = .ready;
    }

    /// One message was typed into the child.
    pub fn typedOne(self: *Table, slot: usize) void {
        self.slots[slot].?.typed += 1;
    }

    /// Claims the child for typing. False while another call is typing.
    pub fn beginTyping(self: *Table, slot: usize) bool {
        const child = &self.slots[slot].?;
        if (child.typing) return false;
        child.typing = true;
        return true;
    }

    pub fn endTyping(self: *Table, slot: usize) void {
        self.slots[slot].?.typing = false;
    }

    /// Starts stopping a ready child. Returns its slot.
    pub fn markStopping(self: *Table, name: []const u8) error{NotFound}!usize {
        const slot = self.find(name) orelse return error.NotFound;
        const child = &self.slots[slot].?;
        if (child.phase != .ready) return error.NotFound;
        child.phase = .stopping;
        return slot;
    }

    /// Frees the name. Call once the child's terminal is closed, or never
    /// started.
    pub fn free(self: *Table, gpa: Allocator, slot: usize) void {
        self.slots[slot].?.labels.deinit(gpa);
        self.slots[slot] = null;
    }

    pub fn get(self: *Table, slot: usize) *Child {
        return &self.slots[slot].?;
    }

    pub fn find(self: *const Table, name: []const u8) ?usize {
        for (&self.slots, 0..) |*slot, index| {
            const child = &(slot.* orelse continue);
            if (std.mem.eql(u8, child.name(), name)) return index;
        }
        return null;
    }

    pub fn findId(self: *const Table, id: sub_engine.Id) ?usize {
        for (&self.slots, 0..) |*slot, index| {
            const child = &(slot.* orelse continue);
            if (child.id) |child_id| {
                if (std.meta.eql(child_id, id)) return index;
            }
        }
        return null;
    }

    /// Applies one report line from terminal `id`. Lines from a terminal no
    /// name holds are ignored.
    pub fn report(self: *Table, gpa: Allocator, id: sub_engine.Id, line: []const u8) error{ OutOfMemory, InvalidLine }!void {
        const slot = self.findId(id) orelse return;
        try self.slots[slot].?.labels.apply(gpa, line);
    }

    pub fn exited(self: *Table, id: sub_engine.Id, exit: sub_engine.Exit) void {
        const slot = self.findId(id) orelse return;
        self.slots[slot].?.exit = exit;
    }

    pub fn count(self: *const Table) usize {
        var live: usize = 0;
        for (self.slots) |slot| live += @intFromBool(slot != null);
        return live;
    }
};

const testing = std.testing;

fn testId(slot: u8) sub_engine.Id {
    return .{ .slot = slot, .gen = 1 };
}

fn applyEvent(table: *Table, id: sub_engine.Id, event: labels_mod.Event) !void {
    const line = try labels_mod.encode(testing.allocator, event);
    defer testing.allocator.free(line);
    try table.report(testing.allocator, id, line[0 .. line.len - 1]);
}

test "names are checked, unique and limited" {
    var table: Table = .{};
    defer table.deinit(testing.allocator);
    for ([_][]const u8{ "", "Upper", "-lead", "has space", "a" ** (max_name_bytes + 1) }) |bad| {
        try testing.expectError(error.InvalidName, table.reserve(bad));
    }
    var name: [8]u8 = undefined;
    for (0..max_children) |i| _ = try table.reserve(try std.fmt.bufPrint(&name, "c{d}", .{i}));
    try testing.expectError(error.NameTaken, table.reserve("c0"));
    try testing.expectError(error.LimitReached, table.reserve("one-more"));
    table.free(testing.allocator, table.find("c3").?);
    _ = try table.reserve("one-more");
}

test "a child settles once it reported everything typed into it" {
    var table: Table = .{};
    defer table.deinit(testing.allocator);
    const slot = try table.reserve("a1");
    table.opened(slot, testId(0));
    const child = table.get(slot);
    try testing.expect(!child.started());

    try applyEvent(&table, testId(0), .{ .state = .idle });
    try testing.expect(child.started());
    try testing.expect(child.settled());

    // The task is typed: until the child reports it, its old idle does not
    // count.
    table.markReady(slot);
    table.typedOne(slot);
    try testing.expect(!child.settled());
    try applyEvent(&table, testId(0), .{ .message = "task" });
    try testing.expect(!child.settled());
    try applyEvent(&table, testId(0), .{ .turn_end = .{ .final = "done", .next = .idle } });
    try testing.expect(child.settled());

    // Reports from a terminal no name holds change nothing.
    try applyEvent(&table, testId(5), .{ .state = .working });
    try testing.expect(child.settled());

    table.exited(testId(0), .{ .code = 0 });
    table.typedOne(slot);
    try testing.expect(child.settled());
}

test "only a ready child can be stopped" {
    var table: Table = .{};
    defer table.deinit(testing.allocator);
    const slot = try table.reserve("a1");
    try testing.expectError(error.NotFound, table.markStopping("a1"));
    table.markReady(slot);
    try testing.expectEqual(slot, try table.markStopping("a1"));
    try testing.expectError(error.NotFound, table.markStopping("a1"));
    try testing.expectError(error.NotFound, table.markStopping("nobody"));
}

// Random runs drive the table the way the runtime and its children do: two
// tool calls at a time launch, send to, wait on and stop two names while
// simulated children start, take input, report through real label lines,
// block, finish turns and exit. After every step the test checks that input
// is typed only once a child can read it, that a wait never says idle
// before the child finished what it was sent, that nothing is typed after a
// stop, that the limit holds, and that every running child has a name.
//
// With SUB_ENGINE_TRACE_DIR set, each run is also written to that folder as
// JSON lines for checking against a model outside this repository.

/// Children, messages and tool calls per run. The model the traces are
/// checked against uses the same bounds.
const run_names = [_][]const u8{ "a", "b" };
const run_threads = 2;
const run_ids = 6;
const run_messages = 3;
const run_ops = 30;

const Sim = struct {
    const Op = enum { none, launch, send, wait, stop };
    const Call = struct { op: Op = .none, step: u8 = 0, name: usize = 0, id: usize = 0, mark: u64 = 0 };
    const Proc = struct {
        alive: bool = false,
        closed: bool = false,
        ready: bool = false,
        inbox: u64 = 0,
        queue: u64 = 0,
        done: u64 = 0,
        blocked: bool = false,
    };

    gpa: Allocator,
    table: Table = .{},
    procs: [run_ids + 1]Proc = [_]Proc{.{}} ** (run_ids + 1),
    next_id: usize = 1,
    calls: [run_threads]Call = [_]Call{.{}} ** run_threads,
    ops: usize = 0,
    lost: bool = false,
    early: bool = false,
    late: bool = false,

    fn idOf(i: usize) sub_engine.Id {
        return .{ .slot = @intCast(i), .gen = 1 };
    }

    fn modelId(child: *const Child) usize {
        return if (child.id) |id| id.slot else 0;
    }

    fn childOf(self: *Sim, name: usize) ?*Child {
        const slot = self.table.find(run_names[name]) orelse return null;
        return self.table.get(slot);
    }

    fn running(self: *const Sim, i: usize) bool {
        return self.procs[i].alive and !self.procs[i].closed;
    }

    fn reportEvent(self: *Sim, i: usize, event: labels_mod.Event) !void {
        const line = try labels_mod.encode(self.gpa, event);
        defer self.gpa.free(line);
        try self.table.report(self.gpa, idOf(i), line[0 .. line.len - 1]);
    }

    /// One message typed into the child holding `name`.
    fn typeInto(self: *Sim, slot: usize) void {
        const i = modelId(self.table.get(slot));
        self.procs[i].inbox += 1;
        self.table.typedOne(slot);
        self.late = self.late or self.procs[i].closed;
    }

    fn check(self: *Sim) !void {
        try testing.expect(!self.lost and !self.early and !self.late);
        try testing.expect(self.table.count() <= max_children);
        for (self.procs[1..], 1..) |proc, i| {
            if (!(proc.alive and !proc.closed)) continue;
            try testing.expect(self.table.findId(idOf(i)) != null);
        }
    }
};

const ControlTrace = struct {
    gpa: Allocator,
    file: ?std.Io.File,
    offset: u64 = 0,

    fn create(gpa: Allocator, seed: u64) !ControlTrace {
        const dir_path = std.c.getenv("SUB_ENGINE_TRACE_DIR") orelse
            return .{ .gpa = gpa, .file = null };
        const io = testing.io;
        var dir = try std.Io.Dir.cwd().openDir(io, std.mem.span(dir_path), .{});
        defer dir.close(io);
        var name: [64]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&name, "Control--seed-{d}.ndjson", .{seed});
        return .{ .gpa = gpa, .file = try dir.createFile(io, file_name, .{ .truncate = true }) };
    }

    const Rec = struct { phase: []const u8, id: usize };
    const Held = struct { id: usize, state: []const u8, msgs: u64, typed: u64 };
    const PcView = struct { op: []const u8, step: u8, n: []const u8, id: usize, mark: u64 };

    fn step(self: *ControlTrace, event: []const u8, sim: *Sim) !void {
        const file = self.file orelse return;
        var recs: [run_names.len]Rec = undefined;
        var held: std.ArrayList(Held) = .empty;
        defer held.deinit(self.gpa);
        for (run_names, &recs, 0..) |_, *rec, n| {
            rec.* = .{ .phase = "none", .id = 0 };
            const child = sim.childOf(n) orelse continue;
            rec.* = .{ .phase = @tagName(child.phase), .id = Sim.modelId(child) };
            if (child.id != null) try held.append(self.gpa, .{
                .id = rec.id,
                .state = @tagName(child.labels.state),
                .msgs = child.labels.messages_total,
                .typed = child.typed,
            });
        }
        var alive: [run_ids]bool = undefined;
        var closed: [run_ids]bool = undefined;
        var ready: [run_ids]bool = undefined;
        var inbox: [run_ids]u64 = undefined;
        var queue: [run_ids]u64 = undefined;
        var done: [run_ids]u64 = undefined;
        var blocked: [run_ids]bool = undefined;
        for (sim.procs[1..], 0..) |proc, k| {
            alive[k] = proc.alive;
            closed[k] = proc.closed;
            ready[k] = proc.ready;
            inbox[k] = proc.inbox;
            queue[k] = proc.queue;
            done[k] = proc.done;
            blocked[k] = proc.blocked;
        }
        var pcs: [run_threads]PcView = undefined;
        for (sim.calls, &pcs) |call, *pc| pc.* = .{
            .op = @tagName(call.op),
            .step = call.step,
            .n = run_names[call.name],
            .id = call.id,
            .mark = call.mark,
        };
        const line = try std.json.Stringify.valueAlloc(self.gpa, .{
            .event = event,
            .rec = .{ .a = recs[0], .b = recs[1] },
            .held = .{ .@"$set" = held.items },
            .nextId = sim.next_id,
            .alive = alive,
            .closed = closed,
            .ready = ready,
            .inbox = inbox,
            .queue = queue,
            .done = done,
            .blocked = blocked,
            .pc = pcs,
            .ops = sim.ops,
            .lost = sim.lost,
            .early = sim.early,
            .late = sim.late,
        }, .{});
        defer self.gpa.free(line);
        try file.writePositionalAll(testing.io, line, self.offset);
        self.offset += line.len;
        try file.writePositionalAll(testing.io, "\n", self.offset);
        self.offset += 1;
    }

    fn finish(self: *ControlTrace) void {
        if (self.file) |file| file.close(testing.io);
    }
};

/// One enabled step: a tool call's next step, or a child's own step.
const SimStep = union(enum) {
    call: usize,
    child: struct { id: usize, kind: enum { ChildReady, ChildSubmit, ChildBlocks, ChildTurnEnds, ChildExits } },
};

fn runRandom(gpa: Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var sim: Sim = .{ .gpa = gpa };
    defer sim.table.deinit(gpa);
    var trace = try ControlTrace.create(gpa, seed);
    defer trace.finish();

    var steps: std.ArrayList(SimStep) = .empty;
    defer steps.deinit(gpa);
    while (true) {
        steps.clearRetainingCapacity();
        for (sim.calls, 0..) |call, t| {
            if (call.op != .none or sim.ops < run_ops) try steps.append(gpa, .{ .call = t });
        }
        for (sim.procs[1..], 1..) |proc, i| {
            if (!sim.running(i)) continue;
            const child = sim.table.get(sim.table.findId(Sim.idOf(i)).?);
            if (!proc.ready) try steps.append(gpa, .{ .child = .{ .id = i, .kind = .ChildReady } });
            if (proc.ready and proc.inbox > 0) try steps.append(gpa, .{ .child = .{ .id = i, .kind = .ChildSubmit } });
            if (child.labels.state == .working and !proc.blocked) try steps.append(gpa, .{ .child = .{ .id = i, .kind = .ChildBlocks } });
            if (proc.queue > 0) try steps.append(gpa, .{ .child = .{ .id = i, .kind = .ChildTurnEnds } });
            if (random.uintLessThan(u8, 4) == 0) try steps.append(gpa, .{ .child = .{ .id = i, .kind = .ChildExits } });
        }
        if (steps.items.len == 0) break;

        switch (steps.items[random.uintLessThan(usize, steps.items.len)]) {
            .child => |c| {
                const proc = &sim.procs[c.id];
                switch (c.kind) {
                    .ChildReady => {
                        proc.ready = true;
                        try sim.reportEvent(c.id, .{ .state = .idle });
                        sim.lost = sim.lost or proc.inbox > 0;
                        proc.inbox = 0;
                    },
                    .ChildSubmit => {
                        proc.inbox -= 1;
                        proc.queue += 1;
                        try sim.reportEvent(c.id, .{ .message = "m" });
                    },
                    .ChildBlocks => {
                        proc.blocked = true;
                        try sim.reportEvent(c.id, .{ .prompt = .{ .number = 1, .reason = .permission, .body = .{
                            .permission = .{ .label = "shell" },
                        } } });
                    },
                    .ChildTurnEnds => {
                        const next: labels_mod.Activity = if (proc.queue > 1) .working else .idle;
                        proc.queue -= 1;
                        proc.done += 1;
                        try sim.reportEvent(c.id, .{ .turn_end = .{ .final = "f", .next = next } });
                    },
                    .ChildExits => {
                        proc.alive = false;
                        sim.table.exited(Sim.idOf(c.id), .{ .code = 0 });
                    },
                }
                try trace.step(@tagName(c.kind), &sim);
            },
            .call => |t| try stepCall(&sim, &trace, random, t),
        }
        try sim.check();
    }
}

fn stepCall(sim: *Sim, trace: *ControlTrace, random: std.Random, t: usize) !void {
    const call = &sim.calls[t];
    const name = run_names[call.name];
    var event: []const u8 = undefined;
    switch (call.op) {
        .none => {
            call.* = .{
                .op = random.enumValue(Sim.Op),
                .step = 1,
                .name = random.uintLessThan(usize, run_names.len),
            };
            if (call.op == .none) call.op = .wait;
            sim.ops += 1;
            event = "StartCall";
        },
        .launch => switch (call.step) {
            1 => {
                event = "LaunchReserve";
                if (sim.table.reserve(name)) |_| call.step = 2 else |_| call.* = .{};
            },
            2 => {
                // Out of terminal ids, the model's launch waits forever.
                if (sim.next_id > run_ids) return;
                event = "LaunchOpen";
                const i = sim.next_id;
                sim.next_id += 1;
                sim.procs[i].alive = true;
                sim.table.opened(sim.table.find(name).?, Sim.idOf(i));
                call.step = 3;
            },
            3 => {
                const slot = sim.table.find(name).?;
                const child = sim.table.get(slot);
                const i = Sim.modelId(child);
                if (!child.started() and random.uintLessThan(u8, 4) == 0) {
                    event = "LaunchTimeout";
                    sim.procs[i].closed = true;
                    sim.procs[i].alive = false;
                    sim.table.free(sim.gpa, slot);
                    call.* = .{};
                } else if (child.started()) {
                    event = "LaunchTask";
                    sim.table.markReady(slot);
                    if (sim.procs[i].alive) {
                        sim.typeInto(slot);
                        call.step = 4;
                    } else call.* = .{};
                } else return;
            },
            else => {
                event = "Delivered";
                call.* = .{};
            },
        },
        .send => switch (call.step) {
            1 => {
                event = "SendType";
                const slot = sim.table.find(name);
                const child = if (slot) |s| sim.table.get(s) else null;
                if (child != null and child.?.phase == .ready and sim.procs[Sim.modelId(child.?)].alive and
                    child.?.typed < run_messages)
                {
                    sim.typeInto(slot.?);
                    call.step = 4;
                } else call.* = .{};
            },
            else => {
                event = "Delivered";
                call.* = .{};
            },
        },
        .wait => switch (call.step) {
            1 => {
                event = "WaitStart";
                const child = sim.childOf(call.name);
                if (child != null and child.?.phase == .ready) {
                    call.step = 2;
                    call.id = Sim.modelId(child.?);
                    call.mark = child.?.typed;
                } else call.* = .{};
            },
            else => {
                const child = sim.childOf(call.name);
                const same = child != null and child.?.phase == .ready and Sim.modelId(child.?) == call.id;
                if (same and !child.?.settled()) return;
                event = "WaitReturn";
                const proc = sim.procs[call.id];
                if (same and proc.alive and child.?.labels.state == .idle and proc.done < call.mark) sim.early = true;
                call.* = .{};
            },
        },
        .stop => switch (call.step) {
            1 => {
                event = "StopMark";
                if (sim.table.markStopping(name)) |_| call.step = 2 else |_| call.* = .{};
            },
            2 => {
                event = "StopClose";
                const child = sim.childOf(call.name).?;
                const i = Sim.modelId(child);
                sim.procs[i].closed = true;
                sim.procs[i].alive = false;
                sim.table.exited(Sim.idOf(i), .{ .signal = 1 });
                call.step = 3;
            },
            else => {
                event = "StopFree";
                sim.table.free(sim.gpa, sim.table.find(name).?);
                call.* = .{};
            },
        },
    }
    try trace.step(event, sim);
}

test "random runs keep the runtime's rules" {
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) try runRandom(testing.allocator, seed);
}
