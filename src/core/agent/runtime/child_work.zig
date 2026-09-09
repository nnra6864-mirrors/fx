const std = @import("std");
const deps_mod = @import("deps.zig");
const execution_memory = @import("execution_memory.zig");
const types = @import("../../shared/types.zig");
const worker = @import("../worker_runtime.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const io_mod = @import("../../shared/io.zig");
const tool_presentation = @import("../../tooling/tool_presentation.zig");

const Allocator = std.mem.Allocator;
pub const WaitResult = enum { none, continue_turn, stopped };

/// Only call at a settled tool/model boundary, with no unresolved call outputs.
/// All prepared values live in the existing parent arena; model dispatch remains
/// with the orchestrator and cannot happen before durable commit succeeds.
pub fn adoptAtBoundary(
    deps: *const deps_mod.AgentRuntimeDeps,
    arena: Allocator,
    job: worker.QueuedPrompt,
    boundary: execution_memory.CompactedExecutionBoundary,
    suffix: *std.ArrayList(types.ChatMessage),
    recovery_source: ?[]const u8,
) !bool {
    const callbacks = deps.child_work orelse return false;
    const snapshot = try callbacks.prepare(deps.ctx, arena, suffix.items);
    return adoptSnapshot(deps, callbacks, arena, job, boundary, suffix, recovery_source, snapshot);
}

fn adoptSnapshot(
    deps: *const deps_mod.AgentRuntimeDeps,
    callbacks: deps_mod.ChildWorkCallbacks,
    arena: Allocator,
    job: worker.QueuedPrompt,
    boundary: execution_memory.CompactedExecutionBoundary,
    suffix: *std.ArrayList(types.ChatMessage),
    recovery_source: ?[]const u8,
    snapshot: deps_mod.ChildWorkSnapshot,
) !bool {
    if (snapshot.observations.len == 0) return false;
    if (recovery_source) |text| {
        if (text.len > 0) try suffix.append(arena, .{ .role = .assistant, .content = try arena.dupe(u8, text), .standalone_response = true });
    }
    try suffix.ensureUnusedCapacity(arena, snapshot.observations.len);
    for (snapshot.observations) |observation| {
        suffix.appendAssumeCapacity(try types.childObservationMessage(arena, observation));
    }
    const memory = try execution_memory.buildExecutionMemory(arena, suffix.items);
    const prefix: types.AssistantHistoryTurn = .{
        .user = .{ .text = job.prompt, .images = job.images },
        .assistant = @constCast(""),
        .execution = try boundary.project(arena, memory),
    };
    try callbacks.commit(deps.ctx, job.turn_id, prefix);
    // The suffix is installed and the canonical prefix is synced. Failure to
    // retire a redundant receipt cannot erase that adoption; reconciliation
    // finds the durable identity before trying to append it again.
    callbacks.acknowledge(deps.ctx, snapshot.observations) catch |err| {
        debug_trace.eventf("subagent", "child_receipt_retirement_deferred", .{ .turn_id = job.turn_id }, "count={d} error={s}", .{ snapshot.observations.len, @errorName(err) });
    };
    debug_trace.eventf("subagent", "child_evidence_model_suffix_installed", .{ .turn_id = job.turn_id }, "observations={d} messages={d}", .{ snapshot.observations.len, suffix.items.len });
    if (deps.push_interactive_notice) |push| {
        for (snapshot.observations) |observation| {
            const notice = try tool_presentation.childCompletionNotice(arena, observation);
            defer types.freeSemanticNotice(arena, notice);
            try push(deps.ctx, notice);
            const detail = try types.childObservationMessage(arena, observation);
            defer arena.free(detail.content.?);
            try push(deps.ctx, .{ .topic = "subagent", .tone = .neutral, .body = detail.content.?, .visibility = .full_only });
            debug_trace.eventf("subagent", "child_completion_presented", .{ .turn_id = job.turn_id }, "child_id={s} work_id={s} delivery_id={s}", .{ observation.child_id, observation.work_id, observation.delivery_id });
        }
    }
    return true;
}

/// Keeps the active worker/arena alive without issuing model requests. A timed
/// level check reuses existing child observation semantics; it cannot lose a
/// completion wake, and each check's temporary I/O storage is freed by the host.
pub fn afterAnswer(
    deps: *const deps_mod.AgentRuntimeDeps,
    arena: Allocator,
    job: worker.QueuedPrompt,
    boundary: execution_memory.CompactedExecutionBoundary,
    suffix: *std.ArrayList(types.ChatMessage),
    answer: []const u8,
    replay: ?types.ProviderReplay,
) !WaitResult {
    const callbacks = deps.child_work orelse return .none;
    var snapshot = try callbacks.prepare(deps.ctx, arena, suffix.items);
    if (!snapshot.pending and snapshot.observations.len == 0) return .none;
    try suffix.append(arena, .{ .role = .assistant, .content = answer, .provider_replay = replay, .standalone_response = true });
    try deps.push_text(deps.ctx, .{ .assistant_rendered = "\n" });
    debug_trace.eventf("subagent", "parent_child_wait_entered", .{ .turn_id = job.turn_id }, "ready={d} pending={s}", .{ snapshot.observations.len, if (snapshot.pending) "true" else "false" });
    var review_offered = false;
    while (true) {
        const input = callbacks.observe_input(deps.ctx, job.turn_id);
        switch (input) {
            .stopped => {
                debug_trace.eventf("subagent", "parent_child_wait_left", .{ .turn_id = job.turn_id }, "reason=parent_stop child_cancelled=false", .{});
                return .stopped;
            },
            .text, .handoff => {
                if (input == .text) {
                    if (deps.take_steering_boundary) |take| {
                        // No model request is in flight while parked. Consume a
                        // steering-owned interrupt here so waking does not spend
                        // an extra empty agent-loop step clearing it later.
                        switch (try take(deps.ctx, arena, job.turn_id, .cancelled)) {
                            .continue_turn => |guidance| {
                                for (guidance) |text| try suffix.append(arena, .{ .role = .user, .content = try execution_memory.steeringMessage(arena, text) });
                            },
                            .interrupt => return .stopped,
                            .none, .handoff => {},
                        }
                    }
                }
                debug_trace.eventf("subagent", "parent_child_wait_left", .{ .turn_id = job.turn_id }, "reason={s} child_cancelled=false", .{@tagName(input)});
                return .continue_turn;
            },
            .none => {},
        }
        if (try adoptSnapshot(deps, callbacks, arena, job, boundary, suffix, null, snapshot)) {
            debug_trace.eventf("subagent", "parent_child_wait_left", .{ .turn_id = job.turn_id }, "reason=completion", .{});
            return .continue_turn;
        }
        if (!snapshot.pending) return error.ChildDeliveryDisappeared;
        if (!review_offered) {
            if (callbacks.begin_wait) |begin| begin(deps.ctx, job.turn_id);
            review_offered = true;
        }
        io_mod.sleep(100 * std.time.ns_per_ms);
        snapshot = try callbacks.prepare(deps.ctx, arena, suffix.items);
    }
}
