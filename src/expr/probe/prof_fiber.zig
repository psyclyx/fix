//! Fiber cost/benefit census for the `-Dprof-main` profiler. Sizes what
//! the fiber machinery costs (dispatch + swap cycles per task) and what
//! it buys (how many tasks suspend; peak concurrent live fibers). Split
//! out of `prof.zig`; workers accumulate locally and flush via
//! `fiberFlush`, with `report()` dumping the totals.

const std = @import("std");
const prof = @import("prof.zig");
const enabled = prof.enabled;
const pct = prof.pct;

/// Fiber cost/benefit census (piggybacks on `-Dprof-main`). Sizes what
/// the fiber machinery costs (dispatch + swap cycles per task) and what
/// it buys (how many tasks ever suspend; how many fibers are live
/// concurrently). Workers accumulate locally (see `Worker`'s census
/// fields) and flush here via `fiberFlush`; `fib_live*` is the one
/// shared-atomic piece (a concurrent gauge can't be thread-local).
pub const FiberLocal = struct {
    /// Tasks started on a freshly-reset fiber (slot/top-level).
    tasks: u64 = 0,
    /// Tasks that ran to completion (fiber reached `.finished`).
    finished: u64 = 0,
    /// Of `finished`, tasks that suspended at least once mid-run.
    finished_suspended: u64 = 0,
    /// `runFiber` calls (first runs + resumes after wake).
    resumes: u64 = 0,
    /// Resumes that ended in another suspension.
    suspend_events: u64 = 0,
    /// Fresh fiber allocations vs free-list recycles.
    allocs: u64 = 0,
    free_hits: u64 = 0,
    /// rdtsc cycles: acquire+assign+`inner.reset` (task dispatch).
    cy_dispatch: u64 = 0,
    /// rdtsc cycles: runFiber entry → first instruction inside the fiber
    /// body (run_mu, timeline branch, spec-ctx refresh, swap-in).
    cy_in: u64 = 0,
    n_in: u64 = 0,
    /// rdtsc cycles: last instruction inside the fiber body → end of
    /// runFiber's bookkeeping (swap-out, state switch, free-list push,
    /// cross-worker nudge).
    cy_out: u64 = 0,
    n_out: u64 = 0,
    /// log2 histogram of suspend counts per suspending task
    /// (bucket i = task suspended in [2^i, 2^(i+1)) times).
    susp_hist: [16]u64 = @splat(0),
};

pub var fib_totals_mu: std.atomic.Value(u8) = .init(0); // spin flag
pub var fib_totals: FiberLocal = .{};
/// Worker 0's slice of the totals — the demand thread IS the wall clock,
/// so its overhead share bounds the fiber machinery's critical-path cost.
pub var fib_totals_w0: FiberLocal = .{};

/// Merge a worker's local fiber census into the global totals and zero
/// the local. Called on park (natural batching point) and at drain-loop
/// exit, always from the owning thread.
pub fn fiberFlush(local: *FiberLocal, is_worker0: bool) void {
    if (!enabled) return;
    while (fib_totals_mu.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer fib_totals_mu.store(0, .release);
    fiberMergeInto(&fib_totals, local);
    if (is_worker0) fiberMergeInto(&fib_totals_w0, local);
    local.* = .{};
}

fn fiberMergeInto(t: *FiberLocal, local: *const FiberLocal) void {
    t.tasks += local.tasks;
    t.finished += local.finished;
    t.finished_suspended += local.finished_suspended;
    t.resumes += local.resumes;
    t.suspend_events += local.suspend_events;
    t.allocs += local.allocs;
    t.free_hits += local.free_hits;
    t.cy_dispatch += local.cy_dispatch;
    t.cy_in += local.cy_in;
    t.n_in += local.n_in;
    t.cy_out += local.cy_out;
    t.n_out += local.n_out;
    for (&t.susp_hist, local.susp_hist) |*th, l| th.* += l;
}

/// Concurrent live-fiber gauge: fibers currently assigned to a task
/// (running or suspended). Incremented at every reset-for-task site,
/// decremented when the fiber finishes. Sampled into a linear histogram
/// at each increment — biased toward busy phases, which is exactly the
/// "does the live count spike past the worker count?" question.
pub const fiber_live_buckets = 129; // 0..127 exact, last bucket = >=128
pub var fib_live: std.atomic.Value(u32) = .init(0);
pub var fib_live_max: std.atomic.Value(u32) = .init(0);
pub var fib_live_hist: [fiber_live_buckets]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));

pub inline fn fiberLiveInc() void {
    if (!enabled) return;
    const now = fib_live.fetchAdd(1, .monotonic) + 1;
    const bucket: usize = @min(now, fiber_live_buckets - 1);
    _ = fib_live_hist[bucket].fetchAdd(1, .monotonic);
    var cur = fib_live_max.load(.monotonic);
    while (now > cur) {
        cur = fib_live_max.cmpxchgWeak(cur, now, .monotonic, .monotonic) orelse break;
    }
}

pub inline fn fiberLiveDec() void {
    if (!enabled) return;
    _ = fib_live.fetchSub(1, .monotonic);
}

/// Mean ticks per event, as a fraction. Per-swap fiber costs are tens of
/// nanoseconds, which is well under one tick of a coarse counter (the aarch64
/// generic timer runs at ~25 MHz), so an integer mean reads 0 and hides the
/// cost entirely.
fn meanTicks(cycles: u64, n: u64) f64 {
    if (n == 0) return 0;
    return @as(f64, @floatFromInt(cycles)) / @as(f64, @floatFromInt(n));
}

/// Fiber cost/benefit census.
pub fn report() void {
    const f = &fib_totals;
    if (f.tasks != 0) {
        const rtc = f.finished - f.finished_suspended;
        std.debug.print(
            "prof fibers: tasks={d} finished={d} run_to_completion={d} ({d:.2}%) ever_suspended={d} ({d:.2}%)\n",
            .{ f.tasks, f.finished, rtc, pct(rtc, f.finished), f.finished_suspended, pct(f.finished_suspended, f.finished) },
        );
        std.debug.print(
            "prof fibers: resumes={d} suspend_events={d} allocs={d} free_hits={d}\n",
            .{ f.resumes, f.suspend_events, f.allocs, f.free_hits },
        );
        const total_over = f.cy_dispatch + f.cy_in + f.cy_out;
        std.debug.print(
            "prof fibers: cy_dispatch={d} cy_in={d} (n={d} avg={d:.3}) cy_out={d} (n={d} avg={d:.3}) total_overhead_cy={d}\n",
            .{
                f.cy_dispatch,
                f.cy_in,
                f.n_in,
                meanTicks(f.cy_in, f.n_in),
                f.cy_out,
                f.n_out,
                meanTicks(f.cy_out, f.n_out),
                total_over,
            },
        );
        const w0 = &fib_totals_w0;
        std.debug.print(
            "prof fibers w0: tasks={d} resumes={d} suspend_events={d} cy_dispatch={d} cy_in={d} cy_out={d} total_overhead_cy={d}\n",
            .{ w0.tasks, w0.resumes, w0.suspend_events, w0.cy_dispatch, w0.cy_in, w0.cy_out, w0.cy_dispatch + w0.cy_in + w0.cy_out },
        );
        std.debug.print("prof fibers: suspends-per-suspending-task hist:", .{});
        for (f.susp_hist, 0..) |n, i| {
            if (n == 0) continue;
            std.debug.print(" [2^{d}]={d}", .{ i, n });
        }
        std.debug.print("\n", .{});
        std.debug.print("prof fibers: live-at-task-start hist:", .{});
        for (&fib_live_hist, 0..) |*n, i| {
            const v = n.load(.monotonic);
            if (v == 0) continue;
            if (i == fiber_live_buckets - 1) {
                std.debug.print(" [>={d}]={d}", .{ i, v });
            } else {
                std.debug.print(" [{d}]={d}", .{ i, v });
            }
        }
        std.debug.print(" (max={d})\n", .{fib_live_max.load(.monotonic)});
    }
}
