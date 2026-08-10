//! Execution capability used by realization without depending on an evaluator
//! worker implementation.

const Future = @import("runtime").future.Future;
const DaemonPool = @import("../daemon.zig").DaemonPool;
const backend = @import("../backend.zig");

pub const WorkFn = backend.WorkFn;

pub const Executor = struct {
    run_pool_fn: *const fn (pool: *DaemonPool, work: WorkFn, context: *anyopaque) void,
    park_future_fn: *const fn (future: *Future) bool,

    pub fn runPool(self: Executor, pool: *DaemonPool, work: WorkFn, context: *anyopaque) void {
        self.run_pool_fn(pool, work, context);
    }

    pub fn parkFuture(self: Executor, future: *Future) bool {
        return self.park_future_fn(future);
    }
};
