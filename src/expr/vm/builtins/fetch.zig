//! Network fetch builtins and fetched-source realization.

const std = @import("std");
const clock = @import("base").clock;
const observ = @import("base").observ;
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const ObjectId = types.ObjectId;
const heap_mod = @import("runtime").heap;
const fetchers = @import("fetchers");
const file_cache = fetchers.file_cache;
const FetchService = fetchers.FetchService;
const forge_mod = fetchers.forge;
const derivation = @import("store").derivation;
const nar = fetchers.nar;
const path_ops = @import("runtime").paths;
const source_paths = @import("store").realization.source_path;
const shared = @import("shared.zig");
const strings = @import("strings.zig");
const purity = @import("purity.zig");
const string_context = @import("string_context.zig");
const arguments = @import("arguments.zig");
const vm_force = @import("../force.zig");
const vm_trace = @import("../trace.zig");

const fetch_observation: observ.SpanSpec = .{
    .category = "fetch",
    .name = "fetch",
    .begin_verb = "fetching",
    .finish_verb = "fetched",
};

const contextStringWithPath = string_context.contextStringWithPath;
const pathArg = strings.pathArg;
const sourcePathStringValue = strings.sourcePathStringValue;
const stringArg = strings.stringArg;
const appendStringAttr = arguments.appendStringAttr;
const dupPathAttr = arguments.dupPathAttr;
const optionalStringAttr = arguments.optionalStringAttr;
const requiredStringAttr = arguments.requiredStringAttr;
const optionalBoolAttr = arguments.optionalBoolAttr;

pub const FetchGitSpec = struct {
    url: []u8,
    name: []u8,
    rev: ?[]u8,
    ref: ?[]u8,
    submodules: bool,

    pub fn deinit(self: FetchGitSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        if (self.rev) |rev| allocator.free(rev);
        if (self.ref) |ref| allocator.free(ref);
    }

    pub fn borrowed(self: FetchGitSpec) FetchService.GitSpec {
        return .{
            .url = self.url,
            .name = self.name,
            .rev = self.rev,
            .ref = self.ref,
            .submodules = self.submodules,
        };
    }
};

/// A fetched tree's realized `outPath` and `narHash`. When store writes are
/// enabled (`fix instantiate`/`build`) the tree is NAR-added to the real store
/// and these are the store path + real SRI NAR hash; otherwise (plain `eval`)
/// they are the local download-cache path + synthetic hash (offline-friendly,
/// matching the pre-store behaviour).
pub const FetchedOut = struct {
    out_path: []u8,
    nar_hash: []u8,

    pub fn deinit(self: FetchedOut, allocator: std.mem.Allocator) void {
        allocator.free(self.out_path);
        allocator.free(self.nar_hash);
    }
};

pub fn ingestFetchedTree(self: *VM, cache_path: []const u8, name: []const u8, rev: []const u8, filter: ?nar.Filter) !FetchedOut {
    _ = rev;
    if (self.realization.storeWritesEnabled()) {
        // Fetched trees carry no user-lambda filter identity, so they are never
        // filter-memoized (pass null); a null `filter` is unfiltered-memoized.
        const ingested = try source_paths.ingest(self.allocator, self.realization, self.files, cache_path, name, filter, null);
        return .{ .out_path = ingested.store_path, .nar_hash = ingested.nar_hash };
    }
    // Plain eval: keep the on-disk cache path (readable) and defer the NAR hash
    // (empty sentinel -> `treeNarHashValue` makes it a lazy thunk), so we match
    // Nix's real narHash without eagerly hashing trees that aren't inspected.
    const out_path = try self.allocator.dupe(u8, cache_path);
    errdefer self.allocator.free(out_path);
    const nar_hash = try self.allocator.dupe(u8, "");
    errdefer self.allocator.free(nar_hash);
    return .{
        .out_path = out_path,
        .nar_hash = nar_hash,
    };
}

/// A fetched `outPath` string value. When the tree was materialized to the
/// store it carries string context referencing that store path, so using it as
/// a derivation `src` records it in `inputSrcs` (like Nix). Off-store (plain
/// eval) it is a bare string of the download-cache path.
fn fetchedPathValue(self: *VM, path: []const u8) !Value {
    const id = try self.intern.intern(path);
    return if (self.realization.storeWritesEnabled())
        contextStringWithPath(self, id)
    else
        Value.string(id);
}

/// NAR filter that drops any `.git` entry, so a git checkout ingests as the
/// tree Nix stores (working tree at the rev, minus the repository metadata).
fn gitFilterAccept(_: *anyopaque, path: []const u8, _: file_cache.FileCache.FileKind) anyerror!bool {
    return !std.mem.eql(u8, path_ops.baseName(path), ".git");
}
var git_filter_ctx: u8 = 0;
const git_filter = nar.Filter{ .context = &git_filter_ctx, .accept = gitFilterAccept };

/// NAR filter that drops any `.hg` entry (the Mercurial repository metadata).
fn hgFilterAccept(_: *anyopaque, path: []const u8, _: file_cache.FileCache.FileKind) anyerror!bool {
    return !std.mem.eql(u8, path_ops.baseName(path), ".hg");
}
var hg_filter_ctx: u8 = 0;
const hg_filter = nar.Filter{ .context = &hg_filter_ctx, .accept = hgFilterAccept };

pub fn mercurialResultValue(self: *VM, name: []const u8, result: FetchService.MercurialResult) !Value {
    const out = try ingestFetchedTree(self, result.out_path, name, result.rev, hg_filter);
    defer out.deinit(self.allocator);
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("narHash"), .value = try treeNarHashValue(self, out.out_path, out.nar_hash, ".hg") },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, out.out_path) },
        .{ .name = try self.intern.intern("rev"), .value = Value.string(try self.intern.intern(result.rev)) },
        .{ .name = try self.intern.intern("shortRev"), .value = Value.string(try self.intern.intern(result.short_rev)) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

const FileCache = file_cache.FileCache;

/// Wraps a fetch progress span so the runtime download loop can report bytes
/// (`downloaded`/`total`) without knowing the progress types. Lives on the
/// `offloadFetch` frame, which stays parked for the whole fetch.
const FetchReport = struct {
    span: *observ.Span,
    downloaded: u64 = 0,
    total: u64 = 0,
    reported: bool = false,

    fn report(ctx: *anyopaque, downloaded: u64, total: u64) void {
        const self: *FetchReport = @ptrCast(@alignCast(ctx));
        self.downloaded = downloaded;
        self.total = total;
        self.reported = true;
        self.span.update(&.{
            .{ .name = "downloaded", .value = .{ .unsigned = downloaded }, .unit = .bytes },
            .{ .name = "total", .value = .{ .unsigned = total }, .unit = .bytes },
        });
    }
};

/// Run a blocking `FetchCache` fetch on a dedicated fetch thread (bounded by
/// `http-connections`) while the calling fiber parks — so the compute worker is
/// free to run other fibers instead of blocking on network/subprocess I/O. The
/// fetch's borrowed args stay valid because the fiber stays parked for the whole
/// call. The blocking thread opens the progress span immediately before the
/// `FetchCache` call and closes it immediately after.
pub const FetchOperation = enum { url, tarball, git, mercurial };

pub fn offloadFetch(self: *VM, comptime operation: FetchOperation, spec: anytype) anyerror!switch (operation) {
    .url => FetchService.UrlResult,
    .tarball => FetchService.TarballResult,
    .git => FetchService.GitResult,
    .mercurial => FetchService.MercurialResult,
} {
    const Res = switch (operation) {
        .url => FetchService.UrlResult,
        .tarball => FetchService.TarballResult,
        .git => FetchService.GitResult,
        .mercurial => FetchService.MercurialResult,
    };
    const Cell = struct {
        fetchers: *FetchService,
        files: *FileCache,
        spec: @TypeOf(spec),
        observer: observ.Observer,
        res: Res = undefined,
        err: ?anyerror = null,

        fn run(p: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(p));
            var span = c.observer.begin(&fetch_observation, .{ .subject = .{ .url = c.spec.url } });
            defer span.cancel();
            var report_store: FetchReport = .{ .span = &span };
            const reporter: ?FetchService.Reporter = if (span.active()) blk: {
                break :blk .{ .ctx = &report_store, .report = FetchReport.report };
            } else null;
            c.res = switch (operation) {
                .url => c.fetchers.fetchUrl(c.files, c.spec, reporter),
                .tarball => c.fetchers.fetchTarball(c.files, c.spec, reporter),
                .git => c.fetchers.fetchGit(c.files, c.spec, reporter),
                .mercurial => c.fetchers.fetchMercurial(c.files, c.spec, reporter),
            } catch |e| {
                c.err = e;
                return;
            };
            const metrics = [_]observ.Metric{
                .{ .name = "downloaded", .value = .{ .unsigned = report_store.downloaded }, .unit = .bytes },
                .{ .name = "total", .value = .{ .unsigned = report_store.total }, .unit = .bytes },
            };
            const cached = if (comptime @hasField(Res, "cached")) c.res.cached else false;
            span.finish(.{
                .verb = if (cached) "cached" else null,
                .metrics = if (report_store.reported) &metrics else &.{},
            });
        }
    };
    var cell: Cell = .{ .fetchers = self.fetchers, .files = self.files, .spec = spec, .observer = self.observer };
    if (self.executor) |executor|
        executor.runBlocking(self.fetchers.blockingPool(), Cell.run, &cell)
    else
        Cell.run(&cell);
    if (cell.err) |e| {
        if (comptime @hasField(@TypeOf(spec), "url")) {
            const message = try std.fmt.allocPrint(self.allocator, "fetching '{s}' failed: {s}", .{ spec.url, @errorName(e) });
            defer self.allocator.free(message);
            try vm_trace.setErrorMessage(self, message);
        }
        return e;
    }
    return cell.res;
}

/// Pure eval requires a fetch to be content-locked (a `rev`/`narHash`/`sha256`
/// on the argument attrset); a bare-string URL is never locked. No-op off pure.
fn enforcePureFetch(self: *VM, arg: Value) !void {
    if (!purity.pure(self)) return;
    const forced = try vm_force.forceValue(self, arg);
    try purity.enforceFetchLocked(self, purity.attrsHaveLock(self, forced));
}

pub fn builtinFetchGit(self: *VM, arg: Value) !Value {
    try enforcePureFetch(self, arg);
    const spec = try fetchGitSpec(self, arg);
    defer spec.deinit(self.allocator);

    const result = try offloadFetch(self, .git, spec.borrowed());
    defer result.deinit(self.fetchers.allocator);
    return gitResultValue(self, spec.name, result);
}

pub fn gitResultValue(self: *VM, name: []const u8, result: FetchService.GitResult) !Value {
    const out = try ingestFetchedTree(self, result.out_path, name, result.rev, git_filter);
    defer out.deinit(self.allocator);
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(result.last_modified) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern(result.last_modified_date)) },
        .{ .name = try self.intern.intern("narHash"), .value = try treeNarHashValue(self, out.out_path, out.nar_hash, ".git") },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, out.out_path) },
        .{ .name = try self.intern.intern("rev"), .value = Value.string(try self.intern.intern(result.rev)) },
        .{ .name = try self.intern.intern("revCount"), .value = Value.int(result.rev_count) },
        .{ .name = try self.intern.intern("shortRev"), .value = Value.string(try self.intern.intern(result.short_rev)) },
        .{ .name = try self.intern.intern("submodules"), .value = Value.boolVal(result.submodules) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

/// The `narHash` value for a fetched tree: an eager SRI string when we already
/// have it (store writes, where ingest computed it), or — when `nar_hash` is
/// empty (plain eval) — a thunk that computes the real NAR hash of `path` only
/// if it's accessed, matching Nix (which never hashes a tree eagerly here).
/// `exclude` is a basename dropped from the NAR (".git"/".hg" for VCS checkouts,
/// "" otherwise) so the lazy hash matches what `ingestFetchedTree` serialized.
fn treeNarHashValue(self: *VM, path: []const u8, nar_hash: []const u8, exclude: []const u8) !Value {
    if (nar_hash.len != 0) return Value.string(try self.intern.intern(nar_hash));
    return shared.makeBuiltinThunk(self, .compute_nar_hash, &.{
        Value.string(try self.intern.intern(path)),
        Value.string(try self.intern.intern(exclude)),
    });
}

const ExcludeCtx = struct { name: []const u8 };
fn excludeAccept(context: *anyopaque, path: []const u8, _: file_cache.FileCache.FileKind) anyerror!bool {
    const ctx: *ExcludeCtx = @ptrCast(@alignCast(context));
    return !std.mem.eql(u8, path_ops.baseName(path), ctx.name);
}

/// Compute a fetched tree's NAR hash in Nix SRI form (`sha256-<base64>`),
/// optionally excluding a basename (e.g. ".git"). Backs the lazy `narHash`
/// thunk (see `treeNarHashValue`).
pub fn computeNarHash(self: *VM, path_value: Value, exclude_value: Value) !Value {
    const path = self.intern.get(path_value.asInternId());
    const exclude = self.intern.get(exclude_value.asInternId());
    var ctx = ExcludeCtx{ .name = exclude };
    const filter: ?nar.Filter = if (exclude.len == 0) null else .{ .context = &ctx, .accept = excludeAccept };
    const digest = try nar.hashPathDigestFiltered(self.allocator, self.files, path, filter);
    const enc = std.base64.standard.Encoder;
    var buf: [7 + 44]u8 = undefined;
    @memcpy(buf[0..7], "sha256-");
    const encoded = enc.encode(buf[7..], &digest);
    return Value.string(try self.intern.intern(buf[0 .. 7 + encoded.len]));
}

pub fn pathTreeValue(self: *VM, path: []const u8, nar_hash: []const u8, last_modified: i64) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(last_modified) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern(&clock.formatUtc(last_modified))) },
        .{ .name = try self.intern.intern("narHash"), .value = try treeNarHashValue(self, path, nar_hash, "") },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, path) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

/// A locked git input whose tree is already valid in the store: the same
/// attrs `gitResultValue` reports, taken from the lock pins instead of a
/// fetch.
pub fn gitTreeValue(self: *VM, path: []const u8, nar_hash: []const u8, rev: []const u8, rev_count: i64, last_modified: i64, submodules: bool) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(last_modified) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern(&clock.formatUtc(last_modified))) },
        .{ .name = try self.intern.intern("narHash"), .value = try treeNarHashValue(self, path, nar_hash, ".git") },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, path) },
        .{ .name = try self.intern.intern("rev"), .value = Value.string(try self.intern.intern(rev)) },
        .{ .name = try self.intern.intern("revCount"), .value = Value.int(rev_count) },
        .{ .name = try self.intern.intern("shortRev"), .value = Value.string(try self.intern.intern(rev[0..@min(rev.len, 7)])) },
        .{ .name = try self.intern.intern("submodules"), .value = Value.boolVal(submodules) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

/// A local source tree's `lastModified`: the root's mtime in whole seconds, as
/// Nix's path fetcher reports it (0 when the stat fails).
pub fn sourceLastModified(self: *VM, path: []const u8) i64 {
    const io = self.files.io orelse return 0;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return 0;
    return @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s));
}

pub fn fileTreeValue(self: *VM, path: []const u8, nar_hash: []const u8) !Value {
    const entries = [_]heap_mod.AttrEntry{
        .{ .name = try self.intern.intern("narHash"), .value = Value.string(try self.intern.intern(nar_hash)) },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, path) },
    };
    return Value.attrs(try self.heap.addAttrs(&entries));
}

fn fetchGitSpec(self: *VM, arg: Value) !FetchGitSpec {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isAttrs()) {
        const url = try self.allocator.dupe(u8, try pathArg(self, value));
        errdefer self.allocator.free(url);
        return .{
            .url = url,
            .name = try self.allocator.dupe(u8, "source"),
            .rev = null,
            .ref = null,
            .submodules = false,
        };
    }

    return fetchGitSpecFromAttrs(self, value.asObjectId());
}

pub fn fetchGitSpecFromAttrs(self: *VM, attrs_id: ObjectId) !FetchGitSpec {
    const url = try dupPathAttr(self, attrs_id, "url");
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse try self.allocator.dupe(u8, "source");
    errdefer self.allocator.free(name);
    const rev = try optionalStringAttr(self, attrs_id, "rev");
    errdefer if (rev) |owned| self.allocator.free(owned);
    const ref = try optionalStringAttr(self, attrs_id, "ref");
    errdefer if (ref) |owned| self.allocator.free(owned);
    const submodules = try optionalBoolAttr(self, attrs_id, "submodules") orelse false;

    return .{
        .url = url,
        .name = name,
        .rev = rev,
        .ref = ref,
        .submodules = submodules,
    };
}

pub const FetchUrlSpec = struct {
    url: []u8,
    name: []u8,

    pub fn deinit(self: FetchUrlSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
    }

    pub fn borrowed(self: FetchUrlSpec) FetchService.UrlSpec {
        return .{ .url = self.url, .name = self.name };
    }
};

pub fn builtinFetchurl(self: *VM, arg: Value) !Value {
    try enforcePureFetch(self, arg);
    const spec = try fetchUrlSpec(self, arg);
    defer spec.deinit(self.allocator);
    const expected_hash = try expectedFetchSha256Hex(self, arg);
    defer if (expected_hash) |hash| self.allocator.free(hash);

    // Plain eval with a known hash: the flat fixed-output path is fully
    // determined by (name, sha256), so return it without fetching. The download
    // is deferred (registered as a pending fetch) and runs only if the path's
    // content is later demanded — offline for path-only use, still correct for
    // import-from-derivation. With store writes, first ask the daemon whether
    // the hash-derived path is already valid; only a miss fetches bytes.
    if (expected_hash) |expected| {
        const store_path = try derivation.fixedOutputPath(self.allocator, self.realization.store_dir, spec.name, "out", "sha256", expected);
        defer self.allocator.free(store_path);
        if (!self.realization.storeWritesEnabled()) {
            try self.realization.recordPendingFetch(store_path, spec.url, spec.name, false, expected);
            return contextStringWithPath(self, try self.intern.intern(store_path));
        }
        if (try self.realization.pathIsValid(store_path))
            return contextStringWithPath(self, try self.intern.intern(store_path));
    }

    const result = try offloadFetch(self, .url, spec.borrowed());
    defer result.deinit(self.fetchers.allocator);
    try validateFetchedSha256(self, "file", spec.url, expected_hash, result.hash);
    const path = try flatFetchOutPath(self, result.path, result.hash, spec.name);
    defer self.allocator.free(path);
    // The flat fixed-output store path is fully determined by the fetched
    // content's hash, so return it (with context) even in plain eval — matching
    // Nix, whose `fetchurl` always yields the store path with `{ path = true }`.
    return contextStringWithPath(self, try self.intern.intern(path));
}

fn expectedFetchSha256Hex(self: *VM, arg: Value) !?[]u8 {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isAttrs()) return null;
    const expected = (try optionalStringAttr(self, value.asObjectId(), "sha256")) orelse return null;
    defer self.allocator.free(expected);
    return derivation.hashToBase16(self.allocator, "sha256", expected) catch {
        const message = try std.fmt.allocPrint(self.allocator, "invalid sha256 hash '{s}'", .{expected});
        defer self.allocator.free(message);
        try vm_trace.setErrorMessage(self, message);
        return error.InvalidHash;
    };
}

fn validateFetchedSha256(self: *VM, noun: []const u8, url: []const u8, expected_hex: ?[]const u8, actual_hex: []const u8) !void {
    const expected = expected_hex orelse return;
    if (std.ascii.eqlIgnoreCase(expected, actual_hex)) return;
    const message = try std.fmt.allocPrint(
        self.allocator,
        "hash mismatch in {s} downloaded from '{s}': expected sha256 '{s}', got '{s}'",
        .{ noun, url, expected, actual_hex },
    );
    defer self.allocator.free(message);
    try vm_trace.setErrorMessage(self, message);
    return error.HashMismatch;
}

/// Realize a fetched single file to its flat (`fixed:sha256`) fixed-output
/// store path — like Nix's fetchurl. Under store writes the bytes are added to
/// the real store; in plain eval the store path is still returned, with the
/// fetched content seeded into the file cache so reads of it succeed.
/// Returns the store path (owned by `self.allocator`).
pub fn flatFetchOutPath(self: *VM, cache_path: []const u8, hash_hex: []const u8, name: []const u8) ![]u8 {
    // The flat store path is determined by the content hash regardless of store
    // writes; only the store instantiation is gated on them.
    const store_path = try derivation.fixedOutputPath(self.allocator, self.realization.store_dir, name, "out", "sha256", hash_hex);
    errdefer self.allocator.free(store_path);
    var contents = try self.files.retainFile(cache_path);
    defer contents.release();
    if (!self.realization.storeWritesEnabled()) {
        // Plain eval has no store to materialize the file; seed the cache so
        // `readFile`/`import` on the returned store path stays zero-copy.
        try self.files.provideRegular(store_path, contents);
    }
    try self.realization.recordFlatRecipe(store_path, contents, true);
    return store_path;
}

/// Reject any attr not in `allowed`, matching Nix's argument validation for
/// the simple fetchers.
fn rejectUnknownFetchAttrs(self: *VM, attrs_id: ObjectId, comptime allowed: []const []const u8) !void {
    const entries = try self.heap.materializeAttrs(attrs_id);
    outer: for (entries.names) |entry_name| {
        const name = self.intern.get(entry_name);
        inline for (allowed) |a| {
            if (std.mem.eql(u8, name, a)) continue :outer;
        }
        const msg = try std.fmt.allocPrint(self.allocator, "unexpected argument '{s}'", .{name});
        defer self.allocator.free(msg);
        try vm_trace.setErrorMessage(self, msg);
        return error.UnexpectedArgument;
    }
}

fn fetchUrlSpec(self: *VM, arg: Value) !FetchUrlSpec {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isAttrs()) {
        // fetchurl/fetchTarball take a string URL (or an attrset); a path is a
        // type error.
        const url = try self.allocator.dupe(u8, try stringArg(self, value));
        errdefer self.allocator.free(url);
        return .{
            .url = url,
            .name = try defaultFetchName(self, url),
        };
    }

    // Direct fetchurl/fetchTarball accept only url / sha256 / name; anything
    // else (e.g. `hash`) errors. (fetchTree's file/tarball reuse the spec below
    // but carry an extra `type` attr, so they don't go through this check.)
    try rejectUnknownFetchAttrs(self, value.asObjectId(), &.{ "url", "sha256", "name" });
    return fetchUrlSpecFromAttrs(self, value.asObjectId(), null);
}

pub fn fetchUrlSpecFromAttrs(self: *VM, attrs_id: ObjectId, default_name: ?[]const u8) !FetchUrlSpec {
    const url = try dupPathAttr(self, attrs_id, "url");
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse if (default_name) |name|
        try self.allocator.dupe(u8, name)
    else
        try defaultFetchName(self, url);
    return .{ .url = url, .name = name };
}

pub fn builtinFetchTarball(self: *VM, arg: Value) !Value {
    try enforcePureFetch(self, arg);
    const tree_name = try tarballTreeName(self, arg);
    defer self.allocator.free(tree_name);
    const spec = try fetchUrlSpec(self, arg);
    defer spec.deinit(self.allocator);
    const expected_hash = try expectedFetchSha256Hex(self, arg);
    defer if (expected_hash) |hash| self.allocator.free(hash);

    // Plain eval with a known hash: the recursive fixed-output path is fully
    // determined by (name, sha256), so return it without fetching (deferred like
    // fetchurl above). Content demand (readFile into the tree, import) triggers
    // the fetch+unpack lazily. With store writes, the supplied hash determines
    // the exact store path, so a valid daemon path skips fetch and NAR hashing.
    if (expected_hash) |expected| {
        const store_path = try derivation.sourcePath(self.allocator, self.realization.store_dir, tree_name, expected);
        defer self.allocator.free(store_path);
        if (!self.realization.storeWritesEnabled()) {
            try self.realization.recordPendingFetch(store_path, spec.url, tree_name, true, expected);
            return contextStringWithPath(self, try self.intern.intern(store_path));
        }
        if (try self.realization.pathIsValid(store_path))
            return contextStringWithPath(self, try self.intern.intern(store_path));
    }

    const result = try offloadFetch(self, .tarball, FetchService.TarballSpec{
        .url = spec.url,
        .name = spec.name,
        .serialize_nar = expected_hash != null,
    });
    defer result.deinit(self.fetchers.allocator);

    if (expected_hash) |expected| {
        const payload = result.nar_payload orelse unreachable;
        const actual_hash = std.fmt.bytesToHex(payload.digest, .lower);
        try validateFetchedSha256(self, "tarball", spec.url, expected, &actual_hash);
        if (self.realization.storeWritesEnabled()) {
            const ingested = try source_paths.ingestSerializedNar(
                self.allocator,
                self.realization,
                tree_name,
                payload.bytes,
                &payload.digest,
            );
            defer ingested.deinit(self.allocator);
            return contextStringWithPath(self, try self.intern.intern(ingested.store_path));
        }
        // Plain eval: the value text is the readable download-cache path, but
        // its context references the real recursive fixed-output store path, so
        // `builtins.getContext` matches Nix without a store to materialize it.
        const nar_hex = std.fmt.bytesToHex(payload.digest, .lower);
        const store_path = try derivation.sourcePath(self.allocator, self.realization.store_dir, tree_name, &nar_hex);
        defer self.allocator.free(store_path);
        return string_context.contextStringTextWithPath(self, try self.intern.intern(result.path), try self.intern.intern(store_path));
    }

    // The unpacked tree is named "source" by default (Nix), independent of the
    // archive's URL basename which named the download (`tree_name`, above).
    const out = try ingestFetchedTree(self, result.path, tree_name, "", null);
    defer out.deinit(self.allocator);
    return fetchedPathValue(self, out.out_path);
}

/// Materialize a deferred `fetchurl`/`fetchTarball` when its content is demanded
/// (readFile/import). `demanded_path` is the store path being read, or a
/// `store_path/sub` inside a fetched tree. Runs the download now, validates it
/// against the recorded hash, and seeds the file cache so the read succeeds.
/// Returns true iff a pending fetch was found and materialized. Called from the
/// path-demand seam so path-only uses never reach here (and never fetch).
pub fn materializePendingFetch(self: *VM, demanded_path: []const u8) !bool {
    const store_root = storeRootOf(demanded_path, self.realization.store_dir) orelse return false;
    // `peekPendingFetch` clones with the store's allocator; free with the same.
    var pending = (try self.realization.peekPendingFetch(store_root)) orelse return false;
    defer pending.deinit(self.realization.allocator);

    if (pending.recursive) {
        const result = try offloadFetch(self, .tarball, FetchService.TarballSpec{
            .url = pending.url,
            .name = pending.name,
            .serialize_nar = true,
        });
        defer result.deinit(self.fetchers.allocator);
        const payload = result.nar_payload orelse unreachable;
        const actual_hash = std.fmt.bytesToHex(payload.digest, .lower);
        try validateFetchedSha256(self, "tarball", pending.url, pending.hash_hex, &actual_hash);
        // Seed the specific file demanded from the unpacked tree; the entry
        // stays registered so sibling reads materialize too (the fetch cache
        // memoizes the download + unpack, so repeats are cheap).
        const rel_raw = demanded_path[store_root.len..];
        const rel = if (rel_raw.len > 0 and rel_raw[0] == '/') rel_raw[1..] else rel_raw;
        const src = try std.fs.path.join(self.allocator, &.{ result.path, rel });
        defer self.allocator.free(src);
        var contents = try self.files.retainFile(src);
        defer contents.release();
        try self.files.provideRegular(demanded_path, contents);
        return true;
    }

    const result = try offloadFetch(self, .url, FetchService.UrlSpec{
        .url = pending.url,
        .name = pending.name,
    });
    defer result.deinit(self.fetchers.allocator);
    try validateFetchedSha256(self, "file", pending.url, pending.hash_hex, result.hash);
    var contents = try self.files.retainFile(result.path);
    defer contents.release();
    try self.files.provideRegular(store_root, contents);
    self.realization.removePendingFetch(store_root);
    return true;
}

/// The `/nix/store/<name>` root of a store path (stripping any `/sub…`), or null
/// if `path` isn't under the store directory.
fn storeRootOf(path: []const u8, store_dir: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, store_dir)) return null;
    if (path.len <= store_dir.len or path[store_dir.len] != '/') return null;
    const after = store_dir.len + 1;
    const rel_end = std.mem.indexOfScalarPos(u8, path, after, '/') orelse return path;
    return path[0..rel_end];
}

/// The store name for a `fetchTarball` unpacked tree: an explicit `name` attr,
/// else "source" (matching Nix — not the archive's URL basename).
fn tarballTreeName(self: *VM, arg: Value) ![]u8 {
    const value = try vm_force.forceValue(self, arg);
    if (value.isAttrs()) {
        if (try optionalStringAttr(self, value.asObjectId(), "name")) |name| return name;
    }
    return self.allocator.dupe(u8, "source");
}

pub const FetchMercurialSpec = struct {
    url: []u8,
    name: []u8,
    rev: ?[]u8,

    pub fn deinit(self: FetchMercurialSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.name);
        if (self.rev) |rev| allocator.free(rev);
    }

    pub fn borrowed(self: FetchMercurialSpec) FetchService.MercurialSpec {
        return .{ .url = self.url, .name = self.name, .rev = self.rev };
    }
};

pub fn builtinFetchMercurial(self: *VM, arg: Value) !Value {
    try enforcePureFetch(self, arg);
    const spec = try fetchMercurialSpec(self, arg);
    defer spec.deinit(self.allocator);

    const result = try offloadFetch(self, .mercurial, spec.borrowed());
    defer result.deinit(self.fetchers.allocator);
    return mercurialResultValue(self, spec.name, result);
}

fn fetchMercurialSpec(self: *VM, arg: Value) !FetchMercurialSpec {
    const value = try vm_force.forceValue(self, arg);
    if (!value.isAttrs()) {
        const url = try self.allocator.dupe(u8, try pathArg(self, value));
        errdefer self.allocator.free(url);
        return .{
            .url = url,
            .name = try self.allocator.dupe(u8, "source"),
            .rev = null,
        };
    }

    return fetchMercurialSpecFromAttrs(self, value.asObjectId());
}

pub fn fetchMercurialSpecFromAttrs(self: *VM, attrs_id: ObjectId) !FetchMercurialSpec {
    const url = try dupPathAttr(self, attrs_id, "url");
    errdefer self.allocator.free(url);
    const name = try optionalStringAttr(self, attrs_id, "name") orelse try self.allocator.dupe(u8, "source");
    errdefer self.allocator.free(name);
    const rev = try optionalStringAttr(self, attrs_id, "rev");
    errdefer if (rev) |owned| self.allocator.free(owned);

    return .{ .url = url, .name = name, .rev = rev };
}

pub const ForgeTreeSpec = forge_mod.Plan;

/// Build the codeload archive URL for github/gitlab/sourcehut, honoring a
/// `host` override (self-hosted forges) and pinning `rev`/`ref` (else HEAD).
pub fn forgeTreeSpec(self: *VM, attrs_id: ObjectId, forge: []const u8) !ForgeTreeSpec {
    const owner = try requiredStringAttr(self, attrs_id, "owner");
    defer self.allocator.free(owner);
    const repo = try requiredStringAttr(self, attrs_id, "repo");
    defer self.allocator.free(repo);
    const rev = try optionalStringAttr(self, attrs_id, "rev");
    defer if (rev) |owned| self.allocator.free(owned);
    const ref = try optionalStringAttr(self, attrs_id, "ref");
    defer if (ref) |owned| self.allocator.free(owned);
    const host = try optionalStringAttr(self, attrs_id, "host");
    defer if (host) |owned| self.allocator.free(owned);
    const name = try optionalStringAttr(self, attrs_id, "name");
    defer if (name) |owned| self.allocator.free(owned);
    const kind: forge_mod.Forge = if (std.mem.eql(u8, forge, "github"))
        .github
    else if (std.mem.eql(u8, forge, "gitlab"))
        .gitlab
    else
        .sourcehut;

    return forge_mod.plan(self.allocator, kind, .{
        .owner = owner,
        .repo = repo,
        .rev = rev,
        .ref = ref,
        .host = host,
        .name = name,
    }) catch |err| switch (err) {
        error.RefAndRev => {
            try vm_trace.setErrorMessage(self, "fetchTree: 'ref' and 'rev' cannot both be specified for a forge source");
            return error.UnexpectedArgument;
        },
        else => return err,
    };
}

/// `locked_last_modified` is the pin carried on the ref attrs (a flake.lock
/// `locked` field, or a caller-supplied `lastModified`): the fallback when the
/// fetch was satisfied without live forge metadata (rev-pinned, cached).
pub fn githubTreeValue(self: *VM, path: []const u8, nar_hash: []const u8, rev: ?[]const u8, metadata: ?FetchService.ForgeMetadata, locked_last_modified: i64) !Value {
    const last_modified = if (metadata) |item| item.last_modified else locked_last_modified;
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    try entries.appendSlice(self.allocator, &.{
        .{ .name = try self.intern.intern("lastModified"), .value = Value.int(last_modified) },
        .{ .name = try self.intern.intern("lastModifiedDate"), .value = Value.string(try self.intern.intern(&clock.formatUtc(last_modified))) },
        .{ .name = try self.intern.intern("narHash"), .value = try treeNarHashValue(self, path, nar_hash, "") },
        .{ .name = try self.intern.intern("outPath"), .value = try fetchedPathValue(self, path) },
    });
    if (if (metadata) |item| item.rev else rev) |value| {
        try appendStringAttr(self, &entries, "rev", value);
        try appendStringAttr(self, &entries, "shortRev", value[0..@min(value.len, 7)]);
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

fn defaultFetchName(self: *VM, url: []const u8) ![]u8 {
    const basename = path_ops.baseName(url);
    if (basename.len != 0) return self.allocator.dupe(u8, basename);
    return self.allocator.dupe(u8, "source");
}
