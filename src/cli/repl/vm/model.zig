//! Persistent and rendered data model for the interactive VM explorer.
//!
//! This module intentionally contains no terminal I/O or evaluator operations:
//! it describes what the explorer can display and the state navigation keeps.

const std = @import("std");
const runtime = @import("runtime");
const vm_navigation = @import("navigation.zig");
const vm_refs = @import("refs.zig");
const vm_source = @import("source.zig");

const ChunkId = runtime.types.ChunkId;

pub const Category = enum(u1) { bytecode, heap };
pub const HeapView = enum { overview, objects, values, attrs, attr_positions, intern, builtin };

pub const RowAction = union(enum) {
    none,
    section,
    source: ChunkId,
    instruction,
    chunk: ChunkId,
    object: runtime.types.ObjectId,
    store_record: struct { view: HeapView, id: u32 },
};

/// One rendered inspector document (or the help screen). Actions and locations
/// are parallel to lines so links survive independently of viewport height.
pub const Page = struct {
    title: []u8,
    lines: [][]u8,
    actions: []RowAction,
    locations: []const ?vm_source.Location = &.{},
};

pub const PageBuilder = struct {
    arena: std.mem.Allocator,
    lines: std.ArrayListUnmanaged([]u8) = .empty,
    actions: std.ArrayListUnmanaged(RowAction) = .empty,
    locations: std.ArrayListUnmanaged(?vm_source.Location) = .empty,

    pub fn line(self: *PageBuilder, line_text: []const u8, action: RowAction) !void {
        try self.lineAt(line_text, action, null);
    }

    pub fn heading(self: *PageBuilder, line_text: []const u8) !void {
        try self.line(line_text, .section);
    }

    pub fn lineAt(self: *PageBuilder, line_text: []const u8, action: RowAction, location: ?vm_source.Location) !void {
        try self.lines.append(self.arena, try self.arena.dupe(u8, line_text));
        try self.actions.append(self.arena, action);
        try self.locations.append(self.arena, location);
    }

    pub fn text(self: *PageBuilder, contents: []const u8) !void {
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |line_text| try self.line(line_text, .none);
        if (self.lines.items.len > 0 and self.lines.items[self.lines.items.len - 1].len == 0) {
            _ = self.lines.pop();
            _ = self.actions.pop();
            _ = self.locations.pop();
        }
    }
};

/// A stack entry remembers where you were on the page you left.
pub const Visit = struct {
    kind: Kind,
    scroll: usize = 0,
    tree_selection: usize = 0,
    detail_selection: usize = 0,
    x_scroll: usize = 0,

    pub const Kind = union(enum) {
        chunk: ChunkId,
        heap: HeapView,
        object: runtime.types.ObjectId,
        store_record: struct { view: HeapView, id: u32 },
        debug_frame: usize,
        debug_value,
        help,
    };
};

pub const RangeKind = enum(u4) { names, chunks, objects, values, attrs, attr_positions, intern, builtin };

pub const RangeKey = struct {
    kind: RangeKind,
    parent: u64,
    start: u32,
    span: u32,
};

pub const ChunkEquivalence = union(enum) {
    structural: ChunkId,
    code: ChunkId,
};

pub const Range = struct {
    kind: RangeKind,
    parent: u32,
    start: u32,
    len: u32,
    /// Live records in this half-open range, distinct from backing capacity.
    live: u32,
    depth: u16,
    stable_parent: u64 = 0,
    /// Nominal width, so a growing final partial range keeps its identity.
    key_span: u32,

    pub fn key(self: Range) RangeKey {
        return .{
            .kind = self.kind,
            .parent = self.stable_parent,
            .start = self.start,
            .span = self.key_span,
        };
    }
};

pub const TreeRow = union(enum) {
    category: struct { kind: Category, depth: u16 },
    name: struct { id: u32, key: u64, depth: u16 },
    chunk: struct { id: ChunkId, depth: u16, label: ?u32 = null },
    range: Range,
    heap: struct { view: HeapView, depth: u16 },
    object: struct { id: runtime.types.ObjectId, depth: u16 },
    store_record: struct { view: HeapView, id: u32, depth: u16 },
    debug_root: struct { depth: u16 },
    debug_frame: struct { index: u32, depth: u16 },
    debug_value: struct { depth: u16 },
};

pub const LineRange = struct { start: usize, end: usize };

pub const NavigationState = struct {
    back: std.ArrayListUnmanaged(Visit) = .empty,
    forward: std.ArrayListUnmanaged(Visit) = .empty,
    search: std.ArrayListUnmanaged(u8) = .empty,
    focus: vm_navigation.Focus = .subject,
    tree_selection: usize = 0,
    detail_selection: usize = 0,
    scroll: usize = 0,
    x_scroll: usize = 0,
};

pub const HeapProjection = struct {
    view: HeapView,
    id: u32,
};

pub const TreeState = struct {
    expanded_names: std.AutoHashMapUnmanaged(u64, void) = .empty,
    expanded_ranges: std.AutoHashMapUnmanaged(RangeKey, void) = .empty,
    focus_path: std.AutoHashMapUnmanaged(u32, void) = .empty,
    rows: std.ArrayListUnmanaged(TreeRow) = .empty,
    indexing: bool = false,
    categories: [2]bool = .{ false, false },
    heap_views: [@typeInfo(HeapView).@"enum".field_names.len]bool = @splat(false),
    filter_query: std.ArrayListUnmanaged(u8) = .empty,
    filter_keep: std.AutoHashMapUnmanaged(u32, void) = .empty,
    projected_chunk: ?ChunkId = null,
    projected_heap: ?HeapProjection = null,
};

pub const HeapIndexState = struct {
    stats: ?runtime.ObjectHeap.Stats = null,
    objects: ?runtime.ObjectHeap.ObjectSnapshot = null,
    objects_failed: bool = false,
    values: ?runtime.ObjectHeap.ObjectSnapshot = null,
    values_count: u32 = 0,
    attrs: ?runtime.ObjectHeap.ObjectSnapshot = null,
    attrs_count: u32 = 0,
    attr_positions: ?runtime.ObjectHeap.ObjectSnapshot = null,
    attr_positions_count: u32 = 0,
};

pub const ReferenceIndexState = struct {
    graph: ?vm_refs.Graph = null,
    failed: bool = false,
};

pub const Viewport = struct {
    cols: usize = 80,
    rows: usize = 22,
};

test "range identity ignores a growing partial tail" {
    const range: Range = .{
        .kind = .chunks,
        .parent = 9,
        .start = 256,
        .len = 12,
        .live = 12,
        .depth = 2,
        .stable_parent = 42,
        .key_span = 256,
    };
    try std.testing.expectEqual(RangeKey{
        .kind = .chunks,
        .parent = 42,
        .start = 256,
        .span = 256,
    }, range.key());
}
