//! Cold display projection for the VM explorer tree.
//!
//! Compiler name ids are intentionally append-only rather than interned, so
//! equal sibling components can have different ids. The explorer wants the
//! opposite tradeoff: group first by a relative source path, then consolidate
//! equal name components. This index performs that canonicalization without
//! adding locks or maps to compilation's hot path.

const std = @import("std");
const engine = @import("expr");
const runtime = @import("runtime");

const bytecode = engine.bytecode;
const ChunkId = runtime.types.ChunkId;
const InternId = runtime.types.InternId;
const NameId = bytecode.NameId;
const NodeId = u32;

pub const root_node_id: NodeId = 0;

pub const Kind = enum { path, name };

pub const Node = struct {
    parent: NodeId,
    label: []const u8,
    kind: Kind,
    synthetic: bool,
    file_leaf: bool,
    /// Stable across rebuilt indexes: the semantic parent path, node kind, and
    /// label determine this identity rather than the builder's temporary id.
    stable_key: u64,
};

pub const Stats = struct {
    chunks: u64 = 0,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    labels: [][]u8,
    nodes: []Node,
    child_offsets: []u32,
    children: []NodeId,
    chunk_offsets: []u32,
    chunks: []ChunkId,
    subtree: []Stats,
    chunk_nodes: []NodeId,
    equivalence: bytecode.inspect.ChunkEquivalenceIndex,
    registry_count: u32,
    name_count: u32,

    pub fn build(
        allocator: std.mem.Allocator,
        registry: *const bytecode.ChunkRegistry,
        intern: *const runtime.InternTable,
        base_path: ?[]const u8,
    ) !Index {
        var builder = Builder{
            .allocator = allocator,
            .registry = registry,
            .intern = intern,
            .base_path = base_path,
        };
        defer builder.deinit();
        return builder.build();
    }

    pub fn deinit(self: *Index) void {
        for (self.labels) |label| self.allocator.free(label);
        self.allocator.free(self.labels);
        self.allocator.free(self.nodes);
        self.allocator.free(self.child_offsets);
        self.allocator.free(self.children);
        self.allocator.free(self.chunk_offsets);
        self.allocator.free(self.chunks);
        self.allocator.free(self.subtree);
        self.allocator.free(self.chunk_nodes);
        self.equivalence.deinit();
        self.* = undefined;
    }

    pub fn node(self: *const Index, id: NodeId) ?Node {
        if (id >= self.nodes.len) return null;
        return self.nodes[id];
    }

    pub fn childrenOf(self: *const Index, id: NodeId) []const NodeId {
        if (id + 1 >= self.child_offsets.len) return &.{};
        return self.children[self.child_offsets[id]..self.child_offsets[id + 1]];
    }

    pub fn chunksOf(self: *const Index, id: NodeId) []const ChunkId {
        if (id + 1 >= self.chunk_offsets.len) return &.{};
        return self.chunks[self.chunk_offsets[id]..self.chunk_offsets[id + 1]];
    }

    pub fn statsOf(self: *const Index, id: NodeId) Stats {
        if (id >= self.subtree.len) return .{};
        return self.subtree[id];
    }

    pub fn nodeForChunk(self: *const Index, id: ChunkId) NodeId {
        if (id >= self.chunk_nodes.len) return root_node_id;
        return self.chunk_nodes[id];
    }

    pub fn stableKey(self: *const Index, id: NodeId) u64 {
        return if (id < self.nodes.len) self.nodes[id].stable_key else 0;
    }
};

const NodeKey = struct {
    parent: NodeId,
    label: u32,
    kind: Kind,
    synthetic: bool,
};

const TempNode = struct {
    parent: NodeId,
    label: u32,
    kind: Kind,
    synthetic: bool,
    file_leaf: bool = false,
    stable_key: u64,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    registry: *const bytecode.ChunkRegistry,
    intern: *const runtime.InternTable,
    base_path: ?[]const u8,
    labels: std.StringArrayHashMapUnmanaged(void) = .empty,
    nodes: std.ArrayListUnmanaged(TempNode) = .empty,
    canonical: std.AutoHashMapUnmanaged(NodeKey, NodeId) = .empty,
    file_nodes: std.AutoHashMapUnmanaged(InternId, NodeId) = .empty,

    fn deinit(self: *Builder) void {
        for (self.labels.keys()) |label| self.allocator.free(label);
        self.labels.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.canonical.deinit(self.allocator);
        self.file_nodes.deinit(self.allocator);
    }

    fn build(self: *Builder) !Index {
        const registry_count = self.registry.count();
        const name_count = self.registry.nameCount();
        const name_len = @as(usize, name_count) + 1;

        const root_label = try self.labelId("<root>");
        try self.nodes.append(self.allocator, .{
            .parent = root_node_id,
            .label = root_label,
            .kind = .path,
            .synthetic = false,
            .stable_key = stableNodeKey(0, "<root>", .path, false),
        });

        const name_files = try self.allocator.alloc(?InternId, name_len);
        defer self.allocator.free(name_files);
        @memset(name_files, null);
        var chunk_id: ChunkId = 0;
        while (chunk_id < registry_count) : (chunk_id += 1) {
            const chunk = self.registry.get(chunk_id) orelse continue;
            const name = normalizedName(self.registry.nameOf(chunk_id) orelse bytecode.root_name_id, name_count);
            const file = bytecode.inspect.chunkPrimaryFile(chunk, chunk_id, self.registry) orelse continue;
            if (name_files[name] == null) name_files[name] = file;
        }
        var reverse = name_len;
        while (reverse > 1) {
            reverse -= 1;
            const file = name_files[reverse] orelse continue;
            const parent = normalizedName((self.registry.nameNode(@intCast(reverse)) orelse continue).parent, name_count);
            if (parent != bytecode.root_name_id and name_files[parent] == null) name_files[parent] = file;
        }

        const display_names = try self.allocator.alloc(NodeId, name_len);
        defer self.allocator.free(display_names);
        @memset(display_names, root_node_id);
        var name: NameId = 1;
        while (name <= name_count) : (name += 1) {
            const source_node = self.registry.nameNode(name) orelse continue;
            const file_node = if (name_files[name]) |file| try self.fileNode(file) else root_node_id;
            var parent = if (source_node.parent == bytecode.root_name_id)
                file_node
            else
                display_names[normalizedName(source_node.parent, name_count)];
            if (parent == root_node_id and file_node != root_node_id) parent = file_node;

            const label = self.intern.get(source_node.segment);
            if (source_node.parent == bytecode.root_name_id and name_files[name] != null and
                std.mem.eql(u8, label, std.fs.path.basename(self.intern.get(name_files[name].?))))
            {
                display_names[name] = file_node;
            } else {
                display_names[name] = try self.insertNode(parent, label, .name, source_node.synthetic);
            }
        }

        const chunk_nodes = try self.allocator.alloc(NodeId, registry_count);
        errdefer self.allocator.free(chunk_nodes);
        const direct_counts = try self.allocator.alloc(u32, self.nodes.items.len);
        defer self.allocator.free(direct_counts);
        @memset(direct_counts, 0);
        chunk_id = 0;
        while (chunk_id < registry_count) : (chunk_id += 1) {
            const name_id = normalizedName(self.registry.nameOf(chunk_id) orelse bytecode.root_name_id, name_count);
            const display = display_names[name_id];
            chunk_nodes[chunk_id] = display;
            direct_counts[display] += 1;
        }

        const nodes = try self.allocator.alloc(Node, self.nodes.items.len);
        errdefer self.allocator.free(nodes);
        const labels = try self.takeLabels();
        errdefer {
            for (labels) |label| self.allocator.free(label);
            self.allocator.free(labels);
        }
        for (self.nodes.items, 0..) |node, i| nodes[i] = .{
            .parent = node.parent,
            .label = labels[node.label],
            .kind = node.kind,
            .synthetic = node.synthetic,
            .file_leaf = node.file_leaf,
            .stable_key = node.stable_key,
        };

        const child_offsets = try self.allocator.alloc(u32, nodes.len + 1);
        errdefer self.allocator.free(child_offsets);
        @memset(child_offsets, 0);
        for (nodes[1..]) |node| child_offsets[@as(usize, node.parent) + 1] += 1;
        prefixSum(child_offsets);
        const children = try self.allocator.alloc(NodeId, child_offsets[nodes.len]);
        errdefer self.allocator.free(children);
        const child_cursor = try self.allocator.dupe(u32, child_offsets[0..nodes.len]);
        defer self.allocator.free(child_cursor);
        for (nodes[1..], 1..) |node, id| {
            const at = child_cursor[node.parent];
            children[at] = @intCast(id);
            child_cursor[node.parent] = at + 1;
        }
        const sort_context = SortContext{ .nodes = nodes };
        for (0..nodes.len) |id| {
            std.mem.sort(NodeId, children[child_offsets[id]..child_offsets[id + 1]], sort_context, SortContext.lessThan);
        }

        const chunk_offsets = try self.allocator.alloc(u32, nodes.len + 1);
        errdefer self.allocator.free(chunk_offsets);
        @memset(chunk_offsets, 0);
        for (direct_counts, 0..) |count, id| chunk_offsets[id + 1] = count;
        prefixSum(chunk_offsets);
        const chunks = try self.allocator.alloc(ChunkId, registry_count);
        errdefer self.allocator.free(chunks);
        const chunk_cursor = try self.allocator.dupe(u32, chunk_offsets[0..nodes.len]);
        defer self.allocator.free(chunk_cursor);
        chunk_id = 0;
        while (chunk_id < registry_count) : (chunk_id += 1) {
            const node = chunk_nodes[chunk_id];
            const at = chunk_cursor[node];
            chunks[at] = chunk_id;
            chunk_cursor[node] = at + 1;
        }

        const subtree = try self.allocator.alloc(Stats, nodes.len);
        errdefer self.allocator.free(subtree);
        for (subtree, direct_counts) |*stats, count| stats.* = .{ .chunks = count };
        reverse = nodes.len;
        while (reverse > 1) {
            reverse -= 1;
            subtree[nodes[reverse].parent].chunks += subtree[reverse].chunks;
        }

        var equivalence = try bytecode.inspect.ChunkEquivalenceIndex.build(self.allocator, self.registry);
        errdefer equivalence.deinit();

        return .{
            .allocator = self.allocator,
            .labels = labels,
            .nodes = nodes,
            .child_offsets = child_offsets,
            .children = children,
            .chunk_offsets = chunk_offsets,
            .chunks = chunks,
            .subtree = subtree,
            .chunk_nodes = chunk_nodes,
            .equivalence = equivalence,
            .registry_count = registry_count,
            .name_count = name_count,
        };
    }

    fn takeLabels(self: *Builder) ![][]u8 {
        const result = try self.allocator.alloc([]u8, self.labels.count());
        for (self.labels.keys(), 0..) |label, i| result[i] = @constCast(label);
        self.labels.clearRetainingCapacity();
        return result;
    }

    fn labelId(self: *Builder, text: []const u8) !u32 {
        if (self.labels.getIndex(text)) |id| return @intCast(id);
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        const result = try self.labels.getOrPut(self.allocator, owned);
        if (result.found_existing) {
            self.allocator.free(owned);
            return @intCast(result.index);
        }
        return @intCast(result.index);
    }

    fn insertNode(self: *Builder, parent: NodeId, text: []const u8, kind: Kind, synthetic: bool) !NodeId {
        const label = try self.labelId(text);
        const key: NodeKey = .{ .parent = parent, .label = label, .kind = kind, .synthetic = synthetic };
        const result = try self.canonical.getOrPut(self.allocator, key);
        if (result.found_existing) return result.value_ptr.*;
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .parent = parent,
            .label = label,
            .kind = kind,
            .synthetic = synthetic,
            .stable_key = stableNodeKey(self.nodes.items[parent].stable_key, text, kind, synthetic),
        });
        result.value_ptr.* = id;
        return id;
    }

    fn fileNode(self: *Builder, file: InternId) !NodeId {
        if (self.file_nodes.get(file)) |id| return id;
        const full = self.intern.get(file);
        const shown = relativePath(full, self.base_path);
        var parent = root_node_id;
        if (std.fs.path.isAbsolute(shown)) parent = try self.insertNode(parent, std.fs.path.sep_str, .path, false);
        var components = std.mem.tokenizeAny(u8, shown, "/\\");
        var last = false;
        while (components.next()) |component| {
            const next = components.peek();
            parent = try self.insertNode(parent, component, .path, false);
            last = next == null;
        }
        if (parent == root_node_id) parent = try self.insertNode(parent, std.fs.path.basename(full), .path, false);
        if (last or parent != root_node_id) self.nodes.items[parent].file_leaf = true;
        try self.file_nodes.put(self.allocator, file, parent);
        return parent;
    }
};

fn stableNodeKey(parent: u64, label: []const u8, kind: Kind, synthetic: bool) u64 {
    var hash = std.hash.Wyhash.init(parent ^ 0x6e_61_6d_65_74_72_65_65);
    const discriminants = [_]u8{ @backingInt(kind), @intFromBool(synthetic) };
    hash.update(&discriminants);
    hash.update(label);
    return hash.final();
}

const SortContext = struct {
    nodes: []const Node,

    fn lessThan(self: SortContext, lhs: NodeId, rhs: NodeId) bool {
        const a = self.nodes[lhs];
        const b = self.nodes[rhs];
        if (a.kind != b.kind) return a.kind == .path;
        const order = std.mem.order(u8, a.label, b.label);
        if (order != .eq) return order == .lt;
        return lhs < rhs;
    }
};

fn normalizedName(id: NameId, max: NameId) NameId {
    return if (id <= max) id else bytecode.root_name_id;
}

fn relativePath(path: []const u8, base_path: ?[]const u8) []const u8 {
    const base = std.mem.trimEnd(u8, base_path orelse return path, "/\\");
    if (base.len == 0 or path.len <= base.len or !std.mem.eql(u8, path[0..base.len], base)) return path;
    if (path[base.len] != '/' and path[base.len] != '\\') return path;
    return path[base.len + 1 ..];
}

fn prefixSum(offsets: []u32) void {
    for (offsets[1..], 1..) |*value, i| value.* += offsets[i - 1];
}

test "display tree consolidates duplicate name siblings" {
    const testing = std.testing;
    var intern = try runtime.InternTable.init(testing.allocator);
    defer intern.deinit();
    var registry = try bytecode.ChunkRegistry.init(testing.allocator);
    defer registry.deinit();

    const pkgs_text = try intern.intern("pkgs");
    const lib_text = try intern.intern("lib");
    const pkgs_a = try registry.childName(bytecode.root_name_id, pkgs_text, false);
    const pkgs_b = try registry.childName(bytecode.root_name_id, pkgs_text, false);
    const lib_a = try registry.childName(pkgs_a, lib_text, false);
    const lib_b = try registry.childName(pkgs_b, lib_text, false);
    _ = try registry.registerNamed(try testChunk(testing.allocator, 1), lib_a);
    _ = try registry.registerNamed(try testChunk(testing.allocator, 2), lib_b);

    var index = try Index.build(testing.allocator, &registry, &intern, null);
    defer index.deinit();
    var pkgs: ?NodeId = null;
    for (index.childrenOf(root_node_id)) |id| if (std.mem.eql(u8, index.node(id).?.label, "pkgs")) {
        try testing.expect(pkgs == null);
        pkgs = id;
    };
    const children = index.childrenOf(pkgs.?);
    try testing.expectEqual(@as(usize, 1), children.len);
    try testing.expectEqualStrings("lib", index.node(children[0]).?.label);
    try testing.expectEqual(@as(u64, 2), index.statsOf(children[0]).chunks);
}

test "display node keys survive index rebuilds" {
    const testing = std.testing;
    var intern = try runtime.InternTable.init(testing.allocator);
    defer intern.deinit();
    var registry = try bytecode.ChunkRegistry.init(testing.allocator);
    defer registry.deinit();

    const pkgs_text = try intern.intern("pkgs");
    const lib_text = try intern.intern("lib");
    const pkgs = try registry.childName(bytecode.root_name_id, pkgs_text, false);
    const lib = try registry.childName(pkgs, lib_text, false);
    _ = try registry.registerNamed(try testChunk(testing.allocator, 1), lib);

    var before = try Index.build(testing.allocator, &registry, &intern, null);
    defer before.deinit();
    const before_pkgs = findChild(&before, root_node_id, "pkgs").?;
    const before_lib = findChild(&before, before_pkgs, "lib").?;

    const tools_text = try intern.intern("tools");
    const tools = try registry.childName(pkgs, tools_text, false);
    _ = try registry.registerNamed(try testChunk(testing.allocator, 2), tools);

    var after = try Index.build(testing.allocator, &registry, &intern, null);
    defer after.deinit();
    const after_pkgs = findChild(&after, root_node_id, "pkgs").?;
    const after_lib = findChild(&after, after_pkgs, "lib").?;

    try testing.expectEqual(before.stableKey(before_pkgs), after.stableKey(after_pkgs));
    try testing.expectEqual(before.stableKey(before_lib), after.stableKey(after_lib));
}

test "display tree groups files by relative path components" {
    const testing = std.testing;
    var intern = try runtime.InternTable.init(testing.allocator);
    defer intern.deinit();
    var registry = try bytecode.ChunkRegistry.init(testing.allocator);
    defer registry.deinit();

    const basename = try intern.intern("default.nix");
    const file_a = try intern.intern("/work/a/default.nix");
    const file_b = try intern.intern("/work/b/default.nix");
    const name_a = try registry.childName(bytecode.root_name_id, basename, false);
    const name_b = try registry.childName(bytecode.root_name_id, basename, false);
    _ = try registry.registerNamed(try testChunkAt(testing.allocator, 1, file_a), name_a);
    _ = try registry.registerNamed(try testChunkAt(testing.allocator, 2, file_b), name_b);

    var index = try Index.build(testing.allocator, &registry, &intern, "/work");
    defer index.deinit();
    for ([_][]const u8{ "a", "b" }) |directory| {
        const dir = findChild(&index, root_node_id, directory).?;
        const file = findChild(&index, dir, "default.nix").?;
        try testing.expect(index.node(file).?.file_leaf);
        try testing.expectEqual(@as(u64, 1), index.statsOf(file).chunks);
    }
}

fn findChild(index: *const Index, parent: NodeId, label: []const u8) ?NodeId {
    for (index.childrenOf(parent)) |id| if (std.mem.eql(u8, index.node(id).?.label, label)) return id;
    return null;
}

fn testChunk(allocator: std.mem.Allocator, value: i64) !bytecode.Chunk {
    return testChunkAt(allocator, value, null);
}

fn testChunkAt(allocator: std.mem.Allocator, value: i64, file: ?InternId) !bytecode.Chunk {
    var builder = try bytecode.ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    try builder.emitConstant(allocator, runtime.Value.int(value));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);
    if (file) |id| builder.body_span = .{ .file = id, .offset = 0, .len = 1, .line = 1, .column = 1 };
    return builder.finish(allocator, 0);
}
