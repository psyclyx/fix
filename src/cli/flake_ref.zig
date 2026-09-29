//! Flake references on the command line, resolved as Nix's
//! `parseFlakeRefWithFragment` does with the working directory as base: a
//! path names the flake around it (searching up for `flake.nix`), and inside
//! a git repository it names that repository (`git+file:`, with `dir` for a
//! flake below the repository's root), so that `self` is the repository's
//! tracked files with its `rev`, as in Nix.

const std = @import("std");
const url = @import("fetchers").url;

/// `flake_ref` (without its `#fragment`) as a reference `builtins.getFlake`
/// takes, owned by `allocator`. References that aren't paths pass through,
/// and so does a path Nix would reject: `getFlake` reports that.
pub fn resolve(allocator: std.mem.Allocator, io: std.Io, base: ?[]const u8, flake_ref: []const u8) ![]u8 {
    if (flake_ref.len == 0 or (flake_ref[0] != '/' and flake_ref[0] != '.')) return allocator.dupe(u8, flake_ref);
    const base_dir = base orelse return allocator.dupe(u8, flake_ref);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const query_start = std.mem.indexOfScalar(u8, flake_ref, '?');
    const query_text = if (query_start) |i| flake_ref[i..] else "";
    var path: []const u8 = try std.fs.path.resolve(arena, &.{ base_dir, flake_ref[0 .. query_start orelse flake_ref.len] });
    const plain = try std.mem.concat(allocator, u8, &.{ path, query_text });
    errdefer allocator.free(plain);

    if (!isDirectory(io, path)) {
        // Nix lets `/foo/bar/flake.nix` mean `/foo/bar`.
        if (!std.mem.eql(u8, std.fs.path.basename(path), "flake.nix")) return plain;
        path = std.fs.path.dirname(path) orelse return plain;
    }
    if (!try exists(arena, io, path, "flake.nix")) {
        var dir = path;
        while (true) {
            const parent = std.fs.path.dirname(dir) orelse return plain;
            if (try exists(arena, io, dir, "flake.nix")) break;
            if (try exists(arena, io, dir, ".git")) return plain;
            dir = parent;
        }
        path = dir;
    }

    var root = path;
    var subdir: []const u8 = "";
    while (std.fs.path.dirname(root)) |parent| {
        if (try exists(arena, io, root, ".git")) {
            var query = if (query_start) |i| try url.decodeQuery(arena, flake_ref[i + 1 ..], true) else url.Query{};
            if (subdir.len != 0) try query.put(arena, "dir", subdir);
            if (try exists(arena, io, root, ".git/shallow")) try query.put(arena, "shallow", "1");
            const parsed: url.ParsedUrl = .{
                .scheme = "git+file",
                .authority = .{},
                .path = try url.pathToUrlPath(arena, root),
                .query = query,
            };
            allocator.free(plain);
            return allocator.dupe(u8, try parsed.toString(arena));
        }
        const name = std.fs.path.basename(root);
        subdir = if (subdir.len == 0) name else try std.mem.concat(arena, u8, &.{ name, "/", subdir });
        root = parent;
    }
    allocator.free(plain);
    return std.mem.concat(allocator, u8, &.{ path, query_text });
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn exists(arena: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(arena, &.{ dir, name });
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "a path in a git repository is the repository, with dir for a subdirectory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/.git");
    try tmp.dir.createDirPath(io, "repo/sub/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/flake.nix", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/sub/flake.nix", .data = "{}" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "./repo", "git+file://{s}/repo" },
        .{ "./repo/flake.nix", "git+file://{s}/repo" },
        .{ "./repo/sub", "git+file://{s}/repo?dir=sub" },
        // Nix searches up for the flake.nix.
        .{ "./repo/sub/deeper", "git+file://{s}/repo?dir=sub" },
        // Not a flake: `getFlake` says so.
        .{ "./missing", "{s}/missing" },
        .{ "./missing?x=1", "{s}/missing?x=1" },
    };
    inline for (cases) |case| {
        const got = try resolve(std.testing.allocator, io, base, case[0]);
        defer std.testing.allocator.free(got);
        const want = try std.fmt.allocPrint(std.testing.allocator, case[1], .{base});
        defer std.testing.allocator.free(want);
        try std.testing.expectEqualStrings(want, got);
    }

    const passthrough = try resolve(std.testing.allocator, io, base, "github:o/r");
    defer std.testing.allocator.free(passthrough);
    try std.testing.expectEqualStrings("github:o/r", passthrough);
}
