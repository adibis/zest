# Zest

Declarative, high-level TUI framework for Zig — comptime layouts, zero heap per frame.

> **Status: Pre-alpha. Active development. Not ready for production use.**

---

## What is Zest?

Zest is a TUI framework for Zig that lets you build rich, beautiful terminal applications without writing layout math or touching terminal escape sequences. It sits above [`libvaxis`](https://github.com/rockorager/libvaxis) and handles everything between raw terminal I/O and your application logic.

The goal is to give Zig developers what Textual gives Python developers — a productive, expressive way to build terminal UIs with a clean component model, a design token styling system, and predictable performance.

---

## Core Ideas

### Comptime Panel Layouts

The structure of your screen — which panels go where — is declared as nested anonymous structs and validated at compile time. No layout math. No coordinate arithmetic. The framework resolves panel positions at render time using the actual terminal dimensions.

### Widgets Own Their State

Widgets are structs with explicit state — scroll position, cursor, selection index. Application data (the items a list displays, the rows a table renders) is passed in at draw time. This keeps widgets reusable and keeps your data model in control.

### Design Token Styling

Colors and text styles are expressed as named tokens (`primary`, `danger`, `surface`, `muted`) rather than raw color codes. A theme maps tokens to concrete terminal colors at render time. Invalid token usage fails at compile time.

### Single-Threaded First

Zest uses a straightforward single-threaded event loop: read event → update state → render. This makes the execution model easy to reason about and debug. Threading is planned as an opt-in feature after v1.0.

### Zero Heap Per Frame

All memory allocated during a render pass lives in a frame-scoped arena that is reset at the start of each frame. No per-frame heap fragmentation. No GC pressure.

---

## Roadmap

| Milestone | Scope | Status |
|---|---|---|
| 1 — Foundation | libvaxis wiring, event loop, frame arena, resize handling | 🔲 Planned |
| 2 — Layout Engine | Layout types, recursive solver, Box compositor widget | 🔲 Planned |
| 3 — Focus & Events | Focus ring, modal stack, event dispatch to widgets | 🔲 Planned |
| 4 — Core Widgets | Text, List (virtual scroll), theme system | 🔲 Planned |
| 5 — Table & Custom Widgets | Data grid, custom widget state protocol | 🔲 Planned |
| 6 — Release | Dashboard example, benchmark harness, docs, v0.1.0 | 🔲 Planned |

---

## Performance Targets

| Metric | Target |
|---|---|
| Resident Set Size (RSS) | < 12 MB |
| Frame layout latency (p99) | < 150 µs |
| Release binary size | < 4 MB |

Measured with `heaptrack` and `std.time.Timer` against the included dashboard example, built with `ReleaseSmall`.

---

## Dependencies

- [Zig](https://ziglang.org/) — pinned version specified in `build.zig.zon`
- [libvaxis](https://github.com/rockorager/libvaxis) — terminal I/O, screen diffing, cell rendering

No other runtime dependencies.

---

## What's Out of Scope for v0.1

- Multi-threading
- Animations or transitions
- Windows / ConPTY support (Linux and macOS only)
- Kitty graphics protocol (planned for v0.2)
- Accessibility

---

## License

MIT — see [LICENSE](LICENSE).
