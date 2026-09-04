const std = @import("std");
const io_mod = @import("../shared/io.zig");
const cancellation = @import("../shared/read_cancellation.zig");
const layout = @import("session_layout.zig");

const Allocator = std.mem.Allocator;
pub const lock_file = "latest.lock";
pub const index_file = "index.json";
const updates_dir = "updates";
const max_records = 4096;
const private_file = std.Io.File.Permissions.fromMode(0o600);

pub const Identity = struct {
    inode: u128,
    size: u64,
    mtime_ns: i96,
    ctime_ns: i96,
};

/// Holds one immutable index inode while its bytes are parsed outside the lock.
pub const Snapshot = union(enum) {
    missing,
    file: struct { handle: std.Io.File, identity: Identity },

    pub fn deinit(self: *Snapshot) void {
        if (self.* == .file) self.file.handle.close(io_mod.getIo());
        self.* = .missing;
    }

    pub fn identity(self: Snapshot) ?Identity {
        return if (self == .file) self.file.identity else null;
    }
};

pub fn capture(sessions: *const io_mod.VerifiedDir, mode: enum { current, rebuild }) !Snapshot {
    var guard = try readLock(sessions);
    defer guard.release();
    if (mode == .current and try pending(sessions)) return error.SessionIndexChanged;
    return openSnapshot(sessions);
}

fn readLock(sessions: *const io_mod.VerifiedDir) !io_mod.TimedAdvisoryLock {
    var file = io_mod.openExistingRegularFile(sessions.dir, lock_file, .read_only) catch |err| switch (err) {
        error.FileNotFound => return error.SessionIndexNotFound,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    _ = try fileIdentity(file);
    if (!try file.tryLock(io_mod.getIo(), .shared)) return error.SessionIndexChanged;
    return .{ .file = file };
}

fn openSnapshot(sessions: *const io_mod.VerifiedDir) !Snapshot {
    var file = io_mod.openExistingRegularFile(sessions.dir, index_file, .read_only) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    return .{ .file = .{ .handle = file, .identity = try fileIdentity(file) } };
}

fn fileIdentity(file: std.Io.File) !Identity {
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600) return error.InvalidSessionIndex;
    return .{ .inode = @intCast(stat.inode), .size = stat.size, .mtime_ns = stat.mtime.nanoseconds, .ctime_ns = stat.ctime.nanoseconds };
}

fn openUpdates(sessions: *const io_mod.VerifiedDir) !?io_mod.VerifiedDir {
    var latest = sessions.dir.openDir(io_mod.getIo(), "latest", .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer latest.close(io_mod.getIo());
    var dir = latest.openDir(io_mod.getIo(), updates_dir, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer dir.close(io_mod.getIo());
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700) return error.InvalidSessionIndex;
    return .{ .dir = dir };
}

pub fn pending(sessions: *const io_mod.VerifiedDir) !bool {
    var directory = (try openUpdates(sessions)) orelse return false;
    defer directory.close();
    var iter = directory.dir.iterate();
    var visited: usize = 0;
    while (try iter.next(io_mod.getIo())) |entry| {
        visited += 1;
        if (visited > max_records) return error.SessionIndexChanged;
        if (!std.mem.startsWith(u8, entry.name, ".")) return true;
    }
    return false;
}

/// Release ends canonical mutation, but deliberately leaves publication debt.
/// Only a publisher that incorporates this record may unlink it.
pub const Invalidation = struct {
    file: std.Io.File,

    pub fn begin(sessions: *const io_mod.VerifiedDir, session_id: []const u8, cancel_flag: cancellation.CancelFlag) !Invalidation {
        try layout.validateSessionId(session_id);
        try cancellation.check(cancel_flag);
        var parent = sessions.*;
        if (io_mod.acquireTimedAdvisoryLock(&parent, lock_file, 0)) |value| {
            var guard = value;
            guard.release();
        } else |err| switch (err) {
            error.LockBusy => {},
            else => return err,
        }
        var latest = try io_mod.openOrCreateVerifiedPrivateDir(&parent, "latest");
        defer latest.close();
        var directory = try io_mod.openOrCreateVerifiedPrivateDir(&latest, updates_dir);
        defer directory.close();
        var nonce: [16]u8 = undefined;
        io_mod.getIo().random(&nonce);
        const name = std.fmt.bytesToHex(nonce, .lower);
        var temporary: [33]u8 = undefined;
        temporary[0] = '.';
        @memcpy(temporary[1..], &name);
        var file = try directory.dir.createFile(io_mod.getIo(), &temporary, .{ .read = true, .exclusive = true, .permissions = private_file });
        errdefer file.close(io_mod.getIo());
        var published = false;
        defer if (!published) directory.dir.deleteFile(io_mod.getIo(), &temporary) catch {};
        if (!try file.tryLock(io_mod.getIo(), .exclusive)) return error.SessionIndexChanged;
        try file.writeStreamingAll(io_mod.getIo(), session_id);
        try file.sync(io_mod.getIo());
        try cancellation.check(cancel_flag);
        try directory.dir.rename(&temporary, directory.dir, &name, io_mod.getIo());
        published = true;
        try io_mod.syncVerifiedDir(directory.dir);
        return .{ .file = file };
    }

    pub fn release(self: *Invalidation) void {
        self.file.unlock(io_mod.getIo());
        self.file.close(io_mod.getIo());
        self.* = undefined;
    }
};

const CompletedRecord = struct {
    file: std.Io.File,
    identity: Identity,
    name: []u8,
    session_id: []u8,

    fn deinit(self: *CompletedRecord, alloc: Allocator) void {
        self.file.unlock(io_mod.getIo());
        self.file.close(io_mod.getIo());
        alloc.free(self.name);
        alloc.free(self.session_id);
    }
};

pub const Records = struct {
    directory: ?io_mod.VerifiedDir = null,
    items: std.ArrayList(CompletedRecord) = .empty,

    pub fn capture(alloc: Allocator, sessions: *const io_mod.VerifiedDir, cancel_flag: cancellation.CancelFlag) !Records {
        var result = Records{ .directory = try openUpdates(sessions) };
        errdefer result.deinit(alloc);
        var directory = result.directory orelse return result;
        var iter = directory.dir.iterate();
        var visited: usize = 0;
        while (try iter.next(io_mod.getIo())) |entry| {
            try cancellation.check(cancel_flag);
            visited += 1;
            if (visited > max_records) break;
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            var nonce: [16]u8 = undefined;
            if (entry.name.len != 32) return error.InvalidSessionIndex;
            _ = std.fmt.hexToBytes(&nonce, entry.name) catch return error.InvalidSessionIndex;
            var file = try io_mod.openExistingRegularFile(directory.dir, entry.name, .read_only);
            var owned = true;
            defer if (owned) file.close(io_mod.getIo());
            const identity = try fileIdentity(file);
            if (!try file.tryLock(io_mod.getIo(), .exclusive)) continue;
            const id = try io_mod.readFileToEnd(alloc, &file, 256);
            errdefer alloc.free(id);
            try layout.validateSessionId(id);
            const name = try alloc.dupe(u8, entry.name);
            errdefer alloc.free(name);
            try result.items.append(alloc, .{ .file = file, .identity = identity, .name = name, .session_id = id });
            owned = false;
        }
        return result;
    }

    pub fn deinit(self: *Records, alloc: Allocator) void {
        for (self.items.items) |*record| record.deinit(alloc);
        self.items.deinit(alloc);
        if (self.directory) |*dir| dir.close();
        self.* = .{};
    }

    fn retire(self: *Records, cancel_flag: cancellation.CancelFlag) !void {
        var directory = self.directory orelse return;
        for (self.items.items) |record| {
            try cancellation.check(cancel_flag);
            var current = try io_mod.openExistingRegularFile(directory.dir, record.name, .read_only);
            defer current.close(io_mod.getIo());
            if (!std.meta.eql(record.identity, try fileIdentity(current))) return error.SessionIndexChanged;
            try directory.dir.deleteFile(io_mod.getIo(), record.name);
        }
        try io_mod.syncVerifiedDir(directory.dir);
    }
};

/// Staging owns one temporary file, never a live index. The old inode remains
/// pinned by Snapshot until publication has either committed or been rejected.
pub const PreparedIndex = struct {
    name: ?[43]u8,

    pub fn init(sessions: *const io_mod.VerifiedDir, bytes: []const u8, cancel_flag: cancellation.CancelFlag) !PreparedIndex {
        try cancellation.check(cancel_flag);
        if (bytes.len > 16 * 1024 * 1024) return error.InvalidSessionIndex;
        var nonce: [16]u8 = undefined;
        io_mod.getIo().random(&nonce);
        var name: [43]u8 = undefined;
        _ = try std.fmt.bufPrint(&name, ".index-{s}.tmp", .{std.fmt.bytesToHex(nonce, .lower)});
        var file = try sessions.dir.createFile(io_mod.getIo(), &name, .{ .exclusive = true, .permissions = private_file });
        defer file.close(io_mod.getIo());
        errdefer sessions.dir.deleteFile(io_mod.getIo(), &name) catch {};
        try cancellation.writeFileBytes(io_mod.getIo(), file, 0, bytes, cancel_flag);
        try file.sync(io_mod.getIo());
        return .{ .name = name };
    }

    pub fn deinit(self: *PreparedIndex, sessions: *const io_mod.VerifiedDir) void {
        if (self.name) |name| sessions.dir.deleteFile(io_mod.getIo(), &name) catch {};
        self.name = null;
    }

    pub fn publish(self: *PreparedIndex, sessions: *const io_mod.VerifiedDir, expected: Snapshot, records: *Records, cancel_flag: cancellation.CancelFlag) !void {
        try cancellation.check(cancel_flag);
        {
            var parent = sessions.*;
            var guard = try io_mod.acquireTimedAdvisoryLock(&parent, lock_file, 0);
            defer guard.release();
            var current = try openSnapshot(sessions);
            defer current.deinit();
            if (!std.meta.eql(expected.identity(), current.identity())) return error.SessionIndexChanged;
            try cancellation.check(cancel_flag);
            try sessions.dir.rename(&self.name.?, sessions.dir, index_file, io_mod.getIo());
            self.name = null;
            try io_mod.syncVerifiedDir(sessions.dir);
        }
        // Record locks still prevent another publisher from retiring this
        // batch. Until cleanup completes, readers conservatively fall back.
        try records.retire(cancel_flag);
    }
};

test "active records remain unavailable and publication cannot retire later invalidations" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions = io_mod.VerifiedDir{ .dir = tmp.dir };
    var first = try Invalidation.begin(&sessions, "first", null);
    try std.testing.expect(try pending(&sessions));
    var active = try Records.capture(alloc, &sessions, null);
    defer active.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), active.items.items.len);
    first.release();
    var records = try Records.capture(alloc, &sessions, null);
    defer records.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), records.items.items.len);
    var snapshot = try capture(&sessions, .rebuild);
    defer snapshot.deinit();
    var later = try Invalidation.begin(&sessions, "later", null);
    var prepared = try PreparedIndex.init(&sessions, "first index", null);
    defer prepared.deinit(&sessions);
    try prepared.publish(&sessions, snapshot, &records, null);
    try std.testing.expect(try pending(&sessions));
    later.release();
    var remaining = try Records.capture(alloc, &sessions, null);
    defer remaining.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), remaining.items.items.len);
    try std.testing.expectEqualStrings("later", remaining.items.items[0].session_id);
}

test "publication rejects an obsolete captured index and preserves its records" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sessions = io_mod.VerifiedDir{ .dir = tmp.dir };
    var invalidation = try Invalidation.begin(&sessions, "session", null);
    invalidation.release();
    var snapshot = try capture(&sessions, .rebuild);
    defer snapshot.deinit();
    var first = try PreparedIndex.init(&sessions, "newer index", null);
    defer first.deinit(&sessions);
    var empty: Records = .{};
    defer empty.deinit(alloc);
    try first.publish(&sessions, snapshot, &empty, null);
    var stale = try PreparedIndex.init(&sessions, "older index", null);
    defer stale.deinit(&sessions);
    var records = try Records.capture(alloc, &sessions, null);
    defer records.deinit(alloc);
    try std.testing.expectError(error.SessionIndexChanged, stale.publish(&sessions, snapshot, &records, null));
    try std.testing.expect(try pending(&sessions));
    var current = try openSnapshot(&sessions);
    defer current.deinit();
    const bytes = try io_mod.readFileToEnd(alloc, &current.file.handle, 32);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("newer index", bytes);
}
