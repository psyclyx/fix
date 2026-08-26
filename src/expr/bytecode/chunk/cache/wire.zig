//! Shared wire types and byte-level primitives for the chunk-cache codec.

const std = @import("std");
const runtime = @import("runtime");
const ast = @import("syntax").ast;
const opcode = @import("../../opcode.zig");
const encoding = @import("../../encoding.zig");
const model = @import("../model.zig");
const registry = @import("../registry.zig");
const deferred_table = @import("../../../compiler/deferred_table.zig");
const LanguagePolicy = @import("../../../policy.zig").LanguagePolicy;

pub const format_version: u32 = 6;
pub const checksum_start = 8;
pub const checksum_end = 16;
pub const checksum_seed: u64 = 0xF17C_CACE_B10B;

pub const Error = error{ Uncacheable, Corrupt, Stale, Unfit, OutOfMemory };

pub fn corruptAt(src: std.builtin.SourceLocation) Error {
    if (std.c.getenv("FIX_CC_DEBUG") != null)
        std.debug.print("cache corrupt at {s}:{d}\n", .{ src.fn_name, src.line });
    return error.Corrupt;
}

pub fn wrapErr(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Uncacheable,
    };
}

pub fn readWidth(code: []const u8, at: usize, width: opcode.Width) u32 {
    return switch (width) {
        .b1 => code[at],
        .b2 => encoding.readU16(code, at),
        .b4 => encoding.readU32(code, at),
    };
}

pub fn writeWidth(code: []u8, at: usize, width: opcode.Width, value: u32) void {
    switch (width) {
        .b1 => code[at] = @intCast(value),
        .b2 => {
            code[at] = @truncate(value);
            code[at + 1] = @truncate(value >> 8);
        },
        .b4 => {
            code[at] = @truncate(value);
            code[at + 1] = @truncate(value >> 8);
            code[at + 2] = @truncate(value >> 16);
            code[at + 3] = @truncate(value >> 24);
        },
    }
}

pub const UnitRecord = struct {
    source_path: []const u8,
    chunk_ids: []const runtime.types.ChunkId,
    deferred_ids: []const u32,
};

pub const LoadDeps = struct {
    allocator: std.mem.Allocator,
    registry: *registry.ChunkRegistry,
    intern: *runtime.intern.InternTable,
    heap: *runtime.heap.ObjectHeap,
    deferred: *deferred_table.Table,
    ast_arena: *ast.AstArena,
    source: []const u8,
    base_path: ?[]const u8,
    source_path: ?[]const u8,
    policy: LanguagePolicy,
};

pub const LoadResult = struct {
    top: runtime.types.ChunkId,
    chunk_count: u32,
    deferred_count: u32,
};

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn need(self: *const Reader, n: usize) Error!void {
        if (self.pos > self.bytes.len or n > self.bytes.len - self.pos) return corruptAt(@src());
    }

    pub fn u8_(self: *Reader) Error!u8 {
        try self.need(1);
        const value = self.bytes[self.pos];
        self.pos += 1;
        return value;
    }

    pub fn u16_(self: *Reader) Error!u16 {
        try self.need(2);
        const value = encoding.readU16(self.bytes, self.pos);
        self.pos += 2;
        return value;
    }

    pub fn u32_(self: *Reader) Error!u32 {
        try self.need(4);
        const value = encoding.readU32(self.bytes, self.pos);
        self.pos += 4;
        return value;
    }

    pub fn u64_(self: *Reader) Error!u64 {
        try self.need(8);
        const lo = encoding.readU32(self.bytes, self.pos);
        const hi = encoding.readU32(self.bytes, self.pos + 4);
        self.pos += 8;
        return @as(u64, lo) | (@as(u64, hi) << 32);
    }

    pub fn i64_(self: *Reader) Error!i64 {
        return @bitCast(try self.u64_());
    }

    pub fn bytesN(self: *Reader, n: usize) Error![]const u8 {
        try self.need(n);
        const slice = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }
};

comptime {
    if (std.meta.fields(model.Chunk).len != 14)
        @compileError("Chunk changed shape: update the cache codec and its field guard.");
    if (std.meta.fields(model.SchedulingHints).len != 6)
        @compileError("SchedulingHints changed shape: update the cache codec and its field guard.");
    if (std.meta.fields(model.ChunkStrictness).len != 2)
        @compileError("ChunkStrictness changed shape: update the cache codec and its field guard.");
    if (std.meta.fields(deferred_table.Entry).len != 10)
        @compileError("deferred_table.Entry changed shape: update the cache codec and its field guard.");
}
