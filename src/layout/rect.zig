//! Fundamental geometry types used throughout the layout solver and widget system.
//! A Rect represents a rectangular region in terminal cell coordinates (col, row).

const std = @import("std");

pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,

    /// Returns a sub-rectangle within this rect. The child's position is expressed
    /// as an offset from this rect's origin and converted to an absolute screen position.
    ///
    /// Asserts in Debug/ReleaseSafe that the child fits within the parent. In
    /// ReleaseFast/ReleaseSmall the assert is compiled away — zero runtime cost.
    /// Use float() when intentional overflow is needed (modals, tooltips).
    pub fn child(self: Rect, x_off: u16, y_off: u16, w: u16, h: u16) Rect {
        // Upcast to u32 before adding: both operands are u16, so their sum could
        // overflow u16 before the <= comparison runs. u32 covers the full range.
        std.debug.assert(@as(u32, x_off) + w <= self.width);
        std.debug.assert(@as(u32, y_off) + h <= self.height);
        return .{
            // +| is saturating addition: clamps to 65535 instead of wrapping.
            // In practice terminals never approach this limit, but it makes the
            // arithmetic unconditionally correct regardless of input.
            .x = self.x +| x_off,
            .y = self.y +| y_off,
            .width = w,
            .height = h,
        };
    }

    /// Same as child() but without bounds checking. Intended for UI elements that
    /// intentionally extend beyond their logical parent — floating dialogs, dropdown
    /// menus, tooltips. The name signals to the reader that overflow is on purpose.
    /// vaxis clips all writes at the physical screen edge, so this never corrupts output.
    pub fn float(self: Rect, x_off: u16, y_off: u16, w: u16, h: u16) Rect {
        return .{
            .x = self.x +| x_off,
            .y = self.y +| y_off,
            .width = w,
            .height = h,
        };
    }
};

test "Rect: zero value is valid" {
    const r: Rect = .{};
    try std.testing.expectEqual(0, r.x);
    try std.testing.expectEqual(0, r.width);
}

test "Rect: construction" {
    const r: Rect = .{ .x = 10, .y = 5, .width = 80, .height = 24 };
    try std.testing.expectEqual(10, r.x);
    try std.testing.expectEqual(5, r.y);
    try std.testing.expectEqual(80, r.width);
    try std.testing.expectEqual(24, r.height);
}

test "Rect: child offsets from parent origin" {
    const parent: Rect = .{ .x = 10, .y = 5, .width = 80, .height = 24 };
    const c = parent.child(2, 3, 40, 10);
    try std.testing.expectEqual(12, c.x);   // 10 + 2
    try std.testing.expectEqual(8, c.y);    // 5 + 3
    try std.testing.expectEqual(40, c.width);
    try std.testing.expectEqual(10, c.height);
}

test "Rect: child at zero offset preserves parent origin" {
    const parent: Rect = .{ .x = 5, .y = 3, .width = 100, .height = 50 };
    const c = parent.child(0, 0, 100, 50);
    try std.testing.expectEqual(parent.x, c.x);
    try std.testing.expectEqual(parent.y, c.y);
}

test "Rect: float may exceed parent bounds" {
    const parent: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const dialog = parent.float(50, 50, 60, 60); // ends at 110x110 — intentional
    try std.testing.expectEqual(50, dialog.x);
    try std.testing.expectEqual(50, dialog.y);
    try std.testing.expectEqual(60, dialog.width);
    try std.testing.expectEqual(60, dialog.height);
}

test "Rect: float anchors to parent origin" {
    const parent: Rect = .{ .x = 10, .y = 5, .width = 100, .height = 100 };
    const tooltip = parent.float(20, 3, 40, 5);
    try std.testing.expectEqual(30, tooltip.x); // 10 + 20
    try std.testing.expectEqual(8, tooltip.y);  // 5 + 3
}
