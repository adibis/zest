//! Compile-time validated styling via semantic color tokens.
//!
//! Color names what a thing is (primary, muted, danger) — not what it looks
//! like. Theme maps those names to concrete vaxis colors. Widgets receive a
//! Theme at draw time and call resolve() to get vaxis.Cell.Style values.

const std = @import("std");
const vaxis = @import("vaxis");

/// Semantic color roles. Name the purpose, not the pixel value.
pub const Color = enum {
    default,
    primary,
    secondary,
    surface,
    muted,
    danger,
    success,
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
/// Pass to Theme.resolve() to obtain a concrete vaxis.Cell.Style.
pub const Style = struct {
    fg:   Color     = .default,
    bg:   Color     = .default,
    text: TextStyle = .{},
};

/// Maps semantic Color tokens to concrete vaxis colors.
pub const Theme = struct {
    colors: std.EnumArray(Color, vaxis.Color),

    /// Convert a semantic Style to a concrete vaxis.Cell.Style.
    pub fn resolve(self: Theme, style: Style) vaxis.Cell.Style {
        return .{
            .fg       = self.colors.get(style.fg),
            .bg       = self.colors.get(style.bg),
            .bold     = style.text.bold,
            .italic   = style.text.italic,
            .ul_style = if (style.text.underline) .single else .off,
            .dim      = style.text.dim,
            .reverse  = style.text.reverse,
        };
    }

    /// Built-in dark theme (Catppuccin Mocha palette).
    pub const dark: Theme = .{
        .colors = std.EnumArray(Color, vaxis.Color).init(.{
            .default   = .default,
            .primary   = .{ .rgb = .{ 0x89, 0xb4, 0xfa } },
            .secondary = .{ .rgb = .{ 0xb4, 0xbe, 0xfe } },
            .surface   = .{ .rgb = .{ 0x31, 0x32, 0x44 } },
            .muted     = .{ .rgb = .{ 0xa6, 0xad, 0xc8 } },
            .danger    = .{ .rgb = .{ 0xf3, 0x8b, 0xa8 } },
            .success   = .{ .rgb = .{ 0xa6, 0xe3, 0xa1 } },
        }),
    };
};

test "Style: all fields default to zero/unset" {
    const s: Style = .{};
    try std.testing.expectEqual(Color.default, s.fg);
    try std.testing.expectEqual(Color.default, s.bg);
    try std.testing.expect(!s.text.bold);
    try std.testing.expect(!s.text.italic);
    try std.testing.expect(!s.text.underline);
    try std.testing.expect(!s.text.dim);
    try std.testing.expect(!s.text.reverse);
}

test "Theme.resolve: default style produces terminal-default fg and bg" {
    const result = Theme.dark.resolve(.{});
    const want: vaxis.Color = .default;
    try std.testing.expectEqual(want, result.fg);
    try std.testing.expectEqual(want, result.bg);
}

test "Theme.resolve: primary fg maps to the expected rgb" {
    const result = Theme.dark.resolve(.{ .fg = .primary });
    const want: vaxis.Color = .{ .rgb = .{ 0x89, 0xb4, 0xfa } };
    try std.testing.expectEqual(want, result.fg);
}

test "Theme.resolve: bold text style is forwarded" {
    const result = Theme.dark.resolve(.{ .text = .{ .bold = true } });
    try std.testing.expect(result.bold);
    try std.testing.expect(!result.italic);
}

test "Theme.resolve: dim text style is forwarded" {
    const result = Theme.dark.resolve(.{ .text = .{ .dim = true } });
    try std.testing.expect(result.dim);
}

test "Theme.resolve: underline maps to single underline style" {
    const result = Theme.dark.resolve(.{ .text = .{ .underline = true } });
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.single, result.ul_style);
}

test "Theme.resolve: no underline maps to off" {
    const result = Theme.dark.resolve(.{});
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.off, result.ul_style);
}

test "Theme.resolve: reverse text style is forwarded" {
    const result = Theme.dark.resolve(.{ .text = .{ .reverse = true } });
    try std.testing.expect(result.reverse);
    try std.testing.expect(!result.bold);
}

test "Theme.dark: surface color has the expected rgb" {
    const want: vaxis.Color = .{ .rgb = .{ 0x31, 0x32, 0x44 } };
    try std.testing.expectEqual(want, Theme.dark.colors.get(.surface));
}

test "Theme.dark: danger color has the expected rgb" {
    const want: vaxis.Color = .{ .rgb = .{ 0xf3, 0x8b, 0xa8 } };
    try std.testing.expectEqual(want, Theme.dark.colors.get(.danger));
}
