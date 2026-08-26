const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;
const renderStrictForTest = @import("../test_helpers.zig").renderStrictForTest;

test "a path never equals a string with the same text" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expect(!(try ev.evaluate("\"/a\" == /a")).asBool());
    try std.testing.expect(!(try ev.evaluate("/a == \"/a\"")).asBool());
    try std.testing.expect((try ev.evaluate("\"/a\" != /a")).asBool());
    // Past the inline-intern threshold the string lives on the heap, which
    // is a different residency but still not a path.
    try std.testing.expect(!(try ev.evaluate("/abcdefghijklmnop == \"/abcdefghijklmnop\"")).asBool());
    try std.testing.expect(!(try ev.evaluate("\"${\"/a\"}\" == /a")).asBool());
}

test "path-vs-string inequality holds through lists and attrsets" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expect(!(try ev.evaluate("[ /a ] == [ \"/a\" ]")).asBool());
    try std.testing.expect((try ev.evaluate("[ /a ] == [ /a ]")).asBool());
    try std.testing.expect(!(try ev.evaluate("{ p = /a; } == { p = \"/a\"; }")).asBool());
    try std.testing.expect((try ev.evaluate("{ p = /a; } == { p = /a; }")).asBool());
    try std.testing.expect(!(try ev.evaluate("{ outPath = /a; } == { outPath = \"/a\"; }")).asBool());
    try std.testing.expect(
        !(try ev.evaluate(
            "{ type = \"derivation\"; outPath = /a; } == { type = \"derivation\"; outPath = \"/a\"; }",
        )).asBool(),
    );
    try std.testing.expect(
        (try ev.evaluate(
            "{ type = \"derivation\"; outPath = \"/a\"; } == { type = \"derivation\"; outPath = \"/a\"; }",
        )).asBool(),
    );
}

test "elem does not match a path against a string" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expect(!(try ev.evaluate("builtins.elem /a [ \"/a\" ]")).asBool());
    try std.testing.expect(!(try ev.evaluate("builtins.elem \"/a\" [ /a ]")).asBool());
    try std.testing.expect((try ev.evaluate("builtins.elem /a [ 1 \"/a\" /a ]")).asBool());
}

test "genericClosure keeps deduplicating equal keys" {
    const paths = try renderStrictForTest(
        "builtins.genericClosure { startSet = [ { key = /a; } { key = /a; } ]; operator = item: []; }",
    );
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqualStrings("[ { key = /a; } ]", paths);

    // Paths and strings share a key hash bucket (it hashes text, not type);
    // the exact compare must still keep them apart.
    const mixed = try renderStrictForTest(
        "builtins.genericClosure { startSet = [ { key = /a; } { key = \"/a\"; } ]; operator = item: []; }",
    );
    defer std.testing.allocator.free(mixed);
    try std.testing.expectEqualStrings("[ { key = /a; } { key = \"/a\"; } ]", mixed);

    const numbers = try renderStrictForTest(
        "builtins.genericClosure { startSet = [ { key = 1; } ]; " ++
            "operator = item: if item.key < 4 then [ { key = item.key + 1; } ] else []; }",
    );
    defer std.testing.allocator.free(numbers);
    try std.testing.expectEqualStrings(
        "[ { key = 1; } { key = 2; } { key = 3; } { key = 4; } ]",
        numbers,
    );
}

test "functions compare by identity" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // Lix 2.95 short-circuits equality on pointer identity, so a function
    // does equal itself; two syntactically identical lambdas do not.
    try std.testing.expect((try ev.evaluate("let f = x: x; in f == f")).asBool());
    try std.testing.expect((try ev.evaluate("let f = x: x; in [ f ] == [ f ]")).asBool());
    try std.testing.expect((try ev.evaluate("let f = x: x; in { a = f; } == { a = f; }")).asBool());
    try std.testing.expect((try ev.evaluate("let f = x: x; in builtins.elem f [ f ]")).asBool());
    try std.testing.expect((try ev.evaluate("builtins.length == builtins.length")).asBool());
    try std.testing.expect((try ev.evaluate("let f = builtins.add 1; in f == f")).asBool());
    try std.testing.expect(!(try ev.evaluate("[ (x: x) ] == [ (x: x) ]")).asBool());
    try std.testing.expect(!(try ev.evaluate("(x: x) == 1")).asBool());
}
