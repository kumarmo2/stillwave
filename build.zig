const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const protocols = b.option([]const u8, "wayland-protocols", "wayland-protocols data directory") orelse "/usr/share/wayland-protocols";
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const specs = [_]struct { name: []const u8, path: std.Build.LazyPath }{
        .{ .name = "wlr-layer-shell", .path = b.path("protocols/wlr-layer-shell-unstable-v1.xml") },
        .{ .name = "xdg-shell", .path = .{ .cwd_relative = b.pathJoin(&.{ protocols, "stable/xdg-shell/xdg-shell.xml" }) } },
        .{ .name = "xdg-output", .path = .{ .cwd_relative = b.pathJoin(&.{ protocols, "unstable/xdg-output/xdg-output-unstable-v1.xml" }) } },
        .{ .name = "viewporter", .path = .{ .cwd_relative = b.pathJoin(&.{ protocols, "stable/viewporter/viewporter.xml" }) } },
        .{ .name = "fractional-scale", .path = .{ .cwd_relative = b.pathJoin(&.{ protocols, "staging/fractional-scale/fractional-scale-v1.xml" }) } },
    };
    const translate = b.addSystemCommand(&.{ b.graph.zig_exe, "translate-c", "-lc" });
    for (specs) |spec| {
        const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        header.addFileArg(spec.path);
        const h = header.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{spec.name}));
        mod.addIncludePath(h.dirname());
        translate.addArg("-I");
        translate.addDirectoryArg(h.dirname());
        const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        code.addFileArg(spec.path);
        const c = code.addOutputFileArg(b.fmt("{s}-protocol.c", .{spec.name}));
        mod.addCSourceFile(.{ .file = c, .flags = &.{} });
    }
    translate.addFileArg(b.path("src/native.h"));
    const native = b.createModule(.{ .root_source_file = translate.captureStdOut(.{ .basename = "native.zig" }), .target = target, .optimize = optimize });
    mod.addImport("native", native);
    for ([_][]const u8{ "wayland-client", "wayland-egl", "EGL", "GL", "mpv" }) |lib|
        mod.linkSystemLibrary(lib, .{});
    const exe = b.addExecutable(.{ .name = "stillwave", .root_module = mod });
    b.installArtifact(exe);

    // This opt-in step installs for the invoking user, independently of --prefix.
    const install_system = b.step("install-system", "Install Stillwave to $HOME/.local/bin (no sudo)");
    // Resolve HOME at execution time, not in Zig\'s cached build configuration.
    const install = b.addSystemCommand(&.{"sh"});
    install.addFileArg(b.path("scripts/install-system.sh"));
    install.addArtifactArg(exe);
    // Always copy again, including when the installed file was removed/changed.
    install.has_side_effects = true;
    install_system.dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the CLI").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
