/* Pure timing tests; linking FFmpeg does not initialize a GPU/device. */
#define main probe_cli_main
#include "../experiments/ffmpeg-probe.c"
#undef main
#include <assert.h>
#include <float.h>

int main(void) {
    const int64_t now = 1000000000;
    int64_t target;
    Timeline t = {0};
    assert(!timeline_target(&t, 5, .1, now, &target) && target == now);
    assert(!timeline_target(&t, 20, .1, now, &target) && target == now + 15000000000);
    /* A valid long interval must not be treated as a discontinuity. */
    assert(!timeline_loop(&t, .1));
    assert(!timeline_target(&t, 5, .1, now, &target) && target == now + 15100000000);

    t = (Timeline){0};
    assert(!timeline_target(&t, NAN, .1, now, &target) && target == now);
    assert(!timeline_target(&t, 5, .1, now, &target) && target == now + 100000000);
    assert(!timeline_target(&t, NAN, .1, now, &target) && target == now + 200000000);
    assert(!timeline_target(&t, 5.3, .1, now, &target));
    assert(llabs(target - (now + 400000000)) <= 1);
    /* Reanchor backward jumps onto the next synthetic frame interval. */
    assert(!timeline_target(&t, 0, .1, now, &target));
    assert(llabs(target - (now + 500000000)) <= 1);
    assert(timeline_target(&t, DBL_MAX, .1, now, &target) == AVERROR_INVALIDDATA);
    return 0;
}
