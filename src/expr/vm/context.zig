//! Tail-calling bytecode virtual machine.
//!
//! Each worker thread gets its own VM instance. The VM executes bytecode chunks
//! in a loop until they return. Tail calls are optimized by reusing the current
//! frame instead of pushing a new one.
//!
//! Architecture:
//!   - Direct-threaded dispatch via switch statement
//!   - Value stack (growable, contiguous memory)
//!   - Frame stack (call frames with return info)
//!   - Atomic thunk integration for lazy evaluation

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ChunkId = types.ChunkId;
const ObjectId = types.ObjectId;
const bytecode_mod = @import("../bytecode.zig");
const build_options = @import("build_options");
const chunk = bytecode_mod.chunk;
const Chunk = chunk.Chunk;
const ChunkRegistry = chunk.ChunkRegistry;
const InternTable = @import("runtime").intern.InternTable;
const VmRuntime = @import("../eval/workers/vm_runtime.zig").Runtime;
const heap_mod = @import("runtime").heap;
const ObjectHeap = heap_mod.ObjectHeap;
const FileCache = @import("store").FileCache;
const FetchService = @import("fetchers").FetchService;
const RealizationStore = @import("store").RealizationStore;
const eval_trace = @import("../observ.zig").trace;
const observ = @import("base").observ;
const VmTrace = @import("trace_log.zig").VmTrace;
const worker_id_mod = @import("base").worker_id;
const DeferredTable = @import("../compiler/deferred_table.zig").Table;
const ChunkRegistrationSink = @import("../compiler/context.zig").ChunkRegistrationSink;
const ThunkTrace = @import("../probe.zig").thunk_trace.ThunkTrace;
const LanguagePolicy = @import("../policy.zig").LanguagePolicy;
const effects_mod = @import("../effects.zig");

pub const exec_context = @import("../eval/workers/context.zig");
pub const ExecutionContext = exec_context.ExecutionContext;

pub const thunks_log_enabled = build_options.thunks_log;
const SpinMutex = @import("base").sync.SpinMutex;
const vma = @import("runtime").mem_tag.vma;
const PatternCache = @import("../support.zig").regex.PatternCache;
const FiberExecutor = @import("../eval/workers/port.zig").FiberExecutor;

pub const Driver = struct {
    eval: *const fn (*VM, ChunkId) anyerror!Value,
};

/// Reusable value and frame stacks. Pooling bounds storage by concurrent VMs.
/// Buffers return dirty; consumers and GC scans are bounded by `sp` and
/// `frames_len`.
pub const BufferPool = struct {
    allocator: std.mem.Allocator,
    mu: SpinMutex = .{},
    list: std.ArrayListUnmanaged(Buffers) = .empty,

    // These are large, mostly-sparse reservations. Give them an alignment
    // above the page size so BlockCacheAllocator sends them directly to its
    // ordinary mmap-backed allocator instead of eagerly prefaulting the whole
    // capacity from the hugetlb pool. The VM keeps the enlarged correctness
    // limits while ordinary evaluations pay only for pages they touch.
    pub const buffer_alignment: std.mem.Alignment = .fromByteUnits(std.heap.page_size_min * 2);
    pub const ValueStack = []align(buffer_alignment.toByteUnits()) Value;
    pub const FrameStack = []align(buffer_alignment.toByteUnits()) Frame;
    pub const Buffers = struct { stack: ValueStack, frames: FrameStack };

    pub fn init(allocator: std.mem.Allocator) BufferPool {
        return .{ .allocator = allocator };
    }

    /// All VMs must be dead (buffers released or freed) before this.
    pub fn deinit(self: *BufferPool) void {
        for (self.list.items) |bufs| {
            self.allocator.free(bufs.stack);
            self.allocator.free(bufs.frames);
        }
        self.list.deinit(self.allocator);
    }

    pub fn acquire(self: *BufferPool) !Buffers {
        self.mu.lock();
        if (self.list.pop()) |bufs| {
            self.mu.unlock();
            return bufs;
        }
        self.mu.unlock();
        // RSS attribution (runtime/vma.zig): VM buffers get their own
        // bucket so the report separates them from transient blocks.
        const prev_tag = vma.setAllocTag(.worker_arena);
        defer _ = vma.setAllocTag(prev_tag);
        const value_stack = try self.allocator.alignedAlloc(Value, buffer_alignment, types.vm_stack_capacity);
        errdefer self.allocator.free(value_stack);
        const frames = try self.allocator.alignedAlloc(Frame, buffer_alignment, types.max_frames);
        return .{ .stack = value_stack, .frames = frames };
    }

    pub fn release(self: *BufferPool, bufs: Buffers) void {
        self.mu.lock();
        const appended = blk: {
            self.list.append(self.allocator, bufs) catch break :blk false;
            break :blk true;
        };
        self.mu.unlock();
        if (!appended) {
            self.allocator.free(bufs.stack);
            self.allocator.free(bufs.frames);
        }
    }
};

/// A single call frame.
pub const Frame = struct {
    /// The chunk being executed.
    chunk_ptr: *const Chunk,
    /// Id of the chunk being executed.
    chunk_id: ChunkId,
    /// Instruction pointer (byte offset into chunk.code).
    ip: usize,
    /// Base index into the VM stack for local variables.
    frame_base: u32,
    /// Number of locals in this frame (for cleanup).
    local_count: u32,
    /// Upvalues for the closure or direct thunk currently executing.
    upvalues: ?[]const Value,
    /// Heap closure whose value-store range backs `upvalues`. A frame keeps
    /// only a raw slice, so the precise collector must root this owner before
    /// closure ranges can be reclaimed. Null for immediate functions and
    /// thunk/stack-backed upvalue slices whose owners are rooted elsewhere.
    upvalue_owner: ?ObjectId,
    /// Logical call depth of this frame — the length of the function-
    /// application chain that reached it, matching Nix's `max-call-depth`
    /// accounting. A function-application frame is one deeper than the
    /// frame that called it; a passthrough frame (top-level entry, a
    /// thunk-force isolated frame, an eager argument evaluation) inherits
    /// its parent's depth unchanged. Tail calls (`replaceCurrentFrame`)
    /// bump this in place, so a tail-recursion loop grows the logical
    /// depth without growing the physical frame stack — exactly how Nix
    /// bounds otherwise-unbounded tail recursion.
    call_depth: u32 = 0,
};

pub const ImportHost = struct {
    context: *anyopaque,
    // `parent_depth` = the calling VM's `native_depth` (the import builtin has
    // already +1'd it): the nested import VM inherits `parent_depth - 1` so
    // imports stay depth-transparent for GC safepoints.
    import_value: *const fn (*anyopaque, *VM, []const u8, u32) anyerror!Value,
    scoped_import: *const fn (*anyopaque, *VM, Value, []const u8, u32) anyerror!Value,
    find_file: *const fn (*anyopaque, []const u8) anyerror!Value,
    get_env: *const fn (*anyopaque, []const u8) anyerror![]const u8,
    /// Next queued path from the chunk-cache import manifest (interned), or
    /// null when the backlog is drained. Each completed import-prefetch task
    /// pulls one and resubmits, so the manifest replays as a bounded
    /// self-perpetuating drip on idle helpers rather than a startup flood
    /// that overflows the spec rings.
    manifest_next: ?*const fn (*anyopaque) ?InternId = null,
};

/// Why evaluation paused into the debugger. `entry` is the one-shot stop at
/// the start of a `:debug` expression; `break_builtin` is a `builtins.break x`
/// call; `line_breakpoint` is a patched source-line breakpoint; `step` is a
/// completed single-step; `return_step` is the virtual stop after a stepped
/// frame has returned to its caller; `eval_error` is an evaluation error caught
/// with `--debugger`.
pub const BreakReason = enum { entry, break_builtin, line_breakpoint, step, return_step, eval_error };

/// A debugger attachment. Installed on every VM by `Engine.initVm` when a
/// debugger is active; null (the default) means "no debugger" and ordinary
/// return paths pay only one unlikely null check.
///
/// `fire` is an upcall into the owning layer (the `fix` Engine, then the
/// `cli` debug console): it runs the interactive session synchronously on the
/// *current* demand fiber, then returns so evaluation continues. `ctx` is the
/// owner's opaque self-pointer. The callback may re-enter the evaluator to
/// force/render `value` and to evaluate console expressions — that nesting is
/// safe because forcing already re-enters the VM (`runIsolatedFrame`).
pub const BreakSink = struct {
    ctx: *anyopaque,
    fire: *const fn (ctx: *anyopaque, vm: *VM, value: Value, reason: BreakReason) anyerror!void,
};

/// Per-thread VM state. Each worker thread has one of these.
/// Sentinel for `VM.speculation.claim_budget`: no bound on speculative work. (Never
/// reachable by decrement — 2^64 claimed forces don't happen.)
pub const no_spec_budget: u64 = std.math.maxInt(u64);

pub const VM = struct {
    const DebugState = struct {
        break_sink: ?BreakSink = null,
        breakpoints: ?*bytecode_mod.BreakpointTable = null,
        parent: ?*VM = null,
        import_replay: bool = false,
    };

    const SpeculationState = struct {
        /// Suppresses recursive speculative submission while a task runs.
        active: bool = false,
        /// A demand waiter promotes this fiber's descendants to urgent work.
        demand_rescue: std.atomic.Value(u8) = .init(0),
        /// Remaining claimed forces; `no_spec_budget` disables the bound.
        claim_budget: u64 = no_spec_budget,
        /// Remaining thunk creations, settled from the current worker counter.
        create_left: u64 = no_spec_budget,
        create_snapshot: u64 = 0,
        create_worker: u8 = 0,
    };

    const GcRoots = struct {
        /// Value currently crossing a safepoint off the operand stack.
        extra: Value = Value.null_val,
        /// Claimed thunks whose bodies are currently nested.
        force_chain: std.ArrayListUnmanaged(types.ObjectId) = .empty,
        /// Native-held containers and results that cross later safepoints.
        temporary: std.ArrayListUnmanaged(Value) = .empty,
    };

    driver: *const Driver,
    allocator: std.mem.Allocator,
    /// Global chunk registry (shared across all VMs). Mutable: the
    /// deferred-attr force path registers freshly-compiled chunks at
    /// runtime (`register` is internally thread-safe).
    registry: *ChunkRegistry,
    /// Lazy per-attr compilation: deferred bodies + their compile cache.
    /// Set post-init by `Engine.initVm`; null in standalone test VMs
    /// (which never create `.deferred` thunks). See
    /// `compiler/deferred_table.zig`.
    deferred_table: ?*DeferredTable = null,
    registration_sink: ?ChunkRegistrationSink = null,
    /// Engine-owned compiled-regex cache for `builtins.match`/`split`
    /// (see `support/regex.zig`). Set post-init by
    /// `Engine.initVm`; null in standalone test VMs, which fall back
    /// to compiling per call.
    regexes: ?*PatternCache = null,
    /// Debugger attachment, breakpoint state, and synchronous import ancestry.
    debug: DebugState = .{},
    /// Global intern table (shared).
    intern: *InternTable,
    /// Runtime object heap.
    heap: *ObjectHeap,
    /// Engine-owned filesystem cache.
    files: *FileCache,
    /// Engine-owned network/source fetch cache.
    fetchers: *FetchService,
    /// Engine-owned realization service for recipes, store I/O, and builds.
    realization: *RealizationStore,
    /// Borrowed worker capabilities. Queue storage and scheduler machinery
    /// remain owned by the evaluator's worker runtime.
    workers: VmRuntime,
    /// Engine-owned error trace collector.
    trace: ?*eval_trace.Trace,
    /// Sparse demand-committed language-effect store. Null only in isolated
    /// VM unit harnesses that do not exercise effecting builtins.
    effects: ?*effects_mod.Store,
    /// Effects observed during the current speculative task. Nested thunk
    /// forces leave records here so each containing thunk can publish a group.
    effect_journal: effects_mod.Journal = .empty,
    /// Monotonic per-VM marker used to keep effectful bodies out of the pure
    /// bytecode-result memo. Wrapping is harmless; only equality is tested.
    effect_epoch: u64 = 0,
    /// Engine-scoped structured observation capability. Disabled handles
    /// are cheap values and all workers may use an enabled handle safely.
    observer: observ.Observer,
    /// Fiber-aware blocking capability supplied by the evaluator. Standalone
    /// VMs leave this null and execute blocking work inline.
    executor: ?FiberExecutor,
    /// Standalone VMs own their execution context here. Engine fibers bind
    /// `ctx` below to their stable fiber-owned context instead.
    local_ctx: ExecutionContext = .{},
    /// Fiber-scoped execution identity: claim id and demand role.
    /// Points at the owning `WorkerFiber`'s context; nested VMs created on
    /// that fiber share the pointer (see `Engine.initVm`), so they cannot
    /// diverge from their fiber's identity. Standalone test VMs (no fiber)
    /// use `local_ctx`. Engine-bound VMs point at mutable fiber-owned state;
    /// only code running that fiber mutates the carrier.
    /// See `eval/workers/context.zig`.
    ctx: ?*ExecutionContext = null,
    /// Optional VM execution tracer.
    vm_trace: ?*VmTrace,
    /// Optional per-thunk lifecycle event log (see `probe/thunk_trace.zig`).
    /// Recording is disabled when null. All workers share a single
    /// trace; writes serialize on its internal mutex. The field is
    /// compiled out entirely unless `-Dthunks-log` is set so the
    /// per-thunk null-check overhead doesn't burden default builds.
    thunk_trace: if (thunks_log_enabled) ?*ThunkTrace else void,
    import_host: ?ImportHost,
    /// Cached evaluator-owned builtins attrset.
    builtins: Value,
    /// GC native-builtin call depth: incremented
    /// around each native builtin, so `native_depth == 0` marks a clean
    /// safepoint where no builtin holds un-rooted Zig locals. On the VM (not a
    /// threadlocal) so it's fiber-local — a yielded fiber resuming on another
    /// thread keeps its own count. A nested import's fresh VM inherits the
    /// caller's depth (see `Engine.evaluateSource`).
    native_depth: u32 = 0,

    /// Where `stack`/`frames` came from and where `deinit` returns them:
    /// the evaluator's shared pool, or (null — tests, tools) `allocator`.
    buffer_pool: ?*BufferPool,
    /// The value stack. Fixed capacity = vm_stack_capacity; `sp` is the
    /// logical length.
    stack: BufferPool.ValueStack,
    /// Stack pointer — index of the next push slot.
    sp: u32,
    /// Max value of `sp` ever observed on this VM since construction.
    /// Updated on every push/pushFrame so we can report stack
    /// high-water for sizing future vm_stack_capacity defaults. Not reset
    /// when sp is reset between tasks (so the peak is across all tasks
    /// this VM has executed).
    sp_high_water: u32,
    /// Call frames. Fixed capacity = max_frames; `frames_len` is the
    /// logical count.
    frames: BufferPool.FrameStack,
    frames_len: u32,
    /// Single-worker mode (`Scheduler.worker_count == 1`, captured at VM
    /// construction — before any helper thread can exist). When set, the
    /// thunk force protocol takes the plain-load/store claim + publish
    /// variants (`Thunk.tryForceSolo`/`resolveSolo`) instead of the CAS +
    /// waiter-mutex variants: with one OS thread, fibers interleave only at
    /// yield points and do not need atomic ownership changes.
    solo: bool,

    /// Fiber-local mode, priority inheritance, and work budgets.
    speculation: SpeculationState = .{},

    /// True only when the result will be rendered as lazy XML, where
    /// eagerly-built shapes (list/attrset/lambda) must appear unevaluated
    /// (`<unevaluated />`) until demanded. The compiler emits
    /// `thunk_shell` to wrap such values; when this is false (the
    /// common default/JSON/`.drv`/strict path) the op pushes the value
    /// directly. Set per-eval from `Engine.lazy_shells_visible`.
    lazy_shells_visible: bool,

    /// Compatibility policy applied while parsing and compiling this code.
    policy: LanguagePolicy,
    /// Engine-local threshold for routing derived strings to the GC heap.
    heap_string_min: usize,
    /// Nix's `trace-verbose` setting gates `builtins.traceVerbose`.
    trace_verbose: bool,
    /// `FIX_PROF_DUP` in a `-Dprof-main` build: run the duplicate-thunk
    /// census. Always false in builds without the profiler.
    dup_census: bool,

    /// Values held off the VM stack across GC safepoints.
    gc_roots: GcRoots = .{},

    pub const Init = struct {
        driver: *const Driver,
        allocator: std.mem.Allocator,
        buffer_pool: ?*BufferPool = null,
        registry: *ChunkRegistry,
        intern: *InternTable,
        heap: *ObjectHeap,
        files: *FileCache,
        fetchers: *FetchService,
        realization: *RealizationStore,
        workers: VmRuntime,
        trace_sink: ?*eval_trace.Trace = null,
        effects: ?*effects_mod.Store = null,
        observer: observ.Observer = .{},
        executor: ?FiberExecutor = null,
        vm_trace: ?*VmTrace = null,
        thunk_trace: if (thunks_log_enabled) ?*ThunkTrace else void = if (thunks_log_enabled) null else {},
        import_host: ?ImportHost = null,
        builtins_value: Value = Value.null_val,
        deferred_table: ?*DeferredTable = null,
        registration_sink: ?ChunkRegistrationSink = null,
        regexes: ?*PatternCache = null,
        break_sink: ?BreakSink = null,
        breakpoints: ?*bytecode_mod.BreakpointTable = null,
        policy: LanguagePolicy = .{},
        heap_string_min: usize = 64,
        trace_verbose: bool = false,
        lazy_shells_visible: bool = false,
        dup_census: bool = false,
    };

    pub fn init(options: Init) !VM {
        const bufs: BufferPool.Buffers = if (options.buffer_pool) |bp| try bp.acquire() else blk: {
            const value_stack = try options.allocator.alignedAlloc(Value, BufferPool.buffer_alignment, types.vm_stack_capacity);
            errdefer options.allocator.free(value_stack);
            const frames = try options.allocator.alignedAlloc(Frame, BufferPool.buffer_alignment, types.max_frames);
            break :blk .{ .stack = value_stack, .frames = frames };
        };
        const value_stack = bufs.stack;
        const frames = bufs.frames;

        return .{
            .driver = options.driver,
            .allocator = options.allocator,
            .registry = options.registry,
            .deferred_table = options.deferred_table,
            .registration_sink = options.registration_sink,
            .regexes = options.regexes,
            .debug = .{
                .break_sink = options.break_sink,
                .breakpoints = options.breakpoints,
            },
            .intern = options.intern,
            .heap = options.heap,
            .files = options.files,
            .fetchers = options.fetchers,
            .realization = options.realization,
            .workers = options.workers,
            .trace = options.trace_sink,
            .effects = options.effects,
            .observer = options.observer,
            .executor = options.executor,
            .vm_trace = options.vm_trace,
            .thunk_trace = options.thunk_trace,
            .import_host = options.import_host,
            .builtins = options.builtins_value,
            // `ctx` remains null here, selecting this VM's owned `local_ctx`.
            // Worker.allocateFiber repoints evaluator VMs at the fiber's
            // context before they run, and Engine.initVm does the same for
            // nested VMs.
            .buffer_pool = options.buffer_pool,
            .stack = value_stack,
            .sp = 0,
            .sp_high_water = 0,
            .frames = frames,
            .frames_len = 0,
            .solo = options.workers.isSolo(),
            .lazy_shells_visible = options.lazy_shells_visible,
            .policy = options.policy,
            .heap_string_min = options.heap_string_min,
            .trace_verbose = options.trace_verbose,
            .dup_census = options.dup_census,
        };
    }

    /// The OS-thread-current worker id. Reads the threadlocal set by
    /// `Worker.run` / `Worker.runTopLevel`. Use this anywhere code
    /// needs to know "who is executing right now" — not a stored field
    /// because fibers migrate across workers.
    pub inline fn workerId(self: *const VM) u8 {
        _ = self;
        return worker_id_mod.currentId();
    }

    /// Select debugger-owned executable bytecode at a frame boundary. The
    /// ordinary path returns the immutable chunk slice after one null check;
    /// dispatch itself performs no breakpoint lookup per opcode.
    pub inline fn executableCode(self: *const VM, chunk_id: ChunkId, chunk_ptr: *const Chunk) []const u8 {
        if (self.debug.breakpoints) |breakpoints| {
            @branchHint(.unlikely);
            return breakpoints.executableCode(chunk_id, chunk_ptr);
        }
        return chunk_ptr.code;
    }

    /// The authoritative execution context. Computing the standalone fallback
    /// from `self` avoids a self-pointer that would be invalidated when a VM
    /// value moves out of `init`.
    pub inline fn executionContext(self: *VM) *ExecutionContext {
        return self.ctx orelse &self.local_ctx;
    }

    pub inline fn executionContextConst(self: *const VM) *const ExecutionContext {
        return self.ctx orelse &self.local_ctx;
    }

    /// Physical frames across the synchronous import-parent chain. Used only
    /// by patched debugger traps, so normal dispatch does not pay for it.
    pub fn debugFrameDepth(self: *const VM) u32 {
        var total = self.frames_len;
        var cursor = self.debug.parent;
        while (cursor) |parent| : (cursor = parent.debug.parent) total += parent.frames_len;
        return total;
    }

    /// The owner is about to reset the arena backing `allocator` (fiber
    /// recycle — see WorkerFiber.recycleScratch): drop any capacity this
    /// VM retains there. The lists are logically empty between tasks
    /// (roots/chains are scoped to a force); only their capacity lives on.
    pub fn onScratchReset(self: *VM) void {
        std.debug.assert(self.gc_roots.force_chain.items.len == 0);
        std.debug.assert(self.gc_roots.temporary.items.len == 0);
        std.debug.assert(self.effect_journal.items.len == 0);
        self.gc_roots.force_chain = .empty;
        self.gc_roots.temporary = .empty;
        self.effect_journal = .empty;
    }

    pub fn deinit(self: *VM) void {
        self.gc_roots.force_chain.deinit(self.allocator);
        self.gc_roots.temporary.deinit(self.allocator);
        self.effect_journal.deinit(self.allocator);
        if (self.buffer_pool) |bp| {
            bp.release(.{ .stack = self.stack, .frames = self.frames });
        } else {
            self.allocator.free(self.stack);
            self.allocator.free(self.frames);
        }
    }

    /// Evaluate a chunk and return its result.
    pub fn eval(self: *VM, chunk_id: ChunkId) !Value {
        return self.driver.eval(self, chunk_id);
    }
};

// ---- free functions (don't take self) ----

pub fn readU16(code: []const u8, ip: usize) u16 {
    return bytecode_mod.readU16(code, ip);
}

pub fn readU32(code: []const u8, ip: usize) u32 {
    return bytecode_mod.readU32(code, ip);
}

pub fn readInternId(code: []const u8, ip: usize, wide: bool) InternId {
    return bytecode_mod.readInternId(code, ip, wide);
}
