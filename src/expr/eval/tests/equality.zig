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

// Nix holds `genericClosure` keys in an ordered set, so a key that cannot be
// ordered against the keys already there is an error rather than a distinct
// entry — the dedup never gets to run. Two keys of the same unorderable type
// fail too, because the insert still has to compare them.
test "genericClosure rejects keys it cannot order" {
    const cases = [_][]const u8{
        "[ { key = /a; } { key = \"/a\"; } ]",
        "[ { key = 1; } { key = \"a\"; } ]",
        "[ { key = 1; } { key = /a; } ]",
        "[ { key = 1; } { key = true; } ]",
        "[ { key = 1; } { key = null; } ]",
        "[ { key = 1; } { key = [ 1 ]; } ]",
        "[ { key = 1; } { key = { q = 1; }; } ]",
        "[ { key = true; } { key = true; } ]",
        "[ { key = null; } { key = null; } ]",
        "[ { key = { q = 1; }; } { key = { q = 1; }; } ]",
        // A later key, and one the operator produces, are checked the same way.
        "[ { key = 1; } { key = 2; } { key = \"a\"; } ]",
        // Lists order element-wise, so an unorderable element pair errors.
        "[ { key = [ 1 ]; } { key = [ \"a\" ]; } ]",
        "[ { key = [ true ]; } { key = [ false ]; } ]",
    };
    for (cases) |start_set| {
        const expr = try std.fmt.allocPrint(
            std.testing.allocator,
            "builtins.genericClosure {{ startSet = {s}; operator = item: []; }}",
            .{start_set},
        );
        defer std.testing.allocator.free(expr);
        try std.testing.expectError(error.TypeError, renderStrictForTest(expr));
    }
    try std.testing.expectError(error.TypeError, renderStrictForTest(
        "builtins.genericClosure { startSet = [ { key = 1; } ]; operator = item: [ { key = \"a\"; } ]; }",
    ));
}

test "genericClosure accepts every key pair Nix can order" {
    // A lone unorderable key is never compared with anything, so it is fine.
    const cases = [_]struct { expr: []const u8, want: []const u8 }{
        .{ .expr = "[ { key = true; } ]", .want = "[ { key = true; } ]" },
        .{ .expr = "[ { key = 1; } { key = 1.0; } ]", .want = "[ { key = 1; } ]" },
        .{ .expr = "[ { key = 1; } { key = 1.5; } ]", .want = "[ { key = 1; } { key = 1.5; } ]" },
        .{ .expr = "[ { key = \"a\"; } { key = \"b\"; } ]", .want = "[ { key = \"a\"; } { key = \"b\"; } ]" },
        .{ .expr = "[ { key = /a; } { key = /b; } ]", .want = "[ { key = /a; } { key = /b; } ]" },
        .{ .expr = "[ { key = [ 1 ]; } { key = [ 2 ]; } ]", .want = "[ { key = [ 1 ]; } { key = [ 2 ]; } ]" },
        // Equal elements are skipped before ordering, so equal-but-unorderable
        // list elements dedup instead of erroring.
        .{ .expr = "[ { key = [ true ]; } { key = [ true ]; } ]", .want = "[ { key = [ true ]; } ]" },
        // Extra fields ride along; only `key` decides.
        .{
            .expr = "[ { key = 1; extra = \"x\"; } { key = 1; extra = \"y\"; } { key = 2; } ]",
            .want = "[ { extra = \"x\"; key = 1; } { key = 2; } ]",
        },
    };
    for (cases) |case| {
        const expr = try std.fmt.allocPrint(
            std.testing.allocator,
            "builtins.genericClosure {{ startSet = {s}; operator = item: []; }}",
            .{case.expr},
        );
        defer std.testing.allocator.free(expr);
        const got = try renderStrictForTest(expr);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }

    // A real recursive closure still terminates.
    const closure = try renderStrictForTest(
        "builtins.genericClosure { startSet = [ { key = 0; } ]; " ++
            "operator = x: if x.key > 5 then [] else [ { key = x.key + 1; } { key = x.key + 2; } ]; }",
    );
    defer std.testing.allocator.free(closure);
    try std.testing.expectEqualStrings(
        "[ { key = 0; } { key = 1; } { key = 2; } { key = 3; } { key = 4; } { key = 5; } { key = 6; } { key = 7; } ]",
        closure,
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
