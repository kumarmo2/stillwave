//! Staged replacement: candidates never own a mapped layer surface and never
//! become audible. Original players remain untouched until every candidate is
//! ready and the media-only config update succeeds. Stable heap addresses keep
//! native callbacks safe across the final pointer exchange.
const std = @import("std");
const config = @import("config.zig");
const control = @import("control.zig");
const persistence = @import("persistence.zig");
const support = @import("support.zig");
const wl = @import("platform/wayland.zig");
const egl = @import("render/egl.zig");
const backend = @import("backend.zig");
const startup = @import("startup.zig");
const c = @import("c.zig").api;
const a = std.heap.c_allocator;

pub const Candidate = struct {
    output_id: u32,
    label: []const u8,
    surface: *c.wl_surface,
    window: egl.Window,
    video: ?*backend.Player = null,
    validated: bool = false,
    hidden: bool = false,

    fn destroy(self: *Candidate, context: *egl.Context) void {
        context.makeCurrent(self.window.surface) catch {};
        if (self.video) |p| {
            p.deinit();
            a.destroy(p);
        }
        self.window.deinit();
        c.wl_surface_destroy(self.surface);
        a.free(self.label);
        a.destroy(self);
    }
};

pub const Transaction = struct {
    request: control.Request,
    media: []const u8,
    snapshot: persistence.Snapshot,
    candidates: std.ArrayList(*Candidate) = .empty,
    cleaning: bool = false,
    deadline: u64,

    pub fn create(request: control.Request, path: []const u8, cfg: config.Config, client: *wl.Client, context: *egl.Context, wake: c_int, profile: *const startup.Profile) !*Transaction {
        var snapshot = try persistence.Snapshot.init(path);
        errdefer snapshot.deinit();
        const media = try a.dupe(u8, request.path[0..request.path_len]);
        errdefer a.free(media);
        var candidate_cfg = cfg;
        candidate_cfg.media = media;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var d: support.Diagnostic = .{};
        try config.validateRunnable(arena.allocator(), candidate_cfg, &d);
        const self = try a.create(Transaction);
        self.* = .{ .request = request, .media = media, .snapshot = snapshot, .deadline = profile.begin() + 30 * std.time.ns_per_s };
        // Fallible construction is incremental in service(), so failed players
        // are never destroyed while their decoder is still busy on this path.
        errdefer {
            for (self.candidates.items) |candidate| candidate.destroy(context);
            self.candidates.deinit(a);
            a.destroy(self);
        }
        for (client.outputs.items) |o| {
            if (!o.active or !o.ready or !cfg.selects(o.name)) continue;
            const candidate = try a.create(Candidate);
            errdefer a.destroy(candidate);
            const label = try a.dupe(u8, o.name orelse "unnamed");
            errdefer a.free(label);
            const surface = c.wl_compositor_create_surface(client.compositor) orelse return error.ProbeSurfaceFailed;
            errdefer c.wl_surface_destroy(surface);
            // No role, commit, frame callback or swap: this surface never maps.
            var window: egl.Window = undefined;
            try window.init(context, surface, 16, 16);
            errdefer window.deinit();
            candidate.* = .{ .output_id = o.id, .label = label, .surface = surface, .window = window };
            self.candidates.append(a, candidate) catch |err| return err;
        }
        _ = wake;
        if (self.candidates.items.len == 0) return error.NoSelectedOutputsForValidation;
        return self;
    }

    /// Returns true after an actual frame has been decoded AND drawn offscreen
    /// on each selected output. Includes paused videos; no presentation required.
    pub fn service(self: *Transaction, cfg: config.Config, client: *wl.Client, context: *egl.Context, wake: c_int, profile: *const startup.Profile) !bool {
        if (profile.begin() >= self.deadline) return error.VideoReplacementTimedOut;
        var count: usize = 0;
        for (client.outputs.items) |o| {
            if (!o.active or !o.ready or !cfg.selects(o.name)) continue;
            count += 1;
            var found = false;
            for (self.candidates.items) |candidate| if (candidate.output_id == o.id) {
                found = true;
            };
            if (!found) return error.OutputsChangedDuringReplacement;
        }
        if (count != self.candidates.items.len) return error.OutputsChangedDuringReplacement;
        var ready = true;
        for (self.candidates.items) |candidate| {
            try context.makeCurrent(candidate.window.surface);
            if (candidate.video == null) {
                const p = try a.create(backend.Player);
                errdefer a.destroy(p);
                var candidate_cfg = cfg;
                candidate_cfg.media = self.media;
                // Hold frame zero until commit: short nonlooping videos must
                // not finish while another output/config write is pending.
                candidate_cfg.paused = true;
                // Backend init already starts muted even when audio is enabled.
                try p.init(candidate_cfg, client.display, wake, candidate.label, profile, context);
                candidate.video = p;
            }
            const p = candidate.video.?;
            p.pollUpdate();
            if (p.failed()) return error.CandidateVideoPlaybackFailed;
            // Prime the renderer even before the worker's PLAYBACK_RESTART
            // event; decoder/render readiness and event delivery are distinct.
            // No EGL swap or compositor presentation occurs here.
            if (p.needsDraw() or (p.ready() and p.hasFrame() and !candidate.validated)) {
                try p.draw(16, 16);
                p.reportSwap(); // service libmpv; no EGL/compositor swap
                if (p.ready() and p.hasFrame()) candidate.validated = true;
            }
            if (!candidate.validated) ready = false;
        }
        return ready;
    }
    pub fn beginCleanup(self: *Transaction, context: *egl.Context) void {
        self.cleaning = true;
        for (self.candidates.items) |candidate| {
            if (candidate.video) |p| {
                context.makeCurrent(candidate.window.surface) catch {};
                if (!candidate.hidden) p.hide();
                candidate.hidden = true;
            }
        }
    }
    pub fn reap(self: *Transaction, context: *egl.Context) bool {
        var i: usize = 0;
        while (i < self.candidates.items.len) {
            const candidate = self.candidates.items[i];
            context.makeCurrent(candidate.window.surface) catch {};
            if (candidate.video) |p| {
                p.pollUpdate();
                if (p.needsDraw()) p.skip() catch {};
                if (!p.canDeinit()) {
                    i += 1;
                    continue;
                }
            }
            candidate.destroy(context);
            _ = self.candidates.orderedRemove(i);
        }
        return self.candidates.items.len == 0;
    }
    pub fn destroy(self: *Transaction, context: *egl.Context) void {
        for (self.candidates.items) |candidate| candidate.destroy(context);
        self.candidates.deinit(a);
        self.snapshot.deinit();
        a.free(self.media);
        a.destroy(self);
    }
};
