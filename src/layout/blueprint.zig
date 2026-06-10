//! Comptime blueprint constructors for the layout system.
//!
//! A blueprint is a tree of comptime type descriptors built by calling
//! slot() and box() in your source code. Because the entire structure is
//! known at compile time, the solver traverses it with zero runtime overhead —
//! no heap allocation, no dynamic dispatch, no vtables.
//!
//! Example:
//!
//!   const layout = box(.{
//!       .direction = .horizontal,
//!       .children  = &.{
//!           slot(.{ .size = .{ .fixed = 30 } }),
//!           slot(.{ .size = .{ .fraction = 1 } }),
//!       },
//!   });

const std = @import("std");
const Size = @import("size.zig").Size;
const Direction = @import("slot.zig").Direction;

/// Returns a comptime leaf-node descriptor for the layout blueprint.
///
/// Each call produces an anonymous struct type carrying the size as a
/// compile-time constant. The solver identifies leaf nodes by checking for
/// the `is_slot` declaration via @hasDecl — no runtime tag needed.
///
/// Because this function returns a type, Zig requires its argument to be
/// comptime-known. That is enforced by the `comptime` parameter qualifier.
pub fn slot(comptime opts: struct { size: Size }) type {
    return struct {
        /// Marker the solver uses to distinguish leaf nodes from branch nodes.
        pub const is_slot = true;
        /// The size this panel claims along the layout axis.
        pub const size: Size = opts.size;
    };
}

/// Returns a comptime branch-node descriptor for the layout blueprint.
///
/// opts is anytype rather than a concrete struct because the children field
/// holds a *const [N]type whose length N varies per call site — there is no
/// single concrete type that could describe it. The compiler monomorphises
/// box() for each unique opts shape at the call site.
pub fn box(comptime opts: anytype) type {
    return struct {
        /// Marker the solver uses to distinguish branch nodes from leaf nodes.
        pub const is_box = true;
        /// The axis along which children are arranged.
        pub const direction: Direction = opts.direction;
        /// Comptime array of child descriptors (each a type returned by
        /// slot() or box()). The solver iterates with inline for.
        pub const children = opts.children;
    };
}

test "slot: produced type has is_slot marker" {
    const S = slot(.{ .size = .{ .fixed = 30 } });
    // @hasDecl checks for a named declaration on a type at comptime.
    // The solver uses this same check to tell leaves from branches.
    try std.testing.expect(@hasDecl(S, "is_slot"));
}

test "slot: size is preserved on the returned type" {
    const S = slot(.{ .size = .{ .fixed = 30 } });
    try std.testing.expectEqual(@as(u16, 30), S.size.fixed);
}

test "slot: fraction size is preserved" {
    const S = slot(.{ .size = .{ .fraction = 1 } });
    try std.testing.expectEqual(@as(u16, 1), S.size.fraction);
}

test "slot: two slots with different sizes carry different values" {
    const A = slot(.{ .size = .{ .fixed = 30 } });
    const B = slot(.{ .size = .{ .fixed = 40 } });
    try std.testing.expect(A.size.fixed != B.size.fixed);
}

test "box: produced type has is_box marker" {
    const B = box(.{
        .direction = .horizontal,
        .children = &.{slot(.{ .size = .{ .fixed = 30 } })},
    });
    try std.testing.expect(@hasDecl(B, "is_box"));
}

test "box: direction is preserved" {
    const B = box(.{
        .direction = .vertical,
        .children = &.{slot(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expectEqual(Direction.vertical, B.direction);
}

test "box: children length is accessible" {
    const B = box(.{
        .direction = .horizontal,
        .children = &.{
            slot(.{ .size = .{ .fixed = 20 } }),
            slot(.{ .size = .{ .fraction = 1 } }),
        },
    });
    try std.testing.expectEqual(@as(usize, 2), B.children.len);
}

test "box: children are identifiable as slots" {
    const B = box(.{
        .direction = .horizontal,
        .children = &.{slot(.{ .size = .{ .fixed = 20 } })},
    });
    try std.testing.expect(@hasDecl(B.children[0], "is_slot"));
}
