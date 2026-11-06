#ifndef STILLWAVE_YUV_H
#define STILLWAVE_YUV_H
#include "../ffmpeg_decoder.h"
typedef struct SWYuv SWYuv;
/* All functions require the owning EGL context current on the calling thread. */
SWYuv *sw_yuv_create(void);
int sw_yuv_upload(SWYuv *r, const SWImage *image);
int sw_yuv_draw(SWYuv *r, int width, int height, int fill);
void sw_yuv_release_video(SWYuv *r);
void sw_yuv_destroy(SWYuv *r);
#endif
