//! Precise marker and collection metrics for the non-moving, generational,
//! stop-the-world collector. See `docs/gc.md` for the architecture and root
//! map.
//!
//! Without reclamation, the segmented stores track total allocation rather
//! than the live set. This module provides serial and parallel marking;
//! `heap/collector.zig` owns collection policy and reclamation; the evaluator
//! enumerates roots; the VM coordinates force-boundary safepoints. Parked peers
//! can assist both marking and sweeping.
//!
//! The `Tracer` follows exactly the heap edges described in `docs/gc.md`.

const std = @import("std");
const builtin = @import("builtin");
const containers = @import("base");
const clock = @import("base").clock;
const heap_mod = @import("heap.zig");
const heap_edges = @import("heap/edges.zig");
const heap_collector = @import("heap/collector.zig");
const RangeFreeList = @import("heap/reuse.zig").RangeFreeList;
const value_mod = @import("value.zig");
const thunk_mod = @import("thunk.zig");
const types = @import("types.zig");

const ObjectHeap = heap_mod.ObjectHeap;
const Value = value_mod.Value;
const ObjectId = types.ObjectId;
const future_mod = @import("future.zig");

/// The mark bitmap's natural locality unit: one word describes 64 adjacent
/// fixed-size object slots. Marking records object discovery in `mark_bits`
/// ("seen"), while the page worklist drains the corresponding word in address
/// order and records completion in `scanned_bits`. Queueing words instead of
/// individual graph edges lets discoveries accumulate and turns the graph
/// flood into mostly-linear object-store reads (the Green Tea GC shape).
const MarkPage = u32;
const objects_per_mark_page = 64;

/// Deferred scans of the two side stores that actually hold most graph edges.
/// They are exclusive ranges owned by one object, so unlike object pages they
/// need no seen/scanned bitmap: queueing the owning object's range exactly
/// once is sufficient.
const RangeWork = union(enum) {
    values: heap_mod.ValueRange,
    attrs: heap_mod.AttrRange,
};

/// Atomic queue slots need a scalar representation. Keep that transport detail
/// at the queue boundary instead of forcing the tracing domain union to adopt a
/// memory layout or leak tags into its consumers.
fn packRangeWork(work: RangeWork) u128 {
    const Fields = struct { tag: u128, segment: u128, offset: u128, len: u128 };
    const fields: Fields = switch (work) {
        .values => |range| .{ .tag = 0, .segment = range.segment, .offset = range.offset, .len = range.len },
        .attrs => |range| .{ .tag = 1, .segment = range.segment, .offset = range.offset, .len = range.len },
    };
    return fields.tag << 96 | fields.segment << 64 | fields.offset << 32 | fields.len;
}

fn unpackRangeWork(bits: u128) RangeWork {
    const segment: u32 = @truncate(bits >> 64);
    const offset: u32 = @truncate(bits >> 32);
    const len: u32 = @truncate(bits);
    return if (@as(u32, @truncate(bits >> 96)) == 0)
        .{ .values = .{ .segment = segment, .offset = offset, .len = len } }
    else
        .{ .attrs = .{ .segment = segment, .offset = offset, .len = len } };
}

test "range work atomic transport round-trips both variants" {
    const value_range: heap_mod.ValueRange = .{ .segment = 7, .offset = 11, .len = 13 };
    const attr_range: heap_mod.AttrRange = .{ .segment = 17, .offset = 19, .len = 23 };
    switch (unpackRangeWork(packRangeWork(.{ .values = value_range }))) {
        .values => |range| try std.testing.expectEqual(value_range, range),
        .attrs => return error.WrongRangeWorkTag,
    }
    switch (unpackRangeWork(packRangeWork(.{ .attrs = attr_range }))) {
        .attrs => |range| try std.testing.expectEqual(attr_range, range),
        .values => return error.WrongRangeWorkTag,
    }
}

/// 256 sixteen-byte descriptors make a 4 KiB sorting window: large enough to
/// expose physical locality without turning mark into a whole-live-set sort.
const range_batch_size = 256;

fn rangeWorkLessThan(_: void, a: RangeWork, b: RangeWork) bool {
    const a_tag = @backingInt(std.meta.activeTag(a));
    const b_tag = @backingInt(std.meta.activeTag(b));
    if (a_tag != b_tag) return a_tag < b_tag;
    return switch (a) {
        .values => |ar| blk: {
            const br = b.values;
            break :blk ar.segment < br.segment or
                (ar.segment == br.segment and ar.offset < br.offset);
        },
        .attrs => |ar| blk: {
            const br = b.attrs;
            break :blk ar.segment < br.segment or
                (ar.segment == br.segment and ar.offset < br.offset);
        },
    };
}

/// Live-set tally accumulated by one mark pass: object slots reached, the
/// value/attr/attr-pos store slots they own, and the total live bytes
/// (object slots + owned ranges).
pub const LiveStats = struct {
    objects: u64 = 0,
    values: u64 = 0,
    attrs: u64 = 0,
    attr_pos: u64 = 0,
    bytes: u64 = 0,

    /// Accumulate another tally (summing per-marker stats after a parallel mark).
    pub fn add(self: *LiveStats, other: LiveStats) void {
        self.objects += other.objects;
        self.values += other.values;
        self.attrs += other.attrs;
        self.attr_pos += other.attr_pos;
        self.bytes += other.bytes;
    }
};

/// Set the mark bit for `id` **atomically** (parallel mark: many markers may
/// race the same object). Returns true iff this call is the one that newly
/// set the bit — the caller then enqueues `id` for scanning, so exactly one
/// marker ever scans a given object. An atomic OR + old-bit test; `.acq_rel`
/// so a marker that loses the race still synchronizes-with the winner's write
/// (the winner will scan the object and mark its children).
fn atomicTestAndSet(mark_bits: []u64, id: ObjectId) bool {
    const word = id >> 6;
    if (word >= mark_bits.len) return false; // allocated after reset
    const mask = @as(u64, 1) << @intCast(id & 63);
    const prev = @atomicRmw(u64, &mark_bits[word], .Or, mask, .acq_rel);
    return prev & mask == 0;
}

fn atomicClaimPage(pending_pages: []u64, page: MarkPage) bool {
    const word = page >> 6;
    if (word >= pending_pages.len) return false;
    const mask = @as(u64, 1) << @intCast(page & 63);
    const prev = @atomicRmw(u64, &pending_pages[word], .Or, mask, .acq_rel);
    return prev & mask == 0;
}

fn atomicReleasePage(pending_pages: []u64, page: MarkPage) void {
    const word = page >> 6;
    const mask = @as(u64, 1) << @intCast(page & 63);
    _ = @atomicRmw(u64, &pending_pages[word], .And, ~mask, .acq_rel);
}

/// One parallel marker: a private never-drop page worklist
/// (`GrowableDeque` — a dropped page can strand reachable descendants) plus a
/// private `LiveStats` tally
/// (summed after termination; a shared atomic per object would cache-line
/// bounce and erase the parallel win). All markers share the one atomic
/// seen bitmap (`mark_bits`), scanned bitmap, and queued/in-flight page bitmap.
///
/// `Marker` doubles as a `heap_edges.walkObject` sink. Its small adapter
/// surface keeps the graph shape independent from the parallel queue policy.
pub const Marker = struct {
    pub const Error = error{};

    deque: containers.GrowableDeque(MarkPage),
    ranges: containers.GrowableDeque(u128),
    stats: LiveStats = .{},
    /// Shared with every other marker and the Tracer; set in `resetParallel`.
    mark_bits: []u64 = &.{},
    scanned_bits: []u64 = &.{},
    pending_pages: []u64 = &.{},
    allocator: std.mem.Allocator,
    /// Minor-collection young-gate (set by `resetParallelMinor`): stop the
    /// trace at old objects. Matches `Tracer.minor_gate` for the serial path.
    minor_gate: bool = false,

    inline fn markValue(self: *Marker, heap: *const ObjectHeap, v: Value) void {
        if (hasObjectRef(v)) self.markObject(heap, v.asObjectId());
    }
    inline fn markObject(self: *Marker, heap: *const ObjectHeap, id: ObjectId) void {
        // Minor collection: the trace stops at old objects (their young
        // referents arrive via the remembered set). Same gate as the serial
        // `Tracer.markObject`, so parallel and serial minors agree.
        if (self.minor_gate and !heap.gcIsYoung(id)) return;
        if (!atomicTestAndSet(self.mark_bits, id)) return;
        self.enqueuePage(@intCast(id >> 6));
    }
    inline fn enqueuePage(self: *Marker, page: MarkPage) void {
        // The worklist is correctness metadata. Only the thread whose Marker
        // this is pushes its deque; peers consume through `steal`.
        if (atomicClaimPage(self.pending_pages, page))
            self.deque.push(self.allocator, page) catch @panic("gc parallel mark worklist exhausted");
    }
    inline fn scanValues(self: *Marker, _: *const ObjectHeap, range: heap_mod.ValueRange) void {
        self.ranges.push(self.allocator, packRangeWork(.{ .values = range })) catch @panic("gc parallel range worklist exhausted");
    }
    inline fn scanAttrs(self: *Marker, _: *const ObjectHeap, range: heap_mod.AttrRange) void {
        self.ranges.push(self.allocator, packRangeWork(.{ .attrs = range })) catch @panic("gc parallel range worklist exhausted");
    }
    fn scanRange(self: *Marker, heap: *const ObjectHeap, work: RangeWork) void {
        scanRangeWork(Marker, self, heap, work);
    }
    fn scanPage(self: *Marker, heap: *const ObjectHeap, page: MarkPage) void {
        const wi: usize = @intCast(page);
        const seen = @atomicLoad(u64, &self.mark_bits[wi], .acquire);
        const scanned = @atomicLoad(u64, &self.scanned_bits[wi], .monotonic);
        const active = seen & ~scanned;
        if (active != 0) {
            @atomicStore(u64, &self.scanned_bits[wi], scanned | active, .release);
            scanMarkedWord(Marker, self, heap, page, active);
        }

        // Close the page only after every object in our snapshot was scanned.
        // A marker that discovered another object while the page was pending
        // deliberately did not enqueue it. The post-release check catches that
        // case; a discovery after the check observes pending=false and queues
        // the page itself. Thus no seen object can be stranded between states.
        atomicReleasePage(self.pending_pages, page);
        const seen_after = @atomicLoad(u64, &self.mark_bits[wi], .acquire);
        const scanned_after = @atomicLoad(u64, &self.scanned_bits[wi], .acquire);
        if (seen_after & ~scanned_after != 0) self.enqueuePage(page);
    }
    inline fn countObject(self: *Marker) void {
        self.stats.objects += 1;
        self.stats.bytes += @sizeOf(heap_mod.Object);
    }
    inline fn countValues(self: *Marker, n: u64) void {
        self.stats.values += n;
        self.stats.bytes += n * @sizeOf(Value);
    }
    inline fn countAttrs(self: *Marker, n: u64) void {
        self.stats.attrs += n;
        self.stats.bytes += n * @sizeOf(heap_mod.AttrEntry);
    }
    inline fn countAttrPos(self: *Marker, n: u64) void {
        self.stats.attr_pos += n;
        self.stats.bytes += n * @sizeOf(heap_mod.AttrPosEntry);
    }

    pub inline fn objectSlot(self: *Marker) Error!void {
        self.countObject();
    }
    pub inline fn object(self: *Marker, heap: *const ObjectHeap, id: ObjectId) Error!void {
        self.markObject(heap, id);
    }
    pub inline fn chunk(_: *Marker, _: types.ChunkId) Error!void {}
    pub inline fn value(self: *Marker, heap: *const ObjectHeap, child: Value) Error!void {
        self.markValue(heap, child);
    }
    pub inline fn valueRange(self: *Marker, heap: *const ObjectHeap, range: heap_mod.ValueRange) Error!void {
        self.scanValues(heap, range);
    }
    pub inline fn attrRange(self: *Marker, heap: *const ObjectHeap, range: heap_mod.AttrRange) Error!void {
        self.scanAttrs(heap, range);
    }
    pub inline fn attrPositions(self: *Marker, positions: heap_mod.AttrPositions) Error!void {
        self.countAttrPos(positions.heapLen());
    }
    pub inline fn capturedValues(self: *Marker, heap: *const ObjectHeap, values: []const Value, owns_range: bool) Error!void {
        if (owns_range) self.countValues(values.len);
        for (values) |child| self.markValue(heap, child);
    }
};

/// Precise marker over the heap object graph. Both serial and parallel paths
/// use the same two-phase batching model: adjacent objects in ObjectId order
/// within each mark page, then bounded value/attribute batches in physical
/// store order. No native recursion is involved.
pub const Tracer = struct {
    allocator: std.mem.Allocator,
    /// One bit per ObjectId; bit set == marked. Shared (aliased) by every
    /// `Marker` in the parallel path; set with `atomicTestAndSet` there.
    mark_bits: []u64 = &.{},
    /// One bit per ObjectId; bit set == its outgoing edges were scanned.
    scanned_bits: []u64 = &.{},
    /// One bit per mark page; bit set == queued or currently being scanned.
    pending_pages: []u64 = &.{},
    /// Serial (`--workers=1`) FIFO worklists. Parallel marking uses the same
    /// payloads in each Marker's stealable deques.
    pages: std.ArrayListUnmanaged(MarkPage) = .empty,
    ranges: std.ArrayListUnmanaged(RangeWork) = .empty,
    stats: LiveStats = .{},

    // --- parallel mark (`--workers>1`; see resetParallel/drainParallel) ---
    /// One `Marker` per worker (slot == worker_id). Allocated lazily on the
    /// first parallel collection and reused across collections (deques keep
    /// their grown capacity; `resetParallel` just clears them).
    markers: []Marker = &.{},
    /// Number of markers participating in the current collection (== worker
    /// count). Termination target for `active_idle`.
    marker_count: u32 = 0,
    /// Work-stealing termination counter (HotSpot ParallelTaskTerminator
    /// shape): count of markers currently offering termination. Mark is done
    /// iff this reaches `marker_count` — which can only happen when every
    /// deque is empty and no scan is in flight (a producing marker is active,
    /// hence not offering). Bumped per idle-transition, NOT per object.
    /// INVARIANT: a marker must count itself ACTIVE (retracted) for the entire
    /// window in which it holds or scans stolen work — see `drainParallel`'s
    /// idle loop, which retracts before probing. Scanning while counted idle
    /// would let a peer observe a spurious all-idle and abandon pushed children.
    active_idle: std.atomic.Value(u32) = .init(0),
    /// When non-null, `markObject`/`markValue` seed into this marker's deque
    /// (atomic bitmap) instead of the serial page FIFO. Set only by the lone
    /// collector during the single-threaded root-scan (`beginSeeding`), so a
    /// plain field — no concurrency — is safe.
    parallel_seed: ?*Marker = null,
    /// Minor-collection mode: when armed, `markObject` stops
    /// at OLD objects — the mark reaches only the young generation. Old objects
    /// are assumed live; the young objects they reference arrive via the
    /// remembered set (`markRemsetSource`), not by tracing through old.
    minor_gate: bool = false,

    pub fn init(allocator: std.mem.Allocator) Tracer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tracer) void {
        self.allocator.free(self.mark_bits);
        self.allocator.free(self.scanned_bits);
        self.allocator.free(self.pending_pages);
        self.pages.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
        for (self.markers) |*m| {
            m.deque.deinit(self.allocator);
            m.ranges.deinit(self.allocator);
        }
        self.allocator.free(self.markers);
    }

    /// Prepare for a fresh mark over `[0, object_count)`: grow + clear all
    /// seen/scanned/page-state bitmaps and empty the serial FIFOs.
    pub fn reset(self: *Tracer, object_count: u32) !void {
        const words = (@as(usize, object_count) + 63) >> 6;
        if (words > self.mark_bits.len)
            self.mark_bits = try self.allocator.realloc(self.mark_bits, words);
        if (words > self.scanned_bits.len)
            self.scanned_bits = try self.allocator.realloc(self.scanned_bits, words);
        const page_words = (words + 63) >> 6;
        if (page_words > self.pending_pages.len)
            self.pending_pages = try self.allocator.realloc(self.pending_pages, page_words);
        @memset(self.mark_bits[0..words], 0);
        @memset(self.scanned_bits[0..words], 0);
        @memset(self.pending_pages[0..page_words], 0);
        self.pages.clearRetainingCapacity();
        self.ranges.clearRetainingCapacity();
        self.stats = .{};
    }

    /// Set the mark bit for `id`; return true if it was newly set (caller
    /// then pushes it for scanning).
    fn testAndSet(self: *Tracer, id: ObjectId) bool {
        const word = id >> 6;
        if (word >= self.mark_bits.len) return false; // allocated after reset
        const mask = @as(u64, 1) << @intCast(id & 63);
        if (self.mark_bits[word] & mask != 0) return false;
        self.mark_bits[word] |= mask;
        return true;
    }

    fn queuePage(self: *Tracer, page: MarkPage) void {
        const word: usize = @intCast(page >> 6);
        const mask = @as(u64, 1) << @intCast(page & 63);
        if (self.pending_pages[word] & mask != 0) return;
        self.pending_pages[word] |= mask;
        self.pages.append(self.allocator, page) catch @panic("gc serial mark worklist exhausted");
    }

    fn scanPage(self: *Tracer, sink: *SerialSink, heap: *const ObjectHeap, page: MarkPage) void {
        const wi: usize = @intCast(page);
        const active = self.mark_bits[wi] & ~self.scanned_bits[wi];
        self.scanned_bits[wi] |= active;
        scanMarkedWord(SerialSink, sink, heap, page, active);

        const pending_word: usize = @intCast(page >> 6);
        const pending_mask = @as(u64, 1) << @intCast(page & 63);
        self.pending_pages[pending_word] &= ~pending_mask;
        if (self.mark_bits[wi] & ~self.scanned_bits[wi] != 0)
            self.queuePage(page);
    }

    /// Is `id` already marked? (Oracle: detect what precise roots missed.)
    pub fn isMarked(self: *const Tracer, id: ObjectId) bool {
        const word = id >> 6;
        if (word >= self.mark_bits.len) return false;
        return self.mark_bits[word] & (@as(u64, 1) << @intCast(id & 63)) != 0;
    }

    /// Mark the heap object a Value references, if any. Non-heap Values
    /// (int/float/bool/null/string/path/builtin) are ignored.
    pub fn markValue(self: *Tracer, heap: *const ObjectHeap, v: Value) void {
        if (!hasObjectRef(v)) return;
        self.markObject(heap, v.asObjectId());
    }

    /// Mark `id` for later scanning. The caller runs `drain`/`drainParallel`
    /// once after all roots are marked, so the graph is walked iteratively
    /// (the worklist), never by native recursion. During a parallel
    /// collection's single-threaded root-scan, `parallel_seed` is set and the
    /// root is seeded into that marker's deque instead of the serial stack.
    pub fn markObject(self: *Tracer, heap: *const ObjectHeap, id: ObjectId) void {
        // Minor collection: the trace stops at old objects (they're live; their
        // young referents come via the remembered set). Young-only keeps the
        // pause proportional to the young survivors, not the whole heap.
        if (self.minor_gate and !heap.gcIsYoung(id)) return;
        if (self.parallel_seed) |m| {
            m.markObject(heap, id);
            return;
        }
        if (!self.testAndSet(id)) return;
        self.queuePage(@intCast(id >> 6));
    }

    /// Serial drain (`--workers=1`): alternate complete FIFO batches of object
    /// pages and owned side-store ranges. Range scans discover pages; page
    /// scans discover ranges. Keeping the phases distinct lets marks for the
    /// same page accumulate before it is revisited.
    pub fn drain(self: *Tracer, heap: *const ObjectHeap) void {
        var sink = SerialSink{ .tr = self };
        var page_head: usize = 0;
        var range_head: usize = 0;
        while (page_head < self.pages.items.len or range_head < self.ranges.items.len) {
            while (page_head < self.pages.items.len) : (page_head += 1)
                self.scanPage(&sink, heap, self.pages.items[page_head]);
            const range_end = @min(range_head + range_batch_size, self.ranges.items.len);
            std.mem.sort(RangeWork, self.ranges.items[range_head..range_end], {}, rangeWorkLessThan);
            while (range_head < range_end) : (range_head += 1)
                sink.scanRange(heap, self.ranges.items[range_head]);
        }
    }

    // --- minor collection (young-gated) ---

    /// Prepare a young-gated mark over `[0, object_count)`.
    pub fn resetMinor(self: *Tracer, object_count: u32) !void {
        try self.reset(object_count);
        self.minor_gate = true;
    }

    /// Seed the young referents of a remembered old `source` (an old→young
    /// edge). Scans the source's outgoing edges via the canonical trace map;
    /// young children are marked+queued (the gate drops old ones), and the old
    /// source itself is never added to the live set. Call for each remembered
    /// source before `drainMinor`.
    pub fn markRemsetSource(self: *Tracer, heap: *const ObjectHeap, source: ObjectId) void {
        if (self.parallel_seed) |marker| {
            heap_edges.walkObject(Marker, marker, heap, source) catch unreachable;
            return;
        }
        var sink = SerialSink{ .tr = self };
        heap_edges.walkObject(SerialSink, &sink, heap, source) catch unreachable;
    }

    /// Drain the young-gated mark to its transitive closure, then disarm the
    /// gate.
    pub fn drainMinor(self: *Tracer, heap: *const ObjectHeap) void {
        self.drain(heap);
        self.minor_gate = false;
    }

    // --- major collection (full, non-gated mark) ---

    /// Prepare a FULL mark over `[0, object_count)`: like `reset`, but also
    /// clears the young-gate (a prior parallel minor may have left it armed) and
    /// the parallel-seed hook, so the serial mark traces the whole graph —
    /// through old objects, not just the young generation.
    pub fn resetMajor(self: *Tracer, object_count: u32) !void {
        try self.reset(object_count);
        self.minor_gate = false;
        self.parallel_seed = null;
    }

    // --- parallel mark ---

    /// Prepare for a parallel mark over `[0, object_count)` with `marker_count`
    /// markers (== worker count). Grows + clears the shared bitmap, (re)sizes
    /// the marker roster reusing deques across collections, clears each deque
    /// and per-marker stats, and resets the termination counter. Call at a
    /// stop-the-world safepoint, before seeding roots.
    pub fn resetParallel(self: *Tracer, object_count: u32, marker_count: u32) !void {
        const words = (@as(usize, object_count) + 63) >> 6;
        if (words > self.mark_bits.len)
            self.mark_bits = try self.allocator.realloc(self.mark_bits, words);
        if (words > self.scanned_bits.len)
            self.scanned_bits = try self.allocator.realloc(self.scanned_bits, words);
        const page_words = (words + 63) >> 6;
        if (page_words > self.pending_pages.len)
            self.pending_pages = try self.allocator.realloc(self.pending_pages, page_words);
        @memset(self.mark_bits[0..words], 0);
        @memset(self.scanned_bits[0..words], 0);
        @memset(self.pending_pages[0..page_words], 0);
        self.stats = .{};
        // Grow the roster once (worker count is fixed within a run); reuse
        // the deques (with their grown capacity) on later collections.
        if (self.markers.len < marker_count) {
            const old = self.markers.len;
            self.markers = try self.allocator.realloc(self.markers, marker_count);
            for (self.markers[old..]) |*m| m.* = .{
                .deque = try containers.GrowableDeque(MarkPage).init(self.allocator, 1024),
                .ranges = try containers.GrowableDeque(u128).init(self.allocator, 1024),
                .allocator = self.allocator,
            };
        }
        for (self.markers[0..marker_count]) |*m| {
            m.deque.clear();
            m.ranges.clear();
            m.stats = .{};
            m.mark_bits = self.mark_bits;
            m.scanned_bits = self.scanned_bits;
            m.pending_pages = self.pending_pages;
            // Default to a FULL (non-gated) mark; `resetParallelMinor` re-arms
            // the gate. Without this a parallel major inherits a leftover
            // young-gate from the previous minor and misses old objects.
            m.minor_gate = false;
        }
        self.marker_count = marker_count;
        self.active_idle = .init(0);
        self.parallel_seed = null;
        self.minor_gate = false;
    }

    /// Like `resetParallel` but young-gated (minor collection): the serial
    /// root-seed path (`Tracer.markObject`) and every parallel `Marker` stop the
    /// trace at old objects. Roots + remembered-set seeds reach the young set;
    /// old objects are assumed live.
    pub fn resetParallelMinor(self: *Tracer, object_count: u32, marker_count: u32) !void {
        try self.resetParallel(object_count, marker_count);
        self.minor_gate = true;
        for (self.markers[0..marker_count]) |*m| m.minor_gate = true;
    }

    /// Seed subsequent `markObject`/`markValue` root marks into marker `id`'s
    /// deque (collector-only, single-threaded). Paired with `endSeeding`.
    pub fn beginSeeding(self: *Tracer, id: usize) void {
        self.parallel_seed = &self.markers[id];
    }
    pub fn endSeeding(self: *Tracer) void {
        self.parallel_seed = null;
    }

    /// Parallel marker `id`: drain own deque FIFO, steal from peers when
    /// empty, and cooperatively detect termination. Returns only when the
    /// whole mark is complete (`active_idle == marker_count`). Safe to run on
    /// every worker concurrently. See the `active_idle` field for the
    /// termination-correctness argument.
    pub fn drainParallel(self: *Tracer, heap: *const ObjectHeap, id: usize) void {
        const me = &self.markers[id];
        while (true) {
            // Phase A: consume complete FIFO batches of object pages, then
            // side-store ranges. Each phase produces the other kind of work,
            // allowing both page marks and adjacent range scans to accumulate.
            var did_work = false;
            while (me.deque.steal()) |page| me.scanPage(heap, page);
            var range_batch: [range_batch_size]RangeWork = undefined;
            var range_count: usize = 0;
            while (range_count < range_batch.len) : (range_count += 1) {
                range_batch[range_count] = unpackRangeWork(me.ranges.steal() orelse break);
            }
            if (range_count != 0) {
                did_work = true;
                std.mem.sort(RangeWork, range_batch[0..range_count], {}, rangeWorkLessThan);
                for (range_batch[0..range_count]) |work| me.scanRange(heap, work);
            }
            if (did_work or me.deque.approxLen() > 0) continue;
            // Phase B: our deque is empty. Try to steal one item and scan it;
            // if that fails, offer termination. We are still ACTIVE here (not
            // yet counted idle), so scanning the stolen item — which pushes
            // children into our deque — is safe.
            if (self.stealOneAndScan(heap, id)) continue;
            _ = self.active_idle.fetchAdd(1, .acq_rel); // announce idle
            while (true) {
                if (self.active_idle.load(.acquire) == self.marker_count) return; // all done
                // CORRECTNESS: while offering termination we only PEEK peers for
                // work (a non-removing size probe) — we never steal-and-scan
                // here. A scan pushes children; doing it while counted idle let
                // a peer observe `active_idle == marker_count` mid-scan and
                // terminate the whole mark, abandoning those children — a live
                // object left unmarked, then swept by the minor (the w>1 UAF /
                // free-list corruption). On seeing work we RETRACT to active
                // first, then break back to the active steal-and-scan path
                // (Phase B above), so no scan is ever in flight while we're
                // idle. Invariant restored: termination observed ⇒ every deque
                // empty (an idle marker drained its own in Phase A; a non-empty
                // deque belongs to an active, non-offering marker) AND no scan
                // in flight. A stale peek (item stolen before we re-steal) just
                // costs a retract + re-idle; peeking (not stealing) keeps us
                // counted idle so all-idle alignment — hence termination —
                // converges promptly even at high marker counts.
                if (self.anyPeerHasWork(id)) {
                    _ = self.active_idle.fetchSub(1, .acq_rel); // retract to active
                    break; // re-enter Phase A/B and steal-and-scan while active
                }
                std.atomic.spinLoopHint();
            }
        }
    }

    /// Steal one page from some peer's deque and scan it into marker `id`'s
    /// own deque. Returns true iff an item was stolen (and scanned). Visits
    /// peers in a rotated order to spread steal contention. Caller must be
    /// counted ACTIVE (not offering termination) — the scan produces work.
    fn stealOneAndScan(self: *Tracer, heap: *const ObjectHeap, id: usize) bool {
        const n = self.marker_count;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            const j = (id + k) % n;
            if (self.markers[j].deque.steal()) |page| {
                self.markers[id].scanPage(heap, page);
                return true;
            }
            if (self.markers[j].ranges.steal()) |work| {
                self.markers[id].scanRange(heap, unpackRangeWork(work));
                return true;
            }
        }
        return false;
    }

    /// Non-removing probe: does any peer's deque appear to hold stealable work?
    /// Used only by the idle loop to decide whether to retract to active and
    /// re-enter the steal path — it never removes an item, so it cannot leave
    /// unscanned work "in flight" while the marker is counted idle. A false
    /// positive (item gone by the time we re-steal) is harmless; a false
    /// negative (a just-pushed item not yet visible) is safe too, because the
    /// pushing marker is still active and drains its own deque in Phase A.
    fn anyPeerHasWork(self: *Tracer, id: usize) bool {
        const n = self.marker_count;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            const j = (id + k) % n;
            if (self.markers[j].deque.approxLen() > 0 or
                self.markers[j].ranges.approxLen() > 0) return true;
        }
        return false;
    }

    /// Sum the per-marker stats into `self.stats` after a parallel mark
    /// terminates. Call once, single-threaded, before recording/sweeping.
    pub fn sumStats(self: *Tracer) void {
        self.stats = .{};
        for (self.markers[0..self.marker_count]) |*m| self.stats.add(m.stats);
    }

    /// Snapshot the marked ObjectIds for tracer tests. Caller owns the slice.
    fn collectLiveIds(self: *Tracer, allocator: std.mem.Allocator) ![]ObjectId {
        var list: std.ArrayListUnmanaged(ObjectId) = .empty;
        errdefer list.deinit(allocator);
        try list.ensureTotalCapacity(allocator, self.stats.objects);
        for (self.mark_bits, 0..) |word, wi| {
            var w = word;
            while (w != 0) {
                const bit = @ctz(w);
                list.appendAssumeCapacity(@intCast(wi * 64 + bit));
                w &= w - 1;
            }
        }
        return list.toOwnedSlice(allocator);
    }
};

/// Serial-mark sink (`--workers=1`): the counterpart of `Marker`.
/// Pushes children to the Tracer's `stack` (plain, non-atomic `testAndSet`)
/// and accumulates into the Tracer's `stats`. Same method surface as `Marker`
/// so the one generic edge-walk drives both.
const SerialSink = struct {
    pub const Error = error{};

    tr: *Tracer,

    inline fn markValue(self: *SerialSink, heap: *const ObjectHeap, v: Value) void {
        self.tr.markValue(heap, v);
    }
    inline fn markObject(self: *SerialSink, heap: *const ObjectHeap, id: ObjectId) void {
        self.tr.markObject(heap, id);
    }
    inline fn scanValues(self: *SerialSink, _: *const ObjectHeap, range: heap_mod.ValueRange) void {
        self.tr.ranges.append(self.tr.allocator, .{ .values = range }) catch @panic("gc serial range worklist exhausted");
    }
    inline fn scanAttrs(self: *SerialSink, _: *const ObjectHeap, range: heap_mod.AttrRange) void {
        self.tr.ranges.append(self.tr.allocator, .{ .attrs = range }) catch @panic("gc serial range worklist exhausted");
    }
    fn scanRange(self: *SerialSink, heap: *const ObjectHeap, work: RangeWork) void {
        scanRangeWork(SerialSink, self, heap, work);
    }
    inline fn countObject(self: *SerialSink) void {
        self.tr.stats.objects += 1;
        self.tr.stats.bytes += @sizeOf(heap_mod.Object);
    }
    inline fn countValues(self: *SerialSink, n: u64) void {
        self.tr.stats.values += n;
        self.tr.stats.bytes += n * @sizeOf(Value);
    }
    inline fn countAttrs(self: *SerialSink, n: u64) void {
        self.tr.stats.attrs += n;
        self.tr.stats.bytes += n * @sizeOf(heap_mod.AttrEntry);
    }
    inline fn countAttrPos(self: *SerialSink, n: u64) void {
        self.tr.stats.attr_pos += n;
        self.tr.stats.bytes += n * @sizeOf(heap_mod.AttrPosEntry);
    }

    pub inline fn objectSlot(self: *SerialSink) Error!void {
        self.countObject();
    }
    pub inline fn object(self: *SerialSink, heap: *const ObjectHeap, id: ObjectId) Error!void {
        self.markObject(heap, id);
    }
    pub inline fn chunk(_: *SerialSink, _: types.ChunkId) Error!void {}
    pub inline fn value(self: *SerialSink, heap: *const ObjectHeap, child: Value) Error!void {
        self.markValue(heap, child);
    }
    pub inline fn valueRange(self: *SerialSink, heap: *const ObjectHeap, range: heap_mod.ValueRange) Error!void {
        self.scanValues(heap, range);
    }
    pub inline fn attrRange(self: *SerialSink, heap: *const ObjectHeap, range: heap_mod.AttrRange) Error!void {
        self.scanAttrs(heap, range);
    }
    pub inline fn attrPositions(self: *SerialSink, positions: heap_mod.AttrPositions) Error!void {
        self.countAttrPos(positions.heapLen());
    }
    pub inline fn capturedValues(self: *SerialSink, heap: *const ObjectHeap, values: []const Value, owns_range: bool) Error!void {
        if (owns_range) self.countValues(values.len);
        for (values) |child| self.markValue(heap, child);
    }
};

// --- physically ordered work draining; graph shape lives in heap/edges.zig ---
//
// `heap_edges.walkObject` is generic over `SerialSink` and `Marker`, so the GC
// correctness invariant has one source of graph truth while both paths retain
// their distinct queue mechanics. See docs/gc.md.

/// Scan the newly-seen objects in one mark page in ascending ObjectId order.
/// `bits` is a stable snapshot: discoveries made by these scans accumulate in
/// `mark_bits` and are picked up by this page's close/requeue handshake.
fn scanMarkedWord(
    comptime Sink: type,
    sink: *Sink,
    heap: *const ObjectHeap,
    page: MarkPage,
    bits_in: u64,
) void {
    var bits = bits_in;
    while (bits != 0) {
        const bit: u6 = @intCast(@ctz(bits));
        const id: ObjectId = page * objects_per_mark_page + @as(ObjectId, bit);
        heap_edges.walkObject(Sink, sink, heap, id) catch unreachable;
        bits &= bits - 1;
    }
}

/// Account and trace one physically-ordered side-store range. This is generic
/// so serial and parallel tracing share the exact same queue-drain policy.
fn scanRangeWork(
    comptime Sink: type,
    sink: *Sink,
    heap: *const ObjectHeap,
    work: RangeWork,
) void {
    switch (work) {
        .values => |range| {
            sink.countValues(range.len);
            for (heap.values.slice(range)) |v| sink.markValue(heap, v);
        },
        .attrs => |range| {
            sink.countAttrs(range.len);
            // SoA: the T plane IS the values — the mark walk never touches
            // the name plane at all (a quarter fewer marked bytes per attr).
            for (heap.attrs.slice(range)) |v| sink.markValue(heap, v);
        },
    }
}

/// Does this Value carry a heap ObjectId a marker must follow?
pub inline fn hasObjectRef(v: Value) bool {
    return v.isList() or v.isAttrs() or v.isThunk() or v.isClosure() or
        v.isBuiltinClosure() or v.isContextString() or v.isBoxedInt() or
        v.isPartialApp() or v.isHeapString();
}

// --- per-heap collection stats (written by the collection coordinator) ---

const ReportState = heap_mod.GcReportState;
/// Wall time the collector spends in the STW barrier NOT marking/sweeping:
/// waiting for every worker to reach a safepoint (time-to-safepoint) plus the
/// post-collection release handshake. At --workers>1 this busy-spins, so it is
/// the dominant cost of a w>1 collection — see docs/gc.md.
/// Monotonic nanosecond clock for GC timing (collector + barrier).
pub const nowNs = clock.monotonicNs;

pub const Breakdown = struct {
    obj_live: u64,
    obj_reserved: u64,
    val_live: u64,
    val_reserved: u64,
    attr_live: u64,
    attr_reserved: u64,
    attr_pos_live: u64,
    attr_pos_reserved: u64,
};
pub fn recordTiming(state: *ReportState, mark_ns: u64, sweep_ns: u64) void {
    _ = state.mark_ns_total.fetchAdd(mark_ns, .monotonic);
    _ = state.sweep_ns_total.fetchAdd(sweep_ns, .monotonic);
}

// Mark-phase breakdown (w=1 serial path): bitmap reset / root scan /
// remembered-set seeding / transitive drain. Answers "where does the
// pause go" without a profiler run.
pub fn recordMarkPhases(state: *ReportState, reset_ns: u64, roots_ns: u64, remset_ns: u64, drain_ns: u64, remset_sources: u64) void {
    _ = state.reset_ns_total.fetchAdd(reset_ns, .monotonic);
    _ = state.roots_ns_total.fetchAdd(roots_ns, .monotonic);
    _ = state.remset_ns_total.fetchAdd(remset_ns, .monotonic);
    _ = state.drain_ns_total.fetchAdd(drain_ns, .monotonic);
    _ = state.remset_sources_total.fetchAdd(remset_sources, .monotonic);
}

/// Record barrier wall time (time-to-safepoint + release) for one collection.
pub fn recordBarrier(state: *ReportState, ns: u64) void {
    _ = state.barrier_ns_total.fetchAdd(ns, .monotonic);
}

pub fn recordBreakdown(state: *ReportState, b: Breakdown) void {
    const values = [_]u64{
        b.obj_live,
        b.obj_reserved,
        b.val_live,
        b.val_reserved,
        b.attr_live,
        b.attr_reserved,
        b.attr_pos_live,
        b.attr_pos_reserved,
    };
    for (&state.breakdown, values) |*slot, value| slot.store(value, .monotonic);
}

fn loadBreakdown(state: *const ReportState) Breakdown {
    return .{
        .obj_live = state.breakdown[0].load(.monotonic),
        .obj_reserved = state.breakdown[1].load(.monotonic),
        .val_live = state.breakdown[2].load(.monotonic),
        .val_reserved = state.breakdown[3].load(.monotonic),
        .attr_live = state.breakdown[4].load(.monotonic),
        .attr_reserved = state.breakdown[5].load(.monotonic),
        .attr_pos_live = state.breakdown[6].load(.monotonic),
        .attr_pos_reserved = state.breakdown[7].load(.monotonic),
    };
}

pub const CollectionKind = enum { minor, major };

/// Record one completed collection: objects freed, surviving live bytes,
/// and total reserved bytes (the committed-RSS high-water for this cycle).
pub fn recordCollection(state: *ReportState, kind: CollectionKind, objects_freed: u64, live: LiveStats, total_after: u64) void {
    _ = state.collections.fetchAdd(1, .monotonic);
    switch (kind) {
        .minor => _ = state.minor_collections.fetchAdd(1, .monotonic),
        .major => {
            _ = state.major_collections.fetchAdd(1, .monotonic);
            const values = [_]u64{ live.objects, live.values, live.attrs, live.attr_pos, live.bytes };
            for (&state.peak_major_live, values) |*peak, value| _ = peak.fetchMax(value, .monotonic);
        },
    }
    _ = state.objects_freed_total.fetchAdd(objects_freed, .monotonic);
    state.last_live_bytes.store(live.bytes, .monotonic);
    _ = state.peak_total_bytes.fetchMax(total_after, .monotonic);
}

/// Collector counter snapshot used by diagnostics and tests: how many
/// collections have run, the surviving live bytes after the last one, and the
/// cumulative objects freed.
pub const LiveReport = struct {
    collections: u64,
    live_bytes: u64,
    freed_objects: u64,
};

pub fn liveReport(state: *const ReportState) LiveReport {
    return .{
        .collections = state.collections.load(.monotonic),
        .live_bytes = state.last_live_bytes.load(.monotonic),
        .freed_objects = state.objects_freed_total.load(.monotonic),
    };
}

pub fn recordFinalTotal(state: *ReportState, total: u64) void {
    state.final_total_bytes.store(total, .monotonic);
    _ = state.peak_total_bytes.fetchMax(total, .monotonic);
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

fn pct(live: u64, reserved: u64) f64 {
    if (reserved == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(live)) / @as(f64, @floatFromInt(reserved));
}

/// Peak resident set size in bytes (kernel high-water, never decreases).
pub fn peakRssBytes() u64 {
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    const maxrss: u64 = @intCast(ru.maxrss);
    // ru_maxrss units differ by OS: KiB on Linux/BSD, bytes on Darwin.
    return if (comptime builtin.os.tag.isDarwin()) maxrss else maxrss * 1024;
}

// Hugetlb-backed bytes are invisible to every kernel RSS figure (ru_maxrss,
// VmRSS/VmHWM, statm) — with `--hugetlb` most of the heap moves off-RSS, so
// any diagnostic that means "how much memory is this process using" must fold
// in the hugetlb byte tracking from base/hugetlb.zig. (The GC budget itself is
// immune: it gates on
// `ObjectHeap.totalReservedBytes()`, internal slot counting.)

/// Darwin libproc surface for a precise current RSS. `std.c` does not
/// expose `proc_pid_rusage`; RUSAGE_INFO_V0 is the smallest flavor carrying
/// `ri_resident_size`. Referenced only inside the Darwin comptime branch,
/// so nothing here is codegen'd elsewhere.
const darwin_libproc = struct {
    const rusage_info_v0 = 0;
    const RusageInfoV0 = extern struct {
        uuid: [16]u8,
        user_time: u64,
        system_time: u64,
        pkg_idle_wkups: u64,
        interrupt_wkups: u64,
        pageins: u64,
        wired_size: u64,
        resident_size: u64,
        phys_footprint: u64,
        proc_start_abstime: u64,
        proc_exit_abstime: u64,
    };
    extern "c" fn proc_pid_rusage(pid: std.c.pid_t, flavor: c_int, buffer: *RusageInfoV0) c_int;
};

/// Current resident set size in bytes. Linux reads /proc/self/statm (field
/// 2 = resident pages); Darwin queries libproc's `proc_pid_rusage`
/// (`ri_resident_size`), falling back to the peak high-water if the call
/// fails. Other OSes report 0.
pub fn currentRssBytes() u64 {
    if (comptime builtin.os.tag != .linux) {
        if (comptime builtin.os.tag.isDarwin()) {
            var info: darwin_libproc.RusageInfoV0 = undefined;
            if (darwin_libproc.proc_pid_rusage(std.c.getpid(), darwin_libproc.rusage_info_v0, &info) == 0)
                return info.resident_size;
            return peakRssBytes();
        }
        return 0;
    }
    var buf: [128]u8 = undefined;
    const linux = std.os.linux;
    const fd_raw = linux.open("/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_raw)));
    if (fd < 0) return 0;
    defer _ = linux.close(fd);
    const n = linux.read(fd, &buf, buf.len);
    const rd: isize = @bitCast(n);
    if (rd <= 0) return 0;
    var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(rd)], ' ');
    _ = it.next() orelse return 0; // total program size
    const resident = it.next() orelse return 0;
    const pages = std.fmt.parseInt(u64, resident, 10) catch return 0;
    return pages * std.heap.pageSize();
}

pub fn report(state: *const ReportState, budget_bytes: u64) void {
    // Diagnostic stderr during `zig build test --listen=-` corrupts the
    // runner. Stay silent under the test runner.
    if (builtin.is_test) return;
    std.debug.print("\n=== GC (stop-the-world mark-sweep; parallel mark at --workers>1) ===\n", .{});
    const live = liveReport(state);
    const peak_total_bytes = state.peak_total_bytes.load(.monotonic);
    const final_total_bytes = state.final_total_bytes.load(.monotonic);
    const mark_ns_total = state.mark_ns_total.load(.monotonic);
    const sweep_ns_total = state.sweep_ns_total.load(.monotonic);
    const barrier_ns_total = state.barrier_ns_total.load(.monotonic);
    const drain_ns_total = state.drain_ns_total.load(.monotonic);
    std.debug.print("memory budget (reserved-bytes ceiling): {d:.1} MB\n", .{mb(budget_bytes)});
    std.debug.print("collections: {d} ({d} minor, {d} major)\n", .{
        live.collections,
        state.minor_collections.load(.monotonic),
        state.major_collections.load(.monotonic),
    });
    std.debug.print("objects freed (total): {d}\n", .{live.freed_objects});
    std.debug.print("live after last collect: {d:.1} MB\n", .{mb(live.live_bytes)});
    std.debug.print("peak reserved (RSS ceiling held): {d:.1} MB\n", .{mb(peak_total_bytes)});
    std.debug.print("final reserved: {d:.1} MB\n", .{mb(final_total_bytes)});
    std.debug.print("mark time (total): {d:.1} ms\n", .{@as(f64, @floatFromInt(mark_ns_total)) / 1e6});
    if (drain_ns_total > 0)
        std.debug.print("  mark phases: reset {d:.1} / roots {d:.1} / remset {d:.1} ms ({d} sources) / drain {d:.1} ms\n", .{
            @as(f64, @floatFromInt(state.reset_ns_total.load(.monotonic))) / 1e6,
            @as(f64, @floatFromInt(state.roots_ns_total.load(.monotonic))) / 1e6,
            @as(f64, @floatFromInt(state.remset_ns_total.load(.monotonic))) / 1e6,
            state.remset_sources_total.load(.monotonic),
            @as(f64, @floatFromInt(drain_ns_total)) / 1e6,
        });
    std.debug.print("sweep time (total): {d:.1} ms\n", .{@as(f64, @floatFromInt(sweep_ns_total)) / 1e6});
    std.debug.print("barrier wait (total, w>1 spin): {d:.1} ms\n", .{@as(f64, @floatFromInt(barrier_ns_total)) / 1e6});
    std.debug.print("peak RSS (kernel high-water): {d:.1} MB\n", .{mb(peakRssBytes())});
    std.debug.print("current RSS (end of eval): {d:.1} MB\n", .{mb(currentRssBytes())});
    if (containers.hugetlb.peakMappedBytes() > 0)
        std.debug.print("hugetlb mapped (now / peak): {d:.1} / {d:.1} MB (excluded from RSS lines above)\n", .{
            mb(containers.hugetlb.mappedBytes()), mb(containers.hugetlb.peakMappedBytes()),
        });
    const b = loadBreakdown(state);
    std.debug.print("last-collect per-store (live / reserved):\n", .{});
    std.debug.print("  objects: {d} / {d} ({d:.0}% live)\n", .{ b.obj_live, b.obj_reserved, pct(b.obj_live, b.obj_reserved) });
    std.debug.print("  values:  {d} / {d} ({d:.0}% live)\n", .{ b.val_live, b.val_reserved, pct(b.val_live, b.val_reserved) });
    std.debug.print("  attrs:   {d} / {d} ({d:.0}% live)\n", .{ b.attr_live, b.attr_reserved, pct(b.attr_live, b.attr_reserved) });
    std.debug.print("  attrpos: {d} / {d} ({d:.0}% live)\n", .{ b.attr_pos_live, b.attr_pos_reserved, pct(b.attr_pos_live, b.attr_pos_reserved) });
    if (state.major_collections.load(.monotonic) > 0) {
        std.debug.print("peak full-mark live: {d:.1} MB (objects {d}, values {d}, attrs {d}, attrpos {d})\n", .{
            mb(state.peak_major_live[4].load(.monotonic)),
            state.peak_major_live[0].load(.monotonic),
            state.peak_major_live[1].load(.monotonic),
            state.peak_major_live[2].load(.monotonic),
            state.peak_major_live[3].load(.monotonic),
        });
    }
    if (live.collections == 0)
        std.debug.print("(no collection — eval stayed under the threshold)\n", .{});
}

test "gc census excludes object TLAB tails discarded at arming" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();

    // Two real objects. The first allocation reserves a whole object-slot
    // chunk from the store, of which only these two slots are ever filled.
    _ = try heap.addList(&.{Value.int(1)});
    _ = try heap.addAttrs(&.{});
    const reserved = heap.objects.count();
    try std.testing.expect(reserved > 2); // a full chunk was reserved

    // Arming discards the partially-used object TLAB; its reserved-but-unfilled
    // tail is zeroed memory that decodes as the object union's tag-0 variant,
    // an empty `[ ]`. The census must exclude it, not report ~chunk-many
    // phantom empty lists.
    heap_collector.armTracking(&heap);
    try std.testing.expect(heap.discarded_object_tails.items.len == 1);

    const stats = heap.stats();
    try std.testing.expectEqual(@as(u32, 1), stats.variant_counts[0]); // the one real list
    try std.testing.expectEqual(@as(u32, 1), stats.variant_counts[1]); // the one real attrs

    var snap = try heap.objectSnapshot(allocator);
    defer snap.deinit();
    try std.testing.expectEqual(@as(u32, 2), snap.live_count);
}

test "gc reclaim: sweep frees unreachable objects + ranges, allocator reuses them" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    // Live tree: outer list -> inner list. Garbage: two unreferenced lists.
    const inner = try heap.addList(&.{ Value.int(1), Value.int(2), Value.int(3) });
    const outer = try heap.addList(&.{Value.list(inner)});
    const g1 = try heap.addList(&.{ Value.int(7), Value.int(8), Value.int(9) }); // same len as inner
    const g2 = try heap.addList(&.{Value.int(42)});
    _ = g1;
    _ = g2;
    const count_before = heap.objects.count();

    // Mark from the single root `outer`; inner must survive transitively.
    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    tr.markValue(&heap, Value.list(outer));
    tr.drain(&heap);
    try std.testing.expectEqual(@as(u64, 2), tr.stats.objects); // outer + inner live

    const st = heap_collector.sweep(&heap, tr.mark_bits);
    try std.testing.expectEqual(@as(u64, 2), st.objects_freed); // g1 + g2 dead

    // Live objects survive intact.
    try std.testing.expectEqual(@as(usize, 1), try heap.getListLen(outer));
    try std.testing.expectEqual(@as(usize, 3), try heap.getListLen(inner));
    try std.testing.expectEqual(@as(i64, 2), (try heap.getListItem(inner, 1)).asInt());

    // A new len-3 list reuses g1's freed value range + a freed object slot,
    // so neither the object store nor the value store grows.
    const values_before = heap.values.count();
    const reused = try heap.addList(&.{ Value.int(100), Value.int(200), Value.int(300) });
    try std.testing.expectEqual(count_before, heap.objects.count()); // slot reused
    try std.testing.expectEqual(values_before, heap.values.count()); // value range reused
    try std.testing.expectEqual(@as(i64, 200), (try heap.getListItem(reused, 1)).asInt());
}

test "gc reclaim: heap strings survive marking; swept byte ranges poison and reuse" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    // Equal lengths so the dead range is an exact best-fit for the reuse
    // allocation below.
    const live_x: [55]u8 = @splat('x');
    const dead_y: [55]u8 = @splat('y');
    const live_text = "live-" ++ live_x;
    const dead_text = "dead-" ++ dead_y;
    const live_id = try heap.addHeapString(live_text);
    const dead_id = try heap.addHeapString(dead_text);
    // The dangling borrow a native caller could still hold across a
    // collection that sweeps the owner.
    const stale = try heap.getHeapString(dead_id);
    const count_before = heap.objects.count();
    const bytes_before = heap.bytes.count();

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    tr.markValue(&heap, Value.heapString(live_id));
    tr.drain(&heap);
    try std.testing.expectEqual(@as(u64, 1), tr.stats.objects);

    const st = heap_collector.sweep(&heap, tr.mark_bits);
    try std.testing.expectEqual(@as(u64, 1), st.objects_freed);

    // The live string's text is intact.
    try std.testing.expectEqualStrings(live_text, try heap.getHeapString(live_id));

    // Detector builds memset swept byte ranges: the dangling slice reads
    // visible garbage, never stale-but-plausible text.
    if (comptime heap_mod.gc_debug) {
        for (stale) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);
    }

    // A same-length heap string reuses the freed byte range + object slot,
    // so neither store grows — the churn-reclaim property end to end.
    const reused = try heap.addHeapString(dead_text);
    try std.testing.expectEqual(count_before, heap.objects.count());
    try std.testing.expectEqual(bytes_before, heap.bytes.count());
    try std.testing.expectEqualStrings(dead_text, try heap.getHeapString(reused));
}

test "concurrency: detector poisons swept thunk state so stale claims trap" {
    // Regression tripwire for the tight-budget w>1 SIGSEGV (2026-08-02): a
    // speculative force_thunk task's root thunk was unrooted once slotEntry
    // cleared `current_task`, so a fiber parked on a busy claim could resume
    // holding a `*Thunk` into a swept slot and re-run `tryClaim` on recycled
    // memory. The claim loop derefs the raw pointer captured before the park
    // — no id-based `gcAssertLive` fires — so detector builds must stamp the
    // swept slot's state word; `tryClaim`/`tryClaimSolo` panic on the stamp.
    if (comptime !heap_mod.gc_debug) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    const live_id = try heap.addThunk(thunk_mod.Thunk.init(Value.int(1)));
    const dead_id = try heap.addThunk(thunk_mod.Thunk.init(Value.int(2)));
    // The raw pointer a parked fiber would still hold across the collection.
    const dead_ptr = heap.getThunkAssumeValid(dead_id);

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    tr.markObject(&heap, live_id);
    tr.drain(&heap);
    const st = heap_collector.sweep(&heap, tr.mark_bits);
    try std.testing.expectEqual(@as(u64, 1), st.objects_freed);

    const live_state = heap.getThunkAssumeValid(live_id).future.state.load(.monotonic);
    try std.testing.expect(live_state != future_mod.poisoned_state);
    try std.testing.expectEqual(future_mod.poisoned_state, dead_ptr.future.state.load(.monotonic));
}

test "gc range reuse splits a larger range and preserves the remainder" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    const live = try heap.addList(&.{Value.int(1)});
    const dead = try heap.addList(&.{
        Value.int(10),
        Value.int(20),
        Value.int(30),
        Value.int(40),
        Value.int(50),
        Value.int(60),
        Value.int(70),
    });
    const dead_range = switch (heap.get(dead).*) {
        .list => |range| range,
        else => unreachable,
    };

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    tr.markValue(&heap, Value.list(live));
    tr.drain(&heap);
    const st = heap_collector.sweep(&heap, tr.mark_bits);
    try std.testing.expectEqual(@as(u64, 1), st.objects_freed);

    // The len-3 request has no exact class, so it takes the prefix of the
    // reclaimed len-7 range. The len-4 request then consumes the remainder.
    const prefix = try heap.addList(&.{ Value.int(2), Value.int(3), Value.int(4) });
    const prefix_range = switch (heap.get(prefix).*) {
        .list => |range| range,
        else => unreachable,
    };
    try std.testing.expectEqual(dead_range.segment, prefix_range.segment);
    try std.testing.expectEqual(dead_range.offset, prefix_range.offset);
    try std.testing.expectEqual(@as(u32, 3), prefix_range.len);

    const remainder = try heap.addList(&.{ Value.int(5), Value.int(6), Value.int(7), Value.int(8) });
    const remainder_range = switch (heap.get(remainder).*) {
        .list => |range| range,
        else => unreachable,
    };
    try std.testing.expectEqual(dead_range.segment, remainder_range.segment);
    try std.testing.expectEqual(dead_range.offset + 3, remainder_range.offset);
    try std.testing.expectEqual(@as(u32, 4), remainder_range.len);
}

test "range batch claim returns a hit without consuming another worker's fair share" {
    const allocator = std.testing.allocator;
    var shared: RangeFreeList = .{};
    defer shared.deinit(allocator);
    var worker_0: RangeFreeList = .{};
    defer worker_0.deinit(allocator);
    var worker_1: RangeFreeList = .{};
    defer worker_1.deinit(allocator);

    shared.push(allocator, 0, 10, 3);
    shared.push(allocator, 0, 20, 3);

    const first = shared.moveBestFitBatchAndClaim(&worker_0, allocator, 3, 256, 2).?;
    try std.testing.expect(!first.split);
    try std.testing.expectEqual(@as(u64, 1), shared.stats().ranges);
    try std.testing.expectEqual(@as(u64, 0), worker_0.stats().ranges);

    const second = shared.moveBestFitBatchAndClaim(&worker_1, allocator, 3, 256, 2).?;
    try std.testing.expect(!second.split);
    try std.testing.expectEqual(@as(u64, 0), shared.stats().ranges);
    try std.testing.expectEqual(@as(u64, 0), worker_1.stats().ranges);
    try std.testing.expect(first.loc.offset != second.loc.offset);
}

test "gc range best-fit preserves a larger class for a later request" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    const large = try heap.addList(&.{ Value.int(1), Value.int(2), Value.int(3), Value.int(4), Value.int(5), Value.int(6), Value.int(7) });
    const large_range = switch (heap.get(large).*) {
        .list => |range| range,
        else => unreachable,
    };
    const live = try heap.addList(&.{Value.int(8)}); // separates the dead ranges
    const small = try heap.addList(&.{ Value.int(9), Value.int(10), Value.int(11), Value.int(12) });
    const small_range = switch (heap.get(small).*) {
        .list => |range| range,
        else => unreachable,
    };

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    tr.markValue(&heap, Value.list(live));
    tr.drain(&heap);
    _ = heap_collector.sweep(&heap, tr.mark_bits);

    // A worst-fit fallback would split len 7 here and strand the later len-7
    // request. Best-fit consumes len 4 and leaves the scarce large class whole.
    const three = try heap.addList(&.{ Value.int(13), Value.int(14), Value.int(15) });
    const three_range = switch (heap.get(three).*) {
        .list => |range| range,
        else => unreachable,
    };
    try std.testing.expectEqual(small_range.segment, three_range.segment);
    try std.testing.expectEqual(small_range.offset, three_range.offset);

    const seven = try heap.addList(&.{ Value.int(16), Value.int(17), Value.int(18), Value.int(19), Value.int(20), Value.int(21), Value.int(22) });
    const seven_range = switch (heap.get(seven).*) {
        .list => |range| range,
        else => unreachable,
    };
    try std.testing.expectEqual(large_range.segment, seven_range.segment);
    try std.testing.expectEqual(large_range.offset, seven_range.offset);
}

test "partially filled attr reservation returns its unowned tail" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    const reserved = try heap.reserveAttrsForMerge(7);
    errdefer heap.abortMergedAttrs(reserved);
    const dst = heap.attrsMutSlice(reserved);
    dst.names[0] = 1;
    dst.values[0] = Value.int(1);
    dst.names[1] = 2;
    dst.values[1] = Value.int(2);
    _ = try heap.publishMergedAttrs(reserved, 2);

    const tail_owner = try heap.addAttrs(&.{
        .{ .name = 3, .value = Value.int(3) },
        .{ .name = 4, .value = Value.int(4) },
        .{ .name = 5, .value = Value.int(5) },
        .{ .name = 6, .value = Value.int(6) },
        .{ .name = 7, .value = Value.int(7) },
    });
    const tail_range = switch (heap.get(tail_owner).*) {
        .attrs => |attrs| attrs.range,
        else => unreachable,
    };
    try std.testing.expectEqual(reserved.range.segment, tail_range.segment);
    try std.testing.expectEqual(reserved.range.offset + 2, tail_range.offset);
}

test "range TLAB refill returns the abandoned tail" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    const first_values = try allocator.alloc(Value, 8000);
    defer allocator.free(first_values);
    @memset(first_values, Value.int(1));
    const first = try heap.addList(first_values);
    const first_range = switch (heap.get(first).*) {
        .list => |range| range,
        else => unreachable,
    };

    const second_values = try allocator.alloc(Value, 200);
    defer allocator.free(second_values);
    @memset(second_values, Value.int(2));
    _ = try heap.addList(second_values); // replaces the TLAB with 192 slots left

    const tail_values = try allocator.alloc(Value, 192);
    defer allocator.free(tail_values);
    @memset(tail_values, Value.int(3));
    const tail = try heap.addList(tail_values);
    const tail_range = switch (heap.get(tail).*) {
        .list => |range| range,
        else => unreachable,
    };
    try std.testing.expectEqual(first_range.segment, tail_range.segment);
    try std.testing.expectEqual(first_range.offset + 8000, tail_range.offset);
}

test "gc sweep coalesces consecutive adjacent dead ranges" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    const live = try heap.addList(&.{Value.int(1)});
    const dead_a = try heap.addList(&.{ Value.int(2), Value.int(3) });
    const dead_b = try heap.addList(&.{ Value.int(4), Value.int(5), Value.int(6) });
    const range_a = switch (heap.get(dead_a).*) {
        .list => |range| range,
        else => unreachable,
    };
    const range_b = switch (heap.get(dead_b).*) {
        .list => |range| range,
        else => unreachable,
    };
    try std.testing.expectEqual(range_a.segment, range_b.segment);
    try std.testing.expectEqual(range_a.offset + range_a.len, range_b.offset);

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    tr.markValue(&heap, Value.list(live));
    tr.drain(&heap);
    const st = heap_collector.sweep(&heap, tr.mark_bits);
    try std.testing.expectEqual(@as(u64, 2), st.objects_freed);

    // Neither dead object alone can satisfy len 4. Streaming sweep combines
    // their adjacent ranges to len 5; split reuse returns this prefix and tail.
    const prefix = try heap.addList(&.{ Value.int(7), Value.int(8), Value.int(9), Value.int(10) });
    const prefix_range = switch (heap.get(prefix).*) {
        .list => |range| range,
        else => unreachable,
    };
    try std.testing.expectEqual(range_a.segment, prefix_range.segment);
    try std.testing.expectEqual(range_a.offset, prefix_range.offset);

    const tail = try heap.addList(&.{Value.int(11)});
    const tail_range = switch (heap.get(tail).*) {
        .list => |range| range,
        else => unreachable,
    };
    try std.testing.expectEqual(range_a.segment, tail_range.segment);
    try std.testing.expectEqual(range_a.offset + 4, tail_range.offset);
}

test "major coalescing joins adjacent ranges freed by different collections" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 2);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    const saved_worker = containers.worker_id.state();
    defer containers.worker_id.set(saved_worker.id, saved_worker.is_worker);
    containers.worker_id.set(0, saved_worker.is_worker);

    const dead_first = try heap.addList(&.{ Value.int(1), Value.int(2) });
    const live_first = try heap.addList(&.{ Value.int(3), Value.int(4), Value.int(5) });
    const first_range = switch (heap.get(dead_first).*) {
        .list => |range| range,
        else => unreachable,
    };
    const second_range = switch (heap.get(live_first).*) {
        .list => |range| range,
        else => unreachable,
    };
    try std.testing.expectEqual(first_range.segment, second_range.segment);
    try std.testing.expectEqual(first_range.offset + first_range.len, second_range.offset);

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    tr.markValue(&heap, Value.list(live_first));
    tr.drain(&heap);
    try std.testing.expectEqual(@as(u64, 1), heap_collector.sweep(&heap, tr.mark_bits).objects_freed);

    // The separating owner dies only in the next collection, so the streaming
    // sweep cannot see the two free intervals together.
    try tr.reset(heap.objects.count());
    try std.testing.expectEqual(@as(u64, 1), heap_collector.sweep(&heap, tr.mark_bits).objects_freed);
    const fragmented = heap.freeRangesStats().values;
    try std.testing.expectEqual(@as(u64, 2), fragmented.ranges);
    try std.testing.expectEqual(@as(u64, 5), fragmented.slots);
    try std.testing.expectEqual(@as(u32, 3), fragmented.max_len);

    heap.gcCoalesceFreeRanges();
    const coalesced = heap.freeRangesStats().values;
    try std.testing.expectEqual(@as(u64, 1), coalesced.ranges);
    try std.testing.expectEqual(@as(u64, 5), coalesced.slots);
    try std.testing.expectEqual(@as(u32, 5), coalesced.max_len);
    try std.testing.expect(coalesced.capacity < fragmented.capacity);
    try std.testing.expect(coalesced.capacity >= coalesced.ranges);

    const values_before = heap.values.count();
    const reused = try heap.addList(&.{ Value.int(6), Value.int(7), Value.int(8), Value.int(9), Value.int(10) });
    const reused_range = switch (heap.get(reused).*) {
        .list => |range| range,
        else => unreachable,
    };
    try std.testing.expectEqual(first_range.segment, reused_range.segment);
    try std.testing.expectEqual(first_range.offset, reused_range.offset);
    try std.testing.expectEqual(values_before, heap.values.count());
}

test "exhausting a reclaimed object pool requests an early collection once" {
    // The object-reuse contract this asserts is deliberately void in
    // detector builds: swept slots are retained un-reused so stale id reads
    // keep trapping (`sweepYoungListInto`, the `!gc_debug` reuse gate in
    // object construction), and pool-miss arming is bypassed with them.
    if (comptime heap_mod.gc_debug) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    // `afterCollect` normally arms this only after a worthwhile reclaimed
    // pool was published. Model that post-collection state, then verify that
    // the first true pool miss requests a safepoint collection and consumes
    // the one-shot arm.
    heap.collection.object_miss_collect_armed.store(true, .monotonic);
    _ = try heap.addBoxedInt(1);
    try std.testing.expect(heap.collection.collect_requested.load(.monotonic));
    try std.testing.expect(!heap.collection.object_miss_collect_armed.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), heap.collection.object_miss_collect_requests.load(.monotonic));

    _ = try heap.addBoxedInt(2);
    try std.testing.expectEqual(@as(u64, 1), heap.collection.object_miss_collect_requests.load(.monotonic));
}

test "minor sweep publishes every allocation worker's storage for reuse" {
    // Asserts object-slot reuse — deliberately void in detector builds
    // (see the skip note in the pool-exhaustion test above).
    if (comptime heap_mod.gc_debug) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 2);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    const saved_worker = containers.worker_id.state();
    defer containers.worker_id.set(saved_worker.id, saved_worker.is_worker);

    containers.worker_id.set(0, saved_worker.is_worker);
    const dead_0 = try heap.addList(&.{ Value.int(1), Value.int(2), Value.int(3) });
    const range_0 = switch (heap.get(dead_0).*) {
        .list => |range| range,
        else => unreachable,
    };

    containers.worker_id.set(1, saved_worker.is_worker);
    const dead_1 = try heap.addList(&.{ Value.int(4), Value.int(5), Value.int(6) });
    const range_1 = switch (heap.get(dead_1).*) {
        .list => |range| range,
        else => unreachable,
    };

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    const st = heap_collector.minorCollect(&heap, tr.mark_bits);
    try std.testing.expectEqual(@as(u64, 2), st.freed);

    // The coordinator ran with worker 1 current. Object slots and ranges may
    // cross workers through their shared batch pools.
    const objects_before = heap.objects.count();
    containers.worker_id.set(0, saved_worker.is_worker);
    const reused_0 = try heap.addList(&.{ Value.int(7), Value.int(8), Value.int(9) });
    const reused_range_0 = switch (heap.get(reused_0).*) {
        .list => |range| range,
        else => unreachable,
    };
    containers.worker_id.set(1, saved_worker.is_worker);
    const reused_1 = try heap.addList(&.{ Value.int(10), Value.int(11), Value.int(12) });
    const reused_range_1 = switch (heap.get(reused_1).*) {
        .list => |range| range,
        else => unreachable,
    };
    const reused_0_bits = (@as(u64, reused_range_0.segment) << 32) | reused_range_0.offset;
    const reused_1_bits = (@as(u64, reused_range_1.segment) << 32) | reused_range_1.offset;
    const range_0_bits = (@as(u64, range_0.segment) << 32) | range_0.offset;
    const range_1_bits = (@as(u64, range_1.segment) << 32) | range_1.offset;
    try std.testing.expect((reused_0_bits == range_0_bits or reused_0_bits == range_1_bits) and
        (reused_1_bits == range_0_bits or reused_1_bits == range_1_bits) and
        reused_0_bits != reused_1_bits);
    try std.testing.expectEqual(objects_before, heap.objects.count());
    try std.testing.expect(reused_0 != reused_1);
    try std.testing.expect((reused_0 == dead_0 or reused_0 == dead_1) and (reused_1 == dead_0 or reused_1 == dead_1));
}

test "collection boundary makes free storage available to an idle worker" {
    // Asserts object-slot reuse — deliberately void in detector builds
    // (see the skip note in the pool-exhaustion test above).
    if (comptime heap_mod.gc_debug) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 2);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    const saved_worker = containers.worker_id.state();
    defer containers.worker_id.set(saved_worker.id, saved_worker.is_worker);
    containers.worker_id.set(0, saved_worker.is_worker);

    var live: [3]ObjectId = undefined;
    for (&live) |*root| {
        _ = try heap.addList(&.{Value.int(1)}); // dead; leaves a len-1 hole
        root.* = try heap.addList(&.{Value.int(2)}); // live; prevents coalescing
    }

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    for (live) |id| tr.markValue(&heap, Value.list(id));
    tr.drain(&heap);
    const st = heap_collector.minorCollect(&heap, tr.mark_bits);
    try std.testing.expectEqual(@as(u64, 3), st.freed);

    // Worker 1 allocated nothing before collection. Shared overflow must still
    // give it one dead slot and len-1 range, so its first allocation grows
    // neither backing store.
    const objects_before = heap.objects.count();
    const values_before = heap.values.count();
    containers.worker_id.set(1, saved_worker.is_worker);
    _ = try heap.addList(&.{Value.int(3)});
    try std.testing.expectEqual(objects_before, heap.objects.count());
    try std.testing.expectEqual(values_before, heap.values.count());
}

test "resolved thunk returns its spilled capture range" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_collector.enableCollect(&heap, 64 << 20, 0);

    const thunk_id = try heap.addBytecodeThunk(1, &.{ Value.int(1), Value.int(2), Value.int(3) });
    const thunk = try heap.getThunk(thunk_id);
    const spill = thunk.targetSpillRange().?;

    // Mirrors the force publication order: evaluation has unwound, return the
    // captures, then overwrite the target arm with the resolved result.
    heap.gcReleaseThunkSpill(thunk);
    thunk.resolve(Value.int(42));
    const list_id = try heap.addList(&.{ Value.int(4), Value.int(5), Value.int(6) });
    const list_range = switch (heap.get(list_id).*) {
        .list => |range| range,
        else => unreachable,
    };
    try std.testing.expectEqual(spill.segment, list_range.segment);
    try std.testing.expectEqual(spill.offset, list_range.offset);
    try std.testing.expectEqual(@as(i64, 42), (try heap.getThunk(thunk_id)).payload.result.asInt());
}

test "constrained GC makes the first post-arm collection major" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();
    heap_collector.enableBudget(&heap, 512 << 20, true);

    // This allocation precedes lazy arming, but constrained mode has kept its
    // roots precise so the first major may reclaim it if unreachable.
    _ = try heap.addList(&.{Value.int(1)});
    try std.testing.expect(!heap.gcShouldMajor());
    heap_collector.armLazy(&heap);
    try std.testing.expect(heap.gcShouldMajor());

    // Major reconciliation lowers the generation boundary and returns to the
    // ordinary promotion-count gate.
    heap.gcMajorReconcile(&.{});
    heap.gcNoteMajor(0);
    try std.testing.expect(!heap.gcShouldMajor());
}

test "tracer collectLiveIds returns exactly the marked set" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();

    // Reachable (from root `outer`): outer -> inner. Unreachable: loose_a, loose_b.
    const inner = try heap.addList(&.{ Value.int(1), Value.int(2) });
    const outer = try heap.addList(&.{Value.list(inner)});
    const loose_a = try heap.addList(&.{Value.int(3)});
    const loose_b = try heap.addList(&.{Value.int(4)});

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    try tr.reset(heap.objects.count());
    tr.markValue(&heap, Value.list(outer));
    tr.drain(&heap);

    const live_ids = try tr.collectLiveIds(allocator);
    defer allocator.free(live_ids);

    try std.testing.expectEqual(@as(usize, 2), live_ids.len);
    var saw_outer = false;
    var saw_inner = false;
    for (live_ids) |id| {
        if (id == outer) saw_outer = true;
        if (id == inner) saw_inner = true;
    }
    try std.testing.expect(saw_outer);
    try std.testing.expect(saw_inner);
    try std.testing.expect(!tr.isMarked(loose_a));
    try std.testing.expect(!tr.isMarked(loose_b));
}

test "tracer markObject ignores objects outside the reset range" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();

    const a = try heap.addList(&.{Value.int(1)});

    var tr = Tracer.init(allocator);
    defer tr.deinit();
    // Reset to a bitmap covering zero objects, then mark an id past it —
    // markObject/testAndSet must not go out of bounds.
    try tr.reset(0);
    tr.markObject(&heap, a);
    try std.testing.expect(!tr.isMarked(a));

    const live_ids = try tr.collectLiveIds(allocator);
    defer allocator.free(live_ids);
    try std.testing.expectEqual(@as(usize, 0), live_ids.len);
}

test "tracer: parallel mark reaches exactly the live set (marker_count markers, stealing)" {
    const allocator = std.testing.allocator;
    var heap = try ObjectHeap.init(allocator, 1);
    defer heap.deinit();

    // Wide + deep graph so stealing is actually exercised: a root list of chain_count
    // chain-heads, each chain a depth-chain_depth spine of 1-element lists. All objects
    // are distinct (append-only store), so the live set is exactly chain_count*chain_depth + 1.
    const chain_count = 512;
    const chain_depth = 8;
    var heads: [chain_count]Value = undefined;
    for (&heads) |*h| {
        var node = try heap.addList(&.{Value.int(0)}); // innermost (1 object)
        var d: usize = 1;
        while (d < chain_depth) : (d += 1) node = try heap.addList(&.{Value.list(node)});
        h.* = Value.list(node);
    }
    const root = try heap.addList(&heads);
    const live_expected: u64 = @as(u64, chain_count) * chain_depth + 1;

    // Garbage the mark must NOT reach.
    const g1 = try heap.addList(&.{Value.int(1)});
    const g2 = try heap.addList(&.{ Value.int(2), Value.int(3) });

    const Worker = struct {
        fn drain(tr: *Tracer, h: *const ObjectHeap, id: usize) void {
            tr.drainParallel(h, id);
        }
    };

    var tr = Tracer.init(allocator);
    defer tr.deinit();

    const marker_count = 4;
    // Repeat: a parallel-mark data race is rare, so hammer it.
    var iter: usize = 0;
    while (iter < 50) : (iter += 1) {
        try tr.resetParallel(heap.objects.count(), marker_count);
        // Seed the single root into marker 0; stealing spreads the rest.
        tr.beginSeeding(0);
        tr.markValue(&heap, Value.list(root));
        tr.endSeeding();

        var threads: [marker_count]std.Thread = undefined;
        for (&threads, 0..) |*th, id|
            th.* = try std.Thread.spawn(.{}, Worker.drain, .{ &tr, &heap, id });
        for (&threads) |th| th.join();

        tr.sumStats();
        try std.testing.expectEqual(live_expected, tr.stats.objects);
        try std.testing.expect(tr.isMarked(root));
        try std.testing.expect(!tr.isMarked(g1));
        try std.testing.expect(!tr.isMarked(g2));
    }
}

test "gc stat recorders accumulate observable deltas" {
    var state: ReportState = .{};
    recordTiming(&state, 100, 50);
    try std.testing.expectEqual(@as(u64, 100), state.mark_ns_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 50), state.sweep_ns_total.load(.monotonic));

    const breakdown: Breakdown = .{
        .obj_live = 3,
        .obj_reserved = 10,
        .val_live = 4,
        .val_reserved = 12,
        .attr_live = 5,
        .attr_reserved = 14,
        .attr_pos_live = 6,
        .attr_pos_reserved = 16,
    };
    recordBreakdown(&state, breakdown);
    try std.testing.expectEqual(breakdown, loadBreakdown(&state));

    recordCollection(&state, .major, 7, .{ .objects = 3, .values = 4, .attrs = 5, .attr_pos = 6, .bytes = 1234 }, 999);
    try std.testing.expectEqual(@as(u64, 1), state.collections.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), state.major_collections.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), state.minor_collections.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 7), state.objects_freed_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1234), state.last_live_bytes.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 999), state.peak_total_bytes.load(.monotonic));

    // A smaller total-after must not lower the running peak.
    recordCollection(&state, .minor, 0, .{ .bytes = 1234 }, 1);
    try std.testing.expectEqual(@as(u64, 1), state.minor_collections.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 999), state.peak_total_bytes.load(.monotonic));

    recordFinalTotal(&state, 999);
    try std.testing.expectEqual(@as(u64, 999), state.final_total_bytes.load(.monotonic));

    // recordFinalTotal also raises the peak if the final total exceeds it.
    recordFinalTotal(&state, 2000);
    try std.testing.expectEqual(@as(u64, 2000), state.peak_total_bytes.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2000), state.final_total_bytes.load(.monotonic));
}

test "gc policy and reports are isolated per heap" {
    var left = try ObjectHeap.init(std.testing.allocator, 1);
    defer left.deinit();
    var right = try ObjectHeap.init(std.testing.allocator, 1);
    defer right.deinit();

    heap_collector.enableCollect(&left, 128 << 20, 4 << 20);
    heap_collector.enableBudget(&right, 2 << 30, false);
    left.gcSetDisableReuse(true);

    try std.testing.expectEqual(@as(u64, 128 << 20), left.collection.budget_bytes);
    try std.testing.expectEqual(@as(u64, 4 << 20), left.collection.step_bytes);
    try std.testing.expect(left.collection.disable_reuse);
    try std.testing.expectEqual(@as(u64, 2 << 30), right.collection.budget_bytes);
    try std.testing.expectEqual(@as(u64, 0), right.collection.step_bytes);
    try std.testing.expect(!right.collection.disable_reuse);

    recordCollection(&left.collection.report, .minor, 3, .{ .bytes = 4096 }, 8192);
    try std.testing.expectEqual(@as(u64, 1), liveReport(&left.collection.report).collections);
    try std.testing.expectEqual(@as(u64, 0), liveReport(&right.collection.report).collections);
}
