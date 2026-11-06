const std = @import("std");
const c = @import("c.zig").api;

/// Wall-clock startup milestones. No allocations, callbacks, or steady-state logging.
pub const Profile = struct {
    enabled: bool = false,
    origin: u64,

    pub fn init() Profile {
        return .{ .origin = now() };
    }

    pub fn begin(self: *const Profile) u64 {
        return if (self.enabled) now() else 0;
    }

    pub fn mark(self: *const Profile, label: []const u8, stage: []const u8, since: u64) void {
        if (!self.enabled) return;
        const end = now();
        std.debug.print("[startup] +{d:.3} ms [{s}] {s} ({d:.3} ms)\n", .{
            milliseconds(end -| self.origin), label, stage, milliseconds(end -| since),
        });
    }
};

fn now() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

fn milliseconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

test "startup durations use milliseconds" {
    try std.testing.expectEqual(@as(f64, 1.5), milliseconds(1_500_000));
}
