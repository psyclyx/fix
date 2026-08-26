//! String and path machinery for the language: coercion to language strings
//! (`__toString` / outPath), `+` and `str_cat` concatenation, and
//! string-context (store-path dependency set) accumulation and merging.
const std = @import("std");
const vm_mod = @import("context.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const int_mod = @import("runtime").int;
const source_paths = @import("store").realization.source_path;

const closures = @import("closures.zig");
const force = @import("force.zig");
const context_merge = @import("context_merge.zig");
const trace = @import("trace.zig");
const prof = @import("../probe.zig").prof;
const prof_census = @import("../probe.zig").prof_census;

const VM = vm_mod.VM;

/// Intern the concatenation of `parts` (total byte length pre-computed by
/// the caller). Small results — most attr names and interpolation results —
/// assemble in a stack buffer, skipping the allocator round-trip a temp
/// heap buffer pays per concat.
fn internConcatParts(self: *VM, parts: []const []const u8, total: usize) !InternId {
    var stack_buf: [64]u8 = undefined;
    var heap_buf: []u8 = &.{};
    defer if (heap_buf.len != 0) self.allocator.free(heap_buf);
    const buf = if (total <= stack_buf.len) stack_buf[0..total] else blk: {
        heap_buf = try self.allocator.alloc(u8, total);
        break :blk heap_buf;
    };
    var off: usize = 0;
    for (parts) |s| {
        @memcpy(buf[off..][0..s.len], s);
        off += s.len;
    }
    return self.intern.intern(buf);
}

pub fn concatInternedString(self: *VM, a: InternId, b: InternId) !InternId {
    const t_start = prof.tscMainOnly();
    const s_a = self.intern.get(a);
    const s_b = self.intern.get(b);
    const total = s_a.len + s_b.len;

    const pre_entries = if (prof.enabled) self.intern.entries.count() else 0;
    const id = try internConcatParts(self, &.{ s_a, s_b }, total);
    if (prof.enabled and t_start != 0) {
        prof_census.str.concat_calls += 1;
        prof_census.str.concat_cycles += prof.tscMainOnly() - t_start;
        prof_census.str.concat_bytes += total;
        if (self.intern.entries.count() != pre_entries) {
            prof_census.str.concat_new += 1;
            prof_census.str.concat_new_bytes += total;
        }
    }
    return id;
}

/// Enter one nested string-coercion level, counting it against
/// `max-call-depth` as Nix's `EvalState::coerceToString` does via
/// `addCallDepth`. Every attrs/list coercion body recurses on the native
/// stack, so a self-referential value (`let r = { outPath = r; }`) has no
/// other bound and would fault. Pair with `coercionExit`; the depth is only
/// taken on success, so an over-budget caller must not run the exit.
pub fn coercionEnter(self: *VM) !void {
    const ctx = self.executionContext();
    if (ctx.coerce_depth >= self.policy.max_call_depth) return trace.callDepthExceeded(self);
    // Native backstop, as in `forceThunkImpl`: a fiber stack too small to
    // reach the logical limit degrades to an error rather than a fault.
    if (@frameAddress() < ctx.stack_limit) return trace.stackOverflow(self);
    ctx.coerce_depth += 1;
}

pub fn coercionExit(self: *VM) void {
    self.executionContext().coerce_depth -= 1;
}

pub fn stringLikeValue(self: *VM, value: Value) !Value {
    const forced = try force.forceValue(self, value);
    return switch (forced.kind()) {
        .string, .path, .string_context, .heap_string => forced,
        .attrs => try attrsStringLikeValue(self, forced),
        else => trace.coercionError(self, forced),
    };
}

pub fn stringLikeInternId(self: *VM, value: Value) !InternId {
    return stringTextInternId(self, try stringLikeValue(self, value));
}

pub fn stringTextInternId(self: *VM, value: Value) !InternId {
    return switch (value.kind()) {
        .string, .path => value.asInternId(),
        .string_context => (try self.heap.getContextString(value.asObjectId())).text,
        else => error.TypeError,
    };
}

pub fn stringTextInternIdsEqual(self: *VM, left: Value, right: Value) !bool {
    if (!left.isContextString() and !right.isContextString()) {
        return left.asInternId() == right.asInternId();
    }
    return (try stringTextInternId(self, left)) == (try stringTextInternId(self, right));
}

/// Speculative strings are useful only if demand eventually observes their
/// thunk. Before GC tracking arms, putting each one in its own heap object
/// cannot reclaim anything and magnifies undemanded NixOS work. Intern those
/// early speculative results instead; demand work keeps bounded heap strings,
/// and once collection is active speculative strings become reclaimable too.
inline fn useHeapString(self: *VM, len: usize) bool {
    return useHeapStringAt(
        self.heap_string_min,
        len,
        self.speculation.active,
        self.heap.collectionEnabled(),
    );
}

fn useHeapStringAt(threshold: usize, len: usize, speculative: bool, collection_enabled: bool) bool {
    return len >= threshold and (!speculative or collection_enabled);
}

test "speculative assembled strings wait for collection tracking" {
    try std.testing.expect(useHeapStringAt(64, 64, false, false));
    try std.testing.expect(!useHeapStringAt(64, 64, true, false));
    try std.testing.expect(useHeapStringAt(64, 64, true, true));
    try std.testing.expect(!useHeapStringAt(64, 63, false, true));
}

/// Construct a string value from freshly-assembled bytes. Short text
/// interns (dedup pays: attr names, keys, repeated fragments); text of at
/// least this VM's `heap_string_min` bytes becomes a GC-able heap string, so churn —
/// unique intermediates nothing ever looks at again — can be collected.
/// NEVER route text bound for a context string or an attr name through
/// this: those stay id-keyed (`addContextString` asserts it).
pub fn makeString(self: *VM, bytes: []const u8) !Value {
    if (useHeapString(self, bytes.len))
        return Value.heapString(try self.heap.addHeapString(bytes));
    return Value.string(try self.intern.intern(bytes));
}

/// Construct a string value from DERIVED text whose global uniqueness the
/// caller can't rule out but whose unbounded instances are unique —
/// number formatting is the canonical producer. Two regimes:
///
/// - SHORT text (≤ 5 bytes) interns: small numbers (versions, ports,
///   priorities, list indices) repeat millions of times across a real
///   eval, and losing their dedup turned each occurrence into a live
///   48-byte heap object — inflating the live set that every full mark
///   walks (a measured +33% on the whole-nixpkgs eval). The possible
///   short-numeric universe bounds the intern-table pollution at ~110k
///   entries ever, so the churn fixture's unbounded-growth property is
///   preserved.
/// - LONGER text goes to the GC heap: real counters and timestamps are
///   unique in practice, and interning a fold's worth of them was 33% of
///   churn wall in table growth + rehash.
///
/// The Engine's `heap_string_min` at maxInt remains the master off-switch.
pub fn makeUniqueString(self: *VM, bytes: []const u8) !Value {
    if (bytes.len <= 5 or self.heap_string_min == std.math.maxInt(usize))
        return Value.string(try self.intern.intern(bytes));
    return Value.heapString(try self.heap.addHeapString(bytes));
}

/// `makeString` over pre-sliced parts (the concat producers), carrying
/// the -Dprof concat census that previously lived in
/// `concatInternedString`. Contexted results must NOT come here — their
/// text is id-keyed (`addContextString`); callers keep those on
/// `internConcatParts`.
pub fn makeConcatString(self: *VM, parts: []const []const u8, total: usize) !Value {
    const t_start = prof.tscMainOnly();
    if (useHeapString(self, total)) {
        const id = try self.heap.addHeapStringParts(parts, @intCast(total));
        if (prof.enabled and t_start != 0) {
            prof_census.str.concat_calls += 1;
            prof_census.str.concat_cycles += prof.tscMainOnly() - t_start;
            prof_census.str.concat_bytes += total;
        }
        return Value.heapString(id);
    }
    const pre_entries = if (prof.enabled) self.intern.entries.count() else 0;
    const id = try internConcatParts(self, parts, total);
    if (prof.enabled and t_start != 0) {
        prof_census.str.concat_calls += 1;
        prof_census.str.concat_cycles += prof.tscMainOnly() - t_start;
        prof_census.str.concat_bytes += total;
        if (self.intern.entries.count() != pre_entries) {
            prof_census.str.concat_new += 1;
            prof_census.str.concat_new_bytes += total;
        }
    }
    return Value.string(id);
}

/// Borrow the text of a forced string-like value. For interned forms the
/// slice is immortal; for a heap string it follows the
/// `ObjectHeap.getHeapString` contract — valid while `value` stays rooted
/// and only until the next GC safepoint. Copy or intern to retain.
pub inline fn stringBytes(self: *VM, value: Value) ![]const u8 {
    return switch (value.kind()) {
        .string, .path => self.intern.get(value.asInternId()),
        .string_context => self.intern.get((try self.heap.getContextString(value.asObjectId())).text),
        .heap_string => self.heap.getHeapString(value.asObjectId()),
        else => error.TypeError,
    };
}

/// String equality over any string-like pair. Interned-only pairs keep the
/// id-compare fast path; a heap string on either side compares bytes
/// (unique-by-construction ids can't speak for content).
pub fn stringTextEqual(self: *VM, left: Value, right: Value) !bool {
    if (!left.isHeapString() and !right.isHeapString())
        return stringTextInternIdsEqual(self, left, right);
    return std.mem.eql(u8, try stringBytes(self, left), try stringBytes(self, right));
}

/// A string-like's text as an id for an id-keyed role (attr NAME
/// construction, pattern-cache key): heap-resident text is interned here,
/// at the boundary where identity starts to matter.
pub fn stringNameId(self: *VM, value: Value) !InternId {
    if (value.isHeapString())
        return self.intern.intern(try self.heap.getHeapString(value.asObjectId()));
    return stringTextInternId(self, value);
}

/// Read-only name lookup (dynamic select, hasAttr): like `stringNameId`
/// but a heap string probes the intern table WITHOUT inserting — every
/// attr name is interned at construction, so a probe miss proves the attr
/// cannot exist, and the miss leaves no immortal entry behind.
pub fn lookupNameId(self: *VM, value: Value) !?InternId {
    if (value.isHeapString())
        return self.intern.probe(try self.heap.getHeapString(value.asObjectId()));
    return try stringTextInternId(self, value);
}

/// Resolve a forced dynamic-select NAME to an id for id-keyed attr lookup.
/// Interned strings pass through untouched (the hot path); a heap string
/// probes without inserting, mapping a miss to `error.MissingAttribute`
/// (the caller's existing missing-attr handling — default value, `false`,
/// user error — then applies unchanged). Everything else, including
/// context strings, stays `error.TypeError` exactly as before.
pub fn selectNameId(self: *VM, name_val: Value) !InternId {
    if (name_val.isString()) return name_val.asInternId();
    if (name_val.isHeapString())
        return (try lookupNameId(self, name_val)) orelse error.MissingAttribute;
    return error.TypeError;
}

pub fn isPlainString(value: Value) bool {
    return value.isString() or value.isContextString() or value.isHeapString();
}

pub fn attrsStringLikeValue(self: *VM, attrs: Value) !Value {
    try coercionEnter(self);
    defer coercionExit(self);

    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    force.rootKeep(self, attrs); // held across getAttrValue + callValue + recurse
    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs.asObjectId(), to_string_id)) |to_string| {
        return stringLikeValue(self, try closures.callValue(self, try force.forceValue(self, to_string), attrs));
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }

    const out_path_id = try self.intern.intern("outPath");
    const out_path = self.heap.getAttrValue(attrs.asObjectId(), out_path_id) catch |err| switch (err) {
        error.MissingAttribute => return trace.coercionError(self, attrs),
        else => return err,
    };
    return stringLikeValue(self, out_path);
}

pub fn concatPathLike(self: *VM, left: Value, right: Value) !Value {
    const right_like = try stringLikeValue(self, right);
    // Path values stay interned regardless of the right side's residency.
    const raw_text_id = try internConcatParts(self, &.{
        self.intern.get(left.asInternId()),
        try stringBytes(self, right_like),
    }, self.intern.get(left.asInternId()).len + (try stringBytes(self, right_like)).len);
    const raw_text = self.intern.get(raw_text_id);
    const text_id = if (std.fs.path.isAbsolute(raw_text)) text_id: {
        const normalized = try std.fs.path.resolve(self.allocator, &.{raw_text});
        defer self.allocator.free(normalized);
        break :text_id try self.intern.intern(normalized);
    } else raw_text_id;

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    if (right_like.isContextString()) {
        if (try hasStorePathContext(self, right_like)) return error.InvalidPathConcatenation;
        try appendStringContext(self, &context, right_like);
    }
    if (context.items.len == 0) return Value.path(text_id);
    return Value.contextString(try self.heap.addContextStringEntries(text_id, context.items));
}

pub fn concatStringLike(self: *VM, left: Value, right: Value) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    const left_forced = try force.forceValue(self, left);
    force.rootKeep(self, left_forced);
    // Nix coerces `+` operands with copyToStore only when the first operand
    // is a string (ExprConcatStrings); a non-string left (an attrset via
    // outPath/__toString) concatenates path operands as their text.
    const copy = switch (left_forced.kind()) {
        .string, .string_context, .heap_string => true,
        else => false,
    };
    const left_like = if (copy)
        try coerceLanguageStringValue(self, left_forced)
    else
        try textStringLike(self, left_forced);
    force.rootKeep(self, left_like); // held across the `right` coercion + appendStringContext forces
    const right_like = if (copy)
        try coerceLanguageStringValue(self, right)
    else
        try textStringLike(self, right);
    force.rootKeep(self, right_like); // held across appendStringContext forces
    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    try appendStringContext(self, &context, left_like);
    try appendStringContext(self, &context, right_like);

    // Slices AFTER the context forces: a force is a GC safepoint and a
    // heap-string borrow must not be held across one.
    const left_bytes = try stringBytes(self, left_like);
    const right_bytes = try stringBytes(self, right_like);
    const total = left_bytes.len + right_bytes.len;
    if (comptime prof.enabled) if (self.workerId() == 0)
        prof_census.recordLongString(total, context.items.len != 0);
    if (context.items.len != 0) {
        // Contexted text stays interned (context_string.text is id-keyed).
        const text_id = try internConcatParts(self, &.{ left_bytes, right_bytes }, total);
        return Value.contextString(try self.heap.addContextStringEntries(text_id, context.items));
    }
    return makeConcatString(self, &.{ left_bytes, right_bytes }, total);
}

/// `stringLikeValue` with path results flattened to their text, the
/// copyToStore=false side of Nix's concat coercion.
fn textStringLike(self: *VM, value: Value) !Value {
    const like = try stringLikeValue(self, value);
    return if (like.kind() == .path) Value.string(like.asInternId()) else like;
}

/// `str_cat` opcode body: coerce the top `count` stack operands
/// to language strings IN PLACE (each stays in its slot — a precise GC
/// root — across the later parts' coercions), then assemble the result
/// text in one pass and intern it once. The caller pops the operands
/// after we return. Semantically identical to the left fold
/// `((p1 + p2) + p3) + ...` over `concatStringLike`, minus the
/// intermediate allocations/interns.
pub fn concatStackStrings(self: *VM, count: u32) !Value {
    std.debug.assert(count >= 1 and self.sp >= count);
    const base = self.sp - count;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        self.stack[base + i] = try coerceLanguageStringValueOpt(self, self.stack[base + i], true);
    }
    // Single part: the coerced value is the result — its text is already
    // interned, so re-interning (what `"" + x` pays) would be a no-op probe.
    if (count == 1) return self.stack[base];

    // Derive each part's text slice ONCE (intern data segments are stable,
    // so the slices stay valid across the assembly below) instead of paying
    // stringTextInternId + intern.get again per part in a copy pass.
    var slice_buf: [16][]const u8 = undefined;
    const slices = if (count <= slice_buf.len)
        slice_buf[0..count]
    else
        try self.allocator.alloc([]const u8, count);
    defer if (count > slice_buf.len) self.allocator.free(slices);

    var total: usize = 0;
    var any_context = false;
    i = 0;
    while (i < count) : (i += 1) {
        const v = self.stack[base + i];
        const s = try stringBytes(self, v);
        slices[i] = s;
        total += s.len;
        if (v.isContextString()) any_context = true;
    }

    if (comptime prof.enabled) if (self.workerId() == 0)
        prof_census.recordLongString(total, any_context);
    if (!any_context) return makeConcatString(self, slices, total);
    const text_id = try internConcatParts(self, slices, total);

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    i = 0;
    while (i < count) : (i += 1) {
        // GC: appendStringContext can force (context merges); the
        // already-accumulated context values live only in Zig memory,
        // so re-root them across each part's walk. The parts themselves
        // stay rooted in their stack slots.
        const gc_roots = force.rootsBegin(self);
        defer force.rootsEnd(self, gc_roots);
        for (context.items) |e| force.rootKeep(self, e.value);
        try appendStringContext(self, &context, self.stack[base + i]);
    }
    if (context.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextStringEntries(text_id, context.items));
}

/// `path_cat` opcode body: concatenate the top `count` stack operands into a
/// single path, canonicalizing ONCE at the end. The first operand supplies the
/// base path text; the rest are coerced string-like and appended raw. Mirrors
/// `concatPathLike` (used by binary `path + x`) but over N parts with a single
/// canonicalization, so separators between adjacent `${…}` interpolations in a
/// path literal survive.
pub fn concatStackPath(self: *VM, count: u32) !Value {
    std.debug.assert(count >= 1 and self.sp >= count);
    const base = self.sp - count;

    // Coerce every part in place (each stays a precise GC root in its slot).
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        self.stack[base + i] = try stringLikeValue(self, self.stack[base + i]);
    }

    // Assemble the raw concatenated text, then canonicalize once. Same
    // derive-each-slice-once pattern as `concatStackStrings`.
    var slice_buf: [16][]const u8 = undefined;
    const slices = if (count <= slice_buf.len)
        slice_buf[0..count]
    else
        try self.allocator.alloc([]const u8, count);
    defer if (count > slice_buf.len) self.allocator.free(slices);

    var total: usize = 0;
    i = 0;
    while (i < count) : (i += 1) {
        const s = try stringBytes(self, self.stack[base + i]);
        slices[i] = s;
        total += s.len;
    }
    const raw_text_id = try internConcatParts(self, slices, total);
    const raw_text = self.intern.get(raw_text_id);
    const text_id = if (std.fs.path.isAbsolute(raw_text)) text_id: {
        const normalized = try std.fs.path.resolve(self.allocator, &.{raw_text});
        defer self.allocator.free(normalized);
        break :text_id try self.intern.intern(normalized);
    } else raw_text_id;

    // Merge context from any context-string parts; store-path context is
    // illegal inside a path (matches concatPathLike).
    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);
    i = 0;
    while (i < count) : (i += 1) {
        const v = self.stack[base + i];
        if (v.isContextString()) {
            if (try hasStorePathContext(self, v)) return error.InvalidPathConcatenation;
            const gc_roots = force.rootsBegin(self);
            defer force.rootsEnd(self, gc_roots);
            for (context.items) |e| force.rootKeep(self, e.value);
            try appendStringContext(self, &context, v);
        }
    }
    if (context.items.len == 0) return Value.path(text_id);
    return Value.contextString(try self.heap.addContextStringEntries(text_id, context.items));
}

pub fn coerceLanguageStringValue(self: *VM, value: Value) !Value {
    return coerceLanguageStringValueOpt(self, value, false);
}

/// String coercion for `+`/`str_cat`. `allow_int` enables the `coerce-integers`
/// experimental feature — but ONLY on the `${…}` interpolation path (Nix does
/// not coerce integers for binary `+` or `substring`).
pub fn coerceLanguageStringValueOpt(self: *VM, value: Value, allow_int: bool) !Value {
    const gc_roots = force.rootsBegin(self);
    defer force.rootsEnd(self, gc_roots);
    const forced = try force.forceValue(self, value);
    force.rootKeep(self, forced); // held across getAttrValue + callValue + recurse
    return switch (forced.kind()) {
        .string, .string_context, .heap_string => forced,
        .path => try sourcePathStringValue(self, forced.asInternId()),
        .int, .boxed_int => if (allow_int and self.policy.coerce_integers_enabled) blk: {
            // Stack-format + unique-string: number text never dedups.
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{}", .{int_mod.get(forced, self.heap)}) catch unreachable;
            break :blk try makeUniqueString(self, s);
        } else trace.coercionError(self, forced),
        .attrs => blk: {
            const to_string_id = try self.intern.intern("__toString");
            if (self.heap.getAttrValue(forced.asObjectId(), to_string_id)) |to_string| {
                break :blk try coerceLanguageStringValueOpt(self, try closures.callValue(self, try force.forceValue(self, to_string), forced), allow_int);
            } else |err| switch (err) {
                error.MissingAttribute => {},
                else => return err,
            }

            const out_path_id = try self.intern.intern("outPath");
            const out_path = self.heap.getAttrValue(forced.asObjectId(), out_path_id) catch |err| switch (err) {
                error.MissingAttribute => return trace.coercionError(self, forced),
                else => return err,
            };
            break :blk try coerceLanguageStringValueOpt(self, out_path, allow_int);
        },
        else => trace.coercionError(self, forced),
    };
}

pub fn sourcePathStringValue(self: *VM, path_id: InternId) !Value {
    const path = self.intern.get(path_id);
    if (!std.fs.path.isAbsolute(path)) {
        const entries = [_]heap_mod.AttrEntry{
            .{ .name = path_id, .value = try pathContextValue(self) },
        };
        return Value.contextString(try self.heap.addContextStringEntries(path_id, &entries));
    }
    if (!try self.files.pathExists(path)) return error.FileNotFound;
    const store_path = try source_paths.storePathForSourceValue(self.allocator, self.realization, self.files, path);
    defer self.allocator.free(store_path);
    const store_path_id = try self.intern.intern(store_path);
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = store_path_id, .value = try pathContextValue(self) },
    };
    return Value.contextString(try self.heap.addContextStringEntries(store_path_id, &entries));
}

pub fn appendStringContext(self: *VM, context: *std.ArrayListUnmanaged(heap_mod.AttrEntry), value: Value) !void {
    switch (value.kind()) {
        .string, .heap_string => {},
        .path => {
            const path = self.intern.get(value.asInternId());
            if (!try self.files.pathExists(path)) return error.FileNotFound;
            try context_merge.appendContextEntry(self, context, value.asInternId(), try pathContextValue(self));
        },
        .string_context => {
            const gc_roots = force.rootsBegin(self);
            defer force.rootsEnd(self, gc_roots);
            force.rootKeep(self, value); // owns string.context slice, held across appendContextEntry forces
            const string = try self.heap.getContextString(value.asObjectId());
            for (string.context.names, string.context.values) |entry_name, entry_value| try context_merge.appendContextEntry(self, context, entry_name, entry_value);
        },
        else => return error.TypeError,
    }
}

pub fn hasStorePathContext(self: *VM, value: Value) !bool {
    if (!value.isContextString()) return false;
    const store_dir = self.realization.store_dir;
    const string = try self.heap.getContextString(value.asObjectId());
    for (string.context.names) |entry_name| {
        const name = self.intern.get(entry_name);
        if (std.mem.startsWith(u8, name, store_dir) and name.len > store_dir.len and name[store_dir.len] == '/') return true;
    }
    return false;
}

pub fn pathContextValue(self: *VM) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("path"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}
