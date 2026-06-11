//! Panel focus — owns navigation state (which panel is active).
//!
//! Focus manages which index is active. Call next()/prev() for Tab navigation,
//! set() for direct jumps (e.g. number keys), and is() for named slot
//! comparisons at render time without any runtime string hashing.

const std = @import("std");

pub const Focus = struct {
    count: usize,
    index: usize,

    pub fn init(count: usize) Focus {
        return .{ .count = count, .index = 0 };
    }

    /// Advance to the next panel, wrapping around to 0 after the last.
    /// No-op when count is 0 or 1.
    pub fn next(self: *Focus) void {
        if (self.count < 2) return;
        self.index = (self.index + 1) % self.count;
    }

    /// Retreat to the previous panel, wrapping around to count-1 before the first.
    /// No-op when count is 0 or 1.
    pub fn prev(self: *Focus) void {
        if (self.count < 2) return;
        self.index = (self.index + self.count - 1) % self.count;
    }

    /// Returns the index of the currently active panel.
    pub fn active(self: Focus) usize {
        return self.index;
    }

    /// Jump directly to `index`. Clamps to count-1; no-op when count is 0.
    pub fn set(self: *Focus, index: usize) void {
        if (self.count == 0) return;
        self.index = @min(index, self.count - 1);
    }

    /// Returns true if the slot named `id` is currently active.
    /// `ids` is the ordered list of focusable slot ids, e.g. &.{ "sidebar", "header", "body" }.
    pub fn is(self: Focus, comptime id: [:0]const u8, comptime ids: []const [:0]const u8) bool {
        inline for (ids, 0..) |slot_id, i| {
            if (comptime std.mem.eql(u8, slot_id, id)) return self.index == i;
        }
        return false;
    }
};

test "Focus: next advances and wraps around" {
    var f = Focus.init(3);
    f.next();
    try std.testing.expectEqual(@as(usize, 1), f.active());
    f.next();
    try std.testing.expectEqual(@as(usize, 2), f.active());
    f.next();
    try std.testing.expectEqual(@as(usize, 0), f.active());
}

test "Focus: prev retreats and wraps around" {
    var f = Focus.init(3);
    f.prev();
    try std.testing.expectEqual(@as(usize, 2), f.active());
    f.prev();
    try std.testing.expectEqual(@as(usize, 1), f.active());
}

test "Focus: single element stays fixed on next and prev" {
    var f = Focus.init(1);
    f.next();
    try std.testing.expectEqual(@as(usize, 0), f.active());
    f.prev();
    try std.testing.expectEqual(@as(usize, 0), f.active());
}

test "Focus: is() returns true for active slot, false for others" {
    var f = Focus.init(3);
    const ids = &.{ "sidebar", "header", "body" };
    try std.testing.expect(f.is("sidebar", ids));
    try std.testing.expect(!f.is("header", ids));
    f.next();
    try std.testing.expect(f.is("header", ids));
    try std.testing.expect(!f.is("sidebar", ids));
}

test "Focus: is() returns false for unknown id" {
    const f = Focus.init(2);
    try std.testing.expect(!f.is("unknown", &.{ "a", "b" }));
}

test "Focus: zero count is a no-op" {
    var f = Focus.init(0);
    f.next();
    try std.testing.expectEqual(@as(usize, 0), f.active());
    f.prev();
    try std.testing.expectEqual(@as(usize, 0), f.active());
}

test "Focus: set() jumps directly to index" {
    var f = Focus.init(3);
    f.set(2);
    try std.testing.expectEqual(@as(usize, 2), f.active());
    f.set(0);
    try std.testing.expectEqual(@as(usize, 0), f.active());
}

test "Focus: set() clamps when index >= count" {
    var f = Focus.init(3);
    f.set(5);
    try std.testing.expectEqual(@as(usize, 2), f.active());
}

test "Focus: set() is no-op when count is 0" {
    var f = Focus.init(0);
    f.set(1);
    try std.testing.expectEqual(@as(usize, 0), f.active());
}

/// A stack of Focus objects for hierarchical focus management.
/// push() installs a new Focus (e.g. for a modal dialog); pop() restores the previous one.
/// top() returns a pointer to the active Focus. Capacity is fixed at 8 levels.
///
/// For multi-window apps, keep one FocusStack per window and store a *FocusStack
/// pointer in your state. Point it at the active window's stack; App.run() receives
/// **FocusStack and always operates on whatever it currently points to.
pub const FocusStack = struct {
    levels: [8]Focus,
    depth: usize,

    pub fn init(base: Focus) FocusStack {
        var s: FocusStack = undefined;
        s.levels[0] = base;
        s.depth = 1;
        return s;
    }

    /// Returns a pointer to the active (top) Focus.
    pub fn top(self: *FocusStack) *Focus {
        std.debug.assert(self.depth > 0);
        return &self.levels[self.depth - 1];
    }

    /// Returns the active panel index on the top Focus. Const-safe — does not mutate.
    pub fn activeIndex(self: *const FocusStack) usize {
        std.debug.assert(self.depth > 0);
        return self.levels[self.depth - 1].index;
    }

    /// Pushes a new Focus onto the stack. Returns error.Overflow if full.
    pub fn push(self: *FocusStack, focus: Focus) error{Overflow}!void {
        if (self.depth >= self.levels.len) return error.Overflow;
        self.levels[self.depth] = focus;
        self.depth += 1;
    }

    /// Pops the top Focus. No-op if only the base Focus remains.
    pub fn pop(self: *FocusStack) void {
        if (self.depth > 1) self.depth -= 1;
    }

    /// Convenience wrapper: jumps the top Focus directly to `index`.
    pub fn set(self: *FocusStack, index: usize) void {
        self.top().set(index);
    }

    /// Returns true if the named slot is active on the top Focus.
    pub fn is(self: *const FocusStack, comptime id: [:0]const u8, comptime ids: []const [:0]const u8) bool {
        std.debug.assert(self.depth > 0);
        return self.levels[self.depth - 1].is(id, ids);
    }
};

test "FocusStack: top returns base Focus after init" {
    var s = FocusStack.init(Focus.init(3));
    try std.testing.expectEqual(@as(usize, 0), s.top().active());
}

test "FocusStack: push installs new Focus, pop restores previous" {
    var s = FocusStack.init(Focus.init(3));
    s.top().next();
    try std.testing.expectEqual(@as(usize, 1), s.top().active());
    try s.push(Focus.init(2));
    try std.testing.expectEqual(@as(usize, 0), s.top().active());
    s.pop();
    try std.testing.expectEqual(@as(usize, 1), s.top().active());
}

test "FocusStack: pop on base Focus is a no-op" {
    var s = FocusStack.init(Focus.init(2));
    s.pop();
    try std.testing.expectEqual(@as(usize, 1), s.depth);
}

test "FocusStack: push past capacity returns Overflow" {
    var s = FocusStack.init(Focus.init(1));
    var i: usize = 0;
    while (i < 7) : (i += 1) try s.push(Focus.init(1));
    try std.testing.expectError(error.Overflow, s.push(Focus.init(1)));
}
