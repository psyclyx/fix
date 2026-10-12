//! Nix hash encoding/decoding: SHA-256 digests, the Nix base-32 alphabet,
//! loose base-64, and hex conversion.
//!
//! Independent of store-path assembly (`paths.zig`, which consumes
//! `sha256Hex`/`storeDigest` from here). Everything here is pure
//! bytes-in/bytes-out with no derivation-domain knowledge.

const std = @import("std");

pub fn hashToBase16(allocator: std.mem.Allocator, expected_algo: []const u8, text: []const u8) ![]u8 {
    var prefixed_sri = false;
    const body = if (hashAlgorithmSeparator(text)) |separator| blk: {
        const algo = text[0..separator];
        if (!std.mem.eql(u8, algo, expected_algo)) return error.InvalidHashAlgorithm;
        prefixed_sri = text[separator] == '-';
        break :blk text[separator + 1 ..];
    } else text;

    const hex = try decodeToHex(allocator, body, prefixed_sri);
    // A decoded hash must have exactly the algorithm's digest length; e.g.
    // `sha256-00` decodes to one byte and is not a valid sha256 hash.
    if (digestBytes(expected_algo)) |n| {
        if (hex.len != n * 2) {
            allocator.free(hex);
            return error.InvalidHash;
        }
    }
    return hex;
}

fn decodeToHex(allocator: std.mem.Allocator, body: []const u8, prefixed_sri: bool) ![]u8 {
    if (prefixed_sri) {
        const bytes = try base64LooseDecode(allocator, body);
        defer allocator.free(bytes);
        return bytesToHexAlloc(allocator, bytes);
    }
    if (isHex(body)) return allocator.dupe(u8, body);
    if (std.mem.indexOfScalar(u8, body, '=') != null or std.mem.indexOfScalar(u8, body, '+') != null or std.mem.indexOfScalar(u8, body, '/') != null) {
        const bytes = try base64LooseDecode(allocator, body);
        defer allocator.free(bytes);
        return bytesToHexAlloc(allocator, bytes);
    }
    const bytes = try nixBase32Decode(allocator, body);
    defer allocator.free(bytes);
    return bytesToHexAlloc(allocator, bytes);
}

/// Digest length in bytes for a Nix hash algorithm name.
fn digestBytes(algo: []const u8) ?usize {
    if (std.mem.eql(u8, algo, "md5")) return 16;
    if (std.mem.eql(u8, algo, "sha1")) return 20;
    if (std.mem.eql(u8, algo, "sha256")) return 32;
    if (std.mem.eql(u8, algo, "sha512")) return 64;
    return null;
}

fn bytesToHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        const encoded = std.fmt.bytesToHex([_]u8{byte}, .lower);
        out[index * 2] = encoded[0];
        out[index * 2 + 1] = encoded[1];
    }
    return out;
}

fn base64LooseDecode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var acc: u32 = 0;
    var bits: u5 = 0;
    for (text) |char| {
        if (char == '=') break;
        const value = base64Value(char) orelse return error.InvalidHash;
        acc = (acc << 6) | value;
        bits += 6;
        while (bits >= 8) {
            bits -= 8;
            try out.append(allocator, @intCast((acc >> bits) & 0xff));
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn hashAlgorithmSeparator(text: []const u8) ?usize {
    const dash = std.mem.indexOfScalar(u8, text, '-');
    const colon = std.mem.indexOfScalar(u8, text, ':');
    if (dash == null) return colon;
    if (colon == null) return dash;
    return @min(dash.?, colon.?);
}

fn base64Value(char: u8) ?u32 {
    if (char >= 'A' and char <= 'Z') return char - 'A';
    if (char >= 'a' and char <= 'z') return 26 + char - 'a';
    if (char >= '0' and char <= '9') return 52 + char - '0';
    if (char == '+') return 62;
    if (char == '/') return 63;
    return null;
}

fn isHex(text: []const u8) bool {
    if (text.len == 0 or text.len % 2 != 0) return false;
    for (text) |char| {
        if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

pub fn storeDigest(fingerprint: []const u8) [32]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    @import("base").sha256.Sha256.hash(fingerprint, &digest, .{});
    return nixBase32(compressDigest(&digest));
}

pub fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    @import("base").sha256.Sha256.hash(bytes, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

fn compressDigest(digest: []const u8) [20]u8 {
    var compressed: [20]u8 = @splat(0);
    for (digest, 0..) |byte, index| compressed[index % compressed.len] ^= byte;
    return compressed;
}

fn nixBase32(bytes: [20]u8) [32]u8 {
    const alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
    var encoded: [32]u8 = undefined;
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

fn nixBase32Decode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const byte_len = text.len * 5 / 8;
    const bytes = try allocator.alloc(u8, byte_len);
    @memset(bytes, 0);
    errdefer allocator.free(bytes);

    for (text, 0..) |char, n| {
        const value = nixBase32Value(char) orelse return error.InvalidHash;
        const bit = (text.len - n - 1) * 5;
        const byte_index = bit / 8;
        // A malformed-length input can place the leading character's bits
        // past the end of the truncated `byte_len` buffer; that's an invalid
        // encoding, not a crash.
        if (byte_index >= bytes.len) return error.InvalidHash;
        const bit_index: u3 = @intCast(bit % 8);
        bytes[byte_index] |= value << bit_index;
        if (byte_index + 1 < bytes.len and bit_index > 3) {
            const shift: u3 = @intCast(8 - @as(u4, bit_index));
            bytes[byte_index + 1] |= value >> shift;
        }
    }
    return bytes;
}

fn nixBase32Value(char: u8) ?u8 {
    const alphabet = "0123456789abcdfghijklmnpqrsvwxyz";
    return @intCast(std.mem.indexOfScalar(u8, alphabet, char) orelse return null);
}

test "nixBase32 round-trips through nixBase32Decode" {
    const original = [_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
        0x00, 0xff, 0x7f, 0x80,
    };
    const encoded = nixBase32(original);
    try std.testing.expectEqual(@as(usize, 32), encoded.len);
    for (encoded) |char| {
        try std.testing.expect(std.mem.indexOfScalar(u8, "0123456789abcdfghijklmnpqrsvwxyz", char) != null);
    }

    const decoded = try nixBase32Decode(std.testing.allocator, &encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &original, decoded);
}

test "nixBase32 all-zero input encodes to all-zero alphabet symbol" {
    const zero: [20]u8 = @splat(0);
    const encoded = nixBase32(zero);
    for (encoded) |char| try std.testing.expectEqual(@as(u8, '0'), char);

    const decoded = try nixBase32Decode(std.testing.allocator, &encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &zero, decoded);
}

test "nixBase32Decode rejects characters outside the alphabet" {
    try std.testing.expectError(error.InvalidHash, nixBase32Decode(std.testing.allocator, "0000000000000000000000000000e1"));
}
