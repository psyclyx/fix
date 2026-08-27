//! Copy-on-write application of let-float rewrite plans.
//!
//! One rebuild per walk batch: starting from the walk-root cluster, the
//! Rewriter descends the whole subtree applying the UNIT-LEVEL replacement
//! and wrap maps, and — at every nested cluster head — that cluster's own
//! keep/flatten plan inline. Rebuilt residual lets are recorded in the unit
//! state's `decided` set so `rewriteLet` compiles them untouched instead of
//! re-walking fresh nodes (the old per-let scheme's re-walk cascade).

const std = @import("std");
const compiler_mod = @import("../context.zig");
const ast = @import("syntax").ast;
const types = @import("runtime").types;
const attr_names = @import("../attr_names.zig");
const analysis = @import("../let_analysis/model.zig");
const model = @import("model.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const InternId = types.InternId;

/// Rebuild `cluster`'s residual form (and, transitively, every nested
/// cluster's) with all unit-level decisions applied. Returns the node to
/// compile instead of the cluster's head: the head itself when nothing in
/// the subtree changed, a rebuilt `let_in`, or the bare (rewritten) body
/// when every binding dissolved. Memoized per cluster head.
pub fn rebuildCluster(
    self: *Compiler,
    arena: *ast.AstArena,
    ua: *analysis.UnitAnalysis,
    state: *model.UnitState,
    cluster: *analysis.Cluster,
) !*const Node {
    var rw = Rewriter{
        .c = self,
        .arena = arena,
        .ua = ua,
        .state = state,
    };
    return rw.rebuildClusterNode(cluster);
}

/// Rebuild an arbitrary subtree with all unit-level decisions applied
/// (nested cluster plans at their heads, replacements, wraps). Used by the
/// full-laziness lambda hook, which must consume the freshly-decided batch
/// maps IMMEDIATELY: nested residuals come out `decided`, so a later
/// interpolation sub-parse (a new batch, cleared maps) cannot strand a
/// pending hit-path rebuild.
pub fn rebuildTree(
    self: *Compiler,
    arena: *ast.AstArena,
    ua: *analysis.UnitAnalysis,
    state: *model.UnitState,
    root: *const Node,
) !*const Node {
    var rw = Rewriter{
        .c = self,
        .arena = arena,
        .ua = ua,
        .state = state,
    };
    return rw.rewrite(root);
}

/// The cached flat single-level node for a merged directly-nested let spine
/// (entries concatenated across levels, body = the innermost body).
pub fn flatNode(
    arena: *ast.AstArena,
    state: *model.UnitState,
    cluster: *const analysis.Cluster,
) !*const Node {
    if (cluster.levels == 1) return cluster.head;
    const overlay = try state.overlay(cluster.head);
    if (overlay.flat == null) {
        const merged = try arena.allocSlice(Node.Binding, cluster.entries.len);
        @memcpy(merged, cluster.entries);
        const flat = try arena.createNode(.let_in, .{ .let_in = .{
            .bindings = merged,
            .body = @constCast(cluster.body),
        } });
        flat.span = cluster.head.span;
        overlay.flat = flat;
    }
    return overlay.flat.?;
}

/// Copy-on-write tree rewrite: descends the whole subtree, swapping nodes
/// that have replacements (and recursing into the replacement, so a chain of
/// sinks composes), applying nested clusters' keep/flatten plans at their
/// head nodes, and rebuilding only ancestors of a change.
const Rewriter = struct {
    c: *Compiler,
    arena: *ast.AstArena,
    ua: *analysis.UnitAnalysis,
    state: *model.UnitState,
    changed: bool = false,

    fn rewrite(self: *Rewriter, node_in: *const Node) anyerror!*const Node {
        var node = node_in;
        // A replacement may itself be a replaced site (a sibling sunk into an
        // alias's RHS): chase the chain. Acyclic because movement is strictly
        // "into" a live sibling and recursive SCCs never move.
        while (self.state.replacements.get(node)) |replacement| {
            self.changed = true;
            node = replacement;
        }
        const rewritten = try self.rewriteChildren(node);
        // Branch-local floats wrap the (fully rewritten) branch expression
        // in a synthetic let re-binding the floated names — keyed by the
        // ORIGINAL branch node the graph walk recorded.
        if (self.state.wraps.get(node_in)) |floated| {
            return self.wrapWithLet(node_in, rewritten, floated.items);
        }
        return rewritten;
    }

    /// Apply `cluster`'s plan at its head: flatten a merged spine, drop
    /// non-kept groups, rewrite surviving RHSes and the body. Fresh residual
    /// let nodes are marked `decided` (their plan is already applied);
    /// returning the original head means nothing in the subtree changed and
    /// the ordinary registry-hit path handles it at compile.
    fn rebuildClusterNode(self: *Rewriter, cluster: *analysis.Cluster) anyerror!*const Node {
        const overlay = try self.state.overlay(cluster.head);
        if (overlay.rebuilt != null and overlay.rebuilt_batch >= overlay.walk_batch) {
            const r = overlay.rebuilt.?;
            self.changed = self.changed or r != cluster.head;
            return r;
        }
        const plan = &overlay.plan.?;

        const base = try flatNode(self.arena, self.state, cluster);
        const let_in = base.data.let_in;

        // Which original entries survive? An entry survives when its root
        // group's binding is kept. Group ids recompute by first-occurrence
        // order, mirroring `let_analysis.collectBindings` (merged spines
        // cannot collide across levels, so one map spans the flat list).
        const entry_group = try self.c.allocator.alloc(usize, let_in.bindings.len);
        {
            var by_name: std.AutoHashMapUnmanaged(InternId, usize) = .empty;
            defer by_name.deinit(self.c.allocator);
            var next: usize = 0;
            for (let_in.bindings, 0..) |entry, i| {
                const name_id = try self.c.intern.intern(attr_names.span(self.c, entry.path[0]));
                const gop = try by_name.getOrPut(self.c.allocator, name_id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = next;
                    next += 1;
                }
                entry_group[i] = gop.value_ptr.*;
            }
        }

        var surviving: usize = 0;
        for (let_in.bindings, 0..) |_, i| {
            if (plan.keep[entry_group[i]]) surviving += 1;
        }

        const body_was = self.changed;
        self.changed = false;
        const new_body = try self.rewrite(let_in.body);

        const result: *const Node = blk: {
            if (surviving == 0) {
                self.changed = true;
                break :blk new_body;
            }

            const new_bindings = try self.arena.allocSlice(Node.Binding, surviving);
            var out: usize = 0;
            for (let_in.bindings, 0..) |entry, i| {
                if (!plan.keep[entry_group[i]]) continue;
                var copy = entry;
                copy.expr = @constCast(try self.rewrite(entry.expr));
                new_bindings[out] = copy;
                out += 1;
            }

            if (!self.changed and surviving == let_in.bindings.len) {
                if (cluster.levels == 1) break :blk cluster.head;
                // Merged spine with no other changes: compile the cached
                // flat node; its (identity) plan counts as applied.
                self.changed = true;
                try self.state.decided.put(self.state.allocator, base, {});
                break :blk base;
            }

            self.changed = true;
            const node = try self.arena.createNode(.let_in, .{ .let_in = .{
                .bindings = new_bindings,
                .body = @constCast(new_body),
            } });
            node.span = cluster.head.span;
            // The residual's plan is fully applied; compile it as-is.
            try self.state.decided.put(self.state.allocator, node, {});
            break :blk node;
        };

        self.changed = body_was or self.changed;
        overlay.rebuilt = result;
        overlay.rebuilt_batch = self.state.batch;
        return result;
    }

    /// Float-out wrap, AROUND position: `let <floated…> in <lambda>` in the
    /// lambda's parent expression context — the thunk is created once per
    /// closure creation and captured as an upvalue by the body. Marked
    /// `decided` (a re-plan would sink a single-use binding back inside).
    fn wrapLambdaOuter(self: *Rewriter, original: *const Node, lambda_node: *const Node) !*const Node {
        const floated = self.state.lambda_outer_wraps.get(original) orelse return lambda_node;
        self.changed = true;
        const bindings = try self.arena.allocSlice(Node.Binding, floated.items.len);
        for (floated.items, bindings) |entry, *out| {
            out.* = entry;
            out.expr = @constCast(try self.rewrite(entry.expr));
        }
        const node = try self.arena.createNode(.let_in, .{ .let_in = .{
            .bindings = bindings,
            .body = @constCast(lambda_node),
        } });
        node.span = original.span;
        try self.state.decided.put(self.state.allocator, node, {});
        return node;
    }

    /// Float-out wrap: `let <floated…> in <body>` at the top of a lambda
    /// body. Marked `decided` — the float IS this binding's final
    /// placement; a fresh re-plan of the wrap subtree would see a
    /// single-use binding and sink it straight back into the body,
    /// undoing the share.
    fn wrapLambdaBody(self: *Rewriter, dest: *const Node, body: *const Node) !*const Node {
        const floated = self.state.lambda_wraps.get(dest) orelse return body;
        self.changed = true;
        const bindings = try self.arena.allocSlice(Node.Binding, floated.items.len);
        for (floated.items, bindings) |entry, *out| {
            out.* = entry;
            out.expr = @constCast(try self.rewrite(entry.expr));
        }
        const node = try self.arena.createNode(.let_in, .{ .let_in = .{
            .bindings = bindings,
            .body = @constCast(body),
        } });
        node.span = body.span;
        try self.state.decided.put(self.state.allocator, node, {});
        return node;
    }

    /// `let <floated…> in <body>` around a branch expression. Binding
    /// entries reuse the original let's entries (name offsets intact), with
    /// their RHSes rewritten; the wrap compiles as an ordinary inner let, so
    /// classification, naming, and its own strict prefix all apply.
    fn wrapWithLet(self: *Rewriter, original: *const Node, body: *const Node, floated: []const Node.Binding) !*const Node {
        self.changed = true;
        const bindings = try self.arena.allocSlice(Node.Binding, floated.len);
        for (floated, bindings) |entry, *out| {
            out.* = entry;
            out.expr = @constCast(try self.rewrite(entry.expr));
        }
        const node = try self.arena.createNode(.let_in, .{ .let_in = .{
            .bindings = bindings,
            .body = @constCast(body),
        } });
        node.span = original.span;
        return node;
    }

    /// Rewrite `node`'s children; return `node` itself when nothing below
    /// changed, else a rebuilt copy (span recomputed by `createNode`).
    fn rewriteChildren(self: *Rewriter, node: *const Node) anyerror!*const Node {
        switch (node.tag) {
            .integer, .float_val, .string, .path, .uri, .search_path, .identifier, .elided => return node,
            .unary_op => {
                const expr = try self.rewrite(node.data.unary.expr);
                if (expr == node.data.unary.expr) return node;
                return self.make(node, .{ .unary = .{ .op = node.data.unary.op, .expr = @constCast(expr) } });
            },
            .binary_op => {
                const b = node.data.binary;
                const left = try self.rewrite(b.left);
                const right = try self.rewrite(b.right);
                if (left == b.left and right == b.right) return node;
                return self.make(node, .{ .binary = .{ .op = b.op, .left = @constCast(left), .right = @constCast(right) } });
            },
            .apply => {
                const a = node.data.apply;
                const func = try self.rewrite(a.func);
                const arg = try self.rewrite(a.arg);
                if (func == a.func and arg == a.arg) return node;
                return self.make(node, .{ .apply = .{ .func = @constCast(func), .arg = @constCast(arg), .pipe = a.pipe } });
            },
            .lambda => {
                const lam = node.data.lambda;
                var body = try self.rewrite(lam.body);
                body = try self.wrapLambdaBody(node, body);
                if (body == lam.body) return self.wrapLambdaOuter(node, node);
                const rebuilt = try self.make(node, .{ .lambda = .{
                    .param_offset = lam.param_offset,
                    .param_len = lam.param_len,
                    .body = @constCast(body),
                } });
                // Full-lazy: the rebuilt lambda subtree is fully analyzed
                // (fresh residuals inside are `decided`); mark it so the
                // pre-emission hook skips it in O(1).
                if (self.c.let_float.full_lazy)
                    try self.ua.walked.put(self.ua.allocator, rebuilt, {});
                return self.wrapLambdaOuter(node, rebuilt);
            },
            .lambda_attrs => {
                const la = node.data.lambda_attrs;
                var body = try self.rewrite(la.body);
                body = try self.wrapLambdaBody(node, body);
                var params_changed = false;
                const new_params = try self.arena.allocSlice(Node.LambdaAttrParam, la.params.len);
                for (la.params, new_params) |param, *out| {
                    out.* = param;
                    if (param.default) |d| {
                        const nd = try self.rewrite(d);
                        if (nd != d) {
                            out.default = @constCast(nd);
                            params_changed = true;
                        }
                    }
                }
                if (body == la.body and !params_changed) return self.wrapLambdaOuter(node, node);
                const boxed = try self.arena.allocator().create(Node.LambdaAttrs);
                boxed.* = .{
                    .bind_name = la.bind_name,
                    .params = new_params,
                    .allow_extra = la.allow_extra,
                    .body = @constCast(body),
                };
                const rebuilt = try self.make(node, .{ .lambda_attrs = boxed });
                if (self.c.let_float.full_lazy)
                    try self.ua.walked.put(self.ua.allocator, rebuilt, {});
                return self.wrapLambdaOuter(node, rebuilt);
            },
            .let_in => {
                // A registered cluster head applies its own plan (flatten,
                // keep, decided marking); covered non-head spine levels are
                // never reached (the head's rebuild consumes the spine).
                // Zero-binding lets keep their shell (as `rewriteLet` always
                // has) and traverse plainly.
                if (node.data.let_in.bindings.len != 0) {
                    if (self.ua.clusters.get(node)) |cluster| {
                        if (cluster.head == node) return self.rebuildClusterNode(cluster);
                    }
                }
                const li = node.data.let_in;
                const body = try self.rewrite(li.body);
                var bindings_changed = false;
                const new_bindings = try self.arena.allocSlice(Node.Binding, li.bindings.len);
                for (li.bindings, new_bindings) |binding, *out| {
                    out.* = binding;
                    const ne = try self.rewrite(binding.expr);
                    if (ne != binding.expr) {
                        out.expr = @constCast(ne);
                        bindings_changed = true;
                    }
                }
                if (body == li.body and !bindings_changed) return node;
                return self.make(node, .{ .let_in = .{
                    .bindings = new_bindings,
                    .body = @constCast(body),
                } });
            },
            .if_else => {
                const i = node.data.if_else;
                const cond = try self.rewrite(i.cond);
                const then_branch = try self.rewrite(i.then_branch);
                const else_branch = try self.rewrite(i.else_branch);
                if (cond == i.cond and then_branch == i.then_branch and else_branch == i.else_branch) return node;
                return self.make(node, .{ .if_else = .{
                    .cond = @constCast(cond),
                    .then_branch = @constCast(then_branch),
                    .else_branch = @constCast(else_branch),
                } });
            },
            .assert => {
                const a = node.data.assert;
                const cond = try self.rewrite(a.cond);
                const body = try self.rewrite(a.body);
                if (cond == a.cond and body == a.body) return node;
                return self.make(node, .{ .assert = .{ .cond = @constCast(cond), .body = @constCast(body) } });
            },
            .with_expr => {
                const w = node.data.with_expr;
                const attr_set = try self.rewrite(w.attr_set);
                const body = try self.rewrite(w.body);
                if (attr_set == w.attr_set and body == w.body) return node;
                return self.make(node, .{ .with_expr = .{ .attr_set = @constCast(attr_set), .body = @constCast(body) } });
            },
            .attr_set => {
                const set = node.data.attr_set;
                var entries_changed = false;
                const new_entries = try self.arena.allocSlice(Node.AttrSetEntry, set.entries.len);
                for (set.entries, new_entries) |entry, *out| {
                    out.* = entry;
                    const ne = try self.rewrite(entry.expr);
                    if (ne != entry.expr) {
                        out.expr = @constCast(ne);
                        entries_changed = true;
                    }
                    if (entry.dynamic_name) |dn| {
                        const ndn = try self.rewrite(dn);
                        if (ndn != dn) {
                            out.dynamic_name = @constCast(ndn);
                            entries_changed = true;
                        }
                    }
                }
                if (!entries_changed) return node;
                return self.make(node, .{ .attr_set = .{ .entries = new_entries, .recursive = set.recursive } });
            },
            .attr_path => {
                const ap = node.data.attr_path;
                const root = try self.rewrite(ap.root);
                if (root == ap.root) return node;
                return self.make(node, .{ .attr_path = .{ .root = @constCast(root), .segments = ap.segments } });
            },
            .attr_dynamic => {
                const ad = node.data.attr_dynamic;
                const root = try self.rewrite(ad.root);
                const name = try self.rewrite(ad.name);
                if (root == ad.root and name == ad.name) return node;
                return self.make(node, .{ .attr_dynamic = .{ .root = @constCast(root), .name = @constCast(name) } });
            },
            .attr_or => {
                const ao = node.data.attr_or;
                const attr_path = try self.rewrite(ao.attr_path);
                const default = try self.rewrite(ao.default);
                if (attr_path == ao.attr_path and default == ao.default) return node;
                return self.make(node, .{ .attr_or = .{ .attr_path = @constCast(attr_path), .default = @constCast(default) } });
            },
            .has_attr => {
                const ha = node.data.has_attr;
                const root = try self.rewrite(ha.root);
                if (root == ha.root) return node;
                return self.make(node, .{ .has_attr = .{ .root = @constCast(root), .segments = ha.segments } });
            },
            .has_attr_mixed => {
                const ham = node.data.has_attr_mixed;
                const root = try self.rewrite(ham.root);
                var segments_changed = false;
                const new_segments = try self.arena.allocSlice(Node.HasAttrMixedSegment, ham.segments.len);
                for (ham.segments, new_segments) |seg, *out| {
                    out.* = seg;
                    switch (seg) {
                        .static => {},
                        .dynamic => |d| {
                            const nd = try self.rewrite(d);
                            if (nd != d) {
                                out.* = .{ .dynamic = @constCast(nd) };
                                segments_changed = true;
                            }
                        },
                    }
                }
                if (root == ham.root and !segments_changed) return node;
                return self.make(node, .{ .has_attr_mixed = .{ .root = @constCast(root), .segments = new_segments } });
            },
            .list => {
                const list = node.data.list;
                var items_changed = false;
                const new_items = try self.arena.allocSlice(*Node, list.items.len);
                for (list.items, new_items) |item, *out| {
                    const ni = try self.rewrite(item);
                    out.* = @constCast(ni);
                    if (ni != item) items_changed = true;
                }
                if (!items_changed) return node;
                return self.make(node, .{ .list = .{ .items = new_items } });
            },
            .parens => {
                const inner = try self.rewrite(node.data.parens);
                if (inner == node.data.parens) return node;
                return self.make(node, .{ .parens = @constCast(inner) });
            },
        }
    }

    fn make(self: *Rewriter, original: *const Node, data: Node.Data) !*const Node {
        self.changed = true;
        const node = try self.arena.createNode(original.tag, data);
        // Keep the original node's span: `createNode` recombines child spans,
        // but the surrounding source region is still the truest attribution
        // for diagnostics on the rebuilt node.
        node.span = original.span;
        return node;
    }
};
