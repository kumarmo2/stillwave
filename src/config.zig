const std = @import("std");
const support = @import("support.zig");
const xdg = @import("xdg.zig");
const c = @import("c.zig").api;
const Allocator = std.mem.Allocator;
const Diagnostic = support.Diagnostic;

pub const Backend = enum { mpv, ffmpeg };
pub const Scale = enum { fill, fit };
pub const Hwdec = enum { auto, no };
pub const LogLevel = enum { quiet, @"error", warn, info, debug };
pub const Config = struct {
    schema_version: u32 = 1,
    backend: Backend = .mpv,
    media: ?[]const u8 = null,
    // Empty means every output, including newly connected outputs.
    outputs: []const []const u8 = &.{},
    scale: Scale = .fill,
    loop: bool = true,
    mute: bool = true,
    hwdec: Hwdec = .auto,
    paused: bool = false,
    log_level: LogLevel = .info,

    pub fn selects(self: Config, name: ?[]const u8) bool {
        if (self.outputs.len == 0) return true;
        const n = name orelse return false;
        for (self.outputs) |output| if (std.mem.eql(u8, output, n)) return true;
        return false;
    }
};
pub const Overrides = struct {
    backend: ?Backend = null,
    media: ?[]const u8 = null,
    outputs: ?[]const []const u8 = null,
    scale: ?Scale = null,
    loop: ?bool = null,
    mute: ?bool = null,
    hwdec: ?Hwdec = null,
    paused: ?bool = null,
    log_level: ?LogLevel = null,
};
pub const Source = struct { path: ?[]const u8 = null, disabled: bool = false };

/// All returned settings/diagnostics use the caller's arena (also suitable for a GUI model).
pub fn parse(a: Allocator, bytes: []const u8, d: *Diagnostic) !Config {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{
        .duplicate_field_behavior = .@"error",
        .allocate = .alloc_always,
    }) catch |err| return d.fail(a, "invalid JSON configuration: {s}", .{@errorName(err)});
    defer parsed.deinit();
    if (parsed.value != .object) return d.fail(a, "configuration must be a JSON object", .{});
    var cfg: Config = .{};
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "schema_version")) {
            if (v != .integer or v.integer != 1)
                return d.fail(a, "schema_version: only version 1 is supported", .{});
        } else if (std.mem.eql(u8, key, "media")) {
            cfg.media = switch (v) {
                .null => null,
                .string => |s| try a.dupe(u8, s),
                else => return d.fail(a, "media: expected a string or null", .{}),
            };
        } else if (std.mem.eql(u8, key, "outputs")) {
            if (v != .array) return d.fail(a, "outputs: expected an array of names (empty means all)", .{});
            const names = try a.alloc([]const u8, v.array.items.len);
            for (v.array.items, 0..) |item, i| {
                if (item != .string) return d.fail(a, "outputs[{d}]: expected a string", .{i});
                names[i] = try a.dupe(u8, item.string);
            }
            cfg.outputs = names;
        } else if (std.mem.eql(u8, key, "backend")) {
            cfg.backend = try enumValue(Backend, a, key, v, d);
        } else if (std.mem.eql(u8, key, "scale")) {
            cfg.scale = try enumValue(Scale, a, key, v, d);
        } else if (std.mem.eql(u8, key, "hwdec")) {
            cfg.hwdec = try enumValue(Hwdec, a, key, v, d);
        } else if (std.mem.eql(u8, key, "log_level")) {
            cfg.log_level = try enumValue(LogLevel, a, key, v, d);
        } else if (std.mem.eql(u8, key, "loop")) {
            cfg.loop = try boolean(a, key, v, d);
        } else if (std.mem.eql(u8, key, "mute")) {
            cfg.mute = try boolean(a, key, v, d);
        } else if (std.mem.eql(u8, key, "paused")) {
            cfg.paused = try boolean(a, key, v, d);
        } else return d.fail(a, "unknown configuration field: {s}", .{key});
    }
    try validate(a, cfg, d);
    return cfg;
}

fn boolean(a: Allocator, key: []const u8, v: std.json.Value, d: *Diagnostic) !bool {
    if (v != .bool) return d.fail(a, "{s}: expected a boolean", .{key});
    return v.bool;
}
fn enumValue(comptime T: type, a: Allocator, key: []const u8, v: std.json.Value, d: *Diagnostic) !T {
    if (v == .string) if (std.meta.stringToEnum(T, v.string)) |result| return result;
    return d.fail(a, "{s}: invalid value", .{key});
}
pub fn validate(a: Allocator, cfg: Config, d: *Diagnostic) !void {
    if (cfg.schema_version != 1) return d.fail(a, "unsupported schema_version", .{});
    if (cfg.media) |m| if (m.len == 0 or std.mem.indexOfScalar(u8, m, 0) != null)
        return d.fail(a, "media: path must be nonempty and contain no NUL bytes", .{});
    for (cfg.outputs, 0..) |name, i| {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null)
            return d.fail(a, "outputs[{d}]: invalid output name", .{i});
        for (cfg.outputs[0..i]) |prior| if (std.mem.eql(u8, name, prior))
            return d.fail(a, "outputs: duplicate name '{s}'", .{name});
    }
}

pub fn apply(cfg: *Config, overrides: Overrides) void {
    if (overrides.backend) |v| cfg.backend = v;
    if (overrides.media) |v| cfg.media = v;
    if (overrides.outputs) |v| cfg.outputs = v;
    if (overrides.scale) |v| cfg.scale = v;
    if (overrides.loop) |v| cfg.loop = v;
    if (overrides.mute) |v| cfg.mute = v;
    if (overrides.hwdec) |v| cfg.hwdec = v;
    if (overrides.paused) |v| cfg.paused = v;
    if (overrides.log_level) |v| cfg.log_level = v;
}

pub fn load(a: Allocator, source: Source, overrides: Overrides, d: *Diagnostic) !Config {
    const working = try support.cwd(a);
    var cfg: Config = .{};
    if (!source.disabled) {
        const path = if (source.path) |p| try xdg.resolve(a, working, p) else xdg.discover(a) catch
            return d.fail(a, "no XDG config directory; set HOME/XDG_CONFIG_HOME or use --config/--no-config", .{});
        const data: ?[]const u8 = support.readFile(a, path, 1024 * 1024) catch |err| blk: {
            if (err == error.FileNotFound and source.path == null) break :blk null;
            return d.fail(a, "cannot read config '{s}': {s}", .{ path, @errorName(err) });
        };
        if (data) |bytes| {
            cfg = try parse(a, bytes, d);
            if (cfg.media) |media| cfg.media = try xdg.resolve(a, std.fs.path.dirname(path).?, media);
        }
    }
    apply(&cfg, overrides);
    try validate(a, cfg, d);
    if (cfg.media) |media| cfg.media = try xdg.resolve(a, working, media);
    return cfg;
}

pub fn validateRunnable(a: Allocator, cfg: Config, d: *Diagnostic) !void {
    if (cfg.backend == .ffmpeg and !cfg.mute) return d.fail(a, "FFmpeg backend is muted-only; use --mute or --backend mpv for audio", .{});
    const media = cfg.media orelse return d.fail(a, "no video specified; pass VIDEO or set media in JSON", .{});
    const z = try a.dupeSentinel(u8, media, 0);
    defer a.free(z);
    const fd = c.open(z, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return d.fail(a, "cannot open video '{s}': {s}", .{ media, std.mem.span(c.strerror(c.__errno_location().*)) });
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or (stat.st_mode & c.S_IFMT) != c.S_IFREG)
        return d.fail(a, "video must be a readable regular local file: {s}", .{media});
}

test "defaults, partial config, false overrides, all and selected outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostic = .{};
    var cfg = try parse(a, "{\"mute\":false,\"outputs\":[\"LEFT\",\"RIGHT\"],\"scale\":\"fit\"}", &d);
    try std.testing.expect(cfg.loop and !cfg.mute and cfg.scale == .fit);
    try std.testing.expect(cfg.selects("LEFT") and !cfg.selects("OTHER"));
    apply(&cfg, .{ .loop = false, .mute = true, .outputs = &.{} });
    try std.testing.expect(!cfg.loop and cfg.mute and cfg.selects(null));
}

test "JSON rejects unknowns, duplicates, nulls, bad types and versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "[]",                        "{",                 "{\"unknown\":1}",             "{\"mute\":true,\"mute\":false}",
        "{\"schema_version\":2}",    "{\"mute\":null}",   "{\"loop\":1}",                "{\"scale\":\"stretch\"}",
        "{\"outputs\":null}",        "{\"outputs\":[1]}", "{\"outputs\":[\"A\",\"A\"]}", "{\"media\":\"\"}",
        "{\"media\":\"a\\u0000b\"}",
    }) |bytes| {
        var d: Diagnostic = .{};
        try std.testing.expectError(error.InvalidInput, parse(a, bytes, &d));
        try std.testing.expect(d.message.len > 0);
    }
}

test "all settings round trip through JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostic = .{};
    const original: Config = .{ .media = "/v/a b.mp4", .outputs = &.{ "rotated", "scaled" }, .scale = .fit, .loop = false, .mute = false, .hwdec = .no, .paused = true, .log_level = .debug };
    const bytes = try std.json.Stringify.valueAlloc(a, original, .{});
    const result = try parse(a, bytes, &d);
    const again = try std.json.Stringify.valueAlloc(a, result, .{});
    try std.testing.expectEqualStrings(bytes, again);
    const defaults = try parse(a, "{}", &d);
    try std.testing.expect(defaults.mute and defaults.loop and defaults.outputs.len == 0 and defaults.media == null);
    try std.testing.expectError(error.InvalidInput, validateRunnable(a, defaults, &d));
}
