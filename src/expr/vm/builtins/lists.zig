//! Nix list builtins: length/head/tail, map/filter/concatMap/genList,
//! sort/partition/groupBy, foldl', elem/elemAt, seq/deepSeq, and
//! genericClosure.
//! map/genList/filter fan per-element apply-thunks out to worker fibers for
//! parallel evaluation (speculative and demand-safe).

const std = @import("std");
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const heap_mod = @import("runtime").heap;
const int_mod = @import("runtime").int;
const numeric = @import("runtime").numeric;
const shared = @import("shared.zig");
const strings = @import("strings.zig");
const attrsets = @import("attrsets.zig");
const vm_force = @import("../force.zig");
const vm_equality = @import("../equality.zig");
const vm_closures = @import("../closures.zig");
const vm_strings = @import("../strings.zig");

const isCallable = strings.isCallable;
const isPlainString = strings.isPlainString;
const stringTextInternId = strings.stringTextInternId;

pub fn builtinLength(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isList()) return error.TypeError;
    return Value.int(@intCast(try self.heap.getListLen(value.asObjectId())));
}

pub fn builtinHead(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isList()) return error.TypeError;
    const items = try self.heap.getList(value.asObjectId());
    if (items.len == 0) return error.IndexOutOfBounds;
    return vm_force.forceValue(self, items[0]);
}

pub fn builtinTail(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isList()) return error.TypeError;
    const items = try self.heap.getList(value.asObjectId());
    if (items.len == 0) return error.IndexOutOfBounds;
    return Value.list(try self.heap.addList(items[1..]));
}

pub fn builtinConcatLists(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isList()) return error.TypeError;

    const list_id = value.asObjectId();
    const lists = try self.heap.getList(list_id);
    vm_force.forceListAccelerate(self, list_id, lists);
    const list_values = try self.allocator.alloc(Value, lists.len);
    defer self.allocator.free(list_values);
    // A forced outer thunk points at its result, but root the resolved lists
    // explicitly as well: this keeps the direct-builder contract independent
    // of how each outer element was represented.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    const n = lists.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const list_item = try self.heap.getListItem(list_id, i);
        const list = try vm_force.forceValue(self, list_item);
        if (!list.isList()) return error.TypeError;
        list_values[i] = list;
        vm_force.rootKeep(self, list);
    }

    return Value.list(try self.heap.addConcatenatedListValues(list_values));
}

pub fn builtinListToAttrs(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isList()) return error.TypeError;

    const name_id = try self.intern.intern("name");
    const value_id = try self.intern.intern("value");
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    // Nix records each result attr's position as the position of the `value`
    // attribute inside the corresponding list element.
    var positions: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
    defer positions.deinit(self.allocator);
    var entry_idx: shared.NameIndex = .{};
    defer entry_idx.deinit(self.allocator);

    const list_id = value.asObjectId();
    const n = try self.heap.getListLen(list_id);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const item_value = try vm_force.forceValue(self, item);
        if (!item_value.isAttrs()) return error.TypeError;

        const name_value = try vm_force.forceValue(self, try self.heap.getAttrValue(item_value.asObjectId(), name_id));
        if (!isPlainString(name_value)) return error.TypeError;
        // Constructive boundary: the name WILL exist, so heap-resident
        // text interns here.
        const name_intern = try vm_strings.stringNameId(self, name_value);
        if ((try entry_idx.find(self.allocator, entries.items, name_intern)) != null) continue;

        try entries.append(self.allocator, .{
            .name = name_intern,
            .value = try self.heap.getAttrValue(item_value.asObjectId(), value_id),
        });
        try entry_idx.record(self.allocator, name_intern, entries.items.len - 1);
        if (self.heap.getAttrPos(item_value.asObjectId(), value_id)) |pos| {
            try positions.append(self.allocator, .{ .name = name_intern, .pos = pos });
        }
    }

    if (positions.items.len == 0) return Value.attrs(try self.heap.addAttrs(entries.items));
    return Value.attrs(try self.heap.addAttrsWithPositions(entries.items, positions.items));
}

pub fn callComparator(self: *VM, cmp: Value, left: Value, right: Value) !bool {
    const partial = try vm_closures.callValue(self, cmp, left);
    const result = try vm_force.forceValue(self, try vm_closures.callValue(self, partial, right));
    if (!result.isBool()) return error.TypeError;
    return result.asBool();
}

/// A hashcode for a forced `genericClosure` key that respects
/// `valuesEqualForced`: equal keys MUST share a hashcode (collisions are
/// fine — they fall back to an exact compare). Numerics hash by their
/// float value (so `1 == 1.0` and the int/float merge rule both hold),
/// with `-0.0` normalized to `0.0`. String-likes hash by their canonical
/// text intern id (string equality is id equality). Compound keys
/// (lists/attrs/closures/...) share one sentinel bucket and are exhaustively
/// compared without inflating the simple-key buckets.
fn gcKeyMix(tag: u64, x: u64) u64 {
    var h = (tag *% 0x9E3779B97F4A7C15) ^ x;
    h *%= 0xC2B2AE3D27D4EB4F;
    return h ^ (h >> 31);
}

fn gcKeyHashCode(self: *VM, key: Value) !u64 {
    if (numeric.isNumeric(key)) {
        const f = try numeric.toFloat(key, self.heap);
        const norm: f64 = if (f == 0.0) 0.0 else f; // collapse -0.0 -> 0.0
        return gcKeyMix(1, @bitCast(norm));
    }
    if (vm_equality.isStringComparable(key)) {
        // Content hash, not intern id: equal keys MUST share a hashcode,
        // and a heap-resident string can be byte-equal to an interned one
        // while having no id at all.
        return gcKeyMix(2, std.hash.Wyhash.hash(0, try vm_strings.stringBytes(self, key)));
    }
    return switch (key.kind()) {
        .null => 3,
        .bool_false => 4,
        .bool_true => 5,
        else => 6, // compound: shared sentinel bucket, exhaustively compared
    };
}

/// Nix's ordering classes, as `CompareValues` sees them: numbers order with
/// numbers, strings with strings, paths with paths, lists lexicographically
/// with lists, and nothing else orders at all. Strings carrying context are
/// ordinary strings here — only `path` is set apart.
const KeyOrder = enum { number, string, path, list, unorderable };

fn keyOrder(key: Value) KeyOrder {
    if (numeric.isNumeric(key)) return .number;
    if (key.isPath()) return .path;
    if (vm_equality.isStringComparable(key)) return .string;
    if (key.isList()) return .list;
    return .unorderable;
}

/// Errors exactly where Nix's `CompareValues` would on this pair, without
/// computing the ordering itself — the answer only gates the insert.
fn requireOrderableKeys(self: *VM, key: Value, other: Value) anyerror!void {
    const order = keyOrder(key);
    if (order == .unorderable or order != keyOrder(other)) return error.TypeError;
    if (order != .list) return;
    return requireOrderableLists(self, key, other);
}

/// Lists order element-wise, so an element pair can be unorderable in turn.
/// Equal elements are skipped, so equal-but-unorderable ones (two identical
/// attrsets) don't spuriously error — same rule as `equality.compareValues`.
fn requireOrderableLists(self: *VM, key: Value, other: Value) anyerror!void {
    const left_id = key.asObjectId();
    const right_id = other.asObjectId();
    const n = @min(try self.heap.getListLen(left_id), try self.heap.getListLen(right_id));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Re-fetch each element by index: forcing one can move the segment.
        const left = try vm_force.forceValue(self, try self.heap.getListItem(left_id, i));
        const right = try vm_force.forceValue(self, try self.heap.getListItem(right_id, i));
        if (try vm_equality.valuesEqual(self, left, right)) continue;
        return requireOrderableKeys(self, left, right);
    }
}

/// O(1)-amortized deduplication for `genericClosure` keys. Buckets use
/// `gcKeyHashCode`; membership is confirmed by `valuesEqualForced`.
pub const GcKeySet = struct {
    index: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(Value)) = .empty,
    seen: vm_equality.EqualityPairSet = .empty,
    /// Any one key already in the set, plus its order class. Nix stores keys
    /// in an ORDERED set, so every insertion into a non-empty set compares
    /// the new key against at least one resident key and fails when that pair
    /// has no ordering. A mismatch errors on the spot, so all resident keys
    /// share one class and a single representative decides exactly as the
    /// tree does. Caching the class keeps the check to one classification per
    /// key; only list keys need the representative value itself.
    representative: ?Value = null,
    representative_order: KeyOrder = undefined,

    pub fn deinit(self: *GcKeySet, allocator: std.mem.Allocator) void {
        var it = self.index.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        self.index.deinit(allocator);
        self.seen.deinit(allocator);
    }

    /// True if `key` was already present (skip it); otherwise inserts it
    /// and returns false.
    fn contains(self: *GcKeySet, vm: *VM, key: Value) !bool {
        // Before dedup: Nix orders first, and can only conclude equality from
        // the very comparison it would have failed on.
        if (self.representative) |rep| {
            const order = keyOrder(key);
            if (order == .unorderable or order != self.representative_order) return error.TypeError;
            if (order == .list) try requireOrderableLists(vm, key, rep);
        } else {
            self.representative = key;
            self.representative_order = keyOrder(key);
        }
        const hc = try gcKeyHashCode(vm, key);
        const gop = try self.index.getOrPut(vm.allocator, hc);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |stored| {
            self.seen.clearRetainingCapacity();
            if (try vm_equality.valuesEqualForced(vm, key, stored, &self.seen)) return true;
        }
        try gop.value_ptr.append(vm.allocator, key);
        return false;
    }
};

pub fn genericClosureAppend(
    self: *VM,
    key_name: InternId,
    item: Value,
    result: *std.ArrayListUnmanaged(Value),
    keys: *GcKeySet,
) !void {
    const forced = try vm_force.forceValue(self, item);
    if (!forced.isAttrs()) return error.TypeError;
    const key = try vm_force.forceValue(self, try self.heap.getAttrValue(forced.asObjectId(), key_name));
    if (try keys.contains(self, key)) return;
    try result.append(self.allocator, item);
}

pub fn builtinElemAt(self: *VM, list_arg: Value, index_arg: Value) !Value {
    const list = try vm_force.forceValue(self, list_arg);
    const index = try vm_force.forceValue(self, index_arg);
    if (!list.isList() or !int_mod.isAnyInt(index)) return error.TypeError;
    const idx = int_mod.get(index, self.heap);
    if (idx < 0) return error.IndexOutOfBounds;

    const items = try self.heap.getList(list.asObjectId());
    if (idx > std.math.maxInt(usize)) return error.IndexOutOfBounds;
    const i: usize = @intCast(idx);
    if (i >= items.len) return error.IndexOutOfBounds;
    return vm_force.forceValue(self, items[i]);
}

pub fn builtinElem(self: *VM, needle: Value, list_arg: Value) !Value {
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    return Value.boolVal(try vm_equality.listContainsValue(self, needle, list.asObjectId()));
}

// seq/deepSeq are general forcing operations, not list-specific, but they
// live here grouped as sequence operations.
pub fn builtinSeq(self: *VM, first: Value, second: Value) !Value {
    _ = try vm_force.forceValue(self, first);
    return vm_force.forceValue(self, second);
}

pub fn builtinDeepSeq(self: *VM, first: Value, second: Value) !Value {
    try vm_force.forceDeep(self, first);
    return vm_force.forceValue(self, second);
}

pub fn builtinAll(self: *VM, pred_arg: Value, list_arg: Value) !Value {
    const pred = try vm_force.forceValue(self, pred_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const n = try self.heap.getListLen(list_id);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const result = try vm_force.forceValue(self, try vm_closures.callValue(self, pred, item));
        if (!result.isBool()) return error.TypeError;
        if (!result.asBool()) return Value.boolVal(false);
    }
    return Value.boolVal(true);
}

pub fn builtinAny(self: *VM, pred_arg: Value, list_arg: Value) !Value {
    const pred = try vm_force.forceValue(self, pred_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const n = try self.heap.getListLen(list_id);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const result = try vm_force.forceValue(self, try vm_closures.callValue(self, pred, item));
        if (!result.isBool()) return error.TypeError;
        if (result.asBool()) return Value.boolVal(true);
    }
    return Value.boolVal(false);
}

pub fn builtinFilter(self: *VM, pred_arg: Value, list_arg: Value) !Value {
    const pred = try vm_force.forceValue(self, pred_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const n = try self.heap.getListLen(list_id);

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    const items = try self.heap.getList(list_id);
    vm_force.forceListAccelerate(self, list_id, items);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const result = try vm_force.forceValue(self, try vm_closures.callValue(self, pred, item));
        if (!result.isBool()) return error.TypeError;
        if (result.asBool()) try out.append(self.allocator, item);
    }

    return Value.list(try self.heap.addList(out.items));
}

pub fn builtinMap(self: *VM, fn_arg: Value, list_arg: Value) !Value {
    const func = try vm_force.forceValue(self, fn_arg);
    if (!try isCallable(self, func)) return error.NotCallable;
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const items = try self.heap.getList(list.asObjectId());
    const out = try self.allocator.alloc(Value, items.len);
    defer self.allocator.free(out);

    // `genlist_apply` only calls `upvalues[0] upvalues[1]`, so it also serves
    // list elements and avoids a distinct wrapper closure for each one.
    const apply_chunk_id = self.registry.well_known.genlist_apply;
    const speculatable = shared.isSpeculatableUserFunc(self, func);
    for (items, out) |item, *mapped| {
        const tid = try self.heap.addBytecodeThunk(apply_chunk_id, &.{ func, item });
        if (speculatable) _ = self.workers.submitSpeculativeThunk(tid, self.workerId());
        mapped.* = Value.thunk(tid);
    }
    return Value.list(try self.heap.addList(out));
}

pub fn builtinMapValue(self: *VM, func_arg: Value, item_arg: Value) !Value {
    const func = try vm_force.forceValue(self, func_arg);
    return vm_closures.callValue(self, func, item_arg);
}

pub fn builtinConcatMap(self: *VM, fn_arg: Value, list_arg: Value) !Value {
    const func = try vm_force.forceValue(self, fn_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.forceListAccelerate(self, list_id, items);
    const mapped_lists = try self.allocator.alloc(Value, items.len);
    defer self.allocator.free(mapped_lists);
    // GC: mapped_lists holds NEW lists produced by `func` — not reachable
    // through any argument — across later iterations' forces. Root each one.
    // The final direct heap builder copies their elements exactly once.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    const n = items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const mapped = try vm_force.forceValue(self, try vm_closures.callValue(self, func, item));
        if (!mapped.isList()) return error.TypeError;
        vm_force.rootKeep(self, mapped);
        mapped_lists[i] = mapped;
    }
    return Value.list(try self.heap.addConcatenatedListValues(mapped_lists));
}

pub fn builtinGenList(self: *VM, fn_arg: Value, count_arg: Value) !Value {
    const func = try vm_force.forceValue(self, fn_arg);
    const count = try vm_force.forceValue(self, count_arg);
    if (!int_mod.isAnyInt(count)) return error.TypeError;
    const count_i = int_mod.get(count, self.heap);
    if (count_i < 0 or count_i > std.math.maxInt(usize)) return error.TypeError;

    const len: usize = @intCast(count_i);
    const out = try self.allocator.alloc(Value, len);
    defer self.allocator.free(out);

    // Each element is one bytecode thunk over `genlist_apply`, with upvalues
    // `[func, index]`. Submit heavy user functions for speculative forcing.
    const apply_chunk_id = self.registry.well_known.genlist_apply;
    const speculatable = shared.isSpeculatableUserFunc(self, func);
    for (out, 0..) |*value, i| {
        // Abandon a speculative genList of a never-demanded result rather
        // than allocate the whole list (see force.specBailRequested).
        if (i & 8191 == 0 and vm_force.specBailRequested(self)) return error.SpeculativeBail;
        const tid = try self.heap.addBytecodeThunk(apply_chunk_id, &.{ func, Value.int(@intCast(i)) });
        if (speculatable) _ = self.workers.submitSpeculativeThunk(tid, self.workerId());
        value.* = Value.thunk(tid);
    }
    return Value.list(try self.heap.addList(out));
}

pub fn builtinSort(self: *VM, cmp_arg: Value, list_arg: Value) !Value {
    const cmp = try vm_force.forceValue(self, cmp_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.forceListAccelerate(self, list_id, items);
    const sorted = try self.allocator.dupe(Value, items);
    defer self.allocator.free(sorted);

    // Block sort: O(n log n) comparisons, O(1) scratch, and stable — Nix's
    // `sort` is `std::stable_sort`, so equal elements keep their input order.
    // Its comparator cannot fail, so the first comparator error is parked in
    // `ctx` and rethrown; later comparisons short-circuit without user code.
    const Ctx = struct {
        vm: *VM,
        cmp: Value,
        err: ?anyerror = null,

        fn lessThan(ctx: *@This(), left: Value, right: Value) bool {
            if (ctx.err != null) return false;
            return callComparator(ctx.vm, ctx.cmp, left, right) catch |err| {
                ctx.err = err;
                return false;
            };
        }
    };
    var ctx: Ctx = .{ .vm = self, .cmp = cmp };
    std.mem.sort(Value, sorted, &ctx, Ctx.lessThan);
    if (ctx.err) |err| return err;

    return Value.list(try self.heap.addList(sorted));
}

pub fn builtinPartition(self: *VM, pred_arg: Value, list_arg: Value) !Value {
    const pred = try vm_force.forceValue(self, pred_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    var right: std.ArrayListUnmanaged(Value) = .empty;
    defer right.deinit(self.allocator);
    var wrong: std.ArrayListUnmanaged(Value) = .empty;
    defer wrong.deinit(self.allocator);

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.forceListAccelerate(self, list_id, items);
    const n = items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const result = try vm_force.forceValue(self, try vm_closures.callValue(self, pred, item));
        if (!result.isBool()) return error.TypeError;
        if (result.asBool()) {
            try right.append(self.allocator, item);
        } else {
            try wrong.append(self.allocator, item);
        }
    }

    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("right"), .value = Value.list(try self.heap.addList(right.items)) },
        .{ .name = try self.intern.intern("wrong"), .value = Value.list(try self.heap.addList(wrong.items)) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn builtinGroupBy(self: *VM, fn_arg: Value, list_arg: Value) !Value {
    const func = try vm_force.forceValue(self, fn_arg);
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const Group = struct {
        name: InternId,
        items: std.ArrayListUnmanaged(Value) = .empty,
    };
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    defer {
        for (groups.items) |*group| group.items.deinit(self.allocator);
        groups.deinit(self.allocator);
    }
    var group_idx: shared.NameIndex = .{};
    defer group_idx.deinit(self.allocator);

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.forceListAccelerate(self, list_id, items);
    const n = items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const key = try vm_force.forceValue(self, try vm_closures.callValue(self, func, item));
        if (!isPlainString(key)) return error.TypeError;
        // Constructive name boundary: groupBy keys become attr names.
        const key_id = try vm_strings.stringNameId(self, key);
        const index = (try group_idx.find(self.allocator, groups.items, key_id)) orelse blk: {
            try groups.append(self.allocator, .{ .name = key_id });
            const idx = groups.items.len - 1;
            try group_idx.record(self.allocator, key_id, idx);
            break :blk idx;
        };
        try groups.items[index].items.append(self.allocator, item);
    }

    const entries = try self.allocator.alloc(heap_mod.AttrEntry, groups.items.len);
    defer self.allocator.free(entries);
    for (groups.items, entries) |group, *entry| {
        entry.* = .{
            .name = group.name,
            .value = Value.list(try self.heap.addList(group.items.items)),
        };
    }
    return Value.attrs(try self.heap.addAttrs(entries));
}

pub fn builtinGenericClosure(self: *VM, arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, arg);
    if (!attrs.isAttrs()) return error.TypeError;

    const start_set = try vm_force.forceValue(self, try self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("startSet")));
    const operator = try vm_force.forceValue(self, try self.heap.getAttrValue(attrs.asObjectId(), try self.intern.intern("operator")));
    if (!start_set.isList()) return error.TypeError;

    var result: std.ArrayListUnmanaged(Value) = .empty;
    defer result.deinit(self.allocator);
    var keys: GcKeySet = .{};
    defer keys.deinit(self.allocator);

    // GC: `result` (a Zig-side list) holds items from `start_set` (reachable
    // through the arg) and from NEW lists `operator` produces, read back across
    // later forces. Root each produced list so its items — and thus `result`'s
    // contents and the `keys` set — stay alive.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);

    const key_name = try self.intern.intern("key");
    const start_id = start_set.asObjectId();
    const start_n = try self.heap.getListLen(start_id);
    var s: usize = 0;
    while (s < start_n) : (s += 1) {
        const item = try self.heap.getListItem(start_id, s);
        try genericClosureAppend(self, key_name, item, &result, &keys);
    }

    var index: usize = 0;
    while (index < result.items.len) : (index += 1) {
        const produced = try vm_force.forceValue(self, try vm_closures.callValue(self, operator, result.items[index]));
        if (!produced.isList()) return error.TypeError;
        vm_force.rootKeep(self, produced);
        const produced_id = produced.asObjectId();
        const produced_n = try self.heap.getListLen(produced_id);
        var p: usize = 0;
        while (p < produced_n) : (p += 1) {
            const item = try self.heap.getListItem(produced_id, p);
            try genericClosureAppend(self, key_name, item, &result, &keys);
        }
    }

    return Value.list(try self.heap.addList(result.items));
}

pub fn builtinFoldlStrict(self: *VM, op_arg: Value, nul_arg: Value, list_arg: Value) !Value {
    const op = try vm_force.forceValue(self, op_arg);
    // The initial accumulator stays lazy — Nix's foldl' is not strict in the
    // seed, so `foldl' (_: x: x) (throw "…") xs` never forces the throw. Only
    // each op *result* is forced, below.
    var acc = nul_arg;
    const list = try vm_force.forceValue(self, list_arg);
    if (!list.isList()) return error.TypeError;

    const list_id = list.asObjectId();
    const items = try self.heap.getList(list_id);
    vm_force.forceListAccelerate(self, list_id, items);
    // GC: `acc` becomes a NEW value produced by `op` (not reachable through any
    // argument) and is held across the next iteration's call/force. Root the
    // running accumulator so it survives collection between iterations. (`op`
    // and `list`/its elements are covered by the arg roots; the seed `nul_arg`
    // is an arg until the first iteration overwrites `acc`.)
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    const n = items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const item = try self.heap.getListItem(list_id, i);
        const partial = try vm_closures.callValue(self, op, acc);
        acc = try vm_force.forceValue(self, try vm_closures.callValue(self, partial, item));
        vm_force.rootKeep(self, acc);
    }

    return acc;
}
