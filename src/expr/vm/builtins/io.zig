//! Nix filesystem and import builtins: pathExists, readFile, readFileType,
//! readDir, findFile, import, and scopedImport.
//! readDir speculatively fans child-directory listings out to helper fibers
//! to warm the FileCache ahead of the demand walk (cache-only, demand-invisible).

const std = @import("std");
const VM = @import("../context.zig").VM;
const Value = @import("runtime").value.Value;
const heap_mod = @import("runtime").heap;
const path_ops = @import("runtime").paths;
const FileCache = @import("store").FileCache;
const strings = @import("strings.zig");
const fetch = @import("fetch.zig");
const prof = @import("../../probe.zig").prof;
const prof_census = @import("../../probe.zig").prof_census;
const corepkgs = @import("../../eval/imports/corepkgs.zig");
const purity = @import("purity.zig");
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_trace = @import("../trace.zig");

const pathArg = strings.pathArg;
const stringTextInternId = strings.stringTextInternId;
const isPlainString = strings.isPlainString;

pub fn builtinPathExists(self: *VM, arg: Value) !Value {
    const path = try demandPathArg(self, arg);
    if (!try self.files.pathExists(path)) return Value.boolVal(false);
    // A trailing `/` or `/.` requires the target to be a directory (Nix): the
    // path model canonicalizes those away, so check the resolved type (a final
    // symlink is followed here, so `<symlink-to-dir>/.` counts as a directory).
    if (std.mem.endsWith(u8, path, "/") or std.mem.endsWith(u8, path, "/.")) {
        return Value.boolVal(try self.files.isDirectoryFollowing(path));
    }
    return Value.boolVal(true);
}

pub fn builtinReadFile(self: *VM, arg: Value) !Value {
    const contents = try self.files.readFile(try demandPathArg(self, arg));
    if (comptime prof.enabled) if (self.workerId() == 0)
        prof_census.recordLongString(contents.len, false);
    return vm_strings.makeString(self, contents);
}

pub fn builtinReadFileType(self: *VM, arg: Value) !Value {
    const kind = try self.files.fileType(try demandPathArg(self, arg));
    return Value.string(try self.intern.intern(kind.nixTypeName()));
}

const DemandContext = struct {
    drv_path: []const u8,
    outputs: []const []const u8,

    fn deinit(self: DemandContext, allocator: std.mem.Allocator) void {
        allocator.free(self.outputs);
    }
};

/// Coerce a path argument while preserving its rooted string context. Present
/// paths return after one uncached filesystem probe and never touch realization
/// state. A missing derivation output is reconstructed solely from the store's
/// owned recipes and the output descriptor in the context string.
pub fn demandPathArg(self: *VM, arg: Value) ![]const u8 {
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    vm_force.rootKeep(self, arg);
    const forced = try vm_force.forceValue(self, arg);
    vm_force.rootKeep(self, forced);
    const value = try vm_strings.stringLikeValue(self, forced);
    vm_force.rootKeep(self, value);
    const path = try vm_strings.stringBytes(self, value);

    // Pure eval confines filesystem reads to the store and the flake source.
    try purity.enforceReadPath(self, path);

    if (!isStorePath(path, self.realization.store_dir)) return path;
    // Deliberately uncached: recording a pre-build false in FileCache would
    // make pathExists contradict the successful realization below.
    if (try self.files.existsUncached(path)) return path;

    // A deferred fetchurl/fetchTarball (hash known, download skipped) whose
    // content is now demanded: run the fetch lazily and seed the cache. Path-only
    // uses never get here, so they stay offline.
    if (try fetch.materializePendingFetch(self, path)) return path;

    // `builtins.toFile`, `builtins.path`, and related source producers carry
    // their own store path as context, not a `.drv` output descriptor. Their
    // recipe is nevertheless sufficient to materialize the demanded path.
    if (self.realization.hasRecipe(path)) {
        try self.realization.ensureClosure(path);
        return path;
    }

    // Recipes are keyed by the store root, so a subpath materializes its
    // root; deferred hashed fetches were handled above from the full path.
    const root = storePathRoot(path, self.realization.store_dir);
    if (root.len != path.len and self.realization.hasRecipe(root)) {
        try self.realization.ensureClosure(root);
        return path;
    }

    const context = (try demandContext(self, value)) orelse return path;
    defer context.deinit(self.allocator);
    if (std.mem.eql(u8, path, context.drv_path)) {
        // Demanding the `.drv` itself (not an output): it — and, via its
        // references, its `.drv` closure — just needs to be on disk. No output
        // build. The `.drv` write was already offloaded (and awaited) when the
        // derivation was forced, so `ensureClosure` just tops up the recipe
        // closure (input sources, substitutions) that isn't yet present.
        try self.realization.ensureClosure(context.drv_path);
    } else {
        // Demanding a derivation OUTPUT (IFD): realize it through the daemon.
        // `realizeOutput` does dependency-first closure realization + build, all
        // as one daemon-I/O offload job, so the demand fiber parks (and other
        // fibers run) rather than blocking a compute worker on the socket.
        try self.realization.realizeOutput(context.drv_path, context.outputs);
    }
    return path;
}

fn isStorePath(path: []const u8, store_dir: []const u8) bool {
    return std.mem.startsWith(u8, path, store_dir) and
        path.len > store_dir.len and path[store_dir.len] == '/';
}

/// `<store>/<name>` prefix of a path inside the store (the whole path when
/// it IS a root). Caller guarantees `isStorePath`.
fn storePathRoot(path: []const u8, store_dir: []const u8) []const u8 {
    const rest = path[store_dir.len + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return path;
    return path[0 .. store_dir.len + 1 + slash];
}

fn demandContext(self: *VM, value: Value) !?DemandContext {
    if (!value.isContextString()) return null;
    const context_entries = (try self.heap.getContextString(value.asObjectId())).context;
    var drv_name: ?@import("runtime").types.InternId = null;
    var descriptor: Value = undefined;
    for (context_entries.names, context_entries.values) |entry_name, entry_value| {
        if (!std.mem.endsWith(u8, self.intern.get(entry_name), ".drv")) continue;
        drv_name = entry_name;
        descriptor = entry_value;
        break;
    }
    const name = drv_name orelse return null;
    vm_force.rootKeep(self, descriptor);
    const marker = try vm_force.forceValue(self, descriptor);
    vm_force.rootKeep(self, marker);
    if (!marker.isAttrs()) return error.TypeError;

    const outputs_id = try self.intern.intern("outputs");
    if (try self.heap.getAttrValueOpt(marker.asObjectId(), outputs_id)) |outputs_value| {
        const list = try vm_force.forceValue(self, outputs_value);
        vm_force.rootKeep(self, list);
        if (!list.isList()) return error.TypeError;
        const list_id = list.asObjectId();
        const count = try self.heap.getListLen(list_id);
        const outputs = try self.allocator.alloc([]const u8, count);
        errdefer self.allocator.free(outputs);
        for (outputs, 0..) |*output, index| {
            const item = try vm_force.forceValue(self, try self.heap.getListItem(list_id, index));
            if (!isPlainString(item)) return error.TypeError;
            output.* = try vm_strings.stringBytes(self, item);
        }
        return .{ .drv_path = self.intern.get(name), .outputs = outputs };
    }

    const all_id = try self.intern.intern("allOutputs");
    if (try self.heap.getAttrValueOpt(marker.asObjectId(), all_id)) |all_value| {
        const all = try vm_force.forceValue(self, all_value);
        if (!all.isBool()) return error.TypeError;
        if (all.asBool()) {
            const known = self.realization.outputNames(self.intern.get(name)) orelse &.{};
            const outputs = try self.allocator.alloc([]const u8, known.len);
            @memcpy(outputs, known);
            return .{ .drv_path = self.intern.get(name), .outputs = outputs };
        }
    }

    return .{ .drv_path = self.intern.get(name), .outputs = try self.allocator.alloc([]const u8, 0) };
}

pub fn builtinImport(self: *VM, arg: Value) !Value {
    const host = self.import_host orelse return error.ImportUnavailable;
    // `import drv` is import-from-derivation: realize the output first so the
    // file to import exists on disk.
    const path = try demandPathArg(self, arg);
    return host.import_value(host.context, self, path, self.native_depth);
}

pub fn builtinScopedImport(self: *VM, scope_arg: Value, path_arg: Value) !Value {
    const scope = try vm_force.forceValue(self, scope_arg);
    if (!scope.isAttrs()) return vm_trace.typeErrorExpected(self, "attrs", scope);
    const host = self.import_host orelse return error.ImportUnavailable;
    const path = try demandPathArg(self, path_arg);
    return host.scoped_import(host.context, self, scope, path, self.native_depth);
}

pub fn builtinReadDir(self: *VM, arg: Value) !Value {
    const dir_path = try demandPathArg(self, arg);
    var cold = false;
    const dir_entries = try self.files.readDirCold(dir_path, &cold);
    // A cold directory-of-directories often precedes reads of its children.
    // Prefetch only warms the cache; errors remain on the demand path.
    if (cold) maybePrefetchChildDirs(self, dir_path, dir_entries);
    var attrs: std.ArrayListUnmanaged(heap_mod.AttrEntry) = .empty;
    defer attrs.deinit(self.allocator);
    try attrs.ensureTotalCapacity(self.allocator, dir_entries.len);

    // The kind strings take one of four values; intern each once per call.
    var kind_values: [FileKindCount]?Value = @splat(null);
    for (dir_entries) |dir_entry| {
        const ki = @intFromEnum(dir_entry.kind);
        const kv = kind_values[ki] orelse blk: {
            const v = Value.string(try self.intern.intern(dir_entry.kind.nixTypeName()));
            kind_values[ki] = v;
            break :blk v;
        };
        attrs.appendAssumeCapacity(.{
            .name = try self.intern.intern(dir_entry.name),
            .value = kv,
        });
    }

    return Value.attrs(try self.heap.addAttrs(attrs.items));
}

const FileKindCount = @typeInfo(@import("store").FileCache.FileKind).@"enum".fields.len;

/// Children per `readdir_prefetch` task.
const readdir_prefetch_batch = 32;

fn maybePrefetchChildDirs(
    self: *VM,
    dir_path: []const u8,
    dir_entries: []const FileCache.DirEntry,
) void {
    const min = self.workers.readDirPrefetchMin();
    if (min == 0) return; // off (w=1 / FIX_READDIR_PREFETCH=0)
    var ndirs: u32 = 0;
    for (dir_entries) |e| {
        if (e.kind == .directory) ndirs += 1;
    }
    if (ndirs < min) return;
    const granted = self.workers.takeReadDirPrefetch(ndirs);
    if (granted == 0) return;
    // The task carries (parent intern id, child index range); the helper
    // re-reads the parent listing — a warm FileCache hit — and joins the
    // names itself, so the submitter pays one intern lookup, not one
    // allocation per child. Ranges cover the raw index space (non-dirs
    // are skipped helper-side): the mapping stays trivially stable.
    const dir_id = self.intern.intern(dir_path) catch return;
    var covered: u32 = 0; // directory-kind children covered so far
    var offset: u32 = 0;
    while (offset < dir_entries.len and covered < granted) {
        const len: u16 = @intCast(@min(dir_entries.len - offset, readdir_prefetch_batch));
        var dirs_in_batch: u32 = 0;
        for (dir_entries[offset..][0..len]) |e| {
            if (e.kind == .directory) dirs_in_batch += 1;
        }
        if (dirs_in_batch != 0) {
            // This work is demand-adjacent, so use the urgent lane. A full
            // queue simply leaves the remaining reads to demand.
            if (!self.workers.submitUrgentReadDir(dir_id, offset, len, self.workerId())) break;
            covered += dirs_in_batch;
        }
        offset += len;
    }
}

pub fn builtinFindFile(self: *VM, search_path_arg: Value, name_arg: Value) !Value {
    const search_path = try vm_force.forceValue(self, search_path_arg);
    if (!search_path.isList()) return error.TypeError;
    const name = try pathArg(self, name_arg);

    // `<nix/fetchurl.nix>` resolves to fix's synthetic corepkgs file rather
    // than any real search-path entry. Lix additionally deprecates shadowing
    // it: a reserved `nix=` prefix, or a prefixless entry that supplies
    // `nix/fetchurl.nix`, is an error unless `nix-path-shadow` is enabled (in
    // which case a matching prefixless entry wins over the corepkgs default).
    const is_corepkgs = std.mem.eql(u8, name, corepkgs.fetchurl_name);

    // Pure eval forbids `<...>` / NIX_PATH lookups, except the synthetic
    // `<nix/fetchurl.nix>` corepkgs file (not a real search-path entry).
    if (!is_corepkgs) try purity.enforceNoSearchPath(self);

    const path_id = try self.intern.intern("path");
    const prefix_id = try self.intern.intern("prefix");
    const list_id = search_path.asObjectId();
    const n = try self.heap.getListLen(list_id);
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const item = try self.heap.getListItem(list_id, idx);
        const entry = try vm_force.forceValue(self, item);
        if (!entry.isAttrs()) return error.TypeError;

        const base_value = try vm_force.forceValue(self, try self.heap.getAttrValue(entry.asObjectId(), path_id));
        const base = switch (base_value.kind()) {
            .path, .string, .string_context, .heap_string => try vm_strings.stringBytes(self, base_value),
            else => return error.TypeError,
        };

        const prefix_value = self.heap.getAttrValue(entry.asObjectId(), prefix_id) catch |err| switch (err) {
            error.MissingAttribute => Value.string(try self.intern.intern("")),
            else => return err,
        };
        const prefix_forced = try vm_force.forceValue(self, prefix_value);
        if (!isPlainString(prefix_forced)) return error.TypeError;
        const prefix = try vm_strings.stringBytes(self, prefix_forced);

        if (is_corepkgs) {
            if (std.mem.eql(u8, prefix, "nix")) {
                if (!self.policy.allow_nix_path_shadow) {
                    try vm_trace.setErrorMessage(self, "the prefix 'nix' is reserved for internal use in the Nix search path; use --extra-deprecated-features nix-path-shadow to silence this error");
                    return error.NixPathShadow;
                }
                continue; // feature on: ignore the reserved entry, corepkgs wins
            }
            if (prefix.len == 0) {
                if (try findFileCandidate(self, base, "", name)) |candidate| {
                    defer self.allocator.free(candidate);
                    if (!self.policy.allow_nix_path_shadow) {
                        try vm_trace.setErrorMessage(self, "shadowing '<nix/...>' by configuring the nix-path is deprecated; use --extra-deprecated-features nix-path-shadow to silence this error");
                        return error.NixPathShadow;
                    }
                    return Value.path(try self.intern.intern(candidate));
                }
            }
            continue; // only reserved-prefix / prefixless entries affect corepkgs
        }

        if (try findFileCandidate(self, base, prefix, name)) |candidate| {
            defer self.allocator.free(candidate);
            return Value.path(try self.intern.intern(candidate));
        }
    }
    if (is_corepkgs) return Value.path(try self.intern.intern(corepkgs.fetchurl_path));
    // A `<...>` that resolves to nothing is a language-level throw in Nix, not
    // an I/O failure, so `tryEval` catches it. Reading a file that is genuinely
    // absent stays FileNotFound and propagates.
    const message = try std.fmt.allocPrint(
        self.allocator,
        "file '{s}' was not found in the Nix search path (add it using $NIX_PATH or -I)",
        .{name},
    );
    defer self.allocator.free(message);
    try vm_trace.setErrorMessage(self, message);
    return error.NixThrow;
}

pub fn findFileCandidate(self: *VM, base: []const u8, prefix: []const u8, name: []const u8) !?[]u8 {
    const suffix = path_ops.searchPathSuffix(prefix, name) orelse return null;
    const candidate = try std.fs.path.resolve(self.allocator, &.{ base, suffix });
    errdefer self.allocator.free(candidate);
    if (try self.files.pathExists(candidate)) return candidate;
    self.allocator.free(candidate);
    return null;
}
