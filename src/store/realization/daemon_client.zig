//! Store-backend selection, execution dispatch, and presence cache.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("base").sync;
const rstore = @import("../daemon.zig");
const backend = @import("../backend.zig");
const DaemonRuntime = @import("../daemon/runtime.zig").DaemonRuntime;
const Future = @import("runtime").future.Future;
const daemon_execution = @import("daemon_execution.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    mu: sync.BlockingMutex = .{},
    last_error_msg: ?[]u8 = null,
    instantiated: std.StringHashMapUnmanaged(void) = .empty,
    io: ?std.Io = null,
    socket: []const u8 = rstore.default_socket_path,
    socket_owned: ?[]u8 = null,
    options: ?rstore.BuildSettings = null,
    overrides: std.ArrayListUnmanaged(rstore.Setting) = .empty,
    writes_enabled: bool = false,
    pool_executor: ?daemon_execution.Executor = null,
    runtime: ?*DaemonRuntime = null,
    active_driver: ?backend.Driver = null,
    backend_mu: sync.BlockingMutex = .{},
    backend_driver: ?backend.Driver = null,
    backend_started: bool = false,
    test_owned_runtime: if (builtin.is_test) ?*DaemonRuntime else void = if (builtin.is_test) null else {},

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Client) void {
        if (comptime builtin.is_test) {
            if (self.test_owned_runtime) |runtime| {
                runtime.deinit();
                self.allocator.destroy(runtime);
                self.test_owned_runtime = null;
            }
        }
        var instantiated = self.instantiated.keyIterator();
        while (instantiated.next()) |key| self.allocator.free(key.*);
        self.instantiated.deinit(self.allocator);
        deinitOverrides(self.allocator, &self.overrides);
        if (self.socket_owned) |owned| self.allocator.free(owned);
        if (self.last_error_msg) |message| self.allocator.free(message);
        if (self.backend_driver) |selected| selected.destroy();
    }

    pub fn setBuildSettings(self: *Client, settings: rstore.BuildSettings) !void {
        var replacement: std.ArrayListUnmanaged(rstore.Setting) = .empty;
        errdefer deinitOverrides(self.allocator, &replacement);
        try replacement.ensureTotalCapacity(self.allocator, settings.overrides.len);
        for (settings.overrides) |override| {
            const name = try self.allocator.dupe(u8, override.name);
            errdefer self.allocator.free(name);
            const value = try self.allocator.dupe(u8, override.value);
            errdefer self.allocator.free(value);
            replacement.appendAssumeCapacity(.{
                .name = name,
                .value = value,
            });
        }

        deinitOverrides(self.allocator, &self.overrides);
        self.overrides = replacement;
        var owned = settings;
        owned.overrides = self.overrides.items;
        self.options = owned;
    }

    pub fn setSocket(self: *Client, path: []const u8) !void {
        if (path.len == 0) return;
        const owned = try self.allocator.dupe(u8, path);
        if (self.socket_owned) |old| self.allocator.free(old);
        self.socket_owned = owned;
        self.socket = owned;
    }

    pub fn setBorrowedSocket(self: *Client, path: []const u8) void {
        if (comptime !builtin.is_test) unreachable;
        if (self.socket_owned) |owned| self.allocator.free(owned);
        self.socket_owned = null;
        self.socket = path;
    }

    pub fn socketPath(self: *const Client) []const u8 {
        return self.socket;
    }

    pub fn writesEnabled(self: *const Client) bool {
        return self.writes_enabled;
    }

    pub fn setIo(self: *Client, io: std.Io) void {
        self.io = io;
    }

    /// Replace the default worker-protocol backend. Selection is allowed only
    /// before backend execution starts; the client owns `driver` through
    /// `deinit` (a borrowed driver leaves its vtable's `destroy` null).
    pub fn setBackend(self: *Client, selected: backend.Driver) !void {
        self.backend_mu.lock();
        defer self.backend_mu.unlock();
        if (self.active_driver != null) return error.BackendAlreadyStarted;
        if (self.backend_driver) |old| old.destroy();
        self.backend_driver = selected;
        self.backend_started = false;
    }

    pub fn enableWrites(self: *Client) void {
        self.writes_enabled = true;
        _ = self.ensureBackend() catch {};
    }

    pub fn setExecution(self: *Client, runtime: *DaemonRuntime, executor: daemon_execution.Executor) void {
        self.runtime = runtime;
        self.pool_executor = executor;
        runtime.setExecutor(executor);
    }

    pub fn clearExecution(self: *Client) void {
        if (self.runtime) |runtime| runtime.setExecutor(null);
        self.pool_executor = null;
        self.runtime = null;
        // `active_driver` is `ensureBackend`'s state, so drop it under its lock.
        // Both kinds of driver stay started across this, and neither may be
        // started twice: `backend_started` guards a selected driver, and the
        // default daemon is recovered from its runtime by `startedDriver`.
        self.backend_mu.lock();
        defer self.backend_mu.unlock();
        self.active_driver = null;
    }

    pub fn takeRuntime(self: *Client, runtime: *DaemonRuntime) void {
        if (comptime !builtin.is_test) unreachable;
        self.runtime = runtime;
        self.test_owned_runtime = runtime;
    }

    fn ensureBackend(self: *Client) !backend.Driver {
        self.backend_mu.lock();
        defer self.backend_mu.unlock();
        if (self.active_driver) |driver| return driver;
        if (self.backend_driver) |driver| {
            // A driver's `start` is not idempotent (it spawns its worker set),
            // and a selection outlives `clearExecution`, so start it at most
            // once. The default daemon has its own guard in `configureDaemon`.
            if (!self.backend_started) {
                try driver.start();
                self.backend_started = true;
            }
            self.active_driver = driver;
            return driver;
        }
        const runtime = self.runtime orelse return error.StoreUnavailable;
        // A runtime re-attached after `clearExecution` keeps the pool it already
        // started, and its configuration was fixed at that first start, so take
        // the running driver back rather than asking `configureDaemon` to
        // reconfigure a started backend and refuse.
        if (runtime.startedDriver()) |driver| {
            self.active_driver = driver;
            return driver;
        }
        const io = self.io orelse return error.StoreUnavailable;
        const driver = try runtime.configureDaemon(
            self.allocator,
            io,
            self.socket,
            self.options,
            self.writes_enabled,
        );
        try driver.start();
        self.active_driver = driver;
        return driver;
    }

    pub fn connection(self: *Client, raw: ?*anyopaque) !backend.Connection {
        const driver = self.active_driver orelse return error.StoreUnavailable;
        return driver.connection(raw orelse return error.StoreUnavailable);
    }

    pub fn run(self: *Client, work: *const fn (conn: ?*anyopaque, work_ctx: *anyopaque) void, work_ctx: *anyopaque) !void {
        const driver = try self.ensureBackend();
        return driver.run(work, work_ctx);
    }

    /// Dispatch backend work without requiring the submitter to wait here. A
    /// driver may finish inline; otherwise the caller keeps the job alive until
    /// its callback signals completion.
    pub fn submit(self: *Client, job: *backend.Job) !void {
        const driver = try self.ensureBackend();
        return driver.submit(job);
    }

    pub fn captureError(self: *Client, conn: backend.Connection) void {
        const message = conn.lastError() orelse return;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.last_error_msg != null) return;
        self.last_error_msg = self.allocator.dupe(u8, message) catch null;
    }

    pub fn lastError(self: *Client) ?[]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.last_error_msg;
    }

    pub fn cacheContains(self: *Client, store_path: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.instantiated.contains(store_path);
    }

    pub fn cacheMark(self: *Client, store_path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.instantiated.contains(store_path)) return;
        const key = self.allocator.dupe(u8, store_path) catch return;
        self.instantiated.put(self.allocator, key, {}) catch self.allocator.free(key);
    }

    pub fn parkClaim(self: *Client, future: *Future) bool {
        return if (self.pool_executor) |executor| executor.parkFuture(future) else false;
    }
};

fn deinitOverrides(
    allocator: std.mem.Allocator,
    overrides: *std.ArrayListUnmanaged(rstore.Setting),
) void {
    for (overrides.items) |override| {
        allocator.free(override.name);
        allocator.free(override.value);
    }
    overrides.deinit(allocator);
    overrides.* = .empty;
}

fn checkBuildSettingsAllocationFailures(allocator: std.mem.Allocator) !void {
    var client = Client.init(allocator);
    defer client.deinit();
    try client.setBuildSettings(.{ .overrides = &.{
        .{ .name = "max-jobs", .value = "4" },
        .{ .name = "cores", .value = "8" },
    } });
    try std.testing.expectEqual(@as(usize, 2), client.overrides.items.len);
}

test "build settings own complete overrides across every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkBuildSettingsAllocationFailures,
        .{},
    );
}
