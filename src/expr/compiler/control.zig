//! Lowers control-flow expressions — `if`/`else`, `assert`, and `with`
//! (subject thunk + with-scope setup) — with matching tail-position
//! variants for the tail-call compiler.

const std = @import("std");
const compiler_mod = @import("context.zig");
const ast = @import("syntax").ast;
const bytecode = @import("../bytecode.zig");
const builtins = @import("runtime").builtins;
const chunk = bytecode.chunk;
const diagnostic = @import("syntax").diagnostic;
const string_syntax = @import("syntax").string_syntax;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const OpCode = bytecode.OpCode;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const lambda = @import("lambda.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const NodeTag = compiler_mod.NodeTag;
const BinaryOp = compiler_mod.BinaryOp;
const Capture = compiler_mod.Capture;
const AttrEntryView = compiler_mod.AttrEntryView;
const AttrEntryGroup = compiler_mod.AttrEntryGroup;
const AttrEntryGroups = compiler_mod.AttrEntryGroups;
const ContainerValueOptions = compiler_mod.ContainerValueOptions;
const WithScope = compiler_mod.WithScope;
const InternId = types.InternId;

pub fn compileIfElse(self: *Compiler, node: *const Node) !void {
    try compileIfElseBody(self, node, false);
}

pub fn compileIfElseTail(self: *Compiler, node: *const Node) anyerror!void {
    try compileIfElseBody(self, node, true);
}

pub fn compileIfElseBody(self: *Compiler, node: *const Node, tail_branches: bool) anyerror!void {
    const ife = node.data.if_else;

    try self.compileNode(ife.cond);

    // Emit placeholder for jump_false
    const jump_pos = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_false, 0);
    try emit.emitOp(self, .pop);

    if (tail_branches) {
        try lambda.compileTailExpression(self, ife.then_branch);
    } else {
        try self.compileNode(ife.then_branch);
    }
    const jump_over_pos = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump, 0);

    // Patch jump_false target
    emit.patchJump(self, jump_pos, self.builder.code.items.len);

    try emit.emitOp(self, .pop);
    if (tail_branches) {
        try lambda.compileTailExpression(self, ife.else_branch);
    } else {
        try self.compileNode(ife.else_branch);
    }

    // Patch jump (skip else)
    emit.patchJump(self, jump_over_pos, self.builder.code.items.len);
}

pub fn compileAssert(self: *Compiler, node: *const Node) !void {
    try compileAssertBody(self, node, false);
}

pub fn compileAssertTail(self: *Compiler, node: *const Node) anyerror!void {
    try compileAssertBody(self, node, true);
}

pub fn compileAssertBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
    const assert_node = node.data.assert;

    try self.compileNode(assert_node.cond);

    const fail_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump_false, 0);
    try emit.emitOp(self, .pop);

    if (tail_body) {
        try lambda.compileTailExpression(self, assert_node.body);
    } else {
        try self.compileNode(assert_node.body);
    }
    const end_jump = self.builder.code.items.len;
    try emit.emitOpU32(self, .jump, 0);

    emit.patchJump(self, fail_jump, self.builder.code.items.len);
    try emit.emitOp(self, .pop);
    try emit.emitOp(self, .fail);

    emit.patchJump(self, end_jump, self.builder.code.items.len);
}

pub fn compileWith(self: *Compiler, node: *const Node) !void {
    try compileWithBody(self, node, false);
}

pub fn compileWithTail(self: *Compiler, node: *const Node) anyerror!void {
    try compileWithBody(self, node, true);
}

pub fn compileWithBody(self: *Compiler, node: *const Node, tail_body: bool) anyerror!void {
    const with_node = node.data.with_expr;

    try scope.beginScope(self);

    const scope_slot = try scope.declareLocal(self, "", try self.intern.intern(""));
    try thunks.compileThunk(self, with_node.attr_set);
    try emit.emitSetLocal(self, scope_slot);
    try self.with_scopes.append(self.allocator, .{ .kind = .local, .index = scope_slot });

    if (tail_body) {
        try lambda.compileTailExpression(self, with_node.body);
    } else {
        try self.compileNode(with_node.body);
    }

    _ = self.with_scopes.pop();
    scope.endScope(self);
}
