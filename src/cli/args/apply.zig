//! Mutation boundary that folds one parsed option value into `Options`.

const std = @import("std");
const presentation = @import("../presentation.zig");
const engine = @import("expr");
const hugetlb = @import("base").hugetlb;
const features = @import("features.zig");

pub fn apply(
    comptime Options: type,
    comptime Opt: type,
    options: *Options,
    allocator: std.mem.Allocator,
    id: Opt,
    v0: ?[:0]const u8,
    v1: ?[:0]const u8,
) !void {
    switch (id) {
        .expr => try options.addSource(allocator, .{ .expr = v0.? }),
        .file => try options.addSource(allocator, .{ .file = v0.? }),
        .flake => try options.addSource(allocator, .{ .flake = v0.? }),
        .include => try options.include.append(allocator, v0.?),
        .attr => {
            try options.attrs.append(allocator, v0.?);
            options.attr = v0.?;
        },
        .arg => try options.arg_defs.append(allocator, .{ .name = v0.?, .value = v1.?, .is_string = false }),
        .argstr => try options.arg_defs.append(allocator, .{ .name = v0.?, .value = v1.?, .is_string = true }),
        .json => options.output = .json,
        .raw => options.output = .raw,
        .xml => options.output = .xml,
        .no_location => options.no_location = true,
        .impure => options.impure = true,
        .strict => options.strict = true,
        .read_write_mode => options.read_write_mode = true,
        .experimental_features => {
            options.experimental_features = .{};
            options.experimental_features_reset = true;
            try features.parseExperimentalList(&options.experimental_features, v0.?);
        },
        .extra_experimental_features => try features.parseExperimentalList(&options.experimental_features, v0.?),
        .deprecated_features => {
            options.deprecated_features = .{};
            options.deprecated_features_reset = true;
            features.parseDeprecatedList(&options.deprecated_features, v0.?);
        },
        .extra_deprecated_features => features.parseDeprecatedList(&options.deprecated_features, v0.?),
        .option => try options.option_overrides.append(allocator, .{ .name = v0.?, .value = v1.? }),
        .no_link => options.no_link = true,
        .dry_run => options.dry_run = true,
        .find_file => options.find_file = true,
        .no_build_output => options.no_build_output = true,
        .out_link => options.out_link = v0.?,
        .drv_link => options.drv_link = v0.?,
        .add_drv_link => options.add_drv_link = true,
        .add_root => options.add_root = v0.?,
        .indirect => options.indirect = true,
        .check => options.check = true,
        .repair => options.repair = true,
        .max_jobs => {
            const value = v0.?;
            if (!std.mem.eql(u8, value, "auto"))
                _ = std.fmt.parseInt(u64, value, 10) catch return error.InvalidMaxJobs;
            try options.option_overrides.append(allocator, .{ .name = "max-jobs", .value = value });
        },
        .cores => {
            const value = v0.?;
            _ = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCores;
            try options.option_overrides.append(allocator, .{ .name = "cores", .value = value });
        },
        .max_silent_time => try options.option_overrides.append(allocator, .{ .name = "max-silent-time", .value = v0.? }),
        .timeout => try options.option_overrides.append(allocator, .{ .name = "timeout", .value = v0.? }),
        .store => try options.option_overrides.append(allocator, .{ .name = "store", .value = v0.? }),
        .fallback => try options.option_overrides.append(allocator, .{ .name = "fallback", .value = "true" }),
        .keep_failed => try options.option_overrides.append(allocator, .{ .name = "keep-failed", .value = "true" }),
        .keep_going => try options.option_overrides.append(allocator, .{ .name = "keep-going", .value = "true" }),
        .verbose => options.verbose +|= 1,
        .show_trace => options.show_trace = true,
        .no_show_trace => options.show_trace = false,
        .debugger => options.debugger = true,
        .color => options.color = if (v0) |value| (presentation.parseWhen(value) orelse return error.InvalidColorMode) else .always,
        .no_color => options.color = .never,
        .progress => options.progress = .enabled,
        .no_progress => options.progress = .disabled,
        .gc_budget => options.gc_budget = engine.parseMemorySize(v0.?) orelse return error.InvalidGcBudget,
        .hugetlb => options.hugetlb = hugetlb.parseMode(v0.?) orelse return error.InvalidHugetlbMode,
        .help => return error.Help,
        .no_tui => options.no_tui = true,
        .packages => unreachable,
        .nixos => options.switch_target = .nixos,
        .darwin => options.switch_target = .darwin,
        .home_manager => options.switch_target = .home_manager,
        .activate_toplevel => options.activate_toplevel = v0.?,
        .chunk => options.disasm_chunk = std.fmt.parseInt(u32, v0.?, 0) catch return error.InvalidChunkId,
        .no_recurse => options.disasm_no_recurse = true,
        .no_source => options.disasm_no_source = true,
        .no_constants => options.disasm_no_constants = true,
        .no_bytes => options.disasm_no_bytes = true,
        .no_pager => options.disasm_no_pager = true,
        .disasm_eval => options.disasm_eval = true,
        .stats => options.stats = true,
        .no_compile_cache => options.no_compile_cache = true,
        .compile_cache_dir => options.compile_cache_dir = v0.?,
        .workers => options.workers = std.fmt.parseInt(u8, v0.?, 10) catch return error.InvalidWorkers,
        .vm_trace => options.vm_trace_path = v0 orelse "-",
        .vm_trace_format => options.vm_trace_format = parseVmTraceFormat(Options, v0.?) orelse return error.InvalidVmTraceFormat,
        .vm_trace_max_events => options.vm_trace_max_events = std.fmt.parseInt(u64, v0.?, 10) catch return error.InvalidVmTraceMaxEvents,
        .vm_trace_main_only => options.vm_trace_main_only = true,
        .thunks_log => options.thunks_log_path = v0.?,
        .no_spec_thunks => options.disable_spec_thunks = true,
        .no_fanout => options.disable_fanout = true,
        .mem_report => options.mem_report = v0 orelse "",
        .gc_report => options.gc_report = true,
        .timeline => options.timeline_path = v0 orelse "fix-timeline.json",
        .timeline_flows => {
            const value = v0.?;
            options.timeline_flows = if (std.mem.eql(u8, value, "off"))
                false
            else if (std.mem.eql(u8, value, "all"))
                true
            else
                return error.InvalidTimelineFlows;
        },
    }
}

fn parseVmTraceFormat(comptime Options: type, text: []const u8) ?@TypeOf(@as(Options, undefined).vm_trace_format) {
    if (std.mem.eql(u8, text, "binary")) return .binary;
    if (std.mem.eql(u8, text, "text")) return .text;
    return null;
}
