const c = @import("../c.zig").api;

pub const Context = struct {
    display: c.EGLDisplay = null,
    config: c.EGLConfig = null,
    context: c.EGLContext = null,

    pub fn init(self: *Context, wl: *c.wl_display) !void {
        self.* = .{};
        self.display = c.eglGetDisplay(@ptrCast(wl));
        if (self.display == null) return error.EglDisplayFailed;
        if (c.eglInitialize(self.display, null, null) == c.EGL_FALSE) return error.EglInitializeFailed;
        errdefer self.deinit();
        if (c.eglBindAPI(c.EGL_OPENGL_API) == c.EGL_FALSE) return error.EglOpenGlUnavailable;
        const attributes = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      0,
            c.EGL_NONE,
        };
        var count: c.EGLint = 0;
        if (c.eglChooseConfig(self.display, &attributes, &self.config, 1, &count) == c.EGL_FALSE or count == 0)
            return error.EglConfigUnavailable;
        const context_attributes = [_]c.EGLint{c.EGL_NONE};
        self.context = c.eglCreateContext(self.display, self.config, null, &context_attributes);
        if (self.context == null) return error.EglContextFailed;
    }
    pub fn deinit(self: *Context) void {
        if (self.display != null) {
            _ = c.eglMakeCurrent(self.display, null, null, null);
            if (self.context != null) _ = c.eglDestroyContext(self.display, self.context);
            _ = c.eglTerminate(self.display);
        }
    }
    pub fn makeCurrent(self: *Context, surface: c.EGLSurface) !void {
        if (c.eglMakeCurrent(self.display, surface, surface, self.context) == c.EGL_FALSE) return error.EglMakeCurrentFailed;
    }
};

pub const Window = struct {
    context: *Context,
    native: ?*c.wl_egl_window = null,
    surface: c.EGLSurface = null,
    width: i32,
    height: i32,

    pub fn init(self: *Window, context: *Context, surface: *c.wl_surface, w: i32, h: i32) !void {
        self.* = .{ .context = context, .width = w, .height = h };
        errdefer self.deinit();
        self.native = c.wl_egl_window_create(surface, w, h) orelse return error.EglWindowFailed;
        const attributes = [_]c.EGLint{c.EGL_NONE};
        self.surface = c.eglCreateWindowSurface(context.display, context.config, @ptrCast(self.native.?), &attributes);
        if (self.surface == null) return error.EglWindowSurfaceFailed;
        try context.makeCurrent(self.surface);
        // Compositor frame callbacks pace each output independently. Do not
        // block every other output on this output's eglSwapBuffers vsync.
        if (c.eglSwapInterval(context.display, 0) == c.EGL_FALSE) return error.EglSwapIntervalFailed;
    }
    pub fn resize(self: *Window, w: i32, h: i32) void {
        if (w == self.width and h == self.height) return;
        c.wl_egl_window_resize(self.native, w, h, 0, 0);
        self.width = w;
        self.height = h;
    }
    pub fn swap(self: *Window) !void {
        if (c.eglSwapBuffers(self.context.display, self.surface) == c.EGL_FALSE) return error.EglSwapFailed;
    }
    pub fn deinit(self: *Window) void {
        _ = c.eglMakeCurrent(self.context.display, null, null, null);
        if (self.surface != null) _ = c.eglDestroySurface(self.context.display, self.surface);
        if (self.native) |w| c.wl_egl_window_destroy(w);
    }
};

pub fn getProc(_: ?*anyopaque, name: [*c]const u8) callconv(.c) ?*anyopaque {
    return @ptrCast(@constCast(c.eglGetProcAddress(name)));
}
