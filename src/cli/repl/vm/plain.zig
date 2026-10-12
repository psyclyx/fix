//! Bounded, line-oriented VM exploration.
//!
//! This is the non-TUI peer of the interactive explorer. It deliberately
//! exposes stable identifiers and composable queries instead of cursor state,
//! so it works in scrollback, pipes, test harnesses, and debugger consoles.

const std = @import("std");
const base = @import("base");
const engine = @import("expr");
const runtime = @import("runtime");
const query_cache = @import("query_cache.zig");
const vm_refs = @import("refs.zig");

const Engine = engine.Engine;
const ChunkId = runtime.types.ChunkId;
const ObjectId = runtime.types.ObjectId;
const Store = query_cache.Store;
const disasm = engine.bytecode.disasm;

const default_limit: usize = 40;
const maximum_limit: usize = 1000;
const member_limit: usize = 200;

pub const Context = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    ev: *Engine,
    cache: *query_cache.Cache,
    color_depth: base.terminal_color.Depth = .none,
    focused_chunk: ?ChunkId = null,

    /// Execute a text-oriented VM query. Returns false when `text` is not a
    /// query name, allowing the REPL to interpret it as a Nix expression.
    pub fn execute(self: *Context, text_raw: []const u8) !bool {
        return self.executeQuery(text_raw) catch |err| switch (err) {
            error.InvalidVmQuery => true,
            else => return err,
        };
    }

    fn executeQuery(self: *Context, text_raw: []const u8) !bool {
        const text = std.mem.trim(u8, text_raw, " \t");
        if (text.len == 0) {
            const id = self.focused_chunk orelse return self.fail("no VM focus yet — evaluate an expression or use `:vm chunk ID`", .{});
            try self.writeChunk(id);
            return true;
        }
        const word, const rest = splitWord(text);
        if (is(word, &.{ "help", "?" })) {
            try self.writeHelp();
        } else if (is(word, &.{ "ls", "tree" })) {
            try self.writeNameChildren(rest);
        } else if (is(word, &.{"chunks"})) {
            try self.writeNameChunks(rest);
        } else if (is(word, &.{ "find", "search" })) {
            try self.writeNameMatches(rest);
        } else if (is(word, &.{ "chunk", "code" })) {
            const id = if (rest.len == 0)
                self.focused_chunk orelse return self.fail("chunk needs an ID when there is no VM focus", .{})
            else
                parseId(rest) orelse return self.fail("invalid chunk id `{s}`", .{rest});
            try self.writeChunk(id);
        } else if (is(word, &.{"spans"})) {
            try self.writeSpans(rest);
        } else if (is(word, &.{"heap"})) {
            if (rest.len != 0) return self.fail("heap takes no arguments", .{});
            try self.writeHeap();
        } else if (is(word, &.{"objects"})) {
            try self.writeStoreList(.objects, rest);
        } else if (is(word, &.{"object"})) {
            try self.writeObject(rest);
        } else if (is(word, &.{"store"})) {
            try self.writeStoreCommand(rest);
        } else if (is(word, &.{"record"})) {
            try self.writeRecordCommand(rest);
        } else if (is(word, &.{ "refs", "references" })) {
            try self.writeReferencesCommand(rest);
        } else if (is(word, &.{ "break-at", "break" })) {
            try self.setInstructionBreakpoint(rest);
        } else if (is(word, &.{ "clear-at", "unbreak" })) {
            try self.clearInstructionBreakpoint(rest);
        } else if (is(word, &.{"breakpoints"})) {
            if (rest.len != 0) return self.fail("breakpoints takes no arguments", .{});
            try self.writeBreakpoints();
        } else if (is(word, &.{"delete"})) {
            try self.deleteBreakpoint(rest);
        } else {
            return false;
        }
        return true;
    }

    fn writeHelp(self: *Context) !void {
        try self.writer.writeAll(
            \\VM text queries
            \\  chunk ID                     disassemble a chunk, with peers and references
            \\  spans [ID] [START] [LIMIT]   list source subexpressions and code offsets
            \\  ls [@NAME] [LIMIT]           list one bounded name-tree level
            \\  chunks [@NAME] [LIMIT]       list chunks attached to a name
            \\  find TEXT [LIMIT]            search bytecode names
            \\  heap                         print store and object-state counts
            \\  objects [START] [LIMIT]      page through live object ids
            \\  object ID [LIMIT]            inspect an object, members, and references
            \\  store NAME [START] [LIMIT]   page values, attrs, attr-positions,
            \\                               intern, builtin, or objects
            \\  record NAME ID               inspect one store record
            \\  refs (chunk|object) ID [LIMIT]
            \\                               list incoming and outgoing references
            \\  break-at CHUNK OFFSET        set an instruction/source-span breakpoint
            \\  clear-at CHUNK OFFSET        clear that breakpoint
            \\  breakpoints / delete N       list or remove breakpoint requests
            \\Listings default to 40 rows and are capped at 1000.
            \\
        );
    }

    pub fn writeChunk(self: *Context, id: ChunkId) !void {
        const chunk = self.ev.getChunk(id) orelse return self.fail("chunk[0x{x}] not found", .{id});
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const symbols: disasm.Symbols = .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() };
        try disasm.writeChunk(arena.allocator(), self.writer, id, chunk, symbols, .{
            .show_constants = true,
            .show_source = true,
            .show_bytes = true,
            .recurse = false,
            .color_depth = self.color_depth,
        });

        const equivalence = try self.cache.equivalenceIndex(self.allocator, self.ev);
        if (equivalence.structuralPeer(id)) |peer| {
            try self.writer.print("identical: chunk[0x{x}]\n", .{peer});
        } else if (equivalence.codePeer(id)) |peer| {
            try self.writer.print("same code: chunk[0x{x}] (tables/source differ)\n", .{peer});
        }
        // Match the TUI's immediately available page: direct outgoing chunk
        // and constant refs are cheap, while the whole heap/chunk graph remains
        // an explicit `refs` query in text mode.
        try self.writeDirectChunkReferences(chunk, default_limit);
    }

    fn writeHeap(self: *Context) !void {
        const stats = self.ev.heapStats();
        const counts = self.ev.heapCounts();
        try self.writer.print(
            "heap: {d} object slots, {d} value slots, {d} attr slots, {d} attr-position slots, {d} interns, {d} builtins\n",
            .{
                counts.objects,
                counts.values,
                counts.attrs,
                counts.attr_positions,
                self.ev.internTable().stats().entries,
                @typeInfo(runtime.builtins.BuiltinId).@"enum".field_names.len,
            },
        );
        try self.writer.writeAll("  object variants\n");
        for (stats.variant_counts, 0..) |count, i|
            try self.writer.print("    {s:<18} {d:>12}\n", .{ runtime.ObjectHeap.Stats.variantName(i), count });
        try self.writer.writeAll("  thunk states\n");
        for (stats.thunk_states, 0..) |count, i|
            try self.writer.print("    {s:<18} {d:>12}\n", .{ runtime.ObjectHeap.Stats.thunkStateName(i), count });
        try self.writer.print(
            "    resolved demanded   {d:>12}\n    resolved undemanded {d:>12}\n",
            .{ stats.resolved_demanded, stats.resolved_undemanded },
        );
    }

    fn writeStoreCommand(self: *Context, rest: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, rest, " \t");
        const name = tokens.next() orelse return self.fail("store needs NAME [START] [LIMIT]", .{});
        const store = parseStore(name) orelse return self.fail("unknown store `{s}`", .{name});
        const tail = std.mem.trimStart(u8, rest[name.len..], " \t");
        try self.writeStoreList(store, tail);
    }

    fn writeRecordCommand(self: *Context, rest: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, rest, " \t");
        const name = tokens.next() orelse return self.fail("record needs NAME ID", .{});
        const store = parseStore(name) orelse return self.fail("unknown store `{s}`", .{name});
        const id_text = tokens.next() orelse return self.fail("record needs NAME ID", .{});
        if (tokens.next() != null) return self.fail("record takes exactly NAME and ID", .{});
        const id = parseId(id_text) orelse return self.fail("invalid record id `{s}`", .{id_text});
        if (store == .objects) return self.writeObjectId(id, member_limit);
        try self.writeStoreRecord(store, id);
    }

    fn writeStoreList(self: *Context, store: Store, args: []const u8) !void {
        const range = try self.parseRange(args);
        if (range == null) return;
        const start = range.?.start;
        const limit = range.?.limit;
        const count = self.storeCount(store);
        try self.writer.print("{s}[0x0:0x{x}]\n", .{ storeName(store), count });

        if (store == .intern or store == .builtin) {
            const end = @min(@as(usize, count), @as(usize, start) + limit);
            var id: u32 = start;
            while (id < end) : (id += 1) {
                try self.writer.writeAll("  ");
                try self.writeStoreRecordInline(store, id);
                try self.writer.writeByte('\n');
            }
            if (start >= count) try self.writer.writeAll("  (no records at or after that id)\n");
            if (end < count) try self.writer.print("continue with `store {s} {d} {d}`\n", .{ storeName(store), end, limit });
            return;
        }

        const snapshot = try self.cache.storeSnapshot(self.allocator, self.ev, store);
        var next = snapshot.nextLive(start);
        var shown: usize = 0;
        var continuation: ?u32 = null;
        while (next) |id| {
            if (shown >= limit) {
                continuation = id;
                break;
            }
            try self.writer.writeAll("  ");
            try self.writeStoreRecordInline(store, id);
            try self.writer.writeByte('\n');
            shown += 1;
            next = snapshot.nextLive(id + 1);
        }
        if (shown == 0) try self.writer.writeAll("  (no live records at or after that id)\n");
        if (continuation) |id|
            try self.writer.print("continue with `store {s} {d} {d}`\n", .{ storeName(store), id, limit });
    }

    fn writeStoreRecordInline(self: *Context, store: Store, id: u32) !void {
        const symbols: disasm.Symbols = .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() };
        switch (store) {
            .objects => {
                const snapshot = try self.cache.objectSnapshot(self.allocator, self.ev);
                const info = self.ev.inspectHeapObject(snapshot, id) catch return self.writer.print("objects[0x{x}] (not live)", .{id});
                try disasm.writeStoreRef(self.writer, "objects", id, .object, objectInfoLabel(info), self.color_depth);
            },
            .values => {
                try disasm.writeStoreRef(self.writer, "values", id, .value, null, self.color_depth);
                if (self.ev.heapValueAt(id)) |value| {
                    try self.writer.writeAll(" = ");
                    try disasm.writeValueDigest(self.writer, value.*, symbols, 48, self.color_depth);
                }
            },
            .attrs => {
                try disasm.writeStoreRef(self.writer, "attrs", id, .attr, null, self.color_depth);
                if (self.ev.heapAttrAt(id)) |attr| {
                    try self.writer.print(" {s} = ", .{self.ev.internTable().get(attr.name)});
                    try disasm.writeValueDigest(self.writer, attr.value, symbols, 48, self.color_depth);
                }
            },
            .attr_positions => {
                try disasm.writeStoreRef(self.writer, "attr_positions", id, .attr_position, null, self.color_depth);
                if (self.ev.heapAttrPosAt(id)) |position|
                    try self.writer.print(" {s} at {s}:{d}:{d}", .{
                        self.ev.internTable().get(position.name),
                        self.ev.internTable().get(position.pos.file),
                        position.pos.line,
                        position.pos.column,
                    });
            },
            .intern => try disasm.writeStoreRef(
                self.writer,
                "intern",
                id,
                .intern,
                if (id < self.storeCount(.intern)) self.ev.internTable().get(id) else null,
                self.color_depth,
            ),
            .builtin => try disasm.writeStoreRef(
                self.writer,
                "builtin",
                id,
                .builtin,
                disasm.builtinName(id),
                self.color_depth,
            ),
        }
    }

    fn writeStoreRecord(self: *Context, store: Store, id: u32) !void {
        if (id >= self.storeCount(store)) return self.fail("{s}[0x{x}] is out of range", .{ storeName(store), id });
        if (store != .intern and store != .builtin) {
            const snapshot = try self.cache.storeSnapshot(self.allocator, self.ev, store);
            if (!snapshot.isLive(id)) return self.fail("{s}[0x{x}] is not live", .{ storeName(store), id });
        }
        try self.writeStoreRecordInline(store, id);
        try self.writer.writeByte('\n');
        if (store == .values) if (self.ev.heapValueAt(id)) |value| try self.writeValueReference("target", value.*);
        if (store == .attrs) if (self.ev.heapAttrAt(id)) |attr| try self.writeValueReference("target", attr.value);
    }

    fn writeObject(self: *Context, args: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, args, " \t");
        const id_text = tokens.next() orelse return self.fail("object needs ID [LIMIT]", .{});
        const id = parseId(id_text) orelse return self.fail("invalid object id `{s}`", .{id_text});
        const limit = if (tokens.next()) |n| try self.parseLimit(n) else default_limit;
        if (tokens.next() != null) return self.fail("object takes ID [LIMIT]", .{});
        try self.writeObjectId(id, limit);
    }

    fn writeObjectId(self: *Context, id: ObjectId, limit: usize) !void {
        const snapshot = try self.cache.objectSnapshot(self.allocator, self.ev);
        const info = self.ev.inspectHeapObject(snapshot, id) catch
            return self.fail("objects[0x{x}] is not live", .{id});
        try disasm.writeStoreRef(self.writer, "objects", id, .object, objectInfoLabel(info), self.color_depth);
        try self.writer.writeByte('\n');
        switch (info) {
            .list => {
                const items = self.ev.heapListOf(id) catch &.{};
                try self.writer.print("  ITEMS · {d}\n", .{items.len});
                for (items[0..@min(items.len, limit)], 0..) |value, i| {
                    try self.writer.print("    [{d}] ", .{i});
                    try self.writeValueDigest(value);
                    try self.writer.writeByte('\n');
                }
                if (items.len > limit) try self.writer.print("    ... {d} more\n", .{items.len - limit});
            },
            .attrs => |attrs_info| {
                try self.writer.print("  positions: {d}; sibling swept: {s}\n", .{
                    attrs_info.positions,
                    if (attrs_info.sibling_swept) "yes" else "no",
                });
                const attrs = self.ev.heapAttrsOf(id) catch runtime.heap.AttrsView{ .names = &.{}, .values = &.{} };
                try self.writer.print("  MEMBERS · {d}\n", .{attrs.len()});
                const shown = @min(attrs.len(), limit);
                for (attrs.names[0..shown], attrs.values[0..shown]) |attr_name, attr_value| {
                    try self.writer.print("    {s} = ", .{self.ev.internTable().get(attr_name)});
                    try self.writeValueDigest(attr_value);
                    try self.writer.writeByte('\n');
                }
                if (attrs.len() > limit) try self.writer.print("    ... {d} more\n", .{attrs.len() - limit});
            },
            .merge_attrs => |merge| {
                try self.writeObjectField("base", merge.base);
                try self.writeObjectField("overlay", merge.overlay);
                try self.writer.print("  depth: {d}\n", .{merge.depth});
                if (merge.flattened) |flat| try self.writeObjectField("flattened", flat);
            },
            .closure => |closure| {
                try self.writer.writeAll("  chunk: ");
                try disasm.writeStoreRef(self.writer, "chunk", closure.chunk, .chunk, null, self.color_depth);
                try self.writer.print("\n  upvalues: {d}\n", .{closure.upvalues});
            },
            .builtin_closure => |closure| {
                try self.writer.writeAll("  builtin: ");
                try disasm.writeStoreRef(self.writer, "builtin", closure.builtin, .builtin, disasm.builtinName(closure.builtin), self.color_depth);
                try self.writer.print("\n  arguments: {d}\n", .{closure.args});
            },
            .thunk => |thunk| {
                try self.writer.print("  state: {s}\n  demanded: {s}\n", .{ @tagName(thunk.state), if (thunk.demanded) "yes" else "no" });
                switch (thunk.body) {
                    .result => |value| try self.writeHeapValueRef("result", value),
                    .error_name => |name| try self.writer.print("  error: {s}\n", .{name}),
                    .target => |target| switch (target) {
                        .closure => |value| try self.writeHeapValueRef("closure", value),
                        .bytecode => |body| {
                            try self.writer.writeAll("  chunk: ");
                            try disasm.writeStoreRef(self.writer, "chunk", body.chunk, .chunk, null, self.color_depth);
                            try self.writer.print("\n  captures: {d}\n", .{body.captures});
                        },
                        .pass_through => |value| try self.writeHeapValueRef("value", value),
                        .attr_access => |access| {
                            try self.writeHeapValueRef("base", access.base);
                            try self.writer.print("  attribute: intern[0x{x}] {s}\n", .{
                                access.name,
                                self.ev.internTable().get(access.name),
                            });
                        },
                        .deferred => |body| try self.writer.print("  deferred: 0x{x}\n  captures: {d}\n", .{ body.id, body.captures }),
                    },
                }
            },
            .context_string => |string| try self.writer.print(
                "  text: intern[0x{x}] {s}\n  context entries: {d}\n",
                .{ string.text, self.ev.internTable().get(string.text), string.context },
            ),
            .boxed_int => |value| try self.writer.print("  value: {d}\n", .{value}),
            .partial_app => |partial| {
                try self.writeHeapValueRef("function", partial.function);
                try self.writer.print("  arguments: {d}\n", .{partial.args});
            },
            .heap_string => |string| try self.writer.print("  bytes: {d}\n", .{string.len}),
        }
        try self.writeReferences(.{ .object = id }, limit);
    }

    fn writeSpans(self: *Context, args: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, args, " \t");
        const id: ChunkId = if (tokens.next()) |first|
            parseId(first) orelse return self.fail("invalid chunk id `{s}`", .{first})
        else
            self.focused_chunk orelse return self.fail("spans needs a chunk ID when there is no VM focus", .{});
        const start = if (tokens.next()) |n| parseId(n) orelse return self.fail("invalid span start `{s}`", .{n}) else 0;
        const limit = if (tokens.next()) |n| try self.parseLimit(n) else default_limit;
        if (tokens.next() != null) return self.fail("spans takes [ID] [START] [LIMIT]", .{});
        const chunk = self.ev.getChunk(id) orelse return self.fail("chunk[0x{x}] not found", .{id});
        try self.writer.print("SOURCE SPANS · chunk[0x{x}]\n", .{id});
        var unique: usize = 0;
        var shown: usize = 0;
        for (chunk.source_map, 0..) |entry, i| {
            var duplicate = false;
            for (chunk.source_map[0..i]) |previous| if (spanEql(previous.span, entry.span)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            defer unique += 1;
            if (unique < start or shown >= limit) continue;
            var first_offset = entry.start;
            for (chunk.source_map) |candidate| {
                if (spanEql(candidate.span, entry.span))
                    first_offset = @min(first_offset, candidate.start);
            }
            const file = if (entry.span.file) |file_id| self.ev.internTable().get(file_id) else "<repl>";
            const marked = self.ev.breakpointSpan(id, entry.span);
            try self.writer.print("  {s} [{d}] @0x{x} {s}:{d}:{d} bytes {d}+{d}\n", .{
                if (marked) "●" else " ",
                unique,
                first_offset,
                file,
                entry.span.line,
                entry.span.column,
                entry.span.offset,
                entry.span.len,
            });
            shown += 1;
        }
        if (unique == 0) try self.writer.writeAll("  (no source spans)\n");
        if (unique > start + shown)
            try self.writer.print("  ... {d} more; continue with `spans {d} {d} {d}`\n", .{ unique - start - shown, id, start + shown, limit });
    }

    fn writeReferencesCommand(self: *Context, args: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, args, " \t");
        const kind = tokens.next() orelse return self.fail("refs needs (chunk|object) ID [LIMIT]", .{});
        const id_text = tokens.next() orelse return self.fail("refs needs (chunk|object) ID [LIMIT]", .{});
        const id = parseId(id_text) orelse return self.fail("invalid reference id `{s}`", .{id_text});
        const limit = if (tokens.next()) |n| try self.parseLimit(n) else default_limit;
        if (tokens.next() != null) return self.fail("refs needs (chunk|object) ID [LIMIT]", .{});
        const subject: vm_refs.Node = if (is(kind, &.{"chunk"}))
            .{ .chunk = id }
        else if (is(kind, &.{"object"}))
            .{ .object = id }
        else
            return self.fail("reference kind must be `chunk` or `object`", .{});
        try self.writeReferences(subject, limit);
    }

    fn writeDirectChunkReferences(self: *Context, chunk: *const engine.bytecode.Chunk, limit: usize) !void {
        var chunk_refs: std.ArrayListUnmanaged(ChunkId) = .empty;
        defer chunk_refs.deinit(self.allocator);
        try engine.bytecode.inspect.collectRefs(self.allocator, chunk, &chunk_refs);

        var references: std.ArrayListUnmanaged(vm_refs.Node) = .empty;
        defer references.deinit(self.allocator);
        for (chunk_refs.items) |id| try appendUniqueReference(&references, self.allocator, .{ .chunk = id });
        for (chunk.constants) |value| switch (self.ev.valueRef(value).target) {
            .object => |id| try appendUniqueReference(&references, self.allocator, .{ .object = id }),
            .chunk => |id| try appendUniqueReference(&references, self.allocator, .{ .chunk = id }),
            .none, .intern, .builtin => {},
        };

        try self.writer.print("OUTGOING · {d}\n", .{references.items.len});
        for (references.items[0..@min(references.items.len, limit)]) |reference| {
            try self.writer.writeAll("  ");
            try self.writeReference(reference);
            try self.writer.writeByte('\n');
        }
        if (references.items.len > limit)
            try self.writer.print("  ... {d} more\n", .{references.items.len - limit});
        try self.writer.writeAll("INCOMING · use `refs chunk ID [LIMIT]` for the whole graph\n");
    }

    fn writeReferences(self: *Context, subject: vm_refs.Node, limit: usize) !void {
        const graph = try self.cache.referenceGraph(self.allocator, self.ev);
        try self.writeReferenceList("OUTGOING", graph.outgoing(subject), limit);
        try self.writeReferenceList("INCOMING", graph.incoming(subject), limit);
    }

    fn writeReferenceList(self: *Context, heading: []const u8, edges: []const vm_refs.Edge, limit: usize) !void {
        try self.writer.print("{s} · {d}\n", .{ heading, edges.len });
        for (edges[0..@min(edges.len, limit)]) |edge| {
            try self.writer.writeAll("  ");
            try self.writeReference(vm_refs.node(edge.target));
            try self.writer.writeByte('\n');
        }
        if (edges.len > limit) try self.writer.print("  ... {d} more\n", .{edges.len - limit});
    }

    fn writeReference(self: *Context, reference: vm_refs.Node) !void {
        switch (reference) {
            .chunk => |id| {
                try self.writer.print("chunk[0x{x}]", .{id});
                if (self.ev.chunkRegistry().hasQualifiedName(id)) {
                    try self.writer.writeByte(' ');
                    try self.ev.chunkRegistry().writeQualifiedName(self.writer, id, self.ev.internTable());
                }
            },
            .object => |id| {
                const snapshot = try self.cache.objectSnapshot(self.allocator, self.ev);
                const label = if (self.ev.inspectHeapObject(snapshot, id)) |info| objectInfoLabel(info) else |_| null;
                try disasm.writeStoreRef(self.writer, "objects", id, .object, label, self.color_depth);
            },
        }
    }

    fn writeNameChildren(self: *Context, args: []const u8) !void {
        const range = try self.parseNameRange(args, .root);
        if (range == null) return;
        const query = range.?;
        const index = try self.cache.nameIndex(self.allocator, self.ev);
        if (index.node(query.name_id) == null) return self.fail("name @{d} not found", .{query.name_id});
        try self.writeNameHeader(index, query.name_id);
        var active: usize = 0;
        var shown: usize = 0;
        for (index.childrenOf(query.name_id)) |child| {
            const stats = index.statsOf(child);
            if (stats.chunks == 0) continue;
            active += 1;
            if (shown >= query.limit) continue;
            try self.writer.print("  @{d:<8} ", .{child});
            try self.writeNamePath(index, child);
            try self.writer.print("  {d} chunks  {Bi} code\n", .{ stats.chunks, stats.code_bytes });
            shown += 1;
        }
        if (active == 0) try self.writer.writeAll("  (no named children)\n");
        if (active > shown) try self.writer.print("  ... {d} more\n", .{active - shown});
    }

    fn writeNameChunks(self: *Context, args: []const u8) !void {
        const range = try self.parseNameRange(args, .focus);
        if (range == null) return;
        const query = range.?;
        const index = try self.cache.nameIndex(self.allocator, self.ev);
        if (index.node(query.name_id) == null) return self.fail("name @{d} not found", .{query.name_id});
        try self.writeNameHeader(index, query.name_id);
        const chunks = index.chunksOf(query.name_id);
        for (chunks[0..@min(chunks.len, query.limit)]) |id| {
            const chunk = self.ev.getChunk(id) orelse continue;
            try self.writer.print("  chunk[0x{x}]  {Bi} code  {d} constants  arity {d}\n", .{
                id,
                chunk.code.len,
                chunk.constants.len,
                chunk.arity,
            });
        }
        if (chunks.len == 0) try self.writer.writeAll("  (no directly attached chunks)\n");
        if (chunks.len > query.limit) try self.writer.print("  ... {d} more\n", .{chunks.len - query.limit});
    }

    fn writeNameMatches(self: *Context, args: []const u8) !void {
        var tokens = std.mem.tokenizeAny(u8, args, " \t");
        const needle = tokens.next() orelse return self.fail("find needs TEXT [LIMIT]", .{});
        const limit = if (tokens.next()) |n| try self.parseLimit(n) else default_limit;
        if (tokens.next() != null) return self.fail("find takes TEXT [LIMIT]", .{});
        const index = try self.cache.nameIndex(self.allocator, self.ev);
        var matches: usize = 0;
        var id: engine.bytecode.NameId = 1;
        while (id <= index.name_count) : (id += 1) {
            const node = index.node(id) orelse continue;
            const label = self.ev.internTable().get(node.segment);
            if (!asciiContainsIgnoreCase(label, needle)) continue;
            matches += 1;
            if (matches > limit) continue;
            try self.writer.print("  @{d:<8} ", .{id});
            try self.writeNamePath(index, id);
            const stats = index.statsOf(id);
            try self.writer.print("  {d} chunks  {Bi} code\n", .{ stats.chunks, stats.code_bytes });
        }
        if (matches == 0) try self.writer.writeAll("  (no matching names)\n");
        if (matches > limit) try self.writer.print("  ... {d} more\n", .{matches - limit});
    }

    fn setInstructionBreakpoint(self: *Context, args: []const u8) !void {
        const target = try self.parseInstructionTarget(args) orelse return;
        const chunk = self.ev.getChunk(target.chunk) orelse return self.fail("chunk[0x{x}] not found", .{target.chunk});
        const span = engine.bytecode.inspect.bestSpan(chunk, target.offset);
        const result = if (span) |source_span|
            try self.ev.setBreakpointSpan(target.chunk, source_span)
        else
            try self.ev.setBreakpointAt(target.chunk, target.offset);
        try self.writer.print("breakpoint {d} at chunk[0x{x}] @0x{x} — {d} site(s)\n", .{
            result.id,
            target.chunk,
            target.offset,
            result.sites,
        });
    }

    fn clearInstructionBreakpoint(self: *Context, args: []const u8) !void {
        const target = try self.parseInstructionTarget(args) orelse return;
        const chunk = self.ev.getChunk(target.chunk) orelse return self.fail("chunk[0x{x}] not found", .{target.chunk});
        const cleared = if (engine.bytecode.inspect.bestSpan(chunk, target.offset)) |span|
            self.ev.deleteBreakpointSpan(target.chunk, span)
        else
            self.ev.deleteBreakpointAt(target.chunk, target.offset);
        try self.writer.print("{s} breakpoint at chunk[0x{x}] @0x{x}\n", .{
            if (cleared) "cleared" else "no",
            target.chunk,
            target.offset,
        });
    }

    fn writeBreakpoints(self: *Context) !void {
        const requests = self.ev.listBreakpoints();
        if (requests.len == 0) return self.writer.writeAll("(no breakpoints)\n");
        for (requests) |bp| {
            if (bp.span) |span| {
                try self.writer.print("{d}  chunk[0x{x}] L{d}:{d} (source span)\n", .{
                    bp.id,
                    bp.span_chunk.?,
                    span.line,
                    span.column,
                });
            } else if (bp.site_only) {
                try self.writer.print("{d}  (per-instruction site)\n", .{bp.id});
            } else {
                try self.writer.print("{d}  {s}:{d}{s}\n", .{
                    bp.id,
                    bp.file,
                    bp.line,
                    if (bp.pending) " (pending)" else "",
                });
            }
        }
    }

    fn deleteBreakpoint(self: *Context, args: []const u8) !void {
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, args, " \t"), 10) catch
            return self.fail("delete needs a breakpoint number", .{});
        try self.writer.print("{s} breakpoint {d}\n", .{
            if (self.ev.deleteBreakpoint(id)) "deleted" else "no",
            id,
        });
    }

    const NameRange = struct { name_id: engine.bytecode.NameId, limit: usize };
    const DefaultName = enum { root, focus };

    fn parseNameRange(self: *Context, args: []const u8, default: DefaultName) !?NameRange {
        var name_id = switch (default) {
            .root => engine.bytecode.root_name_id,
            .focus => if (self.focused_chunk) |id|
                self.ev.chunkRegistry().nameOf(id) orelse engine.bytecode.root_name_id
            else
                engine.bytecode.root_name_id,
        };
        var limit = default_limit;
        var tokens = std.mem.tokenizeAny(u8, args, " \t");
        if (tokens.next()) |first| {
            if (first.len > 1 and first[0] == '@') {
                name_id = std.fmt.parseInt(engine.bytecode.NameId, first[1..], 10) catch
                    return self.fail("invalid name id `{s}`", .{first});
                if (tokens.next()) |n| limit = try self.parseLimit(n);
            } else {
                limit = try self.parseLimit(first);
            }
        }
        if (tokens.next() != null) return self.fail("too many name query arguments", .{});
        return .{ .name_id = name_id, .limit = limit };
    }

    const Range = struct { start: u32, limit: usize };

    fn parseRange(self: *Context, args: []const u8) !?Range {
        var start: u32 = 0;
        var limit = default_limit;
        var tokens = std.mem.tokenizeAny(u8, args, " \t");
        if (tokens.next()) |first| {
            start = parseId(first) orelse return self.fail("invalid start id `{s}`", .{first});
            if (tokens.next()) |n| limit = try self.parseLimit(n);
        }
        if (tokens.next() != null) return self.fail("listing takes at most START and LIMIT", .{});
        return .{ .start = start, .limit = limit };
    }

    fn parseLimit(self: *Context, text: []const u8) !usize {
        const limit = std.fmt.parseInt(usize, text, 10) catch
            return self.fail("invalid row limit `{s}`", .{text});
        if (limit == 0 or limit > maximum_limit)
            return self.fail("row limit must be between 1 and {d}", .{maximum_limit});
        return limit;
    }

    const InstructionTarget = struct { chunk: ChunkId, offset: u32 };

    fn parseInstructionTarget(self: *Context, args: []const u8) !?InstructionTarget {
        var tokens = std.mem.tokenizeAny(u8, args, " \t:");
        const chunk_text = tokens.next() orelse return self.fail("instruction target needs CHUNK OFFSET", .{});
        const offset_text = tokens.next() orelse return self.fail("instruction target needs CHUNK OFFSET", .{});
        if (tokens.next() != null) return self.fail("instruction target takes CHUNK OFFSET", .{});
        const chunk = parseId(chunk_text) orelse return self.fail("invalid chunk id `{s}`", .{chunk_text});
        const offset = parseId(offset_text) orelse return self.fail("invalid instruction offset `{s}`", .{offset_text});
        return .{ .chunk = chunk, .offset = offset };
    }

    fn writeNameHeader(self: *Context, index: *const engine.bytecode.inspect.NameIndex, id: engine.bytecode.NameId) !void {
        try self.writer.print("@{d} ", .{id});
        try self.writeNamePath(index, id);
        const stats = index.statsOf(id);
        try self.writer.print(" — {d} chunks, {Bi} code, {d} constants\n", .{
            stats.chunks,
            stats.code_bytes,
            stats.constants,
        });
    }

    fn writeNamePath(self: *Context, index: *const engine.bytecode.inspect.NameIndex, id: engine.bytecode.NameId) !void {
        if (id == engine.bytecode.root_name_id) return self.writer.writeAll("<root>");
        var ancestors: std.ArrayListUnmanaged(engine.bytecode.NameId) = .empty;
        defer ancestors.deinit(self.allocator);
        var cursor = id;
        while (cursor != engine.bytecode.root_name_id) {
            try ancestors.append(self.allocator, cursor);
            cursor = (index.node(cursor) orelse break).parent;
        }
        var i = ancestors.items.len;
        while (i > 0) {
            i -= 1;
            const node = index.node(ancestors.items[i]) orelse continue;
            if (i != ancestors.items.len - 1) try self.writer.writeAll(if (node.synthetic) "·" else ".");
            try self.writer.writeAll(self.ev.internTable().get(node.segment));
        }
    }

    fn storeCount(self: *Context, store: Store) u32 {
        const counts = self.ev.heapCounts();
        return switch (store) {
            .objects => counts.objects,
            .values => counts.values,
            .attrs => counts.attrs,
            .attr_positions => counts.attr_positions,
            .intern => self.ev.internTable().stats().entries,
            .builtin => @intCast(@typeInfo(runtime.builtins.BuiltinId).@"enum".field_names.len),
        };
    }

    fn writeObjectField(self: *Context, label: []const u8, id: ObjectId) !void {
        try self.writer.print("  {s}: ", .{label});
        const snapshot = try self.cache.objectSnapshot(self.allocator, self.ev);
        const preview = if (self.ev.inspectHeapObject(snapshot, id)) |info| objectInfoLabel(info) else |_| null;
        try disasm.writeStoreRef(self.writer, "objects", id, .object, preview, self.color_depth);
        try self.writer.writeByte('\n');
    }

    fn writeValueDigest(self: *Context, value: runtime.Value) !void {
        try disasm.writeValueDigest(
            self.writer,
            value,
            .{ .intern = self.ev.internTable(), .registry = self.ev.chunkRegistry() },
            64,
            self.color_depth,
        );
    }

    fn writeValueReference(self: *Context, label: []const u8, value: runtime.Value) !void {
        const reference = self.ev.valueRef(value);
        if (reference.target == .none) return;
        try self.writer.print("  {s}: ", .{label});
        try self.writeHeapValueRefBody(reference);
        try self.writer.writeByte('\n');
    }

    fn writeHeapValueRef(self: *Context, label: []const u8, value: runtime.heap.ValueRef) !void {
        try self.writer.print("  {s}: ", .{label});
        try self.writeHeapValueRefBody(value);
        try self.writer.writeByte('\n');
    }

    fn writeHeapValueRefBody(self: *Context, value: runtime.heap.ValueRef) !void {
        switch (value.target) {
            .none => try self.writer.writeAll(disasm.valueKindLabel(value.kind)),
            .object => |id| try disasm.writeStoreRef(self.writer, "objects", id, .object, disasm.valueKindLabel(value.kind), self.color_depth),
            .chunk => |id| try disasm.writeStoreRef(self.writer, "chunk", id, .chunk, disasm.valueKindLabel(value.kind), self.color_depth),
            .intern => |id| try disasm.writeStoreRef(self.writer, "intern", id, .intern, disasm.valueKindLabel(value.kind), self.color_depth),
            .builtin => |id| try disasm.writeStoreRef(self.writer, "builtin", id, .builtin, disasm.builtinName(id), self.color_depth),
        }
    }

    fn fail(self: *Context, comptime fmt: []const u8, args: anytype) error{InvalidVmQuery} {
        self.writer.print("error: " ++ fmt ++ "\n", args) catch {};
        return error.InvalidVmQuery;
    }
};

pub fn parseId(raw: []const u8) ?u32 {
    var text = std.mem.trim(u8, raw, " \t");
    if (text.len == 0) return null;
    if (text[0] == '#') text = text[1..];
    const prefixes = [_][]const u8{ "chunk[", "objects[", "values[", "attrs[", "attr_positions[", "intern[", "builtin[" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, text, prefix) and text[text.len - 1] == ']') {
        text = text[prefix.len .. text.len - 1];
        break;
    };
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X'))
        return std.fmt.parseInt(u32, text[2..], 16) catch null;
    return std.fmt.parseInt(u32, text, 10) catch null;
}

fn parseStore(text: []const u8) ?Store {
    if (is(text, &.{ "object", "objects" })) return .objects;
    if (is(text, &.{ "value", "values" })) return .values;
    if (is(text, &.{ "attr", "attrs" })) return .attrs;
    if (is(text, &.{ "attr-position", "attr-positions", "attr_position", "attr_positions", "positions" })) return .attr_positions;
    if (is(text, &.{ "intern", "interns" })) return .intern;
    if (is(text, &.{ "builtin", "builtins" })) return .builtin;
    return null;
}

fn storeName(store: Store) []const u8 {
    return switch (store) {
        .objects => "objects",
        .values => "values",
        .attrs => "attrs",
        .attr_positions => "attr-positions",
        .intern => "intern",
        .builtin => "builtin",
    };
}

fn objectInfoLabel(info: runtime.heap.ObjectInfo) []const u8 {
    return switch (info) {
        .list => "list",
        .attrs => "attrs",
        .merge_attrs => "merge_attrs",
        .closure => "closure",
        .builtin_closure => "builtin_closure",
        .thunk => "thunk",
        .context_string => "context_string",
        .boxed_int => "boxed_int",
        .partial_app => "partial_app",
        .heap_string => "heap_string",
    };
}

fn splitWord(text: []const u8) struct { []const u8, []const u8 } {
    const end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    return .{ text[0..end], std.mem.trim(u8, text[end..], " \t") };
}

fn is(word: []const u8, aliases: []const []const u8) bool {
    for (aliases) |alias| if (std.mem.eql(u8, word, alias)) return true;
    return false;
}

fn spanEql(a: engine.bytecode.Chunk.SourceSpan, b: engine.bytecode.Chunk.SourceSpan) bool {
    return a.file == b.file and a.offset == b.offset and a.len == b.len;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, 0..) |char, j|
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(char)) continue :outer;
        return true;
    }
    return false;
}

fn appendUniqueReference(
    references: *std.ArrayListUnmanaged(vm_refs.Node),
    allocator: std.mem.Allocator,
    candidate: vm_refs.Node,
) !void {
    for (references.items) |existing|
        if (vm_refs.key(existing) == vm_refs.key(candidate)) return;
    try references.append(allocator, candidate);
}

test "plain VM ids accept canonical explorer references" {
    try std.testing.expectEqual(@as(?u32, 42), parseId("42"));
    try std.testing.expectEqual(@as(?u32, 42), parseId("#0x2a"));
    try std.testing.expectEqual(@as(?u32, 42), parseId("#0X2a"));
    try std.testing.expectEqual(@as(?u32, 42), parseId("chunk[0x2a]"));
    try std.testing.expectEqual(@as(?u32, 42), parseId("objects[0x2a]"));
    try std.testing.expect(parseId("nope") == null);
}
