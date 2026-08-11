//! Append-only segmented storage with lock-free reads.
//!
//! Storage is divided into segments of geometrically growing size. Once a
//! segment is allocated, its backing array is never relocated. Readers
//! resolve `(segment, offset)` to a stable pointer via a single atomic load.
//! Writers serialize on `write_mu`.
//!
//! Two complementary APIs share the same backing storage:
//!   - `append(value) → u32 global_id`, `get(id) → *const T` — for single-slot
//!     entities indexed by a flat u32 id (e.g. Object slots).
//!   - `reserve(len) → Range`, `slice(range) → []const T` — for contiguous
//!     multi-slot reservations (e.g. list contents, attrset entries).
//!
//! The `T == void` instantiation is rejected at comptime; callers wanting
//! a byte arena should use `T = u8` and the `Range` API directly.

const std = @import("std");

const builtin = @import("builtin");
const BlockingMutex = @import("sync.zig").BlockingMutex;
const hugetlb = @import("hugetlb.zig");

/// `StableSegments` parameters, generic over the injected `Vma`
/// instantiation so `vma_tag` can name the app's attribution enum without
/// this generic store depending on the taxonomy (see runtime/vma.zig,
/// runtime/mem_tag.zig).
pub fn Params(comptime Vma: type) type {
    return struct {
        /// Size of segment 0 in slots. Must be a power of two ≥ 1.
        first_segment_size: u32,
        /// Cap on the number of segments. Total addressable slots is
        /// `first_segment_size * (2^segment_count - 1)`.
        segment_count: u6 = 28,
        /// RSS-attribution tag for this store's segments (see
        /// runtime/vma.zig): a claimed segment is re-tagged from the
        /// allocator's generic "bigblock" bucket to the store's own, so
        /// `--mem-report` can tell the stores apart. Only segments big
        /// enough to be dedicated mappings (≥64 KB) are tagged; smaller
        /// early segments ride allocator slabs and keep the slab's identity.
        vma_tag: ?Vma.Tag = null,
        /// Segments of at least this many bytes get their own 2 MB-aligned
        /// NORESERVE mapping with a chunk-wise-grown reserved-hugetlb prefix
        /// (the FlatStore scheme) instead of a fully-hugetlb-mapped
        /// allocator block. Geometric doubling makes the tail segment huge
        /// (64–256 MB) and mostly empty at peak, and an up-front hugetlb map
        /// bills the whole segment against the pool — mapped-but-untouched
        /// hugetlb is real pool consumption. 0 = off (every segment through
        /// the allocator, as before). Every cursor advance holds `write_mu`,
        /// so the frontier always covers a range before it is published.
        huge_overlay_min: usize = 0,
        /// TLAB refill chunk in SLOTS. One `write_mu` acquisition per this
        /// many reservations. Bigger chunks stripe ids/bytes into wider
        /// per-thread blocks — write-contention relief traded against the
        /// read-side locality of global temporal packing; size per store.
        tlab_chunk_slots: u32 = 8192,
        /// Structure-of-arrays second plane: each segment's single backing
        /// allocation holds `cap` slots of T followed by `cap` slots of this
        /// type, addressed by the SAME Range. `sliceSecond`/`getSecond` read
        /// the paired plane. T must have alignment >= the paired type's (the
        /// paired plane starts at cap*sizeOf(T) from the segment base). The
        /// hugetlb/populate frontiers cover only the T-plane prefix; the
        /// paired plane rides ordinary demand-paged memory.
        paired_second: ?type = null,
    };
}

pub fn StableSegments(comptime T: type, comptime params_in: anytype, comptime Vma: type) type {
    // `params_in` is an anonymous struct literal whose `vma_tag` (if any) is an
    // enum literal; copy it into a typed `Params(Vma)` so defaults apply and
    // `vma_tag` is resolved against the injected `Vma.Tag`. A struct value can't
    // coerce across the `anytype` boundary, so copy field-by-field.
    const params: Params(Vma) = blk: {
        var p: Params(Vma) = .{ .first_segment_size = params_in.first_segment_size };
        if (@hasField(@TypeOf(params_in), "segment_count")) p.segment_count = params_in.segment_count;
        if (@hasField(@TypeOf(params_in), "vma_tag")) p.vma_tag = params_in.vma_tag;
        if (@hasField(@TypeOf(params_in), "huge_overlay_min")) p.huge_overlay_min = params_in.huge_overlay_min;
        if (@hasField(@TypeOf(params_in), "tlab_chunk_slots")) p.tlab_chunk_slots = params_in.tlab_chunk_slots;
        if (@hasField(@TypeOf(params_in), "paired_second")) p.paired_second = params_in.paired_second;
        break :blk p;
    };
    comptime {
        if (T == void) @compileError("StableSegments(void) is unsupported");
        if (params.first_segment_size == 0) @compileError("first_segment_size must be > 0");
        if (!std.math.isPowerOfTwo(params.first_segment_size)) @compileError("first_segment_size must be a power of two");
        if (params.segment_count == 0 or params.segment_count > 32) @compileError("segment_count must be in 1..=32");
    }

    return struct {
        const Self = @This();

        pub const segment_count = params.segment_count;
        pub const first_segment_size = params.first_segment_size;
        const first_log2: u6 = std.math.log2_int(u32, params.first_segment_size);

        /// Total addressable slots. `segmentCapacity`/`segmentStart` are u32,
        /// so the geometry tops out where `first_segment_size << segment`
        /// stops fitting — NOT at `segment_count` (which for the byte store
        /// nominally allows 28 segments but is unreachable past 16). Past
        /// that point `segmentCapacity` truncates to 0 and every reservation
        /// fails with `error.OutOfMemory`, so callers that must collect
        /// before the store dies need this number, not the segment count.
        pub const capacity_slots: u32 = blk: {
            var seg: u32 = 0;
            while (seg < segment_count and
                (@as(u64, params.first_segment_size) << @intCast(seg)) <= std.math.maxInt(u32)) : (seg += 1)
            {}
            break :blk @intCast((@as(u64, params.first_segment_size) << @intCast(seg)) - params.first_segment_size);
        };

        pub const Range = struct {
            segment: u32,
            offset: u32,
            len: u32,
        };

        /// Per-worker bump cursor (a thread-local allocation buffer).
        /// Refilled a chunk at a time under `write_mu`; individual reservations
        /// bump the local cursor lock-free. Only the final partial chunk per
        /// worker is unused, so waste is bounded by one chunk per worker.
        pub const Tlab = struct { seg: u32 = 0, off: u32 = 0, used: u32 = 0, cap: u32 = 0 };
        pub const tlab_chunk_size: u32 = params.tlab_chunk_slots;

        /// Reserve `len` slots via `tlab`. Bumps the local cursor when
        /// the current chunk has room; otherwise refills one chunk under
        /// `write_mu` (or, for an oversized `len`, reserves it directly and
        /// leaves the chunk intact). Not thread-safe on a single `tlab` — each
        /// worker owns its own.
        pub fn reserveLocal(self: *Self, allocator: std.mem.Allocator, tlab: *Tlab, len: u32) !Range {
            if (len == 0) return .{ .segment = 0, .offset = 0, .len = 0 };
            if (tlab.used + len <= tlab.cap) {
                const r: Range = .{ .segment = tlab.seg, .offset = tlab.off + tlab.used, .len = len };
                tlab.used += len;
                return r;
            }
            if (len >= tlab_chunk_size) return self.reserve(allocator, len); // oversized: direct, keep tlab
            const chunk = try self.reserve(allocator, tlab_chunk_size);
            tlab.* = .{ .seg = chunk.segment, .off = chunk.offset, .used = len, .cap = chunk.len };
            return .{ .segment = chunk.segment, .offset = chunk.offset, .len = len };
        }

        /// Cursor packs (segment_index, used_in_segment) into one u64 so we can
        /// load it atomically. The writer mutex is the only mutator, so this
        /// could be plain u64; the atomic wrapper exists so opportunistic
        /// readers (e.g. `count()`) don't tear.
        cursor: std.atomic.Value(u64) = .init(0),
        segments: [segment_count]std.atomic.Value(?[*]T) = blk: {
            var arr: [segment_count]std.atomic.Value(?[*]T) = undefined;
            for (&arr) |*s| s.* = .init(null);
            break :blk arr;
        },
        // Parking, not spinning: since the TLAB round (c900176c) every
        // high-volume store reserves through per-thread TLABs, leaving
        // `write_mu` as the refill/cold lock — but refills do allocator and
        // hugetlb-frontier work while holding it, and burst contention (all
        // workers compiling chunks at eval start) convoys a naked spin.
        // Under TSan the spin storm starved the holder outright
        // (tsan/nixos-desktop w=16 livelock). Uncontended cost is identical
        // (one cmpxchg + release store).
        write_mu: BlockingMutex = .{},
        huge_policy: ?*hugetlb.Policy = null,

        // --- per-segment hugetlb overlay (`params.huge_overlay_min`) ---
        //
        // A self-mapped segment (see `ensureSegment`) is a 2 MB-aligned
        // NORESERVE mapping whose low `[0, seg_huge_frontier[i])` bytes are
        // overlaid with *reserved* hugetlb, grown a chunk at a time under
        // `write_mu` before the cursor moves past it — the exact FlatStore
        // scheme, per segment (see `FlatStore.extendHugeFrontier` for the
        // no-SIGBUS/no-data-loss argument). All zero/false when the feature
        // is off or a segment came from the allocator.
        seg_owned: [segment_count]bool = @splat(false),
        seg_huge_frontier: [segment_count]usize = @splat(0),
        seg_huge_off: [segment_count]bool = @splat(false),
        /// Ordinary-page counterpart to the hugetlb frontier. When a segment
        /// is not covered by a still-growing overlay, reservations grow this
        /// synchronously write-prefaulted prefix in coarse chunks.
        seg_populate_frontier: [segment_count]usize = @splat(0),
        seg_populate_off: [segment_count]bool = @splat(false),

        const overlay_enabled = params.huge_overlay_min > 0;
        const comptime_linux = builtin.os.tag == .linux;
        /// Overlay grow-ahead granularity (matches `FlatParams.huge_chunk`).
        const segment_huge_chunk_size: usize = 32 << 20;
        const segment_populate_chunk_size: usize = 32 << 20;

        pub const empty: Self = .{};

        pub fn setHugePolicy(self: *Self, policy: ?*hugetlb.Policy) void {
            self.huge_policy = policy;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (&self.segments, 0..) |*atom, i| {
                const ptr = atom.load(.monotonic) orelse continue;
                if (overlay_enabled and self.seg_owned[i]) {
                    if (comptime params.vma_tag != null) Vma.unregisterRegion(@ptrCast(ptr));
                    const bytes: [*]align(page_size_min) u8 = @ptrCast(@alignCast(ptr));
                    // One munmap covers the hugetlb-prefix + normal-tail VMAs;
                    // only the accounting needs to know the hugetlb share.
                    std.posix.munmap(bytes[0..segmentBytes(@intCast(i))]);
                    if (self.seg_huge_frontier[i] > 0) hugetlb.noteUnmapped(self.seg_huge_frontier[i]);
                    self.seg_owned[i] = false;
                    self.seg_huge_frontier[i] = 0;
                    self.seg_huge_off[i] = false;
                } else if (comptime paired_enabled) {
                    // Paired segments were allocated as raw bytes spanning
                    // both planes — free with the same shape.
                    const bytes: [*]align(@alignOf(T)) u8 = @ptrCast(@alignCast(ptr));
                    allocator.free(bytes[0 .. @as(usize, segmentCapacity(@intCast(i))) * slot_bytes]);
                } else {
                    allocator.free(ptr[0..segmentCapacity(@intCast(i))]);
                }
                atom.store(null, .monotonic);
                self.seg_populate_frontier[i] = 0;
                self.seg_populate_off[i] = false;
            }
            self.cursor.store(0, .monotonic);
        }

        /// Find and back one range while `write_mu` is held, without advancing
        /// the public cursor. Separating preparation from publication lets a
        /// batch initialize every slot before `count()` exposes any of them.
        fn prepareRangeLocked(self: *Self, allocator: std.mem.Allocator, len: u32) !Range {
            const cur = self.cursor.load(.monotonic);
            var seg = segmentOf(cur);
            var used = usedOf(cur);

            // Skip segments that can't fit `len` contiguous slots. We require
            // a reservation to live in a single segment so `slice` doesn't
            // need to stitch across boundaries.
            while (true) {
                const cap = segmentCapacity(seg);
                if (len > cap) {
                    if (seg + 1 >= segment_count) return error.OutOfMemory;
                    seg += 1;
                    used = 0;
                    continue;
                }
                if (used + len <= cap) break;
                if (seg + 1 >= segment_count) return error.OutOfMemory;
                seg += 1;
                used = 0;
            }

            try self.ensureSegment(allocator, seg);
            // Extend the segment's reserved-hugetlb prefix over the range
            // being handed out BEFORE the cursor moves (see the overlay
            // notes above) — while `write_mu` is held, nothing above the
            // frontier has been handed to any caller.
            if (comptime overlay_enabled)
                self.extendSegHugeFrontier(seg, (@as(usize, used) + len) * @sizeOf(T));
            self.extendSegPopulateFrontier(seg, (@as(usize, used) + len) * @sizeOf(T));

            return .{ .segment = seg, .offset = used, .len = len };
        }

        /// Reserve `len` consecutive slots. Caller initializes via `sliceMut`.
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, len: u32) !Range {
            if (len == 0) return .{ .segment = 0, .offset = 0, .len = 0 };

            self.write_mu.lock();
            defer self.write_mu.unlock();

            const range = try self.prepareRangeLocked(allocator, len);
            self.cursor.store(packCursor(range.segment, range.offset + range.len), .release);
            return range;
        }

        pub const DenseInitializeFn = *const fn (context: *anyopaque, first_id: u32, len: u32) anyerror!void;

        /// Initialize a dense flat-id batch before publishing it. Unlike a
        /// `Range`, the batch may cross segment boundaries: every id from
        /// `first_id` through `first_id + len - 1` is backed before `initialize`
        /// runs, so flat-id consumers never observe skipped segment tails.
        ///
        /// `write_mu` serializes every reservation path. If `initialize`
        /// fails, the cursor never moves and the whole batch remains invisible.
        pub fn appendDenseInitialized(
            self: *Self,
            allocator: std.mem.Allocator,
            len: u32,
            context: *anyopaque,
            initialize: DenseInitializeFn,
        ) !u32 {
            if (len == 0) return error.EmptyBatch;

            self.write_mu.lock();
            defer self.write_mu.unlock();

            const cur = self.cursor.load(.monotonic);
            var seg = segmentOf(cur);
            var used = usedOf(cur);
            const first_id = segmentStart(seg) + used;
            var remaining = len;
            while (remaining > 0) {
                const cap = segmentCapacity(seg);
                if (used == cap) {
                    if (seg + 1 >= segment_count) return error.OutOfMemory;
                    seg += 1;
                    used = 0;
                    continue;
                }
                const take = @min(remaining, cap - used);
                try self.ensureSegment(allocator, seg);
                if (comptime overlay_enabled)
                    self.extendSegHugeFrontier(seg, (@as(usize, used) + take) * @sizeOf(T));
                self.extendSegPopulateFrontier(seg, (@as(usize, used) + take) * @sizeOf(T));
                used += take;
                remaining -= take;
            }

            try initialize(context, first_id, len);
            self.cursor.store(packCursor(seg, used), .release);
            return first_id;
        }

        /// Append via a per-worker TLAB: `write_mu` is taken once per chunk
        /// refill instead of per append. Chunk remainders of abandoned tlabs
        /// become permanent id-space gaps — callers must only dereference
        /// ids they were returned (a gap id reads uninitialized memory).
        pub fn appendLocal(self: *Self, allocator: std.mem.Allocator, tlab: *Tlab, value: T) !u32 {
            const range = try self.reserveLocal(allocator, tlab, 1);
            const slot = self.segments[range.segment].load(.acquire).?;
            slot[range.offset] = value;
            return globalIdOf(range.segment, range.offset);
        }

        /// Append a single value. Returns its global u32 id.
        pub fn append(self: *Self, allocator: std.mem.Allocator, value: T) !u32 {
            self.write_mu.lock();
            defer self.write_mu.unlock();

            const range = try self.prepareRangeLocked(allocator, 1);
            const slot = self.segments[range.segment].load(.acquire).?;
            slot[range.offset] = value;
            self.cursor.store(packCursor(range.segment, range.offset + 1), .release);
            return globalIdOf(range.segment, range.offset);
        }

        /// Append for a caller that guarantees NO concurrent writer exists
        /// (a `--workers=1` evaluator): the same cursor/segment protocol with
        /// plain-cost monotonic accesses instead of taking `write_mu`.
        /// Concurrent readers (`get`/`count` from post-eval walkers) stay
        /// well-defined — monotonic keeps the accesses atomic,
        /// it just drops the RMW and fences.
        pub fn appendSerial(self: *Self, allocator: std.mem.Allocator, value: T) !u32 {
            const cur = self.cursor.load(.monotonic);
            var seg = segmentOf(cur);
            var used = usedOf(cur);
            if (used >= segmentCapacity(seg)) {
                if (seg + 1 >= segment_count) return error.OutOfMemory;
                seg += 1;
                used = 0;
            }
            try self.ensureSegment(allocator, seg);
            const slot = self.segments[seg].load(.monotonic).?;
            slot[used] = value;
            self.cursor.store(packCursor(seg, used + 1), .release);
            return globalIdOf(seg, used);
        }

        /// Re-tag a freshly-claimed segment's backing region for RSS
        /// attribution (no-op unless `params.vma_tag` is set and the
        /// segment is a dedicated mapping — see runtime/vma.zig).
        fn nameSegment(ptr: [*]T, bytes: usize) void {
            if (comptime params.vma_tag) |tag| {
                if (bytes < (64 << 10)) return;
                Vma.retagRegion(ptr, tag);
            }
        }

        /// Try to rewind the most recently reserved range. Returns false when
        /// another writer has advanced the cursor; callers that own a higher-
        /// level free list can then retain the range for reuse instead of
        /// silently stranding it.
        pub fn rollback(self: *Self, range: Range) bool {
            if (range.len == 0) return true;
            self.write_mu.lock();
            defer self.write_mu.unlock();
            const cur = self.cursor.load(.monotonic);
            const seg = segmentOf(cur);
            const used = usedOf(cur);
            if (seg == range.segment and used == range.offset + range.len) {
                self.cursor.store(packCursor(seg, range.offset), .release);
                return true;
            }
            return false;
        }

        pub fn slice(self: *const Self, range: Range) []const T {
            if (range.len == 0) return &.{};
            const seg_ptr = self.segments[range.segment].load(.acquire).?;
            return seg_ptr[range.offset .. range.offset + range.len];
        }

        pub fn sliceMut(self: *Self, range: Range) []T {
            if (range.len == 0) return &.{};
            const seg_ptr = self.segments[range.segment].load(.acquire).?;
            return seg_ptr[range.offset .. range.offset + range.len];
        }

        pub fn get(self: *const Self, id: u32) *const T {
            const loc = locationOf(id);
            const seg_ptr = self.segments[loc.segment].load(.acquire).?;
            return &seg_ptr[loc.offset];
        }

        /// `get`, tolerating a sparse id space. On an unallocated segment,
        /// advances `next_id` to the following segment and returns null.
        pub fn getIfAllocated(self: *const Self, id: u32, next_id: *u32) ?*const T {
            const loc = locationOf(id);
            const seg_ptr = self.segments[loc.segment].load(.acquire) orelse {
                next_id.* = segmentStart(loc.segment) + segmentCapacity(loc.segment);
                return null;
            };
            return &seg_ptr[loc.offset];
        }

        pub fn getMut(self: *Self, id: u32) *T {
            const loc = locationOf(id);
            const seg_ptr = self.segments[loc.segment].load(.acquire).?;
            return &seg_ptr[loc.offset];
        }

        /// Total elements appended/reserved. Approximate under concurrent
        /// writers (writers serialize, but cursor moves at the end of each
        /// reserve so an in-progress reservation isn't reflected).
        pub fn count(self: *const Self) u32 {
            const cur = self.cursor.load(.acquire);
            const seg = segmentOf(cur);
            const used = usedOf(cur);
            return segmentStart(seg) + used;
        }

        /// Translate a global id to (segment, offset).
        pub fn locationOf(id: u32) Range {
            // segment_start(i) = FIRST * (2^i - 1), so the segment containing
            // id is the largest i with segment_start(i) ≤ id. Equivalent:
            //   i = floor(log2((id / FIRST) + 1))
            const shifted = (id >> first_log2) + 1;
            const seg = 31 - @clz(shifted);
            const offset = id - segmentStart(@intCast(seg));
            return .{ .segment = @intCast(seg), .offset = offset, .len = 1 };
        }

        pub fn globalIdOf(segment: u32, offset: u32) u32 {
            return segmentStart(segment) + offset;
        }

        fn segmentCapacity(segment: u32) u32 {
            return params.first_segment_size << @intCast(segment);
        }

        fn segmentStart(segment: u32) u32 {
            // FIRST * (2^segment - 1)
            return (params.first_segment_size << @intCast(segment)) - params.first_segment_size;
        }

        fn ensureSegment(self: *Self, allocator: std.mem.Allocator, segment: u32) !void {
            if (self.segments[segment].load(.monotonic) != null) return;
            if (comptime overlay_enabled and comptime_linux) {
                if (self.mapOwnedSegment(segment)) return;
            }
            const cap = segmentCapacity(segment);
            if (comptime paired_enabled) {
                // One allocation, two planes: T plane first (keeps `slice`
                // and the overlay-prefix math unchanged), paired plane after.
                const raw = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(T)), @as(usize, cap) * slot_bytes);
                const ptr: [*]T = @ptrCast(@alignCast(raw.ptr));
                self.segments[segment].store(ptr, .release);
                nameSegment(ptr, @as(usize, cap) * slot_bytes);
            } else {
                const buf = try allocator.alloc(T, cap);
                self.segments[segment].store(buf.ptr, .release);
                nameSegment(buf.ptr, @as(usize, cap) * @sizeOf(T));
            }
        }

        pub const Paired: type = params.paired_second orelse void;
        const paired_enabled = params.paired_second != null;
        /// Bytes per slot across both planes (T alone when unpaired).
        /// Public: byte-accounting consumers (committed-RSS proxies) must
        /// see the true two-plane cost, not @sizeOf of any one element.
        pub const stored_slot_bytes: usize = @sizeOf(T) + (if (paired_enabled) @sizeOf(Paired) else 0);
        const slot_bytes: usize = stored_slot_bytes;

        fn segmentBytes(segment: u32) usize {
            return @as(usize, segmentCapacity(segment)) * slot_bytes;
        }

        /// Base of the paired plane inside `segment`: the T plane occupies
        /// the first cap*sizeOf(T) bytes of the single backing allocation.
        fn pairedBase(self: *const Self, segment: u32) [*]Paired {
            comptime std.debug.assert(paired_enabled);
            comptime std.debug.assert(@alignOf(T) >= @alignOf(Paired));
            const seg_ptr = self.segments[segment].load(.acquire).?;
            const bytes: [*]u8 = @ptrCast(seg_ptr);
            return @ptrCast(@alignCast(bytes + @as(usize, segmentCapacity(segment)) * @sizeOf(T)));
        }

        pub fn sliceSecond(self: *const Self, range: Range) []const Paired {
            if (range.len == 0) return &.{};
            const base = self.pairedBase(range.segment);
            return base[range.offset .. range.offset + range.len];
        }

        /// Paired-plane single-slot read; caller has already proven the id's
        /// segment allocated (a successful T-plane read of the same id).
        pub fn getSecondAssume(self: *const Self, id: u32) Paired {
            const loc = locationOf(id);
            return self.pairedBase(loc.segment)[loc.offset];
        }

        pub fn sliceSecondMut(self: *Self, range: Range) []Paired {
            if (range.len == 0) return &.{};
            const base = self.pairedBase(range.segment);
            return base[range.offset .. range.offset + range.len];
        }

        /// Self-map a big segment (see `Params.huge_overlay_min`): a
        /// 2 MB-aligned NORESERVE reservation whose hugetlb prefix
        /// `extendSegHugeFrontier` grows chunk-wise as the cursor advances.
        /// Returns false (caller falls back to the allocator, behavior
        /// unchanged) when the segment is small, hugetlb isn't engaged, the
        /// size doesn't split into whole huge pages, or the mmap fails.
        fn mapOwnedSegment(self: *Self, segment: u32) bool {
            const bytes = segmentBytes(segment);
            if (bytes < params.huge_overlay_min) return false;
            if (bytes % hugetlb.huge_page_size != 0) return false;
            const policy = self.huge_policy orelse return false;
            if (!policy.wanted()) return false;
            // Over-reserve by one huge page and trim to a 2 MB-aligned
            // window (a MAP_FIXED hugetlb overlay needs an aligned target).
            const mem = std.posix.mmap(
                null,
                bytes + hugetlb.huge_page_size,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
                -1,
                0,
            ) catch return false;
            const raw = @intFromPtr(mem.ptr);
            const base = std.mem.alignForward(usize, raw, hugetlb.huge_page_size);
            if (base > raw) {
                const head: [*]align(page_size_min) u8 = @ptrFromInt(raw);
                std.posix.munmap(head[0 .. base - raw]);
            }
            const tail_start = base + bytes;
            const tail_end = raw + bytes + hugetlb.huge_page_size;
            if (tail_end > tail_start) {
                const tail: [*]align(page_size_min) u8 = @ptrFromInt(tail_start);
                std.posix.munmap(tail[0 .. tail_end - tail_start]);
            }
            const seg_ptr: [*]T = @ptrFromInt(base);
            if (comptime params.vma_tag) |tag| Vma.registerRegion(@ptrCast(seg_ptr), bytes, tag);
            self.seg_owned[segment] = true;
            self.seg_huge_frontier[segment] = 0;
            self.seg_huge_off[segment] = false;
            self.segments[segment].store(seg_ptr, .release);
            return true;
        }

        /// Grow segment `segment`'s reserved-hugetlb prefix to cover at
        /// least `need_bytes` (plus a chunk of lookahead). Only meaningful
        /// under `write_mu` before the cursor is published — the FlatStore
        /// invariant, per segment: everything at or above the frontier is
        /// unhanded-out, so `overlayFixed`'s replace loses no data. Any
        /// failure stops growth for this segment permanently; its tail then
        /// lives on ordinary pages like a non-hugetlb run.
        fn extendSegHugeFrontier(self: *Self, segment: u32, need_bytes: usize) void {
            if (!self.seg_owned[segment] or self.seg_huge_off[segment]) return;
            const frontier = self.seg_huge_frontier[segment];
            if (need_bytes <= frontier) return;
            const limit = segmentBytes(segment); // whole huge pages by construction
            const want = @max(need_bytes, frontier +| segment_huge_chunk_size);
            const target = @min(std.mem.alignForward(usize, want, hugetlb.huge_page_size), limit);
            if (target <= frontier or target < need_bytes) {
                self.seg_huge_off[segment] = true;
                return;
            }
            const basep: [*]u8 = @ptrCast(self.segments[segment].load(.monotonic).?);
            if (hugetlb.overlayFixed(self.huge_policy.?, basep + frontier, target - frontier)) {
                self.seg_huge_frontier[segment] = target;
                if (target == limit) self.seg_huge_off[segment] = true;
            } else {
                // Pool exhausted (or shrank): the tail continues on normal
                // pages; data below the frontier stays on reserved pages.
                self.seg_huge_off[segment] = true;
            }
        }

        /// Ordinary-page analogue of `extendSegHugeFrontier`. Hugetlb already
        /// prefaults its mapped prefix; this path takes over for allocator-
        /// backed segments or after an overlay stops growing.
        fn extendSegPopulateFrontier(self: *Self, segment: u32, need_bytes: usize) void {
            if (comptime !comptime_linux) return;
            if (self.seg_populate_off[segment]) return;
            if (comptime overlay_enabled) {
                if (self.seg_owned[segment] and !self.seg_huge_off[segment]) return;
            }
            const limit = segmentBytes(segment);
            if (limit < (1 << 20)) {
                self.seg_populate_off[segment] = true;
                return;
            }
            const ptr = self.segments[segment].load(.monotonic) orelse return;
            const base = @intFromPtr(ptr);
            if (base & (page_size_min - 1) != 0) {
                self.seg_populate_off[segment] = true;
                return;
            }
            const frontier = @max(self.seg_populate_frontier[segment], self.seg_huge_frontier[segment]);
            if (need_bytes <= frontier) return;
            const want = @max(need_bytes, frontier +| segment_populate_chunk_size);
            const target = std.mem.alignForward(usize, @min(want, limit), page_size_min);
            if (target <= frontier) return;
            const addr: [*]align(page_size_min) u8 = @ptrFromInt(base + frontier);
            const madv_populate_write: u32 = 23;
            if (std.os.linux.errno(std.os.linux.madvise(addr, target - frontier, madv_populate_write)) != .SUCCESS) {
                self.seg_populate_off[segment] = true;
                return;
            }
            self.seg_populate_frontier[segment] = target;
        }

        fn packCursor(seg: u32, used: u32) u64 {
            return (@as(u64, seg) << 32) | @as(u64, used);
        }
        fn segmentOf(cur: u64) u32 {
            return @intCast(cur >> 32);
        }
        fn usedOf(cur: u64) u32 {
            return @intCast(cur & std.math.maxInt(u32));
        }
    };
}

pub fn FlatParams(comptime Vma: type) type {
    return struct {
        /// Virtual address space to reserve, in slots. The whole region is
        /// mapped up front (MAP_NORESERVE — only touched pages cost physical
        /// memory) and never relocated, so a slot's address is stable for the
        /// store's lifetime and reads need no synchronization on the base.
        max_slots: u32,
        /// RSS-attribution tag for the reservation (see `Params.vma_tag`);
        /// registered at init since the flat store owns its mmap directly.
        vma_tag: ?Vma.Tag = null,
        /// Hugetlb grow-ahead granularity (see `extendHugeFrontier`): the
        /// reserved huge-page prefix grows in chunks of this many bytes.
        /// Small enough that a run only over-reserves one chunk of pool
        /// (mapped-but-untouched hugetlb is real pool consumption — it
        /// counts against the footprint and starves other mappings), big
        /// enough to avoid frequent mmap+mremap overlays under `write_mu`.
        /// Tests shrink it to exercise frontier crossings on a small store.
        huge_chunk: usize = 32 << 20,
    };
}

/// Append-only flat storage backed by a single mmap-reserved contiguous
/// region. A drop-in replacement for `StableSegments` *for flat-id*
/// entities (the object store): `get(id)` is one load — `base[id]` — with
/// no segment decode, no per-access atomic. The trade vs `StableSegments`
/// is a fixed virtual reservation instead of geometric segment growth; it
/// only suits stores referenced solely by flat id (never via `Range`/
/// `slice` handed out externally).
///
/// Thread safety:
///   - `base` is set once in `init` (single-threaded, before any worker
///     spawns) and never changes, so `get`/`getMut` are plain loads.
///   - `reserve` bumps `cursor` under `write_mu`; concurrent readers only
///     ever touch ids already published through the value/state release
///     that made them reachable, which happens-after the slot was filled.
///
/// Huge pages: when hugetlb backing is engaged (base/hugetlb.zig), the low
/// bytes of the reservation are overlaid with *reserved* (non-NORESERVE)
/// 2 MB pages, grown chunk-wise ahead of the cursor under `write_mu` — see
/// `extendHugeFrontier` for the no-SIGBUS/no-data-loss invariants. Any
/// failure degrades that store's tail to ordinary pages.
pub fn FlatStore(comptime T: type, comptime params_in: anytype, comptime Vma: type) type {
    // See `StableSegments`: copy the anonymous literal into a typed
    // `FlatParams(Vma)` so `vma_tag` resolves against the injected `Vma.Tag`.
    const params: FlatParams(Vma) = blk: {
        var p: FlatParams(Vma) = .{ .max_slots = params_in.max_slots };
        if (@hasField(@TypeOf(params_in), "vma_tag")) p.vma_tag = params_in.vma_tag;
        if (@hasField(@TypeOf(params_in), "huge_chunk")) p.huge_chunk = params_in.huge_chunk;
        break :blk p;
    };
    comptime {
        if (T == void) @compileError("FlatStore(void) is unsupported");
        if (params.max_slots == 0) @compileError("max_slots must be > 0");
    }

    return struct {
        const Self = @This();

        pub const max_slots = params.max_slots;

        /// Range shape mirrors `StableSegments.Range` so the heap's TLAB
        /// code is store-agnostic. `segment` is always 0 here (one flat
        /// region); `offset` is the global id.
        pub const Range = struct {
            segment: u32,
            offset: u32,
            len: u32,
        };

        /// Base of the mmap-reserved region. Immutable after `init`.
        base: [*]T,
        /// Next free slot. Bumped under `write_mu`; loaded atomically by
        /// `count()` so an opportunistic reader doesn't tear.
        cursor: std.atomic.Value(u32),
        write_mu: BlockingMutex,
        huge_policy: ?*hugetlb.Policy,
        /// Hugetlb prefix frontier: bytes `[0, huge_frontier)` of the
        /// reservation are backed by reserved, DONTFORK, write-prefaulted
        /// huge pages, so pool/NUMA/cgroup failure can only fail a frontier
        /// extension (handled), never a later touch. Always a 2 MB multiple;
        /// mutated only under `write_mu`.
        huge_frontier: usize,
        /// Set when the prefix can't grow further (mode off, pool exhausted,
        /// or the overlayable range is used up): the rest of the store stays
        /// on ordinary 4 KB pages, permanently — which also upholds the
        /// overlay-never-covers-data invariant (see `extendHugeFrontier`).
        huge_grow_off: bool,

        const byte_count: usize = @as(usize, params.max_slots) * @sizeOf(T);
        /// Only whole huge pages can be overlaid; a sub-2 MB tail stays normal.
        const huge_limit: usize = std.mem.alignBackward(usize, byte_count, hugetlb.huge_page_size);
        const huge_chunk_size: usize = params.huge_chunk;

        pub fn init() !Self {
            return initWithPolicy(null);
        }

        pub fn initWithPolicy(policy: ?*hugetlb.Policy) !Self {
            var self: Self = .{
                .base = undefined,
                .cursor = .init(0),
                .write_mu = .{},
                .huge_policy = policy,
                .huge_frontier = 0,
                .huge_grow_off = true,
            };
            const use_huge = comptime_linux and huge_limit >= hugetlb.huge_page_size and
                byte_count % page_size_min == 0 and policy != null and policy.?.wanted();
            const mem: [*]align(page_size_min) u8 = if (use_huge) blk: {
                // A hugetlb overlay (MAP_FIXED) needs a 2 MB-aligned target,
                // so over-reserve by one huge page and trim to an aligned
                // window. Failure of the aligned dance falls through to the
                // plain mapping (`huge_grow_off` stays set).
                if (initAligned()) |ptr| {
                    self.huge_grow_off = false;
                    break :blk ptr;
                }
                break :blk try plainMap();
            } else try plainMap();
            // Best-effort transparent huge pages for the sequentially-grown
            // ordinary reservation, including the tail behind an explicit
            // hugetlb overlay. This is only a VMA policy hint: kernels without
            // THP support (or with THP disabled / unable to allocate one) keep
            // serving ordinary 4 KB anonymous pages from the same mapping.
            if (comptime comptime_linux) {
                const madv_hugepage: u32 = 14;
                _ = std.os.linux.madvise(mem, byte_count, madv_hugepage);
            }
            if (comptime params.vma_tag) |tag| Vma.registerRegion(mem, byte_count, tag);
            self.base = @ptrCast(@alignCast(mem));
            return self;
        }

        const comptime_linux = builtin.os.tag == .linux;

        fn plainMap() ![*]align(page_size_min) u8 {
            const mem = std.posix.mmap(
                null,
                byte_count,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
                -1,
                0,
            ) catch return error.OutOfMemory;
            return mem.ptr;
        }

        /// Reserve `byte_count` of ordinary NORESERVE address space whose base is
        /// 2 MB-aligned: map one huge page extra, trim the misaligned head
        /// and the surplus tail. Null on mmap failure (caller falls back).
        fn initAligned() ?[*]align(page_size_min) u8 {
            const mem = std.posix.mmap(
                null,
                byte_count + hugetlb.huge_page_size,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
                -1,
                0,
            ) catch return null;
            const raw = @intFromPtr(mem.ptr);
            const base = std.mem.alignForward(usize, raw, hugetlb.huge_page_size);
            if (base > raw) {
                const head: [*]align(page_size_min) u8 = @ptrFromInt(raw);
                std.posix.munmap(head[0 .. base - raw]);
            }
            const tail_start = base + byte_count;
            const tail_end = raw + byte_count + hugetlb.huge_page_size;
            if (tail_end > tail_start) {
                const tail: [*]align(page_size_min) u8 = @ptrFromInt(tail_start);
                std.posix.munmap(tail[0 .. tail_end - tail_start]);
            }
            return @ptrFromInt(base);
        }

        /// `allocator` is accepted for API parity with `StableSegments`
        /// (the heap calls `deinit(allocator)` uniformly); the flat store
        /// owns mmap memory, not allocator memory, so it's ignored.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator;
            if (comptime params.vma_tag != null) Vma.unregisterRegion(self.base);
            const bytes: [*]align(page_size_min) u8 = @ptrCast(@alignCast(self.base));
            // One munmap covers the mixed hugetlb-prefix + normal-tail VMAs
            // (both are whole VMAs within the range); only the accounting
            // needs to know how much of it was hugetlb.
            std.posix.munmap(bytes[0..byte_count]);
            if (self.huge_frontier > 0) hugetlb.noteUnmapped(self.huge_frontier);
            self.huge_frontier = 0;
            self.huge_grow_off = true;
            self.cursor.store(0, .monotonic);
        }

        /// Reserve `len` consecutive slots. `allocator` ignored (see
        /// `deinit`). The returned `Range.offset` is the global id of the
        /// first slot.
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, len: u32) !Range {
            _ = allocator;
            if (len == 0) return .{ .segment = 0, .offset = 0, .len = 0 };
            self.write_mu.lock();
            defer self.write_mu.unlock();
            const start = self.cursor.load(.monotonic);
            if (start > params.max_slots - len) return error.OutOfMemory;
            if (comptime comptime_linux) {
                if (!self.huge_grow_off) {
                    const end_bytes = @as(usize, start + len) * @sizeOf(T);
                    if (end_bytes > self.huge_frontier) self.extendHugeFrontier(end_bytes);
                }
            }
            self.cursor.store(start + len, .release);
            return .{ .segment = 0, .offset = start, .len = len };
        }

        /// Grow the reserved huge-page prefix to cover at least `need_bytes`
        /// (plus a chunk of lookahead) by overlaying `[huge_frontier,
        /// target)` with MAP_FIXED hugetlb. Called under `write_mu` *before*
        /// the cursor moves, which is what makes the overlay safe: while
        /// growth is on, every previously handed-out byte lies below
        /// `huge_frontier` (inductive — each reserve either fit under the
        /// frontier or extended it first), so the replaced range holds no
        /// data. Any failure (or running past `huge_limit`) permanently stops
        /// growth so the invariant can never be violated later; the store's
        /// tail then lives on normal pages exactly like a non-hugetlb run.
        fn extendHugeFrontier(self: *Self, need_bytes: usize) void {
            const want = @max(need_bytes, self.huge_frontier +| huge_chunk_size);
            const target = @min(std.mem.alignForward(usize, want, hugetlb.huge_page_size), huge_limit);
            if (target <= self.huge_frontier or target < need_bytes) {
                // Out of overlayable range (the ≥huge_limit tail): stop for good.
                self.huge_grow_off = true;
                return;
            }
            const basep: [*]u8 = @ptrCast(self.base);
            if (hugetlb.overlayFixed(self.huge_policy.?, basep + self.huge_frontier, target - self.huge_frontier)) {
                self.huge_frontier = target;
                if (target == huge_limit) self.huge_grow_off = true;
            } else {
                // Pool exhausted (or shrank): the tail continues on normal
                // pages. Data below the frontier stays on reserved huge
                // pages — still guaranteed by the kernel.
                self.huge_grow_off = true;
            }
        }

        pub fn get(self: *const Self, id: u32) *const T {
            return &self.base[id];
        }

        pub fn getMut(self: *Self, id: u32) *T {
            return &self.base[id];
        }

        /// Total slots reserved. Approximate under concurrent writers
        /// (cursor moves at reserve end, so an in-flight reserve isn't
        /// reflected) — same contract as `StableSegments.count`.
        pub fn count(self: *const Self) u32 {
            return self.cursor.load(.acquire);
        }

        /// Bytes of the reservation currently in use.
        pub fn usedBytes(self: *const Self) usize {
            return @as(usize, self.count()) * @sizeOf(T);
        }

        /// A flat store has a single region, so the global id IS the
        /// offset. `segment` must be 0 (the only value `reserve` produces).
        pub fn globalIdOf(segment: u32, offset: u32) u32 {
            std.debug.assert(segment == 0);
            return offset;
        }
    };
}

const page_size_min = std.heap.page_size_min;

/// A throwaway `Vma` instantiation for the tests below (none of which tag
/// their stores, so the taxonomy is irrelevant — they just need a type to
/// satisfy the `Vma` parameter).
const TestTag = enum { none };
const TestVma = @import("vma.zig").Vma(TestTag, .none, struct {
    fn n(_: TestTag) [:0]const u8 {
        return "none";
    }
}.n);

test "stable segments: append and get" {
    const allocator = std.testing.allocator;
    var seg = StableSegments(u32, .{ .first_segment_size = 4 }, TestVma).empty;
    defer seg.deinit(allocator);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const id = try seg.append(allocator, i * 7);
        try std.testing.expectEqual(i, id);
    }
    i = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectEqual(i * 7, seg.get(i).*);
    }
    try std.testing.expectEqual(@as(u32, 100), seg.count());
}

test "stable segments: reserve spans multiple segments" {
    const allocator = std.testing.allocator;
    var seg = StableSegments(u8, .{ .first_segment_size = 4 }, TestVma).empty;
    defer seg.deinit(allocator);

    const r1 = try seg.reserve(allocator, 3);
    try std.testing.expectEqual(@as(u32, 0), r1.segment);
    try std.testing.expectEqual(@as(u32, 0), r1.offset);
    try std.testing.expectEqual(@as(u32, 3), r1.len);

    // Segment 0 has 1 slot left; a reservation of len 2 must skip to segment 1.
    const r2 = try seg.reserve(allocator, 2);
    try std.testing.expectEqual(@as(u32, 1), r2.segment);
    try std.testing.expectEqual(@as(u32, 0), r2.offset);

    seg.sliceMut(r1)[0] = 0xAA;
    seg.sliceMut(r1)[1] = 0xBB;
    seg.sliceMut(r1)[2] = 0xCC;
    seg.sliceMut(r2)[0] = 0x11;
    seg.sliceMut(r2)[1] = 0x22;

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, seg.slice(r1));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22 }, seg.slice(r2));
}

test "stable segments: dense initialized batch crosses a segment boundary without holes" {
    const allocator = std.testing.allocator;
    const Store = StableSegments(u32, .{ .first_segment_size = 4 }, TestVma);
    var store = Store.empty;
    defer store.deinit(allocator);

    _ = try store.append(allocator, 10);
    _ = try store.append(allocator, 11);
    _ = try store.append(allocator, 12);

    const Initialize = struct {
        store: *Store,

        fn run(raw: *anyopaque, first_id: u32, len: u32) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            var i: u32 = 0;
            while (i < len) : (i += 1) self.store.getMut(first_id + i).* = 100 + first_id + i;
        }
    };
    var initialize: Initialize = .{ .store = &store };
    const first = try store.appendDenseInitialized(allocator, 4, &initialize, Initialize.run);

    try std.testing.expectEqual(@as(u32, 3), first);
    try std.testing.expectEqual(@as(u32, 7), store.count());
    var id: u32 = 0;
    while (id < store.count()) : (id += 1) {
        const expected: u32 = if (id < 3) 10 + id else 100 + id;
        try std.testing.expectEqual(expected, store.get(id).*);
    }
}

test "stable segments: rollback within current segment" {
    const allocator = std.testing.allocator;
    var seg = StableSegments(u32, .{ .first_segment_size = 8 }, TestVma).empty;
    defer seg.deinit(allocator);

    _ = try seg.append(allocator, 1);
    _ = try seg.append(allocator, 2);
    const r = try seg.reserve(allocator, 3);
    seg.sliceMut(r)[0] = 0xDEAD;
    try std.testing.expectEqual(@as(u32, 5), seg.count());

    try std.testing.expect(seg.rollback(r));
    try std.testing.expectEqual(@as(u32, 2), seg.count());

    const id3 = try seg.append(allocator, 99);
    try std.testing.expectEqual(@as(u32, 2), id3);
    try std.testing.expectEqual(@as(u32, 99), seg.get(2).*);
}

test "stable segments: rollback after segment-skip leaves earlier slots stranded" {
    const allocator = std.testing.allocator;
    var seg = StableSegments(u32, .{ .first_segment_size = 4 }, TestVma).empty;
    defer seg.deinit(allocator);

    _ = try seg.append(allocator, 1);
    _ = try seg.append(allocator, 2);
    // Segment 0 has 2 slots left; reserve(3) must skip to segment 1.
    const r = try seg.reserve(allocator, 3);
    try std.testing.expectEqual(@as(u32, 1), r.segment);

    // rollback rewinds within segment 1 but doesn't go back to segment 0.
    try std.testing.expect(seg.rollback(r));
    const next = try seg.append(allocator, 7);
    // next id lands in segment 1 at offset 0 → global id 4.
    try std.testing.expectEqual(@as(u32, 4), next);
}

test "stable segments: rollback reports a range displaced by another writer" {
    const allocator = std.testing.allocator;
    var seg = StableSegments(u32, .{ .first_segment_size = 8 }, TestVma).empty;
    defer seg.deinit(allocator);

    const first = try seg.reserve(allocator, 2);
    _ = try seg.reserve(allocator, 1);
    try std.testing.expect(!seg.rollback(first));
    try std.testing.expectEqual(@as(u32, 3), seg.count());
}

test "stable segments: locationOf round-trips" {
    const Seg = StableSegments(u32, .{ .first_segment_size = 4 }, TestVma);
    var id: u32 = 0;
    while (id < 200) : (id += 1) {
        const loc = Seg.locationOf(id);
        // FIRST * (2^seg - 1) <= id < FIRST * (2^(seg+1) - 1)
        const start: u32 = (@as(u32, 4) << @as(u5, @intCast(loc.segment))) - 4;
        const end: u32 = (@as(u32, 4) << @as(u5, @intCast(loc.segment + 1))) - 4;
        try std.testing.expect(start <= id);
        try std.testing.expect(id < end);
        try std.testing.expectEqual(id - start, loc.offset);
    }
}

test "stable segments: concurrent appends are race-free" {
    const Seg = StableSegments(u64, .{ .first_segment_size = 16 }, TestVma);
    const allocator = std.testing.allocator;
    var seg = Seg.empty;
    defer seg.deinit(allocator);

    const Worker = struct {
        fn run(s: *Seg, alloc: std.mem.Allocator, worker_id: u64, per_worker: u32) void {
            var i: u32 = 0;
            while (i < per_worker) : (i += 1) {
                _ = s.append(alloc, (worker_id << 32) | i) catch return;
            }
        }
    };

    const worker_count: u8 = 4;
    const per_worker: u32 = 250;
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &seg, allocator, @as(u64, @intCast(i)), per_worker });
    }
    for (&threads) |t| t.join();

    try std.testing.expectEqual(@as(u32, worker_count * per_worker), seg.count());

    // Every (worker, i) pair must be present exactly once.
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    var id: u32 = 0;
    while (id < seg.count()) : (id += 1) {
        const v = seg.get(id).*;
        try std.testing.expect(!seen.contains(v));
        try seen.put(v, {});
    }
    try std.testing.expectEqual(@as(usize, worker_count * per_worker), seen.count());
}

test "flat store: reserve, fill, get round-trip" {
    var store = try FlatStore(u64, .{ .max_slots = 4096 }, TestVma).init();
    defer store.deinit(std.testing.allocator);

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const r = try store.reserve(std.testing.allocator, 1);
        try std.testing.expectEqual(@as(u32, 0), r.segment);
        try std.testing.expectEqual(i, r.offset);
        store.getMut(r.offset).* = @as(u64, i) * 7;
    }
    try std.testing.expectEqual(@as(u32, 1000), store.count());
    i = 0;
    while (i < 1000) : (i += 1) {
        try std.testing.expectEqual(@as(u64, i) * 7, store.get(i).*);
    }
}

test "flat store: multi-slot reservation is contiguous" {
    const Store = FlatStore(u32, .{ .max_slots = 256 }, TestVma);
    var store = try Store.init();
    defer store.deinit(std.testing.allocator);

    const r1 = try store.reserve(std.testing.allocator, 3);
    try std.testing.expectEqual(@as(u32, 0), r1.offset);
    const r2 = try store.reserve(std.testing.allocator, 5);
    try std.testing.expectEqual(@as(u32, 3), r2.offset);
    try std.testing.expectEqual(@as(u32, 8), store.count());
    try std.testing.expectEqual(@as(u32, 5), Store.globalIdOf(0, 5));
}

test "flat store: reserve past capacity errors without relocating" {
    var store = try FlatStore(u32, .{ .max_slots = 8 }, TestVma).init();
    defer store.deinit(std.testing.allocator);

    const r = try store.reserve(std.testing.allocator, 8);
    try std.testing.expectEqual(@as(u32, 0), r.offset);
    try std.testing.expectError(error.OutOfMemory, store.reserve(std.testing.allocator, 1));
    // The successfully-reserved slots remain addressable after the failure.
    store.getMut(7).* = 0xDEAD;
    try std.testing.expectEqual(@as(u32, 0xDEAD), store.get(7).*);
}

test "flat store: hugetlb prefix — data intact across many frontier crossings" {
    if (comptime builtin.os.tag != .linux) return;
    // Force hugetlb on with a tiny 2 MB grow-ahead chunk over an 8 MB store,
    // so reserves cross the frontier several times. Whether the pool serves
    // the overlays (this box) or every extension fails (no pool: first
    // extension falls back, store behaves plainly), the data written before,
    // at, and after each crossing must round-trip — this is the invariant
    // that the MAP_FIXED overlay never covers handed-out slots.
    var policy = hugetlb.Policy.init(.on);

    const Store = FlatStore(u64, .{ .max_slots = 1 << 20, .huge_chunk = 2 << 20 }, TestVma);
    var store = try Store.initWithPolicy(&policy);
    defer store.deinit(std.testing.allocator);

    // Mixed-size reservations so range ends land on both sides of 2 MB lines.
    var next: u32 = 0;
    const lens = [_]u32{ 1, 7, 4093, 262144, 3, 262143, 65536 };
    var li: usize = 0;
    while (next < (1 << 20) - 262145) {
        const len = lens[li % lens.len];
        li += 1;
        const r = try store.reserve(std.testing.allocator, len);
        try std.testing.expectEqual(next, r.offset);
        const s = r.offset;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            store.getMut(s + i).* = @as(u64, s + i) *% 0x9E3779B97F4A7C15;
        }
        next += len;
    }
    var id: u32 = 0;
    while (id < next) : (id += 1) {
        try std.testing.expectEqual(@as(u64, id) *% 0x9E3779B97F4A7C15, store.get(id).*);
    }
}

test "flat store: concurrent reserves are race-free" {
    const Store = FlatStore(u64, .{ .max_slots = 4096 }, TestVma);
    var store = try Store.init();
    defer store.deinit(std.testing.allocator);

    const Worker = struct {
        fn run(s: *Store, worker_id: u64, per_worker: u32) void {
            var i: u32 = 0;
            while (i < per_worker) : (i += 1) {
                const r = s.reserve(std.testing.allocator, 1) catch return;
                s.getMut(r.offset).* = (worker_id << 32) | i;
            }
        }
    };

    const worker_count: u8 = 4;
    const per_worker: u32 = 250;
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &store, @as(u64, @intCast(i)), per_worker });
    }
    for (&threads) |t| t.join();

    try std.testing.expectEqual(@as(u32, worker_count * per_worker), store.count());

    var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer seen.deinit();
    var id: u32 = 0;
    while (id < store.count()) : (id += 1) {
        const v = store.get(id).*;
        try std.testing.expect(!seen.contains(v));
        try seen.put(v, {});
    }
    try std.testing.expectEqual(@as(usize, worker_count * per_worker), seen.count());
}

test "stable segments: capacity_slots is the reachable ceiling, not segment_count" {
    // `segmentCapacity` computes `first_segment_size << segment` in u32, and
    // Zig's `<<` truncates silently in every build mode. A store whose
    // nominal `segment_count` runs past that point can never use the extra
    // segments: `segmentCapacity` returns 0 there and every reservation
    // fails with error.OutOfMemory. `capacity_slots` reports where the
    // geometry actually stops.
    const Bytes = StableSegments(u8, .{ .first_segment_size = 65536, .segment_count = 28 }, TestVma);
    // 2^16 * (2^16 - 1): segments 0..15 are usable, 16..27 are unreachable.
    try std.testing.expectEqual(@as(u32, 4294901760), Bytes.capacity_slots);
    // Below maxInt(u32) — callers use that value as a sentinel.
    try std.testing.expect(Bytes.capacity_slots < std.math.maxInt(u32));

    // A store whose segment_count stops before the overflow keeps its
    // nominal geometry.
    const Small = StableSegments(u8, .{ .first_segment_size = 65536, .segment_count = 4 }, TestVma);
    try std.testing.expectEqual(@as(u32, 65536 * 15), Small.capacity_slots);

    // Wider elements hit the u32 id ceiling later (in slots, not bytes).
    const Vals = StableSegments(u64, .{ .first_segment_size = 8192, .segment_count = 28 }, TestVma);
    try std.testing.expectEqual(@as(u32, 8192 * ((1 << 19) - 1)), Vals.capacity_slots);
}
