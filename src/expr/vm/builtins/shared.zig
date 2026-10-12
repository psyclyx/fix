//! Helpers shared across the builtin families: builtin-thunk/closure
//! construction, the recursive-JSON cycle guard (SeenJsonObject), and the
//! adaptive name->index lookup (NameIndex) for accumulate-by-name builtins.

const std = @import("std");
const VM = @import("../context.zig").VM;
const Value = @import("runtime").value.Value;
const BuiltinId = @import("runtime").builtins.BuiltinId;
const InternId = @import("runtime").types.InternId;
const ObjectId = @import("runtime").types.ObjectId;
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_equality = @import("../equality.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");
const grisu2 = @import("runtime").grisu2;

/// Format a float exactly as Nix's `builtins.toJSON` does (via nlohmann::json).
/// nlohmann's Grisu2 is usually the shortest round-tripping decimal but is not
/// always optimal, so it disagrees with Zig's Ryu (`{d}`/`{e}`) on ~0.6% of
/// doubles — enough to change a generated JSON file's bytes and every drvPath
/// built from it. `grisu2.format` is a faithful port of nlohmann's `to_chars`,
/// validated byte-for-byte against the nlohmann oracle over ~2M random doubles,
/// so this matches Nix exactly (fixed vs `e±NN` notation, the `.0` suffix, and
/// the shortest-or-one-longer digit string). Non-finite serializes as `null`.
pub const json_float_buffer_size = 512;
pub fn jsonFloatText(buf: []u8, v: f64) []const u8 {
    return grisu2.format(buf, v);
}

/// Cycle-guard for the recursive JSON writers (`toJSON`, structured
/// derivation env). A stack of (kind, id) pairs; `enterJsonObject` refuses a
/// re-entry into an object already on the stack so a self-referential
/// list/attrset raises `RecursiveThunk` instead of looping. Callers push on
/// descent and `pop()` on the way out.
pub const SeenJsonKind = enum { list, attrs };

pub const SeenJsonObject = struct {
    kind: SeenJsonKind,
    id: ObjectId,
};

pub fn enterJsonObject(self: *VM, kind: SeenJsonKind, id: ObjectId, seen: *std.ArrayListUnmanaged(SeenJsonObject)) !bool {
    for (seen.items) |item| {
        if (item.kind == kind and item.id == id) return false;
    }
    try seen.append(self.allocator, .{ .kind = kind, .id = id });
    return true;
}

pub fn makeBuiltinClosure(self: *VM, builtin_id: u16, args: []const Value) !Value {
    return Value.builtinClosure(try self.heap.addBuiltinClosure(builtin_id, args));
}

pub fn makeBuiltinThunk(self: *VM, id: BuiltinId, args: []const Value) !Value {
    return vm_force.makeThunk(self, try makeBuiltinClosure(self, @backingInt(id), args));
}

/// Cross-category helper: linear index of a group whose `.name` matches
/// `name`. Used by both `zipAttrsWith` (attrsets) and `groupBy` (lists).
pub fn groupIndex(groups: anytype, name: InternId) ?usize {
    for (groups, 0..) |group, i| {
        if (group.name == name) return i;
    }
    return null;
}

/// Adaptive name→index lookup for accumulate-by-name builtins
/// (`zipAttrsWith`, `groupBy`, `listToAttrs`). Small accumulations keep
/// the allocation-free linear scan; once the item list crosses a
/// threshold, a hash map is built once and kept in sync, replacing the
/// O(n) rescan per element (O(n²) total on large inputs — hit hard by
/// nixpkgs-scale attrset merges, but generic to any large workload).
/// Purely a lookup-structure swap: match results, and therefore
/// insertion order and output bytes, are identical.
pub const NameIndex = struct {
    map: std.AutoHashMapUnmanaged(InternId, usize) = .empty,
    built: bool = false,

    /// Linear-scan cutoff. Below this the scan is cheaper than hashing;
    /// crossing it pays one O(n) build and then O(1) per lookup.
    const streaming_threshold: usize = 32;

    pub fn deinit(self: *NameIndex, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }

    /// Index of the item whose `.name == name`, or null. `items` must be
    /// the same list every call and must only grow via `record`ed
    /// appends (names unique), so the built map stays in sync.
    pub fn find(self: *NameIndex, allocator: std.mem.Allocator, items: anytype, name: InternId) !?usize {
        if (!self.built) {
            if (items.len < streaming_threshold) return groupIndex(items, name);
            try self.map.ensureTotalCapacity(allocator, @intCast(items.len));
            for (items, 0..) |item, i| self.map.putAssumeCapacity(item.name, i);
            self.built = true;
        }
        return self.map.get(name);
    }

    /// Tell the index the caller appended `name` at `index`.
    pub fn record(self: *NameIndex, allocator: std.mem.Allocator, name: InternId, index: usize) !void {
        if (self.built) try self.map.put(allocator, name, index);
    }
};

/// Cross-category helper: the closure half of
/// `force.isSpeculatableBuiltinClosure`'s map-style branch: speculate iff
/// the user function is a `.closure` whose body chunk is substantial. (That
/// branch also speculates on expensive builtins via `isSpeculatableMapFunc`;
/// this fast path only handles the closure case.) Used by `map`/`genList`
/// (lists) and `mapAttrs` (attrsets).
pub fn isSpeculatableUserFunc(self: *VM, func: Value) bool {
    if (!func.isNixClosure()) return false;
    const closure = @import("../closures.zig").closureRef(self, func) catch return false;
    const slot = self.registry.slot(closure.chunk_id) orelse return false;
    return slot.body_is_substantial;
}
