//! Table-driven LALR(1) parser.
//!
//! The ACTION/GOTO tables are generated from the grammar (`grammar.zig` →
//! `lr.zig`) by a cached codegen step (`gen_parser_tables.zig`) and imported
//! here as `parser_tables`. This file is the runtime: a tight shift/reduce loop
//! over the flat tables, plus the semantic actions that build the AST.
//!
//! Pipeline: source → streaming scanner → driver. The driver maintains a
//! state stack and a parallel semantic-value stack; each reduce runs one action
//! to fold children into an AST node. Nodes live in the caller's arena. The
//! grammar is pure LR — the lambda-pattern-vs-attrset ambiguity is resolved
//! inside the grammar (a unified `brace` nonterminal), not by any pre-pass.

const std = @import("std");
const token = @import("token.zig");
const TokenType = token.TokenType;
const Token = token.Token;
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeTag = ast.NodeTag;
const diagnostic = @import("diagnostic.zig");
const Diagnostic = diagnostic.Diagnostic;
const Scanner = @import("scanner.zig").Scanner;
const string_syntax = @import("string_syntax.zig");
const grammar = @import("grammar.zig");
const lr = @import("lr.zig");

/// A node in the attribute-merge tree used to reject duplicate definitions at
/// parse time (see `Parser.checkDuplicateAttrs`). A name maps either to a leaf
/// (a value definition) or to a subtree (an attribute set — whether formed by a
/// nested path `a.b = …` or a set literal).
const DupTree = struct {
    map: std.StringHashMapUnmanaged(Def) = .{},

    const Def = struct {
        pos: Node.Atom, // where this name was first defined
        sub: ?*DupTree, // non-null => this name is a (mergeable) attribute set
    };
};

/// A deprecated-syntax warning recorded during parsing. The parser is
/// feature-agnostic (like `used_pipe_operators`): it records every occurrence,
/// and the consumer (`fix parse`, the eval chokepoint) emits the ones whose
/// deprecated feature is not enabled. `message`/`feature` are semantic, not
/// byte-identical to Nix's prose.
pub const DeprecationWarning = struct {
    pub const Kind = enum {
        or_as_identifier,
        floating_without_zero,
        rec_set_dynamic_attrs,
        cr_line_endings,
    };
    kind: Kind,
    offset: u32,
    len: u32,

    pub fn message(kind: Kind) []const u8 {
        return switch (kind) {
            .or_as_identifier => "using `or` as an identifier is deprecated; use --extra-deprecated-features or-as-identifier to silence this warning",
            .floating_without_zero => "floating point literal without a leading zero; use --extra-deprecated-features floating-without-zero to silence this warning",
            .rec_set_dynamic_attrs => "dynamic attributes in a recursive set are deprecated; use --extra-deprecated-features rec-set-dynamic-attrs to silence this warning",
            .cr_line_endings => "CR (`\\r`) and CRLF (`\\r\\n`) line endings are not supported; normalize the file to LF",
        };
    }

    /// The deprecated-feature name that silences this warning. `cr_line_endings`
    /// is inverted (the feature *enables* the syntax, downgrading the error to a
    /// warning), so it is emitted directly rather than through the shared gate.
    pub fn feature(kind: Kind) []const u8 {
        return switch (kind) {
            .or_as_identifier => "or-as-identifier",
            .floating_without_zero => "floating-without-zero",
            .rec_set_dynamic_attrs => "rec-set-dynamic-attrs",
            .cr_line_endings => "cr-line-endings",
        };
    }
};

/// Comptime-generated LALR tables (see `gen_parser_tables.zig`). Unit `pass`
/// productions are eliminated during generation, so the driver never performs a
/// do-nothing chain reduction — every reduce runs a real semantic action.
const Tab = @import("parser_tables");
const Act = grammar.Act;

/// One attribute-path segment: a static name or a dynamic `${expr}`.
const Seg = union(enum) {
    static: Node.Atom,
    dynamic: *Node,
};

/// Accumulator for an attribute path's segments. Almost every attrpath is 1-2
/// segments (`x`, `x.y`), so those live inline with no allocation; longer paths
/// spill to a heap list. The segments are transient scratch — every consumer
/// (`foldBind`/`buildSelect`/`makeHasAttr`) copies them into a right-sized arena
/// structure — so inline storage never escapes.
const seg_inline = 2;
const SegAccum = struct {
    buf: [seg_inline]Seg = undefined,
    len: u32 = 0,
    spill: ?*std.ArrayListUnmanaged(Seg) = null,

    fn push(self: *SegAccum, a: std.mem.Allocator, seg: Seg) !void {
        if (self.spill) |s| {
            try s.append(a, seg);
        } else if (self.len < seg_inline) {
            self.buf[self.len] = seg;
        } else {
            const s = try a.create(std.ArrayListUnmanaged(Seg));
            s.* = .empty;
            try s.ensureTotalCapacity(a, seg_inline * 2);
            s.appendSliceAssumeCapacity(self.buf[0..self.len]);
            s.appendAssumeCapacity(seg);
            self.spill = s;
        }
        self.len += 1;
    }

    fn items(self: *const SegAccum) []const Seg {
        return if (self.spill) |s| s.items else self.buf[0..self.len];
    }
};

/// One element inside a `{ ... }`. The parser cannot know whether a brace is an
/// attribute set or a lambda pattern until it sees what follows the `}`, so
/// each element is parsed into this union and validated once the role is known.
const Clause = union(enum) {
    formal: Node.LambdaAttrParam, // pattern: `a` or `a ? default`
    ellipsis, // pattern: `...`
    bind: Node.AttrSetEntry, // attrset: `attrpath = expr`
    inherit: []Node.AttrSetEntry, // attrset: `inherit ...` (one or more names)
};

/// A parsed `{ ... }` group plus its opening brace (for diagnostics).
const Brace = struct {
    clauses: std.ArrayListUnmanaged(Clause),
    lbrace: Token,
};

/// A semantic value on the parse stack. Which variant is live is fully
/// determined by the grammar symbol reduced, so the union is untagged: no tag
/// byte in the (hot, per-symbol) value stack and no discriminant checks.
const Value = union {
    tok: Token,
    node: *Node,
    seg: Seg,
    segs: SegAccum,
    entries: std.ArrayListUnmanaged(Node.AttrSetEntry),
    names: std.ArrayListUnmanaged(Node.Atom),
    nodes: std.ArrayListUnmanaged(*Node),
    clause: Clause,
    clauses: std.ArrayListUnmanaged(Clause),
    brace: Brace,
    nil: void,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    arena: *ast.AstArena,
    source: []const u8,
    had_error: bool,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    /// Whether any `|>`/`<|` pipe operator was parsed. Enforcement that the
    /// `pipe-operators` feature is enabled happens at the compile chokepoint
    /// (`Engine.parseAndCompile`), which reads this flag.
    used_pipe_operators: bool,
    /// The earliest pipe operator token seen, for a precise "disabled"
    /// diagnostic.
    first_pipe_token: ?Token,
    /// Offset of the first structural CR (`\r`) line ending, or null. Set from
    /// the scanner after driving. The compile chokepoint gates it on the
    /// `cr-line-endings` deprecated feature, like `used_pipe_operators`.
    first_cr_offset: ?u32 = null,
    /// Clause identity for preserving `inherit (expr) a b` as one source
    /// group through the otherwise entry-oriented AST.
    next_inherit_group: u32 = 1,
    /// Deprecated-syntax warnings recorded during parsing (feature-agnostic);
    /// the consumer emits the ones whose feature is disabled.
    warnings: std.ArrayListUnmanaged(DeprecationWarning) = .empty,
    /// Offset of the first `tokens-no-whitespace` adjacency (a value token
    /// stuck to the next token), or null. Gated at the compile chokepoint.
    first_tokens_no_ws_offset: ?u32 = null,
    /// Body-span elision (lazy parsing): when enabled, a bind body inside a
    /// plain `{ ... }` that (a) appears after `elide_min_prior_clauses`
    /// earlier clauses in the same brace, (b) spans at least
    /// `elide_min_body_bytes`, and (c) is deferral-shaped (see
    /// `scanElidableBody`'s shape gate) is NOT parsed. Its tokens are
    /// skipped by a balanced span scan and a single `.elided` node holding
    /// the span is spliced onto the parse stack; the compiler sub-parses it
    /// on demand. Default off — `Engine.parseAndCompile` enables it for
    /// file compiles, mirroring the lazy per-attr compilation gate
    /// (`compiler/attrs.zig shouldDeferSet`). Note this makes parse errors
    /// inside such bodies surface at first *force* instead of at parse time
    /// — the same deal deferred compilation already makes for compile
    /// errors (an unforced body's errors are never reported).
    elide_bodies: bool = false,

    /// Expression-position uses of `true`/`false`/`null`, which lex as plain
    /// identifiers because Nix binds them in the base environment rather than
    /// reserving them. Unless the file binds one of the three names, `parse`
    /// retags these nodes to `.bool_true`/`.bool_false`/`.null` so every
    /// constant path downstream keeps seeing a literal. Arena-allocated: it
    /// points into the tree and dies with it.
    keyword_literal_refs: std.ArrayListUnmanaged(*Node) = .empty,
    /// Set when a binder (or attribute) named `true`/`false`/`null` is parsed.
    /// Deliberately over-approximate — an attribute *name* is not a binder, but
    /// treating it as one only costs the retag above.
    ///
    /// The retag is sound only for a whole-file parse: a caller sub-parsing one
    /// span (`compiler/literals.zig` — an elided body, a `${…}` interpolation)
    /// cannot see an enclosing binder, so it sets this before `parse` to keep
    /// the uses variables. The compiler then re-decides per use from the live
    /// scope (`compiler/access.zig compileRawIdent`).
    keyword_literal_bound: bool = false,

    /// Gate tunables for body-span elision. Mirror the lazy per-attr
    /// compilation gates (`compiler/deferred_table.zig` min_body_bytes /
    /// min_entries — cross-checked there at comptime): an elided body is
    /// only profitable if the compiler would have deferred it anyway.
    pub const elide_min_body_bytes: u32 = 100;
    pub const elide_min_prior_clauses: u32 = 64;

    pub fn init(allocator: std.mem.Allocator, arena: *ast.AstArena, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .arena = arena,
            .source = source,
            .had_error = false,
            .diagnostics = .empty,
            .used_pipe_operators = false,
            .first_pipe_token = null,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.diagnostics.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
    }

    // ---- `true` / `false` / `null` ----

    /// An identifier in a binding position (`x:`, `{ x }:`, `x = …`, `inherit x`).
    /// Naming one of the three constants means a lexical binder may shadow it,
    /// so no use in this file may be folded to a literal.
    fn noteBinder(self: *Parser, tok: Token) void {
        var text = self.span(tok);
        // A quoted attribute name binds exactly like a bare one
        // (`let "true" = 1; in true` is `1`). Only the three literal spellings
        // can match, so an interpolated name never reaches the comparison.
        if (std.mem.startsWith(u8, text, "''") and std.mem.endsWith(u8, text[2..], "''")) {
            text = text[2 .. text.len - 2];
        } else if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            text = text[1 .. text.len - 1];
        }
        if (ast.keywordLiteralTag(text) != null) self.keyword_literal_bound = true;
    }

    fn formalName(self: *Parser, tok: Token) Node.Atom {
        self.noteBinder(tok);
        return .{ .offset = tok.offset, .len = tok.len };
    }

    fn noteWarning(self: *Parser, kind: DeprecationWarning.Kind, tok: Token) !void {
        try self.noteWarningAt(kind, tok.offset, tok.len);
    }

    fn noteWarningAt(self: *Parser, kind: DeprecationWarning.Kind, offset: u32, len: u32) !void {
        try self.warnings.append(self.allocator, .{ .kind = kind, .offset = offset, .len = len });
    }

    pub fn span(self: *const Parser, tok: Token) []const u8 {
        return self.source[tok.offset .. tok.offset + tok.len];
    }

    fn arenaAllocator(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    // ---- pipe provenance ----

    fn notePipe(self: *Parser, tok: Token) void {
        if (!self.used_pipe_operators) {
            self.used_pipe_operators = true;
            self.first_pipe_token = tok;
        } else if (self.first_pipe_token) |cur| {
            if (tok.offset < cur.offset) self.first_pipe_token = tok;
        }
    }

    // ---- diagnostics ----

    /// Diagnostic line for a token. Normal tokens use their end offset;
    /// unterminated error tokens use their start offset.
    pub fn tokenLine(source: []const u8, tok: Token) u32 {
        const target = if (tok.type == .error_token) tok.offset else tok.offset + tok.len;
        return diagnostic.lineForOffset(source, target);
    }

    fn report(self: *Parser, tok: Token, msg: []const u8) !void {
        self.had_error = true;
        try self.diagnostics.append(self.allocator, .{
            .line = tokenLine(self.source, tok),
            .column = diagnostic.columnForOffset(self.source, tok.offset),
            .offset = tok.offset,
            .len = tok.len,
            .token_type = tok.type,
            .message = msg,
        });
    }

    /// Report a semantic parse error anchored at an AST atom (an attribute or
    /// formal name), rather than a live token — the position Nix points at for
    /// duplicate-attribute / duplicate-formal errors.
    fn reportAtom(self: *Parser, at: Node.Atom, msg: []const u8) !void {
        self.had_error = true;
        try self.appendAtomDiagnostic(.err, at, msg);
    }

    /// A follow-up note (e.g. "first attribute defined here"); does not itself
    /// mark the parse failed — the paired error already did.
    fn noteAtom(self: *Parser, at: Node.Atom, msg: []const u8) !void {
        try self.appendAtomDiagnostic(.note, at, msg);
    }

    fn appendAtomDiagnostic(self: *Parser, severity: Diagnostic.Severity, at: Node.Atom, msg: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .severity = severity,
            .line = diagnostic.lineForOffset(self.source, at.offset),
            .column = diagnostic.columnForOffset(self.source, at.offset),
            .offset = at.offset,
            .len = at.len,
            .token_type = null,
            .message = msg,
        });
    }

    fn atomText(self: *Parser, at: Node.Atom) []const u8 {
        return self.source[at.offset..][0..at.len];
    }

    /// Reject duplicate attribute definitions the way Nix does at parse time,
    /// following its attrpath-merge rule: nested paths (`a.b`, `a.c`) and set
    /// literals merge; only a genuinely repeated leaf, or a leaf clashing with a
    /// set, is an error — reported at the later occurrence. Dynamic keys
    /// (`${e} = …`) aren't statically checkable and are skipped. An entry whose
    /// value was body-elided is also skipped (the parser cannot see whether it
    /// is a mergeable set), and remains covered by the compiler's own check.
    fn checkDuplicateAttrs(self: *Parser, entries: []const Node.AttrSetEntry, is_binding: bool) !void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var root: DupTree = .{};
        for (entries) |entry| try self.addAttrDef(a, &root, "", entry, is_binding);
    }

    fn addAttrDef(self: *Parser, a: std.mem.Allocator, tree: *DupTree, prefix: []const u8, entry: Node.AttrSetEntry, is_binding: bool) !void {
        if (entry.dynamic_name != null or entry.path.len == 0) return; // dynamic key: skip
        const val = ast.unwrapParens(entry.expr);
        if (val.tag == .elided) return; // body-elided: parser can't see it — compiler covers it
        var cur = tree;
        var pfx = prefix;
        // Descend prefix segments, creating/merging subtrees. Meeting a leaf
        // where a set is required is a conflict.
        for (entry.path[0 .. entry.path.len - 1]) |seg| {
            const name = self.atomText(seg);
            pfx = try dotJoin(a, pfx, name);
            const gop = try cur.map.getOrPut(a, name);
            if (!gop.found_existing) {
                const sub = try a.create(DupTree);
                sub.* = .{};
                gop.value_ptr.* = .{ .pos = seg, .sub = sub };
                cur = sub;
            } else if (gop.value_ptr.sub) |sub| {
                cur = sub;
            } else {
                return self.dupConflict(seg, gop.value_ptr.pos, pfx, is_binding);
            }
        }
        const last = entry.path[entry.path.len - 1];
        const name = self.atomText(last);
        const full = try dotJoin(a, pfx, name);
        // Any set literal (recursive or not) merges into the tree; anything else
        // is a leaf.
        const set_entries: ?[]const Node.AttrSetEntry =
            if (val.tag == .attr_set) val.data.attr_set.entries else null;
        const gop = try cur.map.getOrPut(a, name);
        if (!gop.found_existing) {
            if (set_entries) |es| {
                const sub = try a.create(DupTree);
                sub.* = .{};
                gop.value_ptr.* = .{ .pos = last, .sub = sub };
                for (es) |e| try self.addAttrDef(a, sub, full, e, is_binding);
            } else {
                gop.value_ptr.* = .{ .pos = last, .sub = null };
            }
        } else if (gop.value_ptr.sub) |sub| {
            if (set_entries) |es| {
                for (es) |e| try self.addAttrDef(a, sub, full, e, is_binding);
            } else {
                return self.dupConflict(last, gop.value_ptr.pos, full, is_binding);
            }
        } else {
            return self.dupConflict(last, gop.value_ptr.pos, full, is_binding);
        }
    }

    /// Report a duplicate definition: an error at the later occurrence plus a
    /// note at the first. `is_binding` selects `let`-binding vs attribute
    /// wording, matching Nix.
    fn dupConflict(self: *Parser, dup: Node.Atom, first: Node.Atom, full: []const u8, is_binding: bool) !void {
        const noun = if (is_binding) "variable" else "attribute";
        const msg = try std.fmt.allocPrint(self.arenaAllocator(), "{s} '{s}' already defined", .{ noun, full });
        try self.reportAtom(dup, msg);
        try self.noteAtom(first, if (is_binding) "first binding defined here" else "first attribute defined here");
        return error.ParseError;
    }

    fn dotJoin(a: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
        if (prefix.len == 0) return name;
        return std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, name });
    }

    // ---- entry point ----

    pub fn parse(self: *Parser) !*Node {
        var scanner = Scanner.init(self.source);
        const root = try self.drive(&scanner);
        self.first_cr_offset = scanner.first_cr;
        self.first_tokens_no_ws_offset = scanner.first_tokens_no_ws;
        if (scanner.first_float_no_zero) |f| {
            try self.noteWarningAt(.floating_without_zero, f.offset, f.len);
        }

        if (self.had_error) return error.ParseError;
        const top = root orelse return error.ParseError;

        if (!self.keyword_literal_bound) {
            // Nothing in this file binds `true`/`false`/`null`, so every use is
            // the base-env constant: fold them back into literal nodes.
            for (self.keyword_literal_refs.items) |node| {
                node.tag = ast.keywordLiteralTag(self.atomText(node.data.atom)).?;
            }
        }
        return top;
    }

    // ---- the shift/reduce driver ----

    /// Pull the next parseable token, reporting (and skipping) invalid ones.
    fn nextToken(self: *Parser, scanner: *Scanner) !Token {
        while (true) {
            const tk = scanner.next();
            if (tk.type == .error_token) {
                try self.report(tk, "Invalid token.");
                continue;
            }
            return tk;
        }
    }

    /// Binding-context tracking for body-span elision: the kind of the
    /// innermost open construct that could own a `=` bind. Only a plain
    /// (non-`rec`) brace is elidable — `rec { }` / `let ... in` bindings
    /// never defer, and `${ ... }` only nests an expression.
    const BindCtx = struct {
        kind: enum(u8) { brace, other_brace, let_block },
        /// Clauses terminated so far in this brace (approximate: counts
        /// `;` shifts, which is exact for generated package sets).
        clauses: u32 = 0,
    };

    fn drive(self: *Parser, scanner: *Scanner) !?*Node {
        const gpa = self.allocator;
        // Tokens stream straight from the scanner — no token array. The
        // stack starts at a depth that covers any sane nesting (left
        // recursion keeps lists flat, so depth tracks *nesting* only) and
        // grows geometrically for pathological inputs.
        var cap: usize = 256;
        var states = try gpa.alloc(u32, cap);
        defer gpa.free(states);
        var vals = try gpa.alloc(Value, cap);
        defer gpa.free(vals);

        var sp: usize = 0; // number of entries on the stack
        states[sp] = Tab.start_state;
        vals[sp] = .{ .nil = {} };
        sp += 1;

        // Body-span elision bookkeeping (only maintained when enabled —
        // one predictable branch per shift otherwise).
        var ctx_stack: std.ArrayListUnmanaged(BindCtx) = .empty;
        defer ctx_stack.deinit(gpa);
        var last_shifted: TokenType = .eof;

        var tok = try self.nextToken(scanner);
        var error_count: usize = 0;
        const max_errors = 32;
        // Error cooldown: after reporting an error, stay quiet until the parser
        // has shifted a few real tokens again. This collapses the cascade of
        // spurious follow-on errors panic-mode recovery would otherwise emit.
        // Starts "elapsed" so the first error always reports.
        const cooldown = 3;
        var quiet_shifts: u32 = cooldown;
        while (true) {
            const state = states[sp - 1];
            const la = @intFromEnum(tok.type);
            const c = Tab.action[state * Tab.num_terminals + la];
            switch (lr.cellKind(c)) {
                lr.action_shift => {
                    if (sp + 2 > cap) {
                        cap *= 2;
                        states = try gpa.realloc(states, cap);
                        vals = try gpa.realloc(vals, cap);
                    }
                    if (self.elide_bodies) elide: {
                        // Grammar-wide, `=` appears only in the two bind
                        // productions (`attrpath = expr ;` / let-`bind`), so
                        // every `=` shift starts a bind body. Elide it when
                        // the innermost binding context is a plain brace
                        // that has already accumulated enough clauses.
                        if (tok.type != .equal or self.had_error) break :elide;
                        const top = if (ctx_stack.items.len > 0) ctx_stack.items[ctx_stack.items.len - 1] else break :elide;
                        if (top.kind != .brace or top.clauses < elide_min_prior_clauses) break :elide;
                        const eq_state = lr.cellArg(c);
                        const g = Tab.goto_table[eq_state * Tab.num_nonterminals + @intFromEnum(grammar.Nonterminal.expr)];
                        if (g < 0) break :elide;
                        const res = self.scanElidableBody(scanner) orelse break :elide;
                        // Shift the `=`, then splice the elided body onto the
                        // stack as an already-reduced Expr (goto on the Expr
                        // nonterminal with a synthetic value); the pending
                        // lookahead becomes the terminating `;`.
                        states[sp] = eq_state;
                        vals[sp] = .{ .tok = tok };
                        sp += 1;
                        const node = try self.arena.createNode(.elided, .{ .atom = res.span });
                        states[sp] = @intCast(g);
                        vals[sp] = .{ .node = node };
                        sp += 1;
                        scanner.* = res.scanner;
                        tok = res.semi;
                        last_shifted = .equal;
                        continue;
                    }
                    states[sp] = lr.cellArg(c);
                    vals[sp] = .{ .tok = tok };
                    sp += 1;
                    if (self.elide_bodies) {
                        switch (tok.type) {
                            .left_brace => try ctx_stack.append(gpa, .{
                                .kind = if (last_shifted == .kw_rec) .other_brace else .brace,
                            }),
                            .dollar_curly => try ctx_stack.append(gpa, .{ .kind = .other_brace }),
                            .kw_let => try ctx_stack.append(gpa, .{ .kind = .let_block }),
                            .kw_in => {
                                if (ctx_stack.items.len > 0 and ctx_stack.items[ctx_stack.items.len - 1].kind == .let_block) {
                                    _ = ctx_stack.pop();
                                }
                            },
                            .right_brace => {
                                if (ctx_stack.items.len > 0 and ctx_stack.items[ctx_stack.items.len - 1].kind != .let_block) {
                                    _ = ctx_stack.pop();
                                }
                            },
                            .semicolon => {
                                if (ctx_stack.items.len > 0) {
                                    const top = &ctx_stack.items[ctx_stack.items.len - 1];
                                    if (top.kind == .brace) top.clauses += 1;
                                }
                            },
                            else => {},
                        }
                        last_shifted = tok.type;
                    }
                    tok = try self.nextToken(scanner);
                    if (quiet_shifts < cooldown) quiet_shifts += 1;
                },
                lr.action_reduce => {
                    const p = lr.cellArg(c);
                    const n = Tab.prod_rhs_len[p];
                    const base = sp - n;
                    const result = try self.runAction(grammar.act_of_prod[p], vals[base .. base + n]);
                    sp = base;
                    const g = Tab.goto_table[states[sp - 1] * Tab.num_nonterminals + Tab.prod_lhs[p]];
                    if (g < 0) {
                        try self.report(tok, "Internal parser error (no goto).");
                        return null;
                    }
                    if (sp == cap) { // only epsilon productions grow the stack here
                        cap *= 2;
                        states = try gpa.realloc(states, cap);
                        vals = try gpa.realloc(vals, cap);
                    }
                    states[sp] = @intCast(g);
                    vals[sp] = result;
                    sp += 1;
                },
                lr.action_accept => {
                    return vals[sp - 1].node;
                },
                else => {
                    if (quiet_shifts >= cooldown) {
                        try self.reportUnexpected(state, tok);
                        error_count += 1;
                        if (error_count >= max_errors) return null;
                    } else {
                        self.had_error = true;
                    }
                    quiet_shifts = 0;
                    if (!try self.recover(states[sp - 1], scanner, &tok)) return null;
                },
            }
        }
    }

    /// Panic-mode recovery. Keep the parse stack intact (preserving the current
    /// context, e.g. the enclosing `{ ... }`) and discard input tokens until the
    /// current top state has a real action on one — typically the next clause
    /// separator or the context's closing token. The value stack is untouched,
    /// so it stays consistent with the state stack and semantic actions keep
    /// running safely; the recovered tree is discarded anyway, since the
    /// recorded error forces `parse` to return `ParseError`. Returns false at
    /// EOF (nothing left to resynchronize on).
    fn recover(self: *Parser, top_state: u32, scanner: *Scanner, tok: *Token) !bool {
        const terminal_count = Tab.num_terminals;
        while (true) {
            if (tok.type == .eof) return false;
            tok.* = try self.nextToken(scanner); // discard a token (starting with the offending one)
            const la = @intFromEnum(tok.type);
            if (lr.cellKind(Tab.action[top_state * terminal_count + la]) != lr.action_error) return true;
        }
    }

    // ---- body-span elision ----

    const ElideResult = struct {
        /// The body's exact source span: first body token's start to the
        /// terminating `;` (exclusive; may include trailing layout/comments,
        /// which the sub-parse skips identically).
        span: Node.Atom,
        /// The terminating `;`, handed back as the pending lookahead.
        semi: Token,
        /// Scanner state just past the `;`.
        scanner: Scanner,
    };

    /// Scan (without parsing) from just after a bind's `=` to its
    /// terminating `;`, and decide whether the body may be elided. Works on
    /// a COPY of the scanner, so a bail leaves the parse untouched.
    ///
    /// Finding the right `;` is a token-level balance scan — the scanner
    /// already lexes strings (with nested interpolation), paths, and
    /// comments as opaque units, so only real structure needs tracking:
    ///   - bracket depth: `(`/`[`/`{`/`${` vs `)`/`]`/`}` (bail if the body
    ///     would close an enclosing group — malformed or `}`-terminated);
    ///   - `let ... in` at depth 0: every `;` before the matching `in`
    ///     belongs to the let's bindings;
    ///   - `assert`/`with` at depth 0 (outside open lets): each owns one
    ///     following `;`.
    ///
    /// Shape gate (mirrors `compiler/attrs.zig isDeferrableBody`): bodies
    /// the compiler would compile as immediate values — single-token atoms,
    /// lambdas (`x:`/`x@`/`{..}:`/`{..}@`), whole-body `{..}`/`[..]`
    /// literals, `rec`-rooted sets, and whole-body parens (opaque without
    /// unwrapping) — are NOT elided, so an elided body is always
    /// deferral-shaped and the compiler may defer it without inspecting it.
    ///
    /// Returns null to fall back to normal parsing (also on any token-level
    /// anomaly: error tokens, EOF, unbalanced closers, undersized bodies).
    fn scanElidableBody(self: *Parser, scanner: *const Scanner) ?ElideResult {
        var sc = scanner.*;
        const first = sc.next();
        switch (first.type) {
            // Not a body / immediate-shaped roots (see shape gate above).
            .semicolon, .eof, .error_token, .kw_rec, .left_paren => return null,
            else => {},
        }
        const first_opens_group = first.type == .left_brace or first.type == .left_bracket;

        var depth: u32 = 0;
        var lets: u32 = 0;
        var pending_semis: u32 = 0;
        var i: u32 = 0; // token ordinal within the body (0 == `first`)
        var second_type: TokenType = .eof;
        var first_group_close: ?u32 = null; // ordinal of the token closing the first-token group
        var after_first_group: TokenType = .eof; // the token right after that close
        var tk = first;
        const semi = while (true) {
            if (i == 1) second_type = tk.type;
            if (first_group_close) |gc| {
                if (i == gc + 1) after_first_group = tk.type;
            }
            switch (tk.type) {
                .eof, .error_token => return null,
                // Record pipe usage for the compile-time feature gate —
                // these tokens are otherwise never seen by the driver.
                .pipe_forward, .pipe_backward => self.notePipe(tk),
                .left_paren, .left_bracket, .left_brace, .dollar_curly => depth += 1,
                .right_paren, .right_bracket, .right_brace => {
                    if (depth == 0) return null;
                    depth -= 1;
                    if (depth == 0 and first_opens_group and first_group_close == null) first_group_close = i;
                },
                .kw_let => {
                    if (depth == 0) lets += 1;
                },
                .kw_in => {
                    if (depth == 0) {
                        if (lets == 0) return null;
                        lets -= 1;
                    }
                },
                .kw_assert, .kw_with => {
                    if (depth == 0 and lets == 0) pending_semis += 1;
                },
                .semicolon => {
                    if (depth == 0) {
                        if (lets > 0) {
                            // a `let` binding separator — not ours
                        } else if (pending_semis > 0) {
                            pending_semis -= 1;
                        } else {
                            break tk; // the bind's terminator
                        }
                    }
                },
                else => {},
            }
            i += 1;
            tk = sc.next();
        };

        // Shape gate (see doc comment).
        if (i == 1) return null; // single-token body: always an immediate atom
        if (first.type == .identifier and (second_type == .colon or second_type == .at)) return null; // lambda
        if (first_opens_group) {
            if (after_first_group == .colon or after_first_group == .at) return null; // lambda pattern
            if (first_group_close.? == i - 1) return null; // body is exactly `{..}` / `[..]`
        }

        // Size gate: mirrors the deferral gate's min_body_bytes.
        const len = semi.offset - first.offset;
        if (len < elide_min_body_bytes) return null;

        return .{
            .span = .{ .offset = first.offset, .len = len },
            .semi = semi,
            .scanner = sc,
        };
    }

    fn reportUnexpected(self: *Parser, state: u32, tok: Token) !void {
        _ = state;
        var buf: [256]u8 = undefined;
        const written = if (tok.type == .eof)
            "Unexpected end of input."
        else
            std.fmt.bufPrint(&buf, "Unexpected token '{s}'.", .{
                self.source[tok.offset .. tok.offset + tok.len],
            }) catch "Syntax error.";
        // Persist the message in the arena so it outlives `buf`.
        const msg = try self.arenaAllocator().dupe(u8, written);
        try self.report(tok, msg);
    }

    // ---- semantic actions ----

    fn runAction(self: *Parser, act: Act, rhs: []Value) !Value {
        const a = self.arenaAllocator();
        switch (act) {
            .augmented => unreachable,
            .pass => return rhs[0],

            // ---- Expr (function level) ----
            .lambda_id => {
                const name = rhs[0].tok;
                self.noteBinder(name);
                return .{ .node = try self.arena.createNode(.lambda, .{ .lambda = .{
                    .param_offset = name.offset,
                    .param_len = name.len,
                    .body = rhs[2].node,
                } }) };
            },
            .lambda_no_bind => return self.buildLambda(rhs[0].brace, null, rhs[2].node),
            .lambda_bind_before => {
                const bind = rhs[0].tok;
                self.noteBinder(bind);
                return self.buildLambda(rhs[2].brace, .{ .offset = bind.offset, .len = bind.len }, rhs[4].node);
            },
            .lambda_bind_after => {
                const bind = rhs[2].tok;
                self.noteBinder(bind);
                return self.buildLambda(rhs[0].brace, .{ .offset = bind.offset, .len = bind.len }, rhs[4].node);
            },
            .assert_ => return .{ .node = try self.arena.createNode(.assert, .{ .assert = .{
                .cond = rhs[1].node,
                .body = rhs[3].node,
            } }) },
            .with_ => return .{ .node = try self.arena.createNode(.with_expr, .{ .with_expr = .{
                .attr_set = rhs[1].node,
                .body = rhs[3].node,
            } }) },
            .let_in => return self.buildLetIn(rhs),

            // ---- ExprIf ----
            .if_else => return .{ .node = try self.arena.createNode(.if_else, .{ .if_else = .{
                .cond = rhs[1].node,
                .then_branch = rhs[3].node,
                .else_branch = rhs[5].node,
            } }) },

            // ---- binary operators ----
            .bin_impl => return self.binary(.impl, rhs),
            .bin_or => return self.binary(.or_, rhs),
            .bin_and => return self.binary(.and_, rhs),
            .bin_eq => return self.binary(.eq, rhs),
            .bin_neq => return self.binary(.neq, rhs),
            .bin_lt => return self.binary(.lt, rhs),
            .bin_lte => return self.binary(.lte, rhs),
            .bin_gt => return self.binary(.gt, rhs),
            .bin_gte => return self.binary(.gte, rhs),
            .bin_update => return self.binary(.update, rhs),
            .bin_add => return self.binary(.add, rhs),
            .bin_sub => return self.binary(.sub, rhs),
            .bin_mul => return self.binary(.mul, rhs),
            .bin_div => return self.binary(.div, rhs),
            .bin_concat => return self.binary(.concat, rhs),
            .has_attr => return self.makeHasAttr(rhs[0].node, rhs[2].segs),
            .pipe_fwd => {
                self.notePipe(rhs[1].tok);
                return .{ .node = try self.arena.createNode(.apply, .{ .apply = .{
                    .func = rhs[2].node,
                    .arg = rhs[0].node,
                    .pipe = .forward,
                } }) };
            },
            .pipe_bwd => {
                self.notePipe(rhs[1].tok);
                return .{ .node = try self.arena.createNode(.apply, .{ .apply = .{
                    .func = rhs[0].node,
                    .arg = rhs[2].node,
                    .pipe = .backward,
                } }) };
            },
            .not => return .{ .node = try self.arena.createNode(.unary_op, .{ .unary = .{
                .op = .not,
                .expr = rhs[1].node,
            } }) },
            .negate => return .{ .node = try self.arena.createNode(.unary_op, .{ .unary = .{
                .op = .negate,
                .expr = rhs[1].node,
            } }) },

            // ---- application ----
            .apply => return .{ .node = try self.arena.createNode(.apply, .{ .apply = .{
                .func = rhs[0].node,
                .arg = rhs[1].node,
                .pipe = .none,
            } }) },

            // ---- application of the bare `or` identifier (`f or` → `f (or)`) ----
            .apply_or => {
                try self.noteWarning(.or_as_identifier, rhs[1].tok);
                const or_var = try self.atom(.identifier, rhs[1].tok);
                return .{ .node = try self.arena.createNode(.apply, .{ .apply = .{
                    .func = rhs[0].node,
                    .arg = or_var.node,
                    .pipe = .none,
                } }) };
            },

            // ---- selection ----
            .select => return .{ .node = try self.buildSelect(rhs[0].node, rhs[2].segs) },
            .select_or => {
                const selected = try self.buildSelect(rhs[0].node, rhs[2].segs);
                return .{ .node = try self.arena.createNode(.attr_or, .{ .attr_or = .{
                    .attr_path = selected,
                    .default = rhs[4].node,
                } }) };
            },

            // ---- atoms ----
            .ident => {
                const value = try self.atom(.identifier, rhs[0].tok);
                // Record `true`/`false`/`null` for `parse`'s retag pass.
                if (ast.keywordLiteralTag(self.span(rhs[0].tok)) != null) {
                    try self.keyword_literal_refs.append(self.arenaAllocator(), value.node);
                }
                return value;
            },
            .integer => return self.atom(.integer, rhs[0].tok),
            .float_val => return self.atom(.float_val, rhs[0].tok),
            .string => return self.atom(.string, rhs[0].tok),
            .path => {
                // Nix rejects a path literal with a trailing slash (`/nix/store/`).
                // A lone `/` is the division operator, never a path token, so any
                // path token ending in `/` is a genuine trailing slash.
                const tok = rhs[0].tok;
                if (tok.len >= 1 and self.source[tok.offset + tok.len - 1] == '/') {
                    try self.report(tok, "path has a trailing slash");
                    return error.ParseError;
                }
                return self.atom(.path, tok);
            },
            .uri => return self.atom(.uri, rhs[0].tok),
            .search_path => return self.atom(.search_path, rhs[0].tok),
            .parens => return .{ .node = try self.arena.createNode(.parens, .{ .parens = rhs[1].node }) },
            .attrset_from_brace => return self.buildAttrSet(rhs[0].brace),
            .rec_attr_set => return self.buildRecursiveAttrSet(rhs),
            .let_attrs => return self.buildLegacyLetAttrs(rhs),
            .list => {
                var nodes = rhs[1].nodes;
                return .{ .node = try self.arena.createNode(.list, .{ .list = .{
                    .items = try nodes.toOwnedSlice(a),
                } }) };
            },

            // ---- attrpath / attr ----
            .attrpath_one => {
                var segs: SegAccum = .{};
                try segs.push(a, rhs[0].seg);
                return .{ .segs = segs };
            },
            .attrpath_append => {
                var segs = rhs[0].segs;
                try segs.push(a, rhs[2].seg);
                return .{ .segs = segs };
            },
            .attr_static => {
                // `or` used as an attribute name (`let or = 1;`, `x.or`) is the
                // deprecated `or`-as-identifier syntax.
                if (rhs[0].tok.type == .kw_or) try self.noteWarning(.or_as_identifier, rhs[0].tok);
                self.noteBinder(rhs[0].tok);
                return .{ .seg = .{ .static = .{ .offset = rhs[0].tok.offset, .len = rhs[0].tok.len } } };
            },
            .attr_dynamic => return .{ .seg = .{ .dynamic = rhs[1].node } },

            // ---- brace / clauses (unified attrset-or-pattern body) ----
            .brace_group => return .{ .brace = .{ .clauses = rhs[1].clauses, .lbrace = rhs[0].tok } },
            .brace_empty => return .{ .clauses = .empty },
            .bc_final => {
                var list: std.ArrayListUnmanaged(Clause) = .empty;
                try list.append(a, rhs[0].clause);
                return .{ .clauses = list };
            },
            .bc_terms_final => {
                var list = rhs[0].clauses;
                try list.append(a, rhs[1].clause);
                return .{ .clauses = list };
            },
            .term_clauses_one => {
                var list: std.ArrayListUnmanaged(Clause) = .empty;
                try list.append(a, rhs[0].clause);
                return .{ .clauses = list };
            },
            .term_clauses_append => {
                var list = rhs[0].clauses;
                try list.append(a, rhs[1].clause);
                return .{ .clauses = list };
            },
            .tclause_formal_comma => return .{ .clause = .{ .formal = .{
                .name = self.formalName(rhs[0].tok),
                .default = null,
            } } },
            .tclause_formal_default_comma => return .{ .clause = .{ .formal = .{
                .name = self.formalName(rhs[0].tok),
                .default = rhs[2].node,
            } } },
            .tclause_bind => {
                const segs = rhs[0].segs;
                const entry = try self.foldBind(segs.items(), rhs[2].node);
                return .{ .clause = .{ .bind = entry } };
            },
            .tclause_inherit => return .{ .clause = .{ .inherit = try self.inheritEntries(null, rhs[1].names, rhs[0].tok) } },
            .tclause_inherit_from => return .{ .clause = .{ .inherit = try self.inheritEntries(rhs[2].node, rhs[4].names, rhs[0].tok) } },
            .fclause_formal => return .{ .clause = .{ .formal = .{
                .name = self.formalName(rhs[0].tok),
                .default = null,
            } } },
            .fclause_formal_default => return .{ .clause = .{ .formal = .{
                .name = self.formalName(rhs[0].tok),
                .default = rhs[2].node,
            } } },
            .fclause_ellipsis => return .{ .clause = .ellipsis },

            // ---- binds ----
            .binds_empty => return .{ .entries = .empty },
            .binds_append => {
                var acc = rhs[0].entries;
                var add = rhs[1].entries;
                try acc.appendSlice(a, add.items);
                add.deinit(a);
                return .{ .entries = acc };
            },
            .bind_normal => {
                const segs = rhs[0].segs;
                const entry = try self.foldBind(segs.items(), rhs[2].node);
                var list: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;
                try list.append(a, entry);
                return .{ .entries = list };
            },
            .bind_inherit => {
                var list: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;
                try list.appendSlice(a, try self.inheritEntries(null, rhs[1].names, rhs[0].tok));
                return .{ .entries = list };
            },
            .bind_inherit_from => {
                var list: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;
                try list.appendSlice(a, try self.inheritEntries(rhs[2].node, rhs[4].names, rhs[0].tok));
                return .{ .entries = list };
            },
            .inherit_names_empty => return .{ .names = .empty },
            .inherit_names_append => {
                var names = rhs[0].names;
                self.noteBinder(rhs[1].tok);
                try names.append(a, .{ .offset = rhs[1].tok.offset, .len = rhs[1].tok.len });
                return .{ .names = names };
            },

            // ---- list ----
            .list_items_empty => return .{ .nodes = .empty },
            .list_items_append => {
                var nodes = rhs[0].nodes;
                try nodes.append(a, rhs[1].node);
                return .{ .nodes = nodes };
            },
        }
    }

    // ---- action helpers ----

    fn buildLetIn(self: *Parser, rhs: []Value) !Value {
        const a = self.arenaAllocator();
        var entries = rhs[1].entries;
        try self.checkDuplicateAttrs(entries.items, true);
        const bindings = try a.alloc(Node.Binding, entries.items.len);
        for (entries.items, bindings) |entry, *binding| {
            var path = entry.path;
            if (path.len == 0) {
                // Constant dynamic keys become static bindings; other dynamic
                // keys are not valid in a let.
                const folded = try self.constStringAttrAtom(entry.dynamic_name) orelse {
                    try self.report(rhs[2].tok, "Dynamic attributes are not allowed in let bindings.");
                    return error.ParseError;
                };
                const single = try a.alloc(Node.Atom, 1);
                single[0] = folded;
                path = single;
            }
            binding.* = .{
                .name_offset = path[0].offset,
                .name_len = path[0].len,
                .path = path,
                .expr = entry.expr,
                .inherit_outer = entry.inherit_outer,
                .inherit_group = entry.inherit_group,
            };
        }
        entries.deinit(a);
        return .{ .node = try self.arena.createNode(.let_in, .{ .let_in = .{
            .bindings = bindings,
            .body = rhs[3].node,
        } }) };
    }

    fn buildRecursiveAttrSet(self: *Parser, rhs: []Value) !Value {
        var entries = rhs[2].entries;
        try self.checkDuplicateAttrs(entries.items, false);
        // Dynamic attributes in a recursive set are evaluated outside its scope.
        for (entries.items) |entry| {
            if (entry.dynamic_name) |dynamic| {
                if (dynamic.span) |source_span| try self.noteWarningAt(.rec_set_dynamic_attrs, source_span.offset, source_span.len);
            }
        }
        return .{ .node = try self.arena.createNode(.attr_set, .{ .attr_set = .{
            .entries = try entries.toOwnedSlice(self.arenaAllocator()),
            .recursive = true,
        } }) };
    }

    /// `let { … }` evaluates `(rec { … }).body`.
    fn buildLegacyLetAttrs(self: *Parser, rhs: []Value) !Value {
        const a = self.arenaAllocator();
        var entries = rhs[2].entries;
        try self.checkDuplicateAttrs(entries.items, false);
        const recursive = try self.arena.createNode(.attr_set, .{ .attr_set = .{
            .entries = try entries.toOwnedSlice(a),
            .recursive = true,
        } });
        var body_name: ?Node.Atom = null;
        for (recursive.data.attr_set.entries) |entry| {
            if (entry.path.len != 1) continue;
            const segment = entry.path[0];
            if (std.mem.eql(u8, self.source[segment.offset .. segment.offset + segment.len], "body")) {
                body_name = segment;
                break;
            }
        }
        const selected = body_name orelse {
            try self.report(rhs[0].tok, "'let { ... }' requires a 'body' attribute");
            return error.ParseError;
        };
        var segments: SegAccum = .{};
        try segments.push(a, .{ .static = selected });
        return .{ .node = try self.buildSelect(recursive, segments) };
    }

    fn atom(self: *Parser, tag: NodeTag, tok: Token) !Value {
        return .{ .node = try self.arena.createNode(tag, .{ .atom = .{ .offset = tok.offset, .len = tok.len } }) };
    }

    fn binary(self: *Parser, op: ast.BinaryOp, rhs: []Value) !Value {
        return .{ .node = try self.arena.createNode(.binary_op, .{ .binary = .{
            .op = op,
            .left = rhs[0].node,
            .right = rhs[2].node,
        } }) };
    }

    /// Validate a `{ ... }` group as a lambda pattern and build the node. The
    /// grammar already guarantees formal ordering (commas between formals,
    /// `...` last), so this only rejects bind/inherit clauses.
    fn buildLambda(self: *Parser, brace: Brace, bind_name: ?Node.Atom, body: *Node) !Value {
        const a = self.arenaAllocator();
        var clauses = brace.clauses;
        defer clauses.deinit(a);
        var params: std.ArrayListUnmanaged(Node.LambdaAttrParam) = .empty;
        var allow_extra = false;
        for (clauses.items) |clause| {
            switch (clause) {
                .formal => |p| try params.append(a, p),
                .ellipsis => allow_extra = true,
                .bind, .inherit => {
                    try self.report(brace.lbrace, "Function argument pattern cannot contain attribute assignments.");
                    return error.ParseError;
                },
            }
        }
        // Reject duplicate formal argument names (Nix: "duplicate formal
        // function argument 'x'"), including one that collides with the
        // `@`-bound name. Report at the later (offending) occurrence.
        for (params.items, 0..) |p, i| {
            const name = self.atomText(p.name);
            var dup = bind_name != null and std.mem.eql(u8, name, self.atomText(bind_name.?));
            if (!dup) for (params.items[0..i]) |q| {
                if (std.mem.eql(u8, name, self.atomText(q.name))) {
                    dup = true;
                    break;
                }
            };
            if (dup) {
                const msg = try std.fmt.allocPrint(a, "duplicate formal function argument '{s}'", .{name});
                try self.reportAtom(p.name, msg);
                return error.ParseError;
            }
        }

        const la = try a.create(Node.LambdaAttrs);
        la.* = .{
            .bind_name = bind_name,
            .params = try params.toOwnedSlice(a),
            .allow_extra = allow_extra,
            .body = body,
        };
        return .{ .node = try self.arena.createNode(.lambda_attrs, .{ .lambda_attrs = la }) };
    }

    /// Validate a `{ ... }` group as an attribute set and build the node.
    fn buildAttrSet(self: *Parser, brace: Brace) !Value {
        const a = self.arenaAllocator();
        var clauses = brace.clauses;
        defer clauses.deinit(a);
        var entries: std.ArrayListUnmanaged(Node.AttrSetEntry) = .empty;
        for (clauses.items) |clause| {
            switch (clause) {
                .bind => |e| try entries.append(a, e),
                .inherit => |es| try entries.appendSlice(a, es),
                .formal, .ellipsis => {
                    try self.report(brace.lbrace, "Expected '=' after attribute name.");
                    return error.ParseError;
                },
            }
        }
        try self.checkDuplicateAttrs(entries.items, false);
        return .{ .node = try self.arena.createNode(.attr_set, .{ .attr_set = .{
            .entries = try entries.toOwnedSlice(a),
            .recursive = false,
        } }) };
    }

    /// `root.a.b.${x}.c` — replicate dot-access folding: runs of static names
    /// become an `attr_path`; each dynamic segment wraps in an `attr_dynamic`.
    fn buildSelect(self: *Parser, root: *Node, segs: SegAccum) !*Node {
        const a = self.arenaAllocator();
        var current = root;
        var pending: std.ArrayListUnmanaged(Node.Atom) = .empty;
        for (segs.items()) |seg| {
            switch (seg) {
                .static => |atomv| try pending.append(a, atomv),
                .dynamic => |name| {
                    if (pending.items.len > 0) {
                        current = try self.arena.createNode(.attr_path, .{ .attr_path = .{
                            .root = current,
                            .segments = try pending.toOwnedSlice(a),
                        } });
                        pending = .empty;
                    }
                    current = try self.arena.createNode(.attr_dynamic, .{ .attr_dynamic = .{
                        .root = current,
                        .name = name,
                    } });
                },
            }
        }
        if (pending.items.len > 0) {
            current = try self.arena.createNode(.attr_path, .{ .attr_path = .{
                .root = current,
                .segments = try pending.toOwnedSlice(a),
            } });
        }
        return current;
    }

    fn makeHasAttr(self: *Parser, root: *Node, segs: SegAccum) !Value {
        const a = self.arenaAllocator();
        const seg_items = segs.items();
        var has_dynamic = false;
        for (seg_items) |seg| {
            if (seg == .dynamic) has_dynamic = true;
        }
        if (has_dynamic) {
            const mixed = try a.alloc(Node.HasAttrMixedSegment, seg_items.len);
            for (seg_items, mixed) |seg, *m| {
                m.* = switch (seg) {
                    .static => |atomv| .{ .static = atomv },
                    .dynamic => |name| .{ .dynamic = name },
                };
            }
            return .{ .node = try self.arena.createNode(.has_attr_mixed, .{ .has_attr_mixed = .{
                .root = root,
                .segments = mixed,
            } }) };
        }
        const statics = try a.alloc(Node.Atom, seg_items.len);
        for (seg_items, statics) |seg, *s| s.* = seg.static;
        return .{ .node = try self.arena.createNode(.has_attr, .{ .has_attr = .{
            .root = root,
            .segments = statics,
        } }) };
    }

    /// Lower a bind `attrpath = expr` into a single `AttrSetEntry`, nesting any
    /// dynamic segments after a static prefix into wrapper attribute sets — the
    /// same shape the recursive-descent parser produced.
    fn foldBind(self: *Parser, segs: []const Seg, expr: *Node) anyerror!Node.AttrSetEntry {
        const a = self.arenaAllocator();
        if (segs[0] == .dynamic) {
            const inner = if (segs.len == 1) expr else try self.nestChain(segs[1..], expr);
            return .{ .path = &.{}, .dynamic_name = segs[0].dynamic, .expr = inner };
        }
        // leading static run
        var k: usize = 0;
        while (k < segs.len and segs[k] == .static) : (k += 1) {}
        const prefix = try a.alloc(Node.Atom, k);
        for (segs[0..k], prefix) |seg, *dst| dst.* = seg.static;
        if (k == segs.len) {
            return .{ .path = prefix, .dynamic_name = null, .expr = expr };
        }
        return .{ .path = prefix, .dynamic_name = null, .expr = try self.nestChain(segs[k..], expr) };
    }

    fn nestChain(self: *Parser, segs: []const Seg, expr: *Node) anyerror!*Node {
        const a = self.arenaAllocator();
        const entry = try self.foldBind(segs, expr);
        const entries = try a.alloc(Node.AttrSetEntry, 1);
        entries[0] = entry;
        return self.arena.createNode(.attr_set, .{ .attr_set = .{
            .entries = entries,
            .recursive = false,
        } });
    }

    /// Build the attribute-set entries for one `inherit ...;` clause (shared by
    /// `let`/`rec` bindings and by attribute-set braces).
    fn inheritEntries(self: *Parser, source: ?*Node, names_in: std.ArrayListUnmanaged(Node.Atom), inherit_tok: Token) ![]Node.AttrSetEntry {
        var names = names_in;
        defer names.deinit(self.arenaAllocator());
        // `inherit ;` / `inherit (src) ;` — an empty inherit is a valid no-op in
        // Nix (it names nothing), so it contributes no entries rather than being
        // a parse error.
        _ = inherit_tok;
        const a = self.arenaAllocator();
        const entries = try a.alloc(Node.AttrSetEntry, names.items.len);
        const inherit_group = if (source != null) blk: {
            const id = self.next_inherit_group;
            self.next_inherit_group +%= 1;
            if (self.next_inherit_group == 0) self.next_inherit_group = 1;
            break :blk id;
        } else 0;
        for (names.items, entries) |name, *entry| {
            const path = try a.alloc(Node.Atom, 1);
            path[0] = name;
            const expr: *Node = if (source) |src|
                try self.inheritSourceAttr(src, name)
            else
                try self.arena.createNode(.identifier, .{ .atom = name });
            entry.* = .{
                .path = path,
                .expr = expr,
                .inherit_outer = source == null,
                .inherit_group = inherit_group,
            };
        }
        return entries;
    }

    /// If `node` is a constant (non-interpolating) string literal, its source
    /// atom (quotes included) — usable directly as a static attribute name, the
    /// same way a plain `"x" = ...;` binding stores it. Otherwise null (a
    /// genuine dynamic key). Drives Nix's `${"x"}` → static fold for let
    /// bindings, where a real dynamic attribute is rejected.
    fn constStringAttrAtom(self: *Parser, node: ?*Node) !?Node.Atom {
        const n = node orelse return null;
        if (n.tag != .string) return null;
        const str_atom = n.data.atom;
        const parsed = string_syntax.parseLiteral(self.allocator, self.source, .{
            .start = str_atom.offset,
            .end = str_atom.offset + str_atom.len,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer parsed.deinit();
        for (parsed.parts) |part| {
            if (part == .interpolation) return null;
        }
        return str_atom;
    }

    fn inheritSourceAttr(self: *Parser, source: *Node, name: Node.Atom) !*Node {
        const segments = try self.arenaAllocator().alloc(Node.Atom, 1);
        segments[0] = name;
        return self.arena.createNode(.attr_path, .{ .attr_path = .{
            .root = try ast.cloneNode(self.arena, source),
            .segments = segments,
        } });
    }
};

test {
    _ = @import("parser/tests.zig");
    _ = grammar;
    _ = lr;
}
