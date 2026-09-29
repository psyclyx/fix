//! Nix version and derivation-name parsing helpers.
//!
//! Ports of `libstore/names.cc`: `splitVersion` and `compareVersions` share
//! Nix's component scanner, so both builtins agree with `nix-env` about
//! where a version's components begin and end.

const std = @import("std");

pub const ParsedDrvName = struct {
    name: []const u8,
    version: []const u8,
};

/// The components of `text`, as `builtins.splitVersion` returns them. The
/// slices borrow `text`.
pub fn splitVersion(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer parts.deinit(allocator);

    var index: usize = 0;
    while (true) {
        const part = nextComponent(text, &index);
        if (part.len == 0) break;
        try parts.append(allocator, part);
    }

    return parts.toOwnedSlice(allocator);
}

pub fn compareVersions(left: []const u8, right: []const u8) i64 {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left.len or right_index < right.len) {
        const left_part = nextComponent(left, &left_index);
        const right_part = nextComponent(right, &right_index);
        if (componentLessThan(left_part, right_part)) return -1;
        if (componentLessThan(right_part, left_part)) return 1;
    }
    return 0;
}

pub fn parseDrvName(text: []const u8) ParsedDrvName {
    // The name is everything before the first `-` that is followed by a
    // character other than a letter; a trailing `-` is part of the name.
    // `name-that-ends-with-dash--1.0` splits at the first of the double dash,
    // giving version "-1.0", and `-1.0` has an empty name.
    for (text, 0..) |c, index| {
        if (c == '-' and index + 1 < text.len and !std.ascii.isAlphabetic(text[index + 1])) {
            return .{
                .name = text[0..index],
                .version = text[index + 1 ..],
            };
        }
    }
    return .{ .name = text, .version = "" };
}

/// Nix's `nextComponent`: skip separators, then take the longest run of
/// digits, or else of characters that are neither digits nor separators
/// (so `_`, other punctuation and non-ASCII bytes stay inside a word).
/// Returns "" at the end of `text`.
fn nextComponent(text: []const u8, index: *usize) []const u8 {
    var i = index.*;
    while (i < text.len and isSeparator(text[i])) i += 1;
    const start = i;
    if (i < text.len) {
        const digits = std.ascii.isDigit(text[i]);
        while (i < text.len and std.ascii.isDigit(text[i]) == digits and !isSeparator(text[i])) i += 1;
    }
    index.* = i;
    return text[start..i];
}

/// Nix's `componentsLT`. A component is a number only if it fits a C `int`,
/// so a run of digits of 2^31 or more compares as a word: before every
/// number, and by bytes against other words.
fn componentLessThan(left: []const u8, right: []const u8) bool {
    const left_number = componentNumber(left);
    const right_number = componentNumber(right);
    if (left_number != null and right_number != null) return left_number.? < right_number.?;
    if (left.len == 0 and right_number != null) return true;
    if (std.mem.eql(u8, left, "pre") and !std.mem.eql(u8, right, "pre")) return true;
    if (std.mem.eql(u8, right, "pre")) return false;
    // `2.3a` < `2.3.1`: a word sorts before a number.
    if (right_number != null) return true;
    if (left_number != null) return false;
    return std.mem.lessThan(u8, left, right);
}

fn componentNumber(part: []const u8) ?i32 {
    if (part.len == 0 or !std.ascii.isDigit(part[0])) return null;
    return std.fmt.parseInt(i32, part, 10) catch null;
}

fn isSeparator(c: u8) bool {
    return c == '.' or c == '-';
}

fn expectSplit(text: []const u8, expected: []const []const u8) !void {
    const parts = try splitVersion(std.testing.allocator, text);
    defer std.testing.allocator.free(parts);
    try std.testing.expectEqual(expected.len, parts.len);
    for (expected, parts) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn expectCompare(expected: i64, left: []const u8, right: []const u8) !void {
    try std.testing.expectEqual(expected, compareVersions(left, right));
    try std.testing.expectEqual(-expected, compareVersions(right, left));
}

test "splitVersion matches Nix tokenization examples" {
    try expectSplit("1.0-beta2", &.{ "1", "0", "beta", "2" });
    try expectSplit("", &.{});
    try expectSplit(".-.", &.{});
    // Only `.` and `-` separate components; any other non-digit is part of a
    // word, including `_`, punctuation and non-ASCII bytes.
    try expectSplit("__", &.{"__"});
    try expectSplit("a_b", &.{"a_b"});
    try expectSplit("1_2", &.{ "1", "_", "2" });
    try expectSplit("é", &.{"é"});
    try expectSplit("2.0rc1+git", &.{ "2", "0", "rc", "1", "+git" });
}

test "compareVersions matches Nix ordering examples" {
    try expectCompare(0, "1.02", "1.2");
    try expectCompare(-1, "1.0pre", "1.0");
    try expectCompare(-1, "2.3a", "2.3.1");
    try expectCompare(-1, "2.3", "2.3a");
    try expectCompare(-1, "a_b", "a_c");
    try expectCompare(0, "1.0", "1-0");
}

test "compareVersions treats components past a C int as words" {
    // Nix parses components with string2Int<int>: 2^31 is not a number, so
    // it sorts before every number, 0 included.
    try expectCompare(1, "0", "2147483648");
    try expectCompare(1, "2147483647", "2147483648");
    try expectCompare(1, "2147483647", "2147483648a");
    try expectCompare(0, "0002147483647", "2147483647");
    try expectCompare(-1, "2147483648", "3147483648");
}

test "parseDrvName splits at the first dash not followed by a letter" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "apache-httpd-2.0.48", "apache-httpd", "2.0.48" },
        .{ "name-that-ends-with-dash--1.0", "name-that-ends-with-dash", "-1.0" },
        .{ "a-", "a-", "" },
        .{ "a--", "a", "-" },
        .{ "-0", "", "0" },
        .{ "-", "-", "" },
        .{ "", "", "" },
    };
    for (cases) |case| {
        const parsed = parseDrvName(case[0]);
        try std.testing.expectEqualStrings(case[1], parsed.name);
        try std.testing.expectEqualStrings(case[2], parsed.version);
    }
}
