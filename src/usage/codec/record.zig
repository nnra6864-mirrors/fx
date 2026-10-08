//! Byte-exact codecs for the profile usage ledger (`~/.fx/usage.jsonl`), the
//! shared generation fact, and the usage recovery marker body.
//!
//! These formats are shared with older fx binaries running on the same
//! profile, so every writer emits exactly the bytes they emit and every
//! parser accepts and rejects exactly what they accept and reject: the
//! generation fact, the four record kinds, and the read limits.
//! - `usage_report.zig` (`validateFact`, `validatePendingMarker`,
//!   `validateIncident`), `types.validGatewayGenerationId`
//! - `session_store.zig` (`validateUsageRecoveryMarker`, marker writer)
//!
//! Parsers take `std.json.Value`s or raw bytes and return owned values; free
//! them with `deinit`. Writers borrow their input and validate it first, so
//! nothing this file writes is rejected by this file's parsers.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Longest accepted ledger line, excluding its newline.
pub const max_record_bytes: usize = 16 * 1024;
/// Most records a ledger file may hold.
pub const max_records: usize = 200_000;
/// Longest accepted model name in a generation fact.
pub const max_model_bytes: usize = 1024;
/// Largest recovery marker body: `"v1 "`, 20 digits, newline.
pub const max_marker_bytes: usize = marker_prefix.len + 20 + 1;

const marker_prefix = "v1 ";
const generation_id_prefix = "gen_";
const generation_id_len = 30;

/// Completeness a durable incident can record. Ledger and snapshot parsers
/// reject `complete` and `legacy`, so they are not representable here.
pub const IncidentCompleteness = enum { pending, incomplete };

pub const Incident = struct {
    occurred_at_ms: i64,
    completeness: IncidentCompleteness,
};

/// A generation id that may still need a `/v1/generation` lookup.
/// Parsed values own `id`; free with `deinit`.
pub const PendingMarker = struct {
    id: []const u8,
    observed_at_ms: i64,

    pub fn deinit(self: *PendingMarker, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }

    pub fn eql(a: PendingMarker, b: PendingMarker) bool {
        return std.mem.eql(u8, a.id, b.id) and a.observed_at_ms == b.observed_at_ms;
    }
};

/// One authoritative AI Gateway generation. Parsed values own `id` and
/// `model`; free with `deinit`. Caller-built values may borrow them.
pub const GenerationFact = struct {
    id: []const u8,
    created_at_ms: i64,
    model: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: ?u64,
    billable_web_search_calls: u64 = 0,
    total_cost: f64,

    pub fn deinit(self: *GenerationFact, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.model);
        self.* = undefined;
    }

    /// Exact equality, the ledger's dedupe rule. Costs compare with `==`.
    pub fn eql(a: GenerationFact, b: GenerationFact) bool {
        return std.mem.eql(u8, a.id, b.id) and
            a.created_at_ms == b.created_at_ms and
            std.mem.eql(u8, a.model, b.model) and
            a.input_tokens == b.input_tokens and
            a.output_tokens == b.output_tokens and
            a.cache_read_tokens == b.cache_read_tokens and
            a.cache_write_tokens == b.cache_write_tokens and
            a.reasoning_tokens == b.reasoning_tokens and
            a.billable_web_search_calls == b.billable_web_search_calls and
            a.total_cost == b.total_cost;
    }
};

/// One `usage.jsonl` line. Parsed values own their strings; free with `deinit`.
pub const Record = union(enum) {
    coverage: i64,
    generation: GenerationFact,
    pending: PendingMarker,
    incident: Incident,

    pub fn deinit(self: *Record, alloc: Allocator) void {
        switch (self.*) {
            .generation => |*fact| fact.deinit(alloc),
            .pending => |*marker| marker.deinit(alloc),
            .coverage, .incident => {},
        }
        self.* = undefined;
    }
};

pub const FactError = error{InvalidGenerationFact};
pub const RecordError = error{InvalidUsageStore};
pub const MarkerError = error{InvalidUsageRecoveryMarker};

// ---------------------------------------------------------------------------
// Validation

/// `gen_` plus 26 Crockford base32 characters (no I, L, O, U).
pub fn validGenerationId(id: []const u8) bool {
    if (id.len != generation_id_len or !std.mem.startsWith(u8, id, generation_id_prefix)) return false;
    for (id[generation_id_prefix.len..]) |char| switch (char) {
        '0'...'9', 'A'...'H', 'J'...'K', 'M'...'N', 'P'...'T', 'V'...'Z' => {},
        else => return false,
    };
    return true;
}

pub fn validateFact(fact: GenerationFact) FactError!void {
    if (!validGenerationId(fact.id) or
        fact.created_at_ms < 0 or
        fact.model.len == 0 or
        fact.model.len > max_model_bytes or
        !std.math.isFinite(fact.total_cost) or
        fact.total_cost < 0 or
        fact.cache_read_tokens > fact.input_tokens or
        fact.cache_write_tokens > fact.input_tokens)
    {
        return error.InvalidGenerationFact;
    }
    if (fact.reasoning_tokens) |reasoning| {
        if (reasoning > fact.output_tokens) return error.InvalidGenerationFact;
    }
    for (fact.model) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidGenerationFact;
    }
}

pub fn validatePendingMarker(marker: PendingMarker) error{InvalidPendingMarker}!void {
    if (!validGenerationId(marker.id) or marker.observed_at_ms < 0) return error.InvalidPendingMarker;
}

pub fn validateIncident(incident: Incident) error{InvalidUsageIncident}!void {
    if (incident.occurred_at_ms < 0) return error.InvalidUsageIncident;
}

// ---------------------------------------------------------------------------
// Generation fact (10 keys written, 9 or 10 accepted)

/// Writes the shared fact object used by ledger records and snapshot backlogs.
pub fn writeFact(writer: *std.Io.Writer, fact: GenerationFact) (std.Io.Writer.Error || FactError)!void {
    try validateFact(fact);
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(fact.id, .{}, writer);
    try writer.print(",\"created_at_ms\":{d},\"model\":", .{fact.created_at_ms});
    try std.json.Stringify.value(fact.model, .{}, writer);
    try writer.print(
        ",\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":",
        .{ fact.input_tokens, fact.output_tokens, fact.cache_read_tokens, fact.cache_write_tokens },
    );
    try writeOptionalU64(writer, fact.reasoning_tokens);
    try writer.print(
        ",\"billable_web_search_calls\":{d},\"total_cost\":{d}}}",
        .{ fact.billable_web_search_calls, fact.total_cost },
    );
}

/// Parses a fact object. Accepts 9 or 10 keys and, like fx today, checks only
/// the names it reads: a 10th key with any name passes, and a missing
/// `billable_web_search_calls` reads as 0. The caller owns the result.
pub fn parseFact(alloc: Allocator, value: std.json.Value) (Allocator.Error || FactError)!GenerationFact {
    if (value != .object or (value.object.count() != 9 and value.object.count() != 10)) {
        return error.InvalidGenerationFact;
    }
    const id_value = value.object.get("id") orelse return error.InvalidGenerationFact;
    const model_value = value.object.get("model") orelse return error.InvalidGenerationFact;
    const reasoning_value = value.object.get("reasoning_tokens") orelse return error.InvalidGenerationFact;
    if (id_value != .string or model_value != .string) return error.InvalidGenerationFact;
    const id = try alloc.dupe(u8, id_value.string);
    errdefer alloc.free(id);
    const model = try alloc.dupe(u8, model_value.string);
    errdefer alloc.free(model);
    const fact = GenerationFact{
        .id = id,
        .created_at_ms = try factI64(value.object.get("created_at_ms")),
        .model = model,
        .input_tokens = try factU64(value.object.get("input_tokens")),
        .output_tokens = try factU64(value.object.get("output_tokens")),
        .cache_read_tokens = try factU64(value.object.get("cache_read_tokens")),
        .cache_write_tokens = try factU64(value.object.get("cache_write_tokens")),
        .reasoning_tokens = if (reasoning_value == .null) null else try factU64(reasoning_value),
        .billable_web_search_calls = if (value.object.get("billable_web_search_calls")) |field|
            try factU64(field)
        else
            0,
        .total_cost = try factCost(value.object.get("total_cost")),
    };
    try validateFact(fact);
    return fact;
}

fn factU64(value: ?std.json.Value) FactError!u64 {
    return jsonU64(value) orelse error.InvalidGenerationFact;
}

fn factI64(value: ?std.json.Value) FactError!i64 {
    return std.math.cast(i64, try factU64(value)) orelse error.InvalidGenerationFact;
}

fn factCost(value: ?std.json.Value) FactError!f64 {
    const actual = value orelse return error.InvalidGenerationFact;
    const number: f64 = switch (actual) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch return error.InvalidGenerationFact,
        else => return error.InvalidGenerationFact,
    };
    if (!std.math.isFinite(number) or number < 0) return error.InvalidGenerationFact;
    return number;
}

// ---------------------------------------------------------------------------
// Ledger records

/// Writes one ledger line, including its trailing newline.
pub fn writeRecord(
    writer: *std.Io.Writer,
    record: Record,
) (std.Io.Writer.Error || error{ InvalidCoverage, InvalidGenerationFact, InvalidPendingMarker, InvalidUsageIncident })!void {
    switch (record) {
        .coverage => |started_at_ms| {
            if (started_at_ms < 0) return error.InvalidCoverage;
            try writer.print("{{\"schema_version\":1,\"kind\":\"coverage\",\"started_at_ms\":{d}}}\n", .{started_at_ms});
        },
        .generation => |fact| {
            try validateFact(fact);
            try writer.writeAll("{\"schema_version\":1,\"kind\":\"generation\",\"fact\":");
            try writeFact(writer, fact);
            try writer.writeAll("}\n");
        },
        .pending => |marker| {
            try validatePendingMarker(marker);
            try writer.writeAll("{\"schema_version\":1,\"kind\":\"pending\",\"id\":");
            try std.json.Stringify.value(marker.id, .{}, writer);
            try writer.print(",\"observed_at_ms\":{d}}}\n", .{marker.observed_at_ms});
        },
        .incident => |incident| {
            try validateIncident(incident);
            try writer.print(
                "{{\"schema_version\":1,\"kind\":\"incident\",\"occurred_at_ms\":{d},\"completeness\":",
                .{incident.occurred_at_ms},
            );
            try std.json.Stringify.value(@tagName(incident.completeness), .{}, writer);
            try writer.writeAll("}\n");
        },
    }
}

/// Parses one ledger line without its newline, exactly as fx's
/// `parseRecord` does: numbers stay strings (`parse_numbers=false`), the
/// schema must be 1, and each kind has an exact key count. The caller owns
/// the result. Line-length and record-count limits are the caller's, as in
/// fx (`max_record_bytes`, `max_records`).
pub fn parseRecord(alloc: Allocator, line: []const u8) (Allocator.Error || RecordError)!Record {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        line,
        .{ .allocate = .alloc_always, .parse_numbers = false },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidUsageStore,
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidUsageStore;
    const schema = try storeU64(root.object.get("schema_version"));
    const kind_value = root.object.get("kind") orelse return error.InvalidUsageStore;
    if (schema != 1 or kind_value != .string) return error.InvalidUsageStore;
    const kind = kind_value.string;

    if (std.mem.eql(u8, kind, "coverage")) {
        if (root.object.count() != 3) return error.InvalidUsageStore;
        return .{ .coverage = try storeI64(root.object.get("started_at_ms")) };
    }
    if (std.mem.eql(u8, kind, "pending")) {
        if (root.object.count() != 4) return error.InvalidUsageStore;
        const id_value = root.object.get("id") orelse return error.InvalidUsageStore;
        if (id_value != .string) return error.InvalidUsageStore;
        const id = try alloc.dupe(u8, id_value.string);
        errdefer alloc.free(id);
        const marker = PendingMarker{
            .id = id,
            .observed_at_ms = try storeI64(root.object.get("observed_at_ms")),
        };
        validatePendingMarker(marker) catch return error.InvalidUsageStore;
        return .{ .pending = marker };
    }
    if (std.mem.eql(u8, kind, "incident")) {
        if (root.object.count() != 4) return error.InvalidUsageStore;
        const completeness_value = root.object.get("completeness") orelse return error.InvalidUsageStore;
        if (completeness_value != .string) return error.InvalidUsageStore;
        const completeness = std.meta.stringToEnum(IncidentCompleteness, completeness_value.string) orelse
            return error.InvalidUsageStore;
        return .{ .incident = .{
            .occurred_at_ms = try storeI64(root.object.get("occurred_at_ms")),
            .completeness = completeness,
        } };
    }
    if (!std.mem.eql(u8, kind, "generation") or root.object.count() != 3) return error.InvalidUsageStore;
    const fact_value = root.object.get("fact") orelse return error.InvalidUsageStore;
    return .{ .generation = parseFact(alloc, fact_value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidGenerationFact => return error.InvalidUsageStore,
    } };
}

fn storeU64(value: ?std.json.Value) RecordError!u64 {
    return jsonU64(value) orelse error.InvalidUsageStore;
}

fn storeI64(value: ?std.json.Value) RecordError!i64 {
    return std.math.cast(i64, try storeU64(value)) orelse error.InvalidUsageStore;
}

// ---------------------------------------------------------------------------
// Recovery marker body: "v1 <ms>\n" in usage-recovery/ and usage-recovery-v2/

/// Formats the marker body into `buffer` and returns the written slice.
pub fn writeMarker(buffer: *[max_marker_bytes]u8, protected_at_ms: i64) MarkerError![]const u8 {
    if (protected_at_ms < 0) return error.InvalidUsageRecoveryMarker;
    return std.fmt.bufPrint(buffer, marker_prefix ++ "{d}\n", .{protected_at_ms}) catch unreachable;
}

/// Parses a marker body the way `validateUsageRecoveryMarker` does after its
/// file-shape checks: 1..24 bytes, `v1 ` prefix, newline suffix, and a
/// non-negative i64 that `std.fmt.parseInt` accepts (so `+5` and `007` pass).
pub fn parseMarker(bytes: []const u8) MarkerError!i64 {
    if (bytes.len == 0 or bytes.len > max_marker_bytes) return error.InvalidUsageRecoveryMarker;
    if (!std.mem.startsWith(u8, bytes, marker_prefix) or !std.mem.endsWith(u8, bytes, "\n")) {
        return error.InvalidUsageRecoveryMarker;
    }
    // A body of exactly "v1 " ends without a newline, so the slice is ordered.
    const digits = bytes[marker_prefix.len .. bytes.len - 1];
    if (digits.len == 0) return error.InvalidUsageRecoveryMarker;
    const ms = std.fmt.parseInt(i64, digits, 10) catch return error.InvalidUsageRecoveryMarker;
    if (ms < 0) return error.InvalidUsageRecoveryMarker;
    return ms;
}

// ---------------------------------------------------------------------------
// Shared number helpers

/// Non-negative integer from `.integer` or a base-10 `.number_string`.
fn jsonU64(value: ?std.json.Value) ?u64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |number| if (number >= 0) std.math.cast(u64, number) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn writeOptionalU64(writer: *std.Io.Writer, value: ?u64) std.Io.Writer.Error!void {
    if (value) |number| try writer.print("{d}", .{number}) else try writer.writeAll("null");
}

// ---------------------------------------------------------------------------
// Tests. Fixture tests read the compat fixtures embedded from
// testdata/compat/, so they run from any working directory.

const testing = std.testing;
const testdata = @import("../testdata/dir.zig");
const max_fixture_bytes = 1 << 22;

fn openFixtures() !testdata.Dir {
    return testdata.Dir.open("compat");
}

fn readFixture(alloc: Allocator, dir: testdata.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, path, alloc, .limited(max_fixture_bytes));
}

fn lineOf(alloc: Allocator, record: Record) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeRecord(&out.writer, record);
    return out.toOwnedSlice();
}

test "captured usage.jsonl round-trips byte-identically" {
    const alloc = testing.allocator;
    var root = try openFixtures();
    defer root.close(testing.io);
    const ledger = try readFixture(alloc, root, "fx-home/usage.jsonl");
    defer alloc.free(ledger);
    try testing.expect(std.mem.endsWith(u8, ledger, "\n"));

    var rebuilt: std.Io.Writer.Allocating = .init(alloc);
    defer rebuilt.deinit();
    var kinds = std.EnumArray(std.meta.Tag(Record), usize).initFill(0);
    var lines = std.mem.splitScalar(u8, ledger[0 .. ledger.len - 1], '\n');
    while (lines.next()) |line| {
        try testing.expect(line.len <= max_record_bytes);
        var parsed = try parseRecord(alloc, line);
        defer parsed.deinit(alloc);
        kinds.getPtr(std.meta.activeTag(parsed)).* += 1;
        try writeRecord(&rebuilt.writer, parsed);
    }
    try testing.expectEqualStrings(ledger, rebuilt.written());
    // One coverage line, and every other kind fx wrote during capture.
    try testing.expectEqual(@as(usize, 1), kinds.get(.coverage));
    try testing.expect(kinds.get(.generation) >= 5);
    try testing.expect(kinds.get(.pending) >= 5);
    try testing.expect(kinds.get(.incident) >= 2);
}

test "captured torn ledger: whole lines parse, the torn tail does not" {
    const alloc = testing.allocator;
    var root = try openFixtures();
    defer root.close(testing.io);
    const torn = try readFixture(alloc, root, "usage.torn-input.jsonl");
    defer alloc.free(torn);
    try testing.expect(!std.mem.endsWith(u8, torn, "\n"));
    const boundary = std.mem.lastIndexOfScalar(u8, torn, '\n').? + 1;
    var lines = std.mem.splitScalar(u8, torn[0 .. boundary - 1], '\n');
    while (lines.next()) |line| {
        var parsed = try parseRecord(alloc, line);
        parsed.deinit(alloc);
    }
    try testing.expectError(error.InvalidUsageStore, parseRecord(alloc, torn[boundary..]));
}

test "captured recovery markers round-trip byte-identically" {
    const alloc = testing.allocator;
    var root = try openFixtures();
    defer root.close(testing.io);
    var checked: usize = 0;
    for ([_][]const u8{ "fx-home/usage-recovery", "fx-home/usage-recovery-v2" }) |path| {
        var dir = try root.openDir(testing.io, path, .{ .iterate = true });
        defer dir.close(testing.io);
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            const bytes = try readFixture(alloc, dir, entry.name);
            defer alloc.free(bytes);
            const ms = try parseMarker(bytes);
            var buffer: [max_marker_bytes]u8 = undefined;
            try testing.expectEqualStrings(bytes, try writeMarker(&buffer, ms));
            checked += 1;
        }
    }
    try testing.expect(checked >= 4);
}

const CorpusCase = struct { name: []const u8, parser: []const u8, input: []const u8 };
const CorpusVerdict = struct {
    name: []const u8,
    ok: bool,
    @"error": ?[]const u8 = null,
    record: ?[]const u8 = null,
};

test "differential corpus: every ledger reader rule agrees with fx" {
    const alloc = testing.allocator;
    var root = try openFixtures();
    defer root.close(testing.io);
    const corpus = try readFixture(alloc, root, "cases/record.jsonl");
    defer alloc.free(corpus);
    const expected = try readFixture(alloc, root, "derived/cases/record.expected.jsonl");
    defer alloc.free(expected);

    var case_lines = std.mem.splitScalar(u8, corpus, '\n');
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var count: usize = 0;
    var rejected: usize = 0;
    while (case_lines.next()) |case_line| {
        if (case_line.len == 0) continue;
        const expected_line = expected_lines.next() orelse return error.ExpectedVerdictMissing;
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const case = try std.json.parseFromSliceLeaky(CorpusCase, arena, case_line, .{});
        const want = try std.json.parseFromSliceLeaky(CorpusVerdict, arena, expected_line, .{ .ignore_unknown_fields = true });
        try testing.expectEqualStrings(want.name, case.name);
        try testing.expectEqualStrings("record", case.parser);
        if (parseRecord(arena, case.input)) |parsed| {
            if (!want.ok) {
                std.debug.print("case {s}: fx rejected with {?s}, codec accepted\n", .{ case.name, want.@"error" });
                return error.VerdictMismatch;
            }
            const line = try lineOf(arena, parsed);
            testing.expectEqualStrings(want.record.?, line) catch |err| {
                std.debug.print("case {s}\n", .{case.name});
                return err;
            };
        } else |err| {
            if (want.ok) {
                std.debug.print("case {s}: fx accepted, codec rejected with {s}\n", .{ case.name, @errorName(err) });
                return error.VerdictMismatch;
            }
            try testing.expectEqualStrings(want.@"error".?, @errorName(err));
            rejected += 1;
        }
        count += 1;
    }
    try testing.expectEqual(@as(usize, 67), count);
    try testing.expectEqual(@as(usize, 49), rejected);
}

test "fx vector: generation fact codec round trip" {
    // generation_fact_codec.zig "codec round trips the shared generation fact shape"
    const alloc = testing.allocator;
    const expected = GenerationFact{
        .id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV",
        .created_at_ms = 42,
        .model = "provider/model",
        .input_tokens = 8,
        .output_tokens = 3,
        .cache_read_tokens = 2,
        .cache_write_tokens = 1,
        .reasoning_tokens = null,
        .billable_web_search_calls = 4,
        .total_cost = 0.25,
    };
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeFact(&encoded.writer, expected);
    try testing.expectEqualStrings(
        "{\"id\":\"gen_01ARZ3NDEKTSV4RRFFQ69G5FAV\",\"created_at_ms\":42,\"model\":\"provider/model\",\"input_tokens\":8,\"output_tokens\":3,\"cache_read_tokens\":2,\"cache_write_tokens\":1,\"reasoning_tokens\":null,\"billable_web_search_calls\":4,\"total_cost\":0.25}",
        encoded.written(),
    );
    for ([_]bool{ true, false }) |parse_numbers| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{ .parse_numbers = parse_numbers });
        defer parsed.deinit();
        var decoded = try parseFact(alloc, parsed.value);
        defer decoded.deinit(alloc);
        try testing.expect(GenerationFact.eql(expected, decoded));
    }
    try testing.expect(std.mem.indexOf(u8, encoded.written(), "request_count") == null);
}

test "fx vector: usage_recovery test marker parses" {
    // usage_recovery.zig:628 writes this body directly.
    try testing.expectEqual(@as(i64, 9_999_999_999_999), try parseMarker("v1 9999999999999\n"));
}

test "marker body rules" {
    const rejected = [_][]const u8{
        "",
        "v1 ",
        "v1 \n",
        "v1 5",
        "v2 5\n",
        "V1 5\n",
        "v15\n",
        "v1 -1\n",
        "v1 abc\n",
        "v1 5\n\n",
        "v1 5 \n",
        "v1 9223372036854775808\n",
        "v1 000000000000000000001\n", // 25 bytes; the limit is 24
    };
    for (rejected) |body| {
        testing.expectError(error.InvalidUsageRecoveryMarker, parseMarker(body)) catch |err| {
            std.debug.print("accepted {any}\n", .{body});
            return err;
        };
    }
    // parseInt quirks fx accepts.
    try testing.expectEqual(@as(i64, 5), try parseMarker("v1 +5\n"));
    try testing.expectEqual(@as(i64, 7), try parseMarker("v1 007\n"));
    try testing.expectEqual(@as(i64, 0), try parseMarker("v1 0\n"));
    try testing.expectEqual(@as(i64, 0), try parseMarker("v1 -0\n"));
    try testing.expectEqual(@as(i64, 1), try parseMarker("v1 00000000000000000001\n")); // exactly 24 bytes
    try testing.expectEqual(std.math.maxInt(i64), try parseMarker("v1 9223372036854775807\n"));

    var buffer: [max_marker_bytes]u8 = undefined;
    try testing.expectEqualStrings("v1 0\n", try writeMarker(&buffer, 0));
    try testing.expectEqualStrings("v1 9223372036854775807\n", try writeMarker(&buffer, std.math.maxInt(i64)));
    try testing.expectError(error.InvalidUsageRecoveryMarker, writeMarker(&buffer, -1));
}

test "record writers refuse what the ledger parser rejects" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try testing.expectError(error.InvalidCoverage, writeRecord(&writer, .{ .coverage = -1 }));
    try testing.expectError(error.InvalidPendingMarker, writeRecord(&writer, .{ .pending = .{ .id = "gen_short", .observed_at_ms = 1 } }));
    try testing.expectError(error.InvalidPendingMarker, writeRecord(&writer, .{ .pending = .{ .id = "gen_01M4BNAZ8NS50TRNYFRJJESTF4", .observed_at_ms = -1 } }));
    try testing.expectError(error.InvalidUsageIncident, writeRecord(&writer, .{ .incident = .{ .occurred_at_ms = -1, .completeness = .pending } }));
    const fact = GenerationFact{
        .id = "gen_01M4BNAZ8NS50TRNYFRJJESTF4",
        .created_at_ms = 0,
        .model = "m",
        .input_tokens = 1,
        .output_tokens = 1,
        .cache_read_tokens = 2,
        .cache_write_tokens = 0,
        .reasoning_tokens = null,
        .total_cost = 0,
    };
    try testing.expectError(error.InvalidGenerationFact, writeRecord(&writer, .{ .generation = fact }));
    var nan_fact = fact;
    nan_fact.cache_read_tokens = 0;
    nan_fact.total_cost = std.math.nan(f64);
    try testing.expectError(error.InvalidGenerationFact, writeFact(&writer, nan_fact));
    try testing.expectEqual(@as(usize, 0), writer.end);
}

test "generation ids are gen_ plus 26 Crockford base32 characters" {
    try testing.expect(validGenerationId("gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"));
    try testing.expect(validGenerationId("gen_0123456789ABCDEFGHJKMNPQRS"));
    try testing.expect(validGenerationId("gen_TVWXYZ00000000000000000000"));
    for ([_]u8{ 'I', 'L', 'O', 'U', 'a', '-', '_' }) |bad| {
        var id = "gen_01ARZ3NDEKTSV4RRFFQ69G5FAV".*;
        id[29] = bad;
        try testing.expect(!validGenerationId(&id));
    }
    try testing.expect(!validGenerationId("gen_01ARZ3NDEKTSV4RRFFQ69G5FA"));
    try testing.expect(!validGenerationId("gen_01ARZ3NDEKTSV4RRFFQ69G5FAVV"));
    try testing.expect(!validGenerationId("Gen_01ARZ3NDEKTSV4RRFFQ69G5FAV"));
}

test "record parser releases every partial allocation" {
    const line = "{\"schema_version\":1,\"kind\":\"generation\",\"fact\":{\"id\":\"gen_01M4BNCM6HSVRSKERSYR58S3CE\",\"created_at_ms\":1791392895000,\"model\":\"anthropic/claude-haiku-4.5\",\"input_tokens\":14,\"output_tokens\":4,\"cache_read_tokens\":0,\"cache_write_tokens\":0,\"reasoning_tokens\":0,\"billable_web_search_calls\":0,\"total_cost\":0.000134}}";
    const Check = struct {
        fn run(a: Allocator, text: []const u8) !void {
            var parsed = try parseRecord(a, text);
            parsed.deinit(a);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{line});
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{"{\"schema_version\":1,\"kind\":\"pending\",\"id\":\"gen_01M4BNAZ8NS50TRNYFRJJESTF4\",\"observed_at_ms\":1}"});
}
