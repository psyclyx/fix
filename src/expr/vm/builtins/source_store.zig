//! Source and store builtins that operate on local paths and evaluator state.

const std = @import("std");
const VM = @import("../context.zig").VM;
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternId = types.InternId;
const heap_mod = @import("runtime").heap;
const file_cache = @import("store").file_cache;
const derivation = @import("store").derivation;
const nar = @import("store").nar;
const path_ops = @import("runtime").paths;
const source_paths = @import("store").realization.source_path;
const strings = @import("strings.zig");
const vm_strings = @import("../strings.zig");
const string_context = @import("string_context.zig");
const vm_force = @import("../force.zig");
const vm_closures = @import("../closures.zig");
const vm_trace = @import("../trace.zig");

const contextEntriesForValue = string_context.contextEntriesForValue;
const contextStringWithPath = string_context.contextStringWithPath;
const pathArg = strings.pathArg;
const stringArg = strings.stringArg;
const stringTextInternId = strings.stringTextInternId;

pub fn builtinGetEnv(self: *VM, name_arg: Value) !Value {
    const name = try vm_strings.noContextString(self, name_arg);
    // Pure eval hides the process environment (Nix returns "" for every var).
    if (self.policy.pure_eval) return Value.string(try self.intern.intern(""));
    const host = self.import_host orelse return Value.string(try self.intern.intern(""));
    const value = try host.get_env(host.context, name);
    return vm_strings.makeString(self, value);
}

pub fn builtinToPath(self: *VM, arg: Value) !Value {
    // Nix's `coerceToPath`: coerce like interpolation, but without copying a
    // path to the store; the result must be absolute, and comes back
    // canonical, as a string, with its context.
    const gc_roots = vm_force.rootsBegin(self);
    defer vm_force.rootsEnd(self, gc_roots);
    const value = try strings.coerceWithoutCopy(self, arg);
    vm_force.rootKeep(self, value);
    const text = try vm_strings.stringBytes(self, value);
    if (!std.fs.path.isAbsolute(text)) return error.RelativePath;
    const canonical = try std.fs.path.resolve(self.allocator, &.{text});
    defer self.allocator.free(canonical);
    const text_id = try self.intern.intern(canonical);
    if (!value.isContextString()) return Value.string(text_id);
    const context = (try self.heap.getContextString(value.asObjectId())).context;
    const entries = try self.allocator.alloc(heap_mod.AttrEntry, context.len());
    defer self.allocator.free(entries);
    for (entries, context.names, context.values) |*entry, name, v| entry.* = .{ .name = name, .value = v };
    return Value.contextString(try self.heap.addContextStringEntries(text_id, entries));
}

pub fn builtinToFile(self: *VM, name_arg: Value, contents_arg: Value) !Value {
    // Both arguments must already be strings (Nix's `forceString`), and the
    // name must not refer to the store.
    const name_value = try vm_force.forceValue(self, name_arg);
    if (!strings.isPlainString(name_value)) return vm_trace.typeErrorExpected(self, "a string", name_value);
    if (name_value.isContextString() and (try contextEntriesForValue(self, name_value)).len() != 0) {
        try vm_trace.setErrorMessage(self, "the name of a file created by builtins.toFile must not refer to a store path");
        return error.TypeError;
    }

    const name_id = try vm_strings.stringNameId(self, name_value);
    try validateStorePathName(self.intern.get(name_id));

    const contents_value = try vm_force.forceValue(self, contents_arg);
    if (!strings.isPlainString(contents_value)) return vm_trace.typeErrorExpected(self, "a string", contents_value);
    const contents_id = try vm_strings.stringNameId(self, contents_value);
    var ref_ids: std.ArrayListUnmanaged(InternId) = .empty;
    defer ref_ids.deinit(self.allocator);
    {
        const cv = try contextEntriesForValue(self, contents_value);
        for (cv.names) |entry_name| {
            const ref = self.intern.get(entry_name);
            if (std.mem.endsWith(u8, ref, ".drv")) {
                const message = try std.fmt.allocPrint(
                    self.allocator,
                    "files created by builtins.toFile may not reference derivations, but {s} references {s}",
                    .{ self.intern.get(name_id), ref },
                );
                defer self.allocator.free(message);
                try vm_trace.setErrorMessage(self, message);
                return error.DerivationReferenceInToFile;
            }
            try ref_ids.append(self.allocator, entry_name);
        }
    }

    const refs = try self.allocator.alloc([]const u8, ref_ids.items.len);
    defer self.allocator.free(refs);
    for (ref_ids.items, refs) |ref_id, *ref| ref.* = self.intern.get(ref_id);

    const name = self.intern.get(name_id);
    const contents = try self.realization.allocator.dupe(u8, self.intern.get(contents_id));
    const path = derivation.textPath(self.allocator, self.realization.store_dir, name, contents, refs) catch |err| {
        self.realization.allocator.free(contents);
        return err;
    };
    defer self.allocator.free(path);
    // recordOwnedTextRecipe consumes contents on success and error.
    try self.realization.recordOwnedTextRecipe(path, contents, refs);
    try self.realization.materializeEagerRecipe(path);
    return contextStringWithPath(self, try self.intern.intern(path));
}

fn validateStorePathName(name: []const u8) !void {
    if (!derivation.store_name.isValid(name)) return error.InvalidStorePathName;
}

/// The source-memo identity of a `filter`/`filterSource` predicate. Only a
/// heap-object predicate (closure, builtin-closure, partial application) has a
/// stable ObjectId to key on; a bare primop has no GC identity, so it returns
/// `null` and its filtered ingest is never memoized (recomputed each time). The
/// GC token pins the id against post-collection reuse (see `FilterKey`).
pub fn filterKeyOf(self: *VM, pred: Value) ?source_paths.FilterKey {
    if (pred.isClosure() or pred.isBuiltinClosure() or pred.isPartialApp()) {
        return .{ .object_id = pred.asObjectId(), .token = self.heap.token };
    }
    return null;
}

pub fn builtinFilterSource(self: *VM, pred_arg: Value, path_arg: Value) !Value {
    const pred = try vm_force.forceValue(self, pred_arg);
    const root_arg = try pathArg(self, path_arg);
    const root = try self.allocator.dupe(u8, root_arg);
    defer self.allocator.free(root);

    const Context = struct {
        vm: @TypeOf(self),
        pred: Value,

        fn accept(context: *anyopaque, path: []const u8, kind: file_cache.FileCache.FileKind) anyerror!bool {
            const ctx: *@This() = @ptrCast(@alignCast(context));
            return filterSourceAccepts(ctx.vm, ctx.pred, path, kind);
        }
    };
    var context: Context = .{ .vm = self, .pred = pred };

    var unsupported: nar.Unsupported = .{};
    defer unsupported.deinit(self.allocator);
    const store_path = source_paths.storePathForFilteredSourceReport(self.allocator, self.realization, self.files, root, path_ops.baseName(root), .{
        .context = &context,
        .accept = Context.accept,
    }, filterKeyOf(self, pred), &unsupported) catch |err| return reportUnsupportedType(self, &unsupported, err);
    defer self.allocator.free(store_path);
    return contextStringWithPath(self, try self.intern.intern(store_path));
}

/// On `error.UnsupportedPathType` from NAR ingestion, attach the Nix-style
/// `file '<path>' has an unsupported type` message (using the path the
/// serializer recorded) before re-raising. Shared by the `path`/`filterSource`
/// copy-to-store builtins.
pub fn reportUnsupportedType(self: *VM, unsupported: *const nar.Unsupported, err: anyerror) anyerror {
    if (err == error.UnsupportedPathType) {
        if (unsupported.path) |p| {
            const msg = std.fmt.allocPrint(self.allocator, "file '{s}' has an unsupported type", .{p}) catch return err;
            defer self.allocator.free(msg);
            vm_trace.setErrorMessage(self, msg) catch {};
        }
    }
    return err;
}

pub fn filterSourceAccepts(self: *VM, pred: Value, path: []const u8, kind: file_cache.FileCache.FileKind) !bool {
    const path_value = Value.string(try self.intern.intern(path));
    const kind_value = Value.string(try self.intern.intern(kind.nixTypeName()));
    const partial = try vm_closures.callValue(self, pred, path_value);
    const result = try vm_force.forceValue(self, try vm_closures.callValue(self, partial, kind_value));
    if (!result.isBool()) return error.TypeError;
    return result.asBool();
}
