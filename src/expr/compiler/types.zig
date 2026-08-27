//! Shared compiler-internal data types: tracked locals, captures/upvalues,
//! `with`-scopes, the attr-entry views/groups used by attr-set lowering,
//! and container-value options.

const std = @import("std");
const ast = @import("syntax").ast;
const base_types = @import("runtime").types;

const InternId = base_types.InternId;
const Node = ast.Node;

/// A local variable tracked during compilation.
pub const Local = struct {
    name: []const u8,
    name_id: InternId,
    /// Declaring scope's `Compiler.scope_depth` — same width, since `endScope`
    /// compares the two directly.
    depth: u16,
    /// Index from frame base on the stack.
    slot: u16,
};

pub const Capture = struct {
    pub const Kind = enum { local, upvalue };

    name: []const u8,
    name_id: InternId,
    kind: Kind,
    index: u16,
};

pub const WithScope = struct {
    kind: Capture.Kind,
    index: u16,
};

pub const AttrEntryView = struct {
    path: []const Node.Atom,
    /// Present for `${name} = value` entries. Keeping dynamic and static
    /// entries in the same normalized view lets attr-set lowering use one
    /// mixed/static/recursive pipeline instead of mirroring the AST path.
    dynamic_name: ?*const Node = null,
    expr: *const Node,
    inherit_outer: bool = false,
    inherit_group: u32 = 0,
    /// Compiler-local slot holding the one shared lazy source for this group.
    inherit_slot: ?u16 = null,
    /// The outermost attr-path segment this view was desugared from, threaded
    /// through nested-set splits. Nix reports the *start* of an attr path as the
    /// position of every desugared segment, so `{ foo.bar = 1; }` gives `bar`
    /// the position of `foo`. Null for a top-level segment (use `path[0]`).
    origin: ?Node.Atom = null,
};

/// All entries sharing one attr-name root, bucketed into direct `leaves`
/// (path.len == 1) and nested `tails` (path.len > 1).
///
pub const AttrEntryGroup = struct {
    first: Node.Atom,
    name: []const u8,
    name_id: InternId,
    leaf: ?AttrEntryView = null,
    duplicate_leaf: ?AttrEntryView = null,
    leaves: []AttrEntryView = &.{},
    first_nested: ?AttrEntryView = null,
    tails: []AttrEntryView = &.{},
};

pub const AttrEntryGroups = struct {
    groups: []AttrEntryGroup = &.{},
    leaves: []AttrEntryView = &.{},
    tails: []AttrEntryView = &.{},

    pub fn deinit(self: *AttrEntryGroups, allocator: std.mem.Allocator) void {
        allocator.free(self.leaves);
        allocator.free(self.tails);
        for (self.groups) |group| allocator.free(group.name);
        allocator.free(self.groups);
        self.* = .{};
    }
};

pub const ContainerValueOptions = struct {
    raw_identifier: bool = false,
    /// When true and the value compiles to a thunk, emit the eager
    /// variant — runtime submits the thunk to the urgent scheduler
    /// queue at creation. Set by let-binding compile when the body's
    /// strictness signature includes this binding's name.
    eager: bool = false,
};

pub const with_capture_name = "\x00with";
