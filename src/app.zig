const std = @import("std");
const config = @import("config.zig");
const support = @import("support.zig");
const wl = @import("platform/wayland.zig");
const egl = @import("render/egl.zig");
const player = @import("backend.zig");
const startup = @import("startup.zig");
const control = @import("control.zig");
const replacement = @import("replacement.zig");
const c = @import("c.zig").api;

var interrupted = std.atomic.Value(bool).init(false);
var signal_fd: c_int = -1;
fn onSignal(_: c_int) callconv(.c) void {
    interrupted.store(true, .release);
    if (signal_fd >= 0) player.notify(signal_fd);
}

const State = struct {
    surface: wl.Surface = undefined,
    window: ?egl.Window = null,
    video: ?*player.Player = null,
    audible: bool = false,
    last_scale: i32 = 1,
    configure_start: u64 = 0,
    resume_pending: bool = false,
    resume_start: u64 = 0,
    retiring: bool = false,

    fn deinit(self: *State, context: *egl.Context) void {
        if (self.window) |*window| {
            context.makeCurrent(window.surface) catch {};
            if (self.video) |video| {
                video.deinit();
                std.heap.c_allocator.destroy(video);
            }
            window.deinit();
        }
        self.surface.deinit();
    }
};

/// Enumerates only through Wayland; never needs a compositor's IPC tools.
pub fn listOutputs(a: std.mem.Allocator, as_json: bool) !void {
    var client: wl.Client = undefined;
    try client.init(std.heap.c_allocator);
    defer client.deinit();
    const Info = struct {
        name: ?[]const u8,
        description: ?[]const u8,
        mode_width: i32,
        mode_height: i32,
        refresh_mhz: i32,
        integer_scale: i32,
        transform: i32,
    };
    var infos: std.ArrayList(Info) = .empty;
    defer infos.deinit(a);
    for (client.outputs.items) |o| {
        if (!o.active) continue;
        try infos.append(a, .{
            .name = o.name,
            .description = o.description,
            .mode_width = o.width,
            .mode_height = o.height,
            .refresh_mhz = o.refresh_mhz,
            .integer_scale = o.scale,
            .transform = o.transform,
        });
        if (!as_json) {
            const line = try std.fmt.allocPrint(a, "{s}\t{s}\tmode {d}x{d}, scale {d}, transform {d}\n", .{
                o.name orelse "(unnamed)", o.description orelse "", o.width, o.height, o.scale, o.transform,
            });
            defer a.free(line);
            try support.stdout(line);
        }
    }
    if (as_json) try support.json(a, infos.items);
}

/// Foreground application lifecycle shared independently of argv/config loading.
/// A single running instance per process; call on its render-owner thread.
pub fn run(a: std.mem.Allocator, initial: config.Config, config_path: ?[]const u8, d: *support.Diagnostic, profile: *const startup.Profile) !void {
    var cfg = initial;
    var current_media: ?[]const u8 = null;
    defer if (current_media) |media| std.heap.c_allocator.free(media);
    const validation_start = profile.begin();
    try config.validateRunnable(a, cfg, d);
    if (cfg.backend == .ffmpeg and !@import("build_options").ffmpeg)
        return d.fail(a, "FFmpeg backend is not included in this build; rebuild with -Dffmpeg=true", .{});
    profile.mark("process", "media validated", validation_start);
    const runtime = std.heap.c_allocator;
    var commands = control.Server.init(runtime) catch |err| {
        if (err == error.AlreadyRunning) return d.fail(a, "Stillwave is already running in this Wayland session", .{});
        return err;
    };
    defer commands.deinit();
    var visible = true;
    var client: wl.Client = undefined;
    const wayland_start = profile.begin();
    try client.init(runtime);
    profile.mark("process", "Wayland connected and outputs discovered", wayland_start);
    defer client.deinit();
    if (client.compositor == null) return d.fail(a, "Wayland server does not advertise wl_compositor", .{});
    if (client.shell == null) return d.fail(a, "Wayland compositor does not advertise zwlr_layer_shell_v1; background placement needs a different backend (no normal-window fallback)", .{});
    for (cfg.outputs) |wanted| {
        var found = false;
        for (client.outputs.items) |o| {
            if (o.active and o.name != null and std.mem.eql(u8, o.name.?, wanted)) {
                found = true;
                break;
            }
        }
        if (!found) return d.fail(a, "output '{s}' is not connected or has no discoverable name; use list-outputs", .{wanted});
    }
    const wake = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
    if (wake < 0) return error.WakeupFdFailed;
    defer _ = c.close(wake);
    interrupted.store(false, .release);
    signal_fd = wake;
    const old_int = c.signal(c.SIGINT, onSignal);
    const old_term = c.signal(c.SIGTERM, onSignal);
    defer {
        _ = c.signal(c.SIGINT, old_int);
        _ = c.signal(c.SIGTERM, old_term);
        signal_fd = -1;
    }
    var context: egl.Context = undefined;
    const egl_start = profile.begin();
    try context.init(client.display);
    profile.mark("process", "EGL context initialized", egl_start);
    defer context.deinit();
    var states: std.ArrayList(*State) = .empty;
    defer {
        for (states.items) |s| {
            s.deinit(&context);
            runtime.destroy(s);
        }
        states.deinit(runtime);
        _ = c.wl_display_flush(client.display);
    }
    var transaction: ?*replacement.Transaction = null;
    defer if (transaction) |t| t.destroy(&context);
    if (cfg.log_level == .info or cfg.log_level == .debug)
        std.debug.print("Playing on {s}; Ctrl-C to stop. Background layer, no input/focus.\n", .{if (cfg.outputs.len == 0) "all outputs (including hotplug)" else "selected outputs"});
    while (!interrupted.load(.acquire)) {
        if (c.wl_display_dispatch_pending(client.display) < 0 or client.failed) return error.WaylandDispatchFailed;
        // Bounded draining prevents command spam from starving Wayland/mpv.
        for (0..32) |_| {
            const request = (try commands.receive()) orelse break;
            const command = request.command orelse {
                commands.reply(request, false);
                continue;
            };
            if ((command == .hide or command == .show) and transaction != null and !transaction.?.cleaning) {
                commands.reject(request, "video replacement in progress; retry visibility command");
                continue;
            }
            switch (command) {
                .set_video => {
                    if (transaction != null) {
                        commands.reject(request, "video replacement or resource cleanup in progress; retry");
                        continue;
                    }
                    const path = config_path orelse {
                        commands.reject(request, "set-video requires persistence; runner was started with --no-config");
                        continue;
                    };
                    transaction = replacement.Transaction.create(request, path, cfg, &client, &context, wake, profile) catch |err| {
                        commands.reject(request, @errorName(err));
                        continue;
                    };
                    continue; // Final reply follows validation and atomic persistence.
                },
                .quit => {
                    commands.reply(request, true);
                    return;
                },
                .hide => if (visible) {
                    visible = false;
                    for (states.items) |s| {
                        if (!s.surface.output.active or s.surface.closed) continue;
                        if (s.video) |video| {
                            try context.makeCurrent(s.window.?.surface);
                            video.hide();
                            try video.setAudible(false);
                            s.audible = false;
                        }
                        try s.surface.hide();
                        s.resume_pending = false;
                    }
                },
                .show => if (!visible) {
                    visible = true;
                    const show_start = profile.begin();
                    for (states.items) |s| {
                        if (!s.surface.output.active or s.surface.closed) continue;
                        s.resume_pending = true;
                        s.resume_start = show_start;
                        s.configure_start = show_start;
                        if (s.video) |video| video.restart();
                        s.surface.show();
                    }
                },
            }
            commands.reply(request, true);
        }
        if (transaction) |t| {
            if (t.cleaning) {
                if (t.reap(&context)) {
                    t.destroy(&context);
                    transaction = null;
                }
            } else validation: {
                const ready_candidate = t.service(cfg, &client, &context, wake, profile) catch |err| {
                    commands.reject(t.request, @errorName(err));
                    t.beginCleanup(&context);
                    break :validation;
                };
                if (ready_candidate) {
                    // Allocate before saving: no fallible bookkeeping after commit.
                    const media = runtime.dupe(u8, t.media) catch {
                        commands.reject(t.request, "out of memory");
                        t.beginCleanup(&context);
                        break :validation;
                    };
                    t.snapshot.save(t.media) catch |err| {
                        runtime.free(media);
                        commands.reject(t.request, @errorName(err));
                        t.beginCleanup(&context);
                        break :validation;
                    };
                    for (t.candidates.items) |candidate| {
                        for (states.items) |s| {
                            if (s.retiring or !s.surface.output.active or s.video == null or s.surface.output.id != candidate.output_id) continue;
                            // Exchange heap pointers, never callback-bearing
                            // structs. Each mpv player retains its own GL context.
                            const previous = s.video;
                            s.video = candidate.video;
                            candidate.video = previous;
                            candidate.hidden = !visible; // old player already unloaded
                            s.video.?.setPaused(cfg.paused);
                            if (!visible) {
                                context.makeCurrent(s.window.?.surface) catch {};
                                s.video.?.hide();
                            } else {
                                s.video.?.forceDraw();
                                s.surface.dirty = true;
                                s.resume_pending = true;
                                s.resume_start = profile.begin();
                            }
                            // Candidates begin muted. Reassign audio next loop.
                            s.audible = false;
                            break;
                        }
                    }
                    cfg.media = media;
                    if (current_media) |previous| runtime.free(previous);
                    current_media = media;
                    commands.reply(t.request, true);
                    t.beginCleanup(&context);
                }
            }
        }
        // Remove surfaces/players before releasing the corresponding wl_output.
        var i: usize = 0;
        while (i < states.items.len) {
            const s = states.items[i];
            if (s.surface.output.active) {
                if (s.surface.closed) return error.LayerSurfaceClosed;
                i += 1;
                continue;
            }
            if (!s.retiring) {
                s.retiring = true;
                if (s.video) |video| {
                    try context.makeCurrent(s.window.?.surface);
                    video.hide();
                }
                try s.surface.hide();
            }
            if (s.video) |video| {
                if (!video.canDeinit()) {
                    i += 1;
                    continue;
                }
            }
            s.deinit(&context);
            runtime.destroy(s);
            _ = states.orderedRemove(i);
        }
        var retiring = false;
        for (states.items) |s| if (s.retiring) {
            retiring = true;
        };
        if (!retiring) client.prune();
        // Never derive dimensions or placements from physical monitor geometry.
        for (client.outputs.items) |o| {
            if (!visible or !o.active or !o.ready or !cfg.selects(o.name)) continue;
            var exists = false;
            for (states.items) |s| if (s.surface.output == o) {
                exists = true;
                break;
            };
            if (exists) continue;
            const s = try runtime.create(State);
            errdefer runtime.destroy(s);
            s.* = .{ .last_scale = o.scale, .configure_start = profile.begin() };
            try s.surface.init(o);
            profile.mark(o.name orelse "unnamed", "layer surface requested", s.configure_start);
            errdefer s.surface.deinit();
            try states.append(runtime, s);
        }
        var any_playing = false;
        var all_finished = states.items.len > 0;
        var audio_assigned = false;
        for (states.items) |s| {
            if (s.retiring) {
                all_finished = false;
                continue;
            }
            const surface = &s.surface;
            if (surface.invalid) return error.InvalidCompositorSurfaceConfiguration;
            // Retained players must consume pending mpv frames even while
            // unmapped or waiting for the new configure/reload to finish.
            if (s.video) |video| {
                if (video.failed()) return error.VideoPlaybackFailed;
                try context.makeCurrent(s.window.?.surface);
                video.pollUpdate();
                if (video.failed()) return error.VideoPlaybackFailed;
                if (!visible or !surface.configured or !video.ready()) {
                    if (video.needsDraw()) {
                        if (visible) {
                            // Prime a paused load in the back buffer before
                            // readiness/configure; never swap or map it yet.
                            try video.draw(s.window.?.width, s.window.?.height);
                            video.reportSwap();
                        } else try video.skip();
                    }
                    // A current load may reach EOF before rendering readiness.
                    // Count it as finished rather than waiting indefinitely.
                    if (!visible or !video.finished()) all_finished = false;
                    continue;
                }
                // Initial readiness can follow a FRAME consumed with SKIP_RENDERING.
                if (!surface.pacing.started and video.hasFrame()) video.forceDraw();
                if (s.resume_pending) {
                    // Playback has restarted for this load; its frame may already
                    // have been consumed with SKIP_RENDERING. Redraw it once.
                    surface.pacing.started = true;
                    surface.dirty = true;
                }
            }
            if (!visible or !surface.configured) {
                all_finished = false;
                continue;
            }
            if (s.last_scale != surface.output.scale) {
                s.last_scale = surface.output.scale;
                surface.dirty = true;
            }
            const size = try surface.dimensions();
            if (s.window == null) {
                const label = surface.output.name orelse "unnamed";
                profile.mark(label, "surface configure observed (includes event-loop waits)", s.configure_start);
                const window_start = profile.begin();
                // Heap-stable player: native callback targets are never copied.
                s.window = .{ .context = &context, .width = size.w, .height = size.h };
                egl.Window.init(&s.window.?, &context, surface.wl.?, size.w, size.h) catch |err| {
                    s.window = null;
                    return err;
                };
                profile.mark(label, "EGL window initialized and current", window_start);
                const p = try runtime.create(player.Player);
                player.Player.init(p, cfg, client.display, wake, label, profile, &context) catch |err| {
                    runtime.destroy(p);
                    return err;
                };
                s.video = p;
                if (cfg.log_level == .info or cfg.log_level == .debug)
                    std.debug.print("[{s}] configured {d}x{d}, buffer {d}x{d} (scale {d}/120)\n", .{ surface.output.name orelse "unnamed", surface.width, surface.height, size.w, size.h, surface.scale_120 });
            }
            const window = &s.window.?;
            const video = s.video.?;
            if (video.failed()) return error.VideoPlaybackFailed;
            const finished = video.finished();
            if (!finished) {
                any_playing = true;
                all_finished = false;
            }
            // Retire/join old audio workers before unmuting replacements.
            const audio_handoff_ready = transaction == null or !transaction.?.cleaning;
            const audible = audio_handoff_ready and !cfg.mute and !audio_assigned and !finished;
            if (audible) audio_assigned = true;
            if (s.audible != audible) {
                try video.setAudible(audible);
                s.audible = audible;
            }
            try context.makeCurrent(window.surface);
            video.pollUpdate();
            if (video.failed()) return error.VideoPlaybackFailed;
            if (!video.ready()) {
                all_finished = false;
                continue;
            }
            // Always service libmpv FRAME updates, even when the compositor
            // withholds callbacks for hidden/fullscreen-covered backgrounds.
            // Consume those frames via SKIP_RENDERING without GPU presentation.
            switch (surface.pacing.action(surface.frame != null, video.needsDraw(), surface.dirty)) {
                .wait => continue,
                .skip => {
                    try video.skip();
                    surface.pacing.skipped();
                    continue;
                },
                .draw => {},
            }
            {
                try surface.prepare();
                window.resize(size.w, size.h);
                const first = !surface.pacing.started;
                const draw_start = if (first) profile.begin() else 0;
                try video.draw(size.w, size.h);
                if (first) profile.mark(video.label, "first frame rendered", draw_start);
                try surface.requestFrame();
                const swap_start = if (first) profile.begin() else 0;
                try window.swap();
                if (first) profile.mark(video.label, "first frame submitted (not confirmed visible)", swap_start);
                if (s.resume_pending) {
                    profile.mark(video.label, "show to first frame submitted (not confirmed visible)", s.resume_start);
                    s.resume_pending = false;
                }
                video.reportSwap();
                surface.dirty = false;
                surface.pacing.presented();
                if (cfg.log_level == .debug and video.drawCount() <= 3)
                    std.debug.print("[{s}] submitted frame #{d}\n", .{ surface.output.name orelse "unnamed", video.drawCount() });
            }
        }
        if (cfg.backend == .ffmpeg) {
            all_finished = states.items.len > 0;
            any_playing = false;
            for (states.items) |s| {
                if (s.retiring or s.video == null or !s.video.?.finished()) all_finished = false;
            }
        }
        if (transaction == null and visible and all_finished and !any_playing) return;
        // prepare_read pairs exactly once with read_events or cancel_read.
        // EGL may have queued events internally; process them before polling.
        if (c.wl_display_prepare_read(client.display) != 0) continue;
        var write_pending = false;
        if (c.wl_display_flush(client.display) < 0) {
            if (c.__errno_location().* == c.EAGAIN) write_pending = true else {
                c.wl_display_cancel_read(client.display);
                return error.WaylandFlushFailed;
            }
        }
        var fds = [_]c.struct_pollfd{
            .{ .fd = c.wl_display_get_fd(client.display), .events = @intCast(c.POLLIN | (if (write_pending) @as(c_int, c.POLLOUT) else 0)), .revents = 0 },
            .{ .fd = wake, .events = c.POLLIN, .revents = 0 },
            .{ .fd = commands.fd, .events = c.POLLIN, .revents = 0 },
        };
        if (interrupted.load(.acquire)) {
            c.wl_display_cancel_read(client.display);
            break;
        }
        // Bounded transaction polling covers decode deadlines and cleanup even
        // when a backend supplies no wakeup (e.g. a failed/paused candidate).
        var timeout: c_int = if (transaction != null) 50 else -1;
        for (states.items) |s| if (s.video) |video| {
            const deadline = video.pollTimeout();
            if (deadline >= 0 and (timeout < 0 or deadline < timeout)) timeout = deadline;
        };
        const ready = c.poll(&fds, fds.len, timeout);
        if (ready < 0) {
            c.wl_display_cancel_read(client.display);
            if (c.__errno_location().* == c.EINTR) continue;
            return error.PollFailed;
        }
        if ((fds[0].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL)) != 0) {
            c.wl_display_cancel_read(client.display);
            return error.WaylandDisconnected;
        }
        if ((fds[0].revents & c.POLLIN) != 0) {
            if (c.wl_display_read_events(client.display) < 0) return error.WaylandReadFailed;
        } else c.wl_display_cancel_read(client.display);
        if ((fds[1].revents & c.POLLIN) != 0) {
            var count: u64 = 0;
            _ = c.read(wake, &count, @sizeOf(u64));
        }
    }
}
