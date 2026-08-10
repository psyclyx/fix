//! `base` module facade: generic, reusable infrastructure with zero Nix
//! coupling.
//!
//! Sits at the very bottom of the module dependency graph (depends only on
//! `std` and `base_options`) so every higher subsystem can import it without
//! creating a cycle. It provides work-stealing queues, stack-switching fibers,
//! synchronization, segmented storage, RSS attribution, block reuse, and
//! worker identity. Consumers import this module
//! by name (`@import("base")`) and reach submodules through it.

pub const deque = @import("deque.zig");
pub const cache_line = @import("cache_line.zig");
pub const fiber = @import("fiber.zig");
pub const sync = @import("sync.zig");
pub const clock = @import("clock.zig");
pub const owned_strings = @import("owned_strings.zig");
pub const text_ref = @import("text_ref.zig");
pub const segments = @import("segments.zig");
pub const vma = @import("vma.zig");
pub const block_cache = @import("block_cache.zig");
pub const hugetlb = @import("hugetlb.zig");
pub const arena = @import("arena.zig");
pub const worker_id = @import("worker_id.zig");
pub const blocking_pool = @import("blocking_pool.zig");
pub const terminal_text = @import("terminal_text.zig");
pub const terminal_color = @import("terminal_color.zig");
pub const tui = @import("tui.zig");
pub const observ = @import("observ.zig");
pub const sha256 = @import("sha256.zig");
pub const timebase = @import("timebase.zig");

// Common flat re-exports for the most-used types.
pub const Deque = deque.Deque;
pub const GrowableDeque = deque.GrowableDeque;
pub const Isolated = cache_line.Isolated;
pub const Fiber = fiber.Fiber;
pub const BlockingPool = blocking_pool.BlockingPool;
pub const TextRef = text_ref.TextRef;

test {
    _ = deque;
    _ = cache_line;
    _ = fiber;
    _ = sync;
    _ = clock;
    _ = owned_strings;
    _ = text_ref;
    _ = segments;
    _ = vma;
    _ = block_cache;
    _ = hugetlb;
    _ = arena;
    _ = worker_id;
    _ = blocking_pool;
    _ = terminal_text;
    _ = terminal_color;
    _ = tui;
    _ = observ;
    _ = sha256;
    _ = timebase;
}
