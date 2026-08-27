//! Grab-bag of Nix serialization and parsing builtins: toJSON/toXML,
//! fromJSON/fromTOML, compareVersions/splitVersion, the regex match/split
//! builtins, and parseDrvName.

const std = @import("std");
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const ObjectId = types.ObjectId;
const InternId = types.InternId;
const heap_mod = @import("runtime").heap;
const int_mod = @import("runtime").int;
const version = @import("runtime").version;
const regex = @import("../../support.zig").regex;
const toml = @import("../../support.zig").toml;
const prof = @import("../../probe.zig").prof;
const prof_census = @import("../../probe.zig").prof_census;
const FutureState = @import("runtime").future.FutureState;
const attrsets = @import("attrsets.zig");
const shared = @import("shared.zig");
const strings = @import("strings.zig");
const string_context = @import("string_context.zig");
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const equality = @import("../equality.zig");

const appendContextEntry = string_context.appendContextEntry;
const coerceAttrsToStringValue = strings.coerceAttrsToStringValue;
const coerceStringContextValue = strings.coerceStringContextValue;
const contextEntriesForValue = string_context.contextEntriesForValue;
const isPlainString = strings.isPlainString;
const sourcePathStringValue = strings.sourcePathStringValue;
const stringArg = strings.stringArg;
const stringTextInternId = strings.stringTextInternId;
const sortedAttrEntries = attrsets.sortedAttrEntries;

pub fn builtinToJSON(self: *VM, arg: Value) !Value {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);

    try writeJsonValueWithPathMode(self, &out.writer, arg, .source, &context);
    const text = try out.toOwnedSlice();
    defer self.allocator.free(text);
    if (comptime prof.enabled) if (self.workerId() == 0)
        prof_census.recordLongString(text.len, context.items.len != 0);
    if (context.items.len == 0) return vm_strings.makeString(self, text);
    return Value.contextString(try self.heap.addContextStringEntries(try self.intern.intern(text), context.items));
}

pub fn writeJsonValue(self: *VM, writer: *std.Io.Writer, value: Value) !void {
    try writeJsonValueWithPathMode(self, writer, value, .raw, null);
}

const JsonPathMode = enum { raw, source };

fn writeJsonValueWithPathMode(
    self: *VM,
    writer: *std.Io.Writer,
    value: Value,
    path_mode: JsonPathMode,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) !void {
    var seen: std.ArrayListUnmanaged(SeenJsonObject) = .empty;
    defer seen.deinit(self.allocator);

    try writeJsonValueInner(self, writer, value, &seen, path_mode, context);
}

const SeenJsonObject = shared.SeenJsonObject;

fn writeJsonValueInner(
    self: *VM,
    writer: *std.Io.Writer,
    value: Value,
    seen: *std.ArrayListUnmanaged(SeenJsonObject),
    path_mode: JsonPathMode,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) anyerror!void {
    // GC: the `context` accumulator holds freshly-produced context values (heap
    // objects not on the VM stack) that must survive the force below and the
    // recursive subtree. Re-root the accumulated entries at this force point; a
    // deeper frame re-roots before its own force, so LIFO truncation is safe.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    if (context) |entries| for (entries.items) |held| vm_force.rootKeep(self, held.value);

    const forced = try vm_force.forceValue(self, value);
    switch (forced.kind()) {
        .null => try writer.writeAll("null"),
        .bool_false => try writer.writeAll("false"),
        .bool_true => try writer.writeAll("true"),
        .int => try writer.print("{}", .{forced.asInt()}),
        .boxed_int => try writer.print("{}", .{try self.heap.getBoxedInt(forced.asObjectId())}),
        .float => {
            var fbuf: [shared.json_float_buffer_size]u8 = undefined;
            try writer.writeAll(shared.jsonFloatText(&fbuf, forced.asFloat()));
        },
        .string, .string_context, .heap_string => try writeJsonStringValue(self, writer, forced, context),
        .path => {
            switch (path_mode) {
                .raw => try std.json.Stringify.encodeJsonString(self.intern.get(forced.asInternId()), .{}, writer),
                .source => {
                    const string_value = try sourcePathStringValue(self, forced.asInternId());
                    try writeJsonStringValue(self, writer, string_value, context);
                },
            }
        },
        .list => try writeJsonList(self, writer, forced.asObjectId(), seen, path_mode, context),
        .attrs => {
            if (try jsonAttrsStringValue(self, forced, path_mode)) |string_value| {
                try writeJsonStringValue(self, writer, string_value, context);
            } else {
                try writeJsonAttrs(self, writer, forced.asObjectId(), seen, path_mode, context);
            }
        },
        .closure, .builtin, .builtin_closure, .partial_app => return error.TypeError,
        .thunk => unreachable,
    }
}

fn writeJsonStringValue(
    self: *VM,
    writer: *std.Io.Writer,
    value: Value,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) !void {
    const text = try vm_strings.stringBytes(self, value);
    // Nix's toJSON errors on invalid UTF-8 (JSON strings must be valid UTF-8).
    if (!std.unicode.utf8ValidateSlice(text)) return error.TypeError;
    try std.json.Stringify.encodeJsonString(text, .{}, writer);
    if (context) |entries| {
        // GC: `value` may be a FRESH context string (path/attrs coercion by the
        // caller) reachable only through this Zig local. `appendContextEntry`
        // forces (context merge) and can collect; root `value` so the context
        // slice being iterated isn't swept mid-loop (w>1 UAF).
        const gc_roots = vm_force.rootsBegin(self);
        defer vm_force.rootsEnd(self, gc_roots);
        vm_force.rootKeep(self, value);
        const cv_ = try contextEntriesForValue(self, value);
        for (cv_.names, cv_.values) |entry_name, entry_value| {
            try appendContextEntry(self, entries, entry_name, entry_value);
        }
    }
}

fn jsonAttrsStringValue(self: *VM, attrs: Value, path_mode: JsonPathMode) !?Value {
    const attrs_id = attrs.asObjectId();

    const to_string_id = try self.intern.intern("__toString");
    if (self.heap.getAttrValue(attrs_id, to_string_id)) |_| {
        return switch (path_mode) {
            .raw => try coerceAttrsToStringValue(self, attrs),
            .source => try coerceStringContextValue(self, attrs),
        };
    } else |err| switch (err) {
        error.MissingAttribute => {},
        else => return err,
    }

    const out_path_id = try self.intern.intern("outPath");
    if (self.heap.getAttrValue(attrs_id, out_path_id)) |_| {
        return switch (path_mode) {
            .raw => try coerceAttrsToStringValue(self, attrs),
            .source => try coerceStringContextValue(self, attrs),
        };
    } else |err| switch (err) {
        error.MissingAttribute => return null,
        else => return err,
    }
}

pub fn jsonAttrsSourceStringValue(self: *VM, attrs: Value) !?Value {
    return jsonAttrsStringValue(self, attrs, .source);
}

fn writeJsonList(
    self: *VM,
    writer: *std.Io.Writer,
    id: ObjectId,
    seen: *std.ArrayListUnmanaged(SeenJsonObject),
    path_mode: JsonPathMode,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) !void {
    if (!try shared.enterJsonObject(self, .list, id, seen)) return error.RecursiveThunk;
    defer _ = seen.pop();

    // GC: `id` is a bare list id whose element slice is force-walked below; keep
    // the list live across the child forces.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, Value.list(id));

    try writer.writeByte('[');
    const n = try self.heap.getListLen(id);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try writer.writeByte(',');
        try writeJsonValueInner(self, writer, try self.heap.getListItem(id, i), seen, path_mode, context);
    }
    try writer.writeByte(']');
}

fn writeJsonAttrs(
    self: *VM,
    writer: *std.Io.Writer,
    id: ObjectId,
    seen: *std.ArrayListUnmanaged(SeenJsonObject),
    path_mode: JsonPathMode,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
) !void {
    if (!try shared.enterJsonObject(self, .attrs, id, seen)) return error.RecursiveThunk;
    defer _ = seen.pop();

    // GC: `sorted` is a private copy of the attr entries whose values reference
    // heap objects reachable only via the attrs object; keep it live across the
    // per-entry forces below.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, Value.attrs(id));

    const sorted = try sortedAttrEntries(self, Value.attrs(id));
    defer self.allocator.free(sorted);

    try writer.writeByte('{');
    for (sorted, 0..) |entry, i| {
        if (i > 0) try writer.writeByte(',');
        try std.json.Stringify.encodeJsonString(self.intern.get(entry.name), .{}, writer);
        try writer.writeByte(':');
        try writeJsonValueInner(self, writer, entry.value, seen, path_mode, context);
    }
    try writer.writeByte('}');
}

pub fn builtinToXML(self: *VM, arg: Value) !Value {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    var context: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer context.deinit(self.allocator);

    // No deep force first: `.strict` forces each value as the walk reaches it,
    // which is how Nix does it and is what lets the `<repeated />` short-circuit
    // work at all. Deep-forcing up front walks a derivation's out/all
    // self-reference before the writer can collapse it.
    try writeXmlDocument(self, &out.writer, try vm_force.forceValue(self, arg), &context, .strict);

    const text = try out.toOwnedSlice();
    defer self.allocator.free(text);
    if (comptime prof.enabled) if (self.workerId() == 0)
        prof_census.recordLongString(text.len, context.items.len != 0);
    if (context.items.len == 0) return vm_strings.makeString(self, text);
    return Value.contextString(try self.heap.addContextStringEntries(try self.intern.intern(text), context.items));
}

pub fn writeLazyXmlValue(self: *VM, writer: *std.Io.Writer, value: Value) !void {
    try writeXmlDocument(self, writer, try vm_force.forceValue(self, value), null, .lazy);
}

/// `builtins.toXML` must render every value (Nix forces during traversal);
/// only the CLI's lazy `--xml` renderer shows still-undemanded thunks as
/// `<unevaluated />`. The distinction matters under speculation: a
/// speculative force resolves thunks WITHOUT marking them demanded, so a
/// demand-flag-sensitive strict render would bake `<unevaluated />` into a
/// cached string that the real demander then observes.
const XmlMode = enum { strict, lazy };

/// Derivations already expanded in this document, keyed by `drvPath`. A
/// derivation reached a second time renders as `<repeated />` instead of its
/// attrs, which is what stops the `out`/`all` self-reference every derivation
/// carries from recursing forever. Document-scoped, as in Nix: two occurrences
/// of one derivation collapse even when neither encloses the other.
const DrvsSeen = std.AutoHashMapUnmanaged(InternId, void);

fn writeXmlDocument(
    self: *VM,
    writer: *std.Io.Writer,
    value: Value,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
    mode: XmlMode,
) !void {
    var drvs_seen: DrvsSeen = .empty;
    defer drvs_seen.deinit(self.allocator);
    try writer.writeAll("<?xml version='1.0' encoding='utf-8'?>\n<expr>\n");
    try writeXmlValue(self, writer, value, 1, context, mode, &drvs_seen);
    try writer.writeAll("</expr>\n");
}

fn writeXmlValue(
    self: *VM,
    writer: *std.Io.Writer,
    value: Value,
    depth: usize,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
    mode: XmlMode,
    drvs_seen: *DrvsSeen,
) anyerror!void {
    // A cyclic value (`let x = { a = x; }; in x`) has no other bound: the walk
    // below recurses on the native stack and the writer keeps producing output,
    // so `--xml` runs until the stack faults or the disk fills. Bound it by call
    // depth rather than a `seen` set — Nix bounds the same shape that way, and a
    // `seen` set would also collapse legitimate sharing, where a DAG's repeated
    // subtree must render once per occurrence.
    try vm_strings.coercionEnter(self);
    defer vm_strings.coercionExit(self);

    const maybe_forced = switch (mode) {
        .strict => try vm_force.forceValue(self, value),
        .lazy => try xmlVisibleValue(self, value),
    };
    const forced = maybe_forced orelse {
        try writeXmlIndent(writer, depth);
        try writer.writeAll("<unevaluated />\n");
        return;
    };

    try writeXmlIndent(writer, depth);
    switch (forced.kind()) {
        .null => try writer.writeAll("<null />\n"),
        .bool_false => try writer.writeAll("<bool value=\"false\" />\n"),
        .bool_true => try writer.writeAll("<bool value=\"true\" />\n"),
        .int => try writer.print("<int value=\"{}\" />\n", .{forced.asInt()}),
        .boxed_int => try writer.print("<int value=\"{}\" />\n", .{try self.heap.getBoxedInt(forced.asObjectId())}),
        .float => try writer.print("<float value=\"{d}\" />\n", .{forced.asFloat()}),
        .string => {
            try writer.writeAll("<string value=\"");
            try writeXmlEscaped(writer, self.intern.get(forced.asInternId()));
            try writer.writeAll("\" />\n");
        },
        .heap_string => {
            try writer.writeAll("<string value=\"");
            try writeXmlEscaped(writer, try vm_strings.stringBytes(self, forced));
            try writer.writeAll("\" />\n");
        },
        .string_context => {
            try writer.writeAll("<string value=\"");
            try writeXmlEscaped(writer, try vm_strings.stringBytes(self, forced));
            try writer.writeAll("\" />\n");
            if (context) |entries| {
                const cv = try contextEntriesForValue(self, forced);
                for (cv.names, cv.values) |entry_name, entry_value| {
                    try appendContextEntry(self, entries, entry_name, entry_value);
                }
            }
        },
        .path => {
            try writer.writeAll("<path value=\"");
            try writeXmlEscaped(writer, self.intern.get(forced.asInternId()));
            try writer.writeAll("\" />\n");
        },
        .list => try writeXmlList(self, writer, forced.asObjectId(), depth, context, mode, drvs_seen),
        .attrs => try writeXmlAttrs(self, writer, forced.asObjectId(), depth, context, mode, drvs_seen),
        .closure => try writeXmlFunction(self, writer, forced, depth),
        .builtin, .builtin_closure, .partial_app => try writer.writeAll("<function />\n"),
        .thunk => unreachable,
    }
}

fn xmlVisibleValue(self: *VM, value: Value) anyerror!?Value {
    return switch (value.kind()) {
        .thunk => xmlThunkValue(self, value.asObjectId()),
        else => value,
    };
}

fn xmlThunkValue(self: *VM, id: ObjectId) anyerror!?Value {
    const thunk = try self.heap.getThunk(id);
    const state: FutureState = thunk.future.stateField(.acquire);
    if (state != .resolved) return null;
    // Speculation can resolve a thunk before any real observer touches it.
    // Lazy XML treats those as still unevaluated so speculation stays
    // invisible — the rendered output matches the no-helper case.
    if (!thunk.isDemanded()) return null;
    return xmlVisibleValue(self, thunk.payload.result);
}

fn writeXmlList(
    self: *VM,
    writer: *std.Io.Writer,
    id: ObjectId,
    depth: usize,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
    mode: XmlMode,
    drvs_seen: *DrvsSeen,
) !void {
    // GC: keep the bare list id live across the child force-walk below, plus the
    // accumulated `context` values (heap objects not on the VM stack).
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, Value.list(id));
    if (context) |entries| for (entries.items) |held| vm_force.rootKeep(self, held.value);

    try writer.writeAll("<list>\n");
    const n = try self.heap.getListLen(id);
    var i: usize = 0;
    while (i < n) : (i += 1) try writeXmlValue(self, writer, try self.heap.getListItem(id, i), depth + 1, context, mode, drvs_seen);
    try writeXmlIndent(writer, depth);
    try writer.writeAll("</list>\n");
}

fn writeXmlAttrs(
    self: *VM,
    writer: *std.Io.Writer,
    id: ObjectId,
    depth: usize,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
    mode: XmlMode,
    drvs_seen: *DrvsSeen,
) !void {
    // GC: `sorted` holds attr-entry values reachable only via the attrs object;
    // keep it live across the per-entry force-walk below, plus the accumulated
    // `context` values (heap objects not on the VM stack).
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, Value.attrs(id));
    if (context) |entries| for (entries.items) |held| vm_force.rootKeep(self, held.value);

    const sorted = try sortedAttrEntries(self, Value.attrs(id));
    defer self.allocator.free(sorted);

    if (try xmlDerivationHeader(self, id, mode)) |drv| {
        try writer.writeAll("<derivation");
        if (drv.drv_path) |p| {
            try writer.writeAll(" drvPath=\"");
            try writeXmlEscaped(writer, self.intern.get(p));
            try writer.writeAll("\"");
        }
        if (drv.out_path) |p| {
            try writer.writeAll(" outPath=\"");
            try writer.writeAll(self.intern.get(p));
            try writer.writeAll("\"");
        }
        try writer.writeAll(">\n");
        // Expand once per document. Without a drvPath there is nothing to key
        // the identity on, so Nix collapses it too rather than risk recursing.
        const expand = if (drv.drv_path) |p| (try drvs_seen.fetchPut(self.allocator, p, {})) == null else false;
        if (expand) {
            try writeXmlAttrEntries(self, writer, sorted, depth, context, mode, drvs_seen);
        } else {
            try writeXmlIndent(writer, depth + 1);
            try writer.writeAll("<repeated />\n");
        }
        try writeXmlIndent(writer, depth);
        try writer.writeAll("</derivation>\n");
        return;
    }

    try writer.writeAll("<attrs>\n");
    try writeXmlAttrEntries(self, writer, sorted, depth, context, mode, drvs_seen);
    try writeXmlIndent(writer, depth);
    try writer.writeAll("</attrs>\n");
}

fn writeXmlAttrEntries(
    self: *VM,
    writer: *std.Io.Writer,
    sorted: []const heap_mod.AttrEntry,
    depth: usize,
    context: ?*std.ArrayListUnmanaged(heap_mod.AttrEntry),
    mode: XmlMode,
    drvs_seen: *DrvsSeen,
) !void {
    for (sorted) |entry| {
        try writeXmlIndent(writer, depth + 1);
        try writer.writeAll("<attr name=\"");
        try writeXmlEscaped(writer, self.intern.get(entry.name));
        try writer.writeAll("\">\n");
        try writeXmlValue(self, writer, entry.value, depth + 2, context, mode, drvs_seen);
        try writeXmlIndent(writer, depth + 1);
        try writer.writeAll("</attr>\n");
    }
}

const XmlDerivation = struct { drv_path: ?InternId, out_path: ?InternId };

/// A `<derivation>` header for an attrset carrying `type = "derivation"`, or
/// null for an ordinary attrset. `drvPath`/`outPath` are omitted individually
/// when absent or non-string, as in Nix -- the element is still a
/// `<derivation>`, since the `type` attr is what decides that.
fn xmlDerivationHeader(self: *VM, id: ObjectId, mode: XmlMode) !?XmlDerivation {
    const type_id = try self.intern.intern("type");
    if (!try equality.attrsHaveDerivationType(self, id, type_id)) return null;
    return .{
        .drv_path = try xmlStringAttr(self, id, "drvPath", mode),
        .out_path = try xmlStringAttr(self, id, "outPath", mode),
    };
}

/// The text of a string-valued attr, interned, or null when it is absent, not
/// a string, or (under `lazy`) not yet evaluated -- a lazy render must not
/// force a thunk just to label the element.
fn xmlStringAttr(self: *VM, id: ObjectId, name: []const u8, mode: XmlMode) !?InternId {
    const name_id = try self.intern.intern(name);
    const raw = self.heap.getAttrValue(id, name_id) catch |err| switch (err) {
        error.MissingAttribute => return null,
        else => return err,
    };
    const forced = switch (mode) {
        .strict => try vm_force.forceValue(self, raw),
        .lazy => (try xmlVisibleValue(self, raw)) orelse return null,
    };
    return switch (forced.kind()) {
        .string, .path => forced.asInternId(),
        .string_context, .heap_string => try self.intern.intern(try vm_strings.stringBytes(self, forced)),
        else => null,
    };
}

/// Render a user closure as Nix does under `--xml`: `<function>` wrapping a
/// `<varpat>` (value lambda) or `<attrspat>` (attrset-pattern lambda). The
/// opening `<function>`'s indent is already emitted by the caller. Falls back
/// to a self-closing `<function />` when the chunk carries no pattern (never
/// happens for real lambdas, but keeps non-lambda closures well-formed).
fn writeXmlFunction(self: *VM, writer: *std.Io.Writer, value: Value, depth: usize) !void {
    const closure = try @import("../closures.zig").closureRef(self, value);
    const ch = self.registry.get(closure.chunk_id) orelse {
        try writer.writeAll("<function />\n");
        return;
    };
    switch (ch.lambda_pattern) {
        .none => {
            try writer.writeAll("<function />\n");
            return;
        },
        .var_pat => |name_id| {
            try writer.writeAll("<function>\n");
            try writeXmlIndent(writer, depth + 1);
            try writer.writeAll("<varpat name=\"");
            try writeXmlEscaped(writer, self.intern.get(name_id));
            try writer.writeAll("\" />\n");
        },
        .attrs_pat => |ap| {
            try writer.writeAll("<function>\n");
            try writeXmlIndent(writer, depth + 1);
            try writer.writeAll("<attrspat");
            if (ap.ellipsis) try writer.writeAll(" ellipsis=\"1\"");
            if (ap.has_bind) {
                try writer.writeAll(" name=\"");
                try writeXmlEscaped(writer, self.intern.get(ap.bind_name));
                try writer.writeAll("\"");
            }
            try writer.writeAll(">\n");

            // Formal names, sorted lexicographically (as Nix prints them).
            const sorted = try self.allocator.dupe(heap_mod.AttrEntry, ch.function_args);
            defer self.allocator.free(sorted);
            try self.intern.sortByNameLex(self.allocator, heap_mod.AttrEntry, sorted);
            for (sorted) |entry| {
                try writeXmlIndent(writer, depth + 2);
                try writer.writeAll("<attr name=\"");
                try writeXmlEscaped(writer, self.intern.get(entry.name));
                try writer.writeAll("\" />\n");
            }
            try writeXmlIndent(writer, depth + 1);
            try writer.writeAll("</attrspat>\n");
        },
    }
    try writeXmlIndent(writer, depth);
    try writer.writeAll("</function>\n");
}

fn writeXmlIndent(writer: *std.Io.Writer, depth: usize) !void {
    for (0..depth) |_| try writer.writeAll("  ");
}

/// Exactly Nix's `XMLWriter` escape set, byte for byte — `toXML` output is a
/// string value programs diff and hash, so parity outranks XML hygiene here.
/// Notably `'` stays literal (attributes are always `"`-delimited), while a
/// newline becomes a character reference because an XML parser would otherwise
/// normalise it to a space inside an attribute. Tab and CR are left raw despite
/// suffering the same normalisation; Nix does not escape them either.
fn writeXmlEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\n' => try writer.writeAll("&#xA;"),
        else => try writer.writeByte(c),
    };
}

pub fn builtinFromJSON(self: *VM, arg: Value) !Value {
    const text = try stringArg(self, arg);
    // Duplicate object keys keep the last value, matching Nix (`{"k":1,"k":2}`
    // → `{ k = 2; }`) rather than erroring.
    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, text, .{
        .duplicate_field_behavior = .use_last,
    });
    defer parsed.deinit();
    return valueFromJson(self, parsed.value);
}

fn valueFromJson(self: *VM, value: std.json.Value) anyerror!Value {
    return switch (value) {
        .null => Value.null_val,
        .bool => |b| Value.boolVal(b),
        .integer => |i| int_mod.make(self.heap, i),
        .float => |f| Value.float(f),
        .number_string => |s| numberStringFromJson(self, s),
        .string => |s| try vm_strings.makeString(self, s),
        .array => |array| listFromJson(self, array.items),
        .object => |object| attrsFromJson(self, object),
    };
}

fn numberStringFromJson(self: *VM, text: []const u8) !Value {
    if (std.fmt.parseInt(i64, text, 10)) |i| return int_mod.make(self.heap, i) else |_| {}
    return Value.float(std.fmt.parseFloat(f64, text) catch return error.TypeError);
}

fn listFromJson(self: *VM, values: []const std.json.Value) !Value {
    const items = try self.allocator.alloc(Value, values.len);
    defer self.allocator.free(items);
    for (values, items) |item, *out| out.* = try valueFromJson(self, item);
    return Value.list(try self.heap.addList(items));
}

fn attrsFromJson(self: *VM, object: std.json.ObjectMap) !Value {
    const entries = try self.allocator.alloc(heap_mod.AttrEntry, object.count());
    defer self.allocator.free(entries);

    var iter = object.iterator();
    var index: usize = 0;
    while (iter.next()) |entry| : (index += 1) {
        entries[index] = .{
            .name = try self.intern.intern(entry.key_ptr.*),
            .value = try valueFromJson(self, entry.value_ptr.*),
        };
    }
    return Value.attrs(try self.heap.addAttrs(entries));
}

pub fn builtinFromTOML(self: *VM, arg: Value) !Value {
    const text = try stringArg(self, arg);
    var parsed = try toml.parse(self.allocator, text);
    defer parsed.deinit();
    return valueFromToml(self, .{ .table = parsed.root });
}

fn valueFromToml(self: *VM, value: toml.Value) anyerror!Value {
    return switch (value) {
        .boolean => |b| Value.boolVal(b),
        .integer => |i| int_mod.make(self.heap, i),
        .float => |f| Value.float(f),
        .string => |s| try vm_strings.makeString(self, s),
        .array => |items| listFromToml(self, items),
        .table => |table| attrsFromToml(self, table),
    };
}

fn listFromToml(self: *VM, values: []const toml.Value) !Value {
    const items = try self.allocator.alloc(Value, values.len);
    defer self.allocator.free(items);
    for (values, items) |item, *out| out.* = try valueFromToml(self, item);
    return Value.list(try self.heap.addList(items));
}

fn attrsFromToml(self: *VM, table: *toml.Table) !Value {
    const entries = try self.allocator.alloc(heap_mod.AttrEntry, table.entries.items.len);
    defer self.allocator.free(entries);
    for (table.entries.items, entries) |entry, *out| {
        out.* = .{
            .name = try self.intern.intern(entry.key),
            .value = try valueFromToml(self, entry.value),
        };
    }
    return Value.attrs(try self.heap.addAttrs(entries));
}

pub fn builtinCompareVersions(self: *VM, left_arg: Value, right_arg: Value) !Value {
    const left_value = try vm_force.forceValue(self, left_arg);
    const right_value = try vm_force.forceValue(self, right_arg);
    if (!isPlainString(left_value) or !isPlainString(right_value)) return error.TypeError;
    const left = try vm_strings.stringBytes(self, left_value);
    const right = try vm_strings.stringBytes(self, right_value);
    return Value.int(try version.compareVersions(self.allocator, left, right));
}

pub fn builtinSplitVersion(self: *VM, arg: Value) !Value {
    const text = try stringArg(self, arg);
    const parts = try version.splitVersion(self.allocator, text);
    defer self.allocator.free(parts);

    const values = try self.allocator.alloc(Value, parts.len);
    defer self.allocator.free(values);
    for (parts, values) |part, *value| {
        value.* = Value.string(try self.intern.intern(part));
    }
    return Value.list(try self.heap.addList(values));
}

/// Resolve the compiled pattern for a regex builtin: through the
/// evaluator's shared `PatternCache` when wired (`owned` stays null),
/// else compiled locally into `owned` (standalone test VMs), which the
/// caller deinits via `defer`.
fn resolvePattern(self: *VM, pattern_id: InternId, owned: *?regex.Pattern) !*const regex.Pattern {
    if (self.regexes) |cache| return cache.get(pattern_id, self.intern.get(pattern_id));
    owned.* = try regex.Pattern.compile(self.allocator, self.intern.get(pattern_id));
    return &owned.*.?;
}

pub fn builtinMatch(self: *VM, regex_arg: Value, text_arg: Value) !Value {
    const pattern_value = try vm_force.forceValue(self, regex_arg);
    const text_value = try vm_force.forceValue(self, text_arg);
    if (!isPlainString(pattern_value) or !isPlainString(text_value)) return error.TypeError;
    // The PatternCache is keyed by intern id, so a heap-resident pattern
    // interns here (patterns are short and bounded in number).
    const pattern_id = try vm_strings.stringNameId(self, pattern_value);
    const text = try vm_strings.stringBytes(self, text_value);

    var owned: ?regex.Pattern = null;
    defer if (owned) |*p| p.deinit();
    const pattern = try resolvePattern(self, pattern_id, &owned);

    const matched = (try pattern.matchFull(self.allocator, text)) orelse return Value.null_val;
    defer matched.deinit(self.allocator);
    return regexCapturesValue(self, matched.captures);
}

pub fn builtinSplit(self: *VM, regex_arg: Value, text_arg: Value) !Value {
    const pattern_value = try vm_force.forceValue(self, regex_arg);
    const text_value = try vm_force.forceValue(self, text_arg);
    if (!isPlainString(pattern_value) or !isPlainString(text_value)) return error.TypeError;
    const pattern_id = try vm_strings.stringNameId(self, pattern_value);
    const text = try vm_strings.stringBytes(self, text_value);

    var owned: ?regex.Pattern = null;
    defer if (owned) |*p| p.deinit();
    const pattern = try resolvePattern(self, pattern_id, &owned);

    var out: std.ArrayListUnmanaged(Value) = .empty;
    defer out.deinit(self.allocator);

    var cursor: usize = 0;
    var search_start: usize = 0;
    while (search_start <= text.len) {
        const found = (try pattern.find(self.allocator, text, search_start)) orelse break;
        errdefer found.deinit(self.allocator);

        try out.append(self.allocator, try vm_strings.makeString(self, text[cursor..found.start]));
        try out.append(self.allocator, try regexCapturesValue(self, found.captures));

        cursor = found.end;
        // A zero-length match must not advance `cursor`, only the next search
        // position: the character stepped over belongs to the FOLLOWING
        // separator's prefix. Emitting it as an element of its own would add a
        // string where the 2n+1 alternation demands a capture list, which every
        // consumer indexing `split` by parity relies on.
        search_start = if (found.start == found.end) found.end + 1 else found.end;
        found.deinit(self.allocator);
    }

    try out.append(self.allocator, try vm_strings.makeString(self, text[cursor..]));
    return Value.list(try self.heap.addList(out.items));
}

fn regexCapturesValue(self: *VM, captures: []const ?[]const u8) !Value {
    const values = try self.allocator.alloc(Value, captures.len);
    defer self.allocator.free(values);

    for (captures, values) |capture, *value| {
        value.* = if (capture) |text|
            try vm_strings.makeString(self, text)
        else
            Value.null_val;
    }
    return Value.list(try self.heap.addList(values));
}

pub fn builtinParseDrvName(self: *VM, arg: Value) !Value {
    const parsed = version.parseDrvName(try stringArg(self, arg));
    const entries = [_]heap_mod.AttrEntry{
        .{
            .name = try self.intern.intern("name"),
            .value = Value.string(try self.intern.intern(parsed.name)),
        },
        .{
            .name = try self.intern.intern("version"),
            .value = Value.string(try self.intern.intern(parsed.version)),
        },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}
