const std = @import("std");
const sync = @import("base").sync;
const observ = @import("base").observ;
const RealizationStore = @import("../realization.zig").RealizationStore;
const FileCache = @import("../file_cache.zig").FileCache;
const DaemonRuntime = @import("../daemon/runtime.zig").DaemonRuntime;
const FakeDaemon = @import("testing/fake_daemon.zig").FakeDaemon;
const DummyStore = @import("../testing/dummy_store.zig").DummyStore;

const root_path = "/nix/store/00000000000000000000000000000000-root.drv";
const dep_text_path = "/nix/store/11111111111111111111111111111111-dep-text";
const dep_nar_path = "/nix/store/22222222222222222222222222222222-dep-nar";
const missing_path = "/nix/store/33333333333333333333333333333333-missing";

fn recipeApiAvailable() bool {
    return @hasDecl(RealizationStore, "recordOwnedTextRecipe") and
        @hasDecl(RealizationStore, "recordOwnedNarRecipe") and
        @hasDecl(RealizationStore, "recordFlatRecipe") and
        @hasDecl(RealizationStore, "releaseRecipePayloads");
}

fn realizationApiAvailable() bool {
    return recipeApiAvailable() and
        @hasDecl(RealizationStore, "ensureClosure") and
        @hasDecl(RealizationStore, "realizeOutput");
}

/// Point the store at the fake daemon and give it a small pool (2 workers is
/// enough for the concurrent-claim tests: at most two distinct claims coexist).
/// The store owns the runtime and tears it down in `deinit`, before the caller's
/// `fake.deinit()` (declared first, so it runs last).
fn attachFake(store: *RealizationStore, fake: *FakeDaemon) void {
    store.setIo(std.testing.io);
    store.testAccess().useBorrowedDaemonSocket(fake.socketPath());
    const rt = std.testing.allocator.create(DaemonRuntime) catch @panic("OOM");
    rt.* = DaemonRuntime.init();
    rt.pool_workers = 2;
    store.testAccess().takeDaemonRuntime(rt);
}

/// Attach an in-process backend that deliberately executes directly. No store
/// runtime, pool, IO handle, or worker-protocol socket is involved.
fn attachDummy(store: *RealizationStore, dummy: *DummyStore) !void {
    try store.setBackend(dummy.driver());
}

const ProgressRecorder = struct {
    mu: sync.BlockingMutex = .{},
    checks: usize = 0,
    stores: usize = 0,
    ended: usize = 0,

    fn observer(self: *ProgressRecorder) observ.Observer {
        return .{
            .sink = .{
                .context = self,
                .begin_fn = begin,
                .finish_fn = finish,
                .update_fn = update,
                .event_fn = event,
                .counter_fn = counter,
                .next_flow_id_fn = nextFlowId,
                .flow_fn = flow,
                .sample_fn = sample,
            },
            .profile_enabled = true,
        };
    }

    fn begin(raw: *anyopaque, spec: *const observ.SpanSpec, _: observ.Details, _: observ.Track, _: observ.Interest) usize {
        const self: *ProgressRecorder = @ptrCast(@alignCast(raw));
        self.mu.lock();
        defer self.mu.unlock();
        if (std.mem.eql(u8, spec.name, "check")) self.checks += 1;
        if (std.mem.eql(u8, spec.name, "store")) self.stores += 1;
        return 1;
    }

    fn finish(raw: *anyopaque, _: usize, _: *const observ.SpanSpec, _: observ.Details, _: observ.Track, _: observ.Interest, _: observ.Finish, success: bool) void {
        if (!success) return;
        const self: *ProgressRecorder = @ptrCast(@alignCast(raw));
        self.mu.lock();
        defer self.mu.unlock();
        self.ended += 1;
    }

    fn update(_: *anyopaque, _: usize, _: *const observ.SpanSpec, _: observ.Interest, _: []const observ.Metric) void {}
    fn event(_: *anyopaque, _: *const observ.EventSpec, _: observ.Details, _: observ.Track, _: observ.Interest, _: []const observ.Metric) void {}
    fn counter(_: *anyopaque, _: *const observ.CounterSpec, _: observ.Track, _: []const observ.Metric) void {}
    fn nextFlowId(_: *anyopaque) u64 {
        return 1;
    }
    fn flow(_: *anyopaque, _: *const observ.FlowSpec, _: u64, _: observ.FlowPhase, _: observ.Track, _: u64) void {}
    fn sample(_: *anyopaque, _: u64) bool {
        return true;
    }

    fn count(self: *ProgressRecorder, name: []const u8) usize {
        self.mu.lock();
        defer self.mu.unlock();
        if (std.mem.eql(u8, name, "check")) return self.checks;
        if (std.mem.eql(u8, name, "store")) return self.stores;
        return 0;
    }
};

fn owned(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return allocator.dupe(u8, bytes);
}

const TrackingAllocator = struct {
    child: std.mem.Allocator,
    tracked_ptr: std.atomic.Value(usize) = .init(0),
    frees: std.atomic.Value(usize) = .init(0),

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(child: std.mem.Allocator) TrackingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn track(self: *TrackingAllocator, bytes: []u8) void {
        std.debug.assert(self.tracked_ptr.load(.seq_cst) == 0);
        self.tracked_ptr.store(@intFromPtr(bytes.ptr), .seq_cst);
    }

    fn freeCount(self: *TrackingAllocator) usize {
        return self.frees.load(.seq_cst);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const tracked = @intFromPtr(memory.ptr) == self.tracked_ptr.load(.seq_cst);
        self.child.rawFree(memory, alignment, return_address);
        if (tracked) _ = self.frees.fetchAdd(1, .monotonic);
    }
};

test "recordOwnedTextRecipe consumes the producer allocation" {
    if (comptime recipeApiAvailable()) {
        var tracking = TrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var store = RealizationStore.init(allocator);
        const payload = try owned(allocator, "owned derivation text");
        const payload_ptr = @intFromPtr(payload.ptr);
        tracking.track(payload);

        try store.recordOwnedTextRecipe(root_path, payload, &.{dep_text_path});
        try std.testing.expectEqual(@as(usize, 0), tracking.freeCount());
        store.releaseRecipePayloads();
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
        try std.testing.expectEqual(payload_ptr, tracking.tracked_ptr.load(.seq_cst));
        store.deinit();
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
    } else return error.MissingRecipeRegistryApi;
}

test "recordOwnedNarRecipe consumes the original serializer allocation" {
    if (comptime recipeApiAvailable()) {
        var tracking = TrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var store = RealizationStore.init(allocator);
        const payload = try owned(allocator, "nix-archive-1 serialized tree");
        tracking.track(payload);

        try store.recordOwnedNarRecipe(dep_nar_path, payload);
        try std.testing.expectEqual(@as(usize, 0), tracking.freeCount());
        store.deinit();
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
    } else return error.MissingRecipeRegistryApi;
}

test "daemon worker spans bracket validity checks and store writes" {
    if (comptime realizationApiAvailable()) {
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);
        var progress: ProgressRecorder = .{};
        store.setObserver(progress.observer());
        try store.recordOwnedNarRecipe(dep_nar_path, try owned(std.testing.allocator, "nar payload"));

        try store.ensureClosure(dep_nar_path);
        try std.testing.expectEqual(@as(usize, 2), progress.count("check"));
        try std.testing.expectEqual(@as(usize, 1), progress.count("store"));
        try std.testing.expectEqual(@as(usize, 3), progress.ended);
    } else return error.MissingRecipeRealizationApi;
}

test "a daemon runtime re-attached after clearExecution keeps serving from its started pool" {
    if (comptime realizationApiAvailable()) {
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();

        // Held locally so the same runtime can be attached twice: the pool it
        // starts here has to survive the detach in between.
        store.setIo(std.testing.io);
        store.testAccess().useBorrowedDaemonSocket(fake.socketPath());
        const rt = try std.testing.allocator.create(DaemonRuntime);
        rt.* = DaemonRuntime.init();
        rt.pool_workers = 1;
        store.testAccess().takeDaemonRuntime(rt);

        try store.recordOwnedNarRecipe(dep_nar_path, try owned(std.testing.allocator, "nar payload"));
        try store.ensureClosure(dep_nar_path);

        store.clearExecution();
        store.testAccess().takeDaemonRuntime(rt);

        // Reconfiguring a started runtime is refused, so the second attach has
        // to take the running driver back rather than ask for a new one.
        try store.recordOwnedTextRecipe(dep_text_path, try owned(std.testing.allocator, "dependency"), &.{});
        try store.ensureClosure(dep_text_path);
    } else return error.MissingRecipeRealizationApi;
}

test "a selected store backend starts only once across clearExecution" {
    if (comptime realizationApiAvailable()) {
        var dummy = DummyStore.init(std.testing.allocator);
        defer dummy.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        try attachDummy(&store, &dummy);

        store.enableStoreWrites();
        try std.testing.expectEqual(@as(usize, 1), dummy.startCount());

        store.clearExecution();
        try store.recordOwnedTextRecipe(dep_text_path, try owned(std.testing.allocator, "dependency"), &.{});
        try store.ensureClosure(dep_text_path);
        try std.testing.expectEqual(@as(usize, 1), dummy.startCount());
    } else return error.MissingRecipeRealizationApi;
}

test "dummy backend realizes dependency closures through the store interface" {
    if (comptime realizationApiAvailable()) {
        var dummy = DummyStore.init(std.testing.allocator);
        defer dummy.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        try attachDummy(&store, &dummy);
        store.enableStoreWrites();

        try store.recordOwnedTextRecipe(dep_text_path, try owned(std.testing.allocator, "dependency"), &.{});
        try store.recordOwnedTextRecipe(root_path, try owned(std.testing.allocator, "root"), &.{dep_text_path});
        try store.ensureClosure(root_path);

        try std.testing.expect(dummy.contains(dep_text_path));
        try std.testing.expect(dummy.contains(root_path));
        try std.testing.expectEqual(@as(usize, 2), dummy.effectCount(.text));

        var materialized: [2][]const u8 = undefined;
        var count: usize = 0;
        for (0..dummy.effectsLen()) |index| {
            const effect = dummy.effectAt(index).?;
            if (effect.kind != .text) continue;
            materialized[count] = effect.subject;
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), count);
        try std.testing.expectEqualStrings(dep_text_path, materialized[0]);
        try std.testing.expectEqualStrings(root_path, materialized[1]);

        const contents = try store.readFileViaStore(std.testing.allocator, root_path);
        defer std.testing.allocator.free(contents);
        try std.testing.expectEqualStrings("root", contents);

        try store.buildPaths(&.{root_path ++ "!out"}, null, .normal);
        var missing = try store.queryMissing(&.{root_path ++ "!out"});
        defer missing.deinit();
        try std.testing.expectEqual(@as(usize, 1), missing.will_build.len);
        try store.addIndirectRoot("/tmp/dummy-result", root_path);
        try std.testing.expectEqual(@as(usize, 1), dummy.effectCount(.read));
        try std.testing.expectEqual(@as(usize, 1), dummy.effectCount(.build));
        try std.testing.expectEqual(@as(usize, 1), dummy.effectCount(.query_missing));
        try std.testing.expectEqual(@as(usize, 1), dummy.effectCount(.root));
    } else return error.MissingRecipeRealizationApi;
}

test "realization rejects a backend-computed store path mismatch" {
    if (comptime realizationApiAvailable()) {
        var dummy = DummyStore.init(std.testing.allocator);
        defer dummy.deinit();
        try dummy.setReturnedPath(missing_path);
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        try attachDummy(&store, &dummy);
        store.enableStoreWrites();

        try std.testing.expectError(
            error.StorePathMismatch,
            store.instantiateText(root_path, "mismatched", &.{}),
        );
    } else return error.MissingRecipeRealizationApi;
}

test "duplicate identical NAR recipe consumes incoming allocation and preserves original" {
    if (comptime realizationApiAvailable()) {
        var tracking = TrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(allocator);
        defer store.deinit();
        attachFake(&store, fake);
        try store.recordOwnedNarRecipe(dep_nar_path, try owned(allocator, "same nar payload"));
        const duplicate = try owned(allocator, "same nar payload");
        const duplicate_ptr = @intFromPtr(duplicate.ptr);
        tracking.track(duplicate);

        try store.recordOwnedNarRecipe(dep_nar_path, duplicate);
        try std.testing.expectEqual(duplicate_ptr, tracking.tracked_ptr.load(.seq_cst));
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
        try store.ensureClosure(dep_nar_path);
        try std.testing.expectEqual(@as(usize, 1), fake.count(.nar));
        try std.testing.expect(fake.nthPayloadEquals(.nar, 0, "same nar payload"));
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
    } else return error.MissingRecipeRealizationApi;
}

test "conflicting NAR recipe frees rejected allocation and realizes original" {
    if (comptime realizationApiAvailable()) {
        var tracking = TrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(allocator);
        defer store.deinit();
        attachFake(&store, fake);
        try store.recordOwnedNarRecipe(dep_nar_path, try owned(allocator, "original nar payload"));
        const rejected = try owned(allocator, "conflicting nar payload");
        const rejected_ptr = @intFromPtr(rejected.ptr);
        tracking.track(rejected);

        try std.testing.expectError(error.RecipeConflict, store.recordOwnedNarRecipe(dep_nar_path, rejected));
        try std.testing.expectEqual(rejected_ptr, tracking.tracked_ptr.load(.seq_cst));
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
        try store.ensureClosure(dep_nar_path);
        try std.testing.expectEqual(@as(usize, 1), fake.count(.nar));
        try std.testing.expect(fake.nthPayloadEquals(.nar, 0, "original nar payload"));
        try std.testing.expect(!fake.nthPayloadEquals(.nar, 0, "conflicting nar payload"));
    } else return error.MissingRecipeRealizationApi;
}

test "recordFlatRecipe retains the same ImmutableBytes blob" {
    if (comptime recipeApiAvailable()) {
        var tracking = TrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        const bytes = try owned(allocator, "flat cache payload");
        const original_ptr = @intFromPtr(bytes.ptr);
        tracking.track(bytes);
        var handle = try FileCache.ImmutableBytes.fromOwned(allocator, bytes);

        try store.recordFlatRecipe(dep_text_path, handle, false);
        try std.testing.expectEqual(original_ptr, @intFromPtr(handle.bytes().ptr));
        handle.release();
        try std.testing.expectEqual(@as(usize, 0), tracking.freeCount());
        store.releaseRecipePayloads();
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
    } else return error.MissingRecipeRegistryApi;
}

test "ensureClosure realizes flat recipe bytes and releases retained ownership" {
    if (comptime realizationApiAvailable()) {
        var tracking = TrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);
        const bytes = try owned(allocator, "flat closure payload");
        const original_ptr = @intFromPtr(bytes.ptr);
        tracking.track(bytes);
        var handle = try FileCache.ImmutableBytes.fromOwned(allocator, bytes);

        try store.recordFlatRecipe(dep_text_path, handle, false);
        try std.testing.expectEqual(original_ptr, @intFromPtr(handle.bytes().ptr));
        handle.release();
        try std.testing.expectEqual(@as(usize, 0), tracking.freeCount());
        try store.ensureClosure(dep_text_path);
        try std.testing.expectEqual(@as(usize, 1), fake.count(.flat));
        try std.testing.expect(fake.nthSubjectEquals(.flat, 0, "dep-text"));
        try std.testing.expect(fake.nthPayloadEquals(.flat, 0, "flat closure payload"));
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
    } else return error.MissingClosureRealizationApi;
}

test "duplicate identical owned recipe registration releases incoming ownership" {
    if (comptime recipeApiAvailable()) {
        var tracking = TrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var store = RealizationStore.init(allocator);
        defer store.deinit();
        try store.recordOwnedTextRecipe(root_path, try owned(allocator, "same text"), &.{dep_text_path});
        const duplicate = try owned(allocator, "same text");
        tracking.track(duplicate);

        try store.recordOwnedTextRecipe(root_path, duplicate, &.{dep_text_path});
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
    } else return error.MissingRecipeRegistryApi;
}

test "duplicate identical flat recipe keeps original blob without leaking a retain" {
    if (comptime realizationApiAvailable()) {
        var tracking = TrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);
        const bytes = try owned(allocator, "same flat bytes");
        const original_ptr = @intFromPtr(bytes.ptr);
        tracking.track(bytes);
        var handle = try FileCache.ImmutableBytes.fromOwned(allocator, bytes);

        try store.recordFlatRecipe(dep_text_path, handle, false);
        try store.recordFlatRecipe(dep_text_path, handle, false);
        try std.testing.expectEqual(original_ptr, @intFromPtr(handle.bytes().ptr));
        handle.release();
        try std.testing.expectEqual(@as(usize, 0), tracking.freeCount());
        try store.ensureClosure(dep_text_path);
        try std.testing.expectEqual(@as(usize, 1), fake.count(.flat));
        try std.testing.expect(fake.nthPayloadEquals(.flat, 0, "same flat bytes"));
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
    } else return error.MissingRecipeRealizationApi;
}

test "conflicting flat recipe releases rejected retain and realizes original blob" {
    if (comptime realizationApiAvailable()) {
        var original_tracking = TrackingAllocator.init(std.testing.allocator);
        const original_allocator = original_tracking.allocator();
        var rejected_tracking = TrackingAllocator.init(std.testing.allocator);
        const rejected_allocator = rejected_tracking.allocator();
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);

        const original_bytes = try owned(original_allocator, "original flat payload");
        const original_ptr = @intFromPtr(original_bytes.ptr);
        original_tracking.track(original_bytes);
        var original = try FileCache.ImmutableBytes.fromOwned(original_allocator, original_bytes);
        const rejected_bytes = try owned(rejected_allocator, "conflicting flat payload");
        const rejected_ptr = @intFromPtr(rejected_bytes.ptr);
        rejected_tracking.track(rejected_bytes);
        var rejected = try FileCache.ImmutableBytes.fromOwned(rejected_allocator, rejected_bytes);

        try store.recordFlatRecipe(dep_text_path, original, false);
        try std.testing.expectError(error.RecipeConflict, store.recordFlatRecipe(dep_text_path, rejected, false));
        try std.testing.expectEqual(original_ptr, @intFromPtr(original.bytes().ptr));
        try std.testing.expectEqual(rejected_ptr, @intFromPtr(rejected.bytes().ptr));
        rejected.release();
        try std.testing.expectEqual(@as(usize, 1), rejected_tracking.freeCount());
        original.release();
        try std.testing.expectEqual(@as(usize, 0), original_tracking.freeCount());

        try store.ensureClosure(dep_text_path);
        try std.testing.expectEqual(@as(usize, 1), fake.count(.flat));
        try std.testing.expect(fake.nthPayloadEquals(.flat, 0, "original flat payload"));
        try std.testing.expect(!fake.nthPayloadEquals(.flat, 0, "conflicting flat payload"));
        try std.testing.expectEqual(@as(usize, 1), original_tracking.freeCount());
    } else return error.MissingRecipeRealizationApi;
}

test "conflicting text recipe preserves the original and consumes the rejected payload" {
    if (comptime realizationApiAvailable()) {
        var tracking = TrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(allocator);
        defer store.deinit();
        attachFake(&store, fake);
        try store.recordOwnedTextRecipe(root_path, try owned(allocator, "original text"), &.{});
        const rejected = try owned(allocator, "conflicting text");
        tracking.track(rejected);

        try std.testing.expectError(
            error.RecipeConflict,
            store.recordOwnedTextRecipe(root_path, rejected, &.{}),
        );
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
        try store.ensureClosure(root_path);
        try std.testing.expectEqual(@as(usize, 1), fake.count(.text));
        try std.testing.expect(fake.nthPayloadEquals(.text, 0, "original text"));
    } else return error.MissingRecipeRealizationApi;
}

test "successful realization releases recipe payload and realizes requested output" {
    if (comptime realizationApiAvailable()) {
        var tracking = TrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(allocator);
        defer store.deinit();
        attachFake(&store, fake);
        const payload = try owned(allocator, "realized derivation");
        tracking.track(payload);
        try store.recordOwnedTextRecipe(root_path, payload, &.{});

        try store.realizeOutput(root_path, &.{"out"});
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
        try std.testing.expectEqual(@as(usize, 1), fake.count(.text));
        try std.testing.expectEqual(@as(usize, 1), fake.count(.build));
        try std.testing.expect(fake.nthSubjectEquals(.build, 0, root_path ++ "!out"));
    } else return error.MissingRecipeRealizationApi;
}

test "realizeOutput canonicalizes unsorted duplicate output names" {
    if (comptime realizationApiAvailable()) {
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);
        try store.recordOwnedTextRecipe(root_path, try owned(std.testing.allocator, "multi output derivation"), &.{});

        try store.realizeOutput(root_path, &.{ "out", "dev", "out", "dev" });
        try std.testing.expectEqual(@as(usize, 1), fake.count(.build));
        try std.testing.expect(fake.nthSubjectEquals(.build, 0, root_path ++ "!dev,out"));
    } else return error.MissingRecipeRealizationApi;
}

test "releaseRecipePayloads is idempotent and teardown frees exactly once" {
    if (comptime recipeApiAvailable()) {
        var tracking = TrackingAllocator.init(std.testing.allocator);
        const allocator = tracking.allocator();
        var store = RealizationStore.init(std.testing.allocator);
        const bytes = try owned(allocator, "released once");
        tracking.track(bytes);
        var handle = try FileCache.ImmutableBytes.fromOwned(allocator, bytes);
        try store.recordFlatRecipe(dep_text_path, handle, false);
        handle.release();

        store.releaseRecipePayloads();
        store.releaseRecipePayloads();
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
        store.deinit();
        try std.testing.expectEqual(@as(usize, 1), tracking.freeCount());
    } else return error.MissingRecipeRegistryApi;
}

test "ensureClosure materializes invalid references dependency first" {
    if (comptime realizationApiAvailable()) {
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);
        try store.recordOwnedNarRecipe(dep_nar_path, try owned(std.testing.allocator, "dep nar"));
        try store.recordOwnedTextRecipe(dep_text_path, try owned(std.testing.allocator, "dep text"), &.{});
        try store.recordOwnedTextRecipe(root_path, try owned(std.testing.allocator, "root text"), &.{ dep_nar_path, dep_text_path });

        try store.ensureClosure(root_path);
        try std.testing.expectEqual(@as(usize, 3), fake.materializationCount());
        try std.testing.expect(fake.nthMaterializationSubjectEquals(0, "dep-nar"));
        try std.testing.expect(fake.nthMaterializationSubjectEquals(1, "dep-text"));
        try std.testing.expect(fake.nthMaterializationSubjectEquals(2, "root.drv"));
    } else return error.MissingClosureRealizationApi;
}

test "ensureClosure is a no-op for an already valid path" {
    if (comptime realizationApiAvailable()) {
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        try fake.markValid(root_path);
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);
        try store.recordOwnedTextRecipe(root_path, try owned(std.testing.allocator, "unused"), &.{});

        try store.ensureClosure(root_path);
        try std.testing.expectEqual(@as(usize, 0), fake.materializationCount());
        try std.testing.expectEqual(@as(usize, 1), fake.count(.query));
    } else return error.MissingClosureRealizationApi;
}

test "ensureClosure errors for an invalid referenced path with no recipe" {
    if (comptime realizationApiAvailable()) {
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);
        try store.recordOwnedTextRecipe(root_path, try owned(std.testing.allocator, "root"), &.{missing_path});

        try std.testing.expectError(error.MissingStoreRecipe, store.ensureClosure(root_path));
        try std.testing.expectEqual(@as(usize, 0), fake.materializationCount());
    } else return error.MissingClosureRealizationApi;
}

test "ensureClosure rejects a cyclic recipe graph deterministically" {
    if (comptime realizationApiAvailable()) {
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);
        try store.recordOwnedTextRecipe(root_path, try owned(std.testing.allocator, "cycle a"), &.{dep_text_path});
        try store.recordOwnedTextRecipe(dep_text_path, try owned(std.testing.allocator, "cycle b"), &.{root_path});

        try std.testing.expectError(error.RecipeCycle, store.ensureClosure(root_path));
        try std.testing.expectEqual(@as(usize, 0), fake.materializationCount());
    } else return error.MissingClosureRealizationApi;
}

const ConcurrentDemand = struct {
    store: *RealizationStore,
    result: anyerror!void = {},

    fn run(self: *ConcurrentDemand) void {
        self.result = self.store.ensureClosure(root_path);
    }
};

const ConcurrentPathDemand = struct {
    store: *RealizationStore,
    path: []const u8,
    result: anyerror!void = {},

    fn run(self: *ConcurrentPathDemand) void {
        self.result = self.store.ensureClosure(self.path);
    }
};

const RootClaimBarrier = struct {
    observed: std.atomic.Value(u32) = .init(0),
    released: std.atomic.Value(u32) = .init(0),

    const both_claimed: u32 = 0b11;

    fn hook(ctx: *anyopaque, store_path: []const u8) void {
        const self: *RootClaimBarrier = @ptrCast(@alignCast(ctx));
        const bit: u32 = if (std.mem.eql(u8, store_path, root_path))
            0b01
        else if (std.mem.eql(u8, store_path, dep_text_path))
            0b10
        else
            unreachable;
        _ = self.observed.fetchOr(bit, .acq_rel);
        sync.Futex.wake(&self.observed, std.math.maxInt(u32));
        while (self.released.load(.acquire) == 0) sync.Futex.wait(&self.released, 0);
    }

    fn waitForBoth(self: *RootClaimBarrier) u32 {
        while (true) {
            const current = self.observed.load(.acquire);
            if (current == both_claimed) return current;
            sync.Futex.wait(&self.observed, current);
        }
    }

    fn releaseBoth(self: *RootClaimBarrier) void {
        self.released.store(1, .release);
        sync.Futex.wake(&self.released, std.math.maxInt(u32));
    }
};

test "concurrent cross-root cyclic demands return RecipeCycle without deadlock" {
    if (comptime realizationApiAvailable()) {
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);
        try store.recordOwnedTextRecipe(root_path, try owned(std.testing.allocator, "cross cycle a"), &.{dep_text_path});
        try store.recordOwnedTextRecipe(dep_text_path, try owned(std.testing.allocator, "cross cycle b"), &.{root_path});

        var barrier: RootClaimBarrier = .{};
        store.testAccess().setRootClaimHook(.{ .ctx = &barrier, .observe = RootClaimBarrier.hook });
        defer store.testAccess().setRootClaimHook(null);
        var demands = [_]ConcurrentPathDemand{
            .{ .store = &store, .path = root_path },
            .{ .store = &store, .path = dep_text_path },
        };
        var threads: [demands.len]std.Thread = undefined;
        for (&demands, &threads) |*demand, *thread| {
            thread.* = try std.Thread.spawn(.{}, ConcurrentPathDemand.run, .{demand});
        }
        try std.testing.expectEqual(RootClaimBarrier.both_claimed, barrier.waitForBoth());
        barrier.releaseBoth();
        for (threads) |thread| thread.join();
        for (&demands) |*demand| try std.testing.expectError(error.RecipeCycle, demand.result);
        try std.testing.expectEqual(@as(usize, 0), fake.materializationCount());
    } else return error.MissingClosureRealizationApi;
}

test "concurrent closure demand has exactly one materializing writer" {
    if (comptime realizationApiAvailable()) {
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);
        try store.recordOwnedTextRecipe(root_path, try owned(std.testing.allocator, "one writer"), &.{});

        var demands: [8]ConcurrentDemand = undefined;
        var threads: [demands.len]std.Thread = undefined;
        for (&demands, &threads) |*demand, *thread| {
            demand.* = .{ .store = &store };
            thread.* = try std.Thread.spawn(.{}, ConcurrentDemand.run, .{demand});
        }
        for (threads) |thread| thread.join();
        for (&demands) |*demand| try demand.result;
        try std.testing.expectEqual(@as(usize, 1), fake.count(.text));
    } else return error.MissingClosureRealizationApi;
}

test "permanent realization failure is replayed without a second writer" {
    if (comptime realizationApiAvailable()) {
        var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
        defer fake.deinit();
        fake.failNextAdd();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        attachFake(&store, fake);
        try store.recordOwnedTextRecipe(root_path, try owned(std.testing.allocator, "permanent failure"), &.{});

        try std.testing.expectError(error.DaemonError, store.ensureClosure(root_path));
        try std.testing.expectError(error.DaemonError, store.ensureClosure(root_path));
        try std.testing.expectEqual(@as(usize, 1), fake.count(.text));
    } else return error.MissingClosureRealizationApi;
}

test "transient connection failure resets claim state and permits retry" {
    if (comptime realizationApiAvailable()) {
        const socket_path = try FakeDaemon.makeFilesystemSocketPath(std.testing.allocator);
        defer std.testing.allocator.free(socket_path);
        var fake: ?*FakeDaemon = null;
        defer if (fake) |daemon| daemon.deinit();
        var store = RealizationStore.init(std.testing.allocator);
        defer store.deinit();
        store.setIo(std.testing.io);
        store.testAccess().useBorrowedDaemonSocket(socket_path);
        const rt = std.testing.allocator.create(DaemonRuntime) catch @panic("OOM");
        rt.* = DaemonRuntime.init();
        rt.pool_workers = 2;
        store.testAccess().takeDaemonRuntime(rt);
        try store.recordOwnedTextRecipe(root_path, try owned(std.testing.allocator, "retry succeeds"), &.{});

        // No daemon yet: the pool can't open a connection, surfaced as
        // StoreUnavailable (a retryable transient — the claim state resets).
        try std.testing.expectError(error.StoreUnavailable, store.ensureClosure(root_path));
        fake = try FakeDaemon.startAt(std.testing.allocator, std.testing.io, socket_path);
        try store.ensureClosure(root_path);
        try std.testing.expectEqual(@as(usize, 1), fake.?.count(.text));
    } else return error.MissingClosureRealizationApi;
}
