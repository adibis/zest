//! Comptime blueprint constructors for the layout system.
//!
//! A blueprint is a tree of comptime type descriptors. hsplit() and vsplit()
//! are branch nodes that divide screen space along an axis. pane() is a leaf
//! node — the named endpoint that becomes a Panel at runtime.
//!
//! Branch nodes produce no rendered output. They dissolve into geometry during
//! the solve pass. Only pane nodes survive into the result: each becomes a
//! Panel{ win, focused } in the struct returned by Layout.panels().
//!
//! Example:
//!
//!   const layout = hsplit(.{
//!       .children = &.{
//!           pane(.{ .id = "sidebar", .size = .{ .fixed = 30 } }),
//!           vsplit(.{
//!               .size     = .{ .fraction = 1 },
//!               .children = &.{
//!                   pane(.{ .id = "header", .size = .{ .fixed = 3 } }),
//!                   pane(.{ .id = "body",   .size = .{ .fraction = 1 } }),
//!               },
//!           }),
//!       },
//!   });

const std = @import("std");
const Size = @import("size.zig").Size;
const Direction = @import("slot.zig").Direction;

/// Returns a comptime leaf-node descriptor for the layout blueprint.
///
/// pane is the only node type that produces output: each pane becomes a
/// Panel{ win, focused } in the struct returned by Layout.panels(). hsplit
/// and vsplit dissolve into geometry at solve time and produce nothing.
///
/// Each call produces an anonymous struct type carrying the declared fields
/// as compile-time constants. The solver identifies leaf nodes via @hasDecl
/// for the is_pane marker — no runtime tag needed.
pub fn pane(comptime opts: struct {
    size: Size,
    border: bool = false,
    /// Field name in the struct returned by Layout.panels().
    /// Must be unique across all panes in a blueprint tree.
    id: [:0]const u8 = "",
    /// When false, this pane is excluded from the focus ring and always
    /// reports focused = false. Use for chrome (headers, footers, log
    /// strips) that should never receive keyboard focus.
    focusable: bool = true,
}) type {
    return struct {
        pub const is_pane = true;
        pub const size: Size = opts.size;
        pub const border: bool = opts.border;
        pub const id: [:0]const u8 = opts.id;
        pub const focusable: bool = opts.focusable;
    };
}

// Converts an anonymous size literal (.{ .fixed = N } etc.) to Size.
// hsplit/vsplit take `anytype` for opts because the children field has a
// variable-length type — so unlike pane(), no automatic coercion happens.
fn optsToSize(comptime s: anytype) Size {
    if (@hasField(@TypeOf(s), "fixed"))    return .{ .fixed    = s.fixed };
    if (@hasField(@TypeOf(s), "fraction")) return .{ .fraction = s.fraction };
    if (@hasField(@TypeOf(s), "percent"))  return .{ .percent  = s.percent };
    @compileError("size must be .{ .fixed = N }, .{ .fraction = N }, or .{ .percent = N }");
}

// TODO(design): The is_pane / is_split / is_domain boolean marker pattern
// has no exhaustiveness guarantee. A type that accidentally declares both
// is_pane and is_split would silently take the is_pane branch everywhere.
// The correct fix is a single `node_kind: enum { pane, split, domain }`
// field, dispatched via `switch (Blueprint.node_kind)` in the solver and
// compositor. Defer until the custom widget state protocol is finalised and
// we know whether new node kinds will be needed.
fn splitImpl(comptime dir: Direction, comptime opts: anytype) type {
    return struct {
        pub const is_split = true;
        pub const size: Size = if (@hasField(@TypeOf(opts), "size")) optsToSize(opts.size) else .{ .fraction = 1 };
        pub const direction: Direction = dir;
        pub const children = opts.children;
    };
}

/// Returns a comptime branch-node descriptor that divides space horizontally.
/// Children are arranged left-to-right. Produces no Panel of its own — only
/// pane nodes at the leaves of the tree become Panels.
///
/// opts is anytype rather than a concrete struct because the children field
/// holds a *const [N]type whose length N varies per call site.
pub fn hsplit(comptime opts: anytype) type {
    return splitImpl(.horizontal, opts);
}

/// Returns a comptime branch-node descriptor that divides space vertically.
/// Children are arranged top-to-bottom. Produces no Panel of its own — only
/// pane nodes at the leaves of the tree become Panels.
///
/// opts is anytype rather than a concrete struct because the children field
/// holds a *const [N]type whose length N varies per call site.
pub fn vsplit(comptime opts: anytype) type {
    return splitImpl(.vertical, opts);
}

/// Returns a comptime focus-domain descriptor.
///
/// A domain node is geometrically identical to a split — it has a direction,
/// size, and children, and produces no Panel of its own. The difference is the
/// comptime id field, which marks a focus boundary: Tab cycling is constrained
/// to the focusable panes within a single domain. Layout.panels() accepts one
/// FocusStack per domain id declared in the blueprint.
///
/// opts is anytype for the same reason as hsplit/vsplit: children is a
/// *const [N]type whose length N varies per call site. direction and id
/// are required fields; size defaults to fraction(1) when omitted.
pub fn domain(comptime opts: anytype) type {
    return struct {
        pub const is_domain                = true;
        pub const id:        [:0]const u8  = opts.id;
        pub const size:      Size          = if (@hasField(@TypeOf(opts), "size")) optsToSize(opts.size) else .{ .fraction = 1 };
        pub const direction: Direction     = opts.direction;
        pub const children                 = opts.children;
    };
}

test "pane: focusable defaults to true" {
    const S = pane(.{ .size = .{ .fixed = 30 } });
    try std.testing.expect(S.focusable);
}

test "pane: explicit focusable = false is preserved" {
    const S = pane(.{ .size = .{ .fixed = 30 }, .focusable = false });
    try std.testing.expect(!S.focusable);
}

test "pane: border defaults to false" {
    const S = pane(.{ .size = .{ .fixed = 30 } });
    try std.testing.expect(!S.border);
}

test "pane: explicit border = true is preserved" {
    const S = pane(.{ .size = .{ .fixed = 30 }, .border = true });
    try std.testing.expect(S.border);
}

test "pane: produced type has is_pane marker" {
    const S = pane(.{ .size = .{ .fixed = 30 } });
    try std.testing.expect(@hasDecl(S, "is_pane"));
}

test "pane: size is preserved on the returned type" {
    const S = pane(.{ .size = .{ .fixed = 30 } });
    try std.testing.expectEqual(@as(u16, 30), S.size.fixed);
}

test "pane: fraction size is preserved" {
    const S = pane(.{ .size = .{ .fraction = 1 } });
    try std.testing.expectEqual(@as(u16, 1), S.size.fraction);
}

test "pane: id defaults to empty string" {
    const S = pane(.{ .size = .{ .fixed = 30 } });
    try std.testing.expectEqualStrings("", S.id);
}

test "pane: explicit id is preserved on the returned type" {
    const S = pane(.{ .size = .{ .fixed = 30 }, .id = "sidebar" });
    try std.testing.expectEqualStrings("sidebar", S.id);
}

test "pane: two panes with different sizes carry different values" {
    const A = pane(.{ .size = .{ .fixed = 30 } });
    const B = pane(.{ .size = .{ .fixed = 40 } });
    try std.testing.expect(A.size.fixed != B.size.fixed);
}

test "hsplit: produced type has is_split marker" {
    const B = hsplit(.{
        .children = &.{pane(.{ .size = .{ .fixed = 30 } })},
    });
    try std.testing.expect(@hasDecl(B, "is_split"));
}

test "hsplit: direction is horizontal" {
    const B = hsplit(.{
        .children = &.{pane(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expectEqual(Direction.horizontal, B.direction);
}

test "vsplit: direction is vertical" {
    const B = vsplit(.{
        .children = &.{pane(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expectEqual(Direction.vertical, B.direction);
}

test "hsplit: children length is accessible" {
    const B = hsplit(.{
        .children = &.{
            pane(.{ .size = .{ .fixed = 20 } }),
            pane(.{ .size = .{ .fraction = 1 } }),
        },
    });
    try std.testing.expectEqual(@as(usize, 2), B.children.len);
}

test "hsplit: children are identifiable as panes" {
    const B = hsplit(.{
        .children = &.{pane(.{ .size = .{ .fixed = 20 } })},
    });
    try std.testing.expect(@hasDecl(B.children[0], "is_pane"));
}

test "hsplit: size defaults to fraction(1) when omitted" {
    const B = hsplit(.{
        .children = &.{pane(.{ .size = .{ .fixed = 30 } })},
    });
    try std.testing.expectEqual(@as(u16, 1), B.size.fraction);
}

test "hsplit: explicit size is preserved on the returned type" {
    const B = hsplit(.{
        .size     = .{ .fixed = 40 },
        .children = &.{pane(.{ .size = .{ .fixed = 30 } })},
    });
    try std.testing.expectEqual(@as(u16, 40), B.size.fixed);
}

test "domain: produced type has is_domain marker" {
    const B = domain(.{
        .id        = "sidebar",
        .direction = Direction.vertical,
        .children  = &.{pane(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expect(@hasDecl(B, "is_domain"));
}

test "domain: id is preserved on the returned type" {
    const B = domain(.{
        .id        = "sidebar",
        .direction = Direction.vertical,
        .children  = &.{pane(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expectEqualStrings("sidebar", B.id);
}

test "domain: direction is preserved on the returned type" {
    const B = domain(.{
        .id        = "nav",
        .direction = Direction.horizontal,
        .children  = &.{pane(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expectEqual(Direction.horizontal, B.direction);
}

test "domain: size defaults to fraction(1) when omitted" {
    const B = domain(.{
        .id        = "nav",
        .direction = Direction.vertical,
        .children  = &.{pane(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expectEqual(@as(u16, 1), B.size.fraction);
}

test "domain: explicit size is preserved on the returned type" {
    const B = domain(.{
        .id        = "nav",
        .direction = Direction.vertical,
        .size      = .{ .fixed = 25 },
        .children  = &.{pane(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expectEqual(@as(u16, 25), B.size.fixed);
}

test "domain: children are identifiable as panes" {
    const B = domain(.{
        .id        = "main",
        .direction = Direction.vertical,
        .children  = &.{pane(.{ .size = .{ .fixed = 10 } })},
    });
    try std.testing.expect(@hasDecl(B.children[0], "is_pane"));
}
