//! The Nix grammar, in the form consumed by the comptime LALR(1) generator
//! (`lr.zig`). This file is pure data: nonterminals, productions, a semantic
//! `action` tag per production, and the operator precedence table. The runtime
//! driver (`parser.zig`) switches on the action tag to build the AST.
//!
//! Structure follows canonical Nix (Bison `parser.y`): an ambiguous
//! `expr_op OP expr_op` operator layer resolved by precedence, plus a
//! *stratified* application/selection layer.
//!
//! The one genuinely hard case — telling a lambda pattern `{ x }:` from an
//! attribute set `{ x = 1; }` — needs lookahead *past* the closing brace, which
//! LALR(1) cannot do at the brace's contents. Rather than a lexer pre-pass, we
//! keep the parser pure: `{ ... }` reduces to a single permissive `brace`
//! nonterminal whose contents (`brace_content`) is the *union* of formals and
//! bindings. The parser only commits to lambda-vs-attrset one token later —
//! when it sees (or does not see) the `:`/`@` after `}` — and a small semantic
//! check validates the contents against the chosen interpretation.

const std = @import("std");
const lr = @import("lr.zig");
const tok = @import("token.zig");
const TokenType = tok.TokenType;

// ---- terminal symbol ids ---------------------------------------------------
// Real tokens keep their `TokenType` value as their id. One synthetic terminal
// follows: `neg`, a precedence-only marker for unary minus (never present in
// the token stream).

pub const num_tokens = @typeInfo(TokenType).@"enum".fields.len;
pub const t_neg: u32 = num_tokens;
pub const num_terminals: u32 = num_tokens + 1;
pub const t_eof: u32 = @intFromEnum(TokenType.eof);

inline fn t(tt: TokenType) u32 {
    return @intFromEnum(tt);
}

// ---- nonterminals ----------------------------------------------------------

pub const Nonterminal = enum(u32) {
    expr,
    expr_if,
    expr_op,
    expr_app,
    expr_select,
    expr_simple,
    attrpath,
    attr,
    brace, // `{ brace_content }` — attrset or lambda formals, decided later
    brace_content,
    term_clauses, // comma-/semicolon-terminated clauses (may be followed by more)
    term_clause,
    final_clause, // the one trailing clause with no terminator (only before `}`)
    binds, // bindings for `let` / `rec { }` (formals not allowed there)
    bind,
    inherit_names,
    list_items,
};

inline fn n(x: Nonterminal) u32 {
    return num_terminals + @intFromEnum(x);
}

// ---- semantic action tags --------------------------------------------------

pub const Act = enum {
    augmented, // internal S' -> expr (index 0); never dispatched
    pass, // result = rhs[0]

    // Expr (function level)
    lambda_id, // ID : Expr
    lambda_no_bind, // brace : Expr
    lambda_bind_before, // ID @ brace : Expr
    lambda_bind_after, // brace @ ID : Expr
    assert_, // assert Expr ; Expr
    with_, // with Expr ; Expr
    let_in, // let Binds in Expr
    let_attrs, // let { Binds } — ancient let, == (rec { Binds }).body

    // ExprIf
    if_else,

    // ExprOp binary
    bin_impl,
    bin_or,
    bin_and,
    bin_eq,
    bin_neq,
    bin_lt,
    bin_lte,
    bin_gt,
    bin_gte,
    bin_update,
    bin_add,
    bin_sub,
    bin_mul,
    bin_div,
    bin_concat,
    has_attr, // ExprOp ? AttrPath
    pipe_fwd, // ExprOp |> ExprOp
    pipe_bwd, // ExprOp <| ExprOp
    not, // ! ExprOp
    negate, // - ExprOp

    // ExprApp
    apply, // ExprApp ExprSelect

    // ExprSelect
    select, // ExprSimple . AttrPath
    select_or, // ExprSimple . AttrPath or ExprSelect
    apply_or, // ExprSimple or — `or` used as an identifier argument (Nix compat)

    // ExprSimple atoms
    ident,
    integer,
    float_val,
    string,
    path,
    uri,
    search_path,
    parens,
    attrset_from_brace, // brace used as an expression → attribute set
    rec_attr_set, // rec { Binds }
    list, // [ ListItems ]

    // AttrPath / Attr
    attrpath_one,
    attrpath_append,
    attr_static, // ID/STRING/OR/TRUE/FALSE/NULL
    attr_dynamic, // ${ Expr }

    // brace / clauses (the unified formals-or-binds body). Clauses split into
    // "terminated" (end in `,` or `;`, so more may follow) and a single
    // unterminated "final" clause, which keeps a default's expr from being
    // followed by another clause's leading token.
    brace_group, // { brace_content } → clause list
    brace_empty, // (empty content)
    bc_final, // brace_content → final_clause
    bc_terms_final, // brace_content → term_clauses final_clause
    term_clauses_one,
    term_clauses_append,
    tclause_formal_comma, // name ,
    tclause_formal_default_comma, // name ? expr ,
    tclause_bind, // attrpath = expr ;
    tclause_inherit, // inherit names ;
    tclause_inherit_from, // inherit ( expr ) names ;
    fclause_formal, // name
    fclause_formal_default, // name ? expr
    fclause_ellipsis, // ...

    // Binds (let / rec)
    binds_empty,
    binds_append,
    bind_normal, // AttrPath = Expr
    bind_inherit, // inherit InheritNames
    bind_inherit_from, // inherit ( Expr ) InheritNames
    inherit_names_empty,
    inherit_names_append,

    // List
    list_items_empty,
    list_items_append,
};

const Production = struct {
    lhs: Nonterminal,
    rhs: []const u32,
    act: Act,
    prec: ?u32 = null,
};

// ---- productions -----------------------------------------------------------
// Order matters: the production index (offset by +1 for the augmented rule the
// generator prepends) selects the action in the driver.

const productions = [_]Production{
    // Expr
    .{ .lhs = .expr, .rhs = &.{ t(.identifier), t(.colon), n(.expr) }, .act = .lambda_id },
    .{ .lhs = .expr, .rhs = &.{ n(.brace), t(.colon), n(.expr) }, .act = .lambda_no_bind },
    .{ .lhs = .expr, .rhs = &.{ t(.identifier), t(.at), n(.brace), t(.colon), n(.expr) }, .act = .lambda_bind_before },
    .{ .lhs = .expr, .rhs = &.{ n(.brace), t(.at), t(.identifier), t(.colon), n(.expr) }, .act = .lambda_bind_after },
    .{ .lhs = .expr, .rhs = &.{ t(.kw_assert), n(.expr), t(.semicolon), n(.expr) }, .act = .assert_ },
    .{ .lhs = .expr, .rhs = &.{ t(.kw_with), n(.expr), t(.semicolon), n(.expr) }, .act = .with_ },
    .{ .lhs = .expr, .rhs = &.{ t(.kw_let), n(.binds), t(.kw_in), n(.expr) }, .act = .let_in },
    .{ .lhs = .expr, .rhs = &.{n(.expr_if)}, .act = .pass },

    // ExprIf
    .{ .lhs = .expr_if, .rhs = &.{ t(.kw_if), n(.expr), t(.kw_then), n(.expr), t(.kw_else), n(.expr) }, .act = .if_else },
    .{ .lhs = .expr_if, .rhs = &.{n(.expr_op)}, .act = .pass },

    // ExprOp — ambiguous, resolved by precedence
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.arrow), n(.expr_op) }, .act = .bin_impl },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.pipe_pipe), n(.expr_op) }, .act = .bin_or },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.amp_amp), n(.expr_op) }, .act = .bin_and },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.equal_equal), n(.expr_op) }, .act = .bin_eq },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.bang_equal), n(.expr_op) }, .act = .bin_neq },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.less), n(.expr_op) }, .act = .bin_lt },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.less_equal), n(.expr_op) }, .act = .bin_lte },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.greater), n(.expr_op) }, .act = .bin_gt },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.greater_equal), n(.expr_op) }, .act = .bin_gte },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.double_slash), n(.expr_op) }, .act = .bin_update },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.plus), n(.expr_op) }, .act = .bin_add },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.minus), n(.expr_op) }, .act = .bin_sub },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.star), n(.expr_op) }, .act = .bin_mul },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.slash), n(.expr_op) }, .act = .bin_div },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.double_plus), n(.expr_op) }, .act = .bin_concat },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.question_mark), n(.attrpath) }, .act = .has_attr },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.pipe_forward), n(.expr_op) }, .act = .pipe_fwd },
    .{ .lhs = .expr_op, .rhs = &.{ n(.expr_op), t(.pipe_backward), n(.expr_op) }, .act = .pipe_bwd },
    .{ .lhs = .expr_op, .rhs = &.{ t(.bang), n(.expr_op) }, .act = .not },
    .{ .lhs = .expr_op, .rhs = &.{ t(.minus), n(.expr_op) }, .act = .negate, .prec = t_neg },
    .{ .lhs = .expr_op, .rhs = &.{n(.expr_app)}, .act = .pass },

    // ExprApp
    .{ .lhs = .expr_app, .rhs = &.{ n(.expr_app), n(.expr_select) }, .act = .apply },
    .{ .lhs = .expr_app, .rhs = &.{n(.expr_select)}, .act = .pass },

    // ExprSelect
    .{ .lhs = .expr_select, .rhs = &.{n(.expr_simple)}, .act = .pass },
    .{ .lhs = .expr_select, .rhs = &.{ n(.expr_simple), t(.dot), n(.attrpath) }, .act = .select },
    .{ .lhs = .expr_select, .rhs = &.{ n(.expr_simple), t(.dot), n(.attrpath), t(.kw_or), n(.expr_select) }, .act = .select_or },
    // Backwards compatibility: `or` is a keyword, but Nix allows it as a bare
    // identifier argument, so `f or` parses as `f (or)` — the variable `or`.
    .{ .lhs = .expr_select, .rhs = &.{ n(.expr_simple), t(.kw_or) }, .act = .apply_or },

    // ExprSimple
    .{ .lhs = .expr_simple, .rhs = &.{t(.identifier)}, .act = .ident },
    .{ .lhs = .expr_simple, .rhs = &.{t(.integer)}, .act = .integer },
    .{ .lhs = .expr_simple, .rhs = &.{t(.float_val)}, .act = .float_val },
    .{ .lhs = .expr_simple, .rhs = &.{t(.string)}, .act = .string },
    .{ .lhs = .expr_simple, .rhs = &.{t(.path)}, .act = .path },
    .{ .lhs = .expr_simple, .rhs = &.{t(.uri)}, .act = .uri },
    .{ .lhs = .expr_simple, .rhs = &.{t(.search_path)}, .act = .search_path },
    .{ .lhs = .expr_simple, .rhs = &.{ t(.left_paren), n(.expr), t(.right_paren) }, .act = .parens },
    .{ .lhs = .expr_simple, .rhs = &.{n(.brace)}, .act = .attrset_from_brace },
    .{ .lhs = .expr_simple, .rhs = &.{ t(.kw_rec), t(.left_brace), n(.binds), t(.right_brace) }, .act = .rec_attr_set },
    // Ancient `let { … }`: sugar for `(rec { … }).body`.
    .{ .lhs = .expr_simple, .rhs = &.{ t(.kw_let), t(.left_brace), n(.binds), t(.right_brace) }, .act = .let_attrs },
    .{ .lhs = .expr_simple, .rhs = &.{ t(.left_bracket), n(.list_items), t(.right_bracket) }, .act = .list },

    // AttrPath
    .{ .lhs = .attrpath, .rhs = &.{n(.attr)}, .act = .attrpath_one },
    .{ .lhs = .attrpath, .rhs = &.{ n(.attrpath), t(.dot), n(.attr) }, .act = .attrpath_append },

    // Attr (segment)
    .{ .lhs = .attr, .rhs = &.{t(.identifier)}, .act = .attr_static },
    .{ .lhs = .attr, .rhs = &.{t(.string)}, .act = .attr_static },
    .{ .lhs = .attr, .rhs = &.{t(.kw_or)}, .act = .attr_static },
    .{ .lhs = .attr, .rhs = &.{ t(.dollar_curly), n(.expr), t(.right_brace) }, .act = .attr_dynamic },

    // brace: the unified `{ ... }` body
    .{ .lhs = .brace, .rhs = &.{ t(.left_brace), n(.brace_content), t(.right_brace) }, .act = .brace_group },
    .{ .lhs = .brace_content, .rhs = &.{}, .act = .brace_empty },
    .{ .lhs = .brace_content, .rhs = &.{n(.term_clauses)}, .act = .pass },
    .{ .lhs = .brace_content, .rhs = &.{n(.final_clause)}, .act = .bc_final },
    .{ .lhs = .brace_content, .rhs = &.{ n(.term_clauses), n(.final_clause) }, .act = .bc_terms_final },
    .{ .lhs = .term_clauses, .rhs = &.{n(.term_clause)}, .act = .term_clauses_one },
    .{ .lhs = .term_clauses, .rhs = &.{ n(.term_clauses), n(.term_clause) }, .act = .term_clauses_append },
    // terminated clauses (formals end in `,`; binds end in `;`)
    .{ .lhs = .term_clause, .rhs = &.{ t(.identifier), t(.comma) }, .act = .tclause_formal_comma },
    .{ .lhs = .term_clause, .rhs = &.{ t(.kw_or), t(.comma) }, .act = .tclause_formal_comma },
    .{ .lhs = .term_clause, .rhs = &.{ t(.identifier), t(.question_mark), n(.expr), t(.comma) }, .act = .tclause_formal_default_comma },
    .{ .lhs = .term_clause, .rhs = &.{ t(.kw_or), t(.question_mark), n(.expr), t(.comma) }, .act = .tclause_formal_default_comma },
    .{ .lhs = .term_clause, .rhs = &.{ n(.attrpath), t(.equal), n(.expr), t(.semicolon) }, .act = .tclause_bind },
    .{ .lhs = .term_clause, .rhs = &.{ t(.kw_inherit), n(.inherit_names), t(.semicolon) }, .act = .tclause_inherit },
    .{ .lhs = .term_clause, .rhs = &.{ t(.kw_inherit), t(.left_paren), n(.expr), t(.right_paren), n(.inherit_names), t(.semicolon) }, .act = .tclause_inherit_from },
    // the single unterminated trailing clause (only valid right before `}`)
    .{ .lhs = .final_clause, .rhs = &.{t(.identifier)}, .act = .fclause_formal },
    .{ .lhs = .final_clause, .rhs = &.{t(.kw_or)}, .act = .fclause_formal },
    .{ .lhs = .final_clause, .rhs = &.{ t(.identifier), t(.question_mark), n(.expr) }, .act = .fclause_formal_default },
    .{ .lhs = .final_clause, .rhs = &.{ t(.kw_or), t(.question_mark), n(.expr) }, .act = .fclause_formal_default },
    .{ .lhs = .final_clause, .rhs = &.{t(.ellipsis)}, .act = .fclause_ellipsis },

    // Binds (let / rec) — bindings only, no formals
    .{ .lhs = .binds, .rhs = &.{}, .act = .binds_empty },
    .{ .lhs = .binds, .rhs = &.{ n(.binds), n(.bind), t(.semicolon) }, .act = .binds_append },
    .{ .lhs = .bind, .rhs = &.{ n(.attrpath), t(.equal), n(.expr) }, .act = .bind_normal },
    .{ .lhs = .bind, .rhs = &.{ t(.kw_inherit), n(.inherit_names) }, .act = .bind_inherit },
    .{ .lhs = .bind, .rhs = &.{ t(.kw_inherit), t(.left_paren), n(.expr), t(.right_paren), n(.inherit_names) }, .act = .bind_inherit_from },
    .{ .lhs = .inherit_names, .rhs = &.{}, .act = .inherit_names_empty },
    .{ .lhs = .inherit_names, .rhs = &.{ n(.inherit_names), t(.identifier) }, .act = .inherit_names_append },
    .{ .lhs = .inherit_names, .rhs = &.{ n(.inherit_names), t(.kw_or) }, .act = .inherit_names_append },
    .{ .lhs = .inherit_names, .rhs = &.{ n(.inherit_names), t(.string) }, .act = .inherit_names_append },

    // List
    .{ .lhs = .list_items, .rhs = &.{}, .act = .list_items_empty },
    .{ .lhs = .list_items, .rhs = &.{ n(.list_items), n(.expr_select) }, .act = .list_items_append },
};

// ---- operator precedence (Nix; higher level binds tighter) -----------------

const prec = [_]lr.RawPrec{
    .{ .term = t(.pipe_forward), .level = 1, .assoc = .left },
    .{ .term = t(.pipe_backward), .level = 1, .assoc = .right },
    .{ .term = t(.arrow), .level = 2, .assoc = .right },
    .{ .term = t(.pipe_pipe), .level = 3, .assoc = .left },
    .{ .term = t(.amp_amp), .level = 4, .assoc = .left },
    .{ .term = t(.equal_equal), .level = 5, .assoc = .nonassoc },
    .{ .term = t(.bang_equal), .level = 5, .assoc = .nonassoc },
    .{ .term = t(.less), .level = 6, .assoc = .nonassoc },
    .{ .term = t(.less_equal), .level = 6, .assoc = .nonassoc },
    .{ .term = t(.greater), .level = 6, .assoc = .nonassoc },
    .{ .term = t(.greater_equal), .level = 6, .assoc = .nonassoc },
    // Canonical Nix associativity: `//` and `++` are right-associative.
    .{ .term = t(.double_slash), .level = 7, .assoc = .right },
    .{ .term = t(.bang), .level = 8, .assoc = .left },
    .{ .term = t(.plus), .level = 9, .assoc = .left },
    .{ .term = t(.minus), .level = 9, .assoc = .left },
    .{ .term = t(.star), .level = 10, .assoc = .left },
    .{ .term = t(.slash), .level = 10, .assoc = .left },
    .{ .term = t(.double_plus), .level = 11, .assoc = .right },
    .{ .term = t(.question_mark), .level = 12, .assoc = .nonassoc },
    .{ .term = t_neg, .level = 13, .assoc = .right },
};

// ---- assembled grammar description + generated tables ----------------------

// ---- comptime unit-production elimination ----------------------------------
// A unit `pass` rule `A -> B` (single nonterminal RHS, identity action) forces
// a do-nothing reduction at runtime. Eliminate them: for every non-unit rule
// `B -> γ`, add `A -> γ` (keeping B's action) for each A that reaches B through
// unit rules, then drop the unit rules. The generated automaton then performs
// zero chain reductions. This grows the table substantially, but the cost is
// paid once by the cached codegen step (see gen_parser_tables.zig), not on
// every build — so it is free at the point of use.

const num_nt = @typeInfo(Nonterminal).@"enum".fields.len;

/// Eliminate runtime chain reductions by expanding unit productions at
/// comptime. This increases generated table size and generation work.
const eliminate_units = true;

fn isUnitPass(p: Production) bool {
    return p.act == .pass and p.rhs.len == 1 and p.rhs[0] >= num_terminals;
}

const expanded: []const Production = if (!eliminate_units) &productions else blk: {
    @setEvalBranchQuota(10_000_000);
    // reach[a][b]: nonterminal a derives b through a chain of unit rules.
    var reach = [_][num_nt]bool{[_]bool{false} ** num_nt} ** num_nt;
    for (0..num_nt) |a| reach[a][a] = true;
    for (productions) |p| {
        if (isUnitPass(p)) reach[@intFromEnum(p.lhs)][p.rhs[0] - num_terminals] = true;
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (0..num_nt) |a| for (0..num_nt) |b| {
            if (!reach[a][b]) continue;
            for (0..num_nt) |c| if (reach[b][c] and !reach[a][c]) {
                reach[a][c] = true;
                changed = true;
            };
        };
    }
    var out: []const Production = &.{};
    for (productions) |q| {
        if (isUnitPass(q)) continue; // drop the unit rules themselves
        const b = @intFromEnum(q.lhs);
        for (0..num_nt) |a| {
            if (reach[a][b]) out = out ++ &[_]Production{.{ .lhs = @enumFromInt(a), .rhs = q.rhs, .act = q.act, .prec = q.prec }};
        }
    }
    break :blk out;
};

const raw_productions = blk: {
    var r: [expanded.len]lr.RawProd = undefined;
    for (expanded, 0..) |p, i| r[i] = .{ .lhs = @intFromEnum(p.lhs), .rhs = p.rhs, .prec = p.prec };
    break :blk r;
};

/// The grammar description consumed by `lr.Generate`. Building the LALR tables
/// from this is expensive at comptime, so it is done *once* by the codegen tool
/// (`tools/gen_parser_tables.zig`, wired in `build.zig`) rather than every time
/// the `syntax` module compiles — the parser imports the generated `.zig`.
pub const desc = lr.GrammarDesc{
    .num_terminals = num_terminals,
    .num_nonterminals = @typeInfo(Nonterminal).@"enum".fields.len,
    .eof = t_eof,
    .start = @intFromEnum(Nonterminal.expr),
    .productions = &raw_productions,
    .precedence = &prec,
};

/// Action tag per production index (index 0 is the augmented rule the generator
/// prepends). Cheap to compute — kept here so it stays beside the grammar.
pub const act_of_prod = blk: {
    var a: [expanded.len + 1]Act = undefined;
    a[0] = .augmented;
    for (expanded, 0..) |p, i| a[i + 1] = p.act;
    break :blk a;
};

test "grammar action table aligns with productions" {
    try std.testing.expect(act_of_prod.len == expanded.len + 1);
    try std.testing.expect(act_of_prod[0] == .augmented);
}
