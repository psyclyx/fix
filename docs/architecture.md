# Architecture

*The whole system in one pass: what `fix` is, how an expression becomes a derivation, and how the pieces fit.*

`fix` is a from-scratch evaluator for the Nix expression language, written in
Zig. It targets the same evaluated values, derivation text, and store paths as
`nix-instantiate`. Its runtime can force thunks on multiple worker threads,
including work submitted ahead of demand.

Read this page first, then follow the reading order at the bottom.

## The evaluation pipeline

```
source text
  → scanner ─ tokens ─ LALR(1) parser        → AST            [syntax]
  → bytecode compiler + analyses              → bytecode Chunk [compiler + bytecode]
  → threaded VM forces lazy thunks            → Value          [vm + runtime]
  → derivation builtins serialize and hash    → .drv text + store paths [derivation]
  → realization recipes + nix-daemon client  → .drv files in the store, built
                                                outputs, result links  [store]
```

The compiler uses thunks at lazy positions. The VM normally forces them on
demand; the scheduler may also submit eligible thunks speculatively.

- **[syntax](syntax/parsing.md)** — a streaming scanner and a table-driven LALR(1) parser build an arena-allocated AST. Nix's awkward corners (interpolation, indented strings, paths, `inherit`, attr patterns, dynamic attrs) are handled here → [nix-syntax](syntax/nix-syntax.md).
- **[compiler](compiler/pipeline.md)** — recursively lowers the AST to
  **bytecode chunks**, with separate name, reference, and
  [strictness](compiler/strictness.md) analyses where needed. It resolves names
  to stack slots and [upvalue captures](compiler/scopes.md), decides what to
  make lazy, eager, or [deferred](compiler/lazy-compile.md), and — per `let` —
  runs a scoped rewrite that [places bindings](compiler/let-float.md) at their
  demand point before classifying what's left.
- **[runtime](runtime/values.md)** — the data model: an 8-byte NaN-boxed [`Value`](runtime/values.md), a flat [object heap](runtime/heap.md), string [interning](runtime/interning.md), and the [thunk](runtime/thunks.md) that carries laziness.
- **[vm](vm/dispatch.md)** — a direct-threaded bytecode interpreter that [forces thunks](runtime/thunks.md), [calls closures](vm/calls.md), [reads attrsets/lists](vm/access.md), and runs the [builtins](vm/builtins.md).
- **[store / derivation](derivation/model.md)** — the domain model: `Drv`, canonical hashing and paths, string context, and the evaluation-scoped registry of computed derivations. The `derivation` builtins assemble a `Drv`, then [hash](derivation/hashing.md) it (ATerm serialization → SHA-256 → nixBase32) to compute store paths.
- **store / realization** — turns derivation records and source-path recipes into concrete store actions. It owns the evaluation's `RealizationStore`, lazy derivation cache, source snapshots and NAR encoding, closure planning, realization claims, and nix-daemon protocol/runtime. An explicit executor capability lets evaluator fibers park without making the store depend on evaluator workers.
- **fetchers** — remote source acquisition outside the expression engine. `FetchService` owns cache/transport lifecycle; `fetch/` owns borrowed configuration, request/result values, authentication, and narrow URL/Git/Mercurial views. VM builtins only decode Nix values and map fetch results back to values.

## The module DAG

The source tree has seven durable module groups. `base`, `syntax`, and `runtime` are reusable foundations; `store` owns derivations and concrete store behavior; `fetchers` owns remote source acquisition; `expr` owns the expression engine; and `cli` is the application layer. Subsystems under each durable root keep their own facades and namespaces, but use ordinary file imports rather than each restating the same graph as a build module.

```
src/base/       base → base_options
                Generic containers, synchronization, fibers, allocators,
                blocking pools, clocks, and memory backing.

src/syntax/     syntax → base, parser_tables
                Scanner, parser, AST; independently benchmarked.

src/runtime/    runtime → base, build_options
                Value, heap, thunk/Future, interning, GC.

src/store/      store → base, runtime
                Derivations, source snapshots, NAR, realization recipes,
                daemon protocol and runtime.

src/fetchers/   fetchers → base, runtime, store, zurl, ziggit
                Remote-source cache, provider planning, transports.

src/expr/       expr → base, syntax, runtime, store, fetchers, build_options
                Bytecode, compiler, builtins, VM, evaluator workers,
                language support, observability, and probes.

src/cli/        cli → base, expr, runtime, syntax, store
                Commands, options, rendering, debugger.

src/main.zig       → cli, process_support
                Process composition; executable `fix`.
```

`base` is independent of evaluator-specific policy. For example, its virtual
memory accounting is generic over the caller's tag type; the runtime supplies
the evaluator's memory categories.

Within `expr`, the compiler and VM own their execution state, and
`evaluator.zig` composes them into `Engine`. `eval/workers/` owns scheduling,
fibers, and the capabilities that park work or send blocking work away from
compute threads. The VM uses those capabilities but does not own worker state.
The store exposes a narrow executor capability, implemented by the evaluator's
fiber workers, so store operations do not depend on evaluator internals. The
CLI consumes the module groups it needs directly. See [build](build.md) for the
enforced module graph.

## Ownership and state changes

Ownership is explicit in the data model. `base.TextRef` distinguishes borrowed
from owned text; only the owned form is freed. Replacing owned configuration is
transactional: prepare the replacement, then swap it into the live state.

Long-lived mutable state has clear owners: `Engine`, `FetchService`,
`ObjectHeap`, and `Scheduler`. The heap owns its segmented stores and failure
records; other layers use its semantic operations and read-only projections.
Parsed units, compilation plans, derivation artifacts, and validated REPL
commands are values passed between phases rather than additional shared owners.

## Laziness and parallelism are one primitive

The spine of the system is the [thunk / `Future`](runtime/thunks.md). A thunk is
a suspended computation; in parallel mode it is also a concurrent cell. One
[fiber](parallel/fibers.md) at a time claims an unresolved thunk and runs its
body. Other fibers reaching that attempt can park on its waiter list. A
successful result or deterministic error is memoized; explicitly transient
failures reset the thunk for a later attempt. Imports use the same `Future`
protocol in an `ImportEntry`.

## The concurrency model

- **[Fibers](parallel/fibers.md)** — stackful user-space coroutines with x86-64 and AArch64 stack-switching. A yielded fiber carries its evaluation state and can be stolen and resumed by another worker; OS-thread-local services are resolved again through non-inlined accessors after migration.
- **[Scheduler](parallel/scheduler.md)** — per-worker work-stealing queues, classed by submission lane: an *urgent* lane (demand-driven fan-out, a fixed-capacity lock-free Chase-Lev deque) and capped, best-effort *speculative* lanes (a mutex-protected bounded ring). Idle workers steal; parked workers spin then futex-sleep.
- **[Workers](parallel/workers.md)** — N workers; the main thread runs the
  top-level fiber and participates in the drain loop while that fiber is
  parked.
- **[Speculation & fan-out](parallel/speculation.md)** — the evaluator forces likely-needed thunks ahead of demand (speculation) and forks a collection's element thunks in parallel (fan-out), gated by [strictness](compiler/strictness.md) and bounded by bail-on-demand and per-task budgets.

## Why it's shaped this way (performance)

On the NixOS workload recorded in [perf/model](perf/model.md), scaling is
bounded by a serial critical path through module evaluation and derivation
hashing. That observation motivated lean thunks, frameless attr access, layered
merges, and bulk ATerm construction. It is a measured workload result, not a
property asserted for every Nix expression.

## Correctness posture

- Matching derivation text and store paths is a compatibility target covered by
  derivation tests and differential workloads. See [invariants](invariants.md).
- The interpreter is the execution engine. The [GC](gc.md) is part of every
  supported build and must preserve evaluator results while reclaiming storage.
- **Headroom is measured before it's built.** A suite of [probes](perf/probes.md) (compile-time `-D` flags) quantifies each lever's ceiling first.

## Reading order

1. **This page**, then [invariants](invariants.md) — the cross-cutting rules.
2. **Front end:** [syntax/parsing](syntax/parsing.md) → [syntax/nix-syntax](syntax/nix-syntax.md) → [compiler/pipeline](compiler/pipeline.md) (→ [scopes](compiler/scopes.md), [strictness](compiler/strictness.md), [lazy-compile](compiler/lazy-compile.md)).
3. **Data & engine:** [runtime/values](runtime/values.md) → [heap](runtime/heap.md) → [interning](runtime/interning.md) → [thunks](runtime/thunks.md); then [vm/dispatch](vm/dispatch.md) → [calls](vm/calls.md) → [access](vm/access.md) → [builtins](vm/builtins.md).
4. **Derivations:** [derivation/model](derivation/model.md) → [hashing](derivation/hashing.md) → [context](derivation/context.md).
5. **Parallelism:** [fibers](parallel/fibers.md) → [scheduler](parallel/scheduler.md) → [workers](parallel/workers.md) → [speculation](parallel/speculation.md) → [imports](parallel/imports.md).
6. **Performance & memory:** [perf/model](perf/model.md) → [perf/probes](perf/probes.md); [gc](gc.md).
7. **Operating it:** [build](build.md); [cli](cli.md).
