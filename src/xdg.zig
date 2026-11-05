const std = @import("std");
const support = @import("support.zig");
const Allocator = std.mem.Allocator;

pub fn configPath(a: Allocator, xdg: ?[]const u8, home: ?[]const u8) ![]const u8 {
    if (xdg) |base| {
        if (std.fs.path.isAbsolute(base))
            return std.fs.path.join(a, &.{ base, "stillwave", "config.json" });
    }
    if (home) |base| {
        if (std.fs.path.isAbsolute(base))
            return std.fs.path.join(a, &.{ base, ".config", "stillwave", "config.json" });
    }
    return error.ConfigDirectoryUnavailable;
}

pub fn discover(a: Allocator) ![]const u8 {
    return configPath(a, support.env("XDG_CONFIG_HOME"), support.env("HOME"));
}

pub fn resolve(a: Allocator, base: []const u8, path: []const u8) ![]const u8 {
    return std.fs.path.resolve(a, &.{ base, path });
}

test "XDG config absolute path, empty/relative fallback, missing home" {
    const a = std.testing.allocator;
    const cases = [_]struct { xdg: ?[]const u8, home: ?[]const u8, expected: []const u8 }{
        .{ .xdg = "/cfg", .home = "/home/test", .expected = "/cfg/stillwave/config.json" },
        .{ .xdg = "", .home = "/home/test", .expected = "/home/test/.config/stillwave/config.json" },
        .{ .xdg = "relative", .home = "/home/test", .expected = "/home/test/.config/stillwave/config.json" },
        .{ .xdg = null, .home = "/home/test", .expected = "/home/test/.config/stillwave/config.json" },
        .{ .xdg = "/cfg", .home = null, .expected = "/cfg/stillwave/config.json" },
    };
    for (cases) |case| {
        const got = try configPath(a, case.xdg, case.home);
        defer a.free(got);
        try std.testing.expectEqualStrings(case.expected, got);
    }
    try std.testing.expectError(error.ConfigDirectoryUnavailable, configPath(a, null, null));
    try std.testing.expectError(error.ConfigDirectoryUnavailable, configPath(a, "rel", "rel"));
}

test "relative media is resolved against its source, not monitor layout" {
    const a = std.testing.allocator;
    const got = try resolve(a, "/configs", "../videos/a b.mp4");
    defer a.free(got);
    try std.testing.expectEqualStrings("/videos/a b.mp4", got);
}
