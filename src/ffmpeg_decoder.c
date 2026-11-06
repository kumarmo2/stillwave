#define _POSIX_C_SOURCE 200809L
#include "ffmpeg_decoder.h"
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct SWFrame { AVFrame *frame; SWImage image; uint64_t epoch; };
struct SWDecoder {
    char *path, *label;
    int loop, paused, hw_auto, wake_fd, profile;
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    atomic_bool cancel;
    bool quit, requested, busy, failed, eof;
    uint64_t epoch, last_sequence, releases;
    int64_t eof_ns;
    SWFrame *pending;
};
typedef struct {
    SWDecoder *owner;
    uint64_t epoch, frames, pass_frames;
    AVFormatContext *input;
    AVCodecContext *codec;
    AVBufferRef *device;
    AVPacket *packet;
    AVFrame *frame, *download;
    int stream;
    bool cuda, anchored, clock_set;
    double interval, anchor_pts, anchor_delta, last_delta;
    int64_t clock_origin, next_origin, last_target;
} Session;
static int64_t now_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static void notify(SWDecoder *d) {
    uint64_t one = 1;
    while (write(d->wake_fd, &one, sizeof(one)) < 0 && errno == EINTR) {}
}
static int canceled(void *opaque) { return atomic_load_explicit(&((SWDecoder *)opaque)->cancel, memory_order_acquire); }
void sw_frame_free(SWFrame *f) { if (f) { av_frame_free(&f->frame); free(f); } }
const SWImage *sw_frame_image(const SWFrame *f) { return &f->image; }
static int wait_until(SWDecoder *d, int64_t target) {
    struct timespec deadline = { target / 1000000000, target % 1000000000 };
    pthread_mutex_lock(&d->mutex);
    while (!canceled(d) && now_ns() < target) {
        int r = pthread_cond_timedwait(&d->cond, &d->mutex, &deadline);
        if (r && r != ETIMEDOUT) { pthread_mutex_unlock(&d->mutex); return AVERROR(r); }
    }
    pthread_mutex_unlock(&d->mutex);
    return canceled(d) ? AVERROR_EXIT : 0;
}
static int pace(Session *s) {
    double pts = s->frame->best_effort_timestamp == AV_NOPTS_VALUE ? NAN :
        s->frame->best_effort_timestamp * av_q2d(s->input->streams[s->stream]->time_base);
    if (!s->clock_set) {
        s->clock_set = true; s->clock_origin = now_ns();
        if (s->next_origin > s->clock_origin) s->clock_origin = s->next_origin;
        s->last_delta = -s->interval;
    }
    double delta = s->last_delta + s->interval;
    if (isfinite(pts)) {
        if (!s->anchored || pts - s->anchor_pts + s->anchor_delta < s->last_delta - .5) {
            s->anchored = true; s->anchor_pts = pts; s->anchor_delta = delta;
        }
        delta = pts - s->anchor_pts + s->anchor_delta;
    }
    delta = fmax(0, fmax(delta, s->last_delta));
    double ns = delta * 1000000000;
    if (!isfinite(ns) || ns >= (double)(INT64_MAX - s->clock_origin)) return AVERROR_INVALIDDATA;
    s->last_delta = delta; s->last_target = s->clock_origin + (int64_t)ns;
    return wait_until(s->owner, s->last_target);
}
static enum AVPixelFormat cuda_format(AVCodecContext *c, const enum AVPixelFormat *formats) {
    (void)c;
    for (; *formats != AV_PIX_FMT_NONE; formats++) if (*formats == AV_PIX_FMT_CUDA) return *formats;
    return AV_PIX_FMT_NONE;
}
static int open_session(Session *s, bool hardware) {
    SWDecoder *d = s->owner;
    if (canceled(d)) return AVERROR_EXIT;
    s->input = avformat_alloc_context();
    if (!s->input) return AVERROR(ENOMEM);
    s->input->interrupt_callback = (AVIOInterruptCB){ canceled, d };
    AVDictionary *options = NULL;
    int r = av_dict_set(&options, "protocol_whitelist", "file", 0);
    if (r >= 0) r = av_dict_set(&options, "format_whitelist",
        "mov,matroska,webm,avi,mpegts,mpeg,ogg,flv,nut,asf,rm,h264,hevc,av1,ivf,wav", 0);
    if (r >= 0) r = avformat_open_input(&s->input, d->path, NULL, &options);
    av_dict_free(&options);
    if (r < 0) return r;
    if (canceled(d)) return AVERROR_EXIT;
    if ((r = avformat_find_stream_info(s->input, NULL)) < 0) return r;
    if (canceled(d)) return AVERROR_EXIT;
    const AVCodec *codec = NULL;
    if ((r = av_find_best_stream(s->input, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0)) < 0) return r;
    s->stream = r;
    s->codec = avcodec_alloc_context3(codec);
    if (!s->codec) return AVERROR(ENOMEM);
    if ((r = avcodec_parameters_to_context(s->codec, s->input->streams[s->stream]->codecpar)) < 0) return r;
    s->codec->pkt_timebase = s->input->streams[s->stream]->time_base;
    if (canceled(d)) return AVERROR_EXIT;
    if (hardware) {
        bool supported = false;
        for (int i = 0;; i++) {
            const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
            if (!config) break;
            if (config->device_type == AV_HWDEVICE_TYPE_CUDA && config->pix_fmt == AV_PIX_FMT_CUDA &&
                (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) supported = true;
        }
        if (!supported) return AVERROR(ENOSYS);
        if ((r = av_hwdevice_ctx_create(&s->device, AV_HWDEVICE_TYPE_CUDA, NULL, NULL, 0)) < 0) return r;
        s->codec->hw_device_ctx = av_buffer_ref(s->device);
        if (!s->codec->hw_device_ctx) return AVERROR(ENOMEM);
        s->codec->get_format = cuda_format;
        s->cuda = true;
    }
    if (canceled(d)) return AVERROR_EXIT;
    if ((r = avcodec_open2(s->codec, codec, NULL)) < 0) return r;
    AVRational rate = av_guess_frame_rate(s->input, s->input->streams[s->stream], NULL);
    double fps = av_q2d(rate);
    s->interval = isfinite(fps) && fps > 0 && fps <= 1000 ? 1 / fps : 1.0 / 30;
    s->packet = av_packet_alloc(); s->frame = av_frame_alloc(); s->download = av_frame_alloc();
    return s->packet && s->frame && s->download ? 0 : AVERROR(ENOMEM);
}
static void close_session(Session *s) {
    av_packet_free(&s->packet); av_frame_free(&s->download); av_frame_free(&s->frame);
    avcodec_free_context(&s->codec); avformat_close_input(&s->input); av_buffer_unref(&s->device);
}
static int publish(Session *s) {
    SWDecoder *d = s->owner;
    if (canceled(d)) return AVERROR_EXIT;
    AVFrame *image = s->frame;
    if (s->cuda) {
        if (image->format != AV_PIX_FMT_CUDA || !image->hw_frames_ctx) return AVERROR_INVALIDDATA;
        av_frame_unref(s->download);
        int r = av_hwframe_transfer_data(s->download, image, 0);
        if (r < 0) return r;
        if ((r = av_frame_copy_props(s->download, image)) < 0) return r;
        image = s->download;
    }
    int format;
    switch (image->format) {
        case AV_PIX_FMT_NV12: format = SW_NV12; break;
        case AV_PIX_FMT_YUV420P: case AV_PIX_FMT_YUVJ420P: format = SW_YUV420P; break;
        case AV_PIX_FMT_P010LE: format = SW_P010; break;
        case AV_PIX_FMT_YUV420P10LE: format = SW_YUV420P10; break;
        default:
            fprintf(stderr, "[%s/ffmpeg] unsupported pixel format %s; use --backend mpv\n", d->label, av_get_pix_fmt_name(image->format));
            return AVERROR(ENOTSUP);
    }
    if (image->color_trc == AVCOL_TRC_SMPTE2084 || image->color_trc == AVCOL_TRC_ARIB_STD_B67) {
        fprintf(stderr, "[%s/ffmpeg] HDR tone mapping unsupported; use --backend mpv\n", d->label);
        return AVERROR(ENOTSUP);
    }
    int matrix;
    switch (image->colorspace) {
        case AVCOL_SPC_BT709: matrix = 709; break;
        case AVCOL_SPC_FCC: matrix = 470; break;
        case AVCOL_SPC_SMPTE240M: matrix = 240; break;
        case AVCOL_SPC_BT2020_NCL: matrix = 2020; break;
        case AVCOL_SPC_SMPTE170M: case AVCOL_SPC_BT470BG: matrix = 601; break;
        case AVCOL_SPC_UNSPECIFIED: matrix = image->width >= 1280 || image->height > 576 ? 709 : 601; break;
        default:
            fprintf(stderr, "[%s/ffmpeg] unsupported color matrix %d; use --backend mpv\n", d->label, image->colorspace);
            return AVERROR(ENOTSUP);
    }
    SWFrame *f = calloc(1, sizeof(*f));
    if (!f) return AVERROR(ENOMEM);
    f->frame = av_frame_clone(image);
    if (!f->frame) { free(f); return AVERROR(ENOMEM); }
    int r = av_frame_apply_cropping(f->frame, 0);
    if (r < 0) { sw_frame_free(f); return r; }
    image = f->frame;
    f->epoch = s->epoch;
    f->image = (SWImage){ .width = image->width, .height = image->height, .format = format,
        .full_range = image->color_range == AVCOL_RANGE_JPEG || image->format == AV_PIX_FMT_YUVJ420P,
        .matrix = matrix, .chroma_location = image->chroma_location,
        .sar_num = image->sample_aspect_ratio.num, .sar_den = image->sample_aspect_ratio.den,
        .sequence = s->frames + 1 };
    for (int i = 0; i < 3; i++) { f->image.data[i] = image->data[i]; f->image.stride[i] = image->linesize[i]; }
    r = pace(s);
    if (r < 0) { sw_frame_free(f); return r; }
    pthread_mutex_lock(&d->mutex);
    if (canceled(d) || d->epoch != s->epoch) { pthread_mutex_unlock(&d->mutex); sw_frame_free(f); return AVERROR_EXIT; }
    sw_frame_free(d->pending); d->pending = f;
    d->last_sequence = ++s->frames;
    pthread_mutex_unlock(&d->mutex);
    notify(d);
    av_frame_unref(s->frame); av_frame_unref(s->download);
    if (s->frames == 1 && d->profile)
        fprintf(stderr, "[%s/ffmpeg] first frame ready decoding=%s format=%d (GPU color conversion)\n", d->label, s->cuda ? "cuda" : "software", format);
    int64_t pause_start = now_ns();
    pthread_mutex_lock(&d->mutex);
    bool waited = false;
    while (d->paused && !canceled(d)) {
        waited = true;
        pthread_cond_wait(&d->cond, &d->mutex);
    }
    pthread_mutex_unlock(&d->mutex);
    if (canceled(d)) return AVERROR_EXIT;
    // Staging holds the first frame. Shift its clock by the pause duration
    // so activation neither catches up nor drops the first frame's interval.
    if (waited) {
        int64_t delay = now_ns() - pause_start;
        if (s->clock_origin > INT64_MAX - delay || s->last_target > INT64_MAX - delay)
            return AVERROR_INVALIDDATA;
        s->clock_origin += delay;
        s->last_target += delay;
    }
    return 0;
}
static int receive(Session *s, bool *eof) {
    for (;;) {
        if (canceled(s->owner)) return AVERROR_EXIT;
        int r = avcodec_receive_frame(s->codec, s->frame);
        if (r == AVERROR(EAGAIN)) return 0;
        if (r == AVERROR_EOF) { *eof = true; return 0; }
        if (r < 0) return r;
        if ((r = publish(s)) < 0) return r;
    }
}
static int submit(Session *s, const AVPacket *packet, bool *eof) {
    for (;;) {
        if (canceled(s->owner)) return AVERROR_EXIT;
        int r = avcodec_send_packet(s->codec, packet);
        if (r == AVERROR_EOF && !packet) { *eof = true; return 0; }
        if (r == AVERROR(EAGAIN)) {
            uint64_t before = s->frames;
            if ((r = receive(s, eof)) < 0 || *eof) return r;
            if (before == s->frames) return AVERROR_BUG;
            continue;
        }
        if (r < 0) return r;
        return receive(s, eof);
    }
}
static int decode(Session *s) {
    for (;;) {
        if (canceled(s->owner)) return AVERROR_EXIT;
        int r = av_read_frame(s->input, s->packet);
        bool eof = false;
        if (r == AVERROR_EOF) {
            if ((r = submit(s, NULL, &eof)) < 0) return r;
            if (!eof || s->frames == s->pass_frames) return AVERROR_INVALIDDATA;
            int64_t step = (int64_t)(s->interval * 1000000000);
            if (s->last_target > INT64_MAX - step) return AVERROR_INVALIDDATA;
            s->next_origin = s->last_target + step;
            if (!s->owner->loop) return wait_until(s->owner, s->next_origin);
            AVStream *stream = s->input->streams[s->stream];
            int64_t start = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
            if ((r = av_seek_frame(s->input, s->stream, start, AVSEEK_FLAG_BACKWARD)) < 0) return r;
            avcodec_flush_buffers(s->codec);
            s->pass_frames = s->frames; s->clock_set = s->anchored = false;
            continue;
        }
        if (r < 0) return r;
        if (s->packet->stream_index == s->stream) r = submit(s, s->packet, &eof);
        else r = 0;
        av_packet_unref(s->packet);
        if (r < 0) return r;
    }
}
static void *worker(void *opaque) {
    SWDecoder *d = opaque;
    uint64_t handled = 0;
    pthread_mutex_lock(&d->mutex);
    while (!d->quit) {
        while (!d->quit && (!d->requested || d->epoch == handled)) pthread_cond_wait(&d->cond, &d->mutex);
        if (d->quit) break;
        Session s = { .owner = d, .epoch = d->epoch };
        handled = d->epoch; d->busy = true;
        atomic_store_explicit(&d->cancel, false, memory_order_release);
        pthread_mutex_unlock(&d->mutex);
        int result = open_session(&s, d->hw_auto != 0);
        if (result >= 0) result = decode(&s);
        // Auto hardware selection may fall back before publishing any frames.
        // Unsupported native formats/HDR are never converted or silently retried.
        if (result < 0 && result != AVERROR(ENOTSUP) && d->hw_auto && !s.frames && !canceled(d)) {
            close_session(&s);
            s = (Session){ .owner = d, .epoch = handled };
            if (canceled(d)) result = AVERROR_EXIT;
            else {
                fprintf(stderr, "[%s/ffmpeg] hardware unavailable; retrying software decoding\n", d->label);
                result = open_session(&s, false);
                if (result >= 0) result = decode(&s);
            }
        }
        bool failed = result < 0 && !canceled(d);
        if (failed) {
            char message[AV_ERROR_MAX_STRING_SIZE]; av_strerror(result, message, sizeof(message));
            fprintf(stderr, "[%s/ffmpeg] %s\n", d->label, message);
        }
        int64_t release_start = now_ns();
        close_session(&s);
        pthread_mutex_lock(&d->mutex);
        d->busy = false; d->releases++;
        if (d->epoch == handled) { d->failed = failed; d->eof = result == 0; d->eof_ns = now_ns(); }
        if (!d->requested) { sw_frame_free(d->pending); d->pending = NULL; }
        pthread_mutex_unlock(&d->mutex);
        if (d->profile) fprintf(stderr, "[%s/ffmpeg] decoder resources released in %.3f ms\n", d->label, (now_ns() - release_start) / 1000000.0);
        notify(d);
        pthread_mutex_lock(&d->mutex);
    }
    pthread_mutex_unlock(&d->mutex);
    return NULL;
}
SWDecoder *sw_decoder_create(const char *path, int loop, int paused, int hw_auto, int wake_fd, const char *label, int profile) {
    SWDecoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->path = strdup(path); d->label = strdup(label);
    if (!d->path || !d->label) goto strings;
    d->loop = loop; d->paused = paused; d->hw_auto = hw_auto; d->wake_fd = wake_fd; d->profile = profile;
    d->requested = true; d->epoch = 1;
    atomic_init(&d->cancel, false);
    if (pthread_mutex_init(&d->mutex, NULL)) goto strings;
    pthread_condattr_t attr;
    if (pthread_condattr_init(&attr)) goto mutex;
    int r = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    if (!r) r = pthread_cond_init(&d->cond, &attr);
    pthread_condattr_destroy(&attr);
    if (r) goto mutex;
    if (pthread_create(&d->thread, NULL, worker, d)) { pthread_cond_destroy(&d->cond); goto mutex; }
    return d;
mutex: pthread_mutex_destroy(&d->mutex);
strings: free(d->path); free(d->label); free(d); return NULL;
}
void sw_decoder_paused(SWDecoder *d, int paused) {
    pthread_mutex_lock(&d->mutex);
    d->paused = paused != 0;
    pthread_cond_broadcast(&d->cond);
    pthread_mutex_unlock(&d->mutex);
}
void sw_decoder_visibility(SWDecoder *d, int visible) {
    pthread_mutex_lock(&d->mutex);
    d->epoch++; d->requested = visible != 0; d->failed = d->eof = false; d->last_sequence = 0;
    sw_frame_free(d->pending); d->pending = NULL;
    atomic_store_explicit(&d->cancel, true, memory_order_release);
    pthread_cond_broadcast(&d->cond);
    pthread_mutex_unlock(&d->mutex);
    notify(d);
}
void sw_decoder_status(SWDecoder *d, SWDecoderStatus *s) {
    pthread_mutex_lock(&d->mutex);
    *s = (SWDecoderStatus){ d->failed, d->eof, d->busy, d->requested, d->last_sequence, d->releases,
        d->eof ? (uint64_t)(d->eof_ns + 500000000) : 0 };
    pthread_mutex_unlock(&d->mutex);
}
SWFrame *sw_decoder_take(SWDecoder *d) {
    pthread_mutex_lock(&d->mutex);
    SWFrame *f = d->pending; d->pending = NULL;
    if (f && (f->epoch != d->epoch || !d->requested)) { sw_frame_free(f); f = NULL; }
    pthread_mutex_unlock(&d->mutex);
    return f;
}
void sw_decoder_destroy(SWDecoder *d) {
    if (!d) return;
    pthread_mutex_lock(&d->mutex);
    d->quit = true; atomic_store_explicit(&d->cancel, true, memory_order_release);
    pthread_cond_broadcast(&d->cond);
    pthread_mutex_unlock(&d->mutex);
    pthread_join(d->thread, NULL);
    sw_frame_free(d->pending);
    pthread_cond_destroy(&d->cond); pthread_mutex_destroy(&d->mutex);
    free(d->path); free(d->label); free(d);
}
