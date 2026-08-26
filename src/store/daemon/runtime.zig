//! DaemonRuntime owns the background infrastructure used by the built-in Nix
//! worker-protocol backend.
//!
//! The backend-neutral Driver interface does not require a pool. This runtime
//! is the daemon driver's chosen execution policy: a set of hot connections on
//! background threads, with evaluator fibers parked while a worker runs.

const std = @import("std");
const rstore = @import("../daemon.zig");
const backend = @import("../backend.zig");
const daemon_backend = @import("backend.zig");
const daemon_execution = @import("../realization/daemon_execution.zig");
const sync = @import("base").sync;

const DaemonPool = rstore.DaemonPool;

/// Hot-connection count. These threads are IO-bound and independent of the
/// evaluator's compute workers. Bounds concurrent client-driven builds.
const default_pool_workers: usize = 8;

pub const DaemonRuntime = struct {
    pool: DaemonPool = undefined,
    pool_started: bool = false,
    pool_mu: sync.BlockingMutex = .{},
    daemon_config: DaemonConfig = .{},
    executor: ?daemon_execution.Executor = null,
    /// Hot-connection count. Tests override this with a small value.
    pool_workers: usize = default_pool_workers,

    /// Pool workers retain this runtime-owned configuration rather than a
    /// pointer to the movable realization client that selected it.
    const DaemonConfig = struct {
        allocator: std.mem.Allocator = undefined,
        io: std.Io = undefined,
        socket: []const u8 = "",
        options: ?rstore.BuildSettings = null,
        apply_options: bool = false,
    };

    pub fn init() DaemonRuntime {
        return .{};
    }

    /// Configure and return the built-in daemon driver. Configuration is fixed
    /// once the driver starts, just like selecting any alternate backend.
    pub fn configureDaemon(
        self: *DaemonRuntime,
        allocator: std.mem.Allocator,
        io: std.Io,
        socket: []const u8,
        options: ?rstore.BuildSettings,
        apply_options: bool,
    ) !backend.Driver {
        self.pool_mu.lock();
        defer self.pool_mu.unlock();
        if (self.pool_started) return error.BackendAlreadyStarted;
        self.daemon_config = .{
            .allocator = allocator,
            .io = io,
            .socket = socket,
            .options = options,
            .apply_options = apply_options,
        };
        return self.driver();
    }

    /// Install the evaluator capability that parks fibers around daemon-pool
    /// work. Tests and non-evaluator callers leave this null and block instead.
    pub fn setExecutor(self: *DaemonRuntime, executor: ?daemon_execution.Executor) void {
        self.executor = executor;
    }

    fn driver(self: *DaemonRuntime) backend.Driver {
        return .{ .ptr = self, .vtable = &driver_vtable };
    }

    fn ensurePool(self: *DaemonRuntime) !*DaemonPool {
        self.pool_mu.lock();
        defer self.pool_mu.unlock();
        if (self.pool_started) return &self.pool;

        self.pool = DaemonPool.init(self.daemon_config.allocator, .{
            .ctx = &self.daemon_config,
            .open = openDaemon,
            .close = closeDaemon,
        }, self.pool_workers);
        self.pool.start() catch |err| {
            self.pool.deinit();
            return err;
        };
        self.pool_started = true;
        return &self.pool;
    }

    fn openDaemon(raw: *anyopaque) !*anyopaque {
        const config: *DaemonConfig = @ptrCast(@alignCast(raw));
        const daemon = try rstore.DaemonStore.connect(config.allocator, config.io, config.socket);
        errdefer daemon.deinit();
        // Explicit store-writing commands apply their resolved client options.
        // Plain evaluation may perform IFD but leaves system config authoritative.
        if (config.apply_options) {
            if (config.options) |options| try daemon.setOptions(options);
        }
        return daemon;
    }

    fn closeDaemon(_: *anyopaque, raw: *anyopaque) void {
        const daemon: *rstore.DaemonStore = @ptrCast(@alignCast(raw));
        daemon.deinit();
    }

    pub fn deinit(self: *DaemonRuntime) void {
        if (self.pool_started) self.pool.deinit();
    }

    const driver_vtable: backend.Driver.VTable = .{
        .start = startDriver,
        .run = runDriver,
        .submit = submitDriver,
        .connection = driverConnection,
    };

    fn fromDriver(raw: *anyopaque) *DaemonRuntime {
        return @ptrCast(@alignCast(raw));
    }

    fn startDriver(raw: *anyopaque) !void {
        _ = try fromDriver(raw).ensurePool();
    }

    fn runDriver(raw: *anyopaque, work: backend.WorkFn, context: *anyopaque) !void {
        const self = fromDriver(raw);
        const pool = try self.ensurePool();
        if (self.executor) |executor| {
            executor.runPool(pool, work, context);
        } else {
            pool.submitBlocking(work, context);
        }
    }

    fn submitDriver(raw: *anyopaque, job: *backend.Job) !void {
        const pool = try fromDriver(raw).ensurePool();
        pool.submit(job);
    }

    fn driverConnection(_: *anyopaque, raw_connection: *anyopaque) backend.Connection {
        return .{ .context = raw_connection, .vtable = &daemon_backend.vtable };
    }
};

test "daemon driver retains runtime-owned configuration" {
    var runtime = DaemonRuntime.init();
    runtime.pool_workers = 1;
    defer runtime.deinit();

    const driver = try runtime.configureDaemon(
        std.testing.allocator,
        std.testing.io,
        "/definitely/missing/fix-test-daemon.sock",
        null,
        false,
    );
    try std.testing.expect(driver.ptr == @as(*anyopaque, @ptrCast(&runtime)));
    try driver.start();
    try std.testing.expect(runtime.pool.backend.ctx == @as(*anyopaque, @ptrCast(&runtime.daemon_config)));

    var raw_connection: u8 = 0;
    const connection = driver.connection(&raw_connection);
    try std.testing.expect(connection.vtable == &daemon_backend.vtable);
}
