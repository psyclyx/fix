//! Corpus-level bytecode analysis and reporting for `fix disasm --stats`.

const std = @import("std");
const bytecode = @import("../../bytecode.zig");
const let_float = @import("../../compiler/let_float.zig");
const opcode_mod = bytecode.opcode;
const encoding = bytecode.encoding;
const OpCode = opcode_mod.OpCode;
const ChunkRegistry = bytecode.ChunkRegistry;
const ChunkId = @import("runtime").types.ChunkId;

/// One row of counts + code bytes.
const StatRow = struct {
    count: u64 = 0,
    bytes: u64 = 0,
    fn add(self: *StatRow, b: u64) void {
        self.count += 1;
        self.bytes += b;
    }
};

/// Primary category of a chunk body, first match wins.
const ChunkCategory = enum {
    trivial_attr_access,
    trivial_identity,
    trivial_literal,
    trivial_closure0,
    trivial_closure_caps,
    trivial_builtins,
    const_builder, // only constant pushes + aggregate build + ret/halt
    const_scalar, // only constant pushes + ret/halt (no aggregate)
    shell, // builds an aggregate wired with thunks/closures
    general,
};

/// Whether `op` only pushes compile-time-known data (for the const_* buckets).
fn isConstOp(op: OpCode) bool {
    return switch (op) {
        .push_const, .push_const_ret, .push_true, .push_false, .push_null, .ret, .halt => true,
        else => false,
    };
}

fn isAggregateOp(op: OpCode) bool {
    return switch (op) {
        .attrs_new, .attrs_new_srt, .attrs_new_named_srt, .attrs_new_named_pos_srt, .list_new => true,
        else => false,
    };
}

fn isThunkFamilyOp(op: OpCode) bool {
    return switch (op) {
        .thunk, .thunk_w, .thunk_arg, .thunk_shell, .thunk_defer, .thunk_attr, .thunk_attr_w, .thunk_st, .thunk_st_cell, .thunk_w_st, .thunk_w_st_cell, .closure, .closure_w, .closure_cap, .closure_cap_w => true,
        else => false,
    };
}

/// Corpus statistics over every chunk in the registry: size and category
/// breakdowns, mnemonic histogram, position-table share, duplicate-body reuse,
/// and deflate compressibility of the concatenated code — the measurement
/// harness for codegen-size work.
pub fn write(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    registry: *const ChunkRegistry,
    let_float_stats: *const let_float.Stats,
) !void {
    const a = allocator;
    const n = registry.count();

    var total = StatRow{};
    var const_count: u64 = 0;
    var source_map_entries: u64 = 0;

    const bucket_lims = [_]u64{ 4, 8, 16, 32, 128, 512, 2048, 8192, std.math.maxInt(u64) };
    const bucket_names = [_][]const u8{ "<=4B", "<=8B", "<=16B", "<=32B", "<=128B", "<=512B", "<=2KB", "<=8KB", ">8KB" };
    var buckets: [bucket_lims.len]StatRow = @splat(.{});

    var cats = std.enums.EnumArray(ChunkCategory, StatRow).initFill(.{});
    var op_counts: [opcode_mod.count]u64 = @splat(0);
    var op_bytes: [opcode_mod.count]u64 = @splat(0);

    var pos_sites: u64 = 0;
    var pos_entries: u64 = 0;
    var pos_bytes: u64 = 0;
    var empty_attrs_chunks: u64 = 0;

    // Duplicate-body detection: hash of code bytes → (count, size). Chunks with
    // no local constants are fully parametric, so byte-identical code there is
    // semantically interchangeable; track both scopes.
    const DupInfo = struct { count: u64, size: u64 };
    var dups_all: std.AutoHashMapUnmanaged(u64, DupInfo) = .empty;
    defer dups_all.deinit(a);
    var dups_free: std.AutoHashMapUnmanaged(u64, DupInfo) = .empty;
    defer dups_free.deinit(a);

    // Deflate the concatenated code stream to gauge redundancy. (Compress.init
    // asserts the output writer has usable buffer capacity.)
    var flate_out: std.Io.Writer.Allocating = try .initCapacity(a, 1 << 20);
    defer flate_out.deinit();
    const flate_window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(flate_window);
    var flate = try std.compress.flate.Compress.init(&flate_out.writer, flate_window, .raw, .default);

    var id: ChunkId = 0;
    while (id < n) : (id += 1) {
        const chunk = registry.get(id) orelse continue;
        const code = chunk.code;
        total.add(code.len);
        const_count += chunk.constants.len;
        source_map_entries += chunk.source_map.len;
        pos_entries += chunk.attr_pos.len;
        pos_bytes += @as(u64, chunk.attr_pos.len) * 16;
        for (bucket_lims, 0..) |lim, i| {
            if (code.len <= lim) {
                buckets[i].add(code.len);
                break;
            }
        }
        flate.writer.writeAll(code) catch {};

        const h = std.hash.Wyhash.hash(0, code);
        {
            const gop = try dups_all.getOrPut(a, h);
            if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0, .size = code.len };
            gop.value_ptr.count += 1;
        }
        if (chunk.constants.len == 0 and chunk.local_count == 0) {
            const gop = try dups_free.getOrPut(a, h);
            if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0, .size = code.len };
            gop.value_ptr.count += 1;
        }

        // Opcode walk (operand lengths via the same decoder the listing uses).
        var only_const = true;
        var has_agg = false;
        var has_thunk = false;
        var ip: usize = 0;
        while (ip < code.len) {
            const op_byte = code[ip];
            if (op_byte >= opcode_mod.count) {
                ip += 1;
                only_const = false;
                continue;
            }
            const op: OpCode = @fromBackingInt(@intCast(op_byte));
            const start = ip;
            ip += 1;
            // Length-only pass: no rendering, straight from the operand-shape
            // table (the same source `writeOperands` asserts itself against).
            ip = @min(ip + opcode_mod.operandLen(op, code, ip), code.len);
            op_counts[op_byte] += 1;
            op_bytes[op_byte] += ip - start;
            if (!isConstOp(op) and !isAggregateOp(op)) only_const = false;
            if (isAggregateOp(op)) has_agg = true;
            if (isThunkFamilyOp(op)) has_thunk = true;
            switch (op) {
                .attrs_new_named_pos_srt => pos_sites += 1,
                .attrs_new, .attrs_new_srt => {
                    if (code.len == 5 and encoding.readU16(code, start + 1) == 0) empty_attrs_chunks += 1;
                },
                else => {},
            }
        }

        const cat: ChunkCategory = switch (chunk.scheduling.trivial) {
            .attr_access => .trivial_attr_access,
            .identity_upvalue => .trivial_identity,
            .literal => .trivial_literal,
            .closure_zero => .trivial_closure0,
            .closure_captures => .trivial_closure_caps,
            .builtins => .trivial_builtins,
            .none => if (only_const and has_agg) .const_builder else if (only_const) .const_scalar else if (has_agg and has_thunk) .shell else .general,
        };
        cats.getPtr(cat).add(code.len);
    }
    flate.finish() catch {};
    flate.writer.flush() catch {};
    const flate_bytes = flate_out.writer.buffered().len;

    // ---- report ----
    try writer.print("chunks {d}   code {d} B   constants {d}   source-map entries {d}\n", .{ total.count, total.bytes, const_count, source_map_entries });
    if (total.count > 0) try writer.print("avg chunk {d} B   deflate(code) {d} B ({d}.{d:0>2}x)\n", .{ total.bytes / total.count, flate_bytes, total.bytes / @max(flate_bytes, 1), (total.bytes * 100 / @max(flate_bytes, 1)) % 100 });

    try writer.writeAll("\nsize buckets            count       bytes\n");
    for (bucket_names, buckets) |bn, b| {
        try writer.print("  {s:<20} {d:>10} {d:>11}\n", .{ bn, b.count, b.bytes });
    }

    try writer.writeAll("\ncategories              count       bytes\n");
    inline for (@typeInfo(ChunkCategory).@"enum".field_names) |f| {
        const row = cats.get(@field(ChunkCategory, f));
        if (row.count > 0) try writer.print("  {s:<20} {d:>10} {d:>11}\n", .{ f, row.count, row.bytes });
    }
    if (empty_attrs_chunks > 0) try writer.print("  (of const_builder: empty-attrs chunks {d})\n", .{empty_attrs_chunks});

    // Top mnemonics by count.
    try writer.writeAll("\ntop mnemonics           count       bytes\n");
    var shown: usize = 0;
    var used: [opcode_mod.count]bool = @splat(false);
    while (shown < 15) : (shown += 1) {
        var best: usize = 0;
        var best_count: u64 = 0;
        for (op_counts, 0..) |c, i| {
            if (!used[i] and c > best_count) {
                best = i;
                best_count = c;
            }
        }
        if (best_count == 0) break;
        used[best] = true;
        try writer.print("  {s:<20} {d:>10} {d:>11}\n", .{ @tagName(@as(OpCode, @fromBackingInt(@intCast(best)))), op_counts[best], op_bytes[best] });
    }

    if (total.bytes > 0) {
        try writer.print("\nposition side-table (external to code): sites {d}   entries {d}   bytes {d}\n", .{ pos_sites, pos_entries, pos_bytes });
    }

    // Duplicate summaries.
    inline for (.{ .{ "all chunks", &dups_all }, .{ "const-free chunks", &dups_free } }) |pair| {
        var distinct: u64 = 0;
        var members: u64 = 0;
        var wasted: u64 = 0;
        var it = pair[1].valueIterator();
        while (it.next()) |v| {
            distinct += 1;
            members += v.count;
            wasted += (v.count - 1) * v.size;
        }
        try writer.print("duplicate bodies ({s}): members {d}   distinct {d}   duplicates {d}   wasted bytes {d}\n", .{ pair[0], members, distinct, members - distinct, wasted });
    }

    // Binding-placement census for this Engine (nonzero only when the corpus
    // was compiled by it, e.g. `disasm --stats --eval`).
    try writer.print("\nlet-float census:\n", .{});
    try let_float.writeReport(writer, let_float_stats);
}
