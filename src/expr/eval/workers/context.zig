//! Fiber-scoped execution identity.
//!
//! Every `WorkerFiber` owns one `ExecutionContext`; its VM — and every
//! nested VM created while running on that fiber (imports, render/force
//! bodies) — reads identity through `VM.ctx`, so nested VMs share their fiber's
//! identity structurally.
//!
//! Lifetime and ownership:
//!   - The record lives exactly as long as its fiber (stable memory — it is
//!     embedded in the `WorkerFiber`, which is never reallocated).
//!   - Single writer: only the fiber's driving worker mutates it, and only
//!     between resumes — `allocateFiber` bakes the claim id once,
//!     `runTopLevel(s)` dresses the demand role on each top fiber before its
//!     first resume, and `runFiber`'s finished arm resets the role before the
//!     fiber recycles. Readers (the VM run paths) only see it while the fiber
//!     runs, sequenced by the same handoff that publishes all other fiber
//!     state.

const std = @import("std");
const future_mod = @import("runtime").future;
const FailureRef = @import("runtime").failure.FailureRef;
const ErrorTrace = @import("../../observ.zig").trace.Trace;

/// Native-stack headroom reserved below `stack_limit`: the guard trips this
/// far from the mapping's end so the deepest single force step between two
/// guard checks — plus the error-capture/unwind that follows — completes
/// without running off the stack. 512 KiB is generous against the few-KiB
/// force-frame nest; the check is per `forceThunkImpl` (once per chain link).
pub const stack_guard_margin: usize = 512 * 1024;

pub const ExecutionContext = struct {
    /// Globally-unique claim identity for thunk forces — `makeClaimer` of
    /// the owning fiber's id. Baked once at fiber allocation and permanent
    /// for the fiber's life (it survives task recycles, unlike the role
    /// fields below). `invalid_claimer` only in the static default (VMs not
    /// bound to any fiber).
    claimer_id: future_mod.ClaimerId = future_mod.invalid_claimer,
    /// Lowest native stack address the running fiber may touch before the
    /// thunk-force guard trips a graceful "stack overflow" (`= stack base +
    /// stack_guard_margin`). Baked once at fiber allocation from the fiber's
    /// own stack, like `claimer_id`. 0 for VMs not bound to a fiber (tools,
    /// standalone test VMs on the main thread) — a real address is always
    /// ≥ 0, so the `frameAddress() < stack_limit` compare never fires there.
    stack_limit: usize = 0,
    /// True only on a top-level DEMAND fiber for the duration of one
    /// top-level entry: its blocking waits on busy thunks are the serial
    /// critical path. Set by
    /// `Worker.runTopLevel(s)`; cleared by the recycle reset.
    is_demand: bool = false,
    /// Parallel top-level demand entries intentionally do not contribute to
    /// the evaluator's single-run diagnostic trace. Each input installs its
    /// own trace below so build can report failures without a shared race.
    parallel_demand: bool = false,
    /// Per-input error trace installed while a parallel demand fiber runs.
    /// Nested import VMs inherit it through this structural fiber context.
    error_trace: ?*ErrorTrace = null,
    /// The exception currently propagating through this fiber. Nested VMs
    /// borrow the same context, so imports and resumed/migrated execution
    /// cannot lose or replace its diagnostic identity accidentally.
    pending_failure: ?FailureRef = null,
    /// `tryEval` catch depth is fiber state: a nested import VM must still
    /// suppress debugger entry for an exception its caller intends to catch.
    tryeval_depth: u32 = 0,
    /// Nested value-recursion levels, counted against `max-call-depth` exactly
    /// as function calls are. The coercion bodies (`__toString` / `outPath` /
    /// list walks) and the XML writer's structural walk recurse on the native
    /// stack, so a self-referential value has no other bound. Fiber state for
    /// the same reason as `tryeval_depth`: a nested import VM continues its
    /// caller's walk.
    coerce_depth: u32 = 0,
    /// Head of the in-progress `builtins.scopedImport` path chain. Unlike an
    /// OS-thread-local, this travels with the fiber when work stealing resumes
    /// it on another worker. Frames themselves live on the suspended fiber's
    /// stack and are popped before that stack can be recycled.
    scoped_import_top: ?*const ScopedImportFrame = null,
    /// Fiber-owned waiter and yield operation used by VM force paths without
    /// importing the concrete WorkerFiber representation.
    park: ?ParkHandle = null,

    /// Publish a newly captured origin only when no exception is already
    /// unwinding. Ancestor catches therefore preserve the original identity.
    pub fn capture(self: *ExecutionContext, failure: FailureRef) void {
        if (self.pending_failure == null) self.pending_failure = failure;
    }

    /// Install a borrowed cached failure at an observation boundary. Existing
    /// propagation wins so an ancestor cannot replace the original cause.
    pub fn install(self: *ExecutionContext, failure: FailureRef) void {
        if (self.pending_failure == null) self.pending_failure = failure;
    }

    pub fn pending(self: *const ExecutionContext) ?FailureRef {
        return self.pending_failure;
    }

    /// Temporarily remove the propagating exception while a catch performs
    /// fallible work of its own (notably `addErrorContext`'s message coercion).
    pub fn take(self: *ExecutionContext) ?FailureRef {
        const failure = self.pending_failure;
        self.pending_failure = null;
        return failure;
    }

    pub fn restore(self: *ExecutionContext, failure: FailureRef) void {
        std.debug.assert(self.pending_failure == null);
        self.pending_failure = failure;
    }

    pub fn clearFailure(self: *ExecutionContext) void {
        self.pending_failure = null;
    }

    /// Clear the demand-role fields when the fiber recycles onto the free
    /// list (a reused fiber must not mislabel its next task as demand).
    /// The claim id is permanent and survives.
    pub fn resetRole(self: *ExecutionContext) void {
        // A scoped-import frame is stack-scoped and must have unwound before
        // the fiber can finish and return to the recycle list.
        std.debug.assert(self.scoped_import_top == null);
        std.debug.assert(self.tryeval_depth == 0);
        std.debug.assert(self.coerce_depth == 0);
        self.pending_failure = null;
        self.error_trace = null;
        self.is_demand = false;
        self.parallel_demand = false;
    }
};

pub const ParkHandle = struct {
    waiter: *future_mod.Waiter,
    context: *anyopaque,
    yield_fn: *const fn (context: *anyopaque) void,

    pub fn yield(self: ParkHandle) void {
        self.yield_fn(self.context);
    }
};

/// One node in a fiber's active scoped-import chain. Kept here, beside the
/// owning head pointer, so import coordination does not smuggle fiber-local
/// state through OS-thread-local storage.
pub const ScopedImportFrame = struct {
    path: []const u8,
    next: ?*const ScopedImportFrame,
};
