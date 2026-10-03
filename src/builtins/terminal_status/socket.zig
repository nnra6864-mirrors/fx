//! One newline-delimited request over a short-lived Unix socket connection.
//!
//! Waiting briefly for the peer's one-line reply serializes rapid requests so
//! a later one cannot race ahead of an earlier one. SO_RCVTIMEO bounds the
//! wait, so a hung peer cannot block the publisher.

const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");

const reply_timeout = std.posix.timeval{ .sec = 0, .usec = 250_000 };

/// Sends `line` (which must end in a newline) and returns the peer's reply
/// line without its newline, or an empty slice when no reply arrives in time.
/// The reply borrows `reply_buffer`.
pub fn request(socket_path: []const u8, line: []const u8, reply_buffer: []u8) ![]const u8 {
    const io = io_mod.getIo();
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try address.connect(io);
    defer stream.close(io);
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&reply_timeout),
    ) catch {};

    var write_buffer: [256]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    try stream_writer.interface.writeAll(line);
    try stream_writer.interface.flush();

    var stream_reader = stream.reader(io, reply_buffer);
    return stream_reader.interface.takeDelimiterExclusive('\n') catch "";
}

/// Formats one request line into `buffer`. Lines that do not fit are an error
/// so a truncated command is never sent.
pub fn formatLine(buffer: []u8, comptime write: anytype, args: anytype) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try @call(.auto, write, .{&writer} ++ args);
    return writer.buffered();
}
