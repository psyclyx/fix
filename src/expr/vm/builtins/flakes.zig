//! Structured tree fetches and flake graph evaluation.

const std = @import("std");
const VM = @import("../context.zig").VM;
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;
const FetchService = @import("fetchers").FetchService;
const derivation = @import("store").derivation;
const path_ops = @import("runtime").paths;
const flake_ref = @import("flake_ref.zig");
const flake_registry = @import("flake_registry.zig");
const shared = @import("shared.zig");
const purity = @import("purity.zig");
const attrsets = @import("attrsets.zig");
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");
const fetch = @import("fetch.zig");
const arguments = @import("arguments.zig");

const attrEntryNameIndex = attrsets.attrEntryNameIndex;
const stringArg = strings.stringArg;
const dupPathAttr = arguments.dupPathAttr;
const optionalStringAttr = arguments.optionalStringAttr;
const requiredStringAttr = arguments.requiredStringAttr;
const optionalBoolAttr = arguments.optionalBoolAttr;
const optionalIntAttr = arguments.optionalIntAttr;

const ingestFetchedTree = fetch.ingestFetchedTree;
const pathTreeValue = fetch.pathTreeValue;
const fileTreeValue = fetch.fileTreeValue;
const fetchUrlSpecFromAttrs = fetch.fetchUrlSpecFromAttrs;
const offloadFetch = fetch.offloadFetch;
const flatFetchOutPath = fetch.flatFetchOutPath;
const fetchGitSpecFromAttrs = fetch.fetchGitSpecFromAttrs;
const gitResultValue = fetch.gitResultValue;
const forgeTreeSpec = fetch.forgeTreeSpec;
const githubTreeValue = fetch.githubTreeValue;
const gitTreeValue = fetch.gitTreeValue;
const fetchMercurialSpecFromAttrs = fetch.fetchMercurialSpecFromAttrs;
const mercurialResultValue = fetch.mercurialResultValue;
pub const builtinParseFlakeRef = flake_ref.parse;
pub const builtinFlakeRefToString = flake_ref.render;

/// Dispatch entry for a direct `builtins.fetchTree` call. Gated on the
/// `fetch-tree` experimental feature (Nix parity). `getFlake` bypasses this by
/// calling `builtinFetchTree` directly, matching Nix where flake fetching does
/// not additionally require the user to enable `fetch-tree`.
pub fn builtinFetchTreeEntry(self: *VM, arg: Value) !Value {
    if (!self.policy.fetch_tree_enabled) {
        // A hard eval error, like Nix: not catchable by `builtins.tryEval`
        // (which only intercepts NixThrow/NixAbort/AssertionFailed/FileNotFound).
        try vm_trace.setErrorMessage(self, "builtins.fetchTree is disabled; pass --extra-experimental-features fetch-tree to enable it");
        return error.MissingExperimentalFeature;
    }
    // Pure eval requires user-facing fetches to be content-locked. (getFlake's
    // own input fetches go through `builtinFetchTree` directly, bypassing this;
    // they are pinned by the lock's narHash instead.)
    if (purity.pure(self)) {
        const forced = try vm_force.forceValue(self, arg);
        // Parse only explicit-scheme strings (`github:…`, `git+…`); a bare
        // indirect id (`nixpkgs`) is inherently unlocked, so don't hit the
        // registry just to reject it.
        const ref_attrs: Value = if (forced.isString() and std.mem.indexOfScalar(u8, self.intern.get(forced.asInternId()), ':') != null)
            try builtinParseFlakeRef(self, forced)
        else
            forced;
        try purity.enforceFetchLocked(self, purity.attrsHaveLock(self, ref_attrs));
    }
    return fetchTreeImpl(self, arg, true);
}

/// A path that is already a valid store-path root is used verbatim, as
/// Nix's path fetcher does.
fn adoptStorePath(self: *VM, path: []const u8, locked_nar_hash: ?[]const u8, last_modified: i64) !?Value {
    const store_dir = self.realization.store_dir;
    if (!std.mem.startsWith(u8, path, store_dir)) return null;
    if (path.len <= store_dir.len + 1 or path[store_dir.len] != '/') return null;
    const rest = path[store_dir.len + 1 ..];
    if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, '/') != null) return null;
    if (self.realization.storeWritesEnabled()) {
        // A store-shaped name the daemon doesn't know is just a directory.
        if (!try self.realization.pathIsValid(path)) return null;
    }
    return try pathTreeValue(self, path, locked_nar_hash orelse "", last_modified);
}

/// An indirect flake reference (`nixpkgs`, `flake:nixpkgs/branch`)
/// resolved through the flake registries, as Nix does before fetching one:
/// the registry's target, with the reference's own `ref` or `rev` (a forge
/// takes one or the other) and `dir` applied. Any other reference is
/// returned as it is.
pub fn resolveIndirect(self: *VM, ref_attrs: Value) !Value {
    const id_attrs = ref_attrs.asObjectId();
    const type_value = try requiredStringAttr(self, id_attrs, "type");
    defer self.allocator.free(type_value);
    if (!std.mem.eql(u8, type_value, "indirect")) return ref_attrs;

    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, ref_attrs);
    const id = try requiredStringAttr(self, id_attrs, "id");
    defer self.allocator.free(id);
    const target = (try flake_registry.resolve(self, id)) orelse {
        const message = try std.fmt.allocPrint(self.allocator, "cannot find flake 'flake:{s}' in the flake registries", .{id});
        defer self.allocator.free(message);
        try vm_trace.setErrorMessage(self, message);
        return error.InvalidFlakeRef;
    };
    defer self.allocator.free(target);
    const resolved = try builtinParseFlakeRef(self, Value.string(try self.intern.intern(target)));
    vm_force.rootKeep(self, resolved);

    const overrides = [_][]const u8{ "ref", "rev", "dir" };
    var values: [overrides.len]?Value = .{ null, null, null };
    var any = false;
    for (overrides, &values) |name, *slot| {
        slot.* = try self.heap.getAttrValueOpt(id_attrs, try self.intern.intern(name));
        if (slot.* != null) any = true;
    }
    if (!any) return resolved;
    const resolved_type = try requiredStringAttr(self, resolved.asObjectId(), "type");
    defer self.allocator.free(resolved_type);
    const forge = std.mem.eql(u8, resolved_type, "github") or std.mem.eql(u8, resolved_type, "gitlab") or std.mem.eql(u8, resolved_type, "sourcehut");

    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    const view = try self.heap.materializeAttrs(resolved.asObjectId());
    for (view.names, view.values) |name_id, value| {
        const name = self.intern.get(name_id);
        const overridden = for (overrides, values) |override, v| {
            if (v != null and std.mem.eql(u8, name, override)) break true;
        } else false;
        // A forge pins either a branch/tag or a commit.
        const superseded = forge and ((std.mem.eql(u8, name, "ref") and values[1] != null) or
            (std.mem.eql(u8, name, "rev") and values[0] != null));
        if (!overridden and !superseded) try entries.append(self.allocator, .{ .name = name_id, .value = value });
    }
    for (overrides, values) |name, v| {
        if (v) |value| try entries.append(self.allocator, .{ .name = try self.intern.intern(name), .value = value });
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

pub fn builtinFetchTree(self: *VM, arg: Value) !Value {
    return fetchTreeImpl(self, arg, false);
}

/// `fetch_tree_defaults`: the `fetchTree` builtin defaults git inputs to
/// `shallow = true` (Nix injects the attr in its fetchTree primop); flake
/// inputs and `fetchGit` default to full history.
fn fetchTreeImpl(self: *VM, arg: Value, fetch_tree_defaults: bool) !Value {
    const attrs = try vm_force.forceValue(self, arg);
    if (attrs.isPath()) {
        const path = self.intern.get(attrs.asInternId());
        if (try adoptStorePath(self, path, null, fetch.sourceLastModified(self, path))) |adopted| return adopted;
        const out = try ingestFetchedTree(self, path, "source", .none);
        defer out.deinit(self.allocator);
        return pathTreeValue(self, out.out_path, out.nar_hash, fetch.sourceLastModified(self, path));
    }
    if (attrs.isString()) {
        // Nix's `Input::fromURL`: only an attrset argument gets `fetchTree`'s
        // `shallow = true` default, so a git URL has its `revCount`.
        const parsed = try builtinParseFlakeRef(self, attrs);
        return fetchTreeImpl(self, parsed, false);
    }
    if (!attrs.isAttrs()) return error.TypeError;

    // GC: `attrs` is held (via `attrs_id`) across the force-walking spec
    // helpers below. On the recursive path (`builtinParseFlakeRef` result) it
    // is a freshly built attrset that isn't the auto-rooted builtin argument.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, attrs);
    const attrs_id = attrs.asObjectId();
    const type_value = try requiredStringAttr(self, attrs_id, "type");
    defer self.allocator.free(type_value);

    if (std.mem.eql(u8, type_value, "indirect")) {
        return fetchTreeImpl(self, try resolveIndirect(self, attrs), fetch_tree_defaults);
    }

    if (std.mem.eql(u8, type_value, "path")) {
        const path = try dupPathAttr(self, attrs_id, "path");
        defer self.allocator.free(path);
        // A locked pin wins (deterministic across hosts); a bare local path
        // reports the tree's own mtime, as Nix's path fetcher does.
        const last_modified = (try optionalIntAttr(self, attrs_id, "lastModified")) orelse fetch.sourceLastModified(self, path);
        const locked_hash = try optionalStringAttr(self, attrs_id, "narHash");
        defer if (locked_hash) |h| self.allocator.free(h);
        if (try adoptStorePath(self, path, locked_hash, last_modified)) |adopted| return adopted;
        const out = try ingestFetchedTree(self, path, "source", .none);
        defer out.deinit(self.allocator);
        return pathTreeValue(self, out.out_path, out.nar_hash, last_modified);
    }

    if (std.mem.eql(u8, type_value, "file")) {
        const spec = try fetchUrlSpecFromAttrs(self, attrs_id, null);
        defer spec.deinit(self.allocator);
        const result = try offloadFetch(self, .url, spec.borrowed());
        defer result.deinit(self.fetchers.allocator);
        const path = try flatFetchOutPath(self, result.path, result.hash, spec.name);
        defer self.allocator.free(path);
        return fileTreeValue(self, path, result.hash);
    }

    if (std.mem.eql(u8, type_value, "tarball")) {
        const spec = try fetchUrlSpecFromAttrs(self, attrs_id, "source");
        defer spec.deinit(self.allocator);
        const result = try offloadFetch(self, .tarball, FetchService.TarballSpec{ .url = spec.url, .name = spec.name });
        defer result.deinit(self.fetchers.allocator);
        const out = try ingestFetchedTree(self, result.path, spec.name, .none);
        defer out.deinit(self.allocator);
        return pathTreeValue(self, out.out_path, out.nar_hash, (try optionalIntAttr(self, attrs_id, "lastModified")) orelse result.last_modified);
    }

    if (std.mem.eql(u8, type_value, "git")) {
        const spec = try fetchGitSpecFromAttrs(self, attrs_id, fetch_tree_defaults);
        defer spec.deinit(self.allocator);
        const result = try offloadFetch(self, .git, spec.borrowed());
        defer result.deinit(self.fetchers.allocator);
        return gitResultValue(self, spec.name, spec.url, result, .{ .omit_rev_count = spec.shallow });
    }

    if (std.mem.eql(u8, type_value, "github") or std.mem.eql(u8, type_value, "gitlab") or std.mem.eql(u8, type_value, "sourcehut")) {
        const spec = try forgeTreeSpec(self, attrs_id, type_value);
        defer spec.deinit(self.allocator);
        // Tag the fetch with the forge so `access-tokens` are applied with the
        // right per-forge auth header (as in Nix); other fetches get no token.
        const forge: FetchService.Forge = if (std.mem.eql(u8, type_value, "github"))
            .github
        else if (std.mem.eql(u8, type_value, "gitlab"))
            .gitlab
        else
            .sourcehut;
        const result = try offloadFetch(self, .tarball, FetchService.TarballSpec{
            .url = spec.url,
            .name = spec.name,
            .forge = forge,
            .metadata_url = spec.metadata_url,
            .metadata_ref = spec.metadata_ref,
            .metadata_head_url = spec.metadata_head_url,
            .resolved_rev = spec.rev,
            .resolved_url_template = spec.resolved_url_template,
        });
        defer result.deinit(self.fetchers.allocator);
        const out = try ingestFetchedTree(self, result.path, spec.name, .none);
        defer out.deinit(self.allocator);
        return githubTreeValue(self, out.out_path, out.nar_hash, spec.rev, result.forge_metadata, (try optionalIntAttr(self, attrs_id, "lastModified")) orelse 0);
    }

    // Nix calls the scheme `hg`; `mercurial` is accepted too.
    if (std.mem.eql(u8, type_value, "hg") or std.mem.eql(u8, type_value, "mercurial")) {
        const spec = try fetchMercurialSpecFromAttrs(self, attrs_id);
        defer spec.deinit(self.allocator);
        const result = try offloadFetch(self, .mercurial, spec.borrowed());
        defer result.deinit(self.fetchers.allocator);
        return mercurialResultValue(self, spec.name, result);
    }

    return error.InvalidFlakeRef;
}

/// Gate for the flake builtins on the `flakes` experimental feature (Nix
/// parity). A hard eval error, like the `fetch-tree` gate: not catchable by
/// `builtins.tryEval`. `getFlake`/`parseFlakeRef` call each other and the
/// fetcher via their un-suffixed impls, so those internal calls bypass this.
fn requireFlakes(self: *VM) !void {
    if (!self.policy.flakes_enabled) {
        try vm_trace.setErrorMessage(self, "flakes are disabled; pass --extra-experimental-features flakes to enable them");
        return error.MissingExperimentalFeature;
    }
}

pub fn builtinGetFlakeEntry(self: *VM, arg: Value) !Value {
    try requireFlakes(self);
    return builtinGetFlake(self, arg);
}

pub fn builtinParseFlakeRefEntry(self: *VM, arg: Value) !Value {
    try requireFlakes(self);
    return builtinParseFlakeRef(self, arg);
}

pub fn builtinFlakeRefToStringEntry(self: *VM, arg: Value) !Value {
    try requireFlakes(self);
    return builtinFlakeRefToString(self, arg);
}

pub fn builtinGetFlake(self: *VM, arg: Value) !Value {
    const ref = try stringArg(self, arg);
    // A relative path ref (`.`, `./x`, `../x`) resolves against the process CWD,
    // as Nix does for an impure relative flakeref. Absolute paths and scheme
    // refs pass through unchanged.
    const abs_ref: ?[]u8 = if (isRelativePathRef(ref)) try resolveCwdRelative(self, ref) else null;
    defer if (abs_ref) |r| self.allocator.free(r);
    const ref_value = Value.string(try self.intern.intern(abs_ref orelse ref));
    // GC: many intermediate flake values are held live across fetches / output
    // forces that can collect. Root everything created here until we return.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    const parsed = try builtinParseFlakeRef(self, ref_value);
    vm_force.rootKeep(self, parsed);
    const source_info = try builtinFetchTree(self, parsed);
    vm_force.rootKeep(self, source_info);
    const out_path = try requiredStringAttr(self, source_info.asObjectId(), "outPath");
    defer self.allocator.free(out_path);
    try ensureFlakeSourceOnDisk(self, out_path);
    // Subflake: `?dir=sub` puts flake.nix (and flake.lock) in a subdirectory.
    const dir = try optionalStringAttr(self, parsed.asObjectId(), "dir");
    defer if (dir) |d| self.allocator.free(d);

    const flake_value = try importFlakeValue(self, out_path, dir);
    vm_force.rootKeep(self, flake_value);
    const outputs_func = try flakeOutputs(self, flake_value);
    vm_force.rootKeep(self, outputs_func);

    // `self` is the flake's own fixpoint: outputs may read `self.packages`,
    // `self.lib`, etc. Bind it through a placeholder cell (as recursive
    // `let`/`rec` do), then publish the assembled result once outputs return.
    // Created before input resolution: a `follows = ""` input aliases it.
    const self_cell = try vm_force.makeBindingCell(self);
    vm_force.rootKeep(self, self_cell);

    // Inputs: from flake.lock (transitive, honoring `follows`) when present;
    // otherwise from the flake.nix `inputs` declarations (fetched unlocked).
    // Then add `self`.
    var input_entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer input_entries.deinit(self.allocator);
    var source = source_info;
    if (!try resolveRootInputs(self, out_path, dir, self_cell, &input_entries)) {
        // No lock: compute one (fetch + pin inputs), write it back when the
        // flake tree is writable, and resolve inputs from it. `flake update`
        // removes any existing lock first so this path re-pins to latest.
        // Nix then treats the flake as dirty (`forceDirty`): its revision
        // isn't what's being evaluated.
        if (try generateAndUseLock(self, flake_value, parsed, out_path, dir, self_cell, &input_entries)) {
            source = try withoutRevision(self, source_info);
            vm_force.rootKeep(self, source);
        }
    }
    // The result's `inputs` are the declared ones; `outputs` also gets
    // `self` (Nix's `call-flake.nix`).
    const declared = Value.attrs(try self.heap.addAttrs(input_entries.items));
    vm_force.rootKeep(self, declared);
    try input_entries.append(self.allocator, .{ .name = try self.intern.intern("self"), .value = self_cell });

    const inputs = Value.attrs(try self.heap.addAttrs(input_entries.items));
    vm_force.rootKeep(self, inputs);
    const outputs = try vm_force.forceValue(self, try vm_closures.callValue(self, outputs_func, inputs));
    if (!outputs.isAttrs()) return error.TypeError;

    const result = try flakeResultValue(self, source, declared, outputs, try subdirOutPath(self, source, dir));
    publishCell(self, self_cell, result);
    return result;
}

/// A fetched tree's attributes without `rev`, `shortRev` and `revCount`, as
/// Nix's `emitTreeAttrs` gives them with `forceDirty`.
fn withoutRevision(self: *VM, source_info: Value) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    const view = try self.heap.materializeAttrs(source_info.asObjectId());
    for (view.names, view.values) |name, value| {
        const text = self.intern.get(name);
        if (std.mem.eql(u8, text, "rev") or std.mem.eql(u8, text, "shortRev") or std.mem.eql(u8, text, "revCount")) continue;
        try entries.append(self.allocator, .{ .name = name, .value = value });
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

/// A flake's `outPath`: its source's, and its directory in it (Nix's
/// `call-flake.nix`: `sourceInfo.outPath + "/" + subdir`), with the source's
/// context.
fn subdirOutPath(self: *VM, source_info: Value, dir: ?[]const u8) !Value {
    const out_path = try vm_force.forceValue(self, try self.heap.getAttrValue(source_info.asObjectId(), try self.intern.intern("outPath")));
    const subdir = dir orelse return out_path;
    if (subdir.len == 0) return out_path;
    return appendToString(self, out_path, subdir);
}

/// `base + "/" + suffix`, keeping `base`'s context.
fn appendToString(self: *VM, base: Value, suffix: []const u8) !Value {
    const text = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ try vm_strings.stringBytes(self, base), suffix });
    defer self.allocator.free(text);
    const text_id = try self.intern.intern(text);
    if (!base.isContextString()) return Value.string(text_id);
    const context = (try self.heap.getContextString(base.asObjectId())).context;
    return Value.contextString(try self.heap.addContextString(text_id, context));
}

fn isRelativePathRef(ref: []const u8) bool {
    return std.mem.eql(u8, ref, ".") or std.mem.startsWith(u8, ref, "./") or std.mem.startsWith(u8, ref, "../");
}

/// Resolve a relative path ref to an absolute one against the process CWD.
fn resolveCwdRelative(self: *VM, ref: []const u8) ![]u8 {
    const io = self.files.io orelse return error.FileIoUnavailable;
    const cwd = try std.process.currentPathAlloc(io, self.allocator);
    defer self.allocator.free(cwd);
    return std.fs.path.resolve(self.allocator, &.{ cwd, ref });
}

/// Under store writes, a fetched flake's `outPath` is a store path whose NAR is
/// only *recorded* (writes are demand-driven), so it isn't on disk yet. Reading
/// `flake.nix`/`flake.lock` from it — or resolving inputs — needs it
/// materialized first; force the write here (a source path has no dependencies,
/// so this is just its own NAR). No-op in plain eval, where `outPath` is the
/// readable cache path.
fn ensureFlakeSourceOnDisk(self: *VM, out_path: []const u8) !void {
    if (!self.realization.storeWritesEnabled()) return;
    const store_dir = self.realization.store_dir;
    if (!std.mem.startsWith(u8, out_path, store_dir)) return;
    try self.realization.ensureClosure(out_path);
}

/// Import + force the flake.nix attrset at `<out_path>[/dir]`.
fn importFlakeValue(self: *VM, out_path: []const u8, dir: ?[]const u8) !Value {
    const flake_path = if (dir) |d|
        try std.fs.path.join(self.allocator, &.{ out_path, d, "flake.nix" })
    else
        try std.fs.path.join(self.allocator, &.{ out_path, "flake.nix" });
    defer self.allocator.free(flake_path);
    const host = self.import_host orelse return error.ImportUnavailable;
    const flake_value = try vm_force.forceValue(self, try host.import_value(host.context, self, flake_path, self.native_depth));
    if (!flake_value.isAttrs()) return error.TypeError;
    return flake_value;
}

/// The (forced) `outputs` function of an imported flake attrset.
fn flakeOutputs(self: *VM, flake_value: Value) !Value {
    const outputs_id = try self.intern.intern("outputs");
    const outputs = (try self.heap.getAttrValueOpt(flake_value.asObjectId(), outputs_id)) orelse {
        try vm_trace.setErrorMessage(self, "flake has no 'outputs' attribute (flake.nix must define `outputs`)");
        return error.InvalidFlake;
    };
    return vm_force.forceValue(self, outputs);
}

/// Import the flake.nix at `<out_path>[/dir]` and return its (forced) `outputs`.
fn flakeOutputsFunc(self: *VM, out_path: []const u8, dir: ?[]const u8) !Value {
    return flakeOutputs(self, try importFlakeValue(self, out_path, dir));
}

/// Parse `<out_path>[/dir]/flake.lock` and resolve the root flake's declared
/// inputs into `out_entries` (each a fetched, evaluated input flake). Returns
/// false (leaving `out_entries` untouched) when there is no lock file, so the
/// caller can fall back to the flake.nix `inputs` declarations. `root_value`
/// is the flake's own (pending) value — the target of `follows = ""` edges.
fn resolveRootInputs(self: *VM, out_path: []const u8, dir: ?[]const u8, root_value: Value, out_entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry)) !bool {
    const lock_path = if (dir) |d|
        try std.fs.path.join(self.allocator, &.{ out_path, d, "flake.lock" })
    else
        try std.fs.path.join(self.allocator, &.{ out_path, "flake.lock" });
    defer self.allocator.free(lock_path);
    const lock_data = self.files.readFile(lock_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    try resolveInputsFromLockData(self, lock_data, root_value, out_entries, false);
    return true;
}

/// Parse a `flake.lock` (from disk or freshly generated) and resolve the root
/// flake's declared inputs into `out_entries`. `root_value` (the flake's own
/// pending value) resolves edges that follow the root node — Nix's
/// `inputs.<name>.follows = ""`, an input aliasing the flake itself.
/// `fresh`: the lock was computed in this evaluation, not read from a file.
fn resolveInputsFromLockData(self: *VM, lock_data: []const u8, root_value: Value, out_entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry), fresh: bool) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, lock_data, .{}) catch return error.InvalidFlakeLock;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFlakeLock;
    // Nix errors on an unknown lock version; it reads formats 5–7. Our node
    // parser (`locked`/`inputs`/`follows`) is common to all three.
    const version_v = parsed.value.object.get("version") orelse return error.InvalidFlakeLock;
    if (version_v != .integer or version_v.integer < 5 or version_v.integer > 7) return error.UnsupportedFlakeLockVersion;
    const nodes_v = parsed.value.object.get("nodes") orelse return error.InvalidFlakeLock;
    const root_name_v = parsed.value.object.get("root") orelse return error.InvalidFlakeLock;
    if (nodes_v != .object or root_name_v != .string) return error.InvalidFlakeLock;
    const nodes = nodes_v.object;
    const root_name = root_name_v.string;

    const root_node = nodes.get(root_name) orelse return error.InvalidFlakeLock;
    if (root_node != .object) return error.InvalidFlakeLock;
    const root_inputs = root_node.object.get("inputs") orelse return; // lock exists, flake has no inputs
    if (root_inputs != .object) return error.InvalidFlakeLock;

    var memo: std.StringHashMapUnmanaged(Value) = .empty;
    defer memo.deinit(self.allocator);
    // The root node has no `locked` ref to fetch — it IS this flake. Seeding
    // the memo makes `buildNodeThunk` hand any root-resolving edge (a
    // `follows = ""` at any depth) the flake's own value.
    try memo.put(self.allocator, root_name, root_value);

    var it = root_inputs.object.iterator();
    while (it.next()) |entry| {
        const target_node = try followInput(nodes, root_name, entry.value_ptr.*, 0);
        const thunk = try buildNodeThunk(self, nodes, target_node, root_name, &memo, fresh);
        try out_entries.append(self.allocator, .{ .name = try self.intern.intern(entry.key_ptr.*), .value = thunk });
    }
}

// ---- flake.lock generation ------------------------------------------------
//
// When a flake has inputs but no `flake.lock`, compute one: fetch each input to
// pin its `locked` ref (rev/narHash/lastModified), recurse into its own inputs
// (honoring `follows` and `inputs.x.inputs.y` overrides declared in the parent),
// deduplicate identical nodes, and serialize the Nix version-7 graph. The
// result is written back next to `flake.nix` when that directory is writable,
// and is fed to the normal lock reader so evaluation uses the pinned graph.

/// A minimal, insertion-ordered JSON value for emitting a lock (std.json's
/// ObjectMap doesn't preserve order and its API varies across Zig versions).
const JField = struct { key: []const u8, val: JVal };
const JVal = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    array: []const JVal,
    object: []const JField,
};

const LockEdge = struct {
    name: []const u8,
    node_key: ?[]const u8 = null, // a concrete node…
    follows: ?[]const []const u8 = null, // …or a root-relative follows path
};

/// Iterate a `follows` string's `/`-separated input-path segments. Nix's
/// tokenizer drops empty elements, so `follows = ""` is the EMPTY path — the
/// root node, i.e. the flake itself (a lock edge of `[]`).
const FollowsIter = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

    fn init(target: []const u8) FollowsIter {
        return .{ .inner = std.mem.splitScalar(u8, target, '/') };
    }

    fn next(self: *FollowsIter) ?[]const u8 {
        while (self.inner.next()) |seg| if (seg.len != 0) return seg;
        return null;
    }
};

const LockNode = struct {
    key: []const u8,
    locked: JVal,
    original: JVal,
    is_flake: bool,
    inputs: []const LockEdge = &.{},
    /// A relative `path:` input: the input path of the flake whose source
    /// it's part of.
    parent: ?[]const []const u8 = null,
};

const LockGen = struct {
    vm: *VM,
    arena: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(LockNode) = .empty,
    names: std.StringHashMapUnmanaged(u32) = .empty, // base name → next disambiguator

    // Merge context (`flake update`/`lock`): an existing lock whose untouched
    // root inputs are copied forward rather than re-fetched. Null → pin all.
    existing_nodes: ?std.json.ObjectMap = null,
    existing_root: []const u8 = "root",
    update_all: bool = true, // re-pin every root input
    update_names: []const []const u8 = &.{}, // …or only these
    imported: std.StringHashMapUnmanaged([]const u8) = .empty, // existing node name → new key
    /// The (declared) refs of the flakes being locked on the current path,
    /// the root excluded, as Nix keeps them to find circular imports.
    parents: std.ArrayListUnmanaged([]const u8) = .empty,

    /// A node key that is unique in the graph: the input name, or `name_N`.
    fn uniqueKey(self: *LockGen, name: []const u8) ![]const u8 {
        const gop = try self.names.getOrPut(self.arena, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = 2;
            return name;
        }
        const n = gop.value_ptr.*;
        gop.value_ptr.* = n + 1;
        return std.fmt.allocPrint(self.arena, "{s}_{d}", .{ name, n });
    }

    /// The existing lock's root-node `inputs` map, or null when there is no
    /// reusable lock.
    fn existingRootInputs(self: *LockGen) ?std.json.ObjectMap {
        const nodes = self.existing_nodes orelse return null;
        const root = nodes.get(self.existing_root) orelse return null;
        if (root != .object) return null;
        const inputs = root.object.get("inputs") orelse return null;
        return if (inputs == .object) inputs.object else null;
    }

    /// Whether root input `name` must be re-fetched (vs. copied from the existing
    /// lock): when there's no lock, `update` was asked for it, or it's new.
    fn shouldRepin(self: *LockGen, name: []const u8) bool {
        if (self.update_all) return true;
        for (self.update_names) |n| if (std.mem.eql(u8, n, name)) return true;
        const root_inputs = self.existingRootInputs() orelse return true;
        return root_inputs.get(name) == null; // a newly-declared input has no pin yet
    }
};

/// `std.fmt` into an unmanaged byte list (which has no `print` of its own).
fn appendFmt(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    try out.appendSlice(alloc, s);
}

/// Write `v` as nlohmann's `dump(2)` does, which is how Nix writes lock
/// files: two-space indentation, object keys sorted, `[]`/`{}` when empty,
/// strings escaped only as JSON requires.
fn writeLockJson(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, v: JVal, depth: usize) !void {
    switch (v) {
        .string => |s| {
            try out.append(alloc, '"');
            for (s) |c| switch (c) {
                '"' => try out.appendSlice(alloc, "\\\""),
                '\\' => try out.appendSlice(alloc, "\\\\"),
                '\n' => try out.appendSlice(alloc, "\\n"),
                '\t' => try out.appendSlice(alloc, "\\t"),
                '\r' => try out.appendSlice(alloc, "\\r"),
                0x08 => try out.appendSlice(alloc, "\\b"),
                0x0c => try out.appendSlice(alloc, "\\f"),
                0...0x07, 0x0b, 0x0e...0x1f => try appendFmt(out, alloc, "\\u{x:0>4}", .{c}),
                else => try out.append(alloc, c),
            };
            try out.append(alloc, '"');
        },
        .integer => |n| try appendFmt(out, alloc, "{d}", .{n}),
        .boolean => |b| try out.appendSlice(alloc, if (b) "true" else "false"),
        .array => |arr| {
            if (arr.len == 0) return out.appendSlice(alloc, "[]");
            try out.appendSlice(alloc, "[\n");
            for (arr, 0..) |item, i| {
                if (i != 0) try out.appendSlice(alloc, ",\n");
                try out.appendNTimes(alloc, ' ', 2 * (depth + 1));
                try writeLockJson(out, alloc, item, depth + 1);
            }
            try out.append(alloc, '\n');
            try out.appendNTimes(alloc, ' ', 2 * depth);
            try out.append(alloc, ']');
        },
        .object => |fields| {
            if (fields.len == 0) return out.appendSlice(alloc, "{}");
            const sorted = try alloc.dupe(JField, fields);
            std.mem.sort(JField, sorted, {}, struct {
                fn lessThan(_: void, x: JField, y: JField) bool {
                    return std.mem.lessThan(u8, x.key, y.key);
                }
            }.lessThan);
            try out.appendSlice(alloc, "{\n");
            for (sorted, 0..) |f, i| {
                if (i != 0) try out.appendSlice(alloc, ",\n");
                try out.appendNTimes(alloc, ' ', 2 * (depth + 1));
                try writeLockJson(out, alloc, .{ .string = f.key }, depth + 1);
                try out.appendSlice(alloc, ": ");
                try writeLockJson(out, alloc, f.val, depth + 1);
            }
            try out.append(alloc, '\n');
            try out.appendNTimes(alloc, ' ', 2 * depth);
            try out.append(alloc, '}');
        },
    }
}

fn refAttrsToFields(gen: *LockGen, ref_attrs: Value) !std.ArrayListUnmanaged(JField) {
    var fields: std.ArrayListUnmanaged(JField) = .empty;
    if (ref_attrs.isAttrs()) {
        const ra_view = try gen.vm.heap.materializeAttrs(ref_attrs.asObjectId());
        for (ra_view.names, ra_view.values) |e_name, e_value| {
            const name = try gen.arena.dupe(u8, gen.vm.intern.get(e_name));
            const val = try vm_force.forceValue(gen.vm, e_value);
            const jv: JVal = if (val.isString())
                .{ .string = try gen.arena.dupe(u8, gen.vm.intern.get(val.asInternId())) }
            else if (val.isInt())
                .{ .integer = val.asInt() }
            else if (val.isBool())
                .{ .boolean = val.asBool() }
            else
                continue;
            try fields.append(gen.arena, .{ .key = name, .val = jv });
        }
    }
    return fields;
}

fn refAttrsToJson(gen: *LockGen, ref_attrs: Value) !JVal {
    return .{ .object = (try refAttrsToFields(gen, ref_attrs)).items };
}

fn hasField(fields: []const JField, key: []const u8) bool {
    for (fields) |f| if (std.mem.eql(u8, f.key, key)) return true;
    return false;
}

/// The `locked` node: the ref's identity fields plus the fetched pin
/// (rev/narHash/lastModified/revCount). `ref` is dropped once a `rev` pins it.
fn lockedJson(gen: *LockGen, ref_attrs: Value, src_info: Value) !JVal {
    var fields = try refAttrsToFields(gen, ref_attrs);
    for ([_][]const u8{ "narHash", "rev", "shortRev" }) |field| {
        if (try optionalStringAttr(gen.vm, src_info.asObjectId(), field)) |s| {
            defer gen.vm.allocator.free(s);
            if (!hasField(fields.items, field))
                try fields.append(gen.arena, .{ .key = field, .val = .{ .string = try gen.arena.dupe(u8, s) } });
        }
    }
    for ([_][]const u8{ "lastModified", "revCount" }) |field| {
        if (try optionalIntAttr(gen.vm, src_info.asObjectId(), field)) |n| {
            if (!hasField(fields.items, field))
                try fields.append(gen.arena, .{ .key = field, .val = .{ .integer = n } });
        }
    }
    // A resolved `rev` supersedes the `ref` branch in the locked node (Nix).
    if (hasField(fields.items, "rev")) {
        var filtered: std.ArrayListUnmanaged(JField) = .empty;
        for (fields.items) |f| if (!std.mem.eql(u8, f.key, "ref")) try filtered.append(gen.arena, f);
        fields = filtered;
    }
    return .{ .object = fields.items };
}

/// One `inputs = { <name> = …; }` override map (a forced attrset) paired with
/// the input path of the flake whose flake.nix declared it. Nix absolutizes a
/// `follows` at parse time by prepending the declaring flake's path; carrying
/// the origin lets nested override maps (`inputs.a.inputs.b.inputs.c.…`)
/// thread down arbitrarily deep and still resolve against the right prefix.
const OverrideSrc = struct {
    map: Value,
    declared_at: []const []const u8,
    /// The directory of the declaring flake, which relative inputs are
    /// relative to.
    flake_dir: []const u8,
};

/// A declaration that applies to one input: an ancestor's override entry or
/// the flake's own decl, with the declaring flake's input path.
const InputDecl = struct {
    decl: Value,
    declared_at: []const []const u8,
    flake_dir: []const u8,
};

/// The `follows` target string on a (forced) input declaration, or null.
fn declFollows(self: *VM, decl: Value) !?[]const u8 {
    if (!decl.isAttrs()) return null;
    const f = (try self.heap.getAttrValueOpt(decl.asObjectId(), try self.intern.intern("follows"))) orelse return null;
    const fv = try vm_force.forceValue(self, f);
    if (!fv.isString()) return null;
    return self.intern.get(fv.asInternId());
}

/// An absolute (root-relative) follows path: the declaring flake's input path
/// plus the declared segments — Nix's parse-time prefixing.
fn followsPath(gen: *LockGen, declared_at: []const []const u8, target: []const u8) ![]const []const u8 {
    var segs: std.ArrayListUnmanaged([]const u8) = .empty;
    try segs.appendSlice(gen.arena, declared_at);
    var it = FollowsIter.init(target);
    while (it.next()) |seg| try segs.append(gen.arena, try gen.arena.dupe(u8, seg));
    return segs.items;
}

/// Resolve one declared input of the flake at `prefix` into an edge, creating
/// its node and recursing into transitive inputs. `srcs` are the override maps
/// that apply to this flake's inputs, shallowest-declaring flake first.
fn lockInput(gen: *LockGen, name: []const u8, decl: Value, prefix: []const []const u8, srcs: []const OverrideSrc, flake_dir: []const u8) anyerror!LockEdge {
    const self = gen.vm;
    const name_id = try self.intern.intern(name);

    // Everything declared about this input: ancestor overrides shallowest
    // first, the flake's own decl last. The first declaration that links
    // (`follows`) or pins (url/type) is authoritative — an ancestor override
    // supersedes anything deeper, as Nix's first-registered-wins override map
    // does. Declarations that only carry a nested `inputs` map still
    // contribute overrides to the recursion below.
    var decls: std.ArrayListUnmanaged(InputDecl) = .empty;
    for (srcs) |src| {
        if (try self.heap.getAttrValueOpt(src.map.asObjectId(), name_id)) |v| {
            const forced = try vm_force.forceValue(self, v);
            try decls.append(gen.arena, .{ .decl = forced, .declared_at = src.declared_at, .flake_dir = src.flake_dir });
        }
    }
    try decls.append(gen.arena, .{ .decl = decl, .declared_at = prefix, .flake_dir = flake_dir });

    var eff = decls.items[decls.items.len - 1];
    for (decls.items) |d| {
        if ((try declFollows(self, d.decl)) != null or refLike(self, d.decl)) {
            eff = d;
            break;
        }
    }

    // A `follows` is a link, not a node; its path is relative to the flake
    // that declared it.
    if (try declFollows(self, eff.decl)) |target|
        return .{ .name = name, .follows = try followsPath(gen, eff.declared_at, target) };

    const declared_ref = try parseInputRef(self, eff.decl);
    vm_force.rootKeep(self, declared_ref);
    // The input's flakeness comes from its own declaration even when the ref
    // is overridden (Nix: overrides don't change `flake = false`).
    const is_flake = if (decl.isAttrs()) (try optionalBoolAttr(self, decl.asObjectId(), "flake")) orelse true else true;

    // A relative `path:` input is part of the declaring flake's source: it's
    // locked as declared, with the declaring flake as its parent.
    if (try relativeInputPath(self, declared_ref)) |relative| {
        defer self.allocator.free(relative);
        const ref_json = try refAttrsToJson(gen, declared_ref);
        const key = try gen.uniqueKey(name);
        const node_index = gen.nodes.items.len;
        try gen.nodes.append(gen.arena, .{
            .key = key,
            .locked = ref_json,
            .original = ref_json,
            .is_flake = is_flake,
            .parent = eff.declared_at,
        });
        if (is_flake) {
            const child_dir = try std.fs.path.resolve(gen.arena, &.{ eff.flake_dir, relative });
            try lockChildInputs(gen, node_index, name, decls.items, prefix, declared_ref, child_dir);
        }
        return .{ .name = name, .node_key = key };
    }

    // An indirect input is locked to what the registry resolves it to; the
    // lock's `original` keeps it as declared.
    const ref_attrs = try resolveIndirect(self, declared_ref);
    vm_force.rootKeep(self, ref_attrs);

    const src_info = try builtinFetchTree(self, ref_attrs);
    vm_force.rootKeep(self, src_info);

    const key = try gen.uniqueKey(name);
    // Reserve the node slot before recursing (a diamond may point back at it).
    const node_index = gen.nodes.items.len;
    try gen.nodes.append(gen.arena, .{
        .key = key,
        .locked = try lockedJson(gen, ref_attrs, src_info),
        .original = try refAttrsToJson(gen, declared_ref),
        .is_flake = is_flake,
    });

    if (is_flake) {
        const out_path = try requiredStringAttr(self, src_info.asObjectId(), "outPath");
        defer self.allocator.free(out_path);
        try ensureFlakeSourceOnDisk(self, out_path);
        const sub_dir = try optionalStringAttr(self, ref_attrs.asObjectId(), "dir");
        defer if (sub_dir) |d| self.allocator.free(d);
        const child_dir = try std.fs.path.join(gen.arena, &.{ out_path, sub_dir orelse "" });
        try lockChildInputs(gen, node_index, name, decls.items, prefix, declared_ref, child_dir);
    }
    return .{ .name = name, .node_key = key };
}

/// Lock the inputs of the flake in `child_dir`, the input `name` of the flake
/// at `prefix`. Every declaration level may carry an `inputs` override map
/// (the attr is lazy — force before probing); each threads down with its own
/// declaring flake's path and directory.
fn lockChildInputs(
    gen: *LockGen,
    node_index: usize,
    name: []const u8,
    decls: []const InputDecl,
    prefix: []const []const u8,
    declared_ref: Value,
    child_dir: []const u8,
) anyerror!void {
    const self = gen.vm;
    const child_flake = importFlakeValue(self, child_dir, null) catch return;
    vm_force.rootKeep(self, child_flake);
    var child_srcs: std.ArrayListUnmanaged(OverrideSrc) = .empty;
    for (decls) |d| {
        if (!d.decl.isAttrs()) continue;
        const co = (try self.heap.getAttrValueOpt(d.decl.asObjectId(), try self.intern.intern("inputs"))) orelse continue;
        const forced = try vm_force.forceValue(self, co);
        if (forced.isAttrs()) try child_srcs.append(gen.arena, .{ .map = forced, .declared_at = d.declared_at, .flake_dir = d.flake_dir });
    }
    const child_prefix = try gen.arena.alloc([]const u8, prefix.len + 1);
    @memcpy(child_prefix[0..prefix.len], prefix);
    child_prefix[prefix.len] = name;
    var ref_text: std.ArrayListUnmanaged(u8) = .empty;
    try writeLockJson(&ref_text, gen.arena, try refAttrsToJson(gen, declared_ref), 0);
    for (gen.parents.items) |parent| {
        if (!std.mem.eql(u8, parent, ref_text.items)) continue;
        const message = try std.fmt.allocPrint(self.allocator, "found circular import of flake input '{s}'", .{name});
        defer self.allocator.free(message);
        try vm_trace.setErrorMessage(self, message);
        return error.CircularFlakeImport;
    }
    try gen.parents.append(gen.arena, ref_text.items);
    defer _ = gen.parents.pop();
    // Not assigned in place: locking the child's inputs appends to (and may
    // move) `gen.nodes`.
    const edges = try lockFlakeInputs(gen, child_flake, child_prefix, child_srcs.items, child_dir);
    gen.nodes.items[node_index].inputs = edges;
}

/// The path of a relative `path:` input (Nix's `Input::isRelative`), owned
/// by the VM's allocator, or null.
fn relativeInputPath(self: *VM, ref_attrs: Value) !?[]u8 {
    if (!ref_attrs.isAttrs()) return null;
    const id = ref_attrs.asObjectId();
    const input_type = (try optionalStringAttr(self, id, "type")) orelse return null;
    defer self.allocator.free(input_type);
    if (!std.mem.eql(u8, input_type, "path")) return null;
    const path = (try optionalStringAttr(self, id, "path")) orelse return null;
    if (!std.fs.path.isAbsolute(path)) return path;
    self.allocator.free(path);
    return null;
}

/// Convert a parsed lock JSON value into a `JVal`, preserving object key order.
fn jsonToJVal(gen: *LockGen, v: std.json.Value) anyerror!JVal {
    return switch (v) {
        .string => |s| .{ .string = try gen.arena.dupe(u8, s) },
        .integer => |n| .{ .integer = n },
        .float => |f| .{ .integer = @intFromFloat(f) },
        .bool => |b| .{ .boolean = b },
        .array => |arr| blk: {
            var items: std.ArrayListUnmanaged(JVal) = .empty;
            for (arr.items) |item| try items.append(gen.arena, try jsonToJVal(gen, item));
            break :blk .{ .array = items.items };
        },
        .object => |obj| blk: {
            var fields: std.ArrayListUnmanaged(JField) = .empty;
            var it = obj.iterator();
            while (it.next()) |e| try fields.append(gen.arena, .{ .key = try gen.arena.dupe(u8, e.key_ptr.*), .val = try jsonToJVal(gen, e.value_ptr.*) });
            break :blk .{ .object = fields.items };
        },
        else => .{ .string = "" }, // null / number_string don't appear in a lock node
    };
}

/// Copy an existing-lock input edge (a node-name string, or a follows path) into
/// the new graph, importing the referenced node subtree.
fn importExistingEdge(gen: *LockGen, name: []const u8, edge: std.json.Value) anyerror!LockEdge {
    switch (edge) {
        .string => |node_name| return .{ .name = name, .node_key = try importExistingNode(gen, node_name) },
        .array => |arr| {
            var segs: std.ArrayListUnmanaged([]const u8) = .empty;
            for (arr.items) |seg| if (seg == .string) try segs.append(gen.arena, try gen.arena.dupe(u8, seg.string));
            return .{ .name = name, .follows = segs.items };
        },
        else => return error.InvalidFlakeLock,
    }
}

/// Import an existing-lock node (and its subtree) into the new graph, keeping
/// its pin. Imported once per old node name; sharing only ever happens through
/// edges (as Nix — identical pins stay distinct nodes).
fn importExistingNode(gen: *LockGen, node_name: []const u8) anyerror![]const u8 {
    if (gen.imported.get(node_name)) |k| return k;
    const nodes = gen.existing_nodes orelse return error.InvalidFlakeLock;
    const node_v = nodes.get(node_name) orelse return error.InvalidFlakeLock;
    if (node_v != .object) return error.InvalidFlakeLock;
    const node = node_v.object;
    const locked = try jsonToJVal(gen, node.get("locked") orelse return error.InvalidFlakeLock);

    const key = try gen.uniqueKey(node_name);
    try gen.imported.put(gen.arena, try gen.arena.dupe(u8, node_name), key);
    const node_index = gen.nodes.items.len;
    const is_flake = switch (node.get("flake") orelse std.json.Value{ .bool = true }) {
        .bool => |b| b,
        else => true,
    };
    const parent: ?[]const []const u8 = if (node.get("parent")) |p| parent: {
        if (p != .array) return error.InvalidFlakeLock;
        const segments = try gen.arena.alloc([]const u8, p.array.items.len);
        for (p.array.items, segments) |segment, *out| {
            if (segment != .string) return error.InvalidFlakeLock;
            out.* = try gen.arena.dupe(u8, segment.string);
        }
        break :parent segments;
    } else null;
    try gen.nodes.append(gen.arena, .{
        .key = key,
        .locked = locked,
        .original = if (node.get("original")) |o| try jsonToJVal(gen, o) else locked,
        .is_flake = is_flake,
        .parent = parent,
    });
    if (node.get("inputs")) |ins| if (ins == .object) {
        var edges: std.ArrayListUnmanaged(LockEdge) = .empty;
        var it = ins.object.iterator();
        while (it.next()) |e| try edges.append(gen.arena, try importExistingEdge(gen, try gen.arena.dupe(u8, e.key_ptr.*), e.value_ptr.*));
        gen.nodes.items[node_index].inputs = edges.items;
    };
    return key;
}

/// Whether `v` looks like a concrete input ref (a string/path, or an attrset
/// with `url`/`type`) as opposed to a bare `{ follows = …; }` / overrides map.
fn refLike(self: *VM, v: Value) bool {
    if (v.isString() or v.isPath()) return true;
    if (!v.isAttrs()) return false;
    const has_url = (self.heap.getAttrValueOpt(v.asObjectId(), self.intern.intern("url") catch return false) catch null) != null;
    const has_type = (self.heap.getAttrValueOpt(v.asObjectId(), self.intern.intern("type") catch return false) catch null) != null;
    return has_url or has_type;
}

/// Parse an input declaration (`"github:…"` / `{ url = …; }` / inline ref) into
/// ref attrs — the eager analogue of the dispatch in `buildFlakeNixInputThunks`.
fn parseInputRef(self: *VM, decl: Value) !Value {
    if (decl.isPath()) return builtinParseFlakeRef(self, decl);
    if (decl.isString()) return flake_ref.parseInput(self, decl);
    if (decl.isAttrs()) {
        if (try self.heap.getAttrValueOpt(decl.asObjectId(), try self.intern.intern("url"))) |u|
            return flake_ref.parseInput(self, try vm_force.forceValue(self, u));
        return decl; // inline { type = …; }
    }
    return error.InvalidFlakeRef;
}

/// Build the edges for every declared input of `flake_value` (the flake at
/// input path `prefix`), applying ancestor override maps (`srcs`, shallowest
/// declaring flake first).
fn lockFlakeInputs(gen: *LockGen, flake_value: Value, prefix: []const []const u8, srcs: []const OverrideSrc, flake_dir: []const u8) anyerror![]LockEdge {
    if (prefix.len > 64) return error.InvalidFlakeLock; // runaway input-path guard
    const self = gen.vm;
    var edges: std.ArrayListUnmanaged(LockEdge) = .empty;
    const inputs_v = (self.heap.getAttrValueOpt(flake_value.asObjectId(), try self.intern.intern("inputs")) catch return edges.items) orelse return edges.items;
    const inputs = try vm_force.forceValue(self, inputs_v);
    if (!inputs.isAttrs()) return edges.items;

    const inputs_view = try self.heap.materializeAttrs(inputs.asObjectId());
    for (inputs_view.names, inputs_view.values) |entry_name, entry_value| {
        const name = self.intern.get(entry_name);
        // At the root, an input the user didn't ask to update keeps its existing
        // pin: copy the old node subtree instead of re-fetching.
        if (prefix.len == 0 and !gen.shouldRepin(name)) {
            if (gen.existingRootInputs()) |root_inputs| {
                if (root_inputs.get(name)) |edge| {
                    try edges.append(gen.arena, try importExistingEdge(gen, try gen.arena.dupe(u8, name), edge));
                    continue;
                }
            }
        }
        const decl = try vm_force.forceValue(self, entry_value);
        try edges.append(gen.arena, try lockInput(gen, try gen.arena.dupe(u8, name), decl, prefix, srcs, flake_dir));
    }
    return edges.items;
}

/// Serialize the resolved graph as a Nix version-7 `flake.lock` (arena-owned).
/// The lock file, as Nix writes it (`LockFile::toJSON`): nodes are named
/// walking the graph depth-first from the root, each node's inputs in name
/// order, after the input that reaches a node first (`a_2`, `a_3`, … when
/// that name is taken); a node nothing reaches is left out.
fn serializeLock(gen: *LockGen, root_edges: []const LockEdge) ![]u8 {
    const a = gen.arena;
    var namer: LockNamer = .{ .gen = gen };
    for (gen.nodes.items, 0..) |node, i| try namer.by_id.put(a, node.key, i);
    try namer.taken.put(a, "root", {});
    const root_inputs = try namer.edgesJson(root_edges);
    const root_fields: []const JField = if (root_inputs.len == 0) &.{} else try a.dupe(JField, &.{.{ .key = "inputs", .val = .{ .object = root_inputs } }});
    try namer.nodes.append(a, .{ .key = "root", .val = .{ .object = root_fields } });

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try writeLockJson(&out, a, .{ .object = &.{
        .{ .key = "nodes", .val = .{ .object = namer.nodes.items } },
        .{ .key = "root", .val = .{ .string = "root" } },
        .{ .key = "version", .val = .{ .integer = 7 } },
    } }, 0);
    try out.append(a, '\n');
    return out.items;
}

const LockNamer = struct {
    gen: *LockGen,
    /// A node's id (`LockNode.key`) to its index in `gen.nodes`.
    by_id: std.StringHashMapUnmanaged(usize) = .empty,
    taken: std.StringHashMapUnmanaged(void) = .empty,
    /// A node's id to its name in the file.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    nodes: std.ArrayListUnmanaged(JField) = .empty,

    fn edgesJson(self: *LockNamer, edges: []const LockEdge) anyerror![]const JField {
        const a = self.gen.arena;
        const sorted = try a.dupe(LockEdge, edges);
        std.mem.sort(LockEdge, sorted, {}, struct {
            fn lessThan(_: void, x: LockEdge, y: LockEdge) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lessThan);
        const fields = try a.alloc(JField, sorted.len);
        for (sorted, fields) |edge, *field| {
            field.* = .{ .key = edge.name, .val = if (edge.follows) |path| follows: {
                const segments = try a.alloc(JVal, path.len);
                for (path, segments) |segment, *v| v.* = .{ .string = segment };
                break :follows .{ .array = segments };
            } else .{ .string = try self.name(edge.node_key.?, edge.name) } };
        }
        return fields;
    }

    /// Name the node `id` (reached as input `input`) and its descendants.
    fn name(self: *LockNamer, id: []const u8, input: []const u8) anyerror![]const u8 {
        if (self.names.get(id)) |existing| return existing;
        const a = self.gen.arena;
        var key = input;
        var n: usize = 2;
        while (self.taken.contains(key)) : (n += 1) key = try std.fmt.allocPrint(a, "{s}_{d}", .{ input, n });
        try self.taken.put(a, key, {});
        try self.names.put(a, id, key);

        const node = self.gen.nodes.items[self.by_id.get(id).?];
        var fields: std.ArrayListUnmanaged(JField) = .empty;
        if (!node.is_flake) try fields.append(a, .{ .key = "flake", .val = .{ .boolean = false } });
        const inputs = try self.edgesJson(node.inputs);
        if (inputs.len != 0) try fields.append(a, .{ .key = "inputs", .val = .{ .object = inputs } });
        try fields.append(a, .{ .key = "locked", .val = node.locked });
        try fields.append(a, .{ .key = "original", .val = node.original });
        if (node.parent) |parent| {
            const segments = try a.alloc(JVal, parent.len);
            for (parent, segments) |segment, *v| v.* = .{ .string = segment };
            try fields.append(a, .{ .key = "parent", .val = .{ .array = segments } });
        }
        try self.nodes.append(a, .{ .key = key, .val = .{ .object = fields.items } });
        return key;
    }
};

fn flakeLockPath(self: *VM, out_path: []const u8, dir: ?[]const u8) ![]u8 {
    return if (dir) |d|
        std.fs.path.join(self.allocator, &.{ out_path, d, "flake.lock" })
    else
        std.fs.path.join(self.allocator, &.{ out_path, "flake.lock" });
}

/// Where a new `flake.lock` goes, as in Nix: into the flake's own source
/// tree when it is local (a `path:` flake, or a `git+file:` work tree),
/// not into its (read-only) store path. Null for any other flake.
fn sourceLockPath(self: *VM, ref_attrs: Value, dir: ?[]const u8) !?[]u8 {
    const id = ref_attrs.asObjectId();
    const type_value = try requiredStringAttr(self, id, "type");
    defer self.allocator.free(type_value);
    const source: ?[]u8 = if (std.mem.eql(u8, type_value, "path"))
        try optionalStringAttr(self, id, "path")
    else if (std.mem.eql(u8, type_value, "git")) git: {
        const url = (try optionalStringAttr(self, id, "url")) orelse break :git null;
        defer self.allocator.free(url);
        const path = if (std.mem.startsWith(u8, url, "file://")) url["file://".len..] else if (std.fs.path.isAbsolute(url)) url else break :git null;
        break :git try self.allocator.dupe(u8, path);
    } else null;
    const root = source orelse return null;
    defer self.allocator.free(root);
    return try flakeLockPath(self, root, dir);
}

/// The forced `inputs` attrset of a flake, or null when it declares none.
fn flakeInputsAttrs(self: *VM, flake_value: Value) !?Value {
    const inputs_v = (self.heap.getAttrValueOpt(flake_value.asObjectId(), try self.intern.intern("inputs")) catch return null) orelse return null;
    const inputs = try vm_force.forceValue(self, inputs_v);
    if (!inputs.isAttrs() or (try self.heap.materializeAttrs(inputs.asObjectId())).len() == 0) return null;
    return inputs;
}

/// getFlake's no-lock branch: compute a lock (pin every input), write it when
/// the CLI asked for that and the flake is a local tree, and resolve the root
/// inputs from it. Returns false when the flake declares no inputs. This is
/// the "generate all" caller of the same lock machinery `computeFlakeLock`
/// (flake update/lock) uses.
fn generateAndUseLock(self: *VM, flake_value: Value, ref_attrs: Value, out_path: []const u8, dir: ?[]const u8, root_value: Value, out_entries: *std.ArrayListUnmanaged(heap_mod.AttrEntry)) !bool {
    if ((try flakeInputsAttrs(self, flake_value)) == null) return false;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    var gen = LockGen{ .vm = self, .arena = arena_state.allocator() };
    const flake_dir = try std.fs.path.join(gen.arena, &.{ out_path, dir orelse "" });
    const lock_json = try serializeLock(&gen, try lockFlakeInputs(&gen, flake_value, &.{}, &.{}, flake_dir));
    try checkLock(self, lock_json);

    // Persist next to the local flake.nix for the CLI, when writable (a
    // read-only tree is left alone — the in-memory lock is still used for
    // this evaluation).
    if (self.policy.write_flake_lock) {
        if (try sourceLockPath(self, ref_attrs, dir)) |lock_path| {
            defer self.allocator.free(lock_path);
            self.files.writeFile(lock_path, lock_json) catch {};
        }
    }

    try resolveInputsFromLockData(self, lock_json, root_value, out_entries, true);
    return true;
}

/// Compute and write `flake.lock` as a standalone operation — `fix flake
/// update`/`lock`. Fetches the flake and its inputs and pins them, but does NOT
/// evaluate `outputs`. `update_all` re-pins every input; otherwise only the
/// inputs named in `update_names` (and any newly-declared ones) are re-fetched,
/// with the rest copied forward from the current lock.
pub fn computeFlakeLock(self: *VM, ref: []const u8, update_all: bool, update_names: []const []const u8) !void {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);

    const parsed_ref = try builtinParseFlakeRef(self, Value.string(try self.intern.intern(ref)));
    vm_force.rootKeep(self, parsed_ref);
    const src_info = try builtinFetchTree(self, parsed_ref);
    vm_force.rootKeep(self, src_info);
    const out_path = try requiredStringAttr(self, src_info.asObjectId(), "outPath");
    defer self.allocator.free(out_path);
    try ensureFlakeSourceOnDisk(self, out_path);
    const dir = try optionalStringAttr(self, parsed_ref.asObjectId(), "dir");
    defer if (dir) |d| self.allocator.free(d);
    const flake_value = try importFlakeValue(self, out_path, dir);
    vm_force.rootKeep(self, flake_value);
    if ((try flakeInputsAttrs(self, flake_value)) == null) return; // nothing to lock

    const lock_path = try flakeLockPath(self, out_path, dir);
    defer self.allocator.free(lock_path);
    const source_lock_path = (try sourceLockPath(self, parsed_ref, dir)) orelse {
        try vm_trace.setErrorMessage(self, "cannot write the lock file of a flake that isn't a local path or git work tree");
        return error.InvalidFlakeRef;
    };
    defer self.allocator.free(source_lock_path);

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();

    // The existing lock (if any) is the merge base; its parse tree must outlive
    // the generator, which references its node objects for untouched inputs.
    var parsed_lock: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_lock) |p| p.deinit();
    var gen = LockGen{ .vm = self, .arena = arena_state.allocator(), .update_all = update_all, .update_names = update_names };
    if (self.files.readFile(lock_path)) |data| {
        if (std.json.parseFromSlice(std.json.Value, self.allocator, data, .{})) |p| {
            parsed_lock = p;
            if (p.value == .object) {
                if (p.value.object.get("nodes")) |n| {
                    if (n == .object) gen.existing_nodes = n.object;
                }
                if (p.value.object.get("root")) |r| {
                    if (r == .string) gen.existing_root = r.string;
                }
            }
        } else |_| {}
    } else |_| {}

    const flake_dir = try std.fs.path.join(gen.arena, &.{ out_path, dir orelse "" });
    const lock_json = try serializeLock(&gen, try lockFlakeInputs(&gen, flake_value, &.{}, &.{}, flake_dir));
    try checkLock(self, lock_json);
    try self.files.writeFile(source_lock_path, lock_json);
}

/// Internal builtin backing a lazy flake input (`inputs.<name>`): forced only
/// when the input is used, so unused inputs are never fetched. Fetches
/// `ref_attrs` and, if it's a flake, evaluates its outputs. `sub_inputs` is
/// the input's pre-built sub-input thunks from the lock graph (possibly
/// empty) — every input resolves through a lock, freshly generated when the
/// flake had none.
pub fn resolveFlakeNode(self: *VM, ref_attrs: Value, sub_inputs: Value, is_flake: Value) anyerror!Value {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, ref_attrs);
    vm_force.rootKeep(self, sub_inputs);

    // Skip the download+ingest when the locked narHash's store path is already
    // valid (Nix pins inputs by narHash; a valid CA path IS the content).
    const src_info = (try flakeInputFromStore(self, ref_attrs)) orelse try builtinFetchTree(self, ref_attrs);
    vm_force.rootKeep(self, src_info);
    try verifyLockedNarHash(self, ref_attrs, src_info);
    const dir = try optionalStringAttr(self, ref_attrs.asObjectId(), "dir");
    defer if (dir) |d| self.allocator.free(d);
    const out_path = try subdirOutPath(self, src_info, dir);
    vm_force.rootKeep(self, out_path);
    if (!is_flake.asBool()) return nonFlakeResult(self, src_info, out_path);

    const src_out = try requiredStringAttr(self, src_info.asObjectId(), "outPath");
    defer self.allocator.free(src_out);
    try ensureFlakeSourceOnDisk(self, src_out);
    const fnix_path = if (dir) |d|
        try std.fs.path.join(self.allocator, &.{ src_out, d, "flake.nix" })
    else
        try std.fs.path.join(self.allocator, &.{ src_out, "flake.nix" });
    defer self.allocator.free(fnix_path);
    if (!(self.files.pathExists(fnix_path) catch false)) return src_info; // non-flake source

    const flake_value = try importFlakeValue(self, src_out, dir);
    vm_force.rootKeep(self, flake_value);
    const outputs_func = try flakeOutputs(self, flake_value);
    vm_force.rootKeep(self, outputs_func);

    if (!sub_inputs.isAttrs()) return error.TypeError; // lock graph always pre-builds them
    const self_cell = try vm_force.makeBindingCell(self);
    vm_force.rootKeep(self, self_cell);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    {
        const sub_view = try self.heap.materializeAttrs(sub_inputs.asObjectId());
        for (sub_view.names, sub_view.values) |e_name, e_value| try entries.append(self.allocator, .{ .name = e_name, .value = e_value });
    }
    try entries.append(self.allocator, .{ .name = try self.intern.intern("self"), .value = self_cell });
    const inputs = Value.attrs(try self.heap.addAttrs(entries.items));
    vm_force.rootKeep(self, inputs);
    const outputs = try vm_force.forceValue(self, try vm_closures.callValue(self, outputs_func, inputs));
    if (!outputs.isAttrs()) return error.TypeError;
    const result = try flakeResultValue(self, src_info, sub_inputs, outputs, out_path);
    publishCell(self, self_cell, result);
    return result;
}

/// A `flake = false` input: `sourceInfo // { inherit sourceInfo outPath; }`.
fn nonFlakeResult(self: *VM, source_info: Value, out_path: Value) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    try entries.append(self.allocator, .{ .name = try self.intern.intern("outPath"), .value = out_path });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("sourceInfo"), .value = source_info });
    const view = try self.heap.materializeAttrs(source_info.asObjectId());
    for (view.names, view.values) |name, value| {
        if (attrEntryNameIndex(entries.items, name) == null) try entries.append(self.allocator, .{ .name = name, .value = value });
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

/// Internal builtin backing a relative `path:` input, which is part of its
/// parent's source (Nix's `call-flake.nix`): it has the parent's
/// `sourceInfo`, and its `outPath` is the parent's with the relative path
/// (and any `dir`) appended as written. `info` is `{ parent; path; dir?; }`.
pub fn resolveRelativeFlakeNode(self: *VM, info: Value, sub_inputs: Value, is_flake: Value) anyerror!Value {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, info);
    vm_force.rootKeep(self, sub_inputs);

    const info_id = info.asObjectId();
    const parent = try vm_force.forceValue(self, try self.heap.getAttrValue(info_id, try self.intern.intern("parent")));
    if (!parent.isAttrs()) return error.TypeError;
    vm_force.rootKeep(self, parent);
    var source_info = try vm_force.forceValue(self, try self.heap.getAttrValue(parent.asObjectId(), try self.intern.intern("sourceInfo")));
    vm_force.rootKeep(self, source_info);
    var out_path = try vm_force.forceValue(self, try self.heap.getAttrValue(parent.asObjectId(), try self.intern.intern("outPath")));
    const relative = try requiredStringAttr(self, info_id, "path");
    defer self.allocator.free(relative);
    if (relative.len != 0) out_path = try appendToString(self, out_path, relative);
    const dir = try optionalStringAttr(self, info_id, "dir");
    defer if (dir) |d| self.allocator.free(d);
    if (dir) |d| if (d.len != 0) {
        out_path = try appendToString(self, out_path, d);
    };
    // Nix passes the nodes of a lock it has just computed to `call-flake.nix`
    // as overrides: the tree's store path as the whole `sourceInfo`, and the
    // (normalized) directory in it. Only a node read from a lock file takes
    // its parent's `sourceInfo` and the path as written.
    const fresh = try self.heap.getAttrValueOpt(info_id, try self.intern.intern("fresh"));
    if (fresh != null and fresh.?.asBool()) {
        const overridden = try freshRelativeSource(self, out_path);
        source_info = overridden.source_info;
        out_path = overridden.out_path;
    }
    vm_force.rootKeep(self, source_info);
    vm_force.rootKeep(self, out_path);
    if (!is_flake.asBool()) return nonFlakeResult(self, source_info, out_path);

    const flake_dir = try std.fs.path.resolve(self.allocator, &.{try vm_strings.stringBytes(self, out_path)});
    defer self.allocator.free(flake_dir);
    const flake_value = try importFlakeValue(self, flake_dir, null);
    vm_force.rootKeep(self, flake_value);
    const outputs_func = try flakeOutputs(self, flake_value);
    vm_force.rootKeep(self, outputs_func);

    if (!sub_inputs.isAttrs()) return error.TypeError;
    const self_cell = try vm_force.makeBindingCell(self);
    vm_force.rootKeep(self, self_cell);
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    {
        const sub_view = try self.heap.materializeAttrs(sub_inputs.asObjectId());
        for (sub_view.names, sub_view.values) |e_name, e_value| try entries.append(self.allocator, .{ .name = e_name, .value = e_value });
    }
    try entries.append(self.allocator, .{ .name = try self.intern.intern("self"), .value = self_cell });
    const inputs = Value.attrs(try self.heap.addAttrs(entries.items));
    vm_force.rootKeep(self, inputs);
    const outputs = try vm_force.forceValue(self, try vm_closures.callValue(self, outputs_func, inputs));
    if (!outputs.isAttrs()) return error.TypeError;
    const result = try flakeResultValue(self, source_info, sub_inputs, outputs, out_path);
    publishCell(self, self_cell, result);
    return result;
}

/// A relative node's `sourceInfo` and `outPath` as Nix's overrides give
/// them for a lock computed in this evaluation: `{ outPath = <store path>; }`
/// and the store path with the node's normalized directory in it.
fn freshRelativeSource(self: *VM, written: Value) !struct { source_info: Value, out_path: Value } {
    const normalized = try std.fs.path.resolvePosix(self.allocator, &.{try vm_strings.stringBytes(self, written)});
    defer self.allocator.free(normalized);
    const store_dir = self.realization.store_dir;
    if (!std.mem.startsWith(u8, normalized, store_dir) or normalized.len <= store_dir.len + 1 or normalized[store_dir.len] != '/')
        return error.InvalidFlakeLock;
    const rest = normalized[store_dir.len + 1 ..];
    const name_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const store_path_text = normalized[0 .. store_dir.len + 1 + name_end];
    const store_path_id = try self.intern.intern(store_path_text);
    const store_path = if (written.isContextString())
        Value.contextString(try self.heap.addContextString(store_path_id, (try self.heap.getContextString(written.asObjectId())).context))
    else
        Value.string(store_path_id);
    const entries = [_]heap_mod.AttrEntry{.{ .name = try self.intern.intern("outPath"), .value = store_path }};
    const source_info = Value.attrs(try self.heap.addAttrs(&entries));
    const subdir = if (name_end < rest.len) rest[name_end + 1 ..] else "";
    const out_path = if (subdir.len == 0) store_path else try appendToString(self, store_path, subdir);
    return .{ .source_info = source_info, .out_path = out_path };
}

/// Resolve `input_target` (a node name string, or a `follows` path array from
/// the root) to a concrete node name. `depth` guards a lock whose follows
/// edges chain into a cycle without ever reaching a node.
/// Nix's `LockFile::check` on a lock just computed: every `follows` leads to
/// an input that exists, and doesn't go round in a cycle (`a.follows = "a"`).
fn checkLock(self: *VM, lock_json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, lock_json, .{}) catch return error.InvalidFlakeLock;
    defer parsed.deinit();
    const nodes = parsed.value.object.get("nodes").?.object;
    var node_it = nodes.iterator();
    while (node_it.next()) |node| {
        const inputs = node.value_ptr.object.get("inputs") orelse continue;
        var input_it = inputs.object.iterator();
        while (input_it.next()) |input| {
            const target = input.value_ptr.*;
            if (target != .array or target.array.items.len == 0) continue;
            _ = followInput(nodes, "root", target, 0) catch {
                var path: std.ArrayListUnmanaged(u8) = .empty;
                defer path.deinit(self.allocator);
                for (target.array.items, 0..) |segment, i| {
                    if (i != 0) try path.append(self.allocator, '/');
                    try path.appendSlice(self.allocator, if (segment == .string) segment.string else "?");
                }
                const message = try std.fmt.allocPrint(self.allocator, "input '{s}' of lock node '{s}' follows '{s}', a non-existent input or a follow cycle", .{ input.key_ptr.*, node.key_ptr.*, path.items });
                defer self.allocator.free(message);
                try vm_trace.setErrorMessage(self, message);
                return error.InvalidFlakeLock;
            };
        }
    }
}

fn followInput(nodes: std.json.ObjectMap, root_name: []const u8, input_target: std.json.Value, depth: u32) error{InvalidFlakeLock}![]const u8 {
    if (depth > 256) return error.InvalidFlakeLock;
    switch (input_target) {
        .string => |s| return s,
        .array => |arr| {
            var cur = root_name;
            for (arr.items) |elem| {
                if (elem != .string) return error.InvalidFlakeLock;
                const node = nodes.get(cur) orelse return error.InvalidFlakeLock;
                if (node != .object) return error.InvalidFlakeLock;
                const ins = node.object.get("inputs") orelse return error.InvalidFlakeLock;
                if (ins != .object) return error.InvalidFlakeLock;
                const next = ins.object.get(elem.string) orelse return error.InvalidFlakeLock;
                cur = try followInput(nodes, root_name, next, depth + 1);
            }
            return cur;
        },
        else => return error.InvalidFlakeLock,
    }
}

/// Build a lazy thunk for one locked node (fetched + evaluated only on force).
/// Its own inputs are pre-built as thunks — cheap, no fetching — and handed to
/// `resolveFlakeNode`, so the whole lock graph is lazy.
///
/// Each node is published through a binding cell registered in `memo` BEFORE
/// its sub-inputs are built: a lock graph may be cyclic (a `follows` edge can
/// point back at an ancestor, or at the node itself — e.g. a child-declared
/// `follows = ""`), and the pending cell breaks the recursion the way the
/// `self` fixpoint cell does. The memo also dedups diamonds (a shared node is
/// one cell, its resolve thunk forced at most once).
fn buildNodeThunk(self: *VM, nodes: std.json.ObjectMap, node_name: []const u8, root_name: []const u8, memo: *std.StringHashMapUnmanaged(Value), fresh: bool) anyerror!Value {
    if (memo.get(node_name)) |t| return t;

    const node_v = nodes.get(node_name) orelse return error.InvalidFlakeLock;
    if (node_v != .object) return error.InvalidFlakeLock;
    const node = node_v.object;

    const locked_v = node.get("locked") orelse return error.InvalidFlakeLock;
    if (locked_v != .object) return error.InvalidFlakeLock;
    const ref_attrs = try jsonObjectToAttrs(self, locked_v.object);
    vm_force.rootKeep(self, ref_attrs);

    const is_flake = switch (node.get("flake") orelse std.json.Value{ .bool = true }) {
        .bool => |b| b,
        else => true,
    };

    // A relative `path:` node is part of its parent's source.
    const parent_value: ?Value = if (try relativeInputPath(self, ref_attrs)) |relative| parent: {
        self.allocator.free(relative);
        const parent_path = node.get("parent") orelse return error.InvalidFlakeLock;
        const parent_name = try followInput(nodes, root_name, parent_path, 0);
        break :parent try buildNodeThunk(self, nodes, parent_name, root_name, memo, fresh);
    } else null;
    if (memo.get(node_name)) |t| return t;

    const cell = try vm_force.makeBindingCell(self);
    vm_force.rootKeep(self, cell);
    try memo.put(self.allocator, node_name, cell);

    // Pre-build this node's input thunks from the lock graph (no fetching).
    var sub_entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer sub_entries.deinit(self.allocator);
    if (node.get("inputs")) |ins| if (ins == .object) {
        var it = ins.object.iterator();
        while (it.next()) |e| {
            const tnode = try followInput(nodes, root_name, e.value_ptr.*, 0);
            const sub_thunk = try buildNodeThunk(self, nodes, tnode, root_name, memo, fresh);
            try sub_entries.append(self.allocator, .{ .name = try self.intern.intern(e.key_ptr.*), .value = sub_thunk });
        }
    };
    const sub_inputs = Value.attrs(try self.heap.addAttrs(sub_entries.items));
    vm_force.rootKeep(self, sub_inputs);

    const thunk = if (parent_value) |parent| thunk: {
        var info: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
        defer info.deinit(self.allocator);
        try info.append(self.allocator, .{ .name = try self.intern.intern("parent"), .value = parent });
        try info.append(self.allocator, .{ .name = try self.intern.intern("fresh"), .value = Value.boolVal(fresh) });
        const ref_view = try self.heap.materializeAttrs(ref_attrs.asObjectId());
        for (ref_view.names, ref_view.values) |name, value| {
            const text = self.intern.get(name);
            if (std.mem.eql(u8, text, "path") or std.mem.eql(u8, text, "dir")) try info.append(self.allocator, .{ .name = name, .value = value });
        }
        const info_value = Value.attrs(try self.heap.addAttrs(info.items));
        vm_force.rootKeep(self, info_value);
        break :thunk try shared.makeBuiltinThunk(self, .resolve_relative_flake_node, &.{ info_value, sub_inputs, Value.boolVal(is_flake) });
    } else try shared.makeBuiltinThunk(self, .resolve_flake_node, &.{ ref_attrs, sub_inputs, Value.boolVal(is_flake) });
    vm_force.rootKeep(self, thunk);
    publishCell(self, cell, thunk);
    return cell;
}

/// Verify a fetched input's NAR hash against the lock, as Nix does — a mismatch
/// means the locked content changed under the pin (corruption / tampering).
/// Only for the tree types whose NAR hash is confirmed to match Nix
/// (forges/tarball/path/git); mercurial/file are skipped.
fn verifyLockedNarHash(self: *VM, ref_attrs: Value, src_info: Value) !void {
    if (!ref_attrs.isAttrs()) return;
    const ty = (try optionalStringAttr(self, ref_attrs.asObjectId(), "type")) orelse return;
    defer self.allocator.free(ty);
    const verifiable = std.mem.eql(u8, ty, "github") or std.mem.eql(u8, ty, "gitlab") or
        std.mem.eql(u8, ty, "sourcehut") or std.mem.eql(u8, ty, "tarball") or
        std.mem.eql(u8, ty, "path") or std.mem.eql(u8, ty, "git");
    if (!verifiable) return;
    const locked = (try optionalStringAttr(self, ref_attrs.asObjectId(), "narHash")) orelse return;
    defer self.allocator.free(locked);
    const got = (try optionalStringAttr(self, src_info.asObjectId(), "narHash")) orelse return;
    defer self.allocator.free(got);
    if (!std.mem.eql(u8, locked, got)) {
        try vm_trace.setErrorMessage(self, "flake input NAR hash mismatch: lock does not match fetched content");
        return error.FlakeNarHashMismatch;
    }
}

/// If this ref's narHash names a store path that is already valid, return the
/// equivalent tree value directly — skipping the download + ingest, as Nix
/// does (so an input whose source has changed since it was locked, such as a
/// flake's own directory once its lock file is written, still evaluates to
/// the locked tree). Validity is the daemon's with store writes, else the
/// path's presence in the local store. Fail-open: any miss (no narHash,
/// unsupported type, unparseable hash, path not valid) returns null and the
/// caller fetches. Reuses the same store-path scheme (`sourcePath`) and value
/// constructors the real fetch would, so a skipped fetch is indistinguishable
/// from a real one.
fn flakeInputFromStore(self: *VM, attrs: Value) !?Value {
    if (!attrs.isAttrs()) return null;
    const id = attrs.asObjectId();
    const nar_hash = (try optionalStringAttr(self, id, "narHash")) orelse return null;
    defer self.allocator.free(nar_hash);
    const ty = (try optionalStringAttr(self, id, "type")) orelse return null;
    defer self.allocator.free(ty);

    // Recursive-NAR (sourcePath) inputs whose narHash is verified against the
    // lock: forges/tarball/path/git all ingest the fetched tree as a NAR under
    // `source:sha256:<narHash>` (the VCS metadata directory is dropped before
    // hashing), so the locked narHash alone names the store path. Mercurial's
    // narHash is unverified and `file` is flat, not a tree; both fetch.
    const is_forge = std.mem.eql(u8, ty, "github") or std.mem.eql(u8, ty, "gitlab") or std.mem.eql(u8, ty, "sourcehut");
    const is_tarball = std.mem.eql(u8, ty, "tarball");
    const is_path = std.mem.eql(u8, ty, "path");
    const is_git = std.mem.eql(u8, ty, "git");
    if (!is_forge and !is_tarball and !is_path and !is_git) return null;

    // The store-path name must match what the fetch would use (see builtinFetchTree).
    const path_attr = if (is_path) (try optionalStringAttr(self, id, "path")) else null;
    defer if (path_attr) |p| self.allocator.free(p);
    if (path_attr) |p| {
        const lm = (try optionalIntAttr(self, id, "lastModified")) orelse 0;
        if (try adoptStorePath(self, p, nar_hash, lm)) |adopted| return adopted;
    }
    if (is_path and path_attr == null) return null;
    const name_attr = if (!is_path) (try optionalStringAttr(self, id, "name")) else null;
    defer if (name_attr) |n| self.allocator.free(n);
    const name = name_attr orelse "source";

    const hex = derivation.hashToBase16(self.allocator, "sha256", nar_hash) catch return null;
    defer self.allocator.free(hex);
    const store_path = try derivation.sourcePath(self.allocator, self.realization.store_dir, name, hex);
    defer self.allocator.free(store_path);
    const valid = if (self.realization.storeWritesEnabled())
        try self.realization.pathIsValid(store_path)
    else
        try self.files.existsUncached(store_path);
    if (!valid) return null;

    // No fetch happens here, so the locked `lastModified` pin is the only
    // timestamp source.
    const last_modified = (try optionalIntAttr(self, id, "lastModified")) orelse 0;
    if (is_forge) {
        const rev = try optionalStringAttr(self, id, "rev");
        defer if (rev) |r| self.allocator.free(r);
        return try githubTreeValue(self, store_path, nar_hash, rev, null, last_modified);
    }
    if (is_git) {
        // A git tree also exposes rev-derived attrs, which package definitions
        // read; the lock pins are exactly what the fetch would have reported.
        // Anything missing (e.g. a shallow lock has no revCount) falls back to
        // the fetch.
        const rev = (try optionalStringAttr(self, id, "rev")) orelse return null;
        defer self.allocator.free(rev);
        const rev_count = (try optionalIntAttr(self, id, "revCount")) orelse return null;
        const locked_modified = (try optionalIntAttr(self, id, "lastModified")) orelse return null;
        const submodules = (try optionalBoolAttr(self, id, "submodules")) orelse false;
        return try gitTreeValue(self, store_path, nar_hash, rev, rev_count, locked_modified, submodules);
    }
    return try pathTreeValue(self, store_path, nar_hash, last_modified);
}

/// Build a Nix attrset from a flake.lock `locked` node's JSON (string + integer
/// fields — type/owner/repo/rev/url/path/narHash/lastModified/...), suitable as
/// input to `builtinFetchTree`.
fn jsonObjectToAttrs(self: *VM, obj: std.json.ObjectMap) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);
    var it = obj.iterator();
    while (it.next()) |e| {
        const v: Value = switch (e.value_ptr.*) {
            .string => |s| Value.string(try self.intern.intern(s)),
            .integer => |n| Value.int(n),
            .bool => |b| Value.boolVal(b), // e.g. locked `submodules`/`shallow`
            else => continue, // skip null/nested — fetch specs only read scalars
        };
        try entries.append(self.allocator, .{ .name = try self.intern.intern(e.key_ptr.*), .value = v });
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

/// Publish a value into a pre-captured binding cell, mirroring the `cell_set`
/// op that recursive `let`/`rec` use. Backs the two flake fixpoints: the
/// `self` cell (published with the assembled flake result) and lock-graph node
/// cells (published with the node's resolve thunk, so cyclic `follows` edges
/// resolve lazily).
fn publishCell(self: *VM, cell: Value, value: Value) void {
    const cell_thunk = self.heap.getThunkAssumeValid(cell.asObjectId());
    if (self.solo) cell_thunk.publishCellBindingSolo(value) else cell_thunk.publishCellBinding(value);
    self.heap.gcRecordEdge(cell.asObjectId(), value);
}

fn flakeResultValue(self: *VM, source_info: Value, inputs: Value, outputs: Value, out_path: Value) !Value {
    var entries: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer entries.deinit(self.allocator);

    // Nix: `result = outputs // sourceInfo // { inputs; outputs; sourceInfo;
    // _type; }`. The explicit fields win over sourceInfo, which wins over
    // outputs — so we append explicit first, then the whole sourceInfo, then
    // outputs, each deduped against what's already present.
    try entries.append(self.allocator, .{ .name = try self.intern.intern("_type"), .value = Value.string(try self.intern.intern("flake")) });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("inputs"), .value = inputs });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("outputs"), .value = outputs });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("sourceInfo"), .value = source_info });
    try entries.append(self.allocator, .{ .name = try self.intern.intern("outPath"), .value = out_path });

    // Promote every sourceInfo field (outPath, narHash, rev, revCount,
    // shortRev, lastModified, submodules, …) — not a fixed subset — so `self`
    // and the returned flake carry whatever the fetcher produced, as Nix does.
    {
        const si_view = try self.heap.materializeAttrs(source_info.asObjectId());
        for (si_view.names, si_view.values) |entry_name, entry_value| {
            if (attrEntryNameIndex(entries.items, entry_name) == null) {
                try entries.append(self.allocator, .{ .name = entry_name, .value = entry_value });
            }
        }
    }

    {
        const out_view = try self.heap.materializeAttrs(outputs.asObjectId());
        for (out_view.names, out_view.values) |entry_name, entry_value| {
            if (attrEntryNameIndex(entries.items, entry_name) == null) {
                try entries.append(self.allocator, .{ .name = entry_name, .value = entry_value });
            }
        }
    }
    return Value.attrs(try self.heap.addAttrs(entries.items));
}

test "lock files name nodes depth-first in input order and print like Nix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ref: JVal = .{ .object = &.{ .{ .key = "type", .val = .{ .string = "path" } }, .{ .key = "path", .val = .{ .string = "/a" } } } };
    // Created in lock-computation order: c (and its `a`), then b (and its
    // `a`), then a `flake = false` input; the root's `a` follows `c`.
    var gen = LockGen{ .vm = undefined, .arena = a };
    try gen.nodes.appendSlice(a, &.{
        .{ .key = "c", .locked = ref, .original = ref, .is_flake = true, .inputs = &.{.{ .name = "a", .node_key = "a" }} },
        .{ .key = "a", .locked = ref, .original = ref, .is_flake = true },
        .{ .key = "b", .locked = ref, .original = ref, .is_flake = true, .inputs = &.{.{ .name = "a", .node_key = "a_2" }} },
        .{ .key = "a_2", .locked = ref, .original = ref, .is_flake = true },
        .{ .key = "x", .locked = ref, .original = ref, .is_flake = false },
        .{ .key = "unreachable", .locked = ref, .original = ref, .is_flake = true },
    });
    const lock = try serializeLock(&gen, &.{
        .{ .name = "c", .node_key = "c" },
        .{ .name = "b", .node_key = "b" },
        .{ .name = "a", .follows = &.{"c"} },
        .{ .name = "x", .node_key = "x" },
    });
    // b is reached first, so its `a` is `a`, and c's is `a_2`.
    const node =
        \\      "locked": {
        \\        "path": "/a",
        \\        "type": "path"
        \\      },
        \\      "original": {
        \\        "path": "/a",
        \\        "type": "path"
        \\      }
    ;
    try std.testing.expectEqualStrings(
        \\{
        \\  "nodes": {
        \\    "a": {
        \\
    ++ node ++
        \\
        \\    },
        \\    "a_2": {
        \\
    ++ node ++
        \\
        \\    },
        \\    "b": {
        \\      "inputs": {
        \\        "a": "a"
        \\      },
        \\
    ++ node ++
        \\
        \\    },
        \\    "c": {
        \\      "inputs": {
        \\        "a": "a_2"
        \\      },
        \\
    ++ node ++
        \\
        \\    },
        \\    "root": {
        \\      "inputs": {
        \\        "a": [
        \\          "c"
        \\        ],
        \\        "b": "b",
        \\        "c": "c",
        \\        "x": "x"
        \\      }
        \\    },
        \\    "x": {
        \\      "flake": false,
        \\
    ++ node ++
        \\
        \\    }
        \\  },
        \\  "root": "root",
        \\  "version": 7
        \\}
        \\
    , lock);
}
