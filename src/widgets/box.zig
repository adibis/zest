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
const focusableLeafCount = @import("../layout/solver.zig").focusableLeafCount;
const FocusStack = @import("../core/focus.zig").FocusStack;

/// A resolved layout region with its associated render state for a single frame.
/// Each named field in the struct returned by Layout.panels() is a Panel.
pub const Panel = struct {
    win:     vaxis.Window,
    focused: bool,
};

/// Walks the blueprint tree and returns a comptime array of focusable flags,
/// one per leaf pane, in the same depth-first left-to-right order as solve().
fn leafFocusable(comptime Blueprint: type) [leafCount(Blueprint)]bool {
    if (@hasDecl(Blueprint, "is_pane")) {
        return .{Blueprint.focusable};
    }
    var result: [leafCount(Blueprint)]bool = undefined;
    var offset: usize = 0;
    inline for (Blueprint.children) |Child| {
        const count = comptime leafCount(Child);
        const sub = comptime leafFocusable(Child);
        for (0..count) |j| result[offset + j] = sub[j];
        offset += count;
    }
    return result;
}

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

/// Walks the blueprint tree and returns a comptime array of domain ids, one per
/// leaf pane, in depth-first left-to-right order. Each entry is the id of the
/// nearest enclosing domain() node, or "" if the pane is not inside any domain.
fn leafDomainsInner(comptime Blueprint: type, comptime current: [:0]const u8) [leafCount(Blueprint)][:0]const u8 {
    if (@hasDecl(Blueprint, "is_pane")) {
        return .{current};
    }
    const next: [:0]const u8 = if (@hasDecl(Blueprint, "is_domain")) Blueprint.id else current;
    var result: [leafCount(Blueprint)][:0]const u8 = undefined;
    var offset: usize = 0;
    inline for (Blueprint.children) |Child| {
        const count = comptime leafCount(Child);
        const sub   = comptime leafDomainsInner(Child, next);
        for (0..count) |j| result[offset + j] = sub[j];
        offset += count;
    }
    return result;
}

fn leafDomains(comptime Blueprint: type) [leafCount(Blueprint)][:0]const u8 {
    return leafDomainsInner(Blueprint, "");
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

/// For each leaf pane, returns its focusable index within its own domain.
/// The index is the count of focusable panes with the same domain id that
/// appear before this pane in depth-first order. Non-focusable panes get 0.
/// This is the value compared against FocusStack.activeIndex() for the
/// corresponding domain, so it must be computed per-domain, not globally.
fn leafDomainFocusableIndices(comptime Blueprint: type) [leafCount(Blueprint)]usize {
    // O(N²) over leaf count × per-domain string comparisons. N stays small
    // for fixed layouts (typical: 5–20 panes), but the quota is generous.
    @setEvalBranchQuota(100_000);
    const N          = comptime leafCount(Blueprint);
    const domains    = comptime leafDomains(Blueprint);
    const focusables = comptime leafFocusable(Blueprint);
    var result: [N]usize = undefined;
    inline for (0..N) |i| {
        comptime var count: usize = 0;
        if (comptime focusables[i]) {
            inline for (0..i) |j| {
                if (comptime (focusables[j] and std.mem.eql(u8, domains[j], domains[i]))) {
                    count += 1;
                }
            }
        }
        result[i] = count;
    }
    return result;
}

/// Returns the number of focusable panes whose nearest enclosing domain id
/// matches target_domain_id. Use this to size a per-domain FocusStack when
/// the blueprint contains domain() nodes.
fn focusableCountInDomain(comptime Blueprint: type, comptime target: [:0]const u8) usize {
    const N        = comptime leafCount(Blueprint);
    const domains  = comptime leafDomains(Blueprint);
    const focusables = comptime leafFocusable(Blueprint);
    comptime var count: usize = 0;
    inline for (0..N) |i| {
        if (focusables[i] and comptime std.mem.eql(u8, domains[i], target)) {
            count += 1;
        }
    }
    return count;
}

pub const Layout = struct {
    /// Returns the number of focusable leaf panes in Blueprint — use this to
    /// initialize a FocusStack so Tab cycling never lands on display-only panes.
    pub fn panelCount(comptime Blueprint: type) usize {
        return focusableLeafCount(Blueprint);
    }

    /// Returns the number of focusable panes inside the named domain. Use this
    /// to initialize a per-domain FocusStack when the blueprint has domain() nodes.
    ///
    ///   state.focus_sidebar = FocusStack.init(Focus.init(
    ///       Layout.panelCountInDomain(layout, "sidebar"),
    ///   ));
    pub fn panelCountInDomain(comptime Blueprint: type, comptime domain_id: [:0]const u8) usize {
        return focusableCountInDomain(Blueprint, domain_id);
    }

    /// Returns a comptime array of leaf pane IDs in depth-first order.
    /// Useful for deriving the ids list passed to Focus.is() without restating
    /// pane names that are already in the blueprint.
    pub fn panelIds(comptime Blueprint: type) [leafCount(Blueprint)][:0]const u8 {
        return leafIds(Blueprint);
    }

    /// Solves Blueprint's layout within bounds and returns a named struct of
    /// Panels, one per leaf pane. Each Panel carries the resolved vaxis.Window
    /// and a focused bool stamped from ctx.
    ///
    /// ctx is anytype and accepts two forms:
    ///
    ///   No domains  — pass .{ .focus = &state.focus } (or .{} for no focus)
    ///   With domains — pass a struct with one ?*const FocusStack field per
    ///                  domain id declared in the blueprint, e.g.:
    ///                  .{ .sidebar = &state.focus_sidebar, .main = &state.focus_main }
    ///
    /// Passing the wrong fields is a compile error. Each domain's focused bool
    /// is computed against its own FocusStack, so Tab never crosses boundaries.
    /// If a pane declares `border = true`, the border is drawn immediately and
    /// the Panel's window is the inner content area. All geometry is
    /// stack-allocated — no allocator needed.
    pub fn panels(
        comptime Blueprint: type,
        root_win: vaxis.Window,
        bounds: Rect,
        ctx: anytype,
    ) PanelsType(Blueprint) {
        var rects: [leafCount(Blueprint)]Rect = undefined;
        solveInto(Blueprint, bounds, &rects);
        const borders      = comptime leafBorders(Blueprint);
        const focusables   = comptime leafFocusable(Blueprint);
        const ids          = comptime leafIds(Blueprint);
        const domain_ids   = comptime leafDomains(Blueprint);
        const domain_fidxs = comptime leafDomainFocusableIndices(Blueprint);
        var result: PanelsType(Blueprint) = undefined;
        inline for (ids, 0..) |id, i| {
            const r = rects[i];
            const focused: bool = if (!focusables[i]) false else blk: {
                const dom = domain_ids[i];
                if (dom.len == 0) {
                    // No enclosing domain — use ctx.focus when present.
                    // ctx.focus is *FocusStack (not optional) when passed as &focus.
                    const active: ?usize = if (@hasField(@TypeOf(ctx), "focus"))
                        ctx.focus.activeIndex()
                    else
                        null;
                    break :blk if (active) |a| a == domain_fidxs[i] else false;
                } else {
                    // Inside a domain — look up the per-domain FocusStack.
                    const stack: ?*const FocusStack = @field(ctx, dom);
                    const active = if (stack) |s| s.activeIndex() else null;
                    break :blk if (active) |a| a == domain_fidxs[i] else false;
                }
            };
            @field(result, id) = Panel{
                .win = root_win.child(.{
                    .x_off = @intCast(r.x),
                    .y_off = @intCast(r.y),
                    .width  = r.width,
                    .height = r.height,
                    .border = if (borders[i]) .{ .where = .all } else .{},
                }),
                .focused = focused,
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

test "Layout.panelCount: excludes non-focusable panes" {
    const p  = @import("../layout/blueprint.zig").pane;
    const vs = @import("../layout/blueprint.zig").vsplit;
    const B = vs(.{
        .children = &.{
            p(.{ .id = "header", .size = .{ .fixed = 1 }, .focusable = false }),
            p(.{ .id = "a",      .size = .{ .fraction = 1 } }),
            p(.{ .id = "b",      .size = .{ .fraction = 1 } }),
            p(.{ .id = "footer", .size = .{ .fixed = 1 }, .focusable = false }),
        },
    });
    try std.testing.expectEqual(@as(usize, 2), Layout.panelCount(B));
}

test "Layout.panels: non-focusable pane always has focused = false" {
    const p  = @import("../layout/blueprint.zig").pane;
    const vs = @import("../layout/blueprint.zig").vsplit;
    const B = vs(.{
        .children = &.{
            p(.{ .id = "chrome",  .size = .{ .fixed = 1 }, .focusable = false }),
            p(.{ .id = "content", .size = .{ .fraction = 1 } }),
        },
    });

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 10, .cols = 80, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const root_win = vaxis.Window{
        .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0,
        .width = screen.width, .height = screen.height, .screen = &screen,
    };

    // Even with focus index 0 active, the non-focusable pane reports false.
    var focus = @import("../core/focus.zig").FocusStack.init(
        @import("../core/focus.zig").Focus.init(Layout.panelCount(B)),
    );
    const result = Layout.panels(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 10 }, .{ .focus = &focus });
    try std.testing.expect(!result.chrome.focused);
    try std.testing.expect(result.content.focused);
}

test "Layout.panels: focus index maps to focusable panes only, skipping non-focusable" {
    const p  = @import("../layout/blueprint.zig").pane;
    const vs = @import("../layout/blueprint.zig").vsplit;
    const B = vs(.{
        .children = &.{
            p(.{ .id = "a",      .size = .{ .fraction = 1 } }),
            p(.{ .id = "chrome", .size = .{ .fixed = 2 }, .focusable = false }),
            p(.{ .id = "b",      .size = .{ .fraction = 1 } }),
        },
    });

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 20, .cols = 80, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const root_win = vaxis.Window{
        .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0,
        .width = screen.width, .height = screen.height, .screen = &screen,
    };

    var focus = @import("../core/focus.zig").FocusStack.init(
        @import("../core/focus.zig").Focus.init(Layout.panelCount(B)),
    );
    // Index 0 → pane "a" (first focusable).
    var result = Layout.panels(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 20 }, .{ .focus = &focus });
    try std.testing.expect(result.a.focused);
    try std.testing.expect(!result.chrome.focused);
    try std.testing.expect(!result.b.focused);

    // Index 1 → pane "b" (second focusable), skipping chrome.
    focus.set(1);
    result = Layout.panels(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 20 }, .{ .focus = &focus });
    try std.testing.expect(!result.a.focused);
    try std.testing.expect(!result.chrome.focused);
    try std.testing.expect(result.b.focused);
}

test "Layout.panels: domain focus index stamps correct pane in each domain" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").hsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/slot.zig").Direction;
    const FocusStack_ = @import("../core/focus.zig").FocusStack;
    const Focus_ = @import("../core/focus.zig").Focus;

    const B = hs(.{
        .children = &.{
            d(.{
                .id        = "sidebar",
                .direction = Direction.vertical,
                .size      = .{ .fixed = 25 },
                .children  = &.{
                    p(.{ .id = "files",    .size = .{ .fraction = 1 } }),
                    p(.{ .id = "branches", .size = .{ .fraction = 1 } }),
                },
            }),
            d(.{
                .id        = "main",
                .direction = Direction.vertical,
                .size      = .{ .fraction = 1 },
                .children  = &.{
                    p(.{ .id = "diff",   .size = .{ .fraction = 1 } }),
                    p(.{ .id = "cmdlog", .size = .{ .fixed = 5 }, .focusable = false }),
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

    var fs_sidebar = FocusStack_.init(Focus_.init(Layout.panelCountInDomain(B, "sidebar")));
    var fs_main    = FocusStack_.init(Focus_.init(Layout.panelCountInDomain(B, "main")));

    // Each domain stamps its own active pane independently.
    // Both domains start at index 0 → files and diff are focused simultaneously.
    var result = Layout.panels(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 },
        .{ .sidebar = &fs_sidebar, .main = &fs_main });
    try std.testing.expect(result.files.focused);
    try std.testing.expect(!result.branches.focused);
    try std.testing.expect(result.diff.focused);   // main domain also at index 0
    try std.testing.expect(!result.cmdlog.focused); // non-focusable, always false

    // Advancing sidebar to index 1 changes only the sidebar domain's stamp.
    // Main domain is unchanged: diff remains focused.
    fs_sidebar.set(1);
    result = Layout.panels(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 },
        .{ .sidebar = &fs_sidebar, .main = &fs_main });
    try std.testing.expect(!result.files.focused);
    try std.testing.expect(result.branches.focused);
    try std.testing.expect(result.diff.focused);   // main domain untouched
}

test "Layout.panels: domain focus never bleeds across domain boundaries" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").hsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/slot.zig").Direction;
    const FocusStack_ = @import("../core/focus.zig").FocusStack;
    const Focus_ = @import("../core/focus.zig").Focus;

    const B = hs(.{
        .children = &.{
            d(.{
                .id        = "left",
                .direction = Direction.vertical,
                .size      = .{ .fixed = 20 },
                .children  = &.{
                    p(.{ .id = "a", .size = .{ .fraction = 1 } }),
                    p(.{ .id = "b", .size = .{ .fraction = 1 } }),
                },
            }),
            d(.{
                .id        = "right",
                .direction = Direction.vertical,
                .size      = .{ .fraction = 1 },
                .children  = &.{
                    p(.{ .id = "c", .size = .{ .fraction = 1 } }),
                    p(.{ .id = "dd", .size = .{ .fraction = 1 } }),
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

    // left domain index 1, right domain index 1 — each domain has its own active.
    var fs_left  = FocusStack_.init(Focus_.init(Layout.panelCountInDomain(B, "left")));
    var fs_right = FocusStack_.init(Focus_.init(Layout.panelCountInDomain(B, "right")));
    fs_left.set(1);
    fs_right.set(1);

    const result = Layout.panels(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 40 },
        .{ .left = &fs_left, .right = &fs_right });

    // Only index-1 of each domain is focused; index-0 panes are not.
    try std.testing.expect(!result.a.focused);
    try std.testing.expect(result.b.focused);
    try std.testing.expect(!result.c.focused);
    try std.testing.expect(result.dd.focused);
}

test "Layout.panels: backward compat — blueprint without domains accepts ctx.focus" {
    const p  = @import("../layout/blueprint.zig").pane;
    const vs = @import("../layout/blueprint.zig").vsplit;
    const FocusStack_ = @import("../core/focus.zig").FocusStack;
    const Focus_ = @import("../core/focus.zig").Focus;

    const B = vs(.{
        .children = &.{
            p(.{ .id = "top",    .size = .{ .fraction = 1 } }),
            p(.{ .id = "bottom", .size = .{ .fraction = 1 } }),
        },
    });

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 20, .cols = 80, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const root_win = vaxis.Window{
        .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0,
        .width = screen.width, .height = screen.height, .screen = &screen,
    };

    var focus = FocusStack_.init(Focus_.init(Layout.panelCount(B)));
    var result = Layout.panels(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 20 },
        .{ .focus = &focus });
    try std.testing.expect(result.top.focused);
    try std.testing.expect(!result.bottom.focused);

    focus.set(1);
    result = Layout.panels(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 20 },
        .{ .focus = &focus });
    try std.testing.expect(!result.top.focused);
    try std.testing.expect(result.bottom.focused);
}

test "Layout.panelCountInDomain: counts only focusable panes in the named domain" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").hsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/slot.zig").Direction;
    const B = hs(.{
        .children = &.{
            d(.{
                .id        = "sidebar",
                .direction = Direction.vertical,
                .size      = .{ .fixed = 25 },
                .children  = &.{
                    p(.{ .id = "files",    .size = .{ .fraction = 1 } }),
                    p(.{ .id = "branches", .size = .{ .fraction = 1 } }),
                    p(.{ .id = "commits",  .size = .{ .fraction = 1 } }),
                },
            }),
            d(.{
                .id        = "main",
                .direction = Direction.vertical,
                .size      = .{ .fraction = 1 },
                .children  = &.{
                    p(.{ .id = "diff",   .size = .{ .fraction = 1 } }),
                    p(.{ .id = "cmdlog", .size = .{ .fixed = 5 }, .focusable = false }),
                },
            }),
        },
    });
    try std.testing.expectEqual(@as(usize, 3), Layout.panelCountInDomain(B, "sidebar"));
    try std.testing.expectEqual(@as(usize, 1), Layout.panelCountInDomain(B, "main"));
}

test "Layout.panelCountInDomain: non-focusable panes inside domain are excluded" {
    const p  = @import("../layout/blueprint.zig").pane;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/slot.zig").Direction;
    const B = d(.{
        .id        = "col",
        .direction = Direction.vertical,
        .children  = &.{
            p(.{ .id = "a",      .size = .{ .fraction = 1 } }),
            p(.{ .id = "chrome", .size = .{ .fixed = 1 }, .focusable = false }),
            p(.{ .id = "b",      .size = .{ .fraction = 1 } }),
        },
    });
    try std.testing.expectEqual(@as(usize, 2), Layout.panelCountInDomain(B, "col"));
}

test "leafDomains: pane outside any domain gets empty string" {
    const p  = @import("../layout/blueprint.zig").pane;
    const vs = @import("../layout/blueprint.zig").vsplit;
    const B = vs(.{
        .children = &.{
            p(.{ .id = "a", .size = .{ .fraction = 1 } }),
            p(.{ .id = "b", .size = .{ .fraction = 1 } }),
        },
    });
    const domains = comptime leafDomains(B);
    try std.testing.expectEqualStrings("", domains[0]);
    try std.testing.expectEqualStrings("", domains[1]);
}

test "leafDomains: pane directly inside domain gets that domain's id" {
    const p  = @import("../layout/blueprint.zig").pane;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/slot.zig").Direction;
    const B = d(.{
        .id        = "sidebar",
        .direction = Direction.vertical,
        .children  = &.{
            p(.{ .id = "files",    .size = .{ .fraction = 1 } }),
            p(.{ .id = "branches", .size = .{ .fraction = 1 } }),
        },
    });
    const domains = comptime leafDomains(B);
    try std.testing.expectEqualStrings("sidebar", domains[0]);
    try std.testing.expectEqualStrings("sidebar", domains[1]);
}

test "leafDomains: split inside domain propagates domain id to its children" {
    const p  = @import("../layout/blueprint.zig").pane;
    const vs = @import("../layout/blueprint.zig").vsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/slot.zig").Direction;
    const B = d(.{
        .id        = "sidebar",
        .direction = Direction.horizontal,
        .children  = &.{
            vs(.{
                .size     = .{ .fraction = 1 },
                .children = &.{
                    p(.{ .id = "a", .size = .{ .fraction = 1 } }),
                    p(.{ .id = "b", .size = .{ .fraction = 1 } }),
                },
            }),
        },
    });
    const domains = comptime leafDomains(B);
    try std.testing.expectEqualStrings("sidebar", domains[0]);
    try std.testing.expectEqualStrings("sidebar", domains[1]);
}

test "leafDomains: nested domains — inner id wins over outer" {
    const p  = @import("../layout/blueprint.zig").pane;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/slot.zig").Direction;
    const B = d(.{
        .id        = "outer",
        .direction = Direction.horizontal,
        .children  = &.{
            p(.{ .id = "left", .size = .{ .fraction = 1 } }),
            d(.{
                .id        = "inner",
                .direction = Direction.vertical,
                .size      = .{ .fraction = 1 },
                .children  = &.{
                    p(.{ .id = "right", .size = .{ .fraction = 1 } }),
                },
            }),
        },
    });
    const domains = comptime leafDomains(B);
    try std.testing.expectEqualStrings("outer", domains[0]);
    try std.testing.expectEqualStrings("inner", domains[1]);
}

test "leafDomains: mixed — some panes in domain, some outside" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").hsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/slot.zig").Direction;
    const B = hs(.{
        .children = &.{
            d(.{
                .id        = "sidebar",
                .direction = Direction.vertical,
                .size      = .{ .fixed = 25 },
                .children  = &.{
                    p(.{ .id = "files", .size = .{ .fraction = 1 } }),
                },
            }),
            p(.{ .id = "footer", .size = .{ .fraction = 1 } }),
        },
    });
    const domains = comptime leafDomains(B);
    try std.testing.expectEqualStrings("sidebar", domains[0]);
    try std.testing.expectEqualStrings("",        domains[1]);
}
