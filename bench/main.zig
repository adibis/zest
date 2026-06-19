//! Zest micro-benchmark harness.
//!
//! Tracks the framework's hot-path latencies so regressions surface
//! against the performance targets in the README. Built in
//! ReleaseFast (see build.zig) so measurements aren't dominated by
//! debug safety checks.
//!
//! Each scenario runs a fixed number of iterations, samples per-call
//! latency through `std.time.Timer`, then prints p50 / p95 / p99 /
//! max in nanoseconds. Adding a scenario is one entry in `scenarios`
//! below plus a measure function with the standard signature.
//!
//!   zig build bench
//!
//! Scenarios currently covered:
//!
//!   * panelsFromState — the per-frame layout solve + focus stamping
//!     pass that the README's "Frame layout latency (p99) < 150 µs"
//!     target is measured against.

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

const iterations: usize = 100_000;

// --- Scenario: panelsFromState ----------------------------------------------

const bench_layout = zest.hsplit(.{
    .children = &.{
        zest.pane(.{ .id = "header", .size = .{ .fixed = 1 }, .focusable = false }),
        zest.vsplit(.{
            .size = .{ .fraction = 1 },
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
                        zest.pane(.{ .id = "log",      .size = .{ .fixed = 6 }, .border = true, .focusable = false }),
                    },
                }),
            },
        }),
        zest.pane(.{ .id = "footer", .size = .{ .fixed = 1 }, .focusable = false }),
    },
});

const BenchFocus = zest.Layout.FocusStateType(bench_layout);

fn benchPanelsFromState(alloc: std.mem.Allocator, io: std.Io, samples: []u64) !void {
    var focus_state: BenchFocus = zest.Layout.focusStateInit(bench_layout);

    // Synthesize a window — the layout solver only reads .width /
    // .height; the surrounding screen pointer is harmless for the
    // pass we're measuring.
    var screen = try vaxis.Screen.init(alloc, .{
        .rows = 30, .cols = 120, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(alloc);
    const win: vaxis.Window = .{
        .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0,
        .width = 120, .height = 30, .screen = &screen,
    };

    for (samples) |*s| {
        const start = std.Io.Clock.now(.awake, io);
        const p = zest.Layout.panelsFromState(bench_layout, win,
            .{ .x = 0, .y = 0, .width = win.width, .height = win.height },
            &focus_state);
        std.mem.doNotOptimizeAway(p);
        const end = std.Io.Clock.now(.awake, io);
        const dur = start.durationTo(end);
        s.* = @intCast(dur.nanoseconds);
    }
}

// --- Harness ----------------------------------------------------------------

const Scenario = struct {
    name: []const u8,
    desc: []const u8,
    run:  *const fn (std.mem.Allocator, std.Io, []u64) anyerror!void,
};

const scenarios = [_]Scenario{
    .{
        .name = "panelsFromState",
        .desc = "demo-shaped layout (3 chrome panes + 2 domains, 6 leaves)",
        .run  = benchPanelsFromState,
    },
};

fn percentile(sorted: []const u64, frac: f32) u64 {
    if (sorted.len == 0) return 0;
    const idx_f: f32 = frac * @as(f32, @floatFromInt(sorted.len - 1));
    const idx: usize = @intFromFloat(idx_f);
    return sorted[idx];
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const samples = try alloc.alloc(u64, iterations);
    defer alloc.free(samples);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print(
        "Zest micro-benchmark · {d} iterations per scenario\n\n",
        .{iterations},
    );

    for (scenarios) |sc| {
        try sc.run(alloc, init.io, samples);
        std.sort.heap(u64, samples, {}, std.sort.asc(u64));
        const p50 = percentile(samples, 0.50);
        const p95 = percentile(samples, 0.95);
        const p99 = percentile(samples, 0.99);
        const max_ns = samples[samples.len - 1];
        try stdout.print(
            "{s}\n  {s}\n  p50 = {d:>6} ns   p95 = {d:>6} ns   p99 = {d:>6} ns   max = {d:>6} ns\n\n",
            .{ sc.name, sc.desc, p50, p95, p99, max_ns },
        );
    }
}
