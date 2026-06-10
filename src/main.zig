//! Minimal demo application for zest.
//!
//! Shows the event loop wired up end-to-end: renders a greeting on startup
//! and on every resize, exits cleanly on 'q' or Ctrl-C.
//! Not part of the library — exists only to verify the framework compiles
//! and runs correctly as a whole.

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

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
    var tty_buf: [4096]u8 = undefined;
    var app = try zest.App.init(init.io, init.gpa, init.environ_map, &tty_buf);
    defer app.deinit();

    var state: State = .{};
    try app.run(&state, update);
}
