//! Interned strings for fast comparison and small value representation.
//!
//! Thread safety:
//!   - `get(id)` is lock-free. The id-indexed `entries` and `data` are
//!     `StableSegments` whose backing pages are never relocated.
//!   - `intern(s)` shards on the input hash. Each shard holds its own
//!     lookup map and `SpinMutex`. Concurrent interns of strings that
//!     hash to different shards proceed in parallel.
//!
//! Hash-collision correctness: each shard's lookup map stores `InternId`
//! keys and uses an adapter context whose `eql(string, id)` compares the
//! input string against the bytes stored under that id. Two distinct
//! strings that happen to share a Wyhash output coexist as separate
//! entries (in the same shard).

const std = @import("std");
const types = @import("types.zig");
const segments = @import("base").segments;
const sync = @import("base").sync;
const mem_tag = @import("mem_tag.zig");
const InternId = types.InternId;

const Entry = struct {
    segment: u32,
    offset: u32,
    len: u32,
};

/// First 8 bytes of the string, big-endian, zero-padded: comparing two
/// prefixes as `u64` orders exactly like `std.mem.lessThan` on the first
/// `min(len, 8)` bytes. Used by lexicographic sorts to pre-extract one
/// integer sort key per string instead of re-fetching bytes inside the
/// comparator. Equal prefixes (shared 8-byte prefix, or an embedded NUL
/// aliasing the padding) require a full byte-compare tiebreak.
pub fn stringPrefix(s: []const u8) u64 {
    var buf: [8]u8 = @splat(0);
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return std.mem.readInt(u64, &buf, .big);
}

// TLAB chunks small enough to keep near-global temporal packing (hot names
// interned together stay cache-adjacent for the sort/compare read paths)
// while still amortizing each store's write_mu to one acquisition per
// hundreds of inserts. First segments sized >= one refill chunk: a smaller
// first segment cannot host the first refill, which would skip it —
// leaving id 0 unallocated and breaking the empty-string sentinel.
const EntryStore = segments.StableSegments(Entry, .{ .first_segment_size = 256, .tlab_chunk_slots = 256 }, mem_tag.vma);
const ByteStore = segments.StableSegments(u8, .{ .first_segment_size = 4096, .tlab_chunk_slots = 4096 }, mem_tag.vma);

const shard_count: u32 = 64;
const shard_mask: u64 = shard_count - 1;

const cache_size: usize = 512;
const cache_max_len: usize = 19;

/// Exactly half a cache line: two slots pack without straddling. Table
/// identity lives once per thread rather than in every slot.
const CacheSlot = struct {
    hash: u64 = 0,
    id: InternId = 0,
    len: u8 = 0,
    bytes: [cache_max_len]u8 = @splat(0),
};
comptime {
    std.debug.assert(@sizeOf(CacheSlot) == 32);
}

/// Per-thread direct-mapped cache for short-string interns. Indexed
/// by the input's Wyhash mod `cache_size`. `thread_cache_token`
/// distinguishes InternTable instances — pointer comparison fails when
/// the allocator reuses the same address across deinit/init (which broke
/// the cache across sequential tests). Switching tables clears the cache
/// once instead of storing and checking the same token in every slot.
/// Strings longer than `cache_max_len` skip the cache.
threadlocal var thread_cache: [cache_size]CacheSlot = @splat(.{});
threadlocal var thread_cache_token: u64 = 0;

/// Cache operations stay behind non-inlined calls so each invocation forms
/// its TLS address on the OS thread currently running a migratable fiber.
noinline fn threadCacheLookup(table_token: u64, h: u64, s: []const u8) ?InternId {
    if (thread_cache_token != table_token) {
        thread_cache = @splat(.{});
        thread_cache_token = table_token;
    }
    if (s.len > cache_max_len) return null;
    const slot = &thread_cache[h % cache_size];
    if (slot.hash != h or slot.len != s.len or
        !std.mem.eql(u8, slot.bytes[0..s.len], s))
    {
        return null;
    }
    return slot.id;
}

noinline fn threadCacheStore(table_token: u64, h: u64, s: []const u8, id: InternId) void {
    if (s.len > cache_max_len) return;
    if (thread_cache_token != table_token) {
        thread_cache = @splat(.{});
        thread_cache_token = table_token;
    }
    const slot = &thread_cache[h % cache_size];
    slot.hash = h;
    slot.id = id;
    slot.len = @intCast(s.len);
    @memcpy(slot.bytes[0..s.len], s);
}

var next_table_token: std.atomic.Value(u64) = .init(1);

fn hashString(s: []const u8) u64 {
    return std.hash.Wyhash.hash(0, s);
}

const Lookup = std.HashMapUnmanaged(InternId, void, IdContext, std.hash_map.default_max_load_percentage);

/// Context for storing `InternId` keys whose hash and equality dispatch
/// through the owning table so we can re-derive the bytes.
const IdContext = struct {
    table: *const InternTable,

    pub fn hash(self: IdContext, id: InternId) u64 {
        return hashString(self.table.get(id));
    }
    pub fn eql(self: IdContext, a: InternId, b: InternId) bool {
        if (a == b) return true;
        return std.mem.eql(u8, self.table.get(a), self.table.get(b));
    }
};

/// Adapter used by `getOrPutAdapted` so lookups by `[]const u8` use the
/// caller's bytes but storage uses `InternId`. `intern()` precomputes
/// the hash for shard selection and threads it in so the HashMap's
/// internal hash call doesn't recompute the same Wyhash over the same
/// bytes.
const StringAdapter = struct {
    table: *const InternTable,
    precomputed_hash: u64,

    pub fn hash(self: StringAdapter, key: []const u8) u64 {
        _ = key;
        return self.precomputed_hash;
    }
    pub fn eql(self: StringAdapter, key: []const u8, id: InternId) bool {
        const stored = self.table.get(id);
        return stored.len == key.len and std.mem.eql(u8, stored, key);
    }
};

const Shard = struct {
    lookup: Lookup = .empty,
    mu: sync.SpinMutex = .{},
};

/// Per-OS-thread byte-store TLAB, keyed by table token (a recreated table
/// at the same address must not inherit a stale chunk). Switching between
/// two live tables on one thread abandons the old partial chunk — waste
/// bounded by one 8 KB chunk per switch, and nested VMs share the parent's
/// table, so switches are rare.
threadlocal var data_tlab: ByteStore.Tlab = .{};
threadlocal var entry_tlab: EntryStore.Tlab = .{};
threadlocal var tlab_token: u64 = 0;

const Tlabs = struct { data: *ByteStore.Tlab, entry: *EntryStore.Tlab };

fn tlabs(token: u64) Tlabs {
    if (tlab_token != token) {
        data_tlab = .{};
        entry_tlab = .{};
        tlab_token = token;
    }
    return .{ .data = &data_tlab, .entry = &entry_tlab };
}

pub const InternTable = struct {
    allocator: std.mem.Allocator,
    entries: EntryStore,
    data: ByteStore,
    /// Per-shard lookup maps; intern() picks a shard by the low bits of
    /// the input's hash. `entries` and `data` remain global so that ids
    /// stay dense and `get()` doesn't need to know the shard.
    shards: [shard_count]Shard,
    /// Unique-per-init identifier the thread-local intern cache uses to
    /// avoid stale-hit races when an InternTable is recreated at the
    /// same heap address.
    token: u64,
    /// Single-threaded mode: when the owner guarantees exactly one thread
    /// ever interns (a `--workers=1` evaluator; set before anything runs),
    /// `intern()` skips the shard mutex — one lock RMW per uncached intern
    /// elided. `get()` was always lock-free. Default off.
    solo: bool = false,
    pub fn init(allocator: std.mem.Allocator) !InternTable {
        var table: InternTable = .{
            .allocator = allocator,
            .entries = .empty,
            .data = .empty,
            .shards = @splat(.{}),
            .token = next_table_token.fetchAdd(1, .monotonic),
        };
        // Pre-size each shard because growth rehashes every string key.
        const ctx = IdContext{ .table = &table };
        for (&table.shards) |*s| {
            s.lookup.ensureTotalCapacityContext(allocator, 8192, ctx) catch {};
        }
        // Reserve id 0 as the empty string so `id == 0` is a valid "no string"
        // sentinel that `get` can resolve without touching the segments.
        const empty_id = try table.intern("");
        std.debug.assert(empty_id == 0);
        return table;
    }

    pub fn deinit(self: *InternTable) void {
        for (&self.shards) |*s| s.lookup.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn intern(self: *InternTable, s: []const u8) !InternId {
        const h = hashString(s);

        // Thread-local direct-mapped cache. Short identifiers get
        // re-interned repeatedly from many call sites (attr names,
        // builtin args, paths); a per-thread cache short-circuits the
        // shard lock + HashMap probe + segment lookup. Inline copy of
        // the bytes keeps the comparison branch-local (one cache line
        // per slot) instead of paying a `data.slice` indirection.
        if (threadCacheLookup(self.token, h, s)) |id| return id;

        const shard = &self.shards[h & shard_mask];

        if (!self.solo) shard.mu.lock();
        defer if (!self.solo) shard.mu.unlock();

        const ctx = IdContext{ .table = self };
        const adapter = StringAdapter{ .table = self, .precomputed_hash = h };
        const gop = try shard.lookup.getOrPutContextAdapted(self.allocator, s, adapter, ctx);
        if (gop.found_existing) {
            threadCacheStore(self.token, h, s, gop.key_ptr.*);
            return gop.key_ptr.*;
        }
        // The shard lock keeps this vacant slot private until its key is
        // initialized. If either backing-store allocation fails, remove it so
        // no uninitialized id remains reachable on a later lookup.
        errdefer shard.lookup.removeByPtr(gop.key_ptr);

        // The two stores commit independently: bytes come from a per-thread
        // TLAB (the store's write_mu is touched once per 8 KB chunk, not per
        // string), the entry append takes the entry store's own brief spin.
        // No cross-store adjacency is needed — if the entry append fails
        // (OOM path) the reserved bytes simply stay consumed. The old design
        // serialized EVERY miss from all 64 shards through one global
        // blocking mutex to make rollback exact; that mutex was the intern
        // convoy (63% of string-heavy w=8 CPU parked on it).
        const t = tlabs(self.token);
        const data_range = try self.data.reserveLocal(self.allocator, t.data, @intCast(s.len));
        const entry: Entry = .{
            .segment = data_range.segment,
            .offset = data_range.offset,
            .len = data_range.len,
        };
        const pending = .{
            .id = try self.entries.appendLocal(self.allocator, t.entry, entry),
            .data_range = data_range,
        };

        // Copying and map publication cannot fail. The commit mutex need not
        // cover the copy: no reader can discover the new id until the lookup
        // entry is installed below.
        @memcpy(self.data.sliceMut(pending.data_range), s);
        gop.key_ptr.* = pending.id;
        threadCacheStore(self.token, h, s, pending.id);
        return pending.id;
    }

    /// Look up `s` WITHOUT inserting: the id if `s` is already interned,
    /// else null. Serves read-only string→id crossings (dynamic attr
    /// select, hasAttr): every attr name is interned at construction, so
    /// a probe miss proves the attr cannot exist — and the miss leaves no
    /// permanent entry behind, unlike `intern`.
    pub fn probe(self: *InternTable, s: []const u8) ?InternId {
        const h = hashString(s);
        if (threadCacheLookup(self.token, h, s)) |id| return id;
        const shard = &self.shards[h & shard_mask];
        if (!self.solo) shard.mu.lock();
        defer if (!self.solo) shard.mu.unlock();
        const adapter = StringAdapter{ .table = self, .precomputed_hash = h };
        const id = shard.lookup.getKeyAdapted(s, adapter) orelse return null;
        threadCacheStore(self.token, h, s, id);
        return id;
    }

    pub fn get(self: *const InternTable, id: InternId) []const u8 {
        if (id == 0 or id >= self.entries.count()) return "";
        const entry = self.entries.get(id).*;
        if (entry.len == 0) return "";
        return self.data.slice(.{ .segment = entry.segment, .offset = entry.offset, .len = entry.len });
    }

    pub const Stats = struct {
        entries: u32,
        data_bytes: u32,
        shard_counts: [shard_count]u32,
        pub fn shardImbalance(self: Stats) f64 {
            if (self.entries == 0) return 0;
            const ideal = @as(f64, @floatFromInt(self.entries)) / @as(f64, @floatFromInt(shard_count));
            var max: u32 = 0;
            for (self.shard_counts) |c| max = @max(max, c);
            return @as(f64, @floatFromInt(max)) / @max(ideal, 1.0);
        }
    };

    pub fn stats(self: *const InternTable) Stats {
        var result: Stats = .{
            .entries = self.entries.count(),
            .data_bytes = self.data.count(),
            .shard_counts = @splat(0),
        };
        for (&self.shards, 0..) |*shard, i| {
            // Reading the shard's count is racy under concurrent intern,
            // but inspect runs after evaluation finishes when there are no
            // active writers.
            result.shard_counts[i] = @intCast(shard.lookup.count());
        }
        return result;
    }

    pub fn shardCount() u32 {
        return shard_count;
    }

    pub fn eql(_: *const InternTable, a: InternId, b: InternId) bool {
        return a == b;
    }

    /// Sort `entries` (any element type with an `InternId`-typed `name`
    /// field) lexicographically by the named string, byte-wise — the order
    /// Nix presents attrsets in. Fetching the string bytes inside the
    /// comparator costs two segment indirections per comparison (~n log n
    /// of them, cache-hostile); instead this extracts one integer sort key
    /// per element up front (a linear, in-id-order walk), sorts the dense
    /// key array with register compares, and permutes. Prefix ties (shared
    /// 8-byte prefix) fall back to full byte compares; distinct names never
    /// tie completely, so the sort's stability is irrelevant.
    pub fn sortByNameLex(
        self: *const InternTable,
        allocator: std.mem.Allocator,
        comptime T: type,
        entries: []T,
    ) !void {
        if (entries.len < 2) return;
        const Key = struct { prefix: u64, name: InternId, idx: u32 };
        const keys = try allocator.alloc(Key, entries.len);
        defer allocator.free(keys);
        for (keys, entries, 0..) |*key, entry, i| key.* = .{
            .prefix = stringPrefix(self.get(entry.name)),
            .name = entry.name,
            .idx = @intCast(i),
        };

        const Ctx = struct {
            table: *const InternTable,
            fn lessThan(ctx: @This(), a: Key, b: Key) bool {
                if (a.prefix != b.prefix) return a.prefix < b.prefix;
                if (a.name == b.name) return false;
                return std.mem.lessThan(u8, ctx.table.get(a.name), ctx.table.get(b.name));
            }
        };
        // Block sort, not pdq: interned-in-generation-order names (attr
        // storage order) yield long ascending prefix runs with periodic
        // drops ("k1".."k9" ascend, "k10" ranks back between "k1" and
        // "k2"); the merge-based block sort consumes such runs in O(n)
        // while pdq's partial-insertion heuristic measurably thrashes on
        // them (attrset-heavy bench, 2026-08).
        std.mem.sort(Key, keys, Ctx{ .table = self }, Ctx.lessThan);

        const scratch = try allocator.dupe(T, entries);
        defer allocator.free(scratch);
        for (entries, keys) |*entry, key| entry.* = scratch[key.idx];
    }
};

test "intern: round-trips and dedupes" {
    var table = try InternTable.init(std.testing.allocator);
    defer table.deinit();

    const a = try table.intern("hello");
    const b = try table.intern("world");
    const a2 = try table.intern("hello");
    try std.testing.expect(a != b);
    try std.testing.expectEqual(a, a2);
    try std.testing.expectEqualStrings("hello", table.get(a));
    try std.testing.expectEqualStrings("world", table.get(b));
}

test "intern: id 0 is empty sentinel" {
    var table = try InternTable.init(std.testing.allocator);
    defer table.deinit();

    try std.testing.expectEqualStrings("", table.get(0));
    const empty_id = try table.intern("");
    try std.testing.expectEqual(@as(InternId, 0), empty_id);
}

test "intern: sortByNameLex matches byte-wise order" {
    var table = try InternTable.init(std.testing.allocator);
    defer table.deinit();

    // Exercises: distinct prefixes, shared 8-byte prefix (tiebreak path),
    // strict-prefix pairs shorter and longer than the inline prefix, the
    // empty string, and an embedded NUL aliasing the zero padding.
    const inputs = [_][]const u8{
        "b",           "k10",        "ab\x00", "same8byteXY", "abc",
        "longprefixB", "k2",         "",       "a",           "k1",
        "same8byteXX", "longprefix", "ab",     "longprefixA",
    };
    const Named = struct { name: InternId };
    var entries: [inputs.len]Named = undefined;
    for (inputs, 0..) |s, i| entries[i] = .{ .name = try table.intern(s) };
    try table.sortByNameLex(std.testing.allocator, Named, &entries);
    for (entries[1..], entries[0 .. entries.len - 1]) |cur, prev| {
        try std.testing.expect(std.mem.lessThan(u8, table.get(prev.name), table.get(cur.name)));
    }
}

test "intern: distinguishes hash-colliding inputs" {
    var table = try InternTable.init(std.testing.allocator);
    defer table.deinit();

    const inputs = [_][]const u8{ "a", "b", "ab", "ba", "abc", "abcd" };
    var ids: [inputs.len]InternId = undefined;
    for (inputs, 0..) |s, i| ids[i] = try table.intern(s);
    for (inputs, 0..) |s, i| {
        try std.testing.expectEqualStrings(s, table.get(ids[i]));
        try std.testing.expectEqual(ids[i], try table.intern(s));
    }
}

test "intern: get is safe for slices borrowed from previous interns" {
    var table = try InternTable.init(std.testing.allocator);
    defer table.deinit();

    const path_id = try table.intern("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source/file.txt");
    const path = table.get(path_id);
    const base = path[path.len - "file.txt".len ..];
    const base_id = try table.intern(base);
    try std.testing.expectEqualStrings("file.txt", table.get(base_id));
}

test "intern: allocation failures never publish partial strings" {
    // A fresh table has an entry segment (for id 0) but no byte segment.
    // Failing that first byte allocation must leave every logical count and
    // lookup unchanged, and the same table must remain usable afterward.
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var table = try InternTable.init(failing.allocator());
        defer table.deinit();

        const before = table.stats();
        failing.fail_index = failing.alloc_index;
        const large: [4096]u8 = @splat('x');
        try std.testing.expectError(error.OutOfMemory, table.intern(&large));
        const after = table.stats();
        try std.testing.expectEqual(before.entries, after.entries);
        try std.testing.expectEqual(before.data_bytes, after.data_bytes);
        try std.testing.expect(table.probe(&large) == null);

        failing.fail_index = std.math.maxInt(usize);
        const id = try table.intern(&large);
        try std.testing.expectEqualStrings(&large, table.get(id));
        try std.testing.expectEqual(id, table.probe(&large).?);
    }

    // Fill entry segment 0, then fail allocation of segment 1 after the byte
    // reservation. commit_mu makes the rollback tail-safe even though lookup
    // maps are sharded.
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var table = try InternTable.init(failing.allocator());
        defer table.deinit();

        var buf: [16]u8 = undefined;
        while (table.entries.count() < EntryStore.first_segment_size) {
            const name = try std.fmt.bufPrint(&buf, "name-{d}", .{table.entries.count()});
            _ = try table.intern(name);
        }
        const before = table.stats();
        failing.fail_index = failing.alloc_index;
        try std.testing.expectError(error.OutOfMemory, table.intern("entry-segment-boundary"));
        const after = table.stats();
        try std.testing.expectEqual(before.entries, after.entries);
        try std.testing.expectEqual(before.data_bytes, after.data_bytes);
        try std.testing.expect(table.probe("entry-segment-boundary") == null);

        failing.fail_index = std.math.maxInt(usize);
        const id = try table.intern("entry-segment-boundary");
        try std.testing.expectEqualStrings("entry-segment-boundary", table.get(id));
        try std.testing.expectEqual(id, try table.intern("entry-segment-boundary"));
    }
}

test "intern: concurrent inserts dedupe correctly" {
    const allocator = std.testing.allocator;
    var table = try InternTable.init(allocator);
    defer table.deinit();

    const Worker = struct {
        fn run(tbl: *InternTable, seed: u64, count: u32) void {
            var rng = std.Random.DefaultPrng.init(seed);
            const r = rng.random();
            var buf: [16]u8 = undefined;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const n = r.intRangeAtMost(usize, 1, buf.len);
                // Pick from a small alphabet so workers collide on the same strings.
                for (buf[0..n]) |*b| b.* = 'a' + @as(u8, r.intRangeAtMost(u4, 0, 7));
                _ = tbl.intern(buf[0..n]) catch return;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &table, @as(u64, @intCast(i)) +% 1, @as(u32, 500) });
    }
    for (&threads) |t| t.join();

    // TLAB chunking leaves id-space gaps between per-thread blocks, so the
    // table's contract is only that RETURNED ids round-trip — re-intern a
    // deterministic sample of the strings the workers produced and check
    // ids stay stable and content-addressed.
    var rng = std.Random.DefaultPrng.init(1);
    const r = rng.random();
    var buf: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        const n = r.intRangeAtMost(usize, 1, buf.len);
        for (buf[0..n]) |*b| b.* = 'a' + @as(u8, r.intRangeAtMost(u4, 0, 7));
        const id = try table.intern(buf[0..n]);
        try std.testing.expectEqualStrings(buf[0..n], table.get(id));
        const again = try table.intern(buf[0..n]);
        try std.testing.expectEqual(id, again);
    }
}
