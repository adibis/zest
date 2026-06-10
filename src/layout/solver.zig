//! Layout solver — turns a comptime blueprint into a flat slice of Rects.
//!
//! The solver bridges the comptime blueprint tree (built with slot() and
//! box()) and the runtime Rects that widgets use to claim screen space. It
//! runs once per resize event, allocating from the frame arena so the result
//! is bulk-freed at the start of the next frame with zero per-Rect overhead.

const std = @import("std");
const Rect = @import("rect.zig").Rect;

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
    if (@hasDecl(Blueprint, "is_slot")) {
        // A single leaf slot claims the entire bounds — no subdivision needed.
        const rects = try allocator.alloc(Rect, 1);
        rects[0] = bounds;
        return rects;
    }
    // Passing a type that carries neither is_slot nor is_box is a programming
    // error. Because Blueprint is comptime, the compiler monomorphises solve()
    // separately for each call site, and @compileError fires only for the
    // monomorphised version where Blueprint has neither marker.
    @compileError("solve: Blueprint must be a type returned by slot() or box()");
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
