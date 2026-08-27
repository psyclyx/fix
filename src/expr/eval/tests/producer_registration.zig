const std = @import("std");
const eval_mod = @import("../../evaluator.zig");
const Engine = eval_mod.Engine;
const RealizationStore = @import("store").RealizationStore;
const Value = @import("runtime").value.Value;
const ObjectId = @import("runtime").types.ObjectId;
const nar = @import("store").nar;
const derivation = @import("store").derivation;
const FakeDaemon = @import("store").realization.testing.FakeDaemon;

fn recipeInspectionAvailable() bool {
    return @hasDecl(RealizationStore.TestAccess, "RecipeKind") and
        @hasDecl(RealizationStore.TestAccess, "recipeCount") and
        @hasDecl(RealizationStore.TestAccess, "recipeKind") and
        @hasDecl(RealizationStore.TestAccess, "recipePayloadPointer") and
        @hasDecl(RealizationStore.TestAccess, "recipePayloadBytes") and
        @hasDecl(RealizationStore.TestAccess, "recipeReferences") and
        @hasDecl(RealizationStore.TestAccess, "producerPayloadPointer");
}

const Fixture = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    store_dir: []u8,
    fake: *FakeDaemon,
    ev: Engine,

    fn init(allocator: std.mem.Allocator, enable_store_writes: bool) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(std.testing.io, "store", .default_dir);

        const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
        defer allocator.free(cwd);
        const store_dir = try std.fs.path.resolve(allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "store" });
        errdefer allocator.free(store_dir);

        const fake = try FakeDaemon.start(allocator, std.testing.io);
        errdefer fake.deinit();

        var ev = try Engine.init(allocator, .{ .worker_count = 0 });
        errdefer ev.deinit();
        ev.setFileIo(std.testing.io);
        ev.store.realization.store_dir = store_dir;
        ev.store.realization.testAccess().useBorrowedDaemonSocket(fake.socketPath());
        if (enable_store_writes) ev.enableStoreWrites();

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .store_dir = store_dir,
            .fake = fake,
            .ev = ev,
        };
    }

    fn deinit(self: *Fixture) void {
        self.ev.deinit();
        self.fake.deinit();
        self.allocator.free(self.store_dir);
        self.tmp.cleanup();
    }

    fn evaluateAttrs(self: *Fixture, source: []const u8) !ObjectId {
        const value = try self.ev.evaluate(source);
        if (!value.isAttrs()) return error.ExpectedAttrs;
        return value.asObjectId();
    }

    fn forceAttrValue(self: *Fixture, attrs_id: ObjectId, name: []const u8) !Value {
        return self.ev.forceValue(try self.ev.heap.getAttrValue(attrs_id, try self.ev.intern.intern(name)));
    }

    fn forceAttrText(self: *Fixture, attrs_id: ObjectId, name: []const u8) ![]const u8 {
        return valueText(self, try self.forceAttrValue(attrs_id, name));
    }
};

fn valueText(fixture: *Fixture, value: Value) ![]const u8 {
    const forced = try fixture.ev.forceValue(value);
    return switch (forced.kind()) {
        .string, .path => fixture.ev.intern.get(forced.asInternId()),
        .string_context => fixture.ev.intern.get((try fixture.ev.heap.getContextString(forced.asObjectId())).text),
        else => error.ExpectedStringResult,
    };
}

fn expectRefsEqual(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |exp, got| try std.testing.expectEqualStrings(exp, got);
}

fn storePathSubject(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (base.len > 33 and base[32] == '-') return base[33..];
    return base;
}

fn expectRecipeText(store: *RealizationStore, store_path: []const u8, payload: []const u8, refs: []const []const u8) !void {
    if (comptime recipeInspectionAvailable()) {
        try std.testing.expectEqual(RealizationStore.TestAccess.RecipeKind.text, store.testAccess().recipeKind(store_path).?);
        try std.testing.expectEqual(store.testAccess().producerPayloadPointer(store_path).?, store.testAccess().recipePayloadPointer(store_path).?);
        try std.testing.expectEqualStrings(payload, store.testAccess().recipePayloadBytes(store_path).?);
        try expectRefsEqual(store.testAccess().recipeReferences(store_path).?, refs);
    } else unreachable;
}

fn expectRecipeNar(store: *RealizationStore, store_path: []const u8, payload: []const u8) !void {
    if (comptime recipeInspectionAvailable()) {
        try std.testing.expectEqual(RealizationStore.TestAccess.RecipeKind.nar, store.testAccess().recipeKind(store_path).?);
        try std.testing.expectEqual(store.testAccess().producerPayloadPointer(store_path).?, store.testAccess().recipePayloadPointer(store_path).?);
        try std.testing.expectEqualStrings(payload, store.testAccess().recipePayloadBytes(store_path).?);
        try expectRefsEqual(store.testAccess().recipeReferences(store_path).?, &.{});
    } else unreachable;
}

fn expectRecipeFlat(store: *RealizationStore, store_path: []const u8, expected_ptr: usize, payload: []const u8) !void {
    if (comptime recipeInspectionAvailable()) {
        try std.testing.expectEqual(RealizationStore.TestAccess.RecipeKind.flat, store.testAccess().recipeKind(store_path).?);
        try std.testing.expectEqual(expected_ptr, store.testAccess().recipePayloadPointer(store_path).?);
        try std.testing.expectEqualStrings(payload, store.testAccess().recipePayloadBytes(store_path).?);
        try expectRefsEqual(store.testAccess().recipeReferences(store_path).?, &.{});
    } else unreachable;
}

fn expectEffect(fake: *FakeDaemon, index: usize, kind: FakeDaemon.Kind, subject: []const u8, payload: []const u8, refs: []const []const u8) !void {
    try std.testing.expectEqual(kind, fake.effectKindAt(index).?);
    try std.testing.expect(fake.effectSubjectEquals(index, subject));
    try std.testing.expect(fake.effectPayloadEquals(index, payload));
    try std.testing.expect(fake.effectReferencesEqual(index, refs));
}

test "storeless derivation normalization records the exact drv text recipe" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();
        fixture.ev.setDerivationDebug(true);

        const attrs_id = try fixture.evaluateAttrs(
            \\let drv = builtins.derivation {
            \\  name = "recipe-drv";
            \\  system = "x86_64-linux";
            \\  builder = "/bin/sh";
            \\}; in { drv = drv.drvPath; }
        );
        const drv_path = try fixture.forceAttrText(attrs_id, "drv");
        const records = fixture.ev.derivationDebugRecords();
        try std.testing.expectEqual(@as(usize, 1), records.len);
        try std.testing.expectEqual(@as(usize, 1), fixture.ev.store.realization.testAccess().recipeCount());
        try expectRecipeText(&fixture.ev.store.realization, drv_path, records[0].drv_aterm, records[0].drv_text_references);

        try fixture.ev.store.realization.ensureClosure(drv_path);
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 0, .text, storePathSubject(drv_path), records[0].drv_aterm, records[0].drv_text_references);
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.store.realization.testAccess().recipeCount());
    } else return error.MissingRecipeInspectionApi;
}

test "builtins.toFile records owned text and exact references" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();

        const attrs_id = try fixture.evaluateAttrs(
            \\let
            \\  dep = builtins.toFile "dep.txt" "dep payload";
            \\  root = builtins.toFile "root.txt" "${dep}\nroot payload";
            \\in {
            \\  inherit dep root;
            \\  contents = "${dep}\nroot payload";
            \\}
        );
        const dep_path = try fixture.forceAttrText(attrs_id, "dep");
        const root_path = try fixture.forceAttrText(attrs_id, "root");
        const root_contents = try fixture.forceAttrText(attrs_id, "contents");

        try std.testing.expectEqual(@as(usize, 2), fixture.ev.store.realization.testAccess().recipeCount());
        try expectRecipeText(&fixture.ev.store.realization, dep_path, "dep payload", &.{});
        try expectRecipeText(&fixture.ev.store.realization, root_path, root_contents, &.{dep_path});

        try fixture.ev.store.realization.ensureClosure(root_path);
        try std.testing.expectEqual(@as(usize, 2), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 0, .text, storePathSubject(dep_path), "dep payload", &.{});
        try expectEffect(fixture.fake, 1, .text, storePathSubject(root_path), root_contents, &.{dep_path});
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.store.realization.testAccess().recipeCount());
    } else return error.MissingRecipeInspectionApi;
}

test "storeless builtins.path recursive source records the serialized NAR" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();
        try fixture.tmp.dir.createDir(std.testing.io, "tree", .default_dir);
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tree/file.txt", .data = "nar payload" });

        const cwd = try std.process.currentPathAlloc(std.testing.io, fixture.allocator);
        defer fixture.allocator.free(cwd);
        const tree_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "tree" });
        defer fixture.allocator.free(tree_path);
        const source = try std.fmt.allocPrint(
            fixture.allocator,
            "builtins.path {{ path = \"{s}\"; name = \"source-tree\"; }}",
            .{tree_path},
        );
        defer fixture.allocator.free(source);

        const store_path = try valueText(&fixture, try fixture.ev.evaluate(source));
        const nar_bytes = try nar.serialize(fixture.allocator, &fixture.ev.sources.files, tree_path, null);
        defer fixture.allocator.free(nar_bytes);

        try std.testing.expectEqual(@as(usize, 1), fixture.ev.store.realization.testAccess().recipeCount());
        try expectRecipeNar(&fixture.ev.store.realization, store_path, nar_bytes);

        try fixture.ev.store.realization.ensureClosure(store_path);
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 0, .nar, storePathSubject(store_path), nar_bytes, &.{});
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.store.realization.testAccess().recipeCount());
    } else return error.MissingRecipeInspectionApi;
}

test "storeless builtins.path recursive false records retained flat file identity" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "flat.txt", .data = "flat source payload" });

        const cwd = try std.process.currentPathAlloc(std.testing.io, fixture.allocator);
        defer fixture.allocator.free(cwd);
        const flat_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "flat.txt" });
        defer fixture.allocator.free(flat_path);
        const source = try std.fmt.allocPrint(
            fixture.allocator,
            "builtins.path {{ path = \"{s}\"; name = \"flat-source\"; recursive = false; }}",
            .{flat_path},
        );
        defer fixture.allocator.free(source);

        const store_path = try valueText(&fixture, try fixture.ev.evaluate(source));
        var retained = try fixture.ev.sources.files.retainFile(flat_path);
        defer retained.release();

        try std.testing.expectEqual(@as(usize, 1), fixture.ev.store.realization.testAccess().recipeCount());
        try expectRecipeFlat(&fixture.ev.store.realization, store_path, @intFromPtr(retained.bytes().ptr), "flat source payload");

        try fixture.ev.store.realization.ensureClosure(store_path);
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 0, .flat, storePathSubject(store_path), "flat source payload", &.{});
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.store.realization.testAccess().recipeCount());
    } else return error.MissingRecipeInspectionApi;
}

test "storeless fetchurl records retained flat file identity" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload.txt", .data = "fetch payload" });

        const cwd = try std.process.currentPathAlloc(std.testing.io, fixture.allocator);
        defer fixture.allocator.free(cwd);
        const file_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "payload.txt" });
        defer fixture.allocator.free(file_path);
        const source = try std.fmt.allocPrint(
            fixture.allocator,
            "builtins.fetchurl {{ url = \"file://{s}\"; name = \"payload.txt\"; }}",
            .{file_path},
        );
        defer fixture.allocator.free(source);

        const store_path = try valueText(&fixture, try fixture.ev.evaluate(source));
        var retained = try fixture.ev.sources.files.retainFile(store_path);
        defer retained.release();

        try std.testing.expectEqual(@as(usize, 1), fixture.ev.store.realization.testAccess().recipeCount());
        try expectRecipeFlat(&fixture.ev.store.realization, store_path, @intFromPtr(retained.bytes().ptr), "fetch payload");

        try fixture.ev.store.realization.ensureClosure(store_path);
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 0, .flat, storePathSubject(store_path), "fetch payload", &.{});
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.store.realization.testAccess().recipeCount());
    } else return error.MissingRecipeInspectionApi;
}

test "hashed fetchTarball skips fetching when its derived store path is valid" {
    var fixture = try Fixture.init(std.testing.allocator, true);
    defer fixture.deinit();
    const hash = "0000000000000000000000000000000000000000000000000000000000000000";
    const store_path = try derivation.sourcePath(fixture.allocator, fixture.store_dir, "cached-source", hash);
    defer fixture.allocator.free(store_path);
    try fixture.fake.markValid(store_path);

    const value = try fixture.ev.evaluate(
        \\builtins.fetchTarball {
        \\  url = "file:///definitely/missing/fix-cache-fast-path.tar.xz";
        \\  name = "cached-source";
        \\  sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
        \\}
    );
    try std.testing.expectEqualStrings(store_path, try valueText(&fixture, value));
    try std.testing.expectEqual(@as(usize, 1), fixture.fake.count(.query));
    try std.testing.expectEqual(@as(usize, 0), fixture.fake.effectCount());
}

test "realizeOutput realizes a mixed producer closure before the root derivation build" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();
        fixture.ev.setDerivationDebug(true);
        try fixture.tmp.dir.createDir(std.testing.io, "src", .default_dir);
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/file.txt", .data = "nar dep payload" });
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "flat.txt", .data = "flat dep payload" });

        const cwd = try std.process.currentPathAlloc(std.testing.io, fixture.allocator);
        defer fixture.allocator.free(cwd);
        const src_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "src" });
        defer fixture.allocator.free(src_path);
        const flat_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "flat.txt" });
        defer fixture.allocator.free(flat_path);
        const source = try std.fmt.allocPrint(
            fixture.allocator,
            \\let
            \\  text = builtins.toFile "mixed-text" "text dep payload";
            \\  src = builtins.path {{ path = "{s}"; name = "mixed-src"; }};
            \\  flat = builtins.path {{ path = "{s}"; name = "mixed-flat"; recursive = false; }};
            \\  drv = builtins.derivation {{
            \\    name = "mixed-root";
            \\    system = "x86_64-linux";
            \\    builder = "/bin/sh";
            \\    inherit text src flat;
            \\  }};
            \\in {{
            \\  inherit text src flat;
            \\  drv = drv.drvPath;
            \\}}
        ,
            .{ src_path, flat_path },
        );
        defer fixture.allocator.free(source);

        const attrs_id = try fixture.evaluateAttrs(source);
        const text_path = try fixture.forceAttrText(attrs_id, "text");
        const src_store_path = try fixture.forceAttrText(attrs_id, "src");
        const flat_store_path = try fixture.forceAttrText(attrs_id, "flat");
        const drv_path = try fixture.forceAttrText(attrs_id, "drv");
        const records = fixture.ev.derivationDebugRecords();
        try std.testing.expectEqual(@as(usize, 1), records.len);

        const nar_bytes = try nar.serialize(fixture.allocator, &fixture.ev.sources.files, src_path, null);
        defer fixture.allocator.free(nar_bytes);
        var retained = try fixture.ev.sources.files.retainFile(flat_path);
        defer retained.release();

        try std.testing.expectEqual(@as(usize, 4), fixture.ev.store.realization.testAccess().recipeCount());
        try expectRecipeText(&fixture.ev.store.realization, text_path, "text dep payload", &.{});
        try expectRecipeNar(&fixture.ev.store.realization, src_store_path, nar_bytes);
        try expectRecipeFlat(&fixture.ev.store.realization, flat_store_path, @intFromPtr(retained.bytes().ptr), "flat dep payload");
        try expectRecipeText(&fixture.ev.store.realization, drv_path, records[0].drv_aterm, records[0].drv_text_references);

        const build_subject = try std.fmt.allocPrint(fixture.allocator, "{s}!out", .{drv_path});
        defer fixture.allocator.free(build_subject);
        try fixture.ev.store.realization.realizeOutput(drv_path, &.{"out"});

        const refs = records[0].drv_text_references;
        try std.testing.expectEqual(refs.len + 2, fixture.fake.effectCount());
        for (refs, 0..) |ref, i| {
            if (std.mem.eql(u8, ref, text_path)) {
                try expectEffect(fixture.fake, i, .text, storePathSubject(text_path), "text dep payload", &.{});
            } else if (std.mem.eql(u8, ref, src_store_path)) {
                try expectEffect(fixture.fake, i, .nar, storePathSubject(src_store_path), nar_bytes, &.{});
            } else if (std.mem.eql(u8, ref, flat_store_path)) {
                try expectEffect(fixture.fake, i, .flat, storePathSubject(flat_store_path), "flat dep payload", &.{});
            } else return error.UnexpectedMixedReference;
        }
        try expectEffect(fixture.fake, refs.len, .text, storePathSubject(drv_path), records[0].drv_aterm, refs);
        try expectEffect(fixture.fake, refs.len + 1, .build, build_subject, "", &.{});
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.store.realization.testAccess().recipeCount());
    } else return error.MissingRecipeInspectionApi;
}

test "read-write evaluation writes sources and toFile objects with no derivation to demand them" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, false);
        defer fixture.deinit();
        // `nix-instantiate --eval --read-write-mode`: the CLI prints the value
        // and exits, so a coerced source has no terminal closure that would
        // ever walk its recipe. Each producer must land in the store itself.
        fixture.ev.enableReadWriteEvaluation();
        try fixture.tmp.dir.createDir(std.testing.io, "rw-src", .default_dir);
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rw-src/file.txt", .data = "rw nar payload" });
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rw-flat.txt", .data = "rw flat payload" });
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "rw-coerce.txt", .data = "rw coerce payload" });

        const cwd = try std.process.currentPathAlloc(std.testing.io, fixture.allocator);
        defer fixture.allocator.free(cwd);
        const src_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "rw-src" });
        defer fixture.allocator.free(src_path);
        const flat_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "rw-flat.txt" });
        defer fixture.allocator.free(flat_path);
        const coerce_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "rw-coerce.txt" });
        defer fixture.allocator.free(coerce_path);
        const source = try std.fmt.allocPrint(
            fixture.allocator,
            \\{{
            \\  text = builtins.toFile "rw-text" "rw text payload";
            \\  src = builtins.path {{ path = "{s}"; name = "rw-src"; }};
            \\  flat = builtins.path {{ path = "{s}"; name = "rw-flat"; recursive = false; }};
            \\  coerced = "${{{s}}}";
            \\}}
        ,
            .{ src_path, flat_path, coerce_path },
        );
        defer fixture.allocator.free(source);

        const attrs_id = try fixture.evaluateAttrs(source);
        const nar_bytes = try nar.serialize(fixture.allocator, &fixture.ev.sources.files, src_path, null);
        defer fixture.allocator.free(nar_bytes);
        const coerce_nar = try nar.serialize(fixture.allocator, &fixture.ev.sources.files, coerce_path, null);
        defer fixture.allocator.free(coerce_nar);

        // Each attr writes exactly once, at the point it is produced, and leaves
        // no recipe behind for a closure walk that will never come.
        const text_path = try fixture.forceAttrText(attrs_id, "text");
        try std.testing.expectEqual(@as(usize, 1), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 0, .text, storePathSubject(text_path), "rw text payload", &.{});
        const src_store_path = try fixture.forceAttrText(attrs_id, "src");
        try std.testing.expectEqual(@as(usize, 2), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 1, .nar, storePathSubject(src_store_path), nar_bytes, &.{});
        const flat_store_path = try fixture.forceAttrText(attrs_id, "flat");
        try std.testing.expectEqual(@as(usize, 3), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 2, .flat, storePathSubject(flat_store_path), "rw flat payload", &.{});
        const coerced_path = try fixture.forceAttrText(attrs_id, "coerced");
        try std.testing.expectEqual(@as(usize, 4), fixture.fake.effectCount());
        try expectEffect(fixture.fake, 3, .nar, storePathSubject(coerced_path), coerce_nar, &.{});

        try std.testing.expectEqual(@as(usize, 0), fixture.ev.store.realization.testAccess().recipeCount());
    } else return error.MissingRecipeInspectionApi;
}

test "store-writing mode defers writes; ensureClosure materializes the drv closure deps-first" {
    if (comptime recipeInspectionAvailable()) {
        var fixture = try Fixture.init(std.testing.allocator, true);
        defer fixture.deinit();
        fixture.ev.setDerivationDebug(true);
        try fixture.tmp.dir.createDir(std.testing.io, "write-src", .default_dir);
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "write-src/file.txt", .data = "write nar payload" });
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "write-flat.txt", .data = "write flat payload" });
        try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "write-fetch.txt", .data = "write fetch payload" });

        const cwd = try std.process.currentPathAlloc(std.testing.io, fixture.allocator);
        defer fixture.allocator.free(cwd);
        const src_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "write-src" });
        defer fixture.allocator.free(src_path);
        const flat_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "write-flat.txt" });
        defer fixture.allocator.free(flat_path);
        const fetch_path = try std.fs.path.resolve(fixture.allocator, &.{ cwd, ".zig-cache", "tmp", &fixture.tmp.sub_path, "write-fetch.txt" });
        defer fixture.allocator.free(fetch_path);
        const source = try std.fmt.allocPrint(
            fixture.allocator,
            \\let
            \\  text = builtins.toFile "write-text" "write text payload";
            \\  src = builtins.path {{ path = "{s}"; name = "write-src"; }};
            \\  flat = builtins.path {{ path = "{s}"; name = "write-flat"; recursive = false; }};
            \\  fetched = builtins.fetchurl {{ url = "file://{s}"; name = "write-fetch"; }};
            \\  drv = builtins.derivation {{
            \\    name = "write-root";
            \\    system = "x86_64-linux";
            \\    builder = "/bin/sh";
            \\    inherit text src flat fetched;
            \\  }};
            \\in {{ inherit text src flat fetched; drv = drv.drvPath; }}
        ,
            .{ src_path, flat_path, fetch_path },
        );
        defer fixture.allocator.free(source);
        const attrs_id = try fixture.evaluateAttrs(source);

        // Forcing only RECORDS recipes — even in store-writing mode, nothing is
        // written to the daemon eagerly (a forced-but-undemanded derivation must
        // not pollute the store). So no effects yet, and a recipe per producer.
        _ = try fixture.forceAttrText(attrs_id, "text");
        _ = try fixture.forceAttrText(attrs_id, "src");
        _ = try fixture.forceAttrText(attrs_id, "flat");
        _ = try fixture.forceAttrText(attrs_id, "fetched");
        const drv_path = try fixture.forceAttrText(attrs_id, "drv");
        try std.testing.expectEqual(@as(usize, 0), fixture.fake.effectCount());
        const recipes = fixture.ev.store.realization.testAccess().recipeCount();
        try std.testing.expect(recipes >= 5); // text, src, flat, fetched, drv (+ any transitive)

        // Demanding the drv closure materializes it deps-first: every referenced
        // input source is written before the `.drv`, and the recipes are released
        // as they are consumed.
        try fixture.ev.ensureDerivationClosure(drv_path);
        try std.testing.expectEqual(@as(usize, 0), fixture.ev.store.realization.testAccess().recipeCount());
        try std.testing.expectEqual(recipes, fixture.fake.effectCount());

        // The `.drv` itself is written LAST (after its whole reference closure).
        const records = fixture.ev.derivationDebugRecords();
        try std.testing.expectEqual(@as(usize, 1), records.len);
        try expectEffect(fixture.fake, recipes - 1, .text, storePathSubject(drv_path), records[0].drv_aterm, records[0].drv_text_references);
    } else return error.MissingRecipeInspectionApi;
}
