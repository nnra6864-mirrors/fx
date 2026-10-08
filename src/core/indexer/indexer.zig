//! Native workspace indexer: which files and folders exist under a set of
//! roots, decided by git's ignore rules read as data. It never starts a
//! process, so a repository's configuration cannot make it run a program.
//! Outside code imports only this file; `scripts/check-indexer-boundary.sh`
//! enforces that, the import allowlist and the no-process rule in CI.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const git_config = @import("git_config.zig");
const layout = @import("layout.zig");

const Allocator = std.mem.Allocator;

pub const FilterNames = struct {
    /// The slice and every name are owned by the allocator passed to
    /// `repoFilterNames`.
    names: []const []const u8,

    pub fn deinit(self: FilterNames, alloc: Allocator) void {
        for (self.names) |name| alloc.free(name);
        alloc.free(self.names);
    }
};

pub const RepoFilterNamesError = error{ OutOfMemory, RepoConfigUnavailable };

/// Returns every filter driver name with a `clean`, `smudge` or `process`
/// command in the repository's own config: `config`, `config.worktree` and
/// the files they include, counting every `includeIf` as included so no
/// condition can hide a driver. Empty outside a git repository. A repository
/// config file that cannot be read within bounds, a malformed one, or an
/// invalid `.git` file fails closed with `error.RepoConfigUnavailable`.
pub fn repoFilterNames(alloc: Allocator, workspace_root: []const u8) RepoFilterNamesError!FilterNames {
    if (!std.fs.path.isAbsolute(workspace_root)) return error.RepoConfigUnavailable;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = layout.discover(arena, workspace_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidGitFile => {
            debug_trace.logf("indexer", "filter names unavailable reason=invalid_git_file root={s}", .{workspace_root});
            return error.RepoConfigUnavailable;
        },
    };
    const context = try git_config.Context.fromEnvironment(arena, found);
    const loaded = try git_config.loadRepositoryEveryInclude(arena, &context);
    if (loaded.unavailable.len > 0) {
        for (loaded.unavailable) |source| {
            debug_trace.logf("indexer", "filter names unavailable reason={s} path={s}", .{ source.reason, source.path });
        }
        return error.RepoConfigUnavailable;
    }

    const names = try git_config.filterDriverNames(arena, loaded);
    const owned = try alloc.alloc([]const u8, names.len);
    var copied: usize = 0;
    errdefer {
        for (owned[0..copied]) |name| alloc.free(name);
        alloc.free(owned);
    }
    for (names) |name| {
        owned[copied] = try alloc.dupe(u8, name);
        copied += 1;
    }
    return .{ .names = owned };
}

test {
    _ = @import("bounded_read.zig");
    _ = @import("wildmatch.zig");
    _ = @import("ignore.zig");
    _ = @import("sources.zig");
    _ = layout;
    _ = git_config;
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = content });
}

test "repoFilterNames returns repository drivers and fails closed on unreadable config" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "repo/.git/HEAD", "ref: refs/heads/main\n");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git/objects");
    try writeTestFile(tmp.dir, "repo/.git/config", "[includeIf \"gitdir:/nowhere/\"]\npath = extra\n");
    try writeTestFile(tmp.dir, "repo/.git/extra", "[filter \"x\"]\nclean = /tmp/run-me\n");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try writeTestFile(tmp.dir, "bad/.git/HEAD", "ref: refs/heads/main\n");
    try tmp.dir.createDirPath(std.testing.io, "bad/.git/objects");
    try tmp.dir.createDirPath(std.testing.io, "bad/.git/config");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    const repo_src = try std.fs.path.join(alloc, &.{ root, "repo/src" });
    defer alloc.free(repo_src);
    const names = try repoFilterNames(alloc, repo_src);
    defer names.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), names.names.len);
    try std.testing.expectEqualStrings("x", names.names[0]);

    const bad = try std.fs.path.join(alloc, &.{ root, "bad" });
    defer alloc.free(bad);
    try std.testing.expectError(error.RepoConfigUnavailable, repoFilterNames(alloc, bad));
    try std.testing.expectError(error.RepoConfigUnavailable, repoFilterNames(alloc, "relative"));
}
