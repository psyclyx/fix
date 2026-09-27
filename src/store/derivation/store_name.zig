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
