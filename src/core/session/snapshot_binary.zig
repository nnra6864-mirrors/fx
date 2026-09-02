const std = @import("std");

const Allocator = std.mem.Allocator;
const max_container_items: usize = 1024 * 1024;
const max_decoded_allocation_bytes: usize = 256 * 1024 * 1024;

fn isArrayList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasField(T, "items") and
        @hasField(T, "capacity") and
        std.mem.find(u8, @typeName(T), "array_list") != null;
}

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn encodeValue(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    switch (@typeInfo(T)) {
        .bool => try writer.writeByte(@intFromBool(value)),
        .int => try writeInt(writer, T, value),
        .float => {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            try writeInt(writer, U, @bitCast(value));
        },
        .@"enum" => try writeInt(writer, u32, @intCast(@intFromEnum(value))),
        .optional => |info| if (value) |present| {
            try writer.writeByte(1);
            try encodeValue(writer, info.child, present);
        } else try writer.writeByte(0),
        .array => |info| for (value) |item| try encodeValue(writer, info.child, item),
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child != u8 and value.len > max_container_items) {
                    return error.SnapshotContainerTooLarge;
                }
                try writeInt(writer, u64, @intCast(value.len));
                if (info.child == u8) {
                    try writer.writeAll(value);
                } else {
                    for (value) |item| try encodeValue(writer, info.child, item);
                }
            },
            else => @compileError("unsupported snapshot pointer " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            if (comptime isArrayList(T)) {
                try encodeValue(writer, @TypeOf(value.items), value.items);
                return;
            }
            inline for (info.fields) |field| {
                if (!field.is_comptime) try encodeValue(
                    writer,
                    field.type,
                    @field(value, field.name),
                );
            }
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse
                @compileError("untagged snapshot union " ++ @typeName(T));
            const tag = std.meta.activeTag(value);
            try encodeValue(writer, Tag, tag);
            inline for (info.fields) |field| {
                if (tag == @field(Tag, field.name)) {
                    try encodeValue(writer, field.type, @field(value, field.name));
                    return;
                }
            }
            unreachable;
        },
        .void => {},
        else => @compileError("unsupported snapshot type " ++ @typeName(T)),
    }
}

pub fn encode(alloc: Allocator, value: anytype) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    try encodeValue(&output.writer, @TypeOf(value), value);
    return output.toOwnedSlice();
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,
    allocated_bytes: usize = 0,

    fn take(self: *Cursor, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.pos) return error.InvalidSnapshot;
        defer self.pos += len;
        return self.bytes[self.pos..][0..len];
    }

    fn readInt(self: *Cursor, comptime T: type) !T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    fn reserveAllocation(
        self: *Cursor,
        comptime T: type,
        len: usize,
    ) !void {
        const bytes = std.math.mul(usize, @sizeOf(T), len) catch
            return error.InvalidSnapshot;
        self.allocated_bytes = std.math.add(
            usize,
            self.allocated_bytes,
            bytes,
        ) catch return error.InvalidSnapshot;
        if (self.allocated_bytes > max_decoded_allocation_bytes) {
            return error.InvalidSnapshot;
        }
    }
};

fn decodeValue(alloc: Allocator, cursor: *Cursor, comptime T: type) !T {
    return switch (@typeInfo(T)) {
        .bool => switch ((try cursor.take(1))[0]) {
            0 => false,
            1 => true,
            else => error.InvalidSnapshot,
        },
        .int => try cursor.readInt(T),
        .float => blk: {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            break :blk @bitCast(try cursor.readInt(U));
        },
        .@"enum" => std.enums.fromInt(T, try cursor.readInt(u32)) orelse
            error.InvalidSnapshot,
        .optional => |info| switch ((try cursor.take(1))[0]) {
            0 => null,
            1 => try decodeValue(alloc, cursor, info.child),
            else => error.InvalidSnapshot,
        },
        .array => |info| blk: {
            var result: T = undefined;
            for (&result) |*item| item.* = try decodeValue(alloc, cursor, info.child);
            break :blk result;
        },
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                const len = std.math.cast(usize, try cursor.readInt(u64)) orelse
                    return error.InvalidSnapshot;
                if (info.child != u8 and len > max_container_items) {
                    return error.InvalidSnapshot;
                }
                try cursor.reserveAllocation(info.child, len);
                const result = try alloc.alloc(info.child, len);
                errdefer alloc.free(result);
                if (info.child == u8) {
                    @memcpy(result, try cursor.take(len));
                    break :blk result;
                }
                var initialized: usize = 0;
                errdefer {
                    for (result[0..initialized]) |*item| deinit(alloc, info.child, item);
                }
                for (result) |*item| {
                    item.* = try decodeValue(alloc, cursor, info.child);
                    initialized += 1;
                }
                break :blk result;
            },
            else => @compileError("unsupported snapshot pointer " ++ @typeName(T)),
        },
        .@"struct" => |info| blk: {
            if (comptime isArrayList(T)) {
                var result: T = .empty;
                result.items = try decodeValue(alloc, cursor, @TypeOf(result.items));
                result.capacity = result.items.len;
                break :blk result;
            }
            var result: T = undefined;
            var initialized: usize = 0;
            errdefer inline for (info.fields, 0..) |field, index| {
                if (!field.is_comptime and index < initialized) {
                    deinit(alloc, field.type, &@field(result, field.name));
                }
            };
            inline for (info.fields) |field| {
                if (!field.is_comptime) {
                    @field(result, field.name) = try decodeValue(alloc, cursor, field.type);
                    initialized += 1;
                }
            }
            break :blk result;
        },
        .@"union" => |info| blk: {
            const Tag = info.tag_type orelse
                @compileError("untagged snapshot union " ++ @typeName(T));
            const tag = try decodeValue(alloc, cursor, Tag);
            inline for (info.fields) |field| {
                if (tag == @field(Tag, field.name)) {
                    break :blk @unionInit(
                        T,
                        field.name,
                        try decodeValue(alloc, cursor, field.type),
                    );
                }
            }
            return error.InvalidSnapshot;
        },
        .void => {},
        else => @compileError("unsupported snapshot type " ++ @typeName(T)),
    };
}

pub fn decode(alloc: Allocator, comptime T: type, bytes: []const u8) !T {
    var cursor = Cursor{ .bytes = bytes };
    var value = try decodeValue(alloc, &cursor, T);
    errdefer deinit(alloc, T, &value);
    if (cursor.pos != bytes.len) return error.InvalidSnapshot;
    return value;
}

pub fn deinit(alloc: Allocator, comptime T: type, value: *T) void {
    switch (@typeInfo(T)) {
        .optional => |info| if (value.*) |*present| deinit(alloc, info.child, present),
        .array => |info| for (value) |*item| deinit(alloc, info.child, item),
        .pointer => |info| if (info.size == .slice) {
            const mutable = @constCast(value.*);
            if (info.child != u8) {
                for (mutable) |*item| deinit(alloc, info.child, item);
            }
            alloc.free(mutable);
        },
        .@"struct" => |info| {
            if (comptime isArrayList(T)) {
                const Item = @typeInfo(@TypeOf(value.items)).pointer.child;
                for (value.items) |*item| deinit(alloc, Item, item);
                value.deinit(alloc);
                return;
            }
            inline for (info.fields) |field| {
                if (!field.is_comptime) deinit(
                    alloc,
                    field.type,
                    &@field(value.*, field.name),
                );
            }
        },
        .@"union" => |info| {
            const Tag = info.tag_type.?;
            const tag = std.meta.activeTag(value.*);
            inline for (info.fields) |field| {
                if (tag == @field(Tag, field.name)) {
                    deinit(alloc, field.type, &@field(value.*, field.name));
                    return;
                }
            }
        },
        else => {},
    }
    value.* = undefined;
}

test "snapshot binary round trips nested owned values" {
    const Value = struct {
        name: []const u8,
        values: []const u32,
        selected: ?u32,
    };
    const source = Value{
        .name = "session",
        .values = &.{ 3, 5, 8 },
        .selected = 5,
    };
    const bytes = try encode(std.testing.allocator, source);
    defer std.testing.allocator.free(bytes);
    var decoded = try decode(std.testing.allocator, Value, bytes);
    defer deinit(std.testing.allocator, Value, &decoded);
    try std.testing.expectEqualStrings(source.name, decoded.name);
    try std.testing.expectEqualSlices(u32, source.values, decoded.values);
    try std.testing.expectEqual(source.selected, decoded.selected);
}

test "snapshot binary rejects truncation" {
    const bytes = try encode(std.testing.allocator, @as([]const u8, "payload"));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(
        error.InvalidSnapshot,
        decode(std.testing.allocator, []const u8, bytes[0 .. bytes.len - 1]),
    );
}

test "snapshot binary rejects oversized container counts before allocation" {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, max_container_items + 1, .little);
    try std.testing.expectError(
        error.InvalidSnapshot,
        decode(std.testing.allocator, []u64, &bytes),
    );
}
