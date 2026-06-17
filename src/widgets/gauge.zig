//! Level indicator with configurable orientation.
//!
//! Gauge(C) shows a fraction in [0.0, 1.0] as a filled portion of its
//! window. Horizontal gauges fill left-to-right; vertical gauges fill
//! bottom-to-top (the natural direction for level meters — full at the
//! top, empty at the bottom). The whole window is filled, so a 3×40
//! horizontal gauge is a thick bar and a 10×1 vertical gauge is a
//! single-column level meter.
//!
//! Sub-cell precision via the subcell helper: horizontal uses
//! left-fill blocks (▏▎▍▌▋▊▉), vertical uses lower-fill blocks
//! (▁▂▃▄▅▆▇). NaN and out-of-range fractions are coerced silently —
//! the gauge never overflows.
//!
//! An optional top-row label can be set via Label(C). The fill area
//! shrinks by one row to make room; with `win.height == 1` and a label
//! set, the label takes the row and the fill is suppressed. Labels
//! render one column per byte (ASCII); debug builds assert.
//!
//! Generic over a color enum; same construction/draw split as
//! ProgressBar(C).

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("../core/theme.zig");
const subcell   = @import("subcell.zig");
const Style = theme_mod.Style;
const Theme = theme_mod.Theme;

pub const Orientation = enum { horizontal, vertical };

const DH = subcell.Discretise(.left_fill);
const DV = subcell.Discretise(.lower_fill);

/// Optional top-row label.
///
/// The label is rendered above the fill area (which shrinks by one row
/// to make room) with a single style applied to every label cell. There
/// is no per-column flip to bridge since the fill never reaches the
/// label row — one style is enough.
///
/// `text` is rendered one column per byte (ASCII). The caller owns the
/// buffer; the slice must outlive the frame, matching the vaxis
/// lifetime contract for `print()` / `writeCell()` graphemes.
pub fn Label(comptime C: type) type {
    return struct {
        text:  []const u8 = "",
        style: Style(C) = .{},
    };
}

pub fn Gauge(comptime C: type) type {
    return struct {
        orientation:  Orientation = .horizontal,
        filled_style: Style(C) = .{},
        empty_style:  Style(C) = .{},

        const Self = @This();

        pub fn draw(
            self:  Self,
            win:   vaxis.Window,
            fraction: f32,
            theme: Theme(C),
            opts:  Label(C),
        ) void {
            if (win.width == 0 or win.height == 0) return;

            const has_label = opts.text.len > 0;
            const fill_y_off: u16 = if (has_label) 1 else 0;
            const fill_height: u16 = win.height -| fill_y_off;

            if (has_label) {
                if (std.debug.runtime_safety) {
                    for (opts.text) |b| std.debug.assert(b < 0x80);
                }
                const label_w: u16 = @intCast(@min(opts.text.len, win.width));
                const label_col_start: u16 = (win.width - label_w) / 2;
                const label_resolved = theme.resolve(opts.style);
                var li: usize = 0;
                while (li < label_w) : (li += 1) {
                    win.writeCell(label_col_start + @as(u16, @intCast(li)), 0, .{
                        .char  = .{ .grapheme = opts.text[li .. li + 1], .width = 1 },
                        .style = label_resolved,
                    });
                }
            }

            if (fill_height == 0) return;
            const fw = win.child(.{ .y_off = fill_y_off, .height = fill_height });

            const filled  = theme.resolve(self.filled_style);
            const empty   = theme.resolve(self.empty_style);
            const partial = theme.resolve(subcell.partialStyle(C, self.filled_style, self.empty_style));

            switch (self.orientation) {
                .horizontal => {
                    const m = DH.measure(fw.width, fraction);
                    var row: u16 = 0;
                    while (row < fw.height) : (row += 1) {
                        var col: u16 = 0;
                        while (col < fw.width) : (col += 1) {
                            if (col < m.whole) {
                                fw.writeCell(col, row, .{
                                    .char  = .{ .grapheme = DH.full_glyph, .width = 1 },
                                    .style = filled,
                                });
                            } else if (col == m.whole and m.partial_eighths > 0) {
                                fw.writeCell(col, row, .{
                                    .char  = .{ .grapheme = DH.partial_glyphs[m.partial_eighths], .width = 1 },
                                    .style = partial,
                                });
                            } else {
                                fw.writeCell(col, row, .{
                                    .char  = .{ .grapheme = " ", .width = 1 },
                                    .style = empty,
                                });
                            }
                        }
                    }
                },
                .vertical => {
                    const m = DV.measure(fw.height, fraction);
                    // The fully-filled rows are the BOTTOM whole rows. The
                    // partial row (if any) sits immediately above them.
                    // partial_row is optional so the "no partial row" case
                    // doesn't carry a dummy 0 — both branches of the inner
                    // conditional are then explicit.
                    const filled_threshold: u16 = fw.height - m.whole;
                    const partial_row: ?u16 =
                        if (m.partial_eighths > 0 and filled_threshold > 0)
                            filled_threshold - 1
                        else
                            null;

                    var row: u16 = 0;
                    while (row < fw.height) : (row += 1) {
                        var col: u16 = 0;
                        while (col < fw.width) : (col += 1) {
                            if (row >= filled_threshold) {
                                fw.writeCell(col, row, .{
                                    .char  = .{ .grapheme = DV.full_glyph, .width = 1 },
                                    .style = filled,
                                });
                            } else if (partial_row != null and row == partial_row.?) {
                                fw.writeCell(col, row, .{
                                    .char  = .{ .grapheme = DV.partial_glyphs[m.partial_eighths], .width = 1 },
                                    .style = partial,
                                });
                            } else {
                                fw.writeCell(col, row, .{
                                    .char  = .{ .grapheme = " ", .width = 1 },
                                    .style = empty,
                                });
                            }
                        }
                    }
                },
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

test "Gauge.draw horizontal: fraction = 0 leaves every cell empty" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 3);
    const g: Gauge(Color) = .{ .orientation = .horizontal };
    g.draw(win, 0.0, catppuccin_mocha, .{});
    var row: u16 = 0;
    while (row < 3) : (row += 1) {
        var col: u16 = 0;
        while (col < 10) : (col += 1) {
            try std.testing.expectEqualStrings(" ", screen.readCell(col, row).?.char.grapheme);
        }
    }
}

test "Gauge.draw horizontal: fraction = 1 fills every cell" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 3);
    const g: Gauge(Color) = .{ .orientation = .horizontal };
    g.draw(win, 1.0, catppuccin_mocha, .{});
    var row: u16 = 0;
    while (row < 3) : (row += 1) {
        var col: u16 = 0;
        while (col < 10) : (col += 1) {
            try std.testing.expectEqualStrings("█", screen.readCell(col, row).?.char.grapheme);
        }
    }
}

test "Gauge.draw horizontal: fills uniformly across rows" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 3);
    const g: Gauge(Color) = .{ .orientation = .horizontal };
    g.draw(win, 0.5, catppuccin_mocha, .{});
    var row: u16 = 0;
    while (row < 3) : (row += 1) {
        try std.testing.expectEqualStrings("█", screen.readCell(4, row).?.char.grapheme);
        try std.testing.expectEqualStrings(" ", screen.readCell(5, row).?.char.grapheme);
    }
}

test "Gauge.draw vertical: fraction = 0 leaves every cell empty" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 8, .cols = 2, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 2, 8);
    const g: Gauge(Color) = .{ .orientation = .vertical };
    g.draw(win, 0.0, catppuccin_mocha, .{});
    var row: u16 = 0;
    while (row < 8) : (row += 1) {
        try std.testing.expectEqualStrings(" ", screen.readCell(0, row).?.char.grapheme);
        try std.testing.expectEqualStrings(" ", screen.readCell(1, row).?.char.grapheme);
    }
}

test "Gauge.draw vertical: fraction = 1 fills every cell" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 8, .cols = 2, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 2, 8);
    const g: Gauge(Color) = .{ .orientation = .vertical };
    g.draw(win, 1.0, catppuccin_mocha, .{});
    var row: u16 = 0;
    while (row < 8) : (row += 1) {
        try std.testing.expectEqualStrings("█", screen.readCell(0, row).?.char.grapheme);
        try std.testing.expectEqualStrings("█", screen.readCell(1, row).?.char.grapheme);
    }
}

test "Gauge.draw vertical: fills bottom-to-top" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 8, .cols = 1, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 1, 8);
    const g: Gauge(Color) = .{ .orientation = .vertical };
    g.draw(win, 0.5, catppuccin_mocha, .{});
    for ([_]u16{ 0, 1, 2, 3 }) |row| {
        try std.testing.expectEqualStrings(" ", screen.readCell(0, row).?.char.grapheme);
    }
    for ([_]u16{ 4, 5, 6, 7 }) |row| {
        try std.testing.expectEqualStrings("█", screen.readCell(0, row).?.char.grapheme);
    }
}

test "Gauge.draw: NaN fraction renders as empty (no UB)" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 4);
    const g: Gauge(Color) = .{ .orientation = .vertical };
    g.draw(win, std.math.nan(f32), catppuccin_mocha, .{});
    var row: u16 = 0;
    while (row < 4) : (row += 1) {
        try std.testing.expectEqualStrings(" ", screen.readCell(0, row).?.char.grapheme);
    }
}

test "Gauge.draw: negative fraction clamps to 0" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 4);
    const g: Gauge(Color) = .{ .orientation = .vertical };
    g.draw(win, -0.25, catppuccin_mocha, .{});
    var row: u16 = 0;
    while (row < 4) : (row += 1) {
        try std.testing.expectEqualStrings(" ", screen.readCell(0, row).?.char.grapheme);
    }
}

test "Gauge.draw: fraction > 1 clamps to 1" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 4);
    const g: Gauge(Color) = .{ .orientation = .horizontal };
    g.draw(win, 99.0, catppuccin_mocha, .{});
    var col: u16 = 0;
    while (col < 4) : (col += 1) {
        try std.testing.expectEqualStrings("█", screen.readCell(col, 0).?.char.grapheme);
    }
}

test "Gauge.draw: zero-width window does not panic" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 5, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 0, 3);
    const g: Gauge(Color) = .{};
    g.draw(win, 0.5, catppuccin_mocha, .{});
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "Gauge.draw: zero-height window does not panic" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 5, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 5, 0);
    const g: Gauge(Color) = .{};
    g.draw(win, 0.5, catppuccin_mocha, .{});
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "Gauge.draw horizontal: partial cell rendered with a left-fill block glyph" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 2);
    const g: Gauge(Color) = .{ .orientation = .horizontal };
    g.draw(win, 0.375, catppuccin_mocha, .{});
    var row: u16 = 0;
    while (row < 2) : (row += 1) {
        try std.testing.expectEqualStrings("█", screen.readCell(0, row).?.char.grapheme);
        try std.testing.expectEqualStrings("▌", screen.readCell(1, row).?.char.grapheme);
        try std.testing.expectEqualStrings(" ", screen.readCell(2, row).?.char.grapheme);
        try std.testing.expectEqualStrings(" ", screen.readCell(3, row).?.char.grapheme);
    }
}

test "Gauge.draw vertical: partial row rendered with a lower-fill block glyph" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 8, .cols = 1, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 1, 8);
    const g: Gauge(Color) = .{ .orientation = .vertical };
    // 0.59375 × 8 × 8 = 38 eighths → 4 whole + 6/8 partial.
    g.draw(win, 0.59375, catppuccin_mocha, .{});
    for ([_]u16{ 0, 1, 2 }) |row| {
        try std.testing.expectEqualStrings(" ", screen.readCell(0, row).?.char.grapheme);
    }
    try std.testing.expectEqualStrings("▆", screen.readCell(0, 3).?.char.grapheme);
    for ([_]u16{ 4, 5, 6, 7 }) |row| {
        try std.testing.expectEqualStrings("█", screen.readCell(0, row).?.char.grapheme);
    }
}

test "Gauge.draw vertical: tiny fraction renders 1/8 partial at the bottom row" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4, .cols = 1, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 1, 4);
    const g: Gauge(Color) = .{ .orientation = .vertical };
    g.draw(win, 0.0625, catppuccin_mocha, .{});
    for ([_]u16{ 0, 1, 2 }) |row| {
        try std.testing.expectEqualStrings(" ", screen.readCell(0, row).?.char.grapheme);
    }
    try std.testing.expectEqualStrings("▂", screen.readCell(0, 3).?.char.grapheme);
}

test "Gauge.draw: label sits on the top row, centred one byte per column" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4, .cols = 6, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 6, 4);
    const g: Gauge(Color) = .{ .orientation = .vertical };
    g.draw(win, 0.0, catppuccin_mocha, .{ .text = "100%" });
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("1", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("0", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("0", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("%", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(5, 0).?.char.grapheme);
}

test "Gauge.draw: label shrinks fill area by one row, fill still bottom-anchored" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 5, .cols = 1, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 1, 5);
    const g: Gauge(Color) = .{ .orientation = .vertical };
    g.draw(win, 1.0, catppuccin_mocha, .{ .text = "X" });
    try std.testing.expectEqualStrings("X", screen.readCell(0, 0).?.char.grapheme);
    for ([_]u16{ 1, 2, 3, 4 }) |row| {
        try std.testing.expectEqualStrings("█", screen.readCell(0, row).?.char.grapheme);
    }
}

test "Gauge.draw: label takes the only row when win.height == 1" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 3, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 3, 1);
    const g: Gauge(Color) = .{ .orientation = .vertical };
    g.draw(win, 0.5, catppuccin_mocha, .{ .text = "OK" });
    try std.testing.expectEqualStrings("O", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("K", screen.readCell(1, 0).?.char.grapheme);
}

test "Gauge.draw: label style fg applies to every cell of the label row" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 2, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 2, 3);
    const g: Gauge(Color) = .{ .orientation = .vertical };
    g.draw(win, 0.0, catppuccin_mocha, .{
        .text  = "AB",
        .style = .{ .fg = .color_4 },
    });
    const want_fg = catppuccin_mocha.colors.get(.color_4);
    try std.testing.expectEqual(want_fg, screen.readCell(0, 0).?.style.fg);
    try std.testing.expectEqual(want_fg, screen.readCell(1, 0).?.style.fg);
}

test "Gauge(C): works with a user-defined color enum" {
    const AppColor = enum { background, accent };
    const app_theme: Theme(AppColor) = .{
        .colors = std.EnumArray(AppColor, vaxis.Color).init(.{
            .background = .{ .index = 0 },
            .accent     = .{ .index = 3 },
        }),
    };
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 4);
    const g: Gauge(AppColor) = .{
        .orientation  = .vertical,
        .filled_style = .{ .fg = .accent },
    };
    g.draw(win, 1.0, app_theme, .{});
    const want_fg: vaxis.Color = .{ .index = 3 };
    try std.testing.expectEqual(want_fg, screen.readCell(0, 0).?.style.fg);
}
