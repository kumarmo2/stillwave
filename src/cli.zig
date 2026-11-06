const std = @import("std");
const config = @import("config.zig");
const support = @import("support.zig");
pub const Command = enum { help, version, run, list_outputs, defaults, show, validate, hide, reveal, quit };
pub const Options = struct {
    command: Command = .help,
    source: config.Source = .{},
    overrides: config.Overrides = .{},
    json: bool = false,
    profile_startup: bool = false,
};
pub const help =
    \\stillwave — local video wallpapers for layer-shell Wayland compositors
    \\
    \\Usage:
    \\  stillwave run [OPTIONS] [VIDEO]
    \\  stillwave hide | show | quit
    \\  stillwave list-outputs [--json]
    \\  stillwave config defaults
    \\  stillwave config show [OPTIONS] [VIDEO]
    \\  stillwave config validate [OPTIONS]
    \\
    \\Options:
    \\  --config PATH           Explicit JSON file
    \\  --no-config             Ignore XDG config
    \\  --output NAME           Select display (repeatable); default: all
    \\  --all-outputs           Override configured display selection with all
    \\  --backend mpv|ffmpeg    Playback backend (default: mpv; ffmpeg muted-only)
    \\  --scale fill|fit         Crop to fill (default) or letterbox
    \\  --hwdec auto|no          Opportunistic hardware decoding (default: auto)
    \\  --mute / --no-mute       Audio muted by default; unmuted on one output only
    \\  --loop / --no-loop       Loop by default; otherwise exit at EOF
    \\  --paused / --no-paused   Start paused (default: false)
    \\  --log-level LEVEL       quiet, error, warn, info (default), debug
    \\  --profile-startup        Report startup wall-clock timings to stderr (run only)
    \\  --help / --version
    \\  --                      End options (for paths starting with '-')
    \\
    \\Config: $XDG_CONFIG_HOME/stillwave/config.json
    \\        fallback: $HOME/.config/stillwave/config.json
    \\Precedence: defaults < JSON file < CLI overrides. No implicit config writes.
    \\Runs in foreground; Ctrl-C or SIGTERM stops it. No shell/WM-specific IPC.
    \\hide/show/quit control the existing run in this Wayland session.
    \\hide unloads/unmaps; show starts from the beginning using retained contexts.
    \\
;

pub fn parse(a: std.mem.Allocator, args: []const []const u8, d: *support.Diagnostic) !Options {
    var o: Options = .{};
    if (args.len < 2) return o;
    var index: usize = 2;
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return o;
    if (std.mem.eql(u8, cmd, "--version")) return .{ .command = .version };
    if (std.mem.eql(u8, cmd, "run")) {
        o.command = .run;
    } else if (std.mem.eql(u8, cmd, "hide") or std.mem.eql(u8, cmd, "show") or std.mem.eql(u8, cmd, "quit")) {
        if (args.len == 3 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h"))) return o;
        if (args.len != 2) return d.fail(a, "{s} takes no arguments", .{cmd});
        o.command = if (std.mem.eql(u8, cmd, "hide")) .hide else if (std.mem.eql(u8, cmd, "show")) .reveal else .quit;
        return o;
    } else if (std.mem.eql(u8, cmd, "list-outputs")) {
        o.command = .list_outputs;
    } else if (std.mem.eql(u8, cmd, "config")) {
        if (args.len < 3) return d.fail(a, "config requires defaults, show, or validate", .{});
        o.command = if (std.mem.eql(u8, args[2], "defaults")) .defaults else if (std.mem.eql(u8, args[2], "show")) .show else if (std.mem.eql(u8, args[2], "validate")) .validate else return d.fail(a, "unknown config command: {s}", .{args[2]});
        index = 3;
    } else return d.fail(a, "unknown command: {s} (use --help)", .{cmd});
    var outputs: std.ArrayList([]const u8) = .empty;
    defer outputs.deinit(a);
    var all = false;
    var positional = false;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!positional and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) return .{};
        if (o.command == .defaults) return d.fail(a, "config defaults takes no options", .{});
        if (o.command == .list_outputs) {
            if (std.mem.eql(u8, arg, "--json") and !o.json) {
                o.json = true;
                continue;
            }
            return d.fail(a, "list-outputs only accepts --json", .{});
        }
        if (!positional and std.mem.eql(u8, arg, "--")) {
            positional = true;
            continue;
        }
        if (!positional and std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--profile-startup")) {
                if (o.command != .run or o.profile_startup) return d.fail(a, "--profile-startup is run-only and cannot be repeated", .{});
                o.profile_startup = true;
            } else if (std.mem.eql(u8, arg, "--no-config")) {
                if (o.source.disabled or o.source.path != null) return d.fail(a, "conflicting/repeated config selection", .{});
                o.source.disabled = true;
            } else if (std.mem.eql(u8, arg, "--all-outputs")) {
                if (all or outputs.items.len > 0) return d.fail(a, "--all-outputs conflicts with --output", .{});
                all = true;
            } else if (std.mem.eql(u8, arg, "--mute") or std.mem.eql(u8, arg, "--no-mute")) {
                try setBool(a, &o.overrides.mute, std.mem.eql(u8, arg, "--mute"), arg, d);
            } else if (std.mem.eql(u8, arg, "--loop") or std.mem.eql(u8, arg, "--no-loop")) {
                try setBool(a, &o.overrides.loop, std.mem.eql(u8, arg, "--loop"), arg, d);
            } else if (std.mem.eql(u8, arg, "--paused") or std.mem.eql(u8, arg, "--no-paused")) {
                try setBool(a, &o.overrides.paused, std.mem.eql(u8, arg, "--paused"), arg, d);
            } else {
                if (index + 1 == args.len) return d.fail(a, "{s}: missing value", .{arg});
                index += 1;
                const value = args[index];
                if (std.mem.eql(u8, arg, "--config")) {
                    if (o.source.disabled or o.source.path != null or value.len == 0) return d.fail(a, "invalid/conflicting config selection", .{});
                    o.source.path = value;
                } else if (std.mem.eql(u8, arg, "--output")) {
                    if (all) return d.fail(a, "--output conflicts with --all-outputs", .{});
                    try outputs.append(a, value);
                } else if (std.mem.eql(u8, arg, "--backend")) {
                    if (o.overrides.backend != null) return d.fail(a, "repeated --backend", .{});
                    o.overrides.backend = std.meta.stringToEnum(config.Backend, value) orelse return d.fail(a, "--backend: use mpv or ffmpeg", .{});
                } else if (std.mem.eql(u8, arg, "--scale")) {
                    if (o.overrides.scale != null) return d.fail(a, "repeated --scale", .{});
                    o.overrides.scale = std.meta.stringToEnum(config.Scale, value) orelse return d.fail(a, "--scale: use fill or fit", .{});
                } else if (std.mem.eql(u8, arg, "--hwdec")) {
                    if (o.overrides.hwdec != null) return d.fail(a, "repeated --hwdec", .{});
                    o.overrides.hwdec = std.meta.stringToEnum(config.Hwdec, value) orelse return d.fail(a, "--hwdec: use auto or no", .{});
                } else if (std.mem.eql(u8, arg, "--log-level")) {
                    if (o.overrides.log_level != null) return d.fail(a, "repeated --log-level", .{});
                    o.overrides.log_level = std.meta.stringToEnum(config.LogLevel, value) orelse return d.fail(a, "--log-level: invalid level", .{});
                } else return d.fail(a, "unknown option: {s}", .{arg});
            }
        } else {
            if (o.command == .validate or o.overrides.media != null or (!positional and std.mem.startsWith(u8, arg, "-")))
                return d.fail(a, "unexpected argument: {s}", .{arg});
            o.overrides.media = arg;
        }
    }
    if (all or outputs.items.len > 0) o.overrides.outputs = try outputs.toOwnedSlice(a);
    return o;
}
fn setBool(a: std.mem.Allocator, dest: *?bool, value: bool, arg: []const u8, d: *support.Diagnostic) !void {
    if (dest.* != null) return d.fail(a, "conflicting/repeated option: {s}", .{arg});
    dest.* = value;
}

test "CLI supports many outputs, false overrides, all, and literal paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: support.Diagnostic = .{};
    const o = try parse(a, &.{ "stillwave", "run", "--output", "A", "--output", "B", "--no-mute", "--", "-clip.mp4" }, &d);
    try std.testing.expect(o.overrides.outputs.?.len == 2);
    try std.testing.expect(o.overrides.mute.? == false);
    try std.testing.expectEqualStrings("-clip.mp4", o.overrides.media.?);
    const all = try parse(a, &.{ "w", "run", "--all-outputs" }, &d);
    try std.testing.expect(all.overrides.outputs.?.len == 0);
}
test "CLI rejects conflicting flags and stray arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const []const u8{
        &.{ "w", "run", "--mute", "--no-mute" },            &.{ "w", "run", "--config", "x", "--no-config" },
        &.{ "w", "run", "--output", "A", "--all-outputs" }, &.{ "w", "run", "a", "b" },
        &.{ "w", "run", "--hwdec", "bad" },                 &.{ "w", "run", "--unknown" },
    }) |args| {
        var d: support.Diagnostic = .{};
        try std.testing.expectError(error.InvalidInput, parse(a, args, &d));
    }
}
