//! Packed bytecode operands for static and mixed attribute paths.
//!
//! This is AST-aware lowering: it classifies path segments and reports source
//! diagnostics before writing the compact operand. Keeping it out of emit.zig
//! leaves the byte emitter independent of syntax nodes.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const compiler_mod = @import("context.zig");
const attr_names = @import("attr_names.zig");
const diagnostics = @import("diagnostics.zig");
const emit = @import("emit.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;

pub fn isWide(self: *Compiler, segments: []const Node.Atom) !bool {
    var wide = false;
    for (segments) |segment| {
        if (try attr_names.intern(self, segment) > std.math.maxInt(u16)) wide = true;
    }
    return wide;
}

pub fn writeStatic(self: *Compiler, segments: []const Node.Atom, atom: Node.Atom, wide: bool) !void {
    try self.builder.writeByte(self.allocator, try diagnostics.requireU8At(self, segments.len, atom, "attribute path has too many segments"));
    for (segments) |segment| {
        try emit.writeInternId(self, try attr_names.intern(self, segment), wide);
    }
}

pub fn writeMixed(self: *Compiler, segments: []const Node.Atom, dynamic_count: usize, atom: Node.Atom) !void {
    try self.builder.writeByte(self.allocator, try diagnostics.requireU8At(self, segments.len, atom, "attribute path has too many segments"));
    try self.builder.writeByte(self.allocator, try diagnostics.requireU8At(self, dynamic_count, atom, "attribute path has too many dynamic segments"));
    for (segments) |segment| {
        if (attr_names.hasInterpolation(self, segment)) {
            try self.builder.writeByte(self.allocator, @backingInt(bytecode.MixedAttrSegmentTag.dynamic));
        } else {
            try self.builder.writeByte(self.allocator, @backingInt(bytecode.MixedAttrSegmentTag.static));
            try self.builder.writeU32(self.allocator, try attr_names.intern(self, segment));
        }
    }
}

pub fn writeHasAttrMixed(
    self: *Compiler,
    segments: []const Node.HasAttrMixedSegment,
    dynamic_count: usize,
    atom: Node.Atom,
) !void {
    try self.builder.writeByte(self.allocator, try diagnostics.requireU8At(self, segments.len, atom, "attribute path has too many segments"));
    try self.builder.writeByte(self.allocator, try diagnostics.requireU8At(self, dynamic_count, atom, "attribute path has too many dynamic segments"));
    for (segments) |segment| switch (segment) {
        .static => |static_atom| {
            if (attr_names.hasInterpolation(self, static_atom)) {
                try self.builder.writeByte(self.allocator, @backingInt(bytecode.MixedAttrSegmentTag.dynamic));
            } else {
                try self.builder.writeByte(self.allocator, @backingInt(bytecode.MixedAttrSegmentTag.static));
                try self.builder.writeU32(self.allocator, try attr_names.intern(self, static_atom));
            }
        },
        .dynamic => try self.builder.writeByte(self.allocator, @backingInt(bytecode.MixedAttrSegmentTag.dynamic)),
    };
}
