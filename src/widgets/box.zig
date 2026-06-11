//! Layout compositor — bridges the comptime blueprint and the runtime render loop.
//!
//! Call Layout.panels() on each resize or focus event to get a named struct of
//! Panels, one field per pane in the blueprint. Access panels by name
//! (e.g. result.sidebar) — the struct type is derived from the blueprint at
//! compile time. All geometry is stack-allocated; no arena or allocator needed.
//!
//! The pipeline in one line:
//!   hsplit/vsplit  →  pure geometry, no output
//!   pane           →  becomes Panel{ win, focused } via Layout.panels()
//!
//! If a pane declares `border = true`, vaxis draws the border and returns the
//! inner content window. The caller never needs to account for border cells.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("../layout/rect.zig").Rect;
const solveInto = @import("../layout/solver.zig").solveInto;
const leafCount = @import("../layout/solver.zig").leafCount;
const FocusStack = @import("../core/focus.zig").FocusStack;

/// A resolved layout region with its associated render state for a single frame.
/// Each named field in the struct returned by Layout.panels() is a Panel.
pub const Panel = struct {
    win:     vaxis.Window,
    focused: bool,
};

/// Per-frame render context passed to Layout.panels(). Fields are additive —
/// adding theme or other state here does not change existing call sites.
pub const RenderContext = struct {
    focus: ?*const FocusStack = null,
};

/// Walks the blueprint tree and returns a comptime array of border flags,
/// one per leaf pane, in the same depth-first left-to-right order as solve().
fn leafBorders(comptime Blueprint: type) [leafCount(Blueprint)]bool {
    if (@hasDecl(Blueprint, "is_pane")) {
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

/// Walks the blueprint tree and returns a comptime array of pane ids,
/// one per leaf pane, in the same depth-first left-to-right order as solve().
fn leafIds(comptime Blueprint: type) [leafCount(Blueprint)][:0]const u8 {
    if (@hasDecl(Blueprint, "is_pane")) {
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

/// Produces a struct type with one Panel field per leaf pane, named by each
/// pane's id. This is the return type of Layout.panels() — Zig infers it at
/// the call site so callers rarely need to name it explicitly.
pub fn PanelsType(comptime Blueprint: type) type {
    const ids = comptime leafIds(Blueprint);
    const N = ids.len;
    var names: [N][]const u8 = undefined;
    var types: [N]type = undefined;
    var attrs: [N]std.builtin.Type.StructField.Attributes = undefined;
    inline for (ids, 0..) |id, i| {
        names[i] = id;
        types[i] = Panel;
        attrs[i] = .{};
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub const Layout = struct {
    /// Returns the number of leaf panes in Blueprint — useful for Focus.init().
    pub fn panelCount(comptime Blueprint: type) usize {
        return leafCount(Blueprint);
    }

    /// Returns a comptime array of leaf pane IDs in depth-first order.
    /// Useful for deriving the ids list passed to Focus.is() without restating
    /// pane names that are already in the blueprint.
    pub fn panelIds(comptime Blueprint: type) [leafCount(Blueprint)][:0]const u8 {
        return leafIds(Blueprint);
    }

    /// Solves Blueprint's layout within bounds and returns a named struct of
    /// Panels, one per leaf pane. Each Panel carries the resolved vaxis.Window
    /// and a focused bool stamped from ctx.focus (false when focus is null).
    /// If a pane declares `border = true`, the border is drawn immediately and
    /// the Panel's window is the inner content area. All geometry is
    /// stack-allocated — no allocator needed.
    pub fn panels(
        comptime Blueprint: type,
        root_win: vaxis.Window,
        bounds: Rect,
        ctx: RenderContext,
    ) PanelsType(Blueprint) {
        var rects: [leafCount(Blueprint)]Rect = undefined;
        solveInto(Blueprint, bounds, &rects);
        const borders = comptime leafBorders(Blueprint);
        const ids = comptime leafIds(Blueprint);
        const active: ?usize = if (ctx.focus) |f| f.activeIndex() else null;
        var result: PanelsType(Blueprint) = undefined;
        inline for (ids, 0..) |id, i| {
            const r = rects[i];
            @field(result, id) = Panel{
                .win = root_win.child(.{
                    .x_off = @intCast(r.x),
                    .y_off = @intCast(r.y),
                    .width  = r.width,
                    .height = r.height,
                    .border = if (borders[i]) .{ .where = .all } else .{},
                }),
                .focused = if (active) |a| a == i else false,
            };
        }
        return result;
    }
};

test "Layout.panels: returns one panel per leaf pane, no borders" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").hsplit;
    const vs = @import("../layout/blueprint.zig").vsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .id = "a", .size = .{ .fixed = 20 } }),
            vs(.{
                .size = .{ .fraction = 1 },
                .children = &.{
                    p(.{ .id = "b", .size = .{ .fixed = 5 } }),
                    p(.{ .id = "c", .size = .{ .fraction = 1 } }),
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

    const result = Layout.panels(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 }, .{});

    try std.testing.expectEqual(@as(u16, 20), result.a.win.width);
    try std.testing.expectEqual(@as(u16, 40), result.a.win.height);
    try std.testing.expectEqual(@as(u16, 60), result.b.win.width);
    try std.testing.expectEqual(@as(u16, 5),  result.b.win.height);
    try std.testing.expectEqual(@as(u16, 60), result.c.win.width);
    try std.testing.expectEqual(@as(u16, 35), result.c.win.height);
}

test "Layout.panels: bordered pane is inset by one cell per edge" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").hsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .id = "left",  .size = .{ .fixed = 20 }, .border = true }),
            p(.{ .id = "right", .size = .{ .fraction = 1 } }),
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

    const result = Layout.panels(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 }, .{});

    // bordered pane: 20 wide → inner 18 (−1 left, −1 right); 40 tall → inner 38
    try std.testing.expectEqual(@as(u16, 18), result.left.win.width);
    try std.testing.expectEqual(@as(u16, 38), result.left.win.height);
    // no-border pane: full size
    try std.testing.expectEqual(@as(u16, 60), result.right.win.width);
    try std.testing.expectEqual(@as(u16, 40), result.right.win.height);
}

test "PanelsType: flat blueprint produces struct with correct field names" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").hsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .id = "sidebar", .size = .{ .fixed = 20 } }),
            p(.{ .id = "body",    .size = .{ .fraction = 1 } }),
        },
    });
    const W = PanelsType(B);
    try std.testing.expect(@hasField(W, "sidebar"));
    try std.testing.expect(@hasField(W, "body"));
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(W).@"struct".fields.len);
}

test "PanelsType: nested blueprint produces one field per leaf pane" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").hsplit;
    const vs = @import("../layout/blueprint.zig").vsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .id = "sidebar", .size = .{ .fixed = 20 } }),
            vs(.{
                .size = .{ .fraction = 1 },
                .children = &.{
                    p(.{ .id = "header", .size = .{ .fixed = 3 } }),
                    p(.{ .id = "body",   .size = .{ .fraction = 1 } }),
                },
            }),
        },
    });
    const W = PanelsType(B);
    try std.testing.expect(@hasField(W, "sidebar"));
    try std.testing.expect(@hasField(W, "header"));
    try std.testing.expect(@hasField(W, "body"));
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(W).@"struct".fields.len);
}
