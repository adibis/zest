//! Public API surface for the zest library.
//!
//! This is the entry point consumers see when they write @import("zest").
//! All public types are re-exported here so callers never need to know
//! which internal file a type lives in.

const std = @import("std");

pub const App = @import("core/app.zig").App;
pub const Event = @import("core/app.zig").Event;
pub const UpdateResult = @import("core/app.zig").UpdateResult;
pub const FrameArena = @import("core/memory.zig").FrameArena;

pub const Rect = @import("layout/rect.zig").Rect;
pub const Size = @import("layout/size.zig").Size;
pub const Direction = @import("layout/slot.zig").Direction;
pub const PanelSlot = @import("layout/slot.zig").PanelSlot;

test {
    // Importing a file in a test block pulls its test blocks into the test
    // binary. Without these lines, tests in sub-files would compile but never
    // run when you execute `zig build test` against the root module.
    _ = @import("core/memory.zig");
    _ = @import("core/app.zig");
    _ = @import("layout/rect.zig");
    _ = @import("layout/size.zig");
    _ = @import("layout/slot.zig");
}
