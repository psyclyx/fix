const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;
const renderStrictForTest = @import("../test_helpers.zig").renderStrictForTest;

// Test vectors independently verified via `printf 'abc' | md5sum` /
// `printf 'abc' | sha512sum` rather than trusting self-consistency.

test "hashString md5 matches the independently-computed digest of \"abc\"" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("builtins.hashString \"md5\" \"abc\"");
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", ev.intern.get(result.asInternId()));
}

test "hashString sha512 matches the independently-computed digest of \"abc\"" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("builtins.hashString \"sha512\" \"abc\"");
    try std.testing.expectEqualStrings(
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
        ev.intern.get(result.asInternId()),
    );
}

test "hashString rejects an unsupported algorithm name" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(
        error.UnsupportedHashAlgorithm,
        ev.evaluate("builtins.hashString \"md4\" \"abc\""),
    );
}

test "hashString rejects a non-string argument" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.hashString \"sha256\" 1"));
}

test "convertHash converts between Nix's hash formats, as Nix does" {
    const got = try renderStrictForTest(
        \\let h = a: builtins.hashString a "abc"; in
        \\builtins.concatMap (a: map (f: builtins.convertHash { hash = h a; hashAlgo = a; toHashFormat = f; })
        \\  [ "base16" "nix32" "base32" "base64" "sri" ]) [ "md5" "sha1" "sha256" "sha512" ]
        \\++ [ (builtins.convertHash { hash = "sha1-qZk+NkcGgWq6PiVxeFDCbJzQ2J0="; toHashFormat = "nix32"; })
        \\  (builtins.convertHash { hash = "sha256:1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s"; toHashFormat = "base64"; }) ]
    );
    defer std.testing.allocator.free(got);
    // The output of CppNix 2.36.
    try std.testing.expectEqualStrings("[ \"900150983cd24fb0d6963f7d28e17f72\" \"3jgzhjhz9zjvbb0kyj7jc500ch\" \"3jgzhjhz9zjvbb0kyj7jc500ch\" \"kAFQmDzST7DWlj99KOF/cg==\" \"md5-kAFQmDzST7DWlj99KOF/cg==\" \"a9993e364706816aba3e25717850c26c9cd0d89d\" \"kpcd173cq987hw957sx6m0868wv3x6d9\" \"kpcd173cq987hw957sx6m0868wv3x6d9\" \"qZk+NkcGgWq6PiVxeFDCbJzQ2J0=\" \"sha1-qZk+NkcGgWq6PiVxeFDCbJzQ2J0=\" \"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\" \"1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s\" \"1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s\" \"ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=\" \"sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=\" \"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f\" \"2gs8k559z4rlahfx0y688s49m2vvszylcikrfinm30ly9rak69236nkam5ydvly1ai7xac99vxfc4ii84hawjbk876blyk1jfhkbbyx\" \"2gs8k559z4rlahfx0y688s49m2vvszylcikrfinm30ly9rak69236nkam5ydvly1ai7xac99vxfc4ii84hawjbk876blyk1jfhkbbyx\" \"3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw==\" \"sha512-3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw==\" \"kpcd173cq987hw957sx6m0868wv3x6d9\" \"ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=\" ]", got);

    for ([_][]const u8{
        "builtins.convertHash { hash = \"abc\"; toHashFormat = \"sri\"; }",
        "builtins.convertHash { hash = \"sha256-x\"; toHashFormat = \"sri\"; }",
        "builtins.convertHash { hash = \"sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=\"; toHashFormat = \"hex\"; }",
    }) |bad| try std.testing.expectError(error.InvalidHash, renderStrictForTest(bad));
}
