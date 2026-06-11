//! Lazygit-style demo for zest.
//!
//! Panels 1–4 (files/branches/commits/stash) form the repo sidebar — one layout
//! with its own FocusStack. Tab cycles through them; 1–4 jump directly.
//!
//! The diff view (panel 0) is a separate layout with its own FocusStack. Press 0
//! to shift focus there. Because it lives in a different layout, Tab never crosses
//! into it — the layout boundary is the focus boundary.
//!
//! Command log and footer are passed null focus: they are display-only regions
//! that can never be interactive, with no special pane flags needed.

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

// Left sidebar: repo panels 1–4, stacked vertically.
const layout_repo = zest.vsplit(.{
    .children = &.{
        zest.pane(.{ .id = "files",    .size = .{ .fraction = 1 }, .border = true }),
        zest.pane(.{ .id = "branches", .size = .{ .fraction = 1 }, .border = true }),
        zest.pane(.{ .id = "commits",  .size = .{ .fraction = 1 }, .border = true }),
        zest.pane(.{ .id = "stash",    .size = .{ .fraction = 1 }, .border = true }),
    },
});

// Right panel: diff view (panel 0). Separate layout so Tab never reaches it.
const layout_diff = zest.pane(.{ .id = "diff", .size = .{ .fraction = 1 }, .border = true });

// Bottom areas: display only. Passed null focus at render time — never interactive.
const layout_cmdlog = zest.pane(.{ .id = "log",    .size = .{ .fixed = 5 }, .border = true });
const layout_footer = zest.pane(.{ .id = "footer", .size = .{ .fixed = 1 } });

const ActiveWindow = enum { repo, diff };

const State = struct {
    focus_repo:   zest.FocusStack,
    focus_diff:   zest.FocusStack,
    active:       ActiveWindow,
    active_focus: *zest.FocusStack,
};

fn panelLabel(alloc: std.mem.Allocator, name: []const u8, focused: bool, window_active: bool) []const u8 {
    if (focused)        return std.fmt.allocPrint(alloc, "{s} [*]", .{name}) catch name;
    if (!window_active) return std.fmt.allocPrint(alloc, "{s} [-]", .{name}) catch name;
    return name;
}

fn draw(state: *State, win: vaxis.Window, alloc: std.mem.Allocator) zest.UpdateResult {
    win.clear();

    const sidebar_w: u16 = 25;
    const cmdlog_h:  u16 = 5;
    const footer_h:  u16 = 1;
    const col_h:     u16 = win.height -| footer_h;       // sidebar + right column height
    const diff_h:    u16 = col_h      -| cmdlog_h;       // diff sits above cmdlog
    const diff_x:    u16 = sidebar_w;
    const diff_w:    u16 = win.width  -| sidebar_w;

    const repo_active = state.active == .repo;

    // Sidebar spans the full column height — cmdlog does not push it down.
    const repo = zest.Layout.panels(layout_repo, win,
        .{ .x = 0,      .y = 0,      .width = sidebar_w, .height = col_h  },
        .{ .focus = if (repo_active) &state.focus_repo else null });

    const diff = zest.Layout.panels(layout_diff, win,
        .{ .x = diff_x, .y = 0,      .width = diff_w,    .height = diff_h },
        .{ .focus = if (!repo_active) &state.focus_diff else null });

    // Cmdlog lives in the right column, below diff.
    const cmd = zest.Layout.panels(layout_cmdlog, win,
        .{ .x = diff_x, .y = diff_h, .width = diff_w,    .height = cmdlog_h },
        .{ .focus = null });

    const ftr = zest.Layout.panels(layout_footer, win,
        .{ .x = 0, .y = col_h, .width = win.width, .height = footer_h },
        .{ .focus = null });

    _ = repo.files   .win.print(&.{.{ .text = panelLabel(alloc, "1 files",    repo.files.focused,    repo_active) }}, .{});
    _ = repo.branches.win.print(&.{.{ .text = panelLabel(alloc, "2 branches", repo.branches.focused, repo_active) }}, .{});
    _ = repo.commits .win.print(&.{.{ .text = panelLabel(alloc, "3 commits",  repo.commits.focused,  repo_active) }}, .{});
    _ = repo.stash   .win.print(&.{.{ .text = panelLabel(alloc, "4 stash",    repo.stash.focused,    repo_active) }}, .{});

    _ = diff.diff.win.print(&.{.{ .text = panelLabel(alloc, "0 diff", diff.diff.focused, !repo_active) }}, .{});

    _ = cmd.log   .win.print(&.{.{ .text = "command log" }}, .{});
    _ = ftr.footer.win.print(&.{.{ .text = "tab: cycle  1-4: jump  0: diff  q: quit" }}, .{});

    return .redraw;
}

fn focusWindow(state: *State, active: ActiveWindow, repo_slot: ?usize) void {
    state.active = active;
    state.active_focus = switch (active) {
        .repo => blk: {
            if (repo_slot) |s| state.focus_repo.set(s);
            break :blk &state.focus_repo;
        },
        .diff => &state.focus_diff,
    };
}

fn update(state: *State, event: zest.Event, win: vaxis.Window, alloc: std.mem.Allocator) zest.UpdateResult {
    switch (event) {
        .key_press => |key| {
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
            switch (key.codepoint) {
                '0'       => focusWindow(state, .diff, null),
                '1'...'4' => |ch| focusWindow(state, .repo, @intCast(ch - '1')),
                else      => return .idle,
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
    state.focus_repo  = zest.FocusStack.init(zest.Focus.init(zest.Layout.panelCount(layout_repo)));
    state.focus_diff  = zest.FocusStack.init(zest.Focus.init(zest.Layout.panelCount(layout_diff)));
    state.active       = .repo;
    state.active_focus = &state.focus_repo;

    try app.run(&state, &state.active_focus, update);
}
