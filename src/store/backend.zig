//! Backend-neutral store operations.
//!
//! Realization owns dependency ordering, single-flight claims, and its
//! presence cache. A backend connection owns only the effectful operations
//! against one concrete store. A driver owns the execution policy: the daemon
//! driver uses warm worker threads, while an in-process driver may run work
//! directly or provide its own scheduler.

const std = @import("std");
const build_events = @import("daemon/build_events.zig");
const settings = @import("daemon/settings.zig");

pub const BuildEvent = build_events.Event;
pub const BuildSink = build_events.Sink;
pub const BuildMode = settings.Mode;
pub const BuildSettings = settings.Settings;
pub const Setting = settings.Setting;

pub const MissingPlan = struct {
    allocator: std.mem.Allocator,
    will_build: [][]u8,
    will_substitute: [][]u8,
    unknown: [][]u8,
    download_size: u64,
    nar_size: u64,

    pub fn deinit(self: *MissingPlan) void {
        freeStrings(self.allocator, self.will_build);
        freeStrings(self.allocator, self.will_substitute);
        freeStrings(self.allocator, self.unknown);
        self.* = undefined;
    }

    pub fn freeStrings(allocator: std.mem.Allocator, strings: [][]u8) void {
        for (strings) |item| allocator.free(item);
        allocator.free(strings);
    }
};

/// One object Fix has already content-addressed. `expected_path` is part of
/// the contract: a backend returns its independently computed path and the
/// realization layer rejects a mismatch.
pub const AddObject = union(enum) {
    text: struct {
        expected_path: []const u8,
        name: []const u8,
        bytes: []const u8,
        references: []const []const u8,
    },
    nar: struct {
        expected_path: []const u8,
        name: []const u8,
        bytes: []const u8,
    },
    flat: struct {
        expected_path: []const u8,
        name: []const u8,
        bytes: []const u8,
    },

    pub fn expectedPath(self: AddObject) []const u8 {
        return switch (self) {
            inline else => |object| object.expected_path,
        };
    }
};

pub const VTable = struct {
    is_valid_path: *const fn (context: *anyopaque, path: []const u8) anyerror!bool,
    /// Return the backend-computed store path, owned by `allocator`.
    add_object: *const fn (context: *anyopaque, allocator: std.mem.Allocator, object: AddObject) anyerror![]u8,
    /// Read a single regular-file store object. This is the semantic operation
    /// Fix needs; a remote-daemon adapter may implement it through NarFromPath.
    read_file: *const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
    build_paths: *const fn (context: *anyopaque, paths: []const []const u8, sink: ?BuildSink, mode: BuildMode) anyerror!void,
    query_missing: *const fn (context: *anyopaque, allocator: std.mem.Allocator, paths: []const []const u8) anyerror!MissingPlan,
    add_indirect_root: *const fn (context: *anyopaque, link_path: []const u8, target: []const u8) anyerror!void,
    /// Borrowed until the next operation on this connection.
    last_error: *const fn (context: *anyopaque) ?[]const u8,
};

pub const Connection = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub fn isValidPath(self: Connection, path: []const u8) !bool {
        return self.vtable.is_valid_path(self.context, path);
    }

    pub fn addObject(self: Connection, allocator: std.mem.Allocator, object: AddObject) ![]u8 {
        return self.vtable.add_object(self.context, allocator, object);
    }

    pub fn readFile(self: Connection, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.vtable.read_file(self.context, allocator, path);
    }

    pub fn buildPaths(self: Connection, paths: []const []const u8, sink: ?BuildSink, mode: BuildMode) !void {
        return self.vtable.build_paths(self.context, paths, sink, mode);
    }

    pub fn queryMissing(self: Connection, allocator: std.mem.Allocator, paths: []const []const u8) !MissingPlan {
        return self.vtable.query_missing(self.context, allocator, paths);
    }

    pub fn addIndirectRoot(self: Connection, link_path: []const u8, target: []const u8) !void {
        return self.vtable.add_indirect_root(self.context, link_path, target);
    }

    pub fn lastError(self: Connection) ?[]const u8 {
        return self.vtable.last_error(self.context);
    }
};

/// One backend operation. `raw_connection` is interpreted only by the Driver
/// that invokes the callback and is converted with `Driver.connection`.
pub const WorkFn = *const fn (raw_connection: ?*anyopaque, context: *anyopaque) void;

/// Caller-owned asynchronous work. Drivers may complete it inline or retain it
/// until execution finishes; consequently the job and its context must remain
/// alive until the callback runs. `next` is reserved for driver scheduling.
pub const Job = struct {
    run: WorkFn,
    ctx: *anyopaque,
    next: ?*Job = null,
};

/// Type-erased backend capability, following the `std.mem.Allocator` shape.
///
/// The vtable deliberately owns execution as well as connection conversion.
/// This avoids prescribing threads, per-worker connection opens, or a shared
/// handle. `start` is called once before dispatch; `run` completes its callback
/// before returning, while `submit` may complete it asynchronously or inline.
pub const Driver = struct {
    ptr: *anyopaque,
    vtable: *const Driver.VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque) anyerror!void,
        run: *const fn (ptr: *anyopaque, work: WorkFn, context: *anyopaque) anyerror!void,
        submit: *const fn (ptr: *anyopaque, job: *Job) anyerror!void,
        connection: *const fn (ptr: *anyopaque, raw_connection: *anyopaque) Connection,
        destroy: ?*const fn (ptr: *anyopaque) void = null,
    };

    pub fn start(self: Driver) !void {
        return self.vtable.start(self.ptr);
    }

    pub fn run(self: Driver, work: WorkFn, context: *anyopaque) !void {
        return self.vtable.run(self.ptr, work, context);
    }

    pub fn submit(self: Driver, job: *Job) !void {
        return self.vtable.submit(self.ptr, job);
    }

    pub fn connection(self: Driver, raw_connection: *anyopaque) Connection {
        return self.vtable.connection(self.ptr, raw_connection);
    }

    pub fn destroy(self: Driver) void {
        if (self.vtable.destroy) |destroy_fn| destroy_fn(self.ptr);
    }
};
