//! Shared, allocation-free Nix source-line rendering for terminal frontends.
//! Token color, an exact byte-range cursor, and breakpoint backgrounds are
//! composed in one pass. A cursor keeps its normal syntax colors while the
//! surrounding source dims, so selection never masquerades as token meaning.

const std = @import("std");
const terminal_color = @import("base").terminal_color;
const syntax = @import("syntax");

const TokenType = syntax.token.TokenType;

const col_keyword: terminal_color.Rgb = .{ 210, 143, 240 };
const col_string: terminal_color.Rgb = .{ 111, 201, 145 };
const col_number: terminal_color.Rgb = .{ 229, 192, 123 };
const col_breakpoint_bg: terminal_color.Rgb = .{ 92, 40, 52 };
const col_breakpoint_plain: terminal_color.Rgb = .{ 246, 248, 250 };
const dim = "\x1b[2m";
const breakpoint_fallback = "\x1b[7m";
const reset = "\x1b[0m";

pub const Range = struct {
    start: usize,
    end: usize,
};

pub const Options = struct {
    color_depth: terminal_color.Depth,
    /// Byte range relative to `line`. Empty and out-of-bounds ranges are
    /// ignored. Text outside the range is dimmed; text inside retains ordinary
    /// syntax highlighting. The UI renders the cursor marker separately.
    focus: ?Range = null,
    /// Exact breakpoint ranges relative to `line`. Breakpoint backgrounds
    /// remain visible while the cursor moves to another sub-expression.
    breakpoints: []const Range = &.{},
};

pub fn writeLine(w: *std.Io.Writer, line: []const u8, options: Options) !void {
    const selected = if (options.focus) |range| Range{
        .start = @min(range.start, line.len),
        .end = @min(@max(range.end, range.start), line.len),
    } else null;

    var scanner = syntax.scanner.Scanner.init(line);
    var last: usize = 0;
    while (true) {
        const token = scanner.next();
        if (token.type == .eof) break;
        const start = @min(token.offset, line.len);
        const end = @min(token.offset +| token.len, line.len);
        if (end <= last) break;
        if (start > last) try writeSpan(w, line, last, start, null, selected, options.breakpoints, options.color_depth);
        try writeSpan(w, line, start, end, tokenColor(token.type), selected, options.breakpoints, options.color_depth);
        last = end;
    }
    if (last < line.len) try writeSpan(w, line, last, line.len, null, selected, options.breakpoints, options.color_depth);
}

fn writeSpan(
    w: *std.Io.Writer,
    line: []const u8,
    start: usize,
    end: usize,
    color: ?terminal_color.Rgb,
    selected: ?Range,
    breakpoints: []const Range,
    color_depth: terminal_color.Depth,
) !void {
    if (start >= end) return;
    var cursor = start;
    while (cursor < end) {
        var next = end;
        if (selected) |range| {
            if (range.start > cursor) next = @min(next, range.start);
            if (range.end > cursor) next = @min(next, range.end);
        }
        for (breakpoints) |range| {
            if (range.start > cursor) next = @min(next, range.start);
            if (range.end > cursor) next = @min(next, range.end);
        }
        const focused = if (selected) |range| cursor >= range.start and cursor < range.end else false;
        var breakpoint = false;
        for (breakpoints) |range| {
            if (cursor >= range.start and cursor < range.end) {
                breakpoint = true;
                break;
            }
        }
        try styled(w, line[cursor..next], color, selected != null and !focused, breakpoint, color_depth);
        cursor = next;
    }
}

fn styled(
    w: *std.Io.Writer,
    text: []const u8,
    color: ?terminal_color.Rgb,
    dimmed: bool,
    breakpoint: bool,
    color_depth: terminal_color.Depth,
) !void {
    if (breakpoint) {
        if (color_depth.enabled()) {
            try terminal_color.background(w, color_depth, col_breakpoint_bg);
            try terminal_color.foreground(w, color_depth, color orelse col_breakpoint_plain, color == null);
        } else {
            try w.writeAll(breakpoint_fallback);
        }
    } else {
        if (color) |rgb| try terminal_color.foreground(w, color_depth, rgb, false);
        if (dimmed) try w.writeAll(dim);
    }
    try writeSafe(w, text);
    if (dimmed or breakpoint or (color != null and color_depth.enabled())) try w.writeAll(reset);
}

fn writeSafe(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '\t' => try w.writeAll("    "),
        '\r' => {},
        0x1b => try w.writeAll("␛"),
        0...8, 10...12, 14...26, 28...0x1f, 0x7f => try w.writeByte('?'),
        else => try w.writeByte(byte),
    };
}

fn tokenColor(token: TokenType) ?terminal_color.Rgb {
    return switch (token) {
        .kw_if, .kw_then, .kw_else, .kw_assert, .kw_with, .kw_let, .kw_in, .kw_rec, .kw_inherit, .kw_or => col_keyword,
        .string, .path, .search_path => col_string,
        .integer, .float_val => col_number,
        else => null,
    };
}

test "source cursor preserves token color and dims its surroundings" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeLine(&output.writer, "if 42 then x", .{
        .color_depth = .truecolor,
        .focus = .{ .start = 3, .end = 5 },
    });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[38;2;210;143;240m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[2mif") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[38;2;229;192;123m42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[2mx") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[4m") == null);
}

test "source focus outside a token does not duplicate its text" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeLine(&output.writer, "if true", .{
        .color_depth = .none,
        .focus = .{ .start = 3, .end = 7 },
    });
    const plain = @import("base").terminal_text.stripAnsiInPlace(output.written());
    try std.testing.expectEqualStrings("if true", plain);
}

test "source breakpoints mark exact ranges independently of focus" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeLine(&output.writer, "one + two", .{
        .color_depth = .truecolor,
        .focus = .{ .start = 6, .end = 9 },
        .breakpoints = &.{.{ .start = 0, .end = 3 }},
    });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[48;2;92;40;52m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[4m") == null);
    const plain = @import("base").terminal_text.stripAnsiInPlace(output.written());
    try std.testing.expectEqualStrings("one + two", plain);
}
