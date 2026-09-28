//! Small filesystem helpers over the 0.16 io-threaded `std.Io.Dir` API, plus
//! the unprivileged special-file creation the snix fixtures need (fifo/socket
//! via mknod; device nodes are handled at run time via a userns bind-mount).

const std = @import("std");
const builtin = @import("builtin");
const Dir = std.Io.Dir;

pub fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
}

/// Normalize `path` to absolute, joining a relative one onto `cwd`. Does not
/// resolve symlinks — callers verify existence separately.
pub fn absPath(arena: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return arena.dupe(u8, path);
    return std.fs.path.join(arena, &.{ cwd, path });
}

pub fn exists(io: std.Io, path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn mkpath(io: std.Io, path: []const u8) !void {
    try Dir.cwd().createDirPath(io, path);
}

pub fn symlink(io: std.Io, target: []const u8, link_path: []const u8) !void {
    try Dir.cwd().symLink(io, target, link_path, .{});
}

pub fn removeTree(io: std.Io, path: []const u8) void {
    Dir.cwd().deleteTree(io, path) catch {};
}

var temp_counter: std.atomic.Value(u64) = .init(0);

/// A fresh temp dir under /tmp; caller frees the path and should removeTree it.
/// Uniqueness comes from pid + a process-global counter (no RNG needed).
pub fn makeTempDir(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const n = temp_counter.fetchAdd(1, .monotonic);
    const path = try std.fmt.allocPrint(gpa, "/tmp/fixlang-{d}-{d}", .{ std.posix.system.getpid(), n });
    errdefer gpa.free(path);
    try Dir.cwd().createDirPath(io, path);
    var canonical_buf: [std.fs.max_path_bytes]u8 = undefined;
    const canonical_len = try Dir.realPathFileAbsolute(io, path, &canonical_buf);
    const canonical = try gpa.dupe(u8, canonical_buf[0..canonical_len]);
    gpa.free(path);
    return canonical;
}

pub fn copyFile(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) !void {
    const data = try readFile(gpa, io, src);
    defer gpa.free(data);
    try writeFile(io, dst, data);
}

/// Recursively copy the directory tree at `src` to `dst` (created if absent).
pub fn copyTree(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) !void {
    try mkpath(io, dst);
    var dir = try Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const dst_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dst, entry.path });
        defer gpa.free(dst_path);
        const src_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ src, entry.path });
        defer gpa.free(src_path);
        switch (entry.kind) {
            .directory => try mkpath(io, dst_path),
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const len = try Dir.cwd().readLink(io, src_path, &buf);
                try symlink(io, buf[0..len], dst_path);
            },
            else => try copyFile(gpa, io, src_path, dst_path),
        }
    }
}

// POSIX FIFO creation. Device-node fixtures instead use a run-time bind-mount.
// The libc `mkfifo` is referenced only inside the non-Linux comptime branch,
// so the Linux runner links no libc.
const libc_mkfifo = struct {
    extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
};

const fifo_mode: u32 = 0o10000 | 0o666; // S_IFIFO | rw-rw-rw-

/// A FIFO inode (unprivileged).
pub fn mkfifoAt(gpa: std.mem.Allocator, path: []const u8) !void {
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    if (comptime builtin.os.tag == .linux) {
        const rc: isize = @bitCast(std.os.linux.mknod(z.ptr, fifo_mode, 0));
        if (rc < 0) return error.MkfifoFailed;
        return;
    }
    if (libc_mkfifo.mkfifo(z.ptr, @intCast(fifo_mode)) != 0) return error.MkfifoFailed;
}

/// Create a real Unix-domain socket inode and close the listener. Unlike
/// `mknod(S_IFSOCK)`, binding a socket is supported on both Linux and Darwin;
/// the pathname remains until the fixture tree is removed.
pub fn mksocket(io: std.Io, path: []const u8) !void {
    const address = try std.Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    server.deinit(io);
}
