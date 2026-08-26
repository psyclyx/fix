//! Bytecode opcodes for the tail-calling VM.
//!
//! The interpreter is a direct-threaded bytecode loop. Each instruction
//! is a u8 opcode followed by 0–N operand bytes.
//! Multi-byte operands use little-endian encoding.

pub const OpCode = enum(u8) {
    // ---- stack ----
    /// Push a constant from the chunk constant pool (operand: 2-byte ConstIdx).
    push_const,
    /// Push null.
    push_null,
    /// Push true.
    push_true,
    /// Push false.
    push_false,

    /// Discard top of stack.
    pop,
    // ---- locals ----
    /// Push local variable at offset (operand: 1-byte offset from frame base).
    loc_get,
    /// Push local variable at offset (operand: 2-byte offset from frame base).
    loc_get_w,
    /// Push local variable without forcing lazy cells (operand: 1-byte offset).
    loc_grab,
    /// Push local variable without forcing lazy cells (operand: 2-byte offset).
    loc_grab_w,
    /// Push captured upvalue without forcing lazy cells (operand: 2-byte index).
    up_grab,
    /// Set local variable at offset, popping from stack.
    loc_set,
    /// Set local variable at offset, popping from stack (operand: 2-byte offset).
    loc_set_w,
    /// Set the value inside a local cell, popping from stack.
    cell_set,
    /// Set the value inside a local cell (operand: 2-byte offset).
    cell_set_w,
    /// Push captured upvalue at offset (operand: 2-byte closure upvalue index).
    up_get,

    // ---- arithmetic ----
    int_add,
    int_sub,
    int_mul,
    int_div,
    int_neg,
    flt_add,
    flt_sub,
    flt_mul,
    flt_div,

    // ---- comparison ----
    cmp_eq,
    cmp_ne,
    cmp_lt,
    cmp_le,
    cmp_gt,
    cmp_ge,
    /// Specialized `eq null` — pop one value, push `true` if it
    /// forces to null. Emitted by `compileBinary` when one side of
    /// `==` is a literal `null`, avoiding generic equality dispatch.
    cmp_eq_null,
    /// Specialized `neq null` — symmetric with `cmp_eq_null`.
    cmp_ne_null,

    // ---- logical ----
    bool_not,
    /// Force top of stack and require it to be a Boolean, leaving the forced
    /// Boolean in place. `&&`/`||`/`->` compile the taken branch's operand
    /// into the expression's result slot, so without this the right operand
    /// escapes the type check the jump gives the left one.
    bool_check,

    // ---- control flow ----
    /// Relative jump forward (operand: 4-byte unsigned offset).
    jump,
    /// Jump forward if top of stack is false (operand: 4-byte unsigned offset).
    jump_false,
    /// Raise an assertion failure.
    fail,

    // ---- data ----
    /// Build an attribute set from pairs on the stack.
    /// Operand: 2-byte count of entries.
    /// Stack layout from lower to higher indexes: [name1, val1, ..., nameN, valN].
    attrs_new,
    /// `attrs_new`, but the compiler guarantees the pairs are already on
    /// the stack in ascending interned-name order with no duplicates —
    /// static attrset literals are grouped (duplicates rejected at compile
    /// time) and emitted name-sorted, so the runtime skips the
    /// per-construction sort + duplicate scan. Operand: 2-byte count.
    attrs_new_srt,
    /// `attrs_new_srt` with the attr NAMES in the chunk's side table instead
    /// of pushed as string constants: the stack carries only the N values,
    /// and names come from `Chunk.attr_names[names_start..names_start+N]`
    /// (compile-time interned, sorted, unique). Saves a `push_const` op,
    /// dispatch, and constant-pool slot per entry.
    /// Operand: count:u16 + names_start:u32.
    attrs_new_named_srt,
    /// `attrs_new_named_srt` WITHOUT the sorted-names guarantee: the
    /// persistent chunk cache rewrites a `_srt` site to this when intern-id
    /// remapping breaks the baked ascending order. Sorts at build time.
    attrs_new_named,
    /// `attrs_new_named_srt` carrying source positions too.
    /// Operand: count:u16 + names_start:u32 + pos_count:u16 + pos_start:u32.
    attrs_new_named_pos_srt,
    /// `attrs_new_named_pos_srt` without the sorted-names guarantee (cache
    /// loader rewrite target, like `attrs_new_named`).
    attrs_new_named_pos,
    /// Build a list from items on the stack.
    /// Operand: 2-byte count of items.
    list_new,
    /// Merge two attrsets as parts of one attrset literal, recursively rejecting
    /// duplicate leaf attributes.
    attrs_merge_strict,
    /// Merge two attrsets, with right-hand keys overriding left-hand keys.
    attrs_merge,
    /// Concatenate two lists.
    list_cat,
    /// Concatenate N lists in one allocation/copy pass. Emitted for an
    /// unparenthesized right-associated `++` chain; operand: 2-byte list count
    /// (N >= 3). Stack before: [list1, ..., listN]; after: [result].
    list_cat_n,
    /// Concatenate N string-like values in a single pass. Stack before:
    /// [part1, ..., partN] (part1 lowest); after: [result]. Each part is
    /// coerced exactly like the binary `+` string path (string / path /
    /// attrs-with-__toString), contexts are merged in part order, and the
    /// text is assembled into one exact-size buffer and interned ONCE.
    /// Emitted for `${...}` interpolation literals: the equivalent
    /// `int_add` fold interns (hashes + copies + permanently retains)
    /// every intermediate prefix of a k-part string. With N == 1 the op
    /// is a bare string coercion — no re-intern of the coerced text.
    /// Operand: 2-byte count (N >= 1).
    str_cat,
    /// Concatenate N parts into a single path, canonicalizing the whole path
    /// ONCE at the end. Stack before: [base, part2, ..., partN] (base lowest);
    /// after: [path]. The base part is a path literal; the rest are coerced
    /// string-like and appended raw. Emitted for interpolated path literals
    /// (`/${a}/${b}`) — a left fold of binary `path + string` would canonicalize
    /// after each step and drop the separators between adjacent `${…}` parts.
    /// Operand: 2-byte count (N >= 1).
    path_cat,
    /// Push the evaluator-owned builtins attrset.
    push_builtins,
    /// Resolve an evaluator search-path literal.
    /// Operand: 2-byte InternId of the search path text without angle brackets.
    file_find,
    /// Resolve an evaluator search-path literal with a wide intern id.
    /// Operand: 4-byte InternId.
    file_find_w,

    // ---- closures and thunks ----
    /// Create a closure value from a chunk and captured upvalues.
    /// Operand: 2-byte ChunkId, 2-byte upvalue count.
    /// Upvalues are the top N values on the stack, popped.
    closure,
    /// Create a closure whose chunk id does not fit in the short form.
    /// Operand: 4-byte ChunkId, 2-byte upvalue count.
    closure_w,
    /// Create a closure and fill upvalues from inline capture descriptors.
    /// Operand: 2-byte ChunkId, 2-byte count, then repeated
    /// 1-byte kind (0=local, 1=upvalue), 2-byte index.
    closure_cap,
    /// Wide-chunk-id form of closure_cap.
    /// Operand: 4-byte ChunkId, 2-byte count, then repeated descriptors.
    closure_cap_w,
    /// Function-argument with a runtime-adaptive laziness decision. The
    /// callee is already on the stack (just below where the argument
    /// goes). If it is a closure whose chunk's body must-forces its
    /// parameter (`scheduling.strict_param`), the argument expression is
    /// evaluated eagerly to a value — no thunk; otherwise it is
    /// materialised as a thunk exactly like `thunk`. Lets us
    /// skip the thunk for dynamically-dispatched strict calls, which the
    /// compiler can't resolve statically.
    /// Operand: 4-byte ChunkId, 2-byte count, then repeated descriptors.
    thunk_arg,
    /// Create a thunk directly from a chunk and inline capture descriptors.
    /// Operand: 2-byte ChunkId, 2-byte count, then repeated descriptors.
    thunk,
    /// Wide-chunk-id form of thunk.
    /// Operand: 4-byte ChunkId, 2-byte count, then repeated descriptors.
    thunk_w,
    /// Fused `thunk + cell_set`. Creates the thunk
    /// from the chunk-id + descriptors, then `publishCellBinding`s it
    /// into the cell-thunk at frame_base + slot (skipping the
    /// push/pop of the new thunk reference). Operand layout:
    ///   chunk_id:2 + K:2 + 3K descriptors + slot:1
    /// The slot byte is at the END so we can rewrite `thunk`
    /// in place at emit time without shifting the descriptor bytes.
    thunk_st_cell,
    /// Fused `thunk + loc_set`.
    thunk_st,
    /// Wide-chunk-id forms of the fused thunk+store family. Past 65,536
    /// registered chunks (any real NixOS eval) every later chunk reference
    /// uses the wide encoding, so these carry the fusion win to the dominant
    /// form. Operand: chunk_id:4 + K:2 + 3K descriptors + slot:1.
    thunk_w_st_cell,
    /// Fused `thunk_w + loc_set`.
    thunk_w_st,
    /// Create a frameless attr-access thunk directly: resolve ONE capture
    /// descriptor (kind:1 + index:2) to a base value and wrap it in an
    /// attr-access thunk over the 2-byte attr name. The compile-time twin of
    /// the `attr_access` trivial-body short-circuit — emitted instead of a
    /// whole `up_get_attr; ret; halt` wrapper chunk (the single most common
    /// chunk shape on a NixOS eval), which the runtime never dispatched
    /// anyway. Operand: kind:1 + index:2 + name:2.
    thunk_attr,
    /// Wide-intern-id form of thunk_attr. Operand: kind:1 + index:2 + name:4.
    thunk_attr_w,

    // ---- calls ----
    /// Call the top-of-stack closure with the value below it as argument.
    /// The stack layout before: [closure, arg].
    /// After: [result].
    call,
    /// Call in tail position. Closure callees reuse the current frame; other
    /// callees behave like `call` and are followed by the normal `ret`.
    call_tail,
    /// Apply a callee to N arguments in one op. Stack before:
    /// [callee, arg1, ..., argN]; after: [result]. Operand: 1-byte N
    /// (N >= 1). Semantically identical to N sequential `call`s, but when
    /// the callee is an uncurried closure whose arity == N the body runs
    /// in a single frame with zero intermediate closure/PAP allocation —
    /// the uncurrying win. Under/over-application and non-closure callees
    /// fall back to one-arg-at-a-time application. See `vm/closures.zig`.
    call_n,
    /// `call_n` in tail position.
    call_tail_n,

    // ---- fused value+ret super-ops ----
    /// Fused `push_const + ret`: load constant N onto the stack and
    /// return from the current frame in one dispatch. Operand:
    /// 2-byte constant index. Emitted by `compileTailExpression`
    /// when the tail expression is a literal — saves one of the two
    /// dispatches that dominate the bytecode loop's per-thunk
    /// overhead.
    push_const_ret,
    /// Fused `loc_get + ret` (narrow slot).
    loc_get_ret,
    /// Fused `loc_get + ret` (wide slot — 2-byte operand).
    loc_get_ret_w,
    /// Fused `up_get + ret` (always 2-byte upvalue index).
    up_get_ret,

    // ---- fused compound super-ops ----
    /// Fused `up_get + attr_get` — read upvalue, force, look up
    /// attribute. Operand: 2-byte upvalue index + 2-byte name InternId.
    /// Saves the intermediate attrs stack value and one dispatch for common
    /// chains such as `lib.foo` and `config.bar`.
    up_get_attr,
    /// Fused `loc_get + attr_get` (narrow slot — 1-byte). Operand:
    /// 1-byte slot + 2-byte name InternId.
    loc_get_attr,
    /// Fused `loc_get_w + attr_get` (wide slot — 2-byte). Operand:
    /// 2-byte slot + 2-byte name InternId.
    loc_get_attr_w,

    // ---- thunks ----
    /// Wrap the top-of-stack value in a mutable lazy cell.
    cell_new,
    /// Wrap the top-of-stack value in a pre-resolved, undemanded
    /// thunk. Used by the compiler when an eagerly-buildable shape
    /// (list / attrset / lambda) appears in a context that requires
    /// the value to *look* like a lazy thunk to renderers (XML lazy
    /// mode in particular) — we skip emitting a child chunk +
    /// `thunk` and just wrap the already-built shell. The
    /// resulting thunk's `force` is O(1) (resolved fast path); the
    /// XML serializer keeps printing `<unevaluated />` until a real
    /// caller marks it demanded.
    thunk_shell,
    /// Allocate an empty (null-wrapped) lazy cell and store it
    /// directly into a local slot. Operand: 1-byte slot index. Fuses
    /// the `push_null + cell_new + loc_set` sequence that the
    /// compiler emits once per let-binding / recursive-attrset
    /// binding / lambda parameter — saving two dispatches and the
    /// intermediate stack push/pop per call.
    cell_init,
    /// Wide-slot variant of `cell_init`. Operand: 2-byte slot index.
    cell_init_w,

    // ---- attribute access ----
    /// Select an attribute from attrset on stack top.
    /// Operand: 2-byte InternId of the attribute name.
    attr_get,
    /// Select an attribute from attrset on stack top with a wide intern id.
    /// Operand: 4-byte InternId.
    attr_get_w,
    /// Strict single-name existence test used by saturated builtins.hasAttr.
    /// Unlike attr_has_path, a non-attrset operand raises TypeError.
    attr_has_strict,
    /// Wide-intern-id form of attr_has_strict.
    attr_has_strict_w,
    /// Select an attribute by a runtime string name.
    /// Stack layout before: [attrs, name].
    attr_get_dyn,
    /// Select a runtime string attribute with a lazy default.
    /// Stack layout before: [attrs, name, default_thunk].
    attr_get_dyn_or,
    /// Select a static attribute path prefix followed by a runtime string
    /// attribute with a lazy default if any segment is missing.
    /// Operand: 1-byte segment count, then that many 2-byte InternIds.
    /// Stack layout before: [attrs, name, default_thunk].
    attr_get_path_dyn_or,
    /// Wide-intern-id form of attr_get_path_dyn_or.
    /// Operand: 1-byte segment count, then that many 4-byte InternIds.
    attr_get_path_dyn_or_w,
    /// Select an attribute path with a lazy default if any segment is missing.
    /// Operand: 1-byte segment count, then that many 2-byte InternIds.
    /// Stack layout before: [attrs, default_thunk].
    attr_get_path_or,
    /// Wide-intern-id form of attr_get_path_or.
    /// Operand: 1-byte segment count, then that many 4-byte InternIds.
    attr_get_path_or_w,
    /// Select an attribute path containing static and runtime string segments
    /// with a lazy default if any segment is missing.
    /// Operand: 1-byte segment count, 1-byte dynamic segment count, then for
    /// each segment a 1-byte tag: 0 followed by 4-byte InternId for static,
    /// 1 for the next runtime string from the stack.
    /// Stack layout before: [attrs, dynamic_name..., default_thunk].
    attr_get_path_mix_or,
    /// Test whether an attribute path exists without forcing the final value.
    /// Operand: 1-byte segment count, then that many 2-byte InternIds.
    /// Stack layout before: [attrs].
    attr_has_path,
    /// Wide-intern-id form of attr_has_path.
    /// Operand: 1-byte segment count, then that many 4-byte InternIds.
    attr_has_path_w,
    /// Test whether an attribute path containing static and runtime string
    /// segments exists without forcing the final value.
    /// Operand: same segment stream as attr_get_path_mix_or.
    /// Stack layout before: [attrs, dynamic_name_thunk...].
    attr_has_path_mix,
    /// Validate an attrset function argument and bind every required formal
    /// directly from the argument set into its frame local. Optional formals
    /// use the sentinel slot 0xffff and are filled by their default path after
    /// this op. Pairs are name-sorted, so validation and binding are one merge
    /// walk over the argument set instead of one lookup thunk per formal.
    /// Operand: allow_extra:u8, cells:u8, count:u16, then count pairs of
    /// (InternId:u16, slot:u16). Stack layout before: [attrs]; after: [].
    attr_bind,
    /// Wide-intern-id form of attr_bind (InternId:u32 in each pair).
    attr_bind_w,
    /// Look up a variable name through active with-scopes.
    /// Operand: 2-byte InternId, 1-byte scope count.
    /// Stack layout before: [scope1, ..., scopeN], ordered nearest to farthest.
    with_lookup,
    /// Wide-intern-id form of with_lookup.
    /// Operand: 4-byte InternId, 1-byte scope count.
    with_lookup_w,
    /// Lazy per-attr compilation: create a `.deferred` thunk for an
    /// attrset value body whose bytecode has NOT been compiled. The body
    /// is compiled on first force (see `compiler/deferred_table.zig` and
    /// `compiler/deferred.zig`).
    /// Operand: 4-byte deferred-table id, 2-byte env count, then `env`
    /// capture descriptors (kind:1, index:2) — same format as thunk.
    thunk_defer,
    /// Bind an attrset-pattern formal whose default is a trivial literal,
    /// WITHOUT wrapping it in a thunk (Nix's `Expr::maybeThunk` for literals).
    /// Looks up the formal name in the arguments attrset without forcing the
    /// stored value; if absent, uses the literal default already on the stack.
    /// Operand: 2-byte InternId of the formal name.
    /// Stack layout before: [args_attrset, literal_default].
    arg_or_lit,
    /// Recursive-set `__overrides`: after the rec object is built (on the
    /// stack) and its binding cells filled, apply the `__overrides` attrset.
    /// Force `built.__overrides` (must be a set, else error); for each entry
    /// `k = v`, if `k` names an existing rec attr re-point its (shared)
    /// binding cell to `v` so recursive siblings see the override, otherwise
    /// add `k = v` as a new attribute. `__overrides` itself is retained.
    /// Emitted ONLY when a rec set statically declares a `__overrides` key —
    /// plain rec sets never carry it. Operand: 4-byte InternId of
    /// `__overrides`. Stack: [built_attrs] -> [final_attrs].
    attrs_apply_overrides,
    // ---- termination ----
    /// Return from the current frame with the value on top of stack.
    ret,
    /// Halt execution (top-level done).
    halt,
    // ---- debugger ----
    /// A source-line breakpoint patched over another opcode's byte (its
    /// operands are untouched). The handler pauses into the debugger, then
    /// chains to the original opcode's handler at the same ip. Never emitted by
    /// the compiler — only written in place by the debugger, and only present
    /// while a breakpoint is set. Kept last so its value can't shift another
    /// opcode's byte encoding. Operands: none of its own.
    breakpoint,
};

pub const count = @typeInfo(OpCode).@"enum".fields.len;

const std = @import("std");

// ---- operand layout (single source of truth) ----
//
// Every opcode's operand shape is declared ONCE, in `layout` below, as a list
// of typed `Operand` fields. This one table drives `operandLen` (used by the
// disassembler's stepping + the capture census) and the disassembler's operand
// RENDERING — so "how many bytes does this op carry, and what do they mean" is
// not re-derived per subsystem. Semantics (the VM handlers) stay hand-written;
// they need typed values on the hot path, not a generic walk.

fn rdU16(code: []const u8, at: usize) u16 {
    return @as(u16, code[at]) | (@as(u16, code[at + 1]) << 8);
}
fn rdU32(code: []const u8, at: usize) u32 {
    return @as(u32, code[at]) | (@as(u32, code[at + 1]) << 8) |
        (@as(u32, code[at + 2]) << 16) | (@as(u32, code[at + 3]) << 24);
}

/// Width of a scalar operand field.
pub const Width = enum {
    b1,
    b2,
    b4,
    pub fn bytes(w: Width) usize {
        return switch (w) {
            .b1 => 1,
            .b2 => 2,
            .b4 => 4,
        };
    }
};

/// One typed operand field. The disassembler renders each variant uniformly and
/// `operandLen` sizes it; variable-length variants read their count from `code`.
pub const Operand = union(enum) {
    /// Internal side-table offset (names_start, cap_start, …): advances, unshown.
    skip: Width,
    /// Deferred-compilation table id. Persistent bytecode rewrites this to a
    /// unit-local ordinal and back; keeping it distinct makes that obligation
    /// exhaustive instead of hiding it in an untyped scalar.
    deferred_id: Width,
    /// u16 constant-pool index → `#idx` + value digest.
    const_idx,
    /// Frame slot / upvalue index → `role[idx]`.
    slot: struct { w: Width, role: Role },
    /// One capture descriptor `(kind:1, index:2)` → `role[idx]` (role from kind).
    cap1,
    /// Chunk id → `chunk[0xid] name` (records an outgoing reference).
    chunk_id: Width,
    /// Interned id → the interned name.
    intern: Width,
    /// A count → `N noun` (noun labels the collection: entries/items/args/…).
    count: struct { w: Width, noun: []const u8 },
    /// u32 relative jump → `+off → target`.
    jump,
    /// u16 count then `3×count` inline capture descriptors → `N captures`.
    captures,
    /// `captures` followed by a trailing 1-byte store slot → `N captures → local[s]`.
    captures_slot,
    /// u8 segment count then `count×width` interned ids → `"a.b.c"`.
    attr_path: Width,
    /// u8 allow-extra, u8 cell-mode, u16 count, then
    /// `count×(width-byte InternId + u16 slot)` sorted binding pairs.
    bind: Width,
    /// Irregular static/dynamic tagged path stream (`attr_*_mix`).
    mix,

    pub const Role = enum { local, upvalue };
};

// `comptime` params matter: `layout`'s arms return `&[_]Operand{…}` array literals, which
// are only promoted to static storage when every element is comptime-known. A
// runtime helper call would make the literal a stack temporary and leave the
// returned slice dangling, so these must fold at comptime.
fn slot(comptime w: Width, comptime role: Operand.Role) Operand {
    return .{ .slot = .{ .w = w, .role = role } };
}
fn cnt(comptime w: Width, comptime noun: []const u8) Operand {
    return .{ .count = .{ .w = w, .noun = noun } };
}

/// The operand layout of `op`: the single source consumed by `operandLen` and
/// the disassembler. Exhaustive (no `else`) so a new opcode is a compile error
/// until its shape is declared here.
pub fn layout(op: OpCode) []const Operand {
    return switch (op) {
        // No operands.
        .push_null, .push_true, .push_false, .pop, .int_add, .int_sub, .int_mul, .int_div, .int_neg, .flt_add, .flt_sub, .flt_mul, .flt_div, .cmp_eq, .cmp_ne, .cmp_lt, .cmp_le, .cmp_gt, .cmp_ge, .cmp_eq_null, .cmp_ne_null, .bool_not, .bool_check, .fail, .attrs_merge, .attrs_merge_strict, .list_cat, .push_builtins, .attr_get_dyn, .attr_get_dyn_or, .call, .call_tail, .cell_new, .thunk_shell, .ret, .halt, .breakpoint => comptime &[_]Operand{},

        .push_const, .push_const_ret => comptime &[_]Operand{.const_idx},

        // Slot / upvalue reads and writes.
        .loc_get, .loc_grab, .loc_set, .cell_set, .cell_init, .loc_get_ret => comptime &[_]Operand{slot(.b1, .local)},
        .loc_get_w, .loc_grab_w, .loc_set_w, .cell_set_w, .cell_init_w, .loc_get_ret_w => comptime &[_]Operand{slot(.b2, .local)},
        .up_grab, .up_get, .up_get_ret => comptime &[_]Operand{slot(.b2, .upvalue)},

        .jump, .jump_false => comptime &[_]Operand{.jump},

        // Collection builders.
        .attrs_new, .attrs_new_srt => comptime &[_]Operand{cnt(.b2, "entries")},
        .attrs_new_named_srt, .attrs_new_named => comptime &[_]Operand{ cnt(.b2, "entries (named)"), .{ .skip = .b4 } },
        .attrs_new_named_pos_srt, .attrs_new_named_pos => comptime &[_]Operand{ cnt(.b2, "entries (named)"), .{ .skip = .b4 }, cnt(.b2, "positions"), .{ .skip = .b4 } },
        .list_new => comptime &[_]Operand{cnt(.b2, "items")},
        .list_cat_n => comptime &[_]Operand{cnt(.b2, "lists")},
        .str_cat, .path_cat => comptime &[_]Operand{cnt(.b2, "parts")},
        .call_n, .call_tail_n => comptime &[_]Operand{cnt(.b1, "args")},

        .file_find => comptime &[_]Operand{.{ .intern = .b2 }},
        .file_find_w => comptime &[_]Operand{.{ .intern = .b4 }},

        // Closures / thunks (chunk id + captures).
        .closure => comptime &[_]Operand{ .{ .chunk_id = .b2 }, cnt(.b2, "upvalues") },
        .closure_w => comptime &[_]Operand{ .{ .chunk_id = .b4 }, cnt(.b2, "upvalues") },
        .closure_cap, .thunk => comptime &[_]Operand{ .{ .chunk_id = .b2 }, .captures },
        .closure_cap_w, .thunk_w, .thunk_arg => comptime &[_]Operand{ .{ .chunk_id = .b4 }, .captures },
        .thunk_st, .thunk_st_cell => comptime &[_]Operand{ .{ .chunk_id = .b2 }, .captures_slot },
        .thunk_w_st, .thunk_w_st_cell => comptime &[_]Operand{ .{ .chunk_id = .b4 }, .captures_slot },
        .thunk_attr => comptime &[_]Operand{ .cap1, .{ .intern = .b2 } },
        .thunk_attr_w => comptime &[_]Operand{ .cap1, .{ .intern = .b4 } },

        // Fused slot/upvalue + attribute.
        .up_get_attr => comptime &[_]Operand{ slot(.b2, .upvalue), .{ .intern = .b2 } },
        .loc_get_attr => comptime &[_]Operand{ slot(.b1, .local), .{ .intern = .b2 } },
        .loc_get_attr_w => comptime &[_]Operand{ slot(.b2, .local), .{ .intern = .b2 } },

        // Attribute access.
        .attr_get => comptime &[_]Operand{.{ .intern = .b2 }},
        .attr_get_w => comptime &[_]Operand{.{ .intern = .b4 }},
        .attr_has_strict => comptime &[_]Operand{.{ .intern = .b2 }},
        .attr_has_strict_w => comptime &[_]Operand{.{ .intern = .b4 }},
        .attr_get_path_or, .attr_get_path_dyn_or, .attr_has_path => comptime &[_]Operand{.{ .attr_path = .b2 }},
        .attr_get_path_or_w, .attr_get_path_dyn_or_w, .attr_has_path_w => comptime &[_]Operand{.{ .attr_path = .b4 }},
        .attr_get_path_mix_or, .attr_has_path_mix => comptime &[_]Operand{.mix},
        .arg_or_lit => comptime &[_]Operand{.{ .intern = .b2 }},
        .attr_bind => comptime &[_]Operand{.{ .bind = .b2 }},
        .attr_bind_w => comptime &[_]Operand{.{ .bind = .b4 }},
        .with_lookup => comptime &[_]Operand{ .{ .intern = .b2 }, cnt(.b1, "scopes") },
        .with_lookup_w => comptime &[_]Operand{ .{ .intern = .b4 }, cnt(.b1, "scopes") },
        .thunk_defer => comptime &[_]Operand{ .{ .deferred_id = .b4 }, .{ .skip = .b4 }, cnt(.b2, "env") },
        .attrs_apply_overrides => comptime &[_]Operand{.{ .intern = .b4 }},
    };
}

/// Bytes the mixed static/dynamic attr-path stream occupies at `at`:
/// u8 seg count, u8 dyn count, then per static segment a `0` tag + 4-byte id,
/// per dynamic segment a `1` tag.
fn mixLen(code: []const u8, at: usize) usize {
    const segments = code[at];
    var len: usize = 2; // seg count + dyn count
    var i: usize = 0;
    while (i < segments) : (i += 1) {
        const tag = code[at + len];
        len += 1;
        if (tag == 0) len += 4;
    }
    return len;
}

/// Byte length of a single operand field at `at` (reads its count for the
/// variable-length variants). The disassembler advances by this so its
/// stepping shares one source with `operandLen`.
pub fn fieldLen(f: Operand, code: []const u8, at: usize) usize {
    return switch (f) {
        .skip, .deferred_id, .chunk_id, .intern => |w| w.bytes(),
        .const_idx => 2,
        .slot => |s| s.w.bytes(),
        .cap1 => 3,
        .count => |c| c.w.bytes(),
        .jump => 4,
        .captures => 2 + @as(usize, rdU16(code, at)) * 3,
        .captures_slot => 2 + @as(usize, rdU16(code, at)) * 3 + 1,
        .attr_path => |w| 1 + @as(usize, code[at]) * w.bytes(),
        .bind => |w| 1 + 1 + 2 + @as(usize, rdU16(code, at + 2)) * (w.bytes() + 2),
        .mix => mixLen(code, at),
    };
}

pub const DecodeError = error{MalformedInstruction};

fn checkedEnd(at: usize, len: usize, code_len: usize) DecodeError!usize {
    const end = std.math.add(usize, at, len) catch return error.MalformedInstruction;
    if (end > code_len) return error.MalformedInstruction;
    return end;
}

/// Fallible twin of `fieldLen` for bytes that have not yet been trusted.
/// Besides bounding every fixed/count-derived read it validates descriptor
/// tags, so consumers never need to speculatively index malformed bytecode.
pub fn checkedFieldLen(f: Operand, code: []const u8, at: usize) DecodeError!usize {
    const fixed = switch (f) {
        .skip, .deferred_id, .chunk_id, .intern => |w| w.bytes(),
        .const_idx => 2,
        .slot => |s| s.w.bytes(),
        .cap1 => 3,
        .count => |c| c.w.bytes(),
        .jump => 4,
        else => 0,
    };
    if (fixed != 0) {
        _ = try checkedEnd(at, fixed, code.len);
        if (f == .cap1 and code[at] > 1) return error.MalformedInstruction;
        return fixed;
    }

    return switch (f) {
        .captures, .captures_slot => blk: {
            _ = try checkedEnd(at, 2, code.len);
            const descriptor_count: usize = rdU16(code, at);
            const payload = std.math.mul(usize, descriptor_count, 3) catch return error.MalformedInstruction;
            const len = std.math.add(usize, 2, payload + @intFromBool(f == .captures_slot)) catch return error.MalformedInstruction;
            _ = try checkedEnd(at, len, code.len);
            var p = at + 2;
            var i: usize = 0;
            while (i < descriptor_count) : (i += 1) {
                if (code[p] > 1) return error.MalformedInstruction;
                p += 3;
            }
            break :blk len;
        },
        .attr_path => |w| blk: {
            _ = try checkedEnd(at, 1, code.len);
            const payload = std.math.mul(usize, code[at], w.bytes()) catch return error.MalformedInstruction;
            const len = std.math.add(usize, 1, payload) catch return error.MalformedInstruction;
            _ = try checkedEnd(at, len, code.len);
            break :blk len;
        },
        .bind => |w| blk: {
            _ = try checkedEnd(at, 4, code.len);
            if (code[at] > 1 or code[at + 1] > 1) return error.MalformedInstruction;
            const pair_len = std.math.add(usize, w.bytes(), 2) catch return error.MalformedInstruction;
            const payload = std.math.mul(usize, rdU16(code, at + 2), pair_len) catch return error.MalformedInstruction;
            const len = std.math.add(usize, 4, payload) catch return error.MalformedInstruction;
            _ = try checkedEnd(at, len, code.len);
            break :blk len;
        },
        .mix => blk: {
            _ = try checkedEnd(at, 2, code.len);
            const segments = code[at];
            const expected_dynamic = code[at + 1];
            var dynamic: u8 = 0;
            var p = at + 2;
            var i: usize = 0;
            while (i < segments) : (i += 1) {
                _ = try checkedEnd(p, 1, code.len);
                const tag = code[p];
                p += 1;
                switch (tag) {
                    0 => p = try checkedEnd(p, 4, code.len),
                    1 => dynamic +|= 1,
                    else => return error.MalformedInstruction,
                }
            }
            if (dynamic != expected_dynamic) return error.MalformedInstruction;
            break :blk p - at;
        },
        else => unreachable,
    };
}

pub const Instruction = struct {
    op: OpCode,
    ip: usize,
    end: usize,
};

/// Single bounded cursor for untrusted bytecode. All cache validation and
/// load-side rewrites step through this cursor before reading operands.
pub const InstructionCursor = struct {
    code: []const u8,
    ip: usize = 0,

    pub fn next(self: *InstructionCursor) DecodeError!?Instruction {
        if (self.ip == self.code.len) return null;
        if (self.code[self.ip] >= count) return error.MalformedInstruction;
        const start = self.ip;
        const op: OpCode = @enumFromInt(self.code[start]);
        var off = start + 1;
        for (layout(op)) |f| off = try checkedEnd(off, try checkedFieldLen(f, self.code, off), self.code.len);
        self.ip = off;
        return .{ .op = op, .ip = start, .end = off };
    }
};

/// Total operand byte length of the instruction at `ip` (excludes the opcode
/// byte itself), derived from `layout`. Reads counts from `code` for the
/// variable-length fields.
pub fn operandLen(op: OpCode, code: []const u8, ip: usize) usize {
    var len: usize = 0;
    for (layout(op)) |f| len += fieldLen(f, code, ip + len);
    return len;
}

test "opcode byte values round-trip through enumFromInt" {
    inline for (@typeInfo(OpCode).@"enum".fields) |field| {
        const op: OpCode = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(u8, field.value), @intFromEnum(op));
    }
}

test "opcode count matches the number of declared variants" {
    try std.testing.expectEqual(@typeInfo(OpCode).@"enum".fields.len, count);
    // Sanity bound: the opcode set is small and fits comfortably in a u8,
    // which the bytecode encoding relies on.
    try std.testing.expect(count > 0);
    try std.testing.expect(count <= 256);
}

test "opcode tag names are unique" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    inline for (@typeInfo(OpCode).@"enum".fields) |field| {
        const result = try seen.getOrPut(std.testing.allocator, field.name);
        try std.testing.expect(!result.found_existing);
    }
}
