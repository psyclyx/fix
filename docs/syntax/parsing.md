# Parsing

*Scanner → LALR(1) driver → arena AST: how source text becomes the tree the compiler walks.*

The `syntax` module (`@import("syntax")`) is the self-contained front end. It takes immutable source bytes and produces a pointer-linked, arena-allocated AST plus a list of `Diagnostic`s. Everything below the module facade — `Scanner`, the LALR generator/tables, `AstArena`, `string_syntax` — is internal. The compiler ([`compiler/pipeline`](../compiler/pipeline.md)) consumes the AST; it never sees tokens.

Two hard rules shape the whole design:
- **Source outlives everything.** Tokens and AST nodes store byte offsets into the original source buffer, never owned slices. The caller must keep `source` alive for the entire lifetime of the tree.
- **No throwing control flow for recoverable errors.** Parse errors accumulate as diagnostics and the parser resynchronizes in panic mode; it does not unwind or backtrack the token stream.

## Scanner

Single-pass, streaming, allocation-free. `next()` returns exactly one `Token` per call — there is no token array. A `Token` is `{ type: TokenType, offset, len }`: a byte offset and length into `source`. It carries neither a string slice nor a line number — consumers that need the lexeme reslice `source[offset..offset+len]`, and diagnostics recompute the line from the offset (`Parser.tokenLine`), which keeps the hot scan loop from counting newlines at all.

Before each token the scanner skips layout — whitespace, `#` line comments, and `/* */` block comments — so comments never reach the parser. Its byte-run scans are vectorized where they pay off: whitespace runs and identifier runs use SIMD block comparison when the target has vectors (`std.simd.suggestVectorLength`, scalar fallback otherwise), and the comment skips jump straight to the terminator with `indexOfScalarPos`/`indexOfPos`. Character classification on the scalar path is a branchless `class_table` lookup rather than a chain of range comparisons. Keyword recognition dispatches on identifier length (a jump table over lengths 2–7) and compares the candidates of that length, so ordinary identifiers fall straight through.

`true`, `false` and `null` are deliberately *not* keywords. Nix binds them in the base environment like any other global, so a binder shadows them (`let true = 1; in true` is `1`) and they are legal in every binding position (`(true: true) 5`, `{ null ? 3 }: null`). They lex as identifiers, and `Parser.parse` retags the unshadowed ones back to `bool_true`/`bool_false`/`null` AST nodes at the end of the parse — so the compiler's constant paths (literal container values, trivial formal defaults, folding) keep seeing literals, exactly as when they were keywords. A single binder anywhere in the file (`Parser.noteBinder`, deliberately over-approximate — an attribute *name* counts too) disables the retag for the whole file, leaving every use a variable that resolves through the scope chain — the compiler then re-decides per use, from the live scope, so an unshadowed one in such a file still binds as a constant rather than a thunk (`compiler/access.zig compileRawIdent`). The retag is sound only for a whole-file parse: a span sub-parsed later from its own source alone — an elided body, a `${…}` interpolation — cannot see an enclosing binder, so `compiler/literals.zig` sets `keyword_literal_bound` on those parsers and leaves every use a variable.

It recognizes the fixed punctuation set directly (e.g. `pipe_pipe` for `||`, `double_slash` for `//`, `arrow` for `->`, `dollar_curly` for `${`, `pipe_forward`/`pipe_backward` for `|>`/`<|`). Invalid bytes become an `error_token`; the driver reports and skips them. `<` is special: `<name...>` speculatively scans as a `search_path`, but with no closing `>` the scanner rewinds to just past the `<` and emits the bare `less` operator, matching Nix's maximal-munch backtracking (`a<b` is `a < b`).

Strings and interpolated paths are where the scanner stops being trivial: their extent cannot be found by a character class because `"..."`, `''...''`, and `./${...}/x` embed arbitrary nested `${ expr }` interpolations. The scanner delegates extent-finding to [`string_syntax`](nix-syntax.md) — `scanLiteral` for strings, `findInterpolationEnd` for the interpolation holes — which tracks `{`/`}` brace depth through nested interpolations (and skips nested strings and comments inside them), scans literal bodies with a SIMD find-first-of (`skipToAnyOf`) that jumps to the next structurally interesting byte, and returns where the literal ends; the scanner emits one `string`/`path` token spanning the whole thing. (A `search_path` `<...>` has no interpolation and is scanned in the scanner itself.) Decoding the literal's parts happens later, on demand, not during scanning.

## Parser

Table-driven **LALR(1)**. The grammar lives as pure data in `grammar.zig`; a generic generator (`lr.zig`) turns it into flat ACTION/GOTO tables; a build-time codegen tool (`gen_parser_tables.zig`) runs the generator and emits the tables as static array literals. `parser.zig` is the runtime — a tight shift/reduce loop over those tables plus the semantic actions that build the AST.

### Grammar and the generated tables

`grammar.zig` declares the nonterminals, the productions (each tagged with a semantic `Act`), and an operator-precedence table. `lr.zig` builds the canonical LR(0) automaton and adds LALR(1) lookaheads by the DeRemer/Pennello spontaneous-generation-plus-propagation method, packing each action cell into a `u16` (2 bits of kind — shift/reduce/accept/error — and 14 bits of argument) so the whole ACTION table stays small enough to keep the per-token dependent load hot in cache. Shift/reduce conflicts are resolved from the precedence table; any residual conflict is a hard build error, since a correct stratified grammar is conflict-free.

Building the tables is expensive, so it is done **once** at build time, not at every module compile and not at eval time. `gen_parser_tables.zig` runs `lr.generate` as ordinary native code and writes `parser_tables.zig`; `build.zig` caches that artifact and reruns it only when the grammar or generator changes. The parser imports the result as the anonymous `parser_tables` module. The shipped `fix` binary therefore contains only baked-in static arrays and does no table construction.

`grammar.zig` applies one comptime transform to the rule set before generation (`eliminate_units`, a reachability fixpoint): unit `pass` productions (`A -> B`, identity action) are eliminated by inlining each non-unit rule into every nonterminal that reaches it through unit rules, so the driver never performs a do-nothing chain reduction — every reduce runs a real action. This grows the table but costs nothing at eval time, since generation is cached. Production *order* is part of the contract: the driver indexes `act_of_prod` by production number (offset by +1 for the augmented rule the generator prepends) to pick each reduce's action.

### The shift/reduce driver

`drive()` maintains two parallel stacks: a state stack (`u32`) and a semantic-value stack. Tokens stream straight from the scanner — no token array. The value stack holds a `Value`, an **untagged** union (`tok`, `node`, `seg`, `entries`, `clauses`, `brace`, …); which variant is live is fully determined by the grammar symbol just reduced, so there is no tag byte on the hot per-symbol stack and no discriminant checks.

Each loop step reads `action[state * num_terminals + lookahead]`:
- **shift** pushes the token and the target state, and pulls the next token;
- **reduce** pops the production's RHS length off both stacks, runs `runAction` for that production to fold the children into one `Value` (allocating AST nodes in the caller's arena), then follows `goto_table` to the new state;
- **accept** returns the root node;
- **error** triggers recovery.

The stacks start at 4096 entries — left recursion keeps lists flat, so depth tracks *nesting* only, which 4096 covers for any sane input — and double on demand for pathological inputs.

### Stratified grammar and precedence

The expression grammar is stratified into layers — `expr`, `expr_if`, `expr_op`, `expr_app`, `expr_select`, `expr_simple` — following canonical Nix (Bison `parser.y`). The `expr_op` layer is written ambiguously (`expr_op OP expr_op`) and disambiguated entirely by the precedence table; the surrounding layers fix the relative binding of function forms, application, and selection structurally.

The precedence table (higher level binds tighter) with associativities:

```
1   |> (left)   <| (right)      pipe operators
2   ->  (right)                 impl
3   ||  (left)
4   &&  (left)
5   ==  != (nonassoc)
6   <  <=  >  >=  (nonassoc)
7   //  (right)                 update
8   !   (left)                  logical not
9   +  -  (left)
10  *  /  (left)
11  ++  (right)                 concat
12  ?   (nonassoc)              has-attr
```

Unary minus takes a synthetic precedence terminal (`neg`, level 13) — a marker never present in the token stream, attached to the negation production via a `%prec`-style override — so prefix `-` binds tighter than any binary operator. `nonassoc` terminals install an error cell for the repeated form, so `a == b == c` and `a ? x ? y` are syntax errors. Application (juxtaposition) and attribute selection are not operators in this table; they live in the `expr_app`/`expr_select` layers, which always bind tighter than every `expr_op` operator.

### Lambda-vs-attrset: the unified `brace`

The grammar's one genuinely hard case is telling a lambda parameter pattern `{ a, b ? d, ... }@args:` from an attribute set `{ a = 1; }`. Only a `:` or `@` *after* the matching `}` — arbitrarily far ahead — confirms the pattern, which one token of LALR lookahead at the brace's contents cannot see.

Rather than a lexer pre-pass or a speculative re-parse, the grammar stays pure: `{ ... }` reduces to a single permissive `brace` nonterminal whose contents (`brace_content`) is the *union* of formals and bindings. Each element parses into a `Clause` (`formal`, `ellipsis`, `bind`, or `inherit`). The parser commits to lambda-vs-attrset one token later — when it does or does not see the `:`/`@` after `}` — and a small semantic check then validates the clause list against the chosen role (`buildLambda` rejects binds/inherits; `buildAttrSet` rejects formals/ellipsis). Clauses are split grammatically into *terminated* ones (formals end in `,`, binds/inherits end in `;`, so more may follow) and a single unterminated *final* clause valid only right before `}`, which keeps a default's expression from swallowing the next clause's leading token.

### Body-span elision (lazy parsing)

Optional, off by default; `Engine.parseAndCompile` enables it for whole-file compiles, mirroring the compiler's lazy per-attribute compilation. When enabled, a bind body inside a plain `{ ... }` that (a) follows at least `elide_min_prior_clauses` (64) earlier clauses in the same brace, (b) spans at least `elide_min_body_bytes` (100), and (c) is deferral-shaped is **not** parsed. Its tokens are skipped by a balanced token-level span scan (`scanElidableBody`, run on a copy of the scanner so a bail leaves the parse untouched), and a single `.elided` node holding the raw source span is spliced onto the parse stack as an already-reduced `expr`. The compiler sub-parses the span on demand.

The shape gate mirrors the compiler's deferral gate: immediate-shaped bodies (single-token atoms, lambdas, whole-body `{..}`/`[..]` literals, `rec`-rooted sets, whole-body parens) are never elided, so an elided body is always something the compiler would have deferred anyway. The tradeoff: parse errors inside an elided body surface at first *force* rather than at parse time — the same deal deferred compilation already makes, and an unforced body's errors are never reported. A predictable single branch per shift maintains the binding-context bookkeeping (`ctx_stack`) that decides whether a `=` starts an elidable body; with elision off, that branch is skipped entirely.

## AST

An `AstArena` wraps a Zig `ArenaAllocator`: nodes are bump-allocated and freed all-at-once when the arena is dropped. There is no per-node destructor and no reference counting; the tree is immutable once built.

A `Node` is `{ tag: NodeTag, data: Data, span: ?Atom }`. Consumers dispatch on `tag` and read the matching `data` variant. `span` is an optional byte `Atom { offset, len }` into `source`, derived at construction: `nodeSourceSpan` combines child spans (first child through last) so any node can report its own source extent for diagnostics without storing extra bookkeeping — the same offsets-not-strings discipline as tokens. The rare, large `LambdaAttrs` variant is boxed behind a pointer so it does not bloat every node's by-value write (`Node` stays ~40B rather than ~64B).

The tag families (28 tags):

- **Atoms** (`data = Atom`): `integer, float_val, string, path, uri, search_path, identifier, bool_true, bool_false, null`, plus `elided` (the lazy-parsing placeholder above, holding the unparsed body's span). The atom's bytes still live in `source`; string/path *decoding* is deferred to the compiler via [`string_syntax`](nix-syntax.md) `ParsedLiteral`s.
- **Operators**: `unary_op` (`Unary { op, expr }` — `!` or negation), `binary_op` (`Binary { op, left, right }`, 15 ops: add/sub/mul/div, eq/neq, lt/lte/gt/gte, and/or, impl, update, concat).
- **Functions & binding forms**: `apply` (`Apply { func, arg, pipe }`), `lambda` (`Lambda { param_offset, param_len, body }`), `lambda_attrs` (`*LambdaAttrs { bind_name?, params[], allow_extra, body }`), `let_in` (`LetIn { bindings[], body }`), `with_expr`, `if_else`, `assert`.
- **Attribute access & sets**: `attr_path` (`AttrPath { root, segments[] }`), `attr_dynamic`, `attr_or`, `has_attr` / `has_attr_mixed`, `attr_set` (`AttrSet { entries[], recursive }`), `list`, `parens`.

Two shared records recur: `Binding { name_offset, name_len, path[], expr, inherit_outer, inherit_group }` for each `let`/`rec` binding, and `AttrSetEntry { path[], dynamic_name?, expr, inherit_outer, inherit_group }` for each attribute-set entry; `LambdaAttrParam { name, default? }` describes each formal in a pattern. `inherit_group` is zero except for entries sharing one `inherit (expr)` clause. The Nix-surface meaning of these — `inherit` desugaring, dynamic attr paths, pattern semantics — is documented in [nix-syntax](nix-syntax.md); this doc covers only how the tree is shaped and walked.

## Diagnostics and recovery

Errors are values, not exceptions. On an error action the driver reports a `Diagnostic` (unless suppressed by the cooldown below), bumps an error count that caps the parse at `max_errors` (32), and enters **panic-mode recovery**: `recover` keeps the parse stack intact — preserving the enclosing context, e.g. the current `{ ... }` — and discards input tokens until the top state has a real action on one (typically the next clause separator or the context's closing token). The value stack is untouched, so it stays consistent with the state stack and semantic actions keep running safely; the recovered tree is discarded anyway, since any recorded error makes `parse` return `error.ParseError`. An **error cooldown** stays quiet for the three shifted tokens after each report, collapsing the cascade of spurious follow-on errors panic mode would otherwise emit. Recovery gives up (returns the partial state) at EOF.

A `Diagnostic` carries `{ severity, kind (parse|compile), line, column, offset, len, token_type?, message, source?, source_path? }` — the same struct serves compile-phase errors. Rendering (`writeAll`) prints line/column, a source snippet, and a caret under `offset..len` plus a `near \`…\`` excerpt, optionally ANSI-colored. Column and snippet resolution can use a **`LineIndex`**: it caches line-start offsets and maps a byte offset to `(line, column)` by binary search, with an O(1) sequential-access fast path for rendering diagnostics in source order, plus a cache-free `lineForOffset` safe to call concurrently while the compiler shares the index.

## Gotchas

- **Keep `source` alive.** Every span is an offset into it; the AST and tokens are dangling without it.
- **Arena is all-or-nothing.** No node is freed individually; drop the arena to reclaim the tree.
- **`inherit` and other sugar are not stored literally** — they are lowered by the semantic actions (see [nix-syntax](nix-syntax.md)). Don't expect an `inherit` node in the tree.
- **The value stack is untagged.** A `Value` variant is only valid for the symbol that produced it; reading the wrong variant is undefined. The grammar, not a runtime tag, guarantees correctness — changing a production's RHS means updating its action in lockstep.
- **The elision scanner must stay side-effect-free** — it runs on a scanner copy and, apart from noting pipe-operator provenance for the feature gate, touches nothing the real parse depends on; giving it observable effects would desynchronize the eager parse from the deferred sub-parse.

Code: `src/syntax/`
