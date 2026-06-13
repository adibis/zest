//! Layout compositor — bridges the comptime blueprint and the runtime render loop.
//!
//! Call Layout.panels() on each resize or focus event to get a named struct of
//! Panels, one field per pane in the blueprint. Access panels by name
//! (e.g. result.sidebar) — the struct type is derived from the blueprint at
//! compile time. All geometry is stack-allocated; no arena or allocator needed.
//!
//! The pipeline in one line:
//!   vsplit/hsplit  →  pure geometry, no output
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
const focus_mod       = @import("../core/focus.zig");
const Focus           = focus_mod.Focus;
const FocusStack      = focus_mod.FocusStack;
const DomainFocusType = focus_mod.DomainFocusType;

/// A resolved layout region with its associated render state for a single frame.
/// Each named field in the struct returned by Layout.panels() is a Panel.
pub const Panel = struct {
    win:     vaxis.Window,
    focused: bool,
};

// ctx in Layout.panels() is anytype — it accepts any struct whose fields match
// the domain ids declared in the blueprint. This catches wrong field names at
// compile time via @field, but not wrong types. A typed RenderContext would
// give better error messages; the cost is coupling the type to the blueprint.

/// Generic depth-first tree-walker. Collects one value of type T per leaf pane,
/// in the same left-to-right order as solve(). Ex must be a namespace with a
/// single declaration `fn extract(comptime P: type) T` that returns the value
/// for a leaf pane type P.
fn leafCollect(
    comptime T: type,
    comptime Blueprint: type,
    comptime Ex: type,
) [leafCount(Blueprint)]T {
    if (!@hasDecl(Blueprint, "node_kind"))
        @compileError("Blueprint must be produced by pane(), vsplit(), hsplit(), or domain()");
    if (Blueprint.node_kind == .pane) return .{Ex.extract(Blueprint)};
    var result: [leafCount(Blueprint)]T = undefined;
    var offset: usize = 0;
    inline for (Blueprint.children) |Child| {
        const count = comptime leafCount(Child);
        const sub   = comptime leafCollect(T, Child, Ex);
        for (0..count) |j| result[offset + j] = sub[j];
        offset += count;
    }
    return result;
}

/// Returns a comptime array of focusable flags, one per leaf pane.
fn leafFocusable(comptime Blueprint: type) [leafCount(Blueprint)]bool {
    return leafCollect(bool, Blueprint, struct {
        fn extract(comptime P: type) bool { return P.focusable; }
    });
}

/// Returns a comptime array of border flags, one per leaf pane.
fn leafBorders(comptime Blueprint: type) [leafCount(Blueprint)]bool {
    return leafCollect(bool, Blueprint, struct {
        fn extract(comptime P: type) bool { return P.border; }
    });
}

/// Returns a comptime array of pane ids, one per leaf pane.
fn leafIds(comptime Blueprint: type) [leafCount(Blueprint)][:0]const u8 {
    return leafCollect([:0]const u8, Blueprint, struct {
        fn extract(comptime P: type) [:0]const u8 { return P.id; }
    });
}

/// Walks the blueprint tree and returns a comptime array of domain ids, one per
/// leaf pane, in depth-first left-to-right order. Each entry is the id of the
/// nearest enclosing domain() node, or "" if the pane is not inside any domain.
fn leafDomainsInner(comptime Blueprint: type, comptime current: [:0]const u8) [leafCount(Blueprint)][:0]const u8 {
    if (Blueprint.node_kind == .pane) return .{current};
    const next: [:0]const u8 = if (Blueprint.node_kind == .domain) Blueprint.id else current;
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
    // Detect duplicate pane ids at compile time. Two panes with the same id
    // would silently produce a struct where the second field shadows the first,
    // making one pane permanently unreachable. O(N²) but N is always small.
    inline for (0..N) |i| {
        inline for (i + 1..N) |j| {
            if (comptime std.mem.eql(u8, ids[i], ids[j])) {
                @compileError("duplicate pane id '" ++ ids[i] ++ "' in blueprint");
            }
        }
    }
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

/// Counts domain() nodes in the blueprint tree.
fn domainCount(comptime Blueprint: type) usize {
    if (Blueprint.node_kind == .pane) return 0;
    var count: usize = if (Blueprint.node_kind == .domain) 1 else 0;
    inline for (Blueprint.children) |Child| count += domainCount(Child);
    return count;
}

/// Collects domain ids in depth-first order, one per domain() node.
fn domainCollect(comptime Blueprint: type) [domainCount(Blueprint)][:0]const u8 {
    if (Blueprint.node_kind == .pane) return .{};
    var result: [domainCount(Blueprint)][:0]const u8 = undefined;
    var offset: usize = 0;
    if (Blueprint.node_kind == .domain) {
        result[0] = Blueprint.id;
        offset = 1;
    }
    inline for (Blueprint.children) |Child| {
        const sub = comptime domainCollect(Child);
        for (0..sub.len) |j| result[offset + j] = sub[j];
        offset += sub.len;
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
    fn focusablePanelCount(comptime Blueprint: type) usize {
        return focusableLeafCount(Blueprint);
    }

    /// Returns the number of focusable panes inside the named domain. Use this
    /// to initialize a per-domain FocusStack when the blueprint has domain() nodes.
    ///
    ///   state.focus_sidebar = FocusStack.init(Focus.init(
    ///       Layout.focusablePanelCountInDomain(layout, "sidebar"),
    ///   ));
    fn focusablePanelCountInDomain(comptime Blueprint: type, comptime domain_id: [:0]const u8) usize {
        return focusableCountInDomain(Blueprint, domain_id);
    }

    /// Returns a comptime array of ALL leaf pane IDs in depth-first order,
    /// including non-focusable panes. Not safe to pass to Focus.is() — that
    /// function requires a focusable-only list whose positions match Focus.index.
    /// Use domainFocusType for type-safe focus navigation.
    pub fn panelIds(comptime Blueprint: type) [leafCount(Blueprint)][:0]const u8 {
        return leafIds(Blueprint);
    }

    /// Returns a struct type wrapping a FocusStack for the named domain, with
    /// each focusable panel mapped to a typed enum value. Eliminates integer
    /// and string literals from navigation code:
    ///
    ///     const SF = Layout.domainFocusType(layout, "sidebar");
    ///     var sf = SF.init();
    ///     sf.set(.files);       // jump to files — no integer, no string
    ///     sf.is(.branches)      // check focus  — no integer, no string
    ///     &sf.stack             // raw FocusStack for Layout.panels()
    pub fn domainFocusType(
        comptime Blueprint: type,
        comptime domain_id: [:0]const u8,
    ) type {
        @setEvalBranchQuota(100_000);
        const N           = comptime leafCount(Blueprint);
        const ids_        = comptime leafIds(Blueprint);
        const domains_    = comptime leafDomains(Blueprint);
        const focusables_ = comptime leafFocusable(Blueprint);
        const count       = comptime focusableCountInDomain(Blueprint, domain_id);

        // Collect focusable panel names in this domain, in focus-index order.
        var panel_names: [count][:0]const u8 = undefined;
        var k: usize = 0;
        inline for (0..N) |i| {
            if (comptime (focusables_[i] and std.mem.eql(u8, domains_[i], domain_id))) {
                panel_names[k] = ids_[i];
                k += 1;
            }
        }

        return DomainFocusType(count, panel_names);
    }

    /// Returns an enum type listing every domain() id in the blueprint.
    /// Use this to track the active domain as a value rather than a pointer:
    ///
    ///     const DomainId = Layout.domainIdType(layout);
    ///     var active: DomainId = .sidebar;
    ///     active = .main;                 // switch — no pointer, can't dangle
    ///     if (active == .sidebar) { ... } // exhaustive switch prevents missed cases
    ///
    /// A switch on DomainId is exhaustive — adding a domain to the blueprint
    /// produces a compile error at every non-exhaustive switch site.
    pub fn domainIdType(comptime Blueprint: type) type {
        const count = comptime domainCount(Blueprint);
        const ids   = comptime domainCollect(Blueprint);
        var vals: [count]usize = undefined;
        for (0..count) |i| vals[i] = i;
        return @Enum(usize, .exhaustive, &ids, &vals);
    }

    /// Returns a struct type holding all domain focus state for Blueprint.
    /// One field per domain() node (a DomainFocusType), plus active_domain.
    /// All fields are derived from the blueprint — adding a domain to the
    /// blueprint adds it to this struct automatically.
    ///
    ///     const FocusState = Layout.focusStateType(layout);
    ///     state.focus = Layout.focusStateInit(layout);
    ///     state.focus.sidebar.is(.files)  // per-domain focus check
    ///     state.focus.active_domain = .main  // switch active domain
    pub fn focusStateType(comptime Blueprint: type) type {
        @setEvalBranchQuota(100_000);
        const count = comptime domainCount(Blueprint);
        const ids   = comptime domainCollect(Blueprint);
        const DomId = comptime domainIdType(Blueprint);
        var names: [count + 1][]const u8 = undefined;
        var types:  [count + 1]type = undefined;
        var attrs:  [count + 1]std.builtin.Type.StructField.Attributes = undefined;
        inline for (ids, 0..) |id, i| {
            names[i] = id;
            types[i] = domainFocusType(Blueprint, id);
            attrs[i] = .{};
        }
        names[count] = "active_domain";
        types[count] = DomId;
        attrs[count] = .{};
        return @Struct(.auto, null, &names, &types, &attrs);
    }

    /// Returns a default-initialized focusStateType(Blueprint).
    /// Each domain stack is ready to use. The first domain in blueprint
    /// depth-first order starts as the active domain.
    pub fn focusStateInit(comptime Blueprint: type) focusStateType(Blueprint) {
        const ids = comptime domainCollect(Blueprint);
        var fs: focusStateType(Blueprint) = undefined;
        inline for (ids) |id| {
            @field(fs, id) = @TypeOf(@field(fs, id)).init();
        }
        fs.active_domain = @enumFromInt(0);
        return fs;
    }

    /// Returns the *FocusStack for the currently active domain.
    /// Use this in the activeFocus callback passed to App.run():
    ///
    ///     fn activeFocus(state: *State) *zest.FocusStack {
    ///         return zest.Layout.focusStateActiveFocus(layout, &state.focus);
    ///     }
    pub fn focusStateActiveFocus(
        comptime Blueprint: type,
        fs: *focusStateType(Blueprint),
    ) *FocusStack {
        const ids   = comptime domainCollect(Blueprint);
        const DomId = comptime domainIdType(Blueprint);
        inline for (ids, 0..) |id, i| {
            if (fs.active_domain == @as(DomId, @enumFromInt(i)))
                return &@field(fs, id).stack;
        }
        unreachable;
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
    const hs = @import("../layout/blueprint.zig").vsplit;
    const vs = @import("../layout/blueprint.zig").hsplit;
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

    try std.testing.expectEqual(20, result.a.win.width);
    try std.testing.expectEqual(40, result.a.win.height);
    try std.testing.expectEqual(60, result.b.win.width);
    try std.testing.expectEqual(5,  result.b.win.height);
    try std.testing.expectEqual(60, result.c.win.width);
    try std.testing.expectEqual(35, result.c.win.height);
}

test "Layout.panels: bordered pane is inset by one cell per edge" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").vsplit;
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
    try std.testing.expectEqual(18, result.left.win.width);
    try std.testing.expectEqual(38, result.left.win.height);
    // no-border pane: full size
    try std.testing.expectEqual(60, result.right.win.width);
    try std.testing.expectEqual(40, result.right.win.height);
}

test "PanelsType: flat blueprint produces struct with correct field names" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").vsplit;
    const B = hs(.{
        .children = &.{
            p(.{ .id = "sidebar", .size = .{ .fixed = 20 } }),
            p(.{ .id = "body",    .size = .{ .fraction = 1 } }),
        },
    });
    const W = PanelsType(B);
    try std.testing.expect(@hasField(W, "sidebar"));
    try std.testing.expect(@hasField(W, "body"));
    try std.testing.expectEqual(2, @typeInfo(W).@"struct".fields.len);
}

test "PanelsType: nested blueprint produces one field per leaf pane" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").vsplit;
    const vs = @import("../layout/blueprint.zig").hsplit;
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
    try std.testing.expectEqual(3, @typeInfo(W).@"struct".fields.len);
}

test "Layout.focusablePanelCount: excludes non-focusable panes" {
    const p  = @import("../layout/blueprint.zig").pane;
    const vs = @import("../layout/blueprint.zig").hsplit;
    const B = vs(.{
        .children = &.{
            p(.{ .id = "header", .size = .{ .fixed = 1 }, .focusable = false }),
            p(.{ .id = "a",      .size = .{ .fraction = 1 } }),
            p(.{ .id = "b",      .size = .{ .fraction = 1 } }),
            p(.{ .id = "footer", .size = .{ .fixed = 1 }, .focusable = false }),
        },
    });
    try std.testing.expectEqual(2, Layout.focusablePanelCount(B));
}

test "Layout.panels: non-focusable pane always has focused = false" {
    const p  = @import("../layout/blueprint.zig").pane;
    const vs = @import("../layout/blueprint.zig").hsplit;
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
        @import("../core/focus.zig").Focus.init(Layout.focusablePanelCount(B)),
    );
    const result = Layout.panels(B, root_win, Rect{ .x = 0, .y = 0, .width = 80, .height = 10 }, .{ .focus = &focus });
    try std.testing.expect(!result.chrome.focused);
    try std.testing.expect(result.content.focused);
}

test "Layout.panels: focus index maps to focusable panes only, skipping non-focusable" {
    const p  = @import("../layout/blueprint.zig").pane;
    const vs = @import("../layout/blueprint.zig").hsplit;
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
        @import("../core/focus.zig").Focus.init(Layout.focusablePanelCount(B)),
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
    const hs = @import("../layout/blueprint.zig").vsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/blueprint.zig").Direction;
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

    var fs_sidebar = FocusStack_.init(Focus_.init(Layout.focusablePanelCountInDomain(B, "sidebar")));
    var fs_main    = FocusStack_.init(Focus_.init(Layout.focusablePanelCountInDomain(B, "main")));

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
    const hs = @import("../layout/blueprint.zig").vsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/blueprint.zig").Direction;
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
    var fs_left  = FocusStack_.init(Focus_.init(Layout.focusablePanelCountInDomain(B, "left")));
    var fs_right = FocusStack_.init(Focus_.init(Layout.focusablePanelCountInDomain(B, "right")));
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

test "Layout.panels: blueprint without domains uses ctx.focus for global focus state" {
    const p  = @import("../layout/blueprint.zig").pane;
    const vs = @import("../layout/blueprint.zig").hsplit;
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

    var focus = FocusStack_.init(Focus_.init(Layout.focusablePanelCount(B)));
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

test "Layout.focusablePanelCountInDomain: counts only focusable panes in the named domain" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").vsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/blueprint.zig").Direction;
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
    try std.testing.expectEqual(3, Layout.focusablePanelCountInDomain(B, "sidebar"));
    try std.testing.expectEqual(1, Layout.focusablePanelCountInDomain(B, "main"));
}

test "Layout.focusablePanelCountInDomain: non-focusable panes inside domain are excluded" {
    const p  = @import("../layout/blueprint.zig").pane;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/blueprint.zig").Direction;
    const B = d(.{
        .id        = "col",
        .direction = Direction.vertical,
        .children  = &.{
            p(.{ .id = "a",      .size = .{ .fraction = 1 } }),
            p(.{ .id = "chrome", .size = .{ .fixed = 1 }, .focusable = false }),
            p(.{ .id = "b",      .size = .{ .fraction = 1 } }),
        },
    });
    try std.testing.expectEqual(2, Layout.focusablePanelCountInDomain(B, "col"));
}

test "leafDomains: pane outside any domain gets empty string" {
    const p  = @import("../layout/blueprint.zig").pane;
    const vs = @import("../layout/blueprint.zig").hsplit;
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
    const Direction = @import("../layout/blueprint.zig").Direction;
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
    const vs = @import("../layout/blueprint.zig").hsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/blueprint.zig").Direction;
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
    const Direction = @import("../layout/blueprint.zig").Direction;
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
    const hs = @import("../layout/blueprint.zig").vsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/blueprint.zig").Direction;
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

test "Layout.domainFocusType: set and is use typed panel enum, no integers" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").vsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/blueprint.zig").Direction;
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
                    p(.{ .id = "showcase", .size = .{ .fraction = 1 } }),
                },
            }),
        },
    });
    const SidebarFocus = Layout.domainFocusType(B, "sidebar");
    var sf = SidebarFocus.init();
    try std.testing.expect(sf.is(.files));       // starts at 0 = files
    sf.set(.branches);
    try std.testing.expect(sf.is(.branches));
    try std.testing.expect(!sf.is(.files));

    const MainFocus = Layout.domainFocusType(B, "main");
    var mf = MainFocus.init();
    try std.testing.expect(mf.is(.showcase));
    // Advancing sidebar does not affect main domain.
    sf.set(.files);
    try std.testing.expect(mf.is(.showcase));
}

test "Layout.focusStateType: generates struct with one field per domain" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").vsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/blueprint.zig").Direction;
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
                    p(.{ .id = "showcase", .size = .{ .fraction = 1 } }),
                },
            }),
        },
    });
    const FS = Layout.focusStateType(B);
    try std.testing.expect(@hasField(FS, "sidebar"));
    try std.testing.expect(@hasField(FS, "main"));
    try std.testing.expect(@hasField(FS, "active_domain"));
}

test "Layout.focusStateInit: all domains initialised, first domain active" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").vsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/blueprint.zig").Direction;
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
                    p(.{ .id = "showcase", .size = .{ .fraction = 1 } }),
                },
            }),
        },
    });
    var fs = Layout.focusStateInit(B);
    // First domain (sidebar) is active by default.
    try std.testing.expectEqual(@as(Layout.domainIdType(B), .sidebar), fs.active_domain);
    // Domain stacks start at panel index 0.
    try std.testing.expect(fs.sidebar.is(.files));
    try std.testing.expect(fs.main.is(.showcase));
}

test "Layout.focusStateActiveFocus: returns stack for active domain" {
    const p  = @import("../layout/blueprint.zig").pane;
    const hs = @import("../layout/blueprint.zig").vsplit;
    const d  = @import("../layout/blueprint.zig").domain;
    const Direction = @import("../layout/blueprint.zig").Direction;
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
                    p(.{ .id = "showcase", .size = .{ .fraction = 1 } }),
                },
            }),
        },
    });
    var fs = Layout.focusStateInit(B);
    // Starts on sidebar: activeFocus returns &fs.sidebar.stack.
    try std.testing.expectEqual(&fs.sidebar.stack, Layout.focusStateActiveFocus(B, &fs));
    // Switch to main: activeFocus returns &fs.main.stack.
    fs.active_domain = .main;
    try std.testing.expectEqual(&fs.main.stack, Layout.focusStateActiveFocus(B, &fs));
}
