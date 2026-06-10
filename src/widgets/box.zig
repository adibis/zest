//! Box widget — maps a comptime layout blueprint onto a slice of vaxis windows.
//!
//! Box is the bridge between the solver and the rest of your application.
//! Call Box.windows() on each resize event to get a fresh slice of sub-windows,
//! one per leaf slot in depth-first left-to-right order, then index into the
//! result to draw each panel. Allocate from the frame arena so the slice is
//! bulk-freed at the start of the next event with zero per-window overhead.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("../layout/rect.zig").Rect;
const solve = @import("../layout/solver.zig").solve;

pub const Box = struct {
    /// Solves Blueprint's layout within bounds, then wraps each leaf Rect in a
    /// vaxis.Window child of root_win. Returns one window per leaf slot, in
    /// depth-first left-to-right order. Uses the frame arena so the slice
    /// requires no individual frees.
    pub fn windows(
        comptime Blueprint: type,
        root_win: vaxis.Window,
        bounds: Rect,
        arena: std.mem.Allocator,
    ) ![]vaxis.Window {
        const rects = try solve(arena, Blueprint, bounds);
        const wins = try arena.alloc(vaxis.Window, rects.len);
        for (rects, 0..) |r, i| {
            wins[i] = root_win.child(.{
                .x_off = @intCast(r.x),
                .y_off = @intCast(r.y),
                .width = r.width,
                .height = r.height,
            });
        }
        return wins;
    }
};

test "Box.windows: returns one window per leaf slot" {
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
        .x_off = 0, .y_off = 0,
        .parent_x_off = 0, .parent_y_off = 0,
        .width = screen.width, .height = screen.height,
        .screen = &screen,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 0, .y = 0, .width = 80, .height = 40 };
    const wins = try Box.windows(B, root_win, bounds, arena.allocator());

    try std.testing.expectEqual(@as(usize, 3), wins.len);
    // sidebar: x=0, width=20, full height
    try std.testing.expectEqual(@as(u16, 20), wins[0].width);
    try std.testing.expectEqual(@as(u16, 40), wins[0].height);
    // header: width=60, height=5
    try std.testing.expectEqual(@as(u16, 60), wins[1].width);
    try std.testing.expectEqual(@as(u16, 5),  wins[1].height);
    // body: width=60, height=35
    try std.testing.expectEqual(@as(u16, 60), wins[2].width);
    try std.testing.expectEqual(@as(u16, 35), wins[2].height);
}
