const std = @import("std");

/// Worker-owned playback lifecycle; desired visibility is a separate atomic epoch.
/// Even epochs mean show, odd epochs mean hide. No new load crosses an unload
/// barrier, including when a load was interrupted before PLAYBACK_RESTART.
pub const Playback = struct {
    pub const Phase = enum { unloaded, loading, ready, stopping };
    pub const Action = enum { none, load, stop };
    phase: Phase = .unloaded,
    epoch: ?u64 = null,
    started: bool = false,

    pub fn next(self: *Playback, desired: u64) Action {
        switch (self.phase) {
            .stopping => return .none,
            .unloaded => {
                if (desired % 2 == 1) {
                    self.epoch = desired;
                    return .none;
                }
                // Preserve natural EOF: don't reload the same visible epoch.
                return if (self.epoch == desired) .none else .load;
            },
            .loading, .ready => return if (self.epoch == desired) .none else .stop,
        }
    }

    pub fn load(self: *Playback, epoch: u64) void {
        self.* = .{ .phase = .loading, .epoch = epoch };
    }

    pub fn stop(self: *Playback) void {
        self.phase = .stopping;
        self.started = false;
    }

    pub fn idle(self: *Playback) void {
        self.phase = .unloaded;
        self.started = false;
    }

    pub fn startFile(self: *Playback) void {
        if (self.phase == .loading) self.started = true;
    }

    pub fn restart(self: *Playback) ?u64 {
        if (self.phase != .loading or !self.started) return null;
        self.phase = .ready;
        self.started = false;
        return self.epoch;
    }
};

test "hide cancels initial loading without waiting for playback restart" {
    var p: Playback = .{};
    try std.testing.expectEqual(Playback.Action.load, p.next(0));
    p.load(0);
    try std.testing.expectEqual(Playback.Action.stop, p.next(1));
    p.stop();
    p.startFile(); // Late START_FILE must not revive canceled playback.
    try std.testing.expectEqual(@as(?u64, null), p.restart());
    try std.testing.expectEqual(Playback.Action.none, p.next(2));
    p.idle();
    try std.testing.expectEqual(Playback.Action.load, p.next(2));
}

test "hidden unload is idempotent and show waits for idle" {
    var p: Playback = .{};
    p.load(0);
    p.startFile();
    try std.testing.expectEqual(@as(?u64, 0), p.restart());
    try std.testing.expectEqual(Playback.Action.stop, p.next(1));
    p.stop();
    try std.testing.expectEqual(Playback.Action.none, p.next(1));
    try std.testing.expectEqual(Playback.Action.none, p.next(2));
    p.idle();
    try std.testing.expectEqual(Playback.Action.none, p.next(3));
    try std.testing.expectEqual(Playback.Action.none, p.next(3));
    try std.testing.expectEqual(Playback.Action.load, p.next(4));
    p.load(4);
    try std.testing.expectEqual(@as(?u64, null), p.restart());
    p.startFile();
    try std.testing.expectEqual(@as(?u64, 4), p.restart());
    try std.testing.expectEqual(Playback.Action.none, p.next(4));
}

test "EOF does not reload visible epoch but a later show can reload" {
    var p: Playback = .{};
    p.load(0);
    p.startFile();
    _ = p.restart();
    p.stop(); // END_FILE also passes through the idle/unload barrier.
    p.idle();
    try std.testing.expectEqual(Playback.Action.none, p.next(0));
    try std.testing.expectEqual(Playback.Action.none, p.next(1));
    try std.testing.expectEqual(Playback.Action.load, p.next(2));
}
