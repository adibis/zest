//! Tutorial widget — example of the custom widget protocol.
//!
//! This file is a *tutorial*, not part of the public widget set. It
//! shows every convention the library's built-in widgets already
//! follow, applied to the smallest possible widget — an on/off
//! toggle that flips when Space or Enter is pressed. Fork the file
//! as a starting point for your own widget; the pattern is the same
//! whether you're building a CPU meter, a config-row editor, or a
//! pop-up dialog.
//!
//! Conventions demonstrated:
//!
//!   1. **Generic over `C`** — `Toggle(comptime C: type) type`
//!      returns a struct parameterised by the caller's Color enum,
//!      so the same widget composes with any palette an app
//!      defines.
//!   2. **Visual identity on the struct** — `on_style` and
//!      `off_style` are typed `Style(C)` and live as struct fields,
//!      so an instance carries everything `draw` needs to render
//!      itself except the per-frame data.
//!   3. **State on the struct** — `is_on` is the widget's
//!      persistent state. Defaults make `Toggle(C){}` immediately
//!      usable; apps that want to start in a non-default state set
//!      the field at construction.
//!   4. **`draw(self, win, theme)`** — every widget takes the
//!      window first, then any per-frame data (none for Toggle),
//!      then the active theme last. `self` is `Self` (const) when
//!      draw doesn't mutate state; `*Self` (mutable) when it does
//!      — for example, Table's draw adjusts `scroll_offset`.
//!   5. **`handleKey(self, key)`** — optional, takes `*Self` since
//!      key handling almost always mutates state. Returns `void`;
//!      apps decide elsewhere whether the keypress should consume
//!      any further routing.
//!   6. **Inline tests** — the test block at the bottom of the
//!      file verifies the contract end-to-end. The other library
//!      widget files (progress.zig, gauge.zig, etc.) follow this
//!      shape too.
//!
//! Not exported from `root.zig` — readers copy the file into their
//! own widget tree and rename the type. The test block keeps it
//! compiling alongside the library so docs and code stay in sync.

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("../core/theme.zig");
const Style = theme_mod.Style;
const Theme = theme_mod.Theme;

pub fn Toggle(comptime C: type) type {
    return struct {
        /// Style applied when `is_on` is true. Typical recipe: a
        /// bright fg with a bold decoration.
        on_style:  Style(C) = .{},
        /// Style applied when `is_on` is false. Typical recipe: a
        /// dim fg without bold.
        off_style: Style(C) = .{},
        /// Current toggle state. Flipped by `handleKey`; read by
        /// callers to drive linked UI.
        is_on:     bool = false,

        const Self = @This();

        /// Flip `is_on` on Space or Enter. Other keys are ignored;
        /// the caller routes them elsewhere.
        pub fn handleKey(self: *Self, key: vaxis.Key) void {
            const is_space = key.matches(' ', .{});
            const is_enter = key.matches(vaxis.Key.enter, .{});
            if (is_space or is_enter) self.is_on = !self.is_on;
        }

        /// Render the toggle as "[*]" when on or "[ ]" when off,
        /// styled per the active state. Single row, three columns.
        pub fn draw(self: Self, win: vaxis.Window, theme: Theme(C)) void {
            if (win.width == 0 or win.height == 0) return;
            const style = theme.resolve(if (self.is_on) self.on_style else self.off_style);
            const glyph: []const u8 = if (self.is_on) "[*]" else "[ ]";
            _ = win.print(
                &.{.{ .text = glyph, .style = style }},
                .{ .wrap = .none },
            );
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

test "Toggle: default state is off" {
    const t: Toggle(Color) = .{};
    try std.testing.expect(!t.is_on);
}

test "Toggle.handleKey: space flips the toggle" {
    var t: Toggle(Color) = .{};
    const space: vaxis.Key = .{ .codepoint = ' ' };
    t.handleKey(space);
    try std.testing.expect(t.is_on);
    t.handleKey(space);
    try std.testing.expect(!t.is_on);
}

test "Toggle.handleKey: enter flips the toggle" {
    var t: Toggle(Color) = .{};
    const enter: vaxis.Key = .{ .codepoint = vaxis.Key.enter };
    t.handleKey(enter);
    try std.testing.expect(t.is_on);
}

test "Toggle.handleKey: other keys are ignored" {
    var t: Toggle(Color) = .{};
    const j: vaxis.Key = .{ .codepoint = 'j' };
    t.handleKey(j);
    try std.testing.expect(!t.is_on);
}

test "Toggle.draw: off state renders the empty glyph" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const t: Toggle(Color) = .{};
    t.draw(win, catppuccin_mocha);
    try std.testing.expectEqualStrings("[", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(" ", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("]", screen.readCell(2, 0).?.char.grapheme);
}

test "Toggle.draw: on state renders the filled glyph" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const t: Toggle(Color) = .{ .is_on = true };
    t.draw(win, catppuccin_mocha);
    try std.testing.expectEqualStrings("[", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("*", screen.readCell(1, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("]", screen.readCell(2, 0).?.char.grapheme);
}

test "Toggle.draw: on_style fg applies in on state" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const t: Toggle(Color) = .{
        .on_style = .{ .fg = .color_2 },
        .is_on    = true,
    };
    t.draw(win, catppuccin_mocha);
    const want_fg = catppuccin_mocha.colors.get(.color_2);
    try std.testing.expectEqual(want_fg, screen.readCell(0, 0).?.style.fg);
}

test "Toggle.draw: zero-width window does not panic" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 0, 1);
    const t: Toggle(Color) = .{};
    t.draw(win, catppuccin_mocha);
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "Toggle(C): works with a user-defined color enum" {
    const AppColor = enum { ok, warn };
    const app_theme: Theme(AppColor) = .{
        .colors = std.EnumArray(AppColor, vaxis.Color).init(.{
            .ok   = .{ .index = 2 },
            .warn = .{ .index = 3 },
        }),
    };
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const t: Toggle(AppColor) = .{
        .on_style = .{ .fg = .ok },
        .is_on    = true,
    };
    t.draw(win, app_theme);
    const want_fg: vaxis.Color = .{ .index = 2 };
    try std.testing.expectEqual(want_fg, screen.readCell(0, 0).?.style.fg);
}
