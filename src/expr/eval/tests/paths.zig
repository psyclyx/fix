const std = @import("std");
const std_testing = std.testing;
const renderForTest = @import("../test_helpers.zig").renderForTest;
const Engine = @import("../../evaluator.zig").Engine;

/// Evaluate `source` as if it lived at `file_path` (relative path literals
/// resolve against the file's dir, like Nix), deep-force, render.
fn renderResolvedForTest(ev: *Engine, source: []const u8) ![]u8 {
    const result = try ev.evaluatePath(source, "/test/fold.nix");
    try ev.forceDeep(result);
    var out: std.Io.Writer.Allocating = .init(std_testing.allocator);
    defer out.deinit();
    try ev.writeValue(&out.writer, result);
    return out.toOwnedSlice();
}

test "non-interpolated path literals fold inside closed attrset and list literals" {
    // A path literal resolves at compile time (against the base path), so
    // path-bearing attrset/list literals are closed constants and fold
    // whole. The folded values must match what runtime construction would
    // produce.
    var ev = try Engine.init(std_testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try ev.setBasePathToFileDir("/test/fold.nix");

    const folded = try renderResolvedForTest(&ev, "{ rel = ./sub/file.nix; abs = /abs/dir; all = [ ./a.nix /b ]; }");
    defer std_testing.allocator.free(folded);
    try std_testing.expect(std.mem.indexOf(u8, folded, "rel = /test/sub/file.nix") != null);
    try std_testing.expect(std.mem.indexOf(u8, folded, "abs = /abs/dir") != null);
    try std_testing.expect(std.mem.indexOf(u8, folded, "all = [ /test/a.nix /b ]") != null);

    // Interpolated path literals are excluded from the fold but must still
    // resolve to the same path at runtime.
    const dynamic = try renderResolvedForTest(&ev, "let d = \"sub\"; in [ ./${d}/file.nix ]");
    defer std_testing.allocator.free(dynamic);
    try std_testing.expectEqualStrings("[ /test/sub/file.nix ]", dynamic);
}

test "a path after a non-string concat operand appends as text" {
    // Nix coerces `+` operands with copyToStore only when the first operand
    // is a string; an attrset-coerced left concatenates a trailing path as
    // its text, without realizing it.
    var ev = try Engine.init(std_testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const rendered = try renderResolvedForTest(&ev,
        \\[
        \\  ({ outPath = "/d"; } + /missing/sub)
        \\  ({ outPath = /d; } + /missing/sub)
        \\  ({ outPath = "/d"; } + "/str")
        \\  ("s" + ({ outPath = "/d"; } + /m1))
        \\]
    );
    defer std_testing.allocator.free(rendered);
    try std_testing.expectEqualStrings(
        \\[ "/d/missing/sub" "/d/missing/sub" "/d/str" "s/d/m1" ]
    , rendered);
}

test "baseNameOf and dirOf reject non-path non-string arguments" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.baseNameOf 1"));
    try std_testing.expectError(error.TypeError, renderForTest("builtins.dirOf 1"));
}

test "baseNameOf and dirOf preserve the string-ness of their argument" {
    const base_of_path_type = try renderForTest("builtins.typeOf (builtins.baseNameOf /foo/bar)");
    defer std_testing.allocator.free(base_of_path_type);
    try std_testing.expectEqualStrings("\"string\"", base_of_path_type);

    const dir_of_path_type = try renderForTest("builtins.typeOf (builtins.dirOf /foo/bar)");
    defer std_testing.allocator.free(dir_of_path_type);
    try std_testing.expectEqualStrings("\"path\"", dir_of_path_type);

    const dir_of_string_type = try renderForTest("builtins.typeOf (builtins.dirOf \"foo/bar\")");
    defer std_testing.allocator.free(dir_of_string_type);
    try std_testing.expectEqualStrings("\"string\"", dir_of_string_type);
}

test "storePath rejects relative paths" {
    try std_testing.expectError(error.RelativePath, renderForTest("builtins.storePath \"relative/path\""));
}

test "path builtin rejects a relative path attribute" {
    try std_testing.expectError(error.RelativePath, renderForTest("builtins.path { path = \"relative/path\"; }"));
}

test "path builtin rejects a non-string name attribute" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.path { path = /.; name = 1; }"));
}

test "placeholder hashes distinct output names to distinct values" {
    const out = try renderForTest("builtins.placeholder \"out\"");
    defer std_testing.allocator.free(out);
    const dev = try renderForTest("builtins.placeholder \"dev\"");
    defer std_testing.allocator.free(dev);
    try std_testing.expect(!std.mem.eql(u8, out, dev));

    // Deterministic given the same input.
    const out_again = try renderForTest("builtins.placeholder \"out\"");
    defer std_testing.allocator.free(out_again);
    try std_testing.expectEqualStrings(out, out_again);
}

test "a path literal may start with - or +" {
    var ev = try Engine.init(std_testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try ev.setBasePathToFileDir("/test/fold.nix");

    // `f -./x` applies `f` to a path, as in Nix; it is not a subtraction.
    const applied = try renderResolvedForTest(&ev, "let f = p: p; in [ (f -./x) (f +/y) (builtins.typeOf -/z) ]");
    defer std_testing.allocator.free(applied);
    try std_testing.expectEqualStrings("[ /test/-./x /test/+/y \"path\" ]", applied);
}
