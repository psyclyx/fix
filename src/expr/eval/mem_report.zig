//! `--mem-report` peak-RSS attribution.
//!
//! Decomposes the process's memory across every subsystem (object stores,
//! interned strings, bytecode, retained AST arenas) alongside a kernel-truth
//! mincore/smaps breakdown, so it's visible where memory actually goes — the
//! tracked object stores are only part of it. Printed at `Engine.deinit`,
//! before any teardown frees state. Diagnostics only; off the hot path.

const std = @import("std");
const builtin = @import("builtin");
const heap_mod = @import("runtime").heap;
const intern_mod = @import("runtime").intern;
const Value = @import("runtime").value.Value;
const gc = @import("runtime").gc;
const mem_tag = @import("runtime").mem_tag;
const vma_mod = mem_tag.vma;
const block_cache = @import("base").block_cache;
const base_hugetlb = @import("base").hugetlb;
const bytecode = @import("../bytecode.zig");
const ast = @import("syntax").ast;

/// `--mem-report`: attribute peak RSS across every subsystem so we can see
/// where the memory actually goes (the tracked object stores are only part
/// of it — interned strings, bytecode, and AST arenas are large and the GC
/// never sees them). Printed at deinit, before any teardown frees state.
/// Takes the lower-layer state it reads, not the whole Engine.
pub fn report(
    heap: *heap_mod.ObjectHeap,
    intern: *intern_mod.InternTable,
    registry: *bytecode.ChunkRegistry,
    retained_arenas: []const ast.AstArena,
    mode: ?[]const u8,
) void {
    if (mode == null) return;
    const mb = struct {
        fn f(bytes: u64) f64 {
            return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        }
    }.f;
    const p = std.debug.print;

    const heap_counts = heap.counts();
    const obj_b = @as(u64, heap_counts.objects) * @sizeOf(heap_mod.Object);
    const val_b = @as(u64, heap_counts.values) * @sizeOf(Value);
    // SoA attr planes: 12 B/slot (8 B value + 4 B name), NOT sizeOf(AttrEntry).
    const attr_b = @as(u64, heap_counts.attrs) * heap_mod.attr_slot_bytes;
    const apos_b = @as(u64, heap_counts.attr_positions) * @sizeOf(heap_mod.AttrPosEntry);
    const stores_b = obj_b + val_b + attr_b + apos_b;

    const is = intern.stats();
    const intern_b = @as(u64, is.entries) * 12 + is.data_bytes; // Entry = 3×u32

    const cs = registry.stats();
    const code_b = cs.code_bytes + cs.const_count * @sizeOf(Value) +
        cs.source_map_entries * @sizeOf(bytecode.chunk.Chunk.SourceMapEntry);

    var arena_b: u64 = 0;
    for (retained_arenas) |*a| arena_b += a.inner.queryCapacity();

    const accounted = stores_b + intern_b + code_b + arena_b;
    const rss = gc.peakRssBytes();
    // Hugetlb pages are invisible to VmHWM/statm — with `--hugetlb` most of
    // the heap moves off-RSS, so the comparison base is RSS + the tracked
    // hugetlb high-water (see base/hugetlb.zig).
    const huge_peak = base_hugetlb.peakMappedBytes();
    const footprint = rss + huge_peak;

    p("\n=== MEM REPORT — peak RSS attribution ===\n", .{});
    p("  object store:   {d:>8.1} MB  ({d} objs)\n", .{ mb(obj_b), heap_counts.objects });
    p("  value store:    {d:>8.1} MB  ({d} vals)\n", .{ mb(val_b), heap_counts.values });
    p("  attr store:     {d:>8.1} MB  ({d} attrs)\n", .{ mb(attr_b), heap_counts.attrs });
    p("  attr-pos store: {d:>8.1} MB\n", .{mb(apos_b)});
    p("  -- stores total:{d:>8.1} MB\n", .{mb(stores_b)});
    const object_reuse = heap.objectReuseStats();
    p("  object reuse (hit / miss / fresh 256-slot refills / pool-empty collects): {d} / {d} / {d} / {d}\n", .{
        object_reuse.hits,
        object_reuse.misses,
        object_reuse.fresh_refills,
        object_reuse.collect_requests,
    });
    const reuse = heap.rangeReuseStats();
    p("  range reuse (exact / split / miss):\n", .{});
    p("    values:   {d} / {d} / {d}\n", .{ reuse.values.exact, reuse.values.split, reuse.values.miss });
    p("    attrs:    {d} / {d} / {d}\n", .{ reuse.attrs.exact, reuse.attrs.split, reuse.attrs.miss });
    p("    attr-pos: {d} / {d} / {d}\n", .{ reuse.attr_pos.exact, reuse.attr_pos.split, reuse.attr_pos.miss });
    p("    strbytes: {d} / {d} / {d}\n", .{ reuse.bytes.exact, reuse.bytes.split, reuse.bytes.miss });
    p("  range miss slots / fresh refills / fresh slots:\n", .{});
    p("    values:   {d} / {d} / {d}\n", .{ reuse.values.miss_slots, reuse.values.fresh_refills, reuse.values.fresh_slots });
    p("    attrs:    {d} / {d} / {d}\n", .{ reuse.attrs.miss_slots, reuse.attrs.fresh_refills, reuse.attrs.fresh_slots });
    p("    attr-pos: {d} / {d} / {d}\n", .{ reuse.attr_pos.miss_slots, reuse.attr_pos.fresh_refills, reuse.attr_pos.fresh_slots });
    p("    strbytes: {d} / {d} / {d}\n", .{ reuse.bytes.miss_slots, reuse.bytes.fresh_refills, reuse.bytes.fresh_slots });
    const free = heap.freeRangesStats();
    p("  free pool (ranges / slots / nonempty classes / max range):\n", .{});
    p("    objects:  {d} slots\n", .{free.objects});
    p("    values:   {d} / {d} / {d} / {d}\n", .{ free.values.ranges, free.values.slots, free.values.classes, free.values.max_len });
    p("    attrs:    {d} / {d} / {d} / {d}\n", .{ free.attrs.ranges, free.attrs.slots, free.attrs.classes, free.attrs.max_len });
    p("    attr-pos: {d} / {d} / {d} / {d}\n", .{ free.attr_pos.ranges, free.attr_pos.slots, free.attr_pos.classes, free.attr_pos.max_len });
    p("    strbytes: {d} / {d} / {d} / {d}\n", .{ free.bytes.ranges, free.bytes.slots, free.bytes.classes, free.bytes.max_len });
    p("  free-range vector capacity (used / allocated MB):\n", .{});
    p("    values:   {d:.1} / {d:.1}\n", .{ mb(free.values.ranges * @sizeOf(u64)), mb(free.values.capacity * @sizeOf(u64)) });
    p("    attrs:    {d:.1} / {d:.1}\n", .{ mb(free.attrs.ranges * @sizeOf(u64)), mb(free.attrs.capacity * @sizeOf(u64)) });
    p("    attr-pos: {d:.1} / {d:.1}\n", .{ mb(free.attr_pos.ranges * @sizeOf(u64)), mb(free.attr_pos.capacity * @sizeOf(u64)) });
    p("  interned strs:  {d:>8.1} MB  ({d} entries, {d:.1} MB data)\n", .{ mb(intern_b), is.entries, mb(is.data_bytes) });
    p("  bytecode:       {d:>8.1} MB  ({d} chunks, {d:.1} MB code)\n", .{ mb(code_b), cs.chunks, mb(cs.code_bytes) });
    p("  retained AST:   {d:>8.1} MB  ({d} arenas)\n", .{ mb(arena_b), retained_arenas.len });
    p("  == accounted:   {d:>8.1} MB\n", .{mb(accounted)});
    p("  peak RSS (VmHWM):{d:>7.1} MB\n", .{mb(rss)});
    if (huge_peak > 0) {
        p("  hugetlb (peak): {d:>8.1} MB  (2 MB pages; invisible to RSS)\n", .{mb(huge_peak)});
        p("  == footprint:   {d:>8.1} MB  (peak RSS + hugetlb peak)\n", .{mb(footprint)});
    }
    if (footprint > accounted) p("  UNACCOUNTED:    {d:>8.1} MB  (fiber stacks, GC bitmaps, allocator overhead, misc)\n", .{mb(footprint - accounted)});

    // Second table: kernel-truth attribution. Every big mapping the
    // process creates is registered (runtime/vma.zig), so asking
    // mincore for each region's resident pages decomposes the RSS the
    // slot-count table above can't see: segment-capacity slack +
    // pre-touch-ahead (store buckets minus their counted bytes), fiber
    // stacks, block-cache blocks (parse/compile arenas, retained AST,
    // builtin temps, intern data). The remainder vs current RSS is
    // allocator small-slabs + thread stacks + binary. Point-in-time
    // (now, at deinit) — compare against VmHWM above for drift.
    const res = vma_mod.residency();
    var tracked_total: u64 = 0;
    for (res.rss_bytes) |b| tracked_total += b;
    const cur_rss = gc.currentRssBytes();
    const retained_blocks = block_cache.retained_bytes.load(.monotonic);
    p("  -- mapping residency (mincore; current RSS {d:.1} MB + hugetlb {d:.1} MB) --\n", .{ mb(cur_rss), mb(base_hugetlb.mappedBytes()) });
    inline for (0..vma_mod.tag_count) |ti| {
        const tag: vma_mod.Tag = @fromBackingInt(@intCast(ti));
        p("  {s:<16}{d:>8.1} MB  ({d} regions, {d:.0} MB reserved)\n", .{
            mem_tag.tagName(tag), mb(res.rss_bytes[ti]), res.regions[ti], mb(res.reserved_bytes[ti]),
        });
    }
    p("  {s:<16}{d:>8.1} MB  (of fix:bigblock; parked on free stacks)\n", .{ "block-cache", mb(retained_blocks) });
    // The tracked regions' mincore residency includes hugetlb-backed pages
    // (the kernel's hugetlb walker reports them), while statm RSS excludes
    // them — compare against the combined footprint so "untracked" doesn't
    // underflow on a hugetlb run.
    const cur_foot = cur_rss + base_hugetlb.mappedBytes();
    if (cur_foot > tracked_total)
        p("  {s:<16}{d:>8.1} MB  (small-alloc slabs, thread stacks, binary)\n", .{ "untracked", mb(cur_foot - tracked_total) });
    if (res.dropped > 0)
        p("  WARNING: {d} region registrations dropped (table full) — undercount\n", .{res.dropped});
    if (std.mem.eql(u8, mode.?, "dump")) vma_mod.dumpRegions();

    // Decompose the "untracked" bucket above via /proc/self/smaps:
    // split current RSS into file-backed mappings, the main stack, brk heap,
    // and anonymous mappings. Subtracting registered large mappings from the
    // anonymous total isolates small slabs, worker stacks, and miscellaneous
    // anonymous allocations.
    smapsDecompose(tracked_total);
}

const SmapsKind = enum { file, stack, heap, anon };

fn smapsDecompose(tracked_anon: u64) void {
    if (comptime builtin.os.tag != .linux) return;
    const p = std.debug.print;
    const linux = std.os.linux;
    const fd_raw = linux.open("/proc/self/smaps", .{ .ACCMODE = .RDONLY }, 0);
    const fd: i32 = @intCast(@as(isize, @bitCast(fd_raw)));
    if (fd < 0) return;
    defer _ = linux.close(fd);

    var file_rss: u64 = 0;
    var stack_rss: u64 = 0;
    var anon_rss: u64 = 0;
    var heap_rss: u64 = 0;
    var hugetlb_kb: u64 = 0;
    // Track whether the current mapping is file-backed / [stack] /
    // [heap] / anonymous by its header line, then attribute each
    // "Rss:" line to that category. Read in chunks, reassembling lines
    // across chunk boundaries in a small carry buffer.
    var current: SmapsKind = .anon;
    var chunk: [64 * 1024]u8 = undefined;
    var carry: [512]u8 = undefined;
    var carry_len: usize = 0;
    while (true) {
        const n = linux.read(fd, &chunk, chunk.len);
        const rd: isize = @bitCast(n);
        if (rd <= 0) break;
        var data = chunk[0..@intCast(rd)];
        while (std.mem.indexOfScalar(u8, data, '\n')) |nl| {
            var line = data[0..nl];
            if (carry_len > 0) {
                // Prepend carried partial line.
                const take = @min(line.len, carry.len - carry_len);
                @memcpy(carry[carry_len..][0..take], line[0..take]);
                line = carry[0 .. carry_len + take];
                carry_len = 0;
            }
            classifySmapsLine(line, &current, &file_rss, &stack_rss, &heap_rss, &anon_rss, &hugetlb_kb);
            data = data[nl + 1 ..];
        }
        // Stash any trailing partial line.
        if (data.len > 0 and data.len <= carry.len) {
            @memcpy(carry[0..data.len], data);
            carry_len = data.len;
        }
    }
    const mb = struct {
        fn f(kb: u64) f64 {
            return @as(f64, @floatFromInt(kb)) / 1024.0;
        }
    }.f;
    p("  -- smaps decomposition (RSS by mapping kind) --\n", .{});
    p("  file-backed     {d:>8.1} MB  (binary + shared libs)\n", .{mb(file_rss)});
    p("  main [stack]    {d:>8.1} MB\n", .{mb(stack_rss)});
    p("  [heap] brk      {d:>8.1} MB\n", .{mb(heap_rss)});
    p("  anon total      {d:>8.1} MB\n", .{mb(anon_rss)});
    // Kernel-truth *faulted* hugetlb (smaps `Private/Shared_Hugetlb`; their
    // VMAs report `Rss: 0`). Compare with the tracked mapped figure above —
    // the delta is the flat store's reserved-but-untouched grow-ahead.
    if (hugetlb_kb > 0)
        p("  hugetlb faulted {d:>8.1} MB  (smaps *_Hugetlb; not in anon/RSS)\n", .{mb(hugetlb_kb)});
    const tracked_mb = @as(f64, @floatFromInt(tracked_anon)) / (1024.0 * 1024.0);
    p("  anon tracked    {d:>8.1} MB  (registered big regions)\n", .{tracked_mb});
    p("  anon UNTRACKED  {d:>8.1} MB  (SmpAllocator small slabs + worker stacks + misc)\n", .{mb(anon_rss) - tracked_mb});
}

fn classifySmapsLine(
    line: []const u8,
    current: *SmapsKind,
    file_rss: *u64,
    stack_rss: *u64,
    heap_rss: *u64,
    anon_rss: *u64,
    hugetlb_kb: *u64,
) void {
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    const tok0 = line[0..first_space];
    const is_header = std.mem.indexOfScalar(u8, tok0, '-') != null and tok0.len > 0 and isHexDash(tok0);
    if (is_header) {
        if (std.mem.indexOf(u8, line, "[stack]") != null) {
            current.* = .stack;
        } else if (std.mem.indexOf(u8, line, "[heap]") != null) {
            current.* = .heap;
        } else {
            current.* = if (std.mem.lastIndexOfScalar(u8, line, '/') != null) .file else .anon;
        }
        return;
    }
    if (std.mem.startsWith(u8, line, "Rss:")) {
        const kb = parseKb(line);
        switch (current.*) {
            .file => file_rss.* += kb,
            .stack => stack_rss.* += kb,
            .heap => heap_rss.* += kb,
            .anon => anon_rss.* += kb,
        }
        return;
    }
    // Hugetlb VMAs report `Rss: 0`; the faulted amount lives in these two
    // fields instead (private for our anonymous mappings).
    if (std.mem.startsWith(u8, line, "Private_Hugetlb:") or
        std.mem.startsWith(u8, line, "Shared_Hugetlb:"))
    {
        hugetlb_kb.* += parseKb(line);
    }
}

fn isHexDash(tok: []const u8) bool {
    for (tok) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!hex and c != '-') return false;
    }
    return true;
}

fn parseKb(line: []const u8) u64 {
    // "Rss:               1234 kB"
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next(); // "Rss:"
    const num = it.next() orelse return 0;
    return std.fmt.parseInt(u64, num, 10) catch 0;
}
