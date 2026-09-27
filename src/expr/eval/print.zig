//! Nix value rendering for Engine.writeValue.

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const ObjectHeap = @import("runtime").heap.ObjectHeap;
const InternTable = @import("runtime").intern.InternTable;
const FutureState = @import("runtime").future.FutureState;
const numeric = @import("runtime").numeric;

// Value-coloring palette (SGR), applied when `ev.value_color` is set. Chosen to
// match the CLI's own styles (green paths, yellow hashes/numbers, magenta
// keywords, cyan labels) — see `src/cli/presentation.zig`.
const col_string = "\x1b[32m"; // strings, paths — green
const col_number = "\x1b[33m"; // ints, floats — yellow
const col_keyword = "\x1b[35m"; // true/false/null — magenta
const col_name = "\x1b[36m"; // attribute names — cyan
const col_reset = "\x1b[0m";

pub const Host = struct {
    allocator: std.mem.Allocator,
    heap: *ObjectHeap,
    intern: *InternTable,
    value_color: bool,
    context: *anyopaque,
    force_value: *const fn (*anyopaque, Value) anyerror!Value,

    fn forceValue(self: Host, value: Value) !Value {
        return self.force_value(self.context, value);
    }
};

pub fn writeValue(host: Host, writer: *std.Io.Writer, value: Value) !void {
    var printer: ValuePrinter = .{
        .host = host,
        .writer = writer,
        .seen = .empty,
        .use_color = host.value_color,
    };
    defer printer.seen.deinit(host.allocator);

    try printer.write(value);
}

fn writeQuotedString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            // Nix escapes a `$` that begins an interpolation (`${`) as `\${` so
            // the printed form re-parses to the same string.
            '$' => {
                if (i + 1 < s.len and s[i + 1] == '{') try writer.writeByte('\\');
                try writer.writeByte('$');
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// Render a float the way Nix/Lix does: C++ `ostream` default formatting,
/// i.e. printf `%g` with the default precision of 6 significant digits.
/// `18446744073709551616.0` → `1.84467e+19`, `3.1415` → `3.1415`, `1.0` → `1`.
fn writeNixFloat(writer: *std.Io.Writer, v: f64) !void {
    var buf: [numeric.g_max_len]u8 = undefined;
    try writer.writeAll(numeric.formatG(&buf, v, 6));
}

const ValuePrinter = struct {
    const Self = @This();

    host: Host,
    writer: *std.Io.Writer,
    use_color: bool,
    /// Objects already visited in THIS print. A shared or recursive
    /// reference reached a second time (by any path, not just an
    /// ancestor) renders as «repeated», matching Nix's identity-based
    /// printer — it is never pruned mid-print. Keyed by (id, kind); the
    /// id is a heap slot, so this is identity, not structural, equality.
    seen: std.AutoHashMapUnmanaged(u64, void),
    /// Recursion depth, so top-level (`depth == 0`) list/attrs walks can
    /// report `[i/N]` item progress on the render node without every nested
    /// container fighting over the same counter.
    depth: u32 = 0,

    const SeenKind = enum(u2) { list, attrs, thunk };

    /// Emit an SGR code (or nothing when color is off).
    fn on(self: *Self, code: []const u8) !void {
        if (self.use_color) try self.writer.writeAll(code);
    }
    fn off(self: *Self) !void {
        if (self.use_color) try self.writer.writeAll(col_reset);
    }
    /// Write `text` wrapped in `code`…reset.
    fn leaf(self: *Self, code: []const u8, text: []const u8) !void {
        try self.on(code);
        try self.writer.writeAll(text);
        try self.off();
    }
    fn quotedString(self: *Self, s: []const u8) !void {
        try self.on(col_string);
        try writeQuotedString(self.writer, s);
        try self.off();
    }

    fn write(self: *Self, value: Value) anyerror!void {
        switch (value.kind()) {
            .null => try self.leaf(col_keyword, "null"),
            .bool_false => try self.leaf(col_keyword, "false"),
            .bool_true => try self.leaf(col_keyword, "true"),
            .int => {
                try self.on(col_number);
                try self.writer.print("{}", .{value.asInt()});
                try self.off();
            },
            .boxed_int => {
                try self.on(col_number);
                try self.writer.print("{}", .{try self.host.heap.getBoxedInt(value.asObjectId())});
                try self.off();
            },
            .float => {
                try self.on(col_number);
                try writeNixFloat(self.writer, value.asFloat());
                try self.off();
            },
            .string => try self.quotedString(self.host.intern.get(value.asInternId())),
            .path => try self.leaf(col_string, self.host.intern.get(value.asInternId())),
            .string_context => {
                const string = try self.host.heap.getContextString(value.asObjectId());
                try self.quotedString(self.host.intern.get(string.text));
            },
            .heap_string => try self.quotedString(try self.host.heap.getHeapString(value.asObjectId())),
            .list => try self.writeList(value.asObjectId()),
            .attrs => try self.writeAttrs(value.asObjectId()),
            // Marker strings match Nix's value printer: a user lambda is
            // <LAMBDA>, a builtin is <PRIMOP>, a partially-applied builtin
            // is <PRIMOP-APP>.
            .closure => try self.writer.writeAll("<LAMBDA>"),
            .thunk => try self.writeThunk(value.asObjectId()),
            .builtin => try self.writer.writeAll("<PRIMOP>"),
            .builtin_closure => try self.writer.writeAll("<PRIMOP-APP>"),
            .partial_app => try self.writer.writeAll("<PRIMOP-APP>"),
        }
    }

    fn writeList(self: *Self, id: types.ObjectId) !void {
        const items = try self.host.heap.getList(id);
        // Nix only records NON-empty containers for identity («repeated»)
        // tracking — an empty list/attrs is always rendered in full. Check
        // emptiness before `enter` so a shared empty `[ ]` (e.g. an
        // `inherit`ed leaf) doesn't spuriously print as «repeated».
        if (items.len == 0) {
            try self.writer.writeAll("[ ]");
            return;
        }
        if (!try self.enter(.list, id)) {
            try self.writer.writeAll("«repeated»");
            return;
        }

        self.depth += 1;
        defer self.depth -= 1;

        try self.writer.writeAll("[ ");
        for (items, 0..) |item, i| {
            if (i > 0) try self.writer.writeByte(' ');
            try self.write(item);
        }
        try self.writer.writeAll(" ]");
    }

    fn writeAttrs(self: *Self, id: types.ObjectId) !void {
        if (try self.derivationDrvPath(id)) |path| {
            try self.writer.writeAll(path);
            return;
        }

        const stored = try self.host.heap.materializeAttrs(id);
        // Empty attrs are never «repeated» (see writeList) — render `{ }`
        // before recording identity.
        if (stored.len() == 0) {
            try self.writer.writeAll("{ }");
            return;
        }
        if (!try self.enter(.attrs, id)) {
            try self.writer.writeAll("«repeated»");
            return;
        }

        // Nix prints attribute sets with their keys in lexicographic order,
        // regardless of definition order (fix's JSON/XML writers already do
        // this via attrsets.sortedAttrEntries). Sort a private copy here so
        // the plain value form matches — attr storage is symbol-id order,
        // which is first-seen order, not alphabetical.
        const Entry = @import("runtime").heap.AttrEntry;
        const entries = try self.host.allocator.alloc(Entry, stored.len());
        defer self.host.allocator.free(entries);
        for (entries, stored.names, stored.values) |*e, n, v| e.* = .{ .name = n, .value = v };
        try self.host.intern.sortByNameLex(self.host.allocator, Entry, entries);

        self.depth += 1;
        defer self.depth -= 1;

        try self.writer.writeAll("{ ");
        for (entries) |entry| {
            try self.writeAttrName(self.host.intern.get(entry.name));
            try self.writer.writeAll(" = ");
            try self.write(entry.value);
            try self.writer.writeAll("; ");
        }
        try self.writer.writeByte('}');
    }

    fn derivationDrvPath(self: *Self, id: types.ObjectId) !?[]const u8 {
        const type_id = try self.host.intern.intern("type");
        const type_value = self.host.heap.getAttrValue(id, type_id) catch |err| switch (err) {
            error.MissingAttribute => return null,
            else => return err,
        };
        const forced_type = try self.host.forceValue(type_value);
        if (!forced_type.isString()) return null;
        if (!std.mem.eql(u8, self.host.intern.get(forced_type.asInternId()), "derivation")) return null;

        const drv_path_id = try self.host.intern.intern("drvPath");
        const drv_path = self.host.heap.getAttrValue(id, drv_path_id) catch |err| switch (err) {
            error.MissingAttribute => return null,
            else => return err,
        };
        return try self.stringText(try self.host.forceValue(drv_path));
    }

    fn stringText(self: *Self, value: Value) ![]const u8 {
        return switch (value.kind()) {
            .string, .path => self.host.intern.get(value.asInternId()),
            .string_context => blk: {
                const string = try self.host.heap.getContextString(value.asObjectId());
                break :blk self.host.intern.get(string.text);
            },
            else => error.TypeError,
        };
    }

    fn writeThunk(self: *Self, id: types.ObjectId) !void {
        if (!try self.enter(.thunk, id)) {
            try self.writer.writeAll("«repeated»");
            return;
        }

        const thunk = try self.host.heap.getThunk(id);
        const state: FutureState = thunk.future.stateField(.acquire);
        if (state == .resolved) {
            try self.write(thunk.payload.result);
            return;
        }
        // Pass-through thunks expose their wrapped value even before forcing.
        if (thunk.targetKind() == .pass_through) {
            try self.write(thunk.payload.target.pass_through);
        } else {
            // An unforced thunk renders as <CODE>, matching Nix's printer.
            try self.writer.writeAll("<CODE>");
        }
    }

    fn writeAttrName(self: *Self, name: []const u8) !void {
        try self.on(col_name);
        if (isBareAttrName(name)) {
            try self.writer.writeAll(name);
        } else {
            try writeQuotedString(self.writer, name);
        }
        try self.off();
    }

    fn enter(self: *Self, kind: SeenKind, id: types.ObjectId) !bool {
        const key = (@as(u64, id) << 2) | @intFromEnum(kind);
        const gop = try self.seen.getOrPut(self.host.allocator, key);
        return !gop.found_existing;
    }

    fn isBareAttrName(name: []const u8) bool {
        if (name.len == 0) return false;
        if (!isAttrNameStart(name[0])) return false;
        for (name[1..]) |c| {
            if (!isAttrNameContinue(c)) return false;
        }
        return true;
    }

    fn isAttrNameStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isAttrNameContinue(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '\'';
    }
};
