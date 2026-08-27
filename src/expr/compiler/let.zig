//! Lowers `let … in`: runs the demand-driven placement rewrite
//! (`let_float.zig`) first, then classifies each residual binding root
//! (unreferenced/literal/uncaptured/needs_cell) to skip binding cells and
//! dead bindings, and finally drives strict-prefix eager elision — the
//! bindings the body provably forces first (`demand_prefix.analyze`) are
//! evaluated straight into their slots in demand order, with no thunks.

const std = @import("std");
const compiler_mod = @import("context.zig");
const ast = @import("syntax").ast;
const types = @import("runtime").types;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const diagnostics = @import("diagnostics.zig");
const attrs = @import("attrs.zig");
const attr_names = @import("attr_names.zig");
const access = @import("access.zig");
const strictness = @import("strictness.zig");
const demand_prefix = @import("demand_prefix.zig");
const refs_mod = @import("refs.zig");
const lambda = @import("lambda.zig");
const thunks = @import("thunks.zig");
const let_float = @import("let_float.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const AttrEntryView = compiler_mod.AttrEntryView;
const InternId = types.InternId;

pub fn compileLetIn(self: *Compiler, node: *const Node) !void {
    try compileLetInBody(self, node, false);
}

pub fn compileLetInWithTailBody(self: *Compiler, node: *const Node) anyerror!void {
    try compileLetInBody(self, node, true);
}

/// One "binding q's RHS mentions binding m" edge, by binding index (the
/// group's first index for merged roots). Drives strict-prefix validation:
/// a prefix member may only be referenced by LATER prefix members, whose
/// pass-3 evaluations read its already-filled slot.
const RhsEdge = struct { from: u32, to: u32 };

const no_single_leaf = std.math.maxInt(u32);

const LetClassification = struct {
    kinds: []LetBindingKind,
    rhs_edges: []RhsEdge,
    groups: BindingGroups,

    fn deinit(self: *LetClassification, allocator: std.mem.Allocator) void {
        allocator.free(self.kinds);
        allocator.free(self.rhs_edges);
        self.groups.deinit(allocator);
    }
};

/// Bindings grouped by root name, built once per let in `classifyLetBindings`
/// so no later pass rescans the whole binding list per root (quadratic on the
/// thousands-of-bindings lets that full-laziness floats synthesize).
const BindingGroups = struct {
    /// Binding index → group (unique root name, first-occurrence order).
    slot_of: []u32,
    /// Group → earliest binding index with that root.
    slot_first: []u32,
    /// Group → its sole `path.len == 1`, non-`inherit_outer` binding index
    /// when the group is exactly that one leaf; `no_single_leaf` otherwise.
    single_leaf: []u32,
    /// Group → member binding indices in source order:
    /// `items[offsets[slot]..offsets[slot + 1]]`.
    offsets: []u32,
    items: []u32,

    fn deinit(self: *BindingGroups, allocator: std.mem.Allocator) void {
        allocator.free(self.slot_of);
        allocator.free(self.slot_first);
        allocator.free(self.single_leaf);
        allocator.free(self.offsets);
        allocator.free(self.items);
    }

    /// True when `index` is the first binding of its root-name group.
    fn firstAt(self: *const BindingGroups, index: usize) bool {
        return self.slot_first[self.slot_of[index]] == index;
    }

    fn members(self: *const BindingGroups, index: usize) []const u32 {
        const slot = self.slot_of[index];
        return self.items[self.offsets[slot]..self.offsets[slot + 1]];
    }

    /// The group's single plain leaf (see `single_leaf`), by any member index.
    fn singleLeaf(self: *const BindingGroups, bindings: []const Node.Binding, index: usize) ?Node.Binding {
        const leaf = self.single_leaf[self.slot_of[index]];
        return if (leaf == no_single_leaf) null else bindings[leaf];
    }
};

fn compileLetInBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
    // Demand-driven binding placement first (see `let_float.zig`): dead
    // chains drop, duplicable aliases/literals inline, and single-use
    // bindings sink to their consumers. What remains is the residual let
    // this function classifies and emits. May return a non-let when every
    // binding dissolved into the body.
    const target = try let_float.rewriteLet(self, node);
    if (target.tag != .let_in) {
        if (tail_body) return lambda.compileTailExpression(self, target);
        return self.compileNode(target);
    }
    const let_in = target.data.let_in;

    try scope.beginScope(self);

    var plan = try LetPlan.init(self, let_in.bindings, let_in.body);
    defer plan.deinit(self.allocator);
    try declareBindingSlots(self, let_in.bindings, plan);

    // Hidden locals for `inherit (expr)` sources. They are declared after all
    // user bindings (so they cannot affect lexical resolution) and initialized
    // lazily at the first live member's source position in pass 2.
    var inherit_states: std.AutoHashMapUnmanaged(u32, InheritState) = .empty;
    defer inherit_states.deinit(self.allocator);
    try declareInheritSlots(self, let_in.bindings, plan.kinds, &inherit_states);
    try emitBindingInitializers(self, let_in.bindings, plan, &inherit_states);

    if (tail_body) {
        try lambda.compileTailExpression(self, let_in.body);
    } else {
        try self.compileNode(let_in.body);
    }

    scope.endScope(self);
}

const LetBindingKind = enum { unreferenced, literal, uncaptured, needs_cell };
const InheritState = struct { slot: u16, initialized: bool = false };

/// Immutable analysis result consumed by the two bytecode-emission passes.
/// All arrays are region-local to one `let`.
const LetPlan = struct {
    kinds: []LetBindingKind,
    name_ids: []InternId,
    eager: []bool,
    groups: BindingGroups,
    /// Binding indices PROVABLY forced first (in order) when the body runs —
    /// see `demand_prefix.analyze`. Emitted as direct evaluations into
    /// their slots (no thunk), after every sibling thunk exists, so forward
    /// references hold and eager order equals lazy order exactly.
    strict_prefix: []u32,
    /// Membership mask over `strict_prefix` (indexed by binding index):
    /// pass 2 skips these initializers; pass 3 evaluates them in order.
    in_prefix: []bool,

    fn init(self: *Compiler, bindings: []const Node.Binding, body: *const Node) !LetPlan {
        const classification = try classifyLetBindings(self, bindings, body);
        defer self.allocator.free(classification.rhs_edges);
        const kinds = classification.kinds;
        errdefer self.allocator.free(kinds);
        var groups = classification.groups;
        errdefer groups.deinit(self.allocator);

        const name_ids = try self.allocator.alloc(InternId, bindings.len);
        errdefer self.allocator.free(name_ids);
        for (bindings, name_ids) |binding, *name_id| {
            name_id.* = try self.intern.intern(attr_names.span(self, binding.path[0]));
        }

        const eager = try self.allocator.alloc(bool, bindings.len);
        errdefer self.allocator.free(eager);
        const must_force = try self.allocator.alloc(bool, bindings.len);
        defer self.allocator.free(must_force);
        try strictness.analyzeLetBindings(
            self.allocator,
            self.intern,
            self.source,
            body,
            name_ids,
            eager,
            must_force,
        );

        // Strict-prefix eligibility per binding: a single plain leaf of a
        // computational (non-structural) shape, non-recursive and cell-free.
        // Cell-backed bindings are excluded: an earlier sibling captured the
        // cell as a lazy handle, and eager evaluation would leave no thunk
        // in it for that capture to force.
        const prefix_bindings = try self.allocator.alloc(demand_prefix.Binding, bindings.len);
        defer self.allocator.free(prefix_bindings);
        for (bindings, kinds, name_ids, prefix_bindings, 0..) |binding, kind, name_id, *pb, index| {
            const leaf: ?Node.Binding = if (kind != .unreferenced and binding.inherit_group == 0)
                groups.singleLeaf(bindings, index)
            else
                null;
            const eligible = leaf != null and kind == .uncaptured and isEagerEvalShape(leaf.?.expr);
            pb.* = .{
                .name_id = name_id,
                .rhs = if (eligible) leaf.?.expr else null,
                .eligible = eligible,
                // A value-lambda leaf lets the prefix continue THROUGH a
                // saturated call to this binding (see `demand_prefix`): the
                // binding itself stays a lazy pre-resolved closure shell
                // (filled in pass 2, effect-free to force), and the body's
                // demand order extends the chain. Any kind of leaf binding
                // qualifies — even cell-backed self-recursive functions.
                .lambda = if (leaf != null)
                    try demand_prefix.lambdaShape(self.allocator, self.intern, self.source, leaf.?.expr)
                else
                    null,
            };
        }
        var prefix: std.ArrayListUnmanaged(u32) = .empty;
        errdefer prefix.deinit(self.allocator);
        try demand_prefix.analyze(self.allocator, self.intern, self.source, body, prefix_bindings, &prefix);

        const in_prefix = try self.allocator.alloc(bool, bindings.len);
        errdefer self.allocator.free(in_prefix);
        @memset(in_prefix, false);
        for (prefix.items) |i| in_prefix[i] = true;
        let_float.bumpPrefixMembers(self.let_float.stats, prefix.items.len);

        // Validate the prefix against sibling references: a member may only
        // be referenced by LATER members (their pass-3 evaluations read its
        // filled slot). A reference from a lazy sibling (its pass-2 thunk
        // would capture the unset slot) or from an EARLIER member (its eager
        // evaluation would read the unset slot — the transitive version of
        // this is how the old single-binding elision could force an unset
        // cell) demotes the member back to a lazy thunk, which is always
        // sound: the remaining members' demand-order justifications don't
        // depend on HOW a preceding binding gets forced, only that it is.
        // Demotions cascade (a demoted member is itself a lazy referencer).
        var pos = try self.allocator.alloc(u32, bindings.len);
        defer self.allocator.free(pos);
        var changed = true;
        while (changed) {
            changed = false;
            @memset(pos, std.math.maxInt(u32));
            for (prefix.items, 0..) |bi, k| pos[bi] = @intCast(k);
            for (classification.rhs_edges) |edge| {
                if (!in_prefix[edge.to]) continue;
                if (kinds[edge.from] == .unreferenced) continue; // dead RHS never compiles
                const from_lazy = !in_prefix[edge.from];
                if (from_lazy or pos[edge.from] < pos[edge.to]) {
                    in_prefix[edge.to] = false;
                    changed = true;
                }
            }
            if (changed) {
                var w: usize = 0;
                for (prefix.items) |bi| {
                    if (in_prefix[bi]) {
                        prefix.items[w] = bi;
                        w += 1;
                    }
                }
                prefix.shrinkRetainingCapacity(w);
            }
        }

        return .{
            .kinds = kinds,
            .name_ids = name_ids,
            .eager = eager,
            .groups = groups,
            .strict_prefix = try prefix.toOwnedSlice(self.allocator),
            .in_prefix = in_prefix,
        };
    }

    fn deinit(self: *LetPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.kinds);
        allocator.free(self.name_ids);
        allocator.free(self.eager);
        self.groups.deinit(allocator);
        allocator.free(self.strict_prefix);
        allocator.free(self.in_prefix);
    }
};

fn declareBindingSlots(self: *Compiler, bindings: []const Node.Binding, plan: LetPlan) !void {
    for (bindings, plan.kinds, 0..) |binding, kind, index| {
        if (!plan.groups.firstAt(index)) continue;
        if (kind == .unreferenced) continue;
        const name = attr_names.span(self, binding.path[0]);
        const name_id = plan.name_ids[index];
        const slot = try scope.declareLocal(self, name, name_id);
        switch (kind) {
            .literal => {
                const leaf = plan.groups.singleLeaf(bindings, index).?;
                self.armRecursiveName(name_id);
                try access.compileContainerValue(self, leaf.expr, .{});
                try emit.emitSetLocal(self, slot);
            },
            .uncaptured => {},
            .needs_cell => try emit.emitInitCellSlot(self, slot),
            .unreferenced => unreachable,
        }
    }
}

fn declareInheritSlots(
    self: *Compiler,
    bindings: []const Node.Binding,
    kinds: []const LetBindingKind,
    states: *std.AutoHashMapUnmanaged(u32, InheritState),
) !void {
    const inherit_name = "\x00inherit-source";
    const inherit_name_id = try self.intern.intern(inherit_name);
    for (bindings, kinds) |binding, kind| {
        if (binding.inherit_group == 0 or kind == .unreferenced or states.contains(binding.inherit_group)) continue;
        try states.put(self.allocator, binding.inherit_group, .{
            .slot = try scope.declareLocal(self, inherit_name, inherit_name_id),
        });
    }
}

fn emitBindingInitializers(
    self: *Compiler,
    bindings: []const Node.Binding,
    plan: LetPlan,
    inherit_states: *std.AutoHashMapUnmanaged(u32, InheritState),
) !void {
    for (bindings, plan.kinds, 0..) |binding, kind, index| {
        if (!plan.groups.firstAt(index)) continue;
        if (kind == .literal or kind == .unreferenced) continue;
        // Strict-prefix members get no thunk at all: pass 3 below evaluates
        // them directly into their slots once every sibling thunk exists.
        if (plan.in_prefix[index]) continue;
        const name = attr_names.span(self, binding.path[0]);
        const slot = scope.resolveLocal(self, name) orelse return error.UndefinedVariable;

        var inherit_source_slot: ?u16 = null;
        if (binding.inherit_group != 0) {
            const state = inherit_states.getPtr(binding.inherit_group) orelse return error.InvalidAttributePath;
            if (!state.initialized) {
                const inherited = ast.unwrapParens(binding.expr);
                if (inherited.tag != .attr_path or inherited.data.attr_path.segments.len != 1)
                    return error.InvalidAttributePath;
                try thunks.compileThunk(self, inherited.data.attr_path.root);
                try emit.emitSetLocal(self, state.slot);
                state.initialized = true;
            }
            inherit_source_slot = state.slot;
        }

        self.armRecursiveName(plan.name_ids[index]);
        try compileLetRootBinding(self, bindings, plan.groups.members(index), slot, plan.eager[index], inherit_source_slot);
        switch (kind) {
            .needs_cell => try emit.emitSetCellLocal(self, slot),
            .uncaptured => try emit.emitSetLocal(self, slot),
            .literal, .unreferenced => unreachable,
        }
    }

    // Pass 3 — the strict prefix: bindings the body PROVABLY forces first,
    // evaluated directly into their slots in demand order (dependencies
    // before dependents, so a chain member reads its precursor's finished
    // value). All lazy siblings already hold their thunks, so forward
    // references resolve; evaluation order — including which error surfaces
    // first — is exactly what lazy evaluation would have produced.
    for (plan.strict_prefix) |index| {
        const binding = bindings[index];
        const leaf = plan.groups.singleLeaf(bindings, index).?;
        const name = attr_names.span(self, binding.path[0]);
        const slot = scope.resolveLocal(self, name) orelse return error.UndefinedVariable;
        self.armRecursiveName(plan.name_ids[index]);
        try self.compileNode(leaf.expr);
        self.name_hint = null;
        try emit.emitSetLocal(self, slot);
    }
}

/// Decide for each binding whether it can skip the cell. A binding
/// needs a cell iff some *earlier* binding (which gets compiled first
/// in pass 2) references it by name — only then is the cell's
/// mutable-handle behaviour load-bearing. Later bindings and the body
/// always see the bound value because pass 2 fills slots in source
/// order before the body emits.
///
/// To keep compile cost reasonable on big lets, all queries below are
/// membership tests against the let's OWN binding names — so instead of
/// materializing a name set per region (body + every RHS), one walk per
/// region marks which binding names it mentions. Per name we keep how
/// many RHS regions mention it and the earliest such binding index;
/// that pair answers both the "referenced by another RHS" and the
/// "referenced at-or-before index" (cell-needed) predicates exactly.
fn classifyLetBindings(self: *Compiler, bindings: []const Node.Binding, body: *const Node) !LetClassification {
    const kinds = try self.allocator.alloc(LetBindingKind, bindings.len);
    errdefer self.allocator.free(kinds);

    // Slot per unique binding-root name, in first-occurrence order.
    var slots: std.StringHashMapUnmanaged(u32) = .empty;
    defer slots.deinit(self.allocator);
    try slots.ensureTotalCapacity(self.allocator, @intCast(bindings.len));
    var slot_count: u32 = 0;
    for (bindings) |binding| {
        const name = attr_names.span(self, binding.path[0]);
        const gop = slots.getOrPutAssumeCapacity(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = slot_count;
            slot_count += 1;
        }
    }

    // First binding index per slot: all members of a merged dotted group
    // (`a.x = …; a.y = …`) are compiled together at the group's first
    // index, so their RHS references must be credited to that index.
    const slot_of = try self.allocator.alloc(u32, bindings.len);
    errdefer self.allocator.free(slot_of);
    const slot_first = try self.allocator.alloc(u32, slot_count);
    errdefer self.allocator.free(slot_first);
    @memset(slot_first, std.math.maxInt(u32));
    for (bindings, 0..) |binding, i| {
        const slot = slots.get(attr_names.span(self, binding.path[0])).?;
        slot_of[i] = slot;
        if (slot_first[slot] == std.math.maxInt(u32)) slot_first[slot] = @intCast(i);
    }

    // Group membership lists and the per-group single-plain-leaf, one pass.
    const single_leaf = try self.allocator.alloc(u32, slot_count);
    errdefer self.allocator.free(single_leaf);
    @memset(single_leaf, no_single_leaf);
    const group_offsets = try self.allocator.alloc(u32, slot_count + 1);
    errdefer self.allocator.free(group_offsets);
    @memset(group_offsets, 0);
    for (slot_of) |slot| group_offsets[slot + 1] += 1;
    for (1..slot_count + 1) |s| group_offsets[s] += group_offsets[s - 1];
    const group_items = try self.allocator.alloc(u32, bindings.len);
    errdefer self.allocator.free(group_items);
    {
        const cursor = try self.allocator.alloc(u32, slot_count);
        defer self.allocator.free(cursor);
        @memcpy(cursor, group_offsets[0..slot_count]);
        for (slot_of, 0..) |slot, i| {
            group_items[cursor[slot]] = @intCast(i);
            cursor[slot] += 1;
        }
    }
    for (bindings, slot_of, 0..) |binding, slot, i| {
        const sole_member = group_offsets[slot + 1] - group_offsets[slot] == 1;
        if (sole_member and binding.path.len == 1 and !binding.inherit_outer)
            single_leaf[slot] = @intCast(i);
    }

    const body_hit = try self.allocator.alloc(bool, slot_count);
    defer self.allocator.free(body_hit);
    @memset(body_hit, false);
    var body_marker: BodyMarker = .{ .slots = &slots, .hit = body_hit };
    refs_mod.walkReferencedNames(self, body, &body_marker);

    const rhs_counts = try self.allocator.alloc(u32, slot_count);
    defer self.allocator.free(rhs_counts);
    @memset(rhs_counts, 0);
    const rhs_first = try self.allocator.alloc(u32, slot_count);
    defer self.allocator.free(rhs_first);
    const rhs_stamp = try self.allocator.alloc(u32, slot_count);
    defer self.allocator.free(rhs_stamp);
    @memset(rhs_stamp, 0);

    var any_path_nested = false;
    var rhs_marker: RhsMarker = .{
        .allocator = self.allocator,
        .slots = &slots,
        .slot_first = slot_first,
        .counts = rhs_counts,
        .first = rhs_first,
        .stamp_seen = rhs_stamp,
        .stamp = 0,
        .index = 0,
    };
    defer rhs_marker.edges.deinit(self.allocator);
    for (bindings, 0..) |binding, i| {
        if (binding.path.len > 1) {
            // Nested-path bindings synthesise an attr-set thunk
            // whose captures we don't statically track; conservative:
            // any such binding "references" every other.
            any_path_nested = true;
        }
        rhs_marker.stamp += 1;
        rhs_marker.index = slot_first[slot_of[i]];
        refs_mod.walkReferencedNames(self, binding.expr, &rhs_marker);
        // Dotted tail segments may interpolate (`a."${x}" = 1;`): the
        // group's thunk compiles them, so they are RHS references too.
        for (binding.path[1..]) |seg| refs_mod.walkIdentifiersInSpan(self, seg, &rhs_marker);
    }
    if (rhs_marker.err) |err| return err;

    for (bindings, 0..) |binding, i| {
        _ = binding;
        const slot = slot_of[i];
        if (slot_first[slot] != i) {
            kinds[i] = .needs_cell;
            continue;
        }

        const referenced_by_other_rhs = rhs_counts[slot] > 1 or
            (rhs_counts[slot] == 1 and rhs_first[slot] != i);
        const externally_referenced = body_hit[slot] or any_path_nested or
            referenced_by_other_rhs;
        if (!externally_referenced) {
            kinds[i] = .unreferenced;
            continue;
        }
        if (single_leaf[slot] != no_single_leaf and
            access.isLiteralContainerValue(self, bindings[single_leaf[slot]].expr))
        {
            kinds[i] = .literal;
            continue;
        }
        // A binding needs its cell when some RHS at-or-before it (earlier
        // sibling, or itself via self-recursion) mentions the name: that's
        // exactly the set whose pass-2 compile would capture before the
        // slot is filled.
        if (rhs_counts[slot] > 0 and rhs_first[slot] <= i) {
            kinds[i] = .needs_cell;
        } else {
            kinds[i] = .uncaptured;
        }
    }
    return .{
        .kinds = kinds,
        .rhs_edges = try rhs_marker.edges.toOwnedSlice(self.allocator),
        .groups = .{
            .slot_of = slot_of,
            .slot_first = slot_first,
            .single_leaf = single_leaf,
            .offsets = group_offsets,
            .items = group_items,
        },
    };
}

const BodyMarker = struct {
    slots: *const std.StringHashMapUnmanaged(u32),
    hit: []bool,

    pub fn mark(self: *BodyMarker, name: []const u8) void {
        if (self.slots.get(name)) |slot| self.hit[slot] = true;
    }
};

/// Per-slot RHS aggregation: `counts[slot]` = number of RHS regions
/// mentioning the name, `first[slot]` = earliest such binding index.
/// `stamp_seen` deduplicates within one region, so repeated mentions in the
/// same RHS count once. Also collects the full reference edge list
/// (`RhsEdge`) for strict-prefix validation.
const RhsMarker = struct {
    allocator: std.mem.Allocator,
    slots: *const std.StringHashMapUnmanaged(u32),
    slot_first: []const u32,
    counts: []u32,
    first: []u32,
    stamp_seen: []u32,
    stamp: u32,
    index: u32,
    edges: std.ArrayListUnmanaged(RhsEdge) = .empty,
    err: ?anyerror = null,

    pub fn mark(self: *RhsMarker, name: []const u8) void {
        const slot = self.slots.get(name) orelse return;
        if (self.stamp_seen[slot] == self.stamp) return;
        self.stamp_seen[slot] = self.stamp;
        self.counts[slot] += 1;
        // Regions are visited in binding order but carry their group's first
        // index, which is not monotone — keep the minimum, not the first seen.
        if (self.counts[slot] == 1 or self.index < self.first[slot]) self.first[slot] = self.index;
        self.edges.append(self.allocator, .{ .from = self.index, .to = self.slot_first[slot] }) catch |err| {
            self.err = err;
        };
    }
};

/// Compile one root-name group's initializer. `members` is the group's
/// binding-index list from `BindingGroups` (source order).
fn compileLetRootBinding(self: *Compiler, bindings: []const Node.Binding, members: []const u32, slot: u16, eager: bool, inherit_source_slot: ?u16) !void {
    var leaf: ?Node.Binding = null;
    var tail_count: usize = 0;

    for (members) |member| {
        const binding = bindings[member];
        if (binding.path.len == 1) {
            if (leaf) |previous| {
                const span = self.source[binding.name_offset .. binding.name_offset + binding.name_len];
                const message = try std.fmt.allocPrint(self.allocator, "variable '{s}' already defined", .{span});
                try self.owned_diagnostic_messages.append(self.allocator, message);
                try diagnostics.reportCompileError(self, binding.name_offset, binding.name_len, message);
                try diagnostics.reportCompileNote(self, previous.name_offset, previous.name_len, "first binding defined here");
                return error.DuplicateBinding;
            }
            leaf = binding;
        } else {
            tail_count += 1;
        }
    }

    if (tail_count == 0) {
        const binding = leaf orelse return error.UndefinedVariable;
        if (inherit_source_slot) |source_slot| {
            try emit.emitThunkAttr(self, .{
                .name = "\x00inherit-source",
                .name_id = try self.intern.intern("\x00inherit-source"),
                .kind = .local,
                .index = source_slot,
            }, try attr_names.intern(self, binding.path[0]));
            return;
        }
        const previous_skip = self.skip_local_slot;
        if (binding.inherit_outer) self.skip_local_slot = slot;
        const compile_result = access.compileContainerValue(self, binding.expr, .{ .eager = eager });
        self.skip_local_slot = previous_skip;
        return compile_result;
    }

    const tails = try self.allocator.alloc(AttrEntryView, tail_count);
    defer self.allocator.free(tails);
    var i: usize = 0;
    for (members) |member| {
        const binding = bindings[member];
        if (binding.path.len == 1) continue;
        tails[i] = .{
            .path = binding.path[1..],
            .expr = binding.expr,
            .inherit_outer = binding.inherit_outer,
            .inherit_group = binding.inherit_group,
        };
        i += 1;
    }

    if (leaf) |root_leaf| {
        if (root_leaf.expr.tag != .attr_set) {
            try diagnostics.reportDuplicateAttribute(self, tails[0].path[0], root_leaf.path[0]);
            return error.DuplicateAttribute;
        }
        const leaves = [_]AttrEntryView{.{
            .path = root_leaf.path,
            .expr = root_leaf.expr,
            .inherit_outer = root_leaf.inherit_outer,
            .inherit_group = root_leaf.inherit_group,
        }};
        return attrs.compileExtendedAttrSetLiteralThunk(self, &leaves, tails);
    }

    return attrs.compileAttrEntriesThunk(self, tails, true);
}

/// Structural builders (attrset/lambda/list) stay lazy: they're already
/// inlined thunk-free where eager, and eagerly building an attrset value
/// can perturb module fixpoints. Everything else is a scalar/
/// computational expression whose strict evaluation is exactly what
/// forcing the binding-thunk would have done.
pub fn isEagerEvalShape(expr: *const Node) bool {
    return switch (expr.tag) {
        .attr_set, .lambda, .lambda_attrs, .list => false,
        else => true,
    };
}
