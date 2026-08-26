const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;
const renderStrictForTest = @import("../test_helpers.zig").renderStrictForTest;

test "if-else selects the matching branch" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const then_arm = try ev.evaluate("if 1 == 1 then \"yes\" else \"no\"");
    try std.testing.expectEqualStrings("yes", ev.intern.get(then_arm.asInternId()));

    const else_arm = try ev.evaluate("if 1 == 2 then \"yes\" else \"no\"");
    try std.testing.expectEqualStrings("no", ev.intern.get(else_arm.asInternId()));
}

test "assert passes through the body when the condition holds" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("assert 1 + 1 == 2; 42");
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "assert raises an error when the condition fails" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.AssertionFailed, ev.evaluate("assert 1 == 2; 42"));
}

test "the right operand of a boolean operator must be a Boolean" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    // The taken branch's operand *is* the expression's result, so without a
    // check on it a non-Boolean leaks into the value instead of erroring.
    try std.testing.expectError(error.TypeError, ev.evaluate("true && 1"));
    try std.testing.expectError(error.TypeError, ev.evaluate("false || 1"));
    try std.testing.expectError(error.TypeError, ev.evaluate("true -> 1"));
    try std.testing.expectError(error.TypeError, ev.evaluate("true && \"x\""));
    try std.testing.expectError(error.TypeError, ev.evaluate("true && true && 1"));
    try std.testing.expectError(error.TypeError, ev.evaluate("false || false || 1"));
    try std.testing.expectError(error.TypeError, ev.evaluate("let f = a: b: a && b; in f true 1"));
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.typeOf (true && 1)"));
}

test "boolean operators still short-circuit past an untyped right operand" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expect(!(try ev.evaluate("false && 1")).asBool());
    try std.testing.expect((try ev.evaluate("true || 1")).asBool());
    try std.testing.expect((try ev.evaluate("false -> 1")).asBool());
    try std.testing.expect(!(try ev.evaluate("false && (throw \"boom\")")).asBool());
    try std.testing.expect((try ev.evaluate("true || (throw \"boom\")")).asBool());
    try std.testing.expect((try ev.evaluate("false -> (throw \"boom\")")).asBool());
    try std.testing.expect(!(try ev.evaluate("false && true && 1")).asBool());
    try std.testing.expect((try ev.evaluate("true || false || 1")).asBool());
}

test "boolean operators reduce to a Boolean result" {
    const rendered = try renderStrictForTest(
        "[ (true && true) (true && false) (false && true) (false && false)" ++
            " (true || false) (false || true) (false || false)" ++
            " (true -> true) (true -> false) (false -> true) (false -> false)" ++
            " (builtins.typeOf (false && 1)) ]",
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "[ true false false false true true false true false true true \"bool\" ]",
        rendered,
    );
}

test "with brings an attribute set's names into scope" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("with { a = 1; b = 2; }; a + b");
    try std.testing.expectEqual(@as(i64, 3), result.asInt());
}

test "an inner with shadows an outer with for the same name" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate("with { a = 1; }; with { a = 2; }; a");
    try std.testing.expectEqual(@as(i64, 2), result.asInt());
}
