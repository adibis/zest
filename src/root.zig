const std = @import("std");

pub const App = @import("core/app.zig").App;
pub const Event = @import("core/app.zig").Event;
pub const UpdateResult = @import("core/app.zig").UpdateResult;
pub const FrameArena = @import("core/memory.zig").FrameArena;

test {
    _ = @import("core/memory.zig");
    _ = @import("core/app.zig");
}
