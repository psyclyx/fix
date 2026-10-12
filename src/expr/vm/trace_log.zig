//! Per-opcode execution tracing for the VM.
//!
//! When enabled at compile time (`-Dvm-trace=true`) and at runtime
//! (`--vm-trace`), the dispatch loop emits a structured event for every
//! opcode and every frame-stack transition. The sink writes either a
//! human-readable text log or a binary log used by `fix trace replay`.
//!
//! Multi-threaded: each event includes the worker id and the writer is
//! protected by a spin mutex so events are line-atomic.

const std = @import("std");
const build_options = @import("build_options");
const types = @import("runtime").types;
const bytecode = @import("../bytecode.zig");
const sync = @import("base").sync;

const OpCode = bytecode.OpCode;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;

pub const enabled = build_options.vm_trace;

pub const EventKind = enum(u8) {
    op = 0,
    frame_push = 1,
    frame_pop = 2,
    force_enter = 3,
    force_exit = 4,
};

pub const Format = enum {
    text,
    binary,
};

pub const VmTrace = struct {
    writer: *std.Io.Writer,
    format: Format,
    mu: sync.SpinMutex = .{},
    /// Monotonic event counter — useful as a search anchor in diffs.
    seq: std.atomic.Value(u64) = .init(0),
    /// Skip events beyond this count; 0 means unlimited. Useful for very
    /// long programs where the first few million events are what matters.
    max_events: u64 = 0,
    /// Truncate when the limit hits — the next attempted record returns
    /// without writing.
    truncated: std.atomic.Value(bool) = .init(false),
    /// If true, only events from worker_id == 0 (main) are recorded.
    /// Lets you diff a single-worker run against a multi-worker run as
    /// if they were both single-threaded — useful for finding whether
    /// main's bytecode dispatch *itself* diverges between scheduler
    /// configurations (it shouldn't if speculation is semantically
    /// invisible).
    main_only: bool = false,

    pub fn init(writer: *std.Io.Writer, format: Format) VmTrace {
        return .{ .writer = writer, .format = format };
    }

    pub fn setMaxEvents(self: *VmTrace, n: u64) void {
        self.max_events = n;
    }

    pub fn setMainOnly(self: *VmTrace, v: bool) void {
        self.main_only = v;
    }

    inline fn beginEvent(self: *VmTrace, worker_id: u8) ?u64 {
        if (self.main_only and worker_id != 0) return null;
        const seq = self.seq.fetchAdd(1, .monotonic);
        if (self.max_events != 0 and seq >= self.max_events) {
            self.truncated.store(true, .monotonic);
            return null;
        }
        return seq;
    }

    pub fn flush(self: *VmTrace) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.writer.flush();
    }

    pub fn recordOp(
        self: *VmTrace,
        worker_id: u8,
        frames_len: u32,
        chunk_id: ChunkId,
        ip: u32,
        opc: OpCode,
        sp: u32,
    ) void {
        const seq = self.beginEvent(worker_id) orelse return;
        self.mu.lock();
        defer self.mu.unlock();
        switch (self.format) {
            .text => self.writer.print("{d:>10} op w{d} d{d} c{d} ip={x:0>4} {s} sp={d}\n", .{
                seq, worker_id, frames_len, chunk_id, ip, @tagName(opc), sp,
            }) catch {},
            .binary => self.writeBinaryOp(seq, worker_id, frames_len, chunk_id, ip, opc, sp),
        }
    }

    pub fn recordFramePush(
        self: *VmTrace,
        worker_id: u8,
        frames_len: u32,
        chunk_id: ChunkId,
        frame_base: u32,
    ) void {
        const seq = self.beginEvent(worker_id) orelse return;
        self.mu.lock();
        defer self.mu.unlock();
        switch (self.format) {
            .text => self.writer.print("{d:>10} push  w{d} d{d} c{d} base={d}\n", .{
                seq, worker_id, frames_len, chunk_id, frame_base,
            }) catch {},
            .binary => self.writeBinaryFrame(seq, .frame_push, worker_id, frames_len, chunk_id, frame_base),
        }
    }

    pub fn recordFramePop(
        self: *VmTrace,
        worker_id: u8,
        frames_len: u32,
        returning_to_chunk: ChunkId,
        returning_to_ip: u32,
    ) void {
        const seq = self.beginEvent(worker_id) orelse return;
        self.mu.lock();
        defer self.mu.unlock();
        switch (self.format) {
            .text => self.writer.print("{d:>10} pop   w{d} d{d} ret c{d}@{x:0>4}\n", .{
                seq, worker_id, frames_len, returning_to_chunk, returning_to_ip,
            }) catch {},
            .binary => self.writeBinaryFrame(seq, .frame_pop, worker_id, frames_len, returning_to_chunk, returning_to_ip),
        }
    }

    pub fn recordForceEnter(self: *VmTrace, worker_id: u8, thunk_id: ObjectId) void {
        const seq = self.beginEvent(worker_id) orelse return;
        self.mu.lock();
        defer self.mu.unlock();
        switch (self.format) {
            .text => self.writer.print("{d:>10} force w{d} thunk #{d} enter\n", .{ seq, worker_id, thunk_id }) catch {},
            .binary => self.writeBinaryForce(seq, .force_enter, worker_id, thunk_id, true),
        }
    }

    pub fn recordForceExit(self: *VmTrace, worker_id: u8, thunk_id: ObjectId, success: bool) void {
        const seq = self.beginEvent(worker_id) orelse return;
        self.mu.lock();
        defer self.mu.unlock();
        switch (self.format) {
            .text => self.writer.print("{d:>10} force w{d} thunk #{d} exit {s}\n", .{
                seq, worker_id, thunk_id, if (success) "ok" else "err",
            }) catch {},
            .binary => self.writeBinaryForce(seq, .force_exit, worker_id, thunk_id, success),
        }
    }

    fn writeBinaryOp(
        self: *VmTrace,
        seq: u64,
        worker_id: u8,
        frames_len: u32,
        chunk_id: ChunkId,
        ip: u32,
        opc: OpCode,
        sp: u32,
    ) void {
        self.writeU8(@backingInt(EventKind.op));
        self.writeU64(seq);
        self.writeU8(worker_id);
        self.writeU32(frames_len);
        self.writeU32(chunk_id);
        self.writeU32(ip);
        self.writeU8(@backingInt(opc));
        self.writeU32(sp);
    }

    fn writeBinaryFrame(
        self: *VmTrace,
        seq: u64,
        kind: EventKind,
        worker_id: u8,
        frames_len: u32,
        chunk_id: ChunkId,
        extra: u32,
    ) void {
        self.writeU8(@backingInt(kind));
        self.writeU64(seq);
        self.writeU8(worker_id);
        self.writeU32(frames_len);
        self.writeU32(chunk_id);
        self.writeU32(extra);
    }

    fn writeBinaryForce(self: *VmTrace, seq: u64, kind: EventKind, worker_id: u8, thunk_id: ObjectId, ok: bool) void {
        self.writeU8(@backingInt(kind));
        self.writeU64(seq);
        self.writeU8(worker_id);
        self.writeU32(thunk_id);
        self.writeU8(if (ok) 1 else 0);
    }

    inline fn writeU8(self: *VmTrace, v: u8) void {
        self.writer.writeByte(v) catch {};
    }
    inline fn writeU32(self: *VmTrace, v: u32) void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .little);
        self.writer.writeAll(&buf) catch {};
    }
    inline fn writeU64(self: *VmTrace, v: u64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        self.writer.writeAll(&buf) catch {};
    }
};

/// Inline hooks used by the dispatch loop. When `enabled` is false (the
/// default in release builds), each call compiles to nothing. When the
/// runtime sink is null, the hook does nothing either.
pub inline fn op(
    sink: ?*VmTrace,
    worker_id: u8,
    frames_len: u32,
    chunk_id: ChunkId,
    ip: u32,
    opc: OpCode,
    sp: u32,
) void {
    if (comptime !enabled) return;
    if (sink) |t| t.recordOp(worker_id, frames_len, chunk_id, ip, opc, sp);
}

pub inline fn framePush(sink: ?*VmTrace, worker_id: u8, frames_len: u32, chunk_id: ChunkId, frame_base: u32) void {
    if (comptime !enabled) return;
    if (sink) |t| t.recordFramePush(worker_id, frames_len, chunk_id, frame_base);
}

pub inline fn framePop(sink: ?*VmTrace, worker_id: u8, frames_len: u32, returning_to_chunk: ChunkId, returning_to_ip: u32) void {
    if (comptime !enabled) return;
    if (sink) |t| t.recordFramePop(worker_id, frames_len, returning_to_chunk, returning_to_ip);
}

pub inline fn forceEnter(sink: ?*VmTrace, worker_id: u8, thunk_id: ObjectId) void {
    if (comptime !enabled) return;
    if (sink) |t| t.recordForceEnter(worker_id, thunk_id);
}

pub inline fn forceExit(sink: ?*VmTrace, worker_id: u8, thunk_id: ObjectId, ok: bool) void {
    if (comptime !enabled) return;
    if (sink) |t| t.recordForceExit(worker_id, thunk_id, ok);
}
