const std = @import("std");
const std_testing = std.testing;
const renderForTest = @import("../test_helpers.zig").renderForTest;

test "scopedImport rejects a non-attrs scope before touching the filesystem" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.scopedImport 1 /nonexistent-path-for-type-check.nix"));
}

// A search path that resolves to nothing is a language-level throw in Nix, so
// `tryEval` catches it — unlike reading a file that is genuinely absent, which
// is an I/O failure and propagates.
test "findFile throws when no search path entry matches" {
    try std_testing.expectError(error.NixThrow, renderForTest("builtins.findFile [ { prefix = \"pkg\"; path = /nonexistent-search-root; } ] \"other/target.nix\""));

    const caught = try renderForTest("(builtins.tryEval (builtins.findFile [ ] \"missing.nix\")).success");
    defer std_testing.allocator.free(caught);
    try std_testing.expectEqualStrings("false", caught);
}

test "findFile rejects a non-list search path" {
    try std_testing.expectError(error.TypeError, renderForTest("builtins.findFile 1 \"pkg/target.nix\""));
}
