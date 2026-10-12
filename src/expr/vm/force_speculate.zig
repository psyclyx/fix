//! Speculation-eligibility policy for `makeThunk`: decides which freshly
//! created thunks are worth submitting to the scheduler ahead of demand, and
//! (for `FIX_SPEC_NOVEL`) whether a closure is the first speculative instance
//! of its chunk. Pure predicates over registry/heap state — no forcing.

const vm_mod = @import("context.zig");
const VM = vm_mod.VM;
const Value = @import("runtime").value.Value;
const BuiltinId = @import("runtime").builtins.BuiltinId;

/// `FIX_SPEC_NOVEL` selector for `makeThunk`: is this closure the first
/// speculative instance of its chunk? (Test-and-set — call at most once
/// per submission, only when the knob is on.)
pub fn isNovelClosureChunk(self: *VM, closure: Value) bool {
    if (!closure.isNixClosure()) return false;
    const c = @import("closures.zig").closureRef(self, closure) catch return false;
    return self.registry.markSpecSubmitted(c.chunk_id);
}

pub inline fn shouldSpeculateClosure(self: *VM, closure: Value) bool {
    // Bound the cascade: if we got here because a helper is *itself*
    // running speculative work, don't submit further speculation. The
    // helper's result may or may not be observed; chaining more
    // speculation off it would just multiply uncertain work.
    if (self.speculation.active) return false;
    return switch (closure.kind()) {
        .closure => isSpeculatableClosureChunk(self, closure),
        // map / mapAttrs / genList / zipAttrsWith produce builtin-closure
        // thunks around a user function. Speculate them at creation when the
        // inner function is substantial; `speculation.active` bounds chaining.
        .builtin_closure => isSpeculatableBuiltinClosure(self, closure),
        else => false,
    };
}

pub fn isSpeculatableClosureChunk(self: *VM, closure: Value) bool {
    // The eligibility bit is pre-computed at chunk registration time
    // (see Chunk.speculatable); read it from the registry's dense slot
    // rather than dereferencing the heap-scattered Chunk.
    const c = @import("closures.zig").closureRef(self, closure) catch return false;
    const slot = self.registry.slot(c.chunk_id) orelse return false;
    return slot.body_is_substantial;
}

pub fn isSpeculatableBuiltinClosure(self: *VM, closure: Value) bool {
    const bc = self.heap.getBuiltinClosure(closure.asObjectId()) catch return false;
    return switch (@as(BuiltinId, @fromBackingInt(@intCast(bc.builtin_id)))) {
        // Map-style fan-out: args[0] is the user function in each.
        // Speculate when it's either a user closure with a substantial
        // body (the chunk-size threshold filters trivial cases like
        // `x: x + 1`) or a builtin known to be expensive enough to
        // earn the scheduler hop — most importantly `import`, which
        // is how the NixOS module system parallelises file
        // resolution.
        .mapValue, .mapAttrValue, .zipAttrsValue => bc.args.len > 0 and
            isSpeculatableMapFunc(self, bc.args[0]),
        // A single lazy derivation attr is not trivial, but forcing it can
        // recursively evaluate arbitrary package inputs. Keep these
        // demand-driven so speculation does not wander into unobserved
        // package graphs (for example pandoc -> luaPackages on the NixOS
        // toplevel).
        .derivationLazyAttr => false,
        else => false,
    };
}

pub inline fn isSpeculatableMapFunc(self: *VM, func: Value) bool {
    if (func.isNixClosure()) return isSpeculatableClosureChunk(self, func);
    if (func.isBuiltin()) return isExpensiveBuiltin(@fromBackingInt(@intCast(func.asBuiltinId())));
    return false;
}

/// Builtins whose body is heavy enough that submitting a speculative
/// force task pays for itself: file I/O, network fetches, or full
/// nested evaluation. Lightweight ones (head, length, isList, ...)
/// stay off this list so `map builtins.head xs` doesn't burn helper
/// fibers on trivially-cheap work.
pub fn isExpensiveBuiltin(id: BuiltinId) bool {
    return switch (id) {
        .import,
        .scopedImport,
        .fetchurl,
        .fetchTarball,
        .fetchGit,
        .fetchTree,
        .readFile,
        .readFileType,
        .readDir,
        .derivation,
        => true,
        else => false,
    };
}
