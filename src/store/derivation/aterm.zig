//! Serializes a Drv to Nix's ATerm text form (the `Derive(...)` string) that
//! is SHA-256'd to produce store paths and hash-modulo digests. Emits fields
//! in canonical sorted order, escapes strings, and can mask output paths.

const std = @import("std");
const sort = @import("sort.zig");
const types = @import("types.zig");

const DrvInput = types.DrvInput;
const DrvOutput = types.DrvOutput;
const EnvVar = types.EnvVar;

pub const DrvView = struct {
    outputs: []const DrvOutput,
    input_drvs: []const DrvInput,
    input_srcs: []const []const u8,
    system: []const u8,
    builder: []const u8,
    args: []const []const u8,
    env: []const EnvVar,
};

// SIMD find-first escape byte: derivation env values (build scripts, PATH
// lists, dependency closures) are long runs of escape-free bytes, so jump
// straight to the next char that needs escaping instead of testing every
// byte with a switch. Same shape as the string-literal scanner's skipToAnyOf.
const vec_len: comptime_int = std.simd.suggestVectorLength(u8) orelse 0;
const EscVec = @Vector(vec_len, u8);
const EscMask = @Int(.unsigned, if (vec_len == 0) 1 else vec_len);

inline fn escMaskEq(v: EscVec, comptime c: u8) EscMask {
    return @bitCast(v == @as(EscVec, @splat(c)));
}

/// Index of the first escape-needing byte (`"`, `\`, `\n`, `\r`, `\t`) at or
/// after `start`, or `string.len` if the SIMD-reachable prefix has none (the
/// scalar tail loop finishes the rest).
inline fn nextEscape(string: []const u8, start: usize) usize {
    var i = start;
    if (comptime vec_len > 0) {
        while (i + vec_len <= string.len) {
            const v: EscVec = string[i..][0..vec_len].*;
            var m: EscMask = 0;
            m |= escMaskEq(v, '"');
            m |= escMaskEq(v, '\\');
            m |= escMaskEq(v, '\n');
            m |= escMaskEq(v, '\r');
            m |= escMaskEq(v, '\t');
            if (m != 0) return i + @ctz(m);
            i += vec_len;
        }
    }
    return i;
}

pub fn toATerm(drv: DrvView, allocator: std.mem.Allocator, mask_outputs: bool, actual_inputs: ?[]const DrvInput) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // Pre-size from the dominant content (env values + input paths) so the
    // build doesn't repeatedly realloc-and-copy a growing buffer.
    var estimate: usize = 256;
    for (drv.env) |e| estimate += e.name.len + e.value.len + 8;
    const est_inputs = actual_inputs orelse drv.input_drvs;
    for (est_inputs) |i| estimate += i.path.len + 16;
    try out.ensureTotalCapacity(allocator, estimate);

    try out.appendSlice(allocator, "Derive([");
    const sorted_outputs = try sort.sortedOutputs(allocator, drv.outputs);
    defer allocator.free(sorted_outputs);
    for (sorted_outputs, 0..) |output, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.append(allocator, '(');
        try appendUnquotedString(allocator, &out, output.name);
        try out.append(allocator, ',');
        try appendUnquotedString(allocator, &out, if (mask_outputs) "" else output.path);
        try out.append(allocator, ',');
        try appendUnquotedString(allocator, &out, output.hash_algo);
        try out.append(allocator, ',');
        try appendUnquotedString(allocator, &out, output.hash);
        try out.append(allocator, ')');
    }
    try out.appendSlice(allocator, "],[");
    const inputs = actual_inputs orelse drv.input_drvs;
    const sorted_inputs = try sort.sortedInputs(allocator, inputs);
    defer allocator.free(sorted_inputs);
    for (sorted_inputs, 0..) |input, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.append(allocator, '(');
        try appendUnquotedString(allocator, &out, input.path);
        try out.append(allocator, ',');
        const sorted_names = try sort.sortedStrings(allocator, input.outputs);
        defer allocator.free(sorted_names);
        try appendUnquotedStringList(allocator, &out, sorted_names);
        try out.append(allocator, ')');
    }
    try out.appendSlice(allocator, "],");
    const sorted_srcs = try sort.sortedStrings(allocator, drv.input_srcs);
    defer allocator.free(sorted_srcs);
    try appendUnquotedStringList(allocator, &out, sorted_srcs);
    try out.append(allocator, ',');
    try appendUnquotedString(allocator, &out, drv.system);
    try out.append(allocator, ',');
    try appendString(allocator, &out, drv.builder);
    try out.append(allocator, ',');
    try appendStringList(allocator, &out, drv.args);
    try out.appendSlice(allocator, ",[");
    const sorted_env = try sort.sortedEnv(allocator, drv.env);
    defer allocator.free(sorted_env);
    for (sorted_env, 0..) |env, index| {
        if (index != 0) try out.append(allocator, ',');
        try out.append(allocator, '(');
        try appendString(allocator, &out, env.name);
        try out.append(allocator, ',');
        const value = if (mask_outputs and hasOutput(drv.outputs, env.name)) "" else env.value;
        try appendString(allocator, &out, value);
        try out.append(allocator, ')');
    }
    try out.appendSlice(allocator, "])");
    return out.toOwnedSlice(allocator);
}

fn hasOutput(outputs: []const DrvOutput, name: []const u8) bool {
    for (outputs) |output| {
        if (std.mem.eql(u8, output.name, name)) return true;
    }
    return false;
}

fn appendStringList(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), strings: []const []const u8) !void {
    try out.append(allocator, '[');
    for (strings, 0..) |string, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendString(allocator, out, string);
    }
    try out.append(allocator, ']');
}

fn appendUnquotedStringList(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), strings: []const []const u8) !void {
    try out.append(allocator, '[');
    for (strings, 0..) |string, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendUnquotedString(allocator, out, string);
    }
    try out.append(allocator, ']');
}

fn appendString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), string: []const u8) !void {
    try out.append(allocator, '"');
    // Bulk-copy maximal runs with no escape-needing char, then emit the
    // one escape, instead of appending byte-by-byte (each with its own
    // capacity check). Derivation env values (build scripts, dependency
    // lists) are large and almost entirely escape-free, so this is one
    // `appendSlice` per value in the common case rather than N appends —
    // and this runs on the w=32 critical path (drv ATerm hashing). A SIMD
    // scan (`nextEscape`) jumps straight over the escape-free runs.
    var start: usize = 0;
    var i: usize = nextEscape(string, 0);
    while (i < string.len) : (i = nextEscape(string, i)) {
        const esc: []const u8 = switch (string[i]) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            // A non-escape byte only appears here as the SIMD tail's scalar
            // fallthrough handoff; skip it — it stays in the current run.
            else => {
                i += 1;
                continue;
            },
        };
        if (i > start) try out.appendSlice(allocator, string[start..i]);
        try out.appendSlice(allocator, esc);
        start = i + 1;
        i += 1;
    }
    if (start < string.len) try out.appendSlice(allocator, string[start..]);
    try out.append(allocator, '"');
}

fn appendUnquotedString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), string: []const u8) !void {
    try out.append(allocator, '"');
    try out.appendSlice(allocator, string);
    try out.append(allocator, '"');
}
