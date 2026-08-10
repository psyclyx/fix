//! Cheap monotonic tick counter for the cycle probes.
//!
//! The cycle probes (`-Dprof-main`, `-Dprof-path`) read the time millions of
//! times in one evaluation. A system call is too expensive at that rate, so
//! each architecture reads its counter register directly.
//!
//! x86_64 reads the time-stamp counter with `rdtsc`. The counter is invariant
//! on modern parts. It does not stop in a low-power state, and its ratio to
//! wall time stays constant in one run.
//!
//! aarch64 reads the generic timer with `cntvct_el0`. Userspace can always
//! read this register. All cores count at the same fixed frequency, which
//! `cntfrq_el0` gives. That frequency is low, from 24 MHz to 100 MHz, so one
//! tick is 10 ns to 41 ns. A short scope therefore measures 0 ticks or 1 tick.
//! Only totals over many calls are meaningful on this architecture.
//!
//! The read does not execute an `isb` first. The instruction barrier costs
//! more time than the precision that it gives back at this tick rate.
//!
//! The unit is a raw tick. Ticks from two different architectures are not
//! comparable. A caller that prints ticks also prints `name()` and `hz()`.

const std = @import("std");
const builtin = @import("builtin");

/// True when this architecture has a counter that `read()` can use.
pub const supported: bool = switch (builtin.cpu.arch) {
    .x86_64, .aarch64 => true,
    else => false,
};

/// Read the counter. Returns 0 when the architecture has no counter.
pub inline fn read() u64 {
    return switch (builtin.cpu.arch) {
        .x86_64 => blk: {
            var low: u32 = undefined;
            var high: u32 = undefined;
            asm volatile ("rdtsc"
                : [low] "={eax}" (low),
                  [high] "={edx}" (high),
                :
                : .{ .memory = true });
            break :blk (@as(u64, high) << 32) | @as(u64, low);
        },
        .aarch64 => asm volatile ("mrs %[ticks], cntvct_el0"
            : [ticks] "=r" (-> u64),
            :
            : .{ .memory = true }),
        else => 0,
    };
}

/// Ticks per second, or 0 when the frequency is not available at low cost.
pub fn hz() u64 {
    return switch (builtin.cpu.arch) {
        // The TSC frequency needs calibration against a second clock. The
        // probes report ratios, so they do not need it.
        .x86_64 => 0,
        .aarch64 => asm volatile ("mrs %[freq], cntfrq_el0"
            : [freq] "=r" (-> u64),
        ),
        else => 0,
    };
}

/// The counter's name, for a report header.
pub fn name() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "rdtsc",
        .aarch64 => "cntvct_el0",
        else => "none",
    };
}

test "supported agrees with the target architecture" {
    const expected = builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64;
    try std.testing.expectEqual(expected, supported);
}

test "the counter runs forward" {
    if (!supported) return error.SkipZigTest;
    const first = read();
    const second = read();
    try std.testing.expect(first != 0);
    try std.testing.expect(second >= first);
}

test "aarch64 knows its counter frequency" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    try std.testing.expect(hz() > 0);
}

test "the counter has a name" {
    if (!supported) return error.SkipZigTest;
    try std.testing.expect(!std.mem.eql(u8, name(), "none"));
}
