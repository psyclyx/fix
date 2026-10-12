const std = @import("std");
const eval_mod = @import("../../evaluator.zig");
const Engine = eval_mod.Engine;
const Diagnostic = eval_mod.Diagnostic;
const Value = @import("runtime").value.Value;
const path_ops = @import("runtime").paths;
const helpers = @import("../test_helpers.zig");
const renderForTest = helpers.renderForTest;
const renderStrictForTest = helpers.renderStrictForTest;
const renderForTestFromCurrentPath = helpers.renderForTestFromCurrentPath;
const renderXmlForTest = helpers.renderXmlForTest;

test "finishing evaluation is terminal" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    ev.finishEvaluation();
    try std.testing.expectError(error.EvaluationFinished, ev.evaluate("1"));
    ev.deinit();
}

test "inspection evaluation retains its entry chunk" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const result = try ev.evaluateWithScopeResult("1 + 2", null);
    try std.testing.expectEqual(@as(i64, 3), result.value.asInt());
    try std.testing.expect(ev.getChunk(result.entry_chunk) != null);
}

test "build transition runs its explicit post-release action once" {
    const Counter = struct {
        value: usize = 0,

        fn run(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.value += 1;
        }
    };
    var counter: Counter = .{};
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    var session = try ev.beginBuildPhase(&.{}, .{ .context = &counter, .run = Counter.run });
    session.deinit();
    ev.deinit();
    try std.testing.expectEqual(@as(usize, 1), counter.value);
}

test "parallel top-level evaluation uses one demand fiber per ordered input" {
    const Capture = struct {
        values: [3]?Value = .{ null, null, null },
        fibers: [3]usize = .{ 0, 0, 0 },
        errors: [3]?anyerror = .{ null, null, null },

        fn complete(raw: *anyopaque, index: usize, value: ?Value, failure: ?Engine.ParallelFailure) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.values[index] = value;
            self.errors[index] = if (failure) |failed| failed.err else null;
            self.fibers[index] = @intFromPtr(@import("base").fiber.currentFiber().?);
        }
    };

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 4 });
    defer ev.deinit();
    var capture: Capture = .{};
    ev.evaluatePathsParallel(&.{
        .{ .source = "11" },
        .{ .source = "22" },
        .{ .source = "33" },
    }, .{ .context = &capture, .complete_fn = Capture.complete });

    for (capture.errors) |err| try std.testing.expect(err == null);
    try std.testing.expectEqual(@as(i64, 11), capture.values[0].?.asInt());
    try std.testing.expectEqual(@as(i64, 22), capture.values[1].?.asInt());
    try std.testing.expectEqual(@as(i64, 33), capture.values[2].?.asInt());
    try std.testing.expect(capture.fibers[0] != capture.fibers[1]);
    try std.testing.expect(capture.fibers[1] != capture.fibers[2]);
    try std.testing.expect(capture.fibers[0] != capture.fibers[2]);
}

test "parallel top-level failures retain isolated Nix error traces" {
    const Capture = struct {
        messages: [2][32]u8 = .{ undefined, undefined },
        lengths: [2]usize = .{ 0, 0 },

        fn complete(raw: *anyopaque, index: usize, _: ?Value, failure: ?Engine.ParallelFailure) void {
            const failed = failure orelse return;
            const self: *@This() = @ptrCast(@alignCast(raw));
            const message = failed.trace.message orelse return;
            self.lengths[index] = @min(message.len, self.messages[index].len);
            @memcpy(self.messages[index][0..self.lengths[index]], message[0..self.lengths[index]]);
        }
    };

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 4 });
    defer ev.deinit();
    var capture: Capture = .{};
    ev.evaluatePathsParallel(&.{
        .{ .source = "builtins.throw \"first input failed\"" },
        .{ .source = "builtins.throw \"second input failed\"" },
    }, .{ .context = &capture, .complete_fn = Capture.complete });

    try std.testing.expectEqualStrings("first input failed", capture.messages[0][0..capture.lengths[0]]);
    try std.testing.expectEqualStrings("second input failed", capture.messages[1][0..capture.lengths[1]]);
}

test "external scope construction and rooting is evaluator-owned" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const scope = try ev.replaceExternalScope(&.{
        .{ .name = "answer", .value = Value.int(41) },
    });
    const result = try ev.evaluateWithScope("answer + 1", scope);
    try std.testing.expectEqual(@as(i64, 42), result.asInt());
}

test "unused external scopes do not make duplicate entry chunks" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const first_scope = try ev.replaceExternalScope(&.{
        .{ .name = "answer", .value = Value.int(1) },
    });
    const first = try ev.evaluateWithScopeResult("import", first_scope);
    const second_scope = try ev.replaceExternalScope(&.{
        .{ .name = "answer", .value = Value.int(2) },
    });
    const second = try ev.evaluateWithScopeResult("import", second_scope);

    try std.testing.expectEqual(first.entry_chunk, second.entry_chunk);
    try std.testing.expectEqual(@as(usize, 1), ev.getChunk(first.entry_chunk).?.constants.len);
}

test "referenced external scopes remain distinct chunk constants" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();

    const first_scope = try ev.replaceExternalScope(&.{
        .{ .name = "answer", .value = Value.int(41) },
    });
    const first = try ev.evaluateWithScopeResult("answer + 1", first_scope);
    const second_scope = try ev.replaceExternalScope(&.{
        .{ .name = "answer", .value = Value.int(42) },
    });
    const second = try ev.evaluateWithScopeResult("answer + 1", second_scope);

    try std.testing.expectEqual(@as(i64, 42), first.value.asInt());
    try std.testing.expectEqual(@as(i64, 43), second.value.asInt());
    try std.testing.expect(first.entry_chunk != second.entry_chunk);
}

test "writeValue colorizes strings, numbers, keywords, and attr names when value_color is set" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setValueColor(true);
    const result = try ev.evaluate("{ n = 1; s = \"x\"; b = true; }");
    try ev.forceDeep(result);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try ev.writeValue(&out.writer, result);
    const text = out.written();
    // Attr names cyan (36), numbers yellow (33), strings green (32), true magenta (35).
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[36mn\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[33m1\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[32m\"x\"\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b[35mtrue\x1b[0m") != null);
}

test "writeValue prints lazy containers without forcing contents" {
    const list_output = try renderForTest("[ 1 (1 / 0) \"x\" ]");
    defer std.testing.allocator.free(list_output);
    try std.testing.expectEqualStrings("[ 1 <CODE> \"x\" ]", list_output);

    const attrs_output = try renderForTest("{ a = 1; b = 1 / 0; c = \"x\"; }");
    defer std.testing.allocator.free(attrs_output);
    try std.testing.expectEqualStrings("{ a = 1; b = <CODE>; c = \"x\"; }", attrs_output);
}

test "forceDeep recursively evaluates lazy containers" {
    const output = try renderStrictForTest("{ a = 1; b = [ 2 ]; c = \"x\"; }");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("{ a = 1; b = [ 2 ]; c = \"x\"; }", output);

    try std.testing.expectError(error.DivisionByZero, renderStrictForTest("{ a = 1; b = 1 / 0; }"));
}

test "forceDeep handles recursive containers without hiding recursive thunks" {
    const repeated = try renderStrictForTest("let x = rec { a = x; }; in x");
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqualStrings("{ a = «repeated»; }", repeated);

    try std.testing.expectError(error.RecursiveThunk, renderStrictForTest("rec { a = a; b = 1; }"));
}

test "writeValue prints recursive attrsets without looping" {
    const output = try renderForTest("rec { a = a; b = 1; }");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("{ a = «repeated»; b = 1; }", output);
}

test "writeValue prints derivations as drv paths" {
    const output = try renderForTest("builtins.derivation { name = \"pkg\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; }");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("/nix/store/s8l8ca4j8fb6d94205514xd6wf9b57ng-pkg.drv", output);
}

test "writeXmlValue prints lazy containers without forcing contents" {
    const attrs_output = try renderXmlForTest("{ a = 1; b = 1 / 0; c = \"x\"; d = []; e = [ 1 ]; f = { x = 1; }; }");
    defer std.testing.allocator.free(attrs_output);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"a\">\n      <int value=\"1\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"b\">\n      <unevaluated />") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"c\">\n      <string value=\"x\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"d\">\n      <list>") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"e\">\n      <unevaluated />") != null);
    try std.testing.expect(std.mem.indexOf(u8, attrs_output, "<attr name=\"f\">\n      <unevaluated />") != null);
}

test "writeXmlValue prints resolved lazy children" {
    const output = try renderXmlForTest("let xs = [ 1 (1 / 0) ]; in builtins.seq (builtins.elemAt xs 0) xs");
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "<int value=\"1\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<unevaluated />") != null);
}

test "evaluate recursive dynamic attrsets" {
    const dynamic = try renderForTest("rec { a = 1; ${\"x\"} = a + 1; }.x");
    defer std.testing.allocator.free(dynamic);
    try std.testing.expectEqualStrings("2", dynamic);

    const dynamic_or_missing_prefix = try renderForTest("let switch = { kindFallback = \"ignore\"; }; kind = \"broken\"; in switch.kindSpecific.${kind} or switch.kindFallback");
    defer std.testing.allocator.free(dynamic_or_missing_prefix);
    try std.testing.expectEqualStrings("\"ignore\"", dynamic_or_missing_prefix);
}

test "evaluate matches Nix toString bool and null semantics" {
    const true_output = try renderForTest("builtins.toString true");
    defer std.testing.allocator.free(true_output);
    try std.testing.expectEqualStrings("\"1\"", true_output);

    const false_output = try renderForTest("builtins.toString false");
    defer std.testing.allocator.free(false_output);
    try std.testing.expectEqualStrings("\"\"", false_output);

    const null_output = try renderForTest("builtins.toString null");
    defer std.testing.allocator.free(null_output);
    try std.testing.expectEqualStrings("\"\"", null_output);

    const nested_empty_list = try renderForTest("builtins.toString [ \"a\" [ ] \"b\" ]");
    defer std.testing.allocator.free(nested_empty_list);
    try std.testing.expectEqualStrings("\"a b\"", nested_empty_list);

    const nested_empty_string = try renderForTest("builtins.toString [ \"a\" [ \"\" ] \"b\" ]");
    defer std.testing.allocator.free(nested_empty_string);
    try std.testing.expectEqualStrings("\"a  b\"", nested_empty_string);
}

test "evaluate decodes common string escapes" {
    const output = try renderForTest("\"a\\nb\\t\\\"c\"");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("\"a\\nb\\t\\\"c\"", output);
}

test "evaluate compares strings lexically" {
    const output = try renderForTest("let b = \"b\"; a = \"a\"; in b > a");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("true", output);
}

test "evaluate fully applied operator-equivalent builtins" {
    const output = try renderForTest(
        \\builtins.toJSON [
        \\  (builtins.sub 9 4)
        \\  (builtins.mul 3 7)
        \\  (builtins.div 20 4)
        \\  (builtins.lessThan 2 3)
        \\  (builtins.getAttr "x" { x = 11; })
        \\  (builtins.hasAttr "x" { x = 1 / 0; })
        \\]
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("\"[5,21,5,true,11,true]\"", output);

    const shadowed = try renderForTest("let builtins = { sub = a: b: 42; }; in builtins.sub 9 4");
    defer std.testing.allocator.free(shadowed);
    try std.testing.expectEqualStrings("42", shadowed);
}

test "evaluate shared inherit-from sources in let plain and recursive sets" {
    const output = try renderForTest(
        \\builtins.toJSON [
        \\  (let inherit ({ a = 1; b = 2; }) a b; in a + b)
        \\  ({ inherit ({ a = 3; b = 4; }) a b; }.b)
        \\  (rec { inherit ({ a = c; b = 6; }) a b; c = 5; }.a)
        \\]
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("\"[3,4,5]\"", output);
}

test "evaluate static literal selection and membership lazily" {
    const output = try renderForTest(
        \\builtins.toJSON [
        \\  ({ a = 1; b = builtins.throw "unused"; }.a)
        \\  ({ a = { b = 2; c = builtins.throw "unused"; }; }.a.b)
        \\  ({ a = builtins.throw "unused"; } ? a)
        \\  ({ a = 1; } ? b)
        \\]
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("\"[1,2,true,false]\"", output);
}

test "evaluate checks attribute paths without forcing final value" {
    const present = try renderForTest("({ a.b = 1 / 0; } ? a.b)");
    defer std.testing.allocator.free(present);
    try std.testing.expectEqualStrings("true", present);

    const missing = try renderForTest("({ a = {}; } ? a.b)");
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("false", missing);

    const escaped_names = try renderForTest("builtins.toJSON [ (builtins.hasAttr \"\\n\" { \"\\n\" = 1; }) (builtins.getAttr \"\\\\\" { \"\\\\\" = 2; }) ({ \"\\r\" = 3; }.\"\\r\") ]");
    defer std.testing.allocator.free(escaped_names);
    try std.testing.expectEqualStrings("\"[true,2,3]\"", escaped_names);
}

test "evaluate simple attrset function parameters" {
    const output = try renderForTest("({ x, y }: x + y) { x = 1; y = 2; }");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("3", output);

    const lazy = try renderForTest("({ x }: 1) { x = 1 / 0; }");
    defer std.testing.allocator.free(lazy);
    try std.testing.expectEqualStrings("1", lazy);
}

test "evaluate attrset function defaults ellipsis and binding" {
    const defaulted = try renderForTest("({ x ? 2 }: x) { }");
    defer std.testing.allocator.free(defaulted);
    try std.testing.expectEqualStrings("2", defaulted);

    const extra = try renderForTest("({ x, ... }: x) { x = 1; y = 2; }");
    defer std.testing.allocator.free(extra);
    try std.testing.expectEqualStrings("1", extra);

    const bound_before = try renderForTest("(args@{ x }: args.x) { x = 3; }");
    defer std.testing.allocator.free(bound_before);
    try std.testing.expectEqualStrings("3", bound_before);

    const bound_after = try renderForTest("({ x }@args: args.x) { x = 4; }");
    defer std.testing.allocator.free(bound_after);
    try std.testing.expectEqualStrings("4", bound_after);

    const default_uses_bound_args = try renderForTest("({ a ? args.b or 1, ... }@args: a) { }");
    defer std.testing.allocator.free(default_uses_bound_args);
    try std.testing.expectEqualStrings("1", default_uses_bound_args);

    const trailing_comma = try renderForTest("({ a, b, }: a + b) { a = 1; b = 2; }");
    defer std.testing.allocator.free(trailing_comma);
    try std.testing.expectEqualStrings("3", trailing_comma);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(error.MissingAttribute, ev.evaluate("({ x }: 1) { }"));
    try std.testing.expectError(error.UnexpectedAttribute, ev.evaluate("({ x }: x) { x = 1; y = 2; }"));
}

test "evaluate dynamic attr paths with static tails" {
    const output = try renderForTest("let x = \"a\"; in ({ ${x}.b = 1; }).a.b");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("1", output);

    const dynamic_tail = try renderForTest("let x = \"a\"; y = \"b\"; in ({ ${x}.${y} = 2; }).a.b");
    defer std.testing.allocator.free(dynamic_tail);
    try std.testing.expectEqualStrings("2", dynamic_tail);

    const static_prefix = try renderForTest("let name = \"LD_LIBRARY_PATH\"; in { env.${name} = \"x\"; }.env.LD_LIBRARY_PATH");
    defer std.testing.allocator.free(static_prefix);
    try std.testing.expectEqualStrings("\"x\"", static_prefix);

    const static_prefix_tail = try renderForTest("let x = \"c\"; y = \"d\"; in { a.b.${x}.${y}.e = 3; }.a.b.c.d.e");
    defer std.testing.allocator.free(static_prefix_tail);
    try std.testing.expectEqualStrings("3", static_prefix_tail);

    const quoted_interpolation_tail = try renderForTest("let suffix = \"X\"; in builtins.toJSON { env.\"A_${suffix}\" = \"v\"; }");
    defer std.testing.allocator.free(quoted_interpolation_tail);
    try std.testing.expectEqualStrings("\"{\\\"env\\\":{\\\"A_X\\\":\\\"v\\\"}}\"", quoted_interpolation_tail);

    const quoted_interpolation_root = try renderForTest("let x = \"a\"; in ({ \"${x}\".b = 1; }).a.b");
    defer std.testing.allocator.free(quoted_interpolation_root);
    try std.testing.expectEqualStrings("1", quoted_interpolation_root);

    const quoted_interpolation_let_tail = try renderForTest("let x = \"b\"; a.\"${x}\" = 1; in a.b");
    defer std.testing.allocator.free(quoted_interpolation_let_tail);
    try std.testing.expectEqualStrings("1", quoted_interpolation_let_tail);

    const merged_static_prefix = try renderForTest("let x = \"b\"; in builtins.attrNames { a.${x} = 1; a.c = 2; }.a");
    defer std.testing.allocator.free(merged_static_prefix);
    try std.testing.expectEqualStrings("[ \"b\" \"c\" ]", merged_static_prefix);

    const merged_dynamic_root = try renderForTest("builtins.attrNames { ${\"a\"}.b = 1; a.c = 2; }.a");
    defer std.testing.allocator.free(merged_dynamic_root);
    try std.testing.expectEqualStrings("[ \"b\" \"c\" ]", merged_dynamic_root);

    try std.testing.expectError(error.DuplicateAttribute, renderForTest("{ ${\"a\"} = 1; a = 2; } ? a"));
    try std.testing.expectError(error.DuplicateAttribute, renderForTest("{ ${\"a\"}.b = 1; a.b = 2; } ? a"));
    try std.testing.expectError(error.DuplicateAttribute, renderForTest("let x = \"b\"; in { a.${x} = 1; a.b = 2; }.a"));
    try std.testing.expectError(error.DuplicateAttribute, renderForTest("let x = \"b\"; in { a.\"${x}\" = 1; a.b = 2; }.a"));
}

test "evaluate attrset function parameters past byte local slots" {
    var expr: std.ArrayListUnmanaged(u8) = .empty;
    defer expr.deinit(std.testing.allocator);

    try expr.appendSlice(std.testing.allocator, "({ ");
    for (0..270) |index| {
        var buf: [64]u8 = undefined;
        const param = try std.fmt.bufPrint(&buf, "p{d} ? {d}, ", .{ index, index });
        try expr.appendSlice(std.testing.allocator, param);
    }
    try expr.appendSlice(std.testing.allocator, "result ? p269 }: result) { }");

    const output = try renderForTest(expr.items);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("269", output);
}

test "evaluate closures with more than byte upvalues" {
    var expr: std.ArrayListUnmanaged(u8) = .empty;
    defer expr.deinit(std.testing.allocator);

    try expr.appendSlice(std.testing.allocator, "({ ");
    for (0..260) |index| {
        var buf: [64]u8 = undefined;
        const param = try std.fmt.bufPrint(&buf, "p{d} ? 1, ", .{index});
        try expr.appendSlice(std.testing.allocator, param);
    }
    try expr.appendSlice(std.testing.allocator, "}: (x: ");
    for (0..260) |index| {
        if (index != 0) try expr.appendSlice(std.testing.allocator, " + ");
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "p{d}", .{index});
        try expr.appendSlice(std.testing.allocator, name);
    }
    try expr.appendSlice(std.testing.allocator, ") 0) { }");

    const output = try renderForTest(expr.items);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("260", output);
}

test "evaluate jumps past u16 bytecode offsets" {
    var expr: std.ArrayListUnmanaged(u8) = .empty;
    defer expr.deinit(std.testing.allocator);

    try expr.appendSlice(std.testing.allocator, "assert true; builtins.length [ ");
    for (0..24_000) |_| try expr.appendSlice(std.testing.allocator, "0 ");
    try expr.appendSlice(std.testing.allocator, "]");

    const output = try renderForTest(expr.items);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("24000", output);
}

test "evaluate small unary builtins" {
    const is_float = try renderForTest("builtins.isFloat 1.5");
    defer std.testing.allocator.free(is_float);
    try std.testing.expectEqualStrings("true", is_float);

    const is_function = try renderForTest("builtins.isFunction (x: x)");
    defer std.testing.allocator.free(is_function);
    try std.testing.expectEqualStrings("true", is_function);

    const is_path = try renderForTest("builtins.isPath ./foo");
    defer std.testing.allocator.free(is_path);
    try std.testing.expectEqualStrings("true", is_path);

    const length = try renderForTest("builtins.length [ 1 (1 / 0) 3 ]");
    defer std.testing.allocator.free(length);
    try std.testing.expectEqualStrings("3", length);

    const head = try renderForTest("builtins.head [ 4 5 ]");
    defer std.testing.allocator.free(head);
    try std.testing.expectEqualStrings("4", head);

    const names = try renderForTest("builtins.attrNames { b = 2; a = 1; }");
    defer std.testing.allocator.free(names);
    try std.testing.expectEqualStrings("[ \"a\" \"b\" ]", names);

    const values = try renderForTest("builtins.attrValues { b = 2; a = 1; }");
    defer std.testing.allocator.free(values);
    try std.testing.expectEqualStrings("[ 1 2 ]", values);
}

test "evaluate curried binary builtins" {
    const has_attr = try renderForTest("builtins.hasAttr \"a\" { a = 1; }");
    defer std.testing.allocator.free(has_attr);
    try std.testing.expectEqualStrings("true", has_attr);

    const missing_attr = try renderForTest("builtins.hasAttr \"b\" { a = 1; }");
    defer std.testing.allocator.free(missing_attr);
    try std.testing.expectEqualStrings("false", missing_attr);

    const attr_get = try renderForTest("builtins.getAttr \"a\" { a = 3; }");
    defer std.testing.allocator.free(attr_get);
    try std.testing.expectEqualStrings("3", attr_get);

    const elem_at = try renderForTest("builtins.elemAt [ 1 2 3 ] 1");
    defer std.testing.allocator.free(elem_at);
    try std.testing.expectEqualStrings("2", elem_at);

    const partial_is_function = try renderForTest("builtins.isFunction (builtins.elemAt [ 1 ])");
    defer std.testing.allocator.free(partial_is_function);
    try std.testing.expectEqualStrings("true", partial_is_function);
}

test "evaluate primitive arithmetic and bit builtins" {
    const add = try renderForTest("builtins.add 1 2.5");
    defer std.testing.allocator.free(add);
    try std.testing.expectEqualStrings("3.5", add);

    const div = try renderForTest("builtins.div (-7) 2");
    defer std.testing.allocator.free(div);
    try std.testing.expectEqualStrings("-3", div);

    const less_than = try renderForTest("builtins.lessThan \"a\" \"b\"");
    defer std.testing.allocator.free(less_than);
    try std.testing.expectEqualStrings("true", less_than);

    const bit_and = try renderForTest("builtins.bitAnd 6 3");
    defer std.testing.allocator.free(bit_and);
    try std.testing.expectEqualStrings("2", bit_and);

    const bit_or = try renderForTest("builtins.bitOr 4 1");
    defer std.testing.allocator.free(bit_or);
    try std.testing.expectEqualStrings("5", bit_or);

    const bit_xor = try renderForTest("builtins.bitXor 6 3");
    defer std.testing.allocator.free(bit_xor);
    try std.testing.expectEqualStrings("5", bit_xor);

    const floor = try renderForTest("builtins.floor (-1.2)");
    defer std.testing.allocator.free(floor);
    try std.testing.expectEqualStrings("-2", floor);

    const ceil = try renderForTest("builtins.ceil (-1.8)");
    defer std.testing.allocator.free(ceil);
    try std.testing.expectEqualStrings("-1", ceil);
}

test "evaluate primitive path and metadata builtins" {
    const interpolated_path = try renderForTest("builtins.toString (let name = \"root.zig\"; in ./src/${name})");
    defer std.testing.allocator.free(interpolated_path);
    try std.testing.expect(std.mem.endsWith(u8, interpolated_path, "/src/root.zig\""));

    const base = try renderForTest("builtins.baseNameOf /foo/bar");
    defer std.testing.allocator.free(base);
    try std.testing.expectEqualStrings("\"bar\"", base);

    const string_dir = try renderForTest("builtins.dirOf \"foo/bar\"");
    defer std.testing.allocator.free(string_dir);
    try std.testing.expectEqualStrings("\"foo\"", string_dir);

    const to_path_type = try renderForTest("builtins.typeOf (builtins.toPath /foo/bar)");
    defer std.testing.allocator.free(to_path_type);
    try std.testing.expectEqualStrings("\"string\"", to_path_type);

    const to_path_is_path = try renderForTest("builtins.isPath (builtins.toPath /foo/bar)");
    defer std.testing.allocator.free(to_path_is_path);
    try std.testing.expectEqualStrings("false", to_path_is_path);

    const path_dir = try renderForTest("builtins.dirOf /foo/bar");
    defer std.testing.allocator.free(path_dir);
    try std.testing.expectEqualStrings("/foo", path_dir);

    const normalized_paths = try renderForTest("builtins.toJSON [ (toString /.) (toString /foo/../bar) (toString (/. + \"/foo\")) (toString (/foo + \"/../bar\")) ]");
    defer std.testing.allocator.free(normalized_paths);
    try std.testing.expectEqualStrings("\"[\\\"/\\\",\\\"/bar\\\",\\\"/foo\\\",\\\"/bar\\\"]\"", normalized_paths);

    const true_value = try renderForTest("builtins.true");
    defer std.testing.allocator.free(true_value);
    try std.testing.expectEqualStrings("true", true_value);

    const false_value = try renderForTest("builtins.false");
    defer std.testing.allocator.free(false_value);
    try std.testing.expectEqualStrings("false", false_value);

    const null_value = try renderForTest("builtins.null");
    defer std.testing.allocator.free(null_value);
    try std.testing.expectEqualStrings("null", null_value);

    const lang_version = try renderForTest("builtins.langVersion");
    defer std.testing.allocator.free(lang_version);
    try std.testing.expectEqualStrings("6", lang_version);

    const store_dir = try renderForTest("builtins.storeDir");
    defer std.testing.allocator.free(store_dir);
    try std.testing.expectEqualStrings("\"/nix/store\"", store_dir);

    const nested_builtins = try renderForTest("builtins.builtins.storeDir");
    defer std.testing.allocator.free(nested_builtins);
    try std.testing.expectEqualStrings("\"/nix/store\"", nested_builtins);
}

test "evaluate builtins.typeOf" {
    const int_type = try renderForTest("builtins.typeOf 1");
    defer std.testing.allocator.free(int_type);
    try std.testing.expectEqualStrings("\"int\"", int_type);

    const set_type = try renderForTest("builtins.typeOf { }");
    defer std.testing.allocator.free(set_type);
    try std.testing.expectEqualStrings("\"set\"", set_type);

    const fn_type = try renderForTest("builtins.typeOf (x: x)");
    defer std.testing.allocator.free(fn_type);
    try std.testing.expectEqualStrings("\"lambda\"", fn_type);
}

test "evaluate concatLists and listToAttrs builtins" {
    const concat = try renderForTest("builtins.concatLists [ [ 1 ] [ (1 / 0) ] [ 3 ] ]");
    defer std.testing.allocator.free(concat);
    try std.testing.expectEqualStrings("[ 1 <CODE> 3 ]", concat);

    const first_duplicate_wins = try renderForTest("(builtins.listToAttrs [ { name = \"a\"; value = 1; } { name = \"a\"; value = 2; } ]).a");
    defer std.testing.allocator.free(first_duplicate_wins);
    try std.testing.expectEqualStrings("1", first_duplicate_wins);

    const lazy_value = try renderForTest("(builtins.listToAttrs [ { name = \"a\"; value = 1 / 0; } ]) ? a");
    defer std.testing.allocator.free(lazy_value);
    try std.testing.expectEqualStrings("true", lazy_value);
}

test "evaluate removeAttrs and intersectAttrs builtins" {
    const removed = try renderForTest("(builtins.removeAttrs { a = 1; b = 2; } [ \"a\" ]).b");
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualStrings("2", removed);

    const removed_missing = try renderForTest("(builtins.removeAttrs { a = 1; b = 2; } [ \"a\" ]) ? a");
    defer std.testing.allocator.free(removed_missing);
    try std.testing.expectEqualStrings("false", removed_missing);

    const remove_lazy = try renderForTest("(builtins.removeAttrs { a = 1 / 0; b = 2; } [ \"b\" ]) ? a");
    defer std.testing.allocator.free(remove_lazy);
    try std.testing.expectEqualStrings("true", remove_lazy);

    const intersect = try renderForTest("(builtins.intersectAttrs { a = 1; } { a = 2; b = 3; }).a");
    defer std.testing.allocator.free(intersect);
    try std.testing.expectEqualStrings("2", intersect);

    const intersect_lazy = try renderForTest("(builtins.intersectAttrs { a = 1; } { a = 1 / 0; b = 2; }) ? a");
    defer std.testing.allocator.free(intersect_lazy);
    try std.testing.expectEqualStrings("true", intersect_lazy);
}

test "evaluate elem builtin" {
    const present = try renderForTest("builtins.elem 2 [ 1 2 3 ]");
    defer std.testing.allocator.free(present);
    try std.testing.expectEqualStrings("true", present);

    const missing = try renderForTest("builtins.elem 4 [ 1 2 3 ]");
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("false", missing);

    const short_circuit = try renderForTest("builtins.elem 1 [ 1 (1 / 0) ]");
    defer std.testing.allocator.free(short_circuit);
    try std.testing.expectEqualStrings("true", short_circuit);

    const empty_list_lazy_needle = try renderForTest("builtins.elem (builtins.throw \"needle\") [ ]");
    defer std.testing.allocator.free(empty_list_lazy_needle);
    try std.testing.expectEqualStrings("false", empty_list_lazy_needle);
}

test "evaluate seq builtin" {
    const value = try renderForTest("builtins.seq 1 2");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("2", value);

    const list_whnf = try renderForTest("builtins.seq [ (1 / 0) ] 2");
    defer std.testing.allocator.free(list_whnf);
    try std.testing.expectEqualStrings("2", list_whnf);

    const unused = try renderForTest("let x = builtins.seq (1 / 0) 2; in 3");
    defer std.testing.allocator.free(unused);
    try std.testing.expectEqualStrings("3", unused);
}

test "evaluate deepSeq builtin" {
    const attrs = try renderForTest("builtins.deepSeq { a = 1; b = [ 2 ]; } 3");
    defer std.testing.allocator.free(attrs);
    try std.testing.expectEqualStrings("3", attrs);

    const unused = try renderForTest("let x = builtins.deepSeq [ (1 / 0) ] 2; in 3");
    defer std.testing.allocator.free(unused);
    try std.testing.expectEqualStrings("3", unused);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    try std.testing.expectError(error.DivisionByZero, ev.evaluate("builtins.deepSeq [ (1 / 0) ] 2"));
}

test "unsafeGetAttrPos reports file positions for file-attributed sources" {
    // Constant attrset: the closed-literal fold materializes it at compile
    // time — positions must be carried onto the folded object.
    const folded = try helpers.renderPathForTest(
        "builtins.unsafeGetAttrPos \"email\" { name = \"n\"; email = \"e\"; }",
        "/test/pos.nix",
    );
    defer std.testing.allocator.free(folded);
    try std.testing.expect(std.mem.indexOf(u8, folded, "file = \"/test/pos.nix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, folded, "line = 1") != null);

    // Non-constant entry: the attrset builds at runtime via
    // attrs_new_named_pos_srt — positions must flow through that path too.
    const built = try helpers.renderPathForTest(
        "builtins.unsafeGetAttrPos \"email\" { name = toString 1; email = \"e\"; }",
        "/test/pos.nix",
    );
    defer std.testing.allocator.free(built);
    try std.testing.expect(std.mem.indexOf(u8, built, "file = \"/test/pos.nix\"") != null);

    // No source path (bare expression): null, matching Nix's `-E` behavior.
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    const v = try ev.evaluate("builtins.unsafeGetAttrPos \"email\" { email = \"e\"; }");
    try std.testing.expect(v.kind() == .null);
}

test "static attr positions survive a dynamic entry in the same literal" {
    // A literal with a dynamic entry compiles as static-part + strict merges;
    // the merge must carry the position tables (stdenvNoCC's meta.position
    // reads the position of `name` from exactly such a set).
    const merged = try helpers.renderPathForTest(
        "builtins.unsafeGetAttrPos \"a\" { a = 1; ${if false then \"b\" else null} = 2; }",
        "/test/pos.nix",
    );
    defer std.testing.allocator.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, "file = \"/test/pos.nix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "line = 1") != null);
}

test "unsafeGetAttrPos reports dynamic keys at the start of their attribute path" {
    const src =
        "let x = \"a\"; y = \"b\"; in [\n" ++
        "  (builtins.unsafeGetAttrPos \"a\" { ${x} = 1; })\n" ++
        "  (builtins.unsafeGetAttrPos \"a\" { \"${x}\" = 1; })\n" ++
        "  (builtins.unsafeGetAttrPos \"b\" { foo.${x}.${y} = 1; }.foo.a)\n" ++
        "  (builtins.unsafeGetAttrPos \"a\" (rec { ${x} = 1; }))\n" ++
        "]";
    const out = try helpers.renderPathForTest(src, "/test/dyn.nix");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "[ { column = 36; file = \"/test/dyn.nix\"; line = 2; } " ++
            "{ column = 36; file = \"/test/dyn.nix\"; line = 3; } " ++
            "{ column = 36; file = \"/test/dyn.nix\"; line = 4; } " ++
            "{ column = 41; file = \"/test/dyn.nix\"; line = 5; } ]",
        out,
    );
}

test "unsafeGetAttrPos reports a let attribute path at its first segment" {
    const src =
        "let\n" ++
        "  a = { };\n" ++
        "  a.foo = 1;\n" ++
        "in builtins.unsafeGetAttrPos \"foo\" a";
    const out = try helpers.renderPathForTest(src, "/test/let.nix");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{ column = 3; file = \"/test/let.nix\"; line = 3; }", out);
}

test "unsafeGetAttrPos reads positions from the attrs_new_named_pos_srt side table" {
    // Multi-entry runtime-built attrset (non-constant values defeat the
    // closed-literal fold): the names AND positions ride the chunk's
    // attr_names/attr_pos side tables, not the code stream — each key's
    // recorded position must round-trip through the (start, count) operand
    // references.
    const src =
        "let mk = v: {\n" ++
        "  alpha = toString v;\n" ++
        "  beta = toString v;\n" ++
        "  gamma = toString v;\n" ++
        "}; in [\n" ++
        "  (builtins.unsafeGetAttrPos \"alpha\" (mk 1))\n" ++
        "  (builtins.unsafeGetAttrPos \"gamma\" (mk 2))\n" ++
        "]";
    const out = try helpers.renderPathForTest(src, "/test/side_table.nix");
    defer std.testing.allocator.free(out);
    // alpha is declared on line 2 and gamma on line 4 of the attrset body.
    try std.testing.expect(std.mem.indexOf(u8, out, "line = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line = 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "file = \"/test/side_table.nix\"") != null);
}
