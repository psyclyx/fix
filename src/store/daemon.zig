//! nix-daemon client facade: protocol framing, connections, pooling, build
//! events, and settings.

pub const wire = @import("daemon/wire.zig");
pub const endpoint = @import("daemon/endpoint.zig");
pub const client = @import("daemon/client.zig");
pub const pool = @import("daemon/pool.zig");
pub const build_events = @import("daemon/build_events.zig");
pub const settings = @import("daemon/settings.zig");
pub const backend_adapter = @import("daemon/backend.zig");

const backend = @import("backend.zig");

pub const DaemonStore = client.DaemonStore;
pub const BuildEvent = backend.BuildEvent;
pub const BuildSink = backend.BuildSink;
pub const BuildMode = backend.BuildMode;
pub const BuildSettings = backend.BuildSettings;
pub const Setting = backend.Setting;
pub const MissingPlan = backend.MissingPlan;
pub const default_socket_path = endpoint.default_socket_path;
pub const validateStoreUri = endpoint.validateStoreUri;
pub const DaemonPool = pool.DaemonPool;

test {
    _ = pool;
    _ = endpoint;
    _ = build_events;
    _ = settings;
    _ = backend_adapter;
}
