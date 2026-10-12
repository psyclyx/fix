//! Compile-unit encoder: normalize process-local ids and emit the v4 wire format.

const std = @import("std");
const runtime = @import("runtime");
const types = runtime.types;
const Value = runtime.value.Value;
const InternTable = runtime.intern.InternTable;
const ObjectHeap = runtime.heap.ObjectHeap;
const AttrEntry = runtime.heap.AttrEntry;
const AttrPosEntry = runtime.heap.AttrPosEntry;
const rt_int = runtime.int;
const ast = @import("syntax").ast;
const arena_mod = @import("base").arena;
const opcode_mod = @import("../../opcode.zig");
const OpCode = opcode_mod.OpCode;
const Operand = opcode_mod.Operand;
const Width = opcode_mod.Width;
const encoding = @import("../../encoding.zig");
const name_tree_mod = @import("../../name_tree.zig");
const NameId = name_tree_mod.NameId;
const root_name_id = name_tree_mod.root_name_id;
const model = @import("../model.zig");
const Chunk = model.Chunk;
const registry_mod = @import("../registry.zig");
const Capture = @import("../../../compiler/types.zig").Capture;
const deferred_table = @import("../../../compiler/deferred_table.zig");
const common = @import("wire.zig");
const Error = common.Error;
const UnitRecord = common.UnitRecord;
const readW = common.readWidth;
const writeW = common.writeWidth;
const wrapErr = common.wrapErr;
const format_version = common.format_version;
const checksum_start = common.checksum_start;
const checksum_end = common.checksum_end;
const checksum_seed = common.checksum_seed;

const NameNodeRec = struct { parent: u32, segment: u32, synthetic: u8 };
const ScopeKey = struct { ptr: usize, len: usize };

const Writer = struct {
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    registry: *const registry_mod.ChunkRegistry,
    body: std.ArrayListUnmanaged(u8) = .empty,
    str_map: std.AutoHashMapUnmanaged(types.InternId, u32) = .empty,
    str_order: std.ArrayListUnmanaged(types.InternId) = .empty,
    name_map: std.AutoHashMapUnmanaged(NameId, u32) = .empty,
    name_nodes: std.ArrayListUnmanaged(NameNodeRec) = .empty,
    chunk_ordinal: std.AutoHashMapUnmanaged(types.ChunkId, u32) = .empty,
    chunk_order: std.ArrayListUnmanaged(types.ChunkId) = .empty,
    deferred_ordinal: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    scope_ordinal: std.AutoHashMapUnmanaged(ScopeKey, u32) = .empty,
    scopes: std.ArrayListUnmanaged([]const Capture) = .empty,

    fn deinit(self: *Writer) void {
        self.body.deinit(self.allocator);
        self.str_map.deinit(self.allocator);
        self.str_order.deinit(self.allocator);
        self.name_map.deinit(self.allocator);
        self.name_nodes.deinit(self.allocator);
        self.chunk_ordinal.deinit(self.allocator);
        self.chunk_order.deinit(self.allocator);
        self.deferred_ordinal.deinit(self.allocator);
        self.scope_ordinal.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
    }

    fn w8(self: *Writer, v: u8) Error!void {
        try self.body.append(self.allocator, v);
    }
    fn w16(self: *Writer, v: u16) Error!void {
        try encoding.writeU16(&self.body, self.allocator, v);
    }
    fn w32(self: *Writer, v: u32) Error!void {
        try encoding.writeU32(&self.body, self.allocator, v);
    }
    fn w64(self: *Writer, v: u64) Error!void {
        try encoding.writeU32(&self.body, self.allocator, @truncate(v));
        try encoding.writeU32(&self.body, self.allocator, @truncate(v >> 32));
    }
    fn wI64(self: *Writer, v: i64) Error!void {
        try self.w64(@bitCast(v));
    }
    fn wBytes(self: *Writer, b: []const u8) Error!void {
        try self.body.appendSlice(self.allocator, b);
    }

    /// Unit-local string index for `id`, interning it into the write-time
    /// string table on first use (dedup by InternId).
    fn internStr(self: *Writer, id: types.InternId) Error!u32 {
        const gop = try self.str_map.getOrPut(self.allocator, id);
        if (gop.found_existing) return gop.value_ptr.*;
        const idx: u32 = @intCast(self.str_order.items.len);
        try self.str_order.append(self.allocator, id);
        gop.value_ptr.* = idx;
        return idx;
    }

    /// Unit-local BIASED name-node id for the global `id` (0 = root, else
    /// 1+ordinal into the write-time node list), walking + interning the
    /// node's ancestor chain (parent-before-child) on first use. Mirrors
    /// `NameId`'s own root-biased scheme so the load side can reuse it
    /// verbatim.
    fn internName(self: *Writer, id: NameId) Error!u32 {
        if (id == root_name_id) return 0;
        if (self.name_map.get(id)) |idx| return idx + 1;
        const view = self.registry.nameNode(id) orelse return error.Uncacheable;
        const parent_biased = try self.internName(view.parent);
        const seg_idx = try self.internStr(view.segment);
        const idx: u32 = @intCast(self.name_nodes.items.len);
        try self.name_nodes.append(self.allocator, .{
            .parent = parent_biased,
            .segment = seg_idx,
            .synthetic = if (view.synthetic) 1 else 0,
        });
        try self.name_map.put(self.allocator, id, idx);
        return idx + 1;
    }

    fn writeSpan(self: *Writer, span: Chunk.SourceSpan) Error!void {
        if (span.file) |f| {
            try self.w8(1);
            try self.w32(try self.internStr(f));
        } else {
            try self.w8(0);
        }
        try self.w32(span.offset);
        try self.w32(span.len);
        try self.w32(span.line);
        try self.w32(span.column);
    }

    fn writeOptSpan(self: *Writer, opt: ?Chunk.SourceSpan) Error!void {
        if (opt) |s| {
            try self.w8(1);
            try self.writeSpan(s);
        } else {
            try self.w8(0);
        }
    }

    /// `heap.AttrPosEntry.pos.file` is a plain `InternId` (never optional —
    /// unlike `Chunk.SourceSpan.file`), so unlike `writeSpan` this carries no
    /// presence flag; every entry gets a stridx unconditionally.
    fn writeAttrPos(self: *Writer, e: AttrPosEntry) Error!void {
        try self.w32(try self.internStr(e.name));
        try self.w32(try self.internStr(e.pos.file));
        try self.w32(e.pos.line);
        try self.w32(e.pos.column);
    }

    fn writeConstant(self: *Writer, val: Value) Error!void {
        if (val.isNull()) return self.w8(0);
        if (val.isBool()) return self.w8(if (val.asBool()) 2 else 1);
        if (rt_int.isAnyInt(val)) {
            try self.w8(3);
            return self.wI64(rt_int.get(val, self.heap));
        }
        if (val.isFloat()) {
            try self.w8(4);
            return self.w64(@bitCast(val.asFloat()));
        }
        if (val.isString()) {
            try self.w8(5);
            return self.w32(try self.internStr(val.asInternId()));
        }
        if (val.isPath()) {
            try self.w8(6);
            return self.w32(try self.internStr(val.asInternId()));
        }
        if (val.isAttrs()) {
            try self.w8(7);
            const object_id = val.asObjectId();
            const entries = self.heap.materializeAttrs(object_id) catch |e| return wrapErr(e);
            try self.w32(@intCast(entries.len()));
            for (entries.names, entries.values) |ent_name, ent_value| {
                try self.w32(try self.internStr(ent_name));
                try self.writeConstant(ent_value);
            }
            var position_count: u32 = 0;
            for (entries.names) |ent_name| if (self.heap.getAttrPos(object_id, ent_name) != null) {
                position_count += 1;
            };
            try self.w32(position_count);
            for (entries.names) |ent_name| if (self.heap.getAttrPos(object_id, ent_name)) |pos| {
                try self.w32(try self.internStr(ent_name));
                try self.w32(try self.internStr(pos.file));
                try self.w32(pos.line);
                try self.w32(pos.column);
            };
            return;
        }
        if (val.isList()) {
            try self.w8(8);
            const items = self.heap.getList(val.asObjectId()) catch |e| return wrapErr(e);
            try self.w32(@intCast(items.len));
            for (items) |item| try self.writeConstant(item);
            return;
        }
        if (val.isBuiltin()) {
            try self.w8(9);
            return self.w16(val.asBuiltinId());
        }
        return error.Uncacheable;
    }

    /// Normalize one operand field of `op` at byte offset `at` in `code` (a
    /// scratch-owned mutable copy): rewrite id-carrying fields in place to
    /// unit-local ordinals, leave everything else untouched. Returns the
    /// field's byte length (from `opcode.fieldLen`, computed against the
    /// UN-mutated bytes — rewriting an id never changes a field's length).
    fn normalizeField(self: *Writer, code: []u8, op: OpCode, f: Operand, at: usize) Error!usize {
        const len = opcode_mod.fieldLen(f, code, at);
        switch (f) {
            .deferred_id => |w| {
                std.debug.assert(op == .thunk_defer);
                const old = readW(code, at, w);
                const ordinal = self.deferred_ordinal.get(old) orelse return error.Uncacheable;
                writeW(code, at, w, ordinal);
            },
            .chunk_id => |w| {
                const old: types.ChunkId = readW(code, at, w);
                const ordinal = self.chunk_ordinal.get(old) orelse return error.Uncacheable;
                if (w == .b2 and ordinal > 0xFFFF) return error.Uncacheable;
                writeW(code, at, w, ordinal);
            },
            .intern => |w| {
                const old: types.InternId = readW(code, at, w);
                const idx = try self.internStr(old);
                if (w == .b2 and idx > 0xFFFF) return error.Uncacheable;
                writeW(code, at, w, idx);
            },
            .attr_path => |w| {
                const count = code[at];
                var p = at + 1;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const old: types.InternId = readW(code, p, w);
                    const idx = try self.internStr(old);
                    if (w == .b2 and idx > 0xFFFF) return error.Uncacheable;
                    writeW(code, p, w, idx);
                    p += w.bytes();
                }
            },
            .bind => |w| {
                const count = encoding.readU16(code, at + 2);
                var p = at + 4;
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const old: types.InternId = readW(code, p, w);
                    const idx = try self.internStr(old);
                    if (w == .b2 and idx > 0xFFFF) return error.Uncacheable;
                    writeW(code, p, w, idx);
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
                        const old: types.InternId = encoding.readU32(code, p);
                        const idx = try self.internStr(old);
                        writeW(code, p, .b4, idx);
                        p += 4;
                    }
                }
            },
            // Explicitly id-free fields carry no chunk/intern/deferred
            // reference — local/upvalue slots, stack counts, side-table
            // (start,count) refs into THIS chunk's own capture_bytes, jump
            // offsets. Left byte-identical.
            .skip, .const_idx, .slot, .cap1, .count, .jump, .captures, .captures_slot => {},
        }
        return len;
    }

    fn normalizeCode(self: *Writer, scratch: std.mem.Allocator, code: []const u8) Error![]u8 {
        const copy = try scratch.dupe(u8, code);
        var ip: usize = 0;
        while (ip < copy.len) {
            const op: OpCode = @fromBackingInt(@intCast(copy[ip]));
            var off = ip + 1;
            for (opcode_mod.layout(op)) |f| off += try self.normalizeField(copy, op, f, off);
            ip = off;
        }
        return copy;
    }

    fn writeChunkRecord(self: *Writer, scratch: std.mem.Allocator, ch: *const Chunk, name: NameId) Error!void {
        try self.w32(try self.internName(name));
        try self.w16(ch.local_count);
        try self.w16(ch.arity);
        try self.w8(ch.strict_params);

        const sched = ch.scheduling;
        try self.w64(sched.strictness.forced_upvalues);
        try self.w64(sched.strictness.deep_upvalues);
        try self.w8(if (sched.body_is_substantial) 1 else 0);
        try self.w8(if (sched.spec_band_small) 1 else 0);
        try self.w8(if (sched.strict_param) 1 else 0);
        if (sched.strict_via_upvalue) |u| {
            try self.w8(1);
            try self.w16(u);
        } else {
            try self.w8(0);
            try self.w16(0);
        }

        switch (ch.lambda_pattern) {
            .none => try self.w8(0),
            .var_pat => |vid| {
                try self.w8(1);
                try self.w32(try self.internStr(vid));
            },
            .attrs_pat => |ap| {
                try self.w8(2);
                try self.w32(try self.internStr(ap.bind_name));
                try self.w8(if (ap.has_bind) 1 else 0);
                try self.w8(if (ap.ellipsis) 1 else 0);
            },
        }

        try self.writeOptSpan(ch.body_span);

        const normalized = try self.normalizeCode(scratch, ch.code);
        try self.w32(@intCast(normalized.len));
        try self.wBytes(normalized);

        try self.w32(@intCast(ch.constants.len));
        for (ch.constants) |v| try self.writeConstant(v);

        try self.w32(@intCast(ch.attr_names.len));
        for (ch.attr_names) |aid| try self.w32(try self.internStr(aid));

        try self.w32(@intCast(ch.attr_pos.len));
        for (ch.attr_pos) |e| try self.writeAttrPos(e);

        try self.w32(@intCast(ch.function_args.len));
        for (ch.function_args) |e| {
            if (!e.value.isBool()) return error.Uncacheable;
            try self.w32(try self.internStr(e.name));
            try self.w8(if (e.value.asBool()) 1 else 0);
        }

        try self.w32(@intCast(ch.function_arg_pos.len));
        for (ch.function_arg_pos) |e| try self.writeAttrPos(e);

        try self.w32(@intCast(ch.capture_bytes.len));
        try self.wBytes(ch.capture_bytes);

        try self.w32(@intCast(ch.source_map.len));
        for (ch.source_map) |sm| {
            try self.w32(sm.start);
            try self.w32(sm.end);
            try self.writeSpan(sm.span);
        }
    }

    fn internScope(self: *Writer, scope: []const Capture) Error!u32 {
        const key: ScopeKey = .{ .ptr = @intFromPtr(scope.ptr), .len = scope.len };
        const gop = try self.scope_ordinal.getOrPut(self.allocator, key);
        if (gop.found_existing) return gop.value_ptr.*;
        const ordinal: u32 = @intCast(self.scopes.items.len);
        try self.scopes.append(self.allocator, scope);
        gop.value_ptr.* = ordinal;
        return ordinal;
    }

    fn writeScopeRecord(self: *Writer, scope: []const Capture) Error!void {
        try self.w16(@intCast(scope.len));
        for (scope) |cap| {
            try self.w8(if (cap.kind == .local) 0 else 1);
            try self.w16(cap.index);
            try self.w32(try self.internStr(cap.name_id));
        }
    }

    fn writeDeferredRecord(self: *Writer, entry: *const deferred_table.Entry) Error!void {
        const node = entry.node;
        // Only parser-elided bodies are cacheable: their atom is the span
        // `scanElidableBody` chose, guaranteed to re-parse standalone. A
        // regular node's `span` EXCLUDES leading keywords (`with lib; …`
        // spans start at `lib`), so re-parsing it would fail or change
        // meaning — such a unit stays uncached.
        const atom: ast.Node.Atom = if (node.tag == .elided) node.data.atom else return error.Uncacheable;
        try self.w32(atom.offset);
        try self.w32(atom.len);
        try self.w32(try self.internName(entry.name_id));
        try self.w16(entry.with_count);
        try self.w32(try self.internScope(entry.scope));
    }
};

pub fn serialize(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.ChunkRegistry,
    intern: *InternTable,
    heap: *ObjectHeap,
    deferred: *const deferred_table.Table,
    unit: UnitRecord,
) Error![]u8 {
    if (unit.chunk_ids.len == 0) return error.Uncacheable;

    var base_arena = arena_mod.ArenaAllocator.init(allocator);
    defer base_arena.deinit();
    const scratch = base_arena.allocator();

    var w: Writer = .{ .allocator = allocator, .intern = intern, .heap = heap, .registry = registry };
    defer w.deinit();

    // Persistent/debug compilers can reuse a deduplicated chunk more than
    // once in one unit. Keep the first topological occurrence: references
    // remain backward and the header can point at an earlier top record.
    for (unit.chunk_ids) |cid| {
        if (w.chunk_ordinal.contains(cid)) continue;
        const ordinal: u32 = @intCast(w.chunk_order.items.len);
        try w.chunk_ordinal.put(allocator, cid, ordinal);
        try w.chunk_order.append(allocator, cid);
    }
    const top_ordinal = w.chunk_ordinal.get(unit.chunk_ids[unit.chunk_ids.len - 1]) orelse unreachable;
    for (unit.deferred_ids, 0..) |did, i| try w.deferred_ordinal.put(allocator, did, @intCast(i));

    // Scope records precede deferred records and are referenced by ordinal;
    // all entries of one generated attrset therefore serialize their shared
    // snapshot once instead of once per body.
    for (unit.deferred_ids) |did| _ = try w.internScope(deferred.get(did).scope);
    for (w.scopes.items) |scope| try w.writeScopeRecord(scope);

    // Deferred records precede chunk records in the body: the loader
    // registers deferred entries FIRST so chunk-code `thunk_defer` operands
    // can remap to the fresh ids while chunks stream in.
    for (unit.deferred_ids) |did| {
        const entry = deferred.get(did);
        try w.writeDeferredRecord(entry);
    }
    for (w.chunk_order.items) |cid| {
        const ch = registry.get(cid) orelse return error.Uncacheable;
        const name = registry.nameOf(cid) orelse root_name_id;
        try w.writeChunkRecord(scratch, ch, name);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "FIXC");
    try encoding.writeU32(&out, allocator, format_version);
    // Payload checksum placeholder, patched below. Structural bounds checks
    // catch truncation, but not a torn write (rename landed, data didn't —
    // writes are not fsynced) or bit rot inside operand bytes, which would
    // otherwise deserialize into silently-wrong bytecode.
    try encoding.writeU32(&out, allocator, 0);
    try encoding.writeU32(&out, allocator, 0);
    try encoding.writeU32(&out, allocator, @intCast(w.chunk_order.items.len));
    try encoding.writeU32(&out, allocator, @intCast(unit.deferred_ids.len));
    try encoding.writeU32(&out, allocator, @intCast(w.scopes.items.len));
    try encoding.writeU32(&out, allocator, @intCast(w.str_order.items.len));
    try encoding.writeU32(&out, allocator, @intCast(w.name_nodes.items.len));
    try encoding.writeU32(&out, allocator, top_ordinal);

    for (w.str_order.items) |sid| {
        const s = intern.get(sid);
        try encoding.writeU32(&out, allocator, @intCast(s.len));
        try out.appendSlice(allocator, s);
    }
    for (w.name_nodes.items) |n| {
        try encoding.writeU32(&out, allocator, n.parent);
        try encoding.writeU32(&out, allocator, n.segment);
        try out.append(allocator, n.synthetic);
    }
    try out.appendSlice(allocator, w.body.items);

    const sum = std.hash.Wyhash.hash(checksum_seed, out.items[checksum_end..]);
    std.mem.writeInt(u64, out.items[checksum_start..][0..8], sum, .little);

    return out.toOwnedSlice(allocator);
}
