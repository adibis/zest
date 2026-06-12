//! Compile-time validated styling via semantic color tokens.
//!
//! Color names what a thing is (primary, muted, danger) — not what it looks
//! like. Theme maps those names to concrete vaxis colors. Widgets receive a
//! Theme at draw time and call resolve() to get vaxis.Cell.Style values.
//!
//! Theme and Style are generic over a caller-supplied Color enum, so apps can
//! define domain-specific token sets (e.g. faction colors, DEFCON states)
//! without touching the framework. The built-in Color enum and dark constant
//! serve as the default palette for apps that don't need custom tokens.

const std = @import("std");
const vaxis = @import("vaxis");

/// Built-in semantic color roles used by the framework's default theme.
/// Apps that need domain-specific tokens should define their own enum and
/// pass it to Theme(C) and Style(C) directly.
pub const Color = enum {
    default,
    primary,
    secondary,
    surface,
    muted,
    danger,
    success,
    /// Selection cursor / highlight background.
    accent,
};

/// Additive text decorations. Packed so the entire set fits in one byte.
pub const TextStyle = packed struct {
    bold:      bool = false,
    italic:    bool = false,
    underline: bool = false,
    dim:       bool = false,
    /// Swap fg and bg using the terminal's own colors. Works on every terminal
    /// regardless of 24-bit color support — ideal for selection cursors.
    reverse:   bool = false,
};

/// A semantic style: foreground, background, and text decorations.
/// C is any enum type. null fg/bg means terminal default.
/// Pass to Theme(C).resolve() to obtain a concrete vaxis.Cell.Style.
pub fn Style(comptime C: type) type {
    return struct {
        fg:   ?C        = null,
        bg:   ?C        = null,
        text: TextStyle = .{},
    };
}

/// Maps semantic Color tokens to concrete vaxis colors.
/// C is any enum type — supply the built-in Color or your own.
pub fn Theme(comptime C: type) type {
    return struct {
        colors: std.EnumArray(C, vaxis.Color),

        /// Convert a semantic Style(C) to a concrete vaxis.Cell.Style.
        /// null fg/bg maps to terminal default.
        pub fn resolve(self: @This(), style: Style(C)) vaxis.Cell.Style {
            return .{
                .fg       = if (style.fg) |c| self.colors.get(c) else .default,
                .bg       = if (style.bg) |c| self.colors.get(c) else .default,
                .bold     = style.text.bold,
                .italic   = style.text.italic,
                .ul_style = if (style.text.underline) .single else .off,
                .dim      = style.text.dim,
                .reverse  = style.text.reverse,
            };
        }
    };
}

/// Per-widget style configuration — maps widget roles to app color tokens.
/// Store on the widget at construction time; pass Theme(C) at draw time.
/// All token fields are optional: null means terminal default for that role.
pub fn WidgetTheme(comptime C: type) type {
    return struct {
        selected_focused_fg:   ?C   = null,
        selected_focused_bg:   ?C   = null,
        selected_unfocused_fg: ?C   = null,
        selected_unfocused_bg: ?C   = null,
        selected_bold:          bool = true,
    };
}

/// Default widget theme for the built-in dark palette.
pub const dark_widget: WidgetTheme(Color) = .{
    .selected_focused_fg   = .surface,
    .selected_focused_bg   = .accent,
    .selected_unfocused_fg = .primary,
    .selected_bold         = true,
};

/// Built-in dark theme (Catppuccin Mocha palette) using the framework Color enum.
pub const dark: Theme(Color) = .{
    .colors = std.EnumArray(Color, vaxis.Color).init(.{
        .default   = .default,
        .primary   = .{ .rgb = .{ 0x89, 0xb4, 0xfa } },
        .secondary = .{ .rgb = .{ 0xb4, 0xbe, 0xfe } },
        .surface   = .{ .rgb = .{ 0x31, 0x32, 0x44 } },
        .muted     = .{ .rgb = .{ 0xa6, 0xad, 0xc8 } },
        .danger    = .{ .rgb = .{ 0xf3, 0x8b, 0xa8 } },
        .success   = .{ .rgb = .{ 0xa6, 0xe3, 0xa1 } },
        .accent    = .{ .rgb = .{ 0xf9, 0xe2, 0xaf } }, // yellow
    }),
};

test "Style: all fields default to zero/unset" {
    const s: Style(Color) = .{};
    try std.testing.expectEqual(@as(?Color, null), s.fg);
    try std.testing.expectEqual(@as(?Color, null), s.bg);
    try std.testing.expect(!s.text.bold);
    try std.testing.expect(!s.text.italic);
    try std.testing.expect(!s.text.underline);
    try std.testing.expect(!s.text.dim);
    try std.testing.expect(!s.text.reverse);
}

test "Theme.resolve: default style produces terminal-default fg and bg" {
    const result = dark.resolve(.{});
    const want: vaxis.Color = .default;
    try std.testing.expectEqual(want, result.fg);
    try std.testing.expectEqual(want, result.bg);
}

test "Theme.resolve: null fg/bg maps to terminal default" {
    const result = dark.resolve(.{ .fg = null, .bg = null });
    try std.testing.expectEqual(vaxis.Color.default, result.fg);
    try std.testing.expectEqual(vaxis.Color.default, result.bg);
}

test "Theme.resolve: primary fg maps to the expected rgb" {
    const result = dark.resolve(.{ .fg = .primary });
    const want: vaxis.Color = .{ .rgb = .{ 0x89, 0xb4, 0xfa } };
    try std.testing.expectEqual(want, result.fg);
}

test "Theme.resolve: bold text style is forwarded" {
    const result = dark.resolve(.{ .text = .{ .bold = true } });
    try std.testing.expect(result.bold);
    try std.testing.expect(!result.italic);
}

test "Theme.resolve: dim text style is forwarded" {
    const result = dark.resolve(.{ .text = .{ .dim = true } });
    try std.testing.expect(result.dim);
}

test "Theme.resolve: underline maps to single underline style" {
    const result = dark.resolve(.{ .text = .{ .underline = true } });
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.single, result.ul_style);
}

test "Theme.resolve: no underline maps to off" {
    const result = dark.resolve(.{});
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.off, result.ul_style);
}

test "Theme.resolve: reverse text style is forwarded" {
    const result = dark.resolve(.{ .text = .{ .reverse = true } });
    try std.testing.expect(result.reverse);
    try std.testing.expect(!result.bold);
}

test "dark: surface color has the expected rgb" {
    const want: vaxis.Color = .{ .rgb = .{ 0x31, 0x32, 0x44 } };
    try std.testing.expectEqual(want, dark.colors.get(.surface));
}

test "dark: danger color has the expected rgb" {
    const want: vaxis.Color = .{ .rgb = .{ 0xf3, 0x8b, 0xa8 } };
    try std.testing.expectEqual(want, dark.colors.get(.danger));
}

test "dark: accent color has the expected rgb" {
    const want: vaxis.Color = .{ .rgb = .{ 0xf9, 0xe2, 0xaf } };
    try std.testing.expectEqual(want, dark.colors.get(.accent));
}

test "WidgetTheme: all fields default to null / selected_bold true" {
    const wt: WidgetTheme(Color) = .{};
    try std.testing.expectEqual(@as(?Color, null), wt.selected_focused_fg);
    try std.testing.expectEqual(@as(?Color, null), wt.selected_focused_bg);
    try std.testing.expectEqual(@as(?Color, null), wt.selected_unfocused_fg);
    try std.testing.expectEqual(@as(?Color, null), wt.selected_unfocused_bg);
    try std.testing.expect(wt.selected_bold);
}

test "dark_widget: focused tokens are surface/accent" {
    try std.testing.expectEqual(@as(?Color, .surface), dark_widget.selected_focused_fg);
    try std.testing.expectEqual(@as(?Color, .accent),  dark_widget.selected_focused_bg);
}

test "dark_widget: unfocused tokens are primary fg, no bg" {
    try std.testing.expectEqual(@as(?Color, .primary), dark_widget.selected_unfocused_fg);
    try std.testing.expectEqual(@as(?Color, null),     dark_widget.selected_unfocused_bg);
}

test "WidgetTheme(C): works with a user-defined color enum" {
    const AppColor = enum { bg, fg, sel };
    const wt: WidgetTheme(AppColor) = .{
        .selected_focused_fg = .fg,
        .selected_focused_bg = .sel,
    };
    try std.testing.expectEqual(@as(?AppColor, .fg),  wt.selected_focused_fg);
    try std.testing.expectEqual(@as(?AppColor, .sel), wt.selected_focused_bg);
    try std.testing.expectEqual(@as(?AppColor, null), wt.selected_unfocused_fg);
}

test "Theme(C): works with a user-defined color enum" {
    const AppColor = enum { background, foreground, highlight };
    const app_theme: Theme(AppColor) = .{
        .colors = std.EnumArray(AppColor, vaxis.Color).init(.{
            .background = .{ .index = 0 },
            .foreground = .{ .index = 7 },
            .highlight  = .{ .index = 3 },
        }),
    };
    const result = app_theme.resolve(Style(AppColor){ .fg = .foreground, .bg = .background });
    try std.testing.expectEqual(vaxis.Color{ .index = 7 }, result.fg);
    try std.testing.expectEqual(vaxis.Color{ .index = 0 }, result.bg);
}
