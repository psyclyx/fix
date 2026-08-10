//! Atomic lazy thunk built on the generic `future.zig` claim/wait protocol.
//!
//! `Thunk` layers a `ThunkTarget` (what to evaluate) and a
//! `demanded` flag (was this resolution observed by a real caller?)
//! on top of `Future`.
//!
//! Scheduling rules:
//!   - Claimer identity (`ClaimerId`) is a globally-allocated fiber id
//!     (`Scheduler.allocFiberId`). It does NOT encode which OS thread
//!     the fiber runs on, so a fiber that migrates across workers
//!     keeps the same identity.
//!   - Wakes are routed to the scheduler's ready queue keyed by the
//!     fiber's allocator-worker (`Fiber.worker`), but ready fibers
//!     are stealable across workers — any worker may resume a waiter
//!     once it's queued.
//!   - All workers (including worker 0 / main) participate
//!     symmetrically in `tryForce`, waiter enrollment, and resolution.
//!     There is no special "main" path through this module.
//!
//! Memory model:
//!   - `Future.state` transitions follow release-acquire pairs.
//!   - `Thunk.payload.result` is written before the `state → resolved`
//!     store-release; readers observe it after acquire-loading
//!     state == resolved.
//!   - `Thunk.target` is set at construction and never mutated
//!     (except by `publishCellBinding` under EVALUATING claim).
//!   - Waiter list manipulation is protected by the tagged waiters word (`Future.waiters`). Resolvers
//!     re-acquire the lock after the state store so any concurrent
//!     `enrollWaiter` either sees the new state (and refuses) or its
//!     waiter is drained.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const timebase = @import("base").timebase;
const types = @import("types.zig");
const Value = @import("value.zig").Value;
const ChunkId = types.ChunkId;
const future = @import("future.zig");
const failure = @import("failure.zig");

const Future = future.Future;
const FutureState = future.FutureState;
const Waiter = future.Waiter;
const ClaimerId = future.ClaimerId;
const makeClaimer = future.makeClaimer;
pub const FailureRef = failure.FailureRef;

/// `-Dprof-main` age-at-force probe support. These fields belong to thunks,
/// not to the generic synchronization primitive used by imports and I/O.
pub const created_tsc_enabled: bool = build_options.prof_main and timebase.supported;
const CreatedTsc = if (created_tsc_enabled) u64 else void;
pub const CreatedDemand = if (created_tsc_enabled) bool else void;
const SpecDisp = if (created_tsc_enabled) u8 else void;

pub inline fn initCreatedDemand() CreatedDemand {
    return if (comptime created_tsc_enabled) false else {};
}

inline fn initSpecDisp() SpecDisp {
    return if (comptime created_tsc_enabled) @as(u8, 0) else {};
}

inline fn nowCreatedTsc() CreatedTsc {
    if (comptime !created_tsc_enabled) return {};
    return timebase.read();
}

pub const BytecodeThunk = struct {
    chunk_id: ChunkId,
    upvalue_count: u32,
    storage: Storage,

    /// Up to `inline_capacity` upvalues live *inline* in the thunk — one
    /// allocation and no separate `values`-store range. Wider captures spill
    /// to the heap's `values` store. `upvalue_count` is the discriminant, so
    /// inline storage needs no tag word.
    pub const inline_capacity: u32 = 2;

    pub const SpillRange = struct {
        segment: u32,
        offset: u32,
        len: u32,
    };

    const Spilled = struct {
        ptr: [*]const Value,
        segment: u32,
        offset: u32,
    };

    const Storage = union {
        inline_vals: [inline_capacity]Value,
        spilled: Spilled,
    };

    /// The captured upvalues. For inline storage the returned slice
    /// points into `self`, so this MUST be called through a stable
    /// pointer to the thunk (the heap's append-only store gives stable
    /// addresses) — never on a by-value copy of the thunk.
    pub fn upvalues(self: *const BytecodeThunk) []const Value {
        if (self.upvalue_count <= inline_capacity) return self.storage.inline_vals[0..self.upvalue_count];
        return self.storage.spilled.ptr[0..self.upvalue_count];
    }

    pub fn spillRange(self: *const BytecodeThunk) ?SpillRange {
        if (self.upvalue_count <= inline_capacity) return null;
        return .{
            .segment = self.storage.spilled.segment,
            .offset = self.storage.spilled.offset,
            .len = self.upvalue_count,
        };
    }
};

/// A thunk whose body has NOT been compiled to bytecode yet — its value
/// is the result of compiling an AST node (named by `deferred_id` into
/// the evaluator's `DeferredTable`) against the captured environment
/// `env`, then running it. Used by lazy per-attr compilation: a large
/// generated attrset can defer its value bodies. On first force the body is compiled, the resulting
/// ChunkId is cached on the `DeferredTable` entry (shared across
/// instantiations), and execution falls into the same path as a
/// `.bytecode` thunk with `env` as its upvalues.
///
/// Mirrors `BytecodeThunk`'s inline/spilled storage to keep both target arms
/// the same size.
pub const DeferredThunk = struct {
    deferred_id: u32,
    env_count: u32,
    storage: Storage,

    pub const inline_capacity: u32 = BytecodeThunk.inline_capacity;

    const Spilled = struct {
        ptr: [*]const Value,
        segment: u32,
        offset: u32,
    };

    const Storage = union {
        inline_vals: [inline_capacity]Value,
        spilled: Spilled,
    };

    /// The captured environment (the enclosing-scope snapshot). Same
    /// stable-pointer contract as `BytecodeThunk.upvalues`.
    pub fn env(self: *const DeferredThunk) []const Value {
        if (self.env_count <= inline_capacity) return self.storage.inline_vals[0..self.env_count];
        return self.storage.spilled.ptr[0..self.env_count];
    }

    pub fn spillRange(self: *const DeferredThunk) ?BytecodeThunk.SpillRange {
        if (self.env_count <= inline_capacity) return null;
        return .{
            .segment = self.storage.spilled.segment,
            .offset = self.storage.spilled.offset,
            .len = self.env_count,
        };
    }
};

/// What a thunk evaluates when forced.
///
///   - `.closure` and `.bytecode` are computed targets: forcing invokes
///     bytecode or a builtin and the result is stored.
///   - `.pass_through` is a memoization wrapper: the underlying Value is
///     forced and the result becomes the thunk's resolved value. This is
///     how the compiler models recursive let-binding cells.
/// Frameless lazy attr access. Forcing selects `name` from `base` directly.
pub const AttrAccess = struct {
    base: Value,
    name: types.InternId,
};

/// Discriminant for `ThunkTarget`. Stored beside the generic future rather
/// than in the bare target union, avoiding the union's alignment padding.
pub const TargetKind = enum(u8) { closure, bytecode, pass_through, attr_access, deferred };

/// Bare (untagged) union — the active arm is named by `Thunk.target_kind`, set
/// at construction and immutable thereafter (a target is never
/// mutated after creation except by `publishCellBinding`, which keeps
/// the same `pass_through` kind).
pub const ThunkTarget = union {
    closure: Value,
    bytecode: BytecodeThunk,
    pass_through: Value,
    attr_access: AttrAccess,
    deferred: DeferredThunk,
};

pub const ForceOutcome = union(enum) {
    already_resolved: Value,
    claimed,
    blackhole,
    busy,
    /// Borrowed immutable record handle, or an inline degraded error code.
    /// Both representations fit in the existing Value-sized result word.
    errored: FailureRef,
};

/// Atomic lazy thunk: a `Future` (claim/wait state machine) plus a
/// `result`/`target` union. `target` (what to evaluate) is the live
/// union arm while the thunk is unresolved/evaluating; `result` (the
/// resolved Value, or a `FailureRef`'s bits when errored) is live once
/// the thunk reaches a terminal state. The two are never live at the
/// same instant — a thunk reads `target` to compute its value, then
/// overwrites the same bytes with `result` at resolution — so they
/// share storage, keeping each thunk compact.
/// `future.state` is the discriminant. `demanded` (on this thunk)
/// distinguishes a real observation from speculative pre-forcing so
/// lazy renderers can keep speculation invisible.
pub const Thunk = struct {
    future: Future,
    /// Whether a real caller observed this thunk's resolution. Speculative
    /// forcing must remain invisible to lazy renderers.
    /// Engine-owned demand-effect group (0 = none). Written by the claiming
    /// fiber before it release-publishes a resolved/errored state and therefore
    /// safely read after the corresponding acquire-load. A raw u32 keeps the
    /// runtime module independent of the expression engine's effect store and
    /// fits in the struct's existing alignment hole in production builds.
    /// `-Dprof-main` probe state; all fields are zero-sized in normal builds.
    created_tsc: CreatedTsc,
    created_demand: CreatedDemand = initCreatedDemand(),
    demanded_old: CreatedDemand = initCreatedDemand(),
    spec_disp: SpecDisp = initSpecDisp(),
    payload: Payload,

    /// Bare (untagged) union: `future.state` is the only discriminant.
    /// `.resolved`/`.errored` → read `result`; any other state → `target`.
    pub const Payload = union {
        /// Resolved Value, or (when `.errored`) the `FailureRef` bits
        /// reinterpreted through `Value.bits`.
        result: Value,
        target: ThunkTarget,
    };

    fn initWithFuture(future_cell: Future, kind: TargetKind, payload: Payload) Thunk {
        // Fold the target kind into the state word's flag bits at birth
        // (pre-publication, so the plain read-modify-write is race-free).
        var f = future_cell;
        const raw = f.state.load(.monotonic);
        f.state = .init(raw | (@as(u32, @intFromEnum(kind)) << future.flag_kind_shift));
        return .{
            .future = f,
            .created_tsc = nowCreatedTsc(),
            .payload = payload,
        };
    }

    pub fn init(closure: Value) Thunk {
        return initWithFuture(Future.init(), .closure, .{ .target = .{ .closure = closure } });
    }

    /// Inline bytecode thunk. Wider captures use `initBytecodeSpilled` so the
    /// owning heap can reclaim their stable value-store range on resolution.
    pub fn initBytecode(chunk_id: ChunkId, upvalues: []const Value) Thunk {
        std.debug.assert(upvalues.len <= BytecodeThunk.inline_capacity);
        var storage: BytecodeThunk.Storage = undefined;
        var arr: [BytecodeThunk.inline_capacity]Value = undefined;
        @memcpy(arr[0..upvalues.len], upvalues);
        storage = .{ .inline_vals = arr };
        return initWithFuture(Future.init(), .bytecode, .{ .target = .{ .bytecode = .{
            .chunk_id = chunk_id,
            .upvalue_count = @intCast(upvalues.len),
            .storage = storage,
        } } });
    }

    pub fn initBytecodeSpilled(chunk_id: ChunkId, upvalues: []const Value, segment: u32, offset: u32) Thunk {
        std.debug.assert(upvalues.len > BytecodeThunk.inline_capacity);
        return initWithFuture(Future.init(), .bytecode, .{ .target = .{ .bytecode = .{
            .chunk_id = chunk_id,
            .upvalue_count = @intCast(upvalues.len),
            .storage = .{ .spilled = .{ .ptr = upvalues.ptr, .segment = segment, .offset = offset } },
        } } });
    }

    /// Inline deferred-compile thunk (see `DeferredThunk`). Wider
    /// environments use `initDeferredSpilled`.
    pub fn initDeferred(deferred_id: u32, env: []const Value) Thunk {
        std.debug.assert(env.len <= DeferredThunk.inline_capacity);
        var storage: DeferredThunk.Storage = undefined;
        var arr: [DeferredThunk.inline_capacity]Value = undefined;
        @memcpy(arr[0..env.len], env);
        storage = .{ .inline_vals = arr };
        return initWithFuture(Future.init(), .deferred, .{ .target = .{ .deferred = .{
            .deferred_id = deferred_id,
            .env_count = @intCast(env.len),
            .storage = storage,
        } } });
    }

    pub fn initDeferredSpilled(deferred_id: u32, env: []const Value, segment: u32, offset: u32) Thunk {
        std.debug.assert(env.len > DeferredThunk.inline_capacity);
        return initWithFuture(Future.init(), .deferred, .{ .target = .{ .deferred = .{
            .deferred_id = deferred_id,
            .env_count = @intCast(env.len),
            .storage = .{ .spilled = .{ .ptr = env.ptr, .segment = segment, .offset = offset } },
        } } });
    }

    /// Value-store range owned by the still-live target arm. Resolved/errored
    /// thunks have overwritten that arm and therefore own no capture range.
    pub fn targetSpillRange(self: *const Thunk) ?BytecodeThunk.SpillRange {
        const state: FutureState = self.future.stateField(.acquire);
        if (state == .resolved or state == .errored) return null;
        return switch (self.targetKind()) {
            .bytecode => self.payload.target.bytecode.spillRange(),
            .deferred => self.payload.target.deferred.spillRange(),
            else => null,
        };
    }

    /// A frameless attr-access thunk (see `AttrAccess`). Forcing computes
    /// `getAttrValue(base, name)` with no frame/dispatch.
    pub fn initAttrAccess(base: Value, name: types.InternId) Thunk {
        return initWithFuture(Future.init(), .attr_access, .{ .target = .{ .attr_access = .{ .base = base, .name = name } } });
    }

    /// A "cell" thunk: holds a Value to be forced lazily. Used by
    /// `builtins.deepSeq`-style memoisation and by `cell_new` where
    /// the wrapped value is known at construction time.
    pub fn initPassThrough(value: Value) Thunk {
        return initWithFuture(Future.init(), .pass_through, .{ .target = .{ .pass_through = value } });
    }

    /// Pre-resolved "lazy shell" thunk: wraps a value that's already
    /// computed but should still appear unevaluated to lazy renderers.
    /// Forces in O(1) (resolved fast path), prints `<unevaluated />`
    /// in XML lazy mode until a real consumer marks it demanded.
    ///
    /// Used by the compiler when an eager-buildable shape (list /
    /// attrset / lambda) sits in a context where the value is
    /// observably lazy (attrset entry, list item) — we skip the
    /// chunk-registration + bytecode-dispatch roundtrip and just
    /// wrap the already-built shell. Born `.resolved` with `result`
    /// already live, so there is no target.
    pub fn initLazyShell(value: Value) Thunk {
        return initWithFuture(Future.initResolved(), .closure, .{ .result = value });
    }

    /// A "binding cell" thunk: created by `cell_init` for
    /// recursive let bindings, BEFORE the RHS is computed. The cell is
    /// born in `.evaluating` claimed by the creating fiber so any
    /// concurrent force attempt sees BUSY and parks on the waiter list
    /// instead of CAS-claiming the placeholder. The creating fiber
    /// later publishes the real binding via `publishCellBinding(val)`,
    /// which writes `target = pass_through(val)` and transitions back
    /// to `.unresolved` (keeping pass_through laziness — the cell
    /// forces `val` only when consumers actually force the cell).
    /// Without the EVALUATING-on-init guard, a fiber could CAS-claim
    /// the cell while it still wraps the placeholder null and resolve
    /// the cell to null, freezing the binding before the creator could
    /// publish.
    pub fn initBindingCell(claimer: ClaimerId) Thunk {
        return initWithFuture(
            Future.initClaimed(claimer),
            .pass_through,
            // Placeholder; never observed since no fiber can CAS-claim
            // an `.evaluating` cell, and `publishCellBinding` overwrites
            // `target` before transitioning back to `.unresolved`.
            .{ .target = .{ .pass_through = Value.null_val } },
        );
    }

    pub inline fn markDemanded(self: *Thunk) void {
        const raw = self.future.state.load(.monotonic);
        if (comptime future.protocol_checks) {
            if (raw == future.poisoned_state)
                @panic("markDemanded on a GC-swept thunk — stale reference held across a collection");
        }
        if (raw & future.flag_demanded == 0) {
            if (comptime created_tsc_enabled) {
                self.demanded_old = (nowCreatedTsc() -| self.created_tsc) >= (1 << 21);
            }
            // fetchOr: never lost against a concurrent FSM transition (the
            // transitions CAS-preserve flag bits) or another marker.
            _ = self.future.state.fetchOr(future.flag_demanded, .release);
        }
    }

    pub inline fn isDemanded(self: *const Thunk) bool {
        return self.future.state.load(.acquire) & future.flag_demanded != 0;
    }

    /// Set the has-effect-group flag (claim-owner only, pre-publication of
    /// the resolve — concurrent markDemanded is the only racer, handled by
    /// the same fetchOr discipline).
    pub inline fn markHasEffects(self: *Thunk) void {
        _ = self.future.state.fetchOr(future.flag_has_effects, .release);
    }

    pub inline fn hasEffects(self: *const Thunk) bool {
        return self.future.state.load(.acquire) & future.flag_has_effects != 0;
    }

    /// Non-claiming peek at whether the thunk is still evaluating. See
    /// `Future.isEvaluating`.
    pub inline fn isEvaluating(self: *const Thunk) bool {
        return self.future.isEvaluating();
    }

    /// The active arm of the bare `payload.target` union. Only meaningful
    /// while the thunk is unresolved/evaluating (the states in which
    /// `target` is the live union arm).
    pub inline fn targetKind(self: *const Thunk) TargetKind {
        return @enumFromInt((self.future.state.load(.monotonic) & future.flag_kind_mask) >> future.flag_kind_shift);
    }

    pub inline fn noteSpecSubmitted(self: *Thunk, admitted: bool) void {
        if (comptime created_tsc_enabled) self.spec_disp = if (admitted) 1 else 2;
    }

    pub inline fn specDispValue(self: *const Thunk) u8 {
        return if (comptime created_tsc_enabled) self.spec_disp else 0;
    }

    /// Racy-benign read of the target arm's leading bytes, reinterpreted as
    /// `T`, WITHOUT tripping the bare-union active-field safety check. The
    /// `.closure`/`.bytecode` arms both begin at offset 0 of the payload
    /// (closure = `Value`, bytecode = `BytecodeThunk{ chunk_id, ... }`), so a
    /// raw reinterpret of `&payload` reads that arm's first field directly.
    ///
    /// Callers gate on a racy `state == unresolved` load (target arm live),
    /// but a concurrent resolve can flip the payload to `.result` between that
    /// check and this read — so the result may be stale/garbage. Every caller
    /// must bound-guard it (a stale chunk id → `registry.slot` returns null; a
    /// stale closure Value → `getBuiltinClosure` bounds-guards). Reading the
    /// raw storage is what release already does once the safety tag is elided;
    /// this makes Debug/ReleaseSafe match that intended semantics instead of
    /// panicking on the stale union arm.
    ///
    /// The load is one monotonic atomic word, so it cannot tear; staleness is
    /// the only hazard. This is the project's single sanctioned
    /// unsynchronized reader: the conflicting `resolve` store is the hottest
    /// publish in the interpreter and cannot become atomic without splitting
    /// the safety-checked union write or growing the size-critical thunk, so
    /// `test/tsan.supp` suppresses exactly this pair by this function's name.
    /// Deliberately NOT inline, so the suppression stays scoped to this read.
    pub fn targetLeadingRacy(self: *const Thunk, comptime T: type) T {
        comptime std.debug.assert(@sizeOf(T) <= @sizeOf(u64));
        comptime std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
        const word_ptr: *const u64 = @ptrCast(@alignCast(&self.payload));
        const word = @atomicLoad(u64, word_ptr, .monotonic);
        const bytes: *const [@sizeOf(u64)]u8 = @ptrCast(&word);
        const leading: *const T = @ptrCast(@alignCast(bytes));
        return leading.*;
    }

    /// Publish a binding cell's value (see `initBindingCell`). Writes
    /// `target = pass_through(value)` and transitions `.evaluating →
    /// .unresolved` so the next force runs the normal pass_through
    /// path. Ordering: the plain write to `target` is published by the
    /// release-store inside `future.reset`, which pairs with
    /// `tryClaim`'s acquire-load. The cell never reached `.resolved`,
    /// so the `target` arm of the union is still the live one.
    pub fn publishCellBinding(self: *Thunk, value: Value) void {
        self.payload = .{ .target = .{ .pass_through = value } };
        self.future.reset();
    }

    /// `publishCellBinding` on the single-worker path (skips the waiter
    /// mutex when nobody parked on the cell). See `Future.resetSolo`.
    pub fn publishCellBindingSolo(self: *Thunk, value: Value) void {
        self.payload = .{ .target = .{ .pass_through = value } };
        self.future.resetSolo();
    }

    // Delegators to the embedded Future. The hot ones are `inline` so
    // the force path has no extra call frame. The value-carrying ones
    // (`tryForce`, `resolve`, `markErrored`) read/write the local
    // `payload` union — the Future itself is value-less.

    pub inline fn tryForce(self: *Thunk, claimer: ClaimerId) ForceOutcome {
        return switch (self.future.tryClaim(claimer)) {
            // The state acquire-load inside `tryClaim` pairs with the
            // release-store in `publish`/`publishErrored`, so the
            // `payload` reads below observe the published arm.
            .already_resolved => .{ .already_resolved = self.payload.result },
            .errored => .{ .errored = self.cachedFailure() },
            .claimed => .claimed,
            .busy => .busy,
            .blackhole => .blackhole,
        };
    }

    /// `tryForce` on the single-worker (`--workers=1`) claim path: plain
    /// load/store claim instead of the CAS. See `Future.tryClaimSolo` for
    /// the solo-ness contract.
    pub inline fn tryForceSolo(self: *Thunk, claimer: ClaimerId) ForceOutcome {
        return switch (self.future.tryClaimSolo(claimer)) {
            .already_resolved => .{ .already_resolved = self.payload.result },
            .errored => .{ .errored = self.cachedFailure() },
            .claimed => .claimed,
            .busy => .busy,
            .blackhole => .blackhole,
        };
    }

    pub inline fn enrollWaiter(self: *Thunk, waiter: *Waiter) bool {
        return self.future.enrollWaiter(waiter);
    }

    /// Publish `value` as the resolved result, overwriting the `target`
    /// arm, then transition to `.resolved`.
    pub inline fn resolve(self: *Thunk, value: Value) void {
        self.payload = .{ .result = value };
        self.future.publish();
    }

    /// `resolve` on the single-worker publish path (skips the waiter-list
    /// mutex when nobody enrolled). See `Future.publishSolo`.
    pub inline fn resolveSolo(self: *Thunk, value: Value) void {
        self.payload = .{ .result = value };
        self.future.publishSolo();
    }

    pub fn reset(self: *Thunk) void {
        // Transient retry: `target` is still the live arm (a transient
        // failure never wrote `result`), so just re-arm the future.
        self.future.reset();
    }

    /// Stash the `FailureRef` in the result slot (overwriting `target`)
    /// and transition to `.errored`.
    pub fn markErrored(self: *Thunk, failure_ref: FailureRef) void {
        self.payload = .{ .result = .{ .bits = failure_ref.rawBits() } };
        self.future.publishErrored();
    }

    pub inline fn cachedFailure(self: *const Thunk) FailureRef {
        return FailureRef.fromRawBits(self.payload.result.bits);
    }

    pub fn blackhole(self: *Thunk) void {
        self.future.blackhole();
    }

    /// Identity equality. Two thunks are the same object iff they live at
    /// the same heap slot — there is no structural notion of thunk equality.
    pub fn idEq(self: *const Thunk, other: *const Thunk) bool {
        return self == other;
    }
};

test "thunk layout stays compact" {
    if (created_tsc_enabled) return;
    // Debug/ReleaseSafe retain Zig's active-arm safety tag for the bare target
    // union. ReleaseFast/ReleaseSmall intentionally elide it: targetKind plus
    // Future.state are the production discriminants (see targetLeadingRacy).
    const budget: usize = switch (builtin.mode) {
        .Debug, .ReleaseSafe => 80,
        .ReleaseFast, .ReleaseSmall => 56,
    };
    try std.testing.expect(@sizeOf(Thunk) <= budget);
}

test "thunk: cross-worker enroll + resolve signals waiter" {
    var thunk = Thunk.init(Value.null_val);

    const Forcer = struct {
        fn run(th: *Thunk, value: i64, ready: *std.atomic.Value(u8), release_now: *std.atomic.Value(u8)) void {
            switch (th.tryForce(makeClaimer(0))) {
                .claimed => {},
                else => return,
            }
            ready.store(1, .release);
            while (release_now.load(.acquire) == 0) std.atomic.spinLoopHint();
            th.resolve(Value.int(value));
        }
    };

    var ready: std.atomic.Value(u8) = .init(0);
    var release_now: std.atomic.Value(u8) = .init(0);
    var t = try std.Thread.spawn(.{}, Forcer.run, .{ &thunk, @as(i64, 99), &ready, &release_now });

    while (ready.load(.acquire) == 0) std.atomic.spinLoopHint();

    // Worker 1 sees .busy, enrolls a waiter that flips an atomic flag
    // when the resolver fires.
    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .busy => {},
        else => unreachable,
    }
    var signaled: std.atomic.Value(u8) = .init(0);
    const WaiterHarness = struct {
        waiter: Waiter,
        signaled: *std.atomic.Value(u8),
        fn wake(w: *Waiter) void {
            const self: *@This() = @fieldParentPtr("waiter", w);
            self.signaled.store(1, .release);
        }
    };
    var w: WaiterHarness = .{ .waiter = .{ .wake_fn = WaiterHarness.wake }, .signaled = &signaled };
    try std.testing.expect(thunk.enrollWaiter(&w.waiter));

    release_now.store(1, .release);
    while (signaled.load(.acquire) == 0) std.atomic.spinLoopHint();
    t.join();

    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .already_resolved => |v| try std.testing.expectEqual(@as(i64, 99), v.asInt()),
        else => return error.UnexpectedOutcome,
    }
}

test "thunk: same claimer recursive force returns blackhole" {
    var thunk = Thunk.init(Value.null_val);
    const me = makeClaimer(0);

    switch (thunk.tryForce(me)) {
        .claimed => {},
        else => return error.UnexpectedOutcome,
    }
    // Re-forcing from the same claimer → blackhole.
    switch (thunk.tryForce(me)) {
        .blackhole => {},
        else => return error.ExpectedBlackhole,
    }
}

test "thunk: enrollWaiter adds to list and resolve drains it" {
    var thunk = Thunk.init(Value.null_val);

    const me = makeClaimer(0);
    const other = makeClaimer(1);

    // Claim as slot 0.
    switch (thunk.tryForce(me)) {
        .claimed => {},
        else => return error.UnexpectedOutcome,
    }
    // Slot 1 hits .busy and enrolls.
    switch (thunk.tryForce(other)) {
        .busy => {},
        else => return error.UnexpectedOutcome,
    }

    var woken: std.atomic.Value(u32) = .init(0);
    const WaiterHarness = struct {
        waiter: Waiter,
        woken: *std.atomic.Value(u32),
        fn wake(w: *Waiter) void {
            const self: *@This() = @fieldParentPtr("waiter", w);
            _ = self.woken.fetchAdd(1, .acq_rel);
        }
    };
    var ws: [3]WaiterHarness = .{
        .{ .waiter = .{ .wake_fn = WaiterHarness.wake }, .woken = &woken },
        .{ .waiter = .{ .wake_fn = WaiterHarness.wake }, .woken = &woken },
        .{ .waiter = .{ .wake_fn = WaiterHarness.wake }, .woken = &woken },
    };
    try std.testing.expect(thunk.enrollWaiter(&ws[0].waiter));
    try std.testing.expect(thunk.enrollWaiter(&ws[1].waiter));
    try std.testing.expect(thunk.enrollWaiter(&ws[2].waiter));

    thunk.resolve(Value.int(42));
    try std.testing.expectEqual(@as(u32, 3), woken.load(.acquire));
}

test "thunk: enrollWaiter refuses to enroll on already-resolved thunk" {
    var thunk = Thunk.init(Value.null_val);
    const me = makeClaimer(0);

    switch (thunk.tryForce(me)) {
        .claimed => {},
        else => return error.UnexpectedOutcome,
    }
    thunk.resolve(Value.int(7));

    const WaiterHarness = struct {
        waiter: Waiter,
        fn wake(_: *Waiter) void {}
    };
    var w: WaiterHarness = .{ .waiter = .{ .wake_fn = WaiterHarness.wake } };
    try std.testing.expect(!thunk.enrollWaiter(&w.waiter));
}

test "thunk: different fibers see .busy, not blackhole" {
    // Distinct claimers (different fiber ids) must not falsely report
    // recursion when one touches a thunk the other claimed.
    var thunk = Thunk.init(Value.null_val);
    const slot_a = makeClaimer(0);
    const slot_b = makeClaimer(1);

    switch (thunk.tryForce(slot_a)) {
        .claimed => {},
        else => return error.UnexpectedOutcome,
    }
    switch (thunk.tryForce(slot_b)) {
        .busy => {},
        .blackhole => return error.UnexpectedBlackhole,
        else => return error.UnexpectedOutcome,
    }
}

test "thunk: errored caches error and replays on next force" {
    const allocator = std.testing.allocator;
    var failure_store = failure.FailureStore.init(allocator);
    defer failure_store.deinit();
    var thunk = Thunk.init(Value.null_val);
    const me = makeClaimer(0);

    switch (thunk.tryForce(me)) {
        .claimed => {},
        else => return error.UnexpectedOutcome,
    }
    const failure_ref = failure_store.captureOrigin(error.NixThrow, "bad value", &.{});
    thunk.markErrored(failure_ref);

    switch (thunk.tryForce(makeClaimer(1))) {
        .errored => |got| {
            try std.testing.expectEqual(@as(anyerror, error.NixThrow), got.err());
            switch (got.record().?.*) {
                .origin => |origin| try std.testing.expectEqualStrings("bad value", origin.message),
                .context => return error.ExpectedOrigin,
            }
        },
        else => return error.ExpectedErroredOutcome,
    }
    // Replay is idempotent.
    switch (thunk.tryForce(makeClaimer(2))) {
        .errored => |got| try std.testing.expectEqual(@as(anyerror, error.NixThrow), got.err()),
        else => return error.ExpectedErroredOutcome,
    }
}

test "thunk: errored wakes enrolled waiters" {
    var thunk = Thunk.init(Value.null_val);

    const Failer = struct {
        fn run(th: *Thunk, claimed_signal: *std.atomic.Value(u8), go: *std.atomic.Value(u8)) void {
            switch (th.tryForce(makeClaimer(0))) {
                .claimed => {},
                else => return,
            }
            claimed_signal.store(1, .release);
            while (go.load(.acquire) == 0) std.atomic.spinLoopHint();
            th.markErrored(FailureRef.degraded(error.NixThrow));
        }
    };

    var claimed_signal: std.atomic.Value(u8) = .init(0);
    var go: std.atomic.Value(u8) = .init(0);
    var t = try std.Thread.spawn(.{}, Failer.run, .{ &thunk, &claimed_signal, &go });

    while (claimed_signal.load(.acquire) == 0) std.atomic.spinLoopHint();

    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .busy => {},
        else => return error.ExpectedBusy,
    }

    var signaled: std.atomic.Value(u8) = .init(0);
    const WaiterHarness = struct {
        waiter: Waiter,
        signaled: *std.atomic.Value(u8),
        fn wake(w: *Waiter) void {
            const self: *@This() = @fieldParentPtr("waiter", w);
            self.signaled.store(1, .release);
        }
    };
    var w: WaiterHarness = .{ .waiter = .{ .wake_fn = WaiterHarness.wake }, .signaled = &signaled };
    try std.testing.expect(thunk.enrollWaiter(&w.waiter));

    go.store(1, .release);
    while (signaled.load(.acquire) == 0) std.atomic.spinLoopHint();
    t.join();

    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .errored => {},
        else => return error.ExpectedErroredOutcome,
    }
}

test "thunk: reset wakes waiters and lets them retry" {
    var thunk = Thunk.init(Value.null_val);

    const Failer = struct {
        fn run(th: *Thunk, claimed_signal: *std.atomic.Value(u8), go: *std.atomic.Value(u8)) void {
            switch (th.tryForce(makeClaimer(0))) {
                .claimed => {},
                else => return,
            }
            claimed_signal.store(1, .release);
            while (go.load(.acquire) == 0) std.atomic.spinLoopHint();
            th.reset();
        }
    };

    var claimed_signal: std.atomic.Value(u8) = .init(0);
    var go: std.atomic.Value(u8) = .init(0);
    var t = try std.Thread.spawn(.{}, Failer.run, .{ &thunk, &claimed_signal, &go });

    while (claimed_signal.load(.acquire) == 0) std.atomic.spinLoopHint();

    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .busy => {},
        else => return error.ExpectedBusy,
    }

    var signaled: std.atomic.Value(u8) = .init(0);
    const WaiterHarness = struct {
        waiter: Waiter,
        signaled: *std.atomic.Value(u8),
        fn wake(w: *Waiter) void {
            const self: *@This() = @fieldParentPtr("waiter", w);
            self.signaled.store(1, .release);
        }
    };
    var w: WaiterHarness = .{ .waiter = .{ .wake_fn = WaiterHarness.wake }, .signaled = &signaled };
    try std.testing.expect(thunk.enrollWaiter(&w.waiter));

    go.store(1, .release);
    while (signaled.load(.acquire) == 0) std.atomic.spinLoopHint();
    t.join();

    // After reset, the thunk is back to .unresolved — a fresh tryForce
    // should claim it.
    switch (thunk.tryForce(makeClaimer(0x10000000))) {
        .claimed => {},
        else => return error.ExpectedClaimedAfterReset,
    }
}

test "the created-tsc probe follows the build flag on every supported arch" {
    if (!build_options.prof_main) return error.SkipZigTest;
    if (!timebase.supported) return error.SkipZigTest;
    try std.testing.expect(created_tsc_enabled);
    // `CreatedTsc` is `void` while the gate is off, so the value check must
    // not be analyzed in that state.
    if (comptime created_tsc_enabled) try std.testing.expect(nowCreatedTsc() != 0);
}
