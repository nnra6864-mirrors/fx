//! `fx mcp call TOOL [JSON | -]`: runs one of the session's MCP tools from
//! a command that fx's shell tool runs, through the session's bridge
//! (`mcp_call_bridge.zig`). It prints just the tool's data on stdout, so
//! the command can write it to a file or pipe it into `jq`, and only what
//! the command prints reaches the model.
//!
//! The call meets the same permission rules, prompt, and review as a direct
//! call of the tool by the agent that ran the command. It works only while
//! that shell call runs.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const capability_mod = @import("../tooling/mcp_call_capability.zig");
const mcp_call = @import("mcp_call.zig");
const wire = @import("mcp_call_wire.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// What `fx mcp call` exits with.
pub const exit = struct {
    pub const ok: u8 = 0;
    /// The call failed, or the connection to fx was lost.
    pub const failed: u8 = 1;
    /// A usage mistake, as for every `fx mcp` verb.
    pub const usage: u8 = 2;
    /// No running fx shell call to reach: outside fx, after the shell call
    /// ended, or another fx version.
    pub const unavailable: u8 = 3;
    /// Too many calls are running; nothing ran.
    pub const busy: u8 = 4;
    /// Permission was not granted; nothing ran.
    pub const denied: u8 = 5;
    /// The tool ran and returned an error.
    pub const tool_error: u8 = 6;
};

pub const Reply = struct {
    header: wire.Header,
    bytes: []const u8,
};

pub const CallError = error{ MalformedReply, UnsupportedReply, ConnectionLost, OutOfMemory };

/// Sends one call to the bridge at `socket_path` and reads its whole reply.
pub fn call(
    arena: Allocator,
    io: std.Io,
    socket_path: []const u8,
    token: mcp_call.Token,
    tool: []const u8,
    arguments_json: []const u8,
) (CallError || std.Io.net.UnixAddress.ConnectError || std.Io.net.UnixAddress.InitError)!Reply {
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(io);
    defer stream.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    wire.writeRequest(&writer.interface, token, tool, arguments_json) catch return error.ConnectionLost;
    writer.interface.flush() catch return error.ConnectionLost;
    var read_buffer: [wire.max_header_bytes]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = (reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.MalformedReply,
        error.ReadFailed => return error.ConnectionLost,
    }) orelse return error.ConnectionLost;
    const header = try wire.parseHeader(arena, line);
    // A reply carries at most the bridge's result limit and a short message.
    if (header.bytes > capability_mod.max_result_bytes + 64 * 1024) return error.MalformedReply;
    const bytes = reader.interface.readAlloc(arena, @intCast(header.bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EndOfStream, error.ReadFailed => return error.ConnectionLost,
    };
    return .{ .header = header, .bytes = bytes };
}

/// Runs `fx mcp call`. `arguments` is the JSON argument, `-` for stdin, or
/// null for none. Returns the exit code.
pub fn run(arena: Allocator, io: std.Io, out: *Writer, err: *Writer, tool: []const u8, arguments: ?[]const u8) !u8 {
    const arguments_json = blk: {
        const raw = arguments orelse break :blk "{}";
        if (!std.mem.eql(u8, raw, "-")) break :blk raw;
        var stdin_buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(io, &stdin_buffer);
        break :blk stdin.interface.allocRemaining(arena, .limited(wire.max_request_bytes)) catch |e| switch (e) {
            error.StreamTooLong => {
                try err.print("fx mcp call: the arguments on stdin are larger than {d} bytes.\n", .{wire.max_request_bytes});
                return exit.usage;
            },
            else => return e,
        };
    };
    if (!isJsonObject(arena, arguments_json)) {
        try err.writeAll("fx mcp call: the arguments must be one JSON object, such as '{\"team\":\"ENG\"}'.\n");
        return exit.usage;
    }
    const socket_path = io_mod.getenv(wire.socket_env) orelse return unavailable(err);
    const token = wire.parseToken(io_mod.getenv(wire.token_env) orelse "") orelse return unavailable(err);

    const reply = call(arena, io, socket_path, token, tool, arguments_json) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.UnsupportedReply => {
            try err.writeAll("fx mcp call: the running fx session is another fx version.\n");
            return exit.unavailable;
        },
        error.ConnectionLost, error.MalformedReply => {
            try err.print("fx mcp call: the connection to fx was lost ({s}). The call may have run.\n", .{@errorName(e)});
            return exit.failed;
        },
        else => return unavailable(err),
    };
    switch (reply.header.status) {
        .ok => {
            try out.writeAll(reply.bytes);
            return exit.ok;
        },
        .tool_error => {
            try err.print("fx mcp call: {s} returned an error:\n", .{tool});
            try writeLine(err, reply.bytes);
            return exit.tool_error;
        },
        .failed => {
            try err.writeAll("fx mcp call: ");
            try writeLine(err, reply.bytes);
            return exit.failed;
        },
        .denied => {
            try err.print("fx mcp call: {s} did not run. ", .{tool});
            try writeLine(err, reply.bytes);
            return exit.denied;
        },
        .refused => {
            try err.writeAll("fx mcp call: ");
            try writeLine(err, reply.bytes);
            return if (reply.header.reason == .busy) exit.busy else if (reply.header.reason == .malformed or reply.header.reason == .too_large) exit.usage else exit.unavailable;
        },
    }
}

fn unavailable(err: *Writer) !u8 {
    try err.writeAll("fx mcp call: no running fx shell call to reach. It works only in a command that fx's shell tool runs, while that call runs.\n");
    return exit.unavailable;
}

fn writeLine(w: *Writer, text: []const u8) !void {
    try w.writeAll(text);
    if (!std.mem.endsWith(u8, text, "\n")) try w.writeByte('\n');
}

fn isJsonObject(arena: Allocator, text: []const u8) bool {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return false;
    return value == .object;
}

test "fx mcp call outside a shell call reports it is unavailable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var out: std.Io.Writer.Allocating = .init(arena_state.allocator());
    var err: std.Io.Writer.Allocating = .init(arena_state.allocator());
    if (io_mod.getenv(wire.socket_env) != null) return error.SkipZigTest;
    try std.testing.expectEqual(exit.unavailable, try run(arena_state.allocator(), std.testing.io, &out.writer, &err.writer, "mcp_s_t", null));
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    try std.testing.expect(std.mem.find(u8, err.written(), "no running fx shell call") != null);
    try std.testing.expectEqual(exit.usage, try run(arena_state.allocator(), std.testing.io, &out.writer, &err.writer, "mcp_s_t", "[1]"));
}
