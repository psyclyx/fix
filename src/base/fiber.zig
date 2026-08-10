//! Stackful fiber primitive — the foundation for suspendable thunk evaluation.
//!
//! A fiber is a chunk of computation running on its own stack. The fiber's
//! owner (typically a worker thread) calls `resume_` to switch onto the
//! fiber's stack and run its entry function. The fiber can call `yield`
//! to switch back to whoever resumed it, suspending its state for later
//! resumption.
//!
//! Stack switching is done by `contextSwitch`, an inline-asm routine
//! vendored from Zig's `std.Io.fiber`. It saves the stack pointer, frame
//! pointer and resume address into a `Context`. AArch64 also saves the link
//! register explicitly; every other register
//! — callee-saved GPRs, the vector file, and the FP/flags control state
//! (`mxcsr`/`fpcr`/direction flag) — is listed as clobbered, so the compiler
//! spills whatever is live around each swap site. Being `inline` is required:
//! the clobbers must apply at the real call sites. This also preserves FP
//! rounding mode and the direction flag across a swap.
//! The upstream copyright and MIT license are retained in
//! `LICENSES/zig-MIT.txt`.
//!
//! Fibers can be resumed from any OS thread. Each `resume_` replaces
//! `caller_ctx` with a pointer into that resumer's stack frame before switching
//! to the fiber. A stale pointer is never read between resumptions.
//! Threadlocal scheduler state is accessed through non-inlined functions so
//! its address is formed on the OS thread that is active after each migration.
//!
//! Lifecycle:
//!   .ready    — initialized, never resumed. `entry` will run on first resume.
//!   .running  — currently executing on its owner's thread.
//!   .suspended — yielded; `ctx` holds the saved state. Resumable.
//!   .finished — `entry` returned. Not resumable.
//!
//! The owner is responsible for not resuming a `.finished` or `.running`
//! fiber. Asserts guard this in debug builds.

const std = @import("std");
const builtin = @import("builtin");
const base_options = @import("base_options");
const timebase = @import("timebase.zig");

const tsan_enabled = base_options.tsan_enabled;
const TSanHandle = if (tsan_enabled) *anyopaque else void;

const tsan = if (tsan_enabled) struct {
    extern fn __tsan_get_current_fiber() ?*anyopaque;
    extern fn __tsan_create_fiber(flags: u32) ?*anyopaque;
    extern fn __tsan_destroy_fiber(fiber: *anyopaque) void;
    extern fn __tsan_switch_to_fiber(fiber: *anyopaque, flags: u32) void;

    /// Cooperative execution on one kernel thread is ordered. Migration still
    /// depends on the scheduler's real queue synchronization; concurrent
    /// fibers on different workers remain unordered and race-visible.
    const switch_flags: u32 = 0;
} else struct {};

comptime {
    switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => {},
        else => @compileError("fiber.zig only supports x86_64 and aarch64"),
    }
}

/// Fiber cost census (piggybacks on `-Dprof-main`): tick bracketing of
/// the swap-in (dispatcher → fiber body) and swap-out (fiber body →
/// dispatcher) paths, threadlocal so the accumulation itself is free of
/// coherence traffic. `Worker.runFiber` seeds `census_pre_swap` at its
/// entry and drains `census_in_cy`/`census_in_n` after each resume, so
/// the swap-in window covers the complete per-resume machinery
/// (run_mu, timeline branch, spec-ctx refresh, `resume_` setup, the asm
/// swap) and the swap-out window symmetric machinery on the way back.
/// Zero-footprint when the build flag is off.
pub const census_enabled: bool = base_options.fiber_census and timebase.supported;

threadlocal var census_pre_swap: u64 = 0;
threadlocal var census_exit_swap: u64 = 0;
threadlocal var census_in_cy: u64 = 0;
threadlocal var census_in_n: u64 = 0;

pub const CensusSample = struct {
    exit_swap: u64,
    in_cy: u64,
    in_n: u64,
};

pub noinline fn censusSeed(pre_swap: u64) void {
    if (comptime census_enabled) census_pre_swap = pre_swap;
}

noinline fn censusRecordEntry(now: u64) void {
    if (comptime census_enabled) {
        census_in_cy += now -| census_pre_swap;
        census_in_n += 1;
    }
}

noinline fn censusRecordExit(now: u64) void {
    if (comptime census_enabled) census_exit_swap = now;
}

pub noinline fn censusDrain() CensusSample {
    if (comptime !census_enabled) return .{ .exit_swap = 0, .in_cy = 0, .in_n = 0 };
    const sample: CensusSample = .{
        .exit_swap = census_exit_swap,
        .in_cy = census_in_cy,
        .in_n = census_in_n,
    };
    census_in_cy = 0;
    census_in_n = 0;
    return sample;
}

pub inline fn censusNow() u64 {
    if (comptime !census_enabled) return 0;
    return timebase.read();
}

/// Minimal saved state for an inactive fiber. The offsets are load-bearing —
/// `contextSwitch` reads them directly. AArch64 also saves x30 explicitly:
/// LLVM may allocate a live value there across inline asm even when x30 is
/// listed as clobbered. Everything else the swap needs to preserve rides the
/// clobber list, not this struct.
pub const Context = switch (builtin.cpu.arch) {
    .x86_64 => extern struct { rsp: u64 = 0, rbp: u64 = 0, rip: u64 = 0 },
    .aarch64 => extern struct { sp: u64 = 0, fp: u64 = 0, pc: u64 = 0, lr: u64 = 0 },
    else => unreachable, // gated by the comptime block above
};

/// Save-into / restore-from pair for one context switch. Layout matches what
/// `contextSwitch` reads: `old` at offset 0, `new` at offset 8.
const Switch = extern struct { old: *Context, new: *Context };

const aarch64_switch_asm =
    \\ ldp x0, x2, [x1]
    \\ ldr x3, [x2, #16]
    \\ mov x4, sp
    \\ stp x4, fp, [x0]
    \\ adr x5, 0f
    \\ ldp x4, fp, [x2]
    \\ str x5, [x0, #16]
    \\ str x30, [x0, #24]
    \\ ldr x30, [x2, #24]
    \\ mov sp, x4
    \\ br x3
    \\0:
;

/// Save the current CPU state into `s.old`, restore `s.new`, and continue at
/// `s.new`'s resume address. Based on Zig 0.16 `std.Io.fiber`, with the message
/// register removed from each architecture's clobber list: it is already an
/// input and output operand, and declaring all three roles miscompiles optimized
/// builds (ziglang/zig#35724). The stack/frame/resume state is stored
/// explicitly, as is AArch64 x30; the remaining clobbers force the compiler to
/// preserve live state around the emitted swap. MUST stay
/// `inline` — the clobbers only bind at the real call site, never behind a call
/// boundary. The returned `*const Switch` is the resumer's message (unused
/// here).
inline fn contextSwitch(s: *const Switch) *const Switch {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\ movq 0(%%rsi), %%rax
            \\ movq 8(%%rsi), %%rcx
            \\ leaq 0f(%%rip), %%rdx
            \\ movq %%rsp, 0(%%rax)
            \\ movq %%rbp, 8(%%rax)
            \\ movq %%rdx, 16(%%rax)
            \\ movq 0(%%rcx), %%rsp
            \\ movq 8(%%rcx), %%rbp
            \\ jmpq *16(%%rcx)
            \\0:
            : [received_message] "={rsi}" (-> *const Switch),
            : [message_to_send] "{rsi}" (s),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rbx = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .r12 = true,
              .r13 = true,
              .r14 = true,
              .r15 = true,
              .mm0 = true,
              .mm1 = true,
              .mm2 = true,
              .mm3 = true,
              .mm4 = true,
              .mm5 = true,
              .mm6 = true,
              .mm7 = true,
              .zmm0 = true,
              .zmm1 = true,
              .zmm2 = true,
              .zmm3 = true,
              .zmm4 = true,
              .zmm5 = true,
              .zmm6 = true,
              .zmm7 = true,
              .zmm8 = true,
              .zmm9 = true,
              .zmm10 = true,
              .zmm11 = true,
              .zmm12 = true,
              .zmm13 = true,
              .zmm14 = true,
              .zmm15 = true,
              .zmm16 = true,
              .zmm17 = true,
              .zmm18 = true,
              .zmm19 = true,
              .zmm20 = true,
              .zmm21 = true,
              .zmm22 = true,
              .zmm23 = true,
              .zmm24 = true,
              .zmm25 = true,
              .zmm26 = true,
              .zmm27 = true,
              .zmm28 = true,
              .zmm29 = true,
              .zmm30 = true,
              .zmm31 = true,
              .fpsr = true,
              .fpcr = true,
              .mxcsr = true,
              .rflags = true,
              .dirflag = true,
              .memory = true,
            }),
        .aarch64 => asm volatile (aarch64_switch_asm
            : [received_message] "={x1}" (-> *const Switch),
            : [message_to_send] "{x1}" (s),
            : .{
              .x0 = true,
              .x2 = true,
              .x3 = true,
              .x4 = true,
              .x5 = true,
              .x6 = true,
              .x7 = true,
              .x8 = true,
              .x9 = true,
              .x10 = true,
              .x11 = true,
              .x12 = true,
              .x13 = true,
              .x14 = true,
              .x15 = true,
              .x16 = true,
              .x17 = true,
              // x18 is the platform register on Darwin and must not be
              // clobbered there. Linux treats it as an ordinary caller-saved
              // register, so LLVM must not keep a live value in it across the
              // stack switch.
              .x18 = !builtin.os.tag.isDarwin(),
              .x19 = true,
              .x20 = true,
              .x21 = true,
              .x22 = true,
              .x23 = true,
              .x24 = true,
              .x25 = true,
              .x26 = true,
              .x27 = true,
              .x28 = true,
              .z0 = true,
              .z1 = true,
              .z2 = true,
              .z3 = true,
              .z4 = true,
              .z5 = true,
              .z6 = true,
              .z7 = true,
              .z8 = true,
              .z9 = true,
              .z10 = true,
              .z11 = true,
              .z12 = true,
              .z13 = true,
              .z14 = true,
              .z15 = true,
              .z16 = true,
              .z17 = true,
              .z18 = true,
              .z19 = true,
              .z20 = true,
              .z21 = true,
              .z22 = true,
              .z23 = true,
              .z24 = true,
              .z25 = true,
              .z26 = true,
              .z27 = true,
              .z28 = true,
              .z29 = true,
              .z30 = true,
              .z31 = true,
              .p0 = true,
              .p1 = true,
              .p2 = true,
              .p3 = true,
              .p4 = true,
              .p5 = true,
              .p6 = true,
              .p7 = true,
              .p8 = true,
              .p9 = true,
              .p10 = true,
              .p11 = true,
              .p12 = true,
              .p13 = true,
              .p14 = true,
              .p15 = true,
              .fpcr = true,
              .fpsr = true,
              .memory = true,
            }),
        else => unreachable,
    };
}

/// Save the running context into `from` and switch to `to`. `inline` so the
/// vendored `contextSwitch` clobbers bind at the caller (`resume_`, `yield`, or
/// `trampoline`).
inline fn swap(from: *Context, to: *Context, destination_tsan: TSanHandle) void {
    var s = Switch{ .old = from, .new = to };
    if (comptime tsan_enabled)
        tsan.__tsan_switch_to_fiber(destination_tsan, tsan.switch_flags);
    _ = contextSwitch(&s);
}

/// Zeroed headroom kept between the fiber's seeded SP and the very top of the
/// stack mapping. Stack-trace capture (DebugAllocator large allocs, panics,
/// error traces) may unwind through the fiber's entry frame; macOS's
/// compact-unwind path then dereferences the entry frame's CFA — the seeded SP
/// itself. Seeded flush against the mapping end, that read is one byte past
/// the region (a nightly Debug stress .ips showed KERN_INVALID_ADDRESS exactly
/// at a 32 MiB fiber-stack boundary; the pre-CrashReporter symptom was the
/// in-process segfault handler wedging on the same walk). With headroom the
/// read lands in-mapping and returns zeros — a null frame record, which
/// terminates every unwinder. Stacks grow DOWN from the seeded SP, so the
/// headroom is never written and stays mmap-zero across fiber recycles.
const unwind_headroom: usize = 4096;

/// Bootstrap a fresh `Context` on `stack` so the first switch into it lands in
/// `trampoline` on the fiber's own stack. `contextSwitch` loads sp/fp and jumps
/// straight to the saved address, so we seed the resume address directly (no
/// pushed return slot).
fn bootstrapContext(stack: []u8) Context {
    const top = @intFromPtr(stack.ptr) + stack.len - unwind_headroom;
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // The switch `jmp`s to `rip` — entering `trampoline` as if via a
            // `call` (which pushes 8 bytes). SysV wants rsp ≡ 8 (mod 16) at
            // entry, so seed the 16-aligned top minus 8.
            const sp_start = (top & ~@as(usize, 15)) - 8;
            return .{ .rsp = sp_start, .rbp = 0, .rip = @intFromPtr(&trampoline) };
        },
        .aarch64 => {
            // AAPCS64 requires sp 16-byte aligned at all times; `top` is the
            // page-aligned mmap end minus the 16-aligned headroom, hence
            // 16-aligned. The switch `br`s to `pc`, so no return address is
            // pushed onto the stack.
            const sp_start = top & ~@as(usize, 15);
            return .{ .sp = sp_start, .fp = 0, .pc = @intFromPtr(&trampoline) };
        },
        else => unreachable,
    }
}

pub const State = enum(u8) {
    ready,
    running,
    suspended,
    finished,
};

pub const EntryFn = *const fn (arg: *anyopaque) void;

/// Threadlocal "currently running fiber on this OS thread", or null if
/// the bare OS thread is executing (not inside any fiber's stack).
///
/// Set by `resume_` before swapping in; restored to the previous value
/// when control returns. The trampoline reads this to find its own
/// fiber pointer at entry, since naked stack switching can't pass args
/// through the standard ABI.
threadlocal var current: ?*Fiber = null;

/// Form the TLS address in a fresh function invocation on the active OS
/// thread. This mirrors std.Io's `Thread.current`: if this access is inlined
/// into a fiber frame, LLVM may retain AArch64's TPIDR_EL0 across a yield and
/// address the previous thread's TLS after migration.
pub noinline fn currentFiber() ?*Fiber {
    return current;
}

noinline fn setCurrentFiber(fiber: ?*Fiber) void {
    current = fiber;
}

pub const Fiber = struct {
    ctx: Context,
    /// Owned heap-allocated stack buffer.
    stack: []u8,
    state: State,
    /// User-supplied entry function and argument. Cleared once `entry`
    /// returns so a finished fiber doesn't hold a dangling capture.
    entry: ?EntryFn,
    entry_arg: ?*anyopaque,
    /// Where to switch back to on yield/finish. Valid only while
    /// `state == .running`. Pointer into the resumer's stack, replaced before
    /// every switch to the fiber so a later resume from a different thread is
    /// safe.
    caller_ctx: ?*Context,
    /// ThreadSanitizer's logical execution context travels with a migratable
    /// fiber. The caller handle is replaced alongside `caller_ctx` on every
    /// resume and intentionally retained across yields and stack recycling.
    tsan_fiber: TSanHandle,
    caller_tsan_fiber: if (tsan_enabled) ?*anyopaque else void,

    /// Per-fiber stack reservation. Provisioned as a virtual mapping
    /// (PROT_READ|PROT_WRITE, MAP_ANONYMOUS|MAP_PRIVATE) — the kernel
    /// demand-pages it, so RSS scales with actual depth touched, not the
    /// full reservation. Only virtual address space is reserved up front
    /// (physical grows as the stack is touched, at zero hot-path cost), so
    /// this can be generous. The reservation exceeds `default_max_call_depth`,
    /// leaving room for deep forcing (which that limit does not bound) before the
    /// `forceThunkImpl` guard trips a graceful "stack overflow". Raising it
    /// costs virtual address space × peak fiber count, not memory.
    ///
    /// 32 MiB: the whole-nixpkgs monolithic eval's deepest demand chain
    /// (a ~10-native-frame cycle per recursion level through builtins and
    /// tail calls) sat within a few percent of a 16 MiB reservation —
    /// close enough that unrelated compiler-source changes tipped it over
    /// purely by shifting LLVM inlining (frame sizes), with no bytecode
    /// difference. Doubling buys the same workload 2x headroom so binary
    /// layout noise cannot flip a passing eval into a graceful
    /// StackOverflow.
    pub const min_stack_bytes: usize = 32 * 1024 * 1024;

    /// Allocate a fiber with its own stack and prepare it to invoke
    /// `entry(arg)` on first resume.
    ///
    /// The fiber's stack is mmapped directly rather than going through
    /// the supplied allocator: we want the kernel's lazy commit
    /// behaviour, and an mmap reservation is a much better fit for
    /// "huge virtual region, tiny working set" than the general-purpose
    /// allocator's heap. The allocator parameter is kept for API
    /// symmetry with `deinit` (which it likewise ignores).
    pub fn init(allocator: std.mem.Allocator, stack_bytes: usize, entry: EntryFn, arg: *anyopaque) !Fiber {
        _ = allocator;
        const page_size = std.heap.pageSize();
        const aligned_len = std.mem.alignForward(usize, stack_bytes, page_size);
        const stack_raw = std.posix.mmap(
            null,
            aligned_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return error.OutOfMemory;
        const stack: []u8 = stack_raw[0..aligned_len];
        errdefer std.posix.munmap(@alignCast(stack));
        // RSS attribution for the stack (fiber stacks are the process's most
        // numerous big mappings) is done by the *owner* that creates/destroys
        // fibers — see src/expr/eval/workers/worker.zig — not here, so the fiber primitive
        // stays free of the app's tag taxonomy.
        var fiber: Fiber = .{
            .ctx = .{},
            .stack = stack,
            .state = .ready,
            .entry = entry,
            .entry_arg = arg,
            .caller_ctx = null,
            .tsan_fiber = if (tsan_enabled) tsan.__tsan_create_fiber(0) orelse @panic("TSan failed to create fiber") else {},
            .caller_tsan_fiber = if (tsan_enabled) null else {},
        };

        // Set up the new stack so the first swap into this fiber lands in
        // `trampoline` on its own stack (arch-specific mechanism).
        fiber.ctx = bootstrapContext(stack);

        return fiber;
    }

    pub fn deinit(self: *Fiber, allocator: std.mem.Allocator) void {
        _ = allocator;
        // A live fiber whose stack is freed will crash on resume; the
        // caller must arrange shutdown semantics. RSS un-registration of the
        // stack is the owner's job (see src/expr/eval/workers/worker.zig).
        if (comptime tsan_enabled) tsan.__tsan_destroy_fiber(self.tsan_fiber);
        std.posix.munmap(@alignCast(self.stack));
        self.* = undefined;
    }

    /// Give the stack's dirty pages back to the OS (advisory), keeping
    /// `retain_top` bytes at the top — the hot end; stacks grow down.
    /// Call only on a `.finished`/`.ready` fiber: its frames are dead,
    /// so page contents are garbage by definition and a later re-fault
    /// reading zeros is indistinguishable from a fresh stack (`reset`
    /// rewrites the trampoline slot, and running code always writes a
    /// frame before reading it).
    ///
    /// `lazy` picks MADV_FREE (pages reclaimed only under memory
    /// pressure — free to call, RSS drops only when it matters) over
    /// MADV_DONTNEED (immediate reclaim, visible RSS drop, guaranteed
    /// re-fault on reuse).
    pub fn releaseStackPages(self: *Fiber, retain_top: usize, lazy: bool) void {
        // MADV_FREE / MADV_DONTNEED are available on Linux and Darwin; a
        // no-op on any other OS.
        if (comptime builtin.os.tag != .linux and !builtin.os.tag.isDarwin()) return;
        const page = std.heap.pageSize();
        const keep = std.mem.alignForward(usize, retain_top, page);
        if (self.stack.len <= keep) return;
        const len = self.stack.len - keep; // stack.len is page-aligned (mmap)
        const advice: u32 = if (lazy) std.posix.MADV.FREE else std.posix.MADV.DONTNEED;
        std.posix.madvise(@alignCast(self.stack.ptr), len, advice) catch {};
    }

    /// Rewind the fiber so the next `resume_` starts a fresh invocation
    /// of `entry(arg)` on the same stack buffer. Used by Worker to
    /// recycle a `.finished` fiber for a new task without allocating a
    /// new stack.
    ///
    /// Must NOT be called on a fiber in `.running` or `.suspended` —
    /// that would leak the fiber's call frames and break any waiters
    /// enrolled on thunks via its slot.
    pub fn reset(self: *Fiber, entry: EntryFn, arg: *anyopaque) void {
        std.debug.assert(self.state == .finished or self.state == .ready);
        self.ctx = bootstrapContext(self.stack);
        self.entry = entry;
        self.entry_arg = arg;
        self.caller_ctx = null;
        if (comptime tsan_enabled) self.caller_tsan_fiber = null;
        self.state = .ready;
    }

    /// Switch onto this fiber's stack and run until it yields or finishes.
    /// Returns when the fiber yields or returns from `entry`.
    pub fn resume_(self: *Fiber) void {
        std.debug.assert(self.state == .ready or self.state == .suspended);
        var here: Context = .{};
        const prev = currentFiber();
        setCurrentFiber(self);
        self.caller_ctx = &here;
        if (comptime tsan_enabled)
            self.caller_tsan_fiber = tsan.__tsan_get_current_fiber() orelse @panic("TSan lost caller fiber");
        self.state = .running;
        swap(&here, &self.ctx, if (tsan_enabled) self.tsan_fiber else {});
        // Back from the swap: the fiber either yielded (state == .suspended) or
        // completed (state == .finished).
        //
        // Do NOT clear `self.caller_ctx` here. After a *yield* the fiber can
        // already have been re-enqueued (its awaited resolved before it parked —
        // the ".suspended, already resolved" handoff) and resumed on another
        // worker, whose `resume_` has set `caller_ctx` to *its own* frame. Nulling
        // it here would race that store and strand the fiber without a caller.
        // The clear is also unnecessary: the next `resume_` sets `caller_ctx`
        // afresh before the fiber runs again, and `reset` nulls it for a recycled
        // fiber, so no stale/dangling value is ever read.
        setCurrentFiber(prev);
    }

    /// Yield from the *currently running* fiber back to whoever resumed it.
    /// Call only from inside a fiber's `entry` (directly or transitively).
    pub fn yield() void {
        const self = currentFiber() orelse @panic("Fiber.yield called outside a fiber");
        const back = self.caller_ctx orelse @panic("running fiber has no caller_ctx");
        self.state = .suspended;
        if (comptime census_enabled) censusRecordExit(censusNow());
        swap(&self.ctx, back, if (tsan_enabled) self.caller_tsan_fiber orelse @panic("TSan lost yield caller") else {});
        if (comptime census_enabled) censusRecordEntry(censusNow());
        // Resumed: caller_ctx has been set to the new resumer.
        self.state = .running;
    }
};

/// Entry point that the new fiber's stack is bootstrapped to. The first
/// switch into it jumps here on the fiber's own stack (its `Context.rip`/`pc`
/// is seeded to this by `bootstrapContext`). We pull the fiber pointer from the
/// threadlocal `current` (set by `resume_` before the swap), invoke the user
/// entry, and then swap back permanently — `entry` returning means the fiber
/// is done.
fn trampoline() callconv(.c) void {
    if (comptime census_enabled) censusRecordEntry(censusNow());
    const self = currentFiber() orelse @panic("trampoline started with no current fiber");
    const arg = self.entry_arg orelse unreachable;
    const entry = self.entry orelse unreachable;
    entry(arg);
    self.state = .finished;
    // Hold onto the back-ctx pointer before we (effectively) leave the
    // fiber. After the final swap we never resume — caller_ctx may be
    // gone by the time anyone else might read it.
    const back = self.caller_ctx orelse @panic("finished fiber has no caller_ctx");
    self.entry = null;
    self.entry_arg = null;
    if (comptime census_enabled) censusRecordExit(censusNow());
    swap(&self.ctx, back, if (tsan_enabled) self.caller_tsan_fiber orelse @panic("TSan lost finish caller") else {});
    // Should never get here — resuming a `.finished` fiber would re-run
    // the swap, which would land on whatever junk is below this point.
    @panic("trampoline reached unreachable after finish swap");
}

// ---- tests ----

const testing = std.testing;

test "fiber basic spawn / resume / finish" {
    const Ctx = struct {
        ran: bool = false,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.ran = true;
        }
    };
    var ctx: Ctx = .{};
    var fiber = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx);
    defer fiber.deinit(testing.allocator);

    try testing.expectEqual(State.ready, fiber.state);
    fiber.resume_();
    try testing.expect(ctx.ran);
    try testing.expectEqual(State.finished, fiber.state);
}

test "fiber yields and resumes mid-execution" {
    const Ctx = struct {
        steps: u32 = 0,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.steps = 1;
            Fiber.yield();
            ctx.steps = 2;
            Fiber.yield();
            ctx.steps = 3;
        }
    };
    var ctx: Ctx = .{};
    var fiber = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx);
    defer fiber.deinit(testing.allocator);

    fiber.resume_();
    try testing.expectEqual(@as(u32, 1), ctx.steps);
    try testing.expectEqual(State.suspended, fiber.state);

    fiber.resume_();
    try testing.expectEqual(@as(u32, 2), ctx.steps);
    try testing.expectEqual(State.suspended, fiber.state);

    fiber.resume_();
    try testing.expectEqual(@as(u32, 3), ctx.steps);
    try testing.expectEqual(State.finished, fiber.state);
}

test "fiber threadlocal `current` is set during run, cleared after" {
    const Ctx = struct {
        saw_self: ?*Fiber = null,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.saw_self = currentFiber();
        }
    };
    var ctx: Ctx = .{};
    var fiber = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx);
    defer fiber.deinit(testing.allocator);

    try testing.expect(currentFiber() == null);
    fiber.resume_();
    try testing.expectEqual(@as(?*Fiber, &fiber), ctx.saw_self);
    try testing.expect(currentFiber() == null);
}

test "two fibers multiplex on one thread" {
    // A simple ping-pong: each fiber writes its tag, yields, comes back.
    // We resume them alternately from the outer scope.
    const Ctx = struct {
        log: std.ArrayListUnmanaged(u8) = .empty,
        tag: u8 = 0,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            // Append three tag bytes interleaved with yields.
            var i: u8 = 0;
            while (i < 3) : (i += 1) {
                // The testing allocator captures an allocation stack. A
                // manually switched AArch64 stack has no unwind edge back to
                // the test runner, so use the page allocator for this
                // fiber-local allocation test.
                ctx.log.append(std.heap.page_allocator, ctx.tag) catch unreachable;
                Fiber.yield();
            }
        }
    };
    var ctx_a: Ctx = .{ .tag = 'A' };
    var ctx_b: Ctx = .{ .tag = 'B' };
    defer ctx_a.log.deinit(std.heap.page_allocator);
    defer ctx_b.log.deinit(std.heap.page_allocator);

    var fa = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx_a);
    var fb = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx_b);
    defer fa.deinit(testing.allocator);
    defer fb.deinit(testing.allocator);

    // Drive each fiber to completion. The entry body appends then
    // yields, so we need 4 resumes per fiber: three to append+yield
    // (states 'A', 'A', 'A' plus a trailing yield), and a fourth to
    // resume past the yield, fall out of the loop, and let entry return.
    var step: u32 = 0;
    while (step < 4) : (step += 1) {
        fa.resume_();
        fb.resume_();
    }

    try testing.expectEqualSlices(u8, "AAA", ctx_a.log.items);
    try testing.expectEqualSlices(u8, "BBB", ctx_b.log.items);
    try testing.expectEqual(State.finished, fa.state);
    try testing.expectEqual(State.finished, fb.state);
}

test "fiber resumed by different threads in sequence (migration)" {
    // Capture resumer IDs on their native stacks. Calling
    // std.Thread.getCurrentId() from the fiber body would test Zig's own
    // inline TLS implementation rather than this fiber primitive.
    const worker_id = @import("worker_id.zig");
    const previous_worker = worker_id.state();
    defer worker_id.set(previous_worker.id, previous_worker.is_worker);
    worker_id.set(17, true);

    const Ctx = struct {
        steps: std.atomic.Value(u32) = .init(0),
        observed_current: [3]?*Fiber = @splat(null),
        observed_worker: [3]u8 = @splat(0),
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.observed_current[0] = currentFiber();
            ctx.observed_worker[0] = worker_id.currentId();
            _ = ctx.steps.fetchAdd(1, .release);
            Fiber.yield();
            ctx.observed_current[1] = currentFiber();
            ctx.observed_worker[1] = worker_id.currentId();
            _ = ctx.steps.fetchAdd(1, .release);
            Fiber.yield();
            ctx.observed_current[2] = currentFiber();
            ctx.observed_worker[2] = worker_id.currentId();
            _ = ctx.steps.fetchAdd(1, .release);
        }
    };
    var ctx: Ctx = .{};
    var fiber = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx);
    defer fiber.deinit(testing.allocator);

    const first_thread_id = std.Thread.getCurrentId();
    fiber.resume_();
    try testing.expectEqual(@as(u32, 1), ctx.steps.load(.acquire));
    try testing.expectEqual(State.suspended, fiber.state);

    const Runner = struct {
        fn run(f: *Fiber, thread_id: *std.Thread.Id) void {
            thread_id.* = std.Thread.getCurrentId();
            worker_id.set(23, true);
            f.resume_();
        }
    };
    var second_thread_id: std.Thread.Id = undefined;
    var t = try std.Thread.spawn(.{}, Runner.run, .{ &fiber, &second_thread_id });
    t.join();
    try testing.expect(first_thread_id != second_thread_id);
    try testing.expectEqual(@as(u32, 2), ctx.steps.load(.acquire));
    try testing.expectEqual(State.suspended, fiber.state);

    fiber.resume_();
    try testing.expectEqual(@as(u32, 3), ctx.steps.load(.acquire));
    try testing.expectEqual(State.finished, fiber.state);
    for (ctx.observed_current) |observed|
        try testing.expectEqual(@as(?*Fiber, &fiber), observed);
    try testing.expectEqual([3]u8{ 17, 23, 17 }, ctx.observed_worker);
}

test "nested fiber call" {
    // An outer fiber resumes an inner fiber, which yields, then is resumed
    // by the outer fiber again. Validates that `current` is restored correctly
    // when control returns to an outer fiber after running an inner one.
    const InnerCtx = struct {
        ran_before_yield: bool = false,
        ran_after_yield: bool = false,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.ran_before_yield = true;
            Fiber.yield();
            ctx.ran_after_yield = true;
        }
    };
    const OuterCtx = struct {
        inner_fiber: *Fiber,
        observed_inner_current_before_resume: ?*Fiber = null,
        observed_self_current_between_resumes: ?*Fiber = null,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.observed_inner_current_before_resume = currentFiber();
            ctx.inner_fiber.resume_();
            // Now we're back in outer fiber. `current` must point at the
            // outer fiber itself, NOT at the inner one we just resumed.
            ctx.observed_self_current_between_resumes = currentFiber();
            ctx.inner_fiber.resume_();
        }
    };

    var inner_ctx: InnerCtx = .{};
    var inner = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, InnerCtx.entry, &inner_ctx);
    defer inner.deinit(testing.allocator);

    var outer_ctx: OuterCtx = .{ .inner_fiber = &inner };
    var outer = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, OuterCtx.entry, &outer_ctx);
    defer outer.deinit(testing.allocator);

    outer.resume_();

    try testing.expect(inner_ctx.ran_before_yield);
    try testing.expect(inner_ctx.ran_after_yield);
    try testing.expectEqual(@as(?*Fiber, &outer), outer_ctx.observed_inner_current_before_resume);
    try testing.expectEqual(@as(?*Fiber, &outer), outer_ctx.observed_self_current_between_resumes);
    try testing.expectEqual(State.finished, inner.state);
    try testing.expectEqual(State.finished, outer.state);
}

test "reset recycles a finished fiber's stack for a fresh entry" {
    // Worker.zig relies on `reset` to reuse a `.finished` fiber's stack
    // buffer for a new task rather than allocating a new one. Verify the
    // recycled fiber runs the new entry/arg from a clean `.ready` state
    // and reaches `.finished` again on its own stack.
    const CtxA = struct {
        ran: bool = false,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.ran = true;
            Fiber.yield();
        }
    };
    const CtxB = struct {
        ran: bool = false,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.ran = true;
        }
    };

    var ctx_a: CtxA = .{};
    var fiber = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, CtxA.entry, &ctx_a);
    defer fiber.deinit(testing.allocator);

    // Drive it to completion (one yield, then falls off the end).
    fiber.resume_();
    try testing.expect(ctx_a.ran);
    try testing.expectEqual(State.suspended, fiber.state);
    fiber.resume_();
    try testing.expectEqual(State.finished, fiber.state);

    var ctx_b: CtxB = .{};
    fiber.reset(CtxB.entry, &ctx_b);
    try testing.expectEqual(State.ready, fiber.state);

    fiber.resume_();
    try testing.expect(ctx_b.ran);
    try testing.expectEqual(State.finished, fiber.state);
}

test "releaseStackPages: reused post-madvise fiber runs a deep-recursion task correctly" {
    // Worker recycles fibers through the free list and (beyond the
    // prewarm count) gives their stack pages back to the OS. A re-faulted
    // zero page must be indistinguishable from a fresh stack: run a deep
    // recursion, madvise the stack away, reset, and run another deep
    // recursion that checksums its frames.
    const Ctx = struct {
        result: u64 = 0,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.result = deep(4000, 1);
        }
        // Enough frames to reach megabytes of stack; accumulates through
        // the unwind so a corrupted frame corrupts the checksum.
        fn deep(n: u64, acc: u64) u64 {
            var pad: [256]u8 = undefined; // force real frame depth
            pad[0] = @truncate(n);
            std.mem.doNotOptimizeAway(&pad);
            if (n == 0) return acc;
            return deep(n - 1, acc +% n *% pad[0]);
        }
    };
    var ctx: Ctx = .{};
    var fiber = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx);
    defer fiber.deinit(testing.allocator);

    fiber.resume_();
    try testing.expectEqual(State.finished, fiber.state);
    const first = ctx.result;
    try testing.expect(first != 0);

    // Both advice flavors, interleaved with reuse.
    fiber.releaseStackPages(64 * 1024, true); // MADV_FREE
    ctx.result = 0;
    fiber.reset(Ctx.entry, &ctx);
    fiber.resume_();
    try testing.expectEqual(State.finished, fiber.state);
    try testing.expectEqual(first, ctx.result);

    fiber.releaseStackPages(64 * 1024, false); // MADV_DONTNEED
    ctx.result = 0;
    fiber.reset(Ctx.entry, &ctx);
    fiber.resume_();
    try testing.expectEqual(State.finished, fiber.state);
    try testing.expectEqual(first, ctx.result);
}

test "reset is valid from the .ready state (never-resumed fiber)" {
    const Ctx = struct {
        calls: u32 = 0,
        fn entry(arg: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(arg));
            ctx.calls += 1;
        }
    };
    var ctx: Ctx = .{};
    var fiber = try Fiber.init(testing.allocator, Fiber.min_stack_bytes, Ctx.entry, &ctx);
    defer fiber.deinit(testing.allocator);

    try testing.expectEqual(State.ready, fiber.state);
    fiber.reset(Ctx.entry, &ctx);
    try testing.expectEqual(State.ready, fiber.state);

    fiber.resume_();
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    try testing.expectEqual(State.finished, fiber.state);
}

test "the fiber census follows the build flag on every supported arch" {
    if (!base_options.fiber_census) return error.SkipZigTest;
    if (!timebase.supported) return error.SkipZigTest;
    try testing.expect(census_enabled);
    try testing.expect(censusNow() != 0);
}
