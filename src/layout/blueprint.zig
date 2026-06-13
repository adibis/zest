//! Comptime blueprint constructors for the layout system.
//!
//! A blueprint is a tree of comptime type descriptors. hsplit() and vsplit()
//! are branch nodes that divide screen space along an axis. pane() is a leaf
//! node — the named endpoint that becomes a Panel at runtime.
//!
//! hsplit() adds a horizontal dividing line — children stack top-to-bottom.
//! vsplit() adds a vertical dividing line — children sit left-to-right.
//! This matches the tmux/vim convention.
//!
//! Branch nodes produce no rendered output. They dissolve into geometry during
//! the solve pass. Only pane nodes survive into the result: each becomes a
//! Panel{ win, focused } in the struct returned by Layout.panels().
//!
//! Example:
//!
//!   const layout = vsplit(.{
//!       .children = &.{
//!           pane(.{ .id = "sidebar", .size = .{ .fixed = 30 } }),
//!           hsplit(.{
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

/// Which axis children are stacked along inside a split or domain node.
pub const Direction = enum {
    horizontal, // children placed left to right, each consuming width
    vertical,   // children placed top to bottom, each consuming height
};

/// Identifies which kind of blueprint node a type represents.
/// All node types produced by pane(), hsplit(), vsplit(), and domain() carry
/// this as a comptime constant so dispatch sites can switch exhaustively.
pub const NodeKind = enum { pane, split, domain };

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
        pub const node_kind: NodeKind = .pane;
        pub const size: Size = opts.size;
        pub const border: bool = opts.border;
        pub const id: [:0]const u8 = opts.id;
        pub const focusable: bool = opts.focusable;
    };
}

// Converts an anonymous size literal (.{ .fixed = N } etc.) to Size.
// hsplit/vsplit take `anytype` for opts because the children field has a
// variable-length type — so unlike pane(), no automatic coercion happens.
//
// Exactly one of fixed/fraction/percent must be present. A previous form
// fell through to the first matching field, so a typo like
// .{ .fixed = 10, .fraction = 5 } would silently honor only .fixed; the
// explicit count rejects that at compile time.
fn optsToSize(comptime s: anytype) Size {
    const T = @TypeOf(s);
    const has_fixed    = @hasField(T, "fixed");
    const has_fraction = @hasField(T, "fraction");
    const has_percent  = @hasField(T, "percent");
    const present: u2 = @as(u2, @intFromBool(has_fixed))
                     + @as(u2, @intFromBool(has_fraction))
                     + @as(u2, @intFromBool(has_percent));
    if (present != 1)
        @compileError("size must specify exactly one of .fixed, .fraction, or .percent");
    if (has_fixed)    return .{ .fixed    = s.fixed };
    if (has_fraction) return .{ .fraction = s.fraction };
    if (s.percent > 100) @compileError("percent size must be 0–100");
    return .{ .percent = s.percent };
}

fn splitImpl(comptime dir: Direction, comptime opts: anytype) type {
    return struct {
        pub const node_kind: NodeKind = .split;
        pub const size: Size = if (@hasField(@TypeOf(opts), "size")) optsToSize(opts.size) else .{ .fraction = 1 };
        pub const direction: Direction = dir;
        pub const children = opts.children;
    };
}

/// Returns a comptime branch-node descriptor that adds a horizontal split line.
/// Children are stacked top-to-bottom. Produces no Panel of its own — only
/// pane nodes at the leaves of the tree become Panels.
///
/// Matches tmux/vim: "horizontal split" means a horizontal line divides the
/// screen, producing windows above and below.
///
/// opts is anytype rather than a concrete struct because the children field
/// holds a *const [N]type whose length N varies per call site.
pub fn hsplit(comptime opts: anytype) type {
    return splitImpl(.vertical, opts);
}

/// Returns a comptime branch-node descriptor that adds a vertical split line.
/// Children are arranged left-to-right. Produces no Panel of its own — only
/// pane nodes at the leaves of the tree become Panels.
///
/// Matches tmux/vim: "vertical split" means a vertical line divides the
/// screen, producing windows side by side.
///
/// opts is anytype rather than a concrete struct because the children field
/// holds a *const [N]type whose length N varies per call site.
pub fn vsplit(comptime opts: anytype) type {
    return splitImpl(.horizontal, opts);
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
        pub const node_kind: NodeKind      = .domain;
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

test "pane: node_kind is .pane" {
    const S = pane(.{ .size = .{ .fixed = 30 } });
    try std.testing.expectEqual(NodeKind.pane, S.node_kind);
}

test "pane: size is preserved on the returned type" {
    const S = pane(.{ .size = .{ .fixed = 30 } });
    try std.testing.expectEqual(30, S.size.fixed);
}

test "pane: fraction size is preserved" {
    const S = pane(.{ .size = .{ .fraction = 1 } });
    try std.testing.expectEqual(1, S.size.fraction);
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

test "hsplit: node_kind is .split" {
    const B = hsplit(.{
        .children = &.{pane(.{ .size = .{ .fixed = 30 } })},
    });
    try std.testing.expectEqual(NodeKind.split, B.node_kind);
}

test "hsplit: direction is vertical (children stack top-to-bottom)" {
    const B = hsplit(.{
        .children = &.{pane(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expectEqual(Direction.vertical, B.direction);
}

test "vsplit: direction is horizontal (children sit left-to-right)" {
    const B = vsplit(.{
        .children = &.{pane(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expectEqual(Direction.horizontal, B.direction);
}

test "hsplit: children length is accessible" {
    const B = hsplit(.{
        .children = &.{
            pane(.{ .size = .{ .fixed = 20 } }),
            pane(.{ .size = .{ .fraction = 1 } }),
        },
    });
    try std.testing.expectEqual(2, B.children.len);
}

test "hsplit: children have node_kind .pane" {
    const B = hsplit(.{
        .children = &.{pane(.{ .size = .{ .fixed = 20 } })},
    });
    try std.testing.expectEqual(NodeKind.pane, B.children[0].node_kind);
}

test "hsplit: size defaults to fraction(1) when omitted" {
    const B = hsplit(.{
        .children = &.{pane(.{ .size = .{ .fixed = 30 } })},
    });
    try std.testing.expectEqual(1, B.size.fraction);
}

test "hsplit: explicit size is preserved on the returned type" {
    const B = hsplit(.{
        .size     = .{ .fixed = 40 },
        .children = &.{pane(.{ .size = .{ .fixed = 30 } })},
    });
    try std.testing.expectEqual(40, B.size.fixed);
}

test "domain: node_kind is .domain" {
    const B = domain(.{
        .id        = "sidebar",
        .direction = Direction.vertical,
        .children  = &.{pane(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expectEqual(NodeKind.domain, B.node_kind);
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
    try std.testing.expectEqual(1, B.size.fraction);
}

test "domain: explicit size is preserved on the returned type" {
    const B = domain(.{
        .id        = "nav",
        .direction = Direction.vertical,
        .size      = .{ .fixed = 25 },
        .children  = &.{pane(.{ .size = .{ .fraction = 1 } })},
    });
    try std.testing.expectEqual(25, B.size.fixed);
}

test "domain: children have node_kind .pane" {
    const B = domain(.{
        .id        = "main",
        .direction = Direction.vertical,
        .children  = &.{pane(.{ .size = .{ .fixed = 10 } })},
    });
    try std.testing.expectEqual(NodeKind.pane, B.children[0].node_kind);
}

test "Direction: horizontal and vertical are distinct" {
    try std.testing.expect(Direction.horizontal != Direction.vertical);
}

test "Direction: exhaustive switch compiles" {
    // Verifies the enum has exactly these two values — if a third were added
    // without an else branch, this test would fail to compile, catching the gap.
    const d = Direction.horizontal;
    const result: u8 = switch (d) {
        .horizontal => 0,
        .vertical   => 1,
    };
    try std.testing.expectEqual(0, result);
}
