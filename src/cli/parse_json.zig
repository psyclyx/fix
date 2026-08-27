//! AST → JSON serializer matching Lix's `nix-instantiate --parse` schema.
//!
//! fix keeps a lean, raw AST (operators un-desugared, attr paths un-merged,
//! curried applies nested). Nix's `--parse` JSON is the *lowered* tree: `+`
//! becomes `ExprConcatStrings`, `-`/`*`/`/`/`<`/`>` become primop calls,
//! static attr paths are nested and merged, curried applies are flattened, and
//! so on. This module performs those transforms in a depth-first stream. Each
//! node builds only its shallow JSON fields; a typed writer visits child nodes
//! when their field reaches the stream. Attribute sets retain only the
//! merge/sort index their compatibility schema requires, never a second
//! whole-result tree.
//!
//! Output format mirrors nlohmann's `dump(2)`: 2-space indent, object keys
//! sorted lexicographically with `_type` pinned first, empty collection fields
//! omitted. There are no source positions anywhere.
//!
//! Scope is parse-OKAY only: this assumes a well-formed tree from `Parser`.

const std = @import("std");
const syntax = @import("syntax");
const ast = syntax.ast;
const Node = ast.Node;
const string_syntax = syntax.string_syntax;
const parser_mod = syntax.parser;

/// A shallow JSON value. Recursive AST work stays typed and is performed by
/// `CompatibilityWriter` only when the containing value reaches the output.
const JsonValue = union(enum) {
    int: i64,
    float: f64,
    str: []const u8,
    boolean: bool,
    nul,
    array: []JsonValue,
    object: []Field,
    child: Child,

    const Field = struct { key: []const u8, val: JsonValue };
};

const Child = union(enum) {
    node: *const Node,
    interpolation: []const u8,
    set: *BindingSet,
    list: *const Node.List,
};

/// Serialize `node` (a parse-OKAY AST rooted in `source`) as JSON to `writer`.
/// `gpa` backs depth-reused scratch, decoded strings, and the sub-parsers used
/// for string interpolations.
pub fn write(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    source: []const u8,
    node: *const Node,
) !void {
    var compatibility: CompatibilityWriter = .{
        .writer = writer,
        .gpa = gpa,
        .source = source,
    };
    defer compatibility.deinit();
    try compatibility.writeNode(node);
}

const CompatibilityWriter = struct {
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    source: []const u8,
    /// One stable arena state per active traversal depth. Siblings reset and
    /// reuse their level instead of constructing an allocator for every node.
    scratch: std.ArrayListUnmanaged(*std.heap.ArenaAllocator) = .empty,

    fn deinit(self: *CompatibilityWriter) void {
        for (self.scratch.items) |arena| {
            arena.deinit();
            self.gpa.destroy(arena);
        }
        self.scratch.deinit(self.gpa);
    }

    fn writeNode(self: *CompatibilityWriter, node: *const Node) !void {
        try self.writeNodeIndented(self.source, node, 0, 0);
        try self.writer.writeByte('\n');
    }

    fn scratchAt(self: *CompatibilityWriter, depth: usize) !std.mem.Allocator {
        while (self.scratch.items.len <= depth) {
            const arena = try self.gpa.create(std.heap.ArenaAllocator);
            errdefer self.gpa.destroy(arena);
            arena.* = std.heap.ArenaAllocator.init(self.gpa);
            errdefer arena.deinit();
            try self.scratch.append(self.gpa, arena);
        }
        const arena = self.scratch.items[depth];
        _ = arena.reset(.retain_capacity);
        return arena.allocator();
    }

    fn writeNodeIndented(
        self: *CompatibilityWriter,
        source: []const u8,
        node: *const Node,
        indent: usize,
        depth: usize,
    ) anyerror!void {
        const arena = try self.scratchAt(depth);
        var lowerer: Lowerer = .{ .arena = arena, .gpa = self.gpa, .source = source };
        try self.writeValue(source, try lowerer.node(node), indent, depth);
    }

    fn writeSetIndented(
        self: *CompatibilityWriter,
        source: []const u8,
        set: *BindingSet,
        indent: usize,
        depth: usize,
    ) anyerror!void {
        const arena = try self.scratchAt(depth);
        var lowerer: Lowerer = .{ .arena = arena, .gpa = self.gpa, .source = source };
        try self.writeValue(source, try lowerer.emitSet(set, false, null), indent, depth);
    }

    fn writeInterpolation(
        self: *CompatibilityWriter,
        source: []const u8,
        indent: usize,
        depth: usize,
    ) anyerror!void {
        var ast_arena = ast.AstArena.init(self.gpa);
        defer ast_arena.deinit();
        var parser = parser_mod.Parser.init(self.gpa, &ast_arena, source);
        defer parser.deinit();
        const node = parser.parse() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InterpolationParseError,
        };
        try self.writeNodeIndented(source, node, indent, depth);
    }

    fn writeList(
        self: *CompatibilityWriter,
        source: []const u8,
        list: *const Node.List,
        indent: usize,
        depth: usize,
    ) anyerror!void {
        if (list.items.len == 0) return self.writer.writeAll("[]");
        try self.writer.writeAll("[\n");
        for (list.items, 0..) |item, i| {
            try self.writer.splatByteAll(' ', indent + 2);
            try self.writeNodeIndented(source, item, indent + 2, depth);
            if (i + 1 != list.items.len) try self.writer.writeByte(',');
            try self.writer.writeByte('\n');
        }
        try self.writer.splatByteAll(' ', indent);
        try self.writer.writeByte(']');
    }

    fn writeValue(
        self: *CompatibilityWriter,
        source: []const u8,
        value: JsonValue,
        indent: usize,
        depth: usize,
    ) anyerror!void {
        switch (value) {
            .int => |v| try self.writer.print("{d}", .{v}),
            .float => |v| try emitFloat(self.writer, v),
            .str => |s| try emitString(self.writer, s),
            .boolean => |b| try self.writer.writeAll(if (b) "true" else "false"),
            .nul => try self.writer.writeAll("null"),
            .array => |items| {
                if (items.len == 0) return self.writer.writeAll("[]");
                try self.writer.writeAll("[\n");
                for (items, 0..) |item, i| {
                    try self.writer.splatByteAll(' ', indent + 2);
                    try self.writeValue(source, item, indent + 2, depth);
                    if (i + 1 != items.len) try self.writer.writeByte(',');
                    try self.writer.writeByte('\n');
                }
                try self.writer.splatByteAll(' ', indent);
                try self.writer.writeByte(']');
            },
            .object => |fields| {
                if (fields.len == 0) return self.writer.writeAll("{}");
                std.mem.sort(JsonValue.Field, fields, {}, fieldLess);
                try self.writer.writeAll("{\n");
                for (fields, 0..) |field, i| {
                    try self.writer.splatByteAll(' ', indent + 2);
                    try emitString(self.writer, field.key);
                    try self.writer.writeAll(": ");
                    try self.writeValue(source, field.val, indent + 2, depth);
                    if (i + 1 != fields.len) try self.writer.writeByte(',');
                    try self.writer.writeByte('\n');
                }
                try self.writer.splatByteAll(' ', indent);
                try self.writer.writeByte('}');
            },
            .child => |child| switch (child) {
                .node => |node| try self.writeNodeIndented(source, node, indent, depth + 1),
                .interpolation => |sub| try self.writeInterpolation(sub, indent, depth + 1),
                .set => |set| try self.writeSetIndented(source, set, indent, depth + 1),
                .list => |list| try self.writeList(source, list, indent, depth + 1),
            },
        }
    }
};

fn fieldLess(_: void, a: JsonValue.Field, b: JsonValue.Field) bool {
    const a_type = std.mem.eql(u8, a.key, "_type");
    const b_type = std.mem.eql(u8, b.key, "_type");
    if (a_type != b_type) return a_type;
    return std.mem.lessThan(u8, a.key, b.key);
}

fn emitFloat(writer: *std.Io.Writer, value: f64) !void {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch {
        try writer.print("{d}", .{value});
        return;
    };
    try writer.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".eEnN") == null) try writer.writeAll(".0");
}

fn emitString(writer: *std.Io.Writer, string: []const u8) !void {
    try writer.writeByte('"');
    for (string) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            else => if (c < 0x20)
                try writer.print("\\u{x:0>4}", .{c})
            else
                try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

const Lowerer = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    source: []const u8,

    fn childNode(_: *const Lowerer, child: *const Node) JsonValue {
        return .{ .child = .{ .node = child } };
    }

    fn childInterpolation(_: *const Lowerer, source: []const u8) JsonValue {
        return .{ .child = .{ .interpolation = source } };
    }

    fn childSet(_: *const Lowerer, set: *BindingSet) JsonValue {
        return .{ .child = .{ .set = set } };
    }

    fn childList(_: *const Lowerer, items: *const Node.List) JsonValue {
        return .{ .child = .{ .list = items } };
    }

    // ---- dispatch ----

    fn node(self: *Lowerer, n_in: *const Node) anyerror!JsonValue {
        const n = ast.unwrapParens(n_in);
        return switch (n.tag) {
            .integer => try self.literal("Int", .{ .int = try self.parseInt(n.data.atom) }),
            .float_val => try self.literal("Float", .{ .float = try self.parseFloat(n.data.atom) }),
            .string => try self.stringNode(n.data.atom),
            .path => try self.literal("Path", .{ .str = self.atomText(n.data.atom) }),
            // URL literals are ordinary strings in Nix.
            .uri => try self.literal("String", .{ .str = self.atomText(n.data.atom) }),
            .search_path => try self.searchPath(n.data.atom),
            .identifier => try self.identifier(self.atomText(n.data.atom)),

            .unary_op => try self.unary(n.data.unary),
            .binary_op => try self.binary(n.data.binary),
            .apply => try self.call(n),

            .lambda => try self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprLambda" } },
                .{ .key = "arg", .val = .{ .str = self.atomText(.{ .offset = n.data.lambda.param_offset, .len = n.data.lambda.param_len }) } },
                .{ .key = "body", .val = self.childNode(n.data.lambda.body) },
            }),
            .lambda_attrs => try self.lambdaAttrs(n.data.lambda_attrs),

            .let_in => try self.letIn(n.data.let_in),
            .if_else => try self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprIf" } },
                .{ .key = "cond", .val = self.childNode(n.data.if_else.cond) },
                .{ .key = "then", .val = self.childNode(n.data.if_else.then_branch) },
                .{ .key = "else", .val = self.childNode(n.data.if_else.else_branch) },
            }),
            .assert => try self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprAssert" } },
                .{ .key = "cond", .val = self.childNode(n.data.assert.cond) },
                .{ .key = "body", .val = self.childNode(n.data.assert.body) },
            }),
            .with_expr => try self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprWith" } },
                .{ .key = "attrs", .val = self.childNode(n.data.with_expr.attr_set) },
                .{ .key = "body", .val = self.childNode(n.data.with_expr.body) },
            }),

            .attr_set => try self.attrSet(n),
            .attr_path, .attr_dynamic => try self.select(n, null),
            .attr_or => try self.select(n.data.attr_or.attr_path, n.data.attr_or.default),
            .has_attr => try self.hasAttr(n),
            .has_attr_mixed => try self.hasAttrMixed(n),
            .list => try self.list(&n.data.list),

            .parens => unreachable, // unwrapped above
            .elided => return error.ElidedBody, // elision is left off; never reached
        };
    }

    // ---- atoms ----

    fn atomText(self: *Lowerer, atom: Node.Atom) []const u8 {
        return self.source[atom.offset .. atom.offset + atom.len];
    }

    fn parseInt(self: *Lowerer, atom: Node.Atom) !i64 {
        return std.fmt.parseInt(i64, self.atomText(atom), 10) catch error.InvalidInteger;
    }

    fn parseFloat(self: *Lowerer, atom: Node.Atom) !f64 {
        return std.fmt.parseFloat(f64, self.atomText(atom)) catch error.InvalidFloat;
    }

    fn literal(self: *Lowerer, value_type: []const u8, value: JsonValue) !JsonValue {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprLiteral" } },
            .{ .key = "value", .val = value },
            .{ .key = "valueType", .val = .{ .str = value_type } },
        });
    }

    /// A string or name value: a JSON string when valid UTF-8, else a JSON
    /// array of byte values (`[97, 255, 98]`) — matching how Nix's parse JSON
    /// represents an invalid-UTF-8 string/name.
    fn strOrBytes(self: *Lowerer, bytes: []const u8) !JsonValue {
        if (std.unicode.utf8ValidateSlice(bytes)) return .{ .str = bytes };
        const out = try self.arena.alloc(JsonValue, bytes.len);
        for (bytes, out) |b, *j| j.* = .{ .int = b };
        return .{ .array = out };
    }

    fn exprVar(self: *Lowerer, name: []const u8) !JsonValue {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprVar" } },
            .{ .key = "value", .val = try self.strOrBytes(name) },
        });
    }

    fn identifier(self: *Lowerer, name: []const u8) !JsonValue {
        // The magic `__curPos` identifier is Nix's `ExprPos`.
        if (std.mem.eql(u8, name, "__curPos")) {
            return self.obj(&.{.{ .key = "_type", .val = .{ .str = "ExprPos" } }});
        }
        return self.exprVar(name);
    }

    fn searchPath(self: *Lowerer, atom: Node.Atom) !JsonValue {
        // `<x>` → __findFile __nixPath "x"
        const text = self.atomText(atom);
        const inner = if (text.len >= 2 and text[0] == '<' and text[text.len - 1] == '>')
            text[1 .. text.len - 1]
        else
            text;
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprCall" } },
            .{ .key = "fun", .val = try self.exprVar("__findFile") },
            .{ .key = "args", .val = try self.arr(&.{
                try self.exprVar("__nixPath"),
                try self.literal("String", .{ .str = inner }),
            }) },
        });
    }

    // ---- strings ----

    /// A string atom. A single constant text run is an `ExprLiteral String`;
    /// any `${...}` makes it an interpolating `ExprConcatStrings`.
    fn stringNode(self: *Lowerer, atom: Node.Atom) !JsonValue {
        const parsed = string_syntax.parseLiteral(self.gpa, self.source, .{
            .start = atom.offset,
            .end = atom.offset + atom.len,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidStringLiteral,
        };
        defer parsed.deinit();

        var has_interp = false;
        for (parsed.parts) |part| {
            if (part == .interpolation) has_interp = true;
        }

        if (!has_interp) {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            for (parsed.parts) |part| {
                switch (part) {
                    .text => |t| try buf.appendSlice(self.arena, t.slice()),
                    .interpolation => {},
                }
            }
            // Nix strings are NUL-terminated, so a `\0` truncates the value (the
            // `nul-bytes` feature only decides whether that is also an error).
            const bytes = buf.items;
            const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
            return try self.literal("String", try self.strOrBytes(bytes[0..end]));
        }

        // An indented string (`''...''`) whose only content is a single
        // constant-string interpolation (`''${"y"}''`) folds to that literal,
        // as Nix does. Regular strings and empty interpolations do not fold.
        const text = self.atomText(atom);
        const indented = text.len >= 2 and text[0] == '\'' and text[1] == '\'';
        if (indented) {
            if (singleInterpolationSpan(parsed.parts)) |span| {
                if (try self.constInterpolation(span)) |bytes| {
                    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
                    return try self.literal("String", try self.strOrBytes(bytes[0..end]));
                }
            }
        }

        var es: std.ArrayListUnmanaged(JsonValue) = .empty;
        for (parsed.parts) |part| {
            switch (part) {
                .text => |t| {
                    if (t.slice().len == 0) continue; // drop empty text chunks
                    try es.append(self.arena, try self.literal("String", try self.strOrBytes(try self.arena.dupe(u8, t.slice()))));
                },
                .interpolation => |span| try es.append(self.arena, try self.interpolation(span)),
            }
        }
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprConcatStrings" } },
            .{ .key = "es", .val = try self.arr(try es.toOwnedSlice(self.arena)) },
            .{ .key = "isInterpolation", .val = .{ .boolean = true } },
        });
    }

    /// The span of the sole interpolation part when a string's only non-empty
    /// content is one `${...}` (all other parts empty text); else null.
    fn singleInterpolationSpan(parts: []const string_syntax.Part) ?string_syntax.Span {
        var span: ?string_syntax.Span = null;
        for (parts) |part| switch (part) {
            .text => |t| if (t.slice().len != 0) return null,
            .interpolation => |s| {
                if (span != null) return null; // more than one interpolation
                span = s;
            },
        };
        return span;
    }

    /// If `${...}` interpolates a single constant string literal, its decoded
    /// bytes (arena-owned); else null.
    fn constInterpolation(self: *Lowerer, span: string_syntax.Span) !?[]const u8 {
        const sub = self.source[span.start..span.end];
        var arena = ast.AstArena.init(self.gpa);
        defer arena.deinit();
        var parser = parser_mod.Parser.init(self.gpa, &arena, sub);
        defer parser.deinit();
        const n = ast.unwrapParens(parser.parse() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        });
        if (n.tag != .string) return null;
        const lit = string_syntax.parseLiteral(self.gpa, sub, .{
            .start = n.data.atom.offset,
            .end = n.data.atom.offset + n.data.atom.len,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer lit.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (lit.parts) |p| switch (p) {
            .text => |t| try buf.appendSlice(self.arena, t.slice()),
            .interpolation => return null, // not a constant string
        };
        return buf.items;
    }

    /// Defer one `${...}` interpolation. It is a standalone expression over
    /// its source slice, so the writer parses and renders it only when reached.
    fn interpolation(self: *Lowerer, span: string_syntax.Span) !JsonValue {
        const sub = self.source[span.start..span.end];
        return self.childInterpolation(sub);
    }

    // ---- operators ----

    fn unary(self: *Lowerer, u: Node.Unary) !JsonValue {
        return switch (u.op) {
            .not => try self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprOpNot" } },
                .{ .key = "e", .val = self.childNode(u.expr) },
            }),
            // -x  →  __sub 0 x
            .negate => try self.primopCall("__sub", &.{
                try self.literal("Int", .{ .int = 0 }),
                self.childNode(u.expr),
            }),
        };
    }

    fn binary(self: *Lowerer, b: Node.Binary) !JsonValue {
        const l = self.childNode(b.left);
        const r = self.childNode(b.right);
        return switch (b.op) {
            // `+` is string/path/int concat → ExprConcatStrings
            .add => try self.concatStrings(&.{ l, r }, false),
            .sub => try self.primopCall("__sub", &.{ l, r }),
            .mul => try self.primopCall("__mul", &.{ l, r }),
            .div => try self.primopCall("__div", &.{ l, r }),
            .lt => try self.primopCall("__lessThan", &.{ l, r }),
            .gt => try self.primopCall("__lessThan", &.{ r, l }), // a > b → __lessThan b a
            .lte => try self.opNot(try self.primopCall("__lessThan", &.{ r, l })), // a <= b → !(b < a)
            .gte => try self.opNot(try self.primopCall("__lessThan", &.{ l, r })), // a >= b → !(a < b)
            .eq => try self.binOp("ExprOpEq", l, r),
            .neq => try self.binOp("ExprOpNEq", l, r),
            .and_ => try self.binOp("ExprOpAnd", l, r),
            .or_ => try self.binOp("ExprOpOr", l, r),
            .impl => try self.binOp("ExprOpImpl", l, r),
            .update => try self.binOp("ExprOpUpdate", l, r),
            .concat => try self.binOp("ExprOpConcatLists", l, r), // `++`
        };
    }

    fn binOp(self: *Lowerer, type_name: []const u8, e1: JsonValue, e2: JsonValue) !JsonValue {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = type_name } },
            .{ .key = "e1", .val = e1 },
            .{ .key = "e2", .val = e2 },
        });
    }

    fn opNot(self: *Lowerer, e: JsonValue) !JsonValue {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprOpNot" } },
            .{ .key = "e", .val = e },
        });
    }

    fn primopCall(self: *Lowerer, name: []const u8, args: []const JsonValue) !JsonValue {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprCall" } },
            .{ .key = "fun", .val = try self.exprVar(name) },
            .{ .key = "args", .val = try self.arr(args) },
        });
    }

    fn concatStrings(self: *Lowerer, es: []const JsonValue, is_interp: bool) !JsonValue {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprConcatStrings" } },
            .{ .key = "es", .val = try self.arr(es) },
            .{ .key = "isInterpolation", .val = .{ .boolean = is_interp } },
        });
    }

    // ---- application (curried-apply flattening) ----

    fn call(self: *Lowerer, n: *const Node) !JsonValue {
        const app = n.data.apply;
        // A pipe application is a single call `func arg`; the spine is not
        // flattened across it.
        if (app.pipe != .none) {
            return self.obj(&.{
                .{ .key = "_type", .val = .{ .str = "ExprCall" } },
                .{ .key = "fun", .val = self.childNode(app.func) },
                .{ .key = "args", .val = try self.arr(&.{self.childNode(app.arg)}) },
            });
        }
        // Flatten the left spine of plain applies: apply(apply(f,a),b) → f [a,b].
        var args_rev: std.ArrayListUnmanaged(*Node) = .empty;
        var cur = n;
        while (cur.tag == .apply and cur.data.apply.pipe == .none) {
            try args_rev.append(self.arena, cur.data.apply.arg);
            cur = ast.unwrapParens(cur.data.apply.func);
        }
        const args = try self.arena.alloc(JsonValue, args_rev.items.len);
        // args_rev holds outermost-arg-first; reverse into source order.
        for (args_rev.items, 0..) |arg_node, i| {
            args[args_rev.items.len - 1 - i] = self.childNode(arg_node);
        }
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprCall" } },
            .{ .key = "fun", .val = self.childNode(cur) },
            .{ .key = "args", .val = .{ .array = args } },
        });
    }

    // ---- lambda patterns ----

    fn lambdaAttrs(self: *Lowerer, la: *const Node.LambdaAttrs) !JsonValue {
        var fields: std.ArrayListUnmanaged(JsonValue.Field) = .empty;
        try fields.append(self.arena, .{ .key = "_type", .val = .{ .str = "ExprLambda" } });
        if (la.bind_name) |bind| {
            try fields.append(self.arena, .{ .key = "arg", .val = .{ .str = self.atomText(bind) } });
        }
        try fields.append(self.arena, .{ .key = "body", .val = self.childNode(la.body) });
        if (la.params.len != 0) {
            var formals: std.ArrayListUnmanaged(JsonValue.Field) = .empty;
            for (la.params) |p| {
                const dflt: JsonValue = if (p.default) |d| self.childNode(d) else .nul;
                try formals.append(self.arena, .{ .key = try self.attrNameText(p.name), .val = dflt });
            }
            try fields.append(self.arena, .{ .key = "formals", .val = .{ .object = try formals.toOwnedSlice(self.arena) } });
        }
        // Present iff a pattern lambda (always, here).
        try fields.append(self.arena, .{ .key = "formalsEllipsis", .val = .{ .boolean = la.allow_extra } });
        return .{ .object = try fields.toOwnedSlice(self.arena) };
    }

    // ---- selects / hasAttr ----

    /// Flatten a select chain (`attr_path`/`attr_dynamic` nesting) into a base
    /// expression `e` plus an ordered `attrs` list (static names as strings,
    /// dynamic keys as expressions).
    fn select(self: *Lowerer, chain: *const Node, default: ?*const Node) !JsonValue {
        var attrs: std.ArrayListUnmanaged(JsonValue) = .empty;
        const base = try self.collectSelect(chain, &attrs);
        var fields: std.ArrayListUnmanaged(JsonValue.Field) = .empty;
        try fields.append(self.arena, .{ .key = "_type", .val = .{ .str = "ExprSelect" } });
        try fields.append(self.arena, .{ .key = "attrs", .val = try self.arr(try attrs.toOwnedSlice(self.arena)) });
        if (default) |d| try fields.append(self.arena, .{ .key = "default", .val = self.childNode(d) });
        try fields.append(self.arena, .{ .key = "e", .val = self.childNode(base) });
        return .{ .object = try fields.toOwnedSlice(self.arena) };
    }

    fn collectSelect(self: *Lowerer, n_in: *const Node, attrs: *std.ArrayListUnmanaged(JsonValue)) anyerror!*const Node {
        const n = ast.unwrapParens(n_in);
        switch (n.tag) {
            .attr_path => {
                const base = try self.collectSelect(n.data.attr_path.root, attrs);
                for (n.data.attr_path.segments) |seg| {
                    try attrs.append(self.arena, try self.strOrBytes(try self.attrNameText(seg)));
                }
                return base;
            },
            .attr_dynamic => {
                const base = try self.collectSelect(n.data.attr_dynamic.root, attrs);
                try attrs.append(self.arena, self.childNode(n.data.attr_dynamic.name));
                return base;
            },
            else => return n,
        }
    }

    fn hasAttr(self: *Lowerer, n: *const Node) !JsonValue {
        const ha = n.data.has_attr;
        const attrs = try self.arena.alloc(JsonValue, ha.segments.len);
        for (ha.segments, attrs) |seg, *out| out.* = try self.strOrBytes(try self.attrNameText(seg));
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprOpHasAttr" } },
            .{ .key = "attrs", .val = .{ .array = attrs } },
            .{ .key = "e", .val = self.childNode(ha.root) },
        });
    }

    fn hasAttrMixed(self: *Lowerer, n: *const Node) !JsonValue {
        const ha = n.data.has_attr_mixed;
        const attrs = try self.arena.alloc(JsonValue, ha.segments.len);
        for (ha.segments, attrs) |seg, *out| {
            out.* = switch (seg) {
                .static => |a| try self.strOrBytes(try self.attrNameText(a)),
                .dynamic => |d| self.childNode(d),
            };
        }
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprOpHasAttr" } },
            .{ .key = "attrs", .val = .{ .array = attrs } },
            .{ .key = "e", .val = self.childNode(ha.root) },
        });
    }

    fn list(self: *Lowerer, list_node: *const Node.List) !JsonValue {
        return self.obj(&.{
            .{ .key = "_type", .val = .{ .str = "ExprList" } },
            .{ .key = "elems", .val = self.childList(list_node) },
        });
    }

    // ---- attribute sets / let (nesting, merging, inherit regrouping) ----

    fn attrSet(self: *Lowerer, n: *const Node) !JsonValue {
        const set = try self.buildSet(n.data.attr_set);
        return self.emitSet(set, false, null);
    }

    fn letIn(self: *Lowerer, l: Node.LetIn) !JsonValue {
        const set = try self.arena.create(BindingSet);
        set.* = .{};
        for (l.bindings) |b| {
            try self.addBinding(set, b.path, null, b.expr, b.inherit_outer);
        }
        return self.emitSet(set, true, l.body);
    }

    fn buildSet(self: *Lowerer, s: Node.AttrSet) anyerror!*BindingSet {
        const set = try self.arena.create(BindingSet);
        set.* = .{ .recursive = s.recursive };
        for (s.entries) |e| {
            try self.addBinding(set, e.path, e.dynamic_name, e.expr, e.inherit_outer);
        }
        return set;
    }

    /// Route one binding into the mutable `BindingSet`, performing constant-dynamic
    /// folding, static-path nesting/merging, and inherit / inherit-from
    /// regrouping.
    fn addBinding(
        self: *Lowerer,
        set: *BindingSet,
        path: []const Node.Atom,
        dynamic_name: ?*const Node,
        expr: *const Node,
        inherit_outer: bool,
    ) !void {
        // `inherit name;` — outer inherit.
        if (inherit_outer) {
            try set.inherits.append(self.arena, try self.attrNameText(path[0]));
            return;
        }
        // `inherit (src) name;` — fix clones `src` per name as attr_path(src,
        // [name]) reusing the *same* name atom for the path and the segment, so
        // path[0] and segments[0] share a source offset. A genuine `a = b.a`
        // never does (its lhs and rhs names are distinct tokens).
        if (dynamic_name == null and path.len == 1) {
            const e = ast.unwrapParens(expr);
            if (e.tag == .attr_path and e.data.attr_path.segments.len == 1) {
                const seg = e.data.attr_path.segments[0];
                if (seg.offset == path[0].offset and seg.len == path[0].len) {
                    try self.addInheritFrom(set, e.data.attr_path.root, try self.attrNameText(path[0]));
                    return;
                }
            }
        }

        // Descend the static path.
        var cur = set;
        if (dynamic_name) |dyn| {
            for (path) |seg| cur = try self.descend(cur, try self.attrNameText(seg));
            // Constant-string dynamic key folds into a static attr.
            if (try self.constString(dyn)) |name| {
                try self.setLeaf(cur, name, expr);
            } else {
                try cur.dynamic.append(self.arena, .{ .name = dyn, .value = try self.buildValue(expr) });
            }
            return;
        }
        // Static path (len >= 1): descend all but the last, assign the last.
        var i: usize = 0;
        while (i + 1 < path.len) : (i += 1) cur = try self.descend(cur, try self.attrNameText(path[i]));
        try self.setLeaf(cur, try self.attrNameText(path[path.len - 1]), expr);
    }

    fn addInheritFrom(self: *Lowerer, set: *BindingSet, from: *const Node, name: []const u8) !void {
        const from_off: u32 = if (from.span) |s| s.offset else 0;
        if (set.inherit_from.items.len > 0) {
            const last = &set.inherit_from.items[set.inherit_from.items.len - 1];
            if (last.from_offset == from_off) {
                try last.names.append(self.arena, name);
                return;
            }
        }
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try names.append(self.arena, name);
        try set.inherit_from.append(self.arena, .{ .from = from, .from_offset = from_off, .names = names });
    }

    /// Descend (creating/merging as needed) into the nested set at `name`.
    fn descend(self: *Lowerer, set: *BindingSet, name: []const u8) !*BindingSet {
        if (set.attrs.getPtr(name)) |slot| {
            switch (slot.*) {
                .set => |s| return s,
                // A non-set leaf here would be a duplicate-attribute conflict,
                // which Nix rejects (parse-fail, out of scope). Best-effort:
                // replace it with a fresh set so serialization proceeds.
                .leaf => {
                    const s = try self.arena.create(BindingSet);
                    s.* = .{};
                    slot.* = .{ .set = s };
                    return s;
                },
            }
        }
        const s = try self.arena.create(BindingSet);
        s.* = .{};
        try set.attrs.put(self.arena, name, .{ .set = s });
        return s;
    }

    /// Assign `expr` at `name`, merging when both the existing and new values
    /// are (non-recursive) attribute sets — Nix's recursive attr merge.
    fn setLeaf(self: *Lowerer, set: *BindingSet, name: []const u8, expr: *const Node) !void {
        const newv = try self.buildValue(expr);
        if (set.attrs.getPtr(name)) |slot| {
            if (slot.* == .set and newv == .set and !slot.set.recursive and !newv.set.recursive) {
                try self.mergeSets(slot.set, newv.set);
            } else {
                slot.* = newv; // duplicate non-mergeable → last wins (Nix errors)
            }
            return;
        }
        try set.attrs.put(self.arena, name, newv);
    }

    fn mergeSets(self: *Lowerer, dst: *BindingSet, src: *BindingSet) !void {
        var it = src.attrs.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const val = kv.value_ptr.*;
            if (dst.attrs.getPtr(name)) |slot| {
                if (slot.* == .set and val == .set and !slot.set.recursive and !val.set.recursive) {
                    try self.mergeSets(slot.set, val.set);
                } else {
                    slot.* = val;
                }
            } else {
                try dst.attrs.put(self.arena, name, val);
            }
        }
        try dst.dynamic.appendSlice(self.arena, src.dynamic.items);
        try dst.inherits.appendSlice(self.arena, src.inherits.items);
        try dst.inherit_from.appendSlice(self.arena, src.inherit_from.items);
    }

    /// A value slot: a non-recursive attribute-set literal becomes a mutable
    /// `BindingSet` (so sibling binds can merge into it); everything else is a leaf
    /// serialized on demand.
    fn buildValue(self: *Lowerer, expr: *const Node) !BindingValue {
        const e = ast.unwrapParens(expr);
        if (e.tag == .attr_set) return .{ .set = try self.buildSet(e.data.attr_set) };
        return .{ .leaf = e };
    }

    fn emitSet(self: *Lowerer, set: *BindingSet, is_let: bool, body: ?*const Node) anyerror!JsonValue {
        var fields: std.ArrayListUnmanaged(JsonValue.Field) = .empty;
        try fields.append(self.arena, .{ .key = "_type", .val = .{ .str = if (is_let) "ExprLet" else "ExprSet" } });
        if (is_let) {
            try fields.append(self.arena, .{ .key = "body", .val = self.childNode(body.?) });
        } else {
            try fields.append(self.arena, .{ .key = "recursive", .val = .{ .boolean = set.recursive } });
        }

        // attrs — a valid-UTF-8 name is a JSON object key; an invalid one can't
        // be, so it moves to a sibling `binary_attrs` list (Nix's shape).
        if (set.attrs.count() != 0) {
            var attr_fields: std.ArrayListUnmanaged(JsonValue.Field) = .empty;
            var bin_list: std.ArrayListUnmanaged(JsonValue) = .empty;
            var it = set.attrs.iterator();
            while (it.next()) |kv| {
                const val = try self.emitValue(kv.value_ptr.*);
                if (std.unicode.utf8ValidateSlice(kv.key_ptr.*)) {
                    try attr_fields.append(self.arena, .{ .key = kv.key_ptr.*, .val = val });
                } else {
                    try bin_list.append(self.arena, try self.obj(&.{
                        .{ .key = "name", .val = try self.strOrBytes(kv.key_ptr.*) },
                        .{ .key = "value", .val = val },
                    }));
                }
            }
            if (attr_fields.items.len != 0)
                try fields.append(self.arena, .{ .key = "attrs", .val = .{ .object = try attr_fields.toOwnedSlice(self.arena) } });
            if (bin_list.items.len != 0)
                try fields.append(self.arena, .{ .key = "binary_attrs", .val = try self.obj(&.{
                    .{ .key = "attrs", .val = .{ .array = try bin_list.toOwnedSlice(self.arena) } },
                }) });
        }
        // dynamicAttrs (never present for let)
        if (set.dynamic.items.len != 0) {
            const dyn = try self.arena.alloc(JsonValue, set.dynamic.items.len);
            for (set.dynamic.items, dyn) |d, *out| {
                out.* = try self.obj(&.{
                    .{ .key = "name", .val = self.childNode(d.name) },
                    .{ .key = "value", .val = try self.emitValue(d.value) },
                });
            }
            try fields.append(self.arena, .{ .key = "dynamicAttrs", .val = .{ .array = dyn } });
        }
        // inherit — invalid-UTF-8 names move to a `binary_inherit` list.
        if (set.inherits.items.len != 0) {
            var inh: std.ArrayListUnmanaged(JsonValue.Field) = .empty;
            var bin_list: std.ArrayListUnmanaged(JsonValue) = .empty;
            for (set.inherits.items) |name| {
                if (std.unicode.utf8ValidateSlice(name)) {
                    try inh.append(self.arena, .{ .key = name, .val = try self.exprVar(name) });
                } else {
                    try bin_list.append(self.arena, try self.obj(&.{
                        .{ .key = "name", .val = try self.strOrBytes(name) },
                        .{ .key = "value", .val = try self.exprVar(name) },
                    }));
                }
            }
            if (inh.items.len != 0)
                try fields.append(self.arena, .{ .key = "inherit", .val = .{ .object = try inh.toOwnedSlice(self.arena) } });
            if (bin_list.items.len != 0)
                try fields.append(self.arena, .{ .key = "binary_inherit", .val = try self.obj(&.{
                    .{ .key = "inherit", .val = .{ .array = try bin_list.toOwnedSlice(self.arena) } },
                }) });
        }
        // inheritFrom
        if (set.inherit_from.items.len != 0) {
            const groups = try self.arena.alloc(JsonValue, set.inherit_from.items.len);
            for (set.inherit_from.items, groups) |g, *out| {
                const names = try self.arena.alloc(JsonValue, g.names.items.len);
                for (g.names.items, names) |name, *nn| nn.* = try self.strOrBytes(name);
                out.* = try self.obj(&.{
                    .{ .key = "attrs", .val = .{ .array = names } },
                    .{ .key = "from", .val = self.childNode(g.from) },
                });
            }
            try fields.append(self.arena, .{ .key = "inheritFrom", .val = .{ .array = groups } });
        }

        return .{ .object = try fields.toOwnedSlice(self.arena) };
    }

    fn emitValue(self: *Lowerer, v: BindingValue) !JsonValue {
        return switch (v) {
            .leaf => |n| self.childNode(n),
            .set => |s| self.childSet(s),
        };
    }

    // ---- name decoding ----

    /// The textual name of a static attr/formal atom. A quoted-string atom is
    /// decoded (`"a b"` → `a b`); a bare identifier/keyword is taken verbatim.
    fn attrNameText(self: *Lowerer, atom: Node.Atom) ![]const u8 {
        const text = self.atomText(atom);
        if (string_syntax.kindAt(text, 0) == null) return text;
        const parsed = string_syntax.parseLiteral(self.gpa, self.source, .{
            .start = atom.offset,
            .end = atom.offset + atom.len,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return text,
        };
        defer parsed.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (parsed.parts) |part| {
            switch (part) {
                .text => |t| try buf.appendSlice(self.arena, t.slice()),
                .interpolation => {}, // constant names only; ignore any dynamics
            }
        }
        return try buf.toOwnedSlice(self.arena);
    }

    /// If `n` is a constant (non-interpolating) string literal, its decoded
    /// text; otherwise null. Drives `${"lit"}` → static-attr folding.
    fn constString(self: *Lowerer, n_in: *const Node) !?[]const u8 {
        const n = ast.unwrapParens(n_in);
        if (n.tag != .string) return null;
        const atom = n.data.atom;
        const parsed = string_syntax.parseLiteral(self.gpa, self.source, .{
            .start = atom.offset,
            .end = atom.offset + atom.len,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer parsed.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (parsed.parts) |part| {
            switch (part) {
                .text => |t| try buf.appendSlice(self.arena, t.slice()),
                .interpolation => return null, // interpolating → stays dynamic
            }
        }
        return try buf.toOwnedSlice(self.arena);
    }

    // ---- JsonValue builders ----

    fn obj(self: *Lowerer, fields: []const JsonValue.Field) !JsonValue {
        return .{ .object = try self.arena.dupe(JsonValue.Field, fields) };
    }

    fn arr(self: *Lowerer, items: []const JsonValue) !JsonValue {
        return .{ .array = try self.arena.dupe(JsonValue, items) };
    }
};

/// A mutable attribute-set under construction. Static attrs are keyed by
/// decoded name; the other buckets preserve source order.
const BindingSet = struct {
    recursive: bool = false,
    attrs: std.StringArrayHashMapUnmanaged(BindingValue) = .empty,
    dynamic: std.ArrayListUnmanaged(DynamicBinding) = .empty,
    inherits: std.ArrayListUnmanaged([]const u8) = .empty,
    inherit_from: std.ArrayListUnmanaged(BInheritFrom) = .empty,
};

const BindingValue = union(enum) {
    leaf: *const Node,
    set: *BindingSet,
};

const DynamicBinding = struct { name: *const Node, value: BindingValue };

const BInheritFrom = struct {
    from: *const Node,
    from_offset: u32,
    names: std.ArrayListUnmanaged([]const u8),
};

test {
    _ = @import("parse_json/tests.zig");
}
