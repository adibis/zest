//! Lazygit-style demo — single blueprint with two focus domains.
//!
//! One comptime tree covers the entire screen. Two domain() nodes mark focus
//! boundaries: "sidebar" owns the four left panels; "main" owns the diff pane
//! and the non-focusable command log. One Layout.panels() call resolves
//! everything. Two FocusStacks — one per domain — keep Tab within its column.
//!
//! This is the Option C design: layout boundary and focus boundary are both
//! declared in the same blueprint. The previous three-blueprint approach
//! required manual geometry math; domain() makes the schema the single source
//! of truth for both geometry and focus topology.

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

const layout = zest.vsplit(.{
    .children = &.{
        zest.hsplit(.{
            .size     = .{ .fraction = 1 },
            .children = &.{
                zest.domain(.{
                    .id        = "sidebar",
                    .direction = zest.Direction.vertical,
                    .size      = .{ .fixed = 25 },
                    .children  = &.{
                        zest.pane(.{ .id = "files",    .size = .{ .fraction = 1 }, .border = true }),
                        zest.pane(.{ .id = "branches", .size = .{ .fraction = 1 }, .border = true }),
                        zest.pane(.{ .id = "commits",  .size = .{ .fraction = 1 }, .border = true }),
                        zest.pane(.{ .id = "stash",    .size = .{ .fraction = 1 }, .border = true }),
                    },
                }),
                zest.domain(.{
                    .id        = "main",
                    .direction = zest.Direction.vertical,
                    .size      = .{ .fraction = 1 },
                    .children  = &.{
                        zest.pane(.{ .id = "diff",   .size = .{ .fraction = 1 }, .border = true }),
                        zest.pane(.{ .id = "cmdlog", .size = .{ .fixed = 5 },    .border = true, .focusable = false }),
                    },
                }),
            },
        }),
        zest.pane(.{ .id = "footer", .size = .{ .fixed = 1 }, .focusable = false }),
    },
});

// Focusable indices within each domain (depth-first, non-focusable excluded).
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

    const p = zest.Layout.panels(layout, win,
        .{ .x = 0, .y = 0, .width = win.width, .height = win.height },
        .{ .sidebar = &state.focus_sidebar, .main = &state.focus_main });

    _ = p.files   .win.print(&.{.{ .text = panelLabel(alloc, "1 files",    p.files.focused)    }}, .{});
    _ = p.branches.win.print(&.{.{ .text = panelLabel(alloc, "2 branches", p.branches.focused) }}, .{});
    _ = p.commits .win.print(&.{.{ .text = panelLabel(alloc, "3 commits",  p.commits.focused)  }}, .{});
    _ = p.stash   .win.print(&.{.{ .text = panelLabel(alloc, "4 stash",    p.stash.focused)    }}, .{});
    _ = p.diff    .win.print(&.{.{ .text = panelLabel(alloc, "0 diff",     p.diff.focused)     }}, .{});
    _ = p.cmdlog  .win.print(&.{.{ .text = "command log" }}, .{});
    _ = p.footer  .win.print(&.{.{ .text = "tab: cycle  0–4: jump  q: quit" }}, .{});

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
    state.focus_sidebar = zest.FocusStack.init(zest.Focus.init(zest.Layout.panelCountInDomain(layout, "sidebar")));
    state.focus_main    = zest.FocusStack.init(zest.Focus.init(zest.Layout.panelCountInDomain(layout, "main")));
    state.active_focus  = &state.focus_sidebar;

    try app.run(&state, &state.active_focus, update);
}
