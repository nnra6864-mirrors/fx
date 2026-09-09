const std = @import("std");
const environment = @import("subagent_environment.zig");
const app_mcp = @import("app_mcp_runtime.zig");
const model_cache = @import("model_cache_runtime.zig");
const adapter = @import("../subagent/agent_adapter.zig");
const authority = @import("../subagent/authority.zig");
const domain = @import("../subagent/domain.zig");
const execution = @import("../subagent/execution.zig");
const tool_host = @import("../subagent/tool_host.zig");
const tool_runtime = @import("../tooling/tool_runtime.zig");
const mcp_tools = @import("../tooling/tool_mcp_runtime.zig");
const tool_projection = @import("../tooling/tool_projection.zig");
const tool_set = @import("../tooling/tool_set.zig");
const web_search = @import("../tooling/web_search_runtime.zig");
const web_search_provider = @import("../tooling/web_search_provider.zig");
const web_fetch = @import("../tooling/web_fetch_runtime.zig");
const providers = @import("../gateway/provider_set.zig");
const credentials = @import("../auth/credentials.zig");
const oauth = @import("../auth/oauth_transport.zig");
const host_services = @import("../hosts/host.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const limits = @import("../config/context_limits.zig");
const context_contract = @import("../workspace/context_contract.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const permissions = @import("../permissions/permissions.zig");
const saved_permissions = @import("../permissions/session_permission_state.zig");
const terminal_client = @import("../terminal/client.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const elicitation = @import("../mcp/elicitation_interaction.zig");
const hooks = @import("../hooks/hooks.zig");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

/// Process services, not a selected App. MCP acquires its canonical lease on
/// every operation, so disconnect/auth/catalog revocation remains live. Rules
/// are read under the same mutex used by configured-rule replacement. These
/// service objects must remain address-stable until all retained hosts join.
pub const References = struct {
    mcp: *app_mcp.State,
    process_rules: *const types.PermissionRuleSet,
    authority_mutex: *std.Io.Mutex,
    providers: providers.Set,
    tools: tool_set.ToolSet,
    context_registry: context_contract.Registry,
    model_overlay: ?prompt_policy.ModelPromptOverlayFn = null,
    oauth_transport: oauth.Provider,
    secret_store: host_services.SecretStore,
    url_opener: host_services.UrlOpener,
    terminal: ?*terminal_client.Runtime = null,
    web_fetch: ?*web_fetch.Runtime = null,
    web_search_provider: ?web_search_provider.Provider = null,
    access_scope: workspace_access.AccessScope,
    process_access: ?*const workspace_access.WorkspaceAccess = null,
};

/// Native registration currently contains only sound/herdr foreground hooks.
/// Those handlers return before accessing App for subagent scope. Do not retain
/// their App pointers, and reject any new hook until it has a child-safe binding.
pub fn validateNativeLifecycle(view: hooks.RuntimeView) !void {
    if (view.pre_tool_use_handlers.len != 0 or view.stop_handlers.len != 0) return error.UnleasedChildLifecycleHook;
    for (view.post_turn_end_handlers) |handler| {
        if (!std.mem.eql(u8, handler.hook.name, "fx.sound.turn_end") and
            !std.mem.eql(u8, handler.hook.name, "fx.herdr.turn_end")) return error.UnleasedChildLifecycleHook;
    }
    for (view.attention_required_handlers) |handler| {
        if (!std.mem.eql(u8, handler.hook.name, "fx.sound.attention_required") and
            !std.mem.eql(u8, handler.hook.name, "fx.herdr.attention_required")) return error.UnleasedChildLifecycleHook;
    }
}

pub const Binding = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    root_id: []const u8,
    refs: References,
    root_authority: environment.RootAuthority = .{},
    routes_mutex: std.Io.Mutex = .init,
    runs: std.ArrayList(*Run) = .empty,

    /// Caller owns the binding until services() transfers it to Owner.create.
    pub fn create(alloc: Allocator, root_id: []const u8, refs: References, grants: []const types.PermissionGrant, saved: saved_permissions.State) !*Binding {
        const self = try alloc.create(Binding);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .arena = std.heap.ArenaAllocator.init(alloc), .root_id = "", .refs = refs };
        errdefer self.arena.deinit();
        errdefer self.root_authority.deinit(alloc);
        const arena = self.arena.allocator();
        self.root_id = try arena.dupe(u8, root_id);
        self.refs.access_scope.primary_directory = try arena.dupe(u8, refs.access_scope.primary_directory);
        const entries = try arena.dupe(workspace_access.Entry, refs.access_scope.additional_directories);
        for (entries) |*entry| entry.path = try arena.dupe(u8, entry.path);
        self.refs.access_scope.additional_directories = entries;
        self.refs.context_registry.default_provider.id = try arena.dupe(u8, refs.context_registry.default_provider.id);
        try self.root_authority.replaceGrants(alloc, grants);
        try self.root_authority.replaceSaved(alloc, saved);
        return self;
    }

    pub fn fromServices(value: environment.Services) ?*Binding {
        if (value.run_fn != run or value.resolve_fn != resolve) return null;
        return @ptrCast(@alignCast(value.context));
    }

    pub fn services(self: *Binding) environment.Services {
        return .{ .context = self, .root_authority = &self.root_authority, .run_fn = run, .resolve_fn = resolve, .release_fn = release, .retirement_fn = retirement };
    }

    pub fn deinit(self: *Binding) void {
        std.debug.assert(self.runs.items.len == 0);
        self.runs.deinit(self.alloc);
        self.root_authority.deinit(self.alloc);
        self.arena.deinit();
        self.alloc.destroy(self);
    }

    fn release(raw: *anyopaque, _: Allocator) void {
        const self: *Binding = @ptrCast(@alignCast(raw));
        self.deinit();
    }

    fn retirement(raw: *anyopaque) environment.Retirement {
        const self: *Binding = @ptrCast(@alignCast(raw));
        self.routes_mutex.lockUncancelable(io_mod.getIo());
        defer self.routes_mutex.unlock(io_mod.getIo());
        return if (self.runs.items.len == 0) .quiescent else .retained;
    }

    fn resolve(raw: *anyopaque, alloc: Allocator, root_id: []const u8) authority.HostResolveError!authority.HostAuthority {
        const self: *Binding = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, self.root_id, root_id)) return error.HostAuthorityUnavailable;
        self.refs.authority_mutex.lockUncancelable(io_mod.getIo());
        defer self.refs.authority_mutex.unlock(io_mod.getIo());
        self.root_authority.mutex.lockUncancelable(io_mod.getIo());
        defer self.root_authority.mutex.unlock(io_mod.getIo());
        if (!self.root_authority.grants_available or !self.root_authority.saved_available) return error.HostAuthorityUnavailable;
        const rules = self.refs.process_rules.*;
        const names = self.refs.mcp.snapshotToolNames(alloc, rules) catch |err| return authorityError(err);
        defer {
            for (names) |name| alloc.free(name);
            alloc.free(names);
        }
        var view = self.refs.mcp.snapshotAccessView(alloc, root_id, root_id, rules, !permissions.rulesDenyAllTargetsForTool(rules, "mcp_features")) catch |err| return authorityError(err);
        defer if (view) |*value| value.deinit(alloc);
        const resolved = try tool_host.captureHostAuthorityWithMcpView(alloc, .{ .tool_set = self.refs.tools, .mode = .full }, names, rules, self.root_authority.grants, self.root_authority.saved, if (view) |*value| value else null);
        debug_trace.eventf("subagent", "child_root_authority_resolved", .{}, "root_id={s} grants={d} integrations={d}", .{ self.root_id, self.root_authority.grants.len, names.len });
        return resolved;
    }

    fn run(raw: *anyopaque, inputs: *const environment.Inputs, child_host: *tool_host.Runtime, turn: *execution.TurnContext, message: domain.QueuedMessage, admission: domain.AdmissionSnapshot, cancel: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *Binding = @ptrCast(@alignCast(raw));
        debug_trace.eventf("subagent", "child_native_inputs_bound", .{}, "root_id={s} child_id={s} work_id={s} provider={s} authority_generation={d} context_bytes={d} catalog_entries={d}", .{ self.root_id, turn.child_id orelse "", turn.active_work_id orelse "", @tagName(admission.provider), admission.authority_generation, inputs.project_context.len, inputs.catalog.skills.len });
        var projection = tool_projection.buildModelToolProjectionForSet(turn.alloc, self.refs.tools, .{ .permission_mode = admission.permission_mode, .permission_rules = admission.rules }) catch return error.OutOfMemory;
        defer projection.deinit(turn.alloc);
        const child_dir = @import("../session/session_store.zig").sessionDirPath(turn.alloc, child_host.sessions.sessions_dir, turn.child_id orelse return error.AdmissionFailed) catch return error.OutOfMemory;
        defer turn.alloc.free(child_dir);
        turn.sessionRuntime().configureWebFetchArtifacts(turn.alloc, child_dir);
        var active = Run{
            .binding = self,
            .turn = turn,
            .cancel = cancel,
            .provider = self.refs.providers.select(admission.provider),
            .catalog = model_cache.Runtime.init(turn.alloc, inputs.gateway_models_path),
            .search = web_search.Runtime.init(.{ .provider = self.refs.web_search_provider }),
        };
        defer active.catalog.deinit();
        defer active.search.deinit();
        self.routes_mutex.lockUncancelable(io_mod.getIo());
        self.runs.append(self.alloc, &active) catch {
            self.routes_mutex.unlock(io_mod.getIo());
            return error.OutOfMemory;
        };
        self.routes_mutex.unlock(io_mod.getIo());
        defer active.detach();
        const tool_context = active.toolContext(inputs, child_host, admission);
        return adapter.run(.{
            .host = child_host,
            .tool_context = tool_context,
            .provider_set = self.refs.providers,
            .system_prompt = inputs.system_prompt,
            .model_prompt_overlay = if (self.refs.model_overlay) |overlay| overlay(admission.model) else inputs.model_prompt_overlay,
            .skill_catalog = inputs.catalog,
            .advertised_tool_names = projection.advertised_names,
            .advertised_functions = projection.advertised_functions,
            .custom_tool_guidance = projection.custom_guidance,
            .context_registry = self.refs.context_registry,
            .context_enabled = inputs.context_enabled,
            .project_context = inputs.project_context,
            .tool_context_binding = .{ .context = &active, .bind_fn = Run.bindTools },
        }, turn, message, admission, cancel);
    }

    /// Copies question data while the routes lock pins the child stack. No UI
    /// retains a worker pointer. Lock order is routes, then child worker.
    pub fn pendingQuestion(self: *Binding, alloc: Allocator) !?PendingQuestion {
        self.routes_mutex.lockUncancelable(io_mod.getIo());
        defer self.routes_mutex.unlock(io_mod.getIo());
        for (self.runs.items) |active| {
            if (!active.question_active or active.question_dismissed) continue;
            const snapshot = try active.turn.workerRuntime().snapshotPendingQuestionBatch(alloc) orelse continue;
            errdefer snapshot.deinit(alloc);
            const child_id = try alloc.dupe(u8, active.turn.child_id.?);
            errdefer alloc.free(child_id);
            const work_id = try alloc.dupe(u8, active.turn.active_work_id.?);
            errdefer alloc.free(work_id);
            const root_id = try alloc.dupe(u8, self.root_id);
            return .{ .target = .{ .root_id = root_id, .child_id = child_id, .work_id = work_id, .generation = active.question_generation }, .snapshot = snapshot };
        }
        return null;
    }

    /// Exact deliberate response only. A stale question cannot answer a later
    /// question in the same work. Generic main controls call dismissQuestion.
    pub fn answerQuestion(self: *Binding, target: QuestionTarget, alloc: Allocator, answers: ?[]const []const u8) !bool {
        self.routes_mutex.lockUncancelable(io_mod.getIo());
        defer self.routes_mutex.unlock(io_mod.getIo());
        const active = self.findQuestion(target) orelse return false;
        try active.turn.workerRuntime().submitQuestionBatchAnswer(alloc, answers);
        active.question_active = false;
        return true;
    }

    pub fn questionPending(self: *Binding, target: QuestionTarget) bool {
        self.routes_mutex.lockUncancelable(io_mod.getIo());
        defer self.routes_mutex.unlock(io_mod.getIo());
        return self.findQuestion(target) != null;
    }

    pub fn dismissQuestion(self: *Binding, target: QuestionTarget) bool {
        self.routes_mutex.lockUncancelable(io_mod.getIo());
        defer self.routes_mutex.unlock(io_mod.getIo());
        const active = self.findQuestion(target) orelse return false;
        active.question_dismissed = true;
        return true;
    }

    pub fn showQuestions(self: *Binding) void {
        self.routes_mutex.lockUncancelable(io_mod.getIo());
        defer self.routes_mutex.unlock(io_mod.getIo());
        for (self.runs.items) |active| active.question_dismissed = false;
    }

    fn findQuestion(self: *Binding, target: QuestionTarget) ?*Run {
        if (!std.mem.eql(u8, self.root_id, target.root_id)) return null;
        for (self.runs.items) |active| {
            if (active.question_active and active.question_generation == target.generation and
                std.mem.eql(u8, active.turn.child_id orelse "", target.child_id) and
                std.mem.eql(u8, active.turn.active_work_id orelse "", target.work_id)) return active;
        }
        return null;
    }
};

pub const QuestionTarget = domain.QuestionTarget;

pub const PendingQuestion = struct {
    target: QuestionTarget,
    snapshot: worker_runtime.PendingQuestionBatchSnapshot,

    pub fn deinit(self: *PendingQuestion, alloc: Allocator) void {
        alloc.free(self.target.root_id);
        alloc.free(self.target.child_id);
        alloc.free(self.target.work_id);
        self.snapshot.deinit(alloc);
        self.* = undefined;
    }
};

const Run = struct {
    binding: *Binding,
    turn: *execution.TurnContext,
    cancel: *std.atomic.Value(bool),
    provider: providers.Bundle,
    catalog: model_cache.Runtime,
    catalog_started: bool = false,
    search: web_search.Runtime,
    question_generation: u64 = 0,
    question_occupied: bool = false,
    question_active: bool = false,
    question_dismissed: bool = false,

    fn detach(self: *Run) void {
        const binding = self.binding;
        binding.routes_mutex.lockUncancelable(io_mod.getIo());
        defer binding.routes_mutex.unlock(io_mod.getIo());
        for (binding.runs.items, 0..) |active, index| {
            if (active == self) {
                _ = binding.runs.swapRemove(index);
                break;
            }
        }
    }

    fn toolContext(self: *Run, inputs: *const environment.Inputs, child_host: *tool_host.Runtime, admission: domain.AdmissionSnapshot) tool_runtime.Context {
        return .{
            .workspace_root = inputs.workspace_root,
            .access_scope = self.binding.refs.access_scope,
            .ignored_list_entries = inputs.ignored_list_entries,
            .max_list_entries = inputs.max_list_entries,
            .max_read_file_bytes = inputs.max_read_file_bytes,
            .max_read_file_lines = inputs.max_read_file_lines,
            .max_read_file_line_len = inputs.max_read_file_line_len,
            .max_command_output_bytes = inputs.max_command_output_bytes,
            .max_tool_result_bytes = inputs.max_tool_result_bytes,
            .api_key = inputs.api_key,
            .gateway_team = inputs.gateway_team,
            .credential_source = inputs.credential_source,
            .account_id = inputs.account_id,
            .model = admission.model,
            .provider = admission.provider,
            .provider_capabilities = self.provider.capabilities,
            .agent_stream_provider = self.provider.agent_stream_or_unavailable(),
            .permission_reviewer_provider = self.provider.permission_reviewer,
            .oauth_transport = self.binding.refs.oauth_transport,
            .secret_store = self.binding.refs.secret_store,
            .gateway_retry_count = inputs.gateway_retry_count,
            .gateway_chat_url = inputs.gateway_chat_url,
            .gateway_models_path = inputs.gateway_models_path,
            .agent_step_limit = inputs.agent_step_limit,
            .first_call_tool_choice = inputs.first_call_tool_choice,
            .fast_mode = inputs.fast_mode,
            .effort = admission.effort,
            .tool_registry = self.binding.refs.tools.registry,
            .permission_mode = admission.permission_mode,
            .permission_rules = admission.rules,
            .permission_grants = admission.grants,
            .worker = self.turn.workerRuntime(),
            .session = self.turn.sessionRuntime(),
            .session_allocator = self.turn.alloc,
            .cancel_flag = self.cancel,
            .permission_prompter = self.turn.permissionPrompter(),
            .subagent_host = child_host,
            .subagent_caller_id = self.turn.child_id,
            .session_child_capability = self.turn.childCapability() catch null,
            .managed_executions = self.turn.managedExecutionRuntime(),
            .ephemeral_command_replay = self.turn.managedExecutionRuntime().replayStore(),
            .terminal_client = self.binding.refs.terminal,
            .skills_dir = inputs.skills_dir,
            .context_limits = inputs.context_limits,
            .context_enabled = inputs.context_enabled,
            .context_registry = self.binding.refs.context_registry,
            .output_chunk_ctx = self,
            .on_output_chunk = outputChunk,
            .mcp_ctx = self.binding.refs.mcp,
            .mcp_has_tool = mcpHasTool,
            .mcp_validate_tool = mcpValidate,
            .mcp_call_tool = mcpCall,
            .mcp_search_tools = mcpSearch,
            .mcp_tool_schema = mcpSchema,
            .mcp_snapshot_tool = mcpSnapshot,
            .mcp_call_feature = mcpFeature,
            .mcp_input_responder = .{ .context = self, .capabilities = .{ .form = true, .url = true }, .legacy_url_manual_completion = true, .callback = respondToMcpInput },
            .web_fetch_runtime = self.binding.refs.web_fetch,
            .web_fetch_artifact_store = self.turn.sessionRuntime().webFetchArtifactStore(),
            .web_fetch_artifact_error = self.turn.sessionRuntime().webFetchArtifactError(),
            .model_capability_resolver = .{ .ctx = self, .resolve_fn = resolveModel },
            .interactive = false,
        };
    }

    fn bindTools(raw: *anyopaque, alloc: Allocator, ctx: *tool_runtime.Context) Allocator.Error!void {
        const self: *Run = @ptrCast(@alignCast(raw));
        if (self.binding.refs.process_access) |access| {
            self.binding.refs.authority_mutex.lockUncancelable(io_mod.getIo());
            defer self.binding.refs.authority_mutex.unlock(io_mod.getIo());
            const scope = access.scope(ctx.workspace_root);
            const entries = try alloc.dupe(workspace_access.Entry, scope.additional_directories);
            for (entries) |*entry| entry.path = try alloc.dupe(u8, entry.path);
            ctx.access_scope = .{ .primary_directory = ctx.workspace_root, .additional_directories = entries };
        }
        // Adapter invokes this before any parallel tools, after credential
        // routing. Subsequent calls only update the search's synchronized inputs.
        if (!self.catalog_started) {
            self.catalog_started = true;
            if (self.provider.model_catalog) |provider| self.catalog.startWarmup(provider, credentials.catalogAccessForCredentialAndAccount(ctx.credential_source, ctx.api_key, ctx.gateway_team, ctx.account_id));
        }
        self.search.configure(.{
            .api_key = ctx.api_key,
            .credential_source = ctx.credential_source,
            .gateway_team = ctx.gateway_team,
            .worker_model = ctx.model,
            .gateway_retry_count = ctx.gateway_retry_count,
            .gateway_chat_url = ctx.gateway_chat_url,
            .usage = &self.turn.sessionRuntime().usage,
            .usage_allocator = self.turn.alloc,
        });
        if (ctx.provider_capabilities.fx_search) ctx.web_search_backend = self.search.dispatchBackend();
    }

    fn resolveModel(raw: *anyopaque, _: Allocator, model: []const u8) model_capabilities.ResolveError!model_capabilities.Capabilities {
        const self: *Run = @ptrCast(@alignCast(raw));
        _ = try self.catalog.resolveForRequest(model, self.cancel);
        return model_capabilities.mergeCapabilities(self.provider.fallbackModelCapabilities(model), self.catalog.metadataForModel(model));
    }

    fn respondToMcpInput(raw: *anyopaque, alloc: Allocator, origin: mcp_tools.InputOrigin, required: mcp_tools.InputRequired) ![]const u8 {
        const self: *Run = @ptrCast(@alignCast(raw));
        return elicitation.respond(alloc, origin, required, .{
            .questioner = .{ .context = self, .ask_fn = askQuestion },
            .browser = .{ .context = self.binding.refs.url_opener.context, .open_fn = self.binding.refs.url_opener.open_fn },
            .capabilities = .{ .form = true, .url = true },
        });
    }

    fn askQuestion(raw: *anyopaque, alloc: Allocator, entries: []const types.QuestionBatchEntry, deadline_ms: i64, lifecycle_cancel: ?*const std.atomic.Value(bool)) !?[][]u8 {
        const self: *Run = @ptrCast(@alignCast(raw));
        // The canonical worker owns one question slot. Parallel MCP calls wait
        // for that slot without replacing its route or sharing cancellation.
        while (true) {
            if (self.cancel.load(.acquire) or (if (lifecycle_cancel) |flag| flag.load(.acquire) else false)) return null;
            const now = std.Io.Clock.awake.now(io_mod.getIo());
            if (@divFloor(now.nanoseconds, std.time.ns_per_ms) >= deadline_ms) return error.McpInputTimedOut;
            self.binding.routes_mutex.lockUncancelable(io_mod.getIo());
            if (!self.question_occupied) {
                if (self.question_generation == std.math.maxInt(u64)) {
                    self.binding.routes_mutex.unlock(io_mod.getIo());
                    return error.QuestionGenerationExhausted;
                }
                self.question_occupied = true;
                self.question_generation += 1;
                self.question_active = true;
                self.question_dismissed = false;
                self.binding.routes_mutex.unlock(io_mod.getIo());
                break;
            }
            self.binding.routes_mutex.unlock(io_mod.getIo());
            io_mod.sleep(20 * std.time.ns_per_ms);
        }
        defer {
            self.binding.routes_mutex.lockUncancelable(io_mod.getIo());
            self.question_active = false;
            self.question_occupied = false;
            self.binding.routes_mutex.unlock(io_mod.getIo());
        }
        var watch = QuestionDeadline{ .worker = self.turn.workerRuntime(), .cancel = self.cancel, .lifecycle_cancel = lifecycle_cancel, .deadline_ms = deadline_ms };
        const thread = try std.Thread.spawn(.{}, QuestionDeadline.run, .{&watch});
        defer {
            watch.done.store(true, .release);
            thread.join();
        }
        const answers = try self.turn.workerRuntime().requestMcpElicitationAnswerBlocking(alloc, entries);
        if (answers == null and watch.timed_out.load(.acquire)) return error.McpInputTimedOut;
        return answers;
    }
};

const QuestionDeadline = struct {
    worker: *worker_runtime.WorkerRuntime,
    cancel: *const std.atomic.Value(bool),
    lifecycle_cancel: ?*const std.atomic.Value(bool),
    deadline_ms: i64,
    done: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn run(self: *QuestionDeadline) void {
        while (!self.done.load(.acquire)) {
            const now = std.Io.Clock.awake.now(io_mod.getIo());
            const cancelled = self.cancel.load(.acquire) or
                (if (self.lifecycle_cancel) |flag| flag.load(.acquire) else false);
            const timed_out = @divFloor(now.nanoseconds, std.time.ns_per_ms) >= self.deadline_ms;
            if (cancelled or timed_out) {
                if (!cancelled and timed_out) self.timed_out.store(true, .release);
                if (self.worker.cancelPendingQuestionBatch()) return;
            }
            io_mod.sleep(20 * std.time.ns_per_ms);
        }
    }
};

fn testReferences(mcp_state: *app_mcp.State, rules: *types.PermissionRuleSet, mutex: *std.Io.Mutex) References {
    return .{
        .mcp = mcp_state,
        .process_rules = rules,
        .authority_mutex = mutex,
        .providers = providers.gateway_only(.{}),
        .tools = @import("../../builtins/tools.zig").advertisement_set,
        .context_registry = .{ .default_provider = context_contract.empty_provider },
        .oauth_transport = oauth.unavailable_provider,
        .secret_store = host_services.unavailable_secret_store,
        .url_opener = host_services.unavailable_url_opener,
        .access_scope = workspace_access.AccessScope.primaryOnly("/original"),
    };
}

test "native subagent authority observes root grant revocation and process rule updates" {
    const alloc = std.testing.allocator;
    var mcp_state = app_mcp.State{};
    defer mcp_state.deinit(alloc);
    var mutex: std.Io.Mutex = .init;
    var rules = types.PermissionRuleSet{};
    var grants = [_]types.PermissionGrant{.{ .tool_name = @constCast("read_file"), .target_path = @constCast("/original/file") }};
    const binding = try Binding.create(alloc, "original", testReferences(&mcp_state, &rules, &mutex), &grants, .{});
    defer binding.deinit();
    const services = binding.services();
    var original = try services.resolve_fn(services.context, alloc, "original");
    defer original.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), original.grants.len);
    // Mutating selection's backing slice cannot mutate the owned root grants.
    grants[0].target_path = @constCast("/other/file");
    var unchanged = try services.resolve_fn(services.context, alloc, "original");
    defer unchanged.deinit(alloc);
    try std.testing.expectEqualStrings("/original/file", unchanged.grants[0].target_path);
    try binding.root_authority.replaceGrants(alloc, &.{});
    var revoked = try services.resolve_fn(services.context, alloc, "original");
    defer revoked.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), revoked.grants.len);
    try std.testing.expect(original.generation != revoked.generation);
    var deny = [_]types.PermissionRule{.{ .permission = @constCast("read_file"), .pattern = @constCast("*"), .action = .deny }};
    mutex.lockUncancelable(io_mod.getIo());
    rules = .{ .rules = &deny };
    mutex.unlock(io_mod.getIo());
    var process_updated = try services.resolve_fn(services.context, alloc, "original");
    defer process_updated.deinit(alloc);
    try std.testing.expectEqual(.deny, process_updated.rules.rules[0].action);
    try std.testing.expectEqual(.deny, try permissions.ruleDecisionFor(alloc, process_updated.rules, "/original", "read_file", "/original/file", .path_existing));
    try std.testing.expect(revoked.generation != process_updated.generation);
    var saved_rules = [_]saved_permissions.Rule{.{
        .id = .{ .value = 1 },
        .key = try saved_permissions.RuleKey.init(.structured_tool, "read_file:/original/file"),
        .display_identity = @constCast("read original file"),
        .decision = .deny,
        .generation = 1,
    }};
    try binding.root_authority.replaceSaved(alloc, .{ .next_generation = 2, .rules = .fromOwnedSlice(&saved_rules) });
    var saved_updated = try services.resolve_fn(services.context, alloc, "original");
    defer saved_updated.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), saved_updated.permission_state.rules.items.len);
    try std.testing.expectEqual(.deny, saved_permissions.decide(saved_updated.permission_state, saved_rules[0].key));
    try std.testing.expect(saved_updated.generation != process_updated.generation);
    try std.testing.expectError(error.HostAuthorityUnavailable, services.resolve_fn(services.context, alloc, "selected-other"));
}

test "native subagent runner uses owned credentials and context after detach" {
    const stream = @import("../agent/stream_provider.zig");
    const catalog = @import("../gateway/model_catalog.zig");
    const session_store = @import("../session/session_store.zig");
    const Fixture = struct {
        entered: std.Io.Event = .unset,
        release: std.atomic.Value(bool) = .init(false),
        original: std.atomic.Value(bool) = .init(false),
        catalog_calls: std.atomic.Value(usize) = .init(0),
        host: ?*tool_host.Runtime = null,
        result: ?tool_host.ManagedExecutionResult = null,
        failure: ?anyerror = null,

        fn fetch(raw: ?*anyopaque, _: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (std.mem.eql(u8, input.access.authorizationCredential() orelse "", "synthetic-original")) _ = self.catalog_calls.fetchAdd(1, .monotonic);
            return .{ .catalog = .empty };
        }

        fn send(raw: ?*anyopaque, _: Allocator, request: stream.ModelRequest) !stream.Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try request.admission.admit();
            request.delivery.markPossiblySent();
            self.entered.set(io_mod.getIo());
            while (!self.release.load(.acquire) and !request.cancel_flag.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
            var original_prompt = false;
            for (request.instructions) |instruction| {
                if (std.mem.indexOf(u8, instruction.content orelse "", "original system") != null) original_prompt = true;
            }
            self.original.store(original_prompt and std.mem.eql(u8, request.credential.secret() orelse "", "synthetic-original"), .release);
            request.events.emit(.{ .content_delta = "native child completed" });
            return .{ .completed = .{ .completion = .{ .content = "native child completed", .finish_reason = .stop } } };
        }

        fn execute(self: *@This()) void {
            var request = @import("../subagent/model_contract.zig").Request{ .run = .{ .task = @constCast("bounded native child") } };
            self.result = self.host.?.executeManaged(std.testing.allocator, &request, .{
                .caller_id = "original",
                .invocation_id = "native-call",
                .parent_permission_mode = .yolo,
                .defaults = .{ .provider = .gateway, .model = "test/native-child", .effort = .auto, .conversation_language = @import("../session/session.zig").ConversationLanguage.literal("en") },
                .max_result_bytes = 4096,
                .timestamp_ms = 1,
            }) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try session_store.Store.initFromHome(alloc, home, home);
    defer store.deinit(alloc);
    var writer: ?session_store.LoadedWritableSession = try store.startWritableSession(alloc, .{
        .id = @constCast("original"),
        .origin_workspace_root = @constCast(home),
        .workspace_root = @constCast(home),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = @import("../session/session.zig").ConversationLanguage.literal("en"),
        .preferences = .{ .model = @constCast("test/native-child"), .effort = .auto, .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    });
    defer if (writer) |*value| value.deinit(alloc);
    var mcp_state = app_mcp.State{};
    defer mcp_state.deinit(alloc);
    var rules = types.PermissionRuleSet{};
    var mutex: std.Io.Mutex = .init;
    var fixture = Fixture{};
    defer if (fixture.result) |result| alloc.free(result.body);
    var refs = testReferences(&mcp_state, &rules, &mutex);
    refs.access_scope = workspace_access.AccessScope.primaryOnly(home);
    refs.providers.gateway.agent_stream = .{ .context = &fixture, .stream_fn = Fixture.send };
    refs.providers.gateway.model_catalog = .{ .context = &fixture, .fetch_fn = Fixture.fetch };
    const binding = try Binding.create(alloc, "original", refs, &.{}, .{});
    var binding_owned = true;
    defer if (binding_owned) binding.deinit();
    var owner = environment.Owner{};
    defer owner.shutdown();
    var key = "synthetic-original".*;
    var system_prompt = "original system".*;
    fixture.host = try owner.create(alloc, &store, &writer.?, .{
        .root_id = "original",
        .workspace_root = home,
        .system_prompt = &system_prompt,
        .api_key = &key,
        .credential_source = .ai_gateway_api_key,
        .gateway_chat_url = "http://127.0.0.1/unused",
        .max_list_entries = 10,
        .max_read_file_bytes = 4096,
        .max_read_file_lines = 50,
        .max_read_file_line_len = 4096,
        .max_command_output_bytes = 4096,
        .max_tool_result_bytes = 4096,
        .gateway_retry_count = 1,
        .agent_step_limit = 2,
    }, binding.services());
    binding_owned = false;
    const thread = try std.Thread.spawn(.{}, Fixture.execute, .{&fixture});
    var joined = false;
    defer if (!joined) {
        fixture.release.store(true, .release);
        thread.join();
    };
    try fixture.entered.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    try owner.detach(&writer);
    {
        binding.routes_mutex.lockUncancelable(io_mod.getIo());
        defer binding.routes_mutex.unlock(io_mod.getIo());
        try std.testing.expectEqual(@as(usize, 1), binding.runs.items.len);
        const child = binding.runs.items[0];
        try std.testing.expectEqual(&child.turn.sessionRuntime().usage, child.search.usage.?);
        try std.testing.expectEqualStrings("synthetic-original", child.search.api_key);
        try std.testing.expectEqualStrings("test/native-child", child.search.worker_model);
        try std.testing.expectEqualStrings("http://127.0.0.1/unused", child.search.gateway_chat_url);
    }
    key[0] = 'x';
    system_prompt[0] = 'x';
    refs.providers.gateway = .{};
    fixture.release.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expect(fixture.failure == null);
    if (!fixture.result.?.success) std.debug.print("native child result: {s}\n", .{fixture.result.?.body});
    try std.testing.expect(fixture.result.?.success);
    try std.testing.expect(fixture.original.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), fixture.catalog_calls.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, fixture.result.?.body, "native child completed") != null);
    try std.testing.expectEqual(fixture.host.?, try owner.attach("original", &writer));
}

test "native subagent MCP questions route to exact child work and ignore main cancellation" {
    const alloc = std.testing.allocator;
    var mcp_state = app_mcp.State{};
    defer mcp_state.deinit(alloc);
    var rules = types.PermissionRuleSet{};
    var mutex: std.Io.Mutex = .init;
    const binding = try Binding.create(alloc, "original", testReferences(&mcp_state, &rules, &mutex), &.{}, .{});
    defer binding.deinit();
    var turn = execution.TurnContext{
        .alloc = alloc,
        .runtime = .{ .max_history_turns = 8 },
        .managed_executions = @import("../execution/managed_execution.zig").Runtime.init(alloc),
        .loaded = undefined, // This worker-only test never accesses session storage.
        .child_id = "child",
        .active_work_id = "work",
    };
    defer turn.deinit();
    try std.testing.expect(turn.workerRuntime().beginDirectProcessing(1));
    defer turn.workerRuntime().finishProcessing();
    var cancel: std.atomic.Value(bool) = .init(false);
    var active = Run{
        .binding = binding,
        .turn = &turn,
        .cancel = &cancel,
        .provider = .{},
        .catalog = model_cache.Runtime.init(alloc, "/v1/models"),
        .search = web_search.Runtime.init(.{}),
    };
    defer active.catalog.deinit();
    defer active.search.deinit();
    try binding.runs.append(alloc, &active);
    defer active.detach();
    const Asked = struct {
        active: *Run,
        answers: ?[][]u8 = null,
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            defer self.done.store(true, .release);
            const now = std.Io.Clock.awake.now(io_mod.getIo());
            self.answers = Run.askQuestion(self.active, std.testing.allocator, &.{.{
                .question = "Child MCP consent",
                .options = &.{ .{ .label = "Accept" }, .{ .label = "Decline" } },
            }}, @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms) + 5000), null) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var asked = Asked{ .active = &active };
    defer if (asked.answers) |answers| {
        for (answers) |answer| alloc.free(answer);
        alloc.free(answers);
    };
    const thread = try std.Thread.spawn(.{}, Asked.run, .{&asked});
    var joined = false;
    defer if (!joined) {
        cancel.store(true, .release);
        thread.join();
    };
    var pending: ?PendingQuestion = null;
    defer if (pending) |*value| value.deinit(alloc);
    for (0..1000) |_| {
        pending = try binding.pendingQuestion(alloc);
        if (pending != null) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    const target = (pending orelse return error.QuestionNotPublished).target;
    try std.testing.expectEqualStrings("child", target.child_id);
    try std.testing.expectEqualStrings("work", target.work_id);
    try std.testing.expectEqual(.mcp_elicitation, pending.?.snapshot.source);
    var second = Asked{ .active = &active };
    defer if (second.answers) |answers| {
        for (answers) |answer| alloc.free(answer);
        alloc.free(answers);
    };
    const second_thread = try std.Thread.spawn(.{}, Asked.run, .{&second});
    var second_joined = false;
    defer if (!second_joined) {
        cancel.store(true, .release);
        second_thread.join();
    };
    var main_worker = worker_runtime.WorkerRuntime{};
    defer main_worker.deinit(alloc);
    main_worker.requestCancel();
    io_mod.sleep(40 * std.time.ns_per_ms);
    try std.testing.expect(!asked.done.load(.acquire));
    try std.testing.expect(!second.done.load(.acquire));
    try std.testing.expect(!cancel.load(.acquire));
    try std.testing.expect(binding.dismissQuestion(target));
    try std.testing.expect((try binding.pendingQuestion(alloc)) == null);
    try std.testing.expect(!asked.done.load(.acquire));
    binding.showQuestions();
    var shown = (try binding.pendingQuestion(alloc)).?;
    defer shown.deinit(alloc);
    try std.testing.expectEqual(target.generation, shown.target.generation);
    var stale = target;
    stale.root_id = "other-root";
    try std.testing.expect(!try binding.answerQuestion(stale, alloc, &.{"Decline"}));
    stale = target;
    stale.generation += 1;
    try std.testing.expect(!try binding.answerQuestion(stale, alloc, &.{"Decline"}));
    stale = target;
    stale.work_id = "other-work";
    try std.testing.expect(!try binding.answerQuestion(stale, alloc, &.{"Decline"}));
    try std.testing.expect(try binding.answerQuestion(target, alloc, &.{"Accept"}));
    thread.join();
    joined = true;
    try std.testing.expect(asked.failure == null);
    try std.testing.expectEqualStrings("Accept", asked.answers.?[0]);
    try std.testing.expect(!try binding.answerQuestion(target, alloc, &.{"Decline"}));
    var next: ?PendingQuestion = null;
    defer if (next) |*value| value.deinit(alloc);
    for (0..1000) |_| {
        next = try binding.pendingQuestion(alloc);
        if (next != null) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    const next_target = (next orelse return error.QuestionNotPublished).target;
    try std.testing.expectEqual(target.generation + 1, next_target.generation);
    try std.testing.expect(try binding.answerQuestion(next_target, alloc, &.{"Decline"}));
    second_thread.join();
    second_joined = true;
    try std.testing.expect(second.failure == null);
    try std.testing.expectEqualStrings("Decline", second.answers.?[0]);
    try std.testing.expect((try main_worker.snapshotPendingQuestionBatch(alloc)) == null);
}

test "native subagent tool leases refresh directory authority and search credentials" {
    const alloc = std.testing.allocator;
    var mcp_state = app_mcp.State{};
    defer mcp_state.deinit(alloc);
    var rules = types.PermissionRuleSet{};
    var mutex: std.Io.Mutex = .init;
    var entries = [_]workspace_access.Entry{.{ .path = @constCast("/additional"), .saved = false, .command_line = true, .available = true, .active = true }};
    var access = workspace_access.WorkspaceAccess{ .entries = &entries };
    var refs = testReferences(&mcp_state, &rules, &mutex);
    refs.process_access = &access;
    const binding = try Binding.create(alloc, "original", refs, &.{}, .{});
    defer binding.deinit();
    var turn = execution.TurnContext{
        .alloc = alloc,
        .runtime = .{ .max_history_turns = 8 },
        .managed_executions = @import("../execution/managed_execution.zig").Runtime.init(alloc),
        .loaded = undefined, // bindTools only needs the child's usage owner.
    };
    defer turn.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    var active = Run{
        .binding = binding,
        .turn = &turn,
        .cancel = &cancel,
        .provider = .{},
        .catalog = model_cache.Runtime.init(alloc, "/v1/models"),
        .search = web_search.Runtime.init(.{}),
    };
    defer active.catalog.deinit();
    defer active.search.deinit();
    // Initialize exactly the fields the binding consumes. No main App or main
    // worker/session participates in constructing these per-operation services.
    var ctx: tool_runtime.Context = undefined;
    ctx.workspace_root = "/original";
    ctx.api_key = "first-key";
    ctx.credential_source = .ai_gateway_api_key;
    ctx.account_id = null;
    ctx.gateway_team = null;
    ctx.model = "child-model";
    ctx.gateway_retry_count = 1;
    ctx.gateway_chat_url = "http://127.0.0.1/child";
    ctx.provider_capabilities = .{ .fx_search = true };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try Run.bindTools(&active, arena.allocator(), &ctx);
    const before = ctx.access_scope.?;
    try std.testing.expect(before.contains("/additional/file"));
    try std.testing.expectEqual(&turn.sessionRuntime().usage, active.search.usage.?);
    try std.testing.expect(ctx.web_search_backend.?.ctx == @as(*anyopaque, @ptrCast(&active.search)));
    mutex.lockUncancelable(io_mod.getIo());
    entries[0].active = false;
    mutex.unlock(io_mod.getIo());
    ctx.api_key = "refreshed-key";
    try Run.bindTools(&active, arena.allocator(), &ctx);
    try std.testing.expect(!ctx.access_scope.?.contains("/additional/file"));
    try std.testing.expect(ctx.access_scope.?.contains("/original/file"));
    try std.testing.expect(before.contains("/additional/file"));
    try std.testing.expectEqualStrings("refreshed-key", active.search.api_key);
    try std.testing.expectEqualStrings("child-model", active.search.worker_model);
}

fn authorityError(err: anyerror) authority.HostResolveError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.HostAuthorityUnavailable;
}

fn outputChunk(raw: *anyopaque, _: ?types.ToolLifecycleId, _: @import("../tooling/command_output_content.zig").Stream, text: []const u8) !void {
    const self: *Run = @ptrCast(@alignCast(raw));
    self.turn.appendLiveText(text);
}
fn mcp(raw: *anyopaque) *app_mcp.State {
    return @ptrCast(@alignCast(raw));
}
fn mcpHasTool(raw: *anyopaque, name: []const u8, access: mcp_tools.Access) bool {
    return mcp(raw).hasTool(name, access);
}
fn mcpValidate(raw: *anyopaque, alloc: Allocator, name: []const u8, arguments: []const u8, access: mcp_tools.Access) !mcp_tools.ValidationResult {
    return mcp(raw).validateTool(alloc, name, arguments, access);
}
fn mcpCall(raw: *anyopaque, alloc: Allocator, name: []const u8, arguments: []const u8, max_bytes: usize, options: mcp_tools.CallOptions) !?mcp_tools.CallResult {
    return mcp(raw).callTool(alloc, name, arguments, max_bytes, options);
}
fn mcpSearch(raw: *anyopaque, alloc: Allocator, request: mcp_tools.SearchRequest, rules: types.PermissionRuleSet, context_limits: limits.Values, access: mcp_tools.Access, cancel: ?*std.atomic.Value(bool)) !mcp_tools.SearchResult {
    return mcp(raw).searchTools(alloc, request, rules, context_limits, access, cancel);
}
fn mcpSchema(raw: *anyopaque, alloc: Allocator, name: []const u8, rules: types.PermissionRuleSet, context_limits: limits.Values, access: mcp_tools.Access, cancel: ?*std.atomic.Value(bool)) !?mcp_tools.ToolSchemaResult {
    return mcp(raw).toolSchema(alloc, name, rules, context_limits, access, cancel);
}
fn mcpSnapshot(raw: *anyopaque, alloc: Allocator, name: []const u8, known: mcp_tools.Binding, rules: types.PermissionRuleSet, context_limits: limits.Values, access: mcp_tools.Access) !mcp_tools.DefinitionSnapshot {
    return mcp(raw).snapshotToolDefinition(alloc, name, known, rules, context_limits, access);
}
fn mcpFeature(raw: *anyopaque, alloc: Allocator, request: mcp_tools.FeatureRequest, options: mcp_tools.FeatureCallOptions) !mcp_tools.FeatureResult {
    var lease = mcp(raw).acquire() orelse return error.McpRuntimeUnavailable;
    defer lease.deinit();
    return lease.runtime.callFeatureForModel(alloc, request, options);
}
