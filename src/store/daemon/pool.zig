//! DaemonPool: N background threads, each owning a warm connection, draining a
//! shared job queue. You submit a job and park the caller (a compute fiber via
//! an evaluator executor, or the main thread blocking) while a worker runs
//! `job.run(conn)` on its connection and wakes you.
//!
//! This is the one execution path for every nix-daemon store op — `.drv`/source
//! writes, `isValidPath` queries, builds — so compute workers never block on the
//! socket, and connections stay warm and reused across the whole run (eval,
//! on-demand closure writes, and the terminal build).
//!
//! Ordering is NOT the pool's concern. The daemon enforces referential integrity
//! against its own committed state, so a write on ANY connection is valid once
//! its references are committed (on any connection). `RealizationStore`'s
//! demand-driven closure walk writes a path's references before the path itself
//! (deduping concurrent demand via realization claims), so write ordering is a
//! property of that walk, upstream of the pool — the pool just moves bytes
//! concurrently across a set of hot connections.
//!
//! Connections are injected via `Backend` (open/close of an opaque handle) so the
//! queue/threading is unit-testable with a mock and the pool file stays free of
//! any daemon-protocol dependency; the real backend opens a `DaemonStore`.

const std = @import("std");
const sync = @import("base").sync;
const store_backend = @import("../backend.zig");

/// Per-worker connection lifecycle. `open` runs once per worker thread (its own
/// connection, opened warm at spawn); `close` runs at shutdown. A failed `open`
/// is best-effort: the worker retries on its next job and, if still failing,
/// runs jobs with a null connection so the op surfaces `error.StoreUnavailable`
/// rather than hanging the parked caller.
pub const Backend = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque) anyerror!*anyopaque,
    close: *const fn (ctx: *anyopaque, conn: *anyopaque) void,
};

pub const DaemonPool = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    worker_count: usize,

    mu: sync.BlockingMutex = .{},
    /// Bumped on every submit and on shutdown; idle workers futex-wait on it (a
    /// submit that races the wait bumps the value so the wait returns).
    seq: std.atomic.Value(u32) = .init(0),
    head: ?*Job = null,
    tail: ?*Job = null,
    threads: std.ArrayListUnmanaged(std.Thread) = .empty,
    started: bool = false,
    shutdown: bool = false,

    /// A unit of backend work. The job lives on the parked caller's stack, so
    /// submission stays allocation-free.
    pub const Job = store_backend.Job;

    pub fn init(allocator: std.mem.Allocator, backend: Backend, worker_count: usize) DaemonPool {
        return .{ .allocator = allocator, .backend = backend, .worker_count = @max(worker_count, 1) };
    }

    /// Spawn the worker threads; each opens its connection warm (concurrently,
    /// before the first job). Call once, after the pool is at its final address
    /// (heap-allocate it — the threads capture `self`).
    pub fn start(self: *DaemonPool) !void {
        self.started = true;
        errdefer self.stop();
        var i: usize = 0;
        while (i < self.worker_count) : (i += 1) {
            try self.threads.append(self.allocator, try std.Thread.spawn(.{}, worker, .{self}));
        }
    }

    /// Enqueue a job. `job` must outlive its execution — in practice it lives on
    /// the parked caller's stack, which stays parked until the job wakes it.
    /// Alloc-free and infallible.
    pub fn submit(self: *DaemonPool, job: *Job) void {
        job.next = null;
        self.mu.lock();
        if (self.tail) |tl| tl.next = job else self.head = job;
        self.tail = job;
        self.mu.unlock();
        self.wake();
    }

    /// Submit `work(conn)` and block the CALLING thread until a worker has run it.
    /// For callers with no fiber to park — the main-thread terminal build, and
    /// tests — which have nothing else to do meanwhile. (Fiber callers park
    /// instead; see `execution.runOnPool`.)
    pub fn submitBlocking(self: *DaemonPool, work: *const fn (conn: ?*anyopaque, ctx: *anyopaque) void, ctx: *anyopaque) void {
        var cell: BlockingCell = .{ .work = work, .ctx = ctx };
        var job: Job = .{ .run = BlockingCell.run, .ctx = &cell };
        self.submit(&job);
        cell.done.acquire();
    }

    const BlockingCell = struct {
        work: *const fn (conn: ?*anyopaque, ctx: *anyopaque) void,
        ctx: *anyopaque,
        done: sync.Semaphore = sync.Semaphore.init(0),

        fn run(conn: ?*anyopaque, p: *anyopaque) void {
            const self: *BlockingCell = @ptrCast(@alignCast(p));
            self.work(conn, self.ctx);
            self.done.release();
        }
    };

    /// Stop the workers after draining queued jobs, join, and close connections.
    /// Callers must ensure no caller is still parked on an unsubmitted job (drive
    /// the compute pool to quiescence first). Idempotent.
    pub fn deinit(self: *DaemonPool) void {
        self.stop();
        self.threads.deinit(self.allocator);
    }

    fn stop(self: *DaemonPool) void {
        if (!self.started) return;
        self.mu.lock();
        self.shutdown = true;
        self.mu.unlock();
        self.wake();
        for (self.threads.items) |t| t.join();
        self.threads.clearRetainingCapacity();
        self.started = false;
    }

    fn wake(self: *DaemonPool) void {
        _ = self.seq.fetchAdd(1, .release);
        sync.Futex.wake(&self.seq, std.math.maxInt(u32));
    }

    fn worker(self: *DaemonPool) void {
        // Open the connection warm, up front (overlapped with eval / other
        // workers). A failed warm open is retried on the first job; if it keeps
        // failing, jobs run with a null connection.
        var conn: ?*anyopaque = self.backend.open(self.backend.ctx) catch null;
        defer if (conn) |c| self.backend.close(self.backend.ctx, c);

        while (true) {
            self.mu.lock();
            while (self.head == null and !self.shutdown) {
                const s = self.seq.load(.acquire);
                self.mu.unlock();
                sync.Futex.wait(&self.seq, s);
                self.mu.lock();
            }
            if (self.head == null and self.shutdown) {
                self.mu.unlock();
                return;
            }
            // Detach one job (read `next` before running: `run` wakes the parked
            // caller, which may resume and reuse the job's stack frame).
            const job = self.head.?;
            self.head = job.next;
            if (self.head == null) self.tail = null;
            self.mu.unlock();

            if (conn == null) conn = self.backend.open(self.backend.ctx) catch null;
            job.run(conn, job.ctx);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests — mock backend: `open` hands out a small counter object, `run` records
// that it saw a connection. Exercises warm-open, concurrent draining, shutdown.
// ---------------------------------------------------------------------------

const testing = std.testing;

const MockBackend = struct {
    opens: std.atomic.Value(usize) = .init(0),
    closes: std.atomic.Value(usize) = .init(0),
    // A distinct heap sentinel per open, freed on close.
    allocator: std.mem.Allocator,

    fn backend(self: *MockBackend) Backend {
        return .{ .ctx = self, .open = open, .close = close };
    }
    fn open(ctx: *anyopaque) anyerror!*anyopaque {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        _ = self.opens.fetchAdd(1, .monotonic);
        const p = try self.allocator.create(u8);
        p.* = 1;
        return p;
    }
    fn close(ctx: *anyopaque, conn: *anyopaque) void {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        _ = self.closes.fetchAdd(1, .monotonic);
        self.allocator.destroy(@as(*u8, @ptrCast(conn)));
    }
};

const CountJob = struct {
    ran: std.atomic.Value(usize),
    saw_conn: std.atomic.Value(usize),
    fn run(conn: ?*anyopaque, ctx: *anyopaque) void {
        const self: *CountJob = @ptrCast(@alignCast(ctx));
        _ = self.ran.fetchAdd(1, .monotonic);
        if (conn != null) _ = self.saw_conn.fetchAdd(1, .monotonic);
    }
};

test "daemon pool: warm workers drain all submitted jobs on live connections" {
    const alloc = testing.allocator;
    var mock: MockBackend = .{ .allocator = alloc };
    var pool = DaemonPool.init(alloc, mock.backend(), 4);
    try pool.start();

    var counter: CountJob = .{ .ran = .init(0), .saw_conn = .init(0) };
    const n = 200;
    var jobs: [n]DaemonPool.Job = undefined;
    for (&jobs) |*j| j.* = .{ .run = CountJob.run, .ctx = &counter };
    for (&jobs) |*j| pool.submit(j);

    // Drain: workers only exit on shutdown, so joining flushes the queue.
    pool.deinit();

    try testing.expectEqual(@as(usize, n), counter.ran.load(.monotonic));
    try testing.expectEqual(@as(usize, n), counter.saw_conn.load(.monotonic));
    // Every worker opened exactly one warm connection and closed it.
    try testing.expectEqual(@as(usize, 4), mock.opens.load(.monotonic));
    try testing.expectEqual(@as(usize, 4), mock.closes.load(.monotonic));
}
