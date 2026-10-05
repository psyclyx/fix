//! Regular expressions as `builtins.match` and `builtins.split` see them.
//!
//! CppNix hands patterns to libstdc++'s `std::regex` with the POSIX
//! `extended` grammar, so that implementation, not POSIX, defines the
//! language. This is a port of it (GCC 15, `bits/regex_scanner.tcc`,
//! `regex_compiler.tcc`, `regex_automaton.tcc` and the depth-first
//! `regex_executor.tcc`), building the same NFA and searching it in the
//! same order, so that:
//!
//! - the same patterns are rejected: escapes of ordinary characters (`\d`,
//!   `\n`, `\]`), `a{,2}`, `[z-a]`, `[a-z-9]`, and ranges running into
//!   bytes ≥ 0x80, which compare as signed `char`s;
//! - `*?` and `+?` are two quantifiers (the `?` applies to the repetition),
//!   not lazy ones;
//! - the same match and capture groups come out, including where that
//!   isn't POSIX's leftmost-longest rule: `(a|ab)(c|bcd)` against "abcd"
//!   captures "a" and "bcd", and a group keeps what it captured in an
//!   earlier iteration of an enclosing repetition.
//!
//! The executor keeps its own stack rather than recursing per character,
//! so long subjects don't overflow the thread's stack.

const std = @import("std");
const SpinMutex = @import("base").sync.SpinMutex;

pub const Error = error{
    /// Nix: "invalid regular expression".
    InvalidRegex,
    /// libstdc++'s `error_space` (more than 100000 NFA states); Nix:
    /// "memory limit exceeded by regular expression".
    RegexTooLarge,
    OutOfMemory,
};

pub const Match = struct {
    start: usize,
    end: usize,
    /// Groups 1 and up; null for a group that didn't take part.
    captures: []?[]const u8,

    pub fn deinit(self: Match, allocator: std.mem.Allocator) void {
        allocator.free(self.captures);
    }
};

/// Matching small patterns against short strings needs no heap.
const scratch_size = 4096;

/// `_GLIBCXX_REGEX_STATE_LIMIT`.
const state_limit = 100000;
/// Groups nest by recursion in the compiler; deeper patterns count as too
/// large rather than risking the stack.
const max_group_depth = 1000;

const StateId = i32;
const no_state: StateId = -1;

const Opcode = enum(u8) {
    alternative,
    repeat,
    subexpr_begin,
    subexpr_end,
    line_begin,
    line_end,
    match,
    accept,
    dummy,
};

const NfaState = struct {
    op: Opcode,
    next: StateId = no_state,
    /// `alternative`: the left branch; `repeat`: the "once more" branch.
    alt: StateId = no_state,
    /// `subexpr_begin`/`subexpr_end`: the group; `match`: the byte set.
    index: u32 = 0,

    fn hasAlt(self: NfaState) bool {
        return self.op == .alternative or self.op == .repeat;
    }
};

const ByteSet = std.StaticBitSet(256);

pub const Pattern = struct {
    states: []const NfaState,
    sets: []const ByteSet,
    /// Groups including the whole match (group 0).
    sub_count: usize,
    allocator: std.mem.Allocator,

    pub fn compile(allocator: std.mem.Allocator, source: []const u8) Error!Pattern {
        var compiler: Compiler = .{ .allocator = allocator, .scanner = .{ .source = source } };
        defer compiler.deinit();
        try compiler.compile();
        const states = try compiler.nfa.toOwnedSlice(allocator);
        errdefer allocator.free(states);
        return .{
            .states = states,
            .sets = try compiler.sets.toOwnedSlice(allocator),
            .sub_count = compiler.subexpr_count,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pattern) void {
        self.allocator.free(self.states);
        self.allocator.free(self.sets);
    }

    /// `std::regex_match`: the whole of `text`.
    pub fn matchFull(self: *const Pattern, allocator: std.mem.Allocator, text: []const u8) Error!?Match {
        var scratch = std.heap.stackFallback(scratch_size, allocator);
        var executor = try Executor.init(scratch.get(), self, text, 0, .{});
        defer executor.deinit();
        if (!try executor.run(.exact)) return null;
        return try executor.result(allocator);
    }

    /// The matches `std::regex_iterator` visits, as `builtins.split` uses
    /// them.
    pub fn iterator(self: *const Pattern, text: []const u8) Iterator {
        return .{ .pattern = self, .text = text };
    }

    /// `std::regex_search` from `start`.
    fn search(self: *const Pattern, allocator: std.mem.Allocator, text: []const u8, start: usize, flags: Flags) Error!?Match {
        var scratch = std.heap.stackFallback(scratch_size, allocator);
        var executor = try Executor.init(scratch.get(), self, text, start, flags);
        defer executor.deinit();
        if (!try executor.search()) return null;
        return try executor.result(allocator);
    }
};

/// `std::regex_iterator`: after an empty match it first looks for a
/// non-empty one at the same place, then searches on from the next byte.
pub const Iterator = struct {
    pattern: *const Pattern,
    text: []const u8,
    prev_avail: bool = false,
    last: ?struct { start: usize, end: usize } = null,
    done: bool = false,

    pub fn next(self: *Iterator, allocator: std.mem.Allocator) Error!?Match {
        if (self.done) return null;
        const found = try self.advance(allocator);
        if (found) |m| self.last = .{ .start = m.start, .end = m.end } else self.done = true;
        return found;
    }

    fn advance(self: *Iterator, allocator: std.mem.Allocator) Error!?Match {
        const last = self.last orelse return self.pattern.search(allocator, self.text, 0, .{});
        var start = last.end;
        if (last.start == last.end) {
            if (start == self.text.len) return null;
            if (try self.pattern.search(allocator, self.text, start, .{
                .prev_avail = self.prev_avail,
                .not_null = true,
                .continuous = true,
            })) |m| return m;
            start += 1;
        }
        self.prev_avail = true;
        return self.pattern.search(allocator, self.text, start, .{ .prev_avail = true });
    }
};

// --- Scanner (`_Scanner`, extended grammar) ---------------------------------

const Token = enum {
    eof,
    ord_char,
    anychar,
    line_begin,
    line_end,
    closure0,
    closure1,
    opt,
    @"or",
    subexpr_begin,
    subexpr_end,
    bracket_begin,
    bracket_neg_begin,
    bracket_end,
    bracket_dash,
    collsymbol,
    char_class_name,
    equiv_class_name,
    interval_begin,
    interval_end,
    dup_count,
    comma,
};

/// `_M_extended_spec_char`: the bytes with a meaning outside brackets, and
/// the only ones a backslash may escape.
fn isSpecial(c: u8) bool {
    return std.mem.indexOfScalar(u8, ".[\\()*+?{|^$", c) != null;
}

const Scanner = struct {
    source: []const u8,
    pos: usize = 0,
    state: enum { normal, in_bracket, in_brace } = .normal,
    at_bracket_start: bool = false,
    token: Token = .eof,
    value: []const u8 = "",

    fn advance(self: *Scanner) Error!void {
        if (self.pos == self.source.len) {
            self.token = .eof;
            return;
        }
        switch (self.state) {
            .normal => try self.scanNormal(),
            .in_bracket => try self.scanInBracket(),
            .in_brace => try self.scanInBrace(),
        }
    }

    fn ordChar(self: *Scanner, at: usize) void {
        self.token = .ord_char;
        self.value = self.source[at .. at + 1];
    }

    fn scanNormal(self: *Scanner) Error!void {
        const at = self.pos;
        const c = self.source[at];
        self.pos += 1;
        if (!isSpecial(c)) return self.ordChar(at);
        self.token = switch (c) {
            '\\' => {
                // `_M_eat_escape_posix`, built with `__STRICT_ANSI__`: only
                // special characters may be escaped.
                if (self.pos == self.source.len or !isSpecial(self.source[self.pos])) return error.InvalidRegex;
                self.pos += 1;
                return self.ordChar(self.pos - 1);
            },
            '(' => .subexpr_begin,
            ')' => .subexpr_end,
            '[' => blk: {
                self.state = .in_bracket;
                self.at_bracket_start = true;
                if (self.pos < self.source.len and self.source[self.pos] == '^') {
                    self.pos += 1;
                    break :blk .bracket_neg_begin;
                }
                break :blk .bracket_begin;
            },
            '{' => blk: {
                self.state = .in_brace;
                break :blk .interval_begin;
            },
            '^' => .line_begin,
            '$' => .line_end,
            '.' => .anychar,
            '*' => .closure0,
            '+' => .closure1,
            '?' => .opt,
            '|' => .@"or",
            else => unreachable,
        };
    }

    fn scanInBracket(self: *Scanner) Error!void {
        defer self.at_bracket_start = false;
        const at = self.pos;
        const c = self.source[at];
        self.pos += 1;
        switch (c) {
            '-' => self.token = .bracket_dash,
            '[' => {
                if (self.pos == self.source.len) return error.InvalidRegex;
                self.token = switch (self.source[self.pos]) {
                    '.' => .collsymbol,
                    ':' => .char_class_name,
                    '=' => .equiv_class_name,
                    else => return self.ordChar(at),
                };
                try self.eatClass(self.source[self.pos]);
            },
            ']' => if (self.at_bracket_start) self.ordChar(at) else {
                self.token = .bracket_end;
                self.state = .normal;
            },
            else => self.ordChar(at),
        }
    }

    /// The name in `[:name:]`, `[.name.]` or `[=name=]`.
    fn eatClass(self: *Scanner, delimiter: u8) Error!void {
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != delimiter) self.pos += 1;
        self.value = self.source[start..self.pos];
        if (self.pos + 1 >= self.source.len or self.source[self.pos + 1] != ']') return error.InvalidRegex;
        self.pos += 2;
    }

    fn scanInBrace(self: *Scanner) Error!void {
        const at = self.pos;
        const c = self.source[at];
        self.pos += 1;
        if (std.ascii.isDigit(c)) {
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) self.pos += 1;
            self.token = .dup_count;
            self.value = self.source[at..self.pos];
        } else if (c == ',') {
            self.token = .comma;
        } else if (c == '}') {
            self.state = .normal;
            self.token = .interval_end;
        } else return error.InvalidRegex;
    }
};

// --- Compiler (`_Compiler`, `_NFA`, `_StateSeq`) ----------------------------

const Seq = struct {
    start: StateId,
    end: StateId,

    fn single(id: StateId) Seq {
        return .{ .start = id, .end = id };
    }
};

const Compiler = struct {
    allocator: std.mem.Allocator,
    scanner: Scanner,
    nfa: std.ArrayListUnmanaged(NfaState) = .empty,
    sets: std.ArrayListUnmanaged(ByteSet) = .empty,
    stack: std.ArrayListUnmanaged(Seq) = .empty,
    paren_stack: std.ArrayListUnmanaged(u32) = .empty,
    subexpr_count: u32 = 0,
    value: []const u8 = "",
    depth: usize = 0,

    fn deinit(self: *Compiler) void {
        self.nfa.deinit(self.allocator);
        self.sets.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.paren_stack.deinit(self.allocator);
    }

    fn compile(self: *Compiler) Error!void {
        try self.scanner.advance();
        var r = Seq.single(0);
        self.append(&r, try self.insertSubexprBegin());
        try self.disjunction();
        if (!try self.matchToken(.eof)) return error.InvalidRegex;
        self.appendSeq(&r, self.pop());
        self.append(&r, try self.insertSubexprEnd());
        self.append(&r, try self.insert(.{ .op = .accept }));
        self.eliminateDummy();
    }

    fn matchToken(self: *Compiler, token: Token) Error!bool {
        if (self.scanner.token != token) return false;
        self.value = self.scanner.value;
        try self.scanner.advance();
        return true;
    }

    fn insert(self: *Compiler, new: NfaState) Error!StateId {
        try self.nfa.append(self.allocator, new);
        if (self.nfa.items.len > state_limit) return error.RegexTooLarge;
        return @intCast(self.nfa.items.len - 1);
    }

    fn insertSubexprBegin(self: *Compiler) Error!StateId {
        const index = self.subexpr_count;
        self.subexpr_count += 1;
        try self.paren_stack.append(self.allocator, index);
        return self.insert(.{ .op = .subexpr_begin, .index = index });
    }

    fn insertSubexprEnd(self: *Compiler) Error!StateId {
        return self.insert(.{ .op = .subexpr_end, .index = self.paren_stack.pop().? });
    }

    fn insertMatcher(self: *Compiler, set: ByteSet) Error!void {
        try self.sets.append(self.allocator, set);
        try self.push(Seq.single(try self.insert(.{ .op = .match, .index = @intCast(self.sets.items.len - 1) })));
    }

    fn at(self: *Compiler, id: StateId) *NfaState {
        return &self.nfa.items[@intCast(id)];
    }

    fn append(self: *Compiler, seq: *Seq, id: StateId) void {
        self.at(seq.end).next = id;
        seq.end = id;
    }

    fn appendSeq(self: *Compiler, seq: *Seq, other: Seq) void {
        self.at(seq.end).next = other.start;
        seq.end = other.end;
    }

    fn push(self: *Compiler, seq: Seq) Error!void {
        try self.stack.append(self.allocator, seq);
    }

    fn pop(self: *Compiler) Seq {
        return self.stack.pop().?;
    }

    fn disjunction(self: *Compiler) Error!void {
        try self.alternative();
        while (try self.matchToken(.@"or")) {
            var alt1 = self.pop();
            try self.alternative();
            var alt2 = self.pop();
            const end = try self.insert(.{ .op = .dummy });
            self.append(&alt1, end);
            self.append(&alt2, end);
            // The left alternative is `alt`, which the executor tries first.
            try self.push(.{
                .start = try self.insert(.{ .op = .alternative, .next = alt2.start, .alt = alt1.start }),
                .end = end,
            });
        }
    }

    /// A sequence of terms ending in a dummy state (libstdc++ recurses
    /// once per term).
    fn alternative(self: *Compiler) Error!void {
        const base = self.stack.items.len;
        while (try self.term()) {}
        var tail = Seq.single(try self.insert(.{ .op = .dummy }));
        while (self.stack.items.len > base) {
            var seq = self.pop();
            self.appendSeq(&seq, tail);
            tail = seq;
        }
        try self.push(tail);
    }

    fn term(self: *Compiler) Error!bool {
        if (try self.matchToken(.line_begin)) {
            try self.push(Seq.single(try self.insert(.{ .op = .line_begin })));
            return true;
        }
        if (try self.matchToken(.line_end)) {
            try self.push(Seq.single(try self.insert(.{ .op = .line_end })));
            return true;
        }
        if (!try self.atom()) return false;
        while (try self.quantifier()) {}
        return true;
    }

    fn quantifier(self: *Compiler) Error!bool {
        if (try self.matchToken(.closure0)) {
            var e = self.pop();
            const r = Seq.single(try self.insert(.{ .op = .repeat, .alt = e.start }));
            self.appendSeq(&e, r);
            try self.push(r);
        } else if (try self.matchToken(.closure1)) {
            var e = self.pop();
            self.append(&e, try self.insert(.{ .op = .repeat, .alt = e.start }));
            try self.push(e);
        } else if (try self.matchToken(.opt)) {
            var e = self.pop();
            const end = try self.insert(.{ .op = .dummy });
            var r = Seq.single(try self.insert(.{ .op = .repeat, .alt = e.start }));
            self.append(&e, end);
            self.append(&r, end);
            try self.push(r);
        } else if (try self.matchToken(.interval_begin)) {
            if (!try self.matchToken(.dup_count)) return error.InvalidRegex;
            const r = self.pop();
            var e = Seq.single(try self.insert(.{ .op = .dummy }));
            const min_rep = try self.curIntValue();
            var infinite = false;
            var n: i64 = 0;
            if (try self.matchToken(.comma)) {
                if (try self.matchToken(.dup_count))
                    n = @as(i64, try self.curIntValue()) - min_rep
                else
                    infinite = true;
            }
            if (!try self.matchToken(.interval_end)) return error.InvalidRegex;
            var i: i64 = 0;
            while (i < min_rep) : (i += 1) self.appendSeq(&e, try self.clone(r));
            if (infinite) {
                var tmp = try self.clone(r);
                const s = Seq.single(try self.insert(.{ .op = .repeat, .alt = tmp.start }));
                self.appendSeq(&tmp, s);
                self.appendSeq(&e, s);
            } else {
                if (n < 0) return error.InvalidRegex;
                const end = try self.insert(.{ .op = .dummy });
                var optional: std.ArrayListUnmanaged(StateId) = .empty;
                defer optional.deinit(self.allocator);
                i = 0;
                while (i < n) : (i += 1) {
                    const tmp = try self.clone(r);
                    const alt = try self.insert(.{ .op = .repeat, .next = tmp.start, .alt = end });
                    try optional.append(self.allocator, alt);
                    self.appendSeq(&e, .{ .start = alt, .end = tmp.end });
                }
                self.append(&e, end);
                // Built with "skip" as `alt`; the executor wants "once
                // more" there.
                for (optional.items) |id| {
                    const s = self.at(id);
                    std.mem.swap(StateId, &s.next, &s.alt);
                }
            }
            try self.push(e);
        } else return false;
        return true;
    }

    /// `_M_cur_int_value(10)`, which rejects counts that overflow an `int`.
    fn curIntValue(self: *Compiler) Error!i32 {
        var v: i32 = 0;
        for (self.value) |c| {
            v = std.math.mul(i32, v, 10) catch return error.InvalidRegex;
            v = std.math.add(i32, v, c - '0') catch return error.InvalidRegex;
        }
        return v;
    }

    /// `_StateSeq::_M_clone`, keeping its traversal order: a state reached
    /// twice before it's copied is copied twice, which counts towards the
    /// state limit.
    fn clone(self: *Compiler, seq: Seq) Error!Seq {
        var map: std.AutoHashMapUnmanaged(StateId, StateId) = .empty;
        defer map.deinit(self.allocator);
        var todo: std.ArrayListUnmanaged(StateId) = .empty;
        defer todo.deinit(self.allocator);
        try todo.append(self.allocator, seq.start);
        while (todo.pop()) |u| {
            const dup = self.at(u).*;
            try map.put(self.allocator, u, try self.insert(dup));
            if (dup.hasAlt() and dup.alt != no_state and !map.contains(dup.alt))
                try todo.append(self.allocator, dup.alt);
            if (u == seq.end) continue;
            if (dup.next != no_state and !map.contains(dup.next))
                try todo.append(self.allocator, dup.next);
        }
        var it = map.valueIterator();
        while (it.next()) |id| {
            const s = self.at(id.*);
            if (s.next != no_state) s.next = map.get(s.next) orelse s.next;
            if (s.hasAlt() and s.alt != no_state) s.alt = map.get(s.alt) orelse s.alt;
        }
        return .{ .start = map.get(seq.start).?, .end = map.get(seq.end).? };
    }

    fn eliminateDummy(self: *Compiler) void {
        for (self.nfa.items) |*s| {
            while (s.next >= 0 and self.at(s.next).op == .dummy) s.next = self.at(s.next).next;
            if (s.hasAlt()) {
                while (s.alt >= 0 and self.at(s.alt).op == .dummy) s.alt = self.at(s.alt).next;
            }
        }
    }

    fn atom(self: *Compiler) Error!bool {
        if (try self.matchToken(.anychar)) {
            // POSIX `.`: anything but NUL.
            var set = ByteSet.initFull();
            set.unset(0);
            try self.insertMatcher(set);
        } else if (try self.matchToken(.ord_char)) {
            var set = ByteSet.initEmpty();
            set.set(self.value[0]);
            try self.insertMatcher(set);
        } else if (try self.matchToken(.subexpr_begin)) {
            if (self.depth == max_group_depth) return error.RegexTooLarge;
            self.depth += 1;
            defer self.depth -= 1;
            var r = Seq.single(try self.insertSubexprBegin());
            try self.disjunction();
            if (!try self.matchToken(.subexpr_end)) return error.InvalidRegex;
            self.appendSeq(&r, self.pop());
            self.append(&r, try self.insertSubexprEnd());
            try self.push(r);
        } else {
            const negated = try self.matchToken(.bracket_neg_begin);
            if (!negated and !try self.matchToken(.bracket_begin)) return false;
            try self.insertMatcher(try self.bracketExpression(negated));
        }
        return true;
    }

    /// `_M_insert_bracket_matcher` and `_M_expression_term`.
    fn bracketExpression(self: *Compiler, negated: bool) Error!ByteSet {
        var matcher: Bracket = .{};
        defer matcher.deinit(self.allocator);
        // The last single character, which may yet start a range.
        var last: union(enum) { none, char: u8, class } = .none;

        if (try self.matchToken(.ord_char)) {
            last = .{ .char = self.value[0] };
        } else if (try self.matchToken(.bracket_dash)) {
            last = .{ .char = '-' };
        }
        while (true) {
            if (try self.matchToken(.bracket_end)) break;
            if (try self.matchToken(.collsymbol)) {
                const c = lookupCollateName(self.value) orelse return error.InvalidRegex;
                matcher.chars.set(c);
                if (last == .char) matcher.chars.set(last.char);
                last = .{ .char = c };
            } else if (try self.matchToken(.equiv_class_name)) {
                if (last == .char) matcher.chars.set(last.char);
                last = .class;
                const c = lookupCollateName(self.value) orelse return error.InvalidRegex;
                matcher.equivalents.set(std.ascii.toLower(c));
                matcher.has_equivalents = true;
            } else if (try self.matchToken(.char_class_name)) {
                if (last == .char) matcher.chars.set(last.char);
                last = .class;
                matcher.classes |= lookupClassName(self.value) orelse return error.InvalidRegex;
            } else if (try self.matchToken(.ord_char)) {
                if (last == .char) matcher.chars.set(last.char);
                last = .{ .char = self.value[0] };
            } else if (try self.matchToken(.bracket_dash)) {
                if (try self.matchToken(.bracket_end)) {
                    // A dash before `]` is a character.
                    if (last == .char) matcher.chars.set(last.char);
                    last = .{ .char = '-' };
                    break;
                }
                const first = switch (last) {
                    .char => |c| c,
                    // A dash may only follow a range's start, or begin
                    // the expression.
                    .class, .none => return error.InvalidRegex,
                };
                const end = if (try self.matchToken(.ord_char))
                    self.value[0]
                else if (try self.matchToken(.bracket_dash))
                    '-'
                else
                    return error.InvalidRegex;
                try matcher.addRange(self.allocator, first, end);
                last = .none;
            } else return error.InvalidRegex;
        }
        if (last == .char) matcher.chars.set(last.char);
        return matcher.set(negated);
    }
};

/// `_BracketMatcher` in the classic "C" locale.
const Bracket = struct {
    chars: ByteSet = ByteSet.initEmpty(),
    ranges: std.ArrayListUnmanaged([2]u8) = .empty,
    classes: u16 = 0,
    /// Lowercased: `transform_primary` folds case.
    equivalents: ByteSet = ByteSet.initEmpty(),
    has_equivalents: bool = false,

    fn deinit(self: *Bracket, allocator: std.mem.Allocator) void {
        self.ranges.deinit(allocator);
    }

    /// Ranges compare `char`s, which are signed: `[a-é]` is backwards.
    fn addRange(self: *Bracket, allocator: std.mem.Allocator, first: u8, last: u8) Error!void {
        if (signed(first) > signed(last)) return error.InvalidRegex;
        try self.ranges.append(allocator, .{ first, last });
    }

    fn set(self: *const Bracket, negated: bool) ByteSet {
        var out = ByteSet.initEmpty();
        for (0..256) |i| {
            const c: u8 = @intCast(i);
            if (self.matches(c) != negated) out.set(c);
        }
        return out;
    }

    fn matches(self: *const Bracket, c: u8) bool {
        if (self.chars.isSet(c)) return true;
        for (self.ranges.items) |range| {
            if (signed(range[0]) <= signed(c) and signed(c) <= signed(range[1])) return true;
        }
        if (isClass(c, self.classes)) return true;
        return self.has_equivalents and self.equivalents.isSet(std.ascii.toLower(c));
    }
};

fn signed(c: u8) i8 {
    return @bitCast(c);
}

const class_alnum: u16 = 1 << 0;
const class_alpha: u16 = 1 << 1;
const class_blank: u16 = 1 << 2;
const class_cntrl: u16 = 1 << 3;
const class_digit: u16 = 1 << 4;
const class_graph: u16 = 1 << 5;
const class_lower: u16 = 1 << 6;
const class_print: u16 = 1 << 7;
const class_punct: u16 = 1 << 8;
const class_space: u16 = 1 << 9;
const class_upper: u16 = 1 << 10;
const class_xdigit: u16 = 1 << 11;
const class_underscore: u16 = 1 << 12;

/// `regex_traits::lookup_classname`, which ignores case and knows `d`, `w`
/// and `s` too.
fn lookupClassName(name: []const u8) ?u16 {
    const names = [_]struct { []const u8, u16 }{
        .{ "d", class_digit },
        .{ "w", class_alnum | class_underscore },
        .{ "s", class_space },
        .{ "alnum", class_alnum },
        .{ "alpha", class_alpha },
        .{ "blank", class_blank },
        .{ "cntrl", class_cntrl },
        .{ "digit", class_digit },
        .{ "graph", class_graph },
        .{ "lower", class_lower },
        .{ "print", class_print },
        .{ "punct", class_punct },
        .{ "space", class_space },
        .{ "upper", class_upper },
        .{ "xdigit", class_xdigit },
    };
    for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    }
    return null;
}

/// `regex_traits::isctype` in the "C" locale: ASCII only.
fn isClass(c: u8, classes: u16) bool {
    const Check = struct { u16, bool };
    const checks = [_]Check{
        .{ class_alnum, std.ascii.isAlphanumeric(c) },
        .{ class_alpha, std.ascii.isAlphabetic(c) },
        .{ class_blank, c == ' ' or c == '\t' },
        .{ class_cntrl, c < 0x20 or c == 0x7f },
        .{ class_digit, std.ascii.isDigit(c) },
        .{ class_graph, c > 0x20 and c < 0x7f },
        .{ class_lower, std.ascii.isLower(c) },
        .{ class_print, c >= 0x20 and c < 0x7f },
        .{ class_punct, c > 0x20 and c < 0x7f and !std.ascii.isAlphanumeric(c) },
        .{ class_space, std.ascii.isWhitespace(c) },
        .{ class_upper, std.ascii.isUpper(c) },
        .{ class_xdigit, std.ascii.isHex(c) },
        .{ class_underscore, c == '_' },
    };
    for (checks) |check| {
        if (classes & check[0] != 0 and check[1]) return true;
    }
    return false;
}

/// `regex_traits::lookup_collatename`: the POSIX names of the ASCII
/// characters. Letters are their own names; `[.0.]` must be `[.zero.]`.
fn lookupCollateName(name: []const u8) ?u8 {
    const names = [128][]const u8{
        "NUL",              "SOH",                  "STX",               "ETX",
        "EOT",              "ENQ",                  "ACK",               "alert",
        "backspace",        "tab",                  "newline",           "vertical-tab",
        "form-feed",        "carriage-return",      "SO",                "SI",
        "DLE",              "DC1",                  "DC2",               "DC3",
        "DC4",              "NAK",                  "SYN",               "ETB",
        "CAN",              "EM",                   "SUB",               "ESC",
        "IS4",              "IS3",                  "IS2",               "IS1",
        "space",            "exclamation-mark",     "quotation-mark",    "number-sign",
        "dollar-sign",      "percent-sign",         "ampersand",         "apostrophe",
        "left-parenthesis", "right-parenthesis",    "asterisk",          "plus-sign",
        "comma",            "hyphen",               "period",            "slash",
        "zero",             "one",                  "two",               "three",
        "four",             "five",                 "six",               "seven",
        "eight",            "nine",                 "colon",             "semicolon",
        "less-than-sign",   "equals-sign",          "greater-than-sign", "question-mark",
        "commercial-at",    "A",                    "B",                 "C",
        "D",                "E",                    "F",                 "G",
        "H",                "I",                    "J",                 "K",
        "L",                "M",                    "N",                 "O",
        "P",                "Q",                    "R",                 "S",
        "T",                "U",                    "V",                 "W",
        "X",                "Y",                    "Z",                 "left-square-bracket",
        "backslash",        "right-square-bracket", "circumflex",        "underscore",
        "grave-accent",     "a",                    "b",                 "c",
        "d",                "e",                    "f",                 "g",
        "h",                "i",                    "j",                 "k",
        "l",                "m",                    "n",                 "o",
        "p",                "q",                    "r",                 "s",
        "t",                "u",                    "v",                 "w",
        "x",                "y",                    "z",                 "left-curly-bracket",
        "vertical-line",    "right-curly-bracket",  "tilde",             "DEL",
    };
    for (names, 0..) |candidate, c| {
        if (std.mem.eql(u8, name, candidate)) return @intCast(c);
    }
    return null;
}

// --- Executor (`_Executor`, depth-first) -------------------------------------

const Flags = struct {
    /// The search doesn't start at the beginning of the input: `^` can't
    /// match there.
    prev_avail: bool = false,
    not_null: bool = false,
    continuous: bool = false,
};

const SubMatch = struct {
    first: usize = 0,
    second: usize = 0,
    matched: bool = false,
};

const RepCount = struct {
    pos: usize = 0,
    count: u8 = 0,
};

/// The recursive executor's calls, and what each undoes when it returns.
const Task = union(enum) {
    visit: StateId,
    restore_first: struct { sub: u32, first: usize },
    restore_sub: struct { sub: u32, value: SubMatch },
    restore_current: usize,
    restore_rep: struct { state: StateId, value: RepCount },
    decrement_rep: StateId,
    /// After a repetition's "once more" branch: its "done" branch, unless
    /// that found a match.
    repeat_next: StateId,
    /// After an alternative's left branch: its right one.
    alternative_next: StateId,
    alternative_merge: bool,
};

const Executor = struct {
    allocator: std.mem.Allocator,
    pattern: *const Pattern,
    text: []const u8,
    begin: usize,
    current: usize = 0,
    flags: Flags,
    cur_results: []SubMatch,
    results: []SubMatch,
    rep_count: []RepCount,
    has_sol: bool = false,
    sol_pos: ?usize = null,
    tasks: std.ArrayListUnmanaged(Task) = .empty,

    fn init(allocator: std.mem.Allocator, pattern: *const Pattern, text: []const u8, begin: usize, flags: Flags) Error!Executor {
        const cur_results = try allocator.alloc(SubMatch, pattern.sub_count);
        errdefer allocator.free(cur_results);
        const results = try allocator.alloc(SubMatch, pattern.sub_count);
        errdefer allocator.free(results);
        const rep_count = try allocator.alloc(RepCount, pattern.states.len);
        @memset(results, .{});
        @memset(rep_count, .{});
        return .{
            .allocator = allocator,
            .pattern = pattern,
            .text = text,
            .begin = begin,
            .flags = flags,
            .cur_results = cur_results,
            .results = results,
            .rep_count = rep_count,
        };
    }

    fn deinit(self: *Executor) void {
        self.allocator.free(self.cur_results);
        self.allocator.free(self.results);
        self.allocator.free(self.rep_count);
        self.tasks.deinit(self.allocator);
    }

    fn result(self: *const Executor, allocator: std.mem.Allocator) Error!Match {
        const captures = try allocator.alloc(?[]const u8, self.results.len - 1);
        for (self.results[1..], captures) |sub, *capture| {
            capture.* = if (sub.matched) self.text[sub.first..sub.second] else null;
        }
        return .{ .start = self.results[0].first, .end = self.results[0].second, .captures = captures };
    }

    /// `_M_search`: from `begin`, then (unless `continuous`) each later
    /// position.
    fn search(self: *Executor) Error!bool {
        if (try self.run(.prefix)) return true;
        if (self.flags.continuous) return false;
        self.flags.prev_avail = true;
        while (self.begin != self.text.len) {
            self.begin += 1;
            if (try self.run(.prefix)) return true;
        }
        return false;
    }

    const Mode = enum { exact, prefix };

    /// `_M_main_dispatch`.
    fn run(self: *Executor, mode: Mode) Error!bool {
        self.current = self.begin;
        self.has_sol = false;
        self.sol_pos = null;
        @memcpy(self.cur_results, self.results);
        try self.tasks.append(self.allocator, .{ .visit = 0 });
        while (self.tasks.pop()) |task| switch (task) {
            .visit => |i| try self.visit(mode, i),
            .restore_first => |r| self.cur_results[r.sub].first = r.first,
            .restore_sub => |r| self.cur_results[r.sub] = r.value,
            .restore_current => |pos| self.current = pos,
            .restore_rep => |r| self.rep_count[@intCast(r.state)] = r.value,
            .decrement_rep => |i| self.rep_count[@intCast(i)].count -= 1,
            .repeat_next => |i| if (!self.has_sol) try self.push(.{ .visit = self.pattern.states[@intCast(i)].next }),
            .alternative_next => |i| {
                // POSIX: try the right branch too, and keep a longer match.
                try self.push(.{ .alternative_merge = self.has_sol });
                self.has_sol = false;
                try self.push(.{ .visit = self.pattern.states[@intCast(i)].next });
            },
            .alternative_merge => |had| self.has_sol = self.has_sol or had,
        };
        return self.has_sol;
    }

    fn push(self: *Executor, task: Task) Error!void {
        try self.tasks.append(self.allocator, task);
    }

    fn visit(self: *Executor, mode: Mode, i: StateId) Error!void {
        if (i < 0) return;
        const s = self.pattern.states[@intCast(i)];
        switch (s.op) {
            .repeat => {
                // Greedy: once more first.
                try self.push(.{ .repeat_next = i });
                try self.repOnceMore(i);
            },
            .subexpr_begin => {
                const sub = &self.cur_results[s.index];
                try self.push(.{ .restore_first = .{ .sub = s.index, .first = sub.first } });
                sub.first = self.current;
                try self.push(.{ .visit = s.next });
            },
            .subexpr_end => {
                const sub = &self.cur_results[s.index];
                try self.push(.{ .restore_sub = .{ .sub = s.index, .value = sub.* } });
                sub.second = self.current;
                sub.matched = true;
                try self.push(.{ .visit = s.next });
            },
            .line_begin => if (self.current == self.begin and !self.flags.prev_avail) try self.push(.{ .visit = s.next }),
            .line_end => if (self.current == self.text.len) try self.push(.{ .visit = s.next }),
            .match => {
                if (self.current == self.text.len) return;
                if (!self.pattern.sets[s.index].isSet(self.text[self.current])) return;
                try self.push(.{ .restore_current = self.current });
                self.current += 1;
                try self.push(.{ .visit = s.next });
            },
            .accept => self.accept(mode),
            .alternative => {
                try self.push(.{ .alternative_next = i });
                try self.push(.{ .visit = s.alt });
            },
            .dummy => try self.push(.{ .visit = s.next }),
        }
    }

    /// `_M_rep_once_more`: a repetition may go round without consuming
    /// anything, but only twice in a row at the same position.
    fn repOnceMore(self: *Executor, i: StateId) Error!void {
        const count = &self.rep_count[@intCast(i)];
        const alt = self.pattern.states[@intCast(i)].alt;
        if (count.count == 0 or count.pos != self.current) {
            try self.push(.{ .restore_rep = .{ .state = i, .value = count.* } });
            count.* = .{ .pos = self.current, .count = 1 };
            try self.push(.{ .visit = alt });
        } else if (count.count < 2) {
            try self.push(.{ .decrement_rep = i });
            count.count += 1;
            try self.push(.{ .visit = alt });
        }
    }

    fn accept(self: *Executor, mode: Mode) void {
        self.has_sol = switch (mode) {
            .exact => self.current == self.text.len,
            .prefix => true,
        };
        if (self.current == self.begin and self.flags.not_null) self.has_sol = false;
        if (!self.has_sol) return;
        // POSIX: a later solution replaces an earlier one only if it's
        // longer.
        if (self.sol_pos == null or self.sol_pos.? < self.current) {
            self.sol_pos = self.current;
            @memcpy(self.results, self.cur_results);
        }
    }
};

/// Compiled-pattern cache for `builtins.match` and `builtins.split`.
/// Keyed by the pattern text's InternId (the intern table dedupes by
/// content). Entries live until `deinit`. A compiled `Pattern` is
/// immutable after `compile` (matching uses per-call scratch), so
/// concurrent workers share them.
pub const PatternCache = struct {
    allocator: std.mem.Allocator,
    mu: SpinMutex = .{},
    map: std.AutoHashMapUnmanaged(u32, *Pattern) = .empty,

    pub fn init(allocator: std.mem.Allocator) PatternCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PatternCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |p| {
            p.*.deinit();
            self.allocator.destroy(p.*);
        }
        self.map.deinit(self.allocator);
    }

    /// The compiled pattern for `source` (interned under `key`),
    /// compiling and caching on first use. Compile errors are not
    /// cached — they propagate each time (regex errors are terminal
    /// in practice, so the recompile cost is irrelevant).
    pub fn get(self: *PatternCache, key: u32, source: []const u8) !*const Pattern {
        self.mu.lock();
        defer self.mu.unlock();
        const gop = try self.map.getOrPut(self.allocator, key);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = self.map.remove(key);
        const p = try self.allocator.create(Pattern);
        errdefer self.allocator.destroy(p);
        p.* = try Pattern.compile(self.allocator, source);
        gop.value_ptr.* = p;
        return p;
    }
};

fn expectMatch(pattern_source: []const u8, text: []const u8, expected: ?[]const ?[]const u8) !void {
    var pattern = try Pattern.compile(std.testing.allocator, pattern_source);
    defer pattern.deinit();
    const got = try pattern.matchFull(std.testing.allocator, text);
    defer if (got) |m| m.deinit(std.testing.allocator);
    const want = expected orelse return std.testing.expect(got == null);
    const m = got orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(want.len, m.captures.len);
    for (want, m.captures) |w, c| {
        if (w) |text_w| try std.testing.expectEqualStrings(text_w, c orelse return error.TestExpectedCapture) else try std.testing.expect(c == null);
    }
}

test "PatternCache returns the same compiled pattern for repeated keys" {
    var cache = PatternCache.init(std.testing.allocator);
    defer cache.deinit();

    const a = try cache.get(7, "a(b|c)*");
    const b = try cache.get(7, "a(b|c)*");
    try std.testing.expectEqual(a, b);

    const other = try cache.get(9, "[[:digit:]]+");
    try std.testing.expect(a != other);

    const matched = (try a.matchFull(std.testing.allocator, "abcb")).?;
    defer matched.deinit(std.testing.allocator);
}

test "regex match returns captures for full matches" {
    try expectMatch("(.*)e?abi.*", "gnueabihf", &.{"gnue"});
    try expectMatch("[[:space:]]*(-?[[:digit:]]+)[[:space:]]*", " -42 ", &.{"-42"});
    try expectMatch("^$|^[[:alnum:]]([[:alnum:]_-]{0,61}[[:alnum:]])?$", "nixos", &.{"ixos"});
}

test "regex search finds the leftmost match" {
    var pattern = try Pattern.compile(std.testing.allocator, "[^[:alnum:]+._?=-]+");
    defer pattern.deinit();
    var it = pattern.iterator("abc///def");
    const found = (try it.next(std.testing.allocator)).?;
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), found.start);
    try std.testing.expectEqual(@as(usize, 6), found.end);
    try std.testing.expect(try it.next(std.testing.allocator) == null);
}

// POSIX bracket expressions treat `\` as a literal member. The class `[\-]`
// therefore matches both backslash and hyphen — matching Nix `builtins.match`
// and the nixpkgs `unitNameType` pattern, which must accept unit names that
// embed systemd escapes such as `\x3d` for `=`.
test "regex char class treats backslash as literal (POSIX ERE)" {
    try expectMatch("[\\-]+", "\\", &.{});
    try expectMatch("[\\-]+", "-", &.{});
    try expectMatch("[\\-]+", "\\-\\", &.{});
    try expectMatch("[\\-]+", "a", null);

    // nixpkgs nixos/lib/systemd-lib.nix unitNameType (pattern text as the
    // Nix string produces it after `\\` → `\`).
    const unit_pat = "[a-zA-Z0-9@%:_.\\-]+[.](service|socket|device|mount|automount|swap|target|path|timer|scope|slice)";
    // Minimal repro: wireguard peer unit with trailing base64 `=` escaped as `\x3d`.
    try expectMatch(unit_pat, "wireguard-mullvad0-peer-q8TC-ILZWlaydPdkJLkL-pWB8qrK0dWkKtZMGqEElh8\\x3d.service", &.{"service"});
    try expectMatch(unit_pat, "sshd.service", &.{"service"});
}

test "regex syntax is libstdc++'s extended grammar" {
    const invalid = [_][]const u8{
        "{",     "a{",      "a{1",           "a{,1}",     "a{2,1}",  "a{ 1}",    "{1}",           "a|{1}",
        "*a",    "^*",      "a|*",           "(",         ")",       "a)",       "(*)",           "(?:a)",
        "\\",    "\\d",     "\\w",           "\\n",       "\\]",     "\\}",      "\\a",           "[a",
        "[z-a]", "[a-z-9]", "[[:alpha:]-z]", "[[:foo:]]", "[[.0.]]", "[a-\xc3]", "a{2147483648}", "[[",
    };
    for (invalid) |source| {
        const result = Pattern.compile(std.testing.allocator, source);
        if (result) |pattern| {
            var p = pattern;
            p.deinit();
            std.debug.print("accepted: {s}\n", .{source});
            return error.TestExpectedError;
        } else |err| try std.testing.expectEqual(error.InvalidRegex, err);
    }
    try std.testing.expectError(error.RegexTooLarge, Pattern.compile(std.testing.allocator, "a{99999}"));
    try std.testing.expectError(error.RegexTooLarge, Pattern.compile(std.testing.allocator, "a{1,99999}"));

    // `}` and `]` are ordinary; `*?` is `(a*)?`; `\{` escapes.
    try expectMatch("a}]", "a}]", &.{});
    try expectMatch("a*?", "aa", &.{});
    try expectMatch("a+*", "", &.{});
    try expectMatch("\\{\\.", "{.", &.{});
    try expectMatch("a?{2}", "a", &.{});
    try expectMatch("a{1}{2}", "a", null);
    try expectMatch("|a", "", &.{});
    try expectMatch("a^", "a", null);
    // Collating elements, equivalence classes and more class names.
    try expectMatch("[[.a.]][[.hyphen.]-z][[.space.]]", "a- ", &.{});
    try expectMatch("[[=a=]]+", "aA", &.{});
    try expectMatch("[[:W:]][[:d:]][[:BLANK:]]", "_1\t", &.{});
    try expectMatch("[\x80-\xff]+", "\xc3\xa9", &.{});
    try expectMatch("[^a]", "\xc3", &.{});
    try expectMatch("[]a]", "]", &.{});
    try expectMatch("[^]a]", "b", &.{});
    try expectMatch("[--z]", "a", &.{});
}

test "regex captures follow libstdc++'s depth-first search" {
    try expectMatch("(a|ab)(c|bcd)(d*)", "abcd", &.{ "a", "bcd", "" });
    try expectMatch("((a)|b)*", "ab", &.{ "b", "a" });
    try expectMatch("(a*)*", "aa", &.{""});
    try expectMatch("(a*)+(b)", "b", &.{ "", "b" });
    try expectMatch("(){1}", "", &.{""});
    try expectMatch("(a)|b", "b", &.{null});
}

fn expectSplit(pattern_source: []const u8, text: []const u8, expected: []const [2]usize) !void {
    var pattern = try Pattern.compile(std.testing.allocator, pattern_source);
    defer pattern.deinit();
    var it = pattern.iterator(text);
    for (expected) |want| {
        const m = (try it.next(std.testing.allocator)) orelse return error.TestExpectedMatch;
        defer m.deinit(std.testing.allocator);
        try std.testing.expectEqual(want, [2]usize{ m.start, m.end });
    }
    try std.testing.expect(try it.next(std.testing.allocator) == null);
}

test "regex iteration steps over empty matches like std::regex_iterator" {
    try expectSplit("a*", "bab", &.{ .{ 0, 0 }, .{ 1, 2 }, .{ 2, 2 }, .{ 3, 3 } });
    try expectSplit("b*", "abba", &.{ .{ 0, 0 }, .{ 1, 3 }, .{ 3, 3 }, .{ 4, 4 } });
    try expectSplit("^", "ab", &.{.{ 0, 0 }});
    try expectSplit("$", "ab", &.{.{ 2, 2 }});
    try expectSplit("(a|ab)(c|bcd)(d*)", "xabcdy", &.{.{ 1, 5 }});
}

test "regex matching keeps its own stack for long subjects" {
    const text = try std.testing.allocator.alloc(u8, 1 << 16);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    try expectMatch("(a*)", text, &.{text});
}
