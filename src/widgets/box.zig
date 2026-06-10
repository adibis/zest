//! Box widget — maps a comptime layout blueprint onto a slice of vaxis windows.
//!
//! Box is the bridge between the solver and the rest of your application.
//! Call Box.windows() on each resize event to get a fresh slice of sub-windows,
//! one per leaf slot in depth-first left-to-right order, then index into the
//! result to draw each panel. Allocate from the frame arena so the slice is
//! bulk-freed at the start of the next event with zero per-window overhead.
//!
//! If a slot declares `border = true`, vaxis draws the border and returns the
//! inner content window. The caller never needs to account for border cells.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("../layout/rect.zig").Rect;
const solve = @import("../layout/solver.zig").solve;
const leafCount = @import("../layout/solver.zig").leafCount;

/// Walks the blueprint tree and returns a comptime array of border flags,
/// one per leaf slot, in the same depth-first left-to-right order as solve().
fn leafBorders(comptime Blueprint: type) [leafCount(Blueprint)]bool {
    if (@hasDecl(Blueprint, "is_slot")) {
        return .{Blueprint.border};
    }
    var result: [leafCount(Blueprint)]bool = undefined;
    var offset: usize = 0;
    inline for (Blueprint.children) |Child| {
        const count = comptime leafCount(Child);
        const sub = comptime leafBorders(Child);
        for (0..count) |j| {
            result[offset + j] = sub[j];
        }
        offset += count;
    }
    return result;
}

pub const Box = struct {
    /// Solves Blueprint's layout within bounds, then wraps each leaf Rect in a
    /// vaxis.Window child of root_win. Returns one window per leaf slot, in
    /// depth-first left-to-right order. If the slot declares `border = true`,
    /// the border is drawn immediately and the returned window is the inner
    /// content area. Uses the frame arena so the slice requires no individual frees.
    pub fn windows(
        comptime Blueprint: type,
        root_win: vaxis.Window,
        bounds: Rect,
        arena: std.mem.Allocator,
    ) ![]vaxis.Window {
        const rects = try solve(arena, Blueprint, bounds);
        const borders = comptime leafBorders(Blueprint);
        const wins = try arena.alloc(vaxis.Window, rects.len);
        for (rects, 0..) |r, i| {
            wins[i] = root_win.child(.{
                .x_off = @intCast(r.x),
                .y_off = @intCast(r.y),
                .width  = r.width,
                .height = r.height,
                .border = if (borders[i]) .{ .where = .all } else .{},
            });
        }
        return wins;
    }
};

test "Box.windows: returns one window per leaf slot, no borders" {
    const slot = @import("../layout/blueprint.zig").slot;
    const box = @import("../layout/blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .size = .{ .fixed = 20 } }),
            box(.{
                .size = .{ .fraction = 1 },
                .direction = .vertical,
                .children = &.{
                    slot(.{ .size = .{ .fixed = 5 } }),
                    slot(.{ .size = .{ .fraction = 1 } }),
                },
            }),
        },
    });

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 40, .cols = 80, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const root_win = vaxis.Window{
        .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0,
        .width = screen.width, .height = screen.height, .screen = &screen,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const wins = try Box.windows(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 }, arena.allocator());

    try std.testing.expectEqual(@as(usize, 3), wins.len);
    try std.testing.expectEqual(@as(u16, 20), wins[0].width);
    try std.testing.expectEqual(@as(u16, 40), wins[0].height);
    try std.testing.expectEqual(@as(u16, 60), wins[1].width);
    try std.testing.expectEqual(@as(u16, 5),  wins[1].height);
    try std.testing.expectEqual(@as(u16, 60), wins[2].width);
    try std.testing.expectEqual(@as(u16, 35), wins[2].height);
}

test "Box.windows: bordered slot is inset by one cell per edge" {
    const slot = @import("../layout/blueprint.zig").slot;
    const box = @import("../layout/blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .size = .{ .fixed = 20 }, .border = true }),
            slot(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 40, .cols = 80, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const root_win = vaxis.Window{
        .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0,
        .width = screen.width, .height = screen.height, .screen = &screen,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const wins = try Box.windows(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 }, arena.allocator());

    // bordered slot: 20 wide → inner 18 (−1 left, −1 right); 40 tall → inner 38
    try std.testing.expectEqual(@as(u16, 18), wins[0].width);
    try std.testing.expectEqual(@as(u16, 38), wins[0].height);
    // no-border slot: full size
    try std.testing.expectEqual(@as(u16, 60), wins[1].width);
    try std.testing.expectEqual(@as(u16, 40), wins[1].height);
}
