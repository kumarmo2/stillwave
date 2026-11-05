const std = @import("std");
const c = @import("c.zig").api;
pub const Allocator = std.mem.Allocator;

pub const Diagnostic = struct {
    message: []const u8 = "",
    pub fn fail(self: *Diagnostic, a: Allocator, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, InvalidInput } {
        self.message = try std.fmt.allocPrint(a, fmt, args);
        return error.InvalidInput;
    }
};

pub fn env(name: [:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.span(p);
}

pub fn cwd(a: Allocator) ![]const u8 {
    const p = c.getcwd(null, 0) orelse return error.WorkingDirectoryUnavailable;
    defer c.free(p);
    return a.dupe(u8, std.mem.span(p));
}

pub fn readFile(a: Allocator, path: []const u8, limit: usize) ![]const u8 {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const fd = c.open(z, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return switch (c.__errno_location().*) {
        c.ENOENT => error.FileNotFound,
        c.EACCES => error.AccessDenied,
        else => error.FileOpenFailed,
    };
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.FileReadFailed;
    if ((st.st_mode & c.S_IFMT) != c.S_IFREG) return error.NotRegularFile;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n == 0) break;
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return error.FileReadFailed;
        }
        const len: usize = @intCast(n);
        if (bytes.items.len + len > limit) return error.FileTooLarge;
        try bytes.appendSlice(a, buf[0..len]);
    }
    return bytes.toOwnedSlice(a);
}

pub fn stdout(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(c.STDOUT_FILENO, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return error.OutputFailed;
        }
        if (n == 0) return error.OutputFailed;
        offset += @intCast(n);
    }
}

pub fn json(a: Allocator, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
    defer a.free(bytes);
    try stdout(bytes);
    try stdout("\n");
}
