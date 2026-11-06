/* Shared FFmpeg lifecycle experiment. The default build is decode-only;
 * PROBE_RENDER adds a separate one-output Wayland/OpenGL experiment. No mpv. */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef PROBE_RENDER
#include "probe-render.h"
#include <libswscale/swscale.h>
#include <sys/eventfd.h>
#endif

static volatile sig_atomic_t interrupted;
static int64_t origin;
static int64_t now_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) abort();
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static double ms(int64_t ns) { return (double)ns / 1000000; }
static void log_stage(unsigned cycle, const char *stage, int64_t since) {
    int64_t end = now_ns();
    fprintf(stderr, "[probe] +%.3f ms cycle=%u stage=%s duration_ms=%.3f\n",
            ms(end - origin), cycle, stage, ms(end - since));
}
static void on_signal(int sig) { (void)sig; interrupted = 1; }

typedef struct {
    const char *path, *device;
    bool cuda, joinable, failed, had_error;
    uint64_t limit;
    unsigned cycle;
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    atomic_bool stop, done;
    int64_t show_start;
#ifdef PROBE_RENDER
    ProbeRenderer *renderer;
    const char *output;
    AVFrame *pending;
    int wake_fd;
    bool first_submitted;
    uint64_t submitted, dropped;
    int64_t upload_ns, draw_ns, swap_ns;
#endif
} Probe;

typedef struct {
    bool set, anchored;
    int64_t origin_ns, next_origin_ns, last_target_ns;
    double anchor_pts, anchor_delta, last_delta;
} Timeline;

/* Pure timestamp mapping: preserve long intervals, anchor the first valid PTS
 * onto synthetic timing if earlier frames lacked timestamps, and handle backward
 * discontinuities without scheduling before the last frame. */
static int timeline_target(Timeline *t, double pts, double interval, int64_t now, int64_t *target) {
    if (!t->set) {
        t->set = true;
        t->origin_ns = now > t->next_origin_ns ? now : t->next_origin_ns;
        t->last_delta = -interval;
    }
    double delta = t->last_delta + interval;
    if (isfinite(pts)) {
        if (!t->anchored || pts - t->anchor_pts + t->anchor_delta < t->last_delta - 0.5) {
            t->anchored = true;
            t->anchor_pts = pts;
            t->anchor_delta = delta;
        }
        delta = pts - t->anchor_pts + t->anchor_delta;
    }
    delta = fmax(0, fmax(t->last_delta, delta));
    double ns = delta * 1000000000;
    if (!isfinite(ns) || ns >= (double)(INT64_MAX - t->origin_ns)) return AVERROR_INVALIDDATA;
    t->last_delta = delta;
    *target = t->last_target_ns = t->origin_ns + (int64_t)ns;
    return 0;
}
static int timeline_loop(Timeline *t, double interval) {
    int64_t step = (int64_t)(interval * 1000000000);
    if (t->last_target_ns > INT64_MAX - step) return AVERROR_INVALIDDATA;
    t->next_origin_ns = t->last_target_ns + step;
    t->set = t->anchored = false;
    return 0;
}

typedef struct {
    Probe *probe;
    AVFormatContext *input;
    AVCodecContext *decoder;
    AVBufferRef *device;
    AVPacket *packet;
    AVFrame *frame, *download;
    int stream;
    uint64_t frames, downloads, loops, pass_start;
    int64_t transfer_ns;
    double interval;
    Timeline timeline;
#ifdef PROBE_RENDER
    struct SwsContext *scaler;
    AVFrame *rgba;
    int64_t conversion_ns;
#endif
} Session;

static int canceled(void *opaque) {
    Probe *p = opaque;
    return atomic_load_explicit(&p->stop, memory_order_acquire);
}
#ifdef PROBE_RENDER
static void notify_owner(Probe *p) {
    uint64_t one = 1;
    while (write(p->wake_fd, &one, sizeof(one)) < 0 && errno == EINTR) {}
}
static int queue_image(Session *s, const AVFrame *image) {
    Probe *p = s->probe;
    if (canceled(p)) return AVERROR_EXIT;
    if (image->color_trc == AVCOL_TRC_SMPTE2084 || image->color_trc == AVCOL_TRC_ARIB_STD_B67) {
        fprintf(stderr, "[render] HDR/tone mapping unsupported; use SDR video\n");
        return AVERROR(ENOSYS);
    }
    if (!s->rgba) s->rgba = av_frame_alloc();
    if (!s->rgba) return AVERROR(ENOMEM);
    if (s->rgba->width != image->width || s->rgba->height != image->height || !av_frame_is_writable(s->rgba)) {
        av_frame_unref(s->rgba);
        s->rgba->format = AV_PIX_FMT_RGBA;
        s->rgba->width = image->width; s->rgba->height = image->height;
        int r = av_frame_get_buffer(s->rgba, 32);
        if (r < 0) return r;
    }
    int64_t start = now_ns();
    s->scaler = sws_getCachedContext(s->scaler, image->width, image->height, image->format,
        image->width, image->height, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
    if (!s->scaler) return AVERROR(ENOMEM);
    int colorspace;
    switch (image->colorspace) {
        case AVCOL_SPC_BT709: colorspace = SWS_CS_ITU709; break;
        case AVCOL_SPC_FCC: colorspace = SWS_CS_FCC; break;
        case AVCOL_SPC_SMPTE240M: colorspace = SWS_CS_SMPTE240M; break;
        case AVCOL_SPC_BT2020_NCL: colorspace = SWS_CS_BT2020; break;
        case AVCOL_SPC_BT470BG: case AVCOL_SPC_SMPTE170M: colorspace = SWS_CS_ITU601; break;
        case AVCOL_SPC_RGB: case AVCOL_SPC_UNSPECIFIED: colorspace = SWS_CS_DEFAULT; break;
        default:
            fprintf(stderr, "[render] unsupported explicit color matrix=%d\n", image->colorspace);
            return AVERROR(ENOSYS);
    }
    const int *coefficients = sws_getCoefficients(colorspace);
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(image->format);
    int full_range = image->color_range == AVCOL_RANGE_JPEG || (desc && (desc->flags & AV_PIX_FMT_FLAG_RGB));
    int r = sws_setColorspaceDetails(s->scaler, coefficients, full_range, coefficients, 1, 0, 1 << 16, 1 << 16);
    if (r < 0) return r;
    r = sws_scale(s->scaler, (const uint8_t *const *)image->data, image->linesize, 0, image->height,
                  s->rgba->data, s->rgba->linesize);
    s->conversion_ns += now_ns() - start;
    if (r != image->height) return r < 0 ? r : AVERROR_INVALIDDATA;
    s->rgba->sample_aspect_ratio = s->frame->sample_aspect_ratio;
    AVFrame *copy = av_frame_clone(s->rgba);
    if (!copy) return AVERROR(ENOMEM);
    pthread_mutex_lock(&p->mutex);
    if (canceled(p)) { pthread_mutex_unlock(&p->mutex); av_frame_free(&copy); return AVERROR_EXIT; }
    if (p->pending) { av_frame_free(&p->pending); p->dropped++; }
    p->pending = copy; /* One-slot latest-frame mailbox; never wait on compositor callbacks. */
    pthread_mutex_unlock(&p->mutex);
    notify_owner(p);
    return 0;
}
static int present_pending(Probe *p) {
    if (!probe_renderer_can_present(p->renderer)) return 0;
    pthread_mutex_lock(&p->mutex);
    AVFrame *image = p->pending;
    p->pending = NULL;
    pthread_mutex_unlock(&p->mutex);
    if (!image) return 0;
    RenderTiming timing;
    int r = probe_renderer_present(p->renderer, image, &timing);
    av_frame_free(&image);
    if (r < 0) return r;
    p->submitted++;
    p->upload_ns += timing.upload_ns; p->draw_ns += timing.draw_ns; p->swap_ns += timing.swap_ns;
    if (!p->first_submitted) {
        p->first_submitted = true;
        fprintf(stderr, "[probe] cycle=%u first_upload_ms=%.3f first_draw_ms=%.3f first_swap_ms=%.3f\n",
                p->cycle, ms(timing.upload_ns), ms(timing.draw_ns), ms(timing.swap_ns));
        log_stage(p->cycle, "first_frame_submitted", p->show_start);
    }
    return 0;
}
#endif
static enum AVPixelFormat cuda_format(AVCodecContext *ctx, const enum AVPixelFormat *formats) {
    (void)ctx;
    for (; *formats != AV_PIX_FMT_NONE; formats++)
        if (*formats == AV_PIX_FMT_CUDA) return *formats;
    return AV_PIX_FMT_NONE; /* Never silently fall back to software. */
}
static int pace(Session *s) {
    Probe *p = s->probe;
    double pts = s->frame->best_effort_timestamp == AV_NOPTS_VALUE ? NAN :
        s->frame->best_effort_timestamp * av_q2d(s->input->streams[s->stream]->time_base);
    int64_t target;
    int mapped = timeline_target(&s->timeline, pts, s->interval, now_ns(), &target);
    if (mapped < 0) return mapped;
    struct timespec deadline = { .tv_sec = target / 1000000000, .tv_nsec = target % 1000000000 };
    pthread_mutex_lock(&p->mutex);
    while (!canceled(p) && now_ns() < target) {
        int r = pthread_cond_timedwait(&p->cond, &p->mutex, &deadline);
        if (r && r != ETIMEDOUT) { pthread_mutex_unlock(&p->mutex); return AVERROR(r); }
    }
    pthread_mutex_unlock(&p->mutex);
    return canceled(p) ? AVERROR_EXIT : 0;
}
static int consume_frame(Session *s) {
    Probe *p = s->probe;
    if (canceled(p)) return AVERROR_EXIT;
    if (!s->frames) log_stage(p->cycle, "first_frame_decoded", p->show_start);
    AVFrame *image = s->frame;
    if (p->cuda) {
        if (s->frame->format != AV_PIX_FMT_CUDA || !s->frame->hw_frames_ctx)
            return AVERROR_INVALIDDATA;
        av_frame_unref(s->download);
        int64_t start = now_ns();
        int r = av_hwframe_transfer_data(s->download, s->frame, 0);
        s->transfer_ns += now_ns() - start;
        if (r < 0) return r;
        s->downloads++;
#ifdef PROBE_RENDER
        // Transfer copies pixels, not color range/matrix/transfer metadata.
        // Preserve these for correct SDR conversion and explicit HDR rejection.
        r = av_frame_copy_props(s->download, s->frame);
        if (r < 0) return r;
#endif
        image = s->download;
        if (s->downloads == 1) log_stage(p->cycle, "first_frame_downloaded", p->show_start);
    }
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(image->format);
    if (!desc || (desc->flags & AV_PIX_FMT_FLAG_HWACCEL) || !image->data[0] || image->width <= 0 || image->height <= 0)
        return AVERROR_INVALIDDATA;
    s->frames++;
    if (s->frames == 1) {
        fprintf(stderr, "[probe] cycle=%u frame=%dx%d pixel_format=%s decoding=%s\n",
                p->cycle, image->width, image->height, desc->name, p->cuda ? "cuda" : "software");
        log_stage(p->cycle, "first_frame_ready", p->show_start);
    }
    int r = pace(s);
#ifdef PROBE_RENDER
    if (r >= 0) r = queue_image(s, image);
#endif
    av_frame_unref(s->frame);
    av_frame_unref(s->download);
    if (r < 0) return r;
    return p->limit && s->frames >= p->limit ? 1 : 0;
}
static int receive_frames(Session *s, bool *eof) {
    for (;;) {
        if (canceled(s->probe)) return AVERROR_EXIT;
        int r = avcodec_receive_frame(s->decoder, s->frame);
        if (r == AVERROR(EAGAIN)) return 0;
        if (r == AVERROR_EOF) { *eof = true; return 0; }
        if (r < 0) return r;
        r = consume_frame(s);
        if (r) return r;
    }
}
static int submit(Session *s, const AVPacket *packet, bool *eof) {
    for (;;) {
        if (canceled(s->probe)) return AVERROR_EXIT;
        int r = avcodec_send_packet(s->decoder, packet);
        if (r == AVERROR_EOF && !packet) { *eof = true; return 0; }
        if (r == AVERROR(EAGAIN)) {
            uint64_t before = s->frames;
            r = receive_frames(s, eof);
            if (r || *eof) return r;
            if (s->frames == before) return AVERROR_BUG;
            continue; /* Retry the same packet after consuming pending output. */
        }
        if (r < 0) return r;
        return receive_frames(s, eof);
    }
}
static int open_session(Session *s) {
    Probe *p = s->probe;
    int64_t start = now_ns();
    s->input = avformat_alloc_context();
    if (!s->input) return AVERROR(ENOMEM);
    s->input->interrupt_callback = (AVIOInterruptCB){ canceled, p };
    AVDictionary *options = NULL;
    int r = av_dict_set(&options, "protocol_whitelist", "file", 0);
    if (r >= 0) r = av_dict_set(&options, "format_whitelist",
        "mov,matroska,webm,avi,mpegts,mpeg,ogg,flv,nut,asf,rm,h264,hevc,av1,ivf,wav", 0);
    if (r >= 0) r = avformat_open_input(&s->input, p->path, NULL, &options);
    av_dict_free(&options);
    if (r < 0) return r;
    log_stage(p->cycle, "input_opened", start);
    start = now_ns();
    r = avformat_find_stream_info(s->input, NULL);
    if (r < 0) return r;
    log_stage(p->cycle, "stream_info_ready", start);
    const AVCodec *codec = NULL;
    r = av_find_best_stream(s->input, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (r < 0) return r;
    s->stream = r;
    s->decoder = avcodec_alloc_context3(codec);
    if (!s->decoder) return AVERROR(ENOMEM);
    r = avcodec_parameters_to_context(s->decoder, s->input->streams[s->stream]->codecpar);
    if (r < 0) return r;
    s->decoder->pkt_timebase = s->input->streams[s->stream]->time_base;
    if (canceled(p)) return AVERROR_EXIT;
    if (p->cuda) {
        bool supported = false;
        for (int i = 0;; i++) {
            const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
            if (!config) break;
            if (config->device_type == AV_HWDEVICE_TYPE_CUDA && config->pix_fmt == AV_PIX_FMT_CUDA &&
                (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) supported = true;
        }
        if (!supported) return AVERROR(ENOSYS);
        start = now_ns();
        r = av_hwdevice_ctx_create(&s->device, AV_HWDEVICE_TYPE_CUDA, p->device, NULL, 0);
        if (r < 0) return r;
        log_stage(p->cycle, "cuda_device_created", start);
        s->decoder->hw_device_ctx = av_buffer_ref(s->device);
        if (!s->decoder->hw_device_ctx) return AVERROR(ENOMEM);
        s->decoder->get_format = cuda_format;
    }
    if (canceled(p)) return AVERROR_EXIT;
    start = now_ns();
    r = avcodec_open2(s->decoder, codec, NULL);
    if (r < 0) return r;
    log_stage(p->cycle, "decoder_opened", start);
    AVRational rate = av_guess_frame_rate(s->input, s->input->streams[s->stream], NULL);
    double fps = av_q2d(rate);
    s->interval = isfinite(fps) && fps > 0 && fps <= 1000 ? 1 / fps : 1.0 / 30;
    s->packet = av_packet_alloc();
    s->frame = av_frame_alloc();
    s->download = av_frame_alloc();
    return s->packet && s->frame && s->download ? 0 : AVERROR(ENOMEM);
}
static int decode(Session *s) {
    for (;;) {
        if (canceled(s->probe)) return AVERROR_EXIT;
        int r = av_read_frame(s->input, s->packet);
        bool eof = false;
        if (r == AVERROR_EOF) {
            r = submit(s, NULL, &eof); /* Drain delayed frames before looping. */
            if (r) return r;
            if (!eof || s->frames == s->pass_start) return AVERROR_INVALIDDATA;
            AVStream *stream = s->input->streams[s->stream];
            int64_t start = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
            r = av_seek_frame(s->input, s->stream, start, AVSEEK_FLAG_BACKWARD);
            if (r < 0) return r;
            avcodec_flush_buffers(s->decoder);
            s->pass_start = s->frames;
            // Include the last frame's display interval between loops; otherwise
            // every loop would run one frame interval too quickly.
            r = timeline_loop(&s->timeline, s->interval);
            if (r < 0) return r;
            s->loops++;
            if (s->loops <= 3) fprintf(stderr, "[probe] cycle=%u loop=%" PRIu64 " frames=%" PRIu64 "\n",
                                        s->probe->cycle, s->loops, s->frames);
            continue;
        }
        if (r < 0) return r;
        if (s->packet->stream_index == s->stream) r = submit(s, s->packet, &eof);
        else r = 0;
        av_packet_unref(s->packet);
        if (r) return r;
    }
}
static void *worker(void *opaque) {
    Probe *p = opaque;
    Session s = { .probe = p };
    int result = open_session(&s);
    if (result >= 0) result = decode(&s);
    p->failed = result < 0 && !canceled(p);
    if (p->failed) {
        char error[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(result, error, sizeof(error));
        fprintf(stderr, "[probe] cycle=%u error=%s code=%d\n", p->cycle, error, result);
    }
    int64_t teardown = now_ns();
    /* Frames own decoder-pool/device references: free them before the decoder,
     * then drop the final application hardware-device reference. */
#ifdef PROBE_RENDER
    av_frame_free(&s.rgba);
    sws_freeContext(s.scaler);
    fprintf(stderr, "[probe] cycle=%u conversion_total_ms=%.3f\n", p->cycle, ms(s.conversion_ns));
#endif
    av_packet_free(&s.packet);
    av_frame_free(&s.download);
    av_frame_free(&s.frame);
    avcodec_free_context(&s.decoder);
    avformat_close_input(&s.input);
    av_buffer_unref(&s.device);
    fprintf(stderr, "[probe] cycle=%u frames=%" PRIu64 " downloads=%" PRIu64
            " loops=%" PRIu64 " download_total_ms=%.3f outcome=%s\n", p->cycle,
            s.frames, s.downloads, s.loops, ms(s.transfer_ns),
            p->failed ? "error" : canceled(p) ? "hidden" : "frame_limit");
    log_stage(p->cycle, "session_released", teardown);
    atomic_store_explicit(&p->done, true, memory_order_release);
#ifdef PROBE_RENDER
    notify_owner(p);
#endif
    return NULL;
}
static void hide(Probe *p) {
    int64_t start = now_ns();
    pthread_mutex_lock(&p->mutex);
    atomic_store_explicit(&p->stop, true, memory_order_release);
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->mutex);
#ifdef PROBE_RENDER
    if (probe_renderer_hide(p->renderer) < 0) p->had_error = true;
#endif
    if (p->joinable) {
        pthread_join(p->thread, NULL);
        p->joinable = false;
        p->had_error |= p->failed;
    }
#ifdef PROBE_RENDER
    av_frame_free(&p->pending); /* Worker is joined: no remaining mailbox writer. */
    fprintf(stderr, "[probe] cycle=%u submitted=%" PRIu64 " replaced_frames=%" PRIu64
            " upload_total_ms=%.3f draw_total_ms=%.3f swap_total_ms=%.3f\n", p->cycle,
            p->submitted, p->dropped, ms(p->upload_ns), ms(p->draw_ns), ms(p->swap_ns));
    log_stage(p->cycle, "video_buffers_released", start);
#endif
    log_stage(p->cycle, "hide_completed", start);
}
static void show(Probe *p) {
    if (p->joinable && !atomic_load_explicit(&p->done, memory_order_acquire)) {
        log_stage(p->cycle, "already_showing", now_ns());
        return;
    }
    if (p->joinable) hide(p);
    p->cycle++;
    p->failed = false;
    atomic_store_explicit(&p->stop, false, memory_order_release);
    atomic_store_explicit(&p->done, false, memory_order_release);
    p->show_start = now_ns();
    log_stage(p->cycle, "show_requested", p->show_start);
#ifdef PROBE_RENDER
    p->first_submitted = false; p->submitted = p->dropped = 0;
    p->upload_ns = p->draw_ns = p->swap_ns = 0;
    if (probe_renderer_show(p->renderer) < 0) { p->had_error = true; return; }
#endif
    int r = pthread_create(&p->thread, NULL, worker, p);
    if (r) {
        fprintf(stderr, "[probe] pthread_create: %s\n", strerror(r));
        p->had_error = true;
        return;
    }
    p->joinable = true;
}
static bool command(Probe *p, char *line) {
    char *start = line;
    while (*start == ' ' || *start == '\t') start++;
    size_t len = strlen(start);
    while (len && (start[len - 1] == ' ' || start[len - 1] == '\t' || start[len - 1] == '\r')) start[--len] = 0;
    if (!len) return true;
    if (!strcmp(start, "show")) show(p);
    else if (!strcmp(start, "hide")) hide(p);
    else if (!strcmp(start, "quit")) return false;
    else fprintf(stderr, "[probe] unknown_command (expected show, hide, quit)\n");
    return true;
}
static void usage(void) {
#ifdef PROBE_RENDER
    puts("Usage: ffmpeg-render-probe [--decoder software|cuda] [--device INDEX] [--frames N] [--output NAME] VIDEO\n"
         "One-output Wayland background; requires layer-shell. Starts hidden.\n"
         "Commands on stdin: show, hide, quit. EOF/SIGINT/SIGTERM quits.\n"
         "SDR CPU RGBA uploads; no audio, HDR tone mapping, rotation, or GPU interop.\n"
         "hide releases decoder/video textures, retaining EGL/window/shader setup.\n"
         "Timings go to stderr; first_frame_submitted is not confirmed visibility.");
#else
    puts("Usage: ffmpeg-probe [--decoder software|cuda] [--device INDEX] [--frames N] VIDEO\n"
         "Starts hidden. Commands on stdin: show, hide, quit. EOF/SIGINT/SIGTERM quits.\n"
         "Local regular files only. Playback is paced and loops; --frames ends each\n"
         "decode session after N frames. CUDA requires real CUDA frames and downloads;\n"
         "there is no software fallback. No video is displayed. Timings go to stderr.");
#endif
}
int main(int argc, char **argv) {
    origin = now_ns();
    Probe p = { .device = "0" };
    bool decoder_set = false, device_set = false, frames_set = false, positional = false;
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (!positional && !strcmp(arg, "--help")) { usage(); return 0; }
        if (!positional && !strcmp(arg, "--")) { positional = true; continue; }
#ifdef PROBE_RENDER
        if (!positional && !strcmp(arg, "--output")) {
            if (p.output || ++i == argc || !*argv[i]) goto invalid;
            p.output = argv[i]; continue;
        }
#endif
        if (!positional && (!strcmp(arg, "--decoder") || !strcmp(arg, "--device") || !strcmp(arg, "--frames"))) {
            if (++i == argc) goto invalid;
            const char *value = argv[i];
            if (!strcmp(arg, "--decoder")) {
                if (decoder_set || (strcmp(value, "cuda") && strcmp(value, "software"))) goto invalid;
                decoder_set = true; p.cuda = !strcmp(value, "cuda");
            } else if (!strcmp(arg, "--device")) {
                if (device_set || !*value || strspn(value, "0123456789") != strlen(value)) goto invalid;
                device_set = true; p.device = value;
            } else {
                if (frames_set || !*value || strspn(value, "0123456789") != strlen(value)) goto invalid;
                char *end;
                errno = 0;
                p.limit = strtoull(value, &end, 10);
                if (errno || *end || !p.limit) goto invalid;
                frames_set = true;
            }
        } else {
            if (p.path || (!positional && arg[0] == '-')) goto invalid;
            p.path = arg;
        }
    }
    if (!p.path || (device_set && !p.cuda)) goto invalid;
    char *path = realpath(p.path, NULL);
    struct stat st;
    if (!path || stat(path, &st) || !S_ISREG(st.st_mode) || access(path, R_OK)) {
        fprintf(stderr, "ffmpeg-probe: VIDEO must be a readable regular local file\n");
        free(path); return 2;
    }
    p.path = path;
    atomic_init(&p.stop, false);
    atomic_init(&p.done, false);
    pthread_condattr_t attrs;
    int r = pthread_mutex_init(&p.mutex, NULL);
    if (r) { free(path); return 1; }
    r = pthread_condattr_init(&attrs);
    if (!r) {
        r = pthread_condattr_setclock(&attrs, CLOCK_MONOTONIC);
        if (!r) r = pthread_cond_init(&p.cond, &attrs);
        pthread_condattr_destroy(&attrs);
    }
    if (r) { pthread_mutex_destroy(&p.mutex); free(path); return 1; }
    struct sigaction action = { .sa_handler = on_signal };
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    av_log_set_level(AV_LOG_ERROR);
#ifdef PROBE_RENDER
    p.wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    p.renderer = p.wake_fd >= 0 ? probe_renderer_create(p.output) : NULL;
    if (!p.renderer) {
        if (p.wake_fd >= 0) close(p.wake_fd);
        pthread_cond_destroy(&p.cond); pthread_mutex_destroy(&p.mutex); free(path);
        return 1;
    }
    log_stage(0, "presentation_initialized", origin);
#endif
    fprintf(stderr, "[probe] pid=%ld decoder=%s state=hidden ffmpeg=%s commands=show,hide,quit\n",
            (long)getpid(), p.cuda ? "cuda" : "software", av_version_info());
    log_stage(0, "ready", origin);
    char line[256];
    size_t length = 0;
    bool running = true, overflow = false;
    while (running && !interrupted) {
#ifdef PROBE_RENDER
        if (p.joinable && atomic_load_explicit(&p.done, memory_order_acquire) && p.failed) hide(&p);
        if (present_pending(&p) < 0) { p.had_error = true; break; }
        bool stdin_ready = false;
        r = probe_renderer_poll(p.renderer, p.wake_fd, 100, &stdin_ready);
        if (r < 0) { p.had_error = true; break; }
        if (!stdin_ready) continue;
#else
        struct pollfd fd = { .fd = STDIN_FILENO, .events = POLLIN };
        r = poll(&fd, 1, 100);
#endif
        if (r < 0) { if (errno == EINTR) continue; p.had_error = true; break; }
        if (!r) continue;
        char bytes[512];
        ssize_t n = read(STDIN_FILENO, bytes, sizeof(bytes));
        if (n < 0) { if (errno == EINTR) continue; p.had_error = true; break; }
        if (!n) {
            if (length && !overflow) { line[length] = 0; command(&p, line); }
            break;
        }
        for (ssize_t i = 0; i < n && running; i++) {
            if (bytes[i] == '\n') {
                line[length] = 0;
                if (!overflow) running = command(&p, line);
                else fprintf(stderr, "[probe] command_too_long\n");
                length = 0; overflow = false;
            } else if (!overflow) {
                if (bytes[i] == 0 || length == sizeof(line) - 1) overflow = true;
                else line[length++] = bytes[i];
            }
        }
    }
    hide(&p);
#ifdef PROBE_RENDER
    probe_renderer_destroy(p.renderer);
    close(p.wake_fd);
#endif
    pthread_cond_destroy(&p.cond);
    pthread_mutex_destroy(&p.mutex);
    free(path);
    return p.had_error ? 1 : 0;
invalid:
    fprintf(stderr, "ffmpeg-probe: invalid arguments (use --help)\n");
    return 2;
}
