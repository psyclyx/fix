//! Piggyback censuses for the `-Dprof-main` profiler: the small
//! demand-path counters that ride along the main-thread rdtsc probe —
//! discovery-serialization, attr inline-cache, thunk-result memo,
//! repeat-force, attr-lookup size, and string-machinery. Split out of
//! `prof.zig`; these are plain worker-0-guarded counters written at
//! their call sites and dumped by the report helpers here.

const std = @import("std");
const prof = @import("prof.zig");
const pct = prof.pct;

/// Discovery-serialization probe (piggybacks on `-Dprof-main`).
/// Classifies MAIN worker 0's demand-path forces to size the gap
/// between "a helper resolved this ahead of me" (win), "I out-ran the
/// helpers and had to compute it myself" (claimed), and "I blocked on
/// a helper computing it" (busy_wait). At a busy-wait we also record
/// whether the awaited thunk was still un-`demanded` — i.e. claimed
/// speculatively at background priority, so a demand->spec PROMOTION
/// would let the critical path pull it up. All writes are worker-0-only
/// (no races); zero-cost when the build flag is off.
pub const Disc = struct {
    resolved_ahead: u64 = 0,
    claimed_by_main: u64 = 0,
    busy_wait: u64 = 0,
    busy_spec_owned: u64 = 0,
    busy_cycles: u64 = 0,
    busy_spec_cycles: u64 = 0,
};
pub var disc: Disc = .{};

/// Coverage-miss breakdown (piggybacks on `-Dprof-main`): every thunk MAIN
/// claims itself is a speculation coverage MISS (helpers didn't pre-resolve
/// it). This census classifies those misses by (a) whether speculation ever
/// submitted a force task for the thunk — `Thunk.spec_disp`: 0 never /
/// 1 admitted / 2 rejected — crossed with (b) whether the thunk was old
/// enough at force that a helper could have raced ahead. The decisive cells:
///   never + old   = TARGETING gap (existed long enough, but speculation
///                   never aimed here) — the addressable coverage prize.
///   admitted + old= LATENCY  gap (aimed + admitted, but main won the race
///                   or the task never drained) — a drain/junk-volume problem.
///   rejected      = capacity gap (aimed, but the backlog was full).
///   never + fresh = serial spine (created just-in-time on the demand chain;
///                   no helper could get ahead) — structural, unspeculatable.
/// The TARGETING cell is further split by thunk kind: `closure`/`bytecode`
/// are directly speculatable (a selection heuristic missed them), whereas
/// `attr_access` are the depth-pull config traversal that needs a
/// demand-predictive selector (no cheap fix). Worker-0-only; zero-cost off.
pub const Coverage = struct {
    never_fresh: u64 = 0,
    never_old: u64 = 0,
    admitted_fresh: u64 = 0,
    admitted_old: u64 = 0,
    rejected_fresh: u64 = 0,
    rejected_old: u64 = 0,
    /// never+old split by TargetKind (0 closure .. 4 deferred).
    never_old_kind: [5]u64 = @splat(0),
};
pub var cov: Coverage = .{};

/// Mirrors `prof_age.age_old_threshold`; duplicated to keep imports light.
const coverage_old_threshold: u64 = 1 << 21;

/// Classify one `claimed_by_main` force. `disp` = `Thunk.spec_disp`,
/// `created_tsc` = the thunk's creation stamp (0 = unknown, skipped),
/// `kind_idx` = its `TargetKind` int. Off-main callers must not call this
/// (the discovery census already guards worker 0). Zero-cost when off.
pub inline fn recordCoverage(disp: u8, created_tsc: u64, kind_idx: u8) void {
    if (comptime !prof.enabled) return;
    if (created_tsc == 0) return;
    const age = prof.rdtsc() -| created_tsc;
    const old = age >= coverage_old_threshold;
    switch (disp) {
        1 => if (old) {
            cov.admitted_old += 1;
        } else {
            cov.admitted_fresh += 1;
        },
        2 => if (old) {
            cov.rejected_old += 1;
        } else {
            cov.rejected_fresh += 1;
        },
        else => if (old) {
            cov.never_old += 1;
            if (kind_idx < cov.never_old_kind.len) cov.never_old_kind[kind_idx] += 1;
        } else {
            cov.never_fresh += 1;
        },
    }
}

/// Coverage-miss breakdown of main's self-claimed forces (see `Coverage`).
pub fn reportCoverage() void {
    const total = cov.never_fresh + cov.never_old + cov.admitted_fresh +
        cov.admitted_old + cov.rejected_fresh + cov.rejected_old;
    if (total == 0) return;
    const never = cov.never_fresh + cov.never_old;
    const admitted = cov.admitted_fresh + cov.admitted_old;
    const rejected = cov.rejected_fresh + cov.rejected_old;
    std.debug.print(
        "prof coverage-miss (main self-claimed forces, n={d} — speculation did NOT cover these):\n",
        .{total},
    );
    std.debug.print(
        "  never-submitted    = {d} ({d:.1}%) | old={d} ({d:.1}%)=TARGETING gap  fresh={d} ({d:.1}%)=serial spine\n",
        .{ never, pct(never, total), cov.never_old, pct(cov.never_old, total), cov.never_fresh, pct(cov.never_fresh, total) },
    );
    std.debug.print(
        "  submitted-admitted = {d} ({d:.1}%) | old={d} ({d:.1}%)=LATENCY gap   fresh={d} ({d:.1}%)\n",
        .{ admitted, pct(admitted, total), cov.admitted_old, pct(cov.admitted_old, total), cov.admitted_fresh, pct(cov.admitted_fresh, total) },
    );
    std.debug.print(
        "  submitted-rejected = {d} ({d:.1}%) | old={d} fresh={d}  =capacity gap\n",
        .{ rejected, pct(rejected, total), cov.rejected_old, cov.rejected_fresh },
    );
    std.debug.print(
        "  TARGETING gap (never+old) by kind: closure={d} bytecode={d} pass_through={d} attr_access={d} deferred={d}\n",
        .{ cov.never_old_kind[0], cov.never_old_kind[1], cov.never_old_kind[2], cov.never_old_kind[3], cov.never_old_kind[4] },
    );
}

/// Strict-collection-walk size census (piggybacks on `-Dprof-main`): sizes
/// the collections MAIN (worker 0, demand context) strictly walks via
/// `forceListAccelerate` / `forceAttrsAccelerate`. `fan_out_min_items` (=4)
/// is the fan-out floor, so walks below it are UNFANNABLE — main forces their
/// elements serially, one at a time. Tests whether the module-merge mass is
/// many SMALL (sub-threshold) lists — aggregate parallelism that per-list
/// fan-out structurally cannot reach — versus a few large ones. Worker-0-only.
pub const StrictWalks = struct {
    walks: u64 = 0, // total demand strict walks
    items: u64 = 0, // total elements across them
    small_walks: u64 = 0, // walks with < fan_out_min_items elements (unfannable)
    small_items: u64 = 0, // elements in those unfannable walks
    // size histogram: [0]=1 [1]=2-3 [2]=4-7 [3]=8-15 [4]=16-31 [5]=32-63 [6]=64+
    buckets: [7]u64 = @splat(0),
};
pub var list_walks: StrictWalks = .{};
pub var attrs_walks: StrictWalks = .{};

pub inline fn recordStrictWalk(w: *StrictWalks, len: usize, fan_min: usize) void {
    w.walks += 1;
    w.items += len;
    if (len < fan_min) {
        w.small_walks += 1;
        w.small_items += len;
    }
    const b: usize = if (len <= 1) 0 else if (len <= 3) 1 else if (len <= 7) 2 else if (len <= 15) 3 else if (len <= 31) 4 else if (len <= 63) 5 else 6;
    w.buckets[b] += 1;
}

pub fn reportStrictWalks(w: *const StrictWalks, label: []const u8) void {
    if (w.walks == 0) return;
    std.debug.print(
        "prof strict-{s} walks (main demand): n={d} items={d} | UNFANNABLE(<4) walks={d} ({d:.1}%) items={d} ({d:.1}%) | sizes 1={d} 2-3={d} 4-7={d} 8-15={d} 16-31={d} 32-63={d} 64+={d}\n",
        .{
            label,                       w.walks,                     w.items,
            w.small_walks,               pct(w.small_walks, w.walks), w.small_items,
            pct(w.small_items, w.items), w.buckets[0],                w.buckets[1],
            w.buckets[2],                w.buckets[3],                w.buckets[4],
            w.buckets[5],                w.buckets[6],
        },
    );
}

/// Attr inline-cache hit/miss census (piggybacks on `-Dprof-main`).
/// Main-thread-only writes (guarded at the call site); zero-cost off.
pub var attr_cache_hits: u64 = 0;
pub var attr_cache_misses: u64 = 0;

/// Thunk-result-memo census (piggybacks on `-Dprof-main`). Sizes whether
/// the per-claimed-force TLS probe still pays for its cache misses.
pub var memo_probes: u64 = 0;
pub var memo_hits: u64 = 0;
pub var thunk_ups0: u64 = 0;
pub var thunk_ups1: u64 = 0;
pub var thunk_ups2: u64 = 0;
pub var thunk_ups3plus: u64 = 0;
pub var memo_write_ok: u64 = 0;
pub var memo_write_effect_blocked: u64 = 0;
/// Memo eligibility histogram: forces of freshly-claimed bytecode thunks
/// that were NOT memo-probed because their upvalue count exceeds the ≤2
/// inline-key limit. Sizes the widening headroom.
pub var memo_inel_3: u64 = 0;
pub var memo_inel_4: u64 = 0;
pub var memo_inel_ge5: u64 = 0;

/// Repeat-force census (piggybacks on `-Dprof-main`): demand forces that
/// hit an ALREADY-RESOLVED thunk, bucketed by access path. These are the
/// forces a resolved-value writeback (thunk shortcutting) would turn into
/// plain-value reads — each one currently touches the thunk's cache line.
/// Worker-0-only writes.
pub var fv_plain: u64 = 0; // forceValue on a non-thunk value
pub var fv_resolved: u64 = 0; // forceValue resolved-thunk fast-path hit
pub var rf_local: u64 = 0; // opGetLocal(/Long) re-read of resolved thunk in a stack slot
pub var rf_upvalue: u64 = 0; // opGetUpvalue re-read of resolved thunk in a capture array
pub var rf_attr_hit: u64 = 0; // attr-cache HIT returning an already-resolved thunk

/// Attr-lookup size census (piggybacks on `-Dprof-main`): attr-cache
/// MISSES (the compulsory binary-search population) bucketed by the
/// looked-up set's entry count — log2 buckets [0]=1..2, [1]=3..4, ...
/// Sizes the per-object hash-index headroom (binary-search probes are
/// dependent cache misses on large sets). `al_merge` counts lookups that
/// hit an unflattened merge_attrs chain (no single size).
pub const allocation_buckets = 16;
pub var al_size: [allocation_buckets]u64 = @splat(0);
pub var al_probes: [allocation_buckets]u64 = @splat(0); // ~log2(n) per lookup, summed
pub var al_merge: u64 = 0;

/// String-machinery census (piggybacks on `-Dprof-main`). Sizes the
/// byte-assembly cost of the interning value representation: every
/// binary concat (`+` and each `${...}` interpolation boundary)
/// allocates a temp buffer, copies both sides, and interns the
/// intermediate — a k-part interpolation pays O(k) passes over its
/// prefix bytes and leaks every intermediate into the intern table.
/// Worker-0-only writes (guarded at the call sites via `tscMainOnly`).
pub const StrCensus = struct {
    /// `concatInternedString` — the pure assembly step of every binary
    /// string/path concat (no forcing inside; excl == incl).
    concat_calls: u64 = 0,
    concat_cycles: u64 = 0,
    /// Result bytes per call, summed — the bytes copied AND hashed.
    concat_bytes: u64 = 0,
    /// Calls whose result was a first-time intern (table miss): these
    /// bytes stay in the intern table forever.
    concat_new: u64 = 0,
    concat_new_bytes: u64 = 0,
    /// Long-string producer attribution for the GC-able-strings census:
    /// results of at least `long_string_threshold` bytes, split by whether
    /// the result carries string context. Contexted text must stay
    /// interned in heap-strings v1 (context_string.text is an InternId),
    /// so only the PLAIN volume is reclaimable — the GO/NO-GO number.
    long_plain_calls: u64 = 0,
    long_plain_bytes: u64 = 0,
    long_ctx_calls: u64 = 0,
    long_ctx_bytes: u64 = 0,
};
pub var str: StrCensus = .{};

pub const long_string_threshold: usize = 64;

/// Census a produced string of `len` bytes (any producer: concat,
/// substring, readFile, serializers) with its context-ness. Worker-0-only
/// like the rest of StrCensus; callers gate on `prof.enabled`.
pub inline fn recordLongString(len: usize, has_context: bool) void {
    if (len < long_string_threshold) return;
    if (has_context) {
        str.long_ctx_calls += 1;
        str.long_ctx_bytes += len;
    } else {
        str.long_plain_calls += 1;
        str.long_plain_bytes += len;
    }
}

/// String-machinery census.
pub fn reportStrConcat() void {
    if (str.concat_calls != 0) {
        std.debug.print(
            "prof str-concat: calls={d} cycles={d} avg_cy={d:.3} bytes={d} new={d} ({d:.1}%) new_bytes={d}\n",
            .{
                str.concat_calls,
                str.concat_cycles,
                // Fractional: a single concat costs well under one tick of a
                // coarse counter, so an integer mean reads 0.
                @as(f64, @floatFromInt(str.concat_cycles)) / @as(f64, @floatFromInt(str.concat_calls)),
                str.concat_bytes,
                str.concat_new,
                pct(str.concat_new, str.concat_calls),
                str.concat_new_bytes,
            },
        );
    }
    if (str.long_plain_calls != 0 or str.long_ctx_calls != 0) {
        std.debug.print(
            "prof str-long(>={d}B): plain={d}/{d}B ctx={d}/{d}B (plain share {d:.1}% of long bytes)\n",
            .{
                long_string_threshold,
                str.long_plain_calls,
                str.long_plain_bytes,
                str.long_ctx_calls,
                str.long_ctx_bytes,
                pct(str.long_plain_bytes, str.long_plain_bytes + str.long_ctx_bytes),
            },
        );
    }
}

/// Attr inline-cache, thunk-memo, repeat-force, and attr-lookup size
/// censuses (contiguous demand-path breakdowns).
pub fn reportCaches() void {
    // Attr inline-cache census.
    {
        const total = attr_cache_hits + attr_cache_misses;
        if (total != 0) {
            std.debug.print(
                "prof attr-cache: lookups={d} hits={d} ({d:.1}%) misses={d}\n",
                .{ total, attr_cache_hits, pct(attr_cache_hits, total), attr_cache_misses },
            );
        }
    }
    // Thunk-result-memo census.
    if (thunk_ups0 + thunk_ups1 + thunk_ups2 + thunk_ups3plus != 0) {
        const tot = thunk_ups0 + thunk_ups1 + thunk_ups2 + thunk_ups3plus;
        std.debug.print(
            "prof thunk-upvalues at creation: 0={d} ({d:.1}%) 1={d} ({d:.1}%) 2={d} ({d:.1}%) 3+={d} ({d:.1}%)\n",
            .{ thunk_ups0, pct(thunk_ups0, tot), thunk_ups1, pct(thunk_ups1, tot), thunk_ups2, pct(thunk_ups2, tot), thunk_ups3plus, pct(thunk_ups3plus, tot) },
        );
    }
    if (memo_probes != 0) {
        std.debug.print(
            "prof thunk-memo: probes={d} hits={d} ({d:.1}%) writes_ok={d} writes_effect_blocked={d} inel_ups3={d} inel_ups4={d} inel_ups>=5={d}\n",
            .{ memo_probes, memo_hits, pct(memo_hits, memo_probes), memo_write_ok, memo_write_effect_blocked, memo_inel_3, memo_inel_4, memo_inel_ge5 },
        );
    }
    // Repeat-force census.
    {
        const total = fv_plain + fv_resolved;
        if (total != 0) {
            std.debug.print(
                "prof repeat-force: fv_plain={d} fv_resolved={d} rf_local={d} rf_upvalue={d} rf_attr_hit={d}\n",
                .{ fv_plain, fv_resolved, rf_local, rf_upvalue, rf_attr_hit },
            );
        }
    }
    // Attr-lookup size census.
    {
        var total: u64 = 0;
        for (al_size) |n| total += n;
        if (total != 0) {
            std.debug.print("prof attr-lookup sizes (cache misses; bucket=[2^k+1..2^(k+1)] entries):\n", .{});
            for (al_size, 0..) |n, k| {
                if (n == 0) continue;
                std.debug.print(
                    "  size<=2^{d}: lookups={d} ({d:.1}%) probes={d}\n",
                    .{ k + 1, n, pct(n, total), al_probes[k] },
                );
            }
            std.debug.print("  merge-chain lookups={d}\n", .{al_merge});
        }
    }
}

/// Discovery-serialization breakdown of main's demand forces.
pub fn reportDiscovery() void {
    const total = disc.resolved_ahead + disc.claimed_by_main + disc.busy_wait;
    if (total != 0) {
        std.debug.print(
            "prof discovery (main demand-forces, n={d}): resolved_ahead={d} ({d:.1}%) claimed_by_main={d} ({d:.1}%) busy_wait={d} ({d:.1}%)\n",
            .{
                total,
                disc.resolved_ahead,
                pct(disc.resolved_ahead, total),
                disc.claimed_by_main,
                pct(disc.claimed_by_main, total),
                disc.busy_wait,
                pct(disc.busy_wait, total),
            },
        );
        std.debug.print(
            "prof discovery (crit-path busy waits): busy_spec_owned={d}/{d} spec_wait_cy={d} total_wait_cy={d} ({d:.1}% of wait cycles is spec-owned; NOT wall headroom — rescue collapses it 1400x wall-neutral, the chain just re-claims the work)\n",
            .{
                disc.busy_spec_owned,                         disc.busy_wait,
                disc.busy_spec_cycles,                        disc.busy_cycles,
                pct(disc.busy_spec_cycles, disc.busy_cycles),
            },
        );
    }
}
