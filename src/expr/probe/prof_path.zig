//! Force-call-tree / critical-path profiler. Build-gated on
//! `-Dprof-path`; off-build compiles to no-ops with zero footprint.
//!
//! WHY. `-Dprof-main` tells you which C++-level routines burn cycles,
//! but not which *Nix source* the eval spends its time in, and nothing
//! tells you the **critical path** — the longest chain of dependent
//! thunk forces, which is the floor the parallel evaluator can't beat
//! no matter how many workers it has.
//!
//! HOW. Run at `--workers=1`: forcing is then cleanly nested (one
//! fiber, LIFO on the C stack), so every `forceThunkImpl` claim is a
//! span that contains exactly the spans of the thunks it forced. We
//! record each span's wall ticks (`base.timebase`) and its parent,
//! keyed by the body chunk (≈ a Nix source location).
//!
//! From that tree we compute, per span:
//!   total = wall cycles of the whole subtree
//!   self  = total − Σ child totals          (this body's own compute)
//!   span  = self + max(child span)           (critical path through it)
//! The root `span` is the critical-path length; following the
//! max-span child from the root enumerates the chain. Because
//! independent sibling forces would run in *parallel* at high worker
//! counts, `max` (not `sum`) over children models the multi-worker
//! floor, so the reported path is a lower-bound model rather than a
//! prediction for a particular worker count.
//!
//! IMPORTANT attribution caveat. Spans nest on thunk *forces* only, not
//! on direct closure calls (`do_call`/`call_tail` push a frame and keep
//! running in the same dispatch loop). So work done in a directly-called
//! closure that does not itself force a thunk is charged to the *forcing*
//! chunk's self-time, not to the callee. A driver chunk like the overlay
//! fixpoint (`prev // overlay final prev`) can therefore charge overlay work
//! to the forcing chunk rather than the merge. Read the flat profile as
//! "which forcing site drives call work", not "which operation is hot";
//! use `-Dprof-main` for operation-level attribution.
//!
//! This is a workers=1 tool. At higher worker counts fibers interleave
//! and the LIFO assumption breaks; `enter`/`exit` then self-guard and
//! the data is meaningless. Run it as:
//!   zig build -Doptimize=ReleaseFast -Dprof-path
//!   ./zig-out/bin/fix eval --file X --workers=1 --stats 2>&1

const std = @import("std");
const build_options = @import("build_options");
const BuiltinId = @import("runtime").builtins.BuiltinId;
const InternTable = @import("runtime").intern.InternTable;
const ChunkRegistry = @import("../bytecode.zig").chunk.ChunkRegistry;
const worker_id = @import("base").worker_id;
const timebase = @import("base").timebase;

pub const enabled: bool = build_options.prof_path and timebase.supported;

/// Key space (chunk ids on a NixOS toplevel top out in the low
/// millions, far under builtin_key_base):
///   key < builtin_key_base        → a real `ChunkId` (bytecode/closure body)
///   builtin_key_base + builtin_id → a builtin body
///   pass_through_key / other_key → synthetic
pub const builtin_key_base: u32 = 0xFF00_0000;
pub const pass_through_key: u32 = 0xFFFF_0001;
pub const other_key: u32 = 0xFFFF_0002;

const sentinel: u32 = std.math.maxInt(u32);

const Record = struct {
    key: u32,
    self_cy: u64,
    span_cy: u64,
    total_cy: u64,
    /// Index of the child with the largest `span_cy` (the next link on
    /// the critical path), or sentinel for a leaf.
    crit_child: u32,
};

const Frame = struct {
    key: u32,
    start: u64,
    child_total: u64,
    max_child_span: u64,
    max_child_idx: u32,
};

const stack_cap: usize = 4096;

// Worker-0-only state; written single-threaded under `--workers=1`.
var records: std.ArrayListUnmanaged(Record) = .empty;
var stack: [stack_cap]Frame = undefined;
var stack_len: usize = 0;
/// The top-level force subtree with the largest span — the deepest
/// single dependency chain we observed. (The top frame triggers many
/// independent top-level forces; we report the heaviest one.)
var root_idx: u32 = sentinel;
var root_span: u64 = 0;
var overflowed: bool = false;

inline fn rdtsc() u64 {
    return timebase.read();
}

/// Begin a force span keyed by `key`. Returns a token for `exit`, or a
/// sentinel on disabled builds / helper threads / stack overflow.
pub inline fn enter(key: u32) usize {
    if (!enabled) return std.math.maxInt(usize);
    if (worker_id.currentId() != 0) return std.math.maxInt(usize);
    if (stack_len >= stack_cap) {
        overflowed = true;
        return std.math.maxInt(usize);
    }
    const idx = stack_len;
    stack[idx] = .{
        .key = key,
        .start = rdtsc(),
        .child_total = 0,
        .max_child_span = 0,
        .max_child_idx = sentinel,
    };
    stack_len += 1;
    return idx;
}

/// End the span opened by `enter`. No-op on disabled builds; self-
/// guards against unbalanced calls (e.g. if a fiber yielded mid-span
/// at >1 worker).
pub inline fn exit(token: usize) void {
    if (!enabled) return;
    if (token == std.math.maxInt(usize)) return;
    if (stack_len == 0 or stack_len - 1 != token) return;
    const now = rdtsc();
    const frame = stack[token];
    stack_len -= 1;
    const total = now -% frame.start;
    const self_cy = total -% frame.child_total;
    const span = self_cy +% frame.max_child_span;

    const rec_idx: u32 = @intCast(records.items.len);
    records.append(std.heap.page_allocator, .{
        .key = frame.key,
        .self_cy = self_cy,
        .span_cy = span,
        .total_cy = total,
        .crit_child = frame.max_child_idx,
    }) catch return;

    if (stack_len > 0) {
        const parent = &stack[stack_len - 1];
        parent.child_total +%= total;
        if (span > parent.max_child_span) {
            parent.max_child_span = span;
            parent.max_child_idx = rec_idx;
        }
    } else if (span > root_span) {
        root_span = span;
        root_idx = rec_idx;
    }
}

const Agg = struct { self_cy: u64 = 0, total_cy: u64 = 0, calls: u64 = 0 };

/// Print the critical path and a flat source-attributed profile.
pub fn report(registry: *const ChunkRegistry, intern: *const InternTable) void {
    if (!enabled) return;
    const w = std.debug;
    if (records.items.len == 0) {
        w.print("prof-path: no spans recorded (run with --workers=1)\n", .{});
        return;
    }
    if (overflowed) w.print("prof-path: WARNING force depth exceeded {d}; data truncated\n", .{stack_cap});

    // ---- heaviest force subtree: walk root -> max-span child ----
    // NOTE: an OPTIMISTIC chain — independent sibling forces are modeled
    // as parallel (span = self + max child). Real data dependencies
    // between siblings aren't captured, so this under-estimates the true
    // critical path. Use the flat profile below for ground-truth self
    // time; use this to see one deep dependency chain by source.
    if (root_idx != sentinel) {
        const root = records.items[root_idx];
        w.print("prof-path: heaviest force subtree (optimistic span={d} cy; siblings modeled as parallel)\n", .{root.span_cy});
        var idx = root_idx;
        var depth: usize = 0;
        while (idx != sentinel and depth < 80) : (depth += 1) {
            const r = records.items[idx];
            const pct: u64 = if (root.span_cy == 0) 0 else r.self_cy * 100 / root.span_cy;
            w.print("  {d:>3}. self={d:>12} ({d:>2}%) {s}\n", .{ depth, r.self_cy, pct, locName(registry, intern, r.key) });
            idx = r.crit_child;
        }
        if (idx != sentinel) w.print("  ... (truncated)\n", .{});
    }

    // ---- flat profile: aggregate by key, top-20 by self ----
    var map: std.AutoHashMapUnmanaged(u32, Agg) = .empty;
    defer map.deinit(std.heap.page_allocator);
    for (records.items) |r| {
        const gop = map.getOrPut(std.heap.page_allocator, r.key) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.self_cy +%= r.self_cy;
        gop.value_ptr.total_cy +%= r.total_cy;
        gop.value_ptr.calls += 1;
    }
    const Slot = struct { key: u32, agg: Agg };
    var top: [20]Slot = .{Slot{ .key = sentinel, .agg = .{} }} ** 20;
    var it = map.iterator();
    while (it.next()) |e| {
        const self_cy = e.value_ptr.self_cy;
        var slot: usize = 20;
        for (top, 0..) |t, i| {
            if (self_cy > t.agg.self_cy) {
                slot = i;
                break;
            }
        }
        if (slot < 20) {
            var j: usize = 19;
            while (j > slot) : (j -= 1) top[j] = top[j - 1];
            top[slot] = Slot{ .key = e.key_ptr.*, .agg = e.value_ptr.* };
        }
    }
    w.print("prof-path: flat profile (top-20 by self cycles; {d} spans, {d} distinct bodies)\n", .{ records.items.len, map.count() });
    for (top) |t| {
        if (t.key == sentinel) break;
        w.print("  self={d:>12} total={d:>12} calls={d:>9} {s}\n", .{ t.agg.self_cy, t.agg.total_cy, t.agg.calls, locName(registry, intern, t.key) });
    }
}

var name_scratch: [512]u8 = undefined;

pub fn locName(registry: *const ChunkRegistry, intern: *const InternTable, key: u32) []const u8 {
    if (key == pass_through_key) return "<pass_through cell>";
    if (key == other_key) return "<other>";
    if (key >= builtin_key_base) {
        const id: u16 = @intCast(key - builtin_key_base);
        return std.fmt.bufPrint(&name_scratch, "<builtin {s}>", .{@import("runtime").builtins.displayName(@enumFromInt(id))}) catch "<builtin>";
    }
    const ch = registry.get(key) orelse return "<unknown chunk>";
    if (ch.source_map.len == 0)
        return std.fmt.bufPrint(&name_scratch, "<no source map: chunk={d} code_len={d} arity={d} locals={d}>", .{
            key, ch.code.len, ch.arity, ch.local_count,
        }) catch "<no source map>";
    // Smallest enclosing span at pc 0 — the body's defining location.
    var best: ?@TypeOf(ch.source_map[0]) = null;
    for (ch.source_map) |entry| {
        if (0 < entry.start or 0 >= entry.end) {
            if (entry.start != 0) continue;
        }
        if (best == null or entry.end - entry.start <= best.?.end - best.?.start) best = entry;
    }
    const span = (best orelse return "<no span>").span;
    const file = if (span.file) |fid| intern.get(fid) else "?";
    return std.fmt.bufPrint(&name_scratch, "{s}:{d}:{d}", .{ file, span.line, span.column }) catch "<fmt err>";
}

test "the path probe follows the build flag on every supported arch" {
    if (!build_options.prof_path) return error.SkipZigTest;
    if (!timebase.supported) return error.SkipZigTest;
    try std.testing.expect(enabled);
    try std.testing.expect(rdtsc() != 0);
}
