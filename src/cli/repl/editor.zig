//! The line-editor state machine: keys in → buffer/mode changes + reactions
//! out. Pure — no terminal I/O, no timing. The driver (repl.zig) feeds it
//! decoded `keys.Key` events and renders its `view()` after each one; tests
//! feed it key sequences and assert on buffer, cursor, and reactions.
//!
//! Editing model: emacs-style movement and kill/yank, multiline buffers with
//! hard '\n' (up/down move within lines first, history only from the
//! first/last line), readline-style completion (common prefix first, list on
//! the second tab), Ctrl-R incremental history search, and smart-enter —
//! Enter submits only when the input parses as a complete expression (or is
//! a `:command`); otherwise it inserts a newline. Alt-Enter always submits.

const std = @import("std");
const keys = @import("keys.zig");
const width_mod = @import("width.zig");
const history_mod = @import("history.zig");

pub const Reaction = enum {
    none,
    /// The buffer is ready: take it with `takeText`.
    submit,
    /// Ctrl-C: the driver prints feedback and asks for a fresh view.
    cancel,
    /// Ctrl-D on an empty buffer: end the session.
    eof,
    /// Ctrl-L: driver clears the screen, then redraws.
    clear_screen,
    /// Ctrl-Z: driver suspends the process, then redraws.
    suspend_process,
    bell,
};

/// Pluggable completion source. `complete` returns candidates for the text
/// before `cursor` plus the byte span `[start, end)` they replace; results
/// are allocated in the arena passed in.
pub const Completer = struct {
    ctx: *anyopaque,
    completeFn: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, text: []const u8, cursor: usize) anyerror!Result,

    pub const Result = struct {
        start: usize,
        end: usize,
        items: []const []const u8,
    };

    pub fn none() Completer {
        const Callbacks = struct {
            fn complete(_: *anyopaque, _: std.mem.Allocator, _: []const u8, cursor: usize) anyerror!Result {
                return .{ .start = cursor, .end = cursor, .items = &.{} };
            }
        };
        return .{ .ctx = undefined, .completeFn = Callbacks.complete };
    }
};

/// Is `text` a complete expression (submit) or a prefix of one (continue)?
pub const CompleteCheck = struct {
    ctx: *anyopaque,
    isCompleteFn: *const fn (ctx: *anyopaque, text: []const u8) bool,

    pub fn always() CompleteCheck {
        const Callbacks = struct {
            fn is(_: *anyopaque, _: []const u8) bool {
                return true;
            }
        };
        return .{ .ctx = undefined, .isCompleteFn = Callbacks.is };
    }
};

const kill_ring_cap = 8;

pub const Editor = struct {
    allocator: std.mem.Allocator,
    history: *history_mod.History,
    completer: Completer,
    check: CompleteCheck,

    buffer: std.ArrayListUnmanaged(u8) = .empty,
    cursor: usize = 0,

    /// History navigation: null = editing a fresh line; otherwise the index
    /// being viewed. `saved` holds the fresh line while browsing.
    hist_index: ?usize = null,
    saved: std.ArrayListUnmanaged(u8) = .empty,

    /// Kill ring (owned entries, newest at `kill_head`).
    kill_ring: [kill_ring_cap]?[]u8 = [_]?[]u8{null} ** kill_ring_cap,
    kill_head: usize = 0,
    /// Yank state for M-y: span of the last yank, and which ring slot it was.
    last_yank: ?struct { start: usize, len: usize, slot: usize } = null,
    /// Consecutive-kill accumulation (readline: C-k C-k appends).
    last_was_kill: bool = false,

    /// Reverse-i-search state (Ctrl-R).
    search: ?Search = null,

    /// Completion menu to show below the input (arena-owned), plus the
    /// double-tab detection.
    menu: ?[]const []const u8 = null,
    completion: ?Completion = null,
    menu_arena: std.heap.ArenaAllocator,
    last_was_tab: bool = false,

    /// Goal column (display cells) for consecutive up/down movement.
    goal_col: ?usize = null,

    const Search = struct {
        query: std.ArrayListUnmanaged(u8) = .empty,
        /// Current match in history, if any.
        match: ?usize = null,
        /// Buffer + cursor as they were when the search began.
        saved_buffer: []u8,
        saved_cursor: usize,
        failed: bool = false,
    };

    const Completion = struct {
        start: usize,
        end: usize,
        selected: ?usize = null,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        history: *history_mod.History,
        completer: Completer,
        check: CompleteCheck,
    ) Editor {
        return .{
            .allocator = allocator,
            .history = history,
            .completer = completer,
            .check = check,
            .menu_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit(self.allocator);
        self.saved.deinit(self.allocator);
        for (&self.kill_ring) |*slot| if (slot.*) |s| self.allocator.free(s);
        if (self.search) |*s| {
            s.query.deinit(self.allocator);
            self.allocator.free(s.saved_buffer);
        }
        self.menu_arena.deinit();
    }

    /// Reset for a fresh input line (keeps the kill ring and history).
    pub fn reset(self: *Editor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_index = null;
        self.saved.clearRetainingCapacity();
        self.last_yank = null;
        self.last_was_kill = false;
        self.exitSearch(false) catch {};
        self.clearMenu();
        self.last_was_tab = false;
        self.goal_col = null;
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buffer.items;
    }

    pub fn cursorOffset(self: *const Editor) usize {
        return self.cursor;
    }

    /// Hand the buffer to the caller (owned); the editor is left reset.
    pub fn takeText(self: *Editor) ![]u8 {
        const out = try self.allocator.dupe(u8, self.buffer.items);
        self.reset();
        return out;
    }

    /// The prompt text to display: search mode replaces the prompt.
    pub fn searchPrompt(self: *const Editor, buf: []u8) ?[]const u8 {
        const s = &(self.search orelse return null);
        return std.fmt.bufPrint(buf, "({s}r-search)`{s}': ", .{
            if (s.failed) "failing " else "",
            s.query.items,
        }) catch "(r-search): ";
    }

    pub fn menuLines(self: *const Editor) []const []const u8 {
        return self.menu orelse &.{};
    }

    // -- key dispatch --------------------------------------------------------

    pub const KeyError = error{OutOfMemory};

    pub fn handleKey(self: *Editor, key: keys.Key) KeyError!Reaction {
        // Pasted content is inserted literally: no completion, no history,
        // no submission. Newlines inside a paste become buffer newlines.
        if (key.pasted) {
            self.clearTransient();
            switch (key.code) {
                .cp => |cp| if (isPrintable(cp)) try self.insertCp(cp),
                .enter => try self.insertCp('\n'),
                .tab => try self.insertCp('\t'),
                else => {},
            }
            return .none;
        }

        if (self.search != null) return self.handleSearchKey(key);

        const was_tab = self.last_was_tab;
        const was_kill = self.last_was_kill;
        self.last_was_tab = false;
        self.last_was_kill = false;
        // Any key other than completion cycling dismisses the menu.
        if (key.code != .tab and key.code != .backtab) self.clearMenu();
        // Vertical-movement goal column survives only up/down chains.
        if (key.code != .up and key.code != .down) self.goal_col = null;

        switch (key.code) {
            .cp => |cp| {
                if (key.ctrl and !key.alt) return self.handleCtrl(cp, was_kill);
                if (key.alt) return self.handleAlt(cp, was_kill);
                if (isPrintable(cp)) {
                    try self.insertCp(cp);
                    self.hist_index = null;
                }
                return .none;
            },
            .enter => {
                if (key.alt) return self.submitNow();
                return self.smartEnter();
            },
            .tab => {
                if (self.buffer.items.len == 0 or allWhitespace(self.buffer.items[0..self.cursor])) {
                    // Tab at the start of a line: literal indent.
                    try self.insertCp('\t');
                    return .none;
                }
                if (self.menu != null) return self.cycleCompletion(true);
                return self.completeAtCursor(was_tab);
            },
            .backtab => {
                if (self.buffer.items.len == 0 or allWhitespace(self.buffer.items[0..self.cursor])) return .none;
                if (self.menu == null) {
                    _ = try self.completeAtCursor(true);
                    if (self.menu == null) return .none;
                }
                return self.cycleCompletion(false);
            },
            .backspace => {
                if (key.alt) {
                    try self.killRange(self.wordLeft(), self.cursor, .backward, was_kill);
                    return .none;
                }
                self.deleteBack();
                return .none;
            },
            .delete => {
                self.deleteForward();
                return .none;
            },
            .left => {
                if (key.ctrl or key.alt) {
                    self.cursor = self.wordLeft();
                } else if (self.cursor > 0) {
                    self.cursor = width_mod.prevBoundary(self.buffer.items, self.cursor);
                }
                return .none;
            },
            .right => {
                if (key.ctrl or key.alt) {
                    self.cursor = self.wordRight();
                } else if (self.cursor < self.buffer.items.len) {
                    self.cursor = width_mod.nextBoundary(self.buffer.items, self.cursor);
                }
                return .none;
            },
            .up => return self.moveUp(),
            .down => return self.moveDown(),
            .home => {
                self.cursor = self.lineStart(self.cursor);
                return .none;
            },
            .end => {
                self.cursor = self.lineEnd(self.cursor);
                return .none;
            },
            .escape => {
                self.clearMenu();
                return .none;
            },
            .paste_begin, .paste_end => return .none,
            .insert, .page_up, .page_down, .unknown => return .none,
        }
    }

    fn handleCtrl(self: *Editor, letter: u21, was_kill: bool) !Reaction {
        switch (letter) {
            'a' => self.cursor = self.lineStart(self.cursor),
            'e' => self.cursor = self.lineEnd(self.cursor),
            'b' => {
                if (self.cursor > 0) self.cursor = width_mod.prevBoundary(self.buffer.items, self.cursor);
            },
            'f' => {
                if (self.cursor < self.buffer.items.len) self.cursor = width_mod.nextBoundary(self.buffer.items, self.cursor);
            },
            'p' => return self.moveUp(),
            'n' => return self.moveDown(),
            'd' => {
                if (self.buffer.items.len == 0) return .eof;
                self.deleteForward();
            },
            'h' => self.deleteBack(),
            'k' => try self.killRange(self.cursor, self.lineEndForKill(self.cursor), .forward, was_kill),
            'u' => try self.killRange(self.lineStart(self.cursor), self.cursor, .backward, was_kill),
            'w' => try self.killRange(self.whitespaceWordLeft(), self.cursor, .backward, was_kill),
            'y' => try self.yank(),
            't' => self.transpose(),
            'l' => return .clear_screen,
            'c' => return .cancel,
            'z' => return .suspend_process,
            'r' => try self.enterSearch(),
            'g' => return .bell, // nothing to abort outside search mode
            'j' => return self.smartEnter(),
            'o' => try self.insertCp('\n'), // open line: newline without submit
            else => return .none,
        }
        return .none;
    }

    fn handleAlt(self: *Editor, cp: u21, was_kill: bool) !Reaction {
        switch (cp) {
            'b' => self.cursor = self.wordLeft(),
            'f' => self.cursor = self.wordRight(),
            'd' => try self.killRange(self.cursor, self.wordRight(), .forward, was_kill),
            'y' => try self.yankPop(),
            '<' => self.cursor = 0,
            '>' => self.cursor = self.buffer.items.len,
            else => return .none,
        }
        return .none;
    }

    fn clearTransient(self: *Editor) void {
        self.clearMenu();
        self.last_was_tab = false;
        self.last_was_kill = false;
        self.goal_col = null;
    }

    // -- submission ----------------------------------------------------------

    fn submitNow(self: *Editor) Reaction {
        self.clearMenu();
        return .submit;
    }

    fn smartEnter(self: *Editor) !Reaction {
        const t = self.buffer.items;
        const trimmed = std.mem.trim(u8, t, " \t\r\n");
        // Empty and `:command` inputs always submit as-is.
        if (trimmed.len == 0 or trimmed[0] == ':') return self.submitNow();
        // Editing the middle of a multiline buffer: Enter opens a line
        // (submission from mid-buffer is almost always an accident there);
        // Alt-Enter submits from anywhere.
        const multiline = std.mem.indexOfScalar(u8, t, '\n') != null;
        if (multiline and self.cursor < t.len) {
            try self.insertCp('\n');
            return .none;
        }
        if (self.check.isCompleteFn(self.check.ctx, t)) return self.submitNow();
        try self.insertCp('\n');
        return .none;
    }

    // -- insertion / deletion -------------------------------------------------

    fn insertCp(self: *Editor, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.buffer.insertSlice(self.allocator, self.cursor, buf[0..n]);
        self.cursor += n;
    }

    pub fn insertText(self: *Editor, s: []const u8) !void {
        try self.buffer.insertSlice(self.allocator, self.cursor, s);
        self.cursor += s.len;
    }

    fn deleteBack(self: *Editor) void {
        if (self.cursor == 0) return;
        const start = width_mod.prevBoundary(self.buffer.items, self.cursor);
        self.buffer.replaceRangeAssumeCapacity(start, self.cursor - start, &.{});
        self.cursor = start;
        self.hist_index = null;
    }

    fn deleteForward(self: *Editor) void {
        if (self.cursor >= self.buffer.items.len) return;
        const end = width_mod.nextBoundary(self.buffer.items, self.cursor);
        self.buffer.replaceRangeAssumeCapacity(self.cursor, end - self.cursor, &.{});
        self.hist_index = null;
    }

    fn transpose(self: *Editor) void {
        const t = self.buffer.items;
        if (t.len < 2) return;
        // At end of line, transpose the last two; else the chars around point.
        var mid = self.cursor;
        if (mid >= t.len or mid == self.lineEnd(mid)) mid = width_mod.prevBoundary(t, @min(mid, t.len));
        if (mid == 0) return;
        const a_start = width_mod.prevBoundary(t, mid);
        const b_end = width_mod.nextBoundary(t, mid);
        if (b_end == mid) return;
        var tmp: [8]u8 = undefined;
        const a_len = mid - a_start;
        const b_len = b_end - mid;
        if (a_len + b_len > tmp.len) return;
        @memcpy(tmp[0..b_len], t[mid..b_end]);
        @memcpy(tmp[b_len .. b_len + a_len], t[a_start..mid]);
        @memcpy(self.buffer.items[a_start..b_end], tmp[0 .. a_len + b_len]);
        self.cursor = b_end;
    }

    // -- lines & words --------------------------------------------------------

    fn lineStart(self: *const Editor, from: usize) usize {
        const t = self.buffer.items;
        if (std.mem.lastIndexOfScalar(u8, t[0..from], '\n')) |nl| return nl + 1;
        return 0;
    }

    fn lineEnd(self: *const Editor, from: usize) usize {
        const t = self.buffer.items;
        return std.mem.indexOfScalarPos(u8, t, from, '\n') orelse t.len;
    }

    /// C-k target: end of line, or (when already there) the '\n' itself.
    fn lineEndForKill(self: *const Editor, from: usize) usize {
        const le = self.lineEnd(from);
        if (le == from and le < self.buffer.items.len) return le + 1;
        return le;
    }

    fn isWordCp(cp: u21) bool {
        return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or
            (cp >= '0' and cp <= '9') or cp == '_' or cp == '\'' or cp == '-' or cp > 0x7F;
    }

    fn wordLeft(self: *const Editor) usize {
        const t = self.buffer.items;
        var i = self.cursor;
        while (i > 0) {
            const p = width_mod.prevBoundary(t, i);
            if (isWordCp(cpAt(t, p))) break;
            i = p;
        }
        while (i > 0) {
            const p = width_mod.prevBoundary(t, i);
            if (!isWordCp(cpAt(t, p))) break;
            i = p;
        }
        return i;
    }

    fn wordRight(self: *const Editor) usize {
        const t = self.buffer.items;
        var i = self.cursor;
        while (i < t.len and !isWordCp(cpAt(t, i))) i = width_mod.nextBoundary(t, i);
        while (i < t.len and isWordCp(cpAt(t, i))) i = width_mod.nextBoundary(t, i);
        return i;
    }

    /// C-w: back over whitespace, then over non-whitespace (readline unix-word).
    fn whitespaceWordLeft(self: *const Editor) usize {
        const t = self.buffer.items;
        var i = self.cursor;
        while (i > 0) {
            const p = width_mod.prevBoundary(t, i);
            if (!std.ascii.isWhitespace(t[p])) break;
            i = p;
        }
        while (i > 0) {
            const p = width_mod.prevBoundary(t, i);
            if (std.ascii.isWhitespace(t[p])) break;
            i = p;
        }
        return i;
    }

    fn cpAt(t: []const u8, i: usize) u21 {
        var it = width_mod.Utf8Iterator{ .text = t, .i = i };
        const cp = it.next() orelse return 0;
        return cp.cp;
    }

    // -- vertical movement + history -----------------------------------------

    fn displayCol(self: *const Editor, pos: usize) usize {
        const t = self.buffer.items;
        const start = self.lineStart(pos);
        var col: usize = 0;
        var it = width_mod.Utf8Iterator{ .text = t[start..pos] };
        while (it.next()) |cp| col += width_mod.cpWidth(cp.cp);
        return col;
    }

    fn posAtCol(self: *const Editor, line_start: usize, col: usize) usize {
        const t = self.buffer.items;
        var pos = line_start;
        var c: usize = 0;
        var it = width_mod.Utf8Iterator{ .text = t[line_start..] };
        while (it.next()) |cp| {
            if (cp.cp == '\n') break;
            const w = width_mod.cpWidth(cp.cp);
            if (c + w > col) break;
            c += w;
            pos = line_start + cp.offset + cp.len;
        }
        return pos;
    }

    fn moveUp(self: *Editor) !Reaction {
        const start = self.lineStart(self.cursor);
        if (start > 0) {
            const col = self.goal_col orelse self.displayCol(self.cursor);
            self.goal_col = col;
            const prev_start = self.lineStart(start - 1);
            self.cursor = self.posAtCol(prev_start, col);
            return .none;
        }
        return self.historyPrev();
    }

    fn moveDown(self: *Editor) !Reaction {
        const end = self.lineEnd(self.cursor);
        if (end < self.buffer.items.len) {
            const col = self.goal_col orelse self.displayCol(self.cursor);
            self.goal_col = col;
            self.cursor = self.posAtCol(end + 1, col);
            return .none;
        }
        return self.historyNext();
    }

    fn historyPrev(self: *Editor) !Reaction {
        const n = self.history.count();
        if (n == 0) return .bell;
        if (self.hist_index) |i| {
            if (i == 0) return .bell;
            try self.loadHistory(i - 1);
        } else {
            self.saved.clearRetainingCapacity();
            try self.saved.appendSlice(self.allocator, self.buffer.items);
            try self.loadHistory(n - 1);
        }
        return .none;
    }

    fn historyNext(self: *Editor) !Reaction {
        const i = self.hist_index orelse return .bell;
        if (i + 1 < self.history.count()) {
            try self.loadHistory(i + 1);
        } else {
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(self.allocator, self.saved.items);
            self.cursor = self.buffer.items.len;
            self.hist_index = null;
        }
        return .none;
    }

    fn loadHistory(self: *Editor, index: usize) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, self.history.get(index));
        self.cursor = self.buffer.items.len;
        self.hist_index = index;
    }

    // -- kill ring ------------------------------------------------------------

    const KillDir = enum { forward, backward };

    fn killRange(self: *Editor, start: usize, end: usize, dir: KillDir, accumulate: bool) !void {
        if (start >= end) {
            self.last_was_kill = accumulate; // keep an accumulation chain alive
            return;
        }
        const killed = self.buffer.items[start..end];
        if (accumulate and self.kill_ring[self.kill_head] != null) {
            const old = self.kill_ring[self.kill_head].?;
            const merged = if (dir == .forward)
                try std.mem.concat(self.allocator, u8, &.{ old, killed })
            else
                try std.mem.concat(self.allocator, u8, &.{ killed, old });
            self.allocator.free(old);
            self.kill_ring[self.kill_head] = merged;
        } else {
            self.kill_head = (self.kill_head + 1) % kill_ring_cap;
            if (self.kill_ring[self.kill_head]) |old| self.allocator.free(old);
            self.kill_ring[self.kill_head] = try self.allocator.dupe(u8, killed);
        }
        self.buffer.replaceRangeAssumeCapacity(start, end - start, &.{});
        self.cursor = start;
        self.last_was_kill = true;
        self.hist_index = null;
    }

    fn yank(self: *Editor) !void {
        const entry = self.kill_ring[self.kill_head] orelse return;
        const start = self.cursor;
        try self.insertText(entry);
        self.last_yank = .{ .start = start, .len = entry.len, .slot = self.kill_head };
    }

    fn yankPop(self: *Editor) !void {
        const ly = self.last_yank orelse return;
        // Only valid right after a yank at the same spot.
        if (self.cursor != ly.start + ly.len) return;
        var slot = (ly.slot + kill_ring_cap - 1) % kill_ring_cap;
        var tries: usize = 0;
        while (self.kill_ring[slot] == null and tries < kill_ring_cap) : (tries += 1) {
            slot = (slot + kill_ring_cap - 1) % kill_ring_cap;
        }
        const entry = self.kill_ring[slot] orelse return;
        self.buffer.replaceRangeAssumeCapacity(ly.start, ly.len, &.{});
        self.cursor = ly.start;
        try self.insertText(entry);
        self.last_yank = .{ .start = ly.start, .len = entry.len, .slot = slot };
    }

    // -- completion -----------------------------------------------------------

    fn clearMenu(self: *Editor) void {
        self.menu = null;
        self.completion = null;
        _ = self.menu_arena.reset(.retain_capacity);
    }

    fn completeAtCursor(self: *Editor, second_tab: bool) !Reaction {
        self.clearMenu();
        const arena = self.menu_arena.allocator();
        const result = self.completer.completeFn(self.completer.ctx, arena, self.buffer.items, self.cursor) catch {
            return .bell;
        };
        if (result.items.len == 0) return .bell;

        const span = self.buffer.items[result.start..result.end];
        if (result.items.len == 1) {
            try self.replaceSpan(result.start, result.end, result.items[0]);
            return .none;
        }
        // Extend to the longest common prefix if that makes progress.
        const lcp = commonPrefix(result.items);
        if (lcp.len > span.len) {
            try self.replaceSpan(result.start, result.end, lcp);
            self.last_was_tab = true;
            return .none;
        }
        // No progress: list on the second tab.
        if (second_tab) {
            self.menu = result.items;
            self.completion = .{ .start = result.start, .end = result.end };
            self.last_was_tab = true;
            return .none;
        }
        self.last_was_tab = true;
        return .bell;
    }

    fn cycleCompletion(self: *Editor, forward: bool) !Reaction {
        const items = self.menu orelse return .none;
        if (items.len == 0) return .none;
        const state = &self.completion.?;
        const next = if (state.selected) |selected|
            if (forward) (selected + 1) % items.len else (selected + items.len - 1) % items.len
        else if (forward)
            0
        else
            items.len - 1;
        try self.replaceSpan(state.start, state.end, items[next]);
        state.end = state.start + items[next].len;
        state.selected = next;
        self.last_was_tab = true;
        return .none;
    }

    fn replaceSpan(self: *Editor, start: usize, end: usize, replacement: []const u8) !void {
        try self.buffer.replaceRange(self.allocator, start, end - start, replacement);
        self.cursor = start + replacement.len;
        self.hist_index = null;
    }

    fn commonPrefix(items: []const []const u8) []const u8 {
        var prefix = items[0];
        for (items[1..]) |item| {
            var i: usize = 0;
            const max = @min(prefix.len, item.len);
            while (i < max and prefix[i] == item[i]) i += 1;
            prefix = prefix[0..i];
            if (prefix.len == 0) break;
        }
        return prefix;
    }

    // -- reverse-i-search -----------------------------------------------------

    fn enterSearch(self: *Editor) !void {
        if (self.search != null) return;
        self.search = .{
            .saved_buffer = try self.allocator.dupe(u8, self.buffer.items),
            .saved_cursor = self.cursor,
        };
        // An empty query matches nothing yet; wait for input.
    }

    /// Leave search mode. `restore` puts the pre-search buffer back
    /// (Ctrl-G abort); otherwise the current match stays for editing.
    fn exitSearch(self: *Editor, restore: bool) !void {
        var s = self.search orelse return;
        self.search = null;
        if (restore) {
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(self.allocator, s.saved_buffer);
            self.cursor = s.saved_cursor;
        }
        s.query.deinit(self.allocator);
        self.allocator.free(s.saved_buffer);
    }

    fn searchApply(self: *Editor) !void {
        var s = &self.search.?;
        const from = if (s.match) |m| m else (if (self.history.count() == 0) return else self.history.count() - 1);
        if (self.history.searchBack(s.query.items, from)) |found| {
            s.match = found;
            s.failed = false;
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(self.allocator, self.history.get(found));
            self.cursor = self.buffer.items.len;
        } else {
            s.failed = true;
        }
    }

    fn handleSearchKey(self: *Editor, key: keys.Key) !Reaction {
        switch (key.code) {
            .cp => |cp| {
                if (key.isCtrl('r')) {
                    // Next older match.
                    var s = &self.search.?;
                    if (s.match) |m| {
                        if (m > 0) {
                            if (self.history.searchBack(s.query.items, m - 1)) |found| {
                                s.match = found;
                                s.failed = false;
                                self.buffer.clearRetainingCapacity();
                                try self.buffer.appendSlice(self.allocator, self.history.get(found));
                                self.cursor = self.buffer.items.len;
                            } else s.failed = true;
                        } else s.failed = true;
                    } else try self.searchApply();
                    return .none;
                }
                if (key.isCtrl('g')) {
                    try self.exitSearch(true);
                    return .none;
                }
                if (key.isCtrl('c')) {
                    try self.exitSearch(true);
                    return .cancel;
                }
                if (!key.ctrl and !key.alt and isPrintable(cp)) {
                    var s = &self.search.?;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return .none;
                    try s.query.appendSlice(self.allocator, buf[0..n]);
                    s.match = null; // restart from the newest entry
                    try self.searchApply();
                    return .none;
                }
                // Any other chord: accept the match, replay the key normally.
                try self.exitSearch(false);
                return self.handleKey(key);
            },
            .backspace => {
                var s = &self.search.?;
                if (s.query.items.len > 0) {
                    const nb = width_mod.prevBoundary(s.query.items, s.query.items.len);
                    s.query.shrinkRetainingCapacity(nb);
                    s.match = null;
                    if (s.query.items.len > 0) try self.searchApply() else s.failed = false;
                }
                return .none;
            },
            .enter => {
                // Accept the match and treat Enter normally (smart-submit).
                try self.exitSearch(false);
                return self.handleKey(key);
            },
            .escape => {
                try self.exitSearch(false);
                return .none;
            },
            else => {
                try self.exitSearch(false);
                return self.handleKey(key);
            },
        }
    }

    fn isPrintable(cp: u21) bool {
        return cp >= 0x20 and cp != 0x7F;
    }

    fn allWhitespace(s: []const u8) bool {
        for (s) |c| if (!std.ascii.isWhitespace(c)) return false;
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestRig = struct {
    history: history_mod.History,
    editor: Editor,

    fn init() TestRig {
        return .{
            .history = history_mod.History.init(testing.allocator),
            .editor = undefined,
        };
    }

    fn start(self: *TestRig, completer: Completer, check: CompleteCheck) void {
        self.editor = Editor.init(testing.allocator, &self.history, completer, check);
    }

    fn deinit(self: *TestRig) void {
        self.editor.deinit();
        self.history.deinit();
    }

    fn type_(self: *TestRig, s: []const u8) !void {
        var it = width_mod.Utf8Iterator{ .text = s };
        while (it.next()) |cp| {
            _ = try self.editor.handleKey(.{ .code = .{ .cp = cp.cp } });
        }
    }

    fn key(self: *TestRig, k: keys.Key) !Reaction {
        return self.editor.handleKey(k);
    }
};

fn incompleteIfOpenBrace(_: *anyopaque, t: []const u8) bool {
    var depth: i32 = 0;
    for (t) |c| {
        if (c == '{') depth += 1;
        if (c == '}') depth -= 1;
    }
    return depth <= 0;
}

test "insert, move, delete with utf8" {
    var rig = TestRig.init();
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    const e = &rig.editor;

    try rig.type_("aé中");
    try testing.expectEqualStrings("aé中", e.text());
    _ = try rig.key(.{ .code = .left });
    _ = try rig.key(.{ .code = .left });
    _ = try rig.key(.{ .code = .backspace });
    try testing.expectEqualStrings("é中", e.text());
    try testing.expectEqual(@as(usize, 0), e.cursor);
    _ = try rig.key(.{ .code = .delete });
    try testing.expectEqualStrings("中", e.text());
}

test "word movement and kills use ident chars" {
    var rig = TestRig.init();
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    const e = &rig.editor;

    try rig.type_("foo.bar-baz qux");
    // M-b: over "qux".
    _ = try rig.key(.{ .code = .{ .cp = 'b' }, .alt = true });
    try testing.expectEqual(@as(usize, 12), e.cursor);
    // M-b again: over "bar-baz" ('-' is an ident char in nix).
    _ = try rig.key(.{ .code = .{ .cp = 'b' }, .alt = true });
    try testing.expectEqual(@as(usize, 4), e.cursor);
    // M-d kills "bar-baz".
    _ = try rig.key(.{ .code = .{ .cp = 'd' }, .alt = true });
    try testing.expectEqualStrings("foo. qux", e.text());
    // C-y yanks it back.
    _ = try rig.key(keys.Key.ctrlKey('y'));
    try testing.expectEqualStrings("foo.bar-baz qux", e.text());
}

test "ctrl-k / ctrl-u kill and accumulate; yank restores" {
    var rig = TestRig.init();
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    const e = &rig.editor;

    try rig.type_("hello world");
    _ = try rig.key(keys.Key.ctrlKey('a'));
    // Two consecutive C-k on a two-line buffer would accumulate; here one
    // C-k takes the whole line.
    _ = try rig.key(keys.Key.ctrlKey('k'));
    try testing.expectEqualStrings("", e.text());
    _ = try rig.key(keys.Key.ctrlKey('y'));
    try testing.expectEqualStrings("hello world", e.text());

    // C-u kills back to line start.
    _ = try rig.key(keys.Key.ctrlKey('u'));
    try testing.expectEqualStrings("", e.text());
    _ = try rig.key(keys.Key.ctrlKey('y'));
    try testing.expectEqualStrings("hello world", e.text());
}

test "ctrl-w kills a whitespace word" {
    var rig = TestRig.init();
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    try rig.type_("builtins.map f");
    _ = try rig.key(keys.Key.ctrlKey('w'));
    try testing.expectEqualStrings("builtins.map ", rig.editor.text());
    _ = try rig.key(keys.Key.ctrlKey('w'));
    try testing.expectEqualStrings("", rig.editor.text());
}

test "history up/down with saved fresh line" {
    var rig = TestRig.init();
    try rig.history.add("first");
    try rig.history.add("second");
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    const e = &rig.editor;

    try rig.type_("draft");
    _ = try rig.key(.{ .code = .up });
    try testing.expectEqualStrings("second", e.text());
    _ = try rig.key(.{ .code = .up });
    try testing.expectEqualStrings("first", e.text());
    try testing.expectEqual(Reaction.bell, try rig.key(.{ .code = .up }));
    _ = try rig.key(.{ .code = .down });
    try testing.expectEqualStrings("second", e.text());
    _ = try rig.key(.{ .code = .down });
    try testing.expectEqualStrings("draft", e.text());
}

test "multiline: up/down move within lines before history" {
    var rig = TestRig.init();
    try rig.history.add("old");
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    const e = &rig.editor;

    try rig.type_("abc");
    _ = try rig.key(keys.Key.ctrlKey('o')); // newline without submit
    try rig.type_("de");
    try testing.expectEqualStrings("abc\nde", e.text());
    // Cursor on line 2; Up moves to line 1 same column, not history.
    _ = try rig.key(.{ .code = .up });
    try testing.expectEqualStrings("abc\nde", e.text());
    try testing.expectEqual(@as(usize, 2), e.cursor);
    // Up again from line 1 → history.
    _ = try rig.key(.{ .code = .up });
    try testing.expectEqualStrings("old", e.text());
}

test "smart-enter continues incomplete input, submits complete" {
    var rig = TestRig.init();
    rig.start(Completer.none(), .{ .ctx = undefined, .isCompleteFn = incompleteIfOpenBrace });
    defer rig.deinit();
    const e = &rig.editor;

    try rig.type_("{ a = 1;");
    try testing.expectEqual(Reaction.none, try rig.key(.{ .code = .enter }));
    try testing.expectEqualStrings("{ a = 1;\n", e.text());
    try rig.type_("}");
    try testing.expectEqual(Reaction.submit, try rig.key(.{ .code = .enter }));
}

test "alt-enter forces submission of incomplete input" {
    var rig = TestRig.init();
    rig.start(Completer.none(), .{ .ctx = undefined, .isCompleteFn = incompleteIfOpenBrace });
    defer rig.deinit();
    try rig.type_("{ a");
    try testing.expectEqual(Reaction.submit, try rig.key(.{ .code = .enter, .alt = true }));
}

test "enter mid-multiline opens a line instead of submitting" {
    var rig = TestRig.init();
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    const e = &rig.editor;
    try rig.type_("a");
    _ = try rig.key(keys.Key.ctrlKey('o'));
    try rig.type_("b");
    _ = try rig.key(.{ .code = .home });
    try testing.expectEqual(Reaction.none, try rig.key(.{ .code = .enter }));
    try testing.expectEqualStrings("a\n\nb", e.text());
}

test "pasted keys insert literally and never submit" {
    var rig = TestRig.init();
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    const e = &rig.editor;
    try testing.expectEqual(Reaction.none, try rig.key(.{ .code = .{ .cp = 'x' }, .pasted = true }));
    try testing.expectEqual(Reaction.none, try rig.key(.{ .code = .enter, .pasted = true }));
    try testing.expectEqual(Reaction.none, try rig.key(.{ .code = .tab, .pasted = true }));
    try testing.expectEqualStrings("x\n\t", e.text());
}

test "ctrl-c cancels, ctrl-d eof on empty only" {
    var rig = TestRig.init();
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    try rig.type_("junk");
    try testing.expectEqual(Reaction.cancel, try rig.key(keys.Key.ctrlKey('c')));
    try testing.expectEqual(Reaction.none, try rig.key(keys.Key.ctrlKey('d'))); // deletes nothing at end
    rig.editor.reset();
    try testing.expectEqual(Reaction.eof, try rig.key(keys.Key.ctrlKey('d')));
}

const FakeCompleter = struct {
    items: []const []const u8,

    fn complete(ctx: *anyopaque, arena: std.mem.Allocator, t: []const u8, cursor: usize) anyerror!Completer.Result {
        const self: *FakeCompleter = @ptrCast(@alignCast(ctx));
        // Complete the trailing ident-ish token.
        var start = cursor;
        while (start > 0 and Editor.isWordCp(t[start - 1])) start -= 1;
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.items) |item| {
            if (std.mem.startsWith(u8, item, t[start..cursor]))
                try out.append(arena, try arena.dupe(u8, item));
        }
        return .{ .start = start, .end = cursor, .items = out.items };
    }

    fn completer(self: *FakeCompleter) Completer {
        return .{ .ctx = self, .completeFn = complete };
    }
};

test "tab completion extends, lists, and cycles in both directions" {
    var fake = FakeCompleter{ .items = &.{ "builtins", "buildEnv", "buildFHSEnv" } };
    var rig = TestRig.init();
    rig.start(fake.completer(), CompleteCheck.always());
    defer rig.deinit();
    const e = &rig.editor;

    // "bui" → common prefix "buil" (no unique match).
    try rig.type_("bui");
    _ = try rig.key(.{ .code = .tab });
    try testing.expectEqualStrings("buil", e.text());
    try testing.expectEqual(@as(usize, 0), e.menuLines().len);

    // Second tab with no further progress → menu.
    _ = try rig.key(.{ .code = .tab });
    try testing.expectEqual(@as(usize, 3), e.menuLines().len);

    // Further tabs replace the span and wrap through the candidates.
    _ = try rig.key(.{ .code = .tab });
    try testing.expectEqualStrings("builtins", e.text());
    _ = try rig.key(.{ .code = .tab });
    try testing.expectEqualStrings("buildEnv", e.text());
    _ = try rig.key(.{ .code = .backtab });
    try testing.expectEqualStrings("builtins", e.text());

    // Ordinary editing dismisses the menu.
    _ = try rig.key(.{ .code = .end });
    try rig.type_(".");
    try testing.expectEqual(@as(usize, 0), e.menuLines().len);
}

test "reverse search finds, refines, and aborts" {
    var rig = TestRig.init();
    try rig.history.add("builtins.map f xs");
    try rig.history.add("1 + 2");
    try rig.history.add("map g ys");
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    const e = &rig.editor;

    _ = try rig.key(keys.Key.ctrlKey('r'));
    try testing.expect(e.search != null);
    try rig.type_("map");
    try testing.expectEqualStrings("map g ys", e.text());
    // Older match.
    _ = try rig.key(keys.Key.ctrlKey('r'));
    try testing.expectEqualStrings("builtins.map f xs", e.text());
    // C-g restores the original (empty) line.
    _ = try rig.key(keys.Key.ctrlKey('g'));
    try testing.expect(e.search == null);
    try testing.expectEqualStrings("", e.text());
}

test "search accept via escape keeps match editable" {
    var rig = TestRig.init();
    try rig.history.add("let x = 1; in x");
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    const e = &rig.editor;
    _ = try rig.key(keys.Key.ctrlKey('r'));
    try rig.type_("let");
    _ = try rig.key(.{ .code = .escape });
    try testing.expect(e.search == null);
    try testing.expectEqualStrings("let x = 1; in x", e.text());
}

test "transpose swaps around point" {
    var rig = TestRig.init();
    rig.start(Completer.none(), CompleteCheck.always());
    defer rig.deinit();
    try rig.type_("ab");
    _ = try rig.key(keys.Key.ctrlKey('t'));
    try testing.expectEqualStrings("ba", rig.editor.text());
}
