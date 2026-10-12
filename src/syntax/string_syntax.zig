//! Shared Nix string literal mechanics.
//!
//! The scanner needs allocation-free literal extents, while the compiler needs
//! decoded text chunks and interpolation source spans. Keeping both paths here
//! prevents double-quoted and indented strings from drifting apart.

const std = @import("std");
const TextRef = @import("base").TextRef;

// SIMD find-first-of for the literal scanners: string bodies are long runs
// of plain bytes; jump straight to the next structurally interesting byte.
const vec_len: comptime_int = std.simd.suggestVectorLength(u8) orelse 0;
const Vec = @Vector(vec_len, u8);
const VMask = @Int(.unsigned, if (vec_len == 0) 1 else vec_len);

inline fn maskEq(v: Vec, comptime c: u8) VMask {
    return @bitCast(v == @as(Vec, @splat(c)));
}

/// Advance `i` to the first occurrence of any of `chars` at or after `i`.
/// Returns the index of that byte, or `source.len` if none remain in the
/// SIMD-reachable prefix — the caller's scalar loop finishes the tail.
inline fn skipToAnyOf(source: []const u8, start: usize, comptime chars: []const u8) usize {
    var i = start;
    if (comptime vec_len > 0) {
        while (i + vec_len <= source.len) {
            const v: Vec = source[i..][0..vec_len].*;
            var m: VMask = 0;
            inline for (chars) |c| m |= maskEq(v, c);
            if (m != 0) return i + @ctz(m);
            i += vec_len;
        }
    }
    return i;
}

pub const LiteralKind = enum {
    double_quoted,
    indented,
};

pub const Span = struct {
    start: u32,
    end: u32,
};

pub const Text = TextRef;

pub const Part = union(enum) {
    text: Text,
    interpolation: Span,
};

pub const ParsedLiteral = struct {
    allocator: std.mem.Allocator,
    parts: []Part,

    pub fn deinit(self: ParsedLiteral) void {
        for (self.parts) |*part| {
            switch (part.*) {
                .text => |*text| text.deinit(self.allocator),
                .interpolation => {},
            }
        }
        self.allocator.free(self.parts);
    }
};

pub fn kindAt(source: []const u8, start: usize) ?LiteralKind {
    if (start >= source.len) return null;
    if (source[start] == '"') return .double_quoted;
    if (source[start] == '\'' and start + 1 < source.len and source[start + 1] == '\'') return .indented;
    return null;
}

pub fn scanLiteral(source: []const u8, start: usize, kind: LiteralKind) ?usize {
    return switch (kind) {
        .double_quoted => scanDoubleQuoted(source, start),
        .indented => scanIndented(source, start),
    };
}

pub fn parseLiteral(
    allocator: std.mem.Allocator,
    source: []const u8,
    literal: Span,
) !ParsedLiteral {
    const start: usize = literal.start;
    const end: usize = literal.end;
    const kind = kindAt(source, start) orelse return error.InvalidStringLiteral;
    if (end > source.len or end <= start) return error.InvalidStringLiteral;

    var parts: std.ArrayListUnmanaged(Part) = .empty;
    errdefer {
        for (parts.items) |*part| {
            switch (part.*) {
                .text => |*text| text.deinit(allocator),
                .interpolation => {},
            }
        }
        parts.deinit(allocator);
    }

    switch (kind) {
        .double_quoted => try parseDoubleQuoted(allocator, source, start + 1, end - 1, &parts),
        .indented => try parseIndented(allocator, source, start + 2, end - 2, &parts),
    }

    return .{
        .allocator = allocator,
        .parts = try parts.toOwnedSlice(allocator),
    };
}

fn scanDoubleQuoted(source: []const u8, start: usize) ?usize {
    if (start >= source.len or source[start] != '"') return null;
    var i = start + 1;
    while (i < source.len) {
        i = skipToAnyOf(source, i, "\"\\$");
        if (i >= source.len) break;
        switch (source[i]) {
            '"' => return i + 1,
            '\\' => i += if (i + 1 < source.len) 2 else 1,
            '$' => {
                const run_start = i;
                while (i < source.len and source[i] == '$') i += 1;
                if (i < source.len and source[i] == '{' and (i - run_start) % 2 == 1) {
                    const end = findInterpolationEnd(source, i + 1) orelse return null;
                    i = end + 1;
                }
            },
            else => i += 1,
        }
    }
    return null;
}

fn scanIndented(source: []const u8, start: usize) ?usize {
    if (start + 1 >= source.len or source[start] != '\'' or source[start + 1] != '\'') return null;
    var i = start + 2;
    while (i < source.len) {
        i = skipToAnyOf(source, i, "$'");
        if (i >= source.len) break;
        if (source[i] == '$') {
            const run_start = i;
            while (i < source.len and source[i] == '$') i += 1;
            if (i < source.len and source[i] == '{' and (i - run_start) % 2 == 1) {
                const end = findInterpolationEnd(source, i + 1) orelse return null;
                i = end + 1;
            }
            continue;
        }

        if (source[i] == '\'' and i + 1 < source.len and source[i + 1] == '\'') {
            if (isIndentedEscape(source, i)) {
                i += indentedEscapeLen(source, i);
                continue;
            }
            return i + 2;
        }

        i += 1;
    }
    return null;
}

pub fn findInterpolationEnd(source: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < source.len) {
        i = skipToAnyOf(source, i, "\"'#/{}");
        if (i >= source.len) break;
        if (source[i] == '"') {
            i = scanDoubleQuoted(source, i) orelse return null;
            continue;
        }
        if (source[i] == '\'' and i + 1 < source.len and source[i + 1] == '\'') {
            i = scanIndented(source, i) orelse return null;
            continue;
        }
        if (source[i] == '#') {
            i += 1;
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            if (i + 1 >= source.len) return null;
            i += 2;
            continue;
        }

        switch (source[i]) {
            '{' => {
                depth += 1;
                i += 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
                i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

fn parseDoubleQuoted(
    allocator: std.mem.Allocator,
    source: []const u8,
    body_start: usize,
    body_end: usize,
    parts: *std.ArrayListUnmanaged(Part),
) !void {
    var cursor = body_start;
    var i = body_start;
    while (i < body_end) {
        if (source[i] == '\\') {
            i += if (i + 1 < body_end) 2 else 1;
            continue;
        }
        if (source[i] == '$') {
            const run_start = i;
            while (i < body_end and source[i] == '$') i += 1;
            if (i >= body_end or source[i] != '{' or (i - run_start) % 2 == 0) continue;

            const interpolation_start = i - 1;
            try appendDoubleText(allocator, source[cursor..interpolation_start], parts);
            const expr_start = i + 1;
            const expr_end = findInterpolationEnd(source, expr_start) orelse return error.InvalidStringLiteral;
            try parts.append(allocator, .{ .interpolation = .{
                .start = @intCast(expr_start),
                .end = @intCast(expr_end),
            } });
            i = expr_end + 1;
            cursor = i;
            continue;
        }
        i += 1;
    }
    try appendDoubleText(allocator, source[cursor..body_end], parts);
}

fn appendDoubleText(
    allocator: std.mem.Allocator,
    raw: []const u8,
    parts: *std.ArrayListUnmanaged(Part),
) !void {
    if (raw.len == 0) return;
    // A run with neither an escape nor a raw CR needs no decoding — keep the
    // zero-copy source slice.
    if (std.mem.indexOfScalar(u8, raw, '\\') == null and std.mem.indexOfScalar(u8, raw, '\r') == null) {
        try parts.append(allocator, .{ .text = .{ .borrowed = raw } });
        return;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\\' or i + 1 >= raw.len) {
            // Normalize a raw CR/CRLF line ending to LF, as Nix does (a `\r`
            // escape is decoded below and stays a CR character).
            if (raw[i] == '\r') {
                try out.append(allocator, '\n');
                if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1; // CRLF -> LF
                continue;
            }
            try out.append(allocator, raw[i]);
            continue;
        }
        i += 1;
        try out.append(allocator, switch (raw[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '"' => '"',
            '\\' => '\\',
            else => raw[i],
        });
    }
    const bytes = try out.toOwnedSlice(allocator);
    errdefer allocator.free(bytes);
    try parts.append(allocator, .{ .text = .{ .owned = bytes } });
}

fn parseIndented(
    allocator: std.mem.Allocator,
    source: []const u8,
    body_start: usize,
    body_end: usize,
    parts: *std.ArrayListUnmanaged(Part),
) !void {
    // Nix strips the first line if it consists only of spaces followed by a
    // newline (the common `''<newline>` idiom, but also `''   <newline>`).
    const start = leadingSkip(source, body_start, body_end);
    const indent = minIndent(source, start, body_end);
    var state = IndentState.init(indent);
    var text: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text.deinit(allocator);

    var i = start;
    while (i < body_end) {
        if (source[i] == '$') {
            const run_start = i;
            while (i < body_end and source[i] == '$') i += 1;
            if (i >= body_end or source[i] != '{' or (i - run_start) % 2 == 0) {
                for (source[run_start..i]) |byte| {
                    try appendIndentedByte(allocator, &text, &state, byte);
                }
                continue;
            }

            const interpolation_start = i - 1;
            for (source[run_start..interpolation_start]) |byte| {
                try appendIndentedByte(allocator, &text, &state, byte);
            }
            try flushOwnedText(allocator, &text, parts);
            state.noteNonIndent();

            const expr_start = i + 1;
            const expr_end = findInterpolationEnd(source, expr_start) orelse return error.InvalidStringLiteral;
            try parts.append(allocator, .{ .interpolation = .{
                .start = @intCast(expr_start),
                .end = @intCast(expr_end),
            } });
            i = expr_end + 1;
            continue;
        }

        if (source[i] == '\'' and i + 1 < body_end and source[i + 1] == '\'' and isIndentedEscape(source, i)) {
            const decoded = decodeIndentedEscape(source, i);
            try appendIndentedEscape(allocator, &text, &state, decoded.bytes());
            i += decoded.source_len;
            continue;
        }

        try appendIndentedByte(allocator, &text, &state, source[i]);
        i += 1;
    }

    // Nix drops the final line if it is empty and consists only of spaces
    // (the closing `''` on its own indented line), keeping the newline.
    trimTrailingBlankLine(&text);

    try flushOwnedText(allocator, &text, parts);
}

/// Number of source bytes to skip at the start of an indented-string body.
/// If the first line is spaces-only and ends with a newline, that whole line
/// (including the newline) is removed. Tabs count as content, so a first line
/// containing a tab is not stripped.
fn leadingSkip(source: []const u8, body_start: usize, body_end: usize) usize {
    var i = body_start;
    while (i < body_end and source[i] == ' ') i += 1;
    if (i < body_end and source[i] == '\n') return i + 1;
    return body_start;
}

/// Strip a trailing spaces-only final line in place, keeping the newline that
/// precedes it. Only spaces are stripped (a trailing tab is preserved), and
/// only when a newline is present (a spaces-only tail with no newline stays).
fn trimTrailingBlankLine(text: *std.ArrayListUnmanaged(u8)) void {
    const nl = std.mem.lastIndexOfScalar(u8, text.items, '\n') orelse return;
    for (text.items[nl + 1 ..]) |byte| {
        if (byte != ' ') return;
    }
    text.shrinkRetainingCapacity(nl + 1);
}

const IndentState = struct {
    indent: usize,
    remaining: usize,
    at_line_start: bool,

    fn init(indent: usize) IndentState {
        return .{
            .indent = indent,
            .remaining = indent,
            .at_line_start = true,
        };
    }

    fn afterNewline(self: *IndentState) void {
        self.at_line_start = true;
        self.remaining = self.indent;
    }

    fn noteNonIndent(self: *IndentState) void {
        self.at_line_start = false;
        self.remaining = 0;
    }
};

fn appendIndentedByte(
    allocator: std.mem.Allocator,
    text: *std.ArrayListUnmanaged(u8),
    state: *IndentState,
    byte: u8,
) !void {
    if (state.at_line_start and state.remaining > 0 and isIndentByte(byte)) {
        state.remaining -= 1;
        return;
    }

    try text.append(allocator, byte);
    if (byte == '\n') {
        state.afterNewline();
    } else {
        state.noteNonIndent();
    }
}

fn appendIndentedEscape(
    allocator: std.mem.Allocator,
    text: *std.ArrayListUnmanaged(u8),
    state: *IndentState,
    bytes: []const u8,
) !void {
    state.noteNonIndent();
    for (bytes) |byte| {
        try text.append(allocator, byte);
        if (byte == '\n') {
            state.afterNewline();
        } else {
            state.noteNonIndent();
        }
    }
}

fn flushOwnedText(
    allocator: std.mem.Allocator,
    text: *std.ArrayListUnmanaged(u8),
    parts: *std.ArrayListUnmanaged(Part),
) !void {
    if (text.items.len == 0) return;
    const bytes = try text.toOwnedSlice(allocator);
    text.* = .empty;
    errdefer allocator.free(bytes);
    try parts.append(allocator, .{ .text = .{ .owned = bytes } });
}

fn minIndent(source: []const u8, body_start: usize, body_end: usize) usize {
    var best: ?usize = null;
    var line_indent: usize = 0;
    var line_has_content = false;
    var at_line_start = true;
    var i = body_start;

    while (i < body_end) {
        if (source[i] == '$' and i + 1 < body_end and source[i + 1] == '{') {
            line_has_content = true;
            at_line_start = false;
            i = (findInterpolationEnd(source, i + 2) orelse body_end - 1) + 1;
            continue;
        }

        if (source[i] == '\'' and i + 1 < body_end and source[i + 1] == '\'' and isIndentedEscape(source, i)) {
            line_has_content = true;
            at_line_start = false;
            i += indentedEscapeLen(source, i);
            continue;
        }

        accountIndentByte(source[i], &best, &line_indent, &line_has_content, &at_line_start);
        i += 1;
    }
    if (line_has_content) best = @min(best orelse line_indent, line_indent);
    // No line carries non-whitespace content: strip every leading space so an
    // all-whitespace indented string collapses to the empty string, as in Nix.
    return best orelse std.math.maxInt(usize);
}

fn accountIndentByte(
    byte: u8,
    best: *?usize,
    line_indent: *usize,
    line_has_content: *bool,
    at_line_start: *bool,
) void {
    if (byte == '\n') {
        if (line_has_content.*) best.* = @min(best.* orelse line_indent.*, line_indent.*);
        line_indent.* = 0;
        line_has_content.* = false;
        at_line_start.* = true;
        return;
    }
    if (at_line_start.* and isIndentByte(byte)) {
        line_indent.* += 1;
        return;
    }
    at_line_start.* = false;
    if (!isIndentByte(byte)) line_has_content.* = true;
}

fn isIndentedEscape(source: []const u8, i: usize) bool {
    if (i + 2 >= source.len) return false;
    return switch (source[i + 2]) {
        '\'', '$', '\\' => true,
        else => false,
    };
}

fn indentedEscapeLen(source: []const u8, i: usize) usize {
    if (i + 2 >= source.len) return 2;
    if (source[i + 2] == '\\' and i + 3 < source.len) return 4;
    if (source[i + 2] == '$' and i + 3 < source.len and source[i + 3] == '{') return 4;
    return 3;
}

const DecodedIndentedEscape = struct {
    buf: [2]u8,
    bytes_len: u8,
    source_len: usize,

    fn bytes(self: *const DecodedIndentedEscape) []const u8 {
        return self.buf[0..self.bytes_len];
    }
};

fn decodeIndentedEscape(source: []const u8, i: usize) DecodedIndentedEscape {
    std.debug.assert(isIndentedEscape(source, i));
    const third = source[i + 2];
    if (third == '\\' and i + 3 < source.len) {
        return .{
            .buf = .{ switch (source[i + 3]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => source[i + 3],
            }, 0 },
            .bytes_len = 1,
            .source_len = 4,
        };
    }
    if (third == '$' and i + 3 < source.len and source[i + 3] == '{') {
        return .{ .buf = .{ '$', '{' }, .bytes_len = 2, .source_len = 4 };
    }
    if (third == '\'') {
        return .{ .buf = .{ '\'', '\'' }, .bytes_len = 2, .source_len = 3 };
    }
    return .{ .buf = .{ third, 0 }, .bytes_len = 1, .source_len = 3 };
}

fn isIndentByte(byte: u8) bool {
    // Nix only treats spaces as indentation whitespace; tabs count as content
    // (their display width is unknowable), so they end leading-indent counting.
    return byte == ' ';
}

fn checkLiteralAllocationFailures(allocator: std.mem.Allocator) !void {
    const source = "\"a\\n${\"b\"}c\\t\"";
    const parsed = try parseLiteral(
        allocator,
        source,
        .{ .start = 0, .end = @intCast(source.len) },
    );
    defer parsed.deinit();
}

test "literal parsing handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLiteralAllocationFailures,
        .{},
    );
}

test "scans nested interpolation strings" {
    const source = "\"a${{ x = \"}\"; }.x}b\"";
    try std.testing.expectEqual(source.len, scanLiteral(source, 0, .double_quoted).?);
}

test "parses double quoted text and interpolation" {
    const source = "\"a\\n${\"b\"}c\"";
    const parsed = try parseLiteral(std.testing.allocator, source, .{ .start = 0, .end = @intCast(source.len) });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.parts.len);
    try std.testing.expectEqualStrings("a\n", parsed.parts[0].text.slice());
    try std.testing.expectEqualStrings("c", parsed.parts[2].text.slice());
}

test "parses indented strings" {
    const source =
        \\''
        \\  a
        \\  b
        \\''
    ;
    const parsed = try parseLiteral(std.testing.allocator, source, .{ .start = 0, .end = @intCast(source.len) });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.parts.len);
    try std.testing.expectEqualStrings("a\nb\n", parsed.parts[0].text.slice());
}

test "parses indented string escapes after stripping source indentation" {
    const source =
        \\''
        \\  ''\t['name'] = {
        \\  ''\t''\tloader = 'file',
        \\''
    ;
    const parsed = try parseLiteral(std.testing.allocator, source, .{ .start = 0, .end = @intCast(source.len) });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.parts.len);
    try std.testing.expectEqualStrings("\t['name'] = {\n\t\tloader = 'file',\n", parsed.parts[0].text.slice());
}

test "parses indented string escaped newlines after stripping source indentation" {
    const source =
        \\''
        \\  alpha ''\nbeta
        \\  gamma
        \\''
    ;
    const parsed = try parseLiteral(std.testing.allocator, source, .{ .start = 0, .end = @intCast(source.len) });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.parts.len);
    try std.testing.expectEqualStrings("alpha \nbeta\ngamma\n", parsed.parts[0].text.slice());
}
