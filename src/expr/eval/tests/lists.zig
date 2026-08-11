const std = @import("std");
const std_testing = std.testing;
const renderForTest = @import("../test_helpers.zig").renderForTest;
const Engine = @import("../../evaluator.zig").Engine;

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

test "an accumulating foldl' reclaims its intermediates" {
    // Regression (evalbench string_concat / concat_sep_fold, both OutOfMemory):
    // `builtinFoldlStrict` opened ONE root scope around the whole loop and
    // called `rootKeep(acc)` per iteration. `rootKeep` only appends, so every
    // intermediate accumulator stayed a GC root for the entire fold and the
    // byte store grew as O(n^2) until its u32 id space (~4 GiB) ran out.
    //
    // Two more links had to hold for the reclaim to happen at all: the loop
    // must reach a GC safepoint (the strict fan-out resolves the list up
    // front, so nothing in the loop enters `forceThunkImpl`), and the byte
    // store must defend its own ceiling rather than the RAM-derived line
    // sitting above it.
    //
    // 30000 steps of a 1-byte-per-step fold allocate ~560 MB of intermediate
    // text; only the last 30 KB is live.
    var ev = try Engine.init(std_testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.configureMemory(4 << 20, null, false); // tiny budget: collect early

    const result = try ev.evaluate(
        "builtins.stringLength (builtins.foldl' (a: b: a + b) \"\" (builtins.genList (i: \"x\") 30000))",
    );
    var out: std.Io.Writer.Allocating = .init(std_testing.allocator);
    defer out.deinit();
    try ev.writeValue(&out.writer, result);
    try std_testing.expectEqualStrings("30000", out.written());

    // ~197 MB reclaiming; 565 MB with the intermediates pinned (identical to
    // `--gc-budget 0`, since before the fix collection freed none of them).
    try std_testing.expect(ev.heap.counts().bytes < 400 << 20);
}
