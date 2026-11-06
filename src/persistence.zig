//! Explicit media-only configuration updates. Existing bytes outside the media
//! value are preserved; a request snapshot detects edits during candidate loading.
const std = @import("std");
const config = @import("config.zig");
const support = @import("support.zig");
const xdg = @import("xdg.zig");
const c = @import("c.zig").api;
const a = std.heap.c_allocator;

pub fn target(allocator: std.mem.Allocator, source: config.Source) !?[]const u8 {
    if (source.disabled) return null;
    if (source.path) |path| {
        const cwd = try support.cwd(allocator);
        defer allocator.free(cwd);
        return try xdg.resolve(allocator, cwd, path);
    }
    return try xdg.discover(allocator);
}

pub const Snapshot = struct {
    path: [:0]u8,
    bytes: ?[]const u8,
    mode: c_uint = 0o600,

    pub fn init(path: []const u8) !Snapshot {
        const z = try a.dupeSentinel(u8, path, 0);
        errdefer a.free(z);
        var st: c.struct_stat = undefined;
        const exists = c.lstat(z, &st) == 0;
        if (!exists and c.__errno_location().* != c.ENOENT) return error.ConfigReadFailed;
        if (exists and (st.st_mode & c.S_IFMT) != c.S_IFREG) return error.ConfigMustBeRegularNotSymlink;
        const bytes = if (exists) try support.readFile(a, path, 1024 * 1024) else null;
        errdefer if (bytes) |b| a.free(b);
        if (bytes) |b| {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            var diagnostic: support.Diagnostic = .{};
            _ = try config.parse(arena.allocator(), b, &diagnostic);
        }
        return .{ .path = z, .bytes = bytes, .mode = if (exists) st.st_mode & 0o777 else 0o600 };
    }
    pub fn deinit(self: *Snapshot) void {
        a.free(self.path);
        if (self.bytes) |b| a.free(b);
    }
    fn unchanged(self: *const Snapshot) !void {
        var latest = try Snapshot.init(self.path);
        defer latest.deinit();
        if ((self.bytes == null) != (latest.bytes == null) or self.mode != latest.mode) return error.ConfigChangedDuringReplacement;
        if (self.bytes) |old| if (!std.mem.eql(u8, old, latest.bytes.?)) return error.ConfigChangedDuringReplacement;
    }
    pub fn save(self: *const Snapshot, media: []const u8) !void {
        const updated = try patch(a, self.bytes orelse "{}\n", media);
        defer a.free(updated);
        if (updated.len > 1024 * 1024) return error.ConfigFileTooLarge;
        const parent = std.fs.path.dirname(self.path).?;
        // mkdir each prefix; no unrelated files/settings are written.
        const directory = try a.dupeSentinel(u8, parent, 0);
        defer a.free(directory);
        for (directory, 0..) |ch, i| {
            if (ch != '/' or i == 0) continue;
            directory[i] = 0;
            const result = c.mkdir(directory, 0o700);
            directory[i] = '/';
            if (result != 0 and c.__errno_location().* != c.EEXIST) return error.ConfigDirectoryFailed;
        }
        if (c.mkdir(directory, 0o700) != 0 and c.__errno_location().* != c.EEXIST) return error.ConfigDirectoryFailed;
        const temp = try std.fmt.allocPrintSentinel(a, "{s}/.stillwave-XXXXXX", .{parent}, 0);
        defer a.free(temp);
        const fd = c.mkstemp(temp);
        if (fd < 0) return error.ConfigWriteFailed;
        defer _ = c.close(fd);
        defer _ = c.unlink(temp);
        if (c.fchmod(fd, self.mode) != 0) return error.ConfigWriteFailed;
        var offset: usize = 0;
        while (offset < updated.len) {
            const n = c.write(fd, updated[offset..].ptr, updated.len - offset);
            if (n < 0 and c.__errno_location().* == c.EINTR) continue;
            if (n <= 0) return error.ConfigWriteFailed;
            offset += @intCast(n);
        }
        if (c.fsync(fd) != 0) return error.ConfigWriteFailed;
        try self.unchanged();
        if (self.bytes == null) {
            // link is a no-clobber install if someone creates the missing file.
            if (c.link(temp, self.path) != 0) return error.ConfigChangedDuringReplacement;
        } else if (c.rename(temp, self.path) != 0) return error.ConfigWriteFailed;
    }
};

fn whitespace(bytes: []const u8, index: *usize) void {
    while (index.* < bytes.len and std.ascii.isWhitespace(bytes[index.*])) index.* += 1;
}
// Input is already validated JSON; skip exactly one value without normalizing it.
fn valueEnd(bytes: []const u8, start: usize) usize {
    var depth: usize = 0;
    var quoted = false;
    var escape = false;
    var i = start;
    while (i < bytes.len) : (i += 1) {
        const ch = bytes[i];
        if (quoted) {
            if (escape) {
                escape = false;
            } else if (ch == '\\') {
                escape = true;
            } else if (ch == '"') {
                quoted = false;
                if (depth == 0) return i + 1;
            }
            continue;
        }
        switch (ch) {
            '"' => quoted = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return i;
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            ',', ' ', '\n', '\r', '\t' => if (depth == 0) return i,
            else => {},
        }
    }
    return i;
}

pub fn patch(allocator: std.mem.Allocator, bytes: []const u8, media: []const u8) ![]u8 {
    const encoded = try std.json.Stringify.valueAlloc(allocator, media, .{});
    defer allocator.free(encoded);
    var i: usize = 0;
    whitespace(bytes, &i);
    const open = i;
    i += 1;
    whitespace(bytes, &i);
    const empty = bytes[i] == '}';
    while (bytes[i] != '}') {
        const key_end = valueEnd(bytes, i);
        const key = try std.json.parseFromSlice([]const u8, allocator, bytes[i..key_end], .{});
        defer key.deinit();
        i = key_end;
        whitespace(bytes, &i);
        i += 1; // colon
        whitespace(bytes, &i);
        const end = valueEnd(bytes, i);
        if (std.mem.eql(u8, key.value, "media"))
            return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ bytes[0..i], encoded, bytes[end..] });
        i = end;
        whitespace(bytes, &i);
        if (bytes[i] == ',') {
            i += 1;
            whitespace(bytes, &i);
        }
    }
    return std.fmt.allocPrint(allocator, "{s}\"media\": {s}{s}{s}", .{ bytes[0 .. open + 1], encoded, if (empty) "" else ",", bytes[open + 1 ..] });
}

test "media patch preserves unrelated bytes, escaped keys and nested values" {
    const allocator = std.testing.allocator;
    const old = "{\n  \"outputs\": [\"LEFT\", \"RIGHT\"], \"me\\u0064ia\": null,\n \"paused\": true\n}\n";
    const updated = try patch(allocator, old, "/new clip.mp4");
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("{\n  \"outputs\": [\"LEFT\", \"RIGHT\"], \"me\\u0064ia\": \"/new clip.mp4\",\n \"paused\": true\n}\n", updated);
    for ([_][]const u8{ "{}\n", "{ \"scale\": \"fit\" }" }) |input| {
        const result = try patch(allocator, input, "/a\"b.mp4");
        defer allocator.free(result);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var d: support.Diagnostic = .{};
        const cfg = try config.parse(arena.allocator(), result, &d);
        try std.testing.expectEqualStrings("/a\"b.mp4", cfg.media.?);
    }
}
