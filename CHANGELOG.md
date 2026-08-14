# Changelog

All notable changes to `fix` are documented in this file.

## [Unreleased]

### Added

- A persistent compiled-chunk cache: an unchanged source file (same source
  bytes, path, language policy, codegen flags) skips parse + compile
  entirely on later runs, loading its bytecode chunks and deferred entries
  from `~/.cache/fix/chunks` (or `$XDG_CACHE_HOME`; `--compile-cache-dir`
  overrides the root).
  Cache generations are keyed by the binary's GNU build-id — a rebuilt fix
  starts from an empty directory and sweeps stale siblings automatically.
  Every failure mode falls back to a fresh compile; debugger and
  name-capture sessions bypass the cache in both directions. Measured on a
  warm nixos-minimal evaluation at one worker: 1.740s vs 2.149s without the
  cache (1.23× faster). `--no-compile-cache` disables it, and
  `FIX_LET_FLOAT_STATS=1` prints a hits/misses/writes/rejects census at
  teardown. Cache-file IO runs on a background writer lane (drained before
  exit), so cold runs pay no measurable write tax; blobs carry a
  whole-payload checksum, so torn writes and bit rot reject as corrupt and
  self-heal on the recompile.
- Demand-driven `let` binding placement (`let-float`): a compile-time,
  semantics-preserving rewrite that flattens nested-let spines, drops dead
  binding chains, inlines literal/alias bindings, sinks single-use bindings
  to their consumer, and floats branch-exclusive bindings into the `if`-arm
  that uses them — before the residual `let` is classified and lowered.
  Evaluation order and sharing are unchanged; only thunk *creation* moves.
  `FIX_NO_LET_FLOAT=1` disables it for A/B comparison, and
  `FIX_LET_FLOAT_STATS=1` prints a per-rewrite census at teardown.
  - The analysis is now a single-walk cluster **registry** per compile
    unit: one pass over an outermost `let`'s subtree registers every nested
    `let`'s cluster at once (header-relative measurements make each
    cluster's graph invariant under an enclosing rewrite that merely moves
    its subtree), instead of re-walking on every nested level. An enclosing
    rewrite that changes a nested let's own contents rebuilds that node and
    falls back to one fresh walk of just that subtree. Nested-let spine
    merging now happens during this walk rather than as a separate
    pre-pass. Measured on the pinned nixpkgs full-universe evaluation
    (80,586 attrs): ~52.0s vs ~52.9s for the prior per-let-walk version,
    about 3% cumulative faster than pre-let-float HEAD.
  - Bindings whose RHS mentions a `with`-resolved (dynamic) name are no
    longer globally immobile: they may inline/sink/float to any destination
    whose window from the cluster header crosses no `with` body (identical
    `with`-chain ⇒ identical resolution). On the nixpkgs pin this raised
    single-use sinks from 3,235 to 4,078 and cut "blocked: dynamic free
    name" from ~7,000 to 485. Elided (never-parsed) RHSes remain globally
    immobile.
- Full laziness, on by default: `let` bindings and anonymous maximal free
  expressions inside a lambda that do not depend on the lambda's parameters
  float out of it, so every application shares one thunk (evaluated at most
  once) instead of re-creating — and possibly re-evaluating — it per call.
  On the pinned nixpkgs universe this floats 1,327 named bindings and 5,331
  anonymous subexpressions while staying wall- and RSS-neutral; workloads
  that actually repeat work collapse (a shared-subexpression fixture drops
  482ms → 5ms, a wide call tree 441ms → 10ms). `FIX_NO_FULL_LAZY=1`
  disables it for A/B comparison.
- Dynamically built strings are garbage-collected heap objects instead of
  permanent intern-table entries (short results live inline in the object
  slot; number formatting no longer interns at all). A string-churn fixture
  that previously grew the intern table by 141.8 MB now retains 1.8 KB and
  runs 1.21s → 0.37s. Strings carrying derivation context stay interned by
  design.
- A heap memory diet: attrset storage is structure-of-arrays (a names plane
  and a values plane, 16 → 12 bytes per entry, with name-only binary
  searches touching 4× more names per cache line) and every heap object
  shrank 56 → 48 bytes (thunk flags folded into the future's state word,
  rare speculative effect groups moved to a side table). Peak store bytes
  on the nixpkgs full-universe evaluation drop 38 GB → 34.1 GB.
- Per-thread intern-store TLABs: interning appends allocate from
  thread-local chunks, amortizing the store mutex to one acquisition per
  hundreds of inserts — removing the commit convoy that dominated
  string-heavy evaluation at high worker counts.
- The benchmark harness compares one row per evaluator, each in its best
  default configuration, with explicit warm- and cold-compile-cache lanes
  for fix (the cold lane's cache directory is wiped before every timed run,
  so the persistent cache is never silently flattering) and an
  `all-configs` realworld workload that passes every configuration on one
  command line. The summary is a light/dark small-multiples chart with
  per-workload rankings, and every result tree is stamped with
  `provenance.md`: the date, hardware, run settings, tool versions, pinned
  inputs, and measured commit behind the numbers. Everything lives under
  `bench/` now (`run`, `harness.nix`, `render.py`, `workloads/`), and one
  command — `./bench/run` — reruns the whole benchmark and rewrites the
  committed `bench/results/` tree that the README links to instead of
  inlining tables.
- Strict-prefix `let` elision (`strictness.demandPrefix`) generalizes the old
  single-binding eager-elision gate to an ordered, transitively-extended
  prefix of bindings the body provably forces before any other observable
  effect, evaluated straight into their slots with no thunk.
  - The prefix walk is now callee-aware: a saturated call to a statically-
    known sibling (or inline-literal) value lambda is no longer a demand
    barrier — the walk descends into the callee's body with its parameters
    bound to the call's argument expressions, so an argument the callee's
    body provably forces joins the caller's strict prefix too (depth-capped
    at 4). Effect order still follows body demand order, so which error
    surfaces first is unchanged.

### Fixed

- `true`, `false` and `null` are variables bound in the base environment, not
  reserved words, matching Nix. A binder shadows them (`let true = 1; in true`
  is `1`) and they are legal in every binding position — `(true: true) 5` is
  `5`, `({ null ? 3 }: null) { }` is `3` — where they previously lexed as
  keywords and produced a parse error. Unshadowed uses still compile to
  literals, so nothing else changes.
- A `let` whose bindings had an eager-elision-eligible RHS chain could
  false-blackhole with `RecursiveThunk` when an earlier binding transitively
  forced a not-yet-initialized later one (`let l = r + 1; p = l + 2; r = 5 +
  5; in p` now evaluates to `13`, matching lazy semantics). The strict prefix
  is now validated so a member is only referenced by a *later* member.
- Non-strict list rendering matches Nix more closely for single-use `let`
  bindings: `let x = 1 + 1; in [ x ]` prints `[ <CODE> ]` (an unforced thunk)
  instead of eagerly printing `[ 2 ]`.

## [0.3.0] - 2026-08-02

### Added

- A whole-nixpkgs differential harness (`test/nixpkgs/`, `zig build
  test-nixpkgs`): evaluates the entire nixpkgs CI job universe (about 80,000
  derivations) with `fix` and a reference Nix and compares every `.drv` store
  path. The pinned universe currently evaluates to identical derivation paths
  (80,586 of 80,586 attributes, including agreement on which attributes fail
  to evaluate). CI runs it as a sharded chunk matrix.
- Channel resolution: when neither `-I` nor `$NIX_PATH` provides a lookup
  path, `<nixpkgs>` and friends resolve from the user and root channel
  profiles, as Nix does.
- GC detector builds: swept thunk state is poisoned so a stale reference
  traps at the point of use instead of silently reading recycled memory. CI
  runs a tight-budget detector lane on a nixpkgs chunk.

### Fixed

- `builtins.toXML` forces its argument strictly, as Nix does. A
  speculatively resolved but undemanded thunk could previously bake
  `<unevaluated />` into a cached string; the demand-sensitive rendering is
  now exclusive to the CLI's lazy `--xml` output.
- Two parallel-evaluation GC rooting bugs found by the detector: evaluation
  results are rooted across the native handoff, and a speculative force
  task's thunk is rooted for the task's whole duration.
- Merged dotted `let` groups (`let a.b = …; a.c = …;`) get their own binding
  cells instead of miscompiling.
- `fromTOML` handles escape sequences in multi-line strings.
- Type predicates (`isInt` and friends) recognize boxed integers.
- The strict attribute-literal merge carries attribute positions, so
  `unsafeGetAttrPos` and error messages keep their locations.
- Selecting a derivation output (`drv.out`) no longer computes the
  derivation eagerly.
- `FileCache` records lstat-accurate file kinds, fixing NAR hashes for
  symlinks.
- Discarded output dependencies (`builtins.unsafeDiscardOutputDependency`)
  are honored in derivation contexts.
- The VM value and frame stacks are sized so call chains that are legal
  under `max-call-depth` no longer overflow (deep nixpkgs
  `lib.recursiveUpdate` spines evaluate where Nix and Lix already did).

## [0.2.0] - 2026-08-02

### Added

- Local and modern Lix store selectors: `unix://` sockets with
  `protocol=legacy`, `any`, and `legacy-combined`, explicit `ssh-ng://` stores
  with `port`, `ssh-key`, and `compress` settings, and bare daemon-socket
  paths. CI now exercises live CppNix and Lix daemons.
- Retained failure diagnostics: cached evaluation failures keep their full
  message, origin, and deep stack trace across parallel evaluation and replay.
- Debugger: a garbage-collection command at the paused prompt, and paused
  sessions now root their heaps so exploration survives collection.
- A concurrency verification stack: TLA+ models of the future-wait,
  fiber-dispatch, shutdown, and GC-barrier protocols (checked for safety,
  deadlock freedom, and liveness, with a mutation check per model);
  ThreadSanitizer instrumentation with fiber-aware stack attribution;
  deterministic adversarial protocol tests; seeded stress lanes with
  serial/parallel differentials; and a nightly real-eval differential against
  reference Nix at eight workers, including a ThreadSanitizer lane.
- MIT license.

### Changed

- `fix` never delegates to an installed Nix or Lix: unsupported store
  selectors (`local`, `auto`, chroot roots, `lix-xp-1`) fail with specific
  diagnostics instead of falling back to a binary on `PATH`.
- The benchmark harness drops its snix timing row; the snix
  language-conformance suite remains.

### Fixed

- Data races found by the new verification lanes: growable-deque slot reuse,
  mutable state embedded in copied heap unions (the sibling-sweep mark and the
  merge-flatten memo), and the thunk speculation peek.
- Speculative failure propagation: failures computed on helper workers replay
  with the same error, message, and trace as serial evaluation.
- Contended future waiters park instead of spinning, and worker and scheduler
  teardown waits for in-flight external callbacks.
- SSH daemon invocation is hardened: validated destination, batch mode, and
  explicit rejection of unsupported settings.

## [0.1.0] - 2026-07-27

First public release.

### Added

- A from-scratch Nix parser, bytecode compiler, lazy evaluator, and command-line
  interface.
- Parallel evaluation with worker scheduling, fibers, speculative forcing, and
  a parallel garbage collector.
- Evaluation, instantiation, builds, flakes, development shells, program
  execution, configuration activation, and Nix daemon store operations.
- An interactive REPL, VM and heap explorer, source debugger, evaluation
  statistics, and Perfetto-compatible traces.
- Differential language, derivation, store-path, and benchmark-fixture
  compatibility tests.
- Nix packaging, shell completions, direnv integration, and modules for NixOS,
  nix-darwin, and Home Manager.
- Release builds for x86_64 Linux, aarch64 Linux, and aarch64 macOS.
