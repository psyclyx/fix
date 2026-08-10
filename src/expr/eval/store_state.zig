//! Store-side evaluator state that survives language-state teardown.
//!
//! This is the composition point for realization, the default daemon runtime,
//! and the adapter that parks daemon work off compute fibers. Alternate store
//! drivers own their execution policy and do not use this runtime.

const std = @import("std");
const store = @import("store");
const realization = store.realization;

pub const StoreState = struct {
    pub const AsyncBuildRequest = realization.RealizationStore.AsyncBuildRequest;
    allocator: std.mem.Allocator,
    realization: realization.RealizationStore,
    daemon_runtime: *store.DaemonRuntime,

    pub fn init(allocator: std.mem.Allocator) !StoreState {
        const runtime_ptr = try allocator.create(store.DaemonRuntime);
        errdefer allocator.destroy(runtime_ptr);
        runtime_ptr.* = store.DaemonRuntime.init();
        errdefer runtime_ptr.deinit();

        var realization_store = realization.RealizationStore.init(allocator);
        realization_store.setExecution(runtime_ptr, @import("workers.zig").daemon_executor);
        return .{ .allocator = allocator, .realization = realization_store, .daemon_runtime = runtime_ptr };
    }

    pub fn deinit(self: *StoreState) void {
        self.realization.clearExecution();
        self.daemon_runtime.deinit();
        self.allocator.destroy(self.daemon_runtime);
        self.realization.deinit();
    }

    pub fn setBackend(self: *StoreState, driver: store.BackendDriver) !void {
        return self.realization.setBackend(driver);
    }

    pub fn buildPaths(self: *StoreState, paths: []const []const u8, sink: ?store.daemon.BuildSink, mode: store.daemon.BuildMode) !void {
        return self.realization.buildPaths(paths, sink, mode);
    }

    pub fn queryMissing(self: *StoreState, paths: []const []const u8) !store.daemon.MissingPlan {
        return self.realization.queryMissing(paths);
    }

    pub fn submitBuild(self: *StoreState, request: *AsyncBuildRequest) void {
        self.realization.submitBuild(request);
    }

    pub fn lastError(self: *StoreState) ?[]const u8 {
        return self.realization.lastStoreError();
    }

    pub fn addIndirectRoot(self: *StoreState, link_path: []const u8, target: []const u8) !void {
        return self.realization.addIndirectRoot(link_path, target);
    }
};
