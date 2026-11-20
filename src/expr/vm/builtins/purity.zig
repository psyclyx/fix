//! Pure-evaluation enforcement shared by the filesystem, fetch and pure-guard
//! builtins. In pure eval (Nix's default for flake commands; `--impure` opts
//! out) impure operations are restricted so a flake evaluates the same for
//! everyone: the environment is invisible, reads are confined to the store and
//! the flake's own source, and fetches must be content-locked.
//!
//! Search-path lookups are deliberately *not* gated here: pure eval exposes an
//! empty `builtins.nixPath` (`Engine.ensureBuiltins`), so a `<name>` lookup
//! fails as a catchable "not found" — the shape nixpkgs' `impure-overlays.nix`
//! probe relies on.
//!
//! Every entry point is a no-op when `policy.pure_eval` is false, so callers can
//! invoke them unconditionally on the hot path (the branch folds to nothing when
//! purity is off).

const std = @import("std");
const VM = @import("../context.zig").VM;
const Value = @import("runtime").value.Value;
const vm_trace = @import("../trace.zig");
const corepkgs = @import("../../eval/imports/corepkgs.zig");

pub inline fn pure(self: *const VM) bool {
    return self.policy.pure_eval;
}

/// True when `path` equals `root` or lies beneath it (a `/`-boundary prefix, so
/// `/nix/storex` is not "under" `/nix/store`). A trailing slash on `root` is
/// ignored.
fn under(path: []const u8, root: []const u8) bool {
    const r = if (root.len > 0 and root[root.len - 1] == '/') root[0 .. root.len - 1] else root;
    if (r.len == 0) return false;
    if (!std.mem.startsWith(u8, path, r)) return false;
    return path.len == r.len or path[r.len] == '/';
}

/// In pure eval, confine filesystem reads (`readFile`/`readDir`/`pathExists`/
/// `import`/…) to the store, the flake's own source tree(s), and the synthetic
/// corepkgs sources (`import <nix/fetchurl.nix>` is pure — there is no on-disk
/// file to confine).
pub fn enforceReadPath(self: *VM, path: []const u8) !void {
    if (!self.policy.pure_eval) return;
    if (under(path, self.realization.store_dir)) return;
    if (corepkgs.source(path) != null) return;
    for (self.policy.allowed_path_roots) |root| if (under(path, root)) return;
    return restrict(self, "access to absolute path '{s}' is forbidden in pure evaluation mode (use --impure to allow)", .{path});
}

/// True when `attrs` carries a field that content-locks a fetch.
pub fn attrsHaveLock(self: *VM, attrs: Value) bool {
    if (!attrs.isAttrs()) return false;
    for ([_][]const u8{ "narHash", "rev", "sha256", "hash", "outputHash", "sha512", "sha1", "md5" }) |k| {
        const id = self.intern.intern(k) catch return false;
        if ((self.heap.getAttrValueOpt(attrs.asObjectId(), id) catch null) != null) return true;
    }
    return false;
}

/// Reject an unlocked fetch in pure eval. `locked` is whether the caller has
/// established a content hash/rev for this fetch.
pub fn enforceFetchLocked(self: *VM, locked: bool) !void {
    if (!self.policy.pure_eval or locked) return;
    return restrict(self, "fetching without a pinned hash (narHash/rev/sha256) is not allowed in pure evaluation mode (use --impure to allow)", .{});
}

/// Backs the `pure_guarded` builtin wrapping `builtins.currentSystem` /
/// `currentTime`: the constant in impure eval, an error under pure eval.
pub fn guardedPureValue(self: *VM, value: Value) !Value {
    if (!self.policy.pure_eval) return value;
    return restrict(self, "'builtins.currentSystem'/'currentTime' is not available in pure evaluation mode; take 'system' as an output argument instead (use --impure to allow)", .{});
}

fn restrict(self: *VM, comptime fmt: []const u8, fmt_args: anytype) error{RestrictedInPureEval} {
    if (self.trace) |trace| {
        const message = std.fmt.allocPrint(self.allocator, fmt, fmt_args) catch return error.RestrictedInPureEval;
        defer self.allocator.free(message);
        trace.setMessageIfAbsent(message) catch {};
    }
    return error.RestrictedInPureEval;
}
