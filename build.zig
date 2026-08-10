const std = @import("std");

/// Single source of truth for the release version (`fix --version`).
const manifest = @import("build.zig.zon");

const UnitTest = struct {
    name: []const u8,
    root_module: *std.Build.Module,
    runner: std.Build.Step.Compile.TestRunner,
    timeout: []const u8 = "10m",
    filters: []const []const u8 = &.{},
};

fn addUnitTest(b: *std.Build, options: UnitTest) *std.Build.Step.Run {
    const compile = b.addTest(.{
        .name = options.name,
        .root_module = options.root_module,
        .test_runner = options.runner,
        .filters = options.filters,
        .use_llvm = true,
    });
    compile.setExecCmd(&.{ "timeout", "--kill-after=5s", options.timeout, null });
    return b.addRunArtifact(compile);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(bool, "profile", "Keep symbols and frame pointers for profiling") orelse false;
    const tsan = b.option(bool, "tsan", "Instrument the focused concurrency graph with ThreadSanitizer") orelse false;
    const debug_checks_opt = b.option(bool, "debug-checks", "Enable VM dispatch invariant assertions (defaults to Debug builds)");
    const vm_trace = b.option(bool, "vm-trace", "Enable VM execution tracing (--vm-trace)") orelse false;
    const thunks_log = b.option(bool, "thunks-log", "Enable per-thunk lifecycle event log (--thunks-log)") orelse false;
    const prof_main = b.option(bool, "prof-main", "Time main thread's hot serial paths with the CPU tick counter; print via --stats") orelse false;
    const prof_path = b.option(bool, "prof-path", "Record the force-call tree (workers=1) and report the critical path + source-attributed profile; print via --stats") orelse false;
    if (tsan and (target.result.cpu.arch != .x86_64 or target.result.os.tag != .linux))
        @panic("-Dtsan currently supports only x86_64-linux");
    const strip: ?bool = if (profile or tsan) false else null;
    const omit_frame_pointer: ?bool = if (profile or tsan) false else null;
    const debug_checks = debug_checks_opt orelse (optimize == .Debug);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);
    build_options.addOption(bool, "debug_checks", debug_checks);
    build_options.addOption(bool, "vm_trace", vm_trace);
    build_options.addOption(bool, "thunks_log", thunks_log);
    build_options.addOption(bool, "prof_main", prof_main);
    build_options.addOption(bool, "prof_path", prof_path);
    // One shared module instance for every evaluator file that uses build flags.
    const build_options_mod = build_options.createModule();

    const base_options = b.addOptions();
    base_options.addOption(bool, "fiber_census", prof_main);
    base_options.addOption(bool, "tsan_enabled", tsan);
    base_options.addOption(
        bool,
        "test_emulated",
        target.result.cpu.arch != b.graph.host.result.cpu.arch or
            target.result.os.tag != b.graph.host.result.os.tag,
    );
    const base_options_mod = base_options.createModule();

    // Keep build modules for durable domain boundaries. Internal subsystems use
    // ordinary file imports beneath these roots so each type has one canonical
    // instance without restating every file edge in the build graph.
    const syntax_mod = b.addModule("syntax", .{
        .root_source_file = b.path("src/syntax/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .sanitize_thread = tsan,
    });

    // The LALR parser tables are expensive to construct at comptime, so a
    // standalone codegen tool builds them once (cached by the build system;
    // only rebuilt when the grammar or generator changes) and emits a plain
    // `.zig` of literal arrays. The `syntax` module imports it as
    // `@import("parser_tables")`, keeping the cost off every ordinary rebuild.
    const gen_tables_exe = b.addExecutable(.{
        .name = "gen-parser-tables",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/syntax/gen_parser_tables.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
        .use_llvm = true,
    });
    const run_gen_tables = b.addRunArtifact(gen_tables_exe);
    const parser_tables_path = run_gen_tables.addOutputFileArg("parser_tables.zig");
    syntax_mod.addAnonymousImport("parser_tables", .{ .root_source_file = parser_tables_path });
    const gen_tables_step = b.step("gen-parser-tables", "Regenerate the LALR parser tables");
    gen_tables_step.dependOn(&run_gen_tables.step);

    // Generic, reusable infrastructure with zero Nix coupling.
    const base_mod = b.addModule("base", .{
        .root_source_file = b.path("src/base/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .sanitize_thread = tsan,
    });
    base_mod.addImport("base_options", base_options_mod);

    // Hardware twin of the std SHA-256 (see src/base/sha256.zig): the same
    // std hasher compiled with `+sha,+avx2` so its comptime-gated SHA-NI path
    // opens, linked into everything through `base` and selected at runtime by
    // cpuid. Skipped where `base.sha256` never references the extern symbols.
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag != .windows) {
        var hw_query = target.query;
        hw_query.cpu_features_add.addFeature(@intFromEnum(std.Target.x86.Feature.sha));
        hw_query.cpu_features_add.addFeature(@intFromEnum(std.Target.x86.Feature.avx2));
        const sha256_hw_obj = b.addObject(.{
            .name = "sha256_hw",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/base/sha256_hw.zig"),
                .target = b.resolveTargetQuery(hw_query),
                .optimize = optimize,
                .strip = strip,
                .omit_frame_pointer = omit_frame_pointer,
                .sanitize_thread = tsan,
            }),
            .use_llvm = true,
        });
        base_mod.addObject(sha256_hw_obj);
    }

    syntax_mod.addImport("base", base_mod);

    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = b.path("src/runtime/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .sanitize_thread = tsan,
    });
    runtime_mod.addImport("build_options", build_options_mod);
    runtime_mod.addImport("base", base_mod);

    const store_mod = b.addModule("store", .{
        .root_source_file = b.path("src/store/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .sanitize_thread = tsan,
    });
    store_mod.addImport("runtime", runtime_mod);
    store_mod.addImport("base", base_mod);

    const fetchers_mod = b.addModule("fetchers", .{
        .root_source_file = b.path("src/fetchers/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .sanitize_thread = tsan,
    });
    fetchers_mod.addImport("runtime", runtime_mod);
    fetchers_mod.addImport("base", base_mod);
    fetchers_mod.addImport("store", store_mod);
    fetchers_mod.linkSystemLibrary("libcurl", .{ .use_pkg_config = .force });
    fetchers_mod.linkSystemLibrary("libgit2", .{ .use_pkg_config = .force });
    fetchers_mod.link_libc = true;

    const expr_mod = b.addModule("expr", .{
        .root_source_file = b.path("src/expr/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .sanitize_thread = tsan,
    });
    expr_mod.addImport("build_options", build_options_mod);
    expr_mod.addImport("syntax", syntax_mod);
    expr_mod.addImport("runtime", runtime_mod);
    expr_mod.addImport("base", base_mod);
    expr_mod.addImport("store", store_mod);
    expr_mod.addImport("fetchers", fetchers_mod);

    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("src/cli/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .sanitize_thread = tsan,
    });
    cli_mod.addImport("base", base_mod);
    cli_mod.addImport("expr", expr_mod);
    cli_mod.addImport("runtime", runtime_mod);
    cli_mod.addImport("syntax", syntax_mod);
    cli_mod.addImport("store", store_mod);
    cli_mod.addImport("build_options", build_options_mod);

    const process_support_mod = b.createModule(.{
        .root_source_file = b.path("src/process_support.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "base", .module = base_mod },
            .{ .name = "runtime", .module = runtime_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .omit_frame_pointer = omit_frame_pointer,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "cli", .module = cli_mod },
            .{ .name = "process_support", .module = process_support_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "fix",
        .root_module = exe_mod,
        // The threaded VM dispatcher in src/expr/vm/run.zig relies on
        // `@call(.always_tail)`, which only the LLVM backend
        // implements. Force LLVM for every build mode so debug
        // builds don't unbounded-recurse through the dispatch
        // chain.
        .use_llvm = true,
    });
    // Content-derived GNU build-id: the persistent chunk cache keys its
    // on-disk layout by the running binary's identity, so a rebuilt compiler
    // auto-invalidates cached bytecode (and identical/reproducible rebuilds
    // keep it valid). Link-step only — no recompilation cost.
    exe.build_id = .sha1;
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Run tests as ordinary terminal processes. The repository-owned runner
    // reports the active test and lets the OS terminate a crashing process
    // without asking Zig's unwinder to walk a switched fiber stack.
    const simple_test_runner: std.Build.Step.Compile.TestRunner = .{
        .path = b.path("tools/test_runner.zig"),
        .mode = .simple,
    };

    const run_base_tests = addUnitTest(b, .{
        .name = "base-tests",
        .root_module = base_mod,
        .runner = simple_test_runner,
    });

    const run_runtime_tests = addUnitTest(b, .{
        .name = "runtime-tests",
        .root_module = runtime_mod,
        .runner = simple_test_runner,
    });

    const run_syntax_tests = addUnitTest(b, .{
        .name = "syntax-tests",
        .root_module = syntax_mod,
        .runner = simple_test_runner,
    });

    const run_expr_tests = addUnitTest(b, .{
        .name = "expr-tests",
        .root_module = expr_mod,
        .runner = simple_test_runner,
    });

    // Focused concurrency protocol suite. The tests live beside the modules
    // whose invariants they exercise; filters keep this lane small enough for
    // sanitizer and repeated stress runs without creating a second module
    // graph or production-only test hooks.
    const run_concurrency_runtime_tests = addUnitTest(b, .{
        .name = "concurrency-runtime-tests",
        .root_module = runtime_mod,
        .runner = simple_test_runner,
        .filters = &.{"concurrency:"},
        .timeout = "2m",
    });

    const run_concurrency_expr_tests = addUnitTest(b, .{
        .name = "concurrency-expr-tests",
        .root_module = expr_mod,
        .runner = simple_test_runner,
        .filters = &.{"concurrency:"},
        .timeout = "2m",
    });

    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/integration/expr_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "expr", .module = expr_mod },
            .{ .name = "runtime", .module = runtime_mod },
        },
    });
    const run_integration_tests = addUnitTest(b, .{
        .name = "integration-tests",
        .root_module = integration_test_mod,
        .runner = simple_test_runner,
    });

    const run_fetchers_tests = addUnitTest(b, .{
        .name = "fetchers-tests",
        .root_module = fetchers_mod,
        .runner = simple_test_runner,
    });

    const run_store_tests = addUnitTest(b, .{
        .name = "store-tests",
        .root_module = store_mod,
        .runner = simple_test_runner,
    });

    const run_cli_tests = addUnitTest(b, .{
        .name = "cli-tests",
        .root_module = cli_mod,
        .runner = simple_test_runner,
    });

    const test_base_step = b.step("test-base", "Run base unit tests");
    test_base_step.dependOn(&run_base_tests.step);
    const test_runtime_step = b.step("test-runtime", "Run runtime unit tests");
    test_runtime_step.dependOn(&run_runtime_tests.step);
    const test_store_step = b.step("test-store", "Run store unit tests");
    test_store_step.dependOn(&run_store_tests.step);
    const test_fetchers_step = b.step("test-fetchers", "Run fetcher unit tests");
    test_fetchers_step.dependOn(&run_fetchers_tests.step);
    const test_expr_step = b.step("test-expr", "Run evaluator unit tests");
    test_expr_step.dependOn(&run_expr_tests.step);
    const test_concurrency_step = b.step("test-concurrency", "Run focused concurrency protocol tests");
    test_concurrency_step.dependOn(&run_concurrency_runtime_tests.step);
    test_concurrency_step.dependOn(&run_concurrency_expr_tests.step);

    const stress_mod = b.createModule(.{
        .root_source_file = b.path("test/concurrency_stress.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
    });
    stress_mod.addImport("base", base_mod);
    stress_mod.addImport("expr", expr_mod);
    const stress_exe = b.addExecutable(.{
        .name = "concurrency-stress",
        .root_module = stress_mod,
        .use_llvm = true,
    });
    const run_stress = b.addSystemCommand(&.{ "timeout", "--kill-after=5s", "10m" });
    run_stress.addArtifactArg(stress_exe);
    run_stress.has_side_effects = true;
    if (b.args) |args| run_stress.addArgs(args);
    const stress_step = b.step("stress-concurrency", "Run seeded concurrency stress and semantic differentials");
    stress_step.dependOn(&run_stress.step);

    const test_integration_step = b.step("test-integration", "Run integration tests");
    test_integration_step.dependOn(&run_integration_tests.step);
    const test_cli_step = b.step("test-cli", "Run CLI unit tests");
    test_cli_step.dependOn(&run_cli_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_base_tests.step);
    test_step.dependOn(&run_syntax_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_store_tests.step);
    test_step.dependOn(&run_fetchers_tests.step);
    test_step.dependOn(&run_expr_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_cli_tests.step);

    const format_check = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "tools" },
        .check = true,
    });

    const run_structure_check = b.addSystemCommand(&.{"bash"});
    run_structure_check.addFileArg(b.path("tools/structure_check.sh"));
    run_structure_check.addArg(b.pathFromRoot("."));
    const structure_check_step = b.step("structure-check", "Check durable module and ownership boundaries");
    structure_check_step.dependOn(&run_structure_check.step);

    const run_model_check = b.addSystemCommand(&.{"bash"});
    run_model_check.addFileArg(b.path("tools/check_models.sh"));
    run_model_check.addArg(b.pathFromRoot("."));
    const model_check_step = b.step("check-models", "Model-check concurrency protocols with TLC");
    model_check_step.dependOn(&run_model_check.step);

    const static_check_step = b.step("check-static", "Check formatting and module boundaries");
    static_check_step.dependOn(&format_check.step);
    static_check_step.dependOn(structure_check_step);

    const check_step = b.step("check", "Check formatting and run unit tests");
    check_step.dependOn(static_check_step);
    check_step.dependOn(model_check_step);
    check_step.dependOn(test_step);

    // Quick syntax-only tests. The parser imports the build-generated
    // `parser_tables`, so `zig test src/syntax/parser.zig` can't resolve it on
    // its own — use this instead for fast iteration on the lexer/parser/AST.
    const test_syntax_step = b.step("test-syntax", "Run only the syntax (lexer/parser/AST) tests");
    test_syntax_step.dependOn(&run_syntax_tests.step);

    // Parse microbenchmark: `zig build bench-parse -- <file.nix> ...`. Named to
    // avoid colliding with the differential *eval* benchmark (bench/harness.nix,
    // driven by ./bench/run) — this one times the front-end parser alone.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/parse_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("syntax", syntax_mod);
    const bench_exe = b.addExecutable(.{ .name = "parse-bench", .root_module = bench_mod, .use_llvm = true });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench-parse", "Parse microbenchmark (front-end only; eval benchmark lives in bench/harness.nix)");
    bench_step.dependOn(&run_bench.step);

    // Language conformance: run the pinned Lix + snix language test corpora
    // (see test/lang/) against the freshly built `fix`. This is a differential
    // suite, not a unit test — the hand-rolled Zig runner (test/lang/*.zig)
    // needs only Nix (to resolve the npins pins), drives `fix` per case, and
    // exits non-zero while any case diverges. Pass runner flags through, e.g.
    // `zig build test-lang -- --suite lix`. libc is linked for the POSIX
    // special-file creation (mkfifo/mknod) the snix fixtures need.
    const lang_step = b.step("test-lang", "Run the Lix + snix language conformance suites against fix");
    const lang_exe = b.addExecutable(.{
        .name = "lang-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/lang/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    const run_lang = b.addRunArtifact(lang_exe);
    run_lang.step.dependOn(b.getInstallStep());
    run_lang.has_side_effects = true;
    run_lang.addArg("--repo");
    run_lang.addArg(b.pathFromRoot("."));
    run_lang.addArg("--fix");
    run_lang.addArg(b.pathFromRoot("zig-out/bin/fix"));
    if (b.args) |args| run_lang.addArgs(args);
    lang_step.dependOn(&run_lang.step);

    // Bench-fixture differential correctness: evaluate every bench/workloads
    // fixture under fix and a reference Nix and compare (NOT a timing run — it
    // reuses the fixtures to confirm agreement). Needs Nix + the pinned nixpkgs.
    // e.g. `zig build test-bench-fixtures -- torture`.
    const bench_check_step = b.step("test-bench-fixtures", "Differentially check bench fixtures: fix vs reference Nix");
    const bench_check_exe = b.addExecutable(.{
        .name = "bench-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bench_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    const run_bench_check = b.addRunArtifact(bench_check_exe);
    run_bench_check.step.dependOn(b.getInstallStep());
    run_bench_check.has_side_effects = true;
    run_bench_check.addArg("--repo");
    run_bench_check.addArg(b.pathFromRoot("."));
    run_bench_check.addArg("--fix");
    run_bench_check.addArg(b.pathFromRoot("zig-out/bin/fix"));
    // TSan's 10-20x eval multiplier makes the plain 600s per-eval budget read
    // large realworld fixtures as hung. Raised default first, so an explicit
    // `-- --eval-timeout-secs N` still wins (last occurrence is parsed).
    if (tsan) run_bench_check.addArgs(&.{ "--eval-timeout-secs", "3600" });
    if (b.args) |args| run_bench_check.addArgs(args);
    bench_check_step.dependOn(&run_bench_check.step);

    // End-to-end CLI suites (test/e2e/): drive the freshly built `fix` through
    // behavioral checks (repl pipe+PTY contract, `fix flake` subcommands, ...).
    // Adding coverage is dropping a `test/e2e/<name>.sh` fragment. Pipe-mode
    // checks run everywhere; PTY checks self-skip without a util-linux script(1)
    // (e.g. macOS). Part of `zig build test`, and runnable alone, e.g.
    // `zig build test-e2e -- flake`.
    const e2e_step = b.step("test-e2e", "Run the end-to-end CLI suites (test/e2e/) against fix");
    const run_e2e = b.addSystemCommand(&.{"bash"});
    run_e2e.addFileArg(b.path("test/e2e/run.sh"));
    run_e2e.step.dependOn(b.getInstallStep());
    run_e2e.has_side_effects = true;
    if (b.args) |args| run_e2e.addArgs(args);
    e2e_step.dependOn(&run_e2e.step);
    test_step.dependOn(&run_e2e.step);

    // Whole-nixpkgs differential (test/nixpkgs/): evaluate the entire nixpkgs
    // CI job universe (~80k attrs) under fix and a reference Nix and compare
    // per-attr drvPaths. Monolithic by default (peaks ~51 GB; the oracle is
    // cached per pin under ~/.cache/fix-nixpkgs-eval, first run pays ~2.5 min
    // to generate it). Sharded for memory-constrained machines:
    // `zig build test-nixpkgs -- --chunk 3/12 --gc-budget 1024`.
    // NOT part of `zig build test` — run it directly.
    const nixpkgs_step = b.step("test-nixpkgs", "Differentially eval the whole nixpkgs universe: fix vs reference Nix");
    const run_nixpkgs = b.addSystemCommand(&.{"bash"});
    run_nixpkgs.addFileArg(b.path("test/nixpkgs/run.sh"));
    run_nixpkgs.step.dependOn(b.getInstallStep());
    run_nixpkgs.has_side_effects = true;
    if (b.args) |args| run_nixpkgs.addArgs(args);
    nixpkgs_step.dependOn(&run_nixpkgs.step);
}
