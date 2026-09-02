const std = @import("std");
const session_codec = @import("session_codec.zig");
const session_replay = @import("session_replay.zig");
const session_usage = @import("session_usage.zig");
const snapshot_binary = @import("snapshot_binary.zig");

const Allocator = std.mem.Allocator;
const magic = "FXRS";
const schema_version: u8 = 2;
pub const max_file_bytes: usize = 128 * 1024 * 1024;

pub const Decoded = struct {
    session_id: []u8,
    position: session_replay.CommitPosition,
    state: session_codec.DurableSessionState,
    presentation: []u8,

    pub fn deinit(self: *Decoded, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.state.deinit(alloc);
        alloc.free(self.presentation);
        self.* = undefined;
    }
};

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn hashInt(
    hash: *std.crypto.hash.sha2.Sha256,
    comptime T: type,
    value: T,
) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hash.update(&bytes);
}

fn snapshotDigest(
    session_id: []const u8,
    position: session_replay.CommitPosition,
    state_bytes: []const u8,
    presentation: []const u8,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(magic);
    hash.update(&.{schema_version});
    hashInt(&hash, u16, @intCast(session_id.len));
    hash.update(&position.log_generation);
    hashInt(&hash, u64, position.through_seq);
    hash.update(&position.through_event_id);
    hashInt(&hash, u64, position.through_event_log_bytes);
    hashInt(&hash, u64, @intCast(state_bytes.len));
    hashInt(&hash, u64, @intCast(presentation.len));
    hash.update(session_id);
    hash.update(state_bytes);
    hash.update(presentation);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.pos) return error.InvalidResumeSnapshot;
        defer self.pos += len;
        return self.bytes[self.pos..][0..len];
    }

    fn readInt(self: *Cursor, comptime T: type) !T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }
};

pub fn encode(
    alloc: Allocator,
    session_id: []const u8,
    position: session_replay.CommitPosition,
    state: session_codec.DurableSessionState,
    presentation: []const u8,
) ![]u8 {
    if (session_id.len == 0 or session_id.len > std.math.maxInt(u16)) {
        return error.InvalidResumeSnapshot;
    }
    var canonical_state = try state.dupe(alloc);
    defer canonical_state.deinit(alloc);
    if (canonical_state.usage) |*usage| {
        session_usage.stripSidecarOnlyFields(alloc, usage);
    }
    const state_bytes = try snapshot_binary.encode(alloc, canonical_state);
    defer alloc.free(state_bytes);
    const payload_len = std.math.add(usize, state_bytes.len, presentation.len) catch
        return error.ResumeSnapshotTooLarge;
    if (payload_len > max_file_bytes) return error.ResumeSnapshotTooLarge;
    const digest = snapshotDigest(
        session_id,
        position,
        state_bytes,
        presentation,
    );

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(magic);
    try out.writer.writeByte(schema_version);
    try writeInt(&out.writer, u16, @intCast(session_id.len));
    try out.writer.writeAll(&position.log_generation);
    try writeInt(&out.writer, u64, position.through_seq);
    try out.writer.writeAll(&position.through_event_id);
    try writeInt(&out.writer, u64, position.through_event_log_bytes);
    try writeInt(&out.writer, u64, @intCast(state_bytes.len));
    try writeInt(&out.writer, u64, @intCast(presentation.len));
    try out.writer.writeAll(&digest);
    try out.writer.writeAll(session_id);
    try out.writer.writeAll(state_bytes);
    try out.writer.writeAll(presentation);
    if (out.written().len > max_file_bytes) return error.ResumeSnapshotTooLarge;
    return out.toOwnedSlice();
}

pub fn decode(alloc: Allocator, bytes: []const u8) !Decoded {
    if (bytes.len == 0 or bytes.len > max_file_bytes) return error.InvalidResumeSnapshot;
    var cursor = Cursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(magic.len), magic)) {
        return error.InvalidResumeSnapshot;
    }
    const version = (try cursor.take(1))[0];
    if (version != schema_version) return error.UnsupportedResumeSnapshotSchema;
    const session_id_len = try cursor.readInt(u16);
    const generation = try cursor.take(16);
    const through_seq = try cursor.readInt(u64);
    const event_id = try cursor.take(16);
    const event_log_bytes = try cursor.readInt(u64);
    const state_len = std.math.cast(usize, try cursor.readInt(u64)) orelse
        return error.InvalidResumeSnapshot;
    const presentation_len = std.math.cast(usize, try cursor.readInt(u64)) orelse
        return error.InvalidResumeSnapshot;
    const expected_digest = try cursor.take(32);
    const session_id = try cursor.take(session_id_len);
    const state_bytes = try cursor.take(state_len);
    const presentation_bytes = try cursor.take(presentation_len);
    if (cursor.pos != bytes.len or through_seq == 0 or event_log_bytes == 0) {
        return error.InvalidResumeSnapshot;
    }
    const digest = snapshotDigest(
        session_id,
        .{
            .log_generation = generation[0..16].*,
            .through_seq = through_seq,
            .through_event_id = event_id[0..16].*,
            .through_event_log_bytes = event_log_bytes,
        },
        state_bytes,
        presentation_bytes,
    );
    if (!std.mem.eql(u8, expected_digest, &digest)) return error.InvalidResumeSnapshot;

    const owned_id = try alloc.dupe(u8, session_id);
    errdefer alloc.free(owned_id);
    var state = snapshot_binary.decode(
        alloc,
        session_codec.DurableSessionState,
        state_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResumeSnapshot,
    };
    errdefer state.deinit(alloc);
    session_codec.validateState(state) catch return error.InvalidResumeSnapshot;
    if (!std.mem.eql(u8, state.id, owned_id)) return error.InvalidResumeSnapshot;
    const presentation = try alloc.dupe(u8, presentation_bytes);
    return .{
        .session_id = owned_id,
        .position = .{
            .log_generation = generation[0..16].*,
            .through_seq = through_seq,
            .through_event_id = event_id[0..16].*,
            .through_event_log_bytes = event_log_bytes,
        },
        .state = state,
        .presentation = presentation,
    };
}
