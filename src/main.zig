//! Lazygit-style demo — single blueprint with two focus domains.
//!
//! One comptime tree covers the entire screen. Two domain() nodes mark focus
//! boundaries: "sidebar" owns the four left panels; "main" owns the diff pane
//! and the non-focusable command log. One Layout.panels() call resolves
//! everything. Two FocusStacks — one per domain — keep Tab within its column.
//!
//! The "files" panel renders a scrollable List; j/k navigate it when it is
//! focused. All text uses the semantic theme API (Text.draw + Theme.dark).

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

const layout = zest.vsplit(.{
    .children = &.{
        zest.pane(.{ .id = "header", .size = .{ .fixed = 3 }, .border = true, .focusable = false }),
        zest.hsplit(.{
            .size     = .{ .fraction = 1 },
            .children = &.{
                zest.domain(.{
                    .id        = "sidebar",
                    .direction = zest.Direction.vertical,
                    .size      = .{ .percent = 25 },
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
                        zest.pane(.{ .id = "diff",   .size = .{ .fraction = 1 } }),
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

const theme = zest.Theme.dark;

const files_items = [_][]const u8{
    "src/main.zig",
    "src/core/app.zig",
    "src/core/focus.zig",
    "src/core/memory.zig",
    "src/core/theme.zig",
    "src/layout/blueprint.zig",
    "src/layout/rect.zig",
    "src/layout/size.zig",
    "src/layout/slot.zig",
    "src/layout/solver.zig",
    "src/widgets/box.zig",
    "src/widgets/list.zig",
    "src/widgets/text.zig",
};

const State = struct {
    focus_sidebar: zest.FocusStack,
    focus_main:    zest.FocusStack,
    active_focus:  *zest.FocusStack,
    files_list:    zest.List,
};

fn draw(state: *State, win: vaxis.Window) zest.UpdateResult {
    win.clear();

    const sidebar_focus: ?*zest.FocusStack = if (state.active_focus == &state.focus_sidebar) &state.focus_sidebar else null;
    const main_focus:    ?*zest.FocusStack = if (state.active_focus == &state.focus_main)    &state.focus_main    else null;
    const p = zest.Layout.panels(layout, win,
        .{ .x = 0, .y = 0, .width = win.width, .height = win.height },
        .{ .sidebar = sidebar_focus, .main = main_focus });

    zest.Text.draw(p.header.win, "zest demo", .{ .fg = .secondary, .text = .{ .bold = true } }, theme);

    // Each panel shows a label at row 0, "[*]" appended when focused.
    const files_label    = if (p.files.focused)    "1 files [*]"    else "1 files";
    const branches_label = if (p.branches.focused) "2 branches [*]" else "2 branches";
    const commits_label  = if (p.commits.focused)  "3 commits [*]"  else "3 commits";
    const stash_label    = if (p.stash.focused)    "4 stash [*]"    else "4 stash";
    const diff_label     = if (p.diff.focused)     "0 diff [*]"     else "0 diff";
    const focus_style    = zest.Style{ .fg = .primary, .text = .{ .bold = true } };

    zest.Text.draw(p.files.win,    files_label,    if (p.files.focused)    focus_style else .{}, theme);
    zest.Text.draw(p.branches.win, branches_label, if (p.branches.focused) focus_style else .{}, theme);
    zest.Text.draw(p.commits.win,  commits_label,  if (p.commits.focused)  focus_style else .{}, theme);
    zest.Text.draw(p.stash.win,    stash_label,    if (p.stash.focused)    focus_style else .{}, theme);
    // Diff pane: draw a blue border manually (pane has border=false so we control the color).
    const diff_inner = p.diff.win.child(.{
        .border = .{ .where = .all, .style = theme.resolve(.{ .fg = .primary }) },
    });
    zest.Text.draw(diff_inner, diff_label, if (p.diff.focused) focus_style else .{}, theme);
    const diff_body = diff_inner.child(.{ .y_off = 1, .height = diff_inner.height -| 1 });
    zest.Text.draw(diff_body, files_items[state.files_list.selected], .{}, theme);

    // Files list: render below the label row.
    const list_win = p.files.win.child(.{ .y_off = 1, .height = p.files.win.height -| 1 });
    state.files_list.draw(list_win, &files_items, p.files.focused, theme);

    zest.Text.draw(p.cmdlog.win, "command log", .{ .fg = .muted }, theme);
    zest.Text.draw(p.footer.win,
        "tab: cycle  j/k: navigate  ^W: switch  0-4: jump  q: quit  sidebar: 25%",
        .{ .fg = .muted }, theme);

    return .redraw;
}

fn update(state: *State, event: zest.Event, win: vaxis.Window, alloc: std.mem.Allocator) zest.UpdateResult {
    _ = alloc;
    switch (event) {
        .key_press => |key| {
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
            if (key.matches('w', .{ .ctrl = true })) {
                state.active_focus = if (state.active_focus == &state.focus_sidebar)
                    &state.focus_main
                else
                    &state.focus_sidebar;
                return draw(state, win);
            }
            if (key.matches(vaxis.Key.tab, .{})) {
                state.active_focus.top().next();
                return draw(state, win);
            }
            switch (key.codepoint) {
                'j', 'k', vaxis.Key.down, vaxis.Key.up => {
                    if (state.active_focus == &state.focus_sidebar and
                        state.focus_sidebar.activeIndex() == sidebar_files)
                    {
                        state.files_list.handleKey(key, files_items.len);
                    }
                    return draw(state, win);
                },
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
            return draw(state, win);
        },
        .winsize, .focus_changed => return draw(state, win),
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
    state.files_list    = .{};

    try app.run(&state, &state.active_focus, update);
}
