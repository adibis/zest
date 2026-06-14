//! Anchor — where content sits inside an already-sized window.
//!
//! Apps reach for Anchor whenever they draw something smaller than its
//! window and need to decide where in the window it goes: a centered
//! title, a right-aligned timestamp, a bottom-anchored status hint, a
//! progress bar centered both ways. Anchor is purely a draw-time hint;
//! it never participates in the layout solver.
//!
//! Widget integration: each widget's `draw` function takes an `opts`
//! struct as its last parameter. Stateless widgets put `anchor` on
//! their opts default; stateful widgets carry it as an instance field.
//! Either way, the API surface for the caller is the same: pass an
//! Anchor value and the widget uses it.
//!
//! Overflow rule: when content is at least as wide (or tall) as the
//! window, alignment degrades to `.left` / `.top`. The library does
//! not center beyond the window, does not panic, does not emit
//! diagnostics. Apps that need a different overflow behavior should
//! measure the content themselves and pick a different anchor.

const std = @import("std");

pub const Horizontal = enum { left, center, right };
pub const Vertical   = enum { top,  middle, bottom };

pub const Anchor = struct {
    horizontal: Horizontal = .left,
    vertical:   Vertical   = .top,
};

/// Resolve an Anchor against a window-size / content-size pair, returning
/// the (col_offset, row_offset) at which the content should be drawn.
/// Content larger than the window degrades the alignment to the matching
/// edge (left for horizontal, top for vertical) — the offset is 0.
pub fn resolve(
    anchor:    Anchor,
    win_width: u16,
    win_height: u16,
    content_width: u16,
    content_height: u16,
) struct { col: u16, row: u16 } {
    const col: u16 = if (content_width >= win_width) 0 else switch (anchor.horizontal) {
        .left   => 0,
        .center => (win_width - content_width) / 2,
        .right  =>  win_width - content_width,
    };
    const row: u16 = if (content_height >= win_height) 0 else switch (anchor.vertical) {
        .top    => 0,
        .middle => (win_height - content_height) / 2,
        .bottom =>  win_height - content_height,
    };
    return .{ .col = col, .row = row };
}

test "Anchor: default is left/top" {
    const a: Anchor = .{};
    try std.testing.expectEqual(Horizontal.left, a.horizontal);
    try std.testing.expectEqual(Vertical.top,    a.vertical);
}

test "resolve: left/top places content at the origin" {
    const r = resolve(.{}, 80, 24, 10, 1);
    try std.testing.expectEqual(@as(u16, 0), r.col);
    try std.testing.expectEqual(@as(u16, 0), r.row);
}

test "resolve: center horizontal halves the remaining space" {
    const r = resolve(.{ .horizontal = .center }, 80, 24, 10, 1);
    try std.testing.expectEqual(@as(u16, 35), r.col); // (80 - 10) / 2
    try std.testing.expectEqual(@as(u16, 0),  r.row);
}

test "resolve: right anchors to the right edge" {
    const r = resolve(.{ .horizontal = .right }, 80, 24, 10, 1);
    try std.testing.expectEqual(@as(u16, 70), r.col); // 80 - 10
}

test "resolve: middle vertical halves the remaining height" {
    const r = resolve(.{ .vertical = .middle }, 80, 24, 80, 4);
    try std.testing.expectEqual(@as(u16, 0),  r.col);
    try std.testing.expectEqual(@as(u16, 10), r.row); // (24 - 4) / 2
}

test "resolve: bottom anchors to the bottom edge" {
    const r = resolve(.{ .vertical = .bottom }, 80, 24, 80, 4);
    try std.testing.expectEqual(@as(u16, 20), r.row); // 24 - 4
}

test "resolve: content wider than window degrades to left" {
    const r = resolve(.{ .horizontal = .center }, 10, 1, 20, 1);
    try std.testing.expectEqual(@as(u16, 0), r.col);
}

test "resolve: content taller than window degrades to top" {
    const r = resolve(.{ .vertical = .middle }, 80, 3, 80, 10);
    try std.testing.expectEqual(@as(u16, 0), r.row);
}

test "resolve: equal-size content degrades to origin" {
    const r = resolve(.{ .horizontal = .center, .vertical = .middle }, 10, 5, 10, 5);
    try std.testing.expectEqual(@as(u16, 0), r.col);
    try std.testing.expectEqual(@as(u16, 0), r.row);
}

test "resolve: composite center+middle" {
    const r = resolve(.{ .horizontal = .center, .vertical = .middle }, 80, 24, 10, 4);
    try std.testing.expectEqual(@as(u16, 35), r.col);
    try std.testing.expectEqual(@as(u16, 10), r.row);
}

test "resolve: zero-width window with non-empty content stays at origin" {
    const r = resolve(.{ .horizontal = .center }, 0, 24, 5, 1);
    try std.testing.expectEqual(@as(u16, 0), r.col);
}

test "resolve: empty content with center+middle is at the window's midpoint" {
    // Empty content has zero size, so it "fits" — alignment math runs.
    // Center horizontal of 80 → col 40; middle vertical of 24 → row 12.
    const r = resolve(
        .{ .horizontal = .center, .vertical = .middle },
        80, 24, 0, 0,
    );
    try std.testing.expectEqual(@as(u16, 40), r.col);
    try std.testing.expectEqual(@as(u16, 12), r.row);
}

test "resolve: empty content with default anchor stays at origin" {
    const r = resolve(.{}, 80, 24, 0, 0);
    try std.testing.expectEqual(@as(u16, 0), r.col);
    try std.testing.expectEqual(@as(u16, 0), r.row);
}
