//! Builds the runtime attrset Value that `derivation` returns: the derivation
//! attrs (type, drvPath, outputName, outPath, per-output sub-attrs, `all`) with
//! string context wiring drvPath/outPath back to the .drv and its outputs.

const std = @import("std");
const heap_mod = @import("runtime").heap;
const InternTable = @import("runtime").intern.InternTable;
const Value = @import("runtime").value.Value;
const types = @import("types.zig");

const AttrEntry = heap_mod.AttrEntry;
const ObjectHeap = heap_mod.ObjectHeap;
const InternId = @import("runtime").types.InternId;
const ValueOutput = types.ValueOutput;
const ValueSpec = types.ValueSpec;

pub fn buildValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    spec: ValueSpec,
) !Value {
    const output_values = try allocator.alloc(Value, spec.outputs.len);
    defer allocator.free(output_values);
    for (spec.outputs, output_values) |output, *output_value| {
        output_value.* = try buildSelectedValue(allocator, intern, heap, spec, output, null);
    }

    const default = outputByName(spec.outputs, spec.default_output) orelse return error.InvalidDerivationOutput;
    return buildSelectedValue(allocator, intern, heap, spec, default, output_values);
}

pub fn buildStrictValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    spec: ValueSpec,
) !Value {
    var entries: std.ArrayListUnmanaged(AttrEntry) = .empty;
    defer entries.deinit(allocator);

    try entries.append(allocator, .{
        .name = try intern.intern("drvPath"),
        .value = try drvPathString(intern, heap, spec.drv_path),
    });
    for (spec.outputs) |output| {
        try entries.append(allocator, .{
            .name = output.name,
            .value = try outputPathString(intern, heap, spec.drv_path, output),
        });
    }

    return Value.attrs(try heap.addAttrs(entries.items));
}

fn buildSelectedValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    spec: ValueSpec,
    selected: ValueOutput,
    output_values: ?[]const Value,
) !Value {
    var entries: std.ArrayListUnmanaged(AttrEntry) = .empty;
    defer entries.deinit(allocator);

    for (spec.original_attrs.names, spec.original_attrs.values) |entry_name, entry_value| {
        if (isSyntheticName(intern, intern.get(entry_name), spec.outputs)) continue;
        try entries.append(allocator, .{ .name = entry_name, .value = entry_value });
    }

    try entries.append(allocator, .{
        .name = try intern.intern("type"),
        .value = Value.string(try intern.intern("derivation")),
    });
    try entries.append(allocator, .{
        .name = try intern.intern("outputName"),
        .value = Value.string(selected.name),
    });
    try entries.append(allocator, .{
        .name = try intern.intern("drvPath"),
        .value = try drvPathString(intern, heap, spec.drv_path),
    });
    try entries.append(allocator, .{
        .name = try intern.intern("drvAttrs"),
        .value = Value.attrs(try heap.addAttrsView(spec.original_attrs)),
    });

    try entries.append(allocator, .{
        .name = try intern.intern("outPath"),
        .value = try outputPathString(intern, heap, spec.drv_path, selected),
    });

    const nested_output_values = if (output_values) |values|
        values
    else
        try outputReferenceValues(allocator, intern, heap, spec);
    defer if (output_values == null) allocator.free(nested_output_values);

    for (spec.outputs, nested_output_values) |output, output_value| {
        try entries.append(allocator, .{
            .name = output.name,
            .value = output_value,
        });
    }
    const all = try allocator.alloc(Value, if (spec.declared.len != 0) spec.declared.len else spec.outputs.len);
    defer allocator.free(all);
    if (spec.declared.len != 0) {
        for (spec.declared, all) |name, *value| {
            for (spec.outputs, nested_output_values) |output, output_value| {
                if (output.name == name) value.* = output_value;
            }
        }
    } else @memcpy(all, nested_output_values);
    try entries.append(allocator, .{
        .name = try intern.intern("all"),
        .value = Value.list(try heap.addList(all)),
    });

    return Value.attrs(try heap.addAttrs(entries.items));
}

fn outputReferenceValues(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *ObjectHeap,
    spec: ValueSpec,
) ![]Value {
    const values = try allocator.alloc(Value, spec.outputs.len);
    errdefer allocator.free(values);
    for (spec.outputs, values) |output, *value| {
        value.* = try buildOutputReferenceValue(intern, heap, spec, output);
    }
    return values;
}

fn buildOutputReferenceValue(
    intern: *InternTable,
    heap: *ObjectHeap,
    spec: ValueSpec,
    output: ValueOutput,
) !Value {
    const entries = [_]AttrEntry{
        .{
            .name = try intern.intern("type"),
            .value = Value.string(try intern.intern("derivation")),
        },
        .{
            .name = try intern.intern("outputName"),
            .value = Value.string(output.name),
        },
        .{
            .name = try intern.intern("drvPath"),
            .value = try drvPathString(intern, heap, spec.drv_path),
        },
        .{
            .name = try intern.intern("outPath"),
            .value = try outputPathString(intern, heap, spec.drv_path, output),
        },
    };
    return Value.attrs(try heap.addAttrs(&entries));
}

pub fn isSyntheticName(intern: *InternTable, name: []const u8, outputs: []const ValueOutput) bool {
    // Not `outputs`: the value has the `outputs` it was given, as in Nix's
    // `derivation.nix` (`drvAttrs // …`).
    const synthetic = [_][]const u8{ "type", "outputName", "outPath", "drvPath", "drvAttrs", "all" };
    for (synthetic) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    for (outputs) |output| {
        if (std.mem.eql(u8, name, intern.get(output.name))) return true;
    }
    return false;
}

fn drvPathString(
    intern: *InternTable,
    heap: *ObjectHeap,
    drv_path: InternId,
) !Value {
    const all_outputs = [_]AttrEntry{
        .{ .name = try intern.intern("allOutputs"), .value = Value.boolVal(true) },
    };
    const context_value = Value.attrs(try heap.addAttrs(&all_outputs));
    const context = [_]AttrEntry{
        .{ .name = drv_path, .value = context_value },
    };
    return Value.contextString(try heap.addContextStringEntries(drv_path, &context));
}

fn outputPathString(
    intern: *InternTable,
    heap: *ObjectHeap,
    drv_path: InternId,
    output: ValueOutput,
) !Value {
    if (output.missing) |missing| return missing;
    const output_values = [_]Value{Value.string(output.name)};
    const outputs = [_]AttrEntry{
        .{ .name = try intern.intern("outputs"), .value = Value.list(try heap.addList(&output_values)) },
    };
    const context_value = Value.attrs(try heap.addAttrs(&outputs));
    const context = [_]AttrEntry{
        .{ .name = drv_path, .value = context_value },
    };
    return Value.contextString(try heap.addContextStringEntries(output.out_path, &context));
}

fn outputByName(outputs: []const ValueOutput, name: InternId) ?ValueOutput {
    for (outputs) |output| {
        if (output.name == name) return output;
    }
    return null;
}
