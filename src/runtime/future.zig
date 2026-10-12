//! Generic lock-free one-shot claim cell used by thunks, imports, realization
//! claims, and asynchronous I/O: a state word, claimer id, and waiter list.
//!
//! A `Future` is claimed once — the first fiber to CAS the state word
//! from `.unresolved` to `.evaluating` runs the work; every other fiber
//! enrolls a `Waiter` and yields until the claimer publishes a terminal
//! state (`.resolved` / `.errored` / `.blackhole`) or resets it. The
//! embedder owns the result payload; the `Future` owns only the
//! transition protocol and the parking list. All state transitions
//! follow release-acquire pairs so a plain result store made before
//! `publish` is visible to any reader that acquire-loads the terminal
//! state via `tryClaim`. This is the concurrency core — the atomic
//! orderings here are load-bearing.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("base").sync;

pub const protocol_checks = builtin.mode == .debug or builtin.mode == .safe;

/// `state` is a u32 so it's the right shape for futex-style ops if we
/// ever need them. The low byte encodes the lifecycle (`FutureState`);
/// the rest is zero.
/// State-word layout: the LOW BYTE is the FutureState FSM field — the
/// protocol the FutureWait TLA models pin is that byte alone. The high
/// bits carry per-thunk flags ORTHOGONAL to the protocol (demanded /
/// target-kind / has-effect-group, packed here so `Thunk` sheds its
/// separate flag word: 8 bytes × every heap object). Every transition
/// preserves the flag bits via CAS, so a concurrent `markDemanded` is
/// never lost; flag reads/writes are single-bit atomics on the same word.
/// The GC-swept sentinel remains a FULL-WORD compare: a live word's low
/// byte is always a valid FutureState, and the sentinel's (0x0D) is not,
/// so no flag combination can collide with it.
pub const state_field_mask: u32 = 0xFF;
pub const flag_demanded: u32 = 1 << 8;
pub const flag_kind_shift: u5 = 9;
pub const flag_kind_mask: u32 = 0b111 << flag_kind_shift;
pub const flag_has_effects: u32 = 1 << 12;

pub inline fn stateFieldRaw(raw: u32) u32 {
    return raw & state_field_mask;
}

pub const FutureState = enum(u32) {
    unresolved = 0,
    evaluating = 1,
    resolved = 2,
    blackhole = 3,
    /// The work ran and failed deterministically. The embedder owns the
    /// associated error payload.
    errored = 4,
};

/// Detector sentinel (GC-debug builds): the sweep stamps a swept thunk's
/// state word with this so a stale claim through a raw pointer — captured
/// before a park and never re-checked against the alloc bitmap — traps at
/// the exact deref instead of silently reading the retained slot.
pub const poisoned_state: u32 = 0xDEAD_F00D;

/// Identity of whoever is currently claiming a thunk. Each fiber is
/// assigned a globally unique 32-bit id at allocation time (from the
/// scheduler's `next_fiber_id` counter). The claimer is just that id.
///
/// Blackhole detection compares ids directly: same fiber re-entering
/// its own evaluation = real recursion; different fiber on any worker
/// = must wait. Migration does not change the id.
pub const ClaimerId = u32;
pub const invalid_claimer: ClaimerId = std.math.maxInt(ClaimerId);

pub fn makeClaimer(fiber_id: u32) ClaimerId {
    return fiber_id;
}

/// Lightweight linked-list node used to enroll fibers on a future's
/// waiter list. The future owns the list; the embedding struct (a
/// FiberSlot in worker.zig) supplies `wake_fn`, which is invoked when
/// the future resolves/resets/blackholes. `wake_fn` typically marks
/// the parent slot resumable and nudges its owning worker.
///
/// Embedders use `@fieldParentPtr("waiter", w)` inside `wake_fn` to
/// recover the parent. The Future is intentionally agnostic about
/// what the parent is — it just walks pointers.
pub const Waiter = struct {
    next: ?*Waiter = null,
    wake_fn: *const fn (*Waiter) void,
    /// Debug/safe-build ownership bit for the embedding contract: one waiter
    /// node may be enrolled on at most one Future at a time. Release-fast
    /// builds keep the original zero-overhead representation.
    enrolled: if (protocol_checks) std.atomic.Value(u8) else void = if (protocol_checks) .init(0) else {},
};

/// Bare outcome of a claim attempt — no payload. The embedder
/// (`Thunk`/`ImportEntry`) owns its typed result/error storage and
/// reads it itself once `tryClaim` reports a terminal state. Keeping
/// the value out of `Future` lets `Thunk` overlap its resolved
/// `result` with its still-unresolved `target` (never live at once),
/// shrinking the hottest, most-numerous heap object.
pub const ClaimResult = enum { already_resolved, claimed, blackhole, busy, errored };

/// Shared claim+wait state machine. Thunks, imports, realization claims, and
/// I/O fibers embed one. A `Future` owns a five-state lifecycle, a claimer id,
/// and a fiber waiter list. It deliberately does NOT
/// own the result — the embedding struct stores its own typed result
/// (a `Value`, a `FailureRef`, or in `Thunk`'s case a `result`/`target`
/// union) and reads/writes it around the state transitions. Keeping the
/// result out of `Future` lets `Thunk` overlap its resolved value with
/// its unresolved target (never live at once), shrinking the hottest,
/// most-numerous heap object.
///
/// `tryClaim` is the central method. The first caller to observe
/// `.unresolved` CAS-claims to `.evaluating` and gets `.claimed` — it
/// must compute the work, write the embedder's result slot, then call
/// exactly one of `publish`, `publishErrored`, `reset`, or `blackhole`.
/// Other callers see `.busy` and enroll a `Waiter` via `enrollWaiter`.
///
/// Memory model: the embedder writes its result slot with a plain store
/// BEFORE calling `publish`/`publishErrored`; the release-store of
/// `state` inside those methods publishes that write to any reader that
/// acquire-loads the terminal state via `tryClaim`.
pub const Future = struct {
    state: std.atomic.Value(u32),
    claimer: std.atomic.Value(ClaimerId),
    /// Singly-linked list of fibers parked on this future, packed with
    /// its lock into ONE word (8 bytes instead of pointer + mutex — the
    /// Future rides in every thunk, so the word is worth 2.3GB on a
    /// whole-nixpkgs eval): 0 = empty/unlocked, LSB set = locked (Waiter
    /// is 8-aligned, so the bit is free), else the head pointer. The
    /// critical sections serialize exactly as the mutex version did;
    /// empty in the common (uncontended) case where the claimer resolves
    /// before any other fiber tries to force.
    waiters: std.atomic.Value(usize),
    pub fn init() Future {
        return .{
            .state = .init(@backingInt(FutureState.unresolved)),
            .claimer = .init(invalid_claimer),
            .waiters = .init(0),
        };
    }

    /// Construct a Future born in `.resolved`. The embedder writes its own
    /// result slot before making the future reachable.
    pub fn initResolved() Future {
        return .{
            .state = .init(@backingInt(FutureState.resolved)),
            .claimer = .init(invalid_claimer),
            .waiters = .init(0),
        };
    }

    /// Construct a Future born in `.evaluating` claimed by `claimer`.
    /// Used by `Thunk.initBindingCell` so a concurrent force attempt
    /// sees BUSY and parks instead of CAS-claiming a placeholder.
    pub fn initClaimed(claimer: ClaimerId) Future {
        return .{
            .state = .init(@backingInt(FutureState.evaluating)),
            .claimer = .init(claimer),
            .waiters = .init(0),
        };
    }

    /// Non-claiming peek: is this future still being evaluated by *someone*?
    /// A single acquire-load, no CAS — safe to poll from a waiter that wants
    /// to spin briefly before committing to enroll+suspend (see
    /// `force.zig`'s `.busy` spin-before-enroll). A `false` return means the
    /// state left `.evaluating` (resolved / errored / reset); the caller
    /// should re-`tryClaim` to observe the terminal state.
    pub inline fn isEvaluating(self: *const Future) bool {
        return stateFieldRaw(self.state.load(.acquire)) == @backingInt(FutureState.evaluating);
    }

    /// Masked read of the FSM field (flags stripped). Use for every
    /// comparison against FutureState values; comparing the raw word
    /// breaks silently once any flag bit is set.
    pub inline fn stateField(self: *const Future, comptime order: std.builtin.AtomicOrder) FutureState {
        return @fromBackingInt(@intCast(stateFieldRaw(self.state.load(order))));
    }

    /// Flag-preserving FSM transition: CAS keeps the high flag bits intact
    /// so a concurrent `markDemanded` (fetchOr on the same word) is never
    /// lost. Uncontended cost is one extra load over the old plain store.
    inline fn transition(self: *Future, new_state: FutureState, comptime order: std.builtin.AtomicOrder) void {
        var cur = self.state.load(.monotonic);
        while (true) {
            const next = (cur & ~state_field_mask) | @backingInt(new_state);
            cur = self.state.cmpxchgWeak(cur, next, order, .monotonic) orelse return;
        }
    }

    /// Solo-mode flag-preserving transition (plain read-modify-store; see
    /// `tryClaimSolo` for the single-thread contract).
    inline fn transitionSolo(self: *Future, new_state: FutureState) void {
        const cur = self.state.load(.monotonic);
        self.state.store((cur & ~state_field_mask) | @backingInt(new_state), .monotonic);
    }

    /// Try to claim this future for evaluation by `claimer`. Returns a
    /// bare outcome tag; on `.already_resolved`/`.errored` the caller
    /// reads the value/error from the embedder's own result slot.
    ///   - `.already_resolved`: the result is published; read the
    ///     embedder's result slot.
    ///   - `.claimed`: this caller has claimed; must compute, write the
    ///     embedder's result, then call `publish`, `publishErrored`,
    ///     `reset`, or `blackhole`.
    ///   - `.blackhole`: the SAME claim identity is already evaluating —
    ///     real recursion (a fiber re-entering itself).
    ///   - `.busy`: a different claim identity is evaluating; caller
    ///     must enroll on the waiter list and yield.
    ///   - `.errored`: the body ran and failed deterministically; caller
    ///     should re-raise the cached error.
    pub fn tryClaim(self: *Future, claimer: ClaimerId) ClaimResult {
        while (true) {
            const raw = self.state.load(.acquire);
            if (comptime protocol_checks) {
                if (raw == poisoned_state)
                    @panic("Future.tryClaim on a GC-swept object — stale reference held across a collection (missing root)");
            }
            const s: FutureState = @fromBackingInt(@intCast(stateFieldRaw(raw)));
            switch (s) {
                .resolved => return .already_resolved,
                .blackhole => return .blackhole,
                .errored => return .errored,
                .unresolved => {
                    // Full-word expected: carries the flag bits read above,
                    // so a racing markDemanded just retries the loop.
                    const prev = self.state.cmpxchgWeak(
                        raw,
                        (raw & ~state_field_mask) | @backingInt(FutureState.evaluating),
                        .acquire,
                        .monotonic,
                    );
                    if (prev == null) {
                        self.claimer.store(claimer, .release);
                        return .claimed;
                    }
                    continue;
                },
                .evaluating => {
                    const c = self.claimer.load(.acquire);
                    if (c == claimer) return .blackhole;
                    return .busy;
                },
            }
        }
    }

    /// `tryClaim` for a single-worker process (`--workers=1`): exactly one
    /// OS thread touches thunk futures, so the claim CAS — a full fence +
    /// serialized RMW on x86, paid once per claimed force — degenerates to a
    /// plain load/store pair. Fibers on that one thread interleave only at
    /// yield points, never inside this function, so the read-check-write is
    /// atomic with respect to every other future user. Blackhole detection
    /// (same-claimer re-entry) is unchanged. The caller owns the solo-ness
    /// proof (`VM.solo`, derived from `Scheduler.worker_count == 1` before
    /// any helper could exist); mixing solo and atomic calls on one thread
    /// is fine — plain and atomic accesses to the same word are ordered by
    /// program order there.
    pub fn tryClaimSolo(self: *Future, claimer: ClaimerId) ClaimResult {
        // `.monotonic` compiles to plain mov on x86 — the win is dropping
        // the CAS, not the atomic qualifier. Staying atomic keeps any
        // overlooked cross-thread observer (a future sampler, a debug
        // walker) merely stale instead of racy.
        const raw = self.state.load(.monotonic);
        if (comptime protocol_checks) {
            if (raw == poisoned_state)
                @panic("Future.tryClaimSolo on a GC-swept object — stale reference held across a collection (missing root)");
        }
        switch (@as(FutureState, @fromBackingInt(@intCast(stateFieldRaw(raw))))) {
            .resolved => return .already_resolved,
            .blackhole => return .blackhole,
            .errored => return .errored,
            .unresolved => {
                self.state.store((raw & ~state_field_mask) | @backingInt(FutureState.evaluating), .monotonic);
                self.claimer.store(claimer, .monotonic);
                return .claimed;
            },
            .evaluating => return if (self.claimer.load(.monotonic) == claimer) .blackhole else .busy,
        }
    }

    /// `publish` for a single-worker process: plain stores, and the waiter
    /// drain skips the waiter-word RMW when nobody ever enrolled (the
    /// overwhelmingly common case — enrollment means some same-thread fiber
    /// observed `.busy` and parked, and its list push is plainly visible
    /// here). Same solo-ness contract as `tryClaimSolo`.
    pub fn publishSolo(self: *Future) void {
        self.claimer.store(invalid_claimer, .monotonic);
        self.transitionSolo(.resolved);
        if (self.waiters.load(.monotonic) != 0) self.wakeFiberWaiters();
    }

    /// `reset` for a single-worker process — see `publishSolo` for the
    /// contract. Used by the binding-cell publish (`cell_set` runs once per
    /// recursive let binding, which pays the waiter-mutex RMW otherwise).
    pub fn resetSolo(self: *Future) void {
        self.claimer.store(invalid_claimer, .monotonic);
        self.transitionSolo(.unresolved);
        if (self.waiters.load(.monotonic) != 0) self.wakeFiberWaiters();
    }

    /// Enroll a fiber waiter on this future. Returns true if the waiter
    /// was added to the list (caller should yield and wait for `wake_fn`).
    /// Returns false if the future left `.evaluating` between the caller's
    /// `tryForce` and now — caller should re-loop `tryForce` instead.
    ///
    /// Ordering: we re-check `state` under the lock so that any caller
    /// that observes `.evaluating` and enrolls is guaranteed to be drained
    /// by the resolver, which takes the same lock after publishing the
    /// new state.
    pub fn enrollWaiter(self: *Future, waiter: *Waiter) bool {
        comptime std.debug.assert(@alignOf(Waiter) >= 2); // LSB is the lock bit
        // Lock the waiters word (spin: enroll and wake critical sections
        // are a few instructions).
        var head: usize = undefined;
        while (true) {
            head = self.waiters.load(.monotonic);
            if (head & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;
            }
            if (self.waiters.cmpxchgWeak(head, head | 1, .seq_cst, .monotonic) == null) break;
        }
        // Re-check under the lock, exactly as the mutex version: any
        // caller that observes `.evaluating` here is guaranteed to be
        // drained by the resolver, whose wake performs a seq_cst RMW on
        // the same word after publishing the new state — the two RMWs are
        // totally ordered, so either the resolver sees our lock bit (and
        // waits for the push) or we see its published state here (seq_cst
        // pairs with the resolver's barrier; see wakeFiberWaiters).
        const s: FutureState = @fromBackingInt(@intCast(stateFieldRaw(self.state.load(.seq_cst))));
        if (s != .evaluating) {
            self.waiters.store(head, .release); // unlock, list unchanged
            return false;
        }
        if (comptime protocol_checks) {
            if (waiter.enrolled.swap(1, .acq_rel) != 0)
                @panic("Future waiter enrolled more than once");
        }
        waiter.next = if (head == 0) null else @ptrFromInt(head);
        self.waiters.store(@intFromPtr(waiter), .release); // push + unlock
        return true;
    }

    /// Publish the embedder's already-written result and wake all
    /// enrolled fiber waiters. The caller MUST have stored its result
    /// slot before this call; the release-store of `state` publishes it.
    pub fn publish(self: *Future) void {
        self.claimer.store(invalid_claimer, .release);
        self.transition(.resolved, .release);
        self.wakeFiberWaiters();
    }

    /// Drop back to `.unresolved` and wake waiters so they can retry.
    /// Use only for *transient* errors (out-of-memory, stack overflow,
    /// scheduler contention) — deterministic failures should go through
    /// `publishErrored` instead. The embedder's `target` is left intact
    /// (a transient failure never overwrote it with a result).
    pub fn reset(self: *Future) void {
        self.claimer.store(invalid_claimer, .monotonic);
        self.transition(.unresolved, .release);
        self.wakeFiberWaiters();
    }

    /// Publish a deterministic body failure and wake waiters. The
    /// embedder has already stashed its failure handle in the result slot.
    /// The handle's immutable record, if any, is owned out-of-band by the
    /// engine rather than by this future.
    pub fn publishErrored(self: *Future) void {
        self.claimer.store(invalid_claimer, .monotonic);
        self.transition(.errored, .release);
        self.wakeFiberWaiters();
    }

    /// Mark this future as a blackhole. Wakes waiters so they observe
    /// the new state and return an error.
    pub fn blackhole(self: *Future) void {
        self.claimer.store(invalid_claimer, .monotonic);
        self.transition(.blackhole, .release);
        self.wakeFiberWaiters();
    }

    /// Drain the waiter list under the lock, then call each waiter's
    /// `wake_fn` outside the lock so a slow wake doesn't block other
    /// resolvers waiting to drain their own (different) futures' lists.
    fn wakeFiberWaiters(self: *Future) void {
        // The empty-check MUST be an RMW, not a plain load: the caller
        // just release-stored the new `state`, and a plain load may
        // execute while that store still sits in the store buffer — an
        // enroller then locks the word, re-checks `state`, reads the
        // STALE value, and parks forever (the mutex version was immune
        // because even its empty wake performed lock+unlock, giving the
        // next enroller a synchronizes-with edge). A seq_cst no-op RMW is
        // a full barrier AND totally ordered against the enroller's
        // seq_cst lock CAS on this same word; it still costs less than
        // the old mutex's lock+unlock pair.
        var stolen: usize = self.waiters.fetchOr(0, .seq_cst);
        while (true) {
            if (stolen & 1 != 0) {
                std.atomic.spinLoopHint();
                stolen = self.waiters.load(.monotonic);
                continue;
            }
            if (stolen == 0) return;
            if (self.waiters.cmpxchgWeak(stolen, 0, .acquire, .monotonic)) |actual| {
                stolen = actual;
                continue;
            }
            break;
        }
        var head: ?*Waiter = @ptrFromInt(stolen);
        while (head) |w| {
            const next = w.next;
            w.next = null;
            if (comptime protocol_checks) {
                if (w.enrolled.swap(0, .acq_rel) != 1)
                    @panic("Future drained a waiter that was not enrolled");
            }
            w.wake_fn(w);
            head = next;
        }
    }
};
