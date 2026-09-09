const std = @import("std");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const session_store = @import("../session/session_store.zig");
const session_child_store = @import("../session/session_child_store.zig");
const result_store = @import("../session/result_store.zig");
const types = @import("../shared/types.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const index_file = "deliveries.json";
const max_index_bytes = 512 * 1024;
const max_outcome_bytes = 128 * 1024;

/// Borrowed for calls; Index owns its decoded strings. Results live in separate
/// immutable artifacts so registry replacement cannot erase completed work.
pub const Receipt = struct {
    parent_turn_id: u64,
    child_id: []const u8,
    work_id: []const u8,
    tool_call_id: []const u8,
    delivery_id: []const u8,

    pub fn key(self: Receipt) [32]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.delivery_id, &digest, .{});
        return digest;
    }

    fn validate(self: Receipt) !void {
        try domain.validateId(self.child_id);
        if (types.ConversationIdentity.invalidReason(self.work_id) != null or
            types.ConversationIdentity.invalidReason(self.tool_call_id) != null or
            types.ConversationIdentity.invalidReason(self.delivery_id) != null or
            self.parent_turn_id == 0) return error.InvalidDeliveryReceipt;
    }

    pub fn observation(self: Receipt, parent_id: []const u8, outcome: types.ChildObservation.Outcome, text: []const u8) types.ChildObservation {
        return .{
            .parent_session_id = parent_id,
            .parent_turn_id = self.parent_turn_id,
            .child_id = self.child_id,
            .work_id = self.work_id,
            .tool_call_id = self.tool_call_id,
            .delivery_id = self.delivery_id,
            .outcome = outcome,
            .text = text,
        };
    }
};

const Document = struct {
    schema_version: u32 = 1,
    parent_id: []const u8,
    receipts: []const Receipt = &.{},
};

pub const Index = struct {
    parsed: ?std.json.Parsed(Document) = null,

    pub fn items(self: *const Index) []const Receipt {
        return if (self.parsed) |value| value.value.receipts else &.{};
    }

    pub fn find(self: *const Index, child_id: []const u8, work_id: []const u8) ?Receipt {
        for (self.items()) |receipt| {
            if (std.mem.eql(u8, receipt.child_id, child_id) and
                std.mem.eql(u8, receipt.work_id, work_id)) return receipt;
        }
        return null;
    }

    pub fn deinit(self: *Index) void {
        if (self.parsed) |value| value.deinit();
        self.* = .{};
    }
};

/// Uses the child's existing parent-registry advisory lock. Public mutators
/// acquire it themselves; callers must not enter them while holding that lock.
/// The session writer lease remains with the original-session environment.
pub const Store = struct {
    sessions: *session_store.Store,
    parent_id: []const u8,
    results: ?*const session_child_store.SessionChildCapability = null,

    fn registry(self: Store) child_state.Store {
        return .{ .sessions = self.sessions, .parent_id = self.parent_id };
    }

    pub fn load(self: Store, alloc: Allocator) !Index {
        var capability = try self.sessions.openSubagentControlCapabilityReadOnly(alloc, self.parent_id, .{});
        defer capability.deinit();
        var file = capability.openFileReadOnly(alloc, .subagent_control, index_file) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, max_index_bytes);
        defer alloc.free(bytes);
        const parsed = try std.json.parseFromSlice(Document, alloc, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        if (parsed.value.schema_version != 1 or !std.mem.eql(u8, parsed.value.parent_id, self.parent_id) or
            parsed.value.receipts.len > child_state.max_children) return error.InvalidDeliveryReceipt;
        for (parsed.value.receipts, 0..) |receipt, i| {
            try receipt.validate();
            for (parsed.value.receipts[0..i]) |prior| {
                if (std.mem.eql(u8, prior.delivery_id, receipt.delivery_id) or
                    (std.mem.eql(u8, prior.child_id, receipt.child_id) and std.mem.eql(u8, prior.work_id, receipt.work_id)))
                    return error.DuplicateDeliveryReceipt;
            }
        }
        return .{ .parsed = parsed };
    }

    fn save(self: Store, alloc: Allocator, receipts: []const Receipt) !void {
        if (receipts.len > child_state.max_children) return error.DeliveryCapacityExceeded;
        const bytes = try std.json.Stringify.valueAlloc(alloc, Document{ .parent_id = self.parent_id, .receipts = receipts }, .{});
        defer alloc.free(bytes);
        if (bytes.len > max_index_bytes) return error.DeliveryCapacityExceeded;
        var capability = try self.sessions.openSubagentControlCapabilityWritable(alloc, self.parent_id, .{});
        defer capability.deinit();
        var entry = try capability.atomicReplace(alloc, .subagent_control, index_file, bytes);
        entry.deinit(alloc);
    }

    pub fn reserve(self: Store, alloc: Allocator, receipt: Receipt) !void {
        try receipt.validate();
        var lock = try self.registry().acquireLock(alloc);
        defer lock.release();
        var index = try self.load(alloc);
        defer index.deinit();
        for (index.items()) |prior| {
            if (!std.mem.eql(u8, prior.delivery_id, receipt.delivery_id) and
                !(std.mem.eql(u8, prior.child_id, receipt.child_id) and std.mem.eql(u8, prior.work_id, receipt.work_id))) continue;
            if (!equalReceipt(prior, receipt)) return error.DeliveryIdentityConflict;
            debug_trace.eventf("subagent", "child_delivery_reservation_reused", .{ .turn_id = receipt.parent_turn_id }, "root_id={s} child_id={s} work_id={s} delivery_id={s}", .{ self.parent_id, receipt.child_id, receipt.work_id, receipt.delivery_id });
            return;
        }
        if (index.items().len >= child_state.max_children) return error.DeliveryCapacityExceeded;
        const next = try alloc.alloc(Receipt, index.items().len + 1);
        defer alloc.free(next);
        @memcpy(next[0..index.items().len], index.items());
        next[index.items().len] = receipt;
        try self.save(alloc, next);
        debug_trace.eventf("subagent", "child_delivery_reserved", .{ .turn_id = receipt.parent_turn_id }, "root_id={s} child_id={s} work_id={s} delivery_id={s}", .{ self.parent_id, receipt.child_id, receipt.work_id, receipt.delivery_id });
    }

    /// Returns caller-owned exact evidence. The immutable artifact remains until
    /// ordinary session deletion; retiring a receipt only updates the bounded index.
    pub fn outcome(self: Store, alloc: Allocator, receipt: Receipt) !?types.ChildObservation {
        try receipt.validate();
        var capability = try self.sessions.openSubagentControlCapabilityReadOnly(alloc, self.parent_id, .{});
        defer capability.deinit();
        var name: [80]u8 = undefined;
        var file = capability.openFileReadOnly(alloc, .subagent_control, outcomeName(&name, receipt.delivery_id)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, max_outcome_bytes);
        defer alloc.free(bytes);
        var decoded = try std.json.parseFromSlice(types.ChildObservation, alloc, bytes, .{ .allocate = .alloc_always });
        defer decoded.deinit();
        try decoded.value.validate();
        if (!matches(self.parent_id, receipt, decoded.value)) return error.DeliveryIdentityConflict;
        return try types.dupeChildObservation(alloc, decoded.value);
    }

    /// Must complete before latest-state publication lets another generation run.
    /// Identical publication is idempotent; altered evidence cannot replace it.
    pub fn publish(self: Store, alloc: Allocator, value: types.ChildObservation) !void {
        try value.validate();
        var lock = try self.registry().acquireLock(alloc);
        defer lock.release();
        var index = try self.load(alloc);
        defer index.deinit();
        const receipt = index.find(value.child_id, value.work_id) orelse return error.DeliveryNotReserved;
        if (!matches(self.parent_id, receipt, value)) return error.DeliveryIdentityConflict;
        const bytes = try std.json.Stringify.valueAlloc(alloc, value, .{});
        defer alloc.free(bytes);
        if (bytes.len > max_outcome_bytes) return error.DeliveryCapacityExceeded;
        if (try self.outcome(alloc, receipt)) |prior| {
            defer types.freeChildObservation(alloc, prior);
            const prior_bytes = try std.json.Stringify.valueAlloc(alloc, prior, .{});
            defer alloc.free(prior_bytes);
            if (!std.mem.eql(u8, bytes, prior_bytes)) return error.DeliveryIdentityConflict;
            return;
        }
        var capability = try self.sessions.openSubagentControlCapabilityWritable(alloc, self.parent_id, .{});
        defer capability.deinit();
        var name: [80]u8 = undefined;
        var entry = try capability.atomicReplace(alloc, .subagent_control, outcomeName(&name, receipt.delivery_id), bytes);
        entry.deinit(alloc);
        debug_trace.eventf("subagent", "child_delivery_outcome_synced", .{ .turn_id = value.parent_turn_id }, "root_id={s} child_id={s} work_id={s} delivery_id={s} outcome={s} text_bytes={d}", .{ self.parent_id, value.child_id, value.work_id, value.delivery_id, @tagName(value.outcome), value.text.len });
    }

    /// Preserves the full UTF-8 output in content-addressed parent-owned storage
    /// when the model observation needs a bounded preview.
    pub fn publishText(self: Store, alloc: Allocator, receipt: Receipt, outcome_value: types.ChildObservation.Outcome, text: []const u8) !void {
        if (text.len > 4 * 1024 * 1024) return error.DeliveryCapacityExceeded;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidChildObservation;
        var value = receipt.observation(self.parent_id, outcome_value, text);
        var handle: ?[]u8 = null;
        defer if (handle) |owned| alloc.free(owned);
        if (text.len > types.ChildObservation.max_text_bytes) {
            const source = self.results orelse return error.DeliveryOutputStoreUnavailable;
            // A capability caches directory routes; concurrent children use
            // separate duplicates rather than mutating that cache together.
            var capability = try source.duplicate(alloc);
            defer capability.deinit();
            handle = try result_store.storeLargeResultManaged(alloc, &capability, receipt.delivery_id, "subagent", text);
            var end: usize = types.ChildObservation.max_text_bytes;
            while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
            value.text = text[0..end];
            value.output_ref = handle;
            debug_trace.eventf("subagent", "child_delivery_output_stored", .{ .turn_id = receipt.parent_turn_id }, "root_id={s} child_id={s} work_id={s} output_bytes={d}", .{ self.parent_id, receipt.child_id, receipt.work_id, text.len });
        }
        try self.publish(alloc, value);
    }

    /// Invoke only after canonical adoption or the original terminal tool result
    /// is durably committed. On failure the receipt remains eligible for dedup.
    pub fn acknowledge(self: Store, alloc: Allocator, receipt: Receipt) !void {
        var lock = try self.registry().acquireLock(alloc);
        defer lock.release();
        var index = try self.load(alloc);
        defer index.deinit();
        const next = try alloc.alloc(Receipt, index.items().len);
        defer alloc.free(next);
        var count: usize = 0;
        var found = false;
        for (index.items()) |prior| {
            if (std.mem.eql(u8, prior.delivery_id, receipt.delivery_id)) {
                if (!equalReceipt(prior, receipt)) return error.DeliveryIdentityConflict;
                found = true;
                continue;
            }
            next[count] = prior;
            count += 1;
        }
        if (!found) return;
        try self.save(alloc, next[0..count]);
        debug_trace.eventf("subagent", "child_delivery_receipt_retired", .{ .turn_id = receipt.parent_turn_id }, "root_id={s} child_id={s} work_id={s} delivery_id={s}", .{ self.parent_id, receipt.child_id, receipt.work_id, receipt.delivery_id });
    }
};

fn equalReceipt(a: Receipt, b: Receipt) bool {
    return a.parent_turn_id == b.parent_turn_id and
        std.mem.eql(u8, a.child_id, b.child_id) and std.mem.eql(u8, a.work_id, b.work_id) and
        std.mem.eql(u8, a.tool_call_id, b.tool_call_id) and std.mem.eql(u8, a.delivery_id, b.delivery_id);
}

fn matches(parent_id: []const u8, receipt: Receipt, value: types.ChildObservation) bool {
    return std.mem.eql(u8, parent_id, value.parent_session_id) and equalReceipt(receipt, .{
        .parent_turn_id = value.parent_turn_id,
        .child_id = value.child_id,
        .work_id = value.work_id,
        .tool_call_id = value.tool_call_id,
        .delivery_id = value.delivery_id,
    });
}

fn outcomeName(buffer: *[80]u8, delivery_id: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(delivery_id, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.bufPrint(buffer, "delivery-{s}.json", .{hex}) catch unreachable;
}

test "child delivery reservation publication and retirement preserve exact immutable evidence" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var sessions = try session_store.Store.initFromHome(alloc, home, home);
    defer sessions.deinit(alloc);
    var writer = try sessions.startWritableSession(alloc, .{
        .id = @constCast("parent"),
        .origin_workspace_root = @constCast(home),
        .workspace_root = @constCast(home),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = .literal("en"),
        .preferences = .{ .model = @constCast("test"), .effort = .auto, .fast_mode = false },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    });
    defer writer.deinit(alloc);
    const trace_path = try std.fs.path.join(alloc, &.{ home, "delivery-flow.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "subagent");
    defer debug_trace.resetForTest();
    const store = Store{ .sessions = &sessions, .parent_id = "parent", .results = try writer.childCapability() };
    const a = Receipt{ .parent_turn_id = 1, .child_id = "child", .work_id = "work-a", .tool_call_id = "call-a", .delivery_id = "delivery-a" };
    const b = Receipt{ .parent_turn_id = 2, .child_id = "child", .work_id = "work-b", .tool_call_id = "call-b", .delivery_id = "delivery-b" };
    try store.reserve(alloc, a);
    try store.reserve(alloc, a);
    try std.testing.expect(try store.outcome(alloc, a) == null);
    var invalid = a;
    invalid.work_id = "different-work";
    try std.testing.expectError(error.DeliveryIdentityConflict, store.reserve(alloc, invalid));
    const result_a = a.observation("parent", .completed, "PRIVATE_CHILD_OUTPUT_DO_NOT_LOG");
    try store.publish(alloc, result_a);
    try store.publish(alloc, result_a);
    var changed = result_a;
    changed.text = "changed";
    try std.testing.expectError(error.DeliveryIdentityConflict, store.publish(alloc, changed));
    try store.reserve(alloc, b);
    try store.publish(alloc, b.observation("parent", .failed, "second work"));
    const retained = (try store.outcome(alloc, a)).?;
    defer types.freeChildObservation(alloc, retained);
    try std.testing.expectEqualStrings(result_a.text, retained.text);
    try store.acknowledge(alloc, a);
    try store.acknowledge(alloc, a);
    var index = try store.load(alloc);
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 1), index.items().len);
    try std.testing.expectEqualStrings("work-b", index.items()[0].work_id);
    const historical = (try store.outcome(alloc, a)).?;
    defer types.freeChildObservation(alloc, historical);
    try std.testing.expectEqualStrings(result_a.text, historical.text);

    const c = Receipt{ .parent_turn_id = 3, .child_id = "child", .work_id = "work-c", .tool_call_id = "call-c", .delivery_id = "delivery-c" };
    const large = "π" ** 10000;
    try store.reserve(alloc, c);
    try store.publishText(alloc, c, .completed, large);
    const large_result = (try store.outcome(alloc, c)).?;
    defer types.freeChildObservation(alloc, large_result);
    try std.testing.expect(large_result.text.len <= types.ChildObservation.max_text_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(large_result.text));
    var reader = try result_store.openReaderManaged(alloc, try writer.childCapability(), large_result.output_ref.?);
    defer reader.deinit();
    const complete = try reader.readPage(alloc, 0, large.len);
    defer alloc.free(complete);
    try std.testing.expectEqualStrings(large, complete);
    try store.acknowledge(alloc, c);

    const trace = try tmp.dir.readFileAlloc(std.testing.io, "delivery-flow.log", alloc, .limited(64 * 1024));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "PRIVATE_CHILD_OUTPUT_DO_NOT_LOG") == null);
    try std.testing.expect(std.mem.find(u8, trace, "πππ") == null);
    var offset: usize = 0;
    for ([_][]const u8{ "child_delivery_reserved", "child_delivery_outcome_synced", "child_delivery_receipt_retired" }) |event| {
        const expected = try std.fmt.allocPrint(alloc, "event={s} turn_id=1 root_id=parent child_id=child work_id=work-a delivery_id=delivery-a", .{event});
        defer alloc.free(expected);
        const next = std.mem.find(u8, trace[offset..], expected) orelse return error.MissingDeliveryContractTrace;
        offset += next + expected.len;
        try std.testing.expect(std.mem.find(u8, trace[offset..], expected) == null);
    }
}
