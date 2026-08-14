//! `true`, `false` and `null` are ordinary variables bound in Nix's base
//! environment, not reserved words: a lexical binder shadows them, and they are
//! legal in every binding position. They lex as identifiers and the parser folds
//! the unshadowed ones back to literal nodes — these checks pin both halves.

const std = @import("std");
const expr = @import("expr");
const Engine = expr.Engine;

test "end-to-end: a binder shadows true/false/null" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectEqual(@as(i64, 1), (try ev.evaluate("let true = 1; in true")).asInt());
    try std.testing.expectEqual(@as(i64, 2), (try ev.evaluate("let false = 2; in false")).asInt());
    try std.testing.expectEqual(@as(i64, 3), (try ev.evaluate("let null = 3; in null")).asInt());

    // Lambda parameters, plain and as an attrset formal with a default.
    try std.testing.expectEqual(@as(i64, 5), (try ev.evaluate("(true: true) 5")).asInt());
    try std.testing.expectEqual(@as(i64, 3), (try ev.evaluate("({ null ? 3 }: null) { }")).asInt());
    try std.testing.expectEqual(@as(i64, 7), (try ev.evaluate("({ false }: false) { false = 7; }")).asInt());

    // A `rec` set binds them for its own members; a plain set does not.
    try std.testing.expectEqual(@as(i64, 4), (try ev.evaluate("(rec { true = 4; x = true; }).x")).asInt());
    try std.testing.expect((try ev.evaluate("({ true = 4; x = true; }).x")).isBool());

    // `with` never beats the base environment (nor a lexical binding).
    try std.testing.expect((try ev.evaluate("with { true = 9; }; true")).isBool());
}

test "end-to-end: unshadowed true/false/null are the base-env constants" {
    const alloc = std.testing.allocator;

    var ev = try Engine.init(alloc, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expect((try ev.evaluate("true")).isBool());
    try std.testing.expect((try ev.evaluate("null")).isNull());
    try std.testing.expectEqual(@as(i64, 1), (try ev.evaluate("if true then 1 else 2")).asInt());

    // Shadowing one name does not disturb the others' meaning.
    try std.testing.expect((try ev.evaluate("let true = 1; in null")).isNull());
}
