//! Nix error and tracing builtins: throw, abort, tryEval, addErrorContext,
//! and trace/traceVerbose.

const std = @import("std");
const VM = @import("../context.zig").VM;
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_trace = @import("../trace.zig");
const effect_message = @import("../effect_message.zig");
const effects = @import("../../effects.zig");
const error_capture = @import("../errors.zig");
const ErrorTrace = @import("../../observ.zig").trace.Trace;
const FailureRef = @import("runtime").failure.FailureRef;

/// Pause into the debugger at an evaluation error, unless we're inside a
/// `tryEval` (a caught error) or no debugger is attached. `value` is shown as
/// the error subject (the thrown message, or the offending value). Returns
/// normally so the caller still propagates the original error; only a `:q`
/// abort from the console surfaces as an error here.
pub fn debugBreakError(self: *VM, value: Value) !void {
    if (self.executionContextConst().tryeval_depth != 0) return;
    if (self.debug.break_sink) |sink| {
        self.effect_epoch +%= 1;
        try sink.fire(sink.ctx, self, value, .eval_error);
    }
}

pub fn builtinThrow(self: *VM, message_arg: Value) !Value {
    try vm_trace.setErrorMessage(self, try strings.stringArg(self, message_arg));
    try debugBreakError(self, message_arg);
    return error.NixThrow;
}

pub fn builtinAbort(self: *VM, message_arg: Value) !Value {
    // Framed as Nix frames it, so an abort reads differently from a throw:
    // the two are no longer interchangeable now that tryEval catches only one.
    const message = try std.fmt.allocPrint(
        self.allocator,
        "evaluation aborted with the following error message: '{s}'",
        .{try strings.stringArg(self, message_arg)},
    );
    defer self.allocator.free(message);
    try vm_trace.setErrorMessage(self, message);
    try debugBreakError(self, message_arg);
    return error.NixAbort;
}

pub fn builtinTryEval(self: *VM, arg: Value) !Value {
    // Suppress debugger error-entry for errors caught here.
    const ctx = self.executionContext();
    ctx.tryeval_depth += 1;
    defer ctx.tryeval_depth -= 1;
    // Nix catches exactly ThrownError and AssertionError here. `abort` is
    // uncatchable by design -- it means "this evaluation must not continue" --
    // and an I/O failure is not a language-level exception, so both propagate.
    const value = vm_force.forceValue(self, arg) catch |err| switch (err) {
        error.NixThrow,
        error.AssertionFailed,
        => {
            ctx.clearFailure();
            vm_trace.clearErrorTrace(self);
            return tryEvalResult(self, false, Value.boolVal(false));
        },
        else => return err,
    };
    return tryEvalResult(self, true, value);
}

pub fn builtinAddErrorContext(self: *VM, message_arg: Value, value_arg: Value) !Value {
    return vm_force.forceValue(self, value_arg) catch |err| {
        // The force path normally captured this already. Keep the fallback so
        // direct/foreign errors still receive a stable origin.
        error_capture.captureErrorTrace(self, err) catch {};
        const ctx = self.executionContext();
        const cause = ctx.take() orelse FailureRef.degraded(err);

        // Coercing the context message is itself fallible. Give it an isolated
        // trace and empty carrier; any resulting exception is discarded before
        // the original is restored, so diagnostics can never cross-associate.
        const saved_trace = self.trace;
        var message_trace = ErrorTrace.init(self.allocator);
        defer message_trace.deinit();
        self.trace = &message_trace;
        const message = strings.stringArg(self, message_arg) catch {
            self.trace = saved_trace;
            ctx.clearFailure();
            ctx.restore(cause);
            return err;
        };
        self.trace = saved_trace;
        ctx.clearFailure();
        const wrapped = self.heap.addFailureContext(cause, message);
        ctx.restore(wrapped);
        // If the origin has already been materialized into this demand trace,
        // append the new context now. A future cached observer reconstructs it
        // from `wrapped` instead.
        vm_trace.pushErrorContext(self, message) catch {};
        return err;
    };
}

/// `builtins.break x` — identity on `x`, but when a debugger is attached it
/// first pauses into the interactive debug session (Nix's `--debugger`
/// behaviour). With no debugger (`break_sink == null`, the normal case) this
/// is a plain forced identity, so it costs nothing off the debug path.
pub fn builtinBreak(self: *VM, arg: Value) !Value {
    if (self.debug.break_sink) |sink| {
        // Debugger installation disables speculation at the Engine seam;
        // marking this body effectful also keeps repeated calls out of the
        // bytecode-result memo.
        self.effect_epoch +%= 1;
        try sink.fire(sink.ctx, self, arg, .break_builtin);
    }
    return vm_force.forceValue(self, arg);
}

pub fn builtinTrace(self: *VM, message_arg: Value, value_arg: Value) !Value {
    const message = try effect_message.render(self, try vm_force.forceValue(self, message_arg));
    defer message.deinit(self.allocator);
    try emitLanguageEffect(self, .trace, message.text);
    return vm_force.forceValue(self, value_arg);
}

pub fn builtinTraceVerbose(self: *VM, message_arg: Value, value_arg: Value) !Value {
    // Matching Nix: when trace-verbose is off the message is not forced.
    // Still keep the enclosing body out of the pure memo: the setting is an
    // evaluator option and embeddings may change it between evaluations.
    if (!self.trace_verbose) {
        self.effect_epoch +%= 1;
        return vm_force.forceValue(self, value_arg);
    }
    const message = try effect_message.render(self, try vm_force.forceValue(self, message_arg));
    defer message.deinit(self.allocator);
    try emitLanguageEffect(self, .trace, message.text);
    return vm_force.forceValue(self, value_arg);
}

/// `builtins.warn msg x` — evaluate `x` and return it, emitting `msg` as a
/// warning (to stderr, which the conformance runner ignores). `msg` must be a
/// string, matching Nix.
pub fn builtinWarn(self: *VM, message_arg: Value, value_arg: Value) !Value {
    const message = try effect_message.sanitizeString(self, try strings.stringArg(self, message_arg));
    defer message.deinit(self.allocator);
    try emitLanguageEffect(self, .warning, message.text);
    return vm_force.forceValue(self, value_arg);
}

fn emitLanguageEffect(self: *VM, kind: effects.Kind, message: []const u8) !void {
    const store = self.effects orelse return;
    self.effect_epoch +%= 1;
    if (self.speculation.active) {
        try store.hold(&self.effect_journal, self.allocator, kind, message);
    } else {
        store.emitNow(kind, message);
    }
}

pub fn tryEvalResult(self: *VM, success: bool, value: Value) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{
            .name = try self.intern.intern("success"),
            .value = Value.boolVal(success),
        },
        .{
            .name = try self.intern.intern("value"),
            .value = value,
        },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}
