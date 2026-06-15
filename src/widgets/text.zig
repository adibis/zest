//! Single-line text renderer with right-edge truncation.
//!
//! Text.draw() renders one line at the position resolved by opts.anchor.
//! Default anchor is left/top. Content wider than the window degrades to
//! left-aligned and is truncated at the right edge.

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("../core/theme.zig");

pub const Anchor = @import("../core/anchor.zig").Anchor;

pub const DrawOpts = struct {
    /// Where in the window the text sits. Defaults to left/top — the
    /// universal "write a string starting here" behavior.
    anchor: Anchor = .{},
};

pub const Text = struct {
    /// Renders text at the anchor resolved within win.
    /// style is a Style(C) value; theme is a Theme(C) value — C is inferred.
    /// opts carries draw-time hints; pass `.{}` to keep all defaults.
    ///
    /// opts is the home for properties of where content sits within an
    /// already-sized window (anchor, future padding/wrap). It does not
    /// carry style, data, or per-frame state — those are positional.
    pub fn draw(
        win:   vaxis.Window,
        text:  []const u8,
        style: anytype,
        theme: anytype,
        opts:  DrawOpts,
    ) void {
        const resolved_style = theme.resolve(style);
        // Fast path: the universal left/top default skips the measurement
        // entirely (no offset needed). Non-default alignment measures via
        // gwidth and lets anchor.resolve handle overflow.
        if (opts.anchor.horizontal == .left and opts.anchor.vertical == .top) {
            _ = win.print(
                &.{.{ .text = text, .style = resolved_style }},
                .{ .wrap = .none },
            );
            return;
        }
        const content_w = win.gwidth(text);
        const off = opts.anchor.resolve(win.width, win.height, content_w, 1);
        _ = win.print(
            &.{.{ .text = text, .style = resolved_style }},
            .{ .wrap = .none, .col_offset = off.col, .row_offset = off.row },
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

const Color          = theme_mod.Color;
const Style          = theme_mod.Style;
const catppuccin_mocha = theme_mod.catppuccin_mocha;

test "Text.draw: renders all chars when text fits in window" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 1);

    Text.draw(win, "hello", Style(Color){}, catppuccin_mocha, .{});

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

    Text.draw(win, "hello", Style(Color){}, catppuccin_mocha, .{});

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

    Text.draw(win, "", Style(Color){}, catppuccin_mocha, .{});

    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "Text.draw: resolves and applies style to written cells" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 5, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 5, 1);

    Text.draw(win, "hi", Style(Color){ .text = .{ .bold = true } }, catppuccin_mocha, .{});

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
    Text.draw(win, "中X", Style(Color){}, catppuccin_mocha, .{});

    try std.testing.expectEqualStrings("中", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("X", screen.readCell(2, 0).?.char.grapheme);
}

test "Text.draw: anchor center places text at the horizontal middle" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 1);

    // "hi" is 2 wide, window is 10 wide → offset = (10 - 2) / 2 = 4
    Text.draw(win, "hi", Style(Color){}, catppuccin_mocha,
        .{ .anchor = .{ .horizontal = .center } });

    try std.testing.expectEqualStrings(" ", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("h", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("i", screen.readCell(5, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(6, 0).?.char.grapheme);
}

test "Text.draw: anchor right places text flush with the right edge" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 1);

    // "hi" at col 8 (10 - 2)
    Text.draw(win, "hi", Style(Color){}, catppuccin_mocha,
        .{ .anchor = .{ .horizontal = .right } });

    try std.testing.expectEqualStrings(" ", screen.readCell(7, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("h", screen.readCell(8, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("i", screen.readCell(9, 0).?.char.grapheme);
}

test "Text.draw: anchor middle vertical places text at the middle row" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 5, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 5);

    // Single-row text in a 5-row window → row 2 ((5 - 1) / 2)
    Text.draw(win, "hi", Style(Color){}, catppuccin_mocha,
        .{ .anchor = .{ .vertical = .middle } });

    try std.testing.expectEqualStrings(" ", screen.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("h", screen.readCell(0, 2).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 3).?.char.grapheme);
}

test "Text.draw: text wider than window degrades to left and truncates" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);

    // "centered" is 8 wide, window is 4 — center degrades to left, truncates.
    Text.draw(win, "centered", Style(Color){}, catppuccin_mocha,
        .{ .anchor = .{ .horizontal = .center } });

    try std.testing.expectEqualStrings("c", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("e", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("n", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("t", screen.readCell(3, 0).?.char.grapheme);
}
