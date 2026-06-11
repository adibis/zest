//! Lazygit-style demo — single nested blueprint.
//!
//! The entire screen is one comptime blueprint tree: sidebar panels 1–4 on the
//! left, diff view on the right with command log below it, footer at the bottom.
//! One Layout.panels() call resolves everything. One FocusStack owns all five
//! focusable panes; Tab cycles through them. Non-focusable panes (cmdlog,
//! footer) are declared in the blueprint and are automatically excluded from the
//! focus ring — no null-focus plumbing needed.
//!
//! Tab crosses from sidebar into diff because they share one FocusStack. Domain
//! separation (Tab only within sidebar, 0 jumps to diff without Tab reaching it)
//! requires Option C — the domain() constructor described in the plan.

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

const layout = zest.vsplit(.{
    .children = &.{
        zest.hsplit(.{
            .size     = .{ .fraction = 1 },
            .children = &.{
                zest.vsplit(.{
                    .size     = .{ .fixed = 25 },
                    .children = &.{
                        zest.pane(.{ .id = "files",    .size = .{ .fraction = 1 }, .border = true }),
                        zest.pane(.{ .id = "branches", .size = .{ .fraction = 1 }, .border = true }),
                        zest.pane(.{ .id = "commits",  .size = .{ .fraction = 1 }, .border = true }),
                        zest.pane(.{ .id = "stash",    .size = .{ .fraction = 1 }, .border = true }),
                    },
                }),
                zest.vsplit(.{
                    .size     = .{ .fraction = 1 },
                    .children = &.{
                        zest.pane(.{ .id = "diff",   .size = .{ .fraction = 1 }, .border = true }),
                        zest.pane(.{ .id = "cmdlog", .size = .{ .fixed = 5 },    .border = true, .focusable = false }),
                    },
                }),
            },
        }),
        zest.pane(.{ .id = "footer", .size = .{ .fixed = 1 }, .focusable = false }),
    },
});

// Focusable panel indices in depth-first order (non-focusable excluded).
const idx_files    = 0;
const idx_branches = 1;
const idx_commits  = 2;
const idx_stash    = 3;
const idx_diff     = 4;

const State = struct {
    focus:        zest.FocusStack,
    active_focus: *zest.FocusStack,
};

fn panelLabel(alloc: std.mem.Allocator, name: []const u8, focused: bool) []const u8 {
    if (focused) return std.fmt.allocPrint(alloc, "{s} [*]", .{name}) catch name;
    return name;
}

fn draw(state: *State, win: vaxis.Window, alloc: std.mem.Allocator) zest.UpdateResult {
    win.clear();

    const p = zest.Layout.panels(layout, win,
        .{ .x = 0, .y = 0, .width = win.width, .height = win.height },
        .{ .focus = &state.focus });

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
                '0'       => state.focus.set(idx_diff),
                '1'...'4' => |ch| state.focus.set(@intCast(ch - '1')),
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
    state.focus        = zest.FocusStack.init(zest.Focus.init(zest.Layout.panelCount(layout)));
    state.active_focus = &state.focus;

    try app.run(&state, &state.active_focus, update);
}
