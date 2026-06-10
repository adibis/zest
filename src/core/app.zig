//! Application entry point and event loop.
//!
//! App owns the three resources that make a terminal application run:
//! the TTY (raw terminal device), the Vaxis instance (rendering engine),
//! and the FrameArena (per-frame allocator). The user provides an update
//! function; App drives everything else.

const std = @import("std");
const vaxis = @import("vaxis");
const FrameArena = @import("memory.zig").FrameArena;

pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
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
    /// `ctx` is `anytype` — Zig resolves the concrete type at each call site
    /// and generates a specialised version of run(). `comptime update` means
    /// the function pointer is resolved at compile time, enabling inlining
    /// with no indirect call overhead in the render loop.
    pub fn run(
        self: *App,
        ctx: anytype,
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

        while (true) {
            const event = try loop.nextEvent();
            self.frame_arena.reset();

            if (event == .winsize) {
                try self.vx.resize(self.alloc, self.tty.writer(), event.winsize);
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

test "App: init and deinit" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();

    var tty_buf: [64]u8 = undefined;
    var app = try App.init(io, std.testing.allocator, &env_map, &tty_buf);
    defer app.deinit();
}
