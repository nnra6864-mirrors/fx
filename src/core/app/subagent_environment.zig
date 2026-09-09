const std = @import("std");
const authority = @import("../subagent/authority.zig");
const domain = @import("../subagent/domain.zig");
const execution = @import("../subagent/execution.zig");
const tool_host = @import("../subagent/tool_host.zig");
const session_store = @import("../session/session_store.zig");
const session_child_store = @import("../session/session_child_store.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const skill_invocation = @import("../skills/skill_invocation.zig");
const context_limits = @import("../config/context_limits.zig");
const types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;
const max_hosts = 16;
const max_input_bytes = 4 * 1024 * 1024;
const max_catalog_entries = 4096;

/// Immutable original-session inputs. Environment copies every slice. Live
/// permission grants deliberately do not belong here: Services resolves them.
pub const Inputs = struct {
    root_id: []const u8,
    workspace_root: []const u8,
    system_prompt: []const u8,
    project_context: []const u8 = "",
    model_prompt_overlay: ?[]const u8 = null,
    api_key: []const u8 = "",
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    gateway_chat_url: []const u8,
    gateway_models_path: []const u8 = "/v1/models",
    skills_dir: []const u8 = "",
    ignored_list_entries: []const []const u8 = &.{},
    catalog: skill_invocation.Catalog = .{ .skills = &.{} },
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize,
    gateway_retry_count: usize,
    agent_step_limit: usize,
    first_call_tool_choice: types.ToolChoice = .auto,
    fast_mode: bool = false,
    context_limits: context_limits.Values = .{},
    context_enabled: bool = true,
};

/// One owned service lease. The backend must own or lease its provider, tool
/// schemas, workspace access, MCP, hooks, credential refresh and model catalog
/// references, never App or a copy of App. run_fn must bind output, approval,
/// cancellation, replay and usage to the supplied child turn, not the main one.
///
/// resolve_fn snapshots CURRENT original-root authority, including revocation,
/// under the authority owner's lock. A captured grant snapshot is not a lease.
/// release_fn runs only after host workers and their approval routes have joined.
/// No native lease is installed until receipt and service-owner integration.
pub const Services = struct {
    context: *anyopaque,
    root_authority: ?*RootAuthority = null,
    run_fn: *const fn (
        *anyopaque,
        *const Inputs,
        *tool_host.Runtime,
        *execution.TurnContext,
        domain.QueuedMessage,
        domain.AdmissionSnapshot,
        *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome,
    resolve_fn: *const fn (*anyopaque, Allocator, []const u8) authority.HostResolveError!authority.HostAuthority,
    release_fn: *const fn (*anyopaque, Allocator) void,
    /// quiescent means all external callbacks have drained and exact-work
    /// publication/delivery ownership is settled. Absent receipt integration
    /// cannot authorize retirement, even when no child worker is running.
    retirement_fn: ?*const fn (*anyopaque) Retirement = null,
};

pub const Retirement = enum { retained, quiescent };

const saved_permissions = @import("../permissions/session_permission_state.zig");

/// Mutable authority belongs to the original root, not to the selected session
/// slot. Callers take the process authority mutex before this mutex when both
/// are needed. Failed updates invalidate the view rather than retaining grants.
pub const RootAuthority = struct {
    mutex: std.Io.Mutex = .init,
    grants: []types.PermissionGrant = &.{},
    saved: saved_permissions.State = .{},
    grants_available: bool = true,
    saved_available: bool = true,

    pub fn replaceGrants(self: *RootAuthority, alloc: Allocator, grants: []const types.PermissionGrant) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const owned = types.dupePermissionGrantSlice(alloc, grants) catch |err| {
            self.grants_available = false;
            return err;
        };
        types.freePermissionGrantSlice(alloc, self.grants);
        self.grants = owned;
        self.grants_available = true;
    }

    pub fn replaceSaved(self: *RootAuthority, alloc: Allocator, saved: saved_permissions.State) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const owned = saved_permissions.dupe(alloc, saved) catch |err| {
            self.saved_available = false;
            return err;
        };
        self.saved.deinit(alloc);
        self.saved = owned;
        self.saved_available = true;
    }

    pub fn deinit(self: *RootAuthority, alloc: Allocator) void {
        types.freePermissionGrantSlice(alloc, self.grants);
        self.saved.deinit(alloc);
        self.* = undefined;
    }
};

pub const ApprovalTarget = struct {
    child_id: []const u8,
    request_id: []const u8,

    fn eql(self: ApprovalTarget, other: ApprovalTarget) bool {
        return std.mem.eql(u8, self.child_id, other.child_id) and
            std.mem.eql(u8, self.request_id, other.request_id);
    }
};

/// Heap-stable callback target, independent of selection. The store is borrowed
/// from Persistence, which must outlive this owner. The arena is immutable after
/// construction and is never used for allocations by concurrent child workers.
const Environment = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    inputs: Inputs,
    services: Services,
    host: *tool_host.Runtime,
    parked_writer: ?session_store.LoadedWritableSession = null,
    dismissed_approval: ?ApprovalTarget = null,

    fn clearDismissedApproval(self: *Environment) void {
        if (self.dismissed_approval) |target| {
            self.alloc.free(target.child_id);
            self.alloc.free(target.request_id);
        }
        self.dismissed_approval = null;
    }

    /// Transfers services only on success. The caller retains them on failure.
    fn create(alloc: Allocator, store: *session_store.Store, root_writer: *const session_store.LoadedWritableSession, inputs: Inputs, services: Services) !*Environment {
        try domain.validateId(inputs.root_id);
        try validateInputBounds(inputs);
        const self = try alloc.create(Environment);
        errdefer alloc.destroy(self);
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const owned = try cloneInputs(arena.allocator(), inputs);
        errdefer std.crypto.secureZero(u8, @constCast(owned.api_key));
        self.* = .{
            .alloc = alloc,
            .arena = arena,
            .inputs = owned,
            .services = services,
            .host = undefined,
        };
        self.host = try tool_host.Runtime.create(alloc, store, owned.root_id, .{
            .context = self,
            .resolve_fn = resolve,
        }, .{ .context = self, .run_fn = run });
        errdefer self.host.deinit();
        const root_path = try session_store.sessionDirPath(alloc, store.sessions_dir, inputs.root_id);
        defer alloc.free(root_path);
        self.host.delivery_result_capability = try session_child_store.SessionChildCapability.init(alloc, root_writer.log.dir.dir, root_path, .writable);
        return self;
    }

    fn destroy(self: *Environment) void {
        debug_trace.eventf("subagent", "child_host_join_started", .{}, "root_id={s}", .{self.inputs.root_id});
        self.host.deinit();
        debug_trace.eventf("subagent", "child_host_joined", .{}, "root_id={s}", .{self.inputs.root_id});
        self.services.release_fn(self.services.context, self.alloc);
        if (self.parked_writer) |*writer| writer.deinit(self.alloc);
        self.clearDismissedApproval();
        std.crypto.secureZero(u8, @constCast(self.inputs.api_key));
        self.arena.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    fn resolve(raw: ?*anyopaque, alloc: Allocator, root_id: []const u8) authority.HostResolveError!authority.HostAuthority {
        const self: *Environment = @ptrCast(@alignCast(raw.?));
        if (!std.mem.eql(u8, root_id, self.inputs.root_id)) return error.HostAuthorityUnavailable;
        return self.services.resolve_fn(self.services.context, alloc, self.inputs.root_id);
    }

    fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, admission: domain.AdmissionSnapshot, cancel: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *Environment = @ptrCast(@alignCast(raw.?));
        if (!std.mem.eql(u8, admission.parent_id, self.inputs.root_id)) return error.AdmissionFailed;
        return self.services.run_fn(self.services.context, &self.inputs, self.host, turn, message, admission, cancel);
    }
};

/// Selection and lifetime registry, not an execution scheduler. The mutex
/// publishes first-prompt host creation to the UI. Session transitions still
/// settle the main worker before moving its writer. Public callers drain before
/// shutdown. Detach never rebinds callbacks, recovers work or signals cancellation.
pub const Owner = struct {
    mutex: std.Io.Mutex = .init,
    entries: [max_hosts]?*Environment = @splat(null),
    selected: ?usize = null,
    closed: bool = false,

    /// Creates only a new original-root host, before any child admission. Services
    /// transfer on success. Capacity and duplicate checks precede host recovery.
    /// root_writer must hold the writer lock and use alloc; it stays caller-owned
    /// while selected. store must remain address-stable until shutdown.
    pub fn create(self: *Owner, alloc: Allocator, store: *session_store.Store, root_writer: *const session_store.LoadedWritableSession, inputs: Inputs, services: Services) !*tool_host.Runtime {
        self.reapDetached();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.OwnerClosed;
        if (!std.mem.eql(u8, root_writer.active_id, inputs.root_id)) return error.WrongRoot;
        if (self.find(inputs.root_id) != null) return error.HostAlreadyRetained;
        if (self.selected != null) return error.SelectionOccupied;
        const index = for (self.entries, 0..) |entry, index| {
            if (entry == null) break index;
        } else return error.HostCapacityExceeded;
        const environment = try Environment.create(alloc, store, root_writer, inputs, services);
        self.entries[index] = environment;
        self.selected = index;
        debug_trace.eventf("subagent", "child_host_created", .{}, "root_id={s} slot={d}", .{ inputs.root_id, index });
        return environment.host;
    }

    /// Moves the original writer out of selection without releasing its process
    /// lock. Caller settles pending parent writes and drains parent callers first.
    /// On error both selection and writer ownership remain unchanged.
    pub fn detach(self: *Owner, selected_writer: *?session_store.LoadedWritableSession) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.OwnerClosed;
        const index = self.selected orelse return error.NoSelectedHost;
        const entry = self.entries[index].?;
        const writer = if (selected_writer.*) |*value| value else return error.WriterUnavailable;
        if (!std.mem.eql(u8, writer.active_id, entry.inputs.root_id)) return error.WrongRoot;
        std.debug.assert(entry.parked_writer == null);
        entry.parked_writer = writer.*;
        selected_writer.* = null;
        self.selected = null;
        debug_trace.eventf("subagent", "child_host_detached", .{}, "root_id={s} writer_retained=true child_cancelled=false", .{entry.inputs.root_id});
    }

    /// Moves the same writer and returns the SAME host, with no recovery/rebind.
    /// The returned pointer remains valid through detach, until shutdown.
    pub fn attach(self: *Owner, root_id: []const u8, selected_writer: *?session_store.LoadedWritableSession) !*tool_host.Runtime {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.OwnerClosed;
        if (self.selected != null or selected_writer.* != null) return error.SelectionOccupied;
        const index = self.find(root_id) orelse return error.HostNotRetained;
        const entry = self.entries[index].?;
        if (entry.parked_writer == null) return error.WriterUnavailable;
        selected_writer.* = entry.parked_writer;
        entry.parked_writer = null;
        self.selected = index;
        debug_trace.eventf("subagent", "child_host_attached", .{}, "root_id={s} writer_reused=true child_restarted=false", .{root_id});
        return entry.host;
    }

    pub fn selectedHost(self: *Owner) ?*tool_host.Runtime {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const index = self.selected orelse return null;
        return self.entries[index].?.host;
    }

    pub fn selectedServices(self: *Owner) ?Services {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const index = self.selected orelse return null;
        return self.entries[index].?.services;
    }

    pub fn selectedAuthority(self: *Owner) ?*RootAuthority {
        const services = self.selectedServices() orelse return null;
        return services.root_authority;
    }

    /// Session deletion must consult this before touching original-root storage.
    pub fn retains(self: *Owner, root_id: []const u8) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.find(root_id) != null;
    }

    /// Dismissal only hides a request. It is not an approval registry response.
    pub fn dismissApproval(self: *Owner, host: *tool_host.Runtime, target: ApprovalTarget) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const index = self.selected orelse return false;
        const entry = self.entries[index].?;
        if (entry.host != host) return false;
        if (target.child_id.len > 128 or target.request_id.len > 512) return error.InvalidApprovalTarget;
        const child_id = try entry.alloc.dupe(u8, target.child_id);
        errdefer entry.alloc.free(child_id);
        const request_id = try entry.alloc.dupe(u8, target.request_id);
        entry.clearDismissedApproval();
        entry.dismissed_approval = .{ .child_id = child_id, .request_id = request_id };
        return true;
    }

    /// Receipt integration must have the existing approval presenter consult
    /// this predicate and call showApproval when deliberately returning to it.
    pub fn approvalVisible(self: *Owner, host: *tool_host.Runtime, target: ApprovalTarget) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const index = self.selected orelse return false;
        const entry = self.entries[index].?;
        if (entry.host != host) return false;
        return if (entry.dismissed_approval) |dismissed| !dismissed.eql(target) else true;
    }

    pub fn showApproval(self: *Owner) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const index = self.selected orelse return;
        self.entries[index].?.clearDismissedApproval();
    }

    /// Reaps only detached roots after exact outcome publication and callback
    /// quiescence. Pending durable receipts do not require live credentials.
    pub fn reapDetached(self: *Owner) void {
        while (true) {
            const retired = blk: {
                self.mutex.lockUncancelable(io_mod.getIo());
                defer self.mutex.unlock(io_mod.getIo());
                if (self.closed) return;
                for (self.entries, 0..) |entry, index| {
                    const candidate = entry orelse continue;
                    if (self.selected == index or !candidate.host.managed.canRetire()) continue;
                    const readiness = candidate.services.retirement_fn orelse continue;
                    if (readiness(candidate.services.context) != .quiescent) continue;
                    self.entries[index] = null;
                    break :blk candidate;
                }
                return;
            };
            debug_trace.eventf("subagent", "child_host_retired", .{}, "root_id={s} reason=published_and_quiescent", .{retired.inputs.root_id});
            retired.destroy();
        }
    }

    /// Reclaims only a detached, settled original-root environment. The receipt
    /// owner supplies the quiescence proof; lack of that capability retains it.
    pub fn retire(self: *Owner, root_id: []const u8) !void {
        const entry = blk: {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            if (self.closed) return error.OwnerClosed;
            const index = self.find(root_id) orelse return error.HostNotRetained;
            if (self.selected == index) return error.SelectionOccupied;
            const entry = self.entries[index].?;
            if (!entry.host.managed.canRetire()) return error.HostBusy;
            const readiness = entry.services.retirement_fn orelse return error.DeliveryUnsettled;
            if (readiness(entry.services.context) != .quiescent) return error.DeliveryUnsettled;
            self.entries[index] = null;
            break :blk entry;
        };
        entry.destroy();
    }

    /// Stops admission and signals all roots without joining. The process owner
    /// calls this before joining main/tool callers; borrowed services stay live.
    pub fn requestShutdown(self: *Owner) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.closed = true;
        const entries = self.entries;
        self.mutex.unlock(io_mod.getIo());
        for (entries) |entry| if (entry) |environment| {
            debug_trace.eventf("subagent", "child_host_shutdown_requested", .{}, "root_id={s} source=process_exit", .{environment.inputs.root_id});
            environment.host.requestShutdown();
        };
    }

    /// Only process exit uses this. Public host callers must already have drained;
    /// host deinit signals and joins child workers before releasing each lease.
    /// Idempotent, with admission permanently closed even for an empty owner.
    pub fn shutdown(self: *Owner) void {
        self.requestShutdown();
        self.mutex.lockUncancelable(io_mod.getIo());
        self.closed = true;
        self.selected = null;
        const entries = self.entries;
        self.entries = @splat(null);
        self.mutex.unlock(io_mod.getIo());
        // Never join while holding the selection mutex: a worker can be
        // finishing an authority lookup or a routed permission response.
        for (entries) |entry| if (entry) |environment| environment.destroy();
    }

    fn find(self: *const Owner, root_id: []const u8) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (entry) |environment| {
                if (std.mem.eql(u8, environment.inputs.root_id, root_id)) return index;
            }
        }
        return null;
    }
};

fn validateInputBounds(inputs: Inputs) !void {
    if (inputs.catalog.skills.len > max_catalog_entries or
        inputs.catalog.diagnostics.len > max_catalog_entries or
        inputs.ignored_list_entries.len > max_catalog_entries) return error.EnvironmentTooLarge;
    var bytes: usize = 0;
    inline for (std.meta.fields(Inputs)) |field| {
        if (field.type == []const u8) try addBytes(&bytes, @field(inputs, field.name).len);
        if (field.type == ?[]const u8) {
            if (@field(inputs, field.name)) |value| try addBytes(&bytes, value.len);
        }
    }
    for (inputs.ignored_list_entries) |entry| try addBytes(&bytes, entry.len);
    for (inputs.catalog.skills) |skill| {
        try addBytes(&bytes, skill.name.len);
        try addBytes(&bytes, skill.description.len);
        try addBytes(&bytes, skill.path.len);
        if (skill.read_authority) |value| try addBytes(&bytes, value.len);
    }
    for (inputs.catalog.diagnostics) |diagnostic| try addBytes(&bytes, diagnostic.path.len);
}

fn addBytes(total: *usize, len: usize) !void {
    if (len > max_input_bytes - total.*) return error.EnvironmentTooLarge;
    total.* += len;
}

fn cloneInputs(alloc: Allocator, inputs: Inputs) !Inputs {
    var result = inputs;
    // api_key is cloned last so failure cleanup never leaves a secret in arena
    // storage that has already been freed.
    inline for (std.meta.fields(Inputs)) |field| {
        if (!comptime std.mem.eql(u8, field.name, "api_key")) {
            if (field.type == []const u8) @field(result, field.name) = try alloc.dupe(u8, @field(inputs, field.name));
            if (field.type == ?[]const u8) {
                @field(result, field.name) = if (@field(inputs, field.name)) |value| try alloc.dupe(u8, value) else null;
            }
        }
    }
    const ignored = try alloc.alloc([]const u8, inputs.ignored_list_entries.len);
    for (ignored, inputs.ignored_list_entries) |*out, value| out.* = try alloc.dupe(u8, value);
    result.ignored_list_entries = ignored;
    const skills = try alloc.dupe(skill_contract.Skill, inputs.catalog.skills);
    for (skills) |*skill| {
        skill.name = try alloc.dupe(u8, skill.name);
        skill.description = try alloc.dupe(u8, skill.description);
        skill.path = try alloc.dupe(u8, skill.path);
        if (skill.read_authority) |value| skill.read_authority = try alloc.dupe(u8, value);
    }
    const diagnostics = try alloc.dupe(skill_contract.SkillDiagnostic, inputs.catalog.diagnostics);
    for (diagnostics) |*diagnostic| diagnostic.path = try alloc.dupe(u8, diagnostic.path);
    result.catalog = .{ .skills = skills, .diagnostics = diagnostics };
    result.api_key = try alloc.dupe(u8, inputs.api_key);
    return result;
}

const io_mod = @import("../shared/io.zig");
const child_state = @import("../subagent/child_state.zig");

fn testInputs(root_id: []const u8, workspace: []const u8) Inputs {
    return .{
        .root_id = root_id,
        .workspace_root = workspace,
        .system_prompt = "original system",
        .project_context = "original project",
        .api_key = "synthetic-key",
        .gateway_chat_url = "http://127.0.0.1/test",
        .max_list_entries = 10,
        .max_read_file_bytes = 1024,
        .max_read_file_lines = 10,
        .max_read_file_line_len = 100,
        .max_command_output_bytes = 1024,
        .max_tool_result_bytes = 1024,
        .gateway_retry_count = 1,
        .agent_step_limit = 2,
    };
}

fn testWriter(store: *session_store.Store, id: []const u8) !session_store.LoadedWritableSession {
    return store.startWritableSession(std.testing.allocator, .{
        .id = @constCast(id),
        .origin_workspace_root = @constCast(store.workspace_root),
        .workspace_root = @constCast(store.workspace_root),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = @import("../session/session.zig").ConversationLanguage.literal("en"),
        .preferences = .{ .model = @constCast("test"), .effort = .auto, .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    });
}

const TestServices = struct {
    revoked: bool = false,
    releases: usize = 0,
    entered: std.Io.Event = .unset,
    finish: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    saw_original: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(bool) = .init(false),
    released_before_join: bool = false,
    retirement: Retirement = .retained,

    fn lease(self: *TestServices) Services {
        return .{ .context = self, .run_fn = run, .resolve_fn = resolve, .release_fn = release, .retirement_fn = readiness };
    }

    fn readiness(raw: *anyopaque) Retirement {
        const self: *TestServices = @ptrCast(@alignCast(raw));
        return self.retirement;
    }

    fn release(raw: *anyopaque, _: Allocator) void {
        const self: *TestServices = @ptrCast(@alignCast(raw));
        self.releases += 1;
        self.released_before_join = self.started.load(.acquire) and !self.exited.load(.acquire);
    }

    fn resolve(raw: *anyopaque, alloc: Allocator, root_id: []const u8) authority.HostResolveError!authority.HostAuthority {
        const self: *TestServices = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, root_id, "parent")) return error.HostAuthorityUnavailable;
        return authority.HostAuthority.capture(alloc, &.{"read_file"}, &.{}, .{}, if (self.revoked) &.{} else &.{.{ .tool_name = @constCast("read_file"), .target_path = @constCast("/original") }});
    }

    fn capture(_: ?*anyopaque, alloc: Allocator, request: execution.CaptureRequest) execution.ServiceError!domain.AdmissionSnapshot {
        return domain.captureAdmission(alloc, .{
            .parent_id = request.parent_id,
            .source_id = request.source_id,
            .model = request.preferences.model,
            .effort = request.preferences.effort,
        }) catch return error.AdmissionFailed;
    }

    fn run(raw: *anyopaque, inputs: *const Inputs, host: *tool_host.Runtime, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, cancel: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *TestServices = @ptrCast(@alignCast(raw));
        self.started.store(true, .release);
        self.entered.set(io_mod.getIo());
        defer self.exited.store(true, .release);
        while (!self.finish.load(.acquire) and !cancel.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
        self.saw_original.store(
            std.mem.eql(u8, inputs.root_id, "parent") and
                std.mem.eql(u8, inputs.system_prompt, "original system") and
                std.mem.eql(u8, inputs.api_key, "synthetic-key") and
                std.mem.eql(u8, host.root_id, "parent"),
            .release,
        );
        if (cancel.load(.seq_cst)) return error.ProviderFailed;
        turn.commit(message.id, .{ .assistant = .{
            .user = .{ .text = message.content },
            .assistant = @constCast("original child result"),
        } }, 0, 0, 2) catch return error.ProviderFailed;
        return .completed;
    }
};

fn checkInputsAllocation(alloc: Allocator) !void {
    var source = "original system".*;
    var key = "synthetic-key".*;
    var inputs = testInputs("parent", "/original");
    inputs.system_prompt = &source;
    inputs.api_key = &key;
    inputs.catalog = .{ .skills = &.{.{ .name = "review", .description = "review code", .path = "/skills/review", .source = .workspace_shared, .read_authority = "/skills" }} };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const copy = try cloneInputs(arena.allocator(), inputs);
    defer std.crypto.secureZero(u8, @constCast(copy.api_key));
    source[0] = 'x';
    key[0] = 'x';
    try std.testing.expectEqualStrings("original system", copy.system_prompt);
    try std.testing.expectEqualStrings("synthetic-key", copy.api_key);
    try std.testing.expect(copy.catalog.skills.ptr != inputs.catalog.skills.ptr);
    try std.testing.expect(copy.catalog.skills[0].path.ptr != inputs.catalog.skills[0].path.ptr);
    try std.testing.expectEqualStrings("/skills", copy.catalog.skills[0].read_authority.?);
}

test "retained environment owns inputs and cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInputsAllocation, .{});
    var inputs = testInputs("parent", "/original");
    try validateInputBounds(inputs);
    inputs.project_context = "x" ** (max_input_bytes + 1);
    try std.testing.expectError(error.EnvironmentTooLarge, validateInputBounds(inputs));
}

test "retained environment detaches original writer and reattaches same live host" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try session_store.Store.initFromHome(alloc, home, home);
    defer store.deinit(alloc);
    var writer: ?session_store.LoadedWritableSession = try testWriter(&store, "parent");
    defer if (writer) |*value| value.deinit(alloc);
    var services = TestServices{};
    var owner = Owner{};
    defer owner.shutdown();
    const host = try owner.create(alloc, &store, &writer.?, testInputs("parent", home), services.lease());
    try std.testing.expectError(error.HostAlreadyRetained, owner.create(alloc, &store, &writer.?, testInputs("parent", home), services.lease()));
    try std.testing.expectError(error.WrongRoot, owner.create(alloc, &store, &writer.?, testInputs("other", home), services.lease()));
    _ = try writer.?.appendEvent(alloc, .{ .history_turn_committed = .{
        .conversation_language = @import("../session/session.zig").ConversationLanguage.literal("en"),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .turn = .{ .assistant = .{ .user = .{ .text = @constCast("root request") }, .assistant = @constCast("root answer") } },
    } }, 2);
    try owner.detach(&writer);
    try std.testing.expectError(error.SessionBusy, @import("../subagent/resume_admission.zig").resumeForExternalPrompt(
        store,
        alloc,
        .{ .id = "parent" },
        home,
        .{ .log = .{ .session_lock_deadline_ms = 1 } },
    ));
    try std.testing.expect(writer == null);
    try std.testing.expect(owner.selectedHost() == null);
    try std.testing.expect(owner.retains("parent"));
    const approval = ApprovalTarget{ .child_id = "child", .request_id = "approval-a" };
    try std.testing.expect(!owner.approvalVisible(host, approval));
    try std.testing.expectError(error.HostNotRetained, owner.attach("other", &writer));
    try std.testing.expectEqual(host, try owner.attach("parent", &writer));
    try std.testing.expectEqual(host, owner.selectedHost().?);
    try std.testing.expect(try owner.dismissApproval(host, approval));
    try std.testing.expect(!owner.approvalVisible(host, approval));
    try std.testing.expect(owner.approvalVisible(host, .{ .child_id = "other-child", .request_id = "approval-a" }));
    try std.testing.expect(owner.approvalVisible(host, .{ .child_id = "child", .request_id = "approval-b" }));
    owner.showApproval();
    try std.testing.expect(owner.approvalVisible(host, approval));
    try owner.detach(&writer);
    var before = try host.host_authority.resolve_fn(host.host_authority.context, alloc, "parent");
    defer before.deinit(alloc);
    services.revoked = true;
    var after = try host.host_authority.resolve_fn(host.host_authority.context, alloc, "parent");
    defer after.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), before.grants.len);
    try std.testing.expectEqual(@as(usize, 0), after.grants.len);
    try std.testing.expect(before.generation != after.generation);
    try std.testing.expectError(error.HostAuthorityUnavailable, host.host_authority.resolve_fn(host.host_authority.context, alloc, "other"));
    try std.testing.expectError(error.DeliveryUnsettled, owner.retire("parent"));
    try std.testing.expect(owner.retains("parent"));
    services.retirement = .quiescent;
    try owner.retire("parent");
    try std.testing.expect(!owner.retains("parent"));
    owner.shutdown();
    try std.testing.expectEqual(@as(usize, 1), services.releases);
    try std.testing.expectError(error.OwnerClosed, owner.create(alloc, &store, undefined, testInputs("parent", home), services.lease()));
    owner.shutdown();
    try std.testing.expectEqual(@as(usize, 1), services.releases);
}

test "retained environment dismissal preserves approval until deliberate allow or deny" {
    const worker_runtime = @import("../agent/worker_runtime.zig");
    const permission_request = @import("../permissions/permission_request.zig");
    const Route = struct {
        decision: ?types.ToolPermissionDecision = null,
        cancellations: usize = 0,

        fn submit(raw: *anyopaque, _: u64, response: permission_request.OwnedPermissionResponse, _: ?worker_runtime.WorkerRuntime.PermissionCommit) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            var owned = response;
            defer owned.deinit();
            self.decision = owned.decision;
            return .accepted;
        }

        fn cancel(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.cancellations += 1;
        }

        fn pin(_: *anyopaque) bool {
            return true;
        }

        fn release(_: *anyopaque) void {}
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try session_store.Store.initFromHome(alloc, home, home);
    defer store.deinit(alloc);
    var writer: ?session_store.LoadedWritableSession = try testWriter(&store, "parent");
    defer if (writer) |*value| value.deinit(alloc);
    var route = Route{};
    var services = TestServices{};
    var owner = Owner{};
    defer owner.shutdown();
    const host = try owner.create(alloc, &store, &writer.?, testInputs("parent", home), services.lease());
    const target = ApprovalTarget{ .child_id = "child", .request_id = "approval-a" };
    for ([_]types.ToolPermissionDecision{ .once, .deny }) |decision| {
        route.decision = null;
        try host.approvals.registerTool(target.request_id, target.child_id, "parent", "work-a", .{ .id = 42, .label = "review action" }, &.{}, .{
            .context = &route,
            .submit_fn = Route.submit,
            .cancel_fn = Route.cancel,
            .pin_fn = Route.pin,
            .release_fn = Route.release,
        }, 1);
        try std.testing.expect(try owner.dismissApproval(host, target));
        try std.testing.expect(route.decision == null);
        try std.testing.expectEqual(@as(usize, 0), route.cancellations);
        var pending = (try host.pendingApprovalRequest(alloc)).?;
        defer pending.deinit(alloc);
        try std.testing.expectEqualStrings(target.request_id, pending.request_id);
        try owner.detach(&writer);
        try std.testing.expect(!owner.approvalVisible(host, target));
        _ = try owner.attach("parent", &writer);
        try std.testing.expect(!owner.approvalVisible(host, target));
        owner.showApproval();
        try std.testing.expect(owner.approvalVisible(host, target));
        _ = try host.resolveApproval(.{ .request_id = target.request_id, .child_id = target.child_id, .decision = decision, .timestamp_ms = 2 });
        try std.testing.expectEqual(decision, route.decision.?);
        try std.testing.expectEqual(@as(usize, 0), route.cancellations);
        try std.testing.expect((try host.pendingApprovalRequest(alloc)) == null);
    }
}

test "retained environment capacity rejects before taking service ownership" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var store = try session_store.Store.initFromHome(alloc, home, home);
    defer store.deinit(alloc);
    var services = TestServices{};
    var owner = Owner{};
    defer owner.shutdown();
    for (0..max_hosts + 1) |index| {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "root-{d}", .{index});
        var writer: ?session_store.LoadedWritableSession = try testWriter(&store, id);
        defer if (writer) |*value| value.deinit(alloc);
        if (index == max_hosts) {
            try std.testing.expectError(error.HostCapacityExceeded, owner.create(alloc, &store, &writer.?, testInputs(id, home), services.lease()));
            try std.testing.expect(writer != null);
        } else {
            _ = try owner.create(alloc, &store, &writer.?, testInputs(id, home), services.lease());
            try owner.detach(&writer);
            try std.testing.expect(writer == null);
        }
        try std.testing.expectEqual(@as(usize, 0), services.releases);
    }
    owner.shutdown();
    try std.testing.expectEqual(@as(usize, max_hosts), services.releases);
}

test "retained environment child survives detach and shutdown joins before lease release" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |exit_while_running| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(home);
        var store = try session_store.Store.initFromHome(alloc, home, home);
        defer store.deinit(alloc);
        var writer: ?session_store.LoadedWritableSession = try testWriter(&store, "parent");
        defer if (writer) |*value| value.deinit(alloc);
        {
            var child = try testWriter(&store, "child");
            defer child.deinit(alloc);
            child.log.park();
        }
        var services = TestServices{};
        var other_services = TestServices{};
        var owner = Owner{};
        defer owner.shutdown();
        defer services.finish.store(true, .release);
        var source = "original system".*;
        var inputs = testInputs("parent", home);
        inputs.system_prompt = &source;
        const host = try owner.create(alloc, &store, &writer.?, inputs, services.lease());
        // This fixture isolates lifetime from admission; real execution, worker,
        // callback routing and outcome publication still use the managed owner.
        host.managed.services.capture_fn = TestServices.capture;
        var registry = try child_state.Registry.init(alloc, "parent");
        defer registry.deinit(alloc);
        try registry.appendPersistent(alloc, "child", "reviewer", "", .{
            .id = @constCast("work-a"),
            .message = @constCast("review"),
            .created_at_ms = 1,
        });
        try host.managed.state_store.save(alloc, registry);
        const target = @import("../subagent/managed_owner.zig").WorkTarget{ .child_id = "child", .work_id = "work-a" };
        _ = try host.managed.start(target);
        try services.entered.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        try owner.detach(&writer);
        source[0] = 'x';
        var other_writer: ?session_store.LoadedWritableSession = try testWriter(&store, "other");
        defer if (other_writer) |*value| value.deinit(alloc);
        const other_host = try owner.create(alloc, &store, &other_writer.?, testInputs("other", home), other_services.lease());
        try std.testing.expectEqual(other_host, owner.selectedHost().?);
        try std.testing.expect(!owner.approvalVisible(host, .{ .child_id = "child", .request_id = "approval-a" }));
        try std.testing.expectError(error.SelectionOccupied, owner.attach("parent", &writer));
        try std.testing.expectError(error.SelectionOccupied, owner.retire("other"));
        try owner.detach(&other_writer);
        try std.testing.expectError(error.HostBusy, owner.retire("parent"));
        try std.testing.expect(host.managed.hasRunningWork());
        try std.testing.expect(!services.exited.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), services.releases);
        if (!exit_while_running) {
            try std.testing.expectEqual(host, try owner.attach("parent", &writer));
            services.finish.store(true, .release);
            const result = try host.managed.wait(target, .{ .clock = .awake, .raw = .fromSeconds(5) });
            try std.testing.expectEqual(child_state.Outcome.completed, result.outcome.?);
            try owner.detach(&writer);
        }
        owner.shutdown();
        try std.testing.expect(services.exited.load(.acquire));
        try std.testing.expect(services.saw_original.load(.acquire));
        try std.testing.expect(!services.released_before_join);
        try std.testing.expectEqual(@as(usize, 1), services.releases);
    }
}
