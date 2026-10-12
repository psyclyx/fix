//! Canonical outgoing-edge walk for runtime heap objects.
//!
//! Object layout changes must be reflected exactly once, here. Consumers
//! provide policy through a sink: the collector queues physical ranges, GC
//! validators check the referenced values, and inspection records direct
//! object/chunk references without forcing or recursively walking children.

const std = @import("std");
const heap_mod = @import("../heap.zig");
const future_mod = @import("../future.zig");
const thunk_mod = @import("../thunk.zig");
const Value = @import("../value.zig").Value;

const ObjectHeap = heap_mod.ObjectHeap;
const ObjectId = heap_mod.ObjectId;
const FutureState = future_mod.FutureState;

/// Visit the slot accounting, owned side-store ranges, and direct graph edges
/// of one object. `Sink.Error` may be `error{}` for infallible hot paths.
pub fn walkObject(
    comptime Sink: type,
    sink: *Sink,
    heap: *const ObjectHeap,
    id: ObjectId,
) Sink.Error!void {
    try sink.objectSlot();
    const object = heap.objects.get(id);
    switch (object.*) {
        .list => |range| try sink.valueRange(heap, range),
        .attrs => |attrs| {
            try sink.attrRange(heap, attrs.range);
            try sink.attrPositions(attrs.positions);
        },
        .merge_attrs => |merge| {
            try sink.object(heap, merge.base);
            try sink.object(heap, merge.overlay);
            const flattened = merge.flattened.load(.acquire);
            if (flattened != heap_mod.no_flattened_attrs)
                try sink.object(heap, flattened);
        },
        .closure => |closure| {
            try sink.chunk(closure.chunk_id);
            try sink.valueRange(heap, closure.upvalues);
        },
        .builtin_closure => |closure| try sink.valueRange(heap, closure.args),
        .partial_app => |partial| {
            try sink.value(heap, partial.func);
            try sink.valueRange(heap, partial.args);
        },
        .context_string => |string| try sink.attrRange(heap, string.context),
        .thunk => |*thunk| try walkThunk(Sink, sink, heap, thunk),
        .boxed_int, .heap_string, .heap_string_inline => {},
    }
}

fn walkThunk(
    comptime Sink: type,
    sink: *Sink,
    heap: *const ObjectHeap,
    thunk: *const thunk_mod.Thunk,
) Sink.Error!void {
    const raw_state = thunk.future.state.load(.acquire);
    if (raw_state == future_mod.poisoned_state) {
        if (comptime heap_mod.gc_debug)
            @panic("gc: tracing a swept thunk -- a live object still references it (stale edge / missed root)");
        return;
    }

    switch (@as(FutureState, @fromBackingInt(@intCast(future_mod.stateFieldRaw(raw_state))))) {
        .resolved => try sink.value(heap, thunk.payload.result),
        // `.errored` reuses the result bits as a heap-owned FailureRef (or an
        // inline degraded error code); `.blackhole` is terminal. Neither is a
        // Value payload.
        .errored, .blackhole => {},
        .unresolved, .evaluating => switch (thunk.targetKind()) {
            .closure => try sink.value(heap, thunk.payload.target.closure),
            .pass_through => try sink.value(heap, thunk.payload.target.pass_through),
            .attr_access => try sink.value(heap, thunk.payload.target.attr_access.base),
            .bytecode => {
                const target = &thunk.payload.target.bytecode;
                try sink.chunk(target.chunk_id);
                try sink.capturedValues(
                    heap,
                    target.upvalues(),
                    target.upvalue_count > thunk_mod.BytecodeThunk.inline_capacity,
                );
            },
            .deferred => {
                const target = &thunk.payload.target.deferred;
                try sink.capturedValues(
                    heap,
                    target.env(),
                    target.env_count > thunk_mod.DeferredThunk.inline_capacity,
                );
            },
        },
    }
}

/// Tooling projection of `walkObject`: collect direct object/chunk references
/// without forcing thunks, flattening attrs, compiling deferred bodies, or
/// recursively traversing children.
pub fn collectReferences(
    heap: *const ObjectHeap,
    snapshot: *const ObjectHeap.ObjectSnapshot,
    id: ObjectId,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(heap_mod.HeapReference),
) !void {
    if (!snapshot.isLive(id)) return error.InvalidObjectId;
    var sink = ReferenceSink{ .allocator = allocator, .out = out };
    try walkObject(ReferenceSink, &sink, heap, id);
}

const ReferenceSink = struct {
    pub const Error = std.mem.Allocator.Error;

    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(heap_mod.HeapReference),

    pub inline fn objectSlot(_: *ReferenceSink) Error!void {}

    pub fn object(self: *ReferenceSink, _: *const ObjectHeap, id: ObjectId) Error!void {
        try self.out.append(self.allocator, .{ .object = id });
    }

    pub fn chunk(self: *ReferenceSink, id: heap_mod.ChunkId) Error!void {
        try self.out.append(self.allocator, .{ .chunk = id });
    }

    pub fn value(self: *ReferenceSink, heap: *const ObjectHeap, child: Value) Error!void {
        switch (heap_mod.inspection.valueRef(child).target) {
            .object => |id| try self.object(heap, id),
            .chunk => |id| try self.chunk(id),
            .none, .intern, .builtin => {},
        }
    }

    pub fn valueRange(self: *ReferenceSink, heap: *const ObjectHeap, range: heap_mod.ValueRange) Error!void {
        for (heap.values.slice(range)) |child| try self.value(heap, child);
    }

    pub fn attrRange(self: *ReferenceSink, heap: *const ObjectHeap, range: heap_mod.AttrRange) Error!void {
        // SoA: the T plane holds the values; names carry no references.
        for (heap.attrs.slice(range)) |entry_value| try self.value(heap, entry_value);
    }

    pub inline fn attrPositions(_: *ReferenceSink, _: heap_mod.AttrPositions) Error!void {}

    pub fn capturedValues(self: *ReferenceSink, heap: *const ObjectHeap, values: []const Value, _: bool) Error!void {
        for (values) |child| try self.value(heap, child);
    }
};
