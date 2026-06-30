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
//! When `title` is non-empty, the popup paints a banded header on
//! the body's top row (styled per `title_style`) and the returned
//! body window starts one row lower. The caller's content
//! coordinates stay at (0, 0); they don't have to know whether a
//! title row is present.
//!
//! When `backdrop_style` is non-default, the popup first repaints
//! every parent cell outside its own footprint with the backdrop
//! style — typically a dim or default-bg blanket — so the popup
//! visually pops above the rest of the screen. The pass writes
//! spaces, so any content the parent had already painted is
//! discarded under the dim. Apps that want to preserve parent
//! visibility leave backdrop_style at its default and the parent
//! content shows through unaltered.
//!
//! `handleKey` consumes Esc when the popup is open and closes it,
//! returning `true` so the caller short-circuits further routing.
//! All other keys (and any key when the popup is closed) return
//! `false` so the caller continues routing normally. Apps that
//! want different dismissal semantics (Enter, q, y/n) inspect
//! `is_open` and act directly rather than calling handleKey.

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
        /// Optional title text rendered on a banded top row inside
        /// the border. The empty default skips the title row, and
        /// the returned body window covers the full inner area.
        /// One column per byte (ASCII); debug builds assert.
        title:        []const u8 = "",
        /// Style applied to every cell of the title row when
        /// `title` is non-empty.
        title_style:  Style(C) = .{},
        /// Optional style applied to every parent cell *outside*
        /// the popup's own footprint. When non-default, the popup
        /// repaints those cells with this style before drawing
        /// itself — typically a dim or default-bg blanket so the
        /// popup visually pops above the rest of the screen.
        /// Defaults to "no backdrop": the parent content shows
        /// through unaltered.
        backdrop_style: ?Style(C) = null,

        const Self = @This();

        pub fn open(self: *Self) void { self.is_open = true; }
        pub fn close(self: *Self) void { self.is_open = false; }
        pub fn toggle(self: *Self) void { self.is_open = !self.is_open; }

        /// Close the popup on Esc. Returns `true` if the keypress
        /// was consumed (the popup was open and Esc closed it) so
        /// callers can short-circuit further routing; returns
        /// `false` for every other key and for any key while the
        /// popup is closed.
        pub fn handleKey(self: *Self, key: vaxis.Key) bool {
            if (!self.is_open) return false;
            if (key.matches(vaxis.Key.escape, .{})) {
                self.is_open = false;
                return true;
            }
            return false;
        }

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

            // Backdrop dim — paint every parent cell that isn't
            // inside the popup's outer rect. Doing this before
            // carving the inner window means the popup's own border
            // and body overwrite the backdrop cleanly.
            if (self.backdrop_style) |bs| {
                const backdrop = theme.resolve(bs);
                var y: u16 = 0;
                while (y < win.height) : (y += 1) {
                    var x: u16 = 0;
                    while (x < win.width) : (x += 1) {
                        const in_popup = x >= x_off and x < x_off + w
                            and y >= y_off and y < y_off + h;
                        if (in_popup) continue;
                        win.writeCell(x, y, .{
                            .char  = .{ .grapheme = " ", .width = 1 },
                            .style = backdrop,
                        });
                    }
                }
            }

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

            if (self.title.len == 0) return inner;
            if (std.debug.runtime_safety) {
                for (self.title) |b| std.debug.assert(b < 0x80);
            }
            // Paint the title row first so title_style.bg spans the
            // full width, then write the title text on top. The
            // returned body window starts one row below the title.
            const title_resolved = theme.resolve(self.title_style);
            var col: u16 = 0;
            while (col < inner.width) : (col += 1) {
                inner.writeCell(col, 0, .{
                    .char  = .{ .grapheme = " ", .width = 1 },
                    .style = title_resolved,
                });
            }
            const title_w: u16 = @intCast(@min(self.title.len, @as(usize, inner.width)));
            const title_x: u16 = (inner.width - title_w) / 2;
            var ti: usize = 0;
            while (ti < title_w) : (ti += 1) {
                inner.writeCell(title_x + @as(u16, @intCast(ti)), 0, .{
                    .char  = .{ .grapheme = self.title[ti .. ti + 1], .width = 1 },
                    .style = title_resolved,
                });
            }

            if (inner.height == 1) {
                // No room below the title — return a zero-height
                // body so the caller's loops are safe but render
                // nothing.
                return inner.child(.{ .y_off = 1, .height = 0 });
            }
            return inner.child(.{ .y_off = 1, .height = inner.height - 1 });
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

test "Popup.draw: title row is painted centred on row 0 of the inner area" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 10);
    const p: Popup(Color) = .{
        .is_open = true,
        .width   = .{ .percent = 60 },
        .height  = .{ .percent = 60 },
        .title   = "Help",
    };
    _ = p.draw(win, catppuccin_mocha).?;
    // Popup outer 12x6, centred at (4, 2). Border occupies the
    // perimeter, so the inner content starts at (5, 3) with width
    // 10. Title "Help" (4 bytes) centred in 10 → starts at offset 3,
    // i.e. absolute screen col 5 + 3 = 8.
    try std.testing.expectEqualStrings("H", screen.readCell(8,  3).?.char.grapheme);
    try std.testing.expectEqualStrings("e", screen.readCell(9,  3).?.char.grapheme);
    try std.testing.expectEqualStrings("l", screen.readCell(10, 3).?.char.grapheme);
    try std.testing.expectEqualStrings("p", screen.readCell(11, 3).?.char.grapheme);
}

test "Popup.draw: title_style.bg paints the full title row" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 10);
    const p: Popup(Color) = .{
        .is_open     = true,
        .width       = .{ .percent = 60 },
        .height      = .{ .percent = 60 },
        .title       = "X",
        .title_style = .{ .bg = .color_4 },
    };
    _ = p.draw(win, catppuccin_mocha).?;
    const want_bg = catppuccin_mocha.colors.get(.color_4);
    // Inner row starts at screen y=3, spans cols 5..14.
    try std.testing.expectEqual(want_bg, screen.readCell(5,  3).?.style.bg);
    try std.testing.expectEqual(want_bg, screen.readCell(9,  3).?.style.bg);
    try std.testing.expectEqual(want_bg, screen.readCell(14, 3).?.style.bg);
}

test "Popup.draw: empty title returns the full inner area as body" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 10);
    const p: Popup(Color) = .{
        .is_open = true,
        .width   = .{ .percent = 60 },
        .height  = .{ .percent = 60 },
    };
    const body = p.draw(win, catppuccin_mocha).?;
    // 60%/60% of 20x10 → 12x6 outer → 10x4 inner with no title.
    try std.testing.expectEqual(@as(u16, 10), body.width);
    try std.testing.expectEqual(@as(u16, 4),  body.height);
}

test "Popup.draw: title set, body window shrinks by one row" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 10);
    const p: Popup(Color) = .{
        .is_open = true,
        .width   = .{ .percent = 60 },
        .height  = .{ .percent = 60 },
        .title   = "Help",
    };
    const body = p.draw(win, catppuccin_mocha).?;
    try std.testing.expectEqual(@as(u16, 10), body.width);
    try std.testing.expectEqual(@as(u16, 3),  body.height);
}

test "Popup.draw: backdrop_style repaints cells outside the popup footprint" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 10);
    const p: Popup(Color) = .{
        .is_open        = true,
        .width          = .{ .percent = 60 },
        .height         = .{ .percent = 60 },
        .backdrop_style = .{ .bg = .color_0 },
    };
    _ = p.draw(win, catppuccin_mocha).?;
    // 60%/60% of 20x10 → popup outer rect 12x6 centred at (4, 2),
    // covering cols 4..15 and rows 2..7. Cells outside that rect
    // carry the backdrop bg; cells inside it carry the popup's own
    // border / body styles.
    const want_bg = catppuccin_mocha.colors.get(.color_0);
    try std.testing.expectEqual(want_bg, screen.readCell(0, 0).?.style.bg);
    try std.testing.expectEqual(want_bg, screen.readCell(19, 9).?.style.bg);
    try std.testing.expectEqual(want_bg, screen.readCell(3, 5).?.style.bg);
    try std.testing.expectEqual(want_bg, screen.readCell(16, 5).?.style.bg);
}

test "Popup.draw: backdrop_style leaves cells inside the popup untouched" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 10);
    const p: Popup(Color) = .{
        .is_open        = true,
        .width          = .{ .percent = 60 },
        .height         = .{ .percent = 60 },
        .body_style     = .{ .bg = .color_3 },
        .backdrop_style = .{ .bg = .color_0 },
    };
    _ = p.draw(win, catppuccin_mocha).?;
    // Inside the border: body_style bg. Cell (5, 3) is the top-
    // left inner cell, which carries the body fill.
    const want_body_bg = catppuccin_mocha.colors.get(.color_3);
    try std.testing.expectEqual(want_body_bg, screen.readCell(5, 3).?.style.bg);
}

test "Popup.draw: null backdrop_style leaves parent cells alone" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 20, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 20, 10);
    // Pre-paint a cell outside where the popup will land.
    win.writeCell(0, 0, .{
        .char  = .{ .grapheme = "X", .width = 1 },
        .style = .{},
    });
    const p: Popup(Color) = .{
        .is_open = true,
        .width   = .{ .percent = 40 },
        .height  = .{ .percent = 40 },
    };
    _ = p.draw(win, catppuccin_mocha).?;
    // Without a backdrop, the pre-painted "X" still shows.
    try std.testing.expectEqualStrings("X", screen.readCell(0, 0).?.char.grapheme);
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

test "Popup.handleKey: Esc closes an open popup and returns true" {
    var p: Popup(Color) = .{ .is_open = true };
    const esc: vaxis.Key = .{ .codepoint = vaxis.Key.escape };
    const consumed = p.handleKey(esc);
    try std.testing.expect(consumed);
    try std.testing.expect(!p.is_open);
}

test "Popup.handleKey: closed popup returns false on every key" {
    var p: Popup(Color) = .{};
    const esc: vaxis.Key = .{ .codepoint = vaxis.Key.escape };
    try std.testing.expect(!p.handleKey(esc));
    const j: vaxis.Key = .{ .codepoint = 'j' };
    try std.testing.expect(!p.handleKey(j));
}

test "Popup.handleKey: non-Esc key while open returns false and leaves state alone" {
    var p: Popup(Color) = .{ .is_open = true };
    const j: vaxis.Key = .{ .codepoint = 'j' };
    try std.testing.expect(!p.handleKey(j));
    try std.testing.expect(p.is_open);
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
