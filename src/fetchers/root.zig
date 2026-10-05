//! Nix source acquisition: filesystem snapshots, remote-source caching,
//! provider conventions, transports, and NAR serialization of fetched trees.

const store = @import("store");

pub const file_cache = store.file_cache;
pub const fetch_cache = @import("fetch_cache.zig");
pub const fetch = struct {
    pub const types = @import("fetch/types.zig");
    pub const config = @import("fetch/config.zig");
};
pub const forge = @import("forge.zig");
pub const nar = store.nar;
pub const http_transport = @import("http_transport.zig");
pub const git_transport = @import("git_transport.zig");
pub const url = @import("url.zig");
pub const flakeref = @import("flakeref.zig");

pub const FileCache = store.FileCache;
pub const FetchService = fetch_cache.FetchCache;
pub const FetchConfig = fetch.config.Config;
pub const GitSpec = fetch.types.GitSpec;
pub const UrlSpec = fetch.types.UrlSpec;
pub const TarballSpec = fetch.types.TarballSpec;
pub const MercurialSpec = fetch.types.MercurialSpec;

test {
    _ = FileCache;
    _ = FetchService;
    _ = forge;
    _ = nar;
    _ = http_transport;
    _ = git_transport;
    _ = url;
    _ = flakeref;
}
