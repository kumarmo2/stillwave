const std = @import("std");
const c = @import("c.zig").api;
const config = @import("config.zig");
const egl = @import("render/egl.zig");
const startup = @import("startup.zig");
const Playback = @import("playback.zig").Playback;

const Worker = struct {
    playback: Playback = .{},
    muted: bool = true,
    unload_start: ?u64 = null,
};
const AtomicBool = std.atomic.Value(bool);

pub fn notify(fd: c_int) void {
    const saved = c.__errno_location().*;
    const one: u64 = 1;
    while (c.write(fd, &one, @sizeOf(u64)) < 0) {
        if (c.__errno_location().* != c.EINTR) break;
    }
    c.__errno_location().* = saved;
}

pub const Player = struct {
    handle: ?*c.mpv_handle = null,
    render: ?*c.mpv_render_context = null,
    thread: ?std.Thread = null,
    wake_fd: c_int,
    label: []const u8,
    log_level: config.LogLevel,
    stop: AtomicBool = .init(false),
    failed: AtomicBool = .init(false),
    finished: AtomicBool = .init(false),
    update: AtomicBool = .init(true),
    // Initial configure dirtiness is not a decoded frame: wait for FRAME.
    needs_draw: bool = false,
    update_count: u64 = 0,
    draw_count: u64 = 0,
    profile: ?*const startup.Profile = null,
    load_start: u64 = 0,
    first_frame_seen: bool = false,
    // Even epochs request showing; odd epochs request hiding. Only the event
    // worker executes playback commands, keeping property/load ordering explicit.
    visibility_epoch: std.atomic.Value(u64) = .init(0),
    ready_epoch: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    audible_requested: AtomicBool = .init(false),
    media: ?[:0]u8 = null,
    start_paused: bool = false,

    /// Stable address required; EGL context must be current until deinit.
    pub fn init(self: *Player, cfg: config.Config, wl: *c.wl_display, wake_fd: c_int, label: []const u8, profile: *const startup.Profile) !void {
        self.* = .{ .wake_fd = wake_fd, .label = label, .log_level = cfg.log_level, .profile = profile, .start_paused = cfg.paused };
        errdefer self.deinit();
        const create_start = profile.begin();
        self.handle = c.mpv_create() orelse return error.MpvCreateFailed;
        profile.mark(label, "mpv handle created", create_start);
        const options_start = profile.begin();
        try self.option("config", "no");
        try self.option("load-scripts", "no");
        try self.option("terminal", "no");
        try self.option("input-default-bindings", "no");
        try self.option("input-vo-keyboard", "no");
        try self.option("input-terminal", "no");
        try self.option("vo", "libmpv");
        try self.option("osd-level", "0");
        try self.option("sub-visibility", "no");
        try self.option("keep-open", "no");
        try self.option("loop-file", if (cfg.loop) "inf" else "no");
        try self.option("pause", if (cfg.paused) "yes" else "no");
        // Never emit duplicated audio while independently rendering outputs.
        try self.option("mute", "yes");
        if (cfg.mute) try self.option("audio", "no");
        try self.option("hwdec", if (cfg.hwdec == .auto) "auto-safe" else "no");
        try self.option("panscan", if (cfg.scale == .fill) "1.0" else "0.0");
        try self.option("video-timing-offset", "0");
        profile.mark(label, "mpv options set", options_start);
        const initialize_start = profile.begin();
        try check(c.mpv_initialize(self.handle));
        profile.mark(label, "mpv initialized", initialize_start);
        const log: [:0]const u8 = switch (cfg.log_level) {
            .quiet => "no",
            .@"error" => "error",
            .warn => "warn",
            .info => "warn",
            .debug => "v",
        };
        try check(c.mpv_request_log_messages(self.handle, log));
        var gl: c.mpv_opengl_init_params = .{ .get_proc_address = egl.getProc, .get_proc_address_ctx = null };
        var params = [_]c.mpv_render_param{
            .{ .type = c.MPV_RENDER_PARAM_API_TYPE, .data = @ptrCast(@constCast(c.MPV_RENDER_API_TYPE_OPENGL)) },
            .{ .type = c.MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, .data = &gl },
            .{ .type = c.MPV_RENDER_PARAM_WL_DISPLAY, .data = wl },
            .{ .type = c.MPV_RENDER_PARAM_INVALID, .data = null },
        };
        const render_start = profile.begin();
        try check(c.mpv_render_context_create(&self.render, self.handle, &params));
        profile.mark(label, "mpv OpenGL render context created", render_start);
        c.mpv_render_context_set_update_callback(self.render, onUpdate, self);
        self.media = try std.heap.c_allocator.dupeSentinel(u8, cfg.media.?, 0);
        // Observe idle-active to wake the worker when asynchronous unloading
        // completes. Query its current value at the barrier, not a stale event.
        try check(c.mpv_observe_property(self.handle, 3, "idle-active", c.MPV_FORMAT_FLAG));
        self.load_start = profile.begin();
        self.thread = try std.Thread.spawn(.{}, events, .{self});
    }
    fn option(self: *Player, key: [:0]const u8, value: [:0]const u8) !void {
        const result = c.mpv_set_option_string(self.handle, key, value);
        if (result < 0) {
            std.debug.print("libmpv option {s}={s}: {s}\n", .{ key, value, std.mem.span(c.mpv_error_string(result)) });
            return error.MpvOptionFailed;
        }
    }
    pub fn setAudible(self: *Player, audible: bool) !void {
        self.audible_requested.store(audible, .release);
        c.mpv_wakeup(self.handle);
    }
    pub fn hide(self: *Player) void {
        _ = self.visibility_epoch.fetchAdd(1, .acq_rel);
        c.mpv_wakeup(self.handle);
    }
    pub fn restart(self: *Player) void {
        _ = self.visibility_epoch.fetchAdd(1, .acq_rel);
        self.needs_draw = false;
        self.finished.store(false, .release);
        c.mpv_wakeup(self.handle);
    }
    pub fn ready(self: *Player) bool {
        return self.ready_epoch.load(.acquire) == self.visibility_epoch.load(.acquire);
    }
    fn setFlag(self: *Player, name: [:0]const u8, enabled: bool) !void {
        var value: c_int = if (enabled) 1 else 0;
        try check(c.mpv_set_property(self.handle, name, c.MPV_FORMAT_FLAG, &value));
    }
    fn serviceControl(self: *Player, worker: *Worker) !bool {
        if (worker.playback.phase == .stopping) {
            var idle: c_int = 0;
            try check(c.mpv_get_property(self.handle, "idle-active", c.MPV_FORMAT_FLAG, &idle));
            if (idle != 0) {
                worker.playback.idle();
                if (worker.unload_start) |since| {
                    if (self.profile) |profile| profile.mark(self.label, "playback unloaded (renderer retained)", since);
                    worker.unload_start = null;
                }
                // The synchronous query may have queued the old END_FILE.
                // Drain those events before allowing a new START_FILE/load.
                return true;
            }
        }
        const desired = self.visibility_epoch.load(.acquire);
        const should_mute = desired % 2 == 1 or !self.ready() or !self.audible_requested.load(.acquire);
        if (should_mute != worker.muted) {
            try self.setFlag("mute", should_mute);
            worker.muted = should_mute;
        }
        switch (worker.playback.next(desired)) {
            .none => return false,
            .stop => {
                // Unlike pause, stop unloads the active file/decoder. Commands
                // stay on the worker; the render owner keeps servicing frames.
                if (self.profile) |profile| worker.unload_start = profile.begin();
                worker.playback.stop();
                const args = [_][*c]const u8{ "stop", null };
                try check(c.mpv_command(self.handle, @constCast(&args)));
                return true;
            },
            .load => {
                try self.setFlag("pause", self.start_paused);
                self.finished.store(false, .release);
                worker.playback.load(desired);
                const args = [_][*c]const u8{ "loadfile", self.media.?.ptr, "replace", null };
                try check(c.mpv_command(self.handle, @constCast(&args)));
                if (desired == 0) {
                    if (self.profile) |profile| profile.mark(self.label, "media load requested (worker)", self.load_start);
                }
                return true;
            },
        }
    }
    pub fn pollUpdate(self: *Player) void {
        if (self.update.swap(false, .acq_rel)) {
            const flags = c.mpv_render_context_update(self.render);
            self.update_count += 1;
            if (self.log_level == .debug and self.update_count <= 3)
                std.debug.print("[{s}] render update #{d}: flags={d}\n", .{ self.label, self.update_count, flags });
            if ((flags & c.MPV_RENDER_UPDATE_FRAME) != 0) {
                self.needs_draw = true;
                if (!self.first_frame_seen) {
                    self.first_frame_seen = true;
                    if (self.profile) |profile| profile.mark(self.label, "first mpv FRAME update observed since load request", self.load_start);
                }
            }
        }
    }
    pub fn draw(self: *Player, w: i32, h: i32) !void {
        var fbo: c.mpv_opengl_fbo = .{ .fbo = 0, .w = w, .h = h, .internal_format = 0 };
        var flip: c_int = 1;
        var block: c_int = 0;
        var params = [_]c.mpv_render_param{
            .{ .type = c.MPV_RENDER_PARAM_OPENGL_FBO, .data = &fbo },
            .{ .type = c.MPV_RENDER_PARAM_FLIP_Y, .data = &flip },
            .{ .type = c.MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, .data = &block },
            .{ .type = c.MPV_RENDER_PARAM_INVALID, .data = null },
        };
        try check(c.mpv_render_context_render(self.render, &params));
        self.needs_draw = false;
        self.draw_count += 1;
    }
    pub fn skip(self: *Player) !void {
        var skip_frame: c_int = 1;
        var block: c_int = 0;
        var params = [_]c.mpv_render_param{
            .{ .type = c.MPV_RENDER_PARAM_SKIP_RENDERING, .data = &skip_frame },
            .{ .type = c.MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, .data = &block },
            .{ .type = c.MPV_RENDER_PARAM_INVALID, .data = null },
        };
        try check(c.mpv_render_context_render(self.render, &params));
        self.needs_draw = false;
        c.mpv_render_context_report_swap(self.render);
        if (self.log_level == .debug and self.update_count <= 5)
            std.debug.print("[{s}] consumed frame without presenting (compositor callback pending)\n", .{self.label});
    }
    pub fn deinit(self: *Player) void {
        self.stop.store(true, .release);
        if (self.render) |r| {
            c.mpv_render_context_set_update_callback(r, null, null);
            c.mpv_render_context_free(r);
            self.render = null;
        }
        if (self.thread) |thread| {
            c.mpv_wakeup(self.handle);
            thread.join();
            self.thread = null;
        }
        if (self.handle) |h| {
            c.mpv_terminate_destroy(h);
            self.handle = null;
        }
        if (self.media) |media| std.heap.c_allocator.free(media);
        self.media = null;
    }
    fn onUpdate(data: ?*anyopaque) callconv(.c) void {
        const self: *Player = @ptrCast(@alignCast(data.?));
        self.update.store(true, .release);
        notify(self.wake_fd);
    }
    fn fail(self: *Player) void {
        self.failed.store(true, .release);
        notify(self.wake_fd);
    }
    fn events(self: *Player) void {
        var worker: Worker = .{};
        while (!self.stop.load(.acquire)) {
            var event = c.mpv_wait_event(self.handle, 0).*;
            if (event.event_id == c.MPV_EVENT_NONE) {
                const issued = self.serviceControl(&worker) catch {
                    self.fail();
                    return;
                };
                if (issued) continue;
                event = c.mpv_wait_event(self.handle, -1).*;
            }
            if (self.stop.load(.acquire)) return;
            switch (event.event_id) {
                c.MPV_EVENT_END_FILE => {
                    const end: *c.mpv_event_end_file = @ptrCast(@alignCast(event.data.?));
                    if (end.reason == c.MPV_END_FILE_REASON_ERROR) {
                        std.debug.print("[{s}] playback failed: {s}\n", .{ self.label, std.mem.span(c.mpv_error_string(end.@"error")) });
                        self.fail();
                    } else if (end.reason == c.MPV_END_FILE_REASON_EOF and
                        worker.playback.phase != .stopping and
                        worker.playback.epoch == self.visibility_epoch.load(.acquire))
                    {
                        self.finished.store(true, .release);
                        notify(self.wake_fd);
                    }
                    // END_FILE can precede idle-active. Always clear loading
                    // state, even if a canceled load never reached restart.
                    worker.playback.stop();
                },
                c.MPV_EVENT_COMMAND_REPLY, c.MPV_EVENT_SET_PROPERTY_REPLY => {
                    if (event.@"error" < 0) {
                        std.debug.print("[{s}] mpv command failed: {s}\n", .{ self.label, std.mem.span(c.mpv_error_string(event.@"error")) });
                        self.fail();
                    }
                },
                c.MPV_EVENT_START_FILE => {
                    worker.playback.startFile();
                    self.finished.store(false, .release);
                },
                c.MPV_EVENT_PLAYBACK_RESTART => {
                    if (worker.playback.restart()) |epoch| {
                        self.ready_epoch.store(epoch, .release);
                        notify(self.wake_fd);
                    }
                },
                c.MPV_EVENT_FILE_LOADED => {
                    const vid = c.mpv_get_property_string(self.handle, "vid");
                    defer c.mpv_free(vid);
                    if (vid == null or std.mem.eql(u8, std.mem.span(vid), "no")) {
                        std.debug.print("[{s}] input has no selected video track\n", .{self.label});
                        self.fail();
                    }
                },
                c.MPV_EVENT_VIDEO_RECONFIG => {
                    const decoder = c.mpv_get_property_string(self.handle, "hwdec-current");
                    defer c.mpv_free(decoder);
                    if (decoder != null and (self.log_level == .info or self.log_level == .debug))
                        std.debug.print("[{s}] hardware decoder: {s}\n", .{ self.label, std.mem.span(decoder) });
                },
                c.MPV_EVENT_LOG_MESSAGE => {
                    const msg: *c.mpv_event_log_message = @ptrCast(@alignCast(event.data.?));
                    std.debug.print("[{s}/mpv/{s}] {s}", .{ self.label, std.mem.span(msg.prefix), std.mem.span(msg.text) });
                },
                c.MPV_EVENT_SHUTDOWN => {
                    if (!self.stop.load(.acquire)) self.fail();
                    return;
                },
                c.MPV_EVENT_QUEUE_OVERFLOW => self.fail(),
                else => {},
            }
        }
    }
};
fn check(result: c_int) !void {
    if (result < 0) {
        std.debug.print("libmpv: {s}\n", .{std.mem.span(c.mpv_error_string(result))});
        return error.MpvFailed;
    }
}
