#define GL_GLEXT_PROTOTYPES
#include "yuv.h"
#include <GL/gl.h>
#include <GL/glext.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct SWYuv {
    GLuint program, vbo, texture[3];
    GLint position, uv;
    int width, height, format;
    double sar;
    unsigned char *scratch;
    size_t scratch_size;
};
static GLuint compile(GLenum kind, const char *source) {
    GLuint s = glCreateShader(kind);
    glShaderSource(s, 1, &source, NULL); glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024]; glGetShaderInfoLog(s, sizeof(log), NULL, log); fprintf(stderr, "stillwave/yuv shader: %s\n", log); glDeleteShader(s); return 0; }
    return s;
}
SWYuv *sw_yuv_create(void) {
    const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
    int major = 0; const char *version = (const char *)glGetString(GL_VERSION);
    if (version) major = atoi(version);
    if (major < 3 && (!extensions || !strstr(extensions, "GL_ARB_texture_rg"))) {
        fprintf(stderr, "stillwave: FFmpeg renderer requires texture-RG support\n"); return NULL;
    }
    SWYuv *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    GLuint vs = compile(GL_VERTEX_SHADER,
        "#version 120\nattribute vec2 position;attribute vec2 texcoord;varying vec2 uv;"
        "void main(){gl_Position=vec4(position,0,1);uv=texcoord;}");
    GLuint fs = compile(GL_FRAGMENT_SHADER,
        "#version 120\nuniform sampler2D yp;uniform sampler2D up;uniform sampler2D vp;"
        "uniform int semi;uniform vec4 levels;uniform vec4 coeff;uniform vec2 chromaOffset;uniform vec2 chromaScale;varying vec2 uv;"
        "void main(){vec2 c=uv*chromaScale+chromaOffset;float y=texture2D(yp,uv).r*levels.x;"
        "vec2 pair=texture2D(up,c).rg;float u=pair.r*levels.x;"
        "float v=(semi==1?pair.g:texture2D(vp,c).r)*levels.x;"
        "y=(y-levels.y)/levels.z;u=(u-levels.w)/coeff.w;v=(v-levels.w)/coeff.w;"
        "float kr=coeff.x;float kb=coeff.y;float kg=1.0-kr-kb;"
        "vec3 rgb=vec3(y+2.0*(1.0-kr)*v,y-2.0*kb*(1.0-kb)/kg*u-2.0*kr*(1.0-kr)/kg*v,y+2.0*(1.0-kb)*u);"
        "gl_FragColor=vec4(clamp(rgb,0.0,1.0),1.0);}");
    if (!vs || !fs) { if (vs) glDeleteShader(vs); if (fs) glDeleteShader(fs); free(r); return NULL; }
    r->program = glCreateProgram(); glAttachShader(r->program, vs); glAttachShader(r->program, fs);
    glLinkProgram(r->program); glDeleteShader(vs); glDeleteShader(fs);
    GLint ok = 0; glGetProgramiv(r->program, GL_LINK_STATUS, &ok);
    r->position = glGetAttribLocation(r->program, "position"); r->uv = glGetAttribLocation(r->program, "texcoord");
    if (!ok || r->position < 0 || r->uv < 0) { sw_yuv_destroy(r); return NULL; }
    glGenBuffers(1, &r->vbo);
    glUseProgram(r->program);
    glUniform1i(glGetUniformLocation(r->program, "yp"), 0);
    glUniform1i(glGetUniformLocation(r->program, "up"), 1);
    glUniform1i(glGetUniformLocation(r->program, "vp"), 2);
    if (glGetError() != GL_NO_ERROR) { sw_yuv_destroy(r); return NULL; }
    return r;
}
int sw_yuv_upload(SWYuv *r, const SWImage *image) {
    int semi = image->format == SW_NV12 || image->format == SW_P010;
    int bytes = image->format == SW_P010 || image->format == SW_YUV420P10 ? 2 : 1;
    if (image->format < SW_NV12 || image->format > SW_YUV420P10 || image->width < 1 || image->height < 1) return -1;
    GLint max_texture; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_texture);
    if (image->width > max_texture || image->height > max_texture) return -1;
    bool changed = r->width != image->width || r->height != image->height || r->format != image->format;
    if (!r->texture[0]) glGenTextures(3, r->texture);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_UNPACK_SWAP_BYTES, GL_FALSE);
    for (int p = 0; p < (semi ? 2 : 3); p++) {
        int w = p ? (image->width + 1) / 2 : image->width, h = p ? (image->height + 1) / 2 : image->height;
        int channels = p && semi ? 2 : 1, pixel_bytes = channels * bytes;
        size_t row = (size_t)w * pixel_bytes;
        if (!image->data[p] || image->stride[p] == INT_MIN || (size_t)abs(image->stride[p]) < row) return -1;
        const uint8_t *data = image->data[p];
        int row_length;
        if (image->stride[p] < 0 || image->stride[p] % pixel_bytes) {
            if (row > SIZE_MAX / (size_t)h) return -1;
            size_t required = row * h;
            if (required > r->scratch_size) {
                void *copy = realloc(r->scratch, required);
                if (!copy) return -1;
                r->scratch = copy; r->scratch_size = required;
            }
            for (int y = 0; y < h; y++) memcpy(r->scratch + (size_t)y * row, data + (ptrdiff_t)y * image->stride[p], row);
            data = r->scratch; row_length = w;
        } else row_length = image->stride[p] / pixel_bytes;
        glActiveTexture(GL_TEXTURE0 + p); glBindTexture(GL_TEXTURE_2D, r->texture[p]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, row_length);
        GLenum external = channels == 2 ? GL_RG : GL_RED;
        GLint internal = channels == 2 ? (bytes == 2 ? GL_RG16 : GL_RG8) : (bytes == 2 ? GL_R16 : GL_R8);
        GLenum type = bytes == 2 ? GL_UNSIGNED_SHORT : GL_UNSIGNED_BYTE;
        if (changed) glTexImage2D(GL_TEXTURE_2D, 0, internal, w, h, 0, external, type, data);
        else glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, external, type, data);
    }
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glUseProgram(r->program); glUniform1i(glGetUniformLocation(r->program, "semi"), semi);
    float kr = .299f, kb = .114f;
    switch (image->matrix) {
        case 709: kr = .2126f; kb = .0722f; break;
        case 2020: kr = .2627f; kb = .0593f; break;
        case 240: kr = .212f; kb = .087f; break;
        case 470: kr = .30f; kb = .11f; break;
        case 601: break;
        default: return -1;
    }
    float scale = bytes == 1 ? 255 : image->format == SW_P010 ? 65535.0f / 64 : 65535;
    float max = bytes == 1 ? 255 : 1023, mid = bytes == 1 ? 128 : 512;
    float yoff = image->full_range ? 0 : bytes == 1 ? 16 : 64;
    float yrange = image->full_range ? max : bytes == 1 ? 219 : 876;
    float crange = image->full_range ? max : bytes == 1 ? 224 : 896;
    glUniform4f(glGetUniformLocation(r->program, "levels"), scale, yoff, yrange, mid);
    glUniform4f(glGetUniformLocation(r->program, "coeff"), kr, kb, 0, crange);
    float cx = 0, cy = 0;
    switch (image->chroma_location) {
        case 0: case 1: cx = .5f / image->width; break; /* unspecified/left */
        case 2: break; /* center */
        case 3: cx = .5f / image->width; cy = .5f / image->height; break;
        case 4: cy = .5f / image->height; break;
        case 5: cx = .5f / image->width; cy = -.5f / image->height; break;
        case 6: cy = -.5f / image->height; break;
        default: return -1;
    }
    float sx = (float)image->width / (2 * ((image->width + 1) / 2));
    float sy = (float)image->height / (2 * ((image->height + 1) / 2));
    glUniform2f(glGetUniformLocation(r->program, "chromaScale"), sx, sy);
    glUniform2f(glGetUniformLocation(r->program, "chromaOffset"), cx * sx, cy * sy);
    r->width = image->width; r->height = image->height; r->format = image->format;
    r->sar = image->sar_num > 0 && image->sar_den > 0 ? (double)image->sar_num / image->sar_den : 1;
    return glGetError() == GL_NO_ERROR ? 0 : -1;
}
int sw_yuv_draw(SWYuv *r, int width, int height, int fill) {
    if (!r->texture[0] || !r->width || width < 1 || height < 1) return -1;
    double source = r->width * r->sar / r->height, dest = (double)width / height;
    float x = 1, y = 1, ux = 1, uy = 1;
    if (fill) { if (source > dest) ux = (float)(dest / source); else uy = (float)(source / dest); }
    else { if (source > dest) y = (float)(dest / source); else x = (float)(source / dest); }
    float l = (1 - ux) / 2, rr = 1 - l, t = (1 - uy) / 2, b = 1 - t;
    const GLfloat vertices[] = { -x,-y,l,b, x,-y,rr,b, -x,y,l,t, x,y,rr,t };
    glDisable(GL_FRAMEBUFFER_SRGB); glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_SCISSOR_TEST);
    glViewport(0, 0, width, height); glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(r->program);
    for (int p = 0; p < 3; p++) { glActiveTexture(GL_TEXTURE0 + p); glBindTexture(GL_TEXTURE_2D, r->texture[p]); }
    glBindBuffer(GL_ARRAY_BUFFER, r->vbo); glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STREAM_DRAW);
    glEnableVertexAttribArray((GLuint)r->position); glEnableVertexAttribArray((GLuint)r->uv);
    glVertexAttribPointer((GLuint)r->position, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), (void *)0);
    glVertexAttribPointer((GLuint)r->uv, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), (void *)(2 * sizeof(GLfloat)));
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    return glGetError() == GL_NO_ERROR ? 0 : -1;
}
void sw_yuv_release_video(SWYuv *r) {
    if (!r) return;
    glDeleteTextures(3, r->texture); memset(r->texture, 0, sizeof(r->texture));
    r->width = r->height = r->format = 0;
    free(r->scratch); r->scratch = NULL; r->scratch_size = 0;
    glFlush(); /* Deferred GPU completion: do not stall controls with glFinish. */
}
void sw_yuv_destroy(SWYuv *r) {
    if (!r) return;
    sw_yuv_release_video(r);
    if (r->vbo) glDeleteBuffers(1, &r->vbo);
    if (r->program) glDeleteProgram(r->program);
    free(r);
}
