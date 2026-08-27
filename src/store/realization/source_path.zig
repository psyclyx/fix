//! Source path realization: compute the `/nix/store` path for a filesystem
//! source (by NAR hash) and, when a daemon store is attached to the
//! `RealizationStore`, add the source content there. This is the single
//! ingestion chokepoint for `builtins.path`, `filterSource`, and path
//! coercion (`src = ./.`).

const std = @import("std");
const drv_paths = @import("../derivation.zig").paths;
const RealizationStore = @import("store.zig").RealizationStore;
const FileCache = @import("../file_cache.zig").FileCache;
const nar = @import("../nar.zig");
const path_ops = @import("runtime").paths;
const sync = @import("base").sync;

pub fn storePathForSource(
    allocator: std.mem.Allocator,
    realization: *RealizationStore,
    files: *FileCache,
    path: []const u8,
) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    if (isStoreRootPath(path, realization.store_dir)) return allocator.dupe(u8, path);

    return storePathForSourceName(allocator, realization, files, path, path_ops.baseName(path));
}

/// `storePathForSource` for a coerced path VALUE: Nix's copyPathToStore
/// fetches every source unconditionally under its full basename, store
/// paths included, so /nix/store/<h>-src becomes /nix/store/<h2>-<h>-src.
/// Store-path STRINGS (an already-coerced source in a derivation context)
/// keep the passthrough above.
pub fn storePathForSourceValue(
    allocator: std.mem.Allocator,
    realization: *RealizationStore,
    files: *FileCache,
    path: []const u8,
) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return storePathForSourceName(allocator, realization, files, path, path_ops.baseName(path));
}

pub fn storePathForSourceName(
    allocator: std.mem.Allocator,
    realization: *RealizationStore,
    files: *FileCache,
    path: []const u8,
    name: []const u8,
) ![]u8 {
    return storePathForFilteredSource(allocator, realization, files, path, name, null, null);
}

/// A source added to (or computed for) the store.
pub const Ingested = struct {
    /// The `/nix/store/...` path (recursive, `fixed:r:sha256`).
    store_path: []u8,
    /// The NAR hash in Nix SRI form (`sha256-<base64>`), for `narHash` attrs.
    nar_hash: []u8,

    pub fn deinit(self: Ingested, allocator: std.mem.Allocator) void {
        allocator.free(self.store_path);
        allocator.free(self.nar_hash);
    }
};

/// Identity of the Nix `filter` predicate for a filtered ingest, so the source
/// memo can reuse a repeated `(path, name, filter)` result. `object_id` is the
/// predicate lambda's heap ObjectId; `token` is the heap GC token — a GC can
/// reuse the id for a different lambda, so the memo entry stores the token and a
/// mismatch is a miss (mirrors `RealizationStore.lookupLazyDerivation`). Built
/// only for heap-object predicates (closures/partial-apps); a bare primop
/// predicate has no such identity and is passed `null` (never memoized).
pub const FilterKey = struct { object_id: u32, token: u64 };

/// Compute the store path + NAR hash for `path` (serialized under `filter`)
/// and, when a daemon is attached, add the content to the store. Serializing to
/// hash is what the hasher already did, so the add costs only the socket write.
///
/// `filter_key` names the predicate's identity so a repeated identical filter is
/// memoized; pass `null` for unfiltered ingests or predicates without a stable
/// heap identity.
pub fn ingest(
    allocator: std.mem.Allocator,
    realization: *RealizationStore,
    files: *FileCache,
    path: []const u8,
    name: []const u8,
    filter: ?nar.Filter,
    filter_key: ?FilterKey,
) !Ingested {
    return ingestReport(allocator, realization, files, path, name, filter, filter_key, null);
}

/// `ingest`, but records the offending path into `unsupported` (when non-null)
/// on `error.UnsupportedPathType`, so path/filterSource builtins can raise a
/// Nix-style `file '<path>' has an unsupported type` diagnostic.
pub fn ingestReport(
    allocator: std.mem.Allocator,
    realization: *RealizationStore,
    files: *FileCache,
    path: []const u8,
    name: []const u8,
    filter: ?nar.Filter,
    filter_key: ?FilterKey,
    unsupported: ?*nar.Unsupported,
) !Ingested {
    const ingested = try recordIngest(allocator, realization, files, path, name, filter, filter_key, unsupported);
    errdefer ingested.deinit(allocator);
    // Outside `recordIngest` so the ingest stripe lock is already released:
    // materializing parks the fiber on the daemon. A memo hit lands here too,
    // where the store's presence cache makes it a cheap re-check.
    try realization.materializeEagerRecipe(ingested.store_path);
    return ingested;
}

fn recordIngest(
    allocator: std.mem.Allocator,
    realization: *RealizationStore,
    files: *FileCache,
    path: []const u8,
    name: []const u8,
    filter: ?nar.Filter,
    filter_key: ?FilterKey,
    unsupported: ?*nar.Unsupported,
) !Ingested {
    // In-eval source memo (Nix's `srcToStore`): an ingest of the same (path,
    // name[, filter]) is fully determined by content, which `FileCache` freezes
    // for the eval — so reuse the first coercion's store path + NAR hash instead
    // of re-serializing + re-hashing the tree. An unfiltered ingest is always
    // memoizable (content-stable key). A *filtered* ingest is memoized only when
    // we have the predicate's identity (`filter_key`), keyed on its ObjectId +
    // guarded by the GC token; a filter without a stable identity is recomputed.
    const filter_id: ?u32 = if (filter == null) null else if (filter_key) |k| k.object_id else null;
    const token: ?u64 = if (filter_key) |k| k.token else null;
    const memoizable = filter == null or filter_id != null;
    if (memoizable) {
        if (try realization.lookupSourceMemo(allocator, path, name, true, filter_id, token)) |hit| {
            return .{ .store_path = hit.store_path, .nar_hash = hit.nar_hash };
        }
    }

    // Single-flight the actual serialize for UNFILTERED ingests so parallel
    // coercers of the same source don't each re-hash the tree. Take the key's
    // stripe lock and re-check the memo under it: the first worker serializes and
    // memoizes; the rest see the entry here and reuse it. Safe to hold a blocking
    // lock across the serialize because an unfiltered NAR walk has no predicate
    // callback (no reentrancy) and no fiber-park point (no scheduler deadlock).
    // Filtered ingests skip this (their serialize calls back into the VM).
    var ingest_lock: ?*sync.BlockingMutex = null;
    if (filter == null) {
        const lock = realization.sourceIngestLock(path, name);
        lock.lock();
        if (try realization.lookupSourceMemo(allocator, path, name, true, null, null)) |hit| {
            lock.unlock();
            return .{ .store_path = hit.store_path, .nar_hash = hit.nar_hash };
        }
        ingest_lock = lock;
    }
    defer if (ingest_lock) |l| l.unlock();

    const payload_allocator = realization.allocator;
    const nar_bytes = try nar.serializeReport(payload_allocator, files, path, filter, unsupported);
    var nar_owned = true;
    defer if (nar_owned) payload_allocator.free(nar_bytes);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(nar_bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const store_path = try drv_paths.sourcePath(allocator, realization.store_dir, name, hex[0..]);
    errdefer allocator.free(store_path);
    const nar_hash = try sriHash(allocator, &digest);
    errdefer allocator.free(nar_hash);
    nar_owned = false; // recordOwnedNarRecipe consumes on success and error.
    try realization.recordOwnedNarRecipe(store_path, nar_bytes);
    // Memoize the result so later coercions of this source skip the serialize +
    // hash above. A memo-insert failure is non-fatal — worst case a future
    // coercion recomputes. `token` is only consulted for filtered entries; pass
    // 0 for the unfiltered case.
    if (memoizable) {
        realization.storeSourceMemo(path, name, true, filter_id, token orelse 0, store_path, nar_hash) catch {};
    }
    return .{ .store_path = store_path, .nar_hash = nar_hash };
}

/// Ingest an already serialized and SHA-256-hashed NAR without repeating
/// either operation. The NAR bytes and digest are borrowed for the duration of
/// the synchronous daemon operation; the returned paths remain caller-owned.
pub fn ingestSerializedNar(
    allocator: std.mem.Allocator,
    realization: *RealizationStore,
    name: []const u8,
    nar_bytes: []const u8,
    digest: *const [std.crypto.hash.sha2.Sha256.digest_length]u8,
) !Ingested {
    const hex = std.fmt.bytesToHex(digest.*, .lower);
    const store_path = try drv_paths.sourcePath(allocator, realization.store_dir, name, hex[0..]);
    errdefer allocator.free(store_path);
    try realization.instantiatePath(store_path, nar_bytes);

    return .{ .store_path = store_path, .nar_hash = try sriHash(allocator, digest) };
}

/// Encode a sha256 digest as a Nix SRI hash: `sha256-<standard base64>`.
fn sriHash(allocator: std.mem.Allocator, digest: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, "sha256-".len + enc.calcSize(digest.len));
    errdefer allocator.free(out);
    @memcpy(out[0.."sha256-".len], "sha256-");
    _ = enc.encode(out["sha256-".len..], digest);
    return out;
}

/// Compute the store path for `path` (NAR-serialized under `filter`) and, when
/// a daemon is attached, add the content to the store.
pub fn storePathForFilteredSource(
    allocator: std.mem.Allocator,
    realization: *RealizationStore,
    files: *FileCache,
    path: []const u8,
    name: []const u8,
    filter: ?nar.Filter,
    filter_key: ?FilterKey,
) ![]u8 {
    return storePathForFilteredSourceReport(allocator, realization, files, path, name, filter, filter_key, null);
}

/// `storePathForFilteredSource`, but records the offending path into
/// `unsupported` (when non-null) on `error.UnsupportedPathType`.
pub fn storePathForFilteredSourceReport(
    allocator: std.mem.Allocator,
    realization: *RealizationStore,
    files: *FileCache,
    path: []const u8,
    name: []const u8,
    filter: ?nar.Filter,
    filter_key: ?FilterKey,
    unsupported: ?*nar.Unsupported,
) ![]u8 {
    const ingested = try ingestReport(allocator, realization, files, path, name, filter, filter_key, unsupported);
    allocator.free(ingested.nar_hash);
    return ingested.store_path;
}

/// A single regular file added to (or computed for) the store via FLAT
/// (`fixed:sha256`) ingestion — the `recursive = false` mode of `builtins.path`.
pub const FlatIngested = struct {
    /// The `/nix/store/...` path (flat, `fixed:sha256`).
    store_path: []u8,
    /// sha256 of the file's raw contents, lowercase hex (for FOD locking).
    hash_hex: [64]u8,

    pub fn deinit(self: FlatIngested, allocator: std.mem.Allocator) void {
        allocator.free(self.store_path);
    }
};

/// Compute the flat store path for a single regular file `path` (hashing its
/// raw contents, not a NAR) and, when a daemon is attached, add it to the
/// store. Mirrors `ingest`, but flat: `fixedOutputPath(.., "sha256", hex)`.
pub fn flatStorePathForFile(
    allocator: std.mem.Allocator,
    realization: *RealizationStore,
    files: *FileCache,
    path: []const u8,
    name: []const u8,
) !FlatIngested {
    var contents = try files.retainFile(path);
    defer contents.release();

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents.bytes(), &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    const store_path = try drv_paths.fixedOutputPath(allocator, realization.store_dir, name, "out", "sha256", hex[0..]);
    errdefer allocator.free(store_path);
    try realization.recordFlatRecipe(store_path, contents, true);
    try realization.materializeEagerRecipe(store_path);

    return .{ .store_path = store_path, .hash_hex = hex };
}

pub fn isStoreRootPath(path: []const u8, store_dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, store_dir)) return false;
    if (path.len <= store_dir.len or path[store_dir.len] != '/') return false;
    return std.mem.indexOfScalar(u8, path[store_dir.len + 1 ..], '/') == null;
}

test "ingestSerializedNar uses the supplied digest without rehashing" {
    const testing = std.testing;
    var realization = RealizationStore.init(testing.allocator);
    defer realization.deinit();

    const digest = [_]u8{0x5a} ** std.crypto.hash.sha2.Sha256.digest_length;
    const ingested = try ingestSerializedNar(testing.allocator, &realization, "source", "borrowed NAR bytes", &digest);
    defer ingested.deinit(testing.allocator);

    const hex = std.fmt.bytesToHex(digest, .lower);
    const expected_path = try drv_paths.sourcePath(testing.allocator, realization.store_dir, "source", &hex);
    defer testing.allocator.free(expected_path);
    try testing.expectEqualStrings(expected_path, ingested.store_path);
}
