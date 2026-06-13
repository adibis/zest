//! Color palette + theme system.
//!
//! The library palette is intentionally anonymous: 16 ANSI slots and a small
//! set of universal UI roles (background, foreground, cursor, selection).
//! These role names are not opinions about meaning — they match the keys
//! every mainstream terminal theme file (ghostty, kitty, alacritty) already
//! defines, so a theme expressed in any of those formats maps 1:1 onto a
//! Theme(Color) value.
//!
//! Theme and Style are generic over a caller-supplied Color enum, so apps
//! that want semantic role names (chat_text, my_nick, diff_added) define
//! their own enum and Theme(C) value on top, and use it alongside the
//! framework palette in the same draw call.

const std = @import("std");
const vaxis = @import("vaxis");

/// Anonymous palette: 16-slot ANSI + 6 universal UI roles.
/// Maps 1:1 onto ghostty/kitty/alacritty theme files.
pub const Color = enum {
    default,                                          // terminal default

    // 16 ANSI palette slots
    color_0,  color_1,  color_2,  color_3,
    color_4,  color_5,  color_6,  color_7,
    color_8,  color_9,  color_10, color_11,
    color_12, color_13, color_14, color_15,

    // UI roles every terminal theme file defines
    background,    foreground,
    cursor_color,  cursor_text,
    selection_bg,  selection_fg,
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

/// A semantic style: foreground role, background role, text decorations.
/// C is any enum type. null fg/bg means terminal default.
/// Pass to Theme(C).resolve() to obtain a concrete vaxis.Cell.Style.
pub fn Style(comptime C: type) type {
    return struct {
        fg:   ?C        = null,
        bg:   ?C        = null,
        text: TextStyle = .{},
    };
}

/// Maps a color enum to concrete vaxis colors.
/// C is any enum type — use the built-in Color or your own.
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

/// Per-widget color bindings — maps widget roles to palette tokens.
/// Store on the widget at construction; pass Theme(C) at draw time.
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

/// Widget theme for the mocha (dark) default. Binds the focused selection
/// to the theme file's selection_bg/selection_fg roles, which is what every
/// terminal theme file already configures.
pub const mocha_widget: WidgetTheme(Color) = .{
    .selected_focused_fg   = .selection_fg,
    .selected_focused_bg   = .selection_bg,
    .selected_unfocused_fg = .color_4,
    .selected_bold         = true,
};

/// Widget theme for the latte (light) default. Same bindings as mocha_widget;
/// the visible colors come from whichever Theme(Color) the app is using.
pub const latte_widget: WidgetTheme(Color) = .{
    .selected_focused_fg   = .selection_fg,
    .selected_focused_bg   = .selection_bg,
    .selected_unfocused_fg = .color_4,
    .selected_bold         = true,
};

/// Catppuccin Mocha — dark palette. Hex values lifted verbatim from
/// catppuccin/ghostty themes/catppuccin-mocha.conf so any ghostty user
/// running this theme sees the same chrome colors in a Zest app.
pub const catppuccin_mocha: Theme(Color) = .{
    .colors = std.EnumArray(Color, vaxis.Color).init(.{
        .default       = .default,
        // 16 ANSI palette (normal + bright; catppuccin uses identical hex for both)
        .color_0       = .{ .rgb = .{ 0x45, 0x47, 0x5a } },
        .color_1       = .{ .rgb = .{ 0xf3, 0x8b, 0xa8 } },
        .color_2       = .{ .rgb = .{ 0xa6, 0xe3, 0xa1 } },
        .color_3       = .{ .rgb = .{ 0xf9, 0xe2, 0xaf } },
        .color_4       = .{ .rgb = .{ 0x89, 0xb4, 0xfa } },
        .color_5       = .{ .rgb = .{ 0xf5, 0xc2, 0xe7 } },
        .color_6       = .{ .rgb = .{ 0x94, 0xe2, 0xd5 } },
        .color_7       = .{ .rgb = .{ 0xa6, 0xad, 0xc8 } },
        .color_8       = .{ .rgb = .{ 0x58, 0x5b, 0x70 } },
        .color_9       = .{ .rgb = .{ 0xf3, 0x8b, 0xa8 } },
        .color_10      = .{ .rgb = .{ 0xa6, 0xe3, 0xa1 } },
        .color_11      = .{ .rgb = .{ 0xf9, 0xe2, 0xaf } },
        .color_12      = .{ .rgb = .{ 0x89, 0xb4, 0xfa } },
        .color_13      = .{ .rgb = .{ 0xf5, 0xc2, 0xe7 } },
        .color_14      = .{ .rgb = .{ 0x94, 0xe2, 0xd5 } },
        .color_15      = .{ .rgb = .{ 0xba, 0xc2, 0xde } },
        // UI roles
        .background    = .{ .rgb = .{ 0x1e, 0x1e, 0x2e } },
        .foreground    = .{ .rgb = .{ 0xcd, 0xd6, 0xf4 } },
        .cursor_color  = .{ .rgb = .{ 0xf5, 0xe0, 0xdc } },
        .cursor_text   = .{ .rgb = .{ 0x11, 0x11, 0x1b } },
        .selection_bg  = .{ .rgb = .{ 0x35, 0x37, 0x49 } },
        .selection_fg  = .{ .rgb = .{ 0xcd, 0xd6, 0xf4 } },
    }),
};

/// Catppuccin Latte — light palette. Hex values lifted verbatim from
/// catppuccin/ghostty themes/catppuccin-latte.conf.
pub const catppuccin_latte: Theme(Color) = .{
    .colors = std.EnumArray(Color, vaxis.Color).init(.{
        .default       = .default,
        // 16 ANSI palette
        .color_0       = .{ .rgb = .{ 0x5c, 0x5f, 0x77 } },
        .color_1       = .{ .rgb = .{ 0xd2, 0x0f, 0x39 } },
        .color_2       = .{ .rgb = .{ 0x40, 0xa0, 0x2b } },
        .color_3       = .{ .rgb = .{ 0xdf, 0x8e, 0x1d } },
        .color_4       = .{ .rgb = .{ 0x1e, 0x66, 0xf5 } },
        .color_5       = .{ .rgb = .{ 0xea, 0x76, 0xcb } },
        .color_6       = .{ .rgb = .{ 0x17, 0x92, 0x99 } },
        .color_7       = .{ .rgb = .{ 0xac, 0xb0, 0xbe } },
        .color_8       = .{ .rgb = .{ 0x6c, 0x6f, 0x85 } },
        .color_9       = .{ .rgb = .{ 0xd2, 0x0f, 0x39 } },
        .color_10      = .{ .rgb = .{ 0x40, 0xa0, 0x2b } },
        .color_11      = .{ .rgb = .{ 0xdf, 0x8e, 0x1d } },
        .color_12      = .{ .rgb = .{ 0x1e, 0x66, 0xf5 } },
        .color_13      = .{ .rgb = .{ 0xea, 0x76, 0xcb } },
        .color_14      = .{ .rgb = .{ 0x17, 0x92, 0x99 } },
        .color_15      = .{ .rgb = .{ 0xbc, 0xc0, 0xcc } },
        // UI roles
        .background    = .{ .rgb = .{ 0xef, 0xf1, 0xf5 } },
        .foreground    = .{ .rgb = .{ 0x4c, 0x4f, 0x69 } },
        .cursor_color  = .{ .rgb = .{ 0xdc, 0x8a, 0x78 } },
        .cursor_text   = .{ .rgb = .{ 0xef, 0xf1, 0xf5 } },
        .selection_bg  = .{ .rgb = .{ 0xd8, 0xda, 0xe1 } },
        .selection_fg  = .{ .rgb = .{ 0x4c, 0x4f, 0x69 } },
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
    const result = catppuccin_mocha.resolve(.{});
    const want: vaxis.Color = .default;
    try std.testing.expectEqual(want, result.fg);
    try std.testing.expectEqual(want, result.bg);
}

test "Theme.resolve: null fg/bg maps to terminal default" {
    const result = catppuccin_mocha.resolve(.{ .fg = null, .bg = null });
    try std.testing.expectEqual(vaxis.Color.default, result.fg);
    try std.testing.expectEqual(vaxis.Color.default, result.bg);
}

test "Theme.resolve: ANSI palette fg maps to expected rgb" {
    // color_4 is blue in catppuccin mocha.
    const result = catppuccin_mocha.resolve(.{ .fg = .color_4 });
    const want: vaxis.Color = .{ .rgb = .{ 0x89, 0xb4, 0xfa } };
    try std.testing.expectEqual(want, result.fg);
}

test "Theme.resolve: bold text style is forwarded" {
    const result = catppuccin_mocha.resolve(.{ .text = .{ .bold = true } });
    try std.testing.expect(result.bold);
    try std.testing.expect(!result.italic);
}

test "Theme.resolve: dim text style is forwarded" {
    const result = catppuccin_mocha.resolve(.{ .text = .{ .dim = true } });
    try std.testing.expect(result.dim);
}

test "Theme.resolve: underline maps to single underline style" {
    const result = catppuccin_mocha.resolve(.{ .text = .{ .underline = true } });
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.single, result.ul_style);
}

test "Theme.resolve: no underline maps to off" {
    const result = catppuccin_mocha.resolve(.{});
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.off, result.ul_style);
}

test "Theme.resolve: reverse text style is forwarded" {
    const result = catppuccin_mocha.resolve(.{ .text = .{ .reverse = true } });
    try std.testing.expect(result.reverse);
    try std.testing.expect(!result.bold);
}

test "catppuccin_mocha: background matches the ghostty theme file" {
    const want: vaxis.Color = .{ .rgb = .{ 0x1e, 0x1e, 0x2e } };
    try std.testing.expectEqual(want, catppuccin_mocha.colors.get(.background));
}

test "catppuccin_mocha: color_1 is the catppuccin red" {
    const want: vaxis.Color = .{ .rgb = .{ 0xf3, 0x8b, 0xa8 } };
    try std.testing.expectEqual(want, catppuccin_mocha.colors.get(.color_1));
}

test "catppuccin_mocha: selection_bg matches the ghostty theme file" {
    const want: vaxis.Color = .{ .rgb = .{ 0x35, 0x37, 0x49 } };
    try std.testing.expectEqual(want, catppuccin_mocha.colors.get(.selection_bg));
}

test "catppuccin_latte: color_4 is the catppuccin blue" {
    const want: vaxis.Color = .{ .rgb = .{ 0x1e, 0x66, 0xf5 } };
    try std.testing.expectEqual(want, catppuccin_latte.colors.get(.color_4));
}

test "catppuccin_latte: background is light" {
    const want: vaxis.Color = .{ .rgb = .{ 0xef, 0xf1, 0xf5 } };
    try std.testing.expectEqual(want, catppuccin_latte.colors.get(.background));
}

test "WidgetTheme: all fields default to null / selected_bold true" {
    const wt: WidgetTheme(Color) = .{};
    try std.testing.expectEqual(@as(?Color, null), wt.selected_focused_fg);
    try std.testing.expectEqual(@as(?Color, null), wt.selected_focused_bg);
    try std.testing.expectEqual(@as(?Color, null), wt.selected_unfocused_fg);
    try std.testing.expectEqual(@as(?Color, null), wt.selected_unfocused_bg);
    try std.testing.expect(wt.selected_bold);
}

test "mocha_widget: focused selection binds to the theme's selection roles" {
    try std.testing.expectEqual(@as(?Color, .selection_fg), mocha_widget.selected_focused_fg);
    try std.testing.expectEqual(@as(?Color, .selection_bg), mocha_widget.selected_focused_bg);
}

test "mocha_widget: unfocused fg is color_4 (catppuccin blue), no override bg" {
    try std.testing.expectEqual(@as(?Color, .color_4), mocha_widget.selected_unfocused_fg);
    try std.testing.expectEqual(@as(?Color, null),     mocha_widget.selected_unfocused_bg);
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
    const AppColor = enum { bg_role, fg_role, highlight };
    const app_theme: Theme(AppColor) = .{
        .colors = std.EnumArray(AppColor, vaxis.Color).init(.{
            .bg_role   = .{ .index = 0 },
            .fg_role   = .{ .index = 7 },
            .highlight = .{ .index = 3 },
        }),
    };
    const result = app_theme.resolve(Style(AppColor){ .fg = .fg_role, .bg = .bg_role });
    try std.testing.expectEqual(vaxis.Color{ .index = 7 }, result.fg);
    try std.testing.expectEqual(vaxis.Color{ .index = 0 }, result.bg);
}
