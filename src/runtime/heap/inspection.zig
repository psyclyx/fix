//! Stable, read-only heap projection types for tooling.

const std = @import("std");
const types = @import("../types.zig");
const Value = @import("../value.zig").Value;
const ValueType = @import("../value.zig").ValueType;
const thunk_mod = @import("../thunk.zig");
const future_mod = @import("../future.zig");
const Thunk = thunk_mod.Thunk;
const prof_census_enabled = thunk_mod.created_tsc_enabled;

pub const ObjectId = types.ObjectId;
pub const ChunkId = types.ChunkId;
pub const InternId = types.InternId;

/// Bitset snapshot of currently filled object or range-store slots. Tooling
/// owns the allocation and discovers live records lazily through the bitmap.
pub const ObjectSnapshot = struct {
    allocator: std.mem.Allocator,
    live_bits: []u64,
    high_water: ObjectId,
    live_count: u32,

    pub fn deinit(self: *ObjectSnapshot) void {
        self.allocator.free(self.live_bits);
        self.* = undefined;
    }

    pub fn isLive(self: *const ObjectSnapshot, id: ObjectId) bool {
        if (id >= self.high_water) return false;
        return self.live_bits[id >> 6] & (@as(u64, 1) << @intCast(id & 63)) != 0;
    }

    pub fn nextLive(self: *const ObjectSnapshot, start: ObjectId) ?ObjectId {
        if (start >= self.high_water) return null;
        var word_index: usize = start >> 6;
        var word = self.live_bits[word_index] & (~@as(u64, 0) << @intCast(start & 63));
        while (true) {
            if (word != 0) {
                const id: ObjectId = @intCast(word_index * 64 + @ctz(word));
                return if (id < self.high_water) id else null;
            }
            word_index += 1;
            if (word_index >= self.live_bits.len) return null;
            word = self.live_bits[word_index];
        }
    }

    /// One past the greatest live id, excluding reserved or reclaimed tails.
    pub fn liveExtent(self: *const ObjectSnapshot) ObjectId {
        var word_index = self.live_bits.len;
        while (word_index > 0) {
            word_index -= 1;
            const word = self.live_bits[word_index];
            if (word == 0) continue;
            const top_bit: usize = @bitSizeOf(u64) - 1 - @clz(word);
            return @min(
                self.high_water,
                @as(ObjectId, @intCast(word_index * 64 + top_bit + 1)),
            );
        }
        return 0;
    }
};

pub const Counts = struct {
    objects: u32,
    values: u32,
    attrs: u32,
    attr_positions: u32,
    bytes: u32,
};

pub const Stats = struct {
    objects: u32,
    values: u32,
    attrs: u32,
    attr_positions: u32,
    bytes: u32,
    variant_counts: [10]u32,
    thunk_states: [5]u32,
    /// Resolved thunks split by whether a real caller demanded the value.
    resolved_demanded: u32,
    resolved_undemanded: u32,
    /// Inline integer magnitude histogram: zero, i16, i32, i48, overflow.
    int_buckets: [5]u32,

    pub fn variantName(index: usize) []const u8 {
        return switch (index) {
            0 => "list",
            1 => "attrs",
            2 => "closure",
            3 => "builtin closure",
            4 => "thunk",
            5 => "context string",
            6 => "boxed int",
            7 => "attrs merge",
            8 => "partial application",
            9 => "heap string",
            else => "?",
        };
    }

    pub fn thunkStateName(index: usize) []const u8 {
        return switch (index) {
            0 => "unresolved",
            1 => "evaluating",
            2 => "resolved",
            3 => "blackhole",
            4 => "errored",
            else => "?",
        };
    }

    pub fn intBucketLabel(index: usize) []const u8 {
        return switch (index) {
            0 => "zero",
            1 => "i16",
            2 => "i32",
            3 => "i48",
            4 => ">=2^47",
            else => "?",
        };
    }

    pub fn intTotal(self: Stats) u32 {
        var total: u32 = 0;
        for (self.int_buckets) |count| total += count;
        return total;
    }

    pub fn intOverflowsI48(self: Stats) u32 {
        return self.int_buckets[4];
    }
};

pub const ValueRef = struct {
    kind: ValueType,
    target: Target = .none,

    pub const Target = union(enum) {
        none,
        object: ObjectId,
        chunk: ChunkId,
        intern: InternId,
        builtin: u16,
    };
};

pub const HeapReference = union(enum) {
    object: ObjectId,
    chunk: ChunkId,
};

pub const ThunkState = enum(u8) { unresolved, evaluating, resolved, blackhole, errored };

pub const ThunkTargetInfo = union(enum) {
    closure: ValueRef,
    bytecode: struct { chunk: ChunkId, captures: u32 },
    pass_through: ValueRef,
    attr_access: struct { base: ValueRef, name: InternId },
    deferred: struct { id: u32, captures: u32 },
};

pub const ThunkInfo = struct {
    state: ThunkState,
    demanded: bool,
    body: union(enum) {
        target: ThunkTargetInfo,
        result: ValueRef,
        error_name: []const u8,
    },
};

pub const ObjectInfo = union(enum) {
    list: struct { len: u32 },
    attrs: struct { len: u32, positions: u32, sibling_swept: bool },
    merge_attrs: struct {
        base: ObjectId,
        overlay: ObjectId,
        depth: u16,
        flattened: ?ObjectId,
    },
    closure: struct { chunk: ChunkId, upvalues: u32 },
    builtin_closure: struct { builtin: u16, args: u32 },
    thunk: ThunkInfo,
    context_string: struct { text: InternId, context: u32 },
    boxed_int: i64,
    partial_app: struct { function: ValueRef, args: u32 },
    heap_string: struct { len: u32 },
};

pub fn thunkInfo(thunk: *const Thunk) ThunkInfo {
    const raw_state = future_mod.stateFieldRaw(thunk.future.state.load(.acquire));
    const state: ThunkState = @fromBackingInt(@intCast(@min(raw_state, @backingInt(ThunkState.errored))));
    const body: @TypeOf(@as(ThunkInfo, undefined).body) = switch (state) {
        .resolved => .{ .result = valueRef(thunk.payload.result) },
        .errored => .{ .error_name = @errorName(thunk.cachedFailure().err()) },
        .unresolved, .evaluating, .blackhole => .{ .target = switch (thunk.targetKind()) {
            .closure => .{ .closure = valueRef(thunk.payload.target.closure) },
            .bytecode => .{ .bytecode = .{
                .chunk = thunk.payload.target.bytecode.chunk_id,
                .captures = thunk.payload.target.bytecode.upvalue_count,
            } },
            .pass_through => .{ .pass_through = valueRef(thunk.payload.target.pass_through) },
            .attr_access => .{ .attr_access = .{
                .base = valueRef(thunk.payload.target.attr_access.base),
                .name = thunk.payload.target.attr_access.name,
            } },
            .deferred => .{ .deferred = .{
                .id = thunk.payload.target.deferred.deferred_id,
                .captures = thunk.payload.target.deferred.env_count,
            } },
        } },
    };
    return .{ .state = state, .demanded = thunk.isDemanded(), .body = body };
}

pub fn valueRef(value: Value) ValueRef {
    const kind = value.kind();
    const target: ValueRef.Target = switch (kind) {
        .list, .attrs, .thunk, .builtin_closure, .string_context, .boxed_int, .partial_app => .{ .object = value.asObjectId() },
        .closure => if (value.isFunction()) .{ .chunk = value.asFunctionChunkId() } else .{ .object = value.asObjectId() },
        .string, .path => .{ .intern = value.asInternId() },
        .builtin => .{ .builtin = value.asBuiltinId() },
        else => .none,
    };
    return .{ .kind = kind, .target = target };
}

pub fn objectInfo(heap: anytype, snapshot: *const ObjectSnapshot, id: ObjectId) !ObjectInfo {
    if (!snapshot.isLive(id)) return error.InvalidObjectId;
    return switch (heap.objects.get(id).*) {
        .list => |range| .{ .list = .{ .len = range.len } },
        .attrs => |attrs| .{ .attrs = .{
            .len = attrs.range.len,
            .positions = attrs.positions.len,
            .sibling_swept = heap.siblingSweepMarked(id),
        } },
        .merge_attrs => |merge| .{ .merge_attrs = .{
            .base = merge.base,
            .overlay = merge.overlay,
            .depth = merge.depth,
            .flattened = blk: {
                const flattened = merge.flattened.load(.acquire);
                break :blk if (flattened == std.math.maxInt(@TypeOf(flattened))) null else flattened;
            },
        } },
        .closure => |closure| .{ .closure = .{ .chunk = closure.chunk_id, .upvalues = closure.upvalues.len } },
        .builtin_closure => |closure| .{ .builtin_closure = .{ .builtin = closure.builtin_id, .args = closure.args.len } },
        .thunk => |*thunk| .{ .thunk = thunkInfo(thunk) },
        .context_string => |string| .{ .context_string = .{ .text = string.text, .context = string.context.len } },
        .boxed_int => |integer| .{ .boxed_int = integer },
        .partial_app => |partial| .{ .partial_app = .{ .function = valueRef(partial.func), .args = partial.args.len } },
        .heap_string => |string| .{ .heap_string = .{ .len = string.text_len } },
        .heap_string_inline => |string| .{ .heap_string = .{ .len = string.len } },
    };
}

/// Aggregate runtime stats. Safe only when there are no concurrent writers.
pub fn stats(heap: anytype) Stats {
    var result: Stats = .{
        .objects = heap.objects.count(),
        .values = heap.values.count(),
        .attrs = heap.attrs.count(),
        .attr_positions = heap.attr_positions.count(),
        .bytes = heap.bytes.count(),
        .variant_counts = @splat(0),
        .thunk_states = @splat(0),
        .resolved_demanded = 0,
        .resolved_undemanded = 0,
        .int_buckets = @splat(0),
    };

    // TLAB tails are reserved but unfilled. Exclude them from every scan.
    var obj_skip = heap.collectUnfilled(.object);
    heap.addDiscardedObjectTails(&obj_skip);
    const val_skip = heap.collectUnfilled(.value);
    const attr_skip = heap.collectUnfilled(.attr);

    var id: u32 = 0;
    scan_obj: while (id < result.objects) : (id += 1) {
        if (obj_skip.skipPast(id)) |next| {
            id = next - 1;
            continue :scan_obj;
        }
        const variant: usize = switch (heap.objects.get(id).*) {
            .list => 0,
            .attrs => 1,
            .closure => 2,
            .builtin_closure => 3,
            .thunk => |thunk| blk: {
                const state: usize = @intCast(@min(future_mod.stateFieldRaw(thunk.future.state.load(.acquire)), 4));
                result.thunk_states[state] += 1;
                if (state == 2) {
                    if (thunk.isDemanded())
                        result.resolved_demanded += 1
                    else
                        result.resolved_undemanded += 1;
                }
                break :blk 4;
            },
            .context_string => 5,
            .boxed_int => 6,
            .merge_attrs => 7,
            .partial_app => 8,
            .heap_string, .heap_string_inline => 9,
        };
        result.variant_counts[variant] += 1;
    }

    var value_id: u32 = 0;
    scan_value: while (value_id < result.values) : (value_id += 1) {
        if (val_skip.skipPast(value_id)) |next| {
            value_id = next - 1;
            continue :scan_value;
        }
        var next_id: u32 = undefined;
        const value = heap.values.getIfAllocated(value_id, &next_id) orelse {
            value_id = next_id - 1;
            continue :scan_value;
        };
        recordInt(&result.int_buckets, value.*);
    }

    var attr_id: u32 = 0;
    scan_attr: while (attr_id < result.attrs) : (attr_id += 1) {
        if (attr_skip.skipPast(attr_id)) |next| {
            attr_id = next - 1;
            continue :scan_attr;
        }
        var next_id: u32 = undefined;
        const attr_value = heap.attrs.getIfAllocated(attr_id, &next_id) orelse {
            attr_id = next_id - 1;
            continue :scan_attr;
        };
        recordInt(&result.int_buckets, attr_value.*);
    }
    return result;
}

fn recordInt(buckets: *[5]u32, value: Value) void {
    if (value.isBoxedInt()) {
        buckets[4] += 1;
        return;
    }
    if (!value.isInt()) return;
    const integer = value.asInt();
    if (integer == 0) {
        buckets[0] += 1;
        return;
    }
    const magnitude: u64 = @abs(integer);
    const index: usize = if (magnitude < (@as(u64, 1) << 15))
        1
    else if (magnitude < (@as(u64, 1) << 31))
        2
    else if (magnitude < (@as(u64, 1) << 47))
        3
    else
        4;
    buckets[index] += 1;
}

/// Exit-time census of thunk creation context versus final observation state.
pub fn creationCensus(heap: anytype) void {
    if (comptime !prof_census_enabled) return;
    const Cell = struct {
        count: u64 = 0,
        demanded_old: u64 = 0,
        demanded_young: u64 = 0,
        never_resolved_spec: u64 = 0,
        never_unresolved: u64 = 0,
        errored: u64 = 0,
    };
    var cells: [2]Cell = @splat(.{}); // demand-created, spec-created
    var skip = heap.collectUnfilled(.object);
    heap.addDiscardedObjectTails(&skip);
    var id: u32 = 0;
    scan: while (id < heap.objects.count()) : (id += 1) {
        if (skip.skipPast(id)) |next| {
            id = next - 1;
            continue :scan;
        }
        switch (heap.objects.get(id).*) {
            .thunk => |thunk| {
                const cell = &cells[if (thunk.created_demand) 0 else 1];
                cell.count += 1;
                const state = future_mod.stateFieldRaw(thunk.future.state.load(.acquire));
                if (thunk.isDemanded()) {
                    if (thunk.demanded_old)
                        cell.demanded_old += 1
                    else
                        cell.demanded_young += 1;
                } else switch (state) {
                    2 => cell.never_resolved_spec += 1,
                    3, 4 => cell.errored += 1,
                    else => cell.never_unresolved += 1,
                }
            },
            else => {},
        }
    }
    for (cells, 0..) |cell, index| {
        if (cell.count == 0) continue;
        std.debug.print(
            "prof creation-census [{s}]: n={d} demanded_old={d} ({d:.1}%) demanded_young={d} ({d:.1}%) never:spec_resolved={d} ({d:.1}%) never:unresolved={d} ({d:.1}%) errored={d}\n",
            .{
                if (index == 0) "demand-created" else "spec-created",
                cell.count,
                cell.demanded_old,
                percent(cell.demanded_old, cell.count),
                cell.demanded_young,
                percent(cell.demanded_young, cell.count),
                cell.never_resolved_spec,
                percent(cell.never_resolved_spec, cell.count),
                cell.never_unresolved,
                percent(cell.never_unresolved, cell.count),
                cell.errored,
            },
        );
    }
}

/// Exit-time census of sibling-demand speculation by attrset size.
pub fn siblingCensus(heap: anytype) void {
    if (comptime !prof_census_enabled) return;
    const bucket_lower_bounds = [_]usize{ 4, 8, 16, 32, 64, 256 };
    const Bucket = struct {
        sets: u64 = 0,
        touched: u64 = 0,
        all_demanded_sets: u64 = 0,
        members: u64 = 0,
        demanded_old: u64 = 0,
        demanded_young: u64 = 0,
        spec_resolved: u64 = 0,
        unresolved: u64 = 0,

        fn add(self: *@This(), other: @This()) void {
            self.sets += other.sets;
            self.touched += other.touched;
            self.all_demanded_sets += other.all_demanded_sets;
            self.members += other.members;
            self.demanded_old += other.demanded_old;
            self.demanded_young += other.demanded_young;
            self.spec_resolved += other.spec_resolved;
            self.unresolved += other.unresolved;
        }
    };
    var buckets: [bucket_lower_bounds.len]Bucket = @splat(.{});
    var merge_attrs_count: u64 = 0;
    var skip = heap.collectUnfilled(.object);
    heap.addDiscardedObjectTails(&skip);
    var id: u32 = 0;
    scan: while (id < heap.objects.count()) : (id += 1) {
        if (skip.skipPast(id)) |next| {
            id = next - 1;
            continue :scan;
        }
        const entries = switch (heap.objects.get(id).*) {
            .attrs => |attrs| heap.attrs.slice(attrs.range),
            .merge_attrs => {
                merge_attrs_count += 1;
                continue :scan;
            },
            else => continue :scan,
        };
        if (entries.len < bucket_lower_bounds[0]) continue :scan;
        var bucket_index: usize = bucket_lower_bounds.len - 1;
        while (entries.len < bucket_lower_bounds[bucket_index]) bucket_index -= 1;
        const bucket = &buckets[bucket_index];
        bucket.sets += 1;

        var members: u64 = 0;
        var demanded_old: u64 = 0;
        var demanded_young: u64 = 0;
        var spec_resolved: u64 = 0;
        var unresolved: u64 = 0;
        for (entries) |entry_value| {
            if (!entry_value.isThunk()) continue;
            switch (heap.objects.get(entry_value.asObjectId()).*) {
                .thunk => |thunk| {
                    members += 1;
                    if (thunk.isDemanded()) {
                        if (thunk.demanded_old)
                            demanded_old += 1
                        else
                            demanded_young += 1;
                    } else if (future_mod.stateFieldRaw(thunk.future.state.load(.acquire)) == 2) {
                        spec_resolved += 1;
                    } else {
                        unresolved += 1;
                    }
                },
                else => {},
            }
        }
        if (demanded_old + demanded_young == 0) continue :scan;
        bucket.touched += 1;
        if (demanded_old + demanded_young == members) bucket.all_demanded_sets += 1;
        bucket.members += members;
        bucket.demanded_old += demanded_old;
        bucket.demanded_young += demanded_young;
        bucket.spec_resolved += spec_resolved;
        bucket.unresolved += unresolved;
    }

    std.debug.print("prof sibling-census (attrsets by entry count; member stats over TOUCHED sets = >=1 demanded member; merge_attrs skipped n={d}):\n", .{merge_attrs_count});
    var total: Bucket = .{};
    for (buckets, 0..) |bucket, index| {
        total.add(bucket);
        if (bucket.sets == 0) continue;
        std.debug.print(
            "  size>={d:<3}: sets={d} touched={d} all_dem={d} members={d} dem_old={d} ({d:.1}%) dem_young={d} ({d:.1}%) spec_res={d} ({d:.1}%) unres={d} ({d:.1}%)\n",
            .{
                bucket_lower_bounds[index],                    bucket.sets,                                  bucket.touched,                             bucket.all_demanded_sets,                       bucket.members,
                bucket.demanded_old,                           percent(bucket.demanded_old, bucket.members), bucket.demanded_young,                      percent(bucket.demanded_young, bucket.members), bucket.spec_resolved,
                percent(bucket.spec_resolved, bucket.members), bucket.unresolved,                            percent(bucket.unresolved, bucket.members),
            },
        );
    }
    std.debug.print(
        "  TOTAL     : sets={d} touched={d} all_dem={d} members={d} dem_old={d} ({d:.1}%) dem_young={d} ({d:.1}%) spec_res={d} ({d:.1}%) unres={d} ({d:.1}%)\n",
        .{
            total.sets,          total.touched,                               total.all_demanded_sets, total.members,
            total.demanded_old,  percent(total.demanded_old, total.members),  total.demanded_young,    percent(total.demanded_young, total.members),
            total.spec_resolved, percent(total.spec_resolved, total.members), total.unresolved,        percent(total.unresolved, total.members),
        },
    );
}

fn percent(value: u64, total: u64) f64 {
    return if (total == 0) 0 else 100.0 * @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(total));
}
