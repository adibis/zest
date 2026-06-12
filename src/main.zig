//! Zest framework demo — two focus domains, scrollable list, custom theme.
//!
//! The sidebar (four panels, Tab-cycled) uses zest's built-in dark theme.
//! The showcase panel uses a separate DiffColor enum and diff theme —
//! two Theme(C) instances coexisting in one draw() call, no global state.
//!
//! Tab: cycle within active domain   Ctrl-W: switch domain
//! j/k or arrows: navigate list      0-4: jump to panel    q: quit

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

// --- Layout ------------------------------------------------------------------

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
                        zest.pane(.{ .id = "showcase", .size = .{ .fraction = 1 } }),
                        zest.pane(.{ .id = "log",      .size = .{ .fixed = 5 }, .border = true, .focusable = false }),
                    },
                }),
            },
        }),
        zest.pane(.{ .id = "footer", .size = .{ .fixed = 1 }, .focusable = false }),
    },
});

const sidebar_files    = 0;
const sidebar_branches = 1;
const sidebar_commits  = 2;
const sidebar_stash    = 3;
const main_showcase    = 0;

// --- Default (dark) theme ----------------------------------------------------

const dark = zest.dark;

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

// --- Diff theme (showcase panel only) ----------------------------------------
//
// DiffColor is a domain-specific token enum — nothing in the framework knows
// about it. diff_theme is a Theme(DiffColor) that lives only in this file.
// This demonstrates that two Theme(C) instances can coexist in one draw().

const DiffColor = enum {
    default,
    chrome,   // dim — secondary text, context lines, stat chrome
    label,    // bright green — filenames, hashes, section headers
    added,    // green — added lines and insertion counts
    removed,  // red — removed lines and deletion counts
    meta,     // amber — summary lines, counts
};

// Indexed palette: renders correctly on every terminal, including Terminal.app.
const diff_theme: zest.Theme(DiffColor) = .{
    .colors = std.EnumArray(DiffColor, vaxis.Color).init(.{
        .default = .default,
        .chrome  = .{ .index = 10 },
        .label   = .{ .index = 2  },
        .added   = .{ .index = 2  },
        .removed = .{ .index = 9  },
        .meta    = .{ .index = 3  },
    }),
};

const DS = zest.Style(DiffColor);

fn ds(fg: ?DiffColor) vaxis.Cell.Style {
    return diff_theme.resolve(DS{ .fg = fg });
}
fn dsb(fg: ?DiffColor) vaxis.Cell.Style {
    return diff_theme.resolve(DS{ .fg = fg, .text = .{ .bold = true } });
}

// --- State -------------------------------------------------------------------

const State = struct {
    focus_sidebar: zest.FocusStack,
    focus_main:    zest.FocusStack,
    active_focus:  *zest.FocusStack,
    files_list:    zest.DefaultList,
};

// --- Draw --------------------------------------------------------------------

fn drawShowcase(win: vaxis.Window, focused: bool, selected_file: []const u8) void {
    const border_style = if (focused)
        dark.resolve(zest.DefaultStyle{ .fg = .primary })
    else
        dark.resolve(zest.DefaultStyle{});
    const inner = win.child(.{ .border = .{ .where = .all, .style = border_style } });
    if (inner.height == 0) return;

    // Title row — sidebar selection shown in default theme
    _ = inner.print(&.{
        .{ .text = if (focused) "showcase [*]  " else "showcase      ",
           .style = dark.resolve(zest.DefaultStyle{ .fg = .primary, .text = .{ .bold = true } }) },
        .{ .text = selected_file,
           .style = dark.resolve(zest.DefaultStyle{ .fg = .muted }) },
    }, .{ .row_offset = 0 });

    if (inner.height < 3) return;

    // Subtitle — identifies what Theme(C) is doing here
    _ = inner.print(&.{.{
        .text = "─── Theme(DiffColor) — indexed palette, works on all terminals ─────────────────────",
        .style = ds(.chrome),
    }}, .{ .row_offset = 1 });

    var row: u16 = 2;

    // Recent commit log
    _ = inner.print(&.{.{ .text = "─── git log --oneline ──────────────────────────────────────────────────────────────────", .style = ds(.chrome) }}, .{ .row_offset = row }); row += 1;
    const commits = [_]struct { hash: []const u8, msg: []const u8 }{
        .{ .hash = "fa32d37", .msg = "  Make List(C) generic, storing widget color bindings on the widget" },
        .{ .hash = "3022e22", .msg = "  Add WidgetTheme(C) for per-widget color role configuration" },
        .{ .hash = "540051b", .msg = "  Make Theme and Style generic over a user-supplied color enum" },
        .{ .hash = "b48f941", .msg = "  Decouple list widget tests from theme palette values" },
    };
    for (commits) |c| {
        _ = inner.print(&.{
            .{ .text = c.hash, .style = dsb(.label) },
            .{ .text = c.msg,  .style = ds(.chrome) },
        }, .{ .row_offset = row }); row += 1;
    }
    row += 1;

    // Diff stat bars
    _ = inner.print(&.{.{ .text = "─── git diff --stat fa32d37 ────────────────────────────────────────────────────────────", .style = ds(.chrome) }}, .{ .row_offset = row }); row += 1;

    const stats = [_]struct { file: []const u8, n: []const u8, add: []const u8, del: []const u8 }{
        .{ .file = " src/widgets/list.zig  ", .n = "142 ", .add = "++++++++++++++++++++++++++++++++", .del = "────────────────────────" },
        .{ .file = " src/root.zig          ", .n = "  8 ", .add = "+++++++",                          .del = "─" },
        .{ .file = " src/main.zig          ", .n = " 58 ", .add = "+++++++++++++++++++++++++++",      .del = "──────────────────" },
    };
    for (stats) |s| {
        _ = inner.print(&.{
            .{ .text = s.file, .style = dsb(.label)   },
            .{ .text = "│ ",   .style = ds(.chrome)   },
            .{ .text = s.n,    .style = ds(.chrome)   },
            .{ .text = s.add,  .style = ds(.added)    },
            .{ .text = s.del,  .style = ds(.removed)  },
        }, .{ .row_offset = row }); row += 1;
    }
    _ = inner.print(&.{.{
        .text = " 3 files changed, 208 insertions(+), 98 deletions(-)",
        .style = ds(.meta),
    }}, .{ .row_offset = row }); row += 1;
    row += 1;

    // Code diff snippet — the actual Theme(C) refactor
    _ = inner.print(&.{.{ .text = "─── src/core/theme.zig ─────────────────────────────────────────────────────────────────", .style = ds(.chrome) }}, .{ .row_offset = row }); row += 1;

    const diff_lines = [_]struct { prefix: []const u8, code: []const u8, color: DiffColor }{
        .{ .prefix = "  ", .code = " pub const Style = struct {",                       .color = .chrome  },
        .{ .prefix = "- ", .code = "     fg:   Color     = .default,",                 .color = .removed },
        .{ .prefix = "- ", .code = "     bg:   Color     = .default,",                 .color = .removed },
        .{ .prefix = "  ", .code = "     text: TextStyle = .{},",                      .color = .chrome  },
        .{ .prefix = "  ", .code = " };",                                               .color = .chrome  },
        .{ .prefix = "+ ", .code = " pub fn Style(comptime C: type) type {",           .color = .added   },
        .{ .prefix = "+ ", .code = "     return struct {",                             .color = .added   },
        .{ .prefix = "+ ", .code = "         fg:   ?C        = null,",                 .color = .added   },
        .{ .prefix = "+ ", .code = "         bg:   ?C        = null,",                 .color = .added   },
        .{ .prefix = "+ ", .code = "         text: TextStyle = .{},",                  .color = .added   },
        .{ .prefix = "+ ", .code = "     };",                                          .color = .added   },
        .{ .prefix = "+ ", .code = " }",                                               .color = .added   },
    };
    for (diff_lines) |l| {
        _ = inner.print(&.{
            .{ .text = l.prefix, .style = dsb(l.color) },
            .{ .text = l.code,   .style = ds(l.color)  },
        }, .{ .row_offset = row }); row += 1;
        if (row >= inner.height) break;
    }
}

fn draw(state: *State, win: vaxis.Window) zest.UpdateResult {
    win.clear();

    const sidebar_focus: ?*zest.FocusStack = if (state.active_focus == &state.focus_sidebar) &state.focus_sidebar else null;
    const main_focus:    ?*zest.FocusStack = if (state.active_focus == &state.focus_main)    &state.focus_main    else null;
    const p = zest.Layout.panels(layout, win,
        .{ .x = 0, .y = 0, .width = win.width, .height = win.height },
        .{ .sidebar = sidebar_focus, .main = main_focus });

    zest.Text.draw(p.header.win, "zest demo", zest.DefaultStyle{ .fg = .secondary, .text = .{ .bold = true } }, dark);

    const focus_style = zest.DefaultStyle{ .fg = .primary, .text = .{ .bold = true } };
    zest.Text.draw(p.files.win,    if (p.files.focused)    "1 files [*]"    else "1 files",    if (p.files.focused)    focus_style else zest.DefaultStyle{}, dark);
    zest.Text.draw(p.branches.win, if (p.branches.focused) "2 branches [*]" else "2 branches", if (p.branches.focused) focus_style else zest.DefaultStyle{}, dark);
    zest.Text.draw(p.commits.win,  if (p.commits.focused)  "3 commits [*]"  else "3 commits",  if (p.commits.focused)  focus_style else zest.DefaultStyle{}, dark);
    zest.Text.draw(p.stash.win,    if (p.stash.focused)    "4 stash [*]"    else "4 stash",    if (p.stash.focused)    focus_style else zest.DefaultStyle{}, dark);

    const list_win = p.files.win.child(.{ .y_off = 1, .height = p.files.win.height -| 1 });
    state.files_list.draw(list_win, &files_items, p.files.focused, dark);

    drawShowcase(p.showcase.win, p.showcase.focused, files_items[state.files_list.selected]);

    zest.Text.draw(p.log.win, "log", zest.DefaultStyle{ .fg = .muted }, dark);
    zest.Text.draw(p.footer.win,
        "tab: cycle  j/k: navigate  ^W: switch  0-4: jump  q: quit",
        zest.DefaultStyle{ .fg = .muted }, dark);

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
                    state.focus_main.set(main_showcase);
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
    state.files_list    = .{ .widget_theme = zest.dark_widget };

    try app.run(&state, &state.active_focus, update);
}
