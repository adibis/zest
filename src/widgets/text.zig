//! Single-line text renderer with right-edge truncation.
//!
//! Text.draw() renders one line of text at row 0 of the given window.
//! Characters beyond the window width are silently dropped. The caller
//! resolves semantic Style via theme.resolve() before passing it here.

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("../core/theme.zig");

pub const Text = struct {
    /// Renders text at row 0 of win, truncated at the right edge.
    /// style is a Style(C) value; theme is a Theme(C) value — C is inferred.
    pub fn draw(win: vaxis.Window, text: []const u8, style: anytype, theme: anytype) void {
        _ = win.print(
            &.{.{ .text = text, .style = theme.resolve(style) }},
            .{ .wrap = .none },
        );
    }
};

// --- helpers -----------------------------------------------------------------

fn makeWin(screen: *vaxis.Screen, w: u16, h: u16) vaxis.Window {
    return .{
        .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0,
        .width = w, .height = h, .screen = screen,
    };
}

// --- tests -------------------------------------------------------------------

const Color = theme_mod.Color;
const Style = theme_mod.Style;
const dark  = theme_mod.dark;

test "Text.draw: renders all chars when text fits in window" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 1);

    Text.draw(win, "hello", Style(Color){}, dark);

    try std.testing.expectEqualStrings("h", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("e", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("l", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("l", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("o", screen.readCell(4, 0).?.char.grapheme);
}

test "Text.draw: does not write past window width" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    // Window is 3 wide but screen is 10 wide — chars 3+ must stay default.
    const win = makeWin(&screen, 3, 1);

    Text.draw(win, "hello", Style(Color){}, dark);

    try std.testing.expectEqualStrings("h", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("e", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("l", screen.readCell(2, 0).?.char.grapheme);
    // Cols 3–9 were never written — Screen.init fills with default Cell (.char = " ").
    try std.testing.expectEqualStrings(" ", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(4, 0).?.char.grapheme);
}

test "Text.draw: empty string leaves cells at their default" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 5, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 5, 1);

    Text.draw(win, "", Style(Color){}, dark);

    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "Text.draw: resolves and applies style to written cells" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 5, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 5, 1);

    Text.draw(win, "hi", Style(Color){ .text = .{ .bold = true } }, dark);

    try std.testing.expect(screen.readCell(0, 0).?.style.bold);
    try std.testing.expect(screen.readCell(1, 0).?.style.bold);
    // Unwritten cells carry no style.
    try std.testing.expect(!screen.readCell(2, 0).?.style.bold);
}

test "Text.draw: wide char col advances by display width" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 1);

    // "中" is a 2-wide CJK character; "X" follows at col 2.
    Text.draw(win, "中X", Style(Color){}, dark);

    try std.testing.expectEqualStrings("中", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("X", screen.readCell(2, 0).?.char.grapheme);
}
