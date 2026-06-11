//! Lazygit-style demo — two blueprints, two FocusStacks.
//!
//! The outer blueprint defines coarse geometry: sidebar column (25 cols),
//! main column (remainder), footer strip (1 row). Two inner blueprints fill
//! each column. Two FocusStacks — one per column — keep Tab within its own
//! column; focus never leaks across the boundary.
//!
//! This is the Option B design: layout boundary = focus boundary. Tab cycles
//! only within the active stack. Pressing 1–4 activates the sidebar stack;
//! pressing 0 activates the main-area stack. Option C (domain() constructor)
//! will fold both calls back into one while preserving this isolation.

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

// Outer blueprint — coarse geometry only. All panes non-focusable: this
// level owns no focus of its own; the inner blueprints handle that.
const outer_layout = zest.vsplit(.{
    .children = &.{
        zest.hsplit(.{
            .size     = .{ .fraction = 1 },
            .children = &.{
                zest.pane(.{ .id = "sidebar", .size = .{ .fixed = 25 },    .focusable = false }),
                zest.pane(.{ .id = "main",    .size = .{ .fraction = 1 }, .focusable = false }),
            },
        }),
        zest.pane(.{ .id = "footer", .size = .{ .fixed = 1 }, .focusable = false }),
    },
});

// Sidebar blueprint — four stacked focusable panels.
const sidebar_layout = zest.vsplit(.{
    .children = &.{
        zest.pane(.{ .id = "files",    .size = .{ .fraction = 1 }, .border = true }),
        zest.pane(.{ .id = "branches", .size = .{ .fraction = 1 }, .border = true }),
        zest.pane(.{ .id = "commits",  .size = .{ .fraction = 1 }, .border = true }),
        zest.pane(.{ .id = "stash",    .size = .{ .fraction = 1 }, .border = true }),
    },
});

// Main-area blueprint — diff pane above, non-focusable command log below.
const main_layout = zest.vsplit(.{
    .children = &.{
        zest.pane(.{ .id = "diff",   .size = .{ .fraction = 1 }, .border = true }),
        zest.pane(.{ .id = "cmdlog", .size = .{ .fixed = 5 },    .border = true, .focusable = false }),
    },
});

// Focusable indices within each stack (depth-first, non-focusable excluded).
const sidebar_files    = 0;
const sidebar_branches = 1;
const sidebar_commits  = 2;
const sidebar_stash    = 3;
const main_diff        = 0;

const State = struct {
    focus_sidebar: zest.FocusStack,
    focus_main:    zest.FocusStack,
    active_focus:  *zest.FocusStack,
};

fn panelLabel(alloc: std.mem.Allocator, name: []const u8, focused: bool) []const u8 {
    if (focused) return std.fmt.allocPrint(alloc, "{s} [*]", .{name}) catch name;
    return name;
}

fn draw(state: *State, win: vaxis.Window, alloc: std.mem.Allocator) zest.UpdateResult {
    win.clear();

    const outer = zest.Layout.panels(outer_layout, win,
        .{ .x = 0, .y = 0, .width = win.width, .height = win.height }, .{});

    const sb = zest.Layout.panels(sidebar_layout, outer.sidebar.win,
        .{ .x = 0, .y = 0, .width = outer.sidebar.win.width, .height = outer.sidebar.win.height },
        .{ .focus = &state.focus_sidebar });

    const mn = zest.Layout.panels(main_layout, outer.main.win,
        .{ .x = 0, .y = 0, .width = outer.main.win.width, .height = outer.main.win.height },
        .{ .focus = &state.focus_main });

    _ = sb.files   .win.print(&.{.{ .text = panelLabel(alloc, "1 files",    sb.files.focused)    }}, .{});
    _ = sb.branches.win.print(&.{.{ .text = panelLabel(alloc, "2 branches", sb.branches.focused) }}, .{});
    _ = sb.commits .win.print(&.{.{ .text = panelLabel(alloc, "3 commits",  sb.commits.focused)  }}, .{});
    _ = sb.stash   .win.print(&.{.{ .text = panelLabel(alloc, "4 stash",    sb.stash.focused)    }}, .{});
    _ = mn.diff    .win.print(&.{.{ .text = panelLabel(alloc, "0 diff",     mn.diff.focused)     }}, .{});
    _ = mn.cmdlog  .win.print(&.{.{ .text = "command log" }}, .{});
    _ = outer.footer.win.print(&.{.{ .text = "tab: cycle  0–4: jump  q: quit" }}, .{});

    return .redraw;
}

fn update(state: *State, event: zest.Event, win: vaxis.Window, alloc: std.mem.Allocator) zest.UpdateResult {
    switch (event) {
        .key_press => |key| {
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
            switch (key.codepoint) {
                '0' => {
                    state.active_focus = &state.focus_main;
                    state.focus_main.set(main_diff);
                },
                '1'...'4' => |ch| {
                    state.active_focus = &state.focus_sidebar;
                    state.focus_sidebar.set(@intCast(ch - '1'));
                },
                else => return .idle,
            }
            return draw(state, win, alloc);
        },
        .winsize, .focus_changed => return draw(state, win, alloc),
        else => return .idle,
    }
}

pub fn main(init: std.process.Init) !void {
    var tty_buf: [4096]u8 = undefined;
    var app = try zest.App.init(init.io, init.gpa, init.environ_map, &tty_buf);
    defer app.deinit();

    var state: State = undefined;
    state.focus_sidebar = zest.FocusStack.init(zest.Focus.init(zest.Layout.panelCount(sidebar_layout)));
    state.focus_main    = zest.FocusStack.init(zest.Focus.init(zest.Layout.panelCount(main_layout)));
    state.active_focus  = &state.focus_sidebar;

    try app.run(&state, &state.active_focus, update);
}
