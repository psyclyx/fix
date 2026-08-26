const std = @import("std");
const std_testing = std.testing;
const renderForTest = @import("../test_helpers.zig").renderForTest;

test "length head and tail reject non-list arguments" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.length 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.head 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.tail 1"));
}

test "head and tail on an empty list raise index out of bounds" {
    try std_testing.expectError(error.IndexOutOfBounds, renderForTest("builtins.head [ ]"));
    try std_testing.expectError(error.IndexOutOfBounds, renderForTest("builtins.tail [ ]"));
}

test "tail on a single-element list returns the empty list" {
    const result = try renderForTest("builtins.tail [ 1 ]");
    defer std_testing.allocator.free(result);
    try std_testing.expectEqualStrings("[ ]", result);
}

test "concatLists on an empty list and rejects non-list elements" {
    const empty = try renderForTest("builtins.concatLists [ ]");
    defer std_testing.allocator.free(empty);
    try std_testing.expectEqualStrings("[ ]", empty);

    try std_testing.expectError(error.TypeError, renderForTest("builtins.concatLists 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.concatLists [ 1 ]"));
}

test "right-associated list concatenation preserves lazy elements" {
    const result = try renderForTest("[ 1 ] ++ [ (builtins.throw \"unused\") ] ++ [ 3 ]");
    defer std_testing.allocator.free(result);
    try std_testing.expectEqualStrings("[ 1 <CODE> 3 ]", result);
}

test "listToAttrs on an empty list and rejects non-attrs elements" {
    const empty = try renderForTest("builtins.listToAttrs [ ]");
    defer std_testing.allocator.free(empty);
    try std_testing.expectEqualStrings("{ }", empty);

    try std_testing.expectError(error.TypeError, renderForTest("builtins.listToAttrs 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.listToAttrs [ 1 ]"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.listToAttrs [ { name = 1; value = 2; } ]"));
}

test "map filter all any concatMap and mapAttrs on empty inputs" {
    const mapped = try renderForTest("builtins.map (x: x + 1) [ ]");
    defer std_testing.allocator.free(mapped);
    try std_testing.expectEqualStrings("[ ]", mapped);

    const filtered = try renderForTest("builtins.filter (x: x) [ ]");
    defer std_testing.allocator.free(filtered);
    try std_testing.expectEqualStrings("[ ]", filtered);

    const all_empty = try renderForTest("builtins.all (x: x) [ ]");
    defer std_testing.allocator.free(all_empty);
    try std_testing.expectEqualStrings("true", all_empty);

    const any_empty = try renderForTest("builtins.any (x: x) [ ]");
    defer std_testing.allocator.free(any_empty);
    try std_testing.expectEqualStrings("false", any_empty);

    const concat_mapped = try renderForTest("builtins.concatMap (x: [ x ]) [ ]");
    defer std_testing.allocator.free(concat_mapped);
    try std_testing.expectEqualStrings("[ ]", concat_mapped);

    const mapped_attrs = try renderForTest("builtins.mapAttrs (name: value: value) { }");
    defer std_testing.allocator.free(mapped_attrs);
    try std_testing.expectEqualStrings("{ }", mapped_attrs);
}

test "map rejects a non-callable function argument" {
    try std_testing.expectError(error.NotCallable, renderForTest("builtins.map 1 [ 1 ]"));
}

test "concatMap rejects a function whose result is not a list" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.concatMap (x: x) [ 1 ]"));
}

test "elemAt reports out-of-bounds and negative indices" {
    try std_testing.expectError(error.IndexOutOfBounds, renderForTest("builtins.elemAt [ 1 2 ] 2"));
    try std_testing.expectError(error.IndexOutOfBounds, renderForTest("builtins.elemAt [ 1 2 ] (-1)"));
    try std_testing.expectError(error.IndexOutOfBounds, renderForTest("builtins.elemAt [ ] 0"));
}

test "elem on an empty list is false without forcing the needle" {
    const result = try renderForTest("builtins.elem 1 [ ]");
    defer std_testing.allocator.free(result);
    try std_testing.expectEqualStrings("false", result);
}

test "seq and deepSeq force their first argument's effects before returning the second" {
    try std_testing.expectError(error.NixThrow, renderForTest("builtins.seq (builtins.throw \"boom\") 1"));
    try std_testing.expectError(error.NixThrow, renderForTest("builtins.deepSeq (builtins.throw \"boom\") 1"));

    // deepSeq forces nested structure (seq only forces WHNF).
    try std_testing.expectError(error.NixThrow, renderForTest("builtins.deepSeq { a = builtins.throw \"boom\"; } 1"));
    const seq_shallow = try renderForTest("builtins.seq { a = builtins.throw \"boom\"; } 1");
    defer std_testing.allocator.free(seq_shallow);
    try std_testing.expectEqualStrings("1", seq_shallow);
}

test "sort partition groupBy and genericClosure on empty inputs" {
    const sorted = try renderForTest("builtins.sort (a: b: a < b) [ ]");
    defer std_testing.allocator.free(sorted);
    try std_testing.expectEqualStrings("[ ]", sorted);

    const partitioned = try renderForTest("builtins.toJSON (builtins.partition (x: x) [ ])");
    defer std_testing.allocator.free(partitioned);
    try std_testing.expectEqualStrings("\"{\\\"right\\\":[],\\\"wrong\\\":[]}\"", partitioned);

    const grouped = try renderForTest("builtins.groupBy (x: \"k\") [ ]");
    defer std_testing.allocator.free(grouped);
    try std_testing.expectEqualStrings("{ }", grouped);

    const closure_empty = try renderForTest("builtins.genericClosure { startSet = [ ]; operator = item: [ ]; }");
    defer std_testing.allocator.free(closure_empty);
    try std_testing.expectEqualStrings("[ ]", closure_empty);
}

test "sort is stable, orders past the insertion-sort cutoff, and rethrows comparator errors" {
    const stable = try renderForTest(
        \\builtins.sort (a: b: a.k < b.k) [ { k = 1; v = 1; } { k = 0; v = 2; } { k = 1; v = 3; } { k = 0; v = 4; } ]
        \\  == [ { k = 0; v = 2; } { k = 0; v = 4; } { k = 1; v = 1; } { k = 1; v = 3; } ]
    );
    defer std_testing.allocator.free(stable);
    try std_testing.expectEqualStrings("true", stable);

    const big = try renderForTest(
        "builtins.sort (a: b: a < b) (builtins.genList (i: 63 - i) 64) == builtins.genList (i: i) 64",
    );
    defer std_testing.allocator.free(big);
    try std_testing.expectEqualStrings("true", big);

    try std_testing.expectError(error.NixThrow, renderForTest("builtins.sort (a: b: builtins.throw \"boom\") [ 3 1 2 ]"));
}

test "sort partition and groupBy reject non-list arguments" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.sort (a: b: a < b) 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.partition (x: x) 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.groupBy (x: \"k\") 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.genericClosure { startSet = 1; operator = item: [ ]; }"));
}

test "foldl' on an empty list returns the seed without calling the operator" {
    const result = try renderForTest("builtins.foldl' (a: b: builtins.throw \"boom\") 5 [ ]");
    defer std_testing.allocator.free(result);
    try std_testing.expectEqualStrings("5", result);
}
