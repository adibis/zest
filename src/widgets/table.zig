//! Tabular data display with per-column sizing and alignment.
//!
//! Table(C) renders a header row above a list of data rows. Columns
//! carry their own width via the same `Size` tagged union the layout
//! engine uses for panes (`.fixed`, `.fraction`, `.percent`), so the
//! same mental model — fixed cells first, percent off the total, the
//! rest divided by fraction weight — applies at the column level.
//!
//! Rows are passed as `[]const []const []const u8` at draw time — one
//! outer slice over rows, each row a slice of one string per column.
//! The widget is intentionally column-data-agnostic; apps with
//! struct-typed data write a tiny adapter that flattens their structs
//! into the string-slice shape, the same way List(C) leaves item
//! formatting to the caller.
//!
//! Selection and focus styling reuse `WidgetTheme(C)` so a focused
//! table highlights the selected row using the same focused/unfocused
//! pair List(C) consumes. Apps that already configure `mocha_widget`
//! or their own `WidgetTheme(C)` get matching styling on Table for
//! free.
//!
//! `handleKey` advances or retreats the selection on j/k or arrow
//! keys; `draw` then keeps the selected row in view by adjusting
//! `scroll_offset` (the split is so handleKey can run inside
//! update() without knowing the window height).

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("../core/theme.zig");
const size_mod  = @import("../layout/size.zig");
const Style       = theme_mod.Style;
const Theme       = theme_mod.Theme;
const WidgetTheme = theme_mod.WidgetTheme;
const Size        = size_mod.Size;

/// Maximum columns a single Table can carry. Lets the solver use a
/// stack buffer for per-column widths without an allocator at draw
/// time. Realistic table layouts sit far below this — bumping it costs
/// nothing but a slightly larger frame stack.
pub const max_columns: usize = 32;

/// Cell text horizontal alignment within its column.
pub const Alignment = enum { left, center, right };

/// One column descriptor. Identity (header text) and shape (size,
/// alignment) are construction-time data; cell content is supplied
/// per-row at draw time.
pub fn Column(comptime C: type) type {
    _ = C;
    return struct {
        /// Header text rendered on the top row.
        header:    []const u8,
        /// Column width — same `Size` tag the layout engine uses.
        size:      Size,
        /// Cell text alignment within the column.
        alignment: Alignment = .left,
    };
}

pub fn Table(comptime C: type) type {
    return struct {
        /// Column descriptors. The slice is borrowed; it must outlive
        /// the table. File-scope const literals are the typical shape.
        columns:       []const Column(C),
        /// Style applied to header cells (the top row).
        header_style:  Style(C) = .{},
        /// Style applied to every data cell. Selection styling
        /// composes on top via widget_theme.
        cell_style:    Style(C) = .{},
        /// Focused-vs-unfocused selection styling. Reuses the
        /// WidgetTheme(C) List already consumes — apps that share a
        /// widget theme between List and Table get consistent
        /// selection visuals for free.
        widget_theme:  WidgetTheme(C) = .{},
        /// Index of the currently selected row. `handleKey` advances
        /// or retreats it; consumers may read it to drive linked UI.
        selected:      usize = 0,
        /// Number of rows scrolled off the top of the visible window.
        /// Adjusted by `draw` (which knows the window height) to keep
        /// the selected row visible.
        scroll_offset: usize = 0,

        const Self = @This();

        /// Move the selection one row up or down on j/k or arrow keys.
        /// `row_count` is the number of rows the caller is about to
        /// pass to `draw`; the selection is clamped to that range so
        /// it never falls off the end. Scroll bookkeeping happens in
        /// `draw`, which knows the window height — handleKey itself
        /// stays window-agnostic and is safe to call from update().
        pub fn handleKey(self: *Self, key: vaxis.Key, row_count: usize) void {
            if (row_count == 0) return;
            const is_down = key.matches('j', .{}) or key.matches(vaxis.Key.down, .{});
            const is_up   = key.matches('k', .{}) or key.matches(vaxis.Key.up,   .{});
            if (is_down and self.selected + 1 < row_count) {
                self.selected += 1;
            } else if (is_up and self.selected > 0) {
                self.selected -= 1;
            }
        }

        /// Render the table inside `win`. Adjusts `scroll_offset` so
        /// the selected row stays visible (scrolling up when the
        /// selection moves above the visible window, down when it
        /// moves below) and renders the visible slice with the
        /// focus-aware selection highlight.
        pub fn draw(
            self: *Self,
            win: vaxis.Window,
            rows: []const []const []const u8,
            focused: bool,
            theme: Theme(C),
        ) void {
            if (win.width == 0 or win.height == 0) return;
            if (self.columns.len > max_columns) return;

            win.fill(.{
                .char  = .{ .grapheme = " ", .width = 1 },
                .style = theme.resolve(self.cell_style),
            });

            var widths_buf: [max_columns]u16 = undefined;
            const widths = widths_buf[0..self.columns.len];
            solveColumnWidths(C, self.columns, win.width, widths);

            const header_resolved = theme.resolve(self.header_style);
            var hx: u16 = 0;
            for (self.columns, 0..) |col, i| {
                renderCell(win, hx, 0, widths[i], col.header, col.alignment, header_resolved);
                hx += widths[i];
            }

            if (win.height < 2) return;
            const max_visible: u16 = win.height - 1;

            // Adjust scroll_offset to keep the selected row in view.
            // The selected index moves freely via handleKey; draw is
            // where we map "the data the caller has" to "the rows
            // that fit on screen this frame". When `selected` is
            // beyond the data the caller passed (e.g. usize sentinel),
            // we leave scroll_offset alone — no row is highlighted
            // anyway and the data slice may have shrunk between
            // frames.
            if (self.selected < rows.len) {
                if (self.selected < self.scroll_offset) {
                    self.scroll_offset = self.selected;
                } else if (self.selected >= self.scroll_offset + @as(usize, max_visible)) {
                    self.scroll_offset = self.selected - @as(usize, max_visible) + 1;
                }
            }

            const cell_resolved = theme.resolve(self.cell_style);
            const selected_resolved = theme.resolve(self.widget_theme.selected.pick(focused));
            const start = self.scroll_offset;
            const end = @min(rows.len, start + @as(usize, max_visible));
            var row_idx: usize = start;
            while (row_idx < end) : (row_idx += 1) {
                const row = rows[row_idx];
                const y: u16 = @intCast(row_idx - start + 1);
                const is_selected = row_idx == self.selected;
                const row_style = if (is_selected) selected_resolved else cell_resolved;
                if (is_selected) {
                    var col: u16 = 0;
                    while (col < win.width) : (col += 1) {
                        win.writeCell(col, y, .{
                            .char  = .{ .grapheme = " ", .width = 1 },
                            .style = row_style,
                        });
                    }
                }
                var x: u16 = 0;
                for (self.columns, 0..) |col, i| {
                    if (i < row.len) {
                        renderCell(win, x, y, widths[i], row[i], col.alignment, row_style);
                    }
                    x += widths[i];
                }
            }
        }
    };
}

/// Render a single cell's text at (x, y) clipped to `cell_width` and
/// aligned within the cell. One column per byte (ASCII); debug builds
/// assert each byte is < 0x80 — the same lifetime/encoding contract
/// the other label-rendering widgets carry.
fn renderCell(
    win: vaxis.Window,
    x: u16,
    y: u16,
    cell_width: u16,
    text: []const u8,
    alignment: Alignment,
    style: vaxis.Cell.Style,
) void {
    if (cell_width == 0) return;
    if (std.debug.runtime_safety) {
        for (text) |b| std.debug.assert(b < 0x80);
    }
    const text_w: u16 = @intCast(@min(text.len, @as(usize, cell_width)));
    const offset: u16 = switch (alignment) {
        .left   => 0,
        .center => (cell_width - text_w) / 2,
        .right  => cell_width - text_w,
    };
    var i: u16 = 0;
    while (i < text_w) : (i += 1) {
        win.writeCell(x + offset + i, y, .{
            .char  = .{ .grapheme = text[i .. i + 1], .width = 1 },
            .style = style,
        });
    }
}

/// Compute per-column widths from a Size descriptor list and a total
/// available width. Output slice must have one entry per column.
///
/// Two passes: fixed and percent values consume from the total in
/// declaration order (so they always get exactly what they ask for,
/// even if it crowds out fractions). Fractions then divide whatever
/// remains by their integer weight. Any rounding remainder lands on
/// the last fraction column so the row sums exactly to `total`.
fn solveColumnWidths(
    comptime C: type,
    columns: []const Column(C),
    total: u16,
    out: []u16,
) void {
    std.debug.assert(out.len == columns.len);
    if (columns.len == 0) return;

    var remaining: u16 = total;
    var total_fractions: u32 = 0;

    for (columns, 0..) |col, i| {
        switch (col.size) {
            .fixed => |w| {
                const assigned: u16 = @intCast(@min(@as(u32, w), @as(u32, remaining)));
                out[i] = assigned;
                remaining -= assigned;
            },
            .percent => |p| {
                const want: u32 = (@as(u32, total) * p) / 100;
                const assigned: u16 = @intCast(@min(want, @as(u32, remaining)));
                out[i] = assigned;
                remaining -= assigned;
            },
            .fraction => |f| {
                out[i] = 0;
                total_fractions += f;
            },
        }
    }

    if (total_fractions == 0) return;

    var sum_assigned: u32 = 0;
    var last_fraction: ?usize = null;
    for (columns, 0..) |col, i| {
        if (col.size == .fraction) {
            const f = col.size.fraction;
            const share: u32 = (@as(u32, remaining) * f) / total_fractions;
            out[i] = @intCast(share);
            sum_assigned += share;
            last_fraction = i;
        }
    }

    // Drop any rounding remainder onto the last fraction column so
    // the total adds up exactly to `total` (minus fixed/percent).
    if (last_fraction) |idx| {
        const leftover: u32 = @as(u32, remaining) - sum_assigned;
        out[idx] += @intCast(leftover);
    }
}

// --- tests -------------------------------------------------------------------

const Color = theme_mod.Color;

test "solveColumnWidths: fixed columns get exactly what they ask for" {
    const cols = [_]Column(Color){
        .{ .header = "a", .size = .{ .fixed = 10 } },
        .{ .header = "b", .size = .{ .fixed = 20 } },
    };
    var out: [2]u16 = undefined;
    solveColumnWidths(Color, &cols, 40, &out);
    try std.testing.expectEqual(@as(u16, 10), out[0]);
    try std.testing.expectEqual(@as(u16, 20), out[1]);
}

test "solveColumnWidths: percent reads from total, not from remaining" {
    const cols = [_]Column(Color){
        .{ .header = "a", .size = .{ .percent = 25 } },
        .{ .header = "b", .size = .{ .percent = 25 } },
    };
    var out: [2]u16 = undefined;
    solveColumnWidths(Color, &cols, 100, &out);
    try std.testing.expectEqual(@as(u16, 25), out[0]);
    try std.testing.expectEqual(@as(u16, 25), out[1]);
}

test "solveColumnWidths: fractions divide the remainder by weight" {
    const cols = [_]Column(Color){
        .{ .header = "a", .size = .{ .fixed = 10 } },
        .{ .header = "b", .size = .{ .fraction = 1 } },
        .{ .header = "c", .size = .{ .fraction = 3 } },
    };
    var out: [3]u16 = undefined;
    solveColumnWidths(Color, &cols, 50, &out);
    try std.testing.expectEqual(@as(u16, 10), out[0]);
    try std.testing.expectEqual(@as(u16, 10), out[1]);
    try std.testing.expectEqual(@as(u16, 30), out[2]);
}

test "solveColumnWidths: rounding remainder lands on the last fraction" {
    // 10 cols remaining, 3 fraction columns at weight 1 each — 10/3 = 3
    // with remainder 1. The trailing fraction column gets the extra.
    const cols = [_]Column(Color){
        .{ .header = "a", .size = .{ .fraction = 1 } },
        .{ .header = "b", .size = .{ .fraction = 1 } },
        .{ .header = "c", .size = .{ .fraction = 1 } },
    };
    var out: [3]u16 = undefined;
    solveColumnWidths(Color, &cols, 10, &out);
    try std.testing.expectEqual(@as(u16, 3), out[0]);
    try std.testing.expectEqual(@as(u16, 3), out[1]);
    try std.testing.expectEqual(@as(u16, 4), out[2]);
}

test "solveColumnWidths: fixed columns clamp to remaining when oversized" {
    // First fixed column eats most of the width; the second fixed
    // can't grow past what's left.
    const cols = [_]Column(Color){
        .{ .header = "a", .size = .{ .fixed = 8 } },
        .{ .header = "b", .size = .{ .fixed = 8 } },
    };
    var out: [2]u16 = undefined;
    solveColumnWidths(Color, &cols, 10, &out);
    try std.testing.expectEqual(@as(u16, 8), out[0]);
    try std.testing.expectEqual(@as(u16, 2), out[1]);
}

test "solveColumnWidths: no-fraction layout leaves leftover unallocated" {
    const cols = [_]Column(Color){
        .{ .header = "a", .size = .{ .fixed = 10 } },
        .{ .header = "b", .size = .{ .fixed = 10 } },
    };
    var out: [2]u16 = undefined;
    solveColumnWidths(Color, &cols, 30, &out);
    // 10 cells of unused width on the right — callers can render
    // padding into that gap if they want it filled.
    try std.testing.expectEqual(@as(u16, 10), out[0]);
    try std.testing.expectEqual(@as(u16, 10), out[1]);
}

fn makeWin(screen: *vaxis.Screen, w: u16, h: u16) vaxis.Window {
    return .{
        .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0,
        .width = w, .height = h, .screen = screen,
    };
}

test "Table.draw: header text appears at each column's left edge by default" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 12, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 12, 2);
    const cols = [_]Column(Color){
        .{ .header = "ab", .size = .{ .fixed = 4 } },
        .{ .header = "cd", .size = .{ .fixed = 4 } },
        .{ .header = "ef", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{ .columns = &cols };
    t.draw(win, &.{}, false, theme_mod.catppuccin_mocha);
    // Column 0 left-edge: cols 0,1 carry "ab".
    try std.testing.expectEqualStrings("a", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("b", screen.readCell(1, 0).?.char.grapheme);
    // Column 1 left-edge: cols 4,5 carry "cd".
    try std.testing.expectEqualStrings("c", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("d", screen.readCell(5, 0).?.char.grapheme);
    // Column 2 left-edge: cols 8,9 carry "ef".
    try std.testing.expectEqualStrings("e", screen.readCell(8, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("f", screen.readCell(9, 0).?.char.grapheme);
}

test "Table.draw: header alignment .center places text in the middle of its column" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 8, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 8, 2);
    const cols = [_]Column(Color){
        .{ .header = "x", .size = .{ .fixed = 8 }, .alignment = .center },
    };
    var t: Table(Color) = .{ .columns = &cols };
    t.draw(win, &.{}, false, theme_mod.catppuccin_mocha);
    // 8-wide column, 1-char text → offset (8-1)/2 = 3.
    try std.testing.expectEqualStrings(" ", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("x", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(4, 0).?.char.grapheme);
}

test "Table.draw: header alignment .right places text at the column's right edge" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 6, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 6, 2);
    const cols = [_]Column(Color){
        .{ .header = "ab", .size = .{ .fixed = 6 }, .alignment = .right },
    };
    var t: Table(Color) = .{ .columns = &cols };
    t.draw(win, &.{}, false, theme_mod.catppuccin_mocha);
    // 6-wide column, 2-char text right-aligned → offset 4.
    try std.testing.expectEqualStrings(" ", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("a", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("b", screen.readCell(5, 0).?.char.grapheme);
}

test "Table.draw: header text wider than its column truncates at the right edge" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 2);
    const cols = [_]Column(Color){
        .{ .header = "longheader", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{ .columns = &cols };
    t.draw(win, &.{}, false, theme_mod.catppuccin_mocha);
    try std.testing.expectEqualStrings("l", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("o", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("n", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("g", screen.readCell(3, 0).?.char.grapheme);
}

test "Table.draw: header_style fg applies to every header cell" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 6, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 6, 2);
    const cols = [_]Column(Color){
        .{ .header = "name", .size = .{ .fixed = 6 } },
    };
    var t: Table(Color) = .{
        .columns      = &cols,
        .header_style = .{ .fg = .color_4 },
    };
    t.draw(win, &.{}, false, theme_mod.catppuccin_mocha);
    const want_fg = theme_mod.catppuccin_mocha.colors.get(.color_4);
    try std.testing.expectEqual(want_fg, screen.readCell(0, 0).?.style.fg);
}

test "Table.draw: rows render below the header at their column positions" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4, .cols = 12, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 12, 4);
    const cols = [_]Column(Color){
        .{ .header = "A", .size = .{ .fixed = 4 } },
        .{ .header = "B", .size = .{ .fixed = 4 } },
        .{ .header = "C", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{ .columns = &cols };
    const rows = [_][]const []const u8{
        &.{ "aa", "bb", "cc" },
        &.{ "dd", "ee", "ff" },
    };
    t.draw(win, &rows, false, theme_mod.catppuccin_mocha);
    // Header at row 0; data row 0 at y=1; data row 1 at y=2.
    try std.testing.expectEqualStrings("a", screen.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("a", screen.readCell(1, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("b", screen.readCell(4, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("c", screen.readCell(8, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("d", screen.readCell(0, 2).?.char.grapheme);
    try std.testing.expectEqualStrings("e", screen.readCell(4, 2).?.char.grapheme);
    try std.testing.expectEqualStrings("f", screen.readCell(8, 2).?.char.grapheme);
}

test "Table.draw: per-column alignment applies to data cells, not just headers" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 6, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 6, 2);
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 6 }, .alignment = .right },
    };
    var t: Table(Color) = .{ .columns = &cols };
    const rows = [_][]const []const u8{
        &.{"42"},
    };
    t.draw(win, &rows, false, theme_mod.catppuccin_mocha);
    // "42" right-aligned in 6 cols → offset 4.
    try std.testing.expectEqualStrings(" ", screen.readCell(3, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("4", screen.readCell(4, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("2", screen.readCell(5, 1).?.char.grapheme);
}

test "Table.draw: rows beyond the window's height are clipped silently" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 3);
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{ .columns = &cols };
    const rows = [_][]const []const u8{
        &.{"r0"},
        &.{"r1"},
        &.{"r2"}, // does not fit — header takes row 0, body has rows 1-2 (2 visible).
        &.{"r3"},
    };
    t.draw(win, &rows, false, theme_mod.catppuccin_mocha);
    try std.testing.expectEqualStrings("r", screen.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("0", screen.readCell(1, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("r", screen.readCell(0, 2).?.char.grapheme);
    try std.testing.expectEqualStrings("1", screen.readCell(1, 2).?.char.grapheme);
    // Row 2 (r2) would land at y=3, outside the window.
}

test "Table.draw: row with fewer cells than columns leaves trailing columns blank" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 8, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 8, 2);
    const cols = [_]Column(Color){
        .{ .header = "a", .size = .{ .fixed = 4 } },
        .{ .header = "b", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{ .columns = &cols };
    // Row supplies only one cell; second column is left as the
    // cell_style fill rather than crashing or wrapping the first
    // cell across columns.
    const rows = [_][]const []const u8{
        &.{"xx"},
    };
    t.draw(win, &rows, false, theme_mod.catppuccin_mocha);
    try std.testing.expectEqualStrings("x", screen.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("x", screen.readCell(1, 1).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(4, 1).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(7, 1).?.char.grapheme);
}

test "Table.draw: cell_style fg applies to non-selected data cells" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 2);
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    // `selected` past the row count means no visible row carries the
    // selection style; row 0 falls through to the cell style.
    var t: Table(Color) = .{
        .columns    = &cols,
        .cell_style = .{ .fg = .color_2 },
        .selected   = std.math.maxInt(usize),
    };
    const rows = [_][]const []const u8{
        &.{"row"},
    };
    t.draw(win, &rows, false, theme_mod.catppuccin_mocha);
    const want_fg = theme_mod.catppuccin_mocha.colors.get(.color_2);
    try std.testing.expectEqual(want_fg, screen.readCell(0, 1).?.style.fg);
}

test "Table.draw: focused selected row uses widget_theme.selected.focused" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 3);
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{
        .columns      = &cols,
        .widget_theme = .{
            .selected = .{
                .focused   = .{ .fg = .color_2, .bg = .color_4 },
                .unfocused = .{ .fg = .color_8 },
            },
        },
        .selected = 1,
    };
    const rows = [_][]const []const u8{
        &.{"r0"},
        &.{"r1"},
    };
    t.draw(win, &rows, true, theme_mod.catppuccin_mocha);
    const want_fg = theme_mod.catppuccin_mocha.colors.get(.color_2);
    const want_bg = theme_mod.catppuccin_mocha.colors.get(.color_4);
    // r1 is the selected row at y=2.
    try std.testing.expectEqual(want_fg, screen.readCell(0, 2).?.style.fg);
    try std.testing.expectEqual(want_bg, screen.readCell(0, 2).?.style.bg);
    // The highlight extends past the text into the trailing cells.
    try std.testing.expectEqual(want_bg, screen.readCell(3, 2).?.style.bg);
}

test "Table.draw: unfocused selected row uses widget_theme.selected.unfocused" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 3);
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{
        .columns      = &cols,
        .widget_theme = .{
            .selected = .{
                .focused   = .{ .fg = .color_2 },
                .unfocused = .{ .fg = .color_8 },
            },
        },
        .selected = 0,
    };
    const rows = [_][]const []const u8{
        &.{"r0"},
    };
    t.draw(win, &rows, false, theme_mod.catppuccin_mocha);
    const want_fg = theme_mod.catppuccin_mocha.colors.get(.color_8);
    try std.testing.expectEqual(want_fg, screen.readCell(0, 1).?.style.fg);
}

test "Table.draw: non-selected rows keep cell_style fg" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 4);
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{
        .columns      = &cols,
        .cell_style   = .{ .fg = .color_2 },
        .widget_theme = .{ .selected = .{
            .focused   = .{ .fg = .color_4 },
            .unfocused = .{},
        } },
        .selected = 0,
    };
    const rows = [_][]const []const u8{
        &.{"r0"},
        &.{"r1"},
        &.{"r2"},
    };
    t.draw(win, &rows, true, theme_mod.catppuccin_mocha);
    const sel_fg = theme_mod.catppuccin_mocha.colors.get(.color_4);
    const cell_fg = theme_mod.catppuccin_mocha.colors.get(.color_2);
    try std.testing.expectEqual(sel_fg,  screen.readCell(0, 1).?.style.fg);
    try std.testing.expectEqual(cell_fg, screen.readCell(0, 2).?.style.fg);
    try std.testing.expectEqual(cell_fg, screen.readCell(0, 3).?.style.fg);
}

test "Table.draw: selected index past the last visible row does not crash" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 3);
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{
        .columns  = &cols,
        .selected = 5, // far beyond the 2 visible rows
    };
    const rows = [_][]const []const u8{
        &.{"r0"},
        &.{"r1"},
    };
    // No selected row is visible — visible rows render with cell_style.
    t.draw(win, &rows, true, theme_mod.catppuccin_mocha);
    try std.testing.expectEqualStrings("r", screen.readCell(0, 1).?.char.grapheme);
}

test "Table.handleKey: j advances the selection, k retreats it" {
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{ .columns = &cols };
    const j: vaxis.Key = .{ .codepoint = 'j' };
    const k: vaxis.Key = .{ .codepoint = 'k' };
    t.handleKey(j, 5);
    try std.testing.expectEqual(@as(usize, 1), t.selected);
    t.handleKey(j, 5);
    t.handleKey(j, 5);
    try std.testing.expectEqual(@as(usize, 3), t.selected);
    t.handleKey(k, 5);
    try std.testing.expectEqual(@as(usize, 2), t.selected);
}

test "Table.handleKey: arrow down and arrow up move the selection" {
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{ .columns = &cols };
    const down: vaxis.Key = .{ .codepoint = vaxis.Key.down };
    const up:   vaxis.Key = .{ .codepoint = vaxis.Key.up };
    t.handleKey(down, 3);
    try std.testing.expectEqual(@as(usize, 1), t.selected);
    t.handleKey(up, 3);
    try std.testing.expectEqual(@as(usize, 0), t.selected);
}

test "Table.handleKey: selection clamps at 0 and at row_count - 1" {
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{ .columns = &cols };
    const j: vaxis.Key = .{ .codepoint = 'j' };
    const k: vaxis.Key = .{ .codepoint = 'k' };
    // k at 0 stays at 0.
    t.handleKey(k, 3);
    try std.testing.expectEqual(@as(usize, 0), t.selected);
    // j past the last row stays at the last row.
    t.handleKey(j, 3);
    t.handleKey(j, 3);
    t.handleKey(j, 3);
    t.handleKey(j, 3);
    try std.testing.expectEqual(@as(usize, 2), t.selected);
}

test "Table.handleKey: row_count == 0 is a safe no-op" {
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{ .columns = &cols };
    const j: vaxis.Key = .{ .codepoint = 'j' };
    t.handleKey(j, 0);
    try std.testing.expectEqual(@as(usize, 0), t.selected);
}

test "Table.draw: selection moving below the window scrolls the data" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 3);
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{ .columns = &cols, .selected = 3 };
    const rows = [_][]const []const u8{
        &.{"r0"},
        &.{"r1"},
        &.{"r2"},
        &.{"r3"},
        &.{"r4"},
    };
    // height = 3 → max_visible = 2. selected = 3 forces scroll_offset = 2.
    // y=1 shows r2, y=2 shows r3 (selected).
    t.draw(win, &rows, true, theme_mod.catppuccin_mocha);
    try std.testing.expectEqual(@as(usize, 2), t.scroll_offset);
    try std.testing.expectEqualStrings("r", screen.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("2", screen.readCell(1, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("r", screen.readCell(0, 2).?.char.grapheme);
    try std.testing.expectEqualStrings("3", screen.readCell(1, 2).?.char.grapheme);
}

test "Table.draw: selection moving above the window scrolls back up" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 3);
    const cols = [_]Column(Color){
        .{ .header = "n", .size = .{ .fixed = 4 } },
    };
    var t: Table(Color) = .{
        .columns      = &cols,
        .selected     = 0,
        .scroll_offset = 3, // stale offset from a previous frame
    };
    const rows = [_][]const []const u8{
        &.{"r0"},
        &.{"r1"},
        &.{"r2"},
        &.{"r3"},
        &.{"r4"},
    };
    t.draw(win, &rows, true, theme_mod.catppuccin_mocha);
    try std.testing.expectEqual(@as(usize, 0), t.scroll_offset);
    try std.testing.expectEqualStrings("r", screen.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("0", screen.readCell(1, 1).?.char.grapheme);
}

test "Table.draw: empty draw does not panic and leaves the window blank-filled" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 3);
    const cols = [_]Column(Color){
        .{ .header = "", .size = .{ .fixed = 4 } },
        .{ .header = "", .size = .{ .fraction = 1 } },
    };
    var t: Table(Color) = .{ .columns = &cols };
    t.draw(win, &.{}, false, theme_mod.catppuccin_mocha);
    // No headers and no rows — entire window is the cell_style fill.
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(9, 0).?.char.grapheme);
}
