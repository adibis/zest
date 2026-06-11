//! Minimal demo application for zest.
//!
//! Grows alongside the framework — each new capability is wired in here
//! as soon as it exists, following the same development flow a framework
//! user would follow.

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

// Screen layout: fixed sidebar | vertical split (fixed header / body).
const layout = zest.hsplit(.{
    .children = &.{
        zest.pane(.{ .id = "sidebar", .size = .{ .fixed = 30 }, .border = true }),
        zest.vsplit(.{
            .size = .{ .fraction = 1 },
            .children = &.{
                zest.pane(.{ .id = "header", .size = .{ .fixed = 3 }, .border = true }),
                zest.pane(.{ .id = "body",   .size = .{ .fraction = 1 }, .border = true }),
            },
        }),
    },
});

const State = struct {
    focus: zest.FocusStack = zest.FocusStack.init(zest.Focus.init(zest.Layout.panelCount(layout))),
};

fn draw(state: *State, win: vaxis.Window, alloc: std.mem.Allocator) zest.UpdateResult {
    const bounds = zest.Rect{ .x = 0, .y = 0, .width = win.width, .height = win.height };
    win.clear();
    const p = zest.Layout.panels(layout, win, bounds, .{ .focus = &state.focus });
    _ = p.sidebar.win.print(&.{.{ .text = if (p.sidebar.focused) "sidebar [*]" else "sidebar" }}, .{});
    _ = p.header .win.print(&.{.{ .text = if (p.header.focused)  "header [*]"  else "header"  }}, .{});
    const body_text = std.fmt.allocPrint(
        alloc,
        "{s}  ({d}x{d})  tab to cycle focus  q to quit",
        .{ if (p.body.focused) "body [*]" else "body", p.body.win.width, p.body.win.height },
    ) catch return .idle;
    _ = p.body.win.print(&.{.{ .text = body_text }}, .{});
    return .redraw;
}

fn update(state: *State, event: zest.Event, win: vaxis.Window, alloc: std.mem.Allocator) zest.UpdateResult {
    switch (event) {
        .key_press => |key| {
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
            return .idle;
        },
        .winsize, .focus_changed => return draw(state, win, alloc),
        else => return .idle,
    }
}

pub fn main(init: std.process.Init) !void {
    var tty_buf: [4096]u8 = undefined;
    var app = try zest.App.init(init.io, init.gpa, init.environ_map, &tty_buf);
    defer app.deinit();

    var state: State = .{};
    var active_focus: *zest.FocusStack = &state.focus;
    try app.run(&state, &active_focus, update);
}
