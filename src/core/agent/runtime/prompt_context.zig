const std = @import("std");
const model_capabilities = @import("../../config/model_capabilities.zig");
const token_estimate = @import("../../shared/token_estimate.zig");
const types = @import("../../shared/types.zig");
const session_runtime = @import("../../session/session.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;

const compaction_high_water_numerator: usize = 4;
const compaction_ratio_denominator: usize = 5;
const compaction_target_denominator: usize = 10;
const compaction_recent_denominator: usize = 20;
const compaction_soft_ceiling_denominator: usize = 4;
const compaction_source_reduction_denominator: usize = 8;
const compaction_generation_multiplier: usize = 4;

pub const CompactionTrigger = enum {
    automatic,
    manual,
};

pub const CompactionDecision = enum {
    no_op,
    compact,
};

pub const CompactionPlanInput = struct {
    trigger: CompactionTrigger,
    capabilities: model_capabilities.Capabilities,
    request_tokens: usize,
    source_tokens: usize,
    protected_tokens: usize = 0,
    newest_exchange_tokens: usize = 0,
};

pub const CompactionPlan = struct {
    decision: CompactionDecision,
    usable_input_tokens: ?usize,
    high_water_tokens: ?usize,
    session_target_tokens: ?usize,
    accepted_handoff_tokens: ?usize,
    generation_tokens: ?usize,
};

pub fn planCompaction(input: CompactionPlanInput) CompactionPlan {
    const usable = usableInputTokens(input.capabilities);
    const high_water = if (usable) |tokens|
        tokens * compaction_high_water_numerator / compaction_ratio_denominator
    else
        null;
    const session_target = if (usable) |tokens|
        tokens / compaction_target_denominator
    else
        null;
    const should_compact = input.source_tokens > 0 and switch (input.trigger) {
        .manual => true,
        .automatic => if (high_water) |tokens| input.request_tokens >= tokens else false,
    };
    if (!should_compact) return .{
        .decision = .no_op,
        .usable_input_tokens = usable,
        .high_water_tokens = high_water,
        .session_target_tokens = session_target,
        .accepted_handoff_tokens = null,
        .generation_tokens = null,
    };

    const source_target = @max(
        @as(usize, 1),
        (input.source_tokens +| (compaction_source_reduction_denominator - 1)) /
            compaction_source_reduction_denominator,
    );
    const total_target = if (session_target) |target|
        @max(@as(usize, 1), target)
    else
        source_target;
    const soft_ceiling = if (usable) |tokens| tokens / compaction_soft_ceiling_denominator else total_target *| 2;
    const oversized_exchange = if (usable) |tokens|
        input.newest_exchange_tokens > tokens / compaction_recent_denominator and input.protected_tokens > soft_ceiling
    else
        false;
    const request_ceiling = if (oversized_exchange) usable.? else soft_ceiling;
    if (input.protected_tokens >= request_ceiling) return .{
        .decision = .no_op,
        .usable_input_tokens = usable,
        .high_water_tokens = high_water,
        .session_target_tokens = session_target,
        .accepted_handoff_tokens = null,
        .generation_tokens = null,
    };
    const accepted = @min(total_target, request_ceiling - input.protected_tokens);
    const requested_generation = accepted *| compaction_generation_multiplier;
    const generation = if (input.capabilities.max_output_tokens) |limit|
        @min(requested_generation, @as(usize, @intCast(limit)))
    else
        requested_generation;
    return .{
        .decision = .compact,
        .usable_input_tokens = usable,
        .high_water_tokens = high_water,
        .session_target_tokens = session_target,
        .accepted_handoff_tokens = accepted,
        .generation_tokens = generation,
    };
}

pub fn recentContextTarget(capabilities: model_capabilities.Capabilities, source_tokens: usize) usize {
    return (usableInputTokens(capabilities) orelse source_tokens) / compaction_recent_denominator;
}

pub const RetainedContext = struct {
    cut: types.ContextHistoryCut,
    newest_exchange_tokens: usize,
    estimated_tokens: usize,
};

/// Selects complete execution steps. Payloads are measured, never shortened.
pub fn selectRecentContext(history: []const HistoryTurn, target: usize, input_capacity: ?usize) RetainedContext {
    var raw_count = session_runtime.rawHistoryTurnCount(history);
    var selected = types.ContextHistoryCut{ .turns = raw_count };
    var total: usize = 0;
    var newest: usize = 0;
    var selected_any = false;
    var index = history.len;
    history_scan: while (index > 0) {
        index -= 1;
        const turn = history[index];
        if (turn == .compacted_summary) continue;
        raw_count -= 1;
        const user = switch (turn) {
            .assistant => |entry| entry.user.text,
            .interrupted => |entry| entry.user.text,
            .compacted_summary => unreachable,
        };
        const reply = switch (turn) {
            .assistant => |entry| entry.assistant,
            .interrupted => |entry| entry.assistant orelse "",
            .compacted_summary => unreachable,
        };
        const execution = switch (turn) {
            .assistant => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
            .compacted_summary => unreachable,
        };
        var base = textTokens(user) +| textTokens(reply) +| 8;
        var steering_index = execution.steering.len;
        var step_index = execution.tool_steps.len;
        if (step_index == 0) {
            for (execution.steering) |entry| {
                base +|= textTokens(entry.text);
                if (entry.assistant_prefix) |prefix| base +|= textTokens(prefix);
            }
            if (input_capacity) |capacity| {
                if (!selected_any and base >= capacity) break :history_scan;
            }
            if (selected_any and (raw_count == 0 or total +| base > target)) break;
            total +|= base;
            selected = .{ .turns = raw_count };
            if (!selected_any) newest = total;
            selected_any = true;
            continue;
        }
        while (step_index > 0) {
            step_index -= 1;
            var cost = base +| executionStepTokens(execution.tool_steps[step_index]);
            var next_steering = steering_index;
            while (next_steering > 0 and execution.steering[next_steering - 1].after_tool_step_count >= step_index) {
                next_steering -= 1;
                cost +|= textTokens(execution.steering[next_steering].text);
                if (execution.steering[next_steering].assistant_prefix) |prefix| cost +|= textTokens(prefix);
            }
            if (input_capacity) |capacity| {
                if (!selected_any and cost >= capacity) break :history_scan;
            }
            if (selected_any and ((raw_count == 0 and step_index == 0) or total +| cost > target)) return .{
                .cut = selected,
                .newest_exchange_tokens = newest,
                .estimated_tokens = total,
            };
            total +|= cost;
            selected = .{ .turns = raw_count, .tool_steps = step_index, .steering = next_steering };
            if (!selected_any) newest = total;
            selected_any = true;
            steering_index = next_steering;
            base = 0;
        }
    }
    return .{ .cut = selected, .newest_exchange_tokens = newest, .estimated_tokens = total };
}

fn textTokens(text: []const u8) usize {
    var estimator = token_estimate.StreamingEstimator{};
    estimator.consume(text);
    return @intCast(@min(estimator.estimate(), std.math.maxInt(usize)));
}

fn executionStepTokens(step: types.ToolExecutionStep) usize {
    var total: usize = 8;
    if (step.assistant) |text| total +|= textTokens(text);
    for (step.tool_calls) |call| {
        total +|= textTokens(call.id) +| textTokens(call.name) +| textTokens(call.arguments_json) +| 8;
    }
    for (step.tool_results) |result| {
        total +|= textTokens(result.tool_call_id) +| textTokens(result.tool_name) +| textTokens(result.output) +| 8;
    }
    return total;
}

pub const CompactionHandoffError = error{
    EmptyCompactionHandoff,
    InvalidCompactionHandoff,
    CompactionHandoffTooLarge,
};

pub fn validateCompactionHandoff(
    text: []const u8,
    accepted_tokens: usize,
) CompactionHandoffError!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidCompactionHandoff;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        return error.EmptyCompactionHandoff;
    }
    var estimator = token_estimate.StreamingEstimator{};
    estimator.consume(text);
    if (estimator.estimate() > accepted_tokens) {
        return error.CompactionHandoffTooLarge;
    }
}

pub const RequestCost = struct {
    serialized_bytes: usize,
    estimated_input_tokens: usize,
};

pub const RequestTokenCalibration = struct {
    serialized_bytes: usize,
    exact_input_tokens: usize,
};

pub fn measureProviderRequest(body: []const u8) RequestCost {
    var estimator = token_estimate.StreamingEstimator{};
    estimator.consume(body);
    return .{
        .serialized_bytes = body.len,
        .estimated_input_tokens = @intCast(@min(
            estimator.estimate(),
            std.math.maxInt(usize),
        )),
    };
}

pub fn calibrateProviderRequest(
    cost: RequestCost,
    calibration: RequestTokenCalibration,
) RequestCost {
    if (calibration.serialized_bytes == 0 or calibration.exact_input_tokens == 0) {
        return cost;
    }
    const calibrated_tokens = multiplyDivideCeilSaturating(
        cost.serialized_bytes,
        calibration.exact_input_tokens,
        calibration.serialized_bytes,
    );
    return .{
        .serialized_bytes = cost.serialized_bytes,
        .estimated_input_tokens = @max(
            cost.estimated_input_tokens,
            calibrated_tokens,
        ),
    };
}

fn multiplyDivideCeilSaturating(
    value: usize,
    numerator: usize,
    denominator: usize,
) usize {
    std.debug.assert(denominator != 0);
    const whole = std.math.mul(
        usize,
        value / denominator,
        numerator,
    ) catch return std.math.maxInt(usize);
    const remainder_product = std.math.mul(
        usize,
        value % denominator,
        numerator,
    ) catch return std.math.maxInt(usize);
    const partial = remainder_product / denominator +
        @intFromBool(remainder_product % denominator != 0);
    return std.math.add(usize, whole, partial) catch std.math.maxInt(usize);
}

pub fn estimateCompactionSourceTokens(messages: []const ChatMessage) usize {
    var estimator = token_estimate.StreamingEstimator{};
    for (messages) |message| {
        estimator.consume(@tagName(message.role));
        if (message.content) |content| estimator.consume(content);
        if (message.tool_call_id) |id| estimator.consume(id);
        if (message.tool_name) |name| estimator.consume(name);
        for (message.tool_calls) |call| {
            estimator.consume(call.id);
            estimator.consume(call.name);
            estimator.consume(call.arguments_json);
        }
    }
    return @intCast(@min(estimator.estimate(), std.math.maxInt(usize)));
}

pub fn usableInputTokens(
    capabilities: model_capabilities.Capabilities,
) ?usize {
    const context_window = capabilities.context_window orelse return null;
    const context_tokens: usize = @intCast(context_window);
    if (capabilities.max_output_tokens) |output| {
        const output_tokens: usize = @intCast(output);
        if (output_tokens < context_tokens) return context_tokens - output_tokens;
    }
    return context_tokens;
}

pub fn usableInputTokensForGeneration(
    capabilities: model_capabilities.Capabilities,
    generation_tokens: usize,
) ?usize {
    const context_window = capabilities.context_window orelse return null;
    return @as(usize, @intCast(context_window)) -| generation_tokens;
}

pub const ProviderPrompt = struct {
    instructions: std.ArrayList(ChatMessage),
    messages: std.ArrayList(ChatMessage),

    pub fn deinit(self: *ProviderPrompt, alloc: Allocator) void {
        self.instructions.deinit(alloc);
        self.messages.deinit(alloc);
        self.* = undefined;
    }
};

pub fn buildProviderPrompt(
    alloc: Allocator,
    stable_prefix: []const ChatMessage,
    ephemeral_overlay: []const ChatMessage,
    durable_history: []const ChatMessage,
    current_user_message: ChatMessage,
    within_turn_suffix: []const ChatMessage,
) !ProviderPrompt {
    var instructions: std.ArrayList(ChatMessage) = .empty;
    errdefer instructions.deinit(alloc);
    var messages: std.ArrayList(ChatMessage) = .empty;
    errdefer messages.deinit(alloc);

    try instructions.appendSlice(alloc, stable_prefix);
    try appendEphemeralOverlayMessages(alloc, &instructions, ephemeral_overlay);
    try messages.appendSlice(alloc, durable_history);
    try messages.append(alloc, current_user_message);
    try messages.appendSlice(alloc, within_turn_suffix);
    return .{
        .instructions = instructions,
        .messages = messages,
    };
}

fn appendEphemeralOverlayMessages(alloc: Allocator, messages: *std.ArrayList(ChatMessage), ephemeral_overlay: []const ChatMessage) !void {
    for (ephemeral_overlay) |overlay_message| {
        var copy = overlay_message;
        copy.cache_policy = .no_cache;
        try messages.append(alloc, copy);
    }
}

test "buildProviderPrompt separates instructions from chronological messages" {
    const alloc = std.testing.allocator;
    const stable_prefix = [_]ChatMessage{
        .{ .role = .system, .content = "stable system prompt" },
        .{ .role = .system, .content = "stable project context" },
    };
    const overlay = [_]ChatMessage{
        .{ .role = .system, .content = "volatile runtime overlay" },
    };
    const history = [_]ChatMessage{
        .{ .role = .user, .content = "history user prompt" },
        .{ .role = .assistant, .content = "history assistant answer" },
    };
    const current = ChatMessage{ .role = .user, .content = "current user prompt" };
    const suffix = [_]ChatMessage{
        .{ .role = .assistant, .content = "within turn assistant" },
    };

    var prompt = try buildProviderPrompt(alloc, &stable_prefix, &overlay, &history, current, &suffix);
    defer prompt.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), prompt.instructions.items.len);
    try std.testing.expectEqual(@as(usize, 4), prompt.messages.items.len);
    try std.testing.expectEqualStrings("stable system prompt", prompt.instructions.items[0].content.?);
    try std.testing.expectEqualStrings("stable project context", prompt.instructions.items[1].content.?);
    try std.testing.expectEqualStrings("volatile runtime overlay", prompt.instructions.items[2].content.?);
    try std.testing.expectEqualStrings("history user prompt", prompt.messages.items[0].content.?);
    try std.testing.expectEqualStrings("history assistant answer", prompt.messages.items[1].content.?);
    try std.testing.expectEqualStrings("current user prompt", prompt.messages.items[2].content.?);
    try std.testing.expectEqualStrings("within turn assistant", prompt.messages.items[3].content.?);
    try std.testing.expectEqual(types.ChatCachePolicy.no_cache, prompt.instructions.items[2].cache_policy);
}

test "buildProviderPrompt keeps compacted session context out of instructions" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var calls = [_]types.ToolCall{.{
        .id = "call_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/portable.zig\"}",
    }};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("portable contents"),
        .output_bytes = 17,
        .stored_output_bytes = 17,
    }};
    var steps = [_]types.ToolExecutionStep{.{
        .assistant = @constCast("Reading the file."),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    var files = [_]types.FileEvidence{.{
        .path = @constCast("src/portable.zig"),
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .action = .read,
        .status = .success,
        .model_view_covers_full_file = true,
    }};
    const history = [_]HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast("LEADING_SUMMARY_ONLY"),
            .removed_turn_count = 2,
            .compaction_count = 1,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("inspect portable history") },
            .assistant = @constCast("inspection complete"),
            .execution = .{ .tool_steps = steps[0..], .files = files[0..] },
        } },
        .{ .compacted_summary = .{
            .summary = @constCast("LATE_SUMMARY_ONLY"),
            .removed_turn_count = 1,
            .compaction_count = 2,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("run portable server") },
            .assistant = @constCast("server history is inert"),
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("stop portable work") },
            .assistant = @constCast("partial portable work"),
        } },
    };

    var projected_history: std.ArrayList(ChatMessage) = .empty;
    defer projected_history.deinit(arena);
    try session_runtime.appendHistoryChatMessages(arena, &projected_history, &history);

    const stable_prefix = [_]ChatMessage{
        .{ .role = .system, .content = "stable system prompt" },
        .{ .role = .system, .content = "stable project context" },
    };
    const overlay = [_]ChatMessage{.{ .role = .system, .content = "ephemeral overlay" }};
    const current = ChatMessage{ .role = .user, .content = "current portable prompt" };
    const suffix = [_]ChatMessage{.{ .role = .assistant, .content = "within-turn suffix" }};
    var prompt = try buildProviderPrompt(
        arena,
        &stable_prefix,
        &overlay,
        projected_history.items,
        current,
        &suffix,
    );
    defer prompt.deinit(arena);

    var leading_summary_count: usize = 0;
    var late_summary_count: usize = 0;
    var file_evidence_count: usize = 0;
    var interruption_count: usize = 0;
    for (prompt.instructions.items) |entry| try std.testing.expectEqual(types.ChatRole.system, entry.role);
    for (prompt.messages.items) |entry| {
        try std.testing.expect(entry.role != .system);
        const content = entry.content orelse continue;
        if (std.mem.find(u8, content, "LEADING_SUMMARY_ONLY") != null) {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            leading_summary_count += 1;
        }
        if (std.mem.find(u8, content, "LATE_SUMMARY_ONLY") != null) {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            late_summary_count += 1;
        }
        if (std.mem.find(u8, content, "src/portable.zig") != null and
            std.mem.find(u8, content, "Session file evidence") != null)
        {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            file_evidence_count += 1;
        }
        if (std.mem.find(u8, content, "<turn_aborted>") != null) {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            interruption_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), leading_summary_count);
    try std.testing.expectEqual(@as(usize, 1), late_summary_count);
    try std.testing.expectEqual(@as(usize, 1), file_evidence_count);
    try std.testing.expectEqual(@as(usize, 1), interruption_count);
    try std.testing.expectEqualStrings("current portable prompt", prompt.messages.items[prompt.messages.items.len - 2].content.?);
    try std.testing.expectEqualStrings("within-turn suffix", prompt.messages.items[prompt.messages.items.len - 1].content.?);
}

test "provider request measurement includes serialized structure" {
    const compact = measureProviderRequest("{\"prompt\":[{\"role\":\"user\",\"content\":\"same\"}]}");
    const fragmented = measureProviderRequest(
        "{\"prompt\":[{\"role\":\"user\",\"content\":\"s\"},{\"role\":\"user\",\"content\":\"a\"},{\"role\":\"user\",\"content\":\"m\"},{\"role\":\"user\",\"content\":\"e\"}]}",
    );
    try std.testing.expect(fragmented.serialized_bytes > compact.serialized_bytes);
    try std.testing.expect(fragmented.estimated_input_tokens > compact.estimated_input_tokens);
}

test "provider request measurement learns the prior exact token density" {
    const current = RequestCost{
        .serialized_bytes = 1_456_988,
        .estimated_input_tokens = 365_113,
    };
    const calibrated = calibrateProviderRequest(current, .{
        .serialized_bytes = 767_736,
        .exact_input_tokens = 398_710,
    });

    try std.testing.expect(calibrated.estimated_input_tokens > 695_142);
    try std.testing.expect(calibrated.estimated_input_tokens >= current.estimated_input_tokens);
}

test "compactor input budget reserves the requested generation" {
    try std.testing.expectEqual(
        @as(?usize, 296_816),
        usableInputTokensForGeneration(.{ .context_window = 500_000 }, 203_184),
    );
    try std.testing.expectEqual(
        @as(?usize, 0),
        usableInputTokensForGeneration(.{ .context_window = 500_000 }, 500_000),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        usableInputTokensForGeneration(.{}, 1),
    );
}

test "compaction v2 triggers automatic work at eighty percent and targets ten percent" {
    try std.testing.expectEqual(
        @as(usize, 2),
        std.meta.tags(CompactionDecision).len,
    );

    const capabilities = model_capabilities.Capabilities{
        .context_window = 1_000,
        .max_output_tokens = 200,
    };
    const below = planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = 639,
        .source_tokens = 640,
    });
    try std.testing.expectEqual(CompactionDecision.no_op, below.decision);

    const at_boundary = planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = 640,
        .source_tokens = 640,
    });
    try std.testing.expectEqual(CompactionDecision.compact, at_boundary.decision);
    try std.testing.expectEqual(@as(?usize, 800), at_boundary.usable_input_tokens);
    try std.testing.expectEqual(@as(?usize, 640), at_boundary.high_water_tokens);
    try std.testing.expectEqual(@as(?usize, 80), at_boundary.session_target_tokens);
    try std.testing.expectEqual(@as(?usize, 80), at_boundary.accepted_handoff_tokens);
    try std.testing.expectEqual(@as(?usize, 200), at_boundary.generation_tokens);

    const protected_prompt = planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = 640,
        .source_tokens = 640,
        .protected_tokens = 20,
    });
    try std.testing.expectEqual(@as(?usize, 80), protected_prompt.accepted_handoff_tokens);

    const oversized_protected_prompt = planCompaction(.{
        .trigger = .automatic,
        .capabilities = capabilities,
        .request_tokens = 640,
        .source_tokens = 640,
        .protected_tokens = 200,
    });
    try std.testing.expectEqual(CompactionDecision.no_op, oversized_protected_prompt.decision);
}

test "retained context budgets preserve an oversized newest exchange" {
    const caps = model_capabilities.Capabilities{ .context_window = 100_000 };
    try std.testing.expectEqual(@as(usize, 5_000), recentContextTarget(caps, 0));
    const ordinary = planCompaction(.{
        .trigger = .automatic,
        .capabilities = caps,
        .request_tokens = 80_000,
        .source_tokens = 80_000,
        .protected_tokens = 12_000,
        .newest_exchange_tokens = 4_000,
    });
    try std.testing.expectEqual(@as(?usize, 10_000), ordinary.accepted_handoff_tokens);
    const near_ceiling = planCompaction(.{
        .trigger = .automatic,
        .capabilities = caps,
        .request_tokens = 80_000,
        .source_tokens = 80_000,
        .protected_tokens = 20_000,
        .newest_exchange_tokens = 4_000,
    });
    try std.testing.expectEqual(@as(?usize, 5_000), near_ceiling.accepted_handoff_tokens);
    const oversized = planCompaction(.{
        .trigger = .automatic,
        .capabilities = caps,
        .request_tokens = 80_000,
        .source_tokens = 80_000,
        .protected_tokens = 43_000,
        .newest_exchange_tokens = 35_000,
    });
    try std.testing.expectEqual(@as(?usize, 10_000), oversized.accepted_handoff_tokens);
    const impossible = planCompaction(.{
        .trigger = .automatic,
        .capabilities = caps,
        .request_tokens = 110_000,
        .source_tokens = 110_000,
        .protected_tokens = 100_000,
        .newest_exchange_tokens = 90_000,
    });
    try std.testing.expect(impossible.accepted_handoff_tokens == null);
}

test "retained context selects whole parallel tool exchanges without shortening results" {
    const body = "large output " ** 2000;
    const calls = [_]types.ToolCall{
        .{ .id = "one", .name = "read_file", .arguments_json = "{}" },
        .{ .id = "two", .name = "read_file", .arguments_json = "{}" },
    };
    const results = [_]types.PersistedToolResult{
        .{ .tool_call_id = @constCast("one"), .tool_name = @constCast("read_file"), .status = .success, .output = @constCast(body), .output_bytes = body.len, .stored_output_bytes = body.len },
        .{ .tool_call_id = @constCast("two"), .tool_name = @constCast("read_file"), .status = .success, .output = @constCast(body), .output_bytes = body.len, .stored_output_bytes = body.len },
    };
    const steps = [_]types.ToolExecutionStep{
        .{ .assistant = @constCast("earlier work") },
        .{ .tool_calls = @constCast(&calls), .tool_results = @constCast(&results) },
    };
    const history = [_]HistoryTurn{
        .{ .assistant = .{ .user = .{ .text = @constCast("old request") }, .assistant = @constCast("old answer") } },
        .{ .assistant = .{ .user = .{ .text = @constCast("current request") }, .assistant = @constCast(""), .execution = .{ .tool_steps = @constCast(&steps) } } },
    };
    const selected = selectRecentContext(&history, 5000, null);
    try std.testing.expectEqual(@as(usize, 1), selected.cut.turns);
    try std.testing.expectEqual(@as(usize, 1), selected.cut.tool_steps);
    try std.testing.expect(selected.newest_exchange_tokens > 5000);
    try std.testing.expectEqualStrings(body, results[0].output);
    try std.testing.expectEqualStrings(body, results[1].output);
    const over_capacity = selectRecentContext(&history, 5000, 10_000);
    try std.testing.expectEqual(@as(usize, 2), over_capacity.cut.turns);
    try std.testing.expectEqual(@as(usize, 0), over_capacity.cut.tool_steps);
    try std.testing.expectEqual(@as(usize, 0), over_capacity.estimated_tokens);
    try std.testing.expectEqualStrings(body, results[0].output);
    try std.testing.expectEqualStrings(body, results[1].output);
}

test "manual compaction shares the budget and stops after a smaller source" {
    const plan = planCompaction(.{
        .trigger = .manual,
        .capabilities = .{
            .context_window = 1_000,
            .max_output_tokens = 200,
        },
        .request_tokens = 100,
        .source_tokens = 400,
    });
    try std.testing.expectEqual(CompactionDecision.compact, plan.decision);
    try std.testing.expectEqual(@as(?usize, 80), plan.accepted_handoff_tokens);
    try std.testing.expectEqual(@as(?usize, 200), plan.generation_tokens);

    const empty = planCompaction(.{
        .trigger = .manual,
        .capabilities = .{ .context_window = 1_000 },
        .request_tokens = 0,
        .source_tokens = 0,
    });
    try std.testing.expectEqual(CompactionDecision.no_op, empty.decision);
}

test "handoff acceptance is structural and bounded" {
    try std.testing.expectError(
        error.EmptyCompactionHandoff,
        validateCompactionHandoff(" \n\t", 10),
    );
    try std.testing.expectError(
        error.CompactionHandoffTooLarge,
        validateCompactionHandoff("one two three four five six seven eight nine ten eleven", 4),
    );
    try validateCompactionHandoff("# Objective\nContinue safely.", 16);
}
