const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("session.zig");
const Allocator = std.mem.Allocator;

const paths = @import("session_store_paths.zig");
const types = @import("session_store_types.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const cancellation = @import("../shared/read_cancellation.zig");
const publication = @import("session_index_publication.zig");

const validateSessionId = paths.validateSessionId;
const SessionSummary = types.SessionSummary;
const SessionIndexPublication = types.SessionIndexPublication;
const ResumableSessionContinuation = types.ResumableSessionContinuation;
const ResumableSessionPage = types.ResumableSessionPage;
const StateSummary = types.StateSummary;

const WorkspaceLatest = struct {
    workspace_root: []u8,
    session_id: []u8,

    fn deinit(self: *WorkspaceLatest, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const SmallCacheRead = union(enum) {
    missing,
    oversized,
    bytes: []const u8,
};

const JsonStringToken = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: JsonStringToken, alloc: Allocator) void {
        if (self.owned) |value| alloc.free(value);
    }
};

pub const session_index_file = "index.json";
const session_index_generation_bytes: usize = 16;
const relationship_migration_snapshot_file = "relationship-migration-index.json";
pub const max_session_index_bytes: usize = 16 * 1024 * 1024;
const session_index_schema_version: i64 = 4;
pub const relationship_migration_candidate_limit: usize = 16;
const relationship_migration_read_bytes: usize = 64 * 1024;
const relationship_migration_overlap_bytes: u64 = 512;
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);

fn parseIndexGeneration(raw: []const u8) ![16]u8 {
    if (raw.len != 32) return error.InvalidSessionIndex;
    var result: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return error.InvalidSessionIndex;
    const canonical = std.fmt.bytesToHex(result, .lower);
    if (!std.mem.eql(u8, &canonical, raw)) return error.InvalidSessionIndex;
    return result;
}

pub const RelationshipMigrationCursor = struct {
    inode: u64 = 0,
    size: u64 = 0,
    mtime_ns: i128 = 0,
    offset: u64 = 0,
};

pub const RelationshipMigrationCandidatePage = struct {
    cursor: RelationshipMigrationCursor,
    ids: std.ArrayList([]u8) = .empty,
    has_more: bool = false,

    pub fn deinit(self: *RelationshipMigrationCandidatePage, alloc: Allocator) void {
        for (self.ids.items) |id| alloc.free(id);
        self.ids.deinit(alloc);
        self.* = undefined;
    }
};

fn readOptionalCacheFile(alloc: Allocator, path: []const u8, max_bytes: usize) !?[]u8 {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &file, max_bytes);
}

/// Reads the aggregate summary cache at `path`, trying a stack-buffer fast
/// read then the fast parser, falling back to a heap read + scanner parse.
/// `error.SessionIndexNotFound` if absent. Caller owns the result.
pub fn readSessionStateSummary(alloc: Allocator, path: []const u8) !StateSummary {
    var prefix_buf: [4096]u8 = undefined;
    if (try readCachePrefix(path, &prefix_buf)) |prefix| {
        if (try parseSessionStateSummaryFast(alloc, prefix)) |summary| {
            return summary;
        }
    } else {
        return error.SessionIndexNotFound;
    }

    var stack_buf: [64 * 1024]u8 = undefined;
    switch (try readSmallCacheFile(path, &stack_buf)) {
        .missing => return error.SessionIndexNotFound,
        .oversized => {},
        .bytes => |bytes| {
            if (try parseSessionStateSummaryFast(alloc, bytes)) |summary| return summary;
            return parseSessionStateSummary(alloc, bytes);
        },
    }

    const bytes = try readOptionalCacheFile(alloc, path, 256 * 1024) orelse return error.SessionIndexNotFound;
    defer alloc.free(bytes);

    if (try parseSessionStateSummaryFast(alloc, bytes)) |summary| return summary;
    return parseSessionStateSummary(alloc, bytes);
}

fn readCachePrefix(path: []const u8, buffer: []u8) !?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const count = try file.readPositionalAll(io_mod.getIo(), buffer, 0);
    return buffer[0..count];
}

/// Reads the latest session id for `target_workspace` from the summary cache,
/// fast path then scanner fallback. Returns null if the workspace has no entry.
fn readLatestWorkspaceSessionId(alloc: Allocator, path: []const u8, target_workspace: []const u8) !?[]u8 {
    var stack_buf: [64 * 1024]u8 = undefined;
    switch (try readSmallCacheFile(path, &stack_buf)) {
        .missing => return error.SessionIndexNotFound,
        .oversized => {},
        .bytes => |bytes| {
            if (try parseLatestWorkspaceSessionIdFast(alloc, bytes, target_workspace)) |id| return id;
            return parseLatestWorkspaceSessionId(alloc, bytes, target_workspace);
        },
    }

    const bytes = try readOptionalCacheFile(alloc, path, 256 * 1024) orelse return error.SessionIndexNotFound;
    defer alloc.free(bytes);

    if (try parseLatestWorkspaceSessionIdFast(alloc, bytes, target_workspace)) |id| return id;
    return parseLatestWorkspaceSessionId(alloc, bytes, target_workspace);
}

fn readSmallCacheFile(path: []const u8, buf: []u8) !SmallCacheRead {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer file.close(io_mod.getIo());

    const zio = io_mod.getIo();
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.readStreaming(zio, &.{buf[total..]}) catch |err| switch (err) {
            error.EndOfStream => return .{ .bytes = buf[0..total] },
            else => return err,
        };
        if (n == 0) return .{ .bytes = buf[0..total] };
        total += n;
    }

    var extra: [1]u8 = undefined;
    const n = file.readStreaming(zio, &.{extra[0..]}) catch |err| switch (err) {
        error.EndOfStream => return .{ .bytes = buf[0..total] },
        else => return err,
    };
    return if (n == 0) .{ .bytes = buf[0..total] } else .oversized;
}

/// Best-effort byte scan for one workspace entry. Returns null to defer to the
/// scanner path; only allocation can fail.
fn parseLatestWorkspaceSessionIdFast(alloc: Allocator, bytes: []const u8, target_workspace: []const u8) Allocator.Error!?[]u8 {
    if (!isSimpleJsonStringContent(target_workspace)) return null;

    const array_key = "\"latest_by_workspace\":[";
    const array_start = std.mem.find(u8, bytes, array_key) orelse return null;
    const array_tail = bytes[array_start + array_key.len ..];
    const array_end = std.mem.findScalar(u8, array_tail, ']') orelse return null;
    const array = array_tail[0..array_end];

    var needle_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"workspace_root\":\"{s}\"", .{target_workspace}) catch return null;
    const match_start = std.mem.find(u8, array, needle) orelse return null;
    const entry_tail = array[match_start + needle.len ..];
    const entry_end = std.mem.findScalar(u8, entry_tail, '}') orelse return null;
    const entry = entry_tail[0..entry_end];

    const id_key = "\"id\":\"";
    const id_start = std.mem.find(u8, entry, id_key) orelse return null;
    const id_tail = entry[id_start + id_key.len ..];
    const id_end = std.mem.findScalar(u8, id_tail, '"') orelse return null;
    const id = id_tail[0..id_end];
    validateSessionId(id) catch return null;
    return try alloc.dupe(u8, id);
}

/// True if `text` contains no characters needing JSON escaping, so it is safe
/// to match literally in the fast scan.
fn isSimpleJsonStringContent(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte == '"' or byte == '\\') return false;
    }
    return true;
}

/// Best-effort byte scan of the summary cache. Returns the parsed summary, or
/// null to signal "fall back to the scanner" (it never reports a hard parse
/// error); only allocation can fail.
fn parseSessionStateSummaryFast(alloc: Allocator, bytes: []const u8) Allocator.Error!?StateSummary {
    const schema_key = "\"schema_version\":1";
    if (std.mem.find(u8, bytes, schema_key) == null) return null;

    const count_key = "\"count\":";
    const count_start = std.mem.find(u8, bytes, count_key) orelse return null;
    const count_tail = bytes[count_start + count_key.len ..];
    const count_end = countNumberEnd(count_tail);
    if (count_end == 0) return null;
    const count = std.fmt.parseUnsigned(usize, count_tail[0..count_end], 10) catch return null;

    const latest_key = "\"latest_id\":";
    const latest_start = std.mem.find(u8, bytes, latest_key) orelse return null;
    const latest_tail = bytes[latest_start + latest_key.len ..];
    if (std.mem.startsWith(u8, latest_tail, "null")) {
        return .{ .count = count, .latest_id = null };
    }
    if (latest_tail.len == 0 or latest_tail[0] != '"') return null;
    const id_tail = latest_tail[1..];
    const id_end = std.mem.findScalar(u8, id_tail, '"') orelse return null;
    const id = id_tail[0..id_end];
    if (!isSimpleJsonStringContent(id)) return null;
    validateSessionId(id) catch return null;

    return .{
        .count = count,
        .latest_id = try alloc.dupe(u8, id),
    };
}

fn countNumberEnd(bytes: []const u8) usize {
    var end: usize = 0;
    while (end < bytes.len and std.ascii.isDigit(bytes[end])) {
        end += 1;
    }
    return end;
}

/// Authoritative `std.json.Scanner` parse of the summary cache. Strict:
/// malformed input is `error.InvalidSessionIndex`.
fn parseSessionStateSummary(alloc: Allocator, bytes: []const u8) !StateSummary {
    var scanner = std.json.Scanner.initCompleteInput(alloc, bytes);
    defer scanner.deinit();

    try expectJsonToken(try scanner.next(), .object_begin);
    var schema_ok = false;
    var count: ?usize = null;
    var latest_id: ?[]u8 = null;
    errdefer if (latest_id) |id| alloc.free(id);

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => {
                const key = try jsonStringFromToken(token);
                defer key.deinit(alloc);

                if (std.mem.eql(u8, key.text, "schema_version")) {
                    schema_ok = try readSummarySchemaVersion(&scanner);
                } else if (std.mem.eql(u8, key.text, "count")) {
                    count = try readJsonUsize(&scanner, alloc);
                } else if (std.mem.eql(u8, key.text, "latest_id")) {
                    latest_id = try readOptionalJsonStringDup(&scanner, alloc);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeJsonToken(alloc, token);
                return error.InvalidSessionIndex;
            },
        }
    }
    try expectJsonToken(try scanner.next(), .end_of_document);

    if (!schema_ok) return error.InvalidSessionIndex;
    if (latest_id) |id| validateSessionId(id) catch return error.InvalidSessionIndex;
    return .{ .count = count orelse return error.InvalidSessionIndex, .latest_id = latest_id };
}

/// Authoritative scanner parse returning the matched workspace id, or null.
fn parseLatestWorkspaceSessionId(alloc: Allocator, bytes: []const u8, target_workspace: []const u8) !?[]u8 {
    var scanner = std.json.Scanner.initCompleteInput(alloc, bytes);
    defer scanner.deinit();

    try expectJsonToken(try scanner.next(), .object_begin);
    var schema_ok = false;
    var matched_id: ?[]u8 = null;
    errdefer if (matched_id) |id| alloc.free(id);

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => {
                const key = try jsonStringFromToken(token);
                defer key.deinit(alloc);

                if (std.mem.eql(u8, key.text, "schema_version")) {
                    schema_ok = try readSummarySchemaVersion(&scanner);
                } else if (std.mem.eql(u8, key.text, "latest_by_workspace")) {
                    matched_id = try readLatestWorkspaceArray(&scanner, alloc, target_workspace);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeJsonToken(alloc, token);
                return error.InvalidSessionIndex;
            },
        }
    }
    try expectJsonToken(try scanner.next(), .end_of_document);

    if (!schema_ok) return error.InvalidSessionIndex;
    return matched_id;
}

fn readLatestWorkspaceArray(scanner: *std.json.Scanner, alloc: Allocator, target_workspace: []const u8) !?[]u8 {
    try expectJsonToken(try scanner.next(), .array_begin);
    var matched_id: ?[]u8 = null;
    errdefer if (matched_id) |id| alloc.free(id);

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .array_end => return matched_id,
            .object_begin => {
                const candidate = try readLatestWorkspaceEntry(scanner, alloc, target_workspace);
                if (candidate) |id| {
                    if (matched_id == null) {
                        matched_id = id;
                    } else {
                        alloc.free(id);
                    }
                }
            },
            else => return error.InvalidSessionIndex,
        }
    }
}

fn readLatestWorkspaceEntry(scanner: *std.json.Scanner, alloc: Allocator, target_workspace: []const u8) !?[]u8 {
    var workspace_matches = false;
    var id: ?[]u8 = null;
    errdefer if (id) |value| alloc.free(value);

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => {
                const key = try jsonStringFromToken(token);
                defer key.deinit(alloc);

                if (std.mem.eql(u8, key.text, "workspace_root")) {
                    const value = try readJsonString(scanner, alloc);
                    defer value.deinit(alloc);
                    workspace_matches = std.mem.eql(u8, value.text, target_workspace);
                } else if (std.mem.eql(u8, key.text, "id")) {
                    if (id) |old| alloc.free(old);
                    id = try readJsonStringDup(scanner, alloc);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeJsonToken(alloc, token);
                return error.InvalidSessionIndex;
            },
        }
    }

    if (workspace_matches) {
        const matched_id = id orelse return error.InvalidSessionIndex;
        validateSessionId(matched_id) catch return error.InvalidSessionIndex;
        return matched_id;
    }
    if (id) |value| alloc.free(value);
    return null;
}

fn readSummarySchemaVersion(scanner: *std.json.Scanner) !bool {
    const token = try scanner.next();
    switch (token) {
        .number => |raw| return std.mem.eql(u8, raw, "1"),
        else => return error.InvalidSessionIndex,
    }
}

fn readJsonUsize(scanner: anytype, alloc: Allocator) !usize {
    const token = try scanner.nextAllocMax(alloc, .alloc_if_needed, 32);
    defer freeJsonToken(alloc, token);
    return switch (token) {
        .number, .allocated_number => |raw| std.fmt.parseUnsigned(usize, raw, 10) catch error.InvalidSessionIndex,
        else => error.InvalidSessionIndex,
    };
}

fn readOptionalJsonStringDup(scanner: *std.json.Scanner, alloc: Allocator) !?[]u8 {
    const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
    switch (token) {
        .null => return null,
        .string, .allocated_string => {
            const value = try jsonStringFromToken(token);
            defer value.deinit(alloc);
            return try alloc.dupe(u8, value.text);
        },
        else => {
            freeJsonToken(alloc, token);
            return error.InvalidSessionIndex;
        },
    }
}

fn readJsonStringDup(scanner: *std.json.Scanner, alloc: Allocator) ![]u8 {
    const value = try readJsonString(scanner, alloc);
    defer value.deinit(alloc);
    return try alloc.dupe(u8, value.text);
}

fn readSessionIndexGeneration(
    scanner: anytype,
    alloc: Allocator,
) ![session_index_generation_bytes]u8 {
    const value = try readJsonString(scanner, alloc);
    defer value.deinit(alloc);
    if (value.text.len != session_index_generation_bytes * 2) {
        return error.InvalidSessionIndex;
    }
    var generation: [session_index_generation_bytes]u8 = undefined;
    _ = std.fmt.hexToBytes(&generation, value.text) catch
        return error.InvalidSessionIndex;
    const canonical = std.fmt.bytesToHex(generation, .lower);
    if (!std.mem.eql(u8, &canonical, value.text)) {
        return error.InvalidSessionIndex;
    }
    return generation;
}

fn readJsonString(scanner: anytype, alloc: Allocator) !JsonStringToken {
    const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
    switch (token) {
        .string, .allocated_string => return jsonStringFromToken(token),
        else => {
            freeJsonToken(alloc, token);
            return error.InvalidSessionIndex;
        },
    }
}

fn jsonStringFromToken(token: std.json.Token) !JsonStringToken {
    return switch (token) {
        .string => |text| .{ .text = text },
        .allocated_string => |text| .{ .text = text, .owned = text },
        else => error.InvalidSessionIndex,
    };
}

fn freeJsonToken(alloc: Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_string => |text| alloc.free(text),
        .allocated_number => |text| alloc.free(text),
        else => {},
    }
}

fn expectJsonToken(token: std.json.Token, comptime expected: std.json.TokenType) !void {
    const actual: std.json.TokenType = switch (token) {
        .object_begin => .object_begin,
        .object_end => .object_end,
        .array_begin => .array_begin,
        .array_end => .array_end,
        .true => .true,
        .false => .false,
        .null => .null,
        .number, .partial_number, .allocated_number => .number,
        .string, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4, .allocated_string => .string,
        .end_of_document => .end_of_document,
    };
    if (actual != expected) return error.InvalidSessionIndex;
}

fn appendLatestWorkspaceSummary(alloc: Allocator, latest: *std.ArrayList(WorkspaceLatest), workspace_root: []const u8, session_id: []const u8) !void {
    for (latest.items) |*entry| {
        if (!std.mem.eql(u8, entry.workspace_root, workspace_root)) continue;
        if (std.mem.order(u8, session_id, entry.session_id) != .gt) return;
        const replacement_id = try alloc.dupe(u8, session_id);
        alloc.free(entry.session_id);
        entry.session_id = replacement_id;
        return;
    }

    const owned_workspace_root = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(owned_workspace_root);
    const owned_session_id = try alloc.dupe(u8, session_id);
    errdefer alloc.free(owned_session_id);
    try latest.append(alloc, .{
        .workspace_root = owned_workspace_root,
        .session_id = owned_session_id,
    });
}

/// Offline parsing preserves legacy cache compatibility. Current publications
/// enter through the pinned-snapshot reader below and require schema four.
fn parseSessionIndex(alloc: Allocator, json_text: []const u8) !std.ArrayList(SessionSummary) {
    const page = try parseSessionIndexPage(alloc, json_text, .{
        .limit = std.math.maxInt(usize),
        .resumable_only = false,
    });
    return page.summaries;
}

fn parseSessionIndexForWorkspace(
    alloc: Allocator,
    json_text: []const u8,
    workspace_root: []const u8,
) !std.ArrayList(SessionSummary) {
    const page = try parseSessionIndexPage(alloc, json_text, .{
        .workspace_root = workspace_root,
        .limit = std.math.maxInt(usize),
        .resumable_only = false,
    });
    return page.summaries;
}

pub const SessionIndexPageOptions = struct {
    workspace_root: ?[]const u8 = null,
    active_id: ?[]const u8 = null,
    continuation: ?ResumableSessionContinuation = null,
    limit: usize,
    resumable_only: bool,
    cancel_flag: ?*const std.atomic.Value(bool) = null,
};

const IndexReadBoundary = enum {
    after_summary,
    before_final_observation,
};

const IndexReadControls = struct {
    context: ?*anyopaque = null,
    boundary_fn: ?*const fn (?*anyopaque, IndexReadBoundary) anyerror!void = null,

    fn boundary(self: IndexReadControls, point: IndexReadBoundary) !void {
        if (self.boundary_fn) |callback| try callback(self.context, point);
    }
};

fn checkIndexReadCancellation(options: SessionIndexPageOptions) !void {
    if (options.cancel_flag) |flag| {
        if (flag.load(.acquire)) return error.Cancelled;
    }
}

const ParsedSessionIndexPage = struct {
    page: ResumableSessionPage,
    generation: ?[session_index_generation_bytes]u8,
};

fn parseSessionIndexPage(
    alloc: Allocator,
    json_text: []const u8,
    options: SessionIndexPageOptions,
) !ResumableSessionPage {
    const parsed = try parseSessionIndexPageDetailed(
        alloc,
        json_text,
        options,
        .{},
    );
    return parsed.page;
}

fn parseSessionIndexPageControlled(
    alloc: Allocator,
    json_text: []const u8,
    options: SessionIndexPageOptions,
    controls: IndexReadControls,
) !ResumableSessionPage {
    const parsed = try parseSessionIndexPageDetailed(
        alloc,
        json_text,
        options,
        controls,
    );
    return parsed.page;
}

fn parseSessionIndexPageDetailed(
    alloc: Allocator,
    json_text: []const u8,
    options: SessionIndexPageOptions,
    controls: IndexReadControls,
) !ParsedSessionIndexPage {
    if (json_text.len > max_session_index_bytes) return error.InvalidSessionIndex;
    var source: std.Io.Reader = .fixed(json_text);
    return parseSessionIndexReader(alloc, &source, options, controls, .legacy);
}

fn parseSessionIndexReader(
    alloc: Allocator,
    source: *std.Io.Reader,
    options: SessionIndexPageOptions,
    controls: IndexReadControls,
    schema: enum { legacy, publication },
) !ParsedSessionIndexPage {
    try checkIndexReadCancellation(options);
    var buffer: [cancellation.work_bytes]u8 = undefined;
    var checked = cancellation.Reader.init(source, &buffer, options.cancel_flag);
    var reader = std.json.Reader.init(alloc, &checked.interface);
    defer reader.deinit();
    return parseSessionIndexTokens(alloc, &reader, options, controls, schema == .publication) catch |err| {
        try checkIndexReadCancellation(options);
        return switch (err) {
            error.OutOfMemory, error.Cancelled, error.LegacySessionIndex => err,
            else => error.InvalidSessionIndex,
        };
    };
}

fn parseSessionIndexTokens(
    alloc: Allocator,
    scanner: *std.json.Reader,
    options: SessionIndexPageOptions,
    controls: IndexReadControls,
    current: bool,
) !ParsedSessionIndexPage {
    try expectJsonToken(try scanner.next(), .object_begin);
    var schema_ok = false;
    var sessions_seen = false;
    var generation: ?[session_index_generation_bytes]u8 = null;
    const retained_limit = @max(options.limit, 1) +| 1;
    var retained: std.ArrayList(SessionSummary) = .empty;
    defer {
        for (retained.items) |*summary| summary.deinit(alloc);
        retained.deinit(alloc);
    }
    while (true) {
        try checkIndexReadCancellation(options);
        const token = try scanner.nextAllocMax(alloc, .alloc_if_needed, 128);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => {
                const key = try jsonStringFromToken(token);
                defer key.deinit(alloc);
                if (std.mem.eql(u8, key.text, "schema_version")) {
                    if (schema_ok) return error.InvalidSessionIndex;
                    const version = try readJsonI64(scanner, alloc);
                    if (current and version != session_index_schema_version) return error.LegacySessionIndex;
                    if (version != 3 and version != session_index_schema_version) return error.InvalidSessionIndex;
                    schema_ok = true;
                } else if (std.mem.eql(u8, key.text, "generation")) {
                    if (generation != null) return error.InvalidSessionIndex;
                    generation = try readSessionIndexGeneration(scanner, alloc);
                } else if (std.mem.eql(u8, key.text, "sessions")) {
                    if (sessions_seen) return error.InvalidSessionIndex;
                    sessions_seen = true;
                    try parseSessionIndexPageRows(alloc, scanner, options, retained_limit, &retained, controls);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeJsonToken(alloc, token);
                return error.InvalidSessionIndex;
            },
        }
    }
    try expectJsonToken(try scanner.next(), .end_of_document);
    if (!schema_ok or !sessions_seen or (current and generation == null)) return error.InvalidSessionIndex;
    try sortSummariesNewestFirstInterruptible(retained.items, options.cancel_flag);
    const has_more = retained.items.len > options.limit;
    while (retained.items.len > options.limit) {
        var removed = retained.pop().?;
        removed.deinit(alloc);
    }
    try checkIndexReadCancellation(options);
    const result: ParsedSessionIndexPage = .{
        .page = .{ .summaries = retained, .has_more = has_more },
        .generation = generation,
    };
    retained = .empty;
    return result;
}

fn parseSessionIndexPageRows(
    alloc: Allocator,
    scanner: *std.json.Reader,
    options: SessionIndexPageOptions,
    retained_limit: usize,
    retained: *std.ArrayList(SessionSummary),
    controls: IndexReadControls,
) !void {
    try expectJsonToken(try scanner.next(), .array_begin);
    while (true) {
        try checkIndexReadCancellation(options);
        const token = try scanner.next();
        switch (token) {
            .array_end => return,
            .object_begin => {
                var summary = try readIndexedSummary(alloc, scanner);
                errdefer summary.deinit(alloc);
                try controls.boundary(.after_summary);
                try checkIndexReadCancellation(options);
                if (!indexedSummaryMatches(summary, options)) {
                    summary.deinit(alloc);
                    continue;
                }
                if (retained_limit == std.math.maxInt(usize)) {
                    try retained.append(alloc, summary);
                    continue;
                }
                var insert_at: usize = 0;
                while (insert_at < retained.items.len and
                    lessSummaryNewerFirst({}, retained.items[insert_at], summary))
                {
                    insert_at += 1;
                }
                if (insert_at >= retained_limit) {
                    summary.deinit(alloc);
                    continue;
                }
                try retained.insert(alloc, insert_at, summary);
                if (retained.items.len > retained_limit) {
                    if (retained.pop()) |removed_value| {
                        var removed = removed_value;
                        removed.deinit(alloc);
                    }
                }
            },
            else => return error.InvalidSessionIndex,
        }
    }
}

fn readIndexedSummary(
    alloc: Allocator,
    scanner: *std.json.Reader,
) !SessionSummary {
    var id: ?[]u8 = null;
    errdefer if (id) |value| alloc.free(value);
    var workspace_root: ?[]u8 = null;
    errdefer if (workspace_root) |value| alloc.free(value);
    var origin_workspace_root: ?[]u8 = null;
    errdefer if (origin_workspace_root) |value| alloc.free(value);
    var title: ?[]u8 = null;
    errdefer if (title) |value| alloc.free(value);
    var preview: ?[]u8 = null;
    errdefer if (preview) |value| alloc.free(value);
    var display_metadata_present: bool = false;
    var created_at_ms: ?i64 = null;
    var updated_at_ms: ?i64 = null;
    var conversation_language: ?session.ConversationLanguage = null;
    var history_len: ?usize = null;
    var has_managed_children: bool = false;

    while (true) {
        const token = try scanner.nextAlloc(alloc, .alloc_if_needed);
        switch (token) {
            .object_end => break,
            .string, .allocated_string => {
                const key = try jsonStringFromToken(token);
                defer key.deinit(alloc);
                if (std.mem.eql(u8, key.text, "id")) {
                    replaceIndexString(alloc, &id, try readIndexStringOwned(scanner, alloc));
                } else if (std.mem.eql(u8, key.text, "workspace_root")) {
                    replaceIndexString(alloc, &workspace_root, try readOptionalIndexString(scanner, alloc));
                } else if (std.mem.eql(u8, key.text, "origin_workspace_root")) {
                    replaceIndexString(alloc, &origin_workspace_root, try readOptionalIndexString(scanner, alloc));
                } else if (std.mem.eql(u8, key.text, "title")) {
                    replaceIndexString(alloc, &title, try readOptionalIndexString(scanner, alloc));
                } else if (std.mem.eql(u8, key.text, "preview")) {
                    replaceIndexString(alloc, &preview, try readOptionalIndexString(scanner, alloc));
                } else if (std.mem.eql(u8, key.text, "display_metadata_present")) {
                    display_metadata_present = try readJsonBool(scanner);
                } else if (std.mem.eql(u8, key.text, "created_at_ms")) {
                    created_at_ms = try readJsonI64(scanner, alloc);
                } else if (std.mem.eql(u8, key.text, "updated_at_ms")) {
                    updated_at_ms = try readJsonI64(scanner, alloc);
                } else if (std.mem.eql(u8, key.text, "conversation_language")) {
                    const language = try readJsonString(scanner, alloc);
                    defer language.deinit(alloc);
                    conversation_language = session.ConversationLanguage.fromSlice(language.text) catch
                        return error.InvalidSessionIndex;
                } else if (std.mem.eql(u8, key.text, "history_len")) {
                    history_len = try readJsonUsize(scanner, alloc);
                } else if (std.mem.eql(u8, key.text, "has_managed_children")) {
                    has_managed_children = try readJsonBool(scanner);
                } else {
                    try scanner.skipValue();
                }
            },
            else => {
                freeJsonToken(alloc, token);
                return error.InvalidSessionIndex;
            },
        }
    }

    const parsed_id = id orelse return error.InvalidSessionIndex;
    validateSessionId(parsed_id) catch return error.InvalidSessionIndex;
    const parsed_created_at_ms = created_at_ms orelse return error.InvalidSessionIndex;
    const parsed_updated_at_ms = updated_at_ms orelse return error.InvalidSessionIndex;
    const parsed_conversation_language = conversation_language orelse
        return error.InvalidSessionIndex;
    const parsed_history_len = history_len orelse return error.InvalidSessionIndex;
    const result: SessionSummary = .{
        .id = parsed_id,
        .workspace_root = workspace_root,
        .origin_workspace_root = origin_workspace_root,
        .title = title,
        .preview = preview,
        .display_metadata_present = display_metadata_present,
        .created_at_ms = parsed_created_at_ms,
        .updated_at_ms = parsed_updated_at_ms,
        .conversation_language = parsed_conversation_language,
        .history_len = parsed_history_len,
        .has_managed_children = has_managed_children,
    };
    return result;
}

fn replaceIndexString(
    alloc: Allocator,
    destination: *?[]u8,
    replacement: ?[]u8,
) void {
    if (destination.*) |value| alloc.free(value);
    destination.* = replacement;
}

fn readOptionalIndexString(
    scanner: *std.json.Reader,
    alloc: Allocator,
) !?[]u8 {
    const token = try scanner.nextAllocMax(alloc, .alloc_always, max_session_index_bytes);
    return switch (token) {
        .null => null,
        .allocated_string => |value| value,
        else => {
            freeJsonToken(alloc, token);
            return error.InvalidSessionIndex;
        },
    };
}

fn readJsonBool(scanner: anytype) !bool {
    return switch (try scanner.next()) {
        .true => true,
        .false => false,
        else => error.InvalidSessionIndex,
    };
}

fn readJsonI64(scanner: *std.json.Reader, alloc: Allocator) !i64 {
    const token = try scanner.nextAllocMax(alloc, .alloc_if_needed, 32);
    defer freeJsonToken(alloc, token);
    return switch (token) {
        .number, .allocated_number => |raw| std.fmt.parseInt(i64, raw, 10) catch error.InvalidSessionIndex,
        else => error.InvalidSessionIndex,
    };
}

fn readIndexStringOwned(scanner: *std.json.Reader, alloc: Allocator) ![]u8 {
    const token = try scanner.nextAllocMax(alloc, .alloc_always, max_session_index_bytes);
    return switch (token) {
        .allocated_string => |value| value,
        else => {
            freeJsonToken(alloc, token);
            return error.InvalidSessionIndex;
        },
    };
}

fn indexedSummaryMatches(
    summary: SessionSummary,
    options: SessionIndexPageOptions,
) bool {
    if (options.workspace_root) |workspace_root| {
        const indexed_workspace = summary.workspace_root orelse return false;
        if (!std.mem.eql(u8, indexed_workspace, workspace_root)) return false;
    }
    if (options.resumable_only and
        summary.history_len == 0 and
        !summary.has_managed_children)
    {
        return false;
    }
    if (options.active_id) |active_id| {
        if (std.mem.eql(u8, summary.id, active_id)) return false;
    }
    if (options.continuation) |continuation| {
        if (summary.updated_at_ms > continuation.updated_at_ms) return false;
        if (summary.updated_at_ms == continuation.updated_at_ms and
            std.mem.order(u8, summary.id, continuation.id) != .lt)
        {
            return false;
        }
    }
    return true;
}

pub fn readSessionIndex(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
) !std.ArrayList(SessionSummary) {
    const page = try readSessionIndexPage(alloc, sessions, .{
        .limit = std.math.maxInt(usize),
        .resumable_only = false,
    });
    return page.summaries;
}

/// Borrows the pinned snapshot. The caller owns every returned summary.
pub fn readPublicationSnapshot(
    alloc: Allocator,
    snapshot: publication.Snapshot,
    cancel_flag: cancellation.CancelFlag,
) !?std.ArrayList(SessionSummary) {
    try cancellation.check(cancel_flag);
    if (snapshot == .missing) return null;
    const parsed = parsePublicationSnapshot(alloc, snapshot, .{
        .limit = std.math.maxInt(usize),
        .resumable_only = false,
        .cancel_flag = cancel_flag,
    }, .{}) catch |err| switch (err) {
        error.LegacySessionIndex => return null,
        else => return err,
    };
    return parsed.page.summaries;
}

fn parsePublicationSnapshot(
    alloc: Allocator,
    snapshot: publication.Snapshot,
    options: SessionIndexPageOptions,
    controls: IndexReadControls,
) !ParsedSessionIndexPage {
    if (snapshot == .missing) return error.SessionIndexNotFound;
    if (snapshot.file.identity.size > max_session_index_bytes) return error.InvalidSessionIndex;
    var buffer: [cancellation.work_bytes]u8 = undefined;
    var file_reader = snapshot.file.handle.reader(io_mod.getIo(), &buffer);
    var limited = file_reader.interface.limited(.limited64(snapshot.file.identity.size), &.{});
    debug_trace.logf("session", "session index parse begin bytes={d}", .{snapshot.file.identity.size});
    return parseSessionIndexReader(alloc, &limited.interface, options, controls, .publication) catch |err| {
        if (err == error.Cancelled) debug_trace.logf("session", "session index parse cancelled", .{});
        return err;
    };
}

pub fn readSessionIndexPage(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    options: SessionIndexPageOptions,
) !ResumableSessionPage {
    return readSessionIndexPageControlled(alloc, sessions, options, .{});
}

fn readSessionIndexPageControlled(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    options: SessionIndexPageOptions,
    controls: IndexReadControls,
) !ResumableSessionPage {
    for (0..2) |attempt| {
        return readSessionIndexPageAttempt(alloc, sessions, options, controls) catch |err| {
            if (err == error.SessionIndexChanged and attempt == 0) continue;
            return err;
        };
    }
    return error.SessionIndexChanged;
}

fn readSessionIndexPageAttempt(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    options: SessionIndexPageOptions,
    controls: IndexReadControls,
) !ResumableSessionPage {
    try checkIndexReadCancellation(options);
    var snapshot = try publication.capture(sessions, .current);
    defer snapshot.deinit();
    var parsed = parsePublicationSnapshot(alloc, snapshot, options, controls) catch |err| switch (err) {
        error.LegacySessionIndex => return error.InvalidSessionIndex,
        else => return err,
    };
    errdefer parsed.page.deinit(alloc);
    try controls.boundary(.before_final_observation);
    try checkIndexReadCancellation(options);
    var current = try publication.capture(sessions, .current);
    defer current.deinit();
    if (!std.meta.eql(snapshot.identity(), current.identity())) return error.SessionIndexChanged;
    const generation = (try snapshotGeneration(current)) orelse return error.InvalidSessionIndex;
    if (!std.mem.eql(u8, &generation, &parsed.generation.?)) return error.SessionIndexChanged;
    const identity = current.file.identity;
    parsed.page.publication = .{
        .generation = generation,
        .inode = identity.inode,
        .size = identity.size,
        .mtime_ns = identity.mtime_ns,
        .ctime_ns = identity.ctime_ns,
    };
    return parsed.page;
}

fn snapshotGeneration(snapshot: publication.Snapshot) !?[session_index_generation_bytes]u8 {
    if (snapshot == .missing) return null;
    var prefix: [128]u8 = undefined;
    const count = try snapshot.file.handle.readPositionalAll(io_mod.getIo(), &prefix, 0);
    return sessionIndexGenerationFromPrefix(prefix[0..count]);
}

pub fn sessionIndexPublicationCurrent(
    sessions: *const io_mod.VerifiedDir,
    expected: SessionIndexPublication,
) !bool {
    const generation = expected.generation orelse return false;
    var current = publication.capture(sessions, .current) catch return false;
    defer current.deinit();
    if (current == .missing) return false;
    const identity = current.file.identity;
    if (identity.inode != expected.inode or identity.size != expected.size or
        identity.mtime_ns != expected.mtime_ns or identity.ctime_ns != expected.ctime_ns) return false;
    const actual_generation = (try snapshotGeneration(current)) orelse return false;
    return std.mem.eql(u8, &generation, &actual_generation);
}

/// Candidate metadata follows the same publication guard as picker pages;
/// callers still validate canonical managed-child control records.
pub fn readSessionIndexWorkspaceCandidates(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    workspace_root: []const u8,
    cancel_flag: cancellation.CancelFlag,
) !std.ArrayList(SessionSummary) {
    const page = try readSessionIndexPage(alloc, sessions, .{
        .workspace_root = workspace_root,
        .limit = std.math.maxInt(usize),
        .resumable_only = false,
        .cancel_flag = cancel_flag,
    });
    return page.summaries;
}

/// Streams a fixed window of the frozen ordinary-session candidate snapshot.
/// The returned IDs are candidates only; callers must re-read canonical
/// control records before projecting any edge.
pub fn readRelationshipMigrationCandidatePage(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    continuation: RelationshipMigrationCursor,
) !RelationshipMigrationCandidatePage {
    var file = try openVerifiedSessionIndexFile(
        sessions,
        relationship_migration_snapshot_file,
    );
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.size > max_session_index_bytes) return error.InvalidSessionIndex;
    const identity = RelationshipMigrationCursor{
        .inode = @intCast(stat.inode),
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
    };
    const same_identity = continuation.inode == identity.inode and
        continuation.size == identity.size and
        continuation.mtime_ns == identity.mtime_ns and
        continuation.offset <= identity.size;
    const start = if (same_identity) continuation.offset else 0;
    var page = RelationshipMigrationCandidatePage{
        .cursor = identity,
    };
    errdefer page.deinit(alloc);
    if (start == identity.size) {
        page.cursor.offset = start;
        return page;
    }

    var buffer: [relationship_migration_read_bytes]u8 = undefined;
    const count = try file.readPositionalAll(io_mod.getIo(), &buffer, start);
    if (count == 0) return error.InvalidSessionIndex;
    const bytes = buffer[0..count];
    if (start == 0 and
        !hasSupportedMigrationIndexPrefix(bytes))
    {
        return error.InvalidSessionIndex;
    }

    const id_prefix = "\"id\":\"";
    var scan_offset: usize = 0;
    var consumed: usize = 0;
    while (page.ids.items.len < relationship_migration_candidate_limit) {
        const relative = std.mem.find(
            u8,
            bytes[scan_offset..],
            id_prefix,
        ) orelse break;
        const id_start = scan_offset + relative + id_prefix.len;
        const quote = std.mem.findScalar(
            u8,
            bytes[id_start..],
            '"',
        ) orelse break;
        const id_end = id_start + quote;
        const raw_id = bytes[id_start..id_end];
        validateSessionId(raw_id) catch {
            scan_offset = id_end + 1;
            continue;
        };
        try page.ids.append(alloc, try alloc.dupe(u8, raw_id));
        consumed = id_end + 1;
        scan_offset = consumed;
    }

    const read_end = start + count;
    page.cursor.offset = if (page.ids.items.len ==
        relationship_migration_candidate_limit)
        start + consumed
    else if (read_end >= identity.size)
        identity.size
    else if (read_end > relationship_migration_overlap_bytes)
        read_end - relationship_migration_overlap_bytes
    else
        read_end;
    if (page.cursor.offset <= start and read_end > start) {
        page.cursor.offset = read_end;
    }
    page.has_more = page.cursor.offset < identity.size;
    return page;
}

pub fn refreshRelationshipMigrationSnapshot(
    alloc: Allocator,
    sessions: *io_mod.VerifiedDir,
) !void {
    var source = try openVerifiedSessionIndexFile(sessions, session_index_file);
    defer source.close(io_mod.getIo());
    const source_stat = try source.stat(io_mod.getIo());
    if (source_stat.size > max_session_index_bytes or
        source_stat.size < 2)
    {
        return error.InvalidSessionIndex;
    }
    var observed_prefix: [128]u8 = undefined;
    const prefix_len = try source.readPositionalAll(
        io_mod.getIo(),
        &observed_prefix,
        0,
    );
    if (!hasSupportedMigrationIndexPrefix(observed_prefix[0..prefix_len])) {
        return error.InvalidSessionIndex;
    }
    var suffix: [2]u8 = undefined;
    if (try source.readPositionalAll(
        io_mod.getIo(),
        &suffix,
        source_stat.size - suffix.len,
    ) != suffix.len or !std.mem.eql(u8, &suffix, "]}")) {
        return error.InvalidSessionIndex;
    }

    var random_bytes: [16]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
    const temp_name = try std.fmt.allocPrint(
        alloc,
        ".{s}.tmp.{s}",
        .{ relationship_migration_snapshot_file, random_hex },
    );
    defer alloc.free(temp_name);
    var temp_exists = false;
    defer if (temp_exists) {
        sessions.dir.deleteFile(io_mod.getIo(), temp_name) catch {};
    };
    var target = sessions.dir.createFile(io_mod.getIo(), temp_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    }) catch return error.InvalidSessionIndex;
    temp_exists = true;
    defer target.close(io_mod.getIo());
    target.setPermissions(
        io_mod.getIo(),
        private_file_permissions,
    ) catch return error.InvalidSessionIndex;
    const target_stat = target.stat(io_mod.getIo()) catch
        return error.InvalidSessionIndex;
    if (target_stat.kind != .file or
        target_stat.nlink != 1 or
        target_stat.permissions.toMode() & 0o777 != 0o600)
    {
        return error.InvalidSessionIndex;
    }

    var buffer: [relationship_migration_read_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < source_stat.size) {
        const remaining = source_stat.size - offset;
        const chunk_len: usize = @intCast(@min(remaining, buffer.len));
        const count = source.readPositionalAll(
            io_mod.getIo(),
            buffer[0..chunk_len],
            offset,
        ) catch return error.InvalidSessionIndex;
        if (count != chunk_len) return error.InvalidSessionIndex;
        target.writeStreamingAll(
            io_mod.getIo(),
            buffer[0..count],
        ) catch return error.InvalidSessionIndex;
        offset += count;
    }
    target.sync(io_mod.getIo()) catch return error.InvalidSessionIndex;
    var existing = openVerifiedSessionIndexFile(
        sessions,
        relationship_migration_snapshot_file,
    ) catch |err| switch (err) {
        error.SessionIndexNotFound => null,
        else => return err,
    };
    if (existing) |*file| file.close(io_mod.getIo());
    sessions.dir.rename(
        temp_name,
        sessions.dir,
        relationship_migration_snapshot_file,
        io_mod.getIo(),
    ) catch return error.InvalidSessionIndex;
    temp_exists = false;
    var published = try openVerifiedSessionIndexFile(
        sessions,
        relationship_migration_snapshot_file,
    );
    published.close(io_mod.getIo());
    try io_mod.syncVerifiedDir(sessions.dir);
}

fn hasSupportedMigrationIndexPrefix(bytes: []const u8) bool {
    return std.mem.startsWith(
        u8,
        bytes,
        "{\"schema_version\":2,\"sessions\":[",
    ) or std.mem.startsWith(
        u8,
        bytes,
        "{\"schema_version\":3,\"sessions\":[",
    ) or generatedSessionArrayOffset(bytes) != null;
}

fn generatedSessionArrayOffset(bytes: []const u8) ?usize {
    const suffix = "\",\"sessions\":[";
    const hex_len = session_index_generation_bytes * 2;
    for ([_][]const u8{
        "{\"schema_version\":3,\"generation\":\"",
        "{\"schema_version\":4,\"generation\":\"",
    }) |prefix| {
        if (!std.mem.startsWith(u8, bytes, prefix)) continue;
        if (bytes.len < prefix.len + hex_len + suffix.len or
            !std.mem.eql(u8, bytes[prefix.len + hex_len ..][0..suffix.len], suffix)) return null;
        _ = parseIndexGeneration(bytes[prefix.len..][0..hex_len]) catch return null;
        return prefix.len + hex_len + suffix.len;
    }
    return null;
}

fn sessionIndexGenerationFromPrefix(
    bytes: []const u8,
) ?[session_index_generation_bytes]u8 {
    const prefix = "{\"schema_version\":4,\"generation\":\"";
    const hex_len = session_index_generation_bytes * 2;
    if (bytes.len < prefix.len + hex_len or
        !std.mem.startsWith(u8, bytes, prefix))
    {
        return null;
    }
    var generation: [session_index_generation_bytes]u8 = undefined;
    const raw = bytes[prefix.len .. prefix.len + hex_len];
    _ = std.fmt.hexToBytes(&generation, raw) catch return null;
    const canonical = std.fmt.bytesToHex(generation, .lower);
    if (!std.mem.eql(u8, &canonical, raw)) return null;
    return generation;
}

pub fn writeSessionIndex(
    alloc: Allocator,
    sessions: *io_mod.VerifiedDir,
    summaries: []const SessionSummary,
) !void {
    var guard = try io_mod.acquireTimedAdvisoryLock(sessions, publication.lock_file, 0);
    guard.release();
    var snapshot = try publication.capture(sessions, .rebuild);
    defer snapshot.deinit();
    var prepared = try preparePublicationIndex(alloc, sessions, summaries, null);
    defer prepared.deinit(sessions);
    var records: publication.Records = .{};
    try prepared.publish(sessions, snapshot, &records, null);
}

pub fn preparePublicationIndex(
    alloc: Allocator,
    sessions: *const io_mod.VerifiedDir,
    summaries: []const SessionSummary,
    cancel_flag: cancellation.CancelFlag,
) !publication.PreparedIndex {
    try cancellation.check(cancel_flag);
    var generation: [session_index_generation_bytes]u8 = undefined;
    io_mod.getIo().random(&generation);
    var count_buffer: [1024]u8 = undefined;
    var counter: std.Io.Writer.Discarding = .init(&count_buffer);
    try writeSessionIndexDocument(&counter.writer, summaries, generation, cancel_flag);
    const size = counter.fullCount();
    if (size > max_session_index_bytes) return error.InvalidSessionIndex;
    try cancellation.check(cancel_flag);
    const bytes = try alloc.alloc(u8, @intCast(size));
    defer alloc.free(bytes);
    var writer: std.Io.Writer = .fixed(bytes);
    try writeSessionIndexDocument(&writer, summaries, generation, cancel_flag);
    return publication.PreparedIndex.init(sessions, writer.buffered(), cancel_flag);
}

fn writeSessionIndexDocument(
    writer: *std.Io.Writer,
    summaries: []const SessionSummary,
    generation: [session_index_generation_bytes]u8,
    cancel_flag: cancellation.CancelFlag,
) !void {
    try cancellation.check(cancel_flag);
    const generation_hex = std.fmt.bytesToHex(generation, .lower);
    try writer.print(
        "{{\"schema_version\":{d},\"generation\":\"{s}\",\"sessions\":[",
        .{ session_index_schema_version, generation_hex },
    );
    for (summaries, 0..) |summary, i| {
        try cancellation.check(cancel_flag);
        if (i > 0) try writer.writeByte(',');
        try writeIndexedSummaryJson(writer, summary, cancel_flag);
    }
    try writer.writeAll("]}");
}

fn openVerifiedSessionIndexFile(
    sessions: *const io_mod.VerifiedDir,
    name: []const u8,
) !std.Io.File {
    var file = sessions.dir.openFile(io_mod.getIo(), name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SessionIndexNotFound,
        error.NotDir, error.SymLinkLoop, error.IsDir => return error.InvalidSessionIndex,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600) {
        return error.InvalidSessionIndex;
    }
    return file;
}

fn writeIndexedSummaryJson(writer: *std.Io.Writer, summary: SessionSummary, cancel_flag: cancellation.CancelFlag) !void {
    try writer.writeAll("{\"id\":");
    try cancellation.writeJsonString(writer, summary.id, cancel_flag);
    try writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{ summary.created_at_ms, summary.updated_at_ms });
    try writer.writeAll(",\"workspace_root\":");
    if (summary.workspace_root) |workspace_root| {
        try cancellation.writeJsonString(writer, workspace_root, cancel_flag);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"origin_workspace_root\":");
    if (summary.origin_workspace_root) |origin_workspace_root| {
        try cancellation.writeJsonString(writer, origin_workspace_root, cancel_flag);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"conversation_language\":");
    try cancellation.writeJsonString(writer, summary.conversation_language.view(), cancel_flag);
    try writer.print(",\"history_len\":{d},\"has_managed_children\":{s},\"display_metadata_present\":{s},\"title\":", .{
        summary.history_len,
        if (summary.has_managed_children) "true" else "false",
        if (summary.display_metadata_present) "true" else "false",
    });
    if (summary.title) |title| {
        try cancellation.writeJsonString(writer, title, cancel_flag);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"preview\":");
    if (summary.preview) |preview| {
        try cancellation.writeJsonString(writer, preview, cancel_flag);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

/// Frees every summary and the backing list.
pub fn freeSummaries(alloc: Allocator, sessions: *std.ArrayList(SessionSummary)) void {
    for (sessions.items) |*summary| summary.deinit(alloc);
    sessions.deinit(alloc);
}

pub fn cloneSessionSummary(alloc: Allocator, source: SessionSummary) !SessionSummary {
    const id = try alloc.dupe(u8, source.id);
    errdefer alloc.free(id);
    const workspace_root = if (source.workspace_root) |value| try alloc.dupe(u8, value) else null;
    errdefer if (workspace_root) |value| alloc.free(value);
    const origin_workspace_root = if (source.origin_workspace_root) |value| try alloc.dupe(u8, value) else null;
    errdefer if (origin_workspace_root) |value| alloc.free(value);
    const title = if (source.title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (title) |value| alloc.free(value);
    const preview = if (source.preview) |value| try alloc.dupe(u8, value) else null;
    errdefer if (preview) |value| alloc.free(value);
    return .{
        .id = id,
        .workspace_root = workspace_root,
        .origin_workspace_root = origin_workspace_root,
        .title = title,
        .preview = preview,
        .display_metadata_present = source.display_metadata_present,
        .created_at_ms = source.created_at_ms,
        .updated_at_ms = source.updated_at_ms,
        .conversation_language = source.conversation_language,
        .history_len = source.history_len,
        .has_managed_children = source.has_managed_children,
    };
}

/// Display metadata freezes at first derivation: when the indexed row for
/// the same session already carries a title, the replacement keeps it
/// instead of a value re-derived from possibly compacted history.
pub fn preserveIndexedDisplayMetadata(
    alloc: Allocator,
    index: []const SessionSummary,
    replacement: *SessionSummary,
) !void {
    for (index) |summary| {
        if (!std.mem.eql(u8, summary.id, replacement.id)) continue;
        if (!summary.display_metadata_present) return;
        const frozen_title = summary.title orelse return;
        const title = try alloc.dupe(u8, frozen_title);
        errdefer alloc.free(title);
        const preview = if (summary.preview) |value| try alloc.dupe(u8, value) else null;
        if (replacement.title) |value| alloc.free(value);
        if (replacement.preview) |value| alloc.free(value);
        replacement.title = title;
        replacement.preview = preview;
        replacement.display_metadata_present = true;
        return;
    }
}

pub fn replaceIndexedSummary(
    alloc: Allocator,
    index: *std.ArrayList(SessionSummary),
    replacement: *SessionSummary,
) !void {
    for (index.items) |*summary| {
        if (!std.mem.eql(u8, summary.id, replacement.id)) continue;
        summary.deinit(alloc);
        summary.* = replacement.*;
        replacement.* = undefined;
        sortSummariesNewestFirst(index.items);
        return;
    }
    try index.append(alloc, replacement.*);
    replacement.* = undefined;
    sortSummariesNewestFirst(index.items);
}

pub fn resumablePageFromSummaries(
    alloc: Allocator,
    summaries: []const SessionSummary,
    workspace_root: ?[]const u8,
    active_id: ?[]const u8,
    continuation: ?ResumableSessionContinuation,
    limit: usize,
) !ResumableSessionPage {
    const page_limit = @max(limit, 1);
    var page: ResumableSessionPage = .{};
    errdefer page.deinit(alloc);
    for (summaries) |summary| {
        if (workspace_root) |root| {
            const summary_workspace = summary.workspace_root orelse continue;
            if (!std.mem.eql(u8, summary_workspace, root)) continue;
        }
        if (summary.history_len == 0 and !summary.has_managed_children) continue;
        if (active_id) |id| {
            if (std.mem.eql(u8, summary.id, id)) continue;
        }
        if (continuation) |position| {
            if (!summaryFollowsContinuation(summary, position)) continue;
        }
        if (page.summaries.items.len >= page_limit) {
            page.has_more = true;
            break;
        }

        var copied = try cloneSessionSummary(alloc, summary);
        page.summaries.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    return page;
}

pub fn sessionListPageFromSummaries(
    alloc: Allocator,
    summaries: []const SessionSummary,
    workspace_root: ?[]const u8,
    continuation: ?ResumableSessionContinuation,
    limit: usize,
) !types.SessionListPage {
    var page: types.SessionListPage = .{};
    errdefer page.deinit(alloc);
    for (summaries) |summary| {
        if (workspace_root) |root| {
            const summary_workspace = summary.workspace_root orelse continue;
            if (!std.mem.eql(u8, summary_workspace, root)) continue;
        }
        if (continuation) |position| {
            if (!summaryFollowsContinuation(summary, position)) continue;
        }
        if (page.summaries.items.len == limit) {
            page.has_more = true;
            break;
        }

        var copied = try cloneSessionSummary(alloc, summary);
        page.summaries.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    return page;
}

fn summaryFollowsContinuation(
    summary: SessionSummary,
    continuation: ResumableSessionContinuation,
) bool {
    if (summary.updated_at_ms != continuation.updated_at_ms) {
        return summary.updated_at_ms < continuation.updated_at_ms;
    }
    return std.mem.order(u8, summary.id, continuation.id) == .lt;
}

/// Sorts summaries by descending `updated_at_ms`, ties broken by descending id.
pub fn sortSummariesNewestFirst(items: []SessionSummary) void {
    sortSummariesNewestFirstInterruptible(items, null) catch unreachable;
}

pub fn sortSummariesNewestFirstInterruptible(items: []SessionSummary, cancel_flag: cancellation.CancelFlag) !void {
    try sort_utils.sortInterruptible(SessionSummary, items, {}, lessSummaryNewerFirst, cancel_flag);
}

fn lessSummaryNewerFirst(_: void, a: SessionSummary, b: SessionSummary) bool {
    if (a.updated_at_ms != b.updated_at_ms) return a.updated_at_ms > b.updated_at_ms;
    return std.mem.order(u8, a.id, b.id) == .gt;
}

fn writeTestFile(path: []const u8, text: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), text);
}

test "session list sort is stable and O(n log n)" {
    const alloc = std.testing.allocator;
    var summaries: [500]SessionSummary = undefined;
    for (&summaries, 0..) |*summary, i| {
        summary.* = .{
            .id = try std.fmt.allocPrint(alloc, "session-{d:0>3}", .{i}),
            .created_at_ms = @intCast(i),
            .updated_at_ms = if (i % 2 == 0) 200 else 100,
            .conversation_language = session.ConversationLanguage.default(),
            .history_len = i,
        };
    }
    defer for (&summaries) |*summary| summary.deinit(alloc);

    sortSummariesNewestFirst(&summaries);

    for (summaries[1..], 1..) |summary, i| {
        try std.testing.expect(summaries[i - 1].updated_at_ms >= summary.updated_at_ms);
    }
}

test "session index rejects unsafe ids" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidSessionIndex,
        parseSessionIndex(
            alloc,
            "{\"schema_version\":3,\"sessions\":[{\"id\":\"../outside\",\"workspace_root\":\"/tmp/ws\",\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\",\"history_len\":0}]}",
        ),
    );
}

test "session index rejects v2 so resumability metadata is rebuilt" {
    try std.testing.expectError(
        error.InvalidSessionIndex,
        parseSessionIndex(
            std.testing.allocator,
            "{\"schema_version\":2,\"sessions\":[]}",
        ),
    );
}

test "session index parses old rows as metadata missing" {
    const alloc = std.testing.allocator;
    var summaries = try parseSessionIndex(
        alloc,
        "{\"schema_version\":3,\"sessions\":[{\"id\":\"old-session\",\"workspace_root\":\"/tmp/ws\",\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\",\"history_len\":1}]}",
    );
    defer freeSummaries(alloc, &summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    try std.testing.expect(!summaries.items[0].display_metadata_present);
    try std.testing.expect(summaries.items[0].title == null);
    try std.testing.expect(summaries.items[0].preview == null);
    try std.testing.expect(summaries.items[0].origin_workspace_root == null);
}

test "workspace session index materializes only matching canonical rows" {
    const alloc = std.testing.allocator;
    var summaries = try parseSessionIndexForWorkspace(
        alloc,
        "{\"schema_version\":3,\"sessions\":[" ++
            "{\"id\":\"current\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":0,\"title\":\"brace } inside string\"}," ++
            "{\"id\":\"other\",\"created_at_ms\":1,\"updated_at_ms\":3,\"workspace_root\":\"/tmp/other\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":0,\"title\":\"\\\"workspace_root\\\":\\\"/tmp/ws\\\"\"}" ++
            "]}",
        "/tmp/ws",
    );
    defer freeSummaries(alloc, &summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    try std.testing.expectEqualStrings("current", summaries.items[0].id);
}

test "workspace session index preserves noncanonical cache fallback" {
    const alloc = std.testing.allocator;
    var summaries = try parseSessionIndexForWorkspace(
        alloc,
        "{ \"schema_version\": 3, \"sessions\": [{\"id\":\"current\",\"workspace_root\":\"/tmp/ws\",\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\",\"history_len\":0}] }",
        "/tmp/ws",
    );
    defer freeSummaries(alloc, &summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    try std.testing.expectEqualStrings("current", summaries.items[0].id);
}

test "session index parses and writes display metadata fields" {
    const alloc = std.testing.allocator;
    var summaries = try parseSessionIndex(
        alloc,
        "{\"schema_version\":3,\"sessions\":[{\"id\":\"new-session\",\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":\"/tmp/origin\",\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\",\"history_len\":2,\"display_metadata_present\":true,\"title\":\"First prompt title\",\"preview\":\"First prompt title\\nsecond line\"}]}",
    );
    defer freeSummaries(alloc, &summaries);

    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    try std.testing.expect(summaries.items[0].display_metadata_present);
    try std.testing.expectEqualStrings("First prompt title", summaries.items[0].title.?);
    try std.testing.expectEqualStrings("First prompt title\nsecond line", summaries.items[0].preview.?);
    try std.testing.expectEqualStrings("/tmp/origin", summaries.items[0].origin_workspace_root.?);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeIndexedSummaryJson(&out.writer, summaries.items[0], null);
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "\"display_metadata_present\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "\"title\":\"First prompt title\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "\"preview\":\"First prompt title\\nsecond line\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.written(), 1, "\"origin_workspace_root\":\"/tmp/origin\""));
}

test "bounded resumable index page preserves filters and newest-first order" {
    const alloc = std.testing.allocator;
    const index =
        "{\"schema_version\":3,\"sessions\":[" ++
        "{\"id\":\"older\",\"created_at_ms\":1,\"updated_at_ms\":10,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Older\",\"preview\":\"Older\"}," ++
        "{\"id\":\"other-workspace\",\"created_at_ms\":1,\"updated_at_ms\":100,\"workspace_root\":\"/tmp/other\",\"origin_workspace_root\":null,\"conversation_language\":\"ja\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Other\",\"preview\":\"Other\"}," ++
        "{\"id\":\"empty\",\"created_at_ms\":1,\"updated_at_ms\":90,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":0,\"display_metadata_present\":true,\"title\":\"Empty\",\"preview\":\"Empty\"}," ++
        "{\"id\":\"newest\",\"created_at_ms\":1,\"updated_at_ms\":40,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"fr\",\"history_len\":2,\"display_metadata_present\":true,\"title\":\"Newest 🚀\",\"preview\":\"مرحبا\"}," ++
        "{\"id\":\"active\",\"created_at_ms\":1,\"updated_at_ms\":80,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Active\",\"preview\":\"Active\"}," ++
        "{\"id\":\"middle-b\",\"created_at_ms\":1,\"updated_at_ms\":30,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Middle B\",\"preview\":\"Middle B\"}," ++
        "{\"id\":\"middle-a\",\"created_at_ms\":1,\"updated_at_ms\":30,\"workspace_root\":\"/tmp/ws\",\"origin_workspace_root\":null,\"conversation_language\":\"en\",\"history_len\":1,\"display_metadata_present\":true,\"title\":\"Middle A\",\"preview\":\"Middle A\"}" ++
        "]}";

    var first = try parseSessionIndexPage(alloc, index, .{
        .workspace_root = "/tmp/ws",
        .active_id = "active",
        .limit = 2,
        .resumable_only = true,
    });
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), first.summaries.items.len);
    try std.testing.expect(first.has_more);
    try std.testing.expectEqualStrings("newest", first.summaries.items[0].id);
    try std.testing.expectEqualStrings("middle-b", first.summaries.items[1].id);
    try std.testing.expectEqualStrings("Newest 🚀", first.summaries.items[0].title.?);
    try std.testing.expectEqualStrings("مرحبا", first.summaries.items[0].preview.?);

    var second = try parseSessionIndexPage(alloc, index, .{
        .workspace_root = "/tmp/ws",
        .active_id = "active",
        .continuation = .{
            .updated_at_ms = first.summaries.items[1].updated_at_ms,
            .id = first.summaries.items[1].id,
        },
        .limit = 2,
        .resumable_only = true,
    });
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), second.summaries.items.len);
    try std.testing.expect(!second.has_more);
    try std.testing.expectEqualStrings("middle-a", second.summaries.items[0].id);
    try std.testing.expectEqualStrings("older", second.summaries.items[1].id);
}

test "session index read rejects publication between observations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "sessions", private_dir_permissions);
    var dir = try tmp.dir.openDir(std.testing.io, "sessions", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var sessions = io_mod.VerifiedDir{ .dir = dir };
    const initial = [_]SessionSummary{.{
        .id = @constCast("initial-session"),
        .workspace_root = @constCast("/tmp/ws"),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .history_len = 1,
    }};
    const replacement = [_]SessionSummary{.{
        .id = @constCast("replacement-session"),
        .workspace_root = @constCast("/tmp/ws"),
        .created_at_ms = 2,
        .updated_at_ms = 2,
        .conversation_language = .literal("en"),
        .history_len = 1,
    }};
    try writeSessionIndex(alloc, &sessions, &initial);
    var published = try readSessionIndexPage(
        alloc,
        &sessions,
        .{ .limit = 10, .resumable_only = true },
    );
    defer published.deinit(alloc);
    try std.testing.expect(published.publication.?.generation != null);

    const Publisher = struct {
        sessions: *io_mod.VerifiedDir,
        replacement: []const SessionSummary,

        fn hit(raw: ?*anyopaque, point: IndexReadBoundary) !void {
            if (point != .before_final_observation) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try writeSessionIndex(
                std.testing.allocator,
                self.sessions,
                self.replacement,
            );
        }
    };
    var publisher = Publisher{
        .sessions = &sessions,
        .replacement = &replacement,
    };
    try std.testing.expectError(
        error.SessionIndexChanged,
        readSessionIndexPageControlled(
            alloc,
            &sessions,
            .{ .limit = 10, .resumable_only = true },
            .{ .context = &publisher, .boundary_fn = Publisher.hit },
        ),
    );
}

test "schema three index is never accepted as a current publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions: io_mod.VerifiedDir = .{ .dir = tmp.dir };
    var guard = try io_mod.acquireTimedAdvisoryLock(&sessions, "latest.lock", 0);
    guard.release();
    try io_mod.durableReplaceVerified(alloc, &sessions, session_index_file, "{\"schema_version\":3,\"generation\":\"00000000000000000000000000000000\",\"sessions\":[]}");
    try std.testing.expectError(error.InvalidSessionIndex, readSessionIndexPage(alloc, &sessions, .{
        .limit = 1,
        .resumable_only = false,
    }));
}

test "session index refuses invalidation published after the first observation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions: io_mod.VerifiedDir = .{ .dir = tmp.dir };
    try writeSessionIndex(alloc, &sessions, &.{});
    const Writer = struct {
        fn hit(raw: ?*anyopaque, point: IndexReadBoundary) !void {
            if (point != .before_final_observation) return;
            const directory: *io_mod.VerifiedDir = @ptrCast(@alignCast(raw.?));
            var invalidation = try publication.Invalidation.begin(directory, "concurrent-session", null);
            invalidation.release();
        }
    };
    try std.testing.expectError(error.SessionIndexChanged, readSessionIndexPageControlled(alloc, &sessions, .{
        .limit = 1,
        .resumable_only = false,
    }, .{ .context = &sessions, .boundary_fn = Writer.hit }));
}

test "session index parsing observes cancellation after work begins" {
    const alloc = std.testing.allocator;
    const index =
        "{\"schema_version\":3,\"sessions\":[" ++
        "{\"id\":\"first\",\"created_at_ms\":1,\"updated_at_ms\":2,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":1}," ++
        "{\"id\":\"second\",\"created_at_ms\":1,\"updated_at_ms\":1,\"workspace_root\":\"/tmp/ws\",\"conversation_language\":\"en\",\"history_len\":1}" ++
        "]}";
    var cancelled = std.atomic.Value(bool).init(false);
    const Canceller = struct {
        cancelled: *std.atomic.Value(bool),
        summaries: usize = 0,

        fn hit(raw: ?*anyopaque, point: IndexReadBoundary) !void {
            if (point != .after_summary) return;
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.summaries += 1;
            if (self.summaries == 1) self.cancelled.store(true, .release);
        }
    };
    var canceller = Canceller{ .cancelled = &cancelled };
    try std.testing.expectError(
        error.Cancelled,
        parseSessionIndexPageControlled(
            alloc,
            index,
            .{
                .workspace_root = "/tmp/ws",
                .limit = 10,
                .resumable_only = true,
                .cancel_flag = &cancelled,
            },
            .{ .context = &canceller, .boundary_fn = Canceller.hit },
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), canceller.summaries);
}

test "session index cancellation stops a token after its allocation begins" {
    const Probe = struct {
        backing: Allocator,
        cancelled: std.atomic.Value(bool) = .init(false),
        reached: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),
        allocations_after_cancel: usize = 0,

        fn allocator(self: *@This()) Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
        }

        fn observe(self: *@This(), size: usize) void {
            if (size < 64 * 1024) return;
            if (!self.reached.load(.acquire)) {
                self.reached.store(true, .release);
                while (!self.cancelled.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
            } else if (self.cancelled.load(.acquire)) {
                self.allocations_after_cancel += 1;
            }
        }

        fn allocate(raw: *anyopaque, size: usize, alignment: std.mem.Alignment, caller: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const result = self.backing.rawAlloc(size, alignment, caller);
            if (result != null) self.observe(size);
            return result;
        }

        fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, size: usize, caller: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const result = self.backing.rawResize(memory, alignment, size, caller);
            if (result) self.observe(size);
            return result;
        }

        fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, size: usize, caller: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const result = self.backing.rawRemap(memory, alignment, size, caller);
            if (result != null) self.observe(size);
            return result;
        }

        fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, caller: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.backing.rawFree(memory, alignment, caller);
        }

        fn cancel(self: *@This()) void {
            while (!self.reached.load(.acquire) and !self.finished.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
            self.cancelled.store(true, .release);
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions: io_mod.VerifiedDir = .{ .dir = tmp.dir };
    const title = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(title);
    @memset(title, '\n');
    try writeSessionIndex(alloc, &sessions, &.{.{
        .id = @constCast("large-token"),
        .title = title,
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = .literal("en"),
        .history_len = 1,
    }});
    var file = try openVerifiedSessionIndexFile(&sessions, session_index_file);
    defer file.close(io_mod.getIo());
    const before = try file.stat(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_session_index_bytes);
    defer alloc.free(bytes);
    var probe: Probe = .{ .backing = alloc };
    const thread = try std.Thread.spawn(.{}, Probe.cancel, .{&probe});
    defer thread.join();
    defer probe.finished.store(true, .release);
    try std.testing.expectError(error.Cancelled, parseSessionIndexPage(probe.allocator(), bytes, .{
        .limit = 1,
        .resumable_only = false,
        .cancel_flag = &probe.cancelled,
    }));
    try std.testing.expect(probe.reached.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), probe.allocations_after_cancel);
    const after = try file.stat(io_mod.getIo());
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectEqual(before.mtime, after.mtime);
}

test "streaming index keeps retained strings and split numeric tokens" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"schema_version\":3,\"sessions\":[{\"id\":\"retained\",\"title\":\"saved title\",\"preview\":\"saved preview\",\"workspace_root\":\"/tmp/workspace\",\"created_at_ms\":");
    try out.writer.splatByteAll(' ', cancellation.work_bytes - out.written().len - 3);
    try out.writer.writeAll("123456789012345678,\"updated_at_ms\":9,\"conversation_language\":\"en\",\"history_len\":12,\"unknown\":\"");
    try out.writer.splatByteAll('x', 3 * cancellation.work_bytes);
    try out.writer.writeAll("\"}]}");
    var page = try parseSessionIndexPage(alloc, out.written(), .{ .limit = 1, .resumable_only = true });
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    const row = page.summaries.items[0];
    try std.testing.expectEqualStrings("retained", row.id);
    try std.testing.expectEqualStrings("saved title", row.title.?);
    try std.testing.expectEqualStrings("saved preview", row.preview.?);
    try std.testing.expectEqualStrings("/tmp/workspace", row.workspace_root.?);
    try std.testing.expectEqual(@as(i64, 123456789012345678), row.created_at_ms);
    try std.testing.expectEqual(@as(usize, 12), row.history_len);
}

test "publication index rejects oversized output before allocating it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions: io_mod.VerifiedDir = .{ .dir = tmp.dir };
    const title = try alloc.alloc(u8, 3 * 1024 * 1024);
    defer alloc.free(title);
    @memset(title, 0);
    const rows = [_]SessionSummary{.{
        .id = @constCast("oversized"),
        .title = title,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .history_len = 1,
    }};
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(error.InvalidSessionIndex, preparePublicationIndex(failing.allocator(), &sessions, &rows, null));
    try std.testing.expect(!failing.has_induced_failure);
}

test "relationship migration freezes current indexes and retains legacy header support" {
    try std.testing.expect(hasSupportedMigrationIndexPrefix("{\"schema_version\":3,\"generation\":\"00000000000000000000000000000000\",\"sessions\":[]}"));
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions: io_mod.VerifiedDir = .{ .dir = tmp.dir };
    try writeSessionIndex(alloc, &sessions, &.{.{
        .id = @constCast("ordinary-session"),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .history_len = 1,
    }});
    try refreshRelationshipMigrationSnapshot(alloc, &sessions);
    var page = try readRelationshipMigrationCandidatePage(alloc, &sessions, .{});
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.ids.items.len);
    try std.testing.expectEqualStrings("ordinary-session", page.ids.items[0]);
}

test "publication snapshots stay pinned while current candidates reject pending work" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions: io_mod.VerifiedDir = .{ .dir = tmp.dir };
    try writeSessionIndex(alloc, &sessions, &.{.{
        .id = @constCast("pinned-session"),
        .workspace_root = @constCast("/tmp/ws"),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .history_len = 1,
    }});
    var snapshot = try publication.capture(&sessions, .current);
    defer snapshot.deinit();
    for (0..2) |_| {
        var rows = (try readPublicationSnapshot(alloc, snapshot, null)).?;
        defer freeSummaries(alloc, &rows);
        try std.testing.expectEqualStrings("pinned-session", rows.items[0].id);
    }
    try io_mod.durableReplaceVerified(alloc, &sessions, "index.pending", "pending\n");
    var page = try readSessionIndexPage(alloc, &sessions, .{ .limit = 1, .resumable_only = true });
    defer page.deinit(alloc);
    try std.testing.expect(try sessionIndexPublicationCurrent(&sessions, page.publication.?));
    var invalidation = try publication.Invalidation.begin(&sessions, "another-session", null);
    defer invalidation.release();
    try std.testing.expect(!try sessionIndexPublicationCurrent(&sessions, page.publication.?));
    try std.testing.expectError(error.SessionIndexChanged, readSessionIndexWorkspaceCandidates(alloc, &sessions, "/tmp/ws", null));
    var pinned = (try readPublicationSnapshot(alloc, snapshot, null)).?;
    defer freeSummaries(alloc, &pinned);
    try std.testing.expectEqualStrings("pinned-session", pinned.items[0].id);
    const legacy_marker = try sessions.dir.readFileAlloc(io_mod.getIo(), "index.pending", alloc, .limited(16));
    defer alloc.free(legacy_marker);
    try std.testing.expectEqualStrings("pending\n", legacy_marker);
}

test "streaming index parsing releases partial rows on allocation failure" {
    const Probe = struct {
        fn run(alloc: Allocator) !void {
            var rows = try parseSessionIndex(alloc, "{\"schema_version\":3,\"sessions\":[{\"id\":\"one\",\"workspace_root\":\"/tmp/ws\",\"title\":\"line\\nnext\",\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\",\"history_len\":1},{\"id\":\"two\",\"created_at_ms\":1,\"updated_at_ms\":1,\"conversation_language\":\"en\",\"history_len\":1}]}");
            defer freeSummaries(alloc, &rows);
            try std.testing.expectEqual(@as(usize, 2), rows.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "index parser rejects a missing unknown-field value" {
    try std.testing.expectError(error.InvalidSessionIndex, parseSessionIndexPage(std.testing.allocator, "{\"schema_version\":3,\"unknown\":}", .{ .limit = 1, .resumable_only = false }));
}

test "managed child ownership keeps a zero-turn session resumable" {
    const alloc = std.testing.allocator;
    const summaries = [_]SessionSummary{
        .{
            .id = @constCast("ordinary-empty"),
            .workspace_root = @constCast("/tmp/ws"),
            .created_at_ms = 1,
            .updated_at_ms = 3,
            .conversation_language = session.ConversationLanguage.literal("en"),
            .history_len = 0,
        },
        .{
            .id = @constCast("managed-parent"),
            .workspace_root = @constCast("/tmp/ws"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = session.ConversationLanguage.literal("en"),
            .history_len = 0,
            .has_managed_children = true,
        },
    };

    var page = try resumablePageFromSummaries(
        alloc,
        &summaries,
        "/tmp/ws",
        null,
        null,
        10,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), page.summaries.items.len);
    try std.testing.expectEqualStrings("managed-parent", page.summaries.items[0].id);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeIndexedSummaryJson(&out.writer, summaries[1], null);
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        out.written(),
        1,
        "\"has_managed_children\":true",
    ));
}

test "session summary clone owns display metadata strings" {
    const alloc = std.testing.allocator;
    var source = SessionSummary{
        .id = try alloc.dupe(u8, "clone-session"),
        .workspace_root = try alloc.dupe(u8, "/tmp/ws"),
        .origin_workspace_root = try alloc.dupe(u8, "/tmp/origin"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 3,
        .display_metadata_present = true,
        .title = try alloc.dupe(u8, "Clone title"),
        .preview = try alloc.dupe(u8, "Clone preview"),
    };
    defer source.deinit(alloc);

    var cloned = try cloneSessionSummary(alloc, source);
    defer cloned.deinit(alloc);

    try std.testing.expect(cloned.title.?.ptr != source.title.?.ptr);
    try std.testing.expect(cloned.preview.?.ptr != source.preview.?.ptr);
    try std.testing.expectEqualStrings("Clone title", cloned.title.?);
    try std.testing.expectEqualStrings("Clone preview", cloned.preview.?);
}

test "replaced index summary keeps the frozen display metadata" {
    const alloc = std.testing.allocator;
    var indexed = SessionSummary{
        .id = try alloc.dupe(u8, "frozen-session"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 3,
        .display_metadata_present = true,
        .title = try alloc.dupe(u8, "Frozen title"),
        .preview = try alloc.dupe(u8, "Frozen preview"),
    };
    defer indexed.deinit(alloc);

    var replacement = SessionSummary{
        .id = try alloc.dupe(u8, "frozen-session"),
        .created_at_ms = 1,
        .updated_at_ms = 9,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 1,
        .display_metadata_present = true,
        .title = try alloc.dupe(u8, "Rederived title"),
        .preview = null,
    };
    defer replacement.deinit(alloc);

    try preserveIndexedDisplayMetadata(alloc, &.{indexed}, &replacement);

    try std.testing.expectEqualStrings("Frozen title", replacement.title.?);
    try std.testing.expectEqualStrings("Frozen preview", replacement.preview.?);
    try std.testing.expect(replacement.display_metadata_present);
    try std.testing.expectEqual(@as(i64, 9), replacement.updated_at_ms);
}

test "replaced index summary keeps fresh metadata over a degenerate indexed row" {
    const alloc = std.testing.allocator;
    var indexed = SessionSummary{
        .id = try alloc.dupe(u8, "degenerate-session"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 1,
        .display_metadata_present = true,
        .title = null,
        .preview = try alloc.dupe(u8, "Stale preview"),
    };
    defer indexed.deinit(alloc);

    var replacement = SessionSummary{
        .id = try alloc.dupe(u8, "degenerate-session"),
        .created_at_ms = 1,
        .updated_at_ms = 9,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 1,
        .display_metadata_present = true,
        .title = try alloc.dupe(u8, "Fresh title"),
        .preview = try alloc.dupe(u8, "Fresh preview"),
    };
    defer replacement.deinit(alloc);

    try preserveIndexedDisplayMetadata(alloc, &.{indexed}, &replacement);

    try std.testing.expectEqualStrings("Fresh title", replacement.title.?);
    try std.testing.expectEqualStrings("Fresh preview", replacement.preview.?);
}

test "replaced index summary keeps fresh metadata when the indexed row has none" {
    const alloc = std.testing.allocator;
    var indexed = SessionSummary{
        .id = try alloc.dupe(u8, "bare-session"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 0,
        .display_metadata_present = false,
    };
    defer indexed.deinit(alloc);

    var replacement = SessionSummary{
        .id = try alloc.dupe(u8, "bare-session"),
        .created_at_ms = 1,
        .updated_at_ms = 9,
        .conversation_language = session.ConversationLanguage.default(),
        .history_len = 1,
        .display_metadata_present = true,
        .title = try alloc.dupe(u8, "First title"),
        .preview = try alloc.dupe(u8, "First preview"),
    };
    defer replacement.deinit(alloc);

    try preserveIndexedDisplayMetadata(alloc, &.{indexed}, &replacement);

    try std.testing.expectEqualStrings("First title", replacement.title.?);
    try std.testing.expectEqualStrings("First preview", replacement.preview.?);
}

test "workspace summary cache returns first matching latest entry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(cache_dir);
    const summary_path = try std.fs.path.join(alloc, &.{ cache_dir, "summary.json" });
    defer alloc.free(summary_path);
    try writeTestFile(
        summary_path,
        "{\"schema_version\":1,\"count\":2,\"latest_id\":\"other\",\"latest_by_workspace\":[{\"workspace_root\":\"/tmp/ws\",\"id\":\"match\"},{\"workspace_root\":\"/tmp/other\",\"id\":\"other\"}]}",
    );

    const latest = try readLatestWorkspaceSessionId(alloc, summary_path, "/tmp/ws") orelse return error.TestExpectedEqual;
    defer alloc.free(latest);
    try std.testing.expectEqualStrings("match", latest);
}

test "state summary fast parser reads generated cache shape" {
    const alloc = std.testing.allocator;
    const summary = try parseSessionStateSummaryFast(
        alloc,
        "{\"schema_version\":1,\"count\":2,\"latest_id\":\"session-2\",\"latest_by_workspace\":[]}",
    ) orelse return error.TestExpectedEqual;
    defer {
        var mutable = summary;
        mutable.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 2), summary.count);
    try std.testing.expectEqualStrings("session-2", summary.latest_id.?);
}
