# Nix Surface Syntax

*The Nix-specific grammar the parser handles: strings, paths, `inherit`, patterns, dynamic attrs, operators — what each surface form desugars to.*

This doc covers *what* the parser recognizes and *what tree it produces* for Nix's non-obvious surface constructs. For *how* the parser works — the LALR(1) driver, the precedence table, the unified `brace` nonterminal, the arena AST — see [parsing](parsing.md); it is not re-explained here. How these forms *compile and evaluate* is out of scope (see [`compiler/pipeline`](../compiler/pipeline.md)).

## Strings and interpolation

String literal extent-finding lives in `string_syntax`; the [scanner](parsing.md) emits one `string` token per literal and decoding into parts is deferred. A decoded literal is a `ParsedLiteral`: a sequence of `parts`, each either

- **`text`** — a run of literal characters, or
- **`interpolation: Span`** — the byte span of the inner `${ expr }` expression.

`text` parts carry an `owned` flag. When the source bytes are already the final text (no escapes to resolve) the part points directly into `source` with `owned = false`. When escapes had to be decoded, the resolved bytes are heap-allocated and `owned = true`. A `ParsedLiteral` is a rope of literal chunks and holes; the compiler compiles the holes as sub-expressions and concatenates.

**Double-quoted** `"..."` (`scanDoubleQuoted` / `parseDoubleQuoted`): escapes `\n \r \t \" \\`; any other `\x` passes the following byte through literally. `${` opens an interpolation; the extent scanner (`findInterpolationEnd`) tracks nested `{`/`}` depth (and skips over nested strings and comments inside the hole) so `${ f { x = 1; } }` is one hole. Interpolation triggers only on an **odd**-length run of `$` immediately before `{`: a `$` not followed by `{`, or an even-length `$$…` run before `{`, is plain text. A backslash escape `\$` is a literal `$` (the `\` consumes the following `$`, which the interpolation scan then never examines).

**Indented** `''...''` strings (`scanIndented` / `parseIndented`): same interpolation machinery, plus two extra transforms.
- **Dedentation**: the minimum leading indentation across all non-blank lines is computed (`minIndent`) and stripped from every line, so the literal's text is relative to its least-indented line — the standard Nix indented-string behavior. A leading newline right after the opening `''` is dropped.
- **`''`-prefixed escapes** (ordinary `\` is *not* an escape inside `''...''`): `'''` is a literal `''` (suppressing the string terminator), `''$` is a literal `$` (suppressing interpolation) while `''${` is a literal `${`, and `''\x` introduces a character escape (`''\n`, `''\t`, … decode like the double-quoted ones; any other `''\x` yields the raw byte).

## Paths

Three path forms, all emitted as single tokens:

- **Literal path** — `./foo`, `/abs/path`, `../x`, and hidden-dir relatives like `.devops/nix/scope.nix`. The scanner matches Nix flex `PATH` (`PATH_CHAR*(\/PATH_CHAR+)+` with `PATH_CHAR = [A-Za-z0-9._+-]`), extended with `isPathContinue` over the allowed path bytes — ASCII letters, digits, and `/ . - _ +`. Every path literal contains a `/`; a bare `.name` without a slash segment is not a path.
- **Interpolated path** — `./${v}/f`. Despite the embedded `${...}`, this is *one* `path` token: `findInterpolationEnd` skips over the interpolation while continuing the path scan, so the whole thing is a single literal with holes (like a string).
- **Search path** — `<nixpkgs>`, `<nixpkgs/lib>`. Emitted as a distinct `search_path` token/atom; resolution against the search path happens later. `<` with no closing `>` is not a search path — the scanner backtracks to the bare `less` operator (see [parsing](parsing.md)).

## `inherit` desugaring

`inherit` is **lowered by the parser's semantic actions** — there is no `inherit` node in the AST. Both forms lower to ordinary attribute-set entries (`inheritEntries`), valid identically in attribute-set braces and in `let`/`rec` binds:

- **Outer-scope** `{ inherit a b; }` → entries `a = a; b = b;` where each entry has `inherit_outer = true` and its expr is an `identifier` referencing the same-named variable in the enclosing scope.
- **From-expr** `{ inherit (src) a b; }` → entries `a = src.a; b = src.b;`, with `inherit_outer = false`, the expr an `attr_path`, and a shared non-zero `inherit_group` id. The compiler uses that id to create one hidden lazy source binding for the whole clause.

The outer-scope discriminator is exactly `inherit_outer = (source == null)`; from-expression clauses additionally carry `inherit_group`. In an attribute set these come from the `tclause_inherit` / `tclause_inherit_from` clauses; in `let`/`rec` from the `bind_inherit` / `bind_inherit_from` productions. An empty `inherit ;` (no names) is a diagnostic, and a missing `;` triggers panic-mode recovery (see [parsing](parsing.md)) rather than a cascade.

## Lambda parameter patterns

Beyond the simple `x: body` (`lambda` node, `Lambda { param_offset, param_len, body }`), Nix has attribute-set patterns, produced as `lambda_attrs` (`LambdaAttrs { bind_name?, params[], allow_extra, body }`):

- `{ a, b }:` — required formals; each formal is a `LambdaAttrParam { name, default? }`.
- `{ a, b ? d }:` — `b` has a default expression `d`.
- `{ a, ... }:` — trailing ellipsis sets `allow_extra = true` (accept and ignore surplus attrs).
- `args @ { a }:` and `{ a } @ args:` — an `@`-binding names the whole argument set; it may appear before or after the brace group. That name becomes `bind_name`.

Disambiguating a leading `{` between this pattern and an attribute-set expression is handled inside the grammar by the unified `brace` nonterminal, committed one token past the closing `}` (see [parsing](parsing.md)). The confirming `:` or `@` is what selects the lambda interpretation; `buildLambda` then rejects any bind/inherit clause that snuck into the group.

## Dynamic attribute names and access

**Dynamic names in construction** — `{ ${k} = v; }` — a binding whose key is a computed expression rather than a static identifier. Mixed static/dynamic paths like `a.${k}.c = v;` are supported. `foldBind` lowers each bind into a single `AttrSetEntry { path, dynamic_name?, expr }`: the leading run of static names becomes `path`, the first dynamic segment becomes `dynamic_name`, and any remaining segments nest into wrapper attribute sets (`nestChain`) — so no intermediate one-key attr sets are materialized for the static prefix. A binding whose path *begins* with a dynamic segment is rejected inside `let` (`let` keys must be static).

**Access and membership** distinguish static vs dynamic segments:

- `attr_path` (`AttrPath { root, segments[] }`) — `a.b.c`, fully static access. `buildSelect` folds a dot-access path into runs of static names (each run an `attr_path`) with dynamic segments interleaved.
- `attr_dynamic` (`AttrDynamic { root, name }`) — a select segment that is a `${expr}` (`a.${k}`).
- `attr_or` (`AttrOr { attr_path, default }`) — `x.y or default`: attribute access with a fallback expression parsed after the path via the `or` keyword. (`or` here is the fallback keyword, distinct from the `||` boolean-or operator; it also doubles as a valid attribute *name*.)
- `has_attr` (`?`) — membership test `x ? a.b`, all-static segments. `has_attr_mixed` covers a path with any dynamic segment; `makeHasAttr` picks between them by scanning for a dynamic segment.

## Operator set

**15 binary operators**, mapped from tokens to `binary_op` (`Binary { op, left, right }`) via the corresponding `expr_op` productions with the precedences in the [parsing](parsing.md) table:

```
add +   sub -   mul *   div /
eq ==   neq !=
lt <    lte <=  gt >    gte >=
and &&  or ||   impl ->
update //   concat ++
```

Associativity follows canonical Nix: `->` (`impl`), `//` (`update`), and `++` (`concat`) are **right-associative**; `+ - * / && ||` are left-associative; `== != < <= > >=` are **non-associative** (chaining them, e.g. `a == b == c`, is a syntax error). The `?` has-attr test is also a (non-associative) operator on the `expr_op` layer, binding tighter than arithmetic. Precedence and associativity are resolved once, at table-generation time, from the grammar's precedence table.

**Unary operators** (`unary_op`, `Unary { op, expr }`): logical `!` and arithmetic negation `-`. Negation binds tighter than every binary operator via a synthetic precedence marker (see [parsing](parsing.md)).

### Pipe operators (`|>` / `<|`)

`|>` and `<|` occupy the loosest precedence rung (looser than everything above — even `->`). They are **not** among the 15 above: a pipe is pure sugar for function application, so instead of a `binary_op` node it lowers to an ordinary `apply` tagged with its surface form (`Apply.pipe` = `.forward`/`.backward`), which reuses the whole application path in the compiler and evaluator and lets a printer spell the node back faithfully. Operands are stored in evaluation order (`func`, `arg`):

- `x |> f` == `f x` — **left**-associative → `apply(func=f, arg=x, .forward)`
- `f <| x` == `f x` — **right**-associative → `apply(func=f, arg=x, .backward)`

Both always parse; the parser records that a pipe was seen (`used_pipe_operators`, plus the earliest pipe token for a precise diagnostic) but does not itself reject them. Compiling a file that uses one requires the `pipe-operators` experimental feature (`--extra-experimental-features pipe-operators`, Nix-style); otherwise the compile chokepoint (`Engine.parseAndCompile`) rejects the file *on presence* — like Nix, an unused or deferred binding still fails — pointing the diagnostic at the operator. The flag is documented in [cli](../cli.md).

## List juxtaposition restriction

Inside `[ ... ]`, elements are `expr_select`, not `expr_app`: the list-items production folds one `expr_select` at a time, so function application is grammatically unavailable between adjacent elements. `[ f x ]` is therefore a two-element list, not `[ (f x) ]` — matching Nix. Consequently a bare `if`/`let`/lambda/`!`/`-` — anything above the selection layer that would greedily consume following tokens — is **not** a legal unparenthesized list element and must be wrapped in `( ... )`.

Code: `src/syntax/`
