//! Compile-time strictness analysis on the AST.
//!
//! For a chunk's body, compute two sets of upvalues that the chunk will
//! force when entered:
//!   - **shallow** — forced unconditionally as the body is reduced to WHNF.
//!   - **deep**    — additionally forced when the *result* of the body is
//!                   deep-forced by the caller. Captures the case where the
//!                   body builds an attr-set or list whose values reference
//!                   upvalues — those values get forced if the caller walks
//!                   the structure.
//!
//! Translated at chunk-finish into `ChunkStrictness.{forced_upvalues,
//! deep_upvalues}` and consumed by the scheduler to pre-submit known-
//! demanded thunks at the producer side instead of waiting for fan-out
//! at strict barriers.
//!
//! Semantic model. Two functions:
//!   `shallow(e)` — names forced reducing `e` to weak-head normal form.
//!   `deep(e)`    — names forced reducing `e` to deep-WHNF (recursively).
//! By construction `shallow(e) ⊆ deep(e)`.
//!
//! Rules of note:
//!   - identifier `x`: shallow = {x}, deep = {x}.
//!   - lambda value: shallow = deep = ∅ (closure values are atomic).
//!   - attr-set / list literal: shallow = ∅; deep = ⋃ deep(values).
//!     Building doesn't force; walking does.
//!   - arithmetic / comparison: shallow & deep both union over operands.
//!     Result is primitive, so deep == shallow at the chunk root.
//!   - `if c then t else f`: union of cond strictness with branch-wise
//!     intersection, computed independently for shallow and deep.
//!   - `let x = rhs in body`: substitute references to `x` in `body`'s
//!     sets with the corresponding set from `rhs`.
//!   - `apply f x`: shallow(f); cross-chunk on `x` is a later phase.
//!
//! The analysis runs after the body has been compiled, walking the body's
//! AST a second time. It does NOT recurse into nested `lambda` /
//! `lambda_attrs` bodies — those are separate chunks.

const std = @import("std");
const ast = @import("syntax").ast;
const types = @import("runtime").types;
const intern_mod = @import("runtime").intern;
const chunk_mod = @import("../bytecode.zig").chunk;
const prof = @import("../probe.zig").prof;
const diagnostics = @import("diagnostics.zig");

const Node = ast.Node;
const InternId = types.InternId;
const InternTable = intern_mod.InternTable;
const ChunkStrictness = chunk_mod.ChunkStrictness;

const NameSet = std.AutoHashMapUnmanaged(InternId, void);

const Strictness = struct {
    /// May-force shallow set: names forced on *some* path as the expr is
    /// reduced to WHNF. Superset of `shallow_must`.
    shallow: NameSet,
    /// May-force deep set (superset of `shallow`): additionally forced
    /// when the result is deep-forced. Always may-mode — no consumer needs
    /// a must-force deep variant.
    deep: NameSet,
    /// Must-force shallow set: names forced on *every* path before any
    /// other observable effect (sound under-approximation). Differs from
    /// `shallow` only at `assert` (body may be skipped) and `with` (scope
    /// forced lazily). By construction `shallow_must ⊆ shallow`. Both sets are
    /// computed in one walk for eager-submit and eager-elision.
    shallow_must: NameSet,

    fn empty() Strictness {
        return .{ .shallow = .empty, .deep = .empty, .shallow_must = .empty };
    }

    fn deinit(self: *Strictness, allocator: std.mem.Allocator) void {
        self.shallow.deinit(allocator);
        self.deep.deinit(allocator);
        self.shallow_must.deinit(allocator);
    }

    fn unionInto(self: *Strictness, allocator: std.mem.Allocator, other: *const Strictness) !void {
        var it = other.shallow.iterator();
        while (it.next()) |e| try self.shallow.put(allocator, e.key_ptr.*, {});
        var it2 = other.deep.iterator();
        while (it2.next()) |e| try self.deep.put(allocator, e.key_ptr.*, {});
        var it3 = other.shallow_must.iterator();
        while (it3.next()) |e| try self.shallow_must.put(allocator, e.key_ptr.*, {});
    }

    /// Union `other` in a *may-only* context: its may-force names count
    /// (they're reached on some path) but not its must-force names — used
    /// for the conditionally-run child of `assert` (body) and the lazily-
    /// forced child of `with` (scope), which must NOT contribute to our
    /// must-force set.
    fn unionMayOnly(self: *Strictness, allocator: std.mem.Allocator, other: *const Strictness) !void {
        var it = other.shallow.iterator();
        while (it.next()) |e| try self.shallow.put(allocator, e.key_ptr.*, {});
        var it2 = other.deep.iterator();
        while (it2.next()) |e| try self.deep.put(allocator, e.key_ptr.*, {});
    }

    /// Union `other`'s may-force names (shallow ∪ deep) into our deep
    /// set: `other` appears in a deep-only context, so nothing it forces
    /// counts until our result is walked. Must-force names are a subset
    /// of shallow, so they're covered.
    fn unionAllIntoDeep(self: *Strictness, allocator: std.mem.Allocator, other: *const Strictness) !void {
        var it = other.shallow.iterator();
        while (it.next()) |e| try self.deep.put(allocator, e.key_ptr.*, {});
        var it2 = other.deep.iterator();
        while (it2.next()) |e| try self.deep.put(allocator, e.key_ptr.*, {});
    }
};

const BoundFrame = struct {
    name: InternId,
    /// Strictness of this binding's RHS. When body references `name`,
    /// expand to this. `null` for lambda params where the RHS is the
    /// caller's arg (cross-chunk).
    rhs: ?Strictness,
};

const Analyzer = struct {
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    bound_stack: std.ArrayListUnmanaged(BoundFrame),
    /// Self-recursion fixpoint context — null/empty unless `strictParamsMask`
    /// is analyzing a named recursive function. `self_name` is its binding
    /// name; `self_params[i]` the name of param `i`; `self_strict` the current
    /// hypothesis of which params it forces. A saturated direct call to
    /// `self_name` then credits the argument in each hypothesized-strict
    /// position (see `trySelfCall`). Off (`self_name == null`) for every other
    /// caller, so their analysis is unchanged.
    self_name: ?InternId = null,
    self_params: []const InternId = &.{},
    self_strict: u8 = 0,

    fn deinit(self: *Analyzer) void {
        for (self.bound_stack.items) |*frame| {
            if (frame.rhs) |*r| r.deinit(self.allocator);
        }
        self.bound_stack.deinit(self.allocator);
    }

    fn findBound(self: *const Analyzer, name_id: InternId) ?usize {
        var i = self.bound_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.bound_stack.items[i].name == name_id) return i;
        }
        return null;
    }

    /// If `node` is a SATURATED direct call to the self-recursive function
    /// `self_name` — the flattened call head is that (unshadowed) free name and
    /// the argument count equals the arity — fold the callee plus each
    /// hypothesized-strict argument into `out` and return true. Otherwise
    /// return false so the caller applies the default "callee only" rule.
    /// Under-approximates by construction: an argument is analyzed only where
    /// `self_strict` marks that position, so nothing outside the (converging)
    /// hypothesis is credited.
    fn trySelfCall(self: *Analyzer, node: *const Node, self_name: InternId, out: *Strictness) !bool {
        // Flatten `f a0 a1 …` (right-nested `apply{apply{f, a0}, a1}`) into the
        // call head plus args; `args_rev[0]` is the outermost (last) argument.
        var args_rev: [types.max_uncurry_arity]*const Node = undefined;
        var n_args: usize = 0;
        var cur: *const Node = node;
        while (cur.tag == .apply) {
            if (n_args >= args_rev.len) return false; // over-applied → conservative
            args_rev[n_args] = cur.data.apply.arg;
            n_args += 1;
            cur = ast.unwrapParens(cur.data.apply.func);
        }
        if (cur.tag != .identifier) return false;
        const head_id = try self.identifierNameId(cur);
        if (head_id != self_name) return false;
        // A `let`/`with` binding shadowing the name makes this a different value.
        if (self.findBound(head_id) != null) return false;
        // Only a saturated call has a known argument for every param position.
        if (n_args != self.self_params.len) return false;

        // The callee is forced to WHNF to be applied — mirror the free-name rule.
        try out.shallow.put(self.allocator, head_id, {});
        try out.deep.put(self.allocator, head_id, {});
        try out.shallow_must.put(self.allocator, head_id, {});
        // Credit each argument the recursion forces. `args_rev[0]` is the last
        // arg, so its param index counts down from `n_args - 1`.
        var k: usize = 0;
        while (k < n_args) : (k += 1) {
            const param_index = n_args - 1 - k;
            if (self.self_strict & (@as(u8, 1) << @as(u3, @intCast(param_index))) != 0) {
                try self.analyzeInto(args_rev[k], out);
            }
        }
        return true;
    }

    fn identifierNameId(self: *Analyzer, node: *const Node) !InternId {
        const atom = node.data.atom;
        if (atom.len == 0) return @intCast(atom.offset); // synthetic (full-laziness)
        const name = self.source[atom.offset .. atom.offset + atom.len];
        return self.intern.intern(name);
    }

    fn bindingNameId(self: *Analyzer, binding: Node.Binding) !InternId {
        if (binding.name_len == 0) return @intCast(binding.name_offset); // synthetic
        const name = self.source[binding.name_offset .. binding.name_offset + binding.name_len];
        return self.intern.intern(name);
    }

    fn analyze(self: *Analyzer, node: *const Node) anyerror!Strictness {
        var out = Strictness.empty();
        errdefer out.deinit(self.allocator);
        try self.analyzeInto(node, &out);
        return out;
    }

    fn analyzeInto(self: *Analyzer, node: *const Node, out: *Strictness) anyerror!void {
        switch (node.tag) {
            // ---- atomic WHNF, leaves nothing demanded ----
            .integer,
            .float_val,
            .string,
            .path,
            .uri,
            .search_path,
            .lambda,
            .lambda_attrs,
            => {},

            // An elided (never-parsed) body is opaque: contribute nothing.
            // Sound in both directions its sets are used — must-force is an
            // under-approximation by definition, and the may-force sets only
            // drive speculative pre-submission (missing names just mean
            // fewer speculative forces).
            .elided => {},

            .identifier => {
                const name_id = try self.identifierNameId(node);
                if (self.findBound(name_id)) |idx| {
                    if (self.bound_stack.items[idx].rhs) |*rhs| {
                        try out.unionInto(self.allocator, rhs);
                    }
                } else {
                    // A free identifier is forced unconditionally on every
                    // path — it's in all three sets.
                    try out.shallow.put(self.allocator, name_id, {});
                    try out.deep.put(self.allocator, name_id, {});
                    try out.shallow_must.put(self.allocator, name_id, {});
                }
            },

            .attr_set => {
                // Building an attr-set forces nothing. Deep-forcing the
                // result forces each value's may-force names.
                for (node.data.attr_set.entries) |entry| {
                    try self.analyzeIntoDeepOnly(entry.expr, out);
                }
            },

            .list => {
                for (node.data.list.items) |item| {
                    try self.analyzeIntoDeepOnly(item, out);
                }
            },

            .unary_op => try self.analyzeInto(node.data.unary.expr, out),

            .binary_op => {
                const b = node.data.binary;
                switch (b.op) {
                    .add, .sub, .mul, .div, .eq, .neq, .lt, .lte, .gt, .gte, .update, .concat => {
                        try self.analyzeInto(b.left, out);
                        try self.analyzeInto(b.right, out);
                    },
                    .and_, .or_, .impl => {
                        try self.analyzeInto(b.left, out);
                    },
                }
            },

            .apply => {
                // A saturated direct call to the self-recursive function forces
                // its callee plus each hypothesized-strict argument (the
                // fixpoint seam — see `trySelfCall`). Every other application
                // forces only the callee; argument strictness across an
                // unknown callee is not modeled (sound: it stays lazy).
                if (self.self_name) |sname| {
                    if (try self.trySelfCall(node, sname, out)) return;
                }
                try self.analyzeInto(node.data.apply.func, out);
            },

            .let_in => {
                const let = node.data.let_in;
                const start_len = self.bound_stack.items.len;

                for (let.bindings) |binding| {
                    const name_id = try self.bindingNameId(binding);
                    try self.bound_stack.append(self.allocator, .{ .name = name_id, .rhs = null });
                }
                for (let.bindings, 0..) |binding, i| {
                    var rhs = try self.analyze(binding.expr);
                    errdefer rhs.deinit(self.allocator);
                    self.bound_stack.items[start_len + i].rhs = rhs;
                }

                try self.analyzeInto(let.body, out);

                while (self.bound_stack.items.len > start_len) {
                    var frame = self.bound_stack.pop().?;
                    if (frame.rhs) |*r| r.deinit(self.allocator);
                }
            },

            .if_else => {
                const i = node.data.if_else;
                try self.analyzeInto(i.cond, out);
                var then_s = try self.analyze(i.then_branch);
                defer then_s.deinit(self.allocator);
                var else_s = try self.analyze(i.else_branch);
                defer else_s.deinit(self.allocator);
                // A name is forced by the `if` only if BOTH branches force
                // it — intersect per-branch, independently for each set.
                var it = then_s.shallow.iterator();
                while (it.next()) |entry| {
                    if (else_s.shallow.contains(entry.key_ptr.*)) {
                        try out.shallow.put(self.allocator, entry.key_ptr.*, {});
                    }
                }
                var it_deep = then_s.deep.iterator();
                while (it_deep.next()) |entry| {
                    if (else_s.deep.contains(entry.key_ptr.*)) {
                        try out.deep.put(self.allocator, entry.key_ptr.*, {});
                    }
                }
                var it_must = then_s.shallow_must.iterator();
                while (it_must.next()) |entry| {
                    if (else_s.shallow_must.contains(entry.key_ptr.*)) {
                        try out.shallow_must.put(self.allocator, entry.key_ptr.*, {});
                    }
                }
            },

            .assert => {
                const a = node.data.assert;
                try self.analyzeInto(a.cond, out);
                // The body runs only if the assertion passes, so its names
                // are may-forced but NOT must-forced.
                var body_s = try self.analyze(a.body);
                defer body_s.deinit(self.allocator);
                try out.unionMayOnly(self.allocator, &body_s);
            },

            .with_expr => {
                const w = node.data.with_expr;
                // The scope expr is forced lazily (only when the body
                // resolves a name through it) → may-force only. The body
                // always runs → full contribution.
                var scope_s = try self.analyze(w.attr_set);
                defer scope_s.deinit(self.allocator);
                try out.unionMayOnly(self.allocator, &scope_s);
                try self.analyzeInto(w.body, out);
            },

            .attr_path => try self.analyzeInto(node.data.attr_path.root, out),

            .attr_dynamic => {
                try self.analyzeInto(node.data.attr_dynamic.root, out);
                try self.analyzeInto(node.data.attr_dynamic.name, out);
            },

            .attr_or => try self.analyzeAttrOrChain(node.data.attr_or.attr_path, out),

            .has_attr => try self.analyzeInto(node.data.has_attr.root, out),
            .has_attr_mixed => try self.analyzeInto(node.data.has_attr_mixed.root, out),

            .parens => try self.analyzeInto(node.data.parens, out),
        }
    }

    /// Analyze `node` in a deep-only context, writing every may-force
    /// name (shallow ∪ deep) straight into `out.deep`. Equivalent to
    /// `analyze(node)` + `unionAllIntoDeep`, without materializing the
    /// intermediate sets — attr-set / list literals dominate module
    /// files, so their element rule runs here on the direct path.
    /// (must-force never applies: deep names are only forced if the
    /// caller walks the result.)
    fn analyzeIntoDeepOnly(self: *Analyzer, node: *const Node, out: *Strictness) anyerror!void {
        switch (node.tag) {
            .integer,
            .float_val,
            .string,
            .path,
            .uri,
            .search_path,
            .lambda,
            .lambda_attrs,
            => {},

            // Opaque, contributes nothing (see `analyzeInto`).
            .elided => {},

            .identifier => {
                const name_id = try self.identifierNameId(node);
                if (self.findBound(name_id)) |idx| {
                    if (self.bound_stack.items[idx].rhs) |*rhs| {
                        try out.unionAllIntoDeep(self.allocator, rhs);
                    }
                } else {
                    try out.deep.put(self.allocator, name_id, {});
                }
            },

            .attr_set => {
                for (node.data.attr_set.entries) |entry| {
                    try self.analyzeIntoDeepOnly(entry.expr, out);
                }
            },

            .list => {
                for (node.data.list.items) |item| {
                    try self.analyzeIntoDeepOnly(item, out);
                }
            },

            .unary_op => try self.analyzeIntoDeepOnly(node.data.unary.expr, out),

            .binary_op => {
                const b = node.data.binary;
                switch (b.op) {
                    .add, .sub, .mul, .div, .eq, .neq, .lt, .lte, .gt, .gte, .update, .concat => {
                        try self.analyzeIntoDeepOnly(b.left, out);
                        try self.analyzeIntoDeepOnly(b.right, out);
                    },
                    .and_, .or_, .impl => {
                        try self.analyzeIntoDeepOnly(b.left, out);
                    },
                }
            },

            .apply => try self.analyzeIntoDeepOnly(node.data.apply.func, out),

            .let_in => {
                const let = node.data.let_in;
                const start_len = self.bound_stack.items.len;

                for (let.bindings) |binding| {
                    const name_id = try self.bindingNameId(binding);
                    try self.bound_stack.append(self.allocator, .{ .name = name_id, .rhs = null });
                }
                for (let.bindings, 0..) |binding, i| {
                    var rhs = try self.analyze(binding.expr);
                    errdefer rhs.deinit(self.allocator);
                    self.bound_stack.items[start_len + i].rhs = rhs;
                }

                try self.analyzeIntoDeepOnly(let.body, out);

                while (self.bound_stack.items.len > start_len) {
                    var frame = self.bound_stack.pop().?;
                    if (frame.rhs) |*r| r.deinit(self.allocator);
                }
            },

            .if_else => {
                const i = node.data.if_else;
                try self.analyzeIntoDeepOnly(i.cond, out);
                var then_s = try self.analyze(i.then_branch);
                defer then_s.deinit(self.allocator);
                var else_s = try self.analyze(i.else_branch);
                defer else_s.deinit(self.allocator);
                // Branch-wise intersection as in `analyzeInto`, but both
                // the shallow and deep intersections land in `deep`.
                var it = then_s.shallow.iterator();
                while (it.next()) |entry| {
                    if (else_s.shallow.contains(entry.key_ptr.*)) {
                        try out.deep.put(self.allocator, entry.key_ptr.*, {});
                    }
                }
                var it_deep = then_s.deep.iterator();
                while (it_deep.next()) |entry| {
                    if (else_s.deep.contains(entry.key_ptr.*)) {
                        try out.deep.put(self.allocator, entry.key_ptr.*, {});
                    }
                }
            },

            .assert => {
                const a = node.data.assert;
                try self.analyzeIntoDeepOnly(a.cond, out);
                try self.analyzeIntoDeepOnly(a.body, out);
            },

            .with_expr => {
                const w = node.data.with_expr;
                try self.analyzeIntoDeepOnly(w.attr_set, out);
                try self.analyzeIntoDeepOnly(w.body, out);
            },

            .attr_path => try self.analyzeIntoDeepOnly(node.data.attr_path.root, out),

            .attr_dynamic => {
                try self.analyzeIntoDeepOnly(node.data.attr_dynamic.root, out);
                try self.analyzeIntoDeepOnly(node.data.attr_dynamic.name, out);
            },

            .attr_or => try self.analyzeAttrOrChainDeepOnly(node.data.attr_or.attr_path, out),

            .has_attr => try self.analyzeIntoDeepOnly(node.data.has_attr.root, out),
            .has_attr_mixed => try self.analyzeIntoDeepOnly(node.data.has_attr_mixed.root, out),

            .parens => try self.analyzeIntoDeepOnly(node.data.parens, out),
        }
    }

    /// Deep-only counterpart of `analyzeAttrOrChain`.
    fn analyzeAttrOrChainDeepOnly(self: *Analyzer, node: *const Node, out: *Strictness) anyerror!void {
        switch (node.tag) {
            .attr_path => try self.analyzeIntoDeepOnly(node.data.attr_path.root, out),
            .attr_dynamic => try self.analyzeAttrOrChainDeepOnly(node.data.attr_dynamic.root, out),
            .has_attr => try self.analyzeIntoDeepOnly(node.data.has_attr.root, out),
            .has_attr_mixed => try self.analyzeIntoDeepOnly(node.data.has_attr_mixed.root, out),
            .parens => try self.analyzeAttrOrChainDeepOnly(node.data.parens, out),
            else => try self.analyzeIntoDeepOnly(node, out),
        }
    }

    /// Walk an `attr_or`'s lookup chain conservatively: only the
    /// chain's base expression is unconditionally evaluated. Each
    /// segment (static or dynamic) may short-circuit if a preceding
    /// lookup fails — so we must NOT mark dynamic-segment names as
    /// strict, since `attr.${k} or d` will skip evaluating `k` when
    /// an earlier segment in the chain misses.
    fn analyzeAttrOrChain(self: *Analyzer, node: *const Node, out: *Strictness) anyerror!void {
        switch (node.tag) {
            .attr_path => try self.analyzeInto(node.data.attr_path.root, out),
            .attr_dynamic => try self.analyzeAttrOrChain(node.data.attr_dynamic.root, out),
            .has_attr => try self.analyzeInto(node.data.has_attr.root, out),
            .has_attr_mixed => try self.analyzeInto(node.data.has_attr_mixed.root, out),
            .parens => try self.analyzeAttrOrChain(node.data.parens, out),
            else => try self.analyzeInto(node, out),
        }
    }
};

pub const StrictnessResult = struct {
    strict: Strictness,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StrictnessResult) void {
        self.strict.deinit(self.allocator);
    }
};

pub fn analyzeChunkBody(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    body: *const Node,
    params: []const InternId,
) !StrictnessResult {
    var an: Analyzer = .{
        .allocator = allocator,
        .intern = intern,
        .source = source,
        .bound_stack = .empty,
    };
    defer an.deinit();

    for (params) |p| {
        try an.bound_stack.append(allocator, .{ .name = p, .rhs = null });
    }

    var strict = try an.analyze(body);
    for (params) |p| {
        _ = strict.shallow.remove(p);
        _ = strict.deep.remove(p);
        _ = strict.shallow_must.remove(p);
    }

    return .{ .strict = strict, .allocator = allocator };
}

/// For each binding name, decide in ONE walk of the let body:
///   - `out_eager[i]`       — the body *may* force it (shallow may-force
///                            set). Drives strictness-informed container
///                            submit hint: helpers race the binding ahead
///                            of demand instead of waiting for the
///                            chunk-size speculation heuristic.
///   - `out_must_force[i]`  — the body forces it on *every* path before any
///                            observable effect (sound must-force set).
///                            Drives eager elision: such a binding is
///                            evaluated straight into its slot with no
///                            thunk, safe because lazy eval would force it
///                            anyway (can't turn a success into an error,
///                            only reorder which error surfaces).
///
/// The may-force and must-force sets share one traversal; they differ only at
/// `assert` and `with`. Analyzes
/// `body` with an empty bound_stack so binding names appear as free
/// identifiers; inner scopes (nested lets, lambdas) correctly shadow via
/// the analyzer's bound_stack management.
pub fn analyzeLetBindings(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    body: *const Node,
    binding_names: []const InternId,
    out_eager: []bool,
    out_must_force: []bool,
) !void {
    std.debug.assert(binding_names.len == out_eager.len);
    std.debug.assert(binding_names.len == out_must_force.len);
    var an: Analyzer = .{
        .allocator = allocator,
        .intern = intern,
        .source = source,
        .bound_stack = .empty,
    };
    defer an.deinit();

    var strict = try an.analyze(body);
    defer strict.deinit(allocator);

    for (binding_names, out_eager, out_must_force) |name, *eager, *mf| {
        eager.* = strict.shallow.contains(name);
        mf.* = strict.shallow_must.contains(name);
    }
}

/// Does `body` unconditionally force the free name `name_id` to WHNF on
/// every path (sound must-force)? `body` is analyzed with an empty bound
/// stack so `name_id` reads as a free identifier; nested scopes that
/// rebind the name correctly shadow it. Used to decide whether a
/// directly-applied lambda `(x: body) arg` forces its parameter, so the
/// caller may evaluate `arg` eagerly instead of thunking it.
pub fn bodyMustForceName(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    body: *const Node,
    name_id: InternId,
) !bool {
    var an: Analyzer = .{
        .allocator = allocator,
        .intern = intern,
        .source = source,
        .bound_stack = .empty,
    };
    defer an.deinit();
    var strict = try an.analyze(body);
    defer strict.deinit(allocator);
    return strict.shallow_must.contains(name_id);
}

/// Must-force parameter bitmask (bit i = param i) for a function body — the
/// `strict_params` the saturated-call path evaluates eagerly instead of
/// thunking. When `self_name` is the function's own recursive binding name, a
/// bounded greatest fixpoint additionally credits arguments passed in a
/// hypothesized-strict position of a saturated direct self-call, so a
/// tail-recursive accumulator (`go = acc: i: … go (acc + …) (i - 1)`) is proven
/// strict in its accumulator and passed eagerly — no lazy `+`-thunk chain, so
/// it evaluates in constant space instead of building an O(depth) chain that a
/// later force must walk.
///
/// Sound (Mycroft greatest fixpoint): the hypothesis starts with every param
/// assumed strict and shrinks monotonically to a fixpoint (≤ `arity` steps) — a
/// param survives only where the converged hypothesis shows the body forces it
/// on every path (the `if`-intersection rule still gates each branch). A
/// non-saturated / shadowed / non-self call credits nothing extra. With no
/// `self_name` (or when a parameter shadows it), this reduces to per-parameter
/// must-force analysis.
pub fn strictParamsMask(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    body: *const Node,
    param_ids: []const InternId,
    self_name: ?InternId,
) !u8 {
    std.debug.assert(param_ids.len <= 8);
    // A param that shadows the self name rebinds it inside the body, so a
    // reference there is the parameter, not the recursion — drop self-detection.
    var sname = self_name;
    if (sname) |s| {
        for (param_ids) |p| {
            if (p == s) {
                sname = null;
                break;
            }
        }
    }

    const all: u8 = if (param_ids.len >= 8) 0xFF else (@as(u8, 1) << @as(u3, @intCast(param_ids.len))) - 1;
    var hyp: u8 = all;
    var guard: usize = 0;
    while (true) : (guard += 1) {
        var an: Analyzer = .{
            .allocator = allocator,
            .intern = intern,
            .source = source,
            .bound_stack = .empty,
            .self_name = sname,
            .self_params = param_ids,
            .self_strict = hyp,
        };
        defer an.deinit();
        var strict = try an.analyze(body);
        defer strict.deinit(allocator);

        var mask: u8 = 0;
        for (param_ids, 0..) |p, i| {
            if (strict.shallow_must.contains(p)) mask |= @as(u8, 1) << @as(u3, @intCast(i));
        }
        // No self name → the hypothesis is irrelevant, one pass is the answer.
        // Otherwise iterate to the fixpoint (monotone decreasing, so `guard`
        // only backstops the ≤ arity convergence).
        if (sname == null or mask == hyp or guard >= param_ids.len) return mask;
        hyp = mask;
    }
}

const Compiler = @import("context.zig").Compiler;

pub fn stampOnBuilder(c: *Compiler, body: *const Node) !void {
    const _pt = prof.start(.strictness);
    defer prof.end(.strictness, _pt);

    // Record the chunk's body span as a representative source location (the
    // source map is sparse — see Chunk.body_span). Best-effort; never fails the
    // compile. Done before the no-capture early return so all chunks get it.
    c.builder.body_span = diagnostics.sourceSpanForNode(c, body) catch null;

    // The strictness signature is purely an upvalue (capture) mask:
    // `nameSetToMask` only sets bits for names that match a capture slot.
    // A chunk with no captures therefore has an all-zero signature — the
    // ChunkStrictness default — so the entire `analyzeChunkBody` AST walk
    // is wasted work. Skip it. Byte-identical by construction.
    if (c.captures.items.len == 0) {
        c.builder.strictness = .{};
        return;
    }

    var params: std.ArrayListUnmanaged(InternId) = .empty;
    defer params.deinit(c.allocator);
    try params.ensureTotalCapacity(c.allocator, c.locals.items.len);
    for (c.locals.items) |local| params.appendAssumeCapacity(local.name_id);

    var result = try analyzeChunkBody(c.allocator, c.intern, c.source, body, params.items);
    defer result.deinit();

    var capture_ids: std.ArrayListUnmanaged(InternId) = .empty;
    defer capture_ids.deinit(c.allocator);
    try capture_ids.ensureTotalCapacity(c.allocator, c.captures.items.len);
    for (c.captures.items) |capture| {
        const id = c.intern.intern(capture.name) catch continue;
        capture_ids.appendAssumeCapacity(id);
    }

    const shallow_mask = nameSetToMask(&result.strict.shallow, capture_ids.items);
    const deep_mask = nameSetToMask(&result.strict.deep, capture_ids.items);

    c.builder.strictness = .{
        .forced_upvalues = shallow_mask,
        .deep_upvalues = deep_mask,
    };
}

fn nameSetToMask(names: *const NameSet, capture_ids: []const InternId) u64 {
    var mask: u64 = 0;
    var it = names.iterator();
    while (it.next()) |entry| {
        const name_id = entry.key_ptr.*;
        for (capture_ids, 0..) |cid, slot| {
            if (cid == name_id) {
                if (slot < 64) mask |= @as(u64, 1) << @as(u6, @intCast(slot));
                break;
            }
        }
    }
    return mask;
}

const parser_mod = @import("syntax").parser;
const AstArena = ast.AstArena;
const Parser = parser_mod.Parser;

/// Parse `source` (expected to be a top-level `let ... in ...`) and hand
/// back its bindings + body along with the owning arena/intern table. The
/// caller analyzes `body` directly, mirroring how `compileLetIn` drives
/// `analyzeLetEagerness` / `analyzeLetMustForce`.
const ParsedLet = struct {
    arena: AstArena,
    intern: InternTable,
    node: *const Node,

    fn deinit(self: *ParsedLet) void {
        self.intern.deinit();
        self.arena.deinit();
    }

    fn bindings(self: *const ParsedLet) []const Node.Binding {
        return self.node.data.let_in.bindings;
    }

    fn body(self: *const ParsedLet) *const Node {
        return self.node.data.let_in.body;
    }
};

fn parseLet(allocator: std.mem.Allocator, source: []const u8) !ParsedLet {
    var arena = AstArena.init(allocator);
    errdefer arena.deinit();
    var parser = Parser.init(allocator, &arena, source);
    defer parser.deinit();
    const node = try parser.parse();
    if (node.tag != .let_in) return error.NotALet;
    var intern = try InternTable.init(allocator);
    errdefer intern.deinit();
    return .{ .arena = arena, .intern = intern, .node = node };
}

fn bindingNameIds(allocator: std.mem.Allocator, intern: *InternTable, source: []const u8, bindings: []const Node.Binding) ![]InternId {
    const ids = try allocator.alloc(InternId, bindings.len);
    errdefer allocator.free(ids);
    for (bindings, ids) |binding, *id| {
        if (binding.name_len == 0) { // synthetic (full-laziness)
            id.* = @intCast(binding.name_offset);
            continue;
        }
        const name = source[binding.name_offset .. binding.name_offset + binding.name_len];
        id.* = try intern.intern(name);
    }
    return ids;
}

test "analyzeLetEagerness flags a binding the body forces directly" {
    const allocator = std.testing.allocator;
    const source = "let a = 1 + 2; b = 3; in a + 0";
    var parsed = try parseLet(allocator, source);
    defer parsed.deinit();

    const names = try bindingNameIds(allocator, &parsed.intern, source, parsed.bindings());
    defer allocator.free(names);

    const eager = try allocator.alloc(bool, names.len);
    defer allocator.free(eager);
    const mf_unused = try allocator.alloc(bool, names.len);
    defer allocator.free(mf_unused);
    try analyzeLetBindings(allocator, &parsed.intern, source, parsed.body(), names, eager, mf_unused);

    // Body is `a + 0`: forces `a` shallowly, never mentions `b`.
    try std.testing.expect(eager[0]);
    try std.testing.expect(!eager[1]);
}

test "analyzeLetEagerness does not flag names only referenced in binding right-hand-sides" {
    const allocator = std.testing.allocator;
    // `b`'s RHS references `a`, but the body only uses `b` — per the
    // documented semantics, analyzeLetEagerness only looks at the BODY,
    // so `a` must NOT be flagged even though it's forced transitively.
    const source = "let a = 1; b = a + 1; in b";
    var parsed = try parseLet(allocator, source);
    defer parsed.deinit();

    const names = try bindingNameIds(allocator, &parsed.intern, source, parsed.bindings());
    defer allocator.free(names);

    const eager = try allocator.alloc(bool, names.len);
    defer allocator.free(eager);
    const mf_unused = try allocator.alloc(bool, names.len);
    defer allocator.free(mf_unused);
    try analyzeLetBindings(allocator, &parsed.intern, source, parsed.body(), names, eager, mf_unused);

    try std.testing.expect(!eager[0]); // a: not a free name in the body
    try std.testing.expect(eager[1]); // b: forced directly by the body
}

test "analyzeLetEagerness treats attrset/list construction as non-forcing (deep only)" {
    const allocator = std.testing.allocator;
    // Building `{ x = a; }` doesn't force `a` to WHNF; only walking the
    // result would. So the body's *shallow* set (what eagerness reads)
    // must not contain `a`.
    const source = "let a = 1; in { x = a; }";
    var parsed = try parseLet(allocator, source);
    defer parsed.deinit();

    const names = try bindingNameIds(allocator, &parsed.intern, source, parsed.bindings());
    defer allocator.free(names);

    const eager = try allocator.alloc(bool, names.len);
    defer allocator.free(eager);
    const mf_unused = try allocator.alloc(bool, names.len);
    defer allocator.free(mf_unused);
    try analyzeLetBindings(allocator, &parsed.intern, source, parsed.body(), names, eager, mf_unused);

    try std.testing.expect(!eager[0]);
}

test "analyzeLetEagerness unions if-branch strictness only over names common to both branches" {
    const allocator = std.testing.allocator;
    // `a` is forced on the then-branch (as the condition) but `b` only
    // appears on the else-branch — the if-rule intersects per-branch
    // strictness, so neither should show up as unconditionally forced.
    const source = "let a = true; b = 1; in if a then a else b";
    var parsed = try parseLet(allocator, source);
    defer parsed.deinit();

    const names = try bindingNameIds(allocator, &parsed.intern, source, parsed.bindings());
    defer allocator.free(names);

    const eager = try allocator.alloc(bool, names.len);
    defer allocator.free(eager);
    const mf_unused = try allocator.alloc(bool, names.len);
    defer allocator.free(mf_unused);
    try analyzeLetBindings(allocator, &parsed.intern, source, parsed.body(), names, eager, mf_unused);

    // `a` is forced unconditionally as the `if` condition regardless of
    // branch outcome.
    try std.testing.expect(eager[0]);
    // `b` only appears in the else branch, not the then branch.
    try std.testing.expect(!eager[1]);
}

test "analyzeLetMustForce excludes names only forced inside an assert body" {
    const allocator = std.testing.allocator;
    // Under must-force semantics, the assert's body only runs if the
    // condition holds, so forcing `a` there isn't sound to promise.
    const source = "let a = 1; in assert true; a";
    var parsed = try parseLet(allocator, source);
    defer parsed.deinit();

    const names = try bindingNameIds(allocator, &parsed.intern, source, parsed.bindings());
    defer allocator.free(names);

    const eager_unused = try allocator.alloc(bool, names.len);
    defer allocator.free(eager_unused);
    const must_force = try allocator.alloc(bool, names.len);
    defer allocator.free(must_force);
    try analyzeLetBindings(allocator, &parsed.intern, source, parsed.body(), names, eager_unused, must_force);

    try std.testing.expect(!must_force[0]);
}

test "analyzeLetMustForce excludes names only forced inside a with scope expression" {
    const allocator = std.testing.allocator;
    // The `with` scope expr (`a`) is only forced lazily, on demand from
    // the body resolving a name through it — not unconditionally.
    const source = "let a = {}; in with a; 1";
    var parsed = try parseLet(allocator, source);
    defer parsed.deinit();

    const names = try bindingNameIds(allocator, &parsed.intern, source, parsed.bindings());
    defer allocator.free(names);

    const eager_unused = try allocator.alloc(bool, names.len);
    defer allocator.free(eager_unused);
    const must_force = try allocator.alloc(bool, names.len);
    defer allocator.free(must_force);
    try analyzeLetBindings(allocator, &parsed.intern, source, parsed.body(), names, eager_unused, must_force);

    try std.testing.expect(!must_force[0]);
}

test "analyzeLetMustForce flags a name forced on every path of an if-else" {
    const allocator = std.testing.allocator;
    const source = "let a = true; in if a then 1 else 2";
    var parsed = try parseLet(allocator, source);
    defer parsed.deinit();

    const names = try bindingNameIds(allocator, &parsed.intern, source, parsed.bindings());
    defer allocator.free(names);

    const eager_unused = try allocator.alloc(bool, names.len);
    defer allocator.free(eager_unused);
    const must_force = try allocator.alloc(bool, names.len);
    defer allocator.free(must_force);
    try analyzeLetBindings(allocator, &parsed.intern, source, parsed.body(), names, eager_unused, must_force);

    try std.testing.expect(must_force[0]);
}

test "bodyMustForceName detects a name unconditionally forced by arithmetic" {
    const allocator = std.testing.allocator;
    var arena = AstArena.init(allocator);
    defer arena.deinit();
    const source = "x + 1";
    var parser = Parser.init(allocator, &arena, source);
    defer parser.deinit();
    const body = try parser.parse();

    var intern = try InternTable.init(allocator);
    defer intern.deinit();
    const x_id = try intern.intern("x");

    const forces = try bodyMustForceName(allocator, &intern, source, body, x_id);
    try std.testing.expect(forces);
}

test "bodyMustForceName is false when the name is shadowed by a nested lambda" {
    const allocator = std.testing.allocator;
    var arena = AstArena.init(allocator);
    defer arena.deinit();
    // The outer `x` is never referenced in the body at all — the only
    // `x` in scope inside the lambda is its own parameter.
    const source = "(x: x + 1) 5";
    var parser = Parser.init(allocator, &arena, source);
    defer parser.deinit();
    const body = try parser.parse();

    var intern = try InternTable.init(allocator);
    defer intern.deinit();
    const x_id = try intern.intern("x");

    const forces = try bodyMustForceName(allocator, &intern, source, body, x_id);
    try std.testing.expect(!forces);
}

test "strictParamsMask: self-recursion proves a let accumulator strict" {
    const allocator = std.testing.allocator;
    const source = "let go = acc: i: if i == 0 then acc else go (acc + i) (i - 1); in go";
    var parsed = try parseLet(allocator, source);
    defer parsed.deinit();

    // `go`'s RHS is `acc: (i: BODY)`; unwrap both value lambdas to the body.
    const lam_acc = parsed.bindings()[0].expr;
    const lam_i = ast.unwrapParens(lam_acc.data.lambda.body);
    const body = ast.unwrapParens(lam_i.data.lambda.body);

    const acc = try parsed.intern.intern("acc");
    const i = try parsed.intern.intern("i");
    const go = try parsed.intern.intern("go");
    const params = [_]InternId{ acc, i };

    // Without a self name the recursive call's arguments are not credited, so
    // only `i`, the `if` condition, is must-forced.
    const base = try strictParamsMask(allocator, &parsed.intern, source, body, &params, null);
    try std.testing.expectEqual(@as(u8, 0b10), base);

    // With the self name, the greatest fixpoint additionally proves `acc`
    // strict (the recursive call forces `acc + i`, hence `acc`).
    const rec = try strictParamsMask(allocator, &parsed.intern, source, body, &params, go);
    try std.testing.expectEqual(@as(u8, 0b11), rec);
}

test "strictParamsMask: a constant base case keeps the accumulator lazy" {
    const allocator = std.testing.allocator;
    // The `then` branch returns 0 (not `acc`), so `acc` is forced only on the
    // else path — not unconditionally — even with the self-recursion fixpoint.
    const source = "let go = acc: i: if i == 0 then 0 else go (acc + i) (i - 1); in go";
    var parsed = try parseLet(allocator, source);
    defer parsed.deinit();

    const lam_acc = parsed.bindings()[0].expr;
    const lam_i = ast.unwrapParens(lam_acc.data.lambda.body);
    const body = ast.unwrapParens(lam_i.data.lambda.body);

    const acc = try parsed.intern.intern("acc");
    const i = try parsed.intern.intern("i");
    const go = try parsed.intern.intern("go");
    const params = [_]InternId{ acc, i };

    const mask = try strictParamsMask(allocator, &parsed.intern, source, body, &params, go);
    try std.testing.expectEqual(@as(u8, 0b10), mask); // `i` only; `acc` stays lazy
}
