/* Test-only shim: real Mesa OpenGL + libmpv, but offscreen pbuffers instead
 * of desktop windows. Wayland protocol traffic goes to tests/control.py. */
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <wayland-client.h>
#include <wayland-egl.h>
#include <mpv/render.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>

struct wl_egl_window { struct wl_surface *surface; int w, h; };
typedef struct SurfaceMap { EGLSurface surface; struct wl_egl_window *window; struct SurfaceMap *next; } SurfaceMap;
static SurfaceMap *surfaces;
static void *symbol(const char *name) {
    void *p = dlsym(RTLD_NEXT, name);
    if (!p) { fprintf(stderr, "test shim missing %s\n", name); abort(); }
    return p;
}
EGLDisplay eglGetDisplay(EGLNativeDisplayType ignored) {
    (void)ignored;
    PFNEGLGETPLATFORMDISPLAYPROC real = symbol("eglGetPlatformDisplay");
    return real(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
}
EGLBoolean eglChooseConfig(EGLDisplay d, const EGLint *attrs, EGLConfig *configs,
                           EGLint count, EGLint *found) {
    EGLBoolean (*real)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *) = symbol("eglChooseConfig");
    EGLint copy[64];
    int n = 0;
    for (; attrs[n] != EGL_NONE; n += 2) {
        copy[n] = attrs[n];
        copy[n + 1] = attrs[n] == EGL_SURFACE_TYPE ? EGL_PBUFFER_BIT : attrs[n + 1];
    }
    copy[n] = EGL_NONE;
    return real(d, copy, configs, count, found);
}
struct wl_egl_window *wl_egl_window_create(struct wl_surface *s, int w, int h) {
    struct wl_egl_window *p = calloc(1, sizeof(*p));
    if (p) *p = (struct wl_egl_window){s, w, h};
    return p;
}
void wl_egl_window_destroy(struct wl_egl_window *p) { free(p); }
void wl_egl_window_resize(struct wl_egl_window *p, int w, int h, int dx, int dy) {
    (void)dx; (void)dy; p->w = w; p->h = h;
}
EGLSurface eglCreateWindowSurface(EGLDisplay d, EGLConfig c, EGLNativeWindowType native,
                                  const EGLint *ignored) {
    (void)ignored;
    struct wl_egl_window *window = (struct wl_egl_window *)native;
    EGLSurface (*real)(EGLDisplay, EGLConfig, const EGLint *) = symbol("eglCreatePbufferSurface");
    const EGLint attrs[] = { EGL_WIDTH, window->w, EGL_HEIGHT, window->h, EGL_NONE };
    EGLSurface surface = real(d, c, attrs);
    if (surface != EGL_NO_SURFACE) {
        SurfaceMap *map = calloc(1, sizeof(*map));
        if (!map) abort();
        *map = (SurfaceMap){surface, window, surfaces}; surfaces = map;
    }
    return surface;
}
EGLBoolean eglDestroySurface(EGLDisplay display, EGLSurface surface) {
    EGLBoolean (*real)(EGLDisplay, EGLSurface) = symbol("eglDestroySurface");
    SurfaceMap **link = &surfaces;
    while (*link && (*link)->surface != surface) link = &(*link)->next;
    if (*link) { SurfaceMap *old = *link; *link = old->next; free(old); }
    return real(display, surface);
}
EGLBoolean eglSwapBuffers(EGLDisplay d, EGLSurface s) {
    EGLBoolean (*real)(EGLDisplay, EGLSurface) = symbol("eglSwapBuffers");
    SurfaceMap *map = surfaces;
    while (map && map->surface != s) map = map->next;
    if (!map) abort();
    struct wl_egl_window *window = map->window;
    if (getenv("PROBE_TEST_READBACK")) {
        void (*read_pixel)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *) = symbol("glReadPixels");
        unsigned char pixel[4];
        read_pixel(window->w / 2, window->h / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
        fprintf(stderr, "[test] pixel=%u,%u,%u,%u\n", pixel[0], pixel[1], pixel[2], pixel[3]);
        if (getenv("PROBE_TEST_READBACK_GRID")) {
            const char *labels[] = {"TL", "TR", "BL", "BR"};
            for (int i = 0; i < 4; i++) {
                read_pixel((i % 2 ? 3 : 1) * window->w / 4,
                           (i < 2 ? 3 : 1) * window->h / 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
                fprintf(stderr, "[test] sample=%s rgba=%u,%u,%u,%u\n", labels[i], pixel[0], pixel[1], pixel[2], pixel[3]);
            }
        }
    }
    EGLBoolean result = real(d, s);
    if (result) wl_surface_commit(window->surface);
    return result;
}
/* Simulate an uninterruptible open/device operation for control responsiveness. */
int avformat_open_input(AVFormatContext **context, const char *url, const AVInputFormat *format, AVDictionary **options) {
    int (*real)(AVFormatContext **, const char *, const AVInputFormat *, AVDictionary **) = symbol("avformat_open_input");
    const char *delay = getenv("STILLWAVE_TEST_OPEN_DELAY_MS");
    if (delay) {
        long milliseconds = strtol(delay, NULL, 10);
        struct timespec pause = {milliseconds / 1000, milliseconds % 1000 * 1000000};
        nanosleep(&pause, NULL);
    }
    return real(context, url, format, options);
}
/* Force metadata-only HDR rejection without requiring an HDR-capable encoder. */
int avcodec_receive_frame(AVCodecContext *context, AVFrame *frame) {
    int (*real)(AVCodecContext *, AVFrame *) = symbol("avcodec_receive_frame");
    int result = real(context, frame);
    if (result == 0 && getenv("STILLWAVE_TEST_HDR")) frame->color_trc = AVCOL_TRC_SMPTE2084;
    return result;
}
/* Exercise an END_FILE queued by an idle query just before a new load. */
static mpv_event delayed_end;
static mpv_event_end_file delayed_end_data;
static int held_end, release_end, delayed_once;
int mpv_get_property(mpv_handle *handle, const char *name, mpv_format format, void *data) {
    int (*real)(mpv_handle *, const char *, mpv_format, void *) = symbol("mpv_get_property");
    int result = real(handle, name, format, data);
    if (result == 0 && !strcmp(name, "idle-active") && format == MPV_FORMAT_FLAG &&
        *(int *)data && held_end) release_end = 1;
    return result;
}
/* Exercise cancellation before playback readiness without slowing real decoding. */
mpv_event *mpv_wait_event(mpv_handle *handle, double timeout) {
    mpv_event *(*real)(mpv_handle *, double) = symbol("mpv_wait_event");
    static int dropped;
    static mpv_event none = { .event_id = MPV_EVENT_NONE };
    if (release_end) {
        release_end = held_end = 0;
        return &delayed_end;
    }
    mpv_event *event = real(handle, timeout);
    if (!delayed_once && getenv("STILLWAVE_TEST_DELAY_END_FILE") &&
        event->event_id == MPV_EVENT_END_FILE &&
        ((mpv_event_end_file *)event->data)->reason == MPV_END_FILE_REASON_STOP) {
        delayed_end = *event;
        delayed_end_data = *(mpv_event_end_file *)event->data;
        delayed_end.data = &delayed_end_data;
        held_end = delayed_once = 1;
        fprintf(stderr, "[test] END_FILE delayed until idle query\n");
        return &none;
    }
    if (!dropped && getenv("STILLWAVE_TEST_DROP_FIRST_RESTART") &&
        event->event_id == MPV_EVENT_PLAYBACK_RESTART) {
        dropped = 1;
        fprintf(stderr, "[test] first playback restart suppressed\n");
        return &none;
    }
    return event;
}
int mpv_render_context_create(mpv_render_context **out, mpv_handle *handle, mpv_render_param *params) {
    int (*real)(mpv_render_context **, mpv_handle *, mpv_render_param *) = symbol("mpv_render_context_create");
    /* The fake Wayland display is not a hardware-decoder interop display. */
    mpv_render_param copy[16];
    int n = 0;
    for (int i = 0; params[i].type; i++)
        if (params[i].type != MPV_RENDER_PARAM_WL_DISPLAY) copy[n++] = params[i];
    copy[n] = (mpv_render_param){0};
    return real(out, handle, copy);
}
