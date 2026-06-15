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

    /// Resolve the anchor against a window-size / content-size pair,
    /// returning the (col, row) offset at which the content should be
    /// drawn. Content larger than the window degrades the alignment to
    /// the matching edge (left for horizontal, top for vertical) — the
    /// offset is 0. App code that draws composite layouts (multiple
    /// elements at coordinated positions) calls this directly to
    /// compute the placement.
    pub fn resolve(
        self:           Anchor,
        win_width:      u16,
        win_height:     u16,
        content_width:  u16,
        content_height: u16,
    ) struct { col: u16, row: u16 } {
        const col: u16 = if (content_width >= win_width) 0 else switch (self.horizontal) {
            .left   => 0,
            .center => (win_width - content_width) / 2,
            .right  =>  win_width - content_width,
        };
        const row: u16 = if (content_height >= win_height) 0 else switch (self.vertical) {
            .top    => 0,
            .middle => (win_height - content_height) / 2,
            .bottom =>  win_height - content_height,
        };
        return .{ .col = col, .row = row };
    }
};

test "Anchor: default is left/top" {
    const a: Anchor = .{};
    try std.testing.expectEqual(Horizontal.left, a.horizontal);
    try std.testing.expectEqual(Vertical.top,    a.vertical);
}

test "Anchor.resolve: left/top places content at the origin" {
    const a: Anchor = .{};
    const r = a.resolve(80, 24, 10, 1);
    try std.testing.expectEqual(@as(u16, 0), r.col);
    try std.testing.expectEqual(@as(u16, 0), r.row);
}

test "Anchor.resolve: center horizontal halves the remaining space" {
    const a: Anchor = .{ .horizontal = .center };
    const r = a.resolve(80, 24, 10, 1);
    try std.testing.expectEqual(@as(u16, 35), r.col); // (80 - 10) / 2
    try std.testing.expectEqual(@as(u16, 0),  r.row);
}

test "Anchor.resolve: right anchors to the right edge" {
    const a: Anchor = .{ .horizontal = .right };
    const r = a.resolve(80, 24, 10, 1);
    try std.testing.expectEqual(@as(u16, 70), r.col); // 80 - 10
}

test "Anchor.resolve: middle vertical halves the remaining height" {
    const a: Anchor = .{ .vertical = .middle };
    const r = a.resolve(80, 24, 80, 4);
    try std.testing.expectEqual(@as(u16, 0),  r.col);
    try std.testing.expectEqual(@as(u16, 10), r.row); // (24 - 4) / 2
}

test "Anchor.resolve: bottom anchors to the bottom edge" {
    const a: Anchor = .{ .vertical = .bottom };
    const r = a.resolve(80, 24, 80, 4);
    try std.testing.expectEqual(@as(u16, 20), r.row); // 24 - 4
}

test "Anchor.resolve: content wider than window degrades to left" {
    const a: Anchor = .{ .horizontal = .center };
    const r = a.resolve(10, 1, 20, 1);
    try std.testing.expectEqual(@as(u16, 0), r.col);
}

test "Anchor.resolve: content taller than window degrades to top" {
    const a: Anchor = .{ .vertical = .middle };
    const r = a.resolve(80, 3, 80, 10);
    try std.testing.expectEqual(@as(u16, 0), r.row);
}

test "Anchor.resolve: equal-size content degrades to origin" {
    const a: Anchor = .{ .horizontal = .center, .vertical = .middle };
    const r = a.resolve(10, 5, 10, 5);
    try std.testing.expectEqual(@as(u16, 0), r.col);
    try std.testing.expectEqual(@as(u16, 0), r.row);
}

test "Anchor.resolve: composite center+middle" {
    const a: Anchor = .{ .horizontal = .center, .vertical = .middle };
    const r = a.resolve(80, 24, 10, 4);
    try std.testing.expectEqual(@as(u16, 35), r.col);
    try std.testing.expectEqual(@as(u16, 10), r.row);
}

test "Anchor.resolve: zero-width window with non-empty content stays at origin" {
    const a: Anchor = .{ .horizontal = .center };
    const r = a.resolve(0, 24, 5, 1);
    try std.testing.expectEqual(@as(u16, 0), r.col);
}

test "Anchor.resolve: empty content with center+middle is at the window's midpoint" {
    // Empty content has zero size, so it "fits" — alignment math runs.
    // Center horizontal of 80 → col 40; middle vertical of 24 → row 12.
    const a: Anchor = .{ .horizontal = .center, .vertical = .middle };
    const r = a.resolve(80, 24, 0, 0);
    try std.testing.expectEqual(@as(u16, 40), r.col);
    try std.testing.expectEqual(@as(u16, 12), r.row);
}

test "Anchor.resolve: empty content with default anchor stays at origin" {
    const a: Anchor = .{};
    const r = a.resolve(80, 24, 0, 0);
    try std.testing.expectEqual(@as(u16, 0), r.col);
    try std.testing.expectEqual(@as(u16, 0), r.row);
}
