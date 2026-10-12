//! Explicit 2 MB huge-page (hugetlb) backing for the evaluator's big memory.
//!
//! Policy shared by `block_cache.zig` and `segments.zig`. Candidate mappings
//! reserve, exclude themselves from `fork`, and write-prefault before they are
//! published. Any failure falls back to ordinary mappings.
//!
//! Each process composition root owns a `Policy` and passes it to consumers:
//!   - `off`  — never.
//!   - `on`   — always try; warn once when the pool can't serve a mapping.
//!   - `auto` — engage only when the 2 MB pool has unreserved capacity for a
//!     sensible floor (`auto_floor_bytes`) at first use; individual mmap
//!     failures after that fall back silently per-mapping.
//!
//! Hugetlb pages are absent from conventional RSS counters, so this module
//! tracks current and peak mapped bytes explicitly.

const std = @import("std");
const builtin = @import("builtin");
const base_options = @import("base_options");

pub const huge_page_size: usize = 2 << 20;

// Linux 5.14+. Zig's std.os.linux.MADV does not expose this newer value yet.
const madv_populate_write: u32 = 23;

/// `auto` engagement floor: the unreserved pool must cover at least this
/// much before auto turns hugetlb on. Sized to fit the flat store's first
/// grow-ahead chunk plus a couple of class blocks — below it the win is
/// negligible and the pool is better left to other consumers.
pub const auto_floor_bytes: usize = 256 << 20;

pub const Mode = enum(u8) { auto, on, off };

/// Bytes currently mapped as hugetlb by this process (via `map`/`mapFixed`),
/// and the high-water mark. `map` write-prefaults every page before returning,
/// so mapped bytes are both committed to the pool and physically instantiated.
var mapped_bytes: std.atomic.Value(usize) = .init(0);
var peak_mapped_bytes: std.atomic.Value(usize) = .init(0);

pub const Policy = struct {
    mode: std.atomic.Value(Mode),
    /// Cached `auto` resolution: 0 = unresolved, 1 = engaged, 2 = declined.
    auto_state: std.atomic.Value(u8) = .init(0),
    warned_fallback: std.atomic.Value(bool) = .init(false),

    pub fn init(mode: Mode) Policy {
        return .{ .mode = .init(mode) };
    }

    /// Reconfigure this policy before publishing it to memory consumers.
    /// Re-arms the cached `auto` decision and one-shot warning.
    pub fn setMode(self: *Policy, mode: Mode) void {
        self.mode.store(mode, .monotonic);
        self.auto_state.store(0, .monotonic);
        self.warned_fallback.store(false, .monotonic);
    }

    pub fn getMode(self: *const Policy) Mode {
        return self.mode.load(.monotonic);
    }

    /// Should a consumer attempt hugetlb right now? The mmap itself remains
    /// authoritative when pool state changes concurrently.
    pub fn wanted(self: *Policy) bool {
        if (comptime builtin.os.tag != .linux) return false;
        return switch (self.getMode()) {
            .off => false,
            .on => true,
            .auto => self.autoEngaged(),
        };
    }

    fn autoEngaged(self: *Policy) bool {
        const state = self.auto_state.load(.monotonic);
        if (state != 0) return state == 1;
        const engaged = defaultHugePageIs2M() and availablePoolBytes() >= auto_floor_bytes;
        self.auto_state.store(if (engaged) 1 else 2, .monotonic);
        return engaged;
    }

    fn noteFallback(self: *Policy) void {
        if (self.getMode() != .on) return;
        if (comptime builtin.is_test) return;
        if (self.warned_fallback.swap(true, .monotonic)) return;
        std.debug.print(
            "fix: warning: hugetlb pool exhausted, unavailable, or mapping hardening failed; falling back to normal pages " ++
                "(provision with `sysctl vm.nr_hugepages=N`, or pass --hugetlb off)\n",
            .{},
        );
    }
};

/// Parse a mode from CLI text.
pub fn parseMode(text: []const u8) ?Mode {
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "on")) return .on;
    if (std.mem.eql(u8, text, "off")) return .off;
    return null;
}

/// Unreserved 2 MB-pool capacity in bytes: (free − reserved) huge pages.
/// 0 when the pool is absent or sysfs is unreadable.
pub fn availablePoolBytes() usize {
    const free = readSysUint("/sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages") orelse return 0;
    const resv = readSysUint("/sys/kernel/mm/hugepages/hugepages-2048kB/resv_hugepages") orelse 0;
    if (resv >= free) return 0;
    return @as(usize, @intCast(free - resv)) * huge_page_size;
}

/// MAP_HUGETLB without a size suffix uses the kernel's *default* huge page
/// size; all our alignment/rounding assumes 2 MB. On a `default_hugepagesz=1G`
/// system the mmaps would mostly fail (clean fallback), but `auto` shouldn't
/// even engage there.
fn defaultHugePageIs2M() bool {
    var buf: [8192]u8 = undefined;
    const text = readFileInto("/proc/meminfo", &buf) orelse return false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Hugepagesize:")) continue;
        var it = std.mem.tokenizeScalar(u8, line["Hugepagesize:".len..], ' ');
        const tok = it.next() orelse return false;
        const kb = std.fmt.parseInt(u64, tok, 10) catch return false;
        return kb == 2048;
    }
    return false;
}

fn readSysUint(path: [:0]const u8) ?u64 {
    var buf: [64]u8 = undefined;
    const text = readFileInto(path, &buf) orelse return null;
    return parseLeadingUint(text);
}

/// First whitespace-delimited token as an unsigned integer.
pub fn parseLeadingUint(text: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, text, " \t\n");
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(u64, tok, 10) catch null;
}

/// Raw-syscall file read (no allocator, callable at any init order).
fn readFileInto(path: [:0]const u8, buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .linux) return null;
    const linux = std.os.linux;
    const fd_raw = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_raw)));
    if (fd < 0) return null;
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    const rd: isize = @bitCast(n);
    if (rd <= 0) return null;
    return buf[0..@intCast(rd)];
}

pub fn roundedLen(len: usize) usize {
    return std.mem.alignForward(usize, len, huge_page_size);
}

/// Map `len` (rounded up to 2 MB) of anonymous private hugetlb memory and make
/// it safe to publish to the application:
///   1. non-NORESERVE mmap commits the pool pages up front;
///   2. MADV_DONTFORK prevents a subprocess child from inheriting a private
///      mapping whose later COW could need an unreserved extra huge page;
///   3. madv_populate_write instantiates every page under the current
///      NUMA/cpuset policy, reporting a would-be SIGBUS as a syscall error.
/// Any failure unmaps the candidate and returns null so the caller can use its
/// ordinary allocation path. This intentionally makes Linux <5.14 (which has
/// no madv_populate_write) fall back rather than expose a weaker guarantee.
pub fn map(policy: *Policy, len: usize) ?[*]align(std.heap.page_size_min) u8 {
    if (comptime builtin.os.tag != .linux) return null;
    const rounded = roundedLen(len);
    const mem = std.posix.mmap(
        null,
        rounded,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .HUGETLB = true },
        -1,
        0,
    ) catch {
        policy.noteFallback();
        return null;
    };
    const ptr: [*]u8 = mem.ptr;
    if (std.os.linux.errno(std.os.linux.madvise(ptr, rounded, std.os.linux.MADV.DONTFORK)) != .SUCCESS or
        std.os.linux.errno(std.os.linux.madvise(ptr, rounded, madv_populate_write)) != .SUCCESS)
    {
        std.posix.munmap(mem);
        policy.noteFallback();
        return null;
    }
    noteMapped(rounded);
    return mem.ptr;
}

/// Overlay `[target, target+len)` — 2 MB-aligned, a 2 MB multiple — with
/// reserved, DONTFORK, write-prefaulted hugetlb pages. The flat store uses
/// this to grow its huge prefix ahead of the bump cursor; the caller must
/// guarantee the range holds no live data (the replaced mapping's contents
/// are discarded).
///
/// A failing `MAP_FIXED` mmap may unmap the target before reserving huge pages,
/// leaving a race while the hole is repaired. Avoid that window by:
///   1. `map(len)` at a kernel-chosen address — reservation, DONTFORK, and
///      prefault failures happen HERE with no effect on the target mapping;
///   2. `mremap(MAYMOVE|FIXED)` the fresh mapping onto the target — a
///      single syscall under mmap_lock, so no userspace-visible window
///      where the target is unmapped.
/// On failure the target is preserved or restored, and false is returned.
pub fn overlayFixed(policy: *Policy, target: [*]u8, len: usize) bool {
    if (comptime builtin.os.tag != .linux) return false;
    std.debug.assert(@intFromPtr(target) % huge_page_size == 0 and len % huge_page_size == 0 and len > 0);
    const src = map(policy, len) orelse return false;
    const rc = std.os.linux.mremap(src, len, len, .{ .MAYMOVE = true, .FIXED = true }, target);
    if (std.os.linux.errno(rc) == .SUCCESS and rc == @intFromPtr(target)) return true;
    // mremap failed (kernel VMA bookkeeping ENOMEM — not pool pressure).
    // Give the reservation back and make sure the target is a mapping, not
    // a hole: MREMAP_FIXED unmaps the target before moving, and a failure
    // after that point would leave it unmapped. Re-asserting a plain
    // NORESERVE mapping is idempotent when the target is still intact
    // (no live data by the caller's contract).
    unmap(src, len);
    const aligned: [*]align(std.heap.page_size_min) u8 = @alignCast(target);
    _ = std.posix.mmap(
        aligned,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true, .FIXED = true },
        -1,
        0,
    ) catch @panic("hugetlb: cannot restore mapping after failed overlay move");
    return false;
}

/// Unmap a region obtained from `map` (`rounded_len` = the 2 MB-rounded
/// length `map` actually mapped).
pub fn unmap(ptr: [*]u8, rounded_len: usize) void {
    const bytes: [*]align(std.heap.page_size_min) u8 = @alignCast(ptr);
    std.posix.munmap(bytes[0..rounded_len]);
    noteUnmapped(rounded_len);
}

fn noteMapped(n: usize) void {
    const now = mapped_bytes.fetchAdd(n, .monotonic) + n;
    var peak = peak_mapped_bytes.load(.monotonic);
    while (now > peak) {
        peak = peak_mapped_bytes.cmpxchgWeak(peak, now, .monotonic, .monotonic) orelse break;
    }
}

/// Public for consumers whose teardown unmaps hugetlb ranges as part of a
/// larger munmap (the flat store frees its whole reservation in one call).
pub fn noteUnmapped(n: usize) void {
    _ = mapped_bytes.fetchSub(n, .monotonic);
}

pub fn mappedBytes() usize {
    return mapped_bytes.load(.monotonic);
}

pub fn peakMappedBytes() usize {
    return peak_mapped_bytes.load(.monotonic);
}

test "parseMode accepts CLI mode names" {
    try std.testing.expectEqual(@as(?Mode, .auto), parseMode("auto"));
    try std.testing.expectEqual(@as(?Mode, .on), parseMode("on"));
    try std.testing.expectEqual(@as(?Mode, .off), parseMode("off"));
    try std.testing.expectEqual(@as(?Mode, null), parseMode(""));
    try std.testing.expectEqual(@as(?Mode, null), parseMode("1"));
    try std.testing.expectEqual(@as(?Mode, null), parseMode("yes"));
}

test "policy mode is local and reconfigurable" {
    var first = Policy.init(.off);
    var second = Policy.init(.on);
    try std.testing.expectEqual(Mode.off, first.getMode());
    try std.testing.expect(!first.wanted());
    try std.testing.expectEqual(Mode.on, second.getMode());
    first.setMode(.auto);
    try std.testing.expectEqual(Mode.auto, first.getMode());
    try std.testing.expectEqual(Mode.on, second.getMode());
}

test "parseLeadingUint" {
    try std.testing.expectEqual(@as(?u64, 2048), parseLeadingUint("2048\n"));
    try std.testing.expectEqual(@as(?u64, 7), parseLeadingUint("  7 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), parseLeadingUint("x"));
    try std.testing.expectEqual(@as(?u64, null), parseLeadingUint(""));
}

test "roundedLen rounds to 2 MB" {
    try std.testing.expectEqual(huge_page_size, roundedLen(1));
    try std.testing.expectEqual(huge_page_size, roundedLen(huge_page_size));
    try std.testing.expectEqual(2 * huge_page_size, roundedLen(huge_page_size + 1));
}

test "map/unmap: accounting balances whether or not the pool serves it" {
    if (comptime builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    var policy = Policy.init(.on);
    const before = mappedBytes();
    if (map(&policy, 3 << 20)) |p| {
        // Rounded to 2 huge pages; memory is usable end to end.
        try std.testing.expectEqual(before + (4 << 20), mappedBytes());
        try std.testing.expect(peakMappedBytes() >= mappedBytes());

        // QEMU user mode reports success for these guest madvise calls but
        // does not reproduce their kernel-visible residency/fork effects.
        // Cross-emulated tests still exercise the mapping and accounting;
        // native Linux CI verifies the two madvise contracts below.
        if (!base_options.test_emulated) {
            // madv_populate_write made every base page resident before `map`
            // returned, rather than leaving a possible SIGBUS for first touch.
            var resident: [(4 << 20) / std.heap.page_size_min]u8 = @splat(0);
            try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mincore(p, 4 << 20, &resident)));
            for (resident) |state| try std.testing.expect(state & 1 != 0);

            // MADV_DONTFORK removes the VMA from a child. Keep the child path
            // to raw syscalls only: this test may fork from a multithreaded
            // runner.
            const fork_rc = linux.fork();
            try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fork_rc));
            if (fork_rc == 0) {
                var state: [1]u8 = .{0};
                const inherited = linux.errno(linux.mincore(p, std.heap.page_size_min, &state)) == .SUCCESS;
                linux.exit_group(if (inherited) 1 else 0);
            }
            var status: i32 = 0;
            const waited = linux.waitpid(@intCast(fork_rc), &status, 0);
            try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(waited));
            try std.testing.expect(linux.W.IFEXITED(@bitCast(status)));
            try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(@bitCast(status)));
        }

        p[0] = 0xAB;
        p[(4 << 20) - 1] = 0xCD;
        try std.testing.expectEqual(@as(u8, 0xAB), p[0]);
        unmap(p, 4 << 20);
    }
    try std.testing.expectEqual(before, mappedBytes());
}
