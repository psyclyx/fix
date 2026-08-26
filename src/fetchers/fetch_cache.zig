//! Engine-owned network/source fetch cache.
//!
//! Fetching is isolated here for the same reason filesystem I/O is isolated in
//! FileCache: builtin implementations should describe Nix semantics, while this
//! module owns host effects, caching, and subprocess boundaries.

const std = @import("std");
const nix_hash = @import("runtime").hash;
const store = @import("store");
const nar = store.nar;
const FileCache = store.FileCache;
const clock = @import("base").clock;
const sync = @import("base").sync;
const curl_transport = @import("curl_transport.zig");
const git_transport = @import("git_transport.zig");
const BlockingPool = @import("base").BlockingPool;
const fetch_types = @import("fetch/types.zig");
const fetch_config = @import("fetch/config.zig");
const auth_mod = @import("fetch/auth.zig");

/// Download-staging cache under `$XDG_CACHE_HOME/fix` (default `~/.cache/fix`,
/// mirroring Nix's `~/.cache/nix`; falls back to `./.zig-cache/fix` when the
/// environment is unset). This is only a place to land downloads before they
/// are hashed/added to the real store — never a substitute for `/nix/store`.
///
/// Mutable remote sources are reused for `tarball-ttl` seconds. URL downloads
/// are hashed while streaming and published atomically under that hash. The
/// index records the published file's size, making an unchanged hit a
/// metadata-only check; legacy entries are re-hashed once before reuse.
/// Explicit generation markers (not filesystem mtimes) age objects for GC.
pub const FetchCache = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io,
    /// Download-cache root (owned). Set to `$XDG_CACHE_HOME/fix` (default
    /// `~/.cache/fix`), mirroring Nix's `~/.cache/nix`. When unset (e.g. tests
    /// that never call `setEnvironment`) it falls back to `./.zig-cache/fix`.
    cache_root: ?[]u8 = null,
    /// Max concurrent fetches (`http-connections`; 0 = unlimited). A nonzero
    /// value owns exactly this many long-lived blocking workers; unlimited
    /// mode intentionally creates work on demand.
    max_connections: u32 = 0,
    fetch_pool: ?*BlockingPool = null,
    fetch_pool_mu: sync.BlockingMutex = .{},
    /// `download-attempts` (nix default 5): how many times to try a download
    /// before giving up, retrying only transient failures (connection errors,
    /// timeouts, and 5xx responses).
    download_attempts: u32 = 5,
    /// Freshness window shared by URL, Git, and Mercurial sources.
    tarball_ttl: u32 = 3600,
    connect_timeout_seconds: u32 = 15,
    stalled_timeout_seconds: u32 = 300,
    download_speed_kib: u64 = 0,
    ssl_cert_file: ?[]u8 = null,
    flake_registry_url: ?[]u8 = null,
    /// Same-process single-flight for mutable source refreshes. Stripes keep
    /// the structure fixed-size while ensuring identical URLs cannot race.
    fetch_locks: [64]sync.BlockingMutex = @splat(.{}),
    /// Opportunistic URL/tarball-cache pruning runs at most once per process.
    cache_prune_mu: sync.BlockingMutex = .{},
    cache_pruned: bool = false,
    auth: auth_mod.Auth,
    /// The process environment (borrowed), inherited by tar and Mercurial
    /// subprocesses and consulted by the in-process transports.
    env: ?*const std.process.Environ.Map = null,
    /// Lazily-built subprocess environment = `env` plus:
    ///   - `HGPLAIN=` — consistent `hg` output, ignoring a user/system `.hgrc`,
    ///     exactly as Nix's mercurial fetcher (`hgOptions`).
    /// Both are harmless to the unrelated subprocesses sharing this map.
    /// Built on first subprocess run (most evals never fetch); freed in deinit.
    subprocess_env: ?std.process.Environ.Map = null,

    pub const Forge = fetch_types.Forge;

    const command_stderr_limit = 512 * 1024;
    pub const GitSpec = fetch_types.GitSpec;
    pub const UrlSpec = fetch_types.UrlSpec;
    pub const TarballSpec = fetch_types.TarballSpec;
    pub const MercurialSpec = fetch_types.MercurialSpec;
    pub const Reporter = fetch_types.Reporter;
    pub const UrlResult = fetch_types.UrlResult;
    pub const TarballNar = fetch_types.TarballNar;
    pub const TarballResult = fetch_types.TarballResult;
    pub const ForgeMetadata = fetch_types.ForgeMetadata;
    pub const GitResult = fetch_types.GitResult;
    pub const MercurialResult = fetch_types.MercurialResult;
    pub const Config = fetch_config.Config;

    pub fn init(allocator: std.mem.Allocator, config: Config) !FetchCache {
        var service: FetchCache = .{
            .allocator = allocator,
            .io = config.io,
            .auth = auth_mod.Auth.init(allocator),
        };
        errdefer service.deinit();

        service.download_attempts = @max(1, config.download_attempts);
        service.tarball_ttl = config.tarball_ttl;
        service.connect_timeout_seconds = config.connect_timeout_seconds;
        service.stalled_timeout_seconds = config.stalled_timeout_seconds;
        service.download_speed_kib = config.download_speed_kib;
        if (config.environment) |environment| try service.setEnvironment(environment);
        if (config.cache_root) |root| try service.setCacheRoot(root);
        if (config.ssl_cert_file) |path| try service.setSslCertFile(path);
        try service.setFlakeRegistryUrl(config.flake_registry_url);
        if (config.access_tokens) |tokens| try service.setAccessTokens(tokens);
        if (config.netrc) |netrc| try service.setNetrc(netrc);
        try service.setMaxConnections(config.max_connections);
        return service;
    }

    pub fn deinit(self: *FetchCache) void {
        if (self.fetch_pool) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }
        if (self.cache_root) |root| self.allocator.free(root);
        if (self.ssl_cert_file) |path| self.allocator.free(path);
        if (self.flake_registry_url) |url| self.allocator.free(url);
        self.auth.deinit();
        if (self.subprocess_env) |*e| e.deinit();
    }

    pub fn setNetrc(self: *FetchCache, content: []const u8) !void {
        return self.auth.setNetrc(content);
    }

    fn netrcHeader(self: *const FetchCache, url: []const u8) !?AuthHeader {
        return self.auth.netrcHeader(url);
    }

    pub fn setIo(self: *FetchCache, io: std.Io) void {
        self.io = io;
    }

    /// Set the process environment inherited by tar/hg subprocesses and used
    /// to derive proxy/TLS settings for libcurl and libgit2.
    pub fn setEnvironment(self: *FetchCache, env: *const std.process.Environ.Map) !void {
        // Derive every owned field before disturbing the live environment.
        // Absence in the replacement environment deliberately clears a prior
        // environment-derived certificate.
        const ca = env.get("NIX_SSL_CERT_FILE") orelse env.get("SSL_CERT_FILE");
        const replacement_ca = if (ca) |path|
            if (path.len != 0) try self.allocator.dupe(u8, path) else null
        else
            null;

        if (self.subprocess_env) |*e| { // rebuild lazily on next use
            e.deinit();
            self.subprocess_env = null;
        }
        if (self.ssl_cert_file) |old| self.allocator.free(old);
        self.ssl_cert_file = replacement_ca;
        self.env = env;
    }

    /// The environment for a tar/hg subprocess: the inherited process env
    /// plus `HGPLAIN=`. Built once and cached. Null
    /// (inherit the parent env unchanged) when no environment was set (tests).
    fn subprocessEnviron(self: *FetchCache) !?*const std.process.Environ.Map {
        if (self.subprocess_env) |*e| return e;
        const parent = self.env orelse return null;
        var env = std.process.Environ.Map.init(self.allocator);
        errdefer env.deinit();
        for (parent.keys(), parent.values()) |k, v| try env.put(k, v);
        try env.put("HGPLAIN", "");
        if (self.ssl_cert_file) |path| try env.put("SSL_CERT_FILE", path);
        self.subprocess_env = env;
        return &self.subprocess_env.?;
    }

    pub fn setAccessTokens(self: *FetchCache, raw: []const u8) !void {
        return self.auth.setAccessTokens(raw);
    }

    /// Split `url` into its host (authority without `user@`/`:port`) and path.
    fn urlHostPath(url: []const u8) auth_mod.UrlHostPath {
        return auth_mod.urlHostPath(url);
    }

    /// The access token for a request to `url`, matched by the longest
    /// `<host>[/<path>]` key that is a prefix of the URL's `host/path` (so
    /// `github.com/org` beats a bare `github.com`). Null if none matches.
    fn tokenFor(self: *const FetchCache, url: []const u8) ?[]const u8 {
        return self.auth.tokenFor(url);
    }

    pub const AuthHeader = auth_mod.Header;

    /// Build the `access-tokens` auth header for a `forge` request to `url`, per
    /// Nix's per-forge conventions (`libfetchers/github.cc:accessHeaderFromToken`):
    ///   - github:    `Authorization: token <tok>`
    ///   - sourcehut: `Authorization: Bearer <tok>`
    ///   - gitlab:    token is `<type>:<value>`; `OAuth2:` → `Authorization:
    ///     Bearer <value>`, `PAT:` → `Private-token: <value>`, any other type →
    ///     header `<type>: <value>` (a bare, colon-less token yields the Nix
    ///     degenerate `<token>:` empty-value header). Null if no token matches.
    fn authHeader(self: *const FetchCache, forge: Forge, url: []const u8) !?AuthHeader {
        return self.auth.forgeHeader(forge, url);
    }

    /// Set the concurrent-fetch cap (`http-connections`; 0 = unlimited).
    pub fn setMaxConnections(self: *FetchCache, n: u32) !void {
        const replacement: ?*BlockingPool = if (n == 0) null else blk: {
            const pool = try self.allocator.create(BlockingPool);
            pool.* = BlockingPool.init(self.allocator, n);
            break :blk pool;
        };

        const old = self.fetch_pool;
        self.fetch_pool = replacement;
        self.max_connections = n;
        if (old) |pool| {
            pool.deinit();
            self.allocator.destroy(pool);
        }
    }

    /// Set `download-attempts` (total tries per download; clamped to >= 1).
    pub fn setDownloadAttempts(self: *FetchCache, n: u32) void {
        self.download_attempts = @max(1, n);
    }

    pub fn setTarballTtl(self: *FetchCache, seconds: u32) void {
        self.tarball_ttl = seconds;
    }

    pub fn setConnectTimeout(self: *FetchCache, seconds: u32) void {
        self.connect_timeout_seconds = seconds;
    }

    pub fn setStalledDownloadTimeout(self: *FetchCache, seconds: u32) void {
        self.stalled_timeout_seconds = seconds;
    }

    pub fn setDownloadSpeed(self: *FetchCache, kib_per_second: u64) void {
        self.download_speed_kib = kib_per_second;
    }

    pub fn setSslCertFile(self: *FetchCache, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        if (self.ssl_cert_file) |old| self.allocator.free(old);
        self.ssl_cert_file = owned;
        if (self.subprocess_env) |*environment| {
            environment.deinit();
            self.subprocess_env = null;
        }
    }

    pub fn setFlakeRegistryUrl(self: *FetchCache, url: ?[]const u8) !void {
        const owned = if (url) |value| try self.allocator.dupe(u8, value) else null;
        if (self.flake_registry_url) |old| self.allocator.free(old);
        self.flake_registry_url = owned;
    }

    pub fn globalRegistrySpec(self: *const FetchCache) ?UrlSpec {
        const url = self.flake_registry_url orelse return null;
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return null;
        return .{ .url = url, .name = "flake-registry.json" };
    }

    pub fn globalRegistryPath(self: *const FetchCache) ?[]const u8 {
        const path = self.flake_registry_url orelse return null;
        if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) return null;
        return if (std.mem.startsWith(u8, path, "file://")) path["file://".len..] else path;
    }

    pub fn blockingPool(self: *FetchCache) ?*BlockingPool {
        const pool = self.fetch_pool orelse return null;
        self.fetch_pool_mu.lock();
        defer self.fetch_pool_mu.unlock();
        if (!pool.started) pool.start() catch return null;
        return pool;
    }

    /// Set the download-cache root (duped/owned). See `cache_root`.
    pub fn setCacheRoot(self: *FetchCache, root: []const u8) !void {
        const owned = try self.allocator.dupe(u8, root);
        if (self.cache_root) |old| self.allocator.free(old);
        self.cache_root = owned;
        self.cache_pruned = false;
    }

    /// The download-cache root: the configured `cache_root`, else
    /// `<cwd>/.zig-cache/fix` as a fallback (caller frees).
    fn cacheRootDir(self: *FetchCache, io: std.Io) ![]u8 {
        if (self.cache_root) |root| return self.allocator.dupe(u8, root);
        const cwd = try std.process.currentPathAlloc(io, self.allocator);
        defer self.allocator.free(cwd);
        return std.fs.path.join(self.allocator, &.{ cwd, ".zig-cache", "fix" });
    }

    pub fn fetchGit(self: *FetchCache, files: *FileCache, spec: GitSpec, reporter: ?Reporter) !GitResult {
        if (localFetchPath(spec.url)) |path| {
            return self.localGit(files, path, spec);
        }
        return self.remoteGit(files, spec, reporter);
    }

    pub fn fetchUrl(self: *FetchCache, files: *FileCache, spec: UrlSpec, reporter: ?Reporter) !UrlResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        if (localFetchPath(spec.url)) |local_path| {
            const body = try files.readFile(local_path);
            const hash = try nix_hash.hashBytes(self.allocator, "sha256", body);
            errdefer self.allocator.free(hash);
            const generation = std.Io.Clock.real.now(io).toSeconds();
            try self.noteUrlGeneration(io, hash, generation);
            const path = try self.urlCachePath(io, spec.name, hash);
            errdefer self.allocator.free(path);
            try self.publishBytes(io, path, body);
            return .{ .path = path, .hash = hash };
        }
        return self.fetchRemoteUrl(io, spec, reporter);
    }

    pub fn fetchTarball(self: *FetchCache, files: *FileCache, spec: TarballSpec, reporter: ?Reporter) !TarballResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        var all_cached = true;
        var forge_metadata = if (spec.resolved_rev) |rev|
            try self.forgeMetadataForRev(rev, 0)
        else if (spec.metadata_url) |url| metadata: {
            const forge = spec.forge orelse break :metadata null;
            const response = try self.fetchUrl(files, .{
                .url = url,
                .name = "forge-commit.json",
                .forge = forge,
                .auth_url = spec.url,
            }, reporter);
            defer response.deinit(self.allocator);
            all_cached = response.cached;
            break :metadata if (forge == .sourcehut)
                try self.parseSourcehutMetadata(files, response.path, spec.metadata_ref orelse "HEAD", spec.metadata_head_url, spec.url, reporter)
            else
                try self.parseForgeMetadata(files, forge, response.path);
        } else null;
        errdefer if (forge_metadata) |metadata| metadata.deinit(self.allocator);
        const resolved_url = if (forge_metadata) |metadata|
            if (spec.resolved_url_template) |template| try expandRevisionTemplate(self.allocator, template, metadata.rev) else null
        else
            null;
        defer if (resolved_url) |url| self.allocator.free(url);
        const archive = try self.fetchUrl(files, .{
            .url = resolved_url orelse spec.url,
            .name = spec.name,
            .forge = spec.forge,
            .auth_url = spec.url,
        }, reporter);
        defer archive.deinit(self.allocator);

        const out_path = try self.tarballCachePath(io, spec.name, archive.hash);
        errdefer self.allocator.free(out_path);
        {
            const extraction_lock = &self.fetch_locks[@as(usize, @intCast(std.hash.Wyhash.hash(0, out_path) % self.fetch_locks.len))];
            extraction_lock.lock();
            defer extraction_lock.unlock();
            try self.ensureTarballExtracted(io, archive.path, out_path);
        }

        if (forge_metadata) |*metadata| {
            const last_modified = try self.maxTreeMtime(io, out_path);
            self.allocator.free(metadata.last_modified_date);
            metadata.last_modified = last_modified;
            metadata.last_modified_date = try formatTimestamp(self.allocator, last_modified);
        }

        const nar_payload: ?TarballNar = if (spec.serialize_nar) payload: {
            const bytes = try nar.serialize(self.allocator, files, out_path, null);
            errdefer self.allocator.free(bytes);
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            break :payload .{ .bytes = bytes, .digest = digest };
        } else null;
        return .{
            .path = out_path,
            .nar_payload = nar_payload,
            .forge_metadata = forge_metadata,
            .cached = all_cached and archive.cached,
        };
    }

    fn parseForgeMetadata(self: *FetchCache, files: *FileCache, forge: Forge, path: []const u8) !?ForgeMetadata {
        if (forge == .sourcehut) unreachable;
        const data = try files.readFile(path);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const rev_value = switch (forge) {
            .github => parsed.value.object.get("sha") orelse return null,
            .gitlab => parsed.value.object.get("id") orelse return null,
            .sourcehut => unreachable,
        };
        if (rev_value != .string) return null;
        if (!validSha1(rev_value.string)) return null;
        return try self.forgeMetadataForRev(rev_value.string, 0);
    }

    fn parseSourcehutMetadata(
        self: *FetchCache,
        files: *FileCache,
        refs_path: []const u8,
        requested_ref: []const u8,
        head_url: ?[]const u8,
        auth_url: []const u8,
        reporter: ?Reporter,
    ) !?ForgeMetadata {
        var owned_target: ?[]u8 = null;
        defer if (owned_target) |target| self.allocator.free(target);
        const target = if (std.mem.eql(u8, requested_ref, "HEAD")) target: {
            const url = head_url orelse return null;
            const response = try self.fetchUrl(files, .{
                .url = url,
                .name = "sourcehut-HEAD",
                .forge = .sourcehut,
                .auth_url = auth_url,
            }, reporter);
            defer response.deinit(self.allocator);
            const head = std.mem.trim(u8, try files.readFile(response.path), " \t\r\n");
            if (std.mem.startsWith(u8, head, "ref:")) {
                owned_target = try self.allocator.dupe(u8, std.mem.trim(u8, head[4..], " \t\r\n"));
                break :target owned_target.?;
            }
            if (validSha1(head)) return try self.forgeMetadataForRev(head, 0);
            return null;
        } else target: {
            owned_target = if (std.mem.startsWith(u8, requested_ref, "refs/"))
                try self.allocator.dupe(u8, requested_ref)
            else
                try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{requested_ref});
            break :target owned_target.?;
        };

        const refs = try files.readFile(refs_path);
        var lines = std.mem.splitScalar(u8, refs, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const rev = std.mem.trim(u8, line[0..tab], " \t\r");
            const ref_name = std.mem.trim(u8, line[tab + 1 ..], " \t\r");
            if (std.mem.eql(u8, ref_name, target) and validSha1(rev)) return try self.forgeMetadataForRev(rev, 0);
            if (!std.mem.startsWith(u8, requested_ref, "refs/") and std.mem.eql(u8, ref_name, requested_ref) and validSha1(rev))
                return try self.forgeMetadataForRev(rev, 0);
        }
        // Nix accepts either a branch or a tag for a short ref.
        if (!std.mem.startsWith(u8, requested_ref, "refs/") and !std.mem.eql(u8, requested_ref, "HEAD")) {
            const tag = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{requested_ref});
            defer self.allocator.free(tag);
            lines = std.mem.splitScalar(u8, refs, '\n');
            while (lines.next()) |line| {
                const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
                const rev = std.mem.trim(u8, line[0..tab], " \t\r");
                const ref_name = std.mem.trim(u8, line[tab + 1 ..], " \t\r");
                if (std.mem.eql(u8, ref_name, tag) and validSha1(rev)) return try self.forgeMetadataForRev(rev, 0);
            }
        }
        return null;
    }

    fn forgeMetadataForRev(self: *FetchCache, rev_text: []const u8, timestamp: i64) !ForgeMetadata {
        const rev = try self.allocator.dupe(u8, rev_text);
        errdefer self.allocator.free(rev);
        return .{
            .rev = rev,
            .last_modified = timestamp,
            .last_modified_date = try formatTimestamp(self.allocator, timestamp),
        };
    }

    fn maxTreeMtime(self: *FetchCache, io: std.Io, path: []const u8) !i64 {
        var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();
        var latest: i64 = 0;
        while (try walker.next(io)) |entry| {
            const stat = try entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false });
            latest = @max(latest, stat.mtime.toSeconds());
        }
        return latest;
    }

    fn ensureTarballExtracted(self: *FetchCache, io: std.Io, archive_path: []const u8, out_path: []const u8) !void {
        const marker = try std.fmt.allocPrint(self.allocator, "{s}.complete", .{out_path});
        defer self.allocator.free(marker);
        if (try hostPathExists(io, marker) and try hostPathExists(io, out_path)) return;

        if (try hostPathExists(io, out_path)) try std.Io.Dir.cwd().deleteTree(io, out_path);
        std.Io.Dir.deleteFileAbsolute(io, marker) catch {};
        const parent = std.fs.path.dirname(out_path) orelse return error.FetchCacheWriteFailed;
        try std.Io.Dir.cwd().createDirPath(io, parent);
        const staging = try self.uniqueStagingPath(parent, ".extract");
        defer self.allocator.free(staging);
        errdefer std.Io.Dir.cwd().deleteTree(io, staging) catch {};
        try std.Io.Dir.cwd().createDirPath(io, staging);
        try self.runCommandDiscard(&.{ "tar", "-xf", archive_path, "-C", staging, "--strip-components=1" });
        try self.publishStagedDir(io, staging, out_path);
        try self.publishBytes(io, marker, "1\n");
    }

    pub fn fetchMercurial(self: *FetchCache, files: *FileCache, spec: MercurialSpec, _: ?Reporter) !MercurialResult {
        if (localFetchPath(spec.url)) |path| {
            return self.localMercurial(files, path, spec);
        }
        return self.remoteMercurial(files, spec);
    }

    /// Whether `err` from a download attempt is worth retrying (a transient
    /// connection/server problem) vs. a permanent failure (bad URL, 4xx, OOM).
    fn retryable(err: anyerror) bool {
        return switch (err) {
            error.OutOfMemory,
            error.FetchIoUnavailable,
            error.UnsupportedCompressionMethod,
            error.FetchClientError,
            error.FetchInvalidUrl,
            error.FetchTooManyRedirects,
            error.FetchTlsVerificationFailed,
            error.FetchGitRevisionNotFound,
            => false,
            else => true,
        };
    }

    fn fetchRemoteUrl(self: *FetchCache, io: std.Io, spec: UrlSpec, reporter: ?Reporter) !UrlResult {
        const lock = &self.fetch_locks[@as(usize, @intCast(std.hash.Wyhash.hash(0, spec.url) % self.fetch_locks.len))];
        lock.lock();
        defer lock.unlock();

        const root = try self.cacheRootDir(io);
        defer self.allocator.free(root);
        self.maybePruneUrlCache(io, root);
        const metadata_path = try self.urlMetadataPath(root, spec.url);
        defer self.allocator.free(metadata_path);
        if (try self.readFreshUrlCache(io, metadata_path, spec.name)) |cached| return cached;

        const staging_dir = try std.fs.path.join(self.allocator, &.{ root, "tmp" });
        defer self.allocator.free(staging_dir);
        try std.Io.Dir.cwd().createDirPath(io, staging_dir);
        const staging_path = try self.uniqueStagingPath(staging_dir, "download");
        defer self.allocator.free(staging_path);
        errdefer std.Io.Dir.deleteFileAbsolute(io, staging_path) catch {};

        const auth = if (spec.forge) |forge|
            try self.authHeader(forge, spec.auth_url orelse spec.url)
        else
            try self.netrcHeader(spec.url);
        defer if (auth) |header| header.deinit(self.allocator);
        var header_storage: [1]curl_transport.Header = undefined;
        const headers: []const curl_transport.Header = if (auth) |header| blk: {
            header_storage[0] = .{ .name = header.name, .value = header.value };
            break :blk header_storage[0..1];
        } else &.{};
        const curl_reporter: ?curl_transport.Reporter = if (reporter) |r|
            .{ .ctx = r.ctx, .report = r.report }
        else
            null;

        var attempt: u32 = 1;
        const downloaded = while (true) : (attempt += 1) {
            break curl_transport.download(self.allocator, spec.url, staging_path, .{
                .headers = headers,
                .reporter = curl_reporter,
                .connect_timeout_seconds = self.connect_timeout_seconds,
                .stalled_timeout_seconds = self.stalled_timeout_seconds,
                .max_bytes_per_second = std.math.mul(u64, self.download_speed_kib, 1024) catch std.math.maxInt(u64),
                .ca_file = self.ssl_cert_file,
            }) catch |err| {
                std.Io.Dir.deleteFileAbsolute(io, staging_path) catch {};
                if (attempt >= self.download_attempts or !retryable(err)) return err;
                io.sleep(std.Io.Duration.fromMilliseconds(@min(5_000, 250 * @as(i64, attempt))), .awake) catch {};
                continue;
            };
        };

        const hash_array = std.fmt.bytesToHex(downloaded.digest, .lower);
        const hash = try self.allocator.dupe(u8, &hash_array);
        errdefer self.allocator.free(hash);
        const generation = std.Io.Clock.real.now(io).toSeconds();
        try self.noteUrlGenerationAtRoot(io, root, hash, generation);
        const path = try self.urlCachePath(io, spec.name, hash);
        errdefer self.allocator.free(path);
        try self.publishStagedFile(io, staging_path, path);
        const published = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        try self.writeUrlMetadataAt(io, metadata_path, generation, hash, published.size);
        return .{ .path = path, .hash = hash };
    }

    fn urlMetadataPath(self: *FetchCache, root: []const u8, url: []const u8) ![]u8 {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
        const encoded = std.fmt.bytesToHex(digest, .lower);
        return std.fs.path.join(self.allocator, &.{ root, "url-index", &encoded });
    }

    fn readFreshUrlCache(self: *FetchCache, io: std.Io, metadata_path: []const u8, name: []const u8) !?UrlResult {
        if (self.tarball_ttl == 0) return null;
        const metadata = std.Io.Dir.cwd().readFileAlloc(io, metadata_path, self.allocator, .limited(256)) catch return null;
        defer self.allocator.free(metadata);
        var lines = std.mem.splitScalar(u8, metadata, '\n');
        const written_text = lines.next() orelse return null;
        const hash = lines.next() orelse return null;
        if (hash.len != std.crypto.hash.sha2.Sha256.digest_length * 2) return null;
        for (hash) |byte| if (!std.ascii.isHex(byte)) return null;
        const written = std.fmt.parseInt(i64, written_text, 10) catch return null;
        const now = std.Io.Clock.real.now(io).toSeconds();
        if (now < written or now - written > self.tarball_ttl) return null;

        const path = try self.urlCachePath(io, name, hash);
        errdefer self.allocator.free(path);
        const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch {
            self.allocator.free(path);
            return null;
        };
        if (stat.kind != .file) {
            self.allocator.free(path);
            return null;
        }

        // New entries can be trusted after a cheap stat: the file was hashed
        // while downloading, then atomically published under that hash before
        // this size stamp was written. Cache objects are immutable; no
        // filesystem timestamp support is required.
        const recorded_size = if (lines.next()) |text| std.fmt.parseInt(u64, text, 10) catch null else null;
        if (recorded_size) |size| {
            if (stat.size != size) {
                self.allocator.free(path);
                return null;
            }
            self.noteUrlGeneration(io, hash, written) catch {};
            return .{ .path = path, .hash = try self.allocator.dupe(u8, hash), .cached = true };
        }

        // Legacy two-line metadata gets one full validation and is upgraded to
        // the fast size-stamped form.
        const actual = curl_transport.fileDigest(self.allocator, path) catch {
            self.allocator.free(path);
            return null;
        };
        const actual_hex = std.fmt.bytesToHex(actual, .lower);
        if (!std.mem.eql(u8, &actual_hex, hash)) {
            self.allocator.free(path);
            return null;
        }
        self.writeUrlMetadataAt(io, metadata_path, written, hash, stat.size) catch {};
        self.noteUrlGeneration(io, hash, written) catch {};
        return .{ .path = path, .hash = try self.allocator.dupe(u8, hash), .cached = true };
    }

    fn writeUrlMetadataAt(self: *FetchCache, io: std.Io, path: []const u8, written: i64, hash: []const u8, size: u64) !void {
        const contents = try std.fmt.allocPrint(self.allocator, "{d}\n{s}\n{d}\n", .{
            written,
            hash,
            size,
        });
        defer self.allocator.free(contents);
        try self.publishBytes(io, path, contents);
    }

    /// Record object age explicitly in the path, rather than relying on mtime:
    ///
    ///   url-generations/<content-hash-prefix>/<unix-seconds>
    ///
    /// A refresh that returns identical bytes simply adds a newer generation.
    /// This makes both bumping and pruning work on filesystems without times.
    fn noteUrlGeneration(self: *FetchCache, io: std.Io, hash: []const u8, generation: i64) !void {
        const root = try self.cacheRootDir(io);
        defer self.allocator.free(root);
        try self.noteUrlGenerationAtRoot(io, root, hash, generation);
    }

    fn noteUrlGenerationAtRoot(self: *FetchCache, io: std.Io, root: []const u8, hash: []const u8, generation: i64) !void {
        if (!validUrlHash(hash)) return error.FetchCacheWriteFailed;
        var generation_buffer: [32]u8 = undefined;
        const generation_text = try std.fmt.bufPrint(&generation_buffer, "{d}", .{generation});
        const marker = try std.fs.path.join(self.allocator, &.{ root, "url-generations", hash[0..32], generation_text });
        defer self.allocator.free(marker);
        if (try hostPathExists(io, marker)) return;
        try self.publishBytes(io, marker, "1\n");

        // This content hash was just refreshed. Retain a concurrently-created
        // newer generation, but remove older markers so the directory itself
        // is the object's single, cheaply bumpable age record.
        const parent = std.fs.path.dirname(marker) orelse return;
        var dir = try std.Io.Dir.openDirAbsolute(io, parent, .{ .iterate = true });
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            const old_generation = std.fmt.parseInt(i64, entry.name, 10) catch continue;
            if (old_generation >= generation) continue;
            const old_marker = try std.fs.path.join(self.allocator, &.{ parent, entry.name });
            defer self.allocator.free(old_marker);
            std.Io.Dir.deleteFileAbsolute(io, old_marker) catch {};
        }
    }

    fn maybePruneUrlCache(self: *FetchCache, io: std.Io, root: []const u8) void {
        self.cache_prune_mu.lock();
        defer self.cache_prune_mu.unlock();
        if (self.cache_pruned) return;
        self.cache_pruned = true;
        self.pruneUrlCache(io, root, std.Io.Clock.real.now(io).toSeconds()) catch {};
    }

    /// Drop URL archives and their extracted tarballs after two TTL windows.
    /// The URL index's explicit timestamp seeds generation markers for entries
    /// written by older Fix versions, then unmarked legacy/orphaned objects are
    /// removed. Cleanup is deliberately best-effort at the call site: a cache
    /// permission problem must never make evaluation fail.
    fn pruneUrlCache(self: *FetchCache, io: std.Io, root: []const u8, now: i64) !void {
        // Zero is the explicit "always refresh" setting, not an instruction to
        // purge every unrelated cached source on the next fetch.
        if (self.tarball_ttl == 0) return;
        const retention = @as(i64, self.tarball_ttl) * 2;
        const cutoff = now - retention;
        try self.pruneUrlIndex(io, root, now, cutoff);
        try self.pruneUrlGenerations(io, root, cutoff);
        try self.pruneUnmarkedObjects(io, root, "url");
        try self.pruneUnmarkedObjects(io, root, "tarball");
    }

    fn pruneUrlIndex(self: *FetchCache, io: std.Io, root: []const u8, now: i64, cutoff: i64) !void {
        const index_path = try std.fs.path.join(self.allocator, &.{ root, "url-index" });
        defer self.allocator.free(index_path);
        var dir = std.Io.Dir.openDirAbsolute(io, index_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const metadata_path = try std.fs.path.join(self.allocator, &.{ index_path, entry.name });
            defer self.allocator.free(metadata_path);
            const metadata = std.Io.Dir.cwd().readFileAlloc(io, metadata_path, self.allocator, .limited(256)) catch {
                std.Io.Dir.deleteFileAbsolute(io, metadata_path) catch {};
                continue;
            };
            defer self.allocator.free(metadata);
            var lines = std.mem.splitScalar(u8, metadata, '\n');
            const written_text = lines.next() orelse {
                std.Io.Dir.deleteFileAbsolute(io, metadata_path) catch {};
                continue;
            };
            const hash = lines.next() orelse {
                std.Io.Dir.deleteFileAbsolute(io, metadata_path) catch {};
                continue;
            };
            const written = std.fmt.parseInt(i64, written_text, 10) catch {
                std.Io.Dir.deleteFileAbsolute(io, metadata_path) catch {};
                continue;
            };
            if (!validUrlHash(hash) or written > now or written <= cutoff) {
                std.Io.Dir.deleteFileAbsolute(io, metadata_path) catch {};
                continue;
            }
            // Migrates fresh metadata from the old, unversioned object layout.
            self.noteUrlGenerationAtRoot(io, root, hash, written) catch {};
        }
    }

    fn pruneUrlGenerations(self: *FetchCache, io: std.Io, root: []const u8, cutoff: i64) !void {
        const generations_path = try std.fs.path.join(self.allocator, &.{ root, "url-generations" });
        defer self.allocator.free(generations_path);
        var dir = std.Io.Dir.openDirAbsolute(io, generations_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .directory or entry.name.len != 32) continue;
            const hash_generations = try std.fs.path.join(self.allocator, &.{ generations_path, entry.name });
            defer self.allocator.free(hash_generations);
            var hash_dir = std.Io.Dir.openDirAbsolute(io, hash_generations, .{ .iterate = true }) catch continue;
            var hash_iterator = hash_dir.iterate();
            var newest: ?i64 = null;
            while (hash_iterator.next(io) catch null) |marker| {
                const generation = std.fmt.parseInt(i64, marker.name, 10) catch continue;
                newest = if (newest) |value| @max(value, generation) else generation;
            }
            hash_dir.close(io);
            if (newest == null or newest.? <= cutoff)
                self.deleteCachedHash(io, root, entry.name);
        }
    }

    fn pruneUnmarkedObjects(self: *FetchCache, io: std.Io, root: []const u8, object_kind: []const u8) !void {
        const objects_path = try std.fs.path.join(self.allocator, &.{ root, object_kind });
        defer self.allocator.free(objects_path);
        var dir = std.Io.Dir.openDirAbsolute(io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .directory or entry.name.len != 32) continue;
            const generation_path = try std.fs.path.join(self.allocator, &.{ root, "url-generations", entry.name });
            defer self.allocator.free(generation_path);
            if (!try hostPathExists(io, generation_path))
                self.deleteCachedHash(io, root, entry.name);
        }
    }

    fn deleteCachedHash(self: *FetchCache, io: std.Io, root: []const u8, hash_prefix: []const u8) void {
        for ([_][]const u8{ "url", "tarball", "url-generations" }) |kind| {
            const path = std.fs.path.join(self.allocator, &.{ root, kind, hash_prefix }) catch continue;
            defer self.allocator.free(path);
            std.Io.Dir.cwd().deleteTree(io, path) catch {};
        }
    }

    fn publishBytes(self: *FetchCache, io: std.Io, path: []const u8, bytes: []const u8) !void {
        const parent = std.fs.path.dirname(path) orelse return error.FetchCacheWriteFailed;
        try std.Io.Dir.cwd().createDirPath(io, parent);
        const staging = try self.uniqueStagingPath(parent, ".file");
        defer self.allocator.free(staging);
        errdefer std.Io.Dir.deleteFileAbsolute(io, staging) catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staging, .data = bytes });
        try self.publishStagedFile(io, staging, path);
    }

    fn publishStagedFile(_: *FetchCache, io: std.Io, staging: []const u8, final: []const u8) !void {
        const parent = std.fs.path.dirname(final) orelse return error.FetchCacheWriteFailed;
        try std.Io.Dir.cwd().createDirPath(io, parent);
        try std.Io.Dir.renameAbsolute(staging, final, io);
    }

    fn publishStagedDir(_: *FetchCache, io: std.Io, staging: []const u8, final: []const u8) !void {
        std.Io.Dir.renameAbsolute(staging, final, io) catch |err| {
            // Another process may have won the same content-addressed commit.
            // Its directory became visible through one atomic rename, so it is
            // complete; discard our equally complete staging tree.
            if (try hostPathExists(io, final)) {
                try std.Io.Dir.cwd().deleteTree(io, staging);
                return;
            }
            return err;
        };
    }

    fn uniqueStagingPath(self: *FetchCache, dir: []const u8, stem: []const u8) ![]u8 {
        var random: [12]u8 = undefined;
        std.Io.random(self.io.?, &random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const name = try std.fmt.allocPrint(self.allocator, "{s}-{s}.tmp", .{ stem, &suffix });
        defer self.allocator.free(name);
        return std.fs.path.join(self.allocator, &.{ dir, name });
    }

    fn localGit(self: *FetchCache, files: *FileCache, path: []const u8, spec: GitSpec) !GitResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        const root = try self.cacheRootDir(io);
        defer self.allocator.free(root);
        const snapshots = try std.fs.path.join(self.allocator, &.{ root, "git-local" });
        defer self.allocator.free(snapshots);
        try std.Io.Dir.cwd().createDirPath(io, snapshots);
        const staging = try self.uniqueStagingPath(snapshots, ".snapshot");
        defer self.allocator.free(staging);
        errdefer std.Io.Dir.cwd().deleteTree(io, staging) catch {};
        const metadata = try git_transport.snapshotLocal(self.allocator, io, path, staging, spec.rev, spec.submodules);
        const digest = try nar.hashPathDigest(self.allocator, files, staging);
        const encoded = std.fmt.bytesToHex(digest, .lower);
        const snapshot = try std.fs.path.join(self.allocator, &.{ snapshots, encoded[0..32], "source" });
        defer self.allocator.free(snapshot);
        const lock = &self.fetch_locks[@as(usize, @intCast(std.hash.Wyhash.hash(0, snapshot) % self.fetch_locks.len))];
        lock.lock();
        defer lock.unlock();
        const marker = try std.fmt.allocPrint(self.allocator, "{s}.complete", .{snapshot});
        defer self.allocator.free(marker);
        if (try hostPathExists(io, marker) and try hostPathExists(io, snapshot)) {
            try std.Io.Dir.cwd().deleteTree(io, staging);
        } else {
            const parent = std.fs.path.dirname(snapshot) orelse return error.FetchCacheWriteFailed;
            try std.Io.Dir.cwd().createDirPath(io, parent);
            try self.publishStagedDir(io, staging, snapshot);
            try self.publishBytes(io, marker, "1\n");
        }
        return self.gitResultFromTransport(snapshot, metadata, spec.submodules);
    }

    fn remoteGit(self: *FetchCache, _: *FileCache, spec: GitSpec, reporter: ?Reporter) !GitResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        const path = try self.remoteGitPath(io, spec);
        defer self.allocator.free(path);
        const git_dir = try std.fs.path.join(self.allocator, &.{ path, ".git" });
        defer self.allocator.free(git_dir);
        const lock = &self.fetch_locks[@as(usize, @intCast(std.hash.Wyhash.hash(0, path) % self.fetch_locks.len))];
        lock.lock();
        defer lock.unlock();

        const parent = std.fs.path.dirname(path) orelse return error.FetchCacheWriteFailed;
        try std.Io.Dir.cwd().createDirPath(io, parent);
        if (!try hostPathExists(io, git_dir) and try hostPathExists(io, path))
            try std.Io.Dir.cwd().deleteTree(io, path);

        const marker = try std.fmt.allocPrint(self.allocator, "{s}.fresh", .{path});
        defer self.allocator.free(marker);
        const exists = try hostPathExists(io, git_dir);
        // A pinned commit is immutable once present. allRefs always fetches, as
        // in Nix. Mutable refs/HEAD obey the same tarball-ttl policy as URL and
        // Mercurial sources.
        var refresh = !exists or (spec.rev == null and (spec.all_refs or !try self.timestampFresh(io, marker)));
        const credential = try self.gitCredential(spec.url);
        defer if (credential) |value| value.deinit(self.allocator);
        const git_reporter: ?git_transport.Reporter = if (reporter) |r| .{ .ctx = r.ctx, .report = r.report } else null;

        const staging = if (!exists) try self.uniqueStagingPath(parent, ".git-clone") else null;
        defer if (staging) |value| self.allocator.free(value);
        errdefer if (staging) |value| std.Io.Dir.cwd().deleteTree(io, value) catch {};
        const materialize_path = staging orelse path;
        var attempt: u32 = 1;
        var result = while (true) : (attempt += 1) {
            break git_transport.materialize(self.allocator, spec.url, materialize_path, spec.rev, spec.ref, spec.submodules, spec.all_refs, refresh, .{
                .credentials = if (credential) |value| .{ .username = value.username, .password = value.password } else null,
                .reporter = git_reporter,
                .ca_file = self.ssl_cert_file,
                .proxy_url = self.proxyFor(spec.url),
                .connect_timeout_seconds = self.connect_timeout_seconds,
                .stalled_timeout_seconds = self.stalled_timeout_seconds,
            }) catch |err| {
                if (staging) |value| std.Io.Dir.cwd().deleteTree(io, value) catch {};
                // A pinned object may not have been in an older shallow/cache
                // population; retry once with a real fetch before failing.
                if (!refresh and spec.rev != null) {
                    refresh = true;
                    continue;
                }
                if (attempt >= self.download_attempts or !retryable(err)) return err;
                io.sleep(std.Io.Duration.fromMilliseconds(@min(5_000, 250 * @as(i64, attempt))), .awake) catch {};
                continue;
            };
        };
        if (staging) |value| {
            try self.publishStagedDir(io, value, path);
            // If another process won the atomic directory commit, report the
            // revision actually present at the shared final path.
            result = try git_transport.materialize(self.allocator, spec.url, path, spec.rev, spec.ref, spec.submodules, spec.all_refs, false, .{
                .credentials = if (credential) |item| .{ .username = item.username, .password = item.password } else null,
                .ca_file = self.ssl_cert_file,
                .proxy_url = self.proxyFor(spec.url),
                .connect_timeout_seconds = self.connect_timeout_seconds,
                .stalled_timeout_seconds = self.stalled_timeout_seconds,
            });
        }
        if (refresh) try self.writeTimestamp(io, marker);

        return self.gitResultFromTransport(path, result, spec.submodules);
    }

    const GitCredential = auth_mod.Credentials;

    fn gitCredential(self: *const FetchCache, url: []const u8) !?GitCredential {
        return self.auth.gitCredentials(url);
    }

    fn timestampFresh(self: *FetchCache, io: std.Io, marker: []const u8) !bool {
        if (self.tarball_ttl == 0) return false;
        const contents = std.Io.Dir.cwd().readFileAlloc(io, marker, self.allocator, .limited(64)) catch return false;
        defer self.allocator.free(contents);
        const written = std.fmt.parseInt(i64, std.mem.trim(u8, contents, " \t\r\n"), 10) catch return false;
        const now = std.Io.Clock.real.now(io).toSeconds();
        return now >= written and now - written <= self.tarball_ttl;
    }

    fn writeTimestamp(self: *FetchCache, io: std.Io, marker: []const u8) !void {
        const contents = try std.fmt.allocPrint(self.allocator, "{d}\n", .{std.Io.Clock.real.now(io).toSeconds()});
        defer self.allocator.free(contents);
        try self.publishBytes(io, marker, contents);
    }

    fn proxyFor(self: *const FetchCache, url: []const u8) ?[]const u8 {
        const environment = self.env orelse return null;
        const host = urlHostPath(url).host;
        const no_proxy = environment.get("NO_PROXY") orelse environment.get("no_proxy");
        if (no_proxy) |list| {
            var entries = std.mem.tokenizeScalar(u8, list, ',');
            while (entries.next()) |raw| {
                var entry = std.mem.trim(u8, raw, " \t");
                if (std.mem.eql(u8, entry, "*")) return null;
                if (std.mem.indexOfScalar(u8, entry, ':')) |colon| entry = entry[0..colon];
                if (std.mem.startsWith(u8, entry, ".")) entry = entry[1..];
                if (entry.len != 0 and (std.mem.eql(u8, host, entry) or
                    (host.len > entry.len and std.mem.endsWith(u8, host, entry) and host[host.len - entry.len - 1] == '.'))) return null;
            }
        }
        if (std.mem.startsWith(u8, url, "https://"))
            return environment.get("HTTPS_PROXY") orelse environment.get("https_proxy") orelse environment.get("ALL_PROXY") orelse environment.get("all_proxy");
        return environment.get("HTTP_PROXY") orelse environment.get("http_proxy") orelse environment.get("ALL_PROXY") orelse environment.get("all_proxy");
    }

    fn localMercurial(self: *FetchCache, files: *FileCache, path: []const u8, spec: MercurialSpec) !MercurialResult {
        const rev = if (spec.rev) |r| try self.allocator.dupe(u8, r) else try self.localMercurialRevision(files, path) orelse try self.allocator.dupe(u8, "");
        defer self.allocator.free(rev);
        return self.mercurialResult(path, rev);
    }

    fn remoteMercurial(self: *FetchCache, files: *FileCache, spec: MercurialSpec) !MercurialResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        const path = try self.remoteMercurialPath(io, spec);
        defer self.allocator.free(path);
        const hg_dir = try std.fs.path.join(self.allocator, &.{ path, ".hg" });
        defer self.allocator.free(hg_dir);
        _ = files;
        const lock = &self.fetch_locks[@as(usize, @intCast(std.hash.Wyhash.hash(0, path) % self.fetch_locks.len))];
        lock.lock();
        defer lock.unlock();
        const marker = try std.fmt.allocPrint(self.allocator, "{s}.fresh", .{path});
        defer self.allocator.free(marker);
        var exists = try hostPathExists(io, hg_dir);
        if (!exists and try hostPathExists(io, path)) try std.Io.Dir.cwd().deleteTree(io, path);
        const refresh = !exists or (spec.rev == null and !try self.timestampFresh(io, marker));
        if (!exists) {
            const parent = std.fs.path.dirname(path) orelse return error.FetchCacheWriteFailed;
            try std.Io.Dir.cwd().createDirPath(io, parent);
            const staging = try self.uniqueStagingPath(parent, ".hg-clone");
            defer self.allocator.free(staging);
            errdefer std.Io.Dir.cwd().deleteTree(io, staging) catch {};
            try self.runCommandRetried(io, &.{ "hg", "clone", spec.url, staging });
            try self.publishStagedDir(io, staging, path);
            exists = true;
        } else if (refresh) {
            try self.runCommandRetried(io, &.{ "hg", "--cwd", path, "pull" });
        }
        if (spec.rev) |rev| {
            try self.runCommandDiscard(&.{ "hg", "--cwd", path, "update", "--rev", rev });
        } else if (refresh) {
            try self.runCommandDiscard(&.{ "hg", "--cwd", path, "update" });
        }
        if (refresh) try self.writeTimestamp(io, marker);

        const rev = try self.commandOneLine(&.{ "hg", "--cwd", path, "id", "--id" });
        defer self.allocator.free(rev);
        return self.mercurialResult(path, stripMercurialDirtySuffix(rev));
    }

    fn runCommandRetried(self: *FetchCache, io: std.Io, argv: []const []const u8) !void {
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            self.runCommandDiscard(argv) catch |err| {
                if (attempt >= self.download_attempts) return err;
                io.sleep(std.Io.Duration.fromMilliseconds(@min(5_000, 250 * @as(i64, attempt))), .awake) catch {};
                continue;
            };
            return;
        }
    }

    fn gitResultFromTransport(self: *FetchCache, path: []const u8, result: git_transport.Result, submodules: bool) !GitResult {
        const rev = try self.allocator.dupe(u8, &result.rev);
        errdefer self.allocator.free(rev);
        const short_rev = try self.allocator.dupe(u8, result.rev[0..7]);
        errdefer self.allocator.free(short_rev);
        const out_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(out_path);
        const last_modified_date = try self.allocator.dupe(u8, &result.last_modified_date);
        errdefer self.allocator.free(last_modified_date);
        return .{
            .out_path = out_path,
            .rev = rev,
            .short_rev = short_rev,
            .rev_count = result.rev_count,
            .last_modified = result.last_modified,
            .last_modified_date = last_modified_date,
            .submodules = submodules,
        };
    }

    fn remoteGitPath(self: *FetchCache, io: std.Io, spec: GitSpec) ![]u8 {
        var key: std.ArrayListUnmanaged(u8) = .empty;
        defer key.deinit(self.allocator);
        try key.appendSlice(self.allocator, spec.url);
        try key.append(self.allocator, 0);
        if (spec.rev) |rev| try key.appendSlice(self.allocator, rev);
        try key.append(self.allocator, 0);
        if (spec.ref) |ref| try key.appendSlice(self.allocator, ref);
        try key.append(self.allocator, 0);
        try key.append(self.allocator, @intFromBool(spec.submodules));
        // An allRefs clone holds refs a targeted clone lacks; keep them apart.
        try key.append(self.allocator, @intFromBool(spec.all_refs));

        const digest = try nix_hash.hashBytes(self.allocator, "sha256", key.items);
        defer self.allocator.free(digest);
        const root = try self.cacheRootDir(io);
        defer self.allocator.free(root);
        return std.fs.path.join(self.allocator, &.{ root, "git", digest[0..32] });
    }

    fn remoteMercurialPath(self: *FetchCache, io: std.Io, spec: MercurialSpec) ![]u8 {
        var key: std.ArrayListUnmanaged(u8) = .empty;
        defer key.deinit(self.allocator);
        try key.appendSlice(self.allocator, spec.url);
        try key.append(self.allocator, 0);
        if (spec.rev) |rev| try key.appendSlice(self.allocator, rev);

        const digest = try nix_hash.hashBytes(self.allocator, "sha256", key.items);
        defer self.allocator.free(digest);
        const root = try self.cacheRootDir(io);
        defer self.allocator.free(root);
        return std.fs.path.join(self.allocator, &.{ root, "hg", digest[0..32] });
    }

    fn urlCachePath(self: *FetchCache, io: std.Io, name: []const u8, hash: []const u8) ![]u8 {
        const root = try self.cacheRootDir(io);
        defer self.allocator.free(root);
        const clean_name = try cleanStoreName(self.allocator, name);
        defer self.allocator.free(clean_name);
        return std.fs.path.join(self.allocator, &.{ root, "url", hash[0..32], clean_name });
    }

    fn tarballCachePath(self: *FetchCache, io: std.Io, name: []const u8, hash: []const u8) ![]u8 {
        const root = try self.cacheRootDir(io);
        defer self.allocator.free(root);
        const clean_name = try cleanStoreName(self.allocator, name);
        defer self.allocator.free(clean_name);
        return std.fs.path.join(self.allocator, &.{ root, "tarball", hash[0..32], clean_name });
    }

    fn mercurialResult(self: *FetchCache, path: []const u8, rev: []const u8) !MercurialResult {
        const clean_rev = stripMercurialDirtySuffix(rev);
        const short_len = @min(clean_rev.len, 12);
        const short_rev = try self.allocator.dupe(u8, clean_rev[0..short_len]);
        errdefer self.allocator.free(short_rev);
        const out_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(out_path);
        const owned_rev = try self.allocator.dupe(u8, clean_rev);
        errdefer self.allocator.free(owned_rev);

        return .{
            .out_path = out_path,
            .rev = owned_rev,
            .short_rev = short_rev,
        };
    }

    fn localMercurialRevision(self: *FetchCache, files: *FileCache, repo_path: []const u8) !?[]u8 {
        const hg_dir = try std.fs.path.join(self.allocator, &.{ repo_path, ".hg" });
        defer self.allocator.free(hg_dir);
        if (!try files.pathExists(hg_dir)) return null;
        if (self.io == null) return null;
        const rev = self.commandOneLine(&.{ "hg", "--cwd", repo_path, "id", "--id" }) catch return null;
        defer self.allocator.free(rev);
        return try self.allocator.dupe(u8, stripMercurialDirtySuffix(rev));
    }

    fn commandOneLine(self: *FetchCache, argv: []const []const u8) ![]u8 {
        const result = try self.runCommand(argv, null);
        defer self.allocator.free(result.stderr);
        defer self.allocator.free(result.stdout);
        return self.allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }

    fn runCommandDiscard(self: *FetchCache, argv: []const []const u8) !void {
        const result = try self.runCommand(argv, null);
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
    }

    fn runCommand(self: *FetchCache, argv: []const []const u8, cwd: ?[]const u8) !std.process.RunResult {
        const io = self.io orelse return error.FetchIoUnavailable;
        const result = try std.process.run(self.allocator, io, .{
            .argv = argv,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            .environ_map = try self.subprocessEnviron(),
            // These are trusted tools with machine-readable output. Large
            // repositories can legitimately exceed an arbitrary capture cap.
            .stdout_limit = .unlimited,
            .stderr_limit = .limited(command_stderr_limit),
        });
        errdefer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        switch (result.term) {
            .exited => |code| if (code == 0) return result,
            else => {},
        }
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
        return error.FetchCommandFailed;
    }
};

fn cleanStoreName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const clean_name = try allocator.alloc(u8, name.len);
    errdefer allocator.free(clean_name);
    for (name, clean_name) |c, *out| {
        out.* = if (c == '/' or c == 0 or std.ascii.isWhitespace(c)) '-' else c;
    }
    return clean_name;
}

fn hostPathExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn localFetchPath(url: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(url)) return url;
    if (std.mem.startsWith(u8, url, "file://")) return url["file://".len..];
    return null;
}

fn stripMercurialDirtySuffix(rev: []const u8) []const u8 {
    if (std.mem.endsWith(u8, rev, "+")) return rev[0 .. rev.len - 1];
    return rev;
}

fn validSha1(text: []const u8) bool {
    if (text.len != 40) return false;
    for (text) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn validUrlHash(text: []const u8) bool {
    if (text.len != std.crypto.hash.sha2.Sha256.digest_length * 2) return false;
    for (text) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn expandRevisionTemplate(allocator: std.mem.Allocator, template: []const u8, rev: []const u8) ![]u8 {
    const marker = "{rev}";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var rest = template;
    var replaced = false;
    while (std.mem.indexOf(u8, rest, marker)) |position| {
        try out.appendSlice(allocator, rest[0..position]);
        try out.appendSlice(allocator, rev);
        rest = rest[position + marker.len ..];
        replaced = true;
    }
    if (!replaced) return error.InvalidRevisionUrlTemplate;
    try out.appendSlice(allocator, rest);
    return out.toOwnedSlice(allocator);
}

fn formatTimestamp(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    return allocator.dupe(u8, &clock.formatUtc(timestamp));
}

test "forge archive revision templates pin every ref occurrence" {
    const expanded = try expandRevisionTemplate(std.testing.allocator, "https://gitlab/x/-/archive/{rev}/x-{rev}.tar.gz", "abc123");
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqualStrings("https://gitlab/x/-/archive/abc123/x-abc123.tar.gz", expanded);
}

test "access-tokens: parse and longest-prefix host/path match" {
    const testing = std.testing;
    var fc = try FetchCache.init(testing.allocator, .{});
    defer fc.deinit();
    try fc.setAccessTokens("github.com=ghp_base gitlab.example.org=glpat github.com/acme=ghp_acme  =skip  bad_no_eq");

    // Bare host match, and the port/scheme are ignored.
    try testing.expectEqualStrings("ghp_base", fc.tokenFor("https://github.com/owner/repo/archive/HEAD.tar.gz").?);
    try testing.expectEqualStrings("ghp_base", fc.tokenFor("https://github.com").?);
    // The longer `github.com/acme` key wins for that org.
    try testing.expectEqualStrings("ghp_acme", fc.tokenFor("https://github.com/acme/thing/archive/HEAD.tar.gz").?);
    // A different self-hosted host.
    try testing.expectEqualStrings("glpat", fc.tokenFor("https://gitlab.example.org/g/p/-/archive/v1/p-v1.tar.gz").?);
    // No token for an unlisted host; `github.comX` must not match `github.com`.
    try testing.expect(fc.tokenFor("https://codeberg.org/o/r") == null);
    try testing.expect(fc.tokenFor("https://github.com.evil.example/x") == null);
}

fn checkOwnedConfigurationAllocationFailures(allocator: std.mem.Allocator) !void {
    var cache = try FetchCache.init(allocator, .{});
    defer cache.deinit();

    try cache.setNetrc(
        "machine example.org login alice password secret " ++
            "default login fallback password fallback-secret",
    );
    try cache.setAccessTokens(
        "github.com=ghp_base github.com/acme=ghp_acme " ++
            "gitlab.example.org=PAT:glpat",
    );

    const basic = (try cache.netrcHeader("https://example.org/source")).?;
    defer basic.deinit(allocator);
    const token = (try cache.authHeader(
        .github,
        "https://github.com/acme/repo/archive/main.tar.gz",
    )) orelse return error.OutOfMemory;
    defer token.deinit(allocator);
    const hg = try cache.mercurialResult("/cache/repo", "1234567890abcdef+");
    defer hg.deinit(allocator);
    const git = try cache.gitResultFromTransport("/cache/git", .{
        .rev = "0123456789012345678901234567890123456789".*,
        .rev_count = 7,
        .last_modified = 1_767_225_845,
        .last_modified_date = "20260102030405".*,
    }, false);
    defer git.deinit(allocator);
}

test "owned fetch configuration handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkOwnedConfigurationAllocationFailures,
        .{},
    );
}

test "netrc: basic-auth header by machine, else default" {
    const testing = std.testing;
    var fc = try FetchCache.init(testing.allocator, .{});
    defer fc.deinit();
    try fc.setNetrc(
        \\machine example.com login alice password s3cret
        \\machine noauth.example
        \\default login guest password g
    );

    const decoded = struct {
        fn creds(fcp: *FetchCache, url: []const u8, out: []u8) ![]const u8 {
            const h = (try fcp.netrcHeader(url)).?;
            defer h.deinit(fcp.allocator);
            try testing.expectEqualStrings("Authorization", h.name);
            const b64 = h.value["Basic ".len..];
            const dec = std.base64.standard.Decoder;
            const n = try dec.calcSizeForSlice(b64);
            try dec.decode(out[0..n], b64);
            return out[0..n];
        }
    };
    var buf: [64]u8 = undefined;
    // Exact machine match.
    try testing.expectEqualStrings("alice:s3cret", try decoded.creds(&fc, "https://example.com/repo.git", &buf));
    // Unknown host falls back to the `default` entry.
    try testing.expectEqualStrings("guest:g", try decoded.creds(&fc, "https://unknown.example/x", &buf));
    // A matched machine with no login yields no header (and does not fall back
    // to `default` — the host has its own entry).
    try testing.expect((try fc.netrcHeader("https://noauth.example/x")) == null);

    var empty = try FetchCache.init(testing.allocator, .{});
    defer empty.deinit();
    try testing.expect((try empty.netrcHeader("https://example.com")) == null);
}

test "subprocess env: inherits parent and normalizes Mercurial" {
    const testing = std.testing;
    var parent = std.process.Environ.Map.init(testing.allocator);
    defer parent.deinit();
    try parent.put("HOME", "/home/u");
    try parent.put("SSH_AUTH_SOCK", "/run/ssh");

    var fc = try FetchCache.init(testing.allocator, .{});
    defer fc.deinit();
    try fc.setEnvironment(&parent);

    const env = (try fc.subprocessEnviron()).?;
    try testing.expectEqualStrings("", env.get("HGPLAIN").?);
    try testing.expectEqualStrings("/home/u", env.get("HOME").?); // inherited
    try testing.expectEqualStrings("/run/ssh", env.get("SSH_AUTH_SOCK").?); // inherited (creds/ssh)

    // With no environment set, subprocesses inherit the parent unchanged (null).
    var bare = try FetchCache.init(testing.allocator, .{});
    defer bare.deinit();
    try testing.expect((try bare.subprocessEnviron()) == null);
}

test "access-tokens: per-forge auth header (matches Nix)" {
    const testing = std.testing;
    var fc = try FetchCache.init(testing.allocator, .{});
    defer fc.deinit();
    try fc.setAccessTokens("github.com=ghp_x gl.example.org=PAT:glpat gl2.example.org=OAuth2:oa sh.example.org=shtok gitea.example.org=abc:def git.sr.ht=srhtok");

    const check = struct {
        fn one(fcp: *FetchCache, forge: FetchCache.Forge, url: []const u8, name: []const u8, value: []const u8) !void {
            const h = (try fcp.authHeader(forge, url)).?;
            defer h.deinit(fcp.allocator);
            try testing.expectEqualStrings(name, h.name);
            try testing.expectEqualStrings(value, h.value);
        }
    };

    // GitHub: `Authorization: token <tok>`.
    try check.one(&fc, .github, "https://github.com/o/r/archive/HEAD.tar.gz", "Authorization", "token ghp_x");
    // Direct codeload URLs deliberately map back to github.com for token lookup.
    try check.one(&fc, .github, "https://codeload.github.com/o/r/tar.gz/HEAD", "Authorization", "token ghp_x");
    // SourceHut: `Authorization: Bearer <tok>`.
    try check.one(&fc, .sourcehut, "https://git.sr.ht/~o/r/archive/HEAD.tar.gz", "Authorization", "Bearer srhtok");
    // GitLab PAT: `Private-token: <value>`.
    try check.one(&fc, .gitlab, "https://gl.example.org/g/p", "Private-token", "glpat");
    // GitLab OAuth2: `Authorization: Bearer <value>`.
    try check.one(&fc, .gitlab, "https://gl2.example.org/g/p", "Authorization", "Bearer oa");
    // GitLab unrecognized `<type>:<value>` → header `<type>: <value>`.
    try check.one(&fc, .gitlab, "https://gitea.example.org/g/p", "abc", "def");
    // No token configured for this host → no header.
    try testing.expect((try fc.authHeader(.github, "https://unlisted.example/x")) == null);
}

test "fetchTarball only serializes NAR when requested" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "archive-root", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "archive-root/file.txt", .data = "payload" });

    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    const base_path = try std.fs.path.resolve(testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(base_path);
    const archive_path = try std.fs.path.resolve(testing.allocator, &.{ base_path, "archive.tar.gz" });
    defer testing.allocator.free(archive_path);
    const cache_path = try std.fs.path.resolve(testing.allocator, &.{ base_path, "fetch-cache" });
    defer testing.allocator.free(cache_path);

    const tar = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ "tar", "-czf", archive_path, "-C", base_path, "archive-root" },
    });
    defer testing.allocator.free(tar.stdout);
    defer testing.allocator.free(tar.stderr);
    switch (tar.term) {
        .exited => |code| try testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTarFailure,
    }

    var files = FileCache.init(testing.allocator);
    defer files.deinit();
    files.setIo(testing.io);
    var fc = try FetchCache.init(testing.allocator, .{});
    defer fc.deinit();
    fc.setIo(testing.io);
    try fc.setCacheRoot(cache_path);

    const url = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{archive_path});
    defer testing.allocator.free(url);
    const unhashed = try fc.fetchTarball(&files, .{ .url = url, .name = "src" }, null);
    defer unhashed.deinit(testing.allocator);
    try testing.expect(unhashed.nar_payload == null);

    const hashed = try fc.fetchTarball(&files, .{ .url = url, .name = "src", .serialize_nar = true }, null);
    defer hashed.deinit(testing.allocator);
    const payload = hashed.nar_payload orelse return error.MissingNarPayload;
    var independently_hashed: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload.bytes, &independently_hashed, .{});
    try testing.expectEqualSlices(u8, &independently_hashed, &payload.digest);
}

test "URL metadata cheaply reuses immutable files and verifies legacy entries" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var fc = try FetchCache.init(testing.allocator, .{});
    defer fc.deinit();
    fc.setIo(testing.io);
    try fc.setCacheRoot(root);
    const payload = "verified payload";
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);
    const path = try fc.urlCachePath(testing.io, "source", &hash);
    defer testing.allocator.free(path);
    try fc.publishBytes(testing.io, path, payload);
    const metadata = try fc.urlMetadataPath(root, "https://example.invalid/source");
    defer testing.allocator.free(metadata);
    const stat = try std.Io.Dir.cwd().statFile(testing.io, path, .{ .follow_symlinks = false });
    const now = std.Io.Clock.real.now(testing.io).toSeconds();
    try fc.writeUrlMetadataAt(testing.io, metadata, now, &hash, stat.size);

    const cached = (try fc.readFreshUrlCache(testing.io, metadata, "source")).?;
    defer cached.deinit(testing.allocator);
    try testing.expectEqualStrings(&hash, cached.hash);

    // The old two-line format is validated once, then rewritten with the
    // identity stamp so the following lookup can take the cheap path.
    const legacy = try std.fmt.allocPrint(testing.allocator, "{d}\n{s}\n", .{ now, &hash });
    defer testing.allocator.free(legacy);
    try fc.publishBytes(testing.io, metadata, legacy);
    const legacy_cached = (try fc.readFreshUrlCache(testing.io, metadata, "source")).?;
    defer legacy_cached.deinit(testing.allocator);
    const upgraded = try std.Io.Dir.cwd().readFileAlloc(testing.io, metadata, testing.allocator, .limited(256));
    defer testing.allocator.free(upgraded);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, upgraded, "\n"));

    // Legacy metadata still hashes before it is trusted, including for a
    // same-size corruption that a size-only immutable-object check cannot see.
    try fc.publishBytes(testing.io, metadata, legacy);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "corrupt payload!" });
    const same_size_corrupt = try fc.readFreshUrlCache(testing.io, metadata, "source");
    defer if (same_size_corrupt) |result| result.deinit(testing.allocator);
    try testing.expect(same_size_corrupt == null);

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "corrupt" });
    const wrong_size_corrupt = try fc.readFreshUrlCache(testing.io, metadata, "source");
    defer if (wrong_size_corrupt) |result| result.deinit(testing.allocator);
    try testing.expect(wrong_size_corrupt == null);
    fc.setTarballTtl(0);
    try testing.expect((try fc.readFreshUrlCache(testing.io, metadata, "source")) == null);
}

test "URL generation pruning uses explicit timestamps and removes legacy orphans" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var fc = try FetchCache.init(testing.allocator, .{});
    defer fc.deinit();
    fc.setIo(testing.io);
    try fc.setCacheRoot(root);
    fc.setTarballTtl(10);

    const old_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const fresh_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const orphan_hash = "cccccccccccccccccccccccccccccccc";
    const old_url = try fc.urlCachePath(testing.io, "source", old_hash);
    defer testing.allocator.free(old_url);
    const fresh_url = try fc.urlCachePath(testing.io, "source", fresh_hash);
    defer testing.allocator.free(fresh_url);
    try fc.publishBytes(testing.io, old_url, "old");
    try fc.publishBytes(testing.io, fresh_url, "new");
    try fc.noteUrlGenerationAtRoot(testing.io, root, old_hash, 79);
    try fc.noteUrlGenerationAtRoot(testing.io, root, fresh_hash, 89);
    try fc.noteUrlGenerationAtRoot(testing.io, root, fresh_hash, 91);
    const superseded_marker = try std.fs.path.join(testing.allocator, &.{ root, "url-generations", fresh_hash[0..32], "89" });
    defer testing.allocator.free(superseded_marker);
    try testing.expect(!try hostPathExists(testing.io, superseded_marker));

    const old_metadata = try fc.urlMetadataPath(root, "https://old.invalid/source");
    defer testing.allocator.free(old_metadata);
    const fresh_metadata = try fc.urlMetadataPath(root, "https://fresh.invalid/source");
    defer testing.allocator.free(fresh_metadata);
    try fc.writeUrlMetadataAt(testing.io, old_metadata, 79, old_hash, 3);
    try fc.writeUrlMetadataAt(testing.io, fresh_metadata, 91, fresh_hash, 3);

    const orphan_url = try std.fs.path.join(testing.allocator, &.{ root, "url", orphan_hash, "source" });
    defer testing.allocator.free(orphan_url);
    const orphan_tarball = try std.fs.path.join(testing.allocator, &.{ root, "tarball", orphan_hash, "source", "default.nix" });
    defer testing.allocator.free(orphan_tarball);
    try fc.publishBytes(testing.io, orphan_url, "orphan");
    try fc.publishBytes(testing.io, orphan_tarball, "{}\n");

    try fc.pruneUrlCache(testing.io, root, 100);
    try testing.expect(!try hostPathExists(testing.io, old_url));
    try testing.expect(!try hostPathExists(testing.io, old_metadata));
    try testing.expect(try hostPathExists(testing.io, fresh_url));
    try testing.expect(try hostPathExists(testing.io, fresh_metadata));
    try testing.expect(!try hostPathExists(testing.io, orphan_url));
    try testing.expect(!try hostPathExists(testing.io, orphan_tarball));
}

test "http-connections zero remains truly unlimited" {
    var fc = try FetchCache.init(std.testing.allocator, .{});
    defer fc.deinit();
    try fc.setMaxConnections(0);
    try std.testing.expectEqual(@as(u32, 0), fc.max_connections);
    try std.testing.expect(fc.blockingPool() == null);
}

test "remote URL retries transient status then reuses the verified TTL cache" {
    const testing = std.testing;
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    const Server = struct {
        fn run(s: *std.Io.net.Server) void {
            for (0..2) |attempt| {
                const stream = s.accept(testing.io) catch return;
                defer stream.close(testing.io);
                var read_buffer: [2048]u8 = undefined;
                var reader = std.Io.net.Stream.Reader.init(stream, testing.io, &read_buffer);
                while (true) {
                    const line = reader.interface.takeDelimiterExclusive('\n') catch return;
                    if (line.len == 0 or std.mem.eql(u8, line, "\r")) break;
                }
                var buffer: [1024]u8 = undefined;
                var writer = std.Io.net.Stream.Writer.init(stream, testing.io, &buffer);
                if (attempt == 0)
                    writer.interface.writeAll("HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch return
                else
                    writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\npayload") catch return;
                writer.interface.flush() catch return;
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var files = FileCache.init(testing.allocator);
    defer files.deinit();
    files.setIo(testing.io);
    var fc = try FetchCache.init(testing.allocator, .{});
    defer fc.deinit();
    fc.setIo(testing.io);
    fc.setDownloadAttempts(2);
    try fc.setCacheRoot(root);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/source", .{server.socket.address.ip4.port});
    defer testing.allocator.free(url);

    const first = try fc.fetchUrl(&files, .{ .url = url, .name = "source" }, null);
    defer first.deinit(testing.allocator);
    try testing.expect(!first.cached);
    thread.join();
    const second = try fc.fetchUrl(&files, .{ .url = url, .name = "source" }, null);
    defer second.deinit(testing.allocator);
    try testing.expect(second.cached);
    try testing.expectEqualStrings(first.hash, second.hash);
    try testing.expectEqualStrings(first.path, second.path);
}
