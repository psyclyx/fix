//! AST node definitions.
//!
//! All nodes are allocated in an arena allocator and never freed individually.
//! Nodes reference source spans via byte offsets into the source file.
//! This keeps nodes small and avoids string copies.

const std = @import("std");

pub const NodeTag = enum(u8) {
    // ---- atoms ----
    integer,
    float_val,
    string,
    path,
    uri,
    search_path,
    identifier,
    bool_true,
    bool_false,
    null,

    // ---- compound ----
    unary_op,
    binary_op,
    apply,
    lambda,
    lambda_attrs,
    let_in,
    if_else,
    assert,
    with_expr,
    attr_set,
    attr_path, // foo.bar.baz
    attr_dynamic, // foo.${expr}
    attr_or, // foo.bar or default
    has_attr, // foo ? bar.baz
    has_attr_mixed, // foo ? bar.${expr}
    list,
    parens, // parenthesized subexpression

    // ---- lazy parsing ----
    /// An attrset value body whose PARSING was skipped (body-span elision):
    /// the parser recorded the body's source span (`data.atom`) instead of
    /// LR-driving it, because the body was going to be lazily compiled
    /// (deferred) anyway. The compiler sub-parses the span on demand — at
    /// force time for deferred bodies, or immediately ("materialize") when
    /// an eager compile needs the real shape. See `Parser.scanElidableBody`
    /// and `compiler/literals.zig materializeElided`.
    elided,
};

pub const BinaryOp = enum(u8) {
    add,
    sub,
    mul,
    div,
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
    and_,
    or_,
    impl, // ->
    update, // //
    concat, // + on strings
};

pub const UnaryOp = enum(u8) {
    not,
    negate,
};

/// Surface provenance of an `apply` node. A pipe operator is pure sugar
/// for function application, so `|>`/`<|` lower to ordinary `apply` nodes
/// (reusing all of compile/strictness/eval) and record which surface form
/// produced them, purely so the tree can be printed back faithfully. The
/// operands are always stored in evaluation order (func, arg) — the tag
/// says how to re-spell them:
///   .none     → `func arg`
///   .forward  → `arg |> func`   (from `x |> f`, arg=x func=f)
///   .backward → `func <| arg`   (from `f <| x`, func=f arg=x)
pub const PipeSugar = enum(u8) {
    none,
    forward,
    backward,
};

/// All AST nodes use this struct. The `data` union holds type-specific fields.
/// Pointers inside `data` point to other Node structs within the same arena.
pub const Node = struct {
    tag: NodeTag,
    data: Data,
    span: ?Atom,

    pub const Data = union {
        // Atoms store byte offsets into source.
        atom: Atom,
        // Compound nodes hold pointers to children.
        unary: Unary,
        binary: Binary,
        apply: Apply,
        lambda: Lambda,
        // Boxed: `LambdaAttrs` is the largest variant (40B) but rare (only
        // lambda patterns), so keeping it inline would bloat *every* node's
        // by-value write. Behind a pointer the whole `Data` union — and thus
        // `Node` — is much smaller (64B -> 40B). Field reads auto-deref.
        lambda_attrs: *LambdaAttrs,
        let_in: LetIn,
        if_else: IfElse,
        assert: Assert,
        with_expr: WithExpr,
        attr_set: AttrSet,
        attr_path: AttrPath,
        attr_dynamic: AttrDynamic,
        attr_or: AttrOr,
        has_attr: HasAttr,
        has_attr_mixed: HasAttrMixed,
        list: List,
        parens: *Node,
    };

    pub const Atom = struct {
        offset: u32,
        len: u32,
    };

    pub const Unary = struct {
        op: UnaryOp,
        expr: *Node,
    };

    pub const Binary = struct {
        op: BinaryOp,
        left: *Node,
        right: *Node,
    };

    pub const Apply = struct {
        func: *Node,
        arg: *Node,
        /// Surface form this application was written as; `.none` for a
        /// plain `func arg`. See `PipeSugar`.
        pipe: PipeSugar = .none,
    };

    pub const Lambda = struct {
        param_offset: u32,
        param_len: u32,
        body: *Node,
    };

    pub const LambdaAttrs = struct {
        bind_name: ?Atom,
        params: []LambdaAttrParam,
        allow_extra: bool,
        body: *Node,
    };

    pub const LambdaAttrParam = struct {
        name: Atom,
        default: ?*Node,
    };

    pub const LetIn = struct {
        bindings: []Binding,
        body: *Node,
    };

    pub const Binding = struct {
        name_offset: u32,
        name_len: u32,
        path: []Atom,
        expr: *Node,
        inherit_outer: bool = false,
        /// Non-zero for entries originating in the same `inherit (expr)`
        /// clause. The compiler uses this to share one lazy source binding.
        inherit_group: u32 = 0,
    };

    pub const IfElse = struct {
        cond: *Node,
        then_branch: *Node,
        else_branch: *Node,
    };

    pub const Assert = struct {
        cond: *Node,
        body: *Node,
    };

    pub const WithExpr = struct {
        attr_set: *Node,
        body: *Node,
    };

    pub const AttrSetEntry = struct {
        path: []Atom,
        dynamic_name: ?*Node = null,
        expr: *Node,
        inherit_outer: bool = false,
        inherit_group: u32 = 0,
    };

    pub const AttrSet = struct {
        entries: []AttrSetEntry,
        recursive: bool,
    };

    pub const AttrPath = struct {
        root: *Node,
        /// Attribute names (as source offsets).
        /// e.g., `a.b.c` → [a, b, c]
        segments: []Atom,
    };

    pub const AttrDynamic = struct {
        root: *Node,
        name: *Node,
    };

    pub const AttrOr = struct {
        attr_path: *Node,
        default: *Node,
    };

    pub const HasAttr = struct {
        root: *Node,
        segments: []Atom,
    };

    pub const HasAttrMixedSegment = union(enum) {
        static: Atom,
        dynamic: *Node,
    };

    pub const HasAttrMixed = struct {
        root: *Node,
        segments: []HasAttrMixedSegment,
    };

    pub const List = struct {
        items: []*Node,
    };
};

/// Arena allocator wrapper for building ASTs. All nodes and their children
/// live here and are freed together at `deinit`.
pub const AstArena = struct {
    // A parse is single-owner for the arena's lifetime.
    inner: @import("base").arena.ArenaAllocator,

    pub fn init(parent_allocator: std.mem.Allocator) AstArena {
        return .{ .inner = @import("base").arena.ArenaAllocator.init(parent_allocator) };
    }

    pub fn deinit(self: *AstArena) void {
        self.inner.deinit();
    }

    pub fn allocator(self: *AstArena) std.mem.Allocator {
        return self.inner.allocator();
    }

    pub fn createNode(self: *AstArena, tag: NodeTag, data: Node.Data) !*Node {
        const node = try self.allocator().create(Node);
        node.* = .{ .tag = tag, .data = data, .span = nodeSourceSpan(tag, data) };
        return node;
    }

    pub fn allocSlice(self: *AstArena, comptime T: type, len: usize) ![]T {
        return self.allocator().alloc(T, len);
    }
};

fn nodeSourceSpan(tag: NodeTag, data: Node.Data) ?Node.Atom {
    return switch (tag) {
        .integer,
        .float_val,
        .string,
        .path,
        .uri,
        .search_path,
        .identifier,
        .bool_true,
        .bool_false,
        .null,
        .elided,
        => data.atom,

        .unary_op => data.unary.expr.span,
        .binary_op => combineAtoms(data.binary.left.span, data.binary.right.span),
        .apply => combineAtoms(data.apply.func.span, data.apply.arg.span),
        .lambda => combineAtoms(
            .{ .offset = data.lambda.param_offset, .len = data.lambda.param_len },
            data.lambda.body.span,
        ),
        .lambda_attrs => lambdaAttrsSourceSpan(data.lambda_attrs.*),
        .let_in => letSourceSpan(data.let_in),
        .if_else => combineAtoms(data.if_else.cond.span, combineAtoms(data.if_else.then_branch.span, data.if_else.else_branch.span)),
        .assert => combineAtoms(data.assert.cond.span, data.assert.body.span),
        .with_expr => combineAtoms(data.with_expr.attr_set.span, data.with_expr.body.span),
        .attr_set => attrSetSourceSpan(data.attr_set),
        .attr_path => attrPathSourceSpan(data.attr_path),
        .attr_dynamic => combineAtoms(data.attr_dynamic.root.span, data.attr_dynamic.name.span),
        .attr_or => combineAtoms(data.attr_or.attr_path.span, data.attr_or.default.span),
        .has_attr => hasAttrSourceSpan(data.has_attr),
        .has_attr_mixed => hasAttrMixedSourceSpan(data.has_attr_mixed),
        .list => listSourceSpan(data.list),
        .parens => data.parens.span,
    };
}

fn combineAtoms(left: ?Node.Atom, right: ?Node.Atom) ?Node.Atom {
    if (left == null) return right;
    if (right == null) return left;

    const a = left.?;
    const b = right.?;
    const start = @min(a.offset, b.offset);
    const end = @max(a.offset + a.len, b.offset + b.len);
    return .{ .offset = start, .len = end - start };
}

fn lambdaAttrsSourceSpan(lambda: Node.LambdaAttrs) ?Node.Atom {
    var span = lambda.body.span;
    if (lambda.bind_name) |bind_name| span = combineAtoms(span, bind_name);
    for (lambda.params) |param| {
        span = combineAtoms(span, param.name);
        if (param.default) |default| span = combineAtoms(span, default.span);
    }
    return span;
}

fn letSourceSpan(let_in: Node.LetIn) ?Node.Atom {
    var span = let_in.body.span;
    for (let_in.bindings) |binding| {
        span = combineAtoms(span, .{ .offset = binding.name_offset, .len = binding.name_len });
        for (binding.path) |segment| span = combineAtoms(span, segment);
        span = combineAtoms(span, binding.expr.span);
    }
    return span;
}

fn attrSetSourceSpan(attr_set: Node.AttrSet) ?Node.Atom {
    var span: ?Node.Atom = null;
    for (attr_set.entries) |entry| {
        for (entry.path) |segment| span = combineAtoms(span, segment);
        if (entry.dynamic_name) |dynamic_name| span = combineAtoms(span, dynamic_name.span);
        span = combineAtoms(span, entry.expr.span);
    }
    return span;
}

fn attrPathSourceSpan(attr_path: Node.AttrPath) ?Node.Atom {
    var span = attr_path.root.span;
    for (attr_path.segments) |segment| span = combineAtoms(span, segment);
    return span;
}

fn hasAttrSourceSpan(has_attr: Node.HasAttr) ?Node.Atom {
    var span = has_attr.root.span;
    for (has_attr.segments) |segment| span = combineAtoms(span, segment);
    return span;
}

fn hasAttrMixedSourceSpan(has_attr: Node.HasAttrMixed) ?Node.Atom {
    var span = has_attr.root.span;
    for (has_attr.segments) |segment| {
        span = switch (segment) {
            .static => |atom| combineAtoms(span, atom),
            .dynamic => |node| combineAtoms(span, node.span),
        };
    }
    return span;
}

fn listSourceSpan(list: Node.List) ?Node.Atom {
    var span: ?Node.Atom = null;
    for (list.items) |item| span = combineAtoms(span, item.span);
    return span;
}

pub fn cloneNode(arena: *AstArena, node: *const Node) anyerror!*Node {
    return switch (node.tag) {
        .integer,
        .float_val,
        .string,
        .path,
        .uri,
        .search_path,
        .identifier,
        .bool_true,
        .bool_false,
        .null,
        .elided,
        => arena.createNode(node.tag, .{ .atom = node.data.atom }),

        .unary_op => arena.createNode(.unary_op, .{ .unary = .{
            .op = node.data.unary.op,
            .expr = try cloneNode(arena, node.data.unary.expr),
        } }),
        .binary_op => arena.createNode(.binary_op, .{ .binary = .{
            .op = node.data.binary.op,
            .left = try cloneNode(arena, node.data.binary.left),
            .right = try cloneNode(arena, node.data.binary.right),
        } }),
        .apply => arena.createNode(.apply, .{ .apply = .{
            .func = try cloneNode(arena, node.data.apply.func),
            .arg = try cloneNode(arena, node.data.apply.arg),
            .pipe = node.data.apply.pipe,
        } }),
        .lambda => arena.createNode(.lambda, .{ .lambda = .{
            .param_offset = node.data.lambda.param_offset,
            .param_len = node.data.lambda.param_len,
            .body = try cloneNode(arena, node.data.lambda.body),
        } }),
        .lambda_attrs => blk: {
            const la = try arena.allocator().create(Node.LambdaAttrs);
            la.* = .{
                .bind_name = node.data.lambda_attrs.bind_name,
                .params = try cloneLambdaParams(arena, node.data.lambda_attrs.params),
                .allow_extra = node.data.lambda_attrs.allow_extra,
                .body = try cloneNode(arena, node.data.lambda_attrs.body),
            };
            break :blk arena.createNode(.lambda_attrs, .{ .lambda_attrs = la });
        },
        .let_in => arena.createNode(.let_in, .{ .let_in = .{
            .bindings = try cloneBindings(arena, node.data.let_in.bindings),
            .body = try cloneNode(arena, node.data.let_in.body),
        } }),
        .if_else => arena.createNode(.if_else, .{ .if_else = .{
            .cond = try cloneNode(arena, node.data.if_else.cond),
            .then_branch = try cloneNode(arena, node.data.if_else.then_branch),
            .else_branch = try cloneNode(arena, node.data.if_else.else_branch),
        } }),
        .assert => arena.createNode(.assert, .{ .assert = .{
            .cond = try cloneNode(arena, node.data.assert.cond),
            .body = try cloneNode(arena, node.data.assert.body),
        } }),
        .with_expr => arena.createNode(.with_expr, .{ .with_expr = .{
            .attr_set = try cloneNode(arena, node.data.with_expr.attr_set),
            .body = try cloneNode(arena, node.data.with_expr.body),
        } }),
        .attr_set => arena.createNode(.attr_set, .{ .attr_set = .{
            .entries = try cloneAttrSetEntries(arena, node.data.attr_set.entries),
            .recursive = node.data.attr_set.recursive,
        } }),
        .attr_path => arena.createNode(.attr_path, .{ .attr_path = .{
            .root = try cloneNode(arena, node.data.attr_path.root),
            .segments = try cloneAtoms(arena, node.data.attr_path.segments),
        } }),
        .attr_dynamic => arena.createNode(.attr_dynamic, .{ .attr_dynamic = .{
            .root = try cloneNode(arena, node.data.attr_dynamic.root),
            .name = try cloneNode(arena, node.data.attr_dynamic.name),
        } }),
        .attr_or => arena.createNode(.attr_or, .{ .attr_or = .{
            .attr_path = try cloneNode(arena, node.data.attr_or.attr_path),
            .default = try cloneNode(arena, node.data.attr_or.default),
        } }),
        .has_attr => arena.createNode(.has_attr, .{ .has_attr = .{
            .root = try cloneNode(arena, node.data.has_attr.root),
            .segments = try cloneAtoms(arena, node.data.has_attr.segments),
        } }),
        .has_attr_mixed => arena.createNode(.has_attr_mixed, .{ .has_attr_mixed = .{
            .root = try cloneNode(arena, node.data.has_attr_mixed.root),
            .segments = try cloneHasAttrMixedSegments(arena, node.data.has_attr_mixed.segments),
        } }),
        .list => arena.createNode(.list, .{ .list = .{
            .items = try cloneNodeSlice(arena, node.data.list.items),
        } }),
        .parens => arena.createNode(.parens, .{ .parens = try cloneNode(arena, node.data.parens) }),
    };
}

fn cloneAtoms(arena: *AstArena, atoms: []const Node.Atom) anyerror![]Node.Atom {
    const cloned = try arena.allocSlice(Node.Atom, atoms.len);
    @memcpy(cloned, atoms);
    return cloned;
}

fn cloneNodeSlice(arena: *AstArena, nodes: []const *Node) anyerror![]*Node {
    const cloned = try arena.allocSlice(*Node, nodes.len);
    for (nodes, cloned) |item, *dest| {
        dest.* = try cloneNode(arena, item);
    }
    return cloned;
}

fn cloneLambdaParams(arena: *AstArena, params: []const Node.LambdaAttrParam) anyerror![]Node.LambdaAttrParam {
    const cloned = try arena.allocSlice(Node.LambdaAttrParam, params.len);
    for (params, cloned) |param, *dest| {
        dest.* = .{
            .name = param.name,
            .default = if (param.default) |default| try cloneNode(arena, default) else null,
        };
    }
    return cloned;
}

fn cloneBindings(arena: *AstArena, bindings: []const Node.Binding) anyerror![]Node.Binding {
    const cloned = try arena.allocSlice(Node.Binding, bindings.len);
    for (bindings, cloned) |binding, *dest| {
        dest.* = .{
            .name_offset = binding.name_offset,
            .name_len = binding.name_len,
            .path = try cloneAtoms(arena, binding.path),
            .expr = try cloneNode(arena, binding.expr),
            .inherit_outer = binding.inherit_outer,
            .inherit_group = binding.inherit_group,
        };
    }
    return cloned;
}

fn cloneAttrSetEntries(arena: *AstArena, entries: []const Node.AttrSetEntry) anyerror![]Node.AttrSetEntry {
    const cloned = try arena.allocSlice(Node.AttrSetEntry, entries.len);
    for (entries, cloned) |entry, *dest| {
        dest.* = .{
            .path = try cloneAtoms(arena, entry.path),
            .dynamic_name = if (entry.dynamic_name) |name| try cloneNode(arena, name) else null,
            .expr = try cloneNode(arena, entry.expr),
            .inherit_outer = entry.inherit_outer,
            .inherit_group = entry.inherit_group,
        };
    }
    return cloned;
}

fn cloneHasAttrMixedSegments(arena: *AstArena, segments: []const Node.HasAttrMixedSegment) anyerror![]Node.HasAttrMixedSegment {
    const cloned = try arena.allocSlice(Node.HasAttrMixedSegment, segments.len);
    for (segments, cloned) |segment, *dest| {
        dest.* = switch (segment) {
            .static => |atom| .{ .static = atom },
            .dynamic => |dynamic| .{ .dynamic = try cloneNode(arena, dynamic) },
        };
    }
    return cloned;
}

/// The literal node `true`, `false` or `null` stands for, or null for any other
/// identifier. Nix binds the three in the base environment rather than reserving
/// them, so they lex as identifiers and only *become* literals once nothing is
/// known to bind the name — a judgement the parser makes per file
/// (`Parser.parse`) and the compiler makes per use, from the live scope.
pub fn keywordLiteralTag(text: []const u8) ?NodeTag {
    const eql = std.mem.eql;
    return switch (text.len) {
        4 => if (eql(u8, text, "true")) .bool_true else if (eql(u8, text, "null")) .null else null,
        5 => if (eql(u8, text, "false")) .bool_false else null,
        else => null,
    };
}

pub fn unwrapParens(node: *const Node) *const Node {
    var current = node;
    while (current.tag == .parens) current = current.data.parens;
    return current;
}

pub fn nodeMayEvaluateToFloat(node: *const Node) bool {
    return switch (node.tag) {
        .float_val => true,
        .parens => nodeMayEvaluateToFloat(node.data.parens),
        .unary_op => nodeMayEvaluateToFloat(node.data.unary.expr),
        .binary_op => switch (node.data.binary.op) {
            .add, .sub, .mul, .div => nodeMayEvaluateToFloat(node.data.binary.left) or
                nodeMayEvaluateToFloat(node.data.binary.right),
            else => false,
        },
        else => false,
    };
}

/// Shift every source offset in the subtree by `offset`.
/// Used when splicing a parsed fragment into a larger source buffer.
pub fn offsetNode(node: *Node, offset: u32) void {
    if (node.span) |*span| span.offset += offset;
    switch (node.tag) {
        .integer, .float_val, .string, .path, .uri, .search_path, .identifier, .bool_true, .bool_false, .null, .elided => {
            node.data.atom.offset += offset;
        },
        .unary_op => offsetNode(node.data.unary.expr, offset),
        .binary_op => {
            offsetNode(node.data.binary.left, offset);
            offsetNode(node.data.binary.right, offset);
        },
        .apply => {
            offsetNode(node.data.apply.func, offset);
            offsetNode(node.data.apply.arg, offset);
        },
        .lambda => {
            node.data.lambda.param_offset += offset;
            offsetNode(node.data.lambda.body, offset);
        },
        .lambda_attrs => {
            if (node.data.lambda_attrs.bind_name) |*bind_name| {
                bind_name.offset += offset;
            }
            for (node.data.lambda_attrs.params) |*param| {
                param.name.offset += offset;
                if (param.default) |default| offsetNode(default, offset);
            }
            offsetNode(node.data.lambda_attrs.body, offset);
        },
        .let_in => {
            for (node.data.let_in.bindings) |*binding| {
                binding.name_offset += offset;
                for (binding.path) |*segment| {
                    segment.offset += offset;
                }
                offsetNode(binding.expr, offset);
            }
            offsetNode(node.data.let_in.body, offset);
        },
        .if_else => {
            offsetNode(node.data.if_else.cond, offset);
            offsetNode(node.data.if_else.then_branch, offset);
            offsetNode(node.data.if_else.else_branch, offset);
        },
        .assert => {
            offsetNode(node.data.assert.cond, offset);
            offsetNode(node.data.assert.body, offset);
        },
        .with_expr => {
            offsetNode(node.data.with_expr.attr_set, offset);
            offsetNode(node.data.with_expr.body, offset);
        },
        .attr_set => {
            for (node.data.attr_set.entries) |*entry| {
                for (entry.path) |*segment| {
                    segment.offset += offset;
                }
                if (entry.dynamic_name) |dynamic_name| offsetNode(dynamic_name, offset);
                offsetNode(entry.expr, offset);
            }
        },
        .attr_path => {
            offsetNode(node.data.attr_path.root, offset);
            for (node.data.attr_path.segments) |*segment| {
                segment.offset += offset;
            }
        },
        .attr_dynamic => {
            offsetNode(node.data.attr_dynamic.root, offset);
            offsetNode(node.data.attr_dynamic.name, offset);
        },
        .attr_or => {
            offsetNode(node.data.attr_or.attr_path, offset);
            offsetNode(node.data.attr_or.default, offset);
        },
        .has_attr => {
            offsetNode(node.data.has_attr.root, offset);
            for (node.data.has_attr.segments) |*segment| {
                segment.offset += offset;
            }
        },
        .has_attr_mixed => {
            offsetNode(node.data.has_attr_mixed.root, offset);
            for (node.data.has_attr_mixed.segments) |*segment| {
                switch (segment.*) {
                    .static => |*atom| atom.offset += offset,
                    .dynamic => |dynamic| offsetNode(dynamic, offset),
                }
            }
        },
        .list => {
            for (node.data.list.items) |item| {
                offsetNode(item, offset);
            }
        },
        .parens => offsetNode(node.data.parens, offset),
    }
}
