const std = @import("std");
const Engine = @import("../../evaluator.zig").Engine;

test "getContext and hasContext expose a derivation's context on its string coercion" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const has_context = try ev.evaluate(
        \\let d = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\in builtins.hasContext (builtins.toString d)
    );
    try std.testing.expect(has_context.asBool());

    const no_context = try ev.evaluate("builtins.hasContext \"plain\"");
    try std.testing.expect(!no_context.asBool());
}

test "unsafeDiscardStringContext strips context so hasContext reports false" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate(
        \\let d = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\in builtins.hasContext (builtins.unsafeDiscardStringContext (builtins.toString d))
    );
    try std.testing.expect(!result.asBool());
}

test "appendContext adds a context entry that getContext can then observe" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate(
        \\builtins.hasContext (builtins.appendContext "x" {
        \\  "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a.drv" = { outputs = [ "out" ]; };
        \\})
    );
    try std.testing.expect(result.asBool());
}

test "addDrvOutputDependencies rewrites a drv path's context entry to depend on all outputs" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluate(
        \\let
        \\  dep = builtins.derivation { name = "dep"; outputs = [ "out" "bin" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  withDeps = builtins.addDrvOutputDependencies dep.drvPath;
        \\  ctx = builtins.getContext withDeps;
        \\in (builtins.getAttr (builtins.unsafeDiscardStringContext dep.drvPath) ctx).allOutputs
    );
    try std.testing.expect(result.asBool());
}

test "addDrvOutputDependencies rejects a non-string-like argument" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.addDrvOutputDependencies 1"));
}

test "appendContext rejects a non-attrs context argument" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.appendContext \"x\" 1"));
}

test "a string with context orders against a plain string" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const prelude =
        \\let d = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\    s = "${d}";
        \\in
    ;
    try std.testing.expect((try ev.evaluate(prelude ++ " s < \"z\"")).asBool());
    try std.testing.expect(!(try ev.evaluate(prelude ++ " \"z\" < s")).asBool());
    try std.testing.expect((try ev.evaluate(prelude ++ " builtins.lessThan \"/\" s")).asBool());
    try std.testing.expect((try ev.evaluate(prelude ++ " [ s ] < [ \"z\" ]")).asBool());
    try std.testing.expect((try ev.evaluate(prelude ++ " builtins.head (builtins.sort builtins.lessThan [ \"z\" s ]) == s")).asBool());
    // A path still only orders against a path.
    try std.testing.expectError(error.TypeError, ev.evaluate(prelude ++ " s < /z"));
}

test "split keeps the context of a string it does not split" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const prelude =
        \\let d = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\    s = "${d}";
        \\in
    ;
    // Nix returns the argument itself when nothing matches...
    try std.testing.expect((try ev.evaluate(prelude ++ " builtins.hasContext (builtins.head (builtins.split \"#\" s))")).asBool());
    try std.testing.expectEqual(@as(i64, 1), (try ev.evaluate(prelude ++ " builtins.length (builtins.split \"#\" s)")).asInt());
    // ...and builds context-free pieces around a match.
    try std.testing.expect(!(try ev.evaluate(prelude ++ " builtins.hasContext (builtins.head (builtins.split \"/\" s))")).asBool());
}

test "unsafeDiscardOutputDependency only turns all-outputs context into the .drv path" {
    const renderStrictForTest = @import("../test_helpers.zig").renderStrictForTest;
    const got = try renderStrictForTest(
        \\let
        \\  d = builtins.derivation { name = "d"; system = "x"; builder = "/b"; outputs = [ "out" "dev" ]; };
        \\  s = "${d.dev}${d.drvPath}";
        \\in [
        \\  (builtins.getContext (builtins.unsafeDiscardOutputDependency s))
        \\  (builtins.getContext (builtins.unsafeDiscardOutputDependency "${d}"))
        \\  (builtins.unsafeDiscardOutputDependency { outPath = "x"; })
        \\  (builtins.getContext (builtins.unsafeDiscardOutputDependency { __toString = _: d.drvPath; }))
        \\]
    );
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "[ { \"/nix/store/04s49lw7m6vgvdrrkq4iilvzfq7848vy-d.drv\" = { outputs = [ \"dev\" ]; path = true; }; } " ++
            "{ \"/nix/store/04s49lw7m6vgvdrrkq4iilvzfq7848vy-d.drv\" = { outputs = [ \"out\" ]; }; } " ++
            "\"x\" " ++
            "{ \"/nix/store/04s49lw7m6vgvdrrkq4iilvzfq7848vy-d.drv\" = { path = true; }; } ]",
        got,
    );
}

test "hasContext and appendContext take strings, not paths or sets" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.hasContext /x"));
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.hasContext { outPath = \"x\"; }"));
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.appendContext /x { }"));
    // Keys must be store paths, and output context needs a derivation.
    try std.testing.expectError(error.TypeError, ev.evaluate("builtins.appendContext \"a\" { a = { path = true; }; }"));
    try std.testing.expectError(error.TypeError, ev.evaluate(
        "builtins.appendContext \"a\" { \"/nix/store/04s49lw7m6vgvdrrkq4iilvzfq7848vy-d\" = { outputs = [ \"out\" ]; }; }",
    ));
    try std.testing.expectError(error.TypeError, ev.evaluate(
        "builtins.appendContext \"a\" { \"/nix/store/04s49lw7m6vgvdrrkq4iilvzfq7848vy-d\" = { allOutputs = true; }; }",
    ));
}

test "appendContext keeps only what an entry adds up to" {
    const renderStrictForTest = @import("../test_helpers.zig").renderStrictForTest;
    const got = try renderStrictForTest(
        \\let drv = "/nix/store/04s49lw7m6vgvdrrkq4iilvzfq7848vy-d.drv"; in [
        \\  (builtins.getContext (builtins.appendContext "a" { ${drv} = { outputs = [ "b" "a" "a" ]; path = false; }; }))
        \\  (builtins.getContext (builtins.appendContext "a" { ${drv} = { outputs = [ ]; path = false; }; }))
        \\  (builtins.hasContext (builtins.appendContext "a" { ${drv} = { }; }))
        \\]
    );
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "[ { \"/nix/store/04s49lw7m6vgvdrrkq4iilvzfq7848vy-d.drv\" = { outputs = [ \"a\" \"b\" ]; }; } { } false ]",
        got,
    );
}

test "names, patterns and versions may not refer to the store" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const prelude =
        \\let d = derivation { name = "d"; builder = "b"; system = "s"; }; s = "${d}"; in
    ;
    const cases = [_][]const u8{
        "{ ${s} = 1; }",
        "{ a = 1; }.${s} or 2",
        "{ a = 1; } ? ${s}",
        "builtins.getAttr s { }",
        "builtins.hasAttr s { }",
        "builtins.catAttrs s [ ]",
        "builtins.removeAttrs { } [ s ]",
        "builtins.listToAttrs [ { name = s; value = 1; } ]",
        "builtins.groupBy (x: s) [ 1 ]",
        "builtins.unsafeGetAttrPos s { }",
        "builtins.match s \"x\"",
        "builtins.split s \"x\"",
        "builtins.parseDrvName s",
        "builtins.splitVersion s",
        "builtins.compareVersions s \"1\"",
        "builtins.getEnv s",
        "builtins.placeholder s",
        "builtins.fromJSON \"\\\"${s}\\\"\"",
        "builtins.fromTOML \"a='${s}'\"",
        "builtins.hashString s \"x\"",
        "(derivation { name = \"x${s}\"; builder = \"b\"; system = \"s\"; }).drvPath",
        // Emptying the text keeps the context.
        "{ ${builtins.substring 0 0 s} = 1; }",
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s} {s}", .{ prelude, case });
        defer std.testing.allocator.free(source);
        _ = ev.evaluate(source) catch |err| {
            std.testing.expectEqual(error.StringContextNotAllowed, err) catch |e| {
                std.debug.print("case: {s}\n", .{case});
                return e;
            };
            continue;
        };
        std.debug.print("case: {s}\n", .{case});
        return error.TestExpectedError;
    }

    // The message names the first element of the context as Nix prints it.
    try std.testing.expectError(error.StringContextNotAllowed, ev.evaluate(prelude ++ " { ${\"a${d.drvPath}\"} = 1; }"));
    try std.testing.expectEqualStrings(
        "the string 'a/nix/store/9m3vsva6r393zgjc1g7ncynv7cvdx6sj-d.drv' is not allowed to refer to a store path (such as '/nix/store/9m3vsva6r393zgjc1g7ncynv7cvdx6sj-d.drv (deep)')",
        ev.getTrace().message.?,
    );
    try std.testing.expectError(error.StringContextNotAllowed, ev.evaluate(prelude ++ " builtins.getEnv s"));
    try std.testing.expectEqualStrings(
        "the string '/nix/store/82l07bidcfxgl7gmwsa4k2knxhf892s4-d' is not allowed to refer to a store path (such as '/nix/store/9m3vsva6r393zgjc1g7ncynv7cvdx6sj-d.drv^out')",
        ev.getTrace().message.?,
    );

    // Without its context the same text is an ordinary name.
    const plain = try ev.evaluate(prelude ++ " let n = builtins.unsafeDiscardStringContext s; in builtins.getAttr n { ${n} = 1; }");
    try std.testing.expectEqual(@as(i64, 1), plain.asInt());
}
