/* Deterministic native-plane shader tests on an offscreen software EGL context. */
#define GL_GLEXT_PROTOTYPES
#include "../src/render/yuv.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void check(SWYuv *r, int format, int full, int matrix, int negative) {
    unsigned char storage[3][256]; memset(storage, 0, sizeof(storage));
    SWImage image = {.width=5, .height=3, .format=format, .full_range=full, .matrix=matrix, .sar_num=1, .sar_den=1, .chroma_location=2};
    int semi = format == SW_NV12 || format == SW_P010;
    int bytes = format >= SW_P010 ? 2 : 1;
    int values[] = {81,90,240};
    if (bytes==2) for (int i=0;i<3;i++) values[i]=values[i]*4+i+1;
    for (int p=0; p<(semi?2:3); p++) {
        int w = p?3:5, h = p?2:3, channels = p && semi ? 2 : 1;
        int stride = 32;
        for (int y=0; y<h; y++) for (int x=0; x<w; x++) for (int c=0; c<channels; c++) {
            int value = values[p && semi ? c+1 : p];
            if (format==SW_P010) value <<= 6;
            if (bytes==1) storage[p][y*stride+x*channels+c] = (unsigned char)value;
            else { uint16_t v=(uint16_t)value; memcpy(&storage[p][y*stride+(x*channels+c)*2], &v,2); }
        }
        image.data[p] = storage[p] + (negative ? (h-1)*stride : 0);
        image.stride[p] = negative ? -stride : stride;
    }
    assert(!sw_yuv_upload(r,&image)); assert(!sw_yuv_draw(r,64,64,1));
    unsigned char pixel[4]; glReadPixels(32,32,1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel);
    double kr=matrix==709?.2126:matrix==2020?.2627:matrix==470?.30:matrix==240?.212:.299;
    double kb=matrix==709?.0722:matrix==2020?.0593:matrix==470?.11:matrix==240?.087:.114, kg=1-kr-kb;
    double factor=bytes==2?4:1, max=bytes==2?1023:255;
    double y=(values[0]-(full?0:16*factor))/(full?max:219*factor);
    double u=(values[1]-128*factor)/(full?max:224*factor);
    double v=(values[2]-128*factor)/(full?max:224*factor);
    double expected[]={y+2*(1-kr)*v,y-2*kb*(1-kb)/kg*u-2*kr*(1-kr)/kg*v,y+2*(1-kb)*u};
    for(int c=0;c<3;c++) {
        int want=(int)lround(fmax(0,fmin(1,expected[c]))*255);
        if(abs((int)pixel[c]-want)>2) {fprintf(stderr,"format=%d full=%d matrix=%d channel=%d got=%d want=%d\n",format,full,matrix,c,pixel[c],want);assert(0);}
    }
    assert(pixel[3]==255);
    assert(!sw_yuv_draw(r,64,64,0)); glReadPixels(32,1,1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel);
    assert(pixel[0]==0 && pixel[1]==0 && pixel[2]==0); /* Fit letterboxing. */
    /* Keep storage alive across checks to exercise subimage updates and format changes. */
}
static void spatial(SWYuv *r) {
    unsigned char yplane[21], uvplane[14];
    for(int negative=0;negative<2;negative++) {
        memset(yplane,0,sizeof(yplane)); memset(uvplane,0,sizeof(uvplane));
        int levels[]={40,128,210};
        for(int row=0;row<3;row++) for(int x=0;x<5;x++) yplane[(negative?2-row:row)*7+x]=(unsigned char)levels[row];
        for(int row=0;row<2;row++) for(int x=0;x<3;x++) {uvplane[row*7+x*2]=(unsigned char)(80+x*48);uvplane[row*7+x*2+1]=128;}
        SWImage image={.data={yplane+(negative?14:0),uvplane},.stride={negative?-7:7,7},
            .width=5,.height=3,.format=SW_NV12,.matrix=601,.sar_num=1,.sar_den=1,.chroma_location=2};
        assert(!sw_yuv_upload(r,&image)); assert(!sw_yuv_draw(r,5,3,1));
        unsigned char center[4],top[4],bottom[4];
        glReadPixels(2,1,1,1,GL_RGBA,GL_UNSIGNED_BYTE,center);
        glReadPixels(2,2,1,1,GL_RGBA,GL_UNSIGNED_BYTE,top);
        glReadPixels(2,0,1,1,GL_RGBA,GL_UNSIGNED_BYTE,bottom);
        /* Odd-width centered chroma at x=2 interpolates U=116, not U=128. */
        int blue=(int)lround(((128-16)/219.0+2*(1-.114)*(116-128)/224.0)*255);
        assert(abs((int)center[2]-blue)<=2);
        assert(top[0]<50 && bottom[0]>200); /* Top/bottom orientation, even with negative stride. */
        image.chroma_location=1; assert(!sw_yuv_upload(r,&image)); assert(!sw_yuv_draw(r,5,3,1));
        glReadPixels(2,1,1,1,GL_RGBA,GL_UNSIGNED_BYTE,center);
        blue=(int)lround((128-16)/219.0*255);
        assert(abs((int)center[2]-blue)<=2);
    }
    sw_yuv_release_video(r);
}
int main(void) {
    EGLDisplay d=eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,EGL_DEFAULT_DISPLAY,NULL);
    assert(d!=EGL_NO_DISPLAY && eglInitialize(d,NULL,NULL) && eglBindAPI(EGL_OPENGL_API));
    const EGLint attrs[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config; EGLint count; assert(eglChooseConfig(d,attrs,&config,1,&count)&&count);
    const EGLint ca[]={EGL_NONE}, sa[]={EGL_WIDTH,64,EGL_HEIGHT,64,EGL_NONE};
    EGLContext ctx=eglCreateContext(d,config,EGL_NO_CONTEXT,ca);
    EGLSurface surface=eglCreatePbufferSurface(d,config,sa);
    assert(ctx!=EGL_NO_CONTEXT && surface!=EGL_NO_SURFACE && eglMakeCurrent(d,surface,surface,ctx));
    SWYuv *r=sw_yuv_create(); assert(r);
    const int matrices[]={601,709,2020,470,240};
    for(int format=SW_NV12;format<=SW_YUV420P10;format++) for(int full=0;full<2;full++)
        for(int matrix=0;matrix<5;matrix++) for(int negative=0;negative<2;negative++) check(r,format,full,matrices[matrix],negative);
    spatial(r);
    sw_yuv_destroy(r); eglMakeCurrent(d,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
    eglDestroySurface(d,surface); eglDestroyContext(d,ctx); eglTerminate(d);
    puts("Native YUV shader pixel tests passed");
}
