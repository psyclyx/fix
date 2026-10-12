//! Internal VM explorer component.
//!
//! Methods are parameterized by the private explorer state type and wired as
//! direct aliases by `operations.zig`; this module owns the behavior below.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const vm_tree = @import("tree.zig");
const vm_model = @import("model.zig");
const vm_helpers = @import("semantics.zig");
const source_render = @import("../../source_render.zig");
const debugger = @import("../../debugger.zig");
const base = @import("base");
const tui = base.tui;
const Engine = engine.Engine;
const DebugSession = engine.DebugSession;
const ChunkId = runtime.types.ChunkId;
const bytecode = engine.bytecode;
const disasm = engine.bytecode.disasm;

const Category = vm_model.Category;
const HeapView = vm_model.HeapView;
const RowAction = vm_model.RowAction;
const Page = vm_model.Page;
const PageBuilder = vm_model.PageBuilder;
const Visit = vm_model.Visit;
const RangeKind = vm_model.RangeKind;
const ChunkEquivalence = vm_model.ChunkEquivalence;
const Range = vm_model.Range;
const TreeRow = vm_model.TreeRow;
const LineRange = vm_model.LineRange;
const NavigationState = vm_model.NavigationState;
const TreeState = vm_model.TreeState;
const HeapIndexState = vm_model.HeapIndexState;
const ReferenceIndexState = vm_model.ReferenceIndexState;
const Viewport = vm_model.Viewport;

const range_leaf = 256;
const range_branch = 4096;

pub fn Methods(comptime Explorer: type) type {
    return struct {
        pub fn rebuildTreeForCurrent(self: *Explorer) !void {
            try rebuildTree(self, self.tree.projected_chunk orelse std.math.maxInt(ChunkId));
        }

        pub fn expandFocusedPath(self: *Explorer, chunk_id: ChunkId) !void {
            self.tree.categories[@backingInt(Category.bytecode)] = true;
            try projectFocusedPath(self, chunk_id);
        }

        pub fn projectFocusedPath(self: *Explorer, chunk_id: ChunkId) !void {
            self.tree.projected_chunk = chunk_id;
            self.tree.focus_path.clearRetainingCapacity();
            try self.tree.focus_path.put(self.allocator, vm_tree.root_node_id, {});
            var name = self.tree_index.nodeForChunk(chunk_id);
            while (name != vm_tree.root_node_id) {
                try self.tree.focus_path.put(self.allocator, name, {});
                name = (self.tree_index.node(name) orelse break).parent;
            }
        }

        pub fn rebuildTree(self: *Explorer, focused_chunk: ChunkId) !void {
            // Remember the selected row's identity so the cursor stays put across a
            // rebuild (async index landing, an evaluation, a distant expand) instead
            // of snapping to whatever is open in the inspector. TreeRow is a value
            // type, so this copy survives clearRetainingCapacity.
            const prev: ?TreeRow = if (self.navigation.tree_selection < self.tree.rows.items.len)
                self.tree.rows.items[self.navigation.tree_selection]
            else
                null;
            self.tree.rows.clearRetainingCapacity();
            // The paused stack sits at the top of the tree while a debug session is
            // live, and vanishes the instant it ends.
            if (self.debug_session) |session| {
                try self.tree.rows.append(self.allocator, .{ .debug_root = .{ .depth = 0 } });
                var i = session.frameCount();
                while (i > 0) {
                    i -= 1;
                    try self.tree.rows.append(self.allocator, .{ .debug_frame = .{ .index = @intCast(i), .depth = 1 } });
                }
                if (session.reason == .break_builtin or session.reason == .eval_error) {
                    try self.tree.rows.append(self.allocator, .{ .debug_value = .{ .depth = 1 } });
                }
            }
            try self.tree.rows.append(self.allocator, .{ .category = .{ .kind = .heap, .depth = 0 } });
            const heap_open = self.tree.categories[@backingInt(Category.heap)];
            const heap_projection = self.tree.projected_heap;
            if (heap_open or heap_projection != null) {
                for (std.meta.tags(HeapView)) |view| {
                    // The aggregate census is not a browsable folder (it hijacked the
                    // inspector with a cursorless page). It lives in the HEAP-row
                    // preview and the `:vm heap` command instead.
                    if (view == .overview) continue;
                    // Keep a collapsed category showing just the store that owns the
                    // currently-open record/object, projected in.
                    const projected_view = if (heap_projection) |projection|
                        projection.view == view
                    else
                        false;
                    if (!heap_open and !projected_view) continue;
                    try self.tree.rows.append(self.allocator, .{ .heap = .{ .view = view, .depth = 1 } });
                    const expanded = self.tree.heap_views[@backingInt(view)] or projected_view;
                    if (!expanded) continue;
                    const projected_only = !heap_open or !self.tree.heap_views[@backingInt(view)];
                    if (view == .intern or view == .builtin) {
                        try appendDenseStoreRange(self, view, 0, Explorer.Ops.view_state.storeCount(self, view), 2, projected_only);
                    } else {
                        const snapshot = if (view == .objects)
                            (if (self.heap_index.objects) |*s| s else null)
                        else
                            Explorer.Ops.view_state.ensureStoreSnapshot(self, view);
                        if (snapshot) |snap| {
                            try appendLiveRange(self, view, snap, 0, snap.liveExtent(), 2, projected_only);
                        }
                    }
                }
            }
            try self.tree.rows.append(self.allocator, .{ .category = .{ .kind = .bytecode, .depth = 0 } });
            if (filterActive(self)) {
                try computeFilterKeep(self);
                try appendFilteredNameRows(self, vm_tree.root_node_id, 1);
            } else if (self.tree.categories[@backingInt(Category.bytecode)]) {
                try appendNameRows(self, vm_tree.root_node_id, 1, focused_chunk);
            } else if (Explorer.Ops.view_state.currentChunk(self) != null) {
                try appendFocusedNameRows(self, vm_tree.root_node_id, 1, focused_chunk);
            }
            self.navigation.tree_selection = 0;
            // 1) Keep the cursor on the same row it was on, if it still exists.
            if (prev) |p| {
                for (self.tree.rows.items, 0..) |row, i| if (vm_helpers.treeRowsEqual(row, p)) {
                    self.navigation.tree_selection = i;
                    return;
                };
            }
            // 2) Otherwise land on whatever the inspector currently shows.
            for (self.tree.rows.items, 0..) |row, i| switch (row) {
                .debug_frame => |entry| if (Explorer.Ops.view_state.currentDebugFrame(self) == entry.index) {
                    self.navigation.tree_selection = i;
                    break;
                },
                .chunk => |entry| if (entry.id == focused_chunk) {
                    self.navigation.tree_selection = i;
                    break;
                },
                .object => |entry| if (entry.id == Explorer.Ops.view_state.currentObject(self)) {
                    self.navigation.tree_selection = i;
                    break;
                },
                .heap => |entry| if (Explorer.Ops.view_state.currentHeap(self) == entry.view) {
                    self.navigation.tree_selection = i;
                    break;
                },
                else => {},
            };
        }

        pub fn filterActive(self: *const Explorer) bool {
            return self.tree.filter_query.items.len > 0;
        }

        pub fn nodeMatchesFilter(self: *const Explorer, node_id: u32) bool {
            const node = self.tree_index.node(node_id) orelse return false;
            return vm_helpers.asciiContainsIgnoreCase(node.label, self.tree.filter_query.items);
        }

        /// Populate `filter_keep` with every name node on a path to a filter match.
        pub fn computeFilterKeep(self: *Explorer) std.mem.Allocator.Error!void {
            self.tree.filter_keep.clearRetainingCapacity();
            if (!filterActive(self)) return;
            _ = try markFilterKeep(self, vm_tree.root_node_id);
            try self.tree.filter_keep.put(self.allocator, vm_tree.root_node_id, {});
        }

        pub fn markFilterKeep(self: *Explorer, node_id: u32) std.mem.Allocator.Error!bool {
            var keep = nodeMatchesFilter(self, node_id);
            for (self.tree_index.childrenOf(node_id)) |child| {
                if (try markFilterKeep(self, child)) keep = true;
            }
            if (keep) try self.tree.filter_keep.put(self.allocator, node_id, {});
            return keep;
        }

        /// The filtered bytecode tree: fully expanded along kept paths, showing a
        /// matched node's own chunks. A node kept only because a descendant matched
        /// stays visible (an ancestor breadcrumb) without dumping its chunks.
        pub fn appendFilteredNameRows(self: *Explorer, name: u32, depth: u16) std.mem.Allocator.Error!void {
            if (!self.tree.filter_keep.contains(name)) return;
            const children = self.tree_index.childrenOf(name);
            const chunks = self.tree_index.chunksOf(name);
            if (name != vm_tree.root_node_id and children.len == 0 and chunks.len == 1 and nodeMatchesFilter(self, name)) {
                try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = chunks[0], .depth = depth, .label = name } });
                return;
            }
            try self.tree.rows.append(self.allocator, .{ .name = .{
                .id = name,
                .key = self.tree_index.stableKey(name),
                .depth = depth,
            } });
            const next_depth = depth +| 1;
            for (children) |child| {
                if (self.tree.filter_keep.contains(child)) try appendFilteredNameRows(self, child, next_depth);
            }
            if (nodeMatchesFilter(self, name)) {
                for (chunks) |id| try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = id, .depth = next_depth } });
            }
        }

        pub fn appendFocusedNameRows(self: *Explorer, name: u32, depth: u16, focused_chunk: ChunkId) std.mem.Allocator.Error!void {
            const children = self.tree_index.childrenOf(name);
            const chunks = self.tree_index.chunksOf(name);
            if (name != vm_tree.root_node_id and children.len == 0 and chunks.len == 1) {
                try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = chunks[0], .depth = depth, .label = name } });
                return;
            }
            try self.tree.rows.append(self.allocator, .{ .name = .{
                .id = name,
                .key = self.tree_index.stableKey(name),
                .depth = depth,
            } });
            const next_depth = depth +| 1;
            for (children) |child| {
                if (self.tree.focus_path.contains(child)) try appendFocusedNameRows(self, child, next_depth, focused_chunk);
            }
            if (self.tree_index.nodeForChunk(focused_chunk) == name and self.ev.getChunk(focused_chunk) != null) {
                try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = focused_chunk, .depth = next_depth } });
            }
        }

        pub fn storeRangeKind(view: HeapView) RangeKind {
            return switch (view) {
                .values => .values,
                .attrs => .attrs,
                .attr_positions => .attr_positions,
                .intern => .intern,
                .builtin => .builtin,
                .overview, .objects => .objects,
            };
        }

        pub fn liveRow(view: HeapView, id: u32, depth: u16) TreeRow {
            return if (view == .objects)
                .{ .object = .{ .id = id, .depth = depth } }
            else
                .{ .store_record = .{ .view = view, .id = id, .depth = depth } };
        }

        /// Dense stores have no reservation holes: every id below `count` is a
        /// real record. They still use the same bounded range fan-out and canonical
        /// store rows as sparse heap stores.
        pub fn appendDenseStoreRange(
            self: *Explorer,
            view: HeapView,
            start: u32,
            len: u32,
            depth: u16,
            projected_only: bool,
        ) std.mem.Allocator.Error!void {
            if (len == 0) return;
            const focused = if (self.tree.projected_heap) |projection|
                if (projection.view == view) projection.id else null
            else
                null;
            const end = start + len;
            if (len <= range_leaf) {
                if (projected_only) {
                    if (focused) |id| if (id >= start and id < end)
                        try self.tree.rows.append(self.allocator, liveRow(view, id, depth));
                    return;
                }
                var id = start;
                while (id < end) : (id += 1)
                    try self.tree.rows.append(self.allocator, liveRow(view, id, depth));
                return;
            }

            var span: u32 = range_leaf;
            while ((len + span - 1) / span > 64) span *= 64;
            var offset: u32 = 0;
            while (offset < len) : (offset += span) {
                const child_start = start + offset;
                const child_len = @min(span, len - offset);
                const child_end = child_start + child_len;
                const contains_focus = if (focused) |id| id >= child_start and id < child_end else false;
                if (projected_only and !contains_focus) continue;
                const range: Range = .{
                    .kind = storeRangeKind(view),
                    .parent = 0,
                    .start = child_start,
                    .len = child_len,
                    .live = child_len,
                    .depth = depth,
                    .key_span = span,
                };
                try self.tree.rows.append(self.allocator, .{ .range = range });
                if (self.tree.expanded_ranges.contains(range.key())) {
                    try appendDenseStoreRange(self, view, child_start, child_len, depth +| 1, false);
                } else if (contains_focus) {
                    try appendDenseStoreRange(self, view, child_start, child_len, depth +| 1, true);
                }
            }
        }

        /// Bounded, liveness-filtered fan-out over any heap store (objects or the
        /// value/attr/attr-position range stores). Only slots that are actually live
        /// per `snapshot` are shown — reserved backing capacity (GC-freed ranges,
        /// unfilled TLAB tails) is skipped entirely, so browsing never surfaces dead
        /// slots as records.
        pub fn appendLiveRange(
            self: *Explorer,
            view: HeapView,
            snapshot: *const runtime.ObjectHeap.ObjectSnapshot,
            start: u32,
            len: u32,
            depth: u16,
            projected_only: bool,
        ) std.mem.Allocator.Error!void {
            if (len == 0) return;
            const end = start + len;
            const focused: ?u32 = if (self.tree.projected_heap) |projection|
                if (projection.view == view) projection.id else null
            else
                null;
            if (len <= range_leaf) {
                if (projected_only) {
                    if (focused) |id| if (id >= start and id < end and snapshot.isLive(id)) {
                        try self.tree.rows.append(self.allocator, liveRow(view, id, depth));
                    };
                    return;
                }
                var next = snapshot.nextLive(start);
                while (next) |id| : (next = snapshot.nextLive(id + 1)) {
                    if (id >= end) break;
                    try self.tree.rows.append(self.allocator, liveRow(view, id, depth));
                }
                return;
            }

            var span: u32 = range_leaf;
            while ((len + span - 1) / span > 64) span *= 64;
            var offset: u32 = 0;
            while (offset < len) : (offset += span) {
                const child_start = start + offset;
                const child_len = @min(span, len - offset);
                const child_end = child_start + child_len;
                const contains_focus = if (focused) |id| id >= child_start and id < child_end else false;
                if (projected_only and !contains_focus) continue;
                const first_live = snapshot.nextLive(child_start) orelse continue;
                if (first_live >= child_end) continue;
                var live: u32 = 0;
                var next: ?u32 = first_live;
                while (next) |id| : (next = snapshot.nextLive(id + 1)) {
                    if (id >= child_end) break;
                    live += 1;
                }
                const range: Range = .{
                    .kind = storeRangeKind(view),
                    .parent = 0,
                    .start = child_start,
                    .len = child_len,
                    .live = live,
                    .depth = depth,
                    .key_span = span,
                };
                try self.tree.rows.append(self.allocator, .{ .range = range });
                if (self.tree.expanded_ranges.contains(range.key())) {
                    try appendLiveRange(self, view, snapshot, child_start, child_len, depth +| 1, false);
                } else if (contains_focus) {
                    try appendLiveRange(self, view, snapshot, child_start, child_len, depth +| 1, true);
                }
            }
        }

        pub fn appendNameRows(self: *Explorer, name: u32, depth: u16, focused_chunk: ChunkId) std.mem.Allocator.Error!void {
            const children = self.tree_index.childrenOf(name);
            const chunks = self.tree_index.chunksOf(name);
            if (name != vm_tree.root_node_id and children.len == 0 and chunks.len == 1) {
                try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = chunks[0], .depth = depth, .label = name } });
                return;
            }
            const name_key = self.tree_index.stableKey(name);
            try self.tree.rows.append(self.allocator, .{ .name = .{
                .id = name,
                .key = name_key,
                .depth = depth,
            } });
            const next_depth = depth +| 1;
            if (!self.tree.expanded_names.contains(name_key)) {
                if (!self.tree.focus_path.contains(name)) return;
                for (children) |child| {
                    if (self.tree.focus_path.contains(child)) try appendNameRows(self, child, next_depth, focused_chunk);
                }
                if (self.tree_index.nodeForChunk(focused_chunk) == name and self.ev.getChunk(focused_chunk) != null) {
                    try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = focused_chunk, .depth = next_depth } });
                }
                return;
            }
            try appendNameRange(self, name, children, 0, @intCast(children.len), next_depth, focused_chunk);
            try appendChunkRange(self, name, chunks, 0, @intCast(chunks.len), next_depth, focused_chunk);
        }

        pub fn appendNameRange(
            self: *Explorer,
            parent: u32,
            children: []const u32,
            start: u32,
            len: u32,
            depth: u16,
            focused_chunk: ChunkId,
        ) std.mem.Allocator.Error!void {
            if (len == 0) return;
            if (len <= range_leaf) {
                for (children[start .. start + len]) |child| {
                    if (self.tree_index.statsOf(child).chunks == 0) continue;
                    try appendNameRows(self, child, depth, focused_chunk);
                }
                return;
            }

            const span: u32 = if (len > range_branch) range_branch else range_leaf;
            var offset: u32 = 0;
            while (offset < len) : (offset += span) {
                const range: Range = .{
                    .kind = .names,
                    .parent = parent,
                    .start = start + offset,
                    .len = @min(span, len - offset),
                    .live = @min(span, len - offset),
                    .depth = depth,
                    .stable_parent = self.tree_index.stableKey(parent),
                    .key_span = span,
                };
                try self.tree.rows.append(self.allocator, .{ .range = range });
                var contains_focus = false;
                for (children[range.start .. range.start + range.len]) |child| {
                    if (self.tree.focus_path.contains(child)) {
                        contains_focus = true;
                        break;
                    }
                }
                if (contains_focus or self.tree.expanded_ranges.contains(range.key())) {
                    try appendNameRange(self, parent, children, range.start, range.len, depth +| 1, focused_chunk);
                }
            }
        }

        pub fn appendChunkRange(
            self: *Explorer,
            parent: u32,
            chunks: []const ChunkId,
            start: u32,
            len: u32,
            depth: u16,
            focused_chunk: ChunkId,
        ) std.mem.Allocator.Error!void {
            if (len == 0) return;
            if (len <= range_leaf) {
                for (chunks[start .. start + len]) |id| {
                    try self.tree.rows.append(self.allocator, .{ .chunk = .{ .id = id, .depth = depth } });
                }
                return;
            }

            const span: u32 = if (len > range_branch) range_branch else range_leaf;
            var offset: u32 = 0;
            while (offset < len) : (offset += span) {
                const range: Range = .{
                    .kind = .chunks,
                    .parent = parent,
                    .start = start + offset,
                    .len = @min(span, len - offset),
                    .live = @min(span, len - offset),
                    .depth = depth,
                    .stable_parent = self.tree_index.stableKey(parent),
                    .key_span = span,
                };
                try self.tree.rows.append(self.allocator, .{ .range = range });
                const slice = chunks[range.start .. range.start + range.len];
                if (std.mem.indexOfScalar(ChunkId, slice, focused_chunk) != null or self.tree.expanded_ranges.contains(range.key())) {
                    try appendChunkRange(self, parent, chunks, range.start, range.len, depth +| 1, focused_chunk);
                }
            }
        }

        pub fn moveTree(self: *Explorer, forward: bool) void {
            const count = self.tree.rows.items.len;
            if (count == 0) return;
            self.preview.reset();
            if (forward) {
                self.navigation.tree_selection = @min(self.navigation.tree_selection + 1, count - 1);
            } else {
                self.navigation.tree_selection -|= 1;
            }
        }

        pub fn activateTreeRow(self: *Explorer) !void {
            if (self.navigation.tree_selection >= self.tree.rows.items.len) return;
            switch (self.tree.rows.items[self.navigation.tree_selection]) {
                .category => |entry| {
                    const index = @backingInt(entry.kind);
                    self.tree.categories[index] = !self.tree.categories[index];
                    try rebuildTreeForCurrent(self);
                    for (self.tree.rows.items, 0..) |row, i| switch (row) {
                        .category => |candidate| if (candidate.kind == entry.kind) {
                            self.navigation.tree_selection = i;
                            break;
                        },
                        else => {},
                    };
                },
                .name => |entry| {
                    if (self.tree.expanded_names.remove(entry.key)) {
                        // collapsed
                    } else {
                        try self.tree.expanded_names.put(self.allocator, entry.key, {});
                    }
                    try rebuildTreeForCurrent(self);
                    for (self.tree.rows.items, 0..) |row, i| switch (row) {
                        .name => |candidate| if (candidate.key == entry.key) {
                            self.navigation.tree_selection = i;
                            break;
                        },
                        else => {},
                    };
                },
                // Browsing the tree replaces the current view rather than pushing a
                // history entry (only followed reference links do that).
                .chunk => |entry| try Explorer.Ops.controller.openMode(self, .{ .chunk = entry.id }, .replace),
                .heap => |entry| {
                    // The overview is the only heap folder that opens a page (the
                    // aggregate census). Every store folder just expands into its
                    // records in place — expanding a folder shouldn't hijack the
                    // inspector with an unhelpful, cursorless store page.
                    if (entry.view == .overview) {
                        try Explorer.Ops.controller.openMode(self, .{ .heap = entry.view }, .replace);
                        return;
                    }
                    const opening = !self.tree.heap_views[@backingInt(entry.view)];
                    if (opening and entry.view == .objects and self.heap_index.objects == null) {
                        self.heap_index.objects = self.ev.heapObjectSnapshot(self.allocator) catch null;
                        if (self.heap_index.objects == null) self.status_msg = "(object index failed)";
                    }
                    self.tree.heap_views[@backingInt(entry.view)] = opening;
                    try rebuildTreeForCurrent(self);
                    for (self.tree.rows.items, 0..) |row, i| switch (row) {
                        .heap => |candidate| if (candidate.view == entry.view) {
                            self.navigation.tree_selection = i;
                            break;
                        },
                        else => {},
                    };
                },
                .object => |entry| try Explorer.Ops.controller.openMode(self, .{ .object = entry.id }, .replace),
                .store_record => |entry| try Explorer.Ops.controller.openMode(self, .{ .store_record = .{ .view = entry.view, .id = entry.id } }, .replace),
                .range => |range| {
                    if (!self.tree.expanded_ranges.remove(range.key())) try self.tree.expanded_ranges.put(self.allocator, range.key(), {});
                    try rebuildTreeForCurrent(self);
                    for (self.tree.rows.items, 0..) |row, i| switch (row) {
                        .range => |candidate| if (std.meta.eql(candidate.key(), range.key())) {
                            self.navigation.tree_selection = i;
                            break;
                        },
                        else => {},
                    };
                },
                .debug_frame => |entry| try Explorer.Ops.controller.openMode(self, .{ .debug_frame = entry.index }, .replace),
                .debug_value => try Explorer.Ops.controller.openMode(self, .debug_value, .replace),
                .debug_root => {},
            }
        }

        pub fn collapseTreeRow(self: *Explorer) !void {
            if (self.navigation.tree_selection >= self.tree.rows.items.len) return;
            const selected = self.tree.rows.items[self.navigation.tree_selection];
            const collapsed = switch (selected) {
                .category => |entry| blk: {
                    const index = @backingInt(entry.kind);
                    if (!self.tree.categories[index]) break :blk false;
                    self.tree.categories[index] = false;
                    break :blk true;
                },
                .name => |entry| self.tree.expanded_names.remove(entry.key),
                .range => |entry| self.tree.expanded_ranges.remove(entry.key()),
                .heap => |entry| blk: {
                    if (entry.view == .overview or !self.tree.heap_views[@backingInt(entry.view)])
                        break :blk false;
                    self.tree.heap_views[@backingInt(entry.view)] = false;
                    break :blk true;
                },
                else => false,
            };
            if (collapsed) {
                try rebuildTreeForCurrent(self);
                for (self.tree.rows.items, 0..) |row, i| if (vm_helpers.treeRowsEqual(row, selected)) {
                    self.navigation.tree_selection = i;
                    return;
                };
                return;
            }

            // Rows are preorder-flattened. The nearest preceding shallower row is
            // therefore the parent for every node kind: chunk, object, store value,
            // synthetic range, heap folder, name, and paused frame alike.
            const selected_depth = Explorer.Ops.tree_render.treeRowDepth(selected);
            var cursor = self.navigation.tree_selection;
            while (cursor > 0) {
                cursor -= 1;
                if (Explorer.Ops.tree_render.treeRowDepth(self.tree.rows.items[cursor]) < selected_depth) {
                    self.navigation.tree_selection = cursor;
                    return;
                }
            }
        }

        pub fn selectCurrentTreeSubject(self: *Explorer) void {
            for (self.tree.rows.items, 0..) |row, i| {
                const matches = switch (row) {
                    .chunk => |entry| if (Explorer.Ops.view_state.currentChunk(self)) |id| entry.id == id else false,
                    .object => |entry| if (Explorer.Ops.view_state.currentObject(self)) |id| entry.id == id else false,
                    .store_record => |entry| if (Explorer.Ops.view_state.currentStoreRecord(self)) |record|
                        entry.view == record.view and entry.id == record.id
                    else
                        false,
                    .heap => |entry| if (Explorer.Ops.view_state.currentHeap(self)) |view| entry.view == view else false,
                    .debug_frame => |entry| if (Explorer.Ops.view_state.currentDebugFrame(self)) |index| entry.index == index else false,
                    .debug_value => Explorer.Ops.view_state.currentKind(self) == .debug_value,
                    else => false,
                };
                if (matches) {
                    self.navigation.tree_selection = i;
                    return;
                }
            }
        }

        pub fn selectedTreeRowIsCurrentSubject(self: *const Explorer) bool {
            if (self.navigation.tree_selection >= self.tree.rows.items.len) return false;
            return switch (self.tree.rows.items[self.navigation.tree_selection]) {
                .chunk => |entry| Explorer.Ops.view_state.currentChunk(self) == entry.id,
                .object => |entry| Explorer.Ops.view_state.currentObject(self) == entry.id,
                .store_record => |entry| if (Explorer.Ops.view_state.currentStoreRecord(self)) |record|
                    record.view == entry.view and record.id == entry.id
                else
                    false,
                .heap => |entry| Explorer.Ops.view_state.currentHeap(self) == entry.view,
                .debug_frame => |entry| Explorer.Ops.view_state.currentDebugFrame(self) == entry.index,
                .debug_value => Explorer.Ops.view_state.currentKind(self) == .debug_value,
                else => false,
            };
        }

        pub fn treeSelectionCanMoveUp(self: *const Explorer) bool {
            if (self.navigation.tree_selection >= self.tree.rows.items.len) return false;
            const row = self.tree.rows.items[self.navigation.tree_selection];
            if (Explorer.Ops.tree_render.treeRowDepth(row) > 0) return true;
            return switch (row) {
                .category => |entry| self.tree.categories[@backingInt(entry.kind)],
                .name => |entry| self.tree.expanded_names.contains(entry.key),
                .range => |entry| self.tree.expanded_ranges.contains(entry.key()),
                .heap => |entry| entry.view != .overview and self.tree.heap_views[@backingInt(entry.view)],
                else => false,
            };
        }
    };
}
