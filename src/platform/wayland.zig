const std = @import("std");
const c = @import("../c.zig").api;
const Allocator = std.mem.Allocator;
const Pacing = @import("../render/pacing.zig").Pacing;

fn ptr(comptime T: type, data: ?*anyopaque) *T {
    return @ptrCast(@alignCast(data.?));
}
fn same(p: [*c]const u8, s: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(p), s);
}

pub const Output = struct {
    client: *Client,
    id: u32,
    proxy: *c.wl_output,
    version: u32,
    xdg: ?*c.zxdg_output_v1 = null,
    active: bool = true,
    ready: bool = false,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    width: i32 = 0,
    height: i32 = 0,
    refresh_mhz: i32 = 0,
    scale: i32 = 1,
    transform: i32 = 0,

    fn setText(self: *Output, dest: *?[]const u8, text: [*c]const u8) void {
        const copy = self.client.a.dupe(u8, std.mem.span(text)) catch {
            self.client.failed = true;
            return;
        };
        if (dest.*) |old| self.client.a.free(old);
        dest.* = copy;
    }
    fn attachXdg(self: *Output) void {
        if (self.xdg != null or self.version >= 4) return;
        if (self.client.xdg_manager) |manager| {
            self.xdg = c.zxdg_output_manager_v1_get_xdg_output(manager, self.proxy);
            if (self.xdg) |x| {
                _ = c.zxdg_output_v1_add_listener(x, &xdg_listener, self);
            } else self.client.failed = true;
        }
    }
    fn deinit(self: *Output) void {
        if (self.xdg) |x| c.zxdg_output_v1_destroy(x);
        if (self.version >= 3) c.wl_output_release(self.proxy) else c.wl_output_destroy(self.proxy);
        if (self.name) |s| self.client.a.free(s);
        if (self.description) |s| self.client.a.free(s);
    }
};

pub const Client = struct {
    a: Allocator,
    display: *c.wl_display,
    registry: ?*c.wl_registry = null,
    compositor: ?*c.wl_compositor = null,
    shell: ?*c.zwlr_layer_shell_v1 = null,
    xdg_manager: ?*c.zxdg_output_manager_v1 = null,
    viewporter: ?*c.wp_viewporter = null,
    fractional_manager: ?*c.wp_fractional_scale_manager_v1 = null,
    outputs: std.ArrayList(*Output) = .empty,
    failed: bool = false,

    // Caller keeps Client at a stable address until deinit (listeners retain it).
    pub fn init(self: *Client, a: Allocator) !void {
        self.* = .{ .a = a, .display = c.wl_display_connect(null) orelse return error.WaylandConnectionFailed };
        errdefer self.deinit();
        self.registry = c.wl_display_get_registry(self.display) orelse return error.WaylandRegistryFailed;
        if (c.wl_registry_add_listener(self.registry, &registry_listener, self) != 0) return error.WaylandListenerFailed;
        try self.roundtrip();
        for (self.outputs.items) |o| o.attachXdg();
        try self.roundtrip();
        try self.roundtrip();
    }
    pub fn roundtrip(self: *Client) !void {
        if (c.wl_display_roundtrip(self.display) < 0 or self.failed) return error.WaylandDiscoveryFailed;
    }
    pub fn deinit(self: *Client) void {
        for (self.outputs.items) |o| {
            o.deinit();
            self.a.destroy(o);
        }
        self.outputs.deinit(self.a);
        if (self.fractional_manager) |p| c.wp_fractional_scale_manager_v1_destroy(p);
        if (self.viewporter) |p| c.wp_viewporter_destroy(p);
        if (self.xdg_manager) |p| c.zxdg_output_manager_v1_destroy(p);
        if (self.shell) |p| {
            if (c.zwlr_layer_shell_v1_get_version(p) >= 3) c.zwlr_layer_shell_v1_destroy(p) else c.wl_proxy_destroy(@ptrCast(p));
        }
        if (self.compositor) |p| c.wl_compositor_destroy(p);
        if (self.registry) |p| c.wl_registry_destroy(p);
        c.wl_display_disconnect(self.display);
    }
    /// Call only after the application has destroyed surfaces on removed outputs.
    pub fn prune(self: *Client) void {
        var i: usize = 0;
        while (i < self.outputs.items.len) {
            const o = self.outputs.items[i];
            if (o.active) {
                i += 1;
                continue;
            }
            _ = self.outputs.orderedRemove(i);
            o.deinit();
            self.a.destroy(o);
        }
    }
};

fn global(data: ?*anyopaque, _: ?*c.wl_registry, id: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const self = ptr(Client, data);
    const r = self.registry;
    if (same(interface, "wl_compositor")) {
        self.compositor = @ptrCast(c.wl_registry_bind(r, id, &c.wl_compositor_interface, @min(version, 4)));
    } else if (same(interface, "zwlr_layer_shell_v1")) {
        self.shell = @ptrCast(c.wl_registry_bind(r, id, &c.zwlr_layer_shell_v1_interface, @min(version, 4)));
    } else if (same(interface, "zxdg_output_manager_v1")) {
        self.xdg_manager = @ptrCast(c.wl_registry_bind(r, id, &c.zxdg_output_manager_v1_interface, @min(version, 3)));
        for (self.outputs.items) |o| o.attachXdg();
    } else if (same(interface, "wp_viewporter")) {
        self.viewporter = @ptrCast(c.wl_registry_bind(r, id, &c.wp_viewporter_interface, 1));
    } else if (same(interface, "wp_fractional_scale_manager_v1")) {
        self.fractional_manager = @ptrCast(c.wl_registry_bind(r, id, &c.wp_fractional_scale_manager_v1_interface, 1));
    } else if (same(interface, "wl_output")) {
        const o = self.a.create(Output) catch {
            self.failed = true;
            return;
        };
        const v = @min(version, 4);
        const proxy: *c.wl_output = @ptrCast(c.wl_registry_bind(r, id, &c.wl_output_interface, v) orelse {
            self.a.destroy(o);
            self.failed = true;
            return;
        });
        o.* = .{ .client = self, .id = id, .proxy = proxy, .version = v, .ready = v < 2 };
        self.outputs.append(self.a, o) catch {
            o.deinit();
            self.a.destroy(o);
            self.failed = true;
            return;
        };
        _ = c.wl_output_add_listener(proxy, &output_listener, o);
        o.attachXdg();
    }
}
fn removed(data: ?*anyopaque, _: ?*c.wl_registry, id: u32) callconv(.c) void {
    const self = ptr(Client, data);
    for (self.outputs.items) |o| if (o.id == id) {
        o.active = false;
        return;
    };
}
const registry_listener: c.wl_registry_listener = .{ .global = global, .global_remove = removed };
fn geometry(data: ?*anyopaque, _: ?*c.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, transform: i32) callconv(.c) void {
    ptr(Output, data).transform = transform;
}
fn mode(data: ?*anyopaque, _: ?*c.wl_output, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void {
    if ((flags & c.WL_OUTPUT_MODE_CURRENT) == 0) return;
    const o = ptr(Output, data);
    o.width = width;
    o.height = height;
    o.refresh_mhz = refresh;
}
fn done(data: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {
    ptr(Output, data).ready = true;
}
fn scale(data: ?*anyopaque, _: ?*c.wl_output, factor: i32) callconv(.c) void {
    ptr(Output, data).scale = @max(1, factor);
}
fn name(data: ?*anyopaque, _: ?*c.wl_output, text: [*c]const u8) callconv(.c) void {
    const o = ptr(Output, data);
    o.setText(&o.name, text);
}
fn description(data: ?*anyopaque, _: ?*c.wl_output, text: [*c]const u8) callconv(.c) void {
    const o = ptr(Output, data);
    o.setText(&o.description, text);
}
const output_listener: c.wl_output_listener = .{ .geometry = geometry, .mode = mode, .done = done, .scale = scale, .name = name, .description = description };
fn logicalPosition(_: ?*anyopaque, _: ?*c.zxdg_output_v1, _: i32, _: i32) callconv(.c) void {}
fn logicalSize(_: ?*anyopaque, _: ?*c.zxdg_output_v1, _: i32, _: i32) callconv(.c) void {}
fn xdgDone(data: ?*anyopaque, _: ?*c.zxdg_output_v1) callconv(.c) void {
    ptr(Output, data).ready = true;
}
fn xdgName(data: ?*anyopaque, _: ?*c.zxdg_output_v1, text: [*c]const u8) callconv(.c) void {
    const o = ptr(Output, data);
    o.setText(&o.name, text);
}
fn xdgDescription(data: ?*anyopaque, _: ?*c.zxdg_output_v1, text: [*c]const u8) callconv(.c) void {
    const o = ptr(Output, data);
    o.setText(&o.description, text);
}
const xdg_listener: c.zxdg_output_v1_listener = .{ .logical_position = logicalPosition, .logical_size = logicalSize, .done = xdgDone, .name = xdgName, .description = xdgDescription };

pub const Surface = struct {
    output: *Output,
    wl: ?*c.wl_surface = null,
    layer: ?*c.zwlr_layer_surface_v1 = null,
    viewport: ?*c.wp_viewport = null,
    fractional: ?*c.wp_fractional_scale_v1 = null,
    frame: ?*c.wl_callback = null,
    pacing: Pacing = .{},
    width: u32 = 0,
    height: u32 = 0,
    scale_120: u32 = 120,
    fractional_received: bool = false,
    configured: bool = false,
    closed: bool = false,
    dirty: bool = true,
    invalid: bool = false,

    pub fn init(self: *Surface, o: *Output) !void {
        const client = o.client;
        self.* = .{ .output = o, .scale_120 = @as(u32, @intCast(o.scale)) * 120 };
        errdefer self.deinit();
        self.wl = c.wl_compositor_create_surface(client.compositor) orelse return error.SurfaceCreationFailed;
        self.layer = c.zwlr_layer_shell_v1_get_layer_surface(client.shell, self.wl, o.proxy, c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "wallpaper-zig") orelse return error.LayerSurfaceCreationFailed;
        _ = c.zwlr_layer_surface_v1_add_listener(self.layer, &layer_listener, self);
        c.zwlr_layer_surface_v1_set_size(self.layer, 0, 0);
        c.zwlr_layer_surface_v1_set_anchor(self.layer, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
        c.zwlr_layer_surface_v1_set_exclusive_zone(self.layer, -1);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(self.layer, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
        const region = c.wl_compositor_create_region(client.compositor) orelse return error.RegionCreationFailed;
        c.wl_surface_set_input_region(self.wl, region);
        c.wl_region_destroy(region);
        if (client.viewporter) |v| {
            self.viewport = c.wp_viewporter_get_viewport(v, self.wl) orelse return error.ViewportCreationFailed;
            if (client.fractional_manager) |f| {
                self.fractional = c.wp_fractional_scale_manager_v1_get_fractional_scale(f, self.wl) orelse return error.ScaleCreationFailed;
                _ = c.wp_fractional_scale_v1_add_listener(self.fractional, &fractional_listener, self);
            }
        }
        c.wl_surface_commit(self.wl);
    }
    pub fn deinit(self: *Surface) void {
        if (self.frame) |p| c.wl_callback_destroy(p);
        if (self.fractional) |p| c.wp_fractional_scale_v1_destroy(p);
        if (self.viewport) |p| c.wp_viewport_destroy(p);
        if (self.layer) |p| c.zwlr_layer_surface_v1_destroy(p);
        if (self.wl) |p| c.wl_surface_destroy(p);
    }
    pub fn dimensions(self: *Surface) !struct { w: i32, h: i32 } {
        if (!self.fractional_received) self.scale_120 = @as(u32, @intCast(self.output.scale)) * 120;
        return .{ .w = try pixels(self.width, self.scale_120), .h = try pixels(self.height, self.scale_120) };
    }
    pub fn prepare(self: *Surface) !void {
        if (self.viewport) |v| {
            c.wl_surface_set_buffer_scale(self.wl, 1);
            c.wp_viewport_set_destination(v, @intCast(self.width), @intCast(self.height));
        } else {
            if (c.wl_surface_get_version(self.wl) >= 3) {
                c.wl_surface_set_buffer_scale(self.wl, self.output.scale);
            } else if (self.output.scale != 1) return error.BufferScaleUnsupported;
        }
        const region = c.wl_compositor_create_region(self.output.client.compositor) orelse return error.RegionCreationFailed;
        c.wl_region_add(region, 0, 0, @intCast(self.width), @intCast(self.height));
        c.wl_surface_set_opaque_region(self.wl, region);
        c.wl_region_destroy(region);
    }
    pub fn requestFrame(self: *Surface) !void {
        self.frame = c.wl_surface_frame(self.wl) orelse return error.FrameCallbackFailed;
        _ = c.wl_callback_add_listener(self.frame, &frame_listener, self);
    }
};
fn configure(data: ?*anyopaque, layer: ?*c.zwlr_layer_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
    const self = ptr(Surface, data);
    c.zwlr_layer_surface_v1_ack_configure(layer, serial);
    if (width == 0 or height == 0 or width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) {
        self.invalid = true;
        return;
    }
    self.width = width;
    self.height = height;
    self.configured = true;
    self.dirty = true;
}
fn closed(data: ?*anyopaque, _: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
    ptr(Surface, data).closed = true;
}
const layer_listener: c.zwlr_layer_surface_v1_listener = .{ .configure = configure, .closed = closed };
fn preferred(data: ?*anyopaque, _: ?*c.wp_fractional_scale_v1, factor: u32) callconv(.c) void {
    const self = ptr(Surface, data);
    if (factor == 0) {
        self.invalid = true;
        return;
    }
    self.scale_120 = factor;
    self.fractional_received = true;
    self.dirty = true;
}
const fractional_listener: c.wp_fractional_scale_v1_listener = .{ .preferred_scale = preferred };
fn frameDone(data: ?*anyopaque, cb: ?*c.wl_callback, _: u32) callconv(.c) void {
    c.wl_callback_destroy(cb);
    const surface = ptr(Surface, data);
    surface.frame = null;
    if (surface.pacing.frameDone()) surface.dirty = true;
}
const frame_listener: c.wl_callback_listener = .{ .done = frameDone };

pub fn pixels(logical: u32, scale_120: u32) !i32 {
    const n = (@as(u64, logical) * scale_120 + 60) / 120;
    if (n == 0 or n > std.math.maxInt(i32)) return error.InvalidSurfaceSize;
    return @intCast(n);
}

test "buffer size derives only from configured logical size and preferred scale" {
    try std.testing.expectEqual(@as(i32, 1920), try pixels(1920, 120));
    try std.testing.expectEqual(@as(i32, 2400), try pixels(1920, 150));
    try std.testing.expectEqual(@as(i32, 2160), try pixels(1080, 240));
    try std.testing.expectEqual(@as(i32, 126), try pixels(101, 150));
    try std.testing.expectEqual(@as(i32, 128), try pixels(102, 150));
    try std.testing.expectError(error.InvalidSurfaceSize, pixels(0, 120));
    try std.testing.expectError(error.InvalidSurfaceSize, pixels(std.math.maxInt(u32), 240));
}
