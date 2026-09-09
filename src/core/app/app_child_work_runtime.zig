const std = @import("std");
const app_worker = @import("app_worker_runtime.zig");
const deps = @import("../agent/runtime/deps.zig");
const delivery = @import("../subagent/delivery.zig");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const worker = @import("../agent/worker_runtime.zig");

const Allocator = std.mem.Allocator;

/// The active main worker pulls evidence. No child callback enters App, emits a
/// model request, or retains the current parent execution's arena.
pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn callbacks() deps.ChildWorkCallbacks {
            return .{ .prepare = prepare, .commit = commit, .acknowledge = acknowledge, .observe_input = observeInput, .begin_wait = beginWait };
        }

        pub fn needsRetainedHost(app: *App) !bool {
            if (app.session_persistence.retained_subagent_hosts.selectedHost() != null) return false;
            const loaded = if (app.session_persistence.writable) |*value| value else return false;
            const sessions = if (app.session_persistence.store) |*value| value else return false;
            var index = try (delivery.Store{ .sessions = sessions, .parent_id = loaded.active_id }).load(app.alloc);
            defer index.deinit();
            return index.items().len > 0;
        }

        pub fn appendPendingContext(app: *App, arena: Allocator, messages: *std.ArrayList(types.ChatMessage)) !void {
            const host = app.session_persistence.retained_subagent_hosts.selectedHost() orelse return;
            var index = try host.deliveryStore().load(arena);
            defer index.deinit();
            var out: std.Io.Writer.Allocating = .init(arena);
            defer out.deinit();
            var count: usize = 0;
            for (index.items()) |receipt| {
                if (try host.deliveryStore().outcome(arena, receipt)) |finished| {
                    types.freeChildObservation(arena, finished);
                    continue;
                }
                if (count == 0) try out.writer.writeAll("Running delegated work owned by this session (host status, not user input):\n");
                try std.json.Stringify.value(.{ .child_id = receipt.child_id, .work_id = receipt.work_id }, .{}, &out.writer);
                try out.writer.writeByte('\n');
                count += 1;
            }
            if (count == 0) return;
            try out.writer.writeAll("Main-agent input, cancellation and session changes do not cancel this work. Use the subagent cancel action with the exact child_id and work_id only when you intend to stop it.");
            try messages.append(arena, .{ .role = .system, .content = try arena.dupe(u8, out.written()) });
            debug_trace.eventf("subagent", "child_inventory_projected", .{}, "root_id={s} count={d}", .{ host.root_id, count });
        }

        fn beginWait(raw: *anyopaque, turn_id: u64) void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (app.worker.observeChildWaitInput(turn_id) != .none) return;
            // Reoffer human-required input only after the main response, not
            // while a new user request is trying to reach the main model.
            app.session_persistence.retained_subagent_hosts.showApproval();
            app_worker.Runtime(App).showSubagentQuestions(app);
            debug_trace.eventf("subagent", "child_review_available_at_parent_wait", .{ .turn_id = turn_id }, "automatic_approval=false", .{});
        }

        fn observeInput(raw: *anyopaque, turn_id: u64) worker.WorkerRuntime.ChildWaitInput {
            const app: *App = @ptrCast(@alignCast(raw));
            return app.worker.observeChildWaitInput(turn_id);
        }

        fn prepare(raw: *anyopaque, alloc: Allocator, messages: []const types.ChatMessage) !deps.ChildWorkSnapshot {
            const app: *App = @ptrCast(@alignCast(raw));
            const host = app.session_persistence.retained_subagent_hosts.selectedHost() orelse return .{};
            var scratch_state = std.heap.ArenaAllocator.init(app.alloc);
            defer scratch_state.deinit();
            const scratch = scratch_state.allocator();
            var index = try host.deliveryStore().load(scratch);
            defer index.deinit();
            var ready: std.ArrayList(types.ChildObservation) = .empty;
            errdefer {
                for (ready.items) |value| types.freeChildObservation(alloc, value);
                ready.deinit(alloc);
            }
            var pending = false;
            for (index.items()) |receipt| {
                if (representedInMessages(receipt, messages)) continue;
                const value = (try host.readPendingDelivery(scratch, receipt)) orelse {
                    pending = true;
                    continue;
                };
                defer types.freeChildObservation(scratch, value);
                const adopted = blk: {
                    app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
                    defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
                    const loaded = if (app.session_persistence.writable) |*loaded| loaded else return error.SessionStoreUnavailable;
                    if (!std.mem.eql(u8, loaded.active_id, host.root_id)) return error.ChildObservationWrongParent;
                    break :blk try loaded.conversation_writer.hasTerminalChildDelivery(scratch, receipt.key()) or
                        try loaded.conversation_writer.hasChildObservation(scratch, value);
                };
                if (adopted) {
                    debug_trace.eventf("subagent", "child_delivery_already_adopted", .{ .turn_id = receipt.parent_turn_id }, "root_id={s} child_id={s} work_id={s} delivery_id={s}", .{ host.root_id, receipt.child_id, receipt.work_id, receipt.delivery_id });
                    try host.deliveryStore().acknowledge(scratch, receipt);
                    continue;
                }
                const copy = try types.dupeChildObservation(alloc, value);
                errdefer types.freeChildObservation(alloc, copy);
                try ready.append(alloc, copy);
                debug_trace.eventf("subagent", "child_delivery_selected", .{ .turn_id = value.parent_turn_id }, "root_id={s} child_id={s} work_id={s} delivery_id={s}", .{ host.root_id, value.child_id, value.work_id, value.delivery_id });
            }
            return .{ .observations = try ready.toOwnedSlice(alloc), .pending = pending };
        }

        fn commit(raw: *anyopaque, turn_id: u64, prefix: types.AssistantHistoryTurn) !void {
            const app: *App = @ptrCast(@alignCast(raw));
            const host = app.session_persistence.retained_subagent_hosts.selectedHost() orelse return error.ChildHostUnavailable;
            app.session_persistence.write_mutex.lockUncancelable(io_mod.getIo());
            defer app.session_persistence.write_mutex.unlock(io_mod.getIo());
            const loaded = if (app.session_persistence.writable) |*value| value else return error.SessionStoreUnavailable;
            if (!std.mem.eql(u8, loaded.active_id, host.root_id)) return error.ChildObservationWrongParent;
            // Preserve reservation/attempt/authority state while replacing only
            // the canonical active prefix. Partial source is represented by the
            // caller as a standalone assistant step before the observation.
            var recovery = loaded.state.recovery_checkpoint;
            if (recovery) |*checkpoint| {
                checkpoint.turn_id = turn_id;
                checkpoint.user = prefix.user;
                checkpoint.assistant_source = @constCast("");
                checkpoint.execution = prefix.execution;
            }
            _ = try loaded.commitChildObservationPrefix(app.alloc, prefix, recovery, io_mod.milliTimestamp());
            debug_trace.eventf("subagent", "child_evidence_parent_prefix_committed", .{ .turn_id = turn_id }, "root_id={s} observations={d} through_seq={d}", .{ host.root_id, prefix.execution.child_observations.len, loaded.conversation_writer.last_seq });
        }

        fn acknowledge(raw: *anyopaque, observations: []const types.ChildObservation) !void {
            const app: *App = @ptrCast(@alignCast(raw));
            const host = app.session_persistence.retained_subagent_hosts.selectedHost() orelse return error.ChildHostUnavailable;
            for (observations) |value| {
                if (!std.mem.eql(u8, value.parent_session_id, host.root_id)) return error.ChildObservationWrongParent;
                try host.deliveryStore().acknowledge(app.alloc, .{
                    .parent_turn_id = value.parent_turn_id,
                    .child_id = value.child_id,
                    .work_id = value.work_id,
                    .tool_call_id = value.tool_call_id,
                    .delivery_id = value.delivery_id,
                });
            }
        }

        /// Called only after the ordinary terminal history write has succeeded.
        /// A running acknowledgement is not terminal child evidence.
        pub fn acknowledgeTerminalResults(app: *App, turn: types.HistoryTurn) !void {
            const host = app.session_persistence.retained_subagent_hosts.selectedHost() orelse return;
            const execution = switch (turn) {
                .assistant => |value| value.execution,
                .interrupted => |value| value.execution,
                .compacted_summary => return,
            };
            if (!execution.hasChildDeliveryMetadata()) return;
            var index = try host.deliveryStore().load(app.alloc);
            defer index.deinit();
            for (execution.tool_steps) |step| {
                for (step.tool_results) |result| {
                    const value = result.child_delivery orelse continue;
                    if (value.state != .terminal) continue;
                    for (index.items()) |receipt| {
                        const key = receipt.key();
                        if (std.mem.eql(u8, &key, &value.key)) try host.deliveryStore().acknowledge(app.alloc, receipt);
                    }
                }
            }
        }
    };
}

fn representedInMessages(receipt: delivery.Receipt, messages: []const types.ChatMessage) bool {
    const key = receipt.key();
    for (messages) |message| {
        if (message.child_observation) |value| {
            if (std.mem.eql(u8, value.delivery_id, receipt.delivery_id)) return true;
        }
        if (message.tool_result_memory) |memory| {
            if (memory.child_delivery) |value| {
                if (value.state == .terminal and std.mem.eql(u8, &value.key, &key)) return true;
            }
        }
    }
    return false;
}

test "child delivery pending acknowledgement cannot suppress later completion" {
    const receipt = delivery.Receipt{ .parent_turn_id = 1, .child_id = "child", .work_id = "work", .tool_call_id = "call", .delivery_id = "delivery" };
    var messages = [_]types.ChatMessage{.{ .role = .tool, .tool_result_memory = .{ .child_delivery = .{ .key = receipt.key(), .state = .running } } }};
    try std.testing.expect(!representedInMessages(receipt, &messages));
    messages[0].tool_result_memory.?.child_delivery.?.state = .terminal;
    try std.testing.expect(representedInMessages(receipt, &messages));
}
