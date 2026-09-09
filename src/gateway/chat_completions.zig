const std = @import("std");
const codec = @import("chat_completions_protocol.zig");
const client_mod = @import("client.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const gateway_step = @import("../core/agent/runtime/gateway_step.zig");
const review_messages = @import("vercel_protocol.zig");
const io = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const Allocator = std.mem.Allocator;

/// Every callback borrows the immutable definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    var identity = @import("../core/config/model_provider.zig").parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build },
        .model_catalog = .{ .context = context, .fetch_fn = fetch_catalog, .provider_id = identity },
        .cli_model_catalog = .{ .context = context, .fetch_fn = fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    return codec.build_request(alloc, request, .{ .tool_choice_mode = definition_at(raw).tool_choice_mode });
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    if (token) |value| {
        if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    switch (definition.auth) {
        .none => if (token != null) return error.UnexpectedConfiguredProviderCredential,
        .bearer => if (token == null) return error.MissingConfiguredProviderCredential,
    }
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    return post(alloc, definition, request, token, payload) catch |err| {
        request.attempt_evidence.network_failure = client_mod.networkFailureEvidence(err, request.delivery.load());
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (request.deadline) |deadline| if (expired(deadline)) return error.Timeout;
        return err;
    };
}

fn expired(deadline: std.Io.Clock.Timestamp) bool {
    return !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, deadline);
}

fn phase_deadline(milliseconds: i64, caller: ?std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    const phase = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(milliseconds) });
    if (caller) |deadline| if (std.Io.Clock.Timestamp.compare(deadline, .lt, phase)) return deadline;
    return phase;
}

const Opened = struct {
    request: ?std.http.Client.Request,
    pub fn deinit(self: *Opened, _: Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }
};

const Open = struct {
    client: *std.http.Client,
    uri: std.Uri,
    authorization: ?[]const u8,
    pub fn run(self: *Open) !Opened {
        var headers: std.http.Client.Request.Headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .user_agent = .{ .override = client_mod.user_agent },
        };
        if (self.authorization) |value| headers.authorization = .{ .override = value };
        return .{ .request = try self.client.request(.POST, self.uri, .{
            .headers = headers,
            .extra_headers = &.{.{ .name = "accept", .value = "text/event-stream" }},
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) };
    }
};

const Watch = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    fn start(self: *Watch, cancel: *std.atomic.Value(bool), deadline: ?std.Io.Clock.Timestamp, connection: std.Io.net.Stream) !void {
        self.done.store(false, .seq_cst);
        self.thread = if (deadline) |limit|
            try client_mod.spawnHttpCancelWatcherBounded(&self.done, cancel, limit, connection)
        else
            try client_mod.spawnHttpCancelWatcher(&self.done, cancel, connection);
    }
    fn stop(self: *Watch) void {
        self.done.store(true, .seq_cst);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
};

fn post(alloc: Allocator, definition: *const definitions.Definition, request: streams.ModelRequest, token: ?[]const u8, payload: []const u8) !streams.Result {
    const url = try definition.chat_url(alloc);
    defer alloc.free(url);
    const authorization = if (token) |value| try std.fmt.allocPrint(alloc, "Bearer {s}", .{value}) else null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    var client: std.http.Client = .{ .allocator = alloc, .io = io.getIo() };
    defer client.deinit();
    var uri = try std.Uri.parse(url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else return error.UnsupportedUriScheme;
    var operation = Open{ .client = &client, .uri = uri, .authorization = authorization };
    try request.admission.admit();
    var opened = try client_mod.runBoundedHttpOperation(Opened, alloc, request.cancel_flag, phase_deadline(30_000, request.deadline), &operation);
    defer opened.deinit(alloc);
    const http = &opened.request.?;
    var watch: Watch = .{};
    defer watch.stop();
    const head_deadline = phase_deadline(120_000, request.deadline);
    if (http.connection) |connection| try watch.start(request.cancel_flag, head_deadline, connection.stream_writer.stream);
    http.transfer_encoding = .{ .content_length = payload.len };
    var buffer: [8192]u8 = undefined;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    request.delivery.markPossiblySent();
    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(payload);
    try body.end();
    if (http.connection) |connection| try connection.flush();
    var response = http.receiveHead(&.{}) catch |err| {
        if (expired(head_deadline)) return error.Timeout;
        return err;
    };
    watch.stop();
    if (http.connection) |connection| try watch.start(request.cancel_flag, if (response.head.status == .ok) request.deadline else phase_deadline(30_000, request.deadline), connection.stream_writer.stream);
    var retry_after: ?u64 = null;
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
        retry_after = std.fmt.parseUnsigned(u64, std.mem.trim(u8, header.value, " \t"), 10) catch null;
        break;
    };
    var transfer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        const detail = reader.allocRemaining(alloc, .limited(64 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Provider error response exceeded the local limit"),
            else => return err,
        };
        if (token) |value| {
            var remaining = detail;
            while (std.mem.find(u8, remaining, value)) |index| {
                @memset(remaining[index..][0..value.len], '*');
                remaining = remaining[index + value.len ..];
            }
        }

        return .{ .failed = .{ .kind = switch (response.head.status) {
            .bad_request => .invalid_request,
            .unauthorized => .unauthorized,
            .forbidden => .forbidden,
            .payload_too_large => .request_too_large,
            .too_many_requests => .rate_limited,
            .internal_server_error => .server_error,
            .bad_gateway => .bad_gateway,
            .service_unavailable => .unavailable,
            .gateway_timeout => .gateway_timeout,
            else => .provider_error,
        }, .detail = detail, .retry_after_seconds = retry_after, .ownership = .owned } };
    }
    var limits: codec.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return codec.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag);
}

fn fetch_catalog(raw: ?*anyopaque, alloc: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    const definition = definition_at(raw);
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &entries);
    for (definition.model_metadata) |metadata| {
        const id = try alloc.dupe(u8, metadata.id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        try entries.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = metadata.supports_tool_use orelse false,
            .context_window = metadata.context_window orelse 0,
            .max_tokens = metadata.max_output_tokens orelse 0,
        });
    }
    return .{ .catalog = entries };
}

fn fetch_cli_catalog(raw: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const provenance = catalog.Provenance{ .access = catalog.AccessMetadata.init(input.access) };
    const result = fetch_catalog(raw, alloc, .{ .access = input.access, .endpoint = input.endpoint, .cancel_flag = input.cancel_flag }) catch
        return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
    switch (result) {
        .failure => |failure| return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = failure } },
        .catalog => |value| {
            var entries = value;
            defer catalog.freeModelCatalog(alloc, &entries);
            const ids = catalog.projectModelIds(alloc, entries.items) catch return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
            return .{ .loaded = .{ .ids = ids, .provenance = provenance } };
        },
    }
}

const Review = struct { definition: *const definitions.Definition, input: classifier.ProviderInput };
fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    var state = Review{ .definition = definition_at(raw), .input = input };
    return classifier.Reviewer.withTransportModel(.{ .context = &state, .build_fn = build_review, .send_fn = send_review }, input.cancel_flag, classifier.Reviewer.default_timeout_ms, state.definition.reviewer_model orelse request.review_turn.model).review(alloc, request);
}
fn build_review(raw: *anyopaque, alloc: Allocator, model: []const u8, _: []const u8, instructions: []const types.ChatMessage, messages: []const types.ChatMessage, target_id: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) ![]u8 {
    const state: *Review = @ptrCast(@alignCast(raw));
    const expanded = try review_messages.expandPendingToolReviewMessages(alloc, messages, target_id, deadline, cancel);
    defer alloc.free(expanded);
    const output_limit = if (state.definition.model(model)) |metadata| @min(metadata.max_output_tokens orelse 2048, 2048) else 2048;
    return build(@ptrCast(@constCast(state.definition)), alloc, .{ .model = model, .instructions = instructions, .messages = expanded, .tools = .{ .additional_functions = &.{classifier.function_schema} }, .tool_choice = .required, .provider_options = .{}, .max_output_tokens = output_limit });
}
fn ignore_event(_: *anyopaque, _: streams.Event) void {}
fn free_result(raw: *anyopaque, alloc: Allocator) void {
    const result: *streams.Result = @ptrCast(@alignCast(raw));
    result.deinit(alloc);
    alloc.destroy(result);
}
fn send_review(raw: *anyopaque, alloc: Allocator, model: []const u8, payload: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) !classifier.TransportOutcome {
    const state: *Review = @ptrCast(@alignCast(raw));
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var event_context: u8 = 0;
    var result = gateway_step.streamModelCompletion(bundle(state.definition).agent_stream.?, alloc, .{
        .credential = .{ .direct = .{ .secret_bytes = state.input.credential, .source = state.input.credential_source } },
        .model = model,
        .retry_count = 1,
        .messages = &.{},
        .tools = .{ .additional_functions = &.{classifier.function_schema} },
        .tool_choice = .required,
        .provider_options = .{},
        .prepared_request_body = payload,
        .trace_ctx = .{},
        .content_capture_limit = 16 * 1024,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &event_context, .emit_fn = ignore_event },
        .cancel_flag = cancel,
    }, state.input.usage, state.input.usage_allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .cancelled,
        error.Timeout => return .timed_out,
        else => return .permanent_failure,
    };
    errdefer result.deinit(alloc);
    if (result == .failed) {
        result.deinit(alloc);
        return .permanent_failure;
    }
    const owned = try alloc.create(streams.Result);
    owned.* = result;
    return .{ .completion = .{ .completion = owned.completed.completion, .context = owned, .deinit_fn = free_result } };
}
