//! Derivation value construction.
//!
//! Public API surface for derivation IR, hashing, path construction, and
//! evaluator-facing value construction.

const heap_mod = @import("runtime").heap;
const InternTable = @import("runtime").intern.InternTable;
const Value = @import("runtime").value.Value;
pub const types = @import("derivation/types.zig");
pub const drv = @import("derivation/drv.zig");
pub const paths = @import("derivation/paths.zig");
pub const hash_codec = @import("derivation/hash_codec.zig");
pub const value = @import("derivation/value.zig");
pub const debug_record = @import("derivation/debug_record.zig");
pub const clone = @import("derivation/clone.zig");
pub const sort = @import("derivation/sort.zig");
pub const registry = @import("derivation/registry.zig");
pub const Registry = registry.Registry;
const dtypes = types;
const drv_mod = drv;
const path_mod = paths;
const value_builder = value;
const std = @import("std");

/// The one pure store-path name predicate shared by `builtins.path`,
/// `builtins.toFile`, and derivation construction.
pub const store_name = @import("derivation/store_name.zig");

pub const ValueOutput = dtypes.ValueOutput;
pub const DrvOutput = dtypes.DrvOutput;
pub const DrvInput = dtypes.DrvInput;
pub const OutputHash = dtypes.OutputHash;
pub const HashModulo = dtypes.HashModulo;
pub const HashModuloView = dtypes.HashModuloView;
pub const DebugHashModuloStep = dtypes.DebugHashModuloStep;
pub const DebugRecord = dtypes.DebugRecord;
pub const HashModuloResolver = dtypes.HashModuloResolver;
pub const EnvVar = dtypes.EnvVar;
pub const ComputedPaths = dtypes.ComputedPaths;
pub const ValueSpec = dtypes.ValueSpec;

pub const Drv = drv_mod.Drv;
pub const sourcePath = path_mod.sourcePath;
pub const textPath = path_mod.textPath;
pub const fixedOutputPath = path_mod.fixedOutputPath;
pub const outputPathName = path_mod.outputPathName;
pub const drvPathName = path_mod.drvPathName;
pub const hashToBase16 = hash_codec.hashToBase16;
pub const hashAlgorithmSeparator = hash_codec.hashAlgorithmSeparator;
pub const storeDigest = hash_codec.storeDigest;

pub fn buildValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *heap_mod.ObjectHeap,
    spec: ValueSpec,
) !Value {
    return value_builder.buildValue(allocator, intern, heap, spec);
}

pub fn buildStrictValue(
    allocator: std.mem.Allocator,
    intern: *InternTable,
    heap: *heap_mod.ObjectHeap,
    spec: ValueSpec,
) !Value {
    return value_builder.buildStrictValue(allocator, intern, heap, spec);
}

pub const isSyntheticName = value_builder.isSyntheticName;

test {
    _ = hash_codec;
    _ = store_name;
}
