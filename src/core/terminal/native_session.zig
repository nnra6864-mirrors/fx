const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts.zig");
const terminal_engine = @import("engine.zig");
const shell_resolver = @import("shell_resolver.zig");
const terminal_store = @import("store.zig");
const tmux_session = @import("tmux_session.zig");
const host_capabilities = @import("../hosts/host.zig");
const session_layout = @import("../session/session_layout.zig");
const process_identity = @import("../execution/process_identity.zig");
const managed_execution_contract = @import("../execution/managed_execution_contract.zig");
const process_provider_mod = @import(
    "../execution/process_provider.zig",
);
const process_tree = @import("../execution/process_tree.zig");
const command_admission = @import("../permissions/command_admission.zig");
const command_runner = @import("../execution/command_runner.zig");
const execution_router = @import("../execution/router.zig");
const io_mod = @import("../shared/io.zig");
const self_exe = @import("../shared/self_exe.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const workspace_pathing = @import("../workspace/pathing.zig");
const read_cancellation = @import("../shared/read_cancellation.zig");

const Allocator = std.mem.Allocator;

const launcher_mode = "--fx-internal-terminal-launcher";
const control_mode = "--fx-internal-terminal-control";

const max_sessions = managed_execution_contract.max_live_entries;

const max_read_bytes: usize = 64 * 1024;
const launcher_config_bytes: usize = contracts.max_command_bytes * 6 +
    contracts.max_authority_text_bytes * 2 +
    contracts.max_shell_path_bytes * 2 +
    4096;
const wait_poll_ns: u64 = 5 * std.time.ns_per_ms;
const graceful_close_ms: i64 = 800;
const control_poll_ms: i32 = 50;
const marker_frame_timeout_ms: i64 = 5_000;
const marker_ack_timeout_ms: i64 = tmux_session.marker_acknowledgement_timeout_ms;
const command_release_byte: u8 = 2;
const control_nonce_len: usize = 32;
const marker_frame_len: usize = control_nonce_len + 1;
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const default_dimensions: contracts.Dimensions = .{
    .rows = 24,
    .columns = 80,
};
const ioctl_set_controlling_terminal: c_int = switch (builtin.os.tag) {
    .macos => 0x20007461,
    .linux => @intCast(std.os.linux.T.IOCSCTTY),
    else => 0,
};
const ioctl_set_window_size: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(u32, 0x80087467)),
    .linux => @intCast(std.os.linux.T.IOCSWINSZ),
    else => 0,
};

const control_frame_len: usize = 5;
const ControlKind = enum(u8) {
    prepared = 1,
    shell_ready = 2,
    command_started = 3,
    command_exited = 4,
    command_signal = 5,
    startup_failed = 6,
    invalid_term = 7,
};

const StartupFailure = enum(u32) {
    shell_unavailable = 1,
    profile_failed = 2,
    control_failed = 3,
};

const MarkerKind = enum(u8) {
    shell_ready = 1,
    command_started = 2,
};

const LauncherConfig = struct {
    argv: []const []const u8,
    cwd: []const u8,
    dimensions: contracts.Dimensions,
    control_path: []const u8,
    control_nonce: []const u8,
    bootstrap_path: []const u8,
    bootstrap: []const u8,
    command_path: ?[]const u8,
    command: ?[]const u8,
};

const LauncherWatchdog = struct {
    child_pid: std.posix.pid_t,
    done: std.atomic.Value(bool) = .init(false),
    command_released: std.atomic.Value(bool) = .init(false),
    host_closed: std.atomic.Value(bool) = .init(false),

    fn run(self: *LauncherWatchdog) void {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        while (!self.done.load(.acquire)) {
            poll_fds[0].revents = 0;
            _ = std.posix.poll(&poll_fds, control_poll_ms) catch {
                self.host_closed.store(true, .release);
                _ = std.c.kill(-self.child_pid, std.c.SIG.KILL);
                return;
            };
            if (poll_fds[0].revents == 0) continue;
            var byte: [1]u8 = undefined;
            const count = std.posix.read(std.posix.STDIN_FILENO, &byte) catch 0;
            if (count != 0) {
                if (byte[0] == command_release_byte) {
                    self.command_released.store(true, .release);
                }
                continue;
            }
            self.host_closed.store(true, .release);
            if (!self.done.load(.acquire)) {
                _ = std.c.kill(-self.child_pid, std.c.SIG.KILL);
            }
            return;
        }
    }
};

const ControlPhase = enum {
    awaiting_shell,
    shell_ready,
    command_started,
};

const LauncherControl = struct {
    server: *std.Io.net.Server,
    control_path: []const u8,
    bootstrap_path: []const u8,
    nonce: []const u8,
    command_path: ?[]const u8,
    child_pid: std.posix.pid_t,
    watchdog: *LauncherWatchdog,
    done: std.atomic.Value(bool) = .init(false),
    phase: ControlPhase = .awaiting_shell,
    failed: bool = false,

    fn run(self: *LauncherControl) void {
        self.runInner() catch {
            self.failed = true;
        };
    }

    fn runInner(self: *LauncherControl) !void {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = self.server.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        while (!self.done.load(.acquire)) {
            poll_fds[0].revents = 0;
            _ = try std.posix.poll(&poll_fds, control_poll_ms);
            if (poll_fds[0].revents == 0) continue;

            var stream = self.server.accept(io_mod.getIo()) catch |err| switch (err) {
                error.ConnectionAborted, error.WouldBlock => continue,
                else => return err,
            };
            defer stream.close(io_mod.getIo());
            var bytes: [marker_frame_len]u8 = undefined;
            receiveSocketExact(
                stream.socket,
                &bytes,
                marker_frame_timeout_ms,
            ) catch continue;
            if (!std.mem.eql(
                u8,
                self.nonce,
                bytes[0..control_nonce_len],
            )) continue;
            const kind: MarkerKind = switch (bytes[control_nonce_len]) {
                1 => .shell_ready,
                2 => .command_started,
                else => continue,
            };
            if (!try self.acceptMarker(kind)) continue;
            const finished = self.phase == .command_started or
                (self.phase == .shell_ready and self.command_path == null);
            if (finished) {
                std.Io.Dir.deleteFileAbsolute(
                    io_mod.getIo(),
                    self.control_path,
                ) catch {};
            }
            try writeAllFd(stream.socket.handle, &.{1}, false);
            if (finished) {
                return;
            }
        }
    }

    fn acceptMarker(
        self: *LauncherControl,
        kind: MarkerKind,
    ) !bool {
        switch (kind) {
            .shell_ready => {
                if (self.phase != .awaiting_shell) return false;
                setEcho(std.posix.STDOUT_FILENO, true) catch {};
                std.Io.Dir.deleteFileAbsolute(
                    io_mod.getIo(),
                    self.bootstrap_path,
                ) catch {};
                try writeControlFd(
                    std.posix.STDERR_FILENO,
                    .shell_ready,
                    @intCast(self.child_pid),
                );
                self.phase = .shell_ready;
            },
            .command_started => {
                if (self.phase != .shell_ready or
                    self.command_path == null) return false;
                std.Io.Dir.deleteFileAbsolute(
                    io_mod.getIo(),
                    self.command_path.?,
                ) catch {};
                try writeControlFd(
                    std.posix.STDERR_FILENO,
                    .command_started,
                    @intCast(self.child_pid),
                );
                while (!self.watchdog.command_released.load(.acquire)) {
                    if (self.watchdog.host_closed.load(.acquire)) {
                        return error.LauncherHostClosed;
                    }
                    io_mod.sleep(wait_poll_ns);
                }
                self.phase = .command_started;
            },
        }
        return true;
    }
};

pub const WorkTracker = struct {
    context: ?*anyopaque,
    update_fn: *const fn (?*anyopaque, bool) void,

    fn update(self: WorkTracker, live: bool) void {
        self.update_fn(self.context, live);
    }
};

fn isSupported() bool {
    return isSupportedForOs(builtin.os.tag);
}

fn isSupportedForOs(os_tag: std.Target.Os.Tag) bool {
    return host_capabilities.terminalSupportForOs(os_tag).isSupported();
}

test "native terminal backend selection follows canonical platform support" {
    const os_tags = [_]std.Target.Os.Tag{
        .macos,
        .linux,
        .windows,
        .wasi,
        .freebsd,
        .emscripten,
    };
    for (os_tags) |os_tag| {
        try std.testing.expectEqual(
            host_capabilities.terminalSupportForOs(os_tag).isSupported(),
            isSupportedForOs(os_tag),
        );
    }
    try std.testing.expectEqual(isSupportedForOs(builtin.os.tag), isSupported());
    const ExpectedRegistry = if (comptime host_capabilities
        .terminalSupportForOs(builtin.os.tag)
        .isSupported())
        SupportedRegistry
    else
        UnsupportedRegistry;
    try std.testing.expectEqualStrings(
        @typeName(ExpectedRegistry),
        @typeName(Registry),
    );
}

pub fn isLauncherModeRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 2 and
        std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), launcher_mode);
}

pub fn isControlModeRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 5 and
        std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), control_mode);
}

pub fn runControlMarker(raw_args: []const [*:0]const u8) !void {
    if (comptime !isSupported()) return error.TerminalHostUnsupported;
    if (!isControlModeRaw(raw_args)) return error.InvalidControlMarker;
    const control_path = std.mem.sliceTo(raw_args[2], 0);
    const nonce = std.mem.sliceTo(raw_args[3], 0);
    const event = std.mem.sliceTo(raw_args[4], 0);
    if (nonce.len != control_nonce_len) return error.InvalidControlMarker;
    const kind: MarkerKind =
        if (std.mem.eql(u8, event, "shell-ready"))
            .shell_ready
        else if (std.mem.eql(u8, event, "command-started"))
            .command_started
        else
            return error.InvalidControlMarker;

    const tmux_failure = if (std.mem.startsWith(
        u8,
        control_path,
        "/tmp/fx-tmux-marker-",
    ))
        io_mod.getenv("FX_TERMINAL_TEST_TMUX_MARKER_FAILURE")
    else
        null;
    if (tmux_failure) |failure| {
        if (std.mem.eql(u8, failure, "child-exit")) {
            return error.InjectedTmuxMarkerChildExit;
        }
        if (std.mem.eql(u8, failure, "no-peer")) {
            while (true) io_mod.sleep(wait_poll_ns);
        }
    }

    var bytes: [marker_frame_len]u8 = @splat(0);
    @memcpy(bytes[0..control_nonce_len], nonce);
    bytes[control_nonce_len] = @intFromEnum(kind);
    const address = try std.Io.net.UnixAddress.init(control_path);
    var stream = try address.connect(io_mod.getIo());
    defer stream.close(io_mod.getIo());
    if (tmux_failure) |failure| {
        if (std.mem.eql(u8, failure, "silent-peer")) {
            while (true) io_mod.sleep(wait_poll_ns);
        }
        if (std.mem.eql(u8, failure, "partial-marker")) {
            try writeAllFd(
                stream.socket.handle,
                bytes[0 .. bytes.len / 2],
                false,
            );
            while (true) io_mod.sleep(wait_poll_ns);
        }
        if (std.mem.eql(u8, failure, "invalid-nonce")) {
            bytes[0] ^= 1;
            try writeAllFd(stream.socket.handle, &bytes, false);
            while (true) io_mod.sleep(wait_poll_ns);
        }
    }
    try writeAllFd(stream.socket.handle, &bytes, false);
    var ack: [1]u8 = undefined;
    try receiveSocketExact(stream.socket, &ack, marker_ack_timeout_ms);
    if (ack[0] != 1) return error.ControlMarkerRejected;
}

fn writePrivateLauncherFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        path,
        .{
            .exclusive = true,
            .permissions = private_file_permissions,
        },
    );
    errdefer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), bytes);
}

pub fn runLauncher(alloc: Allocator) !void {
    if (comptime !isSupported()) return error.TerminalHostUnsupported;

    var length_bytes: [4]u8 = undefined;
    try readExactFd(std.posix.STDIN_FILENO, &length_bytes);
    const config_len = std.mem.readInt(u32, &length_bytes, .little);
    if (config_len == 0 or config_len > launcher_config_bytes) {
        return error.InvalidLauncherConfig;
    }
    const config_bytes = try alloc.alloc(u8, config_len);
    defer alloc.free(config_bytes);
    try readExactFd(std.posix.STDIN_FILENO, config_bytes);
    var parsed = try std.json.parseFromSlice(
        LauncherConfig,
        alloc,
        config_bytes,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    if (parsed.value.argv.len == 0) return error.InvalidLauncherConfig;
    if (!std.fs.path.isAbsolute(parsed.value.cwd) or
        !std.fs.path.isAbsolute(parsed.value.control_path) or
        !std.fs.path.isAbsolute(parsed.value.bootstrap_path) or
        parsed.value.control_nonce.len != control_nonce_len or
        (parsed.value.command == null) != (parsed.value.command_path == null))
    {
        return error.InvalidLauncherConfig;
    }
    if (parsed.value.command_path) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidLauncherConfig;
    }
    try parsed.value.dimensions.validate();

    var bootstrap_created = false;
    defer if (bootstrap_created) {
        std.Io.Dir.deleteFileAbsolute(
            io_mod.getIo(),
            parsed.value.bootstrap_path,
        ) catch {};
    };
    try writePrivateLauncherFile(
        parsed.value.bootstrap_path,
        parsed.value.bootstrap,
    );
    bootstrap_created = true;
    var command_created = false;
    defer if (command_created) {
        std.Io.Dir.deleteFileAbsolute(
            io_mod.getIo(),
            parsed.value.command_path.?,
        ) catch {};
    };
    if (parsed.value.command) |command| {
        try writePrivateLauncherFile(parsed.value.command_path.?, command);
        command_created = true;
    }
    std.Io.Dir.deleteFileAbsolute(
        io_mod.getIo(),
        parsed.value.control_path,
    ) catch {};
    const address = try std.Io.net.UnixAddress.init(parsed.value.control_path);
    var server = try address.listen(io_mod.getIo(), .{});
    defer server.deinit(io_mod.getIo());
    defer std.Io.Dir.deleteFileAbsolute(
        io_mod.getIo(),
        parsed.value.control_path,
    ) catch {};
    try std.Io.Dir.cwd().setFilePermissions(
        io_mod.getIo(),
        parsed.value.control_path,
        private_file_permissions,
        .{ .follow_symlinks = false },
    );

    if (std.c.setsid() < 0) return error.SessionCreationFailed;
    if (std.c.ioctl(
        std.posix.STDOUT_FILENO,
        ioctl_set_controlling_terminal,
        @as(c_int, 0),
    ) < 0) return error.ControllingTerminalFailed;
    try resizeFd(std.posix.STDOUT_FILENO, parsed.value.dimensions);
    try writeControlFd(std.posix.STDERR_FILENO, .prepared, 0);

    var release: [1]u8 = undefined;
    try readExactFd(std.posix.STDIN_FILENO, &release);
    if (release[0] != 1) return error.InvalidLauncherRelease;

    const terminal_file = std.Io.File{
        .handle = std.posix.STDOUT_FILENO,
        .flags = .{ .nonblocking = false },
    };
    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = parsed.value.argv,
        .stdin = .{ .file = terminal_file },
        .stdout = .{ .file = terminal_file },
        .stderr = .{ .file = terminal_file },
        .cwd = .{ .path = parsed.value.cwd },
        .pgid = 0,
    }) catch {
        try writeControlFd(
            std.posix.STDERR_FILENO,
            .startup_failed,
            @intFromEnum(StartupFailure.shell_unavailable),
        );
        return;
    };
    var child_running = true;
    errdefer if (child_running) child.kill(io_mod.getIo());
    const child_pid = child.id orelse return error.ChildIdentityMissing;
    if (tcsetpgrp(std.posix.STDOUT_FILENO, child_pid) != 0) {
        return error.ForegroundProcessGroupFailed;
    }
    var watchdog = LauncherWatchdog{ .child_pid = child_pid };
    var control = LauncherControl{
        .server = &server,
        .control_path = parsed.value.control_path,
        .bootstrap_path = parsed.value.bootstrap_path,
        .nonce = parsed.value.control_nonce,
        .command_path = parsed.value.command_path,
        .child_pid = child_pid,
        .watchdog = &watchdog,
    };
    var control_thread = try std.Thread.spawn(
        .{},
        LauncherControl.run,
        .{&control},
    );
    var watchdog_thread = std.Thread.spawn(
        .{},
        LauncherWatchdog.run,
        .{&watchdog},
    ) catch |err| {
        control.done.store(true, .release);
        child.kill(io_mod.getIo());
        child_running = false;
        control_thread.join();
        return err;
    };
    const term = waitLauncherChild(&child) catch |err| {
        watchdog.done.store(true, .release);
        control.done.store(true, .release);
        child.kill(io_mod.getIo());
        child_running = false;
        watchdog_thread.join();
        control_thread.join();
        return err;
    };
    child_running = false;
    watchdog.done.store(true, .release);
    control.done.store(true, .release);
    watchdog_thread.join();
    control_thread.join();
    closeFd(std.posix.STDOUT_FILENO);
    if (control.failed) {
        try writeControlFd(
            std.posix.STDERR_FILENO,
            .startup_failed,
            @intFromEnum(StartupFailure.control_failed),
        );
        return;
    }
    const trusted_term = control.phase == .command_started or
        (control.phase == .shell_ready and parsed.value.command == null);
    if (!trusted_term) {
        try writeControlFd(
            std.posix.STDERR_FILENO,
            .startup_failed,
            @intFromEnum(StartupFailure.profile_failed),
        );
        return;
    }
    switch (term) {
        .exited => |code| try writeControlFd(
            std.posix.STDERR_FILENO,
            .command_exited,
            code,
        ),
        .signal => |signal| try writeControlFd(
            std.posix.STDERR_FILENO,
            .command_signal,
            @intFromEnum(signal),
        ),
        .stopped, .unknown => try writeControlFd(
            std.posix.STDERR_FILENO,
            .invalid_term,
            0,
        ),
    }
}

fn signalLauncherProcessGroup(pid: std.c.pid_t, signal: std.c.SIG) !void {
    while (true) switch (std.c.errno(std.c.kill(-pid, signal))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.ChildSignalFailed,
    };
}

fn launcherStatusToTerm(raw_status: u32) std.process.Child.Term {
    return if (std.c.W.IFEXITED(raw_status))
        .{ .exited = std.c.W.EXITSTATUS(raw_status) }
    else if (std.c.W.IFSIGNALED(raw_status))
        .{ .signal = std.c.W.TERMSIG(raw_status) }
    else if (std.c.W.IFSTOPPED(raw_status))
        .{ .stopped = std.c.W.STOPSIG(raw_status) }
    else
        .{ .unknown = raw_status };
}

test "launcher wait status classifies terminal results before stops" {
    try std.testing.expectEqual(
        std.process.Child.Term{ .exited = 23 },
        launcherStatusToTerm(23 << 8),
    );
    try std.testing.expectEqual(
        std.process.Child.Term{ .signal = .TERM },
        launcherStatusToTerm(@intFromEnum(std.c.SIG.TERM)),
    );
    try std.testing.expectEqual(
        std.process.Child.Term{ .signal = .SEGV },
        launcherStatusToTerm(@intFromEnum(std.c.SIG.SEGV) | 0x80),
    );
    try std.testing.expectEqual(
        std.process.Child.Term{ .stopped = .TTIN },
        launcherStatusToTerm((@as(u32, @intFromEnum(std.c.SIG.TTIN)) << 8) | 0x7f),
    );
}

fn waitLauncherChild(child: *std.process.Child) !std.process.Child.Term {
    const pid = child.id orelse return error.ChildIdentityMissing;
    var observe_stops = true;
    while (true) {
        var status: c_int = undefined;
        const flags: c_int = if (observe_stops) std.c.W.UNTRACED else 0;
        const waited = std.c.waitpid(pid, &status, flags);
        switch (std.c.errno(waited)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ChildWaitFailed,
        }
        if (waited != pid) return error.ChildWaitFailed;

        const raw_status: u32 = @bitCast(status);
        const term = launcherStatusToTerm(raw_status);
        switch (term) {
            .stopped => |signal| {
                if (signal == std.c.SIG.TTIN or signal == std.c.SIG.TTOU) {
                    try signalLauncherProcessGroup(pid, std.c.SIG.CONT);
                    debug_trace.logf(
                        "terminal_host",
                        "resumed terminal child after foreground race pid={d}",
                        .{pid},
                    );
                } else {
                    observe_stops = false;
                }
                continue;
            },
            .exited, .signal, .unknown => {},
        }

        std.debug.assert(child.stdin == null);
        std.debug.assert(child.stdout == null);
        std.debug.assert(child.stderr == null);
        child.id = null;
        return term;
    }
}

pub const Registry = if (isSupported()) SupportedRegistry else UnsupportedRegistry;

const UnsupportedRegistry = struct {
    alloc: Allocator,

    pub fn init(
        alloc: Allocator,
        _: WorkTracker,
        _: *terminal_store.ProfileStore,
        _: []const u8,
        _: []const u8,
        _: []const u8,
    ) !UnsupportedRegistry {
        return .{ .alloc = alloc };
    }

    pub fn shutdownSessionsOnly(_: *UnsupportedRegistry) void {}

    pub fn deinit(self: *UnsupportedRegistry) void {
        self.* = undefined;
    }

    pub fn executeAuthorized(
        self: *UnsupportedRegistry,
        request: contracts.ActionRequest,
        _: *std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .failure = .{
                .action = request.action(),
                .code = .unsupported_host,
            } },
        ) catch return error.OutOfMemory;
    }

    pub fn cancelAuthorized(
        _: *UnsupportedRegistry,
        _: []const u8,
        _: contracts.AuthorityClaim,
    ) !void {}
};

const SupportedRegistry = struct {
    const StartReservation = struct {
        owner_id: []const u8,
        source: ?contracts.ProcessOwner,
        cancelled: *std.atomic.Value(bool),
    };
    const Slot = union(enum) {
        empty,
        starting: *StartReservation,
        resident: struct { session: *Session, references: usize },
    };
    const ExitFence = struct {
        const Outcome = enum { open, closing, succeeded, failed };
        owner_id: [255]u8,
        owner_len: u8,
        source: contracts.ProcessOwner,
        outcome: Outcome = .open,

        fn matches(self: ExitFence, id: []const u8, source: contracts.ProcessOwner) bool {
            return std.mem.eql(u8, self.owner_id[0..self.owner_len], id) and
                self.source.pid == source.pid and std.mem.eql(u8, self.source.token(), source.token());
        }
    };

    alloc: Allocator,
    tracker: WorkTracker,
    profile: *terminal_store.ProfileStore,
    host_identity: []const u8,
    durable_root: []const u8,
    transport_root: []const u8,
    mutex: std.Io.Mutex = .init,

    slots: [max_sessions]Slot = @splat(.empty),
    exit_fences: [max_sessions]?ExitFence = @splat(null),
    stop_requested: ?*std.atomic.Value(bool) = null,
    recycle_cursor: usize = 0,
    recovery: ?terminal_store.RecoveredList = null,

    pub fn init(
        alloc: Allocator,
        tracker: WorkTracker,
        profile: *terminal_store.ProfileStore,
        host_identity: []const u8,
        durable_root: []const u8,
        transport_root: []const u8,
    ) !SupportedRegistry {
        var registry = SupportedRegistry{
            .alloc = alloc,
            .tracker = tracker,
            .profile = profile,
            .host_identity = host_identity,
            .durable_root = durable_root,
            .transport_root = transport_root,
        };
        errdefer registry.deinitRecoveryAttempt();
        var recovered = try profile.recover(host_identity, io_mod.milliTimestamp());
        var recovered_owned = true;
        errdefer if (recovered_owned) recovered.deinit();
        for (recovered.sessions.items) |*durable| {
            if (!(try durable.close_cleanup_pending())) continue;
            try finalizeRecoveredCloseBackend(
                alloc,
                profile.process_provider,
                durable_root,
                transport_root,
                durable.record,
            );
            try durable.finish_close(io_mod.milliTimestamp());
        }
        while (recovered.sessions.pop()) |recovered_session| {
            var durable = recovered_session;
            var durable_owned = true;
            defer if (durable_owned) durable.deinit();
            if (durable.record.backend == .tmux and
                (durable.record.lifecycle == .starting or
                    durable.record.lifecycle == .running))
            {
                durable_owned = false;
                try registry.recoverTmux(durable);
                continue;
            }
            if (durable.record.backend == .tmux) {
                tmux_session.cleanupOwnedNamespace(
                    alloc,
                    profile.process_provider,
                    durable_root,
                    transport_root,
                    durable.record.backend_identity,
                );
            }
        }
        registry.recovery = recovered;
        recovered_owned = false;
        return registry;
    }

    fn recoverTmux(
        self: *SupportedRegistry,
        durable: terminal_store.DurableSession,
    ) !void {
        const session = try self.alloc.create(Session);
        var initialized = false;
        defer if (!initialized) self.alloc.destroy(session);
        session.* = Session.initRecovered(
            self.alloc,
            self.tracker,
            durable,
        ) catch |err| return err;
        initialized = true;
        var session_owned = true;
        defer if (session_owned) {
            session.deinitRecoveryAttempt();
            self.alloc.destroy(session);
        };
        try session.durable.ensureSessionExitProof();
        try self.profile.register_resident(&session.durable, null);
        const slot = self.reserve(session) orelse return error.CapacityExceeded;
        std.debug.assert(slot.evicted == null);
        var reserved = true;
        defer if (reserved) self.removeOwned(slot.index, session);
        session.markLive();
        const remains_live = session.recoverTmux(
            self.durable_root,
            self.transport_root,
        ) catch |err| {
            debug_trace.logf(
                "terminal_host",
                "tmux recovery deferred id={s} err={s}",
                .{ session.id, @errorName(err) },
            );
            session.markNotLive();
            if (!definitiveTmuxRecoveryLoss(err)) return err;
            session.cleanupDefinitiveTmuxRecoveryAttempt() catch |cleanup_err| {
                debug_trace.logf(
                    "terminal_host",
                    "tmux definitive recovery cleanup deferred id={s} err={s}",
                    .{ session.id, @errorName(cleanup_err) },
                );
                return cleanup_err;
            };
            session.markLost();
            return;
        };
        if (!remains_live) {
            session.markNotLive();
            return;
        }
        self.releaseReference(slot.index, session);
        reserved = false;
        session_owned = false;
    }

    /// Kills every live session's process without freeing any session state.
    ///
    /// For a host that must exit while client threads are still running: those
    /// threads may hold session pointers, so nothing here may be destroyed, but
    /// the child processes still have to be signalled or they outlive the host
    /// that owns them. `deinit` does both; this does only the half that is safe
    /// while other threads are reading.
    pub fn shutdownSessionsOnly(self: *SupportedRegistry) void {
        const zio = io_mod.getIo();
        var pinned: [max_sessions]?*Session = @splat(null);
        self.mutex.lockUncancelable(zio);
        for (&self.slots, 0..) |*entry, index| switch (entry.*) {
            .empty => {},
            .starting => |starting| starting.cancelled.store(true, .release),
            .resident => |*resident| {
                resident.references += 1;
                pinned[index] = resident.session;
            },
        };
        self.mutex.unlock(zio);
        for (pinned, 0..) |entry, index| {
            const session = entry orelse continue;
            session.shutdown();
            self.releaseReference(index, session);
        }
    }

    pub fn deinit(self: *SupportedRegistry) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        const slots = self.slots;
        self.slots = @splat(.empty);
        self.mutex.unlock(zio);
        for (slots) |entry| switch (entry) {
            .empty => {},
            .starting => unreachable,
            .resident => |resident| resident.session.shutdown(),
        };
        for (slots) |entry| switch (entry) {
            .empty => {},
            .starting => unreachable,
            .resident => |resident| {
                resident.session.deinit();
                self.alloc.destroy(resident.session);
            },
        };
        if (self.recovery) |*recovered| recovered.deinit();
        self.* = undefined;
    }

    fn deinitRecoveryAttempt(self: *SupportedRegistry) void {
        for (&self.slots) |*entry| switch (entry.*) {
            .empty => {},
            .starting => unreachable,
            .resident => |resident| {
                resident.session.deinitRecoveredRegistryAttempt();
                self.alloc.destroy(resident.session);
                entry.* = .empty;
            },
        };
        if (self.recovery) |*recovered| recovered.deinit();
        self.* = undefined;
    }

    pub fn executeAuthorized(
        self: *SupportedRegistry,
        request: contracts.ActionRequest,
        cancelled: *std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        return switch (request) {
            .start => |value| self.start(value, cancelled),
            .read => |value| self.read(value),
            .screen => |value| self.screen(value, cancelled),
            .write => |value| self.write(value, cancelled),
            .wait => |value| self.wait(value, cancelled),
            .inspect => |value| self.inspect(value),
            .list => |value| self.list(value),
            .resize => |value| self.withSession(
                .resize,
                value.session_id,
                resizeAction,
                .{value},
            ),
            .signal => |value| self.withSession(
                .signal,
                value.session_id,
                signalAction,
                .{value},
            ),
            .close => |value| self.close(value),
            .close_owner => |value| self.closeOwner(value),
        };
    }

    pub fn cancelAuthorized(
        self: *SupportedRegistry,
        session_id: []const u8,
        claim: contracts.AuthorityClaim,
    ) !void {
        try self.profile.cancelClaim(session_id, claim, io_mod.milliTimestamp());
    }

    fn read(
        self: *SupportedRegistry,
        request: contracts.ReadRequest,
    ) Allocator.Error!contracts.OwnedResult {
        if (self.find(request.session_id)) |reference| {
            defer self.releaseReference(reference.index, reference.session);
            return readAction(reference.session, request) catch |err|
                self.actionError(.read, request.session_id, err);
        }
        const durable = self.profile.open_terminal(request.session_id) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.read, .session_not_found, request.session_id);
        };
        defer self.profile.release_terminal(durable);
        const authorization = durable.authorize(
            request.authority.?,
            .read,
        ) catch |err| return self.actionError(.read, request.session_id, err);
        var page = durable.read(self.alloc, request.cursor, max_read_bytes) catch |err| {
            return self.actionError(.read, request.session_id, err);
        };
        defer page.deinit(self.alloc);
        const facts = projectedFacts(durable.facts(), authorization);
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .read = .{
                .session = facts,
                .output = page.output,
                .raw_range = page.range,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn inspect(
        self: *SupportedRegistry,
        request: contracts.SessionRequest,
    ) Allocator.Error!contracts.OwnedResult {
        if (self.find(request.session_id)) |reference| {
            defer self.releaseReference(reference.index, reference.session);
            return inspectAction(reference.session, request) catch |err|
                self.actionError(.inspect, request.session_id, err);
        }
        const durable = self.profile.open_terminal(request.session_id) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.inspect, .session_not_found, request.session_id);
        };
        defer self.profile.release_terminal(durable);
        const authorization = durable.authorize(
            request.authority.?,
            .inspect,
        ) catch |err| return self.actionError(.inspect, request.session_id, err);
        const facts = projectedFacts(durable.facts(), authorization);
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .inspect = .{
                .session = facts,
                .shell = durable.record.shell,
                .cwd = durable.record.cwd,
                .command = durable.record.command,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn screen(
        self: *SupportedRegistry,
        request: contracts.SessionRequest,
        cancelled: *const std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        if (self.find(request.session_id)) |reference| {
            defer self.releaseReference(reference.index, reference.session);
            return screenAction(reference.session, request, cancelled) catch |err|
                self.actionError(.screen, request.session_id, err);
        }
        const durable = self.profile.open_terminal(request.session_id) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.screen, .session_not_found, request.session_id);
        };
        defer self.profile.release_terminal(durable);
        const authorization = durable.authorize(
            request.authority.?,
            .screen,
        ) catch |err| return self.actionError(.screen, request.session_id, err);
        return screenDurable(self.alloc, durable, authorization, cancelled) catch |err|
            self.actionError(.screen, request.session_id, err);
    }

    fn close(
        self: *SupportedRegistry,
        request: contracts.CloseRequest,
    ) Allocator.Error!contracts.OwnedResult {
        if (self.find(request.session_id)) |reference| {
            defer self.releaseReference(reference.index, reference.session);
            return closeAction(reference.session, request) catch |err|
                self.actionError(.close, request.session_id, err);
        }
        const durable = self.profile.open_terminal(request.session_id) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.close, .session_not_found, request.session_id);
        };
        defer self.profile.release_terminal(durable);
        const now_ms = io_mod.milliTimestamp();
        requireCloseCandidate(
            request.session_id,
            durable.begin_close(request.authority.?, now_ms),
        ) catch |err| return self.actionError(.close, request.session_id, err);
        durable.finish_close(now_ms) catch |err| {
            return self.actionError(.close, request.session_id, err);
        };
        var facts = durable.facts();
        facts.next_actions = .{};
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .close = .{
                .session = facts,
                .policy = request.policy,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn closeOwner(self: *SupportedRegistry, request: contracts.CloseOwnerRequest) Allocator.Error!contracts.OwnedResult {
        const deadline = io_mod.milliTimestamp() + 300;
        self.profile.authorizeSessionExit(request.authority) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.close_owner, .authority_denied, request.authority.session_id);
        };
        const source = request.process_owner orelse return self.failure(.close_owner, .authority_denied, request.authority.session_id);
        const owner_id = request.authority.session_id;
        var pinned: [max_sessions]?*Session = @splat(null);
        var closed: u16 = 0;
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.sourceFencedLocked(owner_id, source)) {
            self.mutex.unlock(io_mod.getIo());
            return self.waitOwnerExit(owner_id, source, deadline);
        }
        self.fenceSourceLocked(owner_id, source) catch {
            self.mutex.unlock(io_mod.getIo());
            return self.failure(.close_owner, .capacity_exceeded, owner_id);
        };
        for (&self.slots, 0..) |*entry, index| switch (entry.*) {
            .empty => {},
            .starting => |starting| {
                if (std.mem.eql(u8, starting.owner_id, owner_id)) starting.cancelled.store(true, .release);
            },
            .resident => |*resident| {
                const session = resident.session;
                if (!std.mem.eql(u8, session.durable.record.owner_session_id, owner_id)) continue;
                resident.references += 1;
                pinned[index] = session;
                if (!session.backend_detaching.load(.acquire)) closed += 1;
            },
        };
        self.mutex.unlock(io_mod.getIo());
        var outcome: ExitFence.Outcome = .failed;
        defer self.finishOwnerExit(owner_id, source, outcome);
        defer for (pinned, 0..) |entry, index| if (entry) |session| self.releaseReference(index, session);

        for (pinned) |entry| if (entry) |session| session.backend_detaching.store(true, .release);
        var complete = true;
        for (pinned) |entry| {
            const session = entry orelse continue;
            const delivered = session.signalForOwnerExit() catch |err| failed: {
                debug_trace.logf("terminal_host", "owner exit tree signal failed id={s} err={s}", .{ session.id, @errorName(err) });
                break :failed false;
            };
            if (delivered) |success| complete = complete and success;
            session.shutdown();
        }
        while (!self.ownerExitSettled(owner_id, &pinned)) {
            if (io_mod.milliTimestamp() >= deadline) return self.failure(.close_owner, .session_lost, owner_id);
            io_mod.sleep(wait_poll_ns);
        }
        for (pinned) |entry| {
            const session = entry orelse continue;
            session.finalizeBackend();
            if (session.tmux_backend) |*backend| {
                backend.cleanupChecked(self.profile.process_provider, deadline) catch |err| {
                    debug_trace.logf("terminal_host", "owner exit tmux cleanup failed id={s} err={s}", .{ session.id, @errorName(err) });
                    complete = false;
                };
            }
        }
        if (!complete) return self.failure(.close_owner, .session_lost, owner_id);
        outcome = .succeeded;
        return contracts.OwnedResult.init(self.alloc, .{ .success = .{ .close_owner = .{ .closed_sessions = closed } } }) catch return error.OutOfMemory;
    }

    fn waitOwnerExit(self: *SupportedRegistry, owner_id: []const u8, source: contracts.ProcessOwner, deadline: i64) Allocator.Error!contracts.OwnedResult {
        while (true) {
            self.mutex.lockUncancelable(io_mod.getIo());
            const outcome: ExitFence.Outcome = for (self.exit_fences) |entry| {
                const fence = entry orelse continue;
                if (fence.matches(owner_id, source)) break fence.outcome;
            } else .failed;
            self.mutex.unlock(io_mod.getIo());
            switch (outcome) {
                .succeeded => return contracts.OwnedResult.init(self.alloc, .{ .success = .{ .close_owner = .{ .closed_sessions = 0 } } }) catch return error.OutOfMemory,
                .open, .failed => return self.failure(.close_owner, .session_lost, owner_id),
                .closing => if (io_mod.milliTimestamp() >= deadline) return self.failure(.close_owner, .session_lost, owner_id),
            }
            io_mod.sleep(wait_poll_ns);
        }
    }

    fn finishOwnerExit(self: *SupportedRegistry, owner_id: []const u8, source: contracts.ProcessOwner, outcome: ExitFence.Outcome) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (&self.exit_fences) |*entry| {
            const fence = if (entry.*) |*value| value else continue;
            if (fence.matches(owner_id, source)) {
                fence.outcome = outcome;
                return;
            }
        }
    }

    fn ownerExitSettled(self: *SupportedRegistry, owner_id: []const u8, pinned: *const [max_sessions]?*Session) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots, 0..) |entry, index| switch (entry) {
            .empty => {},
            .starting => |starting| {
                if (std.mem.eql(u8, starting.owner_id, owner_id) and starting.cancelled.load(.acquire)) return false;
            },
            .resident => |resident| {
                if (pinned[index] != resident.session) continue;
                if (resident.session.launch_phase.load(.acquire) == .launching) return false;
                resident.session.mutex.lockUncancelable(io_mod.getIo());
                const live = resident.session.live_counted;
                resident.session.mutex.unlock(io_mod.getIo());
                if (live) return false;
            },
        };
        return true;
    }

    fn start(
        self: *SupportedRegistry,
        request: contracts.StartRequest,
        cancelled: *std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        if (!isSupported()) {
            return self.failure(.start, .unsupported_host, null);
        }
        const persistence = request.persistence orelse
            return self.failure(.start, .authority_denied, null);

        if (cancelled.load(.acquire)) return self.failure(.start, .cancelled, null);
        var starting = StartReservation{
            .owner_id = persistence.grant.principal.durable_session_id,
            .source = request.process_owner,
            .cancelled = cancelled,
        };
        const slot = self.reserveSlot(.{ .starting = &starting }) orelse
            return self.failure(.start, if (cancelled.load(.acquire)) .cancelled else .capacity_exceeded, null);
        var reservation_owned = true;
        defer if (reservation_owned) self.abandonStart(slot.index, &starting);
        if (slot.evicted) |evicted| {
            evicted.deinit();
            self.alloc.destroy(evicted);
        }
        if (cancelled.load(.acquire)) return self.failure(.start, .cancelled, null);

        const session_id = try session_layout.generateTerminalSessionId(self.alloc);
        var session_id_owned = true;
        defer if (session_id_owned) self.alloc.free(session_id);
        const session = try self.alloc.create(Session);
        var session_owned = true;
        defer if (session_owned) self.alloc.destroy(session);
        if (cancelled.load(.acquire)) return self.failure(.start, .cancelled, null);
        session.* = Session.init(
            self.alloc,
            self.tracker,
            self.profile,
            self.host_identity,
            session_id,
            request,
            persistence,
            cancelled,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf(
                "terminal_host",
                "durable session start rejected err={s}",
                .{@errorName(err)},
            );
            return self.failure(
                .start,
                switch (err) {
                    error.Cancelled => .cancelled,
                    error.CapacityExceeded => .capacity_exceeded,
                    error.MissingLoginShell => .shell_unavailable,
                    error.RelativeShellPath,
                    error.UnsupportedShell,
                    => .invalid_request,
                    else => .authority_denied,
                },
                null,
            );
        };
        session_id_owned = false;
        self.profile.register_resident(&session.durable, cancelled) catch |err| {
            session.deinitUnlaunched();
            if (err == error.Cancelled) return self.failure(.start, .cancelled, null);
            return error.OutOfMemory;
        };

        const launch_allowed = self.publishStart(slot.index, &starting, session);
        reservation_owned = false;
        session_owned = false;
        if (!launch_allowed) {
            self.retireFailedStart(slot.index, session, error.Cancelled);
            return self.failure(.start, .cancelled, null);
        }

        session.markLive();
        session.launch(
            request,
            self.durable_root,
            self.transport_root,
            cancelled,
        ) catch |err| {
            debug_trace.logf(
                "terminal_host",
                "session launch failed id={s} err={s}",
                .{ session.id, @errorName(err) },
            );
            self.retireFailedStart(slot.index, session, err);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.start, launchFailureCode(err), null);
        };
        defer self.releaseReference(slot.index, session);

        const condition = request.return_when orelse .started;
        const ceiling = request.wait_ceiling_ms orelse 5_000;
        const outcome = session.waitFor(condition, ceiling, cancelled) catch {
            const code = session.startFailureCode();
            session.finalizeBackend();
            return self.failure(.start, code, session.id);
        };
        if (returnOutcomeIsTerminal(outcome)) session.finalizeBackend();
        return session.startResult(outcome, .{
            .actor = persistence.grant.actor,
            .controls = persistence.grant.controls,
        }) catch |err| switch (err) {
            error.Cancelled => self.failure(.start, .cancelled, session.id),
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn retireFailedStart(self: *SupportedRegistry, index: usize, session: *Session, cause: anyerror) void {
        if (cause == error.Cancelled or session.backend_detaching.load(.acquire)) {
            session.shutdown();
            session.finalizeBackend();
            session.mutex.lockUncancelable(io_mod.getIo());
            if (session.lifecycle == .starting or session.lifecycle == .running) session.lifecycle = .lost;
            session.mutex.unlock(io_mod.getIo());
            session.markNotLive();
            self.releaseReference(index, session);
            return;
        }
        self.removeOwned(index, session);
        if (session.launch_phase.load(.acquire) != .released) {
            session.durable.rollback_unreleased_start() catch |err| {
                debug_trace.logf("terminal_host", "unreleased start rollback failed id={s} err={s}", .{ session.id, @errorName(err) });
            };
        }
        session.deinit();
        self.alloc.destroy(session);
    }

    fn write(
        self: *SupportedRegistry,
        request: contracts.WriteRequest,
        cancelled: *const std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        if (self.find(request.session_id)) |reference| {
            defer self.releaseReference(reference.index, reference.session);
            return writeAction(reference.session, request, cancelled) catch |err| {
                return self.actionError(.write, request.session_id, err);
            };
        }
        if (request.lease != .release) {
            return self.failure(.write, .session_not_found, request.session_id);
        }
        if (cancelled.load(.acquire)) {
            return self.failure(.write, .cancelled, request.session_id);
        }
        const durable = self.profile.open_terminal(request.session_id) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.write, .session_not_found, request.session_id);
        };
        defer self.profile.release_terminal(durable);
        const authorization = durable.release_write_lease(
            request.authority.?,
            io_mod.milliTimestamp(),
        ) catch |err| return self.actionError(.write, request.session_id, err);
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .write = .{
                .session = projectedFacts(durable.facts(), authorization),
                .accepted_bytes = 0,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn wait(
        self: *SupportedRegistry,
        request: contracts.WaitRequest,
        cancelled: *const std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        const reference = self.find(request.session_id) orelse {
            if (request.return_when != .exit) {
                return self.failure(.wait, .session_not_found, request.session_id);
            }
            const durable = self.profile.open_terminal(request.session_id) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return self.failure(.wait, .session_not_found, request.session_id);
            };
            defer self.profile.release_terminal(durable);
            const authorization = durable.authorize(
                request.authority.?,
                .wait,
            ) catch |err| return self.actionError(.wait, request.session_id, err);
            const outcome = durable.termination_outcome() orelse
                return self.failure(.wait, .session_not_found, request.session_id);
            return contracts.OwnedResult.init(
                self.alloc,
                .{ .success = .{ .wait = .{
                    .session = projectedFacts(durable.facts(), authorization),
                    .outcome = outcome,
                } } },
            ) catch return error.OutOfMemory;
        };
        defer self.releaseReference(reference.index, reference.session);
        const authorization = reference.session.durable.begin_wait(
            request.authority.?,
            io_mod.milliTimestamp(),
        ) catch |err| return self.actionError(.wait, request.session_id, err);
        const outcome = reference.session.waitFor(
            request.return_when,
            request.safety_ceiling_ms,
            cancelled,
        ) catch {
            reference.session.durable.finish_wait(
                authorization.actor,
                false,
                io_mod.milliTimestamp(),
            ) catch {};
            reference.session.finalizeBackend();
            return self.failure(
                .wait,
                .session_lost,
                request.session_id,
            );
        };
        if (returnOutcomeIsTerminal(outcome)) {
            reference.session.finalizeBackend();
        }
        reference.session.durable.finish_wait(
            authorization.actor,
            outcome == .cancelled,
            io_mod.milliTimestamp(),
        ) catch |err| return self.actionError(.wait, request.session_id, err);
        return reference.session.waitResult(outcome, authorization);
    }

    fn withSession(
        self: *SupportedRegistry,
        comptime action: contracts.Action,
        session_id: []const u8,
        comptime operation: anytype,
        args: anytype,
    ) Allocator.Error!contracts.OwnedResult {
        const reference = self.find(session_id) orelse
            return self.failure(action, .session_not_found, session_id);
        defer self.releaseReference(reference.index, reference.session);
        return @call(.auto, operation, .{reference.session} ++ args) catch |err| {
            return self.actionError(action, session_id, err);
        };
    }

    fn actionError(
        self: *SupportedRegistry,
        action: contracts.Action,
        session_id: []const u8,
        err: anyerror,
    ) Allocator.Error!contracts.OwnedResult {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf(
            "terminal_host",
            "session action failed action={s} id={s} err={s}",
            .{ @tagName(action), session_id, @errorName(err) },
        );
        return self.failure(
            action,
            switch (err) {
                error.InvalidCursor,
                error.MissingJournalSegment,
                error.CorruptJournalSegment,
                => .cursor_gap,
                error.CapacityExceeded, error.MonitorStateTooLarge => .capacity_exceeded,
                error.ScreenMissing,
                error.ScreenCorrupt,
                error.ScreenUnsupported,
                error.ScreenRetentionEvicted,
                error.ScreenRawGap,
                error.ScreenResizeUncheckpointed,
                => .screen_unavailable,
                error.InvalidLifecycle, error.ProcessIdentityUnavailable => .invalid_lifecycle,
                error.AuthorityRevoked,
                error.ControlDenied,
                error.ActorRoleMismatch,
                error.PrincipalMismatch,
                error.StaleAuthorityGeneration,
                error.InvalidHolderProof,
                error.InvalidAuthorityClaim,
                error.OwnerCatalogAuthorityNotFound,
                error.OwnerCatalogProofNotFound,
                error.InvalidAuthorityRecord,
                error.ProbeAuthorityDenied,
                error.ProbeCwdChanged,
                => .authority_denied,
                error.TerminalAuthorityRetired => .authority_retired,
                error.LeaseConflict => .lease_conflict,
                error.Cancelled => .cancelled,
                else => .invalid_request,
            },
            session_id,
        );
    }

    fn list(
        self: *SupportedRegistry,
        filters: contracts.ListFilters,
    ) Allocator.Error!contracts.OwnedResult {
        const owner_authority = filters.owner_authority.?;
        var catalog = self.profile.ownerCatalog(owner_authority) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.actionError(
                .list,
                owner_authority.principal.durable_session_id,
                err,
            );
        };
        defer catalog.deinit();
        var facts: std.ArrayList(contracts.SessionFacts) = .empty;
        defer facts.deinit(self.alloc);
        for (catalog.entries.items) |entry| {
            if (filters.task_id) |task_id| {
                if (!std.mem.eql(
                    u8,
                    task_id,
                    owner_authority.principal.durable_session_id,
                )) continue;
            }
            if (filters.workspace_root) |root| {
                if (!std.mem.eql(u8, root, entry.workspace_root)) continue;
            }
            if (filters.lifecycle) |lifecycle| {
                if (lifecycle != entry.facts.lifecycle) continue;
            }
            if (filters.backend) |backend| {
                if (backend != entry.facts.backend) continue;
            }
            facts.append(
                self.alloc,
                projectedFacts(entry.facts, entry.authorization),
            ) catch return error.OutOfMemory;
        }
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .list = .{ .sessions = facts.items } } },
        ) catch return error.OutOfMemory;
    }

    const Reservation = struct {
        index: usize,
        evicted: ?*Session,
    };

    const SessionReference = struct {
        index: usize,
        session: *Session,
    };

    fn reserve(self: *SupportedRegistry, session: *Session) ?Reservation {
        return self.reserveSlot(.{ .resident = .{ .session = session, .references = 1 } });
    }

    fn reserveSlot(self: *SupportedRegistry, value: Slot) ?Reservation {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.stop_requested) |flag| if (flag.load(.acquire)) {
            if (value == .starting) value.starting.cancelled.store(true, .release);
            return null;
        };
        if (value == .starting and self.sourceFencedLocked(value.starting.owner_id, value.starting.source)) {
            value.starting.cancelled.store(true, .release);
            return null;
        }
        if (value == .starting) {
            if (value.starting.source) |source| {
                _ = self.retainSourceLocked(value.starting.owner_id, source) catch return null;
            }
        }
        for (&self.slots, 0..) |*entry, index| {
            if (entry.* != .empty) continue;
            entry.* = value;
            return .{ .index = index, .evicted = null };
        }
        for (0..max_sessions) |offset| {
            const index = (self.recycle_cursor + offset) % max_sessions;
            const entry = &self.slots[index];
            if (entry.* != .resident or entry.resident.references != 0) continue;
            const candidate = entry.resident.session;
            if (!candidate.isRecyclable()) continue;
            if (!self.profile.tryUnregisterResident(&candidate.durable)) continue;
            entry.* = value;
            self.recycle_cursor = (index + 1) % max_sessions;
            return .{ .index = index, .evicted = candidate };
        }
        return null;
    }

    fn publishStart(self: *SupportedRegistry, index: usize, starting: *StartReservation, session: *Session) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        std.debug.assert(self.slots[index] == .starting and self.slots[index].starting == starting);
        const allowed = !starting.cancelled.load(.acquire) and !self.sourceFencedLocked(starting.owner_id, starting.source) and
            (self.stop_requested == null or !self.stop_requested.?.load(.acquire));
        session.launch_phase.store(if (allowed) .launching else .failed, .release);
        self.slots[index] = .{ .resident = .{ .session = session, .references = 1 } };
        return allowed;
    }

    fn abandonStart(self: *SupportedRegistry, index: usize, starting: *StartReservation) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        std.debug.assert(self.slots[index] == .starting and self.slots[index].starting == starting);
        self.slots[index] = .empty;
    }

    fn sourceFencedLocked(self: *const SupportedRegistry, owner_id: []const u8, source: ?contracts.ProcessOwner) bool {
        const sender = source orelse return false;
        for (self.exit_fences) |entry| {
            const fence = entry orelse continue;
            if (fence.matches(owner_id, sender)) return fence.outcome != .open;
        }
        return false;
    }

    /// The accept owner supplies all active sources, including the incoming
    /// connection. Process death alone does not retire buffered requests.
    pub fn pruneExitFences(self: *SupportedRegistry, active_sources: []const contracts.ProcessOwner) void {
        for (0..max_sessions) |index| {
            self.mutex.lockUncancelable(io_mod.getIo());
            const entry = self.exit_fences[index];
            self.mutex.unlock(io_mod.getIo());
            const fence = entry orelse continue;
            if (fence.outcome == .closing) continue;
            const active = for (active_sources) |source| {
                if (source.pid == fence.source.pid and std.mem.eql(u8, source.token(), fence.source.token())) break true;
            } else false;
            if (active) continue;
            const token = process_identity.ProcessInstanceToken.parse(fence.source.token()) catch continue;
            var pid_buffer: [32]u8 = undefined;
            const pid = std.fmt.bufPrint(&pid_buffer, "{d}", .{fence.source.pid}) catch continue;
            switch (self.profile.process_provider.matchToken(self.alloc, pid, token)) {
                .matched, .unavailable => continue,
                .missing, .mismatched => {},
            }
            self.mutex.lockUncancelable(io_mod.getIo());
            if (self.exit_fences[index]) |current| {
                if (current.outcome != .closing and current.matches(fence.owner_id[0..fence.owner_len], fence.source)) self.exit_fences[index] = null;
            }
            self.mutex.unlock(io_mod.getIo());
        }
    }

    fn fenceSourceLocked(self: *SupportedRegistry, owner_id: []const u8, source: contracts.ProcessOwner) error{CapacityExceeded}!void {
        const fence = try self.retainSourceLocked(owner_id, source);
        if (fence.outcome == .open) fence.outcome = .closing;
    }

    fn retainSourceLocked(self: *SupportedRegistry, owner_id: []const u8, source: contracts.ProcessOwner) error{CapacityExceeded}!*ExitFence {
        for (&self.exit_fences) |*entry| {
            const fence = if (entry.*) |*value| value else continue;
            if (fence.matches(owner_id, source)) return fence;
        }
        const entry = for (&self.exit_fences) |*value| {
            if (value.* == null) break value;
        } else return error.CapacityExceeded;
        var fence = ExitFence{ .owner_id = undefined, .owner_len = @intCast(owner_id.len), .source = source };
        @memcpy(fence.owner_id[0..owner_id.len], owner_id);
        entry.* = fence;
        return &entry.*.?;
    }

    fn removeOwned(self: *SupportedRegistry, index: usize, session: *Session) void {
        const zio = io_mod.getIo();
        while (true) {
            self.mutex.lockUncancelable(zio);
            const entry = &self.slots[index];
            if (entry.* == .resident and entry.resident.session == session and entry.resident.references == 1) {
                entry.* = .empty;
                self.mutex.unlock(zio);
                return;
            }
            self.mutex.unlock(zio);
            io_mod.sleep(wait_poll_ns);
        }
    }

    fn find(self: *SupportedRegistry, session_id: []const u8) ?SessionReference {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (&self.slots, 0..) |*entry, index| {
            if (entry.* != .resident) continue;
            const resident = &entry.resident;
            if (!std.mem.eql(u8, resident.session.id, session_id)) continue;
            resident.references += 1;
            return .{ .index = index, .session = resident.session };
        }
        return null;
    }

    fn releaseReference(self: *SupportedRegistry, index: usize, session: *Session) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const entry = &self.slots[index];
        if (entry.* != .resident or entry.resident.session != session) return;
        std.debug.assert(entry.resident.references > 0);
        entry.resident.references -= 1;
    }

    pub fn retireIfIdle(self: *SupportedRegistry, context: ?*anyopaque, eligible: *const fn (?*anyopaque) bool) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!eligible(context)) return false;
        for (self.slots) |entry| switch (entry) {
            .empty => {},
            .starting => return false,
            .resident => |resident| if (resident.references != 0 or !resident.session.isRecyclable()) return false,
        };
        const stopping = self.stop_requested orelse return false;
        stopping.store(true, .release);
        return true;
    }

    fn failure(
        self: *SupportedRegistry,
        action: contracts.Action,
        code: contracts.StructuredErrorCode,
        session_id: ?[]const u8,
    ) Allocator.Error!contracts.OwnedResult {
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .failure = .{
                .action = action,
                .code = code,
                .session_id = session_id,
            } },
        ) catch return error.OutOfMemory;
    }
};

fn finalizeRecoveredCloseBackend(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    durable_root: []const u8,
    transport_root: []const u8,
    record: terminal_store.Record,
) !void {
    switch (record.backend) {
        .native => try finalizeRecoveredNativeClose(
            alloc,
            process_provider,
            record,
        ),
        .tmux => try tmux_session.cleanupOwnedNamespaceChecked(
            alloc,
            process_provider,
            durable_root,
            transport_root,
            record.backend_identity,
            if (record.pid) |pid|
                if (record.process_token) |process_token|
                    .{ .pid = pid, .process_token = process_token }
                else
                    null
            else
                null,
            null,
        ),
    }
}

fn finalizeRecoveredNativeClose(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    record: terminal_store.Record,
) !void {
    const pid = record.pid orelse return;
    const token_text = record.process_token orelse return;
    const token = process_identity.ProcessInstanceToken.parse(token_text) catch
        return error.ProcessIdentityUnavailable;
    switch (process_provider.matchToken(alloc, pid, token)) {
        .missing, .mismatched => return,
        .unavailable => return error.ProcessIdentityUnavailable,
        .matched => {},
    }
    process_provider.signalProcess(alloc, pid, token) catch |err| switch (err) {
        error.ProcessIdentityMismatch, error.ProcessNotFound => return,
        error.ProcessIdentityIndeterminate => return error.ProcessIdentityUnavailable,
        else => return err,
    };
}

fn requireCloseCandidate(
    session_id: []const u8,
    outcome: terminal_store.CloseCommitOutcome,
) !void {
    switch (outcome) {
        .previous => |err| return err,
        .candidate => |deferred| if (deferred) |err| {
            debug_trace.logf(
                "terminal_store",
                "committed close reconciliation deferred id={s} err={s}",
                .{ session_id, @errorName(err) },
            );
        },
        .indeterminate => |err| {
            debug_trace.logf(
                "terminal_store",
                "close intent indeterminate id={s} err={s}",
                .{ session_id, @errorName(err) },
            );
            return err;
        },
    }
}

fn definitiveTmuxRecoveryLoss(err: anyerror) bool {
    return switch (err) {
        error.TmuxRecoveryMissing,
        error.TmuxRecoveryReplaced,
        error.TmuxCompletionUnavailable,
        error.MalformedTmuxLifecycle,
        error.MalformedTmuxShellIdentity,
        error.MalformedTmuxManifest,
        error.MalformedTmuxPane,
        error.TmuxRecoveryManifestMissing,
        error.TmuxRecoveryShellIdentityMissing,
        => true,
        else => false,
    };
}

const SignalTarget = struct {
    pid: std.posix.pid_t,
    token: process_identity.ProcessInstanceToken,
};

const ProcessGroupDelivery = enum {
    delivered,
    missing,
    failed,
};

fn shouldPauseRecoveredTmuxProcess(
    lifecycle: contracts.Lifecycle,
    terminal_present: bool,
    child_pid_present: bool,
) bool {
    return lifecycle == .starting and !terminal_present and child_pid_present;
}

const Session = struct {
    const LaunchPhase = enum(u8) { prepared, launching, released, failed };

    alloc: Allocator,
    tracker: WorkTracker,
    id: []u8,
    shell: []u8,
    cwd: []u8,
    command: ?[]u8,
    startup_match: ?[]u8,
    startup_match_seen: bool = false,
    dimensions: contracts.Dimensions,
    mutex: std.Io.Mutex = .init,
    write_mutex: std.Io.Mutex = .init,
    lifecycle: contracts.Lifecycle = .starting,
    last_output_ms: i64,
    child_pid: ?std.posix.pid_t = null,
    child_token: ?process_identity.ProcessInstanceToken = null,
    recovered_start_identity: bool = false,
    term: ?std.process.Child.Term = null,
    shell_ready_seen: bool = false,
    start_failure: ?contracts.StructuredErrorCode = null,
    master_fd: ?std.posix.fd_t = null,
    tmux_backend: ?tmux_session.Backend = null,
    tmux_capture: ?std.Io.net.Stream = null,
    tmux_lifecycle_index: usize = 0,
    launcher: ?std.process.Child = null,
    launcher_token: ?process_identity.ProcessInstanceToken = null,
    control_file: ?std.Io.File = null,
    liveness_file: ?std.Io.File = null,
    output_thread: ?std.Thread = null,
    control_thread: ?std.Thread = null,
    timeout_thread: ?std.Thread = null,
    timeout_done: std.Io.Event = .unset,
    timeout_at_ms: ?i64 = null,
    output_done: std.Io.Event = .unset,
    output_active: std.atomic.Value(bool) = .init(false),
    command_boundary_requested: std.atomic.Value(bool) = .init(false),
    command_boundary_done: std.Io.Event = .unset,
    command_start_cursor: ?contracts.RawCursor = null,
    backend_done: std.Io.Event = .unset,
    backend_join_mutex: std.Io.Mutex = .init,
    backend_started: bool = false,
    backend_detaching: std.atomic.Value(bool) = .init(false),
    live_counted: bool = false,
    input_quiesced: bool = false,
    close_committed: bool = false,
    engine: terminal_engine.Grid,
    screen_available: bool = true,
    durable: terminal_store.DurableSession,
    workspace_root: []u8,
    launch_phase: std.atomic.Value(LaunchPhase) = .init(.prepared),

    fn init(
        alloc: Allocator,
        tracker: WorkTracker,
        profile: *terminal_store.ProfileStore,
        host_identity: []const u8,
        id: []u8,
        request: contracts.StartRequest,
        persistence: contracts.StartPersistence,
        cancel_flag: read_cancellation.CancelFlag,
    ) !Session {
        try read_cancellation.check(cancel_flag);
        var login_shell_buffer: [4096]u8 = undefined;
        const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
        const invocation = try shell_resolver.resolve(configured, request.shell);
        const shell = try alloc.dupe(u8, invocation.path);
        errdefer alloc.free(shell);
        const cwd = try alloc.dupe(u8, request.cwd);
        errdefer alloc.free(cwd);
        const workspace_root = try alloc.dupe(
            u8,
            persistence.grant.principal.workspace_root,
        );
        errdefer alloc.free(workspace_root);
        const command = if (request.command) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (command) |value| alloc.free(value);
        const startup_match = if (request.return_when) |condition|
            switch (condition) {
                .match => |pattern| try alloc.dupe(u8, pattern),
                .started, .exit, .quiet => null,
            }
        else
            null;
        errdefer if (startup_match) |value| alloc.free(value);
        const dimensions = request.dimensions orelse default_dimensions;
        var engine = try terminal_engine.Grid.init(
            alloc,
            dimensions.columns,
            dimensions.rows,
        );
        errdefer engine.deinit();
        const now_ms = io_mod.milliTimestamp();
        const durable = try terminal_store.DurableSession.create(profile, .{
            .session_id = id,
            .host_identity = host_identity,
            .shell = shell,
            .cwd = cwd,
            .command = command,
            .timeout_ms = request.timeout_ms,
            .backend = request.backend,
            .dimensions = dimensions,
            .persistence = persistence,
            .now_ms = now_ms,
            .cancel_flag = cancel_flag,
        });
        return .{
            .alloc = alloc,
            .tracker = tracker,
            .id = id,
            .shell = shell,
            .cwd = cwd,
            .command = command,
            .startup_match = startup_match,
            .dimensions = dimensions,
            .last_output_ms = now_ms,
            .engine = engine,
            .durable = durable,
            .workspace_root = workspace_root,
        };
    }

    fn initRecovered(
        alloc: Allocator,
        tracker: WorkTracker,
        durable_value: terminal_store.DurableSession,
    ) !Session {
        var durable = durable_value;
        errdefer durable.deinit();
        const id = try alloc.dupe(u8, durable.record.session_id);
        errdefer alloc.free(id);
        const shell = try alloc.dupe(u8, durable.record.shell);
        errdefer alloc.free(shell);
        const cwd = try alloc.dupe(u8, durable.record.cwd);
        errdefer alloc.free(cwd);
        var execution_scope = try durable.load_recovery_execution_scope(alloc);
        errdefer execution_scope.deinit(alloc);
        const command = if (durable.record.command) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (command) |value| alloc.free(value);
        var screen_available = true;
        const engine = reconstructEngine(alloc, &durable) catch |err| switch (err) {
            error.ScreenMissing,
            error.ScreenCorrupt,
            error.ScreenUnsupported,
            error.ScreenRetentionEvicted,
            error.ScreenRawGap,
            error.ScreenResizeUncheckpointed,
            => blk: {
                screen_available = false;
                break :blk try terminal_engine.Grid.init(
                    alloc,
                    durable.record.dimensions.columns,
                    durable.record.dimensions.rows,
                );
            },
            else => return err,
        };
        const child_pid = if (durable.record.pid) |value|
            std.fmt.parseInt(std.posix.pid_t, value, 10) catch null
        else
            null;
        const child_token = if (durable.record.process_token) |value|
            process_identity.ProcessInstanceToken.parse(value) catch null
        else
            null;
        return .{
            .alloc = alloc,
            .tracker = tracker,
            .id = id,
            .shell = shell,
            .cwd = cwd,
            .command = command,
            .startup_match = null,
            .dimensions = durable.record.dimensions,
            .lifecycle = durable.record.lifecycle,
            .last_output_ms = durable.record.updated_at_ms,
            .timeout_at_ms = durable.record.timeout_at_ms,
            .child_pid = child_pid,
            .child_token = child_token,
            .term = if (durable.record.termination) |termination| switch (termination) {
                .exited => |code| .{ .exited = @intCast(code) },
                .signal => |signal| if (signalFromInt(signal)) |value|
                    .{ .signal = value }
                else
                    null,
            } else null,
            .shell_ready_seen = durable.record.lifecycle == .running,
            .engine = engine,
            .screen_available = screen_available,
            .durable = durable,
            .workspace_root = execution_scope.workspace_root,
        };
    }

    fn deinitUnlaunched(self: *Session) void {
        self.engine.deinit();
        self.durable.deinit();
        if (self.startup_match) |pattern| self.alloc.free(pattern);
        if (self.command) |command| self.alloc.free(command);
        self.alloc.free(self.cwd);
        self.alloc.free(self.workspace_root);
        self.alloc.free(self.shell);
        self.alloc.free(self.id);
        self.* = undefined;
    }

    fn launch(
        self: *Session,
        request: contracts.StartRequest,
        durable_root: []const u8,
        transport_root: []const u8,
        cancelled: *const std.atomic.Value(bool),
    ) !void {
        self.launch_phase.store(.launching, .release);
        errdefer if (self.launch_phase.load(.acquire) != .released) self.launch_phase.store(.failed, .release);
        try self.checkLaunchCancellation(cancelled);
        try switch (request.backend) {
            .native => self.launchNative(request, cancelled),
            .tmux => self.launchTmux(request, durable_root, transport_root, cancelled),
        };
    }

    fn checkLaunchCancellation(self: *Session, cancelled: *const std.atomic.Value(bool)) error{Cancelled}!void {
        if (cancelled.load(.acquire) or self.backend_detaching.load(.acquire)) return error.Cancelled;
    }

    fn startTimeoutWatcher(self: *Session) !void {
        if (self.timeout_thread != null or self.timeout_at_ms == null or
            self.timeout_done.isSet()) return;
        self.timeout_thread = try std.Thread.spawn(.{}, timeoutMain, .{self});
    }

    fn stopTimeoutWatcher(self: *Session) void {
        self.timeout_done.set(io_mod.getIo());
        if (self.timeout_thread) |thread| {
            thread.join();
            self.timeout_thread = null;
        }
    }

    fn timeoutMain(self: *Session) void {
        const deadline_ms = self.timeout_at_ms orelse return;
        while (!self.timeout_done.isSet()) {
            const now_ms = io_mod.milliTimestamp();
            if (now_ms >= deadline_ms) break;
            const remaining_ms = deadline_ms - now_ms;
            self.timeout_done.waitTimeout(io_mod.getIo(), .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(remaining_ms),
            } }) catch |err| switch (err) {
                error.Timeout => continue,
                error.Canceled => return,
            };
        }
        if (self.timeout_done.isSet()) return;

        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (self.lifecycle != .starting and self.lifecycle != .running) {
            self.mutex.unlock(zio);
            return;
        }
        self.mutex.unlock(zio);
        self.durable.mark_timed_out(io_mod.milliTimestamp(), &self.backend_detaching) catch |err| {
            if (err == error.Cancelled) return;
            debug_trace.logf(
                "terminal_host",
                "terminal timeout persistence failed id={s} err={s}",
                .{ self.id, @errorName(err) },
            );
        };
        if (!self.signalProcess(.kill)) self.markLost();
    }

    fn launchTmux(
        self: *Session,
        request: contracts.StartRequest,
        durable_root: []const u8,
        transport_root: []const u8,
        cancelled: *const std.atomic.Value(bool),
    ) !void {
        var invocation = try shell_resolver.resolve(
            null,
            pinnedShell(request.shell, self.shell),
        );

        const executable = try self_exe.pathForPeerReexec(self.alloc);
        defer self.alloc.free(executable);
        var paths = try tmux_session.Paths.init(
            self.alloc,
            durable_root,
            transport_root,
            self.durable.record.backend_identity,
        );
        defer paths.deinit(self.alloc);
        var nonce_bytes: [16]u8 = undefined;
        io_mod.getIo().random(&nonce_bytes);
        const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);
        const command_path = if (request.command != null) paths.command else null;
        const bootstrap = try shell_resolver.buildBootstrap(
            self.alloc,
            executable,
            paths.marker_socket,
            &nonce,
            command_path,
        );
        defer self.alloc.free(bootstrap);
        const source_command = try shell_resolver.buildSourceCommand(
            self.alloc,
            paths.bootstrap,
        );
        defer self.alloc.free(source_command);
        if (request.command != null) invocation.setCommand(source_command);

        try self.checkLaunchCancellation(cancelled);
        var backend = try tmux_session.Backend.start(
            self.alloc,
            self.durable.profile.process_provider,
            durable_root,
            transport_root,
            self.durable.record.backend_identity,
            executable,
            self.dimensions,
            .{
                .argv = invocation.argv(),
                .cwd = request.cwd,
                .control_path = paths.marker_socket,
                .control_nonce = &nonce,
                .bootstrap_path = paths.bootstrap,
                .bootstrap = bootstrap,
                .command_path = command_path,
                .command = request.command,
                .interactive_source = if (request.command == null)
                    source_command
                else
                    null,
                .tmux_socket = paths.socket,
                .tmux_target = paths.target,
                .lifecycle_path = paths.lifecycle,
                .shell_identity_path = paths.shell_identity,
                .manifest_ready_path = paths.manifest_ready,
                .release_path = paths.release,
                .command_release_path = paths.command_release,
            },
        );
        var backend_owned = true;
        errdefer if (backend_owned) {
            backend.killSession();
            backend.deinit();
        };
        try backend.beginCapture();
        var capture = try backend.acceptCapture();
        var capture_owned = true;
        errdefer if (capture_owned) capture.close(io_mod.getIo());

        self.tmux_backend = backend;
        backend_owned = false;
        self.tmux_capture = capture;
        capture_owned = false;
        self.output_active.store(true, .release);
        self.output_thread = std.Thread.spawn(.{}, outputMain, .{self}) catch |err| {
            self.output_active.store(false, .release);
            self.tmux_capture.?.close(io_mod.getIo());
            self.tmux_capture = null;
            self.tmux_backend.?.killSession();
            self.tmux_backend.?.deinit();
            self.tmux_backend = null;
            return err;
        };
        self.backend_started = true;
        self.control_thread = std.Thread.spawn(.{}, tmuxControlMain, .{self}) catch |err| {
            self.backend_started = false;
            self.tmux_backend.?.stopCapture(&self.backend_detaching);
            self.tmux_capture.?.close(io_mod.getIo());
            self.tmux_capture = null;
            self.output_thread.?.join();
            self.output_thread = null;
            self.tmux_backend.?.killSession();
            self.tmux_backend.?.deinit();
            self.tmux_backend = null;
            return err;
        };
        maybeDelayForTest("FX_TERMINAL_TEST_TMUX_PREPARED_RELEASE_DELAY_MS");
        try self.checkLaunchCancellation(cancelled);
        self.tmux_backend.?.release() catch |err| {
            self.tmux_backend.?.killSession();
            return err;
        };
        self.launch_phase.store(.released, .release);
    }

    fn recoverTmux(
        self: *Session,
        durable_root: []const u8,
        transport_root: []const u8,
    ) !bool {
        const executable = try self_exe.pathForPeerReexec(self.alloc);
        defer self.alloc.free(executable);
        const backend = tmux_session.Backend.recover(
            self.alloc,
            self.durable.profile.process_provider,
            durable_root,
            transport_root,
            self.durable.record.backend_identity,
            executable,
        ) catch |err| {
            debug_trace.logf(
                "terminal_host",
                "tmux recovery stage=backend id={s} err={s}",
                .{ self.id, @errorName(err) },
            );
            return err;
        };
        self.tmux_backend = backend;
        const recovered = &self.tmux_backend.?;
        if (tmuxRecoveryFailure(self.id, "after-backend")) return error.InjectedFailure;

        const frames = recovered.lifecycle() catch |err| {
            debug_trace.logf("terminal_host", "tmux recovery stage=lifecycle id={s} err={s}", .{ self.id, @errorName(err) });
            return err;
        };
        defer self.alloc.free(frames);
        if (tmuxRecoveryFailure(self.id, "lifecycle") or
            tmuxRecoveryFailure(self.id, "allocation") or
            tmuxRecoveryFailure(self.id, "storage")) return error.InjectedFailure;
        const terminal_present = tmuxTerminalFrame(frames) != null;
        if (recovered.paneIsDead() and !terminal_present) {
            return error.TmuxCompletionUnavailable;
        }
        if (self.lifecycle == .starting) {
            if (tmuxShellPid(frames)) |raw_pid| {
                const identity = try recovered.shellIdentity();
                if (std.math.cast(u32, identity.pid) != raw_pid) {
                    return error.TmuxRecoveryReplaced;
                }
                if (!terminal_present) {
                    var pid_buffer: [32]u8 = undefined;
                    const pid_text = try std.fmt.bufPrint(
                        &pid_buffer,
                        "{d}",
                        .{identity.pid},
                    );
                    switch (self.durable.profile.process_provider.matchToken(
                        self.alloc,
                        pid_text,
                        identity.process_token,
                    )) {
                        .matched => {},
                        .missing, .mismatched => return error.TmuxRecoveryReplaced,
                        .unavailable => return error.TmuxRecoveryIdentityUnavailable,
                    }
                }
                self.child_pid = identity.pid;
                self.child_token = identity.process_token;
                self.recovered_start_identity = true;
            }
        }
        if (tmuxRecoveryFailure(self.id, "identity")) return error.InjectedFailure;
        const process_paused = shouldPauseRecoveredTmuxProcess(
            self.lifecycle,
            terminal_present,
            self.child_pid != null,
        );
        if (process_paused and !self.signalNative(std.c.SIG.STOP)) {
            return error.TmuxChildIdentityUnavailable;
        }
        defer if (process_paused) {
            if (!self.signalNative(std.c.SIG.CONT)) {
                debug_trace.logf(
                    "terminal_host",
                    "tmux recovery resume failed id={s}",
                    .{self.id},
                );
            }
        };

        if (tmuxRecoveryFailure(self.id, "capture")) return error.InjectedFailure;
        var capture = recovered.captureScreen() catch |err| {
            debug_trace.logf("terminal_host", "tmux recovery stage=screen-capture id={s} err={s}", .{ self.id, @errorName(err) });
            return err;
        };
        defer capture.deinit();
        if (tmuxRecoveryFailure(self.id, "screen-capture")) return error.InjectedFailure;
        self.reanchorTmuxScreen(capture) catch |err| {
            debug_trace.logf("terminal_host", "tmux recovery stage=screen-reanchor id={s} err={s}", .{ self.id, @errorName(err) });
            return err;
        };
        if (tmuxRecoveryFailure(self.id, "screen-reanchor")) return error.InjectedFailure;
        self.launch_phase.store(.released, .release);

        if (terminal_present) {
            try self.applyRecoveredTmuxFrames(frames);
            try recovered.cleanupChecked(
                self.durable.profile.process_provider,
                null,
            );
            recovered.deinit();
            self.tmux_backend = null;
            return false;
        }

        if (self.lifecycle == .running) {
            self.tmux_lifecycle_index = tmuxStartupFrameCount(frames);
        }
        recovered.beginCapture() catch |err| {
            debug_trace.logf("terminal_host", "tmux recovery stage=begin-capture id={s} err={s}", .{ self.id, @errorName(err) });
            return err;
        };
        if (tmuxRecoveryFailure(self.id, "begin-capture")) return error.InjectedFailure;
        const stream = recovered.acceptCapture() catch |err| {
            debug_trace.logf("terminal_host", "tmux recovery stage=accept-capture id={s} err={s}", .{ self.id, @errorName(err) });
            return err;
        };
        self.tmux_capture = stream;
        if (tmuxRecoveryFailure(self.id, "accept-capture")) return error.InjectedFailure;
        self.output_active.store(true, .release);
        self.output_thread = std.Thread.spawn(.{}, outputMain, .{self}) catch |err| {
            self.output_active.store(false, .release);
            return err;
        };
        if (tmuxRecoveryFailure(self.id, "output-thread")) return error.InjectedFailure;
        if (self.lifecycle == .starting and self.child_pid == null) {
            self.tmux_backend.?.release() catch |err| {
                debug_trace.logf("terminal_host", "tmux recovery stage=release-prepared id={s} err={s}", .{ self.id, @errorName(err) });
                return err;
            };
            self.launch_phase.store(.released, .release);
            if (tmuxRecoveryFailure(self.id, "release")) return error.InjectedFailure;
        }
        if (tmuxRecoveryFailure(self.id, "control-thread")) return error.InjectedFailure;
        self.control_thread = try std.Thread.spawn(.{}, tmuxControlMain, .{self});
        self.backend_started = true;
        try self.startTimeoutWatcher();
        return true;
    }

    fn reanchorTmuxScreen(
        self: *Session,
        capture: tmux_session.ScreenCapture,
    ) !void {
        const now_ms = io_mod.milliTimestamp();
        if (self.durable.record.raw_gap == null) {
            _ = try self.durable.begin_raw_gap(now_ms);
        }
        if (tmuxRecoveryFailure(self.id, "after-gap")) return error.InjectedFailure;
        if (capture.dimensions.rows != self.dimensions.rows or
            capture.dimensions.columns != self.dimensions.columns)
        {
            try self.durable.check_resize_capacity(capture.dimensions);
            try self.durable.resize(capture.dimensions, now_ms);
            try self.engine.resize(
                capture.dimensions.columns,
                capture.dimensions.rows,
            );
        }
        self.dimensions = capture.dimensions;
        self.screen_available = false;
        if (!capture.exact_modes_available) {
            debug_trace.logf(
                "terminal_host",
                "tmux screen reanchor unavailable id={s} reason=unobservable_modes",
                .{self.id},
            );
            return;
        }
        return error.TmuxScreenFactsUnavailable;
    }

    fn applyRecoveredTmuxFrames(
        self: *Session,
        frames: []const tmux_session.LifecycleFrame,
    ) !void {
        if (frames.len == 0 or frames[0].kind != .prepared) {
            return error.InvalidTmuxLifecycle;
        }
        for (frames[1..]) |frame| {
            if (self.lifecycle == .running and !tmuxLifecycleTerminal(frame.kind)) {
                continue;
            }
            switch (frame.kind) {
                .prepared => return error.InvalidTmuxLifecycle,
                .shell_ready => if (self.command == null) {
                    self.publishStarted(frame.value);
                } else {
                    self.shell_ready_seen = true;
                },
                .command_started => {
                    if (self.command == null or !self.shell_ready_seen) {
                        return error.InvalidTmuxLifecycle;
                    }
                    self.command_start_cursor = self.durable.output_cursor();
                    self.publishStarted(frame.value);
                },
                .command_exited => self.setTerm(.{ .exited = @intCast(frame.value) }),
                .command_signal => {
                    const signal = signalFromInt(frame.value) orelse
                        return error.InvalidTmuxLifecycle;
                    self.setTerm(.{ .signal = signal });
                },
                .startup_failed => self.handleControl(.{
                    .kind = .startup_failed,
                    .value = frame.value,
                }),
                .invalid_term => self.markLost(),
            }
        }
    }

    fn launchNative(self: *Session, request: contracts.StartRequest, cancelled: *const std.atomic.Value(bool)) !void {
        var invocation = try shell_resolver.resolve(
            null,
            pinnedShell(request.shell, self.shell),
        );

        var nonce_bytes: [16]u8 = undefined;
        io_mod.getIo().random(&nonce_bytes);
        const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);
        var path_bytes: [16]u8 = undefined;
        io_mod.getIo().random(&path_bytes);
        const path_suffix = std.fmt.bytesToHex(path_bytes, .lower);
        const control_path = try std.fmt.allocPrint(
            self.alloc,
            "/tmp/fx-terminal-{s}.sock",
            .{path_suffix},
        );
        defer self.alloc.free(control_path);
        const bootstrap_path = try std.fmt.allocPrint(
            self.alloc,
            "/tmp/fx-terminal-{s}.bootstrap",
            .{path_suffix},
        );
        defer self.alloc.free(bootstrap_path);
        const command_path = if (request.command != null)
            try std.fmt.allocPrint(
                self.alloc,
                "/tmp/fx-terminal-{s}.command",
                .{path_suffix},
            )
        else
            null;
        defer if (command_path) |path| self.alloc.free(path);

        const executable = try self_exe.pathForPeerReexec(self.alloc);
        defer self.alloc.free(executable);
        const bootstrap = try shell_resolver.buildBootstrap(
            self.alloc,
            executable,
            control_path,
            &nonce,
            command_path,
        );
        defer self.alloc.free(bootstrap);
        const source_command = try shell_resolver.buildSourceCommand(
            self.alloc,
            bootstrap_path,
        );
        defer self.alloc.free(source_command);
        if (request.command != null) invocation.setCommand(source_command);

        const pty = try openPty();
        var master_open = true;
        errdefer if (master_open) closeFd(pty.master);
        var slave_open = true;
        defer if (slave_open) closeFd(pty.slave);
        try resizeFd(pty.slave, self.dimensions);
        if (request.command == null) try setEcho(pty.slave, false);

        const helper_argv = [_][]const u8{ executable, launcher_mode };
        const slave_file = std.Io.File{
            .handle = pty.slave,
            .flags = .{ .nonblocking = false },
        };
        try self.checkLaunchCancellation(cancelled);
        var child = try std.process.spawn(io_mod.getIo(), .{
            .argv = &helper_argv,
            .stdin = .pipe,
            .stdout = .{ .file = slave_file },
            .stderr = .pipe,
        });
        var child_owned = true;
        errdefer if (child_owned) child.kill(io_mod.getIo());
        var launcher_pid_buffer: [32]u8 = undefined;
        const launcher_pid = try std.fmt.bufPrint(&launcher_pid_buffer, "{d}", .{child.id orelse return error.ChildIdentityMissing});
        const launcher_token = try self.durable.profile.process_provider.captureToken(self.alloc, launcher_pid);
        closeFd(pty.slave);
        slave_open = false;

        var config_output: std.Io.Writer.Allocating = .init(self.alloc);
        defer config_output.deinit();
        try std.json.Stringify.value(LauncherConfig{
            .argv = invocation.argv(),
            .cwd = request.cwd,
            .dimensions = self.dimensions,
            .control_path = control_path,
            .control_nonce = &nonce,
            .bootstrap_path = bootstrap_path,
            .bootstrap = bootstrap,
            .command_path = command_path,
            .command = request.command,
        }, .{}, &config_output.writer);
        if (config_output.written().len > launcher_config_bytes) {
            return error.LauncherConfigTooLarge;
        }
        var length_bytes: [4]u8 = undefined;
        std.mem.writeInt(
            u32,
            &length_bytes,
            @intCast(config_output.written().len),
            .little,
        );

        var input = child.stdin orelse return error.LauncherInputMissing;
        child.stdin = null;
        var input_open = true;
        errdefer if (input_open) input.close(io_mod.getIo());
        try input.writeStreamingAll(io_mod.getIo(), &length_bytes);
        try input.writeStreamingAll(io_mod.getIo(), config_output.written());

        var control = child.stderr orelse return error.LauncherControlMissing;
        child.stderr = null;
        var control_open = true;
        errdefer if (control_open) control.close(io_mod.getIo());
        const prepared = readControlFile(control, &self.backend_detaching) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            else => return error.LauncherNotPrepared,
        };
        if (prepared.kind != .prepared) return error.LauncherNotPrepared;

        self.mutex.lockUncancelable(io_mod.getIo());
        self.master_fd = pty.master;
        master_open = false;
        self.launcher = child;
        self.launcher_token = launcher_token;
        child_owned = false;
        self.control_file = control;
        self.mutex.unlock(io_mod.getIo());
        control_open = false;
        self.output_active.store(true, .release);
        self.output_thread = std.Thread.spawn(.{}, outputMain, .{self}) catch |err| {
            self.output_active.store(false, .release);
            return err;
        };
        self.backend_started = true;
        self.control_thread = std.Thread.spawn(.{}, controlMain, .{self}) catch |err| {
            self.backend_started = false;
            closeFd(self.master_fd.?);
            self.master_fd = null;
            self.output_thread.?.join();
            self.output_thread = null;
            return err;
        };
        if (request.command == null) {
            try writeAllFd(self.master_fd.?, source_command, true);
        }
        self.write_mutex.lockUncancelable(io_mod.getIo());
        defer self.write_mutex.unlock(io_mod.getIo());
        try self.checkLaunchCancellation(cancelled);
        self.liveness_file = input;
        input_open = false;
        try input.writeStreamingAll(io_mod.getIo(), &.{1});
        self.launch_phase.store(.released, .release);
    }

    fn deinit(self: *Session) void {
        const already_detaching = self.backend_detaching.load(.acquire);
        self.shutdown();
        self.stopTimeoutWatcher();
        if (self.backend_started) {
            self.finalizeBackend();
        } else {
            if (self.output_thread) |thread| thread.join();
            if (self.master_fd) |fd| closeFd(fd);
            if (self.tmux_capture) |stream| stream.close(io_mod.getIo());
            if (self.control_file) |file| file.close(io_mod.getIo());
            if (self.liveness_file) |file| file.close(io_mod.getIo());
            if (self.launcher) |*child| {
                if (child.id != null) child.kill(io_mod.getIo());
            }
        }
        if (self.tmux_backend) |*backend| {
            if (!self.close_committed and !already_detaching) backend.killSession();
            if (!self.close_committed and already_detaching) debug_trace.logf("terminal_host", "session destruction leaves prior forced namespace outcome unchanged id={s}", .{self.id});
            backend.deinit();
            self.tmux_backend = null;
        }
        self.markNotLive();
        self.deinitUnlaunched();
    }

    fn deinitRecoveryAttempt(self: *Session) void {
        std.debug.assert(!self.backend_started);
        self.stopTmuxRecoveryHandles();
        if (self.tmux_backend) |*backend| {
            backend.deinitRetainingOwnedNamespace();
            self.tmux_backend = null;
        }
        self.markNotLive();
        self.deinitUnlaunched();
    }

    fn deinitRecoveredRegistryAttempt(self: *Session) void {
        if (!self.backend_started) {
            self.deinitRecoveryAttempt();
            return;
        }
        self.backend_detaching.store(true, .release);
        if (self.tmux_backend) |*backend| backend.stopCapture(&self.backend_detaching);
        if (self.tmux_capture) |stream| {
            stream.close(io_mod.getIo());
            self.tmux_capture = null;
        }
        self.backend_done.waitUncancelable(io_mod.getIo());
        if (self.control_thread) |thread| {
            thread.join();
            self.control_thread = null;
        }
        self.backend_started = false;
        if (self.tmux_backend) |*backend| {
            backend.deinitRetainingOwnedNamespace();
            self.tmux_backend = null;
        }
        self.markNotLive();
        self.deinitUnlaunched();
    }

    fn cleanupDefinitiveTmuxRecoveryAttempt(self: *Session) !void {
        std.debug.assert(!self.backend_started);
        self.stopTmuxRecoveryHandles();
        const backend = if (self.tmux_backend) |*value| value else return;
        backend.cleanupChecked(
            self.durable.profile.process_provider,
            null,
        ) catch |err| {
            backend.deinitRetainingOwnedNamespace();
            self.tmux_backend = null;
            return err;
        };
        backend.deinit();
        self.tmux_backend = null;
    }

    fn stopTmuxRecoveryHandles(self: *Session) void {
        if (self.tmux_backend) |*backend| backend.stopCapture(&self.backend_detaching);
        if (self.tmux_capture) |stream| {
            stream.close(io_mod.getIo());
            self.tmux_capture = null;
        }
        if (self.output_thread) |thread| {
            thread.join();
            self.output_thread = null;
        }
        self.output_active.store(false, .release);
    }

    fn shutdown(self: *Session) void {
        self.backend_detaching.store(true, .release);
        self.timeout_done.set(io_mod.getIo());
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        const running = self.lifecycle == .starting or self.lifecycle == .running;
        self.mutex.unlock(zio);
        if (running) _ = self.signalProcess(.kill);
        self.closeLiveness();
    }

    fn finalizeBackend(self: *Session) void {
        const zio = io_mod.getIo();
        self.backend_join_mutex.lockUncancelable(zio);
        defer self.backend_join_mutex.unlock(zio);
        if (!self.backend_started) return;
        self.backend_done.waitUncancelable(zio);
        self.stopTimeoutWatcher();
        if (self.control_thread) |thread| {
            thread.join();
            self.control_thread = null;
        }
        self.backend_started = false;
        self.durable.release_completed_handles(&self.backend_detaching);
    }

    fn markLive(self: *Session) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (!self.live_counted) {
            self.live_counted = true;
            self.tracker.update(true);
        }
        self.mutex.unlock(zio);
    }

    fn markNotLive(self: *Session) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (self.live_counted) {
            self.live_counted = false;
            self.tracker.update(false);
        }
        self.mutex.unlock(zio);
    }

    fn waitFor(
        self: *Session,
        condition: contracts.ReturnCondition,
        ceiling_ms: u64,
        cancelled: *const std.atomic.Value(bool),
    ) !contracts.ReturnOutcome {
        const start_ms = io_mod.milliTimestamp();
        const ceiling_i64: i64 = @intCast(@min(
            ceiling_ms,
            @as(u64, @intCast(std.math.maxInt(i64))),
        ));
        while (true) {
            if (cancelled.load(.acquire) or self.backend_detaching.load(.acquire)) return .cancelled;
            const now = io_mod.milliTimestamp();
            const zio = io_mod.getIo();
            read_cancellation.lock(zio, &self.mutex, &self.backend_detaching) catch return .cancelled;
            const outcome = self.matchConditionLocked(condition, now) catch {
                self.mutex.unlock(zio);
                return .cancelled;
            };
            const lost = self.lifecycle == .lost;
            self.mutex.unlock(zio);
            if (outcome) |value| return value;
            if (lost) return error.SessionLost;
            if (now - start_ms >= ceiling_i64) return .safety_ceiling;
            io_mod.sleep(wait_poll_ns);
        }
    }

    fn startFailureCode(self: *Session) contracts.StructuredErrorCode {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return self.start_failure orelse .session_lost;
    }

    fn isRecyclable(self: *Session) bool {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return (self.lifecycle == .exited or
            self.lifecycle == .lost or
            self.lifecycle == .closed) and !self.live_counted;
    }

    fn matchConditionLocked(
        self: *Session,
        condition: contracts.ReturnCondition,
        now_ms: i64,
    ) error{Cancelled}!?contracts.ReturnOutcome {
        if (self.term) |term| return outcomeFromTerm(term);
        return switch (condition) {
            .started => if (self.lifecycle == .running) .started else null,
            .exit => null,
            .quiet => |quiet_ms| blk: {
                if (self.lifecycle != .running) break :blk null;
                const quiet_i64: i64 = @intCast(@min(
                    quiet_ms,
                    @as(u64, @intCast(std.math.maxInt(i64))),
                ));
                break :blk if (now_ms - self.last_output_ms >= quiet_i64)
                    .condition_met
                else
                    null;
            },
            .match => |pattern| blk: {
                if (self.lifecycle != .running) break :blk null;
                if (self.command != null and self.startup_match != null and
                    std.mem.eql(u8, self.startup_match.?, pattern))
                {
                    break :blk if (self.startup_match_seen)
                        .condition_met
                    else
                        null;
                }
                const output = try self.durable.outputState(&self.backend_detaching);
                break :blk if (self.durable.containsCancellable(
                    pattern,
                    output.available_cursor,
                    &self.backend_detaching,
                ) catch |err| switch (err) {
                    error.Cancelled => return error.Cancelled,
                    else => false,
                })
                    .condition_met
                else
                    null;
            },
        };
    }

    fn startResult(
        self: *Session,
        outcome: contracts.ReturnOutcome,
        authorization: terminal_store.Authorization,
    ) (Allocator.Error || error{Cancelled})!contracts.OwnedResult {
        const zio = io_mod.getIo();
        try read_cancellation.lock(zio, &self.mutex, &self.backend_detaching);
        defer self.mutex.unlock(zio);
        const facts = try self.durable.factsCancellable(&self.backend_detaching);
        try read_cancellation.check(&self.backend_detaching);
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .start = .{
                .session = projectedFacts(facts, authorization),
                .outcome = outcome,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn waitResult(
        self: *Session,
        outcome: contracts.ReturnOutcome,
        authorization: terminal_store.Authorization,
    ) Allocator.Error!contracts.OwnedResult {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .wait = .{
                .session = self.factsLocked(authorization),
                .outcome = outcome,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn factsLocked(
        self: *const Session,
        authorization: terminal_store.Authorization,
    ) contracts.SessionFacts {
        var facts = self.durable.facts();
        if (self.backend_detaching.load(.acquire) and (self.term != null or self.backend_done.isSet())) {
            facts.lifecycle = self.lifecycle;
            facts.attention = .{};
        }
        return projectedFacts(facts, authorization);
    }

    fn signalProcess(self: *Session, signal: contracts.Signal) bool {
        return self.signalNative(signalValue(signal));
    }

    fn signalTarget(self: *Session) ?SignalTarget {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (!contracts.lifecycle_controls(self.lifecycle).signal) return null;
        return .{
            .pid = self.child_pid orelse return null,
            .token = self.child_token orelse return null,
        };
    }

    fn matchesSignalTarget(self: *Session, target: SignalTarget) bool {
        var pid_buffer: [32]u8 = undefined;
        const pid_text = std.fmt.bufPrint(
            &pid_buffer,
            "{d}",
            .{target.pid},
        ) catch return false;
        return self.durable.profile.process_provider.matchToken(
            self.alloc,
            pid_text,
            target.token,
        ) == .matched;
    }

    fn signalTerminalProcesses(
        self: *Session,
        signal: contracts.Signal,
    ) !?bool {
        const target = self.signalTarget() orelse return null;
        return try self.signalVerifiedTerminalTree(target, signal);
    }

    fn signalForOwnerExit(self: *Session) !?bool {
        const target = captured: {
            self.mutex.lockUncancelable(io_mod.getIo());
            defer self.mutex.unlock(io_mod.getIo());
            if (self.child_pid) |pid| if (self.child_token) |token| break :captured SignalTarget{ .pid = pid, .token = token };
            const launcher = self.launcher orelse return null;
            break :captured SignalTarget{
                .pid = launcher.id orelse return null,
                .token = self.launcher_token orelse return false,
            };
        };
        return try self.signalVerifiedTerminalTree(target, .kill);
    }

    fn signalVerifiedTerminalTree(self: *Session, target: SignalTarget, signal: contracts.Signal) !bool {
        if (!self.matchesSignalTarget(target)) return false;
        if (failSignalStageForTest("refresh")) {
            return error.ProcessIdentityUnavailable;
        }

        var descendants = try process_tree.Tracker.init(self.alloc);
        defer descendants.deinit();
        descendants.refresh(target.pid) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ProcessIdentityUnavailable,
        };
        if (!self.matchesSignalTarget(target)) return false;

        const shell_group_delivery = if (failSignalStageForTest("shell_group"))
            ProcessGroupDelivery.failed
        else
            self.signalVerifiedProcessGroup(target, signal);
        var descendants_delivery = descendants.signalOutsideProcessGroupChecked(
            signalValue(signal),
            target.pid,
        );
        if (failSignalStageForTest("outside_group")) {
            descendants_delivery.incomplete = true;
        }
        debug_trace.logf(
            "terminal_host",
            "session signal reached outside-group descendants id={s} count={d} incomplete={any}",
            .{ self.id, descendants_delivery.delivered, descendants_delivery.incomplete },
        );
        return terminalSignalCompleted(
            descendants_delivery,
            shell_group_delivery,
        );
    }

    fn signalVerifiedProcessGroup(
        self: *Session,
        target: SignalTarget,
        signal: contracts.Signal,
    ) ProcessGroupDelivery {
        if (!self.matchesSignalTarget(target)) {
            return if (processGroupMissing(target.pid)) .missing else .failed;
        }
        while (true) switch (std.c.errno(std.c.kill(
            -target.pid,
            signalValue(signal),
        ))) {
            .SUCCESS => return .delivered,
            .INTR => continue,
            .SRCH => return .missing,
            else => return .failed,
        };
    }

    fn signalNative(self: *Session, signal: std.c.SIG) bool {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        const pid = self.child_pid;
        const token = self.child_token;
        const running = self.lifecycle == .starting or self.lifecycle == .running;
        self.mutex.unlock(zio);
        if (!running or pid == null or token == null) return false;
        var pid_buffer: [32]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{pid.?}) catch
            return false;
        if (self.durable.profile.process_provider.matchToken(
            self.alloc,
            pid_text,
            token.?,
        ) != .matched) return false;
        return std.c.kill(-pid.?, signal) == 0;
    }

    fn appendOutput(self: *Session, bytes: []const u8) void {
        const zio = io_mod.getIo();
        read_cancellation.lock(zio, &self.write_mutex, &self.backend_detaching) catch {
            debug_trace.logf("terminal_host", "output append abandoned id={s} reason=owner_shutdown", .{self.id});
            return;
        };
        defer self.write_mutex.unlock(zio);
        var feed_result: ?terminal_engine.FeedResult = null;
        defer if (feed_result) |*result| result.deinit(self.alloc);
        var checkpoint_cursor: ?contracts.RawCursor = null;
        read_cancellation.lock(zio, &self.mutex, &self.backend_detaching) catch {
            debug_trace.logf("terminal_host", "output append abandoned id={s} reason=owner_shutdown", .{self.id});
            return;
        };
        const now_ms = io_mod.milliTimestamp();
        const appended = self.durable.appendOutput(bytes, now_ms, &self.backend_detaching) catch |err| {
            if (err == error.Cancelled) {
                self.screen_available = false;
                debug_trace.logf("terminal_host", "output append abandoned id={s} reason=owner_shutdown", .{self.id});
                self.mutex.unlock(zio);
                return;
            }
            const cursor = self.durable.record.output_cursor;
            debug_trace.logf(
                "terminal_host",
                "journal append failed id={s} cursor={d}:{d} raw_gap={any} err={s}",
                .{
                    self.id,
                    cursor.segment,
                    cursor.offset,
                    self.durable.record.raw_gap != null,
                    @errorName(err),
                },
            );
            self.persistLostLocked(now_ms);
            self.mutex.unlock(zio);
            return;
        };
        if (self.screen_available) {
            const feed_mode: terminal_engine.FeedMode = if (self.durable.record.backend == .tmux) .tmux_live else .native_live;
            feed_result = self.engine.feedModeCancellable(bytes, feed_mode, &self.backend_detaching) catch |err| blk: {
                self.screen_available = false;
                debug_trace.logf(
                    "terminal_host",
                    "screen feed unavailable id={s} err={s}",
                    .{ self.id, @errorName(err) },
                );
                if (err == error.Cancelled) {
                    self.mutex.unlock(zio);
                    return;
                }
                break :blk null;
            };
            if (feed_result != null) {
                checkpoint_cursor = appended.checkpoint_cursor;
            }
        }
        self.last_output_ms = now_ms;
        if (!self.startup_match_seen and self.startup_match != null) {
            const eligible = self.command == null or
                self.command_start_cursor != null;
            if (eligible) {
                const anchor = self.command_start_cursor orelse
                    appended.available_cursor;
                self.startup_match_seen = self.durable.containsCancellable(
                    self.startup_match.?,
                    anchor,
                    &self.backend_detaching,
                ) catch |err| failed: {
                    if (err == error.Cancelled) {
                        debug_trace.logf("terminal_host", "startup match scan abandoned id={s} reason=owner_shutdown", .{self.id});
                        self.mutex.unlock(zio);
                        return;
                    }
                    break :failed false;
                };
            }
        }
        const master_fd = if (self.input_quiesced) null else self.master_fd;
        self.mutex.unlock(zio);

        if (feed_result) |*result| {
            if (self.durable.record.backend == .tmux) {
                std.debug.assert(result.replies.items.len == 0);
            } else {
                const fd = master_fd orelse return;
                for (result.replies.items) |reply| {
                    writeAllFd(fd, reply.bytes, true) catch |err| {
                        debug_trace.logf(
                            "terminal_host",
                            "terminal protocol reply failed id={s} err={s}",
                            .{ self.id, @errorName(err) },
                        );
                        return;
                    };
                }
            }
        }

        if (checkpoint_cursor) |cursor| {
            read_cancellation.lock(zio, &self.mutex, &self.backend_detaching) catch return;
            defer self.mutex.unlock(zio);
            if (!self.screen_available) return;
            self.checkpointLockedCancellable(cursor, now_ms, &self.backend_detaching) catch |err| {
                debug_trace.logf(
                    "terminal_host",
                    "screen checkpoint failed id={s} err={s}",
                    .{ self.id, @errorName(err) },
                );
            };
        }
    }

    fn appendScreenTextLocked(
        self: *Session,
        engine: *const terminal_engine.Grid,
        screen_text: *std.ArrayList(u8),
    ) !void {
        var row: u16 = 1;
        while (row <= engine.rows) : (row += 1) {
            try engine.rowTextTrimmed(row, screen_text);
            try screen_text.append(self.alloc, '\n');
        }
    }

    fn checkpointLocked(
        self: *Session,
        applied_cursor: contracts.RawCursor,
        now_ms: i64,
    ) !void {
        return self.checkpointLockedCancellable(applied_cursor, now_ms, null) catch |err| switch (err) {
            error.Cancelled => unreachable,
            inline else => |other| return other,
        };
    }

    fn checkpointLockedCancellable(self: *Session, applied_cursor: contracts.RawCursor, now_ms: i64, cancel_flag: read_cancellation.CancelFlag) !void {
        const output = try self.durable.outputState(cancel_flag);
        if (contracts.compare_raw_cursors(
            applied_cursor,
            output.output_cursor,
        ) != .eq) return error.InvalidCheckpoint;
        const payload = try self.engine.checkpointPayloadCancellable(self.alloc, cancel_flag);
        defer self.alloc.free(payload);
        try read_cancellation.check(cancel_flag);
        const payload_len = std.math.cast(u32, payload.len) orelse
            return error.CheckpointTooLarge;
        const envelope = contracts.CheckpointEnvelope{
            .engine_schema_revision = terminal_engine.checkpoint_schema_revision,
            .applied_cursor = applied_cursor,
            .payload_len = payload_len,
            .checksum = try read_cancellation.sha256(payload, cancel_flag),
        };
        try self.durable.storeCheckpoint(envelope, payload, now_ms, cancel_flag);
    }

    fn handleControl(self: *Session, frame: ControlFrame) void {
        if (self.backend_detaching.load(.acquire)) switch (frame.kind) {
            .prepared, .shell_ready, .command_started => return,
            .command_exited, .command_signal, .startup_failed, .invalid_term => {},
        };
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        const closing = self.close_committed;
        self.mutex.unlock(zio);
        if (closing and frame.kind != .command_exited and
            frame.kind != .command_signal)
        {
            return;
        }
        switch (frame.kind) {
            .prepared => {},
            .shell_ready => {
                if (self.command == null) {
                    if (self.tmux_backend == null and
                        !self.establishStartupBoundary())
                    {
                        if (self.backend_detaching.load(.acquire)) return;
                        debug_trace.logf(
                            "terminal_host",
                            "terminal shell boundary unavailable id={s}",
                            .{self.id},
                        );
                        self.failClosed(.session_lost);
                        return;
                    }
                    self.publishStarted(frame.value);
                } else {
                    self.mutex.lockUncancelable(zio);
                    if (self.lifecycle != .starting or self.shell_ready_seen) {
                        debug_trace.logf(
                            "terminal_host",
                            "tmux shell-ready rejected id={s} lifecycle={s} seen={any}",
                            .{ self.id, @tagName(self.lifecycle), self.shell_ready_seen },
                        );
                        self.lifecycle = .lost;
                        self.start_failure = .session_lost;
                    } else {
                        self.shell_ready_seen = true;
                    }
                    self.mutex.unlock(zio);
                }
            },
            .command_started => {
                self.mutex.lockUncancelable(zio);
                const valid = self.command != null and
                    self.lifecycle == .starting and
                    self.shell_ready_seen;
                self.mutex.unlock(zio);
                if (!valid) {
                    debug_trace.logf(
                        "terminal_host",
                        "tmux recovered command boundary invalid id={s}",
                        .{self.id},
                    );
                    self.failClosed(.session_lost);
                    return;
                }
                if (!self.establishStartupBoundary()) {
                    if (self.backend_detaching.load(.acquire)) return;
                    debug_trace.logf(
                        "terminal_host",
                        "terminal command boundary unavailable id={s}",
                        .{self.id},
                    );
                    self.failClosed(.session_lost);
                    return;
                }
                self.publishStarted(frame.value);
                if (!self.releaseCommandEvaluation()) {
                    if (self.backend_detaching.load(.acquire)) return;
                    debug_trace.logf(
                        "terminal_host",
                        "tmux recovered command release unavailable id={s}",
                        .{self.id},
                    );
                    self.failClosed(.session_lost);
                }
            },
            .command_exited => self.setTerm(.{ .exited = @intCast(frame.value) }),
            .command_signal => {
                const signal = signalFromInt(frame.value) orelse {
                    self.markLost();
                    return;
                };
                self.setTerm(.{ .signal = signal });
            },
            .startup_failed => {
                debug_trace.logf(
                    "terminal_host",
                    "tmux startup failed id={s} code={d}",
                    .{ self.id, frame.value },
                );
                const failure: StartupFailure = switch (frame.value) {
                    1 => .shell_unavailable,
                    2 => .profile_failed,
                    3 => .control_failed,
                    else => {
                        self.markLost();
                        return;
                    },
                };
                self.failClosed(switch (failure) {
                    .shell_unavailable => .shell_unavailable,
                    .profile_failed, .control_failed => .startup_failed,
                });
            },
            .invalid_term => {
                debug_trace.logf(
                    "terminal_host",
                    "tmux launcher reported invalid term id={s}",
                    .{self.id},
                );
                self.markLost();
            },
        }
    }

    fn publishStarted(self: *Session, raw_pid: u32) void {
        const pid = std.math.cast(std.posix.pid_t, raw_pid) orelse {
            self.failClosed(.session_lost);
            return;
        };
        var pid_buffer: [32]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{pid}) catch {
            self.failClosed(.session_lost);
            return;
        };
        const recovered_token = if (self.recovered_start_identity and
            self.child_pid == pid)
            self.child_token
        else
            null;
        const token: ?process_identity.ProcessInstanceToken =
            if (recovered_token) |value|
                value
            else
                self.durable.profile.process_provider.captureToken(
                    self.alloc,
                    pid_text,
                ) catch null;
        if (token == null) {
            debug_trace.logf(
                "terminal_host",
                "tmux recovered child identity unavailable id={s} pid={d}",
                .{ self.id, pid },
            );
            self.failClosed(.process_identity_unavailable);
            return;
        }
        const zio = io_mod.getIo();
        read_cancellation.lock(zio, &self.mutex, &self.backend_detaching) catch return;
        if (self.lifecycle != .starting or
            (self.child_pid != null and !self.recovered_start_identity))
        {
            debug_trace.logf(
                "terminal_host",
                "terminal child start rejected id={s} lifecycle={s} pending={any}",
                .{ self.id, @tagName(self.lifecycle), self.recovered_start_identity },
            );
            self.persistLostLocked(io_mod.milliTimestamp());
        } else {
            self.durable.mark_started(
                pid_text,
                token.?,
                io_mod.milliTimestamp(),
                &self.backend_detaching,
            ) catch |err| {
                if (err == error.Cancelled) {
                    self.mutex.unlock(zio);
                    return;
                }
                debug_trace.logf(
                    "terminal_host",
                    "starting record update failed id={s} err={s}",
                    .{ self.id, @errorName(err) },
                );
                self.persistLostLocked(io_mod.milliTimestamp());
                self.mutex.unlock(zio);
                self.closeLiveness();
                return;
            };
            self.child_pid = pid;
            self.child_token = token;
            self.timeout_at_ms = self.durable.record.timeout_at_ms;
            self.recovered_start_identity = false;
            self.lifecycle = contracts.transition_lifecycle(
                self.lifecycle,
                .child_started,
            ) catch .lost;
        }
        const failed = self.lifecycle == .lost;
        self.mutex.unlock(zio);
        if (failed) {
            self.closeLiveness();
            return;
        }
        self.startTimeoutWatcher() catch |err| {
            debug_trace.logf(
                "terminal_host",
                "terminal timeout watcher failed id={s} err={s}",
                .{ self.id, @errorName(err) },
            );
            self.markLost();
        };
    }

    fn setTerm(self: *Session, term: std.process.Child.Term) void {
        const zio = io_mod.getIo();
        self.timeout_done.set(zio);
        if (self.backend_detaching.load(.acquire)) return self.setDetachedTerm(term);
        read_cancellation.lock(zio, &self.write_mutex, &self.backend_detaching) catch return self.setDetachedTerm(term);
        read_cancellation.lock(zio, &self.mutex, &self.backend_detaching) catch {
            self.write_mutex.unlock(zio);
            return self.setDetachedTerm(term);
        };
        const final_checkpoint = self.lifecycle == .running and self.screen_available;
        if (final_checkpoint) {
            const output = self.durable.outputState(&self.backend_detaching) catch {
                self.mutex.unlock(zio);
                self.write_mutex.unlock(zio);
                return self.setDetachedTerm(term);
            };
            self.checkpointLockedCancellable(
                output.output_cursor,
                io_mod.milliTimestamp(),
                &self.backend_detaching,
            ) catch |err| {
                if (err == error.Cancelled) {
                    self.mutex.unlock(zio);
                    self.write_mutex.unlock(zio);
                    return self.setDetachedTerm(term);
                }
                debug_trace.logf(
                    "terminal_host",
                    "final screen checkpoint failed id={s} err={s}",
                    .{ self.id, @errorName(err) },
                );
            };
        }
        self.mutex.unlock(zio);
        self.write_mutex.unlock(zio);
        read_cancellation.lock(zio, &self.mutex, &self.backend_detaching) catch return self.setDetachedTerm(term);
        if (self.close_committed) {
            self.term = term;
            self.lifecycle = .closed;
            self.mutex.unlock(zio);
            self.closeLiveness();
            return;
        }
        if (self.lifecycle != .running) {
            if (self.lifecycle == .starting) {
                debug_trace.logf(
                    "terminal_host",
                    "terminal exited before start publication id={s}",
                    .{self.id},
                );
                self.persistLostLocked(io_mod.milliTimestamp());
                self.start_failure = .startup_failed;
            }
            self.mutex.unlock(zio);
            self.closeLiveness();
            return;
        }
        const persisted: terminal_store.PersistedTermination = switch (term) {
            .exited => |code| .{ .exited = code },
            .signal => |signal| .{ .signal = @intFromEnum(signal) },
            .stopped, .unknown => {
                self.persistLostLocked(io_mod.milliTimestamp());
                self.mutex.unlock(zio);
                self.closeLiveness();
                return;
            },
        };
        const now_ms = io_mod.milliTimestamp();
        self.durable.persistTermination(
            persisted,
            now_ms,
            &self.backend_detaching,
        ) catch |err| {
            if (err == error.Cancelled) {
                self.mutex.unlock(zio);
                return self.setDetachedTerm(term);
            }
            debug_trace.logf(
                "terminal_host",
                "termination persistence failed id={s} err={s}",
                .{ self.id, @errorName(err) },
            );
            self.persistLostLocked(io_mod.milliTimestamp());
            self.mutex.unlock(zio);
            self.closeLiveness();
            return;
        };
        self.term = term;
        if (self.lifecycle != .closed) {
            self.lifecycle = contracts.transition_lifecycle(
                self.lifecycle,
                .child_exited,
            ) catch .lost;
        }
        self.mutex.unlock(zio);
    }

    fn setDetachedTerm(self: *Session, term: std.process.Child.Term) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.term = term;
        self.lifecycle = if (self.close_committed) .closed else switch (self.lifecycle) {
            .starting => .lost,
            .running => if (outcomeFromTerm(term) != null) .exited else .lost,
            else => self.lifecycle,
        };
        self.input_quiesced = true;
        self.mutex.unlock(io_mod.getIo());
        debug_trace.logf("terminal_host", "final terminal publication skipped id={s} reason=owner_shutdown", .{self.id});
    }

    fn failClosed(
        self: *Session,
        code: contracts.StructuredErrorCode,
    ) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (self.lifecycle == .starting or self.lifecycle == .running) {
            self.persistLostLocked(io_mod.milliTimestamp());
            self.start_failure = code;
        }
        self.mutex.unlock(zio);
        if (!self.backend_detaching.load(.acquire)) self.closeLiveness();
    }

    fn closeLiveness(self: *Session) void {
        const zio = io_mod.getIo();
        self.write_mutex.lockUncancelable(zio);
        defer self.write_mutex.unlock(zio);
        self.mutex.lockUncancelable(zio);
        const file = self.liveness_file;
        self.liveness_file = null;
        self.mutex.unlock(zio);
        if (file) |value| value.close(zio);
    }

    fn markLost(self: *Session) void {
        debug_trace.logf(
            "terminal_host",
            "terminal marked lost id={s}",
            .{self.id},
        );
        const zio = io_mod.getIo();
        self.timeout_done.set(zio);
        self.mutex.lockUncancelable(zio);
        if (self.lifecycle == .starting or self.lifecycle == .running) {
            self.persistLostLocked(io_mod.milliTimestamp());
            if (self.start_failure == null) self.start_failure = .session_lost;
        }
        self.mutex.unlock(zio);
        if (!self.backend_detaching.load(.acquire)) self.closeLiveness();
    }

    fn persistLostLocked(self: *Session, now_ms: i64) void {
        if (self.close_committed) {
            self.lifecycle = .lost;
            if (self.start_failure == null) self.start_failure = .session_lost;
            return;
        }
        self.durable.persistLost(now_ms, &self.backend_detaching) catch |err| {
            if (err == error.Cancelled) {
                debug_trace.logf("terminal_host", "terminal loss publication skipped id={s} reason=owner_shutdown", .{self.id});
                return;
            }
            debug_trace.logf(
                "terminal_host",
                "lost record update failed id={s} err={s}",
                .{ self.id, @errorName(err) },
            );
        };
        self.lifecycle = .lost;
        if (self.start_failure == null) self.start_failure = .session_lost;
    }

    fn establishStartupBoundary(self: *Session) bool {
        self.command_boundary_done.reset();
        self.command_boundary_requested.store(true, .release);
        if (!self.output_active.load(.acquire)) {
            self.command_boundary_requested.store(false, .release);
            return false;
        }
        self.command_boundary_done.waitUncancelable(io_mod.getIo());
        return self.output_active.load(.acquire);
    }

    fn commitStartupBoundary(self: *Session) void {
        if (self.command != null) {
            maybeDelayForTest("FX_TERMINAL_TEST_COMMAND_BOUNDARY_DELAY_MS");
        }
        const zio = io_mod.getIo();
        read_cancellation.lock(zio, &self.mutex, &self.backend_detaching) catch return;
        defer self.mutex.unlock(zio);
        if (self.command != null) {
            const output = self.durable.outputState(&self.backend_detaching) catch return;
            self.command_start_cursor = output.output_cursor;
            self.startup_match_seen = false;
        }
        self.last_output_ms = io_mod.milliTimestamp();
    }

    fn releaseCommandEvaluation(self: *Session) bool {
        const zio = io_mod.getIo();
        read_cancellation.lock(zio, &self.write_mutex, &self.backend_detaching) catch return false;
        defer self.write_mutex.unlock(zio);
        read_cancellation.lock(zio, &self.mutex, &self.backend_detaching) catch return false;
        const file = self.liveness_file;
        const tmux = if (self.tmux_backend) |*backend| backend else null;
        const running = self.lifecycle == .running;
        self.mutex.unlock(zio);
        if (!running or self.backend_detaching.load(.acquire)) return false;
        if (tmux) |backend| {
            backend.releaseCommand() catch return false;
            return true;
        }
        if (file == null) return false;
        file.?.writeStreamingAll(
            zio,
            &.{command_release_byte},
        ) catch return false;
        return true;
    }
};

fn pinnedShell(
    requested: contracts.ShellSpec,
    resolved_path: []const u8,
) contracts.ShellSpec {
    return .{ .executable = .{
        .path = resolved_path,
        .clean_start = switch (requested) {
            .user_login => false,
            .executable => |value| value.clean_start,
        },
    } };
}

fn screenAction(
    session: *Session,
    request: contracts.SessionRequest,
    cancelled: *const std.atomic.Value(bool),
) !contracts.OwnedResult {
    const authorization = try session.durable.authorize(
        request.authority.?,
        .screen,
    );
    const zio = io_mod.getIo();
    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    var recovered: ?terminal_engine.Grid = null;
    defer if (recovered) |*grid| grid.deinit();
    const grid = if (session.screen_available)
        &session.engine
    else blk: {
        recovered = try reconstructEngine(session.alloc, &session.durable);
        break :blk &recovered.?;
    };
    var snapshot = try grid.renderSnapshotCancellable(session.alloc, cancelled);
    defer snapshot.deinit(session.alloc);
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .screen = .{
            .session = session.factsLocked(authorization),
            .snapshot = snapshot.view(),
        } } },
    ) catch return error.OutOfMemory;
}

fn screenDurable(
    alloc: Allocator,
    durable: *terminal_store.DurableSession,
    authorization: terminal_store.Authorization,
    cancelled: *const std.atomic.Value(bool),
) !contracts.OwnedResult {
    var grid = try reconstructEngine(alloc, durable);
    defer grid.deinit();
    var snapshot = try grid.renderSnapshotCancellable(alloc, cancelled);
    defer snapshot.deinit(alloc);
    const facts = projectedFacts(durable.facts(), authorization);
    return contracts.OwnedResult.init(
        alloc,
        .{ .success = .{ .screen = .{
            .session = facts,
            .snapshot = snapshot.view(),
        } } },
    ) catch return error.OutOfMemory;
}

inline fn failReconstructedGrid(err: anytype) @TypeOf(err)!terminal_engine.Grid {
    return @errorCast(failReconstructedGridDynamic(err));
}

noinline fn failReconstructedGridDynamic(err: anyerror) anyerror!terminal_engine.Grid {
    return err;
}

test "reconstructed grid failures preserve exact error types and identities" {
    const corrupt = failReconstructedGrid(error.ScreenCorrupt);
    try std.testing.expect(
        @TypeOf(corrupt) == error{ScreenCorrupt}!terminal_engine.Grid,
    );
    try std.testing.expectError(error.ScreenCorrupt, corrupt);
    try std.testing.expectError(error.OutOfMemory, failReconstructedGrid(error.OutOfMemory));
}

fn reconstructEngine(
    alloc: Allocator,
    durable: *terminal_store.DurableSession,
) !terminal_engine.Grid {
    const initial = contracts.RawCursor{ .segment = 1, .offset = 0 };
    const available = durable.available_cursor();
    const output = durable.output_cursor();
    const checkpoint_reason: contracts.ScreenUnavailableReason = switch (durable.record.screen_recovery) {
        .available => .corrupt,
        .unavailable => |reason| reason,
    };

    var checkpoint = durable.load_checkpoint(alloc) catch |err| {
        const reason = terminal_store.checkpoint_load_unavailable_reason(err) orelse
            return err;
        return replayFromStart(
            alloc,
            durable,
            initial,
            available,
            output,
            reason,
        );
    } orelse return replayFromStart(
        alloc,
        durable,
        initial,
        available,
        output,
        checkpoint_reason,
    );
    defer checkpoint.deinit(alloc);
    if (checkpoint.envelope.engine_schema_revision !=
        terminal_engine.checkpoint_schema_revision)
    {
        return replayFromStart(
            alloc,
            durable,
            initial,
            available,
            output,
            .unsupported_schema,
        );
    }
    if (!terminal_store.contiguous_after_checkpoint(
        checkpoint.envelope,
        available,
        output,
    )) {
        try durable.mark_screen_unavailable(.raw_gap, io_mod.milliTimestamp());
        return failReconstructedGrid(error.ScreenRawGap);
    }

    var grid = terminal_engine.Grid.restoreCheckpoint(
        alloc,
        checkpoint.payload,
    ) catch |err| {
        const reason = engine_checkpoint_unavailable_reason(err) orelse
            return err;
        return replayFromStart(
            alloc,
            durable,
            initial,
            available,
            output,
            reason,
        );
    };
    errdefer grid.deinit();
    if (grid.rows != durable.record.dimensions.rows or
        grid.cols != durable.record.dimensions.columns)
    {
        return replayFromStart(
            alloc,
            durable,
            initial,
            available,
            output,
            .corrupt,
        );
    }
    replayEngine(
        alloc,
        durable,
        &grid,
        checkpoint.envelope.applied_cursor,
        output,
    ) catch |err| switch (err) {
        error.OutOfMemory => return failReconstructedGrid(error.OutOfMemory),
        error.ScreenRawGap, error.MissingJournalSegment => {
            try durable.mark_screen_unavailable(.raw_gap, io_mod.milliTimestamp());
            return failReconstructedGrid(error.ScreenRawGap);
        },
        error.ScreenCorrupt, error.CorruptJournalSegment => {
            try durable.mark_screen_unavailable(.corrupt, io_mod.milliTimestamp());
            return failReconstructedGrid(error.ScreenCorrupt);
        },
        else => return err,
    };
    return grid;
}

fn engine_checkpoint_unavailable_reason(
    err: anyerror,
) ?contracts.ScreenUnavailableReason {
    return switch (err) {
        error.UnsupportedEngineRevision => .unsupported_schema,
        error.CheckpointTooLarge,
        error.InvalidEngineCheckpoint,
        error.InvalidGridSize,
        => .corrupt,
        else => null,
    };
}

fn replayFromStart(
    alloc: Allocator,
    durable: *terminal_store.DurableSession,
    initial: contracts.RawCursor,
    available: contracts.RawCursor,
    output: contracts.RawCursor,
    reason: contracts.ScreenUnavailableReason,
) !terminal_engine.Grid {
    const unavailable_reason: contracts.ScreenUnavailableReason = if (!durable.record.raw_replay_exact and
        reason == .missing)
        .resize_uncheckpointed
    else
        reason;
    if (!durable.record.raw_replay_exact) {
        try durable.mark_screen_unavailable(
            unavailable_reason,
            io_mod.milliTimestamp(),
        );
        return screenUnavailable(unavailable_reason);
    }
    if (contracts.compare_raw_cursors(available, initial) != .eq) {
        const gap_reason: contracts.ScreenUnavailableReason = if (reason == .retention_evicted)
            .retention_evicted
        else
            .raw_gap;
        try durable.mark_screen_unavailable(gap_reason, io_mod.milliTimestamp());
        return screenUnavailable(gap_reason);
    }
    var grid = try terminal_engine.Grid.init(
        alloc,
        durable.record.dimensions.columns,
        durable.record.dimensions.rows,
    );
    errdefer grid.deinit();
    replayEngine(alloc, durable, &grid, initial, output) catch |err| switch (err) {
        error.ScreenRawGap, error.MissingJournalSegment => {
            try durable.mark_screen_unavailable(.raw_gap, io_mod.milliTimestamp());
            return failReconstructedGrid(error.ScreenRawGap);
        },
        error.ScreenCorrupt, error.CorruptJournalSegment => {
            try durable.mark_screen_unavailable(.corrupt, io_mod.milliTimestamp());
            return failReconstructedGrid(error.ScreenCorrupt);
        },
        else => return err,
    };
    try durable.mark_screen_unavailable(
        unavailable_reason,
        io_mod.milliTimestamp(),
    );
    return grid;
}

fn replayEngine(
    alloc: Allocator,
    durable: *terminal_store.DurableSession,
    grid: *terminal_engine.Grid,
    start: contracts.RawCursor,
    output: contracts.RawCursor,
) !void {
    var cursor = start;
    while (contracts.compare_raw_cursors(cursor, output) == .lt) {
        var page = try durable.read(alloc, cursor, max_read_bytes);
        defer page.deinit(alloc);
        if (page.gap != null) return error.ScreenRawGap;
        const range = page.range orelse return error.ScreenCorrupt;
        if (contracts.compare_raw_cursors(range.start, cursor) != .eq or
            contracts.compare_raw_cursors(range.end, cursor) != .gt or
            contracts.compare_raw_cursors(range.end, output) == .gt)
        {
            return error.ScreenCorrupt;
        }
        var result = grid.feedMode(page.output, .journal_replay) catch |err| {
            if (replay_feed_error_is_corrupt(err)) return error.ScreenCorrupt;
            return err;
        };
        defer result.deinit(alloc);
        if (result.replies.items.len != 0) return error.ScreenCorrupt;
        cursor = range.end;
    }
    if (contracts.compare_raw_cursors(cursor, output) != .eq) {
        return error.ScreenRawGap;
    }
}

fn replay_feed_error_is_corrupt(err: anyerror) bool {
    return switch (err) {
        error.CombiningPoolCapacityExceeded,
        error.ControlStringTooLarge,
        error.HyperlinkPoolCapacityExceeded,
        error.InvalidFeedMode,
        error.InvalidParserState,
        error.ReplyEffectCapacityExceeded,
        error.SynchronizedUpdateTooLarge,
        error.TooManyCsiIntermediates,
        error.TooManyCsiParameters,
        => true,
        else => false,
    };
}

fn screenUnavailable(reason: contracts.ScreenUnavailableReason) anyerror {
    return switch (reason) {
        .missing => error.ScreenMissing,
        .corrupt => error.ScreenCorrupt,
        .unsupported_schema => error.ScreenUnsupported,
        .retention_evicted => error.ScreenRetentionEvicted,
        .raw_gap => error.ScreenRawGap,
        .resize_uncheckpointed => error.ScreenResizeUncheckpointed,
    };
}

fn readAction(
    session: *Session,
    request: contracts.ReadRequest,
) !contracts.OwnedResult {
    const authorization = try session.durable.authorize(
        request.authority.?,
        .read,
    );
    const zio = io_mod.getIo();
    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    defer session.durable.release_completed_handles(&session.backend_detaching);
    var page = try session.durable.read(
        session.alloc,
        request.cursor,
        max_read_bytes,
    );
    defer page.deinit(session.alloc);
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .read = .{
            .session = session.factsLocked(authorization),
            .output = page.output,
            .raw_range = page.range,
        } } },
    ) catch return error.OutOfMemory;
}

fn writeAction(
    session: *Session,
    request: contracts.WriteRequest,
    cancelled: *const std.atomic.Value(bool),
) !contracts.OwnedResult {
    const zio = io_mod.getIo();
    session.write_mutex.lockUncancelable(zio);
    defer session.write_mutex.unlock(zio);
    if (cancelled.load(.acquire)) return error.Cancelled;
    if (request.lease == .use) {
        signalTestBarrier("FX_TERMINAL_TEST_WRITE_BARRIER_PATH");
        maybeDelayForTest("FX_TERMINAL_TEST_WRITE_DELAY_MS");
    }

    const authorization = switch (request.lease) {
        .acquire => try session.durable.acquire_write_lease(
            request.authority.?,
            io_mod.milliTimestamp(),
        ),
        .release => try session.durable.release_write_lease(
            request.authority.?,
            io_mod.milliTimestamp(),
        ),
        .use => try session.durable.authorize_write(request.authority.?),
        .revoke => blk: {
            const claim = request.authority.?;
            const auth = try session.durable.authorize(claim, .close);
            try session.durable.revoke_claim(
                claim,
                io_mod.milliTimestamp(),
            );
            session.mutex.lockUncancelable(zio);
            session.input_quiesced = true;
            session.mutex.unlock(zio);
            break :blk auth;
        },
    };

    if (request.lease == .acquire or
        request.lease == .release or
        request.lease == .revoke)
    {
        session.mutex.lockUncancelable(zio);
        defer session.mutex.unlock(zio);
        var facts = session.durable.facts();
        facts.next_actions = if (request.lease == .revoke)
            .{}
        else
            contracts.project_next_actions(
                session.lifecycle,
                authorization.controls,
                authorization.actor,
                facts.attention,
            );
        return contracts.OwnedResult.init(
            session.alloc,
            .{ .success = .{ .write = .{
                .session = facts,
                .accepted_bytes = 0,
            } } },
        ) catch return error.OutOfMemory;
    }

    var encoded = try encodeWritePayload(session.alloc, request.payload.?);
    defer encoded.deinit(session.alloc);
    session.mutex.lockUncancelable(zio);
    const running = session.lifecycle == .running;
    const master_fd = if (session.input_quiesced) null else session.master_fd;
    const tmux_ready = !session.input_quiesced and session.tmux_backend != null;
    session.mutex.unlock(zio);
    if (!running or (master_fd == null and !tmux_ready)) {
        return error.InvalidLifecycle;
    }

    if (session.tmux_backend) |*backend| {
        const paste = switch (request.payload.?) {
            .paste => true,
            .text, .keys, .controls => false,
        };
        try backend.write(encoded.items, paste);
    } else {
        try writeAllFd(master_fd.?, encoded.items, true);
    }

    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .write = .{
            .session = session.factsLocked(authorization),
            .accepted_bytes = @intCast(encoded.items.len),
        } } },
    ) catch return error.OutOfMemory;
}

fn inspectAction(
    session: *Session,
    request: contracts.SessionRequest,
) !contracts.OwnedResult {
    const authorization = try session.durable.authorize(
        request.authority.?,
        .inspect,
    );
    const zio = io_mod.getIo();
    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .inspect = .{
            .session = session.factsLocked(authorization),
            .shell = session.shell,
            .cwd = session.cwd,
            .command = session.command,
        } } },
    ) catch return error.OutOfMemory;
}

fn resizeAction(
    session: *Session,
    request: contracts.ResizeRequest,
) !contracts.OwnedResult {
    const zio = io_mod.getIo();
    try read_cancellation.lock(zio, &session.write_mutex, &session.backend_detaching);
    defer session.write_mutex.unlock(zio);
    const authorization = try session.durable.authorizeCancellable(
        request.authority.?,
        .resize,
        &session.backend_detaching,
    );
    try read_cancellation.lock(zio, &session.mutex, &session.backend_detaching);
    const fd = session.master_fd;
    const tmux_ready = session.tmux_backend != null;
    const valid = session.lifecycle == .starting or session.lifecycle == .running;
    if (!valid or (fd == null and !tmux_ready)) {
        session.mutex.unlock(zio);
        return error.InvalidLifecycle;
    }
    if (!session.screen_available) {
        session.mutex.unlock(zio);
        return error.ScreenCorrupt;
    }
    const previous_dimensions = session.dimensions;
    const now_ms = io_mod.milliTimestamp();
    session.durable.checkResizeCapacityCancellable(request.dimensions, &session.backend_detaching) catch |err| {
        session.mutex.unlock(zio);
        return err;
    };
    const previous_payload = session.engine.checkpointPayloadCancellable(session.alloc, &session.backend_detaching) catch |err| {
        session.mutex.unlock(zio);
        return err;
    };
    defer session.alloc.free(previous_payload);
    var resized_engine = terminal_engine.Grid.restoreCheckpointCancellable(
        session.alloc,
        previous_payload,
        &session.backend_detaching,
    ) catch |err| {
        session.mutex.unlock(zio);
        return err;
    };
    var resized_engine_owned = true;
    defer if (resized_engine_owned) resized_engine.deinit();
    resized_engine.resizeCancellable(
        request.dimensions.columns,
        request.dimensions.rows,
        &session.backend_detaching,
    ) catch |err| {
        session.mutex.unlock(zio);
        return err;
    };
    session.durable.resizeCancellable(request.dimensions, now_ms, &session.backend_detaching) catch |err| {
        session.mutex.unlock(zio);
        return err;
    };
    session.engine.deinit();
    session.engine = resized_engine;
    resized_engine_owned = false;
    session.dimensions = request.dimensions;
    session.mutex.unlock(zio);
    try read_cancellation.check(&session.backend_detaching);
    if (session.tmux_backend) |*backend| {
        backend.resize(request.dimensions, &session.backend_detaching) catch |err| {
            try read_cancellation.check(&session.backend_detaching);
            rollbackTmuxResize(
                session,
                previous_dimensions,
                previous_payload,
            );
            return err;
        };
    } else {
        resizeFd(fd.?, request.dimensions) catch |err| {
            try read_cancellation.check(&session.backend_detaching);
            rollbackDurableResize(
                session,
                fd.?,
                previous_dimensions,
                previous_payload,
            );
            return err;
        };
        if (!session.signalNative(std.c.SIG.WINCH)) {
            try read_cancellation.check(&session.backend_detaching);
            rollbackDurableResize(
                session,
                fd.?,
                previous_dimensions,
                previous_payload,
            );
            return error.ProcessIdentityUnavailable;
        }
    }
    if (session.tmux_backend != null and tmuxResizeCheckpointFailure()) {
        try read_cancellation.check(&session.backend_detaching);
        rollbackTmuxResize(
            session,
            previous_dimensions,
            previous_payload,
        );
        return error.InjectedFailure;
    }
    try read_cancellation.lock(zio, &session.mutex, &session.backend_detaching);
    const output = session.durable.outputState(&session.backend_detaching) catch |err| {
        session.mutex.unlock(zio);
        return err;
    };
    session.checkpointLockedCancellable(output.output_cursor, now_ms, &session.backend_detaching) catch |err| {
        session.mutex.unlock(zio);
        if (err == error.Cancelled) return err;
        if (session.tmux_backend != null) {
            rollbackTmuxResize(
                session,
                previous_dimensions,
                previous_payload,
            );
        } else {
            rollbackDurableResize(
                session,
                fd.?,
                previous_dimensions,
                previous_payload,
            );
        }
        return err;
    };
    session.mutex.unlock(zio);
    try read_cancellation.lock(zio, &session.mutex, &session.backend_detaching);
    defer session.mutex.unlock(zio);
    const facts = try session.durable.factsCancellable(&session.backend_detaching);
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .resize = .{
            .session = projectedFacts(facts, authorization),
            .dimensions = request.dimensions,
        } } },
    ) catch return error.OutOfMemory;
}

fn tmuxResizeCheckpointFailure() bool {
    const value = io_mod.getenv(
        "FX_TERMINAL_TEST_TMUX_RESIZE_CHECKPOINT_FAILURE",
    ) orelse return false;
    return std.mem.eql(u8, value, "allocation") or
        std.mem.eql(u8, value, "storage") or
        std.mem.eql(u8, value, "checkpoint");
}

fn tmuxRecoveryFailure(session_id: []const u8, point: []const u8) bool {
    const value = io_mod.getenv(
        "FX_TERMINAL_TEST_TMUX_RECOVERY_FAILURE",
    ) orelse return false;
    if (!std.mem.eql(u8, value, point)) return false;
    const selected_session = io_mod.getenv(
        "FX_TERMINAL_TEST_TMUX_RECOVERY_SESSION_ID",
    ) orelse return true;
    return std.mem.eql(u8, selected_session, session_id);
}

fn rollbackDurableResize(
    session: *Session,
    fd: std.posix.fd_t,
    dimensions: contracts.Dimensions,
    checkpoint_payload: []const u8,
) void {
    read_cancellation.check(&session.backend_detaching) catch return;
    resizeFd(fd, dimensions) catch |err| {
        const zio = io_mod.getIo();
        read_cancellation.lock(zio, &session.mutex, &session.backend_detaching) catch return;
        session.screen_available = false;
        session.mutex.unlock(zio);
        debug_trace.logf(
            "terminal_host",
            "terminal resize rollback failed id={s} err={s}",
            .{ session.id, @errorName(err) },
        );
        return;
    };
    if (!session.signalNative(std.c.SIG.WINCH)) {
        const zio = io_mod.getIo();
        read_cancellation.lock(zio, &session.mutex, &session.backend_detaching) catch return;
        session.screen_available = false;
        session.mutex.unlock(zio);
        debug_trace.logf(
            "terminal_host",
            "terminal resize rollback signal failed id={s}",
            .{session.id},
        );
        return;
    }
    restoreDurableResize(session, dimensions, checkpoint_payload);
}

fn rollbackTmuxResize(
    session: *Session,
    dimensions: contracts.Dimensions,
    checkpoint_payload: []const u8,
) void {
    read_cancellation.check(&session.backend_detaching) catch return;
    const backend = if (session.tmux_backend) |*value| value else return;
    backend.resize(dimensions, &session.backend_detaching) catch |err| {
        const zio = io_mod.getIo();
        read_cancellation.lock(zio, &session.mutex, &session.backend_detaching) catch return;
        session.screen_available = false;
        session.mutex.unlock(zio);
        debug_trace.logf(
            "terminal_host",
            "tmux resize rollback failed id={s} err={s}",
            .{ session.id, @errorName(err) },
        );
        return;
    };
    restoreDurableResize(session, dimensions, checkpoint_payload);
}

fn restoreDurableResize(
    session: *Session,
    dimensions: contracts.Dimensions,
    checkpoint_payload: []const u8,
) void {
    var restored = terminal_engine.Grid.restoreCheckpointCancellable(
        session.alloc,
        checkpoint_payload,
        &session.backend_detaching,
    ) catch |err| {
        const zio = io_mod.getIo();
        read_cancellation.lock(zio, &session.mutex, &session.backend_detaching) catch {
            debug_trace.logf("terminal_host", "resize rollback abandoned id={s} reason=owner_shutdown", .{session.id});
            return;
        };
        session.screen_available = false;
        session.mutex.unlock(zio);
        debug_trace.logf(
            "terminal_host",
            "screen resize rollback failed id={s} err={s}",
            .{ session.id, @errorName(err) },
        );
        return;
    };
    var restored_owned = true;
    defer if (restored_owned) restored.deinit();
    const zio = io_mod.getIo();
    read_cancellation.lock(zio, &session.mutex, &session.backend_detaching) catch return;
    defer session.mutex.unlock(zio);
    session.durable.resizeCancellable(dimensions, io_mod.milliTimestamp(), &session.backend_detaching) catch |err| {
        session.screen_available = false;
        debug_trace.logf(
            "terminal_host",
            "durable resize rollback failed id={s} err={s}",
            .{ session.id, @errorName(err) },
        );
        return;
    };
    session.engine.deinit();
    session.engine = restored;
    restored_owned = false;
    session.dimensions = dimensions;
    session.screen_available = true;
    const output = session.durable.outputState(&session.backend_detaching) catch return;
    session.checkpointLockedCancellable(
        output.output_cursor,
        io_mod.milliTimestamp(),
        &session.backend_detaching,
    ) catch |err| debug_trace.logf(
        "terminal_host",
        "screen resize rollback checkpoint failed id={s} err={s}",
        .{ session.id, @errorName(err) },
    );
}

fn signalAction(
    session: *Session,
    request: contracts.SignalRequest,
) !contracts.OwnedResult {
    const zio = io_mod.getIo();
    session.write_mutex.lockUncancelable(zio);
    defer session.write_mutex.unlock(zio);
    const authorization = try session.durable.authorize(
        request.authority.?,
        .signal,
    );
    if (!(try session.signalTerminalProcesses(request.signal) orelse false)) {
        return error.ProcessIdentityUnavailable;
    }
    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .signal = .{
            .session = session.factsLocked(authorization),
            .signal = request.signal,
        } } },
    ) catch return error.OutOfMemory;
}

fn terminalSignalCompleted(
    descendants: process_tree.DeliverySummary,
    shell_group: ProcessGroupDelivery,
) bool {
    return !descendants.incomplete and shell_group != .failed;
}

fn processGroupMissing(pid: std.posix.pid_t) bool {
    while (true) switch (std.c.errno(std.c.kill(
        -pid,
        @enumFromInt(0),
    ))) {
        .SUCCESS, .PERM => return false,
        .INTR => continue,
        .SRCH => return true,
        else => return false,
    };
}

test "running tmux recovery does not pause the published process group" {
    try std.testing.expect(!shouldPauseRecoveredTmuxProcess(
        .running,
        false,
        true,
    ));
    try std.testing.expect(shouldPauseRecoveredTmuxProcess(
        .starting,
        false,
        true,
    ));
}

test "terminal signaling accepts a process group that exited during descendant delivery" {
    try std.testing.expect(terminalSignalCompleted(
        .{ .delivered = 1 },
        .missing,
    ));
    try std.testing.expect(!terminalSignalCompleted(
        .{ .delivered = 1, .incomplete = true },
        .missing,
    ));
}

fn failSignalStageForTest(stage: []const u8) bool {
    const requested = io_mod.getenv("FX_TERMINAL_TEST_FAIL_SIGNAL_STAGE") orelse
        return false;
    return std.mem.eql(u8, requested, stage);
}

fn forceCloseSignalIncomplete(tree_complete: ?bool) bool {
    return tree_complete == null or !tree_complete.?;
}

fn closeAction(
    session: *Session,
    request: contracts.CloseRequest,
) !contracts.OwnedResult {
    const zio = io_mod.getIo();
    session.write_mutex.lockUncancelable(zio);
    const close_started_at = io_mod.milliTimestamp();
    requireCloseCandidate(
        session.id,
        session.durable.begin_close(request.authority.?, close_started_at),
    ) catch |err| {
        session.write_mutex.unlock(zio);
        return err;
    };
    if (session.durable.record.backend == .tmux and
        io_mod.getenv("FX_TERMINAL_TEST_INTERRUPT_CLOSE_AFTER_COMMIT") != null)
    {
        session.write_mutex.unlock(zio);
        return error.InjectedTmuxCloseInterruption;
    }
    session.mutex.lockUncancelable(zio);
    session.input_quiesced = true;
    session.close_committed = true;
    session.mutex.unlock(zio);
    session.write_mutex.unlock(zio);

    session.mutex.lockUncancelable(zio);
    var still_live = session.lifecycle == .starting or
        session.lifecycle == .running;
    session.mutex.unlock(zio);
    var force_signal_attempted = false;
    var force_tree_complete: ?bool = null;
    if (still_live) {
        const delivered = if (request.policy == .force) blk: {
            const tree_complete = session.signalTerminalProcesses(.kill) catch |err| {
                force_signal_attempted = true;
                debug_trace.logf(
                    "terminal_host",
                    "force close tree signal failed id={s} err={s}; falling back to shell group",
                    .{ session.id, @errorName(err) },
                );
                break :blk session.signalProcess(.kill);
            };
            if (tree_complete) |complete| {
                force_signal_attempted = true;
                force_tree_complete = complete;
                break :blk complete;
            }
            break :blk false;
        } else session.signalProcess(.terminate);
        if (!delivered) session.markLost();
    }
    if (request.policy == .graceful and still_live) {
        const started = io_mod.milliTimestamp();
        while (io_mod.milliTimestamp() - started < graceful_close_ms) {
            session.mutex.lockUncancelable(zio);
            const done = session.lifecycle != .starting and
                session.lifecycle != .running;
            session.mutex.unlock(zio);
            if (done) break;
            io_mod.sleep(wait_poll_ns);
        }
        session.mutex.lockUncancelable(zio);
        still_live = session.lifecycle == .starting or
            session.lifecycle == .running;
        session.mutex.unlock(zio);
        if (still_live and !session.signalProcess(.kill)) session.markLost();
    }

    if (still_live) {
        const started = io_mod.milliTimestamp();
        while (io_mod.milliTimestamp() - started < graceful_close_ms) {
            session.mutex.lockUncancelable(zio);
            still_live = session.lifecycle == .starting or
                session.lifecycle == .running;
            session.mutex.unlock(zio);
            if (!still_live) break;
            io_mod.sleep(wait_poll_ns);
        }
        if (still_live) session.markLost();
    }

    session.mutex.lockUncancelable(zio);
    session.lifecycle = .closed;
    session.mutex.unlock(zio);
    session.finalizeBackend();
    if (session.tmux_backend) |*backend| {
        try backend.cleanupChecked(session.durable.profile.process_provider, null);
    }
    try session.durable.finish_close(io_mod.milliTimestamp());
    if (force_signal_attempted and forceCloseSignalIncomplete(force_tree_complete)) {
        return contracts.OwnedResult.init(
            session.alloc,
            .{ .failure = .{
                .action = .close,
                .code = .session_lost,
                .session_id = session.id,
            } },
        ) catch return error.OutOfMemory;
    }
    var facts = session.durable.facts();
    facts.next_actions = .{};
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .close = .{
            .session = facts,
            .policy = request.policy,
        } } },
    ) catch return error.OutOfMemory;
}

const Pty = struct {
    master: std.posix.fd_t,
    slave: std.posix.fd_t,
};

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
extern "c" fn tcsetpgrp(fd: c_int, pgrp: std.c.pid_t) c_int;

fn openPty() !Pty {
    if (!isSupported()) return error.TerminalHostUnsupported;
    const master_flags = std.posix.O{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
        .NONBLOCK = true,
    };
    const master = posix_openpt(@bitCast(master_flags));
    if (master < 0) return error.PtyUnavailable;
    errdefer closeFd(master);
    if (grantpt(master) != 0 or unlockpt(master) != 0) {
        return error.PtyUnavailable;
    }
    const slave_name = ptsname(master) orelse return error.PtyUnavailable;
    const slave = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        slave_name,
        .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        },
        0,
    );
    return .{ .master = master, .slave = slave };
}

test "PTY output drains use a nonblocking master" {
    if (comptime !isSupported()) return;
    const pty = try openPty();
    defer closeFd(pty.master);
    defer closeFd(pty.slave);

    const result = std.posix.system.fcntl(
        pty.master,
        std.posix.F.GETFL,
        @as(usize, 0),
    );
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(result));
    const flags: usize = @intCast(result);
    const nonblocking = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    try std.testing.expect(flags & nonblocking != 0);
}

test "terminal protocol replies return when the real PTY input buffer is full" {
    if (comptime !isSupported()) return;
    const pty = try openPty();
    defer closeFd(pty.master);
    defer closeFd(pty.slave);
    var termios = try std.posix.tcgetattr(pty.slave);
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;
    try std.posix.tcsetattr(pty.slave, .NOW, termios);
    const fill = "x" ** 8192;
    var full = false;
    var written: usize = 0;
    while (!full and written < 16 * 1024 * 1024) {
        written += (std.Io.File{ .handle = pty.master, .flags = .{ .nonblocking = true } }).writeStreaming(io_mod.getIo(), "", &.{fill}, 1) catch |err| switch (err) {
            error.WouldBlock => blk: {
                full = true;
                break :blk 0;
            },
            else => return err,
        };
    }
    try std.testing.expect(full);
    const started = io_mod.nanoTimestamp();
    try std.testing.expectError(error.WouldBlock, writeAllFd(pty.master, "\x1b[1;1R", true));
    try std.testing.expect(io_mod.nanoTimestamp() - started < 500 * std.time.ns_per_ms);
}

fn resizeFd(fd: std.posix.fd_t, dimensions: contracts.Dimensions) !void {
    var size = std.posix.winsize{
        .row = dimensions.rows,
        .col = dimensions.columns,
        .xpixel = 0,
        .ypixel = 0,
    };
    if (std.c.ioctl(
        fd,
        ioctl_set_window_size,
        &size,
    ) < 0) return error.ResizeFailed;
}

fn setEcho(fd: std.posix.fd_t, enabled: bool) !void {
    var termios = try std.posix.tcgetattr(fd);
    termios.lflag.ECHO = enabled;
    try std.posix.tcsetattr(fd, .NOW, termios);
}

fn closeFd(fd: std.posix.fd_t) void {
    (std.Io.File{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    }).close(io_mod.getIo());
}

fn readExactFd(fd: std.posix.fd_t, destination: []u8) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const count = try std.posix.read(fd, destination[offset..]);
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

fn receiveSocketExact(
    socket: std.Io.net.Socket,
    destination: []u8,
    timeout_ms: i64,
) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const incoming = try socket.receiveTimeout(
            io_mod.getIo(),
            destination[offset..],
            .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(timeout_ms),
            } },
        );
        if (incoming.data.len == 0) return error.EndOfStream;
        offset += incoming.data.len;
    }
}

fn writeAllFd(
    fd: std.posix.fd_t,
    bytes: []const u8,
    nonblocking: bool,
) !void {
    const file = std.Io.File{
        .handle = fd,
        .flags = .{ .nonblocking = nonblocking },
    };
    try file.writeStreamingAll(io_mod.getIo(), bytes);
}

const ControlFrame = struct {
    kind: ControlKind,
    value: u32,
};

fn tmuxLifecycleTerminal(kind: tmux_session.LifecycleKind) bool {
    return switch (kind) {
        .command_exited,
        .command_signal,
        .startup_failed,
        .invalid_term,
        => true,
        .prepared, .shell_ready, .command_started => false,
    };
}

fn tmuxTerminalFrame(
    frames: []const tmux_session.LifecycleFrame,
) ?tmux_session.LifecycleFrame {
    for (frames) |frame| if (tmuxLifecycleTerminal(frame.kind)) return frame;
    return null;
}

fn tmuxShellPid(
    frames: []const tmux_session.LifecycleFrame,
) ?u32 {
    for (frames) |frame| switch (frame.kind) {
        .shell_ready => return frame.value,
        .prepared,
        .command_started,
        .command_exited,
        .command_signal,
        .startup_failed,
        .invalid_term,
        => {},
    };
    return null;
}

fn tmuxStartupFrameCount(frames: []const tmux_session.LifecycleFrame) usize {
    for (frames, 0..) |frame, index| {
        if (tmuxLifecycleTerminal(frame.kind)) return index;
    }
    return frames.len;
}

fn writeControlFd(fd: std.posix.fd_t, kind: ControlKind, value: u32) !void {
    var bytes: [control_frame_len]u8 = undefined;
    bytes[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, bytes[1..5], value, .little);
    try writeAllFd(fd, &bytes, false);
}

fn readControlFile(file: std.Io.File, cancel_flag: read_cancellation.CancelFlag) !ControlFrame {
    var bytes: [control_frame_len]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes.len) {
        offset += try readAvailableFd(file.handle, bytes[offset..], control_poll_ms, cancel_flag);
    }
    return .{
        .kind = switch (bytes[0]) {
            1 => .prepared,
            2 => .shell_ready,
            3 => .command_started,
            4 => .command_exited,
            5 => .command_signal,
            6 => .startup_failed,
            7 => .invalid_term,
            else => return error.InvalidControlFrame,
        },
        .value = std.mem.readInt(u32, bytes[1..5], .little),
    };
}

fn outputMain(session: *Session) void {
    defer {
        session.output_active.store(false, .release);
        if (session.command_boundary_requested.swap(false, .acq_rel)) {
            session.command_boundary_done.set(io_mod.getIo());
        }
        session.output_done.set(io_mod.getIo());
    }
    var buffer: [256 * 1024]u8 = undefined;
    const fd = session.master_fd orelse if (session.tmux_capture) |stream|
        stream.socket.handle
    else
        return;
    while (true) {
        if (session.command_boundary_requested.load(.acquire)) {
            while (readOutputChunk(session, fd, &buffer, 0) catch return) {}
            session.commitStartupBoundary();
            session.command_boundary_requested.store(false, .release);
            session.command_boundary_done.set(io_mod.getIo());
            continue;
        }
        _ = readOutputChunk(
            session,
            fd,
            &buffer,
            control_poll_ms,
        ) catch break;
    }
}

fn tmuxControlMain(session: *Session) void {
    defer {
        session.backend_done.set(io_mod.getIo());
        session.markNotLive();
    }
    var terminal_seen = false;
    while (!terminal_seen and !session.backend_detaching.load(.acquire)) {
        const backend = if (session.tmux_backend) |*value| value else {
            session.markLost();
            break;
        };
        const frames = backend.lifecycle() catch |err| {
            debug_trace.logf(
                "terminal_host",
                "tmux lifecycle read deferred id={s} err={s}",
                .{ session.id, @errorName(err) },
            );
            io_mod.sleep(wait_poll_ns);
            continue;
        };
        defer session.alloc.free(frames);
        if (session.tmux_lifecycle_index > frames.len) {
            session.markLost();
            break;
        }
        while (session.tmux_lifecycle_index < frames.len) {
            const frame = frames[session.tmux_lifecycle_index];
            session.tmux_lifecycle_index += 1;
            const control = ControlFrame{
                .kind = switch (frame.kind) {
                    .prepared => .prepared,
                    .shell_ready => .shell_ready,
                    .command_started => .command_started,
                    .command_exited => .command_exited,
                    .command_signal => .command_signal,
                    .startup_failed => .startup_failed,
                    .invalid_term => .invalid_term,
                },
                .value = frame.value,
            };
            terminal_seen = switch (control.kind) {
                .command_exited,
                .command_signal,
                .startup_failed,
                .invalid_term,
                => true,
                .prepared, .shell_ready, .command_started => false,
            };
            if (terminal_seen) {
                backend.stopCapture(&session.backend_detaching);
                if (session.tmux_capture) |stream| {
                    stream.close(io_mod.getIo());
                    session.tmux_capture = null;
                }
                session.output_done.waitUncancelable(io_mod.getIo());
            }
            if (control.kind == .shell_ready) {
                maybeDelayForTest(
                    "FX_TERMINAL_TEST_TMUX_SHELL_READY_HOST_DELAY_MS",
                );
            }
            session.handleControl(control);
            if (terminal_seen) break;
        }
        if (!terminal_seen) io_mod.sleep(wait_poll_ns);
    }

    if (session.tmux_backend) |*backend| backend.stopCapture(&session.backend_detaching);
    session.output_done.waitUncancelable(io_mod.getIo());
    if (session.output_thread) |thread| {
        thread.join();
        session.output_thread = null;
    }
    maybeDelayForTest("FX_TERMINAL_TEST_BACKEND_CLEANUP_DELAY_MS");
    const zio = io_mod.getIo();
    session.write_mutex.lockUncancelable(zio);
    if (session.tmux_capture) |stream| stream.close(zio);
    session.tmux_capture = null;
    session.mutex.lockUncancelable(zio);
    const close_committed = session.close_committed;
    session.mutex.unlock(zio);
    if (!close_committed and !session.backend_detaching.load(.acquire)) {
        if (session.tmux_backend) |*backend| backend.killSession();
    }
    session.write_mutex.unlock(zio);
}

fn controlMain(session: *Session) void {
    defer {
        session.backend_done.set(io_mod.getIo());
        session.markNotLive();
    }
    const control = session.control_file orelse return;
    while (true) {
        const frame = readControlFile(control, null) catch {
            const zio = io_mod.getIo();
            session.mutex.lockUncancelable(zio);
            const reported = session.term != null or
                session.start_failure != null;
            session.mutex.unlock(zio);
            if (!reported) session.markLost();
            break;
        };
        switch (frame.kind) {
            .command_exited,
            .command_signal,
            .startup_failed,
            .invalid_term,
            => {
                session.output_done.waitUncancelable(io_mod.getIo());
            },
            .prepared, .shell_ready, .command_started => {},
        }
        session.handleControl(frame);
    }
    if (session.launcher) |*child| {
        const term = child.wait(io_mod.getIo()) catch blk: {
            session.markLost();
            break :blk null;
        };
        const zio = io_mod.getIo();
        session.mutex.lockUncancelable(zio);
        const reported = session.term != null or session.lifecycle == .lost;
        session.mutex.unlock(zio);
        if (!reported and term != null) {
            if (session.backend_detaching.load(.acquire)) {
                session.mutex.lockUncancelable(zio);
                session.lifecycle = .lost;
                session.mutex.unlock(zio);
                debug_trace.logf("terminal_host", "terminal loss publication skipped id={s} reason=owner_shutdown", .{session.id});
            } else switch (term.?) {
                .exited => |code| if (code != 0) session.markLost(),
                .signal, .stopped, .unknown => session.markLost(),
            }
        }
    }

    session.output_done.waitUncancelable(io_mod.getIo());
    if (session.output_thread) |thread| {
        thread.join();
        session.output_thread = null;
    }

    maybeDelayForTest("FX_TERMINAL_TEST_BACKEND_CLEANUP_DELAY_MS");

    const zio = io_mod.getIo();
    session.write_mutex.lockUncancelable(zio);
    session.mutex.lockUncancelable(zio);
    const master_fd = session.master_fd;
    const control_file = session.control_file;
    const liveness_file = session.liveness_file;
    session.master_fd = null;
    session.control_file = null;
    session.liveness_file = null;
    session.launcher = null;
    session.mutex.unlock(zio);
    if (master_fd) |fd| closeFd(fd);
    if (control_file) |file| file.close(zio);
    if (liveness_file) |file| file.close(zio);
    session.write_mutex.unlock(zio);
}

fn readOutputChunk(
    session: *Session,
    fd: std.posix.fd_t,
    buffer: []u8,
    timeout_ms: i32,
) !bool {
    const total = readAvailableFd(fd, buffer, timeout_ms, &session.backend_detaching) catch |err| {
        if (err == error.Cancelled) debug_trace.logf(
            "terminal_host",
            "output collection abandoned id={s} reason=backend_shutdown",
            .{session.id},
        );
        return err;
    };
    if (total == 0) return false;
    session.appendOutput(buffer[0..total]);
    return true;
}

fn readAvailableFd(
    fd: std.posix.fd_t,
    buffer: []u8,
    timeout_ms: i32,
    cancelled: ?*const std.atomic.Value(bool),
) !usize {
    var total: usize = 0;
    var poll_timeout = timeout_ms;
    while (total < buffer.len) {
        if (cancelled) |flag| if (flag.load(.acquire)) return error.Cancelled;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = try std.posix.poll(&poll_fds, poll_timeout);
        const revents = poll_fds[0].revents;
        if (revents == 0) break;
        if (revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) == 0) {
            if (total == 0) return error.EndOfStream;
            break;
        }
        const count = std.posix.read(fd, buffer[total..]) catch |err| {
            if (err == error.WouldBlock) {
                if (total == 0 and
                    revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0)
                {
                    return error.EndOfStream;
                }
                break;
            }
            if (total != 0) break;
            return err;
        };
        if (count == 0) {
            if (total == 0) return error.EndOfStream;
            break;
        }
        total += count;
        poll_timeout = 1;
    }
    return total;
}

test "terminal output drain reads final bytes after peer close" {
    if (comptime !isSupported()) return;
    var handles: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(
        std.c.AF.UNIX,
        std.c.SOCK.STREAM,
        0,
        &handles,
    ) != 0) return error.SocketPairFailed;
    defer closeFd(handles[0]);
    const sentinel = "FINAL_OUTPUT_SENTINEL";
    try (std.Io.File{
        .handle = handles[1],
        .flags = .{ .nonblocking = false },
    }).writeStreamingAll(io_mod.getIo(), sentinel);
    closeFd(handles[1]);

    var buffer: [128]u8 = undefined;
    const count = try readAvailableFd(handles[0], &buffer, 1000, null);
    try std.testing.expectEqualStrings(sentinel, buffer[0..count]);
    try std.testing.expectError(
        error.EndOfStream,
        readAvailableFd(handles[0], &buffer, 0, null),
    );
}

fn testCaptureOutput(mode: enum { idle, active, complete }) !void {
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", try alloc.dupe(u8, "terminal-capture-shutdown"), .{
        .cwd = fixture.home,
        .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash" } },
    }, testPersistence(fixture.home), null);
    defer session.deinitUnlaunched();
    var handles: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &handles) != 0) return error.SocketPairFailed;
    session.tmux_capture = .{ .socket = .{ .handle = handles[0], .address = .{ .ip4 = .unspecified(0) } } };
    defer session.tmux_capture.?.close(zio);
    var writer_owned = true;
    defer if (writer_owned) closeFd(handles[1]);
    var producer = try std.process.spawn(zio, .{
        .argv = &.{ "/bin/sh", "-c", switch (mode) {
            .idle => "printf 'CAPTURE_STARTED\\n'; exec sleep 30",
            .active => "printf 'CAPTURE_STARTED\\n'; while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done",
            .complete => "printf 'CAPTURE_STARTED\\n'; i=0; while [ \"$i\" -lt 8192 ]; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done; printf 'CAPTURE_FINISHED\\n'",
        } },
        .stdin = .ignore,
        .stdout = .{ .file = .{ .handle = handles[1], .flags = .{ .nonblocking = false } } },
        .stderr = .ignore,
    });
    defer if (producer.id != null) producer.kill(zio);
    const producer_pid = producer.id.?;
    closeFd(handles[1]);
    writer_owned = false;
    session.output_active.store(true, .release);
    const thread = try std.Thread.spawn(.{}, outputMain, .{&session});
    var joined = false;
    defer {
        if (producer.id != null) producer.kill(zio);
        if (!joined) thread.join();
    }
    var observed = false;
    const deadline = io_mod.milliTimestamp() + 5000;
    while (!observed and io_mod.milliTimestamp() < deadline) {
        session.mutex.lockUncancelable(zio);
        observed = session.durable.containsCancellable("CAPTURE_STARTED", session.durable.available_cursor(), null) catch false;
        session.mutex.unlock(zio);
        if (!observed) io_mod.sleep(wait_poll_ns);
    }
    try std.testing.expect(observed);
    if (mode == .complete) {
        try session.output_done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try producer.wait(zio));
        var page = try session.durable.read(alloc, session.durable.available_cursor(), 1024 * 1024);
        defer page.deinit(alloc);
        try std.testing.expectEqual(@as(usize, "CAPTURE_STARTED\n".len + 32 * 8192 + "CAPTURE_FINISHED\n".len), page.output.len);
        try std.testing.expect(std.mem.startsWith(u8, page.output, "CAPTURE_STARTED\n"));
        try std.testing.expect(std.mem.endsWith(u8, page.output, "CAPTURE_FINISHED\n"));
        return;
    }
    const started = io_mod.nanoTimestamp();
    session.shutdown();
    const stopped_while_retained = if (session.output_done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(500) } })) |_| true else |_| false;
    const external_survived = std.c.kill(producer_pid, @enumFromInt(0)) == 0;
    if (!stopped_while_retained) producer.kill(zio);
    thread.join();
    joined = true;
    const elapsed = io_mod.nanoTimestamp() - started;
    if (producer.id != null) producer.kill(zio);
    try std.testing.expect(stopped_while_retained);
    try std.testing.expect(elapsed < 500 * std.time.ns_per_ms);
    try std.testing.expect(external_survived);
}

test "capture shutdown stops after reading from an externally retained idle socket" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    try testCaptureOutput(.idle);
}

test "launch control cancellation interrupts a partially received frame" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Reader = struct {
        file: std.Io.File,
        cancelled: std.atomic.Value(bool) = .init(false),
        done: std.Io.Event = .unset,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            _ = readControlFile(self.file, &self.cancelled) catch |err| {
                self.failure = err;
                self.done.set(io_mod.getIo());
                return;
            };
            self.done.set(io_mod.getIo());
        }
    };
    var handles: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &handles) != 0) return error.SocketPairFailed;
    defer closeFd(handles[0]);
    var writer_open = true;
    defer if (writer_open) closeFd(handles[1]);
    try writeAllFd(handles[1], &.{@intFromEnum(ControlKind.prepared)}, false);
    var reader = Reader{ .file = .{ .handle = handles[0], .flags = .{ .nonblocking = false } } };
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    var joined = false;
    defer if (!joined) {
        closeFd(handles[1]);
        writer_open = false;
        thread.join();
    };
    const read_deadline = io_mod.milliTimestamp() + 5000;
    while (true) {
        var unread: c_int = 0;
        const read_pending: c_int = if (builtin.os.tag == .macos) 0x4004667f else std.c.T.FIONREAD;
        if (std.c.ioctl(handles[0], read_pending, &unread) != 0) return error.SocketInspectionFailed;
        if (unread == 0) break;
        if (io_mod.milliTimestamp() >= read_deadline) return error.TestReadDidNotBegin;
        io_mod.sleep(wait_poll_ns);
    }
    reader.cancelled.store(true, .release);
    const stopped = if (reader.done.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(200) } })) |_| true else |_| false;
    closeFd(handles[1]);
    writer_open = false;
    thread.join();
    joined = true;
    try std.testing.expect(stopped);
    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), reader.failure);
}

test "capture shutdown stops after reading from an active external socket producer" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    try testCaptureOutput(.active);
}

test "capture natural completion drains every byte before publishing output done" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    try testCaptureOutput(.complete);
}

fn maybeDelayForTest(name: []const u8) void {
    const value = io_mod.getenv(name) orelse return;
    const delay_ms = std.fmt.parseInt(u64, value, 10) catch return;
    const bounded_ms = @min(delay_ms, 5_000);
    const delay_ns = std.math.mul(
        u64,
        bounded_ms,
        std.time.ns_per_ms,
    ) catch return;
    io_mod.sleep(delay_ns);
}

fn signalTestBarrier(name: []const u8) void {
    const path = io_mod.getenv(name) orelse return;
    var file = std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        path,
        .{ .truncate = true },
    ) catch return;
    file.close(io_mod.getIo());
}

fn outcomeFromTerm(term: std.process.Child.Term) ?contracts.ReturnOutcome {
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |signal| .{ .signal = @intFromEnum(signal) },
        .stopped, .unknown => null,
    };
}

fn returnOutcomeIsTerminal(outcome: contracts.ReturnOutcome) bool {
    return switch (outcome) {
        .exited, .signal => true,
        .started,
        .condition_met,
        .safety_ceiling,
        .cancelled,
        => false,
    };
}

fn launchFailureCode(err: anyerror) contracts.StructuredErrorCode {
    return switch (err) {
        error.Cancelled => .cancelled,
        error.ProcessIdentityUnavailable => .process_identity_unavailable,
        error.MissingLoginShell => .shell_unavailable,
        error.PtyUnavailable,
        error.ResizeFailed,
        error.TerminalHostUnsupported,
        error.LauncherNotPrepared,
        error.TmuxUnavailable,
        => .pty_unavailable,
        error.TmuxIncompatible => .protocol_incompatible,
        error.RelativeShellPath,
        error.UnsupportedShell,
        error.LauncherConfigTooLarge,
        => .invalid_request,
        else => .startup_failed,
    };
}

fn signalValue(signal: contracts.Signal) std.c.SIG {
    return switch (signal) {
        .hangup => std.c.SIG.HUP,
        .interrupt => std.c.SIG.INT,
        .quit => std.c.SIG.QUIT,
        .terminate => std.c.SIG.TERM,
        .kill => std.c.SIG.KILL,
    };
}

fn signalFromInt(value: u32) ?std.posix.SIG {
    if (value == 0 or value > 255) return null;
    return @enumFromInt(value);
}

fn projectedFacts(
    facts: contracts.SessionFacts,
    authorization: terminal_store.Authorization,
) contracts.SessionFacts {
    var projected = facts;
    projected.next_actions = contracts.project_next_actions(
        facts.lifecycle,
        authorization.controls,
        authorization.actor,
        facts.attention,
    );
    return projected;
}

fn encodeWritePayload(
    alloc: Allocator,
    payload: contracts.WritePayload,
) Allocator.Error!std.ArrayList(u8) {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    switch (payload) {
        .text, .paste => |bytes| try result.appendSlice(alloc, bytes),
        .keys => |keys| for (keys) |key| {
            try result.appendSlice(alloc, keySequence(key));
        },
        .controls => |controls| for (controls) |control| {
            const byte = if (control.character == '?')
                @as(u8, 0x7f)
            else
                std.ascii.toUpper(control.character) & 0x1f;
            try result.append(alloc, byte);
        },
    }
    return result;
}

fn keySequence(key: contracts.NamedKey) []const u8 {
    return switch (key) {
        .enter => "\r",
        .tab => "\t",
        .escape => "\x1b",
        .backspace => "\x7f",
        .delete => "\x1b[3~",
        .insert => "\x1b[2~",
        .arrow_up => "\x1b[A",
        .arrow_down => "\x1b[B",
        .arrow_left => "\x1b[D",
        .arrow_right => "\x1b[C",
        .home => "\x1b[H",
        .end => "\x1b[F",
        .page_up => "\x1b[5~",
        .page_down => "\x1b[6~",
    };
}

test "write payload encoding preserves text paste keys and controls" {
    const alloc = std.testing.allocator;
    var text = try encodeWritePayload(alloc, .{ .text = "a\x00b" });
    defer text.deinit(alloc);
    try std.testing.expectEqualSlices(u8, "a\x00b", text.items);

    var paste = try encodeWritePayload(alloc, .{ .paste = "\xff\n" });
    defer paste.deinit(alloc);
    try std.testing.expectEqualSlices(u8, "\xff\n", paste.items);

    var keys = try encodeWritePayload(
        alloc,
        .{ .keys = &.{
            .enter,
            .tab,
            .escape,
            .backspace,
            .delete,
            .insert,
            .arrow_up,
            .arrow_down,
            .arrow_left,
            .arrow_right,
            .home,
            .end,
            .page_up,
            .page_down,
        } },
    );
    defer keys.deinit(alloc);
    try std.testing.expectEqualSlices(
        u8,
        "\r\t\x1b\x7f\x1b[3~\x1b[2~\x1b[A\x1b[B\x1b[D\x1b[C\x1b[H\x1b[F\x1b[5~\x1b[6~",
        keys.items,
    );

    var controls = try encodeWritePayload(
        alloc,
        .{ .controls = &.{
            .{ .character = 'c' },
            .{ .character = '?' },
        } },
    );
    defer controls.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0x7f }, controls.items);
}

test "terminal outcomes preserve exact exit and signal status" {
    try std.testing.expectEqual(
        contracts.ReturnOutcome{ .exited = 23 },
        outcomeFromTerm(.{ .exited = 23 }).?,
    );
    try std.testing.expectEqual(
        contracts.ReturnOutcome{ .signal = @intFromEnum(std.posix.SIG.TERM) },
        outcomeFromTerm(.{ .signal = .TERM }).?,
    );
    try std.testing.expect(outcomeFromTerm(.{ .unknown = 1 }) == null);
    try std.testing.expect(outcomeFromTerm(.{ .stopped = .STOP }) == null);
    try std.testing.expectEqual(
        std.posix.SIG.SEGV,
        signalFromInt(@intFromEnum(std.posix.SIG.SEGV)).?,
    );
    try std.testing.expect(signalFromInt(0) == null);
    try std.testing.expect(signalFromInt(256) == null);
}

test "terminal signal completion requires checked descendants and shell group" {
    try std.testing.expect(terminalSignalCompleted(.{}, .delivered));
    try std.testing.expect(!terminalSignalCompleted(.{
        .delivered = 1,
        .incomplete = true,
    }, .delivered));
    try std.testing.expect(!terminalSignalCompleted(.{}, .failed));
}

test "force close fallback does not erase an incomplete tree operation" {
    try std.testing.expect(!forceCloseSignalIncomplete(true));
    try std.testing.expect(forceCloseSignalIncomplete(false));
    try std.testing.expect(forceCloseSignalIncomplete(null));
}

fn ignoreWorkUpdate(_: ?*anyopaque, _: bool) void {}

const WorkProbe = struct {
    live: isize = 0,
    updates: usize = 0,

    fn update(raw: ?*anyopaque, added: bool) void {
        const self: *WorkProbe = @ptrCast(@alignCast(raw.?));
        self.live += if (added) 1 else -1;
        self.updates += 1;
    }
};

const TestDurableFixture = struct {
    alloc: Allocator,
    tmp: std.testing.TmpDir,
    home: []u8,
    profile: terminal_store.ProfileStore,

    fn init(alloc: Allocator) !TestDurableFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        errdefer alloc.free(home);
        var root = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(
            std.testing.io,
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ) };
        defer root.close();
        var fx = try io_mod.openOrCreateVerifiedPrivateDir(&root, ".fx");
        defer fx.close();
        var sessions = try io_mod.openOrCreateVerifiedPrivateDir(&fx, "sessions");
        defer sessions.close();
        var owner = try io_mod.openOrCreateVerifiedPrivateDir(
            &sessions,
            "terminal-test-owner",
        );
        owner.close();
        return .{
            .alloc = alloc,
            .tmp = tmp,
            .home = home,
            .profile = try terminal_store.ProfileStore.init(
                alloc,
                home,
                process_provider_mod.process_identity_test_provider,
            ),
        };
    }

    fn deinit(self: *TestDurableFixture) void {
        self.profile.deinit();
        self.alloc.free(self.home);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn testPersistence(cwd: []const u8) contracts.StartPersistence {
    return .{
        .grant = .{
            .principal = .{
                .profile_user = "terminal-test",
                .durable_session_id = "terminal-test-owner",
                .workspace_root = cwd,
                .cwd = cwd,
                .transport_role = .interactive,
                .backend = .native,
            },
            .actor = .agent,
            .controls = .full(),
            .generation = .{ .value = 1 },
        },
        .proof = .{ .bytes = @splat(7) },
    };
}

fn checkSessionInitAllocationFailures(alloc: Allocator) !void {
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-allocation");
    var id_owned = true;
    errdefer if (id_owned) alloc.free(id);
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .command = "printf ready",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .return_when = .{ .match = "ready" },
        },
        testPersistence("/workspace"),
        null,
    );
    id_owned = false;
    defer session.deinitUnlaunched();
}

test "session initialization owns durable resources" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSessionInitAllocationFailures,
        .{},
    );
}

const NativeStartAllocationGate = struct {
    armed: bool = false,
    fail_after_release: bool = false,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    blocked: std.atomic.Value(bool) = .init(false),

    fn allocator(self: *@This()) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
    }
    fn allocate(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const result = std.testing.allocator.rawAlloc(len, alignment, address) orelse return null;
        if (self.armed and !self.blocked.swap(true, .acq_rel)) {
            self.entered.set(io_mod.getIo());
            self.release.waitUncancelable(io_mod.getIo());
            if (self.fail_after_release) {
                std.testing.allocator.rawFree(result[0..len], alignment, address);
                return null;
            }
        }
        return result;
    }
    fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        std.testing.allocator.rawFree(bytes, alignment, address);
    }
};

test "owner exit authenticates before fencing and preserves other saved sessions" {
    if (comptime !isSupported()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    fixture.profile.process_provider = @import("../../tools/shell/process_provider.zig").provider;
    var original_source = try std.process.spawn(io_mod.getIo(), .{ .argv = &.{ "/bin/sleep", "30" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer if (original_source.id != null) original_source.kill(io_mod.getIo());
    const request: contracts.StartRequest = .{ .cwd = fixture.home, .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash" } } };
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", try alloc.dupe(u8, "terminal-owner-exit"), request, testPersistence(fixture.home), null);
    defer session.deinit();
    const owner_path = try std.fs.path.join(alloc, &.{ fixture.home, ".fx", "sessions", "terminal-test-owner" });
    defer alloc.free(owner_path);
    var owner_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), owner_path, .{ .iterate = true });
    defer owner_dir.close(io_mod.getIo());
    var owner = try @import("../session/session_child_store.zig").SessionChildCapability.init(alloc, owner_dir, owner_path, .writable);
    defer owner.deinit();
    const proof = try terminal_store.prepareSessionExitProof(alloc, &owner);
    var registry = SupportedRegistry{ .alloc = alloc, .tracker = .{ .context = null, .update_fn = ignoreWorkUpdate }, .profile = &fixture.profile, .host_identity = "test-host", .durable_root = fixture.home, .transport_root = fixture.home };
    registry.slots[0] = .{ .resident = .{ .session = &session, .references = 0 } };
    var cancelled: std.atomic.Value(bool) = .init(false);
    var foreign_cancelled: std.atomic.Value(bool) = .init(false);
    var pending = SupportedRegistry.StartReservation{ .owner_id = "terminal-test-owner", .source = null, .cancelled = &cancelled };
    var foreign = SupportedRegistry.StartReservation{ .owner_id = "another-saved-session", .source = null, .cancelled = &foreign_cancelled };
    const pending_slot = registry.reserveSlot(.{ .starting = &pending }).?;
    var pending_owned = true;
    defer if (pending_owned) registry.abandonStart(pending_slot.index, &pending);
    const foreign_slot = registry.reserveSlot(.{ .starting = &foreign }).?;
    defer registry.abandonStart(foreign_slot.index, &foreign);
    var pid_buffer: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(&pid_buffer, "{d}", .{original_source.id.?});
    const token = try fixture.profile.process_provider.captureToken(alloc, pid);
    const source = try contracts.ProcessOwner.init(@intCast(original_source.id.?), token.view());
    var exit_request = contracts.CloseOwnerRequest{ .authority = .{ .session_id = "terminal-test-owner", .proof = proof }, .process_owner = source };
    exit_request.authority.proof.bytes[0] ^= 1;
    var rejected = try registry.executeAuthorized(.{ .close_owner = exit_request }, &cancelled);
    defer rejected.deinit(alloc);
    try std.testing.expectEqual(contracts.StructuredErrorCode.authority_denied, rejected.view().failure.code);
    try std.testing.expect(!cancelled.load(.acquire));
    try std.testing.expect(!session.backend_detaching.load(.acquire));
    exit_request.authority.proof = proof;
    registry.abandonStart(pending_slot.index, &pending);
    pending_owned = false;
    var closed = try registry.executeAuthorized(.{ .close_owner = exit_request }, &cancelled);
    defer closed.deinit(alloc);
    try std.testing.expect(closed.view() == .success);
    try std.testing.expect(session.backend_detaching.load(.acquire));
    try std.testing.expect(!foreign_cancelled.load(.acquire));
    try std.testing.expect(registry.sourceFencedLocked("terminal-test-owner", source));
    original_source.kill(io_mod.getIo());
    var later = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", try alloc.dupe(u8, "terminal-later-owner-exit"), request, testPersistence(fixture.home), null);
    defer later.deinit();
    registry.slots[0] = .{ .resident = .{ .session = &later, .references = 0 } };
    var duplicate = try registry.executeAuthorized(.{ .close_owner = exit_request }, &cancelled);
    defer duplicate.deinit(alloc);
    try std.testing.expect(duplicate.view() == .success);
    try std.testing.expectEqual(@as(u16, 0), duplicate.view().success.close_owner.closed_sessions);
    try std.testing.expect(!later.backend_detaching.load(.acquire));
    var late = SupportedRegistry.StartReservation{ .owner_id = "terminal-test-owner", .source = source, .cancelled = &cancelled };
    try std.testing.expect(registry.reserveSlot(.{ .starting = &late }) == null);
    try std.testing.expect(cancelled.load(.acquire));
    const next_pid = try std.fmt.bufPrint(&pid_buffer, "{d}", .{std.c.getpid()});
    const next_token = try fixture.profile.process_provider.captureToken(alloc, next_pid);
    const next_source = try contracts.ProcessOwner.init(@intCast(std.c.getpid()), next_token.view());
    cancelled.store(false, .release);
    late.source = next_source;
    const next_slot = registry.reserveSlot(.{ .starting = &late }) orelse return error.TestNextSourceRejected;
    registry.abandonStart(next_slot.index, &late);
    registry.finishOwnerExit("terminal-test-owner", source, .failed);
    var repeated_failure = try registry.executeAuthorized(.{ .close_owner = exit_request }, &cancelled);
    defer repeated_failure.deinit(alloc);
    try std.testing.expectEqual(contracts.StructuredErrorCode.session_lost, repeated_failure.view().failure.code);
    try std.testing.expect(!later.backend_detaching.load(.acquire));
}

test "claimed cancellation reports a busy profile without losing the lease" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Cancel = struct {
        registry: *SupportedRegistry,
        id: []const u8,
        claim: contracts.AuthorityClaim,
        started: std.Io.Event = .unset,
        done: std.Io.Event = .unset,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.started.set(io_mod.getIo());
            self.registry.cancelAuthorized(self.id, self.claim) catch |err| {
                self.failure = err;
            };
            self.done.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const persistence = testPersistence(fixture.home);
    const claim: contracts.AuthorityClaim = .{ .principal = persistence.grant.principal, .actor = persistence.grant.actor, .generation = persistence.grant.generation, .proof = persistence.proof };
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "host", try alloc.dupe(u8, "cancel-busy-profile"), .{ .cwd = fixture.home, .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash" } } }, persistence, null);
    defer session.deinitUnlaunched();
    try fixture.profile.register_resident(&session.durable, null);
    _ = try session.durable.acquire_write_lease(claim, io_mod.milliTimestamp());
    var registry = SupportedRegistry{ .alloc = alloc, .tracker = .{ .context = null, .update_fn = ignoreWorkUpdate }, .profile = &fixture.profile, .host_identity = "host", .durable_root = fixture.home, .transport_root = fixture.home };
    registry.slots[0] = .{ .resident = .{ .session = &session, .references = 0 } };
    fixture.profile.mutex.lockUncancelable(zio);
    var held = true;
    defer if (held) fixture.profile.mutex.unlock(zio);
    var cancel = Cancel{ .registry = &registry, .id = session.id, .claim = claim };
    const thread = try std.Thread.spawn(.{}, Cancel.run, .{&cancel});
    var joined = false;
    defer if (!joined) {
        fixture.profile.mutex.unlock(zio);
        held = false;
        thread.join();
    };
    try cancel.started.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(5000) } });
    const finished = if (cancel.done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(200) } })) |_| true else |_| false;
    fixture.profile.mutex.unlock(zio);
    held = false;
    thread.join();
    joined = true;
    try std.testing.expect(finished);
    try std.testing.expectEqual(@as(?anyerror, error.LockBusy), cancel.failure);
    try std.testing.expectEqual(contracts.WriteLease.agent, session.durable.record.attention.write_lease);
    try std.testing.expectEqual(@as(usize, 0), registry.slots[0].resident.references);
    try registry.cancelAuthorized(session.id, claim);
    try std.testing.expectEqual(contracts.WriteLease.none, session.durable.record.attention.write_lease);
    _ = try session.durable.acquire_write_lease(claim, io_mod.milliTimestamp());
    var wrong_proof = claim;
    wrong_proof.proof.bytes[0] ^= 1;
    try std.testing.expectError(error.InvalidHolderProof, registry.cancelAuthorized(session.id, wrong_proof));
    var wrong_owner = claim;
    wrong_owner.principal.durable_session_id = "another-saved-session";
    try std.testing.expectError(error.PrincipalMismatch, registry.cancelAuthorized(session.id, wrong_owner));
    try std.testing.expectEqual(contracts.WriteLease.agent, session.durable.record.attention.write_lease);
}

test "reopened cancellation resolves its exact owner without scanning the profile" {
    if (comptime !isSupported()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const persistence = testPersistence(fixture.home);
    const claim: contracts.AuthorityClaim = .{ .principal = persistence.grant.principal, .actor = persistence.grant.actor, .generation = persistence.grant.generation, .proof = persistence.proof };
    const id = "cancel-exact-owner";
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "host", try alloc.dupe(u8, id), .{ .cwd = fixture.home, .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash" } } }, persistence, null);
    var session_owned = true;
    defer if (session_owned) session.deinitUnlaunched();
    _ = try session.durable.acquire_write_lease(claim, io_mod.milliTimestamp());
    session.deinitUnlaunched();
    session_owned = false;
    for (0..128) |index| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "unrelated-owner-{d}", .{index});
        try fixture.profile.sessions_dir.dir.createDir(io_mod.getIo(), name, .fromMode(0o700));
    }
    var budget = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 128 });
    fixture.profile.alloc = budget.allocator();
    var profile_restored = false;
    defer if (!profile_restored) {
        fixture.profile.alloc = alloc;
    };
    var registry = SupportedRegistry{ .alloc = alloc, .tracker = .{ .context = null, .update_fn = ignoreWorkUpdate }, .profile = &fixture.profile, .host_identity = "host", .durable_root = fixture.home, .transport_root = fixture.home };
    const result = registry.cancelAuthorized(id, claim);
    fixture.profile.alloc = alloc;
    profile_restored = true;
    try result;
    try std.testing.expectEqual(@as(usize, 0), fixture.profile.residents.items.len);
    const reopened = try fixture.profile.open_terminal(id);
    defer fixture.profile.release_terminal(reopened);
    try std.testing.expectEqual(contracts.WriteLease.none, reopened.record.attention.write_lease);
}

test "owner exit cancels a reserved start before durable initialization" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Start = struct {
        registry: *SupportedRegistry,
        request: contracts.StartRequest,
        cancelled: std.atomic.Value(bool) = .init(false),
        result: ?contracts.OwnedResult = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.result = self.registry.executeAuthorized(.{ .start = self.request }, &self.cancelled) catch |err| failed: {
                self.failure = err;
                break :failed null;
            };
        }
    };
    const Close = struct {
        registry: *SupportedRegistry,
        request: contracts.CloseOwnerRequest,
        result: ?contracts.OwnedResult = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            var cancelled: std.atomic.Value(bool) = .init(false);
            self.result = self.registry.executeAuthorized(.{ .close_owner = self.request }, &cancelled) catch |err| failed: {
                self.failure = err;
                break :failed null;
            };
        }
    };
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    fixture.profile.process_provider = @import("../../tools/shell/process_provider.zig").provider;
    const owner_path = try std.fs.path.join(alloc, &.{ fixture.home, ".fx", "sessions", "terminal-test-owner" });
    defer alloc.free(owner_path);
    var dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), owner_path, .{ .iterate = true });
    defer dir.close(io_mod.getIo());
    var owner = try @import("../session/session_child_store.zig").SessionChildCapability.init(alloc, dir, owner_path, .writable);
    defer owner.deinit();
    const proof = try terminal_store.prepareSessionExitProof(alloc, &owner);
    var pid_buffer: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(&pid_buffer, "{d}", .{std.c.getpid()});
    const token = try fixture.profile.process_provider.captureToken(alloc, pid);
    const source = try contracts.ProcessOwner.init(@intCast(std.c.getpid()), token.view());
    var gate: NativeStartAllocationGate = .{ .armed = true };
    var registry = SupportedRegistry{ .alloc = gate.allocator(), .tracker = .{ .context = null, .update_fn = ignoreWorkUpdate }, .profile = &fixture.profile, .host_identity = "test-host", .durable_root = fixture.home, .transport_root = fixture.home };
    defer registry.deinit();
    var start = Start{ .registry = &registry, .request = .{ .cwd = fixture.home, .command = "read -r ignored", .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash", .clean_start = true } }, .persistence = testPersistence(fixture.home), .process_owner = source } };
    const start_thread = try std.Thread.spawn(.{}, Start.run, .{&start});
    defer if (start.result) |*result| result.deinit(registry.alloc);
    var start_joined = false;
    defer if (!start_joined) {
        start.cancelled.store(true, .release);
        gate.release.set(io_mod.getIo());
        start_thread.join();
    };
    try gate.entered.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(5000) } });
    var close = Close{ .registry = &registry, .request = .{ .authority = .{ .session_id = "terminal-test-owner", .proof = proof }, .process_owner = source } };
    const close_thread = try std.Thread.spawn(.{}, Close.run, .{&close});
    defer if (close.result) |*result| result.deinit(registry.alloc);
    var close_joined = false;
    defer if (!close_joined) close_thread.join();
    const deadline = io_mod.milliTimestamp() + 200;
    while (!start.cancelled.load(.acquire) and io_mod.milliTimestamp() < deadline) io_mod.sleep(std.time.ns_per_ms);
    const owner_cancelled_start = start.cancelled.load(.acquire);
    gate.release.set(io_mod.getIo());
    start_thread.join();
    start_joined = true;
    close_thread.join();
    close_joined = true;
    try std.testing.expect(owner_cancelled_start);
    try std.testing.expectEqual(@as(?anyerror, null), start.failure);
    try std.testing.expectEqual(contracts.StructuredErrorCode.cancelled, start.result.?.view().failure.code);
    try std.testing.expectEqual(@as(?anyerror, null), close.failure);
    try std.testing.expect(close.result.?.view() == .success);
    for (registry.slots) |slot| try std.testing.expect(slot == .empty);
    if (owner.iterate(alloc, .terminal_state)) |value| {
        var names = value;
        defer names.deinit();
        try std.testing.expectEqual(@as(usize, 0), names.names.len);
    } else |err| try std.testing.expectEqual(error.FileNotFound, err);
}

test "owner exit fences are bounded idempotent and cleared only after process death" {
    if (comptime !isSupported()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    fixture.profile.process_provider = @import("../../tools/shell/process_provider.zig").provider;
    var child = try std.process.spawn(io_mod.getIo(), .{ .argv = &.{ "/bin/sleep", "30" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer if (child.id != null) child.kill(io_mod.getIo());
    var pid_buffer: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(&pid_buffer, "{d}", .{child.id.?});
    const token = try fixture.profile.process_provider.captureToken(alloc, pid);
    const source = try contracts.ProcessOwner.init(@intCast(child.id.?), token.view());
    var registry = SupportedRegistry{ .alloc = alloc, .tracker = .{ .context = null, .update_fn = ignoreWorkUpdate }, .profile = &fixture.profile, .host_identity = "test-host", .durable_root = fixture.home, .transport_root = fixture.home };
    try registry.fenceSourceLocked("owner", source);
    try registry.fenceSourceLocked("owner", source);
    try std.testing.expect(registry.exit_fences[0] != null and registry.exit_fences[1] == null);
    registry.pruneExitFences(&.{});
    try std.testing.expect(registry.sourceFencedLocked("owner", source));
    const actual_provider = fixture.profile.process_provider;
    fixture.profile.process_provider = process_provider_mod.unavailable_provider;
    registry.pruneExitFences(&.{});
    try std.testing.expect(registry.sourceFencedLocked("owner", source));
    fixture.profile.process_provider = actual_provider;
    child.kill(io_mod.getIo());
    registry.pruneExitFences(&.{});
    try std.testing.expect(registry.sourceFencedLocked("owner", source));
    registry.finishOwnerExit("owner", source, .succeeded);
    registry.pruneExitFences(&.{});
    try std.testing.expect(!registry.sourceFencedLocked("owner", source));
    for (0..max_sessions) |index| {
        var owner_buffer: [32]u8 = undefined;
        const owner_id = try std.fmt.bufPrint(&owner_buffer, "owner-{d}", .{index});
        try registry.fenceSourceLocked(owner_id, source);
    }
    try std.testing.expectError(error.CapacityExceeded, registry.fenceSourceLocked("one-too-many", source));
    var cancelled: std.atomic.Value(bool) = .init(false);
    var pending = SupportedRegistry.StartReservation{ .owner_id = "one-too-many", .source = source, .cancelled = &cancelled };
    try std.testing.expect(registry.reserveSlot(.{ .starting = &pending }) == null);
    try std.testing.expect(!cancelled.load(.acquire));
}

test "idle retirement excludes pending starts and fences later admissions" {
    if (comptime !isSupported()) return error.SkipZigTest;
    const Idle = struct {
        fn yes(_: ?*anyopaque) bool {
            return true;
        }
        fn no(_: ?*anyopaque) bool {
            return false;
        }
    };
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    var stopping: std.atomic.Value(bool) = .init(false);
    var cancelled: std.atomic.Value(bool) = .init(false);
    var registry = SupportedRegistry{ .alloc = alloc, .tracker = .{ .context = null, .update_fn = ignoreWorkUpdate }, .profile = &fixture.profile, .host_identity = "test-host", .durable_root = fixture.home, .transport_root = fixture.home, .stop_requested = &stopping };
    var pending = SupportedRegistry.StartReservation{ .owner_id = "owner", .source = null, .cancelled = &cancelled };
    const reservation = registry.reserveSlot(.{ .starting = &pending }).?;
    try std.testing.expect(!registry.retireIfIdle(null, Idle.yes));
    try std.testing.expect(!stopping.load(.acquire));
    registry.abandonStart(reservation.index, &pending);
    try std.testing.expect(!registry.retireIfIdle(null, Idle.no));
    try std.testing.expect(registry.retireIfIdle(null, Idle.yes));
    try std.testing.expect(stopping.load(.acquire));
    try std.testing.expect(registry.reserveSlot(.{ .starting = &pending }) == null);
    try std.testing.expect(cancelled.load(.acquire));
}

test "owner shutdown after native launch begins prevents releasing a child" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Launch = struct {
        session: *Session,
        request: contracts.StartRequest,
        home: []const u8,
        failure: ?anyerror = null,
        cancelled: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.session.launch(self.request, self.home, self.home, &self.cancelled) catch |err| {
                self.failure = err;
            };
        }
    };
    var fixture = try TestDurableFixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.profile.process_provider = @import("../../tools/shell/process_provider.zig").provider;
    var gate: NativeStartAllocationGate = .{};
    const alloc = gate.allocator();
    const request: contracts.StartRequest = .{
        .cwd = fixture.home,
        .command = "read -r ignored",
        .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash", .clean_start = true } },
    };
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", try alloc.dupe(u8, "terminal-cancelled-launch"), request, testPersistence(fixture.home), null);
    defer session.deinit();
    session.markLive();
    gate.armed = true;
    var launch = Launch{ .session = &session, .request = request, .home = fixture.home };
    const thread = try std.Thread.spawn(.{}, Launch.run, .{&launch});
    var joined = false;
    defer if (!joined) {
        session.shutdown();
        gate.release.set(io_mod.getIo());
        thread.join();
    };
    try gate.entered.waitTimeout(io_mod.getIo(), .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(5000) } });
    session.shutdown();
    gate.release.set(io_mod.getIo());
    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), launch.failure);
    try std.testing.expect(session.launch_phase.load(.acquire) != .released);
    try std.testing.expect(session.launcher == null);
}

fn testRegisteredShutdownStart(allocation_failure: bool) !void {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Launch = struct {
        registry: *SupportedRegistry,
        session: *Session,
        request: contracts.StartRequest,
        home: []const u8,
        cancelled: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        done: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            defer self.done.set(io_mod.getIo());
            self.session.launch(self.request, self.home, self.home, &self.cancelled) catch |err| {
                self.failure = err;
                self.registry.retireFailedStart(0, self.session, err);
            };
        }
    };
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    var gate: NativeStartAllocationGate = .{ .fail_after_release = allocation_failure };
    const request: contracts.StartRequest = .{ .cwd = fixture.home, .command = "read -r hold", .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash", .clean_start = true } } };
    const session = try alloc.create(Session);
    session.* = try Session.init(gate.allocator(), .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "host", try alloc.dupe(u8, "cancelled-registered-start"), request, testPersistence(fixture.home), null);
    var registry = SupportedRegistry{ .alloc = alloc, .tracker = .{ .context = null, .update_fn = ignoreWorkUpdate }, .profile = &fixture.profile, .host_identity = "host", .durable_root = fixture.home, .transport_root = fixture.home };
    registry.slots[0] = .{ .resident = .{ .session = session, .references = 1 } };
    defer registry.deinit();
    try fixture.profile.register_resident(&session.durable, null);
    session.markLive();
    const original_boundary = session.durable.record.updated_at_ms;
    gate.armed = true;
    var launch = Launch{ .registry = &registry, .session = session, .request = request, .home = fixture.home };
    const thread = try std.Thread.spawn(.{}, Launch.run, .{&launch});
    var joined = false;
    defer if (!joined) {
        launch.cancelled.store(true, .release);
        gate.release.set(zio);
        thread.join();
    };
    try gate.entered.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(5000) } });
    fixture.profile.mutex.lockUncancelable(zio);
    if (allocation_failure) session.backend_detaching.store(true, .release) else launch.cancelled.store(true, .release);
    gate.release.set(zio);
    const completed_while_held = if (launch.done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(200) } })) |_| true else |_| false;
    fixture.profile.mutex.unlock(zio);
    thread.join();
    joined = true;
    try std.testing.expect(completed_while_held);
    try std.testing.expectEqual(@as(?anyerror, if (allocation_failure) error.OutOfMemory else error.Cancelled), launch.failure);
    try std.testing.expect(registry.slots[0] == .resident);
    try std.testing.expectEqual(session, registry.slots[0].resident.session);
    try std.testing.expectEqual(@as(usize, 0), registry.slots[0].resident.references);
    try std.testing.expect(session.durable.registered);
    try std.testing.expectEqual(&session.durable, fixture.profile.residents.items[0]);
    try std.testing.expectEqual(original_boundary, session.durable.record.updated_at_ms);
    try std.testing.expectEqual(contracts.Lifecycle.starting, session.durable.record.lifecycle);
    try std.testing.expect(!session.live_counted and session.isRecyclable());
}

test "registered cancelled start retires without waiting on the profile writer" {
    try testRegisteredShutdownStart(false);
}

test "shutdown retires a registered launch allocation failure without blocking" {
    try testRegisteredShutdownStart(true);
}

test "start cancellation before registration does not wait on profile ownership" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Init = struct {
        alloc: Allocator,
        fixture: *TestDurableFixture,
        id: []u8,
        cancelled: std.atomic.Value(bool) = .init(false),
        result: ?Session = null,
        failure: ?anyerror = null,
        done: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            defer self.done.set(io_mod.getIo());
            self.result = Session.init(self.alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &self.fixture.profile, "host", self.id, .{ .cwd = self.fixture.home, .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash" } } }, testPersistence(self.fixture.home), &self.cancelled) catch |err| failed: {
                self.failure = err;
                break :failed null;
            };
        }
    };
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    var gate: NativeStartAllocationGate = .{ .armed = true };
    var init = Init{ .alloc = gate.allocator(), .fixture = &fixture, .id = try alloc.dupe(u8, "cancel-before-registration") };
    defer if (init.result) |*session| session.deinitUnlaunched() else alloc.free(init.id);
    fixture.profile.mutex.lockUncancelable(zio);
    var held = true;
    defer if (held) fixture.profile.mutex.unlock(zio);
    const worker = try std.Thread.spawn(.{}, Init.run, .{&init});
    var joined = false;
    defer if (!joined) {
        fixture.profile.mutex.unlock(zio);
        held = false;
        init.cancelled.store(true, .release);
        gate.release.set(zio);
        worker.join();
    };
    try gate.entered.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(5000) } });
    init.cancelled.store(true, .release);
    gate.release.set(zio);
    const finished = if (init.done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(200) } })) |_| true else |_| false;
    fixture.profile.mutex.unlock(zio);
    held = false;
    worker.join();
    joined = true;
    try std.testing.expect(finished);
    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), init.failure);
    try std.testing.expect(init.result == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.profile.residents.items.len);
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.access(zio, ".fx/sessions/terminal-test-owner/terminal", .{}));
}

const StartupMetadataOperation = enum { publication, boundary, matching, result };

fn testStartupMetadataCancellation(operation: StartupMetadataOperation) !void {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Operation = struct {
        session: *Session,
        operation: StartupMetadataOperation,
        cancelled: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        done: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            defer self.done.set(io_mod.getIo());
            self.execute() catch |err| {
                self.failure = err;
            };
        }
        fn execute(self: *@This()) !void {
            switch (self.operation) {
                .publication => self.session.publishStarted(@intCast(std.c.getpid())),
                .boundary => self.session.commitStartupBoundary(),
                .matching => {
                    _ = try self.session.waitFor(.{ .match = "missing-pattern" }, 5000, &self.cancelled);
                },
                .result => {
                    var result = try self.session.startResult(.started, .{ .actor = .agent, .controls = .full() });
                    result.deinit(self.session.alloc);
                },
            }
        }
    };
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    fixture.profile.process_provider = @import("../../tools/shell/process_provider.zig").provider;
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "host", try alloc.dupe(u8, "startup-metadata-cancel"), .{ .cwd = fixture.home, .command = "printf ready", .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash" } } }, testPersistence(fixture.home), null);
    defer session.deinitUnlaunched();
    if (operation != .publication) session.lifecycle = .running;
    fixture.profile.mutex.lockUncancelable(zio);
    var held = true;
    defer if (held) fixture.profile.mutex.unlock(zio);
    var task = Operation{ .session = &session, .operation = operation };
    const thread = try std.Thread.spawn(.{}, Operation.run, .{&task});
    var joined = false;
    defer if (!joined) {
        fixture.profile.mutex.unlock(zio);
        held = false;
        task.cancelled.store(true, .release);
        thread.join();
    };
    const deadline = io_mod.milliTimestamp() + 5000;
    while (session.mutex.tryLock()) {
        session.mutex.unlock(zio);
        if (io_mod.milliTimestamp() >= deadline) return error.TestMetadataOperationDidNotBegin;
        io_mod.sleep(wait_poll_ns);
    }
    session.backend_detaching.store(true, .release);
    const finished = if (task.done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(200) } })) |_| true else |_| false;
    task.cancelled.store(true, .release);
    fixture.profile.mutex.unlock(zio);
    held = false;
    thread.join();
    joined = true;
    try std.testing.expect(finished);
    try std.testing.expectEqual(contracts.Lifecycle.starting, session.durable.record.lifecycle);
    if (operation == .publication) try std.testing.expectEqual(contracts.Lifecycle.starting, session.lifecycle);
}

test "started publication cancels after waiting for profile metadata" {
    try testStartupMetadataCancellation(.publication);
}
test "command boundary cancels after waiting for profile metadata" {
    try testStartupMetadataCancellation(.boundary);
}
test "startup matching cancels after waiting for profile metadata" {
    try testStartupMetadataCancellation(.matching);
}
test "startup result cancels after waiting for profile metadata" {
    try testStartupMetadataCancellation(.result);
}

test "owner shutdown joins an expired timer without waiting on profile metadata" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Timer = struct {
        session: *Session,
        done: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            self.session.timeoutMain();
            self.done.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    fixture.profile.process_provider = @import("../../tools/shell/process_provider.zig").provider;
    var child = try std.process.spawn(zio, .{ .argv = &.{ "/bin/sleep", "30" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .pgid = 0 });
    defer if (child.id != null) child.kill(zio);
    var pid_buffer: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(&pid_buffer, "{d}", .{child.id.?});
    const token = try fixture.profile.process_provider.captureToken(alloc, pid);
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "host", try alloc.dupe(u8, "cancelled-expired-timer"), .{ .cwd = fixture.home, .timeout_ms = 1, .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash" } } }, testPersistence(fixture.home), null);
    defer session.deinit();
    try session.durable.mark_started(pid, token, io_mod.milliTimestamp(), null);
    session.child_pid = child.id.?;
    session.child_token = token;
    session.lifecycle = .running;
    session.timeout_at_ms = session.durable.record.timeout_at_ms;
    fixture.profile.mutex.lockUncancelable(zio);
    var profile_held = true;
    defer if (profile_held) fixture.profile.mutex.unlock(zio);
    session.mutex.lockUncancelable(zio);
    var session_held = true;
    defer if (session_held) session.mutex.unlock(zio);
    var timer = Timer{ .session = &session };
    session.timeout_thread = try std.Thread.spawn(.{}, Timer.run, .{&timer});
    const deadline = io_mod.milliTimestamp() + 5000;
    while (session.mutex.state.load(.acquire) != .contended) {
        if (io_mod.milliTimestamp() >= deadline) return error.TestTimerDidNotBegin;
        io_mod.sleep(wait_poll_ns);
    }
    session.backend_detaching.store(true, .release);
    session.mutex.unlock(zio);
    session_held = false;
    const finished = if (timer.done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(200) } })) |_| true else |_| false;
    fixture.profile.mutex.unlock(zio);
    profile_held = false;
    session.stopTimeoutWatcher();
    try std.testing.expect(finished);
    try std.testing.expect(!session.durable.record.timed_out);
    try std.testing.expect(session.timeout_thread == null);
}

const TmuxDeinitTest = struct {
    fn command(socket: []const u8, args: []const []const u8) ![]u8 {
        const alloc = std.testing.allocator;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        try argv.appendSlice(alloc, &.{ "tmux", "-S", socket, "-f", "/dev/null" });
        try argv.appendSlice(alloc, args);
        const result = try @import("../execution/process_owner.zig").run(alloc, .{ .argv = argv.items, .stdout_limit = 4096, .timeout_ms = 2000 });
        defer alloc.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            alloc.free(result.stdout);
            return error.TmuxFixtureCommandFailed;
        }
        return result.stdout;
    }
    fn discard(socket: []const u8, args: []const []const u8) !void {
        std.testing.allocator.free(try command(socket, args));
    }
    fn pendingClient(socket: []const u8) !?std.posix.pid_t {
        const alloc = std.testing.allocator;
        const result = try @import("../execution/process_owner.zig").run(alloc, .{ .argv = &.{ "/bin/ps", "-axo", "pid=,command=" }, .stdout_limit = 1024 * 1024, .timeout_ms = 2000 });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (std.mem.find(u8, line, socket) == null or std.mem.find(u8, line, "pipe-pane") == null) continue;
            var words = std.mem.tokenizeAny(u8, line, " \t");
            return try std.fmt.parseInt(std.posix.pid_t, words.next() orelse continue, 10);
        }
        return null;
    }
};

test "session destruction preserves prior forced tmux cleanup failure without another RPC" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Dispose = struct {
        session: *Session,
        done: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            self.session.deinit();
            self.done.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    const provider = @import("../../tools/shell/process_provider.zig").provider;
    for ([_]bool{ true, false }) |prior_force| {
        var fixture = try TestDurableFixture.init(alloc);
        defer fixture.deinit();
        fixture.profile.process_provider = provider;
        var persistence = testPersistence(fixture.home);
        persistence.grant.principal.backend = .tmux;
        const request = contracts.StartRequest{ .cwd = fixture.home, .backend = .tmux };
        var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", try alloc.dupe(u8, "terminal-tmux-deinit"), request, persistence, null);
        var session_owned = true;
        defer if (session_owned) session.deinit();
        const transport_root = try std.fmt.allocPrint(alloc, "/tmp/fx-deinit-{s}", .{session.durable.record.backend_identity});
        defer alloc.free(transport_root);
        try std.Io.Dir.createDirAbsolute(zio, transport_root, .fromMode(0o700));
        defer std.Io.Dir.deleteDirAbsolute(zio, transport_root) catch {};
        var paths = try tmux_session.Paths.init(alloc, fixture.home, transport_root, session.durable.record.backend_identity);
        defer paths.deinit(alloc);
        var server_pid: ?std.posix.pid_t = null;
        defer {
            if (server_pid) |pid| std.posix.kill(pid, .CONT) catch {};
            TmuxDeinitTest.discard(paths.socket, &.{ "kill-session", "-t", paths.session_name }) catch {};
            TmuxDeinitTest.discard(paths.socket, &.{ "kill-session", "-t", "other-owner" }) catch {};
            std.Io.Dir.deleteFileAbsolute(zio, paths.socket) catch {};
        }
        TmuxDeinitTest.discard(paths.socket, &.{ "new-session", "-d", "-s", paths.session_name, "-n", "terminal", "exec sleep 30" }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        try TmuxDeinitTest.discard(paths.socket, &.{ "set-option", "-g", "@fx_terminal_namespace", "1" });
        try TmuxDeinitTest.discard(paths.socket, &.{ "set-option", "-t", paths.session_name, "@fx_terminal_namespace", session.durable.record.backend_identity });
        try TmuxDeinitTest.discard(paths.socket, &.{ "set-option", "-w", "-t", paths.session_name, "remain-on-exit", "on" });
        try TmuxDeinitTest.discard(paths.socket, &.{ "new-session", "-d", "-s", "other-owner", "exec sleep 30" });
        const identities = try TmuxDeinitTest.command(paths.socket, &.{ "display-message", "-p", "-t", paths.target, "#{pane_id}|#{pane_pid}|#{pid}" });
        defer alloc.free(identities);
        var fields = std.mem.splitScalar(u8, std.mem.trim(u8, identities, "\r\n"), '|');
        const pane_id = fields.next() orelse return error.InvalidFixture;
        const pane_pid = fields.next() orelse return error.InvalidFixture;
        server_pid = try std.fmt.parseInt(std.posix.pid_t, fields.next() orelse return error.InvalidFixture, 10);
        const token = try provider.captureToken(alloc, pane_pid);
        var output: std.Io.Writer.Allocating = .init(alloc);
        defer output.deinit();
        try std.json.Stringify.value(.{ .schema_version = @as(u16, 1), .backend_identity = session.durable.record.backend_identity, .session_name = paths.session_name, .pane_id = pane_id, .pane_pid = pane_pid, .pane_process_token = token.view() }, .{}, &output.writer);
        var manifest_file = try std.Io.Dir.createFileAbsolute(zio, paths.manifest, .{ .permissions = .fromMode(0o600) });
        try manifest_file.writeStreamingAll(zio, output.written());
        manifest_file.close(zio);
        session.tmux_backend = try tmux_session.Backend.recover(alloc, provider, fixture.home, transport_root, session.durable.record.backend_identity, "");
        try session.durable.mark_started(pane_pid, token, io_mod.milliTimestamp(), null);
        session.child_pid = try std.fmt.parseInt(std.posix.pid_t, pane_pid, 10);
        session.child_token = token;
        session.lifecycle = .running;
        if (prior_force) {
            try provider.signalProcess(alloc, pane_pid, token);
            const death_deadline = io_mod.milliTimestamp() + 2000;
            while (provider.matchToken(alloc, pane_pid, token) == .matched and io_mod.milliTimestamp() < death_deadline) io_mod.sleep(wait_poll_ns);
            try std.testing.expect(provider.matchToken(alloc, pane_pid, token) != .matched);
            session.backend_detaching.store(true, .release);
            try std.posix.kill(server_pid.?, .STOP);
            try std.testing.expectError(error.Timeout, session.tmux_backend.?.cleanupChecked(provider, io_mod.milliTimestamp() + 100));
        }
        const before = try std.Io.Dir.cwd().statFile(zio, paths.manifest, .{});
        var dispose = Dispose{ .session = &session };
        const started = io_mod.nanoTimestamp();
        const thread = try std.Thread.spawn(.{}, Dispose.run, .{&dispose});
        session_owned = false;
        var client_pid: ?std.posix.pid_t = null;
        if (prior_force) {
            const observation_deadline = io_mod.milliTimestamp() + 200;
            while (!dispose.done.isSet() and client_pid == null and io_mod.milliTimestamp() < observation_deadline) client_pid = try TmuxDeinitTest.pendingClient(paths.socket);
        }
        const completed = if (dispose.done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(300) } })) |_| true else |_| false;
        const elapsed = io_mod.nanoTimestamp() - started;
        if (!completed) if (client_pid) |pid| {
            std.posix.kill(pid, .KILL) catch {};
        };
        if (prior_force) try std.posix.kill(server_pid.?, .CONT);
        thread.join();
        if (!completed) try std.testing.expect(client_pid != null);
        try std.testing.expect(completed);
        try std.testing.expect(elapsed < 500 * std.time.ns_per_ms);
        if (prior_force) {
            try std.testing.expect(client_pid == null);
            const after = try std.Io.Dir.cwd().statFile(zio, paths.manifest, .{});
            try std.testing.expectEqual(before.inode, after.inode);
            try std.testing.expectEqual(before.mtime, after.mtime);
        } else try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(zio, paths.manifest, .{}));
        try TmuxDeinitTest.discard(paths.socket, &.{ "has-session", "-t", "other-owner" });
    }
}

test "detached terminal completion preserves unknown status without publishing it" {
    if (comptime !isSupported()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const request = contracts.StartRequest{ .cwd = fixture.home };
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", try alloc.dupe(u8, "terminal-detached-term"), request, testPersistence(fixture.home), null);
    defer session.deinit();
    session.backend_detaching.store(true, .release);
    const before = try session.durable.state.?.stat(.terminal_state, "record-terminal-detached-term.json");
    for ([_]std.process.Child.Term{ .{ .exited = 0 }, .{ .signal = .KILL }, .{ .unknown = 1 }, .{ .stopped = .STOP } }) |term| {
        session.lifecycle = .running;
        session.setTerm(term);
        try std.testing.expectEqual(if (outcomeFromTerm(term) != null) contracts.Lifecycle.exited else contracts.Lifecycle.lost, session.lifecycle);
        try std.testing.expectEqual(before, try session.durable.state.?.stat(.terminal_state, "record-terminal-detached-term.json"));
    }
}

test "native shutdown joins busy output without waiting on the profile writer" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Stop = struct {
        session: *Session,
        done: std.Io.Event = .unset,
        elapsed_ns: i128 = 0,
        fn run(self: *@This()) void {
            const started = io_mod.nanoTimestamp();
            self.session.shutdown();
            self.session.finalizeBackend();
            self.elapsed_ns = io_mod.nanoTimestamp() - started;
            self.done.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    fixture.profile.process_provider = @import("../../tools/shell/process_provider.zig").provider;
    const request: contracts.StartRequest = .{
        .cwd = fixture.home,
        .command = "printf 'BUSY_EXIT_READY\\n'; read -r next; printf 'BUSY_EXIT_BLOCKED\\n'; read -r hold",
        .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash", .clean_start = true } },
    };
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", try alloc.dupe(u8, "terminal-busy-output-exit"), request, testPersistence(fixture.home), null);
    defer session.deinit();
    session.markLive();
    var cancelled: std.atomic.Value(bool) = .init(false);
    try session.launchNative(request, &cancelled);
    try std.testing.expectEqual(contracts.ReturnOutcome.condition_met, try session.waitFor(.{ .match = "BUSY_EXIT_READY" }, 5000, &cancelled));
    const shell_pid = session.child_pid.?;
    const launcher_pid = session.launcher.?.id.?;
    const prior = session.durable.output_cursor();
    const record_name = try std.fmt.allocPrint(alloc, "record-{s}.json", .{session.id});
    defer alloc.free(record_name);
    const before_record = try session.durable.state.?.stat(.terminal_state, record_name);
    fixture.profile.mutex.lockUncancelable(zio);
    var held = true;
    defer if (held) fixture.profile.mutex.unlock(zio);
    try writeAllFd(session.master_fd.?, "\n", true);
    var append_began = false;
    const deadline = io_mod.milliTimestamp() + 5000;
    while (!append_began and io_mod.milliTimestamp() < deadline) {
        if (session.mutex.tryLock()) {
            session.mutex.unlock(zio);
            io_mod.sleep(wait_poll_ns);
        } else {
            // Startup is complete and the control thread awaits termination;
            // only the real output worker now takes this mutex.
            append_began = true;
        }
    }
    try std.testing.expect(append_began);
    var stop: Stop = .{ .session = &session };
    const thread = try std.Thread.spawn(.{}, Stop.run, .{&stop});
    const finished_while_held = if (stop.done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(500) } })) |_| true else |_| false;
    const shell_missing_before_release = std.c.errno(std.c.kill(shell_pid, @enumFromInt(0))) == .SRCH;
    fixture.profile.mutex.unlock(zio);
    held = false;
    thread.join();
    try std.testing.expect(finished_while_held);
    try std.testing.expect(stop.elapsed_ns < 500 * std.time.ns_per_ms);
    try std.testing.expect(shell_missing_before_release);
    try std.testing.expect(session.output_done.isSet() and session.backend_done.isSet());
    try std.testing.expect(session.output_thread == null and session.control_thread == null);
    try std.testing.expect(session.launcher == null and !session.backend_started);
    try std.testing.expectEqual(std.posix.E.SRCH, std.c.errno(std.c.kill(launcher_pid, @enumFromInt(0))));
    try std.testing.expectEqual(prior, session.durable.output_cursor());
    try session.durable.record.validate();
    const after_record = try session.durable.state.?.stat(.terminal_state, record_name);
    try std.testing.expectEqual(before_record, after_record);
    try std.testing.expect(session.lifecycle == .exited or session.lifecycle == .lost);
    const facts = session.factsLocked(.{ .actor = .agent, .controls = .{} });
    try std.testing.expect(facts.lifecycle == .exited or facts.lifecycle == .lost);
    var recovered_profile = try terminal_store.ProfileStore.init(alloc, fixture.home, fixture.profile.process_provider);
    defer recovered_profile.deinit();
    var recovered = try recovered_profile.recover("next-host", io_mod.milliTimestamp());
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered.sessions.items.len);
    const saved = &recovered.sessions.items[0];
    try std.testing.expectEqual(contracts.Lifecycle.lost, saved.record.lifecycle);
    try std.testing.expectEqual(prior, saved.record.output_cursor);
    try saved.record.validate();
}

test "owner exit stops profile descendants before the shell identity is published" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    fixture.profile.process_provider = @import("../../tools/shell/process_provider.zig").provider;
    const shell_path = try std.fs.path.join(alloc, &.{ fixture.home, "bash" });
    defer alloc.free(shell_path);
    const profile_path = try std.fs.path.join(alloc, &.{ fixture.home, "profile" });
    defer alloc.free(profile_path);
    const script_path = try std.fs.path.join(alloc, &.{ fixture.home, "escaped.py" });
    defer alloc.free(script_path);
    const identity_path = try std.fs.path.join(alloc, &.{ fixture.home, "escaped.pid" });
    defer alloc.free(identity_path);
    const command_path = try std.fs.path.join(alloc, &.{ fixture.home, "command-ran" });
    defer alloc.free(command_path);
    const wrapper = try std.fmt.allocPrint(alloc, "#!/bin/bash\nwhile [ \"$#\" -gt 0 ] && [ \"$1\" != \"-c\" ]; do shift; done\nexec /bin/bash --noprofile --rcfile '{s}' -i \"$@\"\n", .{profile_path});
    defer alloc.free(wrapper);
    var shell_file = try std.Io.Dir.createFileAbsolute(zio, shell_path, .{ .permissions = .fromMode(0o700) });
    try shell_file.writeStreamingAll(zio, wrapper);
    shell_file.close(zio);
    const profile_text = try std.fmt.allocPrint(alloc, "python3 '{s}' &\nwhile :; do sleep 0.05; done\n", .{script_path});
    defer alloc.free(profile_text);
    var profile_file = try std.Io.Dir.createFileAbsolute(zio, profile_path, .{});
    try profile_file.writeStreamingAll(zio, profile_text);
    profile_file.close(zio);
    const python = try std.fmt.allocPrint(alloc, "import os,time\nif os.fork() == 0:\n os.setsid()\n with open({f},'w') as f: f.write(str(os.getpid())+' '+str(os.getpgrp())+' '+str(os.getsid(0)))\n while True: time.sleep(1)\nos.wait()\n", .{std.json.fmt(identity_path, .{})});
    defer alloc.free(python);
    var script = try std.Io.Dir.createFileAbsolute(zio, script_path, .{});
    try script.writeStreamingAll(zio, python);
    script.close(zio);
    const command = try std.fmt.allocPrint(alloc, "printf forbidden > '{s}'", .{command_path});
    defer alloc.free(command);
    const request: contracts.StartRequest = .{ .cwd = fixture.home, .command = command, .shell = .{ .executable = .{ .path = shell_path, .clean_start = true } } };
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", try alloc.dupe(u8, "terminal-profile-exit"), request, testPersistence(fixture.home), null);
    defer session.deinit();
    var observed = try process_tree.Tracker.init(alloc);
    defer {
        if (session.launcher) |child| if (child.id) |pid| observed.refresh(pid) catch {};
        _ = observed.signalAll(.KILL);
        observed.deinit();
    }
    var cancelled: std.atomic.Value(bool) = .init(false);
    session.markLive();
    try session.launchNative(request, &cancelled);
    const launcher_pid = session.launcher.?.id.?;
    const deadline = io_mod.milliTimestamp() + 5000;
    var identity: ?[]u8 = null;
    defer if (identity) |bytes| alloc.free(bytes);
    while (identity == null and io_mod.milliTimestamp() < deadline) {
        identity = std.Io.Dir.cwd().readFileAlloc(zio, identity_path, alloc, .limited(128)) catch null;
        if (identity) |contents| if (contents.len == 0) {
            alloc.free(contents);
            identity = null;
        };
        if (identity == null) io_mod.sleep(wait_poll_ns);
    }
    const bytes = identity orelse return error.TestProfileDidNotStart;
    var fields = std.mem.tokenizeScalar(u8, bytes, ' ');
    const escaped_pid = try std.fmt.parseInt(std.posix.pid_t, fields.next().?, 10);
    try std.testing.expectEqual(escaped_pid, try std.fmt.parseInt(std.posix.pid_t, fields.next().?, 10));
    try std.testing.expectEqual(escaped_pid, try std.fmt.parseInt(std.posix.pid_t, fields.next().?, 10));
    try observed.refresh(launcher_pid);
    try std.testing.expect(observed.anyAlive());
    try std.testing.expect(session.signalTarget() == null);
    try std.testing.expect(session.child_pid == null);
    try std.testing.expect(session.launcher_token != null);
    const owner_path = try std.fs.path.join(alloc, &.{ fixture.home, ".fx", "sessions", "terminal-test-owner" });
    defer alloc.free(owner_path);
    var owner_dir = try std.Io.Dir.openDirAbsolute(zio, owner_path, .{ .iterate = true });
    defer owner_dir.close(zio);
    var owner = try @import("../session/session_child_store.zig").SessionChildCapability.init(alloc, owner_dir, owner_path, .writable);
    defer owner.deinit();
    const proof = (try terminal_store.loadSessionExitProof(alloc, &owner)).?;
    var pid_buffer: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(&pid_buffer, "{d}", .{std.c.getpid()});
    const token = try fixture.profile.process_provider.captureToken(alloc, pid);
    const source = try contracts.ProcessOwner.init(@intCast(std.c.getpid()), token.view());
    var registry = SupportedRegistry{ .alloc = alloc, .tracker = .{ .context = null, .update_fn = ignoreWorkUpdate }, .profile = &fixture.profile, .host_identity = "test-host", .durable_root = fixture.home, .transport_root = fixture.home };
    registry.slots[0] = .{ .resident = .{ .session = &session, .references = 0 } };
    const started = io_mod.nanoTimestamp();
    var result = try registry.executeAuthorized(.{ .close_owner = .{ .authority = .{ .session_id = "terminal-test-owner", .proof = proof }, .process_owner = source } }, &cancelled);
    defer result.deinit(alloc);
    try std.testing.expect(result.view() == .success);
    while (observed.anyAlive() and io_mod.nanoTimestamp() - started < 500 * std.time.ns_per_ms) io_mod.sleep(wait_poll_ns);
    try std.testing.expect(!observed.anyAlive());
    try std.testing.expect(io_mod.nanoTimestamp() - started < 500 * std.time.ns_per_ms);
    try std.testing.expect(session.launcher == null);
    try std.testing.expect(session.backend_done.isSet());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(zio, command_path, .{}));
}

test "native force close joins while another process retains the PTY slave" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Close = struct {
        session: *Session,
        claim: contracts.AuthorityClaim,
        done: std.Io.Event = .unset,
        result: ?contracts.OwnedResult = null,
        failure: ?anyerror = null,
        elapsed_ns: i128 = 0,

        fn run(self: *@This()) void {
            const started = io_mod.nanoTimestamp();
            self.result = closeAction(self.session, .{
                .session_id = self.session.id,
                .policy = .force,
                .authority = self.claim,
            }) catch |err| failed: {
                self.failure = err;
                break :failed null;
            };
            self.elapsed_ns = io_mod.nanoTimestamp() - started;
            self.done.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    fixture.profile.process_provider = @import("../../tools/shell/process_provider.zig").provider;
    const persistence = testPersistence(fixture.home);
    const request: contracts.StartRequest = .{
        .cwd = fixture.home,
        .command = "printf 'OUTPUT_DRAIN_STARTED\\n'; read -r ignored",
        .shell = .{ .executable = .{
            .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash",
            .clean_start = true,
        } },
    };
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", try alloc.dupe(u8, "terminal-retained-output"), request, persistence, null);
    defer session.deinit();
    session.markLive();
    var cancel: std.atomic.Value(bool) = .init(false);
    try session.launchNative(request, &cancel);
    try std.testing.expectEqual(contracts.ReturnOutcome.condition_met, try session.waitFor(.{ .match = "OUTPUT_DRAIN_STARTED" }, 5000, &cancel));
    const shell_pid = session.child_pid.?;
    const launcher_pid = session.launcher.?.id.?;

    const slave_name = ptsname(session.master_fd.?) orelse return error.PtyUnavailable;
    const slave = try std.posix.openatZ(std.posix.AT.FDCWD, slave_name, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
    var slave_owned = true;
    defer if (slave_owned) closeFd(slave);
    var external = try std.process.spawn(zio, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdin = .ignore,
        .stdout = .{ .file = .{ .handle = slave, .flags = .{ .nonblocking = false } } },
        .stderr = .ignore,
    });
    defer if (external.id != null) external.kill(zio);
    closeFd(slave);
    slave_owned = false;
    const external_pid = external.id.?;
    var close: Close = .{ .session = &session, .claim = .{
        .principal = persistence.grant.principal,
        .actor = persistence.grant.actor,
        .generation = persistence.grant.generation,
        .proof = persistence.proof,
    } };
    const thread = try std.Thread.spawn(.{}, Close.run, .{&close});
    const completed_while_retained = if (close.done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(500) } })) |_| true else |_| false;
    const external_survived = std.c.kill(external_pid, @enumFromInt(0)) == 0;
    // Release only the test-owned external process so a failing drain cannot
    // strand the fixture while reporting the regression.
    external.kill(zio);
    thread.join();
    defer if (close.result) |*result| result.deinit(alloc);
    try std.testing.expect(completed_while_retained);
    try std.testing.expect(close.elapsed_ns < 500 * std.time.ns_per_ms);
    try std.testing.expect(external_survived);
    try std.testing.expectEqual(@as(?anyerror, null), close.failure);
    try std.testing.expect(close.result.? == .success);
    try std.testing.expect(session.backend_done.isSet());
    try std.testing.expect(session.output_done.isSet());
    try std.testing.expect(!session.backend_started);
    try std.testing.expect(session.control_thread == null and session.output_thread == null);
    try std.testing.expect(session.launcher == null);
    try std.testing.expectEqual(std.posix.E.SRCH, std.c.errno(std.c.kill(shell_pid, @enumFromInt(0))));
    try std.testing.expectEqual(std.posix.E.SRCH, std.c.errno(std.c.kill(launcher_pid, @enumFromInt(0))));
}

test "recovered session owns the saved workspace scope" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    var persistence = testPersistence("/saved-workspace/cwd");
    persistence.grant.principal.workspace_root = "/saved-workspace";
    persistence.grant.principal.backend = .tmux;
    const durable = try terminal_store.DurableSession.create(&fixture.profile, .{
        .session_id = "terminal-recovered-scope",
        .host_identity = "test-host",
        .shell = "/bin/zsh",
        .cwd = "/saved-workspace/cwd",
        .command = "printf ready",
        .backend = .tmux,
        .dimensions = .{ .rows = 24, .columns = 80 },
        .persistence = persistence,
        .now_ms = 1,
    });
    var session = try Session.initRecovered(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        durable,
    );
    defer session.deinitUnlaunched();

    try std.testing.expectEqualStrings("/saved-workspace", session.workspace_root);
    try std.testing.expectEqualStrings("/saved-workspace/cwd", session.cwd);
}

test "terminal state does not release live work before backend cleanup" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-live-cleanup");
    var probe: WorkProbe = .{};
    var session = try Session.init(
        alloc,
        .{ .context = &probe, .update_fn = WorkProbe.update },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
        null,
    );
    defer session.deinitUnlaunched();

    session.markLive();
    session.lifecycle = .running;
    session.setTerm(.{ .exited = 0 });
    try std.testing.expectEqual(@as(isize, 1), probe.live);
    try std.testing.expect(!session.isRecyclable());

    session.markNotLive();
    try std.testing.expectEqual(@as(isize, 0), probe.live);
    try std.testing.expect(session.isRecyclable());
    session.markNotLive();
    try std.testing.expectEqual(@as(usize, 2), probe.updates);
}

test "durable journal preserves startup matches" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-retention");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .command = "printf ready",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .return_when = .{ .match = "ready" },
        },
        testPersistence("/workspace"),
        null,
    );
    defer session.deinitUnlaunched();

    session.command_start_cursor = .{ .segment = 1, .offset = 0 };
    session.lifecycle = .running;
    session.appendOutput("ready");
    const noise: [64]u8 = @splat('x');
    session.appendOutput(&noise);
    try std.testing.expectEqual(@as(u64, 1), session.durable.record.output_cursor.segment);
    try std.testing.expect(session.startup_match_seen);
    try std.testing.expectEqual(
        contracts.ReturnOutcome.condition_met,
        (try session.matchConditionLocked(.{ .match = "ready" }, io_mod.milliTimestamp())).?,
    );
}

test "command start match ignores profile output before its cursor" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-command-boundary");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .command = "printf boundary-match",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .return_when = .{ .match = "boundary-match" },
        },
        testPersistence("/workspace"),
        null,
    );
    defer session.deinitUnlaunched();

    session.appendOutput("profile boundary-match\n");
    try std.testing.expect(!session.startup_match_seen);
    try std.testing.expect((try session.matchConditionLocked(
        .{ .match = "boundary-match" },
        io_mod.milliTimestamp(),
    )) == null);

    session.command_start_cursor = session.durable.record.output_cursor;
    session.last_output_ms = io_mod.milliTimestamp();
    session.lifecycle = .running;
    session.appendOutput("target boundary-match\n");
    try std.testing.expect(session.startup_match_seen);
    try std.testing.expectEqual(
        contracts.ReturnOutcome.condition_met,
        (try session.matchConditionLocked(
            .{ .match = "boundary-match" },
            io_mod.milliTimestamp(),
        )).?,
    );
}

test "split partial bytes remain opaque and ordered" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-partial-bytes");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
        null,
    );
    defer session.deinitUnlaunched();

    session.appendOutput(&.{ 0xf0, 0x9f });
    session.appendOutput(&.{0x92});
    session.appendOutput(&.{ 0xa9, 0x00, 0xff });
    var page = try session.durable.read(
        alloc,
        .{ .segment = 1, .offset = 0 },
        16,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xf0, 0x9f, 0x92, 0xa9, 0x00, 0xff },
        page.output,
    );
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 1, .offset = 6 },
        session.durable.record.output_cursor,
    );
}

test "checkpoint plus contiguous observational replay equals live screen" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-screen-replay");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .dimensions = .{ .rows = 4, .columns = 12 },
        },
        testPersistence("/workspace"),
        null,
    );
    defer session.deinitUnlaunched();

    session.appendOutput("hello\x1b[2;");
    const checkpoint_cursor = session.durable.record.output_cursor;
    try session.checkpointLocked(checkpoint_cursor, io_mod.milliTimestamp());
    _ = try session.durable.appendOutput("3H\xe7\x95\x8c\x1b[6n", io_mod.milliTimestamp(), null);
    var live_result = try session.engine.feedMode(
        "3H\xe7\x95\x8c\x1b[6n",
        .native_live,
    );
    defer live_result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), live_result.replies.items.len);
    try std.testing.expectEqual(
        checkpoint_cursor,
        switch (session.durable.record.screen_recovery) {
            .available => |envelope| envelope.applied_cursor,
            .unavailable => return error.TestUnexpectedResult,
        },
    );

    var recovered = try reconstructEngine(alloc, &session.durable);
    defer recovered.deinit();
    const live_payload = try session.engine.checkpointPayload(alloc);
    defer alloc.free(live_payload);
    const recovered_payload = try recovered.checkpointPayload(alloc);
    defer alloc.free(recovered_payload);
    try std.testing.expectEqualSlices(u8, live_payload, recovered_payload);

    const unavailable_from = contracts.RawCursor{
        .segment = checkpoint_cursor.segment,
        .offset = checkpoint_cursor.offset + 1,
    };
    session.durable.record.available_from = unavailable_from;
    session.durable.record.raw_gap = .{
        .missing_from = checkpoint_cursor,
        .available_from = unavailable_from,
    };
    session.durable.record.journal_files[0].range.start = unavailable_from;
    session.durable.record.journal_files[0].payload_bytes =
        session.durable.record.output_cursor.offset - unavailable_from.offset;
    session.durable.record.journal_payload_bytes =
        session.durable.record.journal_files[0].payload_bytes;
    try std.testing.expectError(
        error.ScreenRawGap,
        reconstructEngine(alloc, &session.durable),
    );
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .raw_gap },
        session.durable.facts().screen_recovery,
    );
}

test "many small output chunks checkpoint only at store boundaries" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-checkpoint-boundary");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
        null,
    );
    defer session.deinitUnlaunched();
    var sink = try std.Io.Dir.openFileAbsolute(
        std.testing.io,
        "/dev/null",
        .{ .mode = .write_only },
    );
    defer sink.close(std.testing.io);
    session.master_fd = sink.handle;

    for (0..64) |_| session.appendOutput("x");
    try std.testing.expectEqual(
        @as(u64, 0),
        session.durable.record.checkpoint_generation,
    );

    const block: [256 * 1024]u8 = @splat('y');
    for (0..4) |_| session.appendOutput(&block);
    try std.testing.expectEqual(
        @as(u64, 1),
        session.durable.record.checkpoint_generation,
    );
    try std.testing.expectEqual(
        session.durable.record.output_cursor,
        switch (session.durable.record.screen_recovery) {
            .available => |checkpoint| checkpoint.applied_cursor,
            .unavailable => return error.TestUnexpectedResult,
        },
    );

    for (0..64) |_| session.appendOutput("z");
    try std.testing.expectEqual(
        @as(u64, 1),
        session.durable.record.checkpoint_generation,
    );
}

test "historical screen remains readable after backend detachment" {
    if (comptime !isSupported()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    fixture.profile.process_provider = @import("../../tools/shell/process_provider.zig").provider;
    const persistence = testPersistence(fixture.home);
    const id = try alloc.dupe(u8, "terminal-detached-screen");
    var session = Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", id, .{ .cwd = fixture.home }, persistence, null) catch |err| {
        alloc.free(id);
        return err;
    };
    defer session.deinitUnlaunched();
    _ = try session.durable.appendOutput("SAVED_SCREEN", 2, null);
    try session.engine.feed("SAVED_SCREEN");
    session.backend_detaching.store(true, .release);
    const before = try session.durable.state.?.stat(.terminal_state, "record-terminal-detached-screen.json");
    var cancelled = std.atomic.Value(bool).init(false);
    var result = try screenAction(&session, .{ .session_id = session.id, .authority = .{ .principal = persistence.grant.principal, .actor = .agent, .generation = persistence.grant.generation, .proof = persistence.proof } }, &cancelled);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("S", result.view().success.screen.snapshot.cells[0].text);
    try std.testing.expectEqualStrings("N", result.view().success.screen.snapshot.cells[11].text);
    try std.testing.expectEqual(before, try session.durable.state.?.stat(.terminal_state, "record-terminal-detached-screen.json"));
}

test "resize rollback stops after waiting on the profile writer begins" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Rollback = struct {
        session: *Session,
        payload: []const u8,
        done: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            restoreDurableResize(self.session, self.session.dimensions, self.payload);
            self.done.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const request: contracts.StartRequest = .{ .cwd = fixture.home };
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", try alloc.dupe(u8, "terminal-rollback-cancel"), request, testPersistence(fixture.home), null);
    defer session.deinit();
    try session.engine.feed("saved resize content");
    const payload = try session.engine.checkpointPayload(alloc);
    defer alloc.free(payload);
    const before = try session.durable.state.?.stat(.terminal_state, "record-terminal-rollback-cancel.json");
    fixture.profile.mutex.lockUncancelable(zio);
    var held = true;
    defer if (held) fixture.profile.mutex.unlock(zio);
    var rollback = Rollback{ .session = &session, .payload = payload };
    const thread = try std.Thread.spawn(.{}, Rollback.run, .{&rollback});
    var waiting = false;
    const deadline = io_mod.milliTimestamp() + 5000;
    while (!waiting and io_mod.milliTimestamp() < deadline) {
        if (session.mutex.tryLock()) {
            session.mutex.unlock(zio);
            io_mod.sleep(wait_poll_ns);
        } else waiting = true;
    }
    const started = io_mod.nanoTimestamp();
    session.backend_detaching.store(true, .release);
    const stopped_while_held = if (rollback.done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(500) } })) |_| true else |_| false;
    const elapsed = io_mod.nanoTimestamp() - started;
    fixture.profile.mutex.unlock(zio);
    held = false;
    thread.join();
    try std.testing.expect(waiting);
    try std.testing.expect(stopped_while_held);
    try std.testing.expect(elapsed < 500 * std.time.ns_per_ms);
    try std.testing.expectEqual(before, try session.durable.state.?.stat(.terminal_state, "record-terminal-rollback-cancel.json"));
    const after = try session.engine.checkpointPayload(alloc);
    defer alloc.free(after);
    try std.testing.expectEqualSlices(u8, payload, after);
}

test "owner shutdown cancels resize already waiting on the profile writer" {
    if (comptime !isSupported() or builtin.single_threaded) return error.SkipZigTest;
    const Resize = struct {
        session: *Session,
        request: contracts.ResizeRequest,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            var result = resizeAction(self.session, self.request) catch |err| {
                self.failure = err;
                return;
            };
            result.deinit(self.session.alloc);
        }
    };
    const Stop = struct {
        session: *Session,
        done: std.Io.Event = .unset,
        elapsed_ns: i128 = 0,
        fn run(self: *@This()) void {
            const started = io_mod.nanoTimestamp();
            self.session.shutdown();
            self.session.finalizeBackend();
            self.elapsed_ns = io_mod.nanoTimestamp() - started;
            self.done.set(io_mod.getIo());
        }
    };
    const alloc = std.testing.allocator;
    const zio = io_mod.getIo();
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    fixture.profile.process_provider = @import("../../tools/shell/process_provider.zig").provider;
    const persistence = testPersistence(fixture.home);
    const request: contracts.StartRequest = .{ .cwd = fixture.home, .command = "printf 'RESIZE_READY\\n'; sleep 30", .shell = .{ .executable = .{ .path = if (builtin.os.tag == .macos) "/bin/zsh" else "/bin/bash", .clean_start = true } } };
    var session = try Session.init(alloc, .{ .context = null, .update_fn = ignoreWorkUpdate }, &fixture.profile, "test-host", try alloc.dupe(u8, "terminal-resize-cancel"), request, persistence, null);
    defer session.deinit();
    session.markLive();
    var cancelled: std.atomic.Value(bool) = .init(false);
    try session.launchNative(request, &cancelled);
    try std.testing.expectEqual(contracts.ReturnOutcome.condition_met, try session.waitFor(.{ .match = "RESIZE_READY" }, 5000, &cancelled));
    session.write_mutex.lockUncancelable(zio);
    session.write_mutex.unlock(zio);
    const before = try session.durable.state.?.stat(.terminal_state, "record-terminal-resize-cancel.json");
    const dimensions = session.dimensions;
    fixture.profile.mutex.lockUncancelable(zio);
    var held = true;
    defer if (held) fixture.profile.mutex.unlock(zio);
    var resize = Resize{ .session = &session, .request = .{ .session_id = session.id, .dimensions = .{ .columns = 40, .rows = 12 }, .authority = .{ .principal = persistence.grant.principal, .actor = persistence.grant.actor, .generation = persistence.grant.generation, .proof = persistence.proof } } };
    const resize_thread = try std.Thread.spawn(.{}, Resize.run, .{&resize});
    var resize_began = false;
    const deadline = io_mod.milliTimestamp() + 5000;
    while (!resize_began and io_mod.milliTimestamp() < deadline) {
        if (session.write_mutex.tryLock()) {
            session.write_mutex.unlock(zio);
            io_mod.sleep(wait_poll_ns);
        } else resize_began = true;
    }
    var stop = Stop{ .session = &session };
    const stop_thread = try std.Thread.spawn(.{}, Stop.run, .{&stop});
    const stopped_while_held = if (stop.done.waitTimeout(zio, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(500) } })) |_| true else |_| false;
    fixture.profile.mutex.unlock(zio);
    held = false;
    resize_thread.join();
    stop_thread.join();
    try std.testing.expect(resize_began);
    try std.testing.expect(stopped_while_held);
    try std.testing.expect(stop.elapsed_ns < 500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(?anyerror, error.Cancelled), resize.failure);
    try std.testing.expectEqual(dimensions, session.dimensions);
    try std.testing.expectEqual(before, try session.durable.state.?.stat(.terminal_state, "record-terminal-resize-cancel.json"));
    try std.testing.expect(session.output_done.isSet() and session.backend_done.isSet());
}

test "resize recovery never reflows raw output at final dimensions" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-resize-recovery");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .dimensions = .{ .rows = 2, .columns = 4 },
        },
        testPersistence("/workspace"),
        null,
    );
    var session_owned = true;
    defer if (session_owned) session.deinitUnlaunched();

    _ = try session.durable.appendOutput("abcdef", 2, null);
    var feed = try session.engine.feedMode("abcdef", .native_live);
    feed.deinit(alloc);
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try session.engine.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("abcd", row.items);
    row.clearRetainingCapacity();
    try session.engine.rowTextTrimmed(2, &row);
    try std.testing.expectEqualStrings("ef", row.items);

    const resized = contracts.Dimensions{ .rows = 2, .columns = 6 };
    try session.engine.resize(resized.columns, resized.rows);
    try session.durable.resize(resized, 3);
    session.dimensions = resized;
    try session.checkpointLocked(session.durable.output_cursor(), 4);

    var recovered = try reconstructEngine(alloc, &session.durable);
    defer recovered.deinit();
    const live_payload = try session.engine.checkpointPayload(alloc);
    defer alloc.free(live_payload);
    const recovered_payload = try recovered.checkpointPayload(alloc);
    defer alloc.free(recovered_payload);
    try std.testing.expectEqualSlices(u8, live_payload, recovered_payload);

    var raw_at_final_size = try terminal_engine.Grid.init(
        alloc,
        resized.columns,
        resized.rows,
    );
    defer raw_at_final_size.deinit();
    var raw_feed = try raw_at_final_size.feedMode("abcdef", .journal_replay);
    raw_feed.deinit(alloc);
    row.clearRetainingCapacity();
    try raw_at_final_size.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("abcdef", row.items);
    row.clearRetainingCapacity();
    try session.engine.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("abcd", row.items);

    try session.durable.storeCheckpoint(.{
        .engine_schema_revision = terminal_engine.checkpoint_schema_revision + 1,
        .applied_cursor = session.durable.output_cursor(),
        .payload_len = @intCast(live_payload.len),
        .checksum = contracts.checkpoint_checksum(live_payload),
    }, live_payload, 5, null);
    try std.testing.expect(!session.durable.record.raw_replay_exact);
    try std.testing.expectError(
        error.ScreenUnsupported,
        reconstructEngine(alloc, &session.durable),
    );
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .unsupported_schema },
        session.durable.facts().screen_recovery,
    );

    session.deinitUnlaunched();
    session_owned = false;
    const reopened = try fixture.profile.open_terminal(
        "terminal-resize-recovery",
    );
    defer fixture.profile.release_terminal(reopened);
    try std.testing.expectEqual(resized, reopened.record.dimensions);
    try std.testing.expect(!reopened.record.raw_replay_exact);
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .unsupported_schema },
        reopened.facts().screen_recovery,
    );
}

test "native protocol replies are independent of either durable write lease" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-reply-leases");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
        null,
    );
    defer session.deinitUnlaunched();

    for ([_]contracts.AttentionState{
        .{ .attention = .agent_wait, .write_lease = .agent },
        .{ .attention = .user_takeover, .write_lease = .human },
    }) |attention| {
        session.durable.record.attention = attention;
        var result = try session.engine.feedMode("\x1b[5n", .native_live);
        defer result.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), result.replies.items.len);
        try std.testing.expectEqualStrings("\x1b[0n", result.replies.items[0].bytes);
    }
}

test "missing corrupt and unsupported checkpoints fall back only with full raw continuity" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-screen-fallback");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .dimensions = .{ .rows = 3, .columns = 10 },
        },
        testPersistence("/workspace"),
        null,
    );
    defer session.deinitUnlaunched();
    session.appendOutput("fallback");

    const original_recovery = session.durable.record.screen_recovery;
    inline for (.{
        contracts.ScreenUnavailableReason.missing,
        .corrupt,
        .unsupported_schema,
    }) |reason| {
        session.durable.record.screen_recovery = .{ .unavailable = reason };
        var recovered = try reconstructEngine(alloc, &session.durable);
        defer recovered.deinit();
        try std.testing.expectEqual(@as(u21, 'f'), recovered.cellAt(1, 1).?.codepoint);
        try std.testing.expectEqual(
            contracts.ScreenRecovery{ .unavailable = reason },
            session.durable.facts().screen_recovery,
        );
    }

    session.durable.record.screen_recovery = .{ .unavailable = .corrupt };
    session.durable.record.available_from.offset = 1;
    session.durable.record.raw_gap = .{
        .missing_from = .{ .segment = 1, .offset = 0 },
        .available_from = .{ .segment = 1, .offset = 1 },
    };
    session.durable.record.journal_files[0].range.start.offset = 1;
    session.durable.record.journal_files[0].payload_bytes -= 1;
    session.durable.record.journal_payload_bytes -= 1;
    try std.testing.expectError(
        error.ScreenRawGap,
        reconstructEngine(alloc, &session.durable),
    );
    session.durable.record.available_from.offset = 0;
    session.durable.record.raw_gap = null;
    session.durable.record.journal_files[0].range.start.offset = 0;
    session.durable.record.journal_files[0].payload_bytes += 1;
    session.durable.record.journal_payload_bytes += 1;
    session.durable.record.screen_recovery = original_recovery;
}

test "recovery classifiers preserve allocation and transient failures" {
    try std.testing.expectEqual(
        contracts.ScreenUnavailableReason.unsupported_schema,
        engine_checkpoint_unavailable_reason(error.UnsupportedEngineRevision).?,
    );
    try std.testing.expectEqual(
        contracts.ScreenUnavailableReason.corrupt,
        engine_checkpoint_unavailable_reason(error.InvalidEngineCheckpoint).?,
    );
    try std.testing.expect(
        engine_checkpoint_unavailable_reason(error.OutOfMemory) == null,
    );
    try std.testing.expect(replay_feed_error_is_corrupt(
        error.TooManyCsiParameters,
    ));
    try std.testing.expect(!replay_feed_error_is_corrupt(error.OutOfMemory));
}

test "checkpoint load allocation failure preserves durable recovery facts" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-checkpoint-load-oom");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
        null,
    );
    defer session.deinitUnlaunched();

    session.appendOutput("checkpoint");
    try session.checkpointLocked(
        session.durable.output_cursor(),
        io_mod.milliTimestamp(),
    );
    const recovery = session.durable.record.screen_recovery;
    const generation = session.durable.record.checkpoint_generation;
    const checkpoint_bytes = session.durable.record.checkpoint_payload_bytes;
    const cleanup_generation = session.durable.record.checkpoint_cleanup_generation;

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        reconstructEngine(failing.allocator(), &session.durable),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(recovery, session.durable.record.screen_recovery);
    try std.testing.expectEqual(generation, session.durable.record.checkpoint_generation);
    try std.testing.expectEqual(
        checkpoint_bytes,
        session.durable.record.checkpoint_payload_bytes,
    );
    try std.testing.expectEqual(
        cleanup_generation,
        session.durable.record.checkpoint_cleanup_generation,
    );

    var retained = (try session.durable.load_checkpoint(alloc)).?;
    defer retained.deinit(alloc);
    try std.testing.expectEqual(generation, session.durable.record.checkpoint_generation);
}

test "journal engine feed allocation failure preserves durable recovery facts" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-replay-feed-oom");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
        null,
    );
    defer session.deinitUnlaunched();

    session.appendOutput("base");
    try session.checkpointLocked(
        session.durable.output_cursor(),
        io_mod.milliTimestamp(),
    );
    _ = try session.durable.appendOutput(
        "\x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\",
        io_mod.milliTimestamp(),
        null,
    );
    const recovery = session.durable.record.screen_recovery;
    const generation = session.durable.record.checkpoint_generation;
    const checkpoint_bytes = session.durable.record.checkpoint_payload_bytes;
    const cleanup_generation = session.durable.record.checkpoint_cleanup_generation;

    var probe = std.testing.FailingAllocator.init(alloc, .{});
    var recovered = try reconstructEngine(probe.allocator(), &session.durable);
    recovered.deinit();
    try std.testing.expect(probe.alloc_index > 0);
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = probe.alloc_index - 1 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        reconstructEngine(failing.allocator(), &session.durable),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try std.testing.expectEqual(recovery, session.durable.record.screen_recovery);
    try std.testing.expectEqual(generation, session.durable.record.checkpoint_generation);
    try std.testing.expectEqual(
        checkpoint_bytes,
        session.durable.record.checkpoint_payload_bytes,
    );
    try std.testing.expectEqual(
        cleanup_generation,
        session.durable.record.checkpoint_cleanup_generation,
    );
}

test "malformed raw fallback durably replaces an invalid checkpoint with corrupt" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-malformed-raw-recovery");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
        null,
    );
    var session_owned = true;
    defer if (session_owned) session.deinitUnlaunched();

    const malformed = "\x1b[1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1H";
    _ = try session.durable.appendOutput(malformed, io_mod.milliTimestamp(), null);
    const invalid_payload = "invalid-engine-checkpoint";
    try session.durable.storeCheckpoint(.{
        .engine_schema_revision = terminal_engine.checkpoint_schema_revision,
        .applied_cursor = session.durable.output_cursor(),
        .payload_len = invalid_payload.len,
        .checksum = contracts.checkpoint_checksum(invalid_payload),
    }, invalid_payload, io_mod.milliTimestamp(), null);

    try std.testing.expectError(
        error.ScreenCorrupt,
        reconstructEngine(alloc, &session.durable),
    );
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .corrupt },
        session.durable.facts().screen_recovery,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        session.durable.record.checkpoint_generation,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        session.durable.record.checkpoint_payload_bytes,
    );
    try std.testing.expect(
        session.durable.record.checkpoint_cleanup_generation == null,
    );

    session.deinitUnlaunched();
    session_owned = false;
    const reopened = try fixture.profile.open_terminal(
        "terminal-malformed-raw-recovery",
    );
    defer fixture.profile.release_terminal(reopened);
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .corrupt },
        reopened.facts().screen_recovery,
    );
}

test "shutdownSessionsOnly signals live sessions and leaves them allocated" {
    if (!isSupported()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-shutdown-only");
    var probe: WorkProbe = .{};
    var session = try Session.init(
        alloc,
        .{ .context = &probe, .update_fn = WorkProbe.update },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
        null,
    );
    defer session.deinitUnlaunched();

    session.markLive();
    session.lifecycle = .running;
    // A real handle, so releasing it is observable rather than vacuous.
    session.liveness_file = try std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        "/dev/null",
        .{ .truncate = false },
    );

    var registry = SupportedRegistry{
        .alloc = alloc,
        .tracker = .{ .context = &probe, .update_fn = WorkProbe.update },
        .profile = &fixture.profile,
        .host_identity = "test-host",
        .durable_root = "/workspace",
        .transport_root = "/workspace",
    };
    registry.slots[0] = .{ .resident = .{ .session = &session, .references = 0 } };

    // A slot with no outstanding reference is exactly the slot a client may
    // recycle, so this is the case the pin has to cover.
    try std.testing.expectEqual(@as(usize, 0), registry.slots[0].resident.references);

    registry.shutdownSessionsOnly();

    // Every reference taken to pin the session for shutdown is given back, so
    // the drain cannot wedge a later removeOwned that waits for the count.
    try std.testing.expectEqual(@as(usize, 0), registry.slots[0].resident.references);

    // The liveness handle is released, so the session was actually shut down.
    try std.testing.expect(session.liveness_file == null);
    // And the session is still allocated: the registry slot still points at it
    // and the object is readable, which is what makes this safe to call while
    // client threads still hold session pointers.
    try std.testing.expect(registry.slots[0].resident.session == &session);
    try std.testing.expectEqual(contracts.Lifecycle.running, session.lifecycle);
}

test "durable release and exit wait survive resident session removal" {
    if (!isSupported()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const persistence = testPersistence("/workspace");
    const authority = contracts.AuthorityClaim{
        .principal = persistence.grant.principal,
        .actor = persistence.grant.actor,
        .generation = persistence.grant.generation,
        .proof = persistence.proof,
    };
    var durable = try terminal_store.DurableSession.create(&fixture.profile, .{
        .session_id = "terminal-durable-fallback",
        .host_identity = "test-host",
        .shell = "/bin/zsh",
        .cwd = "/workspace",
        .command = null,
        .backend = .native,
        .dimensions = .{ .rows = 24, .columns = 80 },
        .persistence = persistence,
        .now_ms = 1,
    });
    var durable_owned = true;
    defer if (durable_owned) durable.deinit();
    try durable.persistTermination(.{ .exited = 17 }, 2, null);
    _ = try durable.acquire_write_lease(authority, 3);
    durable.deinit();
    durable_owned = false;

    var probe: WorkProbe = .{};
    var registry = SupportedRegistry{
        .alloc = alloc,
        .tracker = .{ .context = &probe, .update_fn = WorkProbe.update },
        .profile = &fixture.profile,
        .host_identity = "test-host",
        .durable_root = "/workspace",
        .transport_root = "/workspace",
    };
    var cancelled = std.atomic.Value(bool).init(false);
    var released = try registry.write(.{
        .session_id = "terminal-durable-fallback",
        .lease = .release,
        .authority = authority,
    }, &cancelled);
    defer released.deinit(alloc);
    switch (released.view()) {
        .success => |success| switch (success) {
            .write => |write| {
                try std.testing.expectEqual(@as(u32, 0), write.accepted_bytes);
                try std.testing.expectEqual(
                    contracts.WriteLease.none,
                    write.session.attention.write_lease,
                );
                try std.testing.expectEqual(
                    contracts.Lifecycle.exited,
                    write.session.lifecycle,
                );
            },
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    }

    var waited = try registry.wait(.{
        .session_id = "terminal-durable-fallback",
        .return_when = .exit,
        .safety_ceiling_ms = 1_000,
        .authority = authority,
    }, &cancelled);
    defer waited.deinit(alloc);
    switch (waited.view()) {
        .success => |success| switch (success) {
            .wait => |wait| try std.testing.expectEqual(
                contracts.ReturnOutcome{ .exited = 17 },
                wait.outcome,
            ),
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    }
}

test "a referenced slot is never recycled out from under its holder" {
    if (!isSupported()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-recycle-guard");
    var probe: WorkProbe = .{};
    var resident = try Session.init(
        alloc,
        .{ .context = &probe, .update_fn = WorkProbe.update },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
        null,
    );
    defer resident.deinitUnlaunched();
    resident.lifecycle = .exited;
    try fixture.profile.register_resident(&resident.durable, null);
    try std.testing.expect(resident.isRecyclable());

    const incoming_id = try alloc.dupe(u8, "terminal-recycle-incoming");
    var incoming = try Session.init(
        alloc,
        .{ .context = &probe, .update_fn = WorkProbe.update },
        &fixture.profile,
        "test-host",
        incoming_id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
        null,
    );
    defer incoming.deinitUnlaunched();

    var registry = SupportedRegistry{
        .alloc = alloc,
        .tracker = .{ .context = &probe, .update_fn = WorkProbe.update },
        .profile = &fixture.profile,
        .host_identity = "test-host",
        .durable_root = "/workspace",
        .transport_root = "/workspace",
        .slots = @splat(.{ .resident = .{ .session = &resident, .references = 1 } }),
    };

    // Every slot holds a recyclable session, so only the reference keeps them.
    // This is what makes it safe to signal a session after releasing the lock.
    try std.testing.expect(registry.reserve(&incoming) == null);

    // Drop the references and the same slots become recyclable again, so the
    // check above is about the reference and not about some other refusal.
    for (&registry.slots) |*slot| slot.resident.references = 0;
    fixture.profile.mutex.lockUncancelable(io_mod.getIo());
    var profile_held = true;
    defer if (profile_held) fixture.profile.mutex.unlock(io_mod.getIo());
    try std.testing.expect(registry.reserve(&incoming) == null);
    try std.testing.expect(resident.durable.registered);
    try std.testing.expectEqual(&resident.durable, fixture.profile.residents.items[0]);
    fixture.profile.mutex.unlock(io_mod.getIo());
    profile_held = false;
    const reservation = registry.reserve(&incoming) orelse
        return error.TestExpectedRecycle;
    try std.testing.expectEqual(@as(?*Session, &resident), reservation.evicted);
    try std.testing.expect(!resident.durable.registered);
    try std.testing.expectEqual(@as(usize, 0), fixture.profile.residents.items.len);
}
