//! Resolve `FIX_*` evaluation tuning from one Engine's environment.
//!
//! The resulting `Policy` is immutable and Engine-owned. Resolution happens
//! on the Engine's first compile/evaluate operation, after callers have had a
//! chance to configure the scheduler and environment, and before any worker
//! starts.

const std = @import("std");
const scheduler_mod = @import("workers/scheduler.zig");

const EnvMap = std.process.Environ.Map;

fn envValue(env: ?*const EnvMap, name: []const u8) ?[]const u8 {
    const map = env orelse return null;
    return map.get(name);
}

fn envInt(comptime T: type, env: ?*const EnvMap, name: []const u8) ?T {
    const value = envValue(env, name) orelse return null;
    return std.fmt.parseInt(T, value, 10) catch null;
}

fn envEnabled(env: ?*const EnvMap, name: []const u8, fallback: bool) bool {
    const value = envValue(env, name) orelse return fallback;
    return !std.mem.eql(u8, value, "0");
}

fn resolveSibling(config: *scheduler_mod.Config, env: ?*const EnvMap, worker_count: u8) void {
    // Sibling prefetch needs helpers and is bounded at wider pools to avoid
    // duplicating the general speculative lanes.
    config.sibling_prefetch = envEnabled(env, "FIX_SIBLING", worker_count > 1 and worker_count <= 16);
    config.sibling_min = envInt(u32, env, "FIX_SIBLING_MIN") orelse 16;
    config.sibling_max = envInt(u32, env, "FIX_SIBLING_MAX") orelse 64;
    if (envInt(u64, env, "FIX_SIBLING_BUDGET")) |budget| {
        config.sibling_budget = budget;
        config.sibling_claim_budget = budget;
    }
    if (envInt(u64, env, "FIX_SIBLING_CLAIMS")) |budget| config.sibling_claim_budget = budget;
    config.sibling_urgent = envEnabled(env, "FIX_SIBLING_URGENT", config.sibling_urgent);
    config.sibling_log = envValue(env, "FIX_SIBLING_LOG") != null;
}

pub const PrefetchPolicy = struct {
    import_budget: u32,
    read_dir_min: u32,
    read_dir_budget: u32,
};

pub const Policy = struct {
    scheduler: scheduler_mod.Config,
    prefetch: PrefetchPolicy,
    /// Derived strings at or above this length are eligible for the GC heap.
    /// Each Engine starts from 64; environment overrides never leak between
    /// sequential or concurrent Engines.
    heap_string_min: usize = 64,
    let_float_enabled: bool = true,
    /// Full laziness (see docs/compiler/full-laziness.md): the pre-emission
    /// analysis walk at outermost lambdas plus named and anonymous-MFE
    /// float-out. Default ON since 2026-08-05 qualification;
    /// `FIX_NO_FULL_LAZY=1` is the kill switch and gates the WHOLE pass
    /// (walk, transform, and the chunk-cache key bit).
    full_lazy_enabled: bool = true,
    /// Minimum apply count inside an anonymous-MFE candidate
    /// (`FIX_FL_MFE_MIN_APPLIES`): below it, the float's per-closure thunk
    /// creation outweighs the shared work. Tuned on nixos-minimal.
    mfe_min_applies: u16 = 1,
    named_floats_enabled: bool = true,
    /// Experimental (`FIX_FL_CHAIN_SPLIT=1`): allow floats to wrap
    /// chain-inner lambdas, splitting uncurried arity-N chunks into 1-ary
    /// closures in exchange for sharing. Sizing lever for the chain-clamp
    /// coverage loss; not qualified.
    chain_split: bool = false,
    let_float_report: bool = false,
    /// Census-only (`FIX_PROF_DUP`, `-Dprof-main` builds): count repeated
    /// thunk instantiations. The structural hash costs real cycles inside
    /// spans that other counters attribute, so it stays opt-in per run.
    dup_census: bool = false,
    /// `FIX_CC_DEBUG`: print the source location at which the chunk-cache
    /// decoder rejects a blob as corrupt. See docs/compiler/chunk-cache.md.
    cc_debug: bool = false,
};

/// Resolve import and directory prefetch limits. Both require helper workers.
fn resolvePrefetch(env: ?*const EnvMap, worker_count: u8) PrefetchPolicy {
    const helpers_available = worker_count > 1;
    const import_enabled = helpers_available and envEnabled(env, "FIX_IMPORT_PREFETCH", true);
    const read_dir_enabled = helpers_available and envEnabled(env, "FIX_READDIR_PREFETCH", true);
    return .{
        .import_budget = if (import_enabled) envInt(u32, env, "FIX_IMPORT_PREFETCH_MAX") orelse 8192 else 0,
        .read_dir_min = if (read_dir_enabled) envInt(u32, env, "FIX_READDIR_PREFETCH_MIN") orelse 32 else 0,
        .read_dir_budget = if (read_dir_enabled) envInt(u32, env, "FIX_READDIR_PREFETCH_MAX") orelse 16384 else 0,
    };
}

/// Resolve scheduler, prefetch, VM, and compiler tuning into one immutable
/// value owned by the calling Engine.
pub fn resolve(
    base: scheduler_mod.Config,
    env: ?*const EnvMap,
    worker_count: u8,
) Policy {
    var config = base;

    if (envInt(u32, env, "FIX_SPEC_BACKLOG")) |value| config.spec_backlog_per_helper = value;

    // First-time chunk speculation uses the novel lane whenever helpers exist.
    config.spec_novel = envEnabled(env, "FIX_SPEC_NOVEL", worker_count > 1);

    // Limit bulk speculation drainers in wide pools. 255 disables the cap.
    config.spec_helper_cap = envInt(u8, env, "FIX_SPEC_HELPERS") orelse 16;

    // Priority inheritance when demand blocks on a speculatively-owned
    // thunk (rescue): mark it demanded, flag the owning fiber, route its
    // sub-work to the urgent lane, and exempt it from speculation budgets.
    // Opt-in and measured WALL-NEUTRAL (2026-08-06): it collapses the
    // demand chain's spec-owned wait ~1400x (6.8B -> 4.8M cy on a universe
    // chunk at w=8 under full laziness), but the wall doesn't move — the
    // waits overlap helpers computing exactly the values the chain needs
    // next, so unblocking main just shifts the same serial work onto it
    // (claimed_by_main 34% -> 47%). The wait census is pacing, not
    // recoverable headroom; wall is bound by dependency depth.
    if (envValue(env, "FIX_RESCUE") != null)
        config.spec_rescue = worker_count > 1 and envEnabled(env, "FIX_RESCUE", false);

    // Bound thunk creation by speculative tasks rooted at small chunks.
    if (envInt(u64, env, "FIX_SPEC_BAND_BUDGET")) |value| config.spec_band_budget = value;

    resolveSibling(&config, env, worker_count);

    return .{
        .scheduler = config,
        .prefetch = resolvePrefetch(env, worker_count),
        .heap_string_min = envInt(usize, env, "FIX_HEAP_STR_MIN") orelse 64,
        .let_float_enabled = !envEnabled(env, "FIX_NO_LET_FLOAT", false),
        .full_lazy_enabled = !envEnabled(env, "FIX_NO_FULL_LAZY", false),
        .mfe_min_applies = envInt(u16, env, "FIX_FL_MFE_MIN_APPLIES") orelse 1,
        .named_floats_enabled = !envEnabled(env, "FIX_FL_NAMED_OFF", false),
        .chain_split = envEnabled(env, "FIX_FL_CHAIN_SPLIT", false),
        .let_float_report = envEnabled(env, "FIX_LET_FLOAT_STATS", false),
        .dup_census = envValue(env, "FIX_PROF_DUP") != null,
        .cc_debug = envValue(env, "FIX_CC_DEBUG") != null,
    };
}

test "policy resolution is isolated per Engine environment" {
    const testing = std.testing;
    var overridden = EnvMap.init(testing.allocator);
    defer overridden.deinit();
    try overridden.put("FIX_HEAP_STR_MIN", "0");
    try overridden.put("FIX_NO_LET_FLOAT", "1");
    try overridden.put("FIX_LET_FLOAT_STATS", "1");
    try overridden.put("FIX_IMPORT_PREFETCH", "0");

    const first = resolve(.{}, &overridden, 2);
    const second = resolve(.{}, null, 2);

    try testing.expectEqual(@as(usize, 0), first.heap_string_min);
    try testing.expect(!first.let_float_enabled);
    try testing.expect(first.let_float_report);
    try testing.expectEqual(@as(u32, 0), first.prefetch.import_budget);

    try testing.expectEqual(@as(usize, 64), second.heap_string_min);
    try testing.expect(second.let_float_enabled);
    try testing.expect(!second.let_float_report);
    try testing.expectEqual(@as(u32, 8192), second.prefetch.import_budget);
}
