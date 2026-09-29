//! Flake references as Nix parses and prints them (`libflake/flakeref.cc`
//! and the input schemes of `libfetchers`): `builtins.parseFlakeRef`,
//! `builtins.flakeRefToString`, and every flake input URL. A reference is a
//! flake id (`nixpkgs/branch`), a URL (`github:owner/repo`,
//! `git+https://…?ref=x`) or an absolute path; each input scheme decides
//! which URLs are its own, which attributes they turn into, which
//! attributes it allows, and how it prints them again.
//!
//! All allocations go to the caller's allocator, meant to be an arena.

const std = @import("std");
const url_mod = @import("url.zig");
const git_transport = @import("git_transport.zig");

const ParsedUrl = url_mod.ParsedUrl;

pub const Value = union(enum) {
    string: []const u8,
    int: u64,
    boolean: bool,
};

/// Input attributes, sorted by name (Nix's `fetchers::Attrs`).
pub const Attrs = struct {
    list: std.ArrayListUnmanaged(Attr) = .empty,

    pub const Attr = struct { name: []const u8, value: Value };

    pub fn get(self: Attrs, name: []const u8) ?Value {
        const index = self.find(name) orelse return null;
        return self.list.items[index].value;
    }

    /// Add or replace.
    pub fn put(self: *Attrs, allocator: std.mem.Allocator, name: []const u8, value: Value) !void {
        if (self.find(name)) |index| {
            self.list.items[index].value = value;
            return;
        }
        var index: usize = 0;
        while (index < self.list.items.len and std.mem.lessThan(u8, self.list.items[index].name, name)) index += 1;
        try self.list.insert(allocator, index, .{ .name = name, .value = value });
    }

    pub fn remove(self: *Attrs, name: []const u8) void {
        const index = self.find(name) orelse return;
        _ = self.list.orderedRemove(index);
    }

    pub fn clone(self: Attrs, allocator: std.mem.Allocator) !Attrs {
        return .{ .list = try self.list.clone(allocator) };
    }

    fn find(self: Attrs, name: []const u8) ?usize {
        for (self.list.items, 0..) |attr, index| {
            if (std.mem.eql(u8, attr.name, name)) return index;
        }
        return null;
    }
};

pub const Error = error{InvalidFlakeRef} || std.mem.Allocator.Error;

/// The message of the last `error.InvalidFlakeRef`.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

const Ctx = struct {
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    /// Nix's `preserveRelativePaths`: a flake input may be a path relative
    /// to the flake it's declared in.
    preserve_relative: bool = false,

    fn fail(ctx: Ctx, comptime fmt: []const u8, args: anytype) Error {
        ctx.diagnostic.message = try std.fmt.allocPrint(ctx.arena, fmt, args);
        return error.InvalidFlakeRef;
    }

    fn string(ctx: Ctx, attrs: Attrs, name: []const u8) Error!?[]const u8 {
        const value = attrs.get(name) orelse return null;
        return switch (value) {
            .string => |s| s,
            else => ctx.fail("input attribute '{s}' is not a string", .{name}),
        };
    }

    fn requiredString(ctx: Ctx, attrs: Attrs, name: []const u8) Error![]const u8 {
        return (try ctx.string(attrs, name)) orelse ctx.fail("input attribute '{s}' is missing", .{name});
    }

    fn int(ctx: Ctx, attrs: Attrs, name: []const u8) Error!?u64 {
        const value = attrs.get(name) orelse return null;
        return switch (value) {
            .int => |n| n,
            else => ctx.fail("input attribute '{s}' is not an integer", .{name}),
        };
    }

    fn boolean(ctx: Ctx, attrs: Attrs, name: []const u8) Error!?bool {
        const value = attrs.get(name) orelse return null;
        return switch (value) {
            .boolean => |b| b,
            else => ctx.fail("input attribute '{s}' is not a Boolean", .{name}),
        };
    }

    fn badUrl(ctx: Ctx, text: []const u8) Error {
        return ctx.fail("'{s}' is not a valid URL", .{text});
    }
};

/// Nix's `parseFlakeRef(url).toAttrs()` for `builtins.parseFlakeRef`: no
/// base directory, so a path must be absolute, and no fragment.
pub fn parse(arena: std.mem.Allocator, diagnostic: *Diagnostic, text: []const u8) Error!Attrs {
    const ctx: Ctx = .{ .arena = arena, .diagnostic = diagnostic };
    const parsed = try parseWithFragment(ctx, text);
    if (parsed.fragment.len != 0) return ctx.fail("unexpected fragment '{s}' in flake reference '{s}'", .{ parsed.fragment, text });
    return parsed.attrs;
}

/// A flake input's reference (Nix's `parseFlakeRef` with
/// `preserveRelativePaths`): like `parse`, but a path may be relative to the
/// flake that declares the input.
pub fn parseInput(arena: std.mem.Allocator, diagnostic: *Diagnostic, text: []const u8) Error!Attrs {
    const ctx: Ctx = .{ .arena = arena, .diagnostic = diagnostic, .preserve_relative = true };
    const parsed = try parseWithFragment(ctx, text);
    if (parsed.fragment.len != 0) return ctx.fail("unexpected fragment '{s}' in flake reference '{s}'", .{ parsed.fragment, text });
    return parsed.attrs;
}

/// Nix's `FlakeRef::fromAttrs(attrs).to_string()` for
/// `builtins.flakeRefToString`.
pub fn render(arena: std.mem.Allocator, diagnostic: *Diagnostic, attrs: Attrs) Error![]const u8 {
    const ctx: Ctx = .{ .arena = arena, .diagnostic = diagnostic };
    const dir = try ctx.string(attrs, "dir");
    var input = try attrs.clone(arena);
    input.remove("dir");
    input = try fromAttrs(ctx, input);
    var url = try toUrl(ctx, input);
    if (dir) |d| if (d.len != 0) try url.query.add(arena, "dir", d);
    return url.toString(arena);
}

const WithFragment = struct { attrs: Attrs, fragment: []const u8 };

fn parseWithFragment(ctx: Ctx, text: []const u8) Error!WithFragment {
    if (try parseFlakeId(ctx, text)) |parsed| return parsed;
    if (url_mod.parse(ctx.arena, text, true)) |parsed| {
        return fromParsedUrl(ctx, parsed);
    } else |err| switch (err) {
        // Not a URL: try it as a path.
        error.BadUrl => {},
        error.OutOfMemory => return error.OutOfMemory,
    }
    return parsePath(ctx, text);
}

/// `id[/ref-or-rev][#fragment]`: `flake:id/…` without the scheme.
fn parseFlakeId(ctx: Ctx, text: []const u8) Error!?WithFragment {
    const hash = std.mem.indexOfScalar(u8, text, '#');
    const main = if (hash) |h| text[0..h] else text;
    const fragment = if (hash) |h| text[h + 1 ..] else "";
    const slash = std.mem.indexOfScalar(u8, main, '/');
    if (!isFlakeId(main[0 .. slash orelse main.len])) return null;
    if (slash) |s| if (!isRefOrRev(main[s + 1 ..])) return null;
    if (!isFragment(fragment)) return null;

    var path: std.ArrayListUnmanaged([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, main, '/');
    while (split.next()) |segment| try path.append(ctx.arena, segment);
    const attrs = try fromUrl(ctx, .{ .scheme = "flake", .path = path.items });
    return .{ .attrs = attrs, .fragment = url_mod.percentDecode(ctx.arena, fragment) catch return ctx.badUrl(text) };
}

/// `[a-zA-Z][a-zA-Z0-9_-]*`
fn isFlakeId(text: []const u8) bool {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

/// A ref or rev, or a ref and a rev: Nix's `refAndOrRevRegex`, which
/// comes down to `[a-zA-Z0-9@][a-zA-Z0-9_./@+-]*` (a ref may contain `/`).
fn isRefOrRev(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.ascii.isAlphanumeric(text[0]) and text[0] != '@') return false;
    for (text[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_./@+-", c) == null) return false;
    }
    return true;
}

/// Nix's `refRegex`: `[a-zA-Z0-9@][a-zA-Z0-9_./@+-]*`.
fn matchesRefRegex(text: []const u8) bool {
    return isRefOrRev(text);
}

/// Nix's `revRegex`: 40 hex digits.
fn isRev(text: []const u8) bool {
    if (text.len != 40) return false;
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// Nix's `fragmentRegex`: pchars, `/`, `?`, space, `"` and `^`.
fn isFragment(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '%') {
            if (i + 2 >= text.len or !std.ascii.isHex(text[i + 1]) or !std.ascii.isHex(text[i + 2])) return false;
            i += 2;
            continue;
        }
        if (std.ascii.isAlphanumeric(c)) continue;
        if (std.mem.indexOfScalar(u8, "-._~!$&'\"()*+,;=:@/? ^", c) == null) return false;
    }
    return true;
}

/// A reference that is neither a flake id nor a URL: an absolute path,
/// with an optional query and fragment.
fn parsePath(ctx: Ctx, text: []const u8) Error!WithFragment {
    const path_end = std.mem.indexOfAny(u8, text, "?#") orelse text.len;
    const path = text[0..path_end];
    var rest = text[path_end..];
    var query_text: []const u8 = "";
    if (std.mem.startsWith(u8, rest, "?")) {
        const end = std.mem.indexOfScalar(u8, rest, '#') orelse rest.len;
        query_text = rest[1..end];
        rest = rest[end..];
    }
    const fragment_text = if (std.mem.startsWith(u8, rest, "#")) rest[1..] else "";
    const query = url_mod.decodeQuery(ctx.arena, query_text, true) catch |err| switch (err) {
        error.BadUrl => return ctx.fail("invalid URI query '{s}'", .{query_text}),
        else => |e| return e,
    };
    const fragment = url_mod.percentDecode(ctx.arena, fragment_text) catch return ctx.fail("invalid URI parameter '{s}'", .{fragment_text});
    const absolute = std.fs.path.isAbsolute(path);
    if (!absolute and !ctx.preserve_relative) return ctx.fail("flake reference '{s}' is not an absolute path", .{text});
    return fromParsedUrl(ctx, .{
        .scheme = "path",
        .authority = if (absolute) .{} else null,
        .path = try url_mod.pathToUrlPath(ctx.arena, path),
        .query = query,
        .fragment = fragment,
    });
}

/// `?dir=` names the flake's subdirectory, not part of the input.
fn fromParsedUrl(ctx: Ctx, parsed_url: ParsedUrl) Error!WithFragment {
    var parsed = parsed_url;
    parsed.query = try parsed.query.clone(ctx.arena);
    const dir = parsed.query.get("dir") orelse "";
    parsed.query.remove("dir");
    const fragment = parsed.fragment;
    parsed.fragment = "";
    var attrs = try fromUrl(ctx, parsed);
    if (dir.len != 0) try attrs.put(ctx.arena, "dir", .{ .string = dir });
    return .{ .attrs = attrs, .fragment = fragment };
}

// ---------------------------------------------------------------------------
// Input schemes

const SchemeKind = enum { file, git, github, gitlab, hg, indirect, path, sourcehut, tarball };

/// In the order Nix tries them (its scheme map is sorted by name).
const scheme_order = [_]SchemeKind{ .file, .git, .github, .gitlab, .hg, .indirect, .path, .sourcehut, .tarball };

fn schemeName(kind: SchemeKind) []const u8 {
    return @tagName(kind);
}

fn schemeByName(name: []const u8) ?SchemeKind {
    return std.meta.stringToEnum(SchemeKind, name);
}

fn allowedAttrs(kind: SchemeKind) []const []const u8 {
    return switch (kind) {
        .github, .gitlab, .sourcehut => &.{ "owner", "repo", "ref", "rev", "narHash", "lastModified", "host", "treeHash" },
        .indirect => &.{ "id", "ref", "rev", "narHash" },
        .path => &.{ "path", "rev", "revCount", "lastModified", "narHash" },
        .git => &.{ "url", "ref", "rev", "shallow", "submodules", "lfs", "exportIgnore", "lastModified", "revCount", "narHash", "allRefs", "name", "dirtyRev", "dirtyShortRev", "verifyCommit", "keytype", "publicKey", "publicKeys" },
        .hg => &.{ "url", "ref", "rev", "revCount", "narHash", "name" },
        .file, .tarball => &.{ "url", "narHash", "name", "unpack", "rev", "revCount", "lastModified" },
    };
}

/// Nix's `Input::fromURL`, for a flake (`requireTree`).
fn fromUrl(ctx: Ctx, url: ParsedUrl) Error!Attrs {
    for (scheme_order) |kind| {
        if (try schemeFromUrl(ctx, kind, url)) |attrs| {
            try fixup(ctx, attrs);
            return attrs;
        }
    }
    const scheme = url_mod.Scheme.parse(url.scheme);
    const shown = try url.toString(ctx.arena);
    if (scheme.application) |application| {
        if (std.mem.eql(u8, application, "file") and std.mem.eql(u8, scheme.transport, "git"))
            return ctx.fail("input '{s}' is unsupported; did you mean 'git+file' instead of 'file+git'?", .{shown});
    }
    return ctx.fail("input '{s}' is unsupported", .{shown});
}

/// Nix's `Input::fromAttrs`: an unknown type is kept as it is, and can't be
/// printed.
fn fromAttrs(ctx: Ctx, attrs: Attrs) Error!Attrs {
    const type_name = (try ctx.string(attrs, "type")) orelse return ctx.fail("'type' attribute to specify input scheme is required but not provided", .{});
    const kind = schemeByName(type_name) orelse {
        try fixup(ctx, attrs);
        return attrs;
    };
    const allowed = allowedAttrs(kind);
    outer: for (attrs.list.items) |attr| {
        if (std.mem.eql(u8, attr.name, "type") or std.mem.eql(u8, attr.name, "__final")) continue;
        for (allowed) |name| if (std.mem.eql(u8, name, attr.name)) continue :outer;
        return ctx.fail("input attribute '{s}' not supported by scheme '{s}'", .{ attr.name, type_name });
    }
    const input = try schemeFromAttrs(ctx, kind, try attrs.clone(ctx.arena));
    try fixup(ctx, input);
    return input;
}

/// Nix's `fixupInput`: the common attributes have their types.
fn fixup(ctx: Ctx, attrs: Attrs) Error!void {
    _ = try ctx.requiredString(attrs, "type");
    _ = try ctx.string(attrs, "ref");
    _ = try ctx.int(attrs, "revCount");
    _ = try ctx.int(attrs, "lastModified");
}

fn schemeFromUrl(ctx: Ctx, kind: SchemeKind, url: ParsedUrl) Error!?Attrs {
    return switch (kind) {
        .file, .tarball => curlFromUrl(ctx, kind, url),
        .git => gitFromUrl(ctx, url),
        .github, .gitlab, .sourcehut => forgeFromUrl(ctx, kind, url),
        .hg => hgFromUrl(ctx, url),
        .indirect => indirectFromUrl(ctx, url),
        .path => pathFromUrl(ctx, url),
    };
}

fn schemeFromAttrs(ctx: Ctx, kind: SchemeKind, attrs: Attrs) Error!Attrs {
    var input = attrs;
    switch (kind) {
        .github, .gitlab, .sourcehut => {
            _ = try ctx.requiredString(input, "owner");
            _ = try ctx.requiredString(input, "repo");
            const ref = try ctx.string(input, "ref");
            const rev = try ctx.string(input, "rev");
            if (ref != null and rev != null)
                return ctx.fail("input contains both a commit hash ('{s}') and a branch/tag name ('{s}')", .{ rev.?, ref.? });
            if (rev) |r| _ = try gitRev(ctx, r);
            if (ref) |r| if (!git_transport.isLegalRefName(r)) return ctx.fail("input contains an invalid branch/tag name '{s}'", .{r});
            if (try ctx.string(input, "host")) |host| {
                for (host) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-')
                    return ctx.fail("input contains an invalid instance host '{s}'", .{host});
            }
        },
        .indirect => {
            const id = try ctx.requiredString(input, "id");
            if (!isFlakeId(id)) return ctx.fail("'{s}' is not a valid flake ID", .{id});
        },
        .path => _ = try ctx.requiredString(input, "path"),
        .git => {
            for ([_][]const u8{ "verifyCommit", "keytype", "publicKey", "publicKeys" }) |name| {
                if (input.get(name) != null) return ctx.fail("experimental Nix feature 'verified-fetches' is disabled; add '--extra-experimental-features verified-fetches' to enable it", .{});
            }
            if (try ctx.string(input, "ref")) |ref| if (!git_transport.isLegalRefName(ref))
                return ctx.fail("invalid Git branch/tag name '{s}'", .{ref});
            const url = try ctx.requiredString(input, "url");
            const fixed = url_mod.fixGitUrl(ctx.arena, url) catch |err| switch (err) {
                error.BadUrl => return ctx.badUrl(url),
                else => |e| return e,
            };
            try input.put(ctx.arena, "url", .{ .string = try fixed.toString(ctx.arena) });
            for ([_][]const u8{ "shallow", "submodules", "allRefs" }) |name| _ = try ctx.boolean(input, name);
        },
        .hg => {
            const url = try ctx.requiredString(input, "url");
            _ = url_mod.parse(ctx.arena, url, false) catch |err| switch (err) {
                error.BadUrl => return ctx.badUrl(url),
                else => |e| return e,
            };
            if (try ctx.string(input, "ref")) |ref| if (!matchesRefRegex(ref))
                return ctx.fail("invalid Mercurial branch/tag name '{s}'", .{ref});
        },
        .file, .tarball => {},
    }
    return input;
}

fn toUrl(ctx: Ctx, attrs: Attrs) Error!ParsedUrl {
    const type_name = try ctx.requiredString(attrs, "type");
    const kind = schemeByName(type_name) orelse return ctx.fail("cannot show unsupported input of type '{s}'", .{type_name});
    const a = ctx.arena;
    switch (kind) {
        .github, .gitlab, .sourcehut => {
            var path: std.ArrayListUnmanaged([]const u8) = .empty;
            try path.appendSlice(a, &.{ try ctx.requiredString(attrs, "owner"), try ctx.requiredString(attrs, "repo") });
            if (try ctx.string(attrs, "ref")) |ref| try path.append(a, ref);
            if (try ctx.string(attrs, "rev")) |rev| try path.append(a, try gitRev(ctx, rev));
            var url: ParsedUrl = .{ .scheme = schemeName(kind), .path = path.items };
            if (try ctx.string(attrs, "narHash")) |nar_hash| try url.query.put(a, "narHash", try sriNarHash(ctx, nar_hash));
            if (try ctx.string(attrs, "host")) |host| try url.query.put(a, "host", host);
            return url;
        },
        .indirect => {
            var path: std.ArrayListUnmanaged([]const u8) = .empty;
            try path.append(a, try ctx.requiredString(attrs, "id"));
            if (try ctx.string(attrs, "ref")) |ref| try path.append(a, ref);
            if (try ctx.string(attrs, "rev")) |rev| try path.append(a, try gitRev(ctx, rev));
            return .{ .scheme = "flake", .path = path.items };
        },
        .path => {
            var url: ParsedUrl = .{ .scheme = "path", .path = try url_mod.pathToUrlPath(a, try ctx.requiredString(attrs, "path")) };
            for (attrs.list.items) |attr| {
                if (std.mem.eql(u8, attr.name, "path") or std.mem.eql(u8, attr.name, "type") or std.mem.eql(u8, attr.name, "__final")) continue;
                try url.query.put(a, attr.name, switch (attr.value) {
                    .string => |s| s,
                    .int => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
                    .boolean => |b| if (b) "1" else "0",
                });
            }
            return url;
        },
        .git => {
            var url = try reparse(ctx, try ctx.requiredString(attrs, "url"));
            if (!std.mem.eql(u8, url.scheme, "git")) url.scheme = try std.fmt.allocPrint(a, "git+{s}", .{url.scheme});
            if (try ctx.string(attrs, "rev")) |rev| try url.query.put(a, "rev", try gitRev(ctx, rev));
            if (try ctx.string(attrs, "ref")) |ref| try url.query.put(a, "ref", ref);
            for ([_][]const u8{ "shallow", "lfs", "submodules", "exportIgnore", "verifyCommit" }) |name| {
                if ((try ctx.boolean(attrs, name)) orelse false) try url.query.put(a, name, "1");
            }
            return url;
        },
        .hg => {
            var url = try reparse(ctx, try ctx.requiredString(attrs, "url"));
            url.scheme = try std.fmt.allocPrint(a, "hg+{s}", .{url.scheme});
            if (try ctx.string(attrs, "rev")) |rev| try url.query.put(a, "rev", try gitRev(ctx, rev));
            if (try ctx.string(attrs, "ref")) |ref| try url.query.put(a, "ref", ref);
            return url;
        },
        .file, .tarball => {
            var url = try reparse(ctx, try ctx.requiredString(attrs, "url"));
            if (try ctx.string(attrs, "narHash")) |nar_hash| try url.query.put(a, "narHash", try sriNarHash(ctx, nar_hash));
            return url;
        },
    }
}

fn reparse(ctx: Ctx, text: []const u8) Error!ParsedUrl {
    var url = url_mod.parse(ctx.arena, text, false) catch |err| switch (err) {
        error.BadUrl => return ctx.badUrl(text),
        else => |e| return e,
    };
    url.query = try url.query.clone(ctx.arena);
    return url;
}

fn curlFromUrl(ctx: Ctx, kind: SchemeKind, url: ParsedUrl) Error!?Attrs {
    const scheme = url_mod.Scheme.parse(url.scheme);
    const transports = [_][]const u8{ "file", "http", "https" };
    const known = for (transports) |t| {
        if (std.mem.eql(u8, t, scheme.transport)) break true;
    } else false;
    if (!known) return null;
    // Without `file+`/`tarball+`, a flake is a tree, so the URL of one is a
    // tarball (whatever its extension, which only matters for a plain file).
    const mine = if (scheme.application) |application|
        std.mem.eql(u8, application, schemeName(kind))
    else
        kind == .tarball;
    if (!mine) return null;

    const a = ctx.arena;
    var attrs: Attrs = .{};
    var stripped = url;
    stripped.scheme = scheme.transport;
    stripped.query = try url.query.clone(a);
    if (url.query.get("narHash")) |v| try attrs.put(a, "narHash", .{ .string = v });
    if (url.query.get("rev")) |v| try attrs.put(a, "rev", .{ .string = v });
    for ([_][]const u8{ "revCount", "lastModified" }) |name| {
        if (url.query.get(name)) |v| if (parseDecimal(v)) |n| try attrs.put(a, name, .{ .int = n });
    }
    // The parameters Nix handles itself aren't sent to the server.
    for (allowedAttrs(kind)) |name| stripped.query.remove(name);
    try attrs.put(a, "type", .{ .string = schemeName(kind) });
    try attrs.put(a, "url", .{ .string = try stripped.toString(a) });
    return attrs;
}

/// Nix's `string2Int<uint64_t>`.
fn parseDecimal(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

fn gitFromUrl(ctx: Ctx, url: ParsedUrl) Error!?Attrs {
    const scheme = url_mod.Scheme.parse(url.scheme);
    const is_git = std.mem.eql(u8, url.scheme, "git") or (scheme.application != null and std.mem.eql(u8, scheme.application.?, "git"));
    if (!is_git) return null;
    const a = ctx.arena;
    var attrs: Attrs = .{};
    try attrs.put(a, "type", .{ .string = "git" });
    var stripped = url;
    stripped.query = .{};
    for (url.query.params.items) |param| {
        const string_params = [_][]const u8{ "rev", "ref", "keytype", "publicKey", "publicKeys" };
        const bool_params = [_][]const u8{ "shallow", "submodules", "lfs", "exportIgnore", "allRefs", "verifyCommit" };
        if (contains(&string_params, param.name)) {
            try attrs.put(a, param.name, .{ .string = param.value });
        } else if (contains(&bool_params, param.name)) {
            try attrs.put(a, param.name, .{ .boolean = std.mem.eql(u8, param.value, "1") });
        } else {
            try stripped.query.add(a, param.name, param.value);
        }
    }
    try attrs.put(a, "url", .{ .string = try stripped.toString(a) });
    return try schemeFromAttrs(ctx, .git, attrs);
}

fn forgeFromUrl(ctx: Ctx, kind: SchemeKind, url: ParsedUrl) Error!?Attrs {
    if (!std.mem.eql(u8, url.scheme, schemeName(kind))) return null;
    const a = ctx.arena;
    const shown = try url.toString(a);
    // Empty segments are ignored, as Nix always has.
    const path = try url.pathSegments(a);
    var attrs: Attrs = .{};
    if (path.len == 3) {
        try attrs.put(a, if (isRev(path[2])) "rev" else "ref", .{ .string = path[2] });
    } else if (path.len > 3) {
        try attrs.put(a, "ref", .{ .string = try std.mem.join(a, "/", path[2..]) });
    } else if (path.len < 2) {
        return ctx.fail("URL '{s}' is invalid", .{shown});
    }
    for (url.query.params.items) |param| {
        if (std.mem.eql(u8, param.name, "rev") or std.mem.eql(u8, param.name, "ref")) {
            if (attrs.get(param.name) != null) return ctx.fail("URL '{s}' contains multiple {s}", .{ shown, if (param.name[2] == 'v') "commit hashes" else "branch/tag names" });
            try attrs.put(a, param.name, .{ .string = param.value });
        } else if (std.mem.eql(u8, param.name, "host") or std.mem.eql(u8, param.name, "narHash")) {
            try attrs.put(a, param.name, .{ .string = param.value });
        } else {
            return ctx.fail("URL '{s}' contains unknown parameter '{s}'", .{ shown, param.name });
        }
    }
    try attrs.put(a, "type", .{ .string = schemeName(kind) });
    try attrs.put(a, "owner", .{ .string = path[0] });
    try attrs.put(a, "repo", .{ .string = path[1] });
    return try schemeFromAttrs(ctx, kind, attrs);
}

fn hgFromUrl(ctx: Ctx, url: ParsedUrl) Error!?Attrs {
    const schemes = [_][]const u8{ "hg+http", "hg+https", "hg+ssh", "hg+file" };
    if (!contains(&schemes, url.scheme)) return null;
    const a = ctx.arena;
    var attrs: Attrs = .{};
    try attrs.put(a, "type", .{ .string = "hg" });
    var stripped = url;
    stripped.scheme = url.scheme[3..];
    stripped.query = .{};
    for (url.query.params.items) |param| {
        if (std.mem.eql(u8, param.name, "rev") or std.mem.eql(u8, param.name, "ref")) {
            try attrs.put(a, param.name, .{ .string = param.value });
        } else try stripped.query.add(a, param.name, param.value);
    }
    try attrs.put(a, "url", .{ .string = try stripped.toString(a) });
    return try schemeFromAttrs(ctx, .hg, attrs);
}

fn indirectFromUrl(ctx: Ctx, url: ParsedUrl) Error!?Attrs {
    if (!std.mem.eql(u8, url.scheme, "flake")) return null;
    const a = ctx.arena;
    const shown = try url.toString(a);
    const path = try url.pathSegments(a);
    var ref: ?[]const u8 = null;
    var rev: ?[]const u8 = null;
    switch (path.len) {
        1 => {},
        2 => if (isRev(path[1])) {
            rev = try std.ascii.allocLowerString(a, path[1]);
        } else if (git_transport.isLegalRefName(path[1])) {
            ref = path[1];
        } else return ctx.fail("in flake URL '{s}', '{s}' is not a commit hash or branch/tag name", .{ shown, path[1] }),
        3 => {
            if (!git_transport.isLegalRefName(path[1])) return ctx.fail("in flake URL '{s}', '{s}' is not a branch/tag name", .{ shown, path[1] });
            ref = path[1];
            if (!isRev(path[2])) return ctx.fail("in flake URL '{s}', '{s}' is not a commit hash", .{ shown, path[2] });
            rev = try std.ascii.allocLowerString(a, path[2]);
        },
        else => return ctx.fail("GitHub URL '{s}' is invalid", .{shown}),
    }
    if (!isFlakeId(path[0])) return ctx.fail("'{s}' is not a valid flake ID", .{path[0]});
    var attrs: Attrs = .{};
    try attrs.put(a, "type", .{ .string = "indirect" });
    try attrs.put(a, "id", .{ .string = path[0] });
    if (rev) |r| try attrs.put(a, "rev", .{ .string = r });
    if (ref) |r| try attrs.put(a, "ref", .{ .string = r });
    return attrs;
}

fn pathFromUrl(ctx: Ctx, url: ParsedUrl) Error!?Attrs {
    if (!std.mem.eql(u8, url.scheme, "path")) return null;
    const a = ctx.arena;
    const shown = try url.toString(a);
    if (url.authority) |authority| if (authority.host.len != 0)
        return ctx.fail("path URL '{s}' should not have an authority ('{s}')", .{ shown, authority.host });
    var attrs: Attrs = .{};
    try attrs.put(a, "type", .{ .string = "path" });
    const path = url_mod.urlPathToPath(a, url.path) catch return ctx.fail("path URL '{s}' is not a valid path", .{shown});
    try attrs.put(a, "path", .{ .string = path });
    for (url.query.params.items) |param| {
        if (std.mem.eql(u8, param.name, "rev") or std.mem.eql(u8, param.name, "narHash")) {
            try attrs.put(a, param.name, .{ .string = param.value });
        } else if (std.mem.eql(u8, param.name, "revCount") or std.mem.eql(u8, param.name, "lastModified")) {
            const n = parseDecimal(param.value) orelse return ctx.fail("path URL '{s}' has invalid parameter '{s}'", .{ shown, param.name });
            try attrs.put(a, param.name, .{ .int = n });
        } else {
            return ctx.fail("path URL '{s}' has unsupported parameter '{s}'", .{ shown, param.name });
        }
    }
    return attrs;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

/// Nix's `Input::getRev` printed with `gitRev`: 40 hex digits, lowercase
/// (also accepted with a `sha1:` prefix).
fn gitRev(ctx: Ctx, rev: []const u8) Error![]const u8 {
    const hex = if (std.mem.startsWith(u8, rev, "sha1:")) rev["sha1:".len..] else rev;
    if (!isRev(hex)) return ctx.fail("invalid Git revision '{s}'", .{rev});
    return std.ascii.allocLowerString(ctx.arena, hex);
}

/// Nix's `Input::getNarHash` printed as SRI: a SHA-256 SRI hash (or the
/// empty string, the all-zero hash), canonically padded.
fn sriNarHash(ctx: Ctx, nar_hash: []const u8) Error![]const u8 {
    var digest: [32]u8 = @splat(0);
    if (nar_hash.len != 0) {
        const dash = std.mem.indexOfScalar(u8, nar_hash, '-') orelse return ctx.fail("hash '{s}' is not SRI", .{nar_hash});
        if (!std.mem.eql(u8, nar_hash[0..dash], "sha256")) return ctx.fail("narHash must use SHA-256", .{});
        const encoded = std.mem.trimEnd(u8, nar_hash[dash + 1 ..], "=");
        const decoder = std.base64.standard_no_pad.Decoder;
        const size = decoder.calcSizeForSlice(encoded) catch return ctx.fail("invalid SRI hash '{s}'", .{nar_hash});
        if (size != digest.len) return ctx.fail("invalid SRI hash '{s}'", .{nar_hash});
        decoder.decode(&digest, encoded) catch return ctx.fail("invalid SRI hash '{s}'", .{nar_hash});
    }
    var out: [std.base64.standard.Encoder.calcSize(32)]u8 = undefined;
    return std.fmt.allocPrint(ctx.arena, "sha256-{s}", .{std.base64.standard.Encoder.encode(&out, &digest)});
}

// ---------------------------------------------------------------------------
// Tests: the cases of Nix's `libflake-tests/flakeref.cc`.

fn expectCanonical(text: []const u8, expected: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    const attrs = parse(arena.allocator(), &diagnostic, text) catch |err| {
        if (expected == null and err == error.InvalidFlakeRef) return;
        std.debug.print("parsing '{s}': {s}\n", .{ text, diagnostic.message });
        return err;
    };
    const rendered = render(arena.allocator(), &diagnostic, attrs) catch |err| {
        if (expected == null and err == error.InvalidFlakeRef) return;
        std.debug.print("printing '{s}': {s}\n", .{ text, diagnostic.message });
        return err;
    };
    if (expected) |want| {
        try std.testing.expectEqualStrings(want, rendered);
    } else {
        std.debug.print("'{s}' should not parse, but gives '{s}'\n", .{ text, rendered });
        return error.TestUnexpectedResult;
    }
}

fn expectAttrs(text: []const u8, expected: []const Attrs.Attr) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    const attrs = parse(arena.allocator(), &diagnostic, text) catch |err| {
        std.debug.print("parsing '{s}': {s}\n", .{ text, diagnostic.message });
        return err;
    };
    try std.testing.expectEqual(expected.len, attrs.list.items.len);
    for (expected) |want| {
        const got = attrs.get(want.name) orelse return error.TestExpectedAttr;
        try std.testing.expectEqualDeep(want.value, got);
    }
}

test "flake references print canonically, as in Nix's flakeref tests" {
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "/foo/bar", "path:/foo/bar" },
        .{ "/foo/bar?revCount=123&rev=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "path:/foo/bar?rev=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&revCount=123" },
        .{ "/foo/bar?xyzzy=123", null },
        .{ "/foo/bar#bla", null },
        .{ "/foo bar/baz?dir=bla space", "path:/foo%20bar/baz?dir=bla%20space" },
        .{ "github:foo/bar/branch%23", "github:foo/bar/branch%23" },
        .{ "github:foo/bar?ref=branch%23", "github:foo/bar/branch%23" },
        .{ "flake:nixpkgs", "flake:nixpkgs" },
        .{ "flake:nixpkgs/branch", "flake:nixpkgs/branch" },
        .{ "nixpkgs/branch", "flake:nixpkgs/branch" },
        .{ "nixpkgs/branch/2aae6c35c94fcfb415dbe95f408b9ce91ee846ed", "flake:nixpkgs/branch/2aae6c35c94fcfb415dbe95f408b9ce91ee846ed" },
        .{ "nixpkgs/branch////", "flake:nixpkgs/branch" },
        .{ "nixpkgs/branch///2aae6c35c94fcfb415dbe95f408b9ce91ee846ed///", "flake:nixpkgs/branch/2aae6c35c94fcfb415dbe95f408b9ce91ee846ed" },
        .{ "git://somewhere/repo?ref=branch", "git://somewhere/repo?ref=branch" },
        .{ "git+https://somewhere.aaaaaaa/repo?ref=branch", "git+https://somewhere.aaaaaaa/repo?ref=branch" },
        .{ "flake:/nixpkgs///branch////", "flake:nixpkgs/branch" },
        .{ "github://////owner%42/////repo%41///branch%43////", "github:ownerB/repoA/branchC" },
        .{ "gitlab:/owner%252Fsubgroup/////repo%41///branch%43////", "gitlab:owner%252Fsubgroup/repoA/branchC" },
        .{ "github:nixos/nix/0000000000000000000000000000000000000000", "github:nixos/nix/0000000000000000000000000000000000000000" },
        .{ "github:nixos/nix?rev=0000000000000000000000000000000000000000", "github:nixos/nix/0000000000000000000000000000000000000000" },
        .{ "github:nixos/nix//master///something/", "github:nixos/nix/master%2Fsomething" },
        .{ "http://localhost:8181/test/+3d.tar.gz", "http://localhost:8181/test/%2B3d.tar.gz" },
        .{ "github:foo/bar?xyzzy=1", null },
        .{ "github:nixos/nixpkgs/nixpkgs.git?ref=aead170c1a49253ebfa5027010dfd89a77b73ca4", null },
        .{ "git+https://#", "git+https://" },
        .{ "github:a/b#frag", null },
        .{ "nixpkgs", "flake:nixpkgs" },
        .{ "tarball+https://example.org/x", "https://example.org/x" },
        .{ "https://example.org/x.tar.gz?narHash=sha256-JwtCngkoi9pb0pqIdNgukY8GbG5pUDZvrGAHZqjFOw4", "https://example.org/x.tar.gz?narHash=sha256-JwtCngkoi9pb0pqIdNgukY8GbG5pUDZvrGAHZqjFOw4%3D" },
        .{ "hg+https://example.org/repo?ref=default", "hg+https://example.org/repo?ref=default" },
        .{ "relative/path", "flake:relative/path" },
        .{ "./relative", null },
        .{ "path:foo", "path:foo" },
        .{ "path:/foo/bar/", "path:/foo/bar//" },
        .{ "file:///foo/bar", "file:///foo/bar" },
        .{ "git+ssh://git@github.com/NixOS/nix?ref=master", "git+ssh://git@github.com/NixOS/nix?ref=master" },
        .{ "sourcehut:~user/repo", "sourcehut:~user/repo" },
        .{ "git+file:///repo?submodules=1&shallow=0", "git+file:///repo?submodules=1" },
    };
    for (cases) |case| try expectCanonical(case[0], case[1]);
}

test "parseFlakeRef attributes, as in Nix's flakeref tests" {
    try expectAttrs("flake:nixpkgs", &.{
        .{ .name = "id", .value = .{ .string = "nixpkgs" } },
        .{ .name = "type", .value = .{ .string = "indirect" } },
    });
    try expectAttrs("nixpkgs/branch/2aae6c35c94fcfb415dbe95f408b9ce91ee846ed", &.{
        .{ .name = "id", .value = .{ .string = "nixpkgs" } },
        .{ .name = "type", .value = .{ .string = "indirect" } },
        .{ .name = "ref", .value = .{ .string = "branch" } },
        .{ .name = "rev", .value = .{ .string = "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed" } },
    });
    try expectAttrs("git+https://somewhere.aaaaaaa/repo?ref=branch", &.{
        .{ .name = "type", .value = .{ .string = "git" } },
        .{ .name = "ref", .value = .{ .string = "branch" } },
        .{ .name = "url", .value = .{ .string = "https://somewhere.aaaaaaa/repo" } },
    });
    try expectAttrs("github://////owner%42/////repo%41///branch%43////", &.{
        .{ .name = "type", .value = .{ .string = "github" } },
        .{ .name = "owner", .value = .{ .string = "ownerB" } },
        .{ .name = "repo", .value = .{ .string = "repoA" } },
        .{ .name = "ref", .value = .{ .string = "branchC" } },
    });
    try expectAttrs("gitlab:/owner%252Fsubgroup/////repo%41///branch%43////", &.{
        .{ .name = "type", .value = .{ .string = "gitlab" } },
        .{ .name = "owner", .value = .{ .string = "owner%2Fsubgroup" } },
        .{ .name = "repo", .value = .{ .string = "repoA" } },
        .{ .name = "ref", .value = .{ .string = "branchC" } },
    });
    try expectAttrs("github:nixos/nix//master///something/", &.{
        .{ .name = "type", .value = .{ .string = "github" } },
        .{ .name = "owner", .value = .{ .string = "nixos" } },
        .{ .name = "repo", .value = .{ .string = "nix" } },
        .{ .name = "ref", .value = .{ .string = "master/something" } },
    });
    try expectAttrs("/foo bar/baz?dir=bla space", &.{
        .{ .name = "type", .value = .{ .string = "path" } },
        .{ .name = "path", .value = .{ .string = "/foo bar/baz" } },
        .{ .name = "dir", .value = .{ .string = "bla space" } },
    });
    // Integer parameters are integers, Boolean ones Booleans.
    try expectAttrs("/foo?revCount=3&lastModified=4", &.{
        .{ .name = "type", .value = .{ .string = "path" } },
        .{ .name = "path", .value = .{ .string = "/foo" } },
        .{ .name = "revCount", .value = .{ .int = 3 } },
        .{ .name = "lastModified", .value = .{ .int = 4 } },
    });
    try expectAttrs("git+file:///repo?submodules=1&shallow=0", &.{
        .{ .name = "type", .value = .{ .string = "git" } },
        .{ .name = "url", .value = .{ .string = "file:///repo" } },
        .{ .name = "submodules", .value = .{ .boolean = true } },
        .{ .name = "shallow", .value = .{ .boolean = false } },
    });
}

test "flakeRefToString checks attributes against their scheme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostic: Diagnostic = .{};

    var indirect: Attrs = .{};
    try indirect.put(a, "type", .{ .string = "indirect" });
    try indirect.put(a, "id", .{ .string = "a" });
    try std.testing.expectEqualStrings("flake:a", try render(a, &diagnostic, indirect));

    var path: Attrs = .{};
    try path.put(a, "type", .{ .string = "path" });
    try path.put(a, "path", .{ .string = "/x y" });
    try path.put(a, "dir", .{ .string = "sub" });
    try std.testing.expectEqualStrings("path:/x%20y?dir=sub", try render(a, &diagnostic, path));

    try path.put(a, "owner", .{ .string = "o" });
    try std.testing.expectError(error.InvalidFlakeRef, render(a, &diagnostic, path));

    var unknown: Attrs = .{};
    try unknown.put(a, "type", .{ .string = "nope" });
    try std.testing.expectError(error.InvalidFlakeRef, render(a, &diagnostic, unknown));
}

test "a flake input may be a path relative to its flake" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    for ([_][2][]const u8{ .{ "./sub", "./sub" }, .{ "../sub", "../sub" }, .{ "path:./sub", "./sub" }, .{ "/abs", "/abs" } }) |case| {
        const attrs = try parseInput(arena.allocator(), &diagnostic, case[0]);
        try std.testing.expectEqualStrings("path", attrs.get("type").?.string);
        try std.testing.expectEqualStrings(case[1], attrs.get("path").?.string);
    }
    try std.testing.expectError(error.InvalidFlakeRef, parse(arena.allocator(), &diagnostic, "./sub"));
}
