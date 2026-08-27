//! Recursive AST dispatch for `Compiler`.

const std = @import("std");
const context = @import("context.zig");
const Compiler = context.Compiler;
const Node = context.Node;
const Value = @import("runtime").value.Value;
const builtins = @import("runtime").builtins;
const literals = @import("literals.zig");
const fold = @import("fold.zig");
const lambda = @import("lambda.zig");
const let_float = @import("let_float.zig");
const let = @import("let.zig");
const control = @import("control.zig");
const attrs = @import("attrs.zig");
const access = @import("access.zig");
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const diagnostics = @import("diagnostics.zig");
const strictness = @import("strictness.zig");
const refs = @import("refs.zig");

pub const driver: context.Driver = .{
    .compile_node = compileNode,
    .compile_and_finish = compileAndFinish,
};

fn compileWithScope(self: *Compiler, node: *const Node, scope_value: ?Value) !void {
    if (scope_value) |value| {
        if (needsAmbientScope(self, node)) {
            try compileAmbientScope(self, node, value);
        } else {
            try compileNode(self, node);
        }
    } else {
        try compileNode(self, node);
    }
}

const AmbientUseMarker = struct {
    needed: bool = false,

    pub fn mark(self: *AmbientUseMarker, name: []const u8) void {
        if (!isStaticName(name)) self.needed = true;
    }

    fn isStaticName(name: []const u8) bool {
        return std.mem.eql(u8, name, "builtins") or
            std.mem.eql(u8, name, "__curPos") or
            std.mem.eql(u8, name, "__nixPath") or
            builtins.ambientIdForName(name) != null or
            builtins.hasConstant(name);
    }
};

/// A REPL/debug scope overlays lexical names and the static builtin
/// environment. If a subtree mentions no name which could reach that overlay,
/// embedding the changing scope object would add dead bytecode and defeat
/// chunk deduplication. The reference walk is conservative: bound names and
/// interpolation words may retain an unnecessary scope, but it never removes
/// one that may be observed.
fn needsAmbientScope(self: *Compiler, node: *const Node) bool {
    // scopedImport replaces the builtin environment, so even names such as
    // `import` must keep consulting its supplied attrset.
    if (self.scoped_base) return true;

    var marker: AmbientUseMarker = .{};
    refs.walkReferencedNames(self, node, &marker);
    return marker.needed;
}

fn compileAndFinish(self: *Compiler, node: *const Node, scope_value: ?Value) !void {
    try compileWithScope(self, node, scope_value);
    try strictness.stampOnBuilder(self, node);
    try emit.emitRet(self);
    try self.builder.writeOp(self.allocator, .halt);
}

fn compileAmbientScope(self: *Compiler, node: *const Node, scope_value: Value) !void {
    try scope.beginScope(self);

    const scope_slot = try scope.declareLocal(self, "", try self.intern.intern(""));
    try self.builder.emitConstant(self.allocator, scope_value);
    try emit.emitSetLocal(self, scope_slot);
    try self.with_scopes.append(self.allocator, .{ .kind = .local, .index = scope_slot });

    try compileNode(self, node);

    _ = self.with_scopes.pop();
    scope.endScope(self);
}

fn compileNode(self: *Compiler, node: *const Node) anyerror!void {
    const start = self.builder.code.items.len;
    try compileNodeImpl(self, node);
    const end = self.builder.code.items.len;
    if (try diagnostics.sourceSpanForNode(self, node)) |span| {
        try self.builder.addSourceMapEntry(self.allocator, start, end, span);
    }
}

fn compileNodeImpl(self: *Compiler, node: *const Node) anyerror!void {
    switch (node.tag) {
        .integer => try literals.compileInt(self, node),
        .float_val => try literals.compileFloat(self, node),
        .string => try literals.compileString(self, node),
        .path => try literals.compilePath(self, node),
        .uri => try literals.compileUri(self, node),
        .search_path => try literals.compileSearchPath(self, node),
        .identifier => try literals.compileIdent(self, node),
        .binary_op => try fold.compileBinary(self, node),
        .unary_op => try fold.compileUnary(self, node),
        .apply => try lambda.compileApply(self, node),
        .lambda => {
            // Full-laziness pre-emission hook (on by default; FIX_NO_FULL_LAZY
            // disables): the rewrite may return `let floated… in <lambda>` —
            // bindings hoisted into THIS scope, shared across the closure's
            // calls.
            const rewritten = try let_float.rewriteLambdaExpression(self, node);
            if (rewritten != node) return self.compileNode(rewritten);
            try lambda.compileLambda(self, node);
        },
        .lambda_attrs => {
            const rewritten = try let_float.rewriteLambdaExpression(self, node);
            if (rewritten != node) return self.compileNode(rewritten);
            try lambda.compileLambdaAttrs(self, node);
        },
        .let_in => try let.compileLetIn(self, node),
        .if_else => try control.compileIfElse(self, node),
        .assert => try control.compileAssert(self, node),
        .with_expr => try control.compileWith(self, node),
        .attr_set => try attrs.compileAttrSet(self, node),
        .attr_path => try access.compileAttrPath(self, node),
        .attr_dynamic => try access.compileAttrDynamic(self, node),
        .attr_or => try access.compileAttrOr(self, node),
        .has_attr => try access.compileHasAttr(self, node),
        .has_attr_mixed => try access.compileHasAttrMixed(self, node),
        .list => try access.compileList(self, node),
        .parens => try compileNode(self, node.data.parens),
        .elided => {
            const body = try literals.materializeElided(self, node);
            try compileNodeImpl(self, body);
        },
    }
}
