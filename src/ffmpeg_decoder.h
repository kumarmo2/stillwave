#ifndef STILLWAVE_FFMPEG_DECODER_H
#define STILLWAVE_FFMPEG_DECODER_H
#include <stdint.h>
/* Native ABI contains no FFmpeg headers; all published frames are CPU-owned. */
typedef struct SWDecoder SWDecoder;
typedef struct SWFrame SWFrame;
enum { SW_NV12 = 1, SW_YUV420P = 2, SW_P010 = 3, SW_YUV420P10 = 4 };
typedef struct {
    const uint8_t *data[3];
    int stride[3];
    int width, height, format, full_range, matrix, chroma_location;
    int sar_num, sar_den;
    uint64_t sequence;
} SWImage;
typedef struct {
    int failed, eof, busy, requested;
    uint64_t last_sequence, releases, eof_deadline_ns;
} SWDecoderStatus;
SWDecoder *sw_decoder_create(const char *path, int loop, int paused, int hw_auto,
                             int wake_fd, const char *label, int profile);
void sw_decoder_visibility(SWDecoder *d, int visible);
void sw_decoder_paused(SWDecoder *d, int paused);
void sw_decoder_status(SWDecoder *d, SWDecoderStatus *status);
SWFrame *sw_decoder_take(SWDecoder *d);
const SWImage *sw_frame_image(const SWFrame *frame);
void sw_frame_free(SWFrame *frame);
void sw_decoder_destroy(SWDecoder *d);
#endif
