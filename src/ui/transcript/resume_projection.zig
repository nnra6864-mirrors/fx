const std = @import("std");
const assistant_presentation = @import("../../core/agent/assistant_presentation.zig");
const diff = @import("../../core/output/diff.zig");
const types = @import("../../core/shared/types.zig");
const command_output_content = @import("../../core/tooling/command_output_content.zig");
const command_output_runtime = @import("command_output_runtime.zig");
const transcript_painter = @import("painter.zig");
const presentation_record = @import("presentation_record.zig");
const resume_snapshot = @import("resume_snapshot.zig");
const source_preparation = @import("source_preparation.zig");
const transcript_runtime = @import("runtime.zig");
const transcript_store = @import("store.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");

const Allocator = std.mem.Allocator;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

/// Owned, detached presentation state for one resume. All effectful artifact,
/// background, and policy decisions are resolved before values enter here.
pub const ResumeProjection = struct {
    runtime: TranscriptRuntime,
    alloc: Allocator,
    created_at_ms: i64,
    retention_cap: usize,
    postlude_entries: std.ArrayList(transcript_runtime.TranscriptEntry) = .empty,
    record_cursor: presentation_record.Cursor = .start,
    publication_source: ?transcript_runtime.TranscriptPreparationSource = null,
    pending_diffs: std.ArrayList(diff.DiffEntry) = .empty,
    next_diff_id: u32,
    retention_changed: bool = false,
    finalized: bool = false,
    consumed: bool = false,

    pub fn init(
        alloc: Allocator,
        source: *TranscriptRuntime,
        created_at_ms: i64,
        next_diff_id: u32,
    ) !ResumeProjection {
        return initDetached(alloc, source, created_at_ms, next_diff_id, true);
    }

    fn initDetached(
        alloc: Allocator,
        source: *TranscriptRuntime,
        created_at_ms: i64,
        next_diff_id: u32,
        capture_postlude: bool,
    ) !ResumeProjection {
        var detached = try transcript_store.cloneDetachedPresentationState(source, alloc);
        errdefer detached.deinit(alloc);
        const retention_cap = source.configuredTranscriptRetentionCap();
        var postlude_entries: std.ArrayList(transcript_runtime.TranscriptEntry) = .empty;
        if (capture_postlude and detached.entries.items.len > 0) {
            postlude_entries = detached.entries;
            detached.entries = .empty;
        }
        detached.clearTranscript(alloc);
        detached.next_entry_id = 1;
        detached.max_retained_transcript_bytes = std.math.maxInt(usize);
        return .{
            .runtime = detached,
            .alloc = alloc,
            .created_at_ms = created_at_ms,
            .retention_cap = retention_cap,
            .postlude_entries = postlude_entries,
            .next_diff_id = next_diff_id,
        };
    }

    /// Start a detached projection with the source runtime's presentation
    /// policy but none of its conversation content.
    pub fn initEmpty(
        alloc: Allocator,
        source: *TranscriptRuntime,
        created_at_ms: i64,
        next_diff_id: u32,
    ) !ResumeProjection {
        return initDetached(
            alloc,
            source,
            created_at_ms,
            next_diff_id,
            false,
        );
    }

    pub fn initComplete(
        alloc: Allocator,
        source: *TranscriptRuntime,
        created_at_ms: i64,
        next_diff_id: u32,
    ) !ResumeProjection {
        var detached = try transcript_store.cloneDetachedPresentationState(
            source,
            alloc,
        );
        errdefer detached.deinit(alloc);
        const retention_cap = source.configuredTranscriptRetentionCap();
        detached.max_retained_transcript_bytes = std.math.maxInt(usize);
        detached.restoreHistoricalToolTurnWatermark(
            historicalToolTurnWatermark(detached.tool_details.items),
        );
        return .{
            .runtime = detached,
            .alloc = alloc,
            .created_at_ms = created_at_ms,
            .retention_cap = retention_cap,
            .next_diff_id = next_diff_id,
        };
    }

    pub fn deinit(self: *ResumeProjection) void {
        if (!self.consumed) self.runtime.deinit(self.alloc);
        for (self.postlude_entries.items) |*entry| entry.deinit(self.alloc);
        self.postlude_entries.deinit(self.alloc);
        if (self.publication_source) |*source| source.deinit(self.alloc);
        for (self.pending_diffs.items) |*entry| entry.deinit(std.heap.c_allocator);
        self.pending_diffs.deinit(std.heap.c_allocator);
        self.* = undefined;
    }

    fn appendEntry(self: *ResumeProjection, entry: transcript_runtime.TranscriptEntry) !u32 {
        const entry_id = entry.id();
        try self.runtime.entries.append(self.alloc, entry);
        self.runtime.next_entry_id +%= 1;
        self.runtime.replaceable_last_line = false;
        self.runtime.replaceable_start = 0;
        return entry_id;
    }

    pub fn appendNotice(self: *ResumeProjection, notice: types.SemanticNotice) !u32 {
        const owned = try types.dupeSemanticNotice(self.alloc, notice);
        errdefer types.freeSemanticNotice(self.alloc, owned);
        return self.appendEntry(.{ .semantic_notice = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .topic = owned.topic,
            .tone = owned.tone,
            .body = owned.body,
            .visibility = owned.visibility,
        } });
    }

    pub fn appendUserTurn(self: *ResumeProjection, turn: types.UserTurn) !u32 {
        const owned = try types.dupeUserTurn(self.alloc, turn);
        errdefer {
            types.freeUserTurn(self.alloc, owned);
        }
        return self.appendEntry(.{ .user_turn = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .turn = owned,
        } });
    }

    pub fn appendRawClassified(
        self: *ResumeProjection,
        text: []const u8,
        class: transcript_runtime.RawEntryClass,
    ) !u32 {
        if (text.len == 0) return 0;
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        return self.appendRawOwned(owned, class);
    }

    fn appendRawOwned(
        self: *ResumeProjection,
        owned: []u8,
        class: transcript_runtime.RawEntryClass,
    ) !u32 {
        errdefer self.alloc.free(owned);
        return self.appendEntry(.{ .raw_bytes = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .bytes = owned,
            .class = class,
        } });
    }

    pub fn appendReplaceableLine(self: *ResumeProjection, text: []const u8) !u32 {
        const entry_id = try self.appendRawClassified(text, .unknown_raw);
        if (entry_id != 0) self.runtime.replaceable_last_line = true;
        return entry_id;
    }

    pub fn appendToolStatus(
        self: *ResumeProjection,
        kind: types.ToolOutcomeKind,
        summary: []const u8,
    ) !u32 {
        const line = try transcript_runtime.formatHistoricalToolStatusLine(
            self.alloc,
            kind,
            summary,
        );
        return self.appendRawOwned(line, .tool_status);
    }

    pub fn appendAssistantText(self: *ResumeProjection, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.runtime.tailAssistantSegments()) |segments| {
            try segments.text.appendSlice(self.alloc, text);
            return;
        }
        var segments: transcript_runtime.AssistantTurnSegments = .{};
        errdefer segments.deinit(self.alloc);
        try segments.text.appendSlice(self.alloc, text);
        _ = try self.appendEntry(.{ .assistant_turn = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .segments = segments,
        } });
    }

    pub fn appendAssistantTable(
        self: *ResumeProjection,
        table: assistant_presentation.TablePayload,
    ) !void {
        _ = try self.appendEntry(.{ .assistant_table = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .table = table,
        } });
    }

    pub fn appendAssistantCodeBlock(
        self: *ResumeProjection,
        block: assistant_presentation.CodeBlockPayload,
    ) !void {
        _ = try self.appendEntry(.{ .assistant_code_block = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
            .block = block,
        } });
    }

    pub fn appendAssistantThematicRule(self: *ResumeProjection) !void {
        _ = try self.appendEntry(.{ .assistant_thematic_rule = .{
            .id = self.runtime.next_entry_id,
            .created_at_ms = self.created_at_ms,
        } });
    }

    pub fn appendCommandOutput(
        self: *ResumeProjection,
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_output_content.Stream,
        text: []const u8,
    ) !void {
        var metrics: types.Metrics = .{};
        _ = try command_output_runtime.writeCommandOutputChunkDetached(
            &self.runtime,
            self.alloc,
            &metrics,
            self.runtime.retainedTranscriptStyles(),
            lifecycle_id,
            stream,
            text,
            true,
            self.created_at_ms,
        );
    }

    pub fn finishCommandOutput(
        self: *ResumeProjection,
        lifecycle_id: ?types.ToolLifecycleId,
    ) !void {
        try command_output_runtime.flushCommandOutputSummaryDetached(
            &self.runtime,
            self.alloc,
            self.runtime.retainedTranscriptStyles(),
            lifecycle_id,
            self.created_at_ms,
        );
    }

    pub fn attachHistoricalToolDetail(
        self: *ResumeProjection,
        entry_id: u32,
        call: types.ToolCall,
        activity_kind: types.ToolActivityKind,
        result: types.PersistedToolResult,
    ) !void {
        try self.runtime.attachHistoricalToolDetail(
            self.alloc,
            entry_id,
            call,
            activity_kind,
            result,
        );
    }

    pub fn attachHistoricalToolDetailWithLifecycle(
        self: *ResumeProjection,
        entry_id: u32,
        call: types.ToolCall,
        activity_kind: types.ToolActivityKind,
        result: types.PersistedToolResult,
        lifecycle_id: types.ToolLifecycleId,
    ) !void {
        try self.runtime.attachHistoricalToolDetailWithLifecycle(
            self.alloc,
            entry_id,
            call,
            activity_kind,
            result,
            lifecycle_id,
        );
    }

    pub fn attachHistoricalToolDetailAfterCommandOutput(
        self: *ResumeProjection,
        entry_id: u32,
        call: types.ToolCall,
        activity_kind: types.ToolActivityKind,
        result: types.PersistedToolResult,
    ) !void {
        try self.runtime.attachHistoricalToolDetailAfterCommandOutputDetached(
            self.alloc,
            entry_id,
            call,
            activity_kind,
            result,
        );
    }

    pub fn attachHistoricalToolCallWithoutResult(
        self: *ResumeProjection,
        entry_id: u32,
        call: types.ToolCall,
    ) !void {
        try self.runtime.attachHistoricalToolCallWithoutResult(
            self.alloc,
            entry_id,
            call,
        );
    }

    pub fn attachHistoricalCommandOutput(
        self: *ResumeProjection,
        entry_id: u32,
    ) void {
        self.runtime.attachHistoricalCommandOutput(self.alloc, entry_id);
    }

    pub fn attachHistoricalCancelledCommandDetail(
        self: *ResumeProjection,
        entry_id: u32,
        call: types.ToolCall,
        command_artifact_handle: ?[]const u8,
        replayed_output: bool,
    ) !void {
        try self.runtime.attachHistoricalCancelledCommandDetail(
            self.alloc,
            entry_id,
            call,
            command_artifact_handle,
            replayed_output,
        );
    }

    pub fn appendDiff(self: *ResumeProjection, payload: diff.DiffEntryPayload) !void {
        const c_alloc = std.heap.c_allocator;
        var owns_payload = true;
        errdefer if (owns_payload) diff.freeDiffEntryPayload(c_alloc, payload);

        const id = self.next_diff_id;
        const wrapped = try diff.wrapWithMarkers(c_alloc, id, payload.preview);
        defer c_alloc.free(wrapped);
        _ = try self.appendRawClassified(wrapped, .diff_block);
        try self.pending_diffs.append(c_alloc, .{ .id = id, .full = payload.full });
        c_alloc.free(payload.preview);
        owns_payload = false;
        self.next_diff_id += 1;
    }

    pub fn finalize(self: *ResumeProjection) !void {
        return self.finalizeForPresentation(false, false);
    }

    pub fn finalizeForResume(
        self: *ResumeProjection,
        postlude_persisted: bool,
    ) !void {
        if (postlude_persisted) try self.appendPostlude();
        return self.finalizeForPresentation(false, true);
    }

    /// A live projection may end at a valid command-output prefix. Keep that
    /// block open so later output and its terminal event can continue it.
    pub fn finalizeLivePresentation(self: *ResumeProjection) !void {
        return self.finalizeForPresentation(true, false);
    }

    fn finalizeForPresentation(
        self: *ResumeProjection,
        allow_open_command_block: bool,
        preserve_complete_semantics: bool,
    ) !void {
        return self.finalizeInner(
            allow_open_command_block,
            preserve_complete_semantics,
        ) catch |err| switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    }

    fn finalizeInner(
        self: *ResumeProjection,
        allow_open_command_block: bool,
        preserve_complete_semantics: bool,
    ) !void {
        std.debug.assert(!self.finalized);
        std.debug.assert(!self.consumed);
        std.debug.assert(
            allow_open_command_block or
                self.runtime.command_output_display.open_command_block == null,
        );

        _ = try command_output_runtime.syncCommandOutputBlockEntries(
            &self.runtime,
            self.alloc,
        );
        self.record_cursor = cursorAfterLastEntry(&self.runtime);
        var source = try source_preparation.prepareTranscriptSource(
            &self.runtime,
            self.alloc,
            null,
        );
        const full_flow = source.bytes;
        source.bytes = &.{};
        source.deinit(self.alloc);
        self.publication_source = try source_preparation.prepareFullTranscriptViewportSource(
            &self.runtime,
            self.alloc,
            full_flow,
        );

        self.runtime.max_retained_transcript_bytes = self.retention_cap;
        const retention_changed = if (preserve_complete_semantics)
            transcript_store.retainedStructuredBytes(&self.runtime) > self.retention_cap
        else
            try self.runtime.enforceStructuredRetentionAndReport(
                self.alloc,
                null,
            );
        self.retention_changed = retention_changed;
        if (!retention_changed or preserve_complete_semantics) {
            self.runtime.transcript.clearRetainingCapacity();
            self.runtime.replaceable_last_line = false;
            self.runtime.replaceable_start = 0;
            _ = try transcript_store.appendCappedWithinCapacity(
                &self.runtime.transcript,
                self.alloc,
                self.publication_source.?.bytes,
                self.runtime.max_transcript_bytes,
                &self.runtime.replaceable_last_line,
                &self.runtime.replaceable_start,
            );
            self.runtime.last_rendered_cols = self.runtime.layout.cols;
            self.runtime.transcript_cache_origin_untrimmed =
                self.runtime.transcript.items.len == self.publication_source.?.bytes.len;
        }
        self.runtime.recomputeCursorFromTranscript();
        self.finalized = true;
    }

    pub fn publicationBytes(self: *const ResumeProjection) []const u8 {
        std.debug.assert(self.finalized);
        std.debug.assert(!self.consumed);
        return self.publication_source.?.bytes;
    }

    /// Returns allocator-owned terminal-wire bytes for direct stream and
    /// persistence. Logical LF separators become explicit CRLF.
    pub fn publicationWireBytes(
        self: *const ResumeProjection,
        cols: u16,
    ) ![]u8 {
        const bytes = self.publicationBytes();
        const prepared = try transcript_painter.prepareTranscriptDocumentAppendBytes(
            self.alloc,
            bytes,
            cols,
            0,
            bytes.len,
            true,
        );
        if (prepared.len > 0) return prepared;
        return self.alloc.dupe(u8, bytes);
    }

    pub fn recordCursor(self: *const ResumeProjection) presentation_record.Cursor {
        std.debug.assert(self.finalized);
        std.debug.assert(!self.consumed);
        return self.record_cursor;
    }

    pub fn retentionChanged(self: *const ResumeProjection) bool {
        std.debug.assert(self.finalized);
        std.debug.assert(!self.consumed);
        return self.retention_changed;
    }

    pub fn snapshotView(self: *const ResumeProjection) resume_snapshot.View {
        std.debug.assert(self.finalized);
        return .{
            .entries = self.runtime.entries.items,
            .tool_details = self.runtime.tool_details.items,
            .folded_command_blocks = self.runtime.folded_command_blocks.items,
            .command_output_blocks = self.runtime.command_output_blocks.items,
            .command_output_display = self.runtime.command_output_display,
            .transcript = self.runtime.transcript.items,
            .diffs = self.pending_diffs.items,
            .record_cursor = self.record_cursor,
            .next_entry_id = self.runtime.next_entry_id,
            .next_diff_id = self.next_diff_id,
            .last_rendered_cols = self.runtime.last_rendered_cols,
            .transcript_cache_origin_untrimmed = self.runtime.transcript_cache_origin_untrimmed,
            .replaceable_last_line = self.runtime.replaceable_last_line,
            .replaceable_row = self.runtime.replaceable_row,
            .replaceable_start = self.runtime.replaceable_start,
            .retention_cap = self.retention_cap,
            .retention_changed = self.retention_changed,
        };
    }

    pub fn adoptSnapshot(
        self: *ResumeProjection,
        snapshot: *resume_snapshot.Owned,
    ) !void {
        std.debug.assert(!self.finalized);
        std.debug.assert(!self.consumed);
        std.debug.assert(self.runtime.entries.items.len == 0);
        std.debug.assert(self.runtime.tool_details.items.len == 0);
        std.debug.assert(self.runtime.folded_command_blocks.items.len == 0);
        std.debug.assert(self.runtime.command_output_blocks.items.len == 0);
        std.debug.assert(self.runtime.transcript.items.len == 0);
        std.debug.assert(self.pending_diffs.items.len == 0);

        self.runtime.entries = listFromOwnedSlice(
            transcript_blocks.TranscriptEntry,
            snapshot.entries,
        );
        snapshot.entries = &.{};
        self.runtime.tool_details = listFromOwnedSlice(
            transcript_blocks.ToolDetailRecord,
            snapshot.tool_details,
        );
        snapshot.tool_details = &.{};
        self.runtime.folded_command_blocks = listFromOwnedSlice(
            command_output_runtime.FoldedCommandBlock,
            snapshot.folded_command_blocks,
        );
        snapshot.folded_command_blocks = &.{};
        self.runtime.command_output_blocks = listFromOwnedSlice(
            command_output_runtime.CommandOutputBlock,
            snapshot.command_output_blocks,
        );
        snapshot.command_output_blocks = &.{};
        self.runtime.command_output_display = snapshot.command_output_display;
        self.runtime.transcript = listFromOwnedSlice(u8, snapshot.transcript);
        snapshot.transcript = &.{};
        const installed_diffs = try cloneDiffEntries(
            std.heap.c_allocator,
            snapshot.diffs,
        );
        for (snapshot.diffs) |*entry| entry.deinit(self.alloc);
        if (snapshot.diffs.len > 0) self.alloc.free(snapshot.diffs);
        snapshot.diffs = &.{};
        self.pending_diffs = listFromOwnedSlice(diff.DiffEntry, installed_diffs);

        self.record_cursor = snapshot.record_cursor;
        self.runtime.next_entry_id = snapshot.next_entry_id;
        self.next_diff_id = snapshot.next_diff_id;
        self.runtime.last_rendered_cols = snapshot.last_rendered_cols;
        self.runtime.transcript_cache_origin_untrimmed =
            snapshot.transcript_cache_origin_untrimmed;
        self.runtime.replaceable_last_line = snapshot.replaceable_last_line;
        self.runtime.replaceable_row = snapshot.replaceable_row;
        self.runtime.replaceable_start = snapshot.replaceable_start;
        self.retention_cap = snapshot.retention_cap;
        self.runtime.max_retained_transcript_bytes = snapshot.retention_cap;
        self.retention_changed = snapshot.retention_changed;
        self.runtime.recomputeCursorFromTranscript();
        self.runtime.restoreHistoricalToolTurnWatermark(
            historicalToolTurnWatermark(self.runtime.tool_details.items),
        );
        self.publication_source = try self.runtime.prepareTranscriptSource(
            self.alloc,
            null,
        );
        self.finalized = true;
    }

    /// Installs structured continuation state after historical bytes were
    /// already written directly to the terminal. No pending source is armed.
    pub fn installRetained(
        self: *ResumeProjection,
        target: *TranscriptRuntime,
        streamed_history_guard_rows: u16,
    ) !void {
        std.debug.assert(self.finalized);
        std.debug.assert(!self.consumed);
        std.debug.assert(target.pending_resume_source == null);

        std.mem.swap(@TypeOf(target.entries), &target.entries, &self.runtime.entries);
        std.mem.swap(@TypeOf(target.tool_details), &target.tool_details, &self.runtime.tool_details);
        std.mem.swap(
            @TypeOf(target.folded_command_blocks),
            &target.folded_command_blocks,
            &self.runtime.folded_command_blocks,
        );
        std.mem.swap(
            @TypeOf(target.command_output_blocks),
            &target.command_output_blocks,
            &self.runtime.command_output_blocks,
        );
        std.mem.swap(@TypeOf(target.transcript), &target.transcript, &self.runtime.transcript);
        target.next_entry_id = self.runtime.next_entry_id;
        target.last_rendered_cols = self.runtime.last_rendered_cols;
        target.transcript_cache_origin_untrimmed =
            self.runtime.transcript_cache_origin_untrimmed;
        target.command_output_display = self.runtime.command_output_display;
        target.command_output_render = self.runtime.command_output_render;
        target.restoreHistoricalToolTurnWatermark(
            historicalToolTurnWatermark(target.tool_details.items),
        );
        target.replaceable_last_line = self.runtime.replaceable_last_line;
        target.replaceable_row = self.runtime.replaceable_row;
        target.replaceable_start = self.runtime.replaceable_start;
        if (target.streamedSessionHistoryActive()) {
            target.adoptStreamedSessionHistoryAt(
                self.runtime.last_rendered_cols,
            );
            target.retainCompleteStreamedSessionHistory();
            try target.establishStreamedRetainedAnchor(
                self.alloc,
                streamed_history_guard_rows,
            );
        } else {
            target.recomputeCursorFromTranscript();
        }
        target.reconcileDetachedInstallSource(self.publication_source.?.bytes);
        if (!target.streamedSessionHistoryActive()) target.markTranscriptDirty();

        var publication = self.publication_source.?;
        self.publication_source = null;
        publication.deinit(self.alloc);
        self.consumed = true;
        self.runtime.deinit(self.alloc);
    }

    /// Replays current-startup entries through the ordinary append contracts
    /// after the complete historical source has established its anchor.
    pub fn installPostludeRetained(
        self: *ResumeProjection,
        target: *TranscriptRuntime,
        metrics: *types.Metrics,
    ) !void {
        std.debug.assert(self.finalized);
        std.debug.assert(self.consumed);

        var first_entry_id: ?u32 = null;
        while (self.postlude_entries.items.len > 0) {
            const entry = self.postlude_entries.items[0];
            const entry_id = switch (entry) {
                .raw_bytes => |raw| blk: {
                    if (raw.lifecycle_pinned) return error.InvalidResumePostlude;
                    const next_id = target.next_entry_id;
                    try target.writeTranscriptClassified(
                        self.alloc,
                        metrics,
                        raw.bytes,
                        true,
                        raw.class,
                    );
                    break :blk next_id;
                },
                .semantic_notice => |notice| if (notice.pending_replacement)
                    try target.appendReplaceableSemanticNotice(self.alloc, .{
                        .topic = notice.topic,
                        .tone = notice.tone,
                        .body = notice.body,
                        .visibility = notice.visibility,
                    })
                else
                    try target.appendSemanticNotice(self.alloc, .{
                        .topic = notice.topic,
                        .tone = notice.tone,
                        .body = notice.body,
                        .visibility = notice.visibility,
                    }),
                .user_turn,
                .assistant_turn,
                .assistant_table,
                .assistant_code_block,
                .assistant_thematic_rule,
                => return error.InvalidResumePostlude,
            };
            if (first_entry_id == null) first_entry_id = entry_id;
            var removed = self.postlude_entries.orderedRemove(0);
            removed.deinit(self.alloc);
        }
        if (first_entry_id) |entry_id| {
            target.markTranscriptContentDirtyFrom(entry_id);
        }
    }

    /// Transfers a finalized detached projection into a standalone transcript
    /// runtime. The caller owns the returned runtime and must deinitialize it
    /// with the same allocator.
    pub fn intoRuntime(self: *ResumeProjection) TranscriptRuntime {
        std.debug.assert(self.finalized);
        std.debug.assert(!self.consumed);
        std.debug.assert(self.runtime.pending_resume_source == null);

        self.runtime.pending_resume_source = self.publication_source;
        self.publication_source = null;
        self.runtime.reconcileDetachedInstallSource(
            self.runtime.pendingResumeFlow(),
        );
        self.runtime.markTranscriptDirty();

        self.consumed = true;
        return self.runtime;
    }

    /// Transfers the full-diff sidecars that belong to the detached
    /// presentation. The caller owns the returned entries and must deinitialize
    /// each entry and the list with `std.heap.c_allocator`.
    pub fn takePendingDiffs(
        self: *ResumeProjection,
    ) std.ArrayList(diff.DiffEntry) {
        std.debug.assert(self.finalized);
        std.debug.assert(!self.consumed);
        const pending = self.pending_diffs;
        self.pending_diffs = .empty;
        return pending;
    }

    pub fn clonePendingDiffs(
        self: *ResumeProjection,
        source: []const diff.DiffEntry,
    ) !void {
        std.debug.assert(self.pending_diffs.items.len == 0);
        const cloned = try cloneDiffEntries(std.heap.c_allocator, source);
        self.pending_diffs = listFromOwnedSlice(diff.DiffEntry, cloned);
    }

    fn appendPostlude(self: *ResumeProjection) !void {
        _ = try self.appendPostludeTo(&self.runtime);
    }

    fn appendPostludeTo(
        self: *ResumeProjection,
        target: *TranscriptRuntime,
    ) !bool {
        if (self.postlude_entries.items.len == 0) return false;
        try target.entries.ensureUnusedCapacity(
            self.alloc,
            self.postlude_entries.items.len,
        );
        for (self.postlude_entries.items) |*entry| {
            setEntryId(entry, target.next_entry_id);
            target.entries.appendAssumeCapacity(entry.*);
            target.next_entry_id +%= 1;
        }
        self.postlude_entries.clearRetainingCapacity();
        return true;
    }
};

fn listFromOwnedSlice(comptime T: type, items: []T) std.ArrayList(T) {
    return .{ .items = items, .capacity = items.len };
}

fn historicalToolTurnWatermark(
    details: []const transcript_blocks.ToolDetailRecord,
) u64 {
    var watermark: u64 = 0;
    for (details) |detail| {
        if (detail.presentation_group_id) |group| {
            watermark = @max(watermark, group.turn_id);
        }
        if (detail.lifecycle_id) |lifecycle| {
            watermark = @max(watermark, lifecycle.turn_id);
        }
    }
    return watermark;
}

fn cloneDiffEntries(
    alloc: Allocator,
    source: []const diff.DiffEntry,
) ![]diff.DiffEntry {
    const entries = try alloc.alloc(diff.DiffEntry, source.len);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    for (source, entries) |from, *to| {
        to.* = .{ .id = from.id };
        if (from.full) |full| {
            const content = try alloc.dupe(u8, full.content);
            errdefer alloc.free(content);
            const call_id = try alloc.dupe(u8, full.lifecycle_id.call_id);
            to.full = .{
                .content = content,
                .lifecycle_id = .{
                    .turn_id = full.lifecycle_id.turn_id,
                    .call_id = call_id,
                },
            };
        }
        initialized += 1;
    }
    return entries;
}

fn setEntryId(entry: *transcript_runtime.TranscriptEntry, id: u32) void {
    switch (entry.*) {
        .raw_bytes => |*value| value.id = id,
        .semantic_notice => |*value| value.id = id,
        .user_turn => |*value| value.id = id,
        .assistant_turn => |*value| value.id = id,
        .assistant_table => |*value| value.id = id,
        .assistant_code_block => |*value| value.id = id,
        .assistant_thematic_rule => |*value| value.id = id,
    }
}

fn cursorAfterLastEntry(
    runtime: *const TranscriptRuntime,
) presentation_record.Cursor {
    var index = runtime.entries.items.len;
    while (index > 0) {
        index -= 1;
        const entry = runtime.entries.items[index];
        if (!transcript_blocks.isEntryVisibleInCompactPresentation(entry)) continue;
        return .{ .after = .{
            .entry_id = entry.id(),
            .kind = transcript_blocks.blockKindForEntry(entry),
            .ends_with_newline = false,
        } };
    }
    return .start;
}

test "resume projection finalizes complete flow before one retained-tail pass" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 40,
        .cols = 80,
        .content_bottom = 36,
        .divider_top_row = 37,
        .input_row = 38,
        .divider_bottom_row = 39,
        .hint_row = 40,
    };
    source.max_retained_transcript_bytes = 96;
    defer source.deinit(alloc);

    var projection = try ResumeProjection.init(alloc, &source, 42, 1);
    defer projection.deinit();
    _ = try projection.appendNotice(.{
        .topic = "session",
        .tone = .neutral,
        .body = "resumed: fixture",
    });
    for (0..12) |index| {
        var text: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&text, "historical marker {d}\n", .{index});
        _ = try projection.appendRawClassified(line, .unknown_raw);
    }
    try projection.finalize();

    try std.testing.expect(std.mem.find(u8, projection.publication_source.?.bytes, "historical marker 0") != null);
    try std.testing.expect(std.mem.find(u8, projection.publication_source.?.bytes, "historical marker 11") != null);
    try std.testing.expect(projection.runtime.entries.items.len < 13);
    try std.testing.expect(projection.retentionChanged());
}

test "resume projection appends current startup presentation after history" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    defer source.deinit(alloc);
    _ = try source.appendRawTranscriptEntryClassified(
        alloc,
        "STARTUP_WARNING_MARKER\n",
        .unknown_raw,
    );
    _ = try source.appendSemanticNotice(alloc, .{
        .topic = "system",
        .tone = .information,
        .body = "STARTUP_WARNING_FULL_DETAIL",
        .visibility = .full_only,
    });

    var projection = try ResumeProjection.init(alloc, &source, 42, 1);
    defer projection.deinit();
    _ = try projection.appendRawClassified(
        "HISTORICAL_SESSION_MARKER\n",
        .unknown_raw,
    );
    try projection.finalizeForResume(true);

    const bytes = projection.publicationBytes();
    const history = std.mem.find(u8, bytes, "HISTORICAL_SESSION_MARKER") orelse
        return error.MissingHistoricalSessionMarker;
    const startup = std.mem.find(u8, bytes, "STARTUP_WARNING_MARKER") orelse
        return error.MissingStartupWarningMarker;
    try std.testing.expect(history < startup);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, bytes, "HISTORICAL_SESSION_MARKER"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, bytes, "STARTUP_WARNING_MARKER"),
    );
    try std.testing.expect(std.mem.find(
        u8,
        bytes,
        "STARTUP_WARNING_FULL_DETAIL",
    ) == null);
    try std.testing.expectEqual(
        @as(u32, 2),
        projection.recordCursor().after.entry_id,
    );
}

test "exact resume retains structured startup presentation outside the historical anchor" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    defer source.deinit(alloc);
    _ = try source.appendRawTranscriptEntryClassified(
        alloc,
        "CURRENT_STARTUP_SUMMARY\n",
        .unknown_raw,
    );
    _ = try source.appendSemanticNotice(alloc, .{
        .topic = "system",
        .tone = .information,
        .body = "CURRENT_STARTUP_FULL_DETAIL",
        .visibility = .full_only,
    });

    var projection = try ResumeProjection.init(alloc, &source, 42, 1);
    defer projection.deinit();
    _ = try projection.appendRawClassified(
        "EXACT_HISTORICAL_ENTRY\n",
        .unknown_raw,
    );
    try projection.finalizeForResume(false);

    try std.testing.expect(std.mem.find(
        u8,
        projection.publicationBytes(),
        "CURRENT_STARTUP_SUMMARY",
    ) == null);
    try std.testing.expectEqual(
        @as(u32, 1),
        projection.recordCursor().after.entry_id,
    );
    var target: TranscriptRuntime = .{};
    target.layout = source.layout;
    defer target.deinit(alloc);
    try target.enableShadowVt(alloc);
    target.adoptStreamedSessionHistory();
    target.resumePresentationRecordAt(64, projection.recordCursor());
    try projection.installRetained(&target, 0);
    var metrics: types.Metrics = .{};
    try projection.installPostludeRetained(&target, &metrics);

    try std.testing.expectEqual(@as(usize, 3), target.entries.items.len);
    try std.testing.expectEqualStrings(
        "CURRENT_STARTUP_SUMMARY\n",
        target.entries.items[1].raw_bytes.bytes,
    );
    try std.testing.expectEqual(
        types.NoticeVisibility.full_only,
        target.entries.items[2].semantic_notice.visibility,
    );
    try std.testing.expectEqualStrings(
        "CURRENT_STARTUP_FULL_DETAIL",
        target.entries.items[2].semantic_notice.body,
    );
    try std.testing.expectEqual(@as(u32, 2), target.entries.items[1].id());
    try std.testing.expectEqual(@as(u32, 3), target.entries.items[2].id());
    try std.testing.expect(!target.presentationRecordReadyForReset());

    var compact = try target.prepareTranscriptSource(alloc, null);
    defer compact.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        compact.bytes,
        "CURRENT_STARTUP_SUMMARY",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        compact.bytes,
        "CURRENT_STARTUP_FULL_DETAIL",
    ) == null);
}

test "resume projection converts complete publication to terminal wire bytes" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout.cols = 80;
    defer source.deinit(alloc);

    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 1);
    defer projection.deinit();
    _ = try projection.appendRawClassified("one\ntwo\n", .unknown_raw);
    try projection.finalize();

    const wire_bytes = try projection.publicationWireBytes(80);
    defer alloc.free(wire_bytes);
    try std.testing.expectEqualStrings("one\r\ntwo", wire_bytes);
    for (wire_bytes, 0..) |byte, index| {
        if (byte == '\n') {
            try std.testing.expect(index > 0 and wire_bytes[index - 1] == '\r');
        }
    }
}

test "empty resume projection keeps layout without source conversation" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 24,
        .cols = 72,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    defer source.deinit(alloc);
    _ = try source.appendRawTranscriptEntry(alloc, "main-only marker\n");

    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 1);
    defer projection.deinit();
    try std.testing.expectEqual(source.layout.cols, projection.runtime.layout.cols);
    try std.testing.expectEqual(@as(usize, 0), projection.runtime.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), projection.runtime.transcript.items.len);

    _ = try projection.appendRawClassified("child-only marker\n", .unknown_raw);
    try projection.finalize();
    try std.testing.expect(std.mem.find(u8, projection.publication_source.?.bytes, "main-only marker") == null);
    try std.testing.expect(std.mem.find(u8, projection.publication_source.?.bytes, "child-only marker") != null);
    try std.testing.expectEqual(@as(usize, 1), source.entries.items.len);
}

test "resume projection can install retained continuation without publication" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 24,
        .cols = 72,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    defer source.deinit(alloc);
    var target: TranscriptRuntime = .{};
    target.layout = source.layout;
    defer target.deinit(alloc);
    try target.enableShadowVt(alloc);
    target.shadow_vt.?.cursor_row = 7;
    target.shadow_vt.?.cursor_col = 5;
    target.adoptStreamedSessionHistory();

    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 1);
    defer projection.deinit();
    _ = try projection.appendRawClassified("retained marker\n", .unknown_raw);
    try projection.finalize();
    try projection.installRetained(&target, 0);

    try std.testing.expectEqual(@as(usize, 0), target.pendingResumeFlow().len);
    try std.testing.expectEqual(@as(usize, 1), target.entries.items.len);
    try std.testing.expect(std.mem.find(u8, target.transcript.items, "retained marker") != null);
    try std.testing.expectEqual(@as(u16, 7), target.cursor_row);
    try std.testing.expectEqual(@as(u16, 5), target.cursor_col);
    var installed_source = try target.prepareTranscriptSource(alloc, null);
    defer installed_source.deinit(alloc);
    const stable = target.stableTranscriptProjectionForFlow(installed_source.bytes) orelse
        return error.MissingStreamedTranscriptAnchor;
    try std.testing.expectEqual(@as(u16, 7), stable.cursor_row);
    try std.testing.expectEqual(@as(u16, 5), stable.cursor_col);
}

test "binary resume projection installs retained continuation without replay" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 24,
        .cols = 72,
        .content_bottom = 10,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    defer source.deinit(alloc);

    var built = try ResumeProjection.initEmpty(alloc, &source, 42, 1);
    defer built.deinit();
    for (0..30) |index| {
        var line_buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buf,
            "binary retained marker {d}\n",
            .{index},
        );
        _ = try built.appendRawClassified(line, .unknown_raw);
    }
    try built.finalize();
    const bytes = try resume_snapshot.encode(alloc, built.snapshotView());
    defer alloc.free(bytes);
    var decoded = try resume_snapshot.decode(alloc, bytes);
    defer decoded.deinit(alloc);

    var restored = try ResumeProjection.initEmpty(alloc, &source, 43, 1);
    defer restored.deinit();
    try restored.adoptSnapshot(&decoded);

    var target: TranscriptRuntime = .{};
    target.layout = source.layout;
    defer target.deinit(alloc);
    try target.enableShadowVt(alloc);
    target.adoptStreamedSessionHistory();
    target.resumePresentationRecordAt(64, restored.recordCursor());
    try restored.installRetained(&target, 6);

    try std.testing.expectEqual(@as(usize, 30), target.entries.items.len);
    try std.testing.expect(std.mem.find(
        u8,
        target.transcript.items,
        "binary retained marker 29",
    ) != null);
    try std.testing.expectEqual(@as(usize, 0), target.pendingResumeFlow().len);
    var installed_source = try target.prepareTranscriptSource(alloc, null);
    defer installed_source.deinit(alloc);
    const stable = target.stableTranscriptProjectionForFlow(
        installed_source.bytes,
    ) orelse return error.MissingStreamedTranscriptAnchor;
    try std.testing.expectEqual(
        stable.visual_offset,
        stable.history_visual_offset,
    );
    try std.testing.expect(
        stable.total_visual_rows - stable.visual_offset <= 4,
    );
}

test "resume projection transfers a complete standalone runtime" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 24,
        .cols = 72,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    defer source.deinit(alloc);

    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 1);
    defer projection.deinit();
    try projection.appendAssistantText("standalone child\n");
    try projection.finalize();

    var runtime = projection.intoRuntime();
    defer runtime.deinit(alloc);
    try std.testing.expectEqual(source.layout.cols, runtime.layout.cols);
    try std.testing.expect(std.mem.find(
        u8,
        runtime.pendingResumeFlow(),
        "standalone child",
    ) != null);
}

test "resume projection transfers standalone full diff sidecars" {
    const alloc = std.testing.allocator;
    const c_alloc = std.heap.c_allocator;
    var source: TranscriptRuntime = .{};
    source.layout.cols = 72;
    defer source.deinit(alloc);

    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 7);
    defer projection.deinit();
    const payload = try struct {
        fn make(a: Allocator) !diff.DiffEntryPayload {
            const preview = try a.dupe(u8, "preview\n");
            errdefer a.free(preview);
            const full_content = try a.dupe(u8, "complete diff\n");
            errdefer a.free(full_content);
            const call_id = try a.dupe(u8, "diff-call");
            return .{
                .preview = preview,
                .full = .{
                    .content = full_content,
                    .lifecycle_id = .{
                        .turn_id = 3,
                        .call_id = call_id,
                    },
                },
            };
        }
    }.make(c_alloc);
    var owns_payload = true;
    errdefer if (owns_payload) diff.freeDiffEntryPayload(c_alloc, payload);
    try projection.appendDiff(payload);
    owns_payload = false;
    try projection.finalize();

    var pending = projection.takePendingDiffs();
    defer {
        for (pending.items) |*entry| entry.deinit(c_alloc);
        pending.deinit(c_alloc);
    }
    var runtime = projection.intoRuntime();
    defer runtime.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), pending.items.len);
    try std.testing.expectEqual(@as(u32, 7), pending.items[0].id);
    try std.testing.expectEqualStrings(
        "complete diff\n",
        pending.items[0].full.?.content,
    );
    try std.testing.expect(std.mem.find(
        u8,
        runtime.pendingResumeFlow(),
        diff.diff_block_start_prefix,
    ) != null);
}

test "resume projection uses its explicit timestamp for command output" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout.cols = 80;
    defer source.deinit(alloc);

    var projection = try ResumeProjection.init(alloc, &source, 42, 1);
    defer projection.deinit();
    try projection.appendCommandOutput(null, .stdout, "one\ntwo\n");
    try projection.finishCommandOutput(null);

    var command_entries: usize = 0;
    for (projection.runtime.entries.items) |entry| {
        if (entry != .raw_bytes or entry.raw_bytes.class != .command_output) continue;
        try std.testing.expectEqual(@as(i64, 42), entry.raw_bytes.created_at_ms);
        command_entries += 1;
    }
    try std.testing.expect(command_entries > 0);
}

test "live resume projection preserves an incomplete command block" {
    const alloc = std.testing.allocator;
    var source: TranscriptRuntime = .{};
    source.layout.cols = 80;
    defer source.deinit(alloc);

    const lifecycle_id = types.ToolLifecycleId{
        .turn_id = 7,
        .call_id = "streaming-command",
    };
    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 1);
    defer projection.deinit();
    try projection.appendCommandOutput(
        lifecycle_id,
        .stdout,
        "partial output\n",
    );
    try projection.finalizeLivePresentation();
    try std.testing.expect(
        projection.runtime.command_output_display.open_command_block != null,
    );
    try std.testing.expect(
        std.mem.find(u8, projection.publication_source.?.bytes, "partial output") == null,
    );
    try std.testing.expectEqualStrings(
        "partial output",
        projection.runtime.command_output_blocks.items[0].lines.items[0].text,
    );

    var runtime = projection.intoRuntime();
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    _ = try command_output_runtime.writeCommandOutputChunkDetached(
        &runtime,
        alloc,
        &metrics,
        runtime.retainedTranscriptStyles(),
        lifecycle_id,
        .stdout,
        "completed output\n",
        true,
        43,
    );
    try command_output_runtime.flushCommandOutputSummaryDetached(
        &runtime,
        alloc,
        runtime.retainedTranscriptStyles(),
        lifecycle_id,
        44,
    );
    try std.testing.expect(
        runtime.command_output_display.open_command_block == null,
    );
}

fn checkResumeProjectionAllocationFailures(alloc: Allocator) !void {
    var source: TranscriptRuntime = .{};
    source.layout = .{
        .rows = 24,
        .cols = 64,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    defer source.deinit(std.testing.allocator);

    var projection = try ResumeProjection.init(alloc, &source, 42, 1);
    defer projection.deinit();
    _ = try projection.appendNotice(.{
        .topic = "session",
        .tone = .neutral,
        .body = "resumed: allocation fixture",
    });
    _ = try projection.appendUserTurn(.{ .text = @constCast("hello") });
    try projection.appendAssistantText("answer\n");
    try projection.finalize();
}

test "resume projection releases every failed detached build" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkResumeProjectionAllocationFailures,
        .{},
    );
}

fn checkLiveResumeProjectionAllocationFailures(alloc: Allocator) !void {
    var source: TranscriptRuntime = .{};
    source.layout.cols = 80;
    defer source.deinit(std.testing.allocator);

    var projection = try ResumeProjection.initEmpty(alloc, &source, 42, 1);
    defer projection.deinit();
    try projection.appendCommandOutput(
        .{ .turn_id = 9, .call_id = "allocation-command" },
        .stdout,
        "partial output\n",
    );
    try projection.finalizeLivePresentation();
}

test "live resume projection releases every failed detached build" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLiveResumeProjectionAllocationFailures,
        .{},
    );
}
