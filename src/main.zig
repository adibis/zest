//! Zest framework demo — two focus domains, scrollable list, custom theme.
//!
//! The sidebar uses the built-in Catppuccin palette (Mocha/Latte selected at
//! runtime from the terminal's reported color scheme). The showcase panel uses
//! a separate DiffColor enum and diff theme — two Theme(C) instances coexisting
//! in one draw() call, no global state.
//!
//! Tab: cycle within active domain   Ctrl-W: switch domain
//! j/k or arrows: navigate list      0-4: jump to panel    q: quit

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

// --- Layout ------------------------------------------------------------------

const layout = zest.hsplit(.{
    .children = &.{
        zest.pane(.{ .id = "header", .size = .{ .fixed = 1 }, .focusable = false }),
        zest.vsplit(.{
            .size     = .{ .fraction = 1 },
            .children = &.{
                zest.domain(.{
                    .id        = "sidebar",
                    .direction = zest.Direction.vertical,
                    .size      = .{ .percent = 25 },
                    .children  = &.{
                        zest.pane(.{ .id = "files",    .size = .{ .fraction = 1 } }),
                        zest.pane(.{ .id = "branches", .size = .{ .fraction = 1 } }),
                        zest.pane(.{ .id = "commits",  .size = .{ .fraction = 1 } }),
                        zest.pane(.{ .id = "stash",    .size = .{ .fraction = 1 } }),
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

const FocusState = zest.Layout.FocusStateType(layout);

const files_items = [_][]const u8{
    "src/main.zig",
    "src/core/app.zig",
    "src/core/focus.zig",
    "src/core/memory.zig",
    "src/core/theme.zig",
    "src/layout/blueprint.zig",
    "src/layout/rect.zig",
    "src/layout/size.zig",
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
        .chrome  = .default,
        .label   = .{ .index = 2  },
        .added   = .{ .index = 2  },
        .removed = .{ .index = 9  },
        .meta    = .{ .index = 3  },
    }),
};

// diffStyle / diffStyleBold take a bg so every cell drawn inside the
// showcase panel sits on the same chrome lift — without it, each text
// write would punch through the panel's filled background with its own
// terminal-default bg.
fn diffStyle(fg: ?DiffColor, bg: vaxis.Color) vaxis.Cell.Style {
    var s = diff_theme.resolve(zest.Style(DiffColor){ .fg = fg });
    s.bg = bg;
    return s;
}
fn diffStyleBold(fg: ?DiffColor, bg: vaxis.Color) vaxis.Cell.Style {
    var s = diff_theme.resolve(zest.Style(DiffColor){ .fg = fg, .text = .{ .bold = true } });
    s.bg = bg;
    return s;
}

// --- State -------------------------------------------------------------------

const State = struct {
    focus:        FocusState,
    files_list:   zest.DefaultList,
    color_scheme: vaxis.Color.Scheme,
};

fn activeFocus(state: *State) *zest.FocusStack {
    return zest.Layout.focusStateActiveFocus(layout, &state.focus);
}

// --- Draw --------------------------------------------------------------------

fn drawShowcase(win: vaxis.Window, focused: bool, selected_file: []const u8, theme: zest.DefaultTheme) void {
    // Chrome lift for the diff panel — content inside the border sits on
    // a slightly raised surface. The border itself keeps the shared
    // focus-driven fg style with no bg override, so the outline reads
    // as a distinct stroke around the lifted content rather than as
    // part of the colored area.
    const lift: zest.Color = .color_0;
    const lift_resolved = theme.resolve(zest.DefaultStyle{ .bg = lift }).bg;

    const inner = win.child(.{
        .border = .{ .where = .all, .style = theme.resolve(border_styles.pick(focused)) },
    });
    if (inner.height == 0) return;

    inner.fill(.{
        .char  = .{ .grapheme = " ", .width = 1 },
        .style = theme.resolve(zest.DefaultStyle{ .bg = lift }),
    });

    // Title row — bold accent on the showcase label, muted file name beside it.
    _ = inner.print(&.{
        .{ .text = "showcase  ",
           .style = theme.resolve(zest.DefaultStyle{
               .fg   = if (focused) .color_4 else null,
               .bg   = lift,
               .text = .{ .bold = focused },
           }) },
        .{ .text = selected_file,
           .style = theme.resolve(zest.DefaultStyle{ .fg = .color_7, .bg = lift }) },
    }, .{ .row_offset = 0 });

    if (inner.height < 3) return;

    // Subtitle — identifies what Theme(C) is doing here
    _ = inner.print(&.{.{
        .text = "─── Theme(DiffColor) — indexed palette, works on all terminals ─────────────────────",
        .style = diffStyle(.chrome, lift_resolved),
    }}, .{ .row_offset = 1 });

    var row: u16 = 2;

    // Recent commit log
    _ = inner.print(&.{.{ .text = "─── git log --oneline ──────────────────────────────────────────────────────────────────", .style = diffStyle(.chrome, lift_resolved) }}, .{ .row_offset = row }); row += 1;
    const commits = [_]struct { hash: []const u8, msg: []const u8 }{
        .{ .hash = "fa32d37", .msg = "  Make List(C) generic, storing widget color bindings on the widget" },
        .{ .hash = "3022e22", .msg = "  Add WidgetTheme(C) for per-widget color role configuration" },
        .{ .hash = "540051b", .msg = "  Make Theme and Style generic over a user-supplied color enum" },
        .{ .hash = "b48f941", .msg = "  Decouple list widget tests from theme palette values" },
    };
    for (commits) |c| {
        _ = inner.print(&.{
            .{ .text = c.hash, .style = diffStyleBold(.label, lift_resolved) },
            .{ .text = c.msg,  .style = diffStyle(.chrome, lift_resolved) },
        }, .{ .row_offset = row }); row += 1;
    }
    row += 1;

    // Diff stat bars
    _ = inner.print(&.{.{ .text = "─── git diff --stat fa32d37 ────────────────────────────────────────────────────────────", .style = diffStyle(.chrome, lift_resolved) }}, .{ .row_offset = row }); row += 1;

    const stats = [_]struct { file: []const u8, n: []const u8, add: []const u8, del: []const u8 }{
        .{ .file = " src/widgets/list.zig  ", .n = "142 ", .add = "++++++++++++++++++++++++++++++++", .del = "────────────────────────" },
        .{ .file = " src/root.zig          ", .n = "  8 ", .add = "+++++++",                          .del = "─" },
        .{ .file = " src/main.zig          ", .n = " 58 ", .add = "+++++++++++++++++++++++++++",      .del = "──────────────────" },
    };
    for (stats) |s| {
        _ = inner.print(&.{
            .{ .text = s.file, .style = diffStyleBold(.label, lift_resolved) },
            .{ .text = "│ ",   .style = diffStyle(.chrome, lift_resolved) },
            .{ .text = s.n,    .style = diffStyle(.chrome, lift_resolved) },
            .{ .text = s.add,  .style = diffStyle(.added,  lift_resolved) },
            .{ .text = s.del,  .style = diffStyle(.removed, lift_resolved) },
        }, .{ .row_offset = row }); row += 1;
    }
    _ = inner.print(&.{.{
        .text = " 3 files changed, 208 insertions(+), 98 deletions(-)",
        .style = diffStyle(.meta, lift_resolved),
    }}, .{ .row_offset = row }); row += 1;
    row += 1;

    // Code diff snippet — the actual Theme(C) refactor
    _ = inner.print(&.{.{ .text = "─── src/core/theme.zig ─────────────────────────────────────────────────────────────────", .style = diffStyle(.chrome, lift_resolved) }}, .{ .row_offset = row }); row += 1;

    const diff_lines = [_]struct { prefix: []const u8, code: []const u8, color: DiffColor }{
        .{ .prefix = "  ", .code = " pub const Style = struct {",             .color = .chrome  },
        .{ .prefix = "- ", .code = "     fg:   Color     = .default,",        .color = .removed },
        .{ .prefix = "- ", .code = "     bg:   Color     = .default,",        .color = .removed },
        .{ .prefix = "  ", .code = "     text: TextStyle = .{},",             .color = .chrome  },
        .{ .prefix = "  ", .code = " };",                                     .color = .chrome  },
        .{ .prefix = "+ ", .code = " pub fn Style(comptime C: type) type {",  .color = .added   },
        .{ .prefix = "+ ", .code = "     return struct {",                    .color = .added   },
        .{ .prefix = "+ ", .code = "         fg:   ?C        = null,",        .color = .added   },
        .{ .prefix = "+ ", .code = "         bg:   ?C        = null,",        .color = .added   },
        .{ .prefix = "+ ", .code = "         text: TextStyle = .{},",         .color = .added   },
        .{ .prefix = "+ ", .code = "     };",                                 .color = .added   },
        .{ .prefix = "+ ", .code = " }",                                      .color = .added   },
    };
    for (diff_lines) |l| {
        _ = inner.print(&.{
            .{ .text = l.prefix, .style = diffStyleBold(l.color, lift_resolved) },
            .{ .text = l.code,   .style = diffStyle(l.color, lift_resolved) },
        }, .{ .row_offset = row }); row += 1;
        if (row >= inner.height) break;
    }
}

// Shared styling pairs — every focusable pane uses the same focus/unfocus
// styling for its border and its title label. Declaring them once keeps the
// individual draw calls down to one focus-aware call each.
const border_styles = zest.ByFocus(zest.DefaultStyle){
    .focused   = .{ .fg = .color_4 },
    .unfocused = .{ .fg = .color_8 },
};
const label_styles = zest.ByFocus(zest.DefaultStyle){
    .focused   = .{ .fg = .color_4, .text = .{ .bold = true } },
    .unfocused = .{},
};

fn drawSidebarPane(panel: zest.Panel, label: []const u8, theme: zest.DefaultTheme) vaxis.Window {
    const inner = panel.win.child(.{
        .border = .{ .where = .all, .style = theme.resolve(border_styles.pick(panel.focused)) },
    });
    if (inner.height > 0) {
        zest.Text.draw(inner, label, label_styles.pick(panel.focused), theme, .{});
    }
    return inner;
}

fn draw(state: *State, win: vaxis.Window) void {
    win.clear();

    const theme: zest.DefaultTheme = if (state.color_scheme == .dark)
        zest.catppuccin_mocha
    else
        zest.catppuccin_latte;

    const p = zest.Layout.panelsFromState(layout, win,
        .{ .x = 0, .y = 0, .width = win.width, .height = win.height },
        &state.focus);

    // Header — NerdFont powerline pill, centered. Half-circle caps
    // (U+E0B6 left, U+E0B4 right) hold a yellow ribbon with the title.
    // Cap glyphs render the yellow shape on default bg; the ribbon
    // cells carry yellow bg with matching-bg title text. Anchor.resolve
    // computes the centering offset against the full composite width
    // so the pill re-centers on every resize. Requires a patched font;
    // without one the caps render as replacement boxes.
    const header_bg: zest.Color = .color_3;
    const title = " zest demo ";
    const ribbon_w: u16 = @intCast(title.len);
    const composite_w: u16 = ribbon_w + 2; // +2 for the caps

    const off = (zest.Anchor{ .horizontal = .center, .vertical = .top })
        .resolve(p.header.win.width, p.header.win.height, composite_w, 1);

    _ = p.header.win.print(&.{
        .{ .text  = "\u{E0B6}", //
           .style = .{ .fg = theme.colors.get(header_bg), .bg = .default } },
        .{ .text  = title,
           .style = theme.resolve(zest.DefaultStyle{
               .fg   = .background,
               .bg   = header_bg,
               .text = .{ .bold = true },
           }) },
        .{ .text  = "\u{E0B4}", //
           .style = .{ .fg = theme.colors.get(header_bg), .bg = .default } },
    }, .{ .wrap = .none, .col_offset = off.col, .row_offset = off.row });

    const files_inner = drawSidebarPane(p.files, "1 files", theme);
    _ = drawSidebarPane(p.branches, "2 branches", theme);
    _ = drawSidebarPane(p.commits,  "3 commits",  theme);
    _ = drawSidebarPane(p.stash,    "4 stash",    theme);

    const list_win = files_inner.child(.{ .y_off = 1, .height = files_inner.height -| 1 });
    state.files_list.draw(list_win, &files_items, p.files.focused, theme);

    drawShowcase(p.showcase.win, p.showcase.focused,
        files_items[state.files_list.selected], theme);

    zest.Text.draw(p.log.win, "log", zest.DefaultStyle{ .fg = .color_7 }, theme, .{});
    zest.Text.draw(p.footer.win,
        "tab: cycle  j/k: navigate  ^W: switch  0-4: jump  q: quit",
        zest.DefaultStyle{ .fg = .color_7 }, theme, .{});
}

fn update(state: *State, event: zest.Event, alloc: std.mem.Allocator) zest.UpdateResult {
    _ = alloc;
    switch (event) {
        .key_press => |key| {
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
            if (key.matches('w', .{ .ctrl = true })) {
                state.focus.active_domain = if (state.focus.active_domain == .sidebar) .main else .sidebar;
                return .redraw;
            }
            switch (key.codepoint) {
                'j', 'k', vaxis.Key.down, vaxis.Key.up => {
                    if (state.focus.active_domain == .sidebar and state.focus.sidebar.is(.files)) {
                        state.files_list.handleKey(key, files_items.len);
                    }
                    return .redraw;
                },
                '0' => {
                    state.focus.active_domain = .main;
                    state.focus.main.set(.showcase);
                },
                '1'...'4' => |ch| {
                    state.focus.active_domain = .sidebar;
                    state.focus.sidebar.set(switch (ch) {
                        '1' => .files,
                        '2' => .branches,
                        '3' => .commits,
                        '4' => .stash,
                        else => unreachable, // guarded by the outer range arm
                    });
                },
                else => return .idle,
            }
            return .redraw;
        },
        .winsize, .focus_changed => return .redraw,
        .color_scheme => |cs| {
            state.color_scheme = cs;
            state.files_list.widget_theme = if (cs == .dark) zest.mocha_widget else zest.latte_widget;
            return .redraw;
        },
        else => return .idle,
    }
}

pub fn main(init: std.process.Init) !void {
    var tty_buf: [4096]u8 = undefined;
    var app = try zest.App.init(init.io, init.gpa, init.environ_map, &tty_buf);
    defer app.deinit();

    var state: State = .{
        .focus        = zest.Layout.focusStateInit(layout),
        .color_scheme = .dark,
        .files_list   = .{ .widget_theme = zest.mocha_widget },
    };

    try app.run(&state, activeFocus, update, draw, .{});
}
