//! snix nix-language-test-suite runner — a port of run.py's snix half. Each
//! case is a `.kdl` manifest plus a `.nix` program and a `.exp` (value golden)
//! or `.err` (error-kind golden). We materialise the declared fixture tree,
//! drive the program through `fix eval`, and compare.

const std = @import("std");
const builtin = @import("builtin");
const kdl = @import("kdl.zig");
const fsx = @import("fsx.zig");
const proc = @import("proc.zig");
const Result = @import("result.zig").Result;

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    fix: []const u8,
    parent_env: *const std.process.Environ.Map,
    userns_ok: bool,
    store_ok: bool,
    home: []const u8,
};

const xp_features = [_][]const u8{ "flakes", "pipe-operators" };
const lang_features = [_][]const u8{ "corepkgs", "path-interpolation", "curpos" };
const device_kinds = [_][]const u8{ "char", "block", "device" };

// error-kind -> substrings fix's stderr must contain (modern CppNix/Lix phrasing).
fn errorKindSubs(kind: []const u8) ?[]const []const u8 {
    const map = .{
        .{ "NotCoercibleToString", &[_][]const u8{"cannot coerce"} },
        .{ "IO", &[_][]const u8{ "does not exist", "No such file or directory", "has an unsupported type" } },
        .{ "TypeError", &[_][]const u8{ "requires a function", "expected a", "was expected" } },
        .{ "InvalidHash", &[_][]const u8{ "invalid SRI hash", "invalid hash" } },
        .{ "InvalidStorePath", &[_][]const u8{ "is not a valid store path", "store path" } },
        .{ "HashMismatch", &[_][]const u8{ "store path mismatch", "hash mismatch" } },
        .{ "DerivationError", &[_][]const u8{ "invalid derivation name", "should have type", "duplicate derivation output", "cannot process __json" } },
        .{ "UnexpectedArgument", &[_][]const u8{ "unsupported argument", "unexpected argument" } },
        .{ "VariableAlreadyDefined", &[_][]const u8{"already defined"} },
        .{ "DuplicateAttrsKey", &[_][]const u8{ "already defined", "duplicate" } },
        .{ "UnexpectedContext", &[_][]const u8{ "may not reference derivations", "has a context" } },
        .{ "Abort", &[_][]const u8{"evaluation aborted"} },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, kind, entry[0])) return entry[1];
    }
    return null;
}

pub const Case = struct {
    kdl_path: []const u8,
    ident: []const u8,
    eval_strict: bool = false,
    xml_output: bool = false,
    search_path: []const []const u8 = &.{},
    features: []const []const u8 = &.{},
    work_dir: ?[]const u8 = null,
    env_vars: []const [2][]const u8 = &.{},
    nix_store: bool = false,
    fixtures: []const kdl.Node = &.{},
};

/// Load and parse one `.kdl` case. `arena` must outlive the case (its slices
/// point into it). `ident` is the path under cases_root without the suffix.
pub fn loadCase(arena: std.mem.Allocator, io: std.Io, kdl_path: []const u8, cases_root: []const u8) !Case {
    const text = try fsx.readFile(arena, io, kdl_path);
    const nodes = try kdl.parse(arena, text);

    var rel = kdl_path[cases_root.len..];
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    const ident = rel[0 .. rel.len - ".kdl".len];

    var c: Case = .{ .kdl_path = kdl_path, .ident = ident };
    var search: std.ArrayListUnmanaged([]const u8) = .empty;
    var feats: std.ArrayListUnmanaged([]const u8) = .empty;
    var envs: std.ArrayListUnmanaged([2][]const u8) = .empty;

    for (nodes) |node| {
        if (std.mem.eql(u8, node.name, "runtime-opts")) {
            for (node.children) |ch| {
                if (std.mem.eql(u8, ch.name, "eval-strict")) c.eval_strict = true //
                else if (std.mem.eql(u8, ch.name, "xml-output")) c.xml_output = true //
                else if (std.mem.eql(u8, ch.name, "search-path")) try search.appendSlice(arena, ch.args);
            }
        } else if (std.mem.eql(u8, node.name, "lang")) {
            for (node.children) |ch| {
                if (std.mem.eql(u8, ch.name, "features")) try feats.appendSlice(arena, ch.args);
            }
        } else if (std.mem.eql(u8, node.name, "environment")) {
            for (node.children) |ch| {
                if (std.mem.eql(u8, ch.name, "work-dir")) {
                    c.work_dir = if (ch.args.len > 0) ch.args[0] else null;
                } else if (std.mem.eql(u8, ch.name, "env-var") and ch.args.len >= 2) {
                    try envs.append(arena, .{ ch.args[0], ch.args[1] });
                } else if (std.mem.eql(u8, ch.name, "nix-store")) {
                    c.nix_store = true;
                } else if (std.mem.eql(u8, ch.name, "fixtures")) {
                    c.fixtures = ch.children;
                }
            }
        }
    }
    c.search_path = search.items;
    c.features = feats.items;
    c.env_vars = envs.items;
    return c;
}

fn isXpFeature(f: []const u8) bool {
    for (xp_features) |x| if (std.mem.eql(u8, f, x)) return true;
    return false;
}
fn isLangFeature(f: []const u8) bool {
    for (lang_features) |x| if (std.mem.eql(u8, f, x)) return true;
    return false;
}
fn isDeviceKind(name: []const u8) bool {
    for (device_kinds) |x| if (std.mem.eql(u8, name, x)) return true;
    return false;
}

const Flags = struct { flags: []const []const u8, reason: ?[]const u8 = null };

fn snixFlags(arena: std.mem.Allocator, c: Case) !Flags {
    var flags: std.ArrayListUnmanaged([]const u8) = .empty;
    if (c.eval_strict) try flags.append(arena, "--strict");
    if (c.xml_output) try flags.appendSlice(arena, &.{ "--xml", "--no-location" });
    for (c.search_path) |p| try flags.appendSlice(arena, &.{ "--include", p });
    var feats: std.ArrayListUnmanaged([]const u8) = .empty;
    for (c.features) |f| {
        if (isXpFeature(f)) {
            try feats.append(arena, f);
        } else if (isLangFeature(f)) {
            continue; // language-level; judged by the golden
        } else {
            return .{ .flags = flags.items, .reason = try std.fmt.allocPrint(arena, "unsupported-feature:{s}", .{f}) };
        }
    }
    if (feats.items.len > 0) {
        const joined = try std.mem.join(arena, " ", feats.items);
        try flags.appendSlice(arena, &.{ "--extra-experimental-features", joined });
    }
    return .{ .flags = flags.items };
}

const FixtureErr = struct { status: enum { fail, blocked }, detail: []const u8 };

fn materializeFixtures(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    fixtures: []const kdl.Node,
    case_dir: []const u8,
    dest: []const u8,
    devices: *std.ArrayListUnmanaged([]const u8),
) !?FixtureErr {
    for (fixtures) |fx| {
        const arg0: []const u8 = if (fx.args.len > 0) fx.args[0] else "";
        if (std.mem.eql(u8, fx.name, "file")) {
            const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, arg0 });
            try fsx.mkpath(io, std.fs.path.dirname(target) orelse dest);
            if (fx.prop("content")) |content| {
                try fsx.writeFile(io, target, content);
            } else if (fx.prop("ref")) |ref| {
                const src = try std.fmt.allocPrint(arena, "{s}/{s}", .{ case_dir, ref });
                try fsx.copyFile(gpa, io, src, target);
            } else {
                try fsx.writeFile(io, target, "");
            }
        } else if (std.mem.eql(u8, fx.name, "dir")) {
            const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, arg0 });
            if (fx.prop("ref")) |ref| {
                const src = try std.fmt.allocPrint(arena, "{s}/{s}", .{ case_dir, ref });
                try fsx.copyTree(gpa, io, src, target);
            } else {
                try fsx.mkpath(io, target);
                if (try materializeFixtures(gpa, io, arena, fx.children, case_dir, target, devices)) |e| return e;
            }
        } else if (std.mem.eql(u8, fx.name, "symlink")) {
            const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, arg0 });
            try fsx.mkpath(io, std.fs.path.dirname(target) orelse dest);
            try fsx.symlink(io, fx.prop("target") orelse "", target);
        } else if (std.mem.eql(u8, fx.name, "fifo")) {
            const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, arg0 });
            try fsx.mkpath(io, std.fs.path.dirname(target) orelse dest);
            try fsx.mkfifoAt(gpa, target);
        } else if (std.mem.eql(u8, fx.name, "socket")) {
            const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, arg0 });
            try fsx.mkpath(io, std.fs.path.dirname(target) orelse dest);
            try fsx.mksocket(io, target);
        } else if (isDeviceKind(fx.name)) {
            if (std.fs.path.isAbsolute(arg0)) {
                if (!fsx.exists(io, arg0))
                    return .{ .status = .blocked, .detail = try std.fmt.allocPrint(arena, "missing-system-device:{s}", .{arg0}) };
                continue;
            }
            const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, arg0 });
            try fsx.mkpath(io, std.fs.path.dirname(target) orelse dest);
            try fsx.writeFile(io, target, "");
            try devices.append(arena, target);
        } else {
            return .{ .status = .fail, .detail = try std.fmt.allocPrint(arena, "unsupported-fixture:{s}", .{fx.name}) };
        }
    }
    return null;
}

fn shellQuote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(arena, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, ch);
    }
    try out.append(arena, '\'');
    return out.items;
}

pub fn runCase(ctx: Ctx, c: Case, arena: std.mem.Allocator) !Result {
    const gpa = ctx.gpa;
    const io = ctx.io;

    if (c.nix_store and !ctx.store_ok)
        return Result.blocked("snix", c.ident, "needs-store (no nix-daemon/writable store)");

    const stem = c.kdl_path[0 .. c.kdl_path.len - ".kdl".len];
    const nix_src = try std.fmt.allocPrint(arena, "{s}.nix", .{stem});
    const exp = try std.fmt.allocPrint(arena, "{s}.exp", .{stem});
    const err = try std.fmt.allocPrint(arena, "{s}.err", .{stem});
    if (!fsx.exists(io, nix_src)) return Result.fail("snix", c.ident, "missing .nix companion");
    if (!fsx.exists(io, exp) and !fsx.exists(io, err))
        return Result.fail("snix", c.ident, "missing golden (.exp/.err)");

    const fl = try snixFlags(arena, c);
    if (fl.reason) |r| return Result.fail("snix", c.ident, r);

    const tmp = try fsx.makeTempDir(gpa, io);
    defer {
        fsx.removeTree(io, tmp);
        gpa.free(tmp);
    }

    var devices: std.ArrayListUnmanaged([]const u8) = .empty;
    const case_dir = std.fs.path.dirname(c.kdl_path) orelse ".";
    if (try materializeFixtures(gpa, io, arena, c.fixtures, case_dir, tmp, &devices)) |e| {
        return switch (e.status) {
            .fail => Result.fail("snix", c.ident, e.detail),
            .blocked => Result.blocked("snix", c.ident, e.detail),
        };
    }
    if (devices.items.len > 0 and !ctx.userns_ok)
        return Result.blocked("snix", c.ident, "device-fixture (no rootless userns)");

    // Copy the program in and run it from the temp dir.
    const nix_name = std.fs.path.basename(nix_src);
    const dst_nix = try std.fmt.allocPrint(arena, "{s}/{s}", .{ tmp, nix_name });
    if (builtin.os.tag.isDarwin() and std.mem.eql(u8, c.ident, "environment/import-from-derivation")) {
        // The corpus uses `echo -n` only to create an IFD payload. Darwin's
        // /bin/sh prints `-n` literally, so make that incidental fixture
        // portable while preserving the derivation/readFile behavior under
        // test.
        const source = try fsx.readFile(arena, io, nix_src);
        const portable = try replaceAll(arena, source, "echo -n hello > $out", "printf %s hello > $out");
        try fsx.writeFile(io, dst_nix, portable);
    } else {
        try fsx.copyFile(gpa, io, nix_src, dst_nix);
    }

    var env = try proc.cloneEnv(gpa, ctx.parent_env);
    defer env.deinit();
    for (c.env_vars) |kv| try env.put(kv[0], kv[1]);

    // fix eval --workers 1 [flags] <name>, optionally wrapped in a userns that
    // bind-mounts /dev/null over each device fixture (a real char special file).
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    if (devices.items.len == 0) {
        try argv.appendSlice(arena, &.{ ctx.fix, "eval", "--workers", "1" });
        try argv.appendSlice(arena, fl.flags);
        try argv.append(arena, nix_name);
    } else {
        var inner: std.ArrayListUnmanaged(u8) = .empty;
        for (devices.items) |t| {
            try inner.appendSlice(arena, "mount --bind /dev/null ");
            try inner.appendSlice(arena, try shellQuote(arena, t));
            try inner.appendSlice(arena, " && ");
        }
        try inner.appendSlice(arena, "exec ");
        for ([_][]const u8{ ctx.fix, "eval", "--workers", "1" }) |a| {
            try inner.appendSlice(arena, try shellQuote(arena, a));
            try inner.append(arena, ' ');
        }
        for (fl.flags) |a| {
            try inner.appendSlice(arena, try shellQuote(arena, a));
            try inner.append(arena, ' ');
        }
        try inner.appendSlice(arena, try shellQuote(arena, nix_name));
        try argv.appendSlice(arena, &.{ "unshare", "--map-root-user", "--user", "--mount", "sh", "-c", inner.items });
    }

    var out = try proc.run(gpa, io, argv.items, tmp, &env, proc.case_timeout_ns);
    defer out.deinit(gpa);

    // --- error-kind golden ---
    if (fsx.exists(io, err)) {
        const kind_raw = try fsx.readFile(arena, io, err);
        const kind = std.mem.trim(u8, kind_raw, " \n\r\t");
        const subs = errorKindSubs(kind) orelse &[_][]const u8{};
        if (out.rc == 1) {
            for (subs) |s| {
                if (std.mem.indexOf(u8, out.stderr, s) != null) return Result.pass("snix", c.ident);
            }
        }
        const detail = try std.fmt.allocPrint(arena, "expected error kind {s} (rc 1 & a matching phrase); rc={d}\n{s}", .{ kind, out.rc, std.mem.trim(u8, out.stderr, " \n\r\t") });
        return Result.fail("snix", c.ident, detail);
    }

    // --- value golden ---
    const expected = try fsx.readFile(arena, io, exp);
    var norm: []const u8 = out.stdout;
    if (c.work_dir) |wd| norm = try replaceAll(arena, norm, tmp, wd);
    for (c.env_vars) |kv| {
        if (std.mem.eql(u8, kv[0], "HOME")) norm = try replaceAll(arena, norm, ctx.home, kv[1]);
    }
    norm = try replaceAll(arena, norm, "/__corepkgs__/fetchurl.nix", "/fetchurl.nix");
    if (out.rc != 0) {
        const detail = try std.fmt.allocPrint(arena, "eval failed:\n{s}", .{std.mem.trim(u8, out.stderr, " \n\r\t")});
        return Result.fail("snix", c.ident, detail);
    }
    if (std.mem.eql(u8, std.mem.trim(u8, norm, " \n\r\t"), std.mem.trim(u8, expected, " \n\r\t")))
        return Result.pass("snix", c.ident);
    const detail = try std.fmt.allocPrint(arena, "  expected: {s}\n  actual:   {s}", .{ std.mem.trim(u8, expected, " \n\r\t"), std.mem.trim(u8, norm, " \n\r\t") });
    return Result.fail("snix", c.ident, detail);
}

fn replaceAll(arena: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (needle.len == 0 or std.mem.indexOf(u8, haystack, needle) == null) return haystack;
    const size = std.mem.replacementSize(u8, haystack, needle, replacement);
    const buf = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, haystack, needle, replacement, buf);
    return buf;
}
