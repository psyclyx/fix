//! Store-backend adapter for the Nix worker-protocol client.

const std = @import("std");
const backend = @import("../backend.zig");
const DaemonStore = @import("client.zig").DaemonStore;

pub const vtable: backend.VTable = .{
    .is_valid_path = isValidPath,
    .add_object = addObject,
    .read_file = readFile,
    .build_paths = buildPaths,
    .query_missing = queryMissing,
    .add_indirect_root = addIndirectRoot,
    .last_error = lastError,
};

fn daemon(raw: *anyopaque) *DaemonStore {
    return @ptrCast(@alignCast(raw));
}

fn isValidPath(raw: *anyopaque, path: []const u8) !bool {
    return daemon(raw).isValidPath(path);
}

fn addObject(raw: *anyopaque, allocator: std.mem.Allocator, object: backend.AddObject) ![]u8 {
    const store = daemon(raw);
    return switch (object) {
        .text => |text| store.addTextToStore(allocator, text.name, text.bytes, text.references),
        .nar => |nar| store.addPath(allocator, nar.name, nar.bytes, &.{}),
        .flat => |flat| store.addFlatFile(allocator, flat.name, flat.bytes, &.{}),
    };
}

fn readFile(raw: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return daemon(raw).narFromPath(allocator, path);
}

fn buildPaths(raw: *anyopaque, paths: []const []const u8, sink: ?backend.BuildSink, mode: backend.BuildMode) !void {
    return daemon(raw).buildPaths(paths, sink, mode);
}

fn queryMissing(raw: *anyopaque, allocator: std.mem.Allocator, paths: []const []const u8) !backend.MissingPlan {
    return daemon(raw).queryMissing(allocator, paths);
}

fn addIndirectRoot(raw: *anyopaque, link_path: []const u8, _: []const u8) !void {
    return daemon(raw).addIndirectRoot(link_path);
}

fn lastError(raw: *anyopaque) ?[]const u8 {
    return daemon(raw).last_error;
}
