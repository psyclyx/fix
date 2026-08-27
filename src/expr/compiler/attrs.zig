//! Lowers attribute-set construction — plain, recursive (`rec`), and
//! dynamic/mixed sets — grouping entries by interned name for dedup and
//! sorted `attrs_new`.
//! Also drives lazy per-attr compilation: substantial single-leaf value
//! bodies are registered in the root's deferred table (with an enclosing-
//! scope + with-chain snapshot) and compiled at first force, concurrently
//! over the shared retained AST.

const std = @import("std");
const compiler_mod = @import("context.zig");
const ast = @import("syntax").ast;
const bytecode = @import("../bytecode.zig");
const chunk = bytecode.chunk;
const heap_mod = @import("runtime").heap;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const diagnostics = @import("diagnostics.zig");
const literals = @import("literals.zig");
const access = @import("access.zig");
const deferred_table = @import("deferred_table.zig");
const attr_names = @import("attr_names.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const Capture = compiler_mod.Capture;
const AttrEntryView = compiler_mod.AttrEntryView;
const AttrEntryGroup = compiler_mod.AttrEntryGroup;
const AttrEntryGroups = compiler_mod.AttrEntryGroups;
const InternId = types.InternId;
const ChunkBuilder = chunk.ChunkBuilder;
const diagnostic_atom = @import("diagnostic_atom.zig");
const attrEntriesDiagnosticAtom = diagnostic_atom.attrEntriesDiagnosticAtom;
const attrGroupsDiagnosticAtom = diagnostic_atom.attrGroupsDiagnosticAtom;

pub fn compileAttrSet(self: *Compiler, node: *const Node) !void {
    const aset = node.data.attr_set;
    const entries = try attrEntryViews(self, aset.entries);
    defer self.allocator.free(entries);
    try compileAttrEntries(self, entries, aset.recursive);
}

fn compileAttrEntries(self: *Compiler, entries: []const AttrEntryView, recursive: bool) anyerror!void {
    if (hasDynamicAttrEntryViews(self, entries)) {
        return compileMixedAttrEntryViews(self, entries, recursive);
    }

    if (recursive) {
        try compileRecursiveAttrEntries(self, entries);
    } else {
        try compilePlainAttrEntries(self, entries);
    }
}

fn compileMixedAttrEntryViews(self: *Compiler, entries: []const AttrEntryView, recursive: bool) !void {
    if (recursive) return compileMixedRecursiveAttrEntryViews(self, entries);

    const static_count = staticAttrEntryViewCount(self, entries);
    if (static_count > 0) {
        const static_entries = try self.allocator.alloc(AttrEntryView, static_count);
        defer self.allocator.free(static_entries);

        var i: usize = 0;
        for (entries) |entry| {
            if (!isDynamicAttrEntryView(self, entry)) {
                static_entries[i] = entry;
                i += 1;
            }
        }

        try compileAttrEntries(self, static_entries, false);
    } else {
        try emit.emitEmptyAttrs(self);
    }

    for (entries) |entry| {
        if (!isDynamicAttrEntryView(self, entry)) continue;
        try compileDynamicAttrViewName(self, entry);
        try compileDynamicAttrViewValueThunk(self, entry);
        try emit.emitOpU16(self, .attrs_new, 1);
        try emit.emitOp(self, .attrs_merge_strict);
    }
}

fn compileMixedRecursiveAttrEntryViews(self: *Compiler, entries: []const AttrEntryView) !void {
    const static_count = staticAttrEntryViewCount(self, entries);
    const static_entries = try self.allocator.alloc(AttrEntryView, static_count);
    defer self.allocator.free(static_entries);

    var static_i: usize = 0;
    for (entries) |entry| {
        if (!isDynamicAttrEntryView(self, entry)) {
            static_entries[static_i] = entry;
            static_i += 1;
        }
    }

    var initial = try attrEntryGroups(self, static_entries);
    defer initial.deinit(self.allocator);

    scope.beginScope(self);
    errdefer scope.endScope(self);

    try declareRecursiveAttrLocals(self, initial.groups);
    const prepared = try prepareInheritSourcesInCurrentScope(self, static_entries);
    defer if (prepared) |p| self.allocator.free(p);
    var grouped = if (prepared) |p| try attrEntryGroups(self, p) else initial;
    defer if (prepared != null) grouped.deinit(self.allocator);
    const overrides_id = try recursiveOverridesId(self, grouped.groups);
    try compileRecursiveAttrCells(self, grouped.groups, overrides_id != null);
    try emitRecursiveAttrObject(self, grouped.groups);
    if (overrides_id) |id| try emit.emitApplyOverrides(self, id);

    for (entries) |entry| {
        if (!isDynamicAttrEntryView(self, entry)) continue;
        try compileDynamicAttrViewName(self, entry);
        try compileDynamicAttrViewValueThunk(self, entry);
        try emit.emitOpU16(self, .attrs_new, 1);
        try emit.emitOp(self, .attrs_merge_strict);
    }

    scope.endScope(self);
}

fn hasDynamicAttrEntryViews(self: *const Compiler, entries: []const AttrEntryView) bool {
    for (entries) |entry| {
        if (isDynamicAttrEntryView(self, entry)) return true;
    }
    return false;
}

fn staticAttrEntryViewCount(self: *const Compiler, entries: []const AttrEntryView) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (!isDynamicAttrEntryView(self, entry)) count += 1;
    }
    return count;
}

fn isDynamicAttrEntryView(self: *const Compiler, entry: AttrEntryView) bool {
    return entry.dynamic_name != null or
        (entry.path.len > 0 and attr_names.hasInterpolation(self, entry.path[0]));
}

fn compileDynamicAttrViewName(self: *Compiler, entry: AttrEntryView) !void {
    if (entry.dynamic_name) |name| return self.compileNode(name);
    if (entry.path.len > 0 and attr_names.hasInterpolation(self, entry.path[0])) {
        return literals.compileStringAtom(self, entry.path[0]);
    }
    return error.InvalidAttributePath;
}

fn compileDynamicAttrViewValueThunk(self: *Compiler, entry: AttrEntryView) !void {
    if (entry.dynamic_name != null) {
        if (entry.path.len == 0) return thunks.compileThunk(self, entry.expr);
        const nested = [_]AttrEntryView{.{
            .path = entry.path,
            .expr = entry.expr,
            .inherit_outer = entry.inherit_outer,
            .inherit_group = entry.inherit_group,
            .inherit_slot = entry.inherit_slot,
            .origin = entry.origin,
        }};
        return compileAttrEntriesThunk(self, &nested, false);
    }
    if (entry.path.len == 1) return thunks.compileThunk(self, entry.expr);

    const views = [_]AttrEntryView{
        .{
            .path = entry.path[1..],
            .expr = entry.expr,
            .inherit_outer = entry.inherit_outer,
            .inherit_group = entry.inherit_group,
            .inherit_slot = entry.inherit_slot,
        },
    };
    try compileAttrEntriesThunk(self, &views, false);
}

// ---- lazy per-attr compilation (see deferred_table.zig) ----

fn rootCompiler(self: *Compiler) *Compiler {
    var c = self;
    while (c.parent) |p| c = p;
    return c;
}

/// Append the `with` scopes active at this point (in self or any
/// ancestor) to the snapshot as captures of their *subject values*,
/// innermost-first — `collectWithScopes` does the cross-chunk capture
/// plumbing (parent with-subjects become upvalues of this chunk, exactly
/// as an eager body's with-lookup would). Returns false (fall back to
/// eager) if the combined snapshot would exceed `max_scope_size`. The
/// force-time compile re-establishes these as with-scopes on the
/// synthetic parent (see `compiler/deferred.zig`), preserving resolution
/// order: lexical bindings first, then withs innermost-first.
fn appendWithSnapshot(self: *Compiler, out: *std.ArrayListUnmanaged(Capture)) !bool {
    var wscopes: std.ArrayListUnmanaged(compiler_mod.WithScope) = .empty;
    defer wscopes.deinit(self.allocator);
    try scope.collectWithScopes(self, &wscopes);
    if (out.items.len + wscopes.items.len > deferred_table.max_scope_size) return false;
    const with_name_id = try self.intern.intern(compiler_mod.with_capture_name);
    for (wscopes.items) |ws| {
        try out.append(self.allocator, .{
            .name = compiler_mod.with_capture_name,
            .name_id = with_name_id,
            .kind = ws.kind,
            .index = ws.index,
        });
    }
    return true;
}

/// A value body is deferrable iff it is NOT an immediate/trivial shape —
/// i.e. iff it would otherwise go through the ordinary thunk compiler. Deferring
/// exactly replaces that thunk, so output stays byte-identical. (The
/// immediate set mirrors `access.compileImmediateContainerValue`.)
///
/// `.elided` bodies (never parsed) intentionally land in the `else => true`
/// branch: the parser's elision shape gate (`scanElidableBody`) already
/// excluded every immediate shape at token level, so an elided body is
/// deferral-shaped by construction.
fn isDeferrableBody(node: *const Node) bool {
    return switch (ast.unwrapParens(node).tag) {
        .integer, .float_val, .string, .path, .search_path, .identifier, .list, .attr_set, .lambda, .lambda_attrs => false,
        else => true,
    };
}

/// Source-span size of a body, the compile-cost proxy for the gate.
fn bodySpanBytes(node: *const Node) usize {
    return if (node.span) |s| s.len else 0;
}

/// A single clean leaf qualifies for deferral if its body is a
/// substantial, expensive-to-compile shape.
fn leafDeferrable(leaf: AttrEntryView) bool {
    if (leaf.path.len != 1 or leaf.inherit_outer) return false;
    if (!isDeferrableBody(leaf.expr)) return false;
    return bodySpanBytes(leaf.expr) >= deferred_table.min_body_bytes;
}

/// Does this set contain at least one deferrable leaf? Used to avoid
/// building the scope snapshot (which mutates parent captures) for sets
/// where nothing will actually defer.
fn setHasDeferrableLeaf(groups: []const AttrEntryGroup) bool {
    for (groups) |group| {
        if (group.leaf) |leaf| {
            if (group.leaves.len <= 1 and group.tails.len == 0 and leafDeferrable(leaf)) return true;
        }
    }
    return false;
}

fn containsNameId(items: []const Capture, name_id: InternId) bool {
    for (items) |c| if (c.name_id == name_id) return true;
    return false;
}

/// Whether this plain attrset qualifies for lazy per-attr compilation.
/// (Enclosing `with` scopes are fine: their subject values are
/// snapshotted alongside the lexical bindings — see `appendWithSnapshot`.)
fn shouldDeferSet(self: *Compiler, group_count: usize) bool {
    if (rootCompiler(self).deferred_table == null) return false;
    if (group_count < deferred_table.min_entries) return false;
    // File/import compiles only: source + (retained) arena are
    // evaluator-lived; sidesteps top-level-string source ownership.
    if (self.source_path == null) return false;
    return true;
}

/// Build the enclosing-scope snapshot: every lexically visible binding,
/// each as a `Capture` describing how to fetch it from the CURRENT frame
/// (`.local` slot / `.upvalue` index). Returns false (and the set falls
/// back to eager compile) if the scope exceeds `max_scope_size` or any visible
/// name can't be resolved. Side effect: resolving up-scope names adds the
/// corresponding upvalues to this chunk — exactly what a body referencing
/// them would do, so the deferred thunk can capture them.
fn buildEnclosingSnapshot(self: *Compiler, out: *std.ArrayListUnmanaged(Capture)) !bool {
    var comp: ?*Compiler = self;
    while (comp) |c| : (comp = c.parent) {
        var i = c.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = c.locals.items[i];
            // Skip anonymous with-subject slots (declared by
            // `compileWithBody` under the empty name): they are not
            // lexically referencable, and the with chain is snapshotted
            // separately by `appendWithSnapshot`.
            if (local.name.len == 0) continue;
            if (containsNameId(out.items, local.name_id)) continue;
            const cap: Capture = if (scope.resolveLocalId(self, local.name_id)) |slot|
                .{ .name = local.name, .name_id = local.name_id, .kind = .local, .index = slot }
            else if (try scope.resolveCaptureId(self, local.name, local.name_id)) |up|
                .{ .name = local.name, .name_id = local.name_id, .kind = .upvalue, .index = up }
            else
                return false; // visible but unresolvable — bail conservatively
            if (out.items.len >= deferred_table.max_scope_size) return false;
            try out.append(self.allocator, cap);
        }
    }
    return true;
}

/// The per-set deferral snapshot: lexical bindings followed by
/// `with_count` with-subject captures (innermost-first). `caps` and the
/// paths are table-owned (`adoptScope`/`internPath`, resolved once per
/// set) and shared by every deferred leaf of the set.
const DeferScope = struct {
    caps: []const Capture,
    with_count: u16,
    base_path: ?[]const u8,
    source_path: ?[]const u8,
};

/// Register a deferred value body and emit `thunk_defer`. `name` is the
/// attr the body is bound to, carried through for best-effort chunk naming
/// (`fix disasm`); null / ignored when naming is off.
fn deferLeaf(self: *Compiler, body: *const Node, name: InternId, snapshot: DeferScope) !void {
    const root = rootCompiler(self);
    const table = root.deferred_table.?;
    const id = try table.register(.{
        .node = body,
        .scope = snapshot.caps,
        .with_count = snapshot.with_count,
        .source = self.source,
        .base_path = snapshot.base_path,
        .source_path = snapshot.source_path,
        .source_file_id = self.source_file_id,
        .policy = self.policy,
        // Qualified name of the deferred body: this compiler's name, extended
        // by the attr it binds. Always on (real binding), like eager bodies.
        .name_id = self.registry.childName(self.name_id, name, false) catch self.name_id,
    });
    try self.recordUnitDeferred(id);
    try emit.emitDeferAttrValue(self, id, snapshot.caps);
    root.deferred_count += 1;
}

fn compilePlainAttrEntries(self: *Compiler, entries: []const AttrEntryView) anyerror!void {
    const prepared = try prepareInheritSources(self, entries);
    defer if (prepared) |p| {
        self.allocator.free(p);
        scope.endScope(self);
    };
    const effective_entries = prepared orelse entries;

    var grouped = try attrEntryGroups(self, effective_entries);
    defer grouped.deinit(self.allocator);

    // Emit groups in ascending interned-name order (groups are unique by
    // name_id, duplicates rejected below) so `attrs_new_srt` can skip
    // the runtime sort + duplicate scan on every construction. Value code
    // in a plain attr literal is non-strict (thunks/constants/captures),
    // so emission order is not observable. Sorts a compact index array —
    // sorting the larger `AttrEntryGroup` values would copy each group many
    // times.
    const order = try sortedGroupOrder(self, grouped.groups);
    defer self.allocator.free(order);

    var positions: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
    defer positions.deinit(self.allocator);

    // Lazy per-attr compilation: build the enclosing-scope snapshot once
    // (shared by every deferred value body — non-recursive, so they all
    // see the same scope). Null if the set doesn't qualify.
    var snapshot: std.ArrayListUnmanaged(Capture) = .empty;
    defer snapshot.deinit(self.allocator);
    var defer_scope: ?DeferScope = null;
    if (shouldDeferSet(self, grouped.groups.len) and setHasDeferrableLeaf(grouped.groups)) {
        if (try buildEnclosingSnapshot(self, &snapshot)) {
            const lexical_len = snapshot.items.len;
            if (try appendWithSnapshot(self, &snapshot)) {
                const table = rootCompiler(self).deferred_table.?;
                defer_scope = .{
                    .caps = try table.adoptScope(snapshot.items),
                    .with_count = @intCast(snapshot.items.len - lexical_len),
                    .base_path = try table.internPath(self.base_path),
                    .source_path = try table.internPath(self.source_path),
                };
            }
        }
    }

    var names: std.ArrayListUnmanaged(InternId) = .empty;
    defer names.deinit(self.allocator);
    for (order) |group_idx| {
        try names.append(self.allocator, grouped.groups[group_idx].name_id);
        try compilePlainAttrGroup(self, &positions, grouped.groups[group_idx], defer_scope);
    }

    const count = try diagnostics.requireU16At(self, grouped.groups.len, attrEntriesDiagnosticAtom(effective_entries), "too many attributes in set");
    try emit.emitBuildAttrsSorted(self, count, names.items, positions.items);
}

/// Index permutation of `groups` in ascending `name_id` order. Groups are
/// unique by name_id (hashmap-grouped), so the order is total.
fn sortedGroupOrder(self: *Compiler, groups: []const AttrEntryGroup) ![]u32 {
    const order = try self.allocator.alloc(u32, groups.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, groups, groupIndexLessThan);
    return order;
}

fn groupIndexLessThan(groups: []const AttrEntryGroup, lhs: u32, rhs: u32) bool {
    return groups[lhs].name_id < groups[rhs].name_id;
}

fn compileRecursiveAttrEntries(self: *Compiler, entries: []const AttrEntryView) anyerror!void {
    scope.beginScope(self);
    errdefer scope.endScope(self);

    // Recursive names must exist as cells before the inherit-source thunk is
    // created, so a source expression can safely capture any sibling.
    var initial = try attrEntryGroups(self, entries);
    defer initial.deinit(self.allocator);
    try declareRecursiveAttrLocals(self, initial.groups);

    const prepared = try prepareInheritSourcesInCurrentScope(self, entries);
    defer if (prepared) |p| self.allocator.free(p);
    const effective_entries = prepared orelse entries;
    var grouped = if (prepared != null) try attrEntryGroups(self, effective_entries) else initial;
    defer if (prepared != null) grouped.deinit(self.allocator);

    const overrides_id = try recursiveOverridesId(self, grouped.groups);
    try compileRecursiveAttrCells(self, grouped.groups, overrides_id != null);
    try emitRecursiveAttrObject(self, grouped.groups);
    if (overrides_id) |id| try emit.emitApplyOverrides(self, id);
    scope.endScope(self);
}

fn compilePlainAttrGroup(
    self: *Compiler,
    positions: *std.ArrayListUnmanaged(heap_mod.AttrPosEntry),
    group: AttrEntryGroup,
    defer_scope: ?DeferScope,
) anyerror!void {
    const leaf = group.leaf;
    if (leaf == null) {
        // Tail-only group (`a.b = …`): the value is the `{ b = … }` thunk,
        // which the binding name `a` describes.
        self.armName(group.name_id);
        try compileAttrEntriesThunk(self, group.tails, false);
        try attr_names.appendPosition(self, positions, group.first, group.name_id);
        return;
    }

    if (group.leaves.len > 1 or group.tails.len > 0) {
        // Elided leaves must be materialized first: whether an extended
        // group merges (leaf is an attrset literal) or is a duplicate
        // error depends on the leaf's true shape.
        for (group.leaves) |*lv| {
            if (lv.expr.tag == .elided) lv.expr = try literals.materializeElided(self, lv.expr);
        }
        const lead = group.leaves[0];
        const duplicate = duplicateExtendedLeaf(group, lead);
        if (duplicate) |entry| {
            try diagnostics.reportDuplicateAttribute(self, entry.path[0], lead.path[0]);
            return error.DuplicateAttribute;
        }
        self.armName(group.name_id);
        try compileExtendedAttrSetLiteralThunk(self, group.leaves, group.tails);
        try attr_names.appendPosition(self, positions, group.first, group.name_id);
        return;
    }

    // Lazy per-attr compilation: a clean single-leaf body (path.len == 1,
    // not an inherit) whose shape is substantial defers its compile to
    // first force instead of emitting bytecode now. An `.elided` body
    // qualifies without inspection: the parser's elision gates guarantee
    // it is deferral-shaped and over min_body_bytes (`isDeferrableBody`
    // returns true for `.elided` via its else branch).
    if (defer_scope) |dscope| {
        if (leafDeferrable(leaf.?)) {
            try deferLeaf(self, leaf.?.expr, group.name_id, dscope);
            try attr_names.appendPosition(self, positions, group.first, group.name_id);
            return;
        }
    }

    // Eager path: materialize an elided body before the shape-sensitive
    // immediate-vs-thunk decision so the emitted bytecode is exactly what
    // the eager parse would have produced.
    var body = leaf.?.expr;
    if (body.tag == .elided) body = try literals.materializeElided(self, body);
    self.armName(group.name_id);
    if (!try compileInheritedLeaf(self, leaf.?))
        try access.compileContainerValue(self, body, .{ .raw_identifier = true });
    try attr_names.appendPosition(self, positions, group.first, group.name_id);
}

/// If this recursive set statically declares a top-level `__overrides`
/// attribute, validate the feature gate and return its interned name for the
/// caller's runtime override-application step. No-op for the overwhelmingly
/// common case (no `__overrides` key), so plain rec sets pay nothing.
/// Nested `__overrides` (e.g. `rec { a.__overrides.a = 1; }`) is NOT a
/// top-level key here, so it correctly does not trigger.
fn recursiveOverridesId(self: *Compiler, groups: []const AttrEntryGroup) anyerror!?InternId {
    const overrides_id = try self.intern.intern("__overrides");
    for (groups) |group| {
        if (group.name_id == overrides_id) {
            // Lix deprecated `__overrides`: an error by default, re-permitted by
            // the `rec-set-overrides` feature. Scoped to top-level static keys
            // of a rec set, so nested/non-rec/dynamic `__overrides` don't trip.
            if (!self.policy.allow_rec_set_overrides) {
                try diagnostics.reportCompileError(self, group.first.offset, group.first.len, "__overrides attributes are deprecated and will be removed in the future. Use --extra-deprecated-features rec-set-overrides to silence this warning.");
                return error.RecSetOverridesDeprecated;
            }
            return overrides_id;
        }
    }
    return null;
}

fn declareRecursiveAttrLocals(self: *Compiler, groups: []const AttrEntryGroup) anyerror!void {
    for (groups) |group| {
        const slot = try scope.declareLocal(self, group.name, group.name_id);
        try emit.emitInitCellSlot(self, slot);
    }
}

fn compileRecursiveAttrCells(self: *Compiler, groups: []const AttrEntryGroup, suppress_speculation: bool) anyerror!void {
    const previous_suppression = self.suppress_child_speculation;
    self.suppress_child_speculation = previous_suppression or suppress_speculation;
    defer self.suppress_child_speculation = previous_suppression;

    for (groups) |group| {
        const slot = scope.resolveLocalId(self, group.name_id) orelse return error.UndefinedVariable;
        const leaf = group.leaf;
        if (leaf == null) {
            try compileAttrEntriesThunk(self, group.tails, false);
            try emit.emitSetCellLocal(self, slot);
            continue;
        }

        if (group.leaves.len > 1 or group.tails.len > 0) {
            const duplicate = duplicateExtendedLeaf(group, leaf.?);
            if (duplicate) |entry| {
                try diagnostics.reportDuplicateAttribute(self, entry.path[0], leaf.?.path[0]);
                return error.DuplicateAttribute;
            }
            try compileExtendedAttrSetLiteralThunk(self, group.leaves, group.tails);
            try emit.emitSetCellLocal(self, slot);
            continue;
        }
        const previous_skip = self.skip_local_slot;
        if (leaf.?.inherit_outer) self.skip_local_slot = slot;
        self.armName(group.name_id);
        const inherited = try compileInheritedLeaf(self, leaf.?);
        const compile_result = if (inherited) @as(anyerror!void, {}) else access.compileContainerValue(self, leaf.?.expr, .{});
        self.skip_local_slot = previous_skip;
        try compile_result;
        try emit.emitSetCellLocal(self, slot);
    }
}

fn emitRecursiveAttrObject(self: *Compiler, groups: []const AttrEntryGroup) anyerror!void {
    var positions: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
    defer positions.deinit(self.allocator);

    // Emit the cell reads in ascending interned-name order for
    // `attrs_new_named_srt` (names ride the side table) — the cells were
    // already declared and filled in source order above; this loop only
    // reads locals, so its order is not observable.
    const order = try sortedGroupOrder(self, groups);
    defer self.allocator.free(order);

    var names: std.ArrayListUnmanaged(InternId) = .empty;
    defer names.deinit(self.allocator);
    for (order) |group_idx| {
        const group = groups[group_idx];
        try names.append(self.allocator, group.name_id);

        const slot = scope.resolveLocalId(self, group.name_id) orelse return error.UndefinedVariable;
        try emit.emitCaptureLocal(self, slot);
        try attr_names.appendPosition(self, &positions, group.first, group.name_id);
    }

    const count = try diagnostics.requireU16At(self, groups.len, attrGroupsDiagnosticAtom(groups), "too many attributes in set");
    try emit.emitBuildAttrsSorted(self, count, names.items, positions.items);
}

pub fn compileExtendedAttrSetLiteralThunk(self: *Compiler, leaves: []const AttrEntryView, tails: []const AttrEntryView) !void {
    std.debug.assert(leaves.len > 0);
    std.debug.assert(leaves[0].expr.tag == .attr_set);

    var merged_count: usize = tails.len;
    for (leaves) |leaf| {
        std.debug.assert(leaf.expr.tag == .attr_set);
        merged_count += leaf.expr.data.attr_set.entries.len;
    }

    const merged = try self.allocator.alloc(AttrEntryView, merged_count);
    defer self.allocator.free(merged);

    var index: usize = 0;
    for (leaves) |leaf| {
        const attr_set = leaf.expr.data.attr_set;
        for (attr_set.entries, merged[index .. index + attr_set.entries.len]) |entry, *view| {
            view.* = .{
                .path = entry.path,
                .dynamic_name = entry.dynamic_name,
                .expr = entry.expr,
                .inherit_outer = entry.inherit_outer,
                .inherit_group = entry.inherit_group,
            };
        }
        index += attr_set.entries.len;
    }
    for (tails, merged[index..]) |tail, *entry| {
        entry.* = .{
            .path = tail.path,
            .expr = tail.expr,
            .inherit_outer = tail.inherit_outer,
            .inherit_group = tail.inherit_group,
            .inherit_slot = tail.inherit_slot,
            .origin = tail.origin,
        };
    }

    // The merged set is recursive iff the FIRST definition (in source order) is
    // a `rec` leaf — Nix's deprecated `rec-set-merges`. So
    // `{ foo = rec { x=1; y=2; }; foo.bar = y; }` stays recursive (`bar = y` sees
    // 2), while `{ foo.bar = 1; foo = rec { x=1; y=x; }; }` — where the implicit
    // non-rec `foo.bar` comes first — becomes non-recursive, so `y = x` errors.
    // A leaf's source position is its own name atom; a tail's is its outer
    // origin segment (the `foo` of `foo.bar`).
    var recursive = false;
    var earliest: u32 = std.math.maxInt(u32);
    var has_rec = false;
    var has_nonrec = tails.len > 0; // a path continuation (`foo.bar`) is non-recursive
    for (leaves) |leaf| {
        if (leaf.expr.data.attr_set.recursive) has_rec = true else has_nonrec = true;
        const off = leaf.path[0].offset;
        if (off < earliest) {
            earliest = off;
            recursive = leaf.expr.data.attr_set.recursive;
        }
    }
    for (tails) |tail| {
        const off = if (tail.origin) |o| o.offset else tail.path[0].offset;
        if (off < earliest) {
            earliest = off;
            recursive = false;
        }
    }
    // Lix deprecated `rec-set-merges`: merging definitions that disagree on
    // recursiveness (a `rec` set with a non-rec set or a path continuation)
    // discards a `rec` modifier, so it errors by default and is re-permitted by
    // the feature.
    if (has_rec and has_nonrec and !self.policy.allow_rec_set_merges) {
        const name = self.source[leaves[0].path[0].offset..][0..leaves[0].path[0].len];
        const message = try std.fmt.allocPrint(self.allocator, "attribute '{s}' cannot be merged, because one set is marked as recursive and the other isn't. Use --extra-deprecated-features rec-set-merges to disable this error and make the expression parse as-is with implementation-defined semantics.", .{name});
        try self.owned_diagnostic_messages.append(self.allocator, message);
        try diagnostics.reportCompileError(self, leaves[0].path[0].offset, leaves[0].path[0].len, message);
        return error.RecSetMergesDeprecated;
    }
    try compileAttrEntriesThunk(self, merged, recursive);
}

fn duplicateExtendedLeaf(group: AttrEntryGroup, leaf: AttrEntryView) ?AttrEntryView {
    if (leaf.expr.tag != .attr_set) return group.duplicate_leaf orelse group.first_nested;
    return nonAttrSetDuplicateLeaf(group);
}

fn nonAttrSetDuplicateLeaf(group: AttrEntryGroup) ?AttrEntryView {
    if (group.leaves.len <= 1) return null;
    for (group.leaves[1..]) |leaf| {
        if (leaf.expr.tag != .attr_set) return leaf;
    }
    return null;
}

pub fn compileAttrEntriesThunk(self: *Compiler, entries: []const AttrEntryView, recursive: bool) anyerror!void {
    self.armSyntheticName("(attrs)");
    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
    defer child.deinit();

    compileAttrEntries(&child, entries, recursive) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    try emit.emitRet(&child);
    try emit.emitOp(&child, .halt);

    // Attrset-body thunk has no single body node (and an empty source map — its
    // values are separate thunks), so give it a representative body_span from
    // the first entry for the timeline. See Chunk.body_span.
    if (entries.len > 0) child_builder.body_span = diagnostics.sourceSpanForNode(&child, entries[0].expr) catch null;
    const child_chunk = try child_builder.finish(self.persistent, child.slot_count);
    const child_id = try child.registerChunk(child_chunk);
    try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
}

fn attrEntryViews(self: *Compiler, entries: []const Node.AttrSetEntry) ![]AttrEntryView {
    const views = try self.allocator.alloc(AttrEntryView, entries.len);
    for (entries, views) |entry, *view| {
        view.* = .{
            .path = entry.path,
            .dynamic_name = entry.dynamic_name,
            .expr = entry.expr,
            .inherit_outer = entry.inherit_outer,
            .inherit_group = entry.inherit_group,
        };
    }
    return views;
}

/// Prepare one lazy phantom local for every `inherit (expr)` clause and stamp
/// its slot onto each normalized entry. Plain sets get a private compiler
/// scope; recursive sets call the in-current-scope variant after declaring
/// their binding cells.
fn prepareInheritSources(self: *Compiler, entries: []const AttrEntryView) !?[]AttrEntryView {
    for (entries) |entry| {
        if (entry.inherit_group != 0 and entry.inherit_slot == null) {
            scope.beginScope(self);
            errdefer scope.endScope(self);
            return prepareInheritSourcesInCurrentScope(self, entries);
        }
    }
    return null;
}

fn prepareInheritSourcesInCurrentScope(self: *Compiler, entries: []const AttrEntryView) !?[]AttrEntryView {
    var any = false;
    for (entries) |entry| if (entry.inherit_group != 0 and entry.inherit_slot == null) {
        any = true;
        break;
    };
    if (!any) return null;

    const prepared = try self.allocator.dupe(AttrEntryView, entries);
    errdefer self.allocator.free(prepared);
    var slots: std.AutoHashMapUnmanaged(u32, u16) = .empty;
    defer slots.deinit(self.allocator);
    const phantom_name = "\x00inherit-source";
    const phantom_id = try self.intern.intern(phantom_name);

    for (prepared) |*entry| {
        if (entry.inherit_group == 0 or entry.inherit_slot != null) continue;
        if (slots.get(entry.inherit_group)) |slot| {
            entry.inherit_slot = slot;
            continue;
        }
        const slot = try scope.declareLocal(self, phantom_name, phantom_id);
        const source = try inheritSource(entry.expr);
        try thunks.compileThunk(self, source);
        try emit.emitSetLocal(self, slot);
        try slots.put(self.allocator, entry.inherit_group, slot);
        entry.inherit_slot = slot;
    }
    return prepared;
}

fn inheritSource(expr_raw: *const Node) !*const Node {
    const expr = ast.unwrapParens(expr_raw);
    if (expr.tag != .attr_path or expr.data.attr_path.segments.len != 1) return error.InvalidAttributePath;
    return expr.data.attr_path.root;
}

/// Emit the inherited member as a frameless attr-access thunk over the shared
/// source local. Returns false for an ordinary entry.
fn compileInheritedLeaf(self: *Compiler, leaf: AttrEntryView) !bool {
    const source_slot = leaf.inherit_slot orelse return false;
    if (leaf.path.len != 1) return error.InvalidAttributePath;
    const name_id = try attr_names.intern(self, leaf.path[0]);
    try emit.emitThunkAttr(self, .{
        .name = "\x00inherit-source",
        .name_id = try self.intern.intern("\x00inherit-source"),
        .kind = .local,
        .index = source_slot,
    }, name_id);
    return true;
}

const AttrEntryGroupBuild = struct {
    group: AttrEntryGroup,
    leaf_count: usize = 0,
    tail_count: usize = 0,
};

fn attrEntryGroups(self: *Compiler, entries: []const AttrEntryView) !AttrEntryGroups {
    var group_index: std.AutoHashMapUnmanaged(InternId, usize) = .empty;
    defer group_index.deinit(self.allocator);

    var builds: std.ArrayListUnmanaged(AttrEntryGroupBuild) = .empty;
    defer builds.deinit(self.allocator);
    var build_names_owned = true;
    errdefer if (build_names_owned) {
        for (builds.items) |build| self.allocator.free(build.group.name);
    };

    // Per-entry interned name ids, computed once here and reused by the
    // second (leaf/tail fill) pass — recomputing them per entry doubled the
    // decode+intern work on huge generated sets.
    const name_ids = try self.allocator.alloc(InternId, entries.len);
    errdefer self.allocator.free(name_ids);

    var total_leaves: usize = 0;
    var total_tails: usize = 0;
    for (entries, name_ids) |entry, *entry_name_id| {
        if (entry.path.len == 0) return error.InvalidAttributePath;

        const name_id = try attr_names.intern(self, entry.path[0]);
        entry_name_id.* = name_id;
        const gop = try group_index.getOrPut(self.allocator, name_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = builds.items.len;
            try builds.append(self.allocator, .{ .group = .{
                .first = entry.origin orelse entry.path[0],
                .name = try attr_names.alloc(self, entry.path[0]),
                .name_id = name_id,
            } });
        }
        const index = gop.value_ptr.*;

        const build = &builds.items[index];
        const group = &build.group;
        if (entry.path.len == 1) {
            build.leaf_count += 1;
            total_leaves += 1;
            if (group.leaf == null) {
                group.leaf = entry;
            } else if (group.duplicate_leaf == null) {
                group.duplicate_leaf = entry;
            }
        } else {
            if (group.first_nested == null) group.first_nested = entry;
            build.tail_count += 1;
            total_tails += 1;
        }
    }

    const groups = try self.allocator.alloc(AttrEntryGroup, builds.items.len);
    for (builds.items, groups) |build, *group| group.* = build.group;
    build_names_owned = false;
    errdefer {
        for (groups) |group| self.allocator.free(group.name);
        self.allocator.free(groups);
    }

    const leaves = try self.allocator.alloc(AttrEntryView, total_leaves);
    errdefer self.allocator.free(leaves);
    const tails = try self.allocator.alloc(AttrEntryView, total_tails);
    errdefer self.allocator.free(tails);
    const Cursors = struct { leaf: usize = 0, tail: usize = 0 };
    const cursors = try self.allocator.alloc(Cursors, groups.len);
    defer self.allocator.free(cursors);
    @memset(cursors, .{});

    var leaf_start: usize = 0;
    for (groups, builds.items) |*group, build| {
        const leaf_end = leaf_start + build.leaf_count;
        group.leaves = leaves[leaf_start..leaf_end];
        leaf_start = leaf_end;
    }

    var tail_start: usize = 0;
    for (groups, builds.items) |*group, build| {
        const tail_end = tail_start + build.tail_count;
        group.tails = tails[tail_start..tail_end];
        tail_start = tail_end;
    }

    for (entries, name_ids) |entry, name_id| {
        const index = group_index.get(name_id).?;
        const group = &groups[index];
        const cursor = &cursors[index];
        if (entry.path.len == 1) {
            group.leaves[cursor.leaf] = entry;
            cursor.leaf += 1;
            continue;
        }
        group.tails[cursor.tail] = .{
            .path = entry.path[1..],
            .expr = entry.expr,
            .inherit_outer = entry.inherit_outer,
            .inherit_group = entry.inherit_group,
            .inherit_slot = entry.inherit_slot,
            // Keep the outermost segment so the nested set reports the attr
            // path's start position for its desugared segments.
            .origin = entry.origin orelse entry.path[0],
        };
        cursor.tail += 1;
    }

    self.allocator.free(name_ids);
    return .{ .groups = groups, .leaves = leaves, .tails = tails };
}

pub fn emitAttrNameId(self: *Compiler, name_id: InternId) !void {
    const name_val = Value.string(name_id);
    try self.builder.emitConstant(self.allocator, name_val);
}
