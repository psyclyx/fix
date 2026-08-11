//! GC collector driver for `ObjectHeap`: marking, generational sweep, and
//! threshold policy over the heap's storage model.
//!
//! These are free functions over `heap: *ObjectHeap` rather than methods (Zig
//! cannot add methods to a struct from another file). Hot allocation helpers
//! remain on `ObjectHeap` so they inline at their call sites.
//!

const std = @import("std");
const heap_mod = @import("../heap.zig");
const heap_edges = @import("edges.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const HeapLocal = heap_mod.HeapLocal;
const Object = heap_mod.Object;
const ObjectId = heap_mod.ObjectId;
const Value = @import("../value.zig").Value;

const gc_debug = heap_mod.gc_debug;
const future_mod = @import("../future.zig");

/// Detector: stamp a swept thunk's future state with the poison sentinel.
/// The alloc-bitmap assert (`gcAssertLive`) only fires on id-based reads;
/// a claim loop that captured the `*Thunk` BEFORE parking re-derefs the raw
/// pointer after resume with no id check — the poisoned state makes that
/// `tryClaim` trap at the exact deref (see `future.poisoned_state`).
fn poisonSweptObject(heap: *ObjectHeap, id: ObjectId) void {
    switch (heap.objects.getMut(id).*) {
        .thunk => |*t| t.future.state.store(future_mod.poisoned_state, .monotonic),
        // Inline string text lives in the slot itself; memset it so a
        // dangling borrow reads visible garbage (the range-store analogue
        // is in freeObjectRanges).
        .heap_string_inline => |*is| @memset(&is.text, 0xAA),
        else => {},
    }
}

pub const SweepStats = struct {
    objects_freed: u64 = 0,
};

const FreeRange = struct {
    segment: u32,
    offset: u32,
    len: u32,
};

/// Comptime `heap_mod.range_stores` row indices, so `freeObjectRanges` arms
/// name stores without restating field strings.
const si_values = heap_mod.rangeStoreIndex("values");
const si_attrs = heap_mod.rangeStoreIndex("attrs");
const si_attr_pos = heap_mod.rangeStoreIndex("attr_pos");
const si_bytes = heap_mod.rangeStoreIndex("bytes");

/// Collection-local streaming coalescer. Sweep order follows allocation order
/// closely (exactly on one worker, per-worker for a parallel minor), so adjacent
/// dead owners normally arrive consecutively. Holding one interval per store
/// (indexed by `heap_mod.range_stores` row) merges those runs with no
/// per-range allocation, sorting, or address hash.
const RangeBatch = struct {
    heap: *ObjectHeap,
    fixed_dst: ?*HeapLocal,
    shard: usize = 0,
    pending: [heap_mod.range_stores.len]?FreeRange = @splat(null),

    fn global(heap: *ObjectHeap) RangeBatch {
        return .{ .heap = heap, .fixed_dst = null };
    }

    fn local(heap: *ObjectHeap, dst: *HeapLocal) RangeBatch {
        return .{ .heap = heap, .fixed_dst = dst };
    }

    fn add(self: *RangeBatch, comptime si: usize, range: FreeRange) void {
        const pending = &self.pending[si];
        if (pending.*) |*last| {
            if (last.segment == range.segment and last.offset + last.len == range.offset) {
                last.len += range.len;
                return;
            }
            if (last.segment == range.segment and range.offset + range.len == last.offset) {
                last.offset = range.offset;
                last.len += range.len;
                return;
            }
            self.emit(si, last.*);
        }
        pending.* = range;
    }

    fn emit(self: *RangeBatch, comptime si: usize, range: FreeRange) void {
        const dst = self.fixed_dst orelse blk: {
            const selected = &self.heap.worker_locals[self.shard];
            self.shard += 1;
            if (self.shard == self.heap.worker_locals.len) self.shard = 0;
            break :blk selected;
        };
        @field(dst, heap_mod.range_stores[si].free).push(self.heap.allocator, range.segment, range.offset, range.len);
    }

    fn flush(self: *RangeBatch) void {
        inline for (0..heap_mod.range_stores.len) |si| {
            if (self.pending[si]) |range| self.emit(si, range);
            self.pending[si] = null;
        }
    }
};

/// Free every filled object that `mark_bits` left unmarked. Must run at a
/// safepoint with no concurrent allocation.
pub fn sweep(heap: *ObjectHeap, mark_bits: []const u64) SweepStats {
    var stats: SweepStats = .{};
    var ranges = RangeBatch.global(heap);
    if (comptime !gc_debug) heap.gcReconstructAllocBits();
    if (comptime gc_debug) verifyMarkClosed(heap, mark_bits);
    const object_count = heap.objects.count();
    const shard_count = heap.worker_locals.len;
    var shard: usize = 0;
    var id: ObjectId = 0;
    while (id < object_count) : (id += 1) {
        const word = id >> 6;
        if (word >= heap.collection.alloc_bits.len) break;
        const bit = @as(u64, 1) << @intCast(id & 63);
        if (heap.collection.alloc_bits[word] & bit == 0) continue;
        const is_marked = word < mark_bits.len and (mark_bits[word] & bit != 0);
        if (is_marked) continue;
        const local = &heap.worker_locals[shard];
        freeObjectRanges(heap, &ranges, heap.objects.get(id));
        if (comptime gc_debug) poisonSweptObject(heap, id);
        heap.collection.alloc_bits[word] &= ~bit;
        local.gc_free_objects.append(heap.allocator, id) catch {};
        stats.objects_freed += 1;
        shard += 1;
        if (shard >= shard_count) shard = 0;
    }
    ranges.flush();
    heap.gcRebalanceFreeLists();
    return stats;
}

/// Turn on reclaim (alloc-bitmap maintenance + free-list reuse + sweep)
/// with a memory `budget` (the reserved-bytes ceiling the collector
/// defends — see `ObjectHeap.collection.budget_bytes`). `step_bytes` > 0 is the
/// validation override: collect every that-many bytes of fresh allocation
/// from a low starting threshold, ignoring the budget.
pub fn enableCollect(heap: *ObjectHeap, budget: u64, step_bytes: u64) void {
    heap.collection.step_bytes = step_bytes;
    heap.collection.budget_bytes = budget;
    // Collect after fresh reservations cross the configured threshold.
    heap.collection.threshold_bytes = if (step_bytes > 0) heap.totalReservedBytes() + step_bytes else budget;
    heap.gcArmByteLine();
    // Validation path arms eagerly (bootstrap_end == the arming count, so the
    // pre-arming region is empty), but turn on constrained mode so the always-
    // on transient-root gates are exercised. `armTracking` enables root tracking.
    heap.collection.bootstrap_end = heap.objects.count();
    heap.collection.root_always = true;
    // Detector: presize the alloc bitmap here, like the constrained `enableBudget`
    // path. `armTracking` only presizes outside constrained mode, so without this
    // the eager step path would arm with a ZERO-length bitmap — every per-fill
    // `gcSetAllocBit` would silently drop its bit (word >= len) and the very
    // first tracked read would false-trap "read after sweep". (`armTracking`
    // below then skips its own presize, preserving this freshly-zeroed map.)
    if (comptime gc_debug) heap.gcPresizeAllocBits();
    armTracking(heap);
}

/// Bytes of reserved growth at which the lazy path arms tracking+rooting:
/// a QUARTER of the line (floored at 512 MiB, capped at line/2 so tiny
/// budgets still arm before they collect). Everything allocated before
/// arming stays pinned, so a lower arm line shrinks the unreclaimable
/// floor — measured on whole-nixpkgs: arming at line/2 (16 GiB) left
/// collections 13 GiB less effective than early rooting. A run that
/// never reaches the arm line pays ZERO tracking or rooting cost, which
/// is what keeps small evals exactly as fast under any budget form.
pub fn armLineBytes(budget: u64) u64 {
    const floor: u64 = 512 << 20;
    return @min(@max(budget / 4, floor), budget / 2);
}

/// Lazy collection-line policy (the production default, see
/// `gc_controller.memoryBudget`): don't start any per-allocation tracking yet — just
/// watch the reserved-bytes cursor. At `armLineBytes` the safepoint driver arms
/// tracking (STW, `armTracking`); at the line it collects. A run that never
/// reaches the arm line pays ZERO tracking cost (no young-slot appends, no write
/// barrier, no free-list probes). The price: objects allocated before arming are
/// permanently old (unreclaimable floor ≈ reserved at the arm line)
/// UNLESS `root_always` (`FIX_GC_ROOTS=1` / the step validation path): then a
/// major also reclaims that pre-arming region, paid for by keeping the
/// transient-root gates live from here. `collection.bootstrap_end` is captured
/// now as the reclaim boundary (bootstrap below it stays pinned).
pub fn enableBudget(heap: *ObjectHeap, budget: u64, root_always: bool) void {
    heap.collection.step_bytes = 0;
    heap.collection.budget_bytes = budget;
    heap.collection.threshold_bytes = armLineBytes(budget);
    heap.gcArmByteLine();
    heap.collection.bootstrap_end = heap.objects.count();
    heap.collection.root_always = root_always;
    heap.collection.root_active = root_always;
    // Detector: with bits live from here (per-fill, gated on root tracking),
    // size the bitmap now — arming won't be the first sizer, and its re-size
    // outside constrained mode would otherwise wipe bits set in between.
    if (comptime gc_debug) if (root_always) heap.gcPresizeAllocBits();
}

/// Start young-slot tracking, the old-to-young write barrier, and free-list
/// reuse. Objects already allocated are treated as old. The caller must hold
/// the world stopped while the object TLABs are discarded and tracking is
/// published.
pub fn armTracking(heap: *ObjectHeap) void {
    heap.collection.collect_enabled = true;
    heap.collection.root_active = true; // arming turns rooting on (already on if constrained)
    heap.collection.track_from = heap.objects.count();
    // A partially used object TLAB contains reserved ids below the tracking
    // boundary. Discard it so every subsequent object enters the young-slot
    // lists; the discarded tails are recorded so the heap census keeps
    // excluding them (they stay pinned but forever unfilled).
    heap.discardObjectTLABs();
    // Detector build: pre-size the alloc bitmap to the whole object id
    // space so the incremental per-fill bit-set never reallocs (which
    // would free the array under a concurrent reader/setter at
    // --workers>1). With a stable array, set uses atomic-or and read uses
    // atomic-load — no lock on detector paths.
    // Constrained mode already sized-and-populated the bitmap from eval start
    // (gcEnableBudget); re-sizing here would @memset those live bits to zero.
    if (comptime gc_debug) if (!heap.collection.root_always) heap.gcPresizeAllocBits();
}

/// The `armLineBytes` STW safepoint under the lazy policy: arm tracking and
/// re-arm the threshold to the full budget. No mark, no sweep, no token bump —
/// nothing allocated so far is tracked, so there is nothing to reclaim yet.
pub fn armLazy(heap: *ObjectHeap) void {
    armTracking(heap);
    heap.collection.collect_requested.store(false, .monotonic);
    const budget = heap.collection.budget_bytes;
    const headroom = std.math.clamp(budget / 8, 64 << 20, ObjectHeap.gc_headroom);
    heap.collection.threshold_bytes = @max(budget, heap.totalReservedBytes() + headroom);
    heap.gcRaiseByteLine();
}

/// Run a collection now via the registered callback (the evaluator's
/// mark+sweep). Caller must be at a safepoint. `collector_id` is the
/// worker driving the collection (its slot in the parallel mark).
pub fn runCollect(heap: *ObjectHeap, collector_id: u8) void {
    if (heap.collection.hook) |h| h.sample(h.ctx, collector_id);
}

/// Called by the evaluator after a sweep: clear the request and set the
/// next threshold. The store cursors are monotonic — non-moving reuse
/// returns freed ranges to the free lists but never lowers
/// `totalReservedBytes` — so the threshold must be relative to the
/// CURSOR NOW, not the live set: collect again only once we've committed
/// another `gc_headroom` of genuinely fresh pages (i.e. the free lists
/// drained and the cursor actually grew). Anchoring to live would leave
/// the threshold permanently below the cursor → collect every safepoint
/// (livelock). `live_bytes` is accepted for stats only.
pub fn afterCollect(heap: *ObjectHeap, live_bytes: u64) void {
    _ = live_bytes;
    if (comptime gc_debug) heap.gcVerifyByteRanges();
    heap.collection.collect_requested.store(false, .monotonic);
    // Post-collect headroom scales with the budget (an eighth, clamped to
    // [64 MB, gc_headroom]): a small-RAM budget must not grant itself a
    // flat 1 GB of growth per cycle, and a huge budget needn't collect
    // every 64 MB once it has (somehow) been crossed.
    const budget = heap.collection.budget_bytes;
    const headroom = std.math.clamp(budget / 8, 64 << 20, ObjectHeap.gc_headroom);
    heap.collection.threshold_bytes = if (heap.collection.step_bytes > 0)
        heap.totalReservedBytes() + heap.collection.step_bytes
    else
        @max(budget, heap.totalReservedBytes() + headroom);
    heap.gcRaiseByteLine();
    heap.gcArmPoolMissCollection();
    // Invalidate all thread-local caches (thunk memo, attr IC, call IC)
    // that key on `token`. Current thunk-memo and attr-cache values were
    // traced as roots for this collection because a cache may momentarily be
    // their sole owner; the fresh token makes every old slot miss afterward,
    // before a recycled ObjectId can be mistaken for that prior value.
    heap.token = heap_mod.next_heap_token.fetchAdd(1, .monotonic);
}

/// Visit every remembered old source (STW). `cb(ctx, source_id)`.
pub fn forEachRemsetSource(heap: *ObjectHeap, ctx: anytype, comptime cb: fn (@TypeOf(ctx), ObjectId) void) void {
    for (heap.worker_locals) |*wl| for (wl.gc_remset.items) |sid| cb(ctx, sid);
}

pub fn remsetClear(heap: *ObjectHeap) void {
    for (heap.worker_locals) |*wl| wl.gc_remset.clearRetainingCapacity();
}

fn bitSet(bits: []const u64, id: ObjectId) bool {
    const word = id >> 6;
    return word < bits.len and bits[word] & (@as(u64, 1) << @intCast(id & 63)) != 0;
}

const ClosureCheck = enum { minor, full };

/// Verification policy over the canonical object-edge walk. Keeping the
/// checker separate from graph shape makes it impossible for diagnostics to
/// silently omit a newly-added object arm or thunk target.
const ClosureSink = struct {
    pub const Error = error{};

    heap: *const ObjectHeap,
    mark_bits: []const u64,
    parent: ObjectId,
    shown: *u32,
    check: ClosureCheck,

    fn checkObject(self: *ClosureSink, child: ObjectId) void {
        switch (self.check) {
            .minor => {
                if (!self.heap.gcIsYoung(child) or bitSet(self.mark_bits, child)) return;
                if (self.shown.* < 8) {
                    std.debug.print("GC MISSED EDGE: {s} {d} -> unmarked young {s} {d}\n", .{
                        @tagName(self.heap.objects.get(self.parent).*),
                        self.parent,
                        @tagName(self.heap.objects.get(child).*),
                        child,
                    });
                    self.shown.* += 1;
                }
            },
            .full => {
                if (!bitSet(self.heap.collection.alloc_bits, child) or bitSet(self.mark_bits, child)) return;
                if (self.shown.* < 8) {
                    std.debug.print("  TRACER-MISSED EDGE: marked {d} ({s}) -> unmarked {d} ({s})\n", .{
                        self.parent,
                        @tagName(self.heap.objects.get(self.parent).*),
                        child,
                        @tagName(self.heap.objects.get(child).*),
                    });
                    self.shown.* += 1;
                }
            },
        }
    }

    pub inline fn objectSlot(_: *ClosureSink) Error!void {}
    pub inline fn object(self: *ClosureSink, _: *const ObjectHeap, child: ObjectId) Error!void {
        self.checkObject(child);
    }
    pub inline fn chunk(_: *ClosureSink, _: heap_mod.ChunkId) Error!void {}
    pub inline fn value(self: *ClosureSink, _: *const ObjectHeap, child: Value) Error!void {
        if (ObjectHeap.gcHeapId(child)) |id| self.checkObject(id);
    }
    pub inline fn valueRange(self: *ClosureSink, heap: *const ObjectHeap, range: heap_mod.ValueRange) Error!void {
        for (heap.values.slice(range)) |child| try self.value(heap, child);
    }
    pub inline fn attrRange(self: *ClosureSink, heap: *const ObjectHeap, range: heap_mod.AttrRange) Error!void {
        // SoA: the T plane holds the values directly.
        for (heap.attrs.slice(range)) |entry_value| try self.value(heap, entry_value);
    }
    pub inline fn attrPositions(_: *ClosureSink, _: heap_mod.AttrPositions) Error!void {}
    pub inline fn capturedValues(self: *ClosureSink, heap: *const ObjectHeap, values: []const Value, _: bool) Error!void {
        for (values) |child| try self.value(heap, child);
    }
};

/// In detector builds, verify that every young child of a live object was
/// marked before sweeping. A failure identifies the missed parent-child edge.
pub fn verifyMinorClosure(heap: *ObjectHeap, mark_bits: []const u64) void {
    if (comptime !gc_debug) return;
    var shown: u32 = 0;
    // Include pinned objects because they may point into the young generation.
    var id: ObjectId = 0;
    const n = heap.objects.count();
    const pinned_floor = if (heap.collection.root_always)
        heap.collection.bootstrap_end
    else
        heap.collection.track_from;
    while (id < n and shown < 8) : (id += 1) {
        // Pinned pre-arming ids have no alloc bits (per-fill bit setting is
        // gated on root tracking) but are permanently live — and they are
        // exactly the OLD parents whose young referents depend entirely on
        // the remembered set. Verify their edges too, or a missed pinned→
        // young edge surfaces only later as a read-after-sweep.
        if (id >= pinned_floor) {
            const word = id >> 6;
            if (word >= heap.collection.alloc_bits.len) break;
            if (heap.collection.alloc_bits[word] & (@as(u64, 1) << @intCast(id & 63)) == 0) continue;
            // Only LIVE parents constrain the mark: a dead young object
            // (unmarked, about to be swept) may freely reference dead young
            // children. Old and marked-young parents are live.
            if (heap.gcIsYoung(id) and !bitSet(mark_bits, id)) continue;
        }
        var sink = ClosureSink{ .heap = heap, .mark_bits = mark_bits, .parent = id, .shown = &shown, .check = .minor };
        heap_edges.walkObject(ClosureSink, &sink, heap, id) catch unreachable;
    }
    if (shown > 0) @panic("gc: minor mark not closed — missed edge (see MISSED EDGE lines)");
}

/// Sweep the per-worker young-object lists. Marked objects are promoted in
/// place; unmarked objects return their slots and owned ranges to free lists.
pub fn minorCollect(heap: *ObjectHeap, mark_bits: []const u64) ObjectHeap.MinorStats {
    var st: ObjectHeap.MinorStats = .{};
    heap.gcGrowOldBits(heap.objects.count());
    verifyMinorClosure(heap, mark_bits);
    // Return each dead allocation to its originating worker's shard. This
    // keeps mutator reuse local and lock-free even though the coordinator is
    // performing this serial sweep on every worker's behalf.
    for (heap.worker_locals) |*local| {
        var ranges = RangeBatch.local(heap, local);
        sweepYoungListInto(heap, local.gc_young_slots.items, local, &ranges, mark_bits, &st);
        ranges.flush();
        local.gc_young_slots.clearRetainingCapacity();
    }
    heap.gcRebalanceFreeLists();
    return st;
}

/// Sweep one young-object list into its allocation worker's free-list shard.
/// Lists are disjoint, so parallel helpers still have exactly one writer per
/// destination even when the helper and allocation worker differ.
fn sweepYoungListInto(heap: *ObjectHeap, src_ids: []const ObjectId, dst: *HeapLocal, ranges: *RangeBatch, mark_bits: []const u64, st: *ObjectHeap.MinorStats) void {
    for (src_ids) |id| {
        const word = id >> 6;
        const bit = @as(u64, 1) << @intCast(id & 63);
        const marked = word < mark_bits.len and (mark_bits[word] & bit != 0);
        if (marked) {
            heap.gcSetOld(id);
            st.promoted += 1;
            // Byte-weighted gate charge for tenured string text (see
            // MinorStats.promoted_charge).
            switch (heap.objects.get(id).*) {
                .heap_string => |hs| st.promoted_charge += hs.bytes.len / ObjectHeap.gc_bytes_per_object_charge,
                else => {},
            }
        } else {
            // Detector builds retain the slot so stale reads trap reliably.
            freeObjectRanges(heap, ranges, heap.objects.get(id));
            if (comptime gc_debug) {
                poisonSweptObject(heap, id);
                if (word < heap.collection.alloc_bits.len) _ = @atomicRmw(u64, &heap.collection.alloc_bits[word], .And, ~bit, .monotonic);
            } else {
                dst.gc_free_objects.append(heap.allocator, id) catch {};
            }
            st.freed += 1;
        }
    }
}

// --- parallel minor sweep -------------------------------------------------

/// Arm the young-list work queue while the object count is quiescent.
pub fn beginMinorSweep(heap: *ObjectHeap, worker_count: u8) void {
    heap.gcGrowOldBits(heap.objects.count());
    heap.collection.mark_slot.store(0, .release);
    heap.collection.minor_sweep_count = worker_count;
    heap.collection.minor_sweep_next.store(0, .monotonic);
    heap.collection.minor_sweep_done.store(0, .monotonic);
    heap.collection.minor_sweep_promoted.store(0, .monotonic);
    heap.collection.minor_sweep_promoted_charge.store(0, .monotonic);
    heap.collection.minor_sweep_freed.store(0, .monotonic);
    heap.collection.minor_sweep_open.store(false, .release);
}

/// Release helpers after the mark reaches closure.
pub fn openMinorSweep(heap: *ObjectHeap) void {
    heap.collection.minor_sweep_open.store(true, .release);
}

/// Claim and sweep young-object lists until the queue drains.
pub fn minorSweepClaimLoop(heap: *ObjectHeap, mark_bits: []const u64) void {
    while (!heap.collection.minor_sweep_open.load(.acquire)) std.atomic.spinLoopHint();
    var local_st: ObjectHeap.MinorStats = .{};
    while (true) {
        const i = heap.collection.minor_sweep_next.fetchAdd(1, .monotonic);
        if (i >= heap.collection.minor_sweep_count) break;
        const dst = &heap.worker_locals[i];
        var ranges = RangeBatch.local(heap, dst);
        sweepYoungListInto(heap, dst.gc_young_slots.items, dst, &ranges, mark_bits, &local_st);
        // Publish the final pending intervals before declaring this source
        // list swept; the coordinator uses `minor_sweep_done` as its fence.
        ranges.flush();
        dst.gc_young_slots.clearRetainingCapacity();
        _ = heap.collection.minor_sweep_done.fetchAdd(1, .release);
    }
    _ = heap.collection.minor_sweep_promoted.fetchAdd(local_st.promoted, .monotonic);
    _ = heap.collection.minor_sweep_promoted_charge.fetchAdd(local_st.promoted_charge, .monotonic);
    _ = heap.collection.minor_sweep_freed.fetchAdd(local_st.freed, .monotonic);
}

/// Block until every young-object list has been swept.
pub fn waitMinorSweepDone(heap: *ObjectHeap) void {
    while (heap.collection.minor_sweep_done.load(.acquire) < heap.collection.minor_sweep_count) std.atomic.spinLoopHint();
}

/// Return the aggregate result after every list has drained.
pub fn finishMinorSweep(heap: *ObjectHeap) ObjectHeap.MinorStats {
    heap.gcRebalanceFreeLists();
    return .{
        .promoted = heap.collection.minor_sweep_promoted.load(.monotonic),
        .promoted_charge = heap.collection.minor_sweep_promoted_charge.load(.monotonic),
        .freed = heap.collection.minor_sweep_freed.load(.monotonic),
    };
}

/// Debug: verify the mark is closed — no MARKED object may reference an
/// unmarked filled object. A violation means the tracer missed an edge
/// (systematic bug); silence means marking is complete and any swept
/// object is genuinely unreachable (held only by a Zig local / untracked
/// root). Prints up to a few violations. STW-only.
pub fn verifyMarkClosed(heap: *ObjectHeap, mark_bits: []const u64) void {
    var shown: u32 = 0;
    var id: ObjectId = 0;
    const n = heap.objects.count();
    while (id < n and shown < 8) : (id += 1) {
        if (!bitSet(heap.collection.alloc_bits, id) or !bitSet(mark_bits, id)) continue;
        var sink = ClosureSink{ .heap = heap, .mark_bits = mark_bits, .parent = id, .shown = &shown, .check = .full };
        heap_edges.walkObject(ClosureSink, &sink, heap, id) catch unreachable;
    }
    if (shown > 0) std.debug.print("=== ^ mark NOT closed: tracer missed edges (bug) ===\n", .{});
}

/// Return a dead object's owned store ranges to the free lists. Ranges
/// are single-owner (every construction site reserves fresh + copies),
/// so this is the only owner — see docs/gc.md. Thunk *spilled*
/// upvalue/env storage records its segment range and is reclaimed either here
/// (unresolved dead thunk) or immediately after a force publishes its result.
/// `attrs_merge`/`boxed_int` own no ranges.
fn freeObjectRanges(heap: *ObjectHeap, ranges: *RangeBatch, obj: *const Object) void {
    // Detector: poison the freed range so a dangling raw `getList`/`materializeAttrs`
    // slice (owner swept while a Zig local held the slice — the class the
    // reuse-off object-read assert can't see) traps on next access instead
    // of silently reading stale-but-valid data. Poison is a thunk to an
    // unallocated id, so forcing/reading a poisoned element hits gcAssertLive.
    if (comptime gc_debug) {
        const poison = Value.thunk(heap_mod.object_max_slots - 1);
        switch (obj.*) {
            .list => |r| for (heap.values.sliceMut(r)) |*v| {
                v.* = poison;
            },
            .closure => |c| for (heap.values.sliceMut(c.upvalues)) |*v| {
                v.* = poison;
            },
            .attrs => |a| {
                for (heap.attrs.sliceMut(a.range)) |*v| v.* = poison;
                // Name plane: stamp the poison name so dangling name scans
                // (binary search / merge walks) trap via gcAssertNotPoisonName.
                for (heap.attrs.sliceSecondMut(a.range)) |*n| n.* = heap_mod.gc_poison_name;
            },
            .builtin_closure => |c| for (heap.values.sliceMut(c.args)) |*v| {
                v.* = poison;
            },
            .partial_app => |p| for (heap.values.sliceMut(p.args)) |*v| {
                v.* = poison;
            },
            .context_string => |c| {
                for (heap.attrs.sliceMut(c.context)) |*v| v.* = poison;
                for (heap.attrs.sliceSecondMut(c.context)) |*n| n.* = heap_mod.gc_poison_name;
            },
            // Byte payloads have no Value shape to poison with a trapping
            // thunk; memset a sentinel so a dangling `getHeapString` slice
            // reads visibly-garbage text in detector builds instead of
            // stale-but-plausible bytes.
            .heap_string => |hs| @memset(heap.bytes.sliceMut(hs.bytes), 0xAA),
            else => {},
        }
    }
    switch (obj.*) {
        .list => |r| if (r.len > 0) ranges.add(si_values, .{ .segment = r.segment, .offset = r.offset, .len = r.len }),
        .closure => |c| if (c.upvalues.len > 0) ranges.add(si_values, .{ .segment = c.upvalues.segment, .offset = c.upvalues.offset, .len = c.upvalues.len }),
        .attrs => |a| {
            if (a.range.len > 0) ranges.add(si_attrs, .{ .segment = a.range.segment, .offset = a.range.offset, .len = a.range.len });
            // Borrowed positions are owned above the runtime — nothing to free.
            if (a.positions.heapLen() > 0) {
                const pr = a.positions.heapRange();
                ranges.add(si_attr_pos, .{ .segment = pr.segment, .offset = pr.offset, .len = pr.len });
            }
        },
        .builtin_closure => |c| if (c.args.len > 0) ranges.add(si_values, .{ .segment = c.args.segment, .offset = c.args.offset, .len = c.args.len }),
        .partial_app => |p| if (p.args.len > 0) ranges.add(si_values, .{ .segment = p.args.segment, .offset = p.args.offset, .len = p.args.len }),
        .context_string => |c| if (c.context.len > 0) ranges.add(si_attrs, .{ .segment = c.context.segment, .offset = c.context.offset, .len = c.context.len }),
        .thunk => |t| if (t.targetSpillRange()) |r| ranges.add(si_values, .{ .segment = r.segment, .offset = r.offset, .len = r.len }),
        .heap_string => |hs| if (hs.bytes.len > 0) ranges.add(si_bytes, .{ .segment = hs.bytes.segment, .offset = hs.bytes.offset, .len = hs.bytes.len }),
        .merge_attrs, .boxed_int, .heap_string_inline => {},
    }
}
