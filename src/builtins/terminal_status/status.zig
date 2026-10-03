//! Foreground status: the one value fx shows to terminal hosts.
//!
//! Status is a read model derived from lifecycle events by `next`. It never
//! drives fx behavior. Hosts render `Status` values and never see events, so
//! every host shows the same answer for the same sequence of events.

const std = @import("std");
const types = @import("../../core/shared/types.zig");

pub const Activity = enum { idle, working, waiting, failed };

/// What a waiting fx needs from the user.
pub const AttentionKind = enum { permission, question, recovery };

/// Fixed-size copy of a session id so status values can cross threads
/// without shared ownership.
pub const SessionId = struct {
    pub const max_len = 128;

    buffer: [max_len]u8 = undefined,
    len: u8 = 0,

    /// Returns null for empty or over-long ids rather than truncating them.
    pub fn init(id: []const u8) ?SessionId {
        if (id.len == 0 or id.len > max_len) return null;
        var session: SessionId = .{ .len = @intCast(id.len) };
        @memcpy(session.buffer[0..id.len], id);
        return session;
    }

    pub fn slice(self: *const SessionId) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn eql(a: ?SessionId, b: ?SessionId) bool {
        const left = a orelse return b == null;
        const right = b orelse return false;
        return std.mem.eql(u8, left.slice(), right.slice());
    }
};

pub const Status = struct {
    activity: Activity = .idle,
    /// Set only while `activity` is `waiting`.
    attention: ?AttentionKind = null,
    session: ?SessionId = null,

    pub fn eql(a: Status, b: Status) bool {
        return a.activity == b.activity and a.attention == b.attention and SessionId.eql(a.session, b.session);
    }
};

pub const Event = union(enum) {
    /// Foreground work started, or resumed after a permission or question.
    working,
    /// A foreground decision prompt opened.
    attention_opened: AttentionKind,
    /// A foreground turn or work item reached a terminal outcome.
    settled: types.TurnPresentationOutcome,
    /// The latest observation of subagent approval prompts. A subagent
    /// approval overlays the foreground activity without replacing it.
    child_approval: struct { waiting: bool, parent_waiting: bool },
    /// The latest observation of the active session.
    session_changed,
};

pub const State = struct {
    foreground: Activity = .idle,
    foreground_attention: ?AttentionKind = null,
    child_waiting: bool = false,
    session: ?SessionId = null,

    pub fn status(self: State) Status {
        if (self.child_waiting) return .{ .activity = .waiting, .attention = .permission, .session = self.session };
        return .{
            .activity = self.foreground,
            .attention = if (self.foreground == .waiting) self.foreground_attention else null,
            .session = self.session,
        };
    }
};

/// Pure transition. `session` is the active session when the event was
/// observed; activity events adopt it, and `session_changed` resets status
/// only when it differs.
pub fn next(state: State, event: Event, session: ?SessionId) State {
    var result = state;
    switch (event) {
        .session_changed => {
            if (SessionId.eql(state.session, session)) return state;
            return .{ .session = session };
        },
        .working => setForeground(&result, .working, null),
        .attention_opened => |kind| {
            // The subagent overlay already shows this permission prompt.
            if (kind == .permission and state.child_waiting) {
                result.session = session;
                return result;
            }
            setForeground(&result, .waiting, kind);
        },
        .settled => |outcome| switch (outcome) {
            .completed, .interrupted => setForeground(&result, .idle, null),
            .failed => setForeground(&result, .failed, null),
            .paused => setForeground(&result, .waiting, .recovery),
        },
        .child_approval => |observed| {
            if (observed.waiting != state.child_waiting) {
                // A parent prompt replacing a subagent prompt does not reopen
                // the approval UI, so no attention event follows it.
                if (observed.parent_waiting) setForeground(&result, .waiting, .permission);
                result.child_waiting = observed.waiting;
            }
        },
    }
    result.session = session;
    return result;
}

fn setForeground(state: *State, activity: Activity, attention: ?AttentionKind) void {
    state.foreground = activity;
    state.foreground_attention = attention;
}

/// The attention to announce when `now` starts waiting.
pub fn enteredWaiting(prev: ?Status, now: Status) ?AttentionKind {
    if (now.activity != .waiting) return null;
    if (prev) |previous| {
        if (previous.activity == .waiting) return null;
    }
    return now.attention orelse .permission;
}

const testing = std.testing;

const Step = struct {
    event: Event,
    activity: Activity,
    attention: ?AttentionKind = null,
};

fn expectSteps(steps: []const Step) !void {
    const session = SessionId.init("session");
    var state: State = next(.{}, .session_changed, session);
    for (steps, 0..) |step, index| {
        state = next(state, step.event, session);
        const status = state.status();
        errdefer std.debug.print("step {d}: {s}\n", .{ index, @tagName(step.event) });
        try testing.expectEqual(step.activity, status.activity);
        try testing.expectEqual(step.attention, status.attention);
    }
}

test "foreground lifecycle follows work, prompts, and outcomes" {
    try expectSteps(&.{
        .{ .event = .working, .activity = .working },
        .{ .event = .{ .attention_opened = .permission }, .activity = .waiting, .attention = .permission },
        .{ .event = .working, .activity = .working },
        .{ .event = .{ .attention_opened = .question }, .activity = .waiting, .attention = .question },
        .{ .event = .working, .activity = .working },
        .{ .event = .{ .settled = .completed }, .activity = .idle },
        .{ .event = .working, .activity = .working },
        .{ .event = .{ .settled = .failed }, .activity = .failed },
        .{ .event = .working, .activity = .working },
        .{ .event = .{ .settled = .interrupted }, .activity = .idle },
        .{ .event = .working, .activity = .working },
        .{ .event = .{ .settled = .paused }, .activity = .waiting, .attention = .recovery },
        .{ .event = .{ .attention_opened = .recovery }, .activity = .waiting, .attention = .recovery },
        .{ .event = .working, .activity = .working },
    });
}

test "subagent approval overlays foreground activity and restores it" {
    // A subagent permission while the parent works, then approval.
    try expectSteps(&.{
        .{ .event = .working, .activity = .working },
        .{ .event = .{ .child_approval = .{ .waiting = true, .parent_waiting = false } }, .activity = .waiting, .attention = .permission },
        .{ .event = .{ .attention_opened = .permission }, .activity = .waiting, .attention = .permission },
        .{ .event = .{ .child_approval = .{ .waiting = false, .parent_waiting = false } }, .activity = .working },
    });
    // A question during the overlay stays visible after the overlay clears.
    try expectSteps(&.{
        .{ .event = .working, .activity = .working },
        .{ .event = .{ .child_approval = .{ .waiting = true, .parent_waiting = false } }, .activity = .waiting, .attention = .permission },
        .{ .event = .{ .attention_opened = .question }, .activity = .waiting, .attention = .permission },
        .{ .event = .{ .child_approval = .{ .waiting = false, .parent_waiting = false } }, .activity = .waiting, .attention = .question },
    });
    // A parent permission replacing a subagent prompt keeps fx waiting.
    try expectSteps(&.{
        .{ .event = .working, .activity = .working },
        .{ .event = .{ .child_approval = .{ .waiting = true, .parent_waiting = false } }, .activity = .waiting, .attention = .permission },
        .{ .event = .{ .child_approval = .{ .waiting = false, .parent_waiting = true } }, .activity = .waiting, .attention = .permission },
    });
    // An outcome during the overlay appears once the overlay clears.
    try expectSteps(&.{
        .{ .event = .{ .child_approval = .{ .waiting = true, .parent_waiting = false } }, .activity = .waiting, .attention = .permission },
        .{ .event = .{ .settled = .failed }, .activity = .waiting, .attention = .permission },
        .{ .event = .{ .child_approval = .{ .waiting = false, .parent_waiting = false } }, .activity = .failed },
    });
    // Repeated observations do not change anything.
    try expectSteps(&.{
        .{ .event = .working, .activity = .working },
        .{ .event = .{ .child_approval = .{ .waiting = false, .parent_waiting = true } }, .activity = .working },
    });
}

test "session changes reset status only when the session differs" {
    const first = SessionId.init("first");
    const second = SessionId.init("second");
    var state = next(.{}, .session_changed, null);
    try testing.expect(state.status().session == null);

    state = next(state, .working, first);
    try testing.expect(SessionId.eql(state.status().session, first));
    try testing.expectEqual(Activity.working, state.status().activity);

    state = next(state, .session_changed, first);
    try testing.expectEqual(Activity.working, state.status().activity);

    state = next(next(state, .{ .child_approval = .{ .waiting = true, .parent_waiting = false } }, first), .session_changed, second);
    try testing.expectEqual(Activity.idle, state.status().activity);
    try testing.expect(!state.child_waiting);
    try testing.expect(SessionId.eql(state.status().session, second));
}

test "session ids are copied and bounded" {
    try testing.expect(SessionId.init("") == null);
    try testing.expect(SessionId.init("x" ** (SessionId.max_len + 1)) == null);
    var source = [_]u8{ 'a', 'b' };
    const copied = SessionId.init(&source).?;
    source[0] = 'z';
    try testing.expectEqualStrings("ab", copied.slice());
    try testing.expect(SessionId.eql(null, null));
    try testing.expect(!SessionId.eql(copied, null));
}

test "entering waiting is announced once" {
    const waiting: Status = .{ .activity = .waiting, .attention = .question };
    try testing.expectEqual(@as(?AttentionKind, .question), enteredWaiting(null, waiting));
    try testing.expectEqual(@as(?AttentionKind, .question), enteredWaiting(.{ .activity = .working }, waiting));
    try testing.expectEqual(@as(?AttentionKind, null), enteredWaiting(.{ .activity = .waiting, .attention = .permission }, waiting));
    try testing.expectEqual(@as(?AttentionKind, null), enteredWaiting(.{ .activity = .waiting }, .{ .activity = .idle }));
}
