//! Lexer / scanner. Produces a token stream from source text.
//! Single-pass, no allocation during scanning.
//! Returns byte offsets rather than string slices — the source lives longer.

const std = @import("std");
const token = @import("token.zig");
const string_syntax = @import("string_syntax.zig");
const TokenType = token.TokenType;
const Token = token.Token;

// Branchless character classification: one table lookup + mask instead of a
// chain of range comparisons, run once per source byte in the identifier /
// number / path scanning loops.
const char_ident_start: u8 = 1; // a-z A-Z _
const char_digit: u8 = 2; // 0-9
const char_ident_continue: u8 = 4; // ident-start, digit, '-', '\'', '_'
const char_path_continue: u8 = 8; // ident, digit, '/', '.', '-', '_', '+'

const class_table = blk: {
    var tbl = [_]u8{0} ** 256;
    for (0..256) |ci| {
        const c: u8 = @intCast(ci);
        const alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
        const digit = c >= '0' and c <= '9';
        var f: u8 = 0;
        if (alpha) f |= char_ident_start;
        if (digit) f |= char_digit;
        if (alpha or digit or c == '-' or c == '\'' or c == '_') f |= char_ident_continue;
        if (alpha or digit or c == '/' or c == '.' or c == '-' or c == '_' or c == '+') f |= char_path_continue;
        tbl[ci] = f;
    }
    break :blk tbl;
};

inline fn hasClass(c: u8, mask: u8) bool {
    return class_table[c] & mask != 0;
}

// SIMD block scanning for the three byte-run hot loops (layout runs,
// identifier runs, string bodies). `vec_len == 0` (no SIMD on this target)
// falls back to the scalar loops everywhere.
const vec_len: comptime_int = std.simd.suggestVectorLength(u8) orelse 0;
const Vec = @Vector(vec_len, u8);
const VMask = std.meta.Int(.unsigned, if (vec_len == 0) 1 else vec_len);

inline fn maskEq(v: Vec, comptime c: u8) VMask {
    return @bitCast(v == @as(Vec, @splat(c)));
}

inline fn maskGe(v: Vec, comptime c: u8) VMask {
    return @bitCast(v >= @as(Vec, @splat(c)));
}

inline fn maskLe(v: Vec, comptime c: u8) VMask {
    return @bitCast(v <= @as(Vec, @splat(c)));
}

/// Mask of bytes in the identifier-continue class (a-z A-Z 0-9 - ' _),
/// mirroring `char_ident_continue` in `class_table`.
inline fn maskIdentCont(v: Vec) VMask {
    const lower = maskGe(v, 'a') & maskLe(v, 'z');
    const upper = maskGe(v, 'A') & maskLe(v, 'Z');
    const digit = maskGe(v, '0') & maskLe(v, '9');
    const other = maskEq(v, '-') | maskEq(v, '\'') | maskEq(v, '_');
    return lower | upper | digit | other;
}

pub const Scanner = struct {
    source: []const u8,
    pos: u32,
    /// Offset of the first structural CR (`\r`) seen between tokens — a
    /// deprecated CR/CRLF line ending. Recorded for the compile chokepoint to
    /// gate on the `cr-line-endings` feature (see `Parser.first_cr_offset`).
    first_cr: ?u32 = null,
    /// Offset+len of the first leading-dot float (`.5`) — the deprecated
    /// `floating-without-zero` syntax, surfaced as a warning.
    first_float_no_zero: ?struct { offset: u32, len: u32 } = null,
    /// Offset of the first place a value token (number/string/path) is followed
    /// with no whitespace by a char that starts another token (`0a`, `1.a`,
    /// `"x"2`) — Lix's deprecated `tokens-no-whitespace`. Gated at the chokepoint.
    first_tokens_no_ws: ?u32 = null,

    pub fn init(source: []const u8) Scanner {
        return .{
            .source = source,
            .pos = 0,
        };
    }

    pub fn next(self: *Scanner) Token {
        const tok = self.nextRaw();
        // tokens-no-whitespace: a value token (number/string/path) immediately
        // followed — no intervening whitespace — by a char that would start
        // another token is Lix's deprecated adjacency. `self.pos` sits right
        // after the token here (the next `nextRaw` skips layout).
        if (self.first_tokens_no_ws == null and self.pos < self.source.len) {
            const nc = self.source[self.pos];
            const stuck = switch (tok.type) {
                // A number stuck to an identifier, a `.` (select/leading-dot
                // float), or a string opener: `0a`, `1.a`, `0.0.0`, `0."`.
                .integer, .float_val => isAlpha(nc) or nc == '_' or nc == '.' or nc == '"' or nc == '\'',
                // A string/path stuck to a following number (`"1"2`). A `.`
                // after a string is an ordinary select and is NOT flagged.
                .string, .path, .uri => isDigit(nc),
                else => false,
            };
            if (stuck) self.first_tokens_no_ws = self.pos;
        }
        return tok;
    }

    fn nextRaw(self: *Scanner) Token {
        if (self.skipLayout()) |comment_start| {
            return self.makeToken(.error_token, comment_start, self.pos - comment_start);
        }

        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, self.pos, 0);
        }

        const start = self.pos;
        const c = self.advance();

        // Fast path: ASCII alpha starts an identifier/keyword.
        if (isAlpha(c)) return self.lexIdentOrKeyword(start);
        if (isDigit(c)) return self.lexNumber(start);
        if (c == '"') return self.lexString(start, .double_quoted);
        if (c == '\'' and self.peek() == '\'') return self.lexString(start, .indented);
        // Relative path starting with `.` — Nix flex PATH form
        // `{PATH_CHAR}*(\/{PATH_CHAR}+)+`, where PATH_CHAR is
        // `[A-Za-z0-9._+-]` (no slash). Covers `./foo`, `../bar`, hidden
        // dirs like `.devops/nix/scope.nix` (llama.cpp's flake), `.../x`,
        // and `.5/foo` (path outranks a leading-dot float when a `/`
        // segment follows). Bare `.devops` or `...` without a `/` segment
        // is not a path.
        if (c == '.' and self.looksLikeRelativePath()) return self.lexPath(start);
        // Leading-dot float: `.5`, `.5e3` (Nix's `0?\.[0-9]+` form). Deprecated
        // in Lix but still valid; `.` followed by a digit is never a selector
        // here because a bare `.` cannot start a select.
        if (c == '.' and isDigit(self.peek())) {
            const tok = self.lexFractionAndExponent(start);
            if (self.first_float_no_zero == null) self.first_float_no_zero = .{ .offset = tok.offset, .len = tok.len };
            return tok;
        }

        // Single-character tokens.
        switch (c) {
            '(' => return self.makeToken(.left_paren, start, 1),
            ')' => return self.makeToken(.right_paren, start, 1),
            '{' => return self.makeToken(.left_brace, start, 1),
            '}' => return self.makeToken(.right_brace, start, 1),
            '[' => return self.makeToken(.left_bracket, start, 1),
            ']' => return self.makeToken(.right_bracket, start, 1),
            ',' => return self.makeToken(.comma, start, 1),
            ':' => return self.makeToken(.colon, start, 1),
            '.' => {
                if (self.match('.') and self.match('.')) return self.makeToken(.ellipsis, start, 3);
                return self.makeToken(.dot, start, 1);
            },
            '@' => return self.makeToken(.at, start, 1),
            ';' => return self.makeToken(.semicolon, start, 1),
            '?' => return self.makeToken(.question_mark, start, 1),
            '$' => {
                if (self.match('{')) return self.makeToken(.dollar_curly, start, 2);
                return self.makeToken(.error_token, start, 1);
            },
            '+' => {
                if (self.match('+')) return self.makeToken(.double_plus, start, 2);
                return self.makeToken(.plus, start, 1);
            },
            '*' => return self.makeToken(.star, start, 1),
            '-' => {
                if (self.match('>')) return self.makeToken(.arrow, start, 2);
                return self.makeToken(.minus, start, 1);
            },
            '!' => {
                if (self.match('=')) return self.makeToken(.bang_equal, start, 2);
                return self.makeToken(.bang, start, 1);
            },
            '=' => {
                if (self.match('=')) return self.makeToken(.equal_equal, start, 2);
                return self.makeToken(.equal, start, 1);
            },
            '<' => {
                if (self.match('=')) return self.makeToken(.less_equal, start, 2);
                if (self.match('|')) return self.makeToken(.pipe_backward, start, 2);
                if (isSearchPathStart(self.peek())) return self.lexSearchPath(start);
                return self.makeToken(.less, start, 1);
            },
            '>' => {
                if (self.match('=')) return self.makeToken(.greater_equal, start, 2);
                return self.makeToken(.greater, start, 1);
            },
            '/' => {
                if (self.match('/')) return self.makeToken(.double_slash, start, 2);
                // Absolute path (flex `PATH` with an empty leading component):
                // the first segment is `{PATH_CHAR}+` like every other one, so
                // it may start with a digit — `/123abc`, `/1/2`. The `/` is
                // division only when what follows it is not a segment char.
                if (isPathContinue(self.peek())) return self.lexPath(start);
                // Absolute path opening with an interpolation: `/${x}`.
                if (self.peek() == '$' and self.peekAhead(1) == '{') return self.lexPath(start);
                return self.makeToken(.slash, start, 1);
            },
            // Home-relative path (`~/...`, HPATH): a `~` is only a path when
            // immediately followed by `/`.
            '~' => {
                if (self.peek() == '/') return self.lexPath(start);
                return self.makeToken(.error_token, start, 1);
            },
            '&' => {
                if (self.match('&')) return self.makeToken(.amp_amp, start, 2);
                return self.makeToken(.error_token, start, 1);
            },
            '|' => {
                if (self.match('|')) return self.makeToken(.pipe_pipe, start, 2);
                if (self.match('>')) return self.makeToken(.pipe_forward, start, 2);
                return self.makeToken(.error_token, start, 1);
            },
            else => return self.makeToken(.error_token, start, 1),
        }
    }

    fn advance(self: *Scanner) u8 {
        const b = self.source[self.pos];
        self.pos += 1;
        return b;
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.pos >= self.source.len) return false;
        if (self.source[self.pos] != expected) return false;
        self.pos += 1;
        return true;
    }

    fn peek(self: *Scanner) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn peekAhead(self: *Scanner, offset: u32) u8 {
        const i = self.pos + offset;
        if (i >= self.source.len) return 0;
        return self.source[i];
    }

    fn makeToken(self: *Scanner, tt: TokenType, start: u32, len: u32) Token {
        _ = self;
        return Token{ .type = tt, .offset = start, .len = len };
    }

    /// Skip whitespace and comments. Returns the offset of an unterminated
    /// block comment's `/*`, which the caller reports as an invalid token:
    /// a truncated file must not lex as a shorter valid one (`[ 1 2 /*x]`
    /// is not `[ 1 2 ]`).
    fn skipLayout(self: *Scanner) ?u32 {
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                '\r' => {
                    // A structural CR line ending — record the first for the
                    // `cr-line-endings` deprecation gate, then treat as layout.
                    if (self.first_cr == null) self.first_cr = self.pos;
                    self.pos += 1;
                    self.skipWhitespaceRun();
                },
                ' ', '\t', '\n' => {
                    self.pos += 1;
                    self.skipWhitespaceRun();
                },
                '#' => {
                    // Line comment: scan to the next line terminator. A lone
                    // `\r` (old-Mac) ends the line too, matching Nix — otherwise
                    // a CR-terminated comment would swallow the following line.
                    self.pos = @intCast(std.mem.indexOfAnyPos(u8, self.source, self.pos, "\r\n") orelse self.source.len);
                },
                '/' => {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
                        // Block comment
                        const comment_start = self.pos;
                        const body_start = self.pos + 2;
                        const close = if (body_start < self.source.len)
                            std.mem.indexOfPos(u8, self.source, body_start, "*/")
                        else
                            null;
                        self.pos = @intCast(if (close) |c| c + 2 else self.source.len);
                        if (close == null) return comment_start;
                    } else {
                        return null; // single '/' is a token
                    }
                },
                else => return null,
            }
        }
        return null;
    }

    /// SIMD fast path for runs of layout bytes (space/tab/cr/newline).
    /// Stops at the first non-layout byte; `skipLayout` re-dispatches on it
    /// (comment starts, token starts).
    fn skipWhitespaceRun(self: *Scanner) void {
        if (comptime vec_len == 0) return;
        const src = self.source;
        var pos: usize = self.pos;
        while (pos + vec_len <= src.len) {
            const v: Vec = src[pos..][0..vec_len].*;
            const ws = maskEq(v, ' ') | maskEq(v, '\t') | maskEq(v, '\r') | maskEq(v, '\n');
            if (ws != ~@as(VMask, 0)) {
                pos += @ctz(~ws);
                break;
            }
            pos += vec_len;
        }
        self.pos = @intCast(pos);
        // Tail (< vec_len bytes) is handled by skipLayout's scalar dispatch.
    }

    fn lexIdentOrKeyword(self: *Scanner, start: u32) Token {
        if (comptime vec_len > 0) {
            while (self.pos + vec_len <= self.source.len) {
                const v: Vec = self.source[self.pos..][0..vec_len].*;
                const cont = maskIdentCont(v);
                if (cont != ~@as(VMask, 0)) {
                    self.pos += @ctz(~cont);
                    break;
                }
                self.pos += vec_len;
            }
        }
        while (self.pos < self.source.len and hasClass(self.source[self.pos], char_ident_continue)) {
            self.pos += 1;
        }
        // A `/` abutting the identifier's characters makes the whole token a
        // path literal, not an identifier — flex's maximal munch, where PATH
        // outranks IDENT (`common/user-account.nix`, `let/foo`, `a/${x}`).
        if (self.atPathSegment()) return self.lexPath(start);
        const len = self.pos - start;
        const tt = keywordType(self.source[start..][0..len]);
        // Unquoted URI literal (deprecated Nix syntax): a plain identifier
        // immediately followed by `:` and a URI-body char (no whitespace) is a
        // scheme, and the whole `scheme:body` lexes as one string token. A
        // lambda `x: e` has whitespace (or a non-URI char) after the `:`, so it
        // is unaffected. Keywords are never schemes.
        if (tt == .identifier and self.pos < self.source.len and self.source[self.pos] == ':' and
            self.pos + 1 < self.source.len and isUriChar(self.source[self.pos + 1]))
        {
            self.pos += 1; // consume ':'
            while (self.pos < self.source.len and isUriChar(self.source[self.pos])) self.pos += 1;
            return self.makeToken(.uri, start, self.pos - start);
        }
        return self.makeToken(tt, start, len);
    }

    fn isUriChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or switch (c) {
            '%', '/', '?', ':', '@', '&', '=', '+', '$', ',', '-', '_', '.', '!', '~', '*', '\'' => true,
            else => false,
        };
    }

    fn lexNumber(self: *Scanner, start: u32) Token {
        while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
            self.pos += 1;
        }
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            // A `digits.` is a float only per Nix's grammar: `[1-9][0-9]*\.[0-9]*`
            // (int part starts 1-9, empty fraction allowed) or `0?\.[0-9]+` (a
            // single leading `0` needs a fractional digit). Otherwise the `.` is
            // a separate token — `0.`, `00.`, `00012.3` lex as int + `.`/float.
            const int_len = self.pos - start;
            const first = self.source[start];
            const frac_digit = self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]);
            const is_float = (first >= '1' and first <= '9') or (int_len == 1 and first == '0' and frac_digit);
            if (is_float) {
                self.pos += 1;
                const tok = self.lexFractionAndExponent(start);
                // A `/` abutting the number is a path segment, not division:
                // maximal munch makes `6.5/foo` a path, mirroring the ident case.
                if (self.atPathSegment()) return self.lexPath(start);
                return tok;
            }
        }
        // Likewise for an integer prefix: `6/2`, `123/foo` are paths, not `/`.
        if (self.atPathSegment()) return self.lexPath(start);
        return self.makeToken(.integer, start, self.pos - start);
    }

    /// Scan a float's fractional digits and optional exponent, with `self.pos`
    /// positioned just past the decimal point. Used both by `lexNumber` (after
    /// the integer part) and by the leading-dot form (`.5`).
    fn lexFractionAndExponent(self: *Scanner, start: u32) Token {
        while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
            self.pos += 1;
        }
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            const exponent_start = self.pos;
            var exponent_pos = self.pos + 1;
            if (exponent_pos < self.source.len and (self.source[exponent_pos] == '+' or self.source[exponent_pos] == '-')) {
                exponent_pos += 1;
            }
            const digits_start = exponent_pos;
            while (exponent_pos < self.source.len and isDigit(self.source[exponent_pos])) {
                exponent_pos += 1;
            }
            if (exponent_pos > digits_start) {
                self.pos = @intCast(exponent_pos);
            } else {
                self.pos = exponent_start;
            }
        }
        return self.makeToken(.float_val, start, self.pos - start);
    }

    fn lexString(self: *Scanner, start: u32, kind: string_syntax.LiteralKind) Token {
        const end = string_syntax.scanLiteral(self.source, start, kind) orelse {
            self.pos = @intCast(self.source.len);
            return self.makeToken(.error_token, start, self.pos - start);
        };
        self.pos = @intCast(end);
        return self.makeToken(.string, start, self.pos - start);
    }

    fn lexPath(self: *Scanner, start: u32) Token {
        while (self.pos < self.source.len) {
            if (isPathContinue(self.source[self.pos])) {
                self.pos += 1;
                continue;
            }
            if (self.source[self.pos] == '$' and
                self.pos + 1 < self.source.len and
                self.source[self.pos + 1] == '{')
            {
                const end = string_syntax.findInterpolationEnd(self.source, self.pos + 2) orelse break;
                self.pos = @intCast(end + 1);
                continue;
            }
            break;
        }
        return self.makeToken(.path, start, self.pos - start);
    }

    fn lexSearchPath(self: *Scanner, start: u32) Token {
        while (self.pos < self.source.len and self.source[self.pos] != '>') {
            if (!isSearchPathContinue(self.source[self.pos])) break;
            self.pos += 1;
        }
        if (self.pos < self.source.len and self.source[self.pos] == '>') {
            self.pos += 1;
            return self.makeToken(.search_path, start, self.pos - start);
        }
        // No closing `>`: this wasn't a search path after all. Rewind the
        // chars we speculatively consumed (`<foo` in e.g. `a<b`) and emit the
        // bare `<` operator so `foo` re-lexes as a normal token — matching
        // Nix's maximal-munch backtracking (`a<b` is `a < b`).
        self.pos = start + 1;
        return self.makeToken(.less, start, 1);
    }

    fn isAlpha(c: u8) bool {
        return hasClass(c, char_ident_start);
    }

    fn isDigit(c: u8) bool {
        return hasClass(c, char_digit);
    }

    fn isPathContinue(c: u8) bool {
        return hasClass(c, char_path_continue);
    }

    /// True when the token starting at the already-consumed `.` is a Nix
    /// relative path (flex `PATH`), not a bare select `.`, ellipsis, or
    /// leading-dot float. Peek-only: does not advance `self.pos`.
    ///
    /// Matches `{PATH_CHAR}*(\/{PATH_CHAR}+)+` with `PATH_CHAR = [A-Za-z0-9._+-]`,
    /// also allowing `/${` as an interpolated segment opener after the slash.
    fn looksLikeRelativePath(self: *Scanner) bool {
        var i = self.pos;
        // PATH_CHAR* (no slash)
        while (i < self.source.len and isPathChar(self.source[i])) : (i += 1) {}
        // Need at least one /PATH_CHAR+ (or /${) segment
        if (i >= self.source.len or self.source[i] != '/') return false;
        const c = if (i + 1 < self.source.len) self.source[i + 1] else 0;
        if (c == '$' and i + 2 < self.source.len and self.source[i + 2] == '{') return true;
        return c != 0 and isPathChar(c);
    }

    /// Nix flex `PATH_CHAR`: path segment bytes excluding `/`.
    fn isPathChar(c: u8) bool {
        return isAlpha(c) or isDigit(c) or c == '.' or c == '_' or c == '-' or c == '+';
    }

    /// True when `self.pos` sits at a `/` that opens a further path segment,
    /// i.e. the slash abuts a segment char (`[A-Za-z0-9._+-]`, never another
    /// `/`) or a `${` interpolation. After an initial run of path chars — an
    /// identifier or a number — this promotes the token to a path literal per
    /// flex maximal munch. It excludes `a//b` (the char after `/` is `/`, an
    /// update op) and `a / b` / `a/ b` (whitespace, division / syntax error).
    fn atPathSegment(self: *Scanner) bool {
        if (self.peek() != '/') return false;
        const c = self.peekAhead(1);
        if (c == '$' and self.peekAhead(2) == '{') return true;
        return c != '/' and hasClass(c, char_path_continue);
    }

    fn isSearchPathStart(c: u8) bool {
        return hasClass(c, char_ident_start) or c == '.' or c == '-';
    }

    fn isSearchPathContinue(c: u8) bool {
        return hasClass(c, char_path_continue);
    }

    // Keyword lookup: dispatch on length (a jump table) then compare the few
    // candidates of that length. Non-keyword identifiers — the common case —
    // fall straight through, and long identifiers match no length bucket at all.
    //
    // `true`, `false` and `null` are deliberately absent: Nix has no such
    // keywords, only base-environment variables, so a binder shadows them
    // (`let true = 1; in true`) and they are legal wherever an identifier is
    // (`true: true`, `{ null ? 3 }: null`). The compiler folds the unshadowed
    // ones back to `push_true`/`push_false`/`push_null`.
    fn keywordType(s: []const u8) TokenType {
        const eql = std.mem.eql;
        return switch (s.len) {
            2 => if (eql(u8, s, "if")) .kw_if else if (eql(u8, s, "in")) .kw_in else if (eql(u8, s, "or")) .kw_or else .identifier,
            3 => if (eql(u8, s, "let")) .kw_let else if (eql(u8, s, "rec")) .kw_rec else .identifier,
            4 => if (eql(u8, s, "then")) .kw_then else if (eql(u8, s, "else")) .kw_else else if (eql(u8, s, "with")) .kw_with else .identifier,
            6 => if (eql(u8, s, "assert")) .kw_assert else .identifier,
            7 => if (eql(u8, s, "inherit")) .kw_inherit else .identifier,
            else => .identifier,
        };
    }
};

test "scanner recognizes boolean operator tokens" {
    var scanner = Scanner.init("true && false || true ++ []");

    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.amp_amp, scanner.next().type);
    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.pipe_pipe, scanner.next().type);
    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.double_plus, scanner.next().type);
    try std.testing.expectEqual(TokenType.left_bracket, scanner.next().type);
    try std.testing.expectEqual(TokenType.right_bracket, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

// Nix has no `true`/`false`/`null` keywords — they are base-environment
// variables — so the scanner must hand them over as plain identifiers. A
// keyword token here made them unshadowable (`let true = 1; in true`) and
// illegal in binder positions (`true: true`).
test "scanner lexes true, false and null as identifiers" {
    var scanner = Scanner.init("let true = 1; in true");

    try std.testing.expectEqual(TokenType.kw_let, scanner.next().type);
    const bound = scanner.next();
    try std.testing.expectEqual(TokenType.identifier, bound.type);
    try std.testing.expectEqualStrings("true", scanner.source[bound.offset..][0..bound.len]);
    try std.testing.expectEqual(TokenType.equal, scanner.next().type);
    try std.testing.expectEqual(TokenType.integer, scanner.next().type);
    try std.testing.expectEqual(TokenType.semicolon, scanner.next().type);
    try std.testing.expectEqual(TokenType.kw_in, scanner.next().type);
    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);

    // Binder positions the keyword tokens could never reach.
    var lambda = Scanner.init("null: false");
    try std.testing.expectEqual(TokenType.identifier, lambda.next().type);
    try std.testing.expectEqual(TokenType.colon, lambda.next().type);
    try std.testing.expectEqual(TokenType.identifier, lambda.next().type);
}

test "scanner recognizes pipe operator tokens" {
    var scanner = Scanner.init("a |> b <| c");

    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.pipe_forward, scanner.next().type);
    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.pipe_backward, scanner.next().type);
    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner keeps single '<' and '|' behaviour intact" {
    // Regression guard: `<` still comparison, `<nixpkgs>` still a search path,
    // `||` still logical-or — none of these should be swallowed by `<|`/`|>`.
    var lt = Scanner.init("a < b");
    try std.testing.expectEqual(TokenType.identifier, lt.next().type);
    try std.testing.expectEqual(TokenType.less, lt.next().type);
    try std.testing.expectEqual(TokenType.identifier, lt.next().type);

    var sp = Scanner.init("<nixpkgs>");
    try std.testing.expectEqual(TokenType.search_path, sp.next().type);

    var orop = Scanner.init("a || b");
    try std.testing.expectEqual(TokenType.identifier, orop.next().type);
    try std.testing.expectEqual(TokenType.pipe_pipe, orop.next().type);
    try std.testing.expectEqual(TokenType.identifier, orop.next().type);
}

test "scanner: space-free '<' comparison is not a truncated search path" {
    // `a<b` speculatively looks like `<b...>` but has no closing `>`, so it
    // must fall back to `<` + `b` (Nix maximal-munch backtracking) — not
    // swallow `b`. Regression for the search-path rewind.
    var s = Scanner.init("a<b");
    try std.testing.expectEqual(TokenType.identifier, s.next().type);
    const lt = s.next();
    try std.testing.expectEqual(TokenType.less, lt.type);
    const rhs = s.next();
    try std.testing.expectEqual(TokenType.identifier, rhs.type);
    try std.testing.expectEqualStrings("b", s.source[rhs.offset .. rhs.offset + rhs.len]);
}

test "scanner recognizes lambda colon" {
    var scanner = Scanner.init("x: x");

    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.colon, scanner.next().type);
    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner recognizes Nix float exponent forms" {
    var scanner = Scanner.init("5.0e-2 1.E+2 1e2");

    try std.testing.expectEqual(TokenType.float_val, scanner.next().type);
    try std.testing.expectEqual(TokenType.float_val, scanner.next().type);
    try std.testing.expectEqual(TokenType.integer, scanner.next().type);
    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner recognizes simple path literals" {
    var scanner = Scanner.init("./foo ../bar ../../lib /nix/store/abc");

    try std.testing.expectEqual(TokenType.path, scanner.next().type);
    try std.testing.expectEqual(TokenType.path, scanner.next().type);
    try std.testing.expectEqual(TokenType.path, scanner.next().type);
    try std.testing.expectEqual(TokenType.path, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

// Hidden-dir relative paths (`.devops/...`) are valid Nix PATH tokens — used
// by llama.cpp's flake (`callPackage .devops/nix/scope.nix`). Regression for
// scanners that only started paths at `./` / `../`.
test "scanner recognizes leading-dot hidden directory paths" {
    var scanner = Scanner.init(".devops/nix/scope.nix .devops/nix/nixpkgs-instances.nix");

    const t1 = scanner.next();
    try std.testing.expectEqual(TokenType.path, t1.type);
    try std.testing.expectEqualStrings(".devops/nix/scope.nix", scanner.source[t1.offset..][0..t1.len]);
    const t2 = scanner.next();
    try std.testing.expectEqual(TokenType.path, t2.type);
    try std.testing.expectEqualStrings(".devops/nix/nixpkgs-instances.nix", scanner.source[t2.offset..][0..t2.len]);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner: bare leading-dot name is not a path" {
    // No `/` segment → not flex PATH; bare `.` then identifier (Nix errors at parse).
    var scanner = Scanner.init(".devops");

    try std.testing.expectEqual(TokenType.dot, scanner.next().type);
    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner: leading-dot float still works; slash promotes to path" {
    var floats = Scanner.init(".5 .5e3");
    try std.testing.expectEqual(TokenType.float_val, floats.next().type);
    try std.testing.expectEqual(TokenType.float_val, floats.next().type);
    try std.testing.expectEqual(TokenType.eof, floats.next().type);

    var path = Scanner.init(".5/foo");
    try std.testing.expectEqual(TokenType.path, path.next().type);
    try std.testing.expectEqual(TokenType.eof, path.next().type);
}

test "scanner: ellipsis is not a path unless a slash segment follows" {
    var ell = Scanner.init("... ");
    try std.testing.expectEqual(TokenType.ellipsis, ell.next().type);

    var p = Scanner.init(".../x ...foo/bar");
    try std.testing.expectEqual(TokenType.path, p.next().type);
    try std.testing.expectEqual(TokenType.path, p.next().type);
    try std.testing.expectEqual(TokenType.eof, p.next().type);
}

// A digit-leading first component is a normal PATH_CHAR run (`pathWith.nix`
// in nixpkgs' module tests uses `/123abc`); only whitespace or a non-segment
// char after the `/` keeps it division.
test "scanner recognizes digit-leading absolute paths" {
    var scanner = Scanner.init("/123abc /1/2");

    const t1 = scanner.next();
    try std.testing.expectEqual(TokenType.path, t1.type);
    try std.testing.expectEqualStrings("/123abc", scanner.source[t1.offset..][0..t1.len]);
    const t2 = scanner.next();
    try std.testing.expectEqual(TokenType.path, t2.type);
    try std.testing.expectEqualStrings("/1/2", scanner.source[t2.offset..][0..t2.len]);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);

    var div = Scanner.init("6 / 2");
    try std.testing.expectEqual(TokenType.integer, div.next().type);
    try std.testing.expectEqual(TokenType.slash, div.next().type);
    try std.testing.expectEqual(TokenType.integer, div.next().type);
}

test "scanner recognizes interpolated path literals" {
    var scanner = Scanner.init("./${name}/patch ../${dir}/file");

    try std.testing.expectEqual(TokenType.path, scanner.next().type);
    try std.testing.expectEqual(TokenType.path, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner recognizes indented string literals" {
    var scanner = Scanner.init("''\n  ${\"x\"}\n''");

    try std.testing.expectEqual(TokenType.string, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner recognizes nested strings in interpolation" {
    var scanner = Scanner.init("\"a${{ x = \"}\"; }.x}b\"");

    try std.testing.expectEqual(TokenType.string, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

test "scanner recognizes dynamic attribute syntax" {
    var scanner = Scanner.init("attrs.${name}");

    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.dot, scanner.next().type);
    try std.testing.expectEqual(TokenType.dollar_curly, scanner.next().type);
    try std.testing.expectEqual(TokenType.identifier, scanner.next().type);
    try std.testing.expectEqual(TokenType.right_brace, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}

// A truncated file must not lex as a shorter valid one: before this, the
// unterminated branch left the final byte to be re-lexed, so `[ 1 2 /*x]`
// evaluated to `[ 1 2 ]` instead of erroring.
test "scanner: unterminated block comment is an invalid token" {
    var trunc = Scanner.init("[ 1 2 /*x]");
    try std.testing.expectEqual(TokenType.left_bracket, trunc.next().type);
    try std.testing.expectEqual(TokenType.integer, trunc.next().type);
    try std.testing.expectEqual(TokenType.integer, trunc.next().type);
    const bad = trunc.next();
    try std.testing.expectEqual(TokenType.error_token, bad.type);
    try std.testing.expectEqualStrings("/*x]", trunc.source[bad.offset..][0..bad.len]);
    try std.testing.expectEqual(TokenType.eof, trunc.next().type);

    // `/*` with nothing after it at all.
    var bare = Scanner.init("1 /*");
    try std.testing.expectEqual(TokenType.integer, bare.next().type);
    try std.testing.expectEqual(TokenType.error_token, bare.next().type);
    try std.testing.expectEqual(TokenType.eof, bare.next().type);
}

test "scanner: terminated block comments are layout" {
    // `/* */` does not nest in Nix: the first `*/` closes, so the trailing
    // `*/` of `/* /* */` is layout-free source again.
    var nested = Scanner.init("1 /* /* */ 2");
    try std.testing.expectEqual(TokenType.integer, nested.next().type);
    try std.testing.expectEqual(TokenType.integer, nested.next().type);
    try std.testing.expectEqual(TokenType.eof, nested.next().type);

    var at_eof = Scanner.init("1 /**/");
    try std.testing.expectEqual(TokenType.integer, at_eof.next().type);
    try std.testing.expectEqual(TokenType.eof, at_eof.next().type);
}

test "scanner recognizes search path literals" {
    var scanner = Scanner.init("<nixpkgs/lib>");

    try std.testing.expectEqual(TokenType.search_path, scanner.next().type);
    try std.testing.expectEqual(TokenType.eof, scanner.next().type);
}
