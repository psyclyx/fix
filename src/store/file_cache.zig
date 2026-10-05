//! Engine-owned filesystem cache.
//!
//! The VM talks to this cache, not directly to the host filesystem. Cold
//! reads are isolated behind `readFile`/`pathExists` so workers can use
//! the same cache without each call going to the kernel.
//!
//! Concurrency: entries are heap-allocated and pinned, so `*Entry`
//! pointers stay valid across hashmap inserts. The map mutex is held
//! only briefly around lookup/insert; per-entry state is then
//! synchronised under a per-entry mutex, so workers reading *different*
//! files do I/O in parallel and workers reading the *same* file
//! serialise on just that path's mutex (rather than the whole cache).

const std = @import("std");
const sync = @import("base").sync;
const vma = @import("runtime").mem_tag.vma;

pub const FileCache = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,
    /// Path → heap-allocated entry. The pointer stays valid across
    /// map growth, so workers can release `map_mu` immediately after
    /// the lookup and do I/O against the entry without blocking other
    /// paths.
    entries: std.StringHashMapUnmanaged(*Entry),
    /// Protects the hashmap structure only. Held briefly during
    /// lookup / insert, never across I/O.
    map_mu: sync.BlockingMutex = .{},
    /// Store paths whose contents are read from elsewhere on the host, as
    /// Nix mounts a fetched tree at its store path: a tree fetched in plain
    /// eval gets its real store path without the store being written.
    /// Guarded by `map_mu`.
    mounts: std.ArrayListUnmanaged(Mount) = .empty,

    pub const Mount = struct {
        store_path: []u8,
        host_path: []u8,
        /// A name left out of the tree at every depth (a checkout's `.git`),
        /// as its NAR serialization leaves it out.
        hidden: ?[]const u8,
    };

    const max_read_bytes = 128 * 1024 * 1024;

    pub const FileKind = enum {
        regular,
        directory,
        symlink,
        unknown,

        pub fn nixTypeName(self: FileKind) []const u8 {
            return switch (self) {
                .regular => "regular",
                .directory => "directory",
                .symlink => "symlink",
                .unknown => "unknown",
            };
        }
    };

    pub const DirEntry = struct {
        name: []u8,
        kind: FileKind,
    };

    /// Shared ownership of an immutable byte allocation. Handles are cheap to
    /// copy explicitly with `retain`; reading the bytes does not touch the
    /// refcount.
    pub const ImmutableBytes = struct {
        blob: *Blob,

        const Blob = struct {
            allocator: std.mem.Allocator,
            refs: std.atomic.Value(usize),
            owned: []u8,
        };

        /// Takes ownership of `owned` without copying it. On blob allocation
        /// failure, ownership is still consumed and the bytes are freed.
        pub fn fromOwned(allocator: std.mem.Allocator, owned: []u8) !ImmutableBytes {
            const blob = allocator.create(Blob) catch |err| {
                allocator.free(owned);
                return err;
            };
            blob.* = .{
                .allocator = allocator,
                .refs = .init(1),
                .owned = owned,
            };
            return .{ .blob = blob };
        }

        pub fn bytes(self: ImmutableBytes) []const u8 {
            return self.blob.owned;
        }

        pub fn retain(self: ImmutableBytes) ImmutableBytes {
            const previous = self.blob.refs.fetchAdd(1, .monotonic);
            std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
            return self;
        }

        pub fn release(self: *ImmutableBytes) void {
            if (self.blob.refs.fetchSub(1, .acq_rel) != 1) return;
            const blob = self.blob;
            const allocator = blob.allocator;
            allocator.free(blob.owned);
            allocator.destroy(blob);
        }
    };

    const Entry = struct {
        /// The canonical path, and the cache key.
        path: []u8,
        /// Guards the populated-fields below. Held during I/O so a
        /// concurrent reader for the same path waits on the in-flight
        /// fetch rather than duplicating it. Different paths get
        /// different entries → different mutexes → fully parallel.
        mu: sync.BlockingMutex = .{},
        exists_known: bool = false,
        exists: bool = false,
        kind: ?FileKind = null,
        contents: ?ImmutableBytes = null,
        dir_entries: ?[]DirEntry = null,
    };

    pub fn init(allocator: std.mem.Allocator) FileCache {
        return .{
            .allocator = allocator,
            .io = null,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *FileCache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |kv| {
            const entry = kv.value_ptr.*;
            self.allocator.free(entry.path);
            if (entry.contents) |*contents| contents.release();
            if (entry.dir_entries) |entries| self.freeDirEntries(entries);
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
        for (self.mounts.items) |m| {
            self.allocator.free(m.store_path);
            self.allocator.free(m.host_path);
        }
        self.mounts.deinit(self.allocator);
    }

    /// Serve `store_path` from `host_path`, leaving out entries named
    /// `hidden`. Mounting a store path again moves it to the new host path:
    /// store paths are content-addressed, so both hold the same tree, and
    /// the newer one is the more likely to still exist.
    pub fn mount(self: *FileCache, store_path: []const u8, host_path: []const u8, hidden: ?[]const u8) !void {
        const owned_host = try self.allocator.dupe(u8, host_path);
        errdefer self.allocator.free(owned_host);
        self.map_mu.lock();
        defer self.map_mu.unlock();
        for (self.mounts.items) |*m| {
            if (!std.mem.eql(u8, m.store_path, store_path)) continue;
            self.allocator.free(m.host_path);
            m.host_path = owned_host;
            m.hidden = hidden;
            return;
        }
        const owned_store = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(owned_store);
        try self.mounts.append(self.allocator, .{ .store_path = owned_store, .host_path = owned_host, .hidden = hidden });
    }

    /// Where a path lives on the host: itself, or its place in a mount.
    const Host = struct {
        path: []const u8,
        mounted: bool = false,
        /// The path is a name its mount leaves out, so it doesn't exist.
        hidden: bool = false,
        /// The name its mount leaves out (static).
        hidden_name: ?[]const u8 = null,
    };

    /// Resolve canonical `path` through the mounts, into `buf` when it is
    /// mounted. Resolved at each host access (rather than once per entry),
    /// so a re-mounted tree is read from its new place.
    fn host(self: *FileCache, path: []const u8, buf: *[std.fs.max_path_bytes]u8) !Host {
        self.map_mu.lock();
        defer self.map_mu.unlock();
        for (self.mounts.items) |m| {
            if (!std.mem.startsWith(u8, path, m.store_path)) continue;
            const rest = path[m.store_path.len..];
            if (rest.len != 0 and rest[0] != '/') continue;
            var hidden = false;
            if (m.hidden) |name| {
                var components = std.mem.tokenizeScalar(u8, rest, '/');
                while (components.next()) |component| {
                    if (std.mem.eql(u8, component, name)) hidden = true;
                }
            }
            if (m.host_path.len + rest.len > buf.len) return error.NameTooLong;
            @memcpy(buf[0..m.host_path.len], m.host_path);
            @memcpy(buf[m.host_path.len..][0..rest.len], rest);
            return .{ .path = buf[0 .. m.host_path.len + rest.len], .mounted = true, .hidden = hidden, .hidden_name = m.hidden };
        }
        return .{ .path = path };
    }

    pub fn setIo(self: *FileCache, io: std.Io) void {
        self.io = io;
    }

    pub fn pathExists(self: *FileCache, path: []const u8) !bool {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.exists_known) return entry.exists;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const host_path = try self.host(entry.path, &buf);
        if (host_path.hidden) return false;

        const io = self.io orelse return error.FileIoUnavailable;
        // lstat-based existence (matching Nix): the final path component exists
        // even if it is a broken symlink, and a trailing `/`/`/.` on a
        // non-directory does not exist.
        _ = std.Io.Dir.cwd().statFile(io, host_path.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                entry.exists_known = true;
                entry.exists = false;
                return false;
            },
            else => return err,
        };

        entry.exists_known = true;
        entry.exists = true;
        return true;
    }

    /// Whether `path`, following symlinks, is a directory. A trailing `/`/`/.`
    /// in `pathExists` requires a directory, and (unlike `fileType`'s lstat)
    /// must resolve a final symlink to its target.
    pub fn isDirectoryFollowing(self: *FileCache, path: []const u8) !bool {
        const io = self.io orelse return error.FileIoUnavailable;
        const entry = try self.entryFor(path);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const host_path = try self.host(entry.path, &buf);
        if (host_path.hidden) return false;
        const stat = std.Io.Dir.cwd().statFile(io, host_path.path, .{ .follow_symlinks = true }) catch return false;
        return stat.kind == .directory;
    }

    /// Trap: deliberately UNcached existence probe. Used by import-from-
    /// derivation to decide whether a demanded store path still needs building,
    /// WITHOUT memoizing the result — a path that becomes valid after an
    /// on-demand build must not be pinned to a stale `false` (as `pathExists`
    /// would). `path` must be absolute (store paths always are).
    pub fn existsUncached(self: *FileCache, path: []const u8) !bool {
        const io = self.io orelse return error.FileIoUnavailable;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const host_path = try self.host(path, &buf);
        if (host_path.hidden) return false;
        std.Io.Dir.accessAbsolute(io, host_path.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    pub fn readFile(self: *FileCache, path: []const u8) ![]const u8 {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.contents) |contents| return contents.bytes();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const host_path = try self.host(entry.path, &buf);
        if (host_path.hidden) return error.FileNotFound;

        const io = self.io orelse return error.FileIoUnavailable;
        // RSS attribution: cached source texts live for the evaluator's
        // lifetime — big ones (≥64 KB) get their own bucket.
        const prev_tag = vma.setAllocTag(.file_cache);
        defer _ = vma.setAllocTag(prev_tag);
        const contents = try std.Io.Dir.cwd().readFileAlloc(
            io,
            host_path.path,
            self.allocator,
            .limited(max_read_bytes),
        );
        const handle = try ImmutableBytes.fromOwned(self.allocator, contents);

        entry.exists_known = true;
        entry.exists = true;
        entry.contents = handle;
        // Do NOT stamp `kind`: reading follows symlinks, but `kind` is the
        // lstat kind (a symlink-to-regular must still serialize as a symlink
        // node — stamping .regular here poisoned NAR hashing of any tree
        // whose symlinked .nix files were imported first).
        return handle.bytes();
    }

    /// Write `data` to `path` (flake lock generation) and publish the same bytes
    /// into the immutable read cache. The replacement is fully allocated before
    /// host or cache state changes; readers of this path serialize on its entry.
    pub fn writeFile(self: *FileCache, path: []const u8, data: []const u8) !void {
        const io = self.io orelse return error.FileIoUnavailable;
        const owned = try self.allocator.dupe(u8, data);
        var replacement = try ImmutableBytes.fromOwned(self.allocator, owned);
        errdefer replacement.release();

        const entry = try self.entryFor(path);
        // A mounted tree stands in for a read-only store path.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if ((try self.host(entry.path, &buf)).mounted) return error.ReadOnlyFileSystem;
        entry.mu.lock();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = entry.path, .data = data }) catch |err| {
            entry.mu.unlock();
            return err;
        };
        if (entry.contents) |*contents| contents.release();
        if (entry.dir_entries) |entries| self.freeDirEntries(entries);
        entry.contents = replacement;
        entry.dir_entries = null;
        entry.exists_known = true;
        entry.exists = true;
        // See readFile: writes follow a final symlink; `kind` stays lstat-only.
        entry.mu.unlock();

        self.invalidateParentListing(entry.path);
    }

    /// Return a retained immutable handle for a file, populating the same
    /// cache entry used by `readFile` on a cold miss.
    pub fn retainFile(self: *FileCache, path: []const u8) !ImmutableBytes {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.contents) |contents| return contents.retain();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const host_path = try self.host(entry.path, &buf);
        if (host_path.hidden) return error.FileNotFound;

        const io = self.io orelse return error.FileIoUnavailable;
        const prev_tag = vma.setAllocTag(.file_cache);
        defer _ = vma.setAllocTag(prev_tag);
        const owned = try std.Io.Dir.cwd().readFileAlloc(
            io,
            host_path.path,
            self.allocator,
            .limited(max_read_bytes),
        );
        const handle = try ImmutableBytes.fromOwned(self.allocator, owned);

        entry.exists_known = true;
        entry.exists = true;
        entry.contents = handle;
        // See readFile: `kind` stays lstat-only.
        return handle.retain();
    }

    /// Seed the cache so `path` resolves to `contents` as a regular file,
    /// without touching the host filesystem. Used to make a fixed-output store
    /// path readable in storeless eval — its bytes are already known from the
    /// fetch — so `builtins.readFile`/`readFileType` on a `fetchurl` result
    /// behave as they would against Nix's realized store. A no-op if the entry
    /// is already populated.
    pub fn provideRegular(self: *FileCache, path: []const u8, contents: ImmutableBytes) !void {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.contents != null) return;
        entry.contents = contents.retain();
        entry.exists_known = true;
        entry.exists = true;
        entry.kind = .regular;
    }

    pub fn fileType(self: *FileCache, path: []const u8) !FileKind {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.kind) |kind| return kind;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const host_path = try self.host(entry.path, &buf);
        if (host_path.hidden) return error.FileNotFound;

        const io = self.io orelse return error.FileIoUnavailable;
        const stat = std.Io.Dir.cwd().statFile(io, host_path.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                entry.exists_known = true;
                entry.exists = false;
                return err;
            },
            else => return err,
        };
        const kind = fileKindFromStd(stat.kind);
        entry.exists_known = true;
        entry.exists = true;
        entry.kind = kind;
        return kind;
    }

    /// Trap: deliberately UNcached. Unlike `readFile`/`fileType`/`readDir`,
    /// this does not take the per-entry mutex or memoize on the `Entry`; it
    /// stats the file fresh on every call.
    pub fn isExecutable(self: *FileCache, path: []const u8) !bool {
        const entry = try self.entryFor(path);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const host_path = try self.host(entry.path, &buf);
        if (host_path.hidden) return error.FileNotFound;
        const io = self.io orelse return error.FileIoUnavailable;
        const stat = try std.Io.Dir.cwd().statFile(io, host_path.path, .{ .follow_symlinks = false });
        return @TypeOf(stat.permissions).has_executable_bit and stat.permissions.toMode() & 0o111 != 0;
    }

    /// Trap: deliberately UNcached. Unlike `readFile`/`fileType`/`readDir`,
    /// this does not take the per-entry mutex or memoize on the `Entry`; it
    /// re-reads the symlink target fresh on every call and returns a newly
    /// allocated copy the caller owns.
    pub fn readLink(self: *FileCache, path: []const u8) ![]u8 {
        const entry = try self.entryFor(path);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const host_path = try self.host(entry.path, &buf);
        if (host_path.hidden) return error.FileNotFound;
        const io = self.io orelse return error.FileIoUnavailable;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try std.Io.Dir.readLinkAbsolute(io, host_path.path, &buffer);
        return self.allocator.dupe(u8, buffer[0..len]);
    }

    pub fn readDir(self: *FileCache, path: []const u8) ![]const DirEntry {
        return self.readDirCold(path, null);
    }

    /// `readDir` that also reports whether THIS call did the I/O (a cold
    /// miss) vs returning the cached listing. Exactly one caller observes
    /// `cold = true` per path — concurrent readers of the same path
    /// serialise on the entry mutex and see the populated cache. Used by
    /// the readDir-children prefetch hook to fire once per directory.
    pub fn readDirCold(self: *FileCache, path: []const u8, cold: ?*bool) ![]const DirEntry {
        const entry = try self.entryFor(path);
        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.dir_entries) |entries| return entries;
        if (cold) |c| c.* = true;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const host_path = try self.host(entry.path, &buf);
        if (host_path.hidden) return error.FileNotFound;
        const hidden_name = host_path.hidden_name;

        const io = self.io orelse return error.FileIoUnavailable;
        var dir = try std.Io.Dir.cwd().openDir(io, host_path.path, .{ .iterate = true });
        defer dir.close(io);

        var owned_entries: std.ArrayListUnmanaged(DirEntry) = .empty;
        errdefer {
            self.freeDirEntries(owned_entries.items);
            owned_entries.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (try iter.next(io)) |dir_entry| {
            if (hidden_name) |hidden| if (std.mem.eql(u8, dir_entry.name, hidden)) continue;
            const name = try self.allocator.dupe(u8, dir_entry.name);
            owned_entries.append(self.allocator, .{
                .name = name,
                .kind = fileKindFromStd(dir_entry.kind),
            }) catch |err| {
                self.allocator.free(name);
                return err;
            };
        }

        entry.exists_known = true;
        entry.exists = true;
        // See readFile: openDir follows symlinks; `kind` stays lstat-only.
        entry.dir_entries = try owned_entries.toOwnedSlice(self.allocator);
        return entry.dir_entries.?;
    }

    fn entryFor(self: *FileCache, path: []const u8) !*Entry {
        self.map_mu.lock();
        if (self.entries.get(path)) |entry| {
            self.map_mu.unlock();
            return entry;
        }
        // We need to insert. Hold the map mutex through canonicalise +
        // alloc + insert; releasing in the middle would let another
        // worker race in with the same path, and we'd both allocate
        // entries.
        defer self.map_mu.unlock();

        const canonical = try self.canonicalPath(path);
        errdefer self.allocator.free(canonical);

        // Recheck under the lock — `path` and the canonical form may
        // differ, and another worker could have inserted the
        // canonical key while we were normalising.
        if (self.entries.get(canonical)) |entry| {
            self.allocator.free(canonical);
            return entry;
        }

        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .path = canonical };

        try self.entries.put(self.allocator, canonical, entry);
        return entry;
    }

    fn canonicalPath(self: *FileCache, path: []const u8) ![]u8 {
        if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
        if (!needsNormalize(path)) return self.allocator.dupe(u8, path);
        return std.fs.path.resolve(self.allocator, &.{path});
    }

    fn invalidateParentListing(self: *FileCache, path: []const u8) void {
        const parent_path = std.fs.path.dirname(path) orelse return;
        self.map_mu.lock();
        const parent = self.entries.get(parent_path);
        self.map_mu.unlock();
        const entry = parent orelse return;

        entry.mu.lock();
        defer entry.mu.unlock();
        if (entry.dir_entries) |entries| {
            self.freeDirEntries(entries);
            entry.dir_entries = null;
        }
    }

    fn needsNormalize(path: []const u8) bool {
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return true;
        }
        return false;
    }

    fn freeDirEntries(self: *FileCache, entries: []DirEntry) void {
        for (entries) |dir_entry| self.allocator.free(dir_entry.name);
        self.allocator.free(entries);
    }

    fn fileKindFromStd(kind: std.Io.File.Kind) FileKind {
        return switch (kind) {
            .file => .regular,
            .directory => .directory,
            .sym_link => .symlink,
            else => .unknown,
        };
    }
};

const CountingAllocator = struct {
    child: std.mem.Allocator,
    tracked_payload_ptr: std.atomic.Value(usize) = .init(0),
    payload_free_count: std.atomic.Value(usize) = .init(0),

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn trackPayload(self: *CountingAllocator, payload: []u8) void {
        std.debug.assert(self.tracked_payload_ptr.load(.seq_cst) == 0);
        self.tracked_payload_ptr.store(@intFromPtr(payload.ptr), .seq_cst);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const is_payload = @intFromPtr(buf.ptr) == self.tracked_payload_ptr.load(.seq_cst);
        self.child.rawFree(buf, alignment, ret_addr);
        if (is_payload) _ = self.payload_free_count.fetchAdd(1, .monotonic);
    }
};

fn makeOwnedBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const owned = try allocator.alloc(u8, bytes.len);
    @memcpy(owned, bytes);
    return owned;
}

fn hammerRetainRelease(shared: *FileCache.ImmutableBytes, iterations: usize) void {
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var retained = shared.retain();
        std.debug.assert(std.mem.eql(u8, retained.bytes(), "thread-safe"));
        retained.release();
    }
}

test "FileCache.ImmutableBytes.fromOwned preserves pointer and frees once" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const payload_allocator = counting.allocator();
    const original = "payload-transfer";
    const owned = try makeOwnedBytes(payload_allocator, original);
    const original_ptr = @intFromPtr(owned.ptr);
    counting.trackPayload(owned);

    var payload = try FileCache.ImmutableBytes.fromOwned(payload_allocator, owned);
    try std.testing.expectEqual(original_ptr, @intFromPtr(payload.bytes().ptr));
    try std.testing.expectEqualStrings(original, payload.bytes());
    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));

    payload.release();
    try std.testing.expectEqual(@as(usize, 1), counting.payload_free_count.load(.seq_cst));
}

test "FileCache.ImmutableBytes retain release holds bytes until final release" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const payload_allocator = counting.allocator();
    const original = "retained-payload";
    const owned = try makeOwnedBytes(payload_allocator, original);
    const original_ptr = @intFromPtr(owned.ptr);
    counting.trackPayload(owned);

    var payload = try FileCache.ImmutableBytes.fromOwned(payload_allocator, owned);
    var retained = payload.retain();

    try std.testing.expectEqual(original_ptr, @intFromPtr(payload.bytes().ptr));
    try std.testing.expectEqual(@intFromPtr(payload.bytes().ptr), @intFromPtr(retained.bytes().ptr));
    payload.release();
    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));
    try std.testing.expectEqualStrings(original, retained.bytes());

    retained.release();
    try std.testing.expectEqual(@as(usize, 1), counting.payload_free_count.load(.seq_cst));
}

test "FileCache aliases share blob pointers and metadata" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const payload_allocator = counting.allocator();
    var cache = FileCache.init(std.testing.allocator);
    const original = "shared-alias-payload";
    const owned = try makeOwnedBytes(payload_allocator, original);
    const original_ptr = @intFromPtr(owned.ptr);
    counting.trackPayload(owned);

    var payload = try FileCache.ImmutableBytes.fromOwned(payload_allocator, owned);
    var alias_seed = payload.retain();

    try cache.provideRegular("/virtual/cache-alpha", payload);
    try cache.provideRegular("/virtual/cache-beta", alias_seed);
    payload.release();
    alias_seed.release();
    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));

    try std.testing.expect(try cache.pathExists("/virtual/cache-alpha"));
    try std.testing.expect(try cache.pathExists("/virtual/cache-beta"));
    try std.testing.expectEqual(FileCache.FileKind.regular, try cache.fileType("/virtual/cache-alpha"));
    try std.testing.expectEqual(FileCache.FileKind.regular, try cache.fileType("/virtual/cache-beta"));

    const alpha_read = try cache.readFile("/virtual/cache-alpha");
    const beta_read = try cache.readFile("/virtual/cache-beta");
    try std.testing.expectEqual(original_ptr, @intFromPtr(alpha_read.ptr));
    try std.testing.expectEqual(@intFromPtr(alpha_read.ptr), @intFromPtr(beta_read.ptr));
    try std.testing.expectEqualStrings(original, alpha_read);
    try std.testing.expectEqualStrings(original, beta_read);

    var retained_alpha = try cache.retainFile("/virtual/cache-alpha");
    var retained_beta = try cache.retainFile("/virtual/cache-beta");
    try std.testing.expectEqual(original_ptr, @intFromPtr(retained_alpha.bytes().ptr));
    try std.testing.expectEqual(@intFromPtr(retained_alpha.bytes().ptr), @intFromPtr(retained_beta.bytes().ptr));

    retained_alpha.release();
    retained_beta.release();
    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));
    cache.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting.payload_free_count.load(.seq_cst));
}

test "FileCache.ImmutableBytes concurrent retain release frees once" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const payload_allocator = counting.allocator();
    const owned = try makeOwnedBytes(payload_allocator, "thread-safe");
    const original_ptr = @intFromPtr(owned.ptr);
    counting.trackPayload(owned);
    var payload = try FileCache.ImmutableBytes.fromOwned(payload_allocator, owned);
    try std.testing.expectEqual(original_ptr, @intFromPtr(payload.bytes().ptr));

    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, hammerRetainRelease, .{ &payload, 2_000 + index });
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));
    payload.release();
    try std.testing.expectEqual(@as(usize, 1), counting.payload_free_count.load(.seq_cst));
}

test "FileCache provideRegular idempotent seeding preserves payload pointer without leaks" {
    var counting = CountingAllocator.init(std.testing.allocator);
    const payload_allocator = counting.allocator();
    var cache = FileCache.init(std.testing.allocator);
    const original = "idempotent-payload";
    const owned = try makeOwnedBytes(payload_allocator, original);
    const original_ptr = @intFromPtr(owned.ptr);
    counting.trackPayload(owned);

    var payload = try FileCache.ImmutableBytes.fromOwned(payload_allocator, owned);
    var duplicate_seed = payload.retain();

    try cache.provideRegular("/virtual/cache-dup", payload);
    try cache.provideRegular("/virtual/cache-dup", duplicate_seed);
    payload.release();
    duplicate_seed.release();
    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));

    const read_back = try cache.readFile("/virtual/cache-dup");
    try std.testing.expectEqual(original_ptr, @intFromPtr(read_back.ptr));
    try std.testing.expectEqualStrings(original, read_back);

    var retained = try cache.retainFile("/virtual/cache-dup");
    try std.testing.expectEqual(original_ptr, @intFromPtr(retained.bytes().ptr));
    retained.release();

    try std.testing.expectEqual(@as(usize, 0), counting.payload_free_count.load(.seq_cst));
    cache.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting.payload_free_count.load(.seq_cst));
}

test "FileCache writeFile replaces cached bytes and invalidates parent listing" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "flake.lock", .data = "old" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const root = try std.fs.path.resolve(testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer testing.allocator.free(root);
    const lock_path = try std.fs.path.join(testing.allocator, &.{ root, "flake.lock" });
    defer testing.allocator.free(lock_path);
    const added_path = try std.fs.path.join(testing.allocator, &.{ root, "added.lock" });
    defer testing.allocator.free(added_path);

    var cache = FileCache.init(testing.allocator);
    defer cache.deinit();
    cache.setIo(testing.io);

    try testing.expectEqualStrings("old", try cache.readFile(lock_path));
    _ = try cache.readDir(root);
    try cache.writeFile(lock_path, "new");
    try testing.expectEqualStrings("new", try cache.readFile(lock_path));

    try cache.writeFile(added_path, "added");
    try testing.expect(try cache.pathExists(added_path));
    try testing.expectEqual(FileCache.FileKind.regular, try cache.fileType(added_path));
    try testing.expectEqualStrings("added", try cache.readFile(added_path));

    var found_added = false;
    for (try cache.readDir(root)) |entry| {
        if (std.mem.eql(u8, entry.name, "added.lock")) found_added = true;
    }
    try testing.expect(found_added);
}

test "FileCache serves a mounted store path from its host directory" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "tree/sub/.git");
    try tmp.dir.createDirPath(testing.io, "tree/.git");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/sub/file", .data = "contents" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/.git/HEAD", .data = "ref" });
    try tmp.dir.symLink(testing.io, "sub/file", "tree/link", .{});
    const host = try tmp.dir.realPathFileAlloc(testing.io, "tree", testing.allocator);
    defer testing.allocator.free(host);

    var cache = FileCache.init(testing.allocator);
    defer cache.deinit();
    cache.setIo(testing.io);
    const store_path = "/nix/store/00000000000000000000000000000000-source";
    try cache.mount(store_path, host, ".git");

    try testing.expectEqualStrings("contents", try cache.readFile(store_path ++ "/sub/file"));
    try testing.expectEqualStrings("contents", try cache.readFile(store_path ++ "/link"));
    try testing.expectEqual(FileCache.FileKind.symlink, try cache.fileType(store_path ++ "/link"));
    const link = try cache.readLink(store_path ++ "/link");
    defer testing.allocator.free(link);
    try testing.expectEqualStrings("sub/file", link);
    try testing.expect(try cache.pathExists(store_path));
    try testing.expect(try cache.existsUncached(store_path ++ "/sub"));

    // The hidden name is gone at every depth.
    for ([_][]const u8{ store_path, store_path ++ "/sub" }) |dir| {
        const listing = try cache.readDir(dir);
        for (listing) |entry| try testing.expect(!std.mem.eql(u8, entry.name, ".git"));
    }
    try testing.expect(!try cache.pathExists(store_path ++ "/.git"));
    try testing.expect(!try cache.existsUncached(store_path ++ "/sub/.git"));
    try testing.expectError(error.FileNotFound, cache.readFile(store_path ++ "/.git/HEAD"));

    // A mount stands in for a read-only store path.
    try testing.expectError(error.ReadOnlyFileSystem, cache.writeFile(store_path ++ "/new", "x"));
    // Paths that merely share the prefix are not in the mount.
    try testing.expect(!try cache.pathExists(store_path ++ "x"));

    // Mounting the store path again (the same tree, elsewhere) moves it, so
    // it stays readable when the first copy is gone.
    try tmp.dir.createDirPath(testing.io, "copy/sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "copy/sub/other", .data = "contents" });
    const copy = try tmp.dir.realPathFileAlloc(testing.io, "copy", testing.allocator);
    defer testing.allocator.free(copy);
    try cache.mount(store_path, copy, ".git");
    try tmp.dir.deleteTree(testing.io, "tree");
    try testing.expectEqualStrings("contents", try cache.readFile(store_path ++ "/sub/other"));
}
