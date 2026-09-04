const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_event = @import("session_event.zig");
const session_json = @import("session_json.zig");
const session_log = @import("session_log.zig");
const session_projection = @import("session_projection.zig");
const session_read = @import("../shared/read_cancellation.zig");
const session_replay = @import("session_replay.zig");
const Allocator = std.mem.Allocator;

const authority_module = @import("session_authority.zig");
const paths = @import("session_store_paths.zig");
const types = @import("session_store_types.zig");

const AuthorityTransition = authority_module.AuthorityTransition;
const deleteSessionEntry = authority_module.deleteSessionEntry;
const entryExistsRelative = authority_module.entryExistsRelative;
const eventFileStat = authority_module.eventFileStat;
const exactJsonObject = authority_module.exactJsonObject;
const jsonU64 = authority_module.jsonU64;
const loadAuthorityMarkerOptional = authority_module.loadAuthorityMarkerOptional;
const objectString = authority_module.objectString;
const openSessionFile = authority_module.openSessionFile;
const parseIdentifier = authority_module.parseIdentifier;
const positionsEqual = authority_module.positionsEqual;
const readExactLegacyFile = authority_module.readExactLegacyFile;
const readOptionalSessionFile = authority_module.readOptionalSessionFile;
const requireAuthorityFenceAbsent = authority_module.requireAuthorityFenceAbsent;
const validateWorkspaceRoot = paths.validateWorkspaceRoot;
const LoadedWritableSession = types.LoadedWritableSession;
const ResumeOptions = types.ResumeOptions;
const automatic_legacy_max_bytes = types.automatic_legacy_max_bytes;
const StoreContext = types.StoreContext;

pub const LegacyStoredSession = struct {
    id: []u8,
    workspace_root: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: session.ConversationLanguage,
    history: []session.HistoryTurn,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,

    /// Frees owned session fields and history turns.
    pub fn deinit(self: *LegacyStoredSession, alloc: Allocator) void {
        if (self.id.len > 0) alloc.free(self.id);
        if (self.workspace_root) |wr| alloc.free(wr);
        session.freeHistoryTurnSlice(alloc, self.history);
        self.* = undefined;
    }
};

pub const MigrationPreferenceSource = enum {
    requesting_workspace,
    preserved_workspace,
};

const MigrationCanonical = struct {
    events: []u8,
    watermark: []u8,
    watermark_name: []u8,
    checkpoint: []u8,
    authority: []u8,
    intent: []u8,
    authority_id: session_event.Identifier,
    position: session_log.CommitPosition,
    generation_base_bytes: u64,

    fn deinit(self: *MigrationCanonical, alloc: Allocator) void {
        alloc.free(self.events);
        alloc.free(self.watermark);
        alloc.free(self.watermark_name);
        alloc.free(self.checkpoint);
        alloc.free(self.authority);
        alloc.free(self.intent);
        self.* = undefined;
    }
};

const RandomEventIds = struct {
    fn next(_: *anyopaque) session_event.Identifier {
        return randomIdentifier();
    }
};

fn runBoundary(test_controls: session_log.TestControls, boundary: session_log.Boundary) !void {
    try test_controls.boundary(boundary);
}

/// Migrates legacy state to schema v3 while the caller holds the writer lock.
/// Commit order is fixed: migration fence, stable snapshot, projection write,
/// unchanged recheck, then intent, marker, manifest, validation, and intent removal.
/// Resume handles partial disk state. Ownership transfers only on success.
pub fn migrateLegacyLocked(
    ctx: StoreContext,
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    workspace_root: []const u8,
    preference_source: MigrationPreferenceSource,
    options: ResumeOptions,
    lifecycle: *?session_log.CommitLifecycle,
) !LoadedWritableSession {
    var loaded: LoadedWritableSession = undefined;
    try migrateLegacyLockedInto(
        &loaded,
        ctx,
        alloc,
        writable,
        workspace_root,
        preference_source,
        options,
        lifecycle,
    );
    return loaded;
}

// Keep fallible construction behind a noinline out-parameter boundary so
// error returns do not materialize the full LoadedWritableSession payload.
noinline fn migrateLegacyLockedInto(
    out: *LoadedWritableSession,
    ctx: StoreContext,
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    workspace_root: []const u8,
    preference_source: MigrationPreferenceSource,
    options: ResumeOptions,
    lifecycle: *?session_log.CommitLifecycle,
) !void {
    try assertMigratable(
        alloc,
        writable,
        options.log.commit_lock_deadline_ms,
        options.log.cancel_flag,
    );

    var primary = try openSessionFile(&writable.dir, "session.json", .read_only);
    defer primary.close(io_mod.getIo());
    const primary_stat = try primary.stat(io_mod.getIo());
    const allowed_size = if (options.allow_large_legacy)
        primary_stat.size
    else
        automatic_legacy_max_bytes;
    if (primary_stat.size > allowed_size) return error.LegacySessionTooLarge;
    const primary_bytes = readExactLegacyFile(
        alloc,
        &primary,
        primary_stat.size,
        options.log.cancel_flag,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.LegacySessionMigrationResourceExhausted,
        error.Cancelled => return error.Cancelled,
        else => return error.LegacySessionMigrationFailed,
    };
    defer alloc.free(primary_bytes);
    const primary_digest = try session_read.sha256(primary_bytes, options.log.cancel_flag);
    const schema = session_json.parseLegacySchemaVersion(
        alloc,
        primary_bytes,
        options.log.cancel_flag,
    ) catch |err| return err;

    try ensureStableLegacyCopy(alloc, writable, primary_bytes, primary_stat.size, options.log.cancel_flag);

    var legacy = session_json.parseLegacyExact(
        LegacyStoredSession,
        alloc,
        primary_bytes,
        options.log.cancel_flag,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.LegacySessionMigrationResourceExhausted,
        else => return err,
    };
    errdefer legacy.deinit(alloc);
    if (!std.mem.eql(u8, legacy.id, writable.session_id)) {
        return error.InvalidSessionFormat;
    }
    const legacy_had_workspace = legacy.workspace_root != null;
    var state = try legacyToDurableState(
        ctx,
        alloc,
        &legacy,
        workspace_root,
        preference_source,
        options.seed_preferences,
        options.log.cancel_flag,
    );
    errdefer state.deinit(alloc);
    if (!legacy_had_workspace) {
        if (!std.mem.eql(u8, state.workspace_root, workspace_root)) {
            return error.InvalidDurableField;
        }
    }
    if (lifecycle.*) |*value| {
        try value.prepare(
            alloc,
            writable.session_id,
            options.log.cancel_flag,
        );
    }

    var canonical = try buildMigrationCanonical(
        alloc,
        state,
        schema,
        primary_bytes,
        options.log.cancel_flag,
    );
    defer canonical.deinit(alloc);

    const manifest = try writeCanonicalProjection(alloc, writable, state, canonical, options.log.cancel_flag);
    defer alloc.free(manifest);

    try assertLegacyUnchanged(alloc, writable, primary_stat.size, primary_digest, options.log.cancel_flag);

    const replayed = try commitMigrationAuthorityLocked(alloc, writable, canonical, manifest, options);
    state.deinit(alloc);
    state = replayed;
    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer alloc.free(active_id);
    var result = LoadedWritableSession{
        .active_id = active_id,
        .state = state,
        .log = writable.*,
        .position = canonical.position,
        .authority_id = canonical.authority_id,
        .generation_base_seq = 1,
        .generation_base_bytes = canonical.generation_base_bytes,
        .checkpoint_seq = canonical.position.through_seq,
        .checkpoint_sha256 = try session_read.sha256(canonical.checkpoint, options.log.cancel_flag),
        .projection_status = .current,
        .migration_source_schema_version = @intFromEnum(schema),
        .migration_source_bytes = primary_stat.size,
        .commit_lifecycle = lifecycle.*,
    };
    lifecycle.* = null;
    writable.* = undefined;
    result.persistence_debt.derived_publication = !result.publishCommitLifecycle(alloc, options.log.cancel_flag);
    out.* = result;
}

/// Asserts the session may be migrated: takes the commit lock, requires no
/// pending authority fence, and rejects a directory that already owns a
/// schema-v3 authority marker. Releases the lock before returning.
fn assertMigratable(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    commit_lock_deadline_ms: u64,
    cancel_flag: session_read.CancelFlag,
) !void {
    var commit_lock = try acquireMigrationLock(&writable.dir, commit_lock_deadline_ms, cancel_flag);
    defer commit_lock.release();
    try requireAuthorityFenceAbsent(alloc, &writable.dir, writable.session_id);
    if (try entryExistsRelative(&writable.dir, "authority.json")) {
        return error.InvalidSessionFormat;
    }
}

fn acquireMigrationLock(dir: *io_mod.VerifiedDir, deadline_ms: u64, cancel_flag: session_read.CancelFlag) !io_mod.TimedAdvisoryLock {
    const result = if (cancel_flag) |flag|
        io_mod.acquireTimedAdvisoryLockCancellable(dir, "commit.lock", deadline_ms, flag)
    else
        io_mod.acquireTimedAdvisoryLock(dir, "commit.lock", deadline_ms);
    return result catch |err| switch (err) {
        error.Cancelled, error.Canceled => return err,
        error.LockBusy, error.LockUnsupported => return error.SessionCommitBoundaryUnavailable,
        else => return error.LegacySessionMigrationFailed,
    };
}

/// Ensures `session.legacy.json` holds an exact copy of the primary snapshot,
/// writing it durably if absent and rejecting a mismatched existing copy. This
/// is the rollback source if the authority swap is interrupted.
fn ensureStableLegacyCopy(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    primary_bytes: []const u8,
    primary_size: u64,
    cancel_flag: session_read.CancelFlag,
) !void {
    if (try authority_module.readOptionalSessionFileCancellable(
        alloc,
        &writable.dir,
        "session.legacy.json",
        std.math.cast(usize, primary_size + 1) orelse
            return error.LegacySessionMigrationResourceExhausted,
        cancel_flag,
    )) |existing_copy| {
        defer alloc.free(existing_copy);
        if (existing_copy.len != primary_bytes.len) return error.InvalidSessionFormat;
        var offset: usize = 0;
        while (offset < primary_bytes.len) {
            try session_read.check(cancel_flag);
            const end = offset + @min(session_read.work_bytes, primary_bytes.len - offset);
            if (!std.mem.eql(u8, existing_copy[offset..end], primary_bytes[offset..end])) return error.InvalidSessionFormat;
            offset = end;
        }
    } else {
        io_mod.durableReplaceVerifiedWithOps(
            alloc,
            &writable.dir,
            "session.legacy.json",
            primary_bytes,
            .{ .cancel_flag = cancel_flag },
        ) catch |err| switch (err) {
            error.Cancelled => return err,
            else => return error.LegacySessionMigrationFailed,
        };
    }
}

/// Durably writes the canonical projection files (event log, watermark,
/// checkpoint) and returns the encoded manifest bytes for the caller to commit.
/// Caller owns and frees the returned slice.
fn writeCanonicalProjection(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    state: session_codec.DurableSessionState,
    canonical: MigrationCanonical,
    cancel_flag: session_read.CancelFlag,
) ![]u8 {
    io_mod.durableReplaceVerifiedWithOps(
        alloc,
        &writable.dir,
        "events.jsonl",
        canonical.events,
        .{ .cancel_flag = cancel_flag },
    ) catch |err| switch (err) {
        error.Cancelled => return err,
        else => return error.LegacySessionMigrationFailed,
    };
    io_mod.durableReplaceVerifiedWithOps(
        alloc,
        &writable.dir,
        canonical.watermark_name,
        canonical.watermark,
        .{ .cancel_flag = cancel_flag },
    ) catch |err| switch (err) {
        error.Cancelled => return err,
        else => return error.LegacySessionMigrationFailed,
    };
    io_mod.durableReplaceVerifiedWithOps(
        alloc,
        &writable.dir,
        "checkpoint.json",
        canonical.checkpoint,
        .{ .cancel_flag = cancel_flag },
    ) catch |err| switch (err) {
        error.Cancelled => return err,
        else => return error.LegacySessionMigrationFailed,
    };
    return encodeMigrationManifest(
        alloc,
        &writable.dir,
        state,
        canonical,
        cancel_flag,
    ) catch |err| switch (err) {
        error.Cancelled => return err,
        else => return error.LegacySessionMigrationFailed,
    };
}

/// Re-reads the primary snapshot and fails with `error.LegacySessionChanged`
/// if its size or digest no longer matches what was staged, guarding against a
/// concurrent writer between staging and commit.
fn assertLegacyUnchanged(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    primary_size: u64,
    primary_digest: session_projection.Digest,
    cancel_flag: session_read.CancelFlag,
) !void {
    var current_primary = try openSessionFile(
        &writable.dir,
        "session.json",
        .read_only,
    );
    defer current_primary.close(io_mod.getIo());
    const current_stat = try current_primary.stat(io_mod.getIo());
    if (current_stat.size != primary_size) return error.LegacySessionChanged;
    const current_bytes = readExactLegacyFile(
        alloc,
        &current_primary,
        current_stat.size,
        cancel_flag,
    ) catch |err| switch (err) {
        error.Cancelled => return err,
        else => return error.LegacySessionChanged,
    };
    defer alloc.free(current_bytes);
    const current_digest = try session_read.sha256(current_bytes, cancel_flag);
    if (!std.mem.eql(u8, &current_digest, &primary_digest)) {
        return error.LegacySessionChanged;
    }
}

/// Atomically swaps legacy authority to schema-v3 under the commit lock:
/// intent -> marker -> manifest -> validate -> drop intent, each step gated by
/// a crash-injection test boundary. Once the marker is written, failures map to
/// `LegacySessionMigrationIndeterminate` so recovery re-runs validation rather
/// than restarting. Releases the lock before returning.
fn commitMigrationAuthorityLocked(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    canonical: MigrationCanonical,
    manifest: []const u8,
    options: ResumeOptions,
) !session_codec.DurableSessionState {
    var commit_lock = try acquireMigrationLock(&writable.dir, options.log.commit_lock_deadline_ms, options.log.cancel_flag);
    defer commit_lock.release();
    try requireAuthorityFenceAbsent(alloc, &writable.dir, writable.session_id);
    io_mod.durableReplaceVerifiedWithOps(
        alloc,
        &writable.dir,
        "authority.pending.json",
        canonical.intent,
        .{ .cancel_flag = options.log.cancel_flag },
    ) catch |err| switch (err) {
        error.Cancelled => return err,
        else => return error.LegacySessionMigrationFailed,
    };
    runBoundary(options.log.test_controls, .after_authority_intent_sync) catch
        return error.LegacySessionMigrationIndeterminate;
    session_read.check(options.log.cancel_flag) catch return error.LegacySessionMigrationIndeterminate;
    io_mod.durableReplaceVerified(
        alloc,
        &writable.dir,
        "authority.json",
        canonical.authority,
    ) catch return error.LegacySessionMigrationIndeterminate;
    runBoundary(options.log.test_controls, .after_authority_marker_rename) catch
        return error.LegacySessionMigrationIndeterminate;
    session_read.check(options.log.cancel_flag) catch return error.LegacySessionMigrationIndeterminate;
    io_mod.durableReplaceVerified(
        alloc,
        &writable.dir,
        "session.json",
        manifest,
    ) catch return error.LegacySessionMigrationIndeterminate;
    io_mod.syncVerifiedDir(writable.dir.dir) catch
        return error.LegacySessionMigrationIndeterminate;
    var validated_state = validateMigrationTarget(
        alloc,
        &writable.dir,
        writable.session_id,
        canonical.authority_id,
        canonical.position,
        options.log.cancel_flag,
    ) catch return error.LegacySessionMigrationIndeterminate;
    errdefer validated_state.deinit(alloc);
    runBoundary(options.log.test_controls, .after_authority_namespace_sync) catch
        return error.LegacySessionMigrationIndeterminate;
    session_read.check(options.log.cancel_flag) catch return error.LegacySessionMigrationIndeterminate;
    deleteSessionEntry(&writable.dir, "authority.pending.json") catch
        return error.SessionAuthorityIntentCleanupPending;
    runBoundary(options.log.test_controls, .after_authority_intent_remove) catch
        return error.SessionAuthorityIntentCleanupPending;
    return validated_state;
}

fn buildMigrationCanonical(
    alloc: Allocator,
    state: session_codec.DurableSessionState,
    schema: session_json.LegacySchemaVersion,
    primary_bytes: []const u8,
    cancel_flag: session_read.CancelFlag,
) !MigrationCanonical {
    const generation = randomIdentifier();
    const first_event_id = randomIdentifier();
    const authority_id = randomIdentifier();
    const started = session_event.Envelope{
        .log_generation = generation,
        .seq = 1,
        .event_id = first_event_id,
        .timestamp_ms = state.created_at_ms,
        .event = .{ .session_started = .{
            .id = state.id,
            .created_at_ms = state.created_at_ms,
            .origin_workspace_root = state.origin_workspace_root,
            .workspace_root = state.workspace_root,
            .conversation_language = state.conversation_language,
            .preferences = state.preferences,
            .usage = state.usage,
        } },
    };
    const first_line = try session_event.encodeFrameCancellable(alloc, started, cancel_flag);
    defer alloc.free(first_line);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(first_line);
    var random_ids: u8 = 0;
    const replacement = try session_event.writeStateReplacement(
        alloc,
        &out.writer,
        state,
        .{
            .log_generation = generation,
            .first_seq = 2,
            .replacement_id = randomIdentifier(),
            .event_ids = .{
                .context = &random_ids,
                .next_fn = RandomEventIds.next,
            },
            .timestamp_ms = state.updated_at_ms,
            .reason = .migration,
            .cancel_flag = cancel_flag,
        },
    );
    const events = try out.toOwnedSlice();
    errdefer alloc.free(events);
    const position = session_log.CommitPosition{
        .log_generation = generation,
        .through_seq = replacement.last_seq,
        .through_event_id = replacement.last_event_id,
        .through_event_log_bytes = events.len,
    };
    const watermark = try encodeMigrationWatermark(alloc, state.id, position);
    errdefer alloc.free(watermark);
    const watermark_name = try migrationWatermarkName(alloc, generation);
    errdefer alloc.free(watermark_name);

    const checkpoint_value = session_projection.Checkpoint{
        .session_id = state.id,
        .log_generation = generation,
        .through_seq = position.through_seq,
        .through_event_id = position.through_event_id,
        .through_event_log_bytes = position.through_event_log_bytes,
        .state = state,
    };
    const checkpoint = try session_projection.encodeCheckpointCancellable(alloc, checkpoint_value, cancel_flag);
    errdefer alloc.free(checkpoint);
    const authority = try encodeMigrationAuthority(
        alloc,
        state.id,
        authority_id,
    );
    errdefer alloc.free(authority);
    const intent = try encodeMigrationIntent(
        alloc,
        state.id,
        schema,
        primary_bytes,
        authority_id,
        position,
        cancel_flag,
    );
    errdefer alloc.free(intent);
    return .{
        .events = events,
        .watermark = watermark,
        .watermark_name = watermark_name,
        .checkpoint = checkpoint,
        .authority = authority,
        .intent = intent,
        .authority_id = authority_id,
        .position = position,
        .generation_base_bytes = first_line.len,
    };
}

fn encodeMigrationManifest(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    state: session_codec.DurableSessionState,
    canonical: MigrationCanonical,
    cancel_flag: session_read.CancelFlag,
) ![]u8 {
    const stat = try eventFileStat(session_dir, "events.jsonl");
    const fingerprint = try session_projection.eventFileStatFingerprint(
        stat,
        canonical.position.through_event_log_bytes,
    );
    return session_projection.encodeManifest(alloc, .{
        .id = state.id,
        .authority_id = canonical.authority_id,
        .log_generation = canonical.position.log_generation,
        .created_at_ms = state.created_at_ms,
        .updated_at_ms = state.updated_at_ms,
        .origin_workspace_root = state.origin_workspace_root,
        .workspace_root = state.workspace_root,
        .conversation_language = state.conversation_language,
        .history_len = state.history.len,
        .total_input_tokens = state.total_input_tokens,
        .total_output_tokens = state.total_output_tokens,
        .last_event_seq = canonical.position.through_seq,
        .event_log_bytes = canonical.position.through_event_log_bytes,
        .event_log_stat_fingerprint = fingerprint,
        .generation_base_seq = 1,
        .generation_base_bytes = canonical.generation_base_bytes,
        .checkpoint_seq = canonical.position.through_seq,
        .checkpoint_sha256 = try session_read.sha256(canonical.checkpoint, cancel_flag),
        .preferences = state.preferences,
    });
}

fn encodeMigrationWatermark(
    alloc: Allocator,
    session_id: []const u8,
    position: session_log.CommitPosition,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const generation = std.fmt.bytesToHex(position.log_generation, .lower);
    const event_id = std.fmt.bytesToHex(position.through_event_id, .lower);
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
    return out.toOwnedSlice();
}

fn migrationWatermarkName(
    alloc: Allocator,
    generation: session_event.Identifier,
) ![]u8 {
    const hex = std.fmt.bytesToHex(generation, .lower);
    return std.fmt.allocPrint(alloc, "commit.{s}.json", .{hex});
}

fn encodeMigrationAuthority(
    alloc: Allocator,
    session_id: []const u8,
    authority_id: session_event.Identifier,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const authority = std.fmt.bytesToHex(authority_id, .lower);
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, &out.writer);
    try out.writer.print(
        ",\"authority_id\":\"{s}\",\"storage_format\":\"event_log_v1\",\"source\":\"legacy_migration\"}}\n",
        .{authority},
    );
    return out.toOwnedSlice();
}

fn encodeMigrationIntent(
    alloc: Allocator,
    session_id: []const u8,
    schema: session_json.LegacySchemaVersion,
    primary_bytes: []const u8,
    authority_id: session_event.Identifier,
    position: session_log.CommitPosition,
    cancel_flag: session_read.CancelFlag,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const operation = std.fmt.bytesToHex(randomIdentifier(), .lower);
    const authority = std.fmt.bytesToHex(authority_id, .lower);
    const digest = std.fmt.bytesToHex(try session_read.sha256(primary_bytes, cancel_flag), .lower);
    const generation = std.fmt.bytesToHex(position.log_generation, .lower);
    const event_id = std.fmt.bytesToHex(position.through_event_id, .lower);
    try out.writer.writeAll("{\"schema_version\":1,\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, &out.writer);
    try out.writer.print(
        ",\"operation_id\":\"{s}\",\"kind\":\"legacy_to_v3\",\"authority_id\":\"{s}\",\"prior\":{{\"storage_format\":\"legacy_snapshot_v{d}\",\"primary_bytes\":{d},\"primary_sha256\":\"{s}\"}},\"proposed\":{{\"storage_format\":\"event_log_v1\",\"log_generation\":\"{s}\",\"through_seq\":{d},\"through_event_id\":\"{s}\",\"through_event_log_bytes\":{d}}}}}\n",
        .{
            operation,
            authority,
            @intFromEnum(schema),
            primary_bytes.len,
            digest,
            generation,
            position.through_seq,
            event_id,
            position.through_event_log_bytes,
        },
    );
    return out.toOwnedSlice();
}

/// Validates that an on-disk schema-v3 target exactly matches a proposed
/// commit position (marker, manifest, event fingerprint, watermark, replay,
/// checkpoint). Returns the replayed state on success; any mismatch yields
/// `error.LegacySessionMigrationIndeterminate`. Caller owns the returned state.
pub fn validateMigrationTarget(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    authority_id: session_event.Identifier,
    position: session_log.CommitPosition,
    cancel_flag: ?*const std.atomic.Value(bool),
) !session_codec.DurableSessionState {
    try session_read.check(cancel_flag);
    var marker = (try loadAuthorityMarkerOptional(alloc, session_dir)) orelse
        return error.LegacySessionMigrationIndeterminate;
    defer marker.deinit(alloc);
    if (!std.mem.eql(u8, marker.session_id, session_id) or
        !std.mem.eql(u8, &marker.authority_id, &authority_id) or
        marker.source != .legacy_migration)
    {
        return error.LegacySessionMigrationIndeterminate;
    }
    const manifest_bytes = (try authority_module.readOptionalSessionFileCancellable(
        alloc,
        session_dir,
        "session.json",
        session_projection.manifest_max_bytes,
        cancel_flag,
    )) orelse return error.LegacySessionMigrationIndeterminate;
    defer alloc.free(manifest_bytes);
    var manifest = session_projection.decodeManifest(alloc, manifest_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.LegacySessionMigrationIndeterminate,
    };
    defer manifest.deinit(alloc);
    if (!std.mem.eql(u8, manifest.id, session_id) or
        !std.mem.eql(u8, &manifest.authority_id, &authority_id) or
        !std.mem.eql(u8, &manifest.log_generation, &position.log_generation) or
        manifest.last_event_seq != position.through_seq or
        manifest.event_log_bytes != position.through_event_log_bytes)
    {
        return error.LegacySessionMigrationIndeterminate;
    }
    var events = try openSessionFile(session_dir, "events.jsonl", .read_only);
    defer events.close(io_mod.getIo());
    const events_stat = try eventFileStat(session_dir, "events.jsonl");
    const fingerprint = session_projection.eventFileStatFingerprint(
        events_stat,
        position.through_event_log_bytes,
    ) catch return error.LegacySessionMigrationIndeterminate;
    if (!std.mem.eql(
        u8,
        &fingerprint,
        &manifest.event_log_stat_fingerprint,
    )) {
        return error.LegacySessionMigrationIndeterminate;
    }
    const watermark_name = try migrationWatermarkName(alloc, position.log_generation);
    defer alloc.free(watermark_name);
    const watermark = (try authority_module.readOptionalSessionFileCancellable(
        alloc,
        session_dir,
        watermark_name,
        16 * 1024,
        cancel_flag,
    )) orelse return error.LegacySessionMigrationIndeterminate;
    defer alloc.free(watermark);
    const watermark_position = decodeMigrationWatermark(
        alloc,
        watermark,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.LegacySessionMigrationIndeterminate,
    };
    if (!positionsEqual(watermark_position, position)) {
        return error.LegacySessionMigrationIndeterminate;
    }
    var state = session_replay.replayBoundary(
        alloc,
        events,
        position,
        cancel_flag,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.Cancelled => return err,
        else => return error.LegacySessionMigrationIndeterminate,
    };
    errdefer state.deinit(alloc);
    if (!session_projection.stateMatchesManifest(state, manifest)) {
        return error.LegacySessionMigrationIndeterminate;
    }

    const checkpoint_bytes = (try authority_module.readOptionalSessionFileCancellable(
        alloc,
        session_dir,
        "checkpoint.json",
        session_projection.checkpoint_max_bytes,
        cancel_flag,
    )) orelse return error.LegacySessionMigrationIndeterminate;
    defer alloc.free(checkpoint_bytes);
    var checkpoint = session_projection.decodeCheckpoint(
        alloc,
        checkpoint_bytes,
        cancel_flag,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.Cancelled => return err,
        else => return error.LegacySessionMigrationIndeterminate,
    };
    defer checkpoint.deinit(alloc);
    const boundary = session_projection.EventBoundary{
        .log_generation = position.log_generation,
        .seq = position.through_seq,
        .event_id = position.through_event_id,
        .event_log_bytes = position.through_event_log_bytes,
        .semantic = true,
    };
    session_projection.validateCheckpointReference(
        manifest,
        checkpoint_bytes,
        checkpoint,
        boundary,
        boundary,
        cancel_flag,
    ) catch |err| switch (err) {
        error.Cancelled => return err,
        else => return error.LegacySessionMigrationIndeterminate,
    };
    return state;
}

/// Assembles a `LoadedWritableSession` from an already-committed migration
/// target, reading manifest metadata and carrying source schema/bytes from the
/// transition. Consumes `writable`.
pub fn loadedMigrationTarget(
    alloc: Allocator,
    writable: *session_log.WritableSessionDir,
    state: session_codec.DurableSessionState,
    transition: AuthorityTransition,
) !LoadedWritableSession {
    const manifest_bytes = (try readOptionalSessionFile(
        alloc,
        &writable.dir,
        "session.json",
        session_projection.manifest_max_bytes,
    )) orelse return error.LegacySessionMigrationIndeterminate;
    defer alloc.free(manifest_bytes);
    var manifest = session_projection.decodeManifest(
        alloc,
        manifest_bytes,
    ) catch return error.LegacySessionMigrationIndeterminate;
    defer manifest.deinit(alloc);
    const active_id = try alloc.dupe(u8, writable.session_id);
    errdefer alloc.free(active_id);
    const source_schema_version: ?u8 = if (transition.prior) |prior|
        @intFromEnum(prior.schema)
    else
        null;
    const source_bytes: ?u64 = if (transition.prior) |prior|
        prior.primary_bytes
    else
        null;
    const loaded = LoadedWritableSession{
        .active_id = active_id,
        .state = state,
        .log = writable.*,
        .position = transition.proposed,
        .authority_id = transition.authority_id,
        .generation_base_seq = manifest.generation_base_seq,
        .generation_base_bytes = manifest.generation_base_bytes,
        .checkpoint_seq = manifest.checkpoint_seq,
        .checkpoint_sha256 = manifest.checkpoint_sha256,
        .projection_status = .current,
        .migration_source_schema_version = source_schema_version,
        .migration_source_bytes = source_bytes,
    };
    writable.* = undefined;
    return loaded;
}

fn decodeMigrationWatermark(
    alloc: Allocator,
    bytes: []const u8,
    session_id: []const u8,
) !session_log.CommitPosition {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    const expected_keys = [_][]const u8{
        "schema_version",
        "session_id",
        "log_generation",
        "through_seq",
        "through_event_id",
        "through_event_log_bytes",
    };
    const object = try exactJsonObject(parsed.value, &expected_keys);
    if (try jsonU64(object, "schema_version") != 1 or
        !std.mem.eql(u8, try objectString(object, "session_id"), session_id))
    {
        return error.InvalidSessionFormat;
    }
    return .{
        .log_generation = try parseIdentifier(
            try objectString(object, "log_generation"),
        ),
        .through_seq = try jsonU64(object, "through_seq"),
        .through_event_id = try parseIdentifier(
            try objectString(object, "through_event_id"),
        ),
        .through_event_log_bytes = try jsonU64(
            object,
            "through_event_log_bytes",
        ),
    };
}

/// Converts a parsed legacy session into a validated `DurableSessionState`,
/// resolving the origin/current workspace roots and merging preferences from
/// the requested or preserved workspace. Consumes `legacy` (transfers its
/// owned id/history into the returned state).
pub fn legacyToDurableState(
    ctx: StoreContext,
    alloc: Allocator,
    legacy: *LegacyStoredSession,
    requesting_workspace: []const u8,
    preference_source: MigrationPreferenceSource,
    seed_preferences: ?session_codec.DurableSessionPreferences,
    cancel_flag: ?*const std.atomic.Value(bool),
) !session_codec.DurableSessionState {
    const root = legacy.workspace_root orelse ctx.workspace_root;
    try validateWorkspaceRoot(root);
    const origin = if (legacy.workspace_root != null)
        legacy.workspace_root.?
    else
        try alloc.dupe(u8, root);
    errdefer if (legacy.workspace_root == null) alloc.free(origin);
    const current = try alloc.dupe(u8, root);
    errdefer alloc.free(current);
    const preferences = try loadMigrationPreferences(
        ctx,
        alloc,
        switch (preference_source) {
            .requesting_workspace => requesting_workspace,
            .preserved_workspace => root,
        },
        seed_preferences,
    );
    errdefer {
        var owned = preferences;
        owned.deinit(alloc);
    }
    const state = session_codec.DurableSessionState{
        .id = legacy.id,
        .origin_workspace_root = origin,
        .workspace_root = current,
        .created_at_ms = legacy.created_at_ms,
        .updated_at_ms = legacy.updated_at_ms,
        .conversation_language = legacy.conversation_language,
        .preferences = preferences,
        .history = legacy.history,
        .total_input_tokens = legacy.total_input_tokens,
        .total_output_tokens = legacy.total_output_tokens,
    };
    try session_codec.validateState(state, cancel_flag);
    legacy.id = &.{};
    legacy.workspace_root = null;
    legacy.history = &.{};
    return state;
}

fn loadMigrationPreferences(
    ctx: StoreContext,
    alloc: Allocator,
    workspace_root: []const u8,
    seed_preferences: ?session_codec.DurableSessionPreferences,
) !session_codec.DurableSessionPreferences {
    if (seed_preferences) |preferences| return preferences.dupe(alloc);
    var detailed = try config_runtime.loadMergedSettingsDetailedFromHome(
        alloc,
        ctx.home_dir,
        workspace_root,
    );
    defer detailed.deinit(alloc);
    return .{
        .model = try alloc.dupe(
            u8,
            detailed.settings.models.get(.gateway) orelse "anthropic/claude-opus-4.7",
        ),
        .effort = detailed.settings.effort orelse .auto,
        .fast_mode = detailed.settings.fast_mode orelse false,
    };
}

fn randomIdentifier() session_event.Identifier {
    var id: session_event.Identifier = undefined;
    io_mod.getIo().random(&id);
    return id;
}

/// Reads the retained `session.legacy.json` to report the migrated source
/// schema version. Used to populate `SessionMigrationResult` after the fact.
pub fn migratedSourceSchemaVersion(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    allow_large: bool,
) !u8 {
    const source_bytes = try migratedSourceBytes(session_dir);
    const max_bytes = if (allow_large)
        (std.math.cast(usize, source_bytes + 1) orelse return error.LegacySessionMigrationResourceExhausted)
    else
        automatic_legacy_max_bytes + 1;
    const bytes = (try readOptionalSessionFile(
        alloc,
        session_dir,
        "session.legacy.json",
        max_bytes,
    )) orelse return error.SessionNotFound;
    defer alloc.free(bytes);
    return @intFromEnum(try session_json.parseLegacySchemaVersion(alloc, bytes, null));
}

/// Returns the byte size of the retained `session.legacy.json` source.
pub fn migratedSourceBytes(session_dir: *io_mod.VerifiedDir) !u64 {
    const stat = try session_dir.dir.statFile(
        io_mod.getIo(),
        "session.legacy.json",
        .{ .follow_symlinks = false },
    );
    return stat.size;
}

test "legacy migration cancellation stops encoding and preserves authority fences" {
    const Phase = enum { encoding, authority, validation };
    const Pause = struct {
        phase: Phase,
        armed: bool = false,
        observed: bool = false,
        entered: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
        cancel_flag: std.atomic.Value(bool) = .init(false),
        requested_at: i128 = 0,

        fn allocator(self: *@This()) Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
        }
        fn allocate(raw: *anyopaque, size: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const bytes = std.testing.allocator.rawAlloc(size, alignment, ra);
            if (self.armed and size >= 64 * 1024 and !self.observed) self.pause();
            return bytes;
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
        fn prepare(raw: ?*anyopaque, _: Allocator, _: []const u8, _: ?*const std.atomic.Value(bool)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.armed = self.phase == .encoding;
        }
        fn boundary(raw: ?*anyopaque, boundary_value: session_log.Boundary) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.phase == .authority and boundary_value == .after_authority_intent_sync) self.pause();
            if (self.phase == .validation and boundary_value == .after_authority_marker_rename) self.armed = true;
        }
        fn pause(self: *@This()) void {
            self.observed = true;
            self.entered.set(io_mod.getIo());
            self.released.waitUncancelable(io_mod.getIo());
        }
        fn cancel(self: *@This()) void {
            self.entered.waitUncancelable(io_mod.getIo());
            self.requested_at = io_mod.nanoTimestamp();
            self.cancel_flag.store(true, .release);
            self.released.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    for (std.enums.values(Phase)) |phase| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        defer alloc.free(home);
        var root = try session_log.Root.initFromHome(alloc, home, .writable);
        defer root.deinit(alloc);
        var dir = try io_mod.openOrCreateVerifiedPrivateDir(&root.sessions.?, "legacy-cancel");
        const lock = try io_mod.acquireTimedAdvisoryLock(&dir, "session.lock", 0);
        var writable = session_log.WritableSessionDir{ .dir = dir, .writer_lock = lock, .session_id = try alloc.dupe(u8, "legacy-cancel") };
        var owns_writable = true;
        defer if (owns_writable) writable.deinit(alloc);
        const history = [_]session.HistoryTurn{.{ .assistant = .{ .user = .{ .text = @constCast("saved") }, .assistant = @constCast("x" ** (256 * 1024)) } }};
        const bytes = try session_json.renderSessionJson(alloc, "legacy-cancel", 1, 1, .default(), "/workspace", &history, .{});
        defer alloc.free(bytes);
        try io_mod.durableReplaceVerified(alloc, &writable.dir, "session.json", bytes);
        const before = try writable.dir.dir.statFile(io_mod.getIo(), "session.json", .{});
        var pause = Pause{ .phase = phase };
        var lifecycle: ?session_log.CommitLifecycle = .{ .context = &pause, .prepare_fn = Pause.prepare };
        defer if (lifecycle) |*value| value.deinit(alloc);
        const thread = try std.Thread.spawn(.{}, Pause.cancel, .{&pause});
        var failure: ?anyerror = null;
        if (migrateLegacyLocked(.{ .sessions_dir = root.display_root, .home_dir = home, .workspace_root = "/workspace", .canonical_root = root }, pause.allocator(), &writable, "/workspace", .requesting_workspace, .{ .seed_preferences = .{ .model = @constCast("test/model"), .effort = .auto, .fast_mode = false }, .log = .{ .cancel_flag = &pause.cancel_flag, .test_controls = .{ .context = &pause, .boundary_fn = Pause.boundary } } }, &lifecycle)) |value| {
            owns_writable = false;
            var loaded = value;
            loaded.deinit(pause.allocator());
        } else |err| failure = err;
        pause.entered.set(io_mod.getIo());
        thread.join();
        try std.testing.expect(pause.observed);
        try std.testing.expectEqual(@as(?anyerror, if (phase == .encoding) error.Cancelled else error.LegacySessionMigrationIndeterminate), failure);
        try std.testing.expect(io_mod.nanoTimestamp() - pause.requested_at < 500 * std.time.ns_per_ms);
        const after = try writable.dir.dir.statFile(io_mod.getIo(), "session.json", .{});
        if (phase != .validation) {
            try std.testing.expectEqual(before.inode, after.inode);
            try std.testing.expectEqual(before.size, after.size);
            try std.testing.expectEqual(before.mtime, after.mtime);
        }
        try std.testing.expectEqual(phase != .encoding, try entryExistsRelative(&writable.dir, "authority.pending.json"));
        if (phase != .encoding) try std.testing.expectError(error.SessionAuthorityBoundaryUnavailable, root.confirmStoredResumeHandoff(alloc, "legacy-cancel", null));
        if (phase == .validation) {
            try io_mod.durableReplaceVerified(alloc, &writable.dir, "checkpoint.json", "invalid");
            var transition = (try authority_module.loadAuthorityTransitionOptional(alloc, &writable.dir)).?;
            defer transition.deinit(alloc);
            var rollback_pause = Pause{ .phase = .encoding, .armed = true };
            const rollback_thread = try std.Thread.spawn(.{}, Pause.cancel, .{&rollback_pause});
            var rollback_failure: ?anyerror = null;
            authority_module.restoreLegacyAuthority(rollback_pause.allocator(), &writable, transition, &rollback_pause.cancel_flag) catch |err| {
                rollback_failure = err;
            };
            rollback_pause.entered.set(io_mod.getIo());
            rollback_thread.join();
            try std.testing.expect(rollback_pause.observed);
            try std.testing.expectEqual(@as(?anyerror, error.Cancelled), rollback_failure);
            try std.testing.expect(io_mod.nanoTimestamp() - rollback_pause.requested_at < 500 * std.time.ns_per_ms);
            const after_rollback = try writable.dir.dir.statFile(io_mod.getIo(), "session.json", .{});
            try std.testing.expectEqual(after.inode, after_rollback.inode);
            try std.testing.expect(try entryExistsRelative(&writable.dir, "authority.pending.json"));
        }
    }
}
