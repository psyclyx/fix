//! Internal VM explorer component.
//!
//! Methods are parameterized by the private explorer state type and wired as
//! direct aliases by `operations.zig`; this module owns the behavior below.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const width_mod = @import("../width.zig");
const vm_tree = @import("tree.zig");
const vm_model = @import("model.zig");
const vm_source = @import("source.zig");
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
const BreakpointLocation = vm_source.Location;
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

pub fn Methods(comptime Explorer: type) type {
    return struct {
        pub fn drawFocusDivider(self: *Explorer, frame: *tui.Frame, row: usize, col: usize, focused: bool) !void {
            _ = self;
            try frame.at(row, col);
            try frame.text(if (focused) "┃" else "│", 0, 1, if (focused) .section else .border);
        }

        pub fn drawTranscript(self: *Explorer, frame: *tui.Frame, first_row: usize, rows: usize, cols: usize, text: []const u8) !void {
            const shown = @min(rows, self.transcript_lines.items.len);
            const first_line = self.transcript_lines.items.len -| shown;
            const top_padding = rows -| shown;
            for (0..rows) |row| {
                try frame.clearRow(first_row + row);
                if (row < top_padding) continue;
                const range = self.transcript_lines.items[first_line + row - top_padding];
                const line = std.mem.trimEnd(u8, text[range.start..range.end], "\r");
                try frame.at(first_row + row, 1);
                try frame.text(line, 0, cols, .plain);
            }
        }

        pub fn drawDisasmRow(self: *Explorer, frame: *tui.Frame, row: usize, width: usize) !void {
            const idx = self.navigation.scroll + row;
            if (idx < self.page.lines.len) {
                const selected = idx == self.navigation.detail_selection and self.navigation.focus == .subject and Explorer.Ops.controller.rowActionable(self, idx);
                const breakpoint = idx < self.page.locations.len and if (self.page.locations[idx]) |location| hasBreakpoint(self, location) else false;
                if ((selected or breakpoint) and width >= 2) {
                    try frame.text(if (selected and breakpoint) "◆ " else if (selected) "› " else "● ", 0, 2, if (selected) .selection_marker else .current);
                    try frame.text(self.page.lines[idx], self.navigation.x_scroll, width - 2, detailRole(self, idx));
                } else {
                    try frame.text(self.page.lines[idx], self.navigation.x_scroll, width, detailRole(self, idx));
                }
            } else if (idx == self.page.lines.len and self.page.lines.len != 0) {
                try frame.text("(end)", 0, width, .muted);
            }
        }

        pub fn hasBreakpoint(self: *const Explorer, location: BreakpointLocation) bool {
            if (location.span) |span| return self.ev.breakpointSpan(location.chunk_id, span);
            return self.ev.breakpointAt(location.chunk_id, location.offset);
        }

        pub fn detailRole(self: *const Explorer, index: usize) tui.Role {
            if (index < self.page.actions.len) switch (self.page.actions[index]) {
                .section, .source => return .section,
                .chunk => return .chunk,
                .object, .store_record => return .object,
                .none, .instruction => {},
            };
            return .plain;
        }

        pub const TreeViewport = struct {
            pinned: [64]usize = undefined,
            pin_count: usize = 0,
            start: usize = 0,

            pub fn index(self: *const TreeViewport, slot: usize) ?usize {
                if (slot < self.pin_count) return self.pinned[slot];
                return self.start + slot - self.pin_count;
            }
        };

        pub fn treeRowDepth(row: TreeRow) u16 {
            return switch (row) {
                .category => |entry| entry.depth,
                .name => |entry| entry.depth,
                .chunk => |entry| entry.depth,
                .range => |entry| entry.depth,
                .heap => |entry| entry.depth,
                .object => |entry| entry.depth,
                .store_record => |entry| entry.depth,
                .debug_root => |entry| entry.depth,
                .debug_frame => |entry| entry.depth,
                .debug_value => |entry| entry.depth,
            };
        }

        pub fn treeViewport(self: *const Explorer, slots: usize) TreeViewport {
            var result: TreeViewport = .{};
            const count = self.tree.rows.items.len;
            if (slots == 0 or count == 0) return result;

            var normal_slots = slots;
            var pass: usize = 0;
            while (pass < 2) : (pass += 1) {
                result.start = @min(self.navigation.tree_selection -| (normal_slots / 2), count -| normal_slots);
                var hidden_nearest: [64]usize = undefined;
                const hidden_count = hiddenTreeAncestors(self, result.start, &hidden_nearest);
                result.pin_count = @min(@min(hidden_count, hidden_nearest.len), slots -| 1);
                var i: usize = 0;
                while (i < result.pin_count) : (i += 1) {
                    result.pinned[i] = hidden_nearest[result.pin_count - i - 1];
                }
                normal_slots = slots - result.pin_count;
            }
            result.start = @min(self.navigation.tree_selection -| (normal_slots / 2), count -| normal_slots);
            return result;
        }

        /// Collect off-screen ancestors nearest-first. Keeping the nearest entries
        /// means very deep trees degrade into a useful partial breadcrumb.
        pub fn hiddenTreeAncestors(self: *const Explorer, start: usize, out: *[64]usize) usize {
            if (self.navigation.tree_selection >= self.tree.rows.items.len) return 0;
            var wanted_depth = treeRowDepth(self.tree.rows.items[self.navigation.tree_selection]);
            var cursor = self.navigation.tree_selection;
            var count: usize = 0;
            while (cursor > 0 and wanted_depth > 0) {
                cursor -= 1;
                const depth = treeRowDepth(self.tree.rows.items[cursor]);
                if (depth >= wanted_depth) continue;
                if (cursor < start and count < out.len) {
                    out[count] = cursor;
                    count += 1;
                }
                wanted_depth = depth;
            }
            return count;
        }

        pub const TreeCell = struct {
            index: usize,
            segment: usize,
            pinned: bool,
            wrapped: bool,
        };

        /// Map one physical sidebar row to a logical tree row. Selected rows and
        /// pinned breadcrumbs may consume several rows; ordinary rows stay one
        /// line and are middle-ellipsized by the renderer below.
        pub fn treeCell(self: *const Explorer, slot: usize, width: usize, slots: usize) ?TreeCell {
            const viewport = treeViewport(self, slots);
            var pin_start: usize = 0;
            var pin_height: usize = 0;
            for (viewport.pinned[0..viewport.pin_count]) |index| pin_height += treeDisplayHeight(self, index, width, slots, true);
            const selected_height = treeDisplayHeight(self, self.navigation.tree_selection, width, slots, false);
            while (pin_start < viewport.pin_count and pin_height + selected_height > slots) : (pin_start += 1) {
                pin_height -|= treeDisplayHeight(self, viewport.pinned[pin_start], width, slots, true);
            }

            var normal_start = viewport.start;
            var before_selected = self.navigation.tree_selection -| normal_start;
            while (normal_start < self.navigation.tree_selection and pin_height + before_selected + selected_height > slots) {
                normal_start += 1;
                before_selected -|= 1;
            }

            var physical: usize = 0;
            for (viewport.pinned[pin_start..viewport.pin_count]) |index| {
                const height = treeDisplayHeight(self, index, width, slots, true);
                if (slot < physical + height) return .{
                    .index = index,
                    .segment = slot - physical,
                    .pinned = true,
                    .wrapped = height > 1,
                };
                physical += height;
            }

            var index = normal_start;
            while (index < self.tree.rows.items.len and physical < slots) : (index += 1) {
                const height = treeDisplayHeight(self, index, width, slots, false);
                if (slot < physical + height) return .{
                    .index = index,
                    .segment = slot - physical,
                    .pinned = false,
                    .wrapped = height > 1,
                };
                physical += height;
            }
            return null;
        }

        pub fn treeSelectionSlot(self: *const Explorer, width: usize, slots: usize) ?usize {
            for (0..slots) |slot| {
                const cell = treeCell(self, slot, width, slots) orelse continue;
                if (cell.index == self.navigation.tree_selection and cell.segment == 0)
                    return slot;
            }
            return null;
        }

        pub fn treeDisplayHeight(self: *const Explorer, index: usize, width: usize, slots: usize, pinned: bool) usize {
            if (index >= self.tree.rows.items.len or width < 8) return 1;
            const selected = index == self.navigation.tree_selection and self.navigation.focus == .tree;
            if (!pinned and !selected) return 1;
            const content_width = longTreeContentWidth(self, self.tree.rows.items[index]) orelse return 1;
            const prefix = @min(1 + @as(usize, treeRowDepth(self.tree.rows.items[index])) * 2 + 2, width - 1);
            const available = width - prefix;
            const height = @max(@as(usize, 1), (content_width + available - 1) / available);
            const limit = if (pinned) @max(@as(usize, 2), @min(@as(usize, 3), slots / 3)) else @max(@as(usize, 2), slots / 2);
            return @min(height, limit);
        }

        /// Width after indentation/marker for the node rows whose labels may be
        /// arbitrarily long. Other row kinds never need multiline treatment.
        pub fn longTreeContentWidth(self: *const Explorer, row: TreeRow) ?usize {
            var suffix_buf: [96]u8 = undefined;
            var relation_buf: [96]u8 = undefined;
            return switch (row) {
                .name => |entry| blk: {
                    const node = self.tree_index.node(entry.id) orelse return null;
                    const suffix = std.fmt.bufPrint(&suffix_buf, "  {d}", .{self.tree_index.statsOf(entry.id).chunks}) catch "";
                    break :blk width_mod.strWidth(node.label) + width_mod.strWidth(suffix);
                },
                .chunk => |entry| if (entry.label) |node_id| blk: {
                    const node = self.tree_index.node(node_id) orelse return null;
                    const chunk = self.ev.getChunk(entry.id) orelse return null;
                    const relation = Explorer.Ops.pages.chunkEquivalenceSuffix(self, &relation_buf, entry.id);
                    const suffix = std.fmt.bufPrint(&suffix_buf, "  chunk[0x{x}] · {Bi}{s}", .{ entry.id, chunk.code.len, relation }) catch "";
                    break :blk width_mod.strWidth(node.label) + width_mod.strWidth(suffix);
                } else null,
                else => null,
            };
        }

        pub fn drawTreeHeader(self: *Explorer, frame: *tui.Frame, row: usize, width: usize) !bool {
            var line_buf: [512]u8 = undefined;
            switch (row) {
                0 => {
                    const root_stats = self.tree_index.statsOf(vm_tree.root_node_id);
                    const heap_counts = self.ev.heapCounts();
                    const line = if (Explorer.Ops.tree_projection.filterActive(self))
                        std.fmt.bufPrint(&line_buf, " VM STATE · filter '{s}' · F edit · Esc clear", .{self.tree.filter_query.items}) catch " VM STATE · filtered"
                    else
                        std.fmt.bufPrint(&line_buf, " VM STATE · {d} chunks · {d} object slots", .{ root_stats.chunks, heap_counts.objects }) catch " VM STATE";
                    try frame.text(line, 0, width, if (Explorer.Ops.tree_projection.filterActive(self)) .source_focus else .section);
                },
                1 => {
                    const id = Explorer.Ops.view_state.currentChunk(self) orelse {
                        if (Explorer.Ops.view_state.currentObject(self)) |object_id| {
                            const line = std.fmt.bufPrint(&line_buf, " ● objects[0x{x}]", .{object_id}) catch " object";
                            try frame.text(line, 0, width, .object);
                        } else if (Explorer.Ops.view_state.currentHeap(self)) |view| {
                            const line = std.fmt.bufPrint(&line_buf, " ● heap/{s}", .{@tagName(view)}) catch " heap";
                            try frame.text(line, 0, width, .section);
                        } else if (Explorer.Ops.view_state.currentStoreRecord(self)) |record| {
                            const line = std.fmt.bufPrint(&line_buf, " ● {s}[0x{x}]", .{
                                @tagName(record.view),
                                record.id,
                            }) catch " store record";
                            try frame.text(line, 0, width, .object);
                        } else if (self.debug_session) |session| {
                            const line = std.fmt.bufPrint(&line_buf, " ◆ paused/{s}", .{vm_helpers.reasonName(session.reason)}) catch " paused";
                            try frame.text(line, 0, width, .current);
                        } else {
                            try frame.text(" help", 0, width, .muted);
                        }
                        return true;
                    };
                    var relation_buf: [96]u8 = undefined;
                    const relation = Explorer.Ops.pages.chunkEquivalenceSuffix(self, &relation_buf, id);
                    const line = if (self.ev.getChunk(id)) |chunk|
                        std.fmt.bufPrint(&line_buf, " ● chunk[0x{x}]  {d}b · {d}c · a{d}{s}", .{ id, chunk.code.len, chunk.constants.len, chunk.arity, relation }) catch " current chunk"
                    else
                        std.fmt.bufPrint(&line_buf, " ● chunk[0x{x}]  missing", .{id}) catch " current chunk";
                    try frame.text(line, 0, width, .chunk_current);
                },
                2 => try frame.text(" ─ runtime state ─", 0, width, .muted),
                else => return false,
            }
            return true;
        }

        pub fn drawChunkRow(self: *Explorer, arena: std.mem.Allocator, frame: *tui.Frame, row: usize, width: usize, rows: usize) !void {
            var line_buf: [512]u8 = undefined;
            if (try drawTreeHeader(self, frame, row, width)) return;

            const count = self.tree.rows.items.len;
            if (count == 0) {
                if (row == 3) try frame.text("   empty registry", 0, width, .muted);
                return;
            }
            const slots = rows -| 3;
            if (slots == 0) return;
            const slot = row - 3;
            const cell = treeCell(self, slot, width, slots) orelse return;
            const index = cell.index;
            if (index >= count) return;
            const pinned = cell.pinned;
            const selected = index == self.navigation.tree_selection;
            const line: []const u8 = switch (self.tree.rows.items[index]) {
                .category => |entry| blk: {
                    const is_open = self.tree.categories[@backingInt(entry.kind)];
                    const projected = !is_open and switch (entry.kind) {
                        .bytecode => Explorer.Ops.view_state.currentChunk(self) != null,
                        .heap => Explorer.Ops.view_state.currentObject(self) != null,
                    };
                    break :blk switch (entry.kind) {
                        .bytecode => blk2: {
                            const stats = self.tree_index.statsOf(vm_tree.root_node_id);
                            break :blk2 std.fmt.bufPrint(&line_buf, " {s} BYTECODE  {d} chunks", .{ if (is_open) "▾" else if (projected) "›" else "▸", stats.chunks }) catch " bytecode";
                        },
                        .heap => blk2: {
                            const counts = self.ev.heapCounts();
                            break :blk2 std.fmt.bufPrint(&line_buf, " {s} HEAP - {d} slots", .{ if (is_open) "▾" else if (projected) "›" else "▸", counts.objects }) catch " heap";
                        },
                    };
                },
                .name => |entry| blk: {
                    const stats = self.tree_index.statsOf(entry.id);
                    var indent: [64]u8 = undefined;
                    const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                    @memset(indent[0..indent_len], ' ');
                    const label = if (entry.id == vm_tree.root_node_id)
                        "<root>"
                    else if (self.tree_index.node(entry.id)) |node|
                        node.label
                    else
                        "?";
                    break :blk try std.fmt.allocPrint(arena, " {s}{s} {s}  {d}", .{
                        indent[0..indent_len],
                        if (self.tree.expanded_names.contains(entry.key)) "▾" else if (self.tree.focus_path.contains(entry.id)) "›" else "▸",
                        label,
                        stats.chunks,
                    });
                },
                .chunk => |entry| blk: {
                    var indent: [64]u8 = undefined;
                    const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                    @memset(indent[0..indent_len], ' ');
                    const chunk = self.ev.getChunk(entry.id);
                    const label = if (entry.label) |node_id| (self.tree_index.node(node_id) orelse return).label else "";
                    var relation_buf: [96]u8 = undefined;
                    const relation = Explorer.Ops.pages.chunkEquivalenceSuffix(self, &relation_buf, entry.id);
                    break :blk if (chunk) |ch|
                        if (label.len > 0)
                            try std.fmt.allocPrint(arena, " {s}{s} {s}  chunk[0x{x}] · {Bi}{s}", .{
                                indent[0..indent_len],
                                if (Explorer.Ops.view_state.currentChunk(self) == entry.id) "●" else "·",
                                label,
                                entry.id,
                                ch.code.len,
                                relation,
                            })
                        else
                            std.fmt.bufPrint(&line_buf, " {s}{s} chunk[0x{x}]  {Bi}{s}", .{
                                indent[0..indent_len],
                                if (Explorer.Ops.view_state.currentChunk(self) == entry.id) "●" else "·",
                                entry.id,
                                ch.code.len,
                                relation,
                            }) catch " chunk"
                    else
                        std.fmt.bufPrint(&line_buf, " {s}! chunk[0x{x}] missing", .{ indent[0..indent_len], entry.id }) catch " missing";
                },
                .range => |entry| blk: {
                    var indent: [64]u8 = undefined;
                    const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                    @memset(indent[0..indent_len], ' ');
                    const is_open = self.tree.expanded_ranges.contains(entry.key());
                    break :blk switch (entry.kind) {
                        .names => std.fmt.bufPrint(&line_buf, " {s}{s} names {d}–{d}", .{
                            indent[0..indent_len],
                            if (is_open) "▾" else "▸",
                            entry.start + 1,
                            entry.start + entry.len,
                        }) catch " name range",
                        .chunks => blk2: {
                            const chunks = self.tree_index.chunksOf(entry.parent);
                            const first = chunks[entry.start];
                            const last = chunks[entry.start + entry.len - 1];
                            break :blk2 std.fmt.bufPrint(&line_buf, " {s}{s} chunks[0x{x}:0x{x}] ({d})", .{
                                indent[0..indent_len],
                                if (is_open) "▾" else "▸",
                                first,
                                last + 1,
                                entry.live,
                            }) catch " chunk range";
                        },
                        .objects => blk2: {
                            const reference = try Explorer.Ops.value_summary.canonicalStoreRange(
                                self,
                                arena,
                                .objects,
                                entry.start,
                                entry.start + entry.len,
                                entry.live,
                                !(selected and self.navigation.focus == .tree),
                            );
                            break :blk2 try std.fmt.allocPrint(arena, " {s}{s} {s}", .{
                                indent[0..indent_len],
                                if (is_open) "▾" else if (Explorer.Ops.view_state.currentObject(self)) |id| (if (id >= entry.start and id < entry.start + entry.len) "›" else "▸") else "▸",
                                reference,
                            });
                        },
                        .values, .attrs, .attr_positions, .intern, .builtin => blk2: {
                            const view: HeapView = switch (entry.kind) {
                                .values => .values,
                                .attrs => .attrs,
                                .attr_positions => .attr_positions,
                                .intern => .intern,
                                .builtin => .builtin,
                                else => unreachable,
                            };
                            const reference = try Explorer.Ops.value_summary.canonicalStoreRange(
                                self,
                                arena,
                                view,
                                entry.start,
                                entry.start + entry.len,
                                entry.live,
                                !(selected and self.navigation.focus == .tree),
                            );
                            break :blk2 try std.fmt.allocPrint(arena, " {s}{s} {s}", .{
                                indent[0..indent_len],
                                if (is_open) "▾" else "▸",
                                reference,
                            });
                        },
                    };
                },
                .heap => |entry| blk: {
                    var indent: [64]u8 = undefined;
                    const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                    @memset(indent[0..indent_len], ' ');
                    const projected = (entry.view == .objects and Explorer.Ops.view_state.currentObject(self) != null) or
                        (if (Explorer.Ops.view_state.currentStoreRecord(self)) |r| r.view == entry.view else false);
                    const marker = if (entry.view == .overview)
                        "·"
                    else if (self.tree.heap_views[@backingInt(entry.view)])
                        "▾"
                    else if (projected)
                        "›"
                    else
                        "▸";
                    const snapshot = if (entry.view == .objects)
                        (if (self.heap_index.objects) |*s| s else null)
                    else
                        Explorer.Ops.view_state.ensureStoreSnapshot(self, entry.view);
                    if (entry.view == .objects and snapshot == null) {
                        break :blk if (self.heap_index.stats) |stats|
                            try std.fmt.allocPrint(arena, " {s}{s} objects · {d} live", .{
                                indent[0..indent_len],
                                marker,
                                Explorer.Ops.view_state.liveObjectCount(stats),
                            })
                        else
                            try std.fmt.allocPrint(arena, " {s}{s} objects", .{
                                indent[0..indent_len],
                                marker,
                            });
                    }
                    const extent = if (snapshot) |s| s.liveExtent() else Explorer.Ops.view_state.storeCount(self, entry.view);
                    const live = if (snapshot) |s| s.live_count else Explorer.Ops.view_state.storeCount(self, entry.view);
                    const reference = try Explorer.Ops.value_summary.canonicalStoreRange(
                        self,
                        arena,
                        entry.view,
                        0,
                        extent,
                        live,
                        !(selected and self.navigation.focus == .tree),
                    );
                    break :blk try std.fmt.allocPrint(arena, " {s}{s} {s}", .{
                        indent[0..indent_len],
                        marker,
                        reference,
                    });
                },
                .object => |entry| blk: {
                    var indent: [64]u8 = undefined;
                    const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                    @memset(indent[0..indent_len], ' ');
                    const ref_width = width -| indent_len -| 4;
                    const preview = try Explorer.Ops.value_summary.objectSummary(
                        self,
                        arena,
                        entry.id,
                        Explorer.Ops.value_summary.storePreviewBudget(self, "objects", entry.id, ref_width),
                    );
                    const reference = try Explorer.Ops.value_summary.canonicalStoreRef(
                        self,
                        arena,
                        .objects,
                        entry.id,
                        preview,
                        !(selected and self.navigation.focus == .tree),
                    );
                    break :blk try std.fmt.allocPrint(arena, " {s}{s} {s}", .{
                        indent[0..indent_len],
                        if (Explorer.Ops.view_state.currentObject(self) == entry.id) "●" else "·",
                        reference,
                    });
                },
                .store_record => |entry| blk: {
                    var indent: [64]u8 = undefined;
                    const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                    @memset(indent[0..indent_len], ' ');
                    const current = if (Explorer.Ops.view_state.currentStoreRecord(self)) |r| (r.view == entry.view and r.id == entry.id) else false;
                    const ref_width = width -| indent_len -| 4;
                    const detail = try Explorer.Ops.value_summary.storeRecordSummary(
                        self,
                        arena,
                        entry.view,
                        entry.id,
                        Explorer.Ops.value_summary.storePreviewBudget(self, @tagName(entry.view), entry.id, ref_width),
                    );
                    const reference = try Explorer.Ops.value_summary.canonicalStoreRef(
                        self,
                        arena,
                        entry.view,
                        entry.id,
                        detail,
                        !(selected and self.navigation.focus == .tree),
                    );
                    break :blk try std.fmt.allocPrint(arena, " {s}{s} {s}", .{
                        indent[0..indent_len],
                        if (current) "●" else "·",
                        reference,
                    });
                },
                .debug_root => blk: {
                    const reason = if (self.debug_session) |s| vm_helpers.reasonName(s.reason) else "paused";
                    break :blk std.fmt.bufPrint(&line_buf, " ◆ PAUSE · {s}", .{reason}) catch " ◆ PAUSE";
                },
                .debug_frame => |entry| blk: {
                    const session = self.debug_session orelse break :blk " (frame)";
                    if (entry.index >= session.frameCount()) break :blk " (frame gone)";
                    const info = session.frame(entry.index);
                    var name: std.Io.Writer.Allocating = .init(arena);
                    if (session.hasFrameName(entry.index)) session.writeFrameName(&name.writer, entry.index) catch {};
                    var indent: [64]u8 = undefined;
                    const indent_len = @min(@as(usize, entry.depth) * 2, indent.len);
                    @memset(indent[0..indent_len], ' ');
                    break :blk try std.fmt.allocPrint(arena, " {s}{s} #{d} {s}:{d} {s}", .{
                        indent[0..indent_len],
                        if (Explorer.Ops.view_state.currentDebugFrame(self) == entry.index) "●" else "·",
                        entry.index,
                        if (info.file) |f| std.fs.path.basename(f) else "<repl>",
                        info.line,
                        name.written(),
                    });
                },
                .debug_value => blk: {
                    const session = self.debug_session orelse break :blk " value";
                    const v = session.value;
                    const label = vm_helpers.returnValueHeading(session.reason);
                    const detail = try Explorer.Ops.value_summary.valueSummary(self, arena, v, width -| 24);
                    break :blk try std.fmt.allocPrint(arena, " ↳ {s}: {s}", .{ label, detail });
                },
            };
            const role: tui.Role = if (selected and self.navigation.focus == .tree)
                .selection
            else if (pinned)
                .muted
            else switch (self.tree.rows.items[index]) {
                .category => .section,
                .name => .name,
                // Chunks keep their own hue whether or not they're the open one; the
                // `●` marker (not a color change) signals which is current.
                .chunk => |entry| if (Explorer.Ops.view_state.currentChunk(self) == entry.id) .chunk_current else .chunk,
                .range => .range,
                .object => |entry| if (Explorer.Ops.view_state.currentObject(self) == entry.id) .chunk_current else .object,
                .store_record => |entry| if (Explorer.Ops.view_state.currentStoreRecord(self)) |r| (if (r.view == entry.view and r.id == entry.id) .chunk_current else .object) else .object,
                .heap => |entry| switch (Explorer.Ops.view_state.currentKind(self)) {
                    .heap => |view| if (view == entry.view) .section else .name,
                    else => .name,
                },
                .debug_root => .section,
                // A live paused frame is genuine current execution — green stays apt.
                .debug_frame => |entry| if (Explorer.Ops.view_state.currentDebugFrame(self) == entry.index) .current else .name,
                // The pause's return/break/error value stands out (gold, bold).
                .debug_value => .source_focus,
            };
            if (cell.wrapped) {
                const prefix_width = @min(1 + @as(usize, treeRowDepth(self.tree.rows.items[index])) * 2 + 2, width -| 1);
                if (cell.segment == 0) {
                    try frame.text(line, 0, width, role);
                } else if (prefix_width < width) {
                    const indent = try arena.alloc(u8, prefix_width);
                    @memset(indent, ' ');
                    try frame.text(indent, 0, prefix_width, role);
                    const available = width - prefix_width;
                    const start = prefix_width + cell.segment * (width - prefix_width);
                    try frame.text(line, start, available, role);
                }
            } else {
                const ansi_identity = switch (self.tree.rows.items[index]) {
                    .object, .store_record, .heap => !(selected and self.navigation.focus == .tree),
                    .range => |entry| switch (entry.kind) {
                        .objects, .values, .attrs, .attr_positions, .intern, .builtin => !(selected and self.navigation.focus == .tree),
                        else => false,
                    },
                    else => false,
                };
                if (ansi_identity) {
                    const line_width = tui.displayWidth(line, width_mod.cpWidth);
                    try frame.text(line, 0, width -| @intFromBool(line_width > width), role);
                    if (line_width > width and width > 0) {
                        try frame.text("…", 0, 1, role);
                    }
                } else {
                    const shown = try width_mod.middleEllipsis(arena, line, width);
                    try frame.text(shown, 0, width, role);
                }
            }
        }
    };
}
