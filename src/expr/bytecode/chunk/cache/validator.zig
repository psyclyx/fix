const std = @import("std");
const types = @import("runtime").types;

const opcode_mod = @import("../../opcode.zig");
const encoding = @import("../../encoding.zig");
const common = @import("wire.zig");

const Error = common.Error;
const Reader = common.Reader;
const corruptAt = common.corruptAt;
const readW = common.readWidth;
const format_version = common.format_version;
const checksum_end = common.checksum_end;
const checksum_seed = common.checksum_seed;

fn validateIndex(index: u32, count: u32) Error!void {
    if (index >= count) return corruptAt(@src());
}

fn validateSpanRecord(r: *Reader, str_count: u32) Error!void {
    const has_file = try r.u8_();
    if (has_file > 1) return corruptAt(@src());
    if (has_file == 1) try validateIndex(try r.u32_(), str_count);
    _ = try r.u32_();
    _ = try r.u32_();
    _ = try r.u32_();
    _ = try r.u32_();
}

fn validateOptSpanRecord(r: *Reader, str_count: u32) Error!void {
    const present = try r.u8_();
    if (present > 1) return corruptAt(@src());
    if (present == 1) try validateSpanRecord(r, str_count);
}

const max_constant_depth = 1024;

fn validateConstantRecord(r: *Reader, str_count: u32, depth: usize) Error!void {
    if (depth >= max_constant_depth) return corruptAt(@src());
    switch (try r.u8_()) {
        0, 1, 2 => {},
        3, 4 => _ = try r.u64_(),
        5, 6 => try validateIndex(try r.u32_(), str_count),
        7 => {
            const count = try r.u32_();
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                try validateIndex(try r.u32_(), str_count);
                try validateConstantRecord(r, str_count, depth + 1);
            }
            const position_count = try r.u32_();
            if (position_count > count) return corruptAt(@src());
            i = 0;
            while (i < position_count) : (i += 1) try validateAttrPosRecord(r, str_count);
        },
        8 => {
            const count = try r.u32_();
            var i: u32 = 0;
            while (i < count) : (i += 1) try validateConstantRecord(r, str_count, depth + 1);
        },
        9 => _ = try r.u16_(),
        else => return corruptAt(@src()),
    }
}

fn validateAttrPosRecord(r: *Reader, str_count: u32) Error!void {
    try validateIndex(try r.u32_(), str_count);
    try validateIndex(try r.u32_(), str_count);
    _ = try r.u32_();
    _ = try r.u32_();
}

fn boundedRange(start: u32, count: u32, limit: usize) Error!void {
    const end = std.math.add(u32, start, count) catch return corruptAt(@src());
    if (@as(usize, end) > limit) return corruptAt(@src());
}

/// Validate one loaded chunk's code and prove every id it will be rewritten
/// to still fits its operand width. Read-only: the caller runs this over
/// every chunk of the unit before it mutates any of them.
///
/// These were two walks. `validateUnit` checked the wire form of the code,
/// and the decoder's preflight then re-walked the same instructions to check
/// widths. Both are per-field and read-only, so they share one pass. Each arm
/// validates the index before the width check consumes it, which is what lets
/// `chunk_ids` and `strtab` be indexed here without a second bounds test.
///
/// `chunk_ordinal` keeps a chunk from naming a later one: a unit registers
/// children before parents, so a `.chunk_id` may only point at an earlier
/// ordinal.
pub fn validateAndPreflightCode(
    code: []const u8,
    chunk_ordinal: u32,
    deferred_count: u32,
    str_count: u32,
    const_count: u32,
    attr_names_count: u32,
    attr_pos_count: u32,
    capture_bytes_len: u32,
    chunk_ids: []const types.ChunkId,
    strtab: []const types.InternId,
) Error!void {
    var cursor: opcode_mod.InstructionCursor = .{ .code = code };
    while (cursor.next() catch return corruptAt(@src())) |insn| {
        var off = insn.ip + 1;
        for (opcode_mod.layout(insn.op)) |field| {
            const len = opcode_mod.checkedFieldLen(field, code, off) catch return corruptAt(@src());
            switch (field) {
                .deferred_id => |w| try validateIndex(readW(code, off, w), deferred_count),
                .chunk_id => |w| {
                    const ordinal = readW(code, off, w);
                    try validateIndex(ordinal, chunk_ordinal);
                    if (w == .b2 and chunk_ids[ordinal] > 0xFFFF) return error.Unfit;
                },
                .intern => |w| {
                    const idx = readW(code, off, w);
                    try validateIndex(idx, str_count);
                    if (w == .b2 and strtab[idx] > 0xFFFF) return error.Unfit;
                },
                .const_idx => try validateIndex(encoding.readU16(code, off), const_count),
                .attr_path => |w| {
                    const count = code[off];
                    var p = off + 1;
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const idx = readW(code, p, w);
                        try validateIndex(idx, str_count);
                        if (w == .b2 and strtab[idx] > 0xFFFF) return error.Unfit;
                        p += w.bytes();
                    }
                },
                .bind => |w| {
                    const count = encoding.readU16(code, off + 2);
                    var p = off + 4;
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const idx = readW(code, p, w);
                        try validateIndex(idx, str_count);
                        if (w == .b2 and strtab[idx] > 0xFFFF) return error.Unfit;
                        p += w.bytes() + 2;
                    }
                },
                .mix => {
                    const count = code[off];
                    var p = off + 2;
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const tag = code[p];
                        p += 1;
                        if (tag == 0) {
                            try validateIndex(encoding.readU32(code, p), str_count);
                            p += 4;
                        }
                    }
                },
                .skip, .slot, .cap1, .count, .jump, .captures, .captures_slot => {},
            }
            off += len;
        }
        std.debug.assert(off == insn.end);

        switch (insn.op) {
            .attrs_new_named_srt, .attrs_new_named => {
                try boundedRange(encoding.readU32(code, insn.ip + 3), encoding.readU16(code, insn.ip + 1), attr_names_count);
            },
            .attrs_new_named_pos_srt, .attrs_new_named_pos => {
                try boundedRange(encoding.readU32(code, insn.ip + 3), encoding.readU16(code, insn.ip + 1), attr_names_count);
                try boundedRange(encoding.readU32(code, insn.ip + 9), encoding.readU16(code, insn.ip + 7), attr_pos_count);
            },
            .thunk_defer => {
                const capture_count: u32 = encoding.readU16(code, insn.ip + 9);
                const capture_start = encoding.readU32(code, insn.ip + 5);
                const bytes = std.math.mul(u32, capture_count, 3) catch return corruptAt(@src());
                try boundedRange(capture_start, bytes, capture_bytes_len);
            },
            else => {},
        }
    }
}

/// Wire preflight for everything a decode reads: header, checksum, string and
/// name tables, scopes, deferred entries, and each chunk's records. The code
/// bytes are checked separately by `validateAndPreflightCode`, which the
/// decoder runs once per chunk after decode.
///
/// What the split still guarantees: malformed code bytes are never
/// interpreted. Decoding a chunk only copies them, and nothing runs until the
/// code check has passed.
///
/// What it no longer guarantees: keeping a corrupt blob out of the load's
/// append-only tables. `validateAndPreflightCode` runs in `CommitContext
/// .prepare`, by which point `load` has already interned strings, built name
/// tree nodes, adopted deferred scopes, and decoded heap constants. Those are
/// inert leftovers from a corrupt local cache file rather than a safety
/// problem — chunk allocations unwind via errdefer and the named batch rolls
/// its reservation back — but a blob rejected here is not a blob that touched
/// nothing.
pub fn validateUnit(allocator: std.mem.Allocator, bytes: []const u8, source_len: usize) Error!void {
    var r: Reader = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try r.bytesN(4), "FIXC")) return corruptAt(@src());
    if (try r.u32_() != format_version) return error.Stale;
    const sum = try r.u64_();
    if (sum != std.hash.Wyhash.hash(checksum_seed, bytes[checksum_end..])) return corruptAt(@src());
    const chunk_count = try r.u32_();
    const deferred_count = try r.u32_();
    const scope_count = try r.u32_();
    const str_count = try r.u32_();
    const name_count = try r.u32_();
    const top = try r.u32_();
    if (chunk_count == 0 or top >= chunk_count) return corruptAt(@src());

    var i: u32 = 0;
    while (i < str_count) : (i += 1) _ = try r.bytesN(try r.u32_());
    i = 0;
    while (i < name_count) : (i += 1) {
        const parent = try r.u32_();
        if (parent != 0 and parent - 1 >= i) return corruptAt(@src());
        try validateIndex(try r.u32_(), str_count);
        if (try r.u8_() > 1) return corruptAt(@src());
    }

    const lengths = allocator.alloc(u16, scope_count) catch return error.OutOfMemory;
    defer allocator.free(lengths);
    for (lengths) |*length| {
        length.* = try r.u16_();
        var c: u16 = 0;
        while (c < length.*) : (c += 1) {
            if (try r.u8_() > 1) return corruptAt(@src());
            _ = try r.u16_();
            try validateIndex(try r.u32_(), str_count);
        }
    }
    i = 0;
    while (i < deferred_count) : (i += 1) {
        const offset = try r.u32_();
        const len = try r.u32_();
        const end = std.math.add(u32, offset, len) catch return corruptAt(@src());
        if (@as(usize, end) > source_len) return corruptAt(@src());
        const name = try r.u32_();
        if (name != 0) try validateIndex(name - 1, name_count);
        const with_count = try r.u16_();
        const scope_ordinal = try r.u32_();
        try validateIndex(scope_ordinal, scope_count);
        if (with_count > lengths[scope_ordinal]) return corruptAt(@src());
    }

    i = 0;
    while (i < chunk_count) : (i += 1) {
        const name = try r.u32_();
        if (name != 0) try validateIndex(name - 1, name_count);
        const local_count = try r.u16_(); // arity-1 thunks legitimately have zero locals
        const arity = try r.u16_();
        const strict_params = try r.u8_();
        if (arity == 0 or arity > types.max_uncurry_arity) return corruptAt(@src());
        if (arity > 1 and local_count < arity) return corruptAt(@src());
        if (arity == 1 and strict_params != 0) return corruptAt(@src());
        if (arity > 1) {
            const allowed: u8 = if (arity >= 8) std.math.maxInt(u8) else (@as(u8, 1) << @intCast(arity)) - 1;
            if (strict_params & ~allowed != 0) return corruptAt(@src());
        }
        _ = try r.u64_();
        _ = try r.u64_();
        if (try r.u8_() > 1 or try r.u8_() > 1 or try r.u8_() > 1) return corruptAt(@src());
        const svu = try r.u8_();
        if (svu > 1) return corruptAt(@src());
        _ = try r.u16_();
        switch (try r.u8_()) {
            0 => {},
            1 => try validateIndex(try r.u32_(), str_count),
            2 => {
                try validateIndex(try r.u32_(), str_count);
                if (try r.u8_() > 1 or try r.u8_() > 1) return corruptAt(@src());
            },
            else => return corruptAt(@src()),
        }
        try validateOptSpanRecord(&r, str_count);
        const code = try r.bytesN(try r.u32_());
        const const_count = try r.u32_();
        var c: u32 = 0;
        while (c < const_count) : (c += 1) try validateConstantRecord(&r, str_count, 0);
        const attr_names_count = try r.u32_();
        c = 0;
        while (c < attr_names_count) : (c += 1) try validateIndex(try r.u32_(), str_count);
        const attr_pos_count = try r.u32_();
        c = 0;
        while (c < attr_pos_count) : (c += 1) try validateAttrPosRecord(&r, str_count);
        const function_args_count = try r.u32_();
        c = 0;
        while (c < function_args_count) : (c += 1) {
            try validateIndex(try r.u32_(), str_count);
            if (try r.u8_() > 1) return corruptAt(@src());
        }
        const function_arg_pos_count = try r.u32_();
        c = 0;
        while (c < function_arg_pos_count) : (c += 1) try validateAttrPosRecord(&r, str_count);
        const capture_len = try r.u32_();
        const captures = try r.bytesN(capture_len);
        if (captures.len % 3 != 0) return corruptAt(@src());
        c = 0;
        while (c < captures.len) : (c += 3) if (captures[@intCast(c)] > 1) return corruptAt(@src());
        const source_map_count = try r.u32_();
        c = 0;
        while (c < source_map_count) : (c += 1) {
            const start = try r.u32_();
            const end = try r.u32_();
            if (start > end or end > code.len) return corruptAt(@src());
            try validateSpanRecord(&r, str_count);
        }
        // The code bytes themselves are checked by `validateAndPreflightCode`,
        // which the decoder runs over every chunk after decode and before it
        // mutates anything. Everything a decode reads to get here is checked
        // above, including the source-map bounds against `code.len`.
    }
    if (r.pos != bytes.len) return corruptAt(@src());
}
