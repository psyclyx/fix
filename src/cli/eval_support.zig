//! Driving a single evaluation: run the source, write the result, render
//! failures, and load source text.

const std = @import("std");
const render = @import("render.zig");
const args = @import("args.zig");
const fileish = @import("fileish.zig");
const engine = @import("expr");
const runtime = @import("runtime");
const store = @import("store");
const Engine = engine.Engine;
const Value = runtime.Value;
const EvaluationMode = args.EvaluationMode;
const SourceArg = args.SourceArg;
const TextRef = @import("base").TextRef;

/// The build realization mode selected by `--check`/`--repair` (`--check`
/// takes precedence). `--repair`/`--check` require a trusted daemon user.
pub fn buildMode(options: *const args.Options) store.daemon.BuildMode {
    if (options.check) return .check;
    if (options.repair) return .repair;
    return .normal;
}

/// Evaluate `source` and write the result, or render the failure. Returns
/// whether evaluation succeeded.
pub fn evaluateAndWrite(
    io: std.Io,
    mode: EvaluationMode,
    use_color: bool,
    show_trace: bool,
    ev: *Engine,
    source: Source,
    label: []const u8,
) !bool {
    // Values render in the same palette as diagnostics when writing to a tty.
    ev.setValueColor(use_color);
    _ = label;

    const result = ev.evaluatePathAt(source.slice(), source.base_path, source.abs_path) catch |err| {
        try render.evalFailure(io, use_color, show_trace, ev, source.slice(), err);
        return false;
    };
    writeResult(io, mode, ev, result) catch |err| {
        try render.evaluationError(io, use_color, show_trace, ev, source.slice(), err);
        return false;
    };
    // Strict/result rendering can force deferred bodies and imports, which may
    // add warnings after the top-level parse. Emit only once all evaluation
    // work for this input is complete.
    try render.evalDiagnostics(io, use_color, ev, source.slice());
    return true;
}

fn writeResult(io: std.Io, mode: EvaluationMode, ev: *Engine, result: Value) !void {
    if (mode.strict) try ev.forceDeep(result);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    switch (mode.output) {
        .nix => try ev.writeValue(&stdout.interface, result),
        .raw => try ev.writeRawValue(&stdout.interface, result),
        .json => try ev.writeJsonValue(&stdout.interface, result),
        .xml => try ev.writeXmlValue(&stdout.interface, result),
    }
    if (mode.output != .xml and mode.output != .raw) try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

pub const Source = fileish.Source;

pub fn sourceRequiresFlakes(source: SourceArg) bool {
    return switch (source) {
        .flake => true,
        .file => |path| fileish.requiresFlakes(path),
        .expr => false,
    };
}

/// One ordered CLI input after expanding sources × `-A` selectors. The options
/// The source projection is a non-owning value, so selecting one attribute
/// cannot accidentally create a second apparent owner of every CLI list.
pub const SelectedInput = struct {
    source_arg: SourceArg,
    options: args.SourceOptions,
};

pub const LoadedInput = struct {
    source_arg: SourceArg,
    source: Source,

    pub fn deinit(self: *LoadedInput, ev: *Engine) void {
        self.source.deinit(ev.hostAllocator());
    }

    pub fn label(self: LoadedInput) []const u8 {
        return sourceLabel(self.source_arg);
    }
};

/// Shared ordered expansion used by build, eval, and instantiate. Inputs are
/// source-major, with repeated `-A` selectors kept in their command-line order.
pub const InputPlan = struct {
    parsed: *const args.Options,
    io: std.Io,
    default_source: SourceArg,
    selector_count: usize,

    pub fn init(options: *const args.Options, io: std.Io) InputPlan {
        return .{
            .parsed = options,
            .io = io,
            .default_source = options.defaultSource(),
            .selector_count = if (options.attrs.items.len == 0) 1 else options.attrs.items.len,
        };
    }

    pub fn count(self: InputPlan) !usize {
        const source_count: usize = if (self.parsed.sources.items.len == 0) 1 else self.parsed.sources.items.len;
        return std.math.mul(usize, source_count, self.selector_count);
    }

    pub fn selected(self: InputPlan, index: usize) SelectedInput {
        const source_index = index / self.selector_count;
        const selector_index = index % self.selector_count;
        const source_arg = if (self.parsed.sources.items.len == 0)
            self.default_source
        else
            self.parsed.sources.items[source_index];
        const attr = if (self.parsed.attrs.items.len == 0) null else self.parsed.attrs.items[selector_index];
        return .{
            .source_arg = source_arg,
            .options = self.parsed.sourceOptionsWithAttr(attr),
        };
    }

    pub fn validate(self: InputPlan, ev: *Engine) !void {
        if (ev.languagePolicy().flakes_enabled) return;
        const input_count = try self.count();
        for (0..input_count) |index| {
            if (sourceRequiresFlakes(self.selected(index).source_arg)) return error.FlakesFeatureRequired;
        }
    }

    pub fn load(self: InputPlan, ev: *Engine, index: usize) !LoadedInput {
        const input = self.selected(index);
        return .{
            .source_arg = input.source_arg,
            .source = try getSource(ev, self.io, input.source_arg, input.options),
        };
    }
};

pub fn reportInputReadError(io: std.Io, use_color: bool, input_count: usize, index: usize, err: anyerror) void {
    if (input_count == 1)
        render.caughtError(io, use_color, err, "reading source", .{})
    else
        render.caughtError(io, use_color, err, "reading input {d}", .{index + 1});
}

test "input plan shares ordered source and selector expansion" {
    var options: args.Options = .{};
    defer options.deinit(std.testing.allocator);
    try options.sources.append(std.testing.allocator, .{ .expr = "one" });
    try options.sources.append(std.testing.allocator, .{ .expr = "two" });
    try options.attrs.append(std.testing.allocator, "first");
    try options.attrs.append(std.testing.allocator, "second");

    const plan = InputPlan.init(&options, std.testing.io);
    try std.testing.expectEqual(@as(usize, 4), try plan.count());
    const expected_sources = [_][]const u8{ "one", "one", "two", "two" };
    const expected_attrs = [_][]const u8{ "first", "second", "first", "second" };
    for (expected_sources, expected_attrs, 0..) |expected_source, expected_attr, index| {
        const input = plan.selected(index);
        try std.testing.expectEqualStrings(expected_source, input.source_arg.expr);
        try std.testing.expectEqualStrings(expected_attr, input.options.attr.?);
    }
}

/// The real file path behind a source, when the text is the file's own
/// content (not `--flake`/`-A`/`--arg`-synthesized wrapping) — so evaluation
/// attributes spans and attr positions to the file, like Nix does. This is the
/// absolute path (Nix reports absolute paths); null for wrapped/synthetic text.
pub fn sourcePathOf(source: SourceArg, loaded: Source) ?[]const u8 {
    _ = source;
    return loaded.abs_path;
}

/// The source identity used for an evaluation progress session.
pub fn sourceLabel(source: SourceArg) []const u8 {
    return switch (source) {
        .file => |p| p,
        .expr => "expression",
        .flake => |inst| inst,
    };
}

/// Render a store-op failure (daemon down / daemon error) specially, else fall
/// back to the normal eval-failure trace. Returns exit code 1. Shared by the
/// store-writing subcommands (`instantiate`, `build`).
pub fn storeOrEvalFailure(io: std.Io, use_color: bool, show_trace: bool, ev: *Engine, source: []const u8, err: anyerror) !u8 {
    switch (err) {
        error.DaemonError => render.messageError(io, use_color, "daemon: {s}", .{ev.lastStoreError() orelse "unknown"}),
        error.StoreUnavailable => render.caughtError(io, use_color, err, "", .{}),
        else => try render.evalFailure(io, use_color, show_trace, ev, source, err),
    }
    return 1;
}

/// `storeOrEvalFailure` for after `Engine.finishEvaluation`: the language
/// heap (diagnostics, trace, intern table) is gone, so a build failure can
/// only render store-side state. Evaluation already succeeded by the time a
/// build runs — there are no eval diagnostics to lose — and the daemon's own
/// message (still owned by the surviving RealizationStore) is the useful part.
pub fn buildFailure(io: std.Io, use_color: bool, last_store_error: ?[]const u8, err: anyerror) u8 {
    switch (err) {
        error.DaemonError => render.messageError(io, use_color, "daemon: {s}", .{last_store_error orelse "unknown"}),
        error.StoreUnavailable => render.caughtError(io, use_color, err, "", .{}),
        else => render.caughtError(io, use_color, err, "build failed", .{}),
    }
    return 1;
}

pub fn getSource(ev: *Engine, io: std.Io, source: SourceArg, options: args.SourceOptions) !Source {
    return getSourceMode(ev, io, source, options, false);
}

/// Load a source for attribute discovery. Unlike ordinary evaluation without
/// selectors, completion auto-calls a top-level attrset function with `{}` so
/// files such as `default.nix` expose outputs whose formals all have defaults.
pub fn getCompletionSource(ev: *Engine, io: std.Io, source: SourceArg, options: args.SourceOptions) !Source {
    return getSourceMode(ev, io, source, options, true);
}

fn getSourceMode(ev: *Engine, io: std.Io, source: SourceArg, options: args.SourceOptions, completion_auto_call: bool) !Source {
    const allocator = ev.hostAllocator();
    // Load the base source text (borrowed for expr/file, owned for flake).
    var base: Source = switch (source) {
        // `-E` text has no file of its own, so its relative path literals
        // resolve against the working directory, as in Nix. `evaluatePathAt`
        // takes the base explicitly and treats null as "no base", so leaving
        // it unset would leave `./foo.txt` unresolved rather than fall back.
        .expr => |text| .{ .text = .{ .borrowed = text }, .base_path = try fileish.dupBasePath(ev) },
        .file => |path| try fileish.load(ev, io, path),
        .flake => |installable| .{ .text = .{ .owned = try lowerFlakeInstallable(ev, installable, options) } },
    };

    // If selector wrapping fails, `base` (owned flake text and/or file
    // `abs_path`) would otherwise leak. This only fires on the error path; the
    // success paths below hand `base` off or free it explicitly.
    errdefer base.deinit(allocator);

    // Apply `-A`/`--arg`/`--argstr`. Wrapped text has offsets unrelated to the
    // source file, so drop the original source metadata.
    const selected = try applySelectors(ev, base.slice(), options, completion_auto_call);
    if (selected.text.isOwned()) {
        var wrapped = selected;
        wrapped.base_path = base.base_path;
        base.base_path = null;
        base.deinit(allocator);
        return wrapped;
    }
    return base;
}

/// Wrap `base_text` to apply `-A`/`--arg`/`--argstr`, as in `nix-instantiate`:
/// when `--arg`/`--argstr` are given and the value is a function, auto-call it
/// with those args intersected against its formals; then select the `-A`
/// attribute path. Returns owned wrapped text, or `base_text` borrowed when no
/// selector applies.
fn applySelectors(ev: *Engine, base_text: []const u8, options: args.SourceOptions, completion_auto_call: bool) !Source {
    const alloc = ev.hostAllocator();
    const has_args = options.arg_defs.len > 0;
    // A `-A` with only empty components (`.`/``) selects nothing.
    const has_attr = if (options.attr) |a| std.mem.indexOfNone(u8, a, ".") != null else false;
    if (!has_args and !has_attr and !completion_auto_call) return .{ .text = .{ .borrowed = base_text } };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    try out.appendSlice(alloc, "let __fix_top = (");
    try out.appendSlice(alloc, base_text);
    try out.appendSlice(alloc, ");\n");

    // Auto-call a top-level function with `--arg`/`--argstr` args intersected
    // against its formals (as in `nix-instantiate`, so missing formals fall
    // back to their defaults and extra args are dropped). A non-function value
    // passes through unchanged, so plain attrset files still work with `-A`.
    try out.appendSlice(alloc, "    __fix_args = {");
    for (options.arg_defs) |a| {
        try out.appendSlice(alloc, " \"");
        try appendNixEscaped(alloc, &out, a.name);
        try out.appendSlice(alloc, "\" = ");
        if (a.is_string) {
            try out.append(alloc, '"');
            try appendNixEscaped(alloc, &out, a.value);
            try out.append(alloc, '"');
        } else {
            try out.append(alloc, '(');
            try out.appendSlice(alloc, a.value);
            try out.append(alloc, ')');
        }
        try out.append(alloc, ';');
    }
    try out.appendSlice(alloc, " };\n    __fix_v = if builtins.isFunction __fix_top" ++
        " then __fix_top (builtins.intersectAttrs (builtins.functionArgs __fix_top) __fix_args)" ++
        " else __fix_top;\n");

    try out.appendSlice(alloc, "in __fix_v");
    if (options.attr) |attr| _ = try appendAttrPathSuffix(alloc, &out, attr);
    return .{ .text = .{ .owned = try out.toOwnedSlice(alloc) } };
}

/// Lower a flake installable `<flakeref>[#<attrpath>]` into a Nix expression
/// `(builtins.getFlake "<ref>").<attrpath>` and hand it to the normal evaluate
/// path. `.` and relative flakerefs resolve against the evaluator's base path
/// (the CLI's cwd); scheme refs (`github:`, `path:`, …) pass through to
/// `getFlake`. The attrpath is dot-split into quoted selections, so component
/// names may contain any character except `.`. The returned text is owned by
/// the evaluator's host allocator and lives for the rest of the (one-shot) run.
/// The output namespaces a flake fragment resolves against, per command. Nix's
/// installable resolution is command-specific: `build` looks in `packages`,
/// `eval` resolves the attr path from the flake root, etc.
const FlakeProfile = struct {
    /// System-scoped output sets tried in order (`<ns>.<system>.<attr>`).
    namespaces: []const []const u8,
    /// Try the flake root (`f.<attr>`) before the namespaces. `eval` does; the
    /// derivation-building commands try their package set first.
    root_first: bool,
    /// Attr to resolve for an empty fragment (`.#`): the default output. null →
    /// an empty fragment yields the whole flake (for `eval`).
    default_attr: ?[]const u8,
};

fn flakeProfile(cmd: args.Cmd) FlakeProfile {
    return switch (cmd) {
        // devShells first for `shell` (a dev shell IS a derivation, so building
        // it works); packages as the fallback for `fix shell nixpkgs#hello`.
        // A dev shell IS a derivation; devShells first, then packages.
        .shell, .print_dev_env => .{ .namespaces = &.{ "devShells", "packages", "legacyPackages" }, .root_first = false, .default_attr = "default" },
        // `run` resolves `apps.<sys>.x` first (execed directly by realize), then
        // falls back to a package's default binary.
        .run => .{ .namespaces = &.{ "apps", "packages", "legacyPackages" }, .root_first = false, .default_attr = "default" },
        .build, .@"switch" => .{ .namespaces = &.{ "packages", "legacyPackages" }, .root_first = false, .default_attr = "default" },
        // Value commands resolve the attr path from the flake root, as Nix's
        // `nix eval .#a.b` does, with packages as a convenience fallback.
        .eval, .parse, .instantiate, .repl, .disasm => .{ .namespaces = &.{ "packages", "legacyPackages" }, .root_first = true, .default_attr = null },
        .completions, .flake, .thunks, .trace => unreachable,
    };
}

/// Emit one candidate selection: `f.<ns>.${s}<suffix>`, or `f<suffix>` at the
/// flake root when `ns` is null. Candidates are `or`-chained so a miss at any
/// selection level falls through to the next.
fn appendFlakeCandidate(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), first: *bool, ns: ?[]const u8, suffix: []const u8) !void {
    if (!first.*) try out.appendSlice(alloc, " or ");
    first.* = false;
    if (ns) |n| {
        try out.appendSlice(alloc, "f.");
        try out.appendSlice(alloc, n);
        try out.appendSlice(alloc, ".${s}");
    } else {
        try out.appendSlice(alloc, "f");
    }
    try out.appendSlice(alloc, suffix);
}

fn lowerFlakeInstallable(ev: *Engine, installable: []const u8, options: args.SourceOptions) ![]u8 {
    const alloc = ev.hostAllocator();
    const hash = std.mem.indexOfScalar(u8, installable, '#');
    const flake_ref = if (hash) |i| installable[0..i] else installable;
    const attr_path = if (hash) |i| installable[i + 1 ..] else "";

    var resolved = try resolveFlakeRef(ev, flake_ref);
    defer resolved.deinit(alloc);
    const resolved_ref = resolved.slice();

    // Flake installables evaluate in pure mode (Nix's default); `--impure` opts
    // out. A local-path flake's own source tree is readable besides the store.
    const flake_dir: ?[]const u8 = if (std.mem.startsWith(u8, resolved_ref, "path:"))
        resolved_ref["path:".len..]
    else if (resolved_ref.len > 0 and resolved_ref[0] == '/')
        resolved_ref
    else
        null;
    try ev.setPureEval(!options.impure, if (flake_dir) |d| &.{d} else &.{});

    const profile = flakeProfile(options.cmd);

    // Build the attr-select suffix (`."a"."b"`) from the fragment.
    var suffix: std.ArrayListUnmanaged(u8) = .empty;
    defer suffix.deinit(alloc);
    const has_attr = (try appendAttrPathSuffix(alloc, &suffix, attr_path)) > 0;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    // Empty fragment: the whole flake (for `eval`), or the default output (for
    // the derivation-building commands — `.#` means `packages.<system>.default`).
    if (!has_attr) {
        if (profile.default_attr) |d| {
            _ = try appendAttrPathSuffix(alloc, &suffix, d);
        } else {
            try out.appendSlice(alloc, "(builtins.getFlake \"");
            try appendNixEscaped(alloc, &out, resolved_ref);
            try out.appendSlice(alloc, "\")");
            return out.toOwnedSlice(alloc);
        }
    }

    // The system is injected as a string literal (not `builtins.currentSystem`)
    // so the lowered expression is valid under pure evaluation.
    try out.appendSlice(alloc, "(let f = builtins.getFlake \"");
    try appendNixEscaped(alloc, &out, resolved_ref);
    try out.appendSlice(alloc, "\"; s = \"");
    try appendNixEscaped(alloc, &out, ev.systemName());
    try out.appendSlice(alloc, "\"; in ");

    var first = true;
    if (profile.root_first) try appendFlakeCandidate(alloc, &out, &first, null, suffix.items);
    for (profile.namespaces) |ns| try appendFlakeCandidate(alloc, &out, &first, ns, suffix.items);
    if (!profile.root_first) try appendFlakeCandidate(alloc, &out, &first, null, suffix.items);
    try out.appendSlice(alloc, ")");
    return out.toOwnedSlice(alloc);
}

/// Build a source expression whose result merges the attribute sets that Nix
/// installable lookup searches for a flake fragment: `packages.<system>`,
/// `legacyPackages.<system>`, and the flake output root. `parent` is the fully
/// typed portion before the final dot. Non-attr branches are ignored so a
/// similarly named leaf in one namespace cannot suppress useful candidates
/// from another.
pub fn lowerFlakeCompletion(ev: *Engine, flake_ref: []const u8, parent: []const u8) ![]const u8 {
    const alloc = ev.hostAllocator();
    var resolved = try resolveFlakeRef(ev, flake_ref);
    defer resolved.deinit(alloc);
    const resolved_ref = resolved.slice();

    var suffix: std.ArrayListUnmanaged(u8) = .empty;
    defer suffix.deinit(alloc);
    _ = try appendAttrPathSuffix(alloc, &suffix, parent);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "(let f = builtins.getFlake \"");
    try appendNixEscaped(alloc, &out, resolved_ref);
    try out.appendSlice(alloc, "\"; s = \"");
    try appendNixEscaped(alloc, &out, ev.systemName());
    try out.appendSlice(alloc, "\"; add = a: b: if builtins.isAttrs b then a // b else a; in add (add (add {} (f.packages.${s}");
    try out.appendSlice(alloc, suffix.items);
    try out.appendSlice(alloc, " or {})) (f.legacyPackages.${s}");
    try out.appendSlice(alloc, suffix.items);
    try out.appendSlice(alloc, " or {})) ");
    if (suffix.items.len == 0) {
        try out.appendSlice(alloc, "f)");
    } else {
        try out.appendSlice(alloc, "(f");
        try out.appendSlice(alloc, suffix.items);
        try out.appendSlice(alloc, " or {}))");
    }
    return out.toOwnedSlice(alloc);
}

const ResolvedRef = TextRef;

/// Turn a CLI flakeref into one `builtins.getFlake` accepts. Only the
/// CLI-specific bit lives here: `.` and paths (`/…`, `./…`, `../…`) resolve to
/// an absolute path against the base path (the cwd). Everything else — scheme
/// refs (`github:…`, `git+…`) and bare indirect ids (`nixpkgs`) — passes through
/// to getFlake, which resolves indirect ids via the flake registry itself.
fn resolveFlakeRef(ev: *Engine, flake_ref: []const u8) !ResolvedRef {
    if (flake_ref.len > 0 and (flake_ref[0] == '/' or flake_ref[0] == '.')) {
        const base = ev.basePath() orelse return .{ .borrowed = flake_ref };
        const abs = try std.fs.path.resolve(ev.hostAllocator(), &.{ base, flake_ref });
        return .{ .owned = abs };
    }
    return .{ .borrowed = flake_ref };
}

/// Append `."a"."b"` selections for the dotted `attr_path` to `out`, each
/// component quoted and escaped so it may contain any character except `.`.
/// Empty components (from `a..b`, a leading/trailing `.`, or a bare `.`) are
/// skipped. Returns the number of components appended.
fn appendAttrPathSuffix(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), attr_path: []const u8) !usize {
    var it = std.mem.splitScalar(u8, attr_path, '.');
    var count: usize = 0;
    while (it.next()) |component| {
        if (component.len == 0) continue;
        count += 1;
        try out.appendSlice(allocator, ".\"");
        try appendNixEscaped(allocator, out, component);
        try out.append(allocator, '"');
    }
    return count;
}

/// Append `text` escaped for a Nix double-quoted string literal. `$` is escaped
/// too so a `${` in a flakeref/attr name can never start an interpolation.
fn appendNixEscaped(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '\\', '"', '$' => try out.append(allocator, '\\'),
            else => {},
        }
        try out.append(allocator, c);
    }
}

test "completion auto-calls a top-level function with defaulted formals" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();

    var source = try applySelectors(
        &ev,
        "{ pkgs ? 41 }: { answer = pkgs + 1; hello = true; }",
        .{},
        true,
    );
    defer source.deinit(ev.hostAllocator());
    try std.testing.expect(source.text.isOwned());

    const value = try ev.evaluate(source.slice());
    try std.testing.expect((try ev.attrPathValue(value, "answer")) != null);
    try std.testing.expect((try ev.attrPathValue(value, "hello")) != null);
}

test "flake installable lowering: profiles, default attr, literal system" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer ev.deinit();
    const alloc = ev.hostAllocator();

    // The system is injected as a string literal, never `builtins.currentSystem`
    // (which pure eval forbids).
    const build_hello = try lowerFlakeInstallable(&ev, "github:o/r#hello", .{ .cmd = .build });
    defer alloc.free(build_hello);
    try std.testing.expect(std.mem.indexOf(u8, build_hello, "builtins.currentSystem") == null);
    try std.testing.expect(std.mem.indexOf(u8, build_hello, ev.systemName()) != null);
    // build tries the package sets before the flake root.
    const p_idx = std.mem.indexOf(u8, build_hello, "f.packages.${s}").?;
    const root_idx = std.mem.indexOf(u8, build_hello, " or f.\"hello\"").?;
    try std.testing.expect(p_idx < root_idx);

    // eval resolves the attr path from the flake root first.
    const eval_x = try lowerFlakeInstallable(&ev, "github:o/r#a.b", .{ .cmd = .eval });
    defer alloc.free(eval_x);
    try std.testing.expect(std.mem.indexOf(u8, eval_x, "in f.\"a\".\"b\" or f.packages.${s}") != null);

    // Empty fragment: default output for build, whole flake for eval.
    const build_default = try lowerFlakeInstallable(&ev, "github:o/r", .{ .cmd = .build });
    defer alloc.free(build_default);
    try std.testing.expect(std.mem.indexOf(u8, build_default, "f.packages.${s}.\"default\"") != null);
    const eval_whole = try lowerFlakeInstallable(&ev, "github:o/r", .{ .cmd = .eval });
    defer alloc.free(eval_whole);
    try std.testing.expectEqualStrings("(builtins.getFlake \"github:o/r\")", eval_whole);

    // shell resolves devShells before packages.
    const shell_x = try lowerFlakeInstallable(&ev, "github:o/r#dev", .{ .cmd = .shell });
    defer alloc.free(shell_x);
    const dev_idx = std.mem.indexOf(u8, shell_x, "f.devShells.${s}").?;
    const pkg_idx = std.mem.indexOf(u8, shell_x, "f.packages.${s}").?;
    try std.testing.expect(dev_idx < pkg_idx);
}
