#ifndef VNC_BRIDGE_H
#define VNC_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct vncv_client vncv_client;

typedef struct vncv_callbacks {
    /* All callbacks run on the connection worker. Copy borrowed strings/pixels
       synchronously before dispatching work to the main thread. */
    void (*connected)(void *context, const char *desktop_name, int width, int height);
    /* Pixels are B,G,R,X bytes: little-endian 0x00RRGGBB. The complete image is
       supplied; x/y/w/h bound the changed area. One callback per server update. */
    void (*frame)(void *context, const uint8_t *pixels, int width, int height,
                  int stride, int x, int y, int w, int h);
    /* Text is UTF-8. The bridge converts legacy Latin-1 server clipboard text. */
    void (*clipboard)(void *context, const char *utf8, size_t length);
    /* intentional is true following vncv_stop. message is never NULL. */
    void (*disconnected)(void *context, const char *message, int intentional);
} vncv_callbacks;

vncv_client *vncv_create(vncv_callbacks callbacks, void *context);
/* Lifecycle functions start/wait/destroy must be serialized by the owner.
   Returns 1 when a worker starts, 0 for invalid arguments/allocation failure or
   an existing active worker. Reuses a finished handle safely. quality -1 means
   lossless; 0...9 enables Tight JPEG at that quality. Password is copied only
   into volatile process memory, then wiped after the handshake. */
int vncv_start(vncv_client *client, const char *host, uint16_t port,
               const char *password, int view_only, int quality);
/* Thread-safe, nonblocking; safe from a callback. Cancels connect/auth/read. */
void vncv_stop(vncv_client *client);
/* Joins an existing worker. Never call wait/destroy from a worker callback. */
void vncv_wait(vncv_client *client);
void vncv_destroy(vncv_client *client);
int vncv_is_running(vncv_client *client);

/* Thread-safe queues: all RFB writes happen on the single worker. Return 1 if
   queued, 0 if disconnected/stopping, out of memory, or the queue is full.
   Key codes are X11/RFB keysyms; pointer mask uses RFB buttons (1/2/4 etc.). */
int vncv_key(vncv_client *client, uint32_t keysym, int down);
int vncv_pointer(vncv_client *client, int x, int y, int button_mask);
int vncv_clipboard(vncv_client *client, const char *utf8, size_t length);
int vncv_refresh(vncv_client *client);
int vncv_set_view_only(vncv_client *client, int view_only);

#ifdef __cplusplus
}
#endif
#endif
