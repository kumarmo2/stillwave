const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const support = @import("support.zig");
const c = @import("c.zig").api;
const app = @import("app.zig");
const startup = @import("startup.zig");
const control = @import("control.zig");

pub fn main(init: std.process.Init) void {
    var profile = startup.Profile.init();
    const a = init.arena.allocator();
    var d: support.Diagnostic = .{};
    execute(init, a, &d, &profile) catch |err| {
        if (d.message.len > 0) std.debug.print("stillwave: {s}\n", .{d.message}) else std.debug.print("stillwave: {s}\n", .{@errorName(err)});
        c.exit(if (err == error.InvalidInput) 2 else 1);
    };
}

fn execute(init: std.process.Init, a: std.mem.Allocator, d: *support.Diagnostic, profile: *startup.Profile) !void {
    const args = try init.minimal.args.toSlice(a);
    const o = try cli.parse(a, args, d);
    profile.enabled = o.profile_startup;
    profile.mark("process", "arguments parsed (clock starts at main; excludes loader/shell)", profile.origin);
    switch (o.command) {
        .help => return support.stdout(cli.help),
        .version => return support.stdout("stillwave 0.1.0-poc\n"),
        .defaults => return support.json(a, config.Config{}),
        .list_outputs => return app.listOutputs(a, o.json),
        .set_video => {
            const cwd = try support.cwd(a);
            const path = try @import("xdg.zig").resolve(a, cwd, o.overrides.media.?);
            return control.setVideo(a, path, d) catch |err| {
                if (err == error.NoRunningInstance) d.message = "no running instance; start stillwave run first";
                return err;
            };
        },
        .hide, .reveal, .quit => return control.send(a, switch (o.command) {
            .hide => .hide,
            .reveal => .show,
            .quit => .quit,
            else => unreachable,
        }) catch |err| {
            if (err == error.NoRunningInstance) d.message = "no running instance; start stillwave run first";
            return err;
        },
        else => {},
    }
    const config_start = profile.begin();
    const cfg = try config.load(a, o.source, o.overrides, d);
    profile.mark("process", "configuration loaded", config_start);
    switch (o.command) {
        .show => try support.json(a, cfg),
        .validate => try support.stdout(if (cfg.media == null) "Valid configuration template; run requires media.\n" else "Valid configuration.\n"),
        .run => try app.run(a, cfg, try @import("persistence.zig").target(a, o.source), d, profile),
        else => unreachable,
    }
}

test {
    _ = @import("startup.zig");
    _ = @import("playback.zig");
    _ = @import("persistence.zig");
    _ = @import("config.zig");
    _ = @import("cli.zig");
    _ = @import("xdg.zig");
    _ = @import("platform/wayland.zig");
    _ = @import("render/pacing.zig");
}
