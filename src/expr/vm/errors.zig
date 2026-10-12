//! Error-trace capture: walk the VM frame stack turning each frame's source span
//! into a "while evaluating" diagnostic note, plus the span-resolution helpers
//! (frame / chunk-entry / tightest-span-for-ip) shared with the timeline.
const std = @import("std");
const vm_mod = @import("context.zig");
const chunk = @import("../bytecode.zig").chunk;
const diagnostic = @import("syntax").diagnostic;
const failure_mod = @import("runtime").failure;
const ErrorTrace = @import("../observ.zig").trace.Trace;

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const FailureFrame = failure_mod.FailureFrame;
const FailureRef = failure_mod.FailureRef;

pub fn captureErrorTrace(self: *VM, err: anyerror) !void {
    const ctx = self.executionContext();
    const propagating = ctx.pending() != null;
    if (!propagating) {
        const message = if (self.trace) |trace|
            trace.message orelse defaultErrorMessage(err)
        else
            defaultErrorMessage(err);
        const frame_count: usize = self.debugFrameDepth();
        const allocated: ?[]FailureFrame = self.allocator.alloc(FailureFrame, frame_count) catch null;
        defer if (allocated) |frames| self.allocator.free(frames);
        const captured: []FailureFrame = allocated orelse @constCast(&[_]FailureFrame{});
        var len: usize = 0;
        var cursor: ?*const VM = self;
        while (cursor) |vm| : (cursor = vm.debug.parent) {
            var i: usize = vm.frames_len;
            while (i > 0 and len < captured.len) {
                i -= 1;
                const frame = vm.frames[i];
                captured[len] = .{ .chunk_id = frame.chunk_id, .ip = @intCast(frame.ip) };
                len += 1;
            }
        }
        ctx.capture(self.heap.captureFailure(err, message, captured[0..len]));
    }

    // A speculative observer of an already-frozen failure carries identity
    // only. The genuine demander later supplies its own continuation.
    if (propagating and self.speculation.active) return;

    const trace = self.trace orelse return;
    if (trace.captured_stack) return;
    try renderFailureTrace(self, ctx.pending().?, trace, false);
}

/// Materialize a cached failure at a genuine-demand boundary. The immutable
/// record owns the helper's origin; the currently running demand VM contributes
/// the continuation that did not exist on the speculative fiber.
pub fn captureDemandErrorTrace(self: *VM, err: anyerror) !void {
    const ctx = self.executionContext();
    if (ctx.pending() == null) return captureErrorTrace(self, err);
    const trace = self.trace orelse return;
    if (trace.captured_stack) return;
    try renderFailureTrace(self, ctx.pending().?, trace, true);
}

/// Resolve a frozen compact failure into the caller's trace. The immutable
/// origin remains authoritative; genuine demand may append its live
/// continuation without changing the record.
fn renderFailureTrace(self: *VM, failure: FailureRef, trace: *ErrorTrace, demand_continuation: bool) !void {
    var contexts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer contexts.deinit(self.allocator);
    var origin: ?failure_mod.FailureRecord.Origin = null;
    var current = failure;
    while (current.record()) |record| switch (record.*) {
        .context => |context| {
            try contexts.append(self.allocator, context.message);
            current = context.cause;
        },
        .origin => |captured_origin| {
            origin = captured_origin;
            break;
        },
    };

    if (origin) |captured_origin| {
        try trace.setMessageIfAbsent(captured_origin.message);
        if (!trace.frames_disabled) {
            const boundary = try renderOriginFrames(self, trace, captured_origin.frames);
            if (demand_continuation) try renderDemandContinuation(self, trace, boundary);
        }
    } else {
        try trace.setMessageIfAbsent(defaultErrorMessage(current.err()));
        if (demand_continuation and !trace.frames_disabled)
            try renderDemandContinuation(self, trace, null);
    }
    // Context records are traversed outer-to-inner, while Nix trace order is
    // origin frames followed by cause-first contexts.
    var i = contexts.items.len;
    while (i > 0) {
        i -= 1;
        try trace.pushContext(contexts.items[i]);
    }
    trace.markCapturedStack();
}

fn renderOriginFrames(self: *VM, trace: *ErrorTrace, frames: []const FailureFrame) !?chunk.Chunk.SourceSpan {
    var previous: ?chunk.Chunk.SourceSpan = null;
    for (frames) |failure_frame| {
        const chunk_ptr = self.registry.get(failure_frame.chunk_id) orelse continue;
        const span = sourceSpanForChunk(chunk_ptr, failure_frame.ip) orelse continue;
        if (previous) |prev| if (sameSourceSpan(prev, span)) continue;
        previous = span;
        try pushEvaluationFrame(self, trace, failure_frame.chunk_id, span);
    }
    return previous;
}

/// Append the live demander stack after a frozen helper origin. Only adjacent
/// boundary spans are collapsed; repeated frames elsewhere remain meaningful.
fn renderDemandContinuation(
    self: *VM,
    trace: *ErrorTrace,
    origin_boundary: ?chunk.Chunk.SourceSpan,
) !void {
    var previous = origin_boundary;
    var cursor: ?*const VM = self;
    while (cursor) |vm| : (cursor = vm.debug.parent) {
        var i: usize = vm.frames_len;
        while (i > 0) {
            i -= 1;
            const frame = vm.frames[i];
            const span = sourceSpanForFrame(frame) orelse continue;
            if (previous) |prev| if (sameSourceSpan(prev, span)) continue;
            previous = span;
            try pushEvaluationFrame(self, trace, frame.chunk_id, span);
        }
    }
}

fn pushEvaluationFrame(
    self: *VM,
    trace: *ErrorTrace,
    chunk_id: @import("runtime").types.ChunkId,
    span: chunk.Chunk.SourceSpan,
) !void {
    // Attribute the frame to its qualified name when available.
    var name_buf: [512]u8 = undefined;
    const message = frameMessage(self, chunk_id, &name_buf);
    const diag_frame = diagnostic.Diagnostic{
        .severity = .note,
        .kind = .compile,
        .line = span.line,
        .column = span.column,
        .offset = span.offset,
        .len = span.len,
        .token_type = null,
        .message = message,
    };
    const source_path = if (span.file) |file| self.intern.get(file) else null;
    try trace.pushDiagnosticFrame(source_path, diag_frame);
}

/// The `while evaluating [<name>]` note for a frame, rendering the chunk's
/// qualified name into `buf` when it has one (else the bare note). Cold path.
fn frameMessage(self: *VM, chunk_id: @import("runtime").types.ChunkId, buf: []u8) []const u8 {
    if (!self.registry.hasQualifiedName(chunk_id)) return "while evaluating";
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("while evaluating '") catch return "while evaluating";
    self.registry.writeQualifiedName(&w, chunk_id, self.intern) catch return "while evaluating";
    w.writeByte('\'') catch return "while evaluating";
    return buf[0..w.end];
}

pub fn sourceSpanForFrame(frame: Frame) ?chunk.Chunk.SourceSpan {
    return sourceSpanForChunk(frame.chunk_ptr, frame.ip);
}

/// A chunk's representative source span for labelling a THUNK (which starts at
/// ip 0). Source maps are SPARSE — spans are added only for tail/apply
/// constructs, in code order — so ip 0 is usually uncovered by
/// `sourceSpanForChunk`; use the earliest recorded span instead. Null if the
/// chunk has no source map.
pub fn chunkEntrySpan(chunk_ptr: *const chunk.Chunk) ?chunk.Chunk.SourceSpan {
    // The body span covers every chunk (set at compile from the body node);
    // fall back to the earliest source-map entry for chunks that skipped it.
    if (chunk_ptr.body_span) |s| return s;
    if (chunk_ptr.source_map.len == 0) return null;
    return chunk_ptr.source_map[0].span;
}

/// The tightest source span covering `ip` in `chunk_ptr` (or null if the chunk
/// carries no source map). `ip == 0` resolves the chunk's entry point — used by
/// the timeline to label a thunk quantum with the expression it forces.
pub fn sourceSpanForChunk(chunk_ptr: *const chunk.Chunk, ip: usize) ?chunk.Chunk.SourceSpan {
    if (chunk_ptr.source_map.len == 0) return null;
    const pc = if (ip == 0) 0 else ip - 1;
    var best: ?chunk.Chunk.SourceMapEntry = null;
    for (chunk_ptr.source_map) |entry| {
        if (pc < entry.start or pc >= entry.end) continue;
        const b = best orelse {
            best = entry;
            continue;
        };
        const entry_range = entry.end - entry.start;
        const best_range = b.end - b.start;
        // Tightest code range wins; equal code ranges (an expression that IS
        // the whole enclosing construct, e.g. a `let` dissolved into its
        // body) tie-break on the narrower source span — the innermost
        // expression is the truest attribution.
        if (entry_range < best_range or
            (entry_range == best_range and entry.span.len <= b.span.len))
        {
            best = entry;
        }
    }
    return if (best) |entry| entry.span else null;
}

pub fn sameSourceSpan(left: chunk.Chunk.SourceSpan, right: chunk.Chunk.SourceSpan) bool {
    return left.file == right.file and
        left.offset == right.offset and
        left.len == right.len and
        left.line == right.line and
        left.column == right.column;
}

pub fn defaultErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.TypeError => "type error",
        error.StackOverflow => "stack overflow (possible infinite recursion)",
        error.NotCallable => "value is not callable",
        error.MissingAttribute => "missing attribute",
        error.UndefinedVariable => "undefined variable",
        error.DivisionByZero => "division by zero",
        error.AssertionFailed => "assertion failed",
        error.RecursiveThunk => "infinite recursion encountered",
        error.ImportCycle => "import cycle detected",
        error.FileNotFound => "No such file or directory",
        error.UnsupportedPathType => "file has an unsupported type",
        error.MissingExperimentalFeature => "experimental feature disabled",
        else => @errorName(err),
    };
}
