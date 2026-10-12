//! Plain non-atomic arena allocator for single-owner contexts.
//!
//!   * `WorkerFiber.scratch` is per-fiber; a fiber runs on one OS thread at a
//!     time and every cross-thread handoff (steal, wake, recycle) is
//!     synchronized by `run_mu`/the ready-queue protocol, which gives the
//!     plain state a happens-before edge.
//!   * Parse/compile arenas (`AstArena`, deferred-compile scratch, evaluator
//!     scratch) are locals of a single logical operation on one fiber.
//!   * The remaining arenas (language parsing and run diagnostics) are
//!     either single-threaded by phase or already guarded by their own mutex.
//!
//! Single-owner-at-a-time usage of THIS type is a requirement, not a hint:
//! concurrent `alloc` from two threads on one arena is a data race. New arenas
//! that genuinely need cross-thread sharing should use `std.heap.ArenaAllocator`.
//!
//! Vendored from `lib/zig/std/heap/arena_allocator.zig` at Zig 0.15.2.
//! The upstream copyright and MIT license are retained in
//! `LICENSES/zig-MIT.txt`.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// This allocator takes an existing allocator, wraps it, and provides an interface where
/// you can allocate and then free it all together. Calls to free an individual item only
/// free the item if it was the most recent allocation, otherwise calls to free do
/// nothing.
pub const ArenaAllocator = struct {
    child_allocator: Allocator,
    state: State,

    /// Inner state of ArenaAllocator. Can be stored rather than the entire ArenaAllocator
    /// as a memory-saving optimization.
    pub const State = struct {
        buffer_list: std.SinglyLinkedList = .{},
        end_index: usize = 0,

        pub fn promote(self: State, child_allocator: Allocator) ArenaAllocator {
            return .{
                .child_allocator = child_allocator,
                .state = self,
            };
        }
    };

    pub fn allocator(self: *ArenaAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    const BufNode = struct {
        data: usize,
        node: std.SinglyLinkedList.Node = .{},
    };
    const BufNode_alignment: Alignment = .of(BufNode);

    pub fn init(child_allocator: Allocator) ArenaAllocator {
        return (State{}).promote(child_allocator);
    }

    pub fn deinit(self: ArenaAllocator) void {
        var it = self.state.buffer_list.first;
        while (it) |node| {
            // this has to occur before the free because the free frees node
            const next_it = node.next;
            const buf_node: *BufNode = @fieldParentPtr("node", node);
            const alloc_buf = @as([*]u8, @ptrCast(buf_node))[0..buf_node.data];
            self.child_allocator.rawFree(alloc_buf, BufNode_alignment, @returnAddress());
            it = next_it;
        }
    }

    pub const ResetMode = union(enum) {
        /// Releases all allocated memory in the arena.
        free_all,
        /// Retains the arena's total capacity in one reusable buffer.
        retain_capacity,
        /// Retains at most the requested capacity in one reusable buffer.
        retain_with_limit: usize,
    };
    /// Returns usable capacity, excluding allocator metadata.
    pub fn queryCapacity(self: ArenaAllocator) usize {
        var size: usize = 0;
        var it = self.state.buffer_list.first;
        while (it) |node| : (it = node.next) {
            // Compute the actually allocated size excluding the
            // linked list node.
            const buf_node: *BufNode = @fieldParentPtr("node", node);
            size += buf_node.data - @sizeOf(BufNode);
        }
        return size;
    }
    /// Resets the arena. Returns false only when retaining capacity requires an
    /// allocation that fails; the arena remains empty and usable.
    pub fn reset(self: *ArenaAllocator, mode: ResetMode) bool {
        // Capacity is computed during reset so the allocation path needs no
        // retained-capacity accounting.
        const requested_capacity = switch (mode) {
            .retain_capacity => self.queryCapacity(),
            .retain_with_limit => |limit| @min(limit, self.queryCapacity()),
            .free_all => 0,
        };
        if (requested_capacity == 0) {
            // just reset when we don't have anything to reallocate
            self.deinit();
            self.state = State{};
            return true;
        }
        const total_size = requested_capacity + @sizeOf(BufNode);
        // Free all nodes except for the last one
        var it = self.state.buffer_list.first;
        const maybe_first_node = while (it) |node| {
            // this has to occur before the free because the free frees node
            const next_it = node.next;
            if (next_it == null)
                break node;
            const buf_node: *BufNode = @fieldParentPtr("node", node);
            const alloc_buf = @as([*]u8, @ptrCast(buf_node))[0..buf_node.data];
            self.child_allocator.rawFree(alloc_buf, BufNode_alignment, @returnAddress());
            it = next_it;
        } else null;
        std.debug.assert(maybe_first_node == null or maybe_first_node.?.next == null);
        // reset the state before we try resizing the buffers, so we definitely have reset the arena to 0.
        self.state.end_index = 0;
        if (maybe_first_node) |first_node| {
            self.state.buffer_list.first = first_node;
            // perfect, no need to invoke the child_allocator
            const first_buf_node: *BufNode = @fieldParentPtr("node", first_node);
            if (first_buf_node.data == total_size)
                return true;
            const first_alloc_buf = @as([*]u8, @ptrCast(first_buf_node))[0..first_buf_node.data];
            if (self.child_allocator.rawResize(first_alloc_buf, BufNode_alignment, total_size, @returnAddress())) {
                // successful resize
                first_buf_node.data = total_size;
            } else {
                // manual realloc
                const new_ptr = self.child_allocator.rawAlloc(total_size, BufNode_alignment, @returnAddress()) orelse {
                    // we failed to preheat the arena properly, signal this to the user.
                    return false;
                };
                self.child_allocator.rawFree(first_alloc_buf, BufNode_alignment, @returnAddress());
                const buf_node: *BufNode = @ptrCast(@alignCast(new_ptr));
                buf_node.* = .{ .data = total_size };
                self.state.buffer_list.first = &buf_node.node;
            }
        }
        return true;
    }

    fn createNode(self: *ArenaAllocator, prev_len: usize, minimum_size: usize) ?*BufNode {
        const actual_min_size = minimum_size + (@sizeOf(BufNode) + 16);
        const big_enough_len = prev_len + actual_min_size;
        const len = big_enough_len + big_enough_len / 2;
        const ptr = self.child_allocator.rawAlloc(len, BufNode_alignment, @returnAddress()) orelse
            return null;
        const buf_node: *BufNode = @ptrCast(@alignCast(ptr));
        buf_node.* = .{ .data = len };
        self.state.buffer_list.prepend(&buf_node.node);
        self.state.end_index = 0;
        return buf_node;
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
        _ = ra;

        const ptr_align = alignment.toByteUnits();
        var cur_node: *BufNode = if (self.state.buffer_list.first) |first_node|
            @fieldParentPtr("node", first_node)
        else
            (self.createNode(0, n + ptr_align) orelse return null);
        while (true) {
            const cur_alloc_buf = @as([*]u8, @ptrCast(cur_node))[0..cur_node.data];
            const cur_buf = cur_alloc_buf[@sizeOf(BufNode)..];
            const addr = @intFromPtr(cur_buf.ptr) + self.state.end_index;
            const adjusted_addr = mem.alignForward(usize, addr, ptr_align);
            const adjusted_index = self.state.end_index + (adjusted_addr - addr);
            const new_end_index = adjusted_index + n;

            if (new_end_index <= cur_buf.len) {
                const result = cur_buf[adjusted_index..new_end_index];
                self.state.end_index = new_end_index;
                return result.ptr;
            }

            const bigger_buf_size = @sizeOf(BufNode) + new_end_index;
            if (self.child_allocator.rawResize(cur_alloc_buf, BufNode_alignment, bigger_buf_size, @returnAddress())) {
                cur_node.data = bigger_buf_size;
            } else {
                // Allocate a new node if that's not possible
                cur_node = self.createNode(cur_buf.len, n + ptr_align) orelse return null;
            }
        }
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = ret_addr;

        const cur_node = self.state.buffer_list.first orelse return false;
        const cur_buf_node: *BufNode = @fieldParentPtr("node", cur_node);
        const cur_buf = @as([*]u8, @ptrCast(cur_buf_node))[@sizeOf(BufNode)..cur_buf_node.data];
        if (@intFromPtr(cur_buf.ptr) + self.state.end_index != @intFromPtr(buf.ptr) + buf.len) {
            // It's not the most recent allocation, so it cannot be expanded,
            // but it's fine if they want to make it smaller.
            return new_len <= buf.len;
        }

        if (buf.len >= new_len) {
            self.state.end_index -= buf.len - new_len;
            return true;
        } else if (cur_buf.len - self.state.end_index >= new_len - buf.len) {
            self.state.end_index += new_len - buf.len;
            return true;
        } else {
            return false;
        }
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;

        const self: *ArenaAllocator = @ptrCast(@alignCast(ctx));

        const cur_node = self.state.buffer_list.first orelse return;
        const cur_buf_node: *BufNode = @fieldParentPtr("node", cur_node);
        const cur_buf = @as([*]u8, @ptrCast(cur_buf_node))[@sizeOf(BufNode)..cur_buf_node.data];

        if (@intFromPtr(cur_buf.ptr) + self.state.end_index == @intFromPtr(buf.ptr) + buf.len) {
            self.state.end_index -= buf.len;
        }
    }
};

test "reset with preheating" {
    var arena_allocator = ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    // provides some variance in the allocated data
    var rng_src = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = rng_src.random();
    var rounds: usize = 25;
    while (rounds > 0) {
        rounds -= 1;
        _ = arena_allocator.reset(.retain_capacity);
        var alloced_bytes: usize = 0;
        const total_size: usize = random.intRangeAtMost(usize, 256, 16384);
        while (alloced_bytes < total_size) {
            const size = random.intRangeAtMost(usize, 16, 256);
            const alignment: Alignment = .@"32";
            const slice = try arena_allocator.allocator().alignedAlloc(u8, alignment, size);
            try std.testing.expect(alignment.check(@intFromPtr(slice.ptr)));
            try std.testing.expectEqual(size, slice.len);
            alloced_bytes += slice.len;
        }
    }
}

test "reset while retaining a buffer" {
    var arena_allocator = ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    const a = arena_allocator.allocator();

    // Create two internal buffers. The second allocation must be too big
    // for the child allocator to serve by growing the first buffer: the
    // testing allocator grows small bucket allocations in place but never
    // moves one across its large-allocation threshold.
    _ = try a.alloc(u8, 1);
    _ = try a.alloc(u8, 1 << 20);

    // Check that we have at least two buffers
    try std.testing.expect(arena_allocator.state.buffer_list.first.?.next != null);

    // This retains the first allocated buffer
    try std.testing.expect(arena_allocator.reset(.{ .retain_with_limit = 1 }));
}
