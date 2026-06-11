//! Box widget — maps a comptime layout blueprint onto a named struct of vaxis windows.
//!
//! Box is the bridge between the solver and the rest of your application.
//! Call Box.windows() on each resize event to get a named struct of sub-windows,
//! one field per leaf slot. Access panels by name (e.g. wins.sidebar) — the
//! struct type is derived from the blueprint at compile time. All geometry is
//! stack-allocated; no arena or allocator needed.
//!
//! If a slot declares `border = true`, vaxis draws the border and returns the
//! inner content window. The caller never needs to account for border cells.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("../layout/rect.zig").Rect;
const solveInto = @import("../layout/solver.zig").solveInto;
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

/// Walks the blueprint tree and returns a comptime array of slot ids,
/// one per leaf slot, in the same depth-first left-to-right order as solve().
fn leafIds(comptime Blueprint: type) [leafCount(Blueprint)][:0]const u8 {
    if (@hasDecl(Blueprint, "is_slot")) {
        return .{Blueprint.id};
    }
    var result: [leafCount(Blueprint)][:0]const u8 = undefined;
    var offset: usize = 0;
    inline for (Blueprint.children) |Child| {
        const count = comptime leafCount(Child);
        const sub = comptime leafIds(Child);
        for (0..count) |j| {
            result[offset + j] = sub[j];
        }
        offset += count;
    }
    return result;
}

/// Produces a struct type with one vaxis.Window field per leaf slot, named by
/// each slot's id. This is the return type of Box.windows() — Zig infers it
/// at the call site so callers rarely need to name it explicitly.
pub fn WindowsType(comptime Blueprint: type) type {
    const ids = comptime leafIds(Blueprint);
    const N = ids.len;
    var names: [N][]const u8 = undefined;
    var types: [N]type = undefined;
    var attrs: [N]std.builtin.Type.StructField.Attributes = undefined;
    inline for (ids, 0..) |id, i| {
        names[i] = id;
        types[i] = vaxis.Window;
        attrs[i] = .{};
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub const Box = struct {
    /// Solves Blueprint's layout within bounds, then wraps each leaf Rect in a
    /// vaxis.Window child of root_win. Returns a struct with one field per leaf
    /// slot named by each slot's id. If a slot declares `border = true`, the
    /// border is drawn immediately and the returned window is the inner content
    /// area. All geometry is stack-allocated — no allocator needed.
    pub fn windows(
        comptime Blueprint: type,
        root_win: vaxis.Window,
        bounds: Rect,
    ) WindowsType(Blueprint) {
        var rects: [leafCount(Blueprint)]Rect = undefined;
        solveInto(Blueprint, bounds, &rects);
        const borders = comptime leafBorders(Blueprint);
        const ids = comptime leafIds(Blueprint);
        var result: WindowsType(Blueprint) = undefined;
        inline for (ids, 0..) |id, i| {
            const r = rects[i];
            @field(result, id) = root_win.child(.{
                .x_off = @intCast(r.x),
                .y_off = @intCast(r.y),
                .width  = r.width,
                .height = r.height,
                .border = if (borders[i]) .{ .where = .all } else .{},
            });
        }
        return result;
    }
};

test "Box.windows: returns one window per leaf slot, no borders" {
    const slot = @import("../layout/blueprint.zig").slot;
    const box = @import("../layout/blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .id = "a", .size = .{ .fixed = 20 } }),
            box(.{
                .size = .{ .fraction = 1 },
                .direction = .vertical,
                .children = &.{
                    slot(.{ .id = "b", .size = .{ .fixed = 5 } }),
                    slot(.{ .id = "c", .size = .{ .fraction = 1 } }),
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

    const wins = Box.windows(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 });

    try std.testing.expectEqual(@as(u16, 20), wins.a.width);
    try std.testing.expectEqual(@as(u16, 40), wins.a.height);
    try std.testing.expectEqual(@as(u16, 60), wins.b.width);
    try std.testing.expectEqual(@as(u16, 5),  wins.b.height);
    try std.testing.expectEqual(@as(u16, 60), wins.c.width);
    try std.testing.expectEqual(@as(u16, 35), wins.c.height);
}

test "Box.windows: bordered slot is inset by one cell per edge" {
    const slot = @import("../layout/blueprint.zig").slot;
    const box = @import("../layout/blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .id = "left",  .size = .{ .fixed = 20 }, .border = true }),
            slot(.{ .id = "right", .size = .{ .fraction = 1 } }),
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

    const wins = Box.windows(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 });

    // bordered slot: 20 wide → inner 18 (−1 left, −1 right); 40 tall → inner 38
    try std.testing.expectEqual(@as(u16, 18), wins.left.width);
    try std.testing.expectEqual(@as(u16, 38), wins.left.height);
    // no-border slot: full size
    try std.testing.expectEqual(@as(u16, 60), wins.right.width);
    try std.testing.expectEqual(@as(u16, 40), wins.right.height);
}

test "WindowsType: flat blueprint produces struct with correct field names" {
    const slot = @import("../layout/blueprint.zig").slot;
    const box = @import("../layout/blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .id = "sidebar", .size = .{ .fixed = 20 } }),
            slot(.{ .id = "body",    .size = .{ .fraction = 1 } }),
        },
    });
    const W = WindowsType(B);
    try std.testing.expect(@hasField(W, "sidebar"));
    try std.testing.expect(@hasField(W, "body"));
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(W).@"struct".fields.len);
}

test "WindowsType: nested blueprint produces one field per leaf slot" {
    const slot = @import("../layout/blueprint.zig").slot;
    const box = @import("../layout/blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .id = "sidebar", .size = .{ .fixed = 20 } }),
            box(.{
                .size = .{ .fraction = 1 },
                .direction = .vertical,
                .children = &.{
                    slot(.{ .id = "header", .size = .{ .fixed = 3 } }),
                    slot(.{ .id = "body",   .size = .{ .fraction = 1 } }),
                },
            }),
        },
    });
    const W = WindowsType(B);
    try std.testing.expect(@hasField(W, "sidebar"));
    try std.testing.expect(@hasField(W, "header"));
    try std.testing.expect(@hasField(W, "body"));
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(W).@"struct".fields.len);
}
