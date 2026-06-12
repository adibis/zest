//! Scrollable list widget — state and navigation.
//!
//! List owns selection and scroll offset. Item data is passed at draw time
//! as a slice — the widget never stores or allocates it.
//!
//! Navigation (moveDown, moveUp) updates selected only. Scroll tracking
//! is deferred to draw(), which calls ensureVisible() before rendering so
//! selected is always in the visible window.

const std = @import("std");
const vaxis = @import("vaxis");
const Theme = @import("../core/theme.zig").Theme;

pub const List = struct {
    selected: usize = 0,
    scroll:   usize = 0,

    /// Advance selection by one. No-op when already at the last item or
    /// when item_count is zero.
    pub fn moveDown(self: *List, item_count: usize) void {
        if (item_count == 0) return;
        if (self.selected + 1 < item_count) self.selected += 1;
    }

    /// Retreat selection by one. No-op when already at the first item.
    pub fn moveUp(self: *List) void {
        if (self.selected > 0) self.selected -= 1;
    }

    /// Adjust scroll so selected is within [scroll, scroll + height).
    /// draw() calls this before rendering to keep the selected row visible.
    pub fn ensureVisible(self: *List, height: usize) void {
        if (height == 0) return;
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + height) self.scroll = self.selected - height + 1;
    }

    /// Render visible items into win.
    /// Selected row is highlighted: primary bg when focused, primary fg when not.
    /// Calls ensureVisible() so selected is always in view.
    pub fn draw(
        self: *List,
        win: vaxis.Window,
        items: []const []const u8,
        focused: bool,
        theme: Theme,
    ) void {
        if (win.height == 0) return;
        self.ensureVisible(win.height);
        const visible_end = @min(items.len, self.scroll + @as(usize, win.height));
        for (items[self.scroll..visible_end], 0..) |item, i| {
            const row: u16 = @intCast(i);
            const cell_style = if (self.scroll + i == self.selected)
                theme.resolve(if (focused)
                    .{ .fg = .surface, .bg = .accent, .text = .{ .bold = true } }
                else
                    .{ .fg = .primary, .text = .{ .bold = true } })
            else
                theme.resolve(.{});
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
    pub fn handleKey(self: *List, key: vaxis.Key, item_count: usize) void {
        switch (key.codepoint) {
            'j', vaxis.Key.down => self.moveDown(item_count),
            'k', vaxis.Key.up   => self.moveUp(),
            else                => {},
        }
    }

    /// Clamp selected and scroll to remain valid for a new item count.
    /// Call whenever the item slice changes size.
    pub fn setCount(self: *List, count: usize) void {
        if (count == 0) {
            self.selected = 0;
            self.scroll = 0;
            return;
        }
        self.selected = @min(self.selected, count - 1);
        self.scroll = @min(self.scroll, self.selected);
    }
};

test "List: initial state is selected=0 scroll=0" {
    const l: List = .{};
    try std.testing.expectEqual(0, l.selected);
    try std.testing.expectEqual(0, l.scroll);
}

test "List.moveDown: advances selected" {
    var l: List = .{};
    l.moveDown(5);
    try std.testing.expectEqual(1, l.selected);
    l.moveDown(5);
    try std.testing.expectEqual(2, l.selected);
}

test "List.moveDown: clamps at last item" {
    var l: List = .{};
    l.moveDown(1);
    try std.testing.expectEqual(0, l.selected);
    l.moveDown(3);
    l.moveDown(3);
    l.moveDown(3); // already at 2, one extra call
    try std.testing.expectEqual(2, l.selected);
}

test "List.moveDown: no-op when item_count is zero" {
    var l: List = .{};
    l.moveDown(0);
    try std.testing.expectEqual(0, l.selected);
}

test "List.moveUp: retreats selected" {
    var l: List = .{ .selected = 3 };
    l.moveUp();
    try std.testing.expectEqual(2, l.selected);
}

test "List.moveUp: no-op at first item (no underflow)" {
    var l: List = .{};
    l.moveUp();
    try std.testing.expectEqual(0, l.selected);
}

test "List.ensureVisible: scrolls down when selected falls below window" {
    var l: List = .{ .selected = 5, .scroll = 0 };
    l.ensureVisible(3); // window shows rows 0-2; row 5 is out
    try std.testing.expectEqual(3, l.scroll); // scroll = 5 - 3 + 1
}

test "List.ensureVisible: scrolls up when selected is above window" {
    var l: List = .{ .selected = 1, .scroll = 4 };
    l.ensureVisible(3);
    try std.testing.expectEqual(1, l.scroll);
}

test "List.ensureVisible: no-op when selected is already visible" {
    var l: List = .{ .selected = 2, .scroll = 1 };
    l.ensureVisible(4); // window shows rows 1-4; row 2 is inside
    try std.testing.expectEqual(1, l.scroll);
}

test "List.setCount: clamps selected when count shrinks" {
    var l: List = .{ .selected = 7, .scroll = 5 };
    l.setCount(3);
    try std.testing.expectEqual(2, l.selected);
    try std.testing.expectEqual(2, l.scroll);
}

test "List.setCount: resets to zero when count becomes zero" {
    var l: List = .{ .selected = 4, .scroll = 2 };
    l.setCount(0);
    try std.testing.expectEqual(0, l.selected);
    try std.testing.expectEqual(0, l.scroll);
}

test "List.setCount: no-op when selected is still in range" {
    var l: List = .{ .selected = 2, .scroll = 1 };
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
    var l: List = .{};
    l.draw(makeWin(&screen, 20, 5), &.{ "alpha", "beta", "gamma" }, false, Theme.dark);
    try std.testing.expectEqualStrings("a", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("b", screen.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("g", screen.readCell(0, 2).?.char.grapheme);
}

test "List.draw: focused selected row has accent bg and bold across full width" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    var l: List = .{ .selected = 1 };
    l.draw(makeWin(&screen, 10, 3), &.{ "one", "two", "three" }, true, Theme.dark);
    const accent = Theme.dark.colors.get(.accent);
    try std.testing.expectEqual(accent, screen.readCell(0, 1).?.style.bg);
    try std.testing.expect(screen.readCell(0, 1).?.style.bold);
    try std.testing.expectEqual(accent, screen.readCell(9, 1).?.style.bg); // trailing space too
}

test "List.draw: unfocused selected row has primary fg and bold, no accent bg" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    var l: List = .{ .selected = 0 };
    l.draw(makeWin(&screen, 10, 3), &.{ "one", "two" }, false, Theme.dark);
    const primary = Theme.dark.colors.get(.primary);
    try std.testing.expectEqual(primary, screen.readCell(0, 0).?.style.fg);
    try std.testing.expect(screen.readCell(0, 0).?.style.bold);
    try std.testing.expectEqual(vaxis.Color.default, screen.readCell(0, 0).?.style.bg);
}

test "List.draw: scroll offset shifts visible items" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 10, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    // scroll=2: items[2] and items[3] are visible
    var l: List = .{ .selected = 2, .scroll = 2 };
    l.draw(makeWin(&screen, 10, 2), &.{ "a", "b", "c", "d" }, false, Theme.dark);
    try std.testing.expectEqualStrings("c", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("d", screen.readCell(0, 1).?.char.grapheme);
}

test "List.handleKey: j advances selection, k retreats it" {
    var l: List = .{};
    l.handleKey(.{ .codepoint = 'j' }, 5);
    try std.testing.expectEqual(1, l.selected);
    l.handleKey(.{ .codepoint = 'k' }, 5);
    try std.testing.expectEqual(0, l.selected);
}

test "List.handleKey: down/up arrow keys work like j/k" {
    var l: List = .{};
    l.handleKey(.{ .codepoint = vaxis.Key.down }, 3);
    try std.testing.expectEqual(1, l.selected);
    l.handleKey(.{ .codepoint = vaxis.Key.up }, 3);
    try std.testing.expectEqual(0, l.selected);
}
