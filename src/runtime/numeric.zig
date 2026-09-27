//! Numeric operations shared by bytecode opcodes and builtins.
//!
//! All int-returning ops take the heap so they can transparently box
//! results that overflow the 48-bit inline int range via
//! `runtime/int.zig`'s `make` helper.

const std = @import("std");
const Value = @import("value.zig").Value;
const int_mod = @import("int.zig");
const ObjectHeap = @import("heap.zig").ObjectHeap;

pub fn isNumeric(value: Value) bool {
    return int_mod.isAnyInt(value) or value.isFloat();
}

pub fn toFloat(value: Value, heap: *const ObjectHeap) !f64 {
    return switch (value.kind()) {
        .int => @floatFromInt(value.asInt()),
        .boxed_int => @floatFromInt(try heap.getBoxedInt(value.asObjectId())),
        .float => value.asFloat(),
        else => error.TypeError,
    };
}

// ---- Nix-parity integer arithmetic ----
//
// Nix's C++ evaluator raises on integer overflow rather than wrapping.
// We match that: each binary op uses Zig's checked overflow builtin and
// returns `error.IntegerOverflow` when the result wouldn't fit i64.
// Float arithmetic, by contrast, uses ordinary IEEE 754 (Inf/NaN-producing)
// EXCEPT for division by zero, which Nix raises rather than producing Inf.

inline fn checkedAdd(a: i64, b: i64) !i64 {
    const r = @addWithOverflow(a, b);
    if (r[1] != 0) return error.IntegerOverflow;
    return r[0];
}

inline fn checkedSub(a: i64, b: i64) !i64 {
    const r = @subWithOverflow(a, b);
    if (r[1] != 0) return error.IntegerOverflow;
    return r[0];
}

inline fn checkedMul(a: i64, b: i64) !i64 {
    const r = @mulWithOverflow(a, b);
    if (r[1] != 0) return error.IntegerOverflow;
    return r[0];
}

pub fn add(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (int_mod.isAnyInt(a) and int_mod.isAnyInt(b)) {
        return int_mod.make(heap, try checkedAdd(int_mod.get(a, heap), int_mod.get(b, heap)));
    }
    if (isNumeric(a) and isNumeric(b)) return Value.float(try toFloat(a, heap) + try toFloat(b, heap));
    return error.TypeError;
}

pub fn sub(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (int_mod.isAnyInt(a) and int_mod.isAnyInt(b)) {
        return int_mod.make(heap, try checkedSub(int_mod.get(a, heap), int_mod.get(b, heap)));
    }
    if (isNumeric(a) and isNumeric(b)) return Value.float(try toFloat(a, heap) - try toFloat(b, heap));
    return error.TypeError;
}

pub fn mul(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (int_mod.isAnyInt(a) and int_mod.isAnyInt(b)) {
        return int_mod.make(heap, try checkedMul(int_mod.get(a, heap), int_mod.get(b, heap)));
    }
    if (isNumeric(a) and isNumeric(b)) return Value.float(try toFloat(a, heap) * try toFloat(b, heap));
    return error.TypeError;
}

pub fn div(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (int_mod.isAnyInt(a) and int_mod.isAnyInt(b)) {
        const bi = int_mod.get(b, heap);
        if (bi == 0) return error.DivisionByZero;
        const ai = int_mod.get(a, heap);
        // `@divTrunc(i64_min, -1)` overflows i64 (the mathematical result
        // is 2^63, one past the max). Zig treats this as illegal
        // behaviour; raise instead of leaving it to LLVM.
        if (ai == std.math.minInt(i64) and bi == -1) return error.IntegerOverflow;
        return int_mod.make(heap, @divTrunc(ai, bi));
    }
    if (isNumeric(a) and isNumeric(b)) {
        const bf = try toFloat(b, heap);
        // Parity with Nix: float division by zero raises rather than
        // producing IEEE Inf/NaN.
        if (bf == 0.0) return error.DivisionByZero;
        return Value.float(try toFloat(a, heap) / bf);
    }
    return error.TypeError;
}

pub fn negate(heap: *ObjectHeap, value: Value) !Value {
    return switch (value.kind()) {
        // Negating i64_min overflows; defer to checkedSub for parity with
        // Nix's `0 - i64_min` behaviour.
        .int => int_mod.make(heap, try checkedSub(0, value.asInt())),
        .boxed_int => int_mod.make(heap, try checkedSub(0, try heap.getBoxedInt(value.asObjectId()))),
        .float => Value.float(-value.asFloat()),
        else => error.TypeError,
    };
}

/// Longest `formatToString` result: a sign, the 309 integer digits of the
/// largest double, and ".000000".
pub const to_string_max_len = 1 + 309 + 7;

/// A float as Nix coerces it to a string (`toString 1.5`), which is C++
/// `std::to_string`, i.e. printf `%f`: the exact binary value rounded to six
/// decimals, ties to even (glibc). Formatting the shortest round-trip digits
/// with `{d:.6}` instead rounds twice and keeps only 17 significant digits,
/// so `1.0078125` would print `1.007813` and `3.002399751580331e16` would
/// lose its last digits.
pub fn formatToString(buf: *[to_string_max_len]u8, v: f64) []const u8 {
    return formatFixed(buf, v, 6);
}

/// Longest `formatG` result: a sign, 17 digits, a point, and `e-308`.
pub const g_max_len = 1 + 17 + 1 + 5;

/// printf `%.{precision}g` (precision ≤ 17), which is how C++ streams print
/// a double by default (precision 6): Nix uses it for `toXML` and to print
/// values. Rounds the exact value, like `formatToString`.
pub fn formatG(buf: *[g_max_len]u8, v: f64, precision: u5) []const u8 {
    std.debug.assert(precision <= 17);
    var out = Output{ .buf = buf };
    if (writeSpecial(&out, v)) return out.slice();
    if (std.math.signbit(v)) out.put('-');
    const p: i32 = @max(precision, 1);
    var digits_buf: [exact_digits_max + 1]u8 = undefined;
    const exact = exactDecimal(&digits_buf, @abs(v));
    if (exact.digits.len == 0) {
        out.put('0');
        return out.slice();
    }
    // The exponent style `e` would print, after rounding to `p` digits.
    var rounded_buf: [exact_digits_max + 1]u8 = undefined;
    const sci = roundDecimal(&rounded_buf, exact, p - exact.point);
    const x = sci.point - 1;
    if (x < -4 or x >= p) {
        // `e` style with p - 1 decimals, trailing zeros dropped.
        var mantissa = sci.digits[0..@min(sci.digits.len, @as(usize, @intCast(p)))];
        while (mantissa.len > 1 and mantissa[mantissa.len - 1] == '0') mantissa.len -= 1;
        out.put(mantissa[0]);
        if (mantissa.len > 1) {
            out.put('.');
            out.putAll(mantissa[1..]);
        }
        out.put('e');
        out.put(if (x < 0) '-' else '+');
        const magnitude: u32 = @abs(x);
        if (magnitude < 10) out.put('0');
        out.pos += (std.fmt.bufPrint(buf[out.pos..], "{d}", .{magnitude}) catch unreachable).len;
        return out.slice();
    }
    // `f` style with p - 1 - x decimals, trailing zeros (and point) dropped.
    const start = out.pos;
    writeFixedDigits(&out, sci, @intCast(p - 1 - x));
    if (std.mem.indexOfScalarPos(u8, buf[0..out.pos], start, '.') != null) {
        while (buf[out.pos - 1] == '0') out.pos -= 1;
        if (buf[out.pos - 1] == '.') out.pos -= 1;
    }
    return out.slice();
}

/// printf `%.{precision}f` of `v`, exactly rounded, ties to even.
fn formatFixed(buf: []u8, v: f64, precision: u32) []const u8 {
    var out = Output{ .buf = buf };
    if (writeSpecial(&out, v)) return out.slice();
    if (std.math.signbit(v)) out.put('-');
    var digits_buf: [exact_digits_max + 1]u8 = undefined;
    var rounded_buf: [exact_digits_max + 1]u8 = undefined;
    const rounded = roundDecimal(&rounded_buf, exactDecimal(&digits_buf, @abs(v)), @intCast(precision));
    writeFixedDigits(&out, rounded, precision);
    return out.slice();
}

const Output = struct {
    buf: []u8,
    pos: usize = 0,

    fn put(self: *Output, c: u8) void {
        self.buf[self.pos] = c;
        self.pos += 1;
    }

    fn putAll(self: *Output, bytes: []const u8) void {
        @memcpy(self.buf[self.pos .. self.pos + bytes.len], bytes);
        self.pos += bytes.len;
    }

    fn putZeros(self: *Output, count: usize) void {
        @memset(self.buf[self.pos .. self.pos + count], '0');
        self.pos += count;
    }

    fn slice(self: *const Output) []const u8 {
        return self.buf[0..self.pos];
    }
};

/// glibc's spelling of NaN and the infinities, sign included.
fn writeSpecial(out: *Output, v: f64) bool {
    if (!std.math.isNan(v) and !std.math.isInf(v)) return false;
    if (std.math.signbit(v)) out.put('-');
    out.putAll(if (std.math.isNan(v)) "nan" else "inf");
    return true;
}

/// `d` with exactly `precision` decimals; `d` must already be rounded to
/// them.
fn writeFixedDigits(out: *Output, d: Decimal, precision: u32) void {
    const len: i32 = @intCast(d.digits.len);
    if (d.point <= 0) {
        out.put('0');
    } else {
        const int_len: usize = @intCast(d.point);
        const have = @min(int_len, d.digits.len);
        out.putAll(d.digits[0..have]);
        out.putZeros(int_len - have);
    }
    if (precision == 0) return;
    out.put('.');
    // Decimal place k (1-based) holds digit index point + k - 1.
    var k: i32 = 1;
    while (k <= precision) : (k += 1) {
        const index = d.point + k - 1;
        out.put(if (index >= 0 and index < len) d.digits[@intCast(index)] else '0');
    }
}

/// A non-negative value `0.digits × 10^point`: `digits` has no leading
/// zeros, and is empty for zero.
const Decimal = struct {
    digits: []const u8,
    point: i32,
};

/// Significant digits of the exact decimal expansion of any double: at most
/// 17 + 751 for the smallest subnormals (2^-1074 = 5^1074 / 10^1074), 309
/// for the largest integers.
const exact_digits_max = 800;

/// The exact decimal expansion of a finite `v ≥ 0`. Every double is an
/// integer times a power of two, and so has a finite one.
fn exactDecimal(buf: *[exact_digits_max + 1]u8, v: f64) Decimal {
    const bits: u64 = @bitCast(v);
    const fraction = bits & ((@as(u64, 1) << 52) - 1);
    const biased: i32 = @intCast(bits >> 52);
    var mantissa: u64 = if (biased == 0) fraction else fraction | (@as(u64, 1) << 52);
    var exponent: i32 = if (biased == 0) -1074 else biased - 1075;
    if (mantissa == 0) return .{ .digits = buf[0..0], .point = 0 };
    const shift = @ctz(mantissa);
    mantissa >>= @intCast(shift);
    exponent += @intCast(shift);

    // mantissa * 2^exponent = mantissa * 2^exponent, or, for a negative
    // exponent, mantissa * 5^-exponent / 10^-exponent: an integer either
    // way, in base 10^9 limbs, least significant first.
    var limbs: [90]u32 = undefined;
    limbs[0] = @intCast(mantissa % 1_000_000_000);
    limbs[1] = @intCast(mantissa / 1_000_000_000 % 1_000_000_000);
    limbs[2] = @intCast(mantissa / 1_000_000_000 / 1_000_000_000);
    var len: usize = 3;
    while (len > 1 and limbs[len - 1] == 0) len -= 1;
    var remaining: u32 = @abs(exponent);
    while (remaining > 0) {
        // Multiply by 2^k or 5^k, keeping limb * factor + carry in a u64.
        const step: u32 = @min(remaining, @as(u32, if (exponent > 0) 31 else 13));
        remaining -= step;
        const factor: u64 = if (exponent > 0) @as(u64, 1) << @intCast(step) else std.math.pow(u64, 5, step);
        var carry: u64 = 0;
        for (limbs[0..len]) |*limb| {
            const t = @as(u64, limb.*) * factor + carry;
            limb.* = @intCast(t % 1_000_000_000);
            carry = t / 1_000_000_000;
        }
        while (carry != 0) {
            limbs[len] = @intCast(carry % 1_000_000_000);
            len += 1;
            carry /= 1_000_000_000;
        }
    }

    var n = (std.fmt.bufPrint(buf, "{d}", .{limbs[len - 1]}) catch unreachable).len;
    var i = len - 1;
    while (i > 0) {
        i -= 1;
        n += (std.fmt.bufPrint(buf[n..], "{d:0>9}", .{limbs[i]}) catch unreachable).len;
    }
    const scale: i32 = if (exponent < 0) exponent else 0;
    var digits = buf[0..n];
    while (digits[digits.len - 1] == '0') digits.len -= 1;
    return .{ .digits = digits, .point = @as(i32, @intCast(n)) + scale };
}

/// `d` rounded to `decimals` places after the point, ties to even: the
/// rounding glibc's printf does on exact values.
fn roundDecimal(buf: *[exact_digits_max + 1]u8, d: Decimal, decimals: i32) Decimal {
    const keep_signed = d.point + decimals;
    if (keep_signed >= d.digits.len) return d;
    if (keep_signed < 0) return .{ .digits = buf[0..0], .point = 0 };
    const keep: usize = @intCast(keep_signed);

    const rest = d.digits[keep..];
    const up = switch (rest[0]) {
        '6'...'9' => true,
        '5' => rest.len > 1 or (keep > 0 and (d.digits[keep - 1] - '0') % 2 == 1),
        else => false,
    };
    // One spare digit in front for a carry out of the top.
    @memcpy(buf[1 .. keep + 1], d.digits[0..keep]);
    var digits = buf[1 .. keep + 1];
    var point = d.point;
    if (up) {
        var i = keep;
        while (true) {
            if (i == 0) {
                buf[0] = '1';
                digits = buf[0 .. keep + 1];
                point += 1;
                break;
            }
            i -= 1;
            if (digits[i] != '9') {
                digits[i] += 1;
                break;
            }
            digits[i] = '0';
        }
    }
    while (digits.len > 0 and digits[digits.len - 1] == '0') digits.len -= 1;
    if (digits.len == 0) point = 0;
    return .{ .digits = digits, .point = point };
}

pub fn floor(heap: *ObjectHeap, value: Value) !Value {
    return switch (value.kind()) {
        .int => intFloorCeil(value.asInt(), value),
        .boxed_int => intFloorCeil(try heap.getBoxedInt(value.asObjectId()), value),
        .float => int_mod.make(heap, try floatToI64Safely(@floor(value.asFloat()))),
        else => error.TypeError,
    };
}

pub fn ceil(heap: *ObjectHeap, value: Value) !Value {
    return switch (value.kind()) {
        .int => intFloorCeil(value.asInt(), value),
        .boxed_int => intFloorCeil(try heap.getBoxedInt(value.asObjectId()), value),
        .float => int_mod.make(heap, try floatToI64Safely(@ceil(value.asFloat()))),
        else => error.TypeError,
    };
}

/// `builtins.floor`/`ceil` of an integer: Nix routes the argument through
/// `double`, so an integer with more than 53 significant bits would be
/// silently corrupted by the round-trip. Nix errors on this rather than
/// return a wrong value (unless the deprecated `floor-ceil-corrupt-integers`
/// feature is set). When the round-trip is exact we return the integer
/// unchanged, matching Nix (and the common small-int case).
fn intFloorCeil(i: i64, original: Value) !Value {
    if (intRoundTripCorruption(i) != null) return error.FloorCeilCorruptsInteger;
    return original;
}

/// If converting `i` to `f64` and back changes its value (`i` needs more
/// precision than an f64 mantissa holds), returns the corrupted round-trip
/// value; otherwise null. Floor and ceil of an already-integer-valued
/// double are identical, so a single round-trip covers both.
pub fn intRoundTripCorruption(i: i64) ?i64 {
    const f: f64 = @floatFromInt(i);
    const back = floatToI64Safely(f) catch return i; // out of i64 range ⇒ corrupted
    return if (back != i) back else null;
}

/// Convert a finite, in-range f64 to i64 with Nix-parity semantics:
///
///   - NaN and ±Infinity raise `error.NumericConversion` (Nix throws
///     `"failed to convert to integer"`).
///   - Finite floats whose magnitude is `>= 2^63` saturate to `i64_min`,
///     mirroring the x86 `cvttsd2si` "indefinite integer" result that
///     Nix's C++ cast exhibits. We replicate that exact behaviour rather
///     than triggering Zig's `@intFromFloat` UB.
///   - In-range finite floats truncate via `@intFromFloat`.
///
/// Hex float literals are exact: `0x1.0p63 == 2^63`. f64 represents 2^63
/// and -2^63 exactly but not (2^63 - 1), so the upper bound is strictly
/// less-than 2^63 and the lower bound is greater-equal -2^63.
fn floatToI64Safely(f: f64) !i64 {
    if (std.math.isNan(f) or std.math.isInf(f)) return error.NumericConversion;
    const upper_exclusive: f64 = 0x1.0p63;
    const lower_inclusive: f64 = -0x1.0p63;
    if (f < lower_inclusive or f >= upper_exclusive) return std.math.minInt(i64);
    return @intFromFloat(f);
}

pub fn bitAnd(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (!int_mod.isAnyInt(a) or !int_mod.isAnyInt(b)) return error.TypeError;
    return int_mod.make(heap, int_mod.get(a, heap) & int_mod.get(b, heap));
}

pub fn bitOr(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (!int_mod.isAnyInt(a) or !int_mod.isAnyInt(b)) return error.TypeError;
    return int_mod.make(heap, int_mod.get(a, heap) | int_mod.get(b, heap));
}

pub fn bitXor(heap: *ObjectHeap, a: Value, b: Value) !Value {
    if (!int_mod.isAnyInt(a) or !int_mod.isAnyInt(b)) return error.TypeError;
    return int_mod.make(heap, int_mod.get(a, heap) ^ int_mod.get(b, heap));
}

test "numeric builtins preserve int results when both inputs are ints" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    try std.testing.expectEqual(@as(i64, 3), (try add(&heap, Value.int(1), Value.int(2))).asInt());
    try std.testing.expectEqual(@as(i64, 3), (try div(&heap, Value.int(7), Value.int(2))).asInt());
    try std.testing.expectEqual(@as(i64, -3), (try div(&heap, Value.int(-7), Value.int(2))).asInt());
}

test "numeric builtins promote mixed numeric inputs to floats" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    try std.testing.expectEqual(@as(f64, 3.5), (try add(&heap, Value.int(1), Value.float(2.5))).asFloat());
    try std.testing.expectEqual(@as(f64, 3.5), (try div(&heap, Value.int(7), Value.float(2.0))).asFloat());
}

test "div rejects i64.min / -1 overflow rather than invoking @divTrunc UB" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    // Build i64.min via a boxed int so we exercise the cross-encoding
    // unbox path used by the safety check.
    const boxed_min = Value.boxedInt(try heap.addBoxedInt(std.math.minInt(i64)));
    try std.testing.expectError(error.IntegerOverflow, div(&heap, boxed_min, Value.int(-1)));
    // Sanity: i64.min / 1 still works (boxed result since i64.min doesn't
    // fit i48).
    _ = try div(&heap, boxed_min, Value.int(1));
}

test "int arithmetic raises on overflow rather than wrapping (Nix parity)" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    const max = Value.boxedInt(try heap.addBoxedInt(std.math.maxInt(i64)));
    const min = Value.boxedInt(try heap.addBoxedInt(std.math.minInt(i64)));
    try std.testing.expectError(error.IntegerOverflow, add(&heap, max, Value.int(1)));
    try std.testing.expectError(error.IntegerOverflow, sub(&heap, min, Value.int(1)));
    const half = Value.boxedInt(try heap.addBoxedInt(@as(i64, 1) << 32));
    try std.testing.expectError(error.IntegerOverflow, mul(&heap, half, half));
    try std.testing.expectError(error.IntegerOverflow, negate(&heap, min));
}

test "float division by zero raises (Nix parity)" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    try std.testing.expectError(error.DivisionByZero, div(&heap, Value.float(1.0), Value.float(0.0)));
    try std.testing.expectError(error.DivisionByZero, div(&heap, Value.float(0.0), Value.float(0.0)));
    try std.testing.expectError(error.DivisionByZero, div(&heap, Value.int(1), Value.float(0.0)));
}

test "floor/ceil reject NaN and infinities, saturate huge finite floats to i64_min (Nix parity)" {
    var heap = try ObjectHeap.init(std.testing.allocator, 1);
    defer heap.deinit();
    try std.testing.expectError(error.NumericConversion, floor(&heap, Value.float(std.math.nan(f64))));
    try std.testing.expectError(error.NumericConversion, ceil(&heap, Value.float(std.math.nan(f64))));
    try std.testing.expectError(error.NumericConversion, floor(&heap, Value.float(std.math.inf(f64))));
    try std.testing.expectError(error.NumericConversion, ceil(&heap, Value.float(-std.math.inf(f64))));
    // Out-of-range finite floats saturate to i64_min (Nix C++ inherits the
    // x86 cvttsd2si "indefinite integer" behaviour on overflow).
    const huge_pos = try floor(&heap, Value.float(1.0e100));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), int_mod.get(huge_pos, &heap));
    const huge_neg = try ceil(&heap, Value.float(-1.0e100));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), int_mod.get(huge_neg, &heap));
    // The boundary: exactly 2^63 saturates; -2^63 (== i64_min) succeeds.
    const boundary_pos = try floor(&heap, Value.float(0x1.0p63));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), int_mod.get(boundary_pos, &heap));
    const boundary_neg = try floor(&heap, Value.float(-0x1.0p63));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), int_mod.get(boundary_neg, &heap));
}

test "formatToString prints the exact value to six decimals, ties to even" {
    var buf: [to_string_max_len]u8 = undefined;
    const cases = [_]struct { f64, []const u8 }{
        .{ 1.0, "1.000000" },
        .{ 0.0, "0.000000" },
        .{ -0.0, "-0.000000" },
        .{ 1.5e-6, "0.000002" },
        .{ -1.0e-9, "-0.000000" },
        // Exactly representable ties round to even.
        .{ 1.0078125, "1.007812" },
        .{ 1.0234375, "1.023438" },
        .{ 0.0000005, "0.000000" },
        // The exact binary value, not the shortest round-trip digits.
        .{ 3.002399751580331e16, "30023997515803312.000000" },
        .{ 6.71088640127945e7, "67108864.012794" },
        .{ 0.1, "0.100000" },
        .{ 1.0e23, "99999999999999991611392.000000" },
        .{ 5.0e-324, "0.000000" },
        .{ 123456.7890625, "123456.789062" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case[1], formatToString(&buf, case[0]));
    }
    try std.testing.expectEqualStrings("inf", formatToString(&buf, std.math.inf(f64)));
    try std.testing.expectEqualStrings("-inf", formatToString(&buf, -std.math.inf(f64)));

    const max = formatToString(&buf, std.math.floatMax(f64));
    try std.testing.expectEqual(@as(usize, 309 + 7), max.len);
    try std.testing.expect(std.mem.startsWith(u8, max, "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368.000000"));
}

test "formatG is printf %g of the exact value" {
    var buf: [g_max_len]u8 = undefined;
    const cases = [_]struct { f64, u5, []const u8 }{
        .{ 0.0, 6, "0" },
        .{ -0.0, 6, "-0" },
        .{ 1.0, 6, "1" },
        .{ 0.1, 6, "0.1" },
        .{ 1.5, 6, "1.5" },
        .{ 123456789.0, 6, "1.23457e+08" },
        .{ 123456.0, 6, "123456" },
        .{ 1234567.0, 6, "1.23457e+06" },
        .{ 1.0e-5, 6, "1e-05" },
        .{ 0.0001, 6, "0.0001" },
        .{ 0.00012345678, 6, "0.000123457" },
        .{ 999999.5, 6, "1e+06" },
        .{ 9.9999949999, 6, "9.99999" },
        .{ 1.0e100, 6, "1e+100" },
        .{ 5.0e-324, 6, "4.94066e-324" },
        .{ 1.7976931348623157e308, 6, "1.79769e+308" },
        // Exact ties round to even.
        .{ 1.0000005, 7, "1.000001" },
        .{ 2.5, 1, "2" },
        .{ 0.125, 2, "0.12" },
        .{ 0.1, 17, "0.10000000000000001" },
        .{ 100.0, 0, "1e+02" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case[2], formatG(&buf, case[0], case[1]));
    }
    try std.testing.expectEqualStrings("inf", formatG(&buf, std.math.inf(f64), 6));
    try std.testing.expectEqualStrings("-nan", formatG(&buf, -std.math.nan(f64), 6));
}
