const std = @import("std");

pub const CancelFlag = ?*const std.atomic.Value(bool);
pub const work_bytes = 8192;

pub fn check(cancel_flag: CancelFlag) error{Cancelled}!void {
    if (cancel_flag) |flag| {
        if (flag.load(.acquire)) return error.Cancelled;
    }
}

pub fn lock(io: std.Io, mutex: *std.Io.Mutex, cancel_flag: CancelFlag) error{Cancelled}!void {
    if (cancel_flag == null) {
        mutex.lockUncancelable(io);
        return;
    }
    while (true) {
        try check(cancel_flag);
        if (mutex.tryLock()) return;
        io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .awake) catch return error.Cancelled;
    }
}

/// Returns caller-owned bytes, checking cancellation between bounded copies.
pub fn duplicateBytes(alloc: std.mem.Allocator, bytes: []const u8, cancel_flag: CancelFlag) ![]u8 {
    try check(cancel_flag);
    const copy = try alloc.alloc(u8, bytes.len);
    errdefer alloc.free(copy);
    try copyBytes(copy, bytes, cancel_flag);
    return copy;
}

pub fn copyBytes(destination: []u8, bytes: []const u8, cancel_flag: CancelFlag) error{Cancelled}!void {
    std.debug.assert(destination.len == bytes.len);
    var offset: usize = 0;
    while (offset < bytes.len) {
        try check(cancel_flag);
        const end = offset + @min(work_bytes, bytes.len - offset);
        @memcpy(destination[offset..end], bytes[offset..end]);
        offset = end;
    }
}

/// Decodes canonical padded base64 into caller-owned bytes.
pub fn decodeBase64(alloc: std.mem.Allocator, encoded: []const u8, cancel_flag: CancelFlag) ![]u8 {
    try check(cancel_flag);
    const length = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const decoded = try alloc.alloc(u8, length);
    errdefer alloc.free(decoded);
    var rendered: [work_bytes]u8 = undefined;
    var source_offset: usize = 0;
    var destination_offset: usize = 0;
    while (source_offset < encoded.len) {
        try check(cancel_flag);
        const end = source_offset + @min(work_bytes, encoded.len - source_offset);
        const chunk = encoded[source_offset..end];
        const count = std.base64.standard.Decoder.calcSizeForSlice(chunk) catch return error.InvalidBase64;
        if (count > decoded.len - destination_offset) return error.InvalidBase64;
        const output = decoded[destination_offset..][0..count];
        std.base64.standard.Decoder.decode(output, chunk) catch return error.InvalidBase64;
        const canonical = std.base64.standard.Encoder.encode(&rendered, output);
        if (!std.mem.eql(u8, chunk, canonical)) return error.InvalidBase64;
        source_offset = end;
        destination_offset += count;
    }
    if (destination_offset != decoded.len) return error.InvalidBase64;
    return decoded;
}

pub fn validUtf8(bytes: []const u8, cancel_flag: CancelFlag) !bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try check(cancel_flag);
        var end = offset + @min(work_bytes, bytes.len - offset);
        if (end < bytes.len) {
            while (end > offset and bytes[end] & 0xc0 == 0x80) end -= 1;
            if (end == offset) return false;
        }
        if (!std.unicode.utf8ValidateSlice(bytes[offset..end])) return false;
        offset = end;
    }
    return true;
}

pub fn updateSha256(hash: *std.crypto.hash.sha2.Sha256, bytes: []const u8, cancel_flag: CancelFlag) error{Cancelled}!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try check(cancel_flag);
        const end = offset + @min(work_bytes, bytes.len - offset);
        hash.update(bytes[offset..end]);
        offset = end;
    }
}

pub fn sha256(bytes: []const u8, cancel_flag: CancelFlag) error{Cancelled}![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    try updateSha256(&hash, bytes, cancel_flag);
    return hash.finalResult();
}

pub fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8, cancel_flag: CancelFlag) !void {
    try check(cancel_flag);
    try writer.writeByte('"');
    var offset: usize = 0;
    while (offset < bytes.len) {
        try check(cancel_flag);
        const end = offset + @min(work_bytes, bytes.len - offset);
        try std.json.Stringify.encodeJsonStringChars(bytes[offset..end], .{}, writer);
        offset = end;
    }
    try writer.writeByte('"');
}

pub fn writeBase64(writer: *std.Io.Writer, bytes: []const u8, cancel_flag: CancelFlag) !void {
    var output: [work_bytes]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes.len) {
        try check(cancel_flag);
        const end = offset + @min(work_bytes / 4 * 3, bytes.len - offset);
        try writer.writeAll(std.base64.standard.Encoder.encode(&output, bytes[offset..end]));
        offset = end;
    }
}

pub fn writeFileBytes(io: std.Io, file: std.Io.File, start: u64, bytes: []const u8, cancel_flag: CancelFlag) !void {
    _ = std.math.add(u64, start, bytes.len) catch return error.WriteFailed;
    var offset: usize = 0;
    while (offset < bytes.len) {
        try check(cancel_flag);
        const end = offset + @min(work_bytes, bytes.len - offset);
        try file.writePositionalAll(io, bytes[offset..end], start + offset);
        offset = end;
    }
    try check(cancel_flag);
}

test "bounded byte transforms preserve data at chunk boundaries" {
    const alloc = std.testing.allocator;
    const bytes = try alloc.alloc(u8, 2 * work_bytes + 4);
    defer alloc.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index);
    for ([_]usize{ 0, 1, 2, 3, 6143, 6144, 6145, 12288 }) |len| {
        const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(len));
        defer alloc.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, bytes[0..len]);
        var written: std.Io.Writer.Allocating = .init(alloc);
        defer written.deinit();
        try writeBase64(&written.writer, bytes[0..len], null);
        try std.testing.expectEqualStrings(encoded, written.written());
        const decoded = try decodeBase64(alloc, encoded, null);
        defer alloc.free(decoded);
        try std.testing.expectEqualSlices(u8, bytes[0..len], decoded);
    }
    var escaped: std.Io.Writer.Allocating = .init(alloc);
    defer escaped.deinit();
    var ordinary: std.Io.Writer.Allocating = .init(alloc);
    defer ordinary.deinit();
    const text = "line\n\"snow 雪\\" ** 2048;
    try writeJsonString(&escaped.writer, text, null);
    try std.json.Stringify.value(text, .{}, &ordinary.writer);
    try std.testing.expectEqualStrings(ordinary.written(), escaped.written());
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &try sha256(bytes, null));
    for ([_]usize{ work_bytes - 3, work_bytes - 2, work_bytes - 1, work_bytes }) |start| {
        @memset(bytes, 'a');
        @memcpy(bytes[start..][0..4], "\xf0\x9f\x92\xa9");
        try std.testing.expect(try validUtf8(bytes, null));
        bytes[start + 1] = 0xff;
        try std.testing.expect(!try validUtf8(bytes, null));
    }
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, sha256(bytes, &cancelled));
    try std.testing.expectError(error.Cancelled, validUtf8(bytes, &cancelled));
}

/// Borrows the source, buffer, and cancellation flag for one read operation.
/// std.Io.Reader erases cancellation to ReadFailed; the owner checks the flag
/// before translating a reader failure into a session-format error.
pub const Reader = struct {
    source: *std.Io.Reader,
    cancel_flag: CancelFlag,
    interface: std.Io.Reader,

    pub fn init(source: *std.Io.Reader, buffer: []u8, cancel_flag: CancelFlag) Reader {
        return .{
            .source = source,
            .cancel_flag = cancel_flag,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Reader = @fieldParentPtr("interface", reader);
        check(self.cancel_flag) catch return error.ReadFailed;
        return self.source.stream(writer, limit.min(.limited(work_bytes)));
    }
};
