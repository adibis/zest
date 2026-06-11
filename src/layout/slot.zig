//! Slot and direction types for the layout blueprint.
//!
//! Direction is used by hsplit, vsplit, and domain nodes to specify whether
//! their children are arranged left-to-right or top-to-bottom.

const std = @import("std");

/// Which axis children are stacked along inside a split or domain node.
pub const Direction = enum {
    horizontal, // children placed left to right, each consuming width
    vertical,   // children placed top to bottom, each consuming height
};

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
    try std.testing.expectEqual(0, result);
}
