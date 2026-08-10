//! Lightweight tick-counter profiler for the main thread's hot
//! serial paths. Build-gated on `-Dprof-main`; off-build compiles
//! to no-ops with zero runtime footprint. `base.timebase` supplies the
//! counter, so one tick is a TSC cycle on x86_64 and a generic-timer
//! tick on aarch64.
//!
//! Helpers don't update counters (we only care about main's serial
//! pathlength). Each evaluator fiber owns its nesting stack, so suspension
//! cannot splice another fiber's scopes into its exclusions. If a fiber
//! migrates away from worker 0, its open main-thread scopes are discarded;
//! only complete regions executed on worker 0 reach the plain counters.
//!
//! **Exclusive time.** A per-fiber call stack tracks the nested
//! instrumented scopes; at `end`, the inclusive delta is recorded
//! as the sample's exclusive cycles, *minus* time already attributed
//! to nested child scopes. The parent's `child_exclusion` then
//! absorbs the popped scope's inclusive delta. This means the
//! printed cycles for each path are wall-cycles spent *inside that
//! routine but not inside any inner instrumented routine* — what
//! you want for finding bottlenecks.
//!
//! The large census/report blocks live in focused sibling files
//! (`prof_age.zig`, `prof_task.zig`, `prof_fiber.zig`, `prof_census.zig`);
//! this file keeps the core stack profiler and orchestrates their
//! `report()` output. Re-export shims below keep external call sites
//! resolving `prof.<name>`.

const std = @import("std");
const InternTable = @import("runtime").intern.InternTable;
const ChunkRegistry = @import("../bytecode.zig").chunk.ChunkRegistry;
const build_options = @import("build_options");
const worker_id = @import("base").worker_id;
const timebase = @import("base").timebase;
const BuiltinId = @import("runtime").builtins.BuiltinId;
const prof_path_mod = @import("prof_path.zig");
const prof_age = @import("prof_age.zig");
const prof_task = @import("prof_task.zig");
const prof_fiber = @import("prof_fiber.zig");
const prof_census = @import("prof_census.zig");

/// Compile-time switch. False when `-Dprof-main` wasn't passed.
/// The probe needs a tick counter, so it also gates on the architecture.
pub const enabled: bool = build_options.prof_main and timebase.supported;

/// Tag for every instrumented path. Keep names short — they appear
/// in the stats line as-is.
pub const Path = enum {
    /// `force.forceValue` end-to-end, including both fast and slow
    /// thunk paths. Covers explicit caller forces.
    force_value,
    /// `forceThunkImpl` slow path — the thunk was not already
    /// resolved when `forceValue` peeked.
    force_thunk_slow,
    /// `access.getAttrValue` — attr lookup (post-force on the
    /// attrs operand, post-cached-lookup, post-force on the result).
    get_attr_value,
    /// `closures.callValue` — helper-callable closure entry.
    call_value,
    /// `closures.doCall` — interpreter-side closure entry.
    do_call,
    /// `closures.doTailCall` — interpreter-side closure tail entry.
    do_tail_call,
    /// `closures.runIsolatedFrame` — bytecode runner for a
    /// freshly-pushed frame.
    run_isolated_frame,
    /// `closures.makeBytecodeThunkFromCaptures` — non-trivial path
    /// (when the trivial-body short-circuit didn't apply).
    make_bytecode_thunk,
    /// Time spent in `Fiber.yield()` when a force hits a `.busy`
    /// thunk — the fiber suspends until the resolver wakes it. While
    /// suspended, worker 0 may run other fibers / drain tasks; the
    /// TSC doesn't stop, so this cycles count is wall-clock cycles,
    /// not CPU-cycles. A same-worker resume records the whole wait;
    /// a migration discards the open scope rather than attributing
    /// another worker's clock interval to worker 0.
    wait_busy_thunk,
    /// Time spent in `parkAndAccount` on worker 0 (the OS thread
    /// running main) when its ready queue is empty. Pure idle time
    /// from main's perspective; if this is large, helpers aren't
    /// keeping main fed.
    park_main_worker,
    /// `builtins.applyBuiltin` outer dispatch — covers the entire
    /// inline body of whichever builtin matched. A large share of
    /// `do_call` exclusive time usually lands here when the callee
    /// is `.isBuiltin()` or `.isBuiltinClosure()`.
    apply_builtin,
    /// `//` attrset update (`opMergeAttrs` + `opMergeAttrsStrict`) —
    /// the sorted merge-walk over two attrsets. Hot on the overlay
    /// fixpoint (`prev // overlay final prev`).
    merge_attrs,
    /// `Parser.parse` — tokenize + build the AST for an imported file.
    parse,
    /// `Compiler.compileAndFinish` — AST → bytecode for an imported file.
    compile,
    /// `chunk_cache.load` — decode a cached unit and register its chunks,
    /// which replaces `parse` + `compile` on a cache hit. Without this scope
    /// the work has no bucket of its own, so it lands in the exclusive time of
    /// whichever builtin drove the import and makes `import` look slow. The
    /// file read is not included; it happens before this scope opens.
    chunk_cache_load,
    /// `strictness.stampOnBuilder` — per-chunk strictness analysis (a
    /// second AST walk building NameSets). Sub-phase of `compile`; its
    /// exclusive cycles are carved out of the `compile` bucket.
    strictness,
    /// `let_float.rewriteLet` — the demand-driven binding-placement pass
    /// (graph walk + decisions + rebuild). Sub-phase of `compile`; its
    /// exclusive cycles are carved out of the `compile` bucket.
    let_float,
    /// `core.analyze` — the cluster graph walk alone. Sub-phase of
    /// `let_float`.
    let_float_walk,
    /// `normalizeDerivation` — env-string assembly, attr walk, string
    /// dupes, context scans. Sub-phase of the `derivationLazyAttr` /
    /// `derivation` builtin bodies; nested force/call regions are
    /// carved out, so EXCL here is the raw assembly cost.
    drv_normalize,
    /// `Drv.computePaths` — ATerm serializations + sha256 +
    /// hashModuloInputs. No nested regions; EXCL is the whole phase.
    drv_compute,
    /// `derivation.buildValue`/`buildStrictValue` — result attrset
    /// construction after paths are known.
    drv_build_value,
};

pub const Sample = struct {
    calls: u64 = 0,
    /// Exclusive cycles — time spent in this routine but not inside
    /// any inner instrumented routine.
    cycles: u64 = 0,
    /// Inclusive cycles — time spent in this routine including
    /// nested instrumented routines. Useful as a sanity check.
    cycles_inclusive: u64 = 0,
};

const path_count = @typeInfo(Path).@"enum".fields.len;

/// Per-path counters. Main-thread-only writes; reads (for printing)
/// happen after the eval finishes.
pub var samples: [path_count]Sample = @splat(.{});

/// Per-builtin counters (indexed by `BuiltinId`). Populated by
/// `applyBuiltin` instrumentation when the path's outer scope is
/// active. Numerator is `apply_builtin` exclusive cycles; this
/// breakdown attributes that bucket to specific builtins.
pub const max_builtin_id: usize = 256;
pub var builtin_samples: [max_builtin_id]Sample = @splat(.{});

// ---- Re-export shims. The census blocks now live in focused sibling
// files; these keep external call sites resolving `prof.<name>` for the
// functions/types/consts they reference. (Mutable census `var`s can't be
// aliased, so `prof_census` call sites are updated to import it directly.)

/// See `prof_age.ageForceBegin`.
pub const ageForceBegin = prof_age.ageForceBegin;
/// See `prof_age.ageForceEnd`.
pub const ageForceEnd = prof_age.ageForceEnd;
/// See `prof_age.age_old_threshold`.
pub const age_old_threshold = prof_age.age_old_threshold;

/// See `prof_task.TaskClass`.
pub const TaskClass = prof_task.TaskClass;
/// See `prof_task.taskCensusRecord`.
pub const taskCensusRecord = prof_task.taskCensusRecord;

/// See `prof_fiber.FiberLocal`.
pub const FiberLocal = prof_fiber.FiberLocal;
/// See `prof_fiber.fiberFlush`.
pub const fiberFlush = prof_fiber.fiberFlush;
/// See `prof_fiber.fiberLiveInc`.
pub const fiberLiveInc = prof_fiber.fiberLiveInc;
/// See `prof_fiber.fiberLiveDec`.
pub const fiberLiveDec = prof_fiber.fiberLiveDec;

/// Read TSC unconditionally. Used by `recordBuiltin` to get an
/// inclusive timestamp without going through the prof stack.
pub inline fn tscMainOnly() u64 {
    if (!enabled) return 0;
    if (worker_id.currentId() != 0) return 0;
    return rdtsc();
}

/// Record one call to `builtin_id`. `start` is the value returned
/// by `tscMainOnly()` at builtin entry; the inclusive delta is
/// recorded against `builtin_samples[builtin_id]`. No exclusive-
/// time bookkeeping — the breakdown is just to identify the few
/// builtins whose total wall share is biggest.
pub inline fn recordBuiltin(builtin_id: u16, t_start: u64) void {
    if (!enabled) return;
    if (worker_id.currentId() != 0) return;
    if (t_start == 0) return;
    if (builtin_id >= max_builtin_id) return;
    const inclusive = rdtsc() - t_start;
    const s = &builtin_samples[builtin_id];
    s.calls += 1;
    s.cycles += inclusive;
    s.cycles_inclusive += inclusive;
}

const no_builtin: u16 = std.math.maxInt(u16);

const StackFrame = struct {
    path: Path,
    start_tsc: u64,
    /// Sum of inclusive deltas of nested instrumented calls that
    /// have already returned. Used to compute exclusive time at end.
    child_exclusion: u64,
    /// For an `apply_builtin` frame opened via `startBuiltin`, the
    /// builtin whose EXCLUSIVE time this frame should be attributed to
    /// (`builtin_samples`). `no_builtin` otherwise.
    builtin_id: u16 = no_builtin,
};

// Large enough that nested force instrumentation does not truncate and
// attribute dropped regions to a shallower ancestor.
const stack_cap: usize = 4096;

/// Fiber-owned instrumentation state. WorkerFiber compiles one of these into
/// each migratable fiber only in `-Dprof-main` builds. `generation` makes
/// tokens opened before a migration reset incapable of matching later scopes.
pub const Stack = struct {
    frames: [stack_cap]StackFrame = undefined,
    len: usize = 0,
    generation: u32 = 1,

    fn reset(self: *Stack) void {
        self.len = 0;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }
};

/// The active fiber stack on this OS thread. Bare worker-0 work (parse,
/// compile, parking) uses a separate TLS stack because it runs outside a
/// fiber. `Worker.runFiber` installs/removes the fiber pointer around resume.
threadlocal var active_stack: ?*Stack = null;
threadlocal var bare_stack: Stack = .{};

pub inline fn enterFiber(stack: *Stack) void {
    if (!enabled) return;
    std.debug.assert(active_stack == null);
    active_stack = stack;
    // A token opened on worker 0 must never close on a helper or survive a
    // round-trip migration back to worker 0. Resetting here invalidates every
    // open token through the generation check in end().
    if (worker_id.currentId() != 0 and stack.len != 0) stack.reset();
}

pub inline fn leaveFiber() void {
    if (!enabled) return;
    active_stack = null;
}

/// Start a new task on a recycled fiber with no profiler state inherited from
/// its previous task. Incrementing the generation also invalidates a token
/// from malformed control flow that escaped the old task's unwind.
pub inline fn resetFiber(stack: *Stack) void {
    if (!enabled) return;
    stack.reset();
}

inline fn currentStack() *Stack {
    return active_stack orelse &bare_stack;
}

inline fn token(stack: *const Stack, idx: usize) u64 {
    return (@as(u64, stack.generation) << 32) | @as(u64, @intCast(idx));
}

/// Read the tick counter. The unit is one tick of `base.timebase`: a TSC
/// cycle on x86_64, a generic-timer tick on aarch64. The name stays `rdtsc`
/// because `prof_age.zig`, `prof_census.zig` and `vm/force.zig` call it.
pub inline fn rdtsc() u64 {
    if (!enabled) return 0;
    return timebase.read();
}

/// Start a measurement on the main thread. Returns a sentinel
/// (UINT64_MAX) on helpers and on disabled builds; the matching
/// `end` ignores that case. The real returned value is the
/// generation + stack index of the pushed frame.
pub inline fn start(comptime path: Path) u64 {
    if (!enabled) return std.math.maxInt(u64);
    if (worker_id.currentId() != 0) return std.math.maxInt(u64);
    const stack = currentStack();
    if (stack.len >= stack_cap) return std.math.maxInt(u64);
    const idx = stack.len;
    stack.frames[idx] = .{
        .path = path,
        .start_tsc = rdtsc(),
        .child_exclusion = 0,
    };
    stack.len += 1;
    return token(stack, idx);
}

/// Like `start(.apply_builtin)` but tags the frame so its EXCLUSIVE
/// cycles are also attributed to `builtin_samples[builtin_id]` at
/// `end` — giving a per-builtin breakdown of the `apply_builtin`
/// bucket that excludes nested instrumented work (force/call/etc.),
/// i.e. the builtin's own body cost. Pair with `end(.apply_builtin, _)`.
pub inline fn startBuiltin(builtin_id: u16) u64 {
    if (!enabled) return std.math.maxInt(u64);
    if (worker_id.currentId() != 0) return std.math.maxInt(u64);
    const stack = currentStack();
    if (stack.len >= stack_cap) return std.math.maxInt(u64);
    const idx = stack.len;
    stack.frames[idx] = .{
        .path = .apply_builtin,
        .start_tsc = rdtsc(),
        .child_exclusion = 0,
        .builtin_id = builtin_id,
    };
    stack.len += 1;
    return token(stack, idx);
}

/// End a measurement started by `start`. No-op on disabled builds
/// and helper threads.
pub inline fn end(comptime path: Path, t: u64) void {
    if (!enabled) return;
    if (t == std.math.maxInt(u64)) return;
    if (worker_id.currentId() != 0) return;
    const stack = currentStack();
    const generation: u32 = @intCast(t >> 32);
    const idx: usize = @intCast(t & std.math.maxInt(u32));
    if (generation != stack.generation) return;
    const now = rdtsc();
    // The expected stack invariant: `t` indexes the topmost frame
    // and its path matches what we pushed. Tolerate mismatches by
    // unwinding only if depth is consistent — defensive guard
    // against unexpected control-flow that bypasses defer.
    if (stack.len == 0 or stack.len - 1 != idx) return;
    const frame = &stack.frames[idx];
    if (frame.path != path) return;
    const inclusive = now - frame.start_tsc;
    const exclusive = inclusive - frame.child_exclusion;
    const s = &samples[@intFromEnum(path)];
    s.calls += 1;
    s.cycles += exclusive;
    s.cycles_inclusive += inclusive;
    if (frame.builtin_id != no_builtin and frame.builtin_id < max_builtin_id) {
        const b = &builtin_samples[frame.builtin_id];
        b.calls += 1;
        b.cycles += exclusive;
        b.cycles_inclusive += inclusive;
    }
    stack.len -= 1;
    // Attribute the popped scope's inclusive delta to the parent's
    // child_exclusion so the parent's exclusive time skips it.
    if (stack.len > 0) {
        stack.frames[stack.len - 1].child_exclusion += inclusive;
    }
}

/// Print the mean exclusive ticks per call, then end the line.
///
/// The mean is fractional on purpose. Integer division discards everything
/// below one tick, and one tick is 40 ns on a 25 MHz counter — more than a
/// cheap scope such as `force_value` costs, which made its average read as
/// zero. The mean itself keeps the resolution the counter appears to lack,
/// because each measurement's error is its phase against the tick edge and
/// those errors cancel over millions of calls.
///
/// `avg_ns` appears only when the counter states its rate. See
/// `base.timebase.toNs`.
fn printAvgExcl(cycles: u64, calls: u64) void {
    if (calls == 0) {
        std.debug.print("\n", .{});
        return;
    }
    const avg = @as(f64, @floatFromInt(cycles)) / @as(f64, @floatFromInt(calls));
    if (timebase.toNs(avg)) |ns| {
        std.debug.print(" avg_excl={d:.3} avg_ns={d:.1}\n", .{ avg, ns });
    } else {
        std.debug.print(" avg_excl={d:.3}\n", .{avg});
    }
}

/// Dump the main-thread path + per-builtin cycle samples
/// (`--stats`). Lives beside the counters it reads.
/// `registry`/`intern` resolve chunk keys to source locations for the
/// age-at-force per-body breakdown (same shapes as `prof_path.report`).
pub fn report(registry: *const ChunkRegistry, intern: *const InternTable) void {
    timebase.reportLine("prof");
    inline for (@typeInfo(Path).@"enum".fields) |f| {
        const samp = samples[f.value];
        if (samp.calls != 0) {
            std.debug.print("prof: {s}: excl_cy={d} incl_cy={d} calls={d}", .{
                f.name,
                samp.cycles,
                samp.cycles_inclusive,
                samp.calls,
            });
            printAvgExcl(samp.cycles, samp.calls);
        }
    }
    // String-machinery census.
    prof_census.reportStrConcat();
    // Top builtins by inclusive cycles on main.
    const top_count = 40;
    const BSlot = struct { id: u16, cycles: u64, incl: u64, calls: u64 };
    var top_b: [top_count]BSlot = .{BSlot{ .id = 0, .cycles = 0, .incl = 0, .calls = 0 }} ** top_count;
    for (builtin_samples, 0..) |samp, id| {
        if (samp.calls == 0) continue;
        var slot: usize = top_count;
        for (top_b, 0..) |entry, i| {
            if (samp.cycles > entry.cycles) {
                slot = i;
                break;
            }
        }
        if (slot < top_count) {
            var j: usize = top_count - 1;
            while (j > slot) : (j -= 1) top_b[j] = top_b[j - 1];
            top_b[slot] = .{ .id = @intCast(id), .cycles = samp.cycles, .incl = samp.cycles_inclusive, .calls = samp.calls };
        }
    }
    std.debug.print("prof builtins (top-{d} by EXCL cycles — own-body cost):\n", .{top_count});
    for (top_b) |entry| {
        if (entry.cycles == 0) break;
        const name = @import("runtime").builtins.displayName(@enumFromInt(entry.id));
        std.debug.print("  {s}: excl={d} incl={d} calls={d}", .{ name, entry.cycles, entry.incl, entry.calls });
        printAvgExcl(entry.cycles, entry.calls);
    }
    // Attr inline-cache, thunk-memo, repeat-force, and attr-lookup size censuses.
    prof_census.reportCaches();
    // Duplicate-resolve census (full-laziness payoff).
    @import("prof_dup.zig").report(registry, intern);
    // Fiber cost/benefit census.
    prof_fiber.report();
    // Per-task-class census: what each scheduled item delivered.
    prof_task.report();
    // Discovery-serialization breakdown of main's demand forces.
    prof_census.reportDiscovery();
    // Coverage-miss breakdown: of the forces main computed itself, how many
    // did speculation never aim at (targeting gap) vs aim-at-but-lose.
    prof_census.reportCoverage();
    // Strict-collection-walk size census: are main's walks mostly small
    // (unfannable, sub-threshold) — aggregate parallelism fan-out can't reach?
    prof_census.reportStrictWalks(&prof_census.list_walks, "list");
    prof_census.reportStrictWalks(&prof_census.attrs_walks, "attrs");
    // Age-at-force breakdown of main's claimed demand-forces.
    prof_age.report(registry, intern);
}

pub fn pct(x: u64, total: u64) f64 {
    return if (total == 0) @as(f64, 0) else 100.0 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(total));
}

test "fiber profiler stack invalidates scopes on worker migration" {
    if (!enabled) return error.SkipZigTest;

    const saved_worker = worker_id.state();
    defer worker_id.set(saved_worker.id, saved_worker.is_worker);

    var stack: Stack = .{};
    worker_id.set(0, true);
    enterFiber(&stack);
    const stale = start(.force_value);
    try std.testing.expectEqual(@as(usize, 1), stack.len);
    leaveFiber();

    worker_id.set(1, true);
    enterFiber(&stack);
    try std.testing.expectEqual(@as(usize, 0), stack.len);
    end(.force_value, stale);
    try std.testing.expectEqual(@as(usize, 0), stack.len);
    leaveFiber();

    worker_id.set(0, true);
    enterFiber(&stack);
    end(.force_value, stale);
    try std.testing.expectEqual(@as(usize, 0), stack.len);
    leaveFiber();
}

test "fiber profiler stacks remain isolated across suspension" {
    if (!enabled) return error.SkipZigTest;

    const saved_worker = worker_id.state();
    defer worker_id.set(saved_worker.id, saved_worker.is_worker);
    worker_id.set(0, true);

    var suspended: Stack = .{};
    var other: Stack = .{};

    enterFiber(&suspended);
    const outer = start(.force_value);
    leaveFiber();

    enterFiber(&other);
    const inner = start(.get_attr_value);
    end(.get_attr_value, inner);
    try std.testing.expectEqual(@as(usize, 0), other.len);
    leaveFiber();

    enterFiber(&suspended);
    end(.force_value, outer);
    try std.testing.expectEqual(@as(usize, 0), suspended.len);
    leaveFiber();
}

test "the main probe follows the build flag on every supported arch" {
    if (!build_options.prof_main) return error.SkipZigTest;
    if (!timebase.supported) return error.SkipZigTest;
    try std.testing.expect(enabled);
    try std.testing.expect(rdtsc() != 0);
}
