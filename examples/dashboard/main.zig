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
    // Per-frame scratch buffers for the overview gauge labels.
    // Written from draw(); same single-threaded-loop dependency as
    // the demo's progress_text_buf.
    cpu_label_buf: [16]u8,
    ram_label_buf: [16]u8,
    net_label_buf: [32]u8,
};

fn activeFocus(state: *State) *zest.FocusStack {
    return zest.Layout.focusStateActiveFocus(layout, &state.focus);
}

// Populated for real in commit 6.
const process_rows = [_][]const []const u8{};

// --- File-scope widget instances --------------------------------------------

// CPU and RAM share the same horizontal-gauge shape but pick distinct
// colours so a glance at the overview pane reads which meter is which.
const cpu_gauge = zest.Gauge(zest.Color){
    .orientation  = .horizontal,
    .filled_style = .{ .fg = .color_2 }, // green
};
const ram_gauge = zest.Gauge(zest.Color){
    .orientation  = .horizontal,
    .filled_style = .{ .fg = .color_4 }, // blue
};

// Network throughput sparkline — values come from `net_history` on
// State, refreshed once per tick from the mock generator. The
// brighter accent (magenta) sets it apart from the green/blue
// gauges above.
const net_sparkline = zest.Sparkline(zest.Color){
    .style = .{ .fg = .color_5 },
};

// Mock peak throughput (KB/s) the 0..1 fractions in net_history map
// onto. Adjust when swapping in real measurements.
const net_peak_kbps: f32 = 200.0;

fn fmtPctLabel(buf: []u8, prefix: []const u8, fraction: f32) []const u8 {
    const pct: u32 = @intFromFloat(std.math.clamp(fraction, 0.0, 1.0) * 100.0);
    return std.fmt.bufPrint(buf, "{s}  {d}%", .{ prefix, pct }) catch "";
}

fn drawNetwork(state: *State, win: vaxis.Window, theme: zest.DefaultTheme) void {
    if (win.height == 0 or win.width == 0) return;

    const latest = state.net_history[state.net_history.len - 1];
    const kbps: u32 = @intFromFloat(latest * net_peak_kbps);
    const label = std.fmt.bufPrint(
        &state.net_label_buf,
        "Network  ·  {d} KB/s",
        .{kbps},
    ) catch "";

    zest.Text.draw(win, label,
        zest.DefaultStyle{ .fg = .color_7, .text = .{ .bold = true } }, theme, .{});

    // Sparkline on the bottom inner row so the label and the strip
    // are visually separated and there's no overlap risk on small
    // terminals.
    if (win.height >= 3) {
        const sl_y: u16 = win.height - 1;
        const sl_win = win.child(.{ .y_off = sl_y, .height = 1 });
        net_sparkline.draw(sl_win, &state.net_history, theme);
    }
}

fn drawOverview(state: *State, win: vaxis.Window, theme: zest.DefaultTheme) void {
    if (win.height == 0) return;
    // Two side-by-side horizontal gauges. Each gauge uses its built-in
    // top-row label option, so the label "CPU  47%" sits on the top
    // row of its own half-window and the fill bar fills the rest.
    const half_w: u16 = win.width / 2;
    if (half_w < 6) return; // not enough width for a meaningful split

    const cpu_label = fmtPctLabel(&state.cpu_label_buf, "CPU", state.cpu_fraction);
    const ram_label = fmtPctLabel(&state.ram_label_buf, "RAM", state.ram_fraction);

    const label_style = zest.DefaultStyle{ .fg = .color_7, .text = .{ .bold = true } };

    const cpu_win = win.child(.{ .width = half_w });
    cpu_gauge.draw(cpu_win, state.cpu_fraction, theme, .{
        .text  = cpu_label,
        .style = label_style,
    });

    const ram_win = win.child(.{ .x_off = half_w, .width = win.width - half_w });
    ram_gauge.draw(ram_win, state.ram_fraction, theme, .{
        .text  = ram_label,
        .style = label_style,
    });
}

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

    drawOverview(state, p.overview.win, theme);
    drawNetwork(state, p.network.win, theme);

    // Process table content lands in commit 6.
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
        .cpu_label_buf = undefined,
        .ram_label_buf = undefined,
        .net_label_buf = undefined,
    };

    try app.run(&state, activeFocus, update, draw, .{
        .tick_interval = .fromMilliseconds(100),
    });
}
