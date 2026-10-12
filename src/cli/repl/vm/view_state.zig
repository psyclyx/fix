//! Internal VM explorer component.
//!
//! Methods are parameterized by the private explorer state type and wired as
//! direct aliases by `operations.zig`; this module owns the behavior below.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");
const vm_model = @import("model.zig");
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

pub const Layout = struct {
    cols: usize,
    rows: usize,
    body_rows: usize,
    split: bool,
    sidebar_width: usize,
    main_col: usize,
    main_width: usize,
};

pub fn Methods(comptime Explorer: type) type {
    return struct {
        // -- navigation ------------------------------------------------------------

        pub fn layout(self: *const Explorer) Layout {
            const cols = @max(@as(usize, 1), self.viewport.cols);
            const body_rows = self.viewport.rows;
            const split = cols >= 96;
            const sidebar_width = if (split) @max(cols * 3 / 10, 28) else 0;
            const inspector_width = if (split) cols - sidebar_width - 1 else cols;
            const main_col = if (split) sidebar_width + 2 else 1;
            return .{
                .cols = cols,
                .rows = body_rows + 2,
                .body_rows = body_rows,
                .split = split,
                .sidebar_width = sidebar_width,
                .main_col = main_col,
                .main_width = inspector_width,
            };
        }

        /// The chunk/object referenced by the selected detail row (for the
        /// right-hand preview), or null when there's nothing to peek into.
        pub fn detailPreviewAction(self: *const Explorer) ?RowAction {
            if (self.navigation.focus != .subject) return null;
            const kind = currentKind(self);
            const is_value_subject = switch (kind) {
                .object, .store_record, .debug_value, .debug_frame => true,
                else => false,
            };
            if (!is_value_subject) return null;
            const idx = self.navigation.detail_selection;
            if (idx >= self.page.actions.len) return null;
            return switch (self.page.actions[idx]) {
                .object, .chunk, .store_record => self.page.actions[idx],
                else => null,
            };
        }

        pub fn currentKind(self: *const Explorer) Visit.Kind {
            return self.navigation.back.items[self.navigation.back.items.len - 1].kind;
        }

        pub fn currentChunk(self: *const Explorer) ?ChunkId {
            return switch (currentKind(self)) {
                .chunk => |id| id,
                .heap, .object, .store_record, .debug_frame, .debug_value, .help => null,
            };
        }

        /// The paused stack frame currently open in the inspector, if any.
        pub fn currentDebugFrame(self: *const Explorer) ?usize {
            return switch (currentKind(self)) {
                .debug_frame => |i| i,
                else => null,
            };
        }

        pub fn currentHeap(self: *const Explorer) ?HeapView {
            return switch (currentKind(self)) {
                .heap => |view| view,
                else => null,
            };
        }

        pub fn currentObject(self: *const Explorer) ?runtime.types.ObjectId {
            return switch (currentKind(self)) {
                .object => |id| id,
                else => null,
            };
        }

        pub const StoreRecord = struct { view: HeapView, id: u32 };

        pub fn currentStoreRecord(self: *const Explorer) ?StoreRecord {
            return switch (currentKind(self)) {
                .store_record => |r| .{ .view = r.view, .id = r.id },
                else => null,
            };
        }

        pub fn liveObjectCount(stats: runtime.ObjectHeap.Stats) u32 {
            var total: u32 = 0;
            for (stats.variant_counts) |count| total += count;
            return total;
        }

        pub fn storeCount(self: *const Explorer, view: HeapView) u32 {
            const c = self.ev.heapCounts();
            return switch (view) {
                .overview, .objects => c.objects,
                .values => c.values,
                .attrs => c.attrs,
                .attr_positions => c.attr_positions,
                .intern => self.ev.internTable().stats().entries,
                .builtin => @intCast(@typeInfo(runtime.builtins.BuiltinId).@"enum".field_names.len),
            };
        }

        /// The number of LIVE records in a store (via its snapshot), falling back to
        /// the raw reserved count if the snapshot can't be built.
        pub fn liveStoreCount(self: *Explorer, view: HeapView) u32 {
            if (view == .intern or view == .builtin) return storeCount(self, view);
            if (view == .objects or view == .overview)
                return if (self.heap_index.objects) |*s| s.live_count else if (self.heap_index.stats) |stats| liveObjectCount(stats) else 0;
            return if (ensureStoreSnapshot(self, view)) |s| s.live_count else storeCount(self, view);
        }

        /// The live-slot snapshot for a store, (re)built lazily when its slot count
        /// changes so browsing shows only real records, not reserved capacity.
        pub fn ensureStoreSnapshot(self: *Explorer, view: HeapView) ?*const runtime.ObjectHeap.ObjectSnapshot {
            const slot: *?runtime.ObjectHeap.ObjectSnapshot, const cnt: *u32 = switch (view) {
                .values => .{ &self.heap_index.values, &self.heap_index.values_count },
                .attrs => .{ &self.heap_index.attrs, &self.heap_index.attrs_count },
                .attr_positions => .{ &self.heap_index.attr_positions, &self.heap_index.attr_positions_count },
                .overview, .objects, .intern, .builtin => return null,
            };
            const current = storeCount(self, view);
            if (slot.* == null or cnt.* != current) {
                if (slot.*) |*s| s.deinit();
                slot.* = (switch (view) {
                    .values => self.ev.heapValueSnapshot(self.allocator),
                    .attrs => self.ev.heapAttrSnapshot(self.allocator),
                    .attr_positions => self.ev.heapAttrPosSnapshot(self.allocator),
                    else => unreachable,
                }) catch {
                    slot.* = null;
                    return null;
                };
                cnt.* = current;
            }
            return if (slot.*) |*s| s else null;
        }
    };
}
