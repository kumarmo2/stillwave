const std = @import("std");
const config = @import("config.zig");
const startup = @import("startup.zig");
const mpv = @import("player.zig");
const ffmpeg = @import("ffmpeg.zig");
const c = @import("c.zig").api;
pub const notify = mpv.notify;

/// Stable-address adapter: mpv callbacks must retain the in-place implementation.
pub const Player = struct {
    wake_fd: c_int,
    label: []const u8,
    log_level: config.LogLevel,
    implementation: union(config.Backend) { mpv: mpv.Player, ffmpeg: ffmpeg.Player } = undefined,

    pub fn init(self: *Player, cfg: config.Config, display: *c.wl_display, wake: c_int, label: []const u8, profile: *const startup.Profile) !void {
        self.* = .{ .wake_fd = wake, .label = label, .log_level = cfg.log_level };
        switch (cfg.backend) {
            .mpv => {
                self.implementation = .{ .mpv = .{ .wake_fd = wake, .label = label, .log_level = cfg.log_level } };
                try self.implementation.mpv.init(cfg, display, wake, label, profile);
            },
            .ffmpeg => {
                self.implementation = .{ .ffmpeg = .{} };
                try self.implementation.ffmpeg.init(cfg, wake, label, profile);
            },
        }
    }
    pub fn failed(self: *Player) bool {
        return switch (self.implementation) {
            .mpv => |*p| p.failed.load(.acquire),
            .ffmpeg => |*p| p.failed(),
        };
    }
    pub fn finished(self: *Player) bool {
        return switch (self.implementation) {
            .mpv => |*p| p.finished.load(.acquire),
            .ffmpeg => |*p| p.finished(),
        };
    }
    pub fn needsDraw(self: *Player) bool {
        return switch (self.implementation) {
            .mpv => |*p| p.needs_draw,
            .ffmpeg => |*p| p.needs_draw,
        };
    }
    pub fn hasFrame(self: *Player) bool {
        return switch (self.implementation) {
            .mpv => |*p| p.first_frame_seen,
            .ffmpeg => |*p| p.ready(),
        };
    }
    pub fn forceDraw(self: *Player) void {
        switch (self.implementation) {
            .mpv => |*p| p.needs_draw = true,
            .ffmpeg => |*p| p.needs_draw = true,
        }
    }
    pub fn ready(self: *Player) bool {
        return switch (self.implementation) {
            .mpv => |*p| p.ready(),
            .ffmpeg => |*p| p.ready(),
        };
    }
    pub fn pollTimeout(self: *Player) c_int {
        return switch (self.implementation) {
            .mpv => -1,
            .ffmpeg => |*p| p.pollTimeout(),
        };
    }
    pub fn canDeinit(self: *Player) bool {
        return switch (self.implementation) {
            .mpv => true,
            .ffmpeg => |*p| p.canDeinit(),
        };
    }
    pub fn hide(self: *Player) void {
        switch (self.implementation) {
            .mpv => |*p| p.hide(),
            .ffmpeg => |*p| p.hide(),
        }
    }
    pub fn restart(self: *Player) void {
        switch (self.implementation) {
            .mpv => |*p| p.restart(),
            .ffmpeg => |*p| p.restart(),
        }
    }
    pub fn setAudible(self: *Player, audible: bool) !void {
        switch (self.implementation) {
            .mpv => |*p| try p.setAudible(audible),
            .ffmpeg => if (audible) return error.FfmpegAudioUnsupported,
        }
    }
    pub fn pollUpdate(self: *Player) void {
        switch (self.implementation) {
            .mpv => |*p| p.pollUpdate(),
            .ffmpeg => |*p| p.pollUpdate(),
        }
    }
    pub fn draw(self: *Player, w: i32, h: i32) !void {
        switch (self.implementation) {
            .mpv => |*p| try p.draw(w, h),
            .ffmpeg => |*p| try p.draw(w, h),
        }
    }
    pub fn skip(self: *Player) !void {
        switch (self.implementation) {
            .mpv => |*p| try p.skip(),
            .ffmpeg => |*p| p.skip(),
        }
    }
    pub fn reportSwap(self: *Player) void {
        switch (self.implementation) {
            .mpv => |*p| c.mpv_render_context_report_swap(p.render),
            .ffmpeg => |*p| p.reportSwap(),
        }
    }
    pub fn drawCount(self: *Player) u64 {
        return switch (self.implementation) {
            .mpv => |*p| p.draw_count,
            .ffmpeg => |*p| p.draw_count,
        };
    }
    pub fn deinit(self: *Player) void {
        switch (self.implementation) {
            .mpv => |*p| p.deinit(),
            .ffmpeg => |*p| p.deinit(),
        }
    }
};
