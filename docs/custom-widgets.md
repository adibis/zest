# Writing Custom Widgets

This page documents the conventions every Zest built-in widget follows.
When the library doesn't ship the widget you need, write your own using
the same shape — the framework's contracts (Theme, Style, focus
stamping, frame arena, event routing) all fall into place.

The smallest possible example lives at
[`src/widgets/example_toggle.zig`](../src/widgets/example_toggle.zig).
Fork it as a starting point.

---

## The Protocol

A widget is a generic type returning a struct:

```zig
pub fn MyWidget(comptime C: type) type {
    return struct {
        // visual identity + persistent state, with defaults
        style: Style(C) = .{},
        cursor: usize = 0,

        const Self = @This();

        pub fn handleKey(self: *Self, key: vaxis.Key, ...) void { ... }
        pub fn draw(self: ..., win: vaxis.Window, ..., theme: Theme(C)) void { ... }
    };
}
```

Three things live on the struct:

| Kind | Examples | Why on the struct |
|---|---|---|
| **Visual identity** | `style`, `glyph_set`, `cap_shape` | Set once at construction; never changes per frame. |
| **Persistent state** | `cursor`, `scroll_offset`, `frame_index`, `is_on` | The widget owns it; `update` and `draw` both read/write it. |
| **Per-frame data** | *(not stored here)* | Passed positionally to `draw` — the data the widget paints this frame. |

Persistent state has defaults so `MyWidget(C){}` is immediately usable;
apps that want a non-default starting state override at construction.

---

## Generic over `C`

Every widget is `Widget(comptime C: type) type`. The `C` parameter is
the caller's `Color` enum; the framework's built-in palette is one
option, an app-defined enum is another. Inside the returned struct,
style fields are typed `Style(C)` and the resolved style is read off
a `Theme(C)` at draw time. The same widget code composes with any
palette the app picks.

Tests pin the contract by running the widget against both the
built-in `Color` and a user-defined enum — see the
`Toggle(C): works with a user-defined color enum` test in
`example_toggle.zig`.

---

## `draw` signature

```zig
pub fn draw(
    self: Self,            // or *Self if draw mutates state
    win: vaxis.Window,     // always first
    primary_data: ...,     // optional, widget-specific
    theme: Theme(C),       // always last (or last before opts)
    opts: WidgetOpts,      // optional, for variants
) void
```

Conventions:

- **Window first.** Every widget paints into a window the framework
  hands it; this is the only resource the widget actually owns at
  draw time.
- **Primary data is positional.** `ProgressBar` takes `fraction: f32`,
  `Sparkline` takes `values: []const f32`, `Table` takes `rows`. If
  the widget has no primary data, omit the parameter.
- **Theme last.** The active `Theme(C)` resolves `Style(C)` into the
  concrete `vaxis.Cell.Style` the widget writes.
- **Opts trailing.** A trailing `opts: WidgetOpts` struct is the
  pattern for label overlays, alignment hints, and other per-frame
  variations. See `ProgressBar.LabelOverlay`, `Gauge.Label`,
  `TitleBar.TitleOpts`.
- **`*Self` only when needed.** `self: Self` (const) is the default;
  use `*Self` when the widget mutates state during draw (`Table`
  adjusts `scroll_offset`, for example).

Every widget opens with a zero-size guard:

```zig
if (win.width == 0 or win.height == 0) return;
```

The framework hands out windows that may collapse to zero in either
dimension during resize; the guard is one line and avoids every
widget having to defend against it downstream.

---

## `handleKey` signature

```zig
pub fn handleKey(self: *Self, key: vaxis.Key, ...trailing args...) void
```

- Takes `*Self` — key handling almost always mutates state.
- Returns `void`. Apps route keys themselves; the widget reports
  state changes through its public fields, not a return value.
- Trailing args are widget-specific. `List(C).handleKey(key,
  item_count)` and `Table(C).handleKey(key, row_count)` both take the
  data length so the cursor can clamp without the widget having to
  hold a borrowed slice.

The split between `handleKey` (mutates state from `update`) and
`draw` (renders state into a window) is enforced by which function
the framework passes the window to. Calling `print()` from
`handleKey` is impossible because there is no window in scope.

---

## State + draw interplay

Widgets like `Table` and `List` have **scroll state** that needs to
react to both keypresses (the selection moves) and window resizes
(the visible row count changes). The pattern:

- `handleKey` knows about the data; it moves the cursor and clamps
  to `row_count`.
- `draw` knows about the window; it adjusts `scroll_offset` so the
  cursor stays visible.

`draw` takes `*Self` in that case. The split avoids `handleKey`
having to know the window dimensions and avoids `draw` having to
know the input semantics.

---

## Lifetime contracts

Strings passed to `print()` or `writeCell()` must outlive the frame
in which they were rendered. vaxis stores the grapheme slice on the
cell until the render-time flush. Three safe sources:

| Source | Safe? |
|---|---|
| String literals (`"text"`) | ✅ static lifetime |
| `state.scratch_buf[0..n]` formatted in `update` | ✅ lives in state |
| `state.scratch_buf[0..n]` formatted in `draw` synchronously before the print | ✅ if the synchronous loop guarantees nothing else writes the buf |
| Stack buffer in `draw` returned through `bufPrint` | ❌ goes out of scope before render |

See `progress_text_buf` on the demo's `State` struct, and the field
comments that document the synchronous-loop dependency.

---

## NaN safety

When a widget computes geometry from a caller-supplied `f32`, guard
against NaN before any `@intFromFloat`:

```zig
const sanitized = if (std.math.isNan(fraction)) 0.0 else fraction;
const clamped = std.math.clamp(sanitized, 0.0, 1.0);
const cells: u32 = @intFromFloat(@as(f32, @floatFromInt(extent)) * clamped);
```

`std.math.clamp` propagates NaN through IEEE 754, and
`@intFromFloat(NaN)` is illegal behavior — UB in `ReleaseFast`,
panic in `ReleaseSafe`. App code computing `done / total` with
`total == 0` is a normal source of NaN, so the widget must defend.
The framework's shared `subcell.Discretise(...).measure(...)` helper
does this once at the boundary for fill-based widgets.

---

## Testing

Tests sit inline at the bottom of the widget file. The pattern:

```zig
test "MyWidget.draw: <invariant>" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = N, .cols = M, .x_pixel = 0, .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const win = makeWin(&screen, M, N);

    const w: MyWidget(Color) = .{ ... };
    w.draw(win, theme_mod.catppuccin_mocha);

    try std.testing.expectEqualStrings("x", screen.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqual(want_fg,  screen.readCell(0, 0).?.style.fg);
}
```

The library widget files (`progress.zig`, `gauge.zig`, `sparkline.zig`,
`spinner.zig`, `title_bar.zig`, `table.zig`) all follow this shape and
are the best place to copy fixtures from.

Pyramidal coverage — many small contract-shaped tests, no `update +
render` integration tests (the latter would need a real TTY). Each
widget file ships 8 – 30 tests covering fraction = 0, fraction = 1,
fraction > 1, fraction < 0, NaN, zero-size window, custom color enum,
edge cases specific to the widget.

---

## See also

- `src/widgets/example_toggle.zig` — minimal worked example.
- `src/widgets/progress.zig` — opts-struct pattern + label overlay.
- `src/widgets/table.zig` — `handleKey`, scroll state, `*Self` draw.
- The "Core Ideas" section of [`README.md`](../README.md) — the
  framework-wide invariants (focus stamping, frame arena, focus
  domains) that custom widgets compose with.
