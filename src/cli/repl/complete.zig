//! Tab completion for the repl.
//!
//! Sources, chosen by the context at the cursor:
//! - `:` commands (from `commands.zig`) — the discoverability surface;
//! - attribute paths (`foo.ba<TAB>`): resolved through the repl bindings /
//!   `builtins` by walking ALREADY-FORCED values only — a resolved thunk is
//!   looked through, an unforced one ends the walk (never start evaluation
//!   from the completer);
//! - bare identifiers: repl bindings, keywords, `builtins`, and the ambient
//!   (globally visible) builtin names;
//! - file paths inside string or path literals.
//!
//! All results are allocated in the arena the editor hands us.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const editor_mod = @import("editor.zig");
const commands = @import("commands.zig");

const Engine = engine.Engine;
const Value = runtime.Value;
const builtins_mod = runtime.builtins;
const future_mod = runtime.future;

pub const Ctx = struct {
    ev: *Engine,
    io: std.Io,
    bindings: *const std.StringArrayHashMapUnmanaged(Value),
};

pub fn completer(ctx: *Ctx) editor_mod.Completer {
    return .{ .ctx = ctx, .completeFn = complete };
}

const keywords = [_][]const u8{
    "let",      "in",   "if",    "then", "else",   "with",  "rec",        "inherit", "assert",
    "builtins", "true", "false", "null", "import", "throw", "derivation",
};

fn complete(ctx_ptr: *anyopaque, arena: std.mem.Allocator, text: []const u8, cursor: usize) anyerror!editor_mod.Completer.Result {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    const empty: editor_mod.Completer.Result = .{ .start = cursor, .end = cursor, .items = &.{} };

    // Current logical line (completion never spans a newline).
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..cursor], '\n')) |nl| nl + 1 else 0;
    const line = text[line_start..cursor];

    // `:command` — complete the command word itself.
    if (line.len > 0 and line[0] == ':' and std.mem.indexOfAny(u8, line, " \t") == null) {
        var items: std.ArrayListUnmanaged([]const u8) = .empty;
        for (&commands.table) |*cmd| {
            for (cmd.names) |name| {
                if (std.mem.startsWith(u8, name, line)) {
                    try items.append(arena, try arena.dupe(u8, name));
                }
            }
        }
        sortItems(items.items);
        return .{ .start = line_start, .end = cursor, .items = items.items };
    }

    // Inside a string or path literal → file path completion.
    if (stringOrPathStart(line)) |tok_start| {
        return completePath(ctx, arena, text, line_start + tok_start, cursor);
    }

    // Identifier / attribute path ending at the cursor.
    const tok_start = identPathStart(line);
    const token = line[tok_start..];
    const abs_start = line_start + tok_start;

    if (std.mem.lastIndexOfScalar(u8, token, '.')) |last_dot| {
        // Attribute path: resolve everything before the final dot.
        const base_path = token[0..last_dot];
        const partial = token[last_dot + 1 ..];
        const base = resolveForcedPath(ctx, base_path) orelse return empty;
        if (!base.isAttrs()) return empty;
        var items: std.ArrayListUnmanaged([]const u8) = .empty;
        const tooling = ctx.ev.tooling();
        const entries = tooling.attrs(base) catch return empty;
        for (entries.names) |entry_name| {
            const name = tooling.internText(entry_name);
            if (std.mem.startsWith(u8, name, partial)) {
                try items.append(arena, try arena.dupe(u8, name));
            }
        }
        sortItems(items.items);
        return .{ .start = abs_start + last_dot + 1, .end = cursor, .items = items.items };
    }

    if (token.len == 0) return empty;

    // Bare identifier: bindings + keywords + ambient builtins.
    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;

    var bit = ctx.bindings.iterator();
    while (bit.next()) |e| {
        if (std.mem.startsWith(u8, e.key_ptr.*, token)) {
            const gop = try seen.getOrPut(arena, e.key_ptr.*);
            if (!gop.found_existing) try items.append(arena, try arena.dupe(u8, e.key_ptr.*));
        }
    }
    for (keywords) |kw| {
        if (std.mem.startsWith(u8, kw, token)) {
            const gop = try seen.getOrPut(arena, kw);
            if (!gop.found_existing) try items.append(arena, try arena.dupe(u8, kw));
        }
    }
    // Ambient builtins: names visible without the `builtins.` prefix.
    if (builtinsAttrs(ctx)) |entries| {
        for (entries.names) |entry_name| {
            const name = ctx.ev.tooling().internText(entry_name);
            if (!std.mem.startsWith(u8, name, token)) continue;
            if (builtins_mod.ambientIdForName(name) == null) continue;
            const gop = try seen.getOrPut(arena, name);
            if (!gop.found_existing) try items.append(arena, try arena.dupe(u8, name));
        }
    }
    sortItems(items.items);
    return .{ .start = abs_start, .end = cursor, .items = items.items };
}

fn sortItems(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

/// The builtins attrset's entries (always fully built, never thunked).
/// `builtinsValue` constructs it on first use, so completion works before
/// the session's first evaluation.
fn builtinsAttrs(ctx: *Ctx) ?runtime.heap.AttrsView {
    const b = ctx.ev.builtinsValue() catch return null;
    if (!b.isAttrs()) return null;
    return ctx.ev.tooling().attrs(b) catch null;
}

/// Resolve a dotted attr path against the repl scope WITHOUT forcing:
/// bindings and `builtins` at the root, then already-resolved values only.
/// Returns null the moment evaluation would be needed.
fn resolveForcedPath(ctx: *Ctx, path: []const u8) ?Value {
    var it = std.mem.splitScalar(u8, path, '.');
    const first = it.next() orelse return null;

    var current: Value = blk: {
        if (std.mem.eql(u8, first, "builtins")) {
            break :blk ctx.ev.builtinsValue() catch return null;
        }
        if (ctx.bindings.get(first)) |v| break :blk v;
        return null;
    };
    current = lookThroughResolved(ctx, current) orelse return null;

    while (it.next()) |segment| {
        if (!current.isAttrs()) return null;
        const tooling = ctx.ev.tooling();
        const name_id = tooling.intern(segment) catch return null;
        const attr = tooling.attrValueOpt(current, name_id) catch return null;
        current = lookThroughResolved(ctx, attr orelse return null) orelse return null;
    }
    return current;
}

/// A resolved thunk yields its result; an unforced one yields null
/// (the completer never forces).
fn lookThroughResolved(ctx: *Ctx, value: Value) ?Value {
    var current = value;
    var hops: usize = 0;
    while (current.kind() == .thunk and hops < 16) : (hops += 1) {
        const thunk = ctx.ev.tooling().thunk(current) catch return null;
        const state: future_mod.FutureState = thunk.future.stateField(.acquire);
        if (state != .resolved) return null;
        current = thunk.payload.result;
    }
    return current;
}

// -- file path completion -----------------------------------------------------

/// If the cursor sits inside a string literal or a path literal, the byte
/// offset (within `line`) where the path text starts.
fn stringOrPathStart(line: []const u8) ?usize {
    // Inside a double-quoted string? Count unescaped quotes.
    var in_string = false;
    var string_content_start: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and in_string) {
            i += 1;
            continue;
        }
        if (line[i] == '"') {
            in_string = !in_string;
            if (in_string) string_content_start = i + 1;
        }
    }
    if (in_string) {
        // Complete only string content that looks path-like.
        const content = line[string_content_start..];
        if (content.len > 0 and (content[0] == '/' or content[0] == '.' or content[0] == '~'))
            return string_content_start;
        return null;
    }

    // A path literal token: scan back over path chars, require a '/'.
    var start = line.len;
    while (start > 0) {
        const c = line[start - 1];
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '.' or c == '_' or
            c == '-' or c == '+' or c == '~')
        {
            start -= 1;
        } else break;
    }
    const token = line[start..];
    if (std.mem.indexOfScalar(u8, token, '/') == null) return null;
    if (token.len == 0) return null;
    if (!(token[0] == '/' or token[0] == '.' or token[0] == '~')) return null;
    return start;
}

fn completePath(ctx: *Ctx, arena: std.mem.Allocator, text: []const u8, tok_start: usize, cursor: usize) !editor_mod.Completer.Result {
    const token = text[tok_start..cursor];
    const empty: editor_mod.Completer.Result = .{ .start = cursor, .end = cursor, .items = &.{} };

    const slash = std.mem.lastIndexOfScalar(u8, token, '/') orelse return empty;
    const dir_part = token[0 .. slash + 1];
    const partial = token[slash + 1 ..];

    var dir = std.Io.Dir.cwd().openDir(ctx.io, if (dir_part.len > 1 and dir_part[0] != '/')
        dir_part[0 .. dir_part.len - 1]
    else if (std.mem.eql(u8, dir_part, "/"))
        "/"
    else
        dir_part[0 .. dir_part.len - 1], .{ .iterate = true }) catch return empty;
    defer dir.close(ctx.io);

    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, partial)) continue;
        if (partial.len == 0 and entry.name[0] == '.') continue; // hide dotfiles
        const suffix: []const u8 = if (entry.kind == .directory) "/" else "";
        try items.append(arena, try std.mem.concat(arena, u8, &.{ entry.name, suffix }));
        if (items.items.len >= 500) break;
    }
    sortItems(items.items);
    return .{ .start = tok_start + slash + 1, .end = cursor, .items = items.items };
}

/// Byte offset (within `line`) where the trailing identifier/attr-path
/// token starts.
fn identPathStart(line: []const u8) usize {
    var start = line.len;
    while (start > 0) {
        const c = line[start - 1];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '\'' or c == '-' or c == '.') {
            start -= 1;
        } else break;
    }
    return start;
}

const testing = std.testing;

test "identPathStart finds the trailing token" {
    try testing.expectEqual(@as(usize, 4), identPathStart("1 + foo.ba"));
    try testing.expectEqual(@as(usize, 0), identPathStart("builtins.ma"));
    try testing.expectEqual(@as(usize, 6), identPathStart("(map (x"));
}

test "stringOrPathStart detects strings and path literals" {
    try testing.expectEqual(@as(?usize, 1), stringOrPathStart("\"./fo"));
    try testing.expectEqual(@as(?usize, 7), stringOrPathStart("import ./src/ma"));
    try testing.expectEqual(@as(?usize, null), stringOrPathStart("1 + foo"));
    try testing.expectEqual(@as(?usize, null), stringOrPathStart("\"hello wo"));
    // A closed string puts us back outside.
    try testing.expectEqual(@as(?usize, null), stringOrPathStart("\"./x\" + foo"));
}
