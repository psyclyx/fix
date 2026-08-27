const std = @import("std");
const testing = std.testing;
const Engine = @import("../../evaluator.zig").Engine;
const disasm = @import("../../tooling/bytecode.zig").disasm;
const effects = @import("../../effects.zig");

/// One decoded disassembler line: the opcode name and its 0-based position
/// in the (depth-first, recursive) disassembly of `source`'s compiled
/// chunk graph. Lets tests assert on opcode-sequence ordering (e.g. "the
/// jump falls between the two operand pushes") without hand-decoding the
/// bytecode stream or pinning byte offsets.
const OpLine = struct { name: []const u8, index: usize };

/// Compile `source` with a fresh single-threaded `Engine`, recursively
/// disassemble every reachable chunk via the real disassembler, and split
/// the result into per-line opcode names in program order. The caller owns
/// the returned text buffer (`text`) and must free it; `lines` borrows from
/// it.
const Disassembly = struct {
    text: []u8,
    lines: []OpLine,

    fn deinit(self: *Disassembly, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
        allocator.free(self.text);
    }

    /// First line whose opcode is exactly `name`.
    fn find(self: *const Disassembly, name: []const u8) ?usize {
        for (self.lines) |line| {
            if (std.mem.eql(u8, line.name, name)) return line.index;
        }
        return null;
    }

    fn contains(self: *const Disassembly, name: []const u8) bool {
        return self.find(name) != null;
    }

    fn count(self: *const Disassembly, name: []const u8) usize {
        var total: usize = 0;
        for (self.lines) |line| if (std.mem.eql(u8, line.name, name)) {
            total += 1;
        };
        return total;
    }
};

fn disassemble(ev: *Engine, source: []const u8) !Disassembly {
    const chunk_id = try ev.compileSource(source, null);
    const target = ev.getChunk(chunk_id).?;
    const symbols = disasm.Symbols{ .intern = ev.internTable(), .registry = ev.chunkRegistry() };
    const options = disasm.Options{ .recurse = true, .max_depth = 16 };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disasm.writeChunk(testing.allocator, &out.writer, chunk_id, target, symbols, options);
    const text = try out.toOwnedSlice();
    errdefer testing.allocator.free(text);

    var lines: std.ArrayListUnmanaged(OpLine) = .empty;
    errdefer lines.deinit(testing.allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    var idx: usize = 0;
    while (it.next()) |raw_line| : (idx += 1) {
        // Every body line starts with the chunk left-margin guide "│ "; strip it.
        const line = if (std.mem.startsWith(u8, raw_line, "│ ")) raw_line["│ ".len..] else raw_line;
        // Instruction lines are "  xxxx  opname<spaces...>operands"; every
        // other line (headers, constants, blanks) starts differently.
        if (line.len < 8 or line[0] != ' ' or line[1] != ' ') continue;
        const hex = line[2..6];
        if (!std.mem.eql(u8, line[6..8], "  ")) continue;
        var hex_ok = true;
        for (hex) |c| {
            if (!std.ascii.isHex(c)) hex_ok = false;
        }
        if (!hex_ok) continue;
        const rest = std.mem.trimStart(u8, line[8..], " ");
        const name_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        try lines.append(testing.allocator, .{ .name = rest[0..name_end], .index = idx });
    }
    return .{ .text = text, .lines = try lines.toOwnedSlice(testing.allocator) };
}

test "compileBinary emits the runtime add opcode for non-literal operands" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // Locals (lambda params), not literals, so the `+` can't constant-fold
    // — the runtime `int_add` opcode must actually be emitted.
    var d = try disassemble(&ev, "a: b: a + b");
    defer d.deinit(testing.allocator);
    try testing.expect(d.contains("int_add"));
}

test "compileBinary emits the runtime sub/mul/div opcodes for non-literal operands" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    var sub_d = try disassemble(&ev, "a: b: a - b");
    defer sub_d.deinit(testing.allocator);
    try testing.expect(sub_d.contains("int_sub"));

    var mul_d = try disassemble(&ev, "a: b: a * b");
    defer mul_d.deinit(testing.allocator);
    try testing.expect(mul_d.contains("int_mul"));

    var div_d = try disassemble(&ev, "a: b: a / b");
    defer div_d.deinit(testing.allocator);
    try testing.expect(div_d.contains("int_div"));
}

test "compileBinary emits comparison opcodes for non-literal operands" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    var lt_d = try disassemble(&ev, "a: b: a < b");
    defer lt_d.deinit(testing.allocator);
    try testing.expect(lt_d.contains("cmp_lt"));

    var eq_d = try disassemble(&ev, "a: b: a == b");
    defer eq_d.deinit(testing.allocator);
    try testing.expect(eq_d.contains("cmp_eq"));
}

test "fully applied operator-equivalent builtins lower to VM opcodes" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const cases = [_]struct { source: []const u8, opcode: []const u8 }{
        .{ .source = "a: b: builtins.sub a b", .opcode = "int_sub" },
        .{ .source = "a: b: builtins.mul a b", .opcode = "int_mul" },
        .{ .source = "a: b: builtins.div a b", .opcode = "int_div" },
        .{ .source = "a: b: builtins.lessThan a b", .opcode = "cmp_lt" },
        .{ .source = "s: builtins.getAttr \"x\" s", .opcode = "loc_get_attr" },
        .{ .source = "s: builtins.hasAttr \"x\" s", .opcode = "attr_has_strict" },
    };
    for (cases) |case| {
        var d = try disassemble(&ev, case.source);
        defer d.deinit(testing.allocator);
        try testing.expect(d.contains(case.opcode));
        try testing.expect(!d.contains("call_n"));
        try testing.expect(!d.contains("call_tail_n"));
        try testing.expect(!d.contains("push_builtins"));
    }
}

test "builtin opcode lowering requires saturation and the global builtins set" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    var partial = try disassemble(&ev, "builtins.sub 1");
    defer partial.deinit(testing.allocator);
    try testing.expect(partial.contains("push_builtins"));
    try testing.expect(partial.contains("call") or partial.contains("call_tail"));

    var shadowed = try disassemble(&ev, "let builtins = { sub = a: b: 42; }; in builtins.sub 1 2");
    defer shadowed.deinit(testing.allocator);
    try testing.expect(shadowed.contains("call_n") or shadowed.contains("call_tail_n"));
    try testing.expect(!shadowed.contains("int_sub"));
}

test "inherit-from group compiles one shared source thunk" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    var d = try disassemble(&ev, "let inherit (builtins.trace \"once\" { a = 1; b = 2; }) a b; in a + b");
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), d.count("thunk_attr"));
    // The source application exists in one child chunk, not one clone per
    // inherited name.
    try testing.expectEqual(@as(usize, 1), d.count("push_builtins"));
}

test "static literal selection skips attrset construction" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    var selected = try disassemble(&ev, "({ a = 1; b = builtins.throw \"unused\"; }).a");
    defer selected.deinit(testing.allocator);
    try testing.expect(!selected.contains("attrs_new"));
    try testing.expect(!selected.contains("attrs_new_srt"));
    try testing.expect(!selected.contains("attrs_new_named_srt"));
    try testing.expect(!selected.contains("attr_get"));
    try testing.expect(!selected.contains("push_builtins"));

    var nested = try disassemble(&ev, "({ a = { b = 2; c = 3; }; x = 4; }).a.b");
    defer nested.deinit(testing.allocator);
    try testing.expect(!nested.contains("attrs_new"));
    try testing.expect(!nested.contains("attr_get"));

    // Dynamic keys and recursive sets keep the general construction path.
    var dynamic = try disassemble(&ev, "name: ({ ${name} = 1; a = 2; }).a");
    defer dynamic.deinit(testing.allocator);
    try testing.expect(dynamic.contains("attrs_new"));
    var recursive = try disassemble(&ev, "(rec { a = 1; }).a");
    defer recursive.deinit(testing.allocator);
    try testing.expect(recursive.contains("attrs_new_named_srt") or recursive.contains("attrs_new_named_pos_srt"));
}

test "static literal membership emits a boolean without member code" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    var present = try disassemble(&ev, "({ a = builtins.throw \"unused\"; } ? a)");
    defer present.deinit(testing.allocator);
    try testing.expect(present.contains("push_true"));
    try testing.expect(!present.contains("attr_has_path"));
    try testing.expect(!present.contains("push_builtins"));

    var missing = try disassemble(&ev, "({ a = 1; } ? b)");
    defer missing.deinit(testing.allocator);
    try testing.expect(missing.contains("push_false"));
    try testing.expect(!missing.contains("attr_has_path"));
}

test "repeated constants share one chunk-pool index" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    var d = try disassemble(&ev, "x: x + 7 + 7");
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), d.count("push_const"));
    try testing.expect(std.mem.indexOf(u8, d.text, "push_const #0") != null);
    try testing.expect(std.mem.indexOf(u8, d.text, "push_const #1") == null);
}

test "empty containers lower to shared singleton constants" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    var attrs = try disassemble(&ev, "{}");
    defer attrs.deinit(testing.allocator);
    try testing.expect(attrs.contains("push_const_ret"));
    try testing.expect(!attrs.contains("attrs_new"));
    try testing.expect(!attrs.contains("attrs_new_srt"));

    var list = try disassemble(&ev, "[]");
    defer list.deinit(testing.allocator);
    try testing.expect(list.contains("push_const_ret"));
    try testing.expect(!list.contains("list_new"));

    // Repeated empties reuse the same two constant-pool entries; the outer
    // populated list is the only runtime container construction.
    var repeated = try disassemble(&ev, "[ {} {} [] [] ]");
    defer repeated.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, repeated.text, "2 consts") != null);
    try testing.expectEqual(@as(usize, 4), repeated.count("push_const"));
    try testing.expectEqual(@as(usize, 1), repeated.count("list_new"));
}

test "right-associated list concatenation lowers to one n-ary opcode" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    var chain = try disassemble(&ev, "a: b: c: a ++ b ++ c");
    defer chain.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), chain.count("list_cat_n"));
    try testing.expectEqual(@as(usize, 0), chain.count("list_cat"));

    // Explicit left grouping retains its two binary operations: flattening it
    // would change when the first concatenation's type error is observed.
    var grouped = try disassemble(&ev, "a: b: c: (a ++ b) ++ c");
    defer grouped.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), grouped.count("list_cat_n"));
    try testing.expectEqual(@as(usize, 2), grouped.count("list_cat"));
}

test "compileBinary folds literal-on-literal arithmetic to a constant instead of emitting an opcode" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    var d = try disassemble(&ev, "1 + 2");
    defer d.deinit(testing.allocator);
    try testing.expect(!d.contains("int_add"));
    try testing.expect(d.contains("push_const") or d.contains("push_const_ret"));
}

test "compileAnd emits a jump strictly between the two operand pushes" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // Uncurried two-param lambda: both `a` and `b` compile to `loc_get`
    // reads in one chunk, so the two occurrences bracket the jump.
    var d = try disassemble(&ev, "a: b: a && b");
    defer d.deinit(testing.allocator);

    const jump_line = d.find("jump_false").?;
    var first_local: ?usize = null;
    var second_local: ?usize = null;
    for (d.lines) |line| {
        if (!std.mem.eql(u8, line.name, "loc_get")) continue;
        if (first_local == null) {
            first_local = line.index;
        } else if (second_local == null) {
            second_local = line.index;
        }
    }
    try testing.expect(first_local.? < jump_line);
    try testing.expect(jump_line < second_local.?);
}

test "compileOr emits a jump strictly between the two operand pushes" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    var d = try disassemble(&ev, "a: b: a || b");
    defer d.deinit(testing.allocator);

    const false_jump_line = d.find("jump_false").?;
    const end_jump_line = d.find("jump").?;
    try testing.expect(false_jump_line < end_jump_line);

    var first_local: ?usize = null;
    var second_local: ?usize = null;
    for (d.lines) |line| {
        if (!std.mem.eql(u8, line.name, "loc_get")) continue;
        if (first_local == null) {
            first_local = line.index;
        } else if (second_local == null) {
            second_local = line.index;
        }
    }
    // Left operand precedes both jumps; right operand follows both.
    try testing.expect(first_local.? < false_jump_line);
    try testing.expect(end_jump_line < second_local.?);
}

test "&& never evaluates its right-hand side when the left side is false" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // If `1/0` were evaluated, this would raise DivisionByZero.
    const v = try ev.evaluate("false && (1 / 0 == 0)");
    try testing.expect(v.isBool());
    try testing.expect(!v.asBool());
}

test "|| never evaluates its right-hand side when the left side is true" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const v = try ev.evaluate("true || (1 / 0 == 0)");
    try testing.expect(v.isBool());
    try testing.expect(v.asBool());
}

test "&& does evaluate its right-hand side when the left side is true" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try testing.expectError(error.DivisionByZero, ev.evaluate("true && (1 / 0 == 0)"));
}

test "|| does evaluate its right-hand side when the left side is false" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try testing.expectError(error.DivisionByZero, ev.evaluate("false || (1 / 0 == 0)"));
}

test "compileLambda and compileLambdaAttrs produce different chunk shapes" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    var value_lambda = try disassemble(&ev, "x: x");
    defer value_lambda.deinit(testing.allocator);
    var attrs_lambda = try disassemble(&ev, "{ x }: x");
    defer attrs_lambda.deinit(testing.allocator);

    // Only the attrset-pattern lambda validates its argument shape.
    try testing.expect(!value_lambda.contains("attr_bind"));
    try testing.expect(attrs_lambda.contains("attr_bind"));

    // Both compile to a top-level closure creation over a nested body chunk.
    try testing.expect(value_lambda.contains("closure"));
    try testing.expect(attrs_lambda.contains("closure"));
}

test "applying a non-callable value raises NotCallable instead of panicking" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try testing.expectError(error.NotCallable, ev.evaluate("(1) 2"));
}

test "duplicate let bindings raise a parse error instead of panicking" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try testing.expectError(error.ParseError, ev.evaluate("let x = 1; x = 2; in x"));
}

test "scope nesting past a byte's range compiles instead of wrapping the depth counter" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // Every `with` body opens a lexical scope, and Nix nests them without a
    // ceiling. When `scope_depth` was a u8 the 256th increment overflowed
    // (Debug) or wrapped, leaving `endScope` popping locals against a bogus
    // depth (ReleaseFast).
    const deep = try ev.evaluate("with { a = 1; }; " ** 300 ++ "42");
    try testing.expectEqual(@as(i64, 42), deep.asInt());
    // Resolving a name THROUGH the chain is bounded separately — `with_lookup`
    // encodes its scope count in one byte — and must stay a clean error.
    try testing.expectError(error.TooManyWithScopes, ev.evaluate("with { a = 1; }; " ** 256 ++ "a"));
}

test "dynamic-name bindings move only within an unchanged with-chain" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // `x = v` resolves v through the OUTER with. Its use inside the inner
    // `with { v = 2; }` must NOT inline the bare `v` there (it would read
    // the inner scope): fix must agree with Nix's 1, not 2. Regression for
    // the with-mark log-clock bug (a with body with no binders was
    // invisible to the crossing check).
    const crossed = try ev.evaluate("with { v = 1; }; let x = v; in (with { v = 2; }; x)");
    try testing.expectEqual(@as(i64, 1), crossed.asInt());
    // Within the SAME with-chain the binding is free to move (sink/inline):
    // same value at both positions.
    const same_chain = try ev.evaluate("with { v = 5; }; let x = v; in x + x");
    try testing.expectEqual(@as(i64, 10), same_chain.asInt());
}

test "strict prefix continues through a saturated call to a sibling lambda" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // `f`'s body demands y (the parameter) — the callee-aware prefix
    // eagerizes `y` at the header. Observable soundness guarantees: a
    // parameter the body does NOT force stays lazy (no throw), and error
    // order under tryEval follows body demand order.
    const unforced = try ev.evaluate("let f = x: y: y; a = builtins.throw \"A\"; b = 2; in f a b");
    try testing.expectEqual(@as(i64, 2), unforced.asInt());
    const order = try ev.evaluate("(builtins.tryEval (let f = x: y: x - y; a = builtins.throw \"A\"; b = 1 / 0; in f a b)).success");
    try testing.expect(!order.asBool());
}

test "alias inlining then sinking cannot capture a rebinding of the alias target" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // Regression (found by the nixpkgs differential, build-rust-crate shape):
    // pass A rewrites `x_` inside `o`'s RHS to a fresh `x` identifier; pass B
    // then sinks single-use `o` into the inner let, where `x` is REBOUND.
    // Without folding the alias target into `o`'s free-name set, the sink's
    // shadow check tested the stale `x_` and created a recursive knot
    // (`x = x + 1`) — a false RecursiveThunk.
    const v = try ev.evaluate("(x: let x_ = x; o = x_ + 1; in let x = o; in x) 5");
    try testing.expectEqual(@as(i64, 6), v.asInt());
}

// ---- let lowering characterization: laziness, sharing, error ordering -----
//
// Guardrails for an upcoming let-optimization pass: these lock down
// OBSERVABLE semantics (values, error identity, trace counts) rather than
// bytecode shapes, so the pass is free to change codegen as long as none of
// these regress.

/// Records `builtins.trace`/`builtins.warn` effects via `Engine.setEffectSink`
/// (mirrors `EffectCapture` in `eval/tests/builtin_errors.zig`) so a test can
/// assert an effect fired a specific number of times, not just that the
/// final value looks right.
const EffectCapture = struct {
    count: usize = 0,
    lengths: [8]usize = undefined,
    messages: [8][128]u8 = undefined,

    fn emit(raw: ?*anyopaque, _: effects.Kind, text: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (self.count == self.messages.len or text.len > self.messages[0].len)
            @panic("effect capture overflow");
        self.lengths[self.count] = text.len;
        @memcpy(self.messages[self.count][0..text.len], text);
        self.count += 1;
    }

    fn message(self: *const @This(), index: usize) []const u8 {
        return self.messages[index][0..self.lengths[index]];
    }
};

test "a let binding referenced twice in the body is forced once and shared" {
    var capture: EffectCapture = .{};
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setEffectSink(.{ .context = &capture, .emit_fn = EffectCapture.emit });

    const result = try ev.evaluate("let x = builtins.trace \"eval-x\" (1 + 1); in x + x");
    try testing.expectEqual(@as(i64, 4), result.asInt());
    try testing.expectEqual(@as(usize, 1), capture.count);
    try testing.expectEqualStrings("eval-x", capture.message(0));
}

test "a let binding captured by a closure is shared across separate calls" {
    var capture: EffectCapture = .{};
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setEffectSink(.{ .context = &capture, .emit_fn = EffectCapture.emit });

    // `x` is captured (not re-evaluated) by every call to `f`; only the
    // argument varies per call.
    const result = try ev.evaluate("let x = builtins.trace \"once\" 5; f = y: x + y; in f 1 + f 2");
    try testing.expectEqual(@as(i64, 13), result.asInt());
    try testing.expectEqual(@as(usize, 1), capture.count);
}

test "an unused let binding is never forced even though it would error" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("let x = builtins.throw \"boom\"; in 42");
    try testing.expectEqual(@as(i64, 42), result.asInt());
}

test "the untaken branch of an if inside a let body stays unforced" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("let x = builtins.throw \"boom\"; in if true then 1 else x");
    try testing.expectEqual(@as(i64, 1), result.asInt());
}

test "tryEval catches an eagerly thrown left operand ahead of a lazy division error on the right" {
    // `+` forces its left operand before its right operand, so the throw
    // (from a plain let binding, not a dotted/merged group) wins the race
    // against the division error latent in `x` — matches Lix/Nix.
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const success = try ev.evaluate("let x = 1 / 0; in (builtins.tryEval ((builtins.throw \"t\") + x)).success");
    try testing.expect(success.isBool());
    try testing.expect(!success.asBool());

    // The whole evaluation must not abort with DivisionByZero either —
    // tryEval's catch has to run before `x` is ever forced.
    _ = try ev.evaluate("let x = 1 / 0; in builtins.tryEval ((builtins.throw \"t\") + x)");
}

test "an alias binding shares evaluation with the name it aliases" {
    var capture: EffectCapture = .{};
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setEffectSink(.{ .context = &capture, .emit_fn = EffectCapture.emit });

    const result = try ev.evaluate("let x = builtins.trace \"v\" 7; y = x; in y + x + y");
    try testing.expectEqual(@as(i64, 21), result.asInt());
    try testing.expectEqual(@as(usize, 1), capture.count);
}

test "nested lambda parameters shadow same-named outer let bindings entirely" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // Both `y` and `x` are re-bound by `f`'s own parameters, so the body
    // resolves to the innermost params (2 + 3), never touching the outer
    // `y = 1;`/`x = 100;` let bindings.
    const result = try ev.evaluate("let y = 1; f = (y: x: x + y); x = 100; in f 2 3");
    try testing.expectEqual(@as(i64, 5), result.asInt());
}

test "a plain let binding may forward-reference a sibling defined later" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("let b = a + 1; a = 1; in b");
    try testing.expectEqual(@as(i64, 2), result.asInt());
}

test "an inherit-from source shared by two names is evaluated exactly once" {
    // Complements "inherit-from group compiles one shared source thunk"
    // above (a bytecode-shape assertion) with the observable effect: the
    // shared source thunk's side effect fires once, not once per name.
    var capture: EffectCapture = .{};
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setEffectSink(.{ .context = &capture, .emit_fn = EffectCapture.emit });

    const result = try ev.evaluate("let inherit (builtins.trace \"src\" { a = 1; b = 2; }) a b; in a + b");
    try testing.expectEqual(@as(i64, 3), result.asInt());
    try testing.expectEqual(@as(usize, 1), capture.count);
    try testing.expectEqualStrings("src", capture.message(0));
}

test "a name split across two dotted let-binding statements merges into one attrset" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("let a.x = 1; a.y = 2; in a.x + a.y");
    try testing.expectEqual(@as(i64, 3), result.asInt());
}

test "a lexically bound name takes priority over an enclosing with" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("let x = 1; in with { x = 2; }; x");
    try testing.expectEqual(@as(i64, 1), result.asInt());
}

test "a with-introduced name is visible inside a nested let's bindings" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("with { z = 5; }; let q = z; in q");
    try testing.expectEqual(@as(i64, 5), result.asInt());
}

test "a let binding captured by a mapped lambda is forced once, not once per element" {
    var capture: EffectCapture = .{};
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setEffectSink(.{ .context = &capture, .emit_fn = EffectCapture.emit });

    const result = try ev.evaluate("let c = builtins.trace \"c\" 3; in map (i: c + i) [1 2 3]");
    try ev.forceDeep(result);
    try testing.expectEqual(@as(usize, 1), capture.count);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try ev.writeValue(&out.writer, result);
    const rendered = try out.toOwnedSlice();
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("[ 4 5 6 ]", rendered);
}

test "tryEval catches a throw reached by forcing a let body" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const success = try ev.evaluate("(builtins.tryEval (let x = builtins.throw \"x\"; in x + 1)).success");
    try testing.expect(success.isBool());
    try testing.expect(!success.asBool());
}

test "tryEval catches a throw reached only by demanding an unused-looking let binding" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const success = try ev.evaluate("let x = builtins.throw \"x\"; in (builtins.tryEval x).success");
    try testing.expect(success.isBool());
    try testing.expect(!success.asBool());
}

// ---- let-float bytecode-shape tests ----------------------------------
//
// `let_float.zig` rewrites a `let` before lowering (dead-binding cascade,
// literal/alias inlining, single-use sinking, branch-local floating,
// nested-let flattening); `let.zig`'s strict-prefix eager elision then
// evaluates provably-forced bindings straight into their slots. These lock
// down the resulting bytecode SHAPES the two passes are meant to produce
// (no binding thunk where one is proven unnecessary), complementing the
// observable-semantics guardrails above.

/// True when any thunk-creating opcode (`thunk`, `thunk_w`, `thunk_st`,
/// `thunk_st_cell`, `thunk_w_st`, `thunk_w_st_cell`, `thunk_attr`,
/// `thunk_attr_w`, `thunk_arg`, `thunk_shell`) appears anywhere in the
/// disassembly — every one of these names starts with "thunk".
fn anyThunkOp(d: *const Disassembly) bool {
    for (d.lines) |line| {
        if (std.mem.startsWith(u8, line.name, "thunk")) return true;
    }
    return false;
}

test "let-float sinks a single-use binding to its use site, eliding its thunk entirely" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // `b` has exactly one live use (`x + b`) in an at-most-once region, so
    // single-use sinking moves its RHS straight to the use site: no binding
    // slot, no thunk, just the multiply feeding the add.
    var d = try disassemble(&ev, "x: let b = x * 2; in x + b");
    defer d.deinit(testing.allocator);
    try testing.expect(!anyThunkOp(&d));
    try testing.expect(d.contains("int_mul"));
    try testing.expect(d.contains("int_add"));
}

test "let-float's strict prefix collapses a multi-use dependency chain to zero thunks" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // `a` is used twice (by `b`'s RHS and the body), so it can't sink and
    // must keep a real slot — but `b` itself has exactly ONE live use in
    // the body, so single-use sinking claims it before the strict prefix
    // ever considers it: `b`'s RHS moves straight to its use site instead
    // of getting its own slot. Net effect either way is the same: `a`
    // evaluates eagerly into its slot, `b`'s multiply happens inline at the
    // `+`, and nothing is ever thunked.
    var d = try disassemble(&ev, "x: let a = x + 1; b = a * 2; in a + b");
    defer d.deinit(testing.allocator);
    try testing.expect(!anyThunkOp(&d));
    try testing.expect(d.contains("int_add"));
    try testing.expect(d.contains("int_mul"));
    try testing.expectEqual(@as(usize, 1), d.count("loc_set"));
}

test "let-float leaves runtime-adaptive thunk_arg in place for a dynamic-dispatch chain" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // `f` is an unresolved parameter, so `f input`/`f a`/`f b` are all
    // dynamic calls: their arguments lower to `thunk_arg` (the runtime picks
    // eager-vs-lazy per call), but no binding ever gets an unconditional
    // `thunk`/`thunk_st` — the calls themselves gate everything.
    var d = try disassemble(&ev, "f: input: let a = f input; b = f a; in f b");
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), d.count("thunk_st"));
    try testing.expectEqual(@as(usize, 0), d.count("thunk"));
    try testing.expectEqual(@as(usize, 0), d.count("thunk_w"));
    try testing.expect(d.contains("thunk_arg"));
}

test "let-float collapses an alias binding into its target with no separate slot" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // `y = x;` is a duplicable alias: every use of `y` is replaced by a
    // fresh read of `x` instead of getting its own binding slot. Only `x`'s
    // computation is ever stored (one `loc_set`); all three consuming reads
    // (`y`, `y`, `x`) read that same slot.
    var d = try disassemble(&ev, "let x = builtins.length [ 1 2 ]; y = x; in y + y + x");
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), d.count("loc_set"));
    try testing.expectEqual(@as(usize, 3), d.count("loc_get"));
}

test "let-float drops a dead-binding cascade entirely" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // `a` is only referenced by the dead `b`, so both drop from the
    // compiled chunk: the body reduces to the bare literal, no thunk survives.
    var d = try disassemble(&ev, "let a = builtins.throw \"a\"; b = a + 1; in 42");
    defer d.deinit(testing.allocator);
    try testing.expect(!anyThunkOp(&d));

    const result = try ev.evaluate("let a = builtins.throw \"a\"; b = a + 1; in 42");
    try testing.expectEqual(@as(i64, 42), result.asInt());
}

test "let-float inlines a literal binding across a lambda boundary, leaving no capture" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // `y = 1;` is a literal: every use, including one inside the nested
    // lambda `x: x + y`, is replaced by a fresh copy of the literal. The
    // inner chunk therefore captures nothing — no upvalue list, no
    // `closure_cap`, no `up_get` — it's a plain zero-capture `closure`.
    var d = try disassemble(&ev, "let y = 1; in x: x + y");
    defer d.deinit(testing.allocator);
    try testing.expect(d.contains("closure"));
    try testing.expect(!d.contains("closure_cap"));
    try testing.expect(!d.contains("up_get"));
}

test "let-float floats a branch-local binding so its slot is set only inside the taken branch" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // Every live use of `x` sits under the `then` branch, so it floats into
    // a synthetic let wrapping that branch: its slot is filled strictly
    // after the `jump_false` that skips the branch entirely. (`x` mentions
    // the param `c`, so full laziness leaves it inside the lambda — a
    // param-independent RHS would float past the lambda entirely.)
    var d = try disassemble(&ev, "c: let x = builtins.length [ c ]; in if c then x + x else 0");
    defer d.deinit(testing.allocator);
    const jump_line = d.find("jump_false").?;
    const set_line = d.find("loc_set").?;
    try testing.expect(jump_line < set_line);
}

test "let-float's branch-local float never evaluates the untaken branch's binding, and evaluates the taken one exactly once" {
    var capture: EffectCapture = .{};
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setEffectSink(.{ .context = &capture, .emit_fn = EffectCapture.emit });

    const source = "c: let x = builtins.trace \"hit\" 5; in if c then x + x else 0";

    const off = try ev.evaluate("(" ++ source ++ ") false");
    try testing.expectEqual(@as(i64, 0), off.asInt());
    try testing.expectEqual(@as(usize, 0), capture.count);

    const on = try ev.evaluate("(" ++ source ++ ") true");
    try testing.expectEqual(@as(i64, 10), on.asInt());
    try testing.expectEqual(@as(usize, 1), capture.count);
}

test "let-float flattens a nested let so a cross-let strict prefix collapses to zero thunks" {
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    // `let a = …; in let b = …; in a + b` merges into one cluster: `a` and
    // `b` join a single strict prefix spanning both original let levels,
    // same as the single-level chain above.
    var d = try disassemble(&ev, "x: let a = x + 1; in let b = a * 2; in a + b");
    defer d.deinit(testing.allocator);
    try testing.expect(!anyThunkOp(&d));
    try testing.expect(d.contains("int_add"));
    try testing.expect(d.contains("int_mul"));
}

test "strict-prefix validation demotes a binding referenced before its slot is filled instead of false-blackholing (regression)" {
    // HEAD bug: `l`'s RHS forward-references `r`, which is itself defined
    // AFTER `p` (whose RHS references `l`). A naive strict prefix could try
    // to evaluate `l` into its slot before `r`'s slot is filled, or emit `l`
    // and `p` in an order that reads an unset slot — either way raising a
    // spurious RecursiveThunk. Validation must demote any member whose
    // dependency isn't provably ready in slot order, falling back to lazy
    // thunks so the answer matches ordinary lazy evaluation.
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("let l = r + 1; p = l + 2; r = 5 + 5; in p");
    try testing.expectEqual(@as(i64, 13), result.asInt());
}

test "let-float does not sink a binding whose use sits inside a shadowing inner lambda" {
    // `x`'s only use is inside `(y: x + y) 5`, which rebinds `y` — a name
    // free in NOTHING here, but the sink safety check still must not move
    // `x` across a lambda boundary that could shadow one of ITS free names.
    // This is a guardrail: the outer `y` and `x` must keep evaluating to the
    // right values regardless of how the optimizer places them.
    var ev = try Engine.init(testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const result = try ev.evaluate("let y = 1; x = y + 1; in (y: x + y) 5");
    try testing.expectEqual(@as(i64, 7), result.asInt());
}
