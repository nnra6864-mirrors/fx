const std = @import("std");
const io_mod = @import("io.zig");
const profile_paths = @import("profile_paths.zig");

const Allocator = std.mem.Allocator;

const State = struct {
    configured: bool = false,
    enabled: bool = false,
    stderr_enabled: bool = false,
    scope_filter: ?[]u8 = null,
    file_path: ?[]u8 = null,
};

const default_log_max_bytes: u64 = 2 * 1024 * 1024;
const max_trace_line_bytes: usize = 64 * 1024;

pub const Options = struct {
    file_path: ?[]const u8 = null,
    stderr_enabled: bool = false,
    scope_filter: ?[]const u8 = null,
};

pub const TraceContext = struct {
    turn_id: u64 = 0,
    step_id: u64 = 0,
    subagent_id: u64 = 0,
};

var state_mutex: std.Io.Mutex = .init;
var state: State = .{};
var next_turn_id = std.atomic.Value(u64).init(1);
var next_step_id = std.atomic.Value(u64).init(1);
var next_subagent_id = std.atomic.Value(u64).init(1);

pub fn configureFromEnv(alloc: Allocator, workspace_root: []const u8) void {
    const options = loadOptionsFromEnv(alloc, workspace_root) catch return;
    defer if (options.file_path) |path| alloc.free(path);
    if (options.file_path == null and !options.stderr_enabled) return;
    configure(options) catch {};
}

pub fn shutdown() void {
    if (!state.configured) return;

    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    if (state.scope_filter) |filter| std.heap.c_allocator.free(filter);
    if (state.file_path) |path| std.heap.c_allocator.free(path);
    state = .{};
}

pub fn activeLogPath() ?[]const u8 {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);
    return state.file_path;
}

pub fn nextTurnId() u64 {
    if (comptime @import("builtin").os.tag == .wasi) return 1;
    return next_turn_id.fetchAdd(1, .seq_cst);
}

pub fn nextStepId() u64 {
    if (comptime @import("builtin").os.tag == .wasi) return 1;
    return next_step_id.fetchAdd(1, .seq_cst);
}

pub fn nextSubagentId() u64 {
    if (comptime @import("builtin").os.tag == .wasi) return 1;
    return next_subagent_id.fetchAdd(1, .seq_cst);
}

pub fn logf(scope: []const u8, comptime fmt: []const u8, args: anytype) void {
    var line: TraceLine = undefined;
    if (!line.begin(scope)) return;
    line.print(fmt, args);
    line.end();
}

pub fn eventf(scope: []const u8, event: []const u8, ctx: TraceContext, comptime fmt: []const u8, args: anytype) void {
    var line: TraceLine = undefined;
    if (!line.beginEvent(scope, event, ctx, fmt.len != 0)) return;
    if (fmt.len != 0) line.print(fmt, args);
    line.end();
}

// Keep generic trace wrappers small by centralizing line assembly here.
// Failed lines accept remaining writes but emit nothing.
const TraceLine = struct {
    out: std.Io.Writer.Allocating,
    failed: bool,

    noinline fn begin(line: *TraceLine, scope: []const u8) bool {
        if (!isScopeEnabled(scope)) return false;
        line.* = .{ .out = .init(std.heap.c_allocator), .failed = false };
        line.out.writer.print("{d} [{s}] ", .{ io_mod.milliTimestamp(), scope }) catch {
            line.failed = true;
        };
        return true;
    }

    noinline fn beginEvent(line: *TraceLine, scope: []const u8, event: []const u8, ctx: TraceContext, has_message: bool) bool {
        if (!line.begin(scope)) return false;
        if (line.failed) return true;
        line.appendEventHead(event, ctx, has_message) catch {
            line.failed = true;
        };
        return true;
    }

    fn appendEventHead(line: *TraceLine, event: []const u8, ctx: TraceContext, has_message: bool) !void {
        try line.out.writer.print("event={s}", .{event});
        if (ctx.turn_id != 0) try line.out.writer.print(" turn_id={d}", .{ctx.turn_id});
        if (ctx.step_id != 0) try line.out.writer.print(" step_id={d}", .{ctx.step_id});
        if (ctx.subagent_id != 0) try line.out.writer.print(" subagent_id={d}", .{ctx.subagent_id});
        if (has_message) try line.out.writer.writeByte(' ');
    }

    fn print(line: *TraceLine, comptime fmt: []const u8, args: anytype) void {
        if (line.failed) return;
        if (comptime erasedSpecifiers(fmt, @TypeOf(args))) |specifiers| {
            var erased: [specifiers.len]ErasedArg = undefined;
            inline for (specifiers, 0..) |specifier, index| {
                erased[index] = eraseArg(specifier, args[index]);
            }
            line.printErased(comptime erasedTemplate(fmt), &erased);
            return;
        }
        line.out.writer.print(fmt, args) catch {
            line.failed = true;
        };
    }

    noinline fn printErased(line: *TraceLine, template: []const u8, args: []const ErasedArg) void {
        writeErased(&line.out.writer, template, args) catch {
            line.failed = true;
        };
    }

    noinline fn end(line: *TraceLine) void {
        defer line.out.deinit();
        if (line.failed) return;
        var safe: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer safe.deinit();
        writeTerminalSafeTraceLine(&safe.writer, line.out.written()) catch return;
        safe.writer.writeByte('\n') catch return;
        writeLine(safe.written());
    }
};

// Trace call sites outnumber every other formatting caller, and each comptime
// format string would otherwise instantiate its own copy of `Writer.print`.
// Formats whose placeholders all reduce to bytes or one integer are lowered to
// a small argument array and one shared runtime writer with identical output.
// The runtime template is the format's literal text with braces unescaped and
// each placeholder replaced by one marker byte, so it costs no more data than
// the literal pieces the standard path stores. Every other format keeps the
// standard path.
const erased_placeholder: u8 = 0x1a;

const ErasedArg = union(enum) {
    bytes: []const u8,
    signed: i64,
    unsigned: u64,
    signed_hex: i64,
    unsigned_hex: u64,
};

const ErasedSpecifier = enum { bytes, decimal, hex, tag, boolean, optional_decimal, optional_bytes, optional_tag, optional_hex };

fn erasedSpecifiers(comptime fmt: []const u8, comptime Args: type) ?[]const ErasedSpecifier {
    const info = @typeInfo(Args);
    if (info != .@"struct" or !info.@"struct".is_tuple) return null;
    const fields = info.@"struct".fields;
    @setEvalBranchQuota(@as(comptime_int, fmt.len) * 100 + 1000);
    comptime var specifiers: []const ErasedSpecifier = &.{};
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        const c = fmt[i];
        if (c == erased_placeholder) return null;
        if (c != '{' and c != '}') {
            i += 1;
            continue;
        }
        if (i + 1 < fmt.len and fmt[i + 1] == c) {
            i += 2;
            continue;
        }
        if (c == '}') return null;
        const close = comptime std.mem.findScalarPos(u8, fmt, i + 1, '}') orelse return null;
        const placeholder = fmt[i + 1 .. close];
        if (specifiers.len >= fields.len) return null;
        const specifier = erasedSpecifier(placeholder, fields[specifiers.len].type) orelse return null;
        specifiers = specifiers ++ .{specifier};
        i = close + 1;
    }
    if (specifiers.len != fields.len) return null;
    return specifiers;
}

fn erasedSpecifier(comptime placeholder: []const u8, comptime T: type) ?ErasedSpecifier {
    if (std.mem.eql(u8, placeholder, "s")) return if (isByteString(T)) .bytes else null;
    if (std.mem.eql(u8, placeholder, "d")) return if (isSmallInt(T) or isSmallEnum(T)) .decimal else null;
    if (std.mem.eql(u8, placeholder, "x")) return if (isSmallInt(T) or isSmallEnum(T)) .hex else null;
    if (std.mem.eql(u8, placeholder, "t")) return if (hasStaticTagName(T)) .tag else null;
    if (std.mem.eql(u8, placeholder, "")) {
        if (isSmallInt(T)) return .decimal;
        if (T == bool) return .boolean;
        return null;
    }
    const child = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => return null,
    };
    if (std.mem.eql(u8, placeholder, "?d")) return if (isSmallInt(child) or isSmallEnum(child)) .optional_decimal else null;
    if (std.mem.eql(u8, placeholder, "?x")) return if (isSmallInt(child) or isSmallEnum(child)) .optional_hex else null;
    if (std.mem.eql(u8, placeholder, "?s")) return if (isByteString(child)) .optional_bytes else null;
    if (std.mem.eql(u8, placeholder, "?t")) return if (hasStaticTagName(child)) .optional_tag else null;
    return null;
}

fn isSmallInt(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |int| int.bits <= 64,
        else => false,
    };
}

fn isSmallEnum(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"enum" => |e| isSmallInt(e.tag_type),
        else => false,
    };
}

fn isByteString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

// `@tagName` cannot fail for these, so naming eagerly matches the standard
// path even when an earlier write failure would have skipped the value.
fn hasStaticTagName(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .error_set => true,
        .@"enum" => |e| e.is_exhaustive,
        .@"union" => |u| u.tag_type != null,
        else => false,
    };
}

inline fn eraseArg(comptime specifier: ErasedSpecifier, value: anytype) ErasedArg {
    return switch (specifier) {
        .bytes => .{ .bytes = value },
        .decimal => eraseInt(intValue(value), false),
        .hex => eraseInt(intValue(value), true),
        .tag => .{ .bytes = tagName(value) },
        .boolean => .{ .bytes = if (value) "true" else "false" },
        .optional_decimal => if (value) |payload| eraseInt(intValue(payload), false) else .{ .bytes = "null" },
        .optional_hex => if (value) |payload| eraseInt(intValue(payload), true) else .{ .bytes = "null" },
        .optional_bytes => if (value) |payload| .{ .bytes = payload } else .{ .bytes = "null" },
        .optional_tag => if (value) |payload| .{ .bytes = tagName(payload) } else .{ .bytes = "null" },
    };
}

inline fn intValue(value: anytype) switch (@typeInfo(@TypeOf(value))) {
    .@"enum" => |e| e.tag_type,
    else => @TypeOf(value),
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intFromEnum(value),
        else => value,
    };
}

inline fn eraseInt(value: anytype, comptime hex: bool) ErasedArg {
    return switch (@typeInfo(@TypeOf(value)).int.signedness) {
        .signed => if (hex) .{ .signed_hex = value } else .{ .signed = value },
        .unsigned => if (hex) .{ .unsigned_hex = value } else .{ .unsigned = value },
    };
}

inline fn tagName(value: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(value))) {
        .error_set => @errorName(value),
        else => @tagName(value),
    };
}

// Mirrors the literal handling of `Writer.print` for formats accepted by
// `erasedSpecifiers`: escaped braces become one brace.
fn erasedTemplate(comptime fmt: []const u8) []const u8 {
    @setEvalBranchQuota(@as(comptime_int, fmt.len) * 100 + 1000);
    comptime var template: []const u8 = "";
    comptime var start: usize = 0;
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        const c = fmt[i];
        if (c != '{' and c != '}') {
            i += 1;
            continue;
        }
        template = template ++ fmt[start..i];
        if (fmt[i + 1] == c) {
            template = template ++ .{c};
            i += 2;
        } else {
            template = template ++ .{erased_placeholder};
            i = std.mem.findScalarPos(u8, fmt, i, '}').? + 1;
        }
        start = i;
    }
    return template ++ fmt[start..];
}

fn writeErased(writer: *std.Io.Writer, template: []const u8, args: []const ErasedArg) std.Io.Writer.Error!void {
    var start: usize = 0;
    var next: usize = 0;
    for (template, 0..) |c, index| {
        if (c != erased_placeholder) continue;
        try writer.writeAll(template[start..index]);
        switch (args[next]) {
            .bytes => |bytes| try writer.writeAll(bytes),
            .signed => |value| try writer.printInt(value, 10, .lower, .{}),
            .unsigned => |value| try writer.printInt(value, 10, .lower, .{}),
            .signed_hex => |value| try writer.printInt(value, 16, .lower, .{}),
            .unsigned_hex => |value| try writer.printInt(value, 16, .lower, .{}),
        }
        next += 1;
        start = index + 1;
    }
    try writer.writeAll(template[start..]);
}

fn writeTerminalSafeTraceLine(writer: *std.Io.Writer, raw: []const u8) !void {
    const marker = "...";
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        const encoded_len: usize = if (byte >= 0x20 and byte <= 0x7e) 1 else 4;
        if (writer.buffered().len + encoded_len + marker.len > max_trace_line_bytes) {
            try writer.writeAll(marker);
            return;
        }
        if (encoded_len == 1) {
            try writer.writeByte(byte);
        } else {
            try writer.print("\\x{x:0>2}", .{byte});
        }
    }
}

pub fn preview(text: []const u8, max_len: usize) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const line_end = std.mem.findScalar(u8, trimmed, '\n') orelse trimmed.len;
    const first_line = std.mem.trimEnd(u8, trimmed[0..line_end], "\r");
    if (first_line.len <= max_len) return first_line;
    return first_line[0..max_len];
}

pub fn terminalPreview(buf: []u8, text: []const u8) []const u8 {
    if (buf.len == 0) return buf[0..0];

    const first_line = preview(text, 512);
    var in_idx: usize = 0;
    var out_idx: usize = 0;
    while (in_idx < first_line.len and out_idx < buf.len) {
        const byte = first_line[in_idx];
        if (byte == 0x1b) {
            in_idx = skipTerminalEscape(first_line, in_idx);
            continue;
        }

        buf[out_idx] = if (byte == '\r' or byte == '\n' or byte == '\t')
            ' '
        else if (byte < 0x20 or byte == 0x7f)
            '?'
        else
            byte;
        out_idx += 1;
        in_idx += 1;
    }
    return buf[0..out_idx];
}

fn skipTerminalEscape(text: []const u8, start: usize) usize {
    if (start + 1 >= text.len) return start + 1;

    const introducer = text[start + 1];
    if (introducer == '[') {
        var i = start + 2;
        while (i < text.len) : (i += 1) {
            const byte = text[i];
            if (byte >= 0x40 and byte <= 0x7e) return i + 1;
        }
        return text.len;
    }

    if (introducer == ']') {
        var i = start + 2;
        while (i < text.len) : (i += 1) {
            if (text[i] == 0x07) return i + 1;
            if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
        }
        return text.len;
    }

    return start + 2;
}

pub fn redactedJsonPreview(alloc: Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return alloc.dupe(u8, "<empty>");

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch {
        return std.fmt.allocPrint(alloc, "<invalid-json bytes={d}>", .{text.len});
    };
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeRedactedJsonValuePreview(&out.writer, parsed.value, 0, .preserve);
    return out.toOwnedSlice();
}

pub fn keylessJsonPreview(alloc: Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return alloc.dupe(u8, "<empty>");

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return std.fmt.allocPrint(alloc, "<invalid-json bytes={d}>", .{text.len});
    };
    defer parsed.deinit();

    return keylessJsonValuePreview(alloc, parsed.value);
}

pub fn keylessJsonValuePreview(alloc: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeRedactedJsonValuePreview(&out.writer, value, 0, .omit);
    return out.toOwnedSlice();
}

const JsonKeyPolicy = enum {
    preserve,
    omit,
};

fn writeRedactedJsonValuePreview(
    writer: anytype,
    value: std.json.Value,
    depth: usize,
    key_policy: JsonKeyPolicy,
) !void {
    switch (value) {
        .object => |object| {
            if (depth >= 2) {
                try writer.print("<object_fields={d}>", .{object.count()});
                return;
            }

            switch (key_policy) {
                .preserve => {
                    try writer.writeByte('{');
                    var it = object.iterator();
                    var written: usize = 0;
                    while (it.next()) |entry| {
                        if (written > 0) try writer.writeByte(',');
                        if (written >= 6) {
                            try writer.writeAll("...");
                            break;
                        }
                        try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                        try writer.writeByte(':');
                        try writeRedactedJsonValuePreview(writer, entry.value_ptr.*, depth + 1, key_policy);
                        written += 1;
                    }
                    try writer.writeByte('}');
                },
                .omit => {
                    try writer.print("<object_fields={d}", .{object.count()});
                    if (object.count() > 0) {
                        try writer.writeAll(" values=[");
                        var it = object.iterator();
                        var written: usize = 0;
                        while (it.next()) |entry| {
                            if (written > 0) try writer.writeByte(',');
                            if (written >= 6) {
                                try writer.writeAll("...");
                                break;
                            }
                            try writeRedactedJsonValuePreview(writer, entry.value_ptr.*, depth + 1, key_policy);
                            written += 1;
                        }
                        try writer.writeByte(']');
                    }
                    try writer.writeByte('>');
                },
            }
        },
        .array => |array| try writer.print("<array_len={d}>", .{array.items.len}),
        .string => |string| try writer.print("<string_bytes={d}>", .{string.len}),
        .integer, .float, .number_string => try writer.writeAll("<number>"),
        .bool => try writer.writeAll("<bool>"),
        .null => try writer.writeAll("<null>"),
    }
}

pub fn resetForTest() void {
    shutdown();
    next_turn_id.store(1, .seq_cst);
    next_step_id.store(1, .seq_cst);
    next_subagent_id.store(1, .seq_cst);
}

pub fn configureForTest(alloc: Allocator, path: []const u8) !void {
    const owned = try alloc.dupe(u8, path);
    defer alloc.free(owned);
    try configure(.{ .file_path = owned });
}

pub fn configureForTestWithScopes(alloc: Allocator, path: []const u8, scope_filter: []const u8) !void {
    const owned = try alloc.dupe(u8, path);
    defer alloc.free(owned);
    try configure(.{ .file_path = owned, .scope_filter = scope_filter });
}

pub fn configure(options: Options) !void {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    if (state.configured) return;
    state.configured = true;
    state.stderr_enabled = options.stderr_enabled;

    if (options.file_path) |path| {
        try ensureParentDir(path);
        rotateIfTooLarge(path, default_log_max_bytes);
        var file = try std.Io.Dir.createFileAbsolute(zio, path, .{ .truncate = false });
        file.close(zio);
        state.file_path = std.heap.c_allocator.dupe(u8, path) catch null;
    }
    if (options.scope_filter) |filter| {
        const trimmed = std.mem.trim(u8, filter, " \t\r\n");
        if (trimmed.len > 0) state.scope_filter = try std.heap.c_allocator.dupe(u8, trimmed);
    }

    state.enabled = state.stderr_enabled or state.file_path != null;
}

fn rotateIfTooLarge(path: []const u8, max_bytes: u64) void {
    const zio = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(zio, path, .{}) catch return;
    var should_truncate = false;
    {
        defer file.close(zio);
        const stat = file.stat(zio) catch return;
        if (stat.size > max_bytes) should_truncate = true;
    }
    if (!should_truncate) return;
    var truncate = std.Io.Dir.createFileAbsolute(zio, path, .{ .truncate = true }) catch return;
    truncate.close(zio);
}

pub fn isEnabled() bool {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);
    return state.enabled;
}

pub fn isScopeEnabled(scope: []const u8) bool {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);
    if (!state.enabled) return false;
    const filter = state.scope_filter orelse return true;
    return scopeFilterAllows(filter, scope);
}

fn writeLine(line: []const u8) void {
    const zio = io_mod.getIo();
    state_mutex.lockUncancelable(zio);
    defer state_mutex.unlock(zio);

    if (!state.enabled) return;

    if (state.stderr_enabled) {
        std.debug.print("{s}", .{line});
    }
    if (state.file_path) |path| {
        appendLineToFile(zio, path, line);
    }
}

fn appendLineToFile(zio: std.Io, path: []const u8, line: []const u8) void {
    var file = std.Io.Dir.createFileAbsolute(zio, path, .{
        .truncate = false,
        .lock = .exclusive,
    }) catch return;
    defer file.close(zio);
    _ = std.c.lseek(file.handle, 0, std.posix.SEEK.END);
    file.writeStreamingAll(zio, line) catch {};
}

fn loadOptionsFromEnv(alloc: Allocator, workspace_root: []const u8) !Options {
    const trace_log = loadOptionalEnv("FX_TRACE_LOG");
    const trace_flag = loadOptionalEnv("FX_TRACE");
    const trace_stderr = loadOptionalEnv("FX_TRACE_STDERR");
    const trace_scopes = loadOptionalEnv("FX_TRACE_SCOPES");
    const stderr_enabled = isTruthy(trace_stderr);

    if (trace_log) |raw_path| {
        const resolved = try resolveLogPath(alloc, workspace_root, raw_path);
        return .{ .file_path = resolved, .stderr_enabled = stderr_enabled, .scope_filter = trace_scopes };
    }

    if (isTruthy(trace_flag)) {
        return .{
            .file_path = try defaultLogPath(alloc),
            .stderr_enabled = stderr_enabled,
            .scope_filter = trace_scopes,
        };
    }

    return .{ .stderr_enabled = stderr_enabled, .scope_filter = trace_scopes };
}

fn loadOptionalEnv(name: []const u8) ?[]const u8 {
    return io_mod.getenv(name);
}

fn isTruthy(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

fn scopeFilterAllows(filter: []const u8, scope: []const u8) bool {
    var rest = filter;
    while (true) {
        const next_comma = std.mem.findScalar(u8, rest, ',');
        const raw_part = if (next_comma) |idx| rest[0..idx] else rest;
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len > 0 and std.mem.eql(u8, part, scope)) return true;
        if (next_comma) |idx| {
            rest = rest[idx + 1 ..];
        } else {
            return false;
        }
    }
}

fn resolveLogPath(alloc: Allocator, workspace_root: []const u8, raw_path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidTracePath;
    if (std.fs.path.isAbsolute(trimmed)) return alloc.dupe(u8, trimmed);
    return std.fs.path.join(alloc, &.{ workspace_root, trimmed });
}

fn defaultLogPath(alloc: Allocator) ![]u8 {
    if (io_mod.getenv("HOME")) |home| {
        return defaultLogPathForHome(alloc, home);
    }
    return fallbackLogPathForMillis(alloc, io_mod.milliTimestamp());
}

fn defaultLogPathForHome(alloc: Allocator, home: []const u8) ![]u8 {
    return profile_paths.traceLogPath(alloc, home);
}

fn fallbackLogPathForMillis(alloc: Allocator, millis: i64) ![]u8 {
    return std.fmt.allocPrint(alloc, "/tmp/fx-trace-{d}.log", .{millis});
}

fn ensureParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try makeAbsolutePath(parent);
}

fn makeAbsolutePath(path: []const u8) !void {
    const zio = io_mod.getIo();
    std.Io.Dir.createDirAbsolute(zio, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            if (std.fs.path.dirname(path)) |parent| {
                try makeAbsolutePath(parent);
                try std.Io.Dir.createDirAbsolute(zio, path, .default_dir);
            } else {
                return err;
            }
        },
    };
}

fn tmpRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn tmpPath(alloc: Allocator, root: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ root, name });
}

fn readFileForTest(alloc: Allocator, path: []const u8) ![]u8 {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{});
    defer file.close(zio);
    return io_mod.readFileToEnd(alloc, &file, 8192);
}

test "isTruthy parses accepted and rejected values" {
    try std.testing.expect(isTruthy("1"));
    try std.testing.expect(isTruthy("true"));
    try std.testing.expect(isTruthy("YES"));
    try std.testing.expect(isTruthy("on"));
    try std.testing.expect(!isTruthy("0"));
    try std.testing.expect(!isTruthy(""));
    try std.testing.expect(!isTruthy(" \t\r\n"));
    try std.testing.expect(!isTruthy(null));
}

test "home default log path uses fx logs directory" {
    const alloc = std.testing.allocator;
    const path = try defaultLogPathForHome(alloc, "/tmp/fake-home");
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/logs/trace.log", path);
}

test "fallback default log path uses tmp trace path" {
    const alloc = std.testing.allocator;
    const path = try fallbackLogPathForMillis(alloc, 12345);
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/tmp/fx-trace-12345.log", path);
}

test "trace logger writes configured file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(alloc, tmp);
    defer alloc.free(root);
    const path = try tmpPath(alloc, root, "trace.log");
    defer alloc.free(path);

    resetForTest();
    defer resetForTest();
    try configureForTest(alloc, path);
    logf("test", "hello {d}", .{42});

    const trace = try readFileForTest(alloc, path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "[test] hello 42") != null);
}

test "trace logger filters scopes and writes structured events" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(alloc, tmp);
    defer alloc.free(root);
    const path = try tmpPath(alloc, root, "scoped-trace.log");
    defer alloc.free(path);

    resetForTest();
    defer resetForTest();
    try configureForTestWithScopes(alloc, path, "agent, tool");
    logf("agent", "human line", .{});
    logf("worker", "filtered line", .{});
    eventf("tool", "execution_start", .{ .turn_id = 7, .step_id = 11 }, "name={s}", .{"read_file"});

    const trace = try readFileForTest(alloc, path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "[agent] human line") != null);
    try std.testing.expect(std.mem.find(u8, trace, "[worker] filtered line") == null);
    try std.testing.expect(std.mem.find(u8, trace, "[tool] event=execution_start turn_id=7 step_id=11 name=read_file") != null);
}

fn expectErasedMatchesStandard(comptime fmt: []const u8, args: anytype) !void {
    const specifiers = comptime erasedSpecifiers(fmt, @TypeOf(args)).?;
    var erased: [specifiers.len]ErasedArg = undefined;
    inline for (specifiers, 0..) |specifier, index| {
        erased[index] = eraseArg(specifier, args[index]);
    }
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    try expected.writer.print(fmt, args);
    var actual: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer actual.deinit();
    try writeErased(&actual.writer, comptime erasedTemplate(fmt), &erased);
    try std.testing.expectEqualStrings(expected.written(), actual.written());
}

test "erased trace formats match the standard writer byte for byte" {
    const Color = enum { red, green_blue };
    const Open = enum(u8) { a = 1, _ };
    const Shape = union(enum) { circle: u32, square: void };
    const sentinel: [:0]const u8 = "z";
    var mutable = [_]u8{ 'm', 'u', 't' };

    try expectErasedMatchesStandard("", .{});
    try expectErasedMatchesStandard("plain text", .{});
    try expectErasedMatchesStandard("{{literal}} {{ and }}", .{});
    try expectErasedMatchesStandard("name={s} path={s}", .{ "read_file", @as([]const u8, "/tmp/a b") });
    try expectErasedMatchesStandard("{s}|{s}|{s}", .{ sentinel, @as([]u8, &mutable), &mutable });
    try expectErasedMatchesStandard("{d} {d} {d} {d} {d}", .{
        @as(i8, -128),
        @as(u8, 255),
        @as(i64, std.math.minInt(i64)),
        @as(u64, std.math.maxInt(u64)),
        @as(usize, 0),
    });
    try expectErasedMatchesStandard("{x} {x} {x}", .{ @as(u32, 0xdeadbeef), @as(i16, -255), @as(u64, 0) });
    try expectErasedMatchesStandard("{d} {x} {t}", .{ Color.green_blue, Color.red, Color.green_blue });
    try expectErasedMatchesStandard("{d}", .{@as(Open, @enumFromInt(9))});
    try expectErasedMatchesStandard("{t} {t}", .{ error.OutOfMemory, Shape{ .circle = 3 } });
    try expectErasedMatchesStandard("{} {} {}", .{ true, false, @as(i32, -7) });
    try expectErasedMatchesStandard("{?d} {?d} {?s} {?s} {?t} {?t} {?x}", .{
        @as(?u32, null),
        @as(?i64, -3),
        @as(?[]const u8, null),
        @as(?[]const u8, "x"),
        @as(?Color, null),
        @as(?Color, .red),
        @as(?u8, 255),
    });
    try expectErasedMatchesStandard("{s}{d}}}{{{s}", .{ "a", @as(u16, 1), "b" });
}

test "trace formats outside the erased subset keep the standard writer" {
    const Open = enum(u8) { a = 1, _ };
    const Point = struct {
        x: u8,
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{d}", .{self.x});
        }
    };
    try std.testing.expect(comptime erasedSpecifiers("{any}", @TypeOf(.{@as(u32, 1)})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{d:.3}", @TypeOf(.{@as(f64, 1)})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{d}", @TypeOf(.{@as(f64, 1)})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{d}", @TypeOf(.{@as(i128, 1)})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{d}", @TypeOf(.{42})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{0s}", @TypeOf(.{"x"})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{s:>8}", @TypeOf(.{"x"})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{s}", @TypeOf(.{@as([]const u16, &.{})})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{x}", @TypeOf(.{@as([]const u8, "ab")})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{t}", @TypeOf(.{@as(Open, .a)})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{?}", @TypeOf(.{@as(?u8, 1)})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{f}", @TypeOf(.{Point{ .x = 1 }})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{d} {d}", @TypeOf(.{@as(u8, 1)})) == null);
    try std.testing.expect(comptime erasedSpecifiers("{d}", @TypeOf(.{ @as(u8, 1), @as(u8, 2) })) == null);
    try std.testing.expect(comptime erasedSpecifiers("{s}", @TypeOf(.{ .name = "x" })) == null);
    try std.testing.expect(comptime erasedSpecifiers("}", @TypeOf(.{})) == null);
    try std.testing.expect(comptime erasedSpecifiers("a\x1ab {s}", @TypeOf(.{"x"})) == null);
}

test "erased trace templates keep only literal text and one byte per placeholder" {
    try std.testing.expectEqualStrings("tool=\x1a n=\x1a {x}", comptime erasedTemplate("tool={s} n={d} {{x}}"));
    try std.testing.expectEqualStrings("", comptime erasedTemplate(""));
    try std.testing.expectEqualStrings("\x1a}\x1a{", comptime erasedTemplate("{?d}}}{t}{{"));
    const long = "event detail " ** 120 ++ "{s}";
    try std.testing.expectEqualStrings("event detail " ** 120 ++ "\x1a", comptime erasedTemplate(long));
    try std.testing.expect(comptime erasedSpecifiers(long, @TypeOf(.{"x"})) != null);
}

test "trace logger writes erased formats" {
    const alloc = std.testing.allocator;
    const Kind = enum { read, write };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(alloc, tmp);
    defer alloc.free(root);
    const path = try tmpPath(alloc, root, "erased-trace.log");
    defer alloc.free(path);

    resetForTest();
    defer resetForTest();
    try configureForTest(alloc, path);
    logf("test", "tool={s} n={d} ok={} kind={t} {{x}}", .{ "edit", @as(usize, 3), true, Kind.write });
    eventf("tool", "execution_end", .{ .turn_id = 2 }, "status={t} code={?d}", .{ Kind.read, @as(?u8, null) });

    const trace = try readFileForTest(alloc, path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "[test] tool=edit n=3 ok=true kind=write {x}\n") != null);
    try std.testing.expect(std.mem.find(u8, trace, "[tool] event=execution_end turn_id=2 status=read code=null\n") != null);
}

test "trace id generators reset for tests" {
    resetForTest();
    try std.testing.expectEqual(@as(u64, 1), nextTurnId());
    try std.testing.expectEqual(@as(u64, 2), nextTurnId());
    try std.testing.expectEqual(@as(u64, 1), nextStepId());
    resetForTest();
    try std.testing.expectEqual(@as(u64, 1), nextTurnId());
}

test "redactedJsonPreview reports shape without values" {
    const alloc = std.testing.allocator;
    const preview_text = try redactedJsonPreview(alloc, "{\"path\":\"secret.txt\",\"content\":\"very secret\",\"nested\":{\"token\":\"abc\"}}");
    defer alloc.free(preview_text);

    try std.testing.expect(std.mem.find(u8, preview_text, "\"path\":<string_bytes=") != null);
    try std.testing.expect(std.mem.find(u8, preview_text, "\"content\":<string_bytes=") != null);
    try std.testing.expect(std.mem.find(u8, preview_text, "secret.txt") == null);
    try std.testing.expect(std.mem.find(u8, preview_text, "very secret") == null);
    try std.testing.expect(std.mem.find(u8, preview_text, "abc") == null);
}

test "keylessJsonPreview reports shape without keys or values" {
    const alloc = std.testing.allocator;
    const preview_text = try keylessJsonPreview(alloc, "{\"FX_DYNAMIC_PATH\":\"secret.txt\",\"FX_DYNAMIC_CONTENT\":\"very secret\",\"nested\":{\"FX_DYNAMIC_TOKEN\":\"abc\"}}");
    defer alloc.free(preview_text);

    try std.testing.expect(std.mem.find(u8, preview_text, "<object_fields=3 values=[") != null);
    try std.testing.expect(std.mem.find(u8, preview_text, "FX_DYNAMIC_PATH") == null);
    try std.testing.expect(std.mem.find(u8, preview_text, "FX_DYNAMIC_CONTENT") == null);
    try std.testing.expect(std.mem.find(u8, preview_text, "FX_DYNAMIC_TOKEN") == null);
    try std.testing.expect(std.mem.find(u8, preview_text, "secret.txt") == null);
    try std.testing.expect(std.mem.find(u8, preview_text, "very secret") == null);
    try std.testing.expect(std.mem.find(u8, preview_text, "abc") == null);
}

test "preview trims and keeps first line" {
    try std.testing.expectEqualStrings("first", preview(" \t\nfirst\nsecond\n ", 128));
}

test "preview trims trailing carriage return for CRLF input" {
    try std.testing.expectEqualStrings("first", preview("first\r\nsecond", 128));
}

test "preview clamps by byte length" {
    try std.testing.expectEqualStrings("abcd", preview("abcdef", 4));
}

test "preview returns borrowed slice" {
    const input: []const u8 = "  borrowed  ";
    const result = preview(input, 128);
    const input_start = @intFromPtr(input.ptr);
    const input_end = input_start + input.len;
    const result_start = @intFromPtr(result.ptr);
    try std.testing.expect(result_start >= input_start);
    try std.testing.expect(result_start < input_end);
}

test "terminalPreview strips common terminal controls" {
    var buf: [64]u8 = undefined;
    const result = terminalPreview(buf[0..], "hi \x1b[31mred\x1b[0m \x1b]8;;https://example.com\x07link\x1b]8;;\x07\nnext");
    try std.testing.expectEqualStrings("hi red link", result);
}

test "trace lines encode every non-ASCII and control byte" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeTerminalSafeTraceLine(
        &out.writer,
        "server=bad\n\x1b]0;owned\x07\xff",
    );
    try std.testing.expectEqualStrings(
        "server=bad\\x0a\\x1b]0;owned\\x07\\xff",
        out.written(),
    );
}

test "resolveLogPath resolves absolute and relative paths" {
    const alloc = std.testing.allocator;
    const absolute = try resolveLogPath(alloc, "/tmp/workspace", " \t/tmp/fx-absolute-trace.log\n");
    defer alloc.free(absolute);
    try std.testing.expectEqualStrings("/tmp/fx-absolute-trace.log", absolute);

    const relative = try resolveLogPath(alloc, "/tmp/workspace", "logs/trace.log");
    defer alloc.free(relative);
    const expected = try std.fs.path.join(alloc, &.{ "/tmp/workspace", "logs/trace.log" });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, relative);
}

test "resolveLogPath rejects empty trace paths" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidTracePath, resolveLogPath(alloc, "/tmp/workspace", ""));
    try std.testing.expectError(error.InvalidTracePath, resolveLogPath(alloc, "/tmp/workspace", " \t\r\n"));
}

test "configure is first config wins" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(alloc, tmp);
    defer alloc.free(root);
    const first_path = try tmpPath(alloc, root, "first.log");
    defer alloc.free(first_path);
    const second_path = try tmpPath(alloc, root, "second.log");
    defer alloc.free(second_path);

    resetForTest();
    defer resetForTest();
    try configureForTest(alloc, first_path);
    try configure(.{ .file_path = second_path });
    logf("test", "first sink only", .{});

    const first_trace = try readFileForTest(alloc, first_path);
    defer alloc.free(first_trace);
    try std.testing.expect(std.mem.find(u8, first_trace, "first sink only") != null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(std.testing.io, second_path, .{}));
}

test "configure enables stderr-only tracing" {
    resetForTest();
    defer resetForTest();
    try configure(.{ .stderr_enabled = true });
    try std.testing.expect(isEnabled());
}

test "shutdown clears state and allows reconfigure" {
    resetForTest();
    defer resetForTest();
    try configure(.{ .stderr_enabled = true });
    try std.testing.expect(isEnabled());
    shutdown();
    try std.testing.expect(!isEnabled());
    try configure(.{ .stderr_enabled = true });
    try std.testing.expect(isEnabled());
}

test "configureFromEnv leaves tracing disabled without env" {
    resetForTest();
    defer resetForTest();
    try std.testing.expect(io_mod.getenv("FX_TRACE_LOG") == null);
    try std.testing.expect(io_mod.getenv("FX_TRACE") == null);
    try std.testing.expect(io_mod.getenv("FX_TRACE_STDERR") == null);
    configureFromEnv(std.testing.allocator, "/tmp/workspace");
    try std.testing.expect(!isEnabled());
}
