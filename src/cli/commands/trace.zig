//! `fix trace` — work with binary VM trace files.
//!
//! Subcommands:
//!   diff  A B    walk two traces in lockstep, report first divergence
//!   dump  PATH   pretty-print a binary trace as the text format
//!
//! Binary trace format is defined in src/expr/vm/trace_log.zig and emitted
//! by `--vm-trace --vm-trace-format=binary`.

const std = @import("std");
const engine = @import("expr");
const presentation = @import("../presentation.zig");
const render = @import("../render.zig");
const bytecode = engine.bytecode;
const trace_log = engine.vm.trace_log;

const OpCode = bytecode.OpCode;
const EventKind = trace_log.EventKind;

const usage =
    \\usage: fix trace <subcommand> [args]
    \\
    \\subcommands:
    \\  diff A B    walk two binary trace files in lockstep and report the
    \\              first divergent event (and a few events of context on
    \\              both sides).
    \\  dump PATH   pretty-print a binary trace as text.
    \\
    \\To record a trace:
    \\  fix eval --vm-trace=PATH --vm-trace-format=binary -E EXPR
    \\
;

pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    _ = allocator;
    const sub = args_iter.next() orelse {
        render.usageError(init.io, init.environ_map, "missing subcommand", null, usage);
        return 2;
    };
    if (std.mem.eql(u8, sub, "diff")) {
        const a = args_iter.next() orelse {
            render.usageError(init.io, init.environ_map, "missing first trace file", null, usage);
            return 2;
        };
        const b = args_iter.next() orelse {
            render.usageError(init.io, init.environ_map, "missing second trace file", null, usage);
            return 2;
        };
        return runDiff(init, a, b);
    }
    if (std.mem.eql(u8, sub, "dump")) {
        const path = args_iter.next() orelse {
            render.usageError(init.io, init.environ_map, "missing trace file", null, usage);
            return 2;
        };
        return runDump(init, path);
    }
    if (presentation.isHelpFlag(sub)) {
        presentation.printHelp(init.io, usage);
        return 0;
    }
    render.usageError(init.io, init.environ_map, "unknown subcommand", sub, usage);
    return 2;
}

const Event = union(EventKind) {
    op: struct { seq: u64, worker: u8, frames_len: u32, chunk_id: u32, ip: u32, opcode: u8, sp: u32 },
    frame_push: struct { seq: u64, worker: u8, frames_len: u32, chunk_id: u32, frame_base: u32 },
    frame_pop: struct { seq: u64, worker: u8, frames_len: u32, returning_to_chunk: u32, returning_to_ip: u32 },
    force_enter: struct { seq: u64, worker: u8, thunk_id: u32 },
    force_exit: struct { seq: u64, worker: u8, thunk_id: u32, success: bool },

    fn seq(self: Event) u64 {
        return switch (self) {
            inline else => |payload| payload.seq,
        };
    }

    fn write(self: Event, writer: *std.Io.Writer) !void {
        switch (self) {
            .op => |e| try writer.print("{d:>10} op w{d} d{d} c{d} ip={x:0>4} {s} sp={d}\n", .{ e.seq, e.worker, e.frames_len, e.chunk_id, e.ip, opcodeName(e.opcode), e.sp }),
            .frame_push => |e| try writer.print("{d:>10} push  w{d} d{d} c{d} base={d}\n", .{ e.seq, e.worker, e.frames_len, e.chunk_id, e.frame_base }),
            .frame_pop => |e| try writer.print("{d:>10} pop   w{d} d{d} ret c{d}@{x:0>4}\n", .{ e.seq, e.worker, e.frames_len, e.returning_to_chunk, e.returning_to_ip }),
            .force_enter => |e| try writer.print("{d:>10} force w{d} thunk #{d} enter\n", .{ e.seq, e.worker, e.thunk_id }),
            .force_exit => |e| try writer.print("{d:>10} force w{d} thunk #{d} exit {s}\n", .{ e.seq, e.worker, e.thunk_id, if (e.success) "ok" else "err" }),
        }
    }
};

const Reader = struct {
    data: []const u8,
    cursor: usize = 0,
    path: []const u8,

    pub fn nextEvent(self: *Reader) !?Event {
        if (self.cursor >= self.data.len) return null;
        const kind_byte = self.readU8();
        if (kind_byte > 4) return error.UnknownEventKind;
        const kind: EventKind = @fromBackingInt(@intCast(kind_byte));
        switch (kind) {
            .op => {
                const seq = try self.readU64();
                const worker = try self.readU8Checked();
                const frames_len = try self.readU32();
                const chunk_id = try self.readU32();
                const ip = try self.readU32();
                const opcode = try self.readU8Checked();
                const sp = try self.readU32();
                return Event{ .op = .{ .seq = seq, .worker = worker, .frames_len = frames_len, .chunk_id = chunk_id, .ip = ip, .opcode = opcode, .sp = sp } };
            },
            .frame_push, .frame_pop => {
                const seq = try self.readU64();
                const worker = try self.readU8Checked();
                const frames_len = try self.readU32();
                const chunk_id = try self.readU32();
                const extra = try self.readU32();
                return if (kind == .frame_push)
                    Event{ .frame_push = .{ .seq = seq, .worker = worker, .frames_len = frames_len, .chunk_id = chunk_id, .frame_base = extra } }
                else
                    Event{ .frame_pop = .{ .seq = seq, .worker = worker, .frames_len = frames_len, .returning_to_chunk = chunk_id, .returning_to_ip = extra } };
            },
            .force_enter => {
                const seq = try self.readU64();
                const worker = try self.readU8Checked();
                const thunk_id = try self.readU32();
                _ = try self.readU8Checked(); // success byte is always written, ignored on enter
                return Event{ .force_enter = .{ .seq = seq, .worker = worker, .thunk_id = thunk_id } };
            },
            .force_exit => {
                const seq = try self.readU64();
                const worker = try self.readU8Checked();
                const thunk_id = try self.readU32();
                const success = try self.readU8Checked();
                return Event{ .force_exit = .{ .seq = seq, .worker = worker, .thunk_id = thunk_id, .success = success != 0 } };
            },
        }
    }

    fn readU8(self: *Reader) u8 {
        const v = self.data[self.cursor];
        self.cursor += 1;
        return v;
    }

    fn readU8Checked(self: *Reader) !u8 {
        if (self.cursor >= self.data.len) return error.UnexpectedEnd;
        return self.readU8();
    }

    fn readU32(self: *Reader) !u32 {
        if (self.cursor + 4 > self.data.len) return error.UnexpectedEnd;
        const v = std.mem.readInt(u32, self.data[self.cursor..][0..4], .little);
        self.cursor += 4;
        return v;
    }

    fn readU64(self: *Reader) !u64 {
        if (self.cursor + 8 > self.data.len) return error.UnexpectedEnd;
        const v = std.mem.readInt(u64, self.data[self.cursor..][0..8], .little);
        self.cursor += 8;
        return v;
    }
};

fn runDump(init: std.process.Init, path: []const u8) !u8 {
    const allocator = init.gpa;
    const data = try readFileAll(allocator, init.io, path);
    defer allocator.free(data);
    var reader = Reader{ .data = data, .path = path };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    while (try reader.nextEvent()) |event| {
        try event.write(&stdout.interface);
    }
    try stdout.interface.flush();
    return 0;
}

fn runDiff(init: std.process.Init, path_a: []const u8, path_b: []const u8) !u8 {
    const allocator = init.gpa;
    const data_a = try readFileAll(allocator, init.io, path_a);
    defer allocator.free(data_a);
    const data_b = try readFileAll(allocator, init.io, path_b);
    defer allocator.free(data_b);
    var ra = Reader{ .data = data_a, .path = path_a };
    var rb = Reader{ .data = data_b, .path = path_b };

    // Chunk IDs are assigned in registration order. Under parallel
    // evaluation, helper threads can register chunks in different orders
    // run-to-run, so the same "Nth-newly-seen chunk in trace A" can have
    // a different numeric id in trace B. We translate by canonicalizing
    // each new chunk_id to its first-appearance index so semantically
    // equivalent traces match.
    var canon_a: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
    defer canon_a.deinit(allocator);
    var canon_b: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
    defer canon_b.deinit(allocator);

    // We hold a small ring of recent events from each side so we can
    // print context once a divergence is found.
    const context_line_count: usize = 8;
    var ring_a: [context_line_count]Event = undefined;
    var ring_b: [context_line_count]Event = undefined;
    var ring_a_len: usize = 0;
    var ring_b_len: usize = 0;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const writer = &stdout.interface;

    var step: u64 = 0;
    while (true) {
        const maybe_a = try ra.nextEvent();
        const maybe_b = try rb.nextEvent();
        if (maybe_a == null and maybe_b == null) {
            try writer.print("traces identical ({d} events)\n", .{step});
            try writer.flush();
            return 0;
        }
        if (maybe_a == null) {
            try writer.print("divergence at step {d}: {s} ended early\n", .{ step, path_a });
            try writeRing(writer, ring_a[0..ring_a_len], "a:");
            if (maybe_b) |b| {
                try writer.writeAll("b next: ");
                try b.write(writer);
            }
            try writer.flush();
            return 1;
        }
        if (maybe_b == null) {
            try writer.print("divergence at step {d}: {s} ended early\n", .{ step, path_b });
            try writeRing(writer, ring_b[0..ring_b_len], "b:");
            try writer.writeAll("a next: ");
            try maybe_a.?.write(writer);
            try writer.flush();
            return 1;
        }
        const ea = canonicalize(allocator, maybe_a.?, &canon_a) catch return error.OutOfMemory;
        const eb = canonicalize(allocator, maybe_b.?, &canon_b) catch return error.OutOfMemory;
        if (!eventsEqual(ea, eb)) {
            try writer.print("divergence at step {d}:\n", .{step});
            try writer.writeAll("---- a context ----\n");
            try writeRing(writer, ring_a[0..ring_a_len], "  ");
            try writer.writeAll("  ");
            try ea.write(writer);
            try writer.writeAll("---- b context ----\n");
            try writeRing(writer, ring_b[0..ring_b_len], "  ");
            try writer.writeAll("  ");
            try eb.write(writer);
            try writer.flush();
            return 1;
        }
        appendRing(&ring_a, &ring_a_len, ea);
        appendRing(&ring_b, &ring_b_len, eb);
        step += 1;
    }
}

/// Translate any chunk_id in the event to its first-appearance index in
/// this trace. Same code under either run gets the same canonical id.
fn canonicalize(
    allocator: std.mem.Allocator,
    ev: Event,
    map: *std.AutoArrayHashMapUnmanaged(u32, u32),
) !Event {
    return switch (ev) {
        .op => |e| Event{ .op = .{
            .seq = e.seq,
            .worker = e.worker,
            .frames_len = e.frames_len,
            .chunk_id = try canonId(allocator, map, e.chunk_id),
            .ip = e.ip,
            .opcode = e.opcode,
            .sp = e.sp,
        } },
        .frame_push => |e| Event{ .frame_push = .{
            .seq = e.seq,
            .worker = e.worker,
            .frames_len = e.frames_len,
            .chunk_id = try canonId(allocator, map, e.chunk_id),
            .frame_base = e.frame_base,
        } },
        .frame_pop => |e| Event{ .frame_pop = .{
            .seq = e.seq,
            .worker = e.worker,
            .frames_len = e.frames_len,
            .returning_to_chunk = try canonId(allocator, map, e.returning_to_chunk),
            .returning_to_ip = e.returning_to_ip,
        } },
        else => ev,
    };
}

fn canonId(allocator: std.mem.Allocator, map: *std.AutoArrayHashMapUnmanaged(u32, u32), id: u32) !u32 {
    if (id == std.math.maxInt(u32)) return id; // no_chunk_id sentinel
    const gop = try map.getOrPut(allocator, id);
    if (!gop.found_existing) gop.value_ptr.* = @intCast(map.count() - 1);
    return gop.value_ptr.*;
}

fn appendRing(ring: *[8]Event, len: *usize, ev: Event) void {
    if (len.* < ring.len) {
        ring[len.*] = ev;
        len.* += 1;
        return;
    }
    std.mem.copyForwards(Event, ring[0 .. ring.len - 1], ring[1..]);
    ring[ring.len - 1] = ev;
}

fn writeRing(writer: *std.Io.Writer, ring: []const Event, prefix: []const u8) !void {
    for (ring) |ev| {
        try writer.writeAll(prefix);
        try ev.write(writer);
    }
}

fn opcodeName(byte: u8) []const u8 {
    if (byte >= bytecode.opcode.count) return "?";
    const op: OpCode = @fromBackingInt(@intCast(byte));
    return @tagName(op);
}

fn eventsEqual(a: Event, b: Event) bool {
    if (@as(EventKind, a) != @as(EventKind, b)) return false;
    return switch (a) {
        .op => |pa| {
            const pb = b.op;
            return pa.frames_len == pb.frames_len and pa.chunk_id == pb.chunk_id and pa.ip == pb.ip and pa.opcode == pb.opcode;
        },
        .frame_push => |pa| {
            const pb = b.frame_push;
            return pa.frames_len == pb.frames_len and pa.chunk_id == pb.chunk_id and pa.frame_base == pb.frame_base;
        },
        .frame_pop => |pa| {
            const pb = b.frame_pop;
            return pa.frames_len == pb.frames_len and pa.returning_to_chunk == pb.returning_to_chunk and pa.returning_to_ip == pb.returning_to_ip;
        },
        .force_enter => |pa| pa.thunk_id == b.force_enter.thunk_id,
        .force_exit => |pa| pa.thunk_id == b.force_exit.thunk_id and pa.success == b.force_exit.success,
    };
}

fn readFileAll(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    return try reader.interface.allocRemaining(allocator, .unlimited);
}
