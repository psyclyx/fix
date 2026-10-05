//! Shared data types for the derivation model: outputs, inputs, env vars,
//! hash-modulo (owned + borrowed views), computed paths, debug records, the
//! resolver interface, and the ValueSpec used to build the runtime derivation Value.

const std = @import("std");
const heap_mod = @import("runtime").heap;
const InternId = @import("runtime").types.InternId;
const Value = @import("runtime").value.Value;
// Deep clone/free ownership helpers for these types live in `clone.zig`;
// the struct `deinit` methods below reach the free helpers through it.
const clone = @import("clone.zig");

const AttrEntry = heap_mod.AttrEntry;

pub const ValueOutput = struct {
    name: InternId,
    out_path: InternId,
    /// A declared output the `.drv` doesn't have (`outputs = [ "a b" ]` is
    /// outputs `a` and `b`): its `outPath`, a thunk that fails when forced,
    /// like `getAttr "a b" strict` in Nix's `derivation.nix`.
    missing: ?Value = null,
};

pub const DrvOutput = struct {
    name: []const u8,
    path: []const u8 = "",
    hash_algo: []const u8 = "",
    hash: []const u8 = "",
};

pub const DrvInput = struct {
    path: []const u8,
    outputs: []const []const u8,
};

pub const OutputHash = struct {
    output: []const u8,
    hash: []const u8,
};

pub const HashModulo = union(enum) {
    drv: []u8,
    outputs: []OutputHash,

    pub fn deinit(self: HashModulo, allocator: std.mem.Allocator) void {
        switch (self) {
            .drv => |hash| allocator.free(hash),
            .outputs => |outputs| {
                for (outputs) |output| {
                    allocator.free(output.output);
                    allocator.free(output.hash);
                }
                allocator.free(outputs);
            },
        }
    }

    pub fn view(self: *const HashModulo) HashModuloView {
        return switch (self.*) {
            .drv => |hash| .{ .drv = hash },
            .outputs => |outputs| .{ .outputs = outputs },
        };
    }
};

pub const HashModuloView = union(enum) {
    drv: []const u8,
    outputs: []const OutputHash,
};

pub const DebugHashModuloStep = struct {
    mask_outputs: bool,
    inputs: []DrvInput,
    aterm: ?[]u8,
    hash_modulo: HashModulo,

    pub fn deinit(self: DebugHashModuloStep, allocator: std.mem.Allocator) void {
        clone.freeDrvInputsDeep(allocator, self.inputs);
        if (self.aterm) |aterm| allocator.free(aterm);
        self.hash_modulo.deinit(allocator);
    }
};

pub const DebugRecord = struct {
    name: []u8,
    drv_path: []u8,
    system: []u8,
    builder: []u8,
    args: []const []const u8,
    outputs: []DrvOutput,
    input_drvs: []DrvInput,
    input_srcs: []const []const u8,
    env: []EnvVar,
    drv_aterm: []u8,
    drv_text_hash: []u8,
    drv_text_references: []const []const u8,
    output_hash: DebugHashModuloStep,
    dependency_hash: DebugHashModuloStep,

    pub fn deinit(self: DebugRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.drv_path);
        allocator.free(self.system);
        allocator.free(self.builder);
        clone.freeStringListDeep(allocator, self.args);
        clone.freeDrvOutputsDeep(allocator, self.outputs);
        clone.freeDrvInputsDeep(allocator, self.input_drvs);
        clone.freeStringListDeep(allocator, self.input_srcs);
        clone.freeEnvVarsDeep(allocator, self.env);
        allocator.free(self.drv_aterm);
        allocator.free(self.drv_text_hash);
        clone.freeStringListDeep(allocator, self.drv_text_references);
        self.output_hash.deinit(allocator);
        self.dependency_hash.deinit(allocator);
    }
};

pub const HashModuloResolver = struct {
    store_dir: []const u8,
    context: *anyopaque,
    resolve: *const fn (*anyopaque, []const u8) anyerror!?HashModuloView,

    pub fn resolvePath(self: HashModuloResolver, drv_path: []const u8) !?HashModuloView {
        return self.resolve(self.context, drv_path);
    }
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const ComputedPaths = struct {
    drv_path: []u8,
    hash_modulo: HashModulo,
    /// Exact final ATerm allocation used to derive `drv_path`; caller owns it.
    drv_aterm: []u8,
    /// Slice allocation only; entries borrow from the Drv. Caller owns the slice.
    drv_text_references: []const []const u8,
};

pub const ValueSpec = struct {
    drv_path: InternId,
    default_output: InternId,
    outputs: []const ValueOutput,
    original_attrs: heap_mod.AttrsView,
    /// The outputs as declared, duplicates included, which `all` has one
    /// value for each of (`derivation.nix` maps over them); empty for the
    /// order of `outputs`.
    declared: []const InternId = &.{},
};
