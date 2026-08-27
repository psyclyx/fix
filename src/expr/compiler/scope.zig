//! Compile-time scope management: local-slot declaration and pop, lexical
//! name resolution (by interned id), upvalue capture threading up the
//! parent-compiler chain, and `with`-scope collection + lookup emission.

const std = @import("std");
const compiler_mod = @import("context.zig");
const types = @import("runtime").types;
const emit = @import("emit.zig");

const Compiler = compiler_mod.Compiler;
const Capture = compiler_mod.Capture;
const WithScope = compiler_mod.WithScope;
const with_capture_name = compiler_mod.with_capture_name;
const InternId = types.InternId;

/// Nesting is bounded only so `scope_depth` cannot wrap: a wrapped depth makes
/// `endScope` pop the wrong locals, which miscompiles silently in ReleaseFast
/// rather than failing. The ceiling is set by the counter's width, not by any
/// property of the language — Nix nests scopes arbitrarily deep, so it must sit
/// far above anything a real program reaches.
pub fn beginScope(self: *Compiler) !void {
    if (self.scope_depth == std.math.maxInt(@TypeOf(self.scope_depth))) return error.TooManyScopes;
    self.scope_depth += 1;
}

pub fn endScope(self: *Compiler) void {
    self.scope_depth -= 1;
    // Pop locals defined in this scope.
    while (self.locals.items.len > 0) {
        const local = self.locals.items[self.locals.items.len - 1];
        if (local.depth <= self.scope_depth) break;
        _ = self.locals.pop();
    }
}

pub fn declareLocal(self: *Compiler, name: []const u8, name_id: InternId) !u16 {
    if (self.slot_count == std.math.maxInt(u16)) return error.TooManyLocals;
    const slot = self.slot_count;
    self.slot_count += 1;
    errdefer self.slot_count -= 1;
    try self.locals.append(self.allocator, .{
        .name = name,
        .name_id = name_id,
        .depth = self.scope_depth,
        .slot = slot,
    });
    // Debug-only slot→name record (`capture_names`): slots are monotonic per
    // chunk, so appending in declaration order keeps `local_names[slot]` aligned
    // with `slot`. See `ChunkRegistry.recordLocalNames`.
    if (self.registry.capture_names) try self.local_names.append(self.allocator, name_id);
    return slot;
}

pub fn resolveLocal(self: *const Compiler, name: []const u8) ?u16 {
    var i: usize = self.locals.items.len;
    while (i > 0) {
        i -= 1;
        const local = self.locals.items[i];
        if (self.skip_local_slot) |skip| {
            if (local.slot == skip) continue;
        }
        if (std.mem.eql(u8, local.name, name)) {
            return local.slot;
        }
    }
    return null;
}

pub fn resolveLocalId(self: *const Compiler, name_id: InternId) ?u16 {
    var i: usize = self.locals.items.len;
    while (i > 0) {
        i -= 1;
        const local = self.locals.items[i];
        if (self.skip_local_slot) |skip| {
            if (local.slot == skip) continue;
        }
        if (local.name_id == name_id) return local.slot;
    }
    return null;
}

pub fn resolveCapture(self: *Compiler, name: []const u8) !?u16 {
    return resolveCaptureId(self, name, try self.intern.intern(name));
}

/// Id-based capture resolution: identical to `resolveCapture` but
/// compares interned `name_id`s (u32) up the parent chain instead of
/// re-comparing the source bytes at every level. The `name` slice is
/// still stored on the capture (used by `forwardingUpvalue` and capture
/// descriptors). Hot: every non-local identifier reference walks this.
pub fn resolveCaptureId(self: *Compiler, name: []const u8, name_id: InternId) anyerror!?u16 {
    const parent = self.parent orelse return null;
    if (resolveLocalId(parent, name_id)) |parent_slot| {
        return try addCaptureId(self, name, name_id, .local, parent_slot);
    }
    if (try resolveCaptureId(parent, name, name_id)) |parent_upvalue| {
        return try addCaptureId(self, name, name_id, .upvalue, parent_upvalue);
    }
    return null;
}

pub fn addCapture(self: *Compiler, name: []const u8, kind: Capture.Kind, capture_index: u16) !u16 {
    return addCaptureId(self, name, try self.intern.intern(name), kind, capture_index);
}

pub fn addCaptureId(self: *Compiler, name: []const u8, name_id: InternId, kind: Capture.Kind, capture_index: u16) !u16 {
    for (self.captures.items, 0..) |capture, existing_index| {
        if (capture.kind == kind and capture.index == capture_index and capture.name_id == name_id) {
            return @intCast(existing_index);
        }
    }

    if (self.captures.items.len > std.math.maxInt(u16)) return error.TooManyCaptures;
    try self.captures.append(self.allocator, .{
        .name = name,
        .name_id = name_id,
        .kind = kind,
        .index = capture_index,
    });
    return @intCast(self.captures.items.len - 1);
}

pub fn emitWithLookup(self: *Compiler, name: []const u8) !bool {
    var scopes: std.ArrayListUnmanaged(WithScope) = .empty;
    defer scopes.deinit(self.allocator);

    try collectWithScopes(self, &scopes);
    if (scopes.items.len == 0) return false;
    if (scopes.items.len > std.math.maxInt(u8)) return error.TooManyWithScopes;

    for (scopes.items) |scope| {
        switch (scope.kind) {
            .local => try emit.emitCaptureLocal(self, scope.index),
            .upvalue => try emit.emitOpU16(self, .up_grab, scope.index),
        }
    }

    const name_id = try self.intern.intern(name);
    try emit.emitInternOp(self, .with_lookup, .with_lookup_w, name_id);
    try self.builder.writeByte(self.allocator, @intCast(scopes.items.len));
    return true;
}

pub fn collectWithScopes(self: *Compiler, scopes: *std.ArrayListUnmanaged(WithScope)) !void {
    var i: usize = self.with_scopes.items.len;
    while (i > 0) {
        i -= 1;
        try scopes.append(self.allocator, self.with_scopes.items[i]);
    }

    const parent = self.parent orelse return;
    var parent_scopes: std.ArrayListUnmanaged(WithScope) = .empty;
    defer parent_scopes.deinit(self.allocator);

    try collectWithScopes(parent, &parent_scopes);
    for (parent_scopes.items) |scope| {
        const capture_slot = try addCapture(self, with_capture_name, scope.kind, scope.index);
        try scopes.append(self.allocator, .{ .kind = .upvalue, .index = capture_slot });
    }
}
