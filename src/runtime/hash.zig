//! Nix hash builtins over byte slices.

const std = @import("std");

pub fn hashBytes(allocator: std.mem.Allocator, algorithm: []const u8, bytes: []const u8) ![]u8 {
    if (std.mem.eql(u8, algorithm, "md5")) return hexDigest(allocator, std.crypto.hash.Md5, bytes);
    if (std.mem.eql(u8, algorithm, "sha1")) return hexDigest(allocator, std.crypto.hash.Sha1, bytes);
    if (std.mem.eql(u8, algorithm, "sha256")) return hexDigest(allocator, std.crypto.hash.sha2.Sha256, bytes);
    if (std.mem.eql(u8, algorithm, "sha512")) return hexDigest(allocator, std.crypto.hash.sha2.Sha512, bytes);
    return error.UnsupportedHashAlgorithm;
}

pub fn hashBytesNixBase32(allocator: std.mem.Allocator, algorithm: []const u8, bytes: []const u8) ![]u8 {
    if (std.mem.eql(u8, algorithm, "md5")) return nixBase32Digest(allocator, std.crypto.hash.Md5, bytes);
    if (std.mem.eql(u8, algorithm, "sha1")) return nixBase32Digest(allocator, std.crypto.hash.Sha1, bytes);
    if (std.mem.eql(u8, algorithm, "sha256")) return nixBase32Digest(allocator, std.crypto.hash.sha2.Sha256, bytes);
    if (std.mem.eql(u8, algorithm, "sha512")) return nixBase32Digest(allocator, std.crypto.hash.sha2.Sha512, bytes);
    return error.UnsupportedHashAlgorithm;
}

pub const Algorithm = enum {
    md5,
    sha1,
    sha256,
    sha512,

    pub fn digestLength(self: Algorithm) usize {
        return switch (self) {
            .md5 => 16,
            .sha1 => 20,
            .sha256 => 32,
            .sha512 => 64,
        };
    }
};

/// How a hash is written: Nix's `HashFormat`.
pub const Format = enum {
    base16,
    nix32,
    base64,
    sri,

    /// Nix's `parseHashFormat`, with `base32` for `nix32`.
    pub fn parse(name: []const u8) ?Format {
        if (std.mem.eql(u8, name, "base32")) return .nix32;
        return std.meta.stringToEnum(Format, name);
    }
};

pub const Digest = struct {
    algorithm: Algorithm,
    bytes: [64]u8,

    pub fn slice(self: *const Digest) []const u8 {
        return self.bytes[0..self.algorithm.digestLength()];
    }
};

pub const ParseError = error{ InvalidHash, UnknownHashAlgorithm, HashAlgorithmMismatch, MissingHashAlgorithm };

/// Nix's `Hash::parseAny`: `algo:rest` or SRI `algo-base64`, or a bare
/// hash of `algorithm`. Without SRI, the length tells base-16, nix32 and
/// (padded) base-64 apart.
pub fn parseAny(text: []const u8, algorithm: ?Algorithm) ParseError!Digest {
    var rest = text;
    var sri = false;
    var parsed_algorithm: ?Algorithm = null;
    const separator = std.mem.indexOfScalar(u8, text, ':') orelse sep: {
        const dash = std.mem.indexOfScalar(u8, text, '-');
        sri = dash != null;
        break :sep dash;
    };
    if (separator) |i| {
        parsed_algorithm = std.meta.stringToEnum(Algorithm, text[0..i]) orelse return error.UnknownHashAlgorithm;
        rest = text[i + 1 ..];
    }
    if (parsed_algorithm != null and algorithm != null and parsed_algorithm.? != algorithm.?) return error.HashAlgorithmMismatch;
    const algo = parsed_algorithm orelse algorithm orelse return error.MissingHashAlgorithm;

    var digest: Digest = .{ .algorithm = algo, .bytes = @splat(0) };
    const size = algo.digestLength();
    const out = digest.bytes[0..size];
    if (sri) {
        try decodeBase64(rest, out);
    } else if (rest.len == 2 * size) {
        for (out, 0..) |*byte, i| byte.* = std.fmt.parseInt(u8, rest[2 * i .. 2 * i + 2], 16) catch return error.InvalidHash;
    } else if (rest.len == (size * 8 - 1) / 5 + 1) {
        try decodeNix32(rest, out);
    } else if (rest.len == (4 * size / 3 + 3) & ~@as(usize, 3)) {
        try decodeBase64(rest, out);
    } else return error.InvalidHash;
    return digest;
}

/// `digest` written in `format`; only SRI names the algorithm.
pub fn format(allocator: std.mem.Allocator, digest: Digest, fmt: Format) ![]u8 {
    const bytes = digest.slice();
    return switch (fmt) {
        .base16 => base16: {
            const hex = std.fmt.bytesToHex(digest.bytes, .lower);
            break :base16 allocator.dupe(u8, hex[0 .. 2 * bytes.len]);
        },
        .nix32 => nixBase32(allocator, bytes),
        .base64 => base64Alloc(allocator, "", bytes),
        .sri => base64Alloc(allocator, @tagName(digest.algorithm), bytes),
    };
}

fn base64Alloc(allocator: std.mem.Allocator, prefix: []const u8, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const dash: usize = @intFromBool(prefix.len != 0);
    const out = try allocator.alloc(u8, prefix.len + dash + encoder.calcSize(bytes.len));
    @memcpy(out[0..prefix.len], prefix);
    if (dash != 0) out[prefix.len] = '-';
    _ = encoder.encode(out[prefix.len + dash ..], bytes);
    return out;
}

/// Nix's lenient base-64: stops at `=`, skips newlines.
fn decodeBase64(text: []const u8, out: []u8) ParseError!void {
    var acc: u32 = 0;
    var bits: u5 = 0;
    var n: usize = 0;
    for (text) |c| {
        if (c == '=') break;
        if (c == '\n') continue;
        const value: u32 = switch (c) {
            'A'...'Z' => c - 'A',
            'a'...'z' => 26 + c - 'a',
            '0'...'9' => 52 + c - '0',
            '+' => 62,
            '/' => 63,
            else => return error.InvalidHash,
        };
        acc = (acc << 6) | value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (n == out.len) return error.InvalidHash;
            out[n] = @truncate(acc >> bits);
            n += 1;
        }
    }
    if (n != out.len) return error.InvalidHash;
}

/// Nix's `BaseNix32::decode`: the last character holds the lowest bits.
fn decodeNix32(text: []const u8, out: []u8) ParseError!void {
    const alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
    @memset(out, 0);
    for (0..text.len) |n| {
        const c = text[text.len - n - 1];
        const digit: u16 = @intCast(std.mem.indexOfScalar(u8, alphabet, c) orelse return error.InvalidHash);
        const b = n * 5;
        const i = b / 8;
        const j: u4 = @intCast(b % 8);
        if (i >= out.len) {
            if (digit != 0) return error.InvalidHash;
            continue;
        }
        out[i] |= @truncate(digit << j);
        const carry = digit >> (8 - j);
        if (i + 1 < out.len) {
            out[i + 1] |= @truncate(carry);
        } else if (carry != 0) return error.InvalidHash;
    }
}

fn hexDigest(allocator: std.mem.Allocator, comptime Hash: type, bytes: []const u8) ![]u8 {
    var digest: [Hash.digest_length]u8 = undefined;
    Hash.hash(bytes, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn nixBase32Digest(allocator: std.mem.Allocator, comptime Hash: type, bytes: []const u8) ![]u8 {
    var digest: [Hash.digest_length]u8 = undefined;
    Hash.hash(bytes, &digest, .{});
    return nixBase32(allocator, &digest);
}

fn nixBase32(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
    const encoded_len = (bytes.len * 8 + 4) / 5;
    const encoded = try allocator.alloc(u8, encoded_len);
    for (0..encoded.len) |n| {
        const bit = n * 5;
        const byte_index = bit / 8;
        const bit_index: u3 = @intCast(bit % 8);
        var value: u16 = bytes[byte_index] >> bit_index;
        if (byte_index + 1 < bytes.len) {
            const next_shift: u4 = 8 - @as(u4, bit_index);
            value |= @as(u16, bytes[byte_index + 1]) << next_shift;
        }
        encoded[encoded.len - n - 1] = alphabet[@as(usize, value & 0x1f)];
    }
    return encoded;
}

test "hashBytes matches Nix's flat hex encoding" {
    const sha256 = try hashBytes(std.testing.allocator, "sha256", "abc");
    defer std.testing.allocator.free(sha256);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha256);
}

test "hashBytesNixBase32 matches Nix's base32 encoding" {
    const sha256 = try hashBytesNixBase32(std.testing.allocator, "sha256", "nix-output:out");
    defer std.testing.allocator.free(sha256);
    try std.testing.expectEqualStrings("1rz4g4znpzjwh1xymhjpm42vipw92pr73vdgl6xs1hycac8kf2n9", sha256);
}

test "parseAny and format convert between Nix's hash formats" {
    const a = std.testing.allocator;
    const hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const forms = [_][]const u8{
        hex,
        "sha256:" ++ hex,
        "sha256:1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s",
        "1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s",
        "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=",
        "sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=",
        "sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0",
    };
    for (forms) |text| {
        const digest = try parseAny(text, .sha256);
        const base16 = try format(a, digest, .base16);
        defer a.free(base16);
        try std.testing.expectEqualStrings(hex, base16);
        const sri = try format(a, digest, .sri);
        defer a.free(sri);
        try std.testing.expectEqualStrings("sha256-ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=", sri);
        const nix32 = try format(a, digest, .nix32);
        defer a.free(nix32);
        try std.testing.expectEqualStrings("1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s", nix32);
    }
    try std.testing.expectError(error.MissingHashAlgorithm, parseAny(hex, null));
    try std.testing.expectError(error.HashAlgorithmMismatch, parseAny("sha1:" ++ hex, .sha256));
    try std.testing.expectError(error.InvalidHash, parseAny(hex[1..], .sha256));
    try std.testing.expectError(error.UnknownHashAlgorithm, parseAny("sha3:" ++ hex, null));
}
