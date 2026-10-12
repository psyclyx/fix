//! Terminal control for the interactive repl: raw mode with paranoid
//! restore, window-size tracking (SIGWINCH), suspend/resume, and the
//! input read loop primitive.
//!
//! Restore discipline: the saved termios lives in a module global that a
//! fatal-signal handler (installed while raw mode is active) restores before
//! chaining to the previous handler — so a panic (SIGABRT), a segfault, or a
//! kill -TERM never leaves the terminal raw. Orderly exits restore via
//! `disableRaw` in the caller's defer.

const std = @import("std");
const posix = std.posix;

/// Original termios, saved while raw mode is active. Global on purpose:
/// the signal handler must reach it without a context pointer.
var saved_termios: ?posix.termios = null;

/// Whether another full-screen surface currently owns raw terminal mode.
/// Nested surfaces (the debugger entered from `:vm`) borrow that ownership
/// instead of saving an already-raw termios as if it were the original.
pub fn rawActive() bool {
    return saved_termios != null;
}

/// SIGWINCH arrived since the last size query.
var winch_flag = std.atomic.Value(bool).init(false);

var handlers_installed = false;
/// Previous dispositions for the fatal signals we hook, so the handler can
/// chain (e.g. to zig's segfault trace printer) after restoring the tty.
const hooked_signals = [_]posix.SIG{ .SEGV, .BUS, .ILL, .FPE, .ABRT, .TERM, .QUIT, .HUP, .INT };
var prev_actions: [hooked_signals.len]posix.Sigaction = undefined;

pub const stdin_fd: posix.fd_t = posix.STDIN_FILENO;

pub const Size = struct { cols: usize, rows: usize };

/// Terminal size via TIOCGWINSZ, with an 80x24 fallback.
pub fn size() Size {
    var ws: posix.winsize = undefined;
    // Route through the per-OS backend (linux syscall / libc) so TIOCGWINSZ
    // works on Darwin too.
    const rc = posix.system.ioctl(posix.STDOUT_FILENO, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) == .SUCCESS and ws.col > 0 and ws.row > 0) {
        return .{ .cols = ws.col, .rows = ws.row };
    }
    return .{ .cols = 80, .rows = 24 };
}

/// Consume the pending resize notification, if any.
pub fn takeWinch() bool {
    return winch_flag.swap(false, .acq_rel);
}

fn restoreTermiosRaw() void {
    if (saved_termios) |orig| {
        posix.tcsetattr(stdin_fd, .DRAIN, orig) catch {};
    }
}

fn fatalHandler(sig: posix.SIG) callconv(.c) void {
    // Restore the terminal first — that's the whole point.
    restoreTermiosRaw();
    // Chain to the previous handler (zig's trace printer, or default).
    for (hooked_signals, 0..) |s, i| {
        if (s == sig) {
            posix.sigaction(sig, &prev_actions[i], null);
            break;
        }
    }
    _ = posix.raise(sig) catch {};
}

fn winchHandler(_: posix.SIG) callconv(.c) void {
    winch_flag.store(true, .release);
}

fn installHandlers() void {
    if (handlers_installed) return;
    handlers_installed = true;

    const fatal_action: posix.Sigaction = .{
        .handler = .{ .handler = fatalHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (hooked_signals, 0..) |sig, i| {
        posix.sigaction(sig, &fatal_action, &prev_actions[i]);
    }

    // No SA_RESTART: a resize must interrupt the blocking read.
    const winch_action: posix.Sigaction = .{
        .handler = .{ .handler = winchHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.WINCH, &winch_action, null);
}

pub const RawMode = struct {
    active: bool = false,

    /// Enter raw mode on stdin. Keeps OPOST (output post-processing) on, so
    /// '\n' still writes as CRLF; turns off ISIG so ^C/^Z arrive as bytes.
    /// TCSADRAIN (not FLUSH) everywhere: type-ahead entered while an
    /// evaluation was still printing must survive the mode switch.
    pub fn enable() !RawMode {
        const orig = try posix.tcgetattr(stdin_fd);
        installHandlers();

        const raw = rawTermios(orig);
        try posix.tcsetattr(stdin_fd, .DRAIN, raw);
        saved_termios = orig;
        return .{ .active = true };
    }

    pub fn disable(self: *RawMode) void {
        if (!self.active) return;
        self.active = false;
        restoreTermiosRaw();
        saved_termios = null;
    }

    /// Ctrl-Z: restore the terminal, actually stop, re-enter raw on SIGCONT.
    pub fn suspendProcess(self: *RawMode) void {
        const orig = saved_termios;
        self.disable();
        const dfl: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(.TSTP, &dfl, null);
        posix.raise(.TSTP) catch {};
        // …stopped; resumed here on SIGCONT.
        if (orig) |o| {
            const raw = rawTermios(o);
            posix.tcsetattr(stdin_fd, .DRAIN, raw) catch {};
            saved_termios = o;
            self.active = true;
        }
    }
};

fn rawTermios(orig: posix.termios) posix.termios {
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    return raw;
}

/// Temporarily put an already-owned raw terminal back into its original
/// cooked state without releasing `RawMode`'s restore/fatal-signal contract.
/// The debugger uses this for its nested line-oriented prompt, then returns
/// control to the full-screen REPL and re-enters the exact same raw mode.
pub const CookedPause = struct {
    active: bool = false,

    pub fn begin() CookedPause {
        const orig = saved_termios orelse return .{};
        posix.tcsetattr(stdin_fd, .DRAIN, orig) catch return .{};
        return .{ .active = true };
    }

    pub fn end(self: *CookedPause) void {
        if (!self.active) return;
        self.active = false;
        const orig = saved_termios orelse return;
        posix.tcsetattr(stdin_fd, .DRAIN, rawTermios(orig)) catch {};
    }
};

pub const ReadResult = union(enum) {
    /// `n` bytes were read into the caller's buffer.
    data: usize,
    timeout,
    /// The window was resized (read interrupted or pending flag).
    winch,
    eof,
};

/// Read whatever input is available (blocking, or up to `timeout_ms` when
/// >= 0). Resize signals surface as `.winch` rather than being swallowed. We
/// call the raw per-OS backend (`posix.system.poll`/`read`, portable across
/// Linux and Darwin) rather than the `std.posix.poll`/`read` wrappers,
/// because those retry EINTR internally and would sit blocked through a
/// resize instead of letting the SIGWINCH handler's flag surface.
pub fn readInput(buf: []u8, timeout_ms: i32) ReadResult {
    if (takeWinch()) return .winch;
    while (true) {
        var fds = [_]posix.pollfd{.{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 }};
        const prc = posix.system.poll(&fds, 1, timeout_ms);
        switch (posix.errno(prc)) {
            .SUCCESS => {
                if (prc == 0) return .timeout;
            },
            .INTR => {
                if (takeWinch()) return .winch;
                continue;
            },
            else => return .eof,
        }
        const rc = posix.system.read(stdin_fd, buf.ptr, buf.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return .eof;
                return .{ .data = @intCast(rc) };
            },
            .INTR => {
                if (takeWinch()) return .winch;
                continue;
            },
            .AGAIN => continue,
            else => return .eof,
        }
    }
}
