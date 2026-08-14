const std = @import("std");
const ast = @import("../ast.zig");
const parser_mod = @import("../parser.zig");

const NodeTag = ast.NodeTag;
const Parser = parser_mod.Parser;

fn parseWarningWithFailingAllocator(allocator: std.mem.Allocator) !void {
    var arena = ast.AstArena.init(allocator);
    defer arena.deinit();
    var parser = Parser.init(allocator, &arena, ".5");
    defer parser.deinit();
    _ = try parser.parse();
}

fn parseDiagnosticWithFailingAllocator(allocator: std.mem.Allocator) !void {
    var arena = ast.AstArena.init(allocator);
    defer arena.deinit();
    var parser = Parser.init(allocator, &arena, "$ $ 1");
    defer parser.deinit();
    _ = parser.parse() catch |err| switch (err) {
        error.ParseError => return,
        else => return err,
    };
}

test "parser warnings and diagnostics propagate every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseWarningWithFailingAllocator,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseDiagnosticWithFailingAllocator,
        .{},
    );
}

test "parser applies boolean operator precedence" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "true && false || true");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.or_, node.data.binary.op);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.binary.left.tag);
    try std.testing.expectEqual(ast.BinaryOp.and_, node.data.binary.left.data.binary.op);
    try std.testing.expectEqual(NodeTag.bool_true, node.data.binary.right.tag);
}

test "parser treats implication as right associative" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "a -> b -> c");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.impl, node.data.binary.op);
    try std.testing.expectEqual(NodeTag.identifier, node.data.binary.left.tag);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.binary.right.tag);
    try std.testing.expectEqual(ast.BinaryOp.impl, node.data.binary.right.data.binary.op);
}

test "parser gives implication lower precedence than boolean or" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "true || false -> false");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.impl, node.data.binary.op);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.binary.left.tag);
    try std.testing.expectEqual(ast.BinaryOp.or_, node.data.binary.left.data.binary.op);
    try std.testing.expectEqual(NodeTag.bool_false, node.data.binary.right.tag);
}

test "parser desugars |> to a forward-tagged application" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "x |> f");
    const node = try parser.parse();

    // `x |> f` == `f x`: func is the right operand, arg the left.
    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, node.data.apply.pipe);
    try std.testing.expectEqual(NodeTag.identifier, node.data.apply.func.tag);
    try std.testing.expectEqualStrings("f", parser.source[node.data.apply.func.data.atom.offset..][0..node.data.apply.func.data.atom.len]);
    try std.testing.expectEqualStrings("x", parser.source[node.data.apply.arg.data.atom.offset..][0..node.data.apply.arg.data.atom.len]);
    try std.testing.expect(parser.used_pipe_operators);
    try std.testing.expect(parser.first_pipe_token != null);
}

test "parser desugars <| to a backward-tagged application" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "f <| x");
    const node = try parser.parse();

    // `f <| x` == `f x`: func is the left operand, arg the right.
    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.backward, node.data.apply.pipe);
    try std.testing.expectEqualStrings("f", parser.source[node.data.apply.func.data.atom.offset..][0..node.data.apply.func.data.atom.len]);
    try std.testing.expectEqualStrings("x", parser.source[node.data.apply.arg.data.atom.offset..][0..node.data.apply.arg.data.atom.len]);
    try std.testing.expect(parser.used_pipe_operators);
}

test "parser treats |> as left associative" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    // a |> b |> c  ==  c (b a)  ==  apply(func=c, arg=apply(func=b, arg=a))
    var parser = Parser.init(std.testing.allocator, &arena, "a |> b |> c");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, node.data.apply.pipe);
    try std.testing.expectEqualStrings("c", parser.source[node.data.apply.func.data.atom.offset..][0..node.data.apply.func.data.atom.len]);
    // The outer application's argument is the inner `a |> b`.
    const inner = node.data.apply.arg;
    try std.testing.expectEqual(NodeTag.apply, inner.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, inner.data.apply.pipe);
    try std.testing.expectEqualStrings("b", parser.source[inner.data.apply.func.data.atom.offset..][0..inner.data.apply.func.data.atom.len]);
    try std.testing.expectEqualStrings("a", parser.source[inner.data.apply.arg.data.atom.offset..][0..inner.data.apply.arg.data.atom.len]);
}

test "parser treats <| as right associative" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    // a <| b <| c  ==  a (b c)  ==  apply(func=a, arg=apply(func=b, arg=c))
    var parser = Parser.init(std.testing.allocator, &arena, "a <| b <| c");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.backward, node.data.apply.pipe);
    try std.testing.expectEqualStrings("a", parser.source[node.data.apply.func.data.atom.offset..][0..node.data.apply.func.data.atom.len]);
    const inner = node.data.apply.arg;
    try std.testing.expectEqual(NodeTag.apply, inner.tag);
    try std.testing.expectEqual(ast.PipeSugar.backward, inner.data.apply.pipe);
    try std.testing.expectEqualStrings("b", parser.source[inner.data.apply.func.data.atom.offset..][0..inner.data.apply.func.data.atom.len]);
    try std.testing.expectEqualStrings("c", parser.source[inner.data.apply.arg.data.atom.offset..][0..inner.data.apply.arg.data.atom.len]);
}

test "parser gives |> lower precedence than ->" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    // a -> b |> c  ==  (a -> b) |> c : the arg is the whole implication.
    var parser = Parser.init(std.testing.allocator, &arena, "a -> b |> c");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, node.data.apply.pipe);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.apply.arg.tag);
    try std.testing.expectEqual(ast.BinaryOp.impl, node.data.apply.arg.data.binary.op);
}

test "parser gives function application higher precedence than |>" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    // f x |> g  ==  g (f x) : the arg is the plain application `f x`.
    var parser = Parser.init(std.testing.allocator, &arena, "f x |> g");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, node.data.apply.pipe);
    const arg = node.data.apply.arg;
    try std.testing.expectEqual(NodeTag.apply, arg.tag);
    try std.testing.expectEqual(ast.PipeSugar.none, arg.data.apply.pipe);
}

test "parser keeps a parenthesized pipe as a single list item" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "[ (1 |> f) ]");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.list, node.tag);
    try std.testing.expectEqual(@as(usize, 1), node.data.list.items.len);
}

test "parser rejects a bare pipe operator inside a list" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "[ 1 |> f ]");
    defer parser.deinit(); // error path records a diagnostic; free it
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "cloneNode preserves pipe provenance" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "x |> f");
    const node = try parser.parse();
    const copy = try ast.cloneNode(&arena, node);

    try std.testing.expectEqual(NodeTag.apply, copy.tag);
    try std.testing.expectEqual(ast.PipeSugar.forward, copy.data.apply.pipe);
}

test "parser recognizes identifier lambda" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "x: x + 1");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.lambda, node.tag);
    try std.testing.expectEqualStrings("x", parser.span(.{
        .type = .identifier,
        .offset = node.data.lambda.param_offset,
        .len = node.data.lambda.param_len,
    }));
    try std.testing.expectEqual(NodeTag.binary_op, node.data.lambda.body.tag);
}

test "parser recognizes attrset lambda" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ x, y }: x + y");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.lambda_attrs, node.tag);
    try std.testing.expectEqual(@as(usize, 2), node.data.lambda_attrs.params.len);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.lambda_attrs.body.tag);
}

test "parser recognizes attrset lambda defaults ellipsis and binding" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "args@{ x ? 1, ... }: args.x");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.lambda_attrs, node.tag);
    try std.testing.expect(node.data.lambda_attrs.bind_name != null);
    try std.testing.expect(node.data.lambda_attrs.allow_extra);
    try std.testing.expectEqual(@as(usize, 1), node.data.lambda_attrs.params.len);
    try std.testing.expect(node.data.lambda_attrs.params[0].default != null);
}

test "parser recognizes attrset lambda defaults with dynamic attrs" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(
        std.testing.allocator,
        &arena,
        "{ x ? let table = { a = { b = 1; }; }; in table.${\"a\"}.b }: x",
    );
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.lambda_attrs, node.tag);
    try std.testing.expect(node.data.lambda_attrs.params[0].default != null);
}

test "parser recognizes nested attr declarations" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ a.b = 1; a.\"c\" = 2; }");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_set, node.tag);
    const entries = node.data.attr_set.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(usize, 2), entries[0].path.len);
    try std.testing.expectEqualStrings("a", parser.span(.{
        .type = .identifier,
        .offset = entries[0].path[0].offset,
        .len = entries[0].path[0].len,
    }));
    try std.testing.expectEqualStrings("b", parser.span(.{
        .type = .identifier,
        .offset = entries[0].path[1].offset,
        .len = entries[0].path[1].len,
    }));
    try std.testing.expectEqualStrings("\"c\"", parser.span(.{
        .type = .string,
        .offset = entries[1].path[1].offset,
        .len = entries[1].path[1].len,
    }));
}

test "parser desugars simple inherit in attrsets" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ inherit a or; }");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_set, node.tag);
    const entries = node.data.attr_set.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(usize, 1), entries[0].path.len);
    try std.testing.expectEqualStrings("a", parser.span(.{
        .type = .identifier,
        .offset = entries[0].path[0].offset,
        .len = entries[0].path[0].len,
    }));
    try std.testing.expectEqual(NodeTag.identifier, entries[0].expr.tag);
    try std.testing.expectEqualStrings("or", parser.span(.{
        .type = .kw_or,
        .offset = entries[1].path[0].offset,
        .len = entries[1].path[0].len,
    }));
    try std.testing.expectEqual(NodeTag.identifier, entries[1].expr.tag);
}

test "parser desugars inherit from source expression" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ inherit (src) a or; }");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_set, node.tag);
    const entries = node.data.attr_set.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(NodeTag.attr_path, entries[0].expr.tag);
    try std.testing.expectEqual(NodeTag.identifier, entries[0].expr.data.attr_path.root.tag);
    try std.testing.expectEqual(@as(usize, 1), entries[0].expr.data.attr_path.segments.len);
    try std.testing.expectEqualStrings("a", parser.span(.{
        .type = .identifier,
        .offset = entries[0].expr.data.attr_path.segments[0].offset,
        .len = entries[0].expr.data.attr_path.segments[0].len,
    }));
    try std.testing.expectEqual(NodeTag.attr_path, entries[1].expr.tag);
    try std.testing.expectEqual(NodeTag.identifier, entries[1].expr.data.attr_path.root.tag);
    try std.testing.expect(entries[0].inherit_group != 0);
    try std.testing.expectEqual(entries[0].inherit_group, entries[1].inherit_group);
}

test "parser recognizes contextual or attr names" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ or = 2; x.or = 3; }");
    defer parser.deinit();
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_set, node.tag);
    const entries = node.data.attr_set.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("or", parser.span(.{
        .type = .kw_or,
        .offset = entries[0].path[0].offset,
        .len = entries[0].path[0].len,
    }));
    try std.testing.expectEqualStrings("or", parser.span(.{
        .type = .kw_or,
        .offset = entries[1].path[1].offset,
        .len = entries[1].path[1].len,
    }));
}

test "parser desugars inherit in let bindings" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "let inherit a; inherit (src) b; in a");
    defer parser.deinit();
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.let_in, node.tag);
    const bindings = node.data.let_in.bindings;
    try std.testing.expectEqual(@as(usize, 2), bindings.len);
    try std.testing.expectEqualStrings("a", parser.span(.{
        .type = .identifier,
        .offset = bindings[0].name_offset,
        .len = bindings[0].name_len,
    }));
    try std.testing.expectEqual(NodeTag.identifier, bindings[0].expr.tag);
    try std.testing.expect(bindings[0].inherit_outer);
    try std.testing.expectEqualStrings("b", parser.span(.{
        .type = .identifier,
        .offset = bindings[1].name_offset,
        .len = bindings[1].name_len,
    }));
    try std.testing.expectEqual(NodeTag.attr_path, bindings[1].expr.tag);
    try std.testing.expectEqual(NodeTag.identifier, bindings[1].expr.data.attr_path.root.tag);
    try std.testing.expect(!bindings[1].inherit_outer);
    try std.testing.expect(bindings[1].inherit_group != 0);
}

test "parser recognizes attr path or default" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "a.b or 2");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_or, node.tag);
    try std.testing.expectEqual(NodeTag.attr_path, node.data.attr_or.attr_path.tag);
    try std.testing.expectEqual(NodeTag.integer, node.data.attr_or.default.tag);
}

test "parser gives attr defaults selection precedence" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "m.require or [ ] ++ m.imports or [ ]");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.concat, node.data.binary.op);
    try std.testing.expectEqual(NodeTag.attr_or, node.data.binary.left.tag);
    try std.testing.expectEqual(NodeTag.attr_or, node.data.binary.right.tag);
}

test "parser recognizes has-attr operator" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ a.b = 1; } ? a.b");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.has_attr, node.tag);
    try std.testing.expectEqual(@as(usize, 2), node.data.has_attr.segments.len);
}

test "parser recognizes mixed dynamic has-attr operator" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ a.b = 1; } ? a.${key}.c");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.has_attr_mixed, node.tag);
    try std.testing.expectEqual(@as(usize, 3), node.data.has_attr_mixed.segments.len);
}

test "parser rejects unparenthesized expression forms in lists" {
    const cases = [_][]const u8{
        "[ with { x = 1; }; x ]",
        "[ let x = 1; in x ]",
        "[ if true then 1 else 2 ]",
        "[ assert true; 1 ]",
        "[ ! true ]",
        "[ -1 ]",
        "[ x: x ]",
        "[ 1 + 2 ]",
    };

    for (cases) |source| {
        var arena = ast.AstArena.init(std.testing.allocator);
        defer arena.deinit();

        var parser = Parser.init(std.testing.allocator, &arena, source);
        defer parser.deinit();

        try std.testing.expectError(error.ParseError, parser.parse());
    }
}

test "parser accepts parenthesized expression forms in lists" {
    const cases = [_][]const u8{
        "[ (with { x = 1; }; x) ]",
        "[ (let x = 1; in x) ]",
        "[ (if true then 1 else 2) ]",
        "[ (assert true; 1) ]",
        "[ (! true) ]",
        "[ (-1) ]",
        "[ (x: x) ]",
        "[ (1 + 2) ]",
    };

    for (cases) |source| {
        var arena = ast.AstArena.init(std.testing.allocator);
        defer arena.deinit();

        var parser = Parser.init(std.testing.allocator, &arena, source);
        defer parser.deinit();

        _ = try parser.parse();
    }
}

test "parser records diagnostics without printing" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "$ $ 1");
    defer parser.deinit();

    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(@as(usize, 2), parser.diagnostics.items.len);
    try std.testing.expectEqualStrings("Invalid token.", parser.diagnostics.items[0].message);
    try std.testing.expectEqual(@as(u32, 0), parser.diagnostics.items[0].offset);
    try std.testing.expectEqual(@as(u32, 1), parser.diagnostics.items[0].column);
    try std.testing.expectEqualStrings("Invalid token.", parser.diagnostics.items[1].message);
    try std.testing.expectEqual(@as(u32, 2), parser.diagnostics.items[1].offset);
    try std.testing.expectEqual(@as(u32, 3), parser.diagnostics.items[1].column);
}

test "parser recovers across attrset entries" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ if = 1; good = 2; inherit = 3; alsoGood = 4; }");
    defer parser.deinit();

    // Panic-mode recovery keeps parsing after the first invalid attribute name
    // (`if`) and surfaces the later `inherit = 3` problem too — more than one
    // diagnostic, and the first pinpoints the `if` keyword.
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expect(parser.diagnostics.items.len >= 2);
    try std.testing.expectEqualStrings("Unexpected token 'if'.", parser.diagnostics.items[0].message);
}

// ---- prefix.zig / infix.zig targeted coverage ----
//
// Note on string interpolation: the scanner (see scanner.zig "recognizes nested
// strings in interpolation") flattens an entire interpolated string, including
// nested `${...}` and nested string literals, into a single `.string` token
// before the parser ever sees it. `prefix.stringLit` has exactly one code path
// (capture the token span as an atom) regardless of whether the source text
// contains interpolation. There is no separate prefix handler or branch for
// the interpolated case, so a parser-level "interpolation as prefix position"
// test would just re-exercise `stringLit` identically to a plain string test
// already implied above — skipped as redundant per the task guardrail.

test "parser disambiguates unary minus from binary minus" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "-1 - -2");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.sub, node.data.binary.op);

    try std.testing.expectEqual(NodeTag.unary_op, node.data.binary.left.tag);
    try std.testing.expectEqual(ast.UnaryOp.negate, node.data.binary.left.data.unary.op);
    try std.testing.expectEqual(NodeTag.integer, node.data.binary.left.data.unary.expr.tag);

    try std.testing.expectEqual(NodeTag.unary_op, node.data.binary.right.tag);
    try std.testing.expectEqual(ast.UnaryOp.negate, node.data.binary.right.data.unary.op);
    try std.testing.expectEqual(NodeTag.integer, node.data.binary.right.data.unary.expr.tag);
}

test "parser gives unary minus higher precedence than multiplication" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "-2 * 3");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.mul, node.data.binary.op);
    try std.testing.expectEqual(NodeTag.unary_op, node.data.binary.left.tag);
    try std.testing.expectEqual(ast.UnaryOp.negate, node.data.binary.left.data.unary.op);
    try std.testing.expectEqual(NodeTag.integer, node.data.binary.right.tag);
}

test "parser gives boolean not higher precedence than and/or" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "!true && false || !false");
    const node = try parser.parse();

    // (!true && false) || (!false)
    try std.testing.expectEqual(NodeTag.binary_op, node.tag);
    try std.testing.expectEqual(ast.BinaryOp.or_, node.data.binary.op);

    const lhs = node.data.binary.left;
    try std.testing.expectEqual(NodeTag.binary_op, lhs.tag);
    try std.testing.expectEqual(ast.BinaryOp.and_, lhs.data.binary.op);
    try std.testing.expectEqual(NodeTag.unary_op, lhs.data.binary.left.tag);
    try std.testing.expectEqual(ast.UnaryOp.not, lhs.data.binary.left.data.unary.op);

    const rhs = node.data.binary.right;
    try std.testing.expectEqual(NodeTag.unary_op, rhs.tag);
    try std.testing.expectEqual(ast.UnaryOp.not, rhs.data.unary.op);
}

test "parser combines boolean not with trailing has-attr operator" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "!x ? y");
    const node = try parser.parse();

    // `!` binds the has-attr test itself: not (x ? y)
    try std.testing.expectEqual(NodeTag.unary_op, node.tag);
    try std.testing.expectEqual(ast.UnaryOp.not, node.data.unary.op);
    try std.testing.expectEqual(NodeTag.has_attr, node.data.unary.expr.tag);
    try std.testing.expectEqual(@as(usize, 1), node.data.unary.expr.data.has_attr.segments.len);
}

test "parser parses with as a prefix keyword" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "with { x = 1; }; x");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.with_expr, node.tag);
    try std.testing.expectEqual(NodeTag.attr_set, node.data.with_expr.attr_set.tag);
    try std.testing.expectEqual(NodeTag.identifier, node.data.with_expr.body.tag);
}

test "parser parses assert as a prefix keyword" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "assert true; 1");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.assert, node.tag);
    try std.testing.expectEqual(NodeTag.bool_true, node.data.assert.cond.tag);
    try std.testing.expectEqual(NodeTag.integer, node.data.assert.body.tag);
}

test "parser parses rec as a prefix keyword producing a recursive attrset" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "rec { a = 1; b = a; }");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.attr_set, node.tag);
    try std.testing.expect(node.data.attr_set.recursive);
    try std.testing.expectEqual(@as(usize, 2), node.data.attr_set.entries.len);
}

test "parser parses let as a prefix keyword with multiple bindings" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "let a = 1; b = 2; in a + b");
    const node = try parser.parse();

    try std.testing.expectEqual(NodeTag.let_in, node.tag);
    try std.testing.expectEqual(@as(usize, 2), node.data.let_in.bindings.len);
    try std.testing.expectEqual(NodeTag.binary_op, node.data.let_in.body.tag);
}

test "parser parses deeply nested parenthesization" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "((((((((((1))))))))))");
    const node = try parser.parse();

    var current = node;
    var depth: usize = 0;
    while (current.tag == .parens) : (depth += 1) {
        current = current.data.parens;
    }

    try std.testing.expectEqual(@as(usize, 10), depth);
    try std.testing.expectEqual(NodeTag.integer, current.tag);
}

test "parser attaches or-default to attribute path produced by function application" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "f a.b or c");
    const node = try parser.parse();

    // `f (a.b or c)` — the `or` default rewraps the apply's argument.
    try std.testing.expectEqual(NodeTag.apply, node.tag);
    try std.testing.expectEqual(NodeTag.identifier, node.data.apply.func.tag);
    try std.testing.expectEqual(NodeTag.attr_or, node.data.apply.arg.tag);
    try std.testing.expectEqual(NodeTag.attr_path, node.data.apply.arg.data.attr_or.attr_path.tag);
    try std.testing.expectEqual(NodeTag.identifier, node.data.apply.arg.data.attr_or.default.tag);
}

test "parser accepts a bare `or` as an identifier argument (Nix compat)" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "1 or 2");
    defer parser.deinit();

    // Nix allows the `or` keyword as a bare identifier argument, so `1 or 2`
    // parses as `(1 (or)) 2` — an application, not a syntax error. (It is still
    // a *type* error at eval time, since `1` is not a function.)
    const node = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.diagnostics.items.len);
    try std.testing.expectEqual(ast.NodeTag.apply, node.tag);
}

test "parser reports missing binding name in attrset lambda pattern" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ x }@: x");
    defer parser.deinit();

    // `@` must be followed by the binding name; `:` is rejected there.
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expectEqual(@as(usize, 1), parser.diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "Unexpected token ':'.",
        parser.diagnostics.items[0].message,
    );
}

test "parser accepts an empty inherit-from as a no-op" {
    // `inherit (src);` names nothing — a valid no-op in Nix, contributing no
    // attributes rather than being a parse error.
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "{ inherit (src); }");
    defer parser.deinit();

    const node = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.diagnostics.items.len);
    try std.testing.expectEqual(NodeTag.attr_set, node.tag);
    try std.testing.expectEqual(@as(usize, 0), node.data.attr_set.entries.len);
}

test "parser accepts an empty inherit in let as a no-op" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "let inherit; in 1");
    defer parser.deinit();

    const node = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.diagnostics.items.len);
    try std.testing.expectEqual(NodeTag.let_in, node.tag);
    try std.testing.expectEqual(@as(usize, 0), node.data.let_in.bindings.len);
}

// ---- body-span elision --------------------------------------------------

const Node = ast.Node;

fn atomEq(a: Node.Atom, b: Node.Atom) bool {
    return a.offset == b.offset and a.len == b.len;
}

fn optAtomEq(a: ?Node.Atom, b: ?Node.Atom) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    return atomEq(a.?, b.?);
}

fn atomsEq(a: []const Node.Atom, b: []const Node.Atom) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!atomEq(x, y)) return false;
    return true;
}

fn optNodeEq(a: ?*Node, b: ?*Node) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    return nodeEq(a.?, b.?);
}

/// Deep structural equality of two AST nodes, spans and source offsets
/// included — the byte-identity oracle for elided-body sub-parsing: a
/// sub-parse of the recorded span, offset-corrected, must reproduce the
/// eager parse EXACTLY (a mis-scanned span shows up as a mismatch here,
/// or as a parse error).
fn nodeEq(a: *const Node, b: *const Node) bool {
    if (a.tag != b.tag) return false;
    if (!optAtomEq(a.span, b.span)) return false;
    switch (a.tag) {
        .integer, .float_val, .string, .path, .uri, .search_path, .identifier, .bool_true, .bool_false, .null, .elided => return atomEq(a.data.atom, b.data.atom),
        .unary_op => return a.data.unary.op == b.data.unary.op and nodeEq(a.data.unary.expr, b.data.unary.expr),
        .binary_op => return a.data.binary.op == b.data.binary.op and
            nodeEq(a.data.binary.left, b.data.binary.left) and
            nodeEq(a.data.binary.right, b.data.binary.right),
        .apply => return a.data.apply.pipe == b.data.apply.pipe and
            nodeEq(a.data.apply.func, b.data.apply.func) and
            nodeEq(a.data.apply.arg, b.data.apply.arg),
        .lambda => return a.data.lambda.param_offset == b.data.lambda.param_offset and
            a.data.lambda.param_len == b.data.lambda.param_len and
            nodeEq(a.data.lambda.body, b.data.lambda.body),
        .lambda_attrs => {
            const la = a.data.lambda_attrs;
            const lb = b.data.lambda_attrs;
            if (!optAtomEq(la.bind_name, lb.bind_name)) return false;
            if (la.allow_extra != lb.allow_extra) return false;
            if (la.params.len != lb.params.len) return false;
            for (la.params, lb.params) |pa, pb| {
                if (!atomEq(pa.name, pb.name)) return false;
                if (!optNodeEq(pa.default, pb.default)) return false;
            }
            return nodeEq(la.body, lb.body);
        },
        .let_in => {
            const la = a.data.let_in;
            const lb = b.data.let_in;
            if (la.bindings.len != lb.bindings.len) return false;
            for (la.bindings, lb.bindings) |ba, bb| {
                if (ba.name_offset != bb.name_offset or ba.name_len != bb.name_len) return false;
                if (ba.inherit_outer != bb.inherit_outer) return false;
                if (ba.inherit_group != bb.inherit_group) return false;
                if (!atomsEq(ba.path, bb.path)) return false;
                if (!nodeEq(ba.expr, bb.expr)) return false;
            }
            return nodeEq(la.body, lb.body);
        },
        .if_else => return nodeEq(a.data.if_else.cond, b.data.if_else.cond) and
            nodeEq(a.data.if_else.then_branch, b.data.if_else.then_branch) and
            nodeEq(a.data.if_else.else_branch, b.data.if_else.else_branch),
        .assert => return nodeEq(a.data.assert.cond, b.data.assert.cond) and
            nodeEq(a.data.assert.body, b.data.assert.body),
        .with_expr => return nodeEq(a.data.with_expr.attr_set, b.data.with_expr.attr_set) and
            nodeEq(a.data.with_expr.body, b.data.with_expr.body),
        .attr_set => {
            const sa = a.data.attr_set;
            const sb = b.data.attr_set;
            if (sa.recursive != sb.recursive) return false;
            if (sa.entries.len != sb.entries.len) return false;
            for (sa.entries, sb.entries) |ea, eb| {
                if (ea.inherit_outer != eb.inherit_outer) return false;
                if (ea.inherit_group != eb.inherit_group) return false;
                if (!atomsEq(ea.path, eb.path)) return false;
                if (!optNodeEq(ea.dynamic_name, eb.dynamic_name)) return false;
                if (!nodeEq(ea.expr, eb.expr)) return false;
            }
            return true;
        },
        .attr_path => return nodeEq(a.data.attr_path.root, b.data.attr_path.root) and
            atomsEq(a.data.attr_path.segments, b.data.attr_path.segments),
        .attr_dynamic => return nodeEq(a.data.attr_dynamic.root, b.data.attr_dynamic.root) and
            nodeEq(a.data.attr_dynamic.name, b.data.attr_dynamic.name),
        .attr_or => return nodeEq(a.data.attr_or.attr_path, b.data.attr_or.attr_path) and
            nodeEq(a.data.attr_or.default, b.data.attr_or.default),
        .has_attr => return nodeEq(a.data.has_attr.root, b.data.has_attr.root) and
            atomsEq(a.data.has_attr.segments, b.data.has_attr.segments),
        .has_attr_mixed => {
            const ha = a.data.has_attr_mixed;
            const hb = b.data.has_attr_mixed;
            if (!nodeEq(ha.root, hb.root)) return false;
            if (ha.segments.len != hb.segments.len) return false;
            for (ha.segments, hb.segments) |seg_a, seg_b| {
                switch (seg_a) {
                    .static => |x| switch (seg_b) {
                        .static => |y| if (!atomEq(x, y)) return false,
                        .dynamic => return false,
                    },
                    .dynamic => |x| switch (seg_b) {
                        .static => return false,
                        .dynamic => |y| if (!nodeEq(x, y)) return false,
                    },
                }
            }
            return true;
        },
        .list => {
            if (a.data.list.items.len != b.data.list.items.len) return false;
            for (a.data.list.items, b.data.list.items) |ia, ib| {
                if (!nodeEq(ia, ib)) return false;
            }
            return true;
        },
        .parens => return nodeEq(a.data.parens, b.data.parens),
    }
}

/// Build a plain attrset source with enough prior clauses to open the
/// elision gate, `big = <body>;` as the next entry, and one trailing
/// entry (so the terminator handoff is exercised mid-set).
fn elisionSource(a: std.mem.Allocator, body: []const u8) ![]u8 {
    var src: std.ArrayListUnmanaged(u8) = .empty;
    errdefer src.deinit(a);
    try src.appendSlice(a, "{\n");
    var i: usize = 0;
    while (i < Parser.elide_min_prior_clauses) : (i += 1) {
        try src.print(a, "pre{d} = 0;\n", .{i});
    }
    try src.print(a, "big = {s};\ntail = 1;\n}}", .{body});
    return src.toOwnedSlice(a);
}

fn findEntry(root: *const Node, source: []const u8, name: []const u8) ?Node.AttrSetEntry {
    for (root.data.attr_set.entries) |entry| {
        if (entry.path.len == 0) continue;
        const seg = entry.path[0];
        if (std.mem.eql(u8, source[seg.offset .. seg.offset + seg.len], name)) return entry;
    }
    return null;
}

/// The elision oracle: parse the same source eagerly and with elision.
/// If `expect_elided`, the elided entry's span must reproduce the body
/// text EXACTLY, and sub-parsing it (offset-corrected, as the compiler's
/// materialize does) must equal the eager tree node-for-node. Otherwise
/// the elided parse must already equal the eager tree.
fn checkElision(body: []const u8, expect_elided: bool) !void {
    const a = std.testing.allocator;
    // Fixture sanity: an expect-elided body must clear the size gate.
    if (expect_elided) try std.testing.expect(body.len >= Parser.elide_min_body_bytes);
    const src = try elisionSource(a, body);
    defer a.free(src);

    var eager_arena = ast.AstArena.init(a);
    defer eager_arena.deinit();
    var eager_parser = Parser.init(a, &eager_arena, src);
    defer eager_parser.deinit();
    const eager_root = try eager_parser.parse();
    const eager_big = findEntry(eager_root, src, "big").?;

    var arena = ast.AstArena.init(a);
    defer arena.deinit();
    var parser = Parser.init(a, &arena, src);
    defer parser.deinit();
    parser.elide_bodies = true;
    const root = try parser.parse();
    const big = findEntry(root, src, "big").?;

    if (!expect_elided) {
        try std.testing.expect(big.expr.tag != .elided);
        try std.testing.expect(nodeEq(eager_big.expr, big.expr));
        return;
    }

    try std.testing.expectEqual(NodeTag.elided, big.expr.tag);
    const span = big.expr.data.atom;
    try std.testing.expectEqualStrings(body, src[span.offset .. span.offset + span.len]);

    // Sub-parse the span exactly as `materializeElided` does.
    var sub_parser = Parser.init(a, &arena, src[span.offset .. span.offset + span.len]);
    defer sub_parser.deinit();
    const sub = try sub_parser.parse();
    ast.offsetNode(sub, span.offset);
    try std.testing.expect(nodeEq(eager_big.expr, sub));

    // The rest of the set must be untouched: prior entries and the entry
    // AFTER the elided one (proves the `;` handoff resynchronized).
    const eager_tail = findEntry(eager_root, src, "tail").?;
    const tail = findEntry(root, src, "tail").?;
    try std.testing.expect(nodeEq(eager_tail.expr, tail.expr));
    try std.testing.expectEqual(eager_root.data.attr_set.entries.len, root.data.attr_set.entries.len);
}

test "elision: application body with nested attrsets and inherit (hackage shape)" {
    try checkElision(
        \\callPackage ({ mkDerivation }: mkDerivation { pname = "x"; version = "1.0"; sha256 = "abcdef"; }) { inherit lib; }
    , true);
}

test "elision: strings containing braces, semicolons, quotes, and escaped interpolation" {
    try checkElision(
        \\"contains { braces } ; semicolons ; \" escaped quotes \" and \${ escaped interpolation }" + suffix + morepadding
    , true);
}

test "elision: interpolation nesting an attrset whose string contains '; }'" {
    try checkElision(
        \\"pre ${ { x = "a;}b"; }.x } post padding padding padding padding padding padding padding" + suffix + morepad
    , true);
}

test "elision: comments hiding quotes, semicolons, and braces" {
    try checkElision(
        \\foo.bar /* " ; } block */ + other # line comment with " ; }
        \\+ morepadding + evenmorepadding + yetmorepadding + padpadpad
    , true);
}

test "elision: multiline string with semicolons, braces, and interpolation" {
    try checkElision("''\n  indented ; } \" with stuff\n  more ${interp} here\n  ''${escaped}\n'' + padpadpadpadpadpad + morepadding + evenmore", true);
}

test "elision: let-in body (binding semicolons are not terminators)" {
    try checkElision(
        \\let q = 1; r = { s = 2; }; in q + r.s + 111111111 + 222222222 + 333333333 + 444444444 + 555555555 + 6666
    , true);
}

test "elision: nested let inside let" {
    try checkElision(
        \\let outer = let inner = 1; in inner; in outer + 1000000 + 2000000 + 3000000 + 4000000 + 5000000 + 600000
    , true);
}

test "elision: with and assert each own one semicolon" {
    try checkElision(
        \\with { p = 5; }; assert p == 5; p + 100000000 + 200000000 + 300000000 + 400000000 + 500000000 + 6000000
    , true);
}

test "elision: if-then-else with attrset and list branches" {
    try checkElision(
        \\if true then { x = 1; y = 2; } else [ 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 ]
    , true);
}

test "elision: mixed atoms — paths, search paths, numbers, strings" {
    try checkElision(
        \\f ./some/path.nix ../other/${dir}/file <nixpkgs/lib> 12345 6.5 "str; }" x.y.z or fallback ./more/padding.nix
    , true);
}

test "elision shape gate: plain lambda body is not elided" {
    try checkElision(
        \\x: x + 1 + 100000000 + 200000000 + 300000000 + 400000000 + 500000000 + 600000000 + 70000000
    , false);
}

test "elision shape gate: pattern lambda body is not elided" {
    try checkElision(
        \\{ x, y ? 2, ... }: x + y + 100000000 + 200000000 + 300000000 + 400000000 + 500000000 + 6000
    , false);
}

test "elision shape gate: bound pattern lambdas are not elided" {
    try checkElision(
        \\args@{ x, ... }: x + 100000000 + 200000000 + 300000000 + 400000000 + 500000000 + 600000000
    , false);
    try checkElision(
        \\{ x, ... }@args: x + 100000000 + 200000000 + 300000000 + 400000000 + 500000000 + 600000000
    , false);
}

test "elision shape gate: whole-body attrset literal is not elided" {
    try checkElision(
        \\{ a = 1; b = 2; c = 3; d = 4; e = 5; f = 6; g = 7; h = 8; i = 9; j = 10; k = 11; l = 12; }
    , false);
}

test "elision shape gate: whole-body list literal is not elided" {
    try checkElision(
        \\[ 100000000 200000000 300000000 400000000 500000000 600000000 700000000 800000000 900000 ]
    , false);
}

test "elision shape gate: whole-body parens are not elided" {
    try checkElision(
        \\(f x + 100000000 + 200000000 + 300000000 + 400000000 + 500000000 + 600000000 + 700000000)
    , false);
}

test "elision shape gate: rec attrset is not elided" {
    try checkElision(
        \\rec { a = 1; b = a + 100000000 + 200000000 + 300000000 + 400000000 + 500000000 + 6000000; }
    , false);
}

test "elision shape gate: single-token string body is not elided" {
    try checkElision(
        \\"a single long string token whose length is well over one hundred bytes of padding padding padding"
    , false);
}

test "elision size gate: small bodies are not elided" {
    try checkElision("smallIdent + 1 + 2", false);
}

test "elision gate: early entries (before the clause threshold) are not elided" {
    const a = std.testing.allocator;
    const body = "callPackage some.long.attr.path { config = { allowUnfree = true; }; overrides = old: old; }";
    const src = try std.fmt.allocPrint(a, "{{\nbig = {s};\ntail = 1;\n}}", .{body});
    defer a.free(src);

    var arena = ast.AstArena.init(a);
    defer arena.deinit();
    var parser = Parser.init(a, &arena, src);
    defer parser.deinit();
    parser.elide_bodies = true;
    const root = try parser.parse();
    const big = findEntry(root, src, "big").?;
    try std.testing.expect(big.expr.tag != .elided);
}

test "elision gate: let bindings are never elided" {
    const a = std.testing.allocator;
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "let\n");
    var i: usize = 0;
    while (i < Parser.elide_min_prior_clauses + 4) : (i += 1) {
        try src.print(a, "pre{d} = 0;\n", .{i});
    }
    try src.appendSlice(a, "big = pre0 + 100000000 + 200000000 + 300000000 + 400000000 + 500000000 + 600000000 + 7000;\nin big");

    var arena = ast.AstArena.init(a);
    defer arena.deinit();
    var parser = Parser.init(a, &arena, src.items);
    defer parser.deinit();
    parser.elide_bodies = true;
    const root = try parser.parse();
    for (root.data.let_in.bindings) |binding| {
        try std.testing.expect(binding.expr.tag != .elided);
    }
}

test "elision gate: rec-brace binds are never elided" {
    const a = std.testing.allocator;
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "rec {\n");
    var i: usize = 0;
    while (i < Parser.elide_min_prior_clauses + 4) : (i += 1) {
        try src.print(a, "pre{d} = 0;\n", .{i});
    }
    try src.appendSlice(a, "big = pre0 + 100000000 + 200000000 + 300000000 + 400000000 + 500000000 + 600000000 + 7000;\n}");

    var arena = ast.AstArena.init(a);
    defer arena.deinit();
    var parser = Parser.init(a, &arena, src.items);
    defer parser.deinit();
    parser.elide_bodies = true;
    const root = try parser.parse();
    for (root.data.attr_set.entries) |entry| {
        try std.testing.expect(entry.expr.tag != .elided);
    }
}

test "elision: dotted attrpath binds elide too" {
    const a = std.testing.allocator;
    const body = "callPackage some.long.attr.path { config = { allowUnfree = true; }; overrides = old: old; extra = 1; }";
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "{\n");
    var i: usize = 0;
    while (i < Parser.elide_min_prior_clauses) : (i += 1) {
        try src.print(a, "pre{d} = 0;\n", .{i});
    }
    try src.print(a, "outer.inner = {s};\ntail = 1;\n}}", .{body});

    var arena = ast.AstArena.init(a);
    defer arena.deinit();
    var parser = Parser.init(a, &arena, src.items);
    defer parser.deinit();
    parser.elide_bodies = true;
    const root = try parser.parse();
    const entry = findEntry(root, src.items, "outer").?;
    try std.testing.expectEqual(NodeTag.elided, entry.expr.tag);
    const span = entry.expr.data.atom;
    try std.testing.expectEqualStrings(body, src.items[span.offset .. span.offset + span.len]);
}

test "elision: unbalanced body falls back to a normal parse error" {
    const a = std.testing.allocator;
    const src = try elisionSource(a, "foo ) bar + 100000000 + 200000000 + 300000000 + 400000000 + 500000000 + 600000000 + 70000");
    defer a.free(src);

    var arena = ast.AstArena.init(a);
    defer arena.deinit();
    var parser = Parser.init(a, &arena, src);
    defer parser.deinit();
    parser.elide_bodies = true;
    try std.testing.expectError(error.ParseError, parser.parse());
}

test "elision: pipe operators inside an elided body are still recorded" {
    const a = std.testing.allocator;
    const src = try elisionSource(a, "value |> transform |> finish + 100000000 + 200000000 + 300000000 + 400000000 + 500000000 + 600000000");
    defer a.free(src);

    var arena = ast.AstArena.init(a);
    defer arena.deinit();
    var parser = Parser.init(a, &arena, src);
    defer parser.deinit();
    parser.elide_bodies = true;
    const root = try parser.parse();
    const big = findEntry(root, src, "big").?;
    try std.testing.expectEqual(NodeTag.elided, big.expr.tag);
    try std.testing.expect(parser.used_pipe_operators);
}

test "elision: disabled by default" {
    const a = std.testing.allocator;
    const src = try elisionSource(a, "callPackage some.long.attr.path { config = { allowUnfree = true; }; overrides = old: old; }");
    defer a.free(src);

    var arena = ast.AstArena.init(a);
    defer arena.deinit();
    var parser = Parser.init(a, &arena, src);
    defer parser.deinit();
    const root = try parser.parse();
    for (root.data.attr_set.entries) |entry| {
        try std.testing.expect(entry.expr.tag != .elided);
    }
}

// --- `true` / `false` / `null` --------------------------------------------
// They lex as identifiers (Nix binds them in the base environment, so a binder
// shadows them), and `parse` retags the unshadowed ones back to literals.

test "parser folds unshadowed true/false/null to literals" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "[ true false null ]");
    defer parser.deinit();
    const node = try parser.parse();

    const items = node.data.list.items;
    try std.testing.expectEqual(NodeTag.bool_true, items[0].tag);
    try std.testing.expectEqual(NodeTag.bool_false, items[1].tag);
    try std.testing.expectEqual(NodeTag.null, items[2].tag);
}

test "parser leaves true/false/null as identifiers when the file binds one" {
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    // A binder anywhere disables the fold for the whole file — `null` here is
    // still the base-env constant, but it must resolve through the scope chain.
    var parser = Parser.init(std.testing.allocator, &arena, "let true = 1; in [ true null ]");
    defer parser.deinit();
    const node = try parser.parse();

    const items = node.data.let_in.body.data.list.items;
    try std.testing.expectEqual(NodeTag.identifier, items[0].tag);
    try std.testing.expectEqual(NodeTag.identifier, items[1].tag);
}

test "parser accepts true/false/null in every binding position" {
    const sources = [_][]const u8{
        "true: true",
        "{ null ? 3 }: null",
        "{ false }: false",
        "let true = 1; in true",
        "rec { null = 1; x = null; }",
        "{ inherit true false null; }",
        "x.true",
    };
    for (sources) |src| {
        var arena = ast.AstArena.init(std.testing.allocator);
        defer arena.deinit();
        var parser = Parser.init(std.testing.allocator, &arena, src);
        defer parser.deinit();
        _ = parser.parse() catch |err| {
            std.debug.print("failed to parse: {s}\n", .{src});
            return err;
        };
    }
}

test "keyword_literal_bound suppresses the fold for a sub-parse" {
    // A sub-parsed span (an elided body, a `${…}` interpolation) cannot see an
    // enclosing `let true = …`, so its caller sets the flag and the uses stay
    // identifiers for the compiler to resolve against the live scope.
    var arena = ast.AstArena.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(std.testing.allocator, &arena, "[ true null ]");
    defer parser.deinit();
    parser.keyword_literal_bound = true;
    const node = try parser.parse();

    const items = node.data.list.items;
    try std.testing.expectEqual(NodeTag.identifier, items[0].tag);
    try std.testing.expectEqual(NodeTag.identifier, items[1].tag);
}
