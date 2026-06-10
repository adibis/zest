//! Slot and direction types for the layout blueprint.
//!
//! A PanelSlot is a leaf node in the layout tree — it represents one
//! panel on screen with a declared size. Direction is used by Box nodes
//! to specify whether their children are arranged left-to-right or top-to-bottom.
//!
//! These two types live in the same file because neither is useful without
//! the other: slots exist inside boxes, boxes always have a direction.

const std = @import("std");
const Size = @import("size.zig").Size;

/// Which axis children are stacked along inside a Box.
pub const Direction = enum {
    horizontal, // children placed left to right, each consuming width
    vertical,   // children placed top to bottom, each consuming height
};

/// A leaf node in the layout tree. Declares how much space this panel
/// wants; the solver turns that declaration into a concrete Rect.
pub const PanelSlot = struct {
    size: Size,
};

test "PanelSlot: fixed size" {
    const slot = PanelSlot{ .size = .{ .fixed = 30 } };
    try std.testing.expectEqual(@as(u16, 30), slot.size.fixed);
}

test "PanelSlot: fraction size" {
    const slot = PanelSlot{ .size = .{ .fraction = 1 } };
    try std.testing.expectEqual(@as(u16, 1), slot.size.fraction);
}

test "PanelSlot: percent size" {
    const slot = PanelSlot{ .size = .{ .percent = 50 } };
    try std.testing.expectEqual(@as(u8, 50), slot.size.percent);
}

test "Direction: horizontal and vertical are distinct" {
    try std.testing.expect(Direction.horizontal != Direction.vertical);
}

test "Direction: exhaustive switch compiles" {
    // Verifies the enum has exactly these two values — if a third were added
    // without an else branch, this test would fail to compile, catching the gap.
    const d = Direction.horizontal;
    const result: u8 = switch (d) {
        .horizontal => 0,
        .vertical   => 1,
    };
    try std.testing.expectEqual(@as(u8, 0), result);
}
