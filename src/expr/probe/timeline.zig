//! Engine-scoped Perfetto recording for structured observations.
//!
//! Compute workers append through cache-local chunk cursors; daemon/client-I/O
//! producers use bounded atomic fallback storage. Flow storage is separate so
//! steal arrows cannot evict spans. Disabled observers never enter this code.

const std = @import("std");
const observ = @import("base").observ;
const clock = @import("base").clock;
const worker_id = @import("base").worker_id;
const InternTable = @import("runtime").intern.InternTable;

const event_chunk_len = 256;
const name_chunk_len = 16 << 10;
// Subject labels + counter/span args share one arena. Desktop NixOS timelines
// burn the old 16 MiB pool in a few seconds (empty `rss_mb` args thereafter).
// 128 MiB keeps full-system evals labeled without growing on the hot path.
const name_capacity = 128 << 20;
const no_chunk = std.math.maxInt(u32);
const full_chunk = no_chunk - 1;

const daemon_tid: u16 = 500;
const io_tid: u16 = 501;
const critical_tid: u16 = 502;

const Kind = enum(u8) { span, instant, counter };

const Text = struct { off: u32 = 0, len: u32 = 0 };

const Event = struct {
    ts_ns: u64,
    dur_ns: u64 = 0,
    tid: u16,
    kind: Kind,
    category: []const u8,
    name: []const u8,
    subject: Text = .{},
    args: Text = .{},
    complete: bool = false,
};

const FlowEvent = struct {
    ts_ns: u64,
    id: u64,
    tid: u16,
    phase: observ.FlowPhase,
    category: []const u8,
    name: []const u8,
};

const Chunk = struct { used: u16 = 0 };
const SlotKind = enum { event, flow };

/// Single-writer compute lane; shared chunks absorb worker imbalance. Padding
/// prevents adjacent workers' hot cursors from sharing a cache line.
const Lane = struct {
    event_chunk: u32 = no_chunk,
    flow_chunk: u32 = no_chunk,
    event_next: u16 = 0,
    flow_next: u16 = 0,
    name_next: u32 = 0,
    name_end: u32 = 0,
    flow_sequence: u64 = 0,
    dropped_events: u64 = 0,
    dropped_flows: u64 = 0,
    dropped_names: u64 = 0,
    name_full: bool = false,
    _cache_separation: [64]u8 = undefined,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    intern: *const InternTable,
    worker_count: usize,
    start_ns: u64,
    source: []const u8 = "",

    lanes: []Lane,

    // Compute chunks occupy the prefix; non-worker atomics use the suffix.
    events: []Event,
    worker_event_cap: usize,
    event_chunks: []Chunk,
    next_event_chunk: std.atomic.Value(usize) = .init(0),
    external_event_len: std.atomic.Value(usize) = .init(0),
    external_dropped_events: std.atomic.Value(u64) = .init(0),

    // Independent flow budget: arrows cannot obscure primary work.
    flows: []FlowEvent,
    flow_chunks: []Chunk,
    next_flow_chunk: std.atomic.Value(usize) = .init(0),
    flows_enabled: bool = true,

    names: []u8,
    name_len: std.atomic.Value(usize) = .init(0),
    external_dropped_names: std.atomic.Value(u64) = .init(0),

    last_sample_ns: std.atomic.Value(u64) = .init(0),
    active: bool = true,

    pub fn init(allocator: std.mem.Allocator, worker_count: usize, event_cap: usize, intern: *const InternTable) !Recorder {
        // Protect 3/4 for primary events; compact flows use the remaining 1/4.
        const flow_cap = event_cap / 4;
        const primary_cap = event_cap - flow_cap;
        const worker_event_cap = chunkedPrefix(primary_cap, event_chunk_len);

        const lanes = try allocator.alloc(Lane, @max(worker_count, 1));
        errdefer allocator.free(lanes);
        for (lanes) |*lane| lane.* = .{};

        const events = try allocator.alloc(Event, primary_cap);
        errdefer allocator.free(events);
        const event_chunks = try allocator.alloc(Chunk, worker_event_cap / event_chunk_len);
        errdefer allocator.free(event_chunks);
        @memset(event_chunks, .{});

        const flows = try allocator.alloc(FlowEvent, std.mem.alignBackward(usize, flow_cap, event_chunk_len));
        errdefer allocator.free(flows);
        const flow_chunks = try allocator.alloc(Chunk, flows.len / event_chunk_len);
        errdefer allocator.free(flow_chunks);
        @memset(flow_chunks, .{});

        const names = try allocator.alloc(u8, name_capacity);
        return .{
            .allocator = allocator,
            .intern = intern,
            .worker_count = worker_count,
            .start_ns = clock.monotonicNs(),
            .lanes = lanes,
            .events = events,
            .worker_event_cap = worker_event_cap,
            .event_chunks = event_chunks,
            .flows = flows,
            .flow_chunks = flow_chunks,
            .names = names,
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.active = false;
        self.allocator.free(self.lanes);
        self.allocator.free(self.events);
        self.allocator.free(self.event_chunks);
        self.allocator.free(self.flows);
        self.allocator.free(self.flow_chunks);
        self.allocator.free(self.names);
    }

    pub fn setSource(self: *Recorder, source: []const u8) void {
        self.source = source;
    }

    pub fn setFlows(self: *Recorder, enabled: bool) void {
        self.flows_enabled = enabled;
    }

    pub fn begin(self: *Recorder, spec: *const observ.SpanSpec, details: observ.Details, track: observ.Track) usize {
        const index = self.reserveEvent() orelse return 0;
        self.events[index] = .{
            .ts_ns = clock.monotonicNs(),
            .tid = trackId(track),
            .kind = .span,
            .category = spec.category,
            .name = spec.name,
            .subject = self.storeSubject(details.subject),
        };
        return index + 1;
    }

    pub fn finish(self: *Recorder, token: usize, spec: *const observ.SpanSpec, completion: observ.Finish, success: bool) void {
        if (token == 0) return;
        const index = token - 1;
        if (index >= self.events.len) return;
        const now = clock.monotonicNs();
        const event = &self.events[index];
        event.dur_ns = now -| event.ts_ns;
        if (completion.details) |details| event.subject = self.storeSubject(details.subject);
        event.args = self.formatArgs(spec.name, completion.details, completion.metrics, success);
        event.complete = true;
    }

    pub fn update(self: *Recorder, token: usize, spec: *const observ.SpanSpec, metrics: []const observ.Metric) void {
        if (token == 0) return;
        const index = token - 1;
        if (index >= self.events.len) return;
        self.events[index].args = self.formatArgs(spec.name, null, metrics, true);
    }

    pub fn instant(self: *Recorder, spec: *const observ.EventSpec, details: observ.Details, track: observ.Track, metrics: []const observ.Metric) void {
        const index = self.reserveEvent() orelse return;
        self.events[index] = .{
            .ts_ns = clock.monotonicNs(),
            .tid = trackId(track),
            .kind = .instant,
            .category = spec.category,
            .name = spec.name,
            .subject = self.storeSubject(details.subject),
            .args = self.formatArgs(spec.name, details, metrics, true),
            .complete = true,
        };
    }

    pub fn counter(self: *Recorder, spec: *const observ.CounterSpec, track: observ.Track, metrics: []const observ.Metric) void {
        const index = self.reserveEvent() orelse return;
        self.events[index] = .{
            .ts_ns = clock.monotonicNs(),
            .tid = trackId(track),
            .kind = .counter,
            .category = spec.category,
            .name = spec.name,
            .args = self.formatArgs("", null, metrics, true),
            .complete = true,
        };
    }

    pub fn nextFlowId(self: *Recorder) u64 {
        const worker = worker_id.state();
        if (!self.flows_enabled or !self.active or !worker.is_worker or worker.id >= self.lanes.len) return 0;
        const lane = &self.lanes[worker.id];
        const sequence = lane.flow_sequence;
        lane.flow_sequence +%= 1;
        return sequence *% self.lanes.len + worker.id + 1;
    }

    pub fn flow(self: *Recorder, spec: *const observ.FlowSpec, id: u64, phase: observ.FlowPhase, track: observ.Track, at_ns: u64) void {
        if (id == 0 or !self.flows_enabled) return;
        const index = self.reserveFlow() orelse return;
        self.flows[index] = .{
            .ts_ns = if (at_ns == 0) clock.monotonicNs() else at_ns,
            .id = id,
            .tid = trackId(track),
            .phase = phase,
            .category = spec.category,
            .name = spec.name,
        };
    }

    pub fn shouldSample(self: *Recorder, min_gap_ns: u64) bool {
        const now = clock.monotonicNs();
        const last = self.last_sample_ns.load(.monotonic);
        if (now < last + min_gap_ns) return false;
        return self.last_sample_ns.cmpxchgStrong(last, now, .monotonic, .monotonic) == null;
    }

    inline fn reserveEvent(self: *Recorder) ?usize {
        if (!self.active) return null;
        const worker = worker_id.state();
        if (worker.is_worker and worker.id < self.lanes.len)
            return self.reserveWorkerSlot(&self.lanes[worker.id], .event);
        const offset = self.external_event_len.fetchAdd(1, .monotonic);
        const external_cap = self.events.len - self.worker_event_cap;
        if (offset < external_cap) return self.worker_event_cap + offset;
        _ = self.external_dropped_events.fetchAdd(1, .monotonic);
        return null;
    }

    inline fn reserveFlow(self: *Recorder) ?usize {
        const worker = worker_id.state();
        if (!self.active or !worker.is_worker or worker.id >= self.lanes.len) return null;
        return self.reserveWorkerSlot(&self.lanes[worker.id], .flow);
    }

    inline fn reserveWorkerSlot(self: *Recorder, lane: *Lane, comptime kind: SlotKind) ?usize {
        const chunk = &@field(lane, if (kind == .event) "event_chunk" else "flow_chunk");
        const cursor = &@field(lane, if (kind == .event) "event_next" else "flow_next");
        const drop_count = &@field(lane, if (kind == .event) "dropped_events" else "dropped_flows");
        const chunks = if (kind == .event) self.event_chunks else self.flow_chunks;
        const next_chunk = if (kind == .event) &self.next_event_chunk else &self.next_flow_chunk;
        if (chunk.* == full_chunk) {
            drop_count.* += 1;
            return null;
        }
        if (chunk.* == no_chunk or cursor.* == event_chunk_len) {
            const index = next_chunk.fetchAdd(1, .monotonic);
            if (index >= chunks.len) {
                chunk.* = full_chunk;
                drop_count.* += 1;
                return null;
            }
            chunk.* = @intCast(index);
            cursor.* = 0;
        }
        const index = @as(usize, chunk.*) * event_chunk_len + cursor.*;
        cursor.* += 1;
        chunks[chunk.*].used = cursor.*;
        return index;
    }

    fn storeText(self: *Recorder, bytes: []const u8) Text {
        if (bytes.len == 0) return .{};
        const worker = worker_id.state();
        if (worker.is_worker and worker.id < self.lanes.len and bytes.len <= name_chunk_len)
            return self.storeWorkerText(&self.lanes[worker.id], bytes);
        return self.storeExternalText(bytes);
    }

    fn storeWorkerText(self: *Recorder, lane: *Lane, bytes: []const u8) Text {
        if (lane.name_full) {
            lane.dropped_names += 1;
            return .{};
        }
        if (lane.name_next + bytes.len > lane.name_end) {
            const offset = self.name_len.fetchAdd(name_chunk_len, .monotonic);
            if (offset > self.names.len or name_chunk_len > self.names.len - offset) {
                lane.name_full = true;
                lane.dropped_names += 1;
                return .{};
            }
            lane.name_next = @intCast(offset);
            lane.name_end = lane.name_next + name_chunk_len;
        }
        const offset = lane.name_next;
        lane.name_next += @intCast(bytes.len);
        @memcpy(self.names[offset..][0..bytes.len], bytes);
        return .{ .off = offset, .len = @intCast(bytes.len) };
    }

    fn storeExternalText(self: *Recorder, bytes: []const u8) Text {
        const offset = self.name_len.fetchAdd(bytes.len, .monotonic);
        if (offset > self.names.len or bytes.len > self.names.len - offset) {
            _ = self.external_dropped_names.fetchAdd(1, .monotonic);
            return .{};
        }
        @memcpy(self.names[offset..][0..bytes.len], bytes);
        return .{ .off = @intCast(offset), .len = @intCast(bytes.len) };
    }

    fn storeSubject(self: *Recorder, subject: observ.Subject) Text {
        return switch (subject) {
            .none => .{},
            .text, .path, .url => |bytes| self.storeText(bytes),
            .source => |source| blk: {
                if (source.file == 0) break :blk .{};
                const path = self.intern.get(source.file);
                const base = std.fs.path.basename(path);
                const directory = std.fs.path.basename(std.fs.path.dirname(path) orelse "");
                var buffer: [512]u8 = undefined;
                const label = std.fmt.bufPrint(&buffer, "{s}/{s}:{d}", .{ directory, base, source.line }) catch base;
                break :blk self.storeText(label);
            },
        };
    }

    fn formatArgs(self: *Recorder, operation: []const u8, details: ?observ.Details, metrics: []const observ.Metric, success: bool) Text {
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        var any = false;
        if (operation.len != 0) {
            writeFieldName(&writer, "operation", &any) catch return .{};
            writeJsonString(&writer, operation) catch return .{};
        }
        if (details) |value| switch (value.destination) {
            .none, .source => {},
            .text, .path, .url => |destination| {
                writeFieldName(&writer, "destination", &any) catch return .{};
                writeJsonString(&writer, destination) catch return .{};
            },
        };
        for (metrics) |metric| {
            writeFieldName(&writer, metric.name, &any) catch return .{};
            switch (metric.value) {
                .unsigned => |value| writer.print("{d}", .{value}) catch return .{},
                .signed => |value| writer.print("{d}", .{value}) catch return .{},
                .float => |value| writer.print("{d}", .{value}) catch return .{},
                .text => |value| writeJsonString(&writer, value) catch return .{},
            }
        }
        if (!success) {
            writeFieldName(&writer, "success", &any) catch return .{};
            writer.writeAll("false") catch return .{};
        }
        return self.storeText(buffer[0..writer.end]);
    }

    pub fn dump(self: *Recorder, io: std.Io, path: []const u8) void {
        if (!self.active) return;
        self.active = false;
        self.dumpImpl(io, path) catch |err| {
            std.debug.print("timeline: failed to write {s}: {s}\n", .{ path, @errorName(err) });
        };
    }

    fn dumpImpl(self: *Recorder, io: std.Io, path: []const u8) !void {
        const event_count = self.compactEvents();
        const flow_count = self.compactFlows();
        std.mem.sort(Event, self.events[0..event_count], {}, eventLessThan);
        std.mem.sort(FlowEvent, self.flows[0..flow_count], {}, flowLessThan);

        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var file_writer = file.writerStreaming(io, &buffer);
        const writer = &file_writer.interface;
        try writer.writeAll("{\"traceEvents\":[\n");
        var first = true;
        for (0..self.worker_count) |tid| {
            var name_buffer: [64]u8 = undefined;
            const name = if (tid == 0)
                "worker 0 (main / serial path)"
            else
                try std.fmt.bufPrint(&name_buffer, "worker {d}", .{tid});
            try writeThreadMetadata(writer, &first, @intCast(tid), name);
        }
        try writeThreadMetadata(writer, &first, daemon_tid, "Nix daemon activities");
        try writeThreadMetadata(writer, &first, io_tid, "client / asynchronous I/O");
        try writeThreadMetadata(writer, &first, critical_tid, "critical path (demand waits)");

        var event_index: usize = 0;
        var flow_index: usize = 0;
        while (event_index < event_count or flow_index < flow_count) {
            try separator(writer, &first);
            if (flow_index >= flow_count or
                (event_index < event_count and self.events[event_index].ts_ns <= self.flows[flow_index].ts_ns))
            {
                try self.writeEvent(writer, self.events[event_index]);
                event_index += 1;
            } else {
                try self.writeFlow(writer, self.flows[flow_index]);
                flow_index += 1;
            }
        }
        try writer.writeAll("\n],\n\"displayTimeUnit\":\"ns\",\n\"metadata\":{");
        try writer.print("\"tool\":\"fix\",\"workers\":{d},\"start-monotonic-ns\":{d},\"source\":", .{ self.worker_count, self.start_ns });
        try writeJsonString(writer, self.source);
        try writer.writeAll("}\n}\n");
        try writer.flush();

        const dropped_events = self.dropped(self.external_dropped_events.load(.monotonic), "dropped_events");
        const dropped_flows = self.dropped(0, "dropped_flows");
        const dropped_names = self.dropped(self.external_dropped_names.load(.monotonic), "dropped_names");
        std.debug.print("timeline: wrote {d} events ({d} flows) to {s} (open in https://ui.perfetto.dev)\n", .{ event_count + flow_count, flow_count, path });
        if (dropped_events != 0 or dropped_flows != 0 or dropped_names != 0)
            std.debug.print("timeline: dropped {d} events, {d} flows, and {d} names\n", .{ dropped_events, dropped_flows, dropped_names });
    }

    fn compactEvents(self: *Recorder) usize {
        var count = compactWorkerEvents(Event, self.events, self.event_chunks, self.next_event_chunk.load(.monotonic), true);
        const external_count = @min(self.external_event_len.load(.monotonic), self.events.len - self.worker_event_cap);
        for (self.events[self.worker_event_cap..][0..external_count]) |event| {
            if (!event.complete) continue;
            self.events[count] = event;
            count += 1;
        }
        return count;
    }

    fn compactFlows(self: *Recorder) usize {
        return compactWorkerEvents(FlowEvent, self.flows, self.flow_chunks, self.next_flow_chunk.load(.monotonic), false);
    }

    fn dropped(self: *const Recorder, external: u64, comptime field: []const u8) u64 {
        var count = external;
        for (self.lanes) |lane| count += @field(lane, field);
        return count;
    }

    fn writeEvent(self: *Recorder, writer: *std.Io.Writer, event: Event) !void {
        const relative = event.ts_ns -| self.start_ns;
        if (event.kind == .counter) {
            try writer.print("{{\"ph\":\"C\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"cat\":", .{ event.tid, micros(relative) });
            try writeJsonString(writer, event.category);
            try writer.writeAll(",\"name\":");
            try writeJsonString(writer, event.name);
            try writer.print(",\"args\":{{{s}}}}}", .{self.text(event.args)});
            return;
        }
        try writer.print("{{\"ph\":\"{s}\",\"pid\":1,\"tid\":{d},\"ts\":{d:.3}", .{
            if (event.kind == .instant) "i" else "X",
            event.tid,
            micros(relative),
        });
        if (event.kind == .instant)
            try writer.writeAll(",\"s\":\"t\"")
        else
            try writer.print(",\"dur\":{d:.3}", .{micros(event.dur_ns)});
        try writer.writeAll(",\"cat\":");
        try writeJsonString(writer, event.category);
        try writer.writeAll(",\"name\":");
        const subject = self.text(event.subject);
        try writeJsonString(writer, if (subject.len == 0) event.name else subject);
        const args = self.text(event.args);
        if (args.len != 0) try writer.print(",\"args\":{{{s}}}", .{args});
        try writer.writeByte('}');
    }

    fn writeFlow(self: *Recorder, writer: *std.Io.Writer, flow_event: FlowEvent) !void {
        const relative = flow_event.ts_ns -| self.start_ns;
        try writer.print("{{\"ph\":\"{s}\",\"id\":{d},\"pid\":1,\"tid\":{d},\"ts\":{d:.3},\"cat\":", .{
            if (flow_event.phase == .out) "s" else "f",
            flow_event.id,
            flow_event.tid,
            micros(relative),
        });
        try writeJsonString(writer, flow_event.category);
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, flow_event.name);
        if (flow_event.phase == .in) try writer.writeAll(",\"bp\":\"e\"");
        try writer.writeByte('}');
    }

    fn text(self: *const Recorder, stored: Text) []const u8 {
        if (stored.len == 0) return "";
        return self.names[stored.off..][0..stored.len];
    }
};

fn compactWorkerEvents(comptime T: type, items: []T, chunks: []const Chunk, reserved: usize, comptime spans: bool) usize {
    var count: usize = 0;
    for (chunks[0..@min(reserved, chunks.len)], 0..) |chunk, chunk_index| {
        for (items[chunk_index * event_chunk_len ..][0..chunk.used]) |item| {
            if (spans and !item.complete) continue;
            items[count] = item;
            count += 1;
        }
    }
    return count;
}

fn chunkedPrefix(capacity: usize, chunk_len: usize) usize {
    const external = capacity / 8;
    return std.mem.alignBackward(usize, capacity - external, chunk_len);
}

fn eventLessThan(_: void, a: Event, b: Event) bool {
    if (a.ts_ns != b.ts_ns) return a.ts_ns < b.ts_ns;
    return a.dur_ns > b.dur_ns;
}

fn flowLessThan(_: void, a: FlowEvent, b: FlowEvent) bool {
    return a.ts_ns < b.ts_ns;
}

fn trackId(track: observ.Track) u16 {
    return switch (track) {
        .current => {
            const worker = worker_id.state();
            return if (worker.is_worker) worker.id else io_tid;
        },
        .worker => |id| id,
        .fiber => |id| @intCast(@min(id, std.math.maxInt(u16))),
        .activity => |id| @intCast(@min(id, std.math.maxInt(u16))),
        .daemon => daemon_tid,
        .critical => critical_tid,
    };
}

fn writeThreadMetadata(writer: *std.Io.Writer, first: *bool, tid: u16, name: []const u8) !void {
    try separator(writer, first);
    try writer.print("{{\"ph\":\"M\",\"pid\":1,\"tid\":{d},\"name\":\"thread_name\",\"args\":{{\"name\":", .{tid});
    try writeJsonString(writer, name);
    try writer.writeAll("}}");
}

fn separator(writer: *std.Io.Writer, first: *bool) !void {
    if (first.*)
        first.* = false
    else
        try writer.writeAll(",\n");
}

fn writeFieldName(writer: *std.Io.Writer, name: []const u8, any: *bool) !void {
    if (any.*) try writer.writeByte(',');
    any.* = true;
    try writeJsonString(writer, name);
    try writer.writeByte(':');
}

fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    for (bytes) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20)
            try writer.print("\\u{x:0>4}", .{byte})
        else
            try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

test "worker producers refill shared buffers only at chunk boundaries" {
    var intern = try InternTable.init(std.testing.allocator);
    defer intern.deinit();
    var recorder = try Recorder.init(std.testing.allocator, 2, 4096, &intern);
    defer recorder.deinit();

    const previous = worker_id.state();
    defer worker_id.set(previous.id, previous.is_worker);

    worker_id.set(0, true);
    try std.testing.expectEqual(@as(?usize, 0), recorder.reserveEvent());
    try std.testing.expectEqual(@as(?usize, 1), recorder.reserveEvent());
    _ = recorder.storeText("one");
    _ = recorder.storeText("two");
    try std.testing.expectEqual(@as(usize, 1), recorder.next_event_chunk.load(.monotonic));
    try std.testing.expectEqual(@as(usize, name_chunk_len), recorder.name_len.load(.monotonic));

    worker_id.set(1, true);
    try std.testing.expectEqual(@as(?usize, event_chunk_len), recorder.reserveEvent());
    try std.testing.expectEqual(@as(usize, 2), recorder.next_event_chunk.load(.monotonic));

    worker_id.set(1, false);
    try std.testing.expectEqual(@as(?usize, recorder.worker_event_cap), recorder.reserveEvent());
    try std.testing.expectEqual(@as(usize, 1), recorder.external_event_len.load(.monotonic));
}

test "logical tracks keep daemon and client IO off worker zero" {
    const previous = worker_id.state();
    defer worker_id.set(previous.id, previous.is_worker);
    worker_id.set(previous.id, false);

    try std.testing.expectEqual(io_tid, trackId(.current));
    try std.testing.expectEqual(daemon_tid, trackId(.daemon));
    try std.testing.expectEqual(critical_tid, trackId(.critical));
}
