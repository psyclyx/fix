//! The one pure store-path *name* predicate, mirroring Nix `checkName`.
//!
//! `builtins.path`, `builtins.toFile`, and derivation construction all validate
//! the store-object name against the same rule. Keeping the rule here (rather
//! than re-deriving it per call site) prevents the drift the review caught,
//! where `builtins.toFile` had silently dropped the length and charset checks.

const std = @import("std");

/// Valid iff: non-empty, at most 211 bytes, its first dash-separated
/// component is not `.` or `..` (so `.-foo` and `..-foo` are out too), and
/// every byte is in `[A-Za-z0-9+._?=-]`. Pure — callers attach their own
/// error/diagnostic.
pub fn isValid(name: []const u8) bool {
    if (name.len == 0 or name.len > 211) return false;
    const first = name[0 .. std.mem.indexOfScalar(u8, name, '-') orelse name.len];
    if (std.mem.eql(u8, first, ".") or std.mem.eql(u8, first, "..")) return false;
    for (name) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        switch (char) {
            '+', '-', '.', '_', '?', '=' => continue,
            else => return false,
        }
    }
    return true;
}

/// Is `path` a store path: `<store_dir>/<32-char nix32 hash>-<valid name>`,
/// with nothing after the name? (Nix's `isStorePath`.)
pub fn isStorePath(store_dir: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, store_dir)) return false;
    const rest = path[store_dir.len..];
    if (rest.len < 1 + 32 + 1 or rest[0] != '/' or rest[1 + 32] != '-') return false;
    for (rest[1 .. 1 + 32]) |c| {
        if (std.mem.indexOfScalar(u8, nix32_alphabet, c) == null) return false;
    }
    return isValid(rest[1 + 32 + 1 ..]);
}

const nix32_alphabet = "0123456789abcdfghijklmnpqrsvwxyz";

test "isStorePath wants a hash and a valid name directly in the store" {
    const t = std.testing;
    try t.expect(isStorePath("/nix/store", "/nix/store/04s49lw7m6vgvdrrkq4iilvzfq7848vy-d.drv"));
    try t.expect(!isStorePath("/nix/store", "/nix/store/04s49lw7m6vgvdrrkq4iilvzfq7848vy-d/sub"));
    try t.expect(!isStorePath("/nix/store", "/nix/store/04s49lw7m6vgvdrrkq4iilvzfq7848vy"));
    try t.expect(!isStorePath("/nix/store", "/nix/store/e4s49lw7m6vgvdrrkq4iilvzfq7848vy-d"));
    try t.expect(!isStorePath("/nix/store", "/nix/storex/04s49lw7m6vgvdrrkq4iilvzfq7848vy-d"));
    try t.expect(!isStorePath("/nix/store", "a"));
}

test "isValid accepts and rejects per Nix checkName" {
    const t = std.testing;
    try t.expect(isValid("hello-1.0"));
    try t.expect(isValid("a+b_c.d?e=f"));
    try t.expect(!isValid(""));
    try t.expect(!isValid("."));
    try t.expect(!isValid(".."));
    try t.expect(!isValid(".-"));
    try t.expect(!isValid(".-foo"));
    try t.expect(!isValid("..-foo"));
    try t.expect(isValid("...-foo"));
    try t.expect(isValid(".foo"));
    try t.expect(isValid("a-.-b"));
    try t.expect(!isValid("has/slash"));
    try t.expect(!isValid("has space"));
    // 211 bytes ok, 212 not.
    try t.expect(isValid("a" ** 211));
    try t.expect(!isValid("a" ** 212));
}
