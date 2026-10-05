//! Direct in-process store backend for contract and realization tests.
//!
//! The dummy deliberately performs no hashing: it accepts the expected path
//! supplied by Fix, records every effect, and keeps object bytes in memory.
//! It executes on the caller instead of inheriting the daemon's pool, proving
//! the Driver contract does not prescribe threads or per-worker connections.

const std = @import("std");
const sync = @import("base").sync;
const backend = @import("../backend.zig");

pub const DummyStore = struct {
    allocator: std.mem.Allocator,
    mu: sync.BlockingMutex = .{},
    objects: std.StringHashMapUnmanaged([]u8) = .empty,
    effects: std.ArrayListUnmanaged(Effect) = .empty,
    returned_path: ?[]u8 = null,
    starts: usize = 0,

    pub const Kind = enum {
        check,
        text,
        nar,
        flat,
        read,
        build,
        query_missing,
        root,
    };

    pub const Effect = struct {
        kind: Kind,
        subject: []u8,
        payload: []u8,
        references: [][]u8,

        fn deinit(self: *Effect, allocator: std.mem.Allocator) void {
            allocator.free(self.subject);
            allocator.free(self.payload);
            backend.MissingPlan.freeStrings(allocator, self.references);
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator) DummyStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DummyStore) void {
        var objects = self.objects.iterator();
        while (objects.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.objects.deinit(self.allocator);
        for (self.effects.items) |*item| item.deinit(self.allocator);
        self.effects.deinit(self.allocator);
        if (self.returned_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn driver(self: *DummyStore) backend.Driver {
        return .{ .ptr = self, .vtable = &driver_vtable };
    }

    /// Make the next and subsequent writes report a different computed path.
    /// Useful for testing the realization layer's path-parity guard.
    pub fn setReturnedPath(self: *DummyStore, path: ?[]const u8) !void {
        const replacement = if (path) |value| try self.allocator.dupe(u8, value) else null;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.returned_path) |old| self.allocator.free(old);
        self.returned_path = replacement;
    }

    pub fn contains(self: *DummyStore, path: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.objects.contains(path);
    }

    pub fn effectCount(self: *DummyStore, kind: Kind) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var count: usize = 0;
        for (self.effects.items) |item| if (item.kind == kind) {
            count += 1;
        };
        return count;
    }

    pub fn startCount(self: *DummyStore) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.starts;
    }

    pub fn effectsLen(self: *DummyStore) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.effects.items.len;
    }

    pub fn effectAt(self: *DummyStore, index: usize) ?EffectView {
        self.mu.lock();
        defer self.mu.unlock();
        const item = if (index < self.effects.items.len) &self.effects.items[index] else return null;
        return .{
            .kind = item.kind,
            .subject = item.subject,
            .payload = item.payload,
            .references = item.references,
        };
    }

    pub const EffectView = struct {
        kind: Kind,
        subject: []const u8,
        payload: []const u8,
        references: []const []const u8,
    };

    const driver_vtable: backend.Driver.VTable = .{
        .start = start,
        .run = run,
        .submit = submit,
        .connection = connection,
    };

    const connection_vtable: backend.VTable = .{
        .is_valid_path = isValidPath,
        .add_object = addObject,
        .read_file = readFile,
        .build_paths = buildPaths,
        .query_missing = queryMissing,
        .add_indirect_root = addIndirectRoot,
        .last_error = lastError,
    };

    fn selfFrom(raw: *anyopaque) *DummyStore {
        return @ptrCast(@alignCast(raw));
    }

    fn start(raw: *anyopaque) !void {
        const self = selfFrom(raw);
        self.mu.lock();
        defer self.mu.unlock();
        self.starts += 1;
    }

    fn run(raw: *anyopaque, work: backend.WorkFn, context: *anyopaque) !void {
        work(raw, context);
    }

    fn submit(raw: *anyopaque, job: *backend.Job) !void {
        job.run(raw, job.ctx);
    }

    fn connection(_: *anyopaque, raw_connection: *anyopaque) backend.Connection {
        return .{ .context = raw_connection, .vtable = &connection_vtable };
    }

    fn isValidPath(raw: *anyopaque, path: []const u8) !bool {
        const self = selfFrom(raw);
        self.mu.lock();
        defer self.mu.unlock();
        try self.appendEffectLocked(.check, path, "", &.{});
        return self.objects.contains(path);
    }

    fn addObject(raw: *anyopaque, allocator: std.mem.Allocator, object: backend.AddObject) ![]u8 {
        const self = selfFrom(raw);
        const Fields = struct {
            kind: Kind,
            path: []const u8,
            payload: []const u8,
            references: []const []const u8,
        };
        const fields: Fields = switch (object) {
            .text => |value| .{ .kind = Kind.text, .path = value.expected_path, .payload = value.bytes, .references = value.references },
            .nar => |value| .{ .kind = Kind.nar, .path = value.expected_path, .payload = value.bytes, .references = @as([]const []const u8, &.{}) },
            .flat => |value| .{ .kind = Kind.flat, .path = value.expected_path, .payload = value.bytes, .references = @as([]const []const u8, &.{}) },
        };

        self.mu.lock();
        defer self.mu.unlock();
        try self.putObjectLocked(fields.path, fields.payload);
        try self.appendEffectLocked(fields.kind, fields.path, fields.payload, fields.references);
        return allocator.dupe(u8, self.returned_path orelse fields.path);
    }

    fn readFile(raw: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self = selfFrom(raw);
        self.mu.lock();
        defer self.mu.unlock();
        try self.appendEffectLocked(.read, path, "", &.{});
        const bytes = self.objects.get(path) orelse return error.PathNotValid;
        return allocator.dupe(u8, bytes);
    }

    fn buildPaths(raw: *anyopaque, paths: []const []const u8, sink: ?backend.BuildSink, _: backend.BuildMode) !void {
        const self = selfFrom(raw);
        for (paths, 0..) |path, index| {
            {
                self.mu.lock();
                defer self.mu.unlock();
                try self.appendEffectLocked(.build, path, "", &.{});
            }
            if (sink) |output| {
                const id: u64 = @intCast(index + 1);
                output.emit(.{ .start = .{ .id = id, .kind = .build, .subject = path, .detail = "dummy" } });
                output.emit(.{ .stop = id });
            }
        }
    }

    fn queryMissing(raw: *anyopaque, allocator: std.mem.Allocator, paths: []const []const u8) !backend.MissingPlan {
        const self = selfFrom(raw);
        self.mu.lock();
        for (paths) |path| self.appendEffectLocked(.query_missing, path, "", &.{}) catch |err| {
            self.mu.unlock();
            return err;
        };
        self.mu.unlock();

        const will_build = try cloneStrings(allocator, paths);
        errdefer backend.MissingPlan.freeStrings(allocator, will_build);
        const will_substitute = try cloneStrings(allocator, &.{});
        errdefer backend.MissingPlan.freeStrings(allocator, will_substitute);
        const unknown = try cloneStrings(allocator, &.{});
        return .{
            .allocator = allocator,
            .will_build = will_build,
            .will_substitute = will_substitute,
            .unknown = unknown,
            .download_size = 0,
            .nar_size = 0,
        };
    }

    fn addIndirectRoot(raw: *anyopaque, link_path: []const u8, target: []const u8) !void {
        const self = selfFrom(raw);
        self.mu.lock();
        defer self.mu.unlock();
        try self.appendEffectLocked(.root, link_path, target, &.{});
    }

    fn lastError(_: *anyopaque) ?[]const u8 {
        return null;
    }

    fn putObjectLocked(self: *DummyStore, path: []const u8, payload: []const u8) !void {
        if (self.objects.contains(path)) return;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_payload = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned_payload);
        try self.objects.put(self.allocator, owned_path, owned_payload);
    }

    fn appendEffectLocked(self: *DummyStore, kind: Kind, subject: []const u8, payload: []const u8, references: []const []const u8) !void {
        const owned_subject = try self.allocator.dupe(u8, subject);
        errdefer self.allocator.free(owned_subject);
        const owned_payload = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned_payload);
        const owned_references = try cloneStrings(self.allocator, references);
        errdefer backend.MissingPlan.freeStrings(self.allocator, owned_references);
        try self.effects.append(self.allocator, .{
            .kind = kind,
            .subject = owned_subject,
            .payload = owned_payload,
            .references = owned_references,
        });
    }
};

fn cloneStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![][]u8 {
    const result = try allocator.alloc([]u8, strings.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |item| allocator.free(item);
        allocator.free(result);
    }
    for (strings, result) |source, *target| {
        target.* = try allocator.dupe(u8, source);
        initialized += 1;
    }
    return result;
}

test "dummy driver implements the store backend contract" {
    const testing = std.testing;
    const path = "/nix/store/00000000000000000000000000000000-dummy";
    var dummy = DummyStore.init(testing.allocator);
    defer dummy.deinit();

    const driver = dummy.driver();
    try driver.start();

    const Capture = struct {
        driver: backend.Driver,
        connection: ?backend.Connection = null,

        fn run(raw: ?*anyopaque, context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.connection = self.driver.connection(raw.?);
        }
    };
    var capture: Capture = .{ .driver = driver };
    try driver.run(Capture.run, &capture);
    const connection = capture.connection.?;

    var submitted: Capture = .{ .driver = driver };
    var job: backend.Job = .{ .run = Capture.run, .ctx = &submitted };
    try driver.submit(&job);
    try testing.expect(submitted.connection != null);

    try testing.expect(!try connection.isValidPath(path));
    const written = try connection.addObject(testing.allocator, .{ .text = .{
        .expected_path = path,
        .name = "dummy",
        .bytes = "hello",
        .references = &.{"/nix/store/reference"},
    } });
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(path, written);
    try testing.expect(try connection.isValidPath(path));

    const bytes = try connection.readFile(testing.allocator, path);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello", bytes);

    try connection.buildPaths(&.{path}, null, .normal);
    var missing = try connection.queryMissing(testing.allocator, &.{path});
    defer missing.deinit();
    try testing.expectEqual(@as(usize, 1), missing.will_build.len);
    try testing.expectEqualStrings(path, missing.will_build[0]);
    try connection.addIndirectRoot("/tmp/result", path);

    try testing.expectEqual(@as(usize, 2), dummy.effectCount(.check));
    try testing.expectEqual(@as(usize, 1), dummy.effectCount(.text));
    try testing.expectEqual(@as(usize, 1), dummy.effectCount(.read));
    try testing.expectEqual(@as(usize, 1), dummy.effectCount(.build));
    try testing.expectEqual(@as(usize, 1), dummy.effectCount(.query_missing));
    try testing.expectEqual(@as(usize, 1), dummy.effectCount(.root));
}
