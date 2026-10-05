const std = @import("std");
const derivation = @import("../derivation.zig");
const realization = @import("../realization.zig");
const sort = derivation.sort;
const hash_codec = derivation.hash_codec;
const runtime = @import("runtime");
const daemon = @import("../daemon.zig");
const debug_record_mod = derivation.debug_record;
const types_mod = derivation.types;
const clone_mod = derivation.clone;
const value_mod = derivation.value;

const RealizationStore = realization.RealizationStore;
const Drv = derivation.Drv;
const DrvInput = derivation.DrvInput;
const DrvOutput = derivation.DrvOutput;
const EnvVar = derivation.EnvVar;
const HashModulo = derivation.HashModulo;
const HashModuloResolver = derivation.HashModuloResolver;
const HashModuloView = derivation.HashModuloView;
const OutputHash = derivation.OutputHash;
const ValueOutput = derivation.ValueOutput;
const ValueSpec = derivation.ValueSpec;
const hashToBase16 = derivation.hashToBase16;
const storeDigest = derivation.storeDigest;
const outputPathName = derivation.outputPathName;
const drvPathName = derivation.drvPathName;
const hashAlgorithmSeparator = derivation.hashAlgorithmSeparator;
const sha256Hex = hash_codec.sha256Hex;

const InternTable = runtime.intern.InternTable;
const ObjectHeap = runtime.heap.ObjectHeap;

test "store digest uses Nix base32 alphabet" {
    const hash = storeDigest("text:sha256:fe9b6355b349291bfdd1c43e9972a3f2c8da199edcf10ee1504797e4da267032:/nix/store:pkg.drv");
    try std.testing.expectEqualStrings("s8l8ca4j8fb6d94205514xd6wf9b57ng", &hash);
    for (hash) |char| {
        try std.testing.expect(std.mem.indexOfScalar(u8, "0123456789abcdfghijklmnpqrsvwxyz", char) != null);
    }
}

test "setDaemonSocket overrides the default path and re-set frees the prior owned copy" {
    var store = RealizationStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqualStrings(daemon.default_socket_path, store.daemonSocket());
    try store.setDaemonSocket("/tmp/one.sock");
    try std.testing.expectEqualStrings("/tmp/one.sock", store.daemonSocket());
    // Re-setting must free the prior owned copy (no leak — the testing allocator
    // would flag it) and point at the new one.
    try store.setDaemonSocket("/tmp/two.sock");
    try std.testing.expectEqualStrings("/tmp/two.sock", store.daemonSocket());
    // Empty is a no-op (keeps the current value).
    try store.setDaemonSocket("");
    try std.testing.expectEqualStrings("/tmp/two.sock", store.daemonSocket());
}

test "derivation IR computes minimal Nix paths" {
    var store = RealizationStore.init(std.testing.allocator);
    defer store.deinit();

    var outputs = [_]DrvOutput{.{ .name = "out" }};
    defer if (outputs[0].path.len != 0) std.testing.allocator.free(outputs[0].path);
    var env = [_]EnvVar{
        .{ .name = "builder", .value = "/bin/sh" },
        .{ .name = "name", .value = "pkg" },
        .{ .name = "out", .value = "" },
        .{ .name = "system", .value = "x86_64-linux" },
    };
    var drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &.{},
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &env,
    };

    const paths = try drv.computePaths(std.testing.allocator, store.resolver());
    defer std.testing.allocator.free(paths.drv_path);
    defer paths.hash_modulo.deinit(std.testing.allocator);
    defer std.testing.allocator.free(paths.drv_aterm);
    defer std.testing.allocator.free(paths.drv_text_references);

    try std.testing.expectEqualStrings("/nix/store/s8l8ca4j8fb6d94205514xd6wf9b57ng-pkg.drv", paths.drv_path);
    try std.testing.expectEqualStrings("/nix/store/8w6a3g1mvf8qkz788dysw8k4hmq91cc8-pkg", outputs[0].path);
}

test "output hash parser accepts SRI base64 and Nix base32" {
    const sri = try hashToBase16(std.testing.allocator, "sha256", "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");
    defer std.testing.allocator.free(sri);
    try std.testing.expectEqualStrings("0000000000000000000000000000000000000000000000000000000000000000", sri);

    const unpadded_sri = try hashToBase16(std.testing.allocator, "sha256", "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    defer std.testing.allocator.free(unpadded_sri);
    try std.testing.expectEqualStrings("0000000000000000000000000000000000000000000000000000000000000000", unpadded_sri);

    const nix32 = try hashToBase16(std.testing.allocator, "sha1", "s8l8ca4j8fb6d94205514xd6wf9b57ng");
    defer std.testing.allocator.free(nix32);
    try std.testing.expectEqualStrings("cf9eb292e3a675124a0182a466964392288628d2", nix32);

    const colon_prefixed_nix32 = try hashToBase16(std.testing.allocator, "sha1", "sha1:s8l8ca4j8fb6d94205514xd6wf9b57ng");
    defer std.testing.allocator.free(colon_prefixed_nix32);
    try std.testing.expectEqualStrings("cf9eb292e3a675124a0182a466964392288628d2", colon_prefixed_nix32);
}

test "sortedOutputs leaves an already-sorted list intact" {
    const outputs = [_]DrvOutput{
        .{ .name = "bin" },
        .{ .name = "dev" },
        .{ .name = "out" },
    };
    const sorted = try sort.sortedOutputs(std.testing.allocator, &outputs);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("bin", sorted[0].name);
    try std.testing.expectEqualStrings("dev", sorted[1].name);
    try std.testing.expectEqualStrings("out", sorted[2].name);
}

test "sortedOutputs fully reorders a reverse-sorted list" {
    const outputs = [_]DrvOutput{
        .{ .name = "out" },
        .{ .name = "dev" },
        .{ .name = "bin" },
    };
    const sorted = try sort.sortedOutputs(std.testing.allocator, &outputs);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("bin", sorted[0].name);
    try std.testing.expectEqualStrings("dev", sorted[1].name);
    try std.testing.expectEqualStrings("out", sorted[2].name);
}

test "sortedInputs orders duplicate paths stably by original relative order" {
    // std.mem.sort documents a stable algorithm (preserves relative order
    // of equal elements), so the two "a-dep.drv" entries must keep their
    // original relative order (dev before out) after sorting.
    const inputs = [_]DrvInput{
        .{ .path = "/nix/store/b-dep.drv", .outputs = &.{"out"} },
        .{ .path = "/nix/store/a-dep.drv", .outputs = &.{"dev"} },
        .{ .path = "/nix/store/a-dep.drv", .outputs = &.{"out"} },
    };
    const sorted = try sort.sortedInputs(std.testing.allocator, &inputs);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("/nix/store/a-dep.drv", sorted[0].path);
    try std.testing.expectEqualStrings("/nix/store/a-dep.drv", sorted[1].path);
    try std.testing.expectEqualStrings("/nix/store/b-dep.drv", sorted[2].path);
    try std.testing.expectEqualStrings("dev", sorted[0].outputs[0]);
    try std.testing.expectEqualStrings("out", sorted[1].outputs[0]);
}

test "sortedEnv fully reorders a reverse-sorted list" {
    const env = [_]EnvVar{
        .{ .name = "system", .value = "x86_64-linux" },
        .{ .name = "out", .value = "" },
        .{ .name = "builder", .value = "/bin/sh" },
    };
    const sorted = try sort.sortedEnv(std.testing.allocator, &env);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("builder", sorted[0].name);
    try std.testing.expectEqualStrings("out", sorted[1].name);
    try std.testing.expectEqualStrings("system", sorted[2].name);
}

test "sortedStrings on an already-sorted list is a no-op" {
    const strings = [_][]const u8{ "a", "b", "c" };
    const sorted = try sort.sortedStrings(std.testing.allocator, &strings);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("a", sorted[0]);
    try std.testing.expectEqualStrings("b", sorted[1]);
    try std.testing.expectEqualStrings("c", sorted[2]);
}

test "sortedStrings fully reorders a reverse-sorted list" {
    const strings = [_][]const u8{ "c", "b", "a" };
    const sorted = try sort.sortedStrings(std.testing.allocator, &strings);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("a", sorted[0]);
    try std.testing.expectEqualStrings("b", sorted[1]);
    try std.testing.expectEqualStrings("c", sorted[2]);
}

test "sortedStrings preserves all entries when duplicates are present" {
    const strings = [_][]const u8{ "dup", "a", "dup" };
    const sorted = try sort.sortedStrings(std.testing.allocator, &strings);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("a", sorted[0]);
    try std.testing.expectEqualStrings("dup", sorted[1]);
    try std.testing.expectEqualStrings("dup", sorted[2]);
}

test "sha256Hex matches an independently-computed digest" {
    // Verified via: printf 'hello' | sha256sum
    const digest = try sha256Hex(std.testing.allocator, "hello");
    defer std.testing.allocator.free(digest);
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", digest);
}

test "sha256Hex of the empty string matches the well-known empty digest" {
    // Verified via: printf '' | sha256sum
    const digest = try sha256Hex(std.testing.allocator, "");
    defer std.testing.allocator.free(digest);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", digest);
}

test "hashToBase16 accepts a plain hex digest unchanged" {
    const hex = try hashToBase16(std.testing.allocator, "sha256", "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    defer std.testing.allocator.free(hex);
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hex);
}

test "hashToBase16 rejects a mismatched algorithm prefix" {
    try std.testing.expectError(
        error.InvalidHashAlgorithm,
        hashToBase16(std.testing.allocator, "sha256", "sha1:s8l8ca4j8fb6d94205514xd6wf9b57ng"),
    );
}

test "outputPathName uses the bare derivation name for the default output" {
    const name = try outputPathName(std.testing.allocator, "pkg", "out");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("pkg", name);
}

test "outputPathName suffixes non-default outputs with the output name" {
    const name = try outputPathName(std.testing.allocator, "pkg", "dev");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("pkg-dev", name);
}

test "drvPathName appends the .drv extension" {
    const name = try drvPathName(std.testing.allocator, "pkg");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("pkg.drv", name);
}

test "hashAlgorithmSeparator finds a colon separator" {
    try std.testing.expectEqual(@as(?usize, 4), hashAlgorithmSeparator("sha1:s8l8ca4j8fb6d94205514xd6wf9b57ng"));
}

test "hashAlgorithmSeparator finds a dash separator" {
    try std.testing.expectEqual(@as(?usize, 6), hashAlgorithmSeparator("sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
}

test "hashAlgorithmSeparator picks whichever separator occurs first" {
    // A dash appears before the colon here, so it wins.
    try std.testing.expectEqual(@as(?usize, 4), hashAlgorithmSeparator("sha1-abc:def"));
}

test "hashAlgorithmSeparator returns null when neither separator is present" {
    try std.testing.expectEqual(@as(?usize, null), hashAlgorithmSeparator("s8l8ca4j8fb6d94205514xd6wf9b57ng"));
}

test "toATerm produces valid ATerm syntax with fields in Derive() order" {
    var outputs = [_]DrvOutput{.{ .name = "out", .path = "/nix/store/xxx-pkg", .hash_algo = "", .hash = "" }};
    var env = [_]EnvVar{
        .{ .name = "builder", .value = "/bin/sh" },
        .{ .name = "out", .value = "/nix/store/xxx-pkg" },
    };
    const drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &.{},
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{ "-c", "true" },
        .env = &env,
    };

    const text = try drv.toATerm(std.testing.allocator, false, null);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "Derive("));
    try std.testing.expect(std.mem.endsWith(u8, text, ")"));

    // Field order per the ATerm grammar: outputs, input drvs, input srcs,
    // system, builder, args, env.
    const outputs_pos = std.mem.indexOf(u8, text, "[(\"out\",\"/nix/store/xxx-pkg\",\"\",\"\")]").?;
    const srcs_and_system_pos = std.mem.indexOf(u8, text, "],[],\"x86_64-linux\",\"/bin/sh\"").?;
    const args_pos = std.mem.indexOf(u8, text, "[\"-c\",\"true\"]").?;
    const env_pos = std.mem.indexOf(u8, text, "[(\"builder\",\"/bin/sh\"),(\"out\",\"/nix/store/xxx-pkg\")]").?;

    try std.testing.expect(outputs_pos < srcs_and_system_pos);
    try std.testing.expect(srcs_and_system_pos < args_pos);
    try std.testing.expect(args_pos < env_pos);
}

test "toATerm masks output paths and their matching env values when requested" {
    var outputs = [_]DrvOutput{.{ .name = "out", .path = "/nix/store/xxx-pkg", .hash_algo = "", .hash = "" }};
    var env = [_]EnvVar{.{ .name = "out", .value = "/nix/store/xxx-pkg" }};
    const drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &.{},
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &env,
    };

    const text = try drv.toATerm(std.testing.allocator, true, null);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "Derive("));
    try std.testing.expect(std.mem.indexOf(u8, text, "/nix/store/xxx-pkg") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(\"out\",\"\",\"\",\"\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(\"out\",\"\")") != null);
}

test "toATerm escapes special characters in quoted string values" {
    var outputs = [_]DrvOutput{.{ .name = "out", .path = "", .hash_algo = "", .hash = "" }};
    var env = [_]EnvVar{.{ .name = "script", .value = "echo \"hi\"\n\tnext\\line" }};
    const drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &.{},
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &env,
    };

    const text = try drv.toATerm(std.testing.allocator, false, null);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "echo \\\"hi\\\"\\n\\tnext\\\\line") != null);
}

test "toATerm uses actual_inputs override instead of drv.input_drvs when supplied" {
    var outputs = [_]DrvOutput{.{ .name = "out", .path = "", .hash_algo = "", .hash = "" }};
    var env = [_]EnvVar{};
    const original_inputs = [_]DrvInput{.{ .path = "/nix/store/original.drv", .outputs = &.{"out"} }};
    const override_inputs = [_]DrvInput{.{ .path = "/nix/store/override.drv", .outputs = &.{"out"} }};
    const drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &original_inputs,
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &env,
    };

    const text = try drv.toATerm(std.testing.allocator, false, &override_inputs);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "override.drv") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "original.drv") == null);
}

// --- drv.zig -----------------------------------------------------------

test "isFixedOutput is true only for a single output carrying a hash algo" {
    var one_fixed: [1]DrvOutput = .{.{ .name = "out", .hash_algo = "sha256", .hash = "abc" }};
    var one_plain: [1]DrvOutput = .{.{ .name = "out" }};
    var two_outputs: [2]DrvOutput = .{ .{ .name = "out", .hash_algo = "sha256", .hash = "abc" }, .{ .name = "dev" } };

    var fixed_drv = blankDrv(&one_fixed);
    var plain_drv = blankDrv(&one_plain);
    var multi_drv = blankDrv(&two_outputs);

    try std.testing.expect(fixed_drv.isFixedOutput());
    try std.testing.expect(!plain_drv.isFixedOutput());
    try std.testing.expect(!multi_drv.isFixedOutput());
}

test "textReferences dedupes input drvs and sources while preserving order" {
    var outputs: [1]DrvOutput = .{.{ .name = "out" }};
    const input_drvs = [_]DrvInput{
        .{ .path = "/nix/store/aaa.drv", .outputs = &.{"out"} },
        .{ .path = "/nix/store/bbb.drv", .outputs = &.{"out"} },
        .{ .path = "/nix/store/aaa.drv", .outputs = &.{"out"} },
    };
    const input_srcs = [_][]const u8{ "/nix/store/src-a", "/nix/store/src-a", "/nix/store/src-b" };

    var drv = blankDrv(&outputs);
    drv.input_drvs = &input_drvs;
    drv.input_srcs = &input_srcs;

    const refs = try drv.textReferences(std.testing.allocator);
    defer std.testing.allocator.free(refs);

    try std.testing.expectEqual(@as(usize, 4), refs.len);
    try std.testing.expectEqualStrings("/nix/store/aaa.drv", refs[0]);
    try std.testing.expectEqualStrings("/nix/store/bbb.drv", refs[1]);
    try std.testing.expectEqualStrings("/nix/store/src-a", refs[2]);
    try std.testing.expectEqualStrings("/nix/store/src-b", refs[3]);
}

test "hashModuloInputs merges outputs of repeated input drvs and resolves per-output hashes" {
    // hashModuloInputs is keyed by the *resolved* hash-modulo, not the
    // original drv path (this mirrors Nix's hashDerivationModulo, which
    // substitutes each input drv's own hash before hashing the referrer).
    // A regular (non-fixed-output) input drv resolves to a single `.drv`
    // hash shared by every reference to it, regardless of which outputs
    // are used — so two entries for the same drv path collapse into one
    // merged input. A distinct drv path that happens to resolve to a
    // different hash stays separate.
    var outputs: [1]DrvOutput = .{.{ .name = "out" }};
    const input_drvs = [_]DrvInput{
        .{ .path = "/nix/store/aaa.drv", .outputs = &.{"out"} },
        .{ .path = "/nix/store/aaa.drv", .outputs = &.{"dev"} },
        .{ .path = "/nix/store/bbb.drv", .outputs = &.{"out"} },
    };
    var drv = blankDrv(&outputs);
    drv.input_drvs = &input_drvs;

    var ctx: StubResolverCtx = .{
        .response = .{ .drv = "hash-aaa" },
    };
    const resolver: HashModuloResolver = .{
        .store_dir = "/nix/store",
        .context = &ctx,
        .resolve = StubResolverCtx.resolve,
    };

    const inputs = try drv.hashModuloInputs(std.testing.allocator, resolver);
    defer clone_mod.freeDrvInputsDeep(std.testing.allocator, inputs);

    // Every input_drv resolves to the same stub hash here (the stub ignores
    // drv_path), so all three entries — including "bbb.drv" — merge into
    // a single hash-keyed input carrying the union of referenced outputs.
    try std.testing.expectEqual(@as(usize, 1), inputs.len);
    try std.testing.expectEqualStrings("hash-aaa", inputs[0].path);
    try std.testing.expectEqual(@as(usize, 2), inputs[0].outputs.len);
    try std.testing.expectEqualStrings("out", inputs[0].outputs[0]);
    try std.testing.expectEqualStrings("dev", inputs[0].outputs[1]);
}

test "hashModuloInputs surfaces unknown input derivation and unknown output errors" {
    var outputs: [1]DrvOutput = .{.{ .name = "out" }};
    const missing_drv_input = [_]DrvInput{
        .{ .path = "/nix/store/missing.drv", .outputs = &.{"out"} },
    };
    var missing_drv = blankDrv(&outputs);
    missing_drv.input_drvs = &missing_drv_input;

    var missing_ctx: StubResolverCtx = .{ .response = null };
    const missing_resolver: HashModuloResolver = .{
        .store_dir = "/nix/store",
        .context = &missing_ctx,
        .resolve = StubResolverCtx.resolve,
    };
    try std.testing.expectError(error.UnknownInputDerivation, missing_drv.hashModuloInputs(std.testing.allocator, missing_resolver));

    const unknown_output_input = [_]DrvInput{
        .{ .path = "/nix/store/aaa.drv", .outputs = &.{"missing-output"} },
    };
    var unknown_output_drv = blankDrv(&outputs);
    unknown_output_drv.input_drvs = &unknown_output_input;

    const known_outputs = [_]OutputHash{.{ .output = "out", .hash = "hash-out" }};
    var unknown_ctx: StubResolverCtx = .{ .response = .{ .outputs = &known_outputs } };
    const unknown_resolver: HashModuloResolver = .{
        .store_dir = "/nix/store",
        .context = &unknown_ctx,
        .resolve = StubResolverCtx.resolve,
    };
    try std.testing.expectError(error.UnknownDerivationOutput, unknown_output_drv.hashModuloInputs(std.testing.allocator, unknown_resolver));
}

fn blankDrv(outputs: []DrvOutput) Drv {
    return .{
        .name = "pkg",
        .outputs = outputs,
        .input_drvs = &.{},
        .input_srcs = &.{},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &.{},
    };
}

const StubResolverCtx = struct {
    response: ?HashModuloView,

    fn resolve(context: *anyopaque, drv_path: []const u8) anyerror!?HashModuloView {
        _ = drv_path;
        const self: *StubResolverCtx = @ptrCast(@alignCast(context));
        return self.response;
    }
};

// --- types.zig -----------------------------------------------------------

test "cloneStringListDeep produces independently-owned equal strings" {
    const original = [_][]const u8{ "alpha", "beta" };
    const cloned = try clone_mod.cloneStringListDeep(std.testing.allocator, &original);
    defer clone_mod.freeStringListDeep(std.testing.allocator, cloned);

    try std.testing.expectEqual(@as(usize, 2), cloned.len);
    try std.testing.expectEqualStrings("alpha", cloned[0]);
    try std.testing.expectEqualStrings("beta", cloned[1]);
    try std.testing.expect(cloned[0].ptr != original[0].ptr);
}

test "cloneDrvOutputsDeep and cloneDrvInputsDeep round-trip all fields" {
    const outputs = [_]DrvOutput{.{ .name = "out", .path = "/nix/store/x", .hash_algo = "sha256", .hash = "abc" }};
    const cloned_outputs = try clone_mod.cloneDrvOutputsDeep(std.testing.allocator, &outputs);
    defer clone_mod.freeDrvOutputsDeep(std.testing.allocator, cloned_outputs);
    try std.testing.expectEqualStrings("out", cloned_outputs[0].name);
    try std.testing.expectEqualStrings("/nix/store/x", cloned_outputs[0].path);
    try std.testing.expectEqualStrings("sha256", cloned_outputs[0].hash_algo);
    try std.testing.expectEqualStrings("abc", cloned_outputs[0].hash);

    const inputs = [_]DrvInput{.{ .path = "/nix/store/a.drv", .outputs = &.{ "out", "dev" } }};
    const cloned_inputs = try clone_mod.cloneDrvInputsDeep(std.testing.allocator, &inputs);
    defer clone_mod.freeDrvInputsDeep(std.testing.allocator, cloned_inputs);
    try std.testing.expectEqualStrings("/nix/store/a.drv", cloned_inputs[0].path);
    try std.testing.expectEqual(@as(usize, 2), cloned_inputs[0].outputs.len);
    try std.testing.expectEqualStrings("dev", cloned_inputs[0].outputs[1]);
}

test "cloneEnvVarsDeep and cloneOutputNames round-trip" {
    const env = [_]EnvVar{.{ .name = "out", .value = "/nix/store/x" }};
    const cloned_env = try clone_mod.cloneEnvVarsDeep(std.testing.allocator, &env);
    defer clone_mod.freeEnvVarsDeep(std.testing.allocator, cloned_env);
    try std.testing.expectEqualStrings("out", cloned_env[0].name);
    try std.testing.expectEqualStrings("/nix/store/x", cloned_env[0].value);

    const outputs = [_]DrvOutput{ .{ .name = "out" }, .{ .name = "dev" } };
    const names = try clone_mod.cloneOutputNames(std.testing.allocator, &outputs);
    defer clone_mod.freeOutputNames(std.testing.allocator, names);
    try std.testing.expectEqualStrings("out", names[0]);
    try std.testing.expectEqualStrings("dev", names[1]);
}

test "cloneHashModulo and HashModulo.deinit handle both drv and outputs variants" {
    const drv_view: HashModuloView = .{ .drv = "deadbeef" };
    const cloned_drv = try clone_mod.cloneHashModulo(std.testing.allocator, drv_view);
    try std.testing.expectEqualStrings("deadbeef", cloned_drv.drv);
    cloned_drv.deinit(std.testing.allocator);

    const output_hashes = [_]OutputHash{.{ .output = "out", .hash = "cafe" }};
    const outputs_view: HashModuloView = .{ .outputs = &output_hashes };
    const cloned_outputs = try clone_mod.cloneHashModulo(std.testing.allocator, outputs_view);
    try std.testing.expectEqual(@as(usize, 1), cloned_outputs.outputs.len);
    try std.testing.expectEqualStrings("out", cloned_outputs.outputs[0].output);
    try std.testing.expectEqualStrings("cafe", cloned_outputs.outputs[0].hash);
    cloned_outputs.deinit(std.testing.allocator);
}

// --- store.zig -----------------------------------------------------------

test "record stores hash modulo and outputs retrievable via resolver and outputNames" {
    var store = RealizationStore.init(std.testing.allocator);
    defer store.deinit();

    const outputs = [_]DrvOutput{.{ .name = "out" }};
    try store.record("/nix/store/pkg.drv", .{ .drv = "abc123" }, &outputs);

    const names = store.outputNames("/nix/store/pkg.drv") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("out", names[0]);

    const resolved = try store.resolver().resolvePath("/nix/store/pkg.drv") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("abc123", resolved.drv);

    try std.testing.expect(store.outputNames("/nix/store/missing.drv") == null);
    try std.testing.expect(try store.resolver().resolvePath("/nix/store/missing.drv") == null);
}

test "record is idempotent for a repeated drv_path" {
    var store = RealizationStore.init(std.testing.allocator);
    defer store.deinit();

    const outputs = [_]DrvOutput{.{ .name = "out" }};
    try store.record("/nix/store/pkg.drv", .{ .drv = "first" }, &outputs);
    try store.record("/nix/store/pkg.drv", .{ .drv = "second" }, &outputs);

    const resolved = try store.resolver().resolvePath("/nix/store/pkg.drv") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("first", resolved.drv);
}

test "lazy derivation cache misses on token mismatch (GC id-reuse guard) and hits otherwise" {
    var store = RealizationStore.init(std.testing.allocator);
    defer store.deinit();

    try store.cacheLazyDerivation(7, 1, 0xdeadbeef);

    try std.testing.expectEqual(@as(?u64, 0xdeadbeef), store.lookupLazyDerivation(7, 1));
    try std.testing.expectEqual(@as(?u64, null), store.lookupLazyDerivation(7, 2));
    try std.testing.expectEqual(@as(?u64, null), store.lookupLazyDerivation(8, 1));
}

test "setDebugEnabled(false) clears any accumulated debug records" {
    var store = RealizationStore.init(std.testing.allocator);
    defer store.deinit();

    store.setDebugEnabled(true);
    try std.testing.expect(store.debugEnabled());
    try std.testing.expectEqual(@as(usize, 0), store.debugRecords().len);

    store.setDebugEnabled(false);
    try std.testing.expect(!store.debugEnabled());
    try std.testing.expectEqual(@as(usize, 0), store.debugRecords().len);
}

// --- value.zig -----------------------------------------------------------

test "isSyntheticName recognizes reserved attrs and declared output names but not user attrs" {
    var intern = try InternTable.init(std.testing.allocator);
    defer intern.deinit();

    const out_id = try intern.intern("out");
    const outputs = [_]ValueOutput{.{ .name = out_id, .out_path = out_id }};

    try std.testing.expect(value_mod.isSyntheticName(&intern, "type", &outputs));
    try std.testing.expect(value_mod.isSyntheticName(&intern, "drvAttrs", &outputs));
    try std.testing.expect(value_mod.isSyntheticName(&intern, "out", &outputs));
    try std.testing.expect(!value_mod.isSyntheticName(&intern, "pname", &outputs));
}

test "buildStrictValue exposes drvPath and each output path as plain attrs" {
    var intern = try InternTable.init(std.testing.allocator);
    defer intern.deinit();
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();

    const drv_path = try intern.intern("/nix/store/pkg.drv");
    const out_name = try intern.intern("out");
    const out_path = try intern.intern("/nix/store/pkg-out");

    const spec: ValueSpec = .{
        .drv_path = drv_path,
        .default_output = out_name,
        .outputs = &.{.{ .name = out_name, .out_path = out_path }},
        .original_attrs = .{ .names = &.{}, .values = &.{} },
    };

    const value = try value_mod.buildStrictValue(std.testing.allocator, &intern, &heap, spec);
    const attrs = try heap.materializeAttrs(value.asObjectId());

    try std.testing.expectEqual(@as(usize, 2), attrs.len());
    var found_drv_path = false;
    var found_out = false;
    for (attrs.names, attrs.values) |entry_name, entry_value| {
        // buildStrictValue emits context strings (path values carry string
        // context), not plain interned strings, so extract via
        // getContextString rather than treating the value as an InternId.
        try std.testing.expect(entry_value.isContextString());
        const context_string = try heap.getContextString(entry_value.asObjectId());
        if (entry_name == try intern.intern("drvPath")) {
            found_drv_path = true;
            try std.testing.expectEqualStrings("/nix/store/pkg.drv", intern.get(context_string.text));
        } else if (entry_name == out_name) {
            found_out = true;
            try std.testing.expectEqualStrings("/nix/store/pkg-out", intern.get(context_string.text));
        }
    }
    try std.testing.expect(found_drv_path);
    try std.testing.expect(found_out);
}

// --- debug_record.zig -----------------------------------------------------------

test "debugRecordFromDrv captures aterm hash and text references, freed on deinit" {
    var store = RealizationStore.init(std.testing.allocator);
    defer store.deinit();

    var outputs = [_]DrvOutput{.{ .name = "out" }};
    defer if (outputs[0].path.len != 0) std.testing.allocator.free(outputs[0].path);
    var env = [_]EnvVar{
        .{ .name = "builder", .value = "/bin/sh" },
        .{ .name = "name", .value = "pkg" },
        .{ .name = "out", .value = "" },
        .{ .name = "system", .value = "x86_64-linux" },
    };
    var drv: Drv = .{
        .name = "pkg",
        .outputs = &outputs,
        .input_drvs = &.{},
        .input_srcs = &.{"/nix/store/src-a"},
        .system = "x86_64-linux",
        .builder = "/bin/sh",
        .args = &.{},
        .env = &env,
    };

    const paths = try drv.computePaths(std.testing.allocator, store.resolver());
    defer std.testing.allocator.free(paths.drv_path);
    defer paths.hash_modulo.deinit(std.testing.allocator);
    defer std.testing.allocator.free(paths.drv_aterm);
    defer std.testing.allocator.free(paths.drv_text_references);

    const record = try debug_record_mod.debugRecordFromDrv(std.testing.allocator, &drv, paths.drv_path, store.resolver());
    defer record.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("pkg", record.name);
    try std.testing.expectEqualStrings(paths.drv_path, record.drv_path);
    try std.testing.expectEqual(@as(usize, 1), record.drv_text_references.len);
    try std.testing.expectEqualStrings("/nix/store/src-a", record.drv_text_references[0]);
    try std.testing.expect(record.drv_text_hash.len > 0);
    // output_hash mirrors computePaths' output_hash_modulo (used to derive
    // output paths before they're known, so output paths are masked);
    // dependency_hash mirrors dependency_hash_modulo (the drv's final
    // identity hash handed to downstream consumers, with real output paths).
    try std.testing.expect(record.output_hash.mask_outputs);
    try std.testing.expect(!record.dependency_hash.mask_outputs);
}
