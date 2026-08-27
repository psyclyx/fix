//! Realization facade coordinating the derivation registry, evaluation memo,
//! recipe/claim graph, and daemon client.

const std = @import("std");
const builtin = @import("builtin");
const derivation = @import("../derivation.zig");
const drv_mod = derivation.drv;
const types = derivation.types;
const sync = @import("base").sync;
const observ = @import("base").observ;
const runtime = @import("runtime");
const rstore = @import("../daemon.zig");
const backend = @import("../backend.zig");
const FileCache = @import("../file_cache.zig").FileCache;
const DaemonRuntime = @import("../daemon/runtime.zig").DaemonRuntime;
const Waiter = runtime.future.Waiter;
const eval_memo = @import("eval_memo.zig");
const recipe_graph = @import("recipe_graph.zig");
const daemon_client = @import("daemon_client.zig");
const daemon_execution = @import("daemon_execution.zig");

const check_observation: observ.SpanSpec = .{
    .category = "daemon",
    .name = "check",
    .begin_verb = "checking",
    .finish_verb = "checked",
    .begin_level = 2,
    .finish_level = 1,
};
const query_observation: observ.SpanSpec = .{
    .category = "daemon",
    .name = "query",
    .begin_verb = "querying",
    .finish_verb = "queried",
    .begin_level = 0,
};
const build_observation: observ.SpanSpec = .{
    .category = "daemon",
    .name = "build",
    .begin_verb = "building",
    .finish_verb = "built",
    .begin_level = 0,
};
const register_observation: observ.SpanSpec = .{
    .category = "daemon",
    .name = "register",
    .begin_verb = "registering",
    .finish_verb = "registered",
};
const store_observation: observ.SpanSpec = .{
    .category = "daemon",
    .name = "store",
    .begin_verb = "storing",
    .finish_verb = "stored",
    .begin_level = 1,
};

const DebugRecord = types.DebugRecord;
const ComputedPaths = types.ComputedPaths;
const Drv = drv_mod.Drv;
const DrvOutput = types.DrvOutput;
const HashModuloResolver = types.HashModuloResolver;
const HashModuloView = types.HashModuloView;

/// Thread safety: all access to `records` and `debug_records` goes through
/// `mu`. The store is read-mostly during evaluation but writes (record /
/// recordDebug) happen on whichever worker forces the originating thunk.
/// Extract the `name` argument required by daemon add-to-store operations.
/// This is protocol data, not a presentation label: progress retains `path`.
fn daemonStoreName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (base.len > 33 and base[32] == '-') return base[33..];
    return base;
}

fn pathsLabel(buffer: []u8, paths: []const []const u8) []const u8 {
    if (paths.len == 0) return "paths";
    if (paths.len == 1) return paths[0];
    return std.fmt.bufPrint(buffer, "{d} paths", .{paths.len}) catch "paths";
}

test "progress labels retain complete store paths" {
    const path = "/nix/store/01234567890123456789012345678901-hello-1.0.drv";
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(path, pathsLabel(&buffer, &.{path}));
    try std.testing.expectEqualStrings("hello-1.0.drv", daemonStoreName(path));
}

pub const RealizationStore = struct {
    allocator: std.mem.Allocator,
    /// The store directory (`store-dir`, default `/nix/store`). Borrowed static
    /// literal until `setStoreDir` replaces it with an owned copy from config.
    store_dir: []const u8 = "/nix/store",
    store_dir_owned: ?[]u8 = null,
    registry: derivation.Registry,
    memo: eval_memo.EvalMemo,
    graph: recipe_graph.Graph,
    daemon: daemon_client.Client,
    observer: observ.Observer = .{},
    /// Legacy read-write evaluation materializes each demand-evaluated
    /// derivation immediately. Normal instantiate/build keep this false and
    /// materialize only their requested terminal closure.
    eager_evaluation_writes: bool = false,

    /// The deliberately narrow test capability. Production users see one
    /// inert declaration instead of a family of `ForTest` methods mixed into
    /// the store API; test builds receive controlled graph and daemon access.
    pub const TestAccess = if (builtin.is_test) struct {
        store: *RealizationStore,

        pub const RecipeKind = recipe_graph.RecipeKind;
        pub const RootClaimHook = recipe_graph.RootClaimHook;

        pub fn setRootClaimHook(self: TestAccess, hook: ?RootClaimHook) void {
            self.store.graph.test_root_claim_hook = hook;
        }

        /// Consume producer allocation observations and return the one retained
        /// by the recipe. Consumption prevents stale-map false positives.
        pub fn producerPayloadPointer(self: TestAccess, store_path: []const u8) ?usize {
            const store = self.store;
            store.graph.mu.lock();
            defer store.graph.mu.unlock();
            var removed = store.graph.test_producer_payload_pointers.fetchRemove(store_path) orelse return null;
            defer store.allocator.free(removed.key);
            defer removed.value.deinit(store.allocator);
            const retained = if (store.graph.recipes.get(store_path)) |recipe| recipe.payloadPointer() else null;
            if (retained) |pointer| {
                for (removed.value.items) |observed| if (observed == pointer) return observed;
            }
            return if (removed.value.items.len == 0) null else removed.value.items[0];
        }

        pub fn recipeCount(self: TestAccess) usize {
            self.store.graph.mu.lock();
            defer self.store.graph.mu.unlock();
            return self.store.graph.recipes.count();
        }

        pub fn recipeKind(self: TestAccess, store_path: []const u8) ?RecipeKind {
            self.store.graph.mu.lock();
            defer self.store.graph.mu.unlock();
            const recipe = self.store.graph.recipes.get(store_path) orelse return null;
            return switch (recipe.payload) {
                .text => .text,
                .nar => .nar,
                .flat => .flat,
            };
        }

        pub fn recipePayloadPointer(self: TestAccess, store_path: []const u8) ?usize {
            self.store.graph.mu.lock();
            defer self.store.graph.mu.unlock();
            return (self.store.graph.recipes.get(store_path) orelse return null).payloadPointer();
        }

        pub fn recipePayloadBytes(self: TestAccess, store_path: []const u8) ?[]const u8 {
            self.store.graph.mu.lock();
            defer self.store.graph.mu.unlock();
            const recipe = self.store.graph.recipes.get(store_path) orelse return null;
            return switch (recipe.payload) {
                .text => |text| text.bytes,
                .nar => |bytes| bytes,
                .flat => |bytes| bytes.bytes(),
            };
        }

        pub fn recipeReferences(self: TestAccess, store_path: []const u8) ?[]const []const u8 {
            self.store.graph.mu.lock();
            defer self.store.graph.mu.unlock();
            return (self.store.graph.recipes.get(store_path) orelse return null).references();
        }

        pub fn useBorrowedDaemonSocket(self: TestAccess, path: []const u8) void {
            self.store.daemon.setBorrowedSocket(path);
        }

        pub fn takeDaemonRuntime(self: TestAccess, daemon_runtime: *DaemonRuntime) void {
            self.store.daemon.takeRuntime(daemon_runtime);
        }
    } else struct {};

    pub fn testAccess(self: *RealizationStore) TestAccess {
        if (comptime builtin.is_test) return .{ .store = self };
        return .{};
    }

    /// A source-memo hit, with slices duplicated into the *caller's* allocator
    /// so it can be dropped into an `Ingested` (which is caller-owned).
    pub const SourceMemoHit = eval_memo.SourceMemoHit;

    pub const PendingFetch = recipe_graph.PendingFetch;

    /// Register a deferred fetch for `store_path` (no-op if one already exists).
    pub fn recordPendingFetch(self: *RealizationStore, store_path: []const u8, url: []const u8, name: []const u8, recursive: bool, hash_hex: []const u8) !void {
        return self.graph.recordPendingFetch(store_path, url, name, recursive, hash_hex);
    }

    /// Return an owned copy of the deferred fetch for exactly `store_path`, or
    /// null. The entry is left in place — concurrent demands each materialize
    /// against the (memoized) fetch cache; `removePendingFetch` drops it once a
    /// flat file is seeded. Caller owns the copy and must `deinit` it.
    pub fn peekPendingFetch(self: *RealizationStore, store_path: []const u8) !?PendingFetch {
        return self.graph.peekPendingFetch(store_path);
    }

    pub fn removePendingFetch(self: *RealizationStore, store_path: []const u8) void {
        self.graph.removePendingFetch(store_path);
    }

    const Recipe = recipe_graph.Recipe;
    const RealizationClaim = recipe_graph.Claim;

    pub fn init(allocator: std.mem.Allocator) RealizationStore {
        return .{
            .allocator = allocator,
            .registry = derivation.Registry.init(allocator),
            .memo = eval_memo.EvalMemo.init(allocator),
            .graph = recipe_graph.Graph.init(allocator),
            .daemon = daemon_client.Client.init(allocator),
        };
    }

    pub fn deinit(self: *RealizationStore) void {
        self.daemon.deinit();
        self.graph.deinit();
        self.registry.deinit();
        self.memo.deinit();
        if (self.store_dir_owned) |owned| self.allocator.free(owned);
    }

    /// Override the store directory (`store-dir` / `NIX_STORE_DIR`). Dupes `dir`
    /// into owned storage (freed in `deinit`); a no-op if empty.
    pub fn setStoreDir(self: *RealizationStore, dir: []const u8) !void {
        if (dir.len == 0) return;
        const owned = try self.allocator.dupe(u8, dir);
        if (self.store_dir_owned) |old| self.allocator.free(old);
        self.store_dir_owned = owned;
        self.store_dir = owned;
    }

    /// Set the per-connection daemon settings to apply on connect. Dupes the
    /// overrides into owned storage (freed in `deinit`).
    pub fn setBuildSettings(self: *RealizationStore, settings: rstore.BuildSettings) !void {
        return self.daemon.setBuildSettings(settings);
    }

    /// Override the nix-daemon socket path (from `$NIX_DAEMON_SOCKET_PATH`).
    /// Dupes `path` into owned storage (freed in `deinit`); a no-op if empty.
    pub fn setDaemonSocket(self: *RealizationStore, path: []const u8) !void {
        return self.daemon.setSocket(path);
    }

    pub fn daemonSocket(self: *const RealizationStore) []const u8 {
        return self.daemon.socketPath();
    }

    pub fn storeWritesEnabled(self: *const RealizationStore) bool {
        return self.daemon.writesEnabled();
    }

    /// Provide the IO handle used to connect to the daemon on demand.
    pub fn setIo(self: *RealizationStore, io: std.Io) void {
        self.daemon.setIo(io);
    }

    /// Select an alternate store backend before backend execution starts.
    /// The realization graph and evaluator-facing API remain unchanged.
    pub fn setBackend(self: *RealizationStore, driver: backend.Driver) !void {
        return self.daemon.setBackend(driver);
    }

    /// Enable writing forced derivations + their sources to the store
    /// (`fix instantiate`/`build`). Off by default so plain eval stays pure.
    /// Eagerly starts the selected backend after configuration. For the daemon
    /// driver this warms its connections concurrently with evaluation instead
    /// of on a compute fiber's critical path at the first store operation.
    pub fn enableStoreWrites(self: *RealizationStore) void {
        self.daemon.enableWrites();
    }

    pub fn enableEagerEvaluationWrites(self: *RealizationStore) void {
        self.eager_evaluation_writes = true;
        self.enableStoreWrites();
    }

    pub fn eagerEvaluationWritesEnabled(self: *const RealizationStore) bool {
        return self.eager_evaluation_writes;
    }

    /// Materialize a just-recorded recipe when legacy read-write evaluation is
    /// on. Sources and `toFile` objects have no terminal closure to pull them
    /// in — the CLI prints the evaluated value and exits — so unlike a `.drv`
    /// under `instantiate`/`build` nothing would ever walk their recipe. A
    /// no-op in every other mode, which keeps plain eval off the store.
    /// Callers must not hold a source-ingest stripe lock: this parks the fiber
    /// on daemon round-trips.
    pub fn materializeEagerRecipe(self: *RealizationStore, store_path: []const u8) !void {
        if (!self.eager_evaluation_writes) return;
        return self.ensureClosure(store_path);
    }

    pub fn setObserver(self: *RealizationStore, observer: observ.Observer) void {
        self.observer = observer;
    }

    /// Install the fiber-aware execution capability. Must be set before forcing
    /// begins and cleared before the daemon runtime is torn down.
    pub fn setExecution(self: *RealizationStore, rt: *DaemonRuntime, executor: daemon_execution.Executor) void {
        self.daemon.setExecution(rt, executor);
    }

    pub fn clearExecution(self: *RealizationStore) void {
        self.daemon.clearExecution();
    }

    /// Recover the selected backend connection handed to a driver callback.
    /// Keep it explicit through the operation instead of installing ambient
    /// thread-local state.
    fn storeConn(self: *RealizationStore, raw: ?*anyopaque) !backend.Connection {
        return self.daemon.connection(raw);
    }

    /// Run one store op using the selected driver's execution policy. The
    /// daemon driver parks evaluator fibers around pool work; another driver
    /// may execute directly or use its own scheduler.
    fn runOnStore(self: *RealizationStore, work: *const fn (conn: ?*anyopaque, work_ctx: *anyopaque) void, work_ctx: *anyopaque) !void {
        return self.daemon.run(work, work_ctx);
    }

    /// Copy a failing op's backend message out of its transient connection so
    /// `lastStoreError` can surface it after reuse. First writer wins.
    fn captureStoreError(self: *RealizationStore, conn: backend.Connection) void {
        self.daemon.captureError(conn);
    }

    /// Read the last daemon error message (for surfacing `error.DaemonError`),
    /// captured from the pool connection whose op failed.
    pub fn lastStoreError(self: *RealizationStore) ?[]const u8 {
        return self.daemon.lastError();
    }

    /// Write `drv_path`'s `.drv` to the store (text-addressed), gated on
    /// `store_writes_enabled`. Inputs are forced before dependents, so a
    /// `.drv`'s referenced input `.drv`s are already written when we get here.
    pub fn instantiateDrv(self: *RealizationStore, drv_path: []const u8, aterm: []const u8, references: []const []const u8) !void {
        return self.instantiateText(drv_path, aterm, references);
    }

    /// Write a text-addressed object (a `.drv` or `builtins.toFile` result),
    /// gated on `store_writes_enabled` (off during plain eval).
    pub fn instantiateText(self: *RealizationStore, store_path: []const u8, text: []const u8, references: []const []const u8) !void {
        if (!self.daemon.writes_enabled) return;
        return self.runStoreOp(.{ .text = .{ .store_path = store_path, .text = text, .references = references } }, true);
    }

    /// Write a NAR-serialized source tree, gated on `store_writes_enabled`.
    /// Sources ingest during derivation normalization — before the `.drv` that
    /// references them — so `input_srcs` are valid in time.
    pub fn instantiatePath(self: *RealizationStore, store_path: []const u8, nar_bytes: []const u8) !void {
        if (!self.daemon.writes_enabled) return;
        return self.runStoreOp(.{ .path = .{ .store_path = store_path, .nar_bytes = nar_bytes } }, true);
    }

    /// Add a flat file's raw bytes to the store (fetchurl), gated on
    /// `store_writes_enabled`.
    pub fn instantiateFlat(self: *RealizationStore, store_path: []const u8, bytes: []const u8) !void {
        if (!self.daemon.writes_enabled) return;
        return self.runStoreOp(.{ .flat = .{ .store_path = store_path, .bytes = bytes } }, true);
    }

    /// Is `store_path` already valid in the store? Used to skip fetching an
    /// input we already have (content-addressed, so a valid path for a given
    /// hash IS the right content). Only meaningful with store writes enabled
    /// (else there is no daemon); returns false otherwise. Offloaded like the
    /// writes so the calling fiber parks rather than blocking on the socket.
    pub fn pathIsValid(self: *RealizationStore, store_path: []const u8) !bool {
        if (!self.daemon.writes_enabled) return false;
        return self.queryPathValid(store_path);
    }

    fn queryPathValid(self: *RealizationStore, store_path: []const u8) !bool {
        // Caller-side cache hit: skip the backend round-trip entirely (the closure
        // walk hits this for every already-present path).
        if (self.cacheContains(store_path)) return true;
        var cell: QueryCell = .{ .store = self, .store_path = store_path };
        try self.runOnStore(QueryCell.run, &cell);
        if (cell.err) |e| return e;
        return cell.valid;
    }

    const QueryCell = struct {
        store: *RealizationStore,
        store_path: []const u8,
        valid: bool = false,
        err: ?anyerror = null,

        fn run(conn: ?*anyopaque, p: *anyopaque) void {
            const c: *QueryCell = @ptrCast(@alignCast(p));
            const store_conn = c.store.storeConn(conn) catch |e| {
                c.err = e;
                return;
            };
            c.valid = c.store.applyIsValid(store_conn, c.store_path) catch |e| {
                c.err = e;
                return;
            };
        }
    };

    /// Read a regular-file store object's contents through the selected backend.
    pub fn readFileViaStore(self: *RealizationStore, allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
        if (!self.daemon.writes_enabled) return error.StoreUnavailable;
        var cell: NarCell = .{ .store = self, .allocator = allocator, .store_path = store_path };
        try self.runOnStore(NarCell.run, &cell);
        if (cell.err) |e| return e;
        return cell.data orelse error.StoreUnavailable;
    }

    /// Compatibility spelling for callers that still assume the default Nix
    /// worker-protocol backend.
    pub fn readFileViaDaemon(self: *RealizationStore, allocator: std.mem.Allocator, store_path: []const u8) ![]u8 {
        return self.readFileViaStore(allocator, store_path);
    }

    const NarCell = struct {
        store: *RealizationStore,
        allocator: std.mem.Allocator,
        store_path: []const u8,
        data: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(conn: ?*anyopaque, p: *anyopaque) void {
            const c: *NarCell = @ptrCast(@alignCast(p));
            const store_conn = c.store.storeConn(conn) catch |e| {
                c.err = e;
                return;
            };
            c.data = store_conn.readFile(c.allocator, c.store_path) catch |e| {
                c.store.captureStoreError(store_conn);
                c.err = e;
                return;
            };
        }
    };

    /// `isValidPath` against the supplied connection, consulting +
    /// populating the `instantiated` cache. The daemon round-trip runs without
    /// `daemon_mu` held (it guards only the brief cache touches), so concurrent
    /// pool workers don't serialize on it.
    fn applyIsValid(self: *RealizationStore, conn: backend.Connection, store_path: []const u8) !bool {
        if (self.cacheContains(store_path)) return true;
        var span = self.observer.beginOn(&check_observation, .{ .subject = .{ .path = store_path } }, .daemon);
        defer span.cancel();
        const valid = conn.isValidPath(store_path) catch |err| {
            self.captureStoreError(conn);
            return err;
        };
        // A path valid now stays valid for the eval (same assumption the cache
        // already makes for writes), so a later demand skips the round-trip.
        if (valid) self.cacheMark(store_path);
        span.finish(.{ .metrics = &.{.{
            .name = "valid",
            .value = .{ .unsigned = @intFromBool(valid) },
        }} });
        return valid;
    }

    /// Realize `derived_paths` (`<drvpath>!<outputs>`, legacy format) via the
    /// daemon, forwarding the build activity/log stream to `sink` if given.
    /// Dispatched to the pool (fiber parks / main thread blocks) so the whole
    /// build runs on a warm worker connection, not a compute worker.
    pub fn buildPaths(self: *RealizationStore, derived_paths: []const []const u8, sink: ?rstore.BuildSink, mode: rstore.BuildMode) !void {
        var cell: BuildCell = .{ .store = self, .paths = derived_paths, .sink = sink, .mode = mode };
        try self.runOnStore(BuildCell.run, &cell);
        return cell.err;
    }

    pub fn queryMissing(self: *RealizationStore, derived_paths: []const []const u8) !rstore.MissingPlan {
        var cell: MissingCell = .{ .store = self, .paths = derived_paths };
        try self.runOnStore(MissingCell.run, &cell);
        return cell.result;
    }

    const MissingCell = struct {
        store: *RealizationStore,
        paths: []const []const u8,
        result: anyerror!rstore.MissingPlan = error.StoreUnavailable,

        fn run(conn: ?*anyopaque, raw: *anyopaque) void {
            const self: *MissingCell = @ptrCast(@alignCast(raw));
            const store_conn = self.store.storeConn(conn) catch |err| {
                self.result = err;
                return;
            };
            var label_buffer: [128]u8 = undefined;
            const label = pathsLabel(&label_buffer, self.paths);
            var span = self.store.observer.beginOn(&query_observation, .{ .subject = .{ .text = label } }, .daemon);
            defer span.cancel();
            const result = store_conn.queryMissing(self.store.allocator, self.paths) catch |err| {
                self.store.captureStoreError(store_conn);
                self.result = err;
                return;
            };
            self.result = result;
            span.finish(.{});
        }
    };

    /// Caller-owned asynchronous build request. Its path slices and sink must
    /// remain valid through `wait`; the selected driver may finish inline or
    /// signal `done` after asynchronous execution.
    pub const AsyncBuildRequest = struct {
        store: ?*RealizationStore = null,
        paths: []const []const u8 = &.{},
        sink: ?rstore.BuildSink = null,
        mode: rstore.BuildMode = .normal,
        job: backend.Job = undefined,
        done: sync.Semaphore = sync.Semaphore.init(0),
        result: anyerror!void = {},

        pub fn init(paths: []const []const u8, sink: ?rstore.BuildSink, mode: rstore.BuildMode) AsyncBuildRequest {
            return .{ .paths = paths, .sink = sink, .mode = mode };
        }

        pub fn fail(self: *AsyncBuildRequest, err: anyerror) void {
            self.result = err;
            self.done.release();
        }

        pub fn wait(self: *AsyncBuildRequest) !void {
            self.done.acquire();
            return self.result;
        }

        fn run(conn: ?*anyopaque, raw: *anyopaque) void {
            const self: *AsyncBuildRequest = @ptrCast(@alignCast(raw));
            const store = self.store.?;
            const store_conn = store.storeConn(conn) catch |err| {
                self.result = err;
                self.done.release();
                return;
            };
            self.result = store.buildOnConn(store_conn, self.paths, self.sink, self.mode);
            self.done.release();
        }
    };

    /// Hand a build to the selected driver. It may complete inline; startup or
    /// submission failures complete the request with that error, keeping the
    /// wait path uniform for callers.
    pub fn submitBuild(self: *RealizationStore, request: *AsyncBuildRequest) void {
        request.store = self;
        request.job = .{ .run = AsyncBuildRequest.run, .ctx = request };
        self.daemon.submit(&request.job) catch |err| request.fail(err);
    }

    /// Realize `derived_paths` for import-from-derivation. Same as `buildPaths`;
    /// kept as a distinct entry for the `run`/`shell` realize call sites.
    pub fn realizePaths(self: *RealizationStore, derived_paths: []const []const u8, mode: rstore.BuildMode) !void {
        return self.buildPaths(derived_paths, null, mode);
    }

    /// Build against the connection supplied by the pool worker.
    fn buildOnConn(self: *RealizationStore, conn: backend.Connection, derived_paths: []const []const u8, sink: ?rstore.BuildSink, mode: rstore.BuildMode) !void {
        var label_buffer: [128]u8 = undefined;
        const label = pathsLabel(&label_buffer, derived_paths);
        // A typed activity sink reports the actual builds/substitutions inside
        // this request. Use a coarse fallback only for internal builds (IFD),
        // where no daemon activity stream is installed.
        var span = if (sink == null)
            self.observer.beginOn(&build_observation, .{ .subject = .{ .text = label } }, .daemon)
        else
            observ.Span{};
        defer span.cancel();
        conn.buildPaths(derived_paths, sink, mode) catch |err| {
            self.captureStoreError(conn);
            return err;
        };
        span.finish(.{});
    }

    const BuildCell = struct {
        store: *RealizationStore,
        paths: []const []const u8,
        sink: ?rstore.BuildSink = null,
        mode: rstore.BuildMode,
        err: anyerror!void = {},

        fn run(conn: ?*anyopaque, p: *anyopaque) void {
            const self: *BuildCell = @ptrCast(@alignCast(p));
            const store_conn = self.store.storeConn(conn) catch |e| {
                self.err = e;
                return;
            };
            self.err = self.store.buildOnConn(store_conn, self.paths, self.sink, self.mode);
        }
    };

    /// Register `link_path` (an existing absolute symlink into the store) as an
    /// indirect GC root via the daemon.
    pub fn addIndirectRoot(self: *RealizationStore, link_path: []const u8, target: []const u8) !void {
        var cell: RootCell = .{ .store = self, .link_path = link_path, .target = target };
        try self.runOnStore(RootCell.run, &cell);
        return cell.err;
    }

    const RootCell = struct {
        store: *RealizationStore,
        link_path: []const u8,
        target: []const u8,
        err: anyerror!void = {},

        fn run(conn: ?*anyopaque, p: *anyopaque) void {
            const self: *RootCell = @ptrCast(@alignCast(p));
            self.err = blk: {
                const c = self.store.storeConn(conn) catch |e| break :blk e;
                var span = self.store.observer.beginOn(
                    &register_observation,
                    .{
                        .subject = .{ .path = self.link_path },
                        .destination = .{ .path = self.target },
                    },
                    .daemon,
                );
                defer span.cancel();
                c.addIndirectRoot(self.link_path, self.target) catch |err| {
                    self.store.captureStoreError(c);
                    break :blk err;
                };
                span.finish(.{});
                break :blk {};
            };
        }
    };

    const StoreOp = union(enum) {
        text: struct { store_path: []const u8, text: []const u8, references: []const []const u8 },
        path: struct { store_path: []const u8, nar_bytes: []const u8 },
        flat: struct { store_path: []const u8, bytes: []const u8 },
    };

    /// Dispatch a store write to the pool (parking the caller) or inline. The op's
    /// args are borrowed and stay valid across the transfer because the calling
    /// fiber parks (its stack — holding the NAR/text buffers — is preserved).
    fn runStoreOp(self: *RealizationStore, op: StoreOp, report_progress: bool) !void {
        var cell: OpCell = .{ .store = self, .op = op, .report_progress = report_progress };
        try self.runOnStore(OpCell.run, &cell);
        return cell.err;
    }

    const OpCell = struct {
        store: *RealizationStore,
        op: StoreOp,
        report_progress: bool = false,
        err: anyerror!void = {},

        fn run(conn: ?*anyopaque, p: *anyopaque) void {
            const self: *OpCell = @ptrCast(@alignCast(p));
            const store_conn = self.store.storeConn(conn) catch |e| {
                self.err = e;
                return;
            };
            self.err = self.store.applyStoreOp(store_conn, self.op, self.report_progress);
        }
    };

    /// Perform a store write against the supplied connection. Skips the transfer
    /// when the path is already valid (cache or a daemon check). Cache touches are
    /// briefly guarded; the daemon round-trips run without `daemon_mu`.
    fn applyStoreOp(self: *RealizationStore, store_conn: backend.Connection, op: StoreOp, report_progress: bool) !void {
        const store_path = switch (op) {
            inline else => |o| o.store_path,
        };
        if (self.cacheContains(store_path)) return;
        if (try self.applyIsValid(store_conn, store_path)) return;
        // The fetch that produced this content and its store write are distinct
        // operations, so both get spans. Open this only after the validity
        // check confirms that a transfer will actually happen.
        var span = if (report_progress)
            self.observer.beginOn(&store_observation, .{ .subject = .{ .path = store_path } }, .daemon)
        else
            observ.Span{};
        defer span.cancel();
        const object: backend.AddObject = switch (op) {
            .text => |o| .{ .text = .{
                .expected_path = store_path,
                .name = daemonStoreName(store_path),
                .bytes = o.text,
                .references = o.references,
            } },
            .path => |o| .{ .nar = .{
                .expected_path = store_path,
                .name = daemonStoreName(store_path),
                .bytes = o.nar_bytes,
            } },
            .flat => |o| .{ .flat = .{
                .expected_path = store_path,
                .name = daemonStoreName(store_path),
                .bytes = o.bytes,
            } },
        };
        const written = store_conn.addObject(self.allocator, object) catch |err| {
            self.captureStoreError(store_conn);
            return err;
        };
        defer self.allocator.free(written);
        if (!std.mem.eql(u8, written, store_path)) return error.StorePathMismatch;
        self.cacheMark(store_path);
        span.finish(.{});
    }

    /// Is `store_path` known present this run? Guarded read of `instantiated`.
    fn cacheContains(self: *RealizationStore, store_path: []const u8) bool {
        return self.daemon.cacheContains(store_path);
    }

    /// Record `store_path` as present (a write landed, or a query confirmed it).
    /// Best-effort: a cache-insert OOM just means a later redundant round-trip.
    fn cacheMark(self: *RealizationStore, store_path: []const u8) void {
        self.daemon.cacheMark(store_path);
    }

    pub fn recordOwnedTextRecipe(self: *RealizationStore, store_path: []const u8, text: []u8, references: []const []const u8) !void {
        self.noteProducerPayload(store_path, text) catch |err| {
            self.allocator.free(text);
            return err;
        };
        return self.graph.recordOwnedText(store_path, text, references);
    }

    pub fn recordOwnedNarRecipe(self: *RealizationStore, store_path: []const u8, nar_bytes: []u8) !void {
        self.noteProducerPayload(store_path, nar_bytes) catch |err| {
            self.allocator.free(nar_bytes);
            return err;
        };
        return self.graph.recordOwnedNar(store_path, nar_bytes);
    }

    pub fn recordFlatRecipe(self: *RealizationStore, store_path: []const u8, handle: FileCache.ImmutableBytes, report_progress: bool) !void {
        return self.graph.recordFlat(store_path, handle, report_progress);
    }

    /// Test-build observation at the ownership-transfer boundary. Keeping this
    /// inside the store means producers only perform the real domain operation;
    /// they do not know that allocation identity is under test.
    fn noteProducerPayload(self: *RealizationStore, store_path: []const u8, payload: []const u8) !void {
        if (comptime builtin.is_test) {
            self.graph.mu.lock();
            defer self.graph.mu.unlock();
            const owned_path = try self.allocator.dupe(u8, store_path);
            const result = self.graph.test_producer_payload_pointers.getOrPut(self.allocator, owned_path) catch |err| {
                self.allocator.free(owned_path);
                return err;
            };
            if (result.found_existing) {
                self.allocator.free(owned_path);
            } else {
                result.value_ptr.* = .empty;
            }
            const pointer = @intFromPtr(payload.ptr);
            for (result.value_ptr.items) |observed| if (observed == pointer) return;
            result.value_ptr.append(self.allocator, pointer) catch |err| {
                if (!result.found_existing) {
                    const removed = self.graph.test_producer_payload_pointers.fetchRemove(store_path).?;
                    self.allocator.free(removed.key);
                }
                return err;
            };
        }
    }

    /// Whether evaluation recorded a deferred producer for `store_path`.
    /// Path-demand builtins use this to realize `toFile` and source recipes
    /// that carry path context but no derivation-output descriptor.
    pub fn hasRecipe(self: *RealizationStore, store_path: []const u8) bool {
        self.graph.mu.lock();
        defer self.graph.mu.unlock();
        return self.graph.recipes.contains(store_path);
    }

    pub fn releaseRecipePayloads(self: *RealizationStore) void {
        self.graph.releaseRecipePayloads();
    }

    const Visit = struct {
        path: []const u8,
        claim: *RealizationClaim,
        parent: ?*const Visit,
    };

    /// Materialize `store_path`'s closure. Runs on the DEMANDING caller — a
    /// compute fiber for IFD (`demandPathArg`), the main thread for the terminal
    /// realize/instantiate — so a wait on another realizer's claim is a normal
    /// fiber park (or a thread block off a fiber). Only the individual daemon
    /// round-trips (queries/writes/builds) are offloaded to the pool.
    pub fn ensureClosure(self: *RealizationStore, store_path: []const u8) anyerror!void {
        return self.ensureClosureInner(store_path, null);
    }

    fn ensureClosureInner(self: *RealizationStore, store_path: []const u8, parent: ?*const Visit) anyerror!void {
        while (true) {
            // Deps-first: a path's references are realized (and land in the store)
            // before the path itself. Each daemon round-trip goes to the pool; a
            // concurrent realizer of the same path deduplicates via the claim.
            if (try self.queryPathValid(store_path)) return;
            if (visitContains(parent, store_path)) return error.RecipeCycle;

            const claim_result = try self.claimMissingPath(store_path);
            const claim = claim_result.claim;
            defer claim.release(self.allocator);

            if (comptime builtin.is_test) {
                if (claim_result.writer and parent == null) {
                    if (self.graph.test_root_claim_hook) |hook| hook.observe(hook.ctx, store_path);
                }
            }

            if (!claim_result.writer) {
                const wait_source: ?*RealizationClaim = if (parent) |visit| blk: {
                    if (self.beginClaimWait(visit.claim, claim)) return error.RecipeCycle;
                    break :blk visit.claim;
                } else null;
                const state = self.waitForClaim(claim);
                if (wait_source) |source| self.endClaimWait(source, claim);
                switch (state) {
                    .success => return,
                    .retry => continue,
                    .permanent_failure => return claim.err.?,
                    .writing => unreachable,
                }
            }

            // Double-check now that we hold the writer claim. Another writer may
            // have realized (and cached) this path between our top-of-loop
            // validity check and claiming — its claim (and single-use recipe) is
            // gone now, so without this we'd become a spurious second writer and
            // hit MissingStoreRecipe. It marks the cache before releasing its
            // claim, so a cache hit here means it finished.
            if (self.cacheContains(store_path)) {
                self.finishSuccessfulClaim(store_path, claim);
                return;
            }

            const visit: Visit = .{ .path = store_path, .claim = claim, .parent = parent };
            self.ensureClosureWriter(store_path, &visit) catch |err| {
                if (isRetryableRealizationError(err)) {
                    self.finishRetryableClaim(store_path, claim, err);
                } else {
                    claim.publish(.permanent_failure, err);
                }
                return err;
            };
            self.finishSuccessfulClaim(store_path, claim);
            return;
        }
    }

    /// Realize `drv_path`'s outputs (IFD / terminal build). Runs on the demanding
    /// caller (see `ensureClosure`): the closure is materialized deps-first, then
    /// the build is offloaded to the pool. A concurrent realizer of the same
    /// output deduplicates via the claim (a normal fiber park / thread block).
    pub fn realizeOutput(self: *RealizationStore, drv_path: []const u8, outputs: []const []const u8) !void {
        try self.ensureClosureInner(drv_path, null);
        const derived = try self.derivedPathString(drv_path, outputs);
        defer self.allocator.free(derived);

        while (true) {
            self.graph.mu.lock();
            const already_realized = self.graph.realized_outputs.contains(derived);
            self.graph.mu.unlock();
            if (already_realized) return;

            const claim_result = try self.claimMissingPath(derived);
            const claim = claim_result.claim;
            defer claim.release(self.allocator);
            if (!claim_result.writer) {
                switch (self.waitForClaim(claim)) {
                    .success => return,
                    .retry => continue,
                    .permanent_failure => return claim.err.?,
                    .writing => unreachable,
                }
            }

            // The build itself is offloaded to the pool (the demanding caller
            // parks / blocks); the `.drv` closure is already on disk above.
            self.buildPaths(&.{derived}, null, .normal) catch |err| {
                if (isRetryableRealizationError(err)) {
                    self.finishRetryableClaim(derived, claim, err);
                } else {
                    claim.publish(.permanent_failure, err);
                }
                return err;
            };
            self.markOutputRealized(derived) catch |err| {
                self.finishRetryableClaim(derived, claim, err);
                return err;
            };
            self.finishSuccessfulClaim(derived, claim);
            return;
        }
    }

    fn markOutputRealized(self: *RealizationStore, derived: []const u8) !void {
        const key = try self.allocator.dupe(u8, derived);
        errdefer self.allocator.free(key);
        self.graph.mu.lock();
        defer self.graph.mu.unlock();
        const result = try self.graph.realized_outputs.getOrPut(self.allocator, key);
        if (result.found_existing) self.allocator.free(key);
    }

    fn ensureClosureWriter(self: *RealizationStore, store_path: []const u8, visit: *const Visit) anyerror!void {
        const recipe = blk: {
            self.graph.mu.lock();
            defer self.graph.mu.unlock();
            break :blk self.graph.recipes.get(store_path) orelse return error.MissingStoreRecipe;
        };

        for (recipe.references()) |reference| try self.ensureClosureInner(reference, visit);
        // References are on disk now; write this path (offloaded to the pool). The
        const report_progress = recipe.report_progress;
        switch (recipe.payload) {
            .text => |text| try self.runStoreOp(.{ .text = .{ .store_path = store_path, .text = text.bytes, .references = text.references } }, report_progress),
            .nar => |nar_bytes| try self.runStoreOp(.{ .path = .{ .store_path = store_path, .nar_bytes = nar_bytes } }, report_progress),
            .flat => |bytes| try self.runStoreOp(.{ .flat = .{ .store_path = store_path, .bytes = bytes.bytes() } }, report_progress),
        }
        self.releaseRecipeForPath(store_path);
    }

    fn claimMissingPath(self: *RealizationStore, store_path: []const u8) !struct { claim: *RealizationClaim, writer: bool } {
        self.graph.mu.lock();
        defer self.graph.mu.unlock();

        if (self.graph.claims.get(store_path)) |claim| {
            claim.retain();
            return .{ .claim = claim, .writer = false };
        }

        const claim = try self.allocator.create(RealizationClaim);
        errdefer self.allocator.destroy(claim);
        claim.* = .{};
        claim.retain();
        errdefer claim.release(self.allocator);

        const key = try self.allocator.dupe(u8, store_path);
        errdefer self.allocator.free(key);
        try self.graph.claims.put(self.allocator, key, claim);
        return .{ .claim = claim, .writer = true };
    }

    fn visitContains(parent: ?*const Visit, path: []const u8) bool {
        var cursor = parent;
        while (cursor) |visit| : (cursor = visit.parent) {
            if (std.mem.eql(u8, visit.path, path)) return true;
        }
        return false;
    }

    /// Add one cold-path wait-for edge and report whether it closes a cycle.
    /// The edge retains its target and is visible only under `recipe_mu`.
    fn beginClaimWait(self: *RealizationStore, source: *RealizationClaim, target: *RealizationClaim) bool {
        self.graph.mu.lock();
        defer self.graph.mu.unlock();
        std.debug.assert(source.waiting_on == null);
        target.retain();
        source.waiting_on = target;

        var cursor: ?*RealizationClaim = target;
        while (cursor) |claim| : (cursor = claim.waiting_on) {
            if (claim == source) {
                source.waiting_on = null;
                target.release(self.allocator);
                return true;
            }
        }
        return false;
    }

    fn endClaimWait(self: *RealizationStore, source: *RealizationClaim, target: *RealizationClaim) void {
        self.graph.mu.lock();
        defer self.graph.mu.unlock();
        if (source.waiting_on == target) {
            source.waiting_on = null;
            target.release(self.allocator);
        }
    }

    fn waitForClaim(self: *RealizationStore, claim: *RealizationClaim) RealizationClaim.State {
        while (true) {
            claim.mu.lock();
            const state = claim.state;
            claim.mu.unlock();
            if (state != .writing) return state;
            // Park until the claim's future is published, then re-read the state.
            // A compute fiber yields (`fiber_park`); anything else (main-thread
            // realize, tests) blocks on a semaphore woken by the same publish.
            if (self.daemon.parkClaim(&claim.future)) continue;
            var w: SemaphoreWaiter = .{ .waiter = .{ .wake_fn = SemaphoreWaiter.wake } };
            if (claim.future.enrollWaiter(&w.waiter)) w.sem.acquire();
        }
    }

    /// A `Future` waiter that wakes a blocked thread (no fiber to park): its
    /// `wake_fn` releases the semaphore the waiter is parked on. Lives on the
    /// waiting thread's stack — safe because `wakeFiberWaiters` reads `next`
    /// before calling `wake_fn`.
    const SemaphoreWaiter = struct {
        waiter: Waiter,
        sem: sync.Semaphore = sync.Semaphore.init(0),

        fn wake(waiter: *Waiter) void {
            const self: *SemaphoreWaiter = @fieldParentPtr("waiter", waiter);
            self.sem.release();
        }
    };

    fn finishSuccessfulClaim(self: *RealizationStore, store_path: []const u8, claim: *RealizationClaim) void {
        self.removeClaim(store_path, claim);
        claim.publish(.success, null);
    }

    fn finishRetryableClaim(self: *RealizationStore, store_path: []const u8, claim: *RealizationClaim, err: anyerror) void {
        self.removeClaim(store_path, claim);
        claim.publish(.retry, err);
    }

    fn removeClaim(self: *RealizationStore, store_path: []const u8, claim: *RealizationClaim) void {
        self.graph.mu.lock();
        defer self.graph.mu.unlock();
        const removed = self.graph.claims.fetchRemove(store_path) orelse return;
        std.debug.assert(removed.value == claim);
        self.allocator.free(removed.key);
        claim.release(self.allocator);
    }

    fn releaseRecipeForPath(self: *RealizationStore, store_path: []const u8) void {
        self.graph.mu.lock();
        defer self.graph.mu.unlock();
        const removed = self.graph.recipes.fetchRemove(store_path) orelse return;
        self.allocator.free(removed.key);
        removed.value.deinit(self.allocator);
    }

    fn derivedPathString(self: *RealizationStore, drv_path: []const u8, outputs: []const []const u8) ![]u8 {
        var rendered: std.ArrayListUnmanaged(u8) = .empty;
        errdefer rendered.deinit(self.allocator);
        try rendered.appendSlice(self.allocator, drv_path);
        // The classic `buildPaths` worker op parses each request with Nix/Lix's
        // legacy `DerivedPath::parseLegacy`, which splits on `!` (a `^` is not
        // recognized and the whole string is parsed as a store path — the daemon
        // then rejects the `^` as an illegal character). So render `<drv>!<outs>`.
        try rendered.append(self.allocator, '!');
        if (outputs.len == 0) {
            try rendered.append(self.allocator, '*');
        } else {
            const ordered = try self.allocator.alloc([]const u8, outputs.len);
            defer self.allocator.free(ordered);
            @memcpy(ordered, outputs);
            std.mem.sort([]const u8, ordered, {}, struct {
                fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                    return std.mem.order(u8, left, right) == .lt;
                }
            }.lessThan);

            var previous: ?[]const u8 = null;
            for (ordered) |output| {
                if (previous) |seen| {
                    if (std.mem.eql(u8, seen, output)) continue;
                    try rendered.append(self.allocator, ',');
                }
                try rendered.appendSlice(self.allocator, output);
                previous = output;
            }
        }
        return rendered.toOwnedSlice(self.allocator);
    }

    fn isRetryableRealizationError(err: anyerror) bool {
        return switch (err) {
            // A null pool connection (the worker could not reach the daemon) —
            // transient, like the raw connect errors below (which the pool
            // surfaces as this once it abstracts the per-connection open).
            error.StoreUnavailable,
            error.OutOfMemory,
            error.FileNotFound,
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            error.SystemResources,
            error.WouldBlock,
            error.TemporaryNameServerFailure,
            error.NetworkSubsystemFailed,
            error.Unexpected,
            => true,
            else => false,
        };
    }

    /// Look up a memoized ingestion. On a hit, the store path + NAR hash are
    /// duplicated into `out_allocator` (caller-owned, for an `Ingested`).
    ///
    /// `filter_id`/`token` are null for unfiltered ingests (keyed purely on
    /// content-stable path+name, so they survive GCs). For a *filtered* ingest
    /// the key includes the filter lambda's ObjectId, which a GC can reuse for a
    /// different lambda — so `token` (the heap GC token) is stored per entry and
    /// a mismatch is treated as a miss, exactly like `lookupLazyDerivation`.
    /// The single-flight stripe lock for an unfiltered ingest of `(path, name)`.
    /// Callers lock it, re-check the memo, serialize on a miss, and unlock — so
    /// concurrent coercers of the same source don't each re-serialize. See
    /// `source_ingest_locks`.
    pub fn sourceIngestLock(self: *RealizationStore, path: []const u8, name: []const u8) *sync.BlockingMutex {
        return self.memo.sourceIngestLock(path, name);
    }

    pub fn lookupSourceMemo(
        self: *RealizationStore,
        out_allocator: std.mem.Allocator,
        path: []const u8,
        name: []const u8,
        recursive: bool,
        filter_id: ?u32,
        token: ?u64,
    ) !?SourceMemoHit {
        return self.memo.lookupSource(out_allocator, path, name, recursive, filter_id, token);
    }

    /// Record a computed ingestion for reuse this eval. Dupes the key and both
    /// slices into `self.allocator`. On a key collision: an unfiltered entry (or
    /// a filtered entry whose token still matches) is a genuine race — drop the
    /// new copy; a filtered entry whose token differs is stale (the filter's
    /// ObjectId was reused after a GC) — replace it.
    pub fn storeSourceMemo(
        self: *RealizationStore,
        path: []const u8,
        name: []const u8,
        recursive: bool,
        filter_id: ?u32,
        token: u64,
        store_path: []const u8,
        nar_hash: []const u8,
    ) !void {
        return self.memo.storeSource(path, name, recursive, filter_id, token, store_path, nar_hash);
    }

    /// Look up a cached `buildForcedDerivationValue(.lazy)` result.
    /// Returns the cached `Value.bits` if present, `null` otherwise.
    pub fn lookupLazyDerivation(self: *RealizationStore, attrs_id: u32, token: u64) ?u64 {
        return self.memo.lookupLazyDerivation(attrs_id, token);
    }

    /// Cache the result of `buildForcedDerivationValue(.lazy)` for
    /// future per-attr lookups against the same input attrs.
    pub fn cacheLazyDerivation(self: *RealizationStore, attrs_id: u32, token: u64, value_bits: u64) !void {
        return self.memo.cacheLazyDerivation(attrs_id, token, value_bits);
    }

    pub fn visitLiveLazyDerivations(self: *RealizationStore, token: u64, context: anytype, comptime visit: anytype) void {
        self.memo.visitLiveLazyValues(token, context, visit);
    }

    pub fn setDebugEnabled(self: *RealizationStore, enabled: bool) void {
        self.registry.setDebugEnabled(enabled);
    }

    pub fn debugEnabled(self: *RealizationStore) bool {
        return self.registry.debugEnabled();
    }

    pub fn clearDebugRecords(self: *RealizationStore) void {
        self.registry.clearDebugRecords();
    }

    /// Returns a borrowed slice. Caller must not invoke `record*` concurrently.
    /// Used at end-of-evaluation from the main thread after helpers have quiesced.
    pub fn debugRecords(self: *const RealizationStore) []const DebugRecord {
        return self.registry.debugRecords();
    }

    pub fn resolver(self: *RealizationStore) HashModuloResolver {
        return self.registry.resolver(self.store_dir);
    }

    pub fn record(self: *RealizationStore, drv_path: []const u8, hash_modulo: HashModuloView, outputs: []const DrvOutput) !void {
        return self.registry.record(drv_path, hash_modulo, outputs);
    }

    pub fn recordDebug(self: *RealizationStore, drv: *const Drv, computed: ComputedPaths) !void {
        return self.registry.recordDebug(self.store_dir, drv, computed);
    }

    pub fn outputNames(self: *RealizationStore, drv_path: []const u8) ?[]const []const u8 {
        return self.registry.outputNames(drv_path);
    }
};

test "eager evaluation writes enable store writes without changing the default" {
    var store = RealizationStore.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expect(!store.storeWritesEnabled());
    try std.testing.expect(!store.eagerEvaluationWritesEnabled());

    store.enableEagerEvaluationWrites();
    try std.testing.expect(store.storeWritesEnabled());
    try std.testing.expect(store.eagerEvaluationWritesEnabled());
}
