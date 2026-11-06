#ifndef PROBE_RENDER_H
#define PROBE_RENDER_H
#include <stdbool.h>
#include <stdint.h>
#include <libavutil/frame.h>

typedef struct ProbeRenderer ProbeRenderer;
typedef struct { int64_t upload_ns, draw_ns, swap_ns; } RenderTiming;
ProbeRenderer *probe_renderer_create(const char *output);
void probe_renderer_destroy(ProbeRenderer *r);
int probe_renderer_show(ProbeRenderer *r);
int probe_renderer_hide(ProbeRenderer *r);
bool probe_renderer_can_present(const ProbeRenderer *r);
int probe_renderer_present(ProbeRenderer *r, const AVFrame *rgba, RenderTiming *timing);
/* Dispatch Wayland and poll stdin + worker wakeup without blocking the decoder.
 * Returns -1 on display failure, 0 on timeout, 1 on events. */
int probe_renderer_poll(ProbeRenderer *r, int wake_fd, int timeout_ms, bool *stdin_ready);
#endif
