const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("host.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("../auth/secret.zig");
const process_owner = @import("../execution/process_owner.zig");

pub const service_name = "FX_AI_GATEWAY_API_KEY";
const mcp_credentials_service_name = "FX_MCP_OAUTH_CREDENTIALS_V1";
pub const oauth_session_service_name = "FX_OAUTH_SESSION_V1";

/// Backing store for a resolved account name. Must outlive any argv built from it.
pub const AccountBuffer = [256]u8;

const passwd_scratch_bytes = 2048;
const max_mcp_credentials_bytes: usize = 1024 * 1024;
const max_oauth_session_bytes: usize = 64 * 1024;

pub const Error = error{
    Cancelled,
    UnsupportedPlatform,
    UserNotSet,
    KeychainItemNotFound,
    KeychainReadFailed,
    KeychainWriteFailed,
    KeychainDeleteFailed,
};

pub fn isAvailable() bool {
    return builtin.os.tag == .macos;
}

pub fn isDisabled() bool {
    const value = io_mod.getenv("FX_DISABLE_KEYCHAIN") orelse return false;
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

pub fn userDefaultKeychainAvailable(alloc: std.mem.Allocator) Error!bool {
    return userDefaultKeychainAvailableControlled(alloc, null);
}

pub fn userDefaultKeychainAvailableCancellable(
    alloc: std.mem.Allocator,
    cancel_flag: *const std.atomic.Value(bool),
) Error!bool {
    return userDefaultKeychainAvailableControlled(alloc, cancel_flag);
}

fn userDefaultKeychainAvailableControlled(
    alloc: std.mem.Allocator,
    cancel_flag: ?*const std.atomic.Value(bool),
) Error!bool {
    if (!isAvailable()) return false;
    return userDefaultKeychainAvailableForCommand(
        alloc,
        &.{ "/usr/bin/security", "default-keychain", "-d", "user" },
        cancel_flag,
    );
}

fn userDefaultKeychainAvailableForCommand(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) Error!bool {
    const result = runMcpKeychainProcess(
        alloc,
        argv,
        cancel_flag,
        .limited(4096),
    ) catch |err| {
        if (err == error.Canceled or err == error.Cancelled) return keychainFailure(err, error.KeychainReadFailed);
        debug_trace.logf("keychain", "availability failed step=spawn err={s}", .{@errorName(err)});
        return error.KeychainReadFailed;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code == 0) return true;
            debug_trace.logf("keychain", "availability unavailable exit_code={d}", .{code});
            return false;
        },
        else => {},
    }
    debug_trace.logf("keychain", "availability failed step=default term={t}", .{result.term});
    return error.KeychainReadFailed;
}

/// Returns a slice borrowing `buf`. `USER` stays authoritative when set, because it
/// is the only way to target a non-login account. ACP clients launched by GUI editors
/// inherit a thinner environment than a shell, so the operating system supplies the
/// account when `USER` is absent instead of failing the read.
fn accountName(buf: *AccountBuffer) Error![]const u8 {
    if (io_mod.getenv("USER")) |user| {
        if (user.len > 0 and user.len <= buf.len) {
            @memcpy(buf[0..user.len], user);
            return buf[0..user.len];
        }
    }
    if (osAccountName(buf)) |name| {
        debug_trace.logf("keychain", "account resolved from os; step=env unavailable", .{});
        return name;
    }
    debug_trace.logf("keychain", "account failed step=resolve err=UserNotSet", .{});
    return error.UserNotSet;
}

fn osAccountName(buf: *AccountBuffer) ?[]const u8 {
    if (comptime builtin.os.tag == .macos) return posixAccountName(buf);
    return null;
}

fn posixAccountName(buf: *AccountBuffer) ?[]const u8 {
    var entry: std.c.passwd = undefined;
    var scratch: [passwd_scratch_bytes]u8 = undefined;
    var found: ?*std.c.passwd = null;
    if (std.c.getpwuid_r(std.c.getuid(), &entry, &scratch, scratch.len, &found) != 0) return null;

    const record = found orelse return null;
    const name_ptr = record.name orelse return null;
    const name = std.mem.span(name_ptr);
    if (name.len == 0 or name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

pub fn load(alloc: std.mem.Allocator) !?[]u8 {
    return loadFromService(alloc, service_name);
}

/// Checks Keychain metadata only. It never asks Security.framework for the
/// secret value and never spawns the `security` command-line tool.
pub fn contains() Error!host.SecretStorePresence {
    return containsService(service_name);
}

pub fn oauthSessionPresence() Error!host.SecretStorePresence {
    return containsService(oauth_session_service_name);
}

fn containsService(service: []const u8) Error!host.SecretStorePresence {
    if (comptime builtin.os.tag != .macos) return .missing;
    var account_buf: AccountBuffer = undefined;
    const argv = mcpScriptArgv("presence", try accountName(&account_buf), service);
    const alloc = std.heap.c_allocator;
    const result = runMcpKeychainProcess(alloc, &argv, null, .limited(16)) catch |err|
        return keychainFailure(err, error.KeychainReadFailed);
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.KeychainReadFailed;
    const marker = std.mem.trim(u8, result.stdout, "\r\n");
    if (std.mem.eql(u8, marker, "1")) return .present;
    if (std.mem.eql(u8, marker, "0")) return .missing;
    return error.KeychainReadFailed;
}

pub fn loadMcpCredentials(alloc: std.mem.Allocator) !?[]u8 {
    return loadValueMacControlled(alloc, mcp_credentials_service_name, null, max_mcp_credentials_bytes);
}

pub fn loadOAuthSession(alloc: std.mem.Allocator) !?[]u8 {
    return loadValueMacControlled(alloc, oauth_session_service_name, null, max_mcp_credentials_bytes);
}

pub fn loadMcpCredentialsCancellable(
    alloc: std.mem.Allocator,
    cancel_flag: *const std.atomic.Value(bool),
) !?[]u8 {
    return loadValueMacControlled(
        alloc,
        mcp_credentials_service_name,
        cancel_flag,
        max_mcp_credentials_bytes,
    );
}

fn loadFromService(alloc: std.mem.Allocator, service: []const u8) !?[]u8 {
    if (!isAvailable()) return null;
    const bytes = (try loadValueMacControlled(alloc, service, null, 8 * 1024)) orelse return null;
    return trimStoredKey(alloc, bytes);
}

fn trimStoredKey(alloc: std.mem.Allocator, bytes: []u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, bytes, "\r\n");
    if (trimmed.len == 0) {
        secret.zeroAndFree(alloc, bytes);
        return null;
    }
    if (trimmed.len == bytes.len) return bytes;

    errdefer secret.zeroAndFree(alloc, bytes);
    const key = try alloc.dupe(u8, trimmed);
    secret.zeroAndFree(alloc, bytes);
    return key;
}

fn storeArgv(account: []const u8) [8][]const u8 {
    return .{ "/usr/bin/security", "add-generic-password", "-a", account, "-s", service_name, "-U", "-w" };
}

// `security add-generic-password -w` uses a 128-byte interactive buffer. MCP's
// aggregate credential store is larger, so use the native Security API through
// the stable system osascript host. Account and service are non-secret argv;
// credential bytes travel only through stdin/stdout.
const mcp_keychain_script =
    \\ObjC.import("Security");
    \\ObjC.import("Foundation");
    \\const object = (value) => ObjC.castRefToObject(value);
    \\function query(account, service) {
    \\    const value = $.NSMutableDictionary.alloc.init;
    \\    value.setObjectForKey(object($.kSecClassGenericPassword), object($.kSecClass));
    \\    value.setObjectForKey($(account), object($.kSecAttrAccount));
    \\    value.setObjectForKey($(service), object($.kSecAttrService));
    \\    return value;
    \\}
    \\function failed(status) {
    \\    throw new Error("keychain status=" + status);
    \\}
    \\function run(argv) {
    \\    const operation = argv[0];
    \\    const value = query(argv[1], argv[2]);
    \\    if (operation === "presence") {
    \\        value.setObjectForKey(object($.kSecMatchLimitOne), object($.kSecMatchLimit));
    \\        const status = $.SecItemCopyMatching(value, null);
    \\        if (status === 0) return "1";
    \\        if (status === -25300) return "0";
    \\        failed(status);
    \\    }
    \\    if (operation === "load") {
    \\        value.setObjectForKey($.NSNumber.numberWithBool(true), object($.kSecReturnData));
    \\        value.setObjectForKey(object($.kSecMatchLimitOne), object($.kSecMatchLimit));
    \\        const result = Ref();
    \\        const status = $.SecItemCopyMatching(value, result);
    \\        if (status === -25300) return;
    \\        if (status !== 0) failed(status);
    \\        $.NSFileHandle.fileHandleWithStandardOutput.writeData(
    \\            ObjC.castRefToObject(result[0]),
    \\        );
    \\        return;
    \\    }
    \\    if (operation === "store") {
    \\        const secret = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    \\        if (secret.length === 0) failed(-50);
    \\        const update = $.NSMutableDictionary.alloc.init;
    \\        update.setObjectForKey(secret, object($.kSecValueData));
    \\        const updateStatus = $.SecItemUpdate(value, update);
    \\        if (updateStatus === 0) return;
    \\        if (updateStatus !== -25300) failed(updateStatus);
    \\        value.setObjectForKey(secret, object($.kSecValueData));
    \\        const addStatus = $.SecItemAdd(value, null);
    \\        if (addStatus !== 0) failed(addStatus);
    \\        return;
    \\    }
    \\    if (operation === "delete") {
    \\        const status = $.SecItemDelete(value);
    \\        if (status === 0) return "1";
    \\        if (status === -25300) return "0";
    \\        failed(status);
    \\    }
    \\    failed(-50);
    \\}
;

/// The returned argv borrows `account_buf`, which must outlive it.
pub fn storeInteractiveArgv(account_buf: *AccountBuffer) Error![8][]const u8 {
    if (!isAvailable()) return error.UnsupportedPlatform;
    return storeArgv(try accountName(account_buf));
}

pub fn storeInteractive() Error!void {
    if (!isAvailable()) return error.UnsupportedPlatform;

    // Let macOS prompt for the secret; do not put it in argv.
    var account_buf: AccountBuffer = undefined;
    const argv = try storeInteractiveArgv(&account_buf);
    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| return writeFailed("interactive_spawn", err);
    const term = child.wait(io_mod.getIo()) catch |err| return writeFailed("interactive_wait", err);
    if (term != .exited or term.exited != 0) return writeFailedTerm("interactive_exit", term);
}

pub fn storeValue(value: []const u8) Error!void {
    if (!isAvailable()) return error.UnsupportedPlatform;
    if (value.len == 0) return error.KeychainWriteFailed;

    if (comptime builtin.os.tag == .macos) return storeValueMac(service_name, value);
    return error.UnsupportedPlatform;
}

pub fn storeMcpCredentials(value: []const u8) Error!void {
    return storeMcpCredentialsControlled(value, null);
}

pub fn storeOAuthSession(value: []const u8) Error!void {
    if (!isAvailable()) return error.UnsupportedPlatform;
    if (value.len == 0 or value.len > max_oauth_session_bytes) {
        return error.KeychainWriteFailed;
    }
    return storeMcpValueMac(oauth_session_service_name, value);
}

pub fn storeMcpCredentialsCancellable(
    value: []const u8,
    cancel_flag: *const std.atomic.Value(bool),
) Error!void {
    return storeMcpCredentialsControlled(value, cancel_flag);
}

fn storeMcpCredentialsControlled(
    value: []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) Error!void {
    if (!isAvailable()) return error.UnsupportedPlatform;
    if (value.len == 0 or value.len > max_mcp_credentials_bytes) {
        return error.KeychainWriteFailed;
    }

    if (comptime builtin.os.tag == .macos) {
        return storeMcpValueMacControlled(
            mcp_credentials_service_name,
            value,
            cancel_flag,
        );
    }
    return error.UnsupportedPlatform;
}

pub fn deleteMcpCredentials(alloc: std.mem.Allocator) Error!bool {
    return deleteMcpValueMac(alloc, mcp_credentials_service_name);
}

pub fn deleteOAuthSession(alloc: std.mem.Allocator) Error!bool {
    return deleteMcpValueMac(alloc, oauth_session_service_name);
}

fn writeFailed(step: []const u8, err: anyerror) Error {
    if (err == error.Canceled or err == error.Cancelled) return keychainFailure(err, error.KeychainWriteFailed);
    debug_trace.logf("keychain", "store failed step={s} err={s}", .{ step, @errorName(err) });
    return error.KeychainWriteFailed;
}

fn keychainFailure(err: anyerror, fallback: Error) Error {
    if (err == error.Canceled) {
        io_mod.getIo().recancel();
        return error.Cancelled;
    }
    return if (err == error.Cancelled) error.Cancelled else fallback;
}

fn writeFailedTerm(step: []const u8, term: std.process.Child.Term) Error {
    debug_trace.logf("keychain", "store failed step={s} term={t}", .{ step, term });
    return error.KeychainWriteFailed;
}

fn storeValueMac(service: []const u8, value: []const u8) Error!void {
    return storeMcpValueMacControlled(service, value, null);
}

fn mcpScriptArgv(
    operation: []const u8,
    account: []const u8,
    service: []const u8,
) [8][]const u8 {
    return .{
        "/usr/bin/osascript",
        "-l",
        "JavaScript",
        "-e",
        mcp_keychain_script,
        operation,
        account,
        service,
    };
}

fn loadMcpValueMac(
    alloc: std.mem.Allocator,
    service: []const u8,
) Error!?[]u8 {
    return loadValueMacControlled(alloc, service, null, max_mcp_credentials_bytes);
}

fn loadValueMacControlled(
    alloc: std.mem.Allocator,
    service: []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
    max_bytes: usize,
) Error!?[]u8 {
    if (!isAvailable()) return error.UnsupportedPlatform;

    var account_buf: AccountBuffer = undefined;
    const account = try accountName(&account_buf);
    const argv = mcpScriptArgv("load", account, service);
    const result = runMcpKeychainProcess(
        alloc,
        &argv,
        cancel_flag,
        .limited(max_bytes + 1),
    ) catch |err| {
        if (err == error.Canceled or err == error.Cancelled) return keychainFailure(err, error.KeychainReadFailed);
        debug_trace.logf("keychain", "load failed step=native err={s}", .{@errorName(err)});
        return error.KeychainReadFailed;
    };
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        secret.zeroAndFree(alloc, result.stdout);
        debug_trace.logf("keychain", "load failed step=native term={t}", .{result.term});
        return error.KeychainReadFailed;
    }
    if (result.stdout.len == 0) {
        alloc.free(result.stdout);
        return error.KeychainItemNotFound;
    }
    if (result.stdout.len > max_bytes) {
        secret.zeroAndFree(alloc, result.stdout);
        return error.KeychainReadFailed;
    }
    return result.stdout;
}

fn runMcpKeychainProcess(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
    stdout_limit: std.Io.Limit,
) anyerror!std.process.RunResult {
    return process_owner.run(alloc, .{
        .argv = argv,
        .stdout_limit = stdout_limit.toInt() orelse max_mcp_credentials_bytes + 1,
        .timeout_ms = 10_000,
        .cancel_flag = cancel_flag,
    });
}

fn storeMcpValueMac(service: []const u8, value: []const u8) Error!void {
    return storeMcpValueMacControlled(service, value, null);
}

fn storeMcpValueMacControlled(
    service: []const u8,
    value: []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) Error!void {
    var account_buf: AccountBuffer = undefined;
    const argv = mcpScriptArgv("store", try accountName(&account_buf), service);
    const alloc = std.heap.c_allocator;
    const result = process_owner.run(alloc, .{
        .argv = &argv,
        .stdin = value,
        .stdout_limit = 16,
        .timeout_ms = 10_000,
        .cancel_flag = cancel_flag,
    }) catch |err| return writeFailed("native_store", err);
    defer secret.zeroAndFree(alloc, result.stdout);
    defer secret.zeroAndFree(alloc, result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return writeFailedTerm("native_exit", result.term);
    }
}

fn deleteMcpValueMac(
    alloc: std.mem.Allocator,
    service: []const u8,
) Error!bool {
    if (!isAvailable()) return error.UnsupportedPlatform;

    var account_buf: AccountBuffer = undefined;
    const account = try accountName(&account_buf);
    const argv = mcpScriptArgv("delete", account, service);
    const result = process_owner.run(alloc, .{
        .argv = &argv,
        .stdout_limit = 16,
        .timeout_ms = 10_000,
    }) catch |err| {
        if (err == error.Canceled or err == error.Cancelled) return keychainFailure(err, error.KeychainDeleteFailed);
        debug_trace.logf("keychain", "delete failed step=native err={s}", .{@errorName(err)});
        return error.KeychainDeleteFailed;
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        debug_trace.logf("keychain", "delete failed step=native term={t}", .{result.term});
        return error.KeychainDeleteFailed;
    }
    const marker = std.mem.trim(u8, result.stdout, "\r\n");
    if (std.mem.eql(u8, marker, "1")) return true;
    if (std.mem.eql(u8, marker, "0")) return false;
    return error.KeychainDeleteFailed;
}

const test_service_name = "FX_TEST_AI_GATEWAY_API_KEY";

test "account name resolves from the operating system when USER is unset" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expect(io_mod.getenv("USER") == null);

    var buf: AccountBuffer = undefined;
    const account = try accountName(&buf);
    try std.testing.expect(account.len > 0);
    try std.testing.expectEqual(@intFromPtr(&buf), @intFromPtr(account.ptr));
}

test "stored key round-trips byte-identically with USER unset" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    if (isDisabled()) return error.SkipZigTest;
    try std.testing.expect(io_mod.getenv("USER") == null);

    const alloc = std.testing.allocator;
    const written = "vt1-round-trip-value";

    storeValueMac(test_service_name, written) catch return error.SkipZigTest;
    defer _ = deleteMcpValueMac(alloc, test_service_name) catch false;

    const read_back = (try loadFromService(alloc, test_service_name)) orelse
        return error.KeychainItemNotFound;
    defer secret.zeroAndFree(alloc, read_back);
    try std.testing.expectEqualStrings(written, read_back);
    try std.testing.expect(try deleteMcpValueMac(alloc, test_service_name));
    try std.testing.expect(!try deleteMcpValueMac(alloc, test_service_name));
    try std.testing.expectError(
        error.KeychainItemNotFound,
        loadFromService(alloc, test_service_name),
    );
    try std.testing.expectEqual(host.SecretStorePresence.missing, try containsService(test_service_name));
}

test "MCP Keychain storage round-trips values beyond the security prompt limit" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    if (isDisabled()) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const test_mcp_service = "FX_TEST_MCP_OAUTH_CREDENTIALS_V1";
    const written = "mcp-credential-section-" ** 32;

    storeMcpValueMac(test_mcp_service, written) catch return error.SkipZigTest;
    defer _ = deleteMcpValueMac(alloc, test_mcp_service) catch false;

    const read_back = (try loadMcpValueMac(alloc, test_mcp_service)) orelse
        return error.KeychainItemNotFound;
    defer secret.zeroAndFree(alloc, read_back);
    try std.testing.expectEqualStrings(written, read_back);
    try std.testing.expect(try deleteMcpValueMac(alloc, test_mcp_service));
    try std.testing.expectError(
        error.KeychainItemNotFound,
        loadMcpValueMac(alloc, test_mcp_service),
    );
}

test "Keychain store command has no secret argument" {
    const argv = storeArgv("user");
    try std.testing.expectEqualStrings("-w", argv[argv.len - 1]);
    for (argv) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "vca_secret_value"));
    }
}

test "stored key normalization retains its ownership on allocation failure" {
    const Probe = struct {
        fn run(alloc: std.mem.Allocator) !void {
            const raw = try alloc.dupe(u8, "\r\ncredential-value\r\n");
            const value = (try trimStoredKey(alloc, raw)) orelse return error.TestMissingKey;
            defer secret.zeroAndFree(alloc, value);
            try std.testing.expectEqualStrings("credential-value", value);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "Keychain presence operation does not request credential bytes" {
    const branch = std.mem.find(u8, mcp_keychain_script, "operation === \"presence\"");
    try std.testing.expect(branch != null);
    const end = std.mem.findPos(u8, mcp_keychain_script, branch.?, "operation === \"load\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.find(u8, mcp_keychain_script[branch.?..end], "kSecReturnData") == null);
    try std.testing.expect(std.mem.find(u8, mcp_keychain_script[branch.?..end], "SecItemCopyMatching") != null);
}

test "cancellable MCP Keychain runner interrupts and reaps a stalled child" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const Canceller = struct {
        flag: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            io_mod.sleep(25 * std.time.ns_per_ms);
            self.flag.store(true, .release);
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var canceller = Canceller{ .flag = &cancel };
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});
    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.Cancelled,
        runMcpKeychainProcess(
            std.testing.allocator,
            &.{ "/bin/sh", "-c", "exec sleep 60" },
            &cancel,
            .limited(16),
        ),
    );
    thread.join();
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1_000);
}

test "Keychain task cancellation force terminates and reaps after child readiness" {
    try testKeychainTaskCancellation(false, false);
}

test "Keychain task cancellation reaps a child that closed output" {
    try testKeychainTaskCancellation(true, false);
}

test "Keychain task cancellation interrupts blocked credential input and reaps" {
    try testKeychainTaskCancellation(false, true);
}

fn testKeychainTaskCancellation(close_output: bool, block_input: bool) !void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const Probe = struct {
        fn run(argv: []const []const u8, blocked_input: bool) !void {
            const result = if (blocked_input)
                try process_owner.run(std.testing.allocator, .{
                    .argv = argv,
                    .stdin = "credential" ** (128 * 1024),
                    .stdout_limit = 16,
                    .timeout_ms = 10_000,
                })
            else
                try runMcpKeychainProcess(std.testing.allocator, argv, null, .limited(16));
            defer std.testing.allocator.free(result.stdout);
            defer std.testing.allocator.free(result.stderr);
        }

        fn rescue(pid: std.posix.pid_t, done: *std.atomic.Value(bool)) void {
            for (0..100) |_| {
                if (done.load(.acquire)) return;
                io_mod.sleep(10 * std.time.ns_per_ms);
            }
            std.posix.kill(pid, .KILL) catch {};
        }

        fn cleanup(pid: std.posix.pid_t) void {
            var status: c_int = 0;
            if (std.c.waitpid(pid, &status, std.posix.W.NOHANG) == 0) {
                std.posix.kill(pid, .KILL) catch {};
                _ = std.c.waitpid(pid, &status, 0);
            }
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, ".");
    defer std.testing.allocator.free(root);
    const ready = try std.fs.path.join(std.testing.allocator, &.{ root, "ready" });
    defer std.testing.allocator.free(ready);
    const argv = [_][]const u8{
        "/usr/bin/python3",
        "-c",
        "import os,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); (os.close(1),os.close(2)) if sys.argv[2]=='closed' else None; os.read(0,1) if sys.argv[3]=='input' else None; open(sys.argv[1],'w').write(str(os.getpid())); time.sleep(60)",
        ready,
        if (close_output) "closed" else "open",
        if (block_input) "input" else "empty",
    };
    var task = try std.Io.concurrent(io_mod.getIo(), Probe.run, .{ &argv, block_input });
    var joined = false;
    defer if (!joined) task.cancel(io_mod.getIo()) catch {};
    var pid: ?std.posix.pid_t = null;
    for (0..5000) |_| {
        if (tmp.dir.openFile(io_mod.getIo(), "ready", .{})) |opened| {
            var file = opened;
            defer file.close(io_mod.getIo());
            const bytes = try io_mod.readFileToEnd(std.testing.allocator, &file, 32);
            defer std.testing.allocator.free(bytes);
            pid = std.fmt.parseInt(std.posix.pid_t, bytes, 10) catch null;
            if (pid != null) break;
        } else |_| {}
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(pid != null);
    defer Probe.cleanup(pid.?);
    var done = std.atomic.Value(bool).init(false);
    const rescuer = try std.Thread.spawn(.{}, Probe.rescue, .{ pid.?, &done });
    defer rescuer.join();
    const started = io_mod.milliTimestamp();
    const result = task.cancel(io_mod.getIo());
    joined = true;
    const elapsed = io_mod.milliTimestamp() - started;
    done.store(true, .release);
    try std.testing.expectError(error.Canceled, result);
    try std.testing.expect(elapsed < 500);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid.?, @enumFromInt(0)));
}

test "default Keychain availability probe is cancellable" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const Canceller = struct {
        flag: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            io_mod.sleep(25 * std.time.ns_per_ms);
            self.flag.store(true, .release);
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var canceller = Canceller{ .flag = &cancel };
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});
    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.Cancelled,
        userDefaultKeychainAvailableForCommand(
            std.testing.allocator,
            &.{ "/bin/sh", "-c", "exec sleep 60" },
            &cancel,
        ),
    );
    thread.join();
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1_000);
}

test "Keychain value store transports credentials through stdin" {
    const argv = mcpScriptArgv("store", "user", "test-service");
    try std.testing.expectEqualStrings("/usr/bin/osascript", argv[0]);
    try std.testing.expect(std.mem.find(u8, argv[4], "fileHandleWithStandardInput") != null);
    for (argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "vca_secret_value"));
}

test "helper cancellation abandons output retained by an external process" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const Probe = struct {
        fn run(root: []const u8) !void {
            const result = try runMcpKeychainProcess(std.testing.allocator, &.{
                "/usr/bin/python3",                                                                                                                                                                                                                                                     "-c",
                "import array,os,socket,sys; os.chdir(sys.argv[1]); s=socket.socket(socket.AF_UNIX); s.connect('output.sock'); s.sendmsg([b'x'],[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',[1]))]); open('sender','w').write(str(os.getpid())); print('output',flush=True)", root,
            }, null, .limited(32));
            defer std.testing.allocator.free(result.stdout);
            defer std.testing.allocator.free(result.stderr);
        }

        fn waitFile(dir: std.Io.Dir, name: []const u8) !void {
            for (0..5000) |_| {
                if (dir.statFile(io_mod.getIo(), name, .{})) |_| return else |_| {}
                io_mod.sleep(std.time.ns_per_ms);
            }
            return error.TestFileNotReady;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var broker = try std.process.spawn(io_mod.getIo(), .{
        .argv = &.{
            "/usr/bin/python3",                                                                                                                                                                                                                                                                                                                 "-c",
            "import array,os,signal,socket,sys; os.chdir(sys.argv[1]); s=socket.socket(socket.AF_UNIX); s.bind('output.sock'); s.listen(1); open('broker','w').close(); c,_=s.accept(); _,ancillary,_,_=c.recvmsg(1,socket.CMSG_SPACE(4)); fds=array.array('i'); fds.frombytes(ancillary[0][2][:4]); open('held','w').close(); signal.pause()", root,
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const broker_pid = broker.id.?;
    defer {
        std.posix.kill(broker_pid, .KILL) catch {};
        _ = broker.wait(io_mod.getIo()) catch {};
    }
    try Probe.waitFile(tmp.dir, "broker");
    var task = try std.Io.concurrent(io_mod.getIo(), Probe.run, .{root});
    var joined = false;
    defer if (!joined) task.cancel(io_mod.getIo()) catch {};
    try Probe.waitFile(tmp.dir, "held");
    try Probe.waitFile(tmp.dir, "sender");
    var sender_file = try tmp.dir.openFile(io_mod.getIo(), "sender", .{});
    defer sender_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &sender_file, 32);
    defer alloc.free(bytes);
    const sender = try std.fmt.parseInt(std.posix.pid_t, bytes, 10);
    const started = io_mod.milliTimestamp();
    const result = task.cancel(io_mod.getIo());
    joined = true;
    try std.testing.expectError(error.Canceled, result);
    try std.testing.expect(io_mod.milliTimestamp() - started < 500);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(sender, @enumFromInt(0)));
    // This descriptor belongs to an independent owner, which shutdown must not kill.
    try std.posix.kill(broker_pid, @enumFromInt(0));
}
