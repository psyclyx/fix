const std = @import("std");
const eval_mod = @import("../../evaluator.zig");
const Engine = eval_mod.Engine;
const Diagnostic = eval_mod.Diagnostic;
const Value = @import("runtime").value.Value;
const FileCache = @import("store").FileCache;
const RealizationStore = @import("store").RealizationStore;
const path_ops = @import("runtime").paths;
const helpers = @import("../test_helpers.zig");
const renderForTest = helpers.renderForTest;
const renderWithFetchTree = helpers.renderWithFetchTree;
const renderWithFlakes = helpers.renderWithFlakes;
const renderStrictForTest = helpers.renderStrictForTest;
const renderForTestFromCurrentPath = helpers.renderForTestFromCurrentPath;
const renderXmlForTest = helpers.renderXmlForTest;

test "evaluate pathExists and readFile builtins through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.txt", .data = "abc\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "input.txt",
    });
    defer std.testing.allocator.free(file_path);

    const exists_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.pathExists \"{s}\"", .{file_path});
    defer std.testing.allocator.free(exists_source);
    const read_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile \"{s}\"", .{file_path});
    defer std.testing.allocator.free(read_source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const exists = try ev.evaluate(exists_source);
    try std.testing.expect(exists.asBool());

    const contents = try ev.evaluate(read_source);
    try std.testing.expectEqualStrings("abc\n", ev.intern.get(contents.asInternId()));

    const reread = try ev.evaluate(read_source);
    try std.testing.expectEqual(contents.asInternId(), reread.asInternId());
}

test "read source files through evaluator file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.nix", .data = "1 + 2\n" });

    const relative_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/source.nix", .{tmp.sub_path});
    defer std.testing.allocator.free(relative_path);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try ev.setBasePathFromCurrentPath(std.testing.io);

    const source = try ev.readSourceFile(relative_path);
    try std.testing.expectEqualStrings("1 + 2\n", source);

    const cached_source = try ev.readSourceFile(relative_path);
    try std.testing.expectEqual(@intFromPtr(source.ptr), @intFromPtr(cached_source.ptr));
}

test "evaluate readDir builtin through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "sub", .default_dir);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(dir_path);

    const file_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.getAttr \"file.txt\" (builtins.readDir {s})", .{dir_path});
    defer std.testing.allocator.free(file_source);
    const dir_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.readDir {s}).sub", .{dir_path});
    defer std.testing.allocator.free(dir_source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const file_kind = try ev.evaluate(file_source);
    try std.testing.expectEqualStrings("regular", ev.intern.get(file_kind.asInternId()));

    const dir_kind = try ev.evaluate(dir_source);
    try std.testing.expectEqualStrings("directory", ev.intern.get(dir_kind.asInternId()));
}

test "evaluate readFileType builtin through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "sub", .default_dir);

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);

    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "file.txt" });
    defer std.testing.allocator.free(file_path);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "sub" });
    defer std.testing.allocator.free(dir_path);

    const file_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFileType {s}", .{file_path});
    defer std.testing.allocator.free(file_source);
    const dir_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFileType {s}", .{dir_path});
    defer std.testing.allocator.free(dir_source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const file_kind = try ev.evaluate(file_source);
    try std.testing.expectEqualStrings("regular", ev.intern.get(file_kind.asInternId()));

    const dir_kind = try ev.evaluate(dir_source);
    try std.testing.expectEqualStrings("directory", ev.intern.get(dir_kind.asInternId()));
}

test "evaluate filterSource builtin through file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keep.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "keepdir", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keepdir/nested.txt", .data = "x" });
    try tmp.dir.createDir(std.testing.io, "skip", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "skip/boom.txt", .data = "x" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(dir_path);

    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\builtins.filterSource
        \\  (path: type:
        \\    if builtins.baseNameOf path == "boom.txt"
        \\    then builtins.throw "descended into rejected directory"
        \\    else builtins.baseNameOf path != "skip")
        \\  {s}
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const filtered = try ev.evaluate(source);
    try std.testing.expectEqual(.string_context, filtered.kind());
    const filtered_string = try ev.heap.getContextString(filtered.asObjectId());
    const filtered_path = ev.intern.get(filtered_string.text);
    try std.testing.expect(std.mem.startsWith(u8, filtered_path, "/nix/store/"));
    try std.testing.expect(std.mem.endsWith(u8, filtered_path, &tmp.sub_path));
    try std.testing.expectEqual(@as(usize, 1), filtered_string.context.len());
    try std.testing.expectEqual(filtered_string.text, filtered_string.context.names[0]);

    ev.setDerivationDebug(true);
    const drv_source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\let
        \\  src = builtins.filterSource
        \\    (path: type:
        \\      if builtins.baseNameOf path == "boom.txt"
        \\      then builtins.throw "descended into rejected directory"
        \\      else builtins.baseNameOf path != "skip")
        \\    {s};
        \\in (builtins.derivation {{
        \\  name = "uses-filter-source";
        \\  system = "x86_64-linux";
        \\  builder = "/bin/sh";
        \\  preHook = src;
        \\}}).drvPath
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(drv_source);
    _ = try ev.evaluate(drv_source);
    const records = ev.derivationDebugRecords();
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqual(@as(usize, 1), records[0].input_srcs.len);
    try std.testing.expectEqualStrings(filtered_path, records[0].input_srcs[0]);

    const called_source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\builtins.filterSource
        \\  (path: type:
        \\    if builtins.baseNameOf path == "keep.txt"
        \\    then builtins.throw "predicate called"
        \\    else true)
        \\  {s}
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(called_source);
    try std.testing.expectError(error.NixThrow, ev.evaluate(called_source));

    const path_filter_called_source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\builtins.path {{
        \\  path = {s};
        \\  name = "filtered-source";
        \\  filter = path: type:
        \\    if builtins.baseNameOf path == "keep.txt"
        \\    then builtins.throw "predicate called"
        \\    else true;
        \\}}
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(path_filter_called_source);
    try std.testing.expectError(error.NixThrow, ev.evaluate(path_filter_called_source));

    const path_filter_source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\builtins.path {{
        \\  path = {s};
        \\  name = "filtered-source";
        \\  filter = path: type:
        \\    if builtins.baseNameOf path == "boom.txt"
        \\    then builtins.throw "descended into rejected directory"
        \\    else builtins.baseNameOf path != "skip";
        \\}}
    ,
        .{dir_path},
    );
    defer std.testing.allocator.free(path_filter_source);
    const filtered_path_value = try ev.evaluate(path_filter_source);
    try std.testing.expectEqual(.string_context, filtered_path_value.kind());
    const filtered_path_string = try ev.heap.getContextString(filtered_path_value.asObjectId());
    const builtins_path_filtered_path = ev.intern.get(filtered_path_string.text);
    try std.testing.expect(std.mem.startsWith(u8, builtins_path_filtered_path, "/nix/store/"));
    try std.testing.expect(std.mem.endsWith(u8, builtins_path_filtered_path, "-filtered-source"));
}

test "evaluate fetchGit builtin for local repository" {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const out_path_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.fetchGit {{ url = \"{s}\"; }}).outPath", .{cwd});
    defer std.testing.allocator.free(out_path_source);
    const short_rev_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.stringLength (builtins.fetchGit {{ url = \"{s}\"; }}).shortRev", .{cwd});
    defer std.testing.allocator.free(short_rev_source);
    const untracked_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.hasAttr \".zig-cache\" (builtins.readDir (builtins.fetchGit {{ url = \"{s}\"; }}).outPath)", .{cwd});
    defer std.testing.allocator.free(untracked_source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const out_path = try ev.evaluate(out_path_source);
    const fetched_path = ev.intern.get(out_path.asInternId());
    try std.testing.expect(!std.mem.eql(u8, cwd, fetched_path));
    try std.testing.expect(std.mem.indexOf(u8, fetched_path, "/git-local/") != null);

    const short_rev_len = try ev.evaluate(short_rev_source);
    try std.testing.expectEqual(@as(i64, 7), short_rev_len.asInt());
    const includes_untracked = try ev.evaluate(untracked_source);
    try std.testing.expect(!includes_untracked.asBool());
}

test "fetchGit and fetchTree follow Nix's shallow defaults for revCount" {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.fetch_tree_enabled = true;

    const cases = [_]struct { args: []const u8, has_rev_count: bool }{
        .{ .args = "builtins.fetchGit {{ url = \"{s}\"; }}", .has_rev_count = true },
        .{ .args = "builtins.fetchGit {{ url = \"{s}\"; shallow = true; }}", .has_rev_count = true },
        .{ .args = "builtins.fetchTree {{ type = \"git\"; url = \"{s}\"; }}", .has_rev_count = false },
        .{ .args = "builtins.fetchTree {{ type = \"git\"; url = \"{s}\"; shallow = false; }}", .has_rev_count = true },
    };
    inline for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.hasAttr \"revCount\" (" ++ case.args ++ ")", .{cwd});
        defer std.testing.allocator.free(source);
        const has = try ev.evaluate(source);
        try std.testing.expectEqual(case.has_rev_count, has.asBool());
    }

    // The legacy builtin backfills revCount for a shallow fetch, as 0.
    const zero_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.fetchGit {{ url = \"{s}\"; shallow = true; }}).revCount", .{cwd});
    defer std.testing.allocator.free(zero_source);
    const zero = try ev.evaluate(zero_source);
    try std.testing.expectEqual(@as(i64, 0), zero.asInt());
}

test "evaluate fetchurl builtin through fetch cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "payload.txt",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile (builtins.fetchurl {{ url = \"file://{s}\"; name = \"payload.txt\"; }})", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const contents = try ev.evaluate(source);
    try std.testing.expectEqualStrings("payload", ev.intern.get(contents.asInternId()));
}

test "evaluate fetchTarball builtin through fetch cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "archive-root", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "archive-root/file.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);
    const archive_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "archive.tar.gz" });
    defer std.testing.allocator.free(archive_path);

    const tar = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "tar", "-czf", archive_path, "-C", base_path, "archive-root" },
    });
    defer std.testing.allocator.free(tar.stdout);
    defer std.testing.allocator.free(tar.stderr);
    switch (tar.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTarFailure,
    }

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile ((builtins.fetchTarball {{ url = \"file://{s}\"; name = \"src\"; }}) + \"/file.txt\")", .{archive_path});
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const contents = try ev.evaluate(source);
    try std.testing.expectEqualStrings("payload", ev.intern.get(contents.asInternId()));
}

test "hashed fetchurl reads content with the specified sha256" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "payload.txt" });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "builtins.readFile (builtins.fetchurl {{ url = \"file://{s}\"; name = \"payload.txt\"; sha256 = \"239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5\"; }})",
        .{file_path},
    );
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const contents = try ev.evaluate(source);
    try std.testing.expectEqualStrings("payload", ev.intern.get(contents.asInternId()));
}

test "hashed fetchurl reports mismatched and malformed sha256" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "payload.txt" });
    defer std.testing.allocator.free(file_path);

    const malformed_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "builtins.readFile (builtins.fetchurl {{ url = \"file://{s}\"; name = \"payload.txt\"; sha256 = \"sha256-not-a-hash\"; }})",
        .{file_path},
    );
    defer std.testing.allocator.free(malformed_source);
    var malformed_ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer malformed_ev.deinit();
    malformed_ev.setFileIo(std.testing.io);
    try std.testing.expectError(error.InvalidHash, malformed_ev.evaluate(malformed_source));
    try std.testing.expect(malformed_ev.getTrace().message != null);

    const mismatch_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "builtins.readFile (builtins.fetchurl {{ url = \"file://{s}\"; name = \"payload.txt\"; sha256 = \"0000000000000000000000000000000000000000000000000000000000000000\"; }})",
        .{file_path},
    );
    defer std.testing.allocator.free(mismatch_source);
    var mismatch_ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer mismatch_ev.deinit();
    mismatch_ev.setFileIo(std.testing.io);
    try std.testing.expectError(error.HashMismatch, mismatch_ev.evaluate(mismatch_source));
    const mismatch_message = mismatch_ev.getTrace().message orelse return error.MissingHashDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, mismatch_message, "0000000000000000000000000000000000000000000000000000000000000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, mismatch_message, "239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5") != null);
}

test "hashed fetchTarball reads a subpath with the specified sha256" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "archive-root", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "archive-root/file.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);
    const archive_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "archive.tar.gz" });
    defer std.testing.allocator.free(archive_path);

    const tar = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "tar", "-czf", archive_path, "-C", base_path, "archive-root" } });
    defer std.testing.allocator.free(tar.stdout);
    defer std.testing.allocator.free(tar.stderr);
    switch (tar.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTarFailure,
    }

    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "builtins.readFile ((builtins.fetchTarball {{ url = \"file://{s}\"; name = \"src\"; sha256 = \"e7836a3c011cee6b24037385323b9883d4657e2fb7c44bc18b6c166eac5555d0\"; }}) + \"/file.txt\")",
        .{archive_path},
    );
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    const contents = try ev.evaluate(source);
    try std.testing.expectEqualStrings("payload", ev.intern.get(contents.asInternId()));
}

test "hashed fetchTarball reports mismatched and malformed sha256" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "archive-root", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "archive-root/file.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(base_path);
    const archive_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "archive.tar.gz" });
    defer std.testing.allocator.free(archive_path);
    const tar = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "tar", "-czf", archive_path, "-C", base_path, "archive-root" } });
    defer std.testing.allocator.free(tar.stdout);
    defer std.testing.allocator.free(tar.stderr);
    switch (tar.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTarFailure,
    }

    const malformed_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "builtins.readFile ((builtins.fetchTarball {{ url = \"file://{s}\"; name = \"src\"; sha256 = \"sha256-not-a-hash\"; }}) + \"/file.txt\")",
        .{archive_path},
    );
    defer std.testing.allocator.free(malformed_source);
    var malformed_ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer malformed_ev.deinit();
    malformed_ev.setFileIo(std.testing.io);
    try std.testing.expectError(error.InvalidHash, malformed_ev.evaluate(malformed_source));
    try std.testing.expect(malformed_ev.getTrace().message != null);

    const mismatch_source = try std.fmt.allocPrint(
        std.testing.allocator,
        "builtins.readFile ((builtins.fetchTarball {{ url = \"file://{s}\"; name = \"src\"; sha256 = \"0000000000000000000000000000000000000000000000000000000000000000\"; }}) + \"/file.txt\")",
        .{archive_path},
    );
    defer std.testing.allocator.free(mismatch_source);
    var mismatch_ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer mismatch_ev.deinit();
    mismatch_ev.setFileIo(std.testing.io);
    try std.testing.expectError(error.HashMismatch, mismatch_ev.evaluate(mismatch_source));
    const mismatch_message = mismatch_ev.getTrace().message orelse return error.MissingHashDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, mismatch_message, "0000000000000000000000000000000000000000000000000000000000000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, mismatch_message, "e7836a3c011cee6b24037385323b9883d4657e2fb7c44bc18b6c166eac5555d0") != null);
}

test "evaluate fetchTree builtin through fetch cache" {
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "payload" });

    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "payload.txt",
    });
    defer std.testing.allocator.free(file_path);

    const path_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.fetchTree {{ type = \"path\"; path = \"{s}\"; }}).outPath", .{cwd});
    defer std.testing.allocator.free(path_source);
    const file_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile (builtins.fetchTree {{ type = \"file\"; url = \"file://{s}\"; }}).outPath", .{file_path});
    defer std.testing.allocator.free(file_source);
    const git_source = try std.fmt.allocPrint(std.testing.allocator, "builtins.stringLength (builtins.fetchTree {{ type = \"git\"; url = \"{s}\"; }}).shortRev", .{cwd});
    defer std.testing.allocator.free(git_source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.fetch_tree_enabled = true;

    const out_path = try ev.evaluate(path_source);
    try std.testing.expectEqualStrings(cwd, ev.intern.get(out_path.asInternId()));

    const contents = try ev.evaluate(file_source);
    try std.testing.expectEqualStrings("payload", ev.intern.get(contents.asInternId()));

    const short_rev_len = try ev.evaluate(git_source);
    try std.testing.expectEqual(@as(i64, 7), short_rev_len.asInt());
}

test "evaluate flake ref builtins" {
    const github = try renderWithFlakes("builtins.toJSON (builtins.parseFlakeRef \"github:NixOS/nixpkgs/nixos-unstable\")");
    defer std.testing.allocator.free(github);
    try std.testing.expectEqualStrings("\"{\\\"owner\\\":\\\"NixOS\\\",\\\"ref\\\":\\\"nixos-unstable\\\",\\\"repo\\\":\\\"nixpkgs\\\",\\\"type\\\":\\\"github\\\"}\"", github);

    const path = try renderWithFlakes("builtins.toJSON (builtins.parseFlakeRef \"path:/tmp/source?rev=abc&narHash=sha256-test\")");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("\"{\\\"narHash\\\":\\\"sha256-test\\\",\\\"path\\\":\\\"/tmp/source\\\",\\\"rev\\\":\\\"abc\\\",\\\"type\\\":\\\"path\\\"}\"", path);

    const stringified = try renderWithFlakes("builtins.flakeRefToString { type = \"github\"; owner = \"NixOS\"; repo = \"nixpkgs\"; ref = \"nixos-unstable\"; }");
    defer std.testing.allocator.free(stringified);
    try std.testing.expectEqualStrings("\"github:NixOS/nixpkgs/nixos-unstable\"", stringified);
}

test "parseFlakeRef handles github refs without a branch and bare absolute paths" {
    const github_no_ref = try renderWithFlakes("builtins.toJSON (builtins.parseFlakeRef \"github:NixOS/nixpkgs\")");
    defer std.testing.allocator.free(github_no_ref);
    try std.testing.expectEqualStrings("\"{\\\"owner\\\":\\\"NixOS\\\",\\\"repo\\\":\\\"nixpkgs\\\",\\\"type\\\":\\\"github\\\"}\"", github_no_ref);

    const path_no_query = try renderWithFlakes("builtins.toJSON (builtins.parseFlakeRef \"path:/tmp/source\")");
    defer std.testing.allocator.free(path_no_query);
    try std.testing.expectEqualStrings("\"{\\\"path\\\":\\\"/tmp/source\\\",\\\"type\\\":\\\"path\\\"}\"", path_no_query);

    const bare_absolute_path = try renderWithFlakes("builtins.toJSON (builtins.parseFlakeRef \"/tmp/source\")");
    defer std.testing.allocator.free(bare_absolute_path);
    try std.testing.expectEqualStrings("\"{\\\"path\\\":\\\"/tmp/source\\\",\\\"type\\\":\\\"path\\\"}\"", bare_absolute_path);
}

test "parseFlakeRef rejects malformed refs" {
    try std.testing.expectError(error.InvalidFlakeRef, renderWithFlakes("builtins.parseFlakeRef \"github:NixOS\""));
    try std.testing.expectError(error.InvalidFlakeRef, renderWithFlakes("builtins.parseFlakeRef \"relative/path\""));
    try std.testing.expectError(error.InvalidFlakeRef, renderWithFlakes("builtins.parseFlakeRef \"\""));
}

test "flakeRefToString serializes each ref type and its query params" {
    const cases = [_]struct { expr: []const u8, want: []const u8 }{
        .{ .expr = "{ type = \"path\"; path = \"/tmp/source\"; }", .want = "\"path:/tmp/source\"" },
        .{ .expr = "{ type = \"path\"; path = \"/tmp/source\"; rev = \"abc\"; narHash = \"sha256-test\"; }", .want = "\"path:/tmp/source?rev=abc&narHash=sha256-test\"" },
        // `rev` is preferred over `ref` in the forge path segment (pin fidelity).
        .{ .expr = "{ type = \"github\"; owner = \"NixOS\"; repo = \"nixpkgs\"; rev = \"deadbeef\"; ref = \"main\"; }", .want = "\"github:NixOS/nixpkgs/deadbeef\"" },
        .{ .expr = "{ type = \"github\"; owner = \"NixOS\"; repo = \"nixpkgs\"; ref = \"main\"; dir = \"sub\"; }", .want = "\"github:NixOS/nixpkgs/main?dir=sub\"" },
        .{ .expr = "{ type = \"gitlab\"; owner = \"foo\"; repo = \"bar\"; }", .want = "\"gitlab:foo/bar\"" },
        .{ .expr = "{ type = \"git\"; url = \"https://example.com/repo\"; ref = \"main\"; }", .want = "\"git+https://example.com/repo?ref=main\"" },
        // A bare http(s) URL round-trips as a tarball with no `tarball+` prefix.
        .{ .expr = "{ type = \"tarball\"; url = \"https://example.com/x.tar.gz\"; }", .want = "\"https://example.com/x.tar.gz\"" },
    };
    for (cases) |c| {
        const expr = try std.fmt.allocPrint(std.testing.allocator, "builtins.flakeRefToString {s}", .{c.expr});
        defer std.testing.allocator.free(expr);
        const got = try renderWithFlakes(expr);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }

    try std.testing.expectError(
        error.MissingAttribute,
        renderWithFlakes("builtins.flakeRefToString { type = \"github\"; owner = \"NixOS\"; }"),
    );
    try std.testing.expectError(error.TypeError, renderWithFlakes("builtins.flakeRefToString \"github:NixOS/nixpkgs\""));
}

test "fetchTree rejects unrecognized or non-attrset input without touching the network" {
    try std.testing.expectError(
        error.InvalidFlakeRef,
        renderWithFetchTree("builtins.fetchTree { type = \"bogus\"; }"),
    );
    try std.testing.expectError(error.TypeError, renderWithFetchTree("builtins.fetchTree 1"));
    try std.testing.expectError(error.MissingAttribute, renderWithFetchTree("builtins.fetchTree { }"));
}

test "fetchTree is gated on the fetch-tree experimental feature" {
    // Without the feature the builtin errors before touching its argument.
    try std.testing.expectError(
        error.MissingExperimentalFeature,
        renderForTest("builtins.fetchTree { type = \"path\"; path = \"/nonexistent\"; }"),
    );
    // A hard error like Nix: tryEval does not catch it, so the whole
    // evaluation fails rather than resolving to `{ success = false; }`.
    try std.testing.expectError(
        error.MissingExperimentalFeature,
        renderForTest("(builtins.tryEval (builtins.fetchTree { type = \"path\"; path = \"/x\"; })).success"),
    );
    // getFlake reaches the fetcher directly, so it is unaffected by the gate;
    // exercised by the "evaluate getFlake builtin for local path ref" test.
}

test "evaluate getFlake builtin for local path ref" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "flake.nix",
        .data =
        \\{
        \\  outputs = inputs: {
        \\    value = 7;
        \\    source = inputs.self.outPath;
        \\  };
        \\}
        ,
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const flake_dir = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(flake_dir);

    const value_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").value", .{flake_dir});
    defer std.testing.allocator.free(value_source);
    const output_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").outputs.value", .{flake_dir});
    defer std.testing.allocator.free(output_source);
    const self_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").source", .{flake_dir});
    defer std.testing.allocator.free(self_source);
    const modified_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").lastModified", .{flake_dir});
    defer std.testing.allocator.free(modified_source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.flakes_enabled = true;

    try std.testing.expectEqual(@as(i64, 7), (try ev.evaluate(value_source)).asInt());
    try std.testing.expectEqual(@as(i64, 7), (try ev.evaluate(output_source)).asInt());
    const self_path = try ev.evaluate(self_source);
    try std.testing.expectEqualStrings(flake_dir, ev.intern.get(self_path.asInternId()));
    // A local path flake's `lastModified` is the tree's mtime (the dir was
    // just written), not the hardcoded epoch — nixpkgs derives its version
    // suffix from this.
    try std.testing.expect((try ev.evaluate(modified_source)).asInt() > 0);
}

test "getFlake ties self into the outputs fixpoint" {
    // `self` must reference the flake's own outputs (self.packages, self.lib,
    // …), not just the source-info fields — the fixpoint back-edge.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "flake.nix",
        .data =
        \\{
        \\  outputs = { self, ... }: {
        \\    base = 21;
        \\    doubled = self.base * 2;
        \\    packages.x = self.base + 1;
        \\    viaOutputs = self.outputs.base;
        \\    selfPath = self.outPath;
        \\    viaSourceInfo = self.sourceInfo.outPath;
        \\  };
        \\}
        ,
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const flake_dir = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(flake_dir);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.flakes_enabled = true;

    const doubled = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").doubled", .{flake_dir});
    defer std.testing.allocator.free(doubled);
    const pkg = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").packages.x", .{flake_dir});
    defer std.testing.allocator.free(pkg);
    const via = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").viaOutputs", .{flake_dir});
    defer std.testing.allocator.free(via);
    const self_path = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").selfPath", .{flake_dir});
    defer std.testing.allocator.free(self_path);
    const via_source = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").viaSourceInfo", .{flake_dir});
    defer std.testing.allocator.free(via_source);

    try std.testing.expectEqual(@as(i64, 42), (try ev.evaluate(doubled)).asInt());
    try std.testing.expectEqual(@as(i64, 22), (try ev.evaluate(pkg)).asInt());
    try std.testing.expectEqual(@as(i64, 21), (try ev.evaluate(via)).asInt());
    // `self.outPath` is the flake's source path, and `self.sourceInfo.outPath`
    // is the same value — both reachable through the fixpoint.
    try std.testing.expectEqualStrings(flake_dir, ev.intern.get((try ev.evaluate(self_path)).asInternId()));
    try std.testing.expectEqualStrings(flake_dir, ev.intern.get((try ev.evaluate(via_source)).asInternId()));
}

test "getFlake resolves inputs from flake.lock (transitive + follows + diamond)" {
    // Three flakes: c (leaf), b (input c via a follows path), root (inputs b + c).
    // Exercises transitive resolution, `follows` arrays, and diamond memoization
    // (c is shared by root and b, fetched once).
    var tc = std.testing.tmpDir(.{});
    defer tc.cleanup();
    var tb = std.testing.tmpDir(.{});
    defer tb.cleanup();
    var tr = std.testing.tmpDir(.{});
    defer tr.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_c = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tc.sub_path });
    defer std.testing.allocator.free(dir_c);
    const dir_b = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tb.sub_path });
    defer std.testing.allocator.free(dir_b);
    const dir_r = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tr.sub_path });
    defer std.testing.allocator.free(dir_r);

    try tc.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ outputs = i: { c = 3; }; }" });
    try tb.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ inputs.c.url = \"path:/x\"; outputs = i: { b = 2; cVal = i.c.c; }; }" });
    try tr.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ outputs = i: { bVal = i.b.b; bTransitiveC = i.b.cVal; cVal = i.c.c; }; }" });

    const lock = try std.fmt.allocPrint(std.testing.allocator,
        \\{{ "nodes": {{
        \\  "root": {{ "inputs": {{ "b": "b", "c": "c" }} }},
        \\  "b": {{ "inputs": {{ "c": ["c"] }}, "locked": {{ "type": "path", "path": "{s}" }}, "original": {{ "type": "path", "path": "{s}" }} }},
        \\  "c": {{ "locked": {{ "type": "path", "path": "{s}", "lastModified": 1650000000 }}, "original": {{ "type": "path", "path": "{s}" }} }}
        \\}}, "root": "root", "version": 7 }}
    , .{ dir_b, dir_b, dir_c, dir_c });
    defer std.testing.allocator.free(lock);
    try tr.dir.writeFile(std.testing.io, .{ .sub_path = "flake.lock", .data = lock });

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.flakes_enabled = true;

    inline for (.{ .{ "bVal", 2 }, .{ "bTransitiveC", 3 }, .{ "cVal", 3 } }) |q| {
        const src = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").{s}", .{ dir_r, q[0] });
        defer std.testing.allocator.free(src);
        try std.testing.expectEqual(@as(i64, q[1]), (try ev.evaluate(src)).asInt());
    }

    // The locked `lastModified` pin is threaded through the fetch into the
    // input's source info (and its formatted date), not reset to the epoch.
    const lm_src = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").inputs.c.lastModified", .{dir_r});
    defer std.testing.allocator.free(lm_src);
    try std.testing.expectEqual(@as(i64, 1650000000), (try ev.evaluate(lm_src)).asInt());
    const lmd_src = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").inputs.c.lastModifiedDate", .{dir_r});
    defer std.testing.allocator.free(lmd_src);
    try std.testing.expectEqualStrings("20220415052000", ev.intern.get((try ev.evaluate(lmd_src)).asInternId()));
}

test "getFlake resolves inputs from flake.nix when there is no lock" {
    // A flake with an input but no flake.lock: inputs come from the flake.nix
    // `inputs` declarations (fetched unlocked), including transitively.
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    var tr = std.testing.tmpDir(.{});
    defer tr.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_d = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &td.sub_path });
    defer std.testing.allocator.free(dir_d);
    const dir_r = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tr.sub_path });
    defer std.testing.allocator.free(dir_r);

    try td.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ outputs = i: { v = 55; }; }" });
    // `alias` has no url of its own — it `follows` the `dep` input, so
    // `i.alias.v` must resolve to the same flake as `i.dep.v` (no fetch, no
    // crash from the fetcher seeing a ref with no `type`).
    const root_flake = try std.fmt.allocPrint(std.testing.allocator, "{{ inputs.dep.url = \"path:{s}\"; inputs.alias.follows = \"dep\"; outputs = i: {{ x = i.dep.v + i.alias.v; }}; }}", .{dir_d});
    defer std.testing.allocator.free(root_flake);
    try tr.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = root_flake });
    // deliberately no flake.lock

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.flakes_enabled = true;

    const src = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").x", .{dir_r});
    defer std.testing.allocator.free(src);
    try std.testing.expectEqual(@as(i64, 110), (try ev.evaluate(src)).asInt());
}

test "getFlake rejects an unsupported flake.lock version" {
    var tr = std.testing.tmpDir(.{});
    defer tr.cleanup();
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_r = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tr.sub_path });
    defer std.testing.allocator.free(dir_r);

    try tr.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ outputs = i: { x = 1; }; }" });
    try tr.dir.writeFile(std.testing.io, .{ .sub_path = "flake.lock", .data = "{ \"nodes\": {\"root\":{}}, \"root\": \"root\", \"version\": 99 }" });

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.flakes_enabled = true;

    const src = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").x", .{dir_r});
    defer std.testing.allocator.free(src);
    try std.testing.expectError(error.UnsupportedFlakeLockVersion, ev.evaluate(src));
}

test "getFlake generates, writes, and uses a flake.lock when none exists" {
    // sub (leaf); dep (input: its own sub, v=99); root (inputs dep + sub v=1,
    // with dep.inputs.sub following root's sub). The generated lock must both
    // evaluate correctly (follows redirects dep's sub to root's) and be written.
    var t_root_sub = std.testing.tmpDir(.{});
    defer t_root_sub.cleanup();
    var t_dep_sub = std.testing.tmpDir(.{});
    defer t_dep_sub.cleanup();
    var t_dep = std.testing.tmpDir(.{});
    defer t_dep.cleanup();
    var t_root = std.testing.tmpDir(.{});
    defer t_root.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const abs = struct {
        fn p(a: std.mem.Allocator, base: []const u8, sub: []const u8) ![]u8 {
            return std.fs.path.resolve(a, &.{ base, ".zig-cache", "tmp", sub });
        }
    }.p;
    const d_root_sub = try abs(std.testing.allocator, cwd, &t_root_sub.sub_path);
    defer std.testing.allocator.free(d_root_sub);
    const d_dep_sub = try abs(std.testing.allocator, cwd, &t_dep_sub.sub_path);
    defer std.testing.allocator.free(d_dep_sub);
    const d_dep = try abs(std.testing.allocator, cwd, &t_dep.sub_path);
    defer std.testing.allocator.free(d_dep);
    const d_root = try abs(std.testing.allocator, cwd, &t_root.sub_path);
    defer std.testing.allocator.free(d_root);

    try t_root_sub.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ outputs = i: { v = 1; }; }" });
    try t_dep_sub.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ outputs = i: { v = 99; }; }" });
    const dep_nix = try std.fmt.allocPrint(std.testing.allocator, "{{ inputs.sub.url = \"path:{s}\"; outputs = {{ sub, ... }}: {{ d = sub.v; }}; }}", .{d_dep_sub});
    defer std.testing.allocator.free(dep_nix);
    try t_dep.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = dep_nix });
    const root_nix = try std.fmt.allocPrint(std.testing.allocator, "{{ inputs.sub.url = \"path:{s}\"; inputs.dep.url = \"path:{s}\"; inputs.dep.inputs.sub.follows = \"sub\"; outputs = {{ dep, ... }}: {{ d = dep.d; }}; }}", .{ d_root_sub, d_dep });
    defer std.testing.allocator.free(root_nix);
    try t_root.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = root_nix });

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.flakes_enabled = true;

    // follows redirects dep's `sub` to root's (v=1), not dep's own (v=99).
    const src = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").d", .{d_root});
    defer std.testing.allocator.free(src);
    try std.testing.expectEqual(@as(i64, 1), (try ev.evaluate(src)).asInt());

    // A flake.lock was written next to the root flake.nix, and it records the
    // follows edge as a path array.
    const lock = try t_root.dir.readFileAlloc(std.testing.io, "flake.lock", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(lock);
    try std.testing.expect(std.mem.indexOf(u8, lock, "\"version\": 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, lock, "\"sub\": [\"sub\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, lock, "narHash") != null);
}

test "getFlake resolves follows-the-root lock edges to the flake itself" {
    // Nix's `inputs.<name>.follows = ""` is the EMPTY input path — the root
    // node, i.e. the flake itself. The lock records it as `[]`. Exercised at
    // the root (`me`) and nested (root overrides dep's `up` to follow root).
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    var tr = std.testing.tmpDir(.{});
    defer tr.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_d = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &td.sub_path });
    defer std.testing.allocator.free(dir_d);
    const dir_r = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tr.sub_path });
    defer std.testing.allocator.free(dir_r);

    try td.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ inputs.up.url = \"path:/unused\"; outputs = i: { rootV = i.up.v; }; }" });
    try tr.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ inputs.me.follows = \"\"; inputs.dep.url = \"path:/unused\"; outputs = i: { v = 5; viaSelf = i.me.v; depSeesRoot = i.dep.rootV; }; }" });

    const lock = try std.fmt.allocPrint(std.testing.allocator,
        \\{{ "nodes": {{
        \\  "root": {{ "inputs": {{ "me": [], "dep": "dep" }} }},
        \\  "dep": {{ "inputs": {{ "up": [] }}, "locked": {{ "type": "path", "path": "{s}" }}, "original": {{ "type": "path", "path": "{s}" }} }}
        \\}}, "root": "root", "version": 7 }}
    , .{ dir_d, dir_d });
    defer std.testing.allocator.free(lock);
    try tr.dir.writeFile(std.testing.io, .{ .sub_path = "flake.lock", .data = lock });

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.flakes_enabled = true;

    inline for (.{ "viaSelf", "depSeesRoot" }) |attr| {
        const src = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").{s}", .{ dir_r, attr });
        defer std.testing.allocator.free(src);
        try std.testing.expectEqual(@as(i64, 5), (try ev.evaluate(src)).asInt());
    }
}

test "lock generation records follows-the-root as an empty path" {
    // No lock: `inputs.me.follows = ""` must generate a `"me": []` edge (Nix's
    // tokenizer drops empty path elements) and evaluate to the flake itself.
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    var tr = std.testing.tmpDir(.{});
    defer tr.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_d = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &td.sub_path });
    defer std.testing.allocator.free(dir_d);
    const dir_r = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tr.sub_path });
    defer std.testing.allocator.free(dir_r);

    try td.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ outputs = i: { v = 1; }; }" });
    const root_nix = try std.fmt.allocPrint(std.testing.allocator, "{{ inputs.dep.url = \"path:{s}\"; inputs.me.follows = \"\"; outputs = i: {{ v = 7; viaSelf = i.me.v; }}; }}", .{dir_d});
    defer std.testing.allocator.free(root_nix);
    try tr.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = root_nix });

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.flakes_enabled = true;

    const src = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").viaSelf", .{dir_r});
    defer std.testing.allocator.free(src);
    try std.testing.expectEqual(@as(i64, 7), (try ev.evaluate(src)).asInt());

    const lock = try tr.dir.readFileAlloc(std.testing.io, "flake.lock", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(lock);
    try std.testing.expect(std.mem.indexOf(u8, lock, "\"me\": []") != null);
}

test "child-declared follows lock relative to the declaring flake" {
    // dep's own flake.nix declares `alias.follows = "sub"` and
    // `me.follows = ""`. Nix absolutizes those against the DECLARING flake's
    // input path, so the lock must record ["dep","sub"] (dep's own sub, not a
    // root input — root has none named sub) and ["dep"] (dep itself, a
    // self-cycle in the graph).
    var ts = std.testing.tmpDir(.{});
    defer ts.cleanup();
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    var tr = std.testing.tmpDir(.{});
    defer tr.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_s = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &ts.sub_path });
    defer std.testing.allocator.free(dir_s);
    const dir_d = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &td.sub_path });
    defer std.testing.allocator.free(dir_d);
    const dir_r = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tr.sub_path });
    defer std.testing.allocator.free(dir_r);

    try ts.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ outputs = i: { v = 33; }; }" });
    const dep_nix = try std.fmt.allocPrint(std.testing.allocator, "{{ inputs.sub.url = \"path:{s}\"; inputs.alias.follows = \"sub\"; inputs.me.follows = \"\"; outputs = i: {{ d = 9; aliasV = i.alias.v; meD = i.me.d; }}; }}", .{dir_s});
    defer std.testing.allocator.free(dep_nix);
    try td.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = dep_nix });
    const root_nix = try std.fmt.allocPrint(std.testing.allocator, "{{ inputs.dep.url = \"path:{s}\"; outputs = i: {{ aliasV = i.dep.aliasV; meD = i.dep.meD; }}; }}", .{dir_d});
    defer std.testing.allocator.free(root_nix);
    try tr.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = root_nix });

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.flakes_enabled = true;

    inline for (.{ .{ "aliasV", 33 }, .{ "meD", 9 } }) |q| {
        const src = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").{s}", .{ dir_r, q[0] });
        defer std.testing.allocator.free(src);
        try std.testing.expectEqual(@as(i64, q[1]), (try ev.evaluate(src)).asInt());
    }

    const lock = try tr.dir.readFileAlloc(std.testing.io, "flake.lock", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(lock);
    try std.testing.expect(std.mem.indexOf(u8, lock, "\"alias\": [\"dep\",\"sub\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, lock, "\"me\": [\"dep\"]") != null);
}

test "deep override chains thread through lock generation" {
    // Root declares `inputs.a.inputs.b.inputs.c.follows = "x"` — a 3-level
    // override whose middle levels carry no ref of their own. The `c` edge on
    // b's node must be ["x"] (declared at root → root-relative), overriding
    // b's own pin of c.
    var tx = std.testing.tmpDir(.{});
    defer tx.cleanup();
    var tc = std.testing.tmpDir(.{});
    defer tc.cleanup();
    var tb = std.testing.tmpDir(.{});
    defer tb.cleanup();
    var ta = std.testing.tmpDir(.{});
    defer ta.cleanup();
    var tr = std.testing.tmpDir(.{});
    defer tr.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const abs = struct {
        fn p(a: std.mem.Allocator, base: []const u8, sub: []const u8) ![]u8 {
            return std.fs.path.resolve(a, &.{ base, ".zig-cache", "tmp", sub });
        }
    }.p;
    const dir_x = try abs(std.testing.allocator, cwd, &tx.sub_path);
    defer std.testing.allocator.free(dir_x);
    const dir_c = try abs(std.testing.allocator, cwd, &tc.sub_path);
    defer std.testing.allocator.free(dir_c);
    const dir_b = try abs(std.testing.allocator, cwd, &tb.sub_path);
    defer std.testing.allocator.free(dir_b);
    const dir_a = try abs(std.testing.allocator, cwd, &ta.sub_path);
    defer std.testing.allocator.free(dir_a);
    const dir_r = try abs(std.testing.allocator, cwd, &tr.sub_path);
    defer std.testing.allocator.free(dir_r);

    try tx.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ outputs = i: { v = 100; }; }" });
    try tc.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = "{ outputs = i: { v = 1; }; }" });
    const b_nix = try std.fmt.allocPrint(std.testing.allocator, "{{ inputs.c.url = \"path:{s}\"; outputs = i: {{ cV = i.c.v; }}; }}", .{dir_c});
    defer std.testing.allocator.free(b_nix);
    try tb.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = b_nix });
    const a_nix = try std.fmt.allocPrint(std.testing.allocator, "{{ inputs.b.url = \"path:{s}\"; outputs = i: {{ bCV = i.b.cV; }}; }}", .{dir_b});
    defer std.testing.allocator.free(a_nix);
    try ta.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = a_nix });
    const root_nix = try std.fmt.allocPrint(std.testing.allocator, "{{ inputs.x.url = \"path:{s}\"; inputs.a = {{ url = \"path:{s}\"; inputs.b.inputs.c.follows = \"x\"; }}; outputs = i: {{ v = i.a.bCV; }}; }}", .{ dir_x, dir_a });
    defer std.testing.allocator.free(root_nix);
    try tr.dir.writeFile(std.testing.io, .{ .sub_path = "flake.nix", .data = root_nix });

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.flakes_enabled = true;

    const src = try std.fmt.allocPrint(std.testing.allocator, "(builtins.getFlake \"path:{s}\").v", .{dir_r});
    defer std.testing.allocator.free(src);
    try std.testing.expectEqual(@as(i64, 100), (try ev.evaluate(src)).asInt());

    const lock = try tr.dir.readFileAlloc(std.testing.io, "flake.lock", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(lock);
    try std.testing.expect(std.mem.indexOf(u8, lock, "\"c\": [\"x\"]") != null);
}

test "pure evaluation sandboxes env, out-of-tree reads, search paths, and unlocked fetches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "inside.txt", .data = "INSIDE" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(dir);
    const inside = try std.fs.path.join(std.testing.allocator, &.{ dir, "inside.txt" });
    defer std.testing.allocator.free(inside);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.policy.flakes_enabled = true;
    ev.policy.fetch_tree_enabled = true;
    // Pure eval, with `dir` as the single readable root besides the store.
    try ev.setPureEval(true, &.{dir});

    // getEnv is hidden.
    const env = try ev.evaluate("builtins.getEnv \"HOME\"");
    try std.testing.expectEqualStrings("", ev.intern.get(env.asInternId()));

    // A read inside the allowed root succeeds; outside is forbidden.
    const in_src = try std.fmt.allocPrint(std.testing.allocator, "builtins.readFile \"{s}\"", .{inside});
    defer std.testing.allocator.free(in_src);
    const in_val = try ev.evaluate(in_src);
    try std.testing.expectEqualStrings("INSIDE", ev.intern.get(in_val.asInternId()));
    try std.testing.expectError(error.RestrictedInPureEval, ev.evaluate("builtins.readFile \"/etc/hostname\""));

    // currentSystem / currentTime are unavailable in pure eval.
    try std.testing.expectError(error.RestrictedInPureEval, ev.evaluate("builtins.currentSystem"));
    try std.testing.expectError(error.RestrictedInPureEval, ev.evaluate("builtins.currentTime"));

    // Search-path lookups and unlocked fetches are forbidden — but the
    // synthetic corepkgs `<nix/fetchurl.nix>` stays importable (it resolves to
    // embedded source, not a search-path entry or an on-disk read).
    try std.testing.expectError(error.RestrictedInPureEval, ev.evaluate("builtins.findFile builtins.nixPath \"nixpkgs\""));
    const fetchurl_fn = try ev.evaluate("builtins.isFunction (import <nix/fetchurl.nix>)");
    try std.testing.expect(fetchurl_fn.asBool());
    try std.testing.expectError(
        error.RestrictedInPureEval,
        ev.evaluate("builtins.fetchTree { type = \"github\"; owner = \"o\"; repo = \"r\"; }"),
    );

    // `--impure` (pure_eval off) lifts the restriction: an out-of-tree read no
    // longer fails *for purity reasons* (it may still fail to find the file).
    try ev.setPureEval(false, &.{});
    if (ev.evaluate("builtins.readFile \"/no/such/file/here\"")) |_| {} else |err| {
        try std.testing.expect(err != error.RestrictedInPureEval);
    }
}

test "flake builtins are gated on the flakes experimental feature" {
    // getFlake / parseFlakeRef / flakeRefToString are hard-gated (uncatchable
    // by tryEval), like Nix. Without the feature they error before doing work.
    try std.testing.expectError(
        error.MissingExperimentalFeature,
        renderForTest("builtins.getFlake \"path:/nonexistent\""),
    );
    try std.testing.expectError(
        error.MissingExperimentalFeature,
        renderForTest("builtins.parseFlakeRef \"github:NixOS/nixpkgs\""),
    );
    try std.testing.expectError(
        error.MissingExperimentalFeature,
        renderForTest("builtins.flakeRefToString { type = \"path\"; path = \"/x\"; }"),
    );
}

test "evaluate findFile builtin through explicit search path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.nix", .data = "1" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);
    const expected_path = try std.fs.path.resolve(std.testing.allocator, &.{ base_path, "target.nix" });
    defer std.testing.allocator.free(expected_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.findFile [ {{ prefix = \"pkg\"; path = {s}; }} ] \"pkg/target.nix\"", .{base_path});
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const found = try ev.evaluate(source);
    try std.testing.expectEqualStrings(expected_path, ev.intern.get(found.asInternId()));
}

test "evaluate angle search path literals through cached nix path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.nix", .data = "{ value = 5; }" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(base_path);

    const nix_path = try std.fmt.allocPrint(std.testing.allocator, "pkg={s}", .{base_path});
    defer std.testing.allocator.free(nix_path);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    try ev.setNixPath(nix_path);

    const imported = try ev.evaluate("(import <pkg/target.nix>).value");
    try std.testing.expectEqual(@as(i64, 5), imported.asInt());
}

test "evaluate import through evaluator file cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "imported.nix", .data = "{ value = 42; }\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "imported.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "let a = import {s}; b = import {s}; in a.value + b.value", .{ file_path, file_path });
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const imported = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 84), imported.asInt());
    try std.testing.expectEqual(@as(u32, 1), ev.sources.imports.entries.count());
}

test "evaluate path builtins coerce outPath attrsets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "imported.nix", .data = "{ value = 21; }\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const imported_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "imported.nix",
    });
    defer std.testing.allocator.free(imported_path);
    const payload_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "payload.txt",
    });
    defer std.testing.allocator.free(payload_path);

    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\let
        \\  imported = (import {{ outPath = "{s}"; }}).value;
        \\  contents = builtins.readFile {{ outPath = "{s}"; }};
        \\in imported + builtins.stringLength contents
    , .{ imported_path, payload_path });
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const result = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 28), result.asInt());
}

test "evaluate directory import through default nix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "pkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pkg/default.nix", .data = "{ value = 9; }\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const dir_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "pkg",
    });
    defer std.testing.allocator.free(dir_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "(import {s}).value", .{dir_path});
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const imported = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 9), imported.asInt());
}

test "evaluate scopedImport through ambient scope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scope.nix", .data = "x + y\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "scope.nix" });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "builtins.scopedImport {{ x = 1; y = 2; }} {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    const imported = try ev.evaluate(source);
    try std.testing.expectEqual(@as(i64, 3), imported.asInt());
}

test "detect recursive scoped imports with migratable workers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cycle.nix",
        .data = "builtins.scopedImport { inherit builtins; } ./cycle.nix\n",
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "cycle.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "builtins.scopedImport {{ inherit builtins; }} {s}",
        .{file_path},
    );
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 4 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    try std.testing.expectError(error.ImportCycle, ev.evaluate(source));
}

test "detect recursive imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cycle.nix", .data = "import ./cycle.nix\n" });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "cycle.nix",
    });
    defer std.testing.allocator.free(file_path);

    const source = try std.fmt.allocPrint(std.testing.allocator, "import {s}", .{file_path});
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);

    try std.testing.expectError(error.ImportCycle, ev.evaluate(source));
}

const LifecycleTrackingAllocator = struct {
    child: std.mem.Allocator,
    tracked_ptr: std.atomic.Value(usize) = .init(0),
    frees: std.atomic.Value(usize) = .init(0),

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(child: std.mem.Allocator) LifecycleTrackingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *LifecycleTrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn track(self: *LifecycleTrackingAllocator, bytes: []u8) void {
        self.tracked_ptr.store(@intFromPtr(bytes.ptr), .seq_cst);
    }

    fn freeCount(self: *LifecycleTrackingAllocator) usize {
        return self.frees.load(.seq_cst);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *LifecycleTrackingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *LifecycleTrackingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *LifecycleTrackingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *LifecycleTrackingAllocator = @ptrCast(@alignCast(ctx));
        const tracked = @intFromPtr(memory.ptr) == self.tracked_ptr.load(.seq_cst);
        self.child.rawFree(memory, alignment, return_address);
        if (tracked) _ = self.frees.fetchAdd(1, .monotonic);
    }
};

test "finishEvaluation releases retained flat recipe payload" {
    if (comptime @hasDecl(RealizationStore, "recordFlatRecipe") and @hasDecl(RealizationStore, "releaseRecipePayloads")) {
        var tracking = LifecycleTrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var ev = try Engine.init(allocator, .{ .worker_count = 0 });
        defer ev.deinit();
        const payload = try allocator.dupe(u8, "shared evaluator recipe payload");
        const payload_ptr = @intFromPtr(payload.ptr);
        tracking.track(payload);
        var handle = try FileCache.ImmutableBytes.fromOwned(allocator, payload);

        try ev.store.realization.recordFlatRecipe("/nix/store/44444444444444444444444444444444-flat", handle, false);
        try std.testing.expectEqual(payload_ptr, @intFromPtr(handle.bytes().ptr));
        handle.release();
        try std.testing.expectEqual(@as(usize, 0), tracking.freeCount());

        // RealizationStore remains alive after this call. The payload can be
        // freed here only if finishEvaluation explicitly drops its recipe
        // reference; review separately enforces that call precedes files.deinit.
        ev.finishEvaluation();
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
    } else return error.MissingRecipeRegistryApi;
}
