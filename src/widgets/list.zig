//! Scrollable list widget — state and navigation.
//!
//! List(C) owns selection, scroll offset, and widget-level color token
//! bindings (WidgetTheme(C)). Item data is passed at draw time as a slice
//! — the widget never stores or allocates it.
//!
//! Navigation (moveDown, moveUp) updates selected only. Scroll tracking
//! is deferred to draw(), which calls ensureVisible() before rendering so
//! selected is always in the visible window.

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod  = @import("../core/theme.zig");
const Color      = theme_mod.Color;
const Style      = theme_mod.Style;
const Theme      = theme_mod.Theme;
const WidgetTheme = theme_mod.WidgetTheme;
const catppuccin_mocha = theme_mod.catppuccin_mocha;
const mocha_widget     = theme_mod.mocha_widget;

/// Scrollable list widget parameterized on a color token enum.
/// C is any enum type — use the built-in Color or your own.
pub fn List(comptime C: type) type {
    return struct {
        selected:     usize        = 0,
        scroll:       usize        = 0,
        /// Color token bindings for selection highlight. Set at construction;
        /// defaults to all-null (terminal default for all roles).
        widget_theme: WidgetTheme(C) = .{},

        const Self = @This();

        /// Advance selection by one. No-op when already at the last item or
        /// when item_count is zero.
        pub fn moveDown(self: *Self, item_count: usize) void {
            if (item_count == 0) return;
            if (self.selected + 1 < item_count) self.selected += 1;
        }

        /// Retreat selection by one. No-op when already at the first item.
        pub fn moveUp(self: *Self) void {
            if (self.selected > 0) self.selected -= 1;
        }

        /// Adjust scroll so selected is within [scroll, scroll + height).
        /// draw() calls this before rendering to keep the selected row visible.
        pub fn ensureVisible(self: *Self, height: usize) void {
            if (height == 0) return;
            if (self.selected < self.scroll) self.scroll = self.selected;
            if (self.selected >= self.scroll + height) self.scroll = self.selected - height + 1;
        }

        /// Render visible items into win.
        /// Selected row is highlighted using widget_theme token bindings.
        /// Calls ensureVisible() so selected is always in view.
        pub fn draw(
            self: *Self,
            win: vaxis.Window,
            items: []const []const u8,
            focused: bool,
            theme: Theme(C),
        ) void {
            if (win.height == 0) return;
            self.ensureVisible(win.height);
            const visible_end = @min(items.len, self.scroll + @as(usize, win.height));
            for (items[self.scroll..visible_end], 0..) |item, i| {
                const row: u16 = @intCast(i);
                const cell_style = if (self.scroll + i == self.selected)
                    theme.resolve(self.widget_theme.selected.pick(focused))
                else
                    theme.resolve(Style(C){});
                // Fill the full row so the highlight bg extends to the right edge.
                for (0..win.width) |col| win.writeCell(@intCast(col), row, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = cell_style,
                });
                _ = win.print(&.{.{ .text = item, .style = cell_style }}, .{
                    .wrap = .none, .row_offset = row,
                });
            }
        }

        /// Handle a keypress. Recognises j/↓ (down) and k/↑ (up).
        pub fn handleKey(self: *Self, key: vaxis.Key, item_count: usize) void {
            switch (key.codepoint) {
                'j', vaxis.Key.down => self.moveDown(item_count),
                'k', vaxis.Key.up   => self.moveUp(),
                else                => {},
            }
        }

        /// Clamp selected and scroll to remain valid for a new item count.
        /// Call whenever the item slice changes size.
        pub fn setCount(self: *Self, count: usize) void {
            if (count == 0) {
                self.selected = 0;
                self.scroll = 0;
                return;
            }
            self.selected = @min(self.selected, count - 1);
            self.scroll = @min(self.scroll, self.selected);
        }
    };
}

test "List: initial state is selected=0 scroll=0" {
    const l: List(Color) = .{};
    try std.testing.expectEqual(0, l.selected);
    try std.testing.expectEqual(0, l.scroll);
}

test "List.moveDown: advances selected" {
    var l: List(Color) = .{};
    l.moveDown(5);
    try std.testing.expectEqual(1, l.selected);
    l.moveDown(5);
    try std.testing.expectEqual(2, l.selected);
}

test "List.moveDown: clamps at last item" {
    var l: List(Color) = .{};
    l.moveDown(1);
    try std.testing.expectEqual(0, l.selected);
    l.moveDown(3);
    l.moveDown(3);
    l.moveDown(3); // already at 2, one extra call
    try std.testing.expectEqual(2, l.selected);
}

test "List.moveDown: no-op when item_count is zero" {
    var l: List(Color) = .{};
    l.moveDown(0);
    try std.testing.expectEqual(0, l.selected);
}

test "List.moveUp: retreats selected" {
    var l: List(Color) = .{ .selected = 3 };
    l.moveUp();
    try std.testing.expectEqual(2, l.selected);
}

test "List.moveUp: no-op at first item (no underflow)" {
    var l: List(Color) = .{};
    l.moveUp();
    try std.testing.expectEqual(0, l.selected);
}

test "List.ensureVisible: scrolls down when selected falls below window" {
    var l: List(Color) = .{ .selected = 5, .scroll = 0 };
    l.ensureVisible(3); // window shows rows 0-2; row 5 is out
    try std.testing.expectEqual(3, l.scroll); // scroll = 5 - 3 + 1
}

test "List.ensureVisible: scrolls up when selected is above window" {
    var l: List(Color) = .{ .selected = 1, .scroll = 4 };
    l.ensureVisible(3);
    try std.testing.expectEqual(1, l.scroll);
}

test "List.ensureVisible: no-op when selected is already visible" {
    var l: List(Color) = .{ .selected = 2, .scroll = 1 };
    l.ensureVisible(4); // window shows rows 1-4; row 2 is inside
    try std.testing.expectEqual(1, l.scroll);
}

test "List.setCount: clamps selected when count shrinks" {
    var l: List(Color) = .{ .selected = 7, .scroll = 5 };
    l.setCount(3);
    try std.testing.expectEqual(2, l.selected);
    try std.testing.expectEqual(2, l.scroll);
}

test "List.setCount: resets to zero when count becomes zero" {
    var l: List(Color) = .{ .selected = 4, .scroll = 2 };
    l.setCount(0);
    try std.testing.expectEqual(0, l.selected);
    try std.testing.expectEqual(0, l.scroll);
}

test "List.setCount: no-op when selected is still in range" {
    var l: List(Color) = .{ .selected = 2, .scroll = 1 };
    l.setCount(10);
    try std.testing.expectEqual(2, l.selected);
    try std.testing.expectEqual(1, l.scroll);
}

// --- draw tests --------------------------------------------------------------

fn makeWin(screen: *vaxis.Screen, w: u16, h: u16) vaxis.Window {
    return .{
        .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0,
        .width = w, .height = h, .screen = screen,
    };
}

test "List.draw: item text appears at the correct row" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 5, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    var l: List(Color) = .{ .widget_theme = mocha_widget };
    l.draw(makeWin(&screen, 20, 5), &.{ "alpha", "beta", "gamma" }, false, catppuccin_mocha);
    try std.testing.expectEqualStrings("a", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("b", screen.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("g", screen.readCell(0, 2).?.char.grapheme);
}

test "List.draw: focused selected row uses selection_bg and bold across full width" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    var l: List(Color) = .{ .selected = 1, .widget_theme = mocha_widget };
    l.draw(makeWin(&screen, 10, 3), &.{ "one", "two", "three" }, true, catppuccin_mocha);
    const sel_bg = catppuccin_mocha.colors.get(.selection_bg);
    try std.testing.expectEqual(sel_bg, screen.readCell(0, 1).?.style.bg);
    try std.testing.expect(screen.readCell(0, 1).?.style.bold);
    try std.testing.expectEqual(sel_bg, screen.readCell(9, 1).?.style.bg); // trailing space too
}

test "List.draw: unfocused selected row uses color_4 fg and bold, no override bg" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    var l: List(Color) = .{ .selected = 0, .widget_theme = mocha_widget };
    l.draw(makeWin(&screen, 10, 3), &.{ "one", "two" }, false, catppuccin_mocha);
    const blue = catppuccin_mocha.colors.get(.color_4);
    try std.testing.expectEqual(blue, screen.readCell(0, 0).?.style.fg);
    try std.testing.expect(screen.readCell(0, 0).?.style.bold);
    try std.testing.expectEqual(vaxis.Color.default, screen.readCell(0, 0).?.style.bg);
}

test "List.draw: scroll offset shifts visible items" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    // scroll=2: items[2] and items[3] are visible
    var l: List(Color) = .{ .selected = 2, .scroll = 2, .widget_theme = mocha_widget };
    l.draw(makeWin(&screen, 10, 2), &.{ "a", "b", "c", "d" }, false, catppuccin_mocha);
    try std.testing.expectEqualStrings("c", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("d", screen.readCell(0, 1).?.char.grapheme);
}

test "List.handleKey: j advances selection, k retreats it" {
    var l: List(Color) = .{};
    l.handleKey(.{ .codepoint = 'j' }, 5);
    try std.testing.expectEqual(1, l.selected);
    l.handleKey(.{ .codepoint = 'k' }, 5);
    try std.testing.expectEqual(0, l.selected);
}

test "List.handleKey: down/up arrow keys work like j/k" {
    var l: List(Color) = .{};
    l.handleKey(.{ .codepoint = vaxis.Key.down }, 3);
    try std.testing.expectEqual(1, l.selected);
    l.handleKey(.{ .codepoint = vaxis.Key.up }, 3);
    try std.testing.expectEqual(0, l.selected);
}

test "List(C): works with a user-defined color enum" {
    const AppColor = enum { bg, fg, sel };
    const app_wt: WidgetTheme(AppColor) = .{
        .selected = .{
            .focused   = .{ .fg = .fg, .bg = .sel },
            .unfocused = .{},
        },
    };
    const app_theme: Theme(AppColor) = .{
        .colors = std.EnumArray(AppColor, vaxis.Color).init(.{
            .bg  = .{ .index = 0 },
            .fg  = .{ .index = 7 },
            .sel = .{ .index = 3 },
        }),
    };
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    var l: List(AppColor) = .{ .selected = 0, .widget_theme = app_wt };
    l.draw(makeWin(&screen, 10, 2), &.{ "item" }, true, app_theme);
    try std.testing.expectEqual(vaxis.Color{ .index = 3 }, screen.readCell(0, 0).?.style.bg);
    try std.testing.expectEqual(vaxis.Color{ .index = 7 }, screen.readCell(0, 0).?.style.fg);
}

test "List.draw: empty slice does not panic" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    var l: List(Color) = .{ .widget_theme = mocha_widget };
    // With no items the draw loop body never executes. Verify no panic.
    l.draw(makeWin(&screen, 10, 3), &.{}, false, catppuccin_mocha);
    // Screen cells remain at their init default — no bold, no accent background.
    try std.testing.expect(!screen.readCell(0, 0).?.style.bold);
    try std.testing.expectEqual(vaxis.Color.default, screen.readCell(0, 0).?.style.bg);
}
