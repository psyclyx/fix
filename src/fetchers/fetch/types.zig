//! Public value types for source acquisition.

const std = @import("std");
const forge_mod = @import("../forge.zig");

pub const Forge = forge_mod.Forge;

pub const GitSpec = struct {
    url: []const u8,
    name: []const u8 = "source",
    rev: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    submodules: bool = false,
    all_refs: bool = false,
};

pub const UrlSpec = struct {
    url: []const u8,
    name: []const u8,
    forge: ?Forge = null,
    auth_url: ?[]const u8 = null,
};

pub const TarballSpec = struct {
    url: []const u8,
    name: []const u8 = "source",
    forge: ?Forge = null,
    metadata_url: ?[]const u8 = null,
    metadata_ref: ?[]const u8 = null,
    metadata_head_url: ?[]const u8 = null,
    resolved_rev: ?[]const u8 = null,
    resolved_url_template: ?[]const u8 = null,
    serialize_nar: bool = false,
};

pub const MercurialSpec = struct {
    url: []const u8,
    name: []const u8 = "source",
    rev: ?[]const u8 = null,
};

pub const Reporter = struct {
    ctx: *anyopaque,
    report: *const fn (ctx: *anyopaque, downloaded: u64, total: u64) void,

    pub fn emit(self: ?Reporter, downloaded: u64, total: u64) void {
        if (self) |reporter| reporter.report(reporter.ctx, downloaded, total);
    }
};

pub const UrlResult = struct {
    path: []u8,
    hash: []u8,
    cached: bool = false,

    pub fn deinit(self: UrlResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.hash);
    }
};

pub const TarballNar = struct {
    bytes: []u8,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8,
};

pub const ForgeMetadata = struct {
    rev: []u8,
    last_modified: i64,
    last_modified_date: []u8,

    pub fn deinit(self: ForgeMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.rev);
        allocator.free(self.last_modified_date);
    }
};

pub const TarballResult = struct {
    path: []u8,
    nar_payload: ?TarballNar,
    forge_metadata: ?ForgeMetadata,
    cached: bool = false,

    pub fn deinit(self: TarballResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.nar_payload) |payload| allocator.free(payload.bytes);
        if (self.forge_metadata) |metadata| metadata.deinit(allocator);
    }
};

pub const GitResult = struct {
    out_path: []u8,
    rev: []u8,
    short_rev: []u8,
    rev_count: i64,
    last_modified: i64,
    last_modified_date: []u8,
    submodules: bool,

    pub fn deinit(self: GitResult, allocator: std.mem.Allocator) void {
        allocator.free(self.out_path);
        allocator.free(self.rev);
        allocator.free(self.short_rev);
        allocator.free(self.last_modified_date);
    }
};

pub const MercurialResult = struct {
    out_path: []u8,
    rev: []u8,
    short_rev: []u8,

    pub fn deinit(self: MercurialResult, allocator: std.mem.Allocator) void {
        allocator.free(self.out_path);
        allocator.free(self.rev);
        allocator.free(self.short_rev);
    }
};
