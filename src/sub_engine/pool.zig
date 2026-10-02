//! A pool of terminals with one reader thread.
//!
//! The pool owns up to `max_terminals` terminals. One reader thread polls
//! them all and hands their output and exits to the owner's sink, so every
//! terminal streams whether or not anyone is looking at it. `open`, `write`,
//! `resize` and `close` are safe to call from any thread; `destroy` comes
//! last, once every other call has returned.
//!
//! The table lock guards the slots and every terminal in them. The reader
//! touches a terminal only under that lock, after checking that its id is
//! still current, so a closed fd, or one reused by other code, is never
//! read. The sink runs on the reader thread while it holds the delivery
//! lock, never the table lock, so the sink may call `write` and `resize`. It
//! must not call `close` or `destroy`, which wait for the delivery lock and
//! the reader. Once `close(id)` returns, the sink gets no more calls for
//! `id`.
//!
//! Each terminal's report channel (see `report_env`) is polled with its PTY.
//! Before the reader reports a child's exit it drains the channel, so every
//! line the child finished arrives first; after the exit it stops reading
//! the channel.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("pool_core.zig");
const terminal_mod = @import("terminal.zig");
const report_core = @import("report_core.zig");
const fd_ops = @import("fd.zig");

const Allocator = std.mem.Allocator;
const Terminal = terminal_mod.Terminal;
const POLL = std.c.POLL;

pub const Id = core.Id;
pub const max_terminals = core.max_terminals;
pub const max_report_line = report_core.max_line;

/// How often the reader checks for exited children while any terminal is
/// live. A child can exit while a process it started keeps the PTY open, so
/// the end of its output does not reveal every exit.
const exit_check_ms: c_int = 100;

pub const Sink = struct {
    ctx: *anyopaque,
    /// Output from terminal `id`. `bytes` is valid only during the call.
    output: *const fn (ctx: *anyopaque, id: Id, bytes: []const u8) void,
    /// One complete line that terminal `id`'s child wrote to its report
    /// channel, newline excluded. `line` is valid only during the call. Lines
    /// arrive in the order written; a line longer than `max_report_line`
    /// and a partial last line are dropped.
    report: *const fn (ctx: *anyopaque, id: Id, line: []const u8) void,
    /// Terminal `id`'s child exited. Called once per id, after every report
    /// line the child finished. Output may still follow, from processes the
    /// child started, but no more report lines.
    exited: *const fn (ctx: *anyopaque, id: Id, exit: terminal_mod.Exit) void,
};

pub const OpenError = error{LimitReached} || terminal_mod.OpenError;

pub const WriteError = error{
    /// No open terminal has this id.
    NotFound,
    /// The terminal's child side of the PTY is gone; it only awaits close.
    Ended,
    QueueFull,
    OutOfMemory,
    WriteFailed,
};

pub const Pool = struct {
    gpa: Allocator,
    io: std.Io,
    sink: Sink,
    table_lock: std.Io.Mutex = .init,
    delivery_lock: std.Io.Mutex = .init,
    table: core.Table = .{},
    terminals: [max_terminals]?Terminal = [_]?Terminal{null} ** max_terminals,
    /// Each slot's report framing. Used by the reader under the delivery
    /// lock, and freed by `close` once no delivery can still use it.
    reports: [max_terminals]report_core.Lines = [_]report_core.Lines{.{}} ** max_terminals,
    /// Each slot's report channel is no longer read: it ended, or the child's
    /// exit was reported. Guarded by the table lock.
    report_done: [max_terminals]bool = [_]bool{false} ** max_terminals,
    wake: fd_ops.Pipe,
    wake_pending: bool = false,
    stopping: bool = false,
    thread: std.Thread = undefined,
    /// The reader's read buffers, for PTY output and for reports.
    buf: [16 * 1024]u8 = undefined,
    report_buf: [16 * 1024]u8 = undefined,
    /// What the reader drained from a report channel before an exit.
    drain: std.ArrayList(u8) = .empty,
    trace: Trace = .{},

    /// Starts the reader thread. Call `destroy` when done.
    pub fn create(
        gpa: Allocator,
        io: std.Io,
        sink: Sink,
    ) error{ OutOfMemory, PipeUnavailable, SystemResources }!*Pool {
        return createWith(gpa, io, sink, .{});
    }

    fn createWith(
        gpa: Allocator,
        io: std.Io,
        sink: Sink,
        trace: Trace,
    ) error{ OutOfMemory, PipeUnavailable, SystemResources }!*Pool {
        const self = try gpa.create(Pool);
        errdefer gpa.destroy(self);
        const wake = try fd_ops.pipe(.{ .read_nonblocking = true, .write_nonblocking = true });
        errdefer {
            fd_ops.close(wake.read);
            fd_ops.close(wake.write);
        }
        self.* = .{ .gpa = gpa, .io = io, .sink = sink, .wake = wake, .trace = trace };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch return error.SystemResources;
        return self;
    }

    /// Stops the reader, closes every terminal still open and frees the
    /// pool. The sink gets no calls after this returns.
    pub fn destroy(self: *Pool) void {
        self.lockTable();
        self.stopping = true;
        self.wakeReader();
        self.unlockTable();
        self.thread.join();
        for (&self.terminals) |*slot| {
            if (slot.*) |*terminal| _ = terminal.close() catch {};
            slot.* = null;
        }
        for (&self.reports) |*lines| lines.deinit(self.gpa);
        self.drain.deinit(self.gpa);
        fd_ops.close(self.wake.read);
        fd_ops.close(self.wake.write);
        self.gpa.destroy(self);
    }

    /// Starts a terminal (see `Terminal.open`) and begins streaming it.
    pub fn open(self: *Pool, options: terminal_mod.Options) OpenError!Id {
        {
            self.lockTable();
            defer self.unlockTable();
            if (!self.table.hasFree()) return error.LimitReached;
        }
        // Started outside the table lock: fork and exec take a while, and
        // the reader must keep streaming the other terminals meanwhile.
        var terminal = try Terminal.open(self.gpa, options);
        self.lockTable();
        defer self.unlockTable();
        const id = self.table.open() catch {
            _ = terminal.close() catch {};
            return error.LimitReached;
        };
        self.terminals[id.slot] = terminal;
        self.report_done[id.slot] = false;
        self.wakeReader();
        self.trace.owner(self, "Open");
        return id;
    }

    /// Writes to terminal `id`, queueing what the PTY cannot take yet; the
    /// reader writes the rest when the PTY has room.
    pub fn write(self: *Pool, id: Id, bytes: []const u8) WriteError!void {
        self.lockTable();
        defer self.unlockTable();
        if (!self.table.isCurrent(id)) {
            return if (self.table.isLive(id)) error.Ended else error.NotFound;
        }
        const terminal = &self.terminals[id.slot].?;
        const was_pending = terminal.pendingBytes() > 0;
        const result = terminal.write(bytes);
        if (!was_pending and terminal.pendingBytes() > 0) {
            self.wakeReader();
            self.trace.owner(self, "Write");
        }
        result catch |err| return switch (err) {
            error.Closed => error.NotFound,
            else => |e| e,
        };
    }

    pub const ReplyError = error{NotFound} || Terminal.ReplyError;

    /// Sends `line` to terminal `id`'s child on its report channel (see
    /// `Terminal.reply`). `Ended` once the child's end is closed.
    pub fn reply(self: *Pool, id: Id, line: []const u8) ReplyError!void {
        self.lockTable();
        defer self.unlockTable();
        if (!self.table.isCurrent(id)) {
            return if (self.table.isLive(id)) error.Ended else error.NotFound;
        }
        self.terminals[id.slot].?.reply(line) catch |err| return switch (err) {
            error.Closed => error.Ended,
            else => |e| e,
        };
    }

    /// Resizes every live terminal.
    pub fn resize(self: *Pool, cols: u16, rows: u16) error{ InvalidOptions, ResizeFailed }!void {
        if (cols == 0 or rows == 0) return error.InvalidOptions;
        self.lockTable();
        defer self.unlockTable();
        var failed = false;
        for (&self.terminals) |*slot| {
            const terminal = &(slot.* orelse continue);
            terminal.resize(cols, rows) catch {
                failed = true;
            };
        }
        if (failed) return error.ResizeFailed;
    }

    /// Closes terminal `id` (see `Terminal.close`). After this returns, the
    /// sink gets no more calls for `id`.
    pub fn close(self: *Pool, id: Id) error{ NotFound, WaitFailed }!terminal_mod.CloseReport {
        self.lockTable();
        self.table.remove(id) catch {
            self.unlockTable();
            return error.NotFound;
        };
        var terminal = self.terminals[id.slot].?;
        self.terminals[id.slot] = null;
        // A poll that still watches the fd keeps the PTY open on Linux,
        // which would delay the child's hangup.
        self.wakeReader();
        self.trace.owner(self, "CloseRemove");
        self.unlockTable();

        // A delivery that began before the removal finishes before close
        // goes on.
        self.delivery_lock.lockUncancelable(self.io);
        self.trace.ownerUnlocked(self, "CloseWait");
        self.delivery_lock.unlock(self.io);
        // The slot stays reserved until `release`, so no reader or open
        // uses its framing meanwhile.
        self.reports[id.slot].deinit(self.gpa);

        const report = terminal.close();
        self.lockTable();
        self.table.release(id);
        self.trace.owner(self, "CloseFinish");
        self.unlockTable();
        return report catch |err| switch (err) {
            // Only this call closes the terminal it removed from the table.
            error.Closed => unreachable,
            error.WaitFailed => error.WaitFailed,
        };
    }

    fn lockTable(self: *Pool) void {
        self.table_lock.lockUncancelable(self.io);
    }

    fn unlockTable(self: *Pool) void {
        self.table_lock.unlock(self.io);
    }

    /// Wakes the reader's poll. Called with the table lock held.
    fn wakeReader(self: *Pool) void {
        if (self.wake_pending) return;
        self.wake_pending = true;
        _ = std.c.write(self.wake.write, "w", 1);
    }

    /// Empties the wake pipe. Called with the table lock held. Returns
    /// whether a wake was pending.
    fn drainWake(self: *Pool) bool {
        var byte: [8]u8 = undefined;
        while (std.c.read(self.wake.read, &byte, byte.len) > 0) {}
        defer self.wake_pending = false;
        return self.wake_pending;
    }

    const Entry = struct {
        id: Id,
        fd: std.posix.fd_t,
        want_out: bool,
        /// The report channel, while it is still read.
        report_fd: ?std.posix.fd_t,
    };

    const Pick = struct {
        entry: Entry,
        revents: i16,
        report_revents: i16,
    };

    const Exited = struct { id: Id, exit: terminal_mod.Exit };

    fn run(self: *Pool) void {
        var entries: [max_terminals]Entry = undefined;
        // The wake pipe, then each entry's PTY and report channel.
        var fds: [2 * max_terminals + 1]std.c.pollfd = undefined;
        var report_at: [max_terminals]?usize = undefined;
        var picks: [max_terminals]Pick = undefined;
        while (true) {
            self.lockTable();
            if (self.stopping) {
                self.unlockTable();
                return;
            }

            if (self.findExit()) |found| {
                self.delivery_lock.lockUncancelable(self.io);
                self.trace.reader(self, "ExitCheck", .{ .rpc = .deliver, .delivering = true });
                self.unlockTable();
                const lines = &self.reports[found.id.slot];
                self.feedReport(found.id, self.drain.items);
                lines.end();
                self.sink.exited(self.sink.ctx, found.id, found.exit);
                self.finishDelivery(&.{});
                continue;
            }

            var count: usize = 0;
            var timed = false;
            for (&self.terminals, 0..) |*slot, index| {
                const terminal = &(slot.* orelse continue);
                const id = self.table.liveId(index) orelse continue;
                timed = true;
                if (!self.table.isCurrent(id)) continue;
                entries[count] = .{
                    .id = id,
                    .fd = terminal.fd(),
                    .want_out = terminal.pendingBytes() > 0,
                    .report_fd = if (self.report_done[index]) null else terminal.reportFd(),
                };
                count += 1;
            }
            self.trace.reader(self, "Snapshot", .{ .rpc = .poll, .snap = entries[0..count], .timed = timed });
            self.unlockTable();

            fds[0] = .{ .fd = self.wake.read, .events = POLL.IN, .revents = 0 };
            var watched: usize = 1;
            for (entries[0..count], report_at[0..count]) |entry, *at| {
                const out: i16 = if (entry.want_out) POLL.OUT else 0;
                fds[watched] = .{ .fd = entry.fd, .events = POLL.IN | out, .revents = 0 };
                watched += 1;
                at.* = null;
                if (entry.report_fd) |report_fd| {
                    fds[watched] = .{ .fd = report_fd, .events = POLL.IN, .revents = 0 };
                    at.* = watched;
                    watched += 1;
                }
            }
            while (std.c.poll(&fds, @intCast(watched), if (timed) exit_check_ms else -1) < 0 and
                std.c.errno(@as(c_int, -1)) == .INTR)
            {}

            self.lockTable();
            const woke = self.drainWake();
            var pick_count: usize = 0;
            var at_pty: usize = 1;
            for (entries[0..count], report_at[0..count]) |entry, at_report| {
                const revents = fds[at_pty].revents;
                const report_revents = if (at_report) |at| fds[at].revents else 0;
                at_pty += if (at_report == null) 1 else 2;
                if (revents == 0 and report_revents == 0) continue;
                picks[pick_count] = .{ .entry = entry, .revents = revents, .report_revents = report_revents };
                pick_count += 1;
            }
            if (pick_count == 0 and !woke) {
                self.trace.reader(self, "PollTimeout", .{ .rpc = .snapshot });
                self.unlockTable();
                continue;
            }
            self.trace.reader(self, "Poll", .{
                .rpc = if (pick_count == 0) .snapshot else .read,
                .picks = picks[0..pick_count],
            });
            self.unlockTable();

            for (picks[0..pick_count], 1..) |pick, handled| {
                self.lockTable();
                self.handle(pick, picks[handled..pick_count]);
            }
        }
    }

    /// One exited child that has not been reported yet, with what it left
    /// in its report channel drained into `drain`. Called with the table lock
    /// held.
    fn findExit(self: *Pool) ?Exited {
        for (&self.terminals, 0..) |*slot, index| {
            const terminal = &(slot.* orelse continue);
            const id = self.table.liveId(index) orelse continue;
            const exit = (terminal.checkExit() catch continue) orelse continue;
            if (!self.table.claimExit(id)) continue;
            self.drainReport(index, terminal);
            return .{ .id = id, .exit = exit };
        }
        return null;
    }

    /// Reads everything the exited child left in its report channel. The child
    /// wrote it all before exiting, so the channel holds every line it
    /// finished. Called with the table lock held.
    fn drainReport(self: *Pool, index: usize, terminal: *Terminal) void {
        self.drain.clearRetainingCapacity();
        defer self.report_done[index] = true;
        if (self.report_done[index]) return;
        while (true) {
            const result = terminal.readReport(&self.report_buf) catch return;
            switch (result) {
                // Short of memory, the lines read so far still arrive.
                .data => |bytes| self.drain.appendSlice(self.gpa, bytes) catch return,
                .empty, .ended => return,
            }
        }
    }

    /// Frames report bytes from terminal `id` and hands each complete line
    /// to the sink. Called with the delivery lock held.
    fn feedReport(self: *Pool, id: Id, bytes: []const u8) void {
        var emit_ctx: ReportEmit = .{ .pool = self, .id = id };
        self.reports[id.slot].feed(self.gpa, bytes, .{ .ctx = &emit_ctx, .line = ReportEmit.line });
    }

    const ReportEmit = struct {
        pool: *Pool,
        id: Id,

        fn line(ctx: *anyopaque, bytes: []const u8) void {
            const self: *ReportEmit = @ptrCast(@alignCast(ctx));
            self.pool.sink.report(self.pool.sink.ctx, self.id, bytes);
        }
    };

    /// Handles one ready fd. Called with the table lock held; returns with
    /// it released.
    fn handle(self: *Pool, pick: Pick, rest: []const Pick) void {
        const id = pick.entry.id;
        const after: Trace.Rpc = if (rest.len == 0) .snapshot else .read;
        if (!self.table.isCurrent(id)) {
            self.trace.reader(self, "Read", .{ .rpc = after, .picks = rest });
            self.unlockTable();
            return;
        }
        const terminal = &self.terminals[id.slot].?;
        // A failed write leaves the bytes queued; the child side closing
        // ends the terminal, and close drops what is left.
        if (pick.entry.want_out and pick.revents & POLL.OUT != 0) terminal.flush() catch {};
        const ready = POLL.IN | POLL.HUP | POLL.ERR;
        // Any other read error ends the terminal the way a hangup does, so a
        // broken fd cannot keep poll spinning; its exit is still reported.
        const output: terminal_mod.ReadResult = if (pick.revents & ready != 0) terminal.read(&self.buf) catch .ended else .empty;
        // Likewise a report channel that fails is no longer read.
        const report: terminal_mod.ReadResult = if (pick.report_revents & ready != 0) terminal.readReport(&self.report_buf) catch .ended else .empty;
        const report_ended = report == .ended;
        if (report_ended) self.report_done[id.slot] = true;

        const output_bytes: []const u8 = if (output == .data) output.data else &.{};
        const report_bytes: []const u8 = if (report == .data) report.data else &.{};
        // The end of the report channel drops a partial line, and the framing
        // is touched only under the delivery lock.
        if (output_bytes.len > 0 or report_bytes.len > 0 or report_ended) {
            // A PTY that also ended is noticed on its next read.
            self.delivery_lock.lockUncancelable(self.io);
            self.trace.reader(self, "Read", .{ .rpc = .deliver, .picks = rest, .delivering = true });
            self.unlockTable();
            if (output_bytes.len > 0) self.sink.output(self.sink.ctx, id, output_bytes);
            self.feedReport(id, report_bytes);
            if (report_ended) self.reports[id.slot].end();
            self.finishDelivery(rest);
            return;
        }
        if (output == .ended) self.table.markEnded(id);
        self.trace.reader(self, "Read", .{ .rpc = after, .picks = rest });
        self.unlockTable();
    }

    /// The sink returned: release the delivery lock.
    fn finishDelivery(self: *Pool, rest: []const Pick) void {
        self.trace.deliver(self, if (rest.len == 0) .snapshot else .read, rest);
        self.delivery_lock.unlock(self.io);
    }
};

// Test builds can record every step of the pool, owner and reader threads
// alike, as JSON lines for checking against a model outside this
// repository. Other builds compile the calls away.

const Trace = if (builtin.is_test) Recorder else struct {
    const Rpc = Recorder.Rpc;
    fn owner(_: *Trace, _: *Pool, _: []const u8) void {}
    fn ownerUnlocked(_: *Trace, _: *Pool, _: []const u8) void {}
    fn reader(_: *Trace, _: *Pool, _: []const u8, _: Recorder.View) void {}
    fn deliver(_: *Trace, _: *Pool, _: Rpc, _: []const Pool.Pick) void {}
};

const Recorder = struct {
    file: ?std.Io.File = null,
    offset: u64 = 0,
    failed: bool = false,
    /// Orders every recorded step. Taken after the table and delivery
    /// locks, never before them.
    lock: std.Io.Mutex = .init,
    /// The state as of the last recorded step.
    last: Saved = .{},

    const Rpc = enum { snapshot, poll, read, deliver };

    const View = struct {
        rpc: Rpc,
        snap: ?[]const Pool.Entry = null,
        picks: []const Pool.Pick = &.{},
        delivering: bool = false,
        timed: ?bool = null,
    };

    const Saved = struct {
        states: [max_terminals]core.SlotState = [_]core.SlotState{.free} ** max_terminals,
        gens: [max_terminals]u32 = [_]u32{0} ** max_terminals,
        exit_sent: [max_terminals]bool = [_]bool{false} ** max_terminals,
        wake: bool = false,
        rpc: Rpc = .snapshot,
        snap: [max_terminals]Id = undefined,
        snap_len: usize = 0,
        picks: [max_terminals]Id = undefined,
        picks_len: usize = 0,
        delivering: bool = false,
        timed: bool = false,
    };

    /// An owner step that changes the table. Called with the table lock held.
    fn owner(self: *Recorder, pool: *Pool, event: []const u8) void {
        self.step(pool, event, null);
    }

    /// An owner step that changes nothing the trace records (close waiting
    /// out deliveries). Called with the delivery lock held.
    fn ownerUnlocked(self: *Recorder, _: *Pool, event: []const u8) void {
        self.step(null, event, null);
    }

    /// A reader step. Called with the table lock held.
    fn reader(self: *Recorder, pool: *Pool, event: []const u8, view: View) void {
        self.step(pool, event, view);
    }

    /// The sink returned. Called with the delivery lock held.
    fn deliver(self: *Recorder, _: *Pool, after: Rpc, rest: []const Pool.Pick) void {
        self.step(null, "Deliver", .{ .rpc = after, .picks = rest });
    }

    /// Stops recording; later steps are not written. Fails if any line
    /// could not be written.
    fn finish(self: *Recorder) error{TraceWriteFailed}!void {
        self.lock.lockUncancelable(std.testing.io);
        defer self.lock.unlock(std.testing.io);
        if (self.file) |file| file.close(std.testing.io);
        self.file = null;
        if (self.failed) return error.TraceWriteFailed;
    }

    /// Records one step. `pool` is given when the caller holds the table
    /// lock, so the table can be read; steps without it change no table
    /// state.
    fn step(self: *Recorder, pool: ?*Pool, event: []const u8, view: ?View) void {
        self.lock.lockUncancelable(std.testing.io);
        defer self.lock.unlock(std.testing.io);
        if (self.file == null) return;
        const last = &self.last;
        if (pool) |p| {
            for (p.table.slots, 0..) |slot, index| {
                last.states[index] = slot.state;
                last.gens[index] = slot.gen;
                last.exit_sent[index] = slot.exit_sent;
            }
            last.wake = p.wake_pending;
        }
        if (view) |v| {
            last.rpc = v.rpc;
            last.delivering = v.delivering;
            if (v.timed) |timed| last.timed = timed;
            if (v.snap) |snap| {
                for (snap, 0..) |entry, index| last.snap[index] = entry.id;
                last.snap_len = snap.len;
            }
            for (v.picks, 0..) |pick, index| last.picks[index] = pick.entry.id;
            last.picks_len = v.picks.len;
        }
        self.emit(event);
    }

    const Ref = struct { s: usize, g: u32 };

    fn refs(ids: []const Id, out: []Ref) []Ref {
        for (ids, out[0..ids.len]) |id, *ref| ref.* = .{ .s = @as(usize, id.slot) + 1, .g = id.gen };
        return out[0..ids.len];
    }

    /// Writes `last` as one line. The model numbers slots from 1.
    fn emit(self: *Recorder, event: []const u8) void {
        const file = self.file.?;
        const last = &self.last;
        var states: [max_terminals][]const u8 = undefined;
        for (last.states, &states) |state, *name| name.* = @tagName(state);
        var snap_refs: [max_terminals]Ref = undefined;
        var pick_refs: [max_terminals]Ref = undefined;
        const line = std.json.Stringify.valueAlloc(std.testing.allocator, .{
            .event = event,
            .state = states,
            .gen = last.gens,
            .exit_sent = last.exit_sent,
            .wake = last.wake,
            .rpc = @tagName(last.rpc),
            .snap = .{ .@"$set" = refs(last.snap[0..last.snap_len], &snap_refs) },
            .picks = .{ .@"$set" = refs(last.picks[0..last.picks_len], &pick_refs) },
            .delivering = last.delivering,
            .timed = last.timed,
        }, .{}) catch {
            self.failed = true;
            return;
        };
        defer std.testing.allocator.free(line);
        file.writePositionalAll(std.testing.io, line, self.offset) catch {
            self.failed = true;
            return;
        };
        self.offset += line.len;
        file.writePositionalAll(std.testing.io, "\n", self.offset) catch {
            self.failed = true;
            return;
        };
        self.offset += 1;
    }
};

// Tests run real children on real PTYs with /bin/sh.

const testing = std.testing;
const test_env = [_][]const u8{ "PATH=/usr/bin:/bin", "TERM=xterm-256color", "LANG=C" };

/// bash, because scripts write to the report fd with `>&$r` and dash takes
/// only single-digit fds there.
fn openShell(pool: *Pool, script: []const u8) OpenError!Id {
    return pool.open(.{ .argv = &.{ "/bin/bash", "-c", script }, .env = &test_env, .cols = 80, .rows = 24 });
}

fn sleepMs(ms: u32) void {
    var none: [0]std.c.pollfd = .{};
    _ = std.c.poll(&none, 0, @intCast(ms));
}

/// Records every sink call. Safe to use from the reader thread and the test.
const Collector = struct {
    lock: std.Io.Mutex = .init,
    records: std.ArrayList(Record) = .empty,
    closed: std.ArrayList(Id) = .empty,
    /// Calls for an id after its close returned.
    late: usize = 0,
    /// Report lines for an id after its exit.
    late_reports: usize = 0,
    /// When output contains `needle`, the sink writes `answer` back, from
    /// the reader thread.
    reply: ?struct { pool: *Pool, needle: []const u8, answer: []const u8 } = null,

    const Record = struct {
        id: Id,
        output: std.ArrayList(u8) = .empty,
        reports: std.ArrayList([]u8) = .empty,
        exit: ?terminal_mod.Exit = null,
        exits: usize = 0,
        /// Report lines received when the exit arrived.
        reports_at_exit: usize = 0,
    };

    fn deinit(self: *Collector) void {
        for (self.records.items) |*entry| {
            entry.output.deinit(testing.allocator);
            for (entry.reports.items) |line| testing.allocator.free(line);
            entry.reports.deinit(testing.allocator);
        }
        self.records.deinit(testing.allocator);
        self.closed.deinit(testing.allocator);
    }

    fn sink(self: *Collector) Sink {
        return .{ .ctx = self, .output = output, .report = report, .exited = exited };
    }

    fn record(self: *Collector, id: Id) *Record {
        for (self.records.items) |*r| {
            if (std.meta.eql(r.id, id)) return r;
        }
        self.records.append(testing.allocator, .{ .id = id }) catch @panic("out of memory");
        return &self.records.items[self.records.items.len - 1];
    }

    fn isClosed(self: *Collector, id: Id) bool {
        for (self.closed.items) |closed| {
            if (std.meta.eql(closed, id)) return true;
        }
        return false;
    }

    fn output(ctx: *anyopaque, id: Id, bytes: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.lock.lockUncancelable(testing.io);
        if (self.isClosed(id)) self.late += 1;
        const r = self.record(id);
        r.output.appendSlice(testing.allocator, bytes) catch @panic("out of memory");
        const reply = self.reply;
        const answer = if (reply) |rule| std.mem.find(u8, r.output.items, rule.needle) != null else false;
        if (answer) self.reply = null;
        self.lock.unlock(testing.io);
        if (answer) reply.?.pool.write(id, reply.?.answer) catch @panic("reply failed");
    }

    fn report(ctx: *anyopaque, id: Id, line: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        if (self.isClosed(id)) self.late += 1;
        const r = self.record(id);
        if (r.exits > 0) self.late_reports += 1;
        const copy = testing.allocator.dupe(u8, line) catch @panic("out of memory");
        r.reports.append(testing.allocator, copy) catch @panic("out of memory");
    }

    fn exited(ctx: *anyopaque, id: Id, exit: terminal_mod.Exit) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        if (self.isClosed(id)) self.late += 1;
        const r = self.record(id);
        r.exit = exit;
        r.exits += 1;
        r.reports_at_exit = r.reports.items.len;
    }

    /// Checks, after every terminal closed, that `id` got exactly `lines`.
    fn expectReports(self: *Collector, id: Id, lines: []const []const u8) !void {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        const got = self.record(id).reports.items;
        try testing.expectEqual(lines.len, got.len);
        for (lines, got) |want, line| try testing.expectEqualStrings(want, line);
    }

    fn markClosed(self: *Collector, id: Id) void {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        self.closed.append(testing.allocator, id) catch @panic("out of memory");
    }

    fn hasOutput(self: *Collector, id: Id, needle: []const u8) bool {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        return std.mem.find(u8, self.record(id).output.items, needle) != null;
    }

    fn exitsOf(self: *Collector, id: Id) usize {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        return self.record(id).exits;
    }

    fn exitOf(self: *Collector, id: Id) ?terminal_mod.Exit {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        return self.record(id).exit;
    }

    fn waitOutput(self: *Collector, id: Id, needle: []const u8, timeout_ms: u32) !void {
        var waited: u32 = 0;
        while (!self.hasOutput(id, needle)) : (waited += 10) {
            if (waited >= timeout_ms) return error.Timeout;
            sleepMs(10);
        }
    }

    fn waitExit(self: *Collector, id: Id, timeout_ms: u32) !terminal_mod.Exit {
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += 10) {
            if (self.exitOf(id)) |exit| return exit;
            sleepMs(10);
        }
        return error.Timeout;
    }
};

test "every terminal streams at the same time" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    const names = [_][]const u8{ "alpha", "bravo", "charlie" };
    var ids: [names.len]Id = undefined;
    for (names, &ids) |name, *id| {
        const script = try std.fmt.allocPrint(testing.allocator, "for i in 1 2 3 4 5; do echo {s}-$i; sleep 0.02; done", .{name});
        defer testing.allocator.free(script);
        id.* = try openShell(pool, script);
    }
    for (names, ids) |name, id| {
        try testing.expectEqual(terminal_mod.Exit{ .code = 0 }, try collector.waitExit(id, 5000));
        const last = try std.fmt.allocPrint(testing.allocator, "{s}-5", .{name});
        defer testing.allocator.free(last);
        try collector.waitOutput(id, last, 5000);
    }
    for (names, ids) |name, id| {
        for (names) |other| {
            if (std.mem.eql(u8, other, name)) continue;
            try testing.expect(!collector.hasOutput(id, other));
        }
        _ = try pool.close(id);
        try testing.expectEqual(@as(usize, 1), collector.exitsOf(id));
    }
}

test "the pool holds at most ten terminals" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    var ids: [max_terminals]Id = undefined;
    for (&ids) |*id| id.* = try openShell(pool, "sleep 30");
    try testing.expectError(error.LimitReached, openShell(pool, "sleep 30"));
    _ = try pool.close(ids[3]);
    ids[3] = try openShell(pool, "sleep 30");
    for (ids) |id| _ = try pool.close(id);
}

test "a write larger than the PTY holds reaches the child" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    const id = try openShell(pool, "stty raw -echo; echo ready; head -c 200000 >/dev/null; echo got-all");
    try collector.waitOutput(id, "ready", 5000);
    const bytes = try testing.allocator.alloc(u8, 200_000);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'x');
    try pool.write(id, bytes);
    try collector.waitOutput(id, "got-all", 10_000);
    _ = try pool.close(id);
}

test "no event arrives after close returns" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    for (0..20) |_| {
        const id = try openShell(pool, "while :; do echo spam; done");
        try collector.waitOutput(id, "spam", 5000);
        _ = try pool.close(id);
        collector.markClosed(id);
    }
    sleepMs(50);
    try testing.expectEqual(@as(usize, 0), collector.late);
}

test "an exit is reported while a background process holds the PTY" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    const id = try openShell(pool, "sleep 1 & exit 3");
    try testing.expectEqual(terminal_mod.Exit{ .code = 3 }, try collector.waitExit(id, 800));
    _ = try pool.close(id);
}

test "stale ids are refused and a reused slot gets a new id" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    const first = try openShell(pool, "sleep 30");
    _ = try pool.close(first);
    try testing.expectError(error.NotFound, pool.write(first, "x"));
    try testing.expectError(error.NotFound, pool.close(first));
    const second = try openShell(pool, "sleep 30");
    try testing.expectEqual(first.slot, second.slot);
    try testing.expect(first.gen != second.gen);
    _ = try pool.close(second);
}

test "writing to a terminal whose child side ended is refused" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    const id = try openShell(pool, "printf bye");
    try collector.waitOutput(id, "bye", 5000);
    var waited: u32 = 0;
    while (true) : (waited += 10) {
        pool.write(id, "x") catch |err| {
            try testing.expectEqual(error.Ended, err);
            break;
        };
        if (waited >= 5000) return error.Timeout;
        sleepMs(10);
    }
    _ = try pool.close(id);
}

test "resize reaches every terminal" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    var ids: [2]Id = undefined;
    for (&ids) |*id| id.* = try openShell(pool, "echo ready; read x; stty size");
    for (ids) |id| try collector.waitOutput(id, "ready", 5000);
    try pool.resize(100, 30);
    for (ids) |id| try pool.write(id, "\n");
    for (ids) |id| try collector.waitOutput(id, "30 100", 5000);
    try testing.expectError(error.InvalidOptions, pool.resize(0, 30));
    for (ids) |id| _ = try pool.close(id);
}

test "the sink can answer a terminal query from the reader thread" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();
    collector.reply = .{ .pool = pool, .needle = "\x1b[6n", .answer = "\x1b[12;34R" };

    const id = try openShell(
        pool,
        "stty raw -echo; printf '\\033[6n'; r=$(dd bs=1 count=8 2>/dev/null); stty sane; echo; echo \"reply=$r\"",
    );
    try collector.waitOutput(id, "12;34R", 5000);
    _ = try pool.close(id);
}

/// Writes to the report channel from /bin/sh: `>&$r` duplicates its fd. A
/// socket has no /dev/fd path on Linux.
const report_path = "r=${SUB_ENGINE_REPORT%%:*}; ";

test "report lines arrive whole, in order and before the exit" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    const id = try openShell(pool, report_path ++
        "{ printf 'one\ntw'; sleep 0.05; printf 'o\n\nlast'; } >&$r; exit 3");
    try testing.expectEqual(terminal_mod.Exit{ .code = 3 }, try collector.waitExit(id, 5000));
    _ = try pool.close(id);
    try collector.expectReports(id, &.{ "one", "two", "" });
    try testing.expectEqual(@as(usize, 3), collector.record(id).reports_at_exit);
}

test "no report line arrives after the exit" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    // The background process keeps the channel and writes after the exit.
    const id = try openShell(pool, report_path ++
        "(sleep 0.3; printf 'late\n' >&$r) & printf 'early\n' >&$r; exit 0");
    _ = try collector.waitExit(id, 5000);
    sleepMs(600);
    _ = try pool.close(id);
    try collector.expectReports(id, &.{"early"});
    try testing.expectEqual(@as(usize, 0), collector.late_reports);
}

test "a report line over the limit is dropped" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    const body = try std.fmt.allocPrint(
        testing.allocator,
        "{{ head -c {d} /dev/zero | tr '\\0' x; printf '\nok\n'; }} >&$r",
        .{max_report_line + 1},
    );
    defer testing.allocator.free(body);
    const script = try std.mem.concat(testing.allocator, u8, &.{ report_path, body });
    defer testing.allocator.free(script);
    const id = try openShell(pool, script);
    _ = try collector.waitExit(id, 10000);
    _ = try pool.close(id);
    try collector.expectReports(id, &.{"ok"});
}

test "each terminal's report lines keep their order" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    defer pool.destroy();

    const names = [_][]const u8{ "alpha", "bravo", "charlie" };
    var ids: [names.len]Id = undefined;
    for (names, &ids) |name, *id| {
        const body = try std.fmt.allocPrint(
            testing.allocator,
            "i=0; while [ $i -lt 200 ]; do printf '{s}-%d\n' $i; i=$((i+1)); done >&$r",
            .{name},
        );
        defer testing.allocator.free(body);
        const script = try std.mem.concat(testing.allocator, u8, &.{ report_path, body });
        defer testing.allocator.free(script);
        id.* = try openShell(pool, script);
    }
    for (ids) |id| _ = try collector.waitExit(id, 10000);
    for (ids) |id| _ = try pool.close(id);
    for (names, ids) |name, id| {
        var expected: [200][]u8 = undefined;
        for (&expected, 0..) |*line, i| line.* = try std.fmt.allocPrint(testing.allocator, "{s}-{d}", .{ name, i });
        defer for (expected) |line| testing.allocator.free(line);
        var views: [200][]const u8 = undefined;
        for (expected, &views) |line, *view| view.* = line;
        try collector.expectReports(id, &views);
    }
}

test "destroy closes the terminals still open" {
    var collector: Collector = .{};
    defer collector.deinit();
    const pool = try Pool.create(testing.allocator, testing.io, collector.sink());
    for (0..3) |_| _ = try openShell(pool, "sleep 30");
    pool.destroy();
}

// Random runs open, write to and close up to three terminals while their
// children print, exit, and leave the PTY to background processes, and
// while other fds are opened and closed so fd numbers get reused. With
// SUB_ENGINE_TRACE_DIR set, each run's steps are written to that folder.

const scripts = [_][]const u8{
    "echo hi",
    "cat",
    "while :; do echo x; sleep 0.01; done",
    "sleep 0.3 & exit 2",
    "printf 'a b c'; sleep 0.05",
    report_path ++ "printf 'one\ntwo\n' >&$r; echo done",
    report_path ++ "while :; do printf 'tick\n' >&$r; sleep 0.01; done",
    report_path ++ "printf 'partial' >&$r; exit 1",
};

fn runRandom(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var collector: Collector = .{};
    defer collector.deinit();

    var trace: Trace = .{};
    if (std.c.getenv("SUB_ENGINE_TRACE_DIR")) |dir_path| {
        var dir = try std.Io.Dir.cwd().openDir(testing.io, std.mem.span(dir_path), .{});
        defer dir.close(testing.io);
        var name: [64]u8 = undefined;
        const file_name = try std.fmt.bufPrint(&name, "Pool--seed-{d}.ndjson", .{seed});
        trace.file = try dir.createFile(testing.io, file_name, .{ .truncate = true });
    }
    const pool = try Pool.createWith(testing.allocator, testing.io, collector.sink(), trace);
    defer pool.destroy();

    var open_ids: std.ArrayList(Id) = .empty;
    defer open_ids.deinit(testing.allocator);
    var foreign: std.ArrayList(c_int) = .empty;
    defer foreign.deinit(testing.allocator);

    for (0..25) |_| {
        switch (random.uintLessThan(u8, 6)) {
            0, 1 => if (open_ids.items.len < 3) {
                const id = try openShell(pool, scripts[random.uintLessThan(usize, scripts.len)]);
                try open_ids.append(testing.allocator, id);
            },
            2 => if (open_ids.items.len > 0) {
                const id = open_ids.items[random.uintLessThan(usize, open_ids.items.len)];
                pool.write(id, "ping\n") catch |err| switch (err) {
                    error.Ended, error.WriteFailed => {},
                    else => return err,
                };
            },
            3 => if (open_ids.items.len > 0) {
                const id = open_ids.swapRemove(random.uintLessThan(usize, open_ids.items.len));
                _ = try pool.close(id);
                collector.markClosed(id);
            },
            4 => {
                if (foreign.items.len > 0 and random.boolean()) {
                    _ = std.c.close(foreign.pop().?);
                } else {
                    const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
                    if (fd >= 0) try foreign.append(testing.allocator, fd);
                }
            },
            else => sleepMs(random.uintLessThan(u32, 40)),
        }
    }
    for (open_ids.items) |id| {
        _ = try pool.close(id);
        collector.markClosed(id);
    }
    for (foreign.items) |fd| _ = std.c.close(fd);
    try pool.trace.finish();

    try testing.expectEqual(@as(usize, 0), collector.late);
    try testing.expectEqual(@as(usize, 0), collector.late_reports);
    for (collector.records.items) |entry| {
        try testing.expect(entry.exits <= 1);
        for (entry.reports.items) |line| {
            const whole = std.mem.eql(u8, line, "one") or std.mem.eql(u8, line, "two") or
                std.mem.eql(u8, line, "tick");
            try testing.expect(whole);
        }
    }
}

test "random runs keep the pool's rules" {
    for (0..8) |seed| try runRandom(seed);
}
