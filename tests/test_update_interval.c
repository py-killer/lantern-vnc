/* Synthetic constant-motion VNC fixture: real worker cadence/input/cancel. */
#include "VNCBridge.h"
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    vncv_client *client;
    const char *scenario;
    int frames, connected, disconnected, intentional, background;
    double first_at;
} State;
static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
static void input(State *s, uint32_t symbol) {
    assert(vncv_key(s->client, symbol, 1));
    assert(vncv_key(s->client, symbol, 0));
    assert(vncv_pointer(s->client, 1, 1, 1));
    assert(vncv_pointer(s->client, 2, 1, 1));
    assert(vncv_pointer(s->client, 2, 1, 0));
    assert(vncv_pointer(s->client, 3, 1, 0));
    assert(vncv_clipboard(s->client, "Pacing clipboard", 16));
}
static void connected(void *context, const char *name, int width, int height) {
    State *s = context;
    assert(name && strstr(name, "integration") && width == 4 && height == 3);
    if (s->background || !strcmp(s->scenario, "pacing-input")) {
        uint32_t interval = !strcmp(s->scenario, "pacing-cancel") || !strcmp(s->scenario, "pacing-reset") ? UINT32_MAX : 2000;
        assert(vncv_set_update_interval(s->client, interval));
    } else if (!strcmp(s->scenario, "pacing-active")) {
        assert(vncv_set_update_interval(s->client, 0));
    }
    if (s->background) input(s, 'x'); /* Every one must be suppressed. */
    else if (strcmp(s->scenario, "pacing-input")) input(s, 'p');
    pthread_mutex_lock(&s->lock);
    s->connected++;
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->lock);
}
static void frame(void *context, const uint8_t *pixels, int width, int height,
                  int stride, int x, int y, int w, int h) {
    State *s = context;
    assert(pixels && width == 4 && height == 3 && stride == 16);
    assert(!x && !y && w == width && h == height); /* Full promotion content. */
    const uint8_t *last = pixels + (height - 1) * stride + (width - 1) * 4;
    assert(pixels[0] == 75 && pixels[1] == 50 && pixels[2] >= 25);
    assert(!memcmp(pixels, last, 4)); /* Borrowed pixels read only in callback. */
    pthread_mutex_lock(&s->lock);
    if (!s->frames) s->first_at = now();
    s->frames++;
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->lock);
}
static void disconnected(void *context, const char *reason, int intentional) {
    State *s = context; assert(reason);
    pthread_mutex_lock(&s->lock);
    s->disconnected++; s->intentional = intentional;
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->lock);
}
static void await_frames(State *s, int frames) {
    struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec += 7;
    pthread_mutex_lock(&s->lock);
    while (s->frames < frames) {
        assert(!s->disconnected);
        assert(!pthread_cond_timedwait(&s->changed, &s->lock, &deadline));
    }
    pthread_mutex_unlock(&s->lock);
}
static int frame_count(State *s) {
    pthread_mutex_lock(&s->lock); int count = s->frames; pthread_mutex_unlock(&s->lock); return count;
}
static double stop(State *s) {
    double at = now(); vncv_stop(s->client); vncv_wait(s->client);
    double elapsed = now() - at;
    assert(elapsed < .5 && s->disconnected == 1 && s->intentional);
    assert(!vncv_is_running(s->client) && !vncv_set_update_interval(s->client, 2000));
    vncv_network_rtt rtt;
    assert(!vncv_get_network_rtt(s->client, &rtt) && !rtt.available);
    return elapsed;
}
static int isolation(int port) {
    State background = {.lock=PTHREAD_MUTEX_INITIALIZER, .changed=PTHREAD_COND_INITIALIZER,
                        .scenario="pacing-cancel", .background=1};
    State active = {.lock=PTHREAD_MUTEX_INITIALIZER, .changed=PTHREAD_COND_INITIALIZER,
                    .scenario="pacing-active"};
    vncv_callbacks callbacks = {connected, frame, NULL, disconnected};
    background.client = vncv_create(callbacks, &background);
    active.client = vncv_create(callbacks, &active);
    assert(background.client && active.client);
    assert(vncv_start_with_options(background.client, "127.0.0.1", (uint16_t)port, "", 1, 8, 3));
    await_frames(&background, 1); /* Gives the two connections stable fixture IDs. */
    assert(vncv_start_with_options(active.client, "127.0.0.1", (uint16_t)port, "", 0, 8, 3));
    await_frames(&active, 1);
    /* A semantic wait, not a throughput benchmark of a shared CI runner.
       Seven frames at an accidental 2-second cadence cannot fit in 7s. The
       other connection is intentionally parked, so this wait cannot consume
       its background deadline or confuse per-session isolation. */
    await_frames(&active, 7);
    assert(frame_count(&active) >= 7 && frame_count(&background) == 1);
    double background_stop = stop(&background), active_stop = stop(&active);
    printf("{\"scenario\":\"pacing-isolation\",\"frames\":%d,\"stopMilliseconds\":%.3f}\n",
           frame_count(&active) + frame_count(&background),
           (background_stop > active_stop ? background_stop : active_stop) * 1000);
    vncv_destroy(background.client); vncv_destroy(active.client);
    pthread_cond_destroy(&background.changed); pthread_mutex_destroy(&background.lock);
    pthread_cond_destroy(&active.changed); pthread_mutex_destroy(&active.lock);
    return 0;
}
int main(int argc, char **argv) {
    assert(argc == 3);
    if (!strcmp(argv[2], "pacing-isolation")) return isolation(atoi(argv[1]));
    State s = {.lock=PTHREAD_MUTEX_INITIALIZER, .changed=PTHREAD_COND_INITIALIZER, .scenario=argv[2]};
    s.background = strcmp(s.scenario, "pacing-active") && strcmp(s.scenario, "pacing-input");
    vncv_callbacks callbacks = {connected, frame, NULL, disconnected};
    s.client = vncv_create(callbacks, &s); assert(s.client);
    assert(!vncv_set_update_interval(s.client, 2000));
    int repeats = !strcmp(s.scenario, "pacing-reset") ? 2 : 1;
    double promoted = 0, input_at = 0, max_stop = 0;
    int total_frames = 0;
    for (int iteration = 0; iteration < repeats; iteration++) {
        s.frames = s.connected = s.disconnected = s.intentional = 0;
        s.first_at = 0;
        if (iteration) s.background = 0;
        assert(vncv_start_with_options(s.client, "127.0.0.1", (uint16_t)atoi(argv[1]), "", s.background, 8, 3));
        await_frames(&s, 1);
        if (!strcmp(s.scenario, "pacing-background")) {
            await_frames(&s, 2);
            assert(frame_count(&s) == 2); /* Initial + one 2-second preview. */
        } else if (!strcmp(s.scenario, "pacing-promote")) {
            usleep(100000); assert(frame_count(&s) == 1);
            promoted = now();
            assert(vncv_set_update_interval(s.client, 0));
            assert(vncv_set_view_only(s.client, 0));
            assert(vncv_refresh(s.client));
            input(&s, 'p');
            await_frames(&s, 5);
            /* The runner checks full-request delivery time on the wire;
               rendering five frames is not itself a CI latency benchmark. */
        } else if (!strcmp(s.scenario, "pacing-input")) {
            input_at = now(); input(&s, 'p');
            usleep(200000);
            assert(frame_count(&s) == 1); /* Input serviced during paced wait. */
        } else if (!s.background) {
            await_frames(&s, 7);
        } else {
            usleep(100000); assert(frame_count(&s) == 1);
        }
        double elapsed = stop(&s); if (elapsed > max_stop) max_stop = elapsed;
        assert(s.connected == 1);
        total_frames += frame_count(&s);
    }
    vncv_destroy(s.client);
    pthread_cond_destroy(&s.changed); pthread_mutex_destroy(&s.lock);
    printf("{\"scenario\":\"%s\",\"frames\":%d,\"promoted\":%.9f,\"inputAt\":%.9f,\"stopMilliseconds\":%.3f}\n",
           s.scenario, total_frames, promoted, input_at, max_stop * 1000);
    return 0;
}
