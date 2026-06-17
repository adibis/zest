//! Sub-cell fill discretisation.
//!
//! Maps a fraction in [0.0, 1.0] along an axis of `extent` cells into a
//! whole-cell count plus a 0..7 partial-eighth remainder. Caller renders
//! whole cells as `full_glyph`, the next cell (if remainder is non-zero)
//! as `partial_glyphs[remainder]`, and the rest as the empty glyph.
//!
//! Two axes are supported and the only difference is which Unicode block
//! family fills the partial cell:
//!
//!   .left_fill  → ▏▎▍▌▋▊▉  (horizontal bars; ProgressBar, horizontal Gauge)
//!   .lower_fill → ▁▂▃▄▅▆▇  (vertical bars; vertical Gauge, future histograms)
//!
//! NaN inputs are coerced to zero before clamping. Without that guard
//! `std.math.clamp(NaN, 0, 1)` propagates NaN through IEEE 754, and
//! `@intFromFloat(NaN)` is illegal behavior in Zig — UB in ReleaseFast,
//! panic in ReleaseSafe. Apps computing fractions as `done / total` would
//! UB the moment `total == 0`. The widget layer should never have to
//! defend against that on every call site, so the guard lives here.

const std = @import("std");
const Style = @import("../core/theme.zig").Style;

pub const Axis = enum { left_fill, lower_fill };

pub fn Discretise(comptime axis: Axis) type {
    return struct {
        /// 8 partial glyphs indexed 0..7. Index 0 (empty cell) is a space
        /// rather than a zero-width sentinel so callers can write it
        /// directly when a partial slot is empty.
        pub const partial_glyphs: [8][]const u8 = switch (axis) {
            .left_fill  => .{ " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉" },
            .lower_fill => .{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇" },
        };

        /// Whole-cell glyph for both axes — same Unicode block.
        pub const full_glyph: []const u8 = "█";

        pub const Measure = struct {
            whole: u16,
            partial_eighths: u3,
        };

        /// Convert a fraction in [0.0, 1.0] along `extent` cells into
        /// (whole_cells, partial_eighths). NaN is coerced to zero; out-of-
        /// range fractions clamp. The partial remainder is the count of
        /// 1/8 sub-cell fills past the last whole cell.
        pub fn measure(extent: u16, fraction: f32) Measure {
            const sanitized = if (std.math.isNan(fraction)) 0.0 else fraction;
            const clamped = std.math.clamp(sanitized, 0.0, 1.0);
            const eighths: u32 = @intFromFloat(
                @as(f32, @floatFromInt(extent)) * clamped * 8.0,
            );
            return .{
                .whole = @intCast(eighths / 8),
                .partial_eighths = @intCast(eighths % 8),
            };
        }
    };
}

/// Compose the style used to render the partial-fill cell at a
/// fill/empty boundary: text decorations and foreground come from the
/// filled style (the half-block glyph that's about to be painted in the
/// fill colour), and background comes from the empty style (the other
/// half of the cell is still empty). Using a helper instead of a struct
/// literal means the composition keeps working when `Style(C)` grows a
/// new field — callers don't have to remember to extend a hand-written
/// `Style(C){ ... }` at every call site.
pub fn partialStyle(comptime C: type, filled: Style(C), empty: Style(C)) Style(C) {
    return .{
        .fg   = filled.fg,
        .bg   = empty.bg,
        .text = filled.text,
    };
}

// --- tests -------------------------------------------------------------------

test "Discretise(.left_fill): partial_glyphs are the left-fill blocks" {
    const D = Discretise(.left_fill);
    try std.testing.expectEqualStrings(" ", D.partial_glyphs[0]);
    try std.testing.expectEqualStrings("▏", D.partial_glyphs[1]);
    try std.testing.expectEqualStrings("▉", D.partial_glyphs[7]);
    try std.testing.expectEqualStrings("█", D.full_glyph);
}

test "Discretise(.lower_fill): partial_glyphs are the lower-fill blocks" {
    const D = Discretise(.lower_fill);
    try std.testing.expectEqualStrings(" ", D.partial_glyphs[0]);
    try std.testing.expectEqualStrings("▁", D.partial_glyphs[1]);
    try std.testing.expectEqualStrings("▇", D.partial_glyphs[7]);
    try std.testing.expectEqualStrings("█", D.full_glyph);
}

test "Discretise.measure: fraction = 0 → zero whole, zero partial" {
    const m = Discretise(.left_fill).measure(10, 0.0);
    try std.testing.expectEqual(@as(u16, 0), m.whole);
    try std.testing.expectEqual(@as(u3, 0), m.partial_eighths);
}

test "Discretise.measure: fraction = 1 → all whole, zero partial" {
    const m = Discretise(.left_fill).measure(10, 1.0);
    try std.testing.expectEqual(@as(u16, 10), m.whole);
    try std.testing.expectEqual(@as(u3, 0), m.partial_eighths);
}

test "Discretise.measure: 1/16 of a 1-cell extent → 0 whole + 1/8 partial" {
    // 1 cell × 1/16 fraction × 8 eighths/cell = 0.5 eighths → truncates to 0.
    // Use 2 cells at 1/16 = 0.0625 → 1 eighth.
    const m = Discretise(.left_fill).measure(2, 0.0625);
    try std.testing.expectEqual(@as(u16, 0), m.whole);
    try std.testing.expectEqual(@as(u3, 1), m.partial_eighths);
}

test "Discretise.measure: NaN coerces to zero, no UB" {
    const nan = std.math.nan(f32);
    const m = Discretise(.left_fill).measure(10, nan);
    try std.testing.expectEqual(@as(u16, 0), m.whole);
    try std.testing.expectEqual(@as(u3, 0), m.partial_eighths);
}

test "Discretise.measure: negative fraction clamps to zero" {
    const m = Discretise(.lower_fill).measure(8, -0.5);
    try std.testing.expectEqual(@as(u16, 0), m.whole);
    try std.testing.expectEqual(@as(u3, 0), m.partial_eighths);
}

test "Discretise.measure: fraction > 1 clamps to full extent" {
    const m = Discretise(.lower_fill).measure(8, 99.0);
    try std.testing.expectEqual(@as(u16, 8), m.whole);
    try std.testing.expectEqual(@as(u3, 0), m.partial_eighths);
}

test "Discretise.measure: partial precision at 3/4 of a 4-cell extent" {
    // 4 × 0.75 × 8 = 24 eighths → 3 whole + 0 partial.
    const m = Discretise(.left_fill).measure(4, 0.75);
    try std.testing.expectEqual(@as(u16, 3), m.whole);
    try std.testing.expectEqual(@as(u3, 0), m.partial_eighths);
}

test "partialStyle: fg from filled, bg from empty, text from filled" {
    const C = enum { a, b };
    const filled: Style(C) = .{ .fg = .a, .bg = .a, .text = .{ .bold = true } };
    const empty:  Style(C) = .{ .fg = .b, .bg = .b, .text = .{} };
    const p = partialStyle(C, filled, empty);
    try std.testing.expectEqual(@as(?C, .a), p.fg);
    try std.testing.expectEqual(@as(?C, .b), p.bg);
    try std.testing.expect(p.text.bold);
}
