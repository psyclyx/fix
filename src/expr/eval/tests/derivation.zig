const std = @import("std");
const eval_mod = @import("../../evaluator.zig");
const Engine = eval_mod.Engine;
const Diagnostic = eval_mod.Diagnostic;
const Value = @import("runtime").value.Value;
const path_ops = @import("runtime").paths;
const helpers = @import("../test_helpers.zig");
const renderForTest = helpers.renderForTest;
const renderStrictForTest = helpers.renderStrictForTest;
const renderForTestFromCurrentPath = helpers.renderForTestFromCurrentPath;
const renderXmlForTest = helpers.renderXmlForTest;

test "evaluate minimal derivation builtins" {
    const derivation_type = try renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).type");
    defer std.testing.allocator.free(derivation_type);
    try std.testing.expectEqualStrings("\"derivation\"", derivation_type);

    const strict_attrs = try renderForTest("builtins.attrNames (builtins.derivationStrict { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; })");
    defer std.testing.allocator.free(strict_attrs);
    try std.testing.expectEqualStrings("[ \"drvPath\" \"out\" ]", strict_attrs);

    const named_output = try renderForTest("(builtins.derivation { name = \"pkg\"; outputs = [ \"out\" \"dev\" ]; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).dev.outputName");
    defer std.testing.allocator.free(named_output);
    try std.testing.expectEqualStrings("\"dev\"", named_output);

    const named_output_attrs = try renderForTest("builtins.attrNames (builtins.derivation { name = \"pkg\"; outputs = [ \"out\" \"dev\" ]; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).dev");
    defer std.testing.allocator.free(named_output_attrs);
    try std.testing.expectEqualStrings("[ \"all\" \"builder\" \"dev\" \"drvAttrs\" \"drvPath\" \"name\" \"out\" \"outPath\" \"outputName\" \"outputs\" \"system\" \"type\" ]", named_output_attrs);

    const implicit_outputs = try renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }) ? outputs");
    defer std.testing.allocator.free(implicit_outputs);
    try std.testing.expectEqualStrings("false", implicit_outputs);

    const derivation_laziness = try renderForTest(
        \\builtins.toJSON {
        \\  lazy = (builtins.tryEval (builtins.derivation {
        \\    name = builtins.throw "x";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\  })).success;
        \\  lazyOutPath = (builtins.tryEval (builtins.derivation {
        \\    name = builtins.throw "x";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\  }).outPath).success;
        \\  strict = (builtins.tryEval (builtins.derivationStrict {
        \\    name = builtins.throw "x";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\  })).success;
        \\}
    );
    defer std.testing.allocator.free(derivation_laziness);
    try std.testing.expectEqualStrings("\"{\\\"lazy\\\":true,\\\"lazyOutPath\\\":false,\\\"strict\\\":false}\"", derivation_laziness);

    const all_len = try renderForTest("builtins.length (builtins.derivation { name = \"pkg\"; outputs = [ \"out\" \"dev\" ]; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).all");
    defer std.testing.allocator.free(all_len);
    try std.testing.expectEqualStrings("2", all_len);

    const input_sensitive_paths = try renderForTest(
        \\let
        \\  mkBuilder = builder: builtins.derivation { name = "pkg"; system = "x86_64-linux"; inherit builder; };
        \\  mkHash = hash: builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = hash;
        \\    outputHashAlgo = "sha256";
        \\    outputHashMode = "flat";
        \\  };
        \\in builtins.toJSON {
        \\  builderOutSame = (mkBuilder "/bin/sh").outPath == (mkBuilder "/bin/bash").outPath;
        \\  builderDrvSame = (mkBuilder "/bin/sh").drvPath == (mkBuilder "/bin/bash").drvPath;
        \\  hashOutSame = (mkHash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=").outPath == (mkHash "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=").outPath;
        \\  hashDrvSame = (mkHash "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=").drvPath == (mkHash "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=").drvPath;
        \\}
    );
    defer std.testing.allocator.free(input_sensitive_paths);
    try std.testing.expectEqualStrings("\"{\\\"builderDrvSame\\\":false,\\\"builderOutSame\\\":false,\\\"hashDrvSame\\\":false,\\\"hashOutSame\\\":false}\"", input_sensitive_paths);

    const exact_derivation_paths = try renderForTest(
        \\let
        \\  zero = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        \\  minimal = builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  multi = builtins.derivation { name = "pkg"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  fixed = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = zero;
        \\    outputHashAlgo = "sha256";
        \\    outputHashMode = "flat";
        \\  };
        \\  a = builtins.derivation { name = "a"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  b = builtins.derivation { name = "b"; system = "x86_64-linux"; builder = "/bin/sh"; src = a; };
        \\  structured = builtins.derivation {
        \\    name = "pkg-structured";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    __structuredAttrs = true;
        \\    env = { A = 1; };
        \\  };
        \\  allOutA = builtins.derivation { name = "a"; outputs = [ "out" "dev" ]; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  allOutB = builtins.derivation { name = "b"; system = "x86_64-linux"; builder = "/bin/sh"; src = allOutA.drvPath; };
        \\in builtins.toJSON [
        \\  minimal.drvPath minimal.outPath
        \\  multi.drvPath multi.outPath multi.dev.outPath
        \\  fixed.drvPath fixed.outPath
        \\  b.drvPath b.outPath
        \\  structured.drvPath structured.outPath
        \\  allOutB.drvPath allOutB.outPath
        \\]
    );
    defer std.testing.allocator.free(exact_derivation_paths);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/s8l8ca4j8fb6d94205514xd6wf9b57ng-pkg.drv\\\",\\\"/nix/store/8w6a3g1mvf8qkz788dysw8k4hmq91cc8-pkg\\\",\\\"/nix/store/n9r8k4kqcj2019llzmc59f5258a33dip-pkg.drv\\\",\\\"/nix/store/92ysms3lcbywv6148gql79ab6zkfwcin-pkg\\\",\\\"/nix/store/16898da86iz5v475hj6bcy0r0c36zxq8-pkg-dev\\\",\\\"/nix/store/rbh6cczsi8jvv5bvdwy39j5p4xmn8z34-pkg.drv\\\",\\\"/nix/store/nrakis94lbi82m0f5n8fbkx78l568y4l-pkg\\\",\\\"/nix/store/n2gl5gv2n8980c52hly1c5d95jxyjs3h-b.drv\\\",\\\"/nix/store/4bcpp52bhq3g1l44b927m0s8rnxzgwvl-b\\\",\\\"/nix/store/bmwfaizv61s5jq8ba6n3xzlz3c7znln4-pkg-structured.drv\\\",\\\"/nix/store/8gn7x4yg0pdiklpk9giczxlb4i4gjkk3-pkg-structured\\\",\\\"/nix/store/dy56prsjy94iy9dxqkjg57k0hi5wj3qq-b.drv\\\",\\\"/nix/store/1mxidf53h5j44ypw18jqq3gc2yzcag4c-b\\\"]\"", exact_derivation_paths);

    const duplicate_fixed_inputs = try renderForTest(
        \\let
        \\  dep = url: builtins.derivation {
        \\    name = "same-dep";
        \\    system = "builtin";
        \\    builder = "builtin:fetchurl";
        \\    outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        \\    outputHashAlgo = null;
        \\    outputHashMode = "flat";
        \\    inherit url;
        \\    urls = [ url ];
        \\  };
        \\  a = dep "https://example.com/a";
        \\  b = dep "https://example.com/b";
        \\  parent = builtins.derivation {
        \\    name = "duplicate-fixed-inputs";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    args = [ "-c" "true" ];
        \\    inherit a b;
        \\  };
        \\in builtins.toJSON [ a.drvPath b.drvPath a.outPath b.outPath parent.drvPath parent.outPath ]
    );
    defer std.testing.allocator.free(duplicate_fixed_inputs);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/6qx84nkmqbsgj08x7w3r04jz5703fi7j-same-dep.drv\\\",\\\"/nix/store/06bch28pzp0aw8yg8qp1imzl8158nhp8-same-dep.drv\\\",\\\"/nix/store/rf5miwzgfd7wj1flkm28zrv1isxmqk1s-same-dep\\\",\\\"/nix/store/rf5miwzgfd7wj1flkm28zrv1isxmqk1s-same-dep\\\",\\\"/nix/store/cz51cfz99k3r5rxnl41vczi9axgnrb1h-duplicate-fixed-inputs.drv\\\",\\\"/nix/store/x4ysk6ka96pi60rh59ny7i4lw3wfd16c-duplicate-fixed-inputs\\\"]\"", duplicate_fixed_inputs);

    const derivation_synthetic_env_attrs = try renderForTest(
        \\let
        \\  base = {
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    type = "user-type";
        \\    outputName = "user-outputName";
        \\    outPath = "user-outPath";
        \\    drvPath = "user-drvPath";
        \\    drvAttrs = "user-drvAttrs";
        \\    all = "user-all";
        \\  };
        \\  unstructured = builtins.derivation ({ name = "synthetic-env"; } // base);
        \\  structured = builtins.derivation ({ name = "structured-type-env"; __structuredAttrs = true; } // base);
        \\in builtins.toJSON [
        \\  unstructured.drvPath unstructured.outPath unstructured.type unstructured.drvAttrs.type unstructured.drvAttrs.drvPath
        \\  structured.drvPath structured.outPath structured.type structured.drvAttrs.type structured.drvAttrs.drvPath
        \\]
    );
    defer std.testing.allocator.free(derivation_synthetic_env_attrs);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/7cg97kw06gcw1jj53vqvimpf0scg6z6k-synthetic-env.drv\\\",\\\"/nix/store/ab1lp4jhwyzl8153x5kl88vqjxpsjj6w-synthetic-env\\\",\\\"derivation\\\",\\\"user-type\\\",\\\"user-drvPath\\\",\\\"/nix/store/izgykj0r86cpacqq7mvzpqpp7bgckmqf-structured-type-env.drv\\\",\\\"/nix/store/6s8glb8gq36fkjn9kasrw24bz7ryix20-structured-type-env\\\",\\\"derivation\\\",\\\"user-type\\\",\\\"user-drvPath\\\"]\"", derivation_synthetic_env_attrs);

    const fixed_null_hash_algo = try renderForTest(
        \\let
        \\  flat = builtins.derivation {
        \\    name = "src";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        \\    outputHashAlgo = null;
        \\    outputHashMode = "flat";
        \\  };
        \\  recursive = builtins.derivation {
        \\    name = "src";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        \\    outputHashAlgo = null;
        \\    outputHashMode = "recursive";
        \\  };
        \\in builtins.toJSON [ flat.outPath recursive.outPath ]
    );
    defer std.testing.allocator.free(fixed_null_hash_algo);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/v7fhk503far527r9d9sk8dh2w6c7h695-src\\\",\\\"/nix/store/v1bh6bzphg5c2dc9ck7wdd3g1p6g19vd-src\\\"]\"", fixed_null_hash_algo);

    const fixed_colon_hash_algo = try renderForTest(
        \\let
        \\  pkg = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = "sha256:12g3fcym8184py66fgwahpb9q05dm9r9rbhh4l50yd62gkmifc93";
        \\    outputHashAlgo = null;
        \\    outputHashMode = "recursive";
        \\  };
        \\in builtins.toJSON [ pkg.drvPath pkg.outPath ]
    );
    defer std.testing.allocator.free(fixed_colon_hash_algo);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/v9ighzbjzplkqd9yhp384g44kafzhafp-pkg.drv\\\",\\\"/nix/store/ghq7kh9qwy7jvf05nmzjh3dlyv6b4cv7-pkg\\\"]\"", fixed_colon_hash_algo);

    const fixed_unpadded_sri_hash = try renderForTest(
        \\let
        \\  pkg = builtins.derivation {
        \\    name = "p";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = "sha256-JwtCngkoi9pb0pqIdNgukY8GbG5pUDZvrGAHZqjFOw4";
        \\    outputHashAlgo = null;
        \\    outputHashMode = "flat";
        \\  };
        \\in builtins.toJSON [ pkg.drvPath pkg.outPath ]
    );
    defer std.testing.allocator.free(fixed_unpadded_sri_hash);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/5n8j4sk7pl5fb7bxifx44wbgqynr0xan-p.drv\\\",\\\"/nix/store/aikg27wbvlrblwb21vhqd6k6lqk31nxr-p\\\"]\"", fixed_unpadded_sri_hash);

    const fixed_empty_hash_algo_sri = try renderForTest(
        \\let
        \\  pkg = builtins.derivation {
        \\    name = "empty-algo-sri";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = "sha256-4Y/RQQeN4VTpig8ZyxUpVHwzN8W8ciTBCkSzND8SMbs=";
        \\    outputHashAlgo = "";
        \\    outputHashMode = "flat";
        \\  };
        \\in builtins.toJSON [ pkg.drvPath pkg.outPath ]
    );
    defer std.testing.allocator.free(fixed_empty_hash_algo_sri);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/srzzssay8777dg3ifm829wbfqvylx4i8-empty-algo-sri.drv\\\",\\\"/nix/store/gmy97hacw4bpawimq98pjrldf5qv0fhw-empty-algo-sri\\\"]\"", fixed_empty_hash_algo_sri);

    const fixed_missing_hash_mode = try renderForTest(
        \\let
        \\  pkg = builtins.derivation {
        \\    name = "missing-hash-mode";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        \\    outputHashAlgo = "sha256";
        \\  };
        \\in builtins.toJSON [ pkg.drvPath pkg.outPath ]
    );
    defer std.testing.allocator.free(fixed_missing_hash_mode);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/czbxqk95397lb4h8jjznyszi6xlni10y-missing-hash-mode.drv\\\",\\\"/nix/store/4kmqy9s0k8m72rpxf4hyybq94gd4wgjr-missing-hash-mode\\\"]\"", fixed_missing_hash_mode);

    const fixed_missing_hash_algo = try renderForTest(
        \\let
        \\  dep = builtins.derivation {
        \\    name = "dep";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        \\    outputHashMode = "recursive";
        \\  };
        \\  pkg = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    inherit dep;
        \\  };
        \\in builtins.toJSON [ dep.outPath pkg.outPath ]
    );
    defer std.testing.allocator.free(fixed_missing_hash_algo);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/dpj2vjfs0xvw3hrsasy8lz0aj4fi2ny3-dep\\\",\\\"/nix/store/bqg55j90nmj4nf913dsdh0v8zyicwdz7-pkg\\\"]\"", fixed_missing_hash_algo);

    const core_fetchurl_hash_precedence = try renderForTest(
        \\(import <nix/fetchurl.nix> {
        \\  name = "bash-5.3.tar.gz";
        \\  url = "https://ftpmirror.gnu.org/bash/bash-5.3.tar.gz";
        \\  hash = "sha256-DVzYaWX4aaJs9k9Lcb57lvkKO6iz104n6OnZ1VUPMbo=";
        \\  sha256 = "";
        \\}).outPath
    );
    defer std.testing.allocator.free(core_fetchurl_hash_precedence);
    try std.testing.expectEqualStrings("\"/nix/store/kwm524zjlnnq4yfhhmb5r14f2wxf8a2j-bash-5.3.tar.gz\"", core_fetchurl_hash_precedence);

    const to_file_churns_intern_table = try renderForTest(
        \\builtins.unsafeDiscardStringContext (builtins.toFile "payload.txt"
        \\  (builtins.concatStringsSep "" (builtins.genList (n: builtins.toString n) 3000)))
    );
    defer std.testing.allocator.free(to_file_churns_intern_table);
    try std.testing.expect(std.mem.endsWith(u8, to_file_churns_intern_table, "-payload.txt\""));

    var missing_hash_algo_ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer missing_hash_algo_ev.deinit();
    try std.testing.expectError(
        error.InvalidHashAlgorithm,
        missing_hash_algo_ev.evaluate(
            \\(builtins.derivation {
            \\  name = "src";
            \\  system = "x86_64-linux";
            \\  builder = "/bin/sh";
            \\  outputHash = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
            \\  outputHashAlgo = null;
            \\  outputHashMode = "flat";
            \\}).outPath
        ),
    );

    const stable_context_inputs = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  churn = builtins.concatStringsSep "" (builtins.genList (n: "long-derivation-input-context-${builtins.toString n}") 4096);
        \\  pkg = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    args = [ dep.outPath churn dep.outPath ];
        \\  };
        \\in builtins.isString pkg.outPath
    );
    defer std.testing.allocator.free(stable_context_inputs);
    try std.testing.expectEqualStrings("true", stable_context_inputs);

    const structured_derivation_input = try renderForTest(
        \\let
        \\  dep = builtins.derivation { name = "dep"; system = "x86_64-linux"; builder = "/bin/sh"; };
        \\  pkg = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    __structuredAttrs = true;
        \\    env = {
        \\      dep = dep;
        \\      nested = { also = dep; };
        \\    };
        \\  };
        \\in builtins.isString pkg.outPath
    );
    defer std.testing.allocator.free(structured_derivation_input);
    try std.testing.expectEqualStrings("true", structured_derivation_input);

    const structured_explicit_outputs = try renderForTest(
        \\let
        \\  pkg = builtins.derivation {
        \\    name = "pkg-structured";
        \\    outputs = [ "out" "debug" ];
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    __structuredAttrs = true;
        \\    env = { A = 1; };
        \\  };
        \\in builtins.toJSON [ pkg.drvPath pkg.outPath pkg.debug.outPath ]
    );
    defer std.testing.allocator.free(structured_explicit_outputs);
    try std.testing.expectEqualStrings("\"[\\\"/nix/store/5nkc970vb573fs2ppl4vflsymcrri8dn-pkg-structured.drv\\\",\\\"/nix/store/j9jfd9axp7wyhrx9mg088db3iw19dkyw-pkg-structured\\\",\\\"/nix/store/470amnhnd10jpqrh3im85xr0bicjb8rm-pkg-structured-debug\\\"]\"", structured_explicit_outputs);

    var recursive_structured_ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer recursive_structured_ev.deinit();
    try std.testing.expectError(
        error.RecursiveThunk,
        recursive_structured_ev.evaluate(
            \\let
            \\  loop = rec { self = loop; };
            \\in (builtins.derivation {
            \\  name = "pkg";
            \\  system = "x86_64-linux";
            \\  builder = "/bin/sh";
            \\  __structuredAttrs = true;
            \\  env = loop;
            \\}).outPath
        ),
    );

    const semantic_paths = try renderForTest(
        \\let
        \\  mk = value: builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; inherit value; };
        \\  mkMeta = meta: builtins.derivation { name = "pkg"; system = "x86_64-linux"; builder = "/bin/sh"; inherit meta; };
        \\  mkStructured = value: builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    __structuredAttrs = true;
        \\    env = { A = value; };
        \\  };
        \\in builtins.toJSON {
        \\  drvPathLength = builtins.stringLength (mk "x").drvPath;
        \\  listStringSame = (mk [ 1 true null ]).outPath == (mk "1  ").outPath;
        \\  emptyListElementSame = (mk [ "a" [ ] "b" ]).outPath == (mk "a b").outPath;
        \\  metaSame = (mkMeta 1).outPath == (mkMeta 2).outPath;
        \\  structuredIntStringSame = (mkStructured 1).outPath == (mkStructured "1").outPath;
        \\  unstructuredIntStringSame = (mk 1).outPath == (mk "1").outPath;
        \\}
    );
    defer std.testing.allocator.free(semantic_paths);
    try std.testing.expectEqualStrings("\"{\\\"drvPathLength\\\":51,\\\"emptyListElementSame\\\":true,\\\"listStringSame\\\":false,\\\"metaSame\\\":false,\\\"structuredIntStringSame\\\":false,\\\"unstructuredIntStringSame\\\":true}\"", semantic_paths);

    const structured_ignore_nulls_reintern = try renderForTest(
        \\let
        \\  churn = builtins.concatStringsSep "" (builtins.genList (n: builtins.toString n) 4096);
        \\  pkg = builtins.derivation {
        \\    name = "pkg";
        \\    system = "x86_64-linux";
        \\    builder = "/bin/sh";
        \\    __structuredAttrs = true;
        \\    __ignoreNulls = true;
        \\    keep = "value";
        \\    skip = builtins.seq churn null;
        \\  };
        \\in builtins.stringLength pkg.drvPath == 51
    );
    defer std.testing.allocator.free(structured_ignore_nulls_reintern);
    try std.testing.expectEqualStrings("true", structured_ignore_nulls_reintern);

    const drv_attrs = try renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; args = [ 1 true null ]; __structuredAttrs = true; env = { A = 1; }; }).drvAttrs.env.A");
    defer std.testing.allocator.free(drv_attrs);
    try std.testing.expectEqualStrings("1", drv_attrs);

    const preserved_int = try renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; version = 1; }).version");
    defer std.testing.allocator.free(preserved_int);
    try std.testing.expectEqualStrings("1", preserved_int);

    const preserved_args = try renderForTest("builtins.head (builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; args = [ 1 ./foo ]; }).args");
    defer std.testing.allocator.free(preserved_args);
    try std.testing.expectEqualStrings("1", preserved_args);
}

test "deeply nested derivation argument values evaluate" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "let deep = ");
    for (0..2000) |_| try source.appendSlice(std.testing.allocator, "[ ");
    try source.append(std.testing.allocator, '1');
    for (0..2000) |_| try source.appendSlice(std.testing.allocator, " ]");
    try source.appendSlice(std.testing.allocator,
        \\; in (builtins.derivation {
        \\  name = "d";
        \\  system = "x86_64-linux";
        \\  builder = ":";
        \\  attr = deep;
        \\}).drvPath
    );
    _ = try ev.evaluate(source.items);
}

test "derivation builtin rejects self-referential argument values" {
    var list_ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer list_ev.deinit();
    try std.testing.expectError(
        error.CallDepthExceeded,
        list_ev.evaluate(
            \\let r = [ r ];
            \\in (builtins.derivation {
            \\  name = "d";
            \\  system = "x86_64-linux";
            \\  builder = ":";
            \\  attr = r;
            \\}).drvPath
        ),
    );

    var attrs_ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer attrs_ev.deinit();
    try std.testing.expectError(
        error.CallDepthExceeded,
        attrs_ev.evaluate(
            \\let r = { outPath = r; };
            \\in (builtins.derivation {
            \\  name = "d";
            \\  system = "x86_64-linux";
            \\  builder = ":";
            \\  attr = r;
            \\}).drvPath
        ),
    );
}

test "derivation builtin rejects missing required attrs" {
    try std.testing.expectError(
        error.MissingAttribute,
        renderForTest("(builtins.derivation { system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).outPath"),
    );
    try std.testing.expectError(
        error.MissingAttribute,
        renderForTest("(builtins.derivation { name = \"pkg\"; builder = \"/bin/sh\"; }).outPath"),
    );
    try std.testing.expectError(
        error.MissingAttribute,
        renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; }).outPath"),
    );
}

test "derivation builtin rejects wrong-typed required attrs" {
    try std.testing.expectError(
        error.TypeError,
        renderForTest("(builtins.derivation { name = 1; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }).outPath"),
    );
    try std.testing.expectError(
        error.TypeError,
        renderForTest("(builtins.derivation { name = \"pkg\"; system = { }; builder = \"/bin/sh\"; }).outPath"),
    );
    try std.testing.expectError(
        error.TypeError,
        renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = { }; }).outPath"),
    );
    try std.testing.expectError(
        error.TypeError,
        renderForTest("builtins.derivation \"not-an-attrset\""),
    );
    try std.testing.expectError(
        error.TypeError,
        renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; args = \"not-a-list\"; }).outPath"),
    );
}

test "derivation builtin rejects invalid outputs list" {
    try std.testing.expectError(
        error.InvalidDerivationOutput,
        renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; outputs = [ ]; }).outPath"),
    );
    try std.testing.expectError(
        error.InvalidDerivationOutput,
        renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; outputs = [ \"\" ]; }).outPath"),
    );
    try std.testing.expectError(
        error.TypeError,
        renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; outputs = [ 1 ]; }).outPath"),
    );
    try std.testing.expectError(
        error.TypeError,
        renderForTest("(builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; outputs = \"out\"; }).outPath"),
    );
}

test "derivation builtin rejects invalid hash mode and multi-output fixed hash" {
    try std.testing.expectError(
        error.InvalidHashMode,
        renderForTest(
            \\(builtins.derivation {
            \\  name = "src";
            \\  system = "x86_64-linux";
            \\  builder = "/bin/sh";
            \\  outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
            \\  outputHashAlgo = "sha256";
            \\  outputHashMode = "bogus";
            \\}).outPath
        ),
    );
    try std.testing.expectError(
        error.InvalidDerivationOutput,
        renderForTest(
            \\(builtins.derivation {
            \\  name = "src";
            \\  system = "x86_64-linux";
            \\  builder = "/bin/sh";
            \\  outputs = [ "out" "dev" ];
            \\  outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
            \\  outputHashAlgo = "sha256";
            \\  outputHashMode = "flat";
            \\}).outPath
        ),
    );
    try std.testing.expectError(
        error.TypeError,
        renderForTest(
            \\(builtins.derivation {
            \\  name = "src";
            \\  system = "x86_64-linux";
            \\  builder = "/bin/sh";
            \\  outputHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
            \\  outputHashAlgo = "sha256";
            \\  outputHashMode = [ "flat" ];
            \\}).outPath
        ),
    );
}

test "derivationStrict rejects non-attrset argument" {
    try std.testing.expectError(error.TypeError, renderForTest("builtins.derivationStrict 1"));
    try std.testing.expectError(error.TypeError, renderForTest("builtins.derivationStrict [ ]"));
}
