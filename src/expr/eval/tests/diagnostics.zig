const std = @import("std");
const eval_mod = @import("../../evaluator.zig");
const Engine = eval_mod.Engine;
const Diagnostic = eval_mod.Diagnostic;
const policy_mod = @import("../../policy.zig");

test "successful evaluation retains unsilenced parser deprecations" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    _ = try ev.evaluate(".5");
    const warnings = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), warnings.len);
    try std.testing.expectEqual(Diagnostic.Severity.warning, warnings[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.parse, warnings[0].kind);
    try std.testing.expectEqual(@as(u32, 0), warnings[0].offset);
    try std.testing.expectEqualStrings(
        "floating point literal without a leading zero; use --extra-deprecated-features floating-without-zero to silence this warning",
        warnings[0].message,
    );

    var policy: policy_mod.LanguagePolicy = .{};
    policy.applyFeatureSets(.empty, .initOne(.floating_without_zero));
    ev.configureLanguage(policy);
    _ = try ev.evaluate(".5");
    try std.testing.expectEqual(@as(usize, 0), ev.getDiagnostics().len);
}

test "evaluate exposes parse diagnostics without printing" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("$ $ 1"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqualStrings("Invalid token.", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 0), diagnostics[0].offset);
    try std.testing.expectEqual(@as(u32, 1), diagnostics[0].column);
    try std.testing.expectEqualStrings("Invalid token.", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].offset);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[1].column);
}

test "evaluate exposes duplicate binding diagnostics" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("let x = 1; x = 2; in x"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.parse, diagnostics[0].kind);
    try std.testing.expectEqualStrings("variable 'x' already defined", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 11), diagnostics[0].offset);
    try std.testing.expectEqual(Diagnostic.Severity.note, diagnostics[1].severity);
    try std.testing.expectEqualStrings("first binding defined here", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 4), diagnostics[1].offset);
}

test "evaluate exposes duplicate attribute diagnostics" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("{ a = 1; a = 2; }"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 2), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.parse, diagnostics[0].kind);
    try std.testing.expectEqualStrings("attribute 'a' already defined", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 9), diagnostics[0].offset);
    try std.testing.expectEqual(Diagnostic.Severity.note, diagnostics[1].severity);
    try std.testing.expectEqualStrings("first attribute defined here", diagnostics[1].message);
    try std.testing.expectEqual(@as(u32, 2), diagnostics[1].offset);
}

test "evaluate exposes undefined variable diagnostics" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.UndefinedVariable, ev.evaluate("let y = x; in y"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Severity.err, diagnostics[0].severity);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("undefined variable 'x'", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 8), diagnostics[0].offset);
    try std.testing.expectEqual(@as(u32, 9), diagnostics[0].column);
}

test "evaluate exposes invalid numeric literal diagnostics" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.InvalidNumber, ev.evaluate("9223372036854775808"));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(Diagnostic.Kind.compile, diagnostics[0].kind);
    try std.testing.expectEqualStrings("invalid integer literal", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 0), diagnostics[0].offset);
}

test "evaluate exposes interpolation parse diagnostics" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.ParseError, ev.evaluate("\"${$}\""));
    const diagnostics = ev.getDiagnostics();
    try std.testing.expect(diagnostics.len >= 1);
    try std.testing.expectEqual(Diagnostic.Kind.parse, diagnostics[0].kind);
    try std.testing.expectEqualStrings("Invalid token.", diagnostics[0].message);
    try std.testing.expectEqual(@as(u32, 3), diagnostics[0].offset);
    try std.testing.expectEqual(@as(u32, 4), diagnostics[0].column);
}

test "evaluate records runtime error message and expression trace" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.TypeError, ev.evaluate("let y = 1 + \"x\"; in y"));

    const trace = ev.getTrace();
    try std.testing.expect(trace.message != null);
    try std.testing.expectEqualStrings("cannot coerce int to a string", trace.message.?);
    // `y` is strictly used by the body, so it is eagerly evaluated into
    // its slot (no binding thunk) — the trace points straight at the
    // erroring RHS `1 + "x"` (col 9) without an extra "while evaluating
    // y" thunk-force wrapper frame. See strictness-driven let elision in
    // compiler/fold.zig.
    try std.testing.expect(trace.frames.items.len >= 1);
    try std.testing.expectEqual(.evaluation, trace.frames.items[0].kind);
    try std.testing.expect(trace.frames.items[0].diagnostic != null);
    try std.testing.expect(trace.frames.items[0].source_path == null);
    try std.testing.expectEqualStrings("while evaluating", trace.frames.items[0].message);
    try std.testing.expectEqual(@as(u32, 1), trace.frames.items[0].diagnostic.?.line);
    try std.testing.expectEqual(@as(u32, 9), trace.frames.items[0].diagnostic.?.column);
}

test "evaluate records imported file source trace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "boom.nix", .data = "let y = 1 + \"x\"; in y\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "boom.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "import {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    try std.testing.expectError(error.TypeError, ev.evaluate(source));

    const trace = ev.getTrace();
    try std.testing.expect(trace.message != null);
    try std.testing.expectEqualStrings("cannot coerce int to a string", trace.message.?);
    try std.testing.expect(trace.frames.items.len >= 1);
    try std.testing.expectEqual(.evaluation, trace.frames.items[0].kind);
    try std.testing.expect(trace.frames.items[0].diagnostic != null);
    try std.testing.expect(trace.frames.items[0].source_path != null);
    try std.testing.expectEqualStrings(file_path, trace.frames.items[0].source_path.?);
    try std.testing.expectEqual(@as(u32, 1), trace.frames.items[0].diagnostic.?.line);
    try std.testing.expectEqual(@as(u32, 9), trace.frames.items[0].diagnostic.?.column);
}

test "cached import failures retain their original diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cached-failure.nix",
        .data = "builtins.throw \"cached import failure\"\n",
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "cached-failure.nix",
    });
    defer std.testing.allocator.free(file_path);
    const source = try std.fmt.allocPrint(std.testing.allocator, "import {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 8 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    // The second evaluation observes ImportEntry's terminal failure rather
    // than evaluating the imported file again. Both observations must expose
    // the same Nix message and imported origin, not the Zig error-set name.
    for (0..2) |_| {
        try std.testing.expectError(error.NixThrow, ev.evaluate(source));
        const trace = ev.getTrace();
        try std.testing.expectEqualStrings("cached import failure", trace.message.?);
        var found_import_origin = false;
        for (trace.frames.items) |frame| {
            if (frame.source_path) |path| {
                if (std.mem.eql(u8, path, file_path)) found_import_origin = true;
            }
        }
        try std.testing.expect(found_import_origin);
    }
}

test "attrset pattern errors name the argument" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    try std.testing.expectError(error.MissingAttribute, ev.evaluate("({ x, y }: x) { x = 1; }"));
    try std.testing.expectEqualStrings("function called without required argument 'y'", ev.getTrace().message.?);

    try std.testing.expectError(error.UnexpectedAttribute, ev.evaluate("({ x }: x) { x = 1; z = 2; }"));
    try std.testing.expectEqualStrings("function called with unexpected argument 'z'", ev.getTrace().message.?);
}
