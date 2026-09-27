//! Nix hashing builtins: hashString, hashFile and convertHash.

const std = @import("std");
const Value = @import("runtime").value.Value;
const VM = @import("../context.zig").VM;
const nix_hash = @import("runtime").hash;
const strings = @import("strings.zig");
const vm_force = @import("../force.zig");
const vm_strings = @import("../strings.zig");
const vm_trace = @import("../trace.zig");
const string_context = @import("string_context.zig");

const stringArg = strings.stringArg;
const pathArg = strings.pathArg;
const stringTextInternId = strings.stringTextInternId;
const isPlainString = strings.isPlainString;

pub fn builtinHashString(self: *VM, algorithm_arg: Value, string_arg: Value) !Value {
    const algorithm_value = try vm_force.forceValue(self, algorithm_arg);
    const string_value = try vm_force.forceValue(self, string_arg);
    if (!isPlainString(algorithm_value) or !isPlainString(string_value)) return error.TypeError;
    const algorithm = try vm_strings.stringBytes(self, algorithm_value);
    const string = try vm_strings.stringBytes(self, string_value);
    const digest = try nix_hash.hashBytes(self.allocator, algorithm, string);
    defer self.allocator.free(digest);
    return Value.string(try self.intern.intern(digest));
}

pub fn builtinHashFile(self: *VM, algorithm_arg: Value, path_arg: Value) !Value {
    const algorithm = try stringArg(self, algorithm_arg);
    const contents = try self.files.readFile(try pathArg(self, path_arg));
    const digest = try nix_hash.hashBytes(self.allocator, algorithm, contents);
    defer self.allocator.free(digest);
    return Value.string(try self.intern.intern(digest));
}

/// `convertHash { hash; hashAlgo ? …; toHashFormat; }`: `hash` in any of
/// Nix's formats, written in `toHashFormat` (`base16`, `nix32` or its old
/// name `base32`, `base64` or `sri`).
pub fn builtinConvertHash(self: *VM, arg: Value) !Value {
    const attrs = try vm_force.forceValue(self, arg);
    if (!attrs.isAttrs()) return vm_trace.typeErrorExpected(self, "a set", attrs);
    const id = attrs.asObjectId();
    const hash_text = try stringWithoutContext(self, try self.heap.getAttrValue(id, try self.intern.intern("hash")));
    const algorithm: ?nix_hash.Algorithm = if (try self.heap.getAttrValueOpt(id, try self.intern.intern("hashAlgo"))) |algo_value| algo: {
        const name = try stringWithoutContext(self, algo_value);
        break :algo std.meta.stringToEnum(nix_hash.Algorithm, name) orelse return fail(self, "unknown hash algorithm '{s}', expect 'md5', 'sha1', 'sha256', or 'sha512'", .{name});
    } else null;
    const format_name = try stringWithoutContext(self, try self.heap.getAttrValue(id, try self.intern.intern("toHashFormat")));
    const format = nix_hash.Format.parse(format_name) orelse return fail(self, "unknown hash format '{s}', expect 'base16', 'base32', 'base64', or 'sri'", .{format_name});
    const digest = nix_hash.parseAny(hash_text, algorithm) catch |err| return fail(self, "invalid hash '{s}': {t}", .{ hash_text, err });
    const text = try nix_hash.format(self.allocator, digest, format);
    defer self.allocator.free(text);
    return Value.string(try self.intern.intern(text));
}

fn stringWithoutContext(self: *VM, arg: Value) ![]const u8 {
    const value = try vm_force.forceValue(self, arg);
    if (!isPlainString(value)) return vm_trace.typeErrorExpected(self, "a string", value);
    if ((try string_context.contextEntriesForValue(self, value)).len() != 0) return fail(self, "the string '{s}' is not allowed to refer to a store path", .{try vm_strings.stringBytes(self, value)});
    return vm_strings.stringBytes(self, value);
}

fn fail(self: *VM, comptime fmt: []const u8, args: anytype) anyerror {
    const message = try std.fmt.allocPrint(self.allocator, fmt, args);
    defer self.allocator.free(message);
    try vm_trace.setErrorMessage(self, message);
    return error.InvalidHash;
}
