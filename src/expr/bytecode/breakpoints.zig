//! Source-line, exact-source-span, and instruction breakpoints through mutable
//! execution overlays.
//!
//! Registry chunks are immutable and participate in structural deduplication,
//! so debugger state never modifies `Chunk.code`. The first trap in a chunk
//! creates a private code copy in `overlays`; breakpoint operations patch that
//! copy while the VM selects it only at frame entry/resume. Execution then hits
//! the `breakpoint` handler, which pauses and chains to the canonical opcode
//! (operands are untouched). This needs no check in the hot dispatch loop.
//!
//! Instruction boundaries come from the chunk's `source_map`: each entry keys a
//! `SourceSpan` by the code offset where that construct's first instruction was
//! emitted, so `entry.start` is always a safe patch point.
//!
//! Because bodies compile lazily (imports, deferred attrs register
//! mid-evaluation), the evaluator explicitly reports each canonical
//! registration so pending breakpoints land in its overlay too.

const std = @import("std");
const types = @import("runtime").types;
const Value = @import("runtime").value.Value;
const InternTable = @import("runtime").intern.InternTable;
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const ChunkRegistry = chunk_mod.ChunkRegistry;
const opcode = @import("opcode.zig");
const name_tree = @import("name_tree.zig");

const ChunkId = types.ChunkId;
const InternId = types.InternId;

const breakpoint_byte: u8 = @intFromEnum(opcode.OpCode.breakpoint);

pub const BreakpointTable = struct {
    gpa: std.mem.Allocator,
    intern: *const InternTable,
    requests: std.ArrayListUnmanaged(Request) = .empty,
    placements: std.ArrayListUnmanaged(Placement) = .empty,
    /// Mutable debugger-owned bytecode copies, created only for chunks with a
    /// trap. Slices stay at stable addresses even if the map itself grows.
    overlays: std.AutoHashMapUnmanaged(ChunkId, []u8) = .empty,
    next_id: u32 = 1,
    /// Temporary trap placements for the in-progress step (cleared on pause).
    step_temps: std.ArrayListUnmanaged(Placement) = .empty,
    /// A step stops only when the frame depth is ≤ this (so a step-over doesn't
    /// stop inside a deeper recursion of the same chunk). `maxInt` = any depth.
    step_max_depth: u32 = 0,
    /// `step into` must also follow code which does not exist yet when the
    /// command is issued (an import or deferred body compiled on demand).
    /// `placeRegisteredChunk` traps those entry points before they can run.
    step_follow_new_chunks: bool = false,
    step_armed: bool = false,
    step_hit_kind: HitKind = .step,

    /// `req_id` sentinel marking a step temp rather than a user breakpoint.
    pub const step_request_id: u32 = 0;

    /// A candidate step-stop location.
    pub const Site = struct { chunk_id: ChunkId, offset: u32 };

    /// What the `breakpoint` handler should do at an overlay trap site.
    pub const HitKind = enum { none, breakpoint, step, entry };
    pub const Hit = struct { original: u8, pause: bool, kind: HitKind };

    /// A user request: "break on FILE:LINE". `line` is the resolved line (the
    /// nearest line at/after the requested one that carries code).
    pub const Request = struct {
        id: u32,
        file: []u8,
        requested_line: u32,
        line: u32,
        pending: bool,
        /// A per-instruction breakpoint pinned to one `(chunk_id, offset)` site
        /// rather than a FILE:LINE. Not re-placeable by line, so lazy chunk
        /// registration and pending-file resolution skip it.
        site_only: bool = false,
        /// An exact source-span request. The chunk id keeps equal source
        /// coordinates in separately compiled bodies independent.
        span_chunk: ?ChunkId = null,
        span: ?Chunk.SourceSpan = null,
    };

    /// A trap site realizing a request in a specific chunk. The original
    /// opcode remains authoritative in the immutable registry chunk.
    pub const Placement = struct {
        req_id: u32,
        chunk_id: ChunkId,
        offset: u32,
    };

    pub const SetResult = struct {
        id: u32,
        /// Resolved line (may differ from the requested one).
        line: u32,
        /// How many sites were trapped at set time (more may appear lazily).
        sites: usize,
        pending: bool,
    };

    pub fn init(gpa: std.mem.Allocator, intern: *const InternTable) BreakpointTable {
        return .{ .gpa = gpa, .intern = intern };
    }

    pub fn deinit(self: *BreakpointTable) void {
        for (self.requests.items) |r| self.gpa.free(r.file);
        self.requests.deinit(self.gpa);
        self.placements.deinit(self.gpa);
        self.step_temps.deinit(self.gpa);
        var overlays = self.overlays.valueIterator();
        while (overlays.next()) |code| self.gpa.free(code.*);
        self.overlays.deinit(self.gpa);
    }

    /// Bytecode to execute for `chunk_id`. Chunks without debugger traps use
    /// the canonical allocation directly; trap-bearing chunks use their stable
    /// mutable overlay. Called only when dispatch enters or resumes a frame.
    pub fn executableCode(self: *const BreakpointTable, chunk_id: ChunkId, chunk: *const Chunk) []const u8 {
        return self.overlays.get(chunk_id) orelse chunk.code;
    }

    /// Apply pending breakpoint requests to one explicitly reported new chunk.
    /// The evaluator calls this after registration; the registry has no hidden
    /// debugger mutation hook.
    pub fn placeRegisteredChunk(self: *BreakpointTable, chunk_id: ChunkId, chunk: *const Chunk) void {
        for (self.requests.items) |req| {
            if (req.site_only) continue;
            if (!req.pending) self.placeRequestInChunk(req, chunk_id, chunk) catch {};
        }
        if (self.step_armed and self.step_follow_new_chunks) {
            const offset = firstMappedOffset(chunk) orelse return;
            self.placeStepSite(chunk_id, offset, chunk) catch {};
        }
    }

    /// Set a breakpoint at FILE:LINE. Resolves LINE to the nearest line ≥ LINE
    /// in an already compiled file, or retains a pending request until the file
    /// compiles. Patches all matching registered chunks now and any that appear
    /// later.
    pub fn set(self: *BreakpointTable, registry: *ChunkRegistry, file: []const u8, line: u32) !SetResult {
        const resolved = self.nearestLine(registry, file, line);
        try self.requests.ensureUnusedCapacity(self.gpa, 1);
        if (resolved != null)
            try self.placements.ensureUnusedCapacity(self.gpa, @intCast(registry.count()));
        const owned_file = try self.gpa.dupe(u8, file);
        errdefer self.gpa.free(owned_file);

        const id = self.next_id;
        const req: Request = .{
            .id = id,
            .file = owned_file,
            .requested_line = line,
            .line = resolved orelse line,
            .pending = resolved == null,
        };
        // Overlay allocation is the last fallible phase. Keep the request and
        // placement lists unchanged until every matching chunk is prepared.
        if (!req.pending) {
            var cid: ChunkId = 0;
            const n = registry.count();
            while (cid < n) : (cid += 1) {
                const chunk = registry.get(cid) orelse continue;
                const offset = self.requestSiteInChunk(req, chunk) orelse continue;
                if (self.canPlaceSite(cid, offset, chunk)) _ = try self.ensureOverlay(cid, chunk);
            }
        }

        self.next_id += 1;
        self.requests.appendAssumeCapacity(req);

        const before = self.placements.items.len;
        if (!req.pending) {
            var cid: ChunkId = 0;
            const n = registry.count();
            while (cid < n) : (cid += 1) {
                const chunk = registry.get(cid) orelse continue;
                const offset = self.requestSiteInChunk(req, chunk) orelse continue;
                if (self.canPlaceSite(cid, offset, chunk)) self.commitSite(req.id, cid, offset);
            }
        }
        return .{
            .id = id,
            .line = req.line,
            .sites = self.placements.items.len - before,
            .pending = req.pending,
        };
    }

    /// Resolve requests for a source file once its top-level compilation unit
    /// is complete. This lets `break FILE:LINE` be set before an import exists
    /// without guessing the nearest executable line from a partially
    /// registered set of child chunks.
    pub fn resolvePendingFile(self: *BreakpointTable, registry: *ChunkRegistry, compiled_file: []const u8) void {
        for (self.requests.items) |*req| {
            if (!req.pending or !textFileMatches(req.file, compiled_file)) continue;
            const resolved = self.nearestLine(registry, compiled_file, req.requested_line) orelse continue;
            req.line = resolved;
            req.pending = false;
            var cid: ChunkId = 0;
            const n = registry.count();
            while (cid < n) : (cid += 1) {
                if (registry.get(cid)) |chunk| self.placeRequestInChunk(req.*, cid, chunk) catch {};
            }
        }
    }

    /// Remove a breakpoint by id, restoring its overlay sites from canonical
    /// bytecode. Returns true if the id existed.
    pub fn remove(self: *BreakpointTable, registry: *ChunkRegistry, id: u32) bool {
        var found = false;
        var i: usize = 0;
        while (i < self.placements.items.len) {
            const p = self.placements.items[i];
            if (p.req_id == id) {
                self.restoreOverlaySite(registry, p);
                _ = self.placements.swapRemove(i);
                found = true;
                continue;
            }
            i += 1;
        }
        var j: usize = 0;
        while (j < self.requests.items.len) : (j += 1) {
            if (self.requests.items[j].id == id) {
                self.gpa.free(self.requests.items[j].file);
                _ = self.requests.orderedRemove(j);
                found = true;
                break;
            }
        }
        return found;
    }

    /// Set a per-instruction breakpoint at an exact `(chunk_id, offset)` site.
    /// Unlike `set`, this does not resolve or track a source line: it traps
    /// the one instruction the caller selected. Source rows use `setSpan`
    /// because several nested spans may share an entry offset.
    pub fn setAt(self: *BreakpointTable, registry: *ChunkRegistry, chunk_id: ChunkId, offset: u32) !SetResult {
        try self.requests.ensureUnusedCapacity(self.gpa, 1);
        try self.placements.ensureUnusedCapacity(self.gpa, 1);
        const owned_file = try self.gpa.dupe(u8, "");
        errdefer self.gpa.free(owned_file);
        const chunk = registry.get(chunk_id);
        const place = if (chunk) |c| self.canPlaceSite(chunk_id, offset, c) else false;
        if (place) _ = try self.ensureOverlay(chunk_id, chunk.?);

        const id = self.next_id;
        self.next_id += 1;
        self.requests.appendAssumeCapacity(.{
            .id = id,
            .file = owned_file,
            .requested_line = 0,
            .line = 0,
            .pending = false,
            .site_only = true,
        });
        const before = self.placements.items.len;
        if (place) self.commitSite(id, chunk_id, offset);
        return .{
            .id = id,
            .line = 0,
            .sites = self.placements.items.len - before,
            .pending = false,
        };
    }

    /// Set a breakpoint on one exact source-map span. Nested spans commonly
    /// share their first bytecode offset, so using the map entry's raw `start`
    /// would collapse them into a line-like breakpoint. Instead, resolve to the
    /// first instruction whose *tightest* source mapping is this exact span.
    /// If compiler lowering gave the span no distinct execution site, return
    /// zero sites rather than silently broadening it.
    pub fn setSpan(
        self: *BreakpointTable,
        registry: *ChunkRegistry,
        chunk_id: ChunkId,
        span: Chunk.SourceSpan,
    ) !SetResult {
        const chunk = registry.get(chunk_id) orelse return .{
            .id = 0,
            .line = span.line,
            .sites = 0,
            .pending = false,
        };
        const offset = self.firstExactSpanSite(chunk_id, chunk, span) orelse return .{
            .id = 0,
            .line = span.line,
            .sites = 0,
            .pending = false,
        };
        if (!self.canPlaceSite(chunk_id, offset, chunk)) return .{
            .id = 0,
            .line = span.line,
            .sites = 0,
            .pending = false,
        };

        try self.requests.ensureUnusedCapacity(self.gpa, 1);
        try self.placements.ensureUnusedCapacity(self.gpa, 1);
        const owned_file = try self.gpa.dupe(u8, "");
        errdefer self.gpa.free(owned_file);
        _ = try self.ensureOverlay(chunk_id, chunk);

        const id = self.next_id;
        self.next_id += 1;
        self.requests.appendAssumeCapacity(.{
            .id = id,
            .file = owned_file,
            .requested_line = span.line,
            .line = span.line,
            .pending = false,
            .site_only = true,
            .span_chunk = chunk_id,
            .span = span,
        });
        self.commitSite(id, chunk_id, offset);
        return .{
            .id = id,
            .line = span.line,
            .sites = 1,
            .pending = false,
        };
    }

    /// Remove whatever breakpoint owns the placement at `(chunk_id, offset)`,
    /// restoring the overlay byte. Returns true if a placement existed there.
    pub fn removeAt(self: *BreakpointTable, registry: *ChunkRegistry, chunk_id: ChunkId, offset: u32) bool {
        for (self.placements.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset) return self.remove(registry, p.req_id);
        }
        return false;
    }

    pub fn removeSpan(
        self: *BreakpointTable,
        registry: *ChunkRegistry,
        chunk_id: ChunkId,
        span: Chunk.SourceSpan,
    ) bool {
        for (self.requests.items) |request| {
            const requested = request.span orelse continue;
            if (request.span_chunk == chunk_id and sameSpan(requested, span))
                return self.remove(registry, request.id);
        }
        return false;
    }

    /// Whether a permanent breakpoint is currently placed at this exact site.
    pub fn hasSite(self: *const BreakpointTable, chunk_id: ChunkId, offset: u32) bool {
        return self.placedAt(chunk_id, offset);
    }

    pub fn hasSpan(self: *const BreakpointTable, chunk_id: ChunkId, span: Chunk.SourceSpan) bool {
        for (self.requests.items) |request| {
            const requested = request.span orelse continue;
            if (request.span_chunk == chunk_id and sameSpan(requested, span)) return true;
        }
        return false;
    }

    /// Decide what the `breakpoint` handler does at `(chunk_id, offset)`: the
    /// saved original opcode to chain to, and whether to pause. A permanent
    /// breakpoint always pauses; a step temp pauses only at the target depth.
    pub fn hit(self: *const BreakpointTable, chunk_id: ChunkId, chunk: *const Chunk, offset: u32, frames_len: u32) Hit {
        const original = if (offset < chunk.code.len)
            chunk.code[offset]
        else
            @intFromEnum(opcode.OpCode.halt);
        for (self.placements.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset)
                return .{ .original = original, .pause = true, .kind = .breakpoint };
        }
        for (self.step_temps.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset)
                return .{ .original = original, .pause = frames_len <= self.step_max_depth, .kind = self.step_hit_kind };
        }
        return .{ .original = @intFromEnum(opcode.OpCode.halt), .pause = false, .kind = .none };
    }

    /// A frame return is also a useful step boundary: the caller is live again
    /// and the VM has the result available for display. Entry traps and
    /// permanent breakpoints do not opt into these virtual stops.
    pub fn pausesAfterReturn(self: *const BreakpointTable, frame_depth: u32) bool {
        return self.step_armed and self.step_hit_kind == .step and frame_depth <= self.step_max_depth;
    }

    /// Add bytecode-level evaluation boundaries from one chunk. These fill the
    /// gaps inside broad source-map spans (notably a curried `foo x y z`): the
    /// debugger can stop before each force/call without putting probes in the
    /// normal evaluator. `skip` is the instruction at the current pause.
    pub fn appendEvaluationStepSites(
        self: *const BreakpointTable,
        allocator: std.mem.Allocator,
        chunk_id: ChunkId,
        chunk: *const Chunk,
        skip: ?u32,
        sites: *std.ArrayListUnmanaged(Site),
    ) !void {
        var start: usize = 0;
        while (start < chunk.code.len) {
            const op = self.instructionOpcode(chunk_id, chunk, @intCast(start)) orelse return;
            if (evaluationStepBoundary(op) and (skip == null or start != skip.?)) {
                try sites.append(allocator, .{ .chunk_id = chunk_id, .offset = @intCast(start) });
            }
            const next = instructionEnd(chunk, start) orelse return;
            if (next <= start) return;
            start = next;
        }
    }

    /// Arm a step: patch each site (unless a permanent breakpoint already sits
    /// there), and stop only at depth ≤ `max_depth`. Replaces any prior step.
    pub fn armStep(
        self: *BreakpointTable,
        registry: *ChunkRegistry,
        sites: []const Site,
        max_depth: u32,
        follow_new_chunks: bool,
    ) !void {
        // Preflight the only fallible mutation. After clearStep the placement
        // loop is allocation-free, so OOM cannot leave a half-armed step.
        try self.step_temps.ensureTotalCapacity(self.gpa, sites.len);
        for (sites) |site| {
            const chunk = registry.get(site.chunk_id) orelse continue;
            if (site.offset >= chunk.code.len) continue;
            if (self.instructionBoundaryAtOrAfter(site.chunk_id, chunk, site.offset) != site.offset) continue;
            if (self.placedAt(site.chunk_id, site.offset)) continue;
            _ = try self.ensureOverlay(site.chunk_id, chunk);
        }
        self.clearStep(registry);
        self.step_max_depth = max_depth;
        self.step_follow_new_chunks = follow_new_chunks;
        self.step_armed = true;
        self.step_hit_kind = .step;
        for (sites) |site| {
            const c = registry.get(site.chunk_id) orelse continue;
            try self.placeStepSite(site.chunk_id, site.offset, c);
        }
    }

    /// Arm a one-shot pause at the first source-mapped instruction in `chunk`.
    /// This is the native `:debug` entry stop: user source is compiled exactly
    /// as written, without a synthetic `builtins.break` wrapper.
    pub fn armEntry(self: *BreakpointTable, registry: *ChunkRegistry, chunk_id: ChunkId) !bool {
        const chunk = registry.get(chunk_id) orelse return false;
        const offset = firstMappedOffset(chunk) orelse return false;
        try self.step_temps.ensureTotalCapacity(self.gpa, 1);
        _ = try self.ensureOverlay(chunk_id, chunk);
        self.clearStep(registry);
        self.step_max_depth = std.math.maxInt(u32);
        self.step_armed = true;
        self.step_hit_kind = .entry;
        try self.placeStepSite(chunk_id, offset, chunk);
        return self.placedAt(chunk_id, offset) or self.stepPlacedAt(chunk_id, offset);
    }

    /// Restore every step-temp overlay site and disarm the step.
    pub fn clearStep(self: *BreakpointTable, registry: *ChunkRegistry) void {
        for (self.step_temps.items) |p| self.restoreOverlaySite(registry, p);
        self.step_temps.clearRetainingCapacity();
        self.step_max_depth = 0;
        self.step_follow_new_chunks = false;
        self.step_armed = false;
        self.step_hit_kind = .step;
    }

    /// Return the first instruction boundary at or after `offset`. A paused
    /// caller's saved ip is not necessarily a boundary: handlers record the ip
    /// just after their opcode before decoding operands or forcing a value.
    /// Stepping must advance such an ip past the rest of that instruction,
    /// rather than replacing one of its operand bytes with `breakpoint`.
    pub fn instructionBoundaryAtOrAfter(
        self: *const BreakpointTable,
        chunk_id: ChunkId,
        chunk: *const Chunk,
        offset: usize,
    ) ?u32 {
        _ = self;
        _ = chunk_id;
        var start: usize = 0;
        while (start < chunk.code.len) {
            if (offset <= start) return @intCast(start);
            const next = instructionEnd(chunk, start) orelse return null;
            if (offset < next) return if (next < chunk.code.len) @intCast(next) else null;
            start = next;
        }
        return null;
    }

    /// Resolve a frame's saved ip to the instruction which suspended there.
    /// Handlers save positions anywhere from just after the opcode through the
    /// end of its operands, so this deliberately treats `ip == end` as part of
    /// the preceding instruction. Instruction discovery reads canonical
    /// bytecode; debugger trap bytes exist only in the execution overlay.
    pub fn instructionForSavedIp(
        self: *const BreakpointTable,
        chunk_id: ChunkId,
        chunk: *const Chunk,
        ip: usize,
    ) ?u32 {
        _ = self;
        _ = chunk_id;
        var start: usize = 0;
        while (start < chunk.code.len) {
            const end = instructionEnd(chunk, start) orelse return null;
            if (ip <= end) return @intCast(start);
            start = end;
        }
        return null;
    }

    /// Decode a canonical instruction. Debugger traps live only in execution
    /// overlays, so instruction discovery never needs to undo patch state.
    pub fn instructionOpcode(self: *const BreakpointTable, chunk_id: ChunkId, chunk: *const Chunk, offset: u32) ?opcode.OpCode {
        _ = self;
        _ = chunk_id;
        if (offset >= chunk.code.len) return null;
        const raw = chunk.code[offset];
        if (raw >= opcode.count) return null;
        return @enumFromInt(raw);
    }

    fn instructionEnd(chunk: *const Chunk, start: usize) ?usize {
        const raw = chunk.code[start];
        if (raw >= opcode.count) return null;
        const op: opcode.OpCode = @enumFromInt(raw);
        const operands_start = start + 1;
        const operands_len = opcode.operandLen(op, chunk.code, operands_start);
        if (operands_len > chunk.code.len - operands_start) return null;
        return operands_start + operands_len;
    }

    fn firstExactSpanSite(
        self: *const BreakpointTable,
        chunk_id: ChunkId,
        chunk: *const Chunk,
        wanted: Chunk.SourceSpan,
    ) ?u32 {
        _ = self;
        _ = chunk_id;
        var start: usize = 0;
        while (start < chunk.code.len) {
            var best: ?Chunk.SourceMapEntry = null;
            for (chunk.source_map) |entry| {
                if (start < entry.start or start >= entry.end) continue;
                if (best == null or entry.end - entry.start <= best.?.end - best.?.start)
                    best = entry;
            }
            if (best) |entry| if (sameSpan(entry.span, wanted)) return @intCast(start);
            const next = instructionEnd(chunk, start) orelse return null;
            if (next <= start) return null;
            start = next;
        }
        return null;
    }

    fn placedAt(self: *const BreakpointTable, chunk_id: ChunkId, offset: u32) bool {
        for (self.placements.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset) return true;
        }
        return false;
    }

    fn stepPlacedAt(self: *const BreakpointTable, chunk_id: ChunkId, offset: u32) bool {
        for (self.step_temps.items) |p| {
            if (p.chunk_id == chunk_id and p.offset == offset) return true;
        }
        return false;
    }

    fn placeStepSite(self: *BreakpointTable, chunk_id: ChunkId, offset: u32, chunk: *const Chunk) !void {
        if (offset >= chunk.code.len) return;
        if (self.instructionBoundaryAtOrAfter(chunk_id, chunk, offset) != offset) return;
        if (self.placedAt(chunk_id, offset) or self.stepPlacedAt(chunk_id, offset)) return;
        if (chunk.code[offset] == breakpoint_byte) return;
        try self.step_temps.ensureUnusedCapacity(self.gpa, 1);
        const executable = try self.ensureOverlay(chunk_id, chunk);
        self.step_temps.appendAssumeCapacity(.{
            .req_id = step_request_id,
            .chunk_id = chunk_id,
            .offset = offset,
        });
        executable[offset] = breakpoint_byte;
    }

    pub fn list(self: *const BreakpointTable) []const Request {
        return self.requests.items;
    }

    // -- internals --------------------------------------------------------------

    /// Nearest line ≥ `wanted` in `file` that any registered chunk carries.
    fn nearestLine(self: *const BreakpointTable, registry: *ChunkRegistry, file: []const u8, wanted: u32) ?u32 {
        var best: ?u32 = null;
        var cid: ChunkId = 0;
        const n = registry.count();
        while (cid < n) : (cid += 1) {
            const c = registry.get(cid) orelse continue;
            for (c.source_map) |entry| {
                if (!self.fileMatches(entry.span.file, file)) continue;
                const l = entry.span.line;
                if (l < wanted) continue;
                if (best == null or l < best.?) best = l;
            }
        }
        return best;
    }

    /// Patch `req`'s line into `chunk` if present and not already placed. Uses
    /// the earliest instruction of that line in the chunk (one site per chunk).
    fn placeRequestInChunk(self: *BreakpointTable, req: Request, chunk_id: ChunkId, chunk: *const Chunk) !void {
        const start = self.requestSiteInChunk(req, chunk) orelse return;
        try self.placeSite(req.id, chunk_id, start, chunk);
    }

    fn requestSiteInChunk(self: *const BreakpointTable, req: Request, chunk: *const Chunk) ?u32 {
        var best_start: ?u32 = null;
        for (chunk.source_map) |entry| {
            if (entry.span.line != req.line) continue;
            if (!self.fileMatches(entry.span.file, req.file)) continue;
            if (best_start == null or entry.start < best_start.?) best_start = entry.start;
        }
        return best_start;
    }

    /// Trap one `(chunk_id, offset)` overlay site under `req_id`. Rejects
    /// offsets that aren't a real instruction boundary, sites already owned by
    /// another permanent placement, and promotes an overlapping step temp so a
    /// resolving permanent breakpoint doesn't get lost when the step clears.
    fn placeSite(self: *BreakpointTable, req_id: u32, chunk_id: ChunkId, offset: u32, chunk: *const Chunk) !void {
        if (!self.canPlaceSite(chunk_id, offset, chunk)) return;
        try self.placements.ensureUnusedCapacity(self.gpa, 1);
        _ = try self.ensureOverlay(chunk_id, chunk);
        self.commitSite(req_id, chunk_id, offset);
    }

    fn canPlaceSite(self: *const BreakpointTable, chunk_id: ChunkId, offset: u32, chunk: *const Chunk) bool {
        if (offset >= chunk.code.len) return false;
        if (chunk.code[offset] == breakpoint_byte) return false;
        if (self.instructionBoundaryAtOrAfter(chunk_id, chunk, offset) != offset) return false;
        return !self.placedAt(chunk_id, offset);
    }

    fn commitSite(self: *BreakpointTable, req_id: u32, chunk_id: ChunkId, offset: u32) void {
        const executable = self.overlays.get(chunk_id).?;
        _ = self.takeStepPlacement(chunk_id, offset);
        self.placements.appendAssumeCapacity(.{
            .req_id = req_id,
            .chunk_id = chunk_id,
            .offset = offset,
        });
        executable[offset] = breakpoint_byte;
    }

    fn takeStepPlacement(self: *BreakpointTable, chunk_id: ChunkId, offset: u32) ?Placement {
        for (self.step_temps.items, 0..) |placement, i| {
            if (placement.chunk_id == chunk_id and placement.offset == offset)
                return self.step_temps.orderedRemove(i);
        }
        return null;
    }

    fn ensureOverlay(self: *BreakpointTable, chunk_id: ChunkId, chunk: *const Chunk) ![]u8 {
        if (self.overlays.get(chunk_id)) |code| return code;
        const copy = try self.gpa.dupe(u8, chunk.code);
        errdefer self.gpa.free(copy);
        const gop = try self.overlays.getOrPut(self.gpa, chunk_id);
        if (gop.found_existing) {
            self.gpa.free(copy);
            return gop.value_ptr.*;
        }
        gop.value_ptr.* = copy;
        return copy;
    }

    fn restoreOverlaySite(self: *BreakpointTable, registry: *const ChunkRegistry, placement: Placement) void {
        const chunk = registry.get(placement.chunk_id) orelse return;
        const executable = self.overlays.get(placement.chunk_id) orelse return;
        if (placement.offset < executable.len and placement.offset < chunk.code.len)
            executable[placement.offset] = chunk.code[placement.offset];
    }

    /// A stored span file matches the user's path if it's an exact match, a path
    /// suffix, or the same basename — forgiving of absolute-vs-relative forms.
    fn fileMatches(self: *const BreakpointTable, span_file: ?InternId, wanted: []const u8) bool {
        const id = span_file orelse return false;
        const text = self.intern.get(id);
        if (std.mem.eql(u8, text, wanted)) return true;
        if (std.mem.endsWith(u8, text, wanted)) return true;
        return std.mem.eql(u8, std.fs.path.basename(text), std.fs.path.basename(wanted));
    }
};

fn textFileMatches(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (std.mem.endsWith(u8, a, b) or std.mem.endsWith(u8, b, a)) return true;
    return std.mem.eql(u8, std.fs.path.basename(a), std.fs.path.basename(b));
}

fn sameSpan(a: Chunk.SourceSpan, b: Chunk.SourceSpan) bool {
    return a.file == b.file and
        a.offset == b.offset and
        a.len == b.len and
        a.line == b.line and
        a.column == b.column;
}

fn firstMappedOffset(chunk: *const Chunk) ?u32 {
    var best: ?u32 = null;
    for (chunk.source_map) |entry| {
        if (best == null or entry.start < best.?) best = entry.start;
    }
    return best;
}

fn buildOverlayTestChunk(allocator: std.mem.Allocator) !Chunk {
    var builder = try chunk_mod.ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    try builder.emitConstant(allocator, Value.int(1));
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);
    return builder.finish(allocator, 0);
}

fn setAtWithInjectedFailures(
    allocator: std.mem.Allocator,
    registry: *ChunkRegistry,
    intern: *const InternTable,
    chunk_id: ChunkId,
) !void {
    var table = BreakpointTable.init(allocator, intern);
    defer table.deinit();
    const result = table.setAt(registry, chunk_id, 0) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), table.requests.items.len);
        try std.testing.expectEqual(@as(usize, 0), table.placements.items.len);
        try std.testing.expectEqual(@as(u32, 1), table.next_id);
        try std.testing.expectEqual(
            @as(u8, @intFromEnum(opcode.OpCode.push_const)),
            registry.get(chunk_id).?.code[0],
        );
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), result.sites);
}

/// Instructions whose execution can enter another frame, force one or more
/// lazy values, or otherwise perform a strict evaluation boundary. Stack-only
/// plumbing is intentionally absent: source stepping should be more precise,
/// not a bytecode single-step firehose.
fn evaluationStepBoundary(op: opcode.OpCode) bool {
    return switch (op) {
        .loc_get,
        .loc_get_w,
        .up_get,
        .int_add,
        .int_sub,
        .int_mul,
        .int_div,
        .int_neg,
        .flt_add,
        .flt_sub,
        .flt_mul,
        .flt_div,
        .cmp_eq,
        .cmp_ne,
        .cmp_lt,
        .cmp_le,
        .cmp_gt,
        .cmp_ge,
        .cmp_eq_null,
        .cmp_ne_null,
        .bool_not,
        .bool_check,
        .jump_false,
        .attrs_new,
        .attrs_merge_strict,
        .attrs_merge,
        .list_cat,
        .list_cat_n,
        .str_cat,
        .path_cat,
        .thunk_arg,
        .call,
        .call_tail,
        .call_n,
        .call_tail_n,
        .loc_get_ret,
        .loc_get_ret_w,
        .up_get_ret,
        .up_get_attr,
        .loc_get_attr,
        .loc_get_attr_w,
        .attr_get,
        .attr_get_w,
        .attr_has_strict,
        .attr_has_strict_w,
        .attr_get_dyn,
        .attr_get_dyn_or,
        .attr_get_path_dyn_or,
        .attr_get_path_dyn_or_w,
        .attr_get_path_or,
        .attr_get_path_or_w,
        .attr_get_path_mix_or,
        .attr_has_path,
        .attr_has_path_w,
        .attr_has_path_mix,
        .attr_bind,
        .attr_bind_w,
        .with_lookup,
        .with_lookup_w,
        .arg_or_lit,
        .attrs_apply_overrides,
        => true,
        else => false,
    };
}

test "step sites advance suspended operand ips to instruction boundaries" {
    var intern = try InternTable.init(std.testing.allocator);
    defer intern.deinit();
    var table = BreakpointTable.init(std.testing.allocator, &intern);
    defer table.deinit();

    // loc_get has one operand and push_const has two. A handler can suspend
    // with its saved ip at any of the marked operand positions.
    var code = [_]u8{
        @intFromEnum(opcode.OpCode.loc_get),    7,
        @intFromEnum(opcode.OpCode.push_const), 0,
        0,                                      @intFromEnum(opcode.OpCode.halt),
    };
    var constants: [0]Value = .{};
    var chunk: Chunk = .{ .code = &code, .constants = &constants, .local_count = 0 };

    try std.testing.expectEqual(@as(?u32, 0), table.instructionBoundaryAtOrAfter(9, &chunk, 0));
    try std.testing.expectEqual(@as(?u32, 2), table.instructionBoundaryAtOrAfter(9, &chunk, 1));
    try std.testing.expectEqual(@as(?u32, 2), table.instructionBoundaryAtOrAfter(9, &chunk, 2));
    try std.testing.expectEqual(@as(?u32, 5), table.instructionBoundaryAtOrAfter(9, &chunk, 3));
    try std.testing.expectEqual(@as(?u32, 5), table.instructionBoundaryAtOrAfter(9, &chunk, 4));

    // A raw operand offset is rejected, while the normalized boundary is
    // trapped only in debugger-owned executable code. Canonical bytecode and
    // its instruction scans remain unchanged.
    try table.placeStepSite(9, 1, &chunk);
    try std.testing.expectEqual(@as(u8, 7), code[1]);
    try table.placeStepSite(9, 2, &chunk);
    try std.testing.expectEqual(@intFromEnum(opcode.OpCode.push_const), code[2]);
    try std.testing.expectEqual(breakpoint_byte, table.executableCode(9, &chunk)[2]);
    try std.testing.expectEqual(@as(?u32, 5), table.instructionBoundaryAtOrAfter(9, &chunk, 3));
    try std.testing.expectEqual(@as(?u32, 0), table.instructionForSavedIp(9, &chunk, 1));
    try std.testing.expectEqual(@as(?u32, 0), table.instructionForSavedIp(9, &chunk, 2));
    try std.testing.expectEqual(@as(?u32, 2), table.instructionForSavedIp(9, &chunk, 3));
    try std.testing.expectEqual(@as(?u32, 2), table.instructionForSavedIp(9, &chunk, 5));
}

test "evaluation step sites include forces and calls but skip stack plumbing" {
    var intern = try InternTable.init(std.testing.allocator);
    defer intern.deinit();
    var table = BreakpointTable.init(std.testing.allocator, &intern);
    defer table.deinit();

    var code = [_]u8{
        @intFromEnum(opcode.OpCode.push_null),
        @intFromEnum(opcode.OpCode.loc_get),
        0,
        @intFromEnum(opcode.OpCode.pop),
        @intFromEnum(opcode.OpCode.call),
        @intFromEnum(opcode.OpCode.halt),
    };
    var constants: [0]Value = .{};
    var chunk: Chunk = .{ .code = &code, .constants = &constants, .local_count = 1 };
    var sites: std.ArrayListUnmanaged(BreakpointTable.Site) = .empty;
    defer sites.deinit(std.testing.allocator);

    try table.appendEvaluationStepSites(std.testing.allocator, 3, &chunk, 1, &sites);
    try std.testing.expectEqualSlices(BreakpointTable.Site, &.{.{ .chunk_id = 3, .offset = 4 }}, sites.items);
}

test "source-span breakpoints distinguish nested expressions on one line" {
    const allocator = std.testing.allocator;
    var intern = try InternTable.init(allocator);
    defer intern.deinit();
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();
    var table = BreakpointTable.init(allocator, &intern);
    defer table.deinit();

    var builder = try chunk_mod.ChunkBuilder.init(allocator);
    defer builder.deinit(allocator);
    try builder.emitConstant(allocator, Value.int(1)); // 0..3
    try builder.emitConstant(allocator, Value.int(2)); // 3..6
    try builder.writeOp(allocator, .int_add); // 6..7
    try builder.writeOp(allocator, .ret);
    try builder.writeOp(allocator, .halt);

    const outer: Chunk.SourceSpan = .{ .file = null, .offset = 0, .len = 5, .line = 1, .column = 1 };
    const left: Chunk.SourceSpan = .{ .file = null, .offset = 0, .len = 1, .line = 1, .column = 1 };
    const right: Chunk.SourceSpan = .{ .file = null, .offset = 4, .len = 1, .line = 1, .column = 5 };
    try builder.addSourceMapEntry(allocator, 0, 3, left);
    try builder.addSourceMapEntry(allocator, 3, 6, right);
    try builder.addSourceMapEntry(allocator, 0, 7, outer);

    const chunk_id = try registry.register(try builder.finish(allocator, 0));
    const chunk = registry.get(chunk_id).?;

    try std.testing.expectEqual(@as(usize, 1), (try table.setSpan(&registry, chunk_id, left)).sites);
    try std.testing.expectEqual(@as(usize, 1), (try table.setSpan(&registry, chunk_id, right)).sites);
    try std.testing.expectEqual(@as(usize, 1), (try table.setSpan(&registry, chunk_id, outer)).sites);
    try std.testing.expect(table.hasSpan(chunk_id, left));
    try std.testing.expect(table.hasSpan(chunk_id, right));
    try std.testing.expect(table.hasSpan(chunk_id, outer));
    try std.testing.expect(table.hasSite(chunk_id, 0));
    try std.testing.expect(table.hasSite(chunk_id, 3));
    try std.testing.expect(table.hasSite(chunk_id, 6));
    try std.testing.expectEqual(@intFromEnum(opcode.OpCode.push_const), chunk.code[0]);
    try std.testing.expectEqual(breakpoint_byte, table.executableCode(chunk_id, chunk)[0]);

    try std.testing.expect(table.removeSpan(&registry, chunk_id, outer));
    try std.testing.expect(!table.hasSpan(chunk_id, outer));
    try std.testing.expectEqual(@as(u8, @intFromEnum(opcode.OpCode.int_add)), chunk.code[6]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(opcode.OpCode.int_add)), table.executableCode(chunk_id, chunk)[6]);
    try std.testing.expect(table.hasSpan(chunk_id, left));
    try std.testing.expect(table.hasSpan(chunk_id, right));
    try std.testing.expect(table.removeSpan(&registry, chunk_id, left));
    try std.testing.expect(table.removeSpan(&registry, chunk_id, right));
}

test "breakpoint overlays preserve canonical chunk deduplication" {
    const allocator = std.testing.allocator;
    var intern = try InternTable.init(allocator);
    defer intern.deinit();
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();
    var table = BreakpointTable.init(allocator, &intern);
    defer table.deinit();

    const first = try registry.registerDeduped(
        try buildOverlayTestChunk(allocator),
        name_tree.root_name_id,
    );
    const canonical = registry.get(first.id).?;
    const original = @intFromEnum(opcode.OpCode.push_const);
    try std.testing.expectEqual(original, canonical.code[0]);
    try std.testing.expectEqual(@as(usize, 1), (try table.setAt(&registry, first.id, 0)).sites);
    try std.testing.expectEqual(original, canonical.code[0]);
    try std.testing.expectEqual(breakpoint_byte, table.executableCode(first.id, canonical)[0]);

    var duplicate = try buildOverlayTestChunk(allocator);
    const second = try registry.registerDeduped(duplicate, name_tree.root_name_id);
    if (second.reused) duplicate.deinit(allocator);
    try std.testing.expect(second.reused);
    try std.testing.expectEqual(first.id, second.id);
    try std.testing.expectEqual(original, registry.get(second.id).?.code[0]);
}

test "breakpoint overlay installation is failure atomic" {
    const allocator = std.testing.allocator;
    var intern = try InternTable.init(allocator);
    defer intern.deinit();
    var registry = try ChunkRegistry.init(allocator);
    defer registry.deinit();
    const chunk_id = try registry.register(try buildOverlayTestChunk(allocator));

    try std.testing.checkAllAllocationFailures(
        allocator,
        setAtWithInjectedFailures,
        .{ &registry, &intern, chunk_id },
    );
}
