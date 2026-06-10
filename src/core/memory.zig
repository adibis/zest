const std = @import("std");

pub const FrameArena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator) FrameArena {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *FrameArena) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *FrameArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Free all per-frame allocations. Call at the start of each render pass.
    pub fn reset(self: *FrameArena) void {
        _ = self.arena.reset(.free_all);
    }
};

test "FrameArena: allocate within frame" {
    var fa = FrameArena.init(std.testing.allocator);
    defer fa.deinit();

    const alloc = fa.allocator();
    const buf = try alloc.alloc(u8, 64);
    try std.testing.expectEqual(@as(usize, 64), buf.len);
}

test "FrameArena: reset frees and allows re-allocation" {
    var fa = FrameArena.init(std.testing.allocator);
    defer fa.deinit();

    const alloc = fa.allocator();
    _ = try alloc.alloc(u8, 128);
    fa.reset();

    const buf2 = try alloc.alloc(u8, 32);
    try std.testing.expectEqual(@as(usize, 32), buf2.len);
}

test "FrameArena: multiple resets are safe" {
    var fa = FrameArena.init(std.testing.allocator);
    defer fa.deinit();

    fa.reset();
    fa.reset();
    fa.reset();

    const alloc = fa.allocator();
    _ = try alloc.alloc(u8, 8);
}
