/* Deterministic worker scheduling + real opt-in LibVNCClient wire behavior.
 * No remote host, credentials, app/UI, or wall-clock pacing sleeps. */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <rfb/rfbclient.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static double fake_now = 100;
static int incremental_sends, full_sends, key_sends, pointer_sends;
static int fake_clock_gettime(clockid_t which, struct timespec *value) {
    assert(which == CLOCK_MONOTONIC);
    value->tv_sec = (time_t)fake_now;
    value->tv_nsec = (long)((fake_now - value->tv_sec) * 1e9);
    return 0;
}
static rfbBool fake_incremental(rfbClient *client) { assert(client); incremental_sends++; return TRUE; }
static rfbBool fake_full(rfbClient *client, int x, int y, int w, int h, rfbBool incremental) {
    assert(client && !x && !y && w == 4 && h == 3 && !incremental);
    full_sends++; return TRUE;
}
static rfbBool fake_key(rfbClient *client, uint32_t symbol, rfbBool down) {
    assert(client); (void)symbol; (void)down; key_sends++; return TRUE;
}
static rfbBool fake_pointer(rfbClient *client, int x, int y, int mask) {
    assert(client); (void)x; (void)y; (void)mask; pointer_sends++; return TRUE;
}
#define clock_gettime fake_clock_gettime
#define SendIncrementalFramebufferUpdateRequest fake_incremental
#define SendFramebufferUpdateRequest fake_full
#define SendKeyEvent fake_key
#define SendPointerEvent fake_pointer
#include "../native/VNCBridge.c"
#undef clock_gettime
#undef SendIncrementalFramebufferUpdateRequest
#undef SendFramebufferUpdateRequest
#undef SendKeyEvent
#undef SendPointerEvent

static void check_schedule(void) {
    vncv_callbacks callbacks = {0};
    vncv_client *client = vncv_create(callbacks, NULL);
    assert(client && !vncv_set_update_interval(NULL, 1));
    assert(!vncv_set_update_interval(client, 2000));
    client->running = 1;
    rfbClient *rfb = rfbGetClient(8, 3, 4);
    assert(rfb); rfb->width = 4; rfb->height = 3;
    rfbClientSetClientData(rfb, &client_tag, client);
    assert(should_request_update(rfb)); /* Normal path asks stock lib to send. */
    assert(!client->update_pending && !incremental_sends);
    assert(vncv_set_update_interval(client, 2000));
    assert(process_commands(client, rfb));
    assert(!should_request_update(rfb));
    assert(client->update_pending && client->update_due == 102);
    fake_now = 101.999;
    assert(send_scheduled_update(client, rfb) && !incremental_sends);
    assert(vncv_set_update_interval(client, 2000));
    assert(process_commands(client, rfb) && client->update_due == 102); /* No starvation. */
    fake_now = 102;
    assert(send_scheduled_update(client, rfb) && incremental_sends == 1);
    assert(!client->update_pending);
    assert(send_scheduled_update(client, rfb) && incremental_sends == 1); /* Only one in flight. */
    assert(!should_request_update(rfb) && client->update_due == 104);
    assert(vncv_refresh(client));
    assert(process_commands(client, rfb));
    assert(full_sends == 1 && !client->update_pending); /* Full promotion bypass. */
    assert(!should_request_update(rfb));
    assert(vncv_set_update_interval(client, 0));
    assert(process_commands(client, rfb));
    assert(send_scheduled_update(client, rfb) && incremental_sends == 2);
    assert(should_request_update(rfb) && !client->update_pending);
    /* Product preview cadence, tested without a ten-second wall-clock wait. */
    assert(vncv_set_update_interval(client, 10000));
    assert(process_commands(client, rfb) && !should_request_update(rfb));
    assert(client->update_due == 112);
    fake_now = 111.999;
    assert(send_scheduled_update(client, rfb) && incremental_sends == 2);
    fake_now = 112;
    assert(send_scheduled_update(client, rfb) && incremental_sends == 3);
    assert(vncv_set_update_interval(client, UINT32_MAX));
    assert(process_commands(client, rfb) && !should_request_update(rfb));
    assert(client->update_due > fake_now + 4294967 && client->update_due < fake_now + 4294968);
    assert(vncv_set_view_only(client, 1));
    assert(vncv_key(client, 'x', 1) && vncv_pointer(client, 1, 1, 1));
    assert(process_commands(client, rfb));
    assert(!key_sends && !pointer_sends); /* Pacing never opens input. */
    vncv_stop(client);
    assert(!vncv_set_update_interval(client, 0));
    rfbClientCleanup(rfb);
    client->running = 0;
    vncv_destroy(client);
}

static int allow_auto, hook_calls;
static rfbBool auto_hook(rfbClient *client) { assert(client); hook_calls++; return allow_auto; }
static void check_wire_hook(void) {
    assert(!rfbClientSetUpdateRequestHook(NULL, NULL));
    for (int iteration = 0; iteration < 100; iteration++) {
        rfbClient *client = rfbGetClient(8, 3, 4);
        assert(client && !client->clientData);
        assert(rfbClientSetUpdateRequestHook(client, NULL) && !client->clientData);
        rfbClientUpdateRequestHook invalid = {NULL};
        assert(!rfbClientSetUpdateRequestHook(client, &invalid));
        int pair[2]; assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, pair));
        client->sock = pair[0];
        /* Fixture has no handshake; initialize its RFB 3.x request support. */
        client->supportedMessages.client2server[0] |= 1 << rfbFramebufferUpdateRequest;
        struct timeval bound = {1, 0};
        assert(!setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &bound, sizeof(bound)));
        client->updateRect.x = client->updateRect.y = 0;
        client->updateRect.w = 4; client->updateRect.h = 3;
        const unsigned char empty_update[] = {0, 0, 0, 0};
        const unsigned char expected[] = {3, 1, 0, 0, 0, 0, 0, 4, 0, 3};
        unsigned char request[10];
        assert(write(pair[1], empty_update, 4) == 4);
        assert(HandleRFBServerMessage(client)); /* Default off, stock wire bytes. */
        assert(read(pair[1], request, 10) == 10 && !memcmp(request, expected, 10));
        rfbClientUpdateRequestHook hook = {auto_hook};
        assert(rfbClientSetUpdateRequestHook(client, &hook));
        allow_auto = 1; hook_calls = 0;
        assert(write(pair[1], empty_update, 4) == 4 && HandleRFBServerMessage(client));
        assert(hook_calls == 1 && read(pair[1], request, 10) == 10 && !memcmp(request, expected, 10));
        allow_auto = 0;
        assert(write(pair[1], empty_update, 4) == 4 && HandleRFBServerMessage(client));
        assert(hook_calls == 2);
        assert(recv(pair[1], request, 10, MSG_DONTWAIT) < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));
        assert(SendFramebufferUpdateRequest(client, 0, 0, 4, 3, FALSE));
        assert(read(pair[1], request, 10) == 10 && request[0] == 3 && !request[1]);
        assert(rfbClientSetUpdateRequestHook(client, NULL));
        assert(write(pair[1], empty_update, 4) == 4 && HandleRFBServerMessage(client));
        assert(read(pair[1], request, 10) == 10 && !memcmp(request, expected, 10));
        close(pair[1]);
        rfbClientCleanup(client); /* Borrowed stack hook never freed. */
    }
}
int main(void) {
    alarm(15);
    check_schedule(); check_wire_hook();
    puts("PASS: deterministic pacing/deadlines/control/input isolation and 100 real wire hook clients");
    return 0;
}
