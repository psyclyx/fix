//! URLs as Nix reads and writes them (`libutil/url.cc`): RFC 3986 parsing
//! (Nix uses boost.url), with Nix's leniency for spaces and quotes in the
//! query and fragment, percent-decoded path segments and query parameters,
//! and the percent-encoding Nix prints them with. Flake references are built
//! on these, so they must agree with Nix character for character: lock files
//! and `flakeRefToString` show them.
//!
//! Everything a parse returns is allocated in the caller's allocator, which
//! is meant to be an arena.

const std = @import("std");

pub const Error = error{BadUrl} || std.mem.Allocator.Error;

pub const HostType = enum { name, ipv4, ipv6, ipvfuture };

pub const Authority = struct {
    host_type: HostType = .name,
    /// Percent-decoded; an IP literal without its brackets.
    host: []const u8 = "",
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    port: ?u16 = null,

    pub fn write(self: Authority, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        if (self.user) |user| {
            try percentEncodeAppend(out, allocator, user, "");
            if (self.password) |password| {
                try out.append(allocator, ':');
                try percentEncodeAppend(out, allocator, password, "");
            }
            try out.append(allocator, '@');
        }
        switch (self.host_type) {
            .name => try percentEncodeAppend(out, allocator, self.host, ""),
            .ipv4 => try out.appendSlice(allocator, self.host),
            .ipv6, .ipvfuture => {
                try out.append(allocator, '[');
                try percentEncodeAppend(out, allocator, self.host, ":");
                try out.append(allocator, ']');
            },
        }
        if (self.port) |port| try out.print(allocator, ":{d}", .{port});
    }
};

/// Query parameters, decoded, sorted by name and unique (Nix's `StringMap`).
pub const Query = struct {
    params: std.ArrayListUnmanaged(Param) = .empty,

    pub const Param = struct { name: []const u8, value: []const u8 };

    pub fn get(self: Query, name: []const u8) ?[]const u8 {
        const index = self.find(name) orelse return null;
        return self.params.items[index].value;
    }

    /// Add `name` unless it is already there (`std::map::emplace`).
    pub fn add(self: *Query, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        if (self.find(name) != null) return;
        try self.params.insert(allocator, self.insertionIndex(name), .{ .name = name, .value = value });
    }

    /// Add or replace `name` (`insert_or_assign`).
    pub fn put(self: *Query, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        if (self.find(name)) |index| {
            self.params.items[index].value = value;
            return;
        }
        try self.params.insert(allocator, self.insertionIndex(name), .{ .name = name, .value = value });
    }

    pub fn remove(self: *Query, name: []const u8) void {
        const index = self.find(name) orelse return;
        _ = self.params.orderedRemove(index);
    }

    pub fn clone(self: Query, allocator: std.mem.Allocator) !Query {
        return .{ .params = try self.params.clone(allocator) };
    }

    fn find(self: Query, name: []const u8) ?usize {
        for (self.params.items, 0..) |param, index| {
            if (std.mem.eql(u8, param.name, name)) return index;
        }
        return null;
    }

    fn insertionIndex(self: Query, name: []const u8) usize {
        for (self.params.items, 0..) |param, index| {
            if (std.mem.lessThan(u8, name, param.name)) return index;
        }
        return self.params.items.len;
    }
};

pub const ParsedUrl = struct {
    scheme: []const u8,
    authority: ?Authority = null,
    /// Percent-decoded segments: `/a/b` is `"", "a", "b"`.
    path: []const []const u8 = &.{},
    query: Query = .{},
    fragment: []const u8 = "",

    /// The non-empty path segments.
    pub fn pathSegments(self: ParsedUrl, allocator: std.mem.Allocator) ![]const []const u8 {
        var segments: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.path) |segment| {
            if (segment.len != 0) try segments.append(allocator, segment);
        }
        return segments.toOwnedSlice(allocator);
    }

    /// Nix's `ParsedURL::to_string`.
    pub fn toString(self: ParsedUrl, allocator: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try out.appendSlice(allocator, self.scheme);
        try out.append(allocator, ':');
        if (self.authority) |authority| {
            try out.appendSlice(allocator, "//");
            try authority.write(&out, allocator);
        }
        try encodeUrlPathAppend(&out, allocator, self.path);
        if (self.query.params.items.len != 0) {
            try out.append(allocator, '?');
            try encodeQueryAppend(&out, allocator, self.query);
        }
        if (self.fragment.len != 0) {
            try out.append(allocator, '#');
            try percentEncodeAppend(&out, allocator, self.fragment, "");
        }
        return out.toOwnedSlice(allocator);
    }
};

/// `application+transport`, e.g. `git+https`.
pub const Scheme = struct {
    application: ?[]const u8,
    transport: []const u8,

    pub fn parse(scheme: []const u8) Scheme {
        const plus = std.mem.indexOfScalar(u8, scheme, '+') orelse return .{ .application = null, .transport = scheme };
        return .{ .application = scheme[0..plus], .transport = scheme[plus + 1 ..] };
    }
};

/// Nix's `parseURL`. With `lenient`, unencoded spaces and double quotes are
/// accepted in the query, and those and `^` in the fragment, as Nix has
/// always allowed. Anything else outside RFC 3986 is `error.BadUrl`, and so
/// is a URL without a scheme.
pub fn parse(allocator: std.mem.Allocator, input: []const u8, lenient: bool) Error!ParsedUrl {
    const url = if (lenient) try fixLenient(allocator, input) else input;

    const scheme_end = schemeLength(url) orelse return error.BadUrl;
    const scheme = url[0..scheme_end];
    var rest = url[scheme_end + 1 ..];

    const fragment_start = std.mem.indexOfScalar(u8, rest, '#');
    const fragment_encoded = if (fragment_start) |i| rest[i + 1 ..] else "";
    if (fragment_start) |i| rest = rest[0..i];
    const query_start = std.mem.indexOfScalar(u8, rest, '?');
    const query_encoded = if (query_start) |i| rest[i + 1 ..] else "";
    if (query_start) |i| rest = rest[0..i];

    var authority: ?Authority = null;
    var encoded_path = rest;
    if (std.mem.startsWith(u8, rest, "//")) {
        const after = rest[2..];
        const end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
        authority = try parseAuthority(allocator, after[0..end]);
        encoded_path = after[end..];
    }
    try checkChars(encoded_path, pathChar);
    try checkChars(query_encoded, queryChar);
    try checkChars(fragment_encoded, queryChar);

    // A `file:` URL names no host (an empty one is fine), and its path is
    // at least `/`.
    const transport_is_file = std.mem.eql(u8, Scheme.parse(scheme).transport, "file");
    if (transport_is_file) {
        if (authority) |a| if (a.host.len != 0) return error.BadUrl;
        if (encoded_path.len == 0) encoded_path = "/";
    }

    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, encoded_path, '/');
    while (split.next()) |segment| try segments.append(allocator, try percentDecode(allocator, segment));

    return .{
        .scheme = scheme,
        .authority = authority,
        .path = try segments.toOwnedSlice(allocator),
        .query = try decodeQuery(allocator, query_encoded, false),
        .fragment = try percentDecode(allocator, fragment_encoded),
    };
}

/// The length of a leading `scheme` followed by `:`, if there is one.
fn schemeLength(url: []const u8) ?usize {
    if (url.len == 0 or !std.ascii.isAlphabetic(url[0])) return null;
    for (url[1..], 1..) |c, i| {
        if (c == ':') return i;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
    }
    return null;
}

/// Nix's lenient fixup: percent-encode ` ` and `"` in the query and ` `,
/// `"` and `^` in the fragment, which RFC 3986 doesn't allow unencoded.
fn fixLenient(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var view = url;
    if (std.mem.indexOfScalar(u8, view, '?')) |q| {
        try out.appendSlice(allocator, view[0 .. q + 1]);
        view = view[q + 1 ..];
        const fragment_start = std.mem.indexOfScalar(u8, view, '#') orelse view.len;
        try encodeSome(&out, allocator, view[0..fragment_start], " \"");
        view = view[fragment_start..];
    }
    if (std.mem.indexOfScalar(u8, view, '#')) |f| {
        try out.appendSlice(allocator, view[0 .. f + 1]);
        try encodeSome(&out, allocator, view[f + 1 ..], " \"^");
        return out.toOwnedSlice(allocator);
    }
    try out.appendSlice(allocator, view);
    return out.toOwnedSlice(allocator);
}

fn encodeSome(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8, chars: []const u8) !void {
    for (text) |c| {
        if (std.mem.indexOfScalar(u8, chars, c) != null) {
            try out.print(allocator, "%{X:0>2}", .{c});
        } else try out.append(allocator, c);
    }
}

fn parseAuthority(allocator: std.mem.Allocator, text: []const u8) Error!Authority {
    var authority: Authority = .{};
    var host_port = text;
    if (std.mem.indexOfScalar(u8, text, '@')) |at| {
        const userinfo = text[0..at];
        try checkChars(userinfo, userinfoChar);
        host_port = text[at + 1 ..];
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            authority.user = try percentDecode(allocator, userinfo[0..colon]);
            authority.password = try percentDecode(allocator, userinfo[colon + 1 ..]);
        } else {
            authority.user = try percentDecode(allocator, userinfo);
        }
    }

    var port_text: ?[]const u8 = null;
    if (std.mem.startsWith(u8, host_port, "[")) {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return error.BadUrl;
        const literal = host_port[1..close];
        const after = host_port[close + 1 ..];
        if (after.len != 0) {
            if (after[0] != ':') return error.BadUrl;
            port_text = after[1..];
        }
        if (literal.len != 0 and (literal[0] == 'v' or literal[0] == 'V')) {
            try checkChars(literal[1..], ipvFutureChar);
            authority.host_type = .ipvfuture;
            authority.host = try allocator.dupe(u8, literal);
        } else {
            if (!isIpv6(literal)) return error.BadUrl;
            authority.host_type = .ipv6;
            authority.host = try allocator.dupe(u8, literal);
        }
    } else {
        const colon = std.mem.indexOfScalar(u8, host_port, ':');
        const host = if (colon) |c| host_port[0..c] else host_port;
        if (colon) |c| port_text = host_port[c + 1 ..];
        try checkChars(host, regNameChar);
        authority.host_type = if (isIpv4(host)) .ipv4 else .name;
        authority.host = try percentDecode(allocator, host);
    }

    if (port_text) |port| {
        for (port) |c| if (!std.ascii.isDigit(c)) return error.BadUrl;
        if (port.len != 0) {
            const number = std.fmt.parseInt(u16, port, 10) catch return error.BadUrl;
            if (number == 0) return error.BadUrl;
            authority.port = number;
        }
    }
    return authority;
}

fn isIpv4(text: []const u8) bool {
    var octets = std.mem.splitScalar(u8, text, '.');
    var count: usize = 0;
    while (octets.next()) |octet| {
        count += 1;
        if (octet.len == 0 or octet.len > 3) return false;
        if (octet.len > 1 and octet[0] == '0') return false;
        const value = std.fmt.parseInt(u16, octet, 10) catch return false;
        if (value > 255) return false;
    }
    return count == 4;
}

fn isIpv6(text: []const u8) bool {
    // Hex groups separated by `:`, at most one `::`, optionally ending in
    // an IPv4 address.
    if (text.len == 0) return false;
    const double = std.mem.indexOf(u8, text, "::");
    if (double) |d| if (std.mem.indexOfPos(u8, text, d + 1, "::") != null) return false;
    var groups: usize = 0;
    var parts = std.mem.splitScalar(u8, text, ':');
    var index: usize = 0;
    while (parts.next()) |part| : (index += 1) {
        if (part.len == 0) continue;
        if (std.mem.indexOfScalar(u8, part, '.') != null) {
            if (parts.peek() != null or !isIpv4(part)) return false;
            groups += 2;
            continue;
        }
        if (part.len > 4) return false;
        for (part) |c| if (!std.ascii.isHex(c)) return false;
        groups += 1;
    }
    return if (double != null) groups < 8 else groups == 8;
}

fn checkChars(text: []const u8, comptime allowed: fn (u8) bool) Error!void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '%') {
            if (!isPercentEscape(text, i)) return error.BadUrl;
            i += 2;
            continue;
        }
        if (!allowed(c)) return error.BadUrl;
    }
}

/// `text[i]` is `%` followed by two hex digits.
fn isPercentEscape(text: []const u8, i: usize) bool {
    return i + 2 < text.len and std.ascii.isHex(text[i + 1]) and std.ascii.isHex(text[i + 2]);
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

fn isSubDelim(c: u8) bool {
    return std.mem.indexOfScalar(u8, "!$&'()*+,;=", c) != null;
}

fn pchar(c: u8) bool {
    return isUnreserved(c) or isSubDelim(c) or c == ':' or c == '@';
}

fn pathChar(c: u8) bool {
    return pchar(c) or c == '/';
}

fn queryChar(c: u8) bool {
    return pchar(c) or c == '/' or c == '?';
}

fn userinfoChar(c: u8) bool {
    return isUnreserved(c) or isSubDelim(c) or c == ':';
}

fn regNameChar(c: u8) bool {
    return isUnreserved(c) or isSubDelim(c);
}

fn ipvFutureChar(c: u8) bool {
    return isUnreserved(c) or isSubDelim(c) or c == ':';
}

/// Nix's `percentDecode`: every `%` must start two hex digits.
pub fn percentDecode(allocator: std.mem.Allocator, text: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, text.len);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '%') {
            out.appendAssumeCapacity(text[i]);
            continue;
        }
        if (!isPercentEscape(text, i)) return error.BadUrl;
        out.appendAssumeCapacity(std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch unreachable);
        i += 2;
    }
    return out.toOwnedSlice(allocator);
}

/// Nix's `percentEncode`: everything but RFC 3986's unreserved characters
/// and `keep` becomes `%XX`.
pub fn percentEncode(allocator: std.mem.Allocator, text: []const u8, keep: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try percentEncodeAppend(&out, allocator, text, keep);
    return out.toOwnedSlice(allocator);
}

fn percentEncodeAppend(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8, keep: []const u8) !void {
    for (text) |c| {
        if (isUnreserved(c) or std.mem.indexOfScalar(u8, keep, c) != null) {
            try out.append(allocator, c);
        } else {
            try out.print(allocator, "%{X:0>2}", .{c});
        }
    }
}

const allowed_in_query = ":@/?";
const allowed_in_path = ":@";

fn encodeUrlPathAppend(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, path: []const []const u8) !void {
    for (path, 0..) |segment, i| {
        if (i != 0) try out.append(allocator, '/');
        try percentEncodeAppend(out, allocator, segment, allowed_in_path);
    }
}

/// `name=value&…`, sorted by name, each part percent-encoded.
pub fn encodeQuery(allocator: std.mem.Allocator, query: Query) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try encodeQueryAppend(&out, allocator, query);
    return out.toOwnedSlice(allocator);
}

fn encodeQueryAppend(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, query: Query) !void {
    for (query.params.items, 0..) |param, i| {
        if (i != 0) try out.append(allocator, '&');
        try percentEncodeAppend(out, allocator, param.name, allowed_in_query);
        try out.append(allocator, '=');
        try percentEncodeAppend(out, allocator, param.value, allowed_in_query);
    }
}

/// Nix's `decodeQuery`: `a=1&b=2`, decoded; a parameter without `=` is
/// skipped, and the first of repeated names wins. With `lenient`, spaces and
/// double quotes needn't be encoded.
pub fn decodeQuery(allocator: std.mem.Allocator, encoded: []const u8, lenient: bool) Error!Query {
    var query: Query = .{};
    const text = if (lenient) fixed: {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        try encodeSome(&out, allocator, encoded, " \"");
        break :fixed try out.toOwnedSlice(allocator);
    } else encoded;
    if (text.len == 0) return query;
    try checkChars(text, queryChar);
    var params = std.mem.splitScalar(u8, text, '&');
    while (params.next()) |param| {
        const equals = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        try query.add(allocator, try percentDecode(allocator, param[0..equals]), try percentDecode(allocator, param[equals + 1 ..]));
    }
    return query;
}

/// Nix's `pathToUrlPath`: an absolute path starts with an empty segment.
/// A trailing `/` gives two more: one from iterating the `std::filesystem`
/// path (which yields a final empty component) and one for its empty file
/// name, so `path:/a/` prints as `path:/a//`.
pub fn pathToUrlPath(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    if (std.mem.startsWith(u8, path, "/")) try segments.append(allocator, "");
    var components = std.mem.tokenizeScalar(u8, path, '/');
    var any = false;
    while (components.next()) |component| {
        try segments.append(allocator, component);
        any = true;
    }
    const trailing_slash = path.len != 0 and path[path.len - 1] == '/';
    if (trailing_slash and any) try segments.append(allocator, "");
    if (path.len == 0 or trailing_slash) try segments.append(allocator, "");
    return segments.toOwnedSlice(allocator);
}

/// Nix's `urlPathToPath`: segments may contain neither `/` nor NUL.
pub fn urlPathToPath(allocator: std.mem.Allocator, segments: []const []const u8) Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (segments, 0..) |segment, i| {
        if (std.mem.indexOfAny(u8, segment, "/\x00") != null) return error.BadUrl;
        if (i == 0 and segment.len == 0) {
            try out.append(allocator, '/');
            continue;
        }
        // `std::filesystem::path::operator/=`: add a separator after a
        // file name, never twice.
        if (out.items.len != 0 and out.items[out.items.len - 1] != '/') try out.append(allocator, '/');
        try out.appendSlice(allocator, segment);
    }
    return out.toOwnedSlice(allocator);
}

/// Nix's `fixGitURL`: an absolute path is a `file://` URL, `host:path`
/// (scp syntax) an `ssh://` one, and `git+` is dropped from a URL's scheme.
pub fn fixGitUrl(allocator: std.mem.Allocator, url: []const u8) Error!ParsedUrl {
    if (std.mem.startsWith(u8, url, "/")) {
        return .{ .scheme = "file", .authority = .{}, .path = try pathToUrlPath(allocator, url) };
    }
    if (try parseScpStyle(allocator, url)) |parsed| return parsed;
    var parsed = try parse(allocator, url, false);
    const scheme = Scheme.parse(parsed.scheme);
    if (scheme.application) |application| {
        if (std.mem.eql(u8, application, "git")) parsed.scheme = scheme.transport;
    }
    return parsed;
}

/// `[user@]host:path` without `://`, where host has no `/` and isn't a
/// scheme git knows, as `ssh://[user@]host/path`.
fn parseScpStyle(allocator: std.mem.Allocator, url: []const u8) Error!?ParsedUrl {
    if (std.mem.indexOf(u8, url, "://") != null) return null;
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    var host = url[0..colon];
    if (std.mem.indexOfScalar(u8, host, '/') != null) return null;
    const git_schemes = [_][]const u8{ "ssh", "http", "https", "file", "ftp", "ftps", "git" };
    for (git_schemes) |scheme| {
        if (std.mem.eql(u8, host, scheme)) return null;
        if (std.mem.startsWith(u8, host, "git+") and std.mem.eql(u8, host[4..], scheme)) return null;
    }
    var path_view = url[colon + 1 ..];
    // A bracketed IPv6 host: the `:` that ends it follows the `]`.
    const bracket_start: ?usize = if (std.mem.indexOf(u8, url, "@[")) |at| at + 1 else if (std.mem.startsWith(u8, url, "[")) 0 else null;
    if (bracket_start) |start| {
        if (std.mem.indexOfScalarPos(u8, url, start + 1, ']')) |close| {
            if (close + 1 < url.len and url[close + 1] == ':') {
                host = url[0 .. close + 1];
                path_view = url[close + 2 ..];
            } else return null;
        }
    }

    var authority: Authority = .{};
    if (std.mem.indexOfScalar(u8, host, '@')) |at| {
        authority.user = host[0..at];
        host = host[at + 1 ..];
    }
    if (isIpv4(host)) {
        authority.host_type = .ipv4;
    } else if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
        if (!isIpv6(host)) return error.BadUrl;
        authority.host_type = .ipv6;
    }
    authority.host = host;
    if (path_view.len == 0) return error.BadUrl;

    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    // The path of an URL with an authority is absolute.
    if (path_view[0] != '/') try segments.append(allocator, "");
    var split = std.mem.splitScalar(u8, path_view, '/');
    while (split.next()) |segment| try segments.append(allocator, segment);
    return .{ .scheme = "ssh", .authority = authority, .path = try segments.toOwnedSlice(allocator) };
}

fn expectRoundTrip(input: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), input, true);
    try std.testing.expectEqualStrings(expected, try parsed.toString(arena.allocator()));
}

test "parse splits a URL into decoded parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const url = try parse(a, "git+https://user:pw@example.org:8080/a%20b/c?ref=x%2Fy&dir=d#frag%21", true);
    try std.testing.expectEqualStrings("git+https", url.scheme);
    try std.testing.expectEqualStrings("example.org", url.authority.?.host);
    try std.testing.expectEqualStrings("user", url.authority.?.user.?);
    try std.testing.expectEqualStrings("pw", url.authority.?.password.?);
    try std.testing.expectEqual(@as(?u16, 8080), url.authority.?.port);
    try std.testing.expectEqual(@as(usize, 3), url.path.len);
    try std.testing.expectEqualStrings("a b", url.path[1]);
    try std.testing.expectEqualStrings("x/y", url.query.get("ref").?);
    try std.testing.expectEqualStrings("d", url.query.get("dir").?);
    try std.testing.expectEqualStrings("frag!", url.fragment);

    const rootless = try parse(a, "github:owner/repo", true);
    try std.testing.expect(rootless.authority == null);
    try std.testing.expectEqual(@as(usize, 2), rootless.path.len);

    // Nix accepts spaces and quotes in the query, and `^` in the fragment.
    const lenient = try parse(a, "path:/x?dir=a b\"#c^d", true);
    try std.testing.expectEqualStrings("a b\"", lenient.query.get("dir").?);
    try std.testing.expectEqualStrings("c^d", lenient.fragment);
    try std.testing.expectError(error.BadUrl, parse(a, "path:/x?dir=a b", false));

    // The first of repeated parameters wins; one without `=` is ignored.
    const repeated = try parse(a, "x:y?a=1&a=2&b", true);
    try std.testing.expectEqualStrings("1", repeated.query.get("a").?);
    try std.testing.expect(repeated.query.get("b") == null);
}

test "parse rejects what RFC 3986 does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "/no/scheme",
        "nixpkgs",
        "1x:y",
        "x:a b",
        "x:a%2",
        "x:a%zz",
        "x:/a<b",
        "https://h:99999/",
        "https://h:0/",
        "https://a@b@c/",
        "file://host/x",
        "x:?a=%",
    }) |bad| {
        try std.testing.expectError(error.BadUrl, parse(a, bad, true));
    }
}

test "toString percent-encodes like Nix" {
    try expectRoundTrip("github:foo/bar/branch%23", "github:foo/bar/branch%23");
    try expectRoundTrip("http://localhost:8181/test/+3d.tar.gz", "http://localhost:8181/test/%2B3d.tar.gz");
    try expectRoundTrip("path:/foo%20bar/baz?dir=bla%20space", "path:/foo%20bar/baz?dir=bla%20space");
    try expectRoundTrip("x:y?b=2&a=1", "x:y?a=1&b=2");
    try expectRoundTrip("x:y?a=/:@?%26", "x:y?a=/:@?%26");
    try expectRoundTrip("https://[::1]:80/a", "https://[::1]:80/a");
    try expectRoundTrip("https://1.2.3.4/a", "https://1.2.3.4/a");
    try expectRoundTrip("file:", "file:/");
    try expectRoundTrip("file:///x", "file:///x");
}

test "paths convert to URL paths and back as in Nix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const []const u8, []const u8 }{
        .{ "/foo bar/baz", &.{ "", "foo bar", "baz" }, "/foo bar/baz" },
        .{ "/foo//bar/", &.{ "", "foo", "bar", "", "" }, "/foo/bar/" },
        .{ "/", &.{ "", "" }, "/" },
        .{ "rel/x", &.{ "rel", "x" }, "rel/x" },
    };
    for (cases) |case| {
        const segments = try pathToUrlPath(a, case[0]);
        try std.testing.expectEqual(case[1].len, segments.len);
        for (case[1], segments) |want, got| try std.testing.expectEqualStrings(want, got);
        try std.testing.expectEqualStrings(case[2], try urlPathToPath(a, segments));
    }
    try std.testing.expectEqualStrings("/foo/bar", try urlPathToPath(a, &.{ "", "foo", "", "bar" }));
    try std.testing.expectError(error.BadUrl, urlPathToPath(a, &.{ "", "a/b" }));
}

test "fixGitUrl handles paths, scp syntax and git+ schemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "/home/me/repo", "file:///home/me/repo" },
        .{ "git@github.com:NixOS/nix", "ssh://git@github.com/NixOS/nix" },
        .{ "git+https://example.org/repo", "https://example.org/repo" },
        .{ "git://example.org/repo", "git://example.org/repo" },
        .{ "git+file:///repo", "file:///repo" },
    };
    for (cases) |case| {
        const parsed = try fixGitUrl(a, case[0]);
        try std.testing.expectEqualStrings(case[1], try parsed.toString(a));
    }
}
