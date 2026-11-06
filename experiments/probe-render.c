/* Owner-thread-only Wayland/EGL/OpenGL presentation for the FFmpeg experiment.
 * No mpv and no CUDA/OpenGL interoperability: only CPU RGBA texture uploads. */
#define _POSIX_C_SOURCE 200809L
#define GL_GLEXT_PROTOTYPES
#include "probe-render.h"
#include <wayland-client.h>
#include <wayland-egl.h>
#include "wlr-layer-shell-client-protocol.h"
#include <EGL/egl.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct Output {
    struct Output *next;
    struct ProbeRenderer *owner;
    struct wl_output *proxy;
    uint32_t id, version;
    int scale;
    char *name;
} Output;
struct ProbeRenderer {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct zwlr_layer_shell_v1 *shell;
    Output *outputs, *selected;
    struct wl_surface *surface;
    struct zwlr_layer_surface_v1 *layer;
    struct wl_callback *frame, *barrier;
    bool visible, configured, failed, show_after_barrier;
    uint32_t width, height;
    EGLDisplay egl;
    EGLContext context;
    EGLConfig config;
    EGLSurface egl_surface;
    struct wl_egl_window *window;
    GLuint program, vbo, texture;
    GLint position, uv, sampler;
    int texture_w, texture_h;
};
static int64_t clock_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static int fail(ProbeRenderer *r, const char *message) {
    fprintf(stderr, "[render] error=%s\n", message);
    r->failed = true;
    return -1;
}
static void output_geometry(void *p, struct wl_output *o, int32_t x, int32_t y,
                            int32_t w, int32_t h, int32_t sub, const char *make,
                            const char *model, int32_t transform) {
    (void)p; (void)o; (void)x; (void)y; (void)w; (void)h; (void)sub;
    (void)make; (void)model; (void)transform;
}
static void output_mode(void *p, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t refresh) {
    (void)p; (void)o; (void)flags; (void)w; (void)h; (void)refresh;
}
static void output_done(void *p, struct wl_output *o) { (void)p; (void)o; }
static void output_scale(void *p, struct wl_output *o, int32_t scale) {
    (void)o;
    Output *output = p;
    if (scale < 1) fail(output->owner, "invalid output scale");
    else output->scale = scale;
}
static void output_name(void *p, struct wl_output *o, const char *name) {
    (void)o;
    Output *output = p;
    free(output->name);
    output->name = strdup(name);
    if (!output->name) fail(output->owner, "output name allocation failed");
}
static void output_description(void *p, struct wl_output *o, const char *description) {
    (void)p; (void)o; (void)description;
}
static const struct wl_output_listener output_listener = {
    output_geometry, output_mode, output_done, output_scale, output_name, output_description
};
static void global(void *p, struct wl_registry *registry, uint32_t id, const char *name, uint32_t version) {
    ProbeRenderer *r = p;
    if (!strcmp(name, "wl_compositor") && !r->compositor) {
        r->compositor = wl_registry_bind(registry, id, &wl_compositor_interface, version < 4 ? version : 4);
    } else if (!strcmp(name, "zwlr_layer_shell_v1") && !r->shell) {
        r->shell = wl_registry_bind(registry, id, &zwlr_layer_shell_v1_interface, version < 4 ? version : 4);
    } else if (!strcmp(name, "wl_output")) {
        Output *output = calloc(1, sizeof(*output));
        if (!output) { fail(r, "output allocation failed"); return; }
        output->owner = r; output->id = id; output->scale = 1;
        output->version = version < 4 ? version : 4;
        output->proxy = wl_registry_bind(registry, id, &wl_output_interface, output->version);
        if (!output->proxy) { free(output); fail(r, "output bind failed"); return; }
        /* Preserve announcement order; this prototype defaults to the first output. */
        Output **tail = &r->outputs;
        while (*tail) tail = &(*tail)->next;
        *tail = output;
        if (wl_output_add_listener(output->proxy, &output_listener, output) < 0) fail(r, "output listener failed");
    }
}
static void global_remove(void *p, struct wl_registry *registry, uint32_t id) {
    (void)registry;
    ProbeRenderer *r = p;
    for (Output *o = r->outputs; o; o = o->next)
        if (o->id == id) {
            if (r->selected == o) fail(r, "selected output removed (hotplug unsupported in prototype)");
            o->id = 0;
        }
}
static const struct wl_registry_listener registry_listener = { global, global_remove };
static void configure(void *p, struct zwlr_layer_surface_v1 *layer, uint32_t serial, uint32_t w, uint32_t h) {
    ProbeRenderer *r = p;
    if (!r->visible || r->barrier) return; /* Ignore pre-unmap configure events. */
    zwlr_layer_surface_v1_ack_configure(layer, serial);
    if (!w || !h || w > INT_MAX || h > INT_MAX) { fail(r, "invalid surface configure"); return; }
    r->width = w; r->height = h; r->configured = true;
}
static void closed(void *p, struct zwlr_layer_surface_v1 *layer) {
    (void)layer;
    fail(p, "compositor closed the layer surface");
}
static const struct zwlr_layer_surface_v1_listener layer_listener = { configure, closed };
static void frame_done(void *p, struct wl_callback *callback, uint32_t time) {
    (void)time;
    ProbeRenderer *r = p;
    wl_callback_destroy(callback);
    r->frame = NULL;
}
static const struct wl_callback_listener frame_listener = { frame_done };
static void apply_layer(ProbeRenderer *r) {
    zwlr_layer_surface_v1_set_size(r->layer, 0, 0);
    zwlr_layer_surface_v1_set_anchor(r->layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_exclusive_zone(r->layer, -1);
    zwlr_layer_surface_v1_set_keyboard_interactivity(r->layer, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
}
static void barrier_done(void *p, struct wl_callback *callback, uint32_t time) {
    (void)time;
    ProbeRenderer *r = p;
    wl_callback_destroy(callback);
    r->barrier = NULL;
    if (r->show_after_barrier) {
        r->show_after_barrier = false;
        apply_layer(r);
        wl_surface_commit(r->surface); /* Fresh initial commit, no attached buffer. */
    }
}
static const struct wl_callback_listener barrier_listener = { barrier_done };
static GLuint shader(GLenum kind, const char *source) {
    GLuint s = glCreateShader(kind);
    glShaderSource(s, 1, &source, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024]; glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "[render] shader_error=%s\n", log);
        glDeleteShader(s); return 0;
    }
    return s;
}
static int init_gl(ProbeRenderer *r) {
    GLuint vs = shader(GL_VERTEX_SHADER, "#version 120\nattribute vec2 position; attribute vec2 texcoord; varying vec2 uv; void main(){gl_Position=vec4(position,0,1);uv=texcoord;}");
    GLuint fs = shader(GL_FRAGMENT_SHADER, "#version 120\nuniform sampler2D image; varying vec2 uv; void main(){gl_FragColor=vec4(texture2D(image,uv).rgb,1);}");
    if (!vs || !fs) { if (vs) glDeleteShader(vs); if (fs) glDeleteShader(fs); return fail(r, "shader compilation failed"); }
    r->program = glCreateProgram();
    glAttachShader(r->program, vs); glAttachShader(r->program, fs);
    glLinkProgram(r->program);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok = 0; glGetProgramiv(r->program, GL_LINK_STATUS, &ok);
    if (!ok) return fail(r, "shader linking failed");
    r->position = glGetAttribLocation(r->program, "position");
    r->uv = glGetAttribLocation(r->program, "texcoord");
    r->sampler = glGetUniformLocation(r->program, "image");
    if (r->position < 0 || r->uv < 0 || r->sampler < 0) return fail(r, "shader attributes unavailable");
    glGenBuffers(1, &r->vbo);
    if (glGetError() != GL_NO_ERROR) return fail(r, "GL resource initialization failed");
    fprintf(stderr, "[render] gl_initialized renderer=%s\n", glGetString(GL_RENDERER));
    return 0;
}
ProbeRenderer *probe_renderer_create(const char *output) {
    ProbeRenderer *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->display = wl_display_connect(NULL);
    if (!r->display) { fail(r, "Wayland connection failed"); goto error; }
    r->registry = wl_display_get_registry(r->display);
    if (!r->registry || wl_registry_add_listener(r->registry, &registry_listener, r) < 0) goto error;
    if (wl_display_roundtrip(r->display) < 0 || wl_display_roundtrip(r->display) < 0 || r->failed) goto error;
    if (!r->compositor || !r->shell) { fail(r, "wl_compositor and layer-shell are required"); goto error; }
    for (Output *o = r->outputs; o; o = o->next)
        if (o->id && (!output || (o->name && !strcmp(output, o->name)))) { r->selected = o; break; }
    if (!r->selected) { fail(r, "requested output unavailable (named selection requires wl_output v4)"); goto error; }
    r->egl = eglGetDisplay((EGLNativeDisplayType)r->display);
    if (r->egl == EGL_NO_DISPLAY || !eglInitialize(r->egl, NULL, NULL) || !eglBindAPI(EGL_OPENGL_API)) goto error;
    const EGLint attrs[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 0, EGL_NONE };
    EGLint count = 0;
    if (!eglChooseConfig(r->egl, attrs, &r->config, 1, &count) || !count) goto error;
    const EGLint context_attrs[] = { EGL_NONE };
    r->context = eglCreateContext(r->egl, r->config, EGL_NO_CONTEXT, context_attrs);
    if (r->context == EGL_NO_CONTEXT) goto error;
    fprintf(stderr, "[render] egl_initialized output=%s scale=%d state=hidden\n",
        r->selected->name ? r->selected->name : "(unnamed)", r->selected->scale);
    return r;
error:
    fprintf(stderr, "[render] initialization failed (EGL error 0x%x)\n", eglGetError());
    probe_renderer_destroy(r);
    return NULL;
}
int probe_renderer_show(ProbeRenderer *r) {
    if (r->failed) return -1;
    r->visible = true; r->configured = false;
    if (!r->surface) {
        r->surface = wl_compositor_create_surface(r->compositor);
        if (!r->surface) return fail(r, "surface creation failed");
        r->layer = zwlr_layer_shell_v1_get_layer_surface(r->shell, r->surface, r->selected->proxy,
            ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "ffmpeg-render-probe");
        if (!r->layer) return fail(r, "layer creation failed");
        if (zwlr_layer_surface_v1_add_listener(r->layer, &layer_listener, r) < 0) return fail(r, "layer listener failed");
        struct wl_region *region = wl_compositor_create_region(r->compositor);
        if (!region) return fail(r, "input region creation failed");
        wl_surface_set_input_region(r->surface, region); wl_region_destroy(region);
    }
    if (r->barrier) r->show_after_barrier = true;
    else { apply_layer(r); wl_surface_commit(r->surface); }
    return 0;
}
int probe_renderer_hide(ProbeRenderer *r) {
    bool was_visible = r->visible;
    r->visible = r->configured = r->show_after_barrier = false;
    if (r->frame) { wl_callback_destroy(r->frame); r->frame = NULL; }
    if (r->texture) {
        if (!eglMakeCurrent(r->egl, r->egl_surface, r->egl_surface, r->context)) return fail(r, "make current for texture release failed");
        glDeleteTextures(1, &r->texture); r->texture = 0;
        glFinish(); /* Complete outstanding uploads/draws before reporting release. */
        r->texture_w = r->texture_h = 0;
        fprintf(stderr, "[render] video_texture_released retained=EGL,shader,VBO\n");
    }
    if (r->surface && was_visible) {
        if (r->barrier) wl_callback_destroy(r->barrier);
        wl_surface_attach(r->surface, NULL, 0, 0); wl_surface_commit(r->surface);
        r->barrier = wl_display_sync(r->display);
        if (!r->barrier || wl_callback_add_listener(r->barrier, &barrier_listener, r) < 0) return fail(r, "unmap sync failed");
    }
    return 0;
}
bool probe_renderer_can_present(const ProbeRenderer *r) {
    return !r->failed && r->visible && r->configured && !r->barrier && !r->frame;
}
int probe_renderer_present(ProbeRenderer *r, const AVFrame *image, RenderTiming *timing) {
    if (!probe_renderer_can_present(r)) return fail(r, "presentation before configure/frame readiness");
    int64_t bw = (int64_t)r->width * r->selected->scale, bh = (int64_t)r->height * r->selected->scale;
    if (bw <= 0 || bh <= 0 || bw > INT_MAX || bh > INT_MAX) return fail(r, "invalid buffer dimensions");
    if (!r->window) {
        r->window = wl_egl_window_create(r->surface, (int)bw, (int)bh);
        if (!r->window) return fail(r, "EGL window creation failed");
        const EGLint attrs[] = { EGL_NONE };
        r->egl_surface = eglCreateWindowSurface(r->egl, r->config, (EGLNativeWindowType)r->window, attrs);
        if (r->egl_surface == EGL_NO_SURFACE) return fail(r, "EGL window surface failed");
        if (!eglMakeCurrent(r->egl, r->egl_surface, r->egl_surface, r->context) || !eglSwapInterval(r->egl, 0)) return fail(r, "EGL current/swap interval failed");
        if (init_gl(r)) return -1;
    } else {
        if (!eglMakeCurrent(r->egl, r->egl_surface, r->egl_surface, r->context)) return fail(r, "EGL make current failed");
        wl_egl_window_resize(r->window, (int)bw, (int)bh, 0, 0);
    }
    if (wl_surface_get_version(r->surface) >= 3) wl_surface_set_buffer_scale(r->surface, r->selected->scale);
    else if (r->selected->scale != 1) return fail(r, "scaled surface needs wl_surface v3");
    GLint max_texture = 0; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_texture);
    if (image->format != AV_PIX_FMT_RGBA || !image->data[0] || image->width <= 0 || image->height <= 0 ||
        image->width > max_texture || image->height > max_texture ||
        image->linesize[0] < (int64_t)image->width * 4 || image->linesize[0] % 4) return fail(r, "unsupported RGBA dimensions/stride");
    int64_t start = clock_ns();
    if (!r->texture) glGenTextures(1, &r->texture);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, r->texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1); glPixelStorei(GL_UNPACK_ROW_LENGTH, image->linesize[0] / 4);
    if (r->texture_w != image->width || r->texture_h != image->height) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, image->width, image->height, 0, GL_RGBA, GL_UNSIGNED_BYTE, image->data[0]);
        r->texture_w = image->width; r->texture_h = image->height;
    } else glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, image->width, image->height, GL_RGBA, GL_UNSIGNED_BYTE, image->data[0]);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    timing->upload_ns = clock_ns() - start;
    start = clock_ns();
    double sar = image->sample_aspect_ratio.num > 0 && image->sample_aspect_ratio.den > 0 ? av_q2d(image->sample_aspect_ratio) : 1;
    double source = (double)image->width * sar / image->height, dest = (double)bw / bh;
    float ux = source > dest ? (float)(dest / source) : 1, uy = source < dest ? (float)(source / dest) : 1;
    float left = (1 - ux) / 2, right = 1 - left, top = (1 - uy) / 2, bottom = 1 - top;
    const GLfloat vertices[] = { -1,-1,left,bottom, 1,-1,right,bottom, -1,1,left,top, 1,1,right,top };
    glViewport(0, 0, (GLsizei)bw, (GLsizei)bh);
    glUseProgram(r->program); glUniform1i(r->sampler, 0);
    glBindBuffer(GL_ARRAY_BUFFER, r->vbo); glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STREAM_DRAW);
    glEnableVertexAttribArray((GLuint)r->position); glEnableVertexAttribArray((GLuint)r->uv);
    glVertexAttribPointer((GLuint)r->position, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), (void *)0);
    glVertexAttribPointer((GLuint)r->uv, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), (void *)(2 * sizeof(GLfloat)));
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    if (glGetError() != GL_NO_ERROR) return fail(r, "texture upload/draw failed");
    timing->draw_ns = clock_ns() - start;
    r->frame = wl_surface_frame(r->surface);
    if (!r->frame || wl_callback_add_listener(r->frame, &frame_listener, r) < 0) return fail(r, "frame callback failed");
    start = clock_ns();
    if (!eglSwapBuffers(r->egl, r->egl_surface)) return fail(r, "EGL swap failed");
    timing->swap_ns = clock_ns() - start;
    return 0;
}
int probe_renderer_poll(ProbeRenderer *r, int wake_fd, int timeout_ms, bool *stdin_ready) {
    *stdin_ready = false;
    if (wl_display_dispatch_pending(r->display) < 0 || r->failed) return -1;
    if (wl_display_prepare_read(r->display) != 0) return 1;
    bool write_pending = false;
    if (wl_display_flush(r->display) < 0) {
        if (errno == EAGAIN) write_pending = true;
        else { wl_display_cancel_read(r->display); return -1; }
    }
    struct pollfd fds[] = { {STDIN_FILENO, POLLIN, 0},
        {wl_display_get_fd(r->display), POLLIN | (write_pending ? POLLOUT : 0), 0}, {wake_fd, POLLIN, 0} };
    int result = poll(fds, 3, timeout_ms);
    if (result < 0 || !(fds[1].revents & POLLIN)) wl_display_cancel_read(r->display);
    else if (wl_display_read_events(r->display) < 0) return -1;
    if (result < 0) return errno == EINTR ? 0 : -1;
    if ((fds[1].revents & (POLLERR | POLLHUP | POLLNVAL)) || (fds[2].revents & (POLLERR | POLLHUP | POLLNVAL))) return -1;
    if (fds[2].revents & POLLIN) { uint64_t value; while (read(wake_fd, &value, sizeof(value)) > 0) {} }
    *stdin_ready = fds[0].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL);
    if (wl_display_dispatch_pending(r->display) < 0 || r->failed) return -1;
    return result;
}
void probe_renderer_destroy(ProbeRenderer *r) {
    if (!r) return;
    if (r->egl != EGL_NO_DISPLAY && r->context != EGL_NO_CONTEXT) {
        if (r->egl_surface != EGL_NO_SURFACE && eglMakeCurrent(r->egl, r->egl_surface, r->egl_surface, r->context)) {
            if (r->texture) glDeleteTextures(1, &r->texture);
            if (r->vbo) glDeleteBuffers(1, &r->vbo);
            if (r->program) glDeleteProgram(r->program);
        }
        eglMakeCurrent(r->egl, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (r->egl_surface != EGL_NO_SURFACE) eglDestroySurface(r->egl, r->egl_surface);
        eglDestroyContext(r->egl, r->context);
    }
    if (r->window) wl_egl_window_destroy(r->window);
    if (r->egl != EGL_NO_DISPLAY) eglTerminate(r->egl);
    if (r->frame) wl_callback_destroy(r->frame);
    if (r->barrier) wl_callback_destroy(r->barrier);
    if (r->layer) zwlr_layer_surface_v1_destroy(r->layer);
    if (r->surface) wl_surface_destroy(r->surface);
    while (r->outputs) {
        Output *o = r->outputs; r->outputs = o->next;
        if (o->version >= 3) wl_output_release(o->proxy); else wl_output_destroy(o->proxy);
        free(o->name); free(o);
    }
    if (r->shell) {
        if (zwlr_layer_shell_v1_get_version(r->shell) >= 3) zwlr_layer_shell_v1_destroy(r->shell);
        else wl_proxy_destroy((struct wl_proxy *)r->shell);
    }
    if (r->compositor) wl_compositor_destroy(r->compositor);
    if (r->registry) wl_registry_destroy(r->registry);
    if (r->display) { wl_display_flush(r->display); wl_display_disconnect(r->display); }
    free(r);
}
