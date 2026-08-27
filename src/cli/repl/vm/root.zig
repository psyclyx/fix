//! The integrated VM explorer: tree navigation, inspection, and debugger UI.
//!
//! Interactive use is deliberately a TUI rather than a pager: the name tree is
//! persistent navigation, the chunk detail is a separately scrollable pane,
//! and the ordinary REPL prompt/transcript occupy the same surface. The plain
//! (`--no-tui`/non-tty) fallback exposes the same model through bounded commands.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const width_mod = @import("../width.zig");
const vm_model = @import("model.zig");
const vm_helpers = @import("semantics.zig");
const vm_tui = @import("tui.zig");
const Engine = engine.Engine;
const ChunkId = runtime.types.ChunkId;
const disasm = engine.bytecode.disasm;

const HeapView = vm_model.HeapView;
const TreeRow = vm_model.TreeRow;

const disasm_options: disasm.Options = .{
    .show_constants = true,
    .show_source = true,
    .show_bytes = true,
    .recurse = false,
};

/// Non-interactive `:vm`: the focused chunk without terminal chrome.
pub fn writePlain(allocator: std.mem.Allocator, w: *std.Io.Writer, ev: *Engine, chunk_id: ChunkId) !void {
    const symbols: disasm.Symbols = .{ .intern = ev.internTable(), .registry = ev.chunkRegistry() };
    try writeChunk(allocator, w, ev, chunk_id, symbols, disasm_options);
}

fn writeChunk(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    ev: *Engine,
    chunk_id: ChunkId,
    symbols: disasm.Symbols,
    options: disasm.Options,
) !void {
    const chunk = ev.getChunk(chunk_id) orelse {
        try w.print("chunk[0x{x}] not found\n", .{chunk_id});
        return;
    };
    try disasm.writeChunk(allocator, w, chunk_id, chunk, symbols, options);
}

pub const SessionHost = vm_tui.SessionHost;
pub const VmDebugger = vm_tui.VmDebugger;
pub const runSession = vm_tui.runSession;

test "disassembly targets recognize chunk and heap links" {
    try std.testing.expectEqual(@as(ChunkId, 0x2a), vm_helpers.disasmTarget("chunk[0x2a] → function").chunk);
    try std.testing.expectEqual(@as(runtime.types.ObjectId, 0x31), vm_helpers.disasmTarget("objects[0x31] → thunk").object);
    const intern = vm_helpers.disasmTarget("intern[0x1] → string \"x\"").store_record;
    try std.testing.expectEqual(HeapView.intern, intern.view);
    try std.testing.expectEqual(@as(u32, 1), intern.id);
    const builtin = vm_helpers.disasmTarget("builtin[0x20] → import").store_record;
    try std.testing.expectEqual(HeapView.builtin, builtin.view);
    try std.testing.expectEqual(@as(u32, 0x20), builtin.id);
}

test "tree row identities ignore transient display ids" {
    const old_name: TreeRow = .{ .name = .{ .id = 3, .key = 0xabc, .depth = 2 } };
    const rebuilt_name: TreeRow = .{ .name = .{ .id = 19, .key = 0xabc, .depth = 5 } };
    try std.testing.expect(vm_helpers.treeRowsEqual(old_name, rebuilt_name));

    const old_range: TreeRow = .{ .range = .{
        .kind = .chunks,
        .parent = 3,
        .stable_parent = 0xabc,
        .start = 256,
        .len = 17,
        .live = 17,
        .key_span = 256,
        .depth = 3,
    } };
    const rebuilt_range: TreeRow = .{ .range = .{
        .kind = .chunks,
        .parent = 19,
        .stable_parent = 0xabc,
        .start = 256,
        .len = 93,
        .live = 93,
        .key_span = 256,
        .depth = 6,
    } };
    try std.testing.expect(vm_helpers.treeRowsEqual(old_range, rebuilt_range));
}

test {
    _ = @import("controller.zig");
    _ = @import("debug_view.zig");
    _ = @import("jobs.zig");
    _ = @import("model.zig");
    _ = @import("navigation.zig");
    _ = @import("operations.zig");
    _ = @import("pages.zig");
    _ = @import("plain.zig");
    _ = @import("preview.zig");
    _ = @import("prompt.zig");
    _ = @import("query_cache.zig");
    _ = @import("refs.zig");
    _ = @import("semantics.zig");
    _ = @import("source.zig");
    _ = @import("source_view.zig");
    _ = @import("tree.zig");
    _ = @import("tree_projection.zig");
    _ = @import("tree_render.zig");
    _ = @import("tui.zig");
    _ = @import("value_summary.zig");
}

test "source snippets honor their container width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "alpha βeta gamma delta";
    const snippet = try vm_helpers.spanSnippet(arena.allocator(), source, .{
        .offset = 0,
        .len = source.len,
    }, 9);
    try std.testing.expect(width_mod.strWidth(snippet) <= 9);
    try std.testing.expect(std.mem.endsWith(u8, snippet, "…"));
}
