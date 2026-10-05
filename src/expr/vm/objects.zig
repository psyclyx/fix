//! Data-structure builders: attrset and list literal construction from stack
//! operands, the `//` update merge (lazy layered + strict recursive), and list
//! concatenation.
const std = @import("std");
const vm_mod = @import("context.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;

const force = @import("force.zig");
const stack = @import("stack.zig");
const trace = @import("trace.zig");
const vm_strings = @import("strings.zig");

const VM = vm_mod.VM;

// ---- data structure builders ----

pub fn buildAttrs(self: *VM, count: u16) !void {
    const value_count: u32 = @as(u32, count) * 2;
    const start = self.sp - value_count;
    // Dynamic keys are arbitrary string values; a heap-string key interns
    // here — names are id-keyed. In place: the slot keeps rooting the
    // value across the intern.
    var i: u32 = 0;
    while (i < value_count) : (i += 2) {
        const key = self.stack[start + i];
        try vm_strings.rejectContext(self, key);
        if (key.isHeapString())
            self.stack[start + i] = Value.string(try vm_strings.stringNameId(self, key));
    }
    const id = try self.heap.addAttrsFromStackPairs(self.stack[start..self.sp]);
    self.sp = start;
    try stack.push(self, Value.attrs(id));
}

/// `attrs_new_named*`: entries are compile-time sorted by interned name and
/// duplicate-free — skip the construction sort. Names come from the chunk
/// side table, values are the top `count` stack slots.
pub fn buildAttrsNamedSorted(self: *VM, names: []const u32, count: u16, positions: heap_mod.AttrPositions) !void {
    const start = self.sp - count;
    const id = try self.heap.addAttrsFromValuesSorted(names, self.stack[start..self.sp], positions);
    self.sp = start;
    try stack.push(self, Value.attrs(id));
}

/// Unsorted twin of `buildAttrsNamedSorted`, dispatched by the
/// `attrs_new_named`/`attrs_new_named_pos` ops the persistent chunk cache
/// rewrites `_srt` sites to when intern-id remapping breaks their baked
/// name order (see `bytecode/chunk/cache.zig`).
pub fn buildAttrsNamed(self: *VM, names: []const u32, count: u16, positions: heap_mod.AttrPositions) !void {
    const start = self.sp - count;
    const id = try self.heap.addAttrsFromValues(names, self.stack[start..self.sp], positions);
    self.sp = start;
    try stack.push(self, Value.attrs(id));
}

pub fn buildAttrsSorted(self: *VM, count: u16, positions: []const heap_mod.AttrPosEntry) !void {
    const value_count: u32 = @as(u32, count) * 2;
    const start = self.sp - value_count;
    const id = try self.heap.addAttrsFromStackPairsSorted(self.stack[start..self.sp], positions);
    self.sp = start;
    try stack.push(self, Value.attrs(id));
}

pub fn buildList(self: *VM, count: u16) !void {
    const start = self.sp - count;
    const id = try self.heap.addList(self.stack[start..self.sp]);
    self.sp = start;
    try stack.push(self, Value.list(id));
}

pub fn mergeAttrs(self: *VM, left: Value, right: Value) !Value {
    if (!left.isAttrs()) return trace.typeErrorExpected(self, "attrs", left);
    if (!right.isAttrs()) return trace.typeErrorExpected(self, "attrs", right);
    return Value.attrs(try self.heap.mergeAttrsLayered(left.asObjectId(), right.asObjectId()));
}

pub fn mergeAttrsStrict(self: *VM, left: Value, right: Value) !Value {
    if (!left.isAttrs()) return trace.typeErrorExpected(self, "attrs", left);
    if (!right.isAttrs()) return trace.typeErrorExpected(self, "attrs", right);
    return Value.attrs(try mergeAttrLiteralObjects(self, left.asObjectId(), right.asObjectId()));
}

pub fn mergeAttrLiteralObjects(self: *VM, left_id: types.ObjectId, right_id: types.ObjectId) anyerror!types.ObjectId {
    // Recursive calls receive nested attr ids that are NOT on the operand
    // stack; root the input objects so their `left`/`right` slices survive
    // the forces inside mergeAttrLiteralValue.
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, Value.attrs(left_id));
    force.rootKeep(self, Value.attrs(right_id));

    const left = try self.heap.materializeAttrs(left_id);
    const right = try self.heap.materializeAttrs(right_id);
    const left_len = left.len();
    const right_len = right.len();

    // Reserve worst-case (no overlap) directly in heap attr storage
    // and walk both sides in lockstep, writing the merge in place.
    // Both inputs are sorted+deduped (heap invariant), so the output
    // is sorted+unique by construction. Skips a per-merge ArrayList
    // alloc + one copy compared to the staged-then-flush pattern.
    const cap: u32 = @intCast(left_len + right_len);
    const reserved = try self.heap.reserveAttrsForMerge(cap);
    errdefer self.heap.abortMergedAttrs(reserved);
    const dst = self.heap.attrsMutSlice(reserved);

    var out: usize = 0;
    var left_i: usize = 0;
    var right_i: usize = 0;
    while (left_i < left_len and right_i < right_len) {
        const ln = left.names[left_i];
        const rn = right.names[right_i];
        if (ln < rn) {
            dst.names[out] = ln;
            dst.values[out] = left.values[left_i];
            out += 1;
            left_i += 1;
        } else if (ln > rn) {
            dst.names[out] = rn;
            dst.values[out] = right.values[right_i];
            out += 1;
            right_i += 1;
        } else {
            // Duplicate name. `mergeAttrLiteralValue` reads from the
            // heap so it's safe to call while we hold a reserved
            // range — the merge target is its own segment of the
            // attr store, not the inputs we're reading.
            const value = try mergeAttrLiteralValue(self, left.values[left_i], right.values[right_i]);
            // GC: `value` is a freshly-merged young object held ONLY in the
            // reserved-but-unpublished `dst` slice — which `markVm` cannot
            // scan (it is neither on the operand stack, nor in temp-roots,
            // nor reachable through `left`/`right`, nor via the remembered
            // set, since no owning object exists until `publishMergedAttrs`).
            // A later iteration's `mergeAttrLiteralValue` forces (and may
            // park for a collection), so root `value` for the rest of the
            // merge — same discipline as concatMap/foldl'/genericClosure.
            // Without this, a collection between here and publish sweeps
            // `value` (and its subtree); its slot is reused and a stale
            // reference in the published merge later corrupts it (w>1 UAF).
            force.rootKeep(self, value);
            dst.names[out] = ln;
            dst.values[out] = value;
            out += 1;
            left_i += 1;
            right_i += 1;
        }
    }
    if (left_i < left_len) {
        const n = left_len - left_i;
        @memcpy(dst.names[out..][0..n], left.names[left_i..]);
        @memcpy(dst.values[out..][0..n], left.values[left_i..]);
        out += n;
    }
    if (right_i < right_len) {
        const n = right_len - right_i;
        @memcpy(dst.names[out..][0..n], right.names[right_i..]);
        @memcpy(dst.values[out..][0..n], right.values[right_i..]);
        out += n;
    }

    // Attach the merged position tables: without this, any attrset literal
    // containing a dynamic entry (compiled as static-part + per-entry strict
    // merges) silently loses unsafeGetAttrPos for ALL its attrs.
    const positions = try self.heap.mergeAttrPositionsStrict(left_id, right_id);
    return self.heap.publishMergedAttrsWithPositions(reserved, @intCast(out), positions);
}

pub fn mergeAttrLiteralValue(self: *VM, left: Value, right: Value) anyerror!Value {
    const left_forced = try force.forceValue(self, left);
    const right_forced = try force.forceValue(self, right);
    if (left_forced.isAttrs() and right_forced.isAttrs()) {
        return Value.attrs(try mergeAttrLiteralObjects(self, left_forced.asObjectId(), right_forced.asObjectId()));
    }
    return error.DuplicateAttribute;
}

pub fn concatLists(self: *VM, left: Value, right: Value) !Value {
    if (!left.isList()) return trace.typeErrorExpected(self, "list", left);
    if (!right.isList()) return trace.typeErrorExpected(self, "list", right);
    return Value.list(try self.heap.addConcatenatedLists(left.asObjectId(), right.asObjectId()));
}

/// `list_cat_n`: validate a right-associated concat chain in the same order as
/// the original binary operations, then build the final immutable list once.
/// For `a ++ (b ++ (c ++ d))`, binary evaluation checks c,d,b,a.
pub fn concatStackLists(self: *VM, count: u16) !Value {
    std.debug.assert(count >= 3 and self.sp >= count);
    const base = self.sp - count;

    var i: u32 = count - 2;
    if (!self.stack[base + i].isList()) return trace.typeErrorExpected(self, "list", self.stack[base + i]);
    if (!self.stack[base + i + 1].isList()) return trace.typeErrorExpected(self, "list", self.stack[base + i + 1]);
    while (i > 0) {
        i -= 1;
        if (!self.stack[base + i].isList()) return trace.typeErrorExpected(self, "list", self.stack[base + i]);
    }

    return Value.list(try self.heap.addConcatenatedListValues(self.stack[base..self.sp]));
}
