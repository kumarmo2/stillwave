const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const support = @import("support.zig");
const c = @import("c.zig").api;
const app = @import("app.zig");

pub fn main(init: std.process.Init) void {
    const a = init.arena.allocator();
    var d: support.Diagnostic = .{};
    execute(init, a, &d) catch |err| {
        if (d.message.len > 0) std.debug.print("stillwave: {s}\n", .{d.message}) else std.debug.print("stillwave: {s}\n", .{@errorName(err)});
        c.exit(if (err == error.InvalidInput) 2 else 1);
    };
}

fn execute(init: std.process.Init, a: std.mem.Allocator, d: *support.Diagnostic) !void {
    const args = try init.minimal.args.toSlice(a);
    const o = try cli.parse(a, args, d);
    switch (o.command) {
        .help => return support.stdout(cli.help),
        .version => return support.stdout("stillwave 0.1.0-poc\n"),
        .defaults => return support.json(a, config.Config{}),
        .list_outputs => return app.listOutputs(a, o.json),
        else => {},
    }
    const cfg = try config.load(a, o.source, o.overrides, d);
    switch (o.command) {
        .show => try support.json(a, cfg),
        .validate => try support.stdout(if (cfg.media == null) "Valid configuration template; run requires media.\n" else "Valid configuration.\n"),
        .run => try app.run(a, cfg, d),
        else => unreachable,
    }
}

test {
    _ = @import("config.zig");
    _ = @import("cli.zig");
    _ = @import("xdg.zig");
    _ = @import("platform/wayland.zig");
    _ = @import("render/pacing.zig");
}
