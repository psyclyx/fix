const std = @import("std");
const runtime = @import("runtime");
const types = runtime.types;
const Value = runtime.value.Value;
const ObjectHeap = runtime.heap.ObjectHeap;
const AttrEntry = runtime.heap.AttrEntry;
const AttrPosEntry = runtime.heap.AttrPosEntry;
const rt_int = runtime.int;

const opcode_mod = @import("../../opcode.zig");
const OpCode = opcode_mod.OpCode;
const Operand = opcode_mod.Operand;
const Width = opcode_mod.Width;
const encoding = @import("../../encoding.zig");
const name_tree = @import("../../name_tree.zig");
const NameId = name_tree.NameId;
const root_name_id = name_tree.root_name_id;
const model = @import("../model.zig");
const Chunk = model.Chunk;
const builder_mod = @import("../builder.zig");
const Capture = @import("../../../compiler/types.zig").Capture;
const deferred_table = @import("../../../compiler/deferred_table.zig");
const arena_mod = @import("base").arena;

const common = @import("wire.zig");
const validator = @import("validator.zig");

const Error = common.Error;
const LoadDeps = common.LoadDeps;
const LoadResult = common.LoadResult;
const Reader = common.Reader;
const corruptAt = common.corruptAt;
const wrapErr = common.wrapErr;
const readW = common.readWidth;
const writeW = common.writeWidth;
const format_version = common.format_version;
const checksum_end = common.checksum_end;
const checksum_seed = common.checksum_seed;

fn mapStr(idx: u32, strtab: []const types.InternId) Error!types.InternId {
    if (idx >= strtab.len) return corruptAt(@src());
    return strtab[idx];
}

fn mapName(biased: u32, name_table: []const NameId) Error!NameId {
    if (biased == 0) return root_name_id;
    const idx = biased - 1;
    if (idx >= name_table.len) return corruptAt(@src());
    return name_table[idx];
}

fn readSpan(r: *Reader, strtab: []const types.InternId) Error!Chunk.SourceSpan {
    const has_file = try r.u8_();
    const file: ?types.InternId = if (has_file != 0) try mapStr(try r.u32_(), strtab) else null;
    const offset = try r.u32_();
    const len = try r.u32_();
    const line = try r.u32_();
    const column = try r.u32_();
    return .{ .file = file, .offset = offset, .len = len, .line = line, .column = column };
}

fn readOptSpan(r: *Reader, strtab: []const types.InternId) Error!?Chunk.SourceSpan {
    if ((try r.u8_()) == 0) return null;
    return try readSpan(r, strtab);
}

fn readAttrPosEntry(r: *Reader, strtab: []const types.InternId) Error!AttrPosEntry {
    const name = try mapStr(try r.u32_(), strtab);
    const file = try mapStr(try r.u32_(), strtab);
    const line = try r.u32_();
    const column = try r.u32_();
    return .{ .name = name, .pos = .{ .file = file, .line = line, .column = column } };
}

fn readConstant(r: *Reader, heap: *ObjectHeap, strtab: []const types.InternId, scratch: std.mem.Allocator) Error!Value {
    const tag = try r.u8_();
    switch (tag) {
        0 => return Value.null_val,
        1 => return Value.boolVal(false),
        2 => return Value.boolVal(true),
        3 => {
            const v = try r.i64_();
            return rt_int.make(heap, v) catch return error.OutOfMemory;
        },
        4 => {
            const bits = try r.u64_();
            return Value.float(@bitCast(bits));
        },
        5 => return Value.string(try mapStr(try r.u32_(), strtab)),
        6 => return Value.path(try mapStr(try r.u32_(), strtab)),
        7 => {
            const count = try r.u32_();
            const entries = scratch.alloc(AttrEntry, count) catch return error.OutOfMemory;
            for (entries) |*e| {
                const name = try mapStr(try r.u32_(), strtab);
                const val = try readConstant(r, heap, strtab, scratch);
                e.* = .{ .name = name, .value = val };
            }
            const position_count = try r.u32_();
            const positions = scratch.alloc(AttrPosEntry, position_count) catch return error.OutOfMemory;
            for (positions) |*position| position.* = try readAttrPosEntry(r, strtab);
            // Both arrays were serialized in the writer's intern order;
            // `addAttrsWithPositions` restores the reader's order for both.
            const id = heap.addAttrsWithPositions(entries, positions) catch |e| return wrapErr(e);
            return Value.attrs(id);
        },
        8 => {
            const count = try r.u32_();
            const items = scratch.alloc(Value, count) catch return error.OutOfMemory;
            for (items) |*it| it.* = try readConstant(r, heap, strtab, scratch);
            const id = heap.addList(items) catch |e| return wrapErr(e);
            return Value.list(id);
        },
        9 => return Value.builtin(try r.u16_()),
        else => return error.Corrupt,
    }
}

/// Load-side twin of `Writer.normalizeField`: rewrite one operand field's
/// unit-local ordinal back into a real (fresh) id. `chunk_ids_so_far` is the
/// PREFIX of the unit's chunk ids already registered this load (chunks
/// register children-before-parents, so a `.chunk_id` reference can only
/// point at an earlier ordinal).
fn remapLoadedField(
    code: []u8,
    op: OpCode,
    f: Operand,
    at: usize,
    chunk_ids_so_far: []const types.ChunkId,
    strtab: []const types.InternId,
    deferred_ids: []const u32,
) Error!usize {
    const len = opcode_mod.checkedFieldLen(f, code, at) catch return corruptAt(@src());
    switch (f) {
        .deferred_id => |w| {
            std.debug.assert(op == .thunk_defer);
            const ordinal = readW(code, at, w);
            if (ordinal >= deferred_ids.len) return corruptAt(@src());
            writeW(code, at, w, deferred_ids[ordinal]);
        },
        .chunk_id => |w| {
            const ordinal = readW(code, at, w);
            if (ordinal >= chunk_ids_so_far.len) return corruptAt(@src());
            const new_id = chunk_ids_so_far[ordinal];
            if (w == .b2 and new_id > 0xFFFF) return error.Unfit;
            writeW(code, at, w, new_id);
        },
        .intern => |w| {
            const new_id = try mapStr(readW(code, at, w), strtab);
            if (w == .b2 and new_id > 0xFFFF) return error.Unfit;
            writeW(code, at, w, new_id);
        },
        .attr_path => |w| {
            const count = code[at];
            var p = at + 1;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const new_id = try mapStr(readW(code, p, w), strtab);
                if (w == .b2 and new_id > 0xFFFF) return error.Unfit;
                writeW(code, p, w, new_id);
                p += w.bytes();
            }
        },
        .bind => |w| {
            const count = encoding.readU16(code, at + 2);
            var p = at + 4;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const new_id = try mapStr(readW(code, p, w), strtab);
                if (w == .b2 and new_id > 0xFFFF) return error.Unfit;
                writeW(code, p, w, new_id);
                p += w.bytes() + 2;
            }
        },
        .mix => {
            const seg_count = code[at];
            var p = at + 2;
            var i: usize = 0;
            while (i < seg_count) : (i += 1) {
                const tag = code[p];
                p += 1;
                if (tag == 0) {
                    const new_id = try mapStr(encoding.readU32(code, p), strtab);
                    writeW(code, p, .b4, new_id);
                    p += 4;
                }
            }
        },
        .skip, .const_idx, .slot, .cap1, .count, .jump, .captures, .captures_slot => {},
    }
    return len;
}

/// Rewrite one chunk's unit-local ordinals into real ids and repair its
/// sorted invariants, in a single walk of the code.
///
/// These were two passes. Each decoded every instruction and asked
/// `opcode.layout` for its operand shape, so the load walked the same
/// bytecode twice to do work that is instruction-local on both sides. The
/// repair reads and writes only the instruction it is looking at, plus the
/// side-table range that instruction names, so merging the walks keeps the
/// same result. Order within an instruction is preserved: fields are remapped
/// first, because `attr_bind` sorts its pairs by the remapped name id.
///
/// The repair can rewrite the opcode byte (`attrs_new_named_srt` becomes
/// `attrs_new_named`). That is safe here for the same reason it was safe in a
/// separate pass: the two opcodes share an operand layout, and the cursor has
/// already read this instruction's shape.
fn remapAndFixChunk(
    code: []u8,
    chunk_ids_so_far: []const types.ChunkId,
    strtab: []const types.InternId,
    deferred_ids: []const u32,
    attr_names: []const types.InternId,
    attr_pos: []AttrPosEntry,
) Error!void {
    var cursor: opcode_mod.InstructionCursor = .{ .code = code };
    while (cursor.next() catch return corruptAt(@src())) |insn| {
        var off = insn.ip + 1;
        const op = insn.op;
        for (opcode_mod.layout(op)) |f| {
            off += try remapLoadedField(code, op, f, off, chunk_ids_so_far, strtab, deferred_ids);
        }
        std.debug.assert(off == insn.end);
        try fixSortedInvariantsAt(code, insn.ip, op, attr_names, attr_pos);
    }
}

/// Restore the sorted invariants the compiler baked in terms of the
/// WRITER's intern ids, which remapping does not preserve:
///   - `attrs_new_named(_pos)_srt` requires its `attr_names` range ascending
///     (values were emitted in that order — the pairing is positional, so
///     the range cannot be re-sorted). When remapping broke the order, the
///     site is rewritten to its unsorted twin, which sorts entries at build
///     time.
///   - the `_pos` variant's `attr_pos` range must stay sorted by name for
///     `findAttrPos`'s binary search — positions are self-contained
///     (name, pos) pairs, so each referenced range is re-sorted in place.
///   - `attr_bind`'s operand embeds (name, slot) pairs consumed by a sorted
///     merge walk; the pairs are self-contained and re-sorted in place.
/// One instruction's share of the sorted-invariant repair. Every case reads
/// and writes only this instruction's own operand bytes plus the side-table
/// range that instruction names, so the repair can share a walk with the id
/// remap. It runs after that instruction's fields are remapped, because
/// `attr_bind` sorts its pairs by the remapped name id.
fn fixSortedInvariantsAt(
    code: []u8,
    ip: usize,
    op: OpCode,
    attr_names: []const types.InternId,
    attr_pos: []AttrPosEntry,
) Error!void {
    {
        switch (op) {
            .attrs_new_named_srt, .attrs_new_named_pos_srt => {
                const count = encoding.readU16(code, ip + 1);
                const names_start = encoding.readU32(code, ip + 3);
                if (names_start + count > attr_names.len) return corruptAt(@src());
                var ascending = true;
                var i: usize = 1;
                while (i < count) : (i += 1) {
                    if (attr_names[names_start + i - 1] >= attr_names[names_start + i]) {
                        ascending = false;
                        break;
                    }
                }
                if (!ascending) {
                    code[ip] = @intFromEnum(@as(OpCode, if (op == .attrs_new_named_srt)
                        .attrs_new_named
                    else
                        .attrs_new_named_pos));
                }
                if (op == .attrs_new_named_pos_srt) {
                    const pos_count = encoding.readU16(code, ip + 7);
                    const pos_start = encoding.readU32(code, ip + 9);
                    if (pos_start + pos_count > attr_pos.len) return corruptAt(@src());
                    std.mem.sort(AttrPosEntry, attr_pos[pos_start .. pos_start + pos_count], {}, struct {
                        fn lessThan(_: void, a: AttrPosEntry, b: AttrPosEntry) bool {
                            return a.name < b.name;
                        }
                    }.lessThan);
                }
            },
            .attr_bind, .attr_bind_w => {
                const wide = op == .attr_bind_w;
                const pair_bytes: usize = (if (wide) @as(usize, 4) else 2) + 2;
                const count = encoding.readU16(code, ip + 3);
                const pairs_at = ip + 5;
                // Insertion-sort the (name, slot) pairs in place by name.
                var i: usize = 1;
                while (i < count) : (i += 1) {
                    var j = i;
                    while (j > 0) : (j -= 1) {
                        const a_at = pairs_at + (j - 1) * pair_bytes;
                        const b_at = pairs_at + j * pair_bytes;
                        const a_id = if (wide) encoding.readU32(code, a_at) else encoding.readU16(code, a_at);
                        const b_id = if (wide) encoding.readU32(code, b_at) else encoding.readU16(code, b_at);
                        if (a_id <= b_id) break;
                        var tmp: [6]u8 = undefined;
                        @memcpy(tmp[0..pair_bytes], code[a_at .. a_at + pair_bytes]);
                        std.mem.copyForwards(u8, code[a_at .. a_at + pair_bytes], code[b_at .. b_at + pair_bytes]);
                        @memcpy(code[b_at .. b_at + pair_bytes], tmp[0..pair_bytes]);
                    }
                }
            },
            else => {},
        }
    }
}

const LoadedChunk = struct {
    name: NameId,
    chunk: Chunk,

    fn deinit(self: *LoadedChunk, allocator: std.mem.Allocator) void {
        self.chunk.deinit(allocator);
    }
};

fn decodeChunk(
    r: *Reader,
    deps: LoadDeps,
    strtab: []const types.InternId,
    name_table: []const NameId,
    scratch: std.mem.Allocator,
) Error!LoadedChunk {
    const name_id = try mapName(try r.u32_(), name_table);

    const local_count = try r.u16_();
    const arity = try r.u16_();
    const strict_params = try r.u8_();

    const forced = try r.u64_();
    const deep = try r.u64_();
    const body_is_substantial = (try r.u8_()) != 0;
    const spec_band_small = (try r.u8_()) != 0;
    const strict_param = (try r.u8_()) != 0;
    const svu_flag = try r.u8_();
    const svu_val = try r.u16_();
    const strict_via_upvalue: ?u16 = if (svu_flag != 0) svu_val else null;

    const lp_tag = try r.u8_();
    const lambda_pattern: model.LambdaPattern = switch (lp_tag) {
        0 => .none,
        1 => .{ .var_pat = try mapStr(try r.u32_(), strtab) },
        2 => blk: {
            const bind_id = try mapStr(try r.u32_(), strtab);
            const has_bind = (try r.u8_()) != 0;
            const ellipsis = (try r.u8_()) != 0;
            break :blk .{ .attrs_pat = .{ .bind_name = bind_id, .has_bind = has_bind, .ellipsis = ellipsis } };
        },
        else => return error.Corrupt,
    };

    const body_span = try readOptSpan(r, strtab);

    const code_len = try r.u32_();
    const code_src = try r.bytesN(code_len);
    const code = deps.allocator.dupe(u8, code_src) catch return error.OutOfMemory;
    errdefer deps.allocator.free(code);

    const const_count = try r.u32_();
    const constants = deps.allocator.alloc(Value, const_count) catch return error.OutOfMemory;
    errdefer deps.allocator.free(constants);
    for (constants) |*c| c.* = try readConstant(r, deps.heap, strtab, scratch);

    const attr_names_count = try r.u32_();
    const attr_names = deps.allocator.alloc(types.InternId, attr_names_count) catch return error.OutOfMemory;
    errdefer deps.allocator.free(attr_names);
    for (attr_names) |*a| a.* = try mapStr(try r.u32_(), strtab);

    const attr_pos_count = try r.u32_();
    const attr_pos = deps.allocator.alloc(AttrPosEntry, attr_pos_count) catch return error.OutOfMemory;
    errdefer deps.allocator.free(attr_pos);
    for (attr_pos) |*e| e.* = try readAttrPosEntry(r, strtab);

    const function_args_count = try r.u32_();
    const function_args = deps.allocator.alloc(AttrEntry, function_args_count) catch return error.OutOfMemory;
    errdefer deps.allocator.free(function_args);
    for (function_args) |*e| {
        const name = try mapStr(try r.u32_(), strtab);
        const is_bool = (try r.u8_()) != 0;
        e.* = .{ .name = name, .value = Value.boolVal(is_bool) };
    }

    const function_arg_pos_count = try r.u32_();
    const function_arg_pos = deps.allocator.alloc(AttrPosEntry, function_arg_pos_count) catch return error.OutOfMemory;
    errdefer deps.allocator.free(function_arg_pos);
    for (function_arg_pos) |*e| e.* = try readAttrPosEntry(r, strtab);

    const capture_bytes_len = try r.u32_();
    const capture_src = try r.bytesN(capture_bytes_len);
    const capture_bytes = deps.allocator.dupe(u8, capture_src) catch return error.OutOfMemory;
    errdefer deps.allocator.free(capture_bytes);

    const source_map_count = try r.u32_();
    const source_map = deps.allocator.alloc(Chunk.SourceMapEntry, source_map_count) catch return error.OutOfMemory;
    errdefer deps.allocator.free(source_map);
    for (source_map) |*sm| {
        const start = try r.u32_();
        const end = try r.u32_();
        const span = try readSpan(r, strtab);
        sm.* = .{ .start = start, .end = end, .span = span };
    }

    const chunk: Chunk = .{
        .code = code,
        .constants = constants,
        .local_count = local_count,
        .arity = arity,
        .strict_params = strict_params,
        .scheduling = .{
            .body_is_substantial = body_is_substantial,
            .spec_band_small = spec_band_small,
            .strictness = .{ .forced_upvalues = forced, .deep_upvalues = deep },
            // Recomputed in the batch prepare step after ordinal remapping.
            .trivial = .none,
            .strict_param = strict_param,
            .strict_via_upvalue = strict_via_upvalue,
        },
        .function_args = function_args,
        .function_arg_pos = function_arg_pos,
        .attr_pos = attr_pos,
        .attr_names = attr_names,
        .capture_bytes = capture_bytes,
        .source_map = source_map,
        .body_span = body_span,
        .lambda_pattern = lambda_pattern,
    };

    return .{ .name = name_id, .chunk = chunk };
}

fn preflightRemap(code: []const u8, chunk_ids: []const types.ChunkId, strtab: []const types.InternId) Error!void {
    var cursor: opcode_mod.InstructionCursor = .{ .code = code };
    while (cursor.next() catch unreachable) |insn| {
        var off = insn.ip + 1;
        for (opcode_mod.layout(insn.op)) |field| {
            switch (field) {
                .chunk_id => |w| {
                    const id = chunk_ids[readW(code, off, w)];
                    if (w == .b2 and id > 0xFFFF) return error.Unfit;
                },
                .intern => |w| {
                    const id = strtab[readW(code, off, w)];
                    if (w == .b2 and id > 0xFFFF) return error.Unfit;
                },
                .attr_path => |w| if (w == .b2) {
                    var p = off + 1;
                    var i: usize = 0;
                    while (i < code[off]) : (i += 1) {
                        if (strtab[encoding.readU16(code, p)] > 0xFFFF) return error.Unfit;
                        p += 2;
                    }
                },
                .bind => |w| if (w == .b2) {
                    var p = off + 4;
                    var i: usize = 0;
                    while (i < encoding.readU16(code, off + 2)) : (i += 1) {
                        if (strtab[encoding.readU16(code, p)] > 0xFFFF) return error.Unfit;
                        p += 4;
                    }
                },
                .skip, .deferred_id, .const_idx, .slot, .cap1, .count, .jump, .captures, .captures_slot, .mix => {},
            }
            off += opcode_mod.fieldLen(field, code, off);
        }
    }
}

const CommitContext = struct {
    deps: LoadDeps,
    chunks: []Chunk,
    strtab: []const types.InternId,
    deferred_entries: []const deferred_table.Entry,
    deferred_ids: []u32,

    fn prepare(raw: *anyopaque, chunk_ids: []const types.ChunkId) anyerror!void {
        const self: *CommitContext = @ptrCast(@alignCast(raw));
        // All possible width failures precede deferred publication. The full
        // wire validator already proved every ordinal and side-table range.
        for (self.chunks) |chunk| try preflightRemap(chunk.code, chunk_ids, self.strtab);
        try self.deps.deferred.registerBatch(self.deferred_entries, self.deferred_ids);
        for (self.chunks, 0..) |*chunk, i| {
            const code = @constCast(chunk.code);
            remapAndFixChunk(
                code,
                chunk_ids[0..i],
                self.strtab,
                self.deferred_ids,
                chunk.attr_names,
                @constCast(chunk.attr_pos),
            ) catch unreachable;
            chunk.scheduling.trivial = builder_mod.classifyTrivialBody(
                chunk.code,
                chunk.constants,
                chunk.local_count,
            );
        }
    }
};

pub fn load(bytes: []const u8, deps: LoadDeps) Error!LoadResult {
    try validator.validateUnit(deps.allocator, bytes, deps.source.len);
    var r: Reader = .{ .bytes = bytes };
    const magic = try r.bytesN(4);
    if (!std.mem.eql(u8, magic, "FIXC")) return corruptAt(@src());
    const version = try r.u32_();
    if (version != format_version) return error.Stale;
    // Whole-payload integrity before any deserialization: a torn write or
    // bit flip must never reach the operand decoders.
    const sum = try r.u64_();
    if (sum != std.hash.Wyhash.hash(checksum_seed, bytes[checksum_end..])) return corruptAt(@src());
    const chunk_count = try r.u32_();
    const deferred_count = try r.u32_();
    const scope_count = try r.u32_();
    const strtab_count = try r.u32_();
    const name_node_count = try r.u32_();
    const top_ordinal = try r.u32_();
    if (chunk_count == 0 or top_ordinal >= chunk_count) return corruptAt(@src());

    // Wire shape is trusted from here. Scratch holds lookup tables and the
    // explicit owned unit; persistent slices remain owned here until the one
    // registry batch below succeeds.
    var base_arena = arena_mod.ArenaAllocator.init(deps.allocator);
    defer base_arena.deinit();
    const scratch = base_arena.allocator();

    const strtab = scratch.alloc(types.InternId, strtab_count) catch return error.OutOfMemory;
    for (strtab) |*slot| {
        const len = try r.u32_();
        const s = try r.bytesN(len);
        slot.* = deps.intern.intern(s) catch |e| return wrapErr(e);
    }

    const name_table = scratch.alloc(NameId, name_node_count) catch return error.OutOfMemory;
    for (name_table, 0..) |*slot, i| {
        const parent_biased = try r.u32_();
        const seg_stridx = try r.u32_();
        const synthetic = try r.u8_();
        const seg_id = try mapStr(seg_stridx, strtab);
        const parent: NameId = if (parent_biased == 0) root_name_id else blk: {
            const pidx = parent_biased - 1;
            if (pidx >= i) return corruptAt(@src()); // parent must precede child
            break :blk name_table[pidx];
        };
        slot.* = deps.registry.childName(parent, seg_id, synthetic != 0) catch |e| return wrapErr(e);
    }

    const scopes = scratch.alloc([]const Capture, scope_count) catch return error.OutOfMemory;
    for (scopes) |*scope| {
        const capture_count = try r.u16_();
        const caps = scratch.alloc(Capture, capture_count) catch return error.OutOfMemory;
        for (caps) |*cap| {
            const kind_byte = try r.u8_();
            const index = try r.u16_();
            const nid = try mapStr(try r.u32_(), strtab);
            cap.* = .{
                .name = deps.intern.get(nid),
                .name_id = nid,
                .kind = if (kind_byte == 0) .local else .upvalue,
                .index = index,
            };
        }
        scope.* = deps.deferred.adoptScope(caps) catch |e| return wrapErr(e);
    }

    const base_path = deps.deferred.internPath(deps.base_path) catch |e| return wrapErr(e);
    const source_path = deps.deferred.internPath(deps.source_path) catch |e| return wrapErr(e);
    const deferred_entries = scratch.alloc(deferred_table.Entry, deferred_count) catch return error.OutOfMemory;
    for (deferred_entries) |*entry| {
        const offset = try r.u32_();
        const span_len = try r.u32_();
        const name_biased = try r.u32_();
        const with_count = try r.u16_();
        const scope_ordinal = try r.u32_();

        const node = deps.ast_arena.createNode(.elided, .{ .atom = .{ .offset = offset, .len = span_len } }) catch return error.OutOfMemory;
        const name_id = try mapName(name_biased, name_table);

        entry.* = .{
            .node = node,
            .scope = scopes[scope_ordinal],
            .with_count = with_count,
            .source = deps.source,
            .base_path = base_path,
            .source_path = source_path,
            .source_file_id = null,
            .policy = deps.policy,
            .name_id = name_id,
        };
    }

    const new_chunk_ids = scratch.alloc(types.ChunkId, chunk_count) catch return error.OutOfMemory;
    const loaded = scratch.alloc(LoadedChunk, chunk_count) catch return error.OutOfMemory;
    var loaded_count: usize = 0;
    errdefer for (loaded[0..loaded_count]) |*chunk| chunk.deinit(deps.allocator);
    for (loaded) |*chunk| {
        chunk.* = try decodeChunk(&r, deps, strtab, name_table, scratch);
        loaded_count += 1;
    }
    const names = scratch.alloc(NameId, chunk_count) catch return error.OutOfMemory;
    const chunks = scratch.alloc(Chunk, chunk_count) catch return error.OutOfMemory;
    for (loaded, names, chunks) |item, *name, *chunk| {
        name.* = item.name;
        chunk.* = item.chunk;
    }
    const new_deferred_ids = scratch.alloc(u32, deferred_count) catch return error.OutOfMemory;
    var commit: CommitContext = .{
        .deps = deps,
        .chunks = chunks,
        .strtab = strtab,
        .deferred_entries = deferred_entries,
        .deferred_ids = new_deferred_ids,
    };
    deps.registry.registerNamedBatch(chunks, names, new_chunk_ids, &commit, CommitContext.prepare) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unfit => return error.Unfit,
        else => return error.Uncacheable,
    };
    loaded_count = 0;

    return .{
        .top = new_chunk_ids[top_ordinal],
        .chunk_count = chunk_count,
        .deferred_count = deferred_count,
    };
}
