//! cmux terminal host: renders foreground status as an `fx` sidebar pill and
//! announces prompts as cmux notifications over cmux's control socket.

const std = @import("std");
const io_mod = @import("../../../core/shared/io.zig");
const debug_trace = @import("../../../core/shared/debug_trace.zig");
const jsonrpc = @import("../../../acp/jsonrpc.zig");
const status_mod = @import("../status.zig");
const socket = @import("../socket.zig");

const Status = status_mod.Status;
const Activity = status_mod.Activity;
const AttentionKind = status_mod.AttentionKind;

/// cmux keys status pills by owner so tools do not overwrite each other.
const status_key = "fx";
const notification_title = "fx";
/// cmux authenticates socket callers with a per-terminal capability token.
const capability_command = "_cmux_capability_v1";

/// Matches the pills cmux renders for its first-party agent integrations.
const Pill = struct {
    /// A single socket token; multi-word values are single-quoted.
    value: []const u8,
    icon: []const u8,
    color: []const u8,
    priority: ?u8 = null,
};

fn pillFor(activity: Activity) Pill {
    return switch (activity) {
        .working => .{ .value = "Running", .icon = "bolt.fill", .color = "#4C8DFF" },
        .idle => .{ .value = "Idle", .icon = "pause.circle.fill", .color = "#8E8E93" },
        .waiting => .{ .value = "'Needs input'", .icon = "bell.fill", .color = "#4C8DFF", .priority = 100 },
        .failed => .{ .value = "Error", .icon = "exclamationmark.triangle.fill", .color = "#FF453A", .priority = 100 },
    };
}

const Attention = struct {
    subtitle: []const u8,
    body: []const u8,
};

/// Notification text never includes prompts, tool arguments, or output.
fn attentionText(kind: AttentionKind) Attention {
    return switch (kind) {
        .permission => .{ .subtitle = "Permission needed", .body = "fx is waiting for approval" },
        .question => .{ .subtitle = "Question", .body = "fx is waiting for your answer" },
        .recovery => .{ .subtitle = "Needs attention", .body = "fx needs a decision to continue" },
    };
}

const Request = union(enum) {
    set_status: Activity,
    clear_status,
    notify: struct { id: u64, kind: AttentionKind },
};

pub const Host = struct {
    alloc: std.mem.Allocator,
    socket_path: []u8,
    workspace_id: []u8,
    /// Empty when cmux runs without socket capabilities.
    capability: []u8,
    next_id: u64 = 1,

    /// Workspace ids and capability tokens are written verbatim into the
    /// socket line, so anything outside a conservative token alphabet disables
    /// the host instead of risking a malformed command.
    pub fn shouldEnable(
        fx_cmux: ?[]const u8,
        socket_path: ?[]const u8,
        workspace_id: ?[]const u8,
        capability: ?[]const u8,
    ) bool {
        if (fx_cmux) |val| {
            if (std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "false")) return false;
        }
        const path = socket_path orelse return false;
        const workspace = workspace_id orelse return false;
        if (path.len == 0 or !isSocketToken(workspace)) return false;
        if (capability) |token| {
            if (token.len > 0 and !isSocketToken(token)) return false;
        }
        return true;
    }

    pub fn detect(alloc: std.mem.Allocator) ?Host {
        const socket_path = io_mod.getenv("CMUX_SOCKET_PATH");
        const workspace_id = io_mod.getenv("CMUX_WORKSPACE_ID");
        const capability = io_mod.getenv("CMUX_SOCKET_CAPABILITY");
        if (!shouldEnable(io_mod.getenv("FX_CMUX"), socket_path, workspace_id, capability)) return null;
        const path_copy = alloc.dupe(u8, socket_path.?) catch return null;
        const workspace_copy = alloc.dupe(u8, workspace_id.?) catch {
            alloc.free(path_copy);
            return null;
        };
        const capability_copy = alloc.dupe(u8, capability orelse "") catch {
            alloc.free(path_copy);
            alloc.free(workspace_copy);
            return null;
        };
        debug_trace.logf("cmux", "enabled socket={s} workspace={s}", .{ path_copy, workspace_copy });
        return .{ .alloc = alloc, .socket_path = path_copy, .workspace_id = workspace_copy, .capability = capability_copy };
    }

    pub fn deinit(self: *Host) void {
        self.alloc.free(self.socket_path);
        self.alloc.free(self.workspace_id);
        self.alloc.free(self.capability);
    }

    pub fn render(self: *Host, prev: ?Status, now: Status) void {
        const pill_changed = if (prev) |previous| previous.activity != now.activity else true;
        if (pill_changed) self.send(.{ .set_status = now.activity });
        if (status_mod.enteredWaiting(prev, now)) |kind| {
            self.send(.{ .notify = .{ .id = self.next_id, .kind = kind } });
            self.next_id += 1;
        }
    }

    /// Removes fx's pill on exit.
    pub fn stop(self: *Host) void {
        self.send(.clear_status);
    }

    fn send(self: *Host, request: Request) void {
        var line_buffer: [1024]u8 = undefined;
        const line = socket.formatLine(&line_buffer, writeRequest, .{ self.capability, self.workspace_id, request }) catch |err| {
            debug_trace.logf("cmux", "format failed kind={s} err={s}", .{ @tagName(request), @errorName(err) });
            return;
        };
        var reply_buffer: [512]u8 = undefined;
        const reply = socket.request(self.socket_path, line, &reply_buffer) catch |err| {
            debug_trace.logf("cmux", "send failed kind={s} err={s}", .{ @tagName(request), @errorName(err) });
            return;
        };
        if (replyIsError(reply)) {
            debug_trace.logf("cmux", "rejected {s} reply={s}", .{ @tagName(request), reply });
            return;
        }
        debug_trace.logf("cmux", "sent {s}", .{@tagName(request)});
    }
};

fn isSocketToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ':')) return false;
    }
    return true;
}

/// Text commands reply `ERROR: ...`; JSON-RPC commands reply `"ok":false`.
fn replyIsError(reply: []const u8) bool {
    return std.mem.startsWith(u8, reply, "ERROR") or std.mem.find(u8, reply, "\"ok\":false") != null;
}

fn writeRequest(w: *std.Io.Writer, capability: []const u8, workspace_id: []const u8, request: Request) !void {
    if (capability.len > 0) try w.print("{s} {s} ", .{ capability_command, capability });
    switch (request) {
        .set_status => |activity| {
            const pill = pillFor(activity);
            try w.print("set_status {s} {s} --icon={s} --color={s}", .{ status_key, pill.value, pill.icon, pill.color });
            if (pill.priority) |priority| try w.print(" --priority={d}", .{priority});
            try w.print(" --tab={s}\n", .{workspace_id});
        },
        .clear_status => try w.print("clear_status {s} --tab={s}\n", .{ status_key, workspace_id }),
        .notify => |notify| {
            const text = attentionText(notify.kind);
            try w.print("{{\"id\":\"fx-{d}\",\"method\":\"notification.create_for_caller\",\"params\":{{", .{notify.id});
            try w.writeAll("\"prefer_tty\":false,\"preferred_workspace_id\":");
            try jsonrpc.writeJsonStr(workspace_id, w);
            try w.writeAll(",\"title\":");
            try jsonrpc.writeJsonStr(notification_title, w);
            try w.writeAll(",\"subtitle\":");
            try jsonrpc.writeJsonStr(text.subtitle, w);
            try w.writeAll(",\"body\":");
            try jsonrpc.writeJsonStr(text.body, w);
            try w.writeAll("}}\n");
        },
    }
}

const test_workspace = "E68D9717-EEEC-49AB-B02C-0627C8983155";

fn expectLine(expected: []const u8, capability: []const u8, request: Request) !void {
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try socket.formatLine(&buffer, writeRequest, .{ capability, test_workspace, request }));
}

test "shouldEnable requires a socket path and a safe workspace id and honors FX_CMUX" {
    try std.testing.expect(Host.shouldEnable(null, "/tmp/cmux.sock", test_workspace, null));
    try std.testing.expect(!Host.shouldEnable(null, null, test_workspace, null));
    try std.testing.expect(!Host.shouldEnable(null, "/tmp/cmux.sock", null, null));
    try std.testing.expect(!Host.shouldEnable(null, "", test_workspace, null));
    try std.testing.expect(!Host.shouldEnable("0", "/tmp/cmux.sock", test_workspace, null));
    try std.testing.expect(!Host.shouldEnable("FALSE", "/tmp/cmux.sock", test_workspace, null));
    try std.testing.expect(Host.shouldEnable("1", "/tmp/cmux.sock", test_workspace, null));
    try std.testing.expect(!Host.shouldEnable(null, "/tmp/cmux.sock", "ws 1", null));
    try std.testing.expect(!Host.shouldEnable(null, "/tmp/cmux.sock", "ws\n1", null));
    try std.testing.expect(!Host.shouldEnable(null, "/tmp/cmux.sock", test_workspace, "tok en"));
    try std.testing.expect(Host.shouldEnable(null, "/tmp/cmux.sock", "workspace:2", "v1.abc_DEF-1.x"));
    try std.testing.expect(Host.shouldEnable(null, "/tmp/cmux.sock", test_workspace, ""));
}

test "set_status serializes each activity as one capability-prefixed line" {
    const prefix = "_cmux_capability_v1 v1.tok set_status fx ";
    const tab = " --tab=" ++ test_workspace ++ "\n";
    try expectLine(prefix ++ "Running --icon=bolt.fill --color=#4C8DFF" ++ tab, "v1.tok", .{ .set_status = .working });
    try expectLine(prefix ++ "Idle --icon=pause.circle.fill --color=#8E8E93" ++ tab, "v1.tok", .{ .set_status = .idle });
    try expectLine(prefix ++ "'Needs input' --icon=bell.fill --color=#4C8DFF --priority=100" ++ tab, "v1.tok", .{ .set_status = .waiting });
    try expectLine(prefix ++ "Error --icon=exclamationmark.triangle.fill --color=#FF453A --priority=100" ++ tab, "v1.tok", .{ .set_status = .failed });
}

test "clear_status omits the capability prefix when cmux has none" {
    try expectLine("clear_status fx --tab=" ++ test_workspace ++ "\n", "", .clear_status);
}

test "notify serializes an attention notification without user content" {
    try expectLine(
        "{\"id\":\"fx-3\",\"method\":\"notification.create_for_caller\",\"params\":{" ++
            "\"prefer_tty\":false,\"preferred_workspace_id\":\"" ++ test_workspace ++ "\"," ++
            "\"title\":\"fx\",\"subtitle\":\"Permission needed\",\"body\":\"fx is waiting for approval\"}}\n",
        "",
        .{ .notify = .{ .id = 3, .kind = .permission } },
    );
}

test "replyIsError detects text and JSON-RPC failures" {
    try std.testing.expect(!replyIsError("OK"));
    try std.testing.expect(!replyIsError(""));
    try std.testing.expect(!replyIsError("{\"ok\":true,\"id\":\"fx-1\"}"));
    try std.testing.expect(replyIsError("ERROR: Unknown command 'x'"));
    try std.testing.expect(replyIsError("{\"ok\":false,\"error\":{}}"));
}
