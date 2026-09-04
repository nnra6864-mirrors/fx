const std = @import("std");
const approval_registry = @import("approval_registry.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const io_mod = @import("../shared/io.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session_store = @import("../session/session_store.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

const Allocator = std.mem.Allocator;

pub const StartResult = enum { started, already_running };
pub const StartError = error{ OutOfMemory, OwnerClosed, ChildUnavailable, ThreadSpawnFailed };
pub const WaitError = error{ OutOfMemory, ChildUnavailable, StateUnavailable };
pub const CancelError = error{ChildUnavailable};

pub const Observation = struct {
    phase: child_state.Phase,
    outcome: ?child_state.Outcome = null,
};

const Slot = struct {
    owner: *Owner,
    child_id: []u8,
    cancel: std.atomic.Value(bool) = .init(false),
    shutdown: std.atomic.Value(bool) = .init(false),
    turn: ?*execution.TurnContext = null,
    route_refs: usize = 0,
    route_changed: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    finished: bool = false,
    done: std.Io.Event = .unset,
};

pub const Owner = struct {
    alloc: Allocator,
    sessions: *session_store.Store,
    state_store: child_state.Store,
    services: execution.Services,
    authority_resolver: *authority.Resolver,
    approvals: *approval_registry.Registry,
    max_history_turns: usize = 8,
    mutex: std.Io.Mutex = .init,
    slots: std.ArrayList(*Slot) = .empty,
    closed: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *Owner, child_id: []const u8) StartError!StartResult {
        while (true) {
            const finished = blk: {
                self.mutex.lockUncancelable(io_mod.getIo());
                defer self.mutex.unlock(io_mod.getIo());
                if (self.closed.load(.acquire)) return error.OwnerClosed;
                for (self.slots.items, 0..) |slot, index| {
                    if (!std.mem.eql(u8, slot.child_id, child_id)) continue;
                    if (!slot.finished) return .already_running;
                    break :blk self.slots.swapRemove(index);
                }
                const slot = try self.alloc.create(Slot);
                errdefer self.alloc.destroy(slot);
                slot.* = .{
                    .owner = self,
                    .child_id = try self.alloc.dupe(u8, child_id),
                };
                errdefer self.alloc.free(slot.child_id);
                try self.slots.append(self.alloc, slot);
                errdefer _ = self.slots.pop();
                slot.thread = std.Thread.spawn(.{}, slotMain, .{slot}) catch
                    return error.ThreadSpawnFailed;
                return .started;
            };
            destroySlot(self, finished);
        }
    }

    pub fn wait(
        self: *Owner,
        child_id: []const u8,
        duration: std.Io.Clock.Duration,
    ) WaitError!Observation {
        const slot = self.findSlot(child_id);
        if (slot) |active| {
            active.done.waitTimeout(io_mod.getIo(), .{ .duration = duration }) catch |err| switch (err) {
                error.Timeout => return self.observe(child_id),
                error.Canceled => return self.observe(child_id),
            };
            self.reapSlot(active);
        }
        return self.observe(child_id);
    }

    pub fn cancel(self: *Owner, child_id: []const u8) CancelError!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (!std.mem.eql(u8, slot.child_id, child_id)) continue;
            if (slot.finished) return;
            slot.cancel.store(true, .seq_cst);
            if (slot.turn) |turn| turn.workerRuntime().requestCancel();
            return;
        }
        return error.ChildUnavailable;
    }

    pub fn recoverInterrupted(self: *Owner) !void {
        var lock = try self.state_store.acquireLock(self.alloc, &self.closed);
        defer lock.release();
        var registry = try self.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const generation = registry.generation;
        registry.interruptActive(self.alloc);
        if (registry.generation != generation) try self.state_store.save(self.alloc, registry, &self.closed);
    }

    pub fn requestShutdown(self: *Owner) void {
        self.closed.store(true, .release);
        if (!self.mutex.tryLock()) return;
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (slot.finished) continue;
            slot.shutdown.store(true, .seq_cst);
            if (slot.turn) |turn| {
                turn.managedExecutionRuntime().requestShutdown();
                _ = turn.workerRuntime().tryRequestShutdown();
            }
            slot.cancel.store(true, .seq_cst);
        }
    }

    /// Polls stop delivery without waiting. Finished slots have released all
    /// worker routes and callbacks; deinit still joins their terminal threads.
    pub fn shutdownComplete(self: *Owner) bool {
        if (!self.closed.load(.acquire)) return false;
        self.requestShutdown();
        if (!self.mutex.tryLock()) return false;
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| if (!slot.finished) return false;
        return true;
    }

    pub fn deinit(self: *Owner) void {
        self.requestShutdown();
        while (!self.shutdownComplete()) io_mod.sleep(std.time.ns_per_ms);
        for (self.slots.items) |slot| destroySlot(self, slot);
        self.slots.deinit(self.alloc);
        self.* = undefined;
    }

    fn findSlot(self: *Owner, child_id: []const u8) ?*Slot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.child_id, child_id)) return slot;
        }
        return null;
    }

    fn reapSlot(self: *Owner, slot: *Slot) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        var index: ?usize = null;
        for (self.slots.items, 0..) |candidate, candidate_index| {
            if (candidate == slot and candidate.finished) {
                index = candidate_index;
                break;
            }
        }
        if (index == null) {
            self.mutex.unlock(io_mod.getIo());
            return;
        }
        _ = self.slots.swapRemove(index.?);
        self.mutex.unlock(io_mod.getIo());
        destroySlot(self, slot);
    }

    fn observe(self: *Owner, child_id: []const u8) WaitError!Observation {
        var lock = self.state_store.acquireLock(self.alloc, &self.closed) catch
            return error.StateUnavailable;
        defer lock.release();
        var registry = self.state_store.load(self.alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.StateUnavailable,
        };
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        return .{ .phase = child.phase, .outcome = child.last_outcome };
    }

    fn phaseTransition(
        raw: *anyopaque,
        child_id: []const u8,
        work_id: []const u8,
        phase: child_state.Phase,
    ) !void {
        const self: *Owner = @ptrCast(@alignCast(raw));
        var lock = try self.state_store.acquireLock(self.alloc, &self.closed);
        defer lock.release();
        var registry = try self.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        const active = child.active orelse return error.StaleWork;
        if (!std.mem.eql(u8, active.id, work_id)) return error.StaleWork;
        child.phase = phase;
        registry.generation +|= 1;
        try self.state_store.save(self.alloc, registry, &self.closed);
    }

    fn finish(
        self: *Owner,
        child_id: []const u8,
        work_id: []const u8,
        outcome: child_state.Outcome,
    ) void {
        if (self.deferFinishForShutdown(child_id)) return;
        var lock = self.state_store.acquireLock(self.alloc, &self.closed) catch |err| {
            if (err == error.Cancelled) {
                _ = self.deferFinishForShutdown(child_id);
                return;
            }
            debugFailure(child_id, "state_lock", err);
            return;
        };
        defer lock.release();
        if (self.deferFinishForShutdown(child_id)) return;
        var registry = self.state_store.load(self.alloc) catch |err| {
            debugFailure(child_id, "state_load", err);
            return;
        };
        defer registry.deinit(self.alloc);
        registry.finish(self.alloc, child_id, work_id, outcome) catch |err| {
            debugFailure(child_id, "state_finish", err);
            return;
        };
        if (self.deferFinishForShutdown(child_id)) return;
        self.state_store.save(self.alloc, registry, &self.closed) catch |err| {
            debugFailure(child_id, "state_save", err);
        };
    }

    fn deferFinishForShutdown(self: *Owner, child_id: []const u8) bool {
        if (!self.closed.load(.acquire)) return false;
        @import("../shared/debug_trace.zig").logf(
            "subagent",
            "derived child registry finish deferred child_id={s} reason=shutdown",
            .{child_id},
        );
        return true;
    }
};

fn destroySlot(owner: *Owner, slot: *Slot) void {
    if (slot.thread) |thread| thread.join();
    std.debug.assert(slot.route_refs == 0);
    owner.alloc.free(slot.child_id);
    owner.alloc.destroy(slot);
}

fn slotMain(slot: *Slot) void {
    const owner = slot.owner;
    const outcome = runOne(slot);
    owner.finish(slot.child_id, outcome.work_id, outcome.outcome);
    outcome.deinit(owner.alloc);
    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.finished = true;
    slot.done.set(io_mod.getIo());
    owner.mutex.unlock(io_mod.getIo());
}

const OneOutcome = struct {
    work_id: []u8,
    outcome: child_state.Outcome,

    fn deinit(self: OneOutcome, alloc: Allocator) void {
        alloc.free(self.work_id);
    }
};

fn runOne(slot: *Slot) OneOutcome {
    const owner = slot.owner;
    var snapshot = loadRunSnapshot(owner, slot.child_id) catch {
        return fallbackOutcome(owner.alloc, "unknown", .failed);
    };
    defer snapshot.deinit(owner.alloc);
    const work_id = owner.alloc.dupe(u8, snapshot.active.id) catch
        return fallbackOutcome(owner.alloc, "unknown", .failed);

    var loaded = owner.sessions.resumeTargetForWrite(
        owner.alloc,
        .{ .id = slot.child_id },
        owner.sessions.workspace_root,
        .{ .log = .{ .cancel_flag = &owner.closed } },
    ) catch return .{ .work_id = work_id, .outcome = .failed };
    defer {
        loaded.log.park();
        loaded.deinit(owner.alloc);
    }
    var turn = execution.TurnContext.init(
        owner.alloc,
        &loaded,
        owner.max_history_turns,
    ) catch return .{ .work_id = work_id, .outcome = .failed };
    defer turn.deinit();
    turn.live_authority = owner.authority_resolver;
    turn.approval_registry = owner.approvals;
    turn.child_id = slot.child_id;
    turn.active_work_id = snapshot.active.id;
    turn.phase_context = owner;
    turn.phase_fn = Owner.phaseTransition;
    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.turn = &turn;
    owner.mutex.unlock(io_mod.getIo());
    turn.approval_worker_route = workerRoute(slot);
    defer detachWorker(slot);

    var message = snapshot.active.queuedMessage(
        owner.alloc,
        owner.state_store.parent_id,
        snapshot.instructions,
    ) catch
        return .{ .work_id = work_id, .outcome = .failed };
    defer message.deinit(owner.alloc);
    const admission = owner.services.capture(owner.alloc, .{
        .child_id = slot.child_id,
        .parent_id = owner.state_store.parent_id,
        .source_id = owner.state_store.parent_id,
        .preferences = .{
            .provider = loaded.state.preferences.provider,
            .model = loaded.state.preferences.model,
            .effort = loaded.state.preferences.effort,
        },
    }) catch |err| return .{
        .work_id = work_id,
        .outcome = if (err == error.Cancelled) .cancelled else .failed,
    };
    var owned_admission = admission;
    defer owned_admission.deinit(owner.alloc);
    const result = owner.services.run(
        &turn,
        message,
        admission,
        &slot.cancel,
    ) catch |err| return .{
        .work_id = work_id,
        .outcome = if (slot.shutdown.load(.seq_cst))
            .interrupted
        else if (slot.cancel.load(.seq_cst) or err == error.Cancelled)
            .cancelled
        else
            .failed,
    };
    if (slot.shutdown.load(.seq_cst)) return .{
        .work_id = work_id,
        .outcome = .interrupted,
    };
    if (slot.cancel.load(.seq_cst)) return .{
        .work_id = work_id,
        .outcome = .cancelled,
    };
    return .{
        .work_id = work_id,
        .outcome = switch (result) {
            .completed => .completed,
            .awaiting_approval, .paused => .interrupted,
        },
    };
}

fn workerRoute(slot: *Slot) approval_registry.WorkerRoute {
    return .{
        .context = slot,
        .submit_fn = submitWorkerApproval,
        .cancel_fn = cancelWorkerApproval,
        .pin_fn = pinWorkerRoute,
        .release_fn = releaseWorkerRoute,
    };
}

fn submitWorkerApproval(
    raw: *anyopaque,
    request_id: u64,
    response: permission_request.OwnedPermissionResponse,
    commit: ?worker_runtime.WorkerRuntime.PermissionCommit,
) worker_runtime.WorkerRuntime.PermissionCommitError!worker_runtime.PermissionSubmissionResult {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    const turn = slot.turn orelse {
        var owned = response;
        owned.deinit();
        return .no_pending;
    };
    return turn.workerRuntime().submitPermissionResponseAfterCommit(
        request_id,
        response,
        commit,
    );
}

fn cancelWorkerApproval(raw: *anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    if (slot.turn) |turn| turn.workerRuntime().cancelApprovalTurn();
}

fn pinWorkerRoute(raw: *anyopaque) bool {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    if (slot.turn == null) return false;
    slot.route_refs += 1;
    return true;
}

fn releaseWorkerRoute(raw: *anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    std.debug.assert(slot.route_refs > 0);
    slot.route_refs -= 1;
    if (slot.route_refs == 0) slot.route_changed.broadcast(io_mod.getIo());
}

fn detachWorker(slot: *Slot) void {
    const owner = slot.owner;
    _ = owner.approvals.invalidateChild(slot.child_id) catch |err|
        debugFailure(slot.child_id, "approval_invalidate", err);
    owner.mutex.lockUncancelable(io_mod.getIo());
    while (slot.route_refs > 0) {
        slot.route_changed.waitUncancelable(io_mod.getIo(), &owner.mutex);
    }
    slot.turn = null;
    owner.mutex.unlock(io_mod.getIo());
}

const RunSnapshot = struct {
    active: child_state.ActiveWork,
    instructions: []u8,

    fn deinit(self: *RunSnapshot, alloc: Allocator) void {
        self.active.deinit(alloc);
        if (self.instructions.len > 0) alloc.free(self.instructions);
        self.* = undefined;
    }
};

fn loadRunSnapshot(owner: *Owner, child_id: []const u8) !RunSnapshot {
    var lock = try owner.state_store.acquireLock(owner.alloc, &owner.closed);
    defer lock.release();
    var registry = try owner.state_store.load(owner.alloc);
    defer registry.deinit(owner.alloc);
    const child = registry.findById(child_id) orelse return error.ChildUnavailable;
    const active = child.active orelse return error.ChildUnavailable;
    const owned_active = try active.clone(owner.alloc);
    errdefer {
        var value = owned_active;
        value.deinit(owner.alloc);
    }
    const instructions: []u8 = if (child.instructions().len == 0)
        &.{}
    else
        try owner.alloc.dupe(u8, child.instructions());
    return .{
        .active = owned_active,
        .instructions = instructions,
    };
}

fn fallbackOutcome(alloc: Allocator, work_id: []const u8, outcome: child_state.Outcome) OneOutcome {
    return .{
        .work_id = alloc.dupe(u8, work_id) catch &.{},
        .outcome = outcome,
    };
}

fn debugFailure(child_id: []const u8, stage: []const u8, err: anyerror) void {
    @import("../shared/debug_trace.zig").logf(
        "subagent",
        "managed child state update failed child_id={s} stage={s} err={s}",
        .{ child_id, stage, @errorName(err) },
    );
}

const TestSessions = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,
    store: session_store.Store,

    fn init(alloc: Allocator) !TestSessions {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "home/.fx");
        try tmp.dir.createDirPath(std.testing.io, "workspace");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
        errdefer alloc.free(workspace);
        var store = try session_store.Store.initFromHome(alloc, home, workspace);
        errdefer store.deinit(alloc);
        var parent = try store.startWritableSession(alloc, .{
            .id = @constCast("parent"),
            .origin_workspace_root = workspace,
            .workspace_root = workspace,
            .created_at_ms = 1,
            .updated_at_ms = 1,
            .conversation_language = .literal("en"),
            .preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false },
            .history = &.{},
            .total_input_tokens = 0,
            .total_output_tokens = 0,
        });
        parent.deinit(alloc);
        return .{ .tmp = tmp, .home = home, .workspace = workspace, .store = store };
    }

    fn deinit(self: *TestSessions, alloc: Allocator) void {
        self.store.deinit(alloc);
        alloc.free(self.workspace);
        alloc.free(self.home);
        self.tmp.cleanup();
    }
};

const PersistenceAllocationGate = struct {
    backing: Allocator,
    reached: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    signalled: bool = false,

    fn allocator(self: *@This()) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
    }
    fn allocate(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const bytes = self.backing.rawAlloc(len, alignment, address);
        if (bytes != null and len >= 128 * 1024 and !self.signalled) {
            self.signalled = true;
            self.reached.set(io_mod.getIo());
            self.release.waitUncancelable(io_mod.getIo());
        }
        return bytes;
    }
    fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.backing.rawFree(bytes, alignment, address);
    }
};

test "child persistence stops after a history copy begins without damaging its boundary" {
    try testChildPersistenceShutdown(.history, true);
}

test "child persistence stops after checkpoint encoding begins without damaging its boundary" {
    try testChildPersistenceShutdown(.checkpoint, true);
}

test "ordinary child cancellation still persists history and recovery checkpoints" {
    try testChildPersistenceShutdown(.history, false);
    try testChildPersistenceShutdown(.checkpoint, false);
}

fn testChildPersistenceShutdown(comptime operation: enum { history, checkpoint }, authoritative: bool) !void {
    const session = @import("../session/session.zig");
    const codec = @import("../session/session_codec.zig");
    const alloc = std.testing.allocator;
    var fixture = try TestSessions.init(alloc);
    defer fixture.deinit(alloc);
    var loaded = try fixture.store.startWritableSession(alloc, .{
        .id = @constCast("canonical-child"),
        .origin_workspace_root = fixture.workspace,
        .workspace_root = fixture.workspace,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .subagent_child = true,
    });
    defer loaded.deinit(alloc);
    const prior = loaded.position;
    const before = try loaded.log.dir.dir.statFile(io_mod.getIo(), "events.jsonl", .{});
    var turn = try execution.TurnContext.init(alloc, &loaded, 8);
    defer turn.deinit();
    var gate: PersistenceAllocationGate = .{ .backing = alloc };
    turn.alloc = gate.allocator();
    defer turn.alloc = alloc;
    const large = "x" ** (128 * 1024);
    const Worker = struct {
        turn: *execution.TurnContext,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            if (operation == .history) {
                self.turn.commit("work", session.HistoryTurn{ .assistant = .{
                    .user = .{ .text = @constCast(large) },
                    .assistant = @constCast("answer"),
                } }, 0, 0, 2) catch |err| self.record(err);
            } else {
                self.turn.setRecoveryCheckpoint(codec.RecoveryCheckpoint{
                    .turn_id = 1,
                    .user = .{ .text = @constCast(large) },
                    .assistant_source = @constCast("partial"),
                    .cause = .response_interrupted,
                    .action = .continuing_response,
                    .authority = .{ .provider = .gateway, .model = @constCast("saved/model") },
                    .requested_fast_mode = false,
                    .fast_mode = false,
                    .max_provider_attempts = 10,
                    .consumed_provider_attempts = 2,
                }, 2) catch |err| self.record(err);
            }
        }
        fn record(self: *@This(), err: anyerror) void {
            self.failure = err;
        }
    };
    var worker: Worker = .{ .turn = &turn };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    gate.reached.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } }) catch |err| {
        gate.release.set(io_mod.getIo());
        thread.join();
        return err;
    };
    const started = io_mod.milliTimestamp();
    if (authoritative) turn.managed_executions.requestShutdown() else turn.workerRuntime().requestCancel();
    gate.release.set(io_mod.getIo());
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, if (authoritative) error.Cancelled else null), worker.failure);
    const after = try loaded.log.dir.dir.statFile(io_mod.getIo(), "events.jsonl", .{});
    if (authoritative) {
        try std.testing.expect(io_mod.milliTimestamp() - started < 500);
        try std.testing.expectEqual(prior, loaded.position);
        try std.testing.expectEqual(before.size, after.size);
        try std.testing.expectEqual(before.mtime, after.mtime);
    } else {
        try std.testing.expect(turn.workerRuntime().isCancelRequested());
        try std.testing.expect(!turn.managed_executions.shutting_down.load(.acquire));
        try std.testing.expect(after.size > before.size);
    }
    try loaded.confirmResumeHandoffBoundary(alloc, .{});
}

test "child admission shutdown abandons publication after index parsing begins" {
    try testChildMetadataShutdown(.admission);
}

test "child marker shutdown abandons publication after index parsing begins" {
    try testChildMetadataShutdown(.marker);
}

fn testChildMetadataShutdown(comptime operation: enum { admission, marker }) !void {
    const tool_host = @import("tool_host.zig");
    const summary_codec = @import("../session/session_summary_codec.zig");
    const publication = @import("../session/session_index_publication.zig");
    const alloc = std.testing.allocator;
    var fixture = try TestSessions.init(alloc);
    defer fixture.deinit(alloc);
    var parent = try fixture.store.resumeTargetForWrite(alloc, .{ .id = "parent" }, fixture.workspace, .{});
    defer parent.deinit(alloc);
    if (operation == .marker) {
        var state = parent.state;
        state.id = @constCast("marked-child");
        state.subagent_child = true;
        var child = try fixture.store.startWritableSession(alloc, state);
        child.deinit(alloc);
    }
    const prior = parent.position;
    const canonical_before = try parent.log.dir.dir.statFile(io_mod.getIo(), "events.jsonl", .{});
    const sessions = &fixture.store.canonical_root.sessions.?;
    var summaries = try summary_codec.readSessionIndex(alloc, sessions);
    defer summary_codec.freeSummaries(alloc, &summaries);
    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    if (summaries.items[0].title) |title| alloc.free(title);
    summaries.items[0].title = try alloc.dupe(u8, "x" ** (256 * 1024));
    try summary_codec.writeSessionIndex(alloc, sessions, summaries.items);
    const index_before = try sessions.dir.statFile(io_mod.getIo(), "index.json", .{});
    const Host = struct {
        fn resolve(_: ?*anyopaque, _: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
            return error.HostAuthorityUnavailable;
        }
    };
    const host = try tool_host.Runtime.createBound(alloc, &fixture.store, "parent", .{ .resolve_fn = Host.resolve }, .{});
    defer host.deinit();
    var gate: PersistenceAllocationGate = .{ .backing = alloc };
    const Worker = struct {
        host: *tool_host.Runtime,
        alloc: Allocator,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            if (operation == .marker) {
                self.host.managed.state_store.markChildSession(self.alloc, "marked-child", &self.host.managed.closed) catch |err| {
                    self.failure = err;
                };
            } else {
                var request: @import("model_contract.zig").Request = .{ .run = .{ .task = @constCast("work") } };
                const result = self.host.executeManaged(self.alloc, &request, .{
                    .caller_id = "parent",
                    .invocation_id = "work",
                    .defaults = .{ .provider = .gateway, .model = "test/model", .effort = .auto, .conversation_language = .literal("en") },
                    .max_result_bytes = 1024,
                    .timestamp_ms = 2,
                }) catch |err| {
                    self.failure = err;
                    return;
                };
                self.alloc.free(result.body);
            }
        }
    };
    var worker: Worker = .{ .host = host, .alloc = gate.allocator() };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    gate.reached.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } }) catch |err| {
        gate.release.set(io_mod.getIo());
        thread.join();
        return err;
    };
    const started = io_mod.milliTimestamp();
    host.requestShutdown();
    gate.release.set(io_mod.getIo());
    thread.join();
    try std.testing.expect(io_mod.milliTimestamp() - started < 500);
    const index_after = try sessions.dir.statFile(io_mod.getIo(), "index.json", .{});
    try std.testing.expectEqual(index_before.inode, index_after.inode);
    try std.testing.expectEqual(index_before.size, index_after.size);
    try std.testing.expectEqual(index_before.mtime, index_after.mtime);
    try std.testing.expect(try publication.pending(sessions));
    try std.testing.expectEqual(@as(?anyerror, if (operation == .marker) null else error.Cancelled), worker.failure);
    if (operation == .admission) {
        var registry = try host.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), registry.children.len);
        try std.testing.expectError(error.FileNotFound, sessions.dir.statFile(io_mod.getIo(), registry.children[0].id, .{}));
    }
    try std.testing.expect(fixture.store.resume_cancel_flag == null);
    try std.testing.expectEqual(prior, parent.position);
    const canonical_after = try parent.log.dir.dir.statFile(io_mod.getIo(), "events.jsonl", .{});
    try std.testing.expectEqual(canonical_before.size, canonical_after.size);
    try std.testing.expectEqual(canonical_before.mtime, canonical_after.mtime);
    try parent.confirmResumeHandoffBoundary(alloc, .{});
}

test "shutdown cancels an in-progress derived registry lock wait" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var fixture = try TestSessions.init(alloc);
    defer fixture.deinit(alloc);
    const state_store = child_state.Store{ .sessions = &fixture.store, .parent_id = "parent" };
    var registry = try child_state.Registry.init(alloc, "parent");
    defer registry.deinit(alloc);
    try registry.appendOneOff(alloc, "child", .{ .id = @constCast("work"), .message = @constCast("message"), .created_at_ms = 1 });
    try state_store.save(alloc, registry, null);
    var capability = try fixture.store.openSubagentControlCapabilityReadOnly(alloc, "parent", .{});
    defer capability.deinit();
    const before = snapshot: {
        var file = try capability.openFileReadOnly(alloc, .subagent_control, "children.json");
        defer file.deinit();
        break :snapshot .{ .stat = try file.stat(), .bytes = try file.readToEnd(alloc, 512 * 1024) };
    };
    defer alloc.free(before.bytes);
    var held = try state_store.acquireLock(alloc, null);
    defer held.release();

    var owner = Owner{
        .alloc = alloc,
        .sessions = &fixture.store,
        .state_store = state_store,
        .services = undefined,
        .authority_resolver = undefined,
        .approvals = undefined,
    };
    const slot = try alloc.create(Slot);
    slot.* = .{ .owner = &owner, .child_id = try alloc.dupe(u8, "child") };
    try owner.slots.append(alloc, slot);
    const Context = struct {
        slot: *Slot,
        contended: std.Io.Event = .unset,
        failed: std.atomic.Value(bool) = .init(false),
        pid: std.posix.pid_t = 0,

        fn tryLock(raw: ?*anyopaque, file: std.Io.File) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const locked = try file.tryLock(io_mod.getIo(), .exclusive);
            if (!locked) self.contended.set(io_mod.getIo());
            return locked;
        }

        fn run(self: *@This()) void {
            if (std.process.spawn(io_mod.getIo(), .{ .argv = &.{"/usr/bin/true"} })) |value| {
                var child = value;
                defer child.kill(io_mod.getIo());
                self.pid = child.id.?;
                _ = child.wait(io_mod.getIo()) catch self.failed.store(true, .release);
            } else |_| self.failed.store(true, .release);
            self.slot.owner.finish("child", "work", .completed);
            self.slot.owner.mutex.lockUncancelable(io_mod.getIo());
            self.slot.finished = true;
            self.slot.done.set(io_mod.getIo());
            self.slot.owner.mutex.unlock(io_mod.getIo());
        }
    };
    var context = Context{ .slot = slot };
    owner.state_store.options.lock_ops = .{ .ctx = &context, .try_lock = Context.tryLock };
    slot.thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    context.contended.waitUncancelable(io_mod.getIo());
    const started = io_mod.milliTimestamp();
    owner.deinit();
    const elapsed_ms = io_mod.milliTimestamp() - started;
    try std.testing.expect(!context.failed.load(.acquire));
    try std.testing.expect(elapsed_ms < 500);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(context.pid, @enumFromInt(0)));
    var unchanged = try state_store.load(alloc);
    defer unchanged.deinit(alloc);
    try std.testing.expectEqual(registry.generation, unchanged.generation);
    try std.testing.expectEqual(child_state.Phase.running, unchanged.children[0].phase);
    try std.testing.expectEqualStrings("work", unchanged.children[0].active.?.id);
    var after_file = try capability.openFileReadOnly(alloc, .subagent_control, "children.json");
    defer after_file.deinit();
    const after = try after_file.readToEnd(alloc, 512 * 1024);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before.bytes, after);
    try std.testing.expectEqual(before.stat, try after_file.stat());
}

test "shutdown completion waits for the slot's final owned cleanup" {
    const alloc = std.testing.allocator;
    var fixture = try TestSessions.init(alloc);
    defer fixture.deinit(alloc);
    const FreeGate = struct {
        child: Allocator,
        tracked: ?[*]u8 = null,
        reached: std.Io.Event = .unset,
        release: std.Io.Event = .unset,

        fn allocate(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const result = self.child.rawAlloc(len, alignment, address);
            if (len == "unknown".len) self.tracked = result;
            return result;
        }
        fn resize(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.child.rawResize(bytes, alignment, len, address);
        }
        fn remap(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.child.rawRemap(bytes, alignment, len, address);
        }
        fn free(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.tracked != null and bytes.ptr == self.tracked.?) {
                self.reached.set(io_mod.getIo());
                self.release.waitUncancelable(io_mod.getIo());
            }
            self.child.rawFree(bytes, alignment, address);
        }
    };
    var gate = FreeGate{ .child = alloc };
    const observed: Allocator = .{ .ptr = &gate, .vtable = &.{ .alloc = FreeGate.allocate, .resize = FreeGate.resize, .remap = FreeGate.remap, .free = FreeGate.free } };
    var owner = Owner{
        .alloc = observed,
        .sessions = &fixture.store,
        .state_store = .{ .sessions = &fixture.store, .parent_id = "parent" },
        .services = undefined,
        .authority_resolver = undefined,
        .approvals = undefined,
    };
    _ = try owner.start("missing-child");
    gate.reached.waitTimeout(io_mod.getIo(), .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch {
        gate.release.set(io_mod.getIo());
        owner.deinit();
        return error.CleanupNotObserved;
    };
    owner.requestShutdown();
    const completed_during_cleanup = owner.shutdownComplete();
    gate.release.set(io_mod.getIo());
    owner.deinit();
    try std.testing.expect(!completed_during_cleanup);
}

test "worker detach invalidates approval routes before worker deinit" {
    const alloc = std.testing.allocator;
    var approvals = approval_registry.Registry{ .alloc = alloc };
    defer approvals.deinit();
    var owner = Owner{
        .alloc = alloc,
        .sessions = undefined,
        .state_store = undefined,
        .services = undefined,
        .authority_resolver = undefined,
        .approvals = &approvals,
    };
    var turn = execution.TurnContext{
        .alloc = alloc,
        .runtime = .{ .max_history_turns = 8 },
        .managed_executions = .init(alloc),
        .loaded = undefined,
    };
    defer turn.deinit();
    const worker = turn.workerRuntime();
    worker.worker_processing = true;
    worker.pending_permission_waiting = true;
    worker.pending_permission_request_shared =
        try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            .{ .id = 9, .label = "review" },
        );
    var slot = Slot{
        .owner = &owner,
        .child_id = try alloc.dupe(u8, "child"),
        .turn = &turn,
    };
    defer alloc.free(slot.child_id);
    const route = workerRoute(&slot);
    try approvals.registerTool(
        "approval",
        "child",
        "root",
        "work",
        .{ .id = 9, .label = "review" },
        &.{},
        route,
        1,
    );

    detachWorker(&slot);
    try std.testing.expect(slot.turn == null);
    var pending = try approvals.firstPendingRequest(alloc, "root");
    defer if (pending) |*request| request.deinit(alloc);
    try std.testing.expect(pending == null);
    try std.testing.expectEqual(
        worker_runtime.PermissionSubmissionResult.no_pending,
        try route.submit_fn(
            route.context,
            9,
            permission_request.OwnedPermissionResponse.init(alloc, .deny, null),
            null,
        ),
    );
}

test "shutdown request returns while an active child callback is still unwinding" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var owner = Owner{
        .alloc = alloc,
        .sessions = undefined,
        .state_store = undefined,
        .services = undefined,
        .authority_resolver = undefined,
        .approvals = undefined,
    };
    const slot = try alloc.create(Slot);
    slot.* = .{ .owner = &owner, .child_id = try alloc.dupe(u8, "active-child") };
    try owner.slots.append(alloc, slot);
    const Context = struct {
        slot: *Slot,
        started: std.Io.Event = .unset,
        cancelled: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        failed: std.atomic.Value(bool) = .init(false),
        returned: std.atomic.Value(bool) = .init(false),
        pid: std.posix.pid_t = 0,

        fn run(self: *@This()) void {
            defer {
                self.slot.owner.mutex.lockUncancelable(io_mod.getIo());
                self.slot.finished = true;
                self.slot.done.set(io_mod.getIo());
                self.slot.owner.mutex.unlock(io_mod.getIo());
            }
            var child = std.process.spawn(io_mod.getIo(), .{ .argv = &.{ "/bin/sleep", "30" } }) catch {
                self.failed.store(true, .release);
                self.started.set(io_mod.getIo());
                self.cancelled.set(io_mod.getIo());
                return;
            };
            self.pid = child.id.?;
            self.started.set(io_mod.getIo());
            const deadline = io_mod.milliTimestamp() + 2_000;
            while (!self.slot.cancel.load(.acquire) and io_mod.milliTimestamp() < deadline) io_mod.sleep(std.time.ns_per_ms);
            if (!self.slot.cancel.load(.acquire)) self.failed.store(true, .release);
            self.cancelled.set(io_mod.getIo());
            self.release.waitUncancelable(io_mod.getIo());
            child.kill(io_mod.getIo());
        }

        fn stop(self: *@This()) void {
            self.slot.owner.requestShutdown();
            self.returned.store(true, .release);
        }
    };
    var context = Context{ .slot = slot };
    slot.thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    context.started.waitUncancelable(io_mod.getIo());
    const stop = try std.Thread.spawn(.{}, Context.stop, .{&context});
    context.cancelled.waitUncancelable(io_mod.getIo());
    const deadline = io_mod.milliTimestamp() + 100;
    while (!context.returned.load(.acquire) and io_mod.milliTimestamp() < deadline) io_mod.sleep(std.time.ns_per_ms);
    const returned_while_callback_active = context.returned.load(.acquire);
    const quiescent_while_callback_active = owner.shutdownComplete();
    context.release.set(io_mod.getIo());
    stop.join();
    const finish_deadline = io_mod.milliTimestamp() + 2_000;
    while (!owner.shutdownComplete() and io_mod.milliTimestamp() < finish_deadline) io_mod.sleep(std.time.ns_per_ms);
    const quiescent = owner.shutdownComplete();
    owner.deinit();
    try std.testing.expect(!context.failed.load(.acquire));
    try std.testing.expect(returned_while_callback_active);
    try std.testing.expect(!quiescent_while_callback_active);
    try std.testing.expect(quiescent);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(context.pid, @enumFromInt(0)));
}

test "host shutdown force-stops a child command already handling TERM" {
    if (@import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return;
    const alloc = std.testing.allocator;
    var fixture = try TestSessions.init(alloc);
    defer fixture.deinit(alloc);
    var loaded = try fixture.store.startWritableSession(alloc, .{
        .id = @constCast("child"),
        .origin_workspace_root = fixture.workspace,
        .workspace_root = fixture.workspace,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .subagent_child = true,
    });
    defer loaded.deinit(alloc);
    var approvals = approval_registry.Registry{ .alloc = alloc };
    defer approvals.deinit();
    const command = try std.fmt.allocPrint(alloc, "python3 -u -c 'import os,signal,time\n" ++
        "def stop(*_):\n open(\"{s}/term\",\"w\").write(\"TERM\")\n time.sleep(30)\n" ++
        "signal.signal(signal.SIGTERM,stop)\n" ++
        "child=os.fork()\n" ++
        "open(\"{s}/\"+(\"child.pid\" if child==0 else \"parent.pid\"),\"w\").write(str(os.getpid()))\n" ++
        "while True: time.sleep(1)'", .{ fixture.workspace, fixture.workspace });
    defer alloc.free(command);
    var owner = Owner{
        .alloc = alloc,
        .sessions = &fixture.store,
        .state_store = .{ .sessions = &fixture.store, .parent_id = "parent" },
        .services = undefined,
        .authority_resolver = undefined,
        .approvals = &approvals,
    };
    defer owner.deinit();
    const slot = try alloc.create(Slot);
    slot.* = .{ .owner = &owner, .child_id = try alloc.dupe(u8, "child") };
    try owner.slots.append(alloc, slot);
    const Context = struct {
        slot: *Slot,
        loaded: *session_store.LoadedWritableSession,
        command: []const u8,
        workspace: []const u8,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            defer {
                self.slot.owner.mutex.lockUncancelable(io_mod.getIo());
                self.slot.finished = true;
                self.slot.done.set(io_mod.getIo());
                self.slot.owner.mutex.unlock(io_mod.getIo());
            }
            var turn = execution.TurnContext.init(std.testing.allocator, self.loaded, 8) catch {
                self.failed.store(true, .release);
                return;
            };
            defer turn.deinit();
            self.slot.owner.mutex.lockUncancelable(io_mod.getIo());
            self.slot.turn = &turn;
            self.slot.owner.mutex.unlock(io_mod.getIo());
            defer detachWorker(self.slot);
            const managed = @import("../execution/managed_execution.zig");
            var input = managed.StartCapturedInput{
                .execution_id = "child-command",
                .command = self.command,
                .cwd = self.workspace,
                .environment = .{ .clean = "/bin/bash" },
                .authority = undefined,
                .max_output_bytes = 4096,
                .timeout_ms = null,
                .command_artifact_dir = null,
                .cancel_flag = &self.slot.cancel,
            };
            input.authority = .{ .shell_allowed = .{ .fingerprint = .init(.{
                .command = input.command,
                .resolved_cwd = input.cwd,
                .target_os = @import("builtin").os.tag,
                .environment = input.environment,
            }), .source = .yolo } };
            var result = turn.managedExecutionRuntime().startCaptured(std.testing.allocator, input) catch {
                self.failed.store(true, .release);
                return;
            };
            if (result.snapshot.error_name != null or !self.slot.cancel.load(.acquire)) self.failed.store(true, .release);
            result.deinit(std.testing.allocator);
        }

        fn waitFile(directory: []const u8, name: []const u8) !void {
            const path = try std.fs.path.join(std.testing.allocator, &.{ directory, name });
            defer std.testing.allocator.free(path);
            const deadline = io_mod.milliTimestamp() + 5_000;
            while (io_mod.milliTimestamp() < deadline) {
                if (std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{})) |file| {
                    defer file.close(io_mod.getIo());
                    if (try file.length(io_mod.getIo()) != 0) return;
                } else |err| if (err != error.FileNotFound) return err;
                io_mod.sleep(std.time.ns_per_ms);
            }
            return error.CommandNotObserved;
        }
    };
    var context = Context{ .slot = slot, .loaded = &loaded, .command = command, .workspace = fixture.workspace };
    slot.thread = std.Thread.spawn(.{}, Context.run, .{&context}) catch |err| {
        slot.finished = true;
        return err;
    };
    try Context.waitFile(fixture.workspace, "parent.pid");
    try Context.waitFile(fixture.workspace, "child.pid");
    slot.cancel.store(true, .release);
    try Context.waitFile(fixture.workspace, "term");
    const started = io_mod.milliTimestamp();
    owner.requestShutdown();
    while (!owner.shutdownComplete() and io_mod.milliTimestamp() - started < 5_000) io_mod.sleep(std.time.ns_per_ms);
    const elapsed_ms = io_mod.milliTimestamp() - started;
    try std.testing.expect(!context.failed.load(.acquire));
    try std.testing.expect(owner.shutdownComplete());
    try std.testing.expect(elapsed_ms < 500);
    for ([_][]const u8{ "parent.pid", "child.pid" }) |name| {
        const path = try std.fs.path.join(alloc, &.{ fixture.workspace, name });
        defer alloc.free(path);
        var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
        defer file.close(io_mod.getIo());
        const bytes = try io_mod.readFileToEnd(alloc, &file, 32);
        defer alloc.free(bytes);
        const pid = try std.fmt.parseInt(std.posix.pid_t, bytes, 10);
        try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
    }
}
