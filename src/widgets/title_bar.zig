//! Single-row centred title pill.
//!
//! TitleBar(C) renders a short title string on a coloured ribbon at a
//! caller-chosen anchor inside its window. With caps set to `.none`
//! (the default) it degenerates to a flat ribbon — font-independent
//! and useful on its own. With caps set to `.round`, `.slant`, or
//! `.custom` it draws powerline-style end glyphs that shape the
//! ribbon into a pill.
//!
//! The recipe the widget encapsulates is the cap fg/bg inversion: the
//! cap glyph's foreground is set to the ribbon's background colour
//! and the cap glyph's background stays at terminal default. The
//! half-block cap then reads as the ribbon's shape continuing past
//! the text, and the default-bg half reads as surrounding negative
//! space. Without the inversion the cap renders on the wrong canvas
//! and produces a coloured rectangle with notches instead of the
//! intended pill outline.
//!
//! Caps are an opt-in tagged union — `.custom` carries its own glyph
//! pair as part of the variant, so it's impossible to ask for custom
//! caps without supplying the glyphs. The powerline / NerdFont caps
//! require a patched font; on terminals without one they render as
//! replacement boxes. The flat-ribbon default is the safe degraded
//! form.
//!
//! Titles longer than the window are truncated to the usable byte
//! count *before* the centring math, so adversarial input (a 65535-
//! byte string) can never overflow the u16 composite width or land
//! the bar at a wildly wrong column.

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("../core/theme.zig");
const anchor_mod = @import("../core/anchor.zig");
const Style = theme_mod.Style;
const Theme = theme_mod.Theme;
const Anchor = anchor_mod.Anchor;

/// Cap shape carried as a tagged union so the custom glyph pair lives
/// on the variant that needs it. The two named shapes use the
/// standard Powerline / NerdFont code points.
pub const Caps = union(enum) {
    none,
    round,                       // U+E0B6 / U+E0B4
    slant,                       // U+E0B2 / U+E0B0
    custom: [2][]const u8,       // caller-supplied (left, right) glyphs
};

/// Construction-time opts for a TitleBar.
///
/// Anchor defaults to center/top, which deviates from `Anchor`'s
/// library-wide left/top default — title bars almost always want a
/// centred title. Override per caller if not.
///
/// `text` is rendered one column per byte (ASCII). The caller owns
/// the buffer; the slice must outlive the frame, matching the vaxis
/// lifetime contract for `print()` graphemes.
pub fn TitleOpts(comptime C: type) type {
    return struct {
        text:   []const u8 = "",
        style:  Style(C) = .{},
        caps:   Caps = .none,
        anchor: Anchor = .{ .horizontal = .center, .vertical = .top },
    };
}

pub fn TitleBar(comptime C: type) type {
    return struct {
        const Self = @This();

        /// Render the title at the configured anchor inside `win`. One
        /// row only; titles wider than the window are truncated to the
        /// available byte count before centring.
        pub fn draw(self: Self, win: vaxis.Window, theme: Theme(C), opts: TitleOpts(C)) void {
            _ = self;
            if (win.width == 0 or win.height == 0) return;
            if (std.debug.runtime_safety) {
                for (opts.text) |b| std.debug.assert(b < 0x80);
            }

            const caps_pair: ?[2][]const u8 = switch (opts.caps) {
                .none           => null,
                .round          => .{ "\u{E0B6}", "\u{E0B4}" },
                .slant          => .{ "\u{E0B2}", "\u{E0B0}" },
                .custom         => |pair| pair,
            };
            const cap_w: u16 = if (caps_pair != null) 2 else 0;

            // Truncate the title to fit before the arithmetic. Without
            // this an adversarial title (e.g. a long filename or branch
            // name from external input) could overflow u16 or land the
            // bar off-screen at a wrapped column.
            const usable: u16 = win.width -| cap_w;
            const ribbon_w: u16 = @intCast(@min(opts.text.len, @as(usize, usable)));
            const display_title = opts.text[0..ribbon_w];
            const composite_w: u16 = ribbon_w + cap_w;

            const off = opts.anchor.resolve(win.width, win.height, composite_w, 1);
            const ribbon_resolved = theme.resolve(opts.style);

            if (caps_pair) |caps| {
                // Caps inherit the ribbon's bg as their fg so the half-
                // block glyph paints the ribbon shape on terminal default.
                const cap_style = vaxis.Cell.Style{
                    .fg = ribbon_resolved.bg,
                    .bg = .default,
                };
                _ = win.print(&.{
                    .{ .text = caps[0],       .style = cap_style },
                    .{ .text = display_title, .style = ribbon_resolved },
                    .{ .text = caps[1],       .style = cap_style },
                }, .{ .wrap = .none, .col_offset = off.col, .row_offset = off.row });
            } else {
                _ = win.print(&.{
                    .{ .text = display_title, .style = ribbon_resolved },
                }, .{ .wrap = .none, .col_offset = off.col, .row_offset = off.row });
            }
        }
    };
}

// --- tests -------------------------------------------------------------------

const Color = theme_mod.Color;
const catppuccin_mocha = theme_mod.catppuccin_mocha;

fn makeWin(screen: *vaxis.Screen, w: u16, h: u16) vaxis.Window {
    return .{
        .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0,
        .width = w, .height = h, .screen = screen,
    };
}

test "TitleBar.draw: flat ribbon centres the title" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 1);
    const bar: TitleBar(Color) = .{};
    bar.draw(win, catppuccin_mocha, .{
        .text  = "test",
        .style = .{ .fg = .foreground, .bg = .color_3 },
    });
    try std.testing.expectEqualStrings("t", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("e", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("s", screen.readCell(5, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("t", screen.readCell(6, 0).?.char.grapheme);
}

test "TitleBar.draw: ribbon bg applies to every title cell" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 6, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 6, 1);
    const bar: TitleBar(Color) = .{};
    bar.draw(win, catppuccin_mocha, .{
        .text  = "ab",
        .style = .{ .fg = .foreground, .bg = .color_3 },
    });
    const want_bg = catppuccin_mocha.colors.get(.color_3);
    try std.testing.expectEqual(want_bg, screen.readCell(2, 0).?.style.bg);
    try std.testing.expectEqual(want_bg, screen.readCell(3, 0).?.style.bg);
}

test "TitleBar.draw: round caps render before and after the ribbon" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 8, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 8, 1);
    const bar: TitleBar(Color) = .{};
    bar.draw(win, catppuccin_mocha, .{
        .text  = "ab",
        .style = .{ .fg = .foreground, .bg = .color_3 },
        .caps  = .round,
    });
    try std.testing.expectEqualStrings("\u{E0B6}", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("a",        screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("b",        screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("\u{E0B4}", screen.readCell(5, 0).?.char.grapheme);
}

test "TitleBar.draw: cap fg derives from ribbon bg, cap bg is terminal default" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 8, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 8, 1);
    const bar: TitleBar(Color) = .{};
    bar.draw(win, catppuccin_mocha, .{
        .text  = "ab",
        .style = .{ .fg = .foreground, .bg = .color_3 },
        .caps  = .round,
    });
    const ribbon_bg = catppuccin_mocha.colors.get(.color_3);
    try std.testing.expectEqual(ribbon_bg,           screen.readCell(2, 0).?.style.fg);
    try std.testing.expectEqual(vaxis.Color.default, screen.readCell(2, 0).?.style.bg);
    try std.testing.expectEqual(ribbon_bg,           screen.readCell(5, 0).?.style.fg);
    try std.testing.expectEqual(vaxis.Color.default, screen.readCell(5, 0).?.style.bg);
}

test "TitleBar.draw: slant caps use the U+E0B2 / U+E0B0 glyphs" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 8, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 8, 1);
    const bar: TitleBar(Color) = .{};
    bar.draw(win, catppuccin_mocha, .{
        .text  = "ab",
        .style = .{ .fg = .foreground, .bg = .color_3 },
        .caps  = .slant,
    });
    try std.testing.expectEqualStrings("\u{E0B2}", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("\u{E0B0}", screen.readCell(5, 0).?.char.grapheme);
}

test "TitleBar.draw: custom caps carry the supplied grapheme pair" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 8, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 8, 1);
    const bar: TitleBar(Color) = .{};
    bar.draw(win, catppuccin_mocha, .{
        .text  = "ab",
        .style = .{ .fg = .foreground, .bg = .color_3 },
        .caps  = .{ .custom = .{ "<", ">" } },
    });
    try std.testing.expectEqualStrings("<", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(">", screen.readCell(5, 0).?.char.grapheme);
}

test "TitleBar.draw: title longer than the usable width truncates" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 6, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 6, 1);
    const bar: TitleBar(Color) = .{};
    // 8-byte title in a 6-wide window with caps (4 usable cells for
    // text). Title truncates to "long" and composite = 4 + 2 = 6 cols.
    bar.draw(win, catppuccin_mocha, .{
        .text  = "longtitle",
        .style = .{ .fg = .foreground, .bg = .color_3 },
        .caps  = .round,
    });
    try std.testing.expectEqualStrings("\u{E0B6}", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("l", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("o", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("n", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("g", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("\u{E0B4}", screen.readCell(5, 0).?.char.grapheme);
}

test "TitleBar.draw: zero-width window does not panic" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 0, 1);
    const bar: TitleBar(Color) = .{};
    bar.draw(win, catppuccin_mocha, .{ .text = "x" });
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "TitleBar(C): works with a user-defined color enum" {
    const AppColor = enum { ribbon, ink };
    const app_theme: Theme(AppColor) = .{
        .colors = std.EnumArray(AppColor, vaxis.Color).init(.{
            .ribbon = .{ .index = 4 },
            .ink    = .{ .index = 15 },
        }),
    };
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 6, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 6, 1);
    const bar: TitleBar(AppColor) = .{};
    bar.draw(win, app_theme, .{
        .text  = "X",
        .style = .{ .fg = .ink, .bg = .ribbon },
        .caps  = .round,
    });
    const want_fg: vaxis.Color = .{ .index = 4 };
    try std.testing.expectEqual(want_fg, screen.readCell(1, 0).?.style.fg);
}
