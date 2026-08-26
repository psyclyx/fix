//! Lowers unary and binary operators, with compile-time constant folding
//! of pure literal-on-literal arithmetic/comparison/logic.
//! Folding is strictly conservative: it never folds operations that could
//! trap (`/`, `%`, i64 overflow), since `{ x = 1/0; }` is valid Nix and
//! only forcing `.x` may throw.

const std = @import("std");
const compiler_mod = @import("context.zig");
const ast = @import("syntax").ast;
const Value = @import("runtime").value.Value;
const emit = @import("emit.zig");
const int_ops = @import("runtime").int;
const heap_mod = @import("runtime").heap;
const string_syntax = @import("syntax").string_syntax;
const attr_names = @import("attr_names.zig");
const literals_mod = @import("literals.zig");
const types = @import("runtime").types;
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const access = @import("access.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const BinaryOp = compiler_mod.BinaryOp;
const nodeMayEvaluateToFloat = ast.nodeMayEvaluateToFloat;
const unwrapParens = ast.unwrapParens;

pub fn compileBinary(self: *Compiler, node: *const Node) !void {
    const bin = node.data.binary;
    switch (bin.op) {
        .and_ => return compileAnd(self, bin.left, bin.right),
        .or_ => return compileOr(self, bin.left, bin.right),
        .impl => return compileImpl(self, bin.left, bin.right),
        else => {},
    }

    // Lix operator overloading: `-` `*` `/` `<` desugar to a call of the
    // lexical variable `__sub`/`__mul`/`__div`/`__lessThan` when that name
    // resolves to a *user* (let/lambda) binding in scope. See
    // `overloadBindingInScope` — the probe is side-effect-free, so the
    // overwhelming common case (no such binding) falls straight through to
    // the direct arithmetic op below with identical bytecode.
    if (overloadNameForBinary(bin.op)) |name| {
        const name_id = try self.intern.intern(name);
        if (overloadBindingInScope(self, name_id)) {
            return compileOverloadCall(self, name, name_id, bin.left, bin.right);
        }
    }

    // `++` is right-associative. Flatten its common unparenthesized chain so
    // the VM can reserve and fill the final list once instead of copying each
    // intermediate suffix. Parenthesized/left-nested groups remain explicit.
    if (bin.op == .concat and try compileListConcatChain(self, node)) return;

    // Compile-time fold pure literal-on-literal expressions. Skips
    // operations that can error (`/`, `%`) since `{x = 1/0;}` is
    // valid Nix — only forcing `.x` is supposed to throw.
    if (try tryFoldNode(self, node)) |val| {
        return self.builder.emitConstant(self.allocator, val);
    }

    // Specialized comparison with literal `null`. Emit only the
    // non-null side and use `cmp_eq_null`/`cmp_ne_null` so the runtime
    // sees a type-monomorphic null check.
    if (bin.op == .eq or bin.op == .neq) {
        const left_null = unwrapParens(bin.left).tag == .null;
        const right_null = unwrapParens(bin.right).tag == .null;
        if (left_null != right_null) {
            try self.compileNode(if (left_null) bin.right else bin.left);
            try emit.emitOp(self, if (bin.op == .eq) .cmp_eq_null else .cmp_ne_null);
            return;
        }
    }

    try self.compileNode(bin.left);
    try self.compileNode(bin.right);

    switch (bin.op) {
        .add => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .flt_add else .int_add),
        .sub => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .flt_sub else .int_sub),
        .mul => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .flt_mul else .int_mul),
        .div => try emit.emitOp(self, if (nodeMayEvaluateToFloat(bin.left) or nodeMayEvaluateToFloat(bin.right)) .flt_div else .int_div),
        .eq => try emit.emitOp(self, .cmp_eq),
        .neq => try emit.emitOp(self, .cmp_ne),
        .lt => try emit.emitOp(self, .cmp_lt),
        .lte => try emit.emitOp(self, .cmp_le),
        .gt => try emit.emitOp(self, .cmp_gt),
        .gte => try emit.emitOp(self, .cmp_ge),
        .and_, .or_ => unreachable,
        .update => try emit.emitOp(self, .attrs_merge),
        .impl => unreachable,
        .concat => try emit.emitOp(self, .list_cat),
    }
}

const max_list_concat_parts: usize = 4096;

fn compileListConcatChain(self: *Compiler, node: *const Node) !bool {
    const first_right = node.data.binary.right;
    if (first_right.tag != .binary_op or first_right.data.binary.op != .concat) return false;

    var parts: std.ArrayListUnmanaged(*const Node) = .empty;
    defer parts.deinit(self.allocator);
    var current = node;
    while (current.tag == .binary_op and current.data.binary.op == .concat) {
        if (parts.items.len == max_list_concat_parts - 1) return false;
        try parts.append(self.allocator, current.data.binary.left);
        current = current.data.binary.right;
    }
    try parts.append(self.allocator, current);
    std.debug.assert(parts.items.len >= 3);

    for (parts.items) |part| try self.compileNode(part);
    try emit.emitOpU16(self, .list_cat_n, @intCast(parts.items.len));
    return true;
}

/// Attempt to compute a pure-arithmetic / comparison / logical
/// expression's value at compile time. Returns null when:
///   - the expression isn't a literal-on-literal pattern (recursive
///     folding handles nested cases like `1 + 2 + 3`);
///   - the operation might error at runtime (division, modulo);
///   - integer arithmetic would overflow i64 (leave for runtime so
///     the user sees the real error site);
///   - the operator is a structural one (`//`, `++`).
///
/// CRITICAL Nix-semantics constraint: `{x = 1/0;}` is valid; only
/// `{x = 1/0;}.x` is supposed to throw. So we MUST NOT fold any
/// operation that could trap — division, modulo, anything that could
/// throw. Folding is purely conservative: when in doubt, don't fold.
/// Public entry for container-literal folding (access.zig immediate values).
pub fn tryFoldConstant(self: *Compiler, node: *const Node) anyerror!?Value {
    return tryFoldNode(self, node);
}

fn tryFoldNode(self: *Compiler, node: *const Node) anyerror!?Value {
    const n = unwrapParens(node);
    switch (n.tag) {
        .integer => {
            const span = self.source[n.data.atom.offset .. n.data.atom.offset + n.data.atom.len];
            const val = std.fmt.parseInt(i64, span, 10) catch return null;
            return try int_ops.make(self.heap, val);
        },
        .float_val => {
            const span = self.source[n.data.atom.offset .. n.data.atom.offset + n.data.atom.len];
            const val = std.fmt.parseFloat(f64, span) catch return null;
            return Value.float(val);
        },
        .bool_true => return Value.boolVal(true),
        .bool_false => return Value.boolVal(false),
        .null => return Value.null_val,
        .string => return tryFoldString(self, n),
        .path => {
            // Non-interpolated path literals resolve at compile time already
            // (against base_path) — same Value the emit path would produce.
            const span = self.source[n.data.atom.offset .. n.data.atom.offset + n.data.atom.len];
            if (std.mem.indexOf(u8, span, "${") != null) return null;
            var path = try literals_mod.resolvePathLiteral(self, span);
            defer path.deinit(self.allocator);
            return Value.path(try self.intern.intern(path.slice()));
        },
        .attr_set => return tryFoldAttrSet(self, n),
        .list => return tryFoldList(self, n),
        .binary_op => {
            const bin = n.data.binary;
            // Never fold an operator that a user `__sub`/`__mul`/`__div`/
            // `__lessThan` overloads — it must lower to the call instead.
            if (overloadNameForBinary(bin.op)) |name| {
                if (overloadBindingInScope(self, try self.intern.intern(name))) return null;
            }
            return tryFoldBinaryOp(self, bin.op, bin.left, bin.right);
        },
        .unary_op => {
            const u = n.data.unary;
            // Unary `-e` overloads via `__sub` (`__sub 0 e`); don't fold it.
            if (u.op == .negate and overloadBindingInScope(self, try self.intern.intern("__sub"))) return null;
            return tryFoldUnaryOp(self, u.op, u.expr);
        },
        else => return null,
    }
}

/// Compile-time value of a non-interpolated string literal, or null.
fn tryFoldString(self: *Compiler, n: *const Node) anyerror!?Value {
    const atom = n.data.atom;
    const parsed = try string_syntax.parseLiteral(self.allocator, self.source, .{
        .start = atom.offset,
        .end = atom.offset + atom.len,
    });
    defer parsed.deinit();
    var total: usize = 0;
    for (parsed.parts) |part| switch (part) {
        .text => |t| total += t.slice().len,
        .interpolation => return null,
    };
    // Common case: one text part interns directly; multi-part (escapes split
    // the literal) assembles into a scratch buffer first.
    if (parsed.parts.len == 1) {
        return Value.string(try self.intern.intern(parsed.parts[0].text.slice()));
    }
    const buf = try self.allocator.alloc(u8, total);
    defer self.allocator.free(buf);
    var off: usize = 0;
    for (parsed.parts) |part| {
        const t = part.text.slice();
        @memcpy(buf[off .. off + t.len], t);
        off += t.len;
    }
    return Value.string(try self.intern.intern(buf));
}

/// Fold a CLOSED constant list — every item itself foldable — into a
/// materialized heap Value. Safe to share: list equality is structural, and
/// the value becomes a chunk constant (a permanent GC root).
fn tryFoldList(self: *Compiler, n: *const Node) anyerror!?Value {
    const items = n.data.list.items;
    const vals = try self.allocator.alloc(Value, items.len);
    defer self.allocator.free(vals);
    for (items, vals) |item, *v| {
        v.* = (try tryFoldNode(self, item)) orelse return null;
    }
    return Value.list(try self.heap.addList(vals));
}

/// Fold a CLOSED constant attrset literal — non-recursive, static single-
/// segment names, every value itself foldable — into a materialized heap
/// Value, positions included (so `unsafeGetAttrPos` parity holds). Duplicate
/// names bail to the normal path, which owns the diagnostics.
fn tryFoldAttrSet(self: *Compiler, n: *const Node) anyerror!?Value {
    const aset = n.data.attr_set;
    if (aset.recursive) return null;
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    var positions: std.ArrayListUnmanaged(heap_mod.AttrPosEntry) = .empty;
    defer positions.deinit(self.allocator);
    for (aset.entries) |entry| {
        if (entry.dynamic_name != null) return null;
        if (entry.path.len != 1) return null; // nested paths carry grouping semantics
        if (entry.inherit_outer) return null;
        if (attr_names.hasInterpolation(self, entry.path[0])) return null;
        const name_id = try attr_names.intern(self, entry.path[0]);
        const v = (try tryFoldNode(self, entry.expr)) orelse return null;
        try entries.append(self.allocator, .{ .name = name_id, .value = v });
        try attr_names.appendPosition(self, &positions, entry.path[0], name_id);
    }
    const id = self.heap.addAttrsWithPositions(entries.items, positions.items) catch |err| switch (err) {
        error.DuplicateAttribute => return null,
        else => return err,
    };
    return Value.attrs(id);
}

fn tryFoldBinaryOp(self: *Compiler, op: BinaryOp, left_node: *const Node, right_node: *const Node) anyerror!?Value {
    // Logical short-circuit operators: a single literal side can
    // determine the result without evaluating the other operand. But
    // *only* when we know the short-circuit side has no side effects
    // — which here means it's also a fully-folded literal. We already
    // recurse on both sides via tryFoldNode below; if both fold,
    // computing the boolean is safe.
    const left = try tryFoldNode(self, left_node) orelse return null;
    const right = try tryFoldNode(self, right_node) orelse return null;
    return switch (op) {
        .add => foldArith(self, left, right, .add),
        .sub => foldArith(self, left, right, .sub),
        .mul => foldArith(self, left, right, .mul),
        // .div / .modulo intentionally omitted (could trap on /0).
        .eq => if (foldEq(self, left, right)) |b| Value.boolVal(b) else null,
        .neq => if (foldEq(self, left, right)) |b| Value.boolVal(!b) else null,
        .lt => foldCompare(left, right, .lt),
        .lte => foldCompare(left, right, .lte),
        .gt => foldCompare(left, right, .gt),
        .gte => foldCompare(left, right, .gte),
        .and_ => if (left.isBool() and right.isBool()) Value.boolVal(left.asBool() and right.asBool()) else null,
        .or_ => if (left.isBool() and right.isBool()) Value.boolVal(left.asBool() or right.asBool()) else null,
        .impl => if (left.isBool() and right.isBool()) Value.boolVal(!left.asBool() or right.asBool()) else null,
        // .update / .concat are structural — never fold.
        .update, .concat, .div => null,
    };
}

fn tryFoldUnaryOp(self: *Compiler, op: ast.UnaryOp, expr: *const Node) anyerror!?Value {
    const v = try tryFoldNode(self, expr) orelse return null;
    return switch (op) {
        .not => if (v.isBool()) Value.boolVal(!v.asBool()) else null,
        .negate => switch (v.kind()) {
            .int => blk: {
                const i = v.asInt();
                // i64.min has no positive counterpart — let runtime
                // handle the saturation/error semantics.
                if (i == std.math.minInt(i64)) break :blk null;
                break :blk try int_ops.make(self.heap, -i);
            },
            .boxed_int => blk: {
                const i = self.heap.getBoxedInt(v.asObjectId()) catch break :blk null;
                if (i == std.math.minInt(i64)) break :blk null;
                break :blk try int_ops.make(self.heap, -i);
            },
            .float => Value.float(-v.asFloat()),
            else => null,
        },
    };
}

const ArithOp = enum { add, sub, mul };

fn foldArith(self: *Compiler, a: Value, b: Value, op: ArithOp) ?Value {
    const a_kind = a.kind();
    const b_kind = b.kind();
    // Both numbers? Promote to float if either is float; otherwise
    // checked i64 op.
    const a_is_int = a_kind == .int or a_kind == .boxed_int;
    const b_is_int = b_kind == .int or b_kind == .boxed_int;
    if ((a_is_int or a_kind == .float) and (b_is_int or b_kind == .float)) {
        if (a_kind == .float or b_kind == .float) {
            const af = toFloat(self, a) orelse return null;
            const bf = toFloat(self, b) orelse return null;
            return Value.float(switch (op) {
                .add => af + bf,
                .sub => af - bf,
                .mul => af * bf,
            });
        }
        const ai = toInt(self, a) orelse return null;
        const bi = toInt(self, b) orelse return null;
        const result = switch (op) {
            .add => @addWithOverflow(ai, bi),
            .sub => @subWithOverflow(ai, bi),
            .mul => @mulWithOverflow(ai, bi),
        };
        // Don't fold across an overflow — leave it to runtime so the
        // error site matches the user's source.
        if (result[1] != 0) return null;
        return int_ops.make(self.heap, result[0]) catch null;
    }
    return null;
}

const CmpOp = enum { lt, lte, gt, gte };

fn foldCompare(a: Value, b: Value, op: CmpOp) ?Value {
    const a_kind = a.kind();
    const b_kind = b.kind();
    const a_is_int = a_kind == .int or a_kind == .boxed_int;
    const b_is_int = b_kind == .int or b_kind == .boxed_int;
    if ((a_is_int or a_kind == .float) and (b_is_int or b_kind == .float)) {
        // Need access to heap for boxed_int — skip for now if either is boxed.
        if (a_kind == .boxed_int or b_kind == .boxed_int) return null;
        if (a_kind == .float or b_kind == .float) {
            const af: f64 = if (a_kind == .float) a.asFloat() else @floatFromInt(a.asInt());
            const bf: f64 = if (b_kind == .float) b.asFloat() else @floatFromInt(b.asInt());
            return Value.boolVal(switch (op) {
                .lt => af < bf,
                .lte => af <= bf,
                .gt => af > bf,
                .gte => af >= bf,
            });
        }
        const ai = a.asInt();
        const bi = b.asInt();
        return Value.boolVal(switch (op) {
            .lt => ai < bi,
            .lte => ai <= bi,
            .gt => ai > bi,
            .gte => ai >= bi,
        });
    }
    return null;
}

/// Compile-time `==` over folded values. Returns null (do not fold) for any
/// kind the comparison cannot decide by value here: heap aggregates compare
/// structurally at runtime (two folded lists are distinct objects), and
/// unknown kinds stay conservative. Strings decide by intern id (interning is
/// canonical); boxed ints resolve through the heap.
fn foldEq(self: *Compiler, a: Value, b: Value) ?bool {
    // Numeric (incl. boxed): resolve then compare; int/float mix promotes.
    const ai = toInt(self, a);
    const bi = toInt(self, b);
    if (ai != null and bi != null) return ai.? == bi.?;
    const a_num: ?f64 = if (ai) |i| @floatFromInt(i) else if (a.kind() == .float) a.asFloat() else null;
    const b_num: ?f64 = if (bi) |i| @floatFromInt(i) else if (b.kind() == .float) b.asFloat() else null;
    if (a_num != null and b_num != null) return a_num.? == b_num.?;
    if (a_num != null or b_num != null) return if (a.kind() == .null or b.kind() == .null or a.isBool() or b.isBool() or a.kind() == .string or b.kind() == .string) false else null;
    if (a.kind() == .null or b.kind() == .null) return a.kind() == b.kind();
    if (a.isBool() and b.isBool()) return a.asBool() == b.asBool();
    if (a.kind() == .string and b.kind() == .string) return a.asInternId() == b.asInternId();
    if (a.isBool() != b.isBool()) return false;
    return null; // aggregates / paths / anything else: fold nothing
}

fn toInt(self: *Compiler, v: Value) ?i64 {
    return switch (v.kind()) {
        .int => v.asInt(),
        .boxed_int => self.heap.getBoxedInt(v.asObjectId()) catch null,
        else => null,
    };
}

fn toFloat(self: *Compiler, v: Value) ?f64 {
    return switch (v.kind()) {
        .float => v.asFloat(),
        .int => @floatFromInt(v.asInt()),
        .boxed_int => blk: {
            const i = self.heap.getBoxedInt(v.asObjectId()) catch break :blk null;
            break :blk @floatFromInt(i);
        },
        else => null,
    };
}

fn compileAnd(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_false, 0);
    try emit.emitOp(self, .pop);

    try self.compileNode(right);
    try emit.emitOp(self, .bool_check);
    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

fn compileOr(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const false_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_false, 0);

    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump, 0);

    emit.patchJump(self, false_jump, self.builder.code.items.len);
    try emit.emitOp(self, .pop);

    try self.compileNode(right);
    try emit.emitOp(self, .bool_check);
    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

fn compileImpl(self: *Compiler, left: *const Node, right: *const Node) !void {
    try self.compileNode(left);

    const false_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_false, 0);
    try emit.emitOp(self, .pop);

    try self.compileNode(right);
    try emit.emitOp(self, .bool_check);
    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump, 0);

    emit.patchJump(self, false_jump, self.builder.code.items.len);
    try emit.emitOp(self, .pop);
    try emit.emitOp(self, .push_true);

    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

pub fn compileUnary(self: *Compiler, node: *const Node) !void {
    const un = node.data.unary;
    // Lix operator overloading: unary `-e` desugars to `__sub 0 e` when a
    // user `__sub` binding is in scope (matching the binary `-` overload).
    if (un.op == .negate) {
        const name_id = try self.intern.intern("__sub");
        if (overloadBindingInScope(self, name_id)) {
            try emitOverloadCallee(self, "__sub", name_id);
            try self.builder.emitConstant(self.allocator, try int_ops.make(self.heap, 0));
            try compileOverloadArg(self, un.expr);
            try emit.emitOpByte(self, .call_n, 2);
            return;
        }
    }
    if (try tryFoldNode(self, node)) |val| {
        return self.builder.emitConstant(self.allocator, val);
    }
    try self.compileNode(un.expr);
    switch (un.op) {
        .negate => try emit.emitOp(self, .int_neg),
        .not => try emit.emitOp(self, .bool_not),
    }
}

/// The `__`-prefixed builtin name a binary operator overloads through, or
/// null for operators Lix does not overload (`+` has no `__add`; structural
/// and equality operators are never overloaded). Also consulted by the
/// reference walker (`refs.zig`) so a `let __mul = …;` referenced only
/// through the `*` operator is kept alive rather than pruned.
pub fn overloadNameForBinary(op: BinaryOp) ?[]const u8 {
    return switch (op) {
        .sub => "__sub",
        .mul => "__mul",
        .div => "__div",
        .lt => "__lessThan",
        else => null,
    };
}

/// True iff `name_id` resolves to a *user* binding (a local, or a local of
/// some ancestor compiler that would be captured as an upvalue). This walks
/// the same local/ancestor chain as `resolveCaptureId` but WITHOUT its
/// capture side effect, so a failed probe leaves compiler state untouched and
/// the non-overloaded path emits a direct arithmetic op.
fn overloadBindingInScope(self: *const Compiler, name_id: types.InternId) bool {
    if (scope.resolveLocalId(self, name_id)) |_| return true;
    var p = self.parent;
    while (p) |parent| : (p = parent.parent) {
        if (scope.resolveLocalId(parent, name_id)) |_| return true;
    }
    return false;
}

/// Push the resolved overload callee (`__mul` etc.) onto the stack. Only
/// called after `overloadBindingInScope` has confirmed a user binding, so
/// resolution here always succeeds (as a local or, via capture threading,
/// an upvalue).
fn emitOverloadCallee(self: *Compiler, name: []const u8, name_id: types.InternId) !void {
    if (scope.resolveLocalId(self, name_id)) |slot| {
        try emit.emitGetLocal(self, slot);
    } else if (try scope.resolveCaptureId(self, name, name_id)) |cap| {
        try emit.emitOpU16(self, .up_get, cap);
    } else unreachable;
}

/// Compile one overload-call argument with the same laziness as a normal
/// application spine arg: a bare immediate/local passes through directly,
/// everything else becomes a lazy thunk.
fn compileOverloadArg(self: *Compiler, arg: *const Node) !void {
    if (try access.compileImmediateContainerValue(self, arg, .{ .raw_identifier = true })) return;
    try thunks.compileThunk(self, arg);
}

/// Emit `<name> left right` as a saturated 2-arg call for an overloaded
/// binary operator.
fn compileOverloadCall(self: *Compiler, name: []const u8, name_id: types.InternId, left: *const Node, right: *const Node) !void {
    try emitOverloadCallee(self, name, name_id);
    try compileOverloadArg(self, left);
    try compileOverloadArg(self, right);
    try emit.emitOpByte(self, .call_n, 2);
}
