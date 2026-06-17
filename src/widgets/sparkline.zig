//! Single-row historical data viz.
//!
//! Sparkline(C) renders a sequence of values in [0.0, 1.0] as a row of
//! Unicode lower-fill block glyphs (▁▂▃▄▅▆▇█, plus a blank for zero).
//! Each value becomes one column; the glyph encodes the magnitude.
//! Anchored to the right edge so the most recent sample sits on the
//! right — the convention every system monitor uses (htop, btop, k9s).
//!
//! Out-of-range and NaN values are coerced silently in the value loop
//! itself (NaN → 0, out-of-range → clamped) so a single NaN in a slice
//! of otherwise-good samples renders as an empty column rather than
//! producing illegal behavior.
//!
//! Two styles let leading-blank columns (when fewer values than columns)
//! fall through to the panel chrome:
//!   - `style`       — applied to the cells that carry a value glyph.
//!   - `empty_style` — applied to the leading blank cells. Default is
//!                     `.{}`, which resolves to terminal defaults — so a
//!                     sparkline lifted onto a coloured panel doesn't
//!                     extend its own bg into the no-value region.
//!
//! The widget is stateless; values come in at draw time. The values
//! slice is read during draw and need not outlive it — but if the
//! caller maintains a ring buffer (typical), the buffer's own lifetime
//! is independent of the widget's.

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("../core/theme.zig");
const Style = theme_mod.Style;
const Theme = theme_mod.Theme;

// 9 levels of lower-fill: 0/8 (empty) through 8/8 (full block).
const level_glyphs = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

pub fn Sparkline(comptime C: type) type {
    return struct {
        /// Style applied to cells that carry a value glyph.
        style:       Style(C) = .{},
        /// Style applied to leading blank columns (when there are fewer
        /// values than the row is wide). Default leaves bg as the
        /// terminal default so the chrome underneath shows through.
        empty_style: Style(C) = .{},

        const Self = @This();

        /// Render `values` (each in [0.0, 1.0]) on row 0 of `win`, anchored
        /// to the right edge. Older values fall off the left when there
        /// are more samples than columns. NaN values are coerced to zero;
        /// out-of-range values clamp.
        pub fn draw(
            self:   Self,
            win:    vaxis.Window,
            values: []const f32,
            theme:  Theme(C),
        ) void {
            if (win.width == 0 or win.height == 0) return;
            const value_style = theme.resolve(self.style);
            const empty_resolved = theme.resolve(self.empty_style);

            // Pick which values to show and which window columns they
            // occupy. If there are fewer values than columns, leave the
            // leftmost columns empty so the most recent value sits on
            // the right.
            const shown: usize = @min(values.len, @as(usize, win.width));
            const skipped_values: usize = values.len - shown;
            const leading_blank_cols: u16 = @intCast(@as(usize, win.width) - shown);

            var col: u16 = 0;
            while (col < leading_blank_cols) : (col += 1) {
                win.writeCell(col, 0, .{
                    .char  = .{ .grapheme = " ", .width = 1 },
                    .style = empty_resolved,
                });
            }
            var i: usize = 0;
            while (i < shown) : (i += 1) {
                const raw = values[skipped_values + i];
                const sanitized = if (std.math.isNan(raw)) 0.0 else raw;
                const v = std.math.clamp(sanitized, 0.0, 1.0);
                // Map [0, 1] to the 0..8 index — round-to-nearest so a value
                // of exactly 0.5 lands on the middle glyph (▄, index 4), and
                // v=1.0 lands on the full block (█, index 8) — both end-of-
                // range values reach the expected glyph.
                const level: usize = @intFromFloat(@round(v * 8.0));
                win.writeCell(leading_blank_cols + @as(u16, @intCast(i)), 0, .{
                    .char  = .{ .grapheme = level_glyphs[level], .width = 1 },
                    .style = value_style,
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

test "Sparkline.draw: each value maps to its lower-fill glyph" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 9, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 9, 1);
    const s: Sparkline(Color) = .{};
    const values = [_]f32{ 0.0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1.0 };
    s.draw(win, &values, catppuccin_mocha);
    const expected = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
    for (expected, 0..) |want, idx| {
        try std.testing.expectEqualStrings(
            want,
            screen.readCell(@intCast(idx), 0).?.char.grapheme,
        );
    }
}

test "Sparkline.draw: fewer values than width anchors to the right edge" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 6, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 6, 1);
    const s: Sparkline(Color) = .{};
    const values = [_]f32{ 0.125, 0.5, 1.0 };
    s.draw(win, &values, catppuccin_mocha);
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("▁", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("▄", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("█", screen.readCell(5, 0).?.char.grapheme);
}

test "Sparkline.draw: more values than width keeps only the most recent" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const s: Sparkline(Color) = .{};
    const values = [_]f32{ 0.0, 0.0, 0.0, 0.125, 0.375, 0.625, 1.0 };
    s.draw(win, &values, catppuccin_mocha);
    try std.testing.expectEqualStrings("▁", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("▃", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("▅", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("█", screen.readCell(3, 0).?.char.grapheme);
}

test "Sparkline.draw: empty slice fills the row with empty cells" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const s: Sparkline(Color) = .{};
    s.draw(win, &.{}, catppuccin_mocha);
    var col: u16 = 0;
    while (col < 4) : (col += 1) {
        try std.testing.expectEqualStrings(" ", screen.readCell(col, 0).?.char.grapheme);
    }
}

test "Sparkline.draw: clamps out-of-range values" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 3, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 3, 1);
    const s: Sparkline(Color) = .{};
    const values = [_]f32{ -0.5, 0.5, 2.0 };
    s.draw(win, &values, catppuccin_mocha);
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("▄", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("█", screen.readCell(2, 0).?.char.grapheme);
}

test "Sparkline.draw: NaN values coerce to zero, no UB" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 3, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 3, 1);
    const s: Sparkline(Color) = .{};
    const values = [_]f32{ 0.5, std.math.nan(f32), 0.5 };
    s.draw(win, &values, catppuccin_mocha);
    try std.testing.expectEqualStrings("▄", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("▄", screen.readCell(2, 0).?.char.grapheme);
}

test "Sparkline.draw: zero-width window does not panic" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 0, 1);
    const s: Sparkline(Color) = .{};
    const values = [_]f32{ 0.5, 1.0 };
    s.draw(win, &values, catppuccin_mocha);
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "Sparkline.draw: style fg applies to value cells; empty_style applies to leading blanks" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const s: Sparkline(Color) = .{
        .style       = .{ .fg = .color_2 },
        .empty_style = .{ .fg = .color_8 },
    };
    const values = [_]f32{ 0.5, 0.5 };
    s.draw(win, &values, catppuccin_mocha);
    const value_fg = catppuccin_mocha.colors.get(.color_2);
    const empty_fg = catppuccin_mocha.colors.get(.color_8);
    try std.testing.expectEqual(empty_fg, screen.readCell(0, 0).?.style.fg);
    try std.testing.expectEqual(empty_fg, screen.readCell(1, 0).?.style.fg);
    try std.testing.expectEqual(value_fg, screen.readCell(2, 0).?.style.fg);
    try std.testing.expectEqual(value_fg, screen.readCell(3, 0).?.style.fg);
}

test "Sparkline(C): works with a user-defined color enum" {
    const AppColor = enum { background, accent };
    const app_theme: Theme(AppColor) = .{
        .colors = std.EnumArray(AppColor, vaxis.Color).init(.{
            .background = .{ .index = 0 },
            .accent     = .{ .index = 3 },
        }),
    };
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 3, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 3, 1);
    const s: Sparkline(AppColor) = .{ .style = .{ .fg = .accent } };
    const values = [_]f32{ 0.5, 0.5, 0.5 };
    s.draw(win, &values, app_theme);
    const want_fg: vaxis.Color = .{ .index = 3 };
    try std.testing.expectEqual(want_fg, screen.readCell(0, 0).?.style.fg);
}
