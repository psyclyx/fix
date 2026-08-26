//! Nix path builtins: baseNameOf, dirOf, placeholder, storePath, and the
//! `path` copy-to-store builtin.

const std = @import("std");
const VM = @import("../context.zig").VM;
const Value = @import("runtime").value.Value;
const ObjectId = @import("runtime").types.ObjectId;
const file_cache = @import("store").file_cache;
const derivation = @import("store").derivation;
const nar = @import("store").nar;
const source_paths = @import("store").realization.source_path;
const path_ops = @import("runtime").paths;
const nix_hash = @import("runtime").hash;
const strings = @import("strings.zig");
const string_context = @import("string_context.zig");
const source_store = @import("source_store.zig");
const vm_force = @import("../force.zig");
const vm_trace = @import("../trace.zig");
const vm_strings = @import("../strings.zig");

const stringArg = strings.stringArg;
const stringTextInternId = strings.stringTextInternId;
const isPlainString = strings.isPlainString;
const contextStringWithPath = string_context.contextStringWithPath;
const filterSourceAccepts = source_store.filterSourceAccepts;

pub fn builtinBaseNameOf(self: *VM, arg: Value) !Value {
    // Coerce like Nix (copyToStore = false): a raw path keeps its text without a
    // store copy; a string/derivation keeps its context.
    const forced = try vm_force.forceValue(self, arg);
    const value = switch (forced.kind()) {
        .path, .string, .string_context, .heap_string => forced,
        .attrs => try strings.coerceAttrsStringContextValue(self, forced),
        else => return error.TypeError,
    };
    const base_id = try self.intern.intern(path_ops.baseName(try vm_strings.stringBytes(self, value)));
    if (value.isContextString()) {
        const ctx = (try self.heap.getContextString(value.asObjectId())).context;
        return Value.contextString(try self.heap.addContextString(base_id, ctx));
    }
    return Value.string(base_id);
}

pub fn builtinDirOf(self: *VM, arg: Value) !Value {
    const forced = try vm_force.forceValue(self, arg);
    const value = switch (forced.kind()) {
        .path, .string, .string_context, .heap_string => forced,
        .attrs => try strings.coerceAttrsStringContextValue(self, forced),
        else => return error.TypeError,
    };
    const dir_id = try self.intern.intern(path_ops.dirOf(try vm_strings.stringBytes(self, value)));
    if (value.isPath()) return Value.path(dir_id);
    if (value.isContextString()) {
        const ctx = (try self.heap.getContextString(value.asObjectId())).context;
        return Value.contextString(try self.heap.addContextString(dir_id, ctx));
    }
    return Value.string(dir_id);
}

pub fn builtinPlaceholder(self: *VM, arg: Value) !Value {
    const output = try stringArg(self, arg);
    const fingerprint = try std.fmt.allocPrint(self.allocator, "nix-output:{s}", .{output});
    defer self.allocator.free(fingerprint);
    const hash = try nix_hash.hashBytesNixBase32(self.allocator, "sha256", fingerprint);
    defer self.allocator.free(hash);
    const text = try std.fmt.allocPrint(self.allocator, "/{s}", .{hash});
    defer self.allocator.free(text);
    return Value.string(try self.intern.intern(text));
}

pub fn builtinStorePath(self: *VM, arg: Value) !Value {
    const path = try strings.pathArg(self, arg);
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
    return contextStringWithPath(self, try self.intern.intern(path));
}

fn optionalAttr(self: *VM, attrs_id: ObjectId, name: []const u8) !Value {
    const id = try self.intern.intern(name);
    return self.heap.getAttrValue(attrs_id, id) catch |err| switch (err) {
        error.MissingAttribute => Value.null_val,
        else => return err,
    };
}

/// Validate a store-path name (mirrors Nix `checkName`): non-empty, ≤211 bytes,
/// not `.`/`..`, and only `[A-Za-z0-9+._?=-]`. On failure sets an error trace
/// message containing "is not a valid store path" and returns the error.
fn validateStorePathName(self: *VM, name: []const u8) !void {
    if (derivation.store_name.isValid(name)) return;
    const message = try std.fmt.allocPrint(
        self.allocator,
        "store path name '{s}' is not a valid store path name",
        .{name},
    );
    defer self.allocator.free(message);
    try vm_trace.setErrorMessage(self, message);
    return error.InvalidStorePath;
}

/// Compare a FOD-locking `sha256`/`hash` attr (`expected`, in SRI/base32/base16)
/// against the `actual_hex` content hash for the chosen ingestion mode. On a
/// mismatch sets an error trace message containing "hash mismatch" and errors.
fn checkFodHash(self: *VM, expected: []const u8, actual_hex: []const u8) !void {
    const expected_hex = derivation.hashToBase16(self.allocator, "sha256", expected) catch {
        const message = try std.fmt.allocPrint(self.allocator, "invalid sha256 hash '{s}'", .{expected});
        defer self.allocator.free(message);
        try vm_trace.setErrorMessage(self, message);
        return error.InvalidHash;
    };
    defer self.allocator.free(expected_hex);
    if (std.ascii.eqlIgnoreCase(expected_hex, actual_hex)) return;
    const message = try std.fmt.allocPrint(
        self.allocator,
        "hash mismatch importing path: expected sha256 '{s}', got '{s}'",
        .{ expected_hex, actual_hex },
    );
    defer self.allocator.free(message);
    try vm_trace.setErrorMessage(self, message);
    return error.HashMismatch;
}

pub fn builtinPath(self: *VM, arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, arg);
    if (!attrs.isAttrs()) return error.TypeError;
    const attrs_id = attrs.asObjectId();

    const path_id = try self.intern.intern("path");
    // Nix's coerceToPath: paths and strings directly, anything else (an
    // attrset via outPath/__toString, e.g. a flake input) through the
    // non-copying string coercion.
    const path_like = try vm_strings.stringLikeValue(self, try self.heap.getAttrValue(attrs_id, path_id));
    // `stringBytes` only borrows: a `__toString` result is a fresh heap string
    // whose slice dies at the next GC safepoint, and the attr forces and user
    // `filter` calls below are safepoints. Intern to own it for the rest of
    // the function; the store path this becomes is interned downstream anyway.
    const path = self.intern.get(try self.intern.intern(try vm_strings.stringBytes(self, path_like)));
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;

    const name_value = try optionalAttr(self, attrs_id, "name");
    var store_name = path_ops.baseName(path);
    if (!name_value.isNull()) {
        const name = try vm_force.forceValue(self, name_value);
        if (!isPlainString(name)) return error.TypeError;
        // Interned for the same reason as `path`: this outlives the forces and
        // filter calls below, and a heap-string slice does not.
        store_name = self.intern.get(try self.intern.intern(try vm_strings.stringBytes(self, name)));
    }
    // Nix validates the store-path name before touching the filesystem.
    try validateStorePathName(self, store_name);

    // `recursive` defaults to true (NAR / fixed:r:sha256 ingestion). When
    // false, a single regular file is ingested flat (fixed:sha256).
    const recursive_value = try optionalAttr(self, attrs_id, "recursive");
    var recursive = true;
    if (!recursive_value.isNull()) {
        const value = try vm_force.forceValue(self, recursive_value);
        recursive = switch (value.kind()) {
            .bool_true => true,
            .bool_false => false,
            else => return error.TypeError,
        };
    }

    // Optional FOD lock: `sha256` (or `hash`) attr checked against the content.
    var sha_value = try optionalAttr(self, attrs_id, "sha256");
    if (sha_value.isNull()) sha_value = try optionalAttr(self, attrs_id, "hash");
    var expected_hash: ?[]const u8 = null;
    if (!sha_value.isNull()) {
        const value = try vm_force.forceValue(self, sha_value);
        if (!isPlainString(value)) return error.TypeError;
        // Checked after `recursiveIngest`, so it must outlive the filter calls.
        expected_hash = self.intern.get(try self.intern.intern(try vm_strings.stringBytes(self, value)));
    }

    if (!recursive) {
        // Flat ingestion: a single regular file, hashed by its raw contents.
        const flat = try source_paths.flatStorePathForFile(self.allocator, self.realization, self.files, path, store_name);
        defer flat.deinit(self.allocator);
        if (expected_hash) |expected| try checkFodHash(self, expected, flat.hash_hex[0..]);
        return contextStringWithPath(self, try self.intern.intern(flat.store_path));
    }

    const filter_value = try optionalAttr(self, attrs_id, "filter");

    // Recursive (NAR) ingestion, computing the NAR hash so a FOD `sha256`
    // attr can be checked even when a `filter` is present.
    var unsupported: nar.Unsupported = .{};
    defer unsupported.deinit(self.allocator);
    const ingested = recursiveIngest(self, path, store_name, filter_value, &unsupported) catch |err|
        return source_store.reportUnsupportedType(self, &unsupported, err);
    defer ingested.deinit(self.allocator);
    if (expected_hash) |expected| {
        const actual_hex = try derivation.hashToBase16(self.allocator, "sha256", ingested.nar_hash);
        defer self.allocator.free(actual_hex);
        try checkFodHash(self, expected, actual_hex);
    }
    return contextStringWithPath(self, try self.intern.intern(ingested.store_path));
}

/// Recursive (NAR) ingestion of `path` under an optional `filter`, returning
/// the store path and NAR hash. Split out so the closure-holding `Context`
/// lives on this frame for the duration of `ingest`. Records the offending path
/// in `unsupported` when the source contains an unsupported node (fifo/socket).
fn recursiveIngest(self: *VM, path: []const u8, store_name: []const u8, filter_value: Value, unsupported: *nar.Unsupported) !source_paths.Ingested {
    if (filter_value.isNull()) {
        return source_paths.ingestReport(self.allocator, self.realization, self.files, path, store_name, null, null, unsupported);
    }
    const pred = try vm_force.forceValue(self, filter_value);
    const Context = struct {
        vm: @TypeOf(self),
        pred: Value,

        fn accept(context: *anyopaque, candidate: []const u8, kind: file_cache.FileCache.FileKind) anyerror!bool {
            const ctx: *@This() = @ptrCast(@alignCast(context));
            return filterSourceAccepts(ctx.vm, ctx.pred, candidate, kind);
        }
    };
    var context: Context = .{ .vm = self, .pred = pred };
    return source_paths.ingestReport(self.allocator, self.realization, self.files, path, store_name, .{
        .context = &context,
        .accept = Context.accept,
    }, source_store.filterKeyOf(self, pred), unsupported);
}
