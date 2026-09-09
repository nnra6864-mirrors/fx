const std = @import("std");
const approval_registry = @import("approval_registry.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const permission_request = @import("../permissions/permission_request.zig");
const session_store = @import("../session/session_store.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Borrowed for one call. Slots own immutable copies of both identifiers.
pub const WorkTarget = struct {
    child_id: []const u8,
    work_id: []const u8,
};

pub const StartResult = enum { started, already_running, already_finished };
pub const StartError = WaitError || error{ OwnerClosed, ThreadSpawnFailed };
pub const WaitError = error{ OutOfMemory, ChildUnavailable, StaleWork, StateUnavailable };
pub const CancelError = WaitError;
pub const CancelResult = enum { cancellation_requested, already_finished };

pub const Observation = struct {
    phase: child_state.Phase,
    outcome: ?child_state.Outcome = null,
    failure: ?types.ModelFailureDiagnostic = null,
};

const Slot = struct {
    owner: *Owner,
    child_id: []const u8,
    work_id: []const u8,
    wait_refs: usize = 0,
    wait_changed: std.Io.Condition = .init,
    cancel: std.atomic.Value(bool) = .init(false),
    shutdown: std.atomic.Value(bool) = .init(false),
    worker: ?*worker_runtime.WorkerRuntime = null,
    route_refs: usize = 0,
    route_changed: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    completion: enum { running, published, unpublished } = .running,
    done: std.Io.Event = .unset,
};

pub const OutcomePublisher = struct {
    context: *anyopaque,
    publish_fn: *const fn (*anyopaque, WorkTarget, child_state.Outcome, ?types.ModelFailureDiagnostic) error{ OutOfMemory, DeliveryUnavailable }!void,
};

pub const Owner = struct {
    alloc: Allocator,
    sessions: *session_store.Store,
    state_store: child_state.Store,
    services: execution.Services,
    authority_resolver: *authority.Resolver,
    approvals: *approval_registry.Registry,
    max_history_turns: usize = 8,
    outcome_publisher: ?OutcomePublisher = null,
    mutex: std.Io.Mutex = .init,
    slots: std.ArrayList(*Slot) = .empty,
    slots_changed: std.Io.Condition = .init,
    closed: bool = false,

    pub fn hasRunningWork(self: *Owner) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (slot.completion == .running) return true;
        }
        return false;
    }

    pub fn canRetire(self: *Owner) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (slot.completion != .published or slot.wait_refs != 0 or slot.route_refs != 0) return false;
        }
        return true;
    }

    /// Rejects new host admission after shutdown. In-flight admission must still
    /// pass start's publication check under the same mutex as requestShutdown.
    pub fn checkAdmission(self: *Owner) error{OwnerClosed}!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.OwnerClosed;
    }

    /// Validates admission under the state lock before publishing the owned slot.
    /// Lock order is state store, then owner; no owner lock spans a join.
    pub fn start(self: *Owner, target: WorkTarget) StartError!StartResult {
        while (true) {
            try self.checkAdmission();
            const previous = blk: {
                var lock = self.state_store.acquireLock(self.alloc) catch return error.StateUnavailable;
                defer lock.release();
                var registry = try self.loadRegistry();
                defer registry.deinit(self.alloc);
                const observation = try observeWork(&registry, target);

                self.mutex.lockUncancelable(io_mod.getIo());
                defer self.mutex.unlock(io_mod.getIo());
                if (self.closed) return error.OwnerClosed;
                for (self.slots.items) |slot| {
                    if (!std.mem.eql(u8, slot.child_id, target.child_id)) continue;
                    if (std.mem.eql(u8, slot.work_id, target.work_id)) {
                        return switch (slot.completion) {
                            .running => .already_running,
                            .published => .already_finished,
                            .unpublished => error.StateUnavailable,
                        };
                    }
                    // A can have published just before its completion flag. Pin
                    // and drain that slot before starting B in the same child.
                    slot.wait_refs += 1;
                    break :blk slot;
                }
                if (observation.outcome != null) return .already_finished;
                const slot = try createSlot(self, target);
                errdefer freeSlot(self.alloc, slot);
                try self.slots.append(self.alloc, slot);
                errdefer _ = self.slots.pop();
                debug_trace.eventf("subagent", "child_slot_published", .{}, "root_id={s} child_id={s} work_id={s}", .{ self.state_store.parent_id, target.child_id, target.work_id });
                slot.thread = std.Thread.spawn(.{}, slotMain, .{slot}) catch |err| {
                    debug_trace.eventf("subagent", "child_spawn_failed", .{}, "root_id={s} child_id={s} work_id={s} error={s}", .{ self.state_store.parent_id, target.child_id, target.work_id, @errorName(err) });
                    return error.ThreadSpawnFailed;
                };
                return .started;
            };
            self.mutex.lockUncancelable(io_mod.getIo());
            while (!self.closed and previous.completion == .running) {
                self.slots_changed.waitUncancelable(io_mod.getIo(), &self.mutex);
            }
            self.mutex.unlock(io_mod.getIo());
            self.releaseWaitSlot(previous);
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            if (self.closed) return error.OwnerClosed;
            for (self.slots.items) |slot| {
                if (!std.mem.eql(u8, slot.child_id, target.child_id) or
                    std.mem.eql(u8, slot.work_id, target.work_id) or
                    slot.completion == .running) continue;
                self.slots_changed.waitUncancelable(io_mod.getIo(), &self.mutex);
                break;
            }
        }
    }

    /// Waits only for target; replacement returns StaleWork, never later state.
    pub fn wait(
        self: *Owner,
        target: WorkTarget,
        duration: std.Io.Clock.Duration,
    ) WaitError!Observation {
        const slot = try self.pinWaitSlot(target);
        defer if (slot) |active| self.releaseWaitSlot(active);
        if (slot) |active| {
            active.done.waitTimeout(io_mod.getIo(), .{ .duration = duration }) catch |err| switch (err) {
                error.Timeout, error.Canceled => return self.observe(target),
            };
            self.mutex.lockUncancelable(io_mod.getIo());
            const unpublished = active.completion == .unpublished;
            self.mutex.unlock(io_mod.getIo());
            if (unpublished) return error.StateUnavailable;
        }
        return self.observe(target);
    }

    /// Signals only this owner's exact work, without waiting for settlement.
    /// The host must validate caller ownership and permissions before calling.
    pub fn cancelWork(self: *Owner, target: WorkTarget) CancelError!CancelResult {
        const pinned: ?struct { slot: *Slot, worker: ?*worker_runtime.WorkerRuntime } = blk: {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            for (self.slots.items) |slot| {
                if (!std.mem.eql(u8, slot.child_id, target.child_id)) continue;
                if (!std.mem.eql(u8, slot.work_id, target.work_id)) {
                    debug_trace.eventf("subagent", "child_cancel_rejected", .{}, "root_id={s} child_id={s} work_id={s} reason=stale_work", .{ self.state_store.parent_id, target.child_id, target.work_id });
                    return error.StaleWork;
                }
                switch (slot.completion) {
                    .published => return .already_finished,
                    .unpublished => return error.StateUnavailable,
                    .running => {},
                }
                slot.cancel.store(true, .seq_cst);
                slot.wait_refs += 1;
                const worker = slot.worker;
                if (worker != null) slot.route_refs += 1;
                break :blk .{ .slot = slot, .worker = worker };
            }
            break :blk null;
        };
        if (pinned) |entry| {
            defer self.releaseWaitSlot(entry.slot);
            debug_trace.eventf("subagent", "child_cancel_requested", .{}, "root_id={s} child_id={s} work_id={s}", .{ self.state_store.parent_id, target.child_id, target.work_id });
            // A permission observer can enter the owner while holding the worker
            // lock. Pins preserve both lifetimes without reversing that order.
            if (entry.worker) |worker| {
                defer releaseWorkerRoute(entry.slot);
                worker.requestCancel();
            }
            return .cancellation_requested;
        }
        const observation = try self.observe(target);
        if (observation.outcome != null) return .already_finished;
        return error.ChildUnavailable;
    }

    pub fn recoverInterrupted(self: *Owner) !void {
        var observed = try self.state_store.load(self.alloc);
        defer observed.deinit(self.alloc);
        if (observed.children.len == 0) return;

        var lock = try self.state_store.acquireLock(self.alloc);
        defer lock.release();
        var registry = try self.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const generation = registry.generation;
        registry.interruptActive(self.alloc);
        if (registry.generation != generation) try self.state_store.save(self.alloc, registry);
    }

    /// Idempotently closes admission and signals every slot without joining or
    /// draining callbacks. Call before joining public callers; keep the owner
    /// and its borrowed services alive until deinit returns.
    pub fn requestShutdown(self: *Owner) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.closed = true;
        for (self.slots.items) |slot| {
            slot.shutdown.store(true, .seq_cst);
            slot.cancel.store(true, .seq_cst);
            slot.wait_refs += 1;
        }
        self.slots_changed.broadcast(io_mod.getIo());
        self.mutex.unlock(io_mod.getIo());

        // Closing freezes membership. Pin workers separately: permission
        // observers can hold the worker lock while entering the approval
        // registry, whose routes in turn acquire the owner lock.
        for (self.slots.items) |slot| {
            self.mutex.lockUncancelable(io_mod.getIo());
            const worker = slot.worker;
            if (worker != null) slot.route_refs += 1;
            self.mutex.unlock(io_mod.getIo());
            if (worker) |active| {
                active.requestShutdown();
                releaseWorkerRoute(slot);
            }
            self.releaseWaitSlot(slot);
        }
    }

    /// Public callers must be joined before destruction. Approval routes and
    /// slot pins drain before reclamation, with no owner lock held across joins.
    pub fn deinit(self: *Owner) void {
        self.requestShutdown();
        for (self.slots.items) |slot| {
            if (slot.thread) |thread| thread.join();
            self.mutex.lockUncancelable(io_mod.getIo());
            while (slot.wait_refs > 0) {
                slot.wait_changed.waitUncancelable(io_mod.getIo(), &self.mutex);
            }
            self.mutex.unlock(io_mod.getIo());
            freeSlot(self.alloc, slot);
        }
        self.slots.deinit(self.alloc);
        self.* = undefined;
    }

    fn pinWaitSlot(self: *Owner, target: WorkTarget) WaitError!?*Slot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.ChildUnavailable;
        for (self.slots.items) |slot| {
            if (!std.mem.eql(u8, slot.child_id, target.child_id)) continue;
            if (!std.mem.eql(u8, slot.work_id, target.work_id)) return error.StaleWork;
            slot.wait_refs += 1;
            return slot;
        }
        return null;
    }

    fn releaseWaitSlot(self: *Owner, slot: *Slot) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        std.debug.assert(slot.wait_refs > 0);
        slot.wait_refs -= 1;
        if (slot.wait_refs == 0) slot.wait_changed.broadcast(io_mod.getIo());
        if (!self.closed and slot.wait_refs == 0 and slot.completion != .running) {
            for (self.slots.items, 0..) |candidate, index| {
                if (candidate != slot) continue;
                _ = self.slots.swapRemove(index);
                self.slots_changed.broadcast(io_mod.getIo());
                const alloc = self.alloc;
                self.mutex.unlock(io_mod.getIo());
                destroySlot(alloc, slot);
                return;
            }
        }
        self.mutex.unlock(io_mod.getIo());
    }

    fn loadRegistry(self: *Owner) WaitError!child_state.Registry {
        return self.state_store.load(self.alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.StateUnavailable,
        };
    }

    fn observe(self: *Owner, target: WorkTarget) WaitError!Observation {
        var lock = self.state_store.acquireLock(self.alloc) catch return error.StateUnavailable;
        defer lock.release();
        var registry = try self.loadRegistry();
        defer registry.deinit(self.alloc);
        return observeWork(&registry, target);
    }

    fn phaseTransition(
        raw: *anyopaque,
        child_id: []const u8,
        work_id: []const u8,
        phase: child_state.Phase,
    ) !void {
        const self: *Owner = @ptrCast(@alignCast(raw));
        var lock = try self.state_store.acquireLock(self.alloc);
        defer lock.release();
        var registry = try self.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        const active = child.active orelse return error.StaleWork;
        if (!std.mem.eql(u8, active.id, work_id)) return error.StaleWork;
        child.phase = phase;
        registry.generation +|= 1;
        try self.state_store.save(self.alloc, registry);
    }

    fn finish(
        self: *Owner,
        child_id: []const u8,
        work_id: []const u8,
        outcome: child_state.Outcome,
        failure: ?types.ModelFailureDiagnostic,
    ) bool {
        // Preserve exact evidence before registry publication admits replacement
        // work. The publisher acquires the registry lock independently.
        if (self.outcome_publisher) |publisher| {
            publisher.publish_fn(publisher.context, .{ .child_id = child_id, .work_id = work_id }, outcome, failure) catch |err| {
                debugFailure(child_id, "delivery_publication", err);
                return false;
            };
        }
        var lock = self.state_store.acquireLock(self.alloc) catch |err| {
            debugFailure(child_id, "state_lock", err);
            return false;
        };
        defer lock.release();
        var registry = self.state_store.load(self.alloc) catch |err| {
            debugFailure(child_id, "state_load", err);
            return false;
        };
        defer registry.deinit(self.alloc);
        registry.finish(self.alloc, child_id, work_id, outcome, failure) catch |err| {
            debugFailure(child_id, "state_finish", err);
            return false;
        };
        self.state_store.save(self.alloc, registry) catch |err| {
            debugFailure(child_id, "state_save", err);
            return false;
        };
        debug_trace.eventf("subagent", "child_outcome_published", .{}, "root_id={s} child_id={s} work_id={s} outcome={s} generation={d}", .{ self.state_store.parent_id, child_id, work_id, @tagName(outcome), registry.generation });
        return true;
    }
};

fn observeWork(registry: *child_state.Registry, target: WorkTarget) WaitError!Observation {
    const child = registry.findById(target.child_id) orelse return error.ChildUnavailable;
    if (child.active) |active| {
        if (!std.mem.eql(u8, active.id, target.work_id)) return error.StaleWork;
        return .{ .phase = child.phase };
    }
    const last_work_id = child.last_work_id orelse return error.StaleWork;
    if (!std.mem.eql(u8, last_work_id, target.work_id)) return error.StaleWork;
    return .{ .phase = child.phase, .outcome = child.last_outcome, .failure = child.last_failure };
}

fn createSlot(owner: *Owner, target: WorkTarget) Allocator.Error!*Slot {
    const slot = try owner.alloc.create(Slot);
    errdefer owner.alloc.destroy(slot);
    const child_id = try owner.alloc.dupe(u8, target.child_id);
    errdefer owner.alloc.free(child_id);
    slot.* = .{
        .owner = owner,
        .child_id = child_id,
        .work_id = try owner.alloc.dupe(u8, target.work_id),
    };
    return slot;
}

fn freeSlot(alloc: Allocator, slot: *Slot) void {
    std.debug.assert(slot.route_refs == 0);
    std.debug.assert(slot.wait_refs == 0);
    alloc.free(slot.work_id);
    alloc.free(slot.child_id);
    alloc.destroy(slot);
}

fn destroySlot(alloc: Allocator, slot: *Slot) void {
    if (slot.thread) |thread| thread.join();
    freeSlot(alloc, slot);
}

fn slotMain(slot: *Slot) void {
    const owner = slot.owner;
    debug_trace.eventf("subagent", "child_worker_entered", .{}, "root_id={s} child_id={s} work_id={s}", .{ owner.state_store.parent_id, slot.child_id, slot.work_id });
    const outcome = runOne(slot);
    debug_trace.eventf("subagent", "child_execution_settled", .{}, "root_id={s} child_id={s} work_id={s} outcome={s}", .{ owner.state_store.parent_id, slot.child_id, slot.work_id, @tagName(outcome.outcome) });
    const published = owner.finish(slot.child_id, slot.work_id, outcome.outcome, outcome.failure);
    if (!published) debug_trace.eventf("subagent", "child_outcome_publication_failed", .{}, "root_id={s} child_id={s} work_id={s} outcome={s}", .{ owner.state_store.parent_id, slot.child_id, slot.work_id, @tagName(outcome.outcome) });
    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.completion = if (published) .published else .unpublished;
    slot.done.set(io_mod.getIo());
    owner.slots_changed.broadcast(io_mod.getIo());
    owner.mutex.unlock(io_mod.getIo());
}

const OneOutcome = struct {
    outcome: child_state.Outcome,
    failure: ?types.ModelFailureDiagnostic = null,
};

fn runOne(slot: *Slot) OneOutcome {
    const owner = slot.owner;
    var snapshot = loadRunSnapshot(owner, .{ .child_id = slot.child_id, .work_id = slot.work_id }) catch |err| {
        debugFailure(slot.child_id, "run_snapshot", err);
        return failedOutcome("run_snapshot", err);
    };
    defer snapshot.deinit(owner.alloc);

    var loaded = owner.sessions.resumeTargetForWrite(
        owner.alloc,
        .{ .id = slot.child_id },
        owner.sessions.workspace_root,
        .{},
    ) catch |err| return failedOutcome("session_resume", err);
    defer {
        loaded.log.park();
        loaded.deinit(owner.alloc);
    }
    var turn = execution.TurnContext.init(
        owner.alloc,
        &loaded,
        owner.max_history_turns,
    ) catch |err| return failedOutcome("turn_initialization", err);
    defer turn.deinit();
    turn.live_authority = owner.authority_resolver;
    turn.approval_registry = owner.approvals;
    turn.child_id = slot.child_id;
    turn.active_work_id = slot.work_id;
    turn.phase_context = owner;
    turn.phase_fn = Owner.phaseTransition;
    attachWorker(slot, turn.workerRuntime());
    turn.approval_worker_route = workerRoute(slot);
    defer detachWorker(slot);
    if (slot.shutdown.load(.seq_cst)) return .{ .outcome = .interrupted };

    var message = snapshot.active.queuedMessage(
        owner.alloc,
        owner.state_store.parent_id,
        snapshot.instructions,
    ) catch |err| return failedOutcome("message_preparation", err);
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
    }) catch |err| return if (err == error.Cancelled) .{
        .outcome = .cancelled,
    } else failedOutcome("admission", err);
    var owned_admission = admission;
    defer owned_admission.deinit(owner.alloc);
    const result = owner.services.run(
        &turn,
        message,
        admission,
        &slot.cancel,
    ) catch |err| {
        const outcome: child_state.Outcome = if (slot.shutdown.load(.seq_cst))
            .interrupted
        else if (slot.cancel.load(.seq_cst) or err == error.Cancelled)
            .cancelled
        else
            .failed;
        return .{
            .outcome = outcome,
            .failure = if (outcome == .failed)
                turn.failureDiagnostic() orelse execution.failureDiagnosticValue("agent_execution", @errorName(err))
            else
                null,
        };
    };
    if (slot.shutdown.load(.seq_cst)) return .{
        .outcome = .interrupted,
    };
    if (slot.cancel.load(.seq_cst)) return .{
        .outcome = .cancelled,
    };
    return .{
        .outcome = switch (result) {
            .completed => .completed,
            .awaiting_approval, .paused => .interrupted,
        },
    };
}

fn attachWorker(slot: *Slot, worker: *worker_runtime.WorkerRuntime) void {
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.worker = worker;
    const shutdown = slot.shutdown.load(.seq_cst);
    const cancel = slot.cancel.load(.seq_cst);
    owner.mutex.unlock(io_mod.getIo());
    // The constructing child owns this worker until detach. Replay signals
    // received before attachment without nesting the owner and worker locks.
    if (shutdown) {
        worker.requestShutdown();
    } else if (cancel) {
        worker.requestCancel();
    }
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
    const worker = slot.worker orelse {
        var owned = response;
        owned.deinit();
        return .no_pending;
    };
    return worker.submitPermissionResponseAfterCommit(
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
    if (slot.worker) |worker| worker.cancelApprovalTurn();
}

fn pinWorkerRoute(raw: *anyopaque) bool {
    const slot: *Slot = @ptrCast(@alignCast(raw));
    const owner = slot.owner;
    owner.mutex.lockUncancelable(io_mod.getIo());
    defer owner.mutex.unlock(io_mod.getIo());
    if (slot.worker == null) return false;
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
    slot.worker = null;
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

fn loadRunSnapshot(owner: *Owner, target: WorkTarget) !RunSnapshot {
    var lock = try owner.state_store.acquireLock(owner.alloc);
    defer lock.release();
    var registry = try owner.state_store.load(owner.alloc);
    defer registry.deinit(owner.alloc);
    const child = registry.findById(target.child_id) orelse return error.ChildUnavailable;
    const active = child.active orelse return error.StaleWork;
    if (!std.mem.eql(u8, active.id, target.work_id)) return error.StaleWork;
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

fn failedOutcome(stage: []const u8, err: anyerror) OneOutcome {
    return .{
        .outcome = .failed,
        .failure = execution.failureDiagnosticValue(stage, @errorName(err)),
    };
}

fn debugFailure(child_id: []const u8, stage: []const u8, err: anyerror) void {
    @import("../shared/debug_trace.zig").logf(
        "subagent",
        "managed child state update failed child_id={s} stage={s} err={s}",
        .{ child_id, stage, @errorName(err) },
    );
}

fn createTestSession(sessions: *session_store.Store, id: []const u8) !void {
    const alloc = std.testing.allocator;
    const state = @import("../session/session_codec.zig").DurableSessionState{
        .id = @constCast(id),
        .origin_workspace_root = @constCast(sessions.workspace_root),
        .workspace_root = @constCast(sessions.workspace_root),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = @import("../session/session.zig").ConversationLanguage.literal("en"),
        .preferences = .{ .model = @constCast("test"), .effort = .auto, .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    var writable = try sessions.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    writable.log.park();
}

test "exact work cancellation wait and reuse never target the next generation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var sessions = try session_store.Store.initFromHome(alloc, home, home);
    defer sessions.deinit(alloc);
    var approvals = approval_registry.Registry{ .alloc = alloc };
    defer approvals.deinit();
    var owner = Owner{
        .alloc = alloc,
        .sessions = &sessions,
        .state_store = .{ .sessions = &sessions, .parent_id = "parent" },
        .services = undefined,
        .authority_resolver = undefined,
        .approvals = &approvals,
    };
    defer owner.deinit();
    var registry = try child_state.Registry.init(alloc, "parent");
    defer registry.deinit(alloc);
    try createTestSession(&sessions, "parent");
    const a = WorkTarget{ .child_id = "child", .work_id = "work-a" };
    const b = WorkTarget{ .child_id = "child", .work_id = "work-b" };
    const missing = WorkTarget{ .child_id = "other", .work_id = "work-a" };
    const pulse = std.Io.Clock.Duration{ .clock = .awake, .raw = .fromMilliseconds(0) };
    const work_a = child_state.ActiveWork{
        .id = @constCast(a.work_id),
        .message = @constCast("review"),
        .created_at_ms = 1,
    };
    try registry.appendPersistent(alloc, a.child_id, "reviewer", "", work_a);
    try owner.state_store.save(alloc, registry);
    const slot_a = try createSlot(&owner, a);
    try owner.slots.append(alloc, slot_a);
    try std.testing.expectEqual(StartResult.already_running, try owner.start(a));
    try std.testing.expectError(error.StaleWork, owner.start(b));
    try std.testing.expectError(error.StaleWork, owner.wait(b, pulse));
    try std.testing.expectError(error.StaleWork, owner.cancelWork(b));
    try std.testing.expectError(error.ChildUnavailable, owner.cancelWork(missing));
    try std.testing.expect(!slot_a.cancel.load(.seq_cst));
    const running = try owner.wait(a, pulse);
    try std.testing.expectEqual(child_state.Phase.running, running.phase);
    try std.testing.expect(running.outcome == null);
    try std.testing.expectEqual(CancelResult.cancellation_requested, try owner.cancelWork(a));
    try std.testing.expectEqual(CancelResult.cancellation_requested, try owner.cancelWork(a));
    try std.testing.expect(slot_a.cancel.load(.seq_cst));

    // Two waiters keep A alive even after another waiter observes completion.
    const first = (try owner.pinWaitSlot(a)).?;
    const second = (try owner.pinWaitSlot(a)).?;
    try registry.finish(alloc, a.child_id, a.work_id, .completed, null);
    try owner.state_store.save(alloc, registry);
    slot_a.completion = .published;
    slot_a.done.set(io_mod.getIo());
    try std.testing.expectEqual(StartResult.already_finished, try owner.start(a));
    try std.testing.expectEqual(CancelResult.already_finished, try owner.cancelWork(a));
    try std.testing.expectEqual(child_state.Outcome.completed, (try owner.wait(a, pulse)).outcome.?);
    try std.testing.expectEqual(@as(usize, 1), owner.slots.items.len);
    owner.releaseWaitSlot(first);
    try std.testing.expectEqual(@as(usize, 1), owner.slots.items.len);

    var work_b = work_a;
    work_b.id = @constCast(b.work_id);
    _ = try registry.startPersistentWork(alloc, "reviewer", null, work_b);
    try owner.state_store.save(alloc, registry);
    try std.testing.expectError(error.StaleWork, owner.wait(a, pulse));
    try std.testing.expectError(error.StaleWork, loadRunSnapshot(&owner, a));
    const observed_b = try owner.observe(b);
    try std.testing.expectEqual(child_state.Phase.running, observed_b.phase);
    try std.testing.expect(observed_b.outcome == null);
    owner.releaseWaitSlot(second);
    try std.testing.expectEqual(@as(usize, 0), owner.slots.items.len);

    const slot_b = try createSlot(&owner, b);
    try owner.slots.append(alloc, slot_b);
    try std.testing.expectError(error.StaleWork, owner.cancelWork(a));
    try std.testing.expectError(error.StaleWork, owner.wait(a, pulse));
    try std.testing.expect(!slot_b.cancel.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), owner.slots.items.len);
}

test "exact work spawned failure publishes the bound identity and reaps cleanly" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var sessions = try session_store.Store.initFromHome(alloc, home, home);
    defer sessions.deinit(alloc);
    var approvals = approval_registry.Registry{ .alloc = alloc };
    defer approvals.deinit();
    var owner = Owner{
        .alloc = alloc,
        .sessions = &sessions,
        .state_store = .{ .sessions = &sessions, .parent_id = "parent" },
        .services = undefined,
        .authority_resolver = undefined,
        .approvals = &approvals,
    };
    defer owner.deinit();
    var registry = try child_state.Registry.init(alloc, "parent");
    defer registry.deinit(alloc);
    try createTestSession(&sessions, "parent");
    const target = WorkTarget{ .child_id = "missing-session", .work_id = "exact-work" };
    try registry.appendOneOff(alloc, target.child_id, .{
        .id = @constCast(target.work_id),
        .message = @constCast("review"),
        .created_at_ms = 1,
    });
    try owner.state_store.save(alloc, registry);
    try std.testing.expectEqual(StartResult.started, try owner.start(target));
    const result = try owner.wait(target, .{ .clock = .awake, .raw = .fromSeconds(5) });
    try std.testing.expectEqual(child_state.Outcome.failed, result.outcome.?);
    try std.testing.expect(result.failure != null);
    try std.testing.expectEqual(@as(usize, 0), owner.slots.items.len);
    try std.testing.expectEqual(CancelResult.already_finished, try owner.cancelWork(target));
    try std.testing.expectEqual(StartResult.already_finished, try owner.start(target));
    try std.testing.expectEqual(@as(usize, 0), owner.slots.items.len);
}

test "exact work threaded completion and cancellation preserve persistent identity" {
    const Fixture = struct {
        entered: std.Io.Event = .unset,
        release: std.Io.Event = .unset,

        fn capture(_: ?*anyopaque, alloc: Allocator, request: execution.CaptureRequest) execution.ServiceError!domain.AdmissionSnapshot {
            return domain.captureAdmission(alloc, .{
                .parent_id = request.parent_id,
                .source_id = request.source_id,
                .model = request.preferences.model,
                .effort = request.preferences.effort,
            }) catch return error.AdmissionFailed;
        }

        fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, cancel: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!std.mem.eql(u8, turn.active_work_id.?, message.id)) return error.ProviderFailed;
            self.entered.set(io_mod.getIo());
            self.release.waitUncancelable(io_mod.getIo());
            if (cancel.load(.seq_cst)) return error.Cancelled;
            turn.commit(message.id, .{ .assistant = .{
                .user = .{ .text = message.content },
                .assistant = @constCast("completed"),
            } }, 0, 0, 2) catch return error.ProviderFailed;
            return .completed;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var sessions = try session_store.Store.initFromHome(alloc, home, home);
    defer sessions.deinit(alloc);
    try createTestSession(&sessions, "parent");
    try createTestSession(&sessions, "child");
    var approvals = approval_registry.Registry{ .alloc = alloc };
    defer approvals.deinit();
    var resolver = authority.Resolver{ .sessions = &sessions, .root_id = "parent", .host = undefined };
    var fixture = Fixture{};
    var owner = Owner{
        .alloc = alloc,
        .sessions = &sessions,
        .state_store = .{ .sessions = &sessions, .parent_id = "parent" },
        .services = .{ .context = &fixture, .capture_fn = Fixture.capture, .run_fn = Fixture.run },
        .authority_resolver = &resolver,
        .approvals = &approvals,
    };
    defer owner.deinit();
    defer fixture.release.set(io_mod.getIo());
    const trace_path = try std.fs.path.join(alloc, &.{ home, "child-flow.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "subagent");
    defer debug_trace.resetForTest();
    for ([_][]const u8{ "work-a", "work-b" }, 0..) |work_id, index| {
        fixture.entered = .unset;
        fixture.release = .unset;
        var registry = if (index == 0)
            try child_state.Registry.init(alloc, "parent")
        else
            try owner.state_store.load(alloc);
        defer registry.deinit(alloc);
        const target = WorkTarget{ .child_id = "child", .work_id = work_id };
        const active = child_state.ActiveWork{ .id = @constCast(work_id), .message = @constCast("PRIVATE_CHILD_TASK_DO_NOT_LOG"), .created_at_ms = 1 };
        if (index == 0) {
            try registry.appendPersistent(alloc, "child", "reviewer", "", active);
        } else {
            _ = try registry.startPersistentWork(alloc, "reviewer", null, active);
        }
        try owner.state_store.save(alloc, registry);
        try std.testing.expectEqual(StartResult.started, try owner.start(target));
        try fixture.entered.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        try std.testing.expectEqual(StartResult.already_running, try owner.start(target));
        if (index == 1) {
            try std.testing.expectError(error.StaleWork, owner.cancelWork(.{ .child_id = "child", .work_id = "work-a" }));
            try std.testing.expectEqual(CancelResult.cancellation_requested, try owner.cancelWork(target));
        }
        fixture.release.set(io_mod.getIo());
        const result = try owner.wait(target, .{ .clock = .awake, .raw = .fromSeconds(5) });
        try std.testing.expectEqual(if (index == 0) child_state.Outcome.completed else .cancelled, result.outcome.?);
        try std.testing.expectEqual(@as(usize, 0), owner.slots.items.len);
    }
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "child-flow.log", alloc, .limited(64 * 1024));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "PRIVATE_CHILD_TASK_DO_NOT_LOG") == null);
    for ([_][]const u8{ "work-a", "work-b" }) |work_id| {
        var offset: usize = 0;
        for ([_][]const u8{ "child_slot_published", "child_worker_entered", "child_execution_settled", "child_outcome_published" }) |event| {
            const expected = try std.fmt.allocPrint(alloc, "event={s} root_id=parent child_id=child work_id={s}", .{ event, work_id });
            defer alloc.free(expected);
            const next = std.mem.find(u8, trace[offset..], expected) orelse return error.MissingChildContractTrace;
            offset += next + expected.len;
            try std.testing.expect(std.mem.find(u8, trace[offset..], expected) == null);
        }
    }
    try std.testing.expect(std.mem.find(u8, trace, "event=child_cancel_rejected root_id=parent child_id=child work_id=work-a reason=stale_work") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=child_cancel_requested root_id=parent child_id=child work_id=work-b") != null);
}

test "shutdown signals held children and approval waits before deinit joins" {
    const Fixture = struct {
        entered: [2]std.Io.Event = .{ .unset, .unset },
        unblocked: [2]std.Io.Event = .{ .unset, .unset },
        release: std.Io.Event = .unset,

        fn capture(_: ?*anyopaque, alloc: Allocator, request: execution.CaptureRequest) execution.ServiceError!domain.AdmissionSnapshot {
            return domain.captureAdmission(alloc, .{
                .parent_id = request.parent_id,
                .source_id = request.source_id,
                .model = request.preferences.model,
                .effort = request.preferences.effort,
            }) catch return error.AdmissionFailed;
        }

        fn pending(raw: *anyopaque, _: *worker_runtime.WorkerRuntime, _: permission_request.PermissionRequest) error{ OutOfMemory, PermissionRegistrationFailed, PermissionCapacityExceeded }!void {
            const entered: *std.Io.Event = @ptrCast(@alignCast(raw));
            entered.set(io_mod.getIo());
        }

        fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, _: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const index: usize = if (std.mem.eql(u8, message.id, "work-a")) 0 else 1;
            var response = turn.workerRuntime().requestPermissionBlockingObserved(
                turn.alloc,
                .{ .label = "review" },
                null,
                .{ .context = &self.entered[index], .observe_fn = pending },
            ) catch return error.ProviderFailed;
            defer response.deinit();
            self.unblocked[index].set(io_mod.getIo());
            self.release.waitUncancelable(io_mod.getIo());
            return error.Cancelled;
        }

        fn shutdown(owner: *Owner, returned: *std.Io.Event) void {
            owner.requestShutdown();
            owner.requestShutdown();
            returned.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var sessions = try session_store.Store.initFromHome(alloc, home, home);
    defer sessions.deinit(alloc);
    try createTestSession(&sessions, "parent");
    var approvals = approval_registry.Registry{ .alloc = alloc };
    defer approvals.deinit();
    var resolver = authority.Resolver{ .sessions = &sessions, .root_id = "parent", .host = undefined };
    var fixture = Fixture{};
    var owner = Owner{
        .alloc = alloc,
        .sessions = &sessions,
        .state_store = .{ .sessions = &sessions, .parent_id = "parent" },
        .services = .{ .context = &fixture, .capture_fn = Fixture.capture, .run_fn = Fixture.run },
        .authority_resolver = &resolver,
        .approvals = &approvals,
    };
    var owner_live = true;
    defer if (owner_live) owner.deinit();
    defer fixture.release.set(io_mod.getIo());
    var registry = try child_state.Registry.init(alloc, "parent");
    defer registry.deinit(alloc);
    const targets = [_]WorkTarget{
        .{ .child_id = "child-a", .work_id = "work-a" },
        .{ .child_id = "child-b", .work_id = "work-b" },
    };
    for (targets) |target| {
        try createTestSession(&sessions, target.child_id);
        try registry.appendOneOff(alloc, target.child_id, .{
            .id = @constCast(target.work_id),
            .message = @constCast("review"),
            .created_at_ms = 1,
        });
    }
    try owner.state_store.save(alloc, registry);
    for (targets, 0..) |target, index| {
        try std.testing.expectEqual(StartResult.started, try owner.start(target));
        try fixture.entered[index].waitTimeout(io_mod.getIo(), timeout);
    }
    {
        var returned: std.Io.Event = .unset;
        const thread = try std.Thread.spawn(.{}, Fixture.shutdown, .{ &owner, &returned });
        defer thread.join();
        defer fixture.release.set(io_mod.getIo());
        try returned.waitTimeout(io_mod.getIo(), timeout);
        for (&fixture.unblocked) |*event| try event.waitTimeout(io_mod.getIo(), timeout);
        try std.testing.expect(owner.hasRunningWork());
        try std.testing.expectEqual(@as(usize, 2), owner.slots.items.len);
        try std.testing.expectError(error.OwnerClosed, owner.checkAdmission());
        try std.testing.expectError(error.OwnerClosed, owner.start(targets[0]));
        try std.testing.expectError(error.OwnerClosed, owner.start(.{ .child_id = "new", .work_id = "new" }));
    }
    const state_store = owner.state_store;
    owner.deinit();
    owner_live = false;
    var settled = try state_store.load(alloc);
    defer settled.deinit(alloc);
    for (targets) |target| {
        const child = settled.findById(target.child_id).?;
        try std.testing.expectEqual(child_state.Outcome.interrupted, child.last_outcome.?);
        try std.testing.expectEqualStrings(target.work_id, child.last_work_id.?);
    }
}

test "shutdown fences a starter already waiting on the previous work" {
    const Starter = struct {
        owner: *Owner,
        result: StartError!StartResult = undefined,
        returned: std.Io.Event = .unset,

        fn run(self: *@This()) void {
            self.result = self.owner.start(.{ .child_id = "child", .work_id = "work-b" });
            self.returned.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var sessions = try session_store.Store.initFromHome(alloc, home, home);
    defer sessions.deinit(alloc);
    try createTestSession(&sessions, "parent");
    var approvals = approval_registry.Registry{ .alloc = alloc };
    defer approvals.deinit();
    var owner = Owner{
        .alloc = alloc,
        .sessions = &sessions,
        .state_store = .{ .sessions = &sessions, .parent_id = "parent" },
        .services = undefined,
        .authority_resolver = undefined,
        .approvals = &approvals,
    };
    defer owner.deinit();
    var registry = try child_state.Registry.init(alloc, "parent");
    defer registry.deinit(alloc);
    try registry.appendPersistent(alloc, "child", "reviewer", "", .{
        .id = @constCast("work-b"),
        .message = @constCast("review"),
        .created_at_ms = 1,
    });
    try owner.state_store.save(alloc, registry);
    // Hold the publication gap: B is admitted but A has not signalled done.
    const previous = try createSlot(&owner, .{ .child_id = "child", .work_id = "work-a" });
    try owner.slots.append(alloc, previous);
    var starter = Starter{ .owner = &owner };
    const thread = try std.Thread.spawn(.{}, Starter.run, .{&starter});
    defer {
        owner.requestShutdown();
        owner.mutex.lockUncancelable(io_mod.getIo());
        previous.completion = .published;
        previous.done.set(io_mod.getIo());
        owner.slots_changed.broadcast(io_mod.getIo());
        owner.mutex.unlock(io_mod.getIo());
        thread.join();
    }
    for (0..1000) |_| {
        owner.mutex.lockUncancelable(io_mod.getIo());
        const waiting = previous.wait_refs > 0;
        owner.mutex.unlock(io_mod.getIo());
        if (waiting) break;
        io_mod.sleep(std.time.ns_per_ms);
    } else return error.TestUnexpectedResult;
    owner.requestShutdown();
    try starter.returned.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    try std.testing.expectError(error.OwnerClosed, starter.result);
    try std.testing.expectEqual(@as(usize, 1), owner.slots.items.len);
    try std.testing.expectEqual(@as(usize, 0), previous.wait_refs);
    try std.testing.expect(previous.shutdown.load(.seq_cst));
    try std.testing.expect(previous.cancel.load(.seq_cst));
}

test "shutdown reaches a worker attached after slot publication" {
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
    defer owner.deinit();
    const slot = try createSlot(&owner, .{ .child_id = "child", .work_id = "work" });
    try owner.slots.append(alloc, slot);
    owner.requestShutdown();
    owner.requestShutdown();
    try std.testing.expect(slot.shutdown.load(.seq_cst));
    try std.testing.expect(slot.cancel.load(.seq_cst));
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    attachWorker(slot, &worker);
    defer detachWorker(slot);
    try std.testing.expect(worker.isCancelRequested());
    try std.testing.expect(worker.worker_stop_requested);
    try std.testing.expectError(error.OwnerClosed, owner.start(.{ .child_id = "new", .work_id = "new" }));
}

fn checkSlotAllocation(alloc: Allocator) !void {
    var owner: Owner = undefined;
    owner.alloc = alloc;
    var child_id = "child".*;
    var work_id = "work".*;
    const slot = try createSlot(&owner, .{ .child_id = &child_id, .work_id = &work_id });
    defer freeSlot(alloc, slot);
    child_id[0] = 'x';
    work_id[0] = 'x';
    try std.testing.expectEqualStrings("child", slot.child_id);
    try std.testing.expectEqualStrings("work", slot.work_id);
}

test "exact work slot owns both identifiers and cleans up partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSlotAllocation, .{});
}

test "subagent failure to publish completion returns state unavailable instead of waiting" {
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
    defer owner.deinit();
    const target = WorkTarget{ .child_id = "child", .work_id = "work" };
    const slot = try createSlot(&owner, target);
    slot.completion = .unpublished;
    try owner.slots.append(alloc, slot);
    slot.done.set(io_mod.getIo());
    try std.testing.expectError(error.StateUnavailable, owner.wait(target, .{
        .clock = .awake,
        .raw = .fromMilliseconds(1),
    }));
    try std.testing.expectEqual(@as(usize, 0), owner.slots.items.len);
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
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
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
        .work_id = "work",
        .worker = &worker,
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
    try std.testing.expect(slot.worker == null);
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
