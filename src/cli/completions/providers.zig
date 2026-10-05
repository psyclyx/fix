//! Engine-backed completion providers and attribute projection.

const std = @import("std");
const args = @import("../args.zig");
const eval_support = @import("../eval_support.zig");
const setup = @import("../setup.zig");
const config_discovery = @import("../config_discovery.zig");
const context = @import("context.zig");
const engine = @import("expr");
const Value = @import("runtime").Value;
const Engine = engine.Engine;

pub fn completeSourceAttrs(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    writer: *std.Io.Writer,
    words: []const [:0]const u8,
    cmd: args.Cmd,
    stop: usize,
    prefix: []const u8,
    replacement: []const u8,
) !void {
    var options = try context.parseOptionsBefore(allocator, words, cmd, stop);
    defer options.deinit(allocator);
    const source_arg = options.source orelse options.defaultSource();
    if (source_arg == .flake) options.experimental_features.insert(.flakes);

    var settings = try config_discovery.loadLocal(allocator, init, &options);
    config_discovery.fetchFlakeSettings(allocator, init, &options, &settings);
    defer settings.deinit();
    var ev = try Engine.init(allocator, setup.engineConfig(init, 1, null, null));
    var session = setup.Session.init(&ev);
    defer session.deinit(.full);
    ev.setParallelismToggles(true, true);
    _ = try session.configure(init, &options, &settings);
    var source = try eval_support.getCompletionSource(&ev, init.io, source_arg, options.sourceOptions());
    defer source.deinit(ev.hostAllocator());
    const value = try ev.evaluatePathAt(source.slice(), source.base_path, source.abs_path);
    try writeAttrCandidates(allocator, writer, &ev, value, prefix, replacement);
}

pub fn completePackageAttrs(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    writer: *std.Io.Writer,
    words: []const [:0]const u8,
    cmd: args.Cmd,
    stop: usize,
    prefix: []const u8,
    replacement: []const u8,
) !void {
    var options = try context.parseOptionsBefore(allocator, words, cmd, stop);
    defer options.deinit(allocator);
    var settings = try config_discovery.loadLocal(allocator, init, &options);
    config_discovery.fetchFlakeSettings(allocator, init, &options, &settings);
    defer settings.deinit();
    var ev = try Engine.init(allocator, setup.engineConfig(init, 1, null, null));
    var session = setup.Session.init(&ev);
    defer session.deinit(.full);
    ev.setParallelismToggles(true, true);
    _ = try session.configure(init, &options, &settings);
    const value = try ev.evaluate("import <nixpkgs> { }");
    try writeAttrCandidates(allocator, writer, &ev, value, prefix, replacement);
}

pub fn completeFlakeAttrs(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    writer: *std.Io.Writer,
    words: []const [:0]const u8,
    cmd: args.Cmd,
    stop: usize,
    prefix: []const u8,
    replacement: []const u8,
) !void {
    const hash = std.mem.indexOfScalar(u8, prefix, '#').?;
    const flake_ref = if (hash == 0) "." else prefix[0..hash];
    const fragment = prefix[hash + 1 ..];
    const parts = attrParts(fragment);

    var options = try context.parseOptionsBefore(allocator, words, cmd, stop);
    defer options.deinit(allocator);
    options.experimental_features.insert(.flakes);
    var settings = try config_discovery.loadLocal(allocator, init, &options);
    config_discovery.fetchFlakeSettings(allocator, init, &options, &settings);
    defer settings.deinit();
    var ev = try Engine.init(allocator, setup.engineConfig(init, 1, null, null));
    var session = setup.Session.init(&ev);
    defer session.deinit(.full);
    ev.setParallelismToggles(true, true);
    _ = try session.configure(init, &options, &settings);

    const source = try eval_support.lowerFlakeCompletion(&ev, init.io, flake_ref, parts.parent);
    defer ev.hostAllocator().free(source);
    const value = try ev.evaluate(source);
    const name_prefix = prefix[0 .. hash + 1 + parts.stem_len];
    try writeAttrEntries(allocator, writer, &ev, value, parts.partial, replacement, name_prefix);
}

pub const AttrParts = struct {
    parent: []const u8,
    partial: []const u8,
    stem_len: usize,
};

pub fn attrParts(prefix: []const u8) AttrParts {
    const dot = std.mem.lastIndexOfScalar(u8, prefix, '.') orelse
        return .{ .parent = "", .partial = prefix, .stem_len = 0 };
    return .{
        .parent = prefix[0..dot],
        .partial = prefix[dot + 1 ..],
        .stem_len = dot + 1,
    };
}

pub fn writeAttrEntries(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    ev: *Engine,
    value: Value,
    partial: []const u8,
    replacement: []const u8,
    name_prefix: []const u8,
) !void {
    const forced = try ev.forceValue(value);
    if (!forced.isAttrs()) return;
    const entries = try ev.tooling().attrs(forced);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    for (entries.names) |entry_name| {
        const name = ev.tooling().internText(entry_name);
        if (std.mem.startsWith(u8, name, partial) and std.mem.indexOfAny(u8, name, "\t\r\n") == null)
            try names.append(allocator, name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    for (names.items) |name|
        try writer.print("{s}{s}{s}\n", .{ replacement, name_prefix, name });
}

fn writeAttrCandidates(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    ev: *Engine,
    root: Value,
    prefix: []const u8,
    replacement: []const u8,
) !void {
    const parts = attrParts(prefix);
    const value = if (parts.parent.len == 0)
        try ev.forceValue(root)
    else
        (try ev.attrPathValue(root, parts.parent)) orelse return;
    try writeAttrEntries(allocator, writer, ev, value, parts.partial, replacement, prefix[0..parts.stem_len]);
}
