#include "VNCBridge.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    vncv_client *client;
    int connected, frames, clipboard, disconnected, intentional, errors;
    int view_only, expect_frames, tight;
    char reason[512];
} State;

static void on_connected(void *context, const char *name, int width, int height) {
    State *s = context;
    assert(name && strstr(name, "integration"));
    assert(width == 4 && height == 3);
    pthread_mutex_lock(&s->lock);
    s->connected++;
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->lock);
    assert(vncv_key(s->client, 'a', 1));
    assert(vncv_key(s->client, 'a', 0));
    assert(vncv_pointer(s->client, 2, 1, 1));
    assert(vncv_pointer(s->client, 2, 1, 0));
    assert(vncv_clipboard(s->client, "Local clipboard", 15));
}

static int is_pixel(const uint8_t *pixels, int stride, int x, int y, int r, int g, int b) {
    const uint8_t *p = pixels + y * stride + x * 4;
    return p[0] == b && p[1] == g && p[2] == r;
}

static void on_frame(void *context, const uint8_t *pixels, int width, int height,
                     int stride, int x, int y, int w, int h) {
    State *s = context;
    pthread_mutex_lock(&s->lock);
    assert(pixels && stride == width * 4);
    assert(x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= width && y + h <= height);
    if (width == 4 && height == 3) {
        assert(is_pixel(pixels, stride, 0, 0, 255, 0, 0));
        assert(is_pixel(pixels, stride, 1, 0, 0, 255, 0));
        assert(is_pixel(pixels, stride, 2, 0, 0, 0, 255));
        if (s->frames == 1) {
            assert(is_pixel(pixels, stride, 2, 1, 255, 0, 0));
            assert(is_pixel(pixels, stride, 3, 1, 0, 255, 0));
            if (s->tight) assert(is_pixel(pixels, stride, 0, 2, 255, 128, 0));
        }
    } else {
        assert(width == 8 && height == 4);
        assert(is_pixel(pixels, stride, 0, 0, 0, 0, 255));
        assert(is_pixel(pixels, stride, 7, 3, 255, 255, 0));
    }
    s->frames++;
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->lock);
}

static void on_clipboard(void *context, const char *text, size_t length) {
    State *s = context;
    const char expected[] = "Remote clipboard caf\xc3\xa9";
    assert(length == strlen(expected));
    assert(!memcmp(text, expected, length));
    pthread_mutex_lock(&s->lock);
    s->clipboard++;
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->lock);
}

static void on_disconnected(void *context, const char *message, int intentional) {
    State *s = context;
    pthread_mutex_lock(&s->lock);
    s->disconnected++;
    s->intentional = intentional;
    snprintf(s->reason, sizeof(s->reason), "%s", message);
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->lock);
}

static void await_state(State *s, int disconnected) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 8;
    pthread_mutex_lock(&s->lock);
    while (!(disconnected ? s->disconnected : (s->frames >= 3 && s->clipboard))) {
        int result = pthread_cond_timedwait(&s->changed, &s->lock, &deadline);
        if (result || (!disconnected && s->disconnected)) {
            fprintf(stderr, "Timed out / disconnected: frames=%d clipboard=%d reason=%s\n", s->frames, s->clipboard, s->reason);
            abort();
        }
    }
    pthread_mutex_unlock(&s->lock);
}

static double now(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    assert(argc == 3);
    const int port = atoi(argv[1]);
    const char *scenario = argv[2];
    State s = {.lock = PTHREAD_MUTEX_INITIALIZER, .changed = PTHREAD_COND_INITIALIZER};
    s.view_only = !strcmp(scenario, "view-only");
    s.tight = !strcmp(scenario, "tight");
    s.expect_frames = !strcmp(scenario, "frames") || !strcmp(scenario, "password") || s.tight || s.view_only;
    vncv_callbacks callbacks = {on_connected, on_frame, on_clipboard, on_disconnected};
    s.client = vncv_create(callbacks, &s);
    assert(s.client);
    assert(!vncv_start(s.client, "", port, "", 0, -1));
    assert(!vncv_key(s.client, 'x', 1));
    assert(!vncv_start(s.client, "127.0.0.1", 0, "", 0, -1));
    for (int iteration = 0; iteration < 5; iteration++) {
        s.connected = s.frames = s.clipboard = s.disconnected = s.intentional = 0;
        s.reason[0] = 0;
        assert(vncv_start(s.client, "127.0.0.1", port, "mock-password", s.view_only, -1));
        assert(!vncv_start(s.client, "127.0.0.1", port, "", 0, -1));
        if (s.expect_frames) {
            await_state(&s, 0);
            assert(s.connected == 1);
            vncv_stop(s.client);
            vncv_wait(s.client);
            assert(s.intentional);
        } else if (!strcmp(scenario, "stall")) {
            usleep(150000);
            double started = now();
            vncv_stop(s.client);
            vncv_wait(s.client);
            assert(now() - started < 1.5);
            assert(s.intentional && !s.connected);
        } else {
            await_state(&s, 1);
            vncv_wait(s.client);
            assert(!s.intentional);
            if (!strcmp(scenario, "auth-fail")) assert(!s.connected);
        }
        assert(s.disconnected == 1);
        assert(!vncv_is_running(s.client));
    }
    vncv_stop(s.client);
    vncv_destroy(s.client);
    pthread_cond_destroy(&s.changed);
    pthread_mutex_destroy(&s.lock);
    printf("PASS: %s, five repeated sessions\n", scenario);
    return 0;
}
