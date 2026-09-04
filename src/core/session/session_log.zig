const std = @import("std");
const session_read = @import("../shared/read_cancellation.zig");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const session = @import("session.zig");
const session_child_store = @import("session_child_store.zig");
const session_codec = @import("session_codec.zig");
const types = @import("../shared/types.zig");
const session_event = @import("session_event.zig");
const session_layout = @import("session_layout.zig");
const session_projection = @import("session_projection.zig");
const session_replay = @import("session_replay.zig");
const session_display_metadata = @import("session_display_metadata.zig");
const session_usage = @import("session_usage.zig");
const session_usage_sidecar = @import("session_usage_sidecar.zig");

const Allocator = std.mem.Allocator;
const Identifier = session_event.Identifier;
const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const lock_deadline_ms: u64 = 2000;
const authority_max_bytes: usize = 16 * 1024;
const authority_intent_max_bytes: usize = 32 * 1024;
const watermark_max_bytes: usize = 16 * 1024;
const publication_intent_max_bytes: usize = 32 * 1024;
const events_file = "events.jsonl";
const authority_file = "authority.json";
const authority_intent_file = "authority.pending.json";
const publication_intent_file = "commit.pending.json";
const manifest_file = "session.json";
const checkpoint_file = "checkpoint.json";
const session_lock_file = "session.lock";
const commit_lock_file = "commit.lock";

pub const Boundary = enum {
    after_event_append,
    after_event_sync,
    after_commit_intent_sync,
    after_watermark_rename,
    after_target_namespace_sync,
    before_usage_sidecar_write,
    after_commit_intent_remove,
    after_authority_intent_sync,
    after_authority_marker_rename,
    after_authority_namespace_sync,
    after_authority_intent_remove,
    after_compaction_temp_sync,
    after_compaction_watermark_sync,
    after_compaction_intent_sync,
    after_compaction_log_rename,
    after_compaction_namespace_sync,
    after_compaction_live_confirmation,
    after_compaction_intent_remove,
    after_latest_cache_pending,
    before_latest_cache_ready,
    before_recovery_proposed_validation,
    before_recovery_prior_validation,
    before_recovery_latest_publication,
    before_read_boundary_validation,
};

pub const LockKind = enum {
    session,
    commit,
};

pub const TestControls = struct {
    context: ?*anyopaque = null,
    boundary_fn: ?*const fn (?*anyopaque, Boundary) anyerror!void = null,
    lock_fn: ?*const fn (?*anyopaque, LockKind) void = null,

    pub fn boundary(self: TestControls, point: Boundary) !void {
        if (self.boundary_fn) |callback| try callback(self.context, point);
    }

    fn lock(self: TestControls, kind: LockKind) void {
        if (self.lock_fn) |callback| callback(self.context, kind);
    }
};

pub const Options = struct {
    test_controls: TestControls = .{},
    /// Borrowed for this operation; cancellation never outlives the caller.
    cancel_flag: ?*const std.atomic.Value(bool) = null,
    session_lock_deadline_ms: u64 = lock_deadline_ms,
    commit_lock_deadline_ms: u64 = lock_deadline_ms,
    checkpoint_interval: u64 = 32,
    compaction_frame_threshold: u64 = 4096,
    compaction_byte_threshold: u64 = 128 * 1024 * 1024,
    resolve_authority_intent: bool = true,
};

pub const OpenMode = enum {
    read_only,
    writable,
};

pub const CommitPosition = session_replay.CommitPosition;

test {
    _ = session_replay;
}

pub const FailedTailDisposition = enum {
    retry_expected_tail,
    rollback_before_adapter_continue,
};

pub const FailedTailKind = union(enum) {
    event: Identifier,
    state_replacement: struct {
        replacement_id: Identifier,
        final_event_id: Identifier,
    },
};

pub const FailedTail = struct {
    prior: CommitPosition,
    proposed: CommitPosition,
    kind: FailedTailKind,
    bytes: []u8,
    sha256: session_projection.Digest,

    pub fn deinit(self: *FailedTail, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

pub const PublicationKind = enum {
    watermark_advance,
    log_generation_replace,
};

pub const ProjectionStatus = enum {
    current,
    stale,
};

const ReplaySource = enum {
    checkpoint,
    event_log,
};

const OpenState = struct {
    state: session_codec.DurableSessionState,
    generation_base_seq: u64,
    generation_base_bytes: u64,
    checkpoint_seq: ?u64,
    checkpoint_sha256: ?session_projection.Digest,
    projection_status: ProjectionStatus,
    source: ReplaySource,
    tail_bytes: u64,
};

const CheckpointReplay = struct {
    state: session_codec.DurableSessionState,
    through_event_log_bytes: u64,
};

const OpenManifest = struct {
    manifest: session_projection.Manifest,
    event_file_matches: bool,
};

pub const CommitWatermarkStatus = enum {
    valid,
    missing,
    invalid,
    mismatched,
};

pub const CommitWatermarkInspection = struct {
    status: CommitWatermarkStatus,
    position: ?CommitPosition = null,
};

pub const CleanupMode = enum {
    report_only,
    delete,
};

pub const CleanupReport = struct {
    removed: usize = 0,
    report_only: usize = 0,
    ignored: usize = 0,
};

const AuthoritySource = enum {
    native_create,
    legacy_migration,
};

const AuthorityKind = enum {
    session_create,
    legacy_to_v3,
};

const AuthorityMarker = struct {
    session_id: []u8,
    authority_id: Identifier,
    source: AuthoritySource,

    fn deinit(self: *AuthorityMarker, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const LegacyFingerprint = struct {
    storage_format: []u8,
    primary_bytes: u64,
    primary_sha256: session_projection.Digest,

    fn deinit(self: *LegacyFingerprint, alloc: Allocator) void {
        alloc.free(self.storage_format);
        self.* = undefined;
    }
};

const AuthorityIntent = struct {
    session_id: []u8,
    operation_id: Identifier,
    kind: AuthorityKind,
    authority_id: Identifier,
    prior: ?LegacyFingerprint,
    proposed: CommitPosition,

    fn deinit(self: *AuthorityIntent, alloc: Allocator) void {
        alloc.free(self.session_id);
        if (self.prior) |*prior| prior.deinit(alloc);
        self.* = undefined;
    }
};

const PublicationIntent = struct {
    session_id: []u8,
    operation_id: Identifier,
    kind: PublicationKind,
    prior: CommitPosition,
    proposed: CommitPosition,

    fn deinit(self: *PublicationIntent, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const DecodedWatermark = struct {
    session_id: []u8,
    position: CommitPosition,

    fn deinit(self: *DecodedWatermark, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

pub const WritableSessionDir = struct {
    dir: io_mod.VerifiedDir,
    writer_lock: ?io_mod.TimedAdvisoryLock,
    session_id: []u8,

    pub fn deinit(self: *WritableSessionDir, alloc: Allocator) void {
        if (self.writer_lock) |*lock| lock.release();
        self.dir.close();
        alloc.free(self.session_id);
        self.* = undefined;
    }

    pub fn isParked(self: *const WritableSessionDir) bool {
        return self.writer_lock == null;
    }

    /// Release `session.lock` while keeping the session directory open for a
    /// later `unpark` in the same process (idle job-control suspend).
    pub fn park(self: *WritableSessionDir) void {
        const lock = &(self.writer_lock orelse return);
        lock.release();
        self.writer_lock = null;
    }

    /// Reacquire `session.lock` after `park`. Fails with `SessionBusy` when
    /// another process already owns the writer lock.
    pub fn unpark(self: *WritableSessionDir) !void {
        if (self.writer_lock != null) return;
        self.writer_lock = acquireLock(&self.dir, session_lock_file, true) catch |err| {
            return mapSessionLockError(err);
        };
    }

    pub fn eventLogLengthForTest(self: *WritableSessionDir) !u64 {
        var file = try openManagedFile(&self.dir, events_file, .read_only);
        defer file.close(io_mod.getIo());
        return file.length(io_mod.getIo());
    }

    fn entryExistsForTest(self: *WritableSessionDir, name: []const u8) !bool {
        return entryExists(&self.dir, name);
    }
};

pub const ReadBoundary = struct {
    log_file: std.Io.File,
    position: CommitPosition,
    usage_sidecar: session_usage_sidecar.Captured,
    alloc: Allocator,

    pub fn deinit(self: *ReadBoundary) void {
        self.log_file.close(io_mod.getIo());
        self.usage_sidecar.deinit(self.alloc);
        self.* = undefined;
    }
};

/// Loads the exact manifest boundary while deliberately ignoring a corrupt
/// commit watermark. The source directory remains unchanged.
pub fn recoverManifestBoundary(
    alloc: Allocator,
    writable: *WritableSessionDir,
    options: Options,
) !session_codec.DurableSessionState {
    if (writable.writer_lock == null) return error.SessionBusy;
    try requireIntentAbsent(alloc, &writable.dir, authority_intent_file);
    options.test_controls.lock(.commit);
    var commit_lock = acquireLockWithDeadline(
        &writable.dir,
        commit_lock_file,
        true,
        options.commit_lock_deadline_ms,
        options.cancel_flag,
    ) catch |err| return mapCommitLockError(err);
    defer commit_lock.release();
    try requireIntentAbsent(alloc, &writable.dir, authority_intent_file);
    try requireIntentAbsent(alloc, &writable.dir, publication_intent_file);

    var authority = try loadAuthority(
        alloc,
        &writable.dir,
        writable.session_id,
    );
    defer authority.deinit(alloc);
    const watermark = try inspectCommitWatermark(
        alloc,
        &writable.dir,
        writable.session_id,
        options.cancel_flag,
    );
    if (watermark.status == .valid) return error.SessionRecoveryNotNeeded;

    var manifest = try loadManifest(alloc, &writable.dir);
    defer manifest.deinit(alloc);
    if (!std.mem.eql(u8, manifest.id, writable.session_id) or
        !std.mem.eql(u8, &manifest.authority_id, &authority.authority_id))
    {
        return error.InvalidSessionFormat;
    }

    var event_log = try openManagedFile(
        &writable.dir,
        events_file,
        .read_only,
    );
    defer event_log.close(io_mod.getIo());
    const stat = try eventStat(event_log, manifest.event_log_bytes);
    if (session_projection.isManifestStale(manifest, stat)) {
        return error.InvalidSessionFormat;
    }

    var replayed = try session_replay.replayExactBoundary(
        alloc,
        event_log,
        manifest.log_generation,
        manifest.last_event_seq,
        manifest.event_log_bytes,
        options.cancel_flag,
    );
    errdefer replayed.deinit(alloc);
    if (!session_projection.stateMatchesManifest(replayed, manifest)) {
        return error.InvalidSessionFormat;
    }
    return replayed;
}

pub const CommitLifecycle = struct {
    context: ?*anyopaque = null,
    prepare_fn: ?*const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
        session_read.CancelFlag,
    ) anyerror!void = null,
    publish_fn: ?*const fn (
        ?*anyopaque,
        Allocator,
        session_codec.DurableSessionState,
        CommitPosition,
        session_read.CancelFlag,
    ) anyerror!void = null,
    abort_fn: ?*const fn (?*anyopaque) void = null,
    deinit_fn: ?*const fn (?*anyopaque, Allocator) void = null,

    pub fn prepare(
        self: *CommitLifecycle,
        alloc: Allocator,
        session_id: []const u8,
        cancel_flag: session_read.CancelFlag,
    ) !void {
        try session_read.check(cancel_flag);
        if (self.prepare_fn) |callback| {
            try callback(
                self.context,
                alloc,
                session_id,
                cancel_flag,
            );
        }
        try session_read.check(cancel_flag);
    }

    pub fn publish(
        self: *CommitLifecycle,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        position: CommitPosition,
        cancel_flag: session_read.CancelFlag,
    ) !void {
        if (self.publish_fn) |callback| {
            try callback(self.context, alloc, state, position, cancel_flag);
        }
    }

    pub fn abort(self: *CommitLifecycle) void {
        if (self.abort_fn) |callback| callback(self.context);
    }

    pub fn deinit(self: *CommitLifecycle, alloc: Allocator) void {
        self.abort();
        if (self.deinit_fn) |callback| callback(self.context, alloc);
        self.* = undefined;
    }
};

const PersistenceDebt = struct {
    canonical_replacement: bool = false,
    derived_publication: bool = false,
};

pub const ResumeHandoffBoundary = struct {
    authority_id: Identifier,
    position: CommitPosition,
};

const HandoffHeader = struct {
    generation: Identifier,
    event_id: Identifier,
};

fn parseHandoffHeader(alloc: Allocator, prefix: []const u8) !HandoffHeader {
    var scanner = std.json.Scanner.initCompleteInput(alloc, prefix);
    defer scanner.deinit();
    if (try scanner.next() != .object_begin) return error.InvalidSessionFormat;
    var generation: ?Identifier = null;
    var schema: ?u64 = null;
    var sequence: ?u64 = null;
    var kind: ?[]const u8 = null;
    var event_id: ?Identifier = null;
    var timestamp: ?i64 = null;
    for (0..7) |_| {
        const key = try scanner.next();
        if (key != .string) return error.InvalidSessionFormat;
        if (std.mem.eql(u8, key.string, "payload")) {
            if (schema != 1 or sequence != 1 or kind == null or event_id == null or timestamp == null or
                !std.mem.eql(u8, kind.?, "session_started")) return error.InvalidSessionFormat;
            return .{ .generation = generation orelse return error.InvalidSessionFormat, .event_id = event_id.? };
        }
        const value = try scanner.next();
        if (std.mem.eql(u8, key.string, "log_generation")) {
            if (generation != null or value != .string) return error.InvalidSessionFormat;
            generation = try parseIdentifier(value.string);
        } else if (std.mem.eql(u8, key.string, "schema_version")) {
            if (schema != null or value != .number) return error.InvalidSessionFormat;
            schema = std.fmt.parseInt(u64, value.number, 10) catch return error.InvalidSessionFormat;
        } else if (std.mem.eql(u8, key.string, "seq")) {
            if (sequence != null or value != .number) return error.InvalidSessionFormat;
            sequence = std.fmt.parseInt(u64, value.number, 10) catch return error.InvalidSessionFormat;
        } else if (std.mem.eql(u8, key.string, "kind")) {
            if (kind != null or value != .string) return error.InvalidSessionFormat;
            kind = value.string;
        } else if (std.mem.eql(u8, key.string, "event_id")) {
            if (event_id != null or value != .string) return error.InvalidSessionFormat;
            event_id = try parseIdentifier(value.string);
        } else if (std.mem.eql(u8, key.string, "timestamp_ms")) {
            if (timestamp != null or value != .number) return error.InvalidSessionFormat;
            timestamp = std.fmt.parseInt(i64, value.number, 10) catch return error.InvalidSessionFormat;
            if (timestamp.? < 0) return error.InvalidSessionFormat;
        } else return error.InvalidSessionFormat;
    }
    return error.SessionCommitBoundaryUnavailable;
}

fn confirmHandoffMetadata(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    expected: ?ResumeHandoffBoundary,
    options: Options,
) !void {
    options.test_controls.lock(.commit);
    var lock = acquireLockWithDeadline(dir, commit_lock_file, false, options.commit_lock_deadline_ms, options.cancel_flag) catch |err| return mapCommitLockError(err);
    defer lock.release();
    try requireIntentAbsent(alloc, dir, authority_intent_file);
    try requireIntentAbsent(alloc, dir, publication_intent_file);
    var authority = try loadAuthority(alloc, dir, session_id);
    defer authority.deinit(alloc);
    var events = try openManagedFile(dir, events_file, .read_only);
    defer events.close(io_mod.getIo());
    var prefix: [1024]u8 = undefined;
    const count = try events.readPositionalAll(io_mod.getIo(), &prefix, 0);
    const header = try parseHandoffHeader(alloc, prefix[0..count]);
    const generation = header.generation;
    const name = try watermarkName(alloc, generation);
    defer alloc.free(name);
    var watermark = try openManagedFile(dir, name, .read_only);
    defer watermark.close(io_mod.getIo());
    const watermark_stat = try watermark.stat(io_mod.getIo());
    if (watermark_stat.kind != .file or watermark_stat.nlink != 1) return error.InvalidSessionFormat;
    const bytes = try io_mod.readFileToEnd(alloc, &watermark, watermark_max_bytes);
    defer alloc.free(bytes);
    const position = try decodeWatermark(alloc, bytes, session_id, generation);
    if (position.through_seq == 0 or
        (position.through_seq == 1 and !std.mem.eql(u8, &position.through_event_id, &header.event_id)))
    {
        return error.InvalidSessionFormat;
    }
    const stat = try eventStat(events, position.through_event_log_bytes);
    if (stat.mtime_ns > watermark_stat.mtime.nanoseconds) return error.InvalidSessionFormat;
    if (expected) |known| {
        if (!std.mem.eql(u8, &authority.authority_id, &known.authority_id) or
            !positionsEqual(position, known.position)) return error.InvalidSessionFormat;
    } else if (stat.ctime_ns > watermark_stat.ctime.nanoseconds) {
        var manifest = try loadManifest(alloc, dir);
        defer manifest.deinit(alloc);
        if (!std.mem.eql(u8, manifest.id, session_id) or
            !std.mem.eql(u8, &manifest.authority_id, &authority.authority_id) or
            !std.mem.eql(u8, &manifest.log_generation, &position.log_generation) or
            manifest.last_event_seq != position.through_seq or
            manifest.event_log_bytes != position.through_event_log_bytes or
            session_projection.isManifestStale(manifest, stat)) return error.SessionCommitBoundaryUnavailable;
    }
}

pub const LoadedWritableSession = struct {
    pub const ExternalPromptOrigin = enum {
        root,
        persistent_child,
    };

    active_id: []u8,
    state: session_codec.DurableSessionState,
    log: WritableSessionDir,
    freshly_started: bool = false,
    persistence_debt: PersistenceDebt = .{},
    child_capability: ?*session_child_store.SessionChildCapability = null,
    commit_lifecycle: ?CommitLifecycle = null,
    position: CommitPosition,
    authority_id: Identifier,
    generation_base_seq: u64,
    generation_base_bytes: u64,
    checkpoint_seq: ?u64 = null,
    checkpoint_sha256: ?session_projection.Digest = null,
    projection_status: ProjectionStatus = .current,
    namespace_confirmation_required: bool = false,
    degraded_tail: ?FailedTail = null,
    compaction_warning_active: bool = false,
    migration_source_schema_version: ?u8 = null,
    migration_source_bytes: ?u64 = null,
    usage_sidecar_reseal_pending: bool = false,
    /// Runtime-only provenance installed by subagent resume admission. These
    /// fields are never written into the session event log.
    external_prompt_origin: ExternalPromptOrigin = .root,
    external_root_user_messages: [][]u8 = &.{},
    external_root_user_evidence_complete: bool = false,

    pub fn deinit(self: *LoadedWritableSession, alloc: Allocator) void {
        if (self.degraded_tail) |*tail| tail.deinit(alloc);
        if (self.commit_lifecycle) |*lifecycle| lifecycle.deinit(alloc);
        if (self.child_capability) |capability| {
            capability.deinit();
            alloc.destroy(capability);
        }
        for (self.external_root_user_messages) |message| alloc.free(message);
        if (self.external_root_user_messages.len > 0) {
            alloc.free(self.external_root_user_messages);
        }
        alloc.free(self.active_id);
        self.state.deinit(alloc);
        self.log.deinit(alloc);
        self.* = undefined;
    }

    /// Returns a borrowed address that remains stable until deinit.
    pub fn childCapability(
        self: *LoadedWritableSession,
    ) !*session_child_store.SessionChildCapability {
        return if (self.child_capability) |capability|
            capability
        else
            error.SessionChildCapabilityUnavailable;
    }

    pub fn installCommitLifecycle(
        self: *LoadedWritableSession,
        lifecycle: CommitLifecycle,
    ) !void {
        if (self.commit_lifecycle != null) return error.SessionCommitLifecycleAlreadyInstalled;
        self.commit_lifecycle = lifecycle;
    }

    pub fn appendEvent(
        self: *LoadedWritableSession,
        alloc: Allocator,
        event: session_event.Event,
        timestamp_ms: i64,
        failed_tail: FailedTailDisposition,
        options: Options,
    ) !CommitPosition {
        const preserves_pristine_start = switch (event) {
            .usage_checkpointed,
            .recovery_checkpoint_set,
            .recovery_checkpoint_cleared,
            => true,
            else => false,
        };
        const replacement_was_pending = self.persistence_debt.canonical_replacement;
        const usage_sidecar_bytes = switch (event) {
            .usage_checkpointed => |payload| encodeUsageSidecarBestEffort(
                alloc,
                self.state.id,
                payload.usage,
            ),
            else => if (self.state.usage) |usage|
                encodeUsageSidecarBestEffort(
                    alloc,
                    self.state.id,
                    usage,
                )
            else
                null,
        };
        const write_usage_sidecar = switch (event) {
            .usage_checkpointed => true,
            else => self.usage_sidecar_reseal_pending,
        };
        defer if (usage_sidecar_bytes) |bytes| alloc.free(bytes);
        try self.prepareCommitLifecycle(alloc, options.cancel_flag);
        _ = appendEventImpl(
            self,
            alloc,
            event,
            timestamp_ms,
            failed_tail,
            options,
            usage_sidecar_bytes,
            write_usage_sidecar,
        ) catch |err| {
            self.abortCommitLifecycle();
            return err;
        };
        if (!preserves_pristine_start) self.freshly_started = false;
        maintainCanonicalLogAfterCommit(self, alloc, options) catch |err| {
            self.abortCommitLifecycle();
            self.persistence_debt.canonical_replacement = true;
            return err;
        };
        self.persistence_debt.canonical_replacement = replacement_was_pending;
        self.persistence_debt.derived_publication = !self.publishCommitLifecycle(alloc, options.cancel_flag);
        return self.position;
    }

    pub fn commitStateReplacement(
        self: *LoadedWritableSession,
        alloc: Allocator,
        state: session_codec.DurableSessionState,
        reason: session_event.ReplacementReason,
        failed_tail: FailedTailDisposition,
        options: Options,
    ) !CommitPosition {
        var replacement = state;
        replacement.subagent_child = self.state.subagent_child;
        const usage_sidecar_bytes = if (replacement.usage) |usage|
            encodeUsageSidecarBestEffort(
                alloc,
                replacement.id,
                usage,
            )
        else
            null;
        defer if (usage_sidecar_bytes) |bytes| alloc.free(bytes);
        try self.prepareCommitLifecycle(alloc, options.cancel_flag);
        _ = commitStateReplacementImpl(
            self,
            alloc,
            replacement,
            reason,
            failed_tail,
            options,
            usage_sidecar_bytes,
            true,
        ) catch |err| {
            self.abortCommitLifecycle();
            return err;
        };
        self.freshly_started = false;
        maintainCanonicalLogAfterCommit(self, alloc, options) catch |err| {
            self.abortCommitLifecycle();
            self.persistence_debt.canonical_replacement = true;
            return err;
        };
        self.persistence_debt.canonical_replacement = false;
        self.persistence_debt.derived_publication = !self.publishCommitLifecycle(alloc, options.cancel_flag);
        return self.position;
    }

    pub fn degradedTail(self: *const LoadedWritableSession) ?*const FailedTail {
        return if (self.degraded_tail) |*tail| tail else null;
    }

    fn prepareCommitLifecycle(
        self: *LoadedWritableSession,
        alloc: Allocator,
        cancel_flag: session_read.CancelFlag,
    ) !void {
        try session_read.check(cancel_flag);
        if (self.commit_lifecycle) |*lifecycle| {
            lifecycle.prepare(
                alloc,
                self.active_id,
                cancel_flag,
            ) catch |err| {
                lifecycle.abort();
                return err;
            };
        }
    }

    pub fn publishCommitLifecycle(self: *LoadedWritableSession, alloc: Allocator, cancel_flag: session_read.CancelFlag) bool {
        if (self.commit_lifecycle) |*lifecycle| {
            lifecycle.publish(alloc, self.state, self.position, cancel_flag) catch |err| {
                lifecycle.abort();
                debug_trace.logf(
                    "session",
                    "event=session_index_publish_failed err={s}",
                    .{@errorName(err)},
                );
                return false;
            };
        }
        return true;
    }

    fn abortCommitLifecycle(self: *LoadedWritableSession) void {
        if (self.commit_lifecycle) |*lifecycle| lifecycle.abort();
    }

    pub fn retryDegradedWithStateReplacement(
        self: *LoadedWritableSession,
        alloc: Allocator,
        current_state: session_codec.DurableSessionState,
        options: Options,
    ) !void {
        return retryDegradedWithStateReplacementImpl(
            self,
            alloc,
            current_state,
            options,
        );
    }

    pub fn compactCanonicalLogIfDue(
        self: *LoadedWritableSession,
        alloc: Allocator,
        options: Options,
    ) !void {
        return compactCanonicalLogIfDueImpl(self, alloc, options);
    }

    pub fn writeCheckpointIfDue(
        self: *LoadedWritableSession,
        alloc: Allocator,
        ensure_present: bool,
        options: Options,
    ) !void {
        const recovering = self.namespace_confirmation_required;
        try confirmWritableNamespace(self, alloc, options);
        defer if (recovering) {
            self.persistence_debt.derived_publication = !self.publishCommitLifecycle(alloc, options.cancel_flag);
        };
        if (!checkpointDue(self, options.checkpoint_interval) and
            !(ensure_present and !self.hasCurrentCheckpoint()))
        {
            return;
        }
        writeCheckpointProjection(alloc, self, options.cancel_flag) catch |err| switch (err) {
            error.CheckpointTooLarge => return,
            else => return err,
        };
        try writeManifestProjection(alloc, self);
        self.projection_status = .current;
    }

    pub fn validateResumeBoundary(
        self: *LoadedWritableSession,
        alloc: Allocator,
        options: Options,
    ) !void {
        const recovering = self.namespace_confirmation_required;
        try confirmWritableNamespace(self, alloc, options);
        errdefer if (recovering) self.abortCommitLifecycle();
        _ = try validateLivePosition(
            alloc,
            &self.log.dir,
            self.active_id,
            self.position,
            options.cancel_flag,
        );
        if (recovering) self.persistence_debt.derived_publication = !self.publishCommitLifecycle(alloc, options.cancel_flag);
    }

    /// Confirms the writer's current durable boundary without replaying the
    /// event log. This is intentionally narrower than recovery validation:
    /// unresolved canonical work is rejected instead of repaired on exit.
    pub fn confirmResumeHandoffBoundary(
        self: *LoadedWritableSession,
        alloc: Allocator,
        options: Options,
    ) !void {
        return confirmHandoffMetadata(alloc, &self.log.dir, self.active_id, try self.resumeHandoffBoundary(), options);
    }

    /// Copies the canonical boundary for later confirmation after replay state
    /// is released. This value is not proof until revalidated at handoff time.
    pub fn resumeHandoffBoundary(self: *const LoadedWritableSession) !ResumeHandoffBoundary {
        if (self.degraded_tail != null or
            self.namespace_confirmation_required or
            self.persistence_debt.canonical_replacement)
        {
            return error.SessionPersistenceDegraded;
        }

        return .{
            .authority_id = self.authority_id,
            .position = self.position,
        };
    }

    /// Repairs only a corrupt watermark whose writer authority, complete
    /// event log, and in-memory state prove the same exact boundary.
    pub fn repairResumeBoundary(
        self: *LoadedWritableSession,
        alloc: Allocator,
        options: Options,
    ) !void {
        try confirmWritableNamespace(self, alloc, options);
        errdefer self.abortCommitLifecycle();
        {
            options.test_controls.lock(.commit);
            var commit_lock = acquireLockWithDeadline(
                &self.log.dir,
                commit_lock_file,
                true,
                options.commit_lock_deadline_ms,
                options.cancel_flag,
            ) catch |err| return mapCommitLockError(err);
            defer commit_lock.release();
            try requireIntentAbsent(alloc, &self.log.dir, authority_intent_file);
            try requireIntentAbsent(alloc, &self.log.dir, publication_intent_file);

            var event_log = try openManagedFile(
                &self.log.dir,
                events_file,
                .read_only,
            );
            defer event_log.close(io_mod.getIo());
            var recovered = try session_replay.replayExactPosition(
                alloc,
                event_log,
                self.position.log_generation,
                self.position.through_seq,
                self.position.through_event_log_bytes,
                options.cancel_flag,
            );
            defer recovered.deinit(alloc);
            if (!positionsEqual(recovered.position, self.position) or
                !try durableStatesEqualCancellable(recovered.state, self.state, options.cancel_flag))
            {
                return error.InvalidSessionFormat;
            }

            const watermark_bytes = try encodeWatermark(
                alloc,
                self.log.session_id,
                self.position,
            );
            defer alloc.free(watermark_bytes);
            const name = try watermarkName(alloc, self.position.log_generation);
            defer alloc.free(name);
            try self.prepareCommitLifecycle(alloc, options.cancel_flag);
            try durableReplace(alloc, &self.log.dir, name, watermark_bytes);
            _ = try validateLivePosition(
                alloc,
                &self.log.dir,
                self.active_id,
                self.position,
                options.cancel_flag,
            );
        }
        self.persistence_debt.derived_publication = !self.publishCommitLifecycle(alloc, options.cancel_flag);
    }

    pub fn hasCurrentCheckpoint(self: *const LoadedWritableSession) bool {
        return self.checkpoint_seq != null and
            self.checkpoint_sha256 != null and
            self.projection_status == .current;
    }

    pub fn needsFinalStateReplacement(
        self: *const LoadedWritableSession,
        usage_dirty: bool,
    ) bool {
        return usage_dirty or self.persistence_debt.canonical_replacement;
    }

    pub fn cleanupOrphans(
        self: *LoadedWritableSession,
        alloc: Allocator,
        mode: CleanupMode,
    ) !CleanupReport {
        try confirmWritableNamespace(self, alloc, .{});
        return cleanupOrphansImpl(self, alloc, mode, .{});
    }

    fn createCleanupCandidatesForTest(
        self: *LoadedWritableSession,
        alloc: Allocator,
    ) !CleanupCandidates {
        return makeCleanupCandidatesForTest(self, alloc);
    }

    fn validateCheckpointForTest(self: *LoadedWritableSession, alloc: Allocator) !void {
        const bytes = try readManagedFileAlloc(
            alloc,
            &self.log.dir,
            checkpoint_file,
            session_projection.checkpoint_max_bytes,
            null,
        );
        defer alloc.free(bytes);
        var checkpoint = try session_projection.decodeCheckpoint(alloc, bytes, null);
        defer checkpoint.deinit(alloc);
        var manifest = try loadManifest(alloc, &self.log.dir);
        defer manifest.deinit(alloc);
        const boundary = try validateCommitPosition(
            alloc,
            &self.log.dir,
            self.log.session_id,
            self.position,
            null,
        );
        try session_projection.validateCheckpointReference(
            manifest,
            bytes,
            checkpoint,
            boundary,
            .{
                .log_generation = checkpoint.log_generation,
                .seq = checkpoint.through_seq,
                .event_id = checkpoint.through_event_id,
                .event_log_bytes = checkpoint.through_event_log_bytes,
                .semantic = true,
            },
            null,
        );
    }
};

/// Preserves each call's exact error set while sharing one dynamic return ABI.
pub inline fn failLoadedWritableSession(err: anytype) @TypeOf(err)!LoadedWritableSession {
    return @errorCast(failLoadedWritableSessionDynamic(err));
}

noinline fn failLoadedWritableSessionDynamic(err: anyerror) anyerror!LoadedWritableSession {
    return err;
}

test "large session errors preserve their exact error type and identity" {
    const result = failLoadedWritableSession(error.NoSavedSessions);
    try std.testing.expect(
        @TypeOf(result) == error{NoSavedSessions}!LoadedWritableSession,
    );
    try std.testing.expectError(error.NoSavedSessions, result);
}

pub const Root = struct {
    sessions: ?io_mod.VerifiedDir,
    display_root: []u8,
    mode: OpenMode,

    pub fn initFromHome(
        alloc: Allocator,
        home_path: []const u8,
        mode: OpenMode,
    ) !Root {
        const zio = io_mod.getIo();
        var home = std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.fs.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                std.Io.Dir.createDirAbsolute(zio, home_path, private_dir_permissions) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => return create_err,
                };
                break :blk try std.Io.Dir.openDirAbsolute(zio, home_path, .{ .iterate = true });
            },
            else => return err,
        };
        defer home.close(zio);

        var durable_home = home.openDir(zio, profile_paths.root_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.fs.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                var verified_home = io_mod.VerifiedDir{
                    .dir = try std.Io.Dir.openDirAbsolute(zio, home_path, .{
                        .iterate = true,
                    }),
                };
                defer verified_home.close();
                const created = try io_mod.openOrCreateVerifiedPrivateDir(
                    &verified_home,
                    profile_paths.root_dir_name,
                );
                break :blk created.dir;
            },
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        defer durable_home.close(zio);
        if (mode == .writable) {
            durable_home.setPermissions(zio, private_dir_permissions) catch
                return error.PrivateStatePermissionsUnsupported;
        }
        try verifyPrivateDir(durable_home, mode);

        var sessions_dir = durable_home.openDir(zio, profile_paths.sessions_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (mode == .read_only) {
                    return .{
                        .sessions = null,
                        .display_root = try std.fs.path.join(
                            alloc,
                            &.{ home_path, profile_paths.root_dir_name, profile_paths.sessions_dir_name },
                        ),
                        .mode = mode,
                    };
                }
                var parent = io_mod.VerifiedDir{ .dir = durable_home };
                const created = try io_mod.openOrCreateVerifiedPrivateDir(
                    &parent,
                    profile_paths.sessions_dir_name,
                );
                break :blk created.dir;
            },
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        errdefer sessions_dir.close(zio);
        if (mode == .writable) {
            sessions_dir.setPermissions(zio, private_dir_permissions) catch
                return error.PrivateStatePermissionsUnsupported;
        }
        try verifyPrivateDir(sessions_dir, mode);
        if (mode == .writable) {
            // A concurrent opener can observe any newly created ancestor
            // before its creator has synced the corresponding parent entry.
            if (std.fs.path.dirname(home_path)) |parent_path| {
                var parent = try std.Io.Dir.openDirAbsolute(zio, parent_path, .{ .iterate = true });
                defer parent.close(zio);
                try io_mod.syncVerifiedDir(parent);
            }
            try io_mod.syncVerifiedDir(home);
            try io_mod.syncVerifiedDir(durable_home);
        }
        const display_root = try io_mod.dirRealpathAlloc(alloc, sessions_dir, ".");
        return .{
            .sessions = .{ .dir = sessions_dir },
            .display_root = display_root,
            .mode = mode,
        };
    }

    pub fn deinit(self: *Root, alloc: Allocator) void {
        if (self.sessions) |*dir| dir.close();
        alloc.free(self.display_root);
        self.* = undefined;
    }

    pub fn startWritableSession(
        self: *Root,
        alloc: Allocator,
        initial_state: session_codec.DurableSessionState,
        options: Options,
    ) !LoadedWritableSession {
        return self.startWritableSessionWithLifecycle(
            alloc,
            initial_state,
            options,
            null,
        );
    }

    pub fn startWritableSessionWithLifecycle(
        self: *Root,
        alloc: Allocator,
        initial_state: session_codec.DurableSessionState,
        options: Options,
        lifecycle: ?CommitLifecycle,
    ) !LoadedWritableSession {
        var lifecycle_value = lifecycle;
        errdefer if (lifecycle_value) |*value| value.deinit(alloc);
        if (self.mode != .writable or self.sessions == null) {
            return failLoadedWritableSession(error.SessionStoreUnavailable);
        }
        try session_codec.validateState(initial_state, options.cancel_flag);
        const sessions = &self.sessions.?;
        if (try entryExists(sessions, initial_state.id)) {
            return failLoadedWritableSession(error.SessionAlreadyExists);
        }

        if (lifecycle_value) |*value| {
            try value.prepare(alloc, initial_state.id, options.cancel_flag);
        }

        sessions.dir.createDir(
            io_mod.getIo(),
            initial_state.id,
            private_dir_permissions,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => return failLoadedWritableSession(error.SessionAlreadyExists),
            else => return failLoadedWritableSession(error.SessionStartFailed),
        };
        io_mod.syncVerifiedDir(sessions.dir) catch
            return failLoadedWritableSession(error.SessionStartFailed);

        var session_dir = try openSessionDir(sessions, initial_state.id, .writable);
        options.test_controls.lock(.session);
        var writer_lock = acquireLockWithDeadline(
            &session_dir,
            session_lock_file,
            true,
            options.session_lock_deadline_ms,
            options.cancel_flag,
        ) catch |err| {
            session_dir.close();
            return mapSessionLockError(err);
        };
        const session_id = alloc.dupe(u8, initial_state.id) catch |err| {
            writer_lock.release();
            session_dir.close();
            return err;
        };
        var writable = WritableSessionDir{
            .dir = session_dir,
            .writer_lock = writer_lock,
            .session_id = session_id,
        };
        var writable_owned = true;
        errdefer if (writable_owned) writable.deinit(alloc);
        var created = try createNativeSession(
            alloc,
            &writable,
            initial_state,
            options,
        );
        writable_owned = false;
        created.commit_lifecycle = lifecycle_value;
        lifecycle_value = null;
        created.persistence_debt.derived_publication = !created.publishCommitLifecycle(alloc, options.cancel_flag);
        return created;
    }

    pub fn resumeForWrite(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        options: Options,
    ) !LoadedWritableSession {
        return self.resumeForWriteWithLifecycle(alloc, session_id, options, null);
    }

    pub fn resumeForWriteWithLifecycle(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        options: Options,
        lifecycle: ?CommitLifecycle,
    ) !LoadedWritableSession {
        var lifecycle_value = lifecycle;
        errdefer if (lifecycle_value) |*value| value.deinit(alloc);
        options.test_controls.lock(.session);
        var writable = try self.openWritableSessionDir(
            alloc,
            session_id,
            options.session_lock_deadline_ms,
            options.cancel_flag,
        );
        const transferred = lifecycle_value;
        lifecycle_value = null;
        return openWritableSession(alloc, &writable, options, transferred) catch |err| {
            writable.deinit(alloc);
            return err;
        };
    }

    /// Confirms a stored target from bounded metadata only. This never creates
    /// files or repairs state; external-resume child admission is separate.
    pub fn confirmStoredResumeHandoff(self: *Root, alloc: Allocator, session_id: []const u8, expected: ?ResumeHandoffBoundary) !void {
        try session_layout.validateSessionId(session_id);
        if (self.sessions == null) return error.SessionNotFound;
        var dir = try openSessionDir(&self.sessions.?, session_id, .read_only);
        defer dir.close();
        return confirmHandoffMetadata(alloc, &dir, session_id, expected, .{
            .session_lock_deadline_ms = 0,
            .commit_lock_deadline_ms = 0,
        });
    }

    pub fn captureReadBoundary(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        options: Options,
    ) !ReadBoundary {
        if (self.sessions == null) return error.SessionNotFound;
        try session_layout.validateSessionId(session_id);
        var session_dir = openSessionDir(
            &self.sessions.?,
            session_id,
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        defer session_dir.close();
        try requireIntentAbsent(alloc, &session_dir, authority_intent_file);
        options.test_controls.lock(.commit);
        var lock = acquireLockWithDeadline(
            &session_dir,
            commit_lock_file,
            false,
            options.commit_lock_deadline_ms,
            options.cancel_flag,
        ) catch |err| switch (err) {
            error.FileNotFound, error.LockBusy, error.LockUnsupported => {
                try requireIntentAbsent(alloc, &session_dir, authority_intent_file);
                return error.SessionCommitBoundaryUnavailable;
            },
            else => return err,
        };
        var lock_held = true;
        defer if (lock_held) lock.release();
        try requireIntentAbsent(alloc, &session_dir, authority_intent_file);
        var marker = try loadAuthority(alloc, &session_dir, session_id);
        defer marker.deinit(alloc);
        try requireIntentAbsent(alloc, &session_dir, publication_intent_file);
        var log_file = try openManagedFile(&session_dir, events_file, .read_only);
        errdefer log_file.close(io_mod.getIo());
        const generation = try session_replay.readFirstGeneration(alloc, log_file, options.cancel_flag);
        const position = try loadWatermarkPosition(
            alloc,
            &session_dir,
            session_id,
            generation,
        );
        var usage_sidecar = try session_usage_sidecar.capture(
            alloc,
            &session_dir,
        );
        errdefer usage_sidecar.deinit(alloc);
        // The watermark and open handle preserve the committed prefix across
        // later appends or a generation rename. Validate it without blocking writers.
        lock.release();
        lock_held = false;

        try options.test_controls.boundary(.before_read_boundary_validation);
        _ = try session_replay.scanCommitPosition(alloc, log_file, position, options.cancel_flag);
        return .{
            .log_file = log_file,
            .position = position,
            .usage_sidecar = usage_sidecar,
            .alloc = alloc,
        };
    }

    pub fn loadReadOnly(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        options: Options,
    ) !session_codec.DurableSessionState {
        var boundary = try self.captureReadBoundary(alloc, session_id, options);
        defer boundary.deinit();
        var state = try session_replay.replayBoundary(
            alloc,
            boundary.log_file,
            boundary.position,
            options.cancel_flag,
        );
        errdefer state.deinit(alloc);
        if (state.usage) |*usage| {
            _ = try session_usage_sidecar.restoreCaptured(
                alloc,
                boundary.usage_sidecar,
                state.id,
                state.updated_at_ms,
                usage,
            );
        }
        return state;
    }

    /// Reads the immutable child-privacy bit from the first event without
    /// replaying history or acquiring the commit lock. State replacement and
    /// compaction preserve this bit for the lifetime of the session.
    pub fn loadSubagentChildIdentity(
        self: *const Root,
        alloc: Allocator,
        session_id: []const u8,
        cancel_flag: session_read.CancelFlag,
    ) !bool {
        var sessions = self.sessions orelse return error.SessionNotFound;
        try session_layout.validateSessionId(session_id);
        var session_dir = openSessionDir(
            &sessions,
            session_id,
            .read_only,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        defer session_dir.close();
        var log_file = try openManagedFile(&session_dir, events_file, .read_only);
        defer log_file.close(io_mod.getIo());
        return session_replay.readSubagentChildIdentity(alloc, log_file, cancel_flag);
    }

    fn openWritableSessionDir(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        deadline_ms: u64,
        cancel_flag: session_read.CancelFlag,
    ) !WritableSessionDir {
        if (self.mode != .writable or self.sessions == null) return error.SessionNotFound;
        try session_layout.validateSessionId(session_id);
        var dir = openSessionDir(&self.sessions.?, session_id, .writable) catch |err| switch (err) {
            error.FileNotFound => return error.SessionNotFound,
            else => return err,
        };
        var writer_lock = acquireLockWithDeadline(
            &dir,
            session_lock_file,
            true,
            deadline_ms,
            cancel_flag,
        ) catch |err| {
            dir.close();
            return mapSessionLockError(err);
        };
        const owned_id = alloc.dupe(u8, session_id) catch |err| {
            writer_lock.release();
            dir.close();
            return err;
        };
        return .{
            .dir = dir,
            .writer_lock = writer_lock,
            .session_id = owned_id,
        };
    }

    fn entryExistsForTest(
        self: *Root,
        alloc: Allocator,
        session_id: []const u8,
        name: []const u8,
    ) !bool {
        _ = alloc;
        if (self.sessions == null) return false;
        var dir = openSessionDir(&self.sessions.?, session_id, .read_only) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer dir.close();
        return entryExists(&dir, name);
    }
};

fn validateLeaf(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\") != null)
    {
        return error.SessionPathUnsafe;
    }
}

fn verifyPrivateDir(dir: std.Io.Dir, mode: OpenMode) !void {
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory) return error.SessionPathUnsafe;
    if (mode == .writable and stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn verifyManagedFile(file: std.Io.File, mode: OpenMode) !void {
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.SessionPathUnsafe;
    if (mode == .writable and stat.permissions.toMode() & 0o777 != 0o600) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn openSessionDir(
    sessions: *io_mod.VerifiedDir,
    session_id: []const u8,
    mode: OpenMode,
) !io_mod.VerifiedDir {
    try session_layout.validateSessionId(session_id);
    var dir = sessions.dir.openDir(io_mod.getIo(), session_id, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer dir.close(io_mod.getIo());
    if (mode == .writable) {
        dir.setPermissions(io_mod.getIo(), private_dir_permissions) catch
            return error.PrivateStatePermissionsUnsupported;
    }
    try verifyPrivateDir(dir, mode);
    return .{ .dir = dir };
}

fn openManagedFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !std.Io.File {
    try validateLeaf(name);
    var file = dir.dir.openFile(io_mod.getIo(), name, .{
        .mode = mode,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.IsDir, error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    try verifyManagedFile(file, if (mode == .read_only) .read_only else .writable);
    return file;
}

fn createManagedFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
) !std.Io.File {
    try validateLeaf(name);
    var file = dir.dir.createFile(io_mod.getIo(), name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.IsDir, error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    file.setPermissions(io_mod.getIo(), private_file_permissions) catch
        return error.PrivateStatePermissionsUnsupported;
    try verifyManagedFile(file, .writable);
    return file;
}

fn entryExists(dir: *io_mod.VerifiedDir, name: []const u8) !bool {
    try validateLeaf(name);
    const stat = dir.dir.statFile(io_mod.getIo(), name, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    if (stat.kind != .file and stat.kind != .directory) return error.SessionPathUnsafe;
    if (stat.kind == .file and stat.nlink != 1) return error.SessionPathUnsafe;
    return true;
}

fn acquireLock(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    create: bool,
) !io_mod.TimedAdvisoryLock {
    return acquireLockWithDeadline(dir, name, create, lock_deadline_ms, null);
}

fn acquireLockWithDeadline(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    create: bool,
    deadline_ms: u64,
    cancel_flag: ?*const std.atomic.Value(bool),
) !io_mod.TimedAdvisoryLock {
    if (create) {
        if (cancel_flag) |flag| {
            return io_mod.acquireTimedAdvisoryLockCancellable(dir, name, deadline_ms, flag);
        }
        return io_mod.acquireTimedAdvisoryLock(dir, name, deadline_ms);
    }
    var file = try openManagedFile(dir, name, .read_write);
    errdefer file.close(io_mod.getIo());
    const started = io_mod.milliTimestamp();
    while (true) {
        if (cancel_flag) |flag| {
            if (flag.load(.acquire)) return error.Cancelled;
        }
        const locked = file.tryLock(io_mod.getIo(), .exclusive) catch |err| switch (err) {
            error.FileLocksUnsupported => return error.LockUnsupported,
            else => return err,
        };
        if (locked) return .{ .file = file };
        if (io_mod.milliTimestamp() - started >= deadline_ms) return error.LockBusy;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}

fn mapSessionLockError(err: anyerror) anyerror {
    return switch (err) {
        error.LockBusy => error.SessionBusy,
        error.LockUnsupported => error.SessionLockUnsupported,
        else => err,
    };
}

fn readManagedFileAlloc(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    max_bytes: usize,
    cancel_flag: session_read.CancelFlag,
) ![]u8 {
    var file = try openManagedFile(dir, name, .read_only);
    defer file.close(io_mod.getIo());
    var file_buffer: [session_read.work_bytes]u8 = undefined;
    var reader = file.reader(io_mod.getIo(), &file_buffer);
    var buffer: [session_read.work_bytes]u8 = undefined;
    var cancellable = session_read.Reader.init(&reader.interface, &buffer, cancel_flag);
    return cancellable.interface.allocRemaining(alloc, .limited(max_bytes + 1)) catch |err| {
        try session_read.check(cancel_flag);
        return switch (err) {
            error.StreamTooLong => error.InvalidSessionFormat,
            else => err,
        };
    };
}

fn requireIntentAbsent(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
) !void {
    if (!try entryExists(dir, name)) return;
    if (std.mem.eql(u8, name, authority_intent_file)) {
        var intent = try loadAuthorityIntent(alloc, dir);
        defer intent.deinit(alloc);
        return error.SessionAuthorityBoundaryUnavailable;
    }
    var intent = try loadPublicationIntent(alloc, dir);
    defer intent.deinit(alloc);
    return error.SessionCommitBoundaryUnavailable;
}

fn randomIdentifier() Identifier {
    var id: Identifier = undefined;
    io_mod.getIo().random(&id);
    return id;
}

fn randomSequenceSeed() u128 {
    const id = randomIdentifier();
    return std.mem.readInt(u128, &id, .big);
}

fn identifierHex(id: Identifier) [32]u8 {
    return std.fmt.bytesToHex(id, .lower);
}

fn parseIdentifier(raw: []const u8) !Identifier {
    if (raw.len != 32) return error.InvalidSessionFormat;
    var result: Identifier = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return error.InvalidSessionFormat;
    const canonical = identifierHex(result);
    if (!std.mem.eql(u8, &canonical, raw)) return error.InvalidSessionFormat;
    return result;
}

fn parseDigest(raw: []const u8) !session_projection.Digest {
    if (raw.len != 64) return error.InvalidSessionFormat;
    var result: session_projection.Digest = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return error.InvalidSessionFormat;
    const canonical = std.fmt.bytesToHex(result, .lower);
    if (!std.mem.eql(u8, &canonical, raw)) return error.InvalidSessionFormat;
    return result;
}

fn encodeAuthority(alloc: Allocator, marker: AuthorityMarker) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(marker.session_id, .{}, &out.writer);
    const authority_hex = identifierHex(marker.authority_id);
    try out.writer.print(
        ",\"authority_id\":\"{s}\",\"storage_format\":\"event_log_v1\",\"source\":\"{s}\"}}\n",
        .{ authority_hex, @tagName(marker.source) },
    );
    if (out.written().len > authority_max_bytes) return error.InvalidSessionFormat;
    return out.toOwnedSlice();
}

fn decodeAuthority(alloc: Allocator, bytes: []const u8) !AuthorityMarker {
    if (bytes.len == 0 or bytes.len > authority_max_bytes) {
        return error.InvalidSessionFormat;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const object = try session_codec.exactObject(parsed.value, &.{
        "schema_version",
        "session_id",
        "authority_id",
        "storage_format",
        "source",
    });
    if (try requireU64(object, "schema_version") != 1 or
        !std.mem.eql(u8, try session_codec.requireString(object, "storage_format"), "event_log_v1"))
    {
        return error.InvalidSessionFormat;
    }
    const id = try alloc.dupe(u8, try session_codec.requireString(object, "session_id"));
    errdefer alloc.free(id);
    try session_layout.validateSessionId(id);
    return .{
        .session_id = id,
        .authority_id = try parseIdentifier(try session_codec.requireString(object, "authority_id")),
        .source = std.meta.stringToEnum(
            AuthoritySource,
            try session_codec.requireString(object, "source"),
        ) orelse return error.InvalidSessionFormat,
    };
}

fn encodeCommitPosition(writer: *std.Io.Writer, position: CommitPosition) !void {
    const generation = identifierHex(position.log_generation);
    const event_id = identifierHex(position.through_event_id);
    try writer.print(
        "{{\"log_generation\":\"{s}\",\"through_seq\":{d},\"through_event_id\":\"{s}\",\"through_event_log_bytes\":{d}}}",
        .{
            generation,
            position.through_seq,
            event_id,
            position.through_event_log_bytes,
        },
    );
}

fn parseCommitPosition(value: std.json.Value) !CommitPosition {
    const object = try session_codec.exactObject(value, &.{
        "log_generation",
        "through_seq",
        "through_event_id",
        "through_event_log_bytes",
    });
    return .{
        .log_generation = try parseIdentifier(try session_codec.requireString(object, "log_generation")),
        .through_seq = try requireU64(object, "through_seq"),
        .through_event_id = try parseIdentifier(try session_codec.requireString(object, "through_event_id")),
        .through_event_log_bytes = try requireU64(object, "through_event_log_bytes"),
    };
}

fn encodeAuthorityPosition(
    writer: *std.Io.Writer,
    position: CommitPosition,
) !void {
    const generation = identifierHex(position.log_generation);
    const event_id = identifierHex(position.through_event_id);
    try writer.print(
        "{{\"storage_format\":\"event_log_v1\",\"log_generation\":\"{s}\",\"through_seq\":{d},\"through_event_id\":\"{s}\",\"through_event_log_bytes\":{d}}}",
        .{
            generation,
            position.through_seq,
            event_id,
            position.through_event_log_bytes,
        },
    );
}

fn parseAuthorityPosition(value: std.json.Value) !CommitPosition {
    const object = try session_codec.exactObject(value, &.{
        "storage_format",
        "log_generation",
        "through_seq",
        "through_event_id",
        "through_event_log_bytes",
    });
    if (!std.mem.eql(
        u8,
        try session_codec.requireString(object, "storage_format"),
        "event_log_v1",
    )) {
        return error.InvalidSessionFormat;
    }
    return .{
        .log_generation = try parseIdentifier(try session_codec.requireString(object, "log_generation")),
        .through_seq = try requireU64(object, "through_seq"),
        .through_event_id = try parseIdentifier(try session_codec.requireString(object, "through_event_id")),
        .through_event_log_bytes = try requireU64(object, "through_event_log_bytes"),
    };
}

fn encodeAuthorityIntent(alloc: Allocator, intent: AuthorityIntent) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(intent.session_id, .{}, &out.writer);
    const operation = identifierHex(intent.operation_id);
    const authority = identifierHex(intent.authority_id);
    try out.writer.print(
        ",\"operation_id\":\"{s}\",\"kind\":\"{s}\",\"authority_id\":\"{s}\",\"prior\":",
        .{ operation, @tagName(intent.kind), authority },
    );
    if (intent.prior) |prior| {
        const digest = std.fmt.bytesToHex(prior.primary_sha256, .lower);
        try out.writer.writeAll("{\"storage_format\":");
        try std.json.Stringify.value(prior.storage_format, .{}, &out.writer);
        try out.writer.print(
            ",\"primary_bytes\":{d},\"primary_sha256\":\"{s}\"}}",
            .{ prior.primary_bytes, digest },
        );
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"proposed\":");
    try encodeAuthorityPosition(&out.writer, intent.proposed);
    try out.writer.writeAll("}\n");
    if (out.written().len > authority_intent_max_bytes) {
        return error.InvalidSessionFormat;
    }
    return out.toOwnedSlice();
}

fn decodeAuthorityIntent(alloc: Allocator, bytes: []const u8) !AuthorityIntent {
    if (bytes.len == 0 or bytes.len > authority_intent_max_bytes) {
        return error.InvalidSessionFormat;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const object = try session_codec.exactObject(parsed.value, &.{
        "schema_version",
        "session_id",
        "operation_id",
        "kind",
        "authority_id",
        "prior",
        "proposed",
    });
    if (try requireU64(object, "schema_version") != 1) {
        return error.InvalidSessionFormat;
    }
    const session_id = try alloc.dupe(u8, try session_codec.requireString(object, "session_id"));
    errdefer alloc.free(session_id);
    try session_layout.validateSessionId(session_id);
    const kind = std.meta.stringToEnum(
        AuthorityKind,
        try session_codec.requireString(object, "kind"),
    ) orelse return error.InvalidSessionFormat;
    const prior_value = object.get("prior") orelse return error.InvalidSessionFormat;
    var prior: ?LegacyFingerprint = null;
    errdefer if (prior) |*owned| owned.deinit(alloc);
    if (prior_value != .null) {
        const prior_object = try session_codec.exactObject(prior_value, &.{
            "storage_format",
            "primary_bytes",
            "primary_sha256",
        });
        prior = .{
            .storage_format = try alloc.dupe(
                u8,
                try session_codec.requireString(prior_object, "storage_format"),
            ),
            .primary_bytes = try requireU64(prior_object, "primary_bytes"),
            .primary_sha256 = try parseDigest(
                try session_codec.requireString(prior_object, "primary_sha256"),
            ),
        };
    }
    if ((kind == .session_create) != (prior == null)) {
        return error.InvalidSessionFormat;
    }
    return .{
        .session_id = session_id,
        .operation_id = try parseIdentifier(try session_codec.requireString(object, "operation_id")),
        .kind = kind,
        .authority_id = try parseIdentifier(try session_codec.requireString(object, "authority_id")),
        .prior = prior,
        .proposed = try parseAuthorityPosition(
            object.get("proposed") orelse return error.InvalidSessionFormat,
        ),
    };
}

fn encodeWatermark(
    alloc: Allocator,
    session_id: []const u8,
    position: CommitPosition,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const generation = identifierHex(position.log_generation);
    const event_id = identifierHex(position.through_event_id);
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, &out.writer);
    try out.writer.print(
        ",\"log_generation\":\"{s}\",\"through_seq\":{d},\"through_event_id\":\"{s}\",\"through_event_log_bytes\":{d}}}\n",
        .{
            generation,
            position.through_seq,
            event_id,
            position.through_event_log_bytes,
        },
    );
    if (out.written().len > watermark_max_bytes) return error.InvalidSessionFormat;
    return out.toOwnedSlice();
}

fn decodeWatermark(
    alloc: Allocator,
    bytes: []const u8,
    expected_session_id: []const u8,
    expected_generation: Identifier,
) !CommitPosition {
    var decoded = try parseWatermark(alloc, bytes);
    defer decoded.deinit(alloc);
    if (!std.mem.eql(u8, decoded.session_id, expected_session_id) or
        !std.mem.eql(u8, &decoded.position.log_generation, &expected_generation))
    {
        return error.InvalidSessionFormat;
    }
    return decoded.position;
}

fn parseWatermark(
    alloc: Allocator,
    bytes: []const u8,
) !DecodedWatermark {
    if (bytes.len == 0 or bytes.len > watermark_max_bytes) {
        return error.InvalidSessionFormat;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const object = try session_codec.exactObject(parsed.value, &.{
        "schema_version",
        "session_id",
        "log_generation",
        "through_seq",
        "through_event_id",
        "through_event_log_bytes",
    });
    if (try requireU64(object, "schema_version") != 1) {
        return error.InvalidSessionFormat;
    }
    const session_id = try alloc.dupe(
        u8,
        try session_codec.requireString(object, "session_id"),
    );
    errdefer alloc.free(session_id);
    try session_layout.validateSessionId(session_id);
    return .{
        .session_id = session_id,
        .position = .{
            .log_generation = try parseIdentifier(
                try session_codec.requireString(object, "log_generation"),
            ),
            .through_seq = try requireU64(object, "through_seq"),
            .through_event_id = try parseIdentifier(
                try session_codec.requireString(object, "through_event_id"),
            ),
            .through_event_log_bytes = try requireU64(
                object,
                "through_event_log_bytes",
            ),
        },
    };
}

pub fn inspectCommitWatermark(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    cancel_flag: session_read.CancelFlag,
) !CommitWatermarkInspection {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, log, cancel_flag);
    const name = try watermarkName(alloc, generation);
    defer alloc.free(name);
    if (!try entryExists(dir, name)) return .{ .status = .missing };
    const bytes = readManagedFileAlloc(
        alloc,
        dir,
        name,
        watermark_max_bytes,
        cancel_flag,
    ) catch |err| switch (err) {
        error.Cancelled, error.OutOfMemory, error.SessionPathUnsafe => return err,
        else => return .{ .status = .invalid },
    };
    defer alloc.free(bytes);
    var decoded = parseWatermark(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .status = .invalid },
    };
    defer decoded.deinit(alloc);
    if (!std.mem.eql(u8, decoded.session_id, session_id) or
        !std.mem.eql(u8, &decoded.position.log_generation, &generation))
    {
        return .{ .status = .mismatched };
    }
    _ = validateCommitPosition(
        alloc,
        dir,
        session_id,
        decoded.position,
        cancel_flag,
    ) catch |err| switch (err) {
        error.Cancelled, error.OutOfMemory => return err,
        else => return .{ .status = .mismatched },
    };
    return .{ .status = .valid, .position = decoded.position };
}

/// A bounded hint for reusing a derived manifest. A false result or metadata
/// failure requires canonical replay; this does not validate event contents.
pub fn manifestMatchesCommit(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    manifest: session_projection.Manifest,
    cancel_flag: session_read.CancelFlag,
) !bool {
    var lock = try acquireLockWithDeadline(dir, commit_lock_file, false, 0, cancel_flag);
    defer lock.release();
    try requireIntentAbsent(alloc, dir, authority_intent_file);
    try requireIntentAbsent(alloc, dir, publication_intent_file);
    var authority = try loadAuthority(alloc, dir, manifest.id);
    defer authority.deinit(alloc);
    if (!std.mem.eql(u8, &authority.authority_id, &manifest.authority_id)) return false;
    const position = try loadWatermarkPosition(alloc, dir, manifest.id, manifest.log_generation);
    if (position.through_seq != manifest.last_event_seq or
        position.through_event_log_bytes != manifest.event_log_bytes)
    {
        return false;
    }
    var file = try openManagedFile(dir, events_file, .read_only);
    defer file.close(io_mod.getIo());
    const stat = try eventStat(file, manifest.event_log_bytes);
    try session_read.check(cancel_flag);
    return !session_projection.isManifestStale(manifest, stat);
}

fn encodePublicationIntent(alloc: Allocator, intent: PublicationIntent) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(intent.session_id, .{}, &out.writer);
    const operation = identifierHex(intent.operation_id);
    try out.writer.print(
        ",\"operation_id\":\"{s}\",\"kind\":\"{s}\",\"prior\":",
        .{ operation, @tagName(intent.kind) },
    );
    try encodeCommitPosition(&out.writer, intent.prior);
    try out.writer.writeAll(",\"proposed\":");
    try encodeCommitPosition(&out.writer, intent.proposed);
    try out.writer.writeAll("}\n");
    if (out.written().len > publication_intent_max_bytes) {
        return error.InvalidSessionFormat;
    }
    return out.toOwnedSlice();
}

fn decodePublicationIntent(alloc: Allocator, bytes: []const u8) !PublicationIntent {
    if (bytes.len == 0 or bytes.len > publication_intent_max_bytes) {
        return error.InvalidSessionFormat;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const object = try session_codec.exactObject(parsed.value, &.{
        "schema_version",
        "session_id",
        "operation_id",
        "kind",
        "prior",
        "proposed",
    });
    if (try requireU64(object, "schema_version") != 1) {
        return error.InvalidSessionFormat;
    }
    const session_id = try alloc.dupe(u8, try session_codec.requireString(object, "session_id"));
    errdefer alloc.free(session_id);
    try session_layout.validateSessionId(session_id);
    return .{
        .session_id = session_id,
        .operation_id = try parseIdentifier(try session_codec.requireString(object, "operation_id")),
        .kind = std.meta.stringToEnum(
            PublicationKind,
            try session_codec.requireString(object, "kind"),
        ) orelse return error.InvalidSessionFormat,
        .prior = try parseCommitPosition(
            object.get("prior") orelse return error.InvalidSessionFormat,
        ),
        .proposed = try parseCommitPosition(
            object.get("proposed") orelse return error.InvalidSessionFormat,
        ),
    };
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .number_string) return error.InvalidSessionFormat;
    return std.fmt.parseUnsigned(u64, value.number_string, 10) catch
        return error.InvalidSessionFormat;
}

fn watermarkName(alloc: Allocator, generation: Identifier) ![]u8 {
    const hex = identifierHex(generation);
    return std.fmt.allocPrint(alloc, "commit.{s}.json", .{hex});
}

fn loadAuthority(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !AuthorityMarker {
    const bytes = try readManagedFileAlloc(alloc, dir, authority_file, authority_max_bytes, null);
    defer alloc.free(bytes);
    var marker = try decodeAuthority(alloc, bytes);
    errdefer marker.deinit(alloc);
    if (!std.mem.eql(u8, marker.session_id, session_id)) {
        return error.InvalidSessionFormat;
    }
    return marker;
}

fn loadAuthorityIntent(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !AuthorityIntent {
    const bytes = try readManagedFileAlloc(
        alloc,
        dir,
        authority_intent_file,
        authority_intent_max_bytes,
        null,
    );
    defer alloc.free(bytes);
    return decodeAuthorityIntent(alloc, bytes);
}

fn loadPublicationIntent(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !PublicationIntent {
    const bytes = try readManagedFileAlloc(
        alloc,
        dir,
        publication_intent_file,
        publication_intent_max_bytes,
        null,
    );
    defer alloc.free(bytes);
    return decodePublicationIntent(alloc, bytes);
}

fn loadManifest(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
) !session_projection.Manifest {
    const bytes = try readManagedFileAlloc(
        alloc,
        dir,
        manifest_file,
        session_projection.manifest_max_bytes,
        null,
    );
    defer alloc.free(bytes);
    return session_projection.decodeManifest(alloc, bytes);
}

const BoundarySyncContext = struct {
    test_controls: TestControls,
    boundary: Boundary,
};

fn syncDirAfterBoundary(raw: ?*anyopaque, dir: std.Io.Dir) !void {
    const context: *BoundarySyncContext = @ptrCast(@alignCast(raw.?));
    try context.test_controls.boundary(context.boundary);
    try io_mod.syncVerifiedDir(dir);
}

fn durableReplace(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    bytes: []const u8,
) !void {
    try io_mod.durableReplaceVerified(alloc, dir, name, bytes);
}

fn durableReplaceWithBoundary(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    bytes: []const u8,
    test_controls: TestControls,
    boundary: Boundary,
) !void {
    var context = BoundarySyncContext{ .test_controls = test_controls, .boundary = boundary };
    try io_mod.durableReplaceVerifiedWithOps(
        alloc,
        dir,
        name,
        bytes,
        .{ .ctx = &context, .sync_dir = syncDirAfterBoundary },
    );
}

fn deleteAndSync(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    test_controls: TestControls,
    boundary: ?Boundary,
) !void {
    try validateLeaf(name);
    dir.dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
        error.FileNotFound => {},
        error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
        else => return err,
    };
    if (boundary) |point| try test_controls.boundary(point);
    try io_mod.syncVerifiedDir(dir.dir);
}

fn createNativeSession(
    alloc: Allocator,
    writable: *WritableSessionDir,
    initial_state: session_codec.DurableSessionState,
    options: Options,
) !LoadedWritableSession {
    var synthesized_usage: ?session_usage.Snapshot = null;
    if (initial_state.usage == null) {
        var fresh_usage = session_usage.Usage.initFresh();
        defer fresh_usage.deinit(alloc);
        synthesized_usage = try fresh_usage.snapshot(alloc);
    }
    defer if (synthesized_usage) |*usage| usage.deinit(alloc);

    const generation = randomIdentifier();
    const event_id = randomIdentifier();
    const authority_id = randomIdentifier();
    const envelope = session_event.Envelope{
        .log_generation = generation,
        .seq = 1,
        .event_id = event_id,
        .timestamp_ms = initial_state.updated_at_ms,
        .event = .{ .session_started = .{
            .id = initial_state.id,
            .created_at_ms = initial_state.created_at_ms,
            .origin_workspace_root = initial_state.origin_workspace_root,
            .workspace_root = initial_state.workspace_root,
            .conversation_language = initial_state.conversation_language,
            .preferences = initial_state.preferences,
            .usage = initial_state.usage orelse synthesized_usage.?,
            .subagent_child = initial_state.subagent_child,
        } },
    };
    const line = try session_event.encodeFrame(alloc, envelope);
    defer alloc.free(line);

    {
        var lock = acquireLock(&writable.dir, commit_lock_file, true) catch |err| {
            return mapCommitLockError(err);
        };
        lock.release();
    }
    var event_log = createManagedFile(&writable.dir, events_file) catch
        return error.SessionStartFailed;
    defer event_log.close(io_mod.getIo());
    event_log.writePositionalAll(io_mod.getIo(), line, 0) catch
        return error.SessionStartFailed;
    options.test_controls.boundary(.after_event_append) catch
        return error.SessionStartFailed;
    event_log.sync(io_mod.getIo()) catch return error.SessionStartFailed;
    options.test_controls.boundary(.after_event_sync) catch
        return error.SessionStartFailed;

    const position = CommitPosition{
        .log_generation = generation,
        .through_seq = 1,
        .through_event_id = event_id,
        .through_event_log_bytes = line.len,
    };
    const watermark_bytes = try encodeWatermark(alloc, initial_state.id, position);
    defer alloc.free(watermark_bytes);
    const watermark_name = try watermarkName(alloc, generation);
    defer alloc.free(watermark_name);
    durableReplaceWithBoundary(
        alloc,
        &writable.dir,
        watermark_name,
        watermark_bytes,
        options.test_controls,
        .after_watermark_rename,
    ) catch return error.SessionStartFailed;

    options.test_controls.lock(.commit);
    var commit_lock = acquireLock(&writable.dir, commit_lock_file, true) catch |err| {
        return mapCommitLockError(err);
    };
    defer commit_lock.release();

    const intent = AuthorityIntent{
        .session_id = writable.session_id,
        .operation_id = randomIdentifier(),
        .kind = .session_create,
        .authority_id = authority_id,
        .prior = null,
        .proposed = position,
    };
    const intent_bytes = try encodeAuthorityIntent(alloc, intent);
    defer alloc.free(intent_bytes);
    if (try entryExists(&writable.dir, authority_intent_file)) {
        return error.SessionStartIndeterminate;
    }
    durableReplace(
        alloc,
        &writable.dir,
        authority_intent_file,
        intent_bytes,
    ) catch return error.SessionStartIndeterminate;
    options.test_controls.boundary(.after_authority_intent_sync) catch
        return error.SessionStartIndeterminate;

    const marker = AuthorityMarker{
        .session_id = writable.session_id,
        .authority_id = authority_id,
        .source = .native_create,
    };
    const marker_bytes = try encodeAuthority(alloc, marker);
    defer alloc.free(marker_bytes);
    durableReplaceWithBoundary(
        alloc,
        &writable.dir,
        authority_file,
        marker_bytes,
        options.test_controls,
        .after_authority_marker_rename,
    ) catch return error.SessionStartIndeterminate;
    validateAuthorityTarget(
        alloc,
        &writable.dir,
        writable.session_id,
        intent,
        options.cancel_flag,
    ) catch return error.SessionStartIndeterminate;
    options.test_controls.boundary(.after_authority_namespace_sync) catch
        return error.SessionStartIndeterminate;

    var cleanup_pending = false;
    deleteAndSync(
        &writable.dir,
        authority_intent_file,
        options.test_controls,
        .after_authority_intent_remove,
    ) catch {
        cleanup_pending = true;
    };

    var state = try initial_state.dupe(alloc);
    errdefer {
        var owned = state;
        owned.deinit(alloc);
    }
    if (state.usage == null) {
        state.usage = synthesized_usage;
        synthesized_usage = null;
    }
    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer alloc.free(active_id);
    var result = LoadedWritableSession{
        .active_id = active_id,
        .state = state,
        .log = writable.*,
        .freshly_started = true,
        .persistence_debt = .{},
        .position = position,
        .authority_id = authority_id,
        .generation_base_seq = position.through_seq,
        .generation_base_bytes = position.through_event_log_bytes,
        .projection_status = if (cleanup_pending) .stale else .current,
        .namespace_confirmation_required = cleanup_pending,
    };
    if (result.state.usage) |usage| {
        session_usage_sidecar.write(
            alloc,
            &result.log.dir,
            result.state.id,
            usage,
        ) catch |err| {
            result.usage_sidecar_reseal_pending = true;
            debug_trace.logf(
                "session",
                "event=usage_sidecar_initial_write_failed err={s}",
                .{@errorName(err)},
            );
        };
    }
    writeManifestProjection(alloc, &result) catch {
        result.projection_status = .stale;
    };
    writable.* = undefined;
    return result;
}

fn openWritableSession(
    alloc: Allocator,
    writable: *WritableSessionDir,
    options: Options,
    lifecycle: ?CommitLifecycle,
) !LoadedWritableSession {
    var lifecycle_value = lifecycle;
    errdefer if (lifecycle_value) |*value| value.deinit(alloc);
    var prepared = false;
    var loaded = opened: {
        options.test_controls.lock(.commit);
        var commit_lock = acquireLockWithDeadline(
            &writable.dir,
            commit_lock_file,
            true,
            options.commit_lock_deadline_ms,
            options.cancel_flag,
        ) catch |err| {
            return mapCommitLockError(err);
        };
        defer commit_lock.release();

        const authority_pending = try entryExists(&writable.dir, authority_intent_file);
        const publication_pending = try entryExists(&writable.dir, publication_intent_file);
        if ((authority_pending and options.resolve_authority_intent) or (!authority_pending and publication_pending)) {
            if (lifecycle_value) |*value| {
                try value.prepare(alloc, writable.session_id, options.cancel_flag);
                prepared = true;
            }
        }
        const marker = try resolveAuthorityIntent(alloc, writable, options);
        defer {
            var owned = marker;
            owned.deinit(alloc);
        }
        const position = if (publication_pending)
            try resolvePublicationIntent(alloc, writable, options)
        else
            try loadCurrentPositionReference(
                alloc,
                &writable.dir,
                writable.session_id,
                options.cancel_flag,
            );

        var event_log = try openManagedFile(&writable.dir, events_file, .read_write);
        defer event_log.close(io_mod.getIo());
        const length = try event_log.length(io_mod.getIo());
        if (length < position.through_event_log_bytes) {
            return failLoadedWritableSession(error.InvalidSessionFormat);
        }
        const replay_started_ns = io_mod.nanoTimestamp();
        var open_state = loadOpenState(
            alloc,
            &writable.dir,
            writable.session_id,
            marker.authority_id,
            event_log,
            position,
            options.cancel_flag,
        ) catch |err| switch (err) {
            error.OutOfMemory => return failLoadedWritableSession(error.SessionReplayResourceExhausted),
            else => return err,
        };
        errdefer open_state.state.deinit(alloc);
        const usage_sidecar_reseal_pending = try restoreUsageSidecar(
            alloc,
            &writable.dir,
            &open_state.state,
        );
        const replay_finished_ns = io_mod.nanoTimestamp();
        debug_trace.logf(
            "session",
            "event=session_replay source={s} checkpoint_seq={?d} tail_bytes={d} elapsed_us={d}",
            .{
                @tagName(open_state.source),
                open_state.checkpoint_seq,
                open_state.tail_bytes,
                @divTrunc(replay_finished_ns - replay_started_ns, std.time.ns_per_us),
            },
        );
        if (length > position.through_event_log_bytes) {
            if (!prepared) {
                if (lifecycle_value) |*value| {
                    try value.prepare(alloc, writable.session_id, options.cancel_flag);
                    prepared = true;
                }
            }
            try rollbackPublicationToPrior(writable, alloc, event_log, position, options);
        }
        const active_id = try alloc.dupe(u8, writable.session_id);
        errdefer alloc.free(active_id);

        const result = LoadedWritableSession{
            .active_id = active_id,
            .state = open_state.state,
            .log = writable.*,
            .position = position,
            .authority_id = marker.authority_id,
            .generation_base_seq = open_state.generation_base_seq,
            .generation_base_bytes = open_state.generation_base_bytes,
            .checkpoint_seq = open_state.checkpoint_seq,
            .checkpoint_sha256 = open_state.checkpoint_sha256,
            .projection_status = open_state.projection_status,
            .usage_sidecar_reseal_pending = usage_sidecar_reseal_pending,
        };
        open_state.state = undefined;
        break :opened result;
    };
    loaded.commit_lifecycle = lifecycle_value;
    lifecycle_value = null;
    writable.* = undefined;
    if (prepared) loaded.persistence_debt.derived_publication = !loaded.publishCommitLifecycle(alloc, options.cancel_flag);
    return loaded;
}

fn restoreUsageSidecar(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    state: *session_codec.DurableSessionState,
) !bool {
    if (state.usage) |*usage| {
        const outcome = try session_usage_sidecar.restoreIfMatching(
            alloc,
            dir,
            state.id,
            state.updated_at_ms,
            usage,
        );
        return outcome != .restored;
    }
    return false;
}

fn encodeUsageSidecarBestEffort(
    alloc: Allocator,
    session_id: []const u8,
    usage: session_usage.Snapshot,
) ?[]u8 {
    return session_usage_sidecar.encode(
        alloc,
        session_id,
        usage,
    ) catch |err| {
        traceUsageSidecarWriteFailure(err);
        return null;
    };
}

fn writeEncodedUsageSidecarBestEffort(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    encoded: []const u8,
) bool {
    session_usage_sidecar.writeEncoded(
        alloc,
        &loaded.log.dir,
        encoded,
    ) catch |err| {
        traceUsageSidecarWriteFailure(err);
        return false;
    };
    return true;
}

fn restoreEncodedUsageSidecarBestEffort(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    encoded: []const u8,
) void {
    if (loaded.state.usage) |*usage| {
        _ = session_usage_sidecar.restoreCaptured(
            alloc,
            .{ .encoded = @constCast(encoded) },
            loaded.state.id,
            loaded.state.updated_at_ms,
            usage,
        ) catch |err| {
            debug_trace.logf(
                "session",
                "event=usage_sidecar_memory_restore_failed err={s}",
                .{@errorName(err)},
            );
        };
    }
}

fn traceUsageSidecarWriteFailure(err: anyerror) void {
    debug_trace.logf(
        "session",
        "event=usage_sidecar_write_failed err={s}",
        .{@errorName(err)},
    );
}

fn loadOpenState(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    authority_id: Identifier,
    event_log: std.Io.File,
    position: CommitPosition,
    cancel_flag: session_read.CancelFlag,
) !OpenState {
    var manifest: ?OpenManifest = loadCurrentManifestForOpen(
        alloc,
        dir,
        session_id,
        authority_id,
        event_log,
        position,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            debug_trace.logf(
                "session",
                "event=session_replay_checkpoint_fallback reason={s}",
                .{@errorName(err)},
            );
            break :blk null;
        },
    };
    defer if (manifest) |*value| value.manifest.deinit(alloc);

    var checkpoint_failed = false;
    if (manifest) |candidate| {
        const value = candidate.manifest;
        if (!candidate.event_file_matches) {
            checkpoint_failed = true;
            debug_trace.logf(
                "session",
                "event=session_replay_checkpoint_fallback reason=StaleEventFileFingerprint",
                .{},
            );
        }
        if (candidate.event_file_matches and value.checkpoint_seq != null) {
            if (replayCurrentCheckpoint(
                alloc,
                dir,
                event_log,
                value,
                position,
                cancel_flag,
            )) |replayed| {
                return .{
                    .state = replayed.state,
                    .generation_base_seq = value.generation_base_seq,
                    .generation_base_bytes = value.generation_base_bytes,
                    .checkpoint_seq = value.checkpoint_seq,
                    .checkpoint_sha256 = value.checkpoint_sha256,
                    .projection_status = .current,
                    .source = .checkpoint,
                    .tail_bytes = position.through_event_log_bytes -
                        replayed.through_event_log_bytes,
                };
            } else |err| switch (err) {
                error.Cancelled, error.OutOfMemory => return err,
                else => {
                    checkpoint_failed = true;
                    debug_trace.logf(
                        "session",
                        "event=session_replay_checkpoint_fallback reason={s}",
                        .{@errorName(err)},
                    );
                },
            }
        }
    }

    var state = try session_replay.replayBoundary(alloc, event_log, position, cancel_flag);
    errdefer state.deinit(alloc);
    if (manifest) |candidate| {
        const value = candidate.manifest;
        if (session_projection.stateMatchesManifest(state, value)) {
            return .{
                .state = state,
                .generation_base_seq = value.generation_base_seq,
                .generation_base_bytes = value.generation_base_bytes,
                .checkpoint_seq = if (checkpoint_failed) null else value.checkpoint_seq,
                .checkpoint_sha256 = if (checkpoint_failed) null else value.checkpoint_sha256,
                .projection_status = if (checkpoint_failed) .stale else .current,
                .source = .event_log,
                .tail_bytes = position.through_event_log_bytes,
            };
        }
        debug_trace.logf(
            "session",
            "event=session_replay_checkpoint_fallback reason=ManifestStateMismatch",
            .{},
        );
    }
    return .{
        .state = state,
        .generation_base_seq = position.through_seq,
        .generation_base_bytes = position.through_event_log_bytes,
        .checkpoint_seq = null,
        .checkpoint_sha256 = null,
        .projection_status = .stale,
        .source = .event_log,
        .tail_bytes = position.through_event_log_bytes,
    };
}

fn loadCurrentManifestForOpen(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    authority_id: Identifier,
    event_log: std.Io.File,
    position: CommitPosition,
) !OpenManifest {
    var manifest = try loadManifest(alloc, dir);
    errdefer manifest.deinit(alloc);
    if (!std.mem.eql(u8, manifest.id, session_id) or
        !std.mem.eql(u8, &manifest.authority_id, &authority_id) or
        !std.mem.eql(u8, &manifest.log_generation, &position.log_generation) or
        manifest.last_event_seq != position.through_seq or
        manifest.event_log_bytes != position.through_event_log_bytes)
    {
        return error.StaleManifest;
    }
    const length = try event_log.length(io_mod.getIo());
    if (length > position.through_event_log_bytes) {
        return .{
            .manifest = manifest,
            .event_file_matches = false,
        };
    }
    const stat = try eventStat(event_log, position.through_event_log_bytes);
    return .{
        .manifest = manifest,
        .event_file_matches = !session_projection.isManifestStale(manifest, stat),
    };
}

fn replayCurrentCheckpoint(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    event_log: std.Io.File,
    manifest: session_projection.Manifest,
    position: CommitPosition,
    cancel_flag: session_read.CancelFlag,
) !CheckpointReplay {
    const bytes = try readManagedFileAlloc(
        alloc,
        dir,
        checkpoint_file,
        session_projection.checkpoint_max_bytes,
        cancel_flag,
    );
    defer alloc.free(bytes);
    var checkpoint = try session_projection.decodeCheckpoint(alloc, bytes, cancel_flag);
    var checkpoint_owns_state = true;
    defer {
        alloc.free(checkpoint.session_id);
        if (checkpoint_owns_state) checkpoint.state.deinit(alloc);
    }
    const checkpoint_position = CommitPosition{
        .log_generation = checkpoint.log_generation,
        .through_seq = checkpoint.through_seq,
        .through_event_id = checkpoint.through_event_id,
        .through_event_log_bytes = checkpoint.through_event_log_bytes,
    };
    try session_projection.validateCheckpointReference(
        manifest,
        bytes,
        checkpoint,
        projectionBoundary(position),
        projectionBoundary(checkpoint_position),
        cancel_flag,
    );
    const checkpoint_state = checkpoint.state;
    checkpoint_owns_state = false;
    var state = try session_replay.replayFromCheckpoint(
        alloc,
        event_log,
        checkpoint_position,
        checkpoint_state,
        position,
        cancel_flag,
    );
    errdefer state.deinit(alloc);
    if (!session_projection.stateMatchesManifest(state, manifest)) {
        return error.StaleCheckpoint;
    }
    return .{
        .state = state,
        .through_event_log_bytes = checkpoint_position.through_event_log_bytes,
    };
}

fn projectionBoundary(position: CommitPosition) session_projection.EventBoundary {
    return .{
        .log_generation = position.log_generation,
        .seq = position.through_seq,
        .event_id = position.through_event_id,
        .event_log_bytes = position.through_event_log_bytes,
        .semantic = true,
    };
}

fn mapCommitLockError(err: anyerror) anyerror {
    return switch (err) {
        error.LockBusy, error.LockUnsupported => error.SessionCommitBoundaryUnavailable,
        else => err,
    };
}

fn resolveAuthorityIntent(
    alloc: Allocator,
    writable: *WritableSessionDir,
    options: Options,
) !AuthorityMarker {
    if (!try entryExists(&writable.dir, authority_intent_file)) {
        return loadAuthority(alloc, &writable.dir, writable.session_id);
    }
    if (!options.resolve_authority_intent) {
        return error.SessionAuthorityBoundaryUnavailable;
    }
    var intent = try loadAuthorityIntent(alloc, &writable.dir);
    defer intent.deinit(alloc);
    if (!std.mem.eql(u8, intent.session_id, writable.session_id)) {
        return error.InvalidSessionFormat;
    }
    if (intent.kind != .session_create) return error.InvalidSessionFormat;

    if (!try entryExists(&writable.dir, authority_file)) {
        try io_mod.syncVerifiedDir(writable.dir.dir);
        if (try entryExists(&writable.dir, authority_file)) {
            return error.SessionStartIndeterminate;
        }
        try deleteAndSync(
            &writable.dir,
            authority_intent_file,
            options.test_controls,
            null,
        );
        return error.SessionNotFound;
    }
    try validateAuthorityTarget(
        alloc,
        &writable.dir,
        writable.session_id,
        intent,
        options.cancel_flag,
    );
    var marker = try loadAuthority(alloc, &writable.dir, writable.session_id);
    errdefer marker.deinit(alloc);
    try deleteAndSync(
        &writable.dir,
        authority_intent_file,
        options.test_controls,
        null,
    );
    return marker;
}

fn validateAuthorityTarget(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    intent: AuthorityIntent,
    cancel_flag: session_read.CancelFlag,
) !void {
    var marker = try loadAuthority(alloc, dir, session_id);
    defer marker.deinit(alloc);
    const expected_source: AuthoritySource = switch (intent.kind) {
        .session_create => .native_create,
        .legacy_to_v3 => .legacy_migration,
    };
    if (!std.mem.eql(u8, marker.session_id, intent.session_id) or
        !std.mem.eql(u8, &marker.authority_id, &intent.authority_id) or
        marker.source != expected_source)
    {
        return error.InvalidSessionFormat;
    }
    _ = try validateLivePosition(alloc, dir, session_id, intent.proposed, cancel_flag);
    try io_mod.syncVerifiedDir(dir.dir);
}

fn resolvePublicationIntent(
    alloc: Allocator,
    writable: *WritableSessionDir,
    options: Options,
) !CommitPosition {
    if (!try entryExists(&writable.dir, publication_intent_file)) {
        return loadCurrentPosition(alloc, &writable.dir, writable.session_id, options.cancel_flag);
    }
    var intent = try loadPublicationIntent(alloc, &writable.dir);
    defer intent.deinit(alloc);
    if (!std.mem.eql(u8, intent.session_id, writable.session_id)) {
        return error.InvalidSessionFormat;
    }
    const current_generation = try liveGeneration(alloc, &writable.dir, options.cancel_flag);
    var chosen: CommitPosition = undefined;
    if (intent.kind == .watermark_advance) {
        if (!std.mem.eql(u8, &current_generation, &intent.prior.log_generation) or
            !std.mem.eql(u8, &current_generation, &intent.proposed.log_generation))
        {
            return error.SessionCommitIndeterminate;
        }
        var log = try openManagedFile(&writable.dir, events_file, .read_write);
        defer log.close(io_mod.getIo());
        const current = try loadWatermarkPosition(
            alloc,
            &writable.dir,
            writable.session_id,
            current_generation,
        );
        if (positionsEqual(current, intent.proposed)) {
            try options.test_controls.boundary(.before_recovery_proposed_validation);
            switch (try session_replay.validateCommitPositionForRecovery(
                alloc,
                log,
                intent.proposed,
                options.cancel_flag,
            )) {
                .valid => chosen = intent.proposed,
                .invalid => {
                    try options.test_controls.boundary(.before_recovery_prior_validation);
                    try requireValidRecoveryPosition(
                        alloc,
                        log,
                        intent.prior,
                        options.cancel_flag,
                    );
                    debug_trace.logf(
                        "session",
                        "event=publication_recovery_rollback reason=invalid_proposed proposed_seq={d} proposed_bytes={d} prior_seq={d} prior_bytes={d}",
                        .{
                            intent.proposed.through_seq,
                            intent.proposed.through_event_log_bytes,
                            intent.prior.through_seq,
                            intent.prior.through_event_log_bytes,
                        },
                    );
                    try rollbackPublicationToPrior(
                        writable,
                        alloc,
                        log,
                        intent.prior,
                        options,
                    );
                    return intent.prior;
                },
            }
        } else if (positionsEqual(current, intent.prior)) {
            chosen = intent.prior;
            try options.test_controls.boundary(.before_recovery_prior_validation);
            try requireValidRecoveryPosition(
                alloc,
                log,
                intent.prior,
                options.cancel_flag,
            );
            const length = try log.length(io_mod.getIo());
            if (length < intent.prior.through_event_log_bytes) {
                return error.InvalidSessionFormat;
            }
            if (length > intent.prior.through_event_log_bytes) {
                try rollbackPublicationToPrior(writable, alloc, log, intent.prior, options);
                return intent.prior;
            }
        } else {
            return error.SessionCommitIndeterminate;
        }
    } else if (std.mem.eql(u8, &current_generation, &intent.proposed.log_generation)) {
        chosen = intent.proposed;
        _ = try validateLivePosition(
            alloc,
            &writable.dir,
            writable.session_id,
            chosen,
            options.cancel_flag,
        );
    } else if (std.mem.eql(u8, &current_generation, &intent.prior.log_generation)) {
        chosen = intent.prior;
        var log = try openManagedFile(&writable.dir, events_file, .read_write);
        defer log.close(io_mod.getIo());
        const current_position = loadAndValidateWatermark(
            alloc,
            &writable.dir,
            writable.session_id,
            current_generation,
            log,
            options.cancel_flag,
        ) catch |err| switch (err) {
            error.Cancelled => return err,
            else => null,
        };
        if (current_position == null or
            !positionsEqual(current_position.?, intent.prior))
        {
            return error.SessionCommitIndeterminate;
        }
        const length = try log.length(io_mod.getIo());
        if (length < intent.prior.through_event_log_bytes) {
            return error.InvalidSessionFormat;
        }
        if (length > intent.prior.through_event_log_bytes) {
            try rollbackPublicationToPrior(writable, alloc, log, intent.prior, options);
            return intent.prior;
        }
        _ = try validateCommitPosition(
            alloc,
            &writable.dir,
            writable.session_id,
            chosen,
            options.cancel_flag,
        );
    } else {
        return error.SessionCommitIndeterminate;
    }
    try io_mod.syncVerifiedDir(writable.dir.dir);
    try deleteAndSync(
        &writable.dir,
        publication_intent_file,
        options.test_controls,
        null,
    );
    return chosen;
}

fn requireValidRecoveryPosition(
    alloc: Allocator,
    log: std.Io.File,
    position: CommitPosition,
    cancel_flag: session_read.CancelFlag,
) !void {
    switch (try session_replay.validateCommitPositionForRecovery(alloc, log, position, cancel_flag)) {
        .valid => {},
        .invalid => return error.InvalidSessionFormat,
    }
}

fn positionsEqual(lhs: CommitPosition, rhs: CommitPosition) bool {
    return std.mem.eql(u8, &lhs.log_generation, &rhs.log_generation) and
        lhs.through_seq == rhs.through_seq and
        std.mem.eql(u8, &lhs.through_event_id, &rhs.through_event_id) and
        lhs.through_event_log_bytes == rhs.through_event_log_bytes;
}

fn liveGeneration(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    cancel_flag: session_read.CancelFlag,
) !Identifier {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    return session_replay.readFirstGeneration(alloc, log, cancel_flag);
}

fn loadCurrentPosition(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    cancel_flag: session_read.CancelFlag,
) !CommitPosition {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, log, cancel_flag);
    return loadAndValidateWatermark(
        alloc,
        dir,
        session_id,
        generation,
        log,
        cancel_flag,
    );
}

fn loadCurrentPositionReference(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    cancel_flag: session_read.CancelFlag,
) !CommitPosition {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, log, cancel_flag);
    return loadWatermarkPosition(alloc, dir, session_id, generation);
}

fn validateLivePosition(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    expected: CommitPosition,
    cancel_flag: session_read.CancelFlag,
) !session_projection.EventBoundary {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, log, cancel_flag);
    if (!std.mem.eql(u8, &generation, &expected.log_generation)) {
        return error.InvalidSessionFormat;
    }
    const actual = try loadAndValidateWatermark(
        alloc,
        dir,
        session_id,
        generation,
        log,
        cancel_flag,
    );
    if (!positionsEqual(actual, expected)) return error.InvalidSessionFormat;
    return validateCommitPosition(alloc, dir, session_id, expected, cancel_flag);
}

fn loadAndValidateWatermark(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    generation: Identifier,
    event_log: std.Io.File,
    cancel_flag: session_read.CancelFlag,
) !CommitPosition {
    const position = try loadWatermarkPosition(alloc, dir, session_id, generation);
    _ = try session_replay.scanCommitPosition(alloc, event_log, position, cancel_flag);
    return position;
}

fn loadWatermarkPosition(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    generation: Identifier,
) !CommitPosition {
    const name = try watermarkName(alloc, generation);
    defer alloc.free(name);
    const bytes = try readManagedFileAlloc(
        alloc,
        dir,
        name,
        watermark_max_bytes,
        null,
    );
    defer alloc.free(bytes);
    return decodeWatermark(alloc, bytes, session_id, generation);
}

fn validateCommitPosition(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    position: CommitPosition,
    cancel_flag: session_read.CancelFlag,
) !session_projection.EventBoundary {
    var log = try openManagedFile(dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const generation = try session_replay.readFirstGeneration(alloc, log, cancel_flag);
    if (!std.mem.eql(u8, &generation, &position.log_generation)) {
        return error.InvalidSessionFormat;
    }
    const watermark = try loadAndValidateWatermark(
        alloc,
        dir,
        session_id,
        generation,
        log,
        cancel_flag,
    );
    if (!positionsEqual(position, watermark)) return error.InvalidSessionFormat;
    return session_replay.scanCommitPosition(alloc, log, position, cancel_flag);
}

fn appendEventImpl(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    event: session_event.Event,
    timestamp_ms: i64,
    failed_tail: FailedTailDisposition,
    options: Options,
    usage_sidecar_bytes: ?[]const u8,
    write_usage_sidecar: bool,
) !CommitPosition {
    try prepareCanonicalWrite(loaded, alloc, options);
    const envelope = session_event.Envelope{
        .log_generation = loaded.position.log_generation,
        .seq = std.math.add(u64, loaded.position.through_seq, 1) catch
            return error.InvalidSessionFormat,
        .event_id = randomIdentifier(),
        .timestamp_ms = timestamp_ms,
        .event = event,
    };
    const frame = try session_event.encodeFrameCancellable(alloc, envelope, options.cancel_flag);
    var prepared = try prepareFailedTail(
        loaded,
        alloc,
        frame,
        envelope.seq,
        envelope.event_id,
        .{ .event = envelope.event_id },
        options.cancel_flag,
    );
    return publishPreparedTail(
        loaded,
        alloc,
        &prepared,
        failed_tail,
        options,
        usage_sidecar_bytes,
        write_usage_sidecar,
    );
}

const IdSequence = struct {
    next_value: u128,

    fn next(raw: *anyopaque) Identifier {
        const self: *IdSequence = @ptrCast(@alignCast(raw));
        self.next_value +%= 1;
        var bytes: Identifier = undefined;
        std.mem.writeInt(u128, &bytes, self.next_value, .big);
        return bytes;
    }

    fn source(self: *IdSequence) session_event.IdentifierSource {
        return .{ .context = self, .next_fn = next };
    }
};

fn commitStateReplacementImpl(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    state: session_codec.DurableSessionState,
    reason: session_event.ReplacementReason,
    failed_tail: FailedTailDisposition,
    options: Options,
    usage_sidecar_bytes: ?[]const u8,
    write_usage_sidecar: bool,
) !CommitPosition {
    try prepareCanonicalWrite(loaded, alloc, options);
    const timestamp_ms = state.updated_at_ms;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var ids = IdSequence{ .next_value = randomSequenceSeed() };
    const replacement_id = randomIdentifier();
    const summary = try session_event.writeStateReplacement(
        alloc,
        &out.writer,
        state,
        .{
            .log_generation = loaded.position.log_generation,
            .first_seq = loaded.position.through_seq + 1,
            .replacement_id = replacement_id,
            .event_ids = ids.source(),
            .timestamp_ms = timestamp_ms,
            .reason = reason,
            .cancel_flag = options.cancel_flag,
        },
    );
    const frames = try out.toOwnedSlice();
    var prepared = try prepareFailedTail(
        loaded,
        alloc,
        frames,
        summary.last_seq,
        summary.last_event_id,
        .{ .state_replacement = .{
            .replacement_id = replacement_id,
            .final_event_id = summary.last_event_id,
        } },
        options.cancel_flag,
    );
    return publishPreparedTail(
        loaded,
        alloc,
        &prepared,
        failed_tail,
        options,
        usage_sidecar_bytes,
        write_usage_sidecar,
    );
}

fn prepareCanonicalWrite(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    options: Options,
) !void {
    if (loaded.degraded_tail != null) return error.SessionPersistenceDegraded;
    try confirmWritableNamespace(loaded, alloc, options);
}

fn prepareFailedTail(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    frames: []u8,
    last_seq: u64,
    last_event_id: Identifier,
    kind: FailedTailKind,
    cancel_flag: session_read.CancelFlag,
) !FailedTail {
    errdefer alloc.free(frames);
    const prior = loaded.position;
    return .{
        .prior = prior,
        .proposed = .{
            .log_generation = prior.log_generation,
            .through_seq = last_seq,
            .through_event_id = last_event_id,
            .through_event_log_bytes = std.math.add(
                u64,
                prior.through_event_log_bytes,
                frames.len,
            ) catch return error.InvalidSessionFormat,
        },
        .kind = kind,
        .bytes = frames,
        .sha256 = try session_read.sha256(frames, cancel_flag),
    };
}

fn publishPreparedTail(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    prepared: *FailedTail,
    failed_tail: FailedTailDisposition,
    options: Options,
    usage_sidecar_bytes: ?[]const u8,
    write_usage_sidecar: bool,
) !CommitPosition {
    const result = publishFrames(
        loaded,
        alloc,
        prepared,
        failed_tail,
        options,
        usage_sidecar_bytes,
        write_usage_sidecar,
    ) catch |err| {
        if (failed_tail == .retry_expected_tail and
            (err == error.SessionPersistenceDegraded or
                err == error.SessionCommitIndeterminate))
        {
            if (loaded.degraded_tail) |*existing| existing.deinit(alloc);
            loaded.degraded_tail = prepared.*;
            prepared.* = undefined;
        } else {
            prepared.deinit(alloc);
        }
        return err;
    };
    loaded.persistence_debt.canonical_replacement = switch (prepared.kind) {
        .event => true,
        .state_replacement => false,
    };
    prepared.deinit(alloc);
    return result;
}

fn publishFrames(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    prepared: *const FailedTail,
    failed_tail: FailedTailDisposition,
    options: Options,
    usage_sidecar_bytes: ?[]const u8,
    write_usage_sidecar: bool,
) !CommitPosition {
    const prior = prepared.prior;
    const proposed = prepared.proposed;
    const frames = prepared.bytes;
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
    defer log.close(io_mod.getIo());
    const current_length = try log.length(io_mod.getIo());
    var reused_tail = false;
    if (current_length == proposed.through_event_log_bytes) {
        reused_tail = try fileBytesMatch(io_mod.getIo(), log, prior.through_event_log_bytes, frames, options.cancel_flag);
    }
    if (current_length < prior.through_event_log_bytes) {
        loaded.persistence_debt.canonical_replacement = true;
        return error.InvalidSessionFormat;
    }
    try session_read.check(options.cancel_flag);
    loaded.persistence_debt.canonical_replacement = true;
    if (!reused_tail) {
        if (current_length > prior.through_event_log_bytes) {
            try log.setLength(io_mod.getIo(), prior.through_event_log_bytes);
            try log.sync(io_mod.getIo());
        }
        session_read.writeFileBytes(
            io_mod.getIo(),
            log,
            prior.through_event_log_bytes,
            frames,
            options.cancel_flag,
        ) catch return handlePreIntentFailure(log, prior, failed_tail);
    }
    options.test_controls.boundary(.after_event_append) catch
        return handlePreIntentFailure(log, prior, failed_tail);
    log.sync(io_mod.getIo()) catch
        return handlePreIntentFailure(log, prior, failed_tail);
    options.test_controls.boundary(.after_event_sync) catch
        return handlePreIntentFailure(log, prior, failed_tail);

    options.test_controls.lock(.commit);
    var commit_lock = acquireLockWithDeadline(
        &loaded.log.dir,
        commit_lock_file,
        true,
        options.commit_lock_deadline_ms,
        options.cancel_flag,
    ) catch |err| return switch (failed_tail) {
        .rollback_before_adapter_continue => blk: {
            rollbackTail(log, prior) catch return error.SessionCommitIndeterminate;
            break :blk mapCommitLockError(err);
        },
        .retry_expected_tail => error.SessionPersistenceDegraded,
    };
    defer commit_lock.release();

    const current = loadCurrentPositionReference(
        alloc,
        &loaded.log.dir,
        loaded.log.session_id,
        options.cancel_flag,
    ) catch |err| return handleIntentFailure(
        loaded,
        alloc,
        log,
        prior,
        failed_tail,
        err,
        options,
    );
    if (!positionsEqual(current, prior) or
        try entryExists(&loaded.log.dir, publication_intent_file))
    {
        return handleIntentFailure(
            loaded,
            alloc,
            log,
            prior,
            failed_tail,
            error.SessionCommitIndeterminate,
            options,
        );
    }
    const intent = PublicationIntent{
        .session_id = loaded.log.session_id,
        .operation_id = randomIdentifier(),
        .kind = .watermark_advance,
        .prior = prior,
        .proposed = proposed,
    };
    const intent_bytes = try encodePublicationIntent(alloc, intent);
    defer alloc.free(intent_bytes);
    const watermark_bytes = try encodeWatermark(
        alloc,
        loaded.log.session_id,
        proposed,
    );
    defer alloc.free(watermark_bytes);
    const name = try watermarkName(alloc, proposed.log_generation);
    defer alloc.free(name);
    durableReplace(
        alloc,
        &loaded.log.dir,
        publication_intent_file,
        intent_bytes,
    ) catch |err| return handleIntentFailure(
        loaded,
        alloc,
        log,
        prior,
        failed_tail,
        err,
        options,
    );
    loaded.namespace_confirmation_required = true;
    options.test_controls.boundary(.after_commit_intent_sync) catch |err|
        return handleIntentFailure(
            loaded,
            alloc,
            log,
            prior,
            failed_tail,
            err,
            options,
        );

    durableReplaceWithBoundary(
        alloc,
        &loaded.log.dir,
        name,
        watermark_bytes,
        options.test_controls,
        .after_watermark_rename,
    ) catch |err| return handlePublishedTailFailure(
        loaded,
        alloc,
        log,
        prior,
        failed_tail,
        err,
        options,
    );
    switch (prepared.kind) {
        .event => {
            const published = loadCurrentPositionReference(
                alloc,
                &loaded.log.dir,
                loaded.log.session_id,
                options.cancel_flag,
            ) catch |err| return handlePublishedTailFailure(
                loaded,
                alloc,
                log,
                prior,
                failed_tail,
                err,
                options,
            );
            const exact_tail = expectedTailMatches(
                loaded,
                prepared.*,
                options.cancel_flag,
            ) catch |err| return handlePublishedTailFailure(
                loaded,
                alloc,
                log,
                prior,
                failed_tail,
                err,
                options,
            );
            if (!positionsEqual(published, proposed) or !exact_tail) {
                return handlePublishedTailFailure(
                    loaded,
                    alloc,
                    log,
                    prior,
                    failed_tail,
                    error.SessionCommitIndeterminate,
                    options,
                );
            }
        },
        .state_replacement => {
            _ = validateLivePosition(
                alloc,
                &loaded.log.dir,
                loaded.log.session_id,
                proposed,
                options.cancel_flag,
            ) catch |err| return handlePublishedTailFailure(
                loaded,
                alloc,
                log,
                prior,
                failed_tail,
                err,
                options,
            );
        },
    }
    options.test_controls.boundary(.after_target_namespace_sync) catch
        return error.SessionCommitIndeterminate;

    var replayed_state: ?session_codec.DurableSessionState = null;
    switch (prepared.kind) {
        .event => |event_id| {
            _ = session_event.applyEventFrame(
                alloc,
                &loaded.state,
                frames,
                .{
                    .generation = prior.log_generation,
                    .next_seq = std.math.add(u64, prior.through_seq, 1) catch
                        return handlePublishedTailFailure(
                            loaded,
                            alloc,
                            log,
                            prior,
                            failed_tail,
                            error.InvalidSessionFormat,
                            options,
                        ),
                    .cancel_flag = options.cancel_flag,
                },
                event_id,
            ) catch |err| return handlePublishedTailFailure(
                loaded,
                alloc,
                log,
                prior,
                failed_tail,
                err,
                options,
            );
        },
        .state_replacement => {
            replayed_state = session_replay.replayBoundary(
                alloc,
                log,
                proposed,
                options.cancel_flag,
            ) catch |err| return handlePublishedTailFailure(
                loaded,
                alloc,
                log,
                prior,
                failed_tail,
                err,
                options,
            );
        },
    }

    var cleanup_pending = false;
    deleteAndSync(
        &loaded.log.dir,
        publication_intent_file,
        options.test_controls,
        .after_commit_intent_remove,
    ) catch {
        cleanup_pending = true;
    };
    loaded.position = proposed;
    if (replayed_state) |next_state| {
        loaded.state.deinit(alloc);
        loaded.state = next_state;
    }
    if (usage_sidecar_bytes) |bytes| {
        if (write_usage_sidecar) {
            options.test_controls.boundary(.before_usage_sidecar_write) catch |err| {
                debug_trace.logf(
                    "session",
                    "event=usage_sidecar_test_boundary_failed err={s}",
                    .{@errorName(err)},
                );
            };
            loaded.usage_sidecar_reseal_pending =
                !writeEncodedUsageSidecarBestEffort(loaded, alloc, bytes);
        }
        restoreEncodedUsageSidecarBestEffort(loaded, alloc, bytes);
    } else if (write_usage_sidecar) {
        loaded.usage_sidecar_reseal_pending = true;
    }
    refreshProjections(alloc, loaded, options) catch {
        loaded.projection_status = .stale;
    };
    if (cleanup_pending) {
        loaded.projection_status = .stale;
    } else {
        loaded.namespace_confirmation_required = false;
    }
    return proposed;
}

fn retryDegradedWithStateReplacementImpl(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    current_state: session_codec.DurableSessionState,
    options: Options,
) !void {
    var failed = loaded.degraded_tail orelse return;
    loaded.degraded_tail = null;
    var owns_failed = true;
    defer if (owns_failed) failed.deinit(alloc);
    errdefer loaded.abortCommitLifecycle();
    errdefer if (owns_failed) {
        loaded.degraded_tail = failed;
        owns_failed = false;
    };
    try confirmWritableNamespace(loaded, alloc, options);

    if (positionsEqual(loaded.position, failed.proposed)) {
        if (!try expectedTailMatches(loaded, failed, options.cancel_flag)) return error.SessionCommitIndeterminate;
        if (try durableStatesRichEqual(loaded.state, current_state, options.cancel_flag)) {
            loaded.persistence_debt.canonical_replacement = false;
            loaded.persistence_debt.derived_publication = !loaded.publishCommitLifecycle(alloc, options.cancel_flag);
            return;
        }

        failed.deinit(alloc);
        owns_failed = false;
        _ = try loaded.commitStateReplacement(
            alloc,
            current_state,
            .recovery,
            .retry_expected_tail,
            options,
        );
        return;
    }

    if (!positionsEqual(loaded.position, failed.prior)) {
        return error.SessionCommitIndeterminate;
    }

    const exact = try expectedTailMatches(loaded, failed, options.cancel_flag);
    if (exact) {
        const usage_sidecar_bytes = if (current_state.usage) |usage|
            encodeUsageSidecarBestEffort(
                alloc,
                current_state.id,
                usage,
            )
        else
            null;
        defer if (usage_sidecar_bytes) |bytes| alloc.free(bytes);
        try loaded.prepareCommitLifecycle(alloc, options.cancel_flag);
        owns_failed = false;
        _ = publishPreparedTail(
            loaded,
            alloc,
            &failed,
            .retry_expected_tail,
            options,
            usage_sidecar_bytes,
            true,
        ) catch |err| {
            loaded.abortCommitLifecycle();
            return err;
        };
        try maintainCanonicalLogAfterCommit(loaded, alloc, options);
        if (try durableStatesEqualCancellable(loaded.state, current_state, options.cancel_flag)) {
            loaded.persistence_debt.canonical_replacement = false;
            loaded.persistence_debt.derived_publication = !loaded.publishCommitLifecycle(alloc, options.cancel_flag);
            return;
        }
        _ = try loaded.commitStateReplacement(
            alloc,
            current_state,
            .recovery,
            .retry_expected_tail,
            options,
        );
        return;
    }

    var log = try openManagedFile(
        &loaded.log.dir,
        events_file,
        .read_write,
    );
    defer log.close(io_mod.getIo());
    const length = try log.length(io_mod.getIo());
    if (length < failed.prior.through_event_log_bytes) {
        return error.SessionCommitIndeterminate;
    }
    try loaded.prepareCommitLifecycle(alloc, options.cancel_flag);
    try rollbackPublicationToPrior(&loaded.log, alloc, log, failed.prior, options);

    failed.deinit(alloc);
    owns_failed = false;
    _ = try loaded.commitStateReplacement(
        alloc,
        current_state,
        .recovery,
        .retry_expected_tail,
        options,
    );
}

fn expectedTailMatches(
    loaded: *LoadedWritableSession,
    failed: FailedTail,
    cancel_flag: session_read.CancelFlag,
) !bool {
    if (!positionsEqual(loaded.position, failed.prior) and
        !positionsEqual(loaded.position, failed.proposed))
    {
        return false;
    }
    if (!std.mem.eql(
        u8,
        &failed.proposed.log_generation,
        &failed.prior.log_generation,
    ) or
        failed.proposed.through_event_log_bytes !=
            failed.prior.through_event_log_bytes + failed.bytes.len or
        !std.mem.eql(
            u8,
            &try session_read.sha256(failed.bytes, cancel_flag),
            &failed.sha256,
        ))
    {
        return false;
    }
    switch (failed.kind) {
        .event => |event_id| {
            if (!std.mem.eql(
                u8,
                &event_id,
                &failed.proposed.through_event_id,
            )) return false;
        },
        .state_replacement => |replacement| {
            if (!std.mem.eql(
                u8,
                &replacement.final_event_id,
                &failed.proposed.through_event_id,
            )) return false;
        },
    }

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const length = try log.length(io_mod.getIo());
    if (length != failed.proposed.through_event_log_bytes) return false;
    return fileBytesMatch(io_mod.getIo(), log, failed.prior.through_event_log_bytes, failed.bytes, cancel_flag);
}

fn fileBytesMatch(io: std.Io, file: std.Io.File, offset: u64, expected: []const u8, cancel_flag: session_read.CancelFlag) !bool {
    var buffer: [session_read.work_bytes]u8 = undefined;
    var consumed: usize = 0;
    while (consumed < expected.len) {
        try session_read.check(cancel_flag);
        const end = consumed + @min(buffer.len, expected.len - consumed);
        const chunk = buffer[0 .. end - consumed];
        const position = std.math.add(u64, offset, consumed) catch return error.InvalidSessionFormat;
        if (try file.readPositionalAll(io, chunk, position) != chunk.len) return false;
        try session_read.check(cancel_flag);
        if (!std.mem.eql(u8, chunk, expected[consumed..end])) return false;
        consumed = end;
    }
    return true;
}

test "tail comparison cancellation after a real positional read leaves files unchanged" {
    const Observer = struct {
        var active: *@This() = undefined;
        entered: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
        cancel_flag: std.atomic.Value(bool) = .init(false),
        requested_at: i128 = 0,

        fn read(ctx: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
            const count = try std.testing.io.vtable.fileReadPositional(ctx, file, data, offset);
            active.entered.set(io_mod.getIo());
            active.released.waitUncancelable(io_mod.getIo());
            return count;
        }
        fn cancel(self: *@This()) void {
            self.entered.waitUncancelable(io_mod.getIo());
            self.requested_at = io_mod.nanoTimestamp();
            self.cancel_flag.store(true, .release);
            self.released.set(io_mod.getIo());
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io_mod.getIo(), "tail", .{ .read = true });
    defer file.close(io_mod.getIo());
    const bytes = "x" ** (256 * 1024);
    try file.writeStreamingAll(io_mod.getIo(), bytes);
    const before = try file.stat(io_mod.getIo());
    var observer = Observer{};
    Observer.active = &observer;
    var vtable = std.testing.io.vtable.*;
    vtable.fileReadPositional = Observer.read;
    const observed_io = std.Io{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    const thread = try std.Thread.spawn(.{}, Observer.cancel, .{&observer});
    var failure: ?anyerror = null;
    _ = fileBytesMatch(observed_io, file, 0, bytes, &observer.cancel_flag) catch |err| failed: {
        failure = err;
        break :failed false;
    };
    observer.entered.set(io_mod.getIo());
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), failure);
    try std.testing.expect(io_mod.nanoTimestamp() - observer.requested_at < 500 * std.time.ns_per_ms);
    const after = try file.stat(io_mod.getIo());
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectEqual(before.mtime, after.mtime);
}

pub fn durableStatesEqual(
    first: session_codec.DurableSessionState,
    second: session_codec.DurableSessionState,
) !bool {
    return durableStatesEqualCancellable(first, second, null) catch |err| switch (err) {
        error.Cancelled => unreachable,
        inline else => |failure| return failure,
    };
}

fn durableStatesEqualCancellable(first: session_codec.DurableSessionState, second: session_codec.DurableSessionState, cancel_flag: session_read.CancelFlag) !bool {
    var first_buffer: [4096]u8 = undefined;
    var first_discard = std.Io.Writer.Discarding.init(&first_buffer);
    const first_summary = try session_codec.encodeStateCancellable(
        first,
        &first_discard.writer,
        cancel_flag,
    );
    var second_buffer: [4096]u8 = undefined;
    var second_discard = std.Io.Writer.Discarding.init(&second_buffer);
    const second_summary = try session_codec.encodeStateCancellable(
        second,
        &second_discard.writer,
        cancel_flag,
    );
    return first_summary.encoded_bytes == second_summary.encoded_bytes and
        std.mem.eql(
            u8,
            &first_summary.sha256,
            &second_summary.sha256,
        );
}

fn durableStatesRichEqual(
    first: session_codec.DurableSessionState,
    second: session_codec.DurableSessionState,
    cancel_flag: session_read.CancelFlag,
) !bool {
    if (!try durableStatesEqualCancellable(first, second, cancel_flag)) return false;
    if (first.usage == null or second.usage == null) {
        return first.usage == null and second.usage == null;
    }
    return session_usage.snapshotEql(first.usage.?, second.usage.?);
}

fn confirmWritableNamespace(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    options: Options,
) !void {
    if (!loaded.namespace_confirmation_required) return;
    try loaded.prepareCommitLifecycle(alloc, options.cancel_flag);
    errdefer loaded.abortCommitLifecycle();

    options.test_controls.lock(.commit);
    var commit_lock = acquireLockWithDeadline(
        &loaded.log.dir,
        commit_lock_file,
        true,
        options.commit_lock_deadline_ms,
        options.cancel_flag,
    ) catch |err| return mapCommitLockError(err);
    defer commit_lock.release();

    var marker = try resolveAuthorityIntent(alloc, &loaded.log, options);
    defer marker.deinit(alloc);
    if (!std.mem.eql(u8, &marker.authority_id, &loaded.authority_id)) {
        return error.SessionCommitIndeterminate;
    }
    const position = try resolvePublicationIntent(alloc, &loaded.log, options);
    if (!positionsEqual(position, loaded.position)) {
        var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
        defer log.close(io_mod.getIo());
        const length = try log.length(io_mod.getIo());
        if (length < position.through_event_log_bytes) {
            return error.SessionCommitIndeterminate;
        }
        if (length > position.through_event_log_bytes) {
            try rollbackPublicationToPrior(&loaded.log, alloc, log, position, options);
        }
        const next_state = session_replay.replayBoundary(alloc, log, position, options.cancel_flag) catch |err| switch (err) {
            error.OutOfMemory => return error.SessionReplayResourceExhausted,
            else => return err,
        };
        const generation_changed = !std.mem.eql(
            u8,
            &position.log_generation,
            &loaded.position.log_generation,
        );
        loaded.state.deinit(alloc);
        loaded.state = next_state;
        loaded.position = position;
        if (generation_changed) {
            loaded.generation_base_seq = position.through_seq;
            loaded.generation_base_bytes = position.through_event_log_bytes;
            loaded.checkpoint_seq = null;
            loaded.checkpoint_sha256 = null;
        }
        loaded.projection_status = .stale;
    }
    try io_mod.syncVerifiedDir(loaded.log.dir.dir);
    loaded.namespace_confirmation_required = false;
}

fn handlePreIntentFailure(
    log: std.Io.File,
    prior: CommitPosition,
    failed_tail: FailedTailDisposition,
) anyerror {
    return switch (failed_tail) {
        .retry_expected_tail => error.SessionPersistenceDegraded,
        .rollback_before_adapter_continue => blk: {
            rollbackTail(log, prior) catch break :blk error.SessionCommitIndeterminate;
            break :blk error.SessionPersistenceDegraded;
        },
    };
}

fn rollbackTail(log: std.Io.File, prior: CommitPosition) !void {
    try log.setLength(io_mod.getIo(), prior.through_event_log_bytes);
    try log.sync(io_mod.getIo());
}

fn handleIntentFailure(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    log: std.Io.File,
    prior: CommitPosition,
    failed_tail: FailedTailDisposition,
    cause: anyerror,
    options: Options,
) anyerror {
    if (cause == error.OutOfMemory) return error.OutOfMemory;
    if (failed_tail == .retry_expected_tail) {
        loaded.namespace_confirmation_required = true;
        return error.SessionCommitIndeterminate;
    }
    rollbackPublicationToPrior(
        &loaded.log,
        alloc,
        log,
        prior,
        options,
    ) catch {
        loaded.namespace_confirmation_required = true;
        return error.SessionCommitIndeterminate;
    };
    loaded.namespace_confirmation_required = false;
    return error.SessionPersistenceDegraded;
}

fn handlePublishedTailFailure(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    log: std.Io.File,
    prior: CommitPosition,
    failed_tail: FailedTailDisposition,
    _: anyerror,
    options: Options,
) anyerror {
    if (failed_tail == .retry_expected_tail) {
        loaded.namespace_confirmation_required = true;
        return error.SessionCommitIndeterminate;
    }
    rollbackPublicationToPrior(
        &loaded.log,
        alloc,
        log,
        prior,
        options,
    ) catch {
        loaded.namespace_confirmation_required = true;
        return error.SessionCommitIndeterminate;
    };
    loaded.namespace_confirmation_required = false;
    return error.SessionPersistenceDegraded;
}

fn rollbackPublicationToPrior(
    writable: *WritableSessionDir,
    alloc: Allocator,
    log: std.Io.File,
    prior: CommitPosition,
    options: Options,
) !void {
    const bytes = try encodeWatermark(alloc, writable.session_id, prior);
    defer alloc.free(bytes);
    const name = try watermarkName(alloc, prior.log_generation);
    defer alloc.free(name);
    try rollbackTail(log, prior);
    try durableReplace(alloc, &writable.dir, name, bytes);
    _ = try validateLivePosition(
        alloc,
        &writable.dir,
        writable.session_id,
        prior,
        options.cancel_flag,
    );
    if (try entryExists(&writable.dir, publication_intent_file)) {
        try deleteAndSync(
            &writable.dir,
            publication_intent_file,
            options.test_controls,
            null,
        );
    }
}

fn refreshProjections(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
    options: Options,
) !void {
    if (checkpointDue(loaded, options.checkpoint_interval)) {
        writeCheckpointProjection(alloc, loaded, options.cancel_flag) catch |err| switch (err) {
            error.CheckpointTooLarge => {},
            else => return err,
        };
    }
    try writeManifestProjection(alloc, loaded);
    loaded.projection_status = .current;
}

fn checkpointDue(loaded: *LoadedWritableSession, interval: u64) bool {
    return interval > 0 and
        (loaded.checkpoint_seq == null or
            loaded.position.through_seq - loaded.checkpoint_seq.? >= interval);
}

fn writeCheckpointProjection(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
    cancel_flag: session_read.CancelFlag,
) !void {
    const checkpoint = session_projection.Checkpoint{
        .session_id = loaded.log.session_id,
        .log_generation = loaded.position.log_generation,
        .through_seq = loaded.position.through_seq,
        .through_event_id = loaded.position.through_event_id,
        .through_event_log_bytes = loaded.position.through_event_log_bytes,
        .state = loaded.state,
    };
    const bytes = try session_projection.encodeCheckpointCancellable(alloc, checkpoint, cancel_flag);
    defer alloc.free(bytes);
    const digest = try session_read.sha256(bytes, cancel_flag);
    try io_mod.durableReplaceVerifiedWithOps(alloc, &loaded.log.dir, checkpoint_file, bytes, .{ .cancel_flag = cancel_flag });
    loaded.checkpoint_seq = loaded.position.through_seq;
    loaded.checkpoint_sha256 = digest;
}

fn writeManifestProjection(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
) !void {
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const stat = try eventStat(log, loaded.position.through_event_log_bytes);
    const fingerprint = try session_projection.eventFileStatFingerprint(
        stat,
        loaded.position.through_event_log_bytes,
    );
    const manifest = session_projection.Manifest{
        .id = loaded.log.session_id,
        .authority_id = loaded.authority_id,
        .log_generation = loaded.position.log_generation,
        .created_at_ms = loaded.state.created_at_ms,
        .updated_at_ms = loaded.state.updated_at_ms,
        .origin_workspace_root = loaded.state.origin_workspace_root,
        .workspace_root = loaded.state.workspace_root,
        .conversation_language = loaded.state.conversation_language,
        .history_len = loaded.state.history.len,
        .total_input_tokens = loaded.state.total_input_tokens,
        .total_output_tokens = loaded.state.total_output_tokens,
        .last_event_seq = loaded.position.through_seq,
        .event_log_bytes = loaded.position.through_event_log_bytes,
        .event_log_stat_fingerprint = fingerprint,
        .generation_base_seq = loaded.generation_base_seq,
        .generation_base_bytes = loaded.generation_base_bytes,
        .checkpoint_seq = loaded.checkpoint_seq,
        .checkpoint_sha256 = loaded.checkpoint_sha256,
        .preferences = loaded.state.preferences,
    };
    const bytes = try session_projection.encodeManifest(alloc, manifest);
    defer alloc.free(bytes);
    try durableReplace(alloc, &loaded.log.dir, manifest_file, bytes);

    var display = try displayMetadataForProjection(alloc, loaded);
    defer display.metadata.deinit(alloc);
    // A present sidecar is frozen and already durable; only first derivations
    // (or repairs after a failed read) are written.
    if (display.metadata.present and !display.from_sidecar) {
        if (display.metadata.origin_workspace_root == null) {
            display.metadata.origin_workspace_root = try alloc.dupe(u8, loaded.state.origin_workspace_root);
        }
        try session_display_metadata.writeSidecar(alloc, &loaded.log.dir, display.metadata);
    }
}

const ProjectionDisplayMetadata = struct {
    metadata: session_display_metadata.DisplayMetadata,
    from_sidecar: bool,
};

fn displayMetadataForProjection(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
) !ProjectionDisplayMetadata {
    var existing = session_display_metadata.readSidecarOrFallback(alloc, &loaded.log.dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf(
                "session",
                "event=display_sidecar_read_failed id={s} err={s}",
                .{ loaded.log.session_id, @errorName(err) },
            );
            return .{
                .metadata = try session_display_metadata.deriveFromHistory(alloc, loaded.state.history),
                .from_sidecar = false,
            };
        },
    };
    if (existing.present) return .{ .metadata = existing, .from_sidecar = true };
    existing.deinit(alloc);
    return .{
        .metadata = try session_display_metadata.deriveFromHistory(alloc, loaded.state.history),
        .from_sidecar = false,
    };
}

fn eventStat(
    file: std.Io.File,
    expected_size: u64,
) !session_projection.EventFileStat {
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1 or stat.size != expected_size) {
        return error.InvalidEventFileStat;
    }
    return .{
        .device = try eventDevice(file),
        .inode = @intCast(stat.inode),
        .kind = .regular,
        .mode = stat.permissions.toMode(),
        .link_count = @intCast(stat.nlink),
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
        .ctime_ns = stat.ctime.nanoseconds,
    };
}

fn eventDevice(file: std.Io.File) !u64 {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            while (true) {
                var statx = std.mem.zeroes(linux.Statx);
                switch (linux.errno(linux.statx(
                    file.handle,
                    "",
                    linux.AT.EMPTY_PATH,
                    linux.STATX.BASIC_STATS,
                    &statx,
                ))) {
                    .SUCCESS => {
                        const major: u64 = statx.dev_major;
                        const minor: u64 = statx.dev_minor;
                        break :blk (minor & 0xff) |
                            ((major & 0xfff) << 8) |
                            ((minor & ~@as(u64, 0xff)) << 12) |
                            ((major & ~@as(u64, 0xfff)) << 32);
                    },
                    .INTR => {},
                    else => return error.InvalidEventFileStat,
                }
            }
        },
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => blk: {
            while (true) {
                var native = std.mem.zeroes(std.c.Stat);
                switch (std.c.errno(std.c.fstat(file.handle, &native))) {
                    .SUCCESS => break :blk @intCast(native.dev),
                    .INTR => {},
                    else => return error.InvalidEventFileStat,
                }
            }
        },
        else => 0,
    };
}

fn compactCanonicalLogIfDueImpl(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    options: Options,
) !void {
    try confirmWritableNamespace(loaded, alloc, options);
    const frame_growth = loaded.position.through_seq - loaded.generation_base_seq;
    const byte_growth =
        loaded.position.through_event_log_bytes - loaded.generation_base_bytes;
    if (frame_growth < options.compaction_frame_threshold and
        byte_growth < options.compaction_byte_threshold)
    {
        return;
    }
    compactCanonicalLog(loaded, alloc, options) catch |err| switch (err) {
        error.OutOfMemory,
        error.Cancelled,
        error.Canceled,
        error.SessionLogCompactionIndeterminate,
        => return err,
        else => return error.SessionLogCompactionFailed,
    };
}

fn maintainCanonicalLogAfterCommit(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    options: Options,
) !void {
    if (loaded.namespace_confirmation_required) return;
    compactCanonicalLogIfDueImpl(loaded, alloc, options) catch |err| {
        if (err == error.Cancelled or err == error.Canceled) return;
        if (!loaded.compaction_warning_active) {
            const frame_growth =
                loaded.position.through_seq - loaded.generation_base_seq;
            const byte_growth =
                loaded.position.through_event_log_bytes -
                loaded.generation_base_bytes;
            debug_trace.logf(
                "session",
                "event=canonical_log_compaction_failed kind={s} current_bytes={d} growth_bytes={d} growth_frames={d}",
                .{
                    @errorName(err),
                    loaded.position.through_event_log_bytes,
                    byte_growth,
                    frame_growth,
                },
            );
            loaded.compaction_warning_active = true;
        }
        if (err == error.SessionLogCompactionIndeterminate) return err;
        return;
    };
    loaded.compaction_warning_active = false;
}

fn compactCanonicalLog(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    options: Options,
) !void {
    const new_generation = randomIdentifier();
    const first_id = randomIdentifier();
    const session_started = session_event.Envelope{
        .log_generation = new_generation,
        .seq = 1,
        .event_id = first_id,
        .timestamp_ms = loaded.state.updated_at_ms,
        .event = .{ .session_started = .{
            .id = loaded.state.id,
            .created_at_ms = loaded.state.created_at_ms,
            .origin_workspace_root = loaded.state.origin_workspace_root,
            .workspace_root = loaded.state.workspace_root,
            .conversation_language = loaded.state.conversation_language,
            .preferences = loaded.state.preferences,
            .usage = loaded.state.usage,
            .subagent_child = loaded.state.subagent_child,
        } },
    };
    const first_line = try session_event.encodeFrameCancellable(alloc, session_started, options.cancel_flag);
    defer alloc.free(first_line);
    var content: std.Io.Writer.Allocating = .init(alloc);
    defer content.deinit();
    try content.writer.writeAll(first_line);
    var ids = IdSequence{ .next_value = randomSequenceSeed() };
    const replacement = try session_event.writeStateReplacement(
        alloc,
        &content.writer,
        loaded.state,
        .{
            .log_generation = new_generation,
            .first_seq = 2,
            .replacement_id = randomIdentifier(),
            .event_ids = ids.source(),
            .timestamp_ms = loaded.state.updated_at_ms,
            .reason = .log_compaction,
            .cancel_flag = options.cancel_flag,
        },
    );
    const suffix = identifierHex(new_generation);
    const temp_name = try std.fmt.allocPrint(
        alloc,
        "events.compact.{s}.tmp",
        .{suffix},
    );
    defer alloc.free(temp_name);
    var temp = try createManagedFile(&loaded.log.dir, temp_name);
    errdefer |err| if (err == error.Cancelled or err == error.Canceled) {
        loaded.log.dir.dir.deleteFile(io_mod.getIo(), temp_name) catch |cleanup_err| debug_trace.logf("session", "event=cancelled_compaction_temp_cleanup_failed err={s}", .{@errorName(cleanup_err)});
    };
    defer temp.close(io_mod.getIo());
    try session_read.writeFileBytes(io_mod.getIo(), temp, 0, content.written(), options.cancel_flag);
    try temp.sync(io_mod.getIo());
    try options.test_controls.boundary(.after_compaction_temp_sync);
    const proposed = CommitPosition{
        .log_generation = new_generation,
        .through_seq = replacement.last_seq,
        .through_event_id = replacement.last_event_id,
        .through_event_log_bytes = content.written().len,
    };
    _ = try session_replay.scanCommitPosition(alloc, temp, proposed, options.cancel_flag);
    const watermark_bytes = try encodeWatermark(
        alloc,
        loaded.log.session_id,
        proposed,
    );
    defer alloc.free(watermark_bytes);
    const new_watermark = try watermarkName(alloc, new_generation);
    defer alloc.free(new_watermark);
    errdefer |err| if (err == error.Cancelled or err == error.Canceled) {
        loaded.log.dir.dir.deleteFile(io_mod.getIo(), new_watermark) catch |cleanup_err| switch (cleanup_err) {
            error.FileNotFound => {},
            else => debug_trace.logf("session", "event=cancelled_compaction_watermark_cleanup_failed err={s}", .{@errorName(cleanup_err)}),
        };
    };
    try durableReplace(
        alloc,
        &loaded.log.dir,
        new_watermark,
        watermark_bytes,
    );
    try options.test_controls.boundary(.after_compaction_watermark_sync);

    options.test_controls.lock(.commit);
    var commit_lock = acquireLockWithDeadline(
        &loaded.log.dir,
        commit_lock_file,
        true,
        options.commit_lock_deadline_ms,
        options.cancel_flag,
    ) catch |err| return @as(anyerror!void, mapCommitLockError(err));
    defer commit_lock.release();
    const current = try loadCurrentPosition(
        alloc,
        &loaded.log.dir,
        loaded.log.session_id,
        options.cancel_flag,
    );
    if (!positionsEqual(current, loaded.position)) {
        return error.SessionLogCompactionFailed;
    }
    const intent = PublicationIntent{
        .session_id = loaded.log.session_id,
        .operation_id = randomIdentifier(),
        .kind = .log_generation_replace,
        .prior = loaded.position,
        .proposed = proposed,
    };
    const intent_bytes = try encodePublicationIntent(alloc, intent);
    defer alloc.free(intent_bytes);
    if (try entryExists(&loaded.log.dir, publication_intent_file)) {
        return error.SessionLogCompactionIndeterminate;
    }
    try durableReplace(
        alloc,
        &loaded.log.dir,
        publication_intent_file,
        intent_bytes,
    );
    loaded.namespace_confirmation_required = true;
    options.test_controls.boundary(.after_compaction_intent_sync) catch
        return error.SessionLogCompactionIndeterminate;
    loaded.log.dir.dir.rename(
        temp_name,
        loaded.log.dir.dir,
        events_file,
        io_mod.getIo(),
    ) catch return error.SessionLogCompactionIndeterminate;
    options.test_controls.boundary(.after_compaction_log_rename) catch
        return error.SessionLogCompactionIndeterminate;
    io_mod.syncVerifiedDir(loaded.log.dir.dir) catch
        return error.SessionLogCompactionIndeterminate;
    options.test_controls.boundary(.after_compaction_namespace_sync) catch
        return error.SessionLogCompactionIndeterminate;
    _ = validateLivePosition(
        alloc,
        &loaded.log.dir,
        loaded.log.session_id,
        proposed,
        options.cancel_flag,
    ) catch return error.SessionLogCompactionIndeterminate;
    options.test_controls.boundary(.after_compaction_live_confirmation) catch
        return error.SessionLogCompactionIndeterminate;
    const compacted_state = session_replay.replayBoundary(alloc, temp, proposed, options.cancel_flag) catch
        return error.SessionLogCompactionIndeterminate;
    var cleanup_pending = false;
    deleteAndSync(
        &loaded.log.dir,
        publication_intent_file,
        options.test_controls,
        .after_compaction_intent_remove,
    ) catch {
        loaded.projection_status = .stale;
        cleanup_pending = true;
    };
    if (!cleanup_pending) {
        loaded.namespace_confirmation_required = false;
    }
    loaded.position = proposed;
    loaded.generation_base_seq = proposed.through_seq;
    loaded.generation_base_bytes = proposed.through_event_log_bytes;
    loaded.checkpoint_seq = null;
    loaded.checkpoint_sha256 = null;
    loaded.state.deinit(alloc);
    loaded.state = compacted_state;
    writeCheckpointProjection(alloc, loaded, options.cancel_flag) catch {};
    writeManifestProjection(alloc, loaded) catch {
        loaded.projection_status = .stale;
    };
    loaded.persistence_debt.canonical_replacement = false;
}

const CleanupCandidates = struct {
    temp_name: []u8,
    watermark_name: []u8,
};

fn makeCleanupCandidatesForTest(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
) !CleanupCandidates {
    const generation = randomIdentifier();
    const first_id = randomIdentifier();
    const envelope = session_event.Envelope{
        .log_generation = generation,
        .seq = 1,
        .event_id = first_id,
        .timestamp_ms = loaded.state.created_at_ms,
        .event = .{ .session_started = .{
            .id = loaded.state.id,
            .created_at_ms = loaded.state.created_at_ms,
            .origin_workspace_root = loaded.state.origin_workspace_root,
            .workspace_root = loaded.state.workspace_root,
            .conversation_language = loaded.state.conversation_language,
            .preferences = loaded.state.preferences,
            .usage = loaded.state.usage,
            .subagent_child = loaded.state.subagent_child,
        } },
    };
    const line = try session_event.encodeFrame(alloc, envelope);
    defer alloc.free(line);
    const suffix = identifierHex(generation);
    const temp_name = try std.fmt.allocPrint(
        alloc,
        "events.compact.{s}.tmp",
        .{suffix},
    );
    errdefer alloc.free(temp_name);
    var file = try createManagedFile(&loaded.log.dir, temp_name);
    defer file.close(io_mod.getIo());
    try file.writePositionalAll(io_mod.getIo(), line, 0);
    try file.sync(io_mod.getIo());
    const position = CommitPosition{
        .log_generation = generation,
        .through_seq = 1,
        .through_event_id = first_id,
        .through_event_log_bytes = line.len,
    };
    const watermark_name = try watermarkName(alloc, generation);
    errdefer alloc.free(watermark_name);
    const bytes = try encodeWatermark(alloc, loaded.log.session_id, position);
    defer alloc.free(bytes);
    try durableReplace(alloc, &loaded.log.dir, watermark_name, bytes);
    return .{ .temp_name = temp_name, .watermark_name = watermark_name };
}

fn cleanupOrphansImpl(
    loaded: *LoadedWritableSession,
    alloc: Allocator,
    mode: CleanupMode,
    options: Options,
) !CleanupReport {
    options.test_controls.lock(.commit);
    var commit_lock = acquireLock(
        &loaded.log.dir,
        commit_lock_file,
        true,
    ) catch return .{ .report_only = 1 };
    defer commit_lock.release();
    if (try entryExists(&loaded.log.dir, authority_intent_file) or
        try entryExists(&loaded.log.dir, publication_intent_file))
    {
        return .{ .report_only = 1 };
    }
    var marker = try loadAuthority(alloc, &loaded.log.dir, loaded.log.session_id);
    defer marker.deinit(alloc);
    const current = try loadCurrentPosition(
        alloc,
        &loaded.log.dir,
        loaded.log.session_id,
        options.cancel_flag,
    );
    try io_mod.syncVerifiedDir(loaded.log.dir.dir);

    var report: CleanupReport = .{};
    var iterator = loaded.log.dir.dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        const generation = cleanupCandidateGeneration(entry.name) orelse continue;
        if (std.mem.eql(u8, &generation, &current.log_generation)) {
            report.ignored += 1;
            continue;
        }
        const stat = loaded.log.dir.dir.statFile(io_mod.getIo(), entry.name, .{
            .follow_symlinks = false,
        }) catch {
            report.ignored += 1;
            continue;
        };
        if (stat.kind != .file or stat.nlink != 1 or
            stat.permissions.toMode() & 0o777 != 0o600)
        {
            report.ignored += 1;
            continue;
        }
        const valid = if (std.mem.startsWith(u8, entry.name, "commit."))
            validateOrphanWatermark(
                alloc,
                &loaded.log.dir,
                entry.name,
                loaded.log.session_id,
                generation,
            )
        else
            validateOrphanTemp(
                alloc,
                &loaded.log.dir,
                entry.name,
                loaded.log.session_id,
                generation,
            );
        valid catch {
            report.ignored += 1;
            continue;
        };
        if (mode == .report_only) {
            report.report_only += 1;
            continue;
        }
        try loaded.log.dir.dir.deleteFile(io_mod.getIo(), entry.name);
        report.removed += 1;
    }
    if (report.removed > 0) try io_mod.syncVerifiedDir(loaded.log.dir.dir);
    return report;
}

pub fn cleanupCandidateGeneration(name: []const u8) ?session_event.Identifier {
    if (std.mem.startsWith(u8, name, "commit.") and
        std.mem.endsWith(u8, name, ".json") and name.len == 44)
    {
        return parseIdentifier(name[7..39]) catch null;
    }
    const prefix = "events.compact.";
    const suffix = ".tmp";
    if (std.mem.startsWith(u8, name, prefix) and
        std.mem.endsWith(u8, name, suffix) and
        name.len == prefix.len + 32 + suffix.len)
    {
        return parseIdentifier(name[prefix.len .. prefix.len + 32]) catch null;
    }
    return null;
}

pub fn hasValidatedCompactionTemp(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !bool {
    var entries = dir.dir.iterate();
    while (try entries.next(io_mod.getIo())) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "events.compact.")) continue;
        const generation = cleanupCandidateGeneration(entry.name) orelse
            continue;
        validateOrphanTemp(
            alloc,
            dir,
            entry.name,
            session_id,
            generation,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        return true;
    }
    return false;
}

fn validateOrphanWatermark(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    session_id: []const u8,
    generation: Identifier,
) !void {
    const bytes = try readManagedFileAlloc(
        alloc,
        dir,
        name,
        watermark_max_bytes,
        null,
    );
    defer alloc.free(bytes);
    _ = try decodeWatermark(alloc, bytes, session_id, generation);
}

fn validateOrphanTemp(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    session_id: []const u8,
    generation: Identifier,
) !void {
    var file = try openManagedFile(dir, name, .read_only);
    defer file.close(io_mod.getIo());
    const length = try file.length(io_mod.getIo());
    var validator: session_event.SequenceValidator = .{};
    var offset: u64 = 0;
    var replacement_open = false;
    var replacement_id: Identifier = undefined;
    var last: ?CommitPosition = null;
    while (offset < length) {
        const line = try session_replay.readLineAt(alloc, file, offset, length, null) orelse
            return error.InvalidSessionFormat;
        defer alloc.free(line.bytes);
        var envelope = session_event.decodeFrame(alloc, line.bytes, null) catch
            return error.InvalidSessionFormat;
        defer envelope.deinit(alloc);
        validator.validate(envelope) catch return error.InvalidSessionFormat;
        if (!std.mem.eql(u8, &envelope.log_generation, &generation)) {
            return error.InvalidSessionFormat;
        }
        if (envelope.seq == 1 and
            (envelope.kind() != .session_started or
                !std.mem.eql(u8, envelope.event.session_started.id, session_id)))
        {
            return error.InvalidSessionFormat;
        }
        switch (envelope.event) {
            .state_replacement_started => |start| {
                if (replacement_open) return error.InvalidSessionFormat;
                replacement_open = true;
                replacement_id = start.replacement_id;
            },
            .state_replacement_chunk => |chunk| {
                if (!replacement_open or
                    !std.mem.eql(u8, &replacement_id, &chunk.replacement_id))
                {
                    return error.InvalidSessionFormat;
                }
            },
            .state_replacement_committed => |commit| {
                if (!replacement_open or
                    !std.mem.eql(u8, &replacement_id, &commit.replacement_id))
                {
                    return error.InvalidSessionFormat;
                }
                replacement_open = false;
                last = .{
                    .log_generation = generation,
                    .through_seq = envelope.seq,
                    .through_event_id = envelope.event_id,
                    .through_event_log_bytes = line.next_offset,
                };
            },
            else => {
                if (replacement_open) return error.InvalidSessionFormat;
                last = .{
                    .log_generation = generation,
                    .through_seq = envelope.seq,
                    .through_event_id = envelope.event_id,
                    .through_event_log_bytes = line.next_offset,
                };
            },
        }
        offset = line.next_offset;
    }
    if (offset != length or replacement_open) return error.InvalidSessionFormat;
    _ = try session_replay.scanCommitPosition(
        alloc,
        file,
        last orelse return error.InvalidSessionFormat,
        null,
    );
}

const BoundaryFailure = struct {
    target: Boundary,

    fn hit(raw: ?*anyopaque, point: Boundary) !void {
        const self: *BoundaryFailure = @ptrCast(@alignCast(raw.?));
        if (point == self.target) return error.InjectedBoundaryFailure;
    }

    fn test_controls(self: *BoundaryFailure) TestControls {
        return .{ .context = self, .boundary_fn = hit };
    }
};

const LockTrace = struct {
    items: [16]LockKind = undefined,
    len: usize = 0,

    fn record(raw: ?*anyopaque, kind: LockKind) void {
        const self: *LockTrace = @ptrCast(@alignCast(raw.?));
        self.items[self.len] = kind;
        self.len += 1;
    }

    fn test_controls(self: *LockTrace) TestControls {
        return .{ .context = self, .lock_fn = record };
    }
};

const TempRoot = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    root: Root,

    fn init(alloc: Allocator) !TempRoot {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(io_mod.getIo(), "home", std.Io.File.Permissions.fromMode(0o700));
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        var root = try Root.initFromHome(alloc, home, .writable);
        errdefer root.deinit(alloc);
        return .{ .tmp = tmp, .home = home, .root = root };
    }

    fn deinit(self: *TempRoot, alloc: Allocator) void {
        self.root.deinit(alloc);
        alloc.free(self.home);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

test "writable recovery prepares publication before mutation and pure opens stay read-only" {
    const Probe = struct {
        root: *Root,
        committed_bytes: u64,
        prepares: usize = 0,
        publishes: usize = 0,
        prepared_before_mutation: bool = false,
        cancel_flag: session_read.CancelFlag,
        fail_publication: bool,
        fn prepare(raw: ?*anyopaque, _: Allocator, id: []const u8, cancel_flag: session_read.CancelFlag) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expect(self.cancel_flag == cancel_flag);
            var dir = try openSessionDir(&self.root.sessions.?, id, .read_only);
            defer dir.close();
            var file = try openManagedFile(&dir, events_file, .read_only);
            defer file.close(io_mod.getIo());
            self.prepared_before_mutation = try file.length(io_mod.getIo()) > self.committed_bytes or
                try entryExists(&dir, authority_intent_file) or try entryExists(&dir, publication_intent_file);
            self.prepares += 1;
        }
        fn publish(raw: ?*anyopaque, _: Allocator, state: session_codec.DurableSessionState, _: CommitPosition, cancel_flag: session_read.CancelFlag) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expect(self.cancel_flag == cancel_flag);
            var dir = try openSessionDir(&self.root.sessions.?, state.id, .read_only);
            defer dir.close();
            var lock = try acquireLockWithDeadline(&dir, commit_lock_file, false, 0, null);
            lock.release();
            self.publishes += 1;
            if (self.fail_publication) return error.InjectedPublicationFailure;
        }
    };
    const alloc = std.testing.allocator;
    const Recovery = enum { tail, publication, authority, none };
    for (std.enums.values(Recovery)) |recovery| {
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        var initial = try testState(alloc, "recovery-publication", 10);
        defer initial.deinit(alloc);
        var committed_bytes: u64 = 0;
        if (recovery == .authority) {
            var failure = BoundaryFailure{ .target = .after_authority_marker_rename };
            try std.testing.expectError(error.SessionStartIndeterminate, temp.root.startWritableSession(alloc, initial, .{ .test_controls = failure.test_controls() }));
        } else {
            var loaded = try temp.root.startWritableSession(alloc, initial, .{});
            defer loaded.deinit(alloc);
            var next = try stateWithTurn(alloc, initial, 20);
            defer next.deinit(alloc);
            _ = try loaded.appendEvent(alloc, historyEvent(next), 20, .retry_expected_tail, .{ .checkpoint_interval = 0 });
            committed_bytes = loaded.position.through_event_log_bytes;
            if (recovery != .none) {
                var failure = BoundaryFailure{ .target = if (recovery == .tail) .after_event_sync else .after_commit_intent_sync };
                try std.testing.expectError(if (recovery == .tail) error.SessionPersistenceDegraded else error.SessionCommitIndeterminate, loaded.appendEvent(alloc, .{ .preferences_changed = .{ .fast_mode = true } }, 21, .retry_expected_tail, .{ .test_controls = failure.test_controls() }));
            }
            try loaded.log.dir.dir.deleteFile(io_mod.getIo(), manifest_file);
        }
        var cancel = std.atomic.Value(bool).init(false);
        var probe = Probe{ .root = &temp.root, .committed_bytes = committed_bytes, .cancel_flag = &cancel, .fail_publication = recovery == .publication };
        var reopened = try temp.root.resumeForWriteWithLifecycle(alloc, initial.id, .{ .cancel_flag = &cancel }, .{ .context = &probe, .prepare_fn = Probe.prepare, .publish_fn = Probe.publish });
        defer reopened.deinit(alloc);
        try std.testing.expectEqual(@as(usize, if (recovery != .none) 1 else 0), probe.prepares);
        try std.testing.expectEqual(probe.prepares, probe.publishes);
        if (recovery != .none) try std.testing.expect(probe.prepared_before_mutation);
        try std.testing.expectEqual(probe.fail_publication, reopened.persistence_debt.derived_publication);
        try std.testing.expect(!try entryExists(&reopened.log.dir, manifest_file));
        try reopened.confirmResumeHandoffBoundary(alloc, .{});
    }
}

test "failed publication preparation preserves the prior canonical handoff" {
    const Reject = struct {
        fn prepare(_: ?*anyopaque, _: Allocator, _: []const u8, _: session_read.CancelFlag) !void {
            return error.InjectedPreparationFailure;
        }
    };
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "prepare-failure", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, initial, 20);
    defer next.deinit(alloc);
    _ = try loaded.appendEvent(alloc, historyEvent(next), 20, .retry_expected_tail, .{});
    const before = loaded.position;
    try loaded.installCommitLifecycle(.{ .prepare_fn = Reject.prepare });
    try std.testing.expectError(error.InjectedPreparationFailure, loaded.appendEvent(alloc, .{ .preferences_changed = .{ .fast_mode = true } }, 21, .retry_expected_tail, .{}));
    try std.testing.expect(positionsEqual(before, loaded.position));
    try loaded.confirmResumeHandoffBoundary(alloc, .{});
    try std.testing.expectError(error.InjectedPreparationFailure, loaded.commitStateReplacement(alloc, next, .recovery, .retry_expected_tail, .{}));
    try loaded.confirmResumeHandoffBoundary(alloc, .{});
}

test "creation prepares publication before exposing a session directory" {
    const Probe = struct {
        root: *Root,
        visible: bool = false,
        released: usize = 0,
        fn prepare(raw: ?*anyopaque, _: Allocator, id: []const u8, _: session_read.CancelFlag) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.visible = try entryExists(&self.root.sessions.?, id);
            return error.InjectedPreparationFailure;
        }
        fn deinit(raw: ?*anyopaque, _: Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.released += 1;
        }
    };
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "prepare-before-create", 10);
    defer initial.deinit(alloc);
    var probe = Probe{ .root = &temp.root };
    try std.testing.expectError(error.InjectedPreparationFailure, temp.root.startWritableSessionWithLifecycle(alloc, initial, .{}, .{ .context = &probe, .prepare_fn = Probe.prepare, .deinit_fn = Probe.deinit }));
    try std.testing.expect(!probe.visible);
    try std.testing.expectEqual(@as(usize, 1), probe.released);
    try std.testing.expect(!try entryExists(&temp.root.sessions.?, initial.id));
    probe.released = 0;
    try std.testing.expectError(error.SessionNotFound, temp.root.resumeForWriteWithLifecycle(alloc, initial.id, .{}, .{ .context = &probe, .deinit_fn = Probe.deinit }));
    try std.testing.expectEqual(@as(usize, 1), probe.released);
}

test "compaction cancellation preserves the publication fence or removes only unpublished files" {
    const Stop = struct {
        target: Boundary,
        entered: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
        cancel: std.atomic.Value(bool) = .init(false),
        fn boundary(raw: ?*anyopaque, point: Boundary) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (point != self.target) return;
            self.entered.set(io_mod.getIo());
            self.released.waitUncancelable(io_mod.getIo());
        }
        fn run(self: *@This()) void {
            self.entered.waitUncancelable(io_mod.getIo());
            self.cancel.store(true, .release);
            self.released.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    for ([_]Boundary{ .after_compaction_temp_sync, .after_compaction_watermark_sync, .after_compaction_intent_sync, .after_compaction_live_confirmation }) |boundary| {
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        var initial = try testState(alloc, "cancel-compaction-boundary", 10);
        defer initial.deinit(alloc);
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        var next = try stateWithTurn(alloc, initial, 20);
        defer next.deinit(alloc);
        _ = try loaded.appendEvent(alloc, historyEvent(next), 20, .retry_expected_tail, .{ .checkpoint_interval = 0 });
        const prior = loaded.position;
        var before = loaded.log.dir.dir.iterate();
        var before_count: usize = 0;
        while (try before.next(io_mod.getIo())) |_| before_count += 1;
        var stop = Stop{ .target = boundary };
        const thread = try std.Thread.spawn(.{}, Stop.run, .{&stop});
        var failure: ?anyerror = null;
        loaded.compactCanonicalLogIfDue(alloc, .{ .cancel_flag = &stop.cancel, .compaction_frame_threshold = 0, .test_controls = .{ .context = &stop, .boundary_fn = Stop.boundary } }) catch |err| {
            failure = err;
        };
        stop.entered.set(io_mod.getIo());
        thread.join();
        if (boundary == .after_compaction_temp_sync or boundary == .after_compaction_watermark_sync) {
            try std.testing.expectEqual(@as(?anyerror, error.Cancelled), failure);
            try std.testing.expect(positionsEqual(prior, loaded.position));
            try loaded.confirmResumeHandoffBoundary(alloc, .{});
            var after = loaded.log.dir.dir.iterate();
            var after_count: usize = 0;
            while (try after.next(io_mod.getIo())) |_| after_count += 1;
            try std.testing.expectEqual(before_count, after_count);
        } else {
            try std.testing.expectEqual(@as(?anyerror, error.SessionLogCompactionIndeterminate), failure);
            try std.testing.expect(loaded.namespace_confirmation_required);
            try std.testing.expectError(error.SessionPersistenceDegraded, loaded.confirmResumeHandoffBoundary(alloc, .{}));
            try loaded.compactCanonicalLogIfDue(alloc, .{});
            try loaded.confirmResumeHandoffBoundary(alloc, .{});
            try std.testing.expectEqualStrings("world", loaded.state.history[0].assistant.assistant);
        }
    }
}

test "cancellation after canonical publication retains its replay fence" {
    const Stop = struct {
        cancel: std.atomic.Value(bool) = .init(false),
        fn boundary(raw: ?*anyopaque, point: Boundary) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (point == .after_target_namespace_sync) self.cancel.store(true, .release);
        }
    };
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "cancel-published-replay", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, initial, 20);
    defer next.deinit(alloc);
    var stop = Stop{};
    try std.testing.expectError(error.SessionCommitIndeterminate, loaded.appendEvent(alloc, historyEvent(next), 20, .retry_expected_tail, .{ .cancel_flag = &stop.cancel, .test_controls = .{ .context = &stop, .boundary_fn = Stop.boundary } }));
    try std.testing.expect(loaded.namespace_confirmation_required);
    try std.testing.expectError(error.SessionPersistenceDegraded, loaded.confirmResumeHandoffBoundary(alloc, .{}));
    try std.testing.expectError(error.SessionCommitBoundaryUnavailable, temp.root.loadReadOnly(alloc, initial.id, .{}));
    stop.cancel.store(false, .release);
    try loaded.retryDegradedWithStateReplacement(alloc, next, .{});
    try loaded.confirmResumeHandoffBoundary(alloc, .{});
}

test "canonical replacement and derived checkpoint encoding cancel after work begins" {
    const Pause = struct {
        cancel: std.atomic.Value(bool) = .init(false),
        entered: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
        observed: bool = false,
        requested_at: i128 = 0,

        fn allocator(self: *@This()) Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
        }
        fn allocate(raw: *anyopaque, size: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const result = std.testing.allocator.rawAlloc(size, alignment, ra);
            if (size >= 64 * 1024 and !self.observed) {
                self.observed = true;
                self.entered.set(io_mod.getIo());
                self.released.waitUncancelable(io_mod.getIo());
            }
            return result;
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
        fn run(self: *@This()) void {
            self.entered.waitUncancelable(io_mod.getIo());
            self.requested_at = io_mod.nanoTimestamp();
            self.cancel.store(true, .release);
            self.released.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    const Operation = enum { replacement, replacement_with_debt, checkpoint, compaction };
    for (std.enums.values(Operation)) |operation| {
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        var initial = try testState(alloc, "cancel-writing", 10);
        defer initial.deinit(alloc);
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        var next = try stateWithPrompt(alloc, initial, 20, "saved", "x" ** (256 * 1024));
        defer next.deinit(alloc);
        if (operation == .checkpoint or operation == .compaction) _ = try loaded.appendEvent(alloc, historyEvent(next), 20, .retry_expected_tail, .{ .checkpoint_interval = 0 });
        if (operation == .replacement_with_debt) loaded.persistence_debt.canonical_replacement = true;
        const prior = loaded.position;
        const before = try loaded.log.dir.dir.statFile(io_mod.getIo(), events_file, .{});
        var pause = Pause{};
        const thread = try std.Thread.spawn(.{}, Pause.run, .{&pause});
        var failure: ?anyerror = null;
        if (operation == .checkpoint) {
            loaded.writeCheckpointIfDue(pause.allocator(), true, .{ .cancel_flag = &pause.cancel }) catch |err| {
                failure = err;
            };
        } else if (operation == .compaction) {
            loaded.compactCanonicalLogIfDue(pause.allocator(), .{ .cancel_flag = &pause.cancel, .compaction_frame_threshold = 0 }) catch |err| {
                failure = err;
            };
        } else {
            _ = loaded.commitStateReplacement(pause.allocator(), next, .recovery, .retry_expected_tail, .{ .cancel_flag = &pause.cancel, .checkpoint_interval = 0 }) catch |err| failed: {
                failure = err;
                break :failed loaded.position;
            };
        }
        pause.entered.set(io_mod.getIo());
        thread.join();
        try std.testing.expect(pause.observed);
        try std.testing.expectEqual(@as(?anyerror, error.Cancelled), failure);
        try std.testing.expect(io_mod.nanoTimestamp() - pause.requested_at < 500 * std.time.ns_per_ms);
        const after = try loaded.log.dir.dir.statFile(io_mod.getIo(), events_file, .{});
        try std.testing.expectEqual(before.size, after.size);
        try std.testing.expectEqual(before.mtime, after.mtime);
        try std.testing.expect(positionsEqual(prior, loaded.position));
        if (operation == .replacement_with_debt) {
            try std.testing.expectError(error.SessionPersistenceDegraded, loaded.confirmResumeHandoffBoundary(alloc, .{}));
        } else {
            try loaded.confirmResumeHandoffBoundary(alloc, .{});
        }
    }
}

test "session loading cancels after large event or checkpoint allocation begins" {
    const alloc = std.testing.allocator;
    const CancelOnAllocation = struct {
        child: Allocator,
        cancel: std.atomic.Value(bool) = .init(false),
        started: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
        observed: bool = false,
        requested_ms: std.atomic.Value(i64) = .init(0),
        largest_request: usize = 0,
        max_trigger_bytes: usize = std.math.maxInt(usize),

        fn request(self: *@This()) void {
            self.started.waitUncancelable(io_mod.getIo());
            self.requested_ms.store(io_mod.milliTimestamp(), .release);
            self.cancel.store(true, .release);
            self.released.set(io_mod.getIo());
        }
        fn observe(self: *@This(), len: usize) void {
            self.largest_request = @max(self.largest_request, len);
            if (self.observed or len < 64 * 1024 or len >= self.max_trigger_bytes) return;
            self.observed = true;
            self.started.set(io_mod.getIo());
            self.released.waitUncancelable(io_mod.getIo());
        }
        fn allocate(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.observe(len);
            return self.child.rawAlloc(len, alignment, address);
        }
        fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.observe(len);
            return self.child.rawResize(memory, alignment, len, address);
        }
        fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.observe(len);
            return self.child.rawRemap(memory, alignment, len, address);
        }
        fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.child.rawFree(memory, alignment, address);
        }
    };
    for ([_]bool{ false, true }) |checkpoint| {
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        var initial = try testState(alloc, "cancel-large-session-read", 10);
        defer initial.deinit(alloc);
        const text = try alloc.alloc(u8, session_event.event_frame_max_bytes - 4096);
        defer alloc.free(text);
        @memset(text, 'x');
        var next = try stateWithPrompt(alloc, initial, 20, "saved prompt", text);
        defer next.deinit(alloc);
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        const frame_offset = loaded.position.through_event_log_bytes;
        _ = try loaded.appendEvent(alloc, .{ .history_turn_committed = .{
            .conversation_language = next.conversation_language,
            .total_input_tokens = 0,
            .total_output_tokens = 0,
            .turn = next.history[0],
        } }, 20, .retry_expected_tail, .{ .checkpoint_interval = 0 });
        if (checkpoint) try loaded.writeCheckpointIfDue(alloc, true, .{});
        const decoder_input = if (checkpoint) checkpoint_bytes: {
            const bytes = try readManagedFileAlloc(alloc, &loaded.log.dir, checkpoint_file, session_projection.checkpoint_max_bytes, null);
            defer alloc.free(bytes);
            const padded = try alloc.alloc(u8, session_projection.checkpoint_max_bytes);
            @memcpy(padded[0..bytes.len], bytes);
            @memset(padded[bytes.len..], ' ');
            break :checkpoint_bytes padded;
        } else event_bytes: {
            var file = try openManagedFile(&loaded.log.dir, events_file, .read_only);
            defer file.close(io_mod.getIo());
            const frame = (try session_replay.readLineAt(alloc, file, frame_offset, loaded.position.through_event_log_bytes, null)).?;
            break :event_bytes frame.bytes;
        };
        defer alloc.free(decoder_input);
        loaded.deinit(alloc);
        var directory = try openSessionDir(&temp.root.sessions.?, initial.id, .read_only);
        defer directory.close();
        const observed_paths = [_][]const u8{ events_file, manifest_file, session_lock_file, commit_lock_file, checkpoint_file };
        const observed_count: usize = if (checkpoint) observed_paths.len else observed_paths.len - 1;
        var before: [observed_paths.len]std.Io.File.Stat = undefined;
        for (observed_paths[0..observed_count], 0..) |path, index| {
            var file = try openManagedFile(&directory, path, .read_only);
            defer file.close(io_mod.getIo());
            before[index] = try file.stat(io_mod.getIo());
            before[index].atime = null;
        }

        const Stage = enum { load, decode, bytes, base64, arguments };
        for ([_]Stage{ .load, .decode, .bytes, .base64, .arguments }) |stage| {
            const encoded_binary = try alloc.alloc(u8, 4 * 1024 * 1024);
            defer alloc.free(encoded_binary);
            @memset(encoded_binary, '/');
            var binary: std.json.ObjectMap = .empty;
            defer binary.deinit(alloc);
            try binary.put(alloc, "encoding", .{ .string = "base64" });
            try binary.put(alloc, "data", .{ .string = encoded_binary });
            var turn = try std.json.parseFromSlice(std.json.Value, alloc, "{\"kind\":\"assistant\",\"user\":{\"text\":\"\",\"images\":[]},\"assistant\":\"\",\"execution\":{\"schema_version\":3,\"tool_steps\":[{\"assistant\":null,\"tool_calls\":[{\"id\":\"call\",\"name\":\"test\",\"arguments_json\":\"{}\",\"provider_result\":null}],\"tool_results\":[]}],\"files\":[]}}", .{});
            defer turn.deinit();
            turn.value.object.getPtr("execution").?.object.getPtr("tool_steps").?.array.items[0].object.getPtr("tool_calls").?.array.items[0].object.getPtr("arguments_json").?.* = .{ .string = decoder_input };
            var cancellation = CancelOnAllocation{ .child = alloc, .max_trigger_bytes = if (stage == .arguments) 1024 * 1024 else std.math.maxInt(usize) };
            const observed_alloc: Allocator = .{ .ptr = &cancellation, .vtable = &.{
                .alloc = CancelOnAllocation.allocate,
                .resize = CancelOnAllocation.resize,
                .remap = CancelOnAllocation.remap,
                .free = CancelOnAllocation.free,
            } };
            const worker = try std.Thread.spawn(.{}, CancelOnAllocation.request, .{&cancellation});
            defer {
                cancellation.started.set(io_mod.getIo());
                worker.join();
            }
            const options = Options{ .cancel_flag = &cancellation.cancel };
            const failure: ?anyerror = if (stage == .arguments) result: {
                const restored = session_codec.parseHistoryTurn(observed_alloc, turn.value, &cancellation.cancel) catch |err| break :result err;
                session.freeHistoryTurn(observed_alloc, restored);
                break :result null;
            } else if (stage == .bytes or stage == .base64) result: {
                const bytes = session_codec.parseDurableBytes(observed_alloc, if (stage == .bytes) .{ .string = decoder_input } else .{ .object = binary }, &cancellation.cancel) catch |err| break :result err;
                observed_alloc.free(bytes);
                break :result null;
            } else if (stage == .decode) result: {
                if (checkpoint) {
                    var decoded = session_projection.decodeCheckpoint(observed_alloc, decoder_input, &cancellation.cancel) catch |err| break :result err;
                    decoded.deinit(observed_alloc);
                } else {
                    var decoded = session_event.decodeFrame(observed_alloc, decoder_input, &cancellation.cancel) catch |err| break :result err;
                    decoded.deinit(observed_alloc);
                }
                break :result null;
            } else if (checkpoint) result: {
                var reopened = temp.root.resumeForWrite(observed_alloc, initial.id, options) catch |err| break :result err;
                reopened.deinit(observed_alloc);
                break :result null;
            } else result: {
                var state = temp.root.loadReadOnly(observed_alloc, initial.id, options) catch |err| break :result err;
                state.deinit(observed_alloc);
                break :result null;
            };
            try std.testing.expect(cancellation.observed);
            try std.testing.expectEqual(@as(?anyerror, error.Cancelled), failure);
            try std.testing.expect(io_mod.milliTimestamp() - cancellation.requested_ms.load(.acquire) < 500);
            if (stage == .load or stage == .decode) try std.testing.expect(cancellation.largest_request < 1024 * 1024);
            for (observed_paths[0..observed_count], 0..) |path, index| {
                var file = try openManagedFile(&directory, path, .read_only);
                defer file.close(io_mod.getIo());
                var after = try file.stat(io_mod.getIo());
                after.atime = null;
                try std.testing.expect(std.meta.eql(before[index], after));
            }
        }
    }
}

test "root init rejects symlinked durable and sessions roots" {
    const alloc = std.testing.allocator;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home");
        try tmp.dir.createDirPath(io_mod.getIo(), "outside");
        tmp.dir.symLink(
            io_mod.getIo(),
            "../outside",
            "home/.fx",
            .{ .is_directory = true },
        ) catch |err| switch (err) {
            error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        defer alloc.free(home);

        try std.testing.expectError(
            error.SessionPathUnsafe,
            Root.initFromHome(alloc, home, .writable),
        );
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
        try tmp.dir.createDirPath(io_mod.getIo(), "outside");
        tmp.dir.symLink(
            io_mod.getIo(),
            "../../outside",
            "home/.fx/sessions",
            .{ .is_directory = true },
        ) catch |err| switch (err) {
            error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        defer alloc.free(home);

        try std.testing.expectError(
            error.SessionPathUnsafe,
            Root.initFromHome(alloc, home, .writable),
        );
    }
}

fn testState(alloc: Allocator, id: []const u8, updated_at_ms: i64) !session_codec.DurableSessionState {
    return .{
        .id = try alloc.dupe(u8, id),
        .origin_workspace_root = try alloc.dupe(u8, "/tmp/fx-plan-03"),
        .workspace_root = try alloc.dupe(u8, "/tmp/fx-plan-03"),
        .created_at_ms = 10,
        .updated_at_ms = updated_at_ms,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "test/model"),
            .effort = types.ReasoningEffort.literal("high"),
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

fn stateWithTurn(
    alloc: Allocator,
    prior: session_codec.DurableSessionState,
    updated_at_ms: i64,
) !session_codec.DurableSessionState {
    return stateWithPrompt(alloc, prior, updated_at_ms, "hello", "world");
}

fn stateWithPrompt(
    alloc: Allocator,
    prior: session_codec.DurableSessionState,
    updated_at_ms: i64,
    prompt: []const u8,
    response: []const u8,
) !session_codec.DurableSessionState {
    var next = try prior.dupe(alloc);
    errdefer next.deinit(alloc);
    const history = try alloc.alloc(session.HistoryTurn, 1);
    errdefer alloc.free(history);
    history[0] = try session.makeAssistantTurn(alloc, prompt, response);
    session.freeHistoryTurnSlice(alloc, next.history);
    next.history = history;
    next.updated_at_ms = updated_at_ms;
    next.total_input_tokens = 11;
    next.total_output_tokens = 7;
    return next;
}

const PendingReplacementTestPositions = struct {
    prior: CommitPosition,
    proposed: CommitPosition,
};

fn leavePendingReplacementForTest(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
    updated_at_ms: i64,
) !PendingReplacementTestPositions {
    var replacement = try stateWithTurn(alloc, loaded.state, updated_at_ms);
    defer replacement.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_target_namespace_sync };
    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        loaded.commitStateReplacement(
            alloc,
            replacement,
            .recovery,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    const failed = loaded.degradedTail() orelse return error.TestUnexpectedResult;
    return .{ .prior = failed.prior, .proposed = failed.proposed };
}

fn replaceFrameByteForTest(
    alloc: Allocator,
    log: std.Io.File,
    frame_offset: u64,
    boundary: u64,
    needle: []const u8,
    replacement: u8,
) !void {
    const line = try session_replay.readLineAt(
        alloc,
        log,
        frame_offset,
        boundary,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer alloc.free(line.bytes);
    const match = std.mem.find(u8, line.bytes, needle) orelse
        return error.TestUnexpectedResult;
    line.bytes[match + needle.len - 1] = replacement;
    try log.writePositionalAll(io_mod.getIo(), line.bytes, frame_offset);
    try log.sync(io_mod.getIo());
}

fn corruptReplacementCommitTimestampForTest(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
    positions: PendingReplacementTestPositions,
) !void {
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
    defer log.close(io_mod.getIo());
    var offset = positions.prior.through_event_log_bytes;
    while (offset < positions.proposed.through_event_log_bytes) {
        const line = try session_replay.readLineAt(
            alloc,
            log,
            offset,
            positions.proposed.through_event_log_bytes,
            null,
        ) orelse return error.TestUnexpectedResult;
        defer alloc.free(line.bytes);
        var envelope = try session_event.decodeFrame(alloc, line.bytes, null);
        defer envelope.deinit(alloc);
        if (envelope.kind() == .state_replacement_committed) {
            const needle = "\"timestamp_ms\":20";
            const match = std.mem.find(u8, line.bytes, needle) orelse
                return error.TestUnexpectedResult;
            line.bytes[match + needle.len - 1] = '1';
            try log.writePositionalAll(io_mod.getIo(), line.bytes, offset);
            try log.sync(io_mod.getIo());
            return;
        }
        offset = line.next_offset;
    }
    return error.TestUnexpectedResult;
}

fn corruptReplacementChunkSchemaForTest(
    alloc: Allocator,
    loaded: *LoadedWritableSession,
    positions: PendingReplacementTestPositions,
) !void {
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
    defer log.close(io_mod.getIo());
    const start = try session_replay.readLineAt(
        alloc,
        log,
        positions.prior.through_event_log_bytes,
        positions.proposed.through_event_log_bytes,
        null,
    ) orelse return error.TestUnexpectedResult;
    defer alloc.free(start.bytes);
    try replaceFrameByteForTest(
        alloc,
        log,
        start.next_offset,
        positions.proposed.through_event_log_bytes,
        "\"schema_version\":1",
        '9',
    );
}

const PublicationBytesSnapshot = struct {
    events: []u8,
    watermark: []u8,
    intent: []u8,

    fn deinit(self: *PublicationBytesSnapshot, alloc: Allocator) void {
        alloc.free(self.events);
        alloc.free(self.watermark);
        alloc.free(self.intent);
        self.* = undefined;
    }

    fn expectEqual(self: PublicationBytesSnapshot, other: PublicationBytesSnapshot) !void {
        try std.testing.expectEqualSlices(u8, self.events, other.events);
        try std.testing.expectEqualSlices(u8, self.watermark, other.watermark);
        try std.testing.expectEqualSlices(u8, self.intent, other.intent);
    }
};

fn capturePublicationBytesForTest(
    alloc: Allocator,
    root: *Root,
    session_id: []const u8,
    generation: Identifier,
) !PublicationBytesSnapshot {
    var dir = try openSessionDir(&root.sessions.?, session_id, .read_only);
    defer dir.close();
    var log = try openManagedFile(&dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    const events = try io_mod.readFileToEnd(alloc, &log, 16 * 1024 * 1024);
    errdefer alloc.free(events);
    const name = try watermarkName(alloc, generation);
    defer alloc.free(name);
    const watermark = try readManagedFileAlloc(alloc, &dir, name, watermark_max_bytes, null);
    errdefer alloc.free(watermark);
    const intent = try readManagedFileAlloc(
        alloc,
        &dir,
        publication_intent_file,
        publication_intent_max_bytes,
        null,
    );
    return .{ .events = events, .watermark = watermark, .intent = intent };
}

test "state replacement uses the durable state timestamp for every frame" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-replacement-timestamp", 10);
    defer initial.deinit(alloc);

    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const first_replacement_byte = loaded.position.through_event_log_bytes;
    var replacement = try stateWithTurn(alloc, loaded.state, 4242);
    defer replacement.deinit(alloc);

    const committed = try loaded.commitStateReplacement(
        alloc,
        replacement,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expectEqual(@as(i64, 4242), loaded.state.updated_at_ms);

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    var offset = first_replacement_byte;
    var frame_count: usize = 0;
    while (offset < committed.through_event_log_bytes) {
        const line = try session_replay.readLineAt(
            alloc,
            log,
            offset,
            committed.through_event_log_bytes,
            null,
        ) orelse return error.TestUnexpectedResult;
        defer alloc.free(line.bytes);
        var envelope = try session_event.decodeFrame(alloc, line.bytes, null);
        defer envelope.deinit(alloc);
        try std.testing.expectEqual(@as(i64, 4242), envelope.timestamp_ms);
        offset = line.next_offset;
        frame_count += 1;
    }
    try std.testing.expect(frame_count >= 3);

    var replayed = try session_replay.replayBoundary(alloc, log, committed, null);
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 4242), replayed.updated_at_ms);
}

test "usage sidecar restores exact optional metrics after read-only and writable resume" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-usage-sidecar-resume", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        7,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "provider/model",
        .total_cost = 0.02,
        .input_tokens = 20,
        .output_tokens = 5,
        .cache_read_tokens = 4,
        .cache_write_tokens = 1,
        .reasoning_tokens = 3,
        .billable_web_search_calls = 0,
    });
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        20,
        .retry_expected_tail,
        .{},
    );
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        21,
        .retry_expected_tail,
        .{},
    );
    loaded.deinit(alloc);

    var read_only = try temp.root.loadReadOnly(
        alloc,
        initial.id,
        .{},
    );
    defer read_only.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 1), read_only.usage.?.request_count);
    try std.testing.expectEqual(@as(?u64, 3), read_only.usage.?.reasoning_tokens);
    try std.testing.expectEqual(
        @as(?u64, 1),
        read_only.usage.?.models[0].request_count,
    );
    try std.testing.expectEqual(
        @as(?u64, 3),
        read_only.usage.?.models[0].reasoning_tokens,
    );

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 1), resumed.state.usage.?.request_count);
    try std.testing.expectEqual(@as(?u64, 3), resumed.state.usage.?.reasoning_tokens);
}

test "failed canonical append leaves the previous usage sidecar unchanged" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-usage-sidecar-append-failure", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const before = try readManagedFileAlloc(
        alloc,
        &loaded.log.dir,
        session_usage_sidecar.sidecar_file,
        session_usage_sidecar.max_sidecar_bytes,
        null,
    );
    defer alloc.free(before);

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    usage.finishInvocation(sequence, 1, .unbilled);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_event_append };
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            .{ .usage_checkpointed = .{ .usage = snapshot } },
            20,
            .rollback_before_adapter_continue,
            .{ .test_controls = failure.test_controls() },
        ),
    );

    const after = try readManagedFileAlloc(
        alloc,
        &loaded.log.dir,
        session_usage_sidecar.sidecar_file,
        session_usage_sidecar.max_sidecar_bytes,
        null,
    );
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "usage sidecar publication stays inside the canonical commit boundary" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-usage-sidecar-commit-pair", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    const Probe = struct {
        root: *Root,
        alloc: Allocator,
        session_id: []const u8,
        read_blocked: bool = false,
        read_succeeded: bool = false,

        fn boundary(raw: ?*anyopaque, point: Boundary) !void {
            if (point != .before_usage_sidecar_write) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            var state = self.root.loadReadOnly(
                self.alloc,
                self.session_id,
                .{ .commit_lock_deadline_ms = 0 },
            ) catch |err| {
                self.read_blocked =
                    err == error.SessionCommitBoundaryUnavailable;
                return;
            };
            state.deinit(self.alloc);
            self.read_succeeded = true;
        }
    };
    var probe = Probe{
        .root = &temp.root,
        .alloc = alloc,
        .session_id = initial.id,
    };
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    usage.finishInvocation(sequence, 1, .unbilled);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        20,
        .retry_expected_tail,
        .{ .test_controls = .{
            .context = &probe,
            .boundary_fn = Probe.boundary,
        } },
    );
    try std.testing.expect(probe.read_blocked);
    try std.testing.expect(!probe.read_succeeded);

    var read_only = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer read_only.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 2), read_only.usage.?.next_sequence);
    try std.testing.expectEqual(@as(usize, 0), read_only.usage.?.incidents.len);
}

test "torn exact settlement restores stale sidecar backlog over settled rollback" {
    const Checkpoint = struct {
        fn persist(_: *anyopaque, _: session_usage.Snapshot, _: ?*const std.atomic.Value(bool)) !void {}
    };
    const RejectPublication = struct {
        fn publish(_: *anyopaque, event: session_usage.usage_report.ProfileEvent, _: ?*const std.atomic.Value(bool)) !void {
            if (event == .generation) return error.InjectedPublicationFailure;
        }
    };
    const PublicationProbe = struct {
        generations: usize = 0,

        fn publish(raw: *anyopaque, event: session_usage.usage_report.ProfileEvent, _: ?*const std.atomic.Value(bool)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (event == .generation) self.generations += 1;
        }
    };
    const TearSidecar = struct {
        dir: *io_mod.VerifiedDir,
        torn: bool = false,
        const stale_file = "usage-v2.stale-test";

        fn boundary(raw: ?*anyopaque, point: Boundary) !void {
            if (point != .before_usage_sidecar_write) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try self.dir.dir.rename(
                session_usage_sidecar.sidecar_file,
                self.dir.dir,
                stale_file,
                io_mod.getIo(),
            );
            try self.dir.dir.createDir(
                io_mod.getIo(),
                session_usage_sidecar.sidecar_file,
                std.Io.File.Permissions.fromMode(0o700),
            );
            self.torn = true;
        }

        fn restore(self: *@This()) !void {
            try self.dir.dir.deleteDir(
                io_mod.getIo(),
                session_usage_sidecar.sidecar_file,
            );
            try self.dir.dir.rename(
                stale_file,
                self.dir.dir,
                session_usage_sidecar.sidecar_file,
                io_mod.getIo(),
            );
        }
    };

    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-usage-torn-exact", 10);
    defer initial.deinit(alloc);
    {
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        const completion: types.ModelCompletion = .{
            .generation_id = "response-torn-log",
            .billing = .{
                .created_at_ms = 100,
                .model = "codex/gpt-test",
                .total_cost = 0,
                .input_tokens = 17,
                .output_tokens = 7,
                .cache_read_tokens = 2,
                .cache_write_tokens = 0,
                .reasoning_tokens = 1,
                .billable_web_search_calls = 0,
            },
        };

        var checkpoint_context: u8 = 0;
        var publication_context: u8 = 0;
        var bridge = session_usage.Usage.initFresh();
        defer bridge.deinit(alloc);
        bridge.configureCheckpointSink(.{
            .context = &checkpoint_context,
            .allocator = alloc,
            .persist = Checkpoint.persist,
        });
        bridge.configurePublicationSink(.{
            .context = &publication_context,
            .allocator = alloc,
            .publish = RejectPublication.publish,
        });
        const bridge_observation = try session_usage.InvocationObservation.begin(&bridge);
        try bridge_observation.complete(alloc, completion, .{ .exact = .codex });
        var bridge_snapshot = try bridge.snapshot(alloc);
        defer bridge_snapshot.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), bridge_snapshot.pending.len);
        try std.testing.expectEqual(@as(usize, 1), bridge_snapshot.publication_backlog.len);
        _ = try loaded.appendEvent(
            alloc,
            .{ .usage_checkpointed = .{ .usage = bridge_snapshot } },
            20,
            .retry_expected_tail,
            .{},
        );

        var settled = session_usage.Usage.initFresh();
        defer settled.deinit(alloc);
        const settled_observation = try session_usage.InvocationObservation.begin(&settled);
        try settled_observation.complete(alloc, completion, .{ .exact = .codex });
        var settled_snapshot = try settled.snapshot(alloc);
        defer settled_snapshot.deinit(alloc);
        try std.testing.expectEqual(@as(u64, 17), settled_snapshot.input_tokens);
        try std.testing.expectEqual(@as(usize, 0), settled_snapshot.pending.len);

        var tear = TearSidecar{ .dir = &loaded.log.dir };
        _ = try loaded.appendEvent(
            alloc,
            .{ .usage_checkpointed = .{ .usage = settled_snapshot } },
            30,
            .retry_expected_tail,
            .{ .test_controls = .{
                .context = &tear,
                .boundary_fn = TearSidecar.boundary,
            } },
        );
        try std.testing.expect(tear.torn);
        try tear.restore();
    }

    var read_only = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer read_only.deinit(alloc);
    const recovered = read_only.usage.?;
    try std.testing.expectEqual(@as(u64, 17), recovered.input_tokens);
    try std.testing.expectEqual(@as(u64, 7), recovered.output_tokens);
    try std.testing.expectEqual(@as(?u64, null), recovered.request_count);
    try std.testing.expectEqual(@as(usize, 0), recovered.pending.len);
    try std.testing.expectEqual(@as(usize, 1), recovered.publication_backlog.len);
    try std.testing.expectEqual(@as(usize, 1), recovered.incidents.len);

    var publication = PublicationProbe{};
    var resumed = session_usage.Usage.initFresh();
    defer resumed.deinit(alloc);
    resumed.configurePublicationSink(.{
        .context = &publication,
        .allocator = alloc,
        .publish = PublicationProbe.publish,
    });
    try resumed.restore(alloc, recovered, 1);
    var final = try resumed.snapshot(alloc);
    defer final.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), publication.generations);
    try std.testing.expectEqual(@as(u64, 17), final.input_tokens);
    try std.testing.expectEqual(@as(u64, 7), final.output_tokens);
    try std.testing.expectEqual(@as(?u64, null), final.request_count);
    try std.testing.expectEqual(@as(usize, 0), final.pending.len);
    try std.testing.expectEqual(@as(usize, 0), final.publication_backlog.len);
}

test "indeterminate canonical usage retry repairs the rich sidecar" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-usage-sidecar-retry", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        7,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "provider/model",
        .total_cost = 0.02,
        .input_tokens = 20,
        .output_tokens = 5,
        .cache_read_tokens = 4,
        .cache_write_tokens = 1,
        .reasoning_tokens = 3,
        .billable_web_search_calls = 0,
    });
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    var current = try loaded.state.dupe(alloc);
    defer current.deinit(alloc);
    if (current.usage) |*prior| prior.deinit(alloc);
    current.usage = try session_usage.dupeSnapshotOwned(alloc, snapshot);
    current.updated_at_ms = 20;

    var failure = BoundaryFailure{ .target = .after_target_namespace_sync };
    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        loaded.appendEvent(
            alloc,
            .{ .usage_checkpointed = .{ .usage = snapshot } },
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    try loaded.retryDegradedWithStateReplacement(alloc, current, .{});
    try std.testing.expectEqual(@as(?u64, 1), loaded.state.usage.?.request_count);
    try std.testing.expectEqual(@as(?u64, 3), loaded.state.usage.?.reasoning_tokens);
    loaded.deinit(alloc);

    var read_only = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer read_only.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 1), read_only.usage.?.request_count);
    try std.testing.expectEqual(@as(?u64, 3), read_only.usage.?.reasoning_tokens);
    try std.testing.expectEqual(@as(usize, 0), read_only.usage.?.incidents.len);
}

test "unwritable usage sidecar keeps canonical usage resumable and incomplete" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-usage-sidecar-failure", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});

    try loaded.log.dir.dir.deleteFile(
        io_mod.getIo(),
        session_usage_sidecar.sidecar_file,
    );
    try loaded.log.dir.dir.createDir(
        io_mod.getIo(),
        session_usage_sidecar.sidecar_file,
        std.Io.File.Permissions.fromMode(0o700),
    );

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const sequence = try usage.reserveInvocation();
    try usage.finishObservedInvocation(
        alloc,
        sequence,
        7,
        .observed_generation,
        "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        "https://ai-gateway.vercel.sh",
        null,
    );
    try usage.applyGeneration(alloc, .{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .model = "provider/model",
        .total_cost = 0.02,
        .input_tokens = 20,
        .output_tokens = 5,
        .cache_read_tokens = 4,
        .cache_write_tokens = 1,
        .reasoning_tokens = 3,
        .billable_web_search_calls = 0,
    });
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        20,
        .retry_expected_tail,
        .{},
    );
    loaded.deinit(alloc);

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.02),
        resumed.state.usage.?.total_cost,
        1e-12,
    );
    try std.testing.expect(resumed.state.usage.?.request_count == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        resumed.state.usage.?.incidents.len,
    );
    try std.testing.expectEqual(
        @as(i64, 20),
        resumed.state.usage.?.incidents[0].occurred_at_ms,
    );
}

test "writable recovery rolls an invalid replacement back to its valid prior" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-invalid-replacement-recovery", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var loaded_owned = true;
    defer if (loaded_owned) loaded.deinit(alloc);
    const positions = try leavePendingReplacementForTest(alloc, &loaded, 20);
    try corruptReplacementCommitTimestampForTest(alloc, &loaded, positions);
    loaded.deinit(alloc);
    loaded_owned = false;

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    try std.testing.expect(positionsEqual(positions.prior, resumed.position));
    try std.testing.expectEqual(@as(usize, 0), resumed.state.history.len);
    try std.testing.expectEqual(
        positions.prior.through_event_log_bytes,
        try resumed.log.eventLogLengthForTest(),
    );
    try std.testing.expect(!(try resumed.log.entryExistsForTest(publication_intent_file)));
    resumed.deinit(alloc);

    var repeated = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer repeated.deinit(alloc);
    try std.testing.expect(positionsEqual(positions.prior, repeated.position));
    try std.testing.expectEqual(@as(usize, 0), repeated.state.history.len);
}

test "publication recovery preserves bytes on reader and resource failures" {
    const RecoveryFailure = struct {
        target: Boundary,
        failure: anyerror,

        fn hit(raw: ?*anyopaque, point: Boundary) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (point == self.target) return self.failure;
        }

        fn testControls(self: *@This()) TestControls {
            return .{ .context = self, .boundary_fn = hit };
        }
    };
    const rows = [_]struct {
        id: []const u8,
        target: Boundary,
        failure: anyerror,
        current_at_prior: bool = false,
    }{
        .{
            .id = "session-proposed-read-failure",
            .target = .before_recovery_proposed_validation,
            .failure = error.ReadFailed,
        },
        .{
            .id = "session-prior-read-failure",
            .target = .before_recovery_prior_validation,
            .failure = error.ReadFailed,
        },
        .{
            .id = "session-proposed-resource-failure",
            .target = .before_recovery_proposed_validation,
            .failure = error.OutOfMemory,
        },
        .{
            .id = "session-current-prior-read-failure",
            .target = .before_recovery_prior_validation,
            .failure = error.ReadFailed,
            .current_at_prior = true,
        },
    };

    for (rows) |row| {
        const alloc = std.testing.allocator;
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        var initial = try testState(alloc, row.id, 10);
        defer initial.deinit(alloc);
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        var loaded_owned = true;
        defer if (loaded_owned) loaded.deinit(alloc);
        const positions = try leavePendingReplacementForTest(alloc, &loaded, 20);
        if (row.current_at_prior) {
            const watermark = try encodeWatermark(alloc, initial.id, positions.prior);
            defer alloc.free(watermark);
            const name = try watermarkName(alloc, positions.prior.log_generation);
            defer alloc.free(name);
            try durableReplace(alloc, &loaded.log.dir, name, watermark);
        } else {
            try corruptReplacementCommitTimestampForTest(alloc, &loaded, positions);
        }
        loaded.deinit(alloc);
        loaded_owned = false;
        var before = try capturePublicationBytesForTest(
            alloc,
            &temp.root,
            initial.id,
            positions.proposed.log_generation,
        );
        defer before.deinit(alloc);
        var failure = RecoveryFailure{ .target = row.target, .failure = row.failure };

        try std.testing.expectError(
            row.failure,
            temp.root.resumeForWrite(
                alloc,
                initial.id,
                .{ .test_controls = failure.testControls() },
            ),
        );
        var after = try capturePublicationBytesForTest(
            alloc,
            &temp.root,
            initial.id,
            positions.proposed.log_generation,
        );
        defer after.deinit(alloc);
        try before.expectEqual(after);
    }
}

test "publication recovery preserves unsupported and invalid prior transactions" {
    const Case = enum {
        unsupported_proposed,
        unsupported_replacement_chunk,
        invalid_prior,
    };
    const cases = [_]Case{
        .unsupported_proposed,
        .unsupported_replacement_chunk,
        .invalid_prior,
    };
    for (cases) |case| {
        const alloc = std.testing.allocator;
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        const session_id = switch (case) {
            .unsupported_proposed => "session-unsupported-proposed",
            .unsupported_replacement_chunk => "session-unsupported-replacement-chunk",
            .invalid_prior => "session-invalid-prior",
        };
        var initial = try testState(alloc, session_id, 10);
        defer initial.deinit(alloc);
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        var loaded_owned = true;
        defer if (loaded_owned) loaded.deinit(alloc);
        const initial_position = loaded.position;
        if (case == .invalid_prior) {
            _ = try loaded.appendEvent(
                alloc,
                .{ .preferences_changed = .{ .fast_mode = true } },
                15,
                .retry_expected_tail,
                .{},
            );
        }
        const positions = try leavePendingReplacementForTest(alloc, &loaded, 20);
        switch (case) {
            .unsupported_proposed => {
                var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
                defer log.close(io_mod.getIo());
                try replaceFrameByteForTest(
                    alloc,
                    log,
                    positions.prior.through_event_log_bytes,
                    positions.proposed.through_event_log_bytes,
                    "\"schema_version\":1",
                    '9',
                );
            },
            .unsupported_replacement_chunk => {
                try corruptReplacementChunkSchemaForTest(alloc, &loaded, positions);
            },
            .invalid_prior => {
                try corruptReplacementCommitTimestampForTest(alloc, &loaded, positions);
                var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
                defer log.close(io_mod.getIo());
                try replaceFrameByteForTest(
                    alloc,
                    log,
                    initial_position.through_event_log_bytes,
                    positions.prior.through_event_log_bytes,
                    "\"seq\":2",
                    '3',
                );
            },
        }
        loaded.deinit(alloc);
        loaded_owned = false;
        var before = try capturePublicationBytesForTest(
            alloc,
            &temp.root,
            initial.id,
            positions.proposed.log_generation,
        );
        defer before.deinit(alloc);

        const expected_error = switch (case) {
            .unsupported_proposed,
            .unsupported_replacement_chunk,
            => error.UnsupportedSessionSchema,
            .invalid_prior => error.InvalidSessionFormat,
        };
        try std.testing.expectError(
            expected_error,
            temp.root.resumeForWrite(alloc, initial.id, .{}),
        );
        var after = try capturePublicationBytesForTest(
            alloc,
            &temp.root,
            initial.id,
            positions.proposed.log_generation,
        );
        defer after.deinit(alloc);
        try before.expectEqual(after);
    }
}

test "publication recovery preserves a watermark outside the intent pair" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-mismatched-intent-watermark", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var loaded_owned = true;
    defer if (loaded_owned) loaded.deinit(alloc);
    const initial_position = loaded.position;
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        15,
        .retry_expected_tail,
        .{},
    );
    const positions = try leavePendingReplacementForTest(alloc, &loaded, 20);
    const watermark = try encodeWatermark(alloc, initial.id, initial_position);
    defer alloc.free(watermark);
    const name = try watermarkName(alloc, initial_position.log_generation);
    defer alloc.free(name);
    try durableReplace(alloc, &loaded.log.dir, name, watermark);
    loaded.deinit(alloc);
    loaded_owned = false;
    var before = try capturePublicationBytesForTest(
        alloc,
        &temp.root,
        initial.id,
        positions.proposed.log_generation,
    );
    defer before.deinit(alloc);

    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        temp.root.resumeForWrite(alloc, initial.id, .{}),
    );
    var after = try capturePublicationBytesForTest(
        alloc,
        &temp.root,
        initial.id,
        positions.proposed.log_generation,
    );
    defer after.deinit(alloc);
    try before.expectEqual(after);
}

test "display projection waits for first prompt and preserves derived title" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-display-title-freeze", 10);
    defer initial.deinit(alloc);

    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    var initial_display = try session_display_metadata.readSidecarOrFallback(alloc, &loaded.log.dir);
    defer initial_display.deinit(alloc);
    try std.testing.expect(!initial_display.present);

    var first_state = try stateWithPrompt(
        alloc,
        loaded.state,
        20,
        "first prompt title should freeze after this",
        "first response",
    );
    defer first_state.deinit(alloc);
    _ = try loaded.commitStateReplacement(
        alloc,
        first_state,
        .recovery,
        .retry_expected_tail,
        .{},
    );

    var first_display = try session_display_metadata.readSidecarOrFallback(alloc, &loaded.log.dir);
    defer first_display.deinit(alloc);
    try std.testing.expect(first_display.present);
    try std.testing.expectEqualStrings(
        "first prompt title should freeze after this",
        first_display.title,
    );

    var replacement_state = try stateWithPrompt(
        alloc,
        loaded.state,
        30,
        "replacement prompt must not become the title",
        "replacement response",
    );
    defer replacement_state.deinit(alloc);
    _ = try loaded.commitStateReplacement(
        alloc,
        replacement_state,
        .recovery,
        .retry_expected_tail,
        .{},
    );

    var preserved_display = try session_display_metadata.readSidecarOrFallback(alloc, &loaded.log.dir);
    defer preserved_display.deinit(alloc);
    try std.testing.expect(preserved_display.present);
    try std.testing.expectEqualStrings(
        "first prompt title should freeze after this",
        preserved_display.title,
    );
}

test "state replacement preserves subagent child identity" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-subagent-child", 10);
    defer initial.deinit(alloc);
    initial.subagent_child = true;

    {
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        defer loaded.deinit(alloc);
        var replacement = try loaded.state.dupe(alloc);
        defer replacement.deinit(alloc);
        replacement.updated_at_ms = 20;
        replacement.subagent_child = false;
        _ = try loaded.commitStateReplacement(
            alloc,
            replacement,
            .recovery,
            .retry_expected_tail,
            .{},
        );
        try std.testing.expect(loaded.state.subagent_child);
    }

    var reloaded = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer reloaded.deinit(alloc);
    try std.testing.expect(reloaded.subagent_child);
}

fn historyEvent(state: session_codec.DurableSessionState) session_event.Event {
    return .{ .history_turn_committed = .{
        .conversation_language = state.conversation_language,
        .total_input_tokens = state.total_input_tokens,
        .total_output_tokens = state.total_output_tokens,
        .turn = state.history[state.history.len - 1],
    } };
}

test "schema v3 exact operations accept dotted session IDs" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session.v3.branch", 10);
    defer initial.deinit(alloc);

    var started = try temp.root.startWritableSession(alloc, initial, .{});
    started.deinit(alloc);

    var read_only = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer read_only.deinit(alloc);
    try std.testing.expectEqualStrings(initial.id, read_only.id);

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(initial.id, resumed.state.id);
}

test "schema v3 exact operations accept 255 byte session IDs" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var session_id: [255]u8 = undefined;
    @memset(&session_id, 'a');
    var initial = try testState(alloc, &session_id, 10);
    defer initial.deinit(alloc);

    var started = try temp.root.startWritableSession(alloc, initial, .{});
    started.deinit(alloc);

    var read_only = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer read_only.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &session_id, read_only.id);

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &session_id, resumed.state.id);
}

test "schema v3 exact operations reject unsafe session IDs" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);

    const invalid_ids = [_][]const u8{
        ".",
        "..",
        "nested/session",
        "nested\\session",
    };
    for (invalid_ids) |session_id| {
        try std.testing.expectError(
            error.InvalidSessionId,
            temp.root.loadReadOnly(alloc, session_id, .{}),
        );
        try std.testing.expectError(
            error.InvalidSessionId,
            temp.root.resumeForWrite(alloc, session_id, .{}),
        );
    }

    const unsupported = [_]u8{ 0xff, 'a' };
    try std.testing.expectError(
        error.InvalidSessionId,
        temp.root.loadReadOnly(alloc, &unsupported, .{}),
    );
    try std.testing.expectError(
        error.InvalidSessionId,
        temp.root.resumeForWrite(alloc, &unsupported, .{}),
    );

    var too_long: [256]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expectError(
        error.InvalidSessionId,
        temp.root.loadReadOnly(alloc, &too_long, .{}),
    );
    try std.testing.expectError(
        error.InvalidSessionId,
        temp.root.resumeForWrite(alloc, &too_long, .{}),
    );
}

test "authority creation resolves marker absence as an uncommitted orphan" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var state = try testState(alloc, "session-authority-absent", 10);
    defer state.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_authority_intent_sync };

    try std.testing.expectError(
        error.SessionStartIndeterminate,
        temp.root.startWritableSession(alloc, state, .{ .test_controls = failure.test_controls() }),
    );
    try std.testing.expectError(
        error.SessionNotFound,
        temp.root.resumeForWrite(alloc, state.id, .{}),
    );
    try std.testing.expect(!(try temp.root.entryExistsForTest(
        alloc,
        state.id,
        "authority.pending.json",
    )));
    try std.testing.expect(!(try temp.root.entryExistsForTest(
        alloc,
        state.id,
        "authority.json",
    )));
}

test "authority creation resolves an exact proposed marker and canonical pair" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var state = try testState(alloc, "session-authority-proposed", 10);
    defer state.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_authority_marker_rename };

    try std.testing.expectError(
        error.SessionStartIndeterminate,
        temp.root.startWritableSession(alloc, state, .{ .test_controls = failure.test_controls() }),
    );
    var loaded = try temp.root.resumeForWrite(alloc, state.id, .{});
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings(state.id, loaded.state.id);
    try std.testing.expect(try temp.root.entryExistsForTest(
        alloc,
        state.id,
        "authority.json",
    ));
    try std.testing.expect(!(try temp.root.entryExistsForTest(
        alloc,
        state.id,
        "authority.pending.json",
    )));
}

test "commit boundary hides synced bytes until watermark publication" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-commit-boundary", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);

    var observed_history_len: usize = std.math.maxInt(usize);
    const PauseReader = struct {
        root: *Root,
        alloc: Allocator,
        session_id: []const u8,
        observed: *usize,

        fn hit(raw: ?*anyopaque, point: Boundary) !void {
            if (point != .after_event_sync) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            var state = try self.root.loadReadOnly(self.alloc, self.session_id, .{});
            defer state.deinit(self.alloc);
            self.observed.* = state.history.len;
        }
    };
    var pause = PauseReader{
        .root = &temp.root,
        .alloc = alloc,
        .session_id = initial.id,
        .observed = &observed_history_len,
    };
    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{ .test_controls = .{ .context = &pause, .boundary_fn = PauseReader.hit } },
    );

    try std.testing.expectEqual(@as(usize, 0), observed_history_len);
    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.history.len);
}

test "publication intent remains a read fence until writable resolution" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-publication-intent", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_commit_intent_sync };

    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    loaded.deinit(alloc);
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        temp.root.loadReadOnly(alloc, initial.id, .{}),
    );
    var resolved = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resolved.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), resolved.state.history.len);
}

test "publication indeterminacy blocks later append until explicit retry" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-publication-same-writer", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_target_namespace_sync };

    try std.testing.expectError(
        error.SessionCommitIndeterminate,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );

    const ConfirmationTrace = struct {
        commit_locks: usize = 0,

        fn lock(raw: ?*anyopaque, kind: LockKind) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (kind == .commit) self.commit_locks += 1;
        }
    };
    var trace: ConfirmationTrace = .{};
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            .{ .preferences_changed = .{ .fast_mode = true } },
            30,
            .retry_expected_tail,
            .{ .test_controls = .{
                .context = &trace,
                .lock_fn = ConfirmationTrace.lock,
            } },
        ),
    );
    try loaded.retryDegradedWithStateReplacement(alloc, next, .{
        .test_controls = .{
            .context = &trace,
            .lock_fn = ConfirmationTrace.lock,
        },
    });
    try std.testing.expect(trace.commit_locks > 0);
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), loaded.state.history.len);
    try std.testing.expect(loaded.state.preferences.fast_mode);
}

test "intent cleanup pending confirms the namespace before a later append" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-intent-cleanup", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_commit_intent_remove };

    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{ .test_controls = failure.test_controls() },
    );

    const ConfirmationTrace = struct {
        commit_locks: usize = 0,
        confirmed_before_append: bool = false,

        fn lock(raw: ?*anyopaque, kind: LockKind) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (kind == .commit) self.commit_locks += 1;
        }

        fn boundary(raw: ?*anyopaque, point: Boundary) !void {
            if (point != .after_event_append) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.confirmed_before_append = self.commit_locks > 0;
        }
    };
    var trace: ConfirmationTrace = .{};
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
        .retry_expected_tail,
        .{ .test_controls = .{
            .context = &trace,
            .boundary_fn = ConfirmationTrace.boundary,
            .lock_fn = ConfirmationTrace.lock,
        } },
    );
    try std.testing.expect(trace.confirmed_before_append);
}

test "writable recovery truncates a complete provisional tail without resetting compaction accounting" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-provisional-tail", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        15,
        .retry_expected_tail,
        .{},
    );
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    const generation_base_seq = loaded.generation_base_seq;
    const generation_base_bytes = loaded.generation_base_bytes;
    const committed_bytes = loaded.position.through_event_log_bytes;
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    loaded.deinit(alloc);
    var read_only = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer read_only.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), read_only.history.len);

    var resumed = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(
        committed_bytes,
        try resumed.log.eventLogLengthForTest(),
    );
    try std.testing.expectEqual(generation_base_seq, resumed.generation_base_seq);
    try std.testing.expectEqual(generation_base_bytes, resumed.generation_base_bytes);

    var manifest = try loadManifest(alloc, &resumed.log.dir);
    defer manifest.deinit(alloc);
    try std.testing.expectEqual(generation_base_seq, manifest.generation_base_seq);
    try std.testing.expectEqual(generation_base_bytes, manifest.generation_base_bytes);
}

test "writable resume preserves the event log when the watermark is invalid" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-invalid-watermark-preserves-log", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var loaded_owned = true;
    defer if (loaded_owned) loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_event_sync };
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );

    var invalid_position = loaded.position;
    invalid_position.through_event_log_bytes -= 1;
    const watermark = try encodeWatermark(alloc, initial.id, invalid_position);
    defer alloc.free(watermark);
    const watermark_name = try watermarkName(alloc, invalid_position.log_generation);
    defer alloc.free(watermark_name);
    try durableReplace(alloc, &loaded.log.dir, watermark_name, watermark);
    const before_events = try readManagedFileAlloc(
        alloc,
        &loaded.log.dir,
        events_file,
        16 * 1024 * 1024,
        null,
    );
    defer alloc.free(before_events);
    const before_watermark = try readManagedFileAlloc(
        alloc,
        &loaded.log.dir,
        watermark_name,
        watermark_max_bytes,
        null,
    );
    defer alloc.free(before_watermark);
    loaded.deinit(alloc);
    loaded_owned = false;

    try std.testing.expectError(
        error.InvalidSessionFormat,
        temp.root.resumeForWrite(alloc, initial.id, .{}),
    );
    var dir = try openSessionDir(&temp.root.sessions.?, initial.id, .read_only);
    defer dir.close();
    const after_events = try readManagedFileAlloc(
        alloc,
        &dir,
        events_file,
        16 * 1024 * 1024,
        null,
    );
    defer alloc.free(after_events);
    const after_watermark = try readManagedFileAlloc(
        alloc,
        &dir,
        watermark_name,
        watermark_max_bytes,
        null,
    );
    defer alloc.free(after_watermark);
    try std.testing.expectEqualSlices(u8, before_events, after_events);
    try std.testing.expectEqualSlices(u8, before_watermark, after_watermark);
}

test "retry eligible failure captures the exact expected event tail" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-failed-tail-capture", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    const prior = loaded.position;
    var failure = BoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );

    const failed = loaded.degradedTail() orelse return error.TestExpectedEqual;
    try std.testing.expect(positionsEqual(prior, failed.prior));
    try std.testing.expectEqual(
        prior.through_event_log_bytes + failed.bytes.len,
        failed.proposed.through_event_log_bytes,
    );
    try std.testing.expectEqualSlices(
        u8,
        &session_projection.sha256(failed.bytes),
        &failed.sha256,
    );
    switch (failed.kind) {
        .event => |event_id| try std.testing.expectEqualSlices(
            u8,
            &failed.proposed.through_event_id,
            &event_id,
        ),
        .state_replacement => return error.TestExpectedEqual,
    }
}

test "degraded retry publishes only the exact expected event tail" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-expected-tail-retry", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    const expected = loaded.degradedTail().?.proposed;

    try loaded.retryDegradedWithStateReplacement(alloc, next, .{});

    try std.testing.expect(loaded.degradedTail() == null);
    try std.testing.expect(positionsEqual(expected, loaded.position));
    try std.testing.expectEqual(@as(usize, 1), loaded.state.history.len);
    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.history.len);
}

test "degraded retry replaces current state when the expected tail is not exact" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-replacement-fallback", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{ .test_controls = failure.test_controls() },
        ),
    );
    const failed = loaded.degradedTail().?;
    const prior = failed.prior;
    const failed_proposed = failed.proposed;
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
    try log.writePositionalAll(
        io_mod.getIo(),
        "!",
        prior.through_event_log_bytes,
    );
    try log.sync(io_mod.getIo());
    log.close(io_mod.getIo());

    try loaded.retryDegradedWithStateReplacement(alloc, next, .{});

    try std.testing.expect(loaded.degradedTail() == null);
    try std.testing.expect(loaded.position.through_seq > failed_proposed.through_seq);
    try std.testing.expectEqual(@as(usize, 1), loaded.state.history.len);
    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.history.len);
    try std.testing.expectEqualStrings(
        "world",
        replayed.history[0].assistant.assistant,
    );
}

test "rollback required failure is excluded from generic degraded retry" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-commit-first-exclusion", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    const prior = loaded.position;
    var failure = BoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .rollback_before_adapter_continue,
            .{ .test_controls = failure.test_controls() },
        ),
    );

    try std.testing.expect(loaded.degradedTail() == null);
    try std.testing.expect(positionsEqual(prior, loaded.position));
    try std.testing.expectEqual(
        prior.through_event_log_bytes,
        try loaded.log.eventLogLengthForTest(),
    );
}

test "resume handoff does not recreate a missing commit lock" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "handoff-missing-lock", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    try loaded.log.dir.dir.deleteFile(io_mod.getIo(), commit_lock_file);

    try std.testing.expectError(error.FileNotFound, loaded.confirmResumeHandoffBoundary(alloc, .{
        .commit_lock_deadline_ms = 0,
    }));
    try std.testing.expect(!try entryExists(&loaded.log.dir, commit_lock_file));
}

test "handoff header rejects missing and duplicate canonical fields" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const generation = "00112233445566778899aabbccddeeff";
    const invalid = [_][]const u8{
        "{\"schema_version\":1,\"log_generation\":\"" ++ generation ++ "\",\"seq\":1,\"event_id\":\"" ++ generation ++ "\",\"kind\":\"session_started\",\"payload\":{}}\n",
        "{\"schema_version\":1,\"log_generation\":\"" ++ generation ++ "\",\"seq\":1,\"event_id\":\"" ++ generation ++ "\",\"event_id\":\"" ++ generation ++ "\",\"kind\":\"session_started\",\"payload\":{}}\n",
        "{\"schema_version\":1,\"log_generation\":\"" ++ generation ++ "\",\"seq\":1,\"event_id\":\"" ++ generation ++ "\",\"timestamp_ms\":-1,\"kind\":\"session_started\",\"payload\":{}}\n",
    };
    for (invalid) |bytes| {
        var file = try tmp.dir.createFile(std.testing.io, "events.jsonl", .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, bytes);
        var prefix: [1024]u8 = undefined;
        const count = try file.readPositionalAll(std.testing.io, &prefix, 0);
        try std.testing.expectError(error.InvalidSessionFormat, parseHandoffHeader(alloc, prefix[0..count]));
    }
}

test "stored resume handoff uses bounded metadata and leaves session files unchanged" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "cold-handoff", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    const large = try alloc.alloc(u8, 4 * 1024 * 1024);
    defer alloc.free(large);
    @memset(large, 'x');
    var next = try stateWithPrompt(alloc, initial, 20, "saved", large);
    defer next.deinit(alloc);
    _ = try loaded.appendEvent(alloc, historyEvent(next), 20, .retry_expected_tail, .{});
    var file = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    var before = try file.stat(io_mod.getIo());
    before.atime = null;
    file.close(io_mod.getIo());
    loaded.deinit(alloc);

    var budget: [64 * 1024]u8 = undefined;
    var bounded = std.heap.FixedBufferAllocator.init(&budget);
    try temp.root.confirmStoredResumeHandoff(bounded.allocator(), initial.id, null);
    var directory = try openSessionDir(&temp.root.sessions.?, initial.id, .read_only);
    defer directory.close();
    file = try openManagedFile(&directory, events_file, .read_only);
    defer file.close(io_mod.getIo());
    var after = try file.stat(io_mod.getIo());
    after.atime = null;
    try std.testing.expect(std.meta.eql(before, after));
    try directory.dir.deleteFile(io_mod.getIo(), commit_lock_file);
    try std.testing.expectError(error.FileNotFound, temp.root.confirmStoredResumeHandoff(alloc, initial.id, null));
    try std.testing.expect(!try entryExists(&directory, commit_lock_file));
}

test "stored resume handoff rejects an impossible initial watermark" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "cold-handoff-invalid", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const name = try watermarkName(alloc, loaded.position.log_generation);
    defer alloc.free(name);
    for ([_]u64{ 0, 1 }) |sequence| {
        var corrupt = loaded.position;
        corrupt.through_seq = sequence;
        corrupt.through_event_id[0] ^= 1;
        const bytes = try encodeWatermark(alloc, initial.id, corrupt);
        defer alloc.free(bytes);
        try durableReplace(alloc, &loaded.log.dir, name, bytes);
        try std.testing.expectError(error.InvalidSessionFormat, temp.root.confirmStoredResumeHandoff(alloc, initial.id, null));
    }
}

test "retired resume boundary is revalidated against the current canonical position" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "retired-handoff", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const old = try loaded.resumeHandoffBoundary();
    try temp.root.confirmStoredResumeHandoff(alloc, initial.id, old);
    _ = try loaded.appendEvent(alloc, .{ .preferences_changed = .{ .fast_mode = true } }, 20, .retry_expected_tail, .{});
    try std.testing.expectError(error.InvalidSessionFormat, temp.root.confirmStoredResumeHandoff(alloc, initial.id, old));
    const current = try loaded.resumeHandoffBoundary();
    try loaded.log.dir.dir.deleteFile(io_mod.getIo(), manifest_file);
    try temp.root.confirmStoredResumeHandoff(alloc, initial.id, current);
    loaded.persistence_debt.derived_publication = true;
    try std.testing.expect(std.meta.eql(current, try loaded.resumeHandoffBoundary()));
    loaded.persistence_debt.canonical_replacement = true;
    try std.testing.expectError(error.SessionPersistenceDegraded, loaded.resumeHandoffBoundary());
}

test "resume handoff confirmation accepts the current durable metadata" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-handoff-metadata", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );

    try loaded.confirmResumeHandoffBoundary(alloc, .{
        .commit_lock_deadline_ms = 0,
    });
}

test "resume handoff confirmation rejects a corrupted watermark" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-handoff-corrupt-watermark", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    const name = try watermarkName(alloc, loaded.position.log_generation);
    defer alloc.free(name);
    try durableReplace(alloc, &loaded.log.dir, name, "{}\n");

    try std.testing.expectError(
        error.InvalidSessionFormat,
        loaded.confirmResumeHandoffBoundary(alloc, .{
            .commit_lock_deadline_ms = 0,
        }),
    );
}

test "checkpoint scheduling publishes an exact committed checkpoint" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-checkpoint", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(
        alloc,
        initial,
        .{ .checkpoint_interval = 1 },
    );
    defer loaded.deinit(alloc);
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);

    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{ .checkpoint_interval = 1 },
    );
    try std.testing.expect(try temp.root.entryExistsForTest(
        alloc,
        initial.id,
        "checkpoint.json",
    ));
    try loaded.validateCheckpointForTest(alloc);
}

test "checkpoint clean shutdown publishes when missing" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-checkpoint-shutdown", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    try std.testing.expect(!(try temp.root.entryExistsForTest(
        alloc,
        initial.id,
        "checkpoint.json",
    )));
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    try std.testing.expect(try temp.root.entryExistsForTest(
        alloc,
        initial.id,
        "checkpoint.json",
    ));
    try loaded.validateCheckpointForTest(alloc);
}

test "checkpoint clean shutdown preserves a valid bounded tail" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-checkpoint-bounded-tail", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    try loaded.writeCheckpointIfDue(alloc, true, .{});
    const checkpoint_seq = loaded.checkpoint_seq.?;
    const checkpoint_sha256 = loaded.checkpoint_sha256.?;
    const checkpoint_bytes = loaded.position.through_event_log_bytes;

    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    try std.testing.expectEqual(checkpoint_seq, loaded.checkpoint_seq.?);
    try std.testing.expectEqualSlices(
        u8,
        &checkpoint_sha256,
        &loaded.checkpoint_sha256.?,
    );

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    var opened = try loadOpenState(
        alloc,
        &loaded.log.dir,
        loaded.active_id,
        loaded.authority_id,
        log,
        loaded.position,
        null,
    );
    defer opened.state.deinit(alloc);
    try std.testing.expectEqual(ReplaySource.checkpoint, opened.source);
    try std.testing.expectEqual(
        loaded.position.through_event_log_bytes - checkpoint_bytes,
        opened.tail_bytes,
    );
    try std.testing.expect(opened.state.preferences.fast_mode);
}

test "final replacement policy tracks mutations after the last replacement" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-final-replacement-policy", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    try std.testing.expect(!loaded.needsFinalStateReplacement(false));
    var replacement = try loaded.state.dupe(alloc);
    defer replacement.deinit(alloc);
    _ = try loaded.commitStateReplacement(
        alloc,
        replacement,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    const generation_before_rebind = loaded.position.log_generation;
    _ = try loaded.appendEvent(
        alloc,
        .{ .workspace_rebound = .{
            .previous_workspace_root = loaded.state.workspace_root,
            .workspace_root = @constCast("/tmp/session-final-replacement-policy-b"),
        } },
        20,
        .retry_expected_tail,
        .{
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        },
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &generation_before_rebind,
        &loaded.position.log_generation,
    ));
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        30,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    _ = try loaded.appendEvent(
        alloc,
        .{ .workspace_rebound = .{
            .previous_workspace_root = loaded.state.workspace_root,
            .workspace_root = @constCast("/tmp/session-final-replacement-policy-c"),
        } },
        40,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    loaded.persistence_debt.canonical_replacement = true;
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = false } },
        45,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(loaded.needsFinalStateReplacement(false));

    var current = try loaded.state.dupe(alloc);
    defer current.deinit(alloc);
    _ = try loaded.commitStateReplacement(
        alloc,
        current,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    var append_failure = BoundaryFailure{ .target = .after_event_append };
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.appendEvent(
            alloc,
            .{ .workspace_rebound = .{
                .previous_workspace_root = loaded.state.workspace_root,
                .workspace_root = @constCast("/tmp/session-final-replacement-policy-failed"),
            } },
            50,
            .rollback_before_adapter_continue,
            .{ .test_controls = append_failure.test_controls() },
        ),
    );
    try std.testing.expect(loaded.needsFinalStateReplacement(false));

    _ = try loaded.commitStateReplacement(
        alloc,
        current,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expect(!loaded.needsFinalStateReplacement(false));

    var replacement_failure = BoundaryFailure{ .target = .after_event_append };
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        loaded.commitStateReplacement(
            alloc,
            current,
            .compaction,
            .rollback_before_adapter_continue,
            .{ .test_controls = replacement_failure.test_controls() },
        ),
    );
    try std.testing.expect(loaded.needsFinalStateReplacement(false));
}

test "event append rejects a truncated committed prefix without extending it" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-truncated-commit-prefix", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const prior = loaded.position;
    const truncated_length = prior.through_event_log_bytes - 1;

    {
        var log = try openManagedFile(
            &loaded.log.dir,
            events_file,
            .read_write,
        );
        defer log.close(io_mod.getIo());
        try log.setLength(io_mod.getIo(), truncated_length);
        try log.sync(io_mod.getIo());
    }

    try std.testing.expectError(
        error.InvalidSessionFormat,
        loaded.appendEvent(
            alloc,
            .{ .preferences_changed = .{ .fast_mode = true } },
            20,
            .retry_expected_tail,
            .{},
        ),
    );
    try std.testing.expect(positionsEqual(prior, loaded.position));
    try std.testing.expect(!loaded.state.preferences.fast_mode);
    try std.testing.expect(loaded.needsFinalStateReplacement(false));
    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    try std.testing.expectEqual(truncated_length, try log.length(io_mod.getIo()));
}

test "writable open state replays only the committed tail after a checkpoint" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-checkpoint-tail-open", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    const checkpoint_position = loaded.position;

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    var exact = try loadOpenState(
        alloc,
        &loaded.log.dir,
        loaded.active_id,
        loaded.authority_id,
        log,
        loaded.position,
        null,
    );
    defer exact.state.deinit(alloc);
    try std.testing.expectEqual(ReplaySource.checkpoint, exact.source);
    try std.testing.expectEqual(@as(u64, 0), exact.tail_bytes);

    const AllocationCheck = struct {
        fn run(
            failing_alloc: Allocator,
            dir: *io_mod.VerifiedDir,
            session_id: []const u8,
            authority_id: Identifier,
            event_log: std.Io.File,
            position: CommitPosition,
        ) !void {
            var opened = try loadOpenState(
                failing_alloc,
                dir,
                session_id,
                authority_id,
                event_log,
                position,
                null,
            );
            defer opened.state.deinit(failing_alloc);
            try std.testing.expectEqual(ReplaySource.checkpoint, opened.source);
        }
    };
    try std.testing.checkAllAllocationFailures(
        alloc,
        AllocationCheck.run,
        .{
            &loaded.log.dir,
            loaded.active_id,
            loaded.authority_id,
            log,
            loaded.position,
        },
    );

    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );
    var tailed = try loadOpenState(
        alloc,
        &loaded.log.dir,
        loaded.active_id,
        loaded.authority_id,
        log,
        loaded.position,
        null,
    );
    defer tailed.state.deinit(alloc);
    try std.testing.expectEqual(ReplaySource.checkpoint, tailed.source);
    try std.testing.expectEqual(
        loaded.position.through_event_log_bytes -
            checkpoint_position.through_event_log_bytes,
        tailed.tail_bytes,
    );
    try std.testing.expect(tailed.state.preferences.fast_mode);
    try std.testing.expectEqual(checkpoint_position.through_seq, tailed.checkpoint_seq.?);
}

test "writable open state falls back when the checkpoint is corrupt" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-corrupt-checkpoint-open", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    try durableReplace(alloc, &loaded.log.dir, checkpoint_file, "{bad");

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer log.close(io_mod.getIo());
    var opened = try loadOpenState(
        alloc,
        &loaded.log.dir,
        loaded.active_id,
        loaded.authority_id,
        log,
        loaded.position,
        null,
    );
    defer opened.state.deinit(alloc);
    try std.testing.expectEqual(ReplaySource.event_log, opened.source);
    try std.testing.expectEqual(ProjectionStatus.stale, opened.projection_status);
    try std.testing.expect(opened.checkpoint_seq == null);
    try std.testing.expectEqualStrings(initial.id, opened.state.id);
}

test "writable open state preserves compaction accounting after a stale event file fingerprint" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-stale-manifest-open", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{},
    );
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    const generation_base_seq = loaded.generation_base_seq;
    const generation_base_bytes = loaded.generation_base_bytes;

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
    defer log.close(io_mod.getIo());
    var first: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try log.readPositionalAll(io_mod.getIo(), &first, 0),
    );
    try log.writePositionalAll(io_mod.getIo(), &first, 0);
    try log.sync(io_mod.getIo());

    var opened = try loadOpenState(
        alloc,
        &loaded.log.dir,
        loaded.active_id,
        loaded.authority_id,
        log,
        loaded.position,
        null,
    );
    defer opened.state.deinit(alloc);
    try std.testing.expectEqual(ReplaySource.event_log, opened.source);
    try std.testing.expectEqual(ProjectionStatus.stale, opened.projection_status);
    try std.testing.expectEqual(generation_base_seq, opened.generation_base_seq);
    try std.testing.expectEqual(generation_base_bytes, opened.generation_base_bytes);
    try std.testing.expect(opened.checkpoint_seq == null);
    try std.testing.expectEqualStrings(initial.id, opened.state.id);
}

test "manifest fingerprint captures the native event device" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-manifest-device", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var file = try openManagedFile(&loaded.log.dir, events_file, .read_only);
    defer file.close(io_mod.getIo());
    const native_device = try eventDevice(file);

    const captured = try eventStat(file, loaded.position.through_event_log_bytes);
    try std.testing.expectEqual(native_device, captured.device);
}

test "log compaction replaces the generation without changing durable state" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-log-compaction", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const old_generation = loaded.position.log_generation;
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{},
    );

    try loaded.compactCanonicalLogIfDue(alloc, .{
        .compaction_frame_threshold = 1,
        .compaction_byte_threshold = 1,
    });
    try std.testing.expect(!std.mem.eql(
        u8,
        &old_generation,
        &loaded.position.log_generation,
    ));
    try std.testing.expectEqual(@as(usize, 1), loaded.state.history.len);
    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.history.len);
    try std.testing.expectEqualStrings("world", replayed.history[0].assistant.assistant);
}

test "specialized history survives event replacement checkpoint and canonical compaction" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-specialized-history", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    var calls = [_]session.ToolCall{.{
        .id = "call_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/main.zig\"}",
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .status = .failure,
        .output = @constCast("typed failure"),
        .output_bytes = 13,
        .stored_output_bytes = 13,
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .assistant = @constCast("Inspecting."),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const historical_template = session.HistoryTurn{ .assistant = .{
        .user = .{ .text = @constCast("run dev") },
        .assistant = @constCast("The historical command is inert."),
        .execution = .{ .tool_steps = steps[0..] },
    } };
    const interrupted_template = session.HistoryTurn{ .interrupted = .{
        .user = .{ .text = @constCast("inspect") },
        .assistant = @constCast("I inspected the entry point."),
        .execution = .{ .tool_steps = steps[0..] },
    } };

    var append_state = try loaded.state.dupe(alloc);
    defer append_state.deinit(alloc);
    const append_history = try alloc.alloc(session.HistoryTurn, 1);
    var owns_append_history = true;
    errdefer if (owns_append_history) alloc.free(append_history);
    append_history[0] = try session.dupeHistoryTurn(alloc, historical_template);
    var append_history_initialized = true;
    errdefer if (owns_append_history and append_history_initialized) {
        session.freeHistoryTurn(alloc, append_history[0]);
    };
    session.freeHistoryTurnSlice(alloc, append_state.history);
    append_state.history = append_history;
    owns_append_history = false;
    append_history_initialized = false;
    append_state.updated_at_ms = 20;
    _ = try loaded.appendEvent(
        alloc,
        historyEvent(append_state),
        20,
        .retry_expected_tail,
        .{},
    );
    try std.testing.expectEqualStrings(
        "The historical command is inert.",
        loaded.state.history[0].assistant.assistant,
    );

    var replacement = try loaded.state.dupe(alloc);
    defer replacement.deinit(alloc);
    const replacement_history = try alloc.alloc(session.HistoryTurn, 2);
    var owns_replacement_history = true;
    var copied_replacement_turns: usize = 0;
    errdefer if (owns_replacement_history) {
        for (replacement_history[0..copied_replacement_turns]) |turn| {
            session.freeHistoryTurn(alloc, turn);
        }
        alloc.free(replacement_history);
    };
    replacement_history[0] = try session.dupeHistoryTurn(alloc, historical_template);
    copied_replacement_turns += 1;
    replacement_history[1] = try session.dupeHistoryTurn(alloc, interrupted_template);
    copied_replacement_turns += 1;
    session.freeHistoryTurnSlice(alloc, replacement.history);
    replacement.history = replacement_history;
    owns_replacement_history = false;
    replacement.updated_at_ms = 30;
    _ = try loaded.commitStateReplacement(
        alloc,
        replacement,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    try loaded.writeCheckpointIfDue(alloc, true, .{});
    try loaded.compactCanonicalLogIfDue(alloc, .{
        .compaction_frame_threshold = 1,
        .compaction_byte_threshold = 1,
    });

    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), replayed.history.len);
    const historical = replayed.history[0].assistant;
    try std.testing.expectEqualStrings("The historical command is inert.", historical.assistant);
    try std.testing.expectEqual(@as(usize, 1), historical.execution.tool_steps.len);
    try std.testing.expectEqual(.failure, historical.execution.tool_steps[0].tool_results[0].status);
    const interrupted = replayed.history[1].interrupted;
    try std.testing.expectEqualStrings("I inspected the entry point.", interrupted.assistant.?);
    try std.testing.expectEqual(@as(usize, 1), interrupted.execution.tool_steps.len);
    try std.testing.expectEqualStrings(
        "typed failure",
        interrupted.execution.tool_steps[0].tool_results[0].output,
    );
}

test "typed history above the context limit survives checkpoint and canonical compaction" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-typed-history-growth", 10);
    defer initial.deinit(alloc);

    {
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        defer loaded.deinit(alloc);

        var calls = [_]session.ToolCall{.{
            .id = "call_first",
            .name = "read_file",
            .arguments_json = "{\"path\":\"src/main.zig\"}",
        }};
        var results = [_]session.PersistedToolResult{.{
            .tool_call_id = @constCast("call_first"),
            .tool_name = @constCast("read_file"),
            .status = .success,
            .output = @constCast("const main = true;"),
            .output_bytes = 18,
            .stored_output_bytes = 18,
        }};
        var steps = [_]session.ToolExecutionStep{.{
            .assistant = @constCast("Inspecting the entry point."),
            .tool_calls = calls[0..],
            .tool_results = results[0..],
        }};
        var files = [_]session.FileEvidence{.{
            .path = @constCast("src/main.zig"),
            .tool_call_id = @constCast("call_first"),
            .tool_name = @constCast("read_file"),
            .action = .read,
            .status = .success,
            .model_view_covers_full_file = true,
        }};
        const typed_turn = session.HistoryTurn{ .assistant = .{
            .user = .{ .text = @constCast("inspect the entry point") },
            .assistant = @constCast("The entry point is intact."),
            .execution = .{
                .tool_steps = steps[0..],
                .files = files[0..],
            },
        } };
        _ = try loaded.appendEvent(
            alloc,
            .{ .history_turn_committed = .{
                .conversation_language = loaded.state.conversation_language,
                .total_input_tokens = 1,
                .total_output_tokens = 1,
                .turn = typed_turn,
            } },
            20,
            .retry_expected_tail,
            .{},
        );

        var index: usize = 1;
        while (index < 9) : (index += 1) {
            const turn = try session.makeAssistantTurn(alloc, "follow-up", "acknowledged");
            defer session.freeHistoryTurn(alloc, turn);
            _ = try loaded.appendEvent(
                alloc,
                .{ .history_turn_committed = .{
                    .conversation_language = loaded.state.conversation_language,
                    .total_input_tokens = index + 1,
                    .total_output_tokens = index + 1,
                    .turn = turn,
                } },
                @intCast(20 + index),
                .retry_expected_tail,
                .{},
            );
        }

        try std.testing.expectEqual(@as(usize, 9), loaded.state.history.len);
        const first = loaded.state.history[0].assistant;
        try std.testing.expectEqualStrings("call_first", first.execution.tool_steps[0].tool_calls[0].id);
        try std.testing.expectEqualStrings(
            "const main = true;",
            first.execution.tool_steps[0].tool_results[0].output,
        );
        try std.testing.expectEqualStrings("src/main.zig", first.execution.files[0].path);

        try loaded.writeCheckpointIfDue(alloc, true, .{});
        try loaded.compactCanonicalLogIfDue(alloc, .{
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        });
        try std.testing.expectEqual(@as(usize, 9), loaded.state.history.len);
    }

    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 9), replayed.history.len);
    const first = replayed.history[0].assistant;
    try std.testing.expectEqualStrings("call_first", first.execution.tool_steps[0].tool_calls[0].id);
    try std.testing.expectEqual(.success, first.execution.tool_steps[0].tool_results[0].status);
    try std.testing.expectEqualStrings(
        "const main = true;",
        first.execution.tool_steps[0].tool_results[0].output,
    );
    try std.testing.expectEqualStrings("src/main.zig", first.execution.files[0].path);
    try std.testing.expect(first.execution.files[0].model_view_covers_full_file);
}

test "successful semantic commit automatically compacts when due" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-log-auto-compaction", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const old_generation = loaded.position.log_generation;
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);

    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        },
    );

    try std.testing.expect(!std.mem.eql(
        u8,
        &old_generation,
        &loaded.position.log_generation,
    ));
    var replayed = try temp.root.loadReadOnly(alloc, initial.id, .{});
    defer replayed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replayed.history.len);
    try std.testing.expectEqualStrings("world", replayed.history[0].assistant.assistant);
}

test "automatic compaction honors an immediate commit lock deadline" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-log-compaction-lock-deadline", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    const Contention = struct {
        dir: *io_mod.VerifiedDir,
        commit_attempts: usize = 0,
        commit_lock: ?io_mod.TimedAdvisoryLock = null,

        fn lock(raw: ?*anyopaque, kind: LockKind) void {
            if (kind != .commit) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.commit_attempts += 1;
            if (self.commit_attempts != 2) return;
            self.commit_lock = io_mod.acquireTimedAdvisoryLock(
                self.dir,
                commit_lock_file,
                2000,
            ) catch return;
        }
    };
    var contention = Contention{ .dir = &loaded.log.dir };
    defer if (contention.commit_lock) |*lock| lock.release();

    const started_at_ms = io_mod.milliTimestamp();
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .retry_expected_tail,
        .{
            .test_controls = .{
                .context = &contention,
                .lock_fn = Contention.lock,
            },
            .commit_lock_deadline_ms = 0,
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        },
    );
    try std.testing.expectEqual(@as(usize, 2), contention.commit_attempts);
    try std.testing.expect(contention.commit_lock != null);
    try std.testing.expect(loaded.compaction_warning_active);
    try std.testing.expect(io_mod.milliTimestamp() - started_at_ms < 1000);
}

test "automatic compaction leaves post-rename uncertainty fenced" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-log-auto-compaction-fence", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_compaction_log_rename };

    try std.testing.expectError(
        error.SessionLogCompactionIndeterminate,
        loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{
                .test_controls = failure.test_controls(),
                .compaction_frame_threshold = 1,
                .compaction_byte_threshold = 1,
            },
        ),
    );

    try std.testing.expect(loaded.namespace_confirmation_required);
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        temp.root.loadReadOnly(alloc, initial.id, .{}),
    );
    loaded.deinit(alloc);

    var resolved = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resolved.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), resolved.state.history.len);
    try std.testing.expectEqualStrings(
        "world",
        resolved.state.history[0].assistant.assistant,
    );
}

test "automatic compaction recovers every injected transaction boundary" {
    const boundaries = [_]Boundary{
        .after_compaction_temp_sync,
        .after_compaction_watermark_sync,
        .after_compaction_intent_sync,
        .after_compaction_log_rename,
        .after_compaction_namespace_sync,
        .after_compaction_live_confirmation,
        .after_compaction_intent_remove,
    };
    for (boundaries, 0..) |boundary, index| {
        const alloc = std.testing.allocator;
        var temp = try TempRoot.init(alloc);
        defer temp.deinit(alloc);
        const session_id = try std.fmt.allocPrint(
            alloc,
            "session-log-compaction-boundary-{d}",
            .{index},
        );
        defer alloc.free(session_id);
        var initial = try testState(alloc, session_id, 10);
        defer initial.deinit(alloc);
        var loaded = try temp.root.startWritableSession(alloc, initial, .{});
        var next = try stateWithTurn(alloc, loaded.state, 20);
        defer next.deinit(alloc);
        var failure = BoundaryFailure{ .target = boundary };

        const result = loaded.appendEvent(
            alloc,
            historyEvent(next),
            20,
            .retry_expected_tail,
            .{
                .test_controls = failure.test_controls(),
                .compaction_frame_threshold = 1,
                .compaction_byte_threshold = 1,
            },
        );
        switch (boundary) {
            .after_compaction_temp_sync,
            .after_compaction_watermark_sync,
            .after_compaction_intent_remove,
            => _ = try result,
            .after_compaction_intent_sync,
            .after_compaction_log_rename,
            .after_compaction_namespace_sync,
            .after_compaction_live_confirmation,
            => try std.testing.expectError(
                error.SessionLogCompactionIndeterminate,
                result,
            ),
            else => unreachable,
        }
        loaded.deinit(alloc);

        var resumed = try temp.root.resumeForWrite(alloc, session_id, .{});
        defer resumed.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), resumed.state.history.len);
        try std.testing.expectEqualStrings(
            "world",
            resumed.state.history[0].assistant.assistant,
        );
    }
}

test "log compaction rename remains fenced until writable resolution" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-log-compaction-fence", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    var next = try stateWithTurn(alloc, loaded.state, 20);
    defer next.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        historyEvent(next),
        20,
        .retry_expected_tail,
        .{},
    );
    var failure = BoundaryFailure{ .target = .after_compaction_log_rename };

    try std.testing.expectError(
        error.SessionLogCompactionIndeterminate,
        loaded.compactCanonicalLogIfDue(alloc, .{
            .test_controls = failure.test_controls(),
            .compaction_frame_threshold = 1,
            .compaction_byte_threshold = 1,
        }),
    );
    loaded.deinit(alloc);
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        temp.root.loadReadOnly(alloc, initial.id, .{}),
    );
    var resolved = try temp.root.resumeForWrite(alloc, initial.id, .{});
    defer resolved.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), resolved.state.history.len);
    try std.testing.expectEqualStrings(
        "world",
        resolved.state.history[0].assistant.assistant,
    );
}

test "orphan cleanup removes only validated noncurrent generated files" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-orphan-cleanup", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    const candidates = try loaded.createCleanupCandidatesForTest(alloc);
    defer {
        alloc.free(candidates.temp_name);
        alloc.free(candidates.watermark_name);
    }
    const report = try loaded.cleanupOrphans(alloc, .delete);
    try std.testing.expectEqual(@as(usize, 2), report.removed);
    try std.testing.expect(!(try loaded.log.entryExistsForTest(candidates.temp_name)));
    try std.testing.expect(!(try loaded.log.entryExistsForTest(candidates.watermark_name)));
    try std.testing.expect(try loaded.log.entryExistsForTest("authority.json"));
}

test "orphan cleanup preserves a generated temp with malformed trailing bytes" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-orphan-malformed", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    const candidates = try loaded.createCleanupCandidatesForTest(alloc);
    defer {
        alloc.free(candidates.temp_name);
        alloc.free(candidates.watermark_name);
    }
    var malformed = try openManagedFile(
        &loaded.log.dir,
        candidates.temp_name,
        .read_write,
    );
    defer malformed.close(io_mod.getIo());
    const length = try malformed.length(io_mod.getIo());
    try malformed.writePositionalAll(io_mod.getIo(), "not-json\n", length);
    try malformed.sync(io_mod.getIo());

    const report = try loaded.cleanupOrphans(alloc, .delete);
    try std.testing.expectEqual(@as(usize, 1), report.removed);
    try std.testing.expectEqual(@as(usize, 2), report.ignored);
    try std.testing.expect(try loaded.log.entryExistsForTest(candidates.temp_name));
    try std.testing.expect(!(try loaded.log.entryExistsForTest(candidates.watermark_name)));
}

test "lock ordering is session before commit and read boundary uses commit only" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-lock-order", 10);
    defer initial.deinit(alloc);
    var create_trace: LockTrace = .{};
    var loaded = try temp.root.startWritableSession(
        alloc,
        initial,
        .{ .test_controls = create_trace.test_controls() },
    );
    loaded.deinit(alloc);
    try std.testing.expect(create_trace.len >= 2);
    try std.testing.expectEqual(LockKind.session, create_trace.items[0]);
    try std.testing.expectEqual(LockKind.commit, create_trace.items[1]);

    var read_trace: LockTrace = .{};
    var boundary = try temp.root.captureReadBoundary(
        alloc,
        initial.id,
        .{ .test_controls = read_trace.test_controls() },
    );
    boundary.deinit();
    try std.testing.expectEqual(@as(usize, 1), read_trace.len);
    try std.testing.expectEqual(LockKind.commit, read_trace.items[0]);
}

test "read boundary validation does not block a concurrent append" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "read-boundary-concurrent-append", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    const captured_position = loaded.position;

    const AppendDuringValidation = struct {
        loaded: *LoadedWritableSession,
        alloc: Allocator,
        attempted: bool = false,
        failure: ?anyerror = null,

        fn hit(raw: ?*anyopaque, point: Boundary) !void {
            if (point != .before_read_boundary_validation) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.attempted = true;
            _ = self.loaded.appendEvent(
                self.alloc,
                .{ .preferences_changed = .{ .fast_mode = true } },
                20,
                .retry_expected_tail,
                .{ .commit_lock_deadline_ms = 0 },
            ) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var append = AppendDuringValidation{
        .loaded = &loaded,
        .alloc = alloc,
    };

    var boundary = try temp.root.captureReadBoundary(
        alloc,
        initial.id,
        .{ .test_controls = .{
            .context = &append,
            .boundary_fn = AppendDuringValidation.hit,
        } },
    );
    defer boundary.deinit();

    try std.testing.expect(append.attempted);
    try std.testing.expectEqual(@as(?anyerror, null), append.failure);
    try std.testing.expect(std.meta.eql(captured_position, boundary.position));
    try std.testing.expect(loaded.state.preferences.fast_mode);
    var captured = try session_replay.replayBoundary(
        alloc,
        boundary.log_file,
        boundary.position,
        null,
    );
    defer captured.deinit(alloc);
    try std.testing.expect(!captured.preferences.fast_mode);
}

test "read boundary validation still rejects a corrupt committed prefix" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "read-boundary-corrupt-prefix", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var usage_snapshot = try usage.snapshot(alloc);
    defer usage_snapshot.deinit(alloc);
    _ = try loaded.appendEvent(
        alloc,
        .{ .usage_checkpointed = .{ .usage = usage_snapshot } },
        20,
        .retry_expected_tail,
        .{},
    );
    const corrupt_frame_start = loaded.position.through_event_log_bytes;
    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        21,
        .retry_expected_tail,
        .{},
    );

    var log = try openManagedFile(&loaded.log.dir, events_file, .read_write);
    defer log.close(io_mod.getIo());
    try replaceFrameByteForTest(
        alloc,
        log,
        corrupt_frame_start,
        loaded.position.through_event_log_bytes,
        "preferences_changed",
        'X',
    );

    try std.testing.expectError(
        error.InvalidSessionFormat,
        temp.root.captureReadBoundary(alloc, initial.id, .{}),
    );
}

test "writable resume can fail immediately at a contended commit boundary" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-commit-lock-deadline", 10);
    defer initial.deinit(alloc);

    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    loaded.log.park();

    var contender = try io_mod.acquireTimedAdvisoryLock(
        &loaded.log.dir,
        commit_lock_file,
        2000,
    );
    defer contender.release();

    const started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        temp.root.resumeForWrite(alloc, initial.id, .{
            .session_lock_deadline_ms = 0,
            .commit_lock_deadline_ms = 0,
        }),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_at_ms < 1000);
}

test "read boundary can fail immediately at a contended commit boundary" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "read-commit-lock-deadline", 10);
    defer initial.deinit(alloc);

    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    loaded.log.park();

    var contender = try io_mod.acquireTimedAdvisoryLock(
        &loaded.log.dir,
        commit_lock_file,
        2000,
    );
    defer contender.release();

    const started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        temp.root.captureReadBoundary(alloc, initial.id, .{
            .commit_lock_deadline_ms = 0,
        }),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_at_ms < 1000);
}

test "namespace confirmation honors an immediate commit lock deadline" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "confirmation-commit-lock-deadline", 10);
    defer initial.deinit(alloc);
    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);
    var failure = BoundaryFailure{ .target = .after_commit_intent_remove };

    _ = try loaded.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .fast_mode = true } },
        20,
        .rollback_before_adapter_continue,
        .{ .test_controls = failure.test_controls() },
    );
    try std.testing.expect(loaded.namespace_confirmation_required);

    var contender = try io_mod.acquireTimedAdvisoryLock(
        &loaded.log.dir,
        commit_lock_file,
        2000,
    );
    defer contender.release();

    const started_at_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.SessionCommitBoundaryUnavailable,
        loaded.appendEvent(
            alloc,
            .{ .preferences_changed = .{ .fast_mode = false } },
            30,
            .rollback_before_adapter_continue,
            .{ .commit_lock_deadline_ms = 0 },
        ),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_at_ms < 1000);
}

test "park releases session.lock and unpark reacquires or fails busy" {
    const alloc = std.testing.allocator;
    var temp = try TempRoot.init(alloc);
    defer temp.deinit(alloc);
    var initial = try testState(alloc, "session-park-lock", 10);
    defer initial.deinit(alloc);

    var loaded = try temp.root.startWritableSession(alloc, initial, .{});
    defer loaded.deinit(alloc);

    try std.testing.expect(!loaded.log.isParked());
    loaded.log.park();
    try std.testing.expect(loaded.log.isParked());

    var contender = try io_mod.acquireTimedAdvisoryLock(
        &loaded.log.dir,
        session_lock_file,
        2000,
    );
    try std.testing.expectError(error.SessionBusy, loaded.log.unpark());
    contender.release();

    try loaded.log.unpark();
    try std.testing.expect(!loaded.log.isParked());

    try std.testing.expectError(
        error.LockBusy,
        io_mod.acquireTimedAdvisoryLock(
            &loaded.log.dir,
            session_lock_file,
            50,
        ),
    );
}

test "watermark decoder rejects malformed object keys and required strings" {
    const unknown_key =
        "{\"schema_version\":1,\"session_id\":\"session\",\"log_generation\":\"00000000000000000000000000000000\",\"through_seq\":0,\"through_event_id\":\"00000000000000000000000000000000\",\"through_event_log_bytes\":0,\"unexpected\":true}";
    const non_string_session_id =
        "{\"schema_version\":1,\"session_id\":1,\"log_generation\":\"00000000000000000000000000000000\",\"through_seq\":0,\"through_event_id\":\"00000000000000000000000000000000\",\"through_event_log_bytes\":0}";

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        unknown_key,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(
        error.InvalidSessionFormat,
        session_codec.exactObject(parsed.value, &.{
            "schema_version",
            "session_id",
            "log_generation",
            "through_seq",
            "through_event_id",
            "through_event_log_bytes",
        }),
    );
    try std.testing.expectError(
        error.InvalidSessionFormat,
        parseWatermark(std.testing.allocator, unknown_key),
    );
    try std.testing.expectError(
        error.InvalidSessionFormat,
        parseWatermark(std.testing.allocator, non_string_session_id),
    );
}
