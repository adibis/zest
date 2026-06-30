//! Modal popup overlay.
//!
//! Popup(C) carves a centred child window on top of its parent and
//! returns it to the caller for content rendering. The widget owns
//! its own open / closed state, its size descriptors, and the styling
//! for the border + body fill. Callers handle the content — same
//! pattern `vaxis.Window.child(.{ .border })` already establishes.
//!
//! Sizing uses a small `Dim` tagged union with two variants:
//!
//!   .fixed: u16  — absolute cell count (clamped to parent extent).
//!   .percent: u8 — percentage of the parent's matching dimension.
//!
//! Both dimensions degrade gracefully on tiny parents — the popup
//! shrinks to fit but never reports a negative-sized body window.
//!
//! Subsequent commits add an optional title row, a backdrop dim
//! pass, and handleKey for Esc-to-dismiss.

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("../core/theme.zig");
const Style = theme_mod.Style;
const Theme = theme_mod.Theme;

/// Single-dimension size descriptor for popups. Two variants — a
/// fixed cell count or a percentage of the parent — keep the call
/// site readable without leaning on the layout engine's full Size
/// tagged union (a popup doesn't have a meaningful `.fraction`
/// interpretation).
pub const Dim = union(enum) {
    fixed:   u16,
    percent: u8,
};

pub fn Popup(comptime C: type) type {
    return struct {
        /// True when the popup is visible. `draw` is a no-op when
        /// this is false; the caller flips it via `open` / `close` /
        /// `toggle` or by writing to the field directly.
        is_open:      bool = false,
        /// Popup width in the parent's coordinate system.
        width:        Dim = .{ .percent = 60 },
        /// Popup height in the parent's coordinate system.
        height:       Dim = .{ .percent = 60 },
        /// Style applied to the border cells.
        border_style: Style(C) = .{},
        /// Style applied to every body cell. Caller renders their
        /// own content on top — body style is the canvas.
        body_style:   Style(C) = .{},

        const Self = @This();

        pub fn open(self: *Self) void { self.is_open = true; }
        pub fn close(self: *Self) void { self.is_open = false; }
        pub fn toggle(self: *Self) void { self.is_open = !self.is_open; }

        /// Render the popup's chrome (border + body fill) inside
        /// `win` and return the body window for the caller to draw
        /// content into. Returns `null` when the popup is closed or
        /// the parent window has zero size.
        ///
        /// The body window is the inside-the-border area, so a
        /// caller writes content with normal `(0, 0)`-anchored
        /// coordinates and the border is already in place around it.
        pub fn draw(self: Self, win: vaxis.Window, theme: Theme(C)) ?vaxis.Window {
            if (!self.is_open) return null;
            if (win.width == 0 or win.height == 0) return null;

            const want_w: u16 = dimToCells(self.width, win.width);
            const want_h: u16 = dimToCells(self.height, win.height);
            // Clamp to parent. Minimum 3 cells per axis so border +
            // body always have at least one inner cell; below that
            // we treat it as "no room" and skip.
            const w: u16 = @min(want_w, win.width);
            const h: u16 = @min(want_h, win.height);
            if (w < 3 or h < 3) return null;

            const x_off: u16 = (win.width  - w) / 2;
            const y_off: u16 = (win.height - h) / 2;

            const inner = win.child(.{
                .x_off  = x_off,
                .y_off  = y_off,
                .width  = w,
                .height = h,
                .border = .{ .where = .all, .style = theme.resolve(self.border_style) },
            });
            if (inner.width == 0 or inner.height == 0) return inner;

            inner.fill(.{
                .char  = .{ .grapheme = " ", .width = 1 },
                .style = theme.resolve(self.body_style),
            });
            return inner;
        }
    };
}

fn dimToCells(d: Dim, parent: u16) u16 {
    return switch (d) {
        .fixed   => |c| c,
        .percent => |p| @intCast((@as(u32, parent) * @as(u32, p)) / 100),
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

test "Popup.draw: closed popup returns null and writes nothing" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 10);
    const p: Popup(Color) = .{};
    try std.testing.expectEqual(@as(?vaxis.Window, null), p.draw(win, catppuccin_mocha));
}

test "Popup.draw: open popup returns a body window" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 10);
    const p: Popup(Color) = .{ .is_open = true };
    const body = p.draw(win, catppuccin_mocha);
    try std.testing.expect(body != null);
}

test "Popup.draw: percent dims compute as fraction of parent" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 10);
    const p: Popup(Color) = .{
        .is_open = true,
        .width   = .{ .percent = 50 },
        .height  = .{ .percent = 50 },
    };
    const body = p.draw(win, catppuccin_mocha).?;
    // Parent 20x10, popup 50%/50% → 10x5 outer. Body is one cell
    // smaller on every side because of the border → 8x3.
    try std.testing.expectEqual(@as(u16, 8), body.width);
    try std.testing.expectEqual(@as(u16, 3), body.height);
}

test "Popup.draw: fixed dims pick absolute cell counts" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 20, .cols = 40, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 40, 20);
    const p: Popup(Color) = .{
        .is_open = true,
        .width   = .{ .fixed = 24 },
        .height  = .{ .fixed = 8 },
    };
    const body = p.draw(win, catppuccin_mocha).?;
    try std.testing.expectEqual(@as(u16, 22), body.width);
    try std.testing.expectEqual(@as(u16, 6),  body.height);
}

test "Popup.draw: oversized requests clamp to the parent" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 6, .cols = 12, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 12, 6);
    const p: Popup(Color) = .{
        .is_open = true,
        .width   = .{ .fixed = 100 },
        .height  = .{ .fixed = 100 },
    };
    const body = p.draw(win, catppuccin_mocha).?;
    // Outer clamps to 12x6 → body is 10x4 after the border inset.
    try std.testing.expectEqual(@as(u16, 10), body.width);
    try std.testing.expectEqual(@as(u16, 4),  body.height);
}

test "Popup.draw: window too small for a body skips silently" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 2);
    const p: Popup(Color) = .{
        .is_open = true,
        .width   = .{ .fixed = 2 },
        .height  = .{ .fixed = 2 },
    };
    try std.testing.expectEqual(@as(?vaxis.Window, null), p.draw(win, catppuccin_mocha));
}

test "Popup.draw: body fills cells with body_style fg/bg" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 10);
    const p: Popup(Color) = .{
        .is_open    = true,
        .body_style = .{ .bg = .color_0 },
    };
    _ = p.draw(win, catppuccin_mocha).?;
    // 60%/60% of 20x10 → 12x6 outer, centred at x=4, y=2. The body
    // bg starts inside the border at (5, 3).
    const want_bg = catppuccin_mocha.colors.get(.color_0);
    try std.testing.expectEqual(want_bg, screen.readCell(5, 3).?.style.bg);
}

test "Popup.open / close / toggle: state transitions" {
    var p: Popup(Color) = .{};
    try std.testing.expect(!p.is_open);
    p.open();
    try std.testing.expect(p.is_open);
    p.close();
    try std.testing.expect(!p.is_open);
    p.toggle();
    try std.testing.expect(p.is_open);
    p.toggle();
    try std.testing.expect(!p.is_open);
}

test "Popup(C): works with a user-defined color enum" {
    const AppColor = enum { surface, accent };
    const app_theme: Theme(AppColor) = .{
        .colors = std.EnumArray(AppColor, vaxis.Color).init(.{
            .surface = .{ .index = 0 },
            .accent  = .{ .index = 4 },
        }),
    };
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 6, .cols = 12, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 12, 6);
    const p: Popup(AppColor) = .{
        .is_open      = true,
        .border_style = .{ .fg = .accent },
        .body_style   = .{ .bg = .surface },
    };
    const body = p.draw(win, app_theme).?;
    try std.testing.expect(body.width > 0);
}
