#include "VNCBridge.h"
#include <rfb/rfbclient.h>
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
    int view_only, expect_frames, tight, jpeg, slow, slow_large;
    char reason[512];
} State;

static void on_connected(void *context, const char *name, int width, int height) {
    State *s = context;
    assert(name && strstr(name, "integration"));
    assert(width == (s->slow_large ? 4096 : 4) && height == (s->slow_large ? 2 : 3));
    vncv_network_rtt network;
    int has_rtt = vncv_get_network_rtt(s->client, &network);
    assert(has_rtt == network.available);
    if (has_rtt) assert(network.rtt_ms > 0 && network.observed_activity_age_ms < 1000 && !network.stale);
    pthread_mutex_lock(&s->lock);
    s->connected++;
    pthread_cond_broadcast(&s->changed);
    pthread_mutex_unlock(&s->lock);
    if (s->slow) return;
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
static int is_jpeg_pixel(const uint8_t *pixels, int stride, int x, int y, int r, int g, int b) {
    const uint8_t *p = pixels + y * stride + x * 4;
    /* The committed JPEG fixture is intentionally lossy. Check channels and
       locations with a bounded tolerance, rather than expecting raw pixels. */
    return abs((int)p[0] - b) <= 8 && abs((int)p[1] - g) <= 8 && abs((int)p[2] - r) <= 8;
}

static void on_frame(void *context, const uint8_t *pixels, int width, int height,
                     int stride, int x, int y, int w, int h) {
    State *s = context;
    pthread_mutex_lock(&s->lock);
    assert(pixels && stride == width * 4);
    assert(x >= 0 && y >= 0 && w >= 0 && h >= 0 && x + w <= width && y + h <= height);
    if (s->slow) {
        assert(width == (s->slow_large ? 4096 : 4) && height == (s->slow_large ? 2 : 3));
        assert(s->frames < 2);
        assert(is_pixel(pixels, stride, 0, 0, s->frames ? 80 : 25, s->frames ? 90 : 50, s->frames ? 100 : 75));
        assert(is_pixel(pixels, stride, width - 1, height - 1, s->frames ? 80 : 25, s->frames ? 90 : 50, s->frames ? 100 : 75));
    } else if (width == 4 && height == 3) {
        int (*check)(const uint8_t *, int, int, int, int, int, int) = s->jpeg ? is_jpeg_pixel : is_pixel;
        assert(check(pixels, stride, 0, 0, 255, 0, 0));
        assert(check(pixels, stride, 1, 0, 0, 255, 0));
        assert(check(pixels, stride, 2, 0, 0, 0, 255));
        assert(check(pixels, stride, 3, 0, 255, 255, 255));
        if (s->frames == 1) {
            assert(check(pixels, stride, 2, 1, 255, 0, 0));
            assert(check(pixels, stride, 3, 1, 0, 255, 0));
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

static void await_frames(State *s, int frames) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 8;
    pthread_mutex_lock(&s->lock);
    while (s->frames < frames) {
        if (s->disconnected || pthread_cond_timedwait(&s->changed, &s->lock, &deadline)) {
            fprintf(stderr, "Slow update failed: frames=%d wanted=%d reason=%s\n", s->frames, frames, s->reason);
            abort();
        }
    }
    pthread_mutex_unlock(&s->lock);
}

static void queue_slow_input(State *s, int toggle_view_only) {
    assert(vncv_pointer(s->client, 1, 1, 1));
    assert(vncv_pointer(s->client, 2, 1, 1));
    if (toggle_view_only) {
        assert(vncv_set_view_only(s->client, 1));
        assert(vncv_pointer(s->client, 0, 0, 1));
        assert(vncv_key(s->client, 'x', 1));
        assert(vncv_key(s->client, 'x', 0));
        assert(vncv_set_view_only(s->client, 0));
    } else {
        assert(vncv_pointer(s->client, 2, 1, 0));
        /* This following hover must not move the preceding button-up. */
        assert(vncv_pointer(s->client, 3, 1, 0));
    }
    assert(vncv_key(s->client, 'b', 1));
    assert(vncv_key(s->client, 'b', 0));
    assert(vncv_pointer(s->client, 3, 1, 4));
    assert(vncv_pointer(s->client, 3, 1, 0));
}

static rfbBool unused_read_wake(rfbClient *client) {
    (void)client;
    abort(); /* Registration/cleanup must never invoke the callback. */
}

static void verify_read_wake_registration(void) {
    for (int iteration = 0; iteration < 100; iteration++) {
        rfbClient *client = rfbGetClient(8, 3, 4);
        assert(client && client->clientData == NULL); /* Default remains off. */
        rfbClientReadWakeHook hook = { -1, unused_read_wake };
        assert(!rfbClientSetReadWakeHook(client, &hook));
        hook.descriptor = -2;
        assert(!rfbClientSetReadWakeHook(client, &hook));
        hook.descriptor = FD_SETSIZE;
        assert(!rfbClientSetReadWakeHook(client, &hook));
        hook.descriptor = 0; hook.service = NULL;
        assert(!rfbClientSetReadWakeHook(client, &hook));
        hook.service = unused_read_wake;
        assert(rfbClientSetReadWakeHook(client, &hook));
        assert(client->clientData && client->clientData->data == &hook);
        assert(rfbClientSetReadWakeHook(client, NULL));
        assert(client->clientData->data == NULL);
        rfbClientCleanup(client); /* The borrowed stack hook is never freed. */
    }
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--read-wake-registration")) {
        verify_read_wake_registration();
        puts("PASS: optional read-wake defaults/validation/borrowed registration/cleanup, 100 clients");
        return 0;
    }
    assert(argc == 3);
    const int port = atoi(argv[1]);
    const char *scenario = argv[2];
    State s = {.lock = PTHREAD_MUTEX_INITIALIZER, .changed = PTHREAD_COND_INITIALIZER};
    s.slow = !strncmp(scenario, "slow-", 5);
    s.slow_large = !strcmp(scenario, "slow-large");
    s.view_only = !strcmp(scenario, "view-only") || !strcmp(scenario, "slow-view-only");
    s.tight = !strcmp(scenario, "tight") || !strcmp(scenario, "quality-lossless");
    s.jpeg = !strcmp(scenario, "jpeg");
    int quality = -1, compression = 1, use_options = 0;
    if (!strcmp(scenario, "quality-balanced") || s.jpeg) quality = 8;
    if (!strcmp(scenario, "quality-wifi")) { quality = 8; compression = 3; use_options = 1; }
    if (!strcmp(scenario, "quality-lossless")) { compression = 3; use_options = 1; }
    if (!strcmp(scenario, "compression-min")) { quality = 8; compression = 0; use_options = 1; }
    if (!strcmp(scenario, "compression-max")) { quality = 8; compression = 9; use_options = 1; }
    s.expect_frames = !strcmp(scenario, "frames") || !strcmp(scenario, "password") || s.tight || s.jpeg || s.view_only ||
        !strcmp(scenario, "quality-balanced") || !strcmp(scenario, "quality-wifi") || use_options;
    vncv_callbacks callbacks = {on_connected, on_frame, on_clipboard, on_disconnected};
    s.client = vncv_create(callbacks, &s);
    assert(s.client);
    vncv_network_rtt network;
    assert(!vncv_get_network_rtt(s.client, &network) && !network.available);
    assert(!vncv_start(s.client, "", port, "", 0, -1));
    assert(!vncv_key(s.client, 'x', 1));
    assert(!vncv_start(s.client, "127.0.0.1", 0, "", 0, -1));
    assert(!vncv_start_with_options(s.client, "127.0.0.1", port, "", 0, 8, -1));
    assert(!vncv_start_with_options(s.client, "127.0.0.1", port, "", 0, 8, 10));
    assert(!vncv_is_running(s.client));
    int iterations = !strcmp(scenario, "rtt-idle") ? 1 : 5;
    for (int iteration = 0; iteration < iterations; iteration++) {
        s.connected = s.frames = s.clipboard = s.disconnected = s.intentional = 0;
        s.reason[0] = 0;
        int started = use_options ?
            vncv_start_with_options(s.client, "127.0.0.1", port, "mock-password", s.view_only, quality, compression) :
            vncv_start(s.client, "127.0.0.1", port, "mock-password", s.view_only, quality);
        assert(started);
        assert(!vncv_start(s.client, "127.0.0.1", port, "", 0, -1));
        if (!strcmp(scenario, "rtt-idle")) {
            await_frames(&s, 1);
            usleep(250000); /* Let the ordinary RFB messages/ACKs settle. */
            int available = vncv_get_network_rtt(s.client, &network);
            assert(available && network.available && network.rtt_ms > 0 && !network.stale);
            double deadline = now() + 7;
            while (!network.stale && now() < deadline) {
                usleep(10000);
                assert(vncv_get_network_rtt(s.client, &network));
            }
            assert(network.stale && network.observed_activity_age_ms >= 5000);
            printf("PASS: passive existing-connection TCP RTT %.0f ms; unchanged traffic becomes idle after %.0f ms\n",
                   network.rtt_ms, network.observed_activity_age_ms);
            vncv_stop(s.client); vncv_wait(s.client);
            assert(s.intentional && s.frames == 1);
        } else if (s.slow) {
            await_frames(&s, 1);
            /* The next incremental update has a header and first pixel, with
               its remaining bytes deliberately withheld for 900 ms. */
            usleep(150000);
            queue_slow_input(&s, !strcmp(scenario, "slow-toggle-view"));
            if (!strcmp(scenario, "slow-wake-storm")) {
                /* 100 wakeups in half a second must not be mistaken for
                   100 full 100ms read-timeout retries. */
                for (int wake = 0; wake < 100; wake++) {
                    assert(vncv_refresh(s.client));
                    usleep(5000);
                }
            }
            if (!strcmp(scenario, "slow-cancel")) {
                double stopping = now();
                vncv_stop(s.client); vncv_wait(s.client);
                assert(now() - stopping < 1.5);
                assert(s.intentional && s.frames == 1);
            } else if (!strcmp(scenario, "slow-drop")) {
                await_state(&s, 1); vncv_wait(s.client);
                assert(!s.intentional && s.frames == 1);
            } else {
                await_frames(&s, 2);
                assert(s.connected == 1 && s.clipboard == 1);
                vncv_stop(s.client); vncv_wait(s.client);
                assert(s.intentional);
            }
        } else if (s.expect_frames) {
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
        memset(&network, 0xff, sizeof(network));
        assert(!vncv_get_network_rtt(s.client, &network));
        assert(!network.available && network.rtt_ms == 0 && network.observed_activity_age_ms == 0 && !network.stale);
    }
    vncv_stop(s.client);
    vncv_destroy(s.client);
    pthread_cond_destroy(&s.changed);
    pthread_mutex_destroy(&s.lock);
    printf("PASS: %s, %d repeated sessions\n", scenario, iterations);
    return 0;
}
