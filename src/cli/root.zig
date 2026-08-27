//! `fix` command-line application boundary.

pub const commands = @import("commands/root.zig");
pub const command_match = @import("command_match.zig");
pub const command_meta = @import("command_meta.zig");
pub const presentation = @import("presentation.zig");
pub const render = @import("render.zig");
pub const ProcessContext = @import("process_context.zig").ProcessContext;
/// `fix --version` line: release version from build.zig.zon plus the Nix
/// language baseline that `builtins.nixVersion` reports.
pub const version_line = "fix " ++ @import("build_options").version ++
    " (Nix language compatibility " ++ @import("runtime").builtins.nix_compat_version ++ ")";
pub const thunks_log_enabled = @import("expr").vm.thunks_log_enabled;
pub const vm_trace_enabled = @import("expr").vm.trace_log.enabled;

test {
    _ = commands;
    _ = command_match;
    _ = command_meta;
    _ = @import("args.zig");
    _ = @import("build_progress.zig");
    _ = @import("completions/command.zig");
    _ = @import("debugger.zig");
    _ = @import("debugger_command.zig");
    _ = @import("eval_support.zig");
    _ = @import("effect_output.zig");
    _ = @import("config_discovery.zig");
    _ = @import("parse_json.zig");
    _ = @import("fileish.zig");
    _ = @import("nix_conf.zig");
    _ = presentation;
    _ = @import("progress.zig");
    _ = @import("realize.zig");
    _ = @import("render.zig");
    _ = @import("repl/command.zig");
    _ = @import("setup.zig");
    _ = @import("source_render.zig");
    _ = @import("stats.zig");
    _ = @import("thunks/diff.zig");
    _ = @import("trace_setup.zig");
}
