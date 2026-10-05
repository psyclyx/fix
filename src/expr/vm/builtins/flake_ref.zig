//! `builtins.parseFlakeRef` and `builtins.flakeRefToString`: the values
//! around `fetchers.flakeref`, which parses and prints flake references as
//! Nix does.

const std = @import("std");
const VM = @import("../context.zig").VM;
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;
const int_mod = @import("runtime").int;
const flakeref = @import("fetchers").flakeref;
const strings = @import("strings.zig");
const string_context = @import("string_context.zig");
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_trace = @import("../trace.zig");

/// The attributes of a flake reference string. An indirect reference
/// (`nixpkgs`) stays indirect: the registry resolves it when it's fetched.
pub fn parse(self: *VM, arg: Value) !Value {
    return parseRef(self, arg, false);
}

/// A flake input's reference, which may be a path relative to its flake.
pub fn parseInput(self: *VM, arg: Value) !Value {
    return parseRef(self, arg, true);
}

fn parseRef(self: *VM, arg: Value, input: bool) !Value {
    const value = try vm_force.forceValue(self, arg);
    if (!strings.isPlainString(value)) return vm_trace.typeErrorExpected(self, "a string", value);
    if (value.isContextString() and (try string_context.contextEntriesForValue(self, value)).len() != 0) {
        try vm_trace.setErrorMessage(self, "a flake reference must not refer to a store path");
        return error.InvalidFlakeRef;
    }
    const text = try vm_strings.stringBytes(self, value);

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    var diagnostic: flakeref.Diagnostic = .{};
    const parse_fn = if (input) &flakeref.parseInput else &flakeref.parse;
    const attrs = parse_fn(arena.allocator(), &diagnostic, text) catch |err| return report(self, err, diagnostic);

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    for (attrs.list.items) |attr| {
        try entries.append(self.allocator, .{
            .name = try self.intern.intern(attr.name),
            .value = switch (attr.value) {
                .string => |s| Value.string(try self.intern.intern(s)),
                .int => |n| try int_mod.make(self.heap, @bitCast(n)),
                .boolean => |b| Value.boolVal(b),
            },
        });
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

/// The canonical string of a flake reference's attributes, which may only
/// be strings, integers and Booleans.
pub fn render(self: *VM, arg: Value) !Value {
    const attrs_value = try vm_force.forceValue(self, arg);
    if (!attrs_value.isAttrs()) return vm_trace.typeErrorExpected(self, "a set", attrs_value);
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, attrs_value);

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var attrs: flakeref.Attrs = .{};
    const attrs_id = attrs_value.asObjectId();
    const n = (try self.heap.materializeAttrs(attrs_id)).len();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const view = try self.heap.materializeAttrs(attrs_id);
        const name = try a.dupe(u8, self.intern.get(view.names[i]));
        const value = try vm_force.forceValue(self, view.values[i]);
        const converted: flakeref.Value = if (int_mod.isAnyInt(value))
            .{ .int = @bitCast(int_mod.get(value, self.heap)) }
        else if (value.isBool())
            .{ .boolean = value.asBool() }
        else if (strings.isPlainString(value))
            .{ .string = try a.dupe(u8, try vm_strings.stringBytes(self, value)) }
        else {
            const message = try std.fmt.allocPrint(self.allocator, "flake reference attribute sets may only contain integers, Booleans, and strings, but attribute '{s}' is {s}", .{ name, vm_trace.valueTypeName(self, value) });
            defer self.allocator.free(message);
            try vm_trace.setErrorMessage(self, message);
            return error.TypeError;
        };
        try attrs.put(a, name, converted);
    }

    var diagnostic: flakeref.Diagnostic = .{};
    const text = flakeref.render(a, &diagnostic, attrs) catch |err| return report(self, err, diagnostic);
    return vm_strings.makeString(self, text);
}

fn report(self: *VM, err: flakeref.Error, diagnostic: flakeref.Diagnostic) anyerror {
    if (err == error.InvalidFlakeRef) try vm_trace.setErrorMessage(self, diagnostic.message);
    return err;
}
