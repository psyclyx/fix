//! Nix/Lix nix-daemon worker-protocol client.
//!
//! Connects to the daemon's Unix socket, performs the version-negotiating
//! handshake, and exposes store operations. Store mutation on a daemon-managed
//! `/nix/store` (the normal case: the store is `root:nixbld`, not user
//! writable) must go through here rather than touching the filesystem.
//!
//! The connection owns the framed reader/writer and drains the `STDERR_*`
//! sideband after every op.

const std = @import("std");
const terminal_text = @import("base").terminal_text;
const wire = @import("wire.zig");
const build_events = @import("build_events.zig");
const endpoint = @import("endpoint.zig");
const nar_reader = @import("nar_reader.zig");
const backend = @import("../backend.zig");

const ActivityType = enum(u64) {
    build = 105,
    substitute = 108,
    post_build_hook = 110,
    _,
};

const ResultType = enum(u64) {
    build_log_line = 101,
    progress = 105,
    post_build_log_line = 107,
    _,
};

/// A consumer of the daemon's build activity/log stream (see `buildPaths`).
/// Callbacks run on the calling thread while the build is in progress.
pub const BuildSink = backend.BuildSink;

/// Build realization mode sent with `build_paths` (Nix's `BuildMode`): the
/// default build, `--repair` (rebuild and fix corrupted paths), or `--check`
/// (rebuild and verify outputs are unchanged).
pub const BuildMode = backend.BuildMode;

/// A `name = value` daemon setting carried in the `set_options` overrides map.
pub const Setting = backend.Setting;

/// Per-connection daemon settings applied via `set_options` (op 19). Mirrors
/// the client settings Nix sends after the handshake: the fixed fields plus a
/// trailing overrides map for any other `nix.conf` key (e.g. `timeout`). The
/// daemon applies the map after the fixed fields, so an override wins.
pub const BuildSettings = backend.BuildSettings;
pub const MissingPlan = backend.MissingPlan;

/// A daemon connection over a direct socket or an explicit SSH remote. Store
/// selection never falls back to a locally installed Nix/Lix implementation.
const Transport = union(enum) {
    socket: Socket,
    command: Command,

    const Socket = struct {
        stream: std.Io.net.Stream,
        reader: std.Io.net.Stream.Reader,
        writer: std.Io.net.Stream.Writer,
    };
    const Command = struct {
        child: std.process.Child,
        reader: std.Io.File.Reader,
        writer: std.Io.File.Writer,
    };

    fn r(self: *Transport) *std.Io.Reader {
        return switch (self.*) {
            .socket => |*s| &s.reader.interface,
            .command => |*c| &c.reader.interface,
        };
    }
    fn w(self: *Transport) *std.Io.Writer {
        return switch (self.*) {
            .socket => |*s| &s.writer.interface,
            .command => |*c| &c.writer.interface,
        };
    }
    fn close(self: *Transport, io: std.Io) void {
        switch (self.*) {
            .socket => |*s| s.stream.close(io),
            .command => |*c| {
                if (c.child.stdin) |f| {
                    f.close(io);
                    c.child.stdin = null;
                }
                _ = c.child.wait(io) catch {};
            },
        }
    }
};

pub const DaemonStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: Transport,
    rbuf: []u8,
    wbuf: []u8,
    /// The daemon's advertised protocol version (its own, not the negotiated
    /// minimum — version-gated wire fields key off `protocolMinor` of this).
    daemon_version: u64 = 0,
    /// Last daemon-reported error message (owned), surfaced with
    /// `error.DaemonError`. Freed on deinit / overwritten on the next error.
    last_error: ?[]u8 = null,
    suppress_build_output: bool = false,
    /// Set during `buildPaths` to forward typed activities and logs to the CLI.
    /// The protocol layer never writes presentation output itself.
    build_sink: ?BuildSink = null,

    /// Connect to a daemon and complete the handshake. `store` is a direct
    /// `daemon`, `unix://PATH`, or `tcp://HOST:PORT` endpoint, or an explicit
    /// `ssh-ng://HOST` remote daemon.
    /// Heap-allocated so the framed reader/writer (which hold interior pointers
    /// via `@fieldParentPtr`) stay put.
    pub fn connect(allocator: std.mem.Allocator, io: std.Io, store: []const u8) !*DaemonStore {
        const self = try allocator.create(DaemonStore);
        errdefer allocator.destroy(self);

        const rbuf = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(rbuf);
        const wbuf = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(wbuf);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .transport = undefined,
            .rbuf = rbuf,
            .wbuf = wbuf,
        };
        try self.openTransport(store);
        errdefer self.transport.close(io);

        try self.handshake();
        return self;
    }

    fn openTransport(self: *DaemonStore, store: []const u8) !void {
        const io = self.io;
        switch (try endpoint.parse(store)) {
            .ssh => |target| {
                // The remote store explicitly owns the worker endpoint. No
                // local Nix/Lix executable participates in adapting it.
                var argv: [endpoint.Ssh.max_command_args][]const u8 = undefined;
                try self.openCommand(target.commandArgs(&argv));
            },
            .tcp => |target| {
                const addr = try std.Io.net.IpAddress.resolve(io, target.host, target.port);
                const stream = try addr.connect(io, .{ .mode = .stream });
                self.initSocketTransport(stream);
            },
            .unix => |target| {
                const owned_path = if (target.append_legacy_socket)
                    try std.fs.path.join(self.allocator, &.{ target.path, "socket" })
                else
                    null;
                defer if (owned_path) |path| self.allocator.free(path);
                const addr = try std.Io.net.UnixAddress.init(owned_path orelse target.path);
                self.initSocketTransport(try addr.connect(io));
            },
        }
    }

    fn initSocketTransport(self: *DaemonStore, stream: std.Io.net.Stream) void {
        self.transport = .{ .socket = .{
            .stream = stream,
            .reader = std.Io.net.Stream.Reader.init(stream, self.io, self.rbuf),
            .writer = std.Io.net.Stream.Writer.init(stream, self.io, self.wbuf),
        } };
    }

    fn openCommand(self: *DaemonStore, argv: []const []const u8) !void {
        const io = self.io;
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
        });
        errdefer {
            if (child.stdin) |f| f.close(io);
            _ = child.wait(io) catch {};
        }
        const out = child.stdout orelse return error.CommandPipeUnavailable;
        const in = child.stdin orelse return error.CommandPipeUnavailable;
        self.transport = .{ .command = .{
            .child = child,
            .reader = out.readerStreaming(io, self.rbuf),
            .writer = in.writerStreaming(io, self.wbuf),
        } };
    }

    pub fn deinit(self: *DaemonStore) void {
        if (self.last_error) |msg| self.allocator.free(msg);
        self.transport.close(self.io);
        self.allocator.free(self.rbuf);
        self.allocator.free(self.wbuf);
        self.allocator.destroy(self);
    }

    fn w(self: *DaemonStore) *std.Io.Writer {
        return self.transport.w();
    }
    fn r(self: *DaemonStore) *std.Io.Reader {
        return self.transport.r();
    }

    fn handshake(self: *DaemonStore) !void {
        try wire.writeInt(self.w(), wire.worker_magic_1);
        try self.w().flush();

        if ((try wire.readInt(self.r())) != wire.worker_magic_2) return error.WorkerMagicMismatch;
        self.daemon_version = try wire.readInt(self.r());
        if (wire.protocolMajor(self.daemon_version) != wire.protocolMajor(wire.protocol_version))
            return error.ProtocolMajorMismatch;
        if (wire.protocolMinor(self.daemon_version) < wire.minimum_protocol_minor)
            return error.ProtocolTooOld;

        try wire.writeInt(self.w(), wire.protocol_version);
        const minor = wire.protocolMinor(self.daemon_version);
        // Two obsolete fields the daemon still expects on the modern protocol:
        // CPU affinity (>=14) and reserveSpace (>=11). Both send 0/false.
        if (minor >= 14) try wire.writeInt(self.w(), 0);
        if (minor >= 11) try wire.writeInt(self.w(), 0);
        try self.w().flush();

        if (minor >= 33) {
            const nix_version = try wire.readString(self.allocator, self.r());
            self.allocator.free(nix_version); // informational; unused
        }
        if (minor >= 35) {
            _ = try wire.readInt(self.r()); // trusted-client status
        }
        try self.processStderr();
    }

    // --- operations -------------------------------------------------------

    /// Whether `path` (a full `/nix/store/...` path) is a valid store path.
    pub fn isValidPath(self: *DaemonStore, path: []const u8) !bool {
        try self.beginOp(.is_valid_path);
        try wire.writeString(self.w(), path);
        try self.flushAndDrain();
        return try wire.readBool(self.r());
    }

    /// Read a store path's contents via `NarFromPath` (op 24) — for a remote
    /// store, where the path isn't on local disk. The daemon streams a NAR after
    /// the stderr sideband; we parse the single-regular-file case (what a get-env
    /// `$out` is) and return its bytes.
    pub fn narFromPath(self: *DaemonStore, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        try self.beginOp(.nar_from_path);
        try wire.writeString(self.w(), path);
        try self.flushAndDrain();
        return try nar_reader.readSingleFile(allocator, self.r());
    }

    /// Add `text` to the store as a text-addressed object named `name`
    /// (`references` are full store paths it refers to). This is what a `.drv`
    /// file and `builtins.toFile` need. Returns the resulting `/nix/store/...`
    /// path (owned by `allocator`). Idempotent: an already-present object just
    /// returns its path.
    ///
    /// Uses the modern `AddToStore` op with text ingestion rather than the
    /// legacy `AddTextToStore` (op 8) — Lix rejects op 8 once the negotiated
    /// protocol is >= 1.25, so op 8 is not portable across Lix/Nix. The content
    /// is streamed raw through the framed sink; the daemon hashes it under the
    /// `text:sha256` scheme (same addressing as `builtins.toFile`/`.drv`
    /// paths).
    pub fn addTextToStore(self: *DaemonStore, allocator: std.mem.Allocator, name: []const u8, text: []const u8, references: []const []const u8) ![]u8 {
        try self.beginOp(.add_to_store);
        try wire.writeString(self.w(), name);
        try wire.writeString(self.w(), "text:sha256");
        try wire.writeStrings(self.w(), references);
        try wire.writeBool(self.w(), false); // repair
        try self.writeFramed(text);
        try self.flushAndDrain();
        return try self.readValidPathInfo(allocator);
    }

    /// Add a NAR-serialized tree to the store under `name`, content-addressed
    /// recursively (`nar:sha256`) — the addressing `builtins.path`/`filterSource`
    /// and fetched sources use. `nar_bytes` is a `nix-archive-1` stream (see
    /// `store.nar.serialize`). Returns the resulting store path (owned by
    /// `allocator`). Idempotent.
    pub fn addPath(self: *DaemonStore, allocator: std.mem.Allocator, name: []const u8, nar_bytes: []const u8, references: []const []const u8) ![]u8 {
        try self.beginOp(.add_to_store);
        try wire.writeString(self.w(), name);
        // `fixed:r:sha256` = fixed-output, recursive (NAR) ingestion, sha256 —
        // the addressing `builtins.path`/`nix store add` use. (The daemon
        // rejects `nar:...`; recognized prefixes are `text` and `fixed`.)
        try wire.writeString(self.w(), "fixed:r:sha256");
        try wire.writeStrings(self.w(), references);
        try wire.writeBool(self.w(), false); // repair
        try self.writeFramed(nar_bytes);
        try self.flushAndDrain();
        return try self.readValidPathInfo(allocator);
    }

    /// Read an `AddToStore` response — a `ValidPathInfo` — returning its path
    /// (owned by `allocator`) and consuming the rest so the connection stays in
    /// sync for the next op. Field order (protocol >= 16): path, deriver,
    /// narHash, references, registrationTime, narSize, ultimate, sigs, ca.
    fn readValidPathInfo(self: *DaemonStore, allocator: std.mem.Allocator) ![]u8 {
        const path = try wire.readString(allocator, self.r());
        errdefer allocator.free(path);
        try wire.skipString(self.r()); // deriver
        try wire.skipString(self.r()); // narHash
        try wire.skipStrings(self.r()); // references
        _ = try wire.readInt(self.r()); // registrationTime
        _ = try wire.readInt(self.r()); // narSize
        _ = try wire.readInt(self.r()); // ultimate (bool)
        try wire.skipStrings(self.r()); // sigs
        try wire.skipString(self.r()); // ca
        return path;
    }

    /// Add a flat (non-NAR) file's raw `bytes` to the store under `name`,
    /// content-addressed as `fixed:sha256` (flat) — the addressing
    /// `builtins.fetchurl` uses. Returns the store path (owned by `allocator`).
    pub fn addFlatFile(self: *DaemonStore, allocator: std.mem.Allocator, name: []const u8, bytes: []const u8, references: []const []const u8) ![]u8 {
        try self.beginOp(.add_to_store);
        try wire.writeString(self.w(), name);
        try wire.writeString(self.w(), "fixed:sha256"); // flat (no `r:`)
        try wire.writeStrings(self.w(), references);
        try wire.writeBool(self.w(), false); // repair
        try self.writeFramed(bytes);
        try self.flushAndDrain();
        return try self.readValidPathInfo(allocator);
    }

    /// Stream `data` through the worker protocol's framed sink: one
    /// `[u64 len][bytes]` frame followed by a zero-length terminator frame.
    /// Frame payloads are raw (not 8-byte padded like protocol strings).
    fn writeFramed(self: *DaemonStore, data: []const u8) !void {
        if (data.len != 0) {
            try wire.writeInt(self.w(), data.len);
            try self.w().writeAll(data);
        }
        try wire.writeInt(self.w(), 0);
    }

    /// Realize `derived_paths` (each a legacy `<drvpath>!<outputs>` string, e.g.
    /// `/nix/store/xxx.drv!*` for all outputs). When supplied, `sink` receives
    /// typed build activity and log events. Errors (with the daemon's message)
    /// are surfaced on failure.
    pub fn buildPaths(self: *DaemonStore, derived_paths: []const []const u8, sink: ?BuildSink, mode: BuildMode) !void {
        try self.beginOp(.build_paths);
        try wire.writeStrings(self.w(), derived_paths);
        try wire.writeInt(self.w(), @intFromEnum(mode));
        self.build_sink = sink;
        defer self.build_sink = null;
        try self.flushAndDrain();
        _ = try wire.readInt(self.r()); // dummy result int
    }

    /// Ask the daemon what realizing `derived_paths` would require without
    /// starting any builds or substitutions (`nix-build --dry-run`).
    pub fn queryMissing(self: *DaemonStore, allocator: std.mem.Allocator, derived_paths: []const []const u8) !MissingPlan {
        try self.beginOp(.query_missing);
        try wire.writeStrings(self.w(), derived_paths);
        try self.flushAndDrain();
        var result: MissingPlan = .{
            .allocator = allocator,
            .will_build = try wire.readStrings(allocator, self.r()),
            .will_substitute = undefined,
            .unknown = undefined,
            .download_size = 0,
            .nar_size = 0,
        };
        errdefer MissingPlan.freeStrings(allocator, result.will_build);
        result.will_substitute = try wire.readStrings(allocator, self.r());
        errdefer MissingPlan.freeStrings(allocator, result.will_substitute);
        result.unknown = try wire.readStrings(allocator, self.r());
        errdefer MissingPlan.freeStrings(allocator, result.unknown);
        result.download_size = try wire.readInt(self.r());
        result.nar_size = try wire.readInt(self.r());
        return result;
    }

    /// Register an indirect GC root (`add_indirect_root`, op 12): the daemon
    /// records `<gcroots>/auto/<hash>` -> `link_path`, so the store path the
    /// symlink at `link_path` points to survives GC. `link_path` must be an
    /// existing absolute symlink into the store; the caller creates it first.
    pub fn addIndirectRoot(self: *DaemonStore, link_path: []const u8) !void {
        try self.beginOp(.add_indirect_root);
        try wire.writeString(self.w(), link_path);
        try self.flushAndDrain();
        // The daemon writes a dummy result (1) after the stderr stream;
        // read it, as Nix's RemoteStore does.
        _ = try wire.readInt(self.r());
    }

    /// Send per-connection client settings (`set_options`, op 19). Field order
    /// matches Nix's `RemoteStore::setOptions`: the fixed settings, four obsolete
    /// placeholders, then (protocol minor >= 12) the `name/value` overrides map.
    pub fn setOptions(self: *DaemonStore, s: BuildSettings) !void {
        self.suppress_build_output = s.suppress_build_output;
        try self.beginOp(.set_options);
        const out = self.w();
        try wire.writeBool(out, s.keep_failed);
        try wire.writeBool(out, s.keep_going);
        try wire.writeBool(out, s.fallback);
        try wire.writeInt(out, s.verbosity);
        try wire.writeInt(out, s.max_build_jobs);
        try wire.writeInt(out, s.max_silent_time);
        try wire.writeInt(out, 0); // obsolete useBuildHook
        try wire.writeInt(out, 7); // verboseBuild != lvlError -> quiet build logs
        try wire.writeInt(out, 0); // obsolete logType
        try wire.writeInt(out, 0); // obsolete printBuildTrace
        try wire.writeInt(out, s.build_cores);
        try wire.writeBool(out, s.use_substitutes);
        if (wire.protocolMinor(self.daemon_version) >= 12) {
            try wire.writeInt(out, s.overrides.len);
            for (s.overrides) |o| {
                try wire.writeString(out, o.name);
                try wire.writeString(out, o.value);
            }
        }
        try self.flushAndDrain(); // set_options has no result, just the stderr stream
    }

    // --- op plumbing ------------------------------------------------------

    fn beginOp(self: *DaemonStore, op: wire.Op) !void {
        try wire.writeInt(self.w(), @intFromEnum(op));
    }

    /// Flush the request and drain the STDERR_* sideband up to the response.
    fn flushAndDrain(self: *DaemonStore) !void {
        try self.w().flush();
        try self.processStderr();
    }

    /// Consume the STDERR_* message stream until STDERR_LAST. During builds,
    /// typed activities and actual log records are forwarded while daemon
    /// presentation strings are discarded. A STDERR_ERROR is captured into
    /// `last_error` and surfaced as `error.DaemonError`.
    fn processStderr(self: *DaemonStore) !void {
        while (true) {
            switch (try wire.readInt(self.r())) {
                wire.stderr_last => return,
                wire.stderr_error => return self.readError(),
                wire.stderr_next => {
                    if (self.build_sink == null) {
                        try wire.skipString(self.r());
                        continue;
                    }
                    const line = try wire.readString(self.allocator, self.r());
                    defer self.allocator.free(line);
                    const clean = terminal_text.stripAnsiInPlace(line);
                    self.build_sink.?.emit(.{ .log = .{ .activity_id = null, .kind = .daemon, .text = clean } });
                },
                wire.stderr_start_activity => try self.readStartActivity(),
                wire.stderr_stop_activity => {
                    const act = try wire.readInt(self.r());
                    if (self.build_sink) |s| s.emit(.{ .stop = act });
                },
                wire.stderr_result => try self.readResult(),
                // Legacy non-framed source/sink: not used by the ops we issue.
                wire.stderr_read, wire.stderr_write => return error.UnexpectedStderrStreaming,
                else => return error.UnknownStderrMessage,
            }
        }
    }

    fn readError(self: *DaemonStore) !void {
        // Proto >= 26 Error serialization: type, level, name, msg, havePos,
        // then a trace list. We keep `msg`; everything else is skipped.
        try wire.skipString(self.r()); // type ("Error")
        _ = try wire.readInt(self.r()); // level
        try wire.skipString(self.r()); // name (ignored)
        const raw_msg = try wire.readString(self.allocator, self.r());
        var raw_msg_owned = true;
        errdefer if (raw_msg_owned) self.allocator.free(raw_msg);
        _ = try wire.readInt(self.r()); // havePos (0)
        const n_traces = try wire.readInt(self.r());
        if (n_traces > wire.max_wire_len) return error.WireListTooLong;
        var i: u64 = 0;
        while (i < n_traces) : (i += 1) {
            _ = try wire.readInt(self.r()); // havePos
            try wire.skipString(self.r()); // trace hint
        }
        const msg = try terminal_text.stripAnsiAlloc(self.allocator, raw_msg);
        self.allocator.free(raw_msg);
        raw_msg_owned = false;
        if (self.last_error) |old| self.allocator.free(old);
        self.last_error = msg;
        return error.DaemonError;
    }

    const FieldString = struct {
        allocation: []u8,
        text_len: usize,

        fn text(self: FieldString) []const u8 {
            return self.allocation[0..self.text_len];
        }
    };

    const Fields = struct {
        strings: [4]?FieldString = .{null} ** 4,
        ints: [4]?u64 = .{null} ** 4,

        fn deinit(self: *Fields, allocator: std.mem.Allocator) void {
            for (self.strings) |field| if (field) |value| allocator.free(value.allocation);
            self.* = undefined;
        }

        fn string(self: *const Fields, index: usize) []const u8 {
            return if (self.strings[index]) |value| value.text() else "";
        }

        fn int(self: *const Fields, index: usize) u64 {
            return self.ints[index] orelse 0;
        }
    };

    fn readFields(self: *DaemonStore) !Fields {
        var fields: Fields = .{};
        errdefer fields.deinit(self.allocator);
        const n = try wire.readInt(self.r());
        if (n > wire.max_wire_len) return error.WireListTooLong;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            switch (try wire.readInt(self.r())) {
                0 => {
                    const value = try wire.readInt(self.r());
                    if (i < fields.ints.len) fields.ints[@intCast(i)] = value;
                },
                1 => {
                    if (i >= fields.strings.len) {
                        try wire.skipString(self.r());
                        continue;
                    }
                    const value = try wire.readString(self.allocator, self.r());
                    fields.strings[@intCast(i)] = .{
                        .allocation = value,
                        .text_len = terminal_text.stripAnsiInPlace(value).len,
                    };
                },
                else => return error.UnknownActivityField,
            }
        }
        return fields;
    }

    fn readStartActivity(self: *DaemonStore) !void {
        const act = try wire.readInt(self.r());
        _ = try wire.readInt(self.r()); // level
        const activity_type: ActivityType = @enumFromInt(try wire.readInt(self.r()));
        try wire.skipString(self.r()); // daemon-rendered text; presentation owns labels
        var fields = try self.readFields();
        defer fields.deinit(self.allocator);
        _ = try wire.readInt(self.r()); // parent
        const kind: build_events.ActivityKind = switch (activity_type) {
            .build => .build,
            .substitute => .substitute,
            .post_build_hook => .post_build_hook,
            else => return,
        };
        const subject = fields.string(0);
        if (self.build_sink) |s| if (subject.len != 0) s.emit(.{ .start = .{
            .id = act,
            .kind = kind,
            .subject = subject,
            .detail = fields.string(1),
        } });
    }

    fn readResult(self: *DaemonStore) !void {
        const act = try wire.readInt(self.r());
        const result_type: ResultType = @enumFromInt(try wire.readInt(self.r()));
        var fields = try self.readFields();
        defer fields.deinit(self.allocator);
        switch (result_type) {
            .progress => if (self.build_sink) |s| s.emit(.{ .progress = .{
                .id = act,
                .done = fields.int(0),
                .expected = fields.int(1),
            } }),
            .build_log_line, .post_build_log_line => {
                if (self.suppress_build_output) return;
                const line = fields.string(0);
                if (self.build_sink) |s| {
                    s.emit(.{ .log = .{
                        .activity_id = act,
                        .kind = if (result_type == .build_log_line) .build else .post_build,
                        .text = line,
                    } });
                }
            },
            else => {},
        }
    }
};
