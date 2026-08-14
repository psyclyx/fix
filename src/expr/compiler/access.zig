//! Lowers attribute-access forms — static paths (`a.b.c`), dynamic
//! `.${…}`, `or`-defaults, and `?` has-attr — plus list and
//! immediate-container-value emission (the literal-vs-thunk dispatch).

const std = @import("std");
const compiler_mod = @import("context.zig");
const ast = @import("syntax").ast;
const types = @import("runtime").types;
const emit = @import("emit.zig");
const scope = @import("scope.zig");
const thunks = @import("thunks.zig");
const diagnostics = @import("diagnostics.zig");
const attr_names = @import("attr_names.zig");
const literals = @import("literals.zig");
const lambda = @import("lambda.zig");
const fold = @import("fold.zig");

const Compiler = compiler_mod.Compiler;
const Node = compiler_mod.Node;
const AttrEntryView = compiler_mod.AttrEntryView;
const ContainerValueOptions = compiler_mod.ContainerValueOptions;
const InternId = types.InternId;
const diagnostic_atom = @import("diagnostic_atom.zig");
const attr_path_operand = @import("attr_path_operand.zig");
const diagnosticAtom = diagnostic_atom.diagnosticAtom;
const attrPathDiagnosticAtom = diagnostic_atom.attrPathDiagnosticAtom;
const hasAttrDiagnosticAtom = diagnostic_atom.hasAttrDiagnosticAtom;
const hasAttrMixedDiagnosticAtom = diagnostic_atom.hasAttrMixedDiagnosticAtom;
const unwrapParens = ast.unwrapParens;

pub fn compileAttrPath(self: *Compiler, node: *const Node) !void {
    const apath = node.data.attr_path;
    if (try compileLiteralAttrSelection(self, apath.root, apath.segments)) return;
    try self.compileNode(apath.root);

    for (apath.segments) |seg| {
        if (attr_names.hasInterpolation(self, seg)) {
            try literals.compileStringAtom(self, seg);
            try emit.emitOp(self, .attr_get_dyn);
        } else {
            const name_id = try attr_names.intern(self, seg);
            try emit.emitGetAttr(self, name_id);
        }
    }
}

pub fn compileAttrDynamic(self: *Compiler, node: *const Node) !void {
    const dynamic = node.data.attr_dynamic;
    try self.compileNode(dynamic.root);
    try self.compileNode(dynamic.name);
    try emit.emitOp(self, .attr_get_dyn);
}

pub fn compileAttrOr(self: *Compiler, node: *const Node) !void {
    const attr_or = node.data.attr_or;

    // Flatten the whole select path — across nested `attr_path`/`attr_dynamic`
    // (e.g. `root.a.${b}.c` parses as an `attr_path` whose root is an
    // `attr_dynamic`) — into one segment list, so the `or` default covers a
    // missing attr at any position, static or dynamic.
    var segments: std.ArrayListUnmanaged(Node.HasAttrMixedSegment) = .empty;
    defer segments.deinit(self.allocator);
    const base = try flattenAttrPath(self, attr_or.attr_path, &segments);
    const atom = diagnosticAtom(attr_or.attr_path);

    var dynamic_count: usize = 0;
    for (segments.items) |segment| {
        switch (segment) {
            .static => |seg| if (attr_names.hasInterpolation(self, seg)) {
                dynamic_count += 1;
            },
            .dynamic => dynamic_count += 1,
        }
    }

    if (dynamic_count == 0) {
        // All-static path: the fast encoding.
        var atoms: std.ArrayListUnmanaged(Node.Atom) = .empty;
        defer atoms.deinit(self.allocator);
        for (segments.items) |segment| try atoms.append(self.allocator, segment.static);
        try self.compileNode(base);
        try thunks.compileThunk(self, attr_or.default);
        const wide = try attr_path_operand.isWide(self, atoms.items);
        try emit.emitOp(self, if (wide) .attr_get_path_or_w else .attr_get_path_or);
        try attr_path_operand.writeStatic(self, atoms.items, atom, wide);
        return;
    }

    // Re-specialize the dominant dynamic shapes to the fused ops. Both fused
    // handlers cover the WHOLE path with the default (missing static prefix
    // segment -> default), so this keeps the flatten fix's semantics while
    // restoring the slimmer pre-flatten encodings (the generic mix_or operand
    // pushed hot chunks over the speculation-eligibility size cliff):
    //   x.${b} or d            -> attr_get_dyn_or   (no operand)
    //   x.a.b.${c} or d        -> attr_get_path_dyn_or[_w]
    // dynamic_count==1 with a trailing .dynamic implies every prefix segment
    // is a pure (non-interpolated) static.
    if (dynamic_count == 1 and segments.items[segments.items.len - 1] == .dynamic) {
        const dyn_name = segments.items[segments.items.len - 1].dynamic;
        const prefix = segments.items[0 .. segments.items.len - 1];
        try self.compileNode(base);
        try thunks.compileThunk(self, dyn_name);
        try thunks.compileThunk(self, attr_or.default);
        if (prefix.len == 0) {
            try emit.emitOp(self, .attr_get_dyn_or);
        } else {
            var atoms: std.ArrayListUnmanaged(Node.Atom) = .empty;
            defer atoms.deinit(self.allocator);
            for (prefix) |segment| try atoms.append(self.allocator, segment.static);
            const wide = try attr_path_operand.isWide(self, atoms.items);
            try emit.emitOp(self, if (wide) .attr_get_path_dyn_or_w else .attr_get_path_dyn_or);
            try attr_path_operand.writeStatic(self, atoms.items, atom, wide);
        }
        return;
    }

    // Mixed static/dynamic path: push root, then each dynamic segment's name
    // thunk in path order, then the default thunk.
    try self.compileNode(base);
    for (segments.items) |segment| {
        switch (segment) {
            .static => |seg| if (attr_names.hasInterpolation(self, seg)) try thunks.compileStringAtomThunk(self, seg),
            .dynamic => |name| try thunks.compileThunk(self, name),
        }
    }
    try thunks.compileThunk(self, attr_or.default);
    try emit.emitOp(self, .attr_get_path_mix_or);
    try attr_path_operand.writeHasAttrMixed(self, segments.items, dynamic_count, atom);
}

/// Flatten a nested attribute-access node into `segments` (root-first) and
/// return the base root (the first non-`attr_path`/`attr_dynamic` node).
fn flattenAttrPath(self: *Compiler, node: *const Node, segments: *std.ArrayListUnmanaged(Node.HasAttrMixedSegment)) !*const Node {
    switch (node.tag) {
        .attr_path => {
            const apath = node.data.attr_path;
            const base = try flattenAttrPath(self, apath.root, segments);
            for (apath.segments) |seg| try segments.append(self.allocator, .{ .static = seg });
            return base;
        },
        .attr_dynamic => {
            const dynamic = node.data.attr_dynamic;
            const base = try flattenAttrPath(self, dynamic.root, segments);
            try segments.append(self.allocator, .{ .dynamic = dynamic.name });
            return base;
        },
        else => return node,
    }
}

pub fn compileHasAttr(self: *Compiler, node: *const Node) !void {
    const has_attr = node.data.has_attr;
    // Keep the packed bytecode format's existing source-level limit even when
    // a literal path can be answered without emitting that bytecode.
    _ = try diagnostics.requireU8At(self, has_attr.segments.len, hasAttrDiagnosticAtom(has_attr), "attribute path has too many segments");
    if (!hasInterpolatedAttrSegment(self, has_attr.segments)) {
        if (try literalHasAttrPath(self, has_attr.root, has_attr.segments)) |present| {
            try emit.emitOp(self, if (present) .push_true else .push_false);
            return;
        }
    }
    try self.compileNode(has_attr.root);
    if (hasInterpolatedAttrSegment(self, has_attr.segments)) {
        var dynamic_count: usize = 0;
        for (has_attr.segments) |seg| {
            if (attr_names.hasInterpolation(self, seg)) {
                try thunks.compileStringAtomThunk(self, seg);
                dynamic_count += 1;
            }
        }
        try emit.emitOp(self, .attr_has_path_mix);
        try attr_path_operand.writeMixed(self, has_attr.segments, dynamic_count, hasAttrDiagnosticAtom(has_attr));
        return;
    }

    const wide = try attr_path_operand.isWide(self, has_attr.segments);
    try emit.emitOp(self, if (wide) .attr_has_path_w else .attr_has_path);
    try attr_path_operand.writeStatic(self, has_attr.segments, hasAttrDiagnosticAtom(has_attr), wide);
}

pub fn compileHasAttrMixed(self: *Compiler, node: *const Node) !void {
    const has_attr = node.data.has_attr_mixed;
    try self.compileNode(has_attr.root);
    var dynamic_count: usize = 0;
    for (has_attr.segments) |segment| {
        switch (segment) {
            .static => |atom| {
                if (attr_names.hasInterpolation(self, atom)) {
                    try thunks.compileStringAtomThunk(self, atom);
                    dynamic_count += 1;
                }
            },
            .dynamic => |name| {
                try thunks.compileThunk(self, name);
                dynamic_count += 1;
            },
        }
    }

    try emit.emitOp(self, .attr_has_path_mix);
    try attr_path_operand.writeHasAttrMixed(self, has_attr.segments, dynamic_count, hasAttrMixedDiagnosticAtom(has_attr));
}

fn hasInterpolatedAttrSegment(self: *Compiler, segments: []const Node.Atom) bool {
    for (segments) |segment| {
        if (attr_names.hasInterpolation(self, segment)) return true;
    }
    return false;
}

/// Select directly from a safe static attr literal instead of materializing
/// the set and all of its lazy members. Restricting the shape to non-recursive,
/// single-segment static entries means no dynamic collision, nested merge, or
/// recursive environment can affect the selected member. Nested literal paths
/// recurse, so `{ a = { b = e; }; }.a.b` compiles just `e`.
fn compileLiteralAttrSelection(self: *Compiler, root_raw: *const Node, segments: []const Node.Atom) !bool {
    if (segments.len == 0 or hasInterpolatedAttrSegment(self, segments)) return false;
    const root = unwrapParens(root_raw);
    if (root.tag != .attr_set) return false;
    const entries = root.data.attr_set.entries;
    if (!try literalSetHasSimpleStaticShape(self, root.data.attr_set)) return false;

    const wanted = try attr_names.intern(self, segments[0]);
    var selected: ?*const Node = null;
    for (entries) |entry| {
        if (try attr_names.intern(self, entry.path[0]) == wanted) {
            selected = entry.expr;
            break;
        }
    }
    const expr = selected orelse return false; // preserve normal missing-attr diagnostics
    if (segments.len > 1 and try compileLiteralAttrSelection(self, expr, segments[1..])) return true;

    try self.compileNode(expr);
    for (segments[1..]) |segment| {
        const name_id = try attr_names.intern(self, segment);
        try emit.emitGetAttr(self, name_id);
    }
    return true;
}

/// Resolve `literal ? static.path` at compile time when every traversed set is
/// a simple literal. The final member is never compiled or forced; membership
/// alone determines the result, matching `?` laziness.
fn literalHasAttrPath(self: *Compiler, root_raw: *const Node, segments: []const Node.Atom) !?bool {
    if (segments.len == 0) return null;
    const root = unwrapParens(root_raw);
    if (root.tag != .attr_set or !try literalSetHasSimpleStaticShape(self, root.data.attr_set)) return null;
    const wanted = try attr_names.intern(self, segments[0]);
    for (root.data.attr_set.entries) |entry| {
        if (try attr_names.intern(self, entry.path[0]) != wanted) continue;
        if (segments.len == 1) return true;
        return literalHasAttrPath(self, entry.expr, segments[1..]);
    }
    return false;
}

fn literalSetHasSimpleStaticShape(self: *Compiler, set: Node.AttrSet) !bool {
    if (set.recursive) return false;
    var names: std.AutoHashMapUnmanaged(InternId, void) = .empty;
    defer names.deinit(self.allocator);
    for (set.entries) |entry| {
        if (entry.dynamic_name != null or entry.path.len != 1 or attr_names.hasInterpolation(self, entry.path[0])) return false;
        const result = try names.getOrPut(self.allocator, try attr_names.intern(self, entry.path[0]));
        // Repeated leaf names may merge attrset literals or diagnose a
        // duplicate; either way the selected value is not this one RHS.
        if (result.found_existing) return false;
    }
    return true;
}

pub fn compileList(self: *Compiler, node: *const Node) !void {
    const list = node.data.list;
    if (list.items.len == 0) return emit.emitEmptyList(self);
    for (list.items) |item| {
        try compileListElement(self, item);
    }
    try emit.emitOpU16(self, .list_new, try diagnostics.requireU16At(self, list.items.len, diagnosticAtom(node), "too many list items"));
}

/// Compile a single list element with Nix's `Expr::maybeThunk` semantics: a
/// trivial atom (int/float/string/path/bool/null, an empty list, or a
/// statically-resolvable identifier) is stored directly as a value; every
/// other expression is stored as an unforced thunk. In a non-strict print the
/// thunk renders as `<CODE>` — matching Nix, which never inlines a composite
/// or computed element. This deliberately differs from `compileContainerValue`
/// (attr/let RHS values), whose composite fast paths inline pre-resolved lazy
/// shells that print as their value.
fn compileListElement(self: *Compiler, item: *const Node) !void {
    // Mirror `compileContainerValue`'s name-hint hygiene.
    defer self.name_hint = null;
    const unwrapped = unwrapParens(item);
    switch (unwrapped.tag) {
        .integer, .float_val, .bool_true, .bool_false, .null, .string, .path, .uri => {
            // Pure literals bind directly (interpolated string/path fall
            // through to a thunk, matching `ExprConcatStrings`).
            if (try compileImmediateContainerValue(self, unwrapped, .{})) return;
            try thunks.compileListElementThunk(self, item);
        },
        .identifier => {
            // A statically-resolvable variable is `ExprVar::maybeThunk`: bind
            // its slot/upvalue directly (no fresh thunk). Dynamic (`with`) and
            // builtin names aren't resolvable here, so they thunk instead.
            if (try compileRawIdent(self, unwrapped)) return;
            try thunks.compileListElementThunk(self, item);
        },
        .list => {
            // Empty list is a shared constant value (`[ [] ]` prints
            // `[ [ ] ]`); a non-empty list literal is thunked (`[ <CODE> ]`).
            if (unwrapped.data.list.items.len == 0) {
                try emit.emitEmptyList(self);
            } else {
                try thunks.compileListElementThunk(self, item);
            }
        },
        .attr_set => {
            // An empty non-recursive set is a shared constant value too
            // (`[ {} {} ]` prints `[ { } { } ]`); any populated set is thunked.
            if (unwrapped.data.attr_set.entries.len == 0 and !unwrapped.data.attr_set.recursive) {
                try emit.emitEmptyAttrs(self);
            } else {
                try thunks.compileListElementThunk(self, item);
            }
        },
        else => try thunks.compileListElementThunk(self, item),
    }
}

pub fn compileContainerValue(self: *Compiler, node: *const Node, options: ContainerValueOptions) !void {
    // Best-effort naming: the caller may have armed `name_hint` for this value.
    // Its representative chunk (the immediate lambda, or the wrapping thunk)
    // claims it at child creation; clear any residue so a nameless value (a bare
    // literal) can't leak the name onto a later sibling or the enclosing body.
    defer self.name_hint = null;
    if (try compileImmediateContainerValue(self, node, options)) return;
    try thunks.compileThunkContext(self, node);
}

/// Predicate version of `compileImmediateContainerValue` for the
/// pure-literal cases. Mirrors the branches above that don't depend
/// on scope state — useful for compile-time decisions about whether
/// a binding's RHS needs a lazy cell at all.
pub fn isLiteralContainerValue(self: *Compiler, node: *const Node) bool {
    const unwrapped = unwrapParens(node);
    return switch (unwrapped.tag) {
        .integer, .float_val, .bool_true, .bool_false, .null => true,
        .string => !stringHasInterpolation(self, unwrapped),
        .path => !pathHasInterpolation(self, unwrapped),
        .list => unwrapped.data.list.items.len == 0,
        else => false,
    };
}

pub fn compileImmediateContainerValue(self: *Compiler, node: *const Node, options: ContainerValueOptions) anyerror!bool {
    const unwrapped = unwrapParens(node);
    switch (unwrapped.tag) {
        .integer => try literals.compileInt(self, unwrapped),
        .float_val => try literals.compileFloat(self, unwrapped),
        .string => {
            if (stringHasInterpolation(self, unwrapped)) return false;
            try literals.compileString(self, unwrapped);
        },
        .path => {
            if (pathHasInterpolation(self, unwrapped)) return false;
            try literals.compilePath(self, unwrapped);
        },
        .uri => try literals.compileUri(self, unwrapped),
        .bool_true => try emit.emitOp(self, .push_true),
        .bool_false => try emit.emitOp(self, .push_false),
        .null => try emit.emitOp(self, .push_null),
        .list => {
            // A composite value has no single representative chunk; drop any
            // pending name so the element thunks don't claim the binding's name.
            self.name_hint = null;
            if (unwrapped.data.list.items.len == 0) {
                try emit.emitEmptyList(self);
            } else if (try fold.tryFoldConstant(self, unwrapped)) |v| {
                // Closed constant list: materialized once at compile time into
                // the constant pool (a permanent GC root) — no chunk, no thunk,
                // no per-eval construction. Equality is structural, so sharing
                // the object is unobservable.
                try self.builder.emitConstant(self.allocator, v);
                try emit.emitOp(self, .thunk_shell); // XML-lazy parity, like the built path
            } else {
                // Build the list shell in place, then wrap in a
                // pre-resolved "lazy shell" thunk. Forcing it in the
                // future is O(1) (resolved fast path); XML lazy mode
                // still prints `<unevaluated />` until a real
                // consumer marks it demanded, matching the
                // observable laziness of a true thunk-wrapped list.
                try compileList(self, unwrapped);
                try emit.emitOp(self, .thunk_shell);
            }
        },
        .attr_set => {
            // `{}` mirrors the empty-list fast path above: nothing to
            // fix-point, nothing lazily observable — build it in place, no
            // thunk, no chunk. (15k chunks on a NixOS toplevel existed solely
            // to build `{}`.)
            if (unwrapped.data.attr_set.entries.len == 0 and !unwrapped.data.attr_set.recursive) {
                try emit.emitEmptyAttrs(self);
                return true;
            }
            // Closed constant attrset: same treatment as the constant list
            // below-left — no scope references means no fix-point hazard.
            if (try fold.tryFoldConstant(self, unwrapped)) |v| {
                try self.builder.emitConstant(self.allocator, v);
                try emit.emitOp(self, .thunk_shell); // XML-lazy parity, like the built path
                return true;
            }
            // Only inline in eager let-binding context (set by
            // compileLetRootBinding when strictness says forced).
            // Other contexts — attrset-entry values, function
            // arguments — break NixOS module fix-points if their
            // attrset values are eagerly compiled into the parent's
            // chunk scope. The eager let-binding path is safe
            // because strictness already guarantees the binding
            // gets forced before any consumer might observe a
            // fix-point race.
            if (!options.eager) return false;
            if (unwrapped.data.attr_set.recursive) return false;
            self.name_hint = null; // composite value: see the .list note above
            try self.compileNode(unwrapped);
            try emit.emitOp(self, .thunk_shell);
        },
        .lambda => {
            try lambda.compileLambda(self, unwrapped);
            try emit.emitOp(self, .thunk_shell);
        },
        .lambda_attrs => {
            try lambda.compileLambdaAttrs(self, unwrapped);
            try emit.emitOp(self, .thunk_shell);
        },
        .identifier => {
            if (!options.raw_identifier) return false;
            if (!try compileRawIdent(self, unwrapped)) return false;
        },
        else => return false,
    }
    return true;
}

fn compileRawIdent(self: *Compiler, node: *const Node) !bool {
    const span = attr_names.identText(self, node.data.atom);
    const name_id = try self.intern.intern(span);
    if (scope.resolveLocalId(self, name_id)) |slot| {
        try emit.emitCaptureLocal(self, slot);
        return true;
    }
    if (try scope.resolveCaptureId(self, span, name_id)) |slot| {
        try emit.emitOpU16(self, .up_grab, slot);
        return true;
    }
    // `true`/`false`/`null` reach the compiler as identifiers only when the
    // file also *binds* one of the three names, which turns off the parser's
    // whole-file fold (see `Parser.parse`). Nothing lexical claims this use, so
    // it is still the base-env constant — emit it as one, so it binds directly
    // like the literal it stands for instead of becoming a `<CODE>` thunk.
    // Under `scopedImport` the supplied set replaces the base env, so no.
    if (!self.scoped_base) {
        if (ast.keywordLiteralTag(span)) |tag| {
            try emit.emitOp(self, switch (tag) {
                .bool_true => .push_true,
                .bool_false => .push_false,
                else => .push_null,
            });
            return true;
        }
    }
    return false;
}

fn stringHasInterpolation(self: *Compiler, node: *const Node) bool {
    const atom = node.data.atom;
    const span = self.source[atom.offset .. atom.offset + atom.len];
    return std.mem.indexOf(u8, span, "${") != null;
}

fn pathHasInterpolation(self: *Compiler, node: *const Node) bool {
    const atom = node.data.atom;
    const span = self.source[atom.offset .. atom.offset + atom.len];
    return std.mem.indexOf(u8, span, "${") != null;
}
