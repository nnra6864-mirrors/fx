//! herdr agent multiplexer host: renders foreground status as herdr's pane
//! agent state over its JSON-RPC Unix socket.

const std = @import("std");
const io_mod = @import("../../../core/shared/io.zig");
const debug_trace = @import("../../../core/shared/debug_trace.zig");
const jsonrpc = @import("../../../acp/jsonrpc.zig");
const status_mod = @import("../status.zig");
const socket = @import("../socket.zig");

const Status = status_mod.Status;

// herdr protocol limits custom status to 32 bytes.
const custom_status_max = 32;
// Third-party reporters use the `custom:` source prefix.
const source = "custom:fx";
const agent_name = "fx";

const WireState = enum { idle, working, blocked };

const Wire = struct {
    state: WireState,
    custom_status: ?[]const u8,

    fn eql(a: Wire, b: Wire) bool {
        if (a.state != b.state) return false;
        const left = a.custom_status orelse return b.custom_status == null;
        return std.mem.eql(u8, left, b.custom_status orelse return false);
    }
};

/// herdr has no failure state; a failed turn shows as idle.
fn wireFor(status: Status) Wire {
    return switch (status.activity) {
        .idle, .failed => .{ .state = .idle, .custom_status = null },
        .working => .{ .state = .working, .custom_status = null },
        .waiting => .{ .state = .blocked, .custom_status = if (status.attention) |kind| switch (kind) {
            .permission => "permission",
            .question => "question",
            .recovery => "recovery",
        } else null },
    };
}

const Request = union(enum) {
    report: Wire,
    session: []const u8,
    /// null clears the pane label.
    pane_rename: ?[]const u8,
    /// null clears the agent name.
    agent_rename: ?[]const u8,
    clear_authority,
};

pub const Host = struct {
    alloc: std.mem.Allocator,
    socket_path: []u8,
    pane_id: []u8,
    next_id: u64 = 1,

    pub fn shouldEnable(fx_herdr: ?[]const u8, socket_path: ?[]const u8, pane_id: ?[]const u8) bool {
        if (fx_herdr) |val| {
            if (std.mem.eql(u8, val, "0") or std.ascii.eqlIgnoreCase(val, "false")) return false;
        }
        const path = socket_path orelse return false;
        const pane = pane_id orelse return false;
        return path.len > 0 and pane.len > 0;
    }

    pub fn detect(alloc: std.mem.Allocator) ?Host {
        const socket_path = io_mod.getenv("HERDR_SOCKET_PATH");
        const pane_id = io_mod.getenv("HERDR_PANE_ID");
        if (!shouldEnable(io_mod.getenv("FX_HERDR"), socket_path, pane_id)) return null;
        const path_copy = alloc.dupe(u8, socket_path.?) catch return null;
        const pane_copy = alloc.dupe(u8, pane_id.?) catch {
            alloc.free(path_copy);
            return null;
        };
        debug_trace.logf("herdr", "enabled socket={s} pane_id={s}", .{ path_copy, pane_copy });
        return .{ .alloc = alloc, .socket_path = path_copy, .pane_id = pane_copy };
    }

    pub fn deinit(self: *Host) void {
        self.alloc.free(self.socket_path);
        self.alloc.free(self.pane_id);
    }

    /// The first render also names the pane so herdr lists fx while idle.
    pub fn render(self: *Host, prev: ?Status, now: Status) void {
        const previous = prev orelse {
            if (now.session) |*session| self.send(.{ .session = session.slice() });
            self.send(.{ .report = wireFor(now) });
            self.send(.{ .pane_rename = agent_name });
            self.send(.{ .agent_rename = agent_name });
            return;
        };
        if (!status_mod.SessionId.eql(previous.session, now.session)) {
            if (now.session) |*session| self.send(.{ .session = session.slice() });
        }
        const wire = wireFor(now);
        if (!wire.eql(wireFor(previous))) self.send(.{ .report = wire });
    }

    /// Removes fx from the pane so it does not keep showing "fx" after exit.
    pub fn stop(self: *Host) void {
        self.send(.{ .agent_rename = null });
        self.send(.clear_authority);
        self.send(.{ .pane_rename = null });
    }

    fn send(self: *Host, request: Request) void {
        var line_buffer: [1024]u8 = undefined;
        const id = self.next_id;
        self.next_id += 1;
        const line = socket.formatLine(&line_buffer, writeRequest, .{ id, self.pane_id, request }) catch |err| {
            debug_trace.logf("herdr", "format failed kind={s} err={s}", .{ @tagName(request), @errorName(err) });
            return;
        };
        var reply_buffer: [512]u8 = undefined;
        _ = socket.request(self.socket_path, line, &reply_buffer) catch |err| {
            debug_trace.logf("herdr", "send failed kind={s} err={s}", .{ @tagName(request), @errorName(err) });
            return;
        };
        debug_trace.logf("herdr", "sent {s} pane_id={s}", .{ @tagName(request), self.pane_id });
    }
};

fn writeRequest(w: *std.Io.Writer, id: u64, pane_id: []const u8, request: Request) !void {
    switch (request) {
        .report => |wire| try writeReportAgent(w, id, pane_id, wire.state, wire.custom_status),
        .session => |session_id| try writeReportAgentSession(w, id, pane_id, session_id),
        .pane_rename => |label| try writeRename(w, id, "pane.rename", "pane_id", pane_id, "label", label),
        .agent_rename => |name| try writeRename(w, id, "agent.rename", "target", pane_id, "name", name),
        .clear_authority => try writeClearAuthority(w, id, pane_id),
    }
}

fn clampStatus(custom_status: ?[]const u8) ?[]const u8 {
    const status = custom_status orelse return null;
    if (status.len == 0) return null;
    return status[0..@min(status.len, custom_status_max)];
}

/// herdr's JSON-RPC requires the request id to be a string, not a number.
fn writeId(w: *std.Io.Writer, id: u64) !void {
    try w.print("{{\"id\":\"{d}\"", .{id});
}

fn writeReportAgent(w: *std.Io.Writer, id: u64, pane_id: []const u8, state: WireState, custom_status: ?[]const u8) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":");
    try jsonrpc.writeJsonStr(pane_id, w);
    try w.writeAll(",\"source\":");
    try jsonrpc.writeJsonStr(source, w);
    try w.writeAll(",\"agent\":");
    try jsonrpc.writeJsonStr(agent_name, w);
    try w.writeAll(",\"state\":");
    try jsonrpc.writeJsonStr(@tagName(state), w);
    if (clampStatus(custom_status)) |status| {
        try w.writeAll(",\"custom_status\":");
        try jsonrpc.writeJsonStr(status, w);
    }
    try w.writeAll("}}\n");
}

fn writeReportAgentSession(w: *std.Io.Writer, id: u64, pane_id: []const u8, session_id: []const u8) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":\"pane.report_agent_session\",\"params\":{\"pane_id\":");
    try jsonrpc.writeJsonStr(pane_id, w);
    try w.writeAll(",\"source\":");
    try jsonrpc.writeJsonStr(source, w);
    try w.writeAll(",\"agent\":");
    try jsonrpc.writeJsonStr(agent_name, w);
    try w.writeAll(",\"agent_session_id\":");
    try jsonrpc.writeJsonStr(session_id, w);
    try w.writeAll("}}\n");
}

fn writeRename(
    w: *std.Io.Writer,
    id: u64,
    method: []const u8,
    target_key: []const u8,
    target: []const u8,
    value_key: []const u8,
    value: ?[]const u8,
) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":");
    try jsonrpc.writeJsonStr(method, w);
    try w.writeAll(",\"params\":{");
    try jsonrpc.writeJsonStr(target_key, w);
    try w.writeAll(":");
    try jsonrpc.writeJsonStr(target, w);
    try w.writeAll(",");
    try jsonrpc.writeJsonStr(value_key, w);
    try w.writeAll(":");
    if (value) |v| try jsonrpc.writeJsonStr(v, w) else try w.writeAll("null");
    try w.writeAll("}}\n");
}

fn writeClearAuthority(w: *std.Io.Writer, id: u64, pane_id: []const u8) !void {
    try writeId(w, id);
    try w.writeAll(",\"method\":\"pane.clear_agent_authority\",\"params\":{\"pane_id\":");
    try jsonrpc.writeJsonStr(pane_id, w);
    try w.writeAll(",\"source\":");
    try jsonrpc.writeJsonStr(source, w);
    try w.writeAll("}}\n");
}

fn expectLine(expected: []const u8, request: Request, id: u64) !void {
    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try socket.formatLine(&buffer, writeRequest, .{ id, "w1:p1", request }));
}

test "shouldEnable requires both socket path and pane id and honors FX_HERDR" {
    try std.testing.expect(Host.shouldEnable(null, "/tmp/herdr.sock", "w1:p1"));
    try std.testing.expect(!Host.shouldEnable(null, null, "w1:p1"));
    try std.testing.expect(!Host.shouldEnable(null, "/tmp/herdr.sock", null));
    try std.testing.expect(!Host.shouldEnable(null, "", "w1:p1"));
    try std.testing.expect(!Host.shouldEnable(null, "/tmp/herdr.sock", ""));
    try std.testing.expect(!Host.shouldEnable("0", "/tmp/herdr.sock", "w1:p1"));
    try std.testing.expect(!Host.shouldEnable("FALSE", "/tmp/herdr.sock", "w1:p1"));
    try std.testing.expect(Host.shouldEnable("1", "/tmp/herdr.sock", "w1:p1"));
}

test "status maps to herdr wire states" {
    try std.testing.expect(wireFor(.{ .activity = .idle }).eql(.{ .state = .idle, .custom_status = null }));
    try std.testing.expect(wireFor(.{ .activity = .failed }).eql(.{ .state = .idle, .custom_status = null }));
    try std.testing.expect(wireFor(.{ .activity = .working }).eql(.{ .state = .working, .custom_status = null }));
    try std.testing.expect(wireFor(.{ .activity = .waiting, .attention = .question }).eql(.{ .state = .blocked, .custom_status = "question" }));
    try std.testing.expect(!wireFor(.{ .activity = .waiting, .attention = .question }).eql(wireFor(.{ .activity = .waiting, .attention = .permission })));
}

test "herdr requests serialize as newline-delimited JSON-RPC" {
    try expectLine(
        "{\"id\":\"7\",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"state\":\"blocked\",\"custom_status\":\"permission\"}}\n",
        .{ .report = .{ .state = .blocked, .custom_status = "permission" } },
        7,
    );
    try expectLine(
        "{\"id\":\"1\",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"state\":\"idle\"}}\n",
        .{ .report = .{ .state = .idle, .custom_status = null } },
        1,
    );
    try expectLine(
        "{\"id\":\"3\",\"method\":\"pane.report_agent_session\",\"params\":{\"pane_id\":\"w1:p1\"," ++
            "\"source\":\"custom:fx\",\"agent\":\"fx\",\"agent_session_id\":\"session-42\"}}\n",
        .{ .session = "session-42" },
        3,
    );
    try expectLine("{\"id\":\"4\",\"method\":\"pane.rename\",\"params\":{\"pane_id\":\"w1:p1\",\"label\":\"fx\"}}\n", .{ .pane_rename = "fx" }, 4);
    try expectLine("{\"id\":\"5\",\"method\":\"agent.rename\",\"params\":{\"target\":\"w1:p1\",\"name\":\"fx\"}}\n", .{ .agent_rename = "fx" }, 5);
    try expectLine("{\"id\":\"6\",\"method\":\"pane.rename\",\"params\":{\"pane_id\":\"w1:p1\",\"label\":null}}\n", .{ .pane_rename = null }, 6);
    try expectLine(
        "{\"id\":\"7\",\"method\":\"pane.clear_agent_authority\",\"params\":{\"pane_id\":\"w1:p1\",\"source\":\"custom:fx\"}}\n",
        .clear_authority,
        7,
    );
}

test "herdr escapes pane ids and clamps custom status" {
    var buffer: [1024]u8 = undefined;
    const line = try socket.formatLine(&buffer, writeRequest, .{ @as(u64, 2), "pane\"x", Request{ .report = .{ .state = .blocked, .custom_status = null } } });
    try std.testing.expect(std.mem.find(u8, line, "\"pane_id\":\"pane\\\"x\"") != null);
    try std.testing.expect(clampStatus(null) == null);
    try std.testing.expect(clampStatus("") == null);
    try std.testing.expectEqual(@as(usize, custom_status_max), clampStatus("0123456789012345678901234567890123456789").?.len);
}
