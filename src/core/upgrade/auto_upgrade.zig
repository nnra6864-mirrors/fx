const std = @import("std");
const io_mod = @import("../shared/io.zig");
const helpers = @import("upgrade_helpers.zig");
const update_target = @import("update_target.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

const check_interval_ms: u64 = 30 * 60 * 1000;
const initial_delay_ms: u64 = 10_000;

pub const State = enum(u8) {
    idle = 0,
    checking = 1,
    waiting = 2,
    downloading = 3,
    ready = 4,
    failed = 5,
};

pub const RelaunchRequest = struct {
    executable_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    executable_path_len: usize = 0,
    previous_revision_buf: [update_target.max_revision_bytes]u8 = undefined,
    previous_revision_len: u8 = 0,

    pub fn executablePath(self: *const RelaunchRequest) []const u8 {
        return self.executable_path_buf[0..self.executable_path_len];
    }

    pub fn previousRevision(self: *const RelaunchRequest) ?[]const u8 {
        if (self.previous_revision_len == 0) return null;
        return self.previous_revision_buf[0..self.previous_revision_len];
    }
};

pub fn shouldEnableForCurrentExecutable() bool {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io_mod.getIo(), &exe_buf) catch return true;
    return !isDevelopmentBuildPath(exe_buf[0..n]);
}

pub fn isDevelopmentBuildPath(path: []const u8) bool {
    return std.mem.find(u8, path, "/zig-out/bin/") != null or
        std.mem.find(u8, path, "\\zig-out\\bin\\") != null;
}

pub const AutoUpgrade = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.idle)),
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    render_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Io.Future(void) = null,

    version_mutex: std.Io.Mutex = .init,
    latest_version_buf: [64]u8 = undefined,
    latest_version_len: u8 = 0,
    previous_revision_buf: [update_target.max_revision_bytes]u8 = undefined,
    previous_revision_len: u8 = 0,

    selected_channel: update_target.Channel = .stable,

    relaunch_request: ?RelaunchRequest = null,

    pub fn configure_channel(self: *AutoUpgrade, selected: update_target.Channel) void {
        self.selected_channel = selected;
    }

    pub fn channel(self: *const AutoUpgrade) update_target.Channel {
        return self.selected_channel;
    }

    pub fn start(
        self: *AutoUpgrade,
        alloc: Allocator,
        current: update_target.CurrentBuild,
    ) void {
        self.setPreviousRevision(current.revision);
        self.thread = std.Io.concurrent(io_mod.getIo(), runLoop, .{ self, alloc, current }) catch return;
    }

    pub fn stop(self: *AutoUpgrade) void {
        self.should_stop.store(true, .release);
        if (self.thread) |*t| {
            t.cancel(io_mod.getIo());
            self.thread = null;
        }
    }

    pub fn getState(self: *const AutoUpgrade) State {
        return @enumFromInt(self.state.load(.acquire));
    }

    pub fn requestRelaunch(self: *AutoUpgrade, executable_path: []const u8) !void {
        if (executable_path.len > std.fs.max_path_bytes) return error.NameTooLong;
        var request = RelaunchRequest{
            .executable_path_len = executable_path.len,
        };
        @memcpy(
            request.executable_path_buf[0..executable_path.len],
            executable_path,
        );
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        if (self.selected_channel == .dev and self.previous_revision_len > 0) {
            @memcpy(
                request.previous_revision_buf[0..self.previous_revision_len],
                self.previous_revision_buf[0..self.previous_revision_len],
            );
            request.previous_revision_len = self.previous_revision_len;
        }
        self.relaunch_request = request;
    }

    pub fn takeRelaunchRequest(self: *AutoUpgrade) ?RelaunchRequest {
        const request = self.relaunch_request;
        self.relaunch_request = null;
        return request;
    }

    pub fn statusLabel(self: *AutoUpgrade, buf: []u8) []const u8 {
        const state = self.getState();
        switch (state) {
            .downloading => {
                var ver_buf: [32]u8 = undefined;
                const ver = self.getLatestVersion(&ver_buf);
                return std.fmt.bufPrint(buf, "upgrading to {s}...", .{ver}) catch "";
            },
            .ready => return "update ready: ctrl+g to reload",
            .failed => return "upgrade failed",
            else => return "",
        }
    }

    pub fn takeRenderDirty(self: *AutoUpgrade) bool {
        return self.render_dirty.swap(false, .acq_rel);
    }

    fn getLatestVersion(self: *AutoUpgrade, out: []u8) []const u8 {
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        const len = self.latest_version_len;
        if (len == 0) return "";
        const n: usize = @min(len, out.len);
        @memcpy(out[0..n], self.latest_version_buf[0..n]);
        return out[0..n];
    }

    fn setState(self: *AutoUpgrade, state: State) void {
        const next = @intFromEnum(state);
        const previous = self.state.swap(next, .acq_rel);
        if (previous != next) self.markRenderDirty();
    }

    fn setPreviousRevision(self: *AutoUpgrade, revision: []const u8) void {
        const valid = update_target.isValidRevision(revision);
        const len: u8 = if (valid) @intCast(revision.len) else 0;
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        if (len > 0) @memcpy(self.previous_revision_buf[0..len], revision);
        self.previous_revision_len = len;
    }

    fn setLatestVersion(self: *AutoUpgrade, version: []const u8) void {
        const stripped = update_target.normalizeVersion(version);
        const len: u8 = @intCast(@min(stripped.len, 32));
        self.version_mutex.lockUncancelable(io_mod.getIo());
        defer self.version_mutex.unlock(io_mod.getIo());
        @memcpy(self.latest_version_buf[0..len], stripped[0..len]);
        self.latest_version_len = len;
        self.markRenderDirty();
    }

    fn markRenderDirty(self: *AutoUpgrade) void {
        self.render_dirty.store(true, .release);
    }

    fn runLoop(
        self: *AutoUpgrade,
        alloc: Allocator,
        current: update_target.CurrentBuild,
    ) void {
        io_mod.getIo().sleep(.fromMilliseconds(initial_delay_ms), .awake) catch return;

        while (!self.should_stop.load(.acquire)) {
            if (self.getState() == .ready) return;
            self.setState(.checking);
            self.runOnce(alloc, current);

            const post_state = self.getState();
            if (post_state == .ready) return;

            if (post_state != .failed) self.setState(.waiting);
            if (self.should_stop.load(.acquire)) return;
            io_mod.getIo().sleep(.fromMilliseconds(check_interval_ms), .awake) catch return;
        }
    }

    fn runOnce(
        self: *AutoUpgrade,
        alloc: Allocator,
        current: update_target.CurrentBuild,
    ) void {
        const cdn_base = helpers.resolveCdnBase();
        var target = helpers.fetchTarget(alloc, self.selected_channel, cdn_base) catch return;
        defer target.deinit(alloc);

        if (!target.shouldInstall(current)) return;

        var label_buf: [64]u8 = undefined;
        const label = target.writeDisplayLabel(&label_buf) catch return;
        self.setLatestVersion(label);
        self.setState(.downloading);

        self.downloadAndInstall(alloc, target, cdn_base) catch {
            self.setState(.failed);
            return;
        };
        self.setState(.ready);
    }

    const InstallError = error{
        AllocFailed,
        DownloadFailed,
        ChecksumFailed,
        ExtractionFailed,
        SelfExeNotFound,
        InstallFailed,
        Cancelled,
    };

    fn downloadAndInstall(
        self: *AutoUpgrade,
        alloc: Allocator,
        target: update_target.Target,
        cdn_base: []const u8,
    ) InstallError!void {
        var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
        defer client.deinit();

        const tmp_base: []const u8 = io_mod.getenv("TMPDIR") orelse "/tmp";
        var rand_buf: [8]u8 = undefined;
        io_mod.getIo().random(&rand_buf);
        const rand_hex = std.fmt.bytesToHex(rand_buf, .lower);
        const tmp_dir = std.fmt.allocPrint(alloc, "{s}/fx-auto-upgrade-{s}", .{ tmp_base, rand_hex }) catch return error.AllocFailed;
        defer alloc.free(tmp_dir);
        defer self.cleanupTemporary(tmp_dir);

        std.Io.Dir.createDirAbsolute(io_mod.getIo(), tmp_dir, .default_dir) catch return error.ExtractionFailed;

        const archive_path = std.fmt.allocPrint(alloc, "{s}/fx.tar.gz", .{tmp_dir}) catch return error.AllocFailed;
        defer alloc.free(archive_path);

        const archive_url = std.fmt.allocPrint(alloc, "{s}/{s}/fx-{s}.tar.gz", .{ cdn_base, target.artifactRef(), helpers.platform }) catch return error.AllocFailed;
        defer alloc.free(archive_url);

        helpers.downloadFileStreaming(&client, archive_url, archive_path) catch return error.DownloadFailed;

        if (self.should_stop.load(.acquire)) return error.Cancelled;

        const checksum_url = std.fmt.allocPrint(alloc, "{s}/{s}/fx-{s}.tar.gz.sha256", .{ cdn_base, target.artifactRef(), helpers.platform }) catch return error.AllocFailed;
        defer alloc.free(checksum_url);

        helpers.verifyChecksum(&client, archive_path, checksum_url) catch return error.ChecksumFailed;

        if (self.should_stop.load(.acquire)) return error.Cancelled;

        helpers.extractTarGz(alloc, archive_path, tmp_dir) catch return error.ExtractionFailed;

        if (self.should_stop.load(.acquire)) return error.Cancelled;

        const extracted_bin = std.fmt.allocPrint(alloc, "{s}/fx", .{tmp_dir}) catch return error.AllocFailed;
        defer alloc.free(extracted_bin);

        var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_exe = helpers.currentExecutablePath(&self_exe_buf) catch return error.SelfExeNotFound;
        io_mod.copyFileAtomic(alloc, extracted_bin, self_exe) catch return error.InstallFailed;
    }

    fn cleanupTemporary(self: *const AutoUpgrade, path: []const u8) void {
        if (self.should_stop.load(.acquire)) {
            debug_trace.logf("upgrade", "temporary extraction cleanup deferred reason=shutdown path={s}", .{path});
            return;
        }
        std.Io.Dir.cwd().deleteTree(io_mod.getIo(), path) catch {};
    }
};

test "statusLabel idle returns empty" {
    var au = AutoUpgrade{};
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqual(@as(usize, 0), label.len);
}

test "upgrade stop cancels a download after the response body begins" {
    try testUpgradeStop(false, false);
}

test "upgrade stop leaves temporary cleanup out of accepted exit" {
    try testUpgradeStop(true, false);
}

test "upgrade stop interrupts checksum after actual artifact reads" {
    if (comptime @import("builtin").os.tag != .macos) return error.SkipZigTest;
    try testUpgradeStop(false, true);
}

fn testUpgradeStop(with_cleanup: bool, checksum: bool) !void {
    const Fixture = struct {
        server: std.Io.net.Server,
        path: []const u8,
        cleanup_path: ?[]const u8 = null,
        upgrader: *AutoUpgrade,
        checksum: bool,
        arrived: std.atomic.Value(bool) = .init(false),
        stop: std.atomic.Value(bool) = .init(false),

        fn serve(self: *@This()) void {
            const io = io_mod.getIo();
            const stream = self.server.accept(io) catch return;
            defer stream.close(io);
            var buf: [4096]u8 = undefined;
            var reader = stream.reader(io, &buf);
            var last: [4]u8 = @splat(0);
            for (0..4096) |_| {
                const byte = reader.interface.takeByte() catch return;
                last = .{ last[1], last[2], last[3], byte };
                if (std.mem.eql(u8, &last, "\r\n\r\n")) break;
            }
            var writer = stream.writer(io, &.{});
            writer.interface.writeAll(if (self.checksum)
                "HTTP/1.1 200 OK\r\nContent-Length: 64\r\n\r\n" ++ "0" ** 64
            else
                "HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\npartial") catch return;
            self.arrived.store(true, .release);
            if (self.checksum) return;
            for (0..100) |_| {
                if (self.stop.load(.acquire)) return;
                io_mod.sleep(10 * std.time.ns_per_ms);
            }
        }

        fn download(self: *@This()) void {
            defer if (self.cleanup_path) |path| self.upgrader.cleanupTemporary(path);
            var url_buf: [96]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/archive", .{self.server.socket.address.getPort()}) catch unreachable;
            var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io_mod.getIo() };
            defer client.deinit();
            if (self.checksum) {
                helpers.verifyChecksum(&client, self.path, url) catch {};
            } else {
                helpers.downloadFileStreaming(&client, url, self.path) catch {};
            }
        }

        fn readStarted(path: []const u8) bool {
            if (comptime @import("builtin").os.tag != .macos) return false;
            for (0..256) |raw_fd| {
                const fd: std.posix.fd_t = @intCast(raw_fd);
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.c.fcntl(fd, 50, &path_buf) != 0) continue;
                const observed = std.mem.sliceTo(&path_buf, 0);
                if (std.mem.eql(u8, observed, path) and std.c.lseek(fd, 0, std.posix.SEEK.CUR) > 0) return true;
            }
            return false;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "archive" });
    defer std.testing.allocator.free(path);
    if (checksum) {
        const file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{});
        defer file.close(io_mod.getIo());
        try file.setLength(io_mod.getIo(), 4 * 1024 * 1024 * 1024);
    }
    try tmp.dir.createDir(io_mod.getIo(), "extraction", .default_dir);
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "extraction/sentinel", .data = "download state" });
    const before = try tmp.dir.statFile(io_mod.getIo(), "extraction/sentinel", .{});
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &.{ root, "extraction" });
    defer std.testing.allocator.free(cleanup_path);
    var au: AutoUpgrade = .{};
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var fixture: Fixture = .{
        .server = try address.listen(io_mod.getIo(), .{}),
        .path = path,
        .cleanup_path = if (with_cleanup) cleanup_path else null,
        .upgrader = &au,
        .checksum = checksum,
    };
    defer fixture.server.deinit(io_mod.getIo());
    const server_thread = try std.Thread.spawn(.{}, Fixture.serve, .{&fixture});
    defer server_thread.join();
    defer fixture.stop.store(true, .release);
    au.thread = try std.Io.concurrent(io_mod.getIo(), Fixture.download, .{&fixture});
    var began = false;
    for (0..5000) |_| {
        began = if (checksum) Fixture.readStarted(path) else fixture.arrived.load(.acquire);
        if (began) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    const arrived = fixture.arrived.load(.acquire);
    const started = io_mod.milliTimestamp();
    au.stop();
    try std.testing.expect(arrived);
    try std.testing.expect(began);
    try std.testing.expect(io_mod.milliTimestamp() - started < 500);
    try std.testing.expect(au.thread == null);
    const after = try tmp.dir.statFile(io_mod.getIo(), "extraction/sentinel", .{});
    try std.testing.expectEqual(before.mtime, after.mtime);
    try std.testing.expectEqual(before.size, after.size);
}

test "selected release channel is owned by the upgrade runtime" {
    var au = AutoUpgrade{};
    try std.testing.expectEqual(update_target.Channel.stable, au.channel());

    au.configure_channel(.dev);
    try std.testing.expectEqual(update_target.Channel.dev, au.channel());
}

test "development build paths disable auto upgrade" {
    try std.testing.expect(isDevelopmentBuildPath("/repo/zig-out/bin/fx"));
    try std.testing.expect(isDevelopmentBuildPath("C:\\repo\\zig-out\\bin\\fx.exe"));
    try std.testing.expect(!isDevelopmentBuildPath("/Users/me/.local/bin/fx"));
}

test "statusLabel downloading shows ellipsis" {
    var au = AutoUpgrade{};
    au.setLatestVersion("v0.3.0");
    au.setState(.downloading);
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqualStrings("upgrading to 0.3.0...", label);
}

test "statusLabel ready explains ctrl+g reload" {
    var au = AutoUpgrade{};
    au.setState(.ready);
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqualStrings("update ready: ctrl+g to reload", label);
}

test "setLatestVersion stores normalized version" {
    var au = AutoUpgrade{};
    _ = au.takeRenderDirty();
    au.setLatestVersion("v1.2.3");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.2.3", au.getLatestVersion(&buf));
    try std.testing.expect(au.takeRenderDirty());
}

test "relaunch request owns its path and previous revision and is consumed once" {
    var au = AutoUpgrade{};
    var path = [_]u8{ '/', 't', 'm', 'p', '/', 'f', 'x' };
    var revision = [_]u8{'1'} ** 40;
    au.configure_channel(.dev);
    au.setPreviousRevision(&revision);
    try au.requestRelaunch(&path);
    path[1] = 'x';
    revision[0] = '2';

    const request = au.takeRelaunchRequest() orelse
        return error.TestExpectedRelaunchRequest;
    try std.testing.expectEqualStrings("/tmp/fx", request.executablePath());
    try std.testing.expectEqualStrings(
        "1111111111111111111111111111111111111111",
        request.previousRevision().?,
    );
    try std.testing.expect(au.takeRelaunchRequest() == null);
}

test "statusLabel waiting returns empty" {
    var au = AutoUpgrade{};
    au.setState(.waiting);
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqual(@as(usize, 0), label.len);
}

test "statusLabel checking returns empty" {
    var au = AutoUpgrade{};
    au.setState(.checking);
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqual(@as(usize, 0), label.len);
}

test "statusLabel failed shows upgrade failed" {
    var au = AutoUpgrade{};
    au.setState(.failed);
    var buf: [64]u8 = undefined;
    const label = au.statusLabel(&buf);
    try std.testing.expectEqualStrings("upgrade failed", label);
}

test "getState returns the current atomic state" {
    var au = AutoUpgrade{};
    try std.testing.expectEqual(State.idle, au.getState());
    try std.testing.expect(!au.takeRenderDirty());
    au.setState(.checking);
    try std.testing.expectEqual(State.checking, au.getState());
    try std.testing.expect(au.takeRenderDirty());
    try std.testing.expect(!au.takeRenderDirty());
    au.setState(.checking);
    try std.testing.expect(!au.takeRenderDirty());
}

test "setLatestVersion truncates to stored capacity" {
    var au = AutoUpgrade{};
    au.setLatestVersion("v1234567890123456789012345678901234567890");

    var buf: [40]u8 = undefined;
    const latest = au.getLatestVersion(&buf);
    try std.testing.expectEqual(@as(usize, 32), latest.len);
    try std.testing.expectEqualStrings("12345678901234567890123456789012", latest);
}
