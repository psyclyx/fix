//! Lazily allocated caches owned by an evaluator OS thread.
//!
//! TLS holds one lazy pointer; the cache bundle is allocated only for threads
//! that execute evaluator code. The bundle comes from the caller's allocator,
//! which is the process allocator `main` gives the Engine, so these caches sit
//! in the same accounted memory as the rest of the evaluator.

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const Chunk = @import("../bytecode.zig").chunk.Chunk;

pub const memo_size: usize = 1 << 14;
pub const attr_cache_size: usize = 8192;
pub const call_ic_size: usize = 256;

pub const MemoSlot = struct {
    token: u64,
    chunk: u32,
    count: u8,
    up0: u64,
    up1: u64,
    value: Value,
};

pub const AttrCacheSlot = struct {
    heap_token: u64,
    obj_id: types.ObjectId,
    name_id: types.InternId,
    value: Value,
};

pub const CallICSlot = struct {
    heap_token: u64,
    caller_chunk_id: types.ChunkId,
    caller_ip: u32,
    callee_chunk_id: types.ChunkId,
    callee_ch_ptr: ?*const Chunk,
};

pub const Caches = struct {
    thunk_memo: [memo_size]MemoSlot,
    attr_cache: [attr_cache_size]AttrCacheSlot,
    call_ic: [call_ic_size]CallICSlot,
};

threadlocal var local: ?*Caches = null;
/// The allocator that made `local`. Teardown returns the bundle to the
/// allocator that supplied it, not to whichever one reaches `unregister`.
threadlocal var local_owner: std.mem.Allocator = undefined;

const max_workers = 256;
var registry: [max_workers]?*Caches = @splat(null);

/// Return this OS thread's cache bundle, allocating it from `gpa` on first VM
/// use. The bundle is near one megabyte and lives for the life of the thread.
/// Zero is the empty sentinel for every cache's heap token, so byte-zeroing is
/// sufficient. Individual tagged values need not be initialized.
/// Resolve the cache pointer on the OS thread active at this call. Keeping
/// this out of migratable fiber frames prevents LLVM from retaining the old
/// thread's TLS base across a yield.
pub noinline fn get(gpa: std.mem.Allocator) *Caches {
    if (local) |caches| return caches;
    const caches = gpa.create(Caches) catch @panic("VM thread cache allocation failed");
    @memset(std.mem.asBytes(caches), 0);
    local = caches;
    local_owner = gpa;
    return caches;
}

/// Publish this worker's cache roots for the stop-the-world collector.
pub fn register(gpa: std.mem.Allocator, worker_id: u8) void {
    registry[worker_id] = get(gpa);
}

/// Remove the collector-visible pointer and release this OS thread's bundle.
/// Idempotent so worker teardown can be structural even when its run loop
/// already unregistered on exit.
pub fn unregister(worker_id: u8) void {
    registry[worker_id] = null;
    if (local) |caches| {
        local_owner.destroy(caches);
        local = null;
    }
}

pub fn registered() []const ?*Caches {
    return &registry;
}
