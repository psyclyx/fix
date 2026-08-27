//! Threaded bytecode dispatcher.
//!
//! Every opcode is a small standalone function with the signature
//! `fn (vm, frame, code, ip, stop_depth) anyerror!Value`. Each handler
//! does its per-opcode work and tail-calls `dispatch`, which reads the
//! next opcode byte and tail-calls its handler via a static table.
//!
//! `@call(.always_tail, ...)` forces LLVM to emit a `jmp` rather than a
//! `call`, so handlers never push frames — the whole dispatch chain
//! reuses a single stack frame established by the outermost `runUntil`.
//!
//! Separate handlers keep per-opcode control flow and register allocation
//! local instead of building one monolithic dispatch function.

const std = @import("std");
const vm_mod = @import("context.zig");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const bytecode_mod = @import("../bytecode.zig");
const opcode = bytecode_mod.opcode;
const OpCode = opcode.OpCode;
const heap_mod = @import("runtime").heap;
const numeric = @import("runtime").numeric;
const prof = @import("../probe.zig").prof;
const prof_census = @import("../probe.zig").prof_census;

const access = @import("access.zig");
const builtin_errors = @import("builtins/errors.zig");
const closures = @import("closures.zig");
const debug = @import("debug.zig");
const equality = @import("equality.zig");
const force = @import("force.zig");
const objects = @import("objects.zig");
const stack = @import("stack.zig");
const strings = @import("strings.zig");
const trace = @import("trace.zig");
const trace_log = @import("trace_log.zig");

const VM = vm_mod.VM;
const Frame = vm_mod.Frame;
const readU16 = vm_mod.readU16;
const readU32 = vm_mod.readU32;

const HandlerFn = *const fn (*VM, *Frame, []const u8, usize, usize) anyerror!void;

// ---- entry points ----
//
// Handlers return `anyerror!void` because `anyerror!Value` is 24 bytes
// on x86-64 SysV, which forces the ABI to return-by-sret-pointer,
// which in turn prevents LLVM from `musttail`-jumping between handlers
// (sret slot wouldn't match across the chain). Instead each handler
// either pushes its produced value onto the VM's value stack (the
// normal case) or leaves the dispatch chain via a normal return when
// the chunk's frame is popped. `runUntil` pops the final result off
// `vm.stack` and hands it back to its caller.

pub fn run(vm: *VM) anyerror!Value {
    return runUntil(vm, 0);
}

pub fn runUntil(vm: *VM, stop_depth: usize) anyerror!Value {
    const frame = stack.currentFrame(vm);
    try dispatchEntry(vm, frame, vm.executableCode(frame.chunk_id, frame.chunk_ptr), frame.ip, stop_depth);
    return stack.pop(vm);
}

/// Non-inline trampoline so `runUntil` (sig: `(vm, stop_depth)`) can
/// kick off the dispatch chain without violating the
/// matching-signature requirement of `@call(.always_tail)`. The body
/// is just an inlined `dispatch`, which ends in a tail call to the
/// first handler — that tail call is *from* this function, whose sig
/// matches the handler sig.
fn dispatchEntry(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- dispatch ----

/// Read the next opcode at `code[ip]` and tail-call its handler with
/// `ip + 1` (so the handler sees `ip` pointing at the first operand
/// byte). Inlined into every handler's epilogue so the dispatch chain
/// is a sequence of direct tail-jumps — no per-handler stack frame.
inline fn dispatch(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    if (ip >= code.len) return endOfCode(vm);
    if (comptime debug.enabled) {
        debug.checkVm(vm, "dispatch");
        debug.checkFrameSync(vm, frame, code, "dispatch");
    }
    const op: OpCode = @enumFromInt(code[ip]);
    if (comptime trace_log.enabled) {
        trace_log.op(vm.vm_trace, vm.workerId(), vm.frames_len, frame.chunk_id, @intCast(ip), op, vm.sp);
    }
    return @call(.always_tail, handlers[@intFromEnum(op)], .{ vm, frame, code, ip + 1, stop_depth });
}

/// End of chunk reached without a `ret` — ensure there's at least one
/// value on the stack for `runUntil` to pop.
fn endOfCode(vm: *VM) anyerror!void {
    if (vm.sp == 0) try stack.push(vm, Value.null_val);
}

// ---- handlers: stack ----

fn opConstant(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const idx = readU16(code, ip);
    try stack.push(vm, frame.chunk_ptr.constants[idx]);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opPushNull(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    try stack.push(vm, Value.null_val);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opPushTrue(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    try stack.push(vm, Value.boolVal(true));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opPushFalse(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    try stack.push(vm, Value.boolVal(false));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opPop(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    _ = stack.pop(vm);
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- handlers: locals ----

const SlotOp = enum { get, grab, set, cell_set, cell_init, get_ret, get_attr };

/// Specialize the repeated narrow/wide local-slot operations at comptime. The
/// width changes only operand decoding and the following instruction offset;
/// keeping their semantics here prevents the variants from drifting apart.
fn slotOp(comptime operation: SlotOp, comptime wide: bool) HandlerFn {
    return struct {
        fn op(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
            if (operation != .get_ret) frame.ip = ip;
            const operand_len: usize = if (wide) 2 else 1;
            const slot: u32 = if (wide) readU16(code, ip) else code[ip];
            switch (operation) {
                .get => {
                    const raw = vm.stack[frame.frame_base + slot];
                    if (comptime prof.enabled) {
                        if (vm.workerId() == 0 and force.profIsResolvedThunk(vm, raw)) prof_census.rf_local += 1;
                    }
                    const val = try force.forceValue(vm, raw);
                    // Slot writeback: a forced thunk reference becomes its
                    // WHNF in place, so repeat reads skip the heap deref.
                    // The stack is fiber-private and root-scanned; no other
                    // reference is affected (the slot holds a copy).
                    if (raw.bits != val.bits) stack.setStack(vm, frame.frame_base + slot, val);
                    try stack.push(vm, val);
                    return dispatch(vm, frame, code, ip + operand_len, stop_depth);
                },
                .grab => {
                    try stack.push(vm, vm.stack[frame.frame_base + slot]);
                    return dispatch(vm, frame, code, ip + operand_len, stop_depth);
                },
                .set => {
                    stack.setStack(vm, frame.frame_base + slot, stack.pop(vm));
                    return dispatch(vm, frame, code, ip + operand_len, stop_depth);
                },
                .cell_set => {
                    const val = stack.pop(vm);
                    const cell_val = vm.stack[frame.frame_base + slot];
                    if (!cell_val.isThunk()) return error.TypeError;
                    const thunk = vm.heap.getThunkAssumeValid(cell_val.asObjectId());
                    // Binding cells are born claimed; publishing installs the
                    // pass-through value and wakes any parked helper.
                    if (vm.solo) thunk.publishCellBindingSolo(val) else thunk.publishCellBinding(val);
                    vm.heap.gcRecordEdge(cell_val.asObjectId(), val);
                    return dispatch(vm, frame, code, ip + operand_len, stop_depth);
                },
                .cell_init => {
                    vm.stack[frame.frame_base + slot] = try force.makeBindingCell(vm);
                    return dispatch(vm, frame, code, ip + operand_len, stop_depth);
                },
                .get_ret => {
                    const result = try force.forceValue(vm, vm.stack[frame.frame_base + slot]);
                    return retEpilogue(vm, stop_depth, result);
                },
                .get_attr => {
                    const name_id = readU16(code, ip + operand_len);
                    const result = try access.getAttrValue(vm, vm.stack[frame.frame_base + slot], @intCast(name_id));
                    try stack.push(vm, result);
                    return dispatch(vm, frame, code, ip + operand_len + 2, stop_depth);
                },
            }
        }
    }.op;
}

fn opCaptureUpvalue(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const upvalues = frame.upvalues orelse return error.MissingClosure;
    try stack.push(vm, upvalues[slot]);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opGetUpvalue(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const upvalues = frame.upvalues orelse return error.MissingClosure;
    if (comptime prof.enabled) {
        if (vm.workerId() == 0 and force.profIsResolvedThunk(vm, upvalues[slot])) prof_census.rf_upvalue += 1;
    }
    const raw = upvalues[slot];
    const val = try force.forceValue(vm, raw);
    writebackUpvalue(vm, frame, upvalues, slot, raw, val);
    try stack.push(vm, val);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

/// Slot writeback for closure upvalues (SOLO mode only): replace a forced
/// thunk reference with its WHNF so every later read through this closure
/// skips the thunk deref. Requirements that gate it:
///   - `vm.solo`: a plain 8-byte store into a shared closure would be a
///     data race at w>1 (benign-identical in practice, but the w>1 design
///     needs atomic slot access end-to-end — not built until measurement
///     justifies it).
///   - `upvalue_owner != null`: the store adds an owner→result edge the
///     remembered set must see (a null owner means thunk/stack-backed
///     slices whose owner id is unavailable here — skipped).
fn writebackUpvalue(vm: *VM, frame: *Frame, upvalues: []const Value, slot: u16, raw: Value, val: Value) void {
    if (!vm.solo or raw.bits == val.bits) return;
    const owner = frame.upvalue_owner orelse return;
    @constCast(upvalues)[slot] = val;
    vm.heap.gcRecordEdge(owner, val);
}

fn opGetUpvalueRet(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    const slot = readU16(code, ip);
    const upvalues = frame.upvalues orelse return error.MissingClosure;
    const raw = upvalues[slot];
    const result = try force.forceValue(vm, raw);
    writebackUpvalue(vm, frame, upvalues, slot, raw, result);
    return retEpilogue(vm, stop_depth, result);
}

// ---- handlers: integer arithmetic ----

fn opAddInt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // Force both operands in place (they stay on the stack, so a GC at
    // either force keeps both rooted); drop only after. `forceAt` is the
    // GC-safe primitive — never `forceValue(pop())`. See vm/force.zig.
    const b = try force.forceTop(vm);
    const a = try force.forceAt(vm, 1);
    if (numeric.isNumeric(a) and numeric.isNumeric(b)) {
        stack.dropBin(vm);
        try stack.push(vm, try numeric.add(vm.heap, a, b));
    } else {
        // GC: the string/path concat helpers force BOTH operands again
        // (coerceLanguageStringValue → forceValue + possible callValue/
        // getAttrValue on a `__toString`/`outPath` attrset — GC safepoints)
        // while the other operand is held only in a Zig local. Keep both on
        // the operand stack across the concat so they stay precise roots;
        // drop only after.
        const result = if (a.isPath())
            try strings.concatPathLike(vm, a, b)
        else
            try strings.concatStringLike(vm, a, b);
        stack.dropBin(vm);
        try stack.push(vm, result);
    }
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opSubInt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, try numeric.sub(vm.heap, a, b));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opMulInt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, try numeric.mul(vm.heap, a, b));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opDivInt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, try numeric.div(vm.heap, a, b));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opNegateInt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const a = stack.pop(vm);
    try stack.push(vm, try numeric.negate(vm.heap, a));
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- handlers: float arithmetic ----

fn opAddFloat(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, Value.float(try numeric.toFloat(a, vm.heap) + try numeric.toFloat(b, vm.heap)));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opSubFloat(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, Value.float(try numeric.toFloat(a, vm.heap) - try numeric.toFloat(b, vm.heap)));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opMulFloat(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    try stack.push(vm, Value.float(try numeric.toFloat(a, vm.heap) * try numeric.toFloat(b, vm.heap)));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opDivFloat(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const b = stack.pop(vm);
    const a = stack.pop(vm);
    const bf = try numeric.toFloat(b, vm.heap);
    // Parity with Nix: float division by zero raises rather than
    // producing IEEE Inf/NaN. The `numeric.div` path enforces the same
    // rule for the fallthrough cases; `opDivFloat` is the hot path the
    // compiler emits when either operand is statically a float.
    if (bf == 0.0) return error.DivisionByZero;
    try stack.push(vm, Value.float(try numeric.toFloat(a, vm.heap) / bf));
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- handlers: comparison ----

fn opEq(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // Operands stay on the stack across valuesEqual (which forces deeply, a
    // GC safepoint) so they remain precise roots; drop only after.
    const ops = stack.binTop(vm);
    // Fast path: two immediate (unboxed) ints — by far the most common `==`
    // (loop counters, filter predicates like `bitAnd x 3 == 0`). Skip the
    // seen-list alloc, the two forceValue calls, and the recursive dispatch.
    if (ops.left.isInt() and ops.right.isInt()) {
        const result = ops.left.asInt() == ops.right.asInt();
        stack.dropBin(vm);
        try stack.push(vm, Value.boolVal(result));
        return dispatch(vm, frame, code, ip, stop_depth);
    }
    const result = try equality.valuesEqual(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(result));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opNeq(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    if (ops.left.isInt() and ops.right.isInt()) {
        const result = ops.left.asInt() == ops.right.asInt();
        stack.dropBin(vm);
        try stack.push(vm, Value.boolVal(!result));
        return dispatch(vm, frame, code, ip, stop_depth);
    }
    const result = try equality.valuesEqual(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(!result));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opEqNull(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const v = try force.forceValue(vm, stack.pop(vm));
    try stack.push(vm, Value.boolVal(v.kind() == .null));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opNeqNull(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const v = try force.forceValue(vm, stack.pop(vm));
    try stack.push(vm, Value.boolVal(v.kind() != .null));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opLt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const r = try equality.compareValues(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(r == .lt));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opLte(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const r = try equality.compareValues(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(r == .lt or r == .eq));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opGt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const r = try equality.compareValues(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(r == .gt));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opGte(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const r = try equality.compareValues(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, Value.boolVal(r == .gt or r == .eq));
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- handlers: logical ----

fn opNot(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const a = stack.pop(vm);
    try stack.push(vm, Value.boolVal(!try expectBool(vm, a)));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opCheckBool(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const a = vm.stack[vm.sp - 1];
    vm.stack[vm.sp - 1] = Value.boolVal(try expectBool(vm, a));
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- handlers: control flow ----

fn opJump(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const offset = readU32(code, ip);
    return dispatch(vm, frame, code, ip + 4 + @as(usize, offset), stop_depth);
}

fn opJumpIfFalse(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const offset = readU32(code, ip);
    var next_ip = ip + 4;
    const cond = vm.stack[vm.sp - 1];
    if (!try expectBool(vm, cond)) {
        next_ip += @as(usize, offset);
    }
    return dispatch(vm, frame, code, next_ip, stop_depth);
}

/// A source-line breakpoint (patched over another opcode's byte by the
/// debugger). Pause into the debugger at this location, then chain to the
/// original opcode's handler — the operands were never touched, and `ip`
/// already points past the (same-position) opcode byte. Never reached unless a
/// breakpoint is set, so the normal dispatch path pays nothing.
fn opBreakpoint(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    const off: u32 = @intCast(ip - 1);
    frame.ip = ip;
    const Hit = bytecode_mod.breakpoints.BreakpointTable.Hit;
    const h: Hit = if (vm.debug.breakpoints) |bps|
        bps.hit(frame.chunk_id, frame.chunk_ptr, off, vm.debugFrameDepth())
    else
        .{ .original = @intFromEnum(OpCode.halt), .pause = false, .kind = .none };
    if (h.pause) {
        if (vm.debug.break_sink) |sink| {
            const reason: vm_mod.BreakReason = switch (h.kind) {
                .step => .step,
                .entry => .entry,
                else => .line_breakpoint,
            };
            vm.effect_epoch +%= 1;
            sink.fire(sink.ctx, vm, Value.null_val, reason) catch |e| return e;
        }
    }
    return @call(.always_tail, handlers[h.original], .{ vm, frame, code, ip, stop_depth });
}

fn opFailAssertion(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    _ = frame;
    _ = code;
    _ = ip;
    _ = stop_depth;
    // Debugger error-entry (no-op unless a debugger is attached and we're not
    // inside a tryEval): pause at the failing assertion before unwinding.
    try builtin_errors.debugBreakError(vm, Value.null_val);
    return error.AssertionFailed;
}

// ---- handlers: data structures ----

fn opBuildAttrs(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    try objects.buildAttrs(vm, count);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opBuildAttrsSorted(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    try objects.buildAttrsSorted(vm, count, &.{});
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opBuildAttrsNamedSorted(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    const names_start = readU32(code, ip + 2);
    const names = frame.chunk_ptr.attr_names;
    if (names_start + count > names.len) return error.InvalidBytecode;
    try objects.buildAttrsNamedSorted(vm, names[names_start .. names_start + count], count, .none);
    return dispatch(vm, frame, code, ip + 6, stop_depth);
}

fn opBuildAttrsNamed(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    const names_start = readU32(code, ip + 2);
    const names = frame.chunk_ptr.attr_names;
    if (names_start + count > names.len) return error.InvalidBytecode;
    try objects.buildAttrsNamed(vm, names[names_start .. names_start + count], count, .none);
    return dispatch(vm, frame, code, ip + 6, stop_depth);
}

fn opBuildAttrsNamedPosSorted(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    const names_start = readU32(code, ip + 2);
    const pos_count = readU16(code, ip + 6);
    const pos_start = readU32(code, ip + 8);
    const names = frame.chunk_ptr.attr_names;
    const table = frame.chunk_ptr.attr_pos;
    if (names_start + count > names.len or pos_start + pos_count > table.len) return error.InvalidBytecode;
    // The registry outlives the heap, so literal attrsets can borrow this
    // immutable table slice without teaching runtime objects about chunks.
    try objects.buildAttrsNamedSorted(vm, names[names_start .. names_start + count], count, .borrowed(table[pos_start .. pos_start + pos_count]));
    return dispatch(vm, frame, code, ip + 12, stop_depth);
}

fn opBuildAttrsNamedPos(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    const names_start = readU32(code, ip + 2);
    const pos_count = readU16(code, ip + 6);
    const pos_start = readU32(code, ip + 8);
    const names = frame.chunk_ptr.attr_names;
    const table = frame.chunk_ptr.attr_pos;
    if (names_start + count > names.len or pos_start + pos_count > table.len) return error.InvalidBytecode;
    try objects.buildAttrsNamed(vm, names[names_start .. names_start + count], count, .borrowed(table[pos_start .. pos_start + pos_count]));
    return dispatch(vm, frame, code, ip + 12, stop_depth);
}

fn opBuildList(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    try objects.buildList(vm, count);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opMergeAttrs(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // Keep both operands on the stack across mergeAttrs (forces + allocates,
    // a GC safepoint) so they stay precise roots; drop only after.
    const ops = stack.binTop(vm);
    const t = prof.start(.merge_attrs);
    const merged = try objects.mergeAttrs(vm, ops.left, ops.right);
    prof.end(.merge_attrs, t);
    stack.dropBin(vm);
    try stack.push(vm, merged);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opMergeAttrsStrict(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const t = prof.start(.merge_attrs);
    const merged = try objects.mergeAttrsStrict(vm, ops.left, ops.right);
    prof.end(.merge_attrs, t);
    stack.dropBin(vm);
    try stack.push(vm, merged);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opConcatLists(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const ops = stack.binTop(vm);
    const result = try objects.concatLists(vm, ops.left, ops.right);
    stack.dropBin(vm);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opConcatListsN(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    const result = try objects.concatStackLists(vm, count);
    stack.dropN(vm, count);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opConcatStrings(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    // Operands stay on the stack across the coercions/forces inside
    // (precise GC roots); drop only after the result is built.
    const result = try strings.concatStackStrings(vm, count);
    stack.dropN(vm, count);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opConcatPath(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const count = readU16(code, ip);
    // Operands stay on the stack across the coercions/forces inside (precise
    // GC roots); drop only after the result is built.
    const result = try strings.concatStackPath(vm, count);
    stack.dropN(vm, count);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opPushBuiltins(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    try stack.push(vm, vm.builtins);
    return dispatch(vm, frame, code, ip, stop_depth);
}

const InternOp = enum { find_file, get_attr, has_attr_strict, lookup_with };

/// Handlers whose only encoding distinction is a u16/u32 intern id.
fn internOp(comptime operation: InternOp, comptime wide: bool) HandlerFn {
    return struct {
        fn op(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
            frame.ip = ip;
            const operand_len: usize = if (wide) 4 else 2;
            const name_id: InternId = if (wide) readU32(code, ip) else readU16(code, ip);
            switch (operation) {
                .find_file => {
                    const host = vm.import_host orelse return error.SearchPathUnavailable;
                    try stack.push(vm, try host.find_file(host.context, vm.intern.get(name_id)));
                    return dispatch(vm, frame, code, ip + operand_len, stop_depth);
                },
                .get_attr => {
                    const attrs_val = vm.stack[vm.sp - 1];
                    vm.stack[vm.sp - 1] = try access.getAttrValue(vm, attrs_val, name_id);
                    return dispatch(vm, frame, code, ip + operand_len, stop_depth);
                },
                .has_attr_strict => {
                    const attrs = try force.forceValue(vm, vm.stack[vm.sp - 1]);
                    if (!attrs.isAttrs()) return trace.typeErrorExpected(vm, "attrs", attrs);
                    vm.stack[vm.sp - 1] = Value.boolVal((try vm.heap.getAttrValueOpt(attrs.asObjectId(), name_id)) != null);
                    return dispatch(vm, frame, code, ip + operand_len, stop_depth);
                },
                .lookup_with => {
                    try access.lookupWith(vm, name_id, code[ip + operand_len]);
                    return dispatch(vm, frame, code, ip + operand_len + 1, stop_depth);
                },
            }
        }
    }.op;
}

// ---- handlers: closures and thunks ----

fn closureOp(comptime wide: bool) HandlerFn {
    return struct {
        fn op(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
            frame.ip = ip;
            const id_len: usize = if (wide) 4 else 2;
            const ch_id: ChunkId = if (wide) readU32(code, ip) else readU16(code, ip);
            try closures.makeClosure(vm, ch_id, readU16(code, ip + id_len));
            return dispatch(vm, frame, code, ip + id_len + 2, stop_depth);
        }
    }.op;
}

/// Config for `capOp`: every capture-carrying thunk/closure/arg op is this one
/// body specialized by comptime flags — the ops are literally a bit-field
/// (`{kind, wide, eager, store}`) resolved at compile time, so each `capOp(cfg)`
/// monomorphizes to exactly the straight-line handler the hand-written variant
/// had. `thunk_defer`/`thunk_attr` stay bespoke (different operand shape).
const CapCfg = struct {
    /// Which value the op creates (selects the `closures.make*` call).
    kind: enum { thunk, closure, arg },
    /// Wide (u32) vs narrow (u16) chunk id.
    wide: bool,
    /// Fused thunk+store (`_st`): bind the new thunk into a slot directly
    /// (`local`) or through the slot's cell (`cell`). Thunk-only.
    store: ?enum { local, cell } = null,
};

fn capOp(comptime cfg: CapCfg) fn (*VM, *Frame, []const u8, usize, usize) anyerror!void {
    return struct {
        fn op(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
            frame.ip = ip;
            const id_len: usize = if (cfg.wide) 4 else 2;
            const ch_id: u32 = if (cfg.wide) readU32(code, ip) else readU16(code, ip);
            const upvalue_count = readU16(code, ip + id_len);
            const descriptors_start = ip + id_len + 2;
            const descriptor_len = @as(usize, upvalue_count) * 3;
            if (descriptor_len > code.len - descriptors_start) return error.InvalidBytecode;
            const descriptors = code[descriptors_start .. descriptors_start + descriptor_len];
            switch (cfg.kind) {
                .thunk => try closures.makeBytecodeThunkFromCaptures(vm, ch_id, descriptors, frame),
                .closure => try closures.makeClosureFromCaptures(vm, ch_id, descriptors, frame),
                .arg => {
                    // The callee sits just below the arg slot; if it forces its
                    // parameter, evaluate eagerly, else materialise the thunk.
                    const callee = vm.stack[vm.sp - 1];
                    if (closures.calleeForcesArg(vm, callee))
                        try closures.evalArgEager(vm, ch_id, descriptors, frame)
                    else
                        try closures.makeBytecodeThunkFromCaptures(vm, ch_id, descriptors, frame);
                },
            }
            const after = descriptors_start + descriptor_len;
            if (cfg.store) |st| {
                // Slot byte trails the descriptors; bind the just-pushed thunk.
                const slot = code[after];
                const val = stack.pop(vm);
                switch (st) {
                    .cell => {
                        const cell_val = vm.stack[frame.frame_base + slot];
                        if (!cell_val.isThunk()) return error.TypeError;
                        const cell_thunk = vm.heap.getThunkAssumeValid(cell_val.asObjectId());
                        if (vm.solo) cell_thunk.publishCellBindingSolo(val) else cell_thunk.publishCellBinding(val);
                        vm.heap.gcRecordEdge(cell_val.asObjectId(), val); // old→young barrier
                    },
                    .local => stack.setStack(vm, frame.frame_base + slot, val),
                }
                return dispatch(vm, frame, code, after + 1, stop_depth);
            }
            return dispatch(vm, frame, code, after, stop_depth);
        }
    }.op;
}

fn opDeferAttrValue(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const deferred_id: u32 = readU32(code, ip);
    // The capture list is interned in the chunk's side table (deduped across an
    // attrset's values); the op carries a (start, count) reference.
    const cap_start = readU32(code, ip + 4);
    const cap_count = readU16(code, ip + 8);
    const descriptors = frame.chunk_ptr.captureList(cap_start, cap_count);
    try closures.makeDeferredThunkFromCaptures(vm, deferred_id, descriptors, frame);
    return dispatch(vm, frame, code, ip + 10, stop_depth);
}

/// `thunk_attr`: one capture descriptor resolves the attr-access base; the
/// frameless thunk is created without any wrapper chunk.
fn thunkAttrOp(comptime wide: bool) HandlerFn {
    return struct {
        fn op(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
            frame.ip = ip;
            const name_len: usize = if (wide) 4 else 2;
            if (ip + 3 + name_len > code.len) return error.InvalidBytecode;
            const descriptors = code[ip .. ip + 3];
            const name: InternId = if (wide) readU32(code, ip + 3) else readU16(code, ip + 3);
            try closures.makeAttrAccessThunk(vm, descriptors, name, frame);
            return dispatch(vm, frame, code, ip + 3 + name_len, stop_depth);
        }
    }.op;
}

// ---- handlers: calls ----

fn opCall(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    // Sync ip back so doCall's pushed frame sits on a caller frame
    // whose ip points at the next opcode.
    _ = code;
    frame.ip = ip;
    const arg = stack.pop(vm);
    const callee = stack.pop(vm);
    try closures.doCall(vm, callee, arg);
    const new_frame = stack.currentFrame(vm);
    return dispatch(vm, new_frame, vm.executableCode(new_frame.chunk_id, new_frame.chunk_ptr), new_frame.ip, stop_depth);
}

fn opTailCall(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    _ = code;
    frame.ip = ip;
    const arg = stack.pop(vm);
    const callee = stack.pop(vm);
    try closures.doTailCall(vm, callee, arg);
    const new_frame = stack.currentFrame(vm);
    return dispatch(vm, new_frame, vm.executableCode(new_frame.chunk_id, new_frame.chunk_ptr), new_frame.ip, stop_depth);
}

fn opCallN(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    const n = code[ip];
    // Resume past the 1-byte operand when the callee frame rets (fast
    // path) or immediately (fold path pushes a value, no new frame).
    frame.ip = ip + 1;
    try closures.doCallN(vm, n);
    const new_frame = stack.currentFrame(vm);
    return dispatch(vm, new_frame, vm.executableCode(new_frame.chunk_id, new_frame.chunk_ptr), new_frame.ip, stop_depth);
}

fn opTailCallN(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    const n = code[ip];
    frame.ip = ip + 1;
    try closures.doTailCallN(vm, n);
    const new_frame = stack.currentFrame(vm);
    return dispatch(vm, new_frame, vm.executableCode(new_frame.chunk_id, new_frame.chunk_ptr), new_frame.ip, stop_depth);
}

// ---- handlers: thunks ----

fn opMakeCell(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const val = stack.pop(vm);
    try stack.push(vm, try force.makeCell(vm, val));
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opMakeLazyShell(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // The lazy-shell wrap exists solely so the lazy-XML renderer can show
    // eagerly-built shapes as `<unevaluated />` until demanded. Outside
    // that mode, leave the value on the stack instead of allocating a thunk.
    if (vm.lazy_shells_visible) {
        const val = stack.pop(vm);
        const id = try vm.heap.addLazyShell(val);
        try stack.push(vm, Value.thunk(id));
    }
    return dispatch(vm, frame, code, ip, stop_depth);
}

// ---- handlers: attribute access ----

fn opApplyOverrides(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const overrides_name: InternId = readU32(code, ip);
    // The freshly-built rec object stays on the stack (GC root) across every
    // force/allocation below; we replace it in place at the end.
    const built = vm.stack[vm.sp - 1];
    if (!built.isAttrs()) return error.TypeError; // rec object is always attrs
    const built_id = built.asObjectId();

    // Force `__overrides` to WHNF; it must be a set. (Forcing to WHNF yields
    // the outer attrset without forcing its members, so recursive sibling
    // cells stay unresolved here — exactly what the re-point below needs.)
    const ov_raw = try vm.heap.getAttrValue(built_id, overrides_name);
    const ov = force.forceValue(vm, ov_raw) catch |err| {
        trace.pushErrorContext(vm, "while evaluating the `__overrides` attribute") catch {};
        return err;
    };
    if (!ov.isAttrs()) {
        const e = trace.typeErrorExpected(vm, "a set", ov);
        trace.pushErrorContext(vm, "while evaluating the `__overrides` attribute") catch {};
        return e;
    }

    try applyOverrides(vm, built_id, ov.asObjectId());
    return dispatch(vm, frame, code, ip + 4, stop_depth);
}

/// Apply the forced `__overrides` set (`ov_id`) to the rec object
/// (`built_id`, on the stack top). For an override name that already
/// exists in the rec set, re-point its shared binding cell so both the
/// built attr and any recursive sibling that captured that cell observe
/// the override; for a new name, collect it and rebuild the attrset with
/// the additions. Mirrors Nix's `ExprAttrs::eval` `__overrides` branch.
fn applyOverrides(vm: *VM, built_id: types.ObjectId, ov_id: types.ObjectId) !void {
    const ov_entries = try vm.heap.materializeAttrs(ov_id);

    var new_entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer new_entries.deinit(vm.allocator);

    // Read-only walk of `ov_entries` (no attr-storage mutation inside), so
    // the slice stays valid; `publishCellBinding` only mutates thunks.
    for (ov_entries.names, ov_entries.values) |ov_name, ov_value| {
        const existing = try vm.heap.getAttrValueOpt(built_id, ov_name);
        if (existing) |cell_val| {
            // Existing rec attr: its stored value IS the shared binding cell
            // (loc_grab pushed the cell thunk into the object). Re-point the
            // cell so already-captured sibling thunks resolve to the override.
            if (cell_val.isThunk()) {
                const th = vm.heap.getThunkAssumeValid(cell_val.asObjectId());
                if (vm.solo) th.publishCellBindingSolo(ov_value) else th.publishCellBinding(ov_value);
                vm.heap.gcRecordEdge(cell_val.asObjectId(), ov_value); // old→young barrier
            }
        } else {
            try new_entries.append(vm.allocator, .{ .name = ov_name, .value = ov_value });
        }
    }

    // No new names: the shared-cell re-points already made `built` reflect
    // every override, so leave it (and its source positions) untouched.
    if (new_entries.items.len == 0) return;

    // Rebuild with the additions in one sorted attrset.
    var all: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer all.deinit(vm.allocator);
    {
        const built_view = try vm.heap.materializeAttrs(built_id);
        for (built_view.names, built_view.values) |b_name, b_value| try all.append(vm.allocator, .{ .name = b_name, .value = b_value });
    }
    try all.appendSlice(vm.allocator, new_entries.items);
    const merged_id = try vm.heap.addAttrs(all.items);
    vm.stack[vm.sp - 1] = Value.attrs(merged_id);
}

fn opGetAttrDynamic(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // [attrs, name] both stay on the stack across the forces.
    const name_val = try force.forceValue(vm, vm.stack[vm.sp - 1]);
    const attrs_val = vm.stack[vm.sp - 2];
    const result = try access.getAttrValue(vm, attrs_val, try strings.selectNameId(vm, name_val));
    vm.sp -= 2;
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip, stop_depth);
}

fn opGetAttrDynamicOr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    // Operands [attrs, name, default] stay on the stack across all forces
    // (GC safepoints) so they remain precise roots; drop only after.
    const default_val = vm.stack[vm.sp - 1];
    const name_val = try force.forceValue(vm, vm.stack[vm.sp - 2]);
    const attrs = try force.forceValue(vm, vm.stack[vm.sp - 3]);
    var result: Value = undefined;
    if (!attrs.isAttrs()) {
        _ = strings.selectNameId(vm, name_val) catch |err| switch (err) {
            error.MissingAttribute => {},
            else => return err,
        };
        result = try force.forceValue(vm, default_val);
    } else {
        result = blk: {
            const name_id = strings.selectNameId(vm, name_val) catch |err| switch (err) {
                error.MissingAttribute => break :blk try force.forceValue(vm, default_val),
                else => return err,
            };
            break :blk vm.heap.getAttrValue(attrs.asObjectId(), name_id) catch |err| switch (err) {
                error.MissingAttribute => try force.forceValue(vm, default_val),
                else => return err,
            };
        };
        result = try force.forceValue(vm, result);
    }
    vm.sp -= 3;
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip, stop_depth);
}

const StaticPathOp = enum { dynamic_or, or_value, has };

/// Attribute-path encodings differ only in the width of each static intern id.
fn staticPathOp(comptime operation: StaticPathOp, comptime wide: bool) HandlerFn {
    return struct {
        fn op(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
            frame.ip = ip;
            const name_len: usize = if (wide) 4 else 2;
            switch (operation) {
                .dynamic_or => {
                    const names_start = ip + 1;
                    const names_end = names_start + @as(usize, code[ip]) * name_len;
                    // Keep [attrs, name, default] rooted across the forcing walk.
                    const result = try access.getAttrPathDynamicOrValue(vm, vm.stack[vm.sp - 3], vm.stack[vm.sp - 2], vm.stack[vm.sp - 1], code[names_start..names_end], wide);
                    vm.sp -= 3;
                    try stack.push(vm, result);
                    return dispatch(vm, frame, code, names_end, stop_depth);
                },
                .or_value => {
                    const names_start = ip + 1;
                    const names_end = names_start + @as(usize, code[ip]) * name_len;
                    // Keep [attrs, default] rooted across the forcing walk.
                    const result = try access.getAttrPathOrValue(vm, vm.stack[vm.sp - 2], vm.stack[vm.sp - 1], code[names_start..names_end], wide);
                    vm.sp -= 2;
                    try stack.push(vm, result);
                    return dispatch(vm, frame, code, names_end, stop_depth);
                },
                .has => {
                    const names_start = ip + 1;
                    const names_end = names_start + @as(usize, code[ip]) * name_len;
                    const attrs_val = vm.stack[vm.sp - 1];
                    vm.stack[vm.sp - 1] = Value.boolVal(try access.hasAttrPath(vm, attrs_val, code[names_start..names_end], wide));
                    return dispatch(vm, frame, code, names_end, stop_depth);
                },
            }
        }
    }.op;
}

/// Attrset-pattern call entry: validate allowed/required formals and install
/// every supplied required value directly into its destination local. The
/// encoded pairs and heap entries are both sorted by InternId, so this is one
/// O(args + formals) merge walk. Optional pairs carry slot=0xffff and are
/// filled by their default-expression bytecode after this op.
fn attrBindOp(comptime wide: bool) HandlerFn {
    return struct {
        fn op(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
            frame.ip = ip;
            const allow_extra = code[ip] != 0;
            const cells = code[ip + 1] != 0;
            const count: usize = readU16(code, ip + 2);
            const name_len: usize = if (wide) 4 else 2;
            const stride = name_len + 2;
            const pairs_start = ip + 4;
            const pairs_end = pairs_start + count * stride;
            if (pairs_end > code.len or vm.sp == 0) return error.InvalidBytecode;

            // Keep the argument rooted on the operand stack across force and
            // possible merge flattening; replace it with WHNF for the walk.
            const attrs = try force.forceValue(vm, vm.stack[vm.sp - 1]);
            vm.stack[vm.sp - 1] = attrs;
            if (!attrs.isAttrs()) return trace.typeErrorExpected(vm, "attrs", attrs);
            const entries = try vm.heap.materializeAttrs(attrs.asObjectId());

            var entry_i: usize = 0;
            var pair_i: usize = 0;
            while (entry_i < entries.len() and pair_i < count) {
                const pair_at = pairs_start + pair_i * stride;
                const name: InternId = if (wide) readU32(code, pair_at) else @intCast(readU16(code, pair_at));
                const slot = readU16(code, pair_at + name_len);
                const entry_name = entries.names[entry_i];
                const entry_value = entries.values[entry_i];
                if (entry_name < name) {
                    if (!allow_extra) return error.UnexpectedAttribute;
                    entry_i += 1;
                } else if (entry_name > name) {
                    if (slot != std.math.maxInt(u16)) return error.MissingAttribute;
                    pair_i += 1;
                } else {
                    if (slot != std.math.maxInt(u16)) {
                        if (slot >= frame.local_count) return error.InvalidBytecode;
                        if (cells) {
                            const cell_val = vm.stack[frame.frame_base + slot];
                            if (!cell_val.isThunk()) return error.InvalidBytecode;
                            const thunk = vm.heap.getThunkAssumeValid(cell_val.asObjectId());
                            if (vm.solo) thunk.publishCellBindingSolo(entry_value) else thunk.publishCellBinding(entry_value);
                            vm.heap.gcRecordEdge(cell_val.asObjectId(), entry_value);
                        } else {
                            stack.setStack(vm, frame.frame_base + slot, entry_value);
                        }
                    }
                    entry_i += 1;
                    pair_i += 1;
                }
            }
            while (pair_i < count) : (pair_i += 1) {
                const pair_at = pairs_start + pair_i * stride;
                const slot = readU16(code, pair_at + name_len);
                if (slot != std.math.maxInt(u16)) return error.MissingAttribute;
            }
            if (!allow_extra and entry_i < entries.len()) return error.UnexpectedAttribute;

            _ = stack.pop(vm);
            return dispatch(vm, frame, code, pairs_end, stop_depth);
        }
    }.op;
}

fn opArgOrLit(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const name_id = readU16(code, ip);
    // Stack: [args_attrset, literal_default]. Bind the formal to the stored
    // argument value WITHOUT forcing it (preserving argument laziness), or to
    // the literal default if the argument is absent — Nix's `maybeThunk` for a
    // literal default binds the value directly instead of a thunk.
    const default_val = vm.stack[vm.sp - 1];
    const attrs = try force.forceValue(vm, vm.stack[vm.sp - 2]);
    var result: Value = default_val;
    if (attrs.isAttrs()) {
        result = vm.heap.getAttrValue(attrs.asObjectId(), @intCast(name_id)) catch |err| switch (err) {
            error.MissingAttribute => default_val,
            else => return err,
        };
    }
    vm.sp -= 2;
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip + 2, stop_depth);
}

fn opGetAttrPathMixedOr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const dynamic_count = code[ip + 1];
    const segments_start = ip + 2;
    var cur_ip = segments_start;
    for (0..segment_count) |_| {
        const tag = code[cur_ip];
        cur_ip += 1;
        switch (tag) {
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => cur_ip += 4,
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => {},
            else => return error.InvalidBytecode,
        }
    }
    // Stack layout (bottom→top): [attrs, dyn0, dyn1, …, dynN-1, default].
    // Read them in place (a slice into the operand stack for the dynamic
    // names — no heap alloc, and they stay rooted across the internally-
    // forcing helper); drop all N+2 only after.
    const default_val = vm.stack[vm.sp - 1];
    const dyn_base = vm.sp - 1 - dynamic_count;
    const dynamic_names = vm.stack[dyn_base .. vm.sp - 1];
    const attrs_val = vm.stack[dyn_base - 1];
    const result = try access.getAttrPathMixedOrValue(vm, attrs_val, dynamic_names, default_val, code[segments_start..cur_ip], segment_count);
    vm.sp -= (2 + dynamic_count);
    try stack.push(vm, result);
    return dispatch(vm, frame, code, cur_ip, stop_depth);
}

fn opHasAttrPathMixed(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const segment_count = code[ip];
    const dynamic_count = code[ip + 1];
    const segments_start = ip + 2;
    var cur_ip = segments_start;
    for (0..segment_count) |_| {
        const tag = code[cur_ip];
        cur_ip += 1;
        switch (tag) {
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.static) => cur_ip += 4,
            @intFromEnum(bytecode_mod.MixedAttrSegmentTag.dynamic) => {},
            else => return error.InvalidBytecode,
        }
    }
    // [attrs, dyn0, …, dynN-1] stay on the stack across the (forcing) walk;
    // pass a stack slice for the dynamic names (no heap alloc), drop after.
    const dyn_base = vm.sp - dynamic_count;
    const dynamic_names = vm.stack[dyn_base..vm.sp];
    const attrs_val = vm.stack[dyn_base - 1];
    const r = try access.hasAttrPathMixed(vm, attrs_val, dynamic_names, code[segments_start..cur_ip], segment_count);
    vm.sp -= (1 + dynamic_count);
    try stack.push(vm, Value.boolVal(r));
    return dispatch(vm, frame, code, cur_ip, stop_depth);
}

// ---- handlers: termination ----

fn opRet(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    _ = frame;
    _ = code;
    _ = ip;
    const result = stack.pop(vm);
    return retEpilogue(vm, stop_depth, result);
}

fn opConstantRet(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    const idx = readU16(code, ip);
    const result = frame.chunk_ptr.constants[idx];
    return retEpilogue(vm, stop_depth, result);
}

fn opGetUpvalueAttr(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    frame.ip = ip;
    const slot = readU16(code, ip);
    const name_id = readU16(code, ip + 2);
    const upvalues = frame.upvalues orelse return error.MissingClosure;
    const result = try access.getAttrValue(vm, upvalues[slot], @intCast(name_id));
    try stack.push(vm, result);
    return dispatch(vm, frame, code, ip + 4, stop_depth);
}

fn opHalt(vm: *VM, frame: *Frame, code: []const u8, ip: usize, stop_depth: usize) anyerror!void {
    _ = frame;
    _ = code;
    _ = ip;
    _ = stop_depth;
    if (vm.sp == 0) try stack.push(vm, Value.null_val);
}

/// Pop the current frame and either leave the result on the stack
/// for `runUntil` to retrieve (when frames_len has reached
/// `stop_depth`) or push it onto the resumed caller frame and
/// continue dispatching. `inline` so the tail call to `dispatch`
/// lands in the caller (an opRet-like handler) whose signature
/// matches handler sig — required by `@call(.always_tail)`.
inline fn retEpilogue(vm: *VM, stop_depth: usize, result: Value) anyerror!void {
    const finished_frame = stack.popFrame(vm);
    if (comptime trace_log.enabled) {
        if (vm.frames_len == 0) {
            trace_log.framePop(vm.vm_trace, vm.workerId(), vm.frames_len, types.no_chunk_id, 0);
        } else {
            const ret_frame = stack.currentFrame(vm);
            trace_log.framePop(vm.vm_trace, vm.workerId(), vm.frames_len, ret_frame.chunk_id, @intCast(ret_frame.ip));
        }
    }
    vm.sp = finished_frame.frame_base;
    try stack.push(vm, result);
    if (vm.debug.break_sink != null) {
        @branchHint(.unlikely);
        try pauseAfterReturn(vm, result);
    }
    if (vm.frames_len == stop_depth) return;
    const new_frame = stack.currentFrame(vm);
    return dispatch(vm, new_frame, vm.executableCode(new_frame.chunk_id, new_frame.chunk_ptr), new_frame.ip, stop_depth);
}

/// A debugger-only virtual instruction after frame teardown. Keeping the slow
/// path out of `retEpilogue` leaves ordinary returns with one predictable null
/// check; the result is already rooted on the VM stack before the UI may
/// re-enter evaluation.
noinline fn pauseAfterReturn(vm: *VM, result: Value) anyerror!void {
    const sink = vm.debug.break_sink orelse return;
    const bps = vm.debug.breakpoints orelse return;
    const depth = vm.debugFrameDepth();
    if (depth == 0 or !bps.pausesAfterReturn(depth)) return;
    vm.effect_epoch +%= 1;
    try sink.fire(sink.ctx, vm, result, .return_step);
}

// ---- handler table ----

/// Exhaustive opcode → handler mapping. Deliberately a `switch` with no
/// `else` arm: adding an `OpCode` variant without wiring a handler here
/// is a COMPILE error. (The previous formulation — manual assignments
/// into an `undefined` array — silently baked an undefined function
/// pointer into the binary for any unwired opcode: runtime UB on first
/// dispatch.)
fn handlerFor(comptime op: OpCode) HandlerFn {
    return switch (op) {
        .push_const => opConstant,
        .push_null => opPushNull,
        .push_true => opPushTrue,
        .push_false => opPushFalse,
        .pop => opPop,
        .loc_get => slotOp(.get, false),
        .loc_get_w => slotOp(.get, true),
        .loc_grab => slotOp(.grab, false),
        .loc_grab_w => slotOp(.grab, true),
        .up_grab => opCaptureUpvalue,
        .loc_set => slotOp(.set, false),
        .loc_set_w => slotOp(.set, true),
        .cell_set => slotOp(.cell_set, false),
        .cell_set_w => slotOp(.cell_set, true),
        .up_get => opGetUpvalue,
        .int_add => opAddInt,
        .int_sub => opSubInt,
        .int_mul => opMulInt,
        .int_div => opDivInt,
        .int_neg => opNegateInt,
        .flt_add => opAddFloat,
        .flt_sub => opSubFloat,
        .flt_mul => opMulFloat,
        .flt_div => opDivFloat,
        .cmp_eq => opEq,
        .cmp_ne => opNeq,
        .cmp_eq_null => opEqNull,
        .cmp_ne_null => opNeqNull,
        .cmp_lt => opLt,
        .cmp_le => opLte,
        .cmp_gt => opGt,
        .cmp_ge => opGte,
        .bool_not => opNot,
        .bool_check => opCheckBool,
        .jump => opJump,
        .jump_false => opJumpIfFalse,
        .fail => opFailAssertion,
        .attrs_new => opBuildAttrs,
        .attrs_new_srt => opBuildAttrsSorted,
        .attrs_new_named_srt => opBuildAttrsNamedSorted,
        .attrs_new_named => opBuildAttrsNamed,
        .attrs_new_named_pos_srt => opBuildAttrsNamedPosSorted,
        .attrs_new_named_pos => opBuildAttrsNamedPos,
        .list_new => opBuildList,
        .attrs_merge_strict => opMergeAttrsStrict,
        .attrs_merge => opMergeAttrs,
        .list_cat => opConcatLists,
        .list_cat_n => opConcatListsN,
        .str_cat => opConcatStrings,
        .path_cat => opConcatPath,
        .push_builtins => opPushBuiltins,
        .file_find => internOp(.find_file, false),
        .file_find_w => internOp(.find_file, true),
        .closure => closureOp(false),
        .closure_w => closureOp(true),
        .closure_cap => capOp(.{ .kind = .closure, .wide = false }),
        .closure_cap_w => capOp(.{ .kind = .closure, .wide = true }),
        .thunk_arg => capOp(.{ .kind = .arg, .wide = true }),
        .thunk => capOp(.{ .kind = .thunk, .wide = false }),
        .thunk_w => capOp(.{ .kind = .thunk, .wide = true }),
        .thunk_st_cell => capOp(.{ .kind = .thunk, .wide = false, .store = .cell }),
        .thunk_st => capOp(.{ .kind = .thunk, .wide = false, .store = .local }),
        .thunk_w_st_cell => capOp(.{ .kind = .thunk, .wide = true, .store = .cell }),
        .thunk_w_st => capOp(.{ .kind = .thunk, .wide = true, .store = .local }),
        .call => opCall,
        .call_tail => opTailCall,
        .call_n => opCallN,
        .call_tail_n => opTailCallN,
        .push_const_ret => opConstantRet,
        .loc_get_ret => slotOp(.get_ret, false),
        .loc_get_ret_w => slotOp(.get_ret, true),
        .up_get_ret => opGetUpvalueRet,
        .up_get_attr => opGetUpvalueAttr,
        .loc_get_attr => slotOp(.get_attr, false),
        .loc_get_attr_w => slotOp(.get_attr, true),
        .cell_new => opMakeCell,
        .thunk_shell => opMakeLazyShell,
        .thunk_attr => thunkAttrOp(false),
        .thunk_attr_w => thunkAttrOp(true),
        .cell_init => slotOp(.cell_init, false),
        .cell_init_w => slotOp(.cell_init, true),
        .attr_get => internOp(.get_attr, false),
        .attr_get_w => internOp(.get_attr, true),
        .attr_has_strict => internOp(.has_attr_strict, false),
        .attr_has_strict_w => internOp(.has_attr_strict, true),
        .attr_get_dyn => opGetAttrDynamic,
        .attr_get_dyn_or => opGetAttrDynamicOr,
        .attr_get_path_dyn_or => staticPathOp(.dynamic_or, false),
        .attr_get_path_dyn_or_w => staticPathOp(.dynamic_or, true),
        .attr_get_path_or => staticPathOp(.or_value, false),
        .attr_get_path_or_w => staticPathOp(.or_value, true),
        .attr_get_path_mix_or => opGetAttrPathMixedOr,
        .attr_has_path => staticPathOp(.has, false),
        .attr_has_path_w => staticPathOp(.has, true),
        .attr_has_path_mix => opHasAttrPathMixed,
        .attr_bind => attrBindOp(false),
        .attr_bind_w => attrBindOp(true),
        .with_lookup => internOp(.lookup_with, false),
        .with_lookup_w => internOp(.lookup_with, true),
        .thunk_defer => opDeferAttrValue,
        .arg_or_lit => opArgOrLit,
        .attrs_apply_overrides => opApplyOverrides,
        .ret => opRet,
        .halt => opHalt,
        .breakpoint => opBreakpoint,
    };
}

const handlers: [opcode.count]HandlerFn = blk: {
    var table: [opcode.count]HandlerFn = undefined;
    for (@typeInfo(OpCode).@"enum".fields) |field| {
        table[field.value] = handlerFor(@field(OpCode, field.name));
    }
    break :blk table;
};

// ---- helpers ----

pub fn expectBool(self: *VM, val: Value) !bool {
    const forced = try force.forceValue(self, val);
    return switch (forced.kind()) {
        .bool_false => false,
        .bool_true => true,
        else => error.TypeError,
    };
}
