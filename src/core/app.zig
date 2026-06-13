//! Application entry point and event loop.
//!
//! App owns the three resources that make a terminal application run:
//! the TTY (raw terminal device), the Vaxis instance (rendering engine),
//! and the FrameArena (per-frame allocator). The user provides an update
//! function; App drives everything else.

const std = @import("std");
const vaxis = @import("vaxis");
const FrameArena = @import("memory.zig").FrameArena;
const Focus      = @import("focus.zig").Focus;
const FocusStack = @import("focus.zig").FocusStack;

pub const Event = union(enum) {
    key_press:    vaxis.Key,
    mouse:        vaxis.Mouse,
    winsize:      vaxis.Winsize,
    focus_in,
    focus_out,
    focus_changed,
    /// Terminal reported its color scheme (dark/light). Fired once at startup
    /// if the terminal supports OSC color scheme queries, and again on change.
    color_scheme: vaxis.Color.Scheme,
};

pub const UpdateResult = enum { redraw, quit, idle };

pub const App = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    frame_arena: FrameArena,

    /// tty_buf is a caller-owned byte slice used as the TTY's write buffer.
    /// It must stay alive for the lifetime of the App. We take it from the
    /// caller (rather than allocating internally) so it can live on the
    /// caller's stack — no heap cost, and the pointer is guaranteed stable.
    pub fn init(
        io: std.Io,
        alloc: std.mem.Allocator,
        env_map: *std.process.Environ.Map,
        tty_buf: []u8,
    ) !App {
        var tty = try vaxis.Tty.init(io, tty_buf);
        // errdefer (not defer) because we only want to clean up tty if the
        // *next* call fails. If init succeeds, ownership transfers to App and
        // App.deinit() is responsible for cleanup instead.
        errdefer tty.deinit();
        const vx = try vaxis.init(io, alloc, env_map, .{});
        return .{
            .io = io,
            .alloc = alloc,
            .tty = tty,
            .vx = vx,
            .frame_arena = .init(alloc),
        };
    }

    pub fn deinit(self: *App) void {
        self.vx.deinit(self.alloc, self.tty.writer());
        self.tty.deinit();
        self.frame_arena.deinit();
    }

    /// Run the event loop. `ctx` is passed to every `update` call.
    /// `update` receives the event, the current root window, and a per-frame
    /// allocator (reset at the start of each frame). Return `.quit` to exit.
    ///
    /// `focus` is a pointer-to-pointer so multi-window apps can redirect it:
    /// keep one FocusStack per window, store `var active: *FocusStack` in your
    /// state, and reassign it in `update` when switching windows.
    pub fn run(
        self: *App,
        ctx: anytype,
        focus: **FocusStack,
        comptime update: fn (@TypeOf(ctx), Event, vaxis.Window, std.mem.Allocator) UpdateResult,
    ) !void {
        // loop is created here, not stored on App, because vaxis.Loop stores
        // *Tty and *Vaxis pointers internally. If loop were a field of App,
        // those pointers would be invalidated whenever App is moved in memory.
        // Keeping loop as a local variable guarantees self.tty and self.vx
        // are already at their final address before loop captures them.
        var loop: vaxis.Loop(Event) = .init(self.io, &self.tty, &self.vx);
        try loop.installResizeHandler();
        try loop.start();
        defer loop.stop();

        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), .fromSeconds(1));
        // Request the terminal's current color scheme; the response arrives as
        // a color_scheme event. No-op on terminals that don't support it.
        try self.vx.subscribeToColorSchemeUpdates(self.tty.writer());

        while (true) {
            const event = try loop.nextEvent();
            self.frame_arena.reset();

            if (event == .winsize) {
                try self.vx.resize(self.alloc, self.tty.writer(), event.winsize);
            }

            // Tab and Shift-Tab are consumed by the framework: they advance or
            // retreat focus, then fire focus_changed so update() re-renders with
            // the new focus state without pretending a resize occurred.
            if (tabConsumed(event, focus)) {
                const win = self.vx.window();
                const result = update(ctx, .focus_changed, win, self.frame_arena.allocator());
                if (result == .quit) break;
                if (result == .redraw) try self.vx.render(self.tty.writer());
                continue;
            }

            const win = self.vx.window();
            switch (update(ctx, event, win, self.frame_arena.allocator())) {
                .redraw => try self.vx.render(self.tty.writer()),
                .quit => break,
                .idle => {},
            }
        }
    }
};

/// Returns true and advances or retreats focus if event is Tab or Shift-Tab.
/// Returns false and leaves focus untouched for all other events.
fn tabConsumed(event: Event, focus: **FocusStack) bool {
    if (event != .key_press) return false;
    const key = event.key_press;
    const is_tab       = key.matches(vaxis.Key.tab, .{});
    const is_shift_tab = key.matches(vaxis.Key.tab, .{ .shift = true });
    if (!is_tab and !is_shift_tab) return false;
    if (is_tab) focus.*.top().next() else focus.*.top().prev();
    return true;
}

test "App: init and deinit" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    var tty_buf: [64]u8 = undefined;
    var app = try App.init(io, std.testing.allocator, &env_map, &tty_buf);
    defer app.deinit();
}

test "tabConsumed: Tab advances focus and returns true" {
    var fs = FocusStack.init(Focus.init(3));
    var focus = &fs;
    const tab_key: Event = .{ .key_press = .{ .codepoint = vaxis.Key.tab } };
    try std.testing.expect(tabConsumed(tab_key, &focus));
    try std.testing.expectEqual(1, fs.top().active());
}

test "tabConsumed: Shift-Tab retreats focus and returns true" {
    var fs = FocusStack.init(Focus.init(3));
    fs.top().set(2);
    var focus = &fs;
    const shift_tab: Event = .{ .key_press = .{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } } };
    try std.testing.expect(tabConsumed(shift_tab, &focus));
    try std.testing.expectEqual(1, fs.top().active());
}

test "tabConsumed: non-Tab key returns false and leaves focus unchanged" {
    var fs = FocusStack.init(Focus.init(3));
    var focus = &fs;
    const j_key: Event = .{ .key_press = .{ .codepoint = 'j' } };
    try std.testing.expect(!tabConsumed(j_key, &focus));
    try std.testing.expectEqual(0, fs.top().active());
}

test "tabConsumed: non-key event returns false and leaves focus unchanged" {
    var fs = FocusStack.init(Focus.init(3));
    var focus = &fs;
    try std.testing.expect(!tabConsumed(.focus_in, &focus));
    try std.testing.expectEqual(0, fs.top().active());
}
