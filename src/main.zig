//! Minimal demo application for zest.
//!
//! Grows alongside the framework — each new capability is wired in here
//! as soon as it exists, following the same development flow a framework
//! user would follow.

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

// Declare the intended screen layout as a comptime blueprint.
// The solver does not exist yet, so this produces no visual output —
// it compiles and proves the blueprint syntax is correct.
const layout = zest.box(.{
    .direction = .horizontal,
    .children = &.{
        zest.slot(.{ .size = .{ .fixed = 30 } }),
        zest.slot(.{ .size = .{ .fraction = 1 } }),
    },
});

const State = struct {};

// Single-slot layout used to verify the solver end-to-end during development.
// The full two-pane `layout` above will replace this once the box() solver
// pass is wired up.
const debug_layout = zest.slot(.{ .size = .{ .fraction = 1 } });

fn update(state: *State, event: zest.Event, win: vaxis.Window, alloc: std.mem.Allocator) zest.UpdateResult {
    _ = state;
    switch (event) {
        .key_press => |key| {
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
            return .idle;
        },
        .winsize => |ws| {
            const bounds = zest.Rect{ .x = 0, .y = 0, .width = ws.cols, .height = ws.rows };
            const rects = zest.solve(alloc, debug_layout, bounds) catch return .idle;
            std.debug.print("solve: {d} rect(s), [0] = {any}\n", .{ rects.len, rects[0] });
            _ = win.print(&.{.{ .text = "Hello, Zest!  Press 'q' to quit." }}, .{});
            return .redraw;
        },
        .focus_in => {
            _ = win.print(&.{.{ .text = "Hello, Zest!  Press 'q' to quit." }}, .{});
            return .redraw;
        },
        else => return .idle,
    }
}

pub fn main(init: std.process.Init) !void {
    // layout is referenced here so the compiler does not optimise it away
    // before the solver is wired up to consume it.
    _ = layout;

    var tty_buf: [4096]u8 = undefined;
    var app = try zest.App.init(init.io, init.gpa, init.environ_map, &tty_buf);
    defer app.deinit();

    var state: State = .{};
    try app.run(&state, update);
}
