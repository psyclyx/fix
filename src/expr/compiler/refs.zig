//! Walks an AST subtree collecting the free identifier names it references
//! (including identifier-shaped words inside `${…}` interpolation), either
//! into a set or streamed to a marker callback.
//! Deliberately conservative — a superset is fine, since callers
//! (let-binding cell/eagerness classification) only ever keep extra
//! bindings alive, never drop a live one.

const std = @import("std");
const compiler_mod = @import("context.zig");

const fold = @import("fold.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;

/// Walk `node` and add every identifier name encountered to `out`,
/// including textual matches inside `${...}` interpolation in atoms.
/// Conservatively mirrors `nodeReferencesName`'s coverage — false
/// positives just keep cells (and bindings) around, never break
/// semantics.
pub fn collectReferencedNames(self: *Compiler, node: *const Node, out: *std.StringHashMapUnmanaged(void)) anyerror!void {
    var ctx: CollectCtx = .{ .allocator = self.allocator, .out = out };
    walkReferencedNames(self, node, &ctx);
    if (ctx.err) |err| return err;
}

const CollectCtx = struct {
    allocator: std.mem.Allocator,
    out: *std.StringHashMapUnmanaged(void),
    err: ?anyerror = null,

    fn mark(self: *CollectCtx, name: []const u8) void {
        self.out.put(self.allocator, name, {}) catch |err| {
            self.err = err;
        };
    }
};

/// Walk `node` with exactly `collectReferencedNames`' coverage, but hand
/// each encountered name to `ctx.mark(name)` instead of accumulating a
/// set. For callers that only test membership of a small fixed name set
/// (let-binding classification) this skips building — and allocating —
/// a full subtree name set per region.
pub fn walkReferencedNames(self: *Compiler, node: *const Node, ctx: anytype) void {
    switch (node.tag) {
        .integer, .float_val, .uri => {},
        // `<name>` desugars to `builtins.findFile __nixPath "name"`, so it
        // references `__nixPath` — a `let __nixPath = …` binding it resolves
        // against must be kept alive by this analysis (else it's dropped as
        // dead and the search path silently falls back to the global one).
        .search_path => ctx.mark("__nixPath"),
        .string, .path => walkIdentifiersInSpan(self, node.data.atom, ctx),
        // Never parsed: conservatively mark every identifier-shaped word in
        // the span (a superset of the real references — false positives
        // only keep cells alive, matching this walker's contract).
        .elided => markIdentWords(self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len], ctx),
        .identifier => {
            // Synthetic (full-laziness) atoms carry an interned id, len 0.
            const a = node.data.atom;
            const ident = if (a.len == 0) self.intern.get(@intCast(a.offset)) else self.source[a.offset .. a.offset + a.len];
            ctx.mark(ident);
        },
        .unary_op => {
            // Lix operator overloading: unary `-e` lowers to `__sub 0 e`, so
            // mark `__sub` referenced — a matching lexical binding must be
            // kept alive even though no identifier textually names it.
            if (node.data.unary.op == .negate) ctx.mark("__sub");
            walkReferencedNames(self, node.data.unary.expr, ctx);
        },
        .binary_op => {
            // Likewise `-` `*` `/` `<` lower to calls of `__sub`/`__mul`/
            // `__div`/`__lessThan` when such a binding is in scope.
            if (fold.overloadNameForBinary(node.data.binary.op)) |name| ctx.mark(name);
            walkReferencedNames(self, node.data.binary.left, ctx);
            walkReferencedNames(self, node.data.binary.right, ctx);
        },
        .apply => {
            walkReferencedNames(self, node.data.apply.func, ctx);
            walkReferencedNames(self, node.data.apply.arg, ctx);
        },
        .lambda => walkReferencedNames(self, node.data.lambda.body, ctx),
        .lambda_attrs => {
            const la = node.data.lambda_attrs;
            for (la.params) |param| {
                if (param.default) |default| walkReferencedNames(self, default, ctx);
            }
            walkReferencedNames(self, la.body, ctx);
        },
        .let_in => {
            const li = node.data.let_in;
            for (li.bindings) |b| walkReferencedNames(self, b.expr, ctx);
            walkReferencedNames(self, li.body, ctx);
        },
        .if_else => {
            const ie = node.data.if_else;
            walkReferencedNames(self, ie.cond, ctx);
            walkReferencedNames(self, ie.then_branch, ctx);
            walkReferencedNames(self, ie.else_branch, ctx);
        },
        .assert => {
            walkReferencedNames(self, node.data.assert.cond, ctx);
            walkReferencedNames(self, node.data.assert.body, ctx);
        },
        .with_expr => {
            walkReferencedNames(self, node.data.with_expr.attr_set, ctx);
            walkReferencedNames(self, node.data.with_expr.body, ctx);
        },
        .attr_set => {
            for (node.data.attr_set.entries) |entry| {
                if (entry.dynamic_name) |dn| walkReferencedNames(self, dn, ctx);
                for (entry.path) |seg| walkIdentifiersInSpan(self, seg, ctx);
                walkReferencedNames(self, entry.expr, ctx);
            }
        },
        .attr_path => {
            walkReferencedNames(self, node.data.attr_path.root, ctx);
            for (node.data.attr_path.segments) |seg| walkIdentifiersInSpan(self, seg, ctx);
        },
        .attr_dynamic => {
            walkReferencedNames(self, node.data.attr_dynamic.root, ctx);
            walkReferencedNames(self, node.data.attr_dynamic.name, ctx);
        },
        .attr_or => {
            walkReferencedNames(self, node.data.attr_or.attr_path, ctx);
            walkReferencedNames(self, node.data.attr_or.default, ctx);
        },
        .has_attr => {
            walkReferencedNames(self, node.data.has_attr.root, ctx);
            for (node.data.has_attr.segments) |seg| walkIdentifiersInSpan(self, seg, ctx);
        },
        .has_attr_mixed => {
            const ham = node.data.has_attr_mixed;
            walkReferencedNames(self, ham.root, ctx);
            for (ham.segments) |seg| switch (seg) {
                .static => |a| walkIdentifiersInSpan(self, a, ctx),
                .dynamic => |n| walkReferencedNames(self, n, ctx),
            };
        },
        .list => {
            for (node.data.list.items) |item| walkReferencedNames(self, item, ctx);
        },
        .parens => walkReferencedNames(self, node.data.parens, ctx),
    }
}

/// Hand every identifier-shaped substring in a source span to
/// `ctx.mark`. Catches references inside `${...}` interpolation in
/// atom-typed fields without expanding through the string parser.
/// A span with no `${` at all cannot reference anything — skip it
/// (its words would only ever be false positives).
pub fn walkIdentifiersInSpan(self: *Compiler, atom: Node.Atom, ctx: anytype) void {
    const text = self.source[atom.offset .. atom.offset + atom.len];
    if (std.mem.indexOf(u8, text, "${") == null) return;
    markIdentWords(text, ctx);
}

fn markIdentWords(text: []const u8, ctx: anytype) void {
    var i: usize = 0;
    while (i < text.len) {
        if (isIdentStart(text[i])) {
            const start = i;
            while (i < text.len and isIdentChar(text[i])) : (i += 1) {}
            ctx.mark(text[start..i]);
        } else {
            i += 1;
        }
    }
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '\'' or c == '-';
}
