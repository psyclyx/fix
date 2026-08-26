//! Engine-owned builtin values.

const std = @import("std");

/// Language compatibility baseline reported by `builtins.nixVersion` and
/// `fix --version` — not the connected daemon's identity. Keep this value
/// and README's runtime-compatibility note in sync when intentionally
/// moving the emulated language baseline.
pub const nix_compat_version = "2.18.3";
const builtin = @import("builtin");
const InternTable = @import("intern.zig").InternTable;
const heap_mod = @import("heap.zig");
const ObjectHeap = heap_mod.ObjectHeap;
const AttrEntry = heap_mod.AttrEntry;
const Thunk = @import("thunk.zig").Thunk;
const Value = @import("value.zig").Value;

pub const NixPathEntry = struct {
    prefix: []const u8,
    path: []const u8,
};

/// Identifies every builtin the evaluator can invoke. Most variants are
/// user-facing: their enum tag is their `builtins.<name>` spelling in Nix. A
/// handful are evaluator-internal continuations/thunks with no name binding;
/// `publicName` is the canonical visibility boundary.
pub const BuiltinId = enum(u16) {
    toString = 0,
    isAttrs = 1,
    isList = 2,
    isString = 3,
    isInt = 4,
    isBool = 5,
    isNull = 6,
    isFloat = 7,
    isFunction = 8,
    isPath = 9,
    length = 10,
    head = 11,
    tail = 12,
    attrNames = 13,
    attrValues = 14,
    hasAttr = 15,
    getAttr = 16,
    elemAt = 17,
    typeOf = 18,
    concatLists = 19,
    listToAttrs = 20,
    removeAttrs = 21,
    intersectAttrs = 22,
    elem = 23,
    seq = 24,
    all = 25,
    any = 26,
    filter = 27,
    foldlStrict = 28,
    deepSeq = 29,
    pathExists = 30,
    readFile = 31,
    import = 32,
    readDir = 33,
    readFileType = 34,
    findFile = 35,
    map = 36,
    concatMap = 37,
    mapAttrs = 38,
    genList = 39,
    stringLength = 40,
    concatStringsSep = 41,
    substring = 42,
    replaceStrings = 43,
    throw = 44,
    abort = 45,
    tryEval = 46,
    trace = 47,
    derivation = 48,
    derivationStrict = 49,
    storePath = 50,
    path = 51,
    sort = 52,
    partition = 53,
    groupBy = 54,
    genericClosure = 55,
    functionArgs = 56,
    unsafeGetAttrPos = 57,
    add = 58,
    sub = 59,
    mul = 60,
    div = 61,
    lessThan = 62,
    bitAnd = 63,
    bitOr = 64,
    bitXor = 65,
    floor = 66,
    ceil = 67,
    baseNameOf = 68,
    dirOf = 69,
    catAttrs = 70,
    zipAttrsWith = 71,
    hashString = 72,
    hashFile = 73,
    mapAttrValue = 74,
    zipAttrsValue = 75,
    toJSON = 76,
    fromJSON = 77,
    compareVersions = 78,
    splitVersion = 79,
    parseDrvName = 80,
    getEnv = 81,
    fromTOML = 82,
    toXML = 83,
    match = 84,
    split = 85,
    traceVerbose = 86,
    addErrorContext = 87,
    unsafeDiscardStringContext = 88,
    unsafeDiscardOutputDependency = 89,
    addDrvOutputDependencies = 90,
    appendContext = 91,
    getContext = 92,
    hasContext = 93,
    toPath = 94,
    toFile = 95,
    placeholder = 96,
    filterSource = 97,
    scopedImport = 98,
    fetchurl = 99,
    fetchTarball = 100,
    fetchGit = 101,
    fetchMercurial = 102,
    fetchTree = 103,
    getFlake = 104,
    parseFlakeRef = 105,
    flakeRefToString = 106,
    break_ = 107,
    derivationLazyAttr = 108,
    mapValue = 109,
    constantValue = 110,
    /// Internal: lazily resolve one flake input (fetch + evaluate on force).
    /// Args: (ref_attrs, sub_inputs | null, is_flake). Backs each `inputs.<name>`
    /// so unused inputs are never fetched. See vm/builtins/fetch.zig.
    resolve_flake_node = 111,
    /// Internal: compute a fetched tree's NAR hash (SRI) on force. Backs the
    /// `narHash` of a fetched tree under plain eval so the (real, Nix-matching)
    /// hash is only computed when accessed. Args: (tree path, exclude basename |
    /// "" — e.g. ".git"/".hg" to drop the VCS dir). See fetch.zig.
    compute_nar_hash = 112,
    warn = 113,
    /// Internal: force-time pure-eval guard. Backs `builtins.currentSystem` /
    /// `currentTime` — returns its single argument (the constant) in impure
    /// eval, or raises `RestrictedInPureEval` under pure eval. Seeded as a thunk
    /// so the check happens on the forcing VM's policy. Arg: (constant value).
    pure_guarded = 114,
    /// Internal: raise the shallow-history error on force. Backs `revCount`
    /// when the repository's history is truncated but `shallow = true` was not
    /// passed, so the error surfaces only if `revCount` is used, as in Nix.
    /// Arg: (repository url). See fetch.zig.
    shallow_rev_count = 115,
};

/// Public spelling for an id, or null for an evaluator-internal continuation.
/// Nearly every public name is the enum tag; keeping the exceptional spellings
/// here avoids a second full registry that can drift from `BuiltinId`.
pub fn publicName(id: BuiltinId) ?[]const u8 {
    return switch (id) {
        .mapAttrValue,
        .zipAttrsValue,
        .derivationLazyAttr,
        .mapValue,
        .constantValue,
        .resolve_flake_node,
        .compute_nar_hash,
        .pure_guarded,
        .shallow_rev_count,
        => null,
        .foldlStrict => "foldl'",
        .break_ => "break",
        else => @tagName(id),
    };
}

/// Diagnostic spelling for every id, including internal continuations.
pub fn displayName(id: BuiltinId) []const u8 {
    return publicName(id) orelse @tagName(id);
}

const public_builtin_count: usize = count: {
    var count: usize = 0;
    for (std.meta.fields(BuiltinId)) |field| {
        const id: BuiltinId = @enumFromInt(field.value);
        if (publicName(id) != null) count += 1;
    }
    break :count count;
};

const constant_bindings = [_][]const u8{
    "true",
    "false",
    "null",
    "langVersion",
    "storeDir",
    "currentSystem",
    "currentTime",
    "nixVersion",
    "nixPath",
};

pub fn idForName(name: []const u8) ?BuiltinId {
    inline for (std.meta.fields(BuiltinId)) |field| {
        const id: BuiltinId = @enumFromInt(field.value);
        if (publicName(id)) |candidate| {
            if (std.mem.eql(u8, candidate, name)) return id;
        }
    }
    return null;
}

test "public builtin names round-trip from the canonical id" {
    inline for (std.meta.fields(BuiltinId)) |field| {
        const id: BuiltinId = @enumFromInt(field.value);
        if (publicName(id)) |builtin_name| {
            try std.testing.expectEqual(id, idForName(builtin_name).?);
        }
    }
    try std.testing.expectEqualStrings("foldl'", publicName(.foldlStrict).?);
    try std.testing.expectEqualStrings("break", publicName(.break_).?);
    try std.testing.expect(publicName(.mapAttrValue) == null);
}

test "legacy __-prefixed globals mirror Nix's bindings" {
    try std.testing.expectEqual(BuiltinId.elem, ambientIdForName("__elem").?);
    try std.testing.expectEqual(BuiltinId.compareVersions, ambientIdForName("__compareVersions").?);
    try std.testing.expectEqual(BuiltinId.toString, ambientIdForName("toString").?);
    try std.testing.expect(ambientIdForName("__toString") == null);
    try std.testing.expect(ambientIdForName("__import") == null);
    try std.testing.expect(ambientIdForName("__derivation") == null);
    try std.testing.expect(ambientIdForName("elem") == null);
    try std.testing.expectEqual(BuiltinId.break_, ambientIdForName("break").?);
    try std.testing.expect(ambientIdForName("__break") == null);
    try std.testing.expect(ambientIdForName("__derivationStrict") == null);
    try std.testing.expect(hasConstant("__currentSystem"));
    try std.testing.expect(hasConstant("__langVersion"));
    try std.testing.expect(!hasConstant("__true"));
    try std.testing.expect(!hasConstant("__null"));
    try std.testing.expect(!hasConstant("__nope"));
}

/// Nix binds each builtin into the global scope exactly once: the names
/// below unprefixed, every other one under a `__` prefix (`__elem`,
/// `__compareVersions`, ...), the pre-`builtins` spelling.
pub fn ambientIdForName(name: []const u8) ?BuiltinId {
    if (std.mem.startsWith(u8, name, "__")) {
        const id = idForName(name[2..]) orelse return null;
        return if (unprefixedGlobal(id)) null else id;
    }
    const id = idForName(name) orelse return null;
    return if (unprefixedGlobal(id)) id else null;
}

fn unprefixedGlobal(id: BuiltinId) bool {
    return switch (id) {
        .abort,
        .baseNameOf,
        .break_,
        .derivationStrict,
        .derivation,
        .dirOf,
        .fetchGit,
        .fetchMercurial,
        .fetchTarball,
        .fetchTree,
        .fromTOML,
        .import,
        .isNull,
        .map,
        .placeholder,
        .removeAttrs,
        .scopedImport,
        .throw,
        .toString,
        => true,
        else => false,
    };
}

pub fn hasConstant(name: []const u8) bool {
    // `__currentSystem`, `__nixVersion`, ... alongside the existing names;
    // the keyword-like constants (`true`, `false`, `null`) have no `__` form.
    const stripped = if (std.mem.startsWith(u8, name, "__")) name[2..] else name;
    if (stripped.len != name.len) {
        for ([_][]const u8{ "true", "false", "null" }) |keyword| {
            if (std.mem.eql(u8, keyword, stripped)) return false;
        }
    }
    for (constant_bindings) |candidate| {
        if (std.mem.eql(u8, candidate, stripped)) return true;
    }
    return false;
}

pub fn arity(id: BuiltinId) u8 {
    return switch (id) {
        .toString,
        .isAttrs,
        .isList,
        .isString,
        .isInt,
        .isBool,
        .isNull,
        .isFloat,
        .isFunction,
        .isPath,
        .length,
        .head,
        .tail,
        .attrNames,
        .attrValues,
        .typeOf,
        .concatLists,
        .listToAttrs,
        .pathExists,
        .readFile,
        .import,
        .readDir,
        .readFileType,
        .stringLength,
        .throw,
        .abort,
        .tryEval,
        .derivation,
        .derivationStrict,
        .storePath,
        .path,
        .genericClosure,
        .functionArgs,
        .toJSON,
        .fromJSON,
        .splitVersion,
        .parseDrvName,
        .getEnv,
        .fromTOML,
        .toXML,
        .unsafeDiscardStringContext,
        .unsafeDiscardOutputDependency,
        .addDrvOutputDependencies,
        .getContext,
        .hasContext,
        .toPath,
        .placeholder,
        .fetchurl,
        .fetchTarball,
        .fetchGit,
        .fetchMercurial,
        .fetchTree,
        .getFlake,
        .parseFlakeRef,
        .flakeRefToString,
        .break_,
        .constantValue,
        .pure_guarded,
        .floor,
        .ceil,
        .baseNameOf,
        .dirOf,
        .shallow_rev_count,
        => 1,
        .hasAttr,
        .getAttr,
        .elemAt,
        .removeAttrs,
        .intersectAttrs,
        .elem,
        .seq,
        .all,
        .any,
        .filter,
        .deepSeq,
        .findFile,
        .map,
        .concatMap,
        .mapAttrs,
        .genList,
        .concatStringsSep,
        .trace,
        .sort,
        .partition,
        .groupBy,
        .unsafeGetAttrPos,
        .add,
        .sub,
        .mul,
        .div,
        .lessThan,
        .bitAnd,
        .bitOr,
        .bitXor,
        .catAttrs,
        .zipAttrsWith,
        .hashString,
        .hashFile,
        .compareVersions,
        .match,
        .split,
        .traceVerbose,
        .warn,
        .addErrorContext,
        .appendContext,
        .toFile,
        .filterSource,
        .scopedImport,
        .mapValue,
        .derivationLazyAttr,
        .compute_nar_hash,
        => 2,
        .foldlStrict,
        .substring,
        .replaceStrings,
        .mapAttrValue,
        .zipAttrsValue,
        .resolve_flake_node,
        => 3,
    };
}

pub fn buildAttrSet(intern: *InternTable, heap: *ObjectHeap, nix_path: []const NixPathEntry, store_dir: []const u8) !Value {
    var entries: std.ArrayListUnmanaged(AttrEntry) = .empty;
    defer entries.deinit(heap.allocator);
    try entries.ensureTotalCapacity(heap.allocator, public_builtin_count + constant_bindings.len + 1);

    inline for (std.meta.fields(BuiltinId)) |field| {
        const id: BuiltinId = @enumFromInt(field.value);
        if (publicName(id)) |builtin_name| {
            entries.appendAssumeCapacity(try builtinEntry(intern, builtin_name, id));
        }
    }

    entries.appendAssumeCapacity(.{ .name = try intern.intern("true"), .value = Value.boolVal(true) });
    entries.appendAssumeCapacity(.{ .name = try intern.intern("false"), .value = Value.boolVal(false) });
    entries.appendAssumeCapacity(.{ .name = try intern.intern("null"), .value = Value.null_val });
    entries.appendAssumeCapacity(.{ .name = try intern.intern("langVersion"), .value = Value.int(6) });
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("storeDir"),
        .value = Value.string(try intern.intern(store_dir)),
    });
    // `currentSystem` / `currentTime` are impure: wrapped in a force-time guard
    // that raises `RestrictedInPureEval` under pure eval (a flake must take
    // `system` explicitly), and otherwise resolves to the constant.
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("currentSystem"),
        .value = try pureGuardedThunk(heap, Value.string(try intern.intern(hostSystemName()))),
    });
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("currentTime"),
        .value = try pureGuardedThunk(heap, Value.int(0)),
    });
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("nixVersion"),
        .value = Value.string(try intern.intern(nix_compat_version)),
    });
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("nixPath"),
        .value = try buildNixPathValue(intern, heap, nix_path),
    });
    // Self-reference: `builtins.builtins` points back at the attrset we're
    // about to add. Reserve an object slot up front, embed its id in the
    // entries, then fill the slot once we have the AttrRange. This is
    // single-threaded — `Engine.evaluate` calls `ensureBuiltins` before
    // `scheduler.start` — so no other thread can observe the in-flight slot.
    const self_slot = try heap.beginObjectSlot();
    errdefer heap.abortObjectSlot(self_slot);
    entries.appendAssumeCapacity(.{
        .name = try intern.intern("builtins"),
        .value = Value.attrs(self_slot.id),
    });
    const attr_range = try heap.prepareAttrsRange(entries.items);
    const self_id = heap.commitObjectSlot(self_slot, .{ .attrs = .{ .range = attr_range } });
    return Value.attrs(self_id);
}

/// A thunk that resolves through the `pure_guarded` builtin, so forcing it runs
/// the pure-eval check against the forcing VM's policy (see `BuiltinId`).
fn pureGuardedThunk(heap: *ObjectHeap, value: Value) !Value {
    const closure = Value.builtinClosure(try heap.addBuiltinClosure(@intFromEnum(BuiltinId.pure_guarded), &.{value}));
    return Value.thunk(try heap.addThunk(Thunk.init(closure)));
}

fn builtinEntry(intern: *InternTable, builtin_name: []const u8, id: BuiltinId) !AttrEntry {
    return .{
        .name = try intern.intern(builtin_name),
        .value = Value.builtin(@intFromEnum(id)),
    };
}

fn buildNixPathValue(intern: *InternTable, heap: *ObjectHeap, nix_path: []const NixPathEntry) !Value {
    const values = try heap.allocator.alloc(Value, nix_path.len);
    defer heap.allocator.free(values);

    const prefix_id = try intern.intern("prefix");
    const path_id = try intern.intern("path");
    for (nix_path, values) |entry, *value| {
        const attrs = [_]AttrEntry{
            .{
                .name = prefix_id,
                .value = Value.string(try intern.intern(entry.prefix)),
            },
            .{
                .name = path_id,
                .value = Value.string(try intern.intern(entry.path)),
            },
        };
        value.* = Value.attrs(try heap.addAttrs(&attrs));
    }

    return Value.list(try heap.addList(values));
}

pub fn hostSystemName() []const u8 {
    return switch (builtin.target.os.tag) {
        .linux => switch (builtin.target.cpu.arch) {
            .x86_64 => "x86_64-linux",
            .aarch64 => "aarch64-linux",
            .arm => "armv7l-linux",
            .riscv64 => "riscv64-linux",
            else => "unknown-linux",
        },
        .macos => switch (builtin.target.cpu.arch) {
            .x86_64 => "x86_64-darwin",
            .aarch64 => "aarch64-darwin",
            else => "unknown-darwin",
        },
        .freebsd => switch (builtin.target.cpu.arch) {
            .x86_64 => "x86_64-freebsd",
            .aarch64 => "aarch64-freebsd",
            else => "unknown-freebsd",
        },
        else => "unknown",
    };
}
