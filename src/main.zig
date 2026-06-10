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
            const rects = zest.solve(alloc, layout, bounds) catch return .idle;
            win.clear();
            const sidebar = win.child(.{
                .x_off = @intCast(rects[0].x),
                .y_off = @intCast(rects[0].y),
                .width = rects[0].width,
                .height = rects[0].height,
            });
            const header = win.child(.{
                .x_off = @intCast(rects[1].x),
                .y_off = @intCast(rects[1].y),
                .width = rects[1].width,
                .height = rects[1].height,
            });
            const body = win.child(.{
                .x_off = @intCast(rects[2].x),
                .y_off = @intCast(rects[2].y),
                .width = rects[2].width,
                .height = rects[2].height,
            });
            _ = sidebar.print(&.{.{ .text = "sidebar" }}, .{});
            _ = header.print(&.{.{ .text = "header" }}, .{});
            const body_text = std.fmt.allocPrint(
                alloc,
                "body  ({d}x{d})  press 'q' to quit",
                .{ rects[2].width, rects[2].height },
            ) catch return .idle;
            _ = body.print(&.{.{ .text = body_text }}, .{});
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
