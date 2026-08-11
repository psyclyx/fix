//! Small POSIX-ERE-style matcher for Nix regex builtins.

const std = @import("std");
const arena = @import("base").arena;
const SpinMutex = @import("base").sync.SpinMutex;

pub const Match = struct {
    start: usize,
    end: usize,
    captures: []?[]const u8,

    pub fn deinit(self: Match, allocator: std.mem.Allocator) void {
        allocator.free(self.captures);
    }
};

pub const Pattern = struct {
    arena: arena.ArenaAllocator,
    root: *Node,
    capture_count: usize,

    pub fn compile(allocator: std.mem.Allocator, source: []const u8) !Pattern {
        var pattern_arena = arena.ArenaAllocator.init(allocator);
        errdefer pattern_arena.deinit();

        var parser = Parser{
            .source = source,
            .allocator = pattern_arena.allocator(),
        };
        const root = try parser.parse();
        return .{
            .arena = pattern_arena,
            .root = root,
            .capture_count = parser.capture_count,
        };
    }

    pub fn deinit(self: *Pattern) void {
        self.arena.deinit();
    }

    pub fn matchFull(self: *const Pattern, allocator: std.mem.Allocator, text: []const u8) !?Match {
        return self.matchAt(allocator, text, 0, true);
    }

    pub fn find(self: *const Pattern, allocator: std.mem.Allocator, text: []const u8, start: usize) !?Match {
        var index = start;
        while (index <= text.len) : (index += 1) {
            if (try self.matchAt(allocator, text, index, false)) |result| return result;
        }
        return null;
    }

    fn matchAt(self: *const Pattern, allocator: std.mem.Allocator, text: []const u8, start: usize, require_end: bool) !?Match {
        var scratch_arena = arena.ArenaAllocator.init(allocator);
        defer scratch_arena.deinit();
        const scratch = scratch_arena.allocator();

        const captures = try scratch.alloc(CaptureRange, self.capture_count);
        @memset(captures, .{});

        var states: std.ArrayListUnmanaged(State) = .empty;
        defer states.deinit(scratch);

        var ctx = MatchContext{
            .text = text,
            .scratch = scratch,
        };
        try ctx.matchNode(self.root, .{ .pos = start, .captures = captures }, &states);

        var best: ?State = null;
        for (states.items) |state| {
            if (require_end and state.pos != text.len) continue;
            if (best == null or state.pos >= best.?.pos) best = state;
        }
        const chosen = best orelse return null;

        const out_captures = try allocator.alloc(?[]const u8, self.capture_count);
        errdefer allocator.free(out_captures);
        for (chosen.captures, out_captures) |capture, *out| {
            out.* = if (capture.start) |capture_start|
                text[capture_start..capture.end.?]
            else
                null;
        }
        return .{
            .start = start,
            .end = chosen.pos,
            .captures = out_captures,
        };
    }
};

const NodeTag = enum {
    empty,
    literal,
    dot,
    char_class,
    anchor_start,
    anchor_end,
    sequence,
    alternate,
    repeat,
    group,
};

const Repeat = struct {
    min: usize,
    max: ?usize,
};

const PosixClass = enum {
    alnum,
    alpha,
    digit,
    space,
    lower,
    upper,
};

const ClassItemTag = enum { char, range, posix };

const ClassItem = struct {
    tag: ClassItemTag,
    char: u8 = 0,
    range_start: u8 = 0,
    range_end: u8 = 0,
    posix: PosixClass = .alnum,
};

const CharClass = struct {
    negated: bool,
    items: []const ClassItem,
};

const Node = struct {
    tag: NodeTag,
    literal: u8 = 0,
    class: CharClass = .{ .negated = false, .items = &.{} },
    children: []const *Node = &.{},
    child: ?*Node = null,
    repeat: Repeat = .{ .min = 0, .max = null },
    group_index: usize = 0,
};

const Parser = struct {
    source: []const u8,
    index: usize = 0,
    allocator: std.mem.Allocator,
    capture_count: usize = 0,

    fn parse(self: *Parser) anyerror!*Node {
        const root = try self.parseAlternation();
        if (!self.atEnd()) return error.InvalidRegex;
        return root;
    }

    fn parseAlternation(self: *Parser) anyerror!*Node {
        var branches: std.ArrayListUnmanaged(*Node) = .empty;
        defer branches.deinit(self.allocator);

        try branches.append(self.allocator, try self.parseSequence());
        while (self.peek() == '|') {
            self.index += 1;
            try branches.append(self.allocator, try self.parseSequence());
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.node(.{
            .tag = .alternate,
            .children = try self.allocator.dupe(*Node, branches.items),
        });
    }

    fn parseSequence(self: *Parser) anyerror!*Node {
        var nodes: std.ArrayListUnmanaged(*Node) = .empty;
        defer nodes.deinit(self.allocator);

        while (!self.atEnd()) {
            switch (self.peek()) {
                ')', '|' => break,
                else => try nodes.append(self.allocator, try self.parseRepeat()),
            }
        }
        if (nodes.items.len == 0) return self.node(.{ .tag = .empty });
        if (nodes.items.len == 1) return nodes.items[0];
        return self.node(.{
            .tag = .sequence,
            .children = try self.allocator.dupe(*Node, nodes.items),
        });
    }

    fn parseRepeat(self: *Parser) anyerror!*Node {
        const atom = try self.parseAtom();
        const repeat = try self.parseRepeatSuffix() orelse return atom;
        return self.node(.{
            .tag = .repeat,
            .child = atom,
            .repeat = repeat,
        });
    }

    fn parseRepeatSuffix(self: *Parser) anyerror!?Repeat {
        if (self.atEnd()) return null;
        const repeat: ?Repeat = switch (self.peek()) {
            '*' => .{ .min = 0, .max = null },
            '+' => .{ .min = 1, .max = null },
            '?' => .{ .min = 0, .max = 1 },
            '{' => return self.parseIntervalRepeat(),
            else => null,
        };
        const r = repeat orelse return null;
        self.index += 1;
        return r;
    }

    fn parseIntervalRepeat(self: *Parser) anyerror!?Repeat {
        const start = self.index;
        self.index += 1;

        const min = self.parseDecimal() orelse {
            self.index = start;
            return null;
        };

        if (self.peek() == '}') {
            self.index += 1;
            return .{ .min = min, .max = min };
        }

        if (self.peek() != ',') {
            self.index = start;
            return null;
        }
        self.index += 1;

        const max = self.parseDecimal();
        if (self.peek() != '}') {
            self.index = start;
            return null;
        }
        self.index += 1;

        if (max) |limit| {
            if (limit < min) return error.InvalidRegex;
        }
        return .{ .min = min, .max = max };
    }

    fn parseDecimal(self: *Parser) ?usize {
        const start = self.index;
        var value: usize = 0;
        while (!self.atEnd() and std.ascii.isDigit(self.peek())) {
            value = value * 10 + (self.advance() - '0');
        }
        if (self.index == start) return null;
        return value;
    }

    fn parseAtom(self: *Parser) anyerror!*Node {
        if (self.atEnd()) return error.InvalidRegex;
        const c = self.advance();
        return switch (c) {
            '(' => self.parseGroup(),
            '[' => self.parseCharClass(),
            '.' => self.node(.{ .tag = .dot }),
            '^' => self.node(.{ .tag = .anchor_start }),
            '$' => self.node(.{ .tag = .anchor_end }),
            '\\' => self.node(.{ .tag = .literal, .literal = try self.escapedByte() }),
            '*', '+', '?' => error.InvalidRegex,
            else => self.node(.{ .tag = .literal, .literal = c }),
        };
    }

    fn parseGroup(self: *Parser) anyerror!*Node {
        const group_index = self.capture_count;
        self.capture_count += 1;
        const child = try self.parseAlternation();
        if (self.atEnd() or self.advance() != ')') return error.InvalidRegex;
        return self.node(.{
            .tag = .group,
            .child = child,
            .group_index = group_index,
        });
    }

    fn parseCharClass(self: *Parser) anyerror!*Node {
        const negated = if (self.peek() == '^') negated: {
            self.index += 1;
            break :negated true;
        } else false;

        var items: std.ArrayListUnmanaged(ClassItem) = .empty;
        defer items.deinit(self.allocator);

        while (!self.atEnd()) {
            if (self.peek() == ']' and items.items.len > 0) {
                self.index += 1;
                return self.node(.{
                    .tag = .char_class,
                    .class = .{
                        .negated = negated,
                        .items = try self.allocator.dupe(ClassItem, items.items),
                    },
                });
            }

            if (try self.parsePosixClass()) |posix| {
                try items.append(self.allocator, .{ .tag = .posix, .posix = posix });
                continue;
            }

            const first = try self.classByte();
            if (self.peek() == '-' and self.index + 1 < self.source.len and self.source[self.index + 1] != ']') {
                self.index += 1;
                const last = try self.classByte();
                try items.append(self.allocator, .{
                    .tag = .range,
                    .range_start = @min(first, last),
                    .range_end = @max(first, last),
                });
            } else {
                try items.append(self.allocator, .{ .tag = .char, .char = first });
            }
        }
        return error.InvalidRegex;
    }

    fn parsePosixClass(self: *Parser) anyerror!?PosixClass {
        if (self.index + 3 > self.source.len) return null;
        if (self.source[self.index] != '[' or self.source[self.index + 1] != ':') return null;
        const start = self.index + 2;
        var end = start;
        while (end + 1 < self.source.len) : (end += 1) {
            if (self.source[end] == ':' and self.source[end + 1] == ']') {
                const name = self.source[start..end];
                self.index = end + 2;
                if (std.mem.eql(u8, name, "alnum")) return .alnum;
                if (std.mem.eql(u8, name, "alpha")) return .alpha;
                if (std.mem.eql(u8, name, "digit")) return .digit;
                if (std.mem.eql(u8, name, "space")) return .space;
                if (std.mem.eql(u8, name, "lower")) return .lower;
                if (std.mem.eql(u8, name, "upper")) return .upper;
                return error.InvalidRegex;
            }
        }
        return null;
    }

    fn escapedByte(self: *Parser) anyerror!u8 {
        if (self.atEnd()) return error.InvalidRegex;
        return self.advance();
    }

    /// Next byte of a bracket expression body.
    ///
    /// POSIX ERE: inside `[...]`, `.` `*` `[` and `\` lose their special
    /// meaning — a backslash is a literal class member, not an escape.
    /// (Nix `builtins.match` follows this; PCRE-style `[\-]` → only `-`
    /// would reject systemd unit names that embed `\xNN` escapes, e.g.
    /// nixpkgs wireguard peer units ending in `\x3d` for base64 `=`.)
    fn classByte(self: *Parser) anyerror!u8 {
        if (self.atEnd()) return error.InvalidRegex;
        return self.advance();
    }

    fn node(self: *Parser, value: Node) anyerror!*Node {
        const out = try self.allocator.create(Node);
        out.* = value;
        return out;
    }

    fn atEnd(self: *const Parser) bool {
        return self.index >= self.source.len;
    }

    fn peek(self: *const Parser) u8 {
        return if (self.atEnd()) 0 else self.source[self.index];
    }

    fn advance(self: *Parser) u8 {
        const c = self.source[self.index];
        self.index += 1;
        return c;
    }
};

const CaptureRange = struct {
    start: ?usize = null,
    end: ?usize = null,
};

const State = struct {
    pos: usize,
    captures: []CaptureRange,
};

const MatchContext = struct {
    text: []const u8,
    scratch: std.mem.Allocator,

    fn matchNode(self: *MatchContext, node: *const Node, state: State, out: *std.ArrayListUnmanaged(State)) anyerror!void {
        switch (node.tag) {
            .empty => try self.appendState(out, state.pos, state.captures),
            .literal => {
                if (state.pos < self.text.len and self.text[state.pos] == node.literal) {
                    try self.appendState(out, state.pos + 1, state.captures);
                }
            },
            .dot => {
                if (state.pos < self.text.len) try self.appendState(out, state.pos + 1, state.captures);
            },
            .char_class => {
                if (state.pos < self.text.len and matchesClass(node.class, self.text[state.pos])) {
                    try self.appendState(out, state.pos + 1, state.captures);
                }
            },
            .anchor_start => {
                if (state.pos == 0) try self.appendState(out, state.pos, state.captures);
            },
            .anchor_end => {
                if (state.pos == self.text.len) try self.appendState(out, state.pos, state.captures);
            },
            .sequence => try self.matchSequence(node.children, state, out),
            .alternate => {
                for (node.children) |child| try self.matchNode(child, state, out);
            },
            .repeat => try self.matchRepeat(node.child.?, node.repeat, 0, state, out),
            .group => try self.matchGroup(node, state, out),
        }
    }

    fn matchSequence(self: *MatchContext, children: []const *Node, state: State, out: *std.ArrayListUnmanaged(State)) anyerror!void {
        var current: std.ArrayListUnmanaged(State) = .empty;
        defer current.deinit(self.scratch);
        try self.appendState(&current, state.pos, state.captures);

        for (children) |child| {
            var next: std.ArrayListUnmanaged(State) = .empty;
            defer next.deinit(self.scratch);
            for (current.items) |item| try self.matchNode(child, item, &next);
            current.clearRetainingCapacity();
            try current.appendSlice(self.scratch, next.items);
            if (current.items.len == 0) break;
        }

        for (current.items) |item| try self.appendState(out, item.pos, item.captures);
    }

    fn matchRepeat(
        self: *MatchContext,
        child: *const Node,
        repeat: Repeat,
        count: usize,
        state: State,
        out: *std.ArrayListUnmanaged(State),
    ) anyerror!void {
        if (count >= repeat.min) try self.appendState(out, state.pos, state.captures);
        if (repeat.max) |max| {
            if (count >= max) return;
        }

        var next: std.ArrayListUnmanaged(State) = .empty;
        defer next.deinit(self.scratch);
        try self.matchNode(child, state, &next);

        for (next.items) |item| {
            if (item.pos == state.pos) continue;
            try self.matchRepeat(child, repeat, count + 1, item, out);
        }
    }

    fn matchGroup(self: *MatchContext, node: *const Node, state: State, out: *std.ArrayListUnmanaged(State)) anyerror!void {
        var child_states: std.ArrayListUnmanaged(State) = .empty;
        defer child_states.deinit(self.scratch);
        try self.matchNode(node.child.?, state, &child_states);

        for (child_states.items) |child_state| {
            const captures = try self.scratch.dupe(CaptureRange, child_state.captures);
            captures[node.group_index] = .{
                .start = state.pos,
                .end = child_state.pos,
            };
            try out.append(self.scratch, .{
                .pos = child_state.pos,
                .captures = captures,
            });
        }
    }

    fn appendState(self: *MatchContext, out: *std.ArrayListUnmanaged(State), pos: usize, captures: []const CaptureRange) anyerror!void {
        try out.append(self.scratch, .{
            .pos = pos,
            .captures = try self.scratch.dupe(CaptureRange, captures),
        });
    }
};

fn matchesClass(class: CharClass, c: u8) bool {
    for (class.items) |item| {
        const matched = switch (item.tag) {
            .char => c == item.char,
            .range => c >= item.range_start and c <= item.range_end,
            .posix => matchesPosixClass(item.posix, c),
        };
        if (matched) return !class.negated;
    }
    return class.negated;
}

fn matchesPosixClass(class: PosixClass, c: u8) bool {
    return switch (class) {
        .alnum => std.ascii.isAlphanumeric(c),
        .alpha => std.ascii.isAlphabetic(c),
        .digit => std.ascii.isDigit(c),
        .space => std.ascii.isWhitespace(c),
        .lower => std.ascii.isLower(c),
        .upper => std.ascii.isUpper(c),
    };
}

/// Compiled-pattern cache for `builtins.match` and `builtins.split`.
/// Keyed by the pattern text's InternId (the
/// intern table dedupes by content, and its byte storage is stable, so
/// compiled nodes may reference the source slice safely). Entries live
/// until `deinit`. A compiled `Pattern` is immutable after `compile`
/// (matching uses per-call scratch), so concurrent workers share them.
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
    var pattern = try Pattern.compile(std.testing.allocator, "(.*)e?abi.*");
    defer pattern.deinit();

    const result = (try pattern.matchFull(std.testing.allocator, "gnueabihf")).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.captures.len);
    try std.testing.expectEqualStrings("gnue", result.captures[0].?);
}

test "regex supports posix classes alternation and search" {
    var pattern = try Pattern.compile(std.testing.allocator, "[[:space:]]*(-?[[:digit:]]+)[[:space:]]*");
    defer pattern.deinit();

    const result = (try pattern.matchFull(std.testing.allocator, " -42 ")).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("-42", result.captures[0].?);

    var split_pattern = try Pattern.compile(std.testing.allocator, "[^[:alnum:]+._?=-]+");
    defer split_pattern.deinit();
    const found = (try split_pattern.find(std.testing.allocator, "abc///def", 0)).?;
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), found.start);
    try std.testing.expectEqual(@as(usize, 6), found.end);

    var hostname_pattern = try Pattern.compile(std.testing.allocator, "^$|^[[:alnum:]]([[:alnum:]_-]{0,61}[[:alnum:]])?$");
    defer hostname_pattern.deinit();
    const hostname = (try hostname_pattern.matchFull(std.testing.allocator, "nixos")).?;
    defer hostname.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ixos", hostname.captures[0].?);
}

// POSIX bracket expressions treat `\` as a literal member. The class `[\-]`
// therefore matches both backslash and hyphen — matching Nix `builtins.match`
// and the nixpkgs `unitNameType` pattern, which must accept unit names that
// embed systemd escapes such as `\x3d` for `=`.
test "regex char class treats backslash as literal (POSIX ERE)" {
    var slash_hyphen = try Pattern.compile(std.testing.allocator, "[\\-]+");
    defer slash_hyphen.deinit();

    const only_bs = (try slash_hyphen.matchFull(std.testing.allocator, "\\")).?;
    defer only_bs.deinit(std.testing.allocator);
    const only_hyphen = (try slash_hyphen.matchFull(std.testing.allocator, "-")).?;
    defer only_hyphen.deinit(std.testing.allocator);
    const both = (try slash_hyphen.matchFull(std.testing.allocator, "\\-\\")).?;
    defer both.deinit(std.testing.allocator);
    try std.testing.expect((try slash_hyphen.matchFull(std.testing.allocator, "a")) == null);

    // nixpkgs nixos/lib/systemd-lib.nix unitNameType (pattern text as the
    // Nix string produces it after `\\` → `\`).
    const unit_pat = "[a-zA-Z0-9@%:_.\\-]+[.](service|socket|device|mount|automount|swap|target|path|timer|scope|slice)";
    var unit = try Pattern.compile(std.testing.allocator, unit_pat);
    defer unit.deinit();

    // Minimal repro: wireguard peer unit with trailing base64 `=` escaped as `\x3d`.
    const peer = "wireguard-mullvad0-peer-q8TC-ILZWlaydPdkJLkL-pWB8qrK0dWkKtZMGqEElh8\\x3d.service";
    const peer_match = (try unit.matchFull(std.testing.allocator, peer)).?;
    defer peer_match.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("service", peer_match.captures[0].?);

    const plain = (try unit.matchFull(std.testing.allocator, "sshd.service")).?;
    defer plain.deinit(std.testing.allocator);
}
