const std = @import("std");
const runtime = @import("runtime");
const types = runtime.types;
const Value = runtime.Value;
const ast = @import("syntax").ast;

const encoding = @import("../../encoding.zig");
const OpCode = @import("../../opcode.zig").OpCode;
const common = @import("wire.zig");
const key = @import("key.zig");
const encoder = @import("encoder.zig");
const decoder = @import("decoder.zig");

const Reader = common.Reader;
const Error = common.Error;
const checksum_start = common.checksum_start;
const checksum_end = common.checksum_end;
const checksum_seed = common.checksum_seed;
const KeyContext = key.KeyContext;
const computeKey = key.computeKey;
const serialize = encoder.serialize;
const load = decoder.load;

const testing = std.testing;
const Engine = @import("../../../evaluator.zig").Engine;
const tooling_bc = @import("../../../tooling/bytecode.zig");

const OpLine = struct { name: []const u8, index: usize };
const Disassembly = struct {
    text: []u8,
    lines: []OpLine,

    fn deinit(self: *Disassembly, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
        allocator.free(self.text);
    }
};

fn disasmChunk(allocator: std.mem.Allocator, ev: *Engine, chunk_id: types.ChunkId) !Disassembly {
    const target = ev.getChunk(chunk_id).?;
    const symbols = tooling_bc.disasm.Symbols{ .intern = ev.internTable(), .registry = ev.chunkRegistry() };
    const options = tooling_bc.disasm.Options{ .recurse = true, .max_depth = 16 };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try tooling_bc.disasm.writeChunk(allocator, &out.writer, chunk_id, target, symbols, options);
    const text = try out.toOwnedSlice();
    errdefer allocator.free(text);

    var lines: std.ArrayListUnmanaged(OpLine) = .empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    var idx: usize = 0;
    while (it.next()) |raw_line| : (idx += 1) {
        const line = if (std.mem.startsWith(u8, raw_line, "\xe2\x94\x82 ")) raw_line["\xe2\x94\x82 ".len..] else raw_line;
        if (line.len < 8 or line[0] != ' ' or line[1] != ' ') continue;
        const hex = line[2..6];
        if (!std.mem.eql(u8, line[6..8], "  ")) continue;
        var hex_ok = true;
        for (hex) |c| {
            if (!std.ascii.isHex(c)) hex_ok = false;
        }
        if (!hex_ok) continue;
        const rest = std.mem.trimStart(u8, line[8..], " ");
        const name_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        try lines.append(allocator, .{ .name = rest[0..name_end], .index = idx });
    }
    return .{ .text = text, .lines = try lines.toOwnedSlice(allocator) };
}

/// Compile `source`, collect every chunk registered by that one compile
/// (ids 2..count, i.e. everything past the two well-known chunks) as a
/// `UnitRecord`, reordering so the compile's own top-level chunk — which a
/// single compile unit always registers LAST (children before parents) — is
/// the record's last entry.
fn collectUnit(allocator: std.mem.Allocator, ev: *Engine, top: types.ChunkId) !std.ArrayListUnmanaged(types.ChunkId) {
    const total = ev.chunkRegistry().count();
    var ids: std.ArrayListUnmanaged(types.ChunkId) = .empty;
    errdefer ids.deinit(allocator);
    var cid: types.ChunkId = 2;
    while (cid < total) : (cid += 1) try ids.append(allocator, cid);
    if (ids.items[ids.items.len - 1] != top) {
        for (ids.items, 0..) |v, idx| {
            if (v == top) {
                std.mem.swap(types.ChunkId, &ids.items[idx], &ids.items[ids.items.len - 1]);
                break;
            }
        }
    }
    try testing.expectEqual(top, ids.items[ids.items.len - 1]);
    return ids;
}

fn firstChunkCode(bytes: []u8) Error![]u8 {
    var r: Reader = .{ .bytes = bytes };
    _ = try r.bytesN(checksum_end);
    _ = try r.u32_(); // chunk count
    const deferred_count = try r.u32_();
    const scope_count = try r.u32_();
    const string_count = try r.u32_();
    const name_count = try r.u32_();
    _ = try r.u32_(); // top ordinal
    var i: u32 = 0;
    while (i < string_count) : (i += 1) _ = try r.bytesN(try r.u32_());
    i = 0;
    while (i < name_count) : (i += 1) _ = try r.bytesN(9);
    i = 0;
    while (i < scope_count) : (i += 1) _ = try r.bytesN(@as(usize, try r.u16_()) * 7);
    _ = try r.bytesN(@as(usize, deferred_count) * 18);

    _ = try r.bytesN(4 + 2 + 2 + 1 + 8 + 8 + 1 + 1 + 1 + 1 + 2);
    switch (try r.u8_()) {
        0 => {},
        1 => _ = try r.bytesN(4),
        2 => _ = try r.bytesN(6),
        else => return error.Corrupt,
    }
    if (try r.u8_() != 0) {
        const has_file = try r.u8_();
        if (has_file != 0) _ = try r.bytesN(4);
        _ = try r.bytesN(16);
    }
    const len = try r.u32_();
    const start = r.pos;
    _ = try r.bytesN(len);
    return bytes[start .. start + len];
}

fn refreshChecksum(bytes: []u8) void {
    const sum = std.hash.Wyhash.hash(checksum_seed, bytes[checksum_end..]);
    std.mem.writeInt(u64, bytes[checksum_start..][0..8], sum, .little);
}

test "serialize/load roundtrips a compile unit's chunk graph (disasm parity)" {
    const allocator = testing.allocator;
    const source =
        \\let
        \\  s = "hello";
        \\  p = ./foo;
        \\  f = 3.5;
        \\  big = 9223372036854775807;
        \\  at = { a = 1; b = "x"; };
        \\  li = [ 1 2 3 ];
        \\  outer = a: b: a + b;
        \\  nested = x: { y = x; };
        \\  ao = at.a or 0;
        \\  bindf = { x, y ? 1 }: x + y;
        \\  k = "a";
        \\  mixed = at.${k}.a or 2;
        \\  bi = builtins;
        \\in [ s p f big at li outer nested ao bindf mixed bi ]
    ;

    var ev1 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev1.deinit();
    const top1 = try ev1.compileSource(source, "cache-roundtrip.nix");

    var ids = try collectUnit(allocator, &ev1, top1);
    defer ids.deinit(allocator);

    const bytes = try serialize(allocator, ev1.chunkRegistry(), &ev1.intern, &ev1.heap, &ev1.compilation.deferred_table, .{
        .source_path = "cache-roundtrip.nix",
        .chunk_ids = ids.items,
        .deferred_ids = &.{},
    });
    defer allocator.free(bytes);

    var ev2 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev2.deinit();
    var ast_arena = ast.AstArena.init(allocator);
    defer ast_arena.deinit();

    const result = try load(bytes, .{
        .allocator = ev2.allocator,
        .registry = &ev2.registry,
        .intern = &ev2.intern,
        .heap = &ev2.heap,
        .deferred = &ev2.compilation.deferred_table,
        .ast_arena = &ast_arena,
        .source = source,
        .base_path = null,
        .source_path = "cache-roundtrip.nix",
        .policy = .{},
    });
    try testing.expectEqual(@as(u32, 0), result.deferred_count);
    try testing.expectEqual(@as(u32, @intCast(ids.items.len)), result.chunk_count);

    var d1 = try disasmChunk(allocator, &ev1, top1);
    defer d1.deinit(allocator);
    var d2 = try disasmChunk(allocator, &ev2, result.top);
    defer d2.deinit(allocator);

    try testing.expectEqual(d1.lines.len, d2.lines.len);
    for (d1.lines, d2.lines) |a, b| try testing.expectEqualStrings(a.name, b.name);
}

test "constant attrset positions survive a cache roundtrip" {
    const allocator = testing.allocator;
    const source = "\"placeholder\"";

    var ev1 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev1.deinit();
    const name1 = try ev1.intern.intern("positioned");
    const file1 = try ev1.intern.intern("constant-position.nix");
    const attrs_id = try ev1.heap.addAttrsWithPositions(
        &.{.{ .name = name1, .value = Value.boolVal(true) }},
        &.{.{ .name = name1, .pos = .{ .file = file1, .line = 1, .column = 3 } }},
    );
    const top1 = try ev1.compileSource(source, "constant-position.nix");
    const constants = @constCast(ev1.getChunk(top1).?.constants);
    try testing.expectEqual(@as(usize, 1), constants.len);
    constants[0] = Value.attrs(attrs_id);
    var ids = try collectUnit(allocator, &ev1, top1);
    defer ids.deinit(allocator);
    const bytes = try serialize(allocator, ev1.chunkRegistry(), &ev1.intern, &ev1.heap, &ev1.compilation.deferred_table, .{
        .source_path = "constant-position.nix",
        .chunk_ids = ids.items,
        .deferred_ids = &.{},
    });
    defer allocator.free(bytes);

    var ev2 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev2.deinit();
    var ast_arena = ast.AstArena.init(allocator);
    defer ast_arena.deinit();
    const result = try load(bytes, .{
        .allocator = ev2.allocator,
        .registry = &ev2.registry,
        .intern = &ev2.intern,
        .heap = &ev2.heap,
        .deferred = &ev2.compilation.deferred_table,
        .ast_arena = &ast_arena,
        .source = source,
        .base_path = null,
        .source_path = "constant-position.nix",
        .policy = .{},
    });

    const name = try ev2.intern.intern("positioned");
    var found = false;
    for (ev2.getChunk(result.top).?.constants) |constant| {
        if (!constant.isAttrs()) continue;
        const pos = ev2.heap.getAttrPos(constant.asObjectId(), name) orelse continue;
        try testing.expectEqualStrings("constant-position.nix", ev2.intern.get(pos.file));
        found = true;
    }
    try testing.expect(found);
}

test "serialize keeps the first ordinal of a reused unit chunk" {
    const allocator = testing.allocator;
    const source = "let f = x: x; in f 1";

    var ev1 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev1.deinit();
    const top1 = try ev1.compileSource(source, "duplicate-unit-chunk.nix");
    var ids = try collectUnit(allocator, &ev1, top1);
    defer ids.deinit(allocator);
    try testing.expect(ids.items.len > 1);

    const duplicated = try allocator.alloc(types.ChunkId, ids.items.len + 1);
    defer allocator.free(duplicated);
    duplicated[0] = ids.items[0];
    @memcpy(duplicated[1..], ids.items);
    const bytes = try serialize(allocator, ev1.chunkRegistry(), &ev1.intern, &ev1.heap, &ev1.compilation.deferred_table, .{
        .source_path = "duplicate-unit-chunk.nix",
        .chunk_ids = duplicated,
        .deferred_ids = &.{},
    });
    defer allocator.free(bytes);

    var ev2 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev2.deinit();
    var ast_arena = ast.AstArena.init(allocator);
    defer ast_arena.deinit();
    const result = try load(bytes, .{
        .allocator = ev2.allocator,
        .registry = &ev2.registry,
        .intern = &ev2.intern,
        .heap = &ev2.heap,
        .deferred = &ev2.compilation.deferred_table,
        .ast_arena = &ast_arena,
        .source = source,
        .base_path = null,
        .source_path = "duplicate-unit-chunk.nix",
        .policy = .{},
    });
    try testing.expectEqual(@as(u32, @intCast(ids.items.len)), result.chunk_count);
}

test "load rejects a bad magic header" {
    const allocator = testing.allocator;
    var ev = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    var ast_arena = ast.AstArena.init(allocator);
    defer ast_arena.deinit();

    var bad_buf: [24]u8 = @splat(0);
    @memcpy(bad_buf[0..4], "NOPE");

    const result = load(&bad_buf, .{
        .allocator = ev.allocator,
        .registry = &ev.registry,
        .intern = &ev.intern,
        .heap = &ev.heap,
        .deferred = &ev.compilation.deferred_table,
        .ast_arena = &ast_arena,
        .source = "",
        .base_path = null,
        .source_path = null,
        .policy = .{},
    });
    try testing.expectError(error.Corrupt, result);
}

test "load rejects any single flipped payload byte (checksum)" {
    const allocator = testing.allocator;
    var ev1 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev1.deinit();
    const top1 = try ev1.compileSource("let x = 1; y = x + 2; in { inherit x y; }", "flip.nix");

    var ids = try collectUnit(allocator, &ev1, top1);
    defer ids.deinit(allocator);

    const bytes = try serialize(allocator, ev1.chunkRegistry(), &ev1.intern, &ev1.heap, &ev1.compilation.deferred_table, .{
        .source_path = "flip.nix",
        .chunk_ids = ids.items,
        .deferred_ids = &.{},
    });
    defer allocator.free(bytes);
    try testing.expect(bytes.len > checksum_end);

    const mutated = try allocator.dupe(u8, bytes);
    defer allocator.free(mutated);
    // Flip a byte in the middle of the payload — deep enough that magic,
    // version, and counts all still parse; only the checksum can catch it.
    const flip_at = checksum_end + (mutated.len - checksum_end) / 2;
    mutated[flip_at] ^= 0x40;

    var ev2 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev2.deinit();
    var ast_arena = ast.AstArena.init(allocator);
    defer ast_arena.deinit();

    const result = load(mutated, .{
        .allocator = ev2.allocator,
        .registry = &ev2.registry,
        .intern = &ev2.intern,
        .heap = &ev2.heap,
        .deferred = &ev2.compilation.deferred_table,
        .ast_arena = &ast_arena,
        .source = "let x = 1; y = x + 2; in { inherit x y; }",
        .base_path = null,
        .source_path = "flip.nix",
        .policy = .{},
    });
    try testing.expectError(error.Corrupt, result);
}

test "checksum-valid malformed operand layouts publish no cache state" {
    const allocator = testing.allocator;
    const source = "let x = 1; in x";
    var ev1 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev1.deinit();
    const top = try ev1.compileSource(source, "malformed.nix");
    var ids = try collectUnit(allocator, &ev1, top);
    defer ids.deinit(allocator);
    const clean = try serialize(allocator, ev1.chunkRegistry(), &ev1.intern, &ev1.heap, &ev1.compilation.deferred_table, .{
        .source_path = "malformed.nix",
        .chunk_ids = ids.items,
        .deferred_ids = &.{},
    });
    defer allocator.free(clean);

    var ev2 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev2.deinit();
    const chunks_before = ev2.registry.count();
    const deferred_before = ev2.compilation.deferred_table.stats().registered;
    const malformed_ops = [_]OpCode{ .attr_get_path_or, .attr_bind, .attr_get_path_mix_or };
    for (malformed_ops) |malformed_op| {
        const bytes = try allocator.dupe(u8, clean);
        defer allocator.free(bytes);
        const code = try firstChunkCode(bytes);
        code[code.len - 1] = @intFromEnum(malformed_op);
        refreshChecksum(bytes);
        var ast_arena = ast.AstArena.init(allocator);
        defer ast_arena.deinit();
        try testing.expectError(error.Corrupt, load(bytes, .{
            .allocator = ev2.allocator,
            .registry = &ev2.registry,
            .intern = &ev2.intern,
            .heap = &ev2.heap,
            .deferred = &ev2.compilation.deferred_table,
            .ast_arena = &ast_arena,
            .source = source,
            .base_path = null,
            .source_path = "malformed.nix",
            .policy = .{},
        }));
        try testing.expectEqual(chunks_before, ev2.registry.count());
        try testing.expectEqual(deferred_before, ev2.compilation.deferred_table.stats().registered);
    }
}

test "deferred scope table serializes and loads a shared snapshot once" {
    const allocator = testing.allocator;
    const source = "xy";
    var ev1 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev1.deinit();
    const top = try ev1.compileSource("null", "scope.nix");
    var ids = try collectUnit(allocator, &ev1, top);
    defer ids.deinit(allocator);
    const capture_name = try ev1.intern.intern("shared");
    const scope = try ev1.compilation.deferred_table.adoptScope(&.{.{
        .name = ev1.intern.get(capture_name),
        .name_id = capture_name,
        .kind = .local,
        .index = 0,
    }});
    var nodes = ast.AstArena.init(allocator);
    defer nodes.deinit();
    const first_node = try nodes.createNode(.elided, .{ .atom = .{ .offset = 0, .len = 1 } });
    const second_node = try nodes.createNode(.elided, .{ .atom = .{ .offset = 1, .len = 1 } });
    const first = try ev1.compilation.deferred_table.register(.{
        .node = first_node,
        .scope = scope,
        .source = source,
        .base_path = null,
        .source_path = "scope.nix",
        .source_file_id = null,
    });
    const second = try ev1.compilation.deferred_table.register(.{
        .node = second_node,
        .scope = scope,
        .source = source,
        .base_path = null,
        .source_path = "scope.nix",
        .source_file_id = null,
    });
    const bytes = try serialize(allocator, ev1.chunkRegistry(), &ev1.intern, &ev1.heap, &ev1.compilation.deferred_table, .{
        .source_path = "scope.nix",
        .chunk_ids = ids.items,
        .deferred_ids = &.{ first, second },
    });
    defer allocator.free(bytes);
    try testing.expectEqual(@as(u32, 1), encoding.readU32(bytes, 24));

    var ev2 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev2.deinit();
    var loaded_nodes = ast.AstArena.init(allocator);
    defer loaded_nodes.deinit();
    const result = try load(bytes, .{
        .allocator = ev2.allocator,
        .registry = &ev2.registry,
        .intern = &ev2.intern,
        .heap = &ev2.heap,
        .deferred = &ev2.compilation.deferred_table,
        .ast_arena = &loaded_nodes,
        .source = source,
        .base_path = null,
        .source_path = "scope.nix",
        .policy = .{},
    });
    try testing.expectEqual(@as(u32, 2), result.deferred_count);
    const loaded_first = ev2.compilation.deferred_table.get(0);
    const loaded_second = ev2.compilation.deferred_table.get(1);
    try testing.expectEqual(@intFromPtr(loaded_first.scope.ptr), @intFromPtr(loaded_second.scope.ptr));
}

test "load rejects truncated bytes" {
    const allocator = testing.allocator;
    var ev1 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev1.deinit();
    const top1 = try ev1.compileSource("let x = 1; in x", "trunc.nix");

    var ids = try collectUnit(allocator, &ev1, top1);
    defer ids.deinit(allocator);

    const bytes = try serialize(allocator, ev1.chunkRegistry(), &ev1.intern, &ev1.heap, &ev1.compilation.deferred_table, .{
        .source_path = "trunc.nix",
        .chunk_ids = ids.items,
        .deferred_ids = &.{},
    });
    defer allocator.free(bytes);
    try testing.expect(bytes.len > 16);

    var ev2 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev2.deinit();
    var ast_arena = ast.AstArena.init(allocator);
    defer ast_arena.deinit();

    const result = load(bytes[0 .. bytes.len / 2], .{
        .allocator = ev2.allocator,
        .registry = &ev2.registry,
        .intern = &ev2.intern,
        .heap = &ev2.heap,
        .deferred = &ev2.compilation.deferred_table,
        .ast_arena = &ast_arena,
        .source = "let x = 1; in x",
        .base_path = null,
        .source_path = "trunc.nix",
        .policy = .{},
    });
    try testing.expectError(error.Corrupt, result);
}

test "constants preserve a folded attrs/list value graph across roundtrip" {
    const allocator = testing.allocator;
    const source =
        \\let p = { file = "f"; line = 1; nested = [ 1 "two" { a = true; } ]; }; in p
    ;

    var ev1 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev1.deinit();
    const top1 = try ev1.compileSource(source, "value-graph.nix");

    var ids = try collectUnit(allocator, &ev1, top1);
    defer ids.deinit(allocator);

    const bytes = try serialize(allocator, ev1.chunkRegistry(), &ev1.intern, &ev1.heap, &ev1.compilation.deferred_table, .{
        .source_path = "value-graph.nix",
        .chunk_ids = ids.items,
        .deferred_ids = &.{},
    });
    defer allocator.free(bytes);

    var ev2 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev2.deinit();
    var ast_arena = ast.AstArena.init(allocator);
    defer ast_arena.deinit();

    const result = try load(bytes, .{
        .allocator = ev2.allocator,
        .registry = &ev2.registry,
        .intern = &ev2.intern,
        .heap = &ev2.heap,
        .deferred = &ev2.compilation.deferred_table,
        .ast_arena = &ast_arena,
        .source = source,
        .base_path = null,
        .source_path = "value-graph.nix",
        .policy = .{},
    });

    const c1 = ev1.getChunk(top1).?;
    const c2 = ev2.getChunk(result.top).?;
    try testing.expectEqual(c1.constants.len, c2.constants.len);

    var d1 = try disasmChunk(allocator, &ev1, top1);
    defer d1.deinit(allocator);
    var d2 = try disasmChunk(allocator, &ev2, result.top);
    defer d2.deinit(allocator);
    try testing.expectEqual(d1.lines.len, d2.lines.len);
    for (d1.lines, d2.lines) |a, b| try testing.expectEqualStrings(a.name, b.name);
}

test "computeKey is stable for identical inputs and varies with codegen policy" {
    const ctx: KeyContext = .{
        .policy_fp = 42,
        .let_float_enabled = true,
        .full_lazy_enabled = false,
        .mfe_min_applies = 1,
        .named_floats = true,
        .chain_split = false,
        .home = "/home/x",
    };
    const k1 = computeKey("let x = 1; in x", "a.nix", ctx);
    const k2 = computeKey("let x = 1; in x", "a.nix", ctx);
    try testing.expectEqualSlices(u8, &k1, &k2);

    const k3 = computeKey("let x = 2; in x", "a.nix", ctx);
    try testing.expect(!std.mem.eql(u8, &k1, &k3));

    var no_float = ctx;
    no_float.let_float_enabled = false;
    const k4 = computeKey("let x = 1; in x", "a.nix", no_float);
    try testing.expect(!std.mem.eql(u8, &k1, &k4));

    var lazy = ctx;
    lazy.full_lazy_enabled = true;
    const k5 = computeKey("let x = 1; in x", "a.nix", lazy);
    try testing.expect(!std.mem.eql(u8, &k1, &k5));

    var gated = lazy;
    gated.mfe_min_applies = 2;
    const k6 = computeKey("let x = 1; in x", "a.nix", gated);
    try testing.expect(!std.mem.eql(u8, &k5, &k6));

    var no_named = lazy;
    no_named.named_floats = false;
    const k7 = computeKey("let x = 1; in x", "a.nix", no_named);
    try testing.expect(!std.mem.eql(u8, &k5, &k7));
}

test "cache load does not allocate for empty chunk side tables" {
    const allocator = testing.allocator;
    // Bodies with no captures, no named function arguments and no attr
    // tables: the side tables that a real unit leaves empty most of the time.
    const source =
        \\[ (a: 1) (b: 2) (c: 3) (d: 4) (e: 5) (f: 6) (g: 7) (h: 8) ]
    ;

    var ev1 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev1.deinit();
    const top1 = try ev1.compileSource(source, "empty-tables.nix");
    var ids = try collectUnit(allocator, &ev1, top1);
    defer ids.deinit(allocator);

    const bytes = try serialize(allocator, ev1.chunkRegistry(), &ev1.intern, &ev1.heap, &ev1.compilation.deferred_table, .{
        .source_path = "empty-tables.nix",
        .chunk_ids = ids.items,
        .deferred_ids = &.{},
    });
    defer allocator.free(bytes);

    var ev2 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev2.deinit();
    var ast_arena = ast.AstArena.init(allocator);
    defer ast_arena.deinit();

    // Counts what the decoder allocates. The registry keeps its own allocator,
    // so batch registration stays out of this number.
    var counting = std.testing.FailingAllocator.init(ev2.allocator, .{});
    const result = try load(bytes, .{
        .allocator = counting.allocator(),
        .registry = &ev2.registry,
        .intern = &ev2.intern,
        .heap = &ev2.heap,
        .deferred = &ev2.compilation.deferred_table,
        .ast_arena = &ast_arena,
        .source = source,
        .base_path = null,
        .source_path = "empty-tables.nix",
        .policy = .{},
    });

    try testing.expect(result.chunk_count >= 8);
    // `decodeChunk` has eight allocation sites per chunk, but a zero-length
    // request never reaches the allocator: `Allocator.allocBytesWithAlignment`
    // returns a dangling aligned pointer for a zero byte count. Only the
    // non-empty side tables cost a block, which for these bodies is the code
    // and the source map. Guards against a change that makes every site
    // allocate for real.
    try testing.expect(counting.allocations <= 3 * result.chunk_count);
}

test "reverse-ordered attrs and pattern binds survive a cache roundtrip" {
    const allocator = testing.allocator;
    // Names declared in descending order drive the sorted-invariant fixups on
    // load: the attrset ops fall back from their `_srt` form, and the pattern
    // bind pairs are re-sorted in place. Both run in the same walk as the id
    // remap, so a fusion mistake shows up here.
    const source =
        \\let
        \\  attrs = { zeta = 1; mid = 2; alpha = 3; };
        \\  pat = { zulu, yankee ? 4, alfa }: zulu + yankee + alfa;
        \\  nested = { q = { zz = 1; aa = 2; }; b = 3; };
        \\in [ attrs.alpha attrs.zeta (pat { zulu = 5; alfa = 6; }) nested.q.aa ]
    ;

    var ev1 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev1.deinit();
    const top1 = try ev1.compileSource(source, "sorted-roundtrip.nix");
    var ids = try collectUnit(allocator, &ev1, top1);
    defer ids.deinit(allocator);

    const bytes = try serialize(allocator, ev1.chunkRegistry(), &ev1.intern, &ev1.heap, &ev1.compilation.deferred_table, .{
        .source_path = "sorted-roundtrip.nix",
        .chunk_ids = ids.items,
        .deferred_ids = &.{},
    });
    defer allocator.free(bytes);

    var ev2 = try Engine.init(allocator, .{ .worker_count = 0 });
    defer ev2.deinit();
    var ast_arena = ast.AstArena.init(allocator);
    defer ast_arena.deinit();

    const result = try load(bytes, .{
        .allocator = ev2.allocator,
        .registry = &ev2.registry,
        .intern = &ev2.intern,
        .heap = &ev2.heap,
        .deferred = &ev2.compilation.deferred_table,
        .ast_arena = &ast_arena,
        .source = source,
        .base_path = null,
        .source_path = "sorted-roundtrip.nix",
        .policy = .{},
    });
    try testing.expectEqual(@as(u32, @intCast(ids.items.len)), result.chunk_count);

    var d1 = try disasmChunk(allocator, &ev1, top1);
    defer d1.deinit(allocator);
    var d2 = try disasmChunk(allocator, &ev2, result.top);
    defer d2.deinit(allocator);

    try testing.expectEqual(d1.lines.len, d2.lines.len);
    for (d1.lines, d2.lines) |a, b| try testing.expectEqualStrings(a.name, b.name);
}
