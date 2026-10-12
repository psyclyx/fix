//! Stop-the-world and parallel-mark coordination owned by the scheduler.

const std = @import("std");

pub const MarkHook = struct {
    ctx: *anyopaque,
    help: *const fn (ctx: *anyopaque, worker_id: u8) void,
};

pub const Barrier = struct {
    const State = enum(u8) {
        idle,
        collecting,
        releasing,
    };

    state: std.atomic.Value(u8) = .init(@backingInt(State.idle)),
    worker_parked: []std.atomic.Value(bool),
    mark_open: std.atomic.Value(bool) = .init(false),
    mark_hook: ?MarkHook = null,

    pub fn init(allocator: std.mem.Allocator, worker_count: u8) !Barrier {
        const parked = try allocator.alloc(std.atomic.Value(bool), worker_count);
        for (parked) |*flag| flag.* = .init(false);
        return .{ .worker_parked = parked };
    }

    pub fn deinit(self: *Barrier, allocator: std.mem.Allocator) void {
        allocator.free(self.worker_parked);
        self.worker_parked = &.{};
    }

    pub inline fn requested(self: *const Barrier) bool {
        return self.state.load(.acquire) == @backingInt(State.collecting);
    }

    pub fn tryBegin(self: *Barrier) bool {
        return self.state.cmpxchgStrong(
            @backingInt(State.idle),
            @backingInt(State.collecting),
            .acq_rel,
            .monotonic,
        ) == null;
    }

    pub fn waitAllParked(self: *Barrier, collector_id: u8) void {
        for (self.worker_parked, 0..) |*flag, id| {
            if (id == collector_id) continue;
            while (!flag.load(.acquire)) std.atomic.spinLoopHint();
        }
    }

    pub fn end(self: *Barrier, collector_id: u8) void {
        // Let this cycle's peers leave, but keep the barrier unavailable to a
        // new collector until every parked flag from this generation is down.
        // A reusable boolean has an ABA window here: a second collector can
        // raise it again while a slow peer is still leaving the first cycle.
        self.state.store(@backingInt(State.releasing), .release);
        for (self.worker_parked, 0..) |*flag, id| {
            if (id == collector_id) continue;
            while (flag.load(.acquire)) std.atomic.spinLoopHint();
        }
        self.state.store(@backingInt(State.idle), .release);
    }

    pub fn setMarkHook(self: *Barrier, hook: MarkHook) void {
        self.mark_hook = hook;
    }

    pub fn openMark(self: *Barrier) void {
        self.mark_open.store(true, .release);
    }

    pub fn closeMark(self: *Barrier) void {
        self.mark_open.store(false, .release);
    }

    pub fn park(self: *Barrier, worker_id: u8) void {
        self.worker_parked[worker_id].store(true, .release);
        if (self.mark_hook) |hook| {
            while (self.requested() and
                !self.mark_open.load(.acquire)) std.atomic.spinLoopHint();
            if (self.mark_open.load(.acquire)) hook.help(hook.ctx, worker_id);
        }
        while (self.requested()) std.atomic.spinLoopHint();
        self.worker_parked[worker_id].store(false, .release);
    }
};

test "a new collection cannot begin while the prior generation is releasing" {
    var barrier = try Barrier.init(std.testing.allocator, 2);
    defer barrier.deinit(std.testing.allocator);

    const HookContext = struct {
        hold: std.atomic.Value(bool) = .init(true),
        entered: std.atomic.Value(bool) = .init(false),

        fn help(raw: *anyopaque, _: u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.entered.store(true, .release);
            while (self.hold.load(.acquire)) std.atomic.spinLoopHint();
        }
    };
    const Run = struct {
        fn park(b: *Barrier) void {
            b.park(1);
        }

        fn end(b: *Barrier) void {
            b.end(0);
        }
    };

    var hook_context = HookContext{};
    barrier.setMarkHook(.{ .ctx = &hook_context, .help = HookContext.help });
    try std.testing.expect(barrier.tryBegin());
    barrier.openMark();

    const helper = try std.Thread.spawn(.{}, Run.park, .{&barrier});
    while (!hook_context.entered.load(.acquire)) std.atomic.spinLoopHint();
    barrier.closeMark();

    const releaser = try std.Thread.spawn(.{}, Run.end, .{&barrier});
    while (barrier.requested()) std.atomic.spinLoopHint();
    const begin_blocked = !barrier.tryBegin();

    hook_context.hold.store(false, .release);
    helper.join();
    releaser.join();

    try std.testing.expect(begin_blocked);
    try std.testing.expect(barrier.tryBegin());
    barrier.end(0);
}
