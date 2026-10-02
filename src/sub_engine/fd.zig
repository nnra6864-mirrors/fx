//! The fd helpers the terminal and the pool share.

const std = @import("std");
const builtin = @import("builtin");

pub const fd_t = std.posix.fd_t;

pub fn close(fd: fd_t) void {
    _ = std.c.close(fd);
}

pub const Pipe = struct { read: fd_t, write: fd_t };

/// A close-on-exec pipe. Each end is non-blocking when asked.
pub fn pipe(options: struct {
    read_nonblocking: bool = false,
    write_nonblocking: bool = false,
}) error{PipeUnavailable}!Pipe {
    var fds: [2]fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeUnavailable;
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }
    for (fds, [_]bool{ options.read_nonblocking, options.write_nonblocking }) |end, nonblocking| {
        setFlags(end, nonblocking) catch return error.PipeUnavailable;
    }
    return .{ .read = fds[0], .write = fds[1] };
}

pub const Pair = struct { parent: fd_t, child: fd_t };

/// A connected pair of close-on-exec stream sockets. The parent's end is
/// non-blocking, and `send` on it never raises SIGPIPE.
pub fn socketPair() error{SocketUnavailable}!Pair {
    var fds: [2]fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketUnavailable;
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }
    setFlags(fds[0], true) catch return error.SocketUnavailable;
    setFlags(fds[1], false) catch return error.SocketUnavailable;
    // Linux has no such flag; `send` passes MSG_NOSIGNAL instead.
    if (comptime builtin.os.tag.isDarwin()) {
        if (std.c.fcntl(fds[0], std.c.F.SETNOSIGPIPE, @as(c_int, 1)) < 0) return error.SocketUnavailable;
    }
    return .{ .parent = fds[0], .child = fds[1] };
}

/// send(2) on a socket from `socketPair`, failing with EPIPE rather than
/// raising SIGPIPE when the other end is closed.
pub fn send(fd: fd_t, bytes: []const u8) isize {
    const flags: u32 = if (comptime builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0;
    return std.c.send(fd, bytes.ptr, bytes.len, flags);
}

fn setFlags(fd: fd_t, nonblocking: bool) error{FcntlFailed}!void {
    if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.FcntlFailed;
    if (!nonblocking) return;
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    const nonblock: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.FcntlFailed;
}

test "a pipe is close-on-exec and non-blocking where asked" {
    const ends = try pipe(.{ .read_nonblocking = true });
    defer close(ends.read);
    defer close(ends.write);
    for ([_]fd_t{ ends.read, ends.write }) |end| {
        try std.testing.expect(std.c.fcntl(end, std.c.F.GETFD, @as(c_int, 0)) & std.c.FD_CLOEXEC != 0);
    }
    const nonblock: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    try std.testing.expect(std.c.fcntl(ends.read, std.c.F.GETFL, @as(c_int, 0)) & nonblock != 0);
    try std.testing.expect(std.c.fcntl(ends.write, std.c.F.GETFL, @as(c_int, 0)) & nonblock == 0);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, -1), std.c.read(ends.read, &byte, 1));
    try std.testing.expectEqual(std.c.E.AGAIN, std.c.errno(@as(c_int, -1)));
}
