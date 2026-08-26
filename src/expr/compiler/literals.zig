//! Lowers leaf and near-leaf expressions: integer/float/string/path
//! literals (with `${…}` interpolation and `str_cat` assembly),
//! search paths, identifier resolution (locals/upvalues/`with`/ambient
//! builtins/`__curPos`), and materialization of parser-elided bodies.

const std = @import("std");
const compiler_mod = @import("context.zig");
const ast = @import("syntax").ast;
const bytecode = @import("../bytecode.zig");
const builtins = @import("runtime").builtins;
const chunk = bytecode.chunk;
const diagnostic = @import("syntax").diagnostic;
const heap_mod = @import("runtime").heap;
const string_syntax = @import("syntax").string_syntax;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const OpCode = bytecode.OpCode;
const emit = @import("emit.zig");
const fold = @import("fold.zig");
const attr_names = @import("attr_names.zig");
const scope = @import("scope.zig");
const diagnostics = @import("diagnostics.zig");
const int_ops = @import("runtime").int;
const parser_mod = @import("syntax").parser;
const TextRef = @import("base").TextRef;

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const NodeTag = compiler_mod.NodeTag;
const BinaryOp = compiler_mod.BinaryOp;
const Capture = compiler_mod.Capture;
const AttrEntryView = compiler_mod.AttrEntryView;
const AttrEntryGroup = compiler_mod.AttrEntryGroup;
const AttrEntryGroups = compiler_mod.AttrEntryGroups;
const ContainerValueOptions = compiler_mod.ContainerValueOptions;
const WithScope = compiler_mod.WithScope;
const InternId = types.InternId;
const offsetNode = ast.offsetNode;

pub const ResolvedPath = TextRef;

pub fn compileInt(self: *Compiler, node: *const Node) !void {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    const val = std.fmt.parseInt(i64, span, 10) catch {
        try diagnostics.reportCompileError(self, node.data.atom.offset, node.data.atom.len, "invalid integer literal");
        return error.InvalidNumber;
    };
    try self.builder.emitConstant(self.allocator, try int_ops.make(self.heap, val));
}

pub fn compileFloat(self: *Compiler, node: *const Node) !void {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    const val = std.fmt.parseFloat(f64, span) catch {
        try diagnostics.reportCompileError(self, node.data.atom.offset, node.data.atom.len, "invalid float literal");
        return error.InvalidNumber;
    };
    const v = Value.float(val);
    try self.builder.emitConstant(self.allocator, v);
}

pub fn compileString(self: *Compiler, node: *const Node) !void {
    try compileStringAtom(self, node.data.atom);
}

/// An unquoted URI literal (`https://…`) is a plain string of its verbatim
/// span — no escapes, no interpolation.
pub fn compileUri(self: *Compiler, node: *const Node) !void {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    try self.builder.emitConstant(self.allocator, Value.string(try self.intern.intern(span)));
}

/// Cap on operands accumulated for one `str_cat`. Keeps the
/// operand count in the opcode's u16 and bounds transient VM stack
/// growth for pathological many-part literals; when the cap is hit the
/// accumulated parts are folded into one operand and assembly continues.
const max_concat_parts: u16 = 4096;

pub fn compileStringAtom(self: *Compiler, atom: Node.Atom) !void {
    const literal = string_syntax.Span{
        .start = atom.offset,
        .end = atom.offset + atom.len,
    };
    const parsed = try string_syntax.parseLiteral(self.allocator, self.source, literal);
    defer parsed.deinit();

    // Push every part, then assemble with ONE `str_cat` — the
    // old `int_add` fold interned every intermediate prefix (hash +
    // copy + permanent intern-table bytes per `${}` boundary).
    var parts: u16 = 0;
    var total_parts: u32 = 0;
    var ops_emitted: u32 = 0;
    var first_is_interp = false;
    var single_is_text = false;
    var nul_truncated = false;
    for (parsed.parts) |part| {
        switch (part) {
            .text => |text| {
                var bytes = text.slice();
                // A NUL byte is a compile error unless the `nul-bytes`
                // deprecated feature is on, in which case the string is
                // truncated at the NUL (fix/Nix strings are NUL-terminated).
                if (std.mem.indexOfScalar(u8, bytes, 0)) |nul_idx| {
                    if (!self.policy.allow_nul_bytes) {
                        try diagnostics.reportCompileError(self, atom.offset, atom.len, "NUL bytes (`\\0`) are currently not well supported, because internally strings are NUL-terminated, which may lead to unexpected truncation. Use --extra-deprecated-features nul-bytes to disable this error.");
                        return error.NulByteInString;
                    }
                    bytes = bytes[0..nul_idx];
                    nul_truncated = true;
                }
                if (bytes.len == 0) {
                    if (nul_truncated) break;
                    continue;
                }
                const id = try self.intern.intern(bytes);
                try self.builder.emitConstant(self.allocator, Value.string(id));
                parts += 1;
                total_parts += 1;
                single_is_text = total_parts == 1;
                if (nul_truncated) break;
            },
            .interpolation => |span| {
                if (total_parts == 0) first_is_interp = true;
                try compileInterpolatedExpr(self, self.source[span.start..span.end], span.start);
                parts += 1;
                total_parts += 1;
                single_is_text = false;
            },
        }
        if (parts == max_concat_parts) {
            try emit.emitOpU16(self, .str_cat, parts);
            ops_emitted += 1;
            parts = 1;
        }
    }

    switch (parts) {
        0 => try self.builder.emitConstant(self.allocator, Value.string(try self.intern.intern(""))),
        // A lone text part is already a string constant. A lone
        // interpolation still needs the string coercion (`"${x}"`);
        // `str_cat 1` coerces without re-interning the text.
        1 => if (!single_is_text) {
            try emit.emitOpU16(self, .str_cat, 1);
            ops_emitted += 1;
        },
        else => {
            try emit.emitOpU16(self, .str_cat, parts);
            ops_emitted += 1;
        },
    }

    // Normalize scheduling weight to the equivalent `int_add` sequence so
    // compact `str_cat` encoding does not make the same work look cheaper.
    if (ops_emitted != 0) {
        const expanded_weight: u32 = (total_parts - 1) + @as(u32, if (first_is_interp) 4 else 0);
        const encoded_weight: u32 = 3 * ops_emitted;
        self.builder.fused_dispatch_weight += expanded_weight -| encoded_weight;
    }
}

pub fn emitStringPart(self: *Compiler, part: []const u8, have_value: *bool) !void {
    if (part.len == 0) return;

    const id = try self.intern.intern(part);
    try self.builder.emitConstant(self.allocator, Value.string(id));
    if (have_value.*) try emit.emitOp(self, .int_add);
    have_value.* = true;
}

/// Materialize an `.elided` body (body-span elision, see
/// `syntax/parser.zig scanElidableBody`): sub-parse its recorded source
/// span into the root compiler's AST arena and return the parsed body,
/// offset-corrected so every node span matches what an eager parse of the
/// whole file would have produced. Parse diagnostics are absorbed with the
/// same offset correction (the `compileInterpolatedExpr` precedent).
///
/// During the original file compile (`elide_mutable`), the shared elided
/// node is overwritten in place, so all later consumers — duplicate-merge
/// checks, the parent chunk's strictness stamp — see the real shape.
/// Force-time deferred compiles run CONCURRENTLY over the shared retained
/// AST: they parse into their per-compile throwaway arena and leave the
/// shared node untouched (racers each materialize their own copy).
pub fn materializeElided(self: *Compiler, node: *const Node) anyerror!*Node {
    std.debug.assert(node.tag == .elided);
    var root: *Compiler = self;
    while (root.parent) |p| root = p;
    const arena = root.ast_arena orelse return error.ElidedBodyWithoutArena;

    const atom = node.data.atom;
    const body_source = self.source[atom.offset .. atom.offset + atom.len];
    var parser = parser_mod.Parser.init(self.allocator, arena, body_source);
    defer parser.deinit();
    const expr = parser.parse() catch |err| {
        try diagnostics.absorbParserDiagnostics(self, parser.diagnostics.items, atom.offset);
        return err;
    };
    offsetNode(expr, atom.offset);

    if (root.elide_mutable) {
        const shared = @constCast(node);
        shared.* = expr.*;
        return shared;
    }
    return expr;
}

pub fn compileInterpolatedExpr(self: *Compiler, expr_source: []const u8, source_offset: u32) !void {
    var arena = ast.AstArena.init(self.allocator);
    defer arena.deinit();

    var parser = parser_mod.Parser.init(self.allocator, &arena, expr_source);
    defer parser.deinit();
    const expr = parser.parse() catch |err| {
        try diagnostics.absorbParserDiagnostics(self, parser.diagnostics.items, source_offset);
        return err;
    };
    offsetNode(expr, source_offset);
    try self.compileNode(expr);
}

pub fn compilePath(self: *Compiler, node: *const Node) !void {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    if (std.mem.indexOf(u8, span, "${") != null) return compileInterpolatedPath(self, span, node.data.atom.offset);

    var path = try resolvePathLiteral(self, span);
    defer path.deinit(self.allocator);
    const id = try self.intern.intern(path.slice());
    const v = Value.path(id);
    try self.builder.emitConstant(self.allocator, v);
}

pub fn compileInterpolatedPath(self: *Compiler, span: []const u8, source_offset: u32) !void {
    // Push every part (leading text as a base path constant, later text as
    // string constants, and each interpolation's value) then assemble with ONE
    // `path_cat`. A left fold of binary `path + string` would canonicalize
    // after each step and lose the `/` separators between adjacent `${…}`
    // interpolations (`/${a}/${b}`); Nix builds a single concatenation and
    // canonicalizes the whole path once.
    var cursor: usize = 0;
    var parts: u16 = 0;
    var have_base = false;

    while (std.mem.indexOf(u8, span[cursor..], "${")) |relative_start| {
        const interp_start = cursor + relative_start;
        if (try emitPathTextPart(self, span[cursor..interp_start], &have_base)) parts += 1;

        const expr_start = interp_start + 2;
        const expr_end = string_syntax.findInterpolationEnd(span, expr_start) orelse return error.InvalidPathLiteral;
        try compileInterpolatedExpr(self, span[expr_start..expr_end], source_offset + @as(u32, @intCast(expr_start)));
        parts += 1;
        cursor = expr_end + 1;
    }

    if (try emitPathTextPart(self, span[cursor..], &have_base)) parts += 1;
    if (parts == 0) return error.InvalidPathLiteral;
    try emit.emitOpU16(self, .path_cat, parts);
}

/// Emit one text part of an interpolated path. The first non-empty part is the
/// base and is resolved to a path constant (preserving a trailing slash so the
/// next part concatenates cleanly); later text parts are plain string
/// constants. Returns whether an operand was pushed.
pub fn emitPathTextPart(self: *Compiler, part: []const u8, have_base: *bool) !bool {
    if (part.len == 0) return false;
    if (!have_base.*) {
        var path = try resolvePathLiteralPreserveTrailingSlash(self, part);
        defer path.deinit(self.allocator);
        const id = try self.intern.intern(path.slice());
        try self.builder.emitConstant(self.allocator, Value.path(id));
        have_base.* = true;
        return true;
    }
    const id = try self.intern.intern(part);
    try self.builder.emitConstant(self.allocator, Value.string(id));
    return true;
}

pub fn compileSearchPath(self: *Compiler, node: *const Node) !void {
    const span = self.source[node.data.atom.offset .. node.data.atom.offset + node.data.atom.len];
    if (span.len < 2) return error.InvalidSearchPath;
    const name_id = try self.intern.intern(span[1 .. span.len - 1]);

    // `<name>` desugars to `builtins.findFile __nixPath "name"`, exactly as in
    // Nix. Threading it through the `__nixPath` *identifier* (rather than a
    // baked-in static search path) is what lets a local `let __nixPath = …`
    // override the lookup lexically. `findFile` itself honors `prefix=path`
    // entries and the synthetic `<nix/fetchurl.nix>` corepkgs file.
    try self.builder.emitConstant(self.allocator, Value.builtin(@intFromEnum(builtins.BuiltinId.findFile)));
    try emitNixPathRef(self);
    try emit.emitOp(self, .call);
    try self.builder.emitConstant(self.allocator, Value.string(name_id));
    try emit.emitOp(self, .call);
}

/// Emit a reference to `__nixPath`: a lexically-bound `__nixPath` (a `let`/
/// argument, so an in-file override wins) if one is in scope, otherwise the
/// global `builtins.nixPath` built from `-I`/`NIX_PATH`.
fn emitNixPathRef(self: *Compiler) !void {
    const name = "__nixPath";
    const name_id = try self.intern.intern(name);
    if (scope.resolveLocalId(self, name_id)) |slot| {
        try emit.emitGetLocal(self, slot);
    } else if (try scope.resolveCaptureId(self, name, name_id)) |slot| {
        try emit.emitOpU16(self, .up_get, slot);
    } else {
        try emit.emitOp(self, .push_builtins);
        try emit.emitGetAttr(self, try self.intern.intern("nixPath"));
    }
}

pub fn resolvePathLiteral(self: *Compiler, span: []const u8) !ResolvedPath {
    // Home-relative path (`~/foo`): expand the leading `~` to $HOME, matching
    // Nix, which resolves it at parse time.
    if (span.len > 0 and span[0] == '~' and (span.len == 1 or span[1] == '/')) {
        const home = self.home_dir orelse return error.NoHomeDir;
        const joined = try std.fs.path.join(self.allocator, &.{ home, span[1..] });
        defer self.allocator.free(joined);
        return .{ .owned = try std.fs.path.resolve(self.allocator, &.{joined}) };
    }
    if (std.fs.path.isAbsolute(span)) {
        return .{ .owned = try std.fs.path.resolve(self.allocator, &.{span}) };
    }
    const cwd = self.base_path orelse return .{ .borrowed = span };

    return .{ .owned = try std.fs.path.resolve(self.allocator, &.{ cwd, span }) };
}

pub fn resolvePathLiteralPreserveTrailingSlash(self: *Compiler, span: []const u8) !ResolvedPath {
    var resolved = try resolvePathLiteral(self, span);
    if (!std.mem.endsWith(u8, span, "/") or std.mem.endsWith(u8, resolved.slice(), "/")) return resolved;

    const text = try std.fmt.allocPrint(self.allocator, "{s}/", .{resolved.slice()});
    resolved.deinit(self.allocator);
    return .{ .owned = text };
}

pub fn compileIdent(self: *Compiler, node: *const Node) !void {
    const span = attr_names.identText(self, node.data.atom);
    if (std.mem.eql(u8, span, "__curPos")) {
        try compileCurPos(self, node.data.atom);
        return;
    }
    // Intern once, then resolve the compact id up the scope chain instead of
    // comparing source bytes against every local at every parent level.
    const name_id = try self.intern.intern(span);
    if (scope.resolveLocalId(self, name_id)) |slot| {
        try emit.emitGetLocal(self, slot);
    } else if (try scope.resolveCaptureId(self, span, name_id)) |slot| {
        try emit.emitOpU16(self, .up_get, slot);
    } else if (self.scoped_base and try scope.emitWithLookup(self, span)) {
        // `builtins.scopedImport`: the ambient attrset REPLACES the base env,
        // so it shadows the static builtins — check it before `builtins`/the
        // ambient builtin table (and never fall through to them). A name absent
        // from the scope raises `undefined variable` at runtime, matching Nix's
        // "the supplied set is the whole environment" semantic.
        return;
    } else if (fold.globalConstant(self, node)) |g| {
        // `true`/`false`/`null` reach here as unshadowed base-env variables:
        // push the constant instead of going through `builtins.<name>` like
        // the other constant bindings below. Ordered above `emitWithLookup`
        // because a `with` cannot shadow a base-env name.
        try emit.emitOp(self, g.op());
    } else if (std.mem.eql(u8, span, "builtins")) {
        try emit.emitOp(self, .push_builtins);
    } else if (try emitAmbientBuiltin(self, span)) {
        return;
    } else if (try scope.emitWithLookup(self, span)) {
        return;
    } else {
        const message = try std.fmt.allocPrint(self.allocator, "undefined variable '{s}'", .{span});
        try self.owned_diagnostic_messages.append(self.allocator, message);
        try diagnostics.reportCompileError(self, node.data.atom.offset, node.data.atom.len, message);
        return error.UndefinedVariable;
    }
}

pub fn compileCurPos(self: *Compiler, atom: Node.Atom) !void {
    if (self.source_path == null) {
        try emit.emitOp(self, .push_null);
        return;
    }

    const file_id = try self.intern.intern("file");
    const line_id = try self.intern.intern("line");
    const column_id = try self.intern.intern("column");
    const source_path_id = try diagnostics.sourceFileId(self);
    const position = try diagnostics.sourcePositionForOffset(self, atom.offset);

    // Fully compile-time-known: materialize the { file, line, column } attrset
    // once as a constant (chunk constants are permanent GC roots) instead of
    // building it at every execution.
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = column_id, .value = Value.int(@intCast(position.column)) },
        .{ .name = file_id, .value = Value.string(source_path_id) },
        .{ .name = line_id, .value = Value.int(@intCast(position.line)) },
    };
    const id = try self.heap.addAttrs(&entries);
    try self.builder.emitConstant(self.allocator, Value.attrs(id));
}

pub fn emitAmbientBuiltin(self: *Compiler, name: []const u8) !bool {
    if (builtins.ambientIdForName(name)) |id| {
        try self.builder.emitConstant(self.allocator, Value.builtin(@intFromEnum(id)));
        return true;
    }

    // `__nixPath` is a global (== `builtins.nixPath`), the search path built
    // from `-I`/`NIX_PATH`. It lives outside the `builtins` set as a bare
    // identifier so `length __nixPath` / `<name>` desugaring resolve it; a
    // local `let __nixPath` shadows it (locals are resolved before we get here).
    if (std.mem.eql(u8, name, "__nixPath")) {
        try emit.emitOp(self, .push_builtins);
        try emit.emitGetAttr(self, try self.intern.intern("nixPath"));
        return true;
    }

    if (builtins.hasConstant(name)) {
        // `__currentSystem` and friends alias the unprefixed `builtins.<name>`.
        const attr = if (std.mem.startsWith(u8, name, "__")) name[2..] else name;
        try emit.emitOp(self, .push_builtins);
        try emit.emitGetAttr(self, try self.intern.intern(attr));
        return true;
    }

    return false;
}
