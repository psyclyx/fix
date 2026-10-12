//! Per-task-class census for the `-Dprof-main` profiler. Sizes what each
//! scheduled work-item CLASS delivers per item (counts, no-op rate,
//! useful-cycle distribution). Split out of `prof.zig`; recorded via
//! `taskCensusRecord` from any worker and dumped by `report()`.

const std = @import("std");
const prof = @import("prof.zig");
const enabled = prof.enabled;
const pct = prof.pct;

/// Per-task-class census (piggybacks on `-Dprof-main`). Every SCHEDULED
/// work item pays a fixed dispatch cost (queue push + wake + steal +
/// fiber acquire/reset/swap) before any useful work; this census sizes
/// what each task CLASS actually delivers per item:
///   - counts per class (creation-spec / novel-lane / urgent fan-out
///     force_thunk, list ranges, and attr sweeps);
///   - the no-op rate: tasks whose target was ALREADY fully resolved on
///     arrival (pure scheduling overhead);
///   - the useful-work cycle distribution (log2 buckets) for the rest.
/// Recorded at fiber entry (slotEntry/contEntry) from any worker —
/// shared monotonic atomics. Cycles are wall-rdtsc across the task,
/// including suspended time.
pub const TaskClass = enum(u8) {
    /// Creation-time speculative `force_thunk` (bulk spec lane).
    spec_thunk,
    /// First-instance-of-chunk `force_thunk` (novel lane, FIX_SPEC_NOVEL).
    novel_thunk,
    /// Demand fan-out `force_thunk` (urgent lane: fanOutAttrsShallow,
    /// drv-attr fan-out, strictness-driven submits).
    urgent_thunk,
    /// `force_list_range` batch (urgent lane).
    list_range,
    /// `force_attrs_sweep` whole-set sweep (FIX_SIBLING).
    attrs_sweep,
    /// `force_attrs_range` batch (urgent lane).
    attrs_range,
    /// Speculative import prefetch (FIX_IMPORT_PREFETCH; spec lane).
    import_prefetch,
    /// Speculative readDir-children prefetch (FIX_READDIR_PREFETCH;
    /// urgent lane).
    readdir_prefetch,
};
pub const task_class_count = @typeInfo(TaskClass).@"enum".field_names.len;
pub const task_cycle_buckets = 26; // bucket i = task cycles in [2^i, 2^(i+1))

const AtomicU64 = std.atomic.Value(u64);
const tc_zero: AtomicU64 = AtomicU64.init(0);
/// Tasks seen per class.
pub var tc_n: [task_class_count]AtomicU64 = @splat(tc_zero);
/// Of `tc_n`, tasks that found ZERO unresolved work on arrival.
pub var tc_noop: [task_class_count]AtomicU64 = @splat(tc_zero);
/// force_thunk tasks whose target arrived `.evaluating` (another fiber
/// owns it — the task can only spin/enroll, never compute).
pub var tc_busy: [task_class_count]AtomicU64 = @splat(tc_zero);
/// Items covered by range/sweep tasks (1 for force_thunk) and how many
/// of those were still unresolved thunks on arrival.
pub var tc_items: [task_class_count]AtomicU64 = @splat(tc_zero);
pub var tc_items_live: [task_class_count]AtomicU64 = @splat(tc_zero);
/// Task cycles, split by whether the task had any unresolved work.
pub var tc_cy_useful: [task_class_count]AtomicU64 = @splat(tc_zero);
pub var tc_cy_noop: [task_class_count]AtomicU64 = @splat(tc_zero);
/// log2 histogram of per-task cycles for tasks WITH work.
pub var tc_hist: [task_class_count][task_cycle_buckets]AtomicU64 = @splat(@splat(tc_zero));

pub fn taskCensusRecord(class: TaskClass, live_items: u64, total_items: u64, arrived_busy: bool, cycles: u64) void {
    if (!enabled) return;
    const ci = @backingInt(class);
    _ = tc_n[ci].fetchAdd(1, .monotonic);
    _ = tc_items[ci].fetchAdd(total_items, .monotonic);
    _ = tc_items_live[ci].fetchAdd(live_items, .monotonic);
    if (arrived_busy) _ = tc_busy[ci].fetchAdd(1, .monotonic);
    if (live_items == 0) {
        _ = tc_noop[ci].fetchAdd(1, .monotonic);
        _ = tc_cy_noop[ci].fetchAdd(cycles, .monotonic);
        return;
    }
    _ = tc_cy_useful[ci].fetchAdd(cycles, .monotonic);
    const lg: usize = if (cycles == 0) 0 else @min(63 - @clz(cycles), task_cycle_buckets - 1);
    _ = tc_hist[ci][lg].fetchAdd(1, .monotonic);
}

/// Per-task-class census: what each scheduled item delivered.
pub fn report() void {
    var any: u64 = 0;
    for (&tc_n) |*n| any += n.load(.monotonic);
    if (any != 0) {
        std.debug.print("prof task-census (per scheduled item; cycles incl. suspended wall):\n", .{});
        var ci: usize = 0;
        while (ci < task_class_count) : (ci += 1) {
            const n = tc_n[ci].load(.monotonic);
            if (n == 0) continue;
            const noop = tc_noop[ci].load(.monotonic);
            const busy = tc_busy[ci].load(.monotonic);
            const items = tc_items[ci].load(.monotonic);
            const live = tc_items_live[ci].load(.monotonic);
            const cy_u = tc_cy_useful[ci].load(.monotonic);
            const cy_n = tc_cy_noop[ci].load(.monotonic);
            const useful_n = n - noop;
            std.debug.print(
                "  {s}: n={d} noop={d} ({d:.1}%) busy_arrival={d} items={d} live_items={d} ({d:.1}%) useful_cy={d} (avg={d}) noop_cy={d} (avg={d})\n",
                .{
                    @tagName(@as(TaskClass, @fromBackingInt(@intCast(ci)))),
                    n,
                    noop,
                    pct(noop, n),
                    busy,
                    items,
                    live,
                    pct(live, items),
                    cy_u,
                    if (useful_n == 0) 0 else cy_u / useful_n,
                    cy_n,
                    if (noop == 0) 0 else cy_n / noop,
                },
            );
            std.debug.print("    cy-hist:", .{});
            for (&tc_hist[ci], 0..) |*b, i| {
                const v = b.load(.monotonic);
                if (v == 0) continue;
                std.debug.print(" [2^{d}]={d}", .{ i, v });
            }
            std.debug.print("\n", .{});
        }
    }
}
