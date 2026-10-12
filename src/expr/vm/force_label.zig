//! Human-readable source labels for thunks — the
//! crit-wait track (force.zig) and run-quanta (worker.zig) diagnostics.
//!
//! Cold: only exercised when `--timeline`/progress is drawing. Every reader
//! here races a concurrent resolver, so target-union bytes are snapshotted
//! through `rawArm` and validated with a `stillEvaluating` recheck before any
//! id is dereferenced (see the per-function notes).

const std = @import("std");
const vm_mod = @import("context.zig");
const VM = vm_mod.VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const ObjectId = types.ObjectId;
const ChunkId = types.ChunkId;
const thunk_mod = @import("runtime").thunk;
const future_mod = @import("runtime").future;
const vm_errors = @import("errors.zig");
const observ = @import("base").observ;
const BuiltinId = @import("runtime").builtins.BuiltinId;

/// Rich source label for a thunk — an interned source
/// location (file id + line, resolved to "modules.nix:545" at dump) or a
/// literal ("mapAttrs" / "builtins.import foo.nix" / ".attr" / an applied fn's
/// location). Shared by the crit-wait track (force.zig) and the run quanta
/// (worker.zig).
///
/// Empty when unresolvable OR when the thunk has already RESOLVED: a resolved
/// thunk's bare target union is clobbered, so it must not be read
/// (state-guarded). Best-effort and bounds-safe against a concurrent resolve.
pub fn thunkLabel(self: *VM, thunk_id: ObjectId, buf: []u8) observ.Subject {
    const th = self.heap.getThunkAssumeValid(thunk_id);
    if (@backingInt(th.future.stateField(.acquire)) > @backingInt(future_mod.FutureState.evaluating)) return .none;
    return critTargetLabel(self, th, buf, true);
}

pub fn critWaitLabel(self: *VM, thunk_id: ObjectId, buf: []u8) observ.Subject {
    const label = thunkLabel(self, thunk_id, buf);
    if (!label.isEmpty()) return label;
    // The crit track never shows a bare "wait". thunkLabel is empty either
    // because the thunk RESOLVED mid-read (the race — a short wait, target
    // clobbered) or because it's genuinely source-less; distinguish the two.
    const th = self.heap.getThunkAssumeValid(thunk_id);
    if (@backingInt(th.future.stateField(.acquire)) > @backingInt(future_mod.FutureState.evaluating)) return observ.Subject.literal("resolved");
    return observ.Subject.literal(@tagName(th.targetKind()));
}

/// True while the thunk's `payload` is still its `.target` arm — i.e. NOT yet
/// resolved/errored, which overwrite that arm with the result. Monotonic (once
/// false, stays false). Read it AFTER a `rawArm` snapshot to validate the
/// snapshot: if the thunk is still evaluating at the recheck, the bytes were
/// live when read (state can't go terminal → evaluating), so the ids in them
/// are real; otherwise discard them unused.
inline fn stillEvaluating(th: *const thunk_mod.Thunk) bool {
    return @backingInt(th.future.stateField(.acquire)) <= @backingInt(future_mod.FutureState.evaluating);
}

/// Snapshot the target arm's bytes as concrete type `T` through a RAW pointer —
/// never a `.payload.target.<arm>` union access. Both `Payload` and
/// `ThunkTarget` are bare unions that carry a hidden safety tag in safe builds,
/// so the field-access form panics ("access of union field 'target' while
/// 'result' is active") the instant a concurrent resolver flips `payload` to
/// `.result`. The arm sits at offset 0 of `payload`; casting to the arm struct
/// reads the same bytes with no tag check. A resolved thunk yields garbage,
/// gated by a `stillEvaluating` recheck before any id is dereferenced.
inline fn rawArm(th: *const thunk_mod.Thunk, comptime T: type) T {
    return @as(*const T, @ptrCast(@alignCast(&th.payload))).*;
}

pub fn critTargetLabel(self: *VM, th: *thunk_mod.Thunk, buf: []u8, follow: bool) observ.Subject {
    return switch (th.targetKind()) {
        .bytecode => blk: {
            const b = rawArm(th, thunk_mod.BytecodeThunk);
            if (!stillEvaluating(th)) break :blk .none; // resolved mid-read → b is garbage
            const loc = critChunkLoc(self, b.chunk_id);
            if (!loc.isEmpty()) break :blk loc;
            // Source-less chunk — a compiler-generated apply-glue. The
            // well-known map/genList/mapAttrs stubs are the common ones; name
            // the operation and, where the applied function (upvalue 0) is
            // INLINE-safe to read, its location. `b` is a validated snapshot,
            // so its inline slot is safe to read.
            if (b.chunk_id == self.registry.well_known.mapattrs_apply) break :blk observ.Subject.literal("mapAttrs"); // 3 ups → spilled
            if (b.upvalue_count >= 1 and b.upvalue_count <= thunk_mod.BytecodeThunk.inline_capacity) {
                const fn_val: Value = @as(*const Value, @ptrCast(@alignCast(&b.storage))).*;
                const fn_loc = critClosureLabel(self, fn_val, buf);
                if (!fn_loc.isEmpty()) break :blk fn_loc;
            }
            // genlist_apply is the SHARED single-arg-application stub — used by
            // both builtins.genList AND builtins.map — so name it for both.
            if (b.chunk_id == self.registry.well_known.genlist_apply) break :blk observ.Subject.literal("map/genList");
            break :blk .none;
        },
        .closure => blk: {
            const cv = rawArm(th, Value);
            if (!stillEvaluating(th)) break :blk .none;
            break :blk critClosureLabel(self, cv, buf);
        },
        .attr_access => blk: {
            const aa = rawArm(th, thunk_mod.AttrAccess);
            if (!stillEvaluating(th)) break :blk .none;
            break :blk observ.Subject.literal(std.fmt.bufPrint(buf, ".{s}", .{self.intern.get(aa.name)}) catch "");
        },
        .pass_through => blk: {
            // A cell forwards to another value; label what it points at (one
            // level, no further pass_through recursion).
            if (!follow) break :blk .none;
            const pv = rawArm(th, Value);
            if (!stillEvaluating(th)) break :blk .none; // resolved mid-read → pv is garbage
            if (!pv.isThunk()) break :blk .none;
            const inner = self.heap.getThunkAssumeValid(pv.asObjectId());
            if (!stillEvaluating(inner)) break :blk .none;
            break :blk critTargetLabel(self, inner, buf, false);
        },
        // A lazy-compiled attr body — file id + line from its AST node via the
        // table's cached per-source line index (built once; `lineForOffset` is
        // cache-free so it's safe even while the compiler shares the index).
        .deferred => blk: {
            const d = rawArm(th, thunk_mod.DeferredThunk);
            if (!stillEvaluating(th)) break :blk .none;
            const table = self.deferred_table orelse break :blk observ.Subject.literal("deferred");
            const entry = table.get(d.deferred_id);
            const fid = entry.source_file_id orelse break :blk observ.Subject.literal("deferred");
            const off = if (entry.node.span) |s| s.offset else break :blk observ.Subject.sourceLocation(fid, 0);
            const idx = table.lineIndexFor(entry.source) catch break :blk observ.Subject.sourceLocation(fid, 0);
            break :blk observ.Subject.sourceLocation(fid, idx.lineForOffset(off));
        },
    };
}

/// The chunk's source location as an interned ref (file id + line) — the
/// filename is resolved from the shared intern table only at dump. No buffer.
fn critChunkLoc(self: *VM, chunk_id: ChunkId) observ.Subject {
    const ch = self.registry.get(chunk_id) orelse return .none;
    const span = vm_errors.chunkEntrySpan(ch) orelse return .none;
    const file_id = span.file orelse return .none;
    return observ.Subject.sourceLocation(file_id, span.line);
}

fn critClosureLabel(self: *VM, cv: Value, buf: []u8) observ.Subject {
    return switch (cv.kind()) {
        .closure => blk: {
            const cl = @import("closures.zig").closureRef(self, cv) catch break :blk .none;
            break :blk critChunkLoc(self, cl.chunk_id);
        },
        .builtin_closure => blk: {
            const bc = self.heap.getBuiltinClosure(cv.asObjectId()) catch break :blk .none;
            break :blk critBuiltinLabel(self, @fromBackingInt(@intCast(bc.builtin_id)), bc.args, buf);
        },
        .builtin => critBuiltinLabel(self, @fromBackingInt(@intCast(cv.asBuiltinId())), &.{}, buf),
        else => .none,
    };
}

fn critBuiltinLabel(self: *VM, id: BuiltinId, args: []const Value, buf: []u8) observ.Subject {
    const name = @tagName(id);
    // Path-taking builtins (import, readFile, ...) carry the file as arg[0] —
    // the "which giant file is main blocked on" bit worth surfacing.
    if (args.len > 0) {
        const a = args[0];
        if (a.kind() == .path or a.kind() == .string) {
            return observ.Subject.literal(std.fmt.bufPrint(buf, "builtins.{s} {s}", .{ name, std.fs.path.basename(self.intern.get(a.asInternId())) }) catch name);
        }
    }
    return observ.Subject.literal(std.fmt.bufPrint(buf, "builtins.{s}", .{name}) catch name);
}
