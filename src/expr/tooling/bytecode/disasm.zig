//! Pretty-print a bytecode chunk with operand decoding and source-map
//! annotations. Used by `fix disasm` and by the trace pretty-printer.
//!
//! The disassembler never needs an evaluator: it only takes a chunk plus
//! an optional intern table for resolving InternIds to their source
//! strings, and an optional registry for resolving ChunkIds when walking
//! closure/thunk opcodes.

const std = @import("std");
const terminal_color = @import("base").terminal_color;
const terminal_text = @import("base").terminal_text;
const ColorDepth = terminal_color.Depth;
const hueColor = terminal_color.hueColor;
const bytecode = @import("../../bytecode.zig");
const Chunk = bytecode.Chunk;
const ChunkRegistry = bytecode.ChunkRegistry;
const opcode_mod = bytecode.opcode;
const OpCode = opcode_mod.OpCode;
const encoding = bytecode.encoding;
const inspect = bytecode.inspect;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const ValueType = @import("runtime").value.ValueType;
const intern_mod = @import("runtime").intern;
const InternTable = intern_mod.InternTable;

const InternId = types.InternId;
const ChunkId = types.ChunkId;

pub const Symbols = struct {
    intern: ?*const InternTable = null,
    registry: ?*const ChunkRegistry = null,

    fn internName(self: Symbols, id: InternId) ?[]const u8 {
        const tab = self.intern orelse return null;
        return tab.get(id);
    }
};

pub const Options = struct {
    /// Print the chunk identity/shape line. Embedders that already provide a
    /// section heading can suppress only the outermost header; recursively
    /// rendered child chunks keep theirs.
    show_header: bool = true,
    /// Print the chunk's cold side tables before the code: constants, formal
    /// arguments, attribute metadata, captures, and upvalues.
    show_constants: bool = true,
    /// Print the decoded instruction stream.
    show_code: bool = true,
    /// Print source-map column on the right.
    show_source: bool = true,
    /// Print the raw instruction bytes as a hex column (one color per byte
    /// value when `color_depth`, so repeated bytes/opcodes stand out).
    show_bytes: bool = false,
    /// Walk closure/thunk operands and recursively disassemble referenced chunks.
    recurse: bool = false,
    /// Colorize headers, mnemonics, operands, and the per-byte hex column.
    color_depth: ColorDepth = .none,
    /// Recursion cap when `recurse` is true; 0 = unlimited (a visited set still
    /// guarantees termination). The trace pretty-printer bounds this.
    max_depth: u8 = 4,
    /// Optional cross-reference graph; when set, each chunk header lists its
    /// incoming and outgoing chunk references.
    refs: ?*const inspect.RefGraph = null,
    /// Terminal width, for extending the zebra row background across the whole
    /// line. 0 disables the extension (background stops at the content).
    line_width: u16 = 0,
    /// Instruction byte offset to mark as the live/current location.
    current_offset: ?u32 = null,
};

/// Bytes shown per row: the hex column is a fixed 4 cells wide (so the opcode
/// byte, operand bytes, mnemonic, and interpretation all align), and longer
/// records wrap onto continuation rows.
const bytes_per_line = 8;

/// Constant string/path snippets are truncated hard: the pool is a reference
/// table, not a value dump, and colored index links tie a `#N` back to its row.
/// Keeping entries short stops one long string from blowing out column widths.
const snippet_max = 20;

/// The constant pool table can afford longer values than inline references —
/// it's the definitive listing, so truncate it only for very long strings.
const table_snippet_max = 48;

const Visited = std.AutoHashMapUnmanaged(ChunkId, void);

pub fn writeChunk(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    chunk_id: ?ChunkId,
    chunk: *const Chunk,
    symbols: Symbols,
    options: Options,
) !void {
    var visited: Visited = .empty;
    defer visited.deinit(allocator);
    try writeChunkAt(allocator, writer, chunk_id, chunk, symbols, options, 0, &visited);
}

fn writeChunkAt(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    chunk_id: ?ChunkId,
    chunk: *const Chunk,
    symbols: Symbols,
    options: Options,
    // `usize`, not `u8`: `fix disasm` runs with `max_depth == 0` (unlimited,
    // termination guaranteed by `visited`), so a deep reachable-chunk chain
    // Deeply nested chunks can recurse past 255; a `u8` counter would
    // overflow and panic.
    depth: usize,
    visited: *Visited,
) anyerror!void {
    // The visited set only matters when recursing (`dumpAll`'s registry walk
    // passes recurse=false and visits each chunk exactly once) — skip the
    // per-call hashmap allocation entirely otherwise.
    if (options.recurse) if (chunk_id) |id| try visited.put(allocator, id, {});
    // Each chunk is a top-level group: a colored header and a left-margin guide
    // (in the chunk's own color) down every line of its body.
    const cc: [3]u8 = if (chunk_id) |id| hueColor(id) else .{ 0x9a, 0x9a, 0x9a };
    // The chunk's recorded upvalue names (slot order), used by the header table
    // and by upvalue-slot comments throughout the body.
    const up_names: ?[]const InternId = blk: {
        const id = chunk_id orelse break :blk null;
        const reg = symbols.registry orelse break :blk null;
        break :blk reg.upvalueNamesOf(id);
    };
    // The chunk's recorded local names (slot order), used to annotate
    // `local[N]` operand comments with the source binding name.
    const local_names: ?[]const InternId = blk: {
        const id = chunk_id orelse break :blk null;
        const reg = symbols.registry orelse break :blk null;
        break :blk reg.localNamesOf(id);
    };
    // The strict/deep flags fold into the upvalues table when it renders;
    // otherwise the header prints its fallback flag lines.
    if (options.show_header or depth > 0)
        try writeChunkHeader(writer, chunk_id, chunk, symbols, cc, up_names != null, options.color_depth);

    try writeChunkTables(writer, chunk_id, chunk, symbols, options, cc, up_names);

    if (!options.show_code) return;

    var ip: usize = 0;
    var referenced_chunks: std.AutoArrayHashMapUnmanaged(ChunkId, void) = .empty;
    defer referenced_chunks.deinit(allocator);
    const ref_sink: RefSink = .{ .map = &referenced_chunks, .allocator = allocator };

    // Scratch for each instruction's compact operand decode. Growable (reset,
    // capacity retained, per instruction) rather than a fixed buffer: a decode
    // is normally a few dozen bytes, but a pathological attribute name or path
    // (`x."<multi-KB string>"`) is unbounded, and overflowing a fixed buffer
    // would abort the whole disassembly with a write error.
    var op_scratch: std.Io.Writer.Allocating = .init(allocator);
    defer op_scratch.deinit();

    const env = Env{
        .cc = cc,
        .show_bytes = options.show_bytes,
        .color_depth = options.color_depth,
        .line_width = options.line_width,
    };
    // Zebra stripe unit counter for the body rows (see takeBg).
    var stripe: usize = 0;

    // Source filenames are hoisted onto their own comment line: one at the top
    // of the chunk (before any bytes) and again only if the file changes
    // mid-chunk. File lines are not striped and don't advance the stripe.
    var last_file: ?InternId = null;
    if (options.show_source) {
        if (inspect.chunkPrimaryFile(chunk, chunk_id, symbols.registry)) |f| {
            try writeGuide(writer, cc, null, options.color_depth);
            try writeFileLine(writer, f, symbols, options.color_depth);
            last_file = f;
        }
    }

    while (ip < chunk.code.len) {
        const start = ip;
        const op_byte = chunk.code[ip];
        // OpCode is a gapless `enum(u8)`, so anything ≥ the tag count is not a
        // valid opcode — a misaligned decode, or (under `--eval`) a registry
        // chunk that isn't plain bytecode. Show the raw byte and resync one byte
        // forward instead of crashing on `@enumFromInt`.
        if (op_byte >= opcode_mod.count) {
            ip += 1;
            const current = options.current_offset == @as(u32, @intCast(start));
            const bg = rowBackground(&stripe, current, options.color_depth);
            try beginRow(writer, bg, options.color_depth);
            try writeGuide(writer, cc, bg, options.color_depth);
            try writeOffset(writer, start, current, bg, options.color_depth);
            try writer.writeAll("  ");
            if (options.show_bytes) try writeByteCellColored(writer, op_byte, byteRgb(op_byte), bg, options.color_depth);
            if (options.show_bytes) try writer.splatByteAll(' ', (bytes_per_line - 1) * 3 + 1);
            try setCommentFg(writer, options.color_depth);
            try writer.print(".byte 0x{x:0>2}", .{op_byte});
            try sgrReset(writer, bg, options.color_depth);
            try endRow(writer, bg, env.prefixWidth() + 10, env);
            continue;
        }
        const op: OpCode = @enumFromInt(op_byte);
        ip += 1;

        // Decode the operands into scratch first: we need the full instruction
        // byte-range (to print the raw-byte column ahead of the mnemonic) before
        // writing the line.
        op_scratch.writer.end = 0;
        ip = try writeOperands(&op_scratch.writer, chunk, op, ip, symbols, up_names, ref_sink);
        const operand_text = op_scratch.writer.buffered();

        // Find the narrowest source span covering this instruction; hoist its
        // filename onto its own line when it changes from the previous one.
        const span: ?Chunk.SourceSpan = if (options.show_source) inspect.bestSpan(chunk, start) else null;
        if (span) |s| {
            if (s.file) |f| {
                if (last_file == null or last_file.? != f) {
                    try writeGuide(writer, cc, null, options.color_depth);
                    try writeFileLine(writer, f, symbols, options.color_depth);
                    last_file = f;
                }
            }
        }

        // Every instruction renders through the same head/tail token model:
        // the mnemonic row carries the head operand (raw accessors, byte-linked,
        // with a colored token comment); multiline ops add indented child rows.
        const current = options.current_offset == @as(u32, @intCast(start));
        const bg = rowBackground(&stripe, current, options.color_depth);
        try beginRow(writer, bg, options.color_depth);
        try writeGuide(writer, cc, bg, options.color_depth);
        try writeOffset(writer, start, current, bg, options.color_depth);
        try writer.writeAll("  ");
        var seq: usize = @intFromEnum(op) + 1;
        var head: Line = undefined;
        head.reset();
        const head_len = buildHead(&head, op, chunk, start, symbols, up_names, local_names, operand_text, ip, &seq);
        try emitMnemonicHead(writer, chunk.code, start, op, &head, head_len, &seq, bg, env);
        if (isMultiline(op)) {
            try writeOperandTail(writer, chunk, op, start + 1 + head_len, ip, operand_text, &seq, symbols, up_names, local_names, &stripe, env);
        }
    }

    if (options.recurse) {
        const reg = symbols.registry orelse return;
        if (options.max_depth != 0 and depth + 1 >= @as(usize, options.max_depth)) return;
        var it = referenced_chunks.iterator();
        while (it.next()) |entry| {
            const child_id = entry.key_ptr.*;
            if (visited.contains(child_id)) continue;
            const child = reg.get(child_id) orelse continue;
            try writer.writeByte('\n');
            try writeChunkAt(allocator, writer, child_id, child, symbols, options, depth + 1, visited);
        }
    }
}

fn writeChunkTables(
    writer: *std.Io.Writer,
    chunk_id: ?ChunkId,
    chunk: *const Chunk,
    symbols: Symbols,
    options: Options,
    cc: [3]u8,
    up_names: ?[]const InternId,
) !void {
    if (!options.show_constants) return;

    if (chunk.constants.len > 0) {
        try writeGuide(writer, cc, null, options.color_depth);
        try writer.writeAll("  constants:\n");
        for (chunk.constants, 0..) |constant, i| {
            try writeGuide(writer, cc, null, options.color_depth);
            try writer.writeAll("  ");
            try writeTreeGuide(writer, sec_constants_color, if (i == chunk.constants.len - 1) .corner else .vert, null, options.color_depth);
            var index_buf: [8]u8 = undefined;
            const index_text = std.fmt.bufPrint(&index_buf, "#{d}", .{i}) catch "#?";
            if (options.color_depth.enabled()) {
                try setFg(writer, constColor(i), options.color_depth);
                try writer.writeAll(index_text);
                try writer.writeAll("\x1b[0m");
            } else {
                try writer.writeAll(index_text);
            }
            try writer.splatByteAll(' ', 6 -| index_text.len);
            try writeValueDigest(writer, constant, symbols, table_snippet_max, options.color_depth);
            try writer.writeByte('\n');
        }
    }

    if (chunk.function_args.len > 0) {
        try writeGuide(writer, cc, null, options.color_depth);
        try writer.writeAll("  function arguments:\n");
        for (chunk.function_args, 0..) |arg, i| {
            try writeTableRowHead(writer, cc, sec_function_args_color, i, i == chunk.function_args.len - 1, attrNameColor(i), options.color_depth);
            try writeInternNameRef(writer, arg.name, symbols, table_snippet_max, options.color_depth);
            try setCommentFg(writer, options.color_depth);
            try writer.writeAll(" = ");
            if (options.color_depth.enabled()) try writer.writeAll("\x1b[0m");
            try writeValueDigest(writer, arg.value, symbols, table_snippet_max, options.color_depth);
            if (i < chunk.function_arg_pos.len) {
                try setCommentFg(writer, options.color_depth);
                try writer.writeAll(" ; ");
                if (options.color_depth.enabled()) try writer.writeAll("\x1b[0m");
                try writeAttrPosLocation(writer, chunk.function_arg_pos[i], symbols, options.color_depth);
            }
            try writer.writeByte('\n');
        }
    }

    if (chunk.attr_names.len > 0) {
        try writeGuide(writer, cc, null, options.color_depth);
        try writer.writeAll("  attr names:\n");
        for (chunk.attr_names, 0..) |name, i| {
            try writeTableRowHead(writer, cc, sec_attr_names_color, i, i == chunk.attr_names.len - 1, attrNameColor(i), options.color_depth);
            try writeInternNameRef(writer, name, symbols, table_snippet_max, options.color_depth);
            try writer.writeByte('\n');
        }
    }
    if (chunk.attr_pos.len > 0) {
        try writeGuide(writer, cc, null, options.color_depth);
        try writer.writeAll("  attr positions:\n");
        for (chunk.attr_pos, 0..) |position, i| {
            try writeTableRowHead(writer, cc, sec_attr_pos_color, i, i == chunk.attr_pos.len - 1, attrPosColor(i), options.color_depth);
            try writeAttrPosRow(writer, position, symbols, options.color_depth);
            try writer.writeByte('\n');
        }
    }
    if (chunk.capture_bytes.len > 0) {
        try writeGuide(writer, cc, null, options.color_depth);
        try writer.writeAll("  capture descriptors:\n");
        const count = chunk.capture_bytes.len / 3;
        for (0..count) |i| {
            const offset = i * 3;
            const is_upvalue = chunk.capture_bytes[offset] != 0;
            const index = readU16(chunk.capture_bytes, offset + 1);
            try writeTableRowHead(writer, cc, sec_captures_color, i, i == count - 1, upvColor(i), options.color_depth);
            try writer.print("@{d} {s}[{d}]\n", .{ offset, if (is_upvalue) "upvalue" else "local", index });
        }
    }

    if (up_names) |names| try writeUpvalueTable(writer, chunk, names, symbols, options, cc);

    if (chunk_id) |id| if (options.refs) |graph| {
        const incoming = graph.incoming(id);
        const outgoing = graph.outgoing(id);
        if (incoming.len > 0 or outgoing.len > 0) {
            try writeGuide(writer, cc, null, options.color_depth);
            try writer.writeAll("  references:\n");
            try writeRefList(writer, "incoming", sec_incoming_color, incoming, outgoing.len == 0, symbols, cc, options.color_depth);
            try writeRefList(writer, "outgoing", sec_outgoing_color, outgoing, true, symbols, cc, options.color_depth);
        }
    };
}

fn writeUpvalueTable(writer: *std.Io.Writer, chunk: *const Chunk, names: []const InternId, symbols: Symbols, options: Options, cc: [3]u8) !void {
    const strict = chunk.scheduling.strictness.forced_upvalues;
    const deep = chunk.scheduling.strictness.deep_upvalues & ~strict;
    try writeGuide(writer, cc, null, options.color_depth);
    try writer.writeAll("  upvalues:\n");
    for (names, 0..) |name_id, i| {
        try writeGuide(writer, cc, null, options.color_depth);
        try writer.writeAll("  ");
        try writeTreeGuide(writer, sec_upvalues_color, if (i == names.len - 1) .corner else .vert, null, options.color_depth);
        var index_buf: [8]u8 = undefined;
        const index_text = std.fmt.bufPrint(&index_buf, "#{d}", .{i}) catch "#?";
        if (options.color_depth.enabled()) {
            try setFg(writer, upvColor(i), options.color_depth);
            try writer.writeAll(index_text);
            try writer.writeAll("\x1b[0m");
        } else {
            try writer.writeAll(index_text);
        }
        try writer.splatByteAll(' ', 6 -| index_text.len);
        if (symbols.internName(name_id)) |raw| {
            const name = if (raw.len > 0 and raw[0] == 0) raw[1..] else raw;
            try setFg(writer, name_color, options.color_depth);
            try writer.writeAll(name);
            if (options.color_depth.enabled()) try writer.writeAll("\x1b[0m");
        } else {
            try writer.print("0x{x}", .{name_id});
        }
        const is_strict = i < 64 and (strict >> @intCast(i)) & 1 == 1;
        const is_deep = i < 64 and (deep >> @intCast(i)) & 1 == 1;
        if (is_strict or is_deep) {
            try setCommentFg(writer, options.color_depth);
            try writer.print(" ; {s}", .{if (is_strict) "strict" else "deep"});
            if (options.color_depth.enabled()) try writer.writeAll("\x1b[0m");
        }
        try writer.writeByte('\n');
    }
}

/// One row of the raw-byte column: `bytes` hex cells (color-coded per byte
/// value when `color_depth`), padded to a fixed width so what follows aligns.
/// `bytes.len` must be ≤ `bytes_per_row`.
fn writeByteField(writer: *std.Io.Writer, bytes: []const u8, color_depth: ColorDepth) !void {
    for (bytes) |b| try writeByteCell(writer, b, color_depth);
    try writer.splatByteAll(' ', (bytes_per_line - bytes.len) * 3);
}

/// One `xx ` hex cell, color-coded per byte value when `color_depth`.
fn writeByteCell(writer: *std.Io.Writer, b: u8, color_depth: ColorDepth) !void {
    if (color_depth.enabled()) {
        const rgb = byteRgb(b);
        try setFg(writer, rgb, color_depth);
        try writer.print("{x:0>2}\x1b[0m ", .{b});
    } else {
        try writer.print("{x:0>2} ", .{b});
    }
}

/// Map a byte value to a legible, deterministic RGB color. The golden-angle
/// hue step maximizes separation between nearby byte values, and a high value
/// keeps every color readable on a dark terminal; equal bytes always share a
/// color, so repeats and runs pop visually.
fn byteRgb(b: u8) [3]u8 {
    return hueColor(b);
}

fn writeOffset(writer: *std.Io.Writer, off: usize, current: bool, bg: ?[3]u8, color_depth: ColorDepth) !void {
    if (current) {
        try setFg(writer, hueColor(3), color_depth);
        try writer.writeAll("▶");
        try sgrReset(writer, bg, color_depth);
        try writer.writeByte(' ');
    } else {
        try writer.writeAll("  ");
    }
    if (color_depth.enabled()) try writer.writeAll("\x1b[2m");
    try writer.print("{x:0>4}", .{off});
    try sgrReset(writer, bg, color_depth);
}

/// Write the mnemonic followed by a single space. When colored, it takes the
/// same per-value color as its opcode byte, so the mnemonic and its leading hex
/// cell visually match.
fn writeMnemonic(writer: *std.Io.Writer, op: OpCode, bg: ?[3]u8, color_depth: ColorDepth) !void {
    const name = @tagName(op);
    if (color_depth.enabled()) {
        const rgb = byteRgb(@intFromEnum(op));
        try setFg(writer, rgb, color_depth);
        try writer.writeAll(name);
        try sgrReset(writer, bg, color_depth);
    } else {
        try writer.writeAll(name);
    }
    try writer.writeByte(' ');
}

// ---------------------------------------------------------------------------
// Operand field rendering: one indented line per operand field
// ---------------------------------------------------------------------------

/// Every chunk has an identity color derived from its id — the same hue is used
/// for its header title and for every reference to it, so a `chunk[0xN]` operand
/// visually points at the header it names.
pub const Identity = enum {
    chunk,
    constant,
    intern,
    object,
    value,
    attr,
    attr_position,
    builtin,
};

/// The canonical identity color for a VM reference.  Explorer surfaces use
/// this too, so `objects[0x8]`, `values[0x8]`, and `chunk[0x8]` each keep a
/// stable (and intentionally distinct) hue wherever they appear.
pub fn identityColor(kind: Identity, id: anytype) [3]u8 {
    const seed: usize = switch (kind) {
        .chunk => 0,
        .constant => 1000,
        .intern => 5000,
        .object => 9000,
        .value => 13000,
        .attr => 17000,
        .attr_position => 21000,
        .builtin => 25000,
    };
    return hueColor(@as(usize, @intCast(id)) + seed);
}

fn objColor(id: anytype) [3]u8 {
    return identityColor(.chunk, id);
}

/// Fixed color for compiler-attributed chunk names, wherever they appear
/// (header title and operand comments), so a name always reads as a name.
const name_color: [3]u8 = .{ 0x83, 0xd6, 0x8f };

/// Subtle background tint for alternating multi-row list records, so each
/// 2-row entry reads as one block.
const row_bg: [3]u8 = .{ 0x28, 0x28, 0x34 };

/// A restrained live-instruction tint; the marker remains visible on terminals
/// without color, while this makes the whole row easy to reacquire in a dense
/// disassembly.
const current_row_bg: [3]u8 = .{ 0x32, 0x2b, 0x43 };

/// A constant pool slot's identity color, shared by its `#N` references and its
/// row in the pool table. Offset well past typical chunk ids so a `#N` constant
/// and a `chunk[0xN]` never share a hue in the same listing.
fn constColor(i: usize) [3]u8 {
    return identityColor(.constant, i);
}

/// Identity color for an interned string/path id: the same hue everywhere the
/// id appears — as a raw operand, inside an `intern[0xN]` comment, and on its
/// constant-pool row — so occurrences of one id link up visually. Offset past
/// the chunk-id and constant-slot seeds.
fn internColor(id: anytype) [3]u8 {
    return identityColor(.intern, id);
}

/// Identity color for a heap object id (closures/thunks/lists in constant
/// digests). Own seed range, like chunks/constants/interns.
fn heapColor(id: anytype) [3]u8 {
    return identityColor(.object, id);
}

/// Identity color for an upvalue slot (chunk-local): the upvalues table row,
/// every `up_get #N` operand, and capture-descriptor indexes referencing the
/// slot all share it — like constants' `#N`.
fn upvColor(slot: anytype) [3]u8 {
    return hueColor(@as(usize, @intCast(slot)) + 1500);
}

/// Fixed keyword color for the store name in a `store[accessor]` reference
/// (`chunk[…]`, `str[…]`, …): the store reads as a keyword, the accessor
/// carries the identity color, and the brackets stay dim.
const store_kw_color: [3]u8 = .{ 0x7f, 0xbf, 0xd8 };

/// Section guide colors (constants / references and its subsections), so each
/// indented table gets its own `│` gutter like operand groups do.
const sec_constants_color: [3]u8 = .{ 0xb8, 0xa6, 0x5c };
const sec_upvalues_color: [3]u8 = .{ 0xb8, 0x5c, 0x74 };
const sec_references_color: [3]u8 = .{ 0x5c, 0xb8, 0xa6 };
const sec_incoming_color: [3]u8 = .{ 0xa6, 0x5c, 0xb8 };
const sec_outgoing_color: [3]u8 = .{ 0x5c, 0x8a, 0xb8 };
const sec_attr_names_color: [3]u8 = .{ 0x8a, 0xb8, 0x5c };
const sec_attr_pos_color: [3]u8 = .{ 0xb8, 0x8a, 0x5c };
const sec_function_args_color: [3]u8 = .{ 0x5c, 0xa6, 0xb8 };
const sec_captures_color: [3]u8 = .{ 0xb8, 0x5c, 0xa6 };

/// Identity color for an `attr_names` side-table row: the same hue on the row
/// `#i` and on the `names[i..]` reference that points at it, so a reference ties
/// back to its section row (like a constant's `#N`). Own seed range.
fn attrNameColor(i: anytype) [3]u8 {
    return hueColor(@as(usize, @intCast(i)) + 13000);
}

/// Identity color for an `attr_pos` side-table row — like `attrNameColor`, its
/// own seed so a `positions[i..]` reference links to its row.
fn attrPosColor(i: anytype) [3]u8 {
    return hueColor(@as(usize, @intCast(i)) + 17000);
}

/// Column (from the mnemonic's first character) where instruction-line `;`
/// comments start. Field rows compute their pad from this too (minus their
/// guide indentation), so every `;` in a chunk body lands in one column.
const mnem_comment_col = 28;

/// Comment/structural text color — a readable grey, brighter than terminal-dim.
const comment_color: [3]u8 = .{ 0xb2, 0xb2, 0xb2 };

/// Shared rendering environment for the chunk-body emitters.
const Env = struct {
    /// Chunk guide color (the left margin `│`).
    cc: [3]u8,
    show_bytes: bool,
    color_depth: ColorDepth,
    /// Terminal width the zebra background extends to (0 = no extension).
    line_width: u16,

    /// Width of the fixed row prefix: guide + offset column + byte field + gap.
    fn prefixWidth(self: Env) u16 {
        return if (self.show_bytes) 35 else 11;
    }
};

/// Zebra striping: every other body row gets the background tint, where a
/// multi-row record (position entries) counts as ONE stripe unit. Returns the
/// current unit's background and advances the stripe.
fn takeBg(stripe: *usize, color_depth: ColorDepth) ?[3]u8 {
    const bg: ?[3]u8 = if (color_depth.enabled() and stripe.* % 2 == 1) row_bg else null;
    stripe.* += 1;
    return bg;
}

fn rowBackground(stripe: *usize, current: bool, color_depth: ColorDepth) ?[3]u8 {
    const striped = takeBg(stripe, color_depth);
    return if (current and color_depth.enabled()) current_row_bg else striped;
}

/// Start a body row: establish its background (if striped) from column 0, so
/// the tint covers the whole line including the left margin.
fn beginRow(writer: *std.Io.Writer, bg: ?[3]u8, color_depth: ColorDepth) !void {
    if (bg) |b| try terminal_color.background(writer, color_depth, b);
}

/// Finish a body row at absolute column `abs_w`: extend a striped row's tint to
/// the full terminal width, reset, newline.
fn endRow(writer: *std.Io.Writer, bg: ?[3]u8, abs_w: u16, env: Env) !void {
    if (env.color_depth.enabled() and bg != null and env.line_width > abs_w) {
        try writer.splatByteAll(' ', env.line_width - abs_w);
    }
    if (env.color_depth.enabled()) try writer.writeAll("\x1b[0m");
    try writer.writeByte('\n');
}

/// Visible width of UTF-8 text (codepoints; `→`/`…`/`│` count 1).
fn visibleWidth(text: []const u8) u16 {
    var w: u16 = 0;
    for (text) |ch| {
        if ((ch & 0xC0) != 0x80) w += 1;
    }
    return w;
}

/// Set the foreground for comment/structural text — the one grey used for
/// every `;` comment, bracket, and annotation, so nothing reads fainter than
/// the rest regardless of hue or the zebra background underneath.
fn setCommentFg(writer: *std.Io.Writer, color_depth: ColorDepth) !void {
    try setFg(writer, comment_color, color_depth);
}

/// Reset the foreground (and any attributes), then — inside a background-tinted
/// row (`bg` set) — re-establish that background so the tint survives per-cell
/// resets and stays an unbroken rectangle.
fn sgrReset(writer: *std.Io.Writer, bg: ?[3]u8, color_depth: ColorDepth) !void {
    if (!color_depth.enabled()) return;
    try writer.writeAll("\x1b[0m");
    if (bg) |b| try terminal_color.background(writer, color_depth, b);
}

fn writeByteCellColored(writer: *std.Io.Writer, b: u8, rgb: [3]u8, bg: ?[3]u8, color_depth: ColorDepth) !void {
    if (color_depth.enabled()) {
        try setFg(writer, rgb, color_depth);
        try writer.print("{x:0>2}", .{b});
        try sgrReset(writer, bg, color_depth);
        try writer.writeByte(' ');
    } else {
        try writer.print("{x:0>2} ", .{b});
    }
}

/// One `--fields` operand line: a run of colored byte-groups (each `len` bytes
/// at `byte_off`, whose interpretation `text` takes that group's color) and dim
/// structural glue (`len == 0`). Groups may be listed in display order even when
/// that differs from byte order — the shared color is the link, not position.
const Tok = struct { byte_off: u16 = 0, len: u16 = 0, text: []const u8, colored: bool = false, pin: bool = false, color: [3]u8 = .{ 0x9a, 0x9a, 0x9a } };

const Line = struct {
    toks: [24]Tok = undefined,
    n: usize = 0,
    buf: [1024]u8 = undefined,
    used: usize = 0,
    /// A token or its text did not fit. The line renders as much as it holds
    /// and ends in `…` (`sealTruncation`) — a debugger that refuses to print
    /// the program because one line is wide is worse than a shortened line.
    truncated: bool = false,
    /// Byte extent of tokens dropped for want of a slot. `total` folds it back
    /// in: the caller advances its instruction offset by `total`, so losing the
    /// display text must not lose the bytes that text stood for.
    dropped_extent: u16 = 0,
    /// Token index where the `;` comment starts, if any. The renderer pads the
    /// tokens before it out to `field_comment_col` so comment semicolons align.
    comment_tok: ?usize = null,

    /// Reset only initialized scalars; token and text storage is overwritten
    /// before use.
    inline fn reset(self: *Line) void {
        self.n = 0;
        self.used = 0;
        self.comment_tok = null;
        self.truncated = false;
        self.dropped_extent = 0;
    }

    fn store(self: *Line, comptime fmt: []const u8, args: anytype) []const u8 {
        const s = std.fmt.bufPrint(self.buf[self.used..], fmt, args) catch {
            self.truncated = true;
            return self.buf[self.used..self.used];
        };
        self.used += s.len;
        return s;
    }

    fn append(self: *Line, tok: Tok) void {
        if (self.n == self.toks.len) {
            self.dropTok(tok);
            return;
        }
        self.toks[self.n] = tok;
        self.n += 1;
    }

    fn dropTok(self: *Line, tok: Tok) void {
        self.truncated = true;
        if (tok.byte_off + tok.len > self.dropped_extent) self.dropped_extent = tok.byte_off + tok.len;
    }

    /// Mark a truncated line: the trailing token becomes `…`, the same mark
    /// `writeEscapedSnippet` and the under-count guard row use for elided
    /// content. The `…` text is static rather than stored, since a line that
    /// overflowed `buf` has no room left to format it into.
    fn sealTruncation(self: *Line) void {
        if (!self.truncated) return;
        if (self.n == self.toks.len) self.dropTok(self.toks[self.n - 1]) else self.n += 1;
        self.toks[self.n - 1] = .{ .text = "…" };
    }

    /// Dim structural text (brackets, separators, `chunk `), consumes no bytes.
    fn glue(self: *Line, comptime fmt: []const u8, args: anytype) void {
        const s = self.store(fmt, args);
        self.append(.{ .text = s });
    }
    /// A decoded value: `len` bytes at `byte_off`, text tinted to match them.
    fn group(self: *Line, byte_off: u16, len: u16, comptime fmt: []const u8, args: anytype) void {
        const s = self.store(fmt, args);
        self.append(.{ .byte_off = byte_off, .len = len, .text = s, .colored = true });
    }
    /// Like `group`, but with an explicit identity `color` (its bytes take it
    /// too) instead of the running-hue assignment — for a chunk id, whose color
    /// is fixed to the chunk it names.
    fn groupPinned(self: *Line, byte_off: u16, len: u16, color: [3]u8, comptime fmt: []const u8, args: anytype) void {
        const s = self.store(fmt, args);
        self.append(.{ .byte_off = byte_off, .len = len, .text = s, .colored = true, .pin = true, .color = color });
    }
    /// Colored text that maps to no bytes — an interpretive comment fragment
    /// (`chunk[0xN]`, a name) drawn in a fixed color rather than dim grey.
    fn tint(self: *Line, color: [3]u8, comptime fmt: []const u8, args: anytype) void {
        const s = self.store(fmt, args);
        self.append(.{ .text = s, .colored = true, .pin = true, .color = color });
    }
    /// Begin the `;` comment: marks the alignment point, then writes ` ; `.
    fn comment(self: *Line) void {
        if (self.comment_tok == null) self.comment_tok = self.n;
        self.glue(" ; ", .{});
    }
    /// A `store[accessor]` reference: keyword in the fixed store color, brackets
    /// dim, accessor in the object's identity color. The uniform shape for every
    /// cross-reference (`chunk[0xN]`, `intern[0xN]`, …).
    fn storeRef(self: *Line, kw: []const u8, id_color: [3]u8, comptime id_fmt: []const u8, id_args: anytype) void {
        self.tint(store_kw_color, "{s}", .{kw});
        self.glue("[", .{});
        self.tint(id_color, id_fmt, id_args);
        self.glue("]", .{});
    }
    fn total(self: *const Line) u16 {
        var m: u16 = self.dropped_extent;
        for (self.toks[0..self.n]) |t| {
            if (t.byte_off + t.len > m) m = t.byte_off + t.len;
        }
        return m;
    }
    /// Assign each group the next hue from the running counter, so adjacent
    /// groups differ sharply regardless of their byte values. The HSV math is
    /// skipped when not coloring (nothing reads the colors then), but `seq`
    /// still advances so hue assignment is identical either way.
    fn paint(self: *Line, seq: *usize, color_depth: ColorDepth) void {
        for (self.toks[0..self.n]) |*t| {
            if (t.colored and t.len > 0 and !t.pin) {
                if (color_depth.enabled()) t.color = hueColor(seq.*);
                seq.* += 1;
            }
        }
    }
    fn colorAt(self: *const Line, pos: u16) [3]u8 {
        for (self.toks[0..self.n]) |t| {
            if (t.len > 0 and pos >= t.byte_off and pos < t.byte_off + t.len) return t.color;
        }
        return .{ 0x9a, 0x9a, 0x9a }; // ungrouped byte
    }
};

/// One hierarchy indent guide, drawn once per ancestor group and colored by
/// that group's title — a background block in color mode, `│` otherwise. This
/// is what nests capture/position lists under their count line.
fn writeGuide(writer: *std.Io.Writer, rgb: [3]u8, bg: ?[3]u8, color_depth: ColorDepth) !void {
    if (color_depth.enabled()) {
        try setFg(writer, rgb, color_depth);
        try writer.writeAll("│");
        try sgrReset(writer, bg, color_depth);
        try writer.writeByte(' ');
    } else {
        try writer.writeAll("│ ");
    }
}

/// One operand-hierarchy gutter cell. Tree columns stay vertical for their
/// entire run; the last item does not change the column into a corner.
const GuideKind = enum { vert, corner, blank };
fn writeTreeGuide(writer: *std.Io.Writer, rgb: [3]u8, kind: GuideKind, bg: ?[3]u8, color_depth: ColorDepth) !void {
    const glyph: []const u8 = switch (kind) {
        .vert => "│  ",
        .corner => "│  ",
        .blank => "   ",
    };
    if (color_depth.enabled() and kind != .blank) {
        try setFg(writer, rgb, color_depth);
        try writer.writeAll(glyph);
        try sgrReset(writer, bg, color_depth);
    } else {
        try writer.writeAll(glyph); // blank guide: bare spaces (already on `bg`)
    }
}

/// Render one operand line at `off` under `guides` (ancestor colors), then
/// advance `off` past its bytes. Bytes stay in their fixed column (aligned under
/// the opcode byte); the hierarchy guides sit in the mnemonic gutter to the
/// right of the bytes, so the interpretation reads as an indented child of the
/// mnemonic. Long records wrap at `bytes_per_line`, guides repeating on each
/// row (a continuous gutter) but the interpretation only on the first. `seq` is
/// the running per-instruction color counter (shared with the mnemonic).
fn emitLine(writer: *std.Io.Writer, code: []const u8, off: *usize, line: *Line, seq: *usize, guides: []const [3]u8, last_mask: u8, bg: ?[3]u8, env: Env) !void {
    line.sealTruncation();
    const base = off.*;
    const total = line.total();
    line.paint(seq, env.color_depth);
    const depth: u16 = @intCast(guides.len);
    // Field-row comment column, relative to the token area: absolute alignment
    // with the mnemonic-line comments, minus this row's guide indentation.
    const comment_col = mnem_comment_col -| 3 * depth;
    const rows: u16 = if (!env.show_bytes or total == 0) 1 else (total + bytes_per_line - 1) / bytes_per_line;
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        try beginRow(writer, bg, env.color_depth);
        try writeGuide(writer, env.cc, bg, env.color_depth);
        try writer.writeAll("        "); // blank offset column
        if (env.show_bytes) {
            var c: u16 = 0;
            while (c < bytes_per_line) : (c += 1) {
                const pos = r * bytes_per_line + c;
                if (pos < total) try writeByteCellColored(writer, code[base + pos], line.colorAt(pos), bg, env.color_depth) else try writer.writeAll("   ");
            }
        }
        try writer.writeByte(' '); // gap column between the bytes and the gutter
        // Tree gutter: every ancestor level draws a vertical bar `│` down the
        // gutter; a level whose run ends at this line (`last_mask` bit i)
        // remains `│` on the line's final row.
        for (guides, 0..) |gc, gi| {
            const ends = (last_mask >> @intCast(gi)) & 1 == 1;
            const kind: GuideKind = if (ends and r == rows - 1) .corner else .vert;
            try writeTreeGuide(writer, gc, kind, bg, env.color_depth);
        }
        var w: u16 = 0;
        if (r == 0) {
            for (line.toks[0..line.n], 0..) |t, i| {
                // Align the `;` comments down the block: pad the raw-value
                // region out to the shared column before the comment starts.
                if (line.comment_tok != null and i == line.comment_tok.? and w < comment_col) {
                    try sgrReset(writer, bg, env.color_depth);
                    try writer.splatByteAll(' ', comment_col - w);
                    w = comment_col;
                }
                if (env.color_depth.enabled()) {
                    if (t.colored) {
                        try setFg(writer, t.color, env.color_depth);
                    } else {
                        // Structural / comment text: grey — reset first so it
                        // doesn't inherit the previous token's hue.
                        try sgrReset(writer, bg, env.color_depth);
                        try setFg(writer, comment_color, env.color_depth);
                    }
                }
                try writer.writeAll(t.text);
                w += visibleWidth(t.text);
            }
        }
        try endRow(writer, bg, env.prefixWidth() + 3 * depth + w, env);
    }
    off.* += total;
}

/// Whether a chunk-id-carrying op uses the wide (u32) id form.
fn chunkIdWide(op: OpCode) bool {
    return switch (op) {
        .closure_w, .closure_cap_w, .thunk_w, .thunk_arg, .thunk_w_st, .thunk_w_st_cell => true,
        else => false,
    };
}

/// The builtin's Nix-visible name for a raw builtin id, if the id is valid.
/// Kept public so debugger/value views can use the same spelling as disassembly.
pub fn builtinName(id: u64) ?[]const u8 {
    const builtins = @import("runtime").builtins;
    const BuiltinId = builtins.BuiltinId;
    inline for (@typeInfo(BuiltinId).@"enum".fields) |f| {
        if (f.value == id) return builtins.displayName(@enumFromInt(f.value));
    }
    return null;
}

/// Human-facing type spelling shared by disassembly and VM value views.
pub fn valueKindLabel(kind: ValueType) []const u8 {
    return switch (kind) {
        .bool_false, .bool_true => "bool",
        .builtin_closure => "builtin closure",
        .string_context => "context string",
        .boxed_int => "boxed int",
        .partial_app => "partial application",
        else => @tagName(kind),
    };
}

/// Escape `text` (middle-truncated at `max`) into `buf`, returning the slice.
fn escSnippet(buf: []u8, text: []const u8, max: usize) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeEscapedSnippet(&w, text, max) catch {};
    return w.buffered();
}

/// Token form of an intern-backed value: `intern[0xN] → type "text"`.
/// The address leads, while the type and resolved text describe its value.
fn lineInternValue(l: *Line, kind: []const u8, id: InternId, symbols: Symbols, max: usize) void {
    const c = internColor(id);
    l.storeRef("intern", c, "0x{x}", .{id});
    l.glue(" → ", .{});
    if (symbols.internName(id)) |text| {
        var buf: [128]u8 = undefined;
        l.tint(c, "{s} \"{s}\"", .{ kind, escSnippet(&buf, text, max) });
    } else {
        l.tint(c, "{s}", .{kind});
    }
}

fn lineLocatedValue(l: *Line, store: []const u8, id: u64, identity: Identity, description: []const u8) void {
    const c = identityColor(identity, id);
    l.storeRef(store, c, "0x{x}", .{id});
    l.glue(" → ", .{});
    l.tint(c, "{s}", .{description});
}

fn shortFloat(buf: []u8, value: f64) []const u8 {
    const number = std.fmt.bufPrint(buf, "{d:.3}", .{value}) catch return "?";
    if (!std.math.isFinite(value)) return number;
    const rounded = std.fmt.parseFloat(f64, number) catch value;
    if (rounded == value) return number;
    if (number.len == buf.len) return number;
    std.mem.copyBackwards(u8, buf[1 .. number.len + 1], number);
    buf[0] = '~';
    return buf[0 .. number.len + 1];
}

/// Token form of `writeValueDigest`: `location → type → description` with
/// identity colors, for mnemonic-line comments. Inline scalars have no
/// location and begin with their type.
fn lineValueDigest(l: *Line, value: Value, symbols: Symbols, max: usize) void {
    switch (value.kind()) {
        .null => l.glue("null", .{}),
        .bool_true => l.glue("bool true", .{}),
        .bool_false => l.glue("bool false", .{}),
        .int => l.glue("int {d}", .{value.asInt()}),
        .float => {
            var buf: [64]u8 = undefined;
            l.glue("float {s}", .{shortFloat(&buf, value.asFloat())});
        },
        .string => lineInternValue(l, "string", value.asInternId(), symbols, max),
        .path => lineInternValue(l, "path", value.asInternId(), symbols, max),
        .list => lineLocatedValue(l, "objects", value.asObjectId(), .object, "list"),
        .attrs => lineLocatedValue(l, "objects", value.asObjectId(), .object, "attrs"),
        .closure => if (value.isFunction())
            lineLocatedValue(l, "chunk", value.asFunctionChunkId(), .chunk, "function")
        else
            lineLocatedValue(l, "objects", value.asObjectId(), .object, "closure"),
        .thunk => lineLocatedValue(l, "objects", value.asObjectId(), .object, "thunk"),
        .builtin => {
            const bid = value.asBuiltinId();
            l.storeRef("builtin", identityColor(.builtin, bid), "0x{x}", .{bid});
            if (builtinName(bid)) |nm| {
                l.glue(" → ", .{});
                l.tint(identityColor(.builtin, bid), "{s}", .{nm});
            }
        },
        .builtin_closure => lineLocatedValue(l, "objects", value.asObjectId(), .object, "builtin closure"),
        .string_context => lineLocatedValue(l, "objects", value.asObjectId(), .object, "context string"),
        .heap_string => lineLocatedValue(l, "objects", value.asObjectId(), .object, "heap string"),
        .boxed_int => lineLocatedValue(l, "objects", value.asObjectId(), .object, "boxed int"),
        .partial_app => lineLocatedValue(l, "objects", value.asObjectId(), .object, "partial application"),
    }
}

/// Build the *head* operand — the accessor(s) the mnemonic line carries — as a
/// `Line` whose byte offsets are relative to the opcode byte (byte 0). For
/// multiline ops this is the leading scalar (chunk id / counts) and the list
/// tail follows on child rows; for single-line ops it is the WHOLE operand,
/// with the interpretation as a colored token comment. Ops without a bespoke
/// arm fall back to the compact `operand_text` decode. Returns the number of
/// operand bytes the head covers.
/// Mnemonic-row head. Three ops keep a bespoke arm (their head/body split or
/// format isn't a plain scalar sequence); everything else is rendered from the
/// operand-layout table by `buildHeadGeneric`.
fn buildHead(l: *Line, op: OpCode, chunk: *const Chunk, start: usize, symbols: Symbols, up_names: ?[]const InternId, local_names: ?[]const InternId, operand_text: []const u8, end_ip: usize, seq: *usize) u16 {
    const code = chunk.code;
    switch (op) {
        .thunk_defer => {
            // deferred id (4) + capture-list start (4) + env count (2). Captures
            // are interned in the chunk side table, not inline — single line.
            const id = readU32(code, start + 1);
            const cap_start = readU32(code, start + 5);
            const cap_count = readU16(code, start + 9);
            l.group(1, 10, "#{d}", .{id});
            l.comment();
            l.glue("deferred #{d}, {d} env @cap[{d}]", .{ id, cap_count, cap_start });
            return 10;
        },
        .attrs_new_named_srt, .attrs_new_named_pos_srt => {
            const entries = readU16(code, start + 1);
            const c_e = hueColor(seq.*);
            seq.* += 1;
            l.groupPinned(1, 2, c_e, "#{d}", .{entries});
            l.comment();
            l.tint(c_e, "{d}", .{entries});
            l.glue(" entries (named)", .{});
            return 2;
        },
        .attr_bind, .attr_bind_w => {
            const allow = code[start + 1];
            const cells = code[start + 2];
            const expected = readU16(code, start + 3);
            const c_a = hueColor(seq.*);
            const c_c = hueColor(seq.* + 1);
            const c_n = hueColor(seq.* + 2);
            seq.* += 3;
            l.groupPinned(1, 1, c_a, "#{d}", .{allow});
            l.glue(" ", .{});
            l.groupPinned(2, 1, c_c, "#{d}", .{cells});
            l.glue(" ", .{});
            l.groupPinned(3, 2, c_n, "#{d}", .{expected});
            l.comment();
            l.tint(c_n, "{d}", .{expected});
            l.glue(" formals, ", .{});
            l.tint(c_a, "extra {s}", .{if (allow != 0) "allowed" else "rejected"});
            l.glue(", ", .{});
            l.tint(c_c, "{s}", .{if (cells != 0) "cells" else "locals"});
            return 4;
        },
        .attr_get_path_or, .attr_get_path_dyn_or, .attr_has_path => return buildAttrPathHead(l, code, start, false, symbols, seq),
        .attr_get_path_or_w, .attr_get_path_dyn_or_w, .attr_has_path_w => return buildAttrPathHead(l, code, start, true, symbols, seq),
        .attr_get_path_mix_or, .attr_has_path_mix => return buildMixPathHead(l, code, start, symbols, seq),
        else => return buildHeadGeneric(l, op, chunk, start, symbols, up_names, local_names, operand_text, end_ip, seq),
    }
}

/// A path segment's name group in the `; "a.b.c"` comment: `escSnippet` copies
/// the source name into the line buffer, so its stack scratch need not outlive
/// this call. `off` is the byte offset (from the opcode) of the segment's id
/// run and `len` its width — pinning the name's color to those exact bytes so
/// the id run in the hex column reads as the same color as the name it decodes.
fn appendPathSegment(l: *Line, id: InternId, off: u16, len: u16, symbols: Symbols) void {
    const c = internColor(id);
    if (symbols.internName(id)) |name| {
        var buf: [128]u8 = undefined;
        l.groupPinned(off, len, c, "{s}", .{escSnippet(&buf, name, snippet_max)});
    } else {
        l.groupPinned(off, len, c, "0x{x}", .{id});
    }
}

/// Single-line head for a static attribute path (`attr_get_path_or` &c.): the
/// leading segment-count byte in its own hue, then the dotted path as the
/// comment with EACH segment byte-linked to — and tinted to — its own id run,
/// so every id run in the hex column maps by color to the name it resolves to
/// (rather than the whole operand reading as one count-colored block).
fn buildAttrPathHead(l: *Line, code: []const u8, start: usize, wide: bool, symbols: Symbols, seq: *usize) u16 {
    const w: u16 = if (wide) 4 else 2;
    const segments = code[start + 1];
    const c_cnt = hueColor(seq.*);
    seq.* += 1;
    l.groupPinned(1, 1, c_cnt, "#{d}", .{segments});
    l.comment();
    l.glue("\"", .{});
    var off: u16 = 2; // first segment id, as a byte offset from the opcode
    var i: u8 = 0;
    while (i < segments) : (i += 1) {
        if (i > 0) l.glue(".", .{});
        const id: InternId = @intCast(readWidth(if (wide) .b4 else .b2, code, start + off));
        appendPathSegment(l, id, off, w, symbols);
        off += w;
    }
    l.glue("\"", .{});
    return off - 1; // count byte + segments * w
}

/// Single-line head for a mixed static/dynamic attribute path
/// (`attr_get_path_mix_or` / `attr_has_path_mix`): segment count and dynamic
/// count each get a hue, then the path renders in the comment with static
/// segments byte-linked to their name and dynamic segments shown as `${…}`
/// (their key comes from the stack), each tinted to its own byte run.
fn buildMixPathHead(l: *Line, code: []const u8, start: usize, symbols: Symbols, seq: *usize) u16 {
    const segments = code[start + 1];
    const dyn = code[start + 2];
    const c_cnt = hueColor(seq.*);
    seq.* += 1;
    const c_dyn = hueColor(seq.*);
    seq.* += 1;
    l.groupPinned(1, 1, c_cnt, "#{d}", .{segments});
    l.glue(" ", .{});
    l.groupPinned(2, 1, c_dyn, "#{d}", .{dyn});
    l.comment();
    l.glue("\"", .{});
    var off: u16 = 3; // first segment tag, as a byte offset from the opcode
    var i: u8 = 0;
    while (i < segments) : (i += 1) {
        if (i > 0) l.glue(".", .{});
        if (code[start + off] == 0) { // static: tag byte + 4-byte id
            const id: InternId = @intCast(readU32(code, start + off + 1));
            appendPathSegment(l, id, off, 5, symbols); // whole tag+id run
            off += 5;
        } else { // dynamic: tag byte only, key popped from the stack
            const c = hueColor(seq.*);
            seq.* += 1;
            l.groupPinned(off, 1, c, "${{…}}", .{});
            off += 1;
        }
    }
    l.glue("\"", .{});
    return off - 1;
}

/// Whether a field's contents are drawn as multiline child rows (by
/// `writeOperandTail`) rather than on the mnemonic row.
fn fieldIsList(f: Operand) bool {
    return switch (f) {
        .captures, .captures_slot, .attr_path, .bind, .mix => true,
        else => false,
    };
}

/// Table-driven head: render an op's leading SCALAR operand fields as byte-
/// pinned colored groups plus their grey interpretation. Multiline ops keep only their
/// leading scalar here (chunk id); the list body is drawn by `writeOperandTail`.
/// Ops whose head is a list (attr paths, mix) or empty fall back to the compact
/// decode.
fn buildHeadGeneric(l: *Line, op: OpCode, chunk: *const Chunk, start: usize, symbols: Symbols, up_names: ?[]const InternId, local_names: ?[]const InternId, operand_text: []const u8, end_ip: usize, seq: *usize) u16 {
    const code = chunk.code;
    const fields = opcode_mod.layout(op);
    const n_head: usize = if (isMultiline(op)) 1 else fields.len;
    if (n_head == 0 or fieldIsList(fields[0])) return buildHeadCompact(l, operand_text, start, end_ip);

    // Colors are computed in pass 1 and reused in pass 2 — a seq-based hue must
    // not advance twice for one field.
    var colors: [4][3]u8 = undefined;
    var byte: u16 = 0;
    var i: usize = 0;
    while (i < n_head) : (i += 1) {
        const f = fields[i];
        const off = start + 1 + byte;
        const flen: u16 = @intCast(opcode_mod.fieldLen(f, code, off));
        colors[i] = headColor(f, code, off, seq);
        if (i > 0) l.glue(" ", .{});
        headRaw(l, f, code, off, 1 + byte, flen, colors[i]);
        byte += flen;
    }
    l.comment();
    byte = 0;
    i = 0;
    while (i < n_head) : (i += 1) {
        if (i > 0) l.glue(", ", .{});
        headInterp(l, fields[i], chunk, code, start + 1 + byte, colors[i], symbols, up_names, local_names);
        byte += @intCast(opcode_mod.fieldLen(fields[i], code, start + 1 + byte));
    }
    return byte;
}

/// Fallback head for ops with no bespoke breakdown: the compact `writeOperands`
/// text, split into a byte-linked raw group and a grey ` ; ` interpretation.
fn buildHeadCompact(l: *Line, operand_text: []const u8, start: usize, end_ip: usize) u16 {
    const oplen: u16 = @intCast(end_ip - (start + 1));
    const cut = std.mem.indexOf(u8, operand_text, " ; ") orelse operand_text.len;
    if (oplen > 0 and cut > 0) l.group(1, oplen, "{s}", .{operand_text[0..cut]});
    if (cut < operand_text.len) {
        l.comment();
        l.glue("{s}", .{operand_text[cut + 3 ..]});
    } else if (oplen == 0 and operand_text.len > 0) {
        l.comment();
        l.glue("{s}", .{operand_text});
    }
    return oplen;
}

/// The identity color for a head field's byte group: value-derived for the
/// ref-like fields (chunk/intern/const/upvalue), a fresh sequential hue for the
/// positional ones (local slot / count / jump).
fn headColor(f: Operand, code: []const u8, off: usize, seq: *usize) [3]u8 {
    switch (f) {
        .const_idx => return constColor(readU16(code, off)),
        .slot => |s| if (s.role == .upvalue) return upvColor(readWidth(s.w, code, off)),
        .chunk_id, .intern => |w| return objInternColor(f, readWidth(w, code, off)),
        else => {},
    }
    const c = hueColor(seq.*);
    seq.* += 1;
    return c;
}

fn objInternColor(f: Operand, id: u32) [3]u8 {
    return switch (f) {
        .chunk_id => objColor(id),
        else => internColor(id),
    };
}

fn headRaw(l: *Line, f: Operand, code: []const u8, off: usize, col_byte: u16, flen: u16, color: [3]u8) void {
    switch (f) {
        .chunk_id, .intern => |w| l.groupPinned(col_byte, flen, color, "0x{x}", .{readWidth(w, code, off)}),
        .jump => l.groupPinned(col_byte, flen, color, "+{d}", .{readU32(code, off)}),
        .cap1 => l.groupPinned(col_byte, flen, color, "#{d}", .{readU16(code, off + 1)}),
        .const_idx => l.groupPinned(col_byte, flen, color, "#{d}", .{readU16(code, off)}),
        .slot => |s| l.groupPinned(col_byte, flen, color, "#{d}", .{readWidth(s.w, code, off)}),
        .count => |c| l.groupPinned(col_byte, flen, color, "#{d}", .{readWidth(c.w, code, off)}),
        .deferred_id => |w| l.groupPinned(col_byte, flen, color, "#{d}", .{readWidth(w, code, off)}),
        else => {},
    }
}

fn headInterp(l: *Line, f: Operand, chunk: *const Chunk, code: []const u8, off: usize, color: [3]u8, symbols: Symbols, up_names: ?[]const InternId, local_names: ?[]const InternId) void {
    switch (f) {
        .const_idx => {
            const idx = readU16(code, off);
            if (idx < chunk.constants.len) lineValueDigest(l, chunk.constants[idx], symbols, snippet_max);
        },
        .slot => |s| {
            const v = readWidth(s.w, code, off);
            const role = if (s.role == .upvalue) "upvalue" else "local";
            l.glue("{s}[", .{role});
            l.tint(color, "{d}", .{v});
            l.glue("]", .{});
            const nm = if (s.role == .upvalue) upvalueName(up_names, symbols, v) else localName(local_names, symbols, v);
            if (nm) |name| l.tint(name_color, " {s}", .{name});
        },
        .cap1 => {
            const kind = code[off];
            const idx = readU16(code, off + 1);
            l.glue("{s}[", .{if (kind == 0) "local" else "upvalue"});
            l.tint(color, "{d}", .{idx});
            l.glue("]", .{});
        },
        .chunk_id => |w| {
            const id: ChunkId = readWidth(w, code, off);
            l.storeRef("chunk", color, "0x{x}", .{id});
            if (chunkNameOf(symbols, id)) |nm| l.tint(name_color, " {s}", .{nm});
        },
        .intern => |w| {
            const id: InternId = readWidth(w, code, off);
            lineInternValue(l, "string", id, symbols, snippet_max);
        },
        .count => |c| {
            l.tint(color, "{d}", .{readWidth(c.w, code, off)});
            l.glue(" {s}", .{c.noun});
        },
        .jump => {
            const target = off + 4 + readU32(code, off);
            l.glue("→ ", .{});
            l.tint(color, "{x:0>4}", .{target});
        },
        else => {},
    }
}

/// Render a multiline op's mnemonic row: byte column (opcode + head bytes,
/// colored to match) then the mnemonic and the inline head operand. `head` is
/// from `buildHead`; `head_len` its operand byte count.
fn emitMnemonicHead(writer: *std.Io.Writer, code: []const u8, start: usize, op: OpCode, head: *Line, head_len: u16, seq: *usize, bg: ?[3]u8, env: Env) !void {
    head.sealTruncation();
    head.paint(seq, env.color_depth);
    if (env.show_bytes) {
        var c: u16 = 0;
        while (c < bytes_per_line) : (c += 1) {
            if (c == 0) {
                try writeByteCellColored(writer, code[start], byteRgb(code[start]), bg, env.color_depth);
            } else if (c <= head_len) {
                try writeByteCellColored(writer, code[start + c], head.colorAt(c), bg, env.color_depth);
            } else {
                try writer.writeAll("   ");
            }
        }
    }
    try writer.writeByte(' '); // gap between bytes and the mnemonic
    try writeMnemonic(writer, op, bg, env.color_depth);
    // Width from the mnemonic's first character, for the shared comment column.
    var w: u16 = @intCast(@tagName(op).len + 1);
    for (head.toks[0..head.n], 0..) |t, i| {
        if (head.comment_tok != null and i == head.comment_tok.? and w < mnem_comment_col) {
            try sgrReset(writer, bg, env.color_depth);
            try writer.splatByteAll(' ', mnem_comment_col - w);
            w = mnem_comment_col;
        }
        if (env.color_depth.enabled()) {
            if (t.colored) {
                try setFg(writer, t.color, env.color_depth);
            } else {
                try sgrReset(writer, bg, env.color_depth);
                try setFg(writer, comment_color, env.color_depth);
            }
        }
        try writer.writeAll(t.text);
        w += visibleWidth(t.text);
    }
    try endRow(writer, bg, env.prefixWidth() + w, env);
    // Heads longer than the byte column (attr paths etc.) wrap their remaining
    // bytes onto continuation rows — same stripe unit as the instruction.
    if (env.show_bytes and head_len + 1 > bytes_per_line) {
        var o: usize = bytes_per_line;
        while (o < head_len + 1) : (o += bytes_per_line) {
            try beginRow(writer, bg, env.color_depth);
            try writeGuide(writer, env.cc, bg, env.color_depth);
            try writer.writeAll("        ");
            var c: usize = o;
            var cnt: u16 = 0;
            while (c < o + bytes_per_line and c < head_len + 1) : (c += 1) {
                try writeByteCellColored(writer, code[start + c], head.colorAt(@intCast(c)), bg, env.color_depth);
                cnt += 1;
            }
            try endRow(writer, bg, 10 + 3 * cnt, env);
        }
    }
}

/// A `#{count} ; {label}` line (count is a u16 at `off`). Fits one row — never
/// wraps — so its guides never blank on a continuation.
fn emitCountLine(writer: *std.Io.Writer, code: []const u8, off: *usize, label: []const u8, seq: *usize, guides: []const [3]u8, last_mask: u8, stripe: *usize, env: Env) !void {
    var l: Line = undefined;
    l.reset();
    l.group(0, 2, "#{d}", .{readU16(code, off.*)});
    l.comment();
    l.glue("{s}", .{label});
    try emitLine(writer, code, off, &l, seq, guides, last_mask, takeBg(stripe, env.color_depth), env);
}

/// The `n` inline capture descriptors (3 bytes each: kind byte + u16 index),
/// each a child line under `guides`, tinting `local`/`upvalue` with the kind
/// byte and the index with its bytes. Each descriptor fits one row. A kind ==
/// upvalue descriptor reads from the ENCLOSING chunk's upvalues, so its
/// best-effort name (when recorded) becomes the row's comment. `end_mask` is
/// the `last_mask` applied to the list's final row (which guide runs it closes).
fn emitCaptureDescriptors(writer: *std.Io.Writer, code: []const u8, off: *usize, n: u16, seq: *usize, guides: []const [3]u8, end_mask: u8, up_names: ?[]const InternId, symbols: Symbols, stripe: *usize, env: Env) !void {
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const is_upvalue = code[off.*] != 0;
        const idx = readU16(code, off.* + 1);
        var l: Line = undefined;
        l.reset();
        l.group(0, 1, "{s}", .{if (is_upvalue) "upvalue" else "local"});
        l.glue("[", .{});
        // An upvalue index reads the enclosing chunk's slot — give it that
        // slot's identity color (matching the upvalues table and up_get ops).
        if (is_upvalue) l.groupPinned(1, 2, upvColor(idx), "{d}", .{idx}) else l.group(1, 2, "{d}", .{idx});
        l.glue("]", .{});
        if (is_upvalue) {
            if (upvalueName(up_names, symbols, idx)) |nm| {
                l.comment();
                l.tint(name_color, "{s}", .{nm});
            }
        }
        const mask: u8 = if (k == n - 1) end_mask else 0;
        try emitLine(writer, code, off, &l, seq, guides, mask, takeBg(stripe, env.color_depth), env);
    }
}

/// Resolve upvalue slot `idx`'s best-effort binding name, if recorded.
/// Compiler-internal names carry a leading NUL (e.g. the attrset-pattern
/// argument holder `\x00args`) — strip it so no NUL reaches the output.
fn upvalueName(up_names: ?[]const InternId, symbols: Symbols, idx: usize) ?[]const u8 {
    const list = up_names orelse return null;
    if (idx >= list.len) return null;
    const name = symbols.internName(list[idx]) orelse return null;
    return if (name.len > 0 and name[0] == 0) name[1..] else name;
}

/// The source name of local `slot` (from the chunk's `local_names` sidecar),
/// or null. Internal (`\x00`-prefixed) names are hidden.
fn localName(local_names: ?[]const InternId, symbols: Symbols, slot: usize) ?[]const u8 {
    const list = local_names orelse return null;
    if (slot >= list.len) return null;
    const name = symbols.internName(list[slot]) orelse return null;
    if (name.len == 0 or name[0] == 0) return null;
    return name;
}

/// Render an instruction's operands as one line per field. `ip` is the byte
/// offset just past the opcode; `end_ip` is the authoritative instruction end
/// (from `writeOperands`), and `operand_text` its compact decode — used both as
/// the fallback comment for opcodes without a bespoke breakdown and as a guard:
/// any bytes a bespoke arm fails to consume are dumped as a trailing field so a
/// miscount can never bleed into the next instruction.
fn writeOperandTail(
    writer: *std.Io.Writer,
    chunk: *const Chunk,
    op: OpCode,
    ip: usize,
    end_ip: usize,
    operand_text: []const u8,
    seq: *usize,
    symbols: Symbols,
    up_names: ?[]const InternId,
    local_names: ?[]const InternId,
    stripe: *usize,
    env: Env,
) !void {
    const code = chunk.code;
    var off = ip;
    // Guide colors: level 0 is the mnemonic (byteRgb of the opcode); list
    // members hang a level deeper under a count line whose color is g[1].
    var g: [3][3]u8 = undefined;
    g[0] = byteRgb(@intFromEnum(op));
    switch (op) {
        .closure, .closure_w => {
            // The chunk id rode the mnemonic line; only the upvalue count
            // remains — the block's only (and thus last) row.
            try emitCountLine(writer, code, &off, "upvalues (from stack)", seq, g[0..1], 0b01, stripe, env);
        },
        .thunk, .thunk_w, .thunk_arg, .closure_cap, .closure_cap_w => {
            const n = readU16(code, off);
            g[1] = hueColor(seq.*); // the "captures" count line's color
            try emitCountLine(writer, code, &off, "captures", seq, g[0..1], if (n == 0) 0b01 else 0, stripe, env);
            // The last descriptor closes both the list (level 1) and the block.
            try emitCaptureDescriptors(writer, code, &off, n, seq, g[0..2], 0b11, up_names, symbols, stripe, env);
        },
        .thunk_st, .thunk_st_cell, .thunk_w_st, .thunk_w_st_cell => {
            const n = readU16(code, off);
            g[1] = hueColor(seq.*);
            try emitCountLine(writer, code, &off, "captures", seq, g[0..1], 0, stripe, env);
            // The list (level 1) closes at the last descriptor; the block
            // (level 0) continues to the store-target row below.
            try emitCaptureDescriptors(writer, code, &off, n, seq, g[0..2], 0b10, up_names, symbols, stripe, env);
            // The trailing slot byte: raw accessor in the value zone, the
            // store-target interpretation (same color) as its comment.
            const c_slot = hueColor(seq.*);
            seq.* += 1;
            var l: Line = undefined;
            l.reset();
            l.groupPinned(0, 1, c_slot, "#{d}", .{code[off]});
            l.comment();
            l.glue("→ local[", .{});
            l.tint(c_slot, "{d}", .{code[off]});
            l.glue("]", .{});
            if (localName(local_names, symbols, code[off])) |nm| l.tint(name_color, " {s}", .{nm});
            try emitLine(writer, code, &off, &l, seq, g[0..1], 0b01, takeBg(stripe, env.color_depth), env);
        },
        .attrs_new_named_srt, .attrs_new_named_pos_srt => {
            // Head took the count; remaining operands are the names start
            // (u32) and, for the pos variant, pos_count:u16 + pos_start:u32.
            const count = readU16(code, off - 2);
            const names_start = readU32(code, off);
            const has_pos = op == .attrs_new_named_pos_srt;
            // The resolved names/positions live in the chunk `attr names:` /
            // `attr positions:` sections; the op carries only the reference into
            // them. Tint the reference to its start row's identity color so it
            // links back to the section (like a constant's `#N`).
            {
                const c = attrNameColor(names_start);
                var l: Line = undefined;
                l.reset();
                l.groupPinned(0, 4, c, "#{d}", .{names_start});
                l.comment();
                l.glue("names[", .{});
                l.tint(c, "{d}..{d}", .{ names_start, names_start + count });
                l.glue("]", .{});
                try emitLine(writer, code, &off, &l, seq, g[0..1], if (has_pos) 0 else 0b01, takeBg(stripe, env.color_depth), env);
            }
            if (has_pos) {
                const pos_count = readU16(code, off);
                const pos_start = readU32(code, off + 2);
                const c = attrPosColor(pos_start);
                var l: Line = undefined;
                l.reset();
                l.group(0, 2, "#{d}", .{pos_count});
                l.glue(" ", .{});
                l.groupPinned(2, 4, c, "#{d}", .{pos_start});
                l.comment();
                l.glue("positions[", .{});
                l.tint(c, "{d}..{d}", .{ pos_start, pos_start + pos_count });
                l.glue("]", .{});
                try emitLine(writer, code, &off, &l, seq, g[0..1], 0b01, takeBg(stripe, env.color_depth), env);
            }
        },
        .thunk_defer => {
            const n = readU16(code, off);
            g[1] = hueColor(seq.*);
            try emitCountLine(writer, code, &off, "env", seq, g[0..1], if (n == 0) 0b01 else 0, stripe, env);
            try emitCaptureDescriptors(writer, code, &off, n, seq, g[0..2], 0b11, up_names, symbols, stripe, env);
        },
        .attr_bind, .attr_bind_w => {
            // The header rode the mnemonic line; each child is one sorted
            // (formal name, destination slot) pair. 0xffff marks an optional
            // formal filled by its default path after this instruction.
            const wide = op == .attr_bind_w;
            const id_len: u16 = if (wide) 4 else 2;
            const expected = readU16(code, off - 2);
            var k: usize = 0;
            while (k < expected) : (k += 1) {
                const id: InternId = if (wide) readU32(code, off) else @intCast(readU16(code, off));
                const slot = readU16(code, off + id_len);
                const c = internColor(id);
                var esc: [128]u8 = undefined;
                var ew: std.Io.Writer = .fixed(&esc);
                if (symbols.internName(id)) |s| writeEscapedSnippet(&ew, s, 24) catch {};
                var l: Line = undefined;
                l.reset();
                l.groupPinned(0, id_len, c, "0x{x}", .{id});
                l.glue(" ", .{});
                l.group(id_len, 2, "#{d}", .{slot});
                l.comment();
                l.storeRef("intern", c, "0x{x}", .{id});
                if (ew.end > 0) {
                    l.glue(" → ", .{});
                    l.tint(c, "\"{s}\"", .{esc[0..ew.end]});
                }
                if (slot == std.math.maxInt(u16)) {
                    l.glue(" → optional", .{});
                } else {
                    l.glue(" → local[{d}]", .{slot});
                }
                try emitLine(writer, code, &off, &l, seq, g[0..1], if (k == expected - 1) 0b01 else 0, takeBg(stripe, env.color_depth), env);
            }
        },
        else => {
            // No bespoke breakdown: dump the whole tail as one group.
            if (end_ip > off) {
                var l: Line = undefined;
                l.reset();
                l.group(0, @intCast(end_ip - off), "{s}", .{operand_text});
                try emitLine(writer, code, &off, &l, seq, g[0..1], 0b01, takeBg(stripe, env.color_depth), env);
            }
        },
    }
    // Guard: dump any bytes a bespoke arm under-counted as a trailing field.
    if (off < end_ip) {
        var l: Line = undefined;
        l.reset();
        l.group(0, @intCast(end_ip - off), "{s}", .{"…"});
        try emitLine(writer, code, &off, &l, seq, g[0..1], 0b01, takeBg(stripe, env.color_depth), env);
    }
}

/// Instructions with a list of sub-fields (captures / positions) are drawn
/// across multiple indented rows; everything else fits on one line.
fn isMultiline(op: OpCode) bool {
    return switch (op) {
        .closure,
        .closure_w,
        .thunk,
        .thunk_w,
        .thunk_arg,
        .closure_cap,
        .closure_cap_w,
        .thunk_st,
        .thunk_st_cell,
        .thunk_w_st,
        .thunk_w_st_cell,
        .attrs_new_named_srt,
        .attrs_new_named_pos_srt,
        // .thunk_defer is now single-line: its captures are interned in the
        // chunk side table, no inline descriptor child rows.
        .attr_bind,
        .attr_bind_w,
        => true,
        else => false,
    };
}

fn writeChunkHeader(writer: *std.Io.Writer, chunk_id: ?ChunkId, chunk: *const Chunk, symbols: Symbols, cc: [3]u8, has_upvalue_table: bool, color_depth: ColorDepth) !void {
    if (chunk_id) |id| {
        // Same `store[accessor]` coloring as every reference to this chunk —
        // keyword, dim brackets, id in the chunk's identity color (bold: this
        // is the definition the references point at).
        try terminal_color.foreground(writer, color_depth, store_kw_color, true);
        try writer.writeAll("chunk");
        if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
        try setCommentFg(writer, color_depth);
        try writer.writeByte('[');
        if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
        try terminal_color.foreground(writer, color_depth, cc, true);
        try writer.print("0x{x}", .{id});
        if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
        try setCommentFg(writer, color_depth);
        try writer.writeByte(']');
        if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    } else {
        try terminal_color.foreground(writer, color_depth, store_kw_color, true);
        try writer.writeAll("chunk");
        if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    }
    // Best-effort compiler-attributed name (the binding a lambda/thunk was
    // compiled for), when name capture was on. See ChunkRegistry.recordName.
    if (chunk_id) |id| {
        if (chunkNameOf(symbols, id)) |name| {
            try terminal_color.foreground(writer, color_depth, name_color, true);
            try writer.print(" {s}", .{name});
            if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
        }
    }
    try writer.print(" ({d} bytes, {d} consts, {d} locals", .{
        chunk.code.len,
        chunk.constants.len,
        chunk.local_count,
    });
    if (chunk.source_map.len > 0) {
        try writer.print(", {d} source spans", .{chunk.source_map.len});
    }
    if (chunk.arity != 1) {
        try writer.print(", arity {d}", .{chunk.arity});
    }
    try writer.writeAll(")\n");
    // Strictness flags fold into the upvalues table when one renders; these
    // lines are the fallback for chunks with no recorded upvalue names.
    if (has_upvalue_table) return;
    if (chunk.scheduling.strictness.forced_upvalues != 0) {
        try writeGuide(writer, cc, null, color_depth);
        try writer.writeAll("  strict upvalues:");
        var mask = chunk.scheduling.strictness.forced_upvalues;
        while (mask != 0) {
            const slot = @ctz(mask);
            try writer.print(" {d}", .{slot});
            mask &= mask - 1;
        }
        try writer.writeByte('\n');
    }
    const deep_extra = chunk.scheduling.strictness.deep_upvalues & ~chunk.scheduling.strictness.forced_upvalues;
    if (deep_extra != 0) {
        try writeGuide(writer, cc, null, color_depth);
        try writer.writeAll("  deep upvalues:");
        var mask = deep_extra;
        while (mask != 0) {
            const slot = @ctz(mask);
            try writer.print(" {d}", .{slot});
            mask &= mask - 1;
        }
        try writer.writeByte('\n');
    }
}

/// A `references:` sub-section (`incoming`/`outgoing`): one `chunk[0xN] name`
/// per referenced chunk, each in that chunk's identity color. No-op when empty.
fn writeRefList(writer: *std.Io.Writer, label: []const u8, sub_color: [3]u8, ids: []const ChunkId, outer_last: bool, symbols: Symbols, cc: [3]u8, color_depth: ColorDepth) !void {
    if (ids.len == 0) return;
    // Sub-section header under the references gutter, then one row per chunk
    // under the sub-section's own gutter; each vertical run stays `│`.
    try writeGuide(writer, cc, null, color_depth);
    try writer.writeAll("  ");
    try writeTreeGuide(writer, sec_references_color, .vert, null, color_depth);
    try writer.print("{s}:\n", .{label});
    for (ids, 0..) |id, i| {
        const sub_last = i == ids.len - 1;
        try writeGuide(writer, cc, null, color_depth);
        try writer.writeAll("  ");
        try writeTreeGuide(writer, sec_references_color, if (outer_last and sub_last) .corner else .vert, null, color_depth);
        try writeTreeGuide(writer, sub_color, if (sub_last) .corner else .vert, null, color_depth);
        try writeStoreRefText(writer, "chunk", id, objColor(id), color_depth);
        if (chunkNameOf(symbols, id)) |name| {
            try setFg(writer, name_color, color_depth);
            try writer.print(" {s}", .{name});
            if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
        }
        try writer.writeByte('\n');
    }
}

/// The best-effort name attributed to chunk `id`, resolved to text.
/// The chunk's qualified name, rendered from the always-on name tree into a
/// scratch buffer. Disasm is single-threaded (name capture forces `--eval`
/// single-worker), and callers use the slice immediately, so the shared buffer
/// is safe.
var chunk_name_buf: [1024]u8 = undefined;
fn chunkNameOf(symbols: Symbols, id: ChunkId) ?[]const u8 {
    const reg = symbols.registry orelse return null;
    // The two registry-synthesized apply trampolines register before any
    // compiler names them — name them statically.
    if (id == reg.well_known.genlist_apply) return "builtin·genlist_apply";
    if (id == reg.well_known.mapattrs_apply) return "builtin·mapattrs_apply";
    const intern = symbols.intern orelse return null;
    if (!reg.hasQualifiedName(id)) return null;
    var w: std.Io.Writer = .fixed(&chunk_name_buf);
    reg.writeQualifiedName(&w, id, intern) catch return null;
    return chunk_name_buf[0..w.end];
}

/// `chunk[0x{id}]` followed by its best-effort name when known, so a reference
/// reads `chunk[0x62] fetchGit` rather than a bare id.
fn writeChunkRef(writer: *std.Io.Writer, id: ChunkId, symbols: Symbols) !void {
    try writer.print("chunk[0x{x}]", .{id});
    if (chunkNameOf(symbols, id)) |name| try writer.print(" {s}", .{name});
}

/// A place to record the chunk ids an instruction references, bundled with the
/// allocator that owns the map — so `writeOperands` never reaches for a global
/// allocator to grow a caller's container. `null` means "don't collect refs".
const RefSink = struct {
    map: *std.AutoArrayHashMapUnmanaged(ChunkId, void),
    allocator: std.mem.Allocator,
};

fn addRef(sink: ?RefSink, id: ChunkId) !void {
    if (sink) |s| try s.map.put(s.allocator, id, {});
}

fn writeOperands(
    writer: *std.Io.Writer,
    chunk: *const Chunk,
    op: OpCode,
    ip_in: usize,
    symbols: Symbols,
    up_names: ?[]const InternId,
    referenced_chunks: ?RefSink,
) !usize {
    // Uniform, table-driven operand rendering. Two passes over the op's operand
    // layout (`opcode.layout`): pass 1 prints raw operand tokens, pass 2 their
    // interpretation, joined as "raw ; interp" (the form the multiline view
    // splits on). Per-field renderers share the same layout table.
    const code = chunk.code;
    const fields = opcode_mod.layout(op);

    var ip = ip_in;
    var wrote_raw = false;
    for (fields) |f| {
        if (fieldHasRaw(f)) {
            if (wrote_raw) try writer.writeByte(' ');
            try writeFieldRaw(writer, f, code, ip);
            wrote_raw = true;
        }
        ip += opcode_mod.fieldLen(f, code, ip);
    }

    var wrote_int = false;
    ip = ip_in;
    for (fields) |f| {
        if (fieldHasInterp(f)) {
            try writer.writeAll(if (wrote_int) ", " else if (wrote_raw) " ; " else "");
            try writeFieldInterp(writer, f, chunk, code, ip, symbols, up_names, referenced_chunks);
            wrote_int = true;
        }
        ip += opcode_mod.fieldLen(f, code, ip);
    }

    std.debug.assert(ip == ip_in + opcode_mod.operandLen(op, code, ip_in));
    return ip;
}

const Operand = opcode_mod.Operand;

fn readWidth(w: opcode_mod.Width, code: []const u8, ip: usize) u32 {
    return switch (w) {
        .b1 => code[ip],
        .b2 => readU16(code, ip),
        .b4 => readU32(code, ip),
    };
}

/// Every field but `.skip` (an internal side-table offset) shows a raw token.
fn fieldHasRaw(f: Operand) bool {
    return switch (f) {
        .skip => false,
        else => true,
    };
}

/// Every field but `.skip` has an interpretation.
fn fieldHasInterp(f: Operand) bool {
    return switch (f) {
        .skip => false,
        else => true,
    };
}

fn writeFieldRaw(writer: *std.Io.Writer, f: Operand, code: []const u8, ip: usize) !void {
    switch (f) {
        .deferred_id, .skip => |w| try writer.print("#{d}", .{readWidth(w, code, ip)}),
        .const_idx => try writer.print("#{d}", .{readU16(code, ip)}),
        .slot => |s| try writer.print("#{d}", .{readWidth(s.w, code, ip)}),
        .cap1 => try writer.print("#{d}", .{readU16(code, ip + 1)}),
        .chunk_id => |w| try writer.print("0x{x}", .{readWidth(w, code, ip)}),
        .intern => |w| try writer.print("#{d}", .{readWidth(w, code, ip)}),
        .count => |c| try writer.print("#{d}", .{readWidth(c.w, code, ip)}),
        .jump => try writer.print("+{d}", .{readU32(code, ip)}),
        .captures, .captures_slot => try writer.print("#{d}", .{readU16(code, ip)}),
        .attr_path => try writer.print("#{d}", .{code[ip]}),
        .bind => try writer.print("#{d}", .{readU16(code, ip + 2)}),
        .mix => try writer.print("#{d} #{d}", .{ code[ip], code[ip + 1] }),
    }
}

fn writeFieldInterp(
    writer: *std.Io.Writer,
    f: Operand,
    chunk: *const Chunk,
    code: []const u8,
    ip: usize,
    symbols: Symbols,
    up_names: ?[]const InternId,
    referenced_chunks: ?RefSink,
) !void {
    switch (f) {
        .skip => {},
        .deferred_id => |w| try writer.print("deferred[{d}]", .{readWidth(w, code, ip)}),
        .const_idx => {
            const idx = readU16(code, ip);
            if (idx < chunk.constants.len)
                try writeValueDigest(writer, chunk.constants[idx], symbols, snippet_max, .none)
            else
                try writer.print("const #{d}", .{idx});
        },
        .slot => |s| {
            const v = readWidth(s.w, code, ip);
            try writer.print("{s}[{d}]", .{ @tagName(s.role), v });
            if (s.role == .upvalue) {
                if (upvalueName(up_names, symbols, v)) |nm| try writer.print(" {s}", .{nm});
            }
        },
        .cap1 => {
            const kind = code[ip];
            const idx = readU16(code, ip + 1);
            try writer.print("{s}[{d}]", .{ if (kind == 0) "local" else "upvalue", idx });
        },
        .chunk_id => |w| {
            const id: ChunkId = readWidth(w, code, ip);
            try writeChunkRef(writer, id, symbols);
            try addRef(referenced_chunks, id);
        },
        .intern => |w| {
            const id: InternId = readWidth(w, code, ip);
            try writeInternRef(writer, id, symbols);
        },
        .count => |c| try writer.print("{d} {s}", .{ readWidth(c.w, code, ip), c.noun }),
        .jump => {
            const off = readU32(code, ip);
            try writer.print("→ {x:0>4}", .{ip + 4 + off});
        },
        .captures => try writer.print("{d} captures", .{readU16(code, ip)}),
        .captures_slot => {
            const n = readU16(code, ip);
            const slot_b = code[ip + 2 + @as(usize, n) * 3];
            try writer.print("{d} captures → local[{d}]", .{ n, slot_b });
        },
        .attr_path => |w| {
            const segments = code[ip];
            try writeAttrPath(writer, code, ip + 1, segments, w == .b4, symbols);
        },
        .bind => {
            const allow = code[ip];
            const cells = code[ip + 1];
            const expected = readU16(code, ip + 2);
            try writer.print("{d} formals (allow_extra={s}, {s})", .{
                expected,
                if (allow != 0) "true" else "false",
                if (cells != 0) "cells" else "locals",
            });
        },
        .mix => try writer.print("{d} segments ({d} dynamic)", .{ code[ip], code[ip + 1] }),
    }
}

fn writeAttrPath(
    writer: *std.Io.Writer,
    code: []const u8,
    start: usize,
    segments: u8,
    wide: bool,
    symbols: Symbols,
) !void {
    try writer.writeByte('"');
    var ip = start;
    for (0..segments) |i| {
        if (i > 0) try writer.writeByte('.');
        const id: InternId = if (wide) blk: {
            const v = readU32(code, ip);
            ip += 4;
            break :blk v;
        } else blk: {
            const v: InternId = @intCast(readU16(code, ip));
            ip += 2;
            break :blk v;
        };
        if (symbols.internName(id)) |name| {
            try writer.writeAll(name);
        } else {
            try writer.print("0x{x}", .{id});
        }
    }
    try writer.writeByte('"');
}

/// A fused slot-plus-attribute operand (`loc_get_attr`/`up_get_attr`): the two
/// raw values (slot index, name id) as the value, with `role[slot]."name"` as
/// the dimmed interpretation.
fn writeSlotAttr(writer: *std.Io.Writer, role: []const u8, slot: u16, id: InternId, symbols: Symbols) !void {
    if (symbols.internName(id)) |name| {
        try writer.print("#{d} 0x{x} ; {s}[{d}].\"{s}\"", .{ slot, id, role, slot, name });
    } else {
        try writer.print("#{d} 0x{x} ; {s}[{d}]", .{ slot, id, role, slot });
    }
}

/// An interned-name operand: the raw id as the value, then the full lookup
/// chain — `intern[0xN] → "text"` — as the interpretation, so the intern id is
/// explicit in the comment and matches the constant-pool rendering.
fn writeInternRef(writer: *std.Io.Writer, id: InternId, symbols: Symbols) !void {
    if (symbols.internName(id)) |name| {
        try writer.print("0x{x} ; intern[0x{x}] → \"", .{ id, id });
        try writeEscapedSnippet(writer, name, snippet_max);
        try writer.writeByte('"');
    } else {
        try writer.print("0x{x} ; intern[0x{x}]", .{ id, id });
    }
}

/// A standalone `; <filename>` comment line marking that subsequent instructions
/// come from this file (emitted only when the file changes).
fn writeFileLine(writer: *std.Io.Writer, file: InternId, symbols: Symbols, color_depth: ColorDepth) !void {
    try setCommentFg(writer, color_depth);
    try writer.writeAll("  ; ");
    if (symbols.internName(file)) |name| {
        try writer.writeAll(name);
    } else {
        try writer.print("file 0x{x}", .{file});
    }
    if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    try writer.writeByte('\n');
}

/// The right-hand `; line:col+len` position annotation — the position within the
/// current file (whose name is on its own hoisted line).
/// A `store[accessor]` reference written directly (outside the `Line` token
/// model): keyword in the store color, brackets comment-grey, accessor in `id_color`.
pub fn writeStoreRefText(writer: *std.Io.Writer, kw: []const u8, id: u64, id_color: [3]u8, color_depth: ColorDepth) !void {
    try setFg(writer, store_kw_color, color_depth);
    try writer.writeAll(kw);
    if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    try setCommentFg(writer, color_depth);
    try writer.writeByte('[');
    if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    try setFg(writer, id_color, color_depth);
    try writer.print("0x{x}", .{id});
    if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    try setCommentFg(writer, color_depth);
    try writer.writeByte(']');
    if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
}

/// Canonical `store[0xid] → preview` rendering shared by disassembly and the
/// VM explorer. The store keyword has one fixed color; the accessor and its
/// short preview share the referenced record's identity color.
pub fn writeStoreRef(
    writer: *std.Io.Writer,
    store: []const u8,
    id: u64,
    identity: Identity,
    preview: ?[]const u8,
    color_depth: ColorDepth,
) !void {
    const id_color = identityColor(identity, id);
    try writeStoreRefText(writer, store, id, id_color, color_depth);
    if (preview) |text| {
        try setCommentFg(writer, color_depth);
        try writer.writeAll(" → ");
        if (color_depth.enabled()) try setFg(writer, id_color, color_depth);
        try writer.writeAll(text);
        if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    }
}

/// Canonical half-open store range with an explicit live-record count.
pub fn writeStoreRange(
    writer: *std.Io.Writer,
    store: []const u8,
    start: u64,
    end: u64,
    live: u64,
    identity: Identity,
    color_depth: ColorDepth,
) !void {
    const range_color = identityColor(identity, start);
    try setFg(writer, store_kw_color, color_depth);
    try writer.writeAll(store);
    if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    try setCommentFg(writer, color_depth);
    try writer.writeByte('[');
    if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    try setFg(writer, range_color, color_depth);
    try writer.print("0x{x}:0x{x}", .{ start, end });
    if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    try setCommentFg(writer, color_depth);
    try writer.print("] ({d})", .{live});
    if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
}

/// A compact `location → type → description` value. Store-backed values lead
/// with their canonical address (`objects`, `chunk`, `intern`, or `builtin`);
/// inline scalars begin with their type. `max` caps resolved string contents.
pub fn writeValueDigest(writer: *std.Io.Writer, value: Value, symbols: Symbols, max: usize, color_depth: ColorDepth) !void {
    switch (value.kind()) {
        .null => try writer.writeAll("null"),
        .bool_true => try writer.writeAll("bool true"),
        .bool_false => try writer.writeAll("bool false"),
        .int => try writer.print("int {d}", .{value.asInt()}),
        .float => {
            var buf: [64]u8 = undefined;
            try writer.print("float {s}", .{shortFloat(&buf, value.asFloat())});
        },
        .string => try writeInternValue(writer, "string", value.asInternId(), symbols, max, color_depth),
        .path => try writeInternValue(writer, "path", value.asInternId(), symbols, max, color_depth),
        .list => try writeStoreRef(writer, "objects", value.asObjectId(), .object, "list", color_depth),
        .attrs => try writeStoreRef(writer, "objects", value.asObjectId(), .object, "attrs", color_depth),
        .closure => if (value.isFunction())
            try writeStoreRef(writer, "chunk", value.asFunctionChunkId(), .chunk, "function", color_depth)
        else
            try writeStoreRef(writer, "objects", value.asObjectId(), .object, "closure", color_depth),
        .thunk => try writeStoreRef(writer, "objects", value.asObjectId(), .object, "thunk", color_depth),
        .builtin => {
            const bid = value.asBuiltinId();
            try writeStoreRef(writer, "builtin", bid, .builtin, builtinName(bid), color_depth);
        },
        .builtin_closure => try writeStoreRef(writer, "objects", value.asObjectId(), .object, "builtin closure", color_depth),
        .string_context => try writeStoreRef(writer, "objects", value.asObjectId(), .object, "context string", color_depth),
        .heap_string => try writeStoreRef(writer, "objects", value.asObjectId(), .object, "heap string", color_depth),
        .boxed_int => try writeStoreRef(writer, "objects", value.asObjectId(), .object, "boxed int", color_depth),
        .partial_app => try writeStoreRef(writer, "objects", value.asObjectId(), .object, "partial application", color_depth),
    }
}

fn writeInternValue(writer: *std.Io.Writer, kind: []const u8, id: InternId, symbols: Symbols, max: usize, color_depth: ColorDepth) !void {
    try writeStoreRef(writer, "intern", id, .intern, null, color_depth);
    try setCommentFg(writer, color_depth);
    try writer.writeAll(" → ");
    if (color_depth.enabled()) try setFg(writer, internColor(id), color_depth);
    try writer.writeAll(kind);
    if (symbols.internName(id)) |text| {
        try writer.writeAll(" \"");
        try writeEscapedSnippet(writer, text, max);
        try writer.writeByte('"');
    }
    if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
}

/// A canonical intern-table reference used for names rather than values.
fn writeInternNameRef(writer: *std.Io.Writer, id: InternId, symbols: Symbols, max: usize, color_depth: ColorDepth) !void {
    try writeStoreRef(writer, "intern", id, .intern, null, color_depth);
    if (symbols.internName(id)) |text| {
        try setCommentFg(writer, color_depth);
        try writer.writeAll(" → ");
        if (color_depth.enabled()) try setFg(writer, internColor(id), color_depth);
        try writer.writeByte('"');
        try writeEscapedSnippet(writer, text, max);
        try writer.writeByte('"');
        if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    }
}

/// Set the foreground to `rgb` (no-op when not coloring).
fn setFg(writer: *std.Io.Writer, rgb: [3]u8, color_depth: ColorDepth) !void {
    try terminal_color.foreground(writer, color_depth, rgb, false);
}

/// One `attr positions:` row body: `"name" @ file:line:col`, the name and the
/// filename each in their intern identity color, structural glue comment-grey.
fn writeAttrPosRow(writer: *std.Io.Writer, rec: @import("runtime").heap.AttrPosEntry, symbols: Symbols, color_depth: ColorDepth) !void {
    if (symbols.internName(rec.name)) |s| {
        try setFg(writer, internColor(rec.name), color_depth);
        try writer.writeByte('"');
        try writeEscapedSnippet(writer, s, table_snippet_max);
        try writer.writeByte('"');
        if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    } else {
        try writeStoreRefText(writer, "str", rec.name, internColor(rec.name), color_depth);
    }
    try setCommentFg(writer, color_depth);
    try writer.writeAll(" @ ");
    try writeAttrPosLocation(writer, rec, symbols, color_depth);
}

fn writeAttrPosLocation(writer: *std.Io.Writer, rec: @import("runtime").heap.AttrPosEntry, symbols: Symbols, color_depth: ColorDepth) !void {
    if (symbols.internName(rec.pos.file)) |f| {
        try setFg(writer, internColor(rec.pos.file), color_depth);
        try writer.writeAll(std.fs.path.basename(f));
        if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
    } else {
        try writeStoreRefText(writer, "file", rec.pos.file, internColor(rec.pos.file), color_depth);
    }
    try setCommentFg(writer, color_depth);
    try writer.print(":{d}:{d}", .{ rec.pos.line, rec.pos.column });
    if (color_depth.enabled()) try writer.writeAll("\x1b[0m");
}

/// The `│  │ #idx` prefix of one `name:` section-table row: chunk gutter, the
/// section's vertical tree guide, then the row index in
/// its identity color padded to the value column. The shared row opener for the
/// attr-name/position tables.
fn writeTableRowHead(writer: *std.Io.Writer, cc: [3]u8, sec_color: [3]u8, idx: usize, last: bool, idx_color: [3]u8, color_depth: ColorDepth) !void {
    try writeGuide(writer, cc, null, color_depth);
    try writer.writeAll("  ");
    try writeTreeGuide(writer, sec_color, if (last) .corner else .vert, null, color_depth);
    var ibuf: [16]u8 = undefined;
    const istr = std.fmt.bufPrint(&ibuf, "#{d}", .{idx}) catch "#?";
    if (color_depth.enabled()) {
        try setFg(writer, idx_color, color_depth);
        try writer.writeAll(istr);
        try writer.writeAll("\x1b[0m");
    } else {
        try writer.writeAll(istr);
    }
    try writer.splatByteAll(' ', 6 -| istr.len);
}

/// Escape a string for display and truncate on terminal cell width. UTF-8 is
/// never split, wide characters consume two cells, and escaped controls count
/// as the two visible characters they become.
fn writeEscapedSnippet(writer: *std.Io.Writer, text: []const u8, max_cells: usize) !void {
    if (escapedCellWidth(text) <= max_cells) {
        try escapeRun(writer, text);
        return;
    }
    if (max_cells == 0) return;
    const keep = max_cells - 1;
    var used: usize = 0;
    var end: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const unit = escapedUnit(text, i);
        if (used + unit.cells > keep) break;
        used += unit.cells;
        i += unit.len;
        end = i;
    }
    try escapeRun(writer, text[0..end]);
    try writer.writeAll("…");
}

const EscapedUnit = struct { len: usize, cells: usize };

fn escapedUnit(text: []const u8, offset: usize) EscapedUnit {
    const byte = text[offset];
    if (byte < 0x80) return .{
        .len = 1,
        .cells = switch (byte) {
            '\\', '"', '\n', '\r', '\t' => 2,
            else => terminal_text.cellWidth(byte),
        },
    };
    const len = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .len = 1, .cells = 1 };
    if (offset + len > text.len) return .{ .len = 1, .cells = 1 };
    const cp = std.unicode.utf8Decode(text[offset .. offset + len]) catch return .{ .len = 1, .cells = 1 };
    return .{ .len = len, .cells = terminal_text.cellWidth(cp) };
}

fn escapedCellWidth(text: []const u8) usize {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const unit = escapedUnit(text, i);
        cells += unit.cells;
        i += unit.len;
    }
    return cells;
}

fn escapeRun(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

fn readU16(code: []const u8, ip: usize) u16 {
    return encoding.readU16(code, ip);
}

fn readU32(code: []const u8, ip: usize) u32 {
    return encoding.readU32(code, ip);
}

const ChunkBuilder = bytecode.ChunkBuilder;

test "disassembling a chunk prints arithmetic opcode names and jump targets" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    // loc_get 0; loc_get 1; int_add; jump +0; ret; halt
    try builder.writeOp(allocator, .loc_get);
    try builder.writeByte(allocator, 0);
    try builder.writeOp(allocator, .loc_get);
    try builder.writeByte(allocator, 1);
    try builder.writeOp(allocator, .int_add);
    try builder.writeOp(allocator, .jump);
    try builder.writeU32(allocator, 0);
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 2);
    defer chunk.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeChunk(allocator, &out.writer, 7, &chunk, .{}, .{});
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "chunk[0x7]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "loc_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "local[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "local[1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "jump") != null);
    // jump operand is a relative +0 offset; disasm annotates the
    // resolved absolute target after the operand.
    try std.testing.expect(std.mem.indexOf(u8, text, "+0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ret") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "halt") != null);
}

test "disassembling prints the constant pool with resolved values" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.emitConstant(allocator, Value.int(42));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeChunk(allocator, &out.writer, null, &chunk, .{}, .{});
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "  constants:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "#0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "push_const") != null);
}

test "disassembling resolves an interned attribute name via Symbols" {
    const allocator = std.testing.allocator;
    var intern = try InternTable.init(allocator);
    defer intern.deinit();
    const name_id = try intern.intern("myAttr");

    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .attr_get);
    try builder.writeU16(allocator, @intCast(name_id));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeChunk(allocator, &out.writer, null, &chunk, .{ .intern = &intern }, .{});
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "attr_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"myAttr\"") != null);
}

test "disassembling omits the constant pool section when show_constants is false" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.emitConstant(allocator, Value.int(1));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeChunk(allocator, &out.writer, null, &chunk, .{}, .{ .show_constants = false });
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "  constants:\n") == null);
}

test "embedded disassembly can omit its redundant outer header" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    try builder.emitConstant(allocator, Value.int(7));
    try builder.writeOp(allocator, .ret);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeChunk(allocator, &out.writer, 0x2a, &chunk, .{}, .{ .show_header = false });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "chunk[0x2a]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "  constants:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "push_const") != null);
}

test "disassembly marks the current instruction" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeChunk(allocator, &out.writer, null, &chunk, .{}, .{
        .show_constants = false,
        .current_offset = 0,
    });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "▶ 0000") != null);
}

test "table-only disassembly omits instructions" {
    const allocator = std.testing.allocator;
    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    try builder.emitConstant(allocator, Value.int(7));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeChunk(allocator, &out.writer, null, &chunk, .{}, .{ .show_code = false });

    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "  constants:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "int 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "push_const") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "halt") == null);
}

test "canonical store references and half-open ranges" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeStoreRef(&out.writer, "values", 2, .value, "int 7", .none);
    try std.testing.expectEqualStrings("values[0x2] → int 7", out.written());

    out.clearRetainingCapacity();
    try writeStoreRange(&out.writer, "objects", 0x100, 0x105, 4, .object, .none);
    try std.testing.expectEqualStrings("objects[0x100:0x105] (4)", out.written());

    out.clearRetainingCapacity();
    try writeEscapedSnippet(&out.writer, "ab中def", 5);
    try std.testing.expectEqualStrings("ab中…", out.written());
}

test "operand lines truncate to an ellipsis instead of failing" {
    var line: Line = undefined;
    line.reset();
    for (0..line.toks.len + 1) |_| line.glue("x", .{});
    line.sealTruncation();
    try std.testing.expectEqual(line.toks.len, line.n);
    try std.testing.expectEqualStrings("…", line.toks[line.n - 1].text);

    // Text overflow: the group's own text is lost but its byte extent is not,
    // so the caller still steps over every byte the instruction owns.
    line.reset();
    line.group(0, 3, "{s}", .{"abc"});
    line.group(3, 4, "{s}", .{[_]u8{'x'} ** (line.buf.len + 1)});
    line.sealTruncation();
    try std.testing.expectEqual(@as(u16, 7), line.total());
    try std.testing.expectEqualStrings("…", line.toks[line.n - 1].text);
}

test "an over-long attribute path disassembles truncated rather than aborting" {
    const allocator = std.testing.allocator;
    var intern = try InternTable.init(allocator);
    defer intern.deinit();

    var builder = try ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);

    // 11 segments: one past what a Line's token budget holds, since each
    // segment costs a name token plus the `.` separating it from the last.
    const segments = 11;
    try builder.writeOp(allocator, .attr_has_path);
    try builder.writeByte(allocator, segments);
    for (0..segments) |i| {
        var name: [2]u8 = .{ 'a' + @as(u8, @intCast(i)), 0 };
        try builder.writeU16(allocator, @intCast(try intern.intern(name[0..1])));
    }
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    var chunk = try builder.finish(allocator, 0);
    defer chunk.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeChunk(allocator, &out.writer, null, &chunk, .{ .intern = &intern }, .{});
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "attr_has_path") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "…") != null);
    // The instructions after the long line still print.
    try std.testing.expect(std.mem.indexOf(u8, text, "ret") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "halt") != null);
}

test "value digests use canonical location-first references" {
    var intern = try InternTable.init(std.testing.allocator);
    defer intern.deinit();
    const text_id = try intern.intern("hello");
    const symbols: Symbols = .{ .intern = &intern };

    const Case = struct {
        value: Value,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .value = Value.boolVal(true), .expected = "bool true" },
        .{ .value = Value.int(7), .expected = "int 7" },
        .{ .value = Value.float(1.0 / 3.0), .expected = "float ~0.333" },
        .{ .value = Value.list(0x12), .expected = "objects[0x12] → list" },
        .{ .value = Value.attrs(0x13), .expected = "objects[0x13] → attrs" },
        .{ .value = Value.function(0xa), .expected = "chunk[0xa] → function" },
        .{ .value = Value.closure(0x14), .expected = "objects[0x14] → closure" },
        .{ .value = Value.thunk(0x15), .expected = "objects[0x15] → thunk" },
        .{ .value = Value.builtin(0x20), .expected = "builtin[0x20] → import" },
        .{ .value = Value.builtinClosure(0x16), .expected = "objects[0x16] → builtin closure" },
        .{ .value = Value.contextString(0x17), .expected = "objects[0x17] → context string" },
        .{ .value = Value.boxedInt(0x18), .expected = "objects[0x18] → boxed int" },
        .{ .value = Value.partialApp(0x19), .expected = "objects[0x19] → partial application" },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    for (cases) |case| {
        out.clearRetainingCapacity();
        try writeValueDigest(&out.writer, case.value, symbols, 40, .none);
        try std.testing.expectEqualStrings(case.expected, out.written());
    }

    out.clearRetainingCapacity();
    try writeValueDigest(&out.writer, Value.string(text_id), symbols, 40, .none);
    var expected: [128]u8 = undefined;
    const expected_text = try std.fmt.bufPrint(&expected, "intern[0x{x}] → string \"hello\"", .{text_id});
    try std.testing.expectEqualStrings(expected_text, out.written());
}

test "constant comments use the same location-first value grammar" {
    var builder = try ChunkBuilder.init(std.testing.allocator);
    defer builder.deinit(std.testing.allocator);

    try builder.emitConstant(std.testing.allocator, Value.list(0x12));
    try builder.emitConstant(std.testing.allocator, Value.function(0xa));
    try builder.writeOp(std.testing.allocator, .ret);
    try builder.writeOp(std.testing.allocator, .halt);

    var chunk = try builder.finish(std.testing.allocator, 0);
    defer chunk.deinit(std.testing.allocator);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeChunk(std.testing.allocator, &out.writer, null, &chunk, .{}, .{});

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "objects[0x12] → list") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "chunk[0xa] → function") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "list[0x12]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "function[0xa]") == null);
}
