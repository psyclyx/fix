//! REPL command implementation and session coordinator.
//!
//! Two strictly separated modes:
//!
//! - **Interactive** (stdin AND stdout are a tty): an ordinary inline editor
//!   with history, completion, and smart-enter multiline input. `:vm`
//!   explicitly enters the full-screen VM workspace unless `--no-tui` was
//!   given; leaving it restores normal scrollback and the inline prompt.
//! - **Streaming** (either end is not a tty): a plain read-a-line loop — no
//!   escape sequences, no raw mode, no redraw tricks. Lines are accumulated
//!   until they form a complete expression, so multiline input pipes work.
//!
//! Both modes share the same command set (`repl/commands.zig`) and the same
//! evaluation core: expressions evaluate inside an ambient scope attrset
//! holding the repl bindings (`name = expr`, `:l`, and `it`), which is also
//! registered as a GC root; a collection runs between inputs so memory does
//! not accrete across evaluations.

const std = @import("std");
const presentation = @import("../presentation.zig");
const progress_ui = @import("../progress.zig");
const args = @import("../args.zig");
const setup = @import("../setup.zig");
const config_discovery = @import("../config_discovery.zig");
const debugger = @import("../debugger.zig");
const render_err = @import("../render.zig");
const stats = @import("../stats.zig");
const engine = @import("expr");
const runtime = @import("runtime");
const future_mod = runtime.future;
const types = runtime.types;

const commands = @import("commands.zig");
const check = @import("check.zig");
const history_mod = @import("history.zig");
const repl_scope = @import("scope.zig");
const editor_mod = @import("editor.zig");
const complete_mod = @import("complete.zig");
const line_input = @import("line_input.zig");
const vm_ui = @import("vm/root.zig");
const vm_plain = @import("vm/plain.zig");
const vm_query_cache = @import("vm/query_cache.zig");
const transcript_mod = @import("transcript.zig");

const Options = args.Options;
const Engine = engine.Engine;
const Value = runtime.Value;
const disasm = engine.bytecode.disasm;

pub const synopsis =
    \\usage: fix repl [options]
    \\
    \\start an interactive read-eval-print loop.
;

const prompt_main = "fix> ";
const prompt_cont = "...> ";

/// `fix repl` subcommand entry point.
pub fn run(process: @import("../process_context.zig").ProcessContext, init: std.process.Init, args_iter: *std.process.Args.Iterator) !u8 {
    const allocator = process.allocator;
    var diag: args.Diag = .{};
    var options = args.parse(allocator, args_iter, null, .repl, &diag) catch |err| switch (err) {
        error.Help => {
            args.writeHelp(init.io, synopsis, .repl);
            return 0;
        },
        else => {
            render_err.usageError(init.io, init.environ_map, args.errorMessage(err), diag.offending, synopsis);
            return 2;
        },
    };
    defer options.deinit(allocator);
    if (options.source != null) {
        render_err.usageError(init.io, init.environ_map, "repl takes no expression, file, or flake", null, synopsis);
        return 2;
    }

    // THE MODE GATE. A tty always gets the ordinary inline editor. --no-tui
    // only selects line-oriented implementations for the optional VM and
    // debugger workspaces; it does not discard history, completion, color, or
    // terminal key handling.
    const stdin_tty = std.Io.File.stdin().isTty(init.io) catch false;
    const stdout_tty = std.Io.File.stdout().isTty(init.io) catch false;
    const interactive = stdin_tty and stdout_tty;
    const tui_enabled = interactive and !options.no_tui;

    // The debugger needs a deterministic pause point: one worker, no
    // speculation. Same posture as `fix eval --debugger`.
    const worker_count = if (options.debugger) 1 else try setup.workerCount(&options);
    const memory_backing = setup.applyMemoryBacking(process, options.hugetlb);
    var settings = try config_discovery.loadLocal(allocator, init, &options);
    config_discovery.fetchFlakeSettings(allocator, init, &options, &settings);
    defer settings.deinit();
    var ev = try Engine.init(allocator, setup.engineConfig(init, worker_count, memory_backing, &options));
    var session = setup.Session.init(&ev);
    defer session.deinit(.full);
    const term = try session.configure(init, &options, &settings);
    // The explorer is a first-class REPL surface: retain binding and synthetic
    // lambda/node path segments for every session, not only --debugger runs.
    ev.setCaptureChunkNames(true);

    var console: debugger.Console = .{ .allocator = allocator, .io = init.io, .use_color = term.use_color };
    defer console.deinit();
    if (options.debugger) {
        ev.setParallelismToggles(true, true);
    }

    var progress = progress_ui.EvalProgress.init(init.io, ev.basePath() orelse "", term.log_progress, term.color_depth, options.verbose);
    var repl_ok = false;
    defer progress.deinit(repl_ok);
    if (term.progressEnabled()) ev.setObserver(progress.observer());

    // Streaming output suppresses automatic color; a tty retains the resolved
    // terminal decision even when its alternate-screen workspaces are disabled.
    ev.setValueColor(if (options.debugger) term.use_color else (term.use_color and interactive));
    var repl = Repl.init(allocator, init, &options, &ev, if (interactive) term.color_depth else .none, interactive);
    defer repl.deinit();
    repl.debug_console = &console;
    var vm_debugger = vm_ui.VmDebugger.init(allocator, init.io, &ev, term.color_depth, &repl.history);
    if (tui_enabled) repl.debug_ui = &vm_debugger;
    if (options.debugger) {
        if (tui_enabled) vm_debugger.install(&ev) else console.install(&ev);
    }

    if (interactive) {
        try repl.runInteractive();
    } else {
        try repl.runBare(stdin_tty);
    }
    if (options.stats) stats.report(&ev);
    repl_ok = true;
    return 0;
}

const Repl = struct {
    const VmSource = struct {
        first: types.ChunkId,
        end: types.ChunkId,
        entry: types.ChunkId,
        text: []u8,
    };

    allocator: std.mem.Allocator,
    proc_init: std.process.Init,
    io: std.Io,
    options: *const Options,
    ev: *Engine,
    use_color: bool,
    color_depth: presentation.ColorDepth,
    interactive: bool,
    tui_enabled: bool,
    /// Shared by persistent `--debugger` sessions and transient `:debug`
    /// commands; the streaming loop attaches its buffered stdin reader here.
    debug_console: ?*debugger.Console = null,
    /// The consolidated VM-explorer debug UI, selected only when TUI workspaces
    /// are enabled. Null for --no-tui/streaming sessions (they use the console).
    debug_ui: ?*vm_ui.VmDebugger = null,

    /// Scope bindings, insertion-ordered. Keys are owned; values are heap
    /// Values kept alive via the evaluator's external roots and scope attrset.
    scope_bindings: repl_scope.Bindings = .{},
    /// Files loaded with :l, in order, for :r. Owned.
    loaded: std.ArrayListUnmanaged([]u8) = .empty,
    /// Stable VM explorer focus. Ordinary evaluations update it to the
    /// result's backing chunk (closure/thunk) or their compiled entry chunk.
    vm_focus: ?types.ChunkId = null,
    /// Cold name and live-object indexes for bounded text-mode VM queries.
    vm_queries: vm_query_cache.Cache = .{},
    /// Direct REPL sources are not backed by the evaluator's file cache. Keep
    /// the source alongside the chunk generation so the VM inspector can show
    /// real text for expression spans as well as imported-file spans.
    vm_sources: std.ArrayListUnmanaged(VmSource) = .empty,
    /// Set only while the full-screen REPL executes one input. Every ordinary
    /// command/result/diagnostic is routed here, preserving the shared command
    /// implementation while keeping terminal writes inside the owned screen.
    output_capture: ?*std.Io.Writer = null,
    tui_active: bool = false,
    vm_requested: bool = false,
    vm_heap_requested: bool = false,
    history: history_mod.History,
    quit: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        proc_init: std.process.Init,
        options: *const Options,
        ev: *Engine,
        color_depth: presentation.ColorDepth,
        interactive: bool,
    ) Repl {
        return .{
            .allocator = allocator,
            .proc_init = proc_init,
            .io = proc_init.io,
            .options = options,
            .ev = ev,
            .use_color = color_depth.enabled(),
            .color_depth = color_depth,
            .interactive = interactive,
            .tui_enabled = interactive and !options.no_tui,
            .history = history_mod.History.init(allocator),
        };
    }

    fn deinit(self: *Repl) void {
        self.scope_bindings.deinit(self.allocator);
        for (self.loaded.items) |p| self.allocator.free(p);
        self.loaded.deinit(self.allocator);
        self.vm_queries.deinit();
        for (self.vm_sources.items) |source| self.allocator.free(source.text);
        self.vm_sources.deinit(self.allocator);
        self.history.deinit();
    }

    // -- streaming mode ------------------------------------------------------

    /// The plain loop: read lines, accumulate until the input parses as a
    /// complete expression, process. No escape sequences anywhere; a prompt
    /// is retained for defensive use if the inline editor cannot own a tty.
    fn runBare(self: *Repl, show_prompt: bool) !void {
        var stdin_buffer: [64 * 1024]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(self.io, &stdin_buffer);
        // Share this reader with the debug console so a break mid-evaluation
        // reads its commands from the same buffered pipe instead of racing it.
        if (self.debug_console) |c| c.attachReader(&stdin);

        var pending: std.ArrayListUnmanaged(u8) = .empty;
        defer pending.deinit(self.allocator);

        while (!self.quit) {
            if (show_prompt) {
                var out = self.output();
                defer out.flush() catch {};
                out.writer().writeAll(if (pending.items.len == 0) prompt_main else prompt_cont) catch {};
            }
            const line = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    try self.printError("input line is too long", .{});
                    _ = stdin.interface.discardDelimiterInclusive('\n') catch {};
                    pending.clearRetainingCapacity();
                    continue;
                },
                else => return err,
            } orelse {
                // EOF: process whatever is pending so a piped script's last
                // (unterminated) expression still runs.
                if (std.mem.trim(u8, pending.items, " \t\r\n").len > 0) {
                    try self.processInput(pending.items);
                }
                break;
            };

            if (pending.items.len == 0) {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                // Commands never continue across lines.
                if (trimmed[0] == ':') {
                    try self.processInput(trimmed);
                    continue;
                }
            }
            try pending.appendSlice(self.allocator, line);
            if (check.isComplete(self.allocator, pending.items)) {
                try self.processInput(pending.items);
                pending.clearRetainingCapacity();
            } else {
                try pending.append(self.allocator, '\n');
            }
        }
    }

    // -- interactive mode ------------------------------------------------------

    fn runInteractive(self: *Repl) !void {
        const env = self.proc_init.environ_map;
        if (env.get("FIX_REPL_NO_HINT") == null) {
            var out = self.output();
            defer out.flush() catch {};
            try presentation.style(out.writer(), self.use_color, .dim);
            try out.writer().writeAll("fix repl — :? for help, :vm to explore the VM\n");
            try presentation.reset(out.writer(), self.use_color);
        }
        self.history.open(self.io, env);

        var completer_ctx = complete_mod.Ctx{
            .ev = self.ev,
            .io = self.io,
            .bindings = &self.scope_bindings.map,
        };
        var editor = editor_mod.Editor.init(
            self.allocator,
            &self.history,
            complete_mod.completer(&completer_ctx),
            .{ .ctx = self, .isCompleteFn = isCompleteThunk },
        );
        defer editor.deinit();

        while (!self.quit) {
            const line = line_input.read(self.allocator, self.io, self.use_color, &editor) catch |err| switch (err) {
                error.NotATerminal => return self.runBare(false),
                else => return err,
            } orelse break;
            defer self.allocator.free(line);

            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            try self.history.add(trimmed);
            try self.processInput(trimmed);
            if (self.vm_requested and !self.quit) try self.runVmSession(&editor);
        }
    }

    fn runVmSession(self: *Repl, editor: *editor_mod.Editor) !void {
        self.vm_requested = false;
        const start_heap = self.vm_heap_requested;
        self.vm_heap_requested = false;
        var journal = transcript_mod.Capture.init(self.allocator, 4 * 1024 * 1024);
        defer journal.deinit();

        self.tui_active = true;
        defer self.tui_active = false;
        vm_ui.runSession(self.allocator, self.io, self.ev, self.color_depth, editor, &journal, .{
            .ctx = self,
            .executeFn = sessionExecute,
            .focusFn = sessionFocus,
            .sourceFn = sessionSource,
            .quitFn = sessionQuit,
            .takeHeapRequestFn = sessionTakeHeapRequest,
            .start_heap = start_heap,
        }, self.debug_ui) catch |err| switch (err) {
            error.NotATerminal => return,
            else => return err,
        };

        var out = self.output();
        defer out.flush() catch {};
        if (journal.omitted() > 0) {
            try presentation.style(out.writer(), self.use_color, .dim);
            try out.writer().print("[VM transcript retained its newest {Bi}; {Bi} omitted]\n", .{
                journal.written().len,
                journal.omitted(),
            });
            try presentation.reset(out.writer(), self.use_color);
        }
        try out.writer().writeAll(journal.written());
    }

    fn sessionExecute(raw: *anyopaque, input: []const u8, sink: *std.Io.Writer) !void {
        const self: *Repl = @ptrCast(@alignCast(raw));
        self.output_capture = sink;
        defer self.output_capture = null;
        try self.history.add(input);
        try self.processInput(input);
    }

    fn sessionFocus(raw: *anyopaque) ?types.ChunkId {
        const self: *Repl = @ptrCast(@alignCast(raw));
        return self.vm_focus;
    }

    fn sessionSource(raw: *anyopaque, chunk_id: types.ChunkId) ?[]const u8 {
        const self: *Repl = @ptrCast(@alignCast(raw));
        var i = self.vm_sources.items.len;
        while (i > 0) {
            i -= 1;
            const source = self.vm_sources.items[i];
            if (chunk_id == source.entry or (chunk_id >= source.first and chunk_id < source.end)) return source.text;
        }
        return null;
    }

    fn sessionQuit(raw: *anyopaque) bool {
        const self: *Repl = @ptrCast(@alignCast(raw));
        return self.quit;
    }

    fn sessionTakeHeapRequest(raw: *anyopaque) bool {
        const self: *Repl = @ptrCast(@alignCast(raw));
        const requested = self.vm_heap_requested;
        self.vm_heap_requested = false;
        return requested;
    }

    fn isCompleteThunk(ctx: *anyopaque, text: []const u8) bool {
        const self: *Repl = @ptrCast(@alignCast(ctx));
        return check.isComplete(self.allocator, text);
    }

    // -- input processing (shared by both modes) -------------------------------

    fn processInput(self: *Repl, input: []const u8) !void {
        defer if (self.debug_ui) |ui| ui.endEvaluation();
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0) return;
        if (trimmed[0] == ':') {
            try self.runCommand(trimmed);
            return;
        }
        if (parseBinding(trimmed)) |b| {
            if (try self.evalExpr(b.expr)) |value| {
                try self.bind(b.name, value);
                try self.collectBetweenInputs();
            }
            return;
        }
        if (try self.evalExpr(trimmed)) |value| {
            // Root the result as `it` BEFORE printing forces anything else,
            // and before the between-inputs collection.
            try self.bind("it", value);
            try self.printResult(value, trimmed);
            try self.collectBetweenInputs();
        }
    }

    fn runCommand(self: *Repl, input: []const u8) !void {
        const invocation = commands.parse(input) catch |err| {
            const word_end = std.mem.indexOfAny(u8, input, " \t") orelse input.len;
            const word = input[0..word_end];
            switch (err) {
                error.UnknownCommand => try self.printError("unknown command `{s}` — :? lists commands", .{word}),
                error.MissingArgument => {
                    const command = commands.find(word).?;
                    try self.printError("{s} needs {s} — :? for details", .{ word, command.metavar });
                },
                error.UnexpectedArgument => try self.printError("{s} takes no argument", .{word}),
            }
            return;
        };
        const cmd = invocation.command;
        const rest = invocation.argument;

        switch (cmd.id) {
            .help => {
                var out = self.output();
                defer out.flush() catch {};
                try commands.writeHelp(out.writer());
            },
            .quit => self.quit = true,
            .load => {
                if (try self.loadFile(rest)) {
                    try self.loaded.ensureUnusedCapacity(self.allocator, 1);
                    const path = try self.allocator.dupe(u8, rest);
                    self.loaded.appendAssumeCapacity(path);
                    try self.collectBetweenInputs();
                }
            },
            .reload => {
                for (self.loaded.items) |path| {
                    if (!try self.loadFile(path)) break;
                }
                try self.collectBetweenInputs();
            },
            .type_of => {
                if (try self.evalExpr(rest)) |v| {
                    const forced = self.ev.forceValue(v) catch v;
                    var out = self.output();
                    defer out.flush() catch {};
                    try self.describeType(out.writer(), forced);
                    try out.writer().writeByte('\n');
                    try self.collectBetweenInputs();
                }
            },
            .print => {
                if (try self.evalExpr(rest)) |v| {
                    try self.bind("it", v);
                    self.ev.forceDeep(v) catch |err| {
                        try self.evaluationError(rest, err);
                        return;
                    };
                    try self.printResult(v, rest);
                    try self.collectBetweenInputs();
                }
            },
            .inspect => {
                if (try self.evalExpr(rest)) |v| {
                    var out = self.output();
                    defer out.flush() catch {};
                    try self.inspectValue(out.writer(), v);
                    try self.collectBetweenInputs();
                }
            },
            .debug => try self.debugExpr(rest),
            .vm => try self.vm(rest),
            .env => {
                var out = self.output();
                defer out.flush() catch {};
                const w = out.writer();
                if (self.scope_bindings.map.count() == 0) {
                    try w.writeAll("no bindings — `name = expr` creates one\n");
                } else {
                    var it = self.scope_bindings.map.iterator();
                    while (it.next()) |e| {
                        try presentation.style(w, self.use_color, .name);
                        try w.writeAll(e.key_ptr.*);
                        try presentation.reset(w, self.use_color);
                        try w.writeAll(" : ");
                        try self.describeType(w, e.value_ptr.*);
                        try w.writeByte('\n');
                    }
                }
            },
            .gc => {
                self.clearVmRuntime();
                const r = self.ev.collectMajorNow();
                var out = self.output();
                defer out.flush() catch {};
                const w = out.writer();
                if (!r.ran) {
                    try w.writeAll("gc: collector inactive (non-gc build, --gc-budget=0, or nothing evaluated yet)\n");
                } else if (r.collections == 0) {
                    try w.print("gc: collector armed; heap capacity {d:.1} MiB retained for reuse\n", .{
                        @as(f64, @floatFromInt(r.capacity_bytes)) / (1 << 20),
                    });
                } else {
                    // The detector marker lets the gc-soak e2e skip its
                    // capacity-plateau check: detector builds retain swept
                    // object slots un-reused (stale reads must trap), so
                    // capacity ratchets by design.
                    try w.print("gc: freed {d} object{s}; live {d:.1} MiB; heap capacity {d:.1} MiB retained for reuse{s}\n", .{
                        r.objects_freed,
                        if (r.objects_freed == 1) "" else "s",
                        @as(f64, @floatFromInt(r.live_bytes)) / (1 << 20),
                        @as(f64, @floatFromInt(r.capacity_bytes)) / (1 << 20),
                        if (comptime runtime.heap.gc_debug) " (detector build: no slot reuse)" else "",
                    });
                }
            },
        }
    }

    // -- evaluation ------------------------------------------------------------

    /// Evaluate an expression in the repl scope. Failures render to stderr
    /// and yield null.
    fn evalExpr(self: *Repl, source: []const u8) !?Value {
        return self.evalExprMode(source, false);
    }

    fn evalExprMode(self: *Repl, source: []const u8, debug_entry: bool) !?Value {
        self.clearVmRuntime();
        self.ev.setDebugSource(source);
        defer self.ev.setDebugSource(null);
        const first_chunk = self.ev.chunkRegistry().count();
        const result = (if (debug_entry)
            self.ev.debugWithScopeResult(source, self.scope_bindings.value)
        else
            self.ev.evaluateWithScopeResult(source, self.scope_bindings.value)) catch |err| {
            try self.rememberVmSource(source, first_chunk, null);
            if (debug_entry) self.endDebugScreen();
            try self.evalFailure(source, err);
            return null;
        };
        try self.rememberVmSource(source, first_chunk, result.entry_chunk);
        self.vm_focus = self.focusForValue(result.value, result.entry_chunk);
        return result.value;
    }

    fn debugExpr(self: *Repl, source: []const u8) !void {
        const console = self.debug_console orelse {
            try self.printError("debugger unavailable", .{});
            return;
        };
        self.ev.setDebugSerial(true);
        defer self.ev.setDebugSerial(false);

        const transient = !self.options.debugger;
        if (transient) {
            if (self.debug_ui) |ui| ui.install(self.ev) else console.install(self.ev);
        }
        defer if (transient) {
            if (self.debug_ui) |ui| ui.uninstall(self.ev) else console.uninstall(self.ev);
        };

        const value = try self.evalExprMode(source, true);
        // A final step/finish can run straight through to completion without
        // another pause. Close the debugger's alternate screen before writing
        // the result, otherwise leaving that screen immediately discards it.
        self.endDebugScreen();
        if (value) |result| {
            try self.bind("it", result);
            try self.printResult(result, source);
            try self.collectBetweenInputs();
        }
    }

    fn endDebugScreen(self: *Repl) void {
        if (self.debug_ui) |ui| ui.endEvaluation();
    }

    fn rememberVmSource(self: *Repl, source: []const u8, first: types.ChunkId, entry: ?types.ChunkId) !void {
        const end = self.ev.chunkRegistry().count();
        if (first == end and entry == null) return;
        const owned = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(owned);
        try self.vm_sources.append(self.allocator, .{
            .first = first,
            .end = end,
            .entry = entry orelse std.math.maxInt(types.ChunkId),
            .text = owned,
        });
    }

    fn printResult(self: *Repl, value: Value, source: []const u8) !void {
        const mode = self.options.evaluationMode();
        if (mode.strict) {
            self.ev.forceDeep(value) catch |err| {
                try self.evaluationError(source, err);
                return;
            };
        }
        var out = self.output();
        defer out.flush() catch {};
        const w = out.writer();
        const write_err: ?anyerror = blk: {
            switch (mode.output) {
                .nix => self.ev.writeValue(w, value) catch |err| break :blk err,
                .raw => self.ev.writeRawValue(w, value) catch |err| break :blk err,
                .json => self.ev.writeJsonValue(w, value) catch |err| break :blk err,
                .xml => self.ev.writeXmlValue(w, value) catch |err| break :blk err,
            }
            break :blk null;
        };
        if (write_err) |err| {
            if (err == error.WriteFailed) return err;
            w.flush() catch {};
            try self.evaluationError(source, err);
            return;
        }
        if (mode.output != .xml and mode.output != .raw) try w.writeByte('\n');
    }

    /// `:l PATH` — evaluate a file (auto-calling a top-level function with
    /// `{}`, as nix repl does) and merge its attrset into the scope.
    fn loadFile(self: *Repl, path: []const u8) !bool {
        var expr: std.ArrayListUnmanaged(u8) = .empty;
        defer expr.deinit(self.allocator);
        try expr.appendSlice(self.allocator, "let __fix_l = import (");
        if (path.len > 0 and path[0] == '<') {
            try expr.appendSlice(self.allocator, path);
        } else if (path.len > 0 and (path[0] == '/' or path[0] == '.' or path[0] == '~')) {
            try expr.appendSlice(self.allocator, path);
        } else {
            try expr.appendSlice(self.allocator, "./");
            try expr.appendSlice(self.allocator, path);
        }
        try expr.appendSlice(self.allocator, "); in if builtins.isFunction __fix_l then __fix_l {} else __fix_l");

        const value = (try self.evalExpr(expr.items)) orelse return false;
        const forced = self.ev.forceValue(value) catch |err| {
            try self.evaluationError(path, err);
            return false;
        };
        if (!forced.isAttrs()) {
            try self.printError("{s} did not evaluate to an attrset", .{path});
            return false;
        }
        const tooling = self.ev.tooling();
        const entries = tooling.attrs(forced) catch return false;
        var updates: std.ArrayListUnmanaged(Engine.ScopeBinding) = .empty;
        defer updates.deinit(self.allocator);
        try updates.ensureTotalCapacity(self.allocator, entries.len());
        for (entries.names, entries.values) |entry_name, entry_value| {
            updates.appendAssumeCapacity(.{
                .name = tooling.internText(entry_name),
                .value = entry_value,
            });
        }
        try self.applyBindingUpdates(updates.items);
        var out = self.output();
        defer out.flush() catch {};
        try out.writer().print("added {d} bindings\n", .{entries.len()});
        return true;
    }

    // -- bindings & GC ----------------------------------------------------------

    /// Bind `name` to `value` and rebuild the scope attrset + GC roots.
    fn bind(self: *Repl, name: []const u8, value: Value) !void {
        try self.scope_bindings.bind(self.allocator, self.ev, name, value);
    }

    /// Apply one or more binding changes as one transaction. Every owned key,
    /// map capacity, candidate scope, and evaluator root replacement exists
    /// before the live binding map changes; after the root swap, commit is
    /// allocation-free.
    fn applyBindingUpdates(self: *Repl, updates: []const Engine.ScopeBinding) !void {
        try self.scope_bindings.apply(self.allocator, self.ev, updates);
    }

    /// The between-inputs collection: reclaim the last evaluation's garbage
    /// so repl memory tracks the live bindings, not the session's history.
    /// The first call arms tracking (cheap); later calls run a full MAJOR
    /// collection — the repl is idle here, so pay for reclaiming tenured
    /// garbage too (a minor leaves the old generation, which under parallel
    /// workers otherwise ratchets reserved memory up across inputs).
    fn collectBetweenInputs(self: *Repl) !void {
        self.clearVmRuntime();
        _ = self.ev.collectMajorNow();
    }

    // -- introspection ----------------------------------------------------------

    fn describeType(self: *Repl, w: *std.Io.Writer, value: Value) !void {
        switch (value.kind()) {
            .null => try w.writeAll("null"),
            .bool_true, .bool_false => try w.writeAll("a boolean"),
            .int, .boxed_int => try w.writeAll("an integer"),
            .float => try w.writeAll("a float"),
            .string, .string_context, .heap_string => try w.writeAll("a string"),
            .path => try w.writeAll("a path"),
            .list => {
                const n = self.ev.tooling().listLen(value) catch 0;
                try w.print("a list ({d} item{s})", .{ n, if (n == 1) "" else "s" });
            },
            .attrs => {
                const n = if (self.ev.tooling().attrs(value)) |entries| entries.len() else |_| 0;
                try w.print("a set ({d} attr{s})", .{ n, if (n == 1) "" else "s" });
            },
            .closure, .builtin, .builtin_closure, .partial_app => try w.writeAll("a function"),
            .thunk => try w.writeAll("a thunk (unforced)"),
        }
    }

    /// `:i` — one value, inspected without forcing: kind, thunk state and
    /// backing chunk, closure chunk/arity, container sizes.
    fn inspectValue(self: *Repl, w: *std.Io.Writer, value: Value) !void {
        const symbols: disasm.Symbols = .{
            .intern = self.ev.internTable(),
            .registry = self.ev.chunkRegistry(),
        };
        switch (value.kind()) {
            .thunk => {
                const id = value.asObjectId();
                const thunk = self.ev.tooling().thunk(value) catch {
                    try disasm.writeStoreRef(w, "objects", id, .object, "thunk · unreadable", self.color_depth);
                    try w.writeByte('\n');
                    return;
                };
                const state: future_mod.FutureState = thunk.future.stateField(.acquire);
                try disasm.writeStoreRef(w, "objects", id, .object, "thunk", self.color_depth);
                try w.print(" · {s}", .{@tagName(state)});
                switch (state) {
                    .resolved => {
                        try w.writeAll(" → ");
                        try disasm.writeValueDigest(w, thunk.payload.result, symbols, 48, self.color_depth);
                        try w.writeByte('\n');
                    },
                    .errored => try w.writeAll(" (cached failure)\n"),
                    else => {
                        switch (thunk.targetKind()) {
                            .bytecode => {
                                try w.writeAll(" · ");
                                try disasm.writeStoreRef(w, "chunk", thunk.payload.target.bytecode.chunk_id, .chunk, "body", self.color_depth);
                                try w.writeAll(" — :vm it\n");
                            },
                            .closure => try w.writeAll(" (closure application)\n"),
                            .pass_through => try w.writeAll(" (pass-through cell)\n"),
                            .attr_access => try w.writeAll(" (attribute access)\n"),
                            .deferred => try w.writeAll(" (deferred compile — forced on first use)\n"),
                        }
                    },
                }
            },
            .closure => {
                if (value.isFunction()) {
                    const chunk_id = value.asFunctionChunkId();
                    try disasm.writeValueDigest(w, value, symbols, 48, self.color_depth);
                    if (self.ev.getChunk(chunk_id)) |chunk| try w.print(" · arity {d}", .{chunk.arity});
                    try w.writeAll(" — :vm it\n");
                    return;
                }
                const closure = self.ev.tooling().closure(value) catch {
                    try disasm.writeValueDigest(w, value, symbols, 48, self.color_depth);
                    try w.writeAll(" · unreadable\n");
                    return;
                };
                var arity: usize = 1;
                if (self.ev.getChunk(closure.chunk_id)) |chunk| arity = chunk.arity;
                try disasm.writeValueDigest(w, value, symbols, 48, self.color_depth);
                try w.writeAll(" → ");
                try disasm.writeStoreRef(w, "chunk", closure.chunk_id, .chunk, null, self.color_depth);
                try w.print(" · arity {d} · {d} upvalue{s} — :vm it\n", .{
                    arity,
                    closure.upvalues.len,
                    if (closure.upvalues.len == 1) "" else "s",
                });
            },
            .list => {
                try disasm.writeValueDigest(w, value, symbols, 48, self.color_depth);
                const n = self.ev.tooling().listLen(value) catch 0;
                try w.print(" ({d} item{s})\n", .{ n, if (n == 1) "" else "s" });
            },
            .attrs => {
                try disasm.writeValueDigest(w, value, symbols, 48, self.color_depth);
                const n2 = if (self.ev.tooling().attrs(value)) |entries| entries.len() else |_| 0;
                try w.print(" ({d} attr{s})\n", .{ n2, if (n2 == 1) "" else "s" });
            },
            else => {
                try disasm.writeValueDigest(w, value, symbols, 48, self.color_depth);
                try w.writeByte('\n');
            },
        }
    }

    fn focusForValue(self: *Repl, value: Value, entry_chunk: types.ChunkId) types.ChunkId {
        switch (value.kind()) {
            .closure => if (self.ev.tooling().closure(value)) |closure| {
                return closure.chunk_id;
            } else |_| {},
            .thunk => if (self.ev.tooling().thunk(value)) |thunk| {
                if (thunk.targetKind() == .bytecode) return thunk.payload.target.bytecode.chunk_id;
            } else |_| {},
            else => {},
        }
        return entry_chunk;
    }

    /// VM explorer command family. The TUI opens on the focused chunk when
    /// enabled; streaming and --no-tui sessions use bounded text queries.
    fn vm(self: *Repl, args_text: []const u8) !void {
        const text = std.mem.trim(u8, args_text, " \t");
        if (text.len == 0) return self.vmShow();

        const word_end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
        const word = text[0..word_end];
        const rest = std.mem.trim(u8, text[word_end..], " \t");
        if (!self.tui_enabled) {
            if (try self.vmPlainQuery(text)) return;
        }
        if (std.mem.eql(u8, word, "help") or
            std.mem.eql(u8, word, "?") or
            std.mem.eql(u8, word, "ls") or
            std.mem.eql(u8, word, "tree") or
            std.mem.eql(u8, word, "chunks") or
            std.mem.eql(u8, word, "objects") or
            std.mem.eql(u8, word, "object") or
            std.mem.eql(u8, word, "find") or
            std.mem.eql(u8, word, "search") or
            std.mem.eql(u8, word, "spans") or
            std.mem.eql(u8, word, "store") or
            std.mem.eql(u8, word, "record") or
            std.mem.eql(u8, word, "refs") or
            std.mem.eql(u8, word, "references") or
            std.mem.eql(u8, word, "break-at") or
            std.mem.eql(u8, word, "break") or
            std.mem.eql(u8, word, "clear-at") or
            std.mem.eql(u8, word, "unbreak") or
            std.mem.eql(u8, word, "breakpoints") or
            std.mem.eql(u8, word, "delete"))
        {
            _ = try self.vmPlainQuery(text);
            return;
        }
        if (std.mem.eql(u8, word, "heap")) return self.vmHeap();
        if (std.mem.eql(u8, word, "chunk") or std.mem.eql(u8, word, "code")) {
            if (rest.len > 0) {
                self.vm_focus = parseChunkId(rest) orelse {
                    try self.printError("expected a chunk id, got `{s}`", .{rest});
                    return;
                };
            }
            return self.vmShow();
        }
        const expr = if (std.mem.eql(u8, word, "eval")) rest else text;
        if (expr.len == 0) {
            try self.printError(":vm eval needs an expression", .{});
            return;
        }
        if (try self.evalExpr(expr) == null) return;
        try self.vmShow();
        try self.collectBetweenInputs();
    }

    fn vmShow(self: *Repl) !void {
        const chunk_id = self.vm_focus orelse {
            if (self.tui_enabled and !self.tui_active) {
                self.vm_heap_requested = false;
                self.vm_requested = true;
                return;
            }
            try self.printError("no VM focus yet — evaluate an expression or use `:vm chunk ID`", .{});
            return;
        };
        if (self.ev.getChunk(chunk_id) == null) {
            try self.printError("chunk[0x{x}] not found", .{chunk_id});
            return;
        }
        if (self.tui_active) return;
        if (self.tui_enabled) {
            self.vm_heap_requested = false;
            self.vm_requested = true;
        } else {
            var out = self.output();
            defer out.flush() catch {};
            var query = self.vmPlainContext(out.writer());
            try query.writeChunk(chunk_id);
        }
    }

    fn vmHeap(self: *Repl) !void {
        self.vm_heap_requested = true;
        if (!self.tui_active) self.vm_requested = true;
    }

    fn clearVmRuntime(self: *Repl) void {
        self.vm_queries.clearRuntime();
    }

    fn vmPlainContext(self: *Repl, writer: *std.Io.Writer) vm_plain.Context {
        return .{
            .allocator = self.allocator,
            .writer = writer,
            .ev = self.ev,
            .cache = &self.vm_queries,
            .color_depth = self.color_depth,
            .focused_chunk = self.vm_focus,
        };
    }

    fn vmPlainQuery(self: *Repl, text: []const u8) !bool {
        var out = self.output();
        defer out.flush() catch {};
        var query = self.vmPlainContext(out.writer());
        return query.execute(text);
    }

    // -- small output helpers ----------------------------------------------------

    const Output = union(enum) {
        capture: *std.Io.Writer,
        terminal: std.Io.File.Writer,

        fn writer(self: *Output) *std.Io.Writer {
            return switch (self.*) {
                .capture => |sink| sink,
                .terminal => |*terminal| &terminal.interface,
            };
        }

        fn flush(self: *Output) !void {
            try self.writer().flush();
        }
    };

    fn output(self: *Repl) Output {
        if (self.output_capture) |writer| return .{ .capture = writer };
        // A fresh short-lived buffered writer per print keeps interleaving
        // with the engine's own stdout writes (writeValue) safe.
        return .{ .terminal = std.Io.File.stdout().writerStreaming(self.io, &stdout_scratch) };
    }

    fn evalFailure(self: *Repl, source: []const u8, err: anyerror) !void {
        if (self.output_capture) |writer|
            return render_err.evalFailureTo(writer, self.use_color, self.options.show_trace, self.ev, source, err);
        return render_err.evalFailure(self.io, self.use_color, self.options.show_trace, self.ev, source, err);
    }

    fn evaluationError(self: *Repl, source: []const u8, err: anyerror) !void {
        if (self.output_capture) |writer|
            return render_err.evaluationErrorTo(writer, self.use_color, self.options.show_trace, self.ev, source, err);
        return render_err.evaluationError(self.io, self.use_color, self.options.show_trace, self.ev, source, err);
    }

    fn printError(self: *Repl, comptime fmt: []const u8, fmt_args: anytype) !void {
        if (self.output_capture) |w| {
            try render_err.messageErrorTo(w, self.use_color, fmt, fmt_args);
            return;
        }
        var stderr_buffer: [1024]u8 = undefined;
        var stderr = try presentation.lockStderr(self.io, &stderr_buffer);
        defer stderr.deinit();
        try render_err.messageErrorTo(stderr.writer(), self.use_color, fmt, fmt_args);
        try stderr.flush();
    }
};

/// Shared scratch for the repl's short-lived stdout writers (single-threaded).
var stdout_scratch: [8 * 1024]u8 = undefined;

// -- `name = expr` binding detection -----------------------------------------

const Binding = struct { name: []const u8, expr: []const u8 };

const nix_keywords = [_][]const u8{
    "let", "in", "if", "then", "else", "with", "rec", "inherit", "assert", "or",
};

fn parseChunkId(input: []const u8) ?types.ChunkId {
    return vm_plain.parseId(input);
}

/// Recognize a top-level `name = expr` binding (nix-repl style). The name
/// must be a plain identifier (not a keyword), the `=` must not begin `==`,
/// and the right side must be non-empty.
fn parseBinding(input: []const u8) ?Binding {
    var i: usize = 0;
    if (i >= input.len) return null;
    const first = input[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return null;
    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or
        input[i] == '_' or input[i] == '\'' or input[i] == '-')) : (i += 1)
    {}
    const name = input[0..i];
    for (nix_keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return null;
    }
    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
    if (i >= input.len or input[i] != '=') return null;
    i += 1;
    if (i < input.len and input[i] == '=') return null; // `a == b`
    const expr = std.mem.trim(u8, input[i..], " \t\r\n");
    if (expr.len == 0) return null;
    return .{ .name = name, .expr = expr };
}

test {
    _ = @import("../repl/keys.zig");
    _ = @import("../repl/width.zig");
    _ = @import("../repl/editor.zig");
    _ = @import("../repl/render.zig");
    _ = @import("../repl/line_input.zig");
    _ = @import("../repl/history.zig");
    _ = @import("../repl/check.zig");
    _ = @import("../repl/commands.zig");
    _ = @import("../repl/complete.zig");
    _ = @import("../repl/vm/root.zig");
    _ = @import("../repl/transcript.zig");
}

const testing = std.testing;

test "parseBinding recognizes bindings, rejects comparisons and keywords" {
    const b = parseBinding("x = 1 + 2").?;
    try testing.expectEqualStrings("x", b.name);
    try testing.expectEqualStrings("1 + 2", b.expr);

    const c = parseBinding("foo-bar' = { }").?;
    try testing.expectEqualStrings("foo-bar'", c.name);

    try testing.expect(parseBinding("x == 1") == null);
    try testing.expect(parseBinding("let = 1") == null);
    try testing.expect(parseBinding("1 = 2") == null);
    try testing.expect(parseBinding("x =") == null);
    try testing.expect(parseBinding("{ a = 1; }") == null);
    try testing.expect(parseBinding("x.y = 1") == null); // attr path: not a plain binding
}

test "parseChunkId accepts explorer display forms" {
    try testing.expectEqual(@as(?types.ChunkId, 42), parseChunkId("42"));
    try testing.expectEqual(@as(?types.ChunkId, 42), parseChunkId("#42"));
    try testing.expectEqual(@as(?types.ChunkId, 42), parseChunkId("#0x2a"));
    try testing.expectEqual(@as(?types.ChunkId, 42), parseChunkId("chunk[0x2a]"));
    try testing.expect(parseChunkId("nope") == null);
}

// The repl subtree's test aggregator: this file is the subtree's entry point,
// so the CLI root reaches every repl file through it.
test {
    _ = @import("check.zig");
    _ = @import("commands.zig");
    _ = @import("complete.zig");
    _ = @import("editor.zig");
    _ = @import("history.zig");
    _ = @import("keys.zig");
    _ = @import("line_input.zig");
    _ = @import("render.zig");
    _ = @import("scope.zig");
    _ = @import("term.zig");
    _ = @import("transcript.zig");
    _ = @import("width.zig");
    _ = @import("vm/root.zig");
}
