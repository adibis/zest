//! Animated indeterminate loading indicator.
//!
//! Spinner(C) cycles through a caller-supplied sequence of glyphs to
//! signal that an operation is in progress without committing to a
//! known completion percentage. The widget owns its current frame
//! index; call `advance()` to step to the next glyph.
//!
//! `advance` is typically wired to the App's `.tick` event for a
//! smooth cadence — but the tick is best-effort at the producer (see
//! `App.RunOpts.tick_interval`), so apps should treat advance as
//! "step at least once per visible interval" rather than "exactly N
//! steps per second." A burst of ticks after a queue drain produces a
//! lurch forward, which is the right semantics for an indeterminate
//! indicator.
//!
//! `default_frames` is the 10-frame braille spinner widely used by
//! CLI tooling. `frame_sets` exposes named alternatives (`braille`,
//! `pulse`, `line`) so callers who want a different visual can
//! override `frames` without restating both `frames` and `style`.

const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("../core/theme.zig");
const Style = theme_mod.Style;
const Theme = theme_mod.Theme;

/// Default braille spinner — 10 frames, smooth rotation.
pub const default_frames: []const []const u8 = &.{
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
};

/// Named frame sets for common spinner visuals. Static lifetime, safe
/// to assign to `Spinner.frames` without thinking about lifetime.
/// See `feedback-vaxis-string-lifetime` style notes for why slice
/// memory passed to a long-lived widget needs to outlive the widget.
pub const frame_sets = struct {
    /// 10-frame braille rotation — smooth, professional, the CLI default.
    pub const braille:  []const []const u8 = default_frames;
    /// 4-frame ASCII line spinner — works on any terminal, retro feel.
    pub const line:     []const []const u8 = &.{ "|", "/", "-", "\\" };
    /// 4-frame block fade — heavy, eye-catching, good for "active" emphasis.
    pub const pulse:    []const []const u8 = &.{ "█", "▓", "▒", "░" };
    /// 4-frame braille subset — subtle, low-attention bouncing dot.
    pub const dots:     []const []const u8 = &.{ "⠁", "⠂", "⠄", "⠂" };
    /// 4-frame quarter-circle arc — smooth, geometric, distinct from braille.
    pub const arc:      []const []const u8 = &.{ "◜", "◝", "◞", "◟" };
    /// 4-frame half-circle rotation — strong shape, reads as a sphere.
    pub const circle:   []const []const u8 = &.{ "◐", "◓", "◑", "◒" };
    /// 4-frame corner-pointing triangle — directional, attention-grabbing.
    pub const triangle: []const []const u8 = &.{ "◢", "◣", "◤", "◥" };
    /// 4-frame quadrant block dance — playful, slightly chunky.
    pub const block:    []const []const u8 = &.{ "▖", "▘", "▝", "▗" };
};

pub fn Spinner(comptime C: type) type {
    return struct {
        /// Glyph sequence cycled by `advance()`. Slice memory is
        /// borrowed; the caller must keep it alive for the spinner's
        /// lifetime. The named entries in `frame_sets` are static and
        /// always safe to assign here.
        frames:      []const []const u8 = default_frames,
        /// Style applied to the rendered glyph at draw time.
        style:       Style(C) = .{},
        /// Index into `frames`. Wrapped to `frames.len` by `advance()`.
        frame_index: usize = 0,

        const Self = @This();

        /// Step to the next frame, wrapping to 0 past the end. The
        /// empty-frames guard lives here once; `draw` doesn't repeat
        /// it because draw's own zero-width guard subsumes the "no
        /// frame to render" case.
        pub fn advance(self: *Self) void {
            if (self.frames.len == 0) return;
            self.frame_index = (self.frame_index + 1) % self.frames.len;
        }

        /// Render the current frame at row 0 of `win`. Adjacent cells
        /// in row 0 are not touched — the spinner is a single-glyph
        /// indicator and leaves room for adjacent content.
        pub fn draw(self: Self, win: vaxis.Window, theme: Theme(C)) void {
            // Single guard covers zero-size window AND empty frames:
            // there's nothing to print without both a destination cell
            // and a glyph to put in it.
            if (win.width == 0 or win.height == 0 or self.frames.len == 0) return;
            const frame = self.frames[self.frame_index];
            _ = win.print(
                &.{.{ .text = frame, .style = theme.resolve(self.style) }},
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

test "Spinner: default frames are the 10-frame braille set" {
    const s: Spinner(Color) = .{};
    try std.testing.expectEqual(@as(usize, 10), s.frames.len);
    try std.testing.expectEqualStrings("⠋", s.frames[0]);
    try std.testing.expectEqualStrings("⠏", s.frames[9]);
}

test "Spinner.advance: cycles through frames and wraps around" {
    var s: Spinner(Color) = .{};
    try std.testing.expectEqual(@as(usize, 0), s.frame_index);
    s.advance();
    try std.testing.expectEqual(@as(usize, 1), s.frame_index);
    var i: usize = 0;
    while (i < 9) : (i += 1) s.advance();
    // Started at 1, advanced 9 more → 10, wraps to 0.
    try std.testing.expectEqual(@as(usize, 0), s.frame_index);
}

test "Spinner.advance: empty frames slice is a no-op" {
    var s: Spinner(Color) = .{ .frames = &.{} };
    s.advance();
    try std.testing.expectEqual(@as(usize, 0), s.frame_index);
}

test "Spinner.draw: renders the current frame at (0, 0)" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const s: Spinner(Color) = .{};
    s.draw(win, catppuccin_mocha);
    try std.testing.expectEqualStrings("⠋", screen.readCell(0, 0).?.char.grapheme);
}

test "Spinner.draw: advanced frame renders at (0, 0)" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    var s: Spinner(Color) = .{};
    s.advance();
    s.advance();
    s.draw(win, catppuccin_mocha);
    try std.testing.expectEqualStrings("⠹", screen.readCell(0, 0).?.char.grapheme);
}

test "Spinner.draw: custom frame set" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    var s: Spinner(Color) = .{ .frames = frame_sets.line };
    s.draw(win, catppuccin_mocha);
    try std.testing.expectEqualStrings("|", screen.readCell(0, 0).?.char.grapheme);
    s.advance();
    s.draw(win, catppuccin_mocha);
    try std.testing.expectEqualStrings("/", screen.readCell(0, 0).?.char.grapheme);
}

test "Spinner.draw: zero-width window does not panic" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 0, 1);
    const s: Spinner(Color) = .{};
    s.draw(win, catppuccin_mocha);
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "Spinner.draw: empty frames slice is a no-op" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const s: Spinner(Color) = .{ .frames = &.{} };
    s.draw(win, catppuccin_mocha);
    try std.testing.expectEqualStrings(" ", screen.readCell(0, 0).?.char.grapheme);
}

test "Spinner.draw: style fg applies to the rendered glyph" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const s: Spinner(Color) = .{ .style = .{ .fg = .color_2 } };
    s.draw(win, catppuccin_mocha);
    const want_fg = catppuccin_mocha.colors.get(.color_2);
    try std.testing.expectEqual(want_fg, screen.readCell(0, 0).?.style.fg);
}

test "Spinner(C): works with a user-defined color enum" {
    const AppColor = enum { background, accent };
    const app_theme: Theme(AppColor) = .{
        .colors = std.EnumArray(AppColor, vaxis.Color).init(.{
            .background = .{ .index = 0 },
            .accent     = .{ .index = 3 },
        }),
    };
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1, .cols = 4, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, 4, 1);
    const s: Spinner(AppColor) = .{ .style = .{ .fg = .accent } };
    s.draw(win, app_theme);
    const want_fg: vaxis.Color = .{ .index = 3 };
    try std.testing.expectEqual(want_fg, screen.readCell(0, 0).?.style.fg);
}

test "frame_sets: named alternatives have non-empty frame counts" {
    try std.testing.expect(frame_sets.braille.len > 0);
    try std.testing.expect(frame_sets.pulse.len > 0);
    try std.testing.expect(frame_sets.line.len > 0);
    try std.testing.expect(frame_sets.dots.len > 0);
    try std.testing.expect(frame_sets.arc.len > 0);
    try std.testing.expect(frame_sets.circle.len > 0);
    try std.testing.expect(frame_sets.triangle.len > 0);
    try std.testing.expect(frame_sets.block.len > 0);
}
