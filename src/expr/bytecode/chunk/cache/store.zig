//! Filesystem ownership and bounded background publication for compiled units.
//! Wire encoding/decoding lives in the sibling cache codec; this owner knows
//! paths, retention, queue capacity, and write lifecycle only.

const std = @import("std");
const BlockingPool = @import("base").BlockingPool;
const SpinMutex = @import("base").sync.SpinMutex;
const codec = @import("../cache.zig");

pub const default_pending_bytes: usize = 64 * 1024 * 1024;
pub const stale_generation_age_seconds: i64 = 30 * 24 * 60 * 60;
pub const staging_age_seconds: i64 = 60 * 60;

pub const Options = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    generation: []const u8,
    home: ?[]const u8,
    policy_fp: u64,
    let_float_enabled: bool,
    full_lazy_enabled: bool,
    mfe_min_applies: u16,
    named_floats: bool,
    chain_split: bool,
    max_pending_bytes: usize = default_pending_bytes,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    generation: []u8,
    dir: []u8,
    home: ?[]u8,
    key_ctx: codec.KeyContext,
    /// Serializes writer submission against the one-way close in `flush`.
    /// Producers may finish serialization after a fast-exit flush; they see
    /// `writer == null` and free their blob instead of touching a dead pool.
    writer_mu: SpinMutex = .{},
    writer: ?*BlockingPool,
    pending_bytes: std.atomic.Value(usize) = .init(0),
    max_pending_bytes: usize,

    pub fn init(options: Options) !Store {
        const root = try options.allocator.dupe(u8, options.root);
        errdefer options.allocator.free(root);
        const generation = try options.allocator.dupe(u8, options.generation);
        errdefer options.allocator.free(generation);
        const dir = try std.fs.path.join(options.allocator, &.{ root, generation });
        errdefer options.allocator.free(dir);
        try std.Io.Dir.cwd().createDirPath(options.io, dir);
        const home: ?[]u8 = if (options.home) |value| try options.allocator.dupe(u8, value) else null;
        errdefer if (home) |value| options.allocator.free(value);

        const writer = try options.allocator.create(BlockingPool);
        errdefer options.allocator.destroy(writer);
        writer.* = BlockingPool.init(options.allocator, 1);
        writer.start() catch |err| {
            writer.deinit();
            return err;
        };

        return .{
            .allocator = options.allocator,
            .io = options.io,
            .root = root,
            .generation = generation,
            .dir = dir,
            .home = home,
            .key_ctx = .{
                .policy_fp = options.policy_fp,
                .let_float_enabled = options.let_float_enabled,
                .full_lazy_enabled = options.full_lazy_enabled,
                .mfe_min_applies = options.mfe_min_applies,
                .named_floats = options.named_floats,
                .chain_split = options.chain_split,
                .home = home,
            },
            .writer = writer,
            .max_pending_bytes = options.max_pending_bytes,
        };
    }

    pub fn deinit(self: *Store) void {
        self.flush();
        self.allocator.free(self.root);
        self.allocator.free(self.generation);
        self.allocator.free(self.dir);
        if (self.home) |home| self.allocator.free(home);
        self.* = undefined;
    }

    pub fn flush(self: *Store) void {
        self.writer_mu.lock();
        const writer = self.writer orelse {
            self.writer_mu.unlock();
            return;
        };
        self.writer = null;
        self.writer_mu.unlock();
        writer.deinit();
        self.allocator.destroy(writer);
        std.debug.assert(self.pending_bytes.load(.acquire) == 0);
    }

    pub fn key(self: *const Store, source: []const u8, source_path: []const u8) codec.Key {
        return codec.computeKey(source, source_path, self.key_ctx);
    }

    pub fn pathAlloc(self: *const Store, allocator: std.mem.Allocator, key_value: codec.Key) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}.unit", .{ self.dir, std.fmt.bytesToHex(key_value, .lower) });
    }

    pub fn readAlloc(self: *const Store, allocator: std.mem.Allocator, key_value: codec.Key, limit: std.Io.Limit) ![]u8 {
        const path = try self.pathAlloc(allocator, key_value);
        defer allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, limit);
    }

    /// An import manifest: the absolute source paths one entry expression's
    /// evaluation imported, one per line. Startup replays them through the
    /// speculative import-prefetch lane so cached units decode early — while
    /// the intern/chunk id spaces are still small enough for their narrow
    /// operands — instead of serially on the demand path's import chains.
    /// Manifests are keyed by the entry file's path (`manifestName`) so
    /// unrelated workloads sharing a generation don't clobber each other's
    /// preload order; expression-only evals have no manifest at all.
    pub fn manifestName(entry_path: []const u8, buf: *[33]u8) []const u8 {
        const fp = std.hash.Wyhash.hash(0x314F1157, entry_path);
        return std.fmt.bufPrint(buf, "imports-{x:0>16}.manifest", .{fp}) catch unreachable;
    }

    pub fn readManifestAlloc(self: *const Store, allocator: std.mem.Allocator, name: []const u8, limit: std.Io.Limit) ![]u8 {
        const path = try std.fs.path.join(allocator, &.{ self.dir, name });
        defer allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, limit);
    }

    /// Best-effort atomic replace (staging + rename), so concurrent
    /// evaluators never observe a torn manifest.
    pub fn writeManifest(self: *const Store, name: []const u8, bytes: []const u8) void {
        const path = std.fs.path.join(self.allocator, &.{ self.dir, name }) catch return;
        defer self.allocator.free(path);
        _ = publish(self.io, self.allocator, path, bytes);
    }

    fn claimPending(self: *Store, bytes: usize) bool {
        if (bytes > self.max_pending_bytes) return false;
        var current = self.pending_bytes.load(.acquire);
        while (true) {
            if (current > self.max_pending_bytes - bytes) return false;
            current = self.pending_bytes.cmpxchgWeak(current, current + bytes, .acq_rel, .acquire) orelse return true;
        }
    }

    /// Best-effort bounded enqueue. Always consumes `bytes`: queued jobs own
    /// the allocation, while a full/stopped/failed queue frees it immediately.
    /// Returning false means the cache write was deliberately dropped.
    pub fn enqueueOwned(self: *Store, key_value: codec.Key, bytes: []u8, writes: *std.atomic.Value(u64)) bool {
        if (!self.claimPending(bytes.len)) {
            self.allocator.free(bytes);
            return false;
        }
        const path = self.pathAlloc(self.allocator, key_value) catch {
            _ = self.pending_bytes.fetchSub(bytes.len, .release);
            self.allocator.free(bytes);
            return false;
        };
        const job = self.allocator.create(WriteJob) catch {
            self.allocator.free(path);
            _ = self.pending_bytes.fetchSub(bytes.len, .release);
            self.allocator.free(bytes);
            return false;
        };
        job.* = .{
            .job = .{ .run = WriteJob.run, .context = job },
            .store = self,
            .path = path,
            .bytes = bytes,
            .writes = writes,
        };

        self.writer_mu.lock();
        const writer = self.writer orelse {
            self.writer_mu.unlock();
            self.allocator.destroy(job);
            self.allocator.free(path);
            _ = self.pending_bytes.fetchSub(bytes.len, .release);
            self.allocator.free(bytes);
            return false;
        };
        writer.submit(&job.job);
        self.writer_mu.unlock();
        return true;
    }

    /// Explicit cache housekeeping. Engine startup never calls this: cache
    /// lookup stays O(1), concurrently running builds keep their generations,
    /// and callers can schedule age-bounded cleanup off the demand path.
    pub fn maintain(self: *Store) void {
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        var root_dir = std.Io.Dir.openDirAbsolute(self.io, self.root, .{ .iterate = true }) catch return;
        defer root_dir.close(self.io);
        var generations = root_dir.iterate();
        while (generations.next(self.io) catch return) |generation_entry| {
            if (generation_entry.kind != .directory) continue;
            const generation_path = std.fs.path.join(self.allocator, &.{ self.root, generation_entry.name }) catch continue;
            defer self.allocator.free(generation_path);
            if (std.mem.eql(u8, generation_entry.name, self.generation)) {
                self.removeOldStaging(generation_path, now);
                continue;
            }
            const stat = root_dir.statFile(self.io, generation_entry.name, .{}) catch continue;
            const age = now - @divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s);
            if (age > stale_generation_age_seconds) std.Io.Dir.cwd().deleteTree(self.io, generation_path) catch {};
        }
    }

    fn removeOldStaging(self: *Store, path: []const u8, now: i64) void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var files = dir.iterate();
        while (files.next(self.io) catch return) |entry| {
            if (entry.kind != .file or std.mem.indexOf(u8, entry.name, ".tmp-") == null) continue;
            const stat = dir.statFile(self.io, entry.name, .{}) catch continue;
            const age = now - @divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s);
            if (age > staging_age_seconds) dir.deleteFile(self.io, entry.name) catch {};
        }
    }
};

const WriteJob = struct {
    job: BlockingPool.Job,
    store: *Store,
    path: []u8,
    bytes: []u8,
    writes: *std.atomic.Value(u64),

    fn run(raw: *anyopaque) void {
        const self: *WriteJob = @ptrCast(@alignCast(raw));
        const store = self.store;
        const byte_count = self.bytes.len;
        defer {
            store.allocator.free(self.path);
            store.allocator.free(self.bytes);
            store.allocator.destroy(self);
            _ = store.pending_bytes.fetchSub(byte_count, .release);
        }
        if (publish(store.io, store.allocator, self.path, self.bytes)) _ = self.writes.fetchAdd(1, .monotonic);
    }
};

fn publish(io: std.Io, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) bool {
    var random: [8]u8 = undefined;
    std.Io.random(io, &random);
    const staging = std.fmt.allocPrint(allocator, "{s}.tmp-{s}", .{ path, std.fmt.bytesToHex(random, .lower) }) catch return false;
    defer allocator.free(staging);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staging, .data = bytes }) catch return false;
    std.Io.Dir.renameAbsolute(staging, path, io) catch {
        std.Io.Dir.deleteFileAbsolute(io, staging) catch {};
        return false;
    };
    return true;
}

test "bounded background store transfers blob ownership and flushes publication" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const root = try std.fs.path.join(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cache" });
    defer testing.allocator.free(root);
    const sibling = try std.fs.path.join(testing.allocator, &.{ root, "other-running-build" });
    defer testing.allocator.free(sibling);
    try std.Io.Dir.cwd().createDirPath(testing.io, sibling);
    const sentinel = try std.fs.path.join(testing.allocator, &.{ sibling, "keep.unit" });
    defer testing.allocator.free(sentinel);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = sentinel, .data = "keep" });
    var store = try Store.init(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .root = root,
        .generation = "test-generation",
        .home = null,
        .policy_fp = 7,
        .let_float_enabled = true,
        .full_lazy_enabled = false,
        .mfe_min_applies = 1,
        .named_floats = true,
        .chain_split = false,
        .max_pending_bytes = 8,
    });
    defer store.deinit();
    _ = try std.Io.Dir.cwd().statFile(testing.io, sentinel, .{});
    var writes: std.atomic.Value(u64) = .init(0);
    const key_value: codec.Key = @splat(0x5a);
    try testing.expect(store.enqueueOwned(key_value, try testing.allocator.dupe(u8, "payload"), &writes));
    try testing.expect(!store.enqueueOwned(key_value, try testing.allocator.dupe(u8, "too-large"), &writes));
    store.flush();
    const bytes = try store.readAlloc(testing.allocator, key_value, .limited(64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("payload", bytes);
    try testing.expectEqual(@as(u64, 1), writes.load(.acquire));
}
