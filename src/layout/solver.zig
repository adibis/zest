//! Layout solver — turns a comptime blueprint into a flat slice of Rects.
//!
//! The solver bridges the comptime blueprint tree (built with pane(),
//! hsplit(), and vsplit()) and the runtime Rects that widgets use to claim
//! screen space. It runs once per resize event, allocating from the frame
//! arena so the result is bulk-freed at the start of the next frame with
//! zero per-Rect overhead.

const std = @import("std");
const Rect = @import("rect.zig").Rect;

/// Returns the number of focusable leaf panes in Blueprint's tree at comptime.
/// Non-focusable panes (focusable = false) are excluded. Use this to initialize
/// a FocusStack so Tab cycling never lands on display-only panes.
pub fn focusableLeafCount(comptime Blueprint: type) usize {
    if (@hasDecl(Blueprint, "is_pane")) {
        return if (Blueprint.focusable) 1 else 0;
    }
    if (@hasDecl(Blueprint, "is_split") or @hasDecl(Blueprint, "is_domain")) {
        var count: usize = 0;
        inline for (Blueprint.children) |Child| {
            count += comptime focusableLeafCount(Child);
        }
        return count;
    }
    @compileError("Blueprint must be produced by pane(), hsplit(), vsplit(), or domain()");
}

/// Returns the total number of leaf panes in Blueprint's tree at comptime.
/// The result is used to allocate exactly the right slice before recursing.
pub fn leafCount(comptime Blueprint: type) usize {
    if (@hasDecl(Blueprint, "is_pane")) return 1;
    if (@hasDecl(Blueprint, "is_split") or @hasDecl(Blueprint, "is_domain")) {
        var count: usize = 0;
        inline for (Blueprint.children) |Child| {
            count += comptime leafCount(Child);
        }
        return count;
    }
    @compileError("Blueprint must be produced by pane(), hsplit(), vsplit(), or domain()");
}

/// Resolves a comptime layout blueprint into a flat slice of Rects.
///
/// Each element corresponds to one leaf pane in the blueprint tree, in
/// depth-first left-to-right order. The caller owns the returned slice;
/// pass the frame arena so it is freed each frame without individual frees.
///
/// `Blueprint` must be a type produced by pane(), hsplit(), or vsplit().
/// Any other type is a compile-time error.
pub fn solve(
    allocator: std.mem.Allocator,
    comptime Blueprint: type,
    bounds: Rect,
) ![]Rect {
    if (!@hasDecl(Blueprint, "is_pane") and !@hasDecl(Blueprint, "is_split") and !@hasDecl(Blueprint, "is_domain"))
        @compileError("solve: Blueprint must be a type returned by pane(), hsplit(), vsplit(), or domain()");
    const rects = try allocator.alloc(Rect, leafCount(Blueprint));
    solveInto(Blueprint, bounds, rects);
    return rects;
}

/// Fills dst with Rects for every leaf pane under Blueprint, treating
/// bounds as the root of this subtree. dst must be exactly
/// leafCount(Blueprint) long. Prefer solve() when heap allocation is
/// acceptable; call this directly with a stack buffer when it is not.
pub fn solveInto(comptime Blueprint: type, bounds: Rect, dst: []Rect) void {
    if (@hasDecl(Blueprint, "is_pane")) {
        dst[0] = bounds;
        return;
    }
    // Compute immediate-child geometry into a stack-allocated array whose
    // length is comptime-known. These are transient bounds passed down during
    // recursion; only leaf Rects ever land in the output slice.
    var child_rects: [Blueprint.children.len]Rect = undefined;
    // is_horiz is comptime, so every branch that depends on it folds at
    // compile time — horizontal and vertical splits produce different machine
    // code with zero shared runtime overhead.
    const is_horiz = Blueprint.direction == .horizontal;
    const main_axis_size = if (is_horiz) bounds.width else bounds.height;
    var cursor: u16 = 0;
    inline for (Blueprint.children, 0..) |Child, i| {
        switch (Child.size) {
            .fixed => |w| {
                child_rects[i] = if (is_horiz) .{
                    .x = bounds.x +| cursor, .y = bounds.y,
                    .width = w,              .height = bounds.height,
                } else .{
                    .x = bounds.x,           .y = bounds.y +| cursor,
                    .width = bounds.width,   .height = w,
                };
                cursor +|= w;
            },
            .percent => |p| {
                const w: u16 = @intCast(@min(
                    @as(u32, main_axis_size) * p / 100,
                    std.math.maxInt(u16),
                ));
                child_rects[i] = if (is_horiz) .{
                    .x = bounds.x +| cursor, .y = bounds.y,
                    .width = w,              .height = bounds.height,
                } else .{
                    .x = bounds.x,           .y = bounds.y +| cursor,
                    .width = bounds.width,   .height = w,
                };
                cursor +|= w;
            },
            .fraction => {
                child_rects[i] = if (is_horiz) .{
                    .x = bounds.x +| cursor, .y = bounds.y,
                    .width = 0,              .height = bounds.height,
                } else .{
                    .x = bounds.x,           .y = bounds.y +| cursor,
                    .width = bounds.width,   .height = 0,
                };
            },
        }
    }
    // Fraction pass: distribute whatever main-axis space remains after fixed
    // children. cursor equals total fixed size because fractions did not
    // advance it.
    var fraction_weight_total: u32 = 0;
    inline for (Blueprint.children) |Child| {
        switch (Child.size) {
            .fraction => |weight| { fraction_weight_total += weight; },
            else => {},
        }
    }
    if (fraction_weight_total > 0) {
        const main_size = if (is_horiz) bounds.width else bounds.height;
        const remaining: u16 = main_size -| cursor;
        // Count fractional children at comptime so the last one absorbs the
        // integer-division remainder rather than leaving a gap at the edge.
        comptime var n_frac: usize = 0;
        inline for (Blueprint.children) |Child| {
            switch (Child.size) {
                .fraction => n_frac += 1,
                else => {},
            }
        }
        var frac_idx: usize = 0;
        var frac_used: u16 = 0;
        inline for (Blueprint.children, 0..) |Child, i| {
            switch (Child.size) {
                .fraction => |weight| {
                    const dim: u16 = if (frac_idx == n_frac - 1)
                        remaining -| frac_used
                    else blk: {
                        const d: u16 = @intCast(@min(
                            @as(u64, remaining) * weight / fraction_weight_total,
                            std.math.maxInt(u16),
                        ));
                        break :blk d;
                    };
                    frac_used += dim;
                    frac_idx += 1;
                    if (is_horiz) child_rects[i].width = dim else child_rects[i].height = dim;
                },
                else => {},
            }
        }
        // Recompute positions along the main axis now that all sizes are known.
        var pos: u16 = 0;
        for (&child_rects) |*r| {
            if (is_horiz) {
                r.x   = bounds.x +| pos;
                pos +|= r.width;
            } else {
                r.y   = bounds.y +| pos;
                pos +|= r.height;
            }
        }
    }
    // Recurse: each child gets a sub-slice of dst sized to its own leaf count.
    var offset: usize = 0;
    inline for (Blueprint.children, 0..) |Child, i| {
        const count = comptime leafCount(Child);
        solveInto(Child, child_rects[i], dst[offset .. offset + count]);
        offset += count;
    }
}

test "solve: single pane returns bounds unchanged" {
    const p = @import("blueprint.zig").pane;
    const S = p(.{ .size = .{ .fixed = 30 } });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 5, .y = 3, .width = 80, .height = 24 };
    const rects = try solve(arena.allocator(), S, bounds);

    try std.testing.expectEqual(1, rects.len);
    try std.testing.expectEqual(bounds, rects[0]);
}

test "solve: hsplit with one fixed pane — placed at left edge" {
    const p = @import("blueprint.zig").pane;
    const hs = @import("blueprint.zig").hsplit;
    const B = hs(.{
        .children = &.{p(.{ .size = .{ .fixed = 30 } })},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const rects = try solve(arena.allocator(), B, bounds);

    try std.testing.expectEqual(1, rects.len);
    try std.testing.expectEqual(0, rects[0].x);
    try std.testing.expectEqual(30, rects[0].width);
    try std.testing.expectEqual(24, rects[0].height);
}

test "solve: hsplit with two fixed panes — correct offsets, no overlap" {
    const p = @import("blueprint.zig").pane;
    const hs = @import("blueprint.zig").hsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .size = .{ .fixed = 20 } }),
            p(.{ .size = .{ .fixed = 30 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const rects = try solve(arena.allocator(), B, bounds);

    try std.testing.expectEqual(2, rects.len);
    try std.testing.expectEqual(0, rects[0].x);
    try std.testing.expectEqual(20, rects[0].width);
    try std.testing.expectEqual(20, rects[1].x);
    try std.testing.expectEqual(30, rects[1].width);
}

test "solve: hsplit fixed + fraction — fraction gets remaining width" {
    const p = @import("blueprint.zig").pane;
    const hs = @import("blueprint.zig").hsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .size = .{ .fixed = 30 } }),
            p(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const rects = try solve(arena.allocator(), B, bounds);

    try std.testing.expectEqual(2, rects.len);
    try std.testing.expectEqual(30, rects[0].width);
    try std.testing.expectEqual(30, rects[1].x);
    try std.testing.expectEqual(50, rects[1].width);
}

test "solve: hsplit fixed + fraction — fraction gets remaining width (variant)" {
    const p = @import("blueprint.zig").pane;
    const hs = @import("blueprint.zig").hsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .size = .{ .fixed = 20 } }),
            p(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 24 });

    try std.testing.expectEqual(20, rects[0].width);
    try std.testing.expectEqual(20, rects[1].x);
    try std.testing.expectEqual(60, rects[1].width);
}

test "solve: hsplit two equal fractions split remaining width evenly" {
    const p = @import("blueprint.zig").pane;
    const hs = @import("blueprint.zig").hsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .size = .{ .fraction = 1 } }),
            p(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 24 });

    try std.testing.expectEqual(0, rects[0].x);
    try std.testing.expectEqual(40, rects[0].width);
    try std.testing.expectEqual(40, rects[1].x);
    try std.testing.expectEqual(40, rects[1].width);
}

test "solve: hsplit weighted fractions split proportionally" {
    const p = @import("blueprint.zig").pane;
    const hs = @import("blueprint.zig").hsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .size = .{ .fraction = 1 } }),
            p(.{ .size = .{ .fraction = 2 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 90, .height = 24 });

    try std.testing.expectEqual(30, rects[0].width);
    try std.testing.expectEqual(30, rects[1].x);
    try std.testing.expectEqual(60, rects[1].width);
}

test "solve: vsplit with two fixed panes — correct y offsets, no overlap" {
    const p = @import("blueprint.zig").pane;
    const vs = @import("blueprint.zig").vsplit;
    const B = vs(.{
        .children = &.{
            p(.{ .size = .{ .fixed = 10 } }),
            p(.{ .size = .{ .fixed = 20 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 });

    try std.testing.expectEqual(0, rects[0].y);
    try std.testing.expectEqual(10, rects[0].height);
    try std.testing.expectEqual(10, rects[1].y);
    try std.testing.expectEqual(20, rects[1].height);
    try std.testing.expectEqual(80, rects[0].width);
}

test "solve: vsplit fixed + fraction gets remaining height" {
    const p = @import("blueprint.zig").pane;
    const vs = @import("blueprint.zig").vsplit;
    const B = vs(.{
        .children = &.{
            p(.{ .size = .{ .fixed = 3 } }),
            p(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 });

    try std.testing.expectEqual(3, rects[0].height);
    try std.testing.expectEqual(3, rects[1].y);
    try std.testing.expectEqual(37, rects[1].height);
    try std.testing.expectEqual(80, rects[1].width);
}

test "solve: vsplit two equal fractions split height evenly" {
    const p = @import("blueprint.zig").pane;
    const vs = @import("blueprint.zig").vsplit;
    const B = vs(.{
        .children = &.{
            p(.{ .size = .{ .fraction = 1 } }),
            p(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 });

    try std.testing.expectEqual(0, rects[0].y);
    try std.testing.expectEqual(20, rects[0].height);
    try std.testing.expectEqual(20, rects[1].y);
    try std.testing.expectEqual(20, rects[1].height);
}

test "solve: vsplit four equal fractions over indivisible height fills all space" {
    const p  = @import("blueprint.zig").pane;
    const vs = @import("blueprint.zig").vsplit;
    const B = vs(.{
        .children = &.{
            p(.{ .size = .{ .fraction = 1 } }),
            p(.{ .size = .{ .fraction = 1 } }),
            p(.{ .size = .{ .fraction = 1 } }),
            p(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 39 is not divisible by 4 — exercises the remainder-to-last-child path.
    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 39 });

    // All rows must be consumed: last pane ends exactly at y=39.
    const last = rects[3];
    try std.testing.expectEqual(39, last.y + last.height);
    // First three panes each get floor(39/4) = 9 rows.
    try std.testing.expectEqual(9, rects[0].height);
    try std.testing.expectEqual(9, rects[1].height);
    try std.testing.expectEqual(9, rects[2].height);
    // Last pane absorbs the remainder: 39 - 27 = 12.
    try std.testing.expectEqual(12, rects[3].height);
}

test "solve: percent pane consumes its share of parent dimension" {
    const p  = @import("blueprint.zig").pane;
    const hs = @import("blueprint.zig").hsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .size = .{ .percent = 25 } }),
            p(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 24 });

    // 25% of 80 = 20 cells; fraction gets the remaining 60.
    try std.testing.expectEqual(20, rects[0].width);
    try std.testing.expectEqual(20, rects[1].x);
    try std.testing.expectEqual(60, rects[1].width);
}

test "solve: percent pane resolved before fraction — fraction sees reduced space" {
    const p  = @import("blueprint.zig").pane;
    const vs = @import("blueprint.zig").vsplit;
    const B = vs(.{
        .children = &.{
            p(.{ .size = .{ .percent = 50 } }),
            p(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 });

    // 50% of 40 = 20 rows for percent pane; fraction absorbs the remaining 20.
    try std.testing.expectEqual(20, rects[0].height);
    try std.testing.expectEqual(20, rects[1].y);
    try std.testing.expectEqual(20, rects[1].height);
}

test "solve: single pane preserves non-zero origin" {
    const p = @import("blueprint.zig").pane;
    const S = p(.{ .size = .{ .fraction = 2 } });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 10, .y = 5, .width = 100, .height = 40 };
    const rects = try solve(arena.allocator(), S, bounds);

    try std.testing.expectEqual(1, rects.len);
    try std.testing.expectEqual(bounds, rects[0]);
}

test "leafCount: domain node counts all leaf panes inside it" {
    const p  = @import("blueprint.zig").pane;
    const d  = @import("blueprint.zig").domain;
    const Direction = @import("slot.zig").Direction;
    const B = d(.{
        .id        = "sidebar",
        .direction = Direction.vertical,
        .children  = &.{
            p(.{ .size = .{ .fraction = 1 } }),
            p(.{ .size = .{ .fraction = 1 } }),
        },
    });
    try std.testing.expectEqual(2, leafCount(B));
}

test "focusableLeafCount: domain node counts only focusable panes" {
    const p  = @import("blueprint.zig").pane;
    const d  = @import("blueprint.zig").domain;
    const Direction = @import("slot.zig").Direction;
    const B = d(.{
        .id        = "sidebar",
        .direction = Direction.vertical,
        .children  = &.{
            p(.{ .size = .{ .fraction = 1 } }),
            p(.{ .size = .{ .fraction = 1 }, .focusable = false }),
        },
    });
    try std.testing.expectEqual(1, focusableLeafCount(B));
}

test "solve: domain node produces same geometry as equivalent vsplit" {
    const p  = @import("blueprint.zig").pane;
    const d  = @import("blueprint.zig").domain;
    const vs = @import("blueprint.zig").vsplit;
    const Direction = @import("slot.zig").Direction;

    const WithDomain = d(.{
        .id        = "col",
        .direction = Direction.vertical,
        .size      = .{ .fixed = 25 },
        .children  = &.{
            p(.{ .size = .{ .fraction = 1 } }),
            p(.{ .size = .{ .fraction = 1 } }),
        },
    });
    const WithSplit = vs(.{
        .size     = .{ .fixed = 25 },
        .children = &.{
            p(.{ .size = .{ .fraction = 1 } }),
            p(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 0, .y = 0, .width = 25, .height = 40 };
    const dr = try solve(arena.allocator(), WithDomain, bounds);
    const sr = try solve(arena.allocator(), WithSplit,  bounds);

    try std.testing.expectEqual(sr[0], dr[0]);
    try std.testing.expectEqual(sr[1], dr[1]);
}

test "solve: nested hsplit/vsplit — sidebar + header/body produces 3 leaf rects" {
    const p  = @import("blueprint.zig").pane;
    const hs = @import("blueprint.zig").hsplit;
    const vs = @import("blueprint.zig").vsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .size = .{ .fixed = 20 } }),
            vs(.{
                .size     = .{ .fraction = 1 },
                .children = &.{
                    p(.{ .size = .{ .fixed = 5 } }),
                    p(.{ .size = .{ .fraction = 1 } }),
                },
            }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 });

    try std.testing.expectEqual(3, rects.len);
    // sidebar: x=0, full height, width=20
    try std.testing.expectEqual(0,  rects[0].x);
    try std.testing.expectEqual(20, rects[0].width);
    try std.testing.expectEqual(40, rects[0].height);
    // header: starts at x=20, y=0, fills remaining width (60), fixed height 5
    try std.testing.expectEqual(20, rects[1].x);
    try std.testing.expectEqual(0,  rects[1].y);
    try std.testing.expectEqual(60, rects[1].width);
    try std.testing.expectEqual(5,  rects[1].height);
    // body: starts at x=20, y=5, fills remaining width (60) and height (35)
    try std.testing.expectEqual(20, rects[2].x);
    try std.testing.expectEqual(5,  rects[2].y);
    try std.testing.expectEqual(60, rects[2].width);
    try std.testing.expectEqual(35, rects[2].height);
}
