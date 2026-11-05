const std = @import("std");

/// Surface presentation hints and libmpv consumption are separate lifecycles.
/// A hidden surface may never receive a frame callback until exposed again.
pub const Pacing = struct {
    pub const Action = enum { wait, draw, skip };
    started: bool = false,
    deferred: bool = false,

    pub fn action(self: Pacing, callback_pending: bool, media_update: bool, dirty: bool) Action {
        if (!self.started and !media_update) return .wait;
        if (callback_pending) return if (media_update) .skip else .wait;
        return if (media_update or dirty) .draw else .wait;
    }
    pub fn presented(self: *Pacing) void {
        self.started = true;
        self.deferred = false;
    }
    pub fn skipped(self: *Pacing) void {
        self.deferred = true;
    }
    /// Redraw the latest skipped frame once when presentation resumes.
    /// An ordinary callback alone must not start a redraw loop while paused.
    pub fn frameDone(self: *Pacing) bool {
        const redraw = self.deferred;
        self.deferred = false;
        return redraw;
    }
};

test "wait for a real initial frame and never stall libmpv behind withheld callbacks" {
    var p: Pacing = .{};
    try std.testing.expectEqual(Pacing.Action.wait, p.action(false, false, true));
    try std.testing.expectEqual(Pacing.Action.draw, p.action(false, true, true));
    p.presented();
    for (0..100) |_| {
        try std.testing.expectEqual(Pacing.Action.skip, p.action(true, true, false));
        p.skipped();
    }
    try std.testing.expectEqual(Pacing.Action.wait, p.action(true, false, false));
    try std.testing.expect(p.frameDone());
    try std.testing.expectEqual(Pacing.Action.draw, p.action(false, false, true));
    p.presented();
    try std.testing.expect(!p.frameDone());
    try std.testing.expectEqual(Pacing.Action.wait, p.action(false, false, false));
}

test "independent outputs do not share callback or deferred redraw state" {
    var hidden: Pacing = .{};
    var visible: Pacing = .{};
    hidden.presented();
    visible.presented();
    hidden.skipped();
    try std.testing.expectEqual(Pacing.Action.skip, hidden.action(true, true, false));
    try std.testing.expectEqual(Pacing.Action.draw, visible.action(false, true, false));
    try std.testing.expect(!visible.frameDone());
    try std.testing.expect(hidden.frameDone());
}
