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

// Converts an anonymous struct literal (.{ .fixed = N } etc.) to Size.
// box() takes `anytype` for opts because the children field has a variable-
// length type — so unlike slot(), no automatic coercion to Size happens.
fn optsToSize(comptime s: anytype) Size {
    if (@hasField(@TypeOf(s), "fixed"))    return .{ .fixed    = s.fixed };
    if (@hasField(@TypeOf(s), "fraction")) return .{ .fraction = s.fraction };
    if (@hasField(@TypeOf(s), "percent"))  return .{ .percent  = s.percent };
    @compileError("size must be .{ .fixed = N }, .{ .fraction = N }, or .{ .percent = N }");
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
        /// How much space this box claims along its parent's main axis.
        /// Ignored for the root box (which gets the full bounds). Required
        /// when this box is a child of another box — the parent solver reads
        /// it exactly like a slot's size.
        pub const size: Size = if (@hasField(@TypeOf(opts), "size")) optsToSize(opts.size) else .{ .fraction = 1 };
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

test "box: size defaults to fraction(1) when omitted" {
    const B = box(.{
        .direction = .horizontal,
        .children = &.{slot(.{ .size = .{ .fixed = 30 } })},
    });
    try std.testing.expectEqual(@as(u16, 1), B.size.fraction);
}

test "box: explicit size is preserved on the returned type" {
    const B = box(.{
        .size = .{ .fixed = 40 },
        .direction = .horizontal,
        .children = &.{slot(.{ .size = .{ .fixed = 30 } })},
    });
    try std.testing.expectEqual(@as(u16, 40), B.size.fixed);
}
