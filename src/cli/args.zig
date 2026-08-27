//! Command-line option parsing for `fix`, driven by a single option table
//! (`specs`). The table is the source of truth for names, value arity, and help
//! text, so `parse` matches generically, `--help` renders from it, and shell
//! completions can be generated from it. Adding an option means adding a `Spec`
//! entry plus one `apply` arm.

const std = @import("std");
const presentation = @import("presentation.zig");
const engine = @import("expr");
const hugetlb = @import("base").hugetlb;
const feature_lists = @import("args/features.zig");
const option_apply = @import("args/apply.zig");
const command_meta = @import("command_meta.zig");

pub const OutputFormat = enum {
    nix,
    raw,
    json,
    xml,
};

/// Nix-style experimental features. Names match Nix's spelling so that the
/// same `--experimental-features pipe-operators` invocation works here.
pub const ExperimentalFeature = feature_lists.ExperimentalFeature;
pub const ExperimentalFeatures = feature_lists.ExperimentalFeatures;

/// Nix-style deprecated features (Lix `--extra-deprecated-features`). Enabling
/// one re-permits behaviour that fix rejects by default. Names match Lix.
pub const DeprecatedFeature = feature_lists.DeprecatedFeature;
pub const DeprecatedFeatures = feature_lists.DeprecatedFeatures;

/// Like `parseFeatureList`, but for features sourced from `nix.conf` rather than
/// argv: unknown names are silently skipped (Nix only warns for config-sourced
/// `experimental-features`, and rejecting would make an unrelated Nix setting
/// break `fix`). Never fails.
pub fn mergeConfigFeatures(set: *ExperimentalFeatures, list: []const u8) void {
    feature_lists.mergeConfigured(set, list);
}

pub const EvaluationMode = struct {
    output: OutputFormat = .nix,
    strict: bool = false,
};

pub const SourceArg = union(enum) {
    expr: []const u8,
    file: []const u8,
    /// A flake installable `<flakeref>[#<attrpath>]` from `--flake`. Lowered
    /// to a `builtins.getFlake` expression at source-load time (see
    /// `cli/run.zig`). Requires the `flakes` experimental feature.
    flake: []const u8,
};

/// A `--arg NAME EXPR` / `--argstr NAME STR` top-level function argument. When
/// the source evaluates to a function, it is auto-called with these (as in
/// `nix-instantiate`). `value` is a Nix expression when `is_string` is false,
/// or a literal string when true. Both fields are borrowed from argv.
pub const ArgDef = struct {
    name: []const u8,
    value: []const u8,
    is_string: bool,
};

/// Borrowed, value-oriented projection used by source loading/lowering.
/// It cannot deinitialize or mutate the owning `Options` lists.
pub const SourceOptions = struct {
    cmd: Cmd = .eval,
    attr: ?[]const u8 = null,
    arg_defs: []const ArgDef = &.{},
    impure: bool = false,
};

/// A `--option NAME VALUE` override for a `nix.conf` setting. Applied over the
/// loaded config at highest precedence (see `setup.Session.configure`). Borrowed from
/// argv.
pub const OptionOverride = struct {
    name: []const u8,
    value: []const u8,
};

/// Which subcommand is asking. The shared parser uses this to reject options
/// outside their command and to scope help and completions.
pub const Cmd = command_meta.Kind;

/// Semantic value classes consumed by the live shell completer. The parser's
/// option table owns these hints so help, parsing, and completion cannot drift.
pub const CompletionHint = enum {
    none,
    file,
    installable,
    attr,
    package,
    color,
    experimental_feature,
    deprecated_feature,
    setting,
    max_jobs,
    hugetlb,
    timeline_flows,
};

pub const CompletionArity = enum { flag, opt, req, req2, multi };

pub const CompletionOption = struct {
    arity: CompletionArity,
    hints: [2]CompletionHint,
};

/// `fix switch` target: which activation flavour to build and switch to. Chosen
/// by `--nixos`/`--darwin`/`--home-manager`, else auto-detected in `switch.zig`.
pub const SwitchTarget = enum { nixos, darwin, home_manager };

pub const Options = struct {
    /// Which subcommand these options belong to. Set by `parse`; used to pick
    /// the flake-installable resolution profile (which output namespaces a
    /// fragment resolves against).
    cmd: Cmd = .eval,
    output: OutputFormat = .nix,
    strict: bool = false,
    /// Legacy `nix-instantiate --eval --read-write-mode`: permit evaluation to
    /// register derivations and fetched sources in the store while still
    /// rendering the evaluated value rather than a top-level `.drv` path.
    read_write_mode: bool = false,
    /// `--no-location`: omit source positions from `--xml` output. fix's XML
    /// serializer never emits positions, so this is accepted for CLI/tooling
    /// compatibility (Nix's `nix-instantiate --eval --xml --no-location`) and
    /// is effectively a no-op — the output already matches Nix's no-location form.
    no_location: bool = false,
    /// `--impure`: disable pure evaluation. Flake installables evaluate in pure
    /// mode by default (getEnv hidden, out-of-tree reads and unlocked fetches
    /// forbidden); this opts back out.
    impure: bool = false,
    experimental_features: ExperimentalFeatures = .{},
    /// True once `--experimental-features` (the replace form) has been seen on
    /// the CLI. It overrides the `nix.conf` base entirely; without it the config
    /// value is the base and `--extra-experimental-features` appends to it (Nix
    /// precedence). See `setup.Session.configure`.
    experimental_features_reset: bool = false,
    /// Deprecated features enabled via `--extra-deprecated-features` /
    /// `--deprecated-features` (Lix compat).
    deprecated_features: DeprecatedFeatures = .{},
    deprecated_features_reset: bool = false,
    /// `--option NAME VALUE`: nix.conf setting overrides, in argv order.
    /// Borrowed from argv; the list backing is owned (caller frees via `deinit`).
    option_overrides: std.ArrayListUnmanaged(OptionOverride) = .empty,
    color: presentation.When = .auto,
    progress: presentation.ProgressMode = .enabled,
    /// `fix repl --no-tui`: keep the ordinary interactive line editor, but
    /// render `:debug` and `:vm` through their line-oriented interfaces rather
    /// than entering an alternate-screen workspace.
    no_tui: bool = false,
    show_trace: bool = false,
    /// Drop into the interactive debug console at `builtins.break` (and, later,
    /// on evaluation errors). Forces single-worker, speculation-free evaluation
    /// so the pause point is deterministic.
    debugger: bool = false,
    /// `fix build --no-link`/`--no-out-link`: skip creating the result symlink.
    no_link: bool = false,
    /// `fix build --dry-run`: evaluate and instantiate, then report the daemon's
    /// missing build/substitution plan without realizing it.
    dry_run: bool = false,
    /// `fix instantiate --find-file`: resolve each source argument as a name in
    /// NIX_PATH and print its absolute path without parsing or evaluating it.
    find_file: bool = false,
    /// `-Q`/`--no-build-output`: consume daemon build log messages silently.
    no_build_output: bool = false,
    /// `--out-link NAME`/`-o`: name of the result symlink (default `result`).
    out_link: ?[]const u8 = null,
    /// `--drv-link NAME`: name of the derivation symlink (default `derivation`).
    drv_link: ?[]const u8 = null,
    /// `--add-drv-link`: also create a symlink to the top-level `.drv`.
    add_drv_link: bool = false,
    /// `--add-root PATH`: create the output/`.drv` link at PATH and register it
    /// as an (indirect) GC root. Borrowed from argv.
    add_root: ?[]const u8 = null,
    /// `--indirect`: make the `--add-root` root indirect (accepted; roots here
    /// are always registered indirectly).
    indirect: bool = false,
    /// `--check`: rebuild and verify outputs are unchanged (BuildMode check).
    check: bool = false,
    /// `--repair`: rebuild and repair corrupted store paths (BuildMode repair).
    repair: bool = false,
    /// `--verbose`/`-v` repeat count controls progress detail and daemon logs.
    verbose: u8 = 0,
    /// `fix switch --nixos|--darwin|--home-manager`: the activation target.
    /// `null` = auto-detect (see `switch.zig:resolveTarget`).
    switch_target: ?SwitchTarget = null,
    /// `fix switch --activate-toplevel PATH` (hidden, internal): when set, the
    /// eval+build phase is skipped and the given store path is activated. This
    /// is how the non-root run re-execs its privileged half under `sudo`.
    activate_toplevel: ?[]const u8 = null,
    /// `fix shell -p <names>`: package attr-paths in `<nixpkgs>`. Borrowed from
    /// argv; the list backing is owned (caller frees via `deinit`).
    packages: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Source arguments in command-line order. `source` below mirrors the first
    /// entry for the single-input commands; `build` consumes the whole list.
    sources: std.ArrayListUnmanaged(SourceArg) = .empty,
    /// `-I`/`--include` search-path entries (`[prefix=]path`), in argv order.
    /// Prepended to `$NIX_PATH` at setup (they take precedence, as in Nix).
    /// Borrowed from argv; the list backing is owned (caller frees via `deinit`).
    include: std.ArrayListUnmanaged([]const u8) = .empty,
    /// `-A`/`--attr`: dotted attribute path to select from the evaluated value
    /// (as in `nix-build -A`). Borrowed from argv.
    attr: ?[]const u8 = null,
    /// Attribute selectors in command-line order. `attr` above mirrors the last
    /// entry for the existing single-selector commands; `build` consumes all.
    attrs: std.ArrayListUnmanaged([]const u8) = .empty,
    /// `--arg`/`--argstr` top-level function arguments, in argv order. Borrowed
    /// from argv; the list backing is owned (caller frees via `deinit`).
    arg_defs: std.ArrayListUnmanaged(ArgDef) = .empty,
    /// `fix disasm --chunk N`: disassemble only chunk #N (else all reachable).
    disasm_chunk: ?u32 = null,
    /// `fix disasm --no-recurse`: only show the top chunk.
    disasm_no_recurse: bool = false,
    /// `fix disasm --no-source`: omit source-span annotations.
    disasm_no_source: bool = false,
    /// `fix disasm --no-constants`: omit the constant-pool listing.
    disasm_no_constants: bool = false,
    /// `fix disasm --no-bytes`: omit the raw-bytecode hex column.
    disasm_no_bytes: bool = false,
    /// `fix disasm --no-pager`: never pipe output to `$PAGER`.
    disasm_no_pager: bool = false,
    /// `fix disasm --eval`: evaluate first, then disassemble every chunk that
    /// compiled (follows imports and lazy attr bodies), instead of statically
    /// compiling the top expression only.
    disasm_eval: bool = false,
    /// Print command-specific evaluator or bytecode statistics.
    stats: bool = false,
    source: ?SourceArg = null,
    vm_trace_path: ?[:0]const u8 = null,
    vm_trace_format: enum { text, binary } = .text,
    vm_trace_max_events: u64 = 0,
    vm_trace_main_only: bool = false,
    thunks_log_path: ?[:0]const u8 = null,
    workers: ?u8 = null,
    /// `--no-compile-cache`: skip the persistent compiled-chunk cache for
    /// this invocation (compile everything from source).
    no_compile_cache: bool = false,
    /// `--compile-cache-dir DIR`: compiled-chunk cache root override
    /// (default `$XDG_CACHE_HOME/fix/chunks`). Borrowed from argv.
    compile_cache_dir: ?[]const u8 = null,
    /// GC collection-budget override in bytes (`--gc-budget`); see
    /// `eval/gc_controller.zig:memoryBudget`. `null` = the automatic RAM-scaled line;
    /// `0` = never collect.
    gc_budget: ?u64 = null,
    /// `--hugetlb auto|on|off`: back the evaluation heap with explicit 2 MB
    /// huge pages. `null` selects `auto`; resolution happens in
    /// `setup.applyMemoryBacking`, before the heap maps.
    hugetlb: ?hugetlb.Mode = null,
    /// Enable background thunk forcing unless `--no-spec-thunks` is given.
    /// Disabling it bounds speculative work and memory at the cost of less
    /// parallelism.
    disable_spec_thunks: bool = false,
    disable_fanout: bool = false,
    /// `--mem-report[=dump]`: peak memory attribution at evaluator teardown.
    mem_report: ?[]const u8 = null,
    /// `--gc-report`: collection summary at evaluator teardown.
    gc_report: bool = false,
    timeline_path: ?[]const u8 = null,
    /// `--timeline-flows`: include scheduler steal arrows. They have a
    /// separate recorder budget and cannot displace primary spans.
    timeline_flows: bool = true,

    pub fn addSource(self: *Options, allocator: std.mem.Allocator, source: SourceArg) !void {
        try self.sources.append(allocator, source);
        if (self.source == null) self.source = source;
    }

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.packages.deinit(allocator);
        self.sources.deinit(allocator);
        self.include.deinit(allocator);
        self.attrs.deinit(allocator);
        self.arg_defs.deinit(allocator);
        self.option_overrides.deinit(allocator);
    }

    /// The source to evaluate when none was given on the command line: the
    /// `./default.nix`, matching `nix-build`/`nix-instantiate`. Flakes are
    /// explicit typed inputs (`--flake REF`), so they never change this default.
    pub fn defaultSource(self: *const Options) SourceArg {
        _ = self;
        return .{ .file = "default.nix" };
    }

    pub fn evaluationMode(self: *const Options) EvaluationMode {
        return .{
            .output = self.output,
            .strict = self.strict,
        };
    }

    pub fn sourceOptions(self: *const Options) SourceOptions {
        return self.sourceOptionsWithAttr(self.attr);
    }

    pub fn sourceOptionsWithAttr(self: *const Options, attr: ?[]const u8) SourceOptions {
        return .{
            .cmd = self.cmd,
            .attr = attr,
            .arg_defs = self.arg_defs.items,
            .impure = self.impure,
        };
    }
};

// ---------------------------------------------------------------------------
// Option table
// ---------------------------------------------------------------------------

/// Stable identity of each option. `apply` switches on it.
pub const Opt = enum {
    // Source selection.
    expr,
    file,
    flake,
    include,
    attr,
    arg,
    argstr,
    // Output.
    json,
    raw,
    xml,
    strict,
    read_write_mode,
    no_location,
    impure,
    // Settings / features.
    experimental_features,
    extra_experimental_features,
    deprecated_features,
    extra_deprecated_features,
    option,
    // Build outputs / links.
    no_link,
    dry_run,
    find_file,
    no_build_output,
    out_link,
    drv_link,
    add_drv_link,
    add_root,
    indirect,
    // Build realization.
    check,
    repair,
    // Daemon build settings (folded into option_overrides, applied via set_options).
    max_jobs,
    cores,
    fallback,
    keep_failed,
    keep_going,
    max_silent_time,
    timeout,
    store,
    verbose,
    // Diagnostics.
    show_trace,
    no_show_trace,
    debugger,
    color,
    no_color,
    progress,
    no_progress,
    gc_budget,
    hugetlb,
    help,
    // Repl.
    no_tui,
    // Shell.
    packages,
    // Switch.
    nixos,
    darwin,
    home_manager,
    activate_toplevel,
    // Disasm.
    chunk,
    no_recurse,
    no_source,
    no_constants,
    no_bytes,
    no_pager,
    disasm_eval,
    stats,
    no_compile_cache,
    compile_cache_dir,
    // Internal perf/trace knobs (hidden from help, still parsed everywhere).
    workers,
    vm_trace,
    vm_trace_format,
    vm_trace_max_events,
    vm_trace_main_only,
    thunks_log,
    no_spec_thunks,
    no_fanout,
    mem_report,
    gc_report,
    timeline,
    timeline_flows,
};

/// Value arity of an option.
const Arg = enum {
    /// No value: `--json`. (`--json=x` is an error.)
    flag,
    /// Optional value, supplied only via `--x=value`; the bare `--x` form is
    /// valid. Never consumes the next token (avoids swallowing a positional).
    opt,
    /// One required value: `--x value`, `--x=value`, or short `-Xvalue`.
    req,
    /// Two required values: `--x NAME VALUE`.
    req2,
    /// Consumes following non-option tokens (`-p pkg1 pkg2`), then returns to
    /// ordinary option parsing at the next option.
    multi,
};

const Spec = struct {
    id: Opt,
    long: ?[]const u8 = null,
    short: ?[]const u8 = null,
    arg: Arg = .flag,
    /// Placeholder shown in help (`PATH`, `NAME EXPR`, `WHEN`, ...). For `.flag`
    /// options a non-empty metavar renders as an optional operand.
    metavar: []const u8 = "",
    /// One-line (or multi-line, `\n`-separated) help text.
    help: []const u8 = "",
    /// Concise pager text when the full help contains details better suited to
    /// `--help`. Argument shape, defaults, and repeatability are rendered
    /// separately.
    completion_help: ?[]const u8 = null,
    /// Stable default associated with this option, shown structurally by shell
    /// completions rather than buried in prose.
    default_value: ?[]const u8 = null,
    /// Whether the option itself may be supplied more than once.
    repeatable: bool = false,
    /// Subcommands whose `--help` lists this option; empty = all of them.
    show_in: []const Cmd = &.{},
    /// Internal knob: parsed everywhere but never shown in help.
    hidden: bool = false,
    /// Completion class for the first and (for `.req2`) second values.
    complete: [2]CompletionHint = .{ .none, .none },
};

/// Commands that take a source expression and its selectors (everything but the
/// streaming `repl`). `disasm` compiles rather than evaluates, but shares the same
/// source model (bare path / `-E` / `--file` / `--flake` / `-A` / `-I`).
const source_cmds = &[_]Cmd{ .eval, .parse, .instantiate, .build, .run, .shell, .disasm, .@"switch", .print_dev_env };
/// Source wrappers/selectors operate on evaluated text. `parse` consumes the
/// original file/expression bytes and therefore intentionally excludes these.
const selected_source_cmds = &[_]Cmd{ .eval, .instantiate, .build, .run, .shell, .disasm, .@"switch", .print_dev_env };
/// Commands that run the evaluator, so diagnostics (`--show-trace`, `--color`),
/// progress, and the GC memory budget apply. `disasm` stops at compilation, so
/// it is excluded.
const eval_cmds = &[_]Cmd{ .eval, .instantiate, .build, .run, .shell, .repl, .@"switch", .print_dev_env };
/// Commands with a meaningful evaluator/bytecode statistics report.
const stats_cmds = &[_]Cmd{ .eval, .instantiate, .build, .run, .shell, .repl, .disasm, .@"switch" };
/// One-shot evaluator commands that can write a complete Perfetto capture.
const timeline_cmds = &[_]Cmd{ .eval, .instantiate, .build };
/// Commands that print an evaluated value, so the output format (`--json`,
/// `--xml`) and `--strict` apply. The realizing commands print store paths, not
/// a value, and `disasm` prints bytecode.
const value_cmds = &[_]Cmd{ .eval, .repl };
/// `parse` always emits JSON but accepts `--json` for nix-instantiate and
/// language-runner compatibility.
const json_cmds = &[_]Cmd{ .eval, .parse, .repl };
/// Commands that produce a top-level `.drv` a link/root can point at.
const drv_cmds = &[_]Cmd{ .build, .instantiate };
/// Commands that realize (build/substitute) derivations via the daemon.
const realize_cmds = &[_]Cmd{ .build, .run, .shell, .@"switch", .print_dev_env };
/// Legacy nix-instantiate accepts daemon build settings in all of its modes;
/// eval can use them for IFD, while parse/find-file simply accept them as
/// process-wide compatibility settings. Realizing commands use them directly.
const daemon_setting_cmds = &[_]Cmd{ .eval, .parse, .instantiate, .build, .run, .shell, .@"switch", .print_dev_env };
const verbose_cmds = &[_]Cmd{ .eval, .parse, .instantiate, .build, .run, .shell, .repl, .@"switch", .print_dev_env };

const specs = [_]Spec{
    .{ .id = .expr, .short = "-E", .long = "--expr", .arg = .req, .metavar = "EXPR", .help = "evaluate expression text; repeatable", .completion_help = "evaluate expression text", .repeatable = true, .show_in = source_cmds },
    .{ .id = .file, .short = "-f", .long = "--file", .arg = .req, .metavar = "FILEISH", .help = "evaluate a legacy fileish input (`-` reads stdin);\nrepeatable", .completion_help = "evaluate a legacy fileish input (`-` reads stdin)", .repeatable = true, .show_in = source_cmds, .complete = .{ .file, .none } },
    .{ .id = .flake, .long = "--flake", .arg = .req, .metavar = "INSTALLABLE", .help = "evaluate one flake output <flakeref>[#<attrpath>];\nrepeatable; requires the flakes feature", .completion_help = "evaluate a flake output; requires flakes", .repeatable = true, .show_in = selected_source_cmds, .complete = .{ .installable, .none } },
    .{ .id = .include, .short = "-I", .long = "--include", .arg = .req, .metavar = "PATH", .help = "prepend a search-path entry (as in NIX_PATH);\nPATH may be `prefix=path`. Repeatable.", .completion_help = "prepend a NIX_PATH search-path entry", .repeatable = true, .show_in = source_cmds, .complete = .{ .file, .none } },
    .{ .id = .attr, .short = "-A", .long = "--attr", .arg = .req, .metavar = "ATTR", .help = "select attribute path ATTR from the result", .show_in = selected_source_cmds, .complete = .{ .attr, .none } },
    .{ .id = .arg, .long = "--arg", .arg = .req2, .metavar = "NAME EXPR", .help = "pass EXPR as top-level function argument NAME", .show_in = selected_source_cmds },
    .{ .id = .argstr, .long = "--argstr", .arg = .req2, .metavar = "NAME STR", .help = "pass string STR as top-level function argument NAME", .show_in = selected_source_cmds },

    .{ .id = .json, .long = "--json", .help = "write output as JSON", .show_in = json_cmds },
    .{ .id = .raw, .long = "--raw", .help = "write a string value without quoting or a newline", .show_in = &.{.eval} },
    .{ .id = .xml, .long = "--xml", .help = "write the evaluated value as XML", .show_in = value_cmds },
    .{ .id = .no_location, .long = "--no-location", .help = "omit source positions from --xml output", .show_in = value_cmds },
    .{ .id = .strict, .long = "--strict", .help = "recursively force values before writing", .show_in = value_cmds },
    .{ .id = .read_write_mode, .long = "--read-write-mode", .help = "allow eval to register derivations and sources in\nthe store", .show_in = &.{.eval} },
    .{ .id = .impure, .long = "--impure", .help = "disable pure evaluation for flake installables\n(allow env, out-of-tree reads, unlocked fetches)", .show_in = selected_source_cmds },

    .{ .id = .experimental_features, .long = "--experimental-features", .arg = .req, .metavar = "FEATS", .help = "space-separated experimental features to enable,\nreplacing the current set (available: pipe-operators,\nfetch-tree, flakes, coerce-integers)", .completion_help = "replace enabled experimental features", .complete = .{ .experimental_feature, .none } },
    .{ .id = .extra_experimental_features, .long = "--extra-experimental-features", .arg = .req, .metavar = "FEATS", .help = "like --experimental-features, but adds to the set", .complete = .{ .experimental_feature, .none } },
    .{ .id = .deprecated_features, .long = "--deprecated-features", .arg = .req, .metavar = "FEATS", .help = "space-separated deprecated features to re-enable;\nsee docs/cli.md for the complete compatibility list", .completion_help = "replace deprecated features to re-enable", .complete = .{ .deprecated_feature, .none } },
    .{ .id = .extra_deprecated_features, .long = "--extra-deprecated-features", .arg = .req, .metavar = "FEATS", .help = "like --deprecated-features, but adds to the set", .complete = .{ .deprecated_feature, .none } },
    .{ .id = .option, .long = "--option", .arg = .req2, .metavar = "NAME VALUE", .help = "override a nix.conf setting", .complete = .{ .setting, .none } },
    .{ .id = .no_compile_cache, .long = "--no-compile-cache", .help = "do not read or write the persistent compiled-chunk\ncache; compile everything from source", .completion_help = "disable the persistent compiled-chunk cache", .show_in = eval_cmds },
    .{ .id = .compile_cache_dir, .long = "--compile-cache-dir", .arg = .req, .metavar = "DIR", .help = "compiled-chunk cache root (default:\n$XDG_CACHE_HOME/fix/chunks)", .completion_help = "compiled-chunk cache root", .show_in = eval_cmds, .complete = .{ .file, .none } },

    .{ .id = .out_link, .short = "-o", .long = "--out-link", .arg = .req, .metavar = "NAME", .help = "name of the result symlink (default: result)", .completion_help = "name of the result symlink", .default_value = "result", .show_in = &.{.build}, .complete = .{ .file, .none } },
    .{ .id = .no_link, .long = "--no-out-link", .help = "do not create the result symlink", .show_in = &.{.build} },
    .{ .id = .no_link, .long = "--no-link", .show_in = &.{.build}, .hidden = true }, // alias of --no-out-link
    .{ .id = .dry_run, .long = "--dry-run", .help = "show what would be built or substituted", .show_in = &.{.build} },
    .{ .id = .find_file, .long = "--find-file", .help = "look up source arguments in NIX_PATH and print\ntheir absolute paths", .show_in = &.{.instantiate} },
    .{ .id = .drv_link, .long = "--drv-link", .arg = .req, .metavar = "NAME", .help = "name of the derivation symlink (default: derivation)", .completion_help = "name of the derivation symlink", .default_value = "derivation", .show_in = drv_cmds, .complete = .{ .file, .none } },
    .{ .id = .add_drv_link, .long = "--add-drv-link", .help = "also create a symlink to the .drv", .show_in = drv_cmds },
    .{ .id = .add_root, .long = "--add-root", .arg = .req, .metavar = "PATH", .help = "create the link at PATH and register it as a GC root", .show_in = drv_cmds, .complete = .{ .file, .none } },
    .{ .id = .indirect, .long = "--indirect", .help = "make the --add-root GC root indirect", .show_in = drv_cmds },

    .{ .id = .check, .long = "--check", .help = "rebuild and check that outputs are unchanged", .show_in = realize_cmds },
    .{ .id = .repair, .long = "--repair", .help = "rebuild and repair corrupted store paths", .show_in = realize_cmds },
    .{ .id = .max_jobs, .short = "-j", .long = "--max-jobs", .arg = .req, .metavar = "N", .help = "maximum number of parallel build jobs (or `auto`)", .show_in = daemon_setting_cmds, .complete = .{ .max_jobs, .none } },
    .{ .id = .cores, .long = "--cores", .arg = .req, .metavar = "N", .help = "build cores per job (0 = all available)", .show_in = daemon_setting_cmds },
    .{ .id = .fallback, .long = "--fallback", .help = "build from source if a substitute fails", .show_in = daemon_setting_cmds },
    .{ .id = .keep_failed, .short = "-K", .long = "--keep-failed", .help = "keep the build tree of failed builds", .show_in = daemon_setting_cmds },
    .{ .id = .keep_going, .short = "-k", .long = "--keep-going", .help = "keep building other derivations if one fails", .show_in = daemon_setting_cmds },
    .{ .id = .max_silent_time, .long = "--max-silent-time", .arg = .req, .metavar = "SECS", .help = "abort a build silent for SECS seconds (0 = no limit)", .show_in = daemon_setting_cmds },
    .{ .id = .timeout, .long = "--timeout", .arg = .req, .metavar = "SECS", .help = "abort a build running longer than SECS (0 = no limit)", .show_in = daemon_setting_cmds },
    .{ .id = .store, .long = "--store", .arg = .req, .metavar = "STORE-URI", .help = "store: daemon/unix, ssh-ng, or tcp URI\n(native local/XP backends are pending)", .show_in = daemon_setting_cmds },
    .{ .id = .verbose, .short = "-v", .long = "--verbose", .help = "increase progress detail and daemon build verbosity (repeatable)", .completion_help = "increase progress and build verbosity", .repeatable = true, .show_in = verbose_cmds },
    .{ .id = .no_build_output, .short = "-Q", .long = "--no-build-output", .help = "suppress builder output", .show_in = daemon_setting_cmds },

    .{ .id = .stats, .long = "--stats", .help = "print evaluator or bytecode corpus statistics", .show_in = stats_cmds },
    .{ .id = .show_trace, .long = "--show-trace", .help = "show full evaluation traces on error", .show_in = eval_cmds },
    .{ .id = .no_show_trace, .long = "--no-show-trace", .help = "truncate long evaluation traces on error (default)", .show_in = eval_cmds },
    .{ .id = .debugger, .long = "--debugger", .help = "pause into an interactive debugger at builtins.break\n(forces --workers=1)", .show_in = &[_]Cmd{ .eval, .repl } },
    .{ .id = .color, .long = "--color", .arg = .opt, .metavar = "WHEN", .help = "color diagnostics: auto, always, never", .default_value = "auto", .complete = .{ .color, .none } },
    .{ .id = .no_color, .long = "--no-color", .help = "disable color diagnostics" },
    .{ .id = .progress, .long = "--progress", .help = "write timestamped progress records", .show_in = eval_cmds },
    .{ .id = .no_progress, .long = "--no-progress", .help = "disable evaluation progress", .show_in = eval_cmds },
    .{ .id = .gc_budget, .long = "--gc-budget", .arg = .req, .metavar = "SIZE", .help = "override the automatic GC collection budget (MiB,\nor with a k/m/g suffix; 0 = never collect).\nDefault: auto, scaled to RAM.", .completion_help = "set the GC collection budget", .default_value = "auto", .show_in = eval_cmds },
    .{ .id = .hugetlb, .long = "--hugetlb", .arg = .req, .metavar = "MODE", .help = "back the evaluation heap with 2 MB huge pages: auto,\non, off (default auto = only when the kernel pool\nhas capacity; provision via vm.nr_hugepages)", .completion_help = "configure 2 MB huge pages", .default_value = "auto", .show_in = eval_cmds, .complete = .{ .hugetlb, .none } },
    .{ .id = .timeline, .long = "--timeline", .arg = .opt, .metavar = "PATH", .help = "write a Perfetto timeline to PATH\n(default: fix-timeline.json)", .completion_help = "write a Perfetto timeline", .default_value = "fix-timeline.json", .show_in = timeline_cmds, .complete = .{ .file, .none } },
    .{ .id = .timeline_flows, .long = "--timeline-flows", .arg = .req, .metavar = "off|all", .help = "record all scheduler steal flows or none\n(default: all)", .completion_help = "record scheduler steal flows", .default_value = "all", .show_in = timeline_cmds, .complete = .{ .timeline_flows, .none } },
    .{ .id = .help, .short = "-h", .long = "--help", .help = "show this help" },

    .{ .id = .no_tui, .long = "--no-tui", .help = "keep the interactive editor, but show :debug and :vm\nwithout an alternate-screen TUI", .show_in = &.{.repl} },
    .{ .id = .no_tui, .long = "--bare", .show_in = &.{.repl}, .hidden = true }, // compatibility alias

    .{ .id = .packages, .short = "-p", .long = "--packages", .arg = .multi, .metavar = "NAMES...", .help = "packages (attr paths) from <nixpkgs>, e.g. -p ripgrep jq", .show_in = &.{.shell}, .complete = .{ .package, .none } },

    .{ .id = .nixos, .long = "--nixos", .help = "build/activate a NixOS system configuration", .show_in = &.{.@"switch"} },
    .{ .id = .darwin, .long = "--darwin", .help = "build/activate a nix-darwin configuration", .show_in = &.{.@"switch"} },
    .{ .id = .home_manager, .long = "--home-manager", .help = "build/activate a home-manager configuration", .show_in = &.{.@"switch"} },
    .{ .id = .home_manager, .long = "--hm", .show_in = &.{.@"switch"}, .hidden = true }, // alias for --home-manager
    .{ .id = .activate_toplevel, .long = "--activate-toplevel", .arg = .req, .metavar = "PATH", .hidden = true },

    // Disasm.
    .{ .id = .disasm_eval, .long = "--eval", .help = "evaluate first, then disassemble every chunk that\ncompiled (imports + whatever evaluation forces)", .show_in = &.{.disasm} },
    .{ .id = .chunk, .long = "--chunk", .arg = .req, .metavar = "N", .help = "disassemble only chunk N (decimal or 0x hex, as\nshown in chunk headers; default: all reachable)", .completion_help = "disassemble only chunk N", .default_value = "all reachable", .show_in = &.{.disasm} },
    .{ .id = .no_recurse, .long = "--no-recurse", .help = "only show the top chunk", .show_in = &.{.disasm} },
    .{ .id = .no_bytes, .long = "--no-bytes", .help = "omit the raw bytecode hex column", .show_in = &.{.disasm} },
    .{ .id = .no_pager, .long = "--no-pager", .help = "do not pipe output to $PAGER", .show_in = &.{.disasm} },
    .{ .id = .no_source, .long = "--no-source", .help = "omit source-span annotations", .show_in = &.{.disasm} },
    .{ .id = .no_constants, .long = "--no-constants", .help = "omit the constant pool listing", .show_in = &.{.disasm} },

    // Hidden perf/trace knobs.
    .{ .id = .workers, .long = "--workers", .arg = .req, .metavar = "N", .hidden = true },
    .{ .id = .vm_trace, .long = "--vm-trace", .arg = .opt, .metavar = "PATH", .hidden = true },
    .{ .id = .vm_trace_format, .long = "--vm-trace-format", .arg = .req, .metavar = "FMT", .hidden = true },
    .{ .id = .vm_trace_max_events, .long = "--vm-trace-max-events", .arg = .req, .metavar = "N", .hidden = true },
    .{ .id = .vm_trace_main_only, .long = "--vm-trace-main-only", .hidden = true },
    .{ .id = .thunks_log, .long = "--thunks-log", .arg = .req, .metavar = "PATH", .hidden = true },
    .{ .id = .no_spec_thunks, .long = "--no-spec-thunks", .hidden = true },
    .{ .id = .no_fanout, .long = "--no-fanout", .hidden = true },
    .{ .id = .mem_report, .long = "--mem-report", .arg = .opt, .metavar = "dump", .hidden = true },
    .{ .id = .gc_report, .long = "--gc-report", .hidden = true },
};

fn findLong(name: []const u8) ?*const Spec {
    for (&specs) |*s| {
        if (s.long) |l| if (std.mem.eql(u8, l, name)) return s;
    }
    return null;
}

fn findShort(name: []const u8) ?*const Spec {
    for (&specs) |*s| {
        if (s.short) |sh| if (std.mem.eql(u8, sh, name)) return s;
    }
    return null;
}

fn validForCommand(spec: *const Spec, cmd: Cmd) bool {
    return spec.show_in.len == 0 or std.mem.indexOfScalar(Cmd, spec.show_in, cmd) != null;
}

/// Look up completion-relevant metadata for an exact long or short option.
/// Hidden options remain recognizable when already typed, but are omitted from
/// `writeOptionCompletions` suggestions.
pub fn completionOption(name: []const u8, cmd: Cmd) ?CompletionOption {
    const spec = (if (std.mem.startsWith(u8, name, "--")) findLong(name) else findShort(name)) orelse return null;
    if (!validForCommand(spec, cmd)) return null;
    return .{
        .arity = switch (spec.arg) {
            .flag => .flag,
            .opt => .opt,
            .req => .req,
            .req2 => .req2,
            .multi => .multi,
        },
        .hints = spec.complete,
    };
}

fn optionDisplayName(spec: *const Spec) []const u8 {
    return spec.long orelse spec.short orelse "";
}

fn pairedModifier(spec: *const Spec, visible: []const *const Spec) ?struct { key: []const u8, rank: u2 } {
    const name = spec.long orelse return null;
    const ModifierPrefix = struct { text: []const u8, rank: u2 };
    const prefixes = [_]ModifierPrefix{
        .{ .text = "--extra-", .rank = 1 },
        .{ .text = "--no-", .rank = 2 },
    };
    for (prefixes) |entry| {
        const prefix = entry.text;
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const suffix = name[prefix.len..];
        for (visible) |candidate| {
            const positive = candidate.long orelse continue;
            if (std.mem.startsWith(u8, positive, "--") and std.mem.eql(u8, positive[2..], suffix))
                return .{ .key = suffix, .rank = entry.rank };
        }
    }
    return null;
}

/// A `--extra-foo` or `--no-foo` sorts with `--foo` only when that positive
/// option is visible for this command. Standalone switches (`--no-location`,
/// `--no-recurse`, …) retain their ordinary alphabetical position.
fn optionSortKey(spec: *const Spec, visible: []const *const Spec) []const u8 {
    if (pairedModifier(spec, visible)) |modifier| return modifier.key;
    return std.mem.trimStart(u8, optionDisplayName(spec), "-");
}

const OptionSortContext = struct { visible: []const *const Spec };

fn optionLessThan(context: OptionSortContext, lhs: *const Spec, rhs: *const Spec) bool {
    const lhs_key = optionSortKey(lhs, context.visible);
    const rhs_key = optionSortKey(rhs, context.visible);
    switch (std.mem.order(u8, lhs_key, rhs_key)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    const lhs_rank = if (pairedModifier(lhs, context.visible)) |modifier| modifier.rank else 0;
    const rhs_rank = if (pairedModifier(rhs, context.visible)) |modifier| modifier.rank else 0;
    if (lhs_rank != rhs_rank) return lhs_rank < rhs_rank;
    return std.mem.lessThan(u8, optionDisplayName(lhs), optionDisplayName(rhs));
}

fn visibleSpecs(cmd: Cmd, storage: *[specs.len]*const Spec) []*const Spec {
    var count: usize = 0;
    for (&specs) |*spec| {
        if (spec.hidden or !validForCommand(spec, cmd)) continue;
        storage[count] = spec;
        count += 1;
    }
    const visible = storage[0..count];
    std.mem.sort(*const Spec, visible, OptionSortContext{ .visible = visible }, optionLessThan);
    return visible;
}

/// Emit visible option candidates as
/// `value<TAB>display-signature<TAB>description`. The insertable value stays
/// separate from structural UI such as metavariables and defaults.
pub fn writeOptionCompletions(w: *std.Io.Writer, cmd: Cmd, prefix: []const u8) !void {
    var storage: [specs.len]*const Spec = undefined;
    for (visibleSpecs(cmd, &storage)) |spec| {
        if (spec.short) |short| {
            if (std.mem.startsWith(u8, short, prefix))
                try writeOptionCompletion(w, spec, short);
        }
        if (spec.long) |long| {
            if (std.mem.startsWith(u8, long, prefix))
                try writeOptionCompletion(w, spec, long);
        }
    }
}

fn writeOptionCompletion(w: *std.Io.Writer, spec: *const Spec, value: []const u8) !void {
    try w.print("{s}\t", .{value});
    try writeCompletionSignature(w, spec, value);
    try w.writeByte('\t');
    try writeFlattenedHelp(w, spec.completion_help orelse spec.help);
    try w.writeByte('\n');
}

fn writeCompletionSignature(w: *std.Io.Writer, spec: *const Spec, value: []const u8) !void {
    try w.writeAll(value);
    // In an alias group, put structural details on the long spelling once.
    const show_details = spec.long == null or std.mem.eql(u8, value, spec.long.?);
    if (!show_details) return;
    if (spec.metavar.len != 0) {
        switch (spec.arg) {
            .flag => try w.print(" [{s}]", .{spec.metavar}),
            .opt => try w.print("[={s}]", .{spec.metavar}),
            .req, .req2, .multi => try w.print(" {s}", .{spec.metavar}),
        }
    }
    if (spec.default_value) |default| try w.print(" [default: {s}]", .{default});
    if (spec.repeatable) try w.writeAll(" [repeatable]");
}

fn writeFlattenedHelp(w: *std.Io.Writer, help: []const u8) !void {
    var pending_space = false;
    for (help) |byte| {
        if (byte == '\n') {
            pending_space = true;
            continue;
        }
        if (pending_space and byte != ' ') try w.writeByte(' ');
        pending_space = false;
        try w.writeByte(byte);
    }
}

/// Emit native Fish option declarations. Fish groups the short and long names
/// from one `complete` call into a single described candidate while retaining
/// both spellings for prefix matching and insertion.
pub fn writeFishOptionDeclarations(w: *std.Io.Writer, cmd: Cmd, command_name: []const u8) !void {
    var storage: [specs.len]*const Spec = undefined;
    const visible = visibleSpecs(cmd, &storage);

    for (visible) |spec| {
        if (spec.short == null and spec.long == null) continue;

        try w.print("complete --command fix --condition '__fix_command_is {s}' --keep-order", .{command_name});
        if (spec.short) |short| try w.print(" --short-option {s}", .{short[1..]});
        if (spec.long) |long| try w.print(" --long-option {s}", .{long[2..]});
        switch (spec.arg) {
            .flag => {},
            .opt => try w.writeAll(" --arguments '(__fix_option_candidates)'"),
            .req, .req2, .multi => try w.writeAll(" --exclusive --arguments '(__fix_option_candidates)'"),
        }
        const help = spec.completion_help orelse spec.help;
        const description = help[0 .. std.mem.indexOfScalar(u8, help, '\n') orelse help.len];
        if (description.len != 0) {
            try w.writeAll(" --description ");
            try writeFishDescription(w, spec, description);
        }
        try w.writeByte('\n');
    }
}

fn writeFishDescription(w: *std.Io.Writer, spec: *const Spec, description: []const u8) !void {
    try w.writeByte('\'');
    try writeFishEscaped(w, description);
    if (spec.repeatable and std.mem.indexOf(u8, description, "repeatable") == null and std.mem.indexOf(u8, description, "Repeatable") == null)
        try w.writeAll(" (repeatable)");
    if (spec.default_value) |default| {
        if (std.mem.indexOf(u8, description, "default") == null and std.mem.indexOf(u8, description, "Default") == null) {
            try w.writeAll(" (default: ");
            try writeFishEscaped(w, default);
            try w.writeByte(')');
        }
    }
    try w.writeByte('\'');
}

fn writeFishEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        if (byte == '\\' or byte == '\'') try w.writeByte('\\');
        try w.writeByte(byte);
    }
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Parse-failure context for user-facing reporting. `offending` borrows the
/// argument token being processed when parsing failed; it stays valid as long
/// as the caller's args iterator.
pub const Diag = struct {
    offending: ?[]const u8 = null,
};

pub fn parse(allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator, first: ?[:0]const u8, cmd: Cmd, diag: ?*Diag) !Options {
    var options: Options = .{ .cmd = cmd };
    errdefer options.deinit(allocator);

    var carried = first;
    parse_loop: while (true) {
        const arg = if (carried) |c| blk: {
            carried = null;
            break :blk c;
        } else (args_iter.next() orelse break);
        errdefer if (diag) |d| {
            d.offending = arg;
        };

        // End of options: leave the rest in the iterator (e.g. `fix run`
        // forwards them as program arguments).
        if (std.mem.eql(u8, arg, "--")) break;

        // Verbosity is conventionally clustered (`-vv`, `-vvv`). It is the
        // only repeatable short flag, so recognize its compact spelling before
        // ordinary exact/attached-value matching.
        if (repeatedVerbose(arg)) |count| {
            const verbose_spec = findShort("-v").?;
            if (std.mem.indexOfScalar(Cmd, verbose_spec.show_in, cmd) == null)
                return error.OptionNotValidForCommand;
            options.verbose +|= count;
            continue;
        }

        // Match the token against the table, extracting any inline `=value`.
        var spec: ?*const Spec = null;
        var inline_value: ?[:0]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                spec = findLong(arg[0..eq]);
                inline_value = arg[eq + 1 ..];
            } else {
                spec = findLong(arg);
            }
        } else if (arg.len >= 2 and arg[0] == '-') {
            spec = findShort(arg);
            if (spec == null) {
                // Attached short value, e.g. `-Ifoo=bar` for a `.req` short.
                const s = findShort(arg[0..2]);
                if (s != null and s.?.arg == .req) {
                    spec = s;
                    inline_value = arg[2..];
                }
            }
        } else {
            try options.addSource(allocator, .{ .file = arg });
            continue;
        }

        const s = spec orelse return error.UnknownOption;
        if (s.show_in.len != 0 and std.mem.indexOfScalar(Cmd, s.show_in, cmd) == null)
            return error.OptionNotValidForCommand;

        // Multi-value options consume non-options, then return the next option
        // to the ordinary parse loop (`-p hello jq --no-progress`).
        if (s.arg == .multi) {
            if (inline_value != null) return error.UnexpectedValue;
            var found = false;
            while (args_iter.next()) |name| {
                if (std.mem.eql(u8, name, "--")) break :parse_loop;
                if (name.len >= 2 and name[0] == '-') {
                    carried = name;
                    break;
                }
                try options.packages.append(allocator, name);
                found = true;
            }
            if (!found) return error.MissingValue;
            continue;
        }

        // Gather the option's value(s) per arity.
        var v0: ?[:0]const u8 = null;
        var v1: ?[:0]const u8 = null;
        switch (s.arg) {
            .flag => if (inline_value != null) return error.UnexpectedValue,
            .opt => v0 = inline_value,
            .req => v0 = inline_value orelse (args_iter.next() orelse return error.MissingValue),
            .req2 => {
                v0 = inline_value orelse (args_iter.next() orelse return error.MissingValue);
                v1 = args_iter.next() orelse return error.MissingSecondValue;
            },
            .multi => unreachable,
        }

        try apply(&options, allocator, s.id, v0, v1);
    }

    return options;
}

fn repeatedVerbose(arg: []const u8) ?u8 {
    if (arg.len <= 2 or arg[0] != '-') return null;
    for (arg[1..]) |byte| if (byte != 'v') return null;
    return @intCast(@min(arg.len - 1, std.math.maxInt(u8)));
}

/// Apply a matched option to `options`. `v0`/`v1` carry the gathered values
/// (present according to the spec's arity). Value-format failures surface as
/// the specific `Invalid*` errors.
fn apply(options: *Options, allocator: std.mem.Allocator, id: Opt, v0: ?[:0]const u8, v1: ?[:0]const u8) !void {
    return option_apply.apply(Options, Opt, options, allocator, id, v0, v1);
}

// ---------------------------------------------------------------------------
// Help rendering (from the table)
// ---------------------------------------------------------------------------

const help_width = 100;
const max_help_col = 42;

/// Print `synopsis`, then the options section for `cmd`, to stdout. Best-effort
/// (a failed write must not change exit status), mirroring `presentation.printHelp`.
pub fn writeHelp(io: std.Io, synopsis: []const u8, cmd: Cmd) void {
    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    writeHelpInner(&w.interface, synopsis, cmd) catch return;
    w.interface.flush() catch {};
}

fn writeHelpInner(w: *std.Io.Writer, synopsis: []const u8, cmd: Cmd) !void {
    try w.writeAll(synopsis);
    try w.writeAll("\n\noptions:\n");
    var storage: [specs.len]*const Spec = undefined;
    const visible = visibleSpecs(cmd, &storage);
    var help_col: usize = 0;
    for (visible) |spec| help_col = @max(help_col, optionHeadLen(spec) + 2);
    help_col = @min(help_col, max_help_col);
    for (visible) |spec| {
        try writeOptionLine(w, spec, help_col);
    }
}

fn optionHeadLen(s: *const Spec) usize {
    var len: usize = 2;
    if (s.short) |short| {
        len += short.len;
        if (s.long != null) len += 2;
    }
    if (s.long) |long| len += long.len;
    if (s.metavar.len != 0) {
        len += switch (s.arg) {
            .flag => s.metavar.len + 3,
            .opt => s.metavar.len + 3,
            .req, .req2, .multi => s.metavar.len + 1,
        };
    }
    return len;
}

fn writeOptionLine(w: *std.Io.Writer, s: *const Spec, help_col: usize) !void {
    try w.writeAll("  ");
    var col: usize = 2;
    if (s.short) |sh| {
        try w.writeAll(sh);
        col += sh.len;
        if (s.long != null) {
            try w.writeAll(", ");
            col += 2;
        }
    }
    if (s.long) |l| {
        try w.writeAll(l);
        col += l.len;
    }
    if (s.metavar.len != 0) {
        switch (s.arg) {
            .flag => {
                try w.print(" [{s}]", .{s.metavar});
                col += s.metavar.len + 3;
            },
            .opt => {
                try w.print("[={s}]", .{s.metavar});
                col += s.metavar.len + 3;
            },
            .req, .req2, .multi => {
                try w.print(" {s}", .{s.metavar});
                col += s.metavar.len + 1;
            },
        }
    }

    if (s.help.len == 0) {
        try w.writeByte('\n');
        return;
    }
    // Align the help column; wrap to a fresh line if the head is too wide.
    if (col + 2 <= help_col) {
        try w.splatByteAll(' ', help_col - col);
    } else {
        try w.writeByte('\n');
        try w.splatByteAll(' ', help_col);
    }
    try writeWrappedHelp(w, s.help, help_col);
    try w.writeByte('\n');
}

fn writeWrappedHelp(w: *std.Io.Writer, help: []const u8, help_col: usize) !void {
    const line_width = @max(@as(usize, 20), help_width -| help_col);
    var logical_lines = std.mem.splitScalar(u8, help, '\n');
    var first_logical = true;
    while (logical_lines.next()) |logical_line| {
        if (!first_logical) {
            try w.writeByte('\n');
            try w.splatByteAll(' ', help_col);
        }
        first_logical = false;

        var remaining = std.mem.trimStart(u8, logical_line, " ");
        while (remaining.len > line_width) {
            var cut = std.mem.lastIndexOfScalar(u8, remaining[0 .. line_width + 1], ' ') orelse line_width;
            if (cut == 0) cut = line_width;
            try w.writeAll(remaining[0..cut]);
            remaining = std.mem.trimStart(u8, remaining[cut..], " ");
            if (remaining.len != 0) {
                try w.writeByte('\n');
                try w.splatByteAll(' ', help_col);
            }
        }
        try w.writeAll(remaining);
    }
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingValue => "missing value for option",
        error.MissingSecondValue => "expected two values (NAME and VALUE) for option",
        error.UnexpectedValue => "option does not take a value",
        error.FlakesFeatureRequired => "flake inputs require the flakes experimental feature; pass --extra-experimental-features flakes",
        error.TooManySources => "provide only one expression or file",
        error.InvalidColorMode => "expected --color to be auto, always, or never",
        error.InvalidVmTraceFormat => "expected --vm-trace-format to be text or binary",
        error.InvalidVmTraceMaxEvents => "expected --vm-trace-max-events to be a non-negative integer",
        error.UnknownExperimentalFeature => "unknown experimental feature (available: pipe-operators, fetch-tree, flakes)",
        error.InvalidWorkers => "expected --workers to be a non-negative integer",
        error.InvalidMaxJobs => "expected --max-jobs to be `auto` or a non-negative integer",
        error.InvalidCores => "expected --cores to be a non-negative integer",
        error.InvalidGcBudget => "expected --gc-budget to be a size like 4096, 512m, or 4g",
        error.InvalidHugetlbMode => "expected --hugetlb to be auto, on, or off",
        error.InvalidTimelineFlows => "expected --timeline-flows to be off or all",
        error.InvalidChunkId => "expected --chunk to be a chunk id (decimal, or 0x-prefixed hex)",
        error.UnknownOption => "unknown option",
        error.OptionNotValidForCommand => "option not valid for this command",
        else => @errorName(err),
    };
}

fn parseForTest(argv: std.process.Args.Vector, cmd: Cmd) !Options {
    var process_args: std.process.Args = .{ .vector = argv };
    var iter = try process_args.iterateAllocator(std.testing.allocator);
    defer iter.deinit();
    _ = iter.next();
    return parse(std.testing.allocator, &iter, null, cmd, null);
}

test "typed sources preserve mixed command-line order" {
    const argv = [_][*:0]const u8{ "fix", "bare.nix", "--flake", ".#hello", "-E", "1 + 2", "-f", "other.nix" };
    var options = try parseForTest(&argv, .build);
    defer options.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), options.sources.items.len);
    try std.testing.expectEqualStrings("bare.nix", options.sources.items[0].file);
    try std.testing.expectEqualStrings(".#hello", options.sources.items[1].flake);
    try std.testing.expectEqualStrings("1 + 2", options.sources.items[2].expr);
    try std.testing.expectEqualStrings("other.nix", options.sources.items[3].file);
}

test "lowercase expression short flag is rejected and flake requires a value" {
    const lowercase = [_][*:0]const u8{ "fix", "-e", "1" };
    try std.testing.expectError(error.UnknownOption, parseForTest(&lowercase, .eval));

    const missing_flake = [_][*:0]const u8{ "fix", "--flake" };
    try std.testing.expectError(error.MissingValue, parseForTest(&missing_flake, .build));
}

test "parser enforces command option scope" {
    const argv = [_][*:0]const u8{ "fix", "--dry-run" };
    try std.testing.expectError(error.OptionNotValidForCommand, parseForTest(&argv, .eval));
}

test "parse accepts and advertises the json compatibility flag" {
    const argv = [_][*:0]const u8{ "fix", "--json", "-E", "1" };
    var options = try parseForTest(&argv, .parse);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqual(OutputFormat.json, options.output);

    var buffer: [32 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeHelpInner(&writer, "usage: fix parse", .parse);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "--json") != null);
}

test "repl no-tui flag and legacy alias select inline workspaces" {
    for ([_][*:0]const u8{ "--no-tui", "--bare" }) |flag| {
        const argv = [_][*:0]const u8{ "fix", flag };
        var options = try parseForTest(&argv, .repl);
        defer options.deinit(std.testing.allocator);
        try std.testing.expect(options.no_tui);
    }
}

test "stats is shared by evaluator and disasm commands" {
    const argv = [_][*:0]const u8{ "fix", "--stats" };
    for (stats_cmds) |cmd| {
        var options = try parseForTest(&argv, cmd);
        defer options.deinit(std.testing.allocator);
        try std.testing.expect(options.stats);
    }

    try std.testing.expectError(error.OptionNotValidForCommand, parseForTest(&argv, .parse));
    const retired = [_][*:0]const u8{ "fix", "--print-sched-stats" };
    try std.testing.expectError(error.UnknownOption, parseForTest(&retired, .eval));
}

test "package list returns to ordinary option parsing" {
    const argv = [_][*:0]const u8{ "fix", "-p", "hello", "jq", "--no-progress" };
    var options = try parseForTest(&argv, .shell);
    defer options.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices([]const u8, &.{ "hello", "jq" }, options.packages.items);
    try std.testing.expectEqual(presentation.ProgressMode.disabled, options.progress);
}

test "progress surface selects enabled or disabled records" {
    const automatic_argv = [_][*:0]const u8{ "fix", "--progress" };
    var automatic = try parseForTest(&automatic_argv, .eval);
    defer automatic.deinit(std.testing.allocator);
    try std.testing.expectEqual(presentation.ProgressMode.enabled, automatic.progress);

    const old_log_argv = [_][*:0]const u8{ "fix", "--progress=log" };
    try std.testing.expectError(error.UnexpectedValue, parseForTest(&old_log_argv, .eval));
}

test "one-shot evaluator help exposes Perfetto timeline controls" {
    var buffer: [32 * 1024]u8 = undefined;
    for (timeline_cmds) |cmd| {
        var writer = std.Io.Writer.fixed(&buffer);
        try writeHelpInner(&writer, "usage: fix", cmd);
        const help = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, help, "--timeline[=PATH]") != null);
        try std.testing.expect(std.mem.indexOf(u8, help, "--timeline-flows off|all") != null);
        try std.testing.expect(std.mem.indexOf(u8, help, "Perfetto timeline") != null);
    }

    var writer = std.Io.Writer.fixed(&buffer);
    try writeHelpInner(&writer, "usage: fix run", .run);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "--timeline") == null);
}

test "help and completions alphabetize visible options with modifiers adjacent" {
    var help_buffer: [32 * 1024]u8 = undefined;
    var help_writer = std.Io.Writer.fixed(&help_buffer);
    try writeHelpInner(&help_writer, "usage: fix eval", .eval);
    const help = help_writer.buffered();

    const arg = std.mem.indexOf(u8, help, "--arg NAME") orelse unreachable;
    const argstr = std.mem.indexOf(u8, help, "--argstr NAME") orelse unreachable;
    const attr = std.mem.indexOf(u8, help, "--attr ATTR") orelse unreachable;
    const color = std.mem.indexOf(u8, help, "--color[=WHEN]") orelse unreachable;
    const no_color = std.mem.indexOf(u8, help, "--no-color") orelse unreachable;
    const cores = std.mem.indexOf(u8, help, "--cores N") orelse unreachable;
    const deprecated = std.mem.indexOf(u8, help, "--deprecated-features FEATS") orelse unreachable;
    const extra_deprecated = std.mem.indexOf(u8, help, "--extra-deprecated-features FEATS") orelse unreachable;
    const experimental = std.mem.indexOf(u8, help, "--experimental-features FEATS") orelse unreachable;
    const extra_experimental = std.mem.indexOf(u8, help, "--extra-experimental-features FEATS") orelse unreachable;
    const expr = std.mem.indexOf(u8, help, "--expr EXPR") orelse unreachable;
    const progress = std.mem.indexOf(u8, help, "--progress") orelse unreachable;
    const no_progress = std.mem.indexOf(u8, help, "--no-progress") orelse unreachable;
    const raw = std.mem.indexOf(u8, help, "--raw") orelse unreachable;
    try std.testing.expect(arg < argstr and argstr < attr);
    try std.testing.expect(color < no_color and no_color < cores);
    try std.testing.expect(deprecated < extra_deprecated and extra_deprecated < experimental);
    try std.testing.expect(experimental < extra_experimental and extra_experimental < expr);
    try std.testing.expect(progress < no_progress and no_progress < raw);

    var completion_buffer: [32 * 1024]u8 = undefined;
    var completion_writer = std.Io.Writer.fixed(&completion_buffer);
    try writeOptionCompletions(&completion_writer, .eval, "--");
    const completions = completion_writer.buffered();
    const completion_color = std.mem.indexOf(u8, completions, "--color\t") orelse unreachable;
    const completion_no_color = std.mem.indexOf(u8, completions, "--no-color\t") orelse unreachable;
    const completion_cores = std.mem.indexOf(u8, completions, "--cores\t") orelse unreachable;
    const completion_deprecated = std.mem.indexOf(u8, completions, "--deprecated-features\t") orelse unreachable;
    const completion_extra_deprecated = std.mem.indexOf(u8, completions, "--extra-deprecated-features\t") orelse unreachable;
    const completion_experimental = std.mem.indexOf(u8, completions, "--experimental-features\t") orelse unreachable;
    const completion_extra_experimental = std.mem.indexOf(u8, completions, "--extra-experimental-features\t") orelse unreachable;
    const completion_expr = std.mem.indexOf(u8, completions, "--expr\t") orelse unreachable;
    const completion_progress = std.mem.indexOf(u8, completions, "--progress\t") orelse unreachable;
    const completion_no_progress = std.mem.indexOf(u8, completions, "--no-progress\t") orelse unreachable;
    const completion_raw = std.mem.indexOf(u8, completions, "--raw\t") orelse unreachable;
    try std.testing.expect(completion_color < completion_no_color and completion_no_color < completion_cores);
    try std.testing.expect(completion_deprecated < completion_extra_deprecated and completion_extra_deprecated < completion_experimental);
    try std.testing.expect(completion_experimental < completion_extra_experimental and completion_extra_experimental < completion_expr);
    try std.testing.expect(completion_progress < completion_no_progress and completion_no_progress < completion_raw);
}

test "option completions expose argument shapes defaults and concise help" {
    var buffer: [32 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeOptionCompletions(&writer, .eval, "--");
    const completions = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, completions, "--arg\t--arg NAME EXPR\tpass EXPR") != null);
    try std.testing.expect(std.mem.indexOf(u8, completions, "--color\t--color[=WHEN] [default: auto]\tcolor diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, completions, "--expr\t--expr EXPR [repeatable]\tevaluate expression text") != null);
    try std.testing.expect(std.mem.indexOf(u8, completions, "--gc-budget\t--gc-budget SIZE [default: auto]\tset the GC collection budget") != null);
    try std.testing.expect(std.mem.indexOf(u8, completions, "--timeline\t--timeline[=PATH] [default: fix-timeline.json]\twrite a Perfetto timeline") != null);
}

test "help aligns long option names and wraps descriptions to its width" {
    var buffer: [32 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeHelpInner(&writer, "usage: fix eval", .eval);
    const help = writer.buffered();

    const long_name = std.mem.indexOf(u8, help, "--extra-experimental-features FEATS") orelse unreachable;
    const long_line_end = std.mem.indexOfScalarPos(u8, help, long_name, '\n') orelse help.len;
    try std.testing.expect(std.mem.indexOf(u8, help[long_name..long_line_end], "like --experimental-features") != null);

    const flows = std.mem.indexOf(u8, help, "--timeline-flows off|all") orelse unreachable;
    const flows_line_end = std.mem.indexOfScalarPos(u8, help, flows, '\n') orelse help.len;
    try std.testing.expect(std.mem.indexOf(u8, help[flows..flows_line_end], "record all scheduler") != null);

    var lines = std.mem.splitScalar(u8, help, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "  "))
            try std.testing.expect(line.len <= help_width);
    }
}

test "timeline flows are either complete or disabled" {
    const off_argv = [_][*:0]const u8{ "fix", "--timeline-flows", "off" };
    var off = try parseForTest(&off_argv, .build);
    defer off.deinit(std.testing.allocator);
    try std.testing.expect(!off.timeline_flows);

    const all_argv = [_][*:0]const u8{ "fix", "--timeline-flows", "all" };
    var all = try parseForTest(&all_argv, .instantiate);
    defer all.deinit(std.testing.allocator);
    try std.testing.expect(all.timeline_flows);

    const sampled_argv = [_][*:0]const u8{ "fix", "--timeline-flows", "10" };
    try std.testing.expectError(error.InvalidTimelineFlows, parseForTest(&sampled_argv, .eval));
}

test "verbosity accepts clustered short flags" {
    const argv = [_][*:0]const u8{ "fix", "-vv" };
    var options = try parseForTest(&argv, .eval);
    defer options.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), options.verbose);
}

test "GC budget replaces max-memory and derivation debug flags are gone" {
    const budget_argv = [_][*:0]const u8{ "fix", "--gc-budget", "512m" };
    var budget = try parseForTest(&budget_argv, .eval);
    defer budget.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u64, 512 << 20), budget.gc_budget);

    const old_memory = [_][*:0]const u8{ "fix", "--max-memory", "512m" };
    try std.testing.expectError(error.UnknownOption, parseForTest(&old_memory, .eval));

    const old_debug = [_][*:0]const u8{ "fix", "--debug-derivations" };
    try std.testing.expectError(error.UnknownOption, parseForTest(&old_debug, .eval));
}

test "find-file keeps ordered lookup names and is instantiate-only" {
    const argv = [_][*:0]const u8{ "fix", "--find-file", "nixpkgs/default.nix", "-E", "second/name", "-f", "third/name" };
    var options = try parseForTest(&argv, .instantiate);
    defer options.deinit(std.testing.allocator);

    try std.testing.expect(options.find_file);
    try std.testing.expectEqual(@as(usize, 3), options.sources.items.len);
    try std.testing.expectEqualStrings("nixpkgs/default.nix", options.sources.items[0].file);
    try std.testing.expectEqualStrings("second/name", options.sources.items[1].expr);
    try std.testing.expectEqualStrings("third/name", options.sources.items[2].file);

    const wrong_command = [_][*:0]const u8{ "fix", "--find-file", "nixpkgs" };
    try std.testing.expectError(error.OptionNotValidForCommand, parseForTest(&wrong_command, .eval));
}

test "legacy daemon settings are accepted by nix-instantiate modes" {
    const argv = [_][*:0]const u8{ "fix", "-jauto", "--cores", "3", "-k", "-K", "--fallback", "-Q" };
    for ([_]Cmd{ .eval, .parse, .instantiate }) |cmd| {
        var options = try parseForTest(&argv, cmd);
        defer options.deinit(std.testing.allocator);
        try std.testing.expect(options.no_build_output);
        try std.testing.expectEqual(@as(usize, 5), options.option_overrides.items.len);
        const expected = [_]OptionOverride{
            .{ .name = "max-jobs", .value = "auto" },
            .{ .name = "cores", .value = "3" },
            .{ .name = "keep-going", .value = "true" },
            .{ .name = "keep-failed", .value = "true" },
            .{ .name = "fallback", .value = "true" },
        };
        for (expected, options.option_overrides.items) |want, got| {
            try std.testing.expectEqualStrings(want.name, got.name);
            try std.testing.expectEqualStrings(want.value, got.value);
        }
    }

    try std.testing.expectError(error.OptionNotValidForCommand, parseForTest(&argv, .disasm));

    const bad_jobs = [_][*:0]const u8{ "fix", "--max-jobs", "many" };
    try std.testing.expectError(error.InvalidMaxJobs, parseForTest(&bad_jobs, .build));
    const bad_cores = [_][*:0]const u8{ "fix", "--cores", "all" };
    try std.testing.expectError(error.InvalidCores, parseForTest(&bad_cores, .build));
}

test "read-write mode is an eval-only store-write switch" {
    const argv = [_][*:0]const u8{ "fix", "--read-write-mode", "-E", "1" };
    var options = try parseForTest(&argv, .eval);
    defer options.deinit(std.testing.allocator);
    try std.testing.expect(options.read_write_mode);

    try std.testing.expectError(error.OptionNotValidForCommand, parseForTest(&argv, .instantiate));
    try std.testing.expectError(error.OptionNotValidForCommand, parseForTest(&argv, .parse));
}
