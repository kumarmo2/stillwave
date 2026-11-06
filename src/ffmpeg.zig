const std = @import("std");
const c = @import("c.zig").api;
const enabled = @import("build_options").ffmpeg;
const config = @import("config.zig");
const startup = @import("startup.zig");

/// Render-owner adapter. The C supervisor owns decoder/CUDA lifetime; this type
/// owns CPU mailbox references and GL resources, never waits during hide/show.
pub const Player = struct {
    decoder: ?*c.SWDecoder = null,
    renderer: ?*c.SWYuv = null,
    frame: ?*c.SWFrame = null,
    status: c.SWDecoderStatus = std.mem.zeroes(c.SWDecoderStatus),
    needs_draw: bool = false,
    first_frame_seen: bool = false,
    draw_count: u64 = 0,
    drawn_sequence: u64 = 0,
    submitted_sequence: u64 = 0,
    texture_valid: bool = false,
    local_failed: bool = false,
    requested: bool = true,
    fill: bool = true,
    label: []const u8 = "",
    profile: *const startup.Profile = undefined,
    hide_start: ?u64 = null,
    hide_releases: u64 = 0,
    eof_warned: bool = false,

    pub fn init(self: *Player, cfg: config.Config, wake: c_int, label: []const u8, profile: *const startup.Profile) !void {
        if (!enabled) return error.FfmpegBackendUnavailable;
        self.* = .{ .label = label, .profile = profile, .fill = cfg.scale == .fill };
        errdefer self.deinit();
        const gl_start = profile.begin();
        self.renderer = c.sw_yuv_create() orelse return error.YuvRendererInitializationFailed;
        profile.mark(label, "YUV GPU shader initialized (no CPU color conversion)", gl_start);
        const path = try std.heap.c_allocator.dupeSentinel(u8, cfg.media.?, 0);
        defer std.heap.c_allocator.free(path);
        const name = try std.heap.c_allocator.dupeSentinel(u8, label, 0);
        defer std.heap.c_allocator.free(name);
        self.decoder = c.sw_decoder_create(path, @intFromBool(cfg.loop), @intFromBool(cfg.paused), @intFromBool(cfg.hwdec == .auto), wake, name, @intFromBool(profile.enabled)) orelse return error.FfmpegWorkerCreationFailed;
    }
    pub fn pollUpdate(self: *Player) void {
        if (!enabled) return;
        c.sw_decoder_status(self.decoder, &self.status);
        if (self.hide_start) |since| {
            if (self.status.releases > self.hide_releases or (self.status.busy == 0 and !self.requested)) {
                self.profile.mark(self.label, "FFmpeg playback/video resources released (EGL retained)", since);
                self.hide_start = null;
            }
        }
        if (c.sw_decoder_take(self.decoder)) |frame| {
            if (self.frame) |old| c.sw_frame_free(old);
            self.frame = frame;
            self.needs_draw = true;
            self.first_frame_seen = true;
        }
    }
    pub fn failed(self: *Player) bool {
        return self.local_failed or self.status.failed != 0;
    }
    fn now() u64 {
        var time: c.struct_timespec = undefined;
        if (c.clock_gettime(c.CLOCK_MONOTONIC, &time) != 0) return 0;
        return @as(u64, @intCast(time.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(time.tv_nsec));
    }
    pub fn finished(self: *Player) bool {
        if (self.status.eof == 0) return false;
        if (self.status.last_sequence <= self.submitted_sequence) return true;
        if (self.status.eof_deadline_ns != 0 and now() >= self.status.eof_deadline_ns) {
            if (!self.eof_warned and self.profile.enabled)
                std.debug.print("[{s}/ffmpeg] EOF presentation grace expired; compositor withheld final frame\n", .{self.label});
            self.eof_warned = true;
            return true;
        }
        return false;
    }
    pub fn pollTimeout(self: *Player) c_int {
        if (!self.requested or self.status.eof == 0 or self.status.last_sequence <= self.submitted_sequence) return -1;
        const left = self.status.eof_deadline_ns -| now();
        return @intCast(@min((left + std.time.ns_per_ms - 1) / std.time.ns_per_ms, std.math.maxInt(c_int)));
    }
    pub fn ready(self: *Player) bool {
        return self.requested and (self.frame != null or self.texture_valid);
    }
    pub fn canDeinit(self: *Player) bool {
        if (!enabled) return true;
        c.sw_decoder_status(self.decoder, &self.status);
        return self.status.busy == 0 and self.status.requested == 0;
    }
    pub fn hide(self: *Player) void {
        if (!enabled) return;
        c.sw_decoder_status(self.decoder, &self.status);
        self.hide_releases = self.status.releases;
        self.hide_start = self.profile.begin();
        self.requested = false;
        c.sw_decoder_visibility(self.decoder, 0);
        if (self.frame) |frame| c.sw_frame_free(frame);
        self.frame = null;
        c.sw_yuv_release_video(self.renderer);
        self.texture_valid = false;
        self.needs_draw = false;
        self.first_frame_seen = false;
    }
    pub fn setPaused(self: *Player, paused: bool) void {
        if (enabled) c.sw_decoder_paused(self.decoder, @intFromBool(paused));
    }
    pub fn restart(self: *Player) void {
        if (!enabled) return;
        self.requested = true;
        self.drawn_sequence = 0;
        self.submitted_sequence = 0;
        self.status.eof = 0;
        self.eof_warned = false;
        self.needs_draw = false;
        self.first_frame_seen = false;
        c.sw_decoder_visibility(self.decoder, 1);
    }
    pub fn draw(self: *Player, width: i32, height: i32) !void {
        if (!enabled) return error.FfmpegBackendUnavailable;
        if (self.frame) |frame| {
            const image = c.sw_frame_image(frame);
            if (c.sw_yuv_upload(self.renderer, image) != 0) return error.YuvTextureUploadFailed;
            self.drawn_sequence = image.*.sequence;
            self.texture_valid = true;
            c.sw_frame_free(frame);
            self.frame = null;
        }
        if (!self.texture_valid or c.sw_yuv_draw(self.renderer, width, height, @intFromBool(self.fill)) != 0) return error.YuvDrawFailed;
        self.needs_draw = false;
        self.draw_count += 1;
    }
    pub fn skip(self: *Player) void {
        // Keep the latest CPU frame for a deferred draw, including paused startup.
        self.needs_draw = false;
    }
    pub fn reportSwap(self: *Player) void {
        self.submitted_sequence = self.drawn_sequence;
    }
    pub fn deinit(self: *Player) void {
        if (!enabled) return;
        // Final shutdown may wait for an uninterruptible CUDA operation. Normal
        // hide/show and output retirement only reap after completion.
        if (self.decoder) |decoder| c.sw_decoder_destroy(decoder);
        self.decoder = null;
        if (self.frame) |frame| c.sw_frame_free(frame);
        self.frame = null;
        if (self.renderer) |renderer| c.sw_yuv_destroy(renderer);
        self.renderer = null;
    }
};
