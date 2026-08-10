//! Engine — the top-level orchestration layer.
//!
//! Manages the shared state (chunk registry, intern table, scheduler) and runs
//! the worker threads that execute bytecode.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const store_domain = @import("store");
const fetchers_mod = @import("fetchers");
const types = @import("runtime").types;
const bytecode = @import("bytecode.zig");
const InternTable = @import("runtime").intern.InternTable;
const ChunkRegistry = bytecode.ChunkRegistry;
const ChunkBuilder = bytecode.ChunkBuilder;
const ChunkId = types.ChunkId;
const Scheduler = @import("eval/workers.zig").Scheduler;
const vm_mod = @import("vm.zig");
const execution = @import("eval/workers.zig");
const VM = vm_mod.VM;
const LanguagePolicy = @import("policy.zig").LanguagePolicy;
const vm_force = @import("vm.zig").force;
const vm_errors = @import("vm.zig").errors;
const vm_builtins = @import("vm.zig").builtins;
const vm_strings = @import("vm.zig").strings;
const ObjectHeap = @import("runtime").heap.ObjectHeap;
const heap_collector = @import("runtime").heap_collector;
const FileCache = store_domain.FileCache;
const FetchService = fetchers_mod.FetchService;
const regex_mod = @import("support.zig").regex;
const corepkgs = @import("eval/imports/corepkgs.zig");
const vma_mod = @import("runtime").mem_tag.vma;
const realization = @import("store").realization;
const derivation = @import("store").derivation;
const Value = @import("runtime").value.Value;
const builtins = @import("runtime").builtins;
const parser_mod = @import("syntax").parser;
const diagnostic = @import("syntax").diagnostic;
const eval_trace = @import("observ.zig").trace;
const observ = @import("base").observ;
const hugetlb = @import("base").hugetlb;
const ast_mod = @import("syntax").ast;
const deferred_mod = @import("compiler.zig").deferred_table;
const chunk_cache = @import("bytecode/chunk/cache.zig");
const chunk_cache_store = @import("bytecode/chunk/cache/store.zig");
const EvaluationReport = @import("eval/report.zig").EvaluationReport;
const path_ops = @import("runtime").paths;
const eval_print = @import("eval/print.zig");
const search_path_mod = @import("eval/search_path.zig");
const imports_mod = @import("eval/imports.zig");
const tuning = @import("eval/tuning.zig");
const debugger_state = @import("eval/debugger_state.zig");
const debug_session = @import("eval/debug_session.zig");
const bytecode_disasm = @import("tooling/bytecode/disasm.zig");
const effects_mod = @import("effects.zig");

const worker_mod = execution.worker;
const gc_controller = @import("eval/gc_controller.zig");
const gc_coordinator = @import("eval/gc_coordinator.zig");
const build_session = @import("build_session.zig");
const store_state = @import("eval/store_state.zig");
const lifecycle = @import("eval/lifecycle.zig");
const tooling_adapter = @import("eval/tooling.zig");
const fiber_mod = @import("base").fiber;
const prof = @import("probe.zig").prof;
const compiler_mod = @import("compiler.zig");
const VmTrace = @import("vm.zig").trace_log.VmTrace;
const ThunkTrace = @import("probe.zig").thunk_trace.ThunkTrace;
const SpinMutex = @import("base").sync.SpinMutex;
const owned_strings = @import("base").owned_strings;

const parse_observation: observ.SpanSpec = .{
    .category = "eval",
    .name = "parse",
    .begin_verb = "parsing",
    .finish_verb = "parsed",
    .begin_level = 3,
    .finish_level = 2,
};
const compile_observation: observ.SpanSpec = .{
    .category = "eval",
    .name = "compile",
    .begin_verb = "compiling",
    .finish_verb = "compiled",
    .begin_level = 3,
    .finish_level = 2,
};
const evaluate_observation: observ.SpanSpec = .{
    .category = "eval",
    .name = "evaluate",
    .begin_verb = "evaluating",
    .finish_verb = "evaluated",
    .begin_level = std.math.maxInt(u8),
    .finish_level = std.math.maxInt(u8),
};
const import_observation: observ.SpanSpec = .{
    .category = "eval",
    .name = "import",
    .begin_verb = "importing",
    .finish_verb = "imported",
    .begin_level = std.math.maxInt(u8),
    .finish_level = std.math.maxInt(u8),
};
const render_observation: observ.SpanSpec = .{
    .category = "eval",
    .name = "render",
    .begin_verb = "rendering",
    .finish_verb = "rendered",
    .begin_level = std.math.maxInt(u8),
    .finish_level = std.math.maxInt(u8),
};
const fetch_observation: observ.SpanSpec = .{
    .category = "fetch",
    .name = "fetch",
    .begin_verb = "fetching",
    .finish_verb = "fetched",
};

fn observationDetails(subject: []const u8) observ.Details {
    return .{ .subject = if (std.fs.path.isAbsolute(subject))
        .{ .path = subject }
    else
        .{ .text = subject } };
}

const gc = @import("runtime").gc;
const future_mod = @import("runtime").future;
const worker_id_mod = @import("base").worker_id;

pub const Diagnostic = diagnostic.Diagnostic;
pub const EvalTrace = eval_trace.Trace;

pub const ReleaseAction = lifecycle.ReleaseAction;

/// Why the debugger was entered (re-exported from the VM layer so the CLI can
/// switch on it without reaching into `vm`).
pub const BreakReason = vm_mod.BreakReason;

/// A top-level evaluation together with the bytecode entry that produced it.
/// Most callers only need `value`; inspection frontends retain `entry_chunk`
/// so concrete results (which carry no runtime code pointer) still have a
/// useful initial location in the VM explorer.
pub const EvaluationResult = struct {
    value: Value,
    entry_chunk: ChunkId,
};

/// The CLI-supplied debugger console. `run` drives one interactive pause.
pub const DebugUi = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, *DebugSession) anyerror!void,
};

const DebuggerState = debugger_state.State(DebugUi, bytecode.BreakpointTable);

/// One rendered backtrace frame: the running chunk and its source anchor.
/// `line`/`column` are 1-based; `file`/all fields are 0 when unavailable.
pub const DebugFrame = debug_session.DebugFrame;

/// A live handle to a paused evaluation, handed to the debugger UI. It exposes
/// only facade-level operations (backtrace, scope inspection, evaluate-in-place,
/// value rendering) so the `cli` layer never touches raw VM types. All methods
/// run on the paused demand fiber; `eval` re-enters the evaluator, which is
/// safe because forcing already nests VM frames (`runIsolatedFrame`).
pub const DebugSession = struct {
    ev: *Engine,
    vm: *VM,
    /// The value passed to `builtins.break`, returned by a stepped frame, or
    /// under evaluation at an error. It may be an unforced thunk.
    value: Value,
    reason: BreakReason,

    /// Number of active call frames (top of stack last).
    pub fn frameCount(self: *const DebugSession) usize {
        return debug_session.frameCount(self.vm);
    }

    /// Frame `i` (0 = outermost, `frameCount()-1` = innermost/current).
    pub fn frame(self: *const DebugSession, i: usize) DebugFrame {
        return debug_session.frame(debugContext(self), i);
    }

    pub fn frameChunkId(self: *const DebugSession, i: usize) ChunkId {
        return debug_session.frameRef(self.vm, i).frame().chunk_id;
    }

    /// The current (innermost) frame, or null if the stack is empty.
    pub fn currentFrame(self: *const DebugSession) ?DebugFrame {
        const count = self.frameCount();
        if (count == 0) return null;
        return self.frame(count - 1);
    }

    /// The source text for frame `i` — the file it runs (from the FileCache),
    /// or the entry `-E` source. Null if neither is available. The frame's span
    /// (`frame(i).span`) offsets into this text. Used to show a code snippet at
    /// the pause.
    pub fn frameSourceText(self: *DebugSession, i: usize) ?[]const u8 {
        return debug_session.frameSourceText(debugContext(self), i);
    }

    /// Render one frame's current bytecode location without exposing the
    /// evaluator or raw VM to a line-oriented debugger frontend.
    pub fn writeFrameCode(
        self: *const DebugSession,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        i: usize,
        color_depth: @import("base").terminal_color.Depth,
    ) !void {
        const frame_ref = debug_session.frameRef(self.vm, i);
        const vm_frame = frame_ref.frame();
        const chunk = self.ev.registry.get(vm_frame.chunk_id) orelse return;
        try bytecode_disasm.writeChunk(
            allocator,
            writer,
            vm_frame.chunk_id,
            chunk,
            .{ .intern = &self.ev.intern, .registry = &self.ev.registry },
            .{
                .show_header = false,
                .show_constants = false,
                .show_code = true,
                .show_source = true,
                .show_bytes = true,
                .color_depth = color_depth,
                .current_offset = self.frame(i).instruction,
            },
        );
    }

    /// Local slots of frame `i` (the values in `vm.stack[base..base+count]`).
    /// Names are not tracked per local, so callers index by slot.
    pub fn localCount(self: *const DebugSession, i: usize) usize {
        return debug_session.frameRef(self.vm, i).frame().local_count;
    }

    pub fn localValue(self: *const DebugSession, i: usize, slot: usize) Value {
        const ref = debug_session.frameRef(self.vm, i);
        const f = ref.frame();
        return ref.vm.stack[f.frame_base + slot];
    }

    /// The frame's live operand (working) stack — the VM stack slots above its
    /// locals, up to the next frame's base (or the VM's stack pointer for the
    /// innermost frame). Lets a pause show the raw VM stack, not just locals.
    pub fn stackSlotCount(self: *const DebugSession, i: usize) usize {
        const ref = debug_session.frameRef(self.vm, i);
        const f = ref.frame();
        const top: u32 = if (ref.index + 1 < ref.vm.frames_len)
            ref.vm.frames[ref.index + 1].frame_base
        else
            ref.vm.sp;
        const base = f.frame_base + f.local_count;
        return if (top > base) top - base else 0;
    }

    pub fn stackSlot(self: *const DebugSession, i: usize, n: usize) Value {
        const ref = debug_session.frameRef(self.vm, i);
        const f = ref.frame();
        return ref.vm.stack[f.frame_base + f.local_count + @as(u32, @intCast(n))];
    }

    /// Write frame `i`'s always-on qualified name (`pkgs.hello`) to `w`, or
    /// nothing if anonymous. Available in every run — no `capture_names` flag.
    pub fn writeFrameName(self: *const DebugSession, w: *std.Io.Writer, i: usize) !void {
        const ref = debug_session.frameRef(self.vm, i);
        try self.ev.registry.writeQualifiedName(w, ref.frame().chunk_id, &self.ev.intern);
    }

    pub fn hasFrameName(self: *const DebugSession, i: usize) bool {
        return self.ev.registry.hasQualifiedName(debug_session.frameRef(self.vm, i).frame().chunk_id);
    }

    /// The source name of local `slot` in frame `i`, if the compiler recorded
    /// one (requires chunk-name capture, which `--debugger` enables). Internal
    /// (`\x00`-prefixed) names are hidden.
    pub fn localName(self: *const DebugSession, i: usize, slot: usize) ?[]const u8 {
        const names = self.ev.registry.localNamesOf(debug_session.frameRef(self.vm, i).frame().chunk_id) orelse return null;
        if (slot >= names.len) return null;
        return debug_session.displayName(self.ev.intern.get(names[slot]));
    }

    /// The source name of upvalue `idx` in frame `i`, if recorded.
    pub fn upvalueName(self: *const DebugSession, i: usize, idx: usize) ?[]const u8 {
        const names = self.ev.registry.upvalueNamesOf(debug_session.frameRef(self.vm, i).frame().chunk_id) orelse return null;
        if (idx >= names.len) return null;
        return debug_session.displayName(self.ev.intern.get(names[idx]));
    }

    pub fn upvalueCount(self: *const DebugSession, i: usize) usize {
        return if (debug_session.frameRef(self.vm, i).frame().upvalues) |ups| ups.len else 0;
    }

    pub fn upvalueValue(self: *const DebugSession, i: usize, idx: usize) Value {
        return debug_session.frameRef(self.vm, i).frame().upvalues.?[idx];
    }

    /// Force `v` (shallow) on the paused fiber and return the result.
    pub fn force(self: *DebugSession, v: Value) !Value {
        _ = self.retain(v);
        return self.retain(try self.runAncillary(forceAncillary, .{v}));
    }

    /// Render `v` for display (forces thunks as needed), same formatting as the
    /// repl. Runs on the paused fiber's VM.
    pub fn writeValue(self: *DebugSession, writer: *std.Io.Writer, v: Value) !void {
        _ = self.retain(v);
        return self.runAncillary(writeValueAncillary, .{ writer, v });
    }

    /// Render a concise value description without forcing it. This is safe for
    /// automatic return-step annotations; `writeValue` remains the explicit,
    /// potentially forcing full renderer.
    pub fn writeValueSummary(self: *const DebugSession, writer: *std.Io.Writer, v: Value) !void {
        return debug_session.writeValueSummary(debugContext(self), writer, v);
    }

    /// Look up interned text (e.g. a source file id).
    pub fn internText(self: *const DebugSession, id: types.InternId) []const u8 {
        return self.ev.intern.get(id);
    }

    /// Compile and evaluate `source` against `scope` (an ambient attrset whose
    /// members resolve as free identifiers, like the repl's bindings), reusing
    /// the paused evaluator. Returns the resulting (unforced) value.
    pub fn eval(self: *DebugSession, source: []const u8, scope: ?Value) !Value {
        if (scope) |value| _ = self.retain(value);
        return self.retain(try self.runAncillary(evalAncillary, .{ source, scope }));
    }

    /// Debugger inspection is ancillary to the paused language evaluation. A
    /// failed console expression or value rendering is normally caught by the
    /// UI so the session can continue; it must therefore neither leave its
    /// exception in the paused fiber's carrier nor overwrite the paused
    /// evaluation's user-facing trace. Keep both pieces of fiber state scoped
    /// together, including for nested VMs created by `eval`/the value printer.
    fn runAncillary(
        self: *DebugSession,
        comptime body: anytype,
        args: anytype,
    ) !ReturnPayload(@TypeOf(body)) {
        const ctx = self.vm.executionContext();
        const saved_failure = ctx.take();
        const saved_vm_trace = self.vm.trace;
        const saved_ctx_trace = ctx.error_trace;
        var scratch_trace = eval_trace.Trace.init(self.ev.allocator);
        self.vm.trace = &scratch_trace;
        ctx.error_trace = &scratch_trace;
        defer {
            self.vm.trace = saved_vm_trace;
            ctx.error_trace = saved_ctx_trace;
            ctx.clearFailure();
            if (saved_failure) |failure| ctx.restore(failure);
            scratch_trace.deinit();
        }
        return @call(.auto, body, .{self} ++ args);
    }

    fn forceAncillary(self: *DebugSession, v: Value) !Value {
        return vm_force.forceValue(self.vm, v);
    }

    fn writeValueAncillary(self: *DebugSession, writer: *std.Io.Writer, v: Value) !void {
        var host = valuePrintHost(self.ev);
        host.context = self;
        host.force_value = debugPrintForceValue;
        return eval_print.writeValue(host, writer, v);
    }

    /// Value rendering normally forces derivation markers through the public
    /// Engine API, which clears the report trace before each operation. A debug
    /// rendering is already inside `runAncillary`; use the untraced entry so
    /// those nested forces stay on its private trace as well.
    fn debugPrintForceValue(context: *anyopaque, value: Value) anyerror!Value {
        const self: *DebugSession = @ptrCast(@alignCast(context));
        return self.ev.forceValueUntraced(value);
    }

    fn evalAncillary(self: *DebugSession, source: []const u8, scope: ?Value) !Value {
        return self.ev.debugEvalScoped(self.vm, source, scope);
    }

    fn retain(self: *DebugSession, value: Value) Value {
        vm_force.rootKeepAcrossArming(self.vm, value);
        return value;
    }

    /// Set a source-line breakpoint at `file:line`. Resolves to the nearest
    /// line carrying code, or remains pending until the file is compiled.
    /// Applies to already compiled chunks and any that compile later.
    pub fn setBreakpoint(self: *DebugSession, file: []const u8, line: u32) !bytecode.BreakpointTable.SetResult {
        return self.ev.setBreakpoint(file, line);
    }

    /// All active breakpoint requests (for a `:breakpoints` listing).
    pub fn listBreakpoints(self: *const DebugSession) []const bytecode.BreakpointTable.Request {
        return self.ev.listBreakpoints();
    }

    /// Remove a breakpoint by id; true if it existed.
    pub fn deleteBreakpoint(self: *DebugSession, id: u32) bool {
        return self.ev.deleteBreakpoint(id);
    }

    /// Per-instruction breakpoint toggling at an exact `(chunk_id, offset)`.
    pub fn setBreakpointAt(self: *DebugSession, chunk_id: types.ChunkId, offset: u32) !bytecode.BreakpointTable.SetResult {
        return self.ev.setBreakpointAt(chunk_id, offset);
    }

    pub fn deleteBreakpointAt(self: *DebugSession, chunk_id: types.ChunkId, offset: u32) bool {
        return self.ev.deleteBreakpointAt(chunk_id, offset);
    }

    pub fn breakpointAt(self: *const DebugSession, chunk_id: types.ChunkId, offset: u32) bool {
        return self.ev.breakpointAt(chunk_id, offset);
    }

    pub fn setBreakpointSpan(
        self: *DebugSession,
        chunk_id: types.ChunkId,
        span: bytecode.Chunk.SourceSpan,
    ) !bytecode.BreakpointTable.SetResult {
        return self.ev.setBreakpointSpan(chunk_id, span);
    }

    pub fn deleteBreakpointSpan(self: *DebugSession, chunk_id: types.ChunkId, span: bytecode.Chunk.SourceSpan) bool {
        return self.ev.deleteBreakpointSpan(chunk_id, span);
    }

    pub fn breakpointSpan(self: *const DebugSession, chunk_id: types.ChunkId, span: bytecode.Chunk.SourceSpan) bool {
        return self.ev.breakpointSpan(chunk_id, span);
    }

    pub const StepKind = debug_session.StepKind;

    /// Arm a single step. It takes effect once the console resumes; the next
    /// pause is the step's landing point. See `clearStep`.
    pub fn step(self: *DebugSession, kind: StepKind) !void {
        if (kind == .into and !self.vm.debug.import_replay) {
            // `import` is memoized across REPL inputs. Continuing/finishing a
            // debug expression may use that fast path, but step-into promises
            // executable imported code. Give this paused VM chain a fresh,
            // separately rooted memo table so old helpers using the ordinary
            // table remain untouched.
            self.ev.sources.imports.beginReplayQuiescent(self.ev.allocator);
            var cursor: ?*VM = self.vm;
            while (cursor) |vm| : (cursor = vm.debug.parent) vm.debug.import_replay = true;
        }
        return debug_session.step(debugContext(self), kind);
    }

    /// Disarm any in-progress step (called at each pause before prompting).
    pub fn clearStep(self: *DebugSession) void {
        if (self.ev.debugger.breakpoints) |*bp| bp.clearStep(&self.ev.registry);
    }

    /// Run a full collection at the paused evaluator safepoint. Unlike the
    /// REPL's between-input `collectMajorNow`, this keeps live evaluator caches
    /// and scans the paused VM, including this session's retained UI values.
    pub fn collectGarbage(self: *DebugSession) Engine.CollectNowResult {
        return self.ev.collectMajorAtSafepoint(self.vm.workerId());
    }

    /// Build a one-entry scope attrset binding `name` to `self.value` — handy
    /// for the console to expose the break value as an identifier.
    pub fn bindValueScope(self: *DebugSession, name: []const u8) !Value {
        const entries = [_]runtime.heap.AttrEntry{.{
            .name = try self.ev.intern.intern(name),
            .value = self.value,
        }};
        return self.retain(Value.attrs(try self.ev.heap.addAttrs(&entries)));
    }

    /// The lexical scope at the pause: an ambient attrset of the current frame's
    /// named locals and upvalues (locals shadow upvalues), plus `it` = the break
    /// value. Console expressions compile against this, so `let`/`param`
    /// bindings visible at the breakpoint resolve as free identifiers. Requires
    /// recorded names (`--debugger` turns capture on); with no frame or no names
    /// it degrades to just `it`.
    pub fn scopeAttrs(self: *DebugSession) !Value {
        return self.retain(try debug_session.scopeAttrs(debugContext(self)));
    }
};

const StoreState = store_state.StoreState;
pub const BuildSession = build_session.BuildSession;

const ExecutionState = struct {
    scheduler: Scheduler,
    vm_buffers: vm_mod.BufferPool,
    worker_count: u8,
    main_worker: ?*worker_mod.Worker = null,
};

const PrefetchState = struct {
    seen: std.AutoHashMapUnmanaged(types.InternId, void) = .empty,
    mu: SpinMutex = .{},
    budget: u32 = 0,
    /// Interned paths from the chunk-cache import manifest, drained one per
    /// completed import-prefetch task (`manifestNext`); `manifest_cursor`
    /// marks the next entry to hand out.
    manifest: std.ArrayListUnmanaged(types.InternId) = .empty,
    manifest_cursor: usize = 0,
    /// Manifest identity for this run, claimed by the first file-backed
    /// compile (`maybePreloadImportManifest`); null until then, and forever
    /// for expression-only evals — they neither preload nor write manifests.
    manifest_name: ?[33]u8 = null,
};

const SourceState = struct {
    files: FileCache,
    fetchers: FetchService,
    imports: imports_mod.Registry = .{},
    search_paths: search_path_mod.Paths = .{},
    base_path: ?[:0]u8 = null,
    env_map: ?*const std.process.Environ.Map = null,
    prefetch: PrefetchState = .{},
};

const CompilationState = struct {
    deferred_table: deferred_mod.Table,
    /// Per-Engine rewrite census. Compilers receive an explicit pointer when
    /// the immutable tuning policy is resolved; no process-global state is
    /// shared by sequential or concurrent Engines.
    let_float_stats: compiler_mod.let_float.Stats = .{},
    retained_arenas: std.ArrayListUnmanaged(ast_mod.AstArena) = .empty,
    retained_arenas_mu: SpinMutex = .{},
    /// Caller's cache placement from `Config.compile_cache`
    /// (`--no-compile-cache` / `--compile-cache-dir` on the CLI).
    cache_config: CompileCacheConfig = .auto,
    /// Persistent chunk-cache configuration, resolved once at
    /// `prepareEvaluations` (null = disabled: no cache dir resolvable,
    /// `cache_config == .off`, or a debugger/name-capture session).
    chunk_cache: ?chunk_cache_store.Store = null,
    cache_hits: std.atomic.Value(u64) = .init(0),
    cache_misses: std.atomic.Value(u64) = .init(0),
    cache_writes: std.atomic.Value(u64) = .init(0),
    cache_rejects: std.atomic.Value(u64) = .init(0),
};

const CollectionState = struct {
    tracer: gc.Tracer,
    import_vms: std.ArrayListUnmanaged(*VM) = .empty,
    import_vms_mu: SpinMutex = .{},
    workers: []std.atomic.Value(?*worker_mod.Worker),
    chunks_scanned: ChunkId = 0,
    budget_bytes: ?u64 = null,
    mem_report_mode: ?[]const u8 = null,
    report_on: bool = false,
    parallel_cap: u32 = gc_controller.default_parallel_cap,
    coordinator: gc_coordinator.Coordinator = .{},
    extra_roots: std.ArrayListUnmanaged(Value) = .empty,
    /// Serializes `extra_roots` appends from concurrently-completing
    /// top-level fibers. `markRoots` reads without it: collections are
    /// stop-the-world, so no appender can be running then.
    extra_roots_mu: SpinMutex = .{},
};

fn debugContext(session: *const DebugSession) debug_session.Context {
    return .{
        .allocator = session.ev.allocator,
        .heap = &session.ev.heap,
        .intern = &session.ev.intern,
        .registry = &session.ev.registry,
        .files = &session.ev.sources.files,
        .breakpoints = if (session.ev.debugger.breakpoints) |*bp| bp else null,
        .source = session.ev.debugger.source,
        .vm = session.vm,
        .value = session.value,
    };
}

/// Placement of the persistent compiled-chunk cache: the default root
/// (`$XDG_CACHE_HOME/fix/chunks`, else `~/.cache/fix/chunks`), a
/// caller-chosen root, or fully disabled.
pub const CompileCacheConfig = union(enum) {
    auto,
    off,
    /// Borrowed (argv lifetime); duplicated when the cache store resolves.
    dir: []const u8,
};

/// Borrowed construction policy for the expression engine.
///
/// Keeping initialization inputs in one value makes setup transactional and
/// lets composition layers resolve policy before allocating long-lived state.
pub const Config = struct {
    worker_count: u8 = 1,
    io: ?std.Io = null,
    environment: ?*const std.process.Environ.Map = null,
    fetch: FetchService.Config = .{},
    memory_backing: ?*hugetlb.Policy = null,
    compile_cache: CompileCacheConfig = .auto,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    intern: InternTable,
    registry: ChunkRegistry,
    heap: ObjectHeap,
    execution: ExecutionState,
    sources: SourceState,
    /// Store and daemon state that deliberately outlives language teardown.
    store: StoreState,
    /// Compiled-regex cache shared by every VM (`builtins.match`/`split`).
    regexes: regex_mod.PatternCache,
    builtins_value: ?Value,
    /// Whether the final render observes lazy shells (only lazy-XML).
    /// Propagated to every VM via `initVm`; gates `thunk_shell`.
    /// Default false — the CLI sets it true only for `--xml`.
    lazy_shells_visible: bool = false,
    /// Feature gates and deprecated compatibility behavior shared unchanged by
    /// parsing, every nested compiler, and every VM.
    policy: LanguagePolicy = .{},
    /// Immutable performance policy, resolved at the first compile/evaluate
    /// operation after callers have configured this Engine's environment and
    /// scheduler. It is fixed before any worker starts.
    tuning_policy: ?tuning.Policy = null,
    /// Owns the backing strings for `policy.allowed_path_roots` (the flake
    /// source tree(s) readable under pure eval). Set via `setPureEval`.
    pure_eval_roots: [][]u8 = &.{},
    debugger: DebuggerState = .{},
    /// Colorize `writeValue` output (strings/numbers/keywords/attr names). Set
    /// by the CLI from its terminal-color decision; default off (plain text for
    /// pipes, tests, JSON/XML paths). See `eval/print.zig`.
    value_color: bool = false,
    observer: observ.Observer = .{},
    effects: effects_mod.Store,
    vm_trace: ?*VmTrace,
    thunk_trace: if (vm_mod.thunks_log_enabled) ?*ThunkTrace else void,
    trace_verbose: bool = false,
    /// Per-evaluation state (diagnostics + trace + string arena). Cleared
    /// at the start of each `evaluate()`; helpers writing diagnostics from
    /// import error paths serialize on `report.mu`.
    report: EvaluationReport,
    /// Lazy per-attr compilation: deferred attrset value bodies, compiled
    /// on first force. See `compiler/deferred_table.zig`.
    compilation: CompilationState,
    collection: CollectionState,
    /// Evaluation has one terminal transition. Store-side build sessions may
    /// outlive it, but no language operation is valid after `.finished`.
    evaluation_phase: enum { active, releasing, finished } = .active,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Engine {
        // Always run at least one worker — the main evaluator thread itself
        // owns worker id 0 even when no scheduler helpers are requested.
        const worker_count: u8 = @max(config.worker_count, 1);

        var scheduler = try Scheduler.init(allocator, worker_count);
        errdefer scheduler.deinit();

        var intern = try InternTable.init(allocator);
        errdefer intern.deinit();

        var registry = try ChunkRegistry.init(allocator);
        errdefer registry.deinit();

        // Single-worker mode: the evaluator owns these tables and no helper
        // thread will ever exist, so their internal locking (intern shard
        // mutexes, chunk-dedup shard mutexes, the registration CAS) is pure
        // tax — mark them solo before anything runs. See InternTable.solo /
        // ChunkRegistry.solo for the contract.
        if (worker_count == 1) {
            intern.solo = true;
            registry.solo = true;
        }

        const gc_workers = try allocator.alloc(std.atomic.Value(?*worker_mod.Worker), worker_count);
        for (gc_workers) |*w| w.* = .init(null);
        errdefer allocator.free(gc_workers);

        var store = try StoreState.init(allocator);
        errdefer store.deinit();

        var heap = try ObjectHeap.initWithMemoryPolicy(allocator, worker_count, config.memory_backing);
        errdefer heap.deinit();

        var fetch_config = config.fetch;
        if (fetch_config.io == null) fetch_config.io = config.io;
        if (fetch_config.environment == null) fetch_config.environment = config.environment;
        var fetch_service = try FetchService.init(allocator, fetch_config);
        errdefer fetch_service.deinit();

        var ev: Engine = .{
            .allocator = allocator,
            .intern = intern,
            .registry = registry,
            .heap = heap,
            .execution = .{
                .scheduler = scheduler,
                .vm_buffers = vm_mod.BufferPool.init(allocator),
                .worker_count = worker_count,
            },
            .sources = .{
                .files = FileCache.init(allocator),
                .fetchers = fetch_service,
            },
            .store = store,
            .regexes = regex_mod.PatternCache.init(allocator),
            .builtins_value = null,
            .observer = .{},
            .effects = effects_mod.Store.init(allocator),
            .vm_trace = null,
            .thunk_trace = if (vm_mod.thunks_log_enabled) null else {},
            .report = EvaluationReport.init(allocator),
            .compilation = .{
                .deferred_table = deferred_mod.Table.init(allocator),
                .cache_config = config.compile_cache,
            },
            .collection = .{
                .tracer = gc.Tracer.init(allocator),
                .workers = gc_workers,
            },
        };
        if (config.io) |io| ev.setFileIo(io);
        if (config.environment) |env_map| try ev.setEnvironment(env_map);
        return ev;
    }

    /// Whether `FIX_LET_FLOAT_STATS` asked for the rewrite census at
    /// teardown — fast-exit paths keep explicit `deinit` alive for it.
    pub fn letFloatCensusEnabled(self: *const Engine) bool {
        return if (self.tuning_policy) |policy| policy.let_float_report else false;
    }

    /// Engine-owned let-rewrite statistics for tooling reports.
    pub fn letFloatStats(self: *const Engine) *const compiler_mod.let_float.Stats {
        return &self.compilation.let_float_stats;
    }

    /// Freeze every environment-driven performance choice into one Engine-
    /// owned value. This is the single entrance for compile-only and evaluate
    /// paths, so deferred compilation, cache identity, workers, and VMs all
    /// observe exactly the same policy.
    fn ensureTuningPolicy(self: *Engine) *const tuning.Policy {
        if (self.tuning_policy == null) {
            self.tuning_policy = tuning.resolve(
                self.execution.scheduler.configuration(),
                self.sources.env_map,
                self.execution.worker_count,
            );
            const policy = &self.tuning_policy.?;
            self.compilation.deferred_table.let_float = .{
                .enabled = policy.let_float_enabled,
                .full_lazy = policy.full_lazy_enabled,
                .mfe_min_applies = policy.mfe_min_applies,
                .named_floats = policy.named_floats_enabled,
                .chain_split = policy.chain_split,
                .stats = &self.compilation.let_float_stats,
            };
        }
        return &self.tuning_policy.?;
    }

    pub fn deinit(self: *Engine) void {
        // Join every compiler/cache producer before closing the writer or
        // freeing registry/intern/heap state that inline serialization reads.
        self.releaseEvaluationResources();
        // Publish queued cache writes before the census reads the `writes`
        // counter and before the cache dir path is freed.
        self.flushChunkCacheWrites();
        // Rewrite census (`FIX_LET_FLOAT_STATS=1`) — Engine-owned counters,
        // reported once at teardown, entirely off the evaluation path.
        if (self.letFloatCensusEnabled()) {
            var buf: [4096]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            compiler_mod.let_float.writeReport(&w, &self.compilation.let_float_stats) catch {};
            std.debug.print("let-float census:\n{s}", .{buf[0..w.end]});
            std.debug.print(
                "chunk-cache census:\n  hits: {d}\n  misses: {d}\n  writes: {d}\n  rejects: {d}\n",
                .{
                    self.compilation.cache_hits.load(.monotonic),
                    self.compilation.cache_misses.load(.monotonic),
                    self.compilation.cache_writes.load(.monotonic),
                    self.compilation.cache_rejects.load(.monotonic),
                },
            );
        }
        if (self.compilation.chunk_cache) |*cc| {
            cc.deinit();
        }
        self.debugger.deinit();
        owned_strings.free(self.allocator, self.pure_eval_roots);
        if (self.sources.base_path) |path| self.allocator.free(path);
        // Language workers are joined by releaseEvaluationResources, so no fiber remains
        // parked on the store's fast IO lane when it is shut down here.
        self.store.deinit();
    }

    /// Finish language evaluation and free its resources — workers and
    /// their fiber stacks, the object heap (flat store + segment stores),
    /// file/fetch caches, retained AST, bytecode registry, and the intern
    /// table — while keeping the store half (daemon connection + IO thread,
    /// progress session) alive. This is a terminal transition: callers may
    /// continue store work, but must not call another language operation.
    ///
    /// `deinit` performs the same cleanup when evaluation is still active.
    pub fn finishEvaluation(self: *Engine) void {
        lifecycle.finish(self);
    }

    fn requireActiveEvaluation(self: *const Engine) !void {
        return lifecycle.requireActive(self);
    }

    /// Idempotent only so whole-Engine destruction can share the teardown
    /// path with the explicit terminal transition.
    fn releaseEvaluationResources(self: *Engine) void {
        lifecycle.releaseIfActive(self);
    }

    /// Allocator for app-layer values whose ownership is explicitly returned
    /// to the evaluator (source descriptors, diagnostics, debug records).
    pub fn hostAllocator(self: *const Engine) std.mem.Allocator {
        return self.allocator;
    }

    pub fn basePath(self: *const Engine) ?[]const u8 {
        return self.sources.base_path;
    }

    /// The value of `builtins.currentSystem` (e.g. "x86_64-linux"). The CLI
    /// bakes this into flake installable lowering so the lowered expression
    /// doesn't depend on `builtins.currentSystem` (which pure eval forbids).
    pub fn systemName(self: *const Engine) []const u8 {
        _ = self;
        return runtime.builtins.hostSystemName();
    }

    pub fn configureLanguage(self: *Engine, policy: LanguagePolicy) void {
        self.policy = policy;
    }

    /// Enable/disable pure evaluation (see `LanguagePolicy.pure_eval`). Each
    /// call replaces the allowed-path roots; `roots` (the flake source tree(s)
    /// readable besides the store) are copied into evaluator-owned storage.
    pub fn setPureEval(self: *Engine, pure: bool, roots: []const []const u8) !void {
        const replacement = try owned_strings.clone(self.allocator, roots);
        owned_strings.free(self.allocator, self.pure_eval_roots);
        self.pure_eval_roots = replacement;
        self.policy.pure_eval = pure;
        self.policy.allowed_path_roots = self.pure_eval_roots;
    }

    pub fn languagePolicy(self: *const Engine) LanguagePolicy {
        return self.policy;
    }

    pub fn configureMemory(self: *Engine, gc_budget: ?u64, report_mode: ?[]const u8, gc_report: bool) void {
        self.collection.budget_bytes = gc_budget;
        self.collection.mem_report_mode = report_mode;
        self.collection.report_on = gc_report;
    }

    pub fn setLazyShellsVisible(self: *Engine, visible: bool) void {
        self.lazy_shells_visible = visible;
    }

    pub fn setTraceFlows(self: *Engine, enabled: bool) void {
        self.execution.scheduler.setTraceFlows(enabled);
    }

    pub fn addIndirectRoot(self: *Engine, link_path: []const u8, target: []const u8) !void {
        return self.store.addIndirectRoot(link_path, target);
    }

    pub fn getDiagnostics(self: *const Engine) []const Diagnostic {
        return self.report.diagnosticsView();
    }

    /// Render recorded parser/compiler diagnostics without exposing the syntax
    /// subsystem through the application facade.
    pub fn writeDiagnostics(self: *const Engine, writer: *std.Io.Writer, source: []const u8, use_color: bool) !void {
        try diagnostic.writeAllWithOptions(writer, source, self.getDiagnostics(), .{ .color = use_color });
    }

    /// Render one source-backed evaluation trace frame. Parser/compiler
    /// diagnostics keep their compact `near` excerpt; a trace already shows
    /// the source line and should not repeat it.
    pub fn writeTraceDiagnostic(
        _: *const Engine,
        writer: *std.Io.Writer,
        source: []const u8,
        item: Diagnostic,
        use_color: bool,
    ) !void {
        try diagnostic.writeAllWithOptions(writer, source, &.{item}, .{
            .color = use_color,
            .show_near = false,
        });
    }

    pub fn getTrace(self: *const Engine) *const EvalTrace {
        return self.report.traceView();
    }

    pub fn setDerivationDebug(self: *Engine, enabled: bool) void {
        self.store.realization.setDebugEnabled(enabled);
    }

    /// Cap concurrent fetches (`http-connections`; 0 = unlimited).
    pub fn setFetchConnections(self: *Engine, n: u32) !void {
        try self.sources.fetchers.setMaxConnections(n);
    }

    /// `download-attempts`: total tries per download before failing.
    pub fn setDownloadAttempts(self: *Engine, n: u32) void {
        self.sources.fetchers.setDownloadAttempts(n);
    }

    pub fn setTarballTtl(self: *Engine, seconds: u32) void {
        self.sources.fetchers.setTarballTtl(seconds);
    }

    pub fn setFetchConnectTimeout(self: *Engine, seconds: u32) void {
        self.sources.fetchers.setConnectTimeout(seconds);
    }

    pub fn setStalledDownloadTimeout(self: *Engine, seconds: u32) void {
        self.sources.fetchers.setStalledDownloadTimeout(seconds);
    }

    pub fn setDownloadSpeed(self: *Engine, kib_per_second: u64) void {
        self.sources.fetchers.setDownloadSpeed(kib_per_second);
    }

    pub fn setSslCertFile(self: *Engine, path: []const u8) !void {
        try self.sources.fetchers.setSslCertFile(path);
    }

    pub fn setFlakeRegistryUrl(self: *Engine, url: ?[]const u8) !void {
        try self.sources.fetchers.setFlakeRegistryUrl(url);
    }

    /// Set the fetcher's `access-tokens` (a raw `nix.conf` value), used to
    /// authenticate downloads to matching hosts. See `setup.configure`.
    pub fn setAccessTokens(self: *Engine, raw: []const u8) !void {
        try self.sources.fetchers.setAccessTokens(raw);
    }

    /// Set the fetcher's `netrc` credentials (raw file content) for HTTP
    /// basic-auth on plain downloads. See `setup.configure`.
    pub fn setNetrc(self: *Engine, content: []const u8) !void {
        try self.sources.fetchers.setNetrc(content);
    }

    pub fn derivationDebugRecords(self: *const Engine) []const derivation.DebugRecord {
        return self.store.realization.debugRecords();
    }

    pub fn setBasePathFromCurrentPath(self: *Engine, io: std.Io) !void {
        const replacement = try std.process.currentPathAlloc(io, self.allocator);
        self.sources.files.setIo(io);
        self.sources.fetchers.setIo(io);
        self.store.realization.setIo(io);
        if (self.sources.base_path) |path| self.allocator.free(path);
        self.sources.base_path = replacement;
    }

    pub fn setFileIo(self: *Engine, io: std.Io) void {
        self.sources.files.setIo(io);
        self.sources.fetchers.setIo(io);
        self.store.realization.setIo(io);
    }

    /// Point the base path (used to resolve relative path literals like `./x`)
    /// at the directory containing `file_path`, resolved against the current
    /// base path. This makes a file's relative paths resolve relative to the
    /// file, as Nix does — not the process cwd.
    pub fn setBasePathToFileDir(self: *Engine, file_path: []const u8) !void {
        const base = self.sources.base_path orelse ".";
        const abs = try std.fs.path.resolve(self.allocator, &.{ base, file_path });
        defer self.allocator.free(abs);
        const dir = std.fs.path.dirname(abs) orelse abs;
        const owned = try self.allocator.dupeZ(u8, dir);
        if (self.sources.base_path) |old| self.allocator.free(old);
        self.sources.base_path = owned;
    }

    pub fn setEnvironment(self: *Engine, env_map: *const std.process.Environ.Map) !void {
        try self.sources.fetchers.setEnvironment(env_map);
        self.sources.env_map = env_map;
        // Point the fetch download-cache at `$XDG_CACHE_HOME/fix` (default
        // `~/.cache/fix`), mirroring Nix's `~/.cache/nix`. Best-effort; without
        // HOME/XDG the FetchCache keeps its `./.zig-cache/fix` fallback.
        self.setFetchCacheRoot() catch {};
    }

    pub fn environment(self: *const Engine) ?*const std.process.Environ.Map {
        return self.sources.env_map;
    }

    fn setFetchCacheRoot(self: *Engine) !void {
        const env = self.sources.env_map orelse return;
        const base: []const u8, const sub: []const []const u8 = blk: {
            if (env.get("XDG_CACHE_HOME")) |xdg| {
                if (xdg.len != 0) break :blk .{ xdg, &.{"fix"} };
            }
            if (env.get("HOME")) |home| {
                if (home.len != 0) break :blk .{ home, &.{ ".cache", "fix" } };
            }
            return;
        };
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        defer parts.deinit(self.allocator);
        try parts.append(self.allocator, base);
        try parts.appendSlice(self.allocator, sub);
        const root = try std.fs.path.join(self.allocator, parts.items);
        defer self.allocator.free(root);
        try self.sources.fetchers.setCacheRoot(root);
    }

    pub fn setVmTrace(self: *Engine, vm_trace: ?*VmTrace) void {
        self.vm_trace = vm_trace;
    }

    pub fn setThunkTrace(self: *Engine, thunk_trace: ?*ThunkTrace) void {
        // No-op when the trace is compiled out; callers don't need to
        // comptime-gate. `--thunks-log` users get a heads-up at the CLI
        // layer.
        if (comptime !vm_mod.thunks_log_enabled) return;
        self.thunk_trace = thunk_trace;
    }

    /// Construct a thunk trace bound to this evaluator's runtime state without
    /// exporting mutable heap/registry pointers to the CLI composition layer.
    pub fn initThunkTrace(self: *Engine, writer: *std.Io.Writer) ThunkTrace {
        return ThunkTrace.init(writer, &self.intern, &self.heap, &self.registry);
    }

    pub fn setObserver(self: *Engine, observer: observ.Observer) void {
        self.observer = observer;
        self.store.realization.setObserver(observer);
    }

    /// Install a language-effect sink. The callback can run concurrently from
    /// independent demanded fibers and is responsible for synchronizing its
    /// destination. Primarily useful to embedding applications and tests.
    pub fn setEffectSink(self: *Engine, sink: effects_mod.Sink) void {
        self.effects.setSink(sink);
    }

    pub fn setTraceVerbose(self: *Engine, enabled: bool) void {
        self.trace_verbose = enabled;
    }

    pub fn setNixPath(self: *Engine, nix_path: []const u8) !void {
        try self.sources.search_paths.set(self.allocator, nix_path, self, resolveHostPath);
        for (self.sources.search_paths.entries) |*entry| {
            if (!std.mem.startsWith(u8, entry.path, "http://") and !std.mem.startsWith(u8, entry.path, "https://") and !std.mem.startsWith(u8, entry.path, "file://")) continue;
            const result = try self.fetchTarball(entry.path);
            self.allocator.free(entry.path);
            entry.path = result.path;
            if (result.nar_payload) |payload| self.allocator.free(payload.bytes);
        }
    }

    pub fn readSourceFile(self: *Engine, path: []const u8) ![]const u8 {
        var resolved = try self.resolveHostPath(path);
        defer resolved.deinit(self.allocator);
        return self.sources.files.readFile(resolved.slice());
    }

    /// Resolve `<name>` through NIX_PATH. The caller owns the returned path
    /// with `allocator`, making its lifetime independent of the engine.
    pub fn resolveLookupPath(self: *Engine, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return self.sources.search_paths.resolveName(allocator, &self.sources.files, name);
    }

    /// Fetch and unpack a legacy fileish tarball. The caller owns the returned
    /// cache path with `allocator`; all fetch-service temporaries stay owned by
    /// the engine.
    pub fn fetchTarballPath(self: *Engine, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
        const result = try self.fetchTarball(url);
        defer result.deinit(self.allocator);
        return allocator.dupe(u8, result.path);
    }

    fn fetchTarball(self: *Engine, url: []const u8) !@import("fetchers").FetchService.TarballResult {
        var span = self.observer.begin(&fetch_observation, .{ .subject = .{ .url = url } });
        defer span.cancel();
        const result = try self.sources.fetchers.fetchTarball(
            &self.sources.files,
            .{ .url = url, .name = "source" },
            null,
        );
        span.finish(.{ .verb = if (result.cached) "cached" else null });
        return result;
    }

    pub fn isSourceDirectory(self: *Engine, path: []const u8) !bool {
        var resolved = try self.resolveHostPath(path);
        defer resolved.deinit(self.allocator);
        return self.sources.files.isDirectoryFollowing(resolved.slice());
    }

    /// Fetch a flake source without evaluating its outputs. `parseFlakeRef`
    /// performs registry resolution, `fetchTree` materializes the source, and
    /// `dir` selects a nested flake before legacy fileish default.nix loading.
    pub fn fetchFlakeSourcePath(self: *Engine, ref: []const u8) ![]u8 {
        if (!self.policy.flakes_enabled) return error.FlakesFeatureRequired;
        var escaped: std.ArrayListUnmanaged(u8) = .empty;
        defer escaped.deinit(self.allocator);
        for (ref) |c| {
            if (c == '\\' or c == '"' or c == '$') try escaped.append(self.allocator, '\\');
            try escaped.append(self.allocator, c);
        }
        const source = try std.fmt.allocPrint(
            self.allocator,
            "let r = builtins.parseFlakeRef \"{s}\"; t = builtins.fetchTree r; in t.outPath + (if r ? dir then \"/\" + r.dir else \"\")",
            .{escaped.items},
        );
        defer self.allocator.free(source);
        const value = try self.forceValue(try self.evaluate(source));
        if (!value.isPath() and !value.isString()) return error.TypeError;
        return self.allocator.dupe(u8, self.intern.get(value.asInternId()));
    }

    fn clearDiagnostics(self: *Engine) void {
        self.report.clear();
    }

    fn copyDiagnostics(self: *Engine, diagnostics: []const Diagnostic, source: []const u8, source_path: ?[]const u8) !void {
        try self.report.replaceDiagnostics(diagnostics, source, source_path);
    }

    fn appendDiagnostics(self: *Engine, diagnostics: []const Diagnostic, source: []const u8, source_path: ?[]const u8) !void {
        try self.report.appendDiagnostics(diagnostics, source, source_path);
    }

    /// Parse and compile source text into a registered chunk id. Used by
    /// debugging tools that want to inspect bytecode without running it.
    pub fn compileSource(
        self: *Engine,
        source: []const u8,
        source_path: ?[]const u8,
    ) !ChunkId {
        return self.parseAndCompile(source, self.sources.base_path, source_path, null);
    }

    pub fn compileSourceAt(self: *Engine, source: []const u8, base_path: ?[]const u8, source_path: ?[]const u8) !ChunkId {
        return self.parseAndCompile(source, base_path, source_path, null);
    }

    /// `compileSource` with an ambient scope attrset (see
    /// `evaluateWithScope`). The repl's VM explorer compiles expressions that
    /// reference repl bindings through this.
    pub fn compileSourceScoped(self: *Engine, source: []const u8, scope: ?Value) !ChunkId {
        return self.parseAndCompile(source, self.sources.base_path, null, scope);
    }

    /// Parse + compile + register, returning the compiled chunk id.
    /// Shared by `compileSource` (public, no eval) and `evaluateSource`
    /// (the internal eval entrypoint that runs the chunk afterwards).
    fn parseAndCompile(
        self: *Engine,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
    ) !ChunkId {
        try self.requireActiveEvaluation();
        _ = self.ensureTuningPolicy();
        // The run's first file-backed unit names the workload: replay its
        // import manifest through the prefetch lane (no-op once claimed).
        if (source_path) |entry_path| {
            if (self.sources.prefetch.manifest_name == null)
                self.maybePreloadImportManifest(entry_path);
        }
        // Persistent chunk cache: an unchanged unit (same source bytes, path,
        // binary, policy, codegen flags) skips parse+compile entirely. Debug
        // and name-capture sessions bypass in both directions (see
        // `chunkCacheKey`); every failure mode falls back to compiling.
        const cache_key = self.chunkCacheKey(source, source_path, scope);
        if (cache_key) |key| {
            if (self.tryLoadCachedUnit(key, source, base_path, source_path)) |top| return top;
        }
        var parsed = try self.parseSourceUnit(source, source_path);
        var retain_arena = false;
        defer if (!retain_arena) parsed.arena.deinit();

        return self.compileParsedUnit(
            &parsed,
            source,
            base_path,
            source_path,
            scope,
            cache_key,
            &retain_arena,
        );
    }

    const ParsedSource = struct {
        arena: ast_mod.AstArena,
        root: *ast_mod.Node,
    };

    /// Parse and policy-check one source unit. The returned arena owns `root`
    /// and is either released by the caller or transferred to deferred
    /// compilation storage.
    fn parseSourceUnit(self: *Engine, source: []const u8, source_path: ?[]const u8) !ParsedSource {
        const subject = source_path orelse "expression";

        var arena = ast_mod.AstArena.init(self.allocator);
        errdefer arena.deinit();

        var parser = parser_mod.Parser.init(self.allocator, &arena, source);
        defer parser.deinit();
        // Body-span elision: skip PARSING large attrset value bodies that
        // lazy per-attr compilation would defer anyway; the compiler
        // sub-parses them on demand (`literals.materializeElided`). File
        // compiles only, mirroring the deferral gate (`shouldDeferSet`).
        parser.elide_bodies = source_path != null;

        const ast_node = blk: {
            var observation = self.observer.begin(&parse_observation, observationDetails(subject));
            defer observation.cancel();
            const pt = prof.start(.parse);
            defer prof.end(.parse, pt);
            // RSS attribution: blocks the parse grows (AST arena chunks,
            // parser scratch) belong to the "ast-arena" bucket — the
            // retained ones live as long as the evaluator.
            const prev_tag = vma_mod.setAllocTag(.ast_arena);
            defer _ = vma_mod.setAllocTag(prev_tag);
            const parsed = parser.parse() catch {
                try self.copyDiagnostics(parser.diagnostics.items, source, source_path);
                return error.ParseError;
            };
            observation.finish(.{ .metrics = &.{.{
                .name = "source",
                .value = .{ .unsigned = source.len },
                .unit = .bytes,
            }} });
            break :blk parsed;
        };

        try self.validateParserPolicy(&parser, source, source_path);
        return .{ .arena = arena, .root = ast_node };
    }

    /// Compile and register an already validated source unit. All compiler
    /// scratch is region-owned and dies here; only bytecode and, when needed,
    /// the parsed AST arena cross the boundary.
    fn compileParsedUnit(
        self: *Engine,
        parsed: *ParsedSource,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
        cache_key: ?chunk_cache.Key,
        retain_arena: *bool,
    ) !ChunkId {
        const subject = source_path orelse "expression";
        // Per-compilation-unit scratch arena: all of the compiler's
        // transient structures (builder buffers, locals/captures, strictness
        // and name-resolution maps, diagnostics) allocate here and are freed
        // wholesale when this returns. Only the emitted chunk is duped onto
        // the long-lived allocator (at `builder.finish`). The AST arena above
        // is separate — it may be retained for deferred bodies; this one never
        // is, since nothing persistent points into it.
        var scratch = @import("base").arena.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const scratch_alloc = scratch.allocator();

        var builder = try ChunkBuilder.init(scratch_alloc);
        defer builder.deinit(scratch_alloc);

        var compiler = compiler_mod.Compiler.init(
            &compiler_mod.driver,
            scratch_alloc,
            self.allocator,
            &builder,
            &self.registry,
            source,
            &self.intern,
            &self.heap,
        );
        compiler.base_path = base_path;
        compiler.source_path = source_path;
        compiler.home_dir = if (self.sources.env_map) |env| env.get("HOME") else null;
        compiler.policy = self.policy;
        const compile_tuning = self.ensureTuningPolicy();
        compiler.let_float = .{
            .enabled = compile_tuning.let_float_enabled,
            .full_lazy = compile_tuning.full_lazy_enabled,
            .mfe_min_applies = compile_tuning.mfe_min_applies,
            .named_floats = compile_tuning.named_floats_enabled,
            .chain_split = compile_tuning.chain_split,
            .stats = &self.compilation.let_float_stats,
        };
        compiler.registration_sink = chunkRegistrationSink(self);
        // Set eagerly (not lazily on first position record, see sourceFileId):
        // chunks registered before any position record would otherwise miss
        // their file in the disasm sidecar.
        if (self.registry.capture_names) {
            if (source_path) |p| compiler.source_file_id = try self.intern.intern(p);
        }
        // A scoped import (`builtins.scopedImport`) supplies BOTH an ambient
        // scope and a source path; that attrset replaces the base env, so free
        // identifiers — even ones that name builtins — must bind to it first. A
        // repl/debug overlay also carries a scope but no source_path, and must
        // keep builtins visible; hence the source_path conjunct.
        compiler.scoped_base = scope != null and source_path != null;
        compiler.deferred_table = &self.compilation.deferred_table;
        // Elided bodies materialize into the file's AST arena (retained
        // below alongside deferred bodies); this compile is single-threaded,
        // so in-place node replacement is safe and keeps every later
        // consumer's view identical to an eager parse.
        compiler.ast_arena = &parsed.arena;
        compiler.elide_mutable = true;
        defer compiler.deinit();

        {
            var observation = self.observer.begin(&compile_observation, observationDetails(subject));
            defer observation.cancel();
            const ct = prof.start(.compile);
            defer prof.end(.compile, ct);
            compiler.compileAndFinish(parsed.root, scope) catch |err| {
                try self.copyDiagnostics(compiler.diagnostics.items, source, source_path);
                return err;
            };
            observation.finish(.{});
        }

        const chunk = try builder.finish(self.allocator, compiler.slot_count);
        const chunk_id = try self.registerTopLevelChunk(chunk, &compiler, source_path);

        // Publish the freshly-compiled unit to the persistent cache
        // (best-effort; `cache_key` is non-null only for eligible units).
        if (cache_key) |key| self.writeCachedUnit(key, &compiler, source_path.?, chunk_id);

        // If any attr body in this file was deferred, its AST nodes are
        // referenced by `deferred_table` entries and must outlive the
        // compile — keep the arena alive for the evaluator's lifetime.
        if (compiler.deferred_count > 0) {
            retain_arena.* = true;
            self.retainDeferredArena(parsed.arena);
        }
        return chunk_id;
    }

    fn validateParserPolicy(
        self: *Engine,
        parser: *const parser_mod.Parser,
        source: []const u8,
        source_path: ?[]const u8,
    ) !void {
        // The parser records disabled syntax even inside deferred bodies, so
        // each compilation unit is validated before bytecode is emitted.
        if (parser.used_pipe_operators and !self.policy.pipe_operators_enabled) {
            const token = parser.first_pipe_token.?;
            try self.copyDiagnostics(&.{.{
                .severity = .err,
                .kind = .compile,
                .line = parser_mod.Parser.tokenLine(source, token),
                .column = diagnostic.columnForOffset(source, token.offset),
                .offset = token.offset,
                .len = token.len,
                .token_type = token.type,
                .message = "pipe operators are disabled; pass --extra-experimental-features pipe-operators to enable them",
            }}, source, source_path);
            return error.PipeOperatorsDisabled;
        }
        if (parser.first_cr_offset) |offset| {
            if (!self.policy.allow_cr_line_endings) {
                try self.copyDiagnostics(&.{.{
                    .severity = .err,
                    .kind = .compile,
                    .line = diagnostic.lineForOffset(source, offset),
                    .column = diagnostic.columnForOffset(source, offset),
                    .offset = offset,
                    .len = 1,
                    .token_type = null,
                    .message = "CR (`\\r`) and CRLF (`\\r\\n`) line endings are not supported. Please inspect the file and normalize it to use LF (`\\n`) line endings instead. Use --extra-deprecated-features cr-line-endings to silence this warning.",
                }}, source, source_path);
                return error.CrLineEndingsDisabled;
            }
            try self.appendParserWarning(
                source,
                source_path,
                offset,
                1,
                parser_mod.DeprecationWarning.message(.cr_line_endings),
            );
        }
        if (parser.first_tokens_no_ws_offset) |offset| {
            if (!self.policy.allow_tokens_no_whitespace) {
                try self.copyDiagnostics(&.{.{
                    .severity = .err,
                    .kind = .compile,
                    .line = diagnostic.lineForOffset(source, offset),
                    .column = diagnostic.columnForOffset(source, offset),
                    .offset = offset,
                    .len = 1,
                    .token_type = null,
                    .message = "whitespace between tokens is required here. Use --extra-deprecated-features tokens-no-whitespace to disable this error.",
                }}, source, source_path);
                return error.TokensNoWhitespaceDisabled;
            }
        }
        for (parser.warnings.items) |warning| {
            const silenced = switch (warning.kind) {
                .or_as_identifier => self.policy.allow_or_as_identifier,
                .floating_without_zero => self.policy.allow_floating_without_zero,
                .rec_set_dynamic_attrs => self.policy.allow_rec_set_dynamic_attrs,
                .cr_line_endings => self.policy.allow_cr_line_endings,
            };
            if (silenced) continue;
            try self.appendParserWarning(
                source,
                source_path,
                warning.offset,
                warning.len,
                parser_mod.DeprecationWarning.message(warning.kind),
            );
        }
    }

    fn appendParserWarning(
        self: *Engine,
        source: []const u8,
        source_path: ?[]const u8,
        offset: u32,
        len: u32,
        message: []const u8,
    ) !void {
        try self.appendDiagnostics(&.{.{
            .severity = .warning,
            .kind = .parse,
            .line = diagnostic.lineForOffset(source, offset),
            .column = diagnostic.columnForOffset(source, offset),
            .offset = offset,
            .len = len,
            .token_type = null,
            .message = message,
        }}, source, source_path);
    }

    fn registerTopLevelChunk(
        self: *Engine,
        chunk: bytecode.Chunk,
        compiler: *compiler_mod.Compiler,
        source_path: ?[]const u8,
    ) !ChunkId {
        const top_name: bytecode.NameId = if (source_path) |path|
            (self.registry.childName(bytecode.root_name_id, try self.intern.intern(std.fs.path.basename(path)), false) catch bytecode.root_name_id)
        else if (self.registry.capture_names)
            (self.registry.childName(bytecode.root_name_id, try self.intern.intern("(top)"), true) catch bytecode.root_name_id)
        else
            bytecode.root_name_id;
        const id = if (self.registry.dedup_compiler_chunks) blk: {
            const registered = try self.registry.registerDeduped(chunk, top_name);
            if (registered.reused) {
                var duplicate = chunk;
                duplicate.deinit(self.allocator);
            }
            break :blk registered.id;
        } else blk: {
            // A one-shot source body is almost always unique; register it
            // directly instead of hashing bytecode and all of its side tables.
            break :blk try self.registry.registerNamed(chunk, top_name);
        };
        self.chunkRegistered(id);
        if (compiler.source_file_id) |file| try self.registry.recordFile(id, file);
        if (self.registry.capture_names)
            try self.registry.recordLocalNames(id, compiler.local_names.items);
        if (source_path) |path| {
            if (self.debugger.breakpoints) |*breakpoints|
                breakpoints.resolvePendingFile(&self.registry, path);
        }
        return id;
    }

    /// Resolve the persistent chunk-cache configuration once per engine —
    /// cache directory and the identity context every unit key embeds
    /// (exe fingerprint, policy fingerprint, codegen-affecting flags).
    /// Must run AFTER the tuning policy is frozen (the key snapshots
    /// `let_float_enabled`). Failure to resolve leaves the cache disabled.
    fn resolveChunkCache(self: *Engine) void {
        if (self.compilation.chunk_cache != null) return;
        const eval_tuning = self.ensureTuningPolicy();
        if (self.compilation.cache_config == .off) return;
        const env = self.sources.env_map orelse return;
        const io = self.sources.files.io orelse return;

        const root = blk: {
            if (self.compilation.cache_config == .dir)
                break :blk self.allocator.dupe(u8, self.compilation.cache_config.dir) catch return;
            if (env.get("XDG_CACHE_HOME")) |x| {
                if (x.len != 0) break :blk std.fs.path.join(self.allocator, &.{ x, "fix", "chunks" }) catch return;
            }
            if (env.get("HOME")) |h| {
                if (h.len != 0) break :blk std.fs.path.join(self.allocator, &.{ h, ".cache", "fix", "chunks" }) catch return;
            }
            return;
        };
        defer self.allocator.free(root);

        // The running binary's identity IS the cache generation: units live
        // under `<root>/<build-id>/`, so a rebuilt compiler starts from an
        // empty directory automatically — no format-version discipline
        // required. The GNU build-id (content-derived, `-fbuild-id=sha1`)
        // survives reproducible rebuilds and nix-store copies whose mtimes
        // are epoch; platforms without one fall back to an exe-stat hash.
        var id_buf: [64]u8 = undefined;
        var fp_buf: [16]u8 = undefined;
        const fingerprint: []const u8 = chunk_cache.selfBuildId(&id_buf) orelse blk: {
            const exe = std.process.executablePathAlloc(io, self.allocator) catch return;
            defer self.allocator.free(exe);
            const exe_stat = std.Io.Dir.cwd().statFile(io, exe, .{}) catch return;
            var h = std.hash.Wyhash.init(0xB111D);
            std.hash.autoHash(&h, exe_stat.size);
            std.hash.autoHash(&h, exe_stat.mtime.nanoseconds);
            break :blk std.fmt.bufPrint(&fp_buf, "{x:0>16}", .{h.final()}) catch return;
        };

        self.compilation.chunk_cache = chunk_cache_store.Store.init(.{
            .allocator = self.allocator,
            .io = io,
            .root = root,
            .generation = fingerprint,
            .home = env.get("HOME"),
            .policy_fp = policyFingerprint(&self.policy),
            .let_float_enabled = eval_tuning.let_float_enabled,
            .full_lazy_enabled = eval_tuning.full_lazy_enabled,
            .mfe_min_applies = eval_tuning.mfe_min_applies,
            .named_floats = eval_tuning.named_floats_enabled,
            .chain_split = eval_tuning.chain_split,
        }) catch return;
    }

    /// Drain and stop the chunk-cache writer lane, blocking until every
    /// queued unit has been published. Cheap when the queue is empty (one
    /// thread join). Idempotent; safe to call before `deinit`, and REQUIRED
    /// on fast-exit paths that skip `deinit` — a process exit with queued
    /// writes would silently drop them.
    pub fn flushChunkCacheWrites(self: *Engine) void {
        const state = &(self.compilation.chunk_cache orelse return);
        state.flush();
    }

    /// First file-backed compile of the run: claim the manifest identity for
    /// `entry_path` and queue that manifest's paths (the previous run's
    /// imports) for speculative import prefetch. Cached units then decode
    /// early — while intern/chunk ids still fit their narrow cached
    /// operands, and on helper workers instead of serially on the demand
    /// path's import chains.
    ///
    /// The spec rings are small, so the backlog is not submitted here: the
    /// first `worker_count` entries seed the lane and every completed
    /// prefetch pulls one more (`manifestNext`). Best-effort: a missing or
    /// stale manifest costs nothing, and a changed file simply re-imports
    /// its current content.
    fn maybePreloadImportManifest(self: *Engine, entry_path: []const u8) void {
        const state = &(self.compilation.chunk_cache orelse return);
        {
            const prefetch = &self.sources.prefetch;
            prefetch.mu.lock();
            defer prefetch.mu.unlock();
            if (prefetch.manifest_name != null) return;
            var name_buf: [33]u8 = undefined;
            _ = chunk_cache_store.Store.manifestName(entry_path, &name_buf);
            prefetch.manifest_name = name_buf;
        }
        const name = self.sources.prefetch.manifest_name.?;
        const bytes = state.readManifestAlloc(self.allocator, &name, .limited(8 * 1024 * 1024)) catch return;
        defer self.allocator.free(bytes);
        // Filled locally (file IO and interning stay outside the lock), then
        // published in one guarded splice: concurrent prefetch completions
        // already consult `manifestNextId`.
        var pending: std.ArrayListUnmanaged(types.InternId) = .empty;
        defer pending.deinit(self.allocator);
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (!std.fs.path.isAbsolute(line)) continue;
            const path_id = self.intern.intern(line) catch return;
            pending.append(self.allocator, path_id) catch return;
        }
        {
            const prefetch = &self.sources.prefetch;
            prefetch.mu.lock();
            defer prefetch.mu.unlock();
            prefetch.manifest.appendSlice(self.allocator, pending.items) catch {};
        }
        // `manifestNextId` already applied the dedup + budget gate; submit
        // directly (prefetchPathConst would re-check `seen` and drop these).
        var seeds: usize = self.execution.worker_count;
        while (seeds > 0) : (seeds -= 1) {
            const path_id = self.manifestNextId() orelse break;
            _ = self.execution.scheduler.submit(.{ .import_prefetch = path_id }, worker_id_mod.currentId());
        }
    }

    /// Pop the next manifest path for the prefetch drip; consults the
    /// dedup/budget gate so a demanded-in-the-meantime import isn't replayed.
    fn manifestNextId(self: *Engine) ?types.InternId {
        const prefetch = &self.sources.prefetch;
        prefetch.mu.lock();
        defer prefetch.mu.unlock();
        while (prefetch.manifest_cursor < prefetch.manifest.items.len) {
            const path_id = prefetch.manifest.items[prefetch.manifest_cursor];
            prefetch.manifest_cursor += 1;
            if (prefetch.budget == 0) break;
            const gop = prefetch.seen.getOrPut(self.allocator, path_id) catch break;
            if (gop.found_existing) continue;
            prefetch.budget -= 1;
            return path_id;
        }
        return null;
    }

    fn manifestNext(context: *anyopaque) ?types.InternId {
        const self: *Engine = @ptrCast(@alignCast(context));
        return self.manifestNextId();
    }

    /// Record this run's successfully imported absolute paths as the
    /// generation's manifest (see `preloadImportManifest`). Runs at teardown
    /// after workers quiesce, while the import registry is still alive
    /// (`lifecycle.destroy`).
    ///
    /// Ordering: entries from the loaded manifest keep their positions
    /// (dropping paths this run no longer imported), and paths new to this
    /// run append in first-demand order (`Registry.order`). The anchor
    /// matters: under preload, first-demand order IS the racy prefetch-drip
    /// order, so rewriting from scratch each run would shuffle the manifest
    /// a little more per generation until it no longer resembles the compile
    /// order that keeps narrow-operand units loadable.
    pub fn writeChunkCacheManifest(self: *Engine) void {
        const state = &(self.compilation.chunk_cache orelse return);
        const name = self.sources.prefetch.manifest_name orelse return;
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer buffer.deinit(self.allocator);
        var carried: std.StringHashMapUnmanaged(void) = .empty;
        defer carried.deinit(self.allocator);
        {
            self.sources.imports.mu.lock();
            defer self.sources.imports.mu.unlock();
            const entries = &self.sources.imports.entries;
            for (self.sources.prefetch.manifest.items) |path_id| {
                const path = self.intern.get(path_id);
                const entry = entries.get(path) orelse continue;
                if (entry.failure != null) continue;
                const gop = carried.getOrPut(self.allocator, path) catch return;
                if (gop.found_existing) continue;
                buffer.appendSlice(self.allocator, path) catch return;
                buffer.append(self.allocator, '\n') catch return;
            }
            for (self.sources.imports.order.items) |path| {
                if (carried.contains(path)) continue;
                const entry = entries.get(path) orelse continue;
                if (entry.failure != null) continue;
                if (!std.fs.path.isAbsolute(path)) continue;
                buffer.appendSlice(self.allocator, path) catch return;
                buffer.append(self.allocator, '\n') catch return;
            }
        }
        if (buffer.items.len == 0) return;
        state.writeManifest(&name, buffer.items);
    }

    /// Hash every `LanguagePolicy` field into the cache key. Field-generic
    /// so a newly added policy knob automatically invalidates by value; the
    /// one slice field hashes its contents.
    fn policyFingerprint(policy: *const LanguagePolicy) u64 {
        var h = std.hash.Wyhash.init(0xF17C_CACE);
        inline for (@typeInfo(LanguagePolicy).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "allowed_path_roots")) {
                for (policy.allowed_path_roots) |root| {
                    h.update(root);
                    h.update(&.{0});
                }
            } else {
                std.hash.autoHash(&h, @field(policy.*, field.name));
            }
        }
        return h.final();
    }

    /// The cache key for a unit, or null when this compile must bypass the
    /// cache: string/scoped units, name-capture (`fix disasm`, REPL), or an
    /// installed debugger (`preserve_bindings` — debug sessions compile
    /// source-shaped, unoptimized bindings and must neither read optimized
    /// cached units nor poison the cache with debug-shaped ones).
    fn chunkCacheKey(self: *Engine, source: []const u8, source_path: ?[]const u8, scope: ?Value) ?chunk_cache.Key {
        if (scope != null) return null;
        const path = source_path orelse return null;
        if (self.registry.capture_names or self.registry.preserve_bindings) return null;
        const state = &(self.compilation.chunk_cache orelse return null);
        return state.key(source, path);
    }

    /// Load a cached unit for `key`, registering its chunks and deferred
    /// entries. Any failure (missing, stale, corrupt, id-width misfit)
    /// falls back to a fresh compile.
    fn tryLoadCachedUnit(
        self: *Engine,
        key: chunk_cache.Key,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
    ) ?ChunkId {
        const state = &(self.compilation.chunk_cache orelse return null);
        const bytes = state.readAlloc(self.allocator, key, .limited(256 * 1024 * 1024)) catch {
            _ = self.compilation.cache_misses.fetchAdd(1, .monotonic);
            return null;
        };
        defer self.allocator.free(bytes);

        var arena = ast_mod.AstArena.init(self.allocator);
        const result = chunk_cache.load(bytes, .{
            .allocator = self.allocator,
            .registry = &self.registry,
            .intern = &self.intern,
            .heap = &self.heap,
            .deferred = &self.compilation.deferred_table,
            .ast_arena = &arena,
            .source = source,
            .base_path = base_path,
            .source_path = source_path,
            .policy = self.policy,
        }) catch |err| {
            arena.deinit();
            _ = self.compilation.cache_rejects.fetchAdd(1, .monotonic);
            if (self.letFloatCensusEnabled())
                std.debug.print("chunk-cache reject: {s} {s}\n", .{ @errorName(err), source_path orelse "?" });
            return null;
        };
        // Deferred bodies materialize their synthesized `.elided` nodes from
        // this arena at force time; keep it for the engine's lifetime, same
        // as an eager compile's retained AST arena.
        if (result.deferred_count > 0) self.retainDeferredArena(arena) else arena.deinit();
        _ = self.compilation.cache_hits.fetchAdd(1, .monotonic);
        return result.top;
    }

    /// Serialize and publish a freshly-compiled unit (best-effort: a cache
    /// write failure never fails the compile). Serialization is inline — it
    /// reads live compiler/registry state — but the file IO goes to the
    /// bounded background writer lane, so the demanding evaluation resumes
    /// without waiting on disk or accumulating unbounded queued blobs. The `writes`
    /// census counter is bumped by the lane, so it is only final after
    /// `flushChunkCacheWrites`.
    fn writeCachedUnit(
        self: *Engine,
        key: chunk_cache.Key,
        compiler: *compiler_mod.Compiler,
        source_path: []const u8,
        top: ChunkId,
    ) void {
        const scratch = compiler.allocator;

        var ids = scratch.alloc(ChunkId, compiler.unit_chunks.items.len + 1) catch return;
        @memcpy(ids[0..compiler.unit_chunks.items.len], compiler.unit_chunks.items);
        ids[compiler.unit_chunks.items.len] = top;

        // Serialize directly into the allocation the background job will own;
        // there is no scratch blob followed by a full duplicate.
        const bytes = chunk_cache.serialize(self.allocator, &self.registry, &self.intern, &self.heap, &self.compilation.deferred_table, .{
            .source_path = source_path,
            .chunk_ids = ids,
            .deferred_ids = compiler.unit_deferred.items,
        }) catch {
            _ = self.compilation.cache_rejects.fetchAdd(1, .monotonic);
            return;
        };

        if (!self.compilation.chunk_cache.?.enqueueOwned(key, bytes, &self.compilation.cache_writes))
            _ = self.compilation.cache_rejects.fetchAdd(1, .monotonic);
    }

    fn retainDeferredArena(self: *Engine, arena: ast_mod.AstArena) void {
        self.compilation.retained_arenas_mu.lock();
        defer self.compilation.retained_arenas_mu.unlock();
        // A failed bookkeeping allocation must leak rather than leave deferred
        // table entries pointing into a freed arena.
        self.compilation.retained_arenas.append(self.allocator, arena) catch {};
    }

    /// Read-only access to compiled chunks for tools.
    pub fn getChunk(self: *const Engine, id: ChunkId) ?*const bytecode.Chunk {
        return self.registry.get(id);
    }

    /// Read-only access to the intern table for tools.
    pub fn internTable(self: *const Engine) *const InternTable {
        return &self.intern;
    }

    /// The `builtins` attrset, built on first use. Single-threaded callers
    /// only (the repl's completer wants it before the first evaluation).
    pub fn builtinsValue(self: *Engine) !Value {
        return self.ensureBuiltins();
    }

    /// Read-only access to the chunk registry for tools.
    pub fn chunkRegistry(self: *const Engine) *const ChunkRegistry {
        return &self.registry;
    }

    /// Explicit diagnostic surface for CLI tooling. Runtime representation is
    /// intentionally available here, but ordinary command workflows do not get
    /// direct mutable access to the Engine's heap/intern/registry fields.
    pub const Tooling = tooling_adapter.Adapter(Engine);

    pub fn tooling(self: *Engine) Tooling {
        return .{ .ev = self };
    }

    pub const ScopeBinding = struct { name: []const u8, value: Value };

    /// Replace the REPL's ambient scope and its external GC roots as one
    /// evaluator-owned operation, so the CLI cannot accidentally construct a
    /// heap object without registering the values that keep it alive.
    pub fn replaceExternalScope(self: *Engine, bindings: []const ScopeBinding) !Value {
        const entries = try self.allocator.alloc(runtime.heap.AttrEntry, bindings.len);
        defer self.allocator.free(entries);
        const roots = try self.allocator.alloc(Value, bindings.len + 1);
        defer self.allocator.free(roots);
        for (bindings, entries, roots[0..bindings.len]) |binding, *entry, *root| {
            entry.* = .{ .name = try self.intern.intern(binding.name), .value = binding.value };
            root.* = binding.value;
        }
        const scope = Value.attrs(try self.heap.addAttrs(entries));
        roots[bindings.len] = scope;
        try self.gcSetExternalRoots(roots);
        return scope;
    }

    /// Enable best-effort chunk naming: the compiler records the attr/let
    /// binding name behind each lambda/thunk chunk into a registry sidecar, for
    /// `fix disasm` and the REPL explorer to display. Off by default (hot
    /// compiles pay nothing); sidecar writes are synchronized for the REPL's
    /// parallel import compilation. Set before compiling.
    pub fn setCaptureChunkNames(self: *Engine, on: bool) void {
        self.registry.capture_names = on;
    }

    /// Use direct chunk registration for an evaluator whose compiled state
    /// cannot be observed by a later evaluation. Persistent/debug evaluators
    /// retain exact structural deduplication by default.
    pub fn setTransientChunkRegistration(self: *Engine, transient: bool) void {
        self.registry.dedup_compiler_chunks = !transient;
    }

    /// Install (or clear) the interactive debugger. `run` is called on the
    /// demand fiber each time evaluation pauses (a `builtins.break`, or — with
    /// `enterDebuggerOnError` — an evaluation error); it drives the console and
    /// returns to resume. `ctx` is the UI's opaque self-pointer. The CLI owns
    /// the UI implementation (terminal I/O lives in `cli`); the engine only
    /// upcalls through this seam, so the layering stays down-only.
    pub fn setDebugUi(self: *Engine, ctx: *anyopaque, run: *const fn (*anyopaque, *DebugSession) anyerror!void) void {
        // Interactive pauses are observable and cannot run on helper fibers.
        // Keep every debugger entry on the deterministic demand path even for
        // embedding applications that do not use the CLI's --debugger setup.
        self.setParallelismToggles(true, true);
        // Debugging wants the source's bindings materialized as written:
        // let-float rewrites stand down for everything compiled from now on
        // (sticky — already-registered chunks are immutable anyway).
        self.registry.preserve_bindings = true;
        self.debugger.setUi(.{ .ctx = ctx, .run = run });
        self.ensureBreakpointTable();
    }

    /// Breakpoint tooling is also available to the VM explorer, before a
    /// debugger UI is attached. A later `:debug`/`--debugger` session reuses
    /// the same requests and execution-overlay sites.
    pub fn setBreakpoint(self: *Engine, file: []const u8, line: u32) !bytecode.BreakpointTable.SetResult {
        self.ensureBreakpointTable();
        return self.debugger.breakpoints.?.set(&self.registry, file, line);
    }

    /// Per-instruction breakpoint at an exact `(chunk_id, offset)` site.
    /// `setBreakpointSpan` handles source-span rows; line-based
    /// `setBreakpoint` stays for console requests and pending/import resolution.
    pub fn setBreakpointAt(self: *Engine, chunk_id: ChunkId, offset: u32) !bytecode.BreakpointTable.SetResult {
        self.ensureBreakpointTable();
        return self.debugger.breakpoints.?.setAt(&self.registry, chunk_id, offset);
    }

    pub fn deleteBreakpointAt(self: *Engine, chunk_id: ChunkId, offset: u32) bool {
        if (self.debugger.breakpoints) |*breakpoints| return breakpoints.removeAt(&self.registry, chunk_id, offset);
        return false;
    }

    pub fn breakpointAt(self: *const Engine, chunk_id: ChunkId, offset: u32) bool {
        if (self.debugger.breakpoints) |*breakpoints| return breakpoints.hasSite(chunk_id, offset);
        return false;
    }

    pub fn setBreakpointSpan(self: *Engine, chunk_id: ChunkId, span: bytecode.Chunk.SourceSpan) !bytecode.BreakpointTable.SetResult {
        self.ensureBreakpointTable();
        return self.debugger.breakpoints.?.setSpan(&self.registry, chunk_id, span);
    }

    pub fn deleteBreakpointSpan(self: *Engine, chunk_id: ChunkId, span: bytecode.Chunk.SourceSpan) bool {
        if (self.debugger.breakpoints) |*breakpoints| return breakpoints.removeSpan(&self.registry, chunk_id, span);
        return false;
    }

    pub fn breakpointSpan(self: *const Engine, chunk_id: ChunkId, span: bytecode.Chunk.SourceSpan) bool {
        if (self.debugger.breakpoints) |*breakpoints| return breakpoints.hasSpan(chunk_id, span);
        return false;
    }

    pub fn listBreakpoints(self: *const Engine) []const bytecode.BreakpointTable.Request {
        if (self.debugger.breakpoints) |*breakpoints| return breakpoints.list();
        return &.{};
    }

    pub fn deleteBreakpoint(self: *Engine, id: u32) bool {
        if (self.debugger.breakpoints) |*breakpoints| return breakpoints.remove(&self.registry, id);
        return false;
    }

    fn ensureBreakpointTable(self: *Engine) void {
        if (self.debugger.breakpoints == null)
            self.debugger.breakpoints = bytecode.BreakpointTable.init(self.allocator, &self.intern);
    }

    pub fn clearDebugUi(self: *Engine) void {
        self.debugger.clearUi();
    }

    pub fn setDebugSource(self: *Engine, source: ?[]const u8) void {
        self.debugger.setSource(source);
    }

    pub fn setValueColor(self: *Engine, enabled: bool) void {
        self.value_color = enabled;
    }

    /// `vm_mod.BreakSink.fire` trampoline: build a `DebugSession` over the
    /// paused VM and hand it to the installed UI. Runs synchronously on the
    /// current demand fiber, so the console can re-enter the evaluator.
    fn fireBreak(ctx: *anyopaque, vm: *VM, value: Value, reason: vm_mod.BreakReason) anyerror!void {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        // A break/throw raised while the console is evaluating an expression
        // must not recurse into a nested debugger.
        const ui = self.debugger.beginSession() orelse return;
        defer self.debugger.endSession();
        const root_scope = vm_force.rootsBegin(vm);
        defer vm_force.rootsEnd(vm, root_scope);
        // The debugger UI owns every value it receives until this synchronous
        // pause ends. Register the initial subject even if collection has not
        // armed yet; DebugSession retains any additional values it returns.
        vm_force.rootKeepAcrossArming(vm, value);
        var session: DebugSession = .{ .ev = self, .vm = vm, .value = value, .reason = reason };
        try ui.run(ui.ctx, &session);
    }

    /// Console-expression evaluation from a debug pause: compile `source` in an
    /// ambient `scope` and run it on a fresh nested VM (sharing the registry,
    /// heap, and intern table). The nested VM leaves the paused VM's stack and
    /// frames untouched, so inspecting a value can't corrupt the pause point.
    fn debugEvalScoped(self: *Engine, paused_vm: *VM, source: []const u8, scope: ?Value) !Value {
        const chunk_id = try self.compileSourceScoped(source, scope);
        return self.runWithVm(debugRunBody, .{ chunk_id, paused_vm.debug.import_replay });
    }

    fn debugRunBody(vm: *VM, chunk_id: ChunkId, import_replay: bool) !Value {
        vm.debug.import_replay = import_replay;
        return vm.eval(chunk_id);
    }

    pub fn heapStats(self: *const Engine) ObjectHeap.Stats {
        return self.heap.stats();
    }

    pub fn heapCounts(self: *const Engine) ObjectHeap.Counts {
        return self.heap.counts();
    }

    pub fn heapObjectSnapshot(self: *const Engine, allocator: std.mem.Allocator) !ObjectHeap.ObjectSnapshot {
        return self.heap.objectSnapshot(allocator);
    }

    /// Live-slot snapshots for the value/attr/attr-position stores, so the VM
    /// explorer browses only real records, not reserved backing capacity.
    pub fn heapValueSnapshot(self: *const Engine, allocator: std.mem.Allocator) !ObjectHeap.ObjectSnapshot {
        return self.heap.valueSnapshot(allocator);
    }

    pub fn heapAttrSnapshot(self: *const Engine, allocator: std.mem.Allocator) !ObjectHeap.ObjectSnapshot {
        return self.heap.attrSnapshot(allocator);
    }

    pub fn heapAttrPosSnapshot(self: *const Engine, allocator: std.mem.Allocator) !ObjectHeap.ObjectSnapshot {
        return self.heap.attrPosSnapshot(allocator);
    }

    pub fn inspectHeapObject(self: *const Engine, snapshot: *const ObjectHeap.ObjectSnapshot, id: runtime.types.ObjectId) !runtime.heap.ObjectInfo {
        return self.heap.inspectObject(snapshot, id);
    }

    pub fn collectHeapObjectReferences(
        self: *const Engine,
        snapshot: *const ObjectHeap.ObjectSnapshot,
        id: runtime.types.ObjectId,
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(runtime.heap.HeapReference),
    ) !void {
        return runtime.heap_edges.collectReferences(&self.heap, snapshot, id, allocator, out);
    }

    /// Per-record access to the value/attr/attr-position stores, for the VM
    /// explorer's heap-store browsing.
    pub fn heapValueAt(self: *const Engine, id: u32) ?*const runtime.value.Value {
        return self.heap.valueAt(id);
    }

    pub fn heapAttrAt(self: *const Engine, id: u32) ?runtime.heap.AttrEntry {
        return self.heap.attrAt(id);
    }

    pub fn heapAttrPosAt(self: *const Engine, id: u32) ?*const runtime.heap.AttrPosEntry {
        return self.heap.attrPosAt(id);
    }

    pub fn valueRef(_: *const Engine, value: Value) runtime.heap.ValueRef {
        return runtime.heap.inspection.valueRef(value);
    }

    /// Enumerate an attrs / list object's members (non-forcing) for the VM
    /// explorer, so a container value inspects into its actual entries.
    pub fn heapAttrsOf(self: *Engine, id: runtime.types.ObjectId) !runtime.heap.AttrsView {
        return self.heap.materializeAttrs(id);
    }

    pub fn heapListOf(self: *const Engine, id: runtime.types.ObjectId) ![]const Value {
        return self.heap.getList(id);
    }

    pub fn heapBoxedInt(self: *const Engine, id: runtime.types.ObjectId) !i64 {
        return self.heap.getBoxedInt(id);
    }

    pub fn internStats(self: *const Engine) InternTable.Stats {
        return self.intern.stats();
    }

    pub fn chunkStats(self: *const Engine) ChunkRegistry.Stats {
        return self.registry.stats();
    }

    pub fn schedulerStats(self: *const Engine) Scheduler.Stats {
        return self.execution.scheduler.stats();
    }

    pub fn deferredStats(self: *const Engine) deferred_mod.Table.Stats {
        return self.compilation.deferred_table.stats();
    }

    pub fn workerCount(self: *const Engine) u8 {
        return self.execution.scheduler.worker_count;
    }

    pub fn setParallelismToggles(self: *Engine, disable_speculation: bool, disable_fanout: bool) void {
        var config = self.execution.scheduler.configuration();
        config.disable_speculation = disable_speculation;
        config.disable_fanout = disable_fanout;
        self.execution.scheduler.configure(config);
    }

    pub fn setDebugSerial(self: *Engine, enabled: bool) void {
        self.execution.scheduler.setDebugSerial(enabled);
    }

    /// Compile source text into bytecode and evaluate it.
    /// This is the main public API.
    pub fn evaluate(self: *Engine, source: []const u8) !Value {
        return self.evaluateTop(source, self.sources.base_path, null, null);
    }

    /// `evaluate`, attributing the top-level source to `source_path` — source
    /// spans and the disasm file sidecar then carry the entry file's name, the
    /// same way imported files do. Used by `fix disasm --eval`.
    pub fn evaluatePath(self: *Engine, source: []const u8, source_path: ?[]const u8) !Value {
        return self.evaluateTop(source, self.sources.base_path, source_path, null);
    }

    /// `evaluatePath` with an explicit relative-path base. Multi-input CLI
    /// builds use this so each file keeps its own directory while sharing one
    /// evaluator.
    pub fn evaluatePathAt(self: *Engine, source: []const u8, base_path: ?[]const u8, source_path: ?[]const u8) !Value {
        return self.evaluateTop(source, base_path, source_path, null);
    }

    /// Like `evaluate`, but compiles the source inside an ambient scope
    /// attrset (identifiers not otherwise bound resolve from `scope`, the
    /// same mechanism as `builtins.scopedImport`). The repl uses this to
    /// make its bindings visible. When a source may reference those bindings,
    /// `scope` is baked into the compiled chunk's constants, which are GC
    /// roots; builtin/literal-only sources omit the unused scope.
    pub fn evaluateWithScope(self: *Engine, source: []const u8, scope: ?Value) !Value {
        return self.evaluateTop(source, self.sources.base_path, null, scope);
    }

    /// `evaluateWithScope`, retaining the compiled entry chunk for tooling.
    pub fn evaluateWithScopeResult(self: *Engine, source: []const u8, scope: ?Value) !EvaluationResult {
        return self.evaluateTopResult(source, self.sources.base_path, null, scope, false);
    }

    /// Evaluate REPL source with a one-shot debugger pause at its first mapped
    /// instruction. The source is compiled unchanged; the UI must already be
    /// installed so the entry trap has somewhere to route.
    pub fn debugWithScopeResult(self: *Engine, source: []const u8, scope: ?Value) !EvaluationResult {
        const was_debug_serial = self.execution.scheduler.swapDebugSerial(true);
        defer self.execution.scheduler.setDebugSerial(was_debug_serial);
        return self.evaluateTopResult(source, self.sources.base_path, null, scope, true);
    }

    fn evaluateTop(self: *Engine, source: []const u8, base_path: ?[]const u8, source_path: ?[]const u8, scope: ?Value) !Value {
        return (try self.evaluateTopResult(source, base_path, source_path, scope, false)).value;
    }

    fn evaluateTopResult(
        self: *Engine,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
        initial_break: bool,
    ) !EvaluationResult {
        if (initial_break) {
            if (self.debugger.breakpoints) |*breakpoints| breakpoints.clearStep(&self.registry);
        }
        defer if (initial_break) {
            // A finish/step can run directly to the result without another
            // pause at which the UI would normally clear its temporary sites.
            if (self.debugger.breakpoints) |*breakpoints| breakpoints.clearStep(&self.registry);
        };
        try self.prepareEvaluations();
        // Not routed through `evaluateSource`: its top-level detection is
        // `source_path == null`, so passing the path there would send the
        // top-level eval down the nested-import path (wrong fiber). Attribute
        // the source at compile time (and, when observable, bake `scope` into
        // the chunk's constants as the repl's ambient-scope mechanism), then
        // run on the main worker as usual.
        const chunk_id = try self.parseAndCompile(source, base_path, source_path, scope);
        if (initial_break) {
            if (self.debugger.breakpoints) |*breakpoints| {
                _ = try breakpoints.armEntry(&self.registry, chunk_id);
            }
        }
        const subject = source_path orelse "expression";
        var observation = self.observer.begin(&evaluate_observation, observationDetails(subject));
        defer observation.cancel();
        const value = try self.runChunkOnMainWorker(chunk_id);
        observation.finish(.{});
        return .{ .value = value, .entry_chunk = chunk_id };
    }

    fn prepareEvaluations(self: *Engine) !void {
        try self.requireActiveEvaluation();
        // Build the builtins attrset on the main thread before any helpers
        // can race on it. `buildAttrSet` predicts the next ObjectId for
        // the self-reference `builtins.builtins`; that prediction is only
        // safe when no other thread is allocating objects.
        _ = try self.ensureBuiltins();
        const eval_tuning = self.ensureTuningPolicy();
        if (!self.execution.scheduler.isStarted()) {
            self.execution.scheduler.configure(eval_tuning.scheduler);
        }
        // Prefetch work is deduplicated by the import and file registries, and
        // bounded so speculative tasks cannot grow without limit.
        // After tuning: the cache key snapshots codegen-affecting knobs
        // (`let_float_enabled`) that tuning just resolved.
        self.resolveChunkCache();
        self.sources.prefetch.budget = eval_tuning.prefetch.import_budget;
        self.execution.scheduler.setReadDirPrefetch(eval_tuning.prefetch.read_dir_min, eval_tuning.prefetch.read_dir_budget);
        try self.execution.scheduler.start(helperLoop, self);
        self.clearDiagnostics();
        self.store.realization.clearDebugRecords();
    }

    pub const ParallelInput = struct {
        source: []const u8,
        base_path: ?[]const u8 = null,
        source_path: ?[]const u8 = null,
    };

    pub const ParallelSink = struct {
        context: *anyopaque,
        complete_fn: *const fn (context: *anyopaque, index: usize, value: ?Value, failure: ?ParallelFailure) void,

        pub fn complete(self: ParallelSink, index: usize, value: ?Value, failure: ?ParallelFailure) void {
            self.complete_fn(self.context, index, value, failure);
        }
    };

    pub const ParallelFailure = struct {
        err: anyerror,
        trace: *const EvalTrace,
        diagnostics: bool = false,
    };

    /// Compile several independent inputs, then evaluate each on its own demand
    /// fiber. `sink` is called exactly once per input, from that demand fiber
    /// for runtime outcomes and from the caller for compile/setup failures.
    pub fn evaluatePathsParallel(self: *Engine, inputs: []const ParallelInput, sink: ParallelSink) void {
        if (inputs.len == 0) return;
        self.prepareEvaluations() catch |err| {
            for (inputs, 0..) |_, index| sink.complete(index, null, .{ .err = err, .trace = self.getTrace() });
            return;
        };

        const Context = struct {
            ev: *Engine,
            sink: ParallelSink,
            index: usize,
            chunk_id: ChunkId,
            details: observ.Details,
            trace: *EvalTrace,

            fn entry(raw: *anyopaque) void {
                const ctx: *@This() = @ptrCast(@alignCast(raw));
                const inner = fiber_mod.currentFiber().?;
                const fiber: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
                fiber.ctx.error_trace = ctx.trace;
                defer fiber.ctx.error_trace = null;
                var scratch = @import("base").arena.ArenaAllocator.init(ctx.ev.allocator);
                defer scratch.deinit();
                var vm = ctx.ev.initVm(0, scratch.allocator()) catch |err| {
                    ctx.sink.complete(ctx.index, null, .{ .err = err, .trace = ctx.trace });
                    return;
                };
                defer vm.deinit();
                gc_controller.registerVm(gcContext(ctx.ev), &vm);
                defer gc_controller.unregisterVm(gcContext(ctx.ev), &vm);
                var observation = ctx.ev.observer.begin(&evaluate_observation, ctx.details);
                defer observation.cancel();
                const value = vm.eval(ctx.chunk_id) catch |err| {
                    ctx.sink.complete(ctx.index, null, .{ .err = err, .trace = ctx.trace });
                    return;
                };
                observation.finish(.{});
                // The sink is native storage and this fiber unwinds now; pin
                // the result before it becomes sweepable (see
                // gcRootCrossingValue).
                ctx.ev.gcRootCrossingValue(value);
                ctx.sink.complete(ctx.index, value, null);
            }
        };

        const contexts = self.allocator.alloc(Context, inputs.len) catch {
            for (inputs, 0..) |_, index| sink.complete(index, null, .{ .err = error.OutOfMemory, .trace = self.getTrace() });
            return;
        };
        defer self.allocator.free(contexts);
        const traces = self.allocator.alloc(EvalTrace, inputs.len) catch {
            for (inputs, 0..) |_, index| sink.complete(index, null, .{ .err = error.OutOfMemory, .trace = self.getTrace() });
            return;
        };
        defer self.allocator.free(traces);
        for (traces) |*trace| trace.* = EvalTrace.init(self.allocator);
        defer for (traces) |*trace| trace.deinit();
        var entries: std.ArrayListUnmanaged(worker_mod.Worker.TopLevelEntry) = .empty;
        defer entries.deinit(self.allocator);
        entries.ensureTotalCapacity(self.allocator, inputs.len) catch {
            for (inputs, 0..) |_, index| sink.complete(index, null, .{ .err = error.OutOfMemory, .trace = self.getTrace() });
            return;
        };

        for (inputs, 0..) |input, index| {
            const chunk_id = self.parseAndCompile(input.source, input.base_path orelse self.sources.base_path, input.source_path, null) catch |err| {
                sink.complete(index, null, .{ .err = err, .trace = self.getTrace(), .diagnostics = true });
                continue;
            };
            contexts[index] = .{
                .ev = self,
                .sink = sink,
                .index = index,
                .chunk_id = chunk_id,
                .details = observationDetails(input.source_path orelse "expression"),
                .trace = &traces[index],
            };
            entries.appendAssumeCapacity(.{ .entry = Context.entry, .arg = &contexts[index] });
        }

        const worker = self.ensureMainWorker() catch |err| {
            for (entries.items) |entry| {
                const ctx: *Context = @ptrCast(@alignCast(entry.arg));
                sink.complete(ctx.index, null, .{ .err = err, .trace = ctx.trace });
            }
            return;
        };
        worker.runTopLevels(entries.items) catch |err| {
            for (entries.items) |entry| {
                const ctx: *Context = @ptrCast(@alignCast(entry.arg));
                sink.complete(ctx.index, null, .{ .err = err, .trace = ctx.trace });
            }
        };
    }

    pub fn evaluateSource(
        self: *Engine,
        source: []const u8,
        base_path: ?[]const u8,
        source_path: ?[]const u8,
        scope: ?Value,
        /// The calling VM's `native_depth` (the `import` builtin already +1'd
        /// it). The nested import VM inherits `parent_depth - 1` so imports are
        /// GC-safepoint-transparent (a top-level import collects at depth 0; a
        /// nested one stays gated at the caller's depth). 0 for the top level.
        parent_depth: u32,
        /// The VM containing the synchronous import call, for debugger stack
        /// traversal. Null for a top-level/non-import evaluation.
        debug_parent: ?*VM,
    ) !Value {
        const chunk_id = try self.parseAndCompile(source, base_path, source_path, scope);
        const subject = source_path orelse "expression";
        var observation = self.observer.begin(&evaluate_observation, observationDetails(subject));
        defer observation.cancel();
        // Only a top-level eval (no source_path — a plain or repl-scoped
        // entry) goes through a main-thread fiber so the main thread can
        // yield on a `.busy` thunk; nested invocations (imports, scoped
        // imports — which always carry the imported file's path) run
        // synchronously on the existing fiber's stack — they share the
        // surrounding fiber's execution identity via the ctx pointer
        // `initVm` copies.
        if (source_path == null) {
            const value = try self.runChunkOnMainWorker(chunk_id);
            observation.finish(.{});
            return value;
        }
        // Per-import scratch arena: the nested VM's run-path allocations
        // (drv hashing, builtin temp buffers) are freed wholesale when the
        // import returns instead of accreting for the evaluator's lifetime.
        var scratch = @import("base").arena.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var vm = try self.initVm(0, scratch.allocator());
        defer vm.deinit();
        vm.debug.parent = debug_parent;
        vm.debug.import_replay = if (debug_parent) |parent| parent.debug.import_replay else false;
        if (debug_parent) |parent| vm.speculation.active = parent.speculation.active;
        // Depth-transparent import: the fresh nested VM inherits the caller's
        // depth minus 1 (dropping the `import` builtin's own +1), so a
        // top-level import evaluates at depth 0 (collects) while a nested one
        // stays gated at the enclosing builtin's depth. native_depth lives on
        // the VM (fiber-local), so no threadlocal dance is needed.
        vm.native_depth = parent_depth -| 1;
        // This VM isn't in a Worker's fiber list; make its roots visible to GC.
        gc_controller.registerVm(gcContext(self), &vm);
        defer gc_controller.unregisterVm(gcContext(self), &vm);
        const value = vm.eval(chunk_id) catch |err| {
            try mergeNestedEffects(debug_parent, &vm);
            return err;
        };
        try mergeNestedEffects(debug_parent, &vm);
        observation.finish(.{});
        return value;
    }

    fn runChunkOnMainWorker(self: *Engine, chunk_id: ChunkId) !Value {
        return self.runWithVm(VM.eval, .{chunk_id});
    }

    /// `scratch` is the VM's allocation arena — per-fiber (reset when the
    /// fiber is recycled) or per-import (freed when the import returns).
    /// It must be an arena: VM frees are best-effort, error and suspend paths
    /// may abandon allocations, and reset/deinit reclaims them wholesale.
    fn initVm(self: *Engine, worker_id: u8, scratch: std.mem.Allocator) !VM {
        // RSS attribution: the VM's own allocations (gc lists; the
        // stack/frames go through the shared pool) get the worker bucket.
        const prev_tag = vma_mod.setAllocTag(.worker_arena);
        defer _ = vma_mod.setAllocTag(prev_tag);
        var vm = try VM.init(.{
            .driver = &vm_mod.driver,
            .allocator = scratch,
            .buffer_pool = &self.execution.vm_buffers,
            .registry = &self.registry,
            .intern = &self.intern,
            .heap = &self.heap,
            .files = &self.sources.files,
            .fetchers = &self.sources.fetchers,
            .realization = &self.store.realization,
            .workers = execution.VmRuntime.init(&self.execution.scheduler),
            // Helpers (worker_id != 0) don't write to the shared trace —
            // it's a side effect of *real* evaluation, so speculative force
            // stays invisible to it.
            .trace_sink = if (worker_id == 0) &self.report.trace else null,
            .effects = &self.effects,
            // The observer is a cheap evaluator-scoped capability. Every VM
            // receives it, including helper VMs, while the sink is responsible
            // for any synchronization needed by the selected outputs.
            .observer = self.observer,
            .executor = execution.fiber_executor,
            .vm_trace = if (worker_id == 0) self.vm_trace else null,
            // The thunk trace IS shared across workers — diagnosing
            // concurrency-shaped wrong-result bugs needs to see every
            // helper's resolves, not just main's. The trace handles
            // its own locking.
            .thunk_trace = self.thunk_trace,
            .import_host = .{ .context = self, .import_value = importValue, .scoped_import = scopedImportValue, .find_file = findFile, .get_env = getEnv, .manifest_next = manifestNext },
            .builtins_value = try self.ensureBuiltins(),
            .deferred_table = &self.compilation.deferred_table,
            .registration_sink = chunkRegistrationSink(self),
            .regexes = &self.regexes,
            .break_sink = if (self.debugger.ui != null) .{ .ctx = self, .fire = fireBreak } else null,
            .breakpoints = if (self.debugger.breakpoints != null) &self.debugger.breakpoints.? else null,
            .policy = self.policy,
            .trace_verbose = self.trace_verbose,
            .lazy_shells_visible = self.lazy_shells_visible,
            .heap_string_min = self.ensureTuningPolicy().heap_string_min,
        });
        // A nested VM runs on the surrounding fiber, so it borrows that
        // fiber's execution identity wholesale: claim id (any thunk it
        // claims is attributed to the fiber, not to a default that would
        // collide with pool fiber #0 and cause spurious blackholes),
        // demand flag, and the demand-only progress handles (stage stack,
        // "waiting on" record). One pointer copy — nested VMs (imports,
        // render/force bodies) CANNOT diverge from their fiber, so
        // stage/count/wait emission stays alive across them on the demand
        // fiber while a helper fiber's nested VMs stay structurally silent.
        // No current fiber (pool-VM construction on the worker thread,
        // single-threaded setup) keeps the neutral static default; the
        // Worker then binds pool VMs to their own fiber's ctx.
        if (fiber_mod.currentFiber()) |inner| {
            const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
            vm.ctx = &wf.ctx;
            // The fiber owns both exception identity and its diagnostic sink.
            // Bind unconditionally: a nested import on a speculative helper
            // must keep using the helper's scratch trace, while ordinary and
            // parallel demand fibers retain their respective report traces.
            vm.trace = wf.ctx.error_trace;
        }
        return vm;
    }

    pub fn writeJsonValue(self: *Engine, writer: *std.Io.Writer, value: Value) !void {
        try self.requireActiveEvaluation();
        var observation = self.observer.begin(&render_observation, .{ .subject = .{ .text = "result" } });
        defer observation.cancel();
        self.report.trace.clear();
        try self.runWithVm(vm_builtins.writeJsonValue, .{ writer, value });
        observation.finish(.{});
    }

    /// Legacy `nix-instantiate --eval --raw` rendering: coerce exactly as a
    /// Nix string interpolation would (strings, paths, `outPath`,
    /// `__toString`; never integers), then emit the bytes verbatim.
    pub fn writeRawValue(self: *Engine, writer: *std.Io.Writer, value: Value) !void {
        try self.requireActiveEvaluation();
        var observation = self.observer.begin(&render_observation, .{ .subject = .{ .text = "result" } });
        defer observation.cancel();
        self.report.trace.clear();
        try self.runWithVm(writeRawValueBody, .{ writer, value });
        observation.finish(.{});
    }

    pub fn writeXmlValue(self: *Engine, writer: *std.Io.Writer, value: Value) !void {
        try self.requireActiveEvaluation();
        var observation = self.observer.begin(&render_observation, .{ .subject = .{ .text = "result" } });
        defer observation.cancel();
        self.report.trace.clear();
        try self.runWithVm(vm_builtins.writeLazyXmlValue, .{ writer, value });
        observation.finish(.{});
    }

    pub fn forceValue(self: *Engine, value: Value) !Value {
        try self.requireActiveEvaluation();
        self.report.trace.clear();
        return self.forceValueUntraced(value);
    }

    fn forceValueUntraced(self: *Engine, value: Value) !Value {
        return self.runWithVm(vm_force.forceValue, .{value});
    }

    /// Enable writing forced derivations + their sources to the store as they
    /// are forced (`fix instantiate`/`build`). The daemon connects lazily on
    /// first use; plain eval leaves this off and never touches the store.
    pub fn enableStoreWrites(self: *Engine) void {
        self.store.realization.enableStoreWrites();
    }

    /// Legacy `nix-instantiate --eval --read-write-mode`: materialize every
    /// derivation actually demanded by evaluation, while the CLI still renders
    /// the evaluated value rather than returning a `.drv` path.
    pub fn enableReadWriteEvaluation(self: *Engine) void {
        self.store.realization.enableEagerEvaluationWrites();
    }

    /// The last daemon error message, for surfacing `error.DaemonError`.
    pub fn lastStoreError(self: *Engine) ?[]const u8 {
        return self.store.realization.lastStoreError();
    }

    /// If `value` is a derivation (an attrset with a `drvPath`), force it — which
    /// also instantiates its closure when a daemon is attached — and return the
    /// drv path (borrowed from the intern table). Returns null if `value` is not
    /// a derivation-shaped attrset.
    pub fn derivationDrvPath(self: *Engine, value: Value) !?[]const u8 {
        self.report.trace.clear();
        return self.derivationAttrPath(value, "drvPath");
    }

    /// The default output path (`outPath`) of a derivation `value`, or null if
    /// it is not a derivation-shaped attrset.
    pub fn derivationOutPath(self: *Engine, value: Value) !?[]const u8 {
        self.report.trace.clear();
        return self.derivationAttrPath(value, "outPath");
    }

    fn derivationAttrPath(self: *Engine, value: Value, attr_name: []const u8) !?[]const u8 {
        const forced = try self.forceValueUntraced(value);
        if (!forced.isAttrs()) return null;
        return self.forcedStringAttr(forced.asObjectId(), attr_name);
    }

    pub const DerivationBuildPaths = struct {
        drv_path: []const u8,
        out_path: []const u8,
    };

    /// Extract the paths needed by the parallel build pipeline without touching
    /// the evaluator's single-run diagnostic trace.
    pub fn derivationBuildPaths(self: *Engine, value: Value) !?DerivationBuildPaths {
        const forced = try self.forceValueUntraced(value);
        if (!forced.isAttrs()) return null;
        const id = forced.asObjectId();
        const drv_path = (try self.forcedStringAttr(id, "drvPath")) orelse return null;
        return .{
            .drv_path = drv_path,
            .out_path = (try self.forcedStringAttr(id, "outPath")) orelse drv_path,
        };
    }

    /// The name of the program `fix run` should exec from a derivation's output:
    /// `meta.mainProgram`, else `pname`, else `name`. Borrowed from intern.
    pub fn derivationProgram(self: *Engine, value: Value) !?[]const u8 {
        const forced = try self.forceValue(value);
        if (!forced.isAttrs()) return null;
        const id = forced.asObjectId();
        if (try self.heap.getAttrValueOpt(id, try self.intern.intern("meta"))) |meta| {
            const meta_forced = try self.forceValue(meta);
            if (meta_forced.isAttrs()) {
                if (try self.forcedStringAttr(meta_forced.asObjectId(), "mainProgram")) |main| return main;
            }
        }
        if (try self.forcedStringAttr(id, "pname")) |pname| return pname;
        return self.forcedStringAttr(id, "name");
    }

    pub const AppProgram = struct {
        /// The absolute program path to exec (`$store/bin/…`).
        program: []const u8,
        /// A `.drv` in the program's string context to build first, if any.
        drv_path: ?[]const u8,
    };

    /// If `value` is a flake app (`{ type = "app"; program = …; }`), return its
    /// program path and (from the program's string context) the derivation to
    /// build before running it. Null when `value` is not an app.
    pub fn appProgram(self: *Engine, value: Value) !?AppProgram {
        const forced = try self.forceValueUntraced(value);
        if (!forced.isAttrs()) return null;
        const id = forced.asObjectId();
        const ty = (try self.forcedStringAttr(id, "type")) orelse return null;
        if (!std.mem.eql(u8, ty, "app")) return null;
        const prog_attr = (try self.heap.getAttrValueOpt(id, try self.intern.intern("program"))) orelse return null;
        const forced_prog = try self.forceValueUntraced(prog_attr);
        const program = switch (forced_prog.kind()) {
            .string, .path => self.intern.get(forced_prog.asInternId()),
            .string_context => self.intern.get((try self.heap.getContextString(forced_prog.asObjectId())).text),
            .heap_string => try self.heap.getHeapString(forced_prog.asObjectId()),
            else => return null,
        };
        var drv_path: ?[]const u8 = null;
        if (forced_prog.kind() == .string_context) {
            for ((try self.heap.getContextString(forced_prog.asObjectId())).context.names) |entry_name| {
                const name = self.intern.get(entry_name);
                if (std.mem.endsWith(u8, name, ".drv")) {
                    drv_path = name;
                    break;
                }
            }
        }
        return .{ .program = program, .drv_path = drv_path };
    }

    /// Force attribute `name` of `id` and return its text (string/path/context),
    /// or null if absent or non-string. Borrowed from the intern table.
    fn forcedStringAttr(self: *Engine, id: types.ObjectId, name: []const u8) !?[]const u8 {
        const name_id = try self.intern.intern(name);
        const attr = (try self.heap.getAttrValueOpt(id, name_id)) orelse return null;
        const forced = try self.forceValueUntraced(attr);
        const text_id = switch (forced.kind()) {
            .string, .path => forced.asInternId(),
            .string_context => (try self.heap.getContextString(forced.asObjectId())).text,
            .heap_string => try self.intern.intern(try self.heap.getHeapString(forced.asObjectId())),
            else => return null,
        };
        return self.intern.get(text_id);
    }

    /// Write `drv_path`'s `.drv` closure to the store on demand (deps-first via
    /// the recipe graph). Since forcing only records recipes, this is how a `.drv`
    /// is materialized — for `instantiate`, and before a build. Must run before
    /// eval state is released (it reads the recipe graph).
    pub fn ensureDerivationClosure(self: *Engine, drv_path: []const u8) !void {
        return self.store.realization.ensureClosure(drv_path);
    }

    /// Hash-modulo resolver over the recorded input derivations — for computing
    /// the paths of a derivation constructed on the fly (e.g. a get-env drv).
    pub fn storeResolver(self: *Engine) derivation.HashModuloResolver {
        return self.store.realization.resolver();
    }

    /// Write a constructed `.drv` (ATerm) to the store. Its references (input
    /// `.drv`s / srcs) must already be valid.
    pub fn instantiateDrv(self: *Engine, drv_path: []const u8, aterm: []const u8, references: []const []const u8) !void {
        return self.store.realization.instantiateDrv(drv_path, aterm, references);
    }

    /// Read a store path's file contents: straight off local disk when the store
    /// is local, else via the daemon (`NarFromPath`) for a remote store. Used to
    /// read a get-env derivation's `$out` back regardless of store location.
    pub fn readStorePathFile(self: *Engine, io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 << 20))) |data| {
            return data;
        } else |err| switch (err) {
            error.FileNotFound => {}, // not on this machine — a remote store
            else => return err,
        }
        return self.store.realization.readFileViaStore(allocator, path);
    }

    /// Read a store path's contents through the selected backend, bypassing the
    /// local disk. Useful for a remote store and as a test hook.
    pub fn readFileViaStore(self: *Engine, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.store.realization.readFileViaStore(allocator, path);
    }

    /// Compatibility spelling for callers that assume the default daemon.
    pub fn readFileViaDaemon(self: *Engine, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.readFileViaStore(allocator, path);
    }

    pub const AsyncBuildRequest = StoreState.AsyncBuildRequest;

    /// Submit a fully materialized derivation to the selected store driver
    /// without waiting for its build to finish.
    pub fn submitBuild(self: *Engine, request: *AsyncBuildRequest) void {
        self.store.submitBuild(request);
    }

    /// Finish evaluation and return the only state needed by the build phase.
    /// Language teardown overlaps daemon work once the returned session starts
    /// a build; callers must keep the session alive until that work completes.
    pub fn beginBuildPhase(self: *Engine, derived_paths: []const []const u8, after_release: ?ReleaseAction) !BuildSession {
        try self.requireActiveEvaluation();
        // Writes are demand-driven: materialize each target's `.drv` closure now,
        // BEFORE releasing eval state — `ensureClosure` walks the recipe graph,
        // which evaluation teardown frees. (Cheap, and inherently sequential: the
        // daemon can't build a `.drv` whose closure isn't on disk yet.)
        for (derived_paths) |derived| {
            const drv = derived[0..(std.mem.indexOfScalar(u8, derived, '!') orelse derived.len)];
            try self.store.realization.ensureClosure(drv);
        }
        // Publish the terminal transition before the releaser starts. The
        // caller can never observe an apparently-active Engine while its
        // language state is concurrently being destroyed.
        self.evaluation_phase = .releasing;
        // Release on a helper so teardown overlaps daemon startup. If spawning
        // fails, release synchronously.
        const releaser = std.Thread.spawn(.{}, releaseForBuild, .{ self, after_release }) catch blk: {
            releaseForBuild(self, after_release);
            break :blk null;
        };
        return BuildSession.init(&self.store, releaser);
    }

    /// Set the per-connection daemon settings (`--cores`/`--max-jobs`/… via
    /// `set_options`) applied when the store connects. See `setup.configure`.
    pub fn setDaemonBuildSettings(self: *Engine, settings: store_domain.daemon.BuildSettings) !void {
        return self.store.realization.setBuildSettings(settings);
    }

    /// Select an alternate store implementation before backend execution
    /// starts. The driver is owned by the Engine's store state until `deinit`.
    pub fn setStoreBackend(self: *Engine, driver: store_domain.BackendDriver) !void {
        return self.store.setBackend(driver);
    }

    /// Override the nix-daemon socket path (`$NIX_DAEMON_SOCKET_PATH`).
    pub fn setDaemonSocket(self: *Engine, path: []const u8) !void {
        return self.store.realization.setDaemonSocket(path);
    }

    /// Override the store directory (`store-dir` / `NIX_STORE_DIR`). Threads
    /// into path computation, store-path detection, and `builtins.storeDir`.
    pub fn setStoreDir(self: *Engine, dir: []const u8) !void {
        return self.store.realization.setStoreDir(dir);
    }

    pub fn storeDir(self: *const Engine) []const u8 {
        return self.store.realization.store_dir;
    }

    /// Navigate a dotted attr path (e.g. `python3Packages.requests`) from `value`,
    /// forcing each step. Returns null if any component is missing or non-attrs.
    pub fn attrPathValue(self: *Engine, value: Value, path: []const u8) !?Value {
        var current = try self.forceValue(value);
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |component| {
            if (!current.isAttrs()) return null;
            const name_id = try self.intern.intern(component);
            const attr = (try self.heap.getAttrValueOpt(current.asObjectId(), name_id)) orelse return null;
            current = try self.forceValue(attr);
        }
        return current;
    }

    /// The sorted attribute names of `value` (owned outer slice; the names are
    /// borrowed from the intern table). Null when `value` is not an attrset.
    /// Used by the `flake` subcommands to walk a flake's outputs/inputs.
    pub fn attrNames(self: *Engine, allocator: std.mem.Allocator, value: Value) !?[][]const u8 {
        const forced = try self.forceValue(value);
        if (!forced.isAttrs()) return null;
        const attrs = try self.heap.materializeAttrs(forced.asObjectId());
        const names = try allocator.alloc([]const u8, attrs.len());
        for (attrs.names, 0..) |e_name, i| names[i] = self.intern.get(e_name);
        std.mem.sort([]const u8, names, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return names;
    }

    /// Force `value` and return its attribute `name` (unforced), or null if
    /// `value` is not an attrset or has no such attribute.
    pub fn getAttr(self: *Engine, value: Value, name: []const u8) !?Value {
        const forced = try self.forceValue(value);
        if (!forced.isAttrs()) return null;
        return self.heap.getAttrValueOpt(forced.asObjectId(), try self.intern.intern(name));
    }

    /// The text of string attribute `name` on `value`, or null. Borrowed.
    pub fn stringAttr(self: *Engine, value: Value, name: []const u8) !?[]const u8 {
        const forced = try self.forceValue(value);
        if (!forced.isAttrs()) return null;
        return self.forcedStringAttr(forced.asObjectId(), name);
    }

    /// The text of `value` if it is a string/path (following string context),
    /// or null otherwise. Borrowed from the intern table.
    pub fn stringValue(self: *Engine, value: Value) !?[]const u8 {
        const forced = try self.forceValue(value);
        return switch (forced.kind()) {
            .string, .path => self.intern.get(forced.asInternId()),
            .string_context => self.intern.get((try self.heap.getContextString(forced.asObjectId())).text),
            .heap_string => try self.heap.getHeapString(forced.asObjectId()),
            else => null,
        };
    }

    /// The value of integer attribute `name` on `value`, or null.
    pub fn intAttr(self: *Engine, value: Value, name: []const u8) !?i64 {
        const attr = (try self.getAttr(value, name)) orelse return null;
        const forced = try self.forceValue(attr);
        return if (forced.isInt()) forced.asInt() else null;
    }

    /// Compute and write `flake.lock` for `ref` as a first-class operation
    /// (`fix flake update`/`lock`) — no `outputs` evaluation. `update_all`
    /// re-pins every input; otherwise only `update_names` (and newly-declared
    /// inputs) are re-fetched and the rest keep their current pins.
    pub fn updateFlakeLock(self: *Engine, ref: []const u8, update_all: bool, update_names: []const []const u8) !void {
        if (!self.policy.flakes_enabled) return error.FlakesFeatureRequired;
        return self.runWithVm(vm_builtins.computeFlakeLock, .{ ref, update_all, update_names });
    }

    pub fn forceDeep(self: *Engine, value: Value) !void {
        try self.requireActiveEvaluation();
        var observation = self.observer.begin(&render_observation, .{ .subject = .{ .text = "strict result" } });
        defer observation.cancel();
        self.report.trace.clear();
        try self.runWithVm(vm_force.forceDeepCounted, .{value});
        observation.finish(.{});
    }

    /// Run `body(vm, args...)` on this Engine's main worker. If we're
    /// already inside a fiber (nested call from inside an evaluation),
    /// reuse the surrounding fiber's claim identity via a fresh VM. If
    /// we're on a bare OS thread, spin up a one-shot main Worker so the
    /// body's `.busy` thunks yield through the standard fiber machinery
    /// instead of blocking the thread. The body's payload type is
    /// inferred from its return signature; void payloads work too.
    /// Any heap `Value` in `args` arrives through NATIVE memory (this frame /
    /// the Ctx struct below), which the precise collector never scans. Between
    /// evaluations nothing else roots such values (the repl guards its own via
    /// `extra_roots`), so the body's first safepoint could sweep them — e.g.
    /// the strict render's result attrset, with the collection budget already
    /// exhausted by the evaluation that produced it. Pin them as temp-roots of
    /// the body's VM for the duration.
    fn rootValueArgs(vm: *vm_mod.VM, args: anytype) void {
        inline for (args) |a| {
            if (@TypeOf(a) == Value) vm_force.rootKeep(vm, a);
        }
    }

    fn runWithVm(self: *Engine, comptime body: anytype, args: anytype) !ReturnPayload(@TypeOf(body)) {
        try self.requireActiveEvaluation();
        if (fiber_mod.currentFiber() != null) {
            var scratch = @import("base").arena.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            var vm = try self.initVm(0, scratch.allocator());
            defer vm.deinit();
            gc_controller.registerVm(gcContext(self), &vm);
            defer gc_controller.unregisterVm(gcContext(self), &vm);
            const gc_scope = vm_force.rootsBegin(&vm);
            defer vm_force.rootsEnd(&vm, gc_scope);
            rootValueArgs(&vm, args);
            const result = try @call(.auto, body, .{&vm} ++ args);
            if (comptime ReturnPayload(@TypeOf(body)) == Value) self.gcRootCrossingValue(result);
            return result;
        }
        const Args = @TypeOf(args);
        const Ret = ReturnPayload(@TypeOf(body));
        const Ctx = struct {
            ev: *Engine,
            body_args: Args,
            result: Ret = undefined,
            err: ?anyerror = null,

            fn entry(arg: *anyopaque) void {
                const ctx: *@This() = @ptrCast(@alignCast(arg));
                var scratch = @import("base").arena.ArenaAllocator.init(ctx.ev.allocator);
                defer scratch.deinit();
                var vm = ctx.ev.initVm(0, scratch.allocator()) catch |e| {
                    ctx.err = e;
                    return;
                };
                defer vm.deinit();
                gc_controller.registerVm(gcContext(ctx.ev), &vm);
                defer gc_controller.unregisterVm(gcContext(ctx.ev), &vm);
                const gc_scope = vm_force.rootsBegin(&vm);
                defer vm_force.rootsEnd(&vm, gc_scope);
                rootValueArgs(&vm, ctx.body_args);
                const result = @call(.auto, body, .{&vm} ++ ctx.body_args) catch |e| {
                    ctx.err = e;
                    return;
                };
                if (comptime Ret == Value) ctx.ev.gcRootCrossingValue(result);
                ctx.result = result;
            }
        };
        var ctx: Ctx = .{ .ev = self, .body_args = args };
        const worker = try self.ensureMainWorker();
        try worker.runTopLevel(Ctx.entry, @ptrCast(&ctx));
        if (ctx.err) |e| return e;
        return ctx.result;
    }

    fn ensureMainWorker(self: *Engine) !*worker_mod.Worker {
        if (self.execution.main_worker) |w| return w;
        const w = try worker_mod.Worker.init(
            self.allocator,
            &self.execution.scheduler,
            0,
            self,
            initVmForWorkerSlot,
        );
        self.execution.main_worker = w;
        // Register the collect callback now that `self` is at
        // its final address (init returns by value), and enable reclaim. The
        // collect runs at the forceThunk safepoint when allocation crosses
        // the byte threshold; at --workers>1 it stops the world (all workers
        // park at safepoints) before marking. Register worker 0 so the
        // collector can walk its fibers for roots.
        self.collection.workers[0].store(w, .release);
        self.collection.coordinator.install(&self.heap, &self.execution.scheduler, .{
            .context = self,
            .collect = gcCollect,
            .help_mark = gcHelpMark,
        });
        if (self.sources.env_map) |em|
            if (em.get("FIX_GC_NOREUSE") != null) self.heap.gcSetDisableReuse(true);
        if (self.sources.env_map) |em|
            if (em.get("FIX_GC_PAR_CAP")) |s| {
                if (std.fmt.parseInt(u32, s, 10)) |c| {
                    if (c >= 1) self.collection.parallel_cap = c;
                } else |_| {}
            };
        // FIX_GC_STEP_MB (validation): collect every N MB of fresh
        // allocation so the detector exercises every builtin loop.
        var step_bytes: u64 = 0;
        if (self.sources.env_map) |em| {
            if (em.get("FIX_GC_STEP_MB")) |s| {
                if (std.fmt.parseInt(u64, s, 10)) |mb| step_bytes = mb << 20 else |_| {}
            }
        }
        // Collection line: no collection runs until heap-reserved bytes
        // cross it (automatic `clamp(½·MemTotal, 256MB, 32GB)`, overridable
        // via `--gc-budget`; see `gc_controller.memoryBudget`).
        // On a roomy machine that line dwarfs the eval → never fires: zero
        // pauses AND zero tracking (lazy arming at line/2, see
        // `heap_collector.enableBudget`); on a tight machine it fires before the
        // eval OOMs. Override 0 = never collect (bump-only). FIX_GC_STEP_MB
        // keeps the eager validation path (tracking from the start).
        const budget = gc_controller.memoryBudget(gcContext(self));
        if (step_bytes > 0)
            heap_collector.enableCollect(&self.heap, budget, step_bytes)
        else if (budget > 0)
            heap_collector.enableBudget(&self.heap, budget, gc_controller.constrainedMode(gcContext(self), budget));
        return w;
    }

    fn gcCollect(ctx: *anyopaque, collector_id: u8) void {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        gc_controller.collect(gcContext(self), collector_id);
    }

    /// Replace the caller-held external root set (see
    /// `collection.extra_roots`). The repl passes its scope attrset + loose values
    /// here whenever they change; they stay rooted until replaced.
    pub fn gcSetExternalRoots(self: *Engine, roots: []const Value) !void {
        self.collection.extra_roots_mu.lock();
        defer self.collection.extra_roots_mu.unlock();
        try self.collection.extra_roots.ensureTotalCapacity(self.allocator, roots.len);
        self.collection.extra_roots.clearRetainingCapacity();
        self.collection.extra_roots.appendSliceAssumeCapacity(roots);
    }

    /// Root a value that is about to cross into NATIVE storage (a result
    /// sink, a runWithVm return) where the precise collector cannot see it.
    /// The publishing fiber unwinds right after, and other workers' straggler
    /// fibers can still park and run a pending collection — without this the
    /// finished value is sweepable the moment its fiber's stack is gone.
    /// Entries persist until the next `gcSetExternalRoots` (repl) replaces
    /// the set; a driver doing many evaluations retains one Value per result.
    fn gcRootCrossingValue(self: *Engine, value: Value) void {
        if (ObjectHeap.gcHeapId(value) == null) return;
        self.collection.extra_roots_mu.lock();
        defer self.collection.extra_roots_mu.unlock();
        // Like the remembered set, this is correctness metadata: failing to
        // record it permits a sweep of a live value.
        self.collection.extra_roots.append(self.allocator, value) catch
            @panic("gc external root append failed");
    }

    pub const CollectNowResult = struct {
        /// False when collection is disabled by policy (`--gc-budget=0`)
        /// or nothing has run yet.
        ran: bool,
        /// Number of actual mark/sweep cycles completed by this request. The
        /// first request may only arm lazy tracking.
        collections: u64,
        objects_freed: u64,
        live_bytes: u64,
        /// Append-store high-water retained for reuse; collection does not
        /// shrink these cursors, so presenting it as before/after is misleading.
        capacity_bytes: u64,
    };

    fn collectNowResult(self: *Engine) CollectNowResult {
        return .{
            .ran = false,
            .collections = 0,
            .objects_freed = 0,
            .live_bytes = 0,
            .capacity_bytes = self.heap.totalReservedBytes(),
        };
    }

    fn finishCollectNow(self: *Engine, result: *CollectNowResult, before: gc.LiveReport) void {
        const after = gc.liveReport(&self.heap.collection.report);
        result.ran = true;
        result.collections = after.collections -| before.collections;
        result.objects_freed = after.freed_objects -| before.freed_objects;
        result.live_bytes = after.live_bytes;
        result.capacity_bytes = self.heap.totalReservedBytes();
    }

    /// GC: run a stop-the-world collection right now, from outside
    /// any evaluation — the repl's between-inputs reclaim. Drives the same
    /// barrier + hook sequence as the in-eval safepoint (vm/force.zig): win
    /// the collector race, park every worker, collect, release. The first
    /// call arms reclaim tracking (`armLazy` — everything already allocated
    /// becomes the untracked old floor); later calls run real minors.
    ///
    /// Callable only between evaluations (no fiber may be mid-flight on the
    /// calling thread); helpers park at their safepoints as in any STW.
    pub fn collectNow(self: *Engine) CollectNowResult {
        var result = self.collectNowResult();
        // No hook yet (nothing evaluated) or reclaim disabled by policy
        // (threshold never armed): nothing to do.
        if (self.execution.main_worker == null) return result;
        if (self.heap.collection.threshold_bytes == std.math.maxInt(u64)) return result;
        if (!self.execution.scheduler.gcTryBeginCollection()) return result;
        const before = gc.liveReport(&self.heap.collection.report);
        self.execution.scheduler.gcWaitAllParked(0);
        // Invalidate the token-keyed thread-local caches (thunk memo, attr
        // IC) BEFORE marking: they root the previous evaluation's hottest
        // values (markRoots must treat current-token entries as live), but
        // between evaluations they are semantically dead — without this the
        // last input's whole result graph gets promoted instead of freed.
        // Safe here: the world is stopped. In-eval collections instead bump
        // the token after the sweep (`afterCollect`).
        self.heap.token = runtime.heap.next_heap_token.fetchAdd(1, .monotonic);
        heap_collector.runCollect(&self.heap, 0);
        self.execution.scheduler.gcEndCollection(0);
        self.finishCollectNow(&result, before);
        return result;
    }

    /// Like `collectNow`, but runs a MAJOR (full) collection — reclaims the
    /// tenured old-generation garbage a minor leaves behind. Used by the repl
    /// between inputs so a heavy input's whole result graph is reclaimed (a
    /// minor only reclaims the young survivors, so under parallel workers, where
    /// more objects tenure, repl memory would otherwise ratchet up). Same STW
    /// dance + cache-invalidating token bump as `collectNow`.
    pub fn collectMajorNow(self: *Engine) CollectNowResult {
        var result = self.collectNowResult();
        if (self.execution.main_worker == null) return result;
        if (self.heap.collection.threshold_bytes == std.math.maxInt(u64)) return result;
        if (!self.execution.scheduler.gcTryBeginCollection()) return result;
        const before = gc.liveReport(&self.heap.collection.report);
        self.execution.scheduler.gcWaitAllParked(0);
        self.heap.token = runtime.heap.next_heap_token.fetchAdd(1, .monotonic);
        gc_controller.collectMajor(gcContext(self), 0);
        self.execution.scheduler.gcEndCollection(0);
        self.finishCollectNow(&result, before);
        return result;
    }

    /// Full collection while the calling evaluator worker is already stopped
    /// in native code (currently the debugger UI). The caller remains a live
    /// evaluation root, so do not pre-invalidate token-keyed caches as the
    /// between-input collector does; `collectMajor` scans them and advances the
    /// token after sweeping through the ordinary in-evaluation path.
    fn collectMajorAtSafepoint(self: *Engine, collector_id: u8) CollectNowResult {
        var result = self.collectNowResult();
        if (self.execution.main_worker == null) return result;
        if (self.heap.collection.threshold_bytes == std.math.maxInt(u64)) return result;
        if (!self.execution.scheduler.gcTryBeginCollection()) return result;
        const before = gc.liveReport(&self.heap.collection.report);
        self.execution.scheduler.gcWaitAllParked(collector_id);
        gc_controller.collectMajor(gcContext(self), collector_id);
        self.execution.scheduler.gcEndCollection(collector_id);
        self.finishCollectNow(&result, before);
        return result;
    }

    fn gcHelpMark(ctx: *anyopaque, worker_id: u8) void {
        const self: *Engine = @ptrCast(@alignCast(ctx));
        gc_controller.helpMark(gcContext(self), worker_id);
    }

    fn importValue(context: *anyopaque, caller: *VM, path: []const u8, parent_depth: u32) anyerror!Value {
        const self: *Engine = @ptrCast(@alignCast(context));
        return self.importPath(path, parent_depth, caller);
    }

    fn importPath(self: *Engine, path: []const u8, parent_depth: u32, debug_parent: *VM) !Value {
        var resolved = try self.resolveHostPath(path);
        defer resolved.deinit(self.allocator);
        return self.importResolvedPath(resolved.slice(), parent_depth, debug_parent);
    }

    fn importResolvedPath(self: *Engine, path: []const u8, parent_depth: u32, debug_parent: *VM) anyerror!Value {
        const entry = try self.sources.imports.lookupOrCreate(self.allocator, path, debug_parent.debug.import_replay);
        return self.forceImportEntry(path, entry, parent_depth, debug_parent);
    }

    fn forceImportEntry(
        self: *Engine,
        path: []const u8,
        entry: *imports_mod.ImportEntry,
        parent_depth: u32,
        debug_parent: *VM,
    ) anyerror!Value {
        const me = currentImportClaimer();
        const real_demand = !debug_parent.speculation.active;
        while (true) {
            switch (entry.future.tryClaim(me)) {
                .already_resolved => {
                    try vm_force.observeEffectGroup(debug_parent, entry.effect_group, real_demand);
                    return entry.result;
                },
                .blackhole => return error.ImportCycle,
                .errored => {
                    try vm_force.observeEffectGroup(debug_parent, entry.effect_group, real_demand);
                    const failure = entry.failure.?;
                    debug_parent.executionContext().install(failure);
                    if (real_demand)
                        vm_errors.captureDemandErrorTrace(debug_parent, failure.err()) catch {};
                    return failure.err();
                },
                .busy => {
                    const inner = fiber_mod.currentFiber() orelse
                        @panic("import entry became busy outside an evaluator fiber");
                    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
                    wf.parkOn(&entry.future);
                    continue;
                },
                .claimed => {
                    const effect_checkpoint = debug_parent.effect_journal.items.len;
                    const value = self.compileImportPath(path, parent_depth, debug_parent) catch |err| {
                        if (debug_parent.speculation.active and !isTransientImportError(err)) {
                            entry.effect_group = self.effects.makeGroup(debug_parent.effect_journal.items[effect_checkpoint..]) catch {
                                self.publishImportFailure(entry, debug_parent, error.OutOfMemory);
                                return error.OutOfMemory;
                            };
                        }
                        self.publishImportFailure(entry, debug_parent, err);
                        return err;
                    };
                    if (debug_parent.speculation.active) {
                        entry.effect_group = self.effects.makeGroup(debug_parent.effect_journal.items[effect_checkpoint..]) catch {
                            self.publishImportFailure(entry, debug_parent, error.OutOfMemory);
                            return error.OutOfMemory;
                        };
                    }
                    entry.result = value;
                    entry.future.publish();
                    return value;
                },
            }
        }
    }

    fn publishImportFailure(self: *Engine, entry: *imports_mod.ImportEntry, vm: *VM, err: anyerror) void {
        _ = self;
        switch (err) {
            error.OutOfMemory, error.StackOverflow, error.SpeculativeBail => {
                const ctx = vm.executionContext();
                if (ctx.pending()) |failure| if (failure.err() != err) ctx.clearFailure();
                entry.effect_group = 0;
                entry.future.reset();
                return;
            },
            else => {},
        }
        const ctx = vm.executionContext();
        if (ctx.pending() == null) vm_errors.captureErrorTrace(vm, err) catch {};
        entry.failure = ctx.pending() orelse
            runtime.failure.FailureRef.degraded(err);
        entry.future.publishErrored();
    }

    fn compileImportPath(self: *Engine, path: []const u8, parent_depth: u32, debug_parent: *VM) anyerror!Value {
        const stable_path = try self.allocator.dupe(u8, path);
        defer self.allocator.free(stable_path);

        var observation = self.observer.begin(&import_observation, .{ .subject = .{ .path = stable_path } });
        defer observation.cancel();

        const source = if (corepkgs.source(stable_path)) |core_source|
            core_source
        else
            self.sources.files.readFile(stable_path) catch |err| switch (err) {
                error.IsDir => return self.importDirectory(stable_path, parent_depth, debug_parent),
                else => return err,
            };
        const source_base = std.fs.path.dirname(stable_path) orelse "/";
        const value = try self.evaluateSource(source, source_base, stable_path, null, parent_depth, debug_parent);
        observation.finish(.{});
        return value;
    }

    /// Explicit post-registration phase: compiler code reports the canonical
    /// chunk selected for a compiled body here, after registry mutation has
    /// completed. Import discovery and debugger overlay placement are evaluator
    /// orchestration, not hidden side effects of `ChunkRegistry.register`.
    fn chunkRegistered(self: *Engine, chunk_id: ChunkId) void {
        const chunk = self.registry.get(chunk_id) orelse return;
        for (chunk.constants) |value| {
            if (value.isPath()) prefetchPathConst(self, value.asInternId());
        }
        if (self.debugger.breakpoints) |*breakpoints| {
            breakpoints.placeRegisteredChunk(chunk_id, chunk);
        }
    }

    /// Import-path discovery in the evaluator's explicit chunk-registration
    /// phase (`FIX_IMPORT_PREFETCH`):
    /// called for every `.path` constant of every freshly compiled chunk,
    /// from whichever worker ran the compile. Filters to `.nix` files
    /// because directory constants are not necessarily imports, dedups per
    /// intern id, spends the submission
    /// budget, and hands the path to the spec lane.
    fn prefetchPathConst(self: *Engine, path_id: types.InternId) void {
        const text = self.intern.get(path_id);
        if (!std.mem.endsWith(u8, text, ".nix")) return;
        {
            self.sources.prefetch.mu.lock();
            defer self.sources.prefetch.mu.unlock();
            if (self.sources.prefetch.budget == 0) return;
            const gop = self.sources.prefetch.seen.getOrPut(self.allocator, path_id) catch return;
            if (gop.found_existing) return;
            self.sources.prefetch.budget -= 1;
        }
        _ = self.execution.scheduler.submit(.{ .import_prefetch = path_id }, worker_id_mod.currentId());
    }

    fn scopedImportValue(context: *anyopaque, caller: *VM, scope: Value, path: []const u8, parent_depth: u32) anyerror!Value {
        const self: *Engine = @ptrCast(@alignCast(context));
        return self.scopedImportPath(scope, path, parent_depth, caller);
    }

    fn scopedImportPath(self: *Engine, scope: Value, path: []const u8, parent_depth: u32, debug_parent: *VM) !Value {
        var resolved = try self.resolveHostPath(path);
        defer resolved.deinit(self.allocator);
        return self.scopedImportResolvedPath(scope, resolved.slice(), parent_depth, debug_parent);
    }

    fn scopedImportResolvedPath(
        self: *Engine,
        scope: Value,
        path: []const u8,
        parent_depth: u32,
        debug_parent: *VM,
    ) anyerror!Value {
        const stable_path = try self.allocator.dupe(u8, path);
        defer self.allocator.free(stable_path);

        var cursor = currentExecutionContext().scoped_import_top;
        while (cursor) |node| {
            if (std.mem.eql(u8, node.path, stable_path)) return error.ImportCycle;
            cursor = node.next;
        }
        var frame: execution.ScopedImportFrame = .{ .path = stable_path, .next = currentExecutionContext().scoped_import_top };
        currentExecutionContext().scoped_import_top = &frame;
        defer currentExecutionContext().scoped_import_top = frame.next;

        var observation = self.observer.begin(&import_observation, .{ .subject = .{ .path = stable_path } });
        defer observation.cancel();

        const source = if (corepkgs.source(stable_path)) |core_source|
            core_source
        else
            self.sources.files.readFile(stable_path) catch |err| switch (err) {
                error.IsDir => return self.scopedImportDirectory(scope, stable_path, parent_depth, debug_parent),
                else => return err,
            };
        const source_base = std.fs.path.dirname(stable_path) orelse "/";
        const value = try self.evaluateSource(source, source_base, stable_path, scope, parent_depth, debug_parent);
        observation.finish(.{});
        return value;
    }

    fn importDirectory(self: *Engine, path: []const u8, parent_depth: u32, debug_parent: *VM) anyerror!Value {
        const default_path = try std.fs.path.resolve(self.allocator, &.{ path, "default.nix" });
        defer self.allocator.free(default_path);
        return self.importResolvedPath(default_path, parent_depth, debug_parent);
    }

    fn scopedImportDirectory(
        self: *Engine,
        scope: Value,
        path: []const u8,
        parent_depth: u32,
        debug_parent: *VM,
    ) anyerror!Value {
        const default_path = try std.fs.path.resolve(self.allocator, &.{ path, "default.nix" });
        defer self.allocator.free(default_path);
        return self.scopedImportResolvedPath(scope, default_path, parent_depth, debug_parent);
    }

    fn findFile(context: *anyopaque, name: []const u8) anyerror!Value {
        const self: *Engine = @ptrCast(@alignCast(context));
        return self.findFileInDefaultSearchPath(name);
    }

    fn getEnv(context: *anyopaque, name: []const u8) anyerror![]const u8 {
        const self: *Engine = @ptrCast(@alignCast(context));
        const env_map = self.sources.env_map orelse return "";
        return env_map.get(name) orelse "";
    }

    fn findFileInDefaultSearchPath(self: *Engine, name: []const u8) !Value {
        return self.sources.search_paths.findFile(self.allocator, &self.sources.files, &self.intern, name);
    }

    fn ensureBuiltins(self: *Engine) !Value {
        if (self.builtins_value) |value| return value;
        // Create the shared `[]`/`{}` singletons as the heap's first objects,
        // before builtins allocate and before any worker arms the GC — so they
        // land below `bootstrap_end` and stay pinned for the eval's lifetime.
        try self.heap.ensureEmptySingletons();
        const nix_path = try self.sources.search_paths.toNixPath(self.allocator);
        defer self.allocator.free(nix_path);
        const value = try builtins.buildAttrSet(&self.intern, &self.heap, nix_path, self.store.realization.store_dir);
        self.builtins_value = value;
        return value;
    }

    pub fn resolveHostPath(self: *Engine, path: []const u8) !search_path_mod.ResolvedPath {
        if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://") or std.mem.startsWith(u8, path, "file://"))
            return .{ .borrowed = path };
        if (std.fs.path.isAbsolute(path)) return .{ .borrowed = path };

        const base_path = self.sources.base_path orelse return error.RelativePath;
        return .{ .owned = try std.fs.path.resolve(self.allocator, &.{ base_path, path }) };
    }

    pub fn writeValue(self: *Engine, writer: *std.Io.Writer, value: Value) !void {
        try self.requireActiveEvaluation();
        var observation = self.observer.begin(&render_observation, .{ .subject = .{ .text = "result" } });
        defer observation.cancel();
        try self.runWithVm(writeValueBody, .{ self, writer, value });
        observation.finish(.{});
    }
};

/// Helper worker loop. Owns an on-demand fiber pool (no fixed size);
/// each fiber has its own VM and can be parked mid-evaluation when it
/// hits a `.busy` thunk. The Worker drives the fiber drain loop — see
/// `worker.zig`. Errors during speculation are swallowed inside the
/// fiber's entry; the thunk's own `reset()` on failure surfaces the
/// error to a future genuine caller.
fn helperLoop(worker_id: u8, sched: *Scheduler, ev: *Engine) void {
    const worker = worker_mod.Worker.init(
        ev.allocator,
        sched,
        worker_id,
        ev,
        initVmForWorkerSlot,
    ) catch {
        // Still pass the quiescence barrier so peers don't wait forever.
        sched.awaitHelpersQuiescent();
        return;
    };
    // GC: register this helper so the collector can walk its fibers
    // for roots. Registration happens before `run()` (before any user-object
    // allocation), and the collector only reads the registry at a stop-the-
    // world where this worker is parked.
    ev.collection.workers[worker_id].store(worker, .release);
    worker.run();
    // Wait until ALL helpers have stopped forcing before destroying any
    // fibers — a still-running helper could resolve a thunk and wake a
    // just-freed enrolled fiber (shutdown UAF). See awaitHelpersQuiescent.
    sched.awaitHelpersQuiescent();
    // Unregister before deinit so a late collection never scans freed fibers.
    // (After awaitHelpersQuiescent no helper is still forcing, so no
    // collection can be triggered past this point, but keep the invariant.)
    ev.collection.workers[worker_id].store(null, .release);
    worker.deinit();
}

fn releaseForBuild(ev: *Engine, after_release: ?ReleaseAction) void {
    lifecycle.finishRelease(ev);
    if (after_release) |action| action.run(action.context);
}

fn initVmForWorkerSlot(ctx: *anyopaque, worker_id: u8, _: u32, scratch: std.mem.Allocator) anyerror!VM {
    const ev: *Engine = @ptrCast(@alignCast(ctx));
    return ev.initVm(worker_id, scratch);
}

fn ReturnPayload(comptime F: type) type {
    const ret = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload,
        else => ret,
    };
}

/// Shim that lets `Engine.writeValue` reuse the same `runWithVm`
/// machinery as the VM-bodied entries. The output formatter walks
/// values via `Engine.forceValue` for nested thunks; the surrounding
/// fiber's identity threads through via initVm, so we don't need a
/// fresh VM here ourselves.
fn writeValueBody(_: *VM, ev: *Engine, writer: *std.Io.Writer, value: Value) !void {
    return eval_print.writeValue(valuePrintHost(ev), writer, value);
}

fn writeRawValueBody(vm: *VM, writer: *std.Io.Writer, value: Value) !void {
    const string_value = try vm_strings.coerceLanguageStringValue(vm, value);
    try writer.writeAll(try vm_strings.stringBytes(vm, string_value));
}

fn valuePrintHost(ev: *Engine) eval_print.Host {
    return .{
        .allocator = ev.allocator,
        .heap = &ev.heap,
        .intern = &ev.intern,
        .value_color = ev.value_color,
        .context = ev,
        .force_value = printForceValue,
    };
}

fn chunkRegistrationSink(ev: *Engine) compiler_mod.ChunkRegistrationSink {
    return .{ .context = ev, .registered = chunkRegisteredThunk };
}

fn chunkRegisteredThunk(context: *anyopaque, chunk_id: ChunkId) void {
    const ev: *Engine = @ptrCast(@alignCast(context));
    ev.chunkRegistered(chunk_id);
}

fn printForceValue(context: *anyopaque, value: Value) anyerror!Value {
    const ev: *Engine = @ptrCast(@alignCast(context));
    return ev.forceValue(value);
}

fn mergeNestedEffects(parent: ?*VM, nested: *VM) !void {
    const outer = parent orelse return;
    // A nested import VM has its own effect epoch. Propagate the fact that it
    // performed an effect even on the demand path, so the caller's bytecode
    // result cannot enter the pure-thunk memo and suppress a later call.
    if (nested.effect_epoch != 0) outer.effect_epoch +%= 1;
    if (!outer.speculation.active or nested.effect_journal.items.len == 0) return;
    try outer.effect_journal.appendSlice(outer.allocator, nested.effect_journal.items);
}

fn isTransientImportError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory, error.StackOverflow, error.SpeculativeBail => true,
        else => false,
    };
}

fn currentImportClaimer() future_mod.ClaimerId {
    const inner = fiber_mod.currentFiber() orelse return future_mod.invalid_claimer;
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
    return wf.ctx.claimer_id;
}

fn currentExecutionContext() *execution.ExecutionContext {
    const inner = fiber_mod.currentFiber() orelse
        @panic("scoped import ran outside an evaluator fiber");
    const wf: *worker_mod.WorkerFiber = @fieldParentPtr("inner", inner);
    return &wf.ctx;
}

fn gcContext(ev: *Engine) gc_controller.Context {
    return .{
        .allocator = ev.allocator,
        .heap = &ev.heap,
        .registry = &ev.registry,
        .scheduler = &ev.execution.scheduler,
        .realization = &ev.store.realization,
        .imports = &ev.sources.imports,
        .builtins_value = &ev.builtins_value,
        .env_map = ev.sources.env_map,
        .worker_count = ev.execution.worker_count,
        .gc_budget_bytes = ev.collection.budget_bytes,
        .tracer = &ev.collection.tracer,
        .import_vms = &ev.collection.import_vms,
        .import_vms_mu = &ev.collection.import_vms_mu,
        .workers = ev.collection.workers,
        .chunks_scanned = &ev.collection.chunks_scanned,
        .extra_roots = &ev.collection.extra_roots,
        .parallel_cap = ev.collection.parallel_cap,
        .observer = ev.observer,
    };
}

const TestEffectCapture = struct {
    count: usize = 0,
    lengths: [8]usize = undefined,
    messages: [8][128]u8 = undefined,

    fn emit(raw: ?*anyopaque, _: effects_mod.Kind, text: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (self.count == self.messages.len or text.len > self.messages[0].len)
            @panic("effect capture overflow");
        self.lengths[self.count] = text.len;
        @memcpy(self.messages[self.count][0..text.len], text);
        self.count += 1;
    }

    fn message(self: *const @This(), index: usize) []const u8 {
        return self.messages[index][0..self.lengths[index]];
    }
};

test "speculative effects wait for demand and fire exactly once" {
    var capture: TestEffectCapture = .{};
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    var ev_live = true;
    defer if (ev_live) ev.deinit();
    ev.setEffectSink(.{ .context = &capture, .emit_fn = TestEffectCapture.emit });

    const attrs = try ev.evaluate(
        \\{
        \\  held = (builtins.trace "held" 40) + 2;
        \\  bad = (builtins.seq (builtins.trace "before-error" null) (builtins.throw "boom")) + 0;
        \\  untouched = builtins.trace "untouched" 0;
        \\}
    );
    const attrs_id = attrs.asObjectId();

    const held = try ev.heap.getAttrValue(attrs_id, try ev.intern.intern("held"));
    try std.testing.expect(held.isThunk());
    const held_spec = try ev.runWithVm(vm_force.forceValueSpeculative, .{held});
    try std.testing.expectEqual(@as(i64, 42), held_spec.asInt());
    try std.testing.expectEqual(@as(usize, 0), capture.count);

    const held_demand = try ev.forceValue(held);
    try std.testing.expectEqual(@as(i64, 42), held_demand.asInt());
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("held", capture.message(0));
    _ = try ev.forceValue(held);
    try std.testing.expectEqual(@as(usize, 1), capture.count);

    // Effects are retained on cached failures too: demand replays the error
    // and commits the trace that preceded it.
    const bad = try ev.heap.getAttrValue(attrs_id, try ev.intern.intern("bad"));
    try std.testing.expectError(error.NixThrow, ev.runWithVm(vm_force.forceValueSpeculative, .{bad}));
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectError(error.NixThrow, ev.forceValue(bad));
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqualStrings("before-error", capture.message(1));
    try std.testing.expectEqualStrings("boom", ev.getTrace().message.?);
    // A second genuine demand observes the same terminal failure. It must
    // neither re-evaluate the body nor recommit the failure's effect group.
    try std.testing.expectError(error.NixThrow, ev.forceValue(bad));
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqualStrings("boom", ev.getTrace().message.?);

    // Work that remains purely speculative never becomes language-visible.
    const untouched = try ev.heap.getAttrValue(attrs_id, try ev.intern.intern("untouched"));
    _ = try ev.runWithVm(vm_force.forceValueSpeculative, .{untouched});
    try std.testing.expectEqual(@as(usize, 2), capture.count);
    ev.deinit();
    ev_live = false;
    try std.testing.expectEqual(@as(usize, 2), capture.count);
}

test "speculative imported traces are committed by their demander" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "traced.nix",
        .data = "builtins.trace \"imported\" 5\n",
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "traced.nix",
    });
    defer std.testing.allocator.free(file_path);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{{ held = import {s}; }}", .{file_path});
    defer std.testing.allocator.free(source);

    var capture: TestEffectCapture = .{};
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 0 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    ev.setEffectSink(.{ .context = &capture, .emit_fn = TestEffectCapture.emit });

    const attrs = try ev.evaluate(source);
    const held = try ev.heap.getAttrValue(attrs.asObjectId(), try ev.intern.intern("held"));
    const spec = try ev.runWithVm(vm_force.forceValueSpeculative, .{held});
    try std.testing.expectEqual(@as(i64, 5), spec.asInt());
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    const demanded = try ev.forceValue(held);
    try std.testing.expectEqual(@as(i64, 5), demanded.asInt());
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("imported", capture.message(0));
}

test "nested speculative thunk failure retains its message and origin" {
    const source =
        \\rec {
        \\  bad = outer;
        \\  leaf = builtins.throw "deep speculative failure";
        \\  middle = builtins.seq leaf null;
        \\  outer = builtins.seq middle null;
        \\}
    ;

    // Keep both Engines live so their trace views can be compared directly.
    // workers=1 takes only the demand path; workers=8 first makes the entire
    // nested chain terminal through forceValueSpeculative, then observes it.
    var serial = try Engine.init(std.testing.allocator, .{ .worker_count = 1 });
    defer serial.deinit();
    const serial_attrs = try serial.evaluate(source);
    const serial_bad = try serial.heap.getAttrValue(serial_attrs.asObjectId(), try serial.intern.intern("bad"));
    try std.testing.expectError(error.NixThrow, serial.forceValue(serial_bad));
    const serial_trace = serial.getTrace();
    try std.testing.expectEqualStrings("deep speculative failure", serial_trace.message.?);

    var parallel = try Engine.init(std.testing.allocator, .{ .worker_count = 8 });
    defer parallel.deinit();
    const parallel_attrs = try parallel.evaluate(source);
    const parallel_bad = try parallel.heap.getAttrValue(parallel_attrs.asObjectId(), try parallel.intern.intern("bad"));
    const parallel_leaf = try parallel.heap.getAttrValue(parallel_attrs.asObjectId(), try parallel.intern.intern("leaf"));
    const parallel_middle = try parallel.heap.getAttrValue(parallel_attrs.asObjectId(), try parallel.intern.intern("middle"));
    const parallel_outer = try parallel.heap.getAttrValue(parallel_attrs.asObjectId(), try parallel.intern.intern("outer"));
    try std.testing.expectError(error.NixThrow, parallel.runWithVm(vm_force.forceValueSpeculative, .{parallel_bad}));

    // Propagation through pass-through/ancestor thunks is pointer sharing,
    // not a new diagnostic capture per level.
    const bad_failure = parallel.heap.getThunkAssumeValid(parallel_bad.asObjectId()).cachedFailure();
    const leaf_failure = parallel.heap.getThunkAssumeValid(parallel_leaf.asObjectId()).cachedFailure();
    const middle_failure = parallel.heap.getThunkAssumeValid(parallel_middle.asObjectId()).cachedFailure();
    const outer_failure = parallel.heap.getThunkAssumeValid(parallel_outer.asObjectId()).cachedFailure();
    try std.testing.expect(bad_failure.eql(leaf_failure));
    try std.testing.expect(bad_failure.eql(middle_failure));
    try std.testing.expect(bad_failure.eql(outer_failure));

    try std.testing.expectError(error.NixThrow, parallel.forceValue(parallel_bad));
    const parallel_trace = parallel.getTrace();
    try std.testing.expectEqualStrings("deep speculative failure", parallel_trace.message.?);

    // Diagnostic parity is deliberately stronger than checking the message:
    // cached observation must materialize the origin captured by the helper,
    // not synthesize a new stack rooted at the later demander.
    try std.testing.expectEqual(serial_trace.frames.items.len, parallel_trace.frames.items.len);
    for (serial_trace.frames.items, parallel_trace.frames.items) |serial_frame, parallel_frame| {
        try std.testing.expectEqual(serial_frame.kind, parallel_frame.kind);
        try std.testing.expectEqualStrings(serial_frame.message, parallel_frame.message);
        try std.testing.expectEqual(serial_frame.diagnostic != null, parallel_frame.diagnostic != null);
        if (serial_frame.diagnostic) |serial_diag| {
            const parallel_diag = parallel_frame.diagnostic.?;
            try std.testing.expectEqual(serial_diag.line, parallel_diag.line);
            try std.testing.expectEqual(serial_diag.column, parallel_diag.column);
            try std.testing.expectEqual(serial_diag.offset, parallel_diag.offset);
            try std.testing.expectEqual(serial_diag.len, parallel_diag.len);
        }
    }
    var found_leaf_origin = false;
    for (parallel_trace.frames.items) |frame| {
        if (frame.diagnostic) |diag| {
            if (diag.line == 3) found_leaf_origin = true;
        }
    }
    try std.testing.expect(found_leaf_origin);
}

test "cached failure adds continuation only for genuine demand" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 8 });
    defer ev.deinit();
    const attrs = try ev.evaluate(
        \\rec {
        \\  leaf = builtins.throw "frozen helper origin";
        \\  consume = x: builtins.seq x 0;
        \\  speculativeObserver = consume leaf;
        \\  demandObserver = (x: consume x) leaf;
        \\}
    );
    const attrs_id = attrs.asObjectId();
    const leaf = try ev.heap.getAttrValue(attrs_id, try ev.intern.intern("leaf"));
    const speculative_observer = try ev.heap.getAttrValue(attrs_id, try ev.intern.intern("speculativeObserver"));
    const demand_observer = try ev.heap.getAttrValue(attrs_id, try ev.intern.intern("demandObserver"));

    // Freeze the origin first, as a helper would. A later speculative cached
    // observer propagates only its identity: it must not materialize into the
    // shared demand trace or mutate the immutable origin with its own frames.
    try std.testing.expectError(error.NixThrow, ev.runWithVm(vm_force.forceValueSpeculative, .{leaf}));
    const leaf_failure = ev.heap.getThunkAssumeValid(leaf.asObjectId()).cachedFailure();
    ev.report.trace.clear();
    try std.testing.expectError(error.NixThrow, ev.runWithVm(vm_force.forceValueSpeculative, .{speculative_observer}));
    try std.testing.expect(ev.getTrace().message == null);
    try std.testing.expectEqual(@as(usize, 0), ev.getTrace().frames.items.len);
    const speculative_failure = ev.heap.getThunkAssumeValid(speculative_observer.asObjectId()).cachedFailure();
    try std.testing.expect(leaf_failure.eql(speculative_failure));

    // Genuine demand reaches the same cached leaf through frames that did not
    // exist when the helper froze the origin. The rendered trace must contain
    // both the immutable leaf location and at least one such continuation.
    try std.testing.expectError(error.NixThrow, ev.forceValue(demand_observer));
    try std.testing.expectEqualStrings("frozen helper origin", ev.getTrace().message.?);
    var found_origin = false;
    var found_demand_continuation = false;
    for (ev.getTrace().frames.items) |frame| {
        const diag = frame.diagnostic orelse continue;
        if (diag.line == 2) found_origin = true;
        if (diag.line == 3 or diag.line == 5) found_demand_continuation = true;
    }
    try std.testing.expect(found_origin);
    try std.testing.expect(found_demand_continuation);
}

test "speculative error contexts preserve order and original cause" {
    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 8 });
    defer ev.deinit();
    const attrs = try ev.evaluate(
        \\{
        \\  ordered = builtins.addErrorContext "outer context"
        \\    (builtins.addErrorContext "inner context"
        \\      (builtins.throw "ordered origin"));
        \\  messageFailure = builtins.addErrorContext
        \\    (builtins.throw "context construction failed")
        \\    (builtins.throw "preserved origin");
        \\}
    );
    const attrs_id = attrs.asObjectId();

    const ordered = try ev.heap.getAttrValue(attrs_id, try ev.intern.intern("ordered"));
    try std.testing.expectError(error.NixThrow, ev.runWithVm(vm_force.forceValueSpeculative, .{ordered}));
    try std.testing.expectError(error.NixThrow, ev.forceValue(ordered));
    try std.testing.expectEqualStrings("ordered origin", ev.getTrace().message.?);
    var contexts: [2][]const u8 = undefined;
    var context_count: usize = 0;
    for (ev.getTrace().frames.items) |frame| {
        if (frame.kind != .context) continue;
        if (context_count < contexts.len) contexts[context_count] = frame.message;
        context_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), context_count);
    try std.testing.expectEqualStrings("inner context", contexts[0]);
    try std.testing.expectEqualStrings("outer context", contexts[1]);

    const message_failure = try ev.heap.getAttrValue(attrs_id, try ev.intern.intern("messageFailure"));
    try std.testing.expectError(error.NixThrow, ev.runWithVm(vm_force.forceValueSpeculative, .{message_failure}));
    try std.testing.expectError(error.NixThrow, ev.forceValue(message_failure));
    try std.testing.expectEqualStrings("preserved origin", ev.getTrace().message.?);
    for (ev.getTrace().frames.items) |frame| {
        try std.testing.expect(std.mem.indexOf(u8, frame.message, "context construction failed") == null);
    }
}

test "speculative nested import failure stays scoped and cached" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "failure.nix",
        .data = "builtins.throw \"import failure\"\n",
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const file_path = try std.fs.path.resolve(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "failure.nix",
    });
    defer std.testing.allocator.free(file_path);
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  handled = builtins.seq
        \\    (builtins.tryEval (import {s}))
        \\    (builtins.throw "failure after handled import");
        \\  cached = import {s};
        \\}}
    , .{ file_path, file_path });
    defer std.testing.allocator.free(source);

    var ev = try Engine.init(std.testing.allocator, .{ .worker_count = 8 });
    defer ev.deinit();
    ev.setFileIo(std.testing.io);
    const attrs = try ev.evaluate(source);
    const attrs_id = attrs.asObjectId();

    // The imported throw is caught inside the speculative thunk. Its carrier
    // must be cleared before the later, unrelated throw becomes sticky.
    const handled = try ev.heap.getAttrValue(attrs_id, try ev.intern.intern("handled"));
    try std.testing.expectError(error.NixThrow, ev.runWithVm(vm_force.forceValueSpeculative, .{handled}));
    try std.testing.expectError(error.NixThrow, ev.forceValue(handled));
    try std.testing.expectEqualStrings("failure after handled import", ev.getTrace().message.?);

    // The same ImportEntry is now terminal. A second speculative thunk that
    // observes it must borrow and publish the original imported failure.
    const cached = try ev.heap.getAttrValue(attrs_id, try ev.intern.intern("cached"));
    try std.testing.expectError(error.NixThrow, ev.runWithVm(vm_force.forceValueSpeculative, .{cached}));
    try std.testing.expectError(error.NixThrow, ev.forceValue(cached));
    try std.testing.expectEqualStrings("import failure", ev.getTrace().message.?);
    var found_import_origin = false;
    for (ev.getTrace().frames.items) |frame| {
        if (frame.source_path) |path| {
            if (std.mem.eql(u8, path, file_path)) found_import_origin = true;
        }
    }
    try std.testing.expect(found_import_origin);
}

test {
    _ = @import("eval/tests.zig");
}
