//! Error reporting onto the VM's trace object: set/push error messages, the
//! type-error and not-callable constructors, and human-readable value type names.
const std = @import("std");
const vm_mod = @import("context.zig");
const Value = @import("runtime").value.Value;
const InternId = @import("runtime").types.InternId;

const VM = vm_mod.VM;

pub fn setErrorMessage(self: *VM, message: []const u8) !void {
    if (self.trace) |trace| try trace.setMessage(message);
}

pub fn pushErrorContext(self: *VM, message: []const u8) !void {
    if (self.trace) |trace| try trace.pushContext(message);
}

/// The logical call-depth cap (Nix's `max-call-depth`) has been exceeded.
/// Sets the canonical Nix message and raises. Used by the frame-push and
/// tail-call paths (`stack.pushFrame` / `closures.replaceCurrentFrame*`).
pub fn callDepthExceeded(self: *VM) error{CallDepthExceeded} {
    if (self.trace) |trace| {
        trace.setMessage("stack overflow; max-call-depth exceeded") catch {};
    }
    return error.CallDepthExceeded;
}

/// The running fiber's native stack is near exhaustion. Deep thunk *forcing*
/// (a lazy chain reduced to WHNF) recurses on the fiber's fixed stack but,
/// unlike function application, is NOT bounded by `max-call-depth` — thunk
/// bodies run with `is_call = false`. Raise a graceful error a margin short of
/// the mapping's end so we never run into the guardless unmapped page below it
/// (a raw SIGSEGV). See `exec_context.stack_limit` and `force.forceThunkImpl`.
pub fn stackOverflow(self: *VM) error{StackOverflow} {
    if (self.trace) |trace| {
        trace.setMessage("stack overflow (possible infinite recursion)") catch {};
    }
    return error.StackOverflow;
}

pub fn clearErrorTrace(self: *VM) void {
    if (self.trace) |trace| trace.clear();
}

pub fn typeErrorExpected(self: *VM, expected: []const u8, got: Value) error{TypeError} {
    if (self.trace) |trace| {
        const message = std.fmt.allocPrint(self.allocator, "expected {s}, got {s}", .{ expected, valueTypeName(self, got) }) catch return error.TypeError;
        defer self.allocator.free(message);
        trace.setMessageIfAbsent(message) catch {};
    }
    return error.TypeError;
}

/// A string-coercion failure, phrased like Nix ("cannot coerce X to a string").
pub fn coercionError(self: *VM, got: Value) error{TypeError} {
    if (self.trace) |trace| {
        const message = std.fmt.allocPrint(self.allocator, "cannot coerce {s} to a string", .{valueTypeName(self, got)}) catch return error.TypeError;
        defer self.allocator.free(message);
        trace.setMessageIfAbsent(message) catch {};
    }
    return error.TypeError;
}

pub fn notCallableError(self: *VM, got: Value) error{NotCallable} {
    if (self.trace) |trace| {
        const message = std.fmt.allocPrint(self.allocator, "expected function, got {s}", .{valueTypeName(self, got)}) catch return error.NotCallable;
        defer self.allocator.free(message);
        trace.setMessageIfAbsent(message) catch {};
    }
    return error.NotCallable;
}

pub fn unexpectedArgument(self: *VM, name: InternId) error{UnexpectedAttribute} {
    argumentError(self, "called with unexpected argument", name);
    return error.UnexpectedAttribute;
}

pub fn missingArgument(self: *VM, name: InternId) error{MissingAttribute} {
    argumentError(self, "called without required argument", name);
    return error.MissingAttribute;
}

fn argumentError(self: *VM, comptime problem: []const u8, name: InternId) void {
    const trace = self.trace orelse return;
    const message = std.fmt.allocPrint(self.allocator, "function " ++ problem ++ " '{s}'", .{self.intern.get(name)}) catch return;
    defer self.allocator.free(message);
    trace.setMessageIfAbsent(message) catch {};
}

pub fn valueTypeName(self: *VM, value: Value) []const u8 {
    _ = self;
    return switch (value.kind()) {
        .null => "null",
        .bool_false, .bool_true => "bool",
        .int, .boxed_int => "int",
        .float => "float",
        .string => "string",
        .path => "path",
        .list => "list",
        .attrs => "attrs",
        .closure, .builtin, .builtin_closure, .partial_app => "function",
        .thunk => "thunk",
        .string_context, .heap_string => "string",
    };
}
