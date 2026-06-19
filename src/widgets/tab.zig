//! Horizontal tab strip for switching between views.
//!
//! Tab(C) renders a row of labels — one per available view —
//! highlighting the active one. The widget carries the active index
//! as state, and `handleKey` advances or retreats it on number keys
//! and arrow keys. Apps drive content selection off
//! `tab.active`: typical use is a switch inside `draw` that fans
//! out to a per-view render function.
//!
//! Visual identity:
//!
//!   ` Tab 0   Tab 1   Tab 2 `
//!     ^^^^^^^                  ← active_style (typically bold + accent)
//!             ^^^^^^^^^^^^^^^  ← inactive_style (typically dim)
//!
//! Labels are padded with a single space on each side so adjacent
//! tabs read as distinct strips. A taller window leaves the rows
//! below the strip alone; the optional active-indicator underline
//! lands in a follow-up commit.

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("../core/theme.zig");
const Style = theme_mod.Style;
const Theme = theme_mod.Theme;

pub fn Tab(comptime C: type) type {
    return struct {
        /// Tab labels rendered left-to-right. Slice memory is
        /// borrowed; the caller keeps it alive for the tab's
        /// lifetime. File-scope const literals are the typical shape.
        labels:         []const []const u8,
        /// Index of the currently active tab. `handleKey` mutates
        /// this; consumers read it to decide which view to render.
        active:         usize = 0,
        /// Style applied to the active tab's cells.
        active_style:   Style(C) = .{},
        /// Style applied to inactive tabs and inter-tab gaps.
        inactive_style: Style(C) = .{},

        const Self = @This();

        /// Render the tab strip on row 0 of `win`. Labels render one
        /// column per byte (ASCII); debug builds assert each byte is
        /// < 0x80, matching the lifetime/encoding contract the other
        /// label-rendering widgets carry.
        pub fn draw(self: Self, win: vaxis.Window, theme: Theme(C)) void {
            if (win.width == 0 or win.height == 0) return;
            if (self.labels.len == 0) return;

            const active_resolved = theme.resolve(self.active_style);
            const inactive_resolved = theme.resolve(self.inactive_style);

            var x: u16 = 0;
            for (self.labels, 0..) |label, i| {
                if (std.debug.runtime_safety) {
                    for (label) |b| std.debug.assert(b < 0x80);
                }
                const style = if (i == self.active) active_resolved else inactive_resolved;

                if (x >= win.width) break;
                win.writeCell(x, 0, .{
                    .char  = .{ .grapheme = " ", .width = 1 },
                    .style = style,
                });
                x += 1;

                var li: usize = 0;
                while (li < label.len and x < win.width) : (li += 1) {
                    win.writeCell(x, 0, .{
                        .char  = .{ .grapheme = label[li .. li + 1], .width = 1 },
                        .style = style,
                    });
                    x += 1;
                }

                if (x < win.width) {
                    win.writeCell(x, 0, .{
                        .char  = .{ .grapheme = " ", .width = 1 },
                        .style = style,
                    });
                    x += 1;
                }

                // Inter-tab gap (one space, inactive style) — only
                // between tabs, not after the last one.
                if (i + 1 < self.labels.len and x < win.width) {
                    win.writeCell(x, 0, .{
                        .char  = .{ .grapheme = " ", .width = 1 },
                        .style = inactive_resolved,
                    });
                    x += 1;
                }
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

test "Tab.draw: labels render left-to-right with single-space padding" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 1);
    const labels = [_][]const u8{ "Demo", "Dash" };
    const t: Tab(Color) = .{ .labels = &labels };
    t.draw(win, catppuccin_mocha);
    // " Demo " " Dash " — each label is padded by 1 space, gap of 1
    // between tabs.
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("D", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("e", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("m", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("o", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(5, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(6, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(7, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("D", screen.readCell(8, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("a", screen.readCell(9, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("s", screen.readCell(10, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("h", screen.readCell(11, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(12, 0).?.char.grapheme);
}

test "Tab.draw: active tab uses active_style" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 1);
    const labels = [_][]const u8{ "A", "B" };
    const t: Tab(Color) = .{
        .labels         = &labels,
        .active         = 1,
        .active_style   = .{ .fg = .color_4, .text = .{ .bold = true } },
        .inactive_style = .{ .fg = .color_8 },
    };
    t.draw(win, catppuccin_mocha);
    const active_fg   = catppuccin_mocha.colors.get(.color_4);
    const inactive_fg = catppuccin_mocha.colors.get(.color_8);
    // " A " " B " — A is at cols 0-2, B is at cols 4-6.
    try std.testing.expectEqual(inactive_fg, screen.readCell(0, 0).?.style.fg);
    try std.testing.expectEqual(inactive_fg, screen.readCell(1, 0).?.style.fg);
    try std.testing.expectEqual(active_fg,   screen.readCell(4, 0).?.style.fg);
    try std.testing.expectEqual(active_fg,   screen.readCell(5, 0).?.style.fg);
    try std.testing.expectEqual(active_fg,   screen.readCell(6, 0).?.style.fg);
}

test "Tab.draw: labels exceeding width truncate at the right edge" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 6, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 6, 1);
    const labels = [_][]const u8{ "Long", "Tail" };
    const t: Tab(Color) = .{ .labels = &labels };
    t.draw(win, catppuccin_mocha);
    // " Long " fits in 6 cols; "Tail" doesn't fit at all.
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("L", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("o", screen.readCell(2, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("n", screen.readCell(3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("g", screen.readCell(4, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(5, 0).?.char.grapheme);
}

test "Tab.draw: zero labels is a safe no-op" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const t: Tab(Color) = .{ .labels = &.{} };
    t.draw(win, catppuccin_mocha);
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "Tab.draw: zero-width window does not panic" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 0, 1);
    const labels = [_][]const u8{"X"};
    const t: Tab(Color) = .{ .labels = &labels };
    t.draw(win, catppuccin_mocha);
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "Tab(C): works with a user-defined color enum" {
    const AppColor = enum { accent, dim };
    const app_theme: Theme(AppColor) = .{
        .colors = std.EnumArray(AppColor, vaxis.Color).init(.{
            .accent = .{ .index = 4 },
            .dim    = .{ .index = 8 },
        }),
    };
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 10, 1);
    const labels = [_][]const u8{"X"};
    const t: Tab(AppColor) = .{
        .labels       = &labels,
        .active_style = .{ .fg = .accent },
    };
    t.draw(win, app_theme);
    const want_fg: vaxis.Color = .{ .index = 4 };
    try std.testing.expectEqual(want_fg, screen.readCell(0, 0).?.style.fg);
}
