//! Nix string-context builtins: getContext, hasContext, appendContext, and
//! the unsafeDiscard*/addDrvOutputDependencies context manipulators, plus the
//! context-entry helpers those and other builtin families share.

const std = @import("std");
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const strings = @import("strings.zig");
const context_merge = @import("../context_merge.zig");
const vm_force = @import("../force.zig");
const vm_trace = @import("../trace.zig");
const vm_strings = @import("../strings.zig");

/// The context-merge algorithm now lives in `vm/context_merge.zig`. Re-exported
/// here so the many `string_context.appendContextEntry` call sites (and this
/// file's own builtins) share the one canonical, GC-safe implementation.
pub const appendContextEntry = context_merge.appendContextEntry;

pub fn builtinGetContext(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    // getContext does not coerce — a path or derivation is a type error (unlike
    // string concatenation, which coerces them).
    if (value.kind() != .string and value.kind() != .string_context and value.kind() != .heap_string) {
        return vm_trace.typeErrorExpected(self, "a string", value);
    }
    return Value.attrs(try self.heap.addAttrsView(try contextEntriesForValue(self, value)));
}

pub fn builtinHasContext(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    return Value.boolVal((try contextEntriesForValue(self, value)).len() != 0);
}

pub fn builtinAppendContext(self: *VM, string_arg: Value, context_arg: Value) !Value {
    const string_value = try vm_force.forceValue(self, string_arg);
    if (!strings.isStringLike(string_value)) return error.TypeError;
    const context_value = try vm_force.forceValue(self, context_arg);
    if (!context_value.isAttrs()) return error.TypeError;

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    {
        const sv = try contextEntriesForValue(self, string_value);
        for (sv.names, sv.values) |n, v| try appendContextEntry(self, &entries, n, v);
        const cv = try self.heap.materializeAttrs(context_value.asObjectId());
        for (cv.names, cv.values) |n, v| try appendContextEntry(self, &entries, n, v);
    }

    if (entries.items.len == 0) return Value.string(try strings.stringNameId(self, string_value));
    return Value.contextString(try self.heap.addContextStringEntries(try strings.stringNameId(self, string_value), entries.items));
}

pub fn builtinUnsafeDiscardStringContext(self: *VM, arg: Value) !Value {
    // Nix coerces the argument to a string first (paths, derivations, and
    // `__toString` attrsets are accepted), then drops the context.
    const value = try strings.coerceStringContextValue(self, arg);
    // A plain heap string has no context to discard; hand it back rather
    // than interning it.
    if (value.isHeapString()) return value;
    return Value.string(try strings.stringTextInternId(self, value));
}

pub fn builtinUnsafeDiscardOutputDependency(self: *VM, arg: Value) !Value {
    // Nix coerces the argument as `"${…}"` does (a path is copied to the
    // store), then turns a dependency on all of a derivation's outputs (a
    // `drvPath`) into a dependency on the `.drv` file itself. Dependencies
    // on single outputs (`"${drv}"`) and on plain paths stay as they are.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    const value = try vm_strings.coerceLanguageStringValue(self, arg);
    vm_force.rootKeep(self, value);
    const text_id = try strings.stringNameId(self, value);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    {
        const cv = try contextEntriesForValue(self, value);
        for (cv.names, cv.values) |n, v| try appendContextEntry(self, &entries, n, try withoutAllOutputs(self, v));
    }
    if (entries.items.len == 0) return Value.string(text_id);
    return Value.contextString(try self.heap.addContextStringEntries(text_id, entries.items));
}

/// A context descriptor with `allOutputs` replaced by `path`, keeping any
/// `outputs`.
fn withoutAllOutputs(self: *VM, descriptor: Value) !Value {
    const forced = try vm_force.forceValue(self, descriptor);
    if (!forced.isAttrs()) return forced;
    const id = forced.asObjectId();
    const all_outputs = (try self.heap.getAttrValueOpt(id, try self.intern.intern("allOutputs"))) orelse return forced;
    if (!(try vm_force.forceValue(self, all_outputs)).asBool()) return forced;

    var entries: [2]heap_mod.AttrEntry = undefined;
    var n: usize = 0;
    entries[n] = .{ .name = try self.intern.intern("path"), .value = Value.boolVal(true) };
    n += 1;
    const outputs_id = try self.intern.intern("outputs");
    if (try self.heap.getAttrValueOpt(id, outputs_id)) |outputs| {
        entries[n] = .{ .name = outputs_id, .value = outputs };
        n += 1;
    }
    return Value.attrs(try self.heap.addAttrs(entries[0..n]));
}

pub fn builtinAddDrvOutputDependencies(self: *VM, arg: Value) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!strings.isStringLike(value)) return vm_trace.typeErrorExpected(self, "a string", value);
    const text_id = try strings.stringNameId(self, value);

    // Nix requires the context to have exactly one element, which must be a
    // bare derivation (`.drv`), not one of its outputs.
    const ctx = try contextEntriesForValue(self, value);
    if (ctx.len() != 1) {
        try vm_trace.setErrorMessage(self, "context of string must have exactly one element, but has a different number");
        return error.TypeError;
    }
    const entry_name = ctx.names[0];
    if (!std.mem.endsWith(u8, self.intern.get(entry_name), ".drv")) {
        try vm_trace.setErrorMessage(self, "addDrvOutputDependencies can only act on derivations");
        return error.TypeError;
    }
    // A `{ outputs = [...] }` marker means the element is a derivation OUTPUT,
    // which is rejected; `path`/`allOutputs` markers are the derivation itself.
    const marker = try vm_force.forceValue(self, ctx.values[0]);
    if (marker.isAttrs()) {
        const outputs_id = try self.intern.intern("outputs");
        if (self.heap.getAttrValue(marker.asObjectId(), outputs_id)) |_| {
            try vm_trace.setErrorMessage(self, "addDrvOutputDependencies can only act on derivations, not on a derivation output");
            return error.TypeError;
        } else |err| switch (err) {
            error.MissingAttribute => {},
            else => return err,
        }
    }

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    try context_merge.appendContextEntry(self, &entries, entry_name, try allOutputsContextValue(self));
    return Value.contextString(try self.heap.addContextStringEntries(text_id, entries.items));
}

pub fn contextEntriesForValue(self: *VM, value: Value) !heap_mod.AttrsView {
    return switch (value.kind()) {
        .string, .heap_string => .{ .names = &.{}, .values = &.{} },
        .path => try singleContextEntry(self, value.asInternId(), try pathContextValue(self)),
        .string_context => (try self.heap.getContextString(value.asObjectId())).context,
        else => error.TypeError,
    };
}

pub fn singleContextEntry(self: *VM, name: InternId, value: Value) !heap_mod.AttrsView {
    const names = try self.allocator.alloc(InternId, 1);
    const values = try self.allocator.alloc(Value, 1);
    names[0] = name;
    values[0] = value;
    return .{ .names = names, .values = values };
}

pub fn pathContextValue(self: *VM) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("path"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn allOutputsContextValue(self: *VM) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("allOutputs"), .value = Value.boolVal(true) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

pub fn contextStringWithPath(self: *VM, text_id: InternId) !Value {
    return contextStringTextWithPath(self, text_id, text_id);
}

/// Like `contextStringWithPath`, but the string text (`text_id`) may differ
/// from the store path recorded in its context (`path_id`). A plain-eval fetch
/// uses this: its text is a readable download-cache path while its context
/// references the real fixed-output store path (so `builtins.getContext`
/// matches Nix even though there is no store to materialize the path).
pub fn contextStringTextWithPath(self: *VM, text_id: InternId, path_id: InternId) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = path_id, .value = try pathContextValue(self) },
    };
    return Value.contextString(try self.heap.addContextStringEntries(text_id, &entries));
}
