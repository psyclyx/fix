const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;

test "stringLength counts bytes, not unicode codepoints" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // "café" is 4 codepoints but 5 bytes (é is a 2-byte UTF-8 sequence).
    const result = try ev.evaluate("builtins.stringLength \"caf\u{00e9}\"");
    try std.testing.expectEqual(@as(i64, 5), result.asInt());
}

test "substring slices multi-byte utf8 text by byte offset without corrupting the remainder" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // "caf\u{00e9}x" is bytes: c a f [0xc3 0xa9] x. Take the 2-byte "é" at offset 3.
    const result = try ev.evaluate("builtins.substring 3 2 \"caf\u{00e9}x\"");
    try std.testing.expectEqualStrings("\u{00e9}", ev.intern.get(result.asInternId()));
}

test "substring on a start index past the string end returns an empty string rather than erroring" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("builtins.substring 10 5 \"abc\"");
    try std.testing.expectEqualStrings("", ev.intern.get(result.asInternId()));
}

test "replaceStrings with an empty needle inserts the replacement between every character" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // Matches Nix: an empty pattern matches at every position, including the end.
    const result = try ev.evaluate("builtins.replaceStrings [ \"\" ] [ \"x\" ] \"abc\"");
    try std.testing.expectEqualStrings("xaxbxcx", ev.intern.get(result.asInternId()));
}

test "concatStringsSep joins a list of strings with the given separator" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("builtins.concatStringsSep \"-\" [ \"a\" \"b\" \"c\" ]");
    try std.testing.expectEqualStrings("a-b-c", ev.intern.get(result.asInternId()));
}

test "toString rejects a list containing a non-coercible attrset" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.toString [ {} ]"));
}

// A self-referential coercion used to recurse natively until the fiber stack
// faulted. Each level now counts against max-call-depth, as in Nix.
test "a cyclic outPath or __toString coercion errors instead of faulting" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.policy.max_call_depth = 128;

    try std.testing.expectError(
        error.CallDepthExceeded,
        ev.evaluate("let r = { outPath = r; }; in builtins.toString r"),
    );
    try std.testing.expectError(
        error.CallDepthExceeded,
        ev.evaluate("let r = { __toString = _: r; }; in builtins.toString r"),
    );
    // A finite chain well inside the budget still coerces.
    const ok = try ev.evaluate("builtins.toString { outPath = { outPath = \"/x\"; }; }");
    try std.testing.expectEqualStrings("/x", ev.intern.get(ok.asInternId()));
}

test "toString of a float prints its exact value to six decimals, like std::to_string" {
    const renderForTest = @import("../test_helpers.zig").renderForTest;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "builtins.toString 1.5", "\"1.500000\"" },
        // A tie in binary rounds to even; the shortest decimal digits of
        // these doubles would round up.
        .{ "builtins.toString 1.0078125", "\"1.007812\"" },
        .{ "builtins.toString 6.71088640127945e7", "\"67108864.012794\"" },
        .{ "builtins.toString 3.002399751580331e16", "\"30023997515803312.000000\"" },
        .{ "builtins.toString [ 1.0e23 ]", "\"99999999999999991611392.000000\"" },
    };
    for (cases) |case| {
        const rendered = try renderForTest(case[0]);
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqualStrings(case[1], rendered);
    }
}
