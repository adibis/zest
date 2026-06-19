//! System-stats dashboard example.
//!
//! Worked example showing how the framework's viz widgets compose
//! into a real application — CPU and memory meters, a network
//! throughput sparkline, a small process table, a live status
//! footer, and a header strip with the running uptime.
//!
//! Everything driven by mock data updated on the framework's `.tick`
//! event; swap the mock generators for real sysinfo readers and the
//! same widget layout drives a working stats dashboard. This file is
//! intentionally self-contained — no shared state with the demo or
//! the library tests — so apps starting from it can fork the
//! directory and modify in place.
//!
//! Layout (drawn top-to-bottom):
//!
//!   header (1)    — TitleBar with the dashboard name
//!   overview (5)  — CPU + RAM horizontal gauges side by side
//!   network (6)   — sparkline of recent throughput
//!   processes (*) — Table with top processes by CPU
//!   footer (1)    — tick-driven spinner + keybinding hint
//!
//! Build & run:
//!
//!   zig build dashboard
//!
//! Tap q to quit. j / k move the process table selection.

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

// --- Layout ------------------------------------------------------------------

const layout = zest.hsplit(.{
    .children = &.{
        zest.pane(.{ .id = "header",   .size = .{ .fixed = 1 }, .focusable = false }),
        zest.pane(.{ .id = "overview", .size = .{ .fixed = 5 }, .border = true, .focusable = false }),
        zest.pane(.{ .id = "network",  .size = .{ .fixed = 6 }, .border = true, .focusable = false }),
        // Single-pane domain so the framework has at least one focus
        // ring to stamp `focused = true` on; widget content lands in
        // later commits and may expand this domain.
        zest.domain(.{
            .id        = "body",
            .direction = zest.Direction.vertical,
            .size      = .{ .fraction = 1 },
            .children  = &.{
                zest.pane(.{ .id = "processes", .size = .{ .fraction = 1 }, .border = true }),
            },
        }),
        zest.pane(.{ .id = "footer",   .size = .{ .fixed = 1 }, .focusable = false }),
    },
});

const FocusState = zest.Layout.FocusStateType(layout);

// --- State -------------------------------------------------------------------
//
// All values here are mock — the dashboard's job is to show the widgets
// composing, not to read real sysinfo. Swap any field for an
// actually-measured value when adapting this example.

const State = struct {
    focus: FocusState,
    color_scheme: vaxis.Color.Scheme,
    spinner: zest.Spinner(zest.Color),
    tick_counter: u32,
    cpu_fraction: f32,
    ram_fraction: f32,
    net_history: [80]f32,
    process_table: zest.Table(zest.Color),
};

fn activeFocus(state: *State) *zest.FocusStack {
    return zest.Layout.focusStateActiveFocus(layout, &state.focus);
}

// Populated for real in commit 6.
const process_rows = [_][]const []const u8{};

// --- Draw --------------------------------------------------------------------

fn draw(state: *State, win: vaxis.Window) void {
    win.clear();

    const theme: zest.DefaultTheme = if (state.color_scheme == .dark)
        zest.catppuccin_mocha
    else
        zest.catppuccin_latte;

    const p = zest.Layout.panelsFromState(layout, win,
        .{ .x = 0, .y = 0, .width = win.width, .height = win.height },
        &state.focus);

    const title_bar = zest.TitleBar(zest.Color){};
    title_bar.draw(p.header.win, theme, .{
        .text  = " zest · dashboard ",
        .style = .{ .fg = .background, .bg = .color_4, .text = .{ .bold = true } },
        .caps  = .round,
    });

    state.spinner.draw(p.footer.win, theme);
    const footer_keys = p.footer.win.child(.{
        .x_off = 2,
        .width = p.footer.win.width -| 2,
    });
    zest.Text.draw(footer_keys,
        "j/k: select  q: quit",
        zest.DefaultStyle{ .fg = .color_7 }, theme, .{});

    // Body panes carry only their borders at this commit; widget
    // content lands in commits 4-6.
    _ = p.overview;
    _ = p.network;
    _ = p.processes;
}

fn update(state: *State, event: zest.Event, alloc: std.mem.Allocator) zest.UpdateResult {
    _ = alloc;
    switch (event) {
        .key_press => |key| {
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
            switch (key.codepoint) {
                'j', 'k', vaxis.Key.down, vaxis.Key.up => {
                    state.process_table.handleKey(key, process_rows.len);
                    return .redraw;
                },
                else => return .idle,
            }
        },
        .winsize, .focus_changed => return .redraw,
        .color_scheme => |cs| {
            state.color_scheme = cs;
            return .redraw;
        },
        .tick => {
            state.tick_counter +%= 1;
            state.spinner.advance();
            const t: f32 = @as(f32, @floatFromInt(state.tick_counter)) * 0.05;
            state.cpu_fraction = 0.5 + 0.4 * @sin(t);
            state.ram_fraction = 0.4 + 0.2 * @sin(t * 0.3);
            std.mem.copyForwards(
                f32,
                state.net_history[0 .. state.net_history.len - 1],
                state.net_history[1..],
            );
            state.net_history[state.net_history.len - 1] =
                0.3 + 0.3 * @sin(t * 0.7) + 0.2 * @sin(t * 2.1);
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
        .focus         = zest.Layout.focusStateInit(layout),
        .color_scheme  = .dark,
        .spinner       = .{ .style = .{ .fg = .color_4 } },
        .tick_counter  = 0,
        .cpu_fraction  = 0.0,
        .ram_fraction  = 0.0,
        .net_history   = .{0.0} ** 80,
        .process_table = .{ .columns = &.{} },
    };

    try app.run(&state, activeFocus, update, draw, .{
        .tick_interval = .fromMilliseconds(100),
    });
}
