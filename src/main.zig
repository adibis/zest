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

fn update(state: *State, event: zest.Event, win: vaxis.Window, _: std.mem.Allocator) zest.UpdateResult {
    _ = state;
    switch (event) {
        .key_press => |key| {
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
            return .idle;
        },
        .winsize, .focus_in => {
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
