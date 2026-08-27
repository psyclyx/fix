//! Lix functional2/lang runner — the declarative half (eval + parse cases,
//! discovered from `.exp` goldens and `test.toml` manifests). Ported from
//! run.py. The 7 python-backed custom dirs are handled in lix_custom.zig.

const std = @import("std");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");
const toml = @import("toml.zig");
const yaml = @import("yaml.zig");
const Result = @import("result.zig").Result;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    fix: []const u8,
    parent_env: *const std.process.Environ.Map,
    lang_dir: []const u8,
};

pub const Runner = enum { eval_okay, eval_fail, parse_okay, parse_fail };

fn runnerFromStr(s: []const u8) ?Runner {
    if (std.mem.eql(u8, s, "eval-okay")) return .eval_okay;
    if (std.mem.eql(u8, s, "eval-fail")) return .eval_fail;
    if (std.mem.eql(u8, s, "parse-okay")) return .parse_okay;
    if (std.mem.eql(u8, s, "parse-fail")) return .parse_fail;
    return null;
}

pub const Case = struct {
    case_dir: []const u8,
    ident: []const u8,
    runner: Runner,
    in_file: []const u8 = "in.nix",
    test_name: []const u8 = "",
    flags: []const []const u8 = &.{},
    extra_files: []const []const u8 = &.{},
    global_assets: []const []const u8 = &.{},
};

// --- discovery --------------------------------------------------------------

pub const Discovered = struct {
    cases: []const Case,
    /// case dirs skipped because they are python-backed (handled elsewhere).
    custom_dirs: []const []const u8,
};

pub fn discover(arena: std.mem.Allocator, io: std.Io, lang_dir: []const u8) !Discovered {
    var cases: std.ArrayListUnmanaged(Case) = .empty;
    var custom: std.ArrayListUnmanaged([]const u8) = .empty;

    const dir_names = try listDir(arena, io, lang_dir, .directory);
    std.mem.sort([]const u8, dir_names, {}, lessStr);
    for (dir_names) |name| {
        if (std.mem.eql(u8, name, "assets") or std.mem.eql(u8, name, "__pycache__")) continue;
        const case_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ lang_dir, name });
        const files = try listDir(arena, io, case_dir, .file);
        if (anyEndsWith(files, ".py")) {
            try custom.append(arena, name);
            continue;
        }
        if (hasFile(files, "test.toml")) {
            try tomlCases(arena, io, case_dir, name, files, &cases);
        } else {
            try simpleCases(arena, case_dir, name, files, &cases);
        }
    }
    return .{ .cases = cases.items, .custom_dirs = custom.items };
}

fn simpleCases(arena: std.mem.Allocator, case_dir: []const u8, rel: []const u8, files: []const []const u8, out: *std.ArrayListUnmanaged(Case)) !void {
    var seen: std.ArrayListUnmanaged([]const u8) = .empty;
    for (files) |f| {
        if (f.len > 0 and f[0] == '_') continue;
        if (!std.mem.endsWith(u8, f, ".exp")) continue;
        const stem = rsplit2(f); // drop the last two dot-extensions
        const rn = parseRunnerName(stem) orelse continue;
        if (containsStr(seen.items, stem)) continue;
        try seen.append(arena, stem);
        const in_file = try std.fmt.allocPrint(arena, "in{s}.nix", .{rn.suffix});
        try out.append(arena, .{
            .case_dir = case_dir,
            .ident = try std.fmt.allocPrint(arena, "{s}:{s}", .{ rel, stem }),
            .runner = rn.runner,
            .in_file = in_file,
            .test_name = stem,
        });
    }
}

fn tomlCases(arena: std.mem.Allocator, io: std.Io, case_dir: []const u8, rel: []const u8, files: []const []const u8, out: *std.ArrayListUnmanaged(Case)) !void {
    const text = try fsx.readFile(arena, io, try std.fmt.allocPrint(arena, "{s}/test.toml", .{case_dir}));
    const entries = try toml.parse(arena, text);
    // All "in*.nix" present, sorted (for matrix without an explicit `in`).
    var in_files: std.ArrayListUnmanaged([]const u8) = .empty;
    for (files) |f| {
        if (isInFile(f)) try in_files.append(arena, f);
    }
    std.mem.sort([]const u8, in_files.items, {}, lessStr);

    for (entries) |e| {
        const runner = runnerFromStr(e.runner) orelse continue;
        const name = e.name orelse e.runner;
        const names: []const []const u8 = if (e.matrix)
            (e.in_spec orelse in_files.items)
        else if (e.in_spec) |s| s[0..1] else &.{"in.nix"};
        for (names) |in_file| {
            const suffix = inFileSuffix(in_file);
            const test_name = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, suffix });
            try out.append(arena, .{
                .case_dir = case_dir,
                .ident = try std.fmt.allocPrint(arena, "{s}:{s}", .{ rel, test_name }),
                .runner = runner,
                .in_file = in_file,
                .test_name = test_name,
                .flags = e.flags,
                .extra_files = e.extra_files,
                .global_assets = e.global_assets,
            });
        }
    }
}

// --- execution --------------------------------------------------------------

pub fn runCase(ctx: Ctx, c: Case, arena: std.mem.Allocator) !Result {
    var fix_flags: std.ArrayListUnmanaged([]const u8) = .empty;
    if (translateFlags(arena, c.flags, &fix_flags)) |ferr|
        return Result.fail("lix", c.ident, try std.fmt.allocPrint(arena, "flag translation failed: {s}", .{ferr}));

    const tmp = try fsx.makeTempDir(ctx.gpa, ctx.io);
    defer {
        fsx.removeTree(ctx.io, tmp);
        ctx.gpa.free(tmp);
    }
    if (try setupFiles(ctx, c, tmp, arena)) |serr|
        return Result.fail("lix", c.ident, try std.fmt.allocPrint(arena, "setup failed: {s}", .{serr}));

    var env = try proc.cloneEnv(ctx.gpa, ctx.parent_env);
    defer env.deinit();
    try env.put("HOME", tmp);

    return switch (c.runner) {
        .eval_okay, .eval_fail => self_eval(ctx, c, tmp, &env, fix_flags.items, arena),
        .parse_okay, .parse_fail => self_parse(ctx, c, tmp, &env, fix_flags.items, arena),
    };
}

fn self_eval(ctx: Ctx, c: Case, tmp: []const u8, env: *std.process.Environ.Map, flags: []const []const u8, arena: std.mem.Allocator) !Result {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ ctx.fix, "eval", "--workers", "1", "--strict", "--extra-experimental-features", "flakes" });
    try argv.appendSlice(arena, flags);
    try argv.append(arena, "in.nix");
    var out = try proc.run(ctx.gpa, ctx.io, argv.items, tmp, env, proc.case_timeout_ns);
    defer out.deinit(ctx.gpa);

    if (c.runner == .eval_fail) {
        if (out.rc == 1) return Result.pass("lix", c.ident);
        if (out.timed_out) return Result.fail("lix", c.ident, "expected eval failure, but fix hung (timeout)");
        if (out.rc == 0) return Result.fail("lix", c.ident, "expected eval failure, but it succeeded");
        return Result.fail("lix", c.ident, try std.fmt.allocPrint(arena, "expected eval failure (rc 1), got rc {d}", .{out.rc}));
    }

    const golden = try readGolden(ctx, c, arena, "out");
    if (golden == null) return Result.fail("lix", c.ident, "eval-okay case has no .out.exp golden (manifest error)");
    if (out.rc != 0)
        return Result.fail("lix", c.ident, try std.fmt.allocPrint(arena, "eval failed:\n{s}", .{std.mem.trim(u8, out.stderr, " \n\r\t")}));
    const got = try replaceAll(arena, out.stdout, tmp, "/pwd");
    if (std.mem.eql(u8, std.mem.trim(u8, got, " \n\r\t"), std.mem.trim(u8, golden.?, " \n\r\t")))
        return Result.pass("lix", c.ident);
    return Result.fail("lix", c.ident, try diff(arena, golden.?, got));
}

fn self_parse(ctx: Ctx, c: Case, tmp: []const u8, env: *std.process.Environ.Map, flags: []const []const u8, arena: std.mem.Allocator) !Result {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ ctx.fix, "parse", "--json" });
    try argv.appendSlice(arena, flags);
    try argv.append(arena, "in.nix");
    var out = try proc.run(ctx.gpa, ctx.io, argv.items, tmp, env, proc.case_timeout_ns);
    defer out.deinit(ctx.gpa);

    if (c.runner == .parse_fail) {
        if (out.rc != 1 or std.mem.trim(u8, out.stdout, " \n\r\t").len != 0)
            return Result.fail("lix", c.ident, try std.fmt.allocPrint(arena, "expected a parse error (exit 1, no AST); got rc={d}", .{out.rc}));
        const want_line = if (try readGolden(ctx, c, arena, "err")) |e| errorLine(e) else null;
        const got_line = errorLine(out.stderr);
        if (want_line != null and got_line != null and want_line.? != got_line.?)
            return Result.fail("lix", c.ident, try std.fmt.allocPrint(arena, "parse error on line {d}, Nix reports line {d}", .{ got_line.?, want_line.? }));
        return Result.pass("lix", c.ident);
    }

    const golden = try readGolden(ctx, c, arena, "out");
    if (golden == null) return Result.fail("lix", c.ident, "parse-okay case has no .out.exp golden (manifest error)");
    if (out.rc != 0)
        return Result.fail("lix", c.ident, try std.fmt.allocPrint(arena, "parse failed (rc={d}):\n{s}", .{ out.rc, std.mem.trim(u8, out.stderr, " \n\r\t") }));

    const normalized = try replaceAll(arena, out.stdout, tmp, "/pwd");
    const got_ast = std.json.parseFromSliceLeaky(std.json.Value, arena, normalized, .{}) catch |e|
        return Result.fail("lix", c.ident, try std.fmt.allocPrint(arena, "could not parse fix JSON: {s}", .{@errorName(e)}));
    const want_ast = yaml.parse(arena, golden.?) catch |e|
        return Result.fail("lix", c.ident, try std.fmt.allocPrint(arena, "could not parse golden YAML: {s}", .{@errorName(e)}));
    if (!yaml.equals(want_ast, got_ast))
        return Result.fail("lix", c.ident, try diff(arena, golden.?, normalized));

    // AST matches: any golden deprecation warning must be present by kind.
    if (try readGolden(ctx, c, arena, "err")) |err_golden| {
        const want = warningKinds(err_golden);
        const got = warningKinds(out.stderr);
        if (want & ~got != 0)
            return Result.fail("lix", c.ident, "AST matches but missing deprecation warning(s)");
    }
    return Result.pass("lix", c.ident);
}

// --- setup ------------------------------------------------------------------

fn setupFiles(ctx: Ctx, c: Case, tmp: []const u8, arena: std.mem.Allocator) !?[]const u8 {
    try fsx.copyFile(ctx.gpa, ctx.io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ c.case_dir, c.in_file }), try std.fmt.allocPrint(arena, "{s}/in.nix", .{tmp}));
    const lib = try std.fmt.allocPrint(arena, "{s}/lib.nix", .{ctx.lang_dir});
    if (fsx.exists(ctx.io, lib))
        try fsx.copyFile(ctx.gpa, ctx.io, lib, try std.fmt.allocPrint(arena, "{s}/lib.nix", .{tmp}));
    for (c.extra_files) |extra| {
        const src = try std.fmt.allocPrint(arena, "{s}/{s}", .{ c.case_dir, extra });
        if (!fsx.exists(ctx.io, src)) return try std.fmt.allocPrint(arena, "missing extra-file {s}", .{extra});
        const dst = try std.fmt.allocPrint(arena, "{s}/{s}", .{ tmp, std.fs.path.basename(extra) });
        // A directory extra is copied as a tree; a file as a file.
        if (std.Io.Dir.cwd().openDir(ctx.io, src, .{})) |*d| {
            @constCast(d).close(ctx.io);
            try fsx.copyTree(ctx.gpa, ctx.io, src, dst);
        } else |_| {
            try fsx.copyFile(ctx.gpa, ctx.io, src, dst);
        }
    }
    for (c.global_assets) |asset| {
        if (try provideGlobalAsset(ctx, asset, tmp, arena)) |e| return e;
    }
    return null;
}

fn provideGlobalAsset(ctx: Ctx, name: []const u8, dest: []const u8, arena: std.mem.Allocator) !?[]const u8 {
    const ga = try std.fmt.allocPrint(arena, "{s}/../testlib/global_assets", .{ctx.lang_dir});
    if (std.mem.eql(u8, name, "config.nix")) {
        const tpl = try std.fmt.allocPrint(arena, "{s}/config.nix.template", .{ga});
        if (!fsx.exists(ctx.io, tpl)) return "global-asset config.nix template missing";
        var text: []const u8 = try fsx.readFile(arena, ctx.io, tpl);
        text = try replaceAll(arena, text, "@path@", "/path-placeholder");
        text = try replaceAll(arena, text, "@system@", "x86_64-linux");
        text = try replaceAll(arena, text, "@shell@", "/bin/sh");
        try fsx.writeFile(ctx.io, try std.fmt.allocPrint(arena, "{s}/config.nix", .{dest}), text);
        return null;
    }
    const src = try std.fmt.allocPrint(arena, "{s}/{s}", .{ ga, name });
    if (!fsx.exists(ctx.io, src)) return try std.fmt.allocPrint(arena, "unsatisfiable global-asset {s}", .{name});
    try fsx.copyFile(ctx.gpa, ctx.io, src, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, name }));
    return null;
}

fn readGolden(ctx: Ctx, c: Case, arena: std.mem.Allocator, which: []const u8) !?[]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.{s}.exp", .{ c.case_dir, c.test_name, which });
    if (!fsx.exists(ctx.io, path)) return null;
    return try fsx.readFile(arena, ctx.io, path);
}

// --- flag translation -------------------------------------------------------

const supported_flags = [_][]const u8{ "-A", "--attr", "--arg", "--argstr", "--option", "-I", "--include", "--xml", "--json", "--strict", "--no-location", "--expr", "-E", "--file", "--show-trace", "--no-show-trace" };
const fix_experimental = [_][]const u8{ "pipe-operators", "fetch-tree", "flakes", "coerce-integers" };

/// Returns null on success (filling `out`), or an error reason string.
fn translateFlags(arena: std.mem.Allocator, flags: []const []const u8, out: *std.ArrayListUnmanaged([]const u8)) ?[]const u8 {
    var i: usize = 0;
    while (i < flags.len) {
        const f = flags[i];
        if (std.mem.eql(u8, f, "--extra-deprecated-features") or std.mem.eql(u8, f, "--deprecated-features")) {
            out.appendSlice(arena, flags[i .. i + 2]) catch return "oom";
            i += 2;
        } else if (std.mem.eql(u8, f, "--no-warning")) {
            i += 1;
        } else if (std.mem.eql(u8, f, "--extra-experimental-features") or std.mem.eql(u8, f, "--experimental-features")) {
            var vals: std.ArrayListUnmanaged([]const u8) = .empty;
            var it = std.mem.tokenizeScalar(u8, flags[i + 1], ' ');
            while (it.next()) |v| {
                if (std.mem.eql(u8, v, "nix-command")) continue;
                if (!containsStr(&fix_experimental, v)) return std.fmt.allocPrint(arena, "unsupported-feature:{s}", .{v}) catch "oom";
                vals.append(arena, v) catch return "oom";
            }
            if (vals.items.len > 0) {
                out.append(arena, f) catch return "oom";
                out.append(arena, std.mem.join(arena, " ", vals.items) catch return "oom") catch return "oom";
            }
            i += 2;
        } else if (isArgFlag(f)) {
            const n: usize = if (std.mem.eql(u8, f, "--option") or std.mem.eql(u8, f, "--arg") or std.mem.eql(u8, f, "--argstr")) 2 else 1;
            out.appendSlice(arena, flags[i .. i + 1 + n]) catch return "oom";
            i += 1 + n;
        } else if (f.len > 0 and f[0] == '-') {
            if (!containsStr(&supported_flags, f)) return std.fmt.allocPrint(arena, "unsupported-flag:{s}", .{f}) catch "oom";
            out.append(arena, f) catch return "oom";
            i += 1;
        } else {
            out.append(arena, f) catch return "oom";
            i += 1;
        }
    }
    return null;
}

fn isArgFlag(f: []const u8) bool {
    const set = [_][]const u8{ "-A", "--attr", "--option", "--arg", "--argstr", "-I", "--include" };
    return containsStr(&set, f);
}

// --- diagnostics parsing ----------------------------------------------------

/// The line number of the last positioned parse error `at <path>:<line>:<col>:`.
fn errorLine(text: []const u8) ?usize {
    var result: ?usize = null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, " at ")) |at| {
        // seek to the ':<digits>:<digits>:' pattern after "at "
        var j = at + 4;
        while (j < text.len and text[j] != ':' and text[j] != ' ' and text[j] != '\n') j += 1;
        if (j < text.len and text[j] == ':') {
            const line_start = j + 1;
            var k = line_start;
            while (k < text.len and std.ascii.isDigit(text[k])) k += 1;
            if (k > line_start and k < text.len and text[k] == ':') {
                var m = k + 1;
                while (m < text.len and std.ascii.isDigit(text[m])) m += 1;
                if (m > k + 1 and m < text.len and text[m] == ':') {
                    result = std.fmt.parseInt(usize, text[line_start..k], 10) catch result;
                }
            }
        }
        i = at + 4;
    }
    return result;
}

// Deprecation-warning kinds, by a distinctive substring. Bitset over the list.
const warning_kinds = [_]struct { keys: []const []const u8 }{
    .{ .keys = &.{ "leading zero", "floating point literal" } }, // floating-without-zero
    .{ .keys = &.{"as an identifier"} }, // or-as-identifier
    .{ .keys = &.{"ill-defined escape"} }, // broken-string-escape
    .{ .keys = &.{"dynamic attribute"} }, // rec-set-dynamic-attrs
    .{ .keys = &.{"line endings are not supported"} }, // cr-line-endings
};

pub fn warningKinds(text: []const u8) u32 {
    var mask: u32 = 0;
    for (warning_kinds, 0..) |wk, bit| {
        for (wk.keys) |k| {
            if (std.mem.indexOf(u8, text, k) != null) {
                mask |= @as(u32, 1) << @intCast(bit);
                break;
            }
        }
    }
    return mask;
}

// --- small helpers ----------------------------------------------------------

fn listDir(arena: std.mem.Allocator, io: std.Io, path: []const u8, want: std.Io.File.Kind) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == want) try out.append(arena, try arena.dupe(u8, entry.name));
    }
    return out.items;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
fn anyEndsWith(items: []const []const u8, suffix: []const u8) bool {
    for (items) |x| if (std.mem.endsWith(u8, x, suffix)) return true;
    return false;
}
fn hasFile(items: []const []const u8, name: []const u8) bool {
    return containsStr(items, name);
}
fn containsStr(items: []const []const u8, s: []const u8) bool {
    for (items) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// Drop the final two dot-delimited extensions ("foo.out.exp" -> "foo").
fn rsplit2(f: []const u8) []const u8 {
    const last = std.mem.lastIndexOfScalar(u8, f, '.') orelse return f;
    const prev = std.mem.lastIndexOfScalar(u8, f[0..last], '.') orelse return f[0..last];
    return f[0..prev];
}

const RunnerName = struct { runner: Runner, suffix: []const u8 };

/// Match `(eval-okay|eval-fail|parse-okay|parse-fail)(-suffix)?`.
fn parseRunnerName(stem: []const u8) ?RunnerName {
    const prefixes = [_]struct { s: []const u8, r: Runner }{
        .{ .s = "eval-okay", .r = .eval_okay },
        .{ .s = "eval-fail", .r = .eval_fail },
        .{ .s = "parse-okay", .r = .parse_okay },
        .{ .s = "parse-fail", .r = .parse_fail },
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, stem, p.s)) {
            const rest = stem[p.s.len..];
            if (rest.len == 0) return .{ .runner = p.r, .suffix = "" };
            if (rest[0] == '-') return .{ .runner = p.r, .suffix = rest };
        }
    }
    return null;
}

fn isInFile(f: []const u8) bool {
    if (!std.mem.startsWith(u8, f, "in") or !std.mem.endsWith(u8, f, ".nix")) return false;
    const mid = f["in".len .. f.len - ".nix".len];
    return mid.len == 0 or mid[0] == '-';
}

fn inFileSuffix(in_file: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, in_file, "in") or !std.mem.endsWith(u8, in_file, ".nix")) return "";
    return in_file["in".len .. in_file.len - ".nix".len];
}

fn replaceAll(arena: std.mem.Allocator, haystack: []const u8, needle: []const u8, repl: []const u8) ![]const u8 {
    if (needle.len == 0 or std.mem.indexOf(u8, haystack, needle) == null) return haystack;
    const size = std.mem.replacementSize(u8, haystack, needle, repl);
    const buf = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, haystack, needle, repl, buf);
    return buf;
}

fn diff(arena: std.mem.Allocator, expected: []const u8, actual: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "  expected: {s}\n  actual:   {s}", .{ std.mem.trim(u8, expected, " \n\r\t"), std.mem.trim(u8, actual, " \n\r\t") });
}
