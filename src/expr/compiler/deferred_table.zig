//! Lazy per-attr compilation: the side table of deferred attrset value
//! bodies.
//!
//! Large generated attrsets can compile value bodies lazily. Each body is
//! registered here as an `Entry` (AST node + a snapshot of the
//! enclosing lexical scope) and emitted as a `.deferred` thunk
//! (`runtime/thunk.zig`). The body's bytecode is produced only when that
//! attr is first forced, so never-forced entries are never compiled. The
//! resulting `ChunkId` is cached on the entry (`compiled`) and shared
//! across all runtime instantiations.
//!
//! The table mirrors `ChunkRegistry`: `StableSegments` gives lock-free
//! `get` (the force path) and internally-serialized `append` (compile
//! time, possibly concurrent across workers compiling different files).

const std = @import("std");
const ast = @import("syntax").ast;
const types = @import("runtime").types;
const Capture = @import("types.zig").Capture;
const segments = @import("base").segments;
const sync = @import("base").sync;
const diagnostic = @import("syntax").diagnostic;
const Parser = @import("syntax").parser.Parser;
const LanguagePolicy = @import("../policy.zig").LanguagePolicy;
const LetFloatContext = @import("let_float/model.zig").Context;

const InternId = types.InternId;
const NameId = @import("../bytecode.zig").NameId;
const root_name_id = @import("../bytecode.zig").root_name_id;

/// Gate tunables for lazy per-attr compilation (see `compiler/attrs.zig`).
///
/// `min_entries`: coarse pre-filter — only consider deferring in attrsets
/// with at least this many entries (skips the snapshot machinery for
/// small sets entirely).
pub const min_entries: usize = 64;

/// `min_body_bytes`: the real lever. Defer a value body only if its
/// source span is at least this large. Body source-span size is a cheap
/// proxy for compile cost: deferral pays off only when skipped compilation
/// outweighs the scope snapshot, environment, table entry, and arena
/// retention.
pub const min_body_bytes: usize = 100;

// The parser's body-span elision gates mirror these tunables (an elided
// body is only profitable if it would have been deferred anyway); keep
// them in lock-step.
comptime {
    std.debug.assert(Parser.elide_min_body_bytes == min_body_bytes);
    std.debug.assert(Parser.elide_min_prior_clauses == min_entries);
}

/// `max_scope_size`: cap on the enclosing-scope snapshot size (lexical
/// bindings + active `with` scopes). Keeps the env gather cheap and
/// bounds the runtime stack buffer.
pub const max_scope_size: usize = 32;

/// One deferred value body. Structurally immutable after registration
/// except for `compiled`, the publish-once compile cache.
pub const Entry = struct {
    /// The value body's AST node (lives in an arena retained by the
    /// Engine for its lifetime — see `evaluator.zig` arena retention).
    node: *const ast.Node,
    /// Snapshot of the enclosing lexical scope, in declaration order:
    /// each `Capture` says how to fetch one visible binding's value from
    /// the *creating* frame (`.local` slot / `.upvalue` index). The
    /// `.deferred` thunk gathers these into its `env` at creation; the
    /// force-time compile presents them as the body's upvalues 0..k in
    /// this same order (see `compiler/deferred.zig`).
    ///
    /// The trailing `with_count` entries are not lexical bindings but the
    /// *subject values* of the `with` scopes active at the set site,
    /// innermost-first (named `with_capture_name`). The force-time compile
    /// re-establishes them as with-scopes on the synthetic parent so the
    /// body's name resolution (lexical-first, then withs innermost-first)
    /// matches the eager compile exactly.
    ///
    /// Table-owned and SHARED: every entry of one attrset registers the
    /// same snapshot, so it is adopted into the table once (`adoptScope`)
    /// and referenced by all of them (a 19k-entry generated set would
    /// otherwise dupe 19k copies).
    scope: []const Capture,
    /// How many trailing `scope` entries are `with`-subject captures.
    with_count: u16 = 0,
    /// Source text for offset resolution. Retained for the evaluator
    /// lifetime (FileCache for imports; static for corepkgs).
    source: []const u8,
    /// Duped into the table's allocator: the originals are slices into
    /// the import's transient `stable_path`, freed when the import
    /// returns, but the force-time compile needs them later (e.g. relative
    /// path-literal resolution uses `base_path`).
    base_path: ?[]const u8,
    source_path: ?[]const u8,
    source_file_id: ?InternId,
    /// Policy captured with the source so force-time compilation is identical
    /// to eager compilation even after the originating compiler is gone.
    policy: LanguagePolicy = .{},
    /// Compile cache: 0 = not yet compiled, else `ChunkId + 1`. Published
    /// once via CAS on the force path; concurrent racers converge on one
    /// selected ChunkId. A losing registration may already have converged on
    /// that id through registry deduplication, or may remain unreferenced.
    compiled: std.atomic.Value(u32) = .init(0),
    /// Always-on qualified-name node for the deferred body (see `name_tree`).
    name_id: NameId = root_name_id,
};

pub const Table = struct {
    pub const Stats = struct { registered: u32, compiled: u32 };

    const Store = segments.StableSegments(*Entry, .{ .first_segment_size = 64 }, @import("runtime").mem_tag.vma);

    allocator: std.mem.Allocator,
    /// Engine-owned compile policy used by every force-time deferred body.
    let_float: LetFloatContext = .{},
    entries: Store = .empty,
    /// Per-source line-index cache (keyed by source pointer). Force-time
    /// compiles of bodies from the same file share one line index instead
    /// of each rebuilding it over the whole (16MB+) source.
    line_indexes: std.AutoHashMapUnmanaged(usize, *diagnostic.LineIndex) = .{},
    line_index_mu: sync.SpinMutex = .{},
    /// Adopted scope snapshots (see `Entry.scope`), freed at deinit.
    scopes: std.ArrayListUnmanaged([]const Capture) = .empty,
    /// Owned base/source path strings, deduped by content: all entries of
    /// one file share the same two paths, so dupe each once, not per entry.
    paths: std.StringHashMapUnmanaged(void) = .empty,
    shared_mu: sync.SpinMutex = .{},

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *Table) void {
        var id: u32 = 0;
        const total = self.entries.count();
        while (id < total) : (id += 1) {
            self.allocator.destroy(self.entries.get(id).*);
        }
        self.entries.deinit(self.allocator);
        for (self.scopes.items) |caps| {
            for (caps) |cap| self.allocator.free(cap.name);
            self.allocator.free(caps);
        }
        self.scopes.deinit(self.allocator);
        var path_it = self.paths.keyIterator();
        while (path_it.next()) |p| self.allocator.free(p.*);
        self.paths.deinit(self.allocator);
        var it = self.line_indexes.valueIterator();
        while (it.next()) |idx| {
            idx.*.deinit(self.allocator);
            self.allocator.destroy(idx.*);
        }
        self.line_indexes.deinit(self.allocator);
    }

    /// Get (building once, caching) the line index for `source`. Shared by
    /// all force-time compiles of bodies from the same file.
    pub fn lineIndexFor(self: *Table, source: []const u8) !*diagnostic.LineIndex {
        const key = @intFromPtr(source.ptr);
        self.line_index_mu.lock();
        defer self.line_index_mu.unlock();
        if (self.line_indexes.get(key)) |idx| return idx;
        const idx = try self.allocator.create(diagnostic.LineIndex);
        errdefer self.allocator.destroy(idx);
        idx.* = try diagnostic.LineIndex.init(self.allocator, source);
        try self.line_indexes.put(self.allocator, key, idx);
        return idx;
    }

    /// Adopt a scope snapshot: dupe `caps` (and each `Capture`'s `name`
    /// bytes — often borrowed from a compile unit's scratch arena, freed
    /// when that unit finishes) into the table's allocator. The returned
    /// slice is table-owned and lives until `deinit`; the caller shares it
    /// across every `register` of one attrset instead of duping per entry.
    pub fn adoptScope(self: *Table, caps: []const Capture) ![]const Capture {
        const scope_copy = try self.allocator.dupe(Capture, caps);
        errdefer self.allocator.free(scope_copy);
        var named: usize = 0;
        errdefer for (scope_copy[0..named]) |cap| self.allocator.free(cap.name);
        for (scope_copy) |*cap| {
            cap.name = try self.allocator.dupe(u8, cap.name);
            named += 1;
        }
        self.shared_mu.lock();
        defer self.shared_mu.unlock();
        try self.scopes.append(self.allocator, scope_copy);
        return scope_copy;
    }

    /// Content-dedupe an owned copy of a path string (base/source paths
    /// are transient — freed with the import's `stable_path` — but the
    /// force-time compile needs them later). Called once per deferring
    /// set (alongside `adoptScope`), NOT per entry — the lock and hash
    /// stay off the per-registration path.
    pub fn internPath(self: *Table, path: ?[]const u8) !?[]const u8 {
        const p = path orelse return null;
        self.shared_mu.lock();
        defer self.shared_mu.unlock();
        const gop = try self.paths.getOrPut(self.allocator, p);
        if (!gop.found_existing) {
            errdefer _ = self.paths.remove(p);
            gop.key_ptr.* = try self.allocator.dupe(u8, p);
        }
        return gop.key_ptr.*;
    }

    /// Register a deferred body and return its id (the operand the
    /// `thunk_defer` op carries). `entry.scope` must be table-owned
    /// (from `adoptScope`) and the path strings table-owned (from
    /// `internPath`); registration itself is just an entry append.
    pub fn register(self: *Table, entry: Entry) !u32 {
        const stored = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(stored);
        stored.* = entry;
        return self.entries.append(self.allocator, stored);
    }

    /// Register one decoded cache unit as a single ownership transfer. All
    /// entry allocations happen before the store reservation, so failure
    /// publishes nothing; after reservation, filling the slots cannot fail.
    pub fn registerBatch(self: *Table, entries: []const Entry, out_ids: []u32) !void {
        if (entries.len != out_ids.len) return error.InvalidBatch;
        if (entries.len == 0) return;
        const stored = try self.allocator.alloc(*Entry, entries.len);
        defer self.allocator.free(stored);
        var allocated: usize = 0;
        errdefer for (stored[0..allocated]) |ptr| self.allocator.destroy(ptr);
        for (stored) |*slot| {
            slot.* = try self.allocator.create(Entry);
            allocated += 1;
        }
        const Initialize = struct {
            store: *Store,
            entries: []const Entry,
            stored: []*Entry,
            ids: []u32,

            fn run(raw: *anyopaque, first_id: u32, len: u32) anyerror!void {
                const context: *@This() = @ptrCast(@alignCast(raw));
                std.debug.assert(len == context.entries.len);
                for (context.entries, context.stored, context.ids, 0..) |entry, ptr, *id, i| {
                    ptr.* = entry;
                    const entry_id = first_id + @as(u32, @intCast(i));
                    context.store.getMut(entry_id).* = ptr;
                    id.* = entry_id;
                }
            }
        };
        var initialize: Initialize = .{ .store = &self.entries, .entries = entries, .stored = stored, .ids = out_ids };
        _ = try self.entries.appendDenseInitialized(
            self.allocator,
            @intCast(entries.len),
            &initialize,
            Initialize.run,
        );
        allocated = 0;
    }

    pub fn get(self: *const Table, id: u32) *Entry {
        return self.entries.get(id).*;
    }

    /// Diagnostic: how many bodies were registered (deferred) vs actually
    /// compiled (forced). A low compiled/registered ratio is where lazy
    /// compilation pays off.
    pub fn stats(self: *const Table) Stats {
        var compiled: u32 = 0;
        var id: u32 = 0;
        const total = self.entries.count();
        while (id < total) : (id += 1) {
            if (self.entries.get(id).*.compiled.load(.monotonic) != 0) compiled += 1;
        }
        return .{ .registered = total, .compiled = compiled };
    }
};

const test_node: ast.Node = .{ .tag = .identifier, .data = .{ .atom = .{ .offset = 0, .len = 0 } }, .span = null };

test "register stores an entry retrievable by its returned id" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    const id = try table.register(.{
        .node = &test_node,
        .scope = &.{},
        .source = "irrelevant",
        .base_path = null,
        .source_path = null,
        .source_file_id = null,
    });

    const entry = table.get(id);
    try std.testing.expectEqual(&test_node, entry.node);
    try std.testing.expectEqual(@as(usize, 0), entry.scope.len);
}

test "adoptScope dupes capture names so the caller's buffer can be freed" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    var name_buf: [3]u8 = "foo".*;
    const caps = [_]Capture{.{ .name = &name_buf, .name_id = 7, .kind = .local, .index = 0 }};
    const id = try table.register(.{
        .node = &test_node,
        .scope = try table.adoptScope(&caps),
        .source = "irrelevant",
        .base_path = null,
        .source_path = null,
        .source_file_id = null,
    });

    // Mutate the caller's buffer after registering: the table must hold
    // its own copy, not a borrowed slice into `name_buf`.
    @memset(&name_buf, 'x');

    const entry = table.get(id);
    try std.testing.expectEqualStrings("foo", entry.scope[0].name);
}

test "stats reports registered bodies as not-yet-compiled" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    _ = try table.register(.{
        .node = &test_node,
        .scope = &.{},
        .source = "irrelevant",
        .base_path = null,
        .source_path = null,
        .source_file_id = null,
    });
    _ = try table.register(.{
        .node = &test_node,
        .scope = &.{},
        .source = "irrelevant",
        .base_path = null,
        .source_path = null,
        .source_file_id = null,
    });

    const stats = table.stats();
    try std.testing.expectEqual(@as(u32, 2), stats.registered);
    try std.testing.expectEqual(@as(u32, 0), stats.compiled);
}

test "lineIndexFor caches the index for the same source pointer" {
    var table = Table.init(std.testing.allocator);
    defer table.deinit();

    const source = "a\nb\nc";
    const first = try table.lineIndexFor(source);
    const second = try table.lineIndexFor(source);
    try std.testing.expectEqual(first, second);
}
