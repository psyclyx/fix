//! Immutable, structurally-shared failures for sticky runtime computations.
//!
//! A failure is published as a one-word `FailureRef`.  Usually it names an
//! immutable record owned by the engine's `FailureStore`; if retaining the
//! diagnostic runs out of memory, the same word carries the Zig error code
//! inline.  That degraded representation is allocation-free, so a completed
//! deterministic computation never has to be reset and evaluated again just
//! because its diagnostic sidecar could not be allocated.

const std = @import("std");
const types = @import("types.zig");
const sync = @import("base").sync;

/// Compact identity of an evaluation frame.  Source locations and qualified
/// names are deliberately resolved only when a failure is rendered.
pub const FailureFrame = struct {
    chunk_id: types.ChunkId,
    ip: u32,
};

/// Immutable diagnostic node.  Context nodes borrow their cause, allowing a
/// single origin (and its frame vector) to be shared by every ancestor thunk
/// and by any number of persistent context wrappers.
pub const FailureRecord = union(enum) {
    origin: Origin,
    context: Context,

    pub const Origin = struct {
        err: anyerror,
        message: []const u8,
        frames: []const FailureFrame,
    };

    pub const Context = struct {
        cause: FailureRef,
        message: []const u8,
    };
};

/// A borrowed failure handle, valid for the lifetime of its `FailureStore`.
///
/// Detailed record pointers have their naturally-zero low bit.  A set low bit
/// tags an inline Zig error code.  The representation is intentionally public
/// only through methods so embedders can store `rawBits()` in an existing
/// pointer/value-sized result slot without depending on the tag scheme.
pub const FailureRef = struct {
    bits: usize,

    const degraded_tag: usize = 1;

    pub fn fromRecord(record_ptr: *const FailureRecord) FailureRef {
        const ptr_bits = @intFromPtr(record_ptr);
        std.debug.assert(ptr_bits != 0 and ptr_bits & degraded_tag == 0);
        return .{ .bits = ptr_bits };
    }

    pub fn degraded(err_value: anyerror) FailureRef {
        const code: usize = @intFromError(err_value);
        std.debug.assert(code != 0);
        return .{ .bits = (code << 1) | degraded_tag };
    }

    pub fn fromRawBits(bits: usize) FailureRef {
        std.debug.assert(bits != 0);
        return .{ .bits = bits };
    }

    pub fn rawBits(self: FailureRef) usize {
        return self.bits;
    }

    pub fn isDetailed(self: FailureRef) bool {
        return self.bits & degraded_tag == 0;
    }

    pub fn record(self: FailureRef) ?*const FailureRecord {
        if (!self.isDetailed()) return null;
        return @ptrFromInt(self.bits);
    }

    pub fn err(self: FailureRef) anyerror {
        const ErrorInt = @Int(.unsigned, @bitSizeOf(anyerror));
        if (!self.isDetailed()) return @errorFromInt(@as(ErrorInt, @intCast(self.bits >> 1)));

        var current = self;
        while (true) {
            switch (current.record().?.*) {
                .origin => |origin| return origin.err,
                .context => |context| current = context.cause,
            }
            if (!current.isDetailed()) return @errorFromInt(@as(ErrorInt, @intCast(current.bits >> 1)));
        }
    }

    pub fn eql(self: FailureRef, other: FailureRef) bool {
        return self.bits == other.bits;
    }
};

/// Engine/heap-lifetime owner for all immutable failure records.  Allocation
/// and record tracking are serialized because speculative fibers may capture
/// failures concurrently.  Reads need no synchronization once a ref has been
/// release-published through its owning future.
pub const FailureStore = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(*FailureRecord) = .empty,
    mutex: sync.SpinMutex = .{},

    pub fn init(allocator: std.mem.Allocator) FailureStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FailureStore) void {
        // Engine teardown is quiescent; no lock is needed.
        for (self.records.items) |record_ptr| {
            switch (record_ptr.*) {
                .origin => |origin| {
                    self.allocator.free(origin.message);
                    self.allocator.free(origin.frames);
                },
                .context => |context| self.allocator.free(context.message),
            }
            self.allocator.destroy(record_ptr);
        }
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Capture an origin once.  On any allocation failure, returns an inline
    /// error-only ref; callers can therefore unconditionally publish the
    /// result as a terminal deterministic failure.
    pub fn captureOrigin(
        self: *FailureStore,
        err_value: anyerror,
        message: []const u8,
        frames: []const FailureFrame,
    ) FailureRef {
        return self.captureOriginAlloc(err_value, message, frames) catch FailureRef.degraded(err_value);
    }

    fn captureOriginAlloc(
        self: *FailureStore,
        err_value: anyerror,
        message: []const u8,
        frames: []const FailureFrame,
    ) !FailureRef {
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);

        const owned_frames = try self.allocator.dupe(FailureFrame, frames);
        errdefer self.allocator.free(owned_frames);

        const record_ptr = try self.allocator.create(FailureRecord);
        errdefer self.allocator.destroy(record_ptr);
        record_ptr.* = .{ .origin = .{
            .err = err_value,
            .message = owned_message,
            .frames = owned_frames,
        } };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.records.append(self.allocator, record_ptr);
        return FailureRef.fromRecord(record_ptr);
    }

    /// Add persistent error context.  If retaining the context fails, the
    /// original failure remains intact and is returned unchanged.
    pub fn addContext(self: *FailureStore, cause: FailureRef, message: []const u8) FailureRef {
        return self.addContextAlloc(cause, message) catch cause;
    }

    fn addContextAlloc(self: *FailureStore, cause: FailureRef, message: []const u8) !FailureRef {
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);

        const record_ptr = try self.allocator.create(FailureRecord);
        errdefer self.allocator.destroy(record_ptr);
        record_ptr.* = .{ .context = .{ .cause = cause, .message = owned_message } };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.records.append(self.allocator, record_ptr);
        return FailureRef.fromRecord(record_ptr);
    }
};

test "failure refs share origins through persistent context" {
    var store = FailureStore.init(std.testing.allocator);
    defer store.deinit();

    const origin = store.captureOrigin(error.NixThrow, "bad value", &.{
        .{ .chunk_id = 7, .ip = 11 },
    });
    const wrapped = store.addContext(origin, "while evaluating an option");

    try std.testing.expect(origin.isDetailed());
    try std.testing.expect(wrapped.isDetailed());
    try std.testing.expectEqual(@as(anyerror, error.NixThrow), wrapped.err());
    switch (wrapped.record().?.*) {
        .context => |context| try std.testing.expect(context.cause.eql(origin)),
        .origin => return error.ExpectedContext,
    }
}

test "degraded failure ref carries an error without allocation" {
    const failure = FailureRef.degraded(error.TypeError);
    try std.testing.expect(!failure.isDetailed());
    try std.testing.expectEqual(@as(anyerror, error.TypeError), failure.err());
    try std.testing.expect(failure.record() == null);
}

test "origin capture remains terminal at every retention allocation failure" {
    // message, frame vector, record, and tracking-vector allocations.
    for (0..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var store = FailureStore.init(failing.allocator());
        defer store.deinit();

        const captured = store.captureOrigin(error.NixThrow, "bad value", &.{
            .{ .chunk_id = 7, .ip = 11 },
        });
        try std.testing.expect(!captured.isDetailed());
        try std.testing.expectEqual(@as(anyerror, error.NixThrow), captured.err());
    }
}
