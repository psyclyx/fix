//! Compiler: AST → Bytecode
//!
//! Walks the AST tree and emits bytecode into a ChunkBuilder.
//! The compiler is stack-based: expressions push their result,
//! statements push/discard as needed.

const std = @import("std");
const LanguagePolicy = @import("../policy.zig").LanguagePolicy;
const compiler_types = @import("types.zig");
const ast = @import("syntax").ast;
pub const Node = ast.Node;
pub const NodeTag = ast.NodeTag;
pub const BinaryOp = ast.BinaryOp;
const bytecode = @import("../bytecode.zig");
const chunk = bytecode.chunk;
const ChunkBuilder = chunk.ChunkBuilder;
const ChunkRegistry = chunk.ChunkRegistry;
const types = @import("runtime").types;
const diagnostic = @import("syntax").diagnostic;
const Diagnostic = diagnostic.Diagnostic;
const Value = @import("runtime").value.Value;
const ObjectHeap = @import("runtime").heap.ObjectHeap;
const InternTable = @import("runtime").intern.InternTable;
const DeferredTable = @import("deferred_table.zig").Table;
const UnitAnalysis = @import("let_analysis/model.zig").UnitAnalysis;
const let_float_model = @import("let_float/model.zig");
const LetFloatUnitState = let_float_model.UnitState;

const InternId = types.InternId;

pub const Local = compiler_types.Local;
pub const Capture = compiler_types.Capture;
pub const WithScope = compiler_types.WithScope;
pub const AttrEntryView = compiler_types.AttrEntryView;
pub const AttrEntryGroup = compiler_types.AttrEntryGroup;
pub const AttrEntryGroups = compiler_types.AttrEntryGroups;
pub const ContainerValueOptions = compiler_types.ContainerValueOptions;
pub const with_capture_name = compiler_types.with_capture_name;

/// Recursive compiler entry points supplied by the dispatch layer. Keeping
/// this narrow interface on the context lets leaf compiler modules recurse
/// without importing the facade that imports them.
pub const Driver = struct {
    compile_node: *const fn (*Compiler, *const Node) anyerror!void,
    compile_and_finish: *const fn (*Compiler, *const Node, ?Value) anyerror!void,
};

/// Explicit post-registration effect owned by the evaluator. The compiler
/// reports the canonical chunk selected for a body after registry mutation is
/// complete; the registry itself remains a storage component and never
/// schedules imports or patches debugger bytecode as a hidden side effect.
pub const ChunkRegistrationSink = struct {
    context: *anyopaque,
    registered: *const fn (context: *anyopaque, chunk_id: types.ChunkId) void,

    pub fn notify(self: ChunkRegistrationSink, chunk_id: types.ChunkId) void {
        self.registered(self.context, chunk_id);
    }
};

pub const Compiler = struct {
    driver: *const Driver,
    /// Per-compilation-unit SCRATCH allocator. Everything the compiler
    /// builds while emitting a chunk — locals/captures/with-scope tracking,
    /// strictness analysis maps, name-resolution sets, the ChunkBuilder's
    /// growth buffers, diagnostics — lives here. It is an arena owned by the
    /// unit root (`parseAndCompile` / `deferred.compile`) and freed wholesale
    /// when the unit finishes, so individual structures never need per-node
    /// frees. Child compilers share the root's arena.
    ///
    /// INVARIANT: anything that must outlive the compile (the emitted Chunk's
    /// `code`/`constants`/etc.) is duped onto `persistent` instead — that
    /// handoff happens only at `ChunkBuilder.finish`. Registry/deferred-table
    /// entries and copied-out diagnostics carry their own persistent copies.
    allocator: std.mem.Allocator,
    /// Long-lived allocator (evaluator lifetime) for compile OUTPUT only:
    /// the bytecode the registered chunk owns. Never used for scratch.
    persistent: std.mem.Allocator,
    builder: *ChunkBuilder,
    registry: *ChunkRegistry,
    registration_sink: ?ChunkRegistrationSink = null,
    /// Used by integer-literal compilation to box i64 values that
    /// exceed the inline Value range (see `runtime/int.zig`). The
    /// resulting boxed object lives in the heap for the same span as
    /// the chunk constants that reference it — i.e. the evaluator
    /// lifetime, which always outlives any chunk execution.
    heap: *ObjectHeap,
    source: []const u8,
    intern: *InternTable,
    base_path: ?[]const u8,
    source_path: ?[]const u8,
    /// $HOME, for expanding `~/…` home-relative path literals at compile time
    /// (Nix resolves the tilde at parse time). Null when unset in the env.
    home_dir: ?[]const u8,
    policy: LanguagePolicy = .{},
    /// Immutable codegen policy plus Engine-owned census, inherited by child
    /// compilers and supplied explicitly to force-time deferred compiles.
    let_float: let_float_model.Context = .{},
    source_file_id: ?InternId,
    locals: std.ArrayListUnmanaged(Local),
    captures: std.ArrayListUnmanaged(Capture),
    /// Debug-only slot→name record (parallel to slot allocation). Populated in
    /// `declareLocal` when `registry.capture_names` is on; handed to the
    /// registry's `local_names` sidecar at finalize. Empty otherwise.
    local_names: std.ArrayListUnmanaged(InternId),
    with_scopes: std.ArrayListUnmanaged(WithScope),
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    owned_diagnostic_messages: std.ArrayListUnmanaged([]u8),
    line_index: diagnostic.LineIndex,
    line_index_ready: bool,
    parent: ?*Compiler,
    skip_local_slot: ?u16,
    /// Prevent child chunks created in the current region from being submitted
    /// speculatively. Deprecated recursive-set overrides use this while their
    /// binding cells are still eligible for the one-time re-point operation.
    suppress_child_speculation: bool,
    /// Lexical nesting depth. u16 rather than u8 because every `let`, lambda
    /// body and `with` body opens a scope and Nix accepts such nesting far past
    /// 255; `beginScope` guards the top of this range.
    scope_depth: u16,
    slot_count: u16,
    /// Count of attr value bodies deferred during this compile (lazy
    /// per-attr compilation). Tracked on the ROOT compiler (children
    /// bump the root); `parseAndCompile` reads it to decide whether to
    /// retain the file's AST arena. See `compiler/attrs.zig`.
    deferred_count: u32,
    /// Deferred-attr table to register bodies into, set on the ROOT
    /// compiler by `parseAndCompile`. Null disables deferral (e.g. the
    /// synthetic parent used by force-time deferred compilation, so
    /// nested attrsets there compile eagerly). See `deferred_table.zig`.
    deferred_table: ?*DeferredTable = null,
    /// A pre-built line index to use instead of building one over
    /// `source`. Set on the synthetic root of a force-time deferred
    /// compile so it doesn't rebuild the index over the whole (possibly
    /// huge) file per body. Not owned — never freed by `deinit`.
    external_line_index: ?*diagnostic.LineIndex = null,
    /// Memoized result of `diagnostics.ensureLineIndex` — avoids walking
    /// the parent chain per compiled node. Points at the root's
    /// `line_index` (or `external_line_index`); never owned.
    resolved_line_index: ?*diagnostic.LineIndex = null,
    /// Spare child ChunkBuilders, populated on the ROOT compiler only
    /// (children route through it). One builder is created per emitted
    /// chunk; recycling the buffers avoids paying the builder's initial
    /// code/constants capacity allocation ~once per chunk.
    builder_pool: std.ArrayListUnmanaged(ChunkBuilder) = .empty,
    /// Per-unit `let` cluster registry (see `compiler/let_analysis/`): the
    /// single-walk binding-placement analysis, populated at unit start by
    /// `let_float.analyzeUnit` and extended on demand for post-pass AST.
    /// ROOT compiler only (children route through the parent chain);
    /// scratch-lifetime like everything else on `allocator`.
    let_units: ?*UnitAnalysis = null,
    /// Optimizer-only plans and flattened AST overlays layered over the
    /// immutable `let_units` analysis. ROOT compiler only; scratch-lifetime.
    let_float_state: ?*LetFloatUnitState = null,
    /// Chunk ids this unit registered, in registration order (children
    /// before parents — a chunk's code only references already-listed
    /// chunks). ROOT compiler only; feeds the persistent chunk cache's
    /// unit record (`bytecode/chunk/cache.zig`). Scratch-lifetime.
    unit_chunks: std.ArrayListUnmanaged(types.ChunkId) = .empty,
    /// Deferred-table ids this unit registered, in registration order.
    /// ROOT compiler only; same consumer as `unit_chunks`.
    unit_deferred: std.ArrayListUnmanaged(u32) = .empty,
    /// Arena that `.elided` bodies are sub-parsed into (body-span elision;
    /// see `literals.materializeElided`). Set on the ROOT compiler:
    /// `parseAndCompile` points it at the file's (possibly retained) AST
    /// arena; `deferred.compile` at a per-compile throwaway arena. Null in
    /// roots that can never see elided nodes (elision is only enabled for
    /// file parses).
    ast_arena: ?*ast.AstArena = null,
    /// Whether `materializeElided` may overwrite the shared `.elided` node
    /// in place with its parsed body. True only for the single-threaded
    /// original file compile (where in-place replacement makes every later
    /// consumer — merge checks, strictness stamps — see exactly the tree an
    /// eager parse would have built). Force-time deferred compiles run
    /// concurrently over the shared retained AST and must never write to it.
    elide_mutable: bool = false,
    /// Best-effort chunk naming (`fix disasm`, gated on `registry.capture_names`).
    /// `name_hint` is set by let/attr-set compilation just before a bound value
    /// is compiled; the first child compiler spun up for that value consumes it
    /// into its own `chunk_name`, which is recorded against the chunk id at
    /// registration. `name_prefix` is the joined path of enclosing named chunks:
    /// real attr/let segments join with `.` (`a.b.c`), synthetic segments (λ…,
    /// node-tag tags) join with `·` so the name never reads as a false attr
    /// path. All null (and free) when off.
    name_hint: ?InternId = null,
    /// Whether `name_hint` is synthetic (λ/tag) rather than a real binding name
    /// — selects the `·` joiner and lets real names take precedence.
    name_hint_synthetic: bool = false,
    /// Whether `name_hint` names a genuinely RECURSIVE binding — i.e. one whose
    /// RHS can see it by name and resolve to itself. Only `let` bindings
    /// qualify (Nix `let` is recursive, and an inner `let` shadows any outer
    /// binding of the same name). Attr-set attrs do NOT: a same-named reference
    /// in `{ overrides = self: super: (overrides …) …; }` resolves to an OUTER
    /// `overrides`, not the attr. The strictness self-recursion fixpoint keys
    /// off this so it never mistakes such a shadowing reference for a self-call.
    name_hint_recursive: bool = false,
    /// Always-on qualified-name node for the chunk this compiler emits (see
    /// `bytecode/name_tree.zig`). Threaded down the compiler chain: a named
    /// child extends it, an anonymous child inherits it. Unlike the `·`/`.`
    /// string naming above (gated on `capture_names`), this is always built —
    /// cheaply, one small node per bound chunk.
    name_id: bytecode.NameId = bytecode.root_name_id,
    /// This compile's ambient scope REPLACES the base (builtins) scope rather
    /// than overlaying it — the `builtins.scopedImport` semantic, where the
    /// supplied attrset becomes the entire free-identifier environment. When
    /// set, free identifiers resolve against the ambient scope BEFORE (and
    /// instead of) the static builtins, so even names that are builtins
    /// (`import`, `map`, …) bind to the attrset's entries. Set on the root by
    /// `parseAndCompile` (scope present AND a source_path — i.e. a scoped
    /// import, not a repl/debug overlay), inherited by children. The repl's
    /// ambient scope keeps this false, so builtins stay visible there.
    scoped_base: bool = false,

    pub fn init(
        driver: *const Driver,
        allocator: std.mem.Allocator,
        persistent: std.mem.Allocator,
        builder: *ChunkBuilder,
        registry: *ChunkRegistry,
        source: []const u8,
        intern: *InternTable,
        heap: *ObjectHeap,
    ) Compiler {
        return .{
            .driver = driver,
            .allocator = allocator,
            .persistent = persistent,
            .builder = builder,
            .registry = registry,
            .heap = heap,
            .source = source,
            .intern = intern,
            .base_path = null,
            .source_path = null,
            .home_dir = null,
            .source_file_id = null,
            .locals = .empty,
            .captures = .empty,
            .local_names = .empty,
            .with_scopes = .empty,
            .diagnostics = .empty,
            .owned_diagnostic_messages = .empty,
            .line_index = .empty,
            .line_index_ready = false,
            .parent = null,
            .skip_local_slot = null,
            .suppress_child_speculation = false,
            .scope_depth = 0,
            .slot_count = 0,
            .deferred_count = 0,
        };
    }

    /// Bootstrap a child compiler for a nested body (thunk, apply-arg,
    /// attr-entry, or lambda body): share the parent's allocators, registry,
    /// source, intern table, and heap via `init`, then inherit the source-
    /// location context (`parent`, `base_path`, `source_path`,
    /// `source_file_id`). Every nested-body compile goes through here so the
    /// inherited-field set lives in exactly one place.
    pub fn initChild(self: *Compiler, builder: *ChunkBuilder) Compiler {
        var child = Compiler.init(
            self.driver,
            self.allocator,
            self.persistent,
            builder,
            self.registry,
            self.source,
            self.intern,
            self.heap,
        );
        child.parent = self;
        child.scoped_base = self.scoped_base;
        child.base_path = self.base_path;
        child.source_path = self.source_path;
        child.home_dir = self.home_dir;
        child.policy = self.policy;
        child.let_float = self.let_float;
        child.source_file_id = self.source_file_id;
        child.registration_sink = self.registration_sink;
        child.suppress_child_speculation = self.suppress_child_speculation;
        // Qualified-name tree: the first child spun up for a named bound value
        // claims the pending name as a child node of this compiler's name and
        // becomes the parent for its own nested bodies. Real binding segments
        // are always recorded (traces/errors); synthetic λ/tag segments are
        // armed only under `capture_names` (disasm detail), so an ordinary run
        // keeps clean `pkgs.hello` paths. Unnamed children inherit the parent.
        child.name_id = self.name_id;
        if (self.name_hint) |seg| {
            child.name_id = self.registry.childName(self.name_id, seg, self.name_hint_synthetic) catch self.name_id;
            self.name_hint = null;
            self.name_hint_synthetic = false;
            self.name_hint_recursive = false;
        }
        return child;
    }

    /// Arm the pending chunk name for the next child compiler: the first body
    /// spun up (see `childCompiler`) claims `name_id` as its best-effort name.
    /// A no-op unless `fix disasm` turned name capture on, so callers can arm
    /// unconditionally without gating on the hot path.
    pub fn armName(self: *Compiler, name_id: InternId) void {
        // Always on now: the qualified-name tree needs real binding segments in
        // every run (traces/errors), and setting a pending `InternId` is cheap.
        // `armSyntheticName`/`armNodeTagName` stay gated — synthetic detail is
        // disasm-only. See `initChild`.
        self.name_hint = name_id;
        self.name_hint_synthetic = false;
        self.name_hint_recursive = false;
    }

    /// Like `armName`, but flags the binding as genuinely recursive (a `let`
    /// binding — see `name_hint_recursive`). Used by `let` compilation so the
    /// strictness self-recursion fixpoint may key off the lambda's own name.
    pub fn armRecursiveName(self: *Compiler, name_id: InternId) void {
        self.name_hint = name_id;
        self.name_hint_synthetic = false;
        self.name_hint_recursive = true;
    }

    /// Arm a *synthetic* name (e.g. `λpkgs` for an unbound lambda, `(apply)`
    /// for an argument thunk) — only when no real binding name is already
    /// pending, since a binding name is always the better attribution.
    pub fn armSyntheticName(self: *Compiler, text: []const u8) void {
        if (!self.registry.capture_names or self.name_hint != null) return;
        self.name_hint = self.intern.intern(text) catch return;
        self.name_hint_synthetic = true;
    }

    /// Arm a synthetic tag derived from the node kind — `(apply)`, `(if_expr)`,
    /// `(string)`, … — for child chunks with no binding name (argument thunks,
    /// operands, interpolations).
    pub fn armNodeTagName(self: *Compiler, node: *const Node) void {
        if (!self.registry.capture_names or self.name_hint != null) return;
        var buf: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "({s})", .{@tagName(node.tag)}) catch return;
        self.armSyntheticName(t);
    }

    /// Register `ch`, tagging it with this compiler's qualified-name node.
    pub fn registerChunk(self: *Compiler, input: chunk.Chunk) !types.ChunkId {
        var ch = input;
        if (self.suppress_child_speculation) ch.scheduling.body_is_substantial = false;
        if (!self.registry.dedup_compiler_chunks) {
            // One-shot compilation overwhelmingly produces unique chunks.
            // Hashing every body and its side tables, then allocating a dedup
            // candidate, costs more than the vanishingly rare reuse saves.
            const id = try self.registry.registerNamed(ch, self.name_id);
            try self.recordChunkSidecar(id, &ch);
            try self.recordUnitChunk(id);
            if (self.registration_sink) |sink| sink.notify(id);
            return id;
        }

        // Persistent/debug evaluators can compile the same source repeatedly;
        // preserve canonical ids and their cross-evaluation memo behavior.
        const r = try self.registry.registerDeduped(ch, self.name_id);
        if (r.reused) {
            var copy = ch;
            copy.deinit(self.persistent);
        } else {
            try self.recordChunkSidecar(r.id, &ch);
        }
        // Reused (cross-unit) ids are recorded too: the cache serializer
        // rejects units whose code references chunks outside the unit list,
        // and a deduped id NOT in the list would be exactly that.
        try self.recordUnitChunk(r.id);
        if (self.registration_sink) |sink| sink.notify(r.id);
        return r.id;
    }

    /// Track a unit-registered chunk id on the ROOT compiler (children
    /// route up), in registration order.
    pub fn recordUnitChunk(self: *Compiler, id: types.ChunkId) !void {
        const root = self.rootCompiler();
        try root.unit_chunks.append(root.allocator, id);
    }

    /// Track a unit-registered deferred-table id on the ROOT compiler.
    pub fn recordUnitDeferred(self: *Compiler, id: u32) !void {
        const root = self.rootCompiler();
        try root.unit_deferred.append(root.allocator, id);
    }

    /// Record disassembly-only slot names and source-file metadata. Qualified
    /// chunk names live in `name_tree`.
    fn recordChunkSidecar(self: *Compiler, id: types.ChunkId, ch: *const chunk.Chunk) !void {
        _ = ch;
        if (self.source_file_id) |file| try self.registry.recordFile(id, file);
        // This compiler's capture list IS the chunk's upvalue vector (slot
        // order), and every capture carries its binding name — record them for
        // the disassembler's upvalue table.
        if (self.registry.capture_names and self.captures.items.len > 0) {
            const names = try self.allocator.alloc(types.InternId, self.captures.items.len);
            defer self.allocator.free(names);
            for (self.captures.items, names) |cap, *n| n.* = cap.name_id;
            try self.registry.recordUpvalueNames(id, names);
        }
        // Local binding names (slot order) — the debugger resolves
        // breakpoint-scope identifiers through this.
        if (self.registry.capture_names and self.local_names.items.len > 0) {
            try self.registry.recordLocalNames(id, self.local_names.items);
        }
    }

    pub fn deinit(self: *Compiler) void {
        for (self.builder_pool.items) |*builder| builder.deinit(self.allocator);
        self.builder_pool.deinit(self.allocator);
        self.unit_chunks.deinit(self.allocator);
        self.unit_deferred.deinit(self.allocator);
        for (self.owned_diagnostic_messages.items) |message| {
            self.allocator.free(message);
        }
        self.owned_diagnostic_messages.deinit(self.allocator);
        self.with_scopes.deinit(self.allocator);
        self.captures.deinit(self.allocator);
        self.locals.deinit(self.allocator);
        self.local_names.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        if (self.parent == null and self.line_index_ready) {
            self.line_index.deinit(self.allocator);
        }
    }

    /// Take a ChunkBuilder for a nested chunk compile — recycled from the
    /// root's pool when available. Pair with `releaseBuilder`.
    pub fn acquireBuilder(self: *Compiler) !ChunkBuilder {
        const root = self.rootCompiler();
        if (root.builder_pool.pop()) |pooled| {
            var builder = pooled;
            builder.reset();
            return builder;
        }
        return ChunkBuilder.init(self.allocator);
    }

    /// Return a finished child builder's buffers to the root's pool. The
    /// builder must not be used again by the caller.
    pub fn releaseBuilder(self: *Compiler, builder: *ChunkBuilder) void {
        const root = self.rootCompiler();
        root.builder_pool.append(root.allocator, builder.*) catch {
            builder.deinit(self.allocator);
        };
    }

    fn rootCompiler(self: *Compiler) *Compiler {
        var compiler = self;
        while (compiler.parent) |parent| compiler = parent;
        return compiler;
    }

    pub fn compileAndFinish(self: *Compiler, node: *const Node, scope_value: ?Value) !void {
        return self.driver.compile_and_finish(self, node, scope_value);
    }

    pub fn compileNode(self: *Compiler, node: *const Node) anyerror!void {
        return self.driver.compile_node(self, node);
    }
};
