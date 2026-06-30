//! Zest framework demo — tabbed multi-view showcase.
//!
//! Tab 0 (Showcase): two focus domains, scrollable list, widget gallery,
//! and a live tick-driven bottom strip.
//! Tab 1 (Dashboard): system-stats style view with CPU/RAM gauges,
//! network sparkline, and a process table.
//!
//! The sidebar uses the built-in Catppuccin palette (Mocha/Latte selected at
//! runtime from the terminal's reported color scheme); apps that set
//! `NO_COLOR` get a no-colour theme regardless. The bottom strip is a worked
//! example of every viz widget the framework ships: progress bar, gauge,
//! sparkline, spinner.
//!
//! Keybindings:
//!   h/l or ←/→ — switch tab
//!   Tab        — cycle focus within active domain
//!   Ctrl-W     — switch domain (Showcase tab)
//!   j/k or arrows — navigate list / table
//!   0-4        — jump to sidebar pane (Showcase tab)
//!   q          — quit

const std = @import("std");
const vaxis = @import("vaxis");
const zest = @import("zest");

// --- Layout ------------------------------------------------------------------
//
// The outer frame (header strip, tab strip, content, footer strip) is
// computed by hand inside draw() because there's only one focusable
// content region and the four chrome rows are fixed-height. The
// showcase tab's body (sidebar + main domains) is a comptime layout
// resolved against whatever child window the content area gives it.

const showcase_layout = zest.vsplit(.{
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
                // Bottom strip: progress + sparkline stacked on the
                // left, a thin vertical gauge on the right. Total
                // strip is 6 rows tall — progress and log each take
                // 3 rows (one content row plus borders); the gauge
                // takes 6 columns (four inner cols, enough for the
                // "100%" worst-case label).
                zest.vsplit(.{
                    .size     = .{ .fixed = 6 },
                    .children = &.{
                        zest.hsplit(.{
                            .size     = .{ .fraction = 1 },
                            .children = &.{
                                zest.pane(.{ .id = "progress", .size = .{ .fixed = 3 }, .border = true, .focusable = false }),
                                zest.pane(.{ .id = "log",      .size = .{ .fixed = 3 }, .border = true, .focusable = false }),
                            },
                        }),
                        zest.pane(.{ .id = "loading", .size = .{ .fixed = 6 }, .border = true, .focusable = false }),
                    },
                }),
            },
        }),
    },
});

const FocusState = zest.Layout.FocusStateType(showcase_layout);

// Dashboard tab body — overview / network header strips and a
// process table inside a focus domain so the table picks up
// `focused = true` on its pane when the tab is active.
const dashboard_layout = zest.hsplit(.{
    .children = &.{
        zest.pane(.{ .id = "overview", .size = .{ .fixed = 5 }, .border = true, .focusable = false }),
        zest.pane(.{ .id = "network",  .size = .{ .fixed = 6 }, .border = true, .focusable = false }),
        zest.domain(.{
            .id        = "body",
            .direction = zest.Direction.vertical,
            .size      = .{ .fraction = 1 },
            .children  = &.{
                zest.pane(.{ .id = "processes", .size = .{ .fraction = 1 }, .border = true }),
            },
        }),
    },
});

const DashboardFocus = zest.Layout.FocusStateType(dashboard_layout);

// Frame chrome heights — header, tab strip, footer.
const header_h: u16 = 1;
const tabs_h:   u16 = 2;
const footer_h: u16 = 1;
const chrome_h: u16 = header_h + tabs_h + footer_h;

const tab_labels = [_][]const u8{ "Showcase", "Dashboard" };

// Mock peak network throughput (KB/s) the 0..1 fractions in
// dashboard.net_history map onto. Adjust when swapping in real
// measurements.
const net_peak_kbps: f32 = 200.0;

// Mock process snapshot for the dashboard tab — name + PID are
// realistic; CPU / MEM values are picked so the rows sort roughly
// by CPU descending. Swap for a real /proc reader (Linux) or
// libproc poll (macOS) when adapting.
const process_rows = [_][]const []const u8{
    &.{ "  1234", "zest",         " 18.4%", "  1.2%" },
    &.{ "  5678", "ghostty",      " 12.1%", "  2.4%" },
    &.{ "    91", "kernel_task",  "  8.7%", "  0.1%" },
    &.{ "  2901", "WindowServer", "  6.5%", "  3.2%" },
    &.{ "  4023", "Slack",        "  3.8%", "  4.8%" },
    &.{ "  7720", "firefox",      "  2.9%", " 12.4%" },
    &.{ "    88", "launchd",      "  0.4%", "  0.0%" },
    &.{ "    93", "syslogd",      "  0.2%", "  0.0%" },
};

const process_columns = [_]zest.TableColumn(zest.Color){
    .{ .header = "  PID", .size = .{ .fixed = 7 },    .alignment = .right },
    .{ .header = "NAME",  .size = .{ .fraction = 1 } },
    .{ .header = "CPU",   .size = .{ .fixed = 8 },    .alignment = .right },
    .{ .header = "MEM",   .size = .{ .fixed = 8 },    .alignment = .right },
};

const files_items = [_][]const u8{
    "src/main.zig",
    "src/core/app.zig",
    "src/core/focus.zig",
    "src/core/memory.zig",
    "src/core/theme.zig",
    "src/layout/blueprint.zig",
    "src/layout/rect.zig",
    "src/layout/size.zig",
    "src/layout/solver.zig",
    "src/widgets/box.zig",
    "src/widgets/list.zig",
    "src/widgets/text.zig",
};

// --- State -------------------------------------------------------------------

const State = struct {
    focus:             FocusState,
    files_list:        zest.DefaultList,
    color_scheme:      vaxis.Color.Scheme,
    /// Advanced by .tick events; wraps at 1.0 — drives the progress widget.
    progress_fraction: f32,
    /// Stepped to the next frame on every .tick; renders in the footer.
    spinner:           zest.Spinner(zest.Color),
    /// Ring of recent progress_fraction samples — drives the log-pane
    /// sparkline. New samples shift in from the right on every .tick. The
    /// O(N) shift is a demo simplification for clarity; production code
    /// should use a ring buffer with a write index.
    progress_history:  [80]f32,
    /// True when NO_COLOR is set in the environment at startup. Drives
    /// the draw-time theme selection.
    no_color:          bool,
    /// Per-frame buffer backing the progress bar's overlaid label. Lives
    /// on State because the formatted slice has to outlive the frame
    /// (vaxis reads graphemes at render time). Written from draw() each
    /// frame; safe because App.run calls draw synchronously between
    /// events and no second writer exists in the demo's threading model.
    progress_text_buf: [8]u8,
    /// Same constraints as progress_text_buf — overwritten every frame.
    gauge_text_buf:    [8]u8,
    /// Backing buffers for the showcase gallery's per-bar labels.
    /// Same lifetime rules as the other text buffers.
    showcase_label_bufs: [3][8]u8,
    /// Display-only Table for the showcase gallery. Carries its own
    /// selection state so the focused-row highlight stays consistent
    /// across frames; the demo doesn't currently route keys to it,
    /// so the selection is a static demonstration.
    showcase_table:      zest.Table(zest.Color),
    /// Free-running tick count used for showcase spinners. Driving them
    /// off `spinner.frame_index` would tie them to the footer braille
    /// spinner's 10-frame modulo and rotate the 4-frame sets at 2.5 Hz
    /// (uncomfortably fast). A separate u32 counter divided by 4 gives
    /// ~0.6 Hz rotations — comfortable to look at — while the footer
    /// keeps its full ~1 Hz braille smoothness.
    tick_counter:      u32,
    /// Top-level tab strip switching between the showcase and the
    /// dashboard views. `handleKey` advances on h/l or ←/→.
    tab:               zest.Tab(zest.Color),
    /// Focus state for the dashboard tab — separate from the
    /// showcase tab's focus so each tab keeps its own selection /
    /// active-domain across switches.
    dashboard_focus:   DashboardFocus,
    /// Process table for the dashboard tab. Same selection +
    /// scroll model as the sidebar list; j/k routes here when the
    /// dashboard tab is active.
    dashboard_table:   zest.Table(zest.Color),
    /// Mock CPU and RAM fractions, walked by .tick.
    cpu_fraction:      f32,
    ram_fraction:      f32,
    /// Mock network throughput history (right-edge anchored), shifted
    /// one sample per tick.
    net_history:       [80]f32,
    /// Per-frame scratch buffers for the dashboard's gauge / sparkline
    /// labels. Same draw-time-write lifetime as the showcase buffers.
    cpu_label_buf:     [16]u8,
    ram_label_buf:     [16]u8,
    net_label_buf:     [32]u8,
    /// Help popup overlaid on top of the active tab when open.
    /// Toggled with `?`; Esc closes. The popup body renders a
    /// keybinding cheatsheet inside `drawHelpPopup`.
    help_popup:        zest.Popup(zest.Color),
};

fn activeFocus(state: *State) *zest.FocusStack {
    return switch (state.tab.active) {
        1 => zest.Layout.focusStateActiveFocus(dashboard_layout, &state.dashboard_focus),
        else => zest.Layout.focusStateActiveFocus(showcase_layout, &state.focus),
    };
}

/// Format a fraction in [0,1] as "{N}%" into `buf`. Returns the formatted
/// slice; the buffer's contents stay stable for the slice's lifetime, so
/// callers pass a State-owned buffer for frame-spanning use.
fn fmtPct(buf: []u8, fraction: f32) []const u8 {
    const pct: u32 = @intFromFloat(std.math.clamp(fraction, 0.0, 1.0) * 100.0);
    return std.fmt.bufPrint(buf, "{d}%", .{pct}) catch "";
}

/// Format a "{prefix}  {N}%" label for the dashboard's gauge headings.
fn fmtPctLabel(buf: []u8, prefix: []const u8, fraction: f32) []const u8 {
    const pct: u32 = @intFromFloat(std.math.clamp(fraction, 0.0, 1.0) * 100.0);
    return std.fmt.bufPrint(buf, "{s}  {d}%", .{ prefix, pct }) catch "";
}

// --- Widget instances --------------------------------------------------------

// Shared focus-aware style pairs. Each focusable bordered pane uses the
// same border and label styling, declared once.
const border_styles = zest.ByFocus(zest.DefaultStyle){
    .focused   = .{ .fg = .color_4 },
    .unfocused = .{ .fg = .color_8 },
};
const label_styles = zest.ByFocus(zest.DefaultStyle){
    .focused   = .{ .fg = .color_4, .text = .{ .bold = true } },
    .unfocused = .{},
};

const progress_bar = zest.ProgressBar(zest.Color){
    .filled_style = .{ .fg = .color_2 }, // green
};

// Vertical level meter on the right side of the bottom strip; fraction
// tracks the sidebar's selected file so moving the cursor raises the fill.
const loading_gauge = zest.Gauge(zest.Color){
    .orientation  = .vertical,
    .filled_style = .{ .fg = .color_4 }, // blue
};

const progress_sparkline = zest.Sparkline(zest.Color){
    .style = .{ .fg = .color_2 }, // green
};

const title_bar = zest.TitleBar(zest.Color){};

// --- Showcase widget instances ----------------------------------------------
//
// Multiple ProgressBar / Gauge / Sparkline instances with distinct styles
// let the showcase pane demonstrate the visual variety the widgets cover —
// different colours, orientations, fill levels — without re-typing the
// construction.

const showcase_bar_green  = zest.ProgressBar(zest.Color){ .filled_style = .{ .fg = .color_2 } };
const showcase_bar_blue   = zest.ProgressBar(zest.Color){ .filled_style = .{ .fg = .color_4 } };
const showcase_bar_purple = zest.ProgressBar(zest.Color){ .filled_style = .{ .fg = .color_5 } };

const showcase_h_gauge_green  = zest.Gauge(zest.Color){ .orientation = .horizontal, .filled_style = .{ .fg = .color_2 } };
const showcase_h_gauge_yellow = zest.Gauge(zest.Color){ .orientation = .horizontal, .filled_style = .{ .fg = .color_3 } };
const showcase_h_gauge_red    = zest.Gauge(zest.Color){ .orientation = .horizontal, .filled_style = .{ .fg = .color_1 } };

const showcase_v_gauge_blue   = zest.Gauge(zest.Color){ .orientation = .vertical, .filled_style = .{ .fg = .color_4 } };
const showcase_v_gauge_green  = zest.Gauge(zest.Color){ .orientation = .vertical, .filled_style = .{ .fg = .color_2 } };
const showcase_v_gauge_purple = zest.Gauge(zest.Color){ .orientation = .vertical, .filled_style = .{ .fg = .color_5 } };

// --- Dashboard widget instances ---------------------------------------------

const cpu_gauge = zest.Gauge(zest.Color){
    .orientation  = .horizontal,
    .filled_style = .{ .fg = .color_2 }, // green
};
const ram_gauge = zest.Gauge(zest.Color){
    .orientation  = .horizontal,
    .filled_style = .{ .fg = .color_4 }, // blue
};
const net_sparkline = zest.Sparkline(zest.Color){
    .style = .{ .fg = .color_5 },
};

// Showcase table — three columns demonstrating mixed Size variants and
// per-column alignment. Selection highlight uses the same widget theme
// the sidebar list consumes, so the focused row reads consistently.
const showcase_table_columns = [_]zest.TableColumn(zest.Color){
    .{ .header = "Widget",   .size = .{ .fraction = 2 } },
    .{ .header = "Frames",   .size = .{ .fixed = 8 }, .alignment = .right },
    .{ .header = "Notes",    .size = .{ .fraction = 3 } },
};
const showcase_table_rows = [_][]const []const u8{
    &.{ "ProgressBar(C)", "1",  "sub-cell precision"   },
    &.{ "Gauge(C)",       "1",  "horizontal / vertical" },
    &.{ "Spinner(C)",     "8",  "frame sets"           },
};

// --- Draw --------------------------------------------------------------------

/// Widget gallery — each library widget rendered in several
/// configurations so a reader can see at a glance what the framework
/// ships. Sections short-circuit if they would exceed `inner.height`
/// so a small terminal degrades gracefully (top sections show, lower
/// sections clip).
/// Widget gallery — each library widget rendered in several
/// configurations on the terminal's default background so the
/// colours of the widgets themselves carry the visual. Sections
/// short-circuit on `inner.height` so a small terminal degrades
/// gracefully — top sections show, lower ones clip.
fn drawShowcase(
    win: vaxis.Window,
    focused: bool,
    selected_file: []const u8,
    theme: zest.DefaultTheme,
    state: *State,
) void {
    const inner = win.child(.{
        .border = .{ .where = .all, .style = theme.resolve(border_styles.pick(focused)) },
    });
    if (inner.height == 0) return;

    // Title row — widget name in focus accent, file path in muted body text.
    _ = inner.print(&.{
        .{ .text = "showcase  ",
           .style = theme.resolve(zest.DefaultStyle{
               .fg   = if (focused) .color_4 else null,
               .text = .{ .bold = focused },
           }) },
        .{ .text = selected_file,
           .style = theme.resolve(zest.DefaultStyle{ .fg = .color_7 }) },
    }, .{ .row_offset = 0 });

    var row: u16 = 2;
    if (row >= inner.height) return;

    // --- helpers -----------------------------------------------------------

    const header = struct {
        fn write(w: vaxis.Window, t: zest.DefaultTheme, r: u16, name: []const u8, accent: zest.Color, desc: []const u8) void {
            _ = w.print(&.{
                .{ .text = name,
                   .style = t.resolve(zest.DefaultStyle{ .fg = accent, .text = .{ .bold = true } }) },
                .{ .text = "  ·  ",
                   .style = t.resolve(zest.DefaultStyle{ .fg = .color_8 }) },
                .{ .text = desc,
                   .style = t.resolve(zest.DefaultStyle{ .fg = .color_8 }) },
            }, .{ .row_offset = r });
        }
    };

    // --- ProgressBar(C) ----------------------------------------------------
    header.write(inner, theme, row, "ProgressBar(C)", .color_2,
        "determinate, 1/8 sub-cell precision, overlaid label");
    row += 1;
    if (row >= inner.height) return;

    const bars = [_]struct {
        bar:           zest.ProgressBar(zest.Color),
        frac:          f32,
        bg_fill:       zest.Color,
        label_buf_idx: usize,
    }{
        .{ .bar = showcase_bar_green,  .frac = 0.20, .bg_fill = .color_2, .label_buf_idx = 0 },
        .{ .bar = showcase_bar_blue,   .frac = 0.55, .bg_fill = .color_4, .label_buf_idx = 1 },
        .{ .bar = showcase_bar_purple, .frac = 0.85, .bg_fill = .color_5, .label_buf_idx = 2 },
    };
    for (bars) |b| {
        if (row >= inner.height) return;
        const bar_win = inner.child(.{ .x_off = 2, .y_off = row, .height = 1, .width = inner.width -| 4 });
        const label = fmtPct(state.showcase_label_bufs[b.label_buf_idx][0..], b.frac);
        b.bar.draw(bar_win, b.frac, theme, .{
            .text       = label,
            .in_filled  = .{ .fg = .background, .bg = b.bg_fill,  .text = .{ .bold = true } },
            .in_partial = .{ .fg = .color_7,    .bg = .color_8,   .text = .{ .bold = true } },
            .in_empty   = .{ .fg = .color_7,                       .text = .{ .bold = true } },
        });
        row += 1;
    }
    row += 1;

    // --- Gauge(C) horizontal ----------------------------------------------
    if (row >= inner.height) return;
    header.write(inner, theme, row, "Gauge(C) horizontal", .color_3,
        "same eighths math, any aspect ratio");
    row += 1;

    const h_gauges = [_]struct {
        gauge:   zest.Gauge(zest.Color),
        frac:    f32,
        caption: []const u8,
    }{
        .{ .gauge = showcase_h_gauge_green,  .frac = 0.25, .caption = "  CPU   25%" },
        .{ .gauge = showcase_h_gauge_yellow, .frac = 0.60, .caption = "  RAM   60%" },
        .{ .gauge = showcase_h_gauge_red,    .frac = 0.92, .caption = "  DISK  92%" },
    };
    for (h_gauges) |h| {
        if (row >= inner.height) return;
        const gauge_width: u16 = @min(@as(u16, 24), (inner.width -| 4) / 2);
        const gauge_win = inner.child(.{ .x_off = 2, .y_off = row, .height = 1, .width = gauge_width });
        h.gauge.draw(gauge_win, h.frac, theme, .{});
        const cap_win = inner.child(.{ .x_off = 2 + gauge_width, .y_off = row, .height = 1 });
        zest.Text.draw(cap_win, h.caption,
            zest.DefaultStyle{ .fg = .color_7 }, theme, .{});
        row += 1;
    }
    row += 1;

    // --- Gauge(C) vertical -----------------------------------------------
    if (row >= inner.height) return;
    header.write(inner, theme, row, "Gauge(C) vertical", .color_4,
        "level meters, bottom-anchored fill");
    row += 1;

    const v_gauge_block_height: u16 = 5;
    const v_gauges = [_]struct {
        gauge: zest.Gauge(zest.Color),
        frac:  f32,
        label: []const u8,
    }{
        .{ .gauge = showcase_v_gauge_blue,   .frac = 0.30, .label = "30%" },
        .{ .gauge = showcase_v_gauge_green,  .frac = 0.65, .label = "65%" },
        .{ .gauge = showcase_v_gauge_purple, .frac = 0.95, .label = "95%" },
    };
    var v_col: u16 = 2;
    for (v_gauges) |vg| {
        if (row + v_gauge_block_height > inner.height) break;
        const v_win = inner.child(.{
            .x_off  = v_col,
            .y_off  = row,
            .width  = 4,
            .height = v_gauge_block_height,
        });
        vg.gauge.draw(v_win, vg.frac, theme, .{
            .text  = vg.label,
            .style = .{ .fg = .color_7, .text = .{ .bold = true } },
        });
        v_col += 6;
    }
    row += v_gauge_block_height + 1;

    // --- Spinner(C) ------------------------------------------------------
    //
    // 2x4 grid of all eight built-in frame sets, all sharing
    // state.spinner.frame_index (mod each set's length) so the grid
    // animates in lockstep with the footer spinner.
    if (row >= inner.height) return;
    header.write(inner, theme, row, "Spinner(C)", .color_3,
        "8 built-in frame sets, advance once per tick");
    row += 1;

    const sp_specs = [_]struct {
        frames: []const []const u8,
        fg:     zest.Color,
        label:  []const u8,
    }{
        // Row 1
        .{ .frames = zest.spinner_frames.braille,  .fg = .color_4, .label = "braille"  },
        .{ .frames = zest.spinner_frames.line,     .fg = .color_2, .label = "line"     },
        .{ .frames = zest.spinner_frames.pulse,    .fg = .color_5, .label = "pulse"    },
        .{ .frames = zest.spinner_frames.dots,     .fg = .color_6, .label = "dots"     },
        // Row 2
        .{ .frames = zest.spinner_frames.arc,      .fg = .color_3, .label = "arc"      },
        .{ .frames = zest.spinner_frames.circle,   .fg = .color_4, .label = "circle"   },
        .{ .frames = zest.spinner_frames.triangle, .fg = .color_1, .label = "triangle" },
        .{ .frames = zest.spinner_frames.block,    .fg = .color_2, .label = "block"    },
    };
    const sp_cols: u16 = 4;
    const sp_cell_w: u16 = (inner.width -| 4) / sp_cols;
    for (sp_specs, 0..) |sp, i| {
        const grid_row = @as(u16, @intCast(i / sp_cols));
        const grid_col = @as(u16, @intCast(i % sp_cols));
        const sp_row = row + grid_row;
        if (sp_row >= inner.height) break;
        const sp_x = 2 + grid_col * sp_cell_w;
        if (sp_x >= inner.width) continue;
        const sp_win = inner.child(.{ .x_off = sp_x, .y_off = sp_row, .height = 1 });
        const spinner = zest.Spinner(zest.Color){
            .frames      = sp.frames,
            .frame_index = (state.tick_counter / 4) % sp.frames.len,
            .style       = .{ .fg = sp.fg, .text = .{ .bold = true } },
        };
        spinner.draw(sp_win, theme);
        const lbl_win = inner.child(.{ .x_off = sp_x + 2, .y_off = sp_row, .height = 1 });
        zest.Text.draw(lbl_win, sp.label,
            zest.DefaultStyle{ .fg = .color_7 }, theme, .{});
    }
    row += 2 + 1;

    // --- Sparkline(C) -----------------------------------------------------
    if (row >= inner.height) return;
    header.write(inner, theme, row, "Sparkline(C)", .color_5,
        "9-level data viz, right-edge anchored");
    row += 1;

    // Synthetic sine wave + live progress_history.
    if (row < inner.height) {
        var sine: [80]f32 = undefined;
        for (&sine, 0..) |*v, i| {
            v.* = 0.5 + 0.4 * @sin(@as(f32, @floatFromInt(i)) * 0.35);
        }
        const sl_win = inner.child(.{ .x_off = 2, .y_off = row, .height = 1, .width = inner.width -| 4 });
        const sl = zest.Sparkline(zest.Color){ .style = .{ .fg = .color_4 } };
        sl.draw(sl_win, &sine, theme);
        row += 1;
    }
    if (row < inner.height) {
        const sl_win = inner.child(.{ .x_off = 2, .y_off = row, .height = 1, .width = inner.width -| 4 });
        const sl = zest.Sparkline(zest.Color){ .style = .{ .fg = .color_2 } };
        sl.draw(sl_win, &state.progress_history, theme);
        row += 1;
    }
    row += 1;

    // --- Table(C) ---------------------------------------------------------
    if (row >= inner.height) return;
    header.write(inner, theme, row, "Table(C)", .color_3,
        "column-typed data grid with selection highlight");
    row += 1;

    // Static showcase table — header row plus the three sample rows.
    // Renders the selection highlight using the demo's mocha widget
    // theme; the focused flag is wired to the showcase pane's own
    // focused state so toggling Ctrl-W shifts the highlight intensity
    // alongside the panel border.
    if (row + 4 <= inner.height) {
        const tbl_win = inner.child(.{
            .x_off  = 2,
            .y_off  = row,
            .width  = inner.width -| 4,
            .height = 4,
        });
        state.showcase_table.draw(tbl_win, &showcase_table_rows, focused, theme);
        row += 5;
    }

    // --- TitleBar(C) caps variants ---------------------------------------
    if (row >= inner.height) return;
    header.write(inner, theme, row, "TitleBar(C)", .color_6,
        "flat / round / slant / custom cap shapes");
    row += 1;

    if (row < inner.height) {
        const cap_specs = [_]struct {
            caps:  zest.TitleCaps,
            label: []const u8,
        }{
            .{ .caps = .none,                          .label = "flat"   },
            .{ .caps = .round,                         .label = "round"  },
            .{ .caps = .slant,                         .label = "slant"  },
            .{ .caps = .{ .custom = .{ "(", ")" } },   .label = "custom" },
        };
        const cell_w: u16 = inner.width / @as(u16, cap_specs.len);
        for (cap_specs, 0..) |cap, i| {
            const cell_x: u16 = @as(u16, @intCast(i)) * cell_w;
            const cell_win = inner.child(.{
                .x_off  = cell_x,
                .y_off  = row,
                .width  = cell_w,
                .height = 1,
            });
            title_bar.draw(cell_win, theme, .{
                .text  = " zest demo ",
                .style = .{ .fg = .background, .bg = .color_3, .text = .{ .bold = true } },
                .caps  = cap.caps,
            });
            if (row + 1 < inner.height) {
                const cap_win = inner.child(.{
                    .x_off  = cell_x,
                    .y_off  = row + 1,
                    .width  = cell_w,
                    .height = 1,
                });
                zest.Text.draw(cap_win, cap.label,
                    zest.DefaultStyle{ .fg = .color_8 }, theme,
                    .{ .anchor = .{ .horizontal = .center, .vertical = .top } });
            }
        }
        row += 2;
    }
}

fn drawSidebarPane(panel: zest.Panel, label: []const u8, theme: zest.DefaultTheme) vaxis.Window {
    const inner = panel.win.child(.{
        .border = .{ .where = .all, .style = theme.resolve(border_styles.pick(panel.focused)) },
    });
    if (inner.height > 0) {
        zest.Text.draw(inner, label, label_styles.pick(panel.focused), theme, .{});
    }
    return inner;
}

fn draw(state: *State, win: vaxis.Window) void {
    win.clear();

    const theme: zest.DefaultTheme = if (state.no_color)
        zest.DefaultTheme.noColor()
    else if (state.color_scheme == .dark)
        zest.catppuccin_mocha
    else
        zest.catppuccin_latte;

    // Frame regions: header, tab strip, content area, footer.
    const header_win  = win.child(.{ .y_off = 0,                       .height = header_h });
    const tabs_win    = win.child(.{ .y_off = header_h,                .height = tabs_h });
    const content_y:    u16 = header_h + tabs_h;
    const content_hgt:  u16 = win.height -| chrome_h;
    const content_win = win.child(.{ .y_off = content_y,               .height = content_hgt });
    const footer_win  = win.child(.{ .y_off = win.height -| footer_h,  .height = footer_h });

    // Header
    title_bar.draw(header_win, theme, .{
        .text  = " Zest ",
        .style = .{ .fg = .background, .bg = .color_3, .text = .{ .bold = true } },
        .caps  = .round,
    });

    // Tab strip
    state.tab.draw(tabs_win, theme);

    // Active tab content
    switch (state.tab.active) {
        0 => drawShowcaseTab(state, content_win, theme),
        1 => drawDashboardTab(state, content_win, theme),
        else => {},
    }

    // Footer: spinner glyph at col 0, keybindings hint two cols over.
    state.spinner.draw(footer_win, theme);
    const footer_keys = footer_win.child(.{
        .x_off = 2,
        .width = footer_win.width -| 2,
    });
    zest.Text.draw(footer_keys,
        "h/l: tab  j/k: navigate  ?: help  q: quit",
        zest.DefaultStyle{ .fg = .color_7 }, theme, .{});

    // Help popup overlays the active tab when open. Drawn last so
    // it sits above the tab content and the footer is still
    // visible underneath the dim.
    drawHelpPopup(state, win, theme);
}

fn drawHelpPopup(state: *State, win: vaxis.Window, theme: zest.DefaultTheme) void {
    const body_opt = state.help_popup.draw(win, theme);
    const body = body_opt orelse return;
    if (body.height == 0) return;
    const lines = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "  h / l",   .desc = "Switch tabs (Showcase / Dashboard)"   },
        .{ .key = "  j / k",   .desc = "Navigate the focused list or table"   },
        .{ .key = "  Ctrl-W",  .desc = "Switch domain (sidebar / main)"       },
        .{ .key = "  1 - 4",   .desc = "Jump to sidebar pane (Showcase tab)"  },
        .{ .key = "  0",       .desc = "Jump to the main pane (Showcase tab)" },
        .{ .key = "  ?",       .desc = "Toggle this help"                     },
        .{ .key = "  Esc",     .desc = "Close this popup"                     },
        .{ .key = "  q",       .desc = "Quit"                                 },
    };
    var row: u16 = 0;
    for (lines) |l| {
        if (row >= body.height) break;
        _ = body.print(&.{
            .{ .text = l.key,
               .style = theme.resolve(zest.DefaultStyle{ .fg = .color_4, .text = .{ .bold = true } }) },
            .{ .text = "   ",
               .style = theme.resolve(zest.DefaultStyle{ .fg = .color_8 }) },
            .{ .text = l.desc,
               .style = theme.resolve(zest.DefaultStyle{ .fg = .color_7 }) },
        }, .{ .row_offset = row });
        row += 1;
    }
}

fn drawShowcaseTab(state: *State, content_win: vaxis.Window, theme: zest.DefaultTheme) void {
    if (content_win.width == 0 or content_win.height == 0) return;

    const p = zest.Layout.panelsFromState(showcase_layout, content_win,
        .{ .x = 0, .y = 0, .width = content_win.width, .height = content_win.height },
        &state.focus);

    const files_inner = drawSidebarPane(p.files,    "1 files",    theme);
    _ = drawSidebarPane(p.branches, "2 branches", theme);
    _ = drawSidebarPane(p.commits,  "3 commits",  theme);
    _ = drawSidebarPane(p.stash,    "4 stash",    theme);

    const list_win = files_inner.child(.{ .y_off = 1, .height = files_inner.height -| 1 });
    state.files_list.draw(list_win, &files_items, p.files.focused, theme);

    drawShowcase(p.showcase.win, p.showcase.focused,
        files_items[state.files_list.selected], theme, state);

    // Progress bar with a centred percentage label.
    const pct_text = fmtPct(&state.progress_text_buf, state.progress_fraction);
    progress_bar.draw(p.progress.win, state.progress_fraction, theme, .{
        .text       = pct_text,
        .in_filled  = .{ .fg = .background, .bg = .color_2, .text = .{ .bold = true } },
        .in_partial = .{ .fg = .color_7,    .bg = .color_8, .text = .{ .bold = true } },
        .in_empty   = .{ .fg = .color_7,                    .text = .{ .bold = true } },
    });

    // Gauge fraction tracks the sidebar's selected file.
    const loading_fraction = if (files_items.len > 0)
        @as(f32, @floatFromInt(state.files_list.selected + 1)) /
        @as(f32, @floatFromInt(files_items.len))
    else
        0.0;
    const gauge_text = fmtPct(&state.gauge_text_buf, loading_fraction);
    loading_gauge.draw(p.loading.win, loading_fraction, theme, .{
        .text  = gauge_text,
        .style = .{ .fg = .foreground, .text = .{ .bold = true } },
    });

    progress_sparkline.draw(p.log.win, &state.progress_history, theme);
}

fn drawDashboardTab(state: *State, content_win: vaxis.Window, theme: zest.DefaultTheme) void {
    if (content_win.width == 0 or content_win.height == 0) return;

    const p = zest.Layout.panelsFromState(dashboard_layout, content_win,
        .{ .x = 0, .y = 0, .width = content_win.width, .height = content_win.height },
        &state.dashboard_focus);

    drawDashboardOverview(state, p.overview.win, theme);
    drawDashboardNetwork(state, p.network.win, theme);
    state.dashboard_table.draw(p.processes.win, &process_rows, p.processes.focused, theme);
}

fn drawDashboardOverview(state: *State, win: vaxis.Window, theme: zest.DefaultTheme) void {
    if (win.height == 0) return;
    const half_w: u16 = win.width / 2;
    if (half_w < 6) return;

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

fn drawDashboardNetwork(state: *State, win: vaxis.Window, theme: zest.DefaultTheme) void {
    if (win.height == 0 or win.width == 0) return;
    const latest = std.math.clamp(
        state.net_history[state.net_history.len - 1],
        0.0,
        1.0,
    );
    const kbps: u32 = @intFromFloat(latest * net_peak_kbps);
    const label = std.fmt.bufPrint(
        &state.net_label_buf,
        "Network  ·  {d} KB/s",
        .{kbps},
    ) catch "";
    zest.Text.draw(win, label,
        zest.DefaultStyle{ .fg = .color_7, .text = .{ .bold = true } }, theme, .{});
    if (win.height >= 3) {
        const sl_y: u16 = win.height - 1;
        const sl_win = win.child(.{ .y_off = sl_y, .height = 1 });
        net_sparkline.draw(sl_win, &state.net_history, theme);
    }
}

fn update(state: *State, event: zest.Event, alloc: std.mem.Allocator) zest.UpdateResult {
    _ = alloc;
    switch (event) {
        .key_press => |key| {
            // Help popup gets first refusal on every key. Esc-while-
            // open closes it (handleKey returns true); other keys
            // while open fall through to nothing — the popup is
            // modal, so the tab content shouldn't see them.
            if (state.help_popup.handleKey(key)) return .redraw;
            if (state.help_popup.is_open) {
                // Modal: swallow non-Esc keys.
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;
                return .idle;
            }
            if (key.matches('?', .{})) {
                state.help_popup.toggle();
                return .redraw;
            }
            if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return .quit;

            // Tab strip nav: h / l and arrow left / right.
            const is_tab_key = key.matches('h', .{}) or key.matches('l', .{})
                or key.matches(vaxis.Key.left, .{}) or key.matches(vaxis.Key.right, .{});
            if (is_tab_key) {
                state.tab.handleKey(key);
                return .redraw;
            }

            // Per-tab content routing.
            switch (state.tab.active) {
                0 => return updateShowcaseTab(state, key),
                1 => return updateDashboardTab(state, key),
                else => return .idle,
            }
        },
        .winsize, .focus_changed => return .redraw,
        .color_scheme => |cs| {
            state.color_scheme = cs;
            state.files_list.widget_theme = if (cs == .dark) zest.mocha_widget else zest.latte_widget;
            return .redraw;
        },
        .tick => {
            // ~5 ticks/sec at the demo's 100 ms interval. Step is 0.005 so
            // one full bar cycle takes 20 s. Spinner advances once per
            // tick — best-effort cadence, may lurch under load.
            state.progress_fraction = @mod(state.progress_fraction + 0.005, 1.0);
            state.spinner.advance();
            state.tick_counter +%= 1;
            // Shift the showcase history buffer left by one and append the
            // latest sample on the right. Demo simplification — see field doc.
            std.mem.copyForwards(
                f32,
                state.progress_history[0 .. state.progress_history.len - 1],
                state.progress_history[1..],
            );
            state.progress_history[state.progress_history.len - 1] = state.progress_fraction;

            // Dashboard mock walks — sine-driven so the gauges always
            // have something to show without depending on real sysinfo.
            const t: f32 = @as(f32, @floatFromInt(state.tick_counter)) * 0.05;
            state.cpu_fraction = 0.5 + 0.4 * @sin(t);
            state.ram_fraction = 0.4 + 0.2 * @sin(t * 0.3);
            std.mem.copyForwards(
                f32,
                state.net_history[0 .. state.net_history.len - 1],
                state.net_history[1..],
            );
            state.net_history[state.net_history.len - 1] = std.math.clamp(
                0.3 + 0.3 * @sin(t * 0.7) + 0.2 * @sin(t * 2.1),
                0.0,
                1.0,
            );
            return .redraw;
        },
        else => return .idle,
    }
}

fn updateDashboardTab(state: *State, key: vaxis.Key) zest.UpdateResult {
    switch (key.codepoint) {
        'j', 'k', vaxis.Key.down, vaxis.Key.up => {
            state.dashboard_table.handleKey(key, process_rows.len);
            return .redraw;
        },
        else => return .idle,
    }
}

fn updateShowcaseTab(state: *State, key: vaxis.Key) zest.UpdateResult {
    if (key.matches('w', .{ .ctrl = true })) {
        state.focus.active_domain = if (state.focus.active_domain == .sidebar) .main else .sidebar;
        return .redraw;
    }
    switch (key.codepoint) {
        'j', 'k', vaxis.Key.down, vaxis.Key.up => {
            if (state.focus.active_domain == .sidebar and state.focus.sidebar.is(.files)) {
                state.files_list.handleKey(key, files_items.len);
            } else if (state.focus.active_domain == .main) {
                state.showcase_table.handleKey(key, showcase_table_rows.len);
            }
            return .redraw;
        },
        '0' => {
            state.focus.active_domain = .main;
            state.focus.main.set(.showcase);
        },
        '1'...'4' => |ch| {
            state.focus.active_domain = .sidebar;
            state.focus.sidebar.set(switch (ch) {
                '1' => .files,
                '2' => .branches,
                '3' => .commits,
                '4' => .stash,
                else => unreachable,
            });
        },
        else => return .idle,
    }
    return .redraw;
}

pub fn main(init: std.process.Init) !void {
    var tty_buf: [4096]u8 = undefined;
    var app = try zest.App.init(init.io, init.gpa, init.environ_map, &tty_buf);
    defer app.deinit();

    // NO_COLOR convention (https://no-color.org): if the variable is
    // present and non-empty, the user has asked for colour output to
    // be suppressed. Read once at startup.
    const no_color = if (init.environ_map.get("NO_COLOR")) |v| v.len > 0 else false;

    var state: State = .{
        .focus             = zest.Layout.focusStateInit(showcase_layout),
        .color_scheme      = .dark,
        .files_list        = .{ .widget_theme = zest.mocha_widget },
        .progress_fraction = 0.0,
        .spinner           = .{ .style = .{ .fg = .color_4 } },
        .progress_history  = .{0.0} ** 80,
        .no_color          = no_color,
        .progress_text_buf = undefined,
        .gauge_text_buf    = undefined,
        .showcase_label_bufs = undefined,
        .showcase_table      = .{
            .columns        = &showcase_table_columns,
            // Header sits on its own banded background so the column
            // titles read as a separate strip from the data rows.
            .header_style   = .{ .fg = .color_3, .bg = .color_8, .text = .{ .bold = true } },
            .cell_style     = .{ .fg = .color_7 },
            // Subtle zebra stripe — odd rows pick up the elevated
            // surface bg so adjacent rows are easy to scan.
            .alt_cell_style = .{ .fg = .color_7, .bg = .color_0 },
            .widget_theme   = zest.mocha_widget,
            .selected       = 1,
        },
        .tick_counter      = 0,
        .tab               = .{
            .labels         = &tab_labels,
            .active_style   = .{ .fg = .color_4, .text = .{ .bold = true } },
            .inactive_style = .{ .fg = .color_8 },
        },
        .dashboard_focus   = zest.Layout.focusStateInit(dashboard_layout),
        .dashboard_table   = .{
            .columns        = &process_columns,
            .header_style   = .{ .fg = .color_3, .bg = .color_8, .text = .{ .bold = true } },
            .cell_style     = .{ .fg = .color_7 },
            .alt_cell_style = .{ .fg = .color_7, .bg = .color_0 },
            .widget_theme   = zest.mocha_widget,
        },
        .cpu_fraction      = 0.0,
        .ram_fraction      = 0.0,
        .net_history       = .{0.0} ** 80,
        .cpu_label_buf     = undefined,
        .ram_label_buf     = undefined,
        .net_label_buf     = undefined,
        .help_popup        = .{
            .width          = .{ .percent = 60 },
            .height         = .{ .percent = 60 },
            .title          = " Help ",
            .title_style    = .{ .fg = .background, .bg = .color_4, .text = .{ .bold = true } },
            .border_style   = .{ .fg = .color_4 },
            .body_style     = .{ .bg = .color_0 },
            .backdrop_style = .{},
        },
    };

    try app.run(&state, activeFocus, update, draw, .{
        .tick_interval = .fromMilliseconds(100),
    });
}
