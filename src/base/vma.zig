//! Big-mapping registry: RSS attribution for the process's large
//! anonymous regions (store segments, fiber stacks, block-cache blocks).
//!
//! `--mem-report`'s slot-count table can't see segment-capacity slack,
//! pre-touch-ahead pages, fiber stacks, or allocator blocks — the
//! "unaccounted" RSS. Every large mapping registers here at its true
//! mmap boundary (and re-tags when a subsystem claims it), so the report
//! can ask the kernel how many of each region's pages are actually
//! resident (`mincore`) and attribute RSS per subsystem exactly.
//!
//! Two mechanisms, one call:
//!   - `pr_set_vma_anon_name` (Linux 5.17+, needs CONFIG_ANON_VMA_NAME):
//!     tags the VMA in /proc/self/smaps for external profilers. Silently
//!     unavailable on kernels without the config (EINVAL) — best-effort.
//!   - The in-process table + `mincore`: works everywhere, powers the
//!     `--mem-report` decomposition.
//!
//! Cost: one prctl + one O(1) hash insert per *backing* mmap (block-cache
//! reuse hits skip it), zero on the hot allocation path.

const std = @import("std");
const builtin = @import("builtin");
const SpinMutex = @import("sync.zig").SpinMutex;

/// Generic RSS region-tracker, parameterized over the caller's attribution
/// taxonomy. The mechanism (open-addressed registry, `mincore` residency,
/// `pr_set_vma_anon_name` smaps naming) is app-agnostic; the tag enum and
/// its smaps labels are injected. The evaluator's concrete instantiation
/// (the `fix:*` buckets) lives in `runtime/mem_tag.zig`.
///
/// `TagT` is the attribution enum, `default_tag` the value a fresh
/// (un-claimed) mapping carries, and `tagName` maps a tag to its static
/// smaps anon-name. Instantiating with the same arguments yields a memoized
/// type, so a shared instance (`mem_tag.vma`) is a single process-wide
/// registry regardless of how many modules name it.
pub fn Vma(
    comptime TagT: type,
    comptime default_tag_param: TagT,
    comptime tagName: fn (TagT) [:0]const u8,
) type {
    return struct {
        /// The injected attribution enum, re-exported so consumers can name
        /// `Vma.Tag` without repeating the instantiation arguments.
        pub const Tag = TagT;
        /// Value a fresh (un-claimed) mapping carries, re-exported for
        /// consumers (e.g. the block cache) that reset blocks to it.
        pub const default_tag: TagT = default_tag_param;

        pub const tag_count = @typeInfo(Tag).@"enum".field_names.len;

        /// Attribution hint for large allocations made *right now* on this
        /// thread: the block cache stamps every block it registers or hands
        /// back out with this tag. Subsystems whose blocks live long enough to
        /// matter (AST arenas, VM buffers, file texts) set it around their
        /// allocation phase via `setAllocTag` and restore the previous value.
        /// Blocks freed back to the cache's park list revert to `default_tag`.
        threadlocal var alloc_tag: Tag = default_tag;

        pub noinline fn currentAllocTag() Tag {
            return alloc_tag;
        }

        pub noinline fn setAllocTag(tag: Tag) Tag {
            const prev = alloc_tag;
            alloc_tag = tag;
            return prev;
        }

        /// Open-addressed table keyed by region base address. Fixed capacity —
        /// live large regions number in the low thousands (segments + fibers +
        /// in-flight big blocks); overflow just drops the entry (counted, so the
        /// report can flag it) rather than growing under a spinlock.
        const capacity: usize = 1 << 14; // 16384 slots, power of two

        const Slot = struct {
            /// 0 = empty, 1 = tombstone, else region base address.
            addr: usize = 0,
            len: usize = 0,
            tag: Tag = default_tag,
        };

        const tombstone: usize = 1;

        var mu: SpinMutex = .{};
        var slots: [capacity]Slot = @splat(.{});
        var live_count: usize = 0;
        var dropped_count: u32 = 0;

        fn hash(addr: usize) usize {
            // Fibonacci hash on the page number; low bits of an mmap base are zero.
            return ((addr >> 12) *% 0x9E3779B97F4A7C15) & (capacity - 1);
        }

        /// Find the slot holding `addr`, or null. Caller holds `mu`.
        fn find(addr: usize) ?*Slot {
            var i = hash(addr);
            var probes: usize = 0;
            while (probes < capacity) : (probes += 1) {
                const s = &slots[i];
                if (s.addr == addr) return s;
                if (s.addr == 0) return null;
                i = (i + 1) & (capacity - 1);
            }
            return null;
        }

        /// Track (and best-effort anon-name) the mapping at `[ptr, ptr+len)`.
        /// Call once per backing mmap; pair with `unregisterRegion` when the
        /// memory returns to the OS (not when it merely parks on a reuse cache).
        pub fn registerRegion(ptr: *const anyopaque, len: usize, tag: Tag) void {
            nameRegion(ptr, len, tagName(tag));
            const addr = @intFromPtr(ptr);
            if (addr <= tombstone) return;
            mu.lock();
            defer mu.unlock();
            if (live_count >= capacity / 2) {
                dropped_count += 1;
                return;
            }
            var i = hash(addr);
            while (true) {
                const s = &slots[i];
                if (s.addr == addr) {
                    // Re-register (shouldn't happen; be idempotent).
                    s.* = .{ .addr = addr, .len = len, .tag = tag };
                    return;
                }
                if (s.addr == 0 or s.addr == tombstone) {
                    s.* = .{ .addr = addr, .len = len, .tag = tag };
                    live_count += 1;
                    return;
                }
                i = (i + 1) & (capacity - 1);
            }
        }

        pub fn unregisterRegion(ptr: *const anyopaque) void {
            const addr = @intFromPtr(ptr);
            mu.lock();
            defer mu.unlock();
            const s = find(addr) orelse return;
            s.* = .{ .addr = tombstone };
            live_count -= 1;
        }

        /// Change the attribution of an already-registered region — e.g. a
        /// block-cache block claimed as a value-store segment. No-op if `ptr`
        /// isn't the base of a registered region.
        pub fn retagRegion(ptr: *const anyopaque, tag: Tag) void {
            const addr = @intFromPtr(ptr);
            mu.lock();
            defer mu.unlock();
            const s = find(addr) orelse return;
            s.tag = tag;
            nameRegion(ptr, s.len, tagName(tag));
        }

        pub const Residency = struct {
            /// Resident bytes per tag (mincore page count × page size).
            rss_bytes: [tag_count]u64 = @splat(0),
            /// Reserved (virtual) bytes per tag.
            reserved_bytes: [tag_count]u64 = @splat(0),
            regions: [tag_count]u32 = @splat(0),
            /// Registrations dropped because the table was full — attribution
            /// is an undercount if nonzero.
            dropped: u32 = 0,
        };

        /// Ask the kernel how much of each registered region is resident.
        /// This point-in-time scan is report-only. Off-Linux returns zeros.
        pub fn residency() Residency {
            var r: Residency = .{};
            if (comptime builtin.os.tag != .linux) return r;
            // Snapshot under the lock (registrations during the walk are lost,
            // which is fine for a report); mincore outside it.
            mu.lock();
            var snapshot: [capacity]Slot = slots;
            r.dropped = dropped_count;
            mu.unlock();
            for (&snapshot) |s| {
                if (s.addr <= tombstone) continue;
                const t = @backingInt(s.tag);
                r.regions[t] += 1;
                r.reserved_bytes[t] += s.len;
                r.rss_bytes[t] += residentBytes(s.addr, s.len);
            }
            return r;
        }

        /// Debug: print every registered region (addr, len, tag, resident MB).
        /// Used by `--mem-report=dump` to cross-check attribution against
        /// /proc/self/maps when a subsystem's numbers look off.
        pub fn dumpRegions() void {
            mu.lock();
            var snapshot: [capacity]Slot = slots;
            mu.unlock();
            for (&snapshot) |s| {
                if (s.addr <= tombstone) continue;
                const res_mb = @as(f64, @floatFromInt(residentBytes(s.addr, s.len))) / (1024.0 * 1024.0);
                std.debug.print("  region 0x{x:0>12} len {d:>12} {s:<16} rss {d:>8.1} MB\n", .{
                    s.addr, s.len, tagName(s.tag), res_mb,
                });
            }
        }

        /// Resident bytes in `[addr, addr+len)` per mincore, chunked so the
        /// per-page vector stays on the stack (32 KB vec = 128 MB per call).
        fn residentBytes(addr: usize, len: usize) u64 {
            const page = std.heap.pageSize();
            var vec: [32 * 1024]u8 = undefined;
            const chunk_bytes = vec.len * page;
            var resident: u64 = 0;
            var off: usize = 0;
            while (off < len) {
                const n = @min(chunk_bytes, len - off);
                const pages = (n + page - 1) / page;
                const rc = std.os.linux.mincore(@ptrFromInt(addr + off), n, &vec);
                if (@as(isize, @bitCast(rc)) != 0) return resident;
                for (vec[0..pages]) |v| {
                    if (v & 1 != 0) resident += page;
                }
                off += n;
            }
            return resident;
        }

        /// Name the anonymous mapping at `[ptr, ptr+len)` (`[anon:<name>]` in
        /// smaps). Best-effort: EINVAL on kernels without CONFIG_ANON_VMA_NAME,
        /// non-page-aligned starts, etc. — naming is diagnostic, never
        /// load-bearing. `name` must be static (kernel-copied; ≤80 chars).
        pub fn nameRegion(ptr: *const anyopaque, len: usize, name: [:0]const u8) void {
            if (comptime builtin.os.tag != .linux) return;
            const pr_set_vma = 0x53564d41;
            const pr_set_vma_anon_name = 0;
            const addr = @intFromPtr(ptr);
            if (addr & (std.heap.page_size_min - 1) != 0) return;
            _ = std.os.linux.prctl(
                pr_set_vma,
                pr_set_vma_anon_name,
                addr,
                len,
                @intFromPtr(name.ptr),
            );
        }
    };
}

test "register / residency / retag / unregister round-trip" {
    if (builtin.os.tag != .linux) return;
    const TestTag = enum { a, b, c };
    const TestVma = Vma(TestTag, .a, struct {
        fn n(t: TestTag) [:0]const u8 {
            return switch (t) {
                .a => "a",
                .b => "b",
                .c => "c",
            };
        }
    }.n);
    const len = 1 << 20;
    const mem = std.posix.mmap(
        null,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return;
    defer std.posix.munmap(@alignCast(mem[0..len]));

    const before = TestVma.residency();
    TestVma.registerRegion(mem.ptr, len, .b);
    // Touch two pages; residency must see at least those.
    mem[0] = 1;
    mem[std.heap.pageSize()] = 1;
    var r = TestVma.residency();
    const fs = @backingInt(TestVma.Tag.b);
    try std.testing.expect(r.regions[fs] == before.regions[fs] + 1);
    try std.testing.expect(r.rss_bytes[fs] >= before.rss_bytes[fs] + 2 * std.heap.pageSize());
    try std.testing.expect(r.reserved_bytes[fs] >= before.reserved_bytes[fs] + len);

    TestVma.retagRegion(mem.ptr, .a);
    r = TestVma.residency();
    try std.testing.expectEqual(before.regions[fs], r.regions[fs]);

    TestVma.unregisterRegion(mem.ptr);
    r = TestVma.residency();
    const bb = @backingInt(TestVma.Tag.a);
    try std.testing.expect(r.reserved_bytes[bb] < before.reserved_bytes[bb] + len);
}
