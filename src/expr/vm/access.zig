//! Attribute-set and list access: getAttr / getAttrPath / hasAttrPath, functor
//! (`__functor`) calls, and `with`-scope lookup, fronted by a per-worker inline
//! attr cache. Also the demand-sibling-sweep trigger — a cache miss speculatively
//! prefetches the set's other members.
//! Concurrency: the attr cache is private to an evaluator OS thread and its
//! lazily allocated bundle is registered so the STW collector marks live entries.
const std = @import("std");
const vm_mod = @import("context.zig");
const types = @import("runtime").types;
const thunk_mod = @import("runtime").thunk;
const future_mod = @import("runtime").future;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const bytecode_mod = @import("../bytecode.zig");

const closures = @import("closures.zig");
const force = @import("force.zig");
const vm_strings = @import("strings.zig");
const stack = @import("stack.zig");
const trace = @import("trace.zig");
const vm_builtins = @import("builtins.zig");
const prof = @import("../probe.zig").prof;
const prof_census = @import("../probe.zig").prof_census;
const gc = @import("runtime").gc;
const heap_mod = @import("runtime").heap;
const thread_caches = @import("thread_caches.zig");

const VM = vm_mod.VM;
const readU32 = vm_mod.readU32;
const readInternId = vm_mod.readInternId;

pub fn callAttrFunctor(self: *VM, callee: Value) !Value {
    // GC: `callee` (the functor attrset) is held in a Zig local across
    // `forceValue(functor)` — and callers reach here off the operand stack
    // (e.g. doTailCall's `current`) — so root it. Compiles away w/o GC.
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, callee);
    const functor_id = try self.intern.intern("__functor");
    const functor = self.heap.getAttrValue(callee.asObjectId(), functor_id) catch |err| switch (err) {
        error.MissingAttribute => return error.NotCallable,
        else => return err,
    };
    return closures.callValue(self, try force.forceValue(self, functor), callee);
}

pub fn applyBuiltin(self: *VM, builtin_id: u16, args: []const Value) !Value {
    // GC: raise the per-thread native depth for the duration of the
    // builtin. This gates only the PEER stop-the-world park (`force.zig`,
    // `native_depth == 0`), NOT collection initiation: a demand `forceValue`
    // that resolves a thunk runs mark+sweep at ANY native depth (the RSS
    // lever, `force.zig` self-collect). So a builtin's own Zig-local heap refs
    // CAN be observed mid-builtin. Args are safe (they stay rooted for the
    // call — on the operand stack / in the in-flight `builtin_closure`), and a
    // value reachable through a rooted arg is fine. But a builtin (or VM op)
    // that produces a FRESH heap value, holds it only in a Zig local / slice /
    // ArrayList, and then FORCES (a thunk) or `callValue`s while it's still
    // needed MUST `force.rootKeep` it first — else the collection sweeps it
    // (w>1 UAF). See concatMap/foldl'/mergeAttrLiteralObjects for the pattern.
    // `import`/`scopedImport` drop back to the caller's depth for the imported
    // eval (see `Engine.evaluateSource`).
    self.native_depth += 1;
    defer {
        self.native_depth -= 1;
    }
    return vm_builtins.applyBuiltin(self, builtin_id, args);
}

pub fn applyBuiltinClosure(self: *VM, callee: Value, arg: Value) !Value {
    const closure = try self.heap.getBuiltinClosure(callee.asObjectId());
    var args: [8]Value = undefined;
    if (closure.args.len + 1 > args.len) return error.TooManyArguments;
    @memcpy(args[0..closure.args.len], closure.args);
    args[closure.args.len] = arg;
    return applyBuiltin(self, closure.builtin_id, args[0 .. closure.args.len + 1]);
}

pub fn getAttrValue(self: *VM, attrs_val: Value, name_id: InternId) !Value {
    const t = prof.start(.get_attr_value);
    defer prof.end(.get_attr_value, t);
    const attrs = try force.forceValue(self, attrs_val);
    if (!attrs.isAttrs()) return trace.typeErrorExpected(self, "attrs", attrs);
    return force.forceValue(self, try cachedAttrLookup(self, attrs.asObjectId(), name_id));
}

/// Per-worker-thread inline cache: (heap_token, obj_id, name_id) → raw
/// attr value. Hits skip the binary search inside
/// `heap.getAttrValue`. The cached value is pre-force; callers force
/// the result if they need a resolved value.
inline fn cachedAttrLookup(self: *VM, obj_id: types.ObjectId, name_id: InternId) !Value {
    const slot_idx = attrCacheIndex(obj_id, name_id);
    const slot = &thread_caches.get(self.allocator).attr_cache[slot_idx];
    const token = self.heap.token;
    if (slot.heap_token == token and slot.obj_id == obj_id and slot.name_id == name_id) {
        if (comptime prof.enabled) {
            if (self.workerId() == 0) {
                prof_census.attr_cache_hits += 1;
                if (force.profIsResolvedThunk(self, slot.value)) prof_census.rf_attr_hit += 1;
            }
        }
        return slot.value;
    }
    if (comptime prof.enabled) {
        if (self.workerId() == 0) {
            prof_census.attr_cache_misses += 1;
            // Attr-lookup size census: bucket this compulsory binary
            // search by the set's entry count.
            switch (self.heap.get(obj_id).*) {
                .attrs => |*a| {
                    const n: u64 = a.range.len;
                    const k: usize = @min(prof_census.allocation_buckets - 1, std.math.log2_int(u64, @max(2, n) - 1));
                    prof_census.al_size[k] += 1;
                    prof_census.al_probes[k] += if (n <= 1) 1 else std.math.log2_int(u64, n) + 1;
                },
                else => prof_census.al_merge += 1,
            }
        }
    }

    const raw = try self.heap.getAttrValue(obj_id, name_id);
    slot.heap_token = token;
    slot.obj_id = obj_id;
    slot.name_id = name_id;
    slot.value = raw;
    // Demand-sibling prefetch (`FIX_SIBLING`): a cache MISS on an attr
    // member is the first touch of this (obj, name) on this worker —
    // the trigger point for sweeping the member's siblings. One dead
    // branch here when the flag is off; everything else lives in the
    // cold helper.
    if (self.workers.siblingPrefetchEnabled()) maybeSiblingSweep(self, obj_id, raw);
    return raw;
}

/// Cold path of the demand-sibling prefetch trigger. Submits ONE
/// speculative whole-set sweep task when:
///   - we're on a demand fiber (speculative work must not cascade),
///   - the just-looked-up member is itself a still-unresolved thunk
///     (if creation-time speculation already resolved it, its siblings
///     are likely resolved too — nothing to prefetch), and
///   - the attrset passes the size gate + once-per-set dedup
///     (`ObjectHeap.trySiblingSweep`).
/// The sweep task forces members via `forceValueSpeculative`, so it is
/// demand-invisible (no `demanded` marks, sticky-error rules unchanged).
fn maybeSiblingSweep(self: *VM, obj_id: types.ObjectId, member: Value) void {
    if (self.speculation.active) return;
    if (!member.isThunk()) return;
    const th = self.heap.getThunkAssumeValid(member.asObjectId());
    if (@intFromEnum(th.future.stateField(.monotonic)) != @intFromEnum(future_mod.FutureState.unresolved)) return;
    const workers = self.workers;
    if (!self.heap.trySiblingSweep(obj_id, workers.siblingMin(), workers.siblingMax())) return;
    const ok = workers.submitSiblingSweep(obj_id, workers.siblingUrgent(), self.workerId());
    if (ok)
        workers.noteSiblingSweep(self.workerId())
    else
        // Rejected (queue full / no helpers): unmark so a later miss can
        // retry — a set must not become permanently unsweepable because
        // one submit lost a race to a full queue.
        self.heap.clearSiblingSwept(obj_id);
    if (workers.siblingLog()) {
        // Diagnostics only: submit timestamp + submitter, so a run log
        // shows per-sweep submit->run latency and lost submits.
        std.debug.print("sweep-submit attrs={d} t_us={d} worker={d} ok={}\n", .{
            obj_id,
            force.diagNowUs(),
            self.workerId(),
            ok,
        });
    }
}

/// GC: the attr cache holds attr Values keyed by heap token. Its
/// entries can be the momentary sole reference to a shared attr value, so valid
/// entries (token match) are roots. Mark every registered worker's entries at
/// the stop-the-world point.
pub fn gcMarkAttrCache(tr: *gc.Tracer, heap: *const heap_mod.ObjectHeap) void {
    for (thread_caches.registered()) |maybe| {
        const caches = maybe orelse continue;
        for (&caches.attr_cache) |*slot| {
            if (slot.heap_token == heap.token) tr.markValue(heap, slot.value);
        }
    }
}

inline fn attrCacheIndex(obj_id: types.ObjectId, name_id: InternId) usize {
    // Mix obj_id and name_id — same lookup site on the same object
    // hits the same slot, but different lookups on the same object
    // (e.g. `.x` and `.y`) land in different slots.
    const mixed: u64 = (@as(u64, obj_id) *% 0x9E3779B97F4A7C15) ^ @as(u64, name_id);
    return @intCast(mixed % thread_caches.attr_cache_size);
}

pub fn getAttrPathOrValue(self: *VM, attrs_val: Value, default_val: Value, encoded_names: []const u8, wide: bool) !Value {
    // GC: no explicit roots — the op keeps `attrs_val` (and `default_val`) on the
    // operand stack across this whole helper, so every `current` path node is
    // transitively reachable from it (attr thunks resolve in place).
    var current = try force.forceValue(self, attrs_val);
    var offset: usize = 0;
    const stride: usize = if (wide) 4 else 2;
    while (offset < encoded_names.len) : (offset += stride) {
        if (!current.isAttrs()) return force.forceValue(self, default_val);
        const name_id = readInternId(encoded_names, offset, wide);
        current = cachedAttrLookup(self, current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return force.forceValue(self, default_val),
            else => return err,
        };
        current = try force.forceValue(self, current);
    }
    return current;
}

pub fn getAttrPathDynamicOrValue(self: *VM, attrs_val: Value, dynamic_name: Value, default_val: Value, encoded_names: []const u8, wide: bool) !Value {
    // GC: no explicit roots — the op keeps [attrs, name, default] on the operand
    // stack across this helper, so every `current` is transitively reachable.
    var current = try force.forceValue(self, attrs_val);
    var offset: usize = 0;
    const stride: usize = if (wide) 4 else 2;
    while (offset < encoded_names.len) : (offset += stride) {
        if (!current.isAttrs()) return force.forceValue(self, default_val);
        const name_id = readInternId(encoded_names, offset, wide);
        current = cachedAttrLookup(self, current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return force.forceValue(self, default_val),
            else => return err,
        };
        current = try force.forceValue(self, current);
    }
    const name_val = try force.forceValue(self, dynamic_name);
    if (!current.isAttrs()) {
        _ = vm_strings.selectNameId(self, name_val) catch |err| switch (err) {
            error.MissingAttribute => {},
            else => return err,
        };
        return force.forceValue(self, default_val);
    }
    const name_id = vm_strings.selectNameId(self, name_val) catch |err| switch (err) {
        error.MissingAttribute => return force.forceValue(self, default_val),
        else => return err,
    };
    const result = cachedAttrLookup(self, current.asObjectId(), name_id) catch |err| switch (err) {
        error.MissingAttribute => return force.forceValue(self, default_val),
        else => return err,
    };
    return force.forceValue(self, result);
}

pub fn getAttrPathMixedOrValue(self: *VM, attrs_val: Value, dynamic_names: []const Value, default_val: Value, encoded_segments: []const u8, segment_count: usize) !Value {
    // GC: no explicit roots — the op keeps [attrs, dyn-names…, default] on the
    // operand stack across this helper, so every `current` is transitively reachable.
    var current = try force.forceValue(self, attrs_val);
    var offset: usize = 0;
    var dynamic_i: usize = 0;
    for (0..segment_count) |_| {
        const tag = encoded_segments[offset];
        offset += 1;
        const name_id: InternId = switch (tag) {
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => name: {
                if (!current.isAttrs()) return force.forceValue(self, default_val);
                const id = readU32(encoded_segments, offset);
                offset += 4;
                break :name id;
            },
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => name: {
                const name_val = try force.forceValue(self, dynamic_names[dynamic_i]);
                dynamic_i += 1;
                if (!current.isAttrs()) return force.forceValue(self, default_val);
                break :name vm_strings.selectNameId(self, name_val) catch |err| switch (err) {
                    error.MissingAttribute => return force.forceValue(self, default_val),
                    else => return err,
                };
            },
            else => return error.InvalidBytecode,
        };
        current = cachedAttrLookup(self, current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return force.forceValue(self, default_val),
            else => return err,
        };
        current = try force.forceValue(self, current);
    }
    return current;
}

pub fn hasAttrPath(self: *VM, attrs_val: Value, encoded_names: []const u8, wide: bool) !bool {
    var current = try force.forceValue(self, attrs_val);
    var offset: usize = 0;
    const stride: usize = if (wide) 4 else 2;
    while (offset < encoded_names.len) : (offset += stride) {
        if (!current.isAttrs()) return false;
        const name_id = readInternId(encoded_names, offset, wide);
        const attr = cachedAttrLookup(self, current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return false,
            else => return err,
        };
        if (offset + stride >= encoded_names.len) return true;
        current = try force.forceValue(self, attr);
    }
    return false;
}

pub fn hasAttrPathMixed(self: *VM, attrs_val: Value, dynamic_names: []const Value, encoded_segments: []const u8, segment_count: usize) !bool {
    var current = try force.forceValue(self, attrs_val);
    var offset: usize = 0;
    var dynamic_i: usize = 0;
    for (0..segment_count) |segment_index| {
        const tag = encoded_segments[offset];
        offset += 1;
        const name_id: InternId = switch (tag) {
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => name: {
                if (!current.isAttrs()) return false;
                const id = readU32(encoded_segments, offset);
                offset += 4;
                break :name id;
            },
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => name: {
                const name_val = try force.forceValue(self, dynamic_names[dynamic_i]);
                dynamic_i += 1;
                if (!current.isAttrs()) return false;
                break :name vm_strings.selectNameId(self, name_val) catch |err| switch (err) {
                    error.MissingAttribute => return false,
                    else => return err,
                };
            },
            else => return error.InvalidBytecode,
        };
        const attr = cachedAttrLookup(self, current.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => return false,
            else => return err,
        };
        if (segment_index + 1 == segment_count) return true;
        current = try force.forceValue(self, attr);
    }
    return false;
}

pub fn lookupWith(self: *VM, name_id: InternId, scope_count: u8) !void {
    const start = self.sp - scope_count;
    const scopes = self.stack[start..self.sp];

    for (scopes) |scope| {
        const attrs_val = try force.forceValue(self, scope);
        if (!attrs_val.isAttrs()) return error.TypeError;

        const attr_val = cachedAttrLookup(self, attrs_val.asObjectId(), name_id) catch |err| switch (err) {
            error.MissingAttribute => continue,
            else => return err,
        };

        const result = try force.forceValue(self, attr_val);
        self.sp = start;
        try stack.push(self, result);
        return;
    }

    self.sp = start;
    return error.UndefinedVariable;
}
