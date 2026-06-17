//! Determinate horizontal progress bar.
//!
//! ProgressBar(C) renders a fraction in [0.0, 1.0] as a filled portion of
//! its window with 1/8 sub-cell precision via Unicode left-fill block
//! glyphs (▏▎▍▌▋▊▉█). NaN and out-of-range inputs are coerced silently —
//! the bar never overflows. The bar renders on row 0 only; multi-row
//! windows leave the other rows untouched, so callers can carve a
//! `win.child(.{ .y_off = ... })` to place the bar inside a thicker pane.
//!
//! An optional centred label can be overlaid via LabelOverlay(C). Each
//! character is styled per the bar's fill state at that column — three
//! styles let the caller bridge the per-column flip into two smaller
//! steps (default → dim partial → filled), so the visible stutter as the
//! boundary sweeps across the label is reduced. Labels are rendered one
//! column per byte (ASCII); pass `[]const u8` you know is ASCII or the
//! per-byte slicing will produce mojibake (debug builds assert).
//!
//! Generic over a color enum: callers using the built-in `Color` write
//! `ProgressBar(Color)`; apps with a domain palette use their own enum.

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("../core/theme.zig");
const subcell   = @import("subcell.zig");
const Style = theme_mod.Style;
const Theme = theme_mod.Theme;

const Discretise = subcell.Discretise(.left_fill);

/// Optional label overlaid on top of the bar.
///
/// The label is rendered with three independent styles, picked per
/// column from the bar's fill state at that column:
///   - `in_filled`  — column lies in the bar's filled region.
///   - `in_partial` — column lies on the trailing partial-fill cell.
///   - `in_empty`   — column lies in the bar's empty region.
///
/// A typical recipe sets `in_partial.bg` to a dim middle colour so each
/// label cell sweeps default → dim → fill in two smaller steps as the
/// boundary crosses, instead of flipping in one large jump.
///
/// `text` is rendered one column per byte (ASCII). The caller owns the
/// buffer; the slice must outlive the frame, matching the vaxis lifetime
/// contract for `print()` / `writeCell()` graphemes.
pub fn LabelOverlay(comptime C: type) type {
    return struct {
        text:       []const u8 = "",
        in_filled:  Style(C) = .{},
        in_partial: Style(C) = .{},
        in_empty:   Style(C) = .{},
    };
}

pub fn ProgressBar(comptime C: type) type {
    return struct {
        filled_style: Style(C) = .{},
        empty_style:  Style(C) = .{},

        const Self = @This();

        /// Render the bar on row 0 of `win`, with `fraction` of the cells
        /// filled (left-to-right). Out-of-range and NaN fractions are
        /// coerced via the subcell helper. When `opts.text` is non-empty,
        /// the label is centred on top of the bar with per-region styling.
        pub fn draw(
            self:  Self,
            win:   vaxis.Window,
            fraction: f32,
            theme: Theme(C),
            opts:  LabelOverlay(C),
        ) void {
            if (win.width == 0 or win.height == 0) return;

            const m = Discretise.measure(win.width, fraction);

            const filled  = theme.resolve(self.filled_style);
            const empty   = theme.resolve(self.empty_style);
            const partial = theme.resolve(subcell.partialStyle(C, self.filled_style, self.empty_style));

            var col: u16 = 0;
            while (col < win.width) : (col += 1) {
                if (col < m.whole) {
                    win.writeCell(col, 0, .{
                        .char  = .{ .grapheme = subcell.Discretise(.left_fill).full_glyph, .width = 1 },
                        .style = filled,
                    });
                } else if (col == m.whole and m.partial_eighths > 0) {
                    win.writeCell(col, 0, .{
                        .char  = .{ .grapheme = Discretise.partial_glyphs[m.partial_eighths], .width = 1 },
                        .style = partial,
                    });
                } else {
                    win.writeCell(col, 0, .{
                        .char  = .{ .grapheme = " ", .width = 1 },
                        .style = empty,
                    });
                }
            }

            if (opts.text.len == 0) return;

            if (std.debug.runtime_safety) {
                for (opts.text) |b| std.debug.assert(b < 0x80);
            }

            // Pre-resolve the three region styles once instead of resolving
            // per cell — the regions are known before the loop and resolve
            // does enum-array lookups that aren't free at hot-loop scale.
            const r_filled  = theme.resolve(opts.in_filled);
            const r_partial = theme.resolve(opts.in_partial);
            const r_empty   = theme.resolve(opts.in_empty);

            const label_w: u16 = @intCast(@min(opts.text.len, win.width));
            const label_col_start: u16 = (win.width - label_w) / 2;
            var li: usize = 0;
            while (li < label_w) : (li += 1) {
                const lc = label_col_start + @as(u16, @intCast(li));
                const region_style = if (lc < m.whole)
                    r_filled
                else if (lc == m.whole and m.partial_eighths > 0)
                    r_partial
                else
                    r_empty;
                win.writeCell(lc, 0, .{
                    .char  = .{ .grapheme = opts.text[li .. li + 1], .width = 1 },
                    .style = region_style,
                });
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

test "ProgressBar.draw: fraction = 0 leaves every cell as empty glyph" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 1);
    const bar: ProgressBar(Color) = .{};
    bar.draw(win, 0.0, catppuccin_mocha, .{});
    var col: u16 = 0;
    while (col < 10) : (col += 1) {
        try std.testing.expectEqualStrings(" ", screen.readCell(col, 0).?.char.grapheme);
    }
}

test "ProgressBar.draw: fraction = 1 fills every cell with the filled glyph" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 1);
    const bar: ProgressBar(Color) = .{};
    bar.draw(win, 1.0, catppuccin_mocha, .{});
    var col: u16 = 0;
    while (col < 10) : (col += 1) {
        try std.testing.expectEqualStrings("█", screen.readCell(col, 0).?.char.grapheme);
    }
}

test "ProgressBar.draw: fraction = 0.5 fills half the width" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 1);
    const bar: ProgressBar(Color) = .{};
    bar.draw(win, 0.5, catppuccin_mocha, .{});
    for ([_]u16{ 0, 1, 2, 3, 4 }) |col| {
        try std.testing.expectEqualStrings("█", screen.readCell(col, 0).?.char.grapheme);
    }
    for ([_]u16{ 5, 6, 7, 8, 9 }) |col| {
        try std.testing.expectEqualStrings(" ", screen.readCell(col, 0).?.char.grapheme);
    }
}

test "ProgressBar.draw: NaN fraction renders as empty bar (no UB)" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const bar: ProgressBar(Color) = .{};
    bar.draw(win, std.math.nan(f32), catppuccin_mocha, .{});
    var col: u16 = 0;
    while (col < 4) : (col += 1) {
        try std.testing.expectEqualStrings(" ", screen.readCell(col, 0).?.char.grapheme);
    }
}

test "ProgressBar.draw: negative fraction clamps to 0" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const bar: ProgressBar(Color) = .{};
    bar.draw(win, -0.5, catppuccin_mocha, .{});
    var col: u16 = 0;
    while (col < 4) : (col += 1) {
        try std.testing.expectEqualStrings(" ", screen.readCell(col, 0).?.char.grapheme);
    }
}

test "ProgressBar.draw: fraction > 1 clamps to 1" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const bar: ProgressBar(Color) = .{};
    bar.draw(win, 2.0, catppuccin_mocha, .{});
    var col: u16 = 0;
    while (col < 4) : (col += 1) {
        try std.testing.expectEqualStrings("█", screen.readCell(col, 0).?.char.grapheme);
    }
}

test "ProgressBar.draw: zero-width window does not panic" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 5, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 0, 1);
    const bar: ProgressBar(Color) = .{};
    bar.draw(win, 0.5, catppuccin_mocha, .{});
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "ProgressBar.draw: zero-height window does not panic" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 5, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 5, 0);
    const bar: ProgressBar(Color) = .{};
    bar.draw(win, 0.5, catppuccin_mocha, .{});
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "ProgressBar.draw: filled style applies fg/bg to filled cells" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const bar: ProgressBar(Color) = .{
        .filled_style = .{ .fg = .color_2 },
    };
    bar.draw(win, 1.0, catppuccin_mocha, .{});
    const want_fg = catppuccin_mocha.colors.get(.color_2);
    try std.testing.expectEqual(want_fg, screen.readCell(0, 0).?.style.fg);
}

test "ProgressBar.draw: partial cell rendered with a left-fill block glyph" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const bar: ProgressBar(Color) = .{};
    // 0.375 × 4 × 8 = 12 eighths → 1 full + 4/8 partial + 2 empty.
    bar.draw(win, 0.375, catppuccin_mocha, .{});
    try std.testing.expectEqualStrings("█", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("▌", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(3, 0).?.char.grapheme);
}

test "ProgressBar.draw: label centred and rendered one cell per byte" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 7, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 7, 1);
    const bar: ProgressBar(Color) = .{};
    bar.draw(win, 0.0, catppuccin_mocha, .{ .text = "ab" });
    // "ab" centred in 7 cols → cols 2 and 3.
    try std.testing.expectEqualStrings("a", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("b", screen.readCell(3, 0).?.char.grapheme);
}

test "ProgressBar.draw: label picks in_filled vs in_empty per column" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 8, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 8, 1);
    const bar: ProgressBar(Color) = .{};
    // Width 8 at 0.5 → whole = 4, partial = 0. Label "1234" centred at cols
    // 2..5. Cols 2,3 sit in the filled region; cols 4,5 in the empty region.
    bar.draw(win, 0.5, catppuccin_mocha, .{
        .text       = "1234",
        .in_filled  = .{ .fg = .color_2 },
        .in_empty   = .{ .fg = .color_7 },
    });
    const want_filled = catppuccin_mocha.colors.get(.color_2);
    const want_empty  = catppuccin_mocha.colors.get(.color_7);
    try std.testing.expectEqual(want_filled, screen.readCell(2, 0).?.style.fg);
    try std.testing.expectEqual(want_filled, screen.readCell(3, 0).?.style.fg);
    try std.testing.expectEqual(want_empty,  screen.readCell(4, 0).?.style.fg);
    try std.testing.expectEqual(want_empty,  screen.readCell(5, 0).?.style.fg);
}

test "ProgressBar.draw: label cell on the partial boundary uses in_partial" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const bar: ProgressBar(Color) = .{};
    // Width 4 at 0.375 → 12 eighths → whole = 1, partial = 4. Label "ab"
    // centred at cols 1..2 → col 1 is the partial cell, col 2 is empty.
    bar.draw(win, 0.375, catppuccin_mocha, .{
        .text       = "ab",
        .in_empty   = .{ .fg = .color_7 },
        .in_partial = .{ .fg = .color_3 },
        .in_filled  = .{ .fg = .color_2 },
    });
    try std.testing.expectEqual(
        catppuccin_mocha.colors.get(.color_3),
        screen.readCell(1, 0).?.style.fg,
    );
    try std.testing.expectEqual(
        catppuccin_mocha.colors.get(.color_7),
        screen.readCell(2, 0).?.style.fg,
    );
}

test "ProgressBar.draw: empty label leaves the bar untouched" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const bar: ProgressBar(Color) = .{};
    bar.draw(win, 0.5, catppuccin_mocha, .{ .text = "" });
    try std.testing.expectEqualStrings("█", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("█", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(3, 0).?.char.grapheme);
}

test "ProgressBar.draw: label wider than the bar truncates to the bar width" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 3, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 3, 1);
    const bar: ProgressBar(Color) = .{};
    bar.draw(win, 0.0, catppuccin_mocha, .{ .text = "abcde" });
    try std.testing.expectEqualStrings("a", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("b", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("c", screen.readCell(2, 0).?.char.grapheme);
}

test "ProgressBar(C): works with a user-defined color enum" {
    const AppColor = enum { background, accent };
    const app_theme: Theme(AppColor) = .{
        .colors = std.EnumArray(AppColor, vaxis.Color).init(.{
            .background = .{ .index = 0 },
            .accent     = .{ .index = 3 },
        }),
    };
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const bar: ProgressBar(AppColor) = .{
        .filled_style = .{ .fg = .accent },
    };
    bar.draw(win, 0.5, app_theme, .{});
    const want_fg: vaxis.Color = .{ .index = 3 };
    try std.testing.expectEqual(want_fg, screen.readCell(0, 0).?.style.fg);
}
