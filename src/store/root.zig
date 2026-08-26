//! Nix store domain: derivation model, source snapshots and NAR encoding,
//! realization recipes, and nix-daemon protocol/runtime.

pub const derivation = @import("derivation.zig");
pub const realization = @import("realization.zig");
pub const file_cache = @import("file_cache.zig");
pub const nar = @import("nar.zig");
pub const daemon = @import("daemon.zig");
pub const daemon_runtime = @import("daemon/runtime.zig");
pub const backend = @import("backend.zig");

pub const FileCache = file_cache.FileCache;
pub const RealizationStore = realization.RealizationStore;
pub const DaemonRuntime = daemon_runtime.DaemonRuntime;
pub const BackendDriver = backend.Driver;

test {
    _ = derivation;
    _ = realization;
    _ = FileCache;
    _ = nar;
    _ = daemon;
    _ = backend;
    _ = DaemonRuntime;
}
