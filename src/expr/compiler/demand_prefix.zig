//! Ordered, conservative demand-prefix analysis for `let` lowering.
//!
//! This is deliberately separate from chunk strictness: it models evaluation
//! order through let RHSes and statically-known lambda calls so the emitter
//! can fill a proven prefix of slots eagerly without changing which effect or
//! error happens first.

const std = @import("std");
const ast = @import("syntax").ast;
const types = @import("runtime").types;
const InternTable = @import("runtime").intern.InternTable;

const Node = ast.Node;
const InternId = types.InternId;

/// One let binding as seen by `analyze`: its interned root name, its
/// single-leaf RHS when eager evaluation is permitted for it, and whether it
/// is eligible to join the strict prefix at all.
pub const Binding = struct {
    name_id: InternId,
    rhs: ?*const Node,
    eligible: bool,
    /// A value-lambda literal chain. Forcing one reads a pre-resolved closure
    /// shell, so a saturated call can continue demand analysis in its body.
    lambda: ?LambdaShape = null,
};

/// The uncurried parameter chain of a value-lambda literal (`a: b: body`).
pub const LambdaShape = struct {
    params: []const InternId,
    body: *const Node,
};

/// Collect a binding RHS's value-lambda chain. The chain stops at a pattern
/// lambda, a non-lambda body, or a repeated parameter name.
pub fn lambdaShape(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    expr: *const Node,
) !?LambdaShape {
    var cur = ast.unwrapParens(expr);
    if (cur.tag != .lambda) return null;
    var params: std.ArrayListUnmanaged(InternId) = .empty;
    errdefer params.deinit(allocator);
    collect: while (cur.tag == .lambda) {
        const lam = cur.data.lambda;
        const id = try intern.intern(source[lam.param_offset .. lam.param_offset + lam.param_len]);
        for (params.items) |existing| {
            if (existing == id) break :collect;
        }
        try params.append(allocator, id);
        cur = ast.unwrapParens(lam.body);
    }
    return .{ .params = try params.toOwnedSlice(allocator), .body = cur };
}

/// Append the maximal ordered sequence of eligible bindings provably forced
/// before any other observable effect while reducing `body` to WHNF.
pub fn analyze(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    body: *const Node,
    bindings: []const Binding,
    out: *std.ArrayListUnmanaged(u32),
) !void {
    if (bindings.len == 0) return;
    var ctx: Context = .{
        .allocator = allocator,
        .intern = intern,
        .source = source,
        .bindings = bindings,
        .emitted = try allocator.alloc(bool, bindings.len),
        .expanding = try allocator.alloc(bool, bindings.len),
        .out = out,
    };
    defer allocator.free(ctx.emitted);
    defer allocator.free(ctx.expanding);
    defer ctx.by_name.deinit(allocator);
    defer ctx.frames.deinit(allocator);
    @memset(ctx.emitted, false);
    @memset(ctx.expanding, false);
    try ctx.by_name.ensureTotalCapacity(allocator, @intCast(bindings.len));
    for (bindings, 0..) |binding, i| {
        const gop = ctx.by_name.getOrPutAssumeCapacity(binding.name_id);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
    }
    _ = try ctx.walk(body, .{ .lo = 0, .hi = 0 });
}

const max_prefix_len = 32;
const max_call_depth = 4;

/// One known-callee descent. Parameters are bound to call-site arguments;
/// `caller_lo` records the frame-window visible at that call site.
const Frame = struct {
    params: []const InternId,
    args: []const *const Node,
    caller_lo: usize,
};

/// Contiguous frame window through which an expression resolves parameters.
const Window = struct { lo: usize, hi: usize };

const Context = struct {
    allocator: std.mem.Allocator,
    intern: *InternTable,
    source: []const u8,
    bindings: []const Binding,
    emitted: []bool,
    expanding: []bool,
    out: *std.ArrayListUnmanaged(u32),
    by_name: std.AutoHashMapUnmanaged(InternId, u32) = .empty,
    frames: std.ArrayListUnmanaged(Frame) = .empty,

    fn findBinding(self: *Context, name_id: InternId) ?u32 {
        return self.by_name.get(name_id);
    }

    fn findParam(self: *Context, name_id: InternId, window: Window) ?struct { arg: *const Node, window: Window } {
        var i = window.hi;
        while (i > window.lo) {
            i -= 1;
            const frame = self.frames.items[i];
            for (frame.params, 0..) |param, j| {
                if (param == name_id) return .{
                    .arg = frame.args[j],
                    .window = .{ .lo = frame.caller_lo, .hi = i },
                };
            }
        }
        return null;
    }

    const Callee = struct { shape: LambdaShape, sibling: bool };

    /// Resolve a statically-known value lambda through sibling bindings,
    /// parameters bound to known callees, or a direct lambda literal.
    fn resolveCallee(self: *Context, callee_in: *const Node, window_in: Window) ?Callee {
        var callee = ast.unwrapParens(callee_in);
        var window = window_in;
        var hops: usize = 0;
        while (hops < max_call_depth) : (hops += 1) {
            switch (callee.tag) {
                .identifier => {
                    const atom = callee.data.atom;
                    const name_id = if (atom.len == 0) @as(@import("runtime").types.InternId, @intCast(atom.offset)) else self.intern.intern(self.source[atom.offset .. atom.offset + atom.len]) catch return null;
                    if (self.findParam(name_id, window)) |hit| {
                        callee = ast.unwrapParens(hit.arg);
                        window = hit.window;
                        continue;
                    }
                    const index = self.findBinding(name_id) orelse return null;
                    const shape = self.bindings[index].lambda orelse return null;
                    return .{ .shape = shape, .sibling = true };
                },
                .lambda => {
                    const shape = (lambdaShape(self.allocator, self.intern, self.source, callee) catch null) orelse return null;
                    return .{ .shape = shape, .sibling = hops != 0 };
                },
                else => return null,
            }
        }
        return null;
    }

    /// Walk in demand order. True means reducing `node` to WHNF performs no
    /// work beyond the emitted prefix and effect-free operations, so its
    /// caller may continue demanding the next expression.
    fn walk(self: *Context, node: *const Node, window: Window) anyerror!bool {
        switch (node.tag) {
            .integer, .float_val, .uri, .lambda, .lambda_attrs => return true,
            .string, .path => {
                const atom = node.data.atom;
                return std.mem.indexOf(u8, self.source[atom.offset .. atom.offset + atom.len], "${") == null;
            },
            .identifier => {
                const atom = node.data.atom;
                // Synthetic (full-laziness) atoms carry an interned id, len 0.
                const name_id = if (atom.len == 0) @as(InternId, @intCast(atom.offset)) else blk: {
                    const text = self.source[atom.offset .. atom.offset + atom.len];
                    if (std.mem.eql(u8, text, "__curPos")) return true;
                    break :blk try self.intern.intern(text);
                };
                if (self.findParam(name_id, window)) |hit| {
                    return self.walk(hit.arg, hit.window);
                }
                const index = self.findBinding(name_id) orelse return false;
                if (self.emitted[index]) return true;
                if (self.expanding[index]) return false;
                const binding = self.bindings[index];
                if (binding.lambda != null) return true;
                if (!binding.eligible) return false;
                if (self.out.items.len >= max_prefix_len) return false;
                self.expanding[index] = true;
                defer self.expanding[index] = false;
                _ = try self.walk(binding.rhs.?, .{ .lo = 0, .hi = 0 });
                if (self.out.items.len >= max_prefix_len) return false;
                self.emitted[index] = true;
                try self.out.append(self.allocator, index);
                return true;
            },
            .parens => return self.walk(node.data.parens, window),
            .unary_op => {
                _ = try self.walk(node.data.unary.expr, window);
                return false;
            },
            .binary_op => {
                const binary = node.data.binary;
                switch (binary.op) {
                    .add, .sub, .mul, .div, .eq, .neq, .lt, .lte, .gt, .gte, .update, .concat => {
                        if (try self.walk(binary.left, window)) _ = try self.walk(binary.right, window);
                        return false;
                    },
                    .and_, .or_, .impl => {
                        _ = try self.walk(binary.left, window);
                        return false;
                    },
                }
            },
            .apply => {
                var args_rev: [types.max_uncurry_arity]*const Node = undefined;
                var arg_count: usize = 0;
                var head: *const Node = node;
                while (head.tag == .apply and arg_count < args_rev.len) {
                    args_rev[arg_count] = head.data.apply.arg;
                    arg_count += 1;
                    head = ast.unwrapParens(head.data.apply.func);
                }
                if (head.tag != .apply and self.frames.items.len < max_call_depth) {
                    if (self.resolveCallee(head, window)) |callee| {
                        const shape = callee.shape;
                        if (arg_count >= shape.params.len and shape.params.len > 0) {
                            var args_buf: [types.max_uncurry_arity]*const Node = undefined;
                            for (shape.params, 0..) |_, i| {
                                args_buf[i] = args_rev[arg_count - 1 - i];
                            }
                            const frame_index = self.frames.items.len;
                            try self.frames.append(self.allocator, .{
                                .params = shape.params,
                                .args = args_buf[0..shape.params.len],
                                .caller_lo = window.lo,
                            });
                            defer _ = self.frames.pop();
                            const body_window: Window = if (callee.sibling)
                                .{ .lo = frame_index, .hi = frame_index + 1 }
                            else
                                .{ .lo = window.lo, .hi = frame_index + 1 };
                            _ = try self.walk(shape.body, body_window);
                            return false;
                        }
                    }
                }
                _ = try self.walk(node.data.apply.func, window);
                return false;
            },
            .if_else => {
                _ = try self.walk(node.data.if_else.cond, window);
                return false;
            },
            .assert => {
                _ = try self.walk(node.data.assert.cond, window);
                return false;
            },
            .attr_path => {
                _ = try self.walk(node.data.attr_path.root, window);
                return false;
            },
            .attr_dynamic => {
                if (try self.walk(node.data.attr_dynamic.root, window))
                    _ = try self.walk(node.data.attr_dynamic.name, window);
                return false;
            },
            .has_attr => {
                _ = try self.walk(node.data.has_attr.root, window);
                return false;
            },
            .has_attr_mixed => {
                _ = try self.walk(node.data.has_attr_mixed.root, window);
                return false;
            },
            .attr_or => {
                var base = node.data.attr_or.attr_path;
                chase: while (true) {
                    base = switch (base.tag) {
                        .attr_path => base.data.attr_path.root,
                        .attr_dynamic => base.data.attr_dynamic.root,
                        .has_attr => base.data.has_attr.root,
                        .has_attr_mixed => base.data.has_attr_mixed.root,
                        .parens => base.data.parens,
                        else => break :chase,
                    };
                }
                _ = try self.walk(base, window);
                return false;
            },
            .let_in, .with_expr, .attr_set, .list, .search_path, .elided => return false,
        }
    }
};
