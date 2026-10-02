//! The ACP side of the libfx journal. A journaled session sends each event
//! to the host as a `libfx/journal_append` notification, in `seq` order, and
//! opens from the events the host stored through `libfx/journal_open`.
//! The events themselves are `core/agent/runtime/journal.zig`'s.
const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const journal = @import("../core/agent/runtime/journal.zig");
const session_runtime = @import("../core/session/session.zig");
const session_codec = @import("../core/session/session_codec.zig");
const types = @import("../core/shared/types.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const session_adapter = @import("../core/session/session_adapter.zig");
const checkpoint_codec = @import("../core/agent/runtime/checkpoint.zig");

const Allocator = std.mem.Allocator;

pub const Event = journal.Event;
pub const max_load_bytes = journal.max_load_bytes;
/// What the model is told when libfx continues a turn a crash left open.
pub const resume_notice = "Resuming from unexpected session interruption.";

/// One session's journal. Its owner serializes every call with the
/// session's write mutex, so events reach the host in `seq` order.
pub const Journal = struct {
    /// The connection's writer, which outlives every session on it.
    writer: *jsonrpc.Writer,
    cursor: journal.Cursor = .{},
    /// Whether the last progress event still stands, as the fold sees it.
    progress_open: bool = false,
    /// The turn a crash left open, its running calls answered, until the
    /// host resumes it or starts another turn. Owned by the session's
    /// allocator.
    pending_resume: ?session_codec.RecoveryCheckpoint = null,
    /// Set when a turn starts: its first progress carries the prompt, or the
    /// resolution of a resumed turn, and must be stored before the model
    /// sees it. Also set when the next progress places inputs.
    barrier_next_progress: bool = false,
    /// Inputs taken for the next model request; its progress places them.
    /// Owned by the session's allocator.
    placed_next: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Inputs the pending resume accepted and never placed, in order. Owned
    /// by the session's allocator.
    pending_inputs: []journal.PendingInput = &.{},
    /// Follow-ups the journal holds that no turn ran, until the host takes
    /// them. Owned by the session's allocator.
    pending_follow_ups: []journal.PendingInput = &.{},
    /// Accepted follow-ups no turn has placed yet. A snapshot waits for none.
    follow_ups_waiting: usize = 0,
    /// Whether `placed_next` holds the follow-up the running turn runs; it
    /// stops waiting only when a progress places it.
    placing_follow_up: bool = false,
    /// The host's config hash, and the last one the journal recorded. Owned
    /// by the session's allocator.
    host_config: ?[]u8 = null,
    recorded_config: ?[]u8 = null,

    pub fn deinit(self: *Journal, alloc: Allocator) void {
        self.dropPendingResume(alloc);
        self.clearPlaced(alloc);
        self.placed_next.deinit(alloc);
        journal.freePendingInputs(alloc, self.takeFollowUps());
        if (self.host_config) |hash| alloc.free(hash);
        if (self.recorded_config) |hash| alloc.free(hash);
    }

    /// Records the host's config hash when a turn starts under one the
    /// journal has not recorded, so a later resume can tell.
    pub fn noteConfig(self: *Journal, alloc: Allocator, session_alloc: Allocator, session_id: []const u8) !void {
        const hash = self.host_config orelse return;
        if (self.recorded_config) |recorded| if (std.mem.eql(u8, recorded, hash)) return;
        const recorded = try session_alloc.dupe(u8, hash);
        errdefer session_alloc.free(recorded);
        try self.append(alloc, session_id, .{ .session_config = hash });
        if (self.recorded_config) |old| session_alloc.free(old);
        self.recorded_config = recorded;
    }

    /// Hands the follow-ups the journal held to the caller, who owns them.
    pub fn takeFollowUps(self: *Journal) []journal.PendingInput {
        const follow_ups = self.pending_follow_ups;
        self.pending_follow_ups = &.{};
        return follow_ups;
    }

    pub fn dropPendingResume(self: *Journal, alloc: Allocator) void {
        if (self.pending_resume) |*checkpoint| checkpoint.deinit(alloc);
        self.pending_resume = null;
        if (self.pending_inputs.len > 0) {
            debug_trace.logf("session", "event=libfx_journal_inputs_dropped count={d} reason=resume_replaced", .{self.pending_inputs.len});
        }
        self.dropPendingInputs(alloc);
    }

    /// Hands the pending resume's inputs to the caller, who owns them.
    pub fn takePendingInputs(self: *Journal) []journal.PendingInput {
        const inputs = self.pending_inputs;
        self.pending_inputs = &.{};
        return inputs;
    }

    fn dropPendingInputs(self: *Journal, alloc: Allocator) void {
        journal.freePendingInputs(alloc, self.pending_inputs);
        self.pending_inputs = &.{};
    }

    /// Records inputs taken for the next model request. Its progress places
    /// them and is a barrier, so the request never carries an input the
    /// journal could lose.
    pub fn notePlaced(self: *Journal, alloc: Allocator, ids: []const []const u8) Allocator.Error!void {
        if (ids.len == 0) return;
        try self.placed_next.ensureUnusedCapacity(alloc, ids.len);
        for (ids) |id| self.placed_next.appendAssumeCapacity(try alloc.dupe(u8, id));
        self.barrier_next_progress = true;
    }

    fn clearPlaced(self: *Journal, alloc: Allocator) void {
        for (self.placed_next.items) |id| alloc.free(id);
        self.placed_next.clearRetainingCapacity();
        self.placing_follow_up = false;
    }

    /// Drops inputs taken for a model request that never went out because
    /// their turn ended first. The model never saw them, the journal already
    /// dropped the steers with their turn, and a follow-up among them stays
    /// waiting for a later turn.
    pub fn dropUnplaced(self: *Journal, alloc: Allocator) void {
        if (self.placed_next.items.len == 0) return;
        debug_trace.logf("session", "event=libfx_journal_inputs_dropped count={d} reason=turn_ended_before_request", .{self.placed_next.items.len});
        self.clearPlaced(alloc);
    }

    /// Sends the open turn so far and the model its next request goes to,
    /// placing the inputs taken since the last progress. `session_alloc`
    /// owns the placed ids.
    pub fn appendProgress(
        self: *Journal,
        alloc: Allocator,
        session_alloc: Allocator,
        session_id: []const u8,
        checkpoint: session_codec.RecoveryCheckpoint,
        model: []const u8,
    ) !void {
        try self.append(alloc, session_id, .{ .turn_progress = .{
            .checkpoint = checkpoint,
            .placed = self.placed_next.items,
            .model = model,
        } });
        if (self.placing_follow_up) self.follow_ups_waiting -|= 1;
        self.clearPlaced(session_alloc);
    }

    /// Sends `event` as the session's next entry. On failure the cursor
    /// stays put, so the next event takes the same `seq`.
    pub fn append(self: *Journal, alloc: Allocator, session_id: []const u8, event: Event) !void {
        var params: std.Io.Writer.Allocating = .init(alloc);
        defer params.deinit();
        try params.writer.writeAll("{\"sessionId\":");
        try jsonrpc.writeJsonStr(session_id, &params.writer);
        try params.writer.writeAll(",\"events\":[");
        const next = try self.cursor.write(&params.writer, event);
        try params.writer.writeAll("]}");
        try self.writer.writeNotification(alloc, "libfx/journal_append", params.written());
        self.cursor = next;
        // Matches the fold: intents and compaction leave the open turn
        // standing.
        switch (event) {
            .turn_progress => self.progress_open = true,
            .turn_committed, .turn_progress_cleared => self.progress_open = false,
            .input_accepted => |input| if (input.kind == .follow_up) {
                self.follow_ups_waiting += 1;
            },
            .tool_intent, .history_replaced, .input_withdrawn, .session_config => {},
        }
    }

    /// The follow-up a starting turn runs: its first progress places it.
    pub fn placeFollowUp(self: *Journal, alloc: Allocator, id: []const u8) Allocator.Error!void {
        try self.notePlaced(alloc, &.{id});
        self.placing_follow_up = true;
    }

    /// Whether the session is at a point a snapshot can stand for: no turn
    /// open or waiting to resume, and no follow-up waiting for its turn.
    pub fn quiet(self: *const Journal) bool {
        return !self.progress_open and self.pending_resume == null and
            self.follow_ups_waiting == 0 and self.cursor.next_seq > 1;
    }

    /// Records that the open turn ended without a history entry. A turn
    /// with no progress on record needs no event.
    pub fn clearProgress(self: *Journal, alloc: Allocator, session_id: []const u8) !void {
        if (!self.progress_open) return;
        try self.append(alloc, session_id, .turn_progress_cleared);
    }
};

pub const Opened = struct {
    turns: usize,
    /// A crash left a turn open; `resume` continues it.
    resumable: bool,
    /// False when the open turn started under another config hash, so the
    /// host's instructions, tools or model differ from the ones it ran with.
    config_matches: bool = true,
};

fn dupePendingInputs(alloc: Allocator, inputs: []const journal.PendingInput) Allocator.Error![]journal.PendingInput {
    const owned = try alloc.alloc(journal.PendingInput, inputs.len);
    var filled: usize = 0;
    errdefer {
        for (owned[0..filled]) |input| {
            alloc.free(input.id);
            alloc.free(input.text);
        }
        alloc.free(owned);
    }
    for (inputs) |input| {
        const id = try alloc.dupe(u8, input.id);
        errdefer alloc.free(id);
        owned[filled] = .{ .id = id, .text = try alloc.dupe(u8, input.text) };
        filled += 1;
    }
    return owned;
}

/// Rebuilds a fresh session from the host's events, after `snapshot` when
/// the host stored one, and starts its journal after them. A turn a crash
/// left open becomes the pending resume, with every call it left running
/// answered as possibly run; `session_alloc` owns it.
pub fn open(
    alloc: Allocator,
    session_alloc: Allocator,
    writer: *jsonrpc.Writer,
    runtime: *session_runtime.SessionRuntime,
    events_json: []const u8,
    snapshot: ?[]const u8,
    config_hash: ?[]const u8,
) !struct { Journal, Opened } {
    if (!runtime.agent.fresh or runtime.agent.history.items.len != 0) return error.AgentNotFresh;
    var base: journal.Base = .{};
    var decoded: ?checkpoint_codec.Decoded = null;
    defer if (decoded) |*value| value.deinit(alloc);
    if (snapshot) |bytes| {
        const parsed = try journal.parseSnapshot(bytes);
        decoded = checkpoint_codec.decode(alloc, parsed.checkpoint) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedCheckpointVersion => return error.UnsupportedJournalVersion,
            else => return error.InvalidJournal,
        };
        base = .{
            .history = decoded.?.history,
            .cursor = .{ .next_seq = parsed.seq + 1, .turn = parsed.turn },
            .config_hash = parsed.config_hash,
        };
    }
    var folded = try journal.foldFrom(alloc, events_json, base);
    defer folded.deinit(alloc);
    if (folded.history.len > 0) try runtime.agent.restoreHistory(alloc, folded.history);
    if (decoded) |value| runtime.agent.turn_usage = value.usage;
    var state: Journal = .{
        .writer = writer,
        .cursor = folded.cursor,
        .progress_open = folded.open_turn != null,
        .pending_follow_ups = try dupePendingInputs(session_alloc, folded.pending_follow_ups),
        .follow_ups_waiting = folded.pending_follow_ups.len,
    };
    errdefer state.deinit(session_alloc);
    if (config_hash) |hash| state.host_config = try session_alloc.dupe(u8, hash);
    if (folded.config_hash) |hash| state.recorded_config = try session_alloc.dupe(u8, hash);
    const checkpoint = folded.open_turn orelse
        return .{ state, .{ .turns = folded.history.len, .resumable = false } };
    // Committed turns continue under any config; only an open turn
    // recorded under another one is refused.
    const config_matches = if (folded.open_turn_config) |recorded|
        if (config_hash) |hash| std.mem.eql(u8, recorded, hash) else true
    else
        true;

    debug_trace.logf("session", "event=libfx_journal_open_turn turn={d} running_calls={d} resolved=pending_resume", .{ folded.cursor.turn, folded.running_calls.len });
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var answered = checkpoint;
    try answerRunning(scratch.allocator(), &answered, folded.running_calls);
    state.pending_resume = try answered.dupe(session_alloc);
    state.pending_inputs = try dupePendingInputs(session_alloc, folded.pending_inputs);
    return .{ state, .{ .turns = folded.history.len, .resumable = true, .config_matches = config_matches } };
}

/// An owned copy of `pending` ready to continue: the model is told the
/// session was interrupted, then sees the inputs the turn accepted and never
/// placed, and the attempt budget starts over, so repeated crashes never turn
/// into a refusal to resume.
pub fn resumeCheckpoint(
    alloc: Allocator,
    pending: session_codec.RecoveryCheckpoint,
    inputs: []const journal.PendingInput,
) !session_codec.RecoveryCheckpoint {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var view = pending;
    const old = view.execution.steering;
    const steering = try scratch.allocator().alloc(types.PersistedSteering, old.len + 1 + inputs.len);
    @memcpy(steering[0..old.len], old);
    const after = view.execution.tool_steps.len;
    steering[old.len] = .{ .text = @constCast(resume_notice), .after_tool_step_count = after };
    for (inputs, steering[old.len + 1 ..]) |input, *entry| {
        entry.* = .{ .text = input.text, .after_tool_step_count = after };
    }
    view.execution.steering = steering;
    view.consumed_provider_attempts = 0;
    view.outstanding_reservation = false;
    return view.dupe(alloc);
}

/// Gives each call the crash left running a result saying it may have
/// partly run, as one more step of the open turn, so the model sees every
/// call it made answered and never has a `replay: "never"` call run again
/// on its own. The response that made the calls, with any text the model
/// wrote before them, is now that step, so the turn continues after its
/// tools. Borrows `calls` and the turn's text; allocates in `scratch`.
fn answerRunning(scratch: Allocator, turn: *session_codec.RecoveryCheckpoint, calls: []types.ToolCall) Allocator.Error!void {
    if (calls.len == 0) return;
    const output = session_adapter.unfinished_tool_output;
    const results = try scratch.alloc(types.PersistedToolResult, calls.len);
    for (calls, results) |call, *result| result.* = .{
        .tool_call_id = @constCast(call.id),
        .tool_name = @constCast(call.name),
        .status = .failure,
        .output = @constCast(output),
        .output_bytes = output.len,
        .stored_output_bytes = output.len,
    };
    const old = turn.execution.tool_steps;
    const steps = try scratch.alloc(types.ToolExecutionStep, old.len + 1);
    @memcpy(steps[0..old.len], old);
    steps[old.len] = .{
        .assistant = if (turn.assistant_source.len > 0) turn.assistant_source else null,
        .tool_calls = calls,
        .tool_results = results,
    };
    turn.execution.tool_steps = steps;
    turn.assistant_source = @constCast("");
    turn.tool_state = .confirmed;
}

const TestCapture = struct {
    frames: std.ArrayList(u8) = .empty,

    fn write(raw: ?*anyopaque, frame: []const u8) !void {
        const self: *TestCapture = @ptrCast(@alignCast(raw.?));
        try self.frames.appendSlice(std.testing.allocator, frame);
    }
};

fn testProgress(alloc: Allocator) !session_codec.RecoveryCheckpoint {
    return .{
        .turn_id = 1,
        .user = .{ .text = try alloc.dupe(u8, "prompt") },
        .assistant_source = try alloc.dupe(u8, ""),
        .cause = .network_interrupted,
        .action = .retrying_request,
        .authority = .{ .provider = .gateway, .model = try alloc.dupe(u8, "fake/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 0,
    };
}

test "inputs taken for a request that never went out are not placed by the next turn" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    try session.notePlaced(alloc, &.{"steer-1"});
    // Its turn ended before the next progress; the next turn starts.
    session.dropUnplaced(alloc);
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "steer-1") == null);
}

test "a follow-up waits until a progress places it, even through a turn that ended first" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer, .follow_ups_waiting = 1 };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    try session.placeFollowUp(alloc, "follow-1");
    try std.testing.expectEqual(@as(usize, 1), session.follow_ups_waiting);
    session.dropUnplaced(alloc);
    try std.testing.expectEqual(@as(usize, 1), session.follow_ups_waiting);
    try std.testing.expect(!session.quiet());

    try session.placeFollowUp(alloc, "follow-1");
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expectEqual(@as(usize, 0), session.follow_ups_waiting);
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "follow-1") != null);
}
