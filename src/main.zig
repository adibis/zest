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
        zest.slot(.{ .size = .{ .fixed = 30 } }),
        zest.box(.{
            .size = .{ .fraction = 1 },
            .direction = .vertical,
            .children = &.{
                zest.slot(.{ .size = .{ .fixed = 3 } }),
                zest.slot(.{ .size = .{ .fraction = 1 } }),
            },
        }),
    },
});

const State = struct {};

fn update(state: *State, event: zest.Event, win: vaxis.Window, alloc: std.mem.Allocator) zest.UpdateResult {
    _ = state;
    switch (event) {
        .key_press => |key| {
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
            return .idle;
        },
        .winsize => |ws| {
            const bounds = zest.Rect{ .x = 0, .y = 0, .width = ws.cols, .height = ws.rows };
            const wins = zest.Box.windows(layout, win, bounds, alloc) catch return .idle;
            win.clear();
            _ = wins[0].print(&.{.{ .text = "sidebar" }}, .{});
            _ = wins[1].print(&.{.{ .text = "header" }}, .{});
            const body_text = std.fmt.allocPrint(
                alloc,
                "body  ({d}x{d})  press 'q' to quit",
                .{ wins[2].width, wins[2].height },
            ) catch return .idle;
            _ = wins[2].print(&.{.{ .text = body_text }}, .{});
            return .redraw;
        },
        .focus_in => {
            _ = win.print(&.{.{ .text = "Hello, Zest!" }}, .{});
            return .redraw;
        },
        else => return .idle,
    }
}

pub fn main(init: std.process.Init) !void {
    var tty_buf: [4096]u8 = undefined;
    var app = try zest.App.init(init.io, init.gpa, init.environ_map, &tty_buf);
    defer app.deinit();

    var state: State = .{};
    try app.run(&state, update);
}
