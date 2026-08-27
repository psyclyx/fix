//! One-line modal input used by VM explorer search and filtering.

const std = @import("std");
const presentation = @import("../../presentation.zig");
const term = @import("../term.zig");
const keys = @import("../keys.zig");
const width = @import("../width.zig");
const tui = @import("base").tui;

pub const Result = enum { submitted, cancelled, eof };

pub fn read(
    allocator: std.mem.Allocator,
    io: std.Io,
    color_depth: presentation.ColorDepth,
    label: []const u8,
    text: *std.ArrayListUnmanaged(u8),
) !Result {
    var out_buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    const writer = &out.interface;
    var decoder = keys.Decoder{};
    var events: keys.Decoder.List = .empty;
    defer events.deinit(allocator);
    var read_buffer: [64]u8 = undefined;

    while (true) {
        const size = term.size();
        var frame = tui.Frame.init(writer, color_depth, width.cpWidth);
        try frame.clearRow(size.rows);
        try frame.at(size.rows, 1);
        var line_buffer: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buffer, "{s}{s}", .{ label, text.items }) catch label;
        try frame.text(line, 0, size.cols, .section);
        try writer.flush();

        const input = term.readInput(&read_buffer, if (decoder.wantsMore()) 40 else -1);
        events.clearRetainingCapacity();
        switch (input) {
            .timeout => try decoder.idleFlush(allocator, &events),
            .winch => continue,
            .eof => return .eof,
            .data => |count| for (read_buffer[0..count]) |byte|
                try decoder.feed(allocator, byte, &events),
        }
        for (events.items) |key| switch (key.code) {
            .enter => return .submitted,
            .escape => return .cancelled,
            .backspace => removeLastCodepoint(text),
            .cp => |codepoint| {
                if (key.isCtrl('g') or key.isCtrl('c')) return .cancelled;
                if (codepoint >= 0x20 and codepoint != 0x7f) {
                    var utf8: [4]u8 = undefined;
                    const count = std.unicode.utf8Encode(codepoint, &utf8) catch continue;
                    try text.appendSlice(allocator, utf8[0..count]);
                }
            },
            else => {},
        };
    }
}

fn removeLastCodepoint(text: *std.ArrayListUnmanaged(u8)) void {
    if (text.items.len == 0) return;
    // Walk back off the continuation bytes onto the lead byte, so a multi-byte
    // codepoint leaves no orphaned lead behind.
    var len = text.items.len - 1;
    while (len > 0 and text.items[len] & 0xc0 == 0x80) len -= 1;
    text.items.len = len;
}

test "backspace removes one UTF-8 codepoint" {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "aλ");
    removeLastCodepoint(&text);
    try std.testing.expectEqualStrings("a", text.items);
}
