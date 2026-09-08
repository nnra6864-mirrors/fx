const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn leftTrim(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line[i..];
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

pub fn isBlankMarkdownLine(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

pub fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

pub fn isAsciiAlphaNumeric(c: u8) bool {
    return isAsciiAlpha(c) or (c >= '0' and c <= '9');
}

pub fn isAsciiWordByte(c: u8) bool {
    return isAsciiAlphaNumeric(c) or c == '_';
}

pub fn isAsciiWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

pub fn isTrailingUrlPunctuation(c: u8) bool {
    return c == '.' or c == ',' or c == ';' or c == ':' or c == '!' or c == '?';
}

fn isEscapablePunctuation(byte: u8) bool {
    return switch (byte) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

pub fn isEscapedPunctuationAt(text: []const u8, index: usize) bool {
    if (index == 0 or index >= text.len or !isEscapablePunctuation(text[index])) return false;

    var slash_count: usize = 0;
    var cursor = index;
    while (cursor > 0 and text[cursor - 1] == '\\') : (cursor -= 1) {
        slash_count += 1;
    }
    return slash_count % 2 == 1;
}

pub fn appendEscapedPunctuation(alloc: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len and isEscapedPunctuationAt(text, i + 1)) {
            try out.append(alloc, text[i + 1]);
            i += 2;
            continue;
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
}

pub fn withoutTerminalHardBreakMarker(line: []const u8, line_has_lf: bool) []const u8 {
    if (!line_has_lf or line.len == 0 or line[line.len - 1] != '\\') return line;

    var slash_start = line.len;
    while (slash_start > 0 and line[slash_start - 1] == '\\') : (slash_start -= 1) {}
    if ((line.len - slash_start) % 2 == 0) return line;
    return line[0 .. line.len - 1];
}

fn isExactUnderscoreRun(text: []const u8, index: usize, marker_len: usize) bool {
    if (marker_len != 1 and marker_len != 2) return false;
    if (index + marker_len > text.len) return false;
    if (index > 0 and text[index - 1] == '_') return false;
    if (index + marker_len < text.len and text[index + marker_len] == '_') return false;
    for (text[index .. index + marker_len]) |c| if (c != '_') return false;
    return true;
}

pub fn isValidUnderscoreOpen(text: []const u8, index: usize, marker_len: usize) bool {
    if (!isExactUnderscoreRun(text, index, marker_len)) return false;
    const after = index + marker_len;
    if (after >= text.len or isSpace(text[after])) return false;
    return index == 0 or !isAsciiWordByte(text[index - 1]);
}

pub fn isValidUnderscoreClose(text: []const u8, index: usize, marker_len: usize) bool {
    if (!isExactUnderscoreRun(text, index, marker_len)) return false;
    if (index == 0 or isSpace(text[index - 1])) return false;
    const after = index + marker_len;
    return after >= text.len or !isAsciiWordByte(text[after]);
}

pub fn nthLine(buf: []const u8, n: usize) ?[]const u8 {
    var idx: usize = 0;
    var start: usize = 0;
    while (start < buf.len) {
        const end = std.mem.indexOfScalarPos(u8, buf, start, '\n') orelse buf.len;
        if (idx == n) return buf[start..end];
        idx += 1;
        start = end + 1;
    }
    return null;
}
