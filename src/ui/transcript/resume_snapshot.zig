const std = @import("std");
const diff = @import("../../core/output/diff.zig");
const snapshot_binary = @import("../../core/session/snapshot_binary.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const command_output_runtime = @import("command_output_runtime.zig");
const presentation_record = @import("presentation_record.zig");

const Allocator = std.mem.Allocator;
const max_retention_cap: usize = 64 * 1024 * 1024;

pub const View = struct {
    entries: []const transcript_blocks.TranscriptEntry,
    tool_details: []const transcript_blocks.ToolDetailRecord,
    folded_command_blocks: []const command_output_runtime.FoldedCommandBlock,
    command_output_blocks: []const command_output_runtime.CommandOutputBlock,
    command_output_display: transcript_blocks.CommandOutputDisplayState,
    transcript: []const u8,
    diffs: []const diff.DiffEntry,
    record_cursor: presentation_record.Cursor,
    next_entry_id: u32,
    next_diff_id: u32,
    last_rendered_cols: u16,
    transcript_cache_origin_untrimmed: bool,
    replaceable_last_line: bool,
    replaceable_row: u16,
    replaceable_start: usize,
    retention_cap: usize,
    retention_changed: bool,
};

pub const Owned = struct {
    entries: []transcript_blocks.TranscriptEntry,
    tool_details: []transcript_blocks.ToolDetailRecord,
    folded_command_blocks: []command_output_runtime.FoldedCommandBlock,
    command_output_blocks: []command_output_runtime.CommandOutputBlock,
    command_output_display: transcript_blocks.CommandOutputDisplayState,
    transcript: []u8,
    diffs: []diff.DiffEntry,
    record_cursor: presentation_record.Cursor,
    next_entry_id: u32,
    next_diff_id: u32,
    last_rendered_cols: u16,
    transcript_cache_origin_untrimmed: bool,
    replaceable_last_line: bool,
    replaceable_row: u16,
    replaceable_start: usize,
    retention_cap: usize,
    retention_changed: bool,

    pub fn deinit(self: *Owned, alloc: Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        if (self.entries.len > 0) alloc.free(self.entries);
        for (self.tool_details) |*detail| detail.deinit(alloc);
        if (self.tool_details.len > 0) alloc.free(self.tool_details);
        for (self.folded_command_blocks) |*block| block.deinit(alloc);
        if (self.folded_command_blocks.len > 0) {
            alloc.free(self.folded_command_blocks);
        }
        for (self.command_output_blocks) |*block| block.deinit(alloc);
        if (self.command_output_blocks.len > 0) {
            alloc.free(self.command_output_blocks);
        }
        if (self.transcript.len > 0) alloc.free(self.transcript);
        for (self.diffs) |*entry| entry.deinit(alloc);
        if (self.diffs.len > 0) alloc.free(self.diffs);
        self.* = undefined;
    }
};

pub fn encode(alloc: Allocator, snapshot: View) ![]u8 {
    return snapshot_binary.encode(alloc, snapshot);
}

pub fn decode(alloc: Allocator, bytes: []const u8) !Owned {
    var snapshot = snapshot_binary.decode(alloc, Owned, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResumeSnapshot,
    };
    errdefer snapshot.deinit(alloc);
    try validate(snapshot);
    return snapshot;
}

fn validate(snapshot: Owned) !void {
    if (snapshot.next_entry_id == 0 or snapshot.next_diff_id == 0 or
        snapshot.last_rendered_cols == 0 or
        snapshot.retention_cap == 0 or
        snapshot.retention_cap > max_retention_cap or
        snapshot.replaceable_start > snapshot.transcript.len or
        snapshot.replaceable_row == 0)
    {
        return error.InvalidResumeSnapshot;
    }
    var prior_entry_id: u32 = 0;
    for (snapshot.entries) |entry| {
        const entry_id = entry.id();
        if (entry_id == 0 or entry_id <= prior_entry_id or
            entry_id >= snapshot.next_entry_id)
        {
            return error.InvalidResumeSnapshot;
        }
        prior_entry_id = entry_id;
    }
    var prior_detail_id: u32 = 0;
    for (snapshot.tool_details) |detail| {
        if (detail.entry_id == 0 or detail.entry_id <= prior_detail_id or
            detail.entry_id >= snapshot.next_entry_id)
        {
            return error.InvalidResumeSnapshot;
        }
        if (detail.command_output_entry_id) |entry_id| {
            if (entry_id == 0 or entry_id >= snapshot.next_entry_id) {
                return error.InvalidResumeSnapshot;
            }
        }
        prior_detail_id = detail.entry_id;
    }
    for (snapshot.folded_command_blocks) |block| {
        if (block.summary_transcript_index > snapshot.transcript.len) {
            return error.InvalidResumeSnapshot;
        }
        if (block.summary_entry_id) |entry_id| {
            if (entry_id == 0 or entry_id >= snapshot.next_entry_id) {
                return error.InvalidResumeSnapshot;
            }
        }
    }
    for (snapshot.command_output_blocks) |block| {
        if (block.entry_id) |entry_id| {
            if (entry_id == 0 or entry_id >= snapshot.next_entry_id) {
                return error.InvalidResumeSnapshot;
            }
        }
        for (block.live_entry_ids.items) |entry_id| {
            if (entry_id == 0 or entry_id >= snapshot.next_entry_id) {
                return error.InvalidResumeSnapshot;
            }
        }
        for (block.source_entry_ids.items) |entry_id| {
            if (entry_id == 0 or entry_id >= snapshot.next_entry_id) {
                return error.InvalidResumeSnapshot;
            }
        }
    }
    if (snapshot.command_output_display.open_block) |index| {
        if (index >= snapshot.folded_command_blocks.len) {
            return error.InvalidResumeSnapshot;
        }
    }
    if (snapshot.command_output_display.open_command_block) |index| {
        if (index >= snapshot.command_output_blocks.len) {
            return error.InvalidResumeSnapshot;
        }
    }
    for (snapshot.diffs) |entry| {
        if (entry.id == 0 or entry.id >= snapshot.next_diff_id) {
            return error.InvalidResumeSnapshot;
        }
    }
    switch (snapshot.record_cursor) {
        .start => {},
        .after => |cursor| if (cursor.entry_id == 0 or
            cursor.entry_id >= snapshot.next_entry_id)
        {
            return error.InvalidResumeSnapshot;
        },
        .at => |cursor| if (cursor.entry_id == 0 or
            cursor.entry_id >= snapshot.next_entry_id or
            cursor.cols != snapshot.last_rendered_cols)
        {
            return error.InvalidResumeSnapshot;
        },
    }
}

test "retained snapshot rejects trailing bytes" {
    const source = View{
        .entries = &.{},
        .tool_details = &.{},
        .folded_command_blocks = &.{},
        .command_output_blocks = &.{},
        .command_output_display = .{},
        .transcript = "tail",
        .diffs = &.{},
        .record_cursor = .start,
        .next_entry_id = 1,
        .next_diff_id = 1,
        .last_rendered_cols = 80,
        .transcript_cache_origin_untrimmed = true,
        .replaceable_last_line = false,
        .replaceable_row = 1,
        .replaceable_start = 0,
        .retention_cap = 1024,
        .retention_changed = false,
    };
    const bytes = try encode(std.testing.allocator, source);
    defer std.testing.allocator.free(bytes);
    const invalid = try std.mem.concat(std.testing.allocator, u8, &.{ bytes, "x" });
    defer std.testing.allocator.free(invalid);
    try std.testing.expectError(
        error.InvalidResumeSnapshot,
        decode(std.testing.allocator, invalid),
    );
}

test "retained snapshot round trips an owned value" {
    const source = View{
        .entries = &.{},
        .tool_details = &.{},
        .folded_command_blocks = &.{},
        .command_output_blocks = &.{},
        .command_output_display = .{},
        .transcript = "tail",
        .diffs = &.{},
        .record_cursor = .start,
        .next_entry_id = 1,
        .next_diff_id = 1,
        .last_rendered_cols = 80,
        .transcript_cache_origin_untrimmed = true,
        .replaceable_last_line = false,
        .replaceable_row = 1,
        .replaceable_start = 0,
        .retention_cap = 1024,
        .retention_changed = false,
    };
    const bytes = try encode(std.testing.allocator, source);
    defer std.testing.allocator.free(bytes);
    var restored = try decode(std.testing.allocator, bytes);
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("tail", restored.transcript);
    try std.testing.expectEqual(@as(u16, 80), restored.last_rendered_cols);
}
