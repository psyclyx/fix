//! Minimal worker-protocol daemon used by RealizationStore realization tests.
//!
//! It intentionally implements only the operations exercised by the recipe
//! registry: handshake, isValidPath, add-to-store (text/NAR/flat), and
//! buildPaths. It is not a general nix-daemon emulator.

const std = @import("std");
const builtin = @import("builtin");
const owned_strings = @import("base").owned_strings;
const sync = @import("base").sync;
const runtime_store = @import("../../daemon.zig");
const wire = runtime_store.wire;

pub const FakeDaemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: []u8,
    server: std.Io.net.Server,
    /// The accept loop; it spawns one `serveConn` thread per client connection
    /// (the connection pool opens several), collected in `conn_threads`.
    thread: std.Thread,
    conn_threads: std.ArrayListUnmanaged(std.Thread) = .empty,
    shutdown: std.atomic.Value(bool) = .init(false),
    mu: sync.BlockingMutex = .{},
    valid_paths: std.StringHashMapUnmanaged(void) = .empty,
    operations: std.ArrayListUnmanaged(Operation) = .empty,
    materializations: std.ArrayListUnmanaged(Materialization) = .empty,
    fail_next_add: bool = false,
    fail_next_build: bool = false,
    build_hook: ?BuildHook = null,
    server_error: ?anyerror = null,

    pub const Kind = enum { query, text, nar, flat, build };

    /// Test synchronization seam invoked after a build request is recorded but
    /// before it is materialized or answered. The hook runs on the fake
    /// daemon's per-connection thread, so separate build requests can rendezvous
    /// to prove client-side pipelining without timing assumptions.
    pub const BuildHook = struct {
        context: *anyopaque,
        run: *const fn (context: *anyopaque, subject: []const u8) void,
    };

    const Operation = struct {
        kind: Kind,
        subject: []u8,
        payload: []u8,
        references: [][]u8,

        fn deinit(self: Operation, allocator: std.mem.Allocator) void {
            allocator.free(self.subject);
            allocator.free(self.payload);
            for (self.references) |reference| allocator.free(reference);
            allocator.free(self.references);
        }
    };

    const Materialization = struct {
        subject: []u8,
        path: []u8,
        payload: ?[]u8,

        fn deinit(self: Materialization, allocator: std.mem.Allocator) void {
            allocator.free(self.subject);
            allocator.free(self.path);
            if (self.payload) |payload| allocator.free(payload);
        }
    };

    var next_socket_id: std.atomic.Value(u64) = .init(0);

    pub fn makeSocketPath(allocator: std.mem.Allocator) ![]u8 {
        const id = next_socket_id.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(allocator, "\x00fix-ifd-test-{d}-{d}", .{ std.Thread.getCurrentId(), id });
    }

    pub fn makeFilesystemSocketPath(allocator: std.mem.Allocator) ![]u8 {
        const id = next_socket_id.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(allocator, "/tmp/fix-ifd-test-{d}-{d}.sock", .{ std.Thread.getCurrentId(), id });
    }

    pub fn start(allocator: std.mem.Allocator, io: std.Io) !*FakeDaemon {
        // Linux supports an abstract Unix-socket namespace (leading NUL).
        // Darwin treats that byte sequence as a filesystem address and bind(2)
        // fails with ENOENT, so use a short pathname there.
        const socket_path = if (builtin.os.tag == .linux)
            try makeSocketPath(allocator)
        else
            try makeFilesystemSocketPath(allocator);
        defer allocator.free(socket_path);
        return startAt(allocator, io, socket_path);
    }

    pub fn startAt(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !*FakeDaemon {
        const owned_path = try allocator.dupe(u8, socket_path);
        errdefer allocator.free(owned_path);
        const address = try std.Io.net.UnixAddress.init(owned_path);
        var server = try address.listen(io, .{});
        errdefer server.deinit(io);

        const self = try allocator.create(FakeDaemon);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .socket_path = owned_path,
            .server = server,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    /// The connected RealizationStore (and its connection pool) must be
    /// deinitialized before this helper, so closing the client streams lets the
    /// per-connection serve threads leave their read loops.
    pub fn deinit(self: *FakeDaemon) void {
        // Stop the accept loop. Closing the listening socket does NOT reliably
        // interrupt a blocked `accept()` (Linux), so signal shutdown and unblock
        // the loop with a throwaway self-connection; it accepts that, sees the
        // flag, and returns. Then join it (so `conn_threads` is final) and join
        // the per-connection serve threads (already ending — the client pool
        // connections were closed when the store's runtime was torn down).
        self.shutdown.store(true, .release);
        self.wakeAccept();
        self.thread.join();
        for (self.conn_threads.items) |t| t.join();
        self.conn_threads.deinit(self.allocator);
        self.server.socket.close(self.io);
        if (self.socket_path.len != 0 and self.socket_path[0] != 0) {
            std.Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
        }
        self.mu.lock();
        var valid = self.valid_paths.keyIterator();
        while (valid.next()) |path| self.allocator.free(path.*);
        self.valid_paths.deinit(self.allocator);
        for (self.operations.items) |operation| operation.deinit(self.allocator);
        self.operations.deinit(self.allocator);
        for (self.materializations.items) |materialization| materialization.deinit(self.allocator);
        self.materializations.deinit(self.allocator);
        self.mu.unlock();
        self.allocator.free(self.socket_path);
        self.allocator.destroy(self);
    }

    pub fn socketPath(self: *const FakeDaemon) []const u8 {
        return self.socket_path;
    }

    pub fn markValid(self: *FakeDaemon, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        self.mu.lock();
        defer self.mu.unlock();
        if (self.valid_paths.contains(path)) {
            self.allocator.free(owned);
            return;
        }
        try self.valid_paths.put(self.allocator, owned, {});
    }

    /// Configure an exact build subject to create `path` as a directory before
    /// the fake reports build success. Register parent directories before
    /// children; this fixture deliberately does not emulate a general store.
    pub fn registerBuildDirectory(self: *FakeDaemon, subject: []const u8, path: []const u8) !void {
        try self.registerMaterialization(subject, path, null);
    }

    /// Configure an exact build subject to write `payload` to absolute `path`
    /// before the fake reports build success.
    pub fn registerBuildFile(self: *FakeDaemon, subject: []const u8, path: []const u8, payload: []const u8) !void {
        try self.registerMaterialization(subject, path, payload);
    }

    fn registerMaterialization(self: *FakeDaemon, subject: []const u8, path: []const u8, payload: ?[]const u8) !void {
        const owned_subject = try self.allocator.dupe(u8, subject);
        errdefer self.allocator.free(owned_subject);
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_payload = if (payload) |bytes| try self.allocator.dupe(u8, bytes) else null;
        errdefer if (owned_payload) |bytes| self.allocator.free(bytes);
        self.mu.lock();
        defer self.mu.unlock();
        try self.materializations.append(self.allocator, .{
            .subject = owned_subject,
            .path = owned_path,
            .payload = owned_payload,
        });
    }

    pub fn failNextAdd(self: *FakeDaemon) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.fail_next_add = true;
    }

    pub fn failNextBuild(self: *FakeDaemon) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.fail_next_build = true;
    }

    pub fn setBuildHook(self: *FakeDaemon, hook: ?BuildHook) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.build_hook = hook;
    }

    pub fn count(self: *FakeDaemon, kind: Kind) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var result: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind == kind) result += 1;
        }
        return result;
    }

    pub fn effectCount(self: *FakeDaemon) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var result: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind != .query) result += 1;
        }
        return result;
    }

    pub fn effectKindAt(self: *FakeDaemon, index: usize) ?Kind {
        self.mu.lock();
        defer self.mu.unlock();
        var seen: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind == .query) continue;
            if (seen == index) return operation.kind;
            seen += 1;
        }
        return null;
    }

    pub fn effectSubjectEquals(self: *FakeDaemon, index: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var seen: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind == .query) continue;
            if (seen == index) return std.mem.eql(u8, operation.subject, expected);
            seen += 1;
        }
        return false;
    }

    pub fn effectPayloadEquals(self: *FakeDaemon, index: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var seen: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind == .query) continue;
            if (seen == index) return std.mem.eql(u8, operation.payload, expected);
            seen += 1;
        }
        return false;
    }

    pub fn effectReferencesEqual(self: *FakeDaemon, index: usize, expected: []const []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var seen: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind == .query) continue;
            if (seen != index) {
                seen += 1;
                continue;
            }
            if (operation.references.len != expected.len) return false;
            for (operation.references, expected) |left, right| {
                if (!std.mem.eql(u8, left, right)) return false;
            }
            return true;
        }
        return false;
    }

    pub fn kindAt(self: *FakeDaemon, index: usize) ?Kind {
        self.mu.lock();
        defer self.mu.unlock();
        if (index >= self.operations.items.len) return null;
        return self.operations.items[index].kind;
    }

    pub fn subjectEquals(self: *FakeDaemon, index: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (index >= self.operations.items.len) return false;
        return std.mem.eql(u8, self.operations.items[index].subject, expected);
    }

    pub fn payloadEquals(self: *FakeDaemon, index: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (index >= self.operations.items.len) return false;
        return std.mem.eql(u8, self.operations.items[index].payload, expected);
    }

    pub fn nthSubjectEquals(self: *FakeDaemon, kind: Kind, n: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var seen: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind != kind) continue;
            if (seen == n) return std.mem.eql(u8, operation.subject, expected);
            seen += 1;
        }
        return false;
    }

    pub fn nthPayloadEquals(self: *FakeDaemon, kind: Kind, n: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var seen: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind != kind) continue;
            if (seen == n) return std.mem.eql(u8, operation.payload, expected);
            seen += 1;
        }
        return false;
    }

    pub fn nthMaterializationSubjectEquals(self: *FakeDaemon, n: usize, expected: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        var seen: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind != .text and operation.kind != .nar and operation.kind != .flat) continue;
            if (seen == n) return std.mem.eql(u8, operation.subject, expected);
            seen += 1;
        }
        return false;
    }

    pub fn materializationCount(self: *FakeDaemon) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var result: usize = 0;
        for (self.operations.items) |operation| {
            if (operation.kind == .text or operation.kind == .nar or operation.kind == .flat) result += 1;
        }
        return result;
    }

    pub fn serverResult(self: *FakeDaemon) !void {
        if (self.server_error) |err| return err;
    }

    /// Accept loop: one `serveConn` thread per client connection (the pool opens
    /// several). Ends when `deinit` sets `shutdown` and self-connects to unblock.
    fn serve(self: *FakeDaemon) void {
        while (true) {
            const stream = self.server.accept(self.io) catch return;
            if (self.shutdown.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            const t = std.Thread.spawn(.{}, serveConn, .{ self, stream }) catch {
                stream.close(self.io);
                continue;
            };
            self.conn_threads.append(self.allocator, t) catch {
                t.detach();
            };
        }
    }

    /// Unblock the accept loop with a throwaway connection (see `deinit`).
    fn wakeAccept(self: *FakeDaemon) void {
        const address = std.Io.net.UnixAddress.init(self.socket_path) catch return;
        const stream = address.connect(self.io) catch return;
        stream.close(self.io);
    }

    fn serveConn(self: *FakeDaemon, stream: std.Io.net.Stream) void {
        self.serveFallible(stream) catch |err| {
            self.mu.lock();
            if (self.server_error == null) self.server_error = err;
            self.mu.unlock();
        };
    }

    fn serveFallible(self: *FakeDaemon, stream: std.Io.net.Stream) !void {
        defer stream.close(self.io);
        var read_buffer: [64 * 1024]u8 = undefined;
        var write_buffer: [64 * 1024]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(stream, self.io, &read_buffer);
        var writer = std.Io.net.Stream.Writer.init(stream, self.io, &write_buffer);
        const input = &reader.interface;
        const output = &writer.interface;

        if ((try wire.readInt(input)) != wire.worker_magic_1) return error.WorkerMagicMismatch;
        try wire.writeInt(output, wire.worker_magic_2);
        try wire.writeInt(output, wire.protocol_version);
        try output.flush();
        _ = try wire.readInt(input); // client protocol
        _ = try wire.readInt(input); // obsolete CPU affinity
        _ = try wire.readInt(input); // obsolete reserveSpace
        try wire.writeString(output, "fix-test-daemon");
        try wire.writeInt(output, 1); // trusted
        try wire.writeInt(output, wire.stderr_last);
        try output.flush();

        while (true) {
            const raw_op = wire.readInt(input) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            const op = std.enums.fromInt(wire.Op, raw_op) orelse return error.UnsupportedWorkerOperation;
            switch (op) {
                .is_valid_path => try self.handleIsValid(input, output),
                .add_to_store => try self.handleAdd(input, output),
                .build_paths => try self.handleBuild(input, output),
                else => return error.UnsupportedWorkerOperation,
            }
        }
    }

    fn handleIsValid(self: *FakeDaemon, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const path = try wire.readString(self.allocator, input);
        defer self.allocator.free(path);
        try self.appendOperation(.query, path, "", &.{});
        self.mu.lock();
        const valid = self.valid_paths.contains(path);
        self.mu.unlock();
        try wire.writeInt(output, wire.stderr_last);
        try wire.writeBool(output, valid);
        try output.flush();
    }

    fn handleAdd(self: *FakeDaemon, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const name = try wire.readString(self.allocator, input);
        defer self.allocator.free(name);
        const content_address = try wire.readString(self.allocator, input);
        defer self.allocator.free(content_address);
        const references = try wire.readStrings(self.allocator, input);
        defer owned_strings.free(self.allocator, references);
        _ = try wire.readBool(input); // repair
        const payload = try readFramed(self.allocator, input);
        defer self.allocator.free(payload);
        const kind: Kind = if (std.mem.eql(u8, content_address, "text:sha256"))
            .text
        else if (std.mem.eql(u8, content_address, "fixed:r:sha256"))
            .nar
        else if (std.mem.eql(u8, content_address, "fixed:sha256"))
            .flat
        else
            return error.UnsupportedContentAddress;
        try self.appendOperation(kind, name, payload, references);

        self.mu.lock();
        const fail = self.fail_next_add;
        self.fail_next_add = false;
        self.mu.unlock();
        if (fail) return writeDaemonError(output, "scripted permanent add failure");

        try wire.writeInt(output, wire.stderr_last);
        // Realization checks that the store independently computed the same
        // path. The worker protocol carries only `name` in AddToStore, so this
        // fake recovers the complete expected path from the preceding
        // IsValidPath operation with the same store name. Direct protocol tests
        // without such a matching query retain the synthetic fallback.
        const returned_path = (try self.queriedPathForName(name)) orelse
            try std.fmt.allocPrint(self.allocator, "/nix/store/fake-{s}", .{name});
        defer self.allocator.free(returned_path);
        try writeValidPathInfo(output, returned_path);
        try output.flush();
    }

    fn queriedPathForName(self: *FakeDaemon, name: []const u8) !?[]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        var index = self.operations.items.len;
        while (index > 0) {
            index -= 1;
            const operation = self.operations.items[index];
            if (operation.kind != .query) continue;
            const base = std.fs.path.basename(operation.subject);
            const queried_name = if (base.len > 33 and base[32] == '-') base[33..] else base;
            if (std.mem.eql(u8, queried_name, name))
                return try self.allocator.dupe(u8, operation.subject);
        }
        return null;
    }

    fn handleBuild(self: *FakeDaemon, input: *std.Io.Reader, output: *std.Io.Writer) !void {
        const paths = try wire.readStrings(self.allocator, input);
        defer owned_strings.free(self.allocator, paths);
        _ = try wire.readInt(input); // build mode
        for (paths) |path| try self.appendOperation(.build, path, "", &.{});

        self.mu.lock();
        const hook = self.build_hook;
        self.mu.unlock();
        if (hook) |active| for (paths) |path| active.run(active.context, path);

        self.mu.lock();
        const fail = self.fail_next_build;
        self.fail_next_build = false;
        self.mu.unlock();
        if (fail) return writeDaemonError(output, "scripted permanent build failure");

        for (paths) |path| try self.materialize(path);
        try wire.writeInt(output, wire.stderr_last);
        try wire.writeInt(output, 0);
        try output.flush();
    }

    fn materialize(self: *FakeDaemon, subject: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.materializations.items) |materialization| {
            if (!std.mem.eql(u8, materialization.subject, subject)) continue;
            if (materialization.payload) |payload| {
                try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = materialization.path, .data = payload });
            } else {
                std.Io.Dir.createDirAbsolute(self.io, materialization.path, .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            }
        }
    }

    fn appendOperation(self: *FakeDaemon, kind: Kind, subject: []const u8, payload: []const u8, references: []const []const u8) !void {
        const owned_subject = try self.allocator.dupe(u8, subject);
        errdefer self.allocator.free(owned_subject);
        const owned_payload = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned_payload);
        const owned_references = try owned_strings.clone(self.allocator, references);
        errdefer owned_strings.free(self.allocator, owned_references);
        self.mu.lock();
        defer self.mu.unlock();
        try self.operations.append(self.allocator, .{
            .kind = kind,
            .subject = owned_subject,
            .payload = owned_payload,
            .references = owned_references,
        });
    }
};

fn readFramed(allocator: std.mem.Allocator, input: *std.Io.Reader) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);
    while (true) {
        const len = try wire.readInt(input);
        if (len == 0) return result.toOwnedSlice(allocator);
        if (len > wire.max_wire_len) return error.WireStringTooLong;
        const old_len = result.items.len;
        try result.resize(allocator, old_len + @as(usize, @intCast(len)));
        try input.readSliceAll(result.items[old_len..]);
    }
}

fn writeDaemonError(output: *std.Io.Writer, message: []const u8) !void {
    try wire.writeInt(output, wire.stderr_error);
    try wire.writeString(output, "Error");
    try wire.writeInt(output, 0);
    try wire.writeString(output, "Error");
    try wire.writeString(output, message);
    try wire.writeInt(output, 0); // no position
    try wire.writeInt(output, 0); // no traces
    try output.flush();
}

fn writeValidPathInfo(output: *std.Io.Writer, path: []const u8) !void {
    try wire.writeString(output, path);
    try wire.writeString(output, ""); // deriver
    try wire.writeString(output, "sha256:fake");
    try wire.writeStrings(output, &.{});
    try wire.writeInt(output, 0); // registration time
    try wire.writeInt(output, 0); // NAR size
    try wire.writeInt(output, 0); // ultimate
    try wire.writeStrings(output, &.{}); // signatures
    try wire.writeString(output, ""); // content address
}

// Keep the protocol helper independently compiled: Task 4's guarded RED tests
// must not hide syntax or framing mistakes in test-only infrastructure.
test "fake derivation daemon supports the concrete DaemonStore protocol subset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "materialized", .default_dir);
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const output_dir = try std.fs.path.resolve(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "materialized", "out" });
    defer std.testing.allocator.free(output_dir);
    const output_file = try std.fs.path.resolve(std.testing.allocator, &.{ output_dir, "result.txt" });
    defer std.testing.allocator.free(output_file);

    var fake = try FakeDaemon.start(std.testing.allocator, std.testing.io);
    defer fake.deinit();
    try fake.registerBuildDirectory("/nix/store/example.drv!out", output_dir);
    try fake.registerBuildFile("/nix/store/example.drv!out", output_file, "built payload");

    const daemon = try runtime_store.DaemonStore.connect(std.testing.allocator, std.testing.io, fake.socketPath());
    defer daemon.deinit();
    try std.testing.expect(!(try daemon.isValidPath("/nix/store/missing")));
    const text_path = try daemon.addTextToStore(std.testing.allocator, "example", "text payload", &.{});
    defer std.testing.allocator.free(text_path);
    const nar_path = try daemon.addPath(std.testing.allocator, "nar-example", "nix-archive-1", &.{});
    defer std.testing.allocator.free(nar_path);
    const flat_path = try daemon.addFlatFile(std.testing.allocator, "flat-example", "flat payload", &.{});
    defer std.testing.allocator.free(flat_path);
    try daemon.buildPaths(&.{"/nix/store/example.drv!out"}, null, .normal);
    try std.testing.expectEqual(@as(usize, 1), fake.count(.query));
    try std.testing.expectEqual(@as(usize, 1), fake.count(.text));
    try std.testing.expectEqual(@as(usize, 1), fake.count(.nar));
    try std.testing.expectEqual(@as(usize, 1), fake.count(.flat));
    try std.testing.expect(fake.nthPayloadEquals(.text, 0, "text payload"));
    try std.testing.expect(fake.nthPayloadEquals(.nar, 0, "nix-archive-1"));
    try std.testing.expect(fake.nthPayloadEquals(.flat, 0, "flat payload"));
    try std.testing.expectEqual(@as(usize, 1), fake.count(.build));
    const materialized = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, output_file, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(materialized);
    try std.testing.expectEqualStrings("built payload", materialized);
}
