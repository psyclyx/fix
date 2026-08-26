//! Terminal policy, styling, and synchronized stderr presentation.

const std = @import("std");
const terminal_color = @import("base").terminal_color;

pub const When = enum { auto, always, never };
pub const ColorDepth = terminal_color.Depth;

pub const ProgressMode = enum { enabled, disabled };

pub const ProgressPolicy = struct {
    log: bool,

    pub fn enabled(self: ProgressPolicy) bool {
        return self.log;
    }
};

/// Every accepted `WHEN` spelling, so argument parsing can recognize the value
/// set without restating it.
pub const when_words = std.meta.fieldNames(When);

pub fn parseWhen(text: []const u8) ?When {
    return std.meta.stringToEnum(When, text);
}

pub fn printHelp(io: std.Io, text: []const u8) void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buf);
    writer.interface.writeAll(text) catch return;
    writer.interface.flush() catch {};
}

pub fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

pub fn isStderrInteractive(io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("TERM")) |term| if (std.mem.eql(u8, term, "dumb")) return false;
    return std.Io.File.stderr().isTty(io) catch false;
}

pub fn colorDepth(mode: When, io: std.Io, env: *const std.process.Environ.Map) ColorDepth {
    return colorDepthForTerminal(mode, isStderrInteractive(io, env), env);
}

pub fn colorDepthForTerminal(mode: When, interactive: bool, env: *const std.process.Environ.Map) ColorDepth {
    if (mode == .never) return .none;
    if (mode == .auto and (!interactive or env.get("NO_COLOR") != null)) return .none;

    if (env.get("COLORTERM")) |value| {
        if (std.ascii.eqlIgnoreCase(value, "truecolor") or std.ascii.eqlIgnoreCase(value, "24bit"))
            return .truecolor;
    }
    if (env.get("TERM")) |term| {
        if (std.mem.indexOf(u8, term, "direct") != null) return .truecolor;
        if (std.mem.indexOf(u8, term, "256color") != null) return .ansi256;
    }
    return .ansi16;
}

pub fn progressPolicy(mode: ProgressMode) ProgressPolicy {
    return switch (mode) {
        .disabled => .{ .log = false },
        .enabled => .{ .log = true },
    };
}

pub const Style = enum {
    name,
    path,
    dim,
    error_label,
    note_label,
    trace_label,
    success,
    warning,
};

pub const Rgb = terminal_color.Rgb;

/// Semantic verb identities. Ongoing and completed spellings of the same
/// operation deliberately share a color.
pub const Verb = enum {
    transform,
    evaluate,
    store,
    query,
    fetch,
    build,
};

/// Golden-angle palette positions that stay away from red, orange, and yellow.
/// Those hues carry error/warning meaning elsewhere in the CLI, so progress
/// identities use only green, cyan, blue, purple, and magenta.
const log_hues = [_]usize{ 1, 2, 4, 5, 7, 9, 10, 12, 14, 15, 17, 18, 20, 22, 23, 25 };

fn logHue(index: usize) Rgb {
    return terminal_color.hueColor(log_hues[index % log_hues.len]);
}

fn stableLogColor(namespace: u64, text: []const u8) Rgb {
    return logHue(@intCast(std.hash.Wyhash.hash(namespace, text) % log_hues.len));
}

pub fn styleCode(use_color: bool, which: Style) []const u8 {
    if (!use_color) return "";
    return switch (which) {
        .name => "\x1b[1m",
        .path => "\x1b[32m",
        .dim => "\x1b[2m",
        .error_label => "\x1b[1;31m",
        .note_label => "\x1b[1;36m",
        .trace_label => "\x1b[36m",
        .success => "\x1b[32m",
        .warning => "\x1b[1;33m",
    };
}

pub fn resetCode(use_color: bool) []const u8 {
    return if (use_color) "\x1b[0m" else "";
}

pub fn style(writer: *std.Io.Writer, use_color: bool, which: Style) !void {
    if (use_color) try writer.writeAll(styleCode(true, which));
}

pub fn reset(writer: *std.Io.Writer, use_color: bool) !void {
    if (use_color) try writer.writeAll(resetCode(true));
}

/// Prefix a durable record with elapsed time and its independently colored
/// source tag. Verb and noun colors are applied by the record writer.
pub fn writeLogPrefix(
    writer: *std.Io.Writer,
    io: std.Io,
    color_depth: ColorDepth,
    started_at: std.Io.Timestamp,
    tag: []const u8,
) !void {
    const now = std.Io.Clock.awake.now(io);
    const elapsed_ns = now.nanoseconds - started_at.nanoseconds;
    const elapsed_ms: u64 = if (elapsed_ns <= 0) 0 else @intCast(@divFloor(elapsed_ns, std.time.ns_per_ms));
    const use_color = color_depth.enabled();
    try style(writer, use_color, .dim);
    try writeElapsedTimestamp(writer, elapsed_ms);
    try reset(writer, use_color);
    try writer.writeByte(' ');
    try terminal_color.foreground(writer, color_depth, systemColor(tag), false);
    try writer.print("[{s}]", .{tag});
    try reset(writer, use_color);
    try writer.writeByte(' ');
}

fn writeElapsedTimestamp(writer: *std.Io.Writer, elapsed_ms: u64) !void {
    try writer.print("[{d:>8}ms]", .{elapsed_ms});
}

pub fn foreground(writer: *std.Io.Writer, color_depth: ColorDepth, color: Rgb, bold: bool) !void {
    try terminal_color.foreground(writer, color_depth, color, bold);
}

pub fn verbColor(verb: Verb) Rgb {
    const hues = [_]usize{ 4, 1, 2, 7, 17, 5 };
    return terminal_color.hueColor(hues[@intFromEnum(verb)]);
}

pub fn nounColor(noun: []const u8) Rgb {
    return stableLogColor(0x6e6f_756e, noun);
}

/// Relativize paths beneath the invocation directory. Nix store derivations
/// instead lose their mechanical `/nix/store/<hash>-` prefix; derived-path
/// output selectors remain attached.
pub fn logNoun(cwd: []const u8, subject: []const u8) []const u8 {
    if (std.mem.startsWith(u8, subject, "/nix/store/")) {
        const base = std.fs.path.basename(subject);
        const drv_end = std.mem.indexOfScalar(u8, base, '!') orelse base.len;
        if (std.mem.endsWith(u8, base[0..drv_end], ".drv")) {
            const hyphen = std.mem.indexOfScalar(u8, base, '-') orelse return relativeToCwd(cwd, subject);
            return base[hyphen + 1 ..];
        }
    }
    return relativeToCwd(cwd, subject);
}

fn relativeToCwd(cwd: []const u8, path: []const u8) []const u8 {
    if (cwd.len == 0 or !std.fs.path.isAbsolute(path)) return path;
    if (std.mem.eql(u8, cwd, path)) return ".";
    if (std.mem.eql(u8, cwd, "/")) return path[1..];
    if (path.len > cwd.len and path[cwd.len] == '/' and std.mem.startsWith(u8, path, cwd))
        return path[cwd.len + 1 ..];
    return path;
}

pub fn systemColor(system: []const u8) Rgb {
    // Keep the small, user-facing system vocabulary at deliberately separated
    // points in the shared palette. Unknown producers still get an identity
    // color without needing to extend this presentation layer first.
    if (std.mem.eql(u8, system, "eval")) return terminal_color.hueColor(2);
    if (std.mem.eql(u8, system, "daemon")) return terminal_color.hueColor(4);
    if (std.mem.eql(u8, system, "fetch")) return terminal_color.hueColor(1);
    if (std.mem.eql(u8, system, "build")) return terminal_color.hueColor(7);
    return stableLogColor(0x7379_7374, system);
}

pub const Stderr = struct {
    io: std.Io,
    locked: std.Io.LockedStderr,

    pub fn writer(self: *Stderr) *std.Io.Writer {
        return &self.locked.file_writer.interface;
    }

    pub fn flush(self: *Stderr) !void {
        try self.writer().flush();
    }

    pub fn deinit(self: *Stderr) void {
        self.io.unlockStderr();
    }
};

pub fn lockStderr(io: std.Io, buffer: []u8) std.Io.Cancelable!Stderr {
    return .{ .io = io, .locked = try io.lockStderr(buffer, null) };
}

test "parse terminal policy" {
    try std.testing.expectEqual(When.auto, parseWhen("auto").?);
    try std.testing.expect(parseWhen("sometimes") == null);
    try std.testing.expect(progressPolicy(.enabled).log);
    try std.testing.expect(!progressPolicy(.disabled).enabled());
}

test "color depth follows conservative terminal capabilities" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectEqual(ColorDepth.ansi16, colorDepthForTerminal(.auto, true, &env));
    try env.put("TERM", "xterm-256color");
    try std.testing.expectEqual(ColorDepth.ansi256, colorDepthForTerminal(.auto, true, &env));
    try env.put("COLORTERM", "truecolor");
    try std.testing.expectEqual(ColorDepth.truecolor, colorDepthForTerminal(.auto, true, &env));
    try env.put("NO_COLOR", "1");
    try std.testing.expectEqual(ColorDepth.none, colorDepthForTerminal(.auto, true, &env));
    try std.testing.expectEqual(ColorDepth.truecolor, colorDepthForTerminal(.always, false, &env));
}

test "log identity colors avoid ANSI error and warning slots" {
    for (log_hues) |hue| {
        const code = terminal_color.ansi16Code(terminal_color.hueColor(hue), false);
        try std.testing.expect(code != 31 and code != 91);
        try std.testing.expect(code != 33 and code != 93);
    }
    inline for (std.meta.fields(Verb)) |field| {
        const code = terminal_color.ansi16Code(verbColor(@enumFromInt(field.value)), false);
        try std.testing.expect(code != 31 and code != 91);
        try std.testing.expect(code != 33 and code != 93);
    }
}

test "log nouns shorten only nix store derivations" {
    try std.testing.expectEqualStrings(
        "hello-1.0.drv",
        logNoun("/work", "/nix/store/01234567890123456789012345678901-hello-1.0.drv"),
    );
    try std.testing.expectEqualStrings(
        "hello-1.0.drv!*",
        logNoun("/work", "/nix/store/01234567890123456789012345678901-hello-1.0.drv!*"),
    );
    const source = "/nix/store/01234567890123456789012345678901-source";
    try std.testing.expectEqualStrings(source, logNoun("/work", source));
    try std.testing.expectEqualStrings("test/a-file.nix", logNoun("/work", "/work/test/a-file.nix"));
    const outside = "/workspace/test/a-file.nix";
    try std.testing.expectEqualStrings(outside, logNoun("/work", outside));
}

test "log timestamps are space-padded elapsed milliseconds" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeElapsedTimestamp(&writer, 12);
    try std.testing.expectEqualStrings("[      12ms]", writer.buffered());
}
