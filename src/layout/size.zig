//! Size describes how much space a panel slot claims along the layout axis.
//!
//! The solver processes children in two passes:
//!   1. Fixed and percent sizes are resolved first (they consume a known amount).
//!   2. Remaining space is divided among fraction slots by weight.
//!
//! This mirrors how CSS flex/grid and most TUI layout engines work.

const std = @import("std");

pub const Size = union(enum) {
    /// Exact number of terminal cells. Resolved before fraction slots.
    fixed: u16,

    /// Proportion of whatever space remains after fixed and percent slots are placed.
    /// Two fraction(1) children split evenly; fraction(2) + fraction(1)
    /// gives a 2:1 split. Think of it as a relative weight, not a percentage.
    fraction: u16,

    /// Percentage of the parent dimension, resolved before fraction slots.
    /// Valid range is 0–100.
    percent: u8,
};

test "Size: fixed holds its value" {
    const s = Size{ .fixed = 30 };
    try std.testing.expectEqual(30, s.fixed);
}

test "Size: fraction holds its weight" {
    const s = Size{ .fraction = 2 };
    try std.testing.expectEqual(2, s.fraction);
}

test "Size: percent holds its value" {
    const s = Size{ .percent = 25 };
    try std.testing.expectEqual(25, s.percent);
}

test "Size: each variant is distinct" {
    const a = Size{ .fixed = 10 };
    const b = Size{ .fraction = 10 };
    // Same payload, different tags — they must not be equal.
    try std.testing.expect(std.meta.activeTag(a) != std.meta.activeTag(b));
}
