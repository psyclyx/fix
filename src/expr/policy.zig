//! Language compatibility and feature policy shared by parsing, compilation,
//! and execution. Keeping one value prevents nested compilers and VMs from
//! silently inheriting only a subset of the evaluator's configuration.

const std = @import("std");
const types = @import("runtime").types;

/// Language-semantic experimental features. Command-line and configuration
/// front ends share these names instead of maintaining a parallel registry.
pub const ExperimentalFeature = enum {
    pipe_operators,
    fetch_tree,
    flakes,
    coerce_integers,

    pub fn fromName(name: []const u8) ?ExperimentalFeature {
        if (std.mem.eql(u8, name, "pipe-operators")) return .pipe_operators;
        if (std.mem.eql(u8, name, "fetch-tree")) return .fetch_tree;
        if (std.mem.eql(u8, name, "flakes")) return .flakes;
        if (std.mem.eql(u8, name, "coerce-integers")) return .coerce_integers;
        return null;
    }
};

pub const ExperimentalFeatures = std.EnumSet(ExperimentalFeature);

/// Compatibility switches named by Lix/Nix deprecated-feature settings.
pub const DeprecatedFeature = enum {
    nul_bytes,
    floor_ceil_corrupt_integers,
    floating_without_zero,
    cr_line_endings,
    or_as_identifier,
    rec_set_merges,
    rec_set_overrides,
    rec_set_dynamic_attrs,
    tokens_no_whitespace,
    nix_path_shadow,

    pub fn fromName(name: []const u8) ?DeprecatedFeature {
        if (std.mem.eql(u8, name, "nul-bytes")) return .nul_bytes;
        if (std.mem.eql(u8, name, "floor-ceil-corrupt-integers")) return .floor_ceil_corrupt_integers;
        if (std.mem.eql(u8, name, "floating-without-zero")) return .floating_without_zero;
        if (std.mem.eql(u8, name, "cr-line-endings")) return .cr_line_endings;
        if (std.mem.eql(u8, name, "or-as-identifier")) return .or_as_identifier;
        if (std.mem.eql(u8, name, "rec-set-merges")) return .rec_set_merges;
        if (std.mem.eql(u8, name, "rec-set-overrides")) return .rec_set_overrides;
        if (std.mem.eql(u8, name, "rec-set-dynamic-attrs")) return .rec_set_dynamic_attrs;
        if (std.mem.eql(u8, name, "tokens-no-whitespace")) return .tokens_no_whitespace;
        if (std.mem.eql(u8, name, "nix-path-shadow")) return .nix_path_shadow;
        return null;
    }
};

pub const DeprecatedFeatures = std.EnumSet(DeprecatedFeature);

pub const LanguagePolicy = struct {
    pipe_operators_enabled: bool = false,
    fetch_tree_enabled: bool = false,
    flakes_enabled: bool = false,
    max_call_depth: u32 = types.default_max_call_depth,
    coerce_integers_enabled: bool = false,
    allow_nul_bytes: bool = false,
    allow_floor_ceil_corrupt: bool = false,
    allow_floating_without_zero: bool = false,
    allow_or_as_identifier: bool = false,
    allow_rec_set_overrides: bool = false,
    allow_rec_set_merges: bool = false,
    allow_rec_set_dynamic_attrs: bool = false,
    allow_cr_line_endings: bool = false,
    allow_tokens_no_whitespace: bool = false,
    allow_nix_path_shadow: bool = false,
    /// Pure evaluation mode (Nix's default for flake commands, `--impure` to
    /// disable). Restricts impure builtins: `getEnv` → "", `<...>`/NIX_PATH and
    /// out-of-tree filesystem reads are forbidden, and fetches must be
    /// content-locked. See `vm/builtins/purity.zig`.
    pure_eval: bool = false,
    /// Extra filesystem roots readable under `pure_eval` (besides the store):
    /// the flake's own source tree(s). Borrowed; owned by the Engine.
    allowed_path_roots: []const []const u8 = &.{},
    /// Write a newly computed `flake.lock` beside a writable flake, as the
    /// `nix` CLI does for flake installables. Off for `builtins.getFlake`
    /// itself, which only locks in memory, as in Nix: evaluating must not
    /// change the source tree (and with it a `path:` flake's hash).
    write_flake_lock: bool = false,

    pub fn applyFeatureSets(
        self: *LanguagePolicy,
        experimental: ExperimentalFeatures,
        deprecated: DeprecatedFeatures,
    ) void {
        self.pipe_operators_enabled = experimental.contains(.pipe_operators);
        self.flakes_enabled = experimental.contains(.flakes);
        self.fetch_tree_enabled = experimental.contains(.fetch_tree) or self.flakes_enabled;
        self.coerce_integers_enabled = experimental.contains(.coerce_integers);
        self.allow_nul_bytes = deprecated.contains(.nul_bytes);
        self.allow_floor_ceil_corrupt = deprecated.contains(.floor_ceil_corrupt_integers);
        self.allow_floating_without_zero = deprecated.contains(.floating_without_zero);
        self.allow_or_as_identifier = deprecated.contains(.or_as_identifier);
        self.allow_rec_set_overrides = deprecated.contains(.rec_set_overrides);
        self.allow_rec_set_merges = deprecated.contains(.rec_set_merges);
        self.allow_rec_set_dynamic_attrs = deprecated.contains(.rec_set_dynamic_attrs);
        self.allow_cr_line_endings = deprecated.contains(.cr_line_endings);
        self.allow_tokens_no_whitespace = deprecated.contains(.tokens_no_whitespace);
        self.allow_nix_path_shadow = deprecated.contains(.nix_path_shadow);
    }
};
