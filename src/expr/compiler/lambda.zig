//! Lowers lambdas and function application into chunks: value-lambda
//! uncurrying (`a: b: …` → one multi-param chunk), attrset-pattern lambdas
//! (formal validation, defaults, mutually-recursive binding cells), and
//! call-spine flattening into `call_n`/`call_tail_n`.
//! Emits per-chunk strictness metadata (`strict_param`/`strict_params`/
//! forwarding upvalue) that drives eager-vs-lazy argument passing.

const std = @import("std");
const compiler_mod = @import("context.zig");
const ast = @import("syntax").ast;
const bytecode = @import("../bytecode.zig");
const chunk = bytecode.chunk;
const heap_mod = @import("runtime").heap;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const OpCode = bytecode.OpCode;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const diagnostics = @import("diagnostics.zig");
const attr_names = @import("attr_names.zig");
const access = @import("access.zig");
const control = @import("control.zig");
const strictness = @import("strictness.zig");
const let = @import("let.zig");
const refs_mod = @import("refs.zig");
const fold = @import("fold.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const InternId = types.InternId;
const ChunkBuilder = chunk.ChunkBuilder;
const diagnostic_atom = @import("diagnostic_atom.zig");
const diagnosticAtom = diagnostic_atom.diagnosticAtom;
const unwrapParens = ast.unwrapParens;

pub fn compileApply(self: *Compiler, node: *const Node) !void {
    try compileApplyWithOp(self, node, .call);
}

pub fn compileTailExpression(self: *Compiler, node: *const Node) anyerror!void {
    const unwrapped = unwrapParens(node);
    switch (unwrapped.tag) {
        .apply, .if_else, .let_in, .assert, .with_expr => {},
        else => return self.compileNode(node),
    }

    {
        const start = self.builder.code.items.len;
        try compileTailNodeImpl(self, unwrapped);
        const end = self.builder.code.items.len;
        if (try diagnostics.sourceSpanForNode(self, node)) |span| {
            try self.builder.addSourceMapEntry(self.allocator, start, end, span);
        }
        return;
    }
}

fn compileTailNodeImpl(self: *Compiler, node: *const Node) anyerror!void {
    switch (node.tag) {
        .apply => try compileApplyWithOp(self, node, .call_tail),
        .if_else => try control.compileIfElseTail(self, node),
        .let_in => try let.compileLetInWithTailBody(self, node),
        .assert => try control.compileAssertTail(self, node),
        .with_expr => try control.compileWithTail(self, node),
        else => unreachable,
    }
}

/// Compile one argument of a flattened `call_n` spine. We deliberately do
/// NOT use the runtime-adaptive `thunk_arg` op here: its eager-vs-thunk
/// check reads the callee at `stack[sp-1]`, which is the real callee only
/// for the *first* spine arg (later args would see the previous arg). So
/// immediate container values stay thunk-free and everything else becomes
/// a plain lazy thunk; the saturated `call_n` path then eagerly forces the
/// arg positions the callee chunk marks must-force (`strict_params`),
/// recovering eager-arg behavior with the callee actually known.
fn compileSpineArg(self: *Compiler, arg: *const Node) !void {
    // `raw_identifier`: a bare local/upvalue argument is already a lazy value in
    // its slot — push it directly (`loc_grab`/`up_grab`) instead of
    // wrapping it in a forwarding thunk that would just return it. Same laziness,
    // one fewer chunk + allocation each (as attr-set values already do).
    if (try access.compileImmediateContainerValue(self, arg, .{ .raw_identifier = true })) return;
    try thunks.compileThunk(self, arg);
}

fn compileApplyWithOp(self: *Compiler, node: *const Node, op: OpCode) !void {
    // Flatten the application spine `f a1 a2 ... aK` and, for K >= 2, emit
    // one `call_n K` instead of K nested `call`s. When the callee is an
    // uncurried (merged) closure of arity K this runs the body in a single
    // frame with no intermediate closure/PAP allocation; otherwise it
    // folds one arg at a time (same result). K == 1 keeps the original
    // single-arg path below (which still carries the eager-strict-arg and
    // tail-call-frame-reuse optimizations).
    {
        var args: [256]*const Node = undefined;
        var k: usize = 0;
        var head: *const Node = unwrapParens(node);
        while (head.tag == .apply and k < args.len) {
            args[k] = head.data.apply.arg;
            k += 1;
            head = unwrapParens(head.data.apply.func);
        }
        if (k == 2 and head.tag != .apply and try compileFullyAppliedBuiltin(self, head, args[1], args[0])) return;
        if (k >= 2 and head.tag != .apply) {
            // `args` is in reverse (last-applied first); emit head then
            // a1..aK in application order.
            try self.compileNode(head);
            var i: usize = k;
            while (i > 0) {
                i -= 1;
                try compileSpineArg(self, args[i]);
            }
            const call_op: OpCode = if (op == .call_tail) .call_tail_n else .call_n;
            try emit.emitOpByte(self, call_op, @intCast(k));
            return;
        }
    }

    const ap = node.data.apply;
    try self.compileNode(ap.func);
    // Directly-applied lambda `(x: body) arg` whose body unconditionally
    // forces `x`: evaluate `arg` straight onto the stack instead of
    // thunking it. The lambda forces it regardless, so this is sound
    // (same success/failure; only error ordering in a failing eval can
    // differ). Structural-builder args stay lazy (isEagerEvalShape).
    if (let.isEagerEvalShape(ap.arg) and try directlyAppliedStrictLambda(self, ap.func)) {
        // Statically-known strict callee: eager arg, no runtime check.
        try self.compileNode(ap.arg);
    } else if (try access.compileImmediateContainerValue(self, ap.arg, .{ .raw_identifier = true })) {
        // Immediate value (literal/empty list/...) or a bare local/upvalue
        // reference: already a lazy value, so pass it directly rather than
        // wrapping it in a forwarding thunk (see `compileSpineArg`).
    } else {
        // Dynamically-dispatched call: defer the thunk-vs-eager decision
        // to runtime via `thunk_arg`, which reads the callee's strictness.
        try thunks.compileApplyArgThunk(self, ap.arg);
    }
    try emit.emitOp(self, op);
}

const InlineBuiltin = enum { sub, mul, div, less_than, get_attr, has_attr };

/// Recognize `builtins.<name>` only when `builtins` really denotes the global
/// set. A local/ancestor binding shadows it, and scopedImport replaces the
/// whole base environment, so neither case may use this intrinsic path.
fn inlineBuiltinHead(self: *Compiler, head_raw: *const Node) !?InlineBuiltin {
    if (self.scoped_base) return null;
    const head = unwrapParens(head_raw);
    if (head.tag != .attr_path or head.data.attr_path.segments.len != 1) return null;
    const root = unwrapParens(head.data.attr_path.root);
    if (root.tag != .identifier) return null;
    const root_name = attr_names.identText(self, root.data.atom);
    if (!std.mem.eql(u8, root_name, "builtins")) return null;

    const builtins_id = try self.intern.intern("builtins");
    if (scope.resolveLocalId(self, builtins_id) != null) return null;
    var parent = self.parent;
    while (parent) |p| : (parent = p.parent) {
        if (scope.resolveLocalId(p, builtins_id) != null) return null;
    }

    const segment = head.data.attr_path.segments[0];
    if (attr_names.hasInterpolation(self, segment)) return null;
    const name = self.intern.get(try attr_names.intern(self, segment));
    if (std.mem.eql(u8, name, "sub")) return .sub;
    if (std.mem.eql(u8, name, "mul")) return .mul;
    if (std.mem.eql(u8, name, "div")) return .div;
    if (std.mem.eql(u8, name, "lessThan")) return .less_than;
    if (std.mem.eql(u8, name, "getAttr")) return .get_attr;
    if (std.mem.eql(u8, name, "hasAttr")) return .has_attr;
    return null;
}

/// Lower saturated builtins with exact VM-operator equivalents. Arithmetic
/// operands are evaluated in builtin argument order. Attribute operations are
/// limited to a compile-time string name, which removes both applications and
/// the builtins-set lookup without changing name-vs-set error ordering.
fn compileFullyAppliedBuiltin(self: *Compiler, head: *const Node, first: *const Node, second: *const Node) !bool {
    const builtin = try inlineBuiltinHead(self, head) orelse return false;
    switch (builtin) {
        .sub, .mul, .div, .less_than => {
            try self.compileNode(first);
            try self.compileNode(second);
            try emit.emitOp(self, switch (builtin) {
                .sub => .int_sub,
                .mul => .int_mul,
                .div => .int_div,
                .less_than => .cmp_lt,
                else => unreachable,
            });
        },
        .get_attr, .has_attr => {
            const name = (try fold.tryFoldConstant(self, first)) orelse return false;
            if (!name.isString()) return false;
            const name_id = name.asInternId();
            try self.compileNode(second);
            if (builtin == .get_attr) {
                try emit.emitGetAttr(self, name_id);
            } else {
                try emit.emitInternOp(self, .attr_has_strict, .attr_has_strict_w, name_id);
            }
        },
    }
    return true;
}

/// Detect the forwarding shape `param: f param` where `f` is a captured
/// free variable, returning `f`'s upvalue index (its position in the
/// child's capture list). The lambda then forces its parameter iff `f`
/// does — resolved at the call site. `null` when the body is not this
/// exact shape.
fn forwardingUpvalue(self: *Compiler, child: *Compiler, body: *const Node, param_name: []const u8) ?u16 {
    const b = unwrapParens(body);
    if (b.tag != .apply) return null;
    const func = unwrapParens(b.data.apply.func);
    const arg = unwrapParens(b.data.apply.arg);
    if (func.tag != .identifier or arg.tag != .identifier) return null;
    const arg_name = attr_names.identText(self, arg.data.atom);
    if (!std.mem.eql(u8, arg_name, param_name)) return null;
    const func_name = attr_names.identText(self, func.data.atom);
    if (std.mem.eql(u8, func_name, param_name)) return null;
    // Upvalue index == position in the child's capture list (upvalues
    // are staged from captures in order).
    for (child.captures.items, 0..) |cap, idx| {
        if (std.mem.eql(u8, cap.name, func_name)) {
            return if (idx <= std.math.maxInt(u16)) @intCast(idx) else null;
        }
    }
    return null;
}

/// True iff `func` is a `x: body` lambda whose body must-force its
/// parameter (so a caller may pass its argument eagerly). Unwraps parens
/// first — a directly-applied lambda is nearly always written parenthesized
/// (`(x: body) arg`), so without this the check was dead (`func.tag == .parens`
/// → false) and only beta-inlining eagerized such args.
fn directlyAppliedStrictLambda(self: *Compiler, func_raw: *const Node) !bool {
    const func = unwrapParens(func_raw);
    if (func.tag != .lambda) return false;
    const lambda = func.data.lambda;
    const param_name = self.source[lambda.param_offset .. lambda.param_offset + lambda.param_len];
    const param_id = try self.intern.intern(param_name);
    return strictness.bodyMustForceName(self.allocator, self.intern, self.source, lambda.body, param_id);
}

pub fn compileLambda(self: *Compiler, node: *const Node) !void {
    // Uncurry: collect the maximal chain of adjacent *value* lambdas
    // `a: b: ...: body` into ONE chunk with N params (each a frame local)
    // and `arity = N`. Nested lambdas reference outer parameters as locals,
    // and a `call_n` site supplying N args runs the body in one frame. Stop at the first
    // non-value-lambda (attrset-pattern lambda or non-lambda body), at the
    // `max_uncurry_arity` cap, or at a repeated param name (so we never
    // rely on within-frame shadow ordering of identically-named locals).
    const max_arity = types.max_uncurry_arity;
    var params: [max_arity][]const u8 = undefined;
    var param_ids: [max_arity]InternId = undefined;
    var n: u16 = 0;
    var cur: *const Node = node;
    while (n < max_arity and cur.tag == .lambda) {
        const lam = cur.data.lambda;
        const name = self.source[lam.param_offset .. lam.param_offset + lam.param_len];
        const id = try self.intern.intern(name);
        var dup = false;
        var k: u16 = 0;
        while (k < n) : (k += 1) {
            if (param_ids[k] == id) {
                dup = true;
                break;
            }
        }
        if (dup) break;
        params[n] = name;
        param_ids[n] = id;
        n += 1;
        cur = unwrapParens(lam.body);
    }
    const body = cur;

    // The binding name this lambda is armed for, captured before `initChild`
    // consumes `name_hint`. Only a genuinely RECURSIVE binding (a `let` — see
    // `name_hint_recursive`) is a valid self-recursion target: an attr-set attr
    // of the same name (`{ overrides = self: super: (overrides …) …; }`)
    // resolves OUTWARD, not to itself, so treating it as a self-call would
    // wrongly force a fixed-point knot. This is what the strictness fixpoint
    // keys off to recognize the lambda's own recursive calls.
    const self_name_id: ?InternId =
        if (self.name_hint_recursive and !self.name_hint_synthetic) self.name_hint else null;

    // Unbound lambda (no attr/let binding armed a name): synthesize one from
    // the parameter, so e.g. a module's top `pkgs: …` reads as `λpkgs`.
    if (self.registry.capture_names and n > 0) {
        var nbuf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&nbuf, "λ{s}", .{params[0]})) |txt| self.armSyntheticName(txt) else |_| {}
    }

    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
    defer child.deinit();

    var pi: u16 = 0;
    while (pi < n) : (pi += 1) {
        _ = try scope.declareLocal(&child, params[pi], param_ids[pi]);
    }
    compileTailExpression(&child, body) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    try strictness.stampOnBuilder(&child, body);
    // Strict-param / forwarding analysis only applies to the single-param
    // (curried) shape — `finish` gates `strict_param` to `local_count == 1`
    // anyway, and an uncurried chunk's params are locals, not upvalues.
    // Which parameters does the body unconditionally force? A saturated call
    // may then evaluate those argument positions eagerly instead of thunking
    // them. `strictParamsMask` folds in a self-recursion fixpoint keyed off the
    // lambda's own binding name (`self_name_id`), so a tail-recursive
    // accumulator is seen as strict in its accumulator — evaluated eagerly
    // rather than left to build a lazy `+`-thunk chain.
    const strict_mask = try strictness.strictParamsMask(self.allocator, self.intern, self.source, body, param_ids[0..n], self_name_id);
    if (n == 1) {
        child_builder.strict_param = (strict_mask & 1) != 0;
        // Forwarding `x: f x` forces x iff `f` does — record `f`'s upvalue
        // index so the caller can resolve it at the call site.
        if (!child_builder.strict_param) {
            child_builder.strict_via_upvalue = forwardingUpvalue(self, &child, body, params[0]);
        }
    } else {
        // Uncurried chunk: the saturated `call_n` path forces these arg
        // positions eagerly, recovering the eager-arg behavior `thunk_arg`
        // gives the single-param shape.
        child_builder.strict_params = strict_mask;
    }
    child_builder.arity = n;
    // For `--xml`, a value lambda renders as `<varpat name="…">` using its
    // (first) parameter name — matching how Nix prints a merged curried chain.
    child_builder.lambda_pattern = .{ .var_pat = param_ids[0] };
    try emit.emitRet(&child);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.persistent, child.slot_count);
    const child_id = try child.registerChunk(child_chunk);
    try emit.emitClosureWithCaptures(self, child_id, child.captures.items);
}

pub fn compileLambdaAttrs(self: *Compiler, node: *const Node) !void {
    const lambda = node.data.lambda_attrs;

    // Unbound pattern lambda: synthesize `λ{first,…}` from the pattern (or the
    // @-binding when present), so module toplevels read as `λ{config,…}`.
    if (self.registry.capture_names) {
        var nbuf: [128]u8 = undefined;
        const txt: ?[]const u8 = if (lambda.bind_name) |bn|
            std.fmt.bufPrint(&nbuf, "λ{s}@", .{self.source[bn.offset .. bn.offset + bn.len]}) catch null
        else if (lambda.params.len == 0)
            "λ{}"
        else blk: {
            const p0 = lambda.params[0].name;
            const first = self.source[p0.offset .. p0.offset + p0.len];
            break :blk std.fmt.bufPrint(&nbuf, "λ{{{s}{s}}}", .{ first, if (lambda.params.len > 1) ",…" else "" }) catch null;
        };
        if (txt) |t| self.armSyntheticName(t);
    }

    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
    defer child.deinit();

    const arg_slot = try scope.declareLocal(&child, "\x00args", try self.intern.intern("\x00args"));
    if (lambda.bind_name) |bind_name| {
        const name = self.source[bind_name.offset .. bind_name.offset + bind_name.len];
        const name_id = try self.intern.intern(name);
        const slot = try scope.declareLocal(&child, name, name_id);
        try emit.emitCaptureLocal(&child, arg_slot);
        try emit.emitSetLocal(&child, slot);
    }

    const param_count = try diagnostics.requireU16At(self, lambda.params.len, diagnosticAtom(node), "too many function parameters");
    const ParamBinding = struct {
        name_id: InternId,
        slot: u16,
        has_default: bool,
    };
    const param_bindings = try self.allocator.alloc(ParamBinding, lambda.params.len);
    defer self.allocator.free(param_bindings);

    var wide_params = false;
    var function_args: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer function_args.deinit(self.allocator);
    try function_args.ensureTotalCapacity(self.allocator, lambda.params.len);
    // Source positions of the formals, so `unsafeGetAttrPos` can report where a
    // parameter was declared. Only recorded when compiling a real file.
    var function_arg_pos: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
    defer function_arg_pos.deinit(self.allocator);
    const record_positions = self.source_path != null;
    for (lambda.params, param_bindings) |param, *binding| {
        const name = self.source[param.name.offset .. param.name.offset + param.name.len];
        const name_id = try self.intern.intern(name);
        if (name_id > std.math.maxInt(u16)) wide_params = true;
        binding.* = .{
            .name_id = name_id,
            .slot = try scope.declareLocal(&child, name, name_id),
            .has_default = param.default != null,
        };
        function_args.appendAssumeCapacity(.{
            .name = name_id,
            .value = Value.boolVal(param.default != null),
        });
        if (record_positions) {
            const pos = try diagnostics.sourcePositionForOffset(self, param.name.offset);
            try function_arg_pos.append(self.allocator, .{
                .name = name_id,
                .pos = .{ .file = try diagnostics.sourceFileId(self), .line = pos.line, .column = pos.column },
            });
        }
    }
    try child_builder.setFunctionArgs(self.allocator, function_args.items);
    if (function_arg_pos.items.len > 0) try child_builder.setFunctionArgPositions(self.allocator, function_arg_pos.items);

    // For `--xml`, an attrset-pattern lambda renders as `<attrspat>` with the
    // formal names (from `function_args`), plus the optional `@`-binding name
    // and `...` ellipsis flag.
    child_builder.lambda_pattern = .{ .attrs_pat = .{
        .has_bind = lambda.bind_name != null,
        .bind_name = if (lambda.bind_name) |bn|
            try self.intern.intern(self.source[bn.offset .. bn.offset + bn.len])
        else
            0,
        .ellipsis = lambda.allow_extra,
    } };

    // Binding cells are only needed when a formal's default references
    // another formal (mutually-recursive defaults, e.g. `{ a, b ? a }`):
    // the cell gives each formal a mutable handle the others can capture.
    // The overwhelmingly common case — no defaults at all, or defaults
    // that don't reference sibling formals (every NixOS module function,
    // `{ config, lib, pkgs, ... }`) — needs no cells: each formal binds
    // directly to the raw argument value, skipping a per-formal binding-cell
    // heap alloc plus a force-indirection on every param access. This lands on
    // the hot critical path (module application,
    // modules.nix:450). The check only walks DEFAULTS (tiny / absent),
    // never bodies, so it adds negligible compile cost.
    const needs_cells = attrParamsNeedCells(self, lambda.params);
    if (needs_cells) for (param_bindings) |binding| try emit.emitInitCellSlot(&child, binding.slot);

    // One sorted merge walk validates the argument set and installs every
    // required formal. Optional names use the 0xffff slot sentinel: they still
    // participate in unexpected-attribute validation, then the default path
    // below chooses the supplied raw value or its lazy fallback.
    const sorted_bindings = try self.allocator.dupe(ParamBinding, param_bindings);
    defer self.allocator.free(sorted_bindings);
    std.mem.sort(ParamBinding, sorted_bindings, {}, struct {
        fn lessThan(_: void, a: ParamBinding, b: ParamBinding) bool {
            return a.name_id < b.name_id;
        }
    }.lessThan);

    try emit.emitCaptureLocal(&child, arg_slot);
    try emit.emitOp(&child, if (wide_params) .attr_bind_w else .attr_bind);
    try child.builder.writeByte(child.allocator, if (lambda.allow_extra) 1 else 0);
    try child.builder.writeByte(child.allocator, if (needs_cells) 1 else 0);
    try child.builder.writeU16(child.allocator, param_count);
    for (sorted_bindings) |binding| {
        try emit.writeInternId(&child, binding.name_id, wide_params);
        try child.builder.writeU16(child.allocator, if (binding.has_default) std.math.maxInt(u16) else binding.slot);
    }

    for (lambda.params, param_bindings) |param, binding| {
        if (!binding.has_default) continue;
        try compileAttrParam(&child, arg_slot, binding.name_id, param.default);
        if (needs_cells) {
            try emit.emitSetCellLocal(&child, binding.slot);
        } else {
            try emit.emitSetLocal(&child, binding.slot);
        }
    }

    compileTailExpression(&child, lambda.body) catch |err| {
        try diagnostics.absorbChildDiagnostics(self, &child);
        return err;
    };
    try strictness.stampOnBuilder(&child, lambda.body);
    try emit.emitRet(&child);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.persistent, child.slot_count);
    const child_id = try child.registerChunk(child_chunk);
    try emit.emitClosureWithCaptures(self, child_id, child.captures.items);
}

/// Do this attrset pattern's formals need binding cells? Only when a
/// formal's default references another formal (mutually-recursive
/// defaults). Walks only the (usually absent / tiny) defaults, so it's
/// cheap; conservatively returns true on any analysis failure.
fn attrParamsNeedCells(self: *Compiler, params: []const Node.LambdaAttrParam) bool {
    var has_default = false;
    for (params) |p| {
        if (p.default != null) {
            has_default = true;
            break;
        }
    }
    if (!has_default) return false;

    var refs: std.StringHashMapUnmanaged(void) = .empty;
    defer refs.deinit(self.allocator);
    for (params) |p| {
        if (p.default) |d| refs_mod.collectReferencedNames(self, d, &refs) catch return true;
    }
    for (params) |p| {
        const name = self.source[p.name.offset .. p.name.offset + p.name.len];
        if (refs.contains(name)) return true;
    }
    return false;
}

/// Does this default expression bind directly as a value (no thunk) under
/// Nix's `Expr::maybeThunk`? Only trivial scalar literals qualify — a computed
/// default (`1 + 1`, `-1`), an identifier (`bar`), a list/set/lambda, etc. all
/// thunk (printing `<CODE>` when the fallback is taken and left unforced).
fn defaultIsTrivialLiteral(self: *Compiler, default: *const Node) bool {
    const unwrapped = ast.unwrapParens(default);
    return switch (unwrapped.tag) {
        .integer, .float_val => true,
        // `true`/`false`/`null` are unshadowed base-env variables here, which
        // Nix's `ExprVar::maybeThunk` binds as the value they denote.
        .identifier => fold.globalConstant(self, unwrapped) != null,
        .string, .path => blk: {
            // Interpolated forms are `ExprConcatStrings` — not literals.
            const atom = unwrapped.data.atom;
            const span = self.source[atom.offset .. atom.offset + atom.len];
            break :blk std.mem.indexOf(u8, span, "${") == null;
        },
        else => false,
    };
}

/// Emit the value bound to one attrset-pattern formal, leaving it on the stack
/// for the caller's `loc_set`/`cell_set`. A formal whose default is a trivial
/// literal binds the argument (unforced) or the literal directly via
/// `arg_or_lit` — matching Nix, which does NOT thunk a literal fallback (so
/// `({ foo ? 12 }: [ foo ]) { }` prints `[ 12 ]`, not `[ <CODE> ]`). Everything
/// else keeps the lazy per-formal thunk.
fn compileAttrParam(self: *Compiler, arg_slot: u16, name_id: InternId, default: ?*const Node) !void {
    if (default) |default_expr| {
        if (name_id <= std.math.maxInt(u16) and defaultIsTrivialLiteral(self, default_expr)) {
            try emit.emitGetLocal(self, arg_slot); // push args attrset
            const pushed = try access.compileImmediateContainerValue(self, ast.unwrapParens(default_expr), .{});
            std.debug.assert(pushed); // trivial literals always emit an immediate value
            try emit.emitArgOrLit(self, name_id);
            return;
        }
    }
    try compileAttrParamThunk(self, arg_slot, name_id, default);
}

fn compileAttrParamThunk(self: *Compiler, arg_slot: u16, name_id: InternId, default: ?*const Node) !void {
    var child_builder = try self.acquireBuilder();
    defer self.releaseBuilder(&child_builder);

    var child = self.initChild(&child_builder);
    defer child.deinit();

    _ = try scope.addCapture(&child, "\x00args", .local, arg_slot);
    try emit.emitOpU16(&child, .up_get, 0);
    if (default) |default_expr| {
        try thunks.compileThunk(&child, default_expr);
        try emit.emitOp(&child, if (name_id > std.math.maxInt(u16)) .attr_get_path_or_w else .attr_get_path_or);
        try child.builder.writeByte(child.allocator, 1);
        try emit.writeInternId(&child, name_id, name_id > std.math.maxInt(u16));
    } else {
        try emit.emitGetAttr(&child, name_id);
    }
    try emit.emitRet(&child);
    try emit.emitOp(&child, .halt);

    const child_chunk = try child_builder.finish(self.persistent, child.slot_count);
    const child_id = try child.registerChunk(child_chunk);
    try emit.emitThunkWithCaptures(self, child_id, child.captures.items);
}
