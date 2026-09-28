<picture>
  <source media="(prefers-color-scheme: dark)" srcset="demo/banner-dark.svg">
  <img alt="fix" src="demo/banner.svg">
</picture>

# fix

`fix` is a fast, parallel evaluator and command-line tool for the Nix language,
written in Zig.

It is a from-scratch implementation, not a wrapper around the Nix evaluator.
`fix` parses Nix source, compiles it to bytecode, evaluates expressions lazily,
computes derivations and store paths, and speaks the Nix daemon protocol for
store operations and builds. It is intended to run existing Nix expressions
and produce the same values and derivations while making evaluation faster.

`fix` also treats the evaluator as something you should be able to inspect. It
includes a heap and bytecode explorer, a source-level debugger, an interactive
REPL, evaluation statistics, and Perfetto-compatible traces.

![Exploring a running evaluation with fix](demo/explorer.gif)

## What is different

### Parallel lazy evaluation

`fix` can evaluate thunk work on multiple worker threads. A thunk contains a
`Future`: one fiber claims an unresolved thunk, while another fiber that reaches
the same in-flight thunk can park and let its worker run something else.
Speculative forcing and strict-demand fan-out provide work for otherwise idle
workers; both can be disabled when diagnosing parallel behavior.

The worker count is configurable, including a single-worker mode when
repeatability or debugging matters more than throughput. Memory is managed by
a parallel generational garbage collector.

The core concurrency protocols — future wait, fiber dispatch, shutdown, and
the GC barrier — are [modeled in TLA+](model/README.md) and checked for
safety, deadlock freedom, and liveness. A nightly CI lane evaluates real
configurations in parallel against a reference Nix under ThreadSanitizer.

### Compatibility you can measure

Compatibility is a target backed by several kinds of tests:

- Derivation tests cover canonical ATerm serialization, hashing, string
  context, and expected `.drv` and output store paths.
- The pinned Lix and snix language suites compare evaluation and parse results.
- A separate differential test evaluates every benchmark fixture with `fix`
  and a reference Nix, then compares the strict JSON results structurally.
- A whole-nixpkgs differential evaluates the entire nixpkgs CI job universe
  (`ci/eval/outpaths.nix`, about 80,000 derivations) with `fix` and a
  reference Nix and compares every `.drv` store path. A drvPath match
  certifies the complete derivation that produced it — inputs, environment,
  and builder, transitively.
- `fix parse` emits the same JSON-shaped syntax tree used by
  `nix-instantiate --parse`.

The language suites and nixpkgs derivation-path differential are separate
checks, with their scope described in
[the language-test documentation](test/lang/README.md). The nixpkgs
differential runs monolithically with
`zig build test-nixpkgs` (it wants a large-memory machine and caches the
reference results per pin) and as a sharded matrix in CI.

### An evaluator you can look inside

The VM explorer and debugger are part of `fix`, rather than separate
instrumented builds. They operate on the real compiler, bytecode, stacks,
thunks, and heap used by ordinary evaluations.

The explorer can move from source expressions to compiled chunks and
instructions, inspect heap objects and their references, search stores, and set
breakpoints. Large chunk and object collections are represented with range
nodes and bounded queries rather than one UI row per entry.

The debugger supports:

- pending and resolved source-line breakpoints;
- `builtins.break` and stops on evaluation errors;
- step, next, finish, and continue;
- lexical locals, captured values, the operand stack, and annotated bytecode;
- evaluating a Nix expression in the scope of the current pause; and
- opening the VM explorer without leaving the debugging session.

`fix eval --debugger` and `fix repl --debugger` use one worker. A transient
`:debug` session in an ordinary REPL temporarily disables parallel submissions.

![A source breakpoint in the fix debugger](demo/debugger.gif)

This demo first evaluates a NixOS toplevel, then starts a debugger session while
that evaluation's heap remains available to inspect.

![Debugging after a NixOS evaluation with a large retained heap](demo/nixos-debugger.gif)

## Quick start

`fix` is alpha-quality software under active development. The development
environment is exercised on x86_64 Linux; other platforms have received less
testing.

Nix is not required to build `fix`. A direct build requires only Zig 0.16:

```console
$ git clone https://github.com/psyclyx/fix
$ cd fix
$ zig build --release=fast
```

The executable is `zig-out/bin/fix`. Alternatively, Nix can provide the pinned
build environment and dependencies:

```console
$ nix-shell --run 'zig build --release=fast'
```

Evaluation does not require a Nix or Lix executable. Store-writing commands
need a reachable Nix or Lix daemon.

```console
$ ./zig-out/bin/fix eval -E '1 + 2'
3

$ ./zig-out/bin/fix build -A fix

$ ./zig-out/bin/fix repl
```

The package also includes shell completions for Bash, Fish, and Zsh.

### Nix and Lix runtime compatibility

`fix` speaks the stable Nix worker protocol to CppNix and Lix daemons
(Nix ≥ 2.4) over `daemon`, `unix://`, `tcp://`, and `ssh-ng://` stores.
`local`/`auto` stores and Lix's experimental `lix-xp-1` protocol are not
implemented and fail explicitly — nothing falls back to an installed Nix.
The selector matrix and configuration details are in
[Nix/Lix store compatibility](docs/store-compatibility.md).

`<nixpkgs>` and other lookup paths resolve like Nix's: from `-I`, then
`$NIX_PATH`, and — when neither is set — from the user and root channel
profiles, so a machine configured purely through `nix-channel` works without
any environment setup.

`builtins.nixVersion` deliberately reports `2.18.3`: it is the evaluator
compatibility baseline, not the version of the connected daemon. Supported
experimental and deprecated language switches are listed in
[the CLI reference](docs/cli.md#evaluation--output).

## What it can do

`fix` covers the common path from evaluating an expression to realizing and
running its output:

| Command | Purpose |
| --- | --- |
| `fix eval` | Evaluate expressions, files, attributes, or flake outputs |
| `fix instantiate` | Evaluate derivations and write their `.drv` files |
| `fix build` | Evaluate and build derivations, with result links and GC roots |
| `fix run` | Build an installable and run its declared program |
| `fix shell` | Enter a shell containing selected packages |
| `fix print-dev-env` | Emit a derivation's build environment as a shell script |
| `fix repl` | Evaluate interactively and enter the explorer or debugger |
| `fix parse` | Parse Nix and emit a compatible JSON syntax tree |
| `fix disasm` | Compile an expression and print its bytecode |
| `fix flake` | Show, check, lock, update, and inspect flake metadata |
| `fix switch` | Build and activate a system or user configuration |
| `fix completions` | Generate shell completions |

Run `fix <command> --help` for the documented inputs and options.

### Evaluate, instantiate, and build

Commands accept expressions, file paths, attribute paths, and repeated mixed
inputs. File paths are positional, and omitting the source uses `./default.nix`:

```console
$ fix eval -E '{ answer = 6 * 7; }' -A answer
42

$ fix eval --strict --json packages.nix

$ fix instantiate -A fix
/nix/store/...-fix.drv

$ fix build -A fix
```

Arguments can be supplied with `--arg` and `--argstr`. Evaluation can produce
Nix, JSON, XML, or raw output, and can be made strict. Builds can target direct
Unix-socket, SSH, and TCP daemon endpoints.

### Run programs and open temporary shells

```console
$ fix run --flake nixpkgs#hello

$ fix shell -p ripgrep jq
```

`fix run` builds the selected installable and chooses its executable from
`meta.mainProgram`, `pname`, or `name`. `fix shell` constructs and realizes an
environment containing the requested packages.

Flake commands require Nix's `flakes` experimental feature. Enable it in
`nix.conf`, or pass it for an invocation:

```console
$ fix flake show . --extra-experimental-features flakes
```

### Development environments and direnv

`fix print-dev-env` evaluates a derivation and prints a Bash program that
reconstructs its build environment without building the derivation:

```console
$ eval "$(fix print-dev-env ./shell.nix)"
```

The included direnv integration provides `use fix` and `use fix_flake`. See
[the direnv documentation](contrib/direnv/README.md) for installation and
options.

### `fix switch`

`fix switch` can build and activate NixOS configurations and implements the
conventional nix-darwin and Home Manager activation paths. It supports
`switch`, `boot`, `test`, `build`, and `dry-activate` actions. When supplied,
the action must be the first argument after `fix switch`.

```console
$ fix switch --nixos

$ fix switch build --home-manager --flake .#me
```

This command is experimental. Its scope and interface may change; do not use it
as a stable automation interface.

## Explorer and debugger

Start the REPL with `fix repl`. From there:

- `:vm` opens the full-screen VM explorer;
- `:d EXPR` evaluates an expression in the debugger; and
- `:help` lists the available REPL commands.

The debugger can also be enabled directly on an evaluation:

```console
$ fix eval --debugger ./expression.nix
```

Inside the debugger, `break FILE:LINE` adds a source breakpoint. A breakpoint
may remain pending until that source is compiled; it resolves automatically
when the matching code appears. `breakpoints` lists breakpoints and `delete N`
removes one. `:gc` runs a full collection while preserving the paused session's
values and refreshes the heap views.

Both tools also have bounded text output for non-interactive use. Start the REPL
with `fix repl --no-tui` when an alternate-screen interface is undesirable.

## Performance

The chart and tables are point-in-time measurements from pinned inputs, not a
claim that `fix` wins every workload. They compare wall-clock evaluation time
across synthetic stress tests, real NixOS and Home Manager configurations, and
JSON-producing workloads. Each cell is relative to the fastest evaluator for
that workload; `1.00×` is fastest. The harness defaults to five recorded runs.

Every evaluator runs in its best default configuration, one row each.
`fix (warm)` and `fix (cold)` are fix at its automatic worker count with the
persistent compile cache warm (populated by a warmup run) or cold (the cache
directory is wiped before every timed run) — the cache is a real speedup, so
it is shown explicitly rather than baked invisibly into one number. `nix` and
`lix` are the pinned CppNix and Lix; `detsys` is
[Determinate Nix](https://github.com/DeterminateSystems/nix-src) with
`--eval-cores 0` (all cores). The realworld suite also runs `all-configs`:
every configuration passed on a single command line, where a parallel
evaluator can overlap independent evaluations. Every harness run
(`./bench/run`) writes a `provenance.md` next to the results recording the
date, hardware, run settings, tool versions, pins, and measured commit —
reproduce and compare against your own hardware rather than trusting these
numbers.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="bench/results/summary-dark.png">
  <img alt="fix evaluator benchmark summary" src="bench/results/summary.png">
</picture>

The data behind the chart lives in [`bench/results/`](bench/results/):
[provenance](bench/results/provenance.md), plus per-workload Hyperfine
tables and raw JSON under each suite directory. `./bench/run` reruns the
whole benchmark and rewrites that directory in place.

The timing harness uses Hyperfine, with separate warmup and measured runs and
optional cache reclamation between runs.
Correctness is checked separately by `zig build test-bench-fixtures`; it is not
part of the timing script. See [the benchmark documentation](bench/README.md)
for the workloads and reproduction commands.

### A less rigorous benchmark
`fix` runs [nixboy](https://github.com/psyclyx/nixboy), a Game Boy emulator written in Nix.

<details>
<summary>Pokemon Red (every third frame, playback 2x speed)</summary>

https://github.com/user-attachments/assets/0353b17c-f196-4dda-ba19-1329b651d9ae

</details>

<details>
<summary>Bad Apple!! (every frame, playback 5x speed)</summary>
  
https://github.com/user-attachments/assets/3e3e44af-03dc-4c4d-89aa-e64eddf847cc

</details>

## Installing through a module

The repository exports modules for NixOS, nix-darwin, and Home Manager:

```nix
let
  fixSource = /path/to/a/pinned/fix;
  fixProject = import fixSource {};
in {
  imports = [
    fixProject.homeManagerModules.fix
  ];

  programs.fix.enable = true;
}
```

Use `nixosModules.fix` or `darwinModules.fix` in the corresponding module
system. Enabling `programs.direnv` enables the bundled integration by default
and installs `fix`; it can be controlled explicitly with
`programs.direnv.fix.enable`. Use `programs.fix.enable` when you want the CLI
without direnv.

## Project status

`fix` is alpha-quality software under active development. Compatibility is a
concrete target backed by focused and differential tests, but not a promise
that every Nix program or workflow is supported. A Nix or Lix daemon is needed
for store operations and builds; it need not be supplied by a locally installed
Nix executable.

If `fix` produces a different value, derivation, or store path from Nix for
supported input, that is a bug. Releases are documented in
[the changelog](CHANGELOG.md).

## Development

Enter the pinned development environment and build an optimized binary with:

```console
$ nix-shell --run 'zig build --release=fast'
```

The result is `zig-out/bin/fix`. Useful checks include:

```console
$ zig build test
$ zig build check
$ zig build test-lang
$ zig build test-bench-fixtures
$ zig build test-nixpkgs
```

Start with [the developer documentation](docs/README.md) for the architecture,
runtime invariants, testing strategy, and performance model.
