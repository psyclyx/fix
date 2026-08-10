# Performance probes

*The instrumentation suite — quantify a lever's ceiling before building the optimizer.*

The expensive cycle/debug probes are compile-time `-D` flags (see [build](../build.md)); their guarded code is omitted when the flag is off. Structured observations are different: spans/events are always compiled, selected at runtime, and feed both terminal progress and the evaluator-scoped Perfetto recorder. With neither output interested, a span stops at the inline observer gate; `--timeline` installs a recorder with fixed event/name buffers, so recording itself never allocates or reaches process-global state. The cycle profilers keep their counters plain (no atomics): `-Dprof-main` writes only from worker 0, so it stays lock-free at any worker count. Its nesting stack belongs to the resumable evaluator fiber rather than the OS thread; an open region that migrates to a helper is discarded instead of corrupting worker 0's attribution. Run it at `--workers=32` for the wait question and at `--workers=1` for the pathlength floor; `-Dprof-path` requires `--workers=1`, since its span nesting assumes a single fiber forcing LIFO. Results surface either through `--stats` (see [cli](../cli.md)) or a written file.

The governing philosophy is to measure headroom before building. The
[performance model](./model.md) records the probe evidence behind its dated
optimization decisions.

## The suite

| flag | question it answers | output |
| --- | --- | --- |
| `-Dprof-main` | Where does main spend cycles, per coarse evaluator operation (e.g. `merge_attrs`, `force_value`, `do_call`), and **does main ever wait**? | exclusive-tick breakdown + piggyback censuses (below), via `--stats` |
| `-Dprof-path` | What force-thunk path dominates under the profiler's parallel-floor model? | force-call tree + per-chunk self/span time, via `--stats` |
| `--timeline` | Per-worker **wall-clock timeline** — structured eval/store spans, fiber-run quanta, GC pauses, counters, metrics, and flows | Perfetto JSON, written via `--timeline[=path]` |
| `-Dthunks-log` | What value did each thunk resolve to, and **where was it created and targeted** — for cross-run comparison | per-thunk lifecycle event log (create/claim/resolve/reset/errored/blackhole), written via `--thunks-log PATH`; `fix thunks diff` compares logs by the stable `(creator, target)` source-location pair |

### `-Dprof-main` and its piggyback censuses

`-Dprof-main` is the workhorse. Its core is a per-fiber tick-counter stack profiler that charges each instrumented scope its **exclusive** cycles (inclusive delta minus time already attributed to nested instrumented scopes), so the printed number for a routine is time spent inside it but not inside an instrumented child. Only worker 0 (main) updates counters. A fiber can suspend and resume on worker 0 without another fiber splicing scopes into its stack; if it resumes on a helper, its open worker-0 scopes are invalidated and omitted from the report. Helpers otherwise return at the worker-id gate.

On the performance model's 2026-07-11 snapshot, `--workers=32` main parked ~3× and waited ~2× while `force_value` dropped from ~23M (w=1) to ~68K; scheduler machinery was ~7% of wall time (see [model](./model.md)). A set of small counters ride the same flag, written only from worker 0:

- **Demand classification** — for each thunk main forces, was it *resolved-ahead* by a helper (win), *claimed by main* (main out-ran the helpers), or a *busy-wait* on a helper mid-compute; at a busy-wait, whether the awaited thunk was still speculative (a demand→spec promotion would pull it up).
- **Age-at-force** — the age of each thunk main claims, sizing the look-ahead ceiling of speculation.
- **Task-class census** — per scheduled work-item class: item counts, no-op rate, useful-cycle distribution.
- **Fiber cost/benefit** — dispatch + swap cycles per task vs. how many tasks suspend and the peak concurrent live-fiber count.
- **Attr-cache / thunk-memo / string** — inline-cache hit rates, thunk-result-memo hit and ineligibility breakdown, and string-machinery (`concat`) counts and bytes.

### `-Dprof-path`: the critical-path floor

`-Dprof-main` tells you which routines burn cycles, but not which *Nix source* the eval spends its time in. `-Dprof-path` runs at `--workers=1`, where forcing is cleanly nested (one fiber, LIFO on the C stack): every `forceThunkImpl` is a span containing the spans of the thunks it forced, keyed by body chunk (approximately a Nix source location). Per span it computes `total` (subtree wall cycles), `self = total − Σ child totals`, and `span = self + max(child span)`. Using `max` (not `sum`) over children models independent siblings as parallel, so the root `span` is an estimate of the force-thunk dependency floor. Comparing it with a same-build multi-worker run also exposes discovery serialization, scheduling overhead, and work outside the profiler's attribution model.

Attribution caveat: spans nest on thunk *forces* only, not on direct closure calls (`do_call`/`do_tail_call` keep running in the same dispatch loop). Work in a directly-called closure that forces no thunk is charged to the *forcing* chunk's self-time. Read the flat profile as "which forcing site drives the most call work", and use `-Dprof-main` for operation-level truth.

### Time source

The cycle probes read a CPU counter directly, because a system call is too expensive at their call rate. `src/base/timebase.zig` owns the read.

| architecture | counter | unit |
| --- | --- | --- |
| x86_64 | `rdtsc` | one TSC cycle |
| aarch64 | `cntvct_el0` | one generic-timer tick, 24 MHz to 100 MHz |

Each report starts with a `timebase=` line that names the counter and gives its frequency, so the reader knows what one tick is worth. The two units are not comparable, and a number from one machine is not comparable with a number from a different machine.

On aarch64 one tick is 10 ns to 41 ns, against a fraction of a nanosecond for the TSC. One measurement of a cheap scope is therefore 0 ticks or 1 tick.

A mean over many measurements does not have that limit. The error of one measurement is its phase against the tick edge, and that phase does not correlate with the scope, so the errors cancel as the call count grows. `-Dprof-main` prints `avg_excl` as a fraction for this reason, and adds `avg_ns` when the counter states its rate. A 25 MHz machine reports `force_value: excl_cy=16115384 calls=52500008 avg_excl=0.307 avg_ns=12.3` on `bench/workloads/torture/math-heavy.nix`: 12.3 ns per call, from a counter whose tick is 40 ns.

Distrust `avg_ns` only where the call count is small. A row with two calls carries up to one tick of error in each, so a short scope called twice tells you little. Rows with millions of calls are sound.

The `pmccntr_el0` register gives true CPU cycles at core frequency, roughly 100x finer. The probes do not use it: Linux keeps `kernel.perf_user_access` at 0 by default, so the instruction traps, and even when it is 1 the counter needs a `perf_event_open` and an `mmap` per thread to find its index. It also counts cycles that stop and scale with core frequency, which answers a different question than the fixed-rate wall ticks these probes report.

## `--stats`

`--stats` works in any build (it does not need a probe flag) and dumps heap/intern/chunk/scheduler/deferred counters plus worker utilisation and the speculation-precision census (of all resolved thunks, the undemanded fraction = speculative waste by count). When `-Dprof-main` or `-Dprof-path` is compiled in, this is also where their reports print.

## How a probe result becomes a decision

- **Ceiling low → don't build.** Historical opcode-count profiling plus dispatch calibration showed dispatch is ~1.5% of the wall (+10 instr/op ≈ +1.5–1.8%), killing superinstructions/fusion before any optimizer was written; that one-off profiler has since been removed.
- **Ceiling high by wall → build (with A/B).** `-Dprof-main` at w=32 pointed the whole program at on-chain work-elimination (the layered-`//` and ATerm wins in [model](./model.md)).
- **Ceiling high by count/bytes, not wall → live but caveated.** Deforestation
  (single-use intermediates) and reclaimable GC storage (see [gc](../gc.md))
  are large by structure count or allocated bytes but need a separate
  mechanism to convert that headroom into wall time or lower reservations.

See the [performance model](./model.md) for the full live/dead ledger.
