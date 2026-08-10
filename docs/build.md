# Build

*The build graph, module layout, and hygiene that keep the fast paths honest.*

`fix` builds with `zig build` from a single `build.zig`. Seven durable source groups are Zig modules; subsystems beneath durable roots are ordinary file namespaces. An executable-only `process_support` module composes allocator policy without adding it to the engine API. The installed artifact is named `fix`. The build also forces LLVM because the threaded dispatcher needs it.

## Module model

The build-module graph follows independently reusable or consumed groups. Within `expr`, `store`, and `fetchers`, normal relative file imports keep one canonical instance of every internal type without restating the subsystem graph in `build.zig`.

| Module | Facade | Imports | Notes |
|---|---|---|---|
| `base` | `src/base/root.zig` | `base_options` | generic containers, fibers, synchronization, blocking pools, allocators, clocks, memory backing |
| `syntax` | `src/syntax/root.zig` | `base`, `parser_tables` | independently consumed lexer, parser, and AST |
| `runtime` | `src/runtime/root.zig` | `build_options`, `base` | value model, heap, interning, thunk/Future, GC, memory tags |
| `store` | `src/store/root.zig` | `base`, `runtime` | derivations, file snapshots, NAR, realization, daemon protocol/runtime |
| `fetchers` | `src/fetchers/root.zig` | `base`, `runtime`, `store`, libcurl, libgit2 | forge planning, remote-source cache and transports |
| `expr` | `src/expr/root.zig` | `build_options`, `base`, `syntax`, `runtime`, `store`, `fetchers` | bytecode/compiler/VM, builtins, evaluator workers and diagnostics |
| `cli` | `src/cli/root.zig` | `base`, `expr`, `runtime`, `syntax`, `store` | command surface, argument parsing, rendering, progress |
| `process_support` | `src/process_support.zig` | `base`, `runtime` | executable-only allocator composition |

`cli` is the in-repository consumer, so it imports the durable modules it uses directly. Evaluation commands use `expr`; value inspection uses `runtime`; parsing and debugger highlighting use `syntax`; realization commands use `store`. The executable (`src/main.zig`) imports `cli` and the private `process_support` composition module.

## Parser-table codegen

The LALR parser tables are expensive to construct at comptime, so a standalone codegen tool builds them once and emits a plain `.zig` of literal arrays. `src/syntax/gen_parser_tables.zig` is compiled into the `gen-parser-tables` host executable, run as a build step whose single output file is fed to the `syntax` module as the anonymous import `parser_tables`. The build system caches the run and only re-executes it when the grammar or generator changes. `zig build gen-parser-tables` runs it explicitly. Because the parser imports the generated `parser_tables`, `zig test src/syntax/parser.zig` cannot resolve it standalone — use `zig build test-syntax`.

## Build options

Engine-specific `-D` flags are folded into one shared `build_options` module and injected only where they are used. Generic `base` does not see that application-wide option surface. It receives a separate, narrow `base_options` module containing the profiler-backed fiber census and the TSan fiber-switch hook gate.

### `-D` flag surface

All are `bool` and off unless noted. These are exactly the flags `build.zig` defines; there are no others. Profiling probes gate instrumentation compiled into the core — see [perf/probes.md](perf/probes.md) for what each measures and the workers=1 caveats.

| Group | Flag | Effect |
|---|---|---|
| diagnostics | `debug-checks` | VM dispatch invariant assertions (**defaults on** in Debug builds) |
| | `vm-trace` | enable VM execution tracing (surfaced by `--vm-trace`) → [cli.md](cli.md) |
| | `thunks-log` | per-thunk lifecycle event log (surfaced by `--thunks-log`) → [cli.md](cli.md) |
| profiling | `prof-main` | time the main thread's hot serial paths with the CPU tick counter; reported via `--stats` → [perf/probes.md](perf/probes.md) |
| | `prof-path` | record the force-call tree + critical path (workers=1); reported via `--stats` → [perf/probes.md](perf/probes.md) |
| compilation | `profile` | keep symbols + frame pointers (sets `strip=false`, `omit_frame_pointer=false`) |
| verification | `tsan` | instrument the evaluator graph with ThreadSanitizer; x86_64 Linux only → [concurrency-testing.md](concurrency-testing.md) |

Standard `zig build` options apply too: `-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall` and `-Dtarget=…`. Perf numbers assume `ReleaseFast` (or `ReleaseSafe`); `-Dprofile` only flips symbol/frame-pointer stripping, it does not change the optimize mode.

The `--vm-trace` / `--thunks-log` runtime flags are inert unless the matching `-D` flag compiled the machinery in; the `fix trace` and `fix thunks` analysis commands are likewise registered only in builds with their corresponding flags. `--timeline` is a special case: the timeline probe is always compiled in and runtime-gated, so `--timeline[=path]` arms it with no rebuild. The `-Dprof-*` reports have no runtime toggle — they are build-time only, so exercising one means a rebuild, and its output surfaces through `--stats`.

## Why LLVM is forced (`use_llvm = true`)

The threaded VM dispatcher (`src/expr/vm/run.zig`) chains handlers with `@call(.always_tail)`. Only the LLVM backend implements guaranteed tail calls; the self-hosted backend would emit ordinary calls and the dispatch chain would **unbounded-recurse and blow the stack** — even in Debug. So `use_llvm = true` is pinned on the `exe` *and* on every `addTest` artifact, for all optimize modes.

## Group test wiring

`zig build test` runs one test artifact for each durable group and the
end-to-end CLI shell suite. `zig build check` runs that suite, the structure
check, `zig fmt --check` over `build.zig`, `src/`, and `tools/`, and the bounded
TLA+ models:

```
test → base_tests, syntax_tests, runtime_tests, store_tests, fetchers_tests,
       expr_tests, integration_tests, cli_tests, test/e2e/run.sh
```

Relative imports inside each durable root let its test artifact discover subsystem tests recursively. `zig build test-syntax` runs the front-end tests alone; `zig build bench-parse -- <file.nix>` runs the parse microbenchmark against `syntax`.

`zig build test-concurrency` filters the runtime and evaluator artifacts to the
deterministic concurrency protocol tests. `zig build check-models` runs the
TLA+ specifications and mutation checks, while `zig build
stress-concurrency -- --seed N --iterations N` drives the longer reproducible
stress executable. See [concurrency verification](concurrency-testing.md).

Expression-engine integration tests live under `src/integration/expr_api`; evaluator, compiler, and VM unit tests live with their `src/expr` subsystems, while the store realization facade owns its socket-backed tests and fake daemon. `test/*.nix` holds pathology and spec fixtures driven through evaluation. `zig build check-static` also runs `tools/structure_check.sh`, which enforces the durable module roots plus selected internal boundaries (including heap-store encapsulation and the compiler's AST-independent emitter).

## The correctness gate

For supported inputs, derivation text and store paths are expected to match
Nix. Unit and integration tests exercise the hashing and serialization rules;
the language and benchmark-fixture differential suites are separate build
steps. See [invariants.md](invariants.md).

CI runs language conformance on every supported system and the complete
benchmark-fixture differential on x86_64 Linux; the latter is correctness-only
and does not run the timing harness.

Code: `build.zig`
