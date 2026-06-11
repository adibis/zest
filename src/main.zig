//! Minimal demo application for zest.
//!
//! Grows alongside the framework — each new capability is wired in here
//! as soon as it exists, following the same development flow a framework
//! user would follow.

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

// Screen layout: fixed sidebar | vertical split (fixed header / body).
const layout = zest.box(.{
    .direction = .horizontal,
    .children = &.{
        zest.slot(.{ .id = "sidebar", .size = .{ .fixed = 30 }, .border = true }),
        zest.box(.{
            .size = .{ .fraction = 1 },
            .direction = .vertical,
            .children = &.{
                zest.slot(.{ .id = "header", .size = .{ .fixed = 3 }, .border = true }),
                zest.slot(.{ .id = "body",   .size = .{ .fraction = 1 }, .border = true }),
            },
        }),
    },
});

// Both derived from the blueprint — no separate count or ID list to maintain.
const panel_ids = zest.Box.panelIds(layout);
const State = struct {
    focus: zest.FocusStack = zest.FocusStack.init(zest.Focus.init(zest.Box.panelCount(layout))),
};

fn draw(state: *State, win: vaxis.Window, alloc: std.mem.Allocator) zest.UpdateResult {
    const bounds = zest.Rect{ .x = 0, .y = 0, .width = win.width, .height = win.height };
    win.clear();
    const wins = zest.Box.windows(layout, win, bounds);
    _ = wins.sidebar.print(&.{.{ .text = if (state.focus.is("sidebar", &panel_ids)) "sidebar [*]" else "sidebar" }}, .{});
    _ = wins.header .print(&.{.{ .text = if (state.focus.is("header",  &panel_ids)) "header [*]"  else "header"  }}, .{});
    const body_text = std.fmt.allocPrint(
        alloc,
        "{s}  ({d}x{d})  tab to cycle focus  q to quit",
        .{ if (state.focus.is("body", &panel_ids)) "body [*]" else "body", wins.body.width, wins.body.height },
    ) catch return .idle;
    _ = wins.body.print(&.{.{ .text = body_text }}, .{});
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
