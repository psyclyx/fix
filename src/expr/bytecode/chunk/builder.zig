//! Mutable construction and finish-time classification for bytecode chunks.

const std = @import("std");
const types = @import("runtime").types;
const encoding = @import("../encoding.zig");
const OpCode = @import("../opcode.zig").OpCode;
const Value = @import("runtime").value.Value;
const AttrEntry = @import("runtime").heap.AttrEntry;
const AttrPosEntry = @import("runtime").heap.AttrPosEntry;
const model = @import("model.zig");
const Chunk = model.Chunk;
const ChunkStrictness = model.ChunkStrictness;
const LambdaPattern = model.LambdaPattern;
const TrivialBody = model.TrivialBody;
const ConstIdx = types.ConstIdx;

/// A mutable builder for constructing chunks.
pub const ChunkBuilder = struct {
    /// A distinct capture list's range in `capture_bytes` (for dedup scanning).
    pub const CaptureRange = struct { start: u32, len: u32 };

    code: std.ArrayListUnmanaged(u8),
    constants: std.ArrayListUnmanaged(Value),
    /// Exact-bit interning for constant operands. Value identity is sufficient
    /// here: equal scalar encodings and references are interchangeable in an
    /// immutable pool, while distinct float encodings (notably +/-0) remain
    /// distinct. This also makes canonical NaN constants shareable.
    constant_index: std.AutoHashMapUnmanaged(u64, ConstIdx) = .empty,
    function_args: std.ArrayListUnmanaged(AttrEntry),
    function_arg_pos: std.ArrayListUnmanaged(AttrPosEntry) = .empty,
    source_map: std.ArrayListUnmanaged(Chunk.SourceMapEntry),
    /// Attr-position records collected by `emitBuildAttrsSorted` — carried
    /// onto `Chunk.attr_pos` at finish (see that field's doc).
    attr_pos: std.ArrayListUnmanaged(AttrPosEntry) = .empty,
    /// Attr names for `attrs_new_named*` — carried onto `Chunk.attr_names`.
    attr_names: std.ArrayListUnmanaged(types.InternId) = .empty,
    /// Deduped capture-descriptor bytes for `thunk_defer` — carried onto
    /// `Chunk.capture_bytes`. `capture_index` records each distinct list's
    /// range so `internCaptureList` can coalesce identical lists (an attrset's
    /// shared scope snapshot) by a linear scan — a chunk has only a handful of
    /// distinct lists per chunk, so no map is needed.
    capture_bytes: std.ArrayListUnmanaged(u8) = .empty,
    capture_index: std.ArrayListUnmanaged(CaptureRange) = .empty,
    /// Dispatch-equivalent weight of capture descriptors before side-table
    /// deduplication, used only for scheduling classification.
    capture_dispatch_weight: usize = 0,
    /// The body node's span (see `Chunk.body_span`). Set by `stampOnBuilder`.
    body_span: ?Chunk.SourceSpan = null,
    /// Byte offset of the start of the most recently written opcode.
    /// `null` when no op has been written or when the tail is no
    /// longer a single rewritable opcode (e.g. after a branch fixup
    /// patches an offset in place). Used by `emit.emitRet` to fuse
    /// the previous value-producing op into a `<op>_ret` super-op.
    last_op_offset: ?usize = null,
    /// Dispatch-equivalent bytes represented by fused super-operations, used
    /// only for scheduling classification.
    fused_dispatch_weight: u32 = 0,
    /// Strictness signature computed by `compiler/strictness.zig`
    /// after the body is compiled. Carried through `finish` onto the
    /// resulting Chunk via `SchedulingHints`.
    strictness: ChunkStrictness = .{},
    /// Single-param lambda whose body must-forces its parameter. Set by
    /// `compileLambda`; carried onto `SchedulingHints.strict_param`.
    strict_param: bool = false,
    /// See `SchedulingHints.strict_via_upvalue`. Set by `compileLambda`.
    strict_via_upvalue: ?u16 = null,
    /// Number of params the chunk consumes before the body runs — carried
    /// onto `Chunk.arity`. Set by `compileLambda` when it merges an
    /// adjacent value-lambda chain into one uncurried chunk; otherwise 1.
    arity: u16 = 1,
    /// Per-param must-force bitmask for an uncurried chunk — carried onto
    /// `Chunk.strict_params`. Set by `compileLambda`.
    strict_params: u8 = 0,
    /// Formal-parameter pattern for `--xml` rendering — carried onto
    /// `Chunk.lambda_pattern`. Set by `compileLambda`/`compileLambdaAttrs`.
    lambda_pattern: LambdaPattern = .none,

    pub fn init(allocator: std.mem.Allocator) !ChunkBuilder {
        var code = try std.ArrayListUnmanaged(u8).initCapacity(allocator, types.chunk_code_capacity);
        errdefer code.deinit(allocator);

        var constants = try std.ArrayListUnmanaged(Value).initCapacity(allocator, types.chunk_constants_capacity);
        errdefer constants.deinit(allocator);

        return .{
            .code = code,
            .constants = constants,
            .function_args = .empty,
            .source_map = .empty,
        };
    }

    pub fn deinit(self: *ChunkBuilder, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.constants.deinit(allocator);
        self.constant_index.deinit(allocator);
        self.function_args.deinit(allocator);
        self.function_arg_pos.deinit(allocator);
        self.source_map.deinit(allocator);
        self.attr_pos.deinit(allocator);
        self.attr_names.deinit(allocator);
        self.capture_bytes.deinit(allocator);
        self.capture_index.deinit(allocator);
    }

    /// Restore the freshly-initialized state, keeping buffer capacity —
    /// for the compiler's child-builder pool (`Compiler.acquireBuilder`).
    pub fn reset(self: *ChunkBuilder) void {
        self.code.clearRetainingCapacity();
        self.constants.clearRetainingCapacity();
        self.constant_index.clearRetainingCapacity();
        self.function_args.clearRetainingCapacity();
        self.function_arg_pos.clearRetainingCapacity();
        self.attr_pos.clearRetainingCapacity();
        self.attr_names.clearRetainingCapacity();
        self.capture_bytes.clearRetainingCapacity();
        self.capture_index.clearRetainingCapacity();
        self.capture_dispatch_weight = 0;
        self.source_map.clearRetainingCapacity();
        self.body_span = null;
        self.last_op_offset = null;
        self.fused_dispatch_weight = 0;
        self.strictness = .{};
        self.strict_param = false;
        self.strict_via_upvalue = null;
        self.arity = 1;
        self.strict_params = 0;
        self.lambda_pattern = .none;
    }

    /// Intern a capture-descriptor list (`descriptors` = `(kind:1, index:2)*`),
    /// returning its start offset in `capture_bytes`. Identical lists coalesce
    /// (an attrset's deferred values share one scope snapshot). A rare hash
    /// collision with different content just appends a non-shared copy.
    pub fn internCaptureList(self: *ChunkBuilder, allocator: std.mem.Allocator, descriptors: []const u8) !u32 {
        for (self.capture_index.items) |r| {
            if (r.len == descriptors.len and
                std.mem.eql(u8, self.capture_bytes.items[r.start .. r.start + r.len], descriptors))
                return r.start;
        }
        const start: u32 = @intCast(self.capture_bytes.items.len);
        try self.capture_bytes.appendSlice(allocator, descriptors);
        try self.capture_index.append(allocator, .{ .start = start, .len = @intCast(descriptors.len) });
        return start;
    }

    /// Write a single opcode byte.
    pub fn writeOp(self: *ChunkBuilder, allocator: std.mem.Allocator, op: OpCode) !void {
        self.last_op_offset = self.code.items.len;
        try self.code.append(allocator, @backingInt(op));
    }

    /// Write a single byte operand.
    pub fn writeByte(self: *ChunkBuilder, allocator: std.mem.Allocator, byte: u8) !void {
        try self.code.append(allocator, byte);
    }

    /// Write a two-byte operand (little-endian).
    pub fn writeU16(self: *ChunkBuilder, allocator: std.mem.Allocator, val: u16) !void {
        try encoding.writeU16(&self.code, allocator, val);
    }

    /// Write a four-byte operand (little-endian).
    pub fn writeU32(self: *ChunkBuilder, allocator: std.mem.Allocator, val: u32) !void {
        try encoding.writeU32(&self.code, allocator, val);
    }

    /// Intern a constant in the pool and return its index.
    pub fn addConstant(self: *ChunkBuilder, allocator: std.mem.Allocator, val: Value) !ConstIdx {
        if (self.constant_index.get(val.bits)) |idx| return idx;
        if (self.constants.items.len > std.math.maxInt(ConstIdx)) return error.TooManyConstants;
        try self.constants.ensureUnusedCapacity(allocator, 1);
        try self.constant_index.ensureUnusedCapacity(allocator, 1);
        const idx: ConstIdx = @intCast(self.constants.items.len);
        self.constants.appendAssumeCapacity(val);
        self.constant_index.putAssumeCapacityNoClobber(val.bits, idx);
        return idx;
    }

    /// Emit a constant-loading instruction (op + 2-byte index).
    pub fn emitConstant(self: *ChunkBuilder, allocator: std.mem.Allocator, val: Value) !void {
        const idx = try self.addConstant(allocator, val);
        try self.writeOp(allocator, .push_const);
        try self.writeU16(allocator, idx);
    }

    pub fn setFunctionArgs(self: *ChunkBuilder, allocator: std.mem.Allocator, args: []const AttrEntry) !void {
        self.function_args.clearRetainingCapacity();
        try self.function_args.appendSlice(allocator, args);
    }

    pub fn setFunctionArgPositions(self: *ChunkBuilder, allocator: std.mem.Allocator, positions: []const AttrPosEntry) !void {
        self.function_arg_pos.clearRetainingCapacity();
        try self.function_arg_pos.appendSlice(allocator, positions);
    }

    pub fn addSourceMapEntry(self: *ChunkBuilder, allocator: std.mem.Allocator, start: usize, end: usize, span: Chunk.SourceSpan) !void {
        if (start >= end) return;
        try self.source_map.append(allocator, .{
            .start = @intCast(start),
            .end = @intCast(end),
            .span = span,
        });
    }

    /// Scheduling weight for metadata whose cost is independent of its compact
    /// side-table encoding. New side tables that replace dispatched work must
    /// contribute here.
    fn schedulingSideTableWeight(self: *const ChunkBuilder) usize {
        return self.attr_pos.items.len * 16 + self.attr_names.items.len * 3 + self.capture_dispatch_weight;
    }

    /// Finalize into an immutable Chunk.
    pub fn finish(self: *ChunkBuilder, allocator: std.mem.Allocator, local_count: u16) !Chunk {
        const code = try allocator.dupe(u8, self.code.items);
        errdefer allocator.free(code);
        const constants = try allocator.dupe(Value, self.constants.items);
        errdefer allocator.free(constants);
        const function_args = try allocator.dupe(AttrEntry, self.function_args.items);
        errdefer allocator.free(function_args);
        const function_arg_pos = try allocator.dupe(AttrPosEntry, self.function_arg_pos.items);
        errdefer allocator.free(function_arg_pos);
        const attr_pos = try allocator.dupe(AttrPosEntry, self.attr_pos.items);
        errdefer allocator.free(attr_pos);
        const attr_names = try allocator.dupe(types.InternId, self.attr_names.items);
        errdefer allocator.free(attr_names);
        const capture_bytes = try allocator.dupe(u8, self.capture_bytes.items);
        errdefer allocator.free(capture_bytes);
        const source_map = try allocator.dupe(Chunk.SourceMapEntry, self.source_map.items);
        const scheduling_weight = self.code.items.len + self.fused_dispatch_weight + self.schedulingSideTableWeight();
        return Chunk{
            .code = code,
            .constants = constants,
            .capture_bytes = capture_bytes,
            .local_count = local_count,
            .arity = self.arity,
            .strict_params = self.strict_params,
            .scheduling = .{
                .body_is_substantial = scheduling_weight >= speculation_min_code_bytes,
                .spec_band_small = scheduling_weight < speculation_trusted_code_bytes,
                .strictness = self.strictness,
                .trivial = classifyTrivialBody(self.code.items, self.constants.items, local_count),
                .strict_param = self.strict_param and local_count == 1,
                .strict_via_upvalue = if (local_count == 1) self.strict_via_upvalue else null,
            },
            .function_args = function_args,
            .function_arg_pos = function_arg_pos,
            .attr_pos = attr_pos,
            .attr_names = attr_names,
            .source_map = source_map,
            .body_span = self.body_span,
            .lambda_pattern = self.lambda_pattern,
        };
    }
};

/// Classify the body of a freshly-built chunk as one of the trivial
/// shapes that let `thunk` skip thunk allocation entirely.
/// Run once at chunk-finish; result lives on the immutable Chunk so
/// the hot path reads it without re-parsing the bytecode.
pub fn classifyTrivialBody(code: []const u8, constants: []const Value, local_count: u16) TrivialBody {
    // Trivial-body short-circuit is only safe for chunks used as
    // *thunk bodies*. Thunk bodies have local_count == 0 (no args,
    // no temporaries). Closure bodies (lambdas) have local_count >= 1
    // for the param and may have additional locals. We must not
    // short-circuit those because `thunk` against a chunk
    // assumes the chunk is a thunk body, not a lambda body.
    if (local_count != 0) return .none;
    if (code.len < 2) return .none;
    const first: OpCode = @fromBackingInt(@intCast(code[0]));
    switch (first) {
        // `up_get_ret upvalue[N]; halt`
        // Layout: 1 byte op, 2 bytes upvalue idx, 1 byte halt.
        .up_get_ret => {
            if (code.len != 4) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[3]))) != .halt) return .none;
            const idx = readU16Inline(code, 1);
            return .{ .identity_upvalue = idx };
        },
        // `push_const_ret #idx; halt` — 1 byte op, 2 bytes idx, 1 byte halt.
        .push_const_ret => {
            if (code.len != 4) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[3]))) != .halt) return .none;
            const idx = readU16Inline(code, 1);
            if (idx >= constants.len) return .none;
            return .{ .literal = constants[idx] };
        },
        // `up_get_attr U N; ret; halt` — 1 + 2 + 2 + 1 + 1 = 7 bytes.
        .up_get_attr => {
            if (code.len != 7) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[5]))) != .ret) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[6]))) != .halt) return .none;
            return .{ .attr_access = .{
                .upvalue_index = readU16Inline(code, 1),
                .name = readU16Inline(code, 3),
            } };
        },
        // `push_builtins; ret; halt` — 1 + 1 + 1 = 3 bytes.
        .push_builtins => {
            if (code.len != 3) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[1]))) != .ret) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[2]))) != .halt) return .none;
            return .builtins;
        },
        // `push_null|push_true|push_false; ret; halt` — 3 bytes.
        // The compiler doesn't fuse these into a `_ret` super-op
        // (only `push_const`/`up_get`/`loc_get`/`loc_get_w`
        // are fused), so without the short-circuit each binding to
        // `null`/`true`/`false` allocates a thunk whose body trivially
        // returns the literal.
        .push_null, .push_true, .push_false => {
            if (code.len != 3) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[1]))) != .ret) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[2]))) != .halt) return .none;
            const literal: Value = switch (first) {
                .push_null => Value.null_val,
                .push_true => Value.boolVal(true),
                .push_false => Value.boolVal(false),
                else => unreachable,
            };
            return .{ .literal = literal };
        },
        // `closure CL, 0; ret; halt` — 1 op + 2 chunk_id + 2 upvalue_count + 1 ret + 1 halt = 7 bytes.
        .closure => {
            if (code.len != 7) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[5]))) != .ret) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[6]))) != .halt) return .none;
            const upvalue_count = readU16Inline(code, 3);
            if (upvalue_count != 0) return .none; // non-zero closure needs stack values
            return .{ .closure_zero = readU16Inline(code, 1) };
        },
        // `closure_w CL(4), 0; ret; halt` — 1 + 4 + 2 + 1 + 1 = 9 bytes.
        .closure_w => {
            if (code.len != 9) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[7]))) != .ret) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[8]))) != .halt) return .none;
            const upvalue_count = readU16Inline(code, 5);
            if (upvalue_count != 0) return .none;
            return .{ .closure_zero = readU32Inline(code, 1) };
        },
        // `closure_cap CL, K, descriptors(3K); ret; halt`
        // 1 op + 2 chunk_id + 2 K + 3K descriptors + 1 ret + 1 halt = 7 + 3K.
        .closure_cap => {
            if (code.len < 7) return .none;
            const k = readU16Inline(code, 3);
            if (k == 0) return .none; // shouldn't happen — emit drops to .closure when K==0
            const desc_len: usize = @as(usize, k) * 3;
            if (code.len != 7 + desc_len) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[5 + desc_len]))) != .ret) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[6 + desc_len]))) != .halt) return .none;
            // Inner descriptors must all be kind=upvalue (1) since the
            // thunk body has no locals. If the compiler ever emits
            // kind=local here it would read garbage, so refusing the
            // short-circuit is the safe fallback.
            var i: usize = 0;
            while (i < desc_len) : (i += 3) {
                if (code[5 + i] != 1) return .none;
            }
            return .{ .closure_captures = .{
                .closure_chunk_id = readU16Inline(code, 1),
                .inner_descriptors_offset = 5,
                .inner_descriptors_len = @intCast(desc_len),
            } };
        },
        // `closure_cap_w CL(4), K, descriptors(3K); ret; halt`
        // 1 + 4 + 2 + 3K + 1 + 1 = 9 + 3K.
        .closure_cap_w => {
            if (code.len < 9) return .none;
            const k = readU16Inline(code, 5);
            if (k == 0) return .none;
            const desc_len: usize = @as(usize, k) * 3;
            if (code.len != 9 + desc_len) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[7 + desc_len]))) != .ret) return .none;
            if (@as(OpCode, @fromBackingInt(@intCast(code[8 + desc_len]))) != .halt) return .none;
            var i: usize = 0;
            while (i < desc_len) : (i += 3) {
                if (code[7 + i] != 1) return .none;
            }
            return .{ .closure_captures = .{
                .closure_chunk_id = readU32Inline(code, 1),
                .inner_descriptors_offset = 7,
                .inner_descriptors_len = @intCast(desc_len),
            } };
        },
        else => return .none,
    }
}

pub inline fn readU16Inline(buf: []const u8, off: usize) u16 {
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}

pub inline fn readU32Inline(buf: []const u8, off: usize) u32 {
    return @as(u32, buf[off]) |
        (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) |
        (@as(u32, buf[off + 3]) << 24);
}

/// Code length at or above which a chunk is considered substantial
/// enough that submitting its body to a helper at thunk-creation time
/// pays the scheduler hop. Used by `SchedulingHints.body_is_substantial`.
pub const speculation_min_code_bytes: usize = 256;

/// Effective size at or above which a chunk's speculative execution is
/// trusted to run WITHOUT a creation budget. Deliberately a separate
/// constant from the admission gate above: the admission gate says "worth
/// a scheduler hop", this one says "safe to run unattended" — see
/// `SchedulingHints.spec_band_small`. Keep at the 2026-07 sweep's
/// validated junk cliff (256) even if the admission gate moves.
pub const speculation_trusted_code_bytes: usize = 256;
