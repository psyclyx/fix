//! Bytecode emission helpers: low-level op/operand writers plus the
//! short/long and capture-carrying encodings for closures, thunks, and
//! attr-set/attr-path ops. Also the peephole super-op fusion (`*_ret`,
//! `get_*_attr`, store-to-slot) and jump patching.

const std = @import("std");
const compiler_mod = @import("context.zig");
const bytecode = @import("../bytecode.zig");
const chunk = bytecode.chunk;
const heap_mod = @import("runtime").heap;
const Value = @import("runtime").value.Value;
const types = @import("runtime").types;
const OpCode = bytecode.OpCode;
const operand = @import("operand.zig");
const diagnostics = @import("diagnostics.zig");

const Compiler = compiler_mod.Compiler;
const Capture = compiler_mod.Capture;
const InternId = types.InternId;
const captureCount = operand.captureCount;
const u16Count = operand.u16Count;

pub fn emitOp(self: *Compiler, op: OpCode) !void {
    try self.builder.writeOp(self.allocator, op);
}

pub fn emitOpU16(self: *Compiler, op: OpCode, val: u16) !void {
    try emitOp(self, op);
    try self.builder.writeU16(self.allocator, val);
}

pub fn emitOpU32(self: *Compiler, op: OpCode, val: u32) !void {
    try emitOp(self, op);
    try self.builder.writeU32(self.allocator, val);
}

/// Empty containers are evaluator-wide pinned singletons. Put their canonical
/// values directly in the chunk pool instead of executing a zero-count builder
/// opcode every time the expression runs.
pub fn emitEmptyAttrs(self: *Compiler) !void {
    try self.heap.ensureEmptySingletons();
    const id = try self.heap.addAttrs(&.{});
    try self.builder.emitConstant(self.allocator, Value.attrs(id));
}

pub fn emitEmptyList(self: *Compiler) !void {
    try self.heap.ensureEmptySingletons();
    const id = try self.heap.addList(&.{});
    try self.builder.emitConstant(self.allocator, Value.list(id));
}

/// Build-attrs emission for STATIC sorted+unique literals: the attr names go
/// to the chunk's side table (`attrs_new_named*`) and the stack carries only
/// the N values — no per-entry `push_const` of the name, no pool slot.
/// Positions (when present) ride the side table too.
pub fn emitBuildAttrsSorted(self: *Compiler, count: u16, names: []const types.InternId, positions: []const heap_mod.AttrPosEntry) !void {
    std.debug.assert(names.len == count);
    if (count == 0) return emitEmptyAttrs(self);
    const names_start: u32 = @intCast(self.builder.attr_names.items.len);
    try self.builder.attr_names.appendSlice(self.allocator, names);
    if (positions.len == 0) {
        try emitOpU16(self, .attrs_new_named_srt, count);
        try self.builder.writeU32(self.allocator, names_start);
        return;
    }
    // Positions bake pre-sorted by name (presorted call sites append them in
    // emit order, which IS name order); `findAttrPos` binary-searches.
    std.debug.assert(std.sort.isSorted(heap_mod.AttrPosEntry, positions, {}, posNameLessThan));
    const pos_start: u32 = @intCast(self.builder.attr_pos.items.len);
    try self.builder.attr_pos.appendSlice(self.allocator, positions);
    try emitOpU16(self, .attrs_new_named_pos_srt, count);
    try self.builder.writeU32(self.allocator, names_start);
    try self.builder.writeU16(self.allocator, try u16Count(positions.len));
    try self.builder.writeU32(self.allocator, pos_start);
}

/// Build one dynamic-key attrset from the `[name, value]` stack pair. With a
/// source file, the entry keeps the position at `offset` for `unsafeGetAttrPos`.
pub fn emitDynamicAttr(self: *Compiler, offset: u32) !void {
    _ = self.source_path orelse return emitOpU16(self, .attrs_new, 1);
    const position = try diagnostics.sourcePositionForOffset(self, offset);
    const pos_index: u32 = @intCast(self.builder.attr_pos.items.len);
    try self.builder.attr_pos.append(self.allocator, .{
        .name = try self.intern.intern(""),
        .pos = .{ .file = try diagnostics.sourceFileId(self), .line = position.line, .column = position.column },
    });
    try emitOp(self, .attrs_new_dyn_pos);
    try self.builder.writeU32(self.allocator, pos_index);
}

fn posNameLessThan(_: void, a: heap_mod.AttrPosEntry, b: heap_mod.AttrPosEntry) bool {
    return a.name < b.name;
}

pub fn emitOpByte(self: *Compiler, op: OpCode, val: u8) !void {
    try emitOp(self, op);
    try self.builder.writeByte(self.allocator, val);
}

pub fn emitLocalOp(self: *Compiler, short_op: OpCode, long_op: OpCode, slot: u16) !void {
    if (slot <= std.math.maxInt(u8)) {
        try emitOpByte(self, short_op, @intCast(slot));
    } else {
        try emitOpU16(self, long_op, slot);
    }
}

pub fn emitGetLocal(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .loc_get, .loc_get_w, slot);
}

pub fn emitCaptureLocal(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .loc_grab, .loc_grab_w, slot);
}

pub fn emitSetLocal(self: *Compiler, slot: u16) !void {
    if (try fuseStoreToSlot(self, slot, .narrow_local)) return;
    try emitLocalOp(self, .loc_set, .loc_set_w, slot);
}

pub fn emitSetCellLocal(self: *Compiler, slot: u16) !void {
    if (try fuseStoreToSlot(self, slot, .narrow_cell)) return;
    try emitLocalOp(self, .cell_set, .cell_set_w, slot);
}

const StoreTarget = enum { narrow_local, narrow_cell };

/// Rewrite a just-emitted `thunk`-family op into the fused `*_st`/`*_st_cell`
/// variant by appending the destination slot byte. Saves the push/pop of the
/// new thunk reference plus one dispatch.
///
/// Only fuses for 1-byte slots (`loc_set`/`cell_set`, not the `_w` forms);
/// ~all let-bindings fit. Both chunk-id widths fuse: past 65,536 registered
/// chunks (any real NixOS eval) the wide encoding is the DOMINANT form, not
/// the rare one.
fn fuseStoreToSlot(self: *Compiler, slot: u16, target: StoreTarget) !bool {
    if (slot > std.math.maxInt(u8)) return false;
    const offset = self.builder.last_op_offset orelse return false;
    const code = self.builder.code.items;
    if (offset >= code.len) return false;
    const last_op: OpCode = @fromBackingInt(@intCast(code[offset]));
    const fused: OpCode = switch (last_op) {
        .thunk => switch (target) {
            .narrow_local => .thunk_st,
            .narrow_cell => .thunk_st_cell,
        },
        .thunk_w => switch (target) {
            .narrow_local => .thunk_w_st,
            .narrow_cell => .thunk_w_st_cell,
        },
        else => return false,
    };
    code[offset] = @backingInt(fused);
    try self.builder.writeByte(self.allocator, @intCast(slot));
    self.builder.last_op_offset = null;
    // Unfused: extra `loc_set` op (1 byte) + slot byte. Fused: just
    // the slot byte appended. Net 1 byte saved.
    self.builder.fused_dispatch_weight += 1;
    return true;
}

pub fn emitInitCellSlot(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .cell_init, .cell_init_w, slot);
}

/// Emit the recursive-set `__overrides` application step (see the opcode
/// doc). `name_id` is the interned `__overrides` name. Always uses the
/// wide (4-byte) intern encoding — this op is rare, so the width choice
/// is not perf-sensitive and keeps the operand layout uniform.
pub fn emitApplyOverrides(self: *Compiler, name_id: InternId) !void {
    try emitOp(self, .attrs_apply_overrides);
    try self.builder.writeU32(self.allocator, name_id);
}

pub fn emitGetLocalRet(self: *Compiler, slot: u16) !void {
    try emitLocalOp(self, .loc_get_ret, .loc_get_ret_w, slot);
}

/// Emit a `ret`, fusing it into the immediately-preceding value-producing
/// op when the pattern matches a `<op>_ret` super-op. Safe because the
/// rewrite preserves the operand bytes — source-map entries pointing at
/// the original op's byte range still describe the same span.
pub fn emitRet(self: *Compiler) !void {
    if (self.builder.last_op_offset) |offset| {
        const code = self.builder.code.items;
        if (offset < code.len) {
            const last_op: OpCode = @fromBackingInt(@intCast(code[offset]));
            switch (last_op) {
                .push_const => {
                    code[offset] = @backingInt(OpCode.push_const_ret);
                    self.builder.last_op_offset = null;
                    return;
                },
                .up_get => {
                    code[offset] = @backingInt(OpCode.up_get_ret);
                    self.builder.last_op_offset = null;
                    return;
                },
                .loc_get => {
                    code[offset] = @backingInt(OpCode.loc_get_ret);
                    self.builder.last_op_offset = null;
                    return;
                },
                .loc_get_w => {
                    code[offset] = @backingInt(OpCode.loc_get_ret_w);
                    self.builder.last_op_offset = null;
                    return;
                },
                else => {},
            }
        }
    }
    try emitOp(self, .ret);
}

pub fn emitInternOp(self: *Compiler, short_op: OpCode, long_op: OpCode, id: InternId) !void {
    if (id <= std.math.maxInt(u16)) {
        try emitOpU16(self, short_op, @intCast(id));
    } else {
        try emitOp(self, long_op);
        try self.builder.writeU32(self.allocator, id);
    }
}

/// Emit `attr_get name`, fusing with an immediately-preceding source
/// op into a compound super-op (`up_get_attr`, `loc_get_attr`,
/// `loc_get_attr_w`). Only fuses when the attr name InternId
/// fits in u16; there's no long-name form yet.
pub fn emitGetAttr(self: *Compiler, id: InternId) !void {
    if (id <= std.math.maxInt(u16)) {
        if (self.builder.last_op_offset) |offset| {
            const code = self.builder.code.items;
            if (offset < code.len) {
                const last_op: OpCode = @fromBackingInt(@intCast(code[offset]));
                const fused: ?OpCode = switch (last_op) {
                    .up_get => .up_get_attr,
                    .loc_get => .loc_get_attr,
                    .loc_get_w => .loc_get_attr_w,
                    else => null,
                };
                if (fused) |op| {
                    code[offset] = @backingInt(op);
                    try self.builder.writeU16(self.allocator, @intCast(id));
                    self.builder.last_op_offset = null;
                    // The unfused encoding would have been 3 bytes
                    // (attr_get op + 2-byte name); we wrote 2 bytes.
                    self.builder.fused_dispatch_weight += 1;
                    return;
                }
            }
        }
    }
    try emitInternOp(self, .attr_get, .attr_get_w, id);
}

/// Emit `arg_or_lit <name_id>`: bind an attrset-pattern formal with a trivial
/// literal default without a thunk. Only the narrow (u16) name form exists; the
/// caller must guarantee `id` fits in a u16.
pub fn emitArgOrLit(self: *Compiler, id: InternId) !void {
    try emitOp(self, .arg_or_lit);
    try self.builder.writeU16(self.allocator, @intCast(id));
}

pub fn writeInternId(self: *Compiler, id: InternId, wide: bool) !void {
    try bytecode.writeInternId(&self.builder.code, self.allocator, id, wide);
}

pub fn emitClosure(self: *Compiler, chunk_id: types.ChunkId, upvalue_count: u16) !void {
    if (chunk_id <= std.math.maxInt(u16)) {
        try emitOpU16(self, .closure, @intCast(chunk_id));
    } else {
        try emitOp(self, .closure_w);
        try self.builder.writeU32(self.allocator, chunk_id);
    }
    try self.builder.writeU16(self.allocator, upvalue_count);
}

/// Emit one capture-carrying op — the compile-time twin of `run.zig`'s `capOp`.
/// Picks the narrow (`narrow`, 2-byte chunk id) or wide (`wide`, 4-byte) opcode
/// by chunk-id width, then writes `count` + inline `(kind,index)` descriptors.
/// The `_st`/`_st_cell` store variants aren't emitted here — `fuseStoreToSlot`
/// rewrites the just-emitted op byte in place.
fn emitCaptureOp(self: *Compiler, narrow: OpCode, wide: OpCode, chunk_id: types.ChunkId, captures: []const Capture) !void {
    const upvalue_count = try captureCount(captures.len);
    if (chunk_id <= std.math.maxInt(u16)) {
        try emitOpU16(self, narrow, @intCast(chunk_id));
    } else {
        try emitOp(self, wide);
        try self.builder.writeU32(self.allocator, chunk_id);
    }
    try self.builder.writeU16(self.allocator, upvalue_count);
    try emitCaptureDescriptors(self, captures);
}

pub fn emitClosureWithCaptures(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
    if (captures.len == 0) return emitClosure(self, chunk_id, 0);
    return emitCaptureOp(self, .closure_cap, .closure_cap_w, chunk_id, captures);
}

pub fn emitThunkWithCaptures(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
    return emitCaptureOp(self, .thunk, .thunk_w, chunk_id, captures);
}

/// Emit `thunk_arg` — a function argument whose laziness is decided at
/// runtime from the callee's strictness. Always a 4-byte chunk id (the 2 extra
/// operand bytes are negligible vs. a second opcode), so it can't share the
/// narrow/wide `emitCaptureOp` — the handler (`capOp(.arg,.wide)`) reads a u32.
pub fn emitApplyArg(self: *Compiler, chunk_id: types.ChunkId, captures: []const Capture) !void {
    const upvalue_count = try captureCount(captures.len);
    try emitOp(self, .thunk_arg);
    try self.builder.writeU32(self.allocator, chunk_id);
    try self.builder.writeU16(self.allocator, upvalue_count);
    try emitCaptureDescriptors(self, captures);
}

/// Emit `thunk_defer` (lazy per-attr compilation): a deferred-table id plus a
/// `(start, count)` reference into the chunk's deduped capture-list side table.
/// Repeated scope snapshots share one interned descriptor list.
pub fn emitDeferAttrValue(self: *Compiler, deferred_id: u32, scope: []const Capture) !void {
    const env_count = try captureCount(scope.len);
    const cap_start = try internCaptureList(self, scope);
    try emitOp(self, .thunk_defer);
    try self.builder.writeU32(self.allocator, deferred_id);
    try self.builder.writeU32(self.allocator, cap_start);
    try self.builder.writeU16(self.allocator, env_count);
    self.builder.capture_dispatch_weight += @as(usize, scope.len) * 3;
}

/// Encode `captures` as `(kind:1, index:2-LE)*` and intern the list into the
/// builder's capture side table, returning its start offset.
fn internCaptureList(self: *Compiler, captures: []const Capture) !u32 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(self.allocator);
    for (captures) |capture| {
        try buf.append(self.allocator, switch (capture.kind) {
            .local => 0,
            .upvalue => 1,
        });
        try buf.append(self.allocator, @intCast(capture.index & 0xff));
        try buf.append(self.allocator, @intCast(capture.index >> 8));
    }
    return self.builder.internCaptureList(self.allocator, buf.items);
}

pub fn emitCaptureDescriptors(self: *Compiler, captures: []const Capture) !void {
    for (captures) |capture| {
        try self.builder.writeByte(self.allocator, switch (capture.kind) {
            .local => 0,
            .upvalue => 1,
        });
        try self.builder.writeU16(self.allocator, capture.index);
    }
}

/// Emit `thunk_attr`: a frameless attr-access thunk over the value of one
/// capture descriptor — the elided form of an `up_get_attr; ret; halt`
/// wrapper chunk.
pub fn emitThunkAttr(self: *Compiler, base: Capture, name: InternId) !void {
    const wide = name > std.math.maxInt(u16);
    try emitOp(self, if (wide) .thunk_attr_w else .thunk_attr);
    try emitCaptureDescriptors(self, &.{base});
    try writeInternId(self, name, wide);
}

pub fn patchJump(self: *Compiler, instruction_offset: usize, target_offset: usize) void {
    const operand_offset = instruction_offset + 1;
    const next_instruction = instruction_offset + 5;
    const relative: u32 = @intCast(target_offset - next_instruction);
    self.builder.code.items[operand_offset] = @truncate(relative);
    self.builder.code.items[operand_offset + 1] = @truncate(relative >> 8);
    self.builder.code.items[operand_offset + 2] = @truncate(relative >> 16);
    self.builder.code.items[operand_offset + 3] = @truncate(relative >> 24);
    // Patching a jump means some branch now lands at `target_offset`.
    // If that target equals the current write position (`code.len`),
    // the next opcode we emit becomes a multi-predecessor join. Return fusion
    // must account for every predecessor, not only `last_op_offset`'s path.
    // Conservative: drop the hint whenever the target
    // is the tail. (Patches that land BEFORE the tail can't affect
    // straight-line fusion of subsequent ops.)
    if (target_offset == self.builder.code.items.len) {
        self.builder.last_op_offset = null;
    }
}
