//! Renderers: every surface's bytes from a `report.View`.
//!
//! - `fx usage` text and JSON, and its failure lines.
//! - The `/usage` dashboard as draw-ready rows, and the usage hint. A row is
//!   a list of ops: a style, a reset, text, or spaces. fx's painter maps the
//!   three styles and the reset to its ANSI codes and writes the rest as is;
//!   every string, number, column, ellipsis, and clip is decided here.
//! - The `fx ask --json` `usage` value and the ACP prompt `usage` and
//!   `usage_update`.
//!
//! Output is byte-identical to what fx printed before this module, quirks
//! included. Nothing here allocates except through the caller's writer.

const std = @import("std");
const report = @import("report.zig");

const View = report.View;
const Scope = report.Scope;
const Totals = report.Totals;
const ModelUsage = report.ModelUsage;
const Writer = std.Io.Writer;

// ---------------------------------------------------------------------------
// fx usage

pub const Format = enum { text, json };

/// `fx usage` text (`UsageSnapshot.renderText`).
pub fn cliText(writer: *Writer, view: *const View) Writer.Error!void {
    try writer.print("Usage ({s})\n", .{view.scope.label()});
    switch (view.coverage) {
        .not_started => try writer.writeAll("Tracking has not started.\n"),
        .partial => {
            var date_buf: [24]u8 = undefined;
            // Partial coverage always has a start (report invariant).
            try writer.print("Tracking since {s} (partial window).\n", .{report.formatUtcDate(&date_buf, view.coverage_started_at_ms.?)});
        },
        .full => {},
    }
    switch (view.completeness) {
        .complete => {},
        .pending => try writer.writeAll("Known totals exclude pending Gateway reconciliation.\n"),
        .incomplete => try writer.writeAll("Known totals may be incomplete.\n"),
        .legacy => try writer.writeAll("This session predates complete usage tracking.\n"),
    }

    const totals = view.totals orelse return;
    try writer.print("Total tokens  {d}\nInput         {d}\nOutput        {d}\n", .{ totals.total_tokens, totals.input_tokens, totals.output_tokens });
    try writer.print("Cache         {d} read · {d} write\n", .{ totals.cache_read_tokens, totals.cache_write_tokens });
    if (totals.reasoning_tokens) |reasoning| try writer.print("Reasoning     {d}\n", .{reasoning});
    if (totals.request_count) |requests| try writer.print("Requests      {d}\n", .{requests});
    try writer.print("Spend         ${d:.4}\n", .{totals.total_cost});

    if (view.models.len == 0) return;
    try writer.writeAll("\nBy model\n");
    for (view.models) |model| {
        try writer.writeAll("- ");
        try writeTerminalSafe(writer, model.model);
        try writer.print("  {d} tokens  ${d:.4}\n", .{ model.totals.total_tokens, model.totals.total_cost });
    }
}

/// `fx usage --json` without the trailing newline (`UsageSnapshot.renderJson`).
pub fn cliJson(writer: *Writer, view: *const View) Writer.Error!void {
    try writer.writeAll("{\"kind\":\"usage\",\"schema_version\":1,\"period\":");
    try std.json.Stringify.value(view.scope.cliValue() orelse "session", .{}, writer);
    try writer.print(",\"snapshot_time_ms\":{d},\"window_start_ms\":{d},\"coverage\":{{\"status\":", .{ view.snapshot_time_ms, view.window_start_ms });
    try std.json.Stringify.value(@tagName(view.coverage), .{}, writer);
    try writer.writeAll(",\"started_at_ms\":");
    if (view.coverage_started_at_ms) |started_at_ms| try writer.print("{d}", .{started_at_ms}) else try writer.writeAll("null");
    try writer.print(",\"full_window\":{}}},\"completeness\":", .{view.coverage == .full});
    try std.json.Stringify.value(@tagName(view.completeness), .{}, writer);
    try writer.writeAll(",\"totals\":");
    if (view.totals) |totals| try writeTotalsJson(writer, totals) else try writer.writeAll("null");
    try writer.writeAll(",\"models\":[");
    for (view.models, 0..) |model, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"model\":");
        try std.json.Stringify.value(model.model, .{}, writer);
        try writer.writeAll(",\"totals\":");
        try writeTotalsJson(writer, model.totals);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

/// Exactly what `fx usage` writes to stdout on success: the text, or the
/// JSON plus one newline (`writeFormattedOutput`).
pub fn cliOutput(writer: *Writer, view: *const View, format: Format) Writer.Error!void {
    switch (format) {
        .text => try cliText(writer, view),
        .json => {
            try cliJson(writer, view);
            try writer.writeByte('\n');
        },
    }
}

/// The message for a failed `fx usage`, from fx's error name
/// (`usageFailureMessage`, plus the argument path's `invalid arguments`).
pub fn cliFailureMessage(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "InvalidUsageArgs")) return "invalid arguments";
    if (std.mem.eql(u8, code, "HomeNotSet")) return "HOME is not set";
    if (std.mem.eql(u8, code, "DurablePathUnsafe") or std.mem.eql(u8, code, "PrivateStatePermissionsUnsupported")) {
        return "local usage storage is unsafe";
    }
    return "local usage data is unavailable";
}

/// A failed `fx usage`: JSON goes to stdout as one line, text to stderr as
/// `fx usage: <message>`. Exit code 1 either way. (Invalid arguments
/// without `--json` print fx's usage help instead, which fx owns.)
pub fn cliFailure(writer: *Writer, code: []const u8, format: Format) Writer.Error!void {
    const message = cliFailureMessage(code);
    switch (format) {
        .json => {
            try writer.writeAll("{\"kind\":");
            try std.json.Stringify.value("usage", .{}, writer);
            try writer.writeAll(",\"error\":");
            try std.json.Stringify.value(message, .{}, writer);
            try writer.writeAll(",\"code\":");
            try std.json.Stringify.value(code, .{}, writer);
            try writer.writeAll("}\n");
        },
        .text => try writer.print("fx usage: {s}\n", .{message}),
    }
}

fn writeTotalsJson(writer: *Writer, totals: Totals) Writer.Error!void {
    try writer.print(
        "{{\"total_tokens\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":",
        .{ totals.total_tokens, totals.input_tokens, totals.output_tokens, totals.cache_read_tokens, totals.cache_write_tokens },
    );
    if (totals.reasoning_tokens) |reasoning| try writer.print("{d}", .{reasoning}) else try writer.writeAll("null");
    try writer.writeAll(",\"request_count\":");
    if (totals.request_count) |requests| try writer.print("{d}", .{requests}) else try writer.writeAll("null");
    try writer.print(",\"spend\":{d}}}", .{totals.total_cost});
}

/// fx's `encodeTerminalSafe` for the bytes a view can hold. View model names
/// are printable ASCII (report validates them), which pass unchanged; any
/// other byte is escaped as `\xNN`, as fx does for control bytes.
fn writeTerminalSafe(writer: *Writer, raw: []const u8) Writer.Error!void {
    for (raw) |byte| {
        if (byte < 0x20 or byte >= 0x7f) try writer.print("\\x{x:0>2}", .{byte}) else try writer.writeByte(byte);
    }
}

// ---------------------------------------------------------------------------
// fx ask --json and ACP

/// The `fx ask --json` `usage` value: main-agent sums, null when unreported.
pub fn writeAskUsage(writer: *Writer, turn: report.TurnUsage) Writer.Error!void {
    try std.json.Stringify.value(.{ .input_tokens = turn.input_tokens, .output_tokens = turn.output_tokens }, .{}, writer);
}

/// The ACP prompt response `usage` object: camelCase keys, present only
/// when reported.
pub fn writeAcpPromptUsage(writer: *Writer, turn: report.TurnUsage) Writer.Error!void {
    try writer.writeByte('{');
    var first = true;
    inline for (.{
        .{ "inputTokens", turn.input_tokens },
        .{ "outputTokens", turn.output_tokens },
        .{ "cacheReadTokens", turn.cache_read_tokens },
        .{ "cacheWriteTokens", turn.cache_write_tokens },
        .{ "reasoningTokens", turn.reasoning_tokens },
    }) |field| {
        if (field[1]) |value| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("\"{s}\":{d}", .{ field[0], value });
        }
    }
    try writer.writeByte('}');
}

pub const AcpUsageUpdate = struct {
    used: u64,
    size: u64,
    cost: ?f64,
};

/// The ACP `usage_update`, or null when fx sends none: no live context
/// measurement (`used` is the latest call's input plus output) or no known
/// context window. Cost only when the session is complete and finite.
pub fn acpUsageUpdate(session: *const View, live_context_used: ?u64, context_window: ?u64) ?AcpUsageUpdate {
    return .{
        .used = live_context_used orelse return null,
        .size = context_window orelse return null,
        .cost = report.completeCost(session),
    };
}

/// The `session/update` `update` object (`writeUsageUpdate`).
pub fn writeAcpUsageUpdate(writer: *Writer, update: AcpUsageUpdate) Writer.Error!void {
    try writer.print("{{\"sessionUpdate\":\"usage_update\",\"used\":{d},\"size\":{d}", .{ update.used, update.size });
    if (update.cost) |amount| try writer.print(",\"cost\":{{\"amount\":{d},\"currency\":\"USD\"}}", .{amount});
    try writer.writeAll("}");
}

// ---------------------------------------------------------------------------
// Dashboard rows

/// The three styles the dashboard uses. fx maps them to
/// `selected_completion_style`, `dim_style`, and `system_notice_label_style`.
pub const Style = enum { title, dim, label };

pub const Op = union(enum) {
    style: Style,
    reset,
    text: []const u8,
    spaces: usize,
};

/// fx's escape codes for the painter.
pub const Palette = struct {
    title: []const u8,
    dim: []const u8,
    label: []const u8,
    reset: []const u8,
};

/// Most model rows the dashboard shows.
pub const max_model_rows: usize = 20;

/// The usage hint row, widest first (`composeCompactCommandMenuHintRow`).
pub const hint_variants = [_][]const u8{
    "tab scope     ↑↓ model     enter expand     r refresh     esc close",
    "tab scope  ↑↓ model  enter expand  r refresh  esc",
    "tab ↑↓  enter  r  esc",
};

/// What the dashboard shows (fx's `UsageMenuProjection`).
pub const Dashboard = struct {
    /// The active tab: the view's scope when there is a view, otherwise the
    /// scope being loaded (`usage_menu.State.scope`).
    scope: Scope = .days_30,
    view: ?*const View = null,
    /// A refresh failed: with a view it shows "Refresh failed", without one
    /// "Usage unavailable".
    refresh_failed: bool = false,
    selected_model: usize = 0,
    expanded_model: ?usize = null,
    model_window_start: usize = 0,
};

/// One dashboard row. Fill with `dashboardRow` and read with `ops`; the text
/// ops point into the row, so read them before the row moves.
pub const Row = struct {
    entries: [max_ops]Entry = undefined,
    len: usize = 0,
    bytes: [text_capacity]u8 = undefined,
    bytes_len: usize = 0,
    /// Visible columns written so far.
    column: usize = 0,
    clip: ?Clip = null,

    const max_ops = 48;
    // One model name, escaped at most four bytes per byte, plus small cells.
    const text_capacity = report.max_model_bytes * 4 + 1024;

    const Entry = union(enum) {
        style: Style,
        reset,
        text: struct { start: usize, len: usize },
        spaces: usize,
    };

    const Clip = struct { remaining: usize, cut: bool };

    pub fn count(self: *const Row) usize {
        return self.len;
    }

    pub fn op(self: *const Row, index: usize) Op {
        return switch (self.entries[index]) {
            .style => |value| .{ .style = value },
            .reset => .reset,
            .text => |span| .{ .text = self.bytes[span.start..][0..span.len] },
            .spaces => |n| .{ .spaces = n },
        };
    }

    /// The row's bytes with fx's escape codes: what fx's compose functions
    /// return for this row.
    pub fn paint(self: *const Row, writer: *Writer, palette: Palette) Writer.Error!void {
        for (0..self.len) |index| switch (self.op(index)) {
            .style => |value| try writer.writeAll(switch (value) {
                .title => palette.title,
                .dim => palette.dim,
                .label => palette.label,
            }),
            .reset => try writer.writeAll(palette.reset),
            .text => |bytes| try writer.writeAll(bytes),
            .spaces => |n| try writer.splatByteAll(' ', n),
        };
    }

    fn push(self: *Row, entry: Entry) void {
        std.debug.assert(self.len < max_ops);
        self.entries[self.len] = entry;
        self.len += 1;
    }

    fn dropped(self: *const Row) bool {
        return if (self.clip) |clip| clip.cut else false;
    }

    fn style(self: *Row, value: Style) void {
        if (!self.dropped()) self.push(.{ .style = value });
    }

    fn reset(self: *Row) void {
        if (!self.dropped()) self.push(.reset);
    }

    /// Writes text, clipped by an open clip region.
    fn text(self: *Row, value: []const u8) void {
        if (self.dropped()) return;
        var shown = value;
        if (self.clip) |*clip| {
            const cells = cellCount(value);
            if (cells > clip.remaining) {
                shown = prefixCells(value, clip.remaining);
                clip.cut = true;
            }
            clip.remaining -= cellCount(shown);
        }
        if (shown.len == 0) return;
        std.debug.assert(self.bytes_len + shown.len <= text_capacity);
        @memcpy(self.bytes[self.bytes_len..][0..shown.len], shown);
        self.push(.{ .text = .{ .start = self.bytes_len, .len = shown.len } });
        self.bytes_len += shown.len;
        self.column += cellCount(shown);
    }

    /// `row_text.appendClipped` over everything until `endClip`: escapes pass
    /// through until the first cell that does not fit, then nothing does.
    fn beginClip(self: *Row, width: usize) void {
        self.clip = .{ .remaining = width, .cut = width == 0 };
    }

    fn endClip(self: *Row) void {
        self.clip = null;
    }

    fn clipped(self: *Row, value: []const u8, width: usize) void {
        self.beginClip(width);
        self.text(value);
        self.endClip();
    }

    /// `row_text.appendSingleLineEllipsized`: trailing `…` when it does not fit.
    fn ellipsized(self: *Row, value: []const u8, width: usize) void {
        if (width == 0) return;
        if (cellCount(value) <= width) return self.text(value);
        if (width == 1) return self.text("…");
        self.text(prefixCells(value, width - 1));
        self.text("…");
    }

    /// `row_text.appendSpacesToColumn`.
    fn padTo(self: *Row, target: usize) void {
        if (self.column >= target) return;
        self.spaces(target - self.column);
    }

    fn spaces(self: *Row, n: usize) void {
        if (n == 0) return;
        self.push(.{ .spaces = n });
        self.column += n;
    }
};

/// Display cells of dashboard text. Every character the dashboard writes
/// (printable ASCII, `·`, `❯`, `…`, `↑↓`) is one cell wide in fx.
fn cellCount(text: []const u8) usize {
    var cells: usize = 0;
    for (text) |byte| {
        if (byte & 0xc0 != 0x80) cells += 1;
    }
    return cells;
}

fn prefixCells(text: []const u8, cells: usize) []const u8 {
    var seen: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte & 0xc0 != 0x80) {
            if (seen == cells) return text[0..index];
            seen += 1;
        }
    }
    return text;
}

/// Rows the dashboard wants at this width (`desiredRowCount`).
pub fn dashboardDesiredRows(dashboard: Dashboard, width: u16) u16 {
    const view = dashboard.view orelse return 2;
    if (view.totals == null) return 2 + @as(u16, if (view.session_activity != null) 3 else 0);
    const model_rows = @min(view.models.len, max_model_rows) + @intFromBool(dashboard.expanded_model != null);
    const wanted = layoutFor(view, width).model_start + @max(model_rows, 1);
    return std.math.cast(u16, wanted) orelse std.math.maxInt(u16);
}

/// Model rows visible in `visible_rows` (`usageVisibleModelItems`), for
/// keeping the selection on screen.
pub fn dashboardVisibleModelItems(dashboard: Dashboard, visible_rows: u16, width: u16) u16 {
    const view = dashboard.view orelse return 0;
    if (view.models.len == 0 or view.totals == null) return 0;
    const model_start: usize = if (visible_rows == 1) 0 else blk: {
        const natural = layoutFor(view, width).model_start;
        break :blk if (visible_rows < natural + 1) constrainedModelStart(visible_rows) else natural;
    };
    const area = @as(usize, visible_rows) -| model_start;
    if (area == 0) return 0;
    return @intCast(@min(view.models.len, max_model_rows, @max(area -| @intFromBool(dashboard.expanded_model != null), 1)));
}

/// The usage hint row (`composeCompactCommandMenuHintRow`).
pub fn dashboardHintRow(row: *Row, width: u16) void {
    row.* = .{};
    var hint = hint_variants[hint_variants.len - 1];
    for (hint_variants) |candidate| {
        if (cellCount(candidate) <= width) {
            hint = candidate;
            break;
        }
    }
    row.style(.dim);
    row.clipped(hint, width);
    row.reset();
}

/// Fills `row` with dashboard row `row_index` of `visible_rows` at `width`
/// (`composeCompactCommandMenuRow` for the usage menu). Empty rows have no ops.
pub fn dashboardRow(row: *Row, dashboard: Dashboard, row_index: u16, visible_rows: u16, width: u16) void {
    row.* = .{};
    if (width == 0 or row_index >= visible_rows) return;
    if (visible_rows == 1) return priorityRow(row, dashboard, width);
    if (row_index == 0) return headerRow(row, dashboard.scope, width);
    const view = dashboard.view orelse {
        if (row_index == 1) styledRow(row, if (dashboard.refresh_failed) "Usage unavailable · press r to retry" else "Loading usage", width, .dim);
        return;
    };
    if (view.totals == null) {
        if (row_index == 1) return statusRow(row, dashboard, view, width);
        const activity = view.session_activity orelse return;
        _ = activityRow(row, activity, row_index, 2, width);
        return;
    }
    const layout = layoutFor(view, width);
    if (visible_rows < layout.model_start + 1) return constrainedRow(row, dashboard, view, row_index, visible_rows, width);
    if (row_index == 1) return statusRow(row, dashboard, view, width);
    if (row_index >= layout.overview_start and row_index < layout.overview_start + layout.overview_rows) {
        return overviewRow(row, view.totals.?, layout.overview_mode, row_index - layout.overview_start, width);
    }
    if (layout.activity_start) |activity_start| {
        if (activityRow(row, view.session_activity.?, row_index, activity_start, width)) return;
    }
    if (row_index == layout.models_header) return modelsHeaderRow(row, view.models.len, width);
    if (layout.model_columns) |column_row| {
        if (row_index == column_row) {
            const columns = modelColumns(view, width) orelse return;
            return modelColumnsRow(row, "Model", "Tokens", "Share", "Spend", false, columns, width);
        }
    }
    if (row_index < layout.model_start) return;
    if (view.models.len == 0) {
        if (row_index == layout.model_start) styledRow(row, "  No model usage in this scope.", width, .dim);
        return;
    }
    modelRow(row, dashboard, view, @as(usize, row_index) - layout.model_start, @as(usize, visible_rows) -| layout.model_start, width);
}

fn styledRow(row: *Row, value: []const u8, width: u16, style: Style) void {
    row.style(style);
    row.ellipsized(value, width);
    row.reset();
}

/// One visible row: the first model, or the status.
fn priorityRow(row: *Row, dashboard: Dashboard, width: u16) void {
    const view = dashboard.view orelse return styledRow(row, if (dashboard.refresh_failed) "Usage unavailable · press r to retry" else "Loading usage", width, .dim);
    if (view.models.len > 0) return modelRow(row, dashboard, view, 0, 1, width);
    statusRow(row, dashboard, view, width);
}

fn headerRow(row: *Row, active: Scope, width: u16) void {
    var wide_cells: usize = "Usage".len;
    for (Scope.tab_order) |scope| wide_cells += 2 + scope.label().len + @as(usize, if (scope == active) 2 else 0);
    if (width >= 64 and wide_cells <= width) {
        row.style(.title);
        row.text("Usage");
        row.reset();
        for (Scope.tab_order) |scope| {
            row.text("  ");
            tab(row, scope, scope == active);
        }
        return;
    }
    // Narrow: only the active tab, clipped to the width.
    row.beginClip(width);
    row.style(.title);
    row.text("Usage");
    row.reset();
    row.text("  ");
    tab(row, active, true);
    row.endClip();
    row.reset();
}

fn tab(row: *Row, scope: Scope, active: bool) void {
    row.style(if (active) .title else .dim);
    if (active) {
        var buf: [16]u8 = undefined;
        row.text(std.fmt.bufPrint(&buf, "[{s}]", .{scope.label()}) catch unreachable);
    } else {
        row.text(scope.label());
    }
    row.reset();
}

/// The status line, in `fx usage`'s words without the trailing period.
/// Completeness outranks a partial window. Rows too narrow for the full
/// sentence (plus an 8-column margin) get a short form.
fn statusRow(row: *Row, dashboard: Dashboard, view: *const View, width: u16) void {
    var window_buf: [64]u8 = undefined;
    const status: []const u8 = if (dashboard.refresh_failed)
        "Refresh failed · showing previous data"
    else if (view.coverage == .not_started)
        "Tracking has not started"
    else switch (view.completeness) {
        .pending => fitted(width, "Known totals exclude pending Gateway reconciliation", "Pending Gateway reconciliation"),
        .incomplete => "Known totals may be incomplete",
        .legacy => fitted(width, "This session predates complete usage tracking", "Predates usage tracking"),
        .complete => if (view.coverage == .partial) partialWindow(&window_buf, view, width) else "Local fx activity",
    };
    styledRow(row, status, width, .dim);
}

fn fitted(width: u16, full: []const u8, short: []const u8) []const u8 {
    return if (@as(usize, width) >= full.len + 8) full else short;
}

/// `Tracking since Oct 7, 2026 (partial window)`, or `Partial window` when
/// that doesn't fit. Partial coverage always has a start (report invariant).
fn partialWindow(buf: *[64]u8, view: *const View, width: u16) []const u8 {
    var date_buf: [24]u8 = undefined;
    const date = report.formatUtcDate(&date_buf, view.coverage_started_at_ms.?);
    const full = std.fmt.bufPrint(buf, "Tracking since {s} (partial window)", .{date}) catch return "Partial window";
    return fitted(width, full, "Partial window");
}

fn constrainedModelStart(visible_rows: u16) usize {
    if (visible_rows <= 4) return visible_rows -| 1;
    return 4;
}

/// Too few rows for the full layout: status, summary, models header, models.
fn constrainedRow(row: *Row, dashboard: Dashboard, view: *const View, row_index: u16, visible_rows: u16, width: u16) void {
    const model_start = constrainedModelStart(visible_rows);
    if (row_index == 1 and row_index < model_start) return statusRow(row, dashboard, view, width);
    if (row_index == 2 and row_index < model_start) return compactSummaryRow(row, view, width);
    if (row_index == 3 and row_index < model_start) return modelsHeaderRow(row, view.models.len, width);
    if (row_index < model_start) return;
    if (view.models.len == 0) return statusRow(row, dashboard, view, width);
    modelRow(row, dashboard, view, row_index - model_start, visible_rows - model_start, width);
}

fn compactSummaryRow(row: *Row, view: *const View, width: u16) void {
    const totals = view.totals orelse return styledRow(row, "Usage unavailable", width, .dim);
    var token_buf: [32]u8 = undefined;
    var spend_buf: [32]u8 = undefined;
    var buf: [96]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "{s} tokens · {s}", .{ formatCompact(&token_buf, totals.total_tokens), formatMoney(&spend_buf, totals.total_cost) }) catch "Usage summary unavailable";
    styledRow(row, summary, width, .dim);
}

/// Session activity rows at `start`; false when `row_index` is not one.
fn activityRow(row: *Row, activity: report.SessionActivity, row_index: u16, start: usize, width: u16) bool {
    if (row_index == start) {
        styledRow(row, "Session activity", width, .label);
        return true;
    }
    var api_buf: [32]u8 = undefined;
    var wall_buf: [32]u8 = undefined;
    var row_buf: [128]u8 = undefined;
    if (row_index == start + 1) {
        const value = std.fmt.bufPrint(&row_buf, "API {s} · Wall {s}", .{
            if (activity.api_duration_complete) formatDuration(&api_buf, activity.api_duration_ms) else "Unavailable",
            if (activity.wall_duration_complete) formatDuration(&wall_buf, activity.wall_duration_ms) else "Unavailable",
        }) catch "Session timing unavailable";
        styledRow(row, value, width, .dim);
        return true;
    }
    if (row_index == start + 2) {
        const value = if (activity.code_complete)
            std.fmt.bufPrint(&row_buf, "Code +{d} · -{d}", .{ activity.lines_added, activity.lines_removed }) catch "Code activity unavailable"
        else
            "Code activity unavailable";
        styledRow(row, value, width, .dim);
        return true;
    }
    return false;
}

fn modelsHeaderRow(row: *Row, model_count: usize, width: u16) void {
    var buf: [64]u8 = undefined;
    const value = if (width < 48) "Models" else std.fmt.bufPrint(&buf, "Models {d}", .{model_count}) catch "Models";
    styledRow(row, value, width, .label);
}

// Layout

const column_gap: usize = 4;

const OverviewMode = enum { wide, medium, narrow };
const ModelMode = enum { columns, facts, compact, name_only };

const Layout = struct {
    overview_mode: OverviewMode,
    overview_start: usize,
    overview_rows: usize,
    activity_start: ?usize,
    models_header: usize,
    model_columns: ?usize,
    model_start: usize,
};

const OverviewColumns = struct { second: usize, third: usize };
const ModelColumns = struct { token: usize, share: usize, spend: usize };

fn layoutFor(view: *const View, width: u16) Layout {
    const totals = view.totals.?;
    const overview_mode: OverviewMode = if (width >= 110 and overviewColumns(totals, width) != null)
        .wide
    else if (width >= 48)
        .medium
    else
        .narrow;
    const overview_start: usize = if (overview_mode == .narrow) 2 else 3;
    const overview_rows: usize = if (overview_mode == .narrow) 2 else 3;
    var cursor = overview_start + overview_rows;
    var activity_start: ?usize = null;
    if (view.session_activity != null) {
        if (overview_mode != .narrow) cursor += 1;
        activity_start = cursor;
        cursor += 3;
    }
    if (overview_mode != .narrow) cursor += 1;
    const models_header = cursor;
    cursor += 1;
    const model_columns: ?usize = if (modelModeFor(view, width) == .columns) blk: {
        cursor += 1;
        break :blk cursor - 1;
    } else null;
    return .{
        .overview_mode = overview_mode,
        .overview_start = overview_start,
        .overview_rows = overview_rows,
        .activity_start = activity_start,
        .models_header = models_header,
        .model_columns = model_columns,
        .model_start = cursor,
    };
}

const Cells = struct {
    first: [64]u8 = undefined,
    second: [64]u8 = undefined,
    third: [64]u8 = undefined,

    fn get(self: *Cells, totals: Totals, mode: OverviewMode, index: usize) [3][]const u8 {
        if (mode == .narrow) return switch (index) {
            0 => .{ formatTokenLabel(&self.first, totals.total_tokens, "tokens"), formatMoney(&self.second, totals.total_cost), "" },
            else => .{ formatRequestLabel(&self.third, totals.request_count), "", "" },
        };
        return switch (index) {
            0 => .{
                formatTokenLabel(&self.first, totals.total_tokens, "tokens"),
                formatMoneyLabel(&self.second, totals.total_cost, "spent"),
                formatRequestLabel(&self.third, totals.request_count),
            },
            1 => .{
                formatTokenLabel(&self.first, totals.input_tokens, "input"),
                formatTokenLabel(&self.second, totals.output_tokens, "output"),
                if (totals.reasoning_tokens) |value| formatTokenLabel(&self.third, value, "reasoning") else "Reasoning unavailable",
            },
            else => .{
                formatTokenLabel(&self.first, totals.cache_read_tokens, "cache read"),
                formatTokenLabel(&self.second, totals.cache_write_tokens, "cache write"),
                "",
            },
        };
    }
};

fn overviewColumns(totals: Totals, width: u16) ?OverviewColumns {
    var widths = [3]usize{ 0, 0, 0 };
    for (0..3) |index| {
        var cells: Cells = .{};
        for (cells.get(totals, .wide, index), &widths) |cell, *widest| widest.* = @max(widest.*, cellCount(cell));
    }
    const indent: usize = if (width <= 2) 0 else 2;
    const second = indent + widths[0] + column_gap;
    const third = second + widths[1] + column_gap;
    if (third + widths[2] > width) return null;
    return .{ .second = second, .third = third };
}

fn overviewRow(row: *Row, totals: Totals, mode: OverviewMode, index: usize, width: u16) void {
    var cells: Cells = .{};
    const values = cells.get(totals, mode, index);
    if (mode == .wide) {
        const columns = overviewColumns(totals, width).?;
        row.style(.dim);
        if (width > 2) row.text("  ");
        row.ellipsized(values[0], columns.second -| 3);
        row.padTo(columns.second);
        row.ellipsized(values[1], columns.third -| columns.second -| 1);
        if (values[2].len > 0) {
            row.padTo(columns.third);
            row.ellipsized(values[2], @as(usize, width) -| columns.third);
        }
        row.reset();
        return;
    }
    var buf: [192]u8 = undefined;
    const joined = if (values[2].len > 0)
        std.fmt.bufPrint(&buf, "{s} · {s} · {s}", .{ values[0], values[1], values[2] }) catch "Usage unavailable"
    else if (values[1].len > 0)
        std.fmt.bufPrint(&buf, "{s} · {s}", .{ values[0], values[1] }) catch "Usage unavailable"
    else
        values[0];
    styledRow(row, joined, width, .dim);
}

fn modelModeFor(view: *const View, width: u16) ModelMode {
    if (width >= 110 and modelColumns(view, width) != null) return .columns;
    if (width >= 48 and infoColumn(view, width, true) != null) return .facts;
    if (infoColumn(view, width, false) != null) return .compact;
    return .name_only;
}

fn safeCells(name: []const u8) usize {
    var cells: usize = 0;
    for (name) |byte| cells += if (byte < 0x20 or byte >= 0x7f) 4 else 1;
    return cells;
}

fn modelColumns(view: *const View, width: u16) ?ModelColumns {
    const indent: usize = if (width <= 2) 0 else 2;
    var longest_model: usize = "Model".len;
    var token_width: usize = "Tokens".len;
    var share_width: usize = "Share".len;
    var spend_width: usize = "Spend".len;
    const total = view.totals.?.total_tokens;
    for (view.models) |model| {
        longest_model = @max(longest_model, safeCells(model.model));
        var token_buf: [32]u8 = undefined;
        var share_buf: [32]u8 = undefined;
        var spend_buf: [32]u8 = undefined;
        token_width = @max(token_width, cellCount(formatCompact(&token_buf, model.totals.total_tokens)));
        share_width = @max(share_width, cellCount(formatShare(&share_buf, model.totals.total_tokens, total)));
        spend_width = @max(spend_width, cellCount(formatMoney(&spend_buf, model.totals.total_cost)));
    }
    const fixed = column_gap * 3 + token_width + share_width + spend_width;
    const minimum_name: usize = 10;
    if (@as(usize, width) < indent + minimum_name + fixed) return null;
    const name_width = @min(longest_model, @as(usize, width) - indent - fixed);
    const token = indent + name_width + column_gap;
    const share = token + token_width + column_gap;
    const spend = share + share_width + column_gap;
    return .{ .token = token, .share = share, .spend = spend };
}

fn infoColumn(view: *const View, width: u16, include_share: bool) ?usize {
    const indent: usize = if (width <= 2) 0 else 2;
    var longest_model: usize = 0;
    var widest_info: usize = 0;
    for (view.models) |model| {
        longest_model = @max(longest_model, safeCells(model.model));
        var info_buf: [128]u8 = undefined;
        widest_info = @max(widest_info, cellCount(formatFacts(&info_buf, model, view.totals.?.total_tokens, include_share)));
    }
    if (widest_info == 0 or @as(usize, width) < indent + 8 + column_gap + widest_info) return null;
    return @min(indent + longest_model + column_gap, @as(usize, width) - widest_info);
}

fn modelRow(row: *Row, dashboard: Dashboard, view: *const View, display_row: usize, visible_rows: usize, width: u16) void {
    const models = view.models;
    const selected = @min(dashboard.selected_model, models.len - 1);
    const visible_models = @min(models.len, max_model_rows, @max(visible_rows -| @intFromBool(dashboard.expanded_model != null), 1));
    const max_start = models.len -| visible_models;
    const selection_start = selected -| (visible_models - 1);
    const start = @min(@max(@min(dashboard.model_window_start, selected), selection_start), max_start);
    var logical_row: usize = 0;
    var index = start;
    while (index < models.len) : (index += 1) {
        if (logical_row == display_row) return modelSummaryRow(row, view, models[index], index == selected, width);
        logical_row += 1;
        if (dashboard.expanded_model == index) {
            if (logical_row == display_row) {
                var detail_buf: [256]u8 = undefined;
                return styledRow(row, formatDetail(&detail_buf, models[index].totals), width, .dim);
            }
            logical_row += 1;
        }
        if (logical_row > display_row) return;
    }
}

fn modelSummaryRow(row: *Row, view: *const View, model: ModelUsage, selected: bool, width: u16) void {
    var name_buf: [report.max_model_bytes * 4]u8 = undefined;
    const name = escapeName(&name_buf, model.model);
    const mode = modelModeFor(view, width);
    const total = view.totals.?.total_tokens;
    if (mode == .columns) {
        var token_buf: [32]u8 = undefined;
        var share_buf: [32]u8 = undefined;
        var spend_buf: [32]u8 = undefined;
        return modelColumnsRow(
            row,
            name,
            formatCompact(&token_buf, model.totals.total_tokens),
            formatShare(&share_buf, model.totals.total_tokens, total),
            formatMoney(&spend_buf, model.totals.total_cost),
            selected,
            modelColumns(view, width).?,
            width,
        );
    }
    const include_share = mode == .facts;
    var info_buf: [128]u8 = undefined;
    const info = formatFacts(&info_buf, model, total, include_share);
    actionRow(row, name, if (mode == .name_only) "" else info, selected, infoColumn(view, width, include_share), width);
}

fn escapeName(buf: *[report.max_model_bytes * 4]u8, name: []const u8) []const u8 {
    std.debug.assert(name.len <= report.max_model_bytes);
    var writer: Writer = .fixed(buf);
    writeTerminalSafe(&writer, name) catch unreachable;
    return writer.buffered();
}

fn modelColumnsRow(row: *Row, name: []const u8, tokens: []const u8, share: []const u8, spend: []const u8, selected: bool, columns: ModelColumns, width: u16) void {
    row.style(if (selected) .label else .dim);
    row.clipped(if (selected) "❯ " else "  ", width);
    const used = row.column;
    row.ellipsized(name, columns.token -| used -| 1);
    row.reset();
    row.padTo(columns.token);
    row.style(.dim);
    row.ellipsized(tokens, columns.share -| columns.token -| 1);
    row.padTo(columns.share);
    row.ellipsized(share, columns.spend -| columns.share -| 1);
    row.padTo(columns.spend);
    row.ellipsized(spend, @as(usize, width) -| columns.spend);
    row.reset();
}

/// A model name with its facts in a column (`composeWorkspaceActionRow`).
fn actionRow(row: *Row, label: []const u8, info: []const u8, selected: bool, info_column: ?usize, width: u16) void {
    row.style(if (selected) .label else .dim);
    row.clipped(if (selected) "❯ " else "  ", width);
    const used_prefix = row.column;
    const total_width: usize = width;
    if (used_prefix >= total_width) return row.reset();
    const info_start = info_column orelse {
        row.ellipsized(label, total_width - used_prefix);
        return row.reset();
    };
    if (info_start <= used_prefix + 2) {
        row.ellipsized(label, total_width - used_prefix);
        return row.reset();
    }
    row.ellipsized(label, info_start - used_prefix - 1);
    row.reset();
    if (row.column >= info_start) return;
    row.spaces(info_start - row.column);
    row.style(.dim);
    row.ellipsized(info, total_width - info_start);
    row.reset();
}

// Formats, each into the buffer size fx uses, with fx's fallback text.

fn formatFacts(buf: *[128]u8, model: ModelUsage, total_tokens: u64, include_share: bool) []const u8 {
    var token_buf: [32]u8 = undefined;
    var share_buf: [32]u8 = undefined;
    var spend_buf: [32]u8 = undefined;
    const tokens = formatCompact(&token_buf, model.totals.total_tokens);
    const spend = formatMoney(&spend_buf, model.totals.total_cost);
    return if (include_share)
        std.fmt.bufPrint(buf, "{s} · {s} · {s}", .{ tokens, formatShare(&share_buf, model.totals.total_tokens, total_tokens), spend }) catch "Unavailable"
    else
        std.fmt.bufPrint(buf, "{s} · {s}", .{ tokens, spend }) catch "Unavailable";
}

fn formatDetail(buf: *[256]u8, totals: Totals) []const u8 {
    var input_buf: [32]u8 = undefined;
    var output_buf: [32]u8 = undefined;
    var read_buf: [32]u8 = undefined;
    var write_buf: [32]u8 = undefined;
    var reasoning_buf: [32]u8 = undefined;
    var request_buf: [32]u8 = undefined;
    var spend_buf: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "Input {s} · Output {s} · Cache {s}/{s} · Reasoning {s} · Requests {s} · {s}", .{
        formatCompact(&input_buf, totals.input_tokens),
        formatCompact(&output_buf, totals.output_tokens),
        formatCompact(&read_buf, totals.cache_read_tokens),
        formatCompact(&write_buf, totals.cache_write_tokens),
        if (totals.reasoning_tokens) |value| formatCompact(&reasoning_buf, value) else "n/a",
        if (totals.request_count) |value| formatGrouped(&request_buf, value) else "n/a",
        formatMoney(&spend_buf, totals.total_cost),
    }) catch "Usage details unavailable";
}

fn formatTokenLabel(buf: *[64]u8, value: u64, label: []const u8) []const u8 {
    var value_buf: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ formatCompact(&value_buf, value), label }) catch "Unavailable";
}

fn formatMoneyLabel(buf: *[64]u8, value: f64, label: []const u8) []const u8 {
    var value_buf: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ formatMoney(&value_buf, value), label }) catch "Unavailable";
}

fn formatRequestLabel(buf: *[64]u8, value: ?u64) []const u8 {
    const requests = value orelse return "Requests unavailable";
    var value_buf: [32]u8 = undefined;
    // "1 request", "0 requests": today's plural rule.
    return std.fmt.bufPrint(buf, "{s} {s}", .{ formatGrouped(&value_buf, requests), if (requests == 1) "request" else "requests" }) catch "Requests unavailable";
}

/// `1.5K`, `43.6M`, `1B`; whole multiples drop the decimal.
fn formatCompact(buf: *[32]u8, value: u64) []const u8 {
    const units = [_]struct { value: u64, suffix: []const u8 }{
        .{ .value = 1_000_000_000, .suffix = "B" },
        .{ .value = 1_000_000, .suffix = "M" },
        .{ .value = 1_000, .suffix = "K" },
    };
    for (units) |unit| {
        if (value < unit.value) continue;
        if (value % unit.value == 0) return std.fmt.bufPrint(buf, "{d}{s}", .{ value / unit.value, unit.suffix }) catch "?";
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(unit.value)), unit.suffix }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "?";
}

/// `1,234`.
fn formatGrouped(buf: *[32]u8, value: u64) []const u8 {
    var cursor = buf.len;
    var remaining = value;
    var digits: usize = 0;
    while (true) {
        if (digits > 0 and digits % 3 == 0) {
            cursor -= 1;
            buf[cursor] = ',';
        }
        cursor -= 1;
        buf[cursor] = @intCast('0' + remaining % 10);
        remaining /= 10;
        digits += 1;
        if (remaining == 0) break;
    }
    return buf[cursor..];
}

/// `$x.xx`, or `$?` when it does not fit the buffer.
fn formatMoney(buf: []u8, value: f64) []const u8 {
    return std.fmt.bufPrint(buf, "${d:.2}", .{value}) catch "$?";
}

fn formatShare(buf: *[32]u8, tokens: u64, total_tokens: u64) []const u8 {
    const share = if (total_tokens == 0) 0.0 else @as(f64, @floatFromInt(tokens)) * 100.0 / @as(f64, @floatFromInt(total_tokens));
    return std.fmt.bufPrint(buf, "{d:.1}%", .{share}) catch "?%";
}

/// `1h 2m 3s`, `2m 3s`, `3s`.
fn formatDuration(buf: *[32]u8, duration_ms: u64) []const u8 {
    const total_seconds = duration_ms / 1000;
    const hours = total_seconds / 3600;
    const minutes = (total_seconds % 3600) / 60;
    const seconds = total_seconds % 60;
    if (hours > 0) return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ hours, minutes, seconds }) catch "Unavailable";
    if (minutes > 0) return std.fmt.bufPrint(buf, "{d}m {d}s", .{ minutes, seconds }) catch "Unavailable";
    return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "Unavailable";
}

// ---------------------------------------------------------------------------
// Dashboard selection (`usage_menu.State`)

/// Which model row is selected and expanded, and the first visible one.
pub const Selection = struct {
    selected_model: usize = 0,
    expanded_model: ?usize = null,
    model_window_start: usize = 0,

    /// After a refresh: keep the selected and expanded models by name when
    /// they still exist (`replaceOwned`).
    pub fn retain(self: Selection, old: ?*const View, new: *const View) Selection {
        const old_selected: ?[]const u8 = if (old) |view|
            if (view.models.len > 0) view.models[@min(self.selected_model, view.models.len - 1)].model else null
        else
            null;
        const old_expanded: ?[]const u8 = if (old) |view|
            if (self.expanded_model) |index| (if (index < view.models.len) view.models[index].model else null) else null
        else
            null;
        const selected = findModel(new.models, old_selected) orelse @min(self.selected_model, new.models.len -| 1);
        return .{
            .selected_model = selected,
            .expanded_model = findModel(new.models, old_expanded),
            .model_window_start = @min(self.model_window_start, selected),
        };
    }

    /// Up (`-1`) or Down (`+1`). False when nothing moved (`moveModel`).
    pub fn move(self: *Selection, delta: i32, model_count: usize, visible_model_rows: usize) bool {
        if (delta == 0 or model_count == 0) return false;
        const next = if (delta > 0) @min(self.selected_model +| 1, model_count - 1) else self.selected_model -| 1;
        if (next == self.selected_model) return false;
        self.selected_model = next;
        self.keepVisible(visible_model_rows);
        return true;
    }

    /// Enter: expand or collapse the selected model (`toggleExpanded`).
    pub fn toggleExpanded(self: *Selection, model_count: usize, visible_model_rows: usize) bool {
        if (model_count == 0) return false;
        const selected = @min(self.selected_model, model_count - 1);
        self.expanded_model = if (self.expanded_model == selected) null else selected;
        self.keepVisible(visible_model_rows);
        return true;
    }

    fn keepVisible(self: *Selection, visible_model_rows: usize) void {
        const visible = @max(visible_model_rows, 1);
        if (self.selected_model < self.model_window_start) {
            self.model_window_start = self.selected_model;
        } else if (self.selected_model >= self.model_window_start +| visible) {
            self.model_window_start = self.selected_model - (visible - 1);
        }
    }
};

fn findModel(models: []const ModelUsage, target: ?[]const u8) ?usize {
    const name = target orelse return null;
    for (models, 0..) |model, index| {
        if (std.mem.eql(u8, model.model, name)) return index;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const record = @import("codec/record.zig");
const snapshot_codec = @import("codec/snapshot.zig");

/// Captured from an fx binary that predates this module.
const testdata = struct {
    const ledger_final = @embedFile("testdata/u07/ledger-final.jsonl");
    const ledger_torn = @embedFile("testdata/u07/ledger-torn.jsonl");

    const V1Session = struct { id: []const u8, sidecar: []const u8, session: []const u8, marker: []const u8 };
    const v1_sessions = [_]V1Session{
        .{ .id = "-0mOs2ToHDxY", .sidecar = @embedFile("testdata/u07/sidecar--0mOs2ToHDxY.json"), .session = @embedFile("testdata/u07/session--0mOs2ToHDxY.json"), .marker = @embedFile("testdata/u07/marker-v1--0mOs2ToHDxY") },
        .{ .id = "7elup-r3q_tk", .sidecar = @embedFile("testdata/u07/sidecar-7elup-r3q_tk.json"), .session = @embedFile("testdata/u07/session-7elup-r3q_tk.json"), .marker = @embedFile("testdata/u07/marker-v1-7elup-r3q_tk") },
        .{ .id = "Cn0Q2_7cxZ_z", .sidecar = @embedFile("testdata/u07/sidecar-Cn0Q2_7cxZ_z.json"), .session = @embedFile("testdata/u07/session-Cn0Q2_7cxZ_z.json"), .marker = @embedFile("testdata/u07/marker-v1-Cn0Q2_7cxZ_z") },
    };
    const v2_value = @embedFile("testdata/u07/v2-9765RiSMBar-.json");
    const v2_marker = @embedFile("testdata/u07/marker-v2-9765RiSMBar-");

    const Run = struct { scope: Scope, text: []const u8, json: []const u8 };
    fn runs(comptime phase: []const u8) [3]Run {
        return .{
            .{ .scope = .hours_24, .text = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_24h.text.stdout"), .json = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_24h.json.stdout") },
            .{ .scope = .days_7, .text = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_7d.text.stdout"), .json = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_7d.json.stdout") },
            .{ .scope = .days_30, .text = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_30d.text.stdout"), .json = @embedFile("testdata/u07/cli/" ++ phase ++ ".usage_30d.json.stdout") },
        };
    }
    const torn_json = @embedFile("testdata/u07/cli/torn.usage_30d.json.stdout");
    const torn_text_stderr = @embedFile("testdata/u07/cli/torn.usage_30d.text.stderr");
};

/// The `snapshot_time_ms` fx stamped on a captured JSON run. The text run
/// just before it is not stamped; the test renders it at the same time.
fn capturedTime(json: []const u8) !i64 {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    return parsed.value.object.get("snapshot_time_ms").?.integer;
}

fn expectOutput(view: *const View, format: Format, want: []const u8) !void {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try cliOutput(&out.writer, view, format);
    try testing.expectEqualStrings(want, out.written());
}

fn expectRuns(ledger: report.LedgerContents, recovery: report.Recovery, runs: [3]testdata.Run) !void {
    for (runs) |run| {
        const now = try capturedTime(run.json);
        var view = try report.rollingView(testing.allocator, ledger, recovery, run.scope, now, .{});
        defer view.deinit(testing.allocator);
        try expectOutput(&view, .json, run.json);
        try expectOutput(&view, .text, run.text);
    }
}

fn wholeLines(bytes: []const u8) []const u8 {
    return bytes[0 .. (std.mem.lastIndexOfScalar(u8, bytes, '\n') orelse return bytes[0..0]) + 1];
}

test "golden: fx usage after every call settled, from the ledger as it was then" {
    // The torn-tail input is the ledger fx read for these runs plus the
    // planted torn tail (capture.ts writes it right after them).
    var ledger = try report.ProfileLedger.load(testing.allocator, wholeLines(testdata.ledger_torn));
    defer ledger.deinit(testing.allocator);
    try expectRuns(ledger.contents(), .{}, testdata.runs("complete"));
}

fn collectFinalRecovery(collector: *report.RecoveryCollector, v1_newer: ?bool) !void {
    const alloc = testing.allocator;
    for (testdata.v1_sessions) |session| {
        var sidecar = try snapshot_codec.parseSidecar(alloc, session.sidecar);
        defer sidecar.deinit(alloc);
        try testing.expectEqualStrings(session.id, sidecar.session_id);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, session.session, .{});
        defer parsed.deinit();
        const updated_at_ms = parsed.value.object.get("updated_at_ms").?.integer;
        const protected = try record.parseMarker(session.marker);
        // The capture did not keep file times, so v1 freshness is given:
        // null means "use the update time", as fx does without a sidecar time.
        const newer = v1_newer orelse report.v1CheckpointIsNewer(&sidecar.snapshot, updated_at_ms, null, 0, protected);
        try collector.addSession(alloc, &sidecar.snapshot, updated_at_ms, newer);
    }
    var v2 = try snapshot_codec.parseV2Value(alloc, testdata.v2_value);
    defer v2.deinit(alloc);
    const protected = try record.parseMarker(testdata.v2_marker);
    try collector.addSession(alloc, &v2.snapshot, v2.at_ms, report.v2CheckpointIsNewer(&v2.snapshot, v2.at_ms, protected));
}

test "golden: fx usage at the end, from the ledger, three v1 sidecars, and one v2 checkpoint" {
    var ledger = try report.ProfileLedger.load(testing.allocator, testdata.ledger_final);
    defer ledger.deinit(testing.allocator);
    // Every freshness outcome gives the same bytes: the ledger's incidents
    // already make each window incomplete.
    for ([_]?bool{ null, true, false }) |newer| {
        var collector: report.RecoveryCollector = .{};
        defer collector.deinit(testing.allocator);
        try collectFinalRecovery(&collector, newer);
        try testing.expectEqual(@as(usize, 1), collector.facts.items.len);
        try expectRuns(ledger.contents(), collector.recovery(), testdata.runs("final"));
    }
}

test "golden: the final views also count what is unpriced" {
    var ledger = try report.ProfileLedger.load(testing.allocator, testdata.ledger_final);
    defer ledger.deinit(testing.allocator);
    var collector: report.RecoveryCollector = .{};
    defer collector.deinit(testing.allocator);
    try collectFinalRecovery(&collector, null);
    const now = try capturedTime(testdata.runs("final")[0].json);
    var view = try report.rollingView(testing.allocator, ledger.contents(), collector.recovery(), .hours_24, now, .{});
    defer view.deinit(testing.allocator);
    // Unresolved markers: the v1 and v2 401 lookups and the grok fact held
    // by the lock. No receipt: the torn-tail repair and the no-id call
    // (ledger incidents) and the lock-held no-id call (its sidecar).
    try testing.expectEqual(report.Unpriced.fromCounts(3, 0, 3), view.unpriced);
}

test "golden: a torn ledger fails fx usage exactly like fx" {
    try testing.expectError(error.UsageStoreIncomplete, report.ProfileLedger.load(testing.allocator, testdata.ledger_torn));
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try cliFailure(&out.writer, @errorName(error.UsageStoreIncomplete), .json);
    try testing.expectEqualStrings(testdata.torn_json, out.written());
    out.clearRetainingCapacity();
    try cliFailure(&out.writer, @errorName(error.UsageStoreIncomplete), .text);
    try testing.expectEqualStrings(testdata.torn_text_stderr, out.written());
}

test "cli failure messages follow fx" {
    try testing.expectEqualStrings("HOME is not set", cliFailureMessage("HomeNotSet"));
    try testing.expectEqualStrings("local usage storage is unsafe", cliFailureMessage("DurablePathUnsafe"));
    try testing.expectEqualStrings("local usage storage is unsafe", cliFailureMessage("PrivateStatePermissionsUnsupported"));
    try testing.expectEqualStrings("local usage data is unavailable", cliFailureMessage("InvalidUsageStore"));
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try cliFailure(&out.writer, "InvalidUsageArgs", .json);
    try testing.expectEqualStrings("{\"kind\":\"usage\",\"error\":\"invalid arguments\",\"code\":\"InvalidUsageArgs\"}\n", out.written());
}

fn testTotals(tokens: u64, cost: f64) Totals {
    return .{ .total_tokens = tokens, .input_tokens = tokens, .output_tokens = 0, .cache_read_tokens = 0, .cache_write_tokens = 0, .reasoning_tokens = null, .request_count = 1, .total_cost = cost };
}

test "every coverage and completeness line in fx usage text" {
    var models = [_]ModelUsage{.{ .model = "p/\"quoted\\name", .totals = testTotals(5, 0.00005) }};
    var view: View = .{
        .scope = .days_7,
        .snapshot_time_ms = 1791399023442,
        .window_start_ms = 1790794223442,
        .coverage_started_at_ms = null,
        .coverage = .not_started,
        .completeness = .legacy,
        .totals = null,
        .models = &models,
    };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try cliText(&out.writer, &view);
    try testing.expectEqualStrings("Usage (7 days)\nTracking has not started.\nThis session predates complete usage tracking.\n", out.written());

    out.clearRetainingCapacity();
    view.coverage = .full;
    view.completeness = .pending;
    view.totals = testTotals(5, 0.00005);
    try cliText(&out.writer, &view);
    try testing.expectEqualStrings(
        "Usage (7 days)\nKnown totals exclude pending Gateway reconciliation.\nTotal tokens  5\nInput         5\nOutput        0\nCache         0 read · 0 write\nRequests      1\nSpend         $0.0001\n\nBy model\n- p/\"quoted\\name  5 tokens  $0.0001\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    view.scope = .session;
    try cliJson(&out.writer, &view);
    try testing.expectEqualStrings(
        "{\"kind\":\"usage\",\"schema_version\":1,\"period\":\"session\",\"snapshot_time_ms\":1791399023442,\"window_start_ms\":1790794223442,\"coverage\":{\"status\":\"full\",\"started_at_ms\":null,\"full_window\":true},\"completeness\":\"pending\",\"totals\":{\"total_tokens\":5,\"input_tokens\":5,\"output_tokens\":0,\"cache_read_tokens\":0,\"cache_write_tokens\":0,\"reasoning_tokens\":null,\"request_count\":1,\"spend\":0.00005},\"models\":[{\"model\":\"p/\\\"quoted\\\\name\",\"totals\":{\"total_tokens\":5,\"input_tokens\":5,\"output_tokens\":0,\"cache_read_tokens\":0,\"cache_write_tokens\":0,\"reasoning_tokens\":null,\"request_count\":1,\"spend\":0.00005}}]}",
        out.written(),
    );
}

test "ask and ACP usage projections" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeAskUsage(&out.writer, .{ .input_tokens = 17, .cache_read_tokens = 3 });
    try testing.expectEqualStrings("{\"input_tokens\":17,\"output_tokens\":null}", out.written());

    out.clearRetainingCapacity();
    try writeAcpPromptUsage(&out.writer, .{ .output_tokens = 5, .reasoning_tokens = 1 });
    try testing.expectEqualStrings("{\"outputTokens\":5,\"reasoningTokens\":1}", out.written());
    out.clearRetainingCapacity();
    try writeAcpPromptUsage(&out.writer, .{});
    try testing.expectEqualStrings("{}", out.written());

    var view: View = .{ .scope = .session, .snapshot_time_ms = 1, .window_start_ms = 0, .coverage_started_at_ms = 0, .coverage = .full, .completeness = .complete, .totals = testTotals(8, 0.25), .models = &.{} };
    try testing.expectEqual(@as(?AcpUsageUpdate, null), acpUsageUpdate(&view, null, 128000));
    try testing.expectEqual(@as(?AcpUsageUpdate, null), acpUsageUpdate(&view, 8, null));
    out.clearRetainingCapacity();
    try writeAcpUsageUpdate(&out.writer, acpUsageUpdate(&view, 8, 128000).?);
    try testing.expectEqualStrings("{\"sessionUpdate\":\"usage_update\",\"used\":8,\"size\":128000,\"cost\":{\"amount\":0.25,\"currency\":\"USD\"}}", out.written());
    view.completeness = .pending;
    out.clearRetainingCapacity();
    try writeAcpUsageUpdate(&out.writer, acpUsageUpdate(&view, 8, 128000).?);
    try testing.expectEqualStrings("{\"sessionUpdate\":\"usage_update\",\"used\":8,\"size\":128000}", out.written());
}

test "dashboard number formats" {
    var buf: [32]u8 = undefined;
    const compact = [_]struct { u64, []const u8 }{ .{ 0, "0" }, .{ 999, "999" }, .{ 1000, "1K" }, .{ 1500, "1.5K" }, .{ 43_600_000, "43.6M" }, .{ 1_000_000_000, "1B" }, .{ std.math.maxInt(u64), "18446744073.7B" } };
    for (compact) |case| try testing.expectEqualStrings(case[1], formatCompact(&buf, case[0]));
    try testing.expectEqualStrings("1,234,567", formatGrouped(&buf, 1234567));
    try testing.expectEqualStrings("0", formatGrouped(&buf, 0));
    try testing.expectEqualStrings("$100.79", formatMoney(&buf, 100.789));
    try testing.expectEqualStrings("$?", formatMoney(&buf, 1e40));
    try testing.expectEqualStrings("71.4%", formatShare(&buf, 714, 1000));
    try testing.expectEqualStrings("0.0%", formatShare(&buf, 0, 0));
    try testing.expectEqualStrings("1h 2m 3s", formatDuration(&buf, 3_723_999));
    try testing.expectEqualStrings("2m 0s", formatDuration(&buf, 120_000));
    try testing.expectEqualStrings("0s", formatDuration(&buf, 999));
}

const test_palette: Palette = .{ .title = "<T>", .dim = "<D>", .label = "<L>", .reset = "</>" };

fn paintRow(dashboard: Dashboard, row_index: u16, visible_rows: u16, width: u16) ![]u8 {
    var row: Row = .{};
    dashboardRow(&row, dashboard, row_index, visible_rows, width);
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try row.paint(&out.writer, test_palette);
    return out.toOwnedSlice();
}

fn expectRow(want: []const u8, dashboard: Dashboard, row_index: u16, visible_rows: u16, width: u16) !void {
    const got = try paintRow(dashboard, row_index, visible_rows, width);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "dashboard header keeps today's tab order and narrows to the active tab" {
    const dashboard: Dashboard = .{ .scope = .hours_24 };
    try expectRow("<T>Usage</>  <D>30 days</>  <D>7 days</>  <T>[24 hours]</>  <D>Session</>", dashboard, 0, 2, 80);
    try expectRow("<T>Usage</>  <T>[24 hours]</></>", dashboard, 0, 2, 63);
    try expectRow("<T>Usage</> </>", dashboard, 0, 2, 6);
    try expectRow("<T>Usa</>", dashboard, 0, 2, 3);
    try expectRow("<D>Loading usage</>", dashboard, 1, 2, 80);
    try expectRow("<D>Usage unavailable · press r to retry</>", .{ .refresh_failed = true }, 1, 2, 80);
    try expectRow("", dashboard, 2, 2, 80);
    try testing.expectEqual(@as(u16, 2), dashboardDesiredRows(dashboard, 80));
}

test "dashboard rows cap models at 20 and keep the selection visible" {
    var models: [25]ModelUsage = undefined;
    var names: [25][16]u8 = undefined;
    for (&models, &names, 0..) |*model, *name, index| {
        model.* = .{ .model = std.fmt.bufPrint(name, "provider/m{d:0>2}", .{index}) catch unreachable, .totals = testTotals(25 - index, 0) };
    }
    const view: View = .{ .scope = .days_30, .snapshot_time_ms = 1, .window_start_ms = 0, .coverage_started_at_ms = 0, .coverage = .full, .completeness = .complete, .totals = testTotals(325, 0), .models = &models };
    var dashboard: Dashboard = .{ .view = &view };
    const desired = dashboardDesiredRows(dashboard, 80);
    // Header, status, blank, 3 overview rows, blank, models header, 20 rows.
    try testing.expectEqual(@as(u16, 8 + 20), desired);
    try testing.expectEqual(@as(u16, 20), dashboardVisibleModelItems(dashboard, desired, 80));
    try expectRow("<D>Local fx activity</>", dashboard, 1, desired, 80);
    try expectRow("<D>325 tokens · $0.00 spent · 1 request</>", dashboard, 3, desired, 80);
    try expectRow("<L>Models 25</>", dashboard, 7, desired, 80);
    try expectRow("<L>❯ provider/m00</>    <D>25 · 7.7% · $0.00</>", dashboard, 8, desired, 80);

    dashboard.selected_model = 24;
    const last = try paintRow(dashboard, desired - 1, desired, 80);
    defer testing.allocator.free(last);
    try testing.expect(std.mem.indexOf(u8, last, "❯ provider/m24") != null);
    const first = try paintRow(dashboard, 8, desired, 80);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "provider/m05") != null);
}

test "dashboard status words match fx usage for every state" {
    var view: View = .{ .scope = .days_7, .snapshot_time_ms = 1, .window_start_ms = 0, .coverage_started_at_ms = 0, .coverage = .full, .completeness = .complete, .totals = testTotals(0, 0), .models = &.{} };
    const dashboard: Dashboard = .{ .view = &view, .scope = .days_7 };
    view.completeness = .pending;
    try expectRow("<D>Known totals exclude pending Gateway reconciliation</>", dashboard, 1, 12, 80);
    try expectRow("<D>Pending Gateway reconciliation</>", dashboard, 1, 12, 58);
    view.completeness = .incomplete;
    try expectRow("<D>Known totals may be incomplete</>", dashboard, 1, 12, 80);
    view.completeness = .legacy;
    try expectRow("<D>This session predates complete usage tracking</>", dashboard, 1, 12, 80);
    try expectRow("<D>Predates usage tracking</>", dashboard, 1, 12, 52);
    // Completeness outranks a partial window.
    view.coverage = .partial;
    view.coverage_started_at_ms = 1791381023000;
    try expectRow("<D>This session predates complete usage tracking</>", dashboard, 1, 12, 80);
    view.completeness = .complete;
    try expectRow("<D>Tracking since Oct 7, 2026 (partial window)</>", dashboard, 1, 12, 80);
    try expectRow("<D>Partial window</>", dashboard, 1, 12, 48);
    view.coverage = .full;
    try expectRow("<D>Local fx activity</>", dashboard, 1, 12, 80);
    view.coverage = .not_started;
    view.totals = null;
    try expectRow("<D>Tracking has not started</>", dashboard, 1, 12, 80);
    try expectRow("<D>Refresh failed · showing previous data</>", .{ .view = &view, .refresh_failed = true }, 1, 12, 80);
}

test "dashboard hint row picks the widest hint that fits" {
    var row: Row = .{};
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    dashboardHintRow(&row, 80);
    try row.paint(&out.writer, test_palette);
    try testing.expectEqualStrings("<D>tab scope     ↑↓ model     enter expand     r refresh     esc close</>", out.written());
    out.clearRetainingCapacity();
    dashboardHintRow(&row, 10);
    try row.paint(&out.writer, test_palette);
    try testing.expectEqualStrings("<D>tab ↑↓  en</>", out.written());
}

test "selection survives refresh by model name" {
    var old_models = [_]ModelUsage{ .{ .model = "a", .totals = testTotals(3, 0) }, .{ .model = "b", .totals = testTotals(2, 0) } };
    var new_models = [_]ModelUsage{ .{ .model = "b", .totals = testTotals(9, 0) }, .{ .model = "a", .totals = testTotals(3, 0) } };
    const old: View = .{ .scope = .days_30, .snapshot_time_ms = 1, .window_start_ms = 0, .coverage_started_at_ms = 0, .coverage = .full, .completeness = .complete, .totals = testTotals(5, 0), .models = &old_models };
    var new = old;
    new.models = &new_models;
    const kept = (Selection{ .selected_model = 1, .expanded_model = 0, .model_window_start = 1 }).retain(&old, &new);
    try testing.expectEqual(Selection{ .selected_model = 0, .expanded_model = 1, .model_window_start = 0 }, kept);

    var selection: Selection = .{};
    try testing.expect(selection.move(1, 2, 1));
    try testing.expectEqual(@as(usize, 1), selection.model_window_start);
    try testing.expect(!selection.move(1, 2, 1));
    try testing.expect(selection.toggleExpanded(2, 1));
    try testing.expectEqual(@as(?usize, 1), selection.expanded_model);
    try testing.expect(selection.toggleExpanded(2, 1));
    try testing.expectEqual(@as(?usize, null), selection.expanded_model);
}
