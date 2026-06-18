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
//! This file currently contains the column-width solver and the
//! widget skeleton — header, row, and selection rendering land in
//! subsequent commits.

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
        /// Number of rows scrolled off the top. Adjusted by
        /// `handleKey` to keep the selected row visible.
        scroll_offset: usize = 0,

        const Self = @This();

        /// Render the table inside `win`. Header, row, and selection
        /// rendering land in later commits; for now `draw` paints the
        /// cell-style background so an integration site can land the
        /// widget without compile errors. The column-width solver
        /// lives in this commit and is exercised by the test block.
        pub fn draw(
            self: Self,
            win: vaxis.Window,
            rows: []const []const []const u8,
            focused: bool,
            theme: Theme(C),
        ) void {
            _ = rows;
            _ = focused;
            if (win.width == 0 or win.height == 0) return;
            if (self.columns.len > max_columns) return;

            win.fill(.{
                .char  = .{ .grapheme = " ", .width = 1 },
                .style = theme.resolve(self.cell_style),
            });
        }
    };
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

test "Table.draw: empty draw does not panic and leaves the window blank-filled" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win: vaxis.Window = .{
        .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0,
        .width = 10, .height = 3, .screen = &screen,
    };
    const cols = [_]Column(Color){
        .{ .header = "a", .size = .{ .fixed = 4 } },
        .{ .header = "b", .size = .{ .fraction = 1 } },
    };
    const t: Table(Color) = .{ .columns = &cols };
    t.draw(win, &.{}, false, theme_mod.catppuccin_mocha);
    // Every cell is the cell_style fill — header/row rendering lands later.
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(9, 0).?.char.grapheme);
}
