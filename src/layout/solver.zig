//! Layout solver — turns a comptime blueprint into a flat slice of Rects.
//!
//! The solver bridges the comptime blueprint tree (built with slot() and
//! box()) and the runtime Rects that widgets use to claim screen space. It
//! runs once per resize event, allocating from the frame arena so the result
//! is bulk-freed at the start of the next frame with zero per-Rect overhead.

const std = @import("std");
const Rect = @import("rect.zig").Rect;

/// Returns the total number of leaf slots in Blueprint's tree at comptime.
/// The result is used to allocate exactly the right slice before recursing.
fn leafCount(comptime Blueprint: type) usize {
    if (@hasDecl(Blueprint, "is_slot")) return 1;
    if (@hasDecl(Blueprint, "is_box")) {
        var count: usize = 0;
        inline for (Blueprint.children) |Child| {
            count += comptime leafCount(Child);
        }
        return count;
    }
    @compileError("Blueprint must be produced by slot() or box()");
}

/// Resolves a comptime layout blueprint into a flat slice of Rects.
///
/// Each element corresponds to one leaf slot in the blueprint tree, in
/// depth-first left-to-right order. The caller owns the returned slice;
/// pass the frame arena so it is freed each frame without individual frees.
///
/// `Blueprint` must be a type produced by slot() or box(). Any other type
/// is a compile-time error.
pub fn solve(
    allocator: std.mem.Allocator,
    comptime Blueprint: type,
    bounds: Rect,
) ![]Rect {
    if (!@hasDecl(Blueprint, "is_slot") and !@hasDecl(Blueprint, "is_box"))
        @compileError("solve: Blueprint must be a type returned by slot() or box()");
    const rects = try allocator.alloc(Rect, leafCount(Blueprint));
    solveInto(Blueprint, bounds, rects);
    return rects;
}

/// Fills dst with Rects for every leaf slot under Blueprint, treating
/// bounds as the root of this subtree. dst must be exactly
/// leafCount(Blueprint) long — the public solve() guarantees this.
fn solveInto(comptime Blueprint: type, bounds: Rect, dst: []Rect) void {
    if (@hasDecl(Blueprint, "is_slot")) {
        dst[0] = bounds;
        return;
    }
    // Compute immediate-child geometry into a stack-allocated array whose
    // length is comptime-known. These are transient bounds passed down during
    // recursion; only leaf Rects ever land in the output slice.
    var child_rects: [Blueprint.children.len]Rect = undefined;
    // is_horiz is comptime, so every branch that depends on it folds at
    // compile time — horizontal and vertical boxes produce different machine
    // code with zero shared runtime overhead.
    const is_horiz = Blueprint.direction == .horizontal;
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
            .fraction, .percent => {
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
        inline for (Blueprint.children, 0..) |Child, i| {
            switch (Child.size) {
                .fraction => |weight| {
                    const dim: u16 = @intCast(@min(
                        @as(u64, remaining) * weight / fraction_weight_total,
                        std.math.maxInt(u16),
                    ));
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

test "solve: single slot returns bounds unchanged" {
    const slot = @import("blueprint.zig").slot;
    const S = slot(.{ .size = .{ .fixed = 30 } });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 5, .y = 3, .width = 80, .height = 24 };
    const rects = try solve(arena.allocator(), S, bounds);

    try std.testing.expectEqual(@as(usize, 1), rects.len);
    try std.testing.expectEqual(bounds, rects[0]);
}

test "solve: box with one fixed child — placed at left edge" {
    const slot = @import("blueprint.zig").slot;
    const box = @import("blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{slot(.{ .size = .{ .fixed = 30 } })},
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const rects = try solve(arena.allocator(), B, bounds);

    try std.testing.expectEqual(@as(usize, 1), rects.len);
    try std.testing.expectEqual(@as(u16, 0), rects[0].x);
    try std.testing.expectEqual(@as(u16, 30), rects[0].width);
    try std.testing.expectEqual(@as(u16, 24), rects[0].height);
}

test "solve: box with two fixed children — correct offsets, no overlap" {
    const slot = @import("blueprint.zig").slot;
    const box = @import("blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .size = .{ .fixed = 20 } }),
            slot(.{ .size = .{ .fixed = 30 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const rects = try solve(arena.allocator(), B, bounds);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(@as(u16, 0), rects[0].x);
    try std.testing.expectEqual(@as(u16, 20), rects[0].width);
    try std.testing.expectEqual(@as(u16, 20), rects[1].x);
    try std.testing.expectEqual(@as(u16, 30), rects[1].width);
}

test "solve: box with fixed and fraction child — fraction gets remaining width" {
    const slot = @import("blueprint.zig").slot;
    const box = @import("blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .size = .{ .fixed = 30 } }),
            slot(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const rects = try solve(arena.allocator(), B, bounds);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(@as(u16, 30), rects[0].width);
    try std.testing.expectEqual(@as(u16, 30), rects[1].x);
    try std.testing.expectEqual(@as(u16, 50), rects[1].width);
}

test "solve: fixed + fraction — fraction gets remaining width" {
    const slot = @import("blueprint.zig").slot;
    const box = @import("blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .size = .{ .fixed = 20 } }),
            slot(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 24 });

    try std.testing.expectEqual(@as(u16, 20), rects[0].width);
    try std.testing.expectEqual(@as(u16, 20), rects[1].x);
    try std.testing.expectEqual(@as(u16, 60), rects[1].width);
}

test "solve: two equal fractions split remaining width evenly" {
    const slot = @import("blueprint.zig").slot;
    const box = @import("blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .size = .{ .fraction = 1 } }),
            slot(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 24 });

    try std.testing.expectEqual(@as(u16, 0), rects[0].x);
    try std.testing.expectEqual(@as(u16, 40), rects[0].width);
    try std.testing.expectEqual(@as(u16, 40), rects[1].x);
    try std.testing.expectEqual(@as(u16, 40), rects[1].width);
}

test "solve: weighted fractions split proportionally" {
    const slot = @import("blueprint.zig").slot;
    const box = @import("blueprint.zig").box;
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .size = .{ .fraction = 1 } }),
            slot(.{ .size = .{ .fraction = 2 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 90, .height = 24 });

    try std.testing.expectEqual(@as(u16, 30), rects[0].width);
    try std.testing.expectEqual(@as(u16, 30), rects[1].x);
    try std.testing.expectEqual(@as(u16, 60), rects[1].width);
}

test "solve: vertical box with two fixed children — correct y offsets, no overlap" {
    const slot = @import("blueprint.zig").slot;
    const box = @import("blueprint.zig").box;
    const B = box(.{
        .direction = .vertical,
        .children = &.{
            slot(.{ .size = .{ .fixed = 10 } }),
            slot(.{ .size = .{ .fixed = 20 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 });

    try std.testing.expectEqual(@as(u16, 0), rects[0].y);
    try std.testing.expectEqual(@as(u16, 10), rects[0].height);
    try std.testing.expectEqual(@as(u16, 10), rects[1].y);
    try std.testing.expectEqual(@as(u16, 20), rects[1].height);
    try std.testing.expectEqual(@as(u16, 80), rects[0].width);
}

test "solve: vertical box — fixed + fraction gets remaining height" {
    const slot = @import("blueprint.zig").slot;
    const box = @import("blueprint.zig").box;
    const B = box(.{
        .direction = .vertical,
        .children = &.{
            slot(.{ .size = .{ .fixed = 3 } }),
            slot(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 });

    try std.testing.expectEqual(@as(u16, 3), rects[0].height);
    try std.testing.expectEqual(@as(u16, 3), rects[1].y);
    try std.testing.expectEqual(@as(u16, 37), rects[1].height);
    try std.testing.expectEqual(@as(u16, 80), rects[1].width);
}

test "solve: vertical box — two equal fractions split height evenly" {
    const slot = @import("blueprint.zig").slot;
    const box = @import("blueprint.zig").box;
    const B = box(.{
        .direction = .vertical,
        .children = &.{
            slot(.{ .size = .{ .fraction = 1 } }),
            slot(.{ .size = .{ .fraction = 1 } }),
        },
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 });

    try std.testing.expectEqual(@as(u16, 0), rects[0].y);
    try std.testing.expectEqual(@as(u16, 20), rects[0].height);
    try std.testing.expectEqual(@as(u16, 20), rects[1].y);
    try std.testing.expectEqual(@as(u16, 20), rects[1].height);
}

test "solve: single slot preserves non-zero origin" {
    const slot = @import("blueprint.zig").slot;
    const S = slot(.{ .size = .{ .fraction = 2 } });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bounds = Rect{ .x = 10, .y = 5, .width = 100, .height = 40 };
    const rects = try solve(arena.allocator(), S, bounds);

    try std.testing.expectEqual(@as(usize, 1), rects.len);
    try std.testing.expectEqual(bounds, rects[0]);
}

test "solve: nested box — sidebar + header/body produces 3 leaf rects" {
    const slot = @import("blueprint.zig").slot;
    const box = @import("blueprint.zig").box;
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

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rects = try solve(arena.allocator(), B, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 });

    try std.testing.expectEqual(@as(usize, 3), rects.len);
    // sidebar: x=0, full height, width=20
    try std.testing.expectEqual(@as(u16, 0),  rects[0].x);
    try std.testing.expectEqual(@as(u16, 20), rects[0].width);
    try std.testing.expectEqual(@as(u16, 40), rects[0].height);
    // header: starts at x=20, y=0, fills remaining width (60), fixed height 5
    try std.testing.expectEqual(@as(u16, 20), rects[1].x);
    try std.testing.expectEqual(@as(u16, 0),  rects[1].y);
    try std.testing.expectEqual(@as(u16, 60), rects[1].width);
    try std.testing.expectEqual(@as(u16, 5),  rects[1].height);
    // body: starts at x=20, y=5, fills remaining width (60) and height (35)
    try std.testing.expectEqual(@as(u16, 20), rects[2].x);
    try std.testing.expectEqual(@as(u16, 5),  rects[2].y);
    try std.testing.expectEqual(@as(u16, 60), rects[2].width);
    try std.testing.expectEqual(@as(u16, 35), rects[2].height);
}
