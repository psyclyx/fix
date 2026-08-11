//! Generic timestamped observation records for the CLI.

const std = @import("std");
const observ = @import("base").observ;
const engine = @import("expr");
const Engine = engine.Engine;
const Timeline = engine.probe.timeline.Recorder;
const terminal_text = @import("base").terminal_text;
const args = @import("args.zig");
const presentation = @import("presentation.zig");
const setup = @import("setup.zig");

pub const EvalProgress = struct {
    io: std.Io,
    started_at: std.Io.Timestamp,
    cwd: []const u8,
    color_depth: presentation.ColorDepth,
    log_progress: bool,
    verbosity: u8,
    timeline: ?*Timeline = null,

    pub fn init(io: std.Io, cwd: []const u8, log_progress: bool, color_depth: presentation.ColorDepth, verbosity: u8) EvalProgress {
        return .{
            .io = io,
            .started_at = std.Io.Clock.awake.now(io),
            .cwd = cwd,
            .color_depth = color_depth,
            .log_progress = log_progress,
            .verbosity = verbosity,
        };
    }

    pub fn deinit(_: *EvalProgress, _: bool) void {}

    pub fn setTimeline(self: *EvalProgress, timeline: *Timeline) void {
        self.timeline = timeline;
    }

    pub fn observer(self: *EvalProgress) observ.Observer {
        return .{
            .sink = .{
                .context = self,
                .begin_fn = beginSpan,
                .finish_fn = finishSpan,
                .update_fn = updateSpan,
                .event_fn = writeEvent,
                .counter_fn = writeCounter,
                .next_flow_id_fn = nextFlowId,
                .flow_fn = writeFlow,
                .sample_fn = shouldSample,
            },
            .verbosity = self.verbosity,
            .log_enabled = self.log_progress,
            .profile_enabled = self.timeline != null,
            .capture_updates = self.timeline != null,
        };
    }

    pub fn writeLogPrefix(self: *EvalProgress, writer: *std.Io.Writer, tag: []const u8) !void {
        return presentation.writeLogPrefix(writer, self.io, self.color_depth, self.started_at, tag);
    }

    pub fn logNoun(self: *const EvalProgress, subject: []const u8) []const u8 {
        return presentation.logNoun(self.cwd, subject);
    }

    fn beginSpan(
        raw: *anyopaque,
        spec: *const observ.SpanSpec,
        details: observ.Details,
        track: observ.Track,
        interest: observ.Interest,
    ) usize {
        const self: *EvalProgress = @ptrCast(@alignCast(raw));
        if (interest.log_begin) self.writeRecord(spec.category, spec.name, spec.begin_verb, details, &.{}, false);
        if (interest.profile) return self.timeline.?.begin(spec, details, track);
        return 0;
    }

    fn finishSpan(
        raw: *anyopaque,
        token: usize,
        spec: *const observ.SpanSpec,
        started: observ.Details,
        _: observ.Track,
        interest: observ.Interest,
        completion: observ.Finish,
        success: bool,
    ) void {
        const self: *EvalProgress = @ptrCast(@alignCast(raw));
        if (interest.profile) self.timeline.?.finish(token, spec, completion, success);
        if (!interest.log_finish or (!success and completion.verb == null)) return;
        self.writeRecord(
            spec.category,
            spec.name,
            completion.verb orelse spec.finish_verb,
            completion.details orelse started,
            completion.metrics,
            !success,
        );
    }

    fn updateSpan(raw: *anyopaque, token: usize, spec: *const observ.SpanSpec, interest: observ.Interest, metrics: []const observ.Metric) void {
        if (!interest.profile) return;
        const self: *EvalProgress = @ptrCast(@alignCast(raw));
        self.timeline.?.update(token, spec, metrics);
    }

    fn writeEvent(
        raw: *anyopaque,
        spec: *const observ.EventSpec,
        details: observ.Details,
        track: observ.Track,
        interest: observ.Interest,
        metrics: []const observ.Metric,
    ) void {
        const self: *EvalProgress = @ptrCast(@alignCast(raw));
        if (interest.profile) self.timeline.?.instant(spec, details, track, metrics);
        if (!interest.log_finish) return;
        self.writeRecord(spec.category, spec.name, spec.verb, details, metrics, false);
    }

    fn writeCounter(raw: *anyopaque, spec: *const observ.CounterSpec, track: observ.Track, metrics: []const observ.Metric) void {
        const self: *EvalProgress = @ptrCast(@alignCast(raw));
        self.timeline.?.counter(spec, track, metrics);
    }

    fn nextFlowId(raw: *anyopaque) u64 {
        const self: *EvalProgress = @ptrCast(@alignCast(raw));
        return self.timeline.?.nextFlowId();
    }

    fn writeFlow(raw: *anyopaque, spec: *const observ.FlowSpec, id: u64, phase: observ.FlowPhase, track: observ.Track, at_ns: u64) void {
        const self: *EvalProgress = @ptrCast(@alignCast(raw));
        self.timeline.?.flow(spec, id, phase, track, at_ns);
    }

    fn shouldSample(raw: *anyopaque, min_gap_ns: u64) bool {
        const self: *EvalProgress = @ptrCast(@alignCast(raw));
        return self.timeline.?.shouldSample(min_gap_ns);
    }

    fn writeRecord(
        self: *EvalProgress,
        category: []const u8,
        identity: []const u8,
        verb: []const u8,
        details: observ.Details,
        metrics: []const observ.Metric,
        is_error: bool,
    ) void {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = presentation.lockStderr(self.io, &stderr_buffer) catch return;
        defer stderr.deinit();
        const writer = stderr.writer();

        const use_color = self.color_depth.enabled();
        presentation.reset(writer, use_color) catch return;
        defer {
            presentation.reset(writer, use_color) catch {};
            stderr.flush() catch {};
        }
        self.writeLogPrefix(writer, category) catch return;
        if (is_error)
            presentation.style(writer, use_color, .error_label) catch return
        else
            presentation.foreground(writer, self.color_depth, presentation.nounColor(identity), false) catch return;
        writer.writeAll(verb) catch return;
        presentation.reset(writer, use_color) catch return;
        self.writeSubject(writer, details.subject) catch return;
        switch (details.destination) {
            .none => {},
            else => {
                writer.writeAll(" ->") catch return;
                self.writeSubject(writer, details.destination) catch return;
            },
        }
        for (metrics) |metric| self.writeMetric(writer, metric) catch return;
        writer.writeByte('\n') catch return;
    }

    fn writeSubject(self: *EvalProgress, writer: *std.Io.Writer, subject: observ.Subject) !void {
        const raw = subject.bytes();
        if (raw.len == 0) return;
        const noun = switch (subject) {
            .path => self.logNoun(raw),
            else => raw,
        };
        var buffer: [1024]u8 = undefined;
        const copied_len = @min(noun.len, buffer.len);
        @memcpy(buffer[0..copied_len], noun[0..copied_len]);
        const clean = terminal_text.stripAnsiInPlace(buffer[0..copied_len]);
        try writer.writeByte(' ');
        try presentation.foreground(writer, self.color_depth, presentation.nounColor(clean), true);
        try writer.writeAll(clean);
        try presentation.reset(writer, self.color_depth.enabled());
    }

    fn writeMetric(_: *EvalProgress, writer: *std.Io.Writer, metric: observ.Metric) !void {
        try writer.print(" {s}=", .{metric.name});
        switch (metric.value) {
            .unsigned => |value| try writer.print("{d}", .{value}),
            .signed => |value| try writer.print("{d}", .{value}),
            .float => |value| try writer.print("{d:.2}", .{value}),
            .text => |value| try writer.writeAll(value),
        }
        switch (metric.unit) {
            .none => {},
            .items => try writer.writeAll(" items"),
            .bytes => try writer.writeAll(" B"),
            .nanoseconds => try writer.writeAll(" ns"),
        }
    }
};

/// Owns the terminal renderer and optional Perfetto sink for one command.
/// Keeping this at the CLI boundary makes installing an evaluator observer a
/// single local operation and lets build keep recording daemon spans after the
/// language evaluator has released its memory.
pub const Session = struct {
    ev: *Engine,
    io: std.Io,
    progress: EvalProgress,
    timeline: ?Timeline = null,
    timeline_path: ?[]const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        ev: *Engine,
        terminal: setup.Terminal,
        options: *const args.Options,
        source: []const u8,
    ) !Session {
        var session: Session = .{
            .ev = ev,
            .io = io,
            .progress = EvalProgress.init(io, ev.basePath() orelse "", terminal.log_progress, terminal.color_depth, options.verbose),
            .timeline_path = options.timeline_path,
        };
        if (options.timeline_path != null) {
            // Event budget: 8M slots (~6M primary + ~2M steal flows). Was 2M;
            // multi-worker NixOS evals filled that and dropped later samples.
            session.timeline = try Timeline.init(allocator, ev.workerCount(), 1 << 23, ev.internTable());
            session.timeline.?.setFlows(options.timeline_flows);
            session.timeline.?.setSource(source);
            ev.setTraceFlows(options.timeline_flows);
        }
        return session;
    }

    /// Call after the returned session is in its final stack location, so the
    /// observer can safely retain pointers into it.
    pub fn install(self: *Session) void {
        if (self.timeline) |*recorder| {
            self.progress.setTimeline(recorder);
        }
        if (self.progress.log_progress or self.timeline != null)
            self.ev.setObserver(self.progress.observer());
    }

    pub fn renderer(self: *Session) *EvalProgress {
        return &self.progress;
    }

    pub fn deinit(self: *Session, success: bool) void {
        // Detach because the evaluator can outlive this command-local progress
        // frame. Engine/build-session ownership decides when evaluation ends.
        self.ev.setObserver(.{});
        self.progress.deinit(success);
        if (self.timeline_path) |path| self.timeline.?.dump(self.io, path);
        if (self.timeline) |*recorder| recorder.deinit();
    }
};

test "observer verbosity separates span openings from completions" {
    const spec: observ.SpanSpec = .{
        .category = "eval",
        .name = "parse",
        .begin_verb = "parsing",
        .finish_verb = "parsed",
        .begin_level = 3,
        .finish_level = 2,
    };
    var progress = EvalProgress.init(std.testing.io, "", true, .none, 2);
    const observer = progress.observer();
    var span = observer.begin(&spec, .{});
    try std.testing.expect(span.active());
    try std.testing.expect(!span.interest.log_begin);
    try std.testing.expect(span.interest.log_finish);
    span.cancel();
}
