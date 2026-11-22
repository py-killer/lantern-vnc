#include "VNCBridge.h"
#include <rfb/rfbclient.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h>
#ifdef __APPLE__
#include <netinet/tcp_fsm.h>
#endif
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_COMMANDS 8192
#define MAX_CLIPBOARD (1024 * 1024)
#define MAX_FRAME_BYTES ((size_t)256 * 1024 * 1024)
#define CONNECT_SECONDS 8

typedef enum { CMD_KEY, CMD_POINTER, CMD_CLIPBOARD, CMD_REFRESH, CMD_VIEW_ONLY, CMD_UPDATE_INTERVAL } command_type;
typedef struct command {
    command_type type;
    uint32_t key;
    int a, b, c;
    int pointer_motion;
    char *text;
    size_t length;
    struct command *next;
} command;

struct vncv_client {
    pthread_mutex_t mutex;
    pthread_t worker;
    int joinable, running, stop_requested;
    int wake[2];
    /* A duplicate, never the rfbClient descriptor. Protected by mutex, so a
       concurrent stop cannot touch a freed client or a reused descriptor. */
    int shutdown_fd;
    /* Protected by mutex. Kernel counters provide observed activity only;
       TCP_CONNECTION_INFO does not expose an RTT sample timestamp. */
    int network_ready, network_observed;
    uint64_t network_txpackets, network_rxpackets, network_txbytes, network_rxbytes;
    double network_activity_at;
    vncv_callbacks callbacks;
    void *context;
    char *host, *password;
    uint16_t port;
    int initial_view_only, quality, compression_level;
    command *head, *tail;
    size_t queued;
    int enqueued_pointer_mask, enqueued_pointer_known;
    /* Worker-owned below. */
    uint8_t *framebuffer;
    int dirty, left, top, right, bottom;
    int view_only, pointer_x, pointer_y, pointer_mask;
    uint32_t pressed[256];
    size_t pressed_count;
    uint32_t update_interval_ms;
    int update_pending;
    double update_due;
    char last_error[768];
};

static _Thread_local vncv_client *logging_client;
static pthread_once_t library_once = PTHREAD_ONCE_INIT;
static char client_tag;

static void wipe_free(char **value) {
    if (!*value) return;
    volatile unsigned char *p = (volatile unsigned char *)*value;
    size_t n = strlen(*value);
    while (n--) *p++ = 0;
    free(*value);
    *value = NULL;
}

static void set_error(vncv_client *c, const char *format, ...) {
    va_list args;
    va_start(args, format);
    vsnprintf(c->last_error, sizeof(c->last_error), format, args);
    va_end(args);
    size_t n = strlen(c->last_error);
    while (n && (c->last_error[n - 1] == '\n' || c->last_error[n - 1] == '\r')) c->last_error[--n] = 0;
}

static void capture_log(int error, const char *format, va_list args) {
    vncv_client *c = logging_client;
    if (!c) return;
    char line[768];
    vsnprintf(line, sizeof(line), format, args);
    /* Keep actual failures, rather than overwriting them with informational
       protocol/encoding chatter. Never print credentials or connection logs. */
    if (error || strstr(line, "failed") || strstr(line, "Failed") ||
        strstr(line, "failure") || strstr(line, "denied") ||
        strstr(line, "timed out") || strstr(line, "too large") ||
        strstr(line, "closed connection") || strstr(line, "unsupported") ||
        strstr(line, "Unsupported")) set_error(c, "%s", line);
}

static void library_log(const char *format, ...) {
    va_list args; va_start(args, format); capture_log(0, format, args); va_end(args);
}
static void library_error(const char *format, ...) {
    va_list args; va_start(args, format); capture_log(1, format, args); va_end(args);
}
static void initialize_library(void) {
    rfbClientLog = library_log;
    rfbClientErr = library_error;
    /* LibVNCClient uses write(2), which must not terminate the app if the
       server disconnects while an input event is being sent. */
    signal(SIGPIPE, SIG_IGN);
}

static int stopped(vncv_client *c) {
    pthread_mutex_lock(&c->mutex);
    int result = c->stop_requested;
    pthread_mutex_unlock(&c->mutex);
    return result;
}
static void wake_worker(vncv_client *c) {
    unsigned char byte = 1;
    ssize_t ignored = write(c->wake[1], &byte, 1);
    (void)ignored;
}
static void drain_wake(vncv_client *c) {
    unsigned char bytes[256];
    while (read(c->wake[0], bytes, sizeof(bytes)) > 0) {}
}
static void free_command(command *cmd) {
    if (!cmd) return;
    free(cmd->text);
    free(cmd);
}
static void clear_commands_locked(vncv_client *c) {
    while (c->head) {
        command *next = c->head->next;
        free_command(c->head);
        c->head = next;
    }
    c->tail = NULL;
    c->queued = 0;
}
static int enqueue(vncv_client *c, command *cmd) {
    if (!c || !cmd) { free_command(cmd); return 0; }
    pthread_mutex_lock(&c->mutex);
    if (!c->running || c->stop_requested || c->queued >= MAX_COMMANDS) {
        pthread_mutex_unlock(&c->mutex); free_command(cmd); return 0;
    }
    if (cmd->type == CMD_POINTER) {
        cmd->pointer_motion = c->enqueued_pointer_known && c->enqueued_pointer_mask == cmd->c;
        c->enqueued_pointer_mask = cmd->c;
        c->enqueued_pointer_known = 1;
    } else if (cmd->type == CMD_VIEW_ONLY) {
        /* A view-only transition may release/suppress remote buttons. Keep
           the next pointer event intact even if its mask matches old input. */
        c->enqueued_pointer_known = 0;
    }
    /* Preserve both the mask and coordinates of button-down/up nodes. */
    if (cmd->type == CMD_POINTER && cmd->pointer_motion && c->tail &&
        c->tail->type == CMD_POINTER && c->tail->pointer_motion && c->tail->c == cmd->c) {
        c->tail->a = cmd->a; c->tail->b = cmd->b;
        pthread_mutex_unlock(&c->mutex); free_command(cmd); wake_worker(c); return 1;
    }
    if (c->tail) c->tail->next = cmd; else c->head = cmd;
    c->tail = cmd;
    c->queued++;
    pthread_mutex_unlock(&c->mutex);
    wake_worker(c);
    return 1;
}
static command *take_commands(vncv_client *c) {
    pthread_mutex_lock(&c->mutex);
    command *head = c->head;
    c->head = c->tail = NULL;
    c->queued = 0;
    pthread_mutex_unlock(&c->mutex);
    return head;
}
static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static void reset_network_rtt_locked(vncv_client *c) {
    c->network_ready = c->network_observed = 0;
    c->network_txpackets = c->network_rxpackets = 0;
    c->network_txbytes = c->network_rxbytes = 0;
    c->network_activity_at = 0;
}

static int network_rtt_locked(vncv_client *c, vncv_network_rtt *snapshot) {
    memset(snapshot, 0, sizeof(*snapshot));
    if (!c->network_ready || !c->running || c->stop_requested || c->shutdown_fd < 0) return 0;
#if defined(__APPLE__) && defined(TCP_CONNECTION_INFO)
    struct tcp_connection_info info;
    memset(&info, 0, sizeof(info));
    socklen_t length = sizeof(info);
    size_t required = offsetof(struct tcp_connection_info, tcpi_rxbytes) + sizeof(info.tcpi_rxbytes);
    if (getsockopt(c->shutdown_fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &length) != 0 ||
        length < required || info.tcpi_state != TCPS_ESTABLISHED) return 0;
    double now = monotonic_seconds();
    if (c->network_observed &&
        (info.tcpi_txpackets != c->network_txpackets || info.tcpi_rxpackets != c->network_rxpackets ||
         info.tcpi_txbytes != c->network_txbytes || info.tcpi_rxbytes != c->network_rxbytes)) {
        c->network_activity_at = now;
    }
    c->network_observed = 1;
    c->network_txpackets = info.tcpi_txpackets;
    c->network_rxpackets = info.tcpi_rxpackets;
    c->network_txbytes = info.tcpi_txbytes;
    c->network_rxbytes = info.tcpi_rxbytes;
    /* Apple's SDK netinet/tcp.h and XNU tcp_connection_fill_info specify ms.
       A zero estimate is ambiguous (including no sample); never invent 0 ms. */
    if (info.tcpi_srtt == 0) return 0;
    snapshot->rtt_ms = (double)info.tcpi_srtt;
    snapshot->observed_activity_age_ms = (now > c->network_activity_at ? now - c->network_activity_at : 0) * 1000.0;
    snapshot->available = 1;
    snapshot->stale = snapshot->observed_activity_age_ms >= 5000.0;
    return 1;
#else
    return 0;
#endif
}

static int connect_socket(vncv_client *c) {
    struct addrinfo hints = {0}, *addresses = NULL;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char service[8];
    snprintf(service, sizeof(service), "%u", c->port);
    double deadline = monotonic_seconds() + CONNECT_SECONDS;
    int gai = getaddrinfo(c->host, service, &hints, &addresses);
    if (gai) { set_error(c, "Cannot resolve %s: %s", c->host, gai_strerror(gai)); return -1; }
    int result = -1, last_errno = ECONNREFUSED;
    for (struct addrinfo *addr = addresses; addr && !stopped(c); addr = addr->ai_next) {
        if (monotonic_seconds() >= deadline) { last_errno = ETIMEDOUT; break; }
        int fd = socket(addr->ai_family, addr->ai_socktype, addr->ai_protocol);
        if (fd < 0) { last_errno = errno; continue; }
        if (fd >= FD_SETSIZE) { last_errno = EMFILE; close(fd); continue; }
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
#ifdef SO_NOSIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) < 0) {
            last_errno = errno; close(fd); continue;
        }
        int rc = connect(fd, addr->ai_addr, addr->ai_addrlen);
        if (rc < 0 && errno != EINPROGRESS && errno != EWOULDBLOCK) {
            last_errno = errno; close(fd); continue;
        }
        while (rc < 0 && !stopped(c)) {
            if (monotonic_seconds() >= deadline) { last_errno = ETIMEDOUT; break; }
            fd_set writefds;
            FD_ZERO(&writefds); FD_SET(fd, &writefds);
            struct timeval timeout = {0, 100000};
            int ready = select(fd + 1, NULL, &writefds, NULL, &timeout);
            if (ready < 0 && errno == EINTR) continue;
            if (ready < 0) { last_errno = errno; break; }
            if (!ready) continue;
            int socket_error = 0; socklen_t len = sizeof(socket_error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error, &len) < 0) socket_error = errno;
            if (socket_error) { last_errno = socket_error; break; }
            rc = 0;
        }
        if (rc == 0 && !stopped(c)) { result = fd; break; }
        close(fd);
    }
    freeaddrinfo(addresses);
    if (result < 0 && !stopped(c)) {
        if (last_errno == ETIMEDOUT) set_error(c, "Connection to %s:%u timed out. Check the server and network.", c->host, c->port);
        else set_error(c, "Cannot connect to %s:%u: %s", c->host, c->port, strerror(last_errno));
    }
    return result;
}

static vncv_client *owner(rfbClient *rfb) {
    return rfbClientGetClientData(rfb, &client_tag);
}
static char *get_password(rfbClient *rfb) {
    vncv_client *c = owner(rfb);
    /* LibVNCClient returns early without freeing an empty password string. */
    char *result = c->password && c->password[0] ? strdup(c->password) : NULL;
    wipe_free(&c->password);
    return result;
}
static rfbBool allocate_framebuffer(rfbClient *rfb) {
    vncv_client *c = owner(rfb);
    if (rfb->width <= 0 || rfb->height <= 0 || rfb->width > 16384 || rfb->height > 16384 ||
        (size_t)rfb->width * (size_t)rfb->height > MAX_FRAME_BYTES / 4) {
        set_error(c, "The remote desktop exceeds the supported framebuffer limit (256 MB). ");
        return FALSE;
    }
    size_t size = (size_t)rfb->width * (size_t)rfb->height * 4;
    uint8_t *pixels = calloc(1, size);
    if (!pixels) { set_error(c, "Not enough memory for the remote desktop."); return FALSE; }
    free(c->framebuffer);
    c->framebuffer = pixels;
    rfb->frameBuffer = pixels;
    c->dirty = 1; c->left = c->top = 0; c->right = rfb->width; c->bottom = rfb->height;
    return TRUE;
}
static void frame_rectangle(rfbClient *rfb, int x, int y, int w, int h) {
    vncv_client *c = owner(rfb);
    if (w <= 0 || h <= 0) return;
    if (!c->dirty) { c->left = x; c->top = y; c->right = x + w; c->bottom = y + h; c->dirty = 1; }
    else {
        if (x < c->left) c->left = x;
        if (y < c->top) c->top = y;
        if (x + w > c->right) c->right = x + w;
        if (y + h > c->bottom) c->bottom = y + h;
    }
}
static void frame_finished(rfbClient *rfb) {
    vncv_client *c = owner(rfb);
    if (c->dirty && c->callbacks.frame && !stopped(c)) {
        c->callbacks.frame(c->context, c->framebuffer, rfb->width, rfb->height,
                           rfb->width * 4, c->left, c->top, c->right - c->left, c->bottom - c->top);
    }
    c->dirty = 0;
}
/* The library calls this just before its normal automatic request. Interval 0
   returns TRUE so the original send stays in exactly the same protocol slot,
   before FinishedFrameBufferUpdate. Background pacing changes no server flags. */
static rfbBool should_request_update(rfbClient *rfb) {
    vncv_client *c = owner(rfb);
    if (!c->update_interval_ms) {
        c->update_pending = 0;
        c->update_due = 0;
        return TRUE;
    }
    c->update_pending = 1;
    c->update_due = monotonic_seconds() + (double)c->update_interval_ms / 1000.0;
    return FALSE;
}
static int send_scheduled_update(vncv_client *c, rfbClient *rfb) {
    if (!c->update_pending || monotonic_seconds() < c->update_due) return 1;
    c->update_pending = 0;
    c->update_due = 0;
    return SendIncrementalFramebufferUpdateRequest(rfb);
}
static void clipboard_utf8(rfbClient *rfb, const char *text, int length) {
    vncv_client *c = owner(rfb);
    if (length < 0 || length > MAX_CLIPBOARD || (!text && length)) return;
    if (c->callbacks.clipboard && !stopped(c)) c->callbacks.clipboard(c->context, text ? text : "", (size_t)length);
}
static void clipboard_latin1(rfbClient *rfb, const char *text, int length) {
    vncv_client *c = owner(rfb);
    if (!c->callbacks.clipboard || length < 0 || length > MAX_CLIPBOARD || (!text && length) || stopped(c)) return;
    char *utf8 = malloc((size_t)length * 2 + 1);
    if (!utf8) return;
    size_t out = 0;
    for (int i = 0; i < length; i++) {
        unsigned char ch = (unsigned char)text[i];
        if (ch < 128) utf8[out++] = (char)ch;
        else { utf8[out++] = (char)(0xc0 | (ch >> 6)); utf8[out++] = (char)(0x80 | (ch & 63)); }
    }
    utf8[out] = 0;
    c->callbacks.clipboard(c->context, utf8, out);
    free(utf8);
}
/* Legacy RFB clipboard is Latin-1. Replace unsupported Unicode codepoints
   with '?' for servers that do not negotiate the UTF-8 clipboard extension. */
static char *to_latin1(const char *utf8, size_t length, int *out_length) {
    char *result = malloc(length + 1);
    if (!result) return NULL;
    size_t out = 0;
    for (size_t i = 0; i < length;) {
        unsigned char ch = (unsigned char)utf8[i++];
        if (ch < 128) { result[out++] = (char)ch; continue; }
        if ((ch == 0xc2 || ch == 0xc3) && i < length && ((unsigned char)utf8[i] & 0xc0) == 0x80) {
            result[out++] = (char)(((ch & 3) << 6) | ((unsigned char)utf8[i++] & 63)); continue;
        }
        result[out++] = '?';
        while (i < length && ((unsigned char)utf8[i] & 0xc0) == 0x80) i++;
    }
    result[out] = 0;
    *out_length = (int)out;
    return result;
}
static void track_key(vncv_client *c, uint32_t key, int down) {
    size_t i = 0;
    while (i < c->pressed_count && c->pressed[i] != key) i++;
    if (down && i == c->pressed_count && i < 256) c->pressed[c->pressed_count++] = key;
    if (!down && i < c->pressed_count) c->pressed[i] = c->pressed[--c->pressed_count];
}
static int release_inputs(vncv_client *c, rfbClient *rfb) {
    while (c->pressed_count) if (!SendKeyEvent(rfb, c->pressed[--c->pressed_count], FALSE)) return 0;
    if (c->pointer_mask) {
        c->pointer_mask = 0;
        if (!SendPointerEvent(rfb, c->pointer_x, c->pointer_y, 0)) return 0;
    }
    return 1;
}
static int process_commands(vncv_client *c, rfbClient *rfb) {
    command *cmd = take_commands(c);
    int okay = 1;
    while (cmd) {
        command *next = cmd->next;
        if (okay && !stopped(c)) switch (cmd->type) {
            case CMD_KEY:
                if (!c->view_only) { okay = SendKeyEvent(rfb, cmd->key, cmd->a ? TRUE : FALSE); if (okay) track_key(c, cmd->key, cmd->a); }
                break;
            case CMD_POINTER:
                if (!c->view_only) {
                    int x = cmd->a < 0 ? 0 : cmd->a >= rfb->width ? rfb->width - 1 : cmd->a;
                    int y = cmd->b < 0 ? 0 : cmd->b >= rfb->height ? rfb->height - 1 : cmd->b;
                    okay = SendPointerEvent(rfb, x, y, cmd->c & 255);
                    if (okay) { c->pointer_x = x; c->pointer_y = y; c->pointer_mask = cmd->c & 255; }
                }
                break;
            case CMD_CLIPBOARD:
                if (!c->view_only) {
#ifdef LIBVNCSERVER_HAVE_LIBZ
                    if (rfb->extendedClipboardServerCapabilities) okay = SendClientCutTextUTF8(rfb, cmd->text, (int)cmd->length);
                    else
#endif
                    {
                        int length = 0;
                        char *text = to_latin1(cmd->text, cmd->length, &length);
                        okay = text ? SendClientCutText(rfb, text, length) : 0;
                        free(text);
                    }
                }
                break;
            case CMD_REFRESH:
                okay = SendFramebufferUpdateRequest(rfb, 0, 0, rfb->width, rfb->height, FALSE);
                if (okay) { c->update_pending = 0; c->update_due = 0; }
                break;
            case CMD_VIEW_ONLY:
                if (cmd->a && !c->view_only) okay = release_inputs(c, rfb);
                c->view_only = cmd->a != 0;
                rfb->appData.viewOnly = c->view_only;
                break;
            case CMD_UPDATE_INTERVAL:
                if (c->update_interval_ms != cmd->key) {
                    c->update_interval_ms = cmd->key;
                    if (c->update_pending)
                        c->update_due = monotonic_seconds() + (double)cmd->key / 1000.0;
                }
                break;
        }
        free_command(cmd);
        cmd = next;
    }
    return okay;
}

/* Invoked by LibVNCClient only on this connection's reader thread while a
   fragmented server message is waiting for more bytes. Never parse/read a
   second server message here: service only our ordered outgoing queue. */
static rfbBool service_input_during_read(rfbClient *rfb) {
    vncv_client *c = owner(rfb);
    drain_wake(c);
    if (stopped(c)) return FALSE;
    if (!process_commands(c, rfb)) {
        if (!c->last_error[0]) set_error(c, "The connection closed while sending input.");
        return FALSE;
    }
    return stopped(c) ? FALSE : TRUE;
}

static void *connection_worker(void *argument) {
    vncv_client *c = argument;
    logging_client = c;
    rfbClient *rfb = NULL;
    rfbClientReadWakeHook read_wake = { c->wake[0], service_input_during_read };
    rfbClientUpdateRequestHook update_hook = { should_request_update };
    int fd = connect_socket(c);
    if (fd < 0) goto finished;
    rfb = rfbGetClient(8, 3, 4);
    if (!rfb) { close(fd); set_error(c, "Unable to create a VNC client."); goto finished; }
    rfbClientSetClientData(rfb, &client_tag, c);
    if (owner(rfb) != c) { close(fd); set_error(c, "Unable to allocate VNC connection state."); goto cleanup; }
    free(rfb->serverHost);
    rfb->serverHost = strdup(c->host);
    if (!rfb->serverHost) { close(fd); set_error(c, "Not enough memory for the connection."); goto cleanup; }
    rfb->serverPort = c->port;
    rfb->sock = fd;
    /* The socket was connected above so cancellation is available throughout
       authentication. listenSpecified tells rfbInitClient to reuse it. */
    rfb->listenSpecified = TRUE;
    rfb->connectTimeout = CONNECT_SECONDS;
    rfb->readTimeout = CONNECT_SECONDS;
    rfb->format.bitsPerPixel = 32;
    rfb->format.depth = 24;
    rfb->format.bigEndian = FALSE;
    rfb->format.trueColour = TRUE;
    rfb->format.redMax = rfb->format.greenMax = rfb->format.blueMax = 255;
    rfb->format.redShift = 16;
    rfb->format.greenShift = 8;
    rfb->format.blueShift = 0;
    rfb->appData.shareDesktop = TRUE;
    rfb->appData.viewOnly = c->initial_view_only;
    rfb->appData.compressLevel = c->compression_level;
    rfb->appData.qualityLevel = c->quality;
    rfb->appData.enableJPEG = c->quality >= 0;
    rfb->appData.encodingsString = "tight zrle copyrect hextile zlib corre rre raw";
    rfb->appData.useRemoteCursor = FALSE;
    rfb->canHandleNewFBSize = TRUE;
    rfb->GetPassword = get_password;
    rfb->MallocFrameBuffer = allocate_framebuffer;
    rfb->GotFrameBufferUpdate = frame_rectangle;
    rfb->FinishedFrameBufferUpdate = frame_finished;
    rfb->GotXCutText = clipboard_latin1;
    rfb->GotXCutTextUTF8 = clipboard_utf8;
    pthread_mutex_lock(&c->mutex);
    c->shutdown_fd = dup(fd);
    if (c->shutdown_fd >= 0) fcntl(c->shutdown_fd, F_SETFD, FD_CLOEXEC);
    int cancelled = c->stop_requested;
    pthread_mutex_unlock(&c->mutex);
    if (cancelled) goto cleanup;
    if (c->shutdown_fd < 0) { set_error(c, "Unable to initialize connection cancellation."); goto cleanup; }
    if (!rfbInitClient(rfb, NULL, NULL)) {
        /* rfbInitClient has ALREADY freed the client on failure. Its custom
           framebuffer is ours, and is reclaimed separately below. */
        rfb = NULL;
        if (!c->last_error[0]) set_error(c, "VNC connection failed. Check the password and TightVNC settings.");
        goto cleanup;
    }
    wipe_free(&c->password);
    c->view_only = c->initial_view_only;
    c->last_error[0] = 0;
    /* Handshake/authentication must finish before any queued input is sent. */
    if (!rfbClientSetReadWakeHook(rfb, &read_wake)) {
        set_error(c, "Unable to initialize responsive input servicing.");
        goto cleanup;
    }
    if (!rfbClientSetUpdateRequestHook(rfb, &update_hook)) {
        set_error(c, "Unable to initialize preview update pacing.");
        goto cleanup;
    }
    pthread_mutex_lock(&c->mutex);
    c->network_ready = 1;
    c->network_activity_at = monotonic_seconds();
    vncv_network_rtt initial_network_rtt;
    network_rtt_locked(c, &initial_network_rtt);
    pthread_mutex_unlock(&c->mutex);
    if (!stopped(c) && c->callbacks.connected) c->callbacks.connected(c->context, rfb->desktopName ? rfb->desktopName : "VNC desktop", rfb->width, rfb->height);
    while (!stopped(c)) {
        if (!process_commands(c, rfb)) { if (!c->last_error[0]) set_error(c, "The connection closed while sending input."); break; }
        if (stopped(c)) break;
        if (!send_scheduled_update(c, rfb)) { if (!c->last_error[0]) set_error(c, "The connection closed while requesting an update."); break; }
        int ready = rfb->buffered > 0;
        if (!ready) {
            fd_set readfds;
            FD_ZERO(&readfds); FD_SET(rfb->sock, &readfds); FD_SET(c->wake[0], &readfds);
            int maxfd = rfb->sock > c->wake[0] ? rfb->sock : c->wake[0];
            struct timeval timeout = {0, 250000};
            if (c->update_pending) {
                double remaining = c->update_due - monotonic_seconds();
                if (remaining < 0) remaining = 0;
                if (remaining < 0.25) timeout.tv_usec = (long)(remaining * 1000000.0) + 1;
            }
            int count = select(maxfd + 1, &readfds, NULL, NULL, &timeout);
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) { set_error(c, "Network wait failed: %s", strerror(errno)); break; }
            if (FD_ISSET(c->wake[0], &readfds)) drain_wake(c);
            ready = count > 0 && FD_ISSET(rfb->sock, &readfds);
        }
        if (ready && !stopped(c) && !HandleRFBServerMessage(rfb)) {
            if (!c->last_error[0]) set_error(c, "The VNC server disconnected.");
            break;
        }
    }
cleanup:
    pthread_mutex_lock(&c->mutex);
    reset_network_rtt_locked(c);
    if (c->shutdown_fd >= 0) { close(c->shutdown_fd); c->shutdown_fd = -1; }
    pthread_mutex_unlock(&c->mutex);
    if (rfb) {
        rfbClientSetUpdateRequestHook(rfb, NULL);
        rfbClientSetReadWakeHook(rfb, NULL);
        rfbClientCleanup(rfb);
    }
    free(c->framebuffer); c->framebuffer = NULL;
finished:
    wipe_free(&c->password);
    int intentional = stopped(c);
    if (c->callbacks.disconnected) c->callbacks.disconnected(c->context,
        intentional ? "Disconnected" : c->last_error[0] ? c->last_error : "The VNC connection ended.", intentional);
    logging_client = NULL;
    pthread_mutex_lock(&c->mutex);
    clear_commands_locked(c);
    c->running = 0;
    pthread_mutex_unlock(&c->mutex);
    return NULL;
}

vncv_client *vncv_create(vncv_callbacks callbacks, void *context) {
    pthread_once(&library_once, initialize_library);
    vncv_client *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->shutdown_fd = -1;
    if (pthread_mutex_init(&c->mutex, NULL)) { free(c); return NULL; }
    if (pipe(c->wake)) { pthread_mutex_destroy(&c->mutex); free(c); return NULL; }
    if (c->wake[0] >= FD_SETSIZE || c->wake[1] >= FD_SETSIZE) {
        close(c->wake[0]); close(c->wake[1]);
        pthread_mutex_destroy(&c->mutex); free(c); return NULL;
    }
    for (int i = 0; i < 2; i++) {
        fcntl(c->wake[i], F_SETFL, fcntl(c->wake[i], F_GETFL, 0) | O_NONBLOCK);
        fcntl(c->wake[i], F_SETFD, FD_CLOEXEC);
    }
    c->callbacks = callbacks;
    c->context = context;
    return c;
}
int vncv_start(vncv_client *c, const char *host, uint16_t port, const char *password, int view_only, int quality) {
    return vncv_start_with_options(c, host, port, password, view_only, quality, 1);
}
int vncv_start_with_options(vncv_client *c, const char *host, uint16_t port, const char *password,
                            int view_only, int quality, int compression_level) {
    if (!c || !host || !host[0] || strlen(host) > 253 || !port || quality < -1 || quality > 9 ||
        compression_level < 0 || compression_level > 9) return 0;
    for (const unsigned char *p = (const unsigned char *)host; *p; p++) if (*p <= 32 || *p == 127) return 0;
    pthread_mutex_lock(&c->mutex);
    int running = c->running;
    pthread_mutex_unlock(&c->mutex);
    if (running) return 0;
    vncv_wait(c);
    free(c->host); c->host = strdup(host);
    wipe_free(&c->password);
    /* Classic VNC authentication uses the first eight bytes. Keeping just
       those bytes also avoids retaining a truncated password suffix. */
    c->password = strndup(password ? password : "", 8);
    if (!c->host || !c->password) { wipe_free(&c->password); return 0; }
    c->port = port; c->initial_view_only = view_only != 0; c->quality = quality;
    c->compression_level = compression_level;
    c->last_error[0] = 0;
    c->dirty = 0; c->pressed_count = 0; c->pointer_mask = 0;
    c->update_interval_ms = 0; c->update_pending = 0; c->update_due = 0;
    drain_wake(c);
    pthread_mutex_lock(&c->mutex);
    clear_commands_locked(c);
    c->stop_requested = 0; c->running = 1;
    reset_network_rtt_locked(c);
    c->enqueued_pointer_mask = 0; c->enqueued_pointer_known = 1;
    int err = pthread_create(&c->worker, NULL, connection_worker, c);
    if (err) { c->running = 0; pthread_mutex_unlock(&c->mutex); wipe_free(&c->password); return 0; }
    c->joinable = 1;
    pthread_mutex_unlock(&c->mutex);
    return 1;
}
void vncv_stop(vncv_client *c) {
    if (!c) return;
    pthread_mutex_lock(&c->mutex);
    c->stop_requested = 1;
    reset_network_rtt_locked(c);
    if (c->shutdown_fd >= 0) shutdown(c->shutdown_fd, SHUT_RDWR);
    pthread_mutex_unlock(&c->mutex);
    wake_worker(c);
}
void vncv_wait(vncv_client *c) {
    if (!c) return;
    pthread_mutex_lock(&c->mutex);
    int joinable = c->joinable;
    pthread_t worker = c->worker;
    pthread_mutex_unlock(&c->mutex);
    if (!joinable || pthread_equal(pthread_self(), worker)) return;
    pthread_join(worker, NULL);
    pthread_mutex_lock(&c->mutex); c->joinable = 0; pthread_mutex_unlock(&c->mutex);
}
void vncv_destroy(vncv_client *c) {
    if (!c) return;
    vncv_stop(c);
    /* Explicit API contract excludes destroy inside a callback. Refuse to
       free live worker state even if a caller violates that contract. */
    if (c->joinable && pthread_equal(pthread_self(), c->worker)) return;
    vncv_wait(c);
    pthread_mutex_lock(&c->mutex); clear_commands_locked(c); pthread_mutex_unlock(&c->mutex);
    close(c->wake[0]); close(c->wake[1]);
    free(c->host); wipe_free(&c->password);
    pthread_mutex_destroy(&c->mutex); free(c);
}
int vncv_is_running(vncv_client *c) {
    if (!c) return 0;
    pthread_mutex_lock(&c->mutex); int running = c->running; pthread_mutex_unlock(&c->mutex);
    return running;
}
int vncv_get_network_rtt(vncv_client *c, vncv_network_rtt *snapshot) {
    if (!snapshot) return 0;
    memset(snapshot, 0, sizeof(*snapshot));
    if (!c) return 0;
    pthread_mutex_lock(&c->mutex);
    int available = network_rtt_locked(c, snapshot);
    pthread_mutex_unlock(&c->mutex);
    return available;
}
int vncv_key(vncv_client *c, uint32_t keysym, int down) {
    command *cmd = calloc(1, sizeof(*cmd));
    if (!cmd) return 0;
    cmd->type = CMD_KEY; cmd->key = keysym; cmd->a = down != 0;
    return enqueue(c, cmd);
}
int vncv_pointer(vncv_client *c, int x, int y, int button_mask) {
    command *cmd = calloc(1, sizeof(*cmd));
    if (!cmd) return 0;
    cmd->type = CMD_POINTER; cmd->a = x; cmd->b = y; cmd->c = button_mask;
    return enqueue(c, cmd);
}
int vncv_clipboard(vncv_client *c, const char *utf8, size_t length) {
    if ((!utf8 && length) || length > MAX_CLIPBOARD) return 0;
    command *cmd = calloc(1, sizeof(*cmd));
    if (!cmd) return 0;
    cmd->text = malloc(length + 1);
    if (!cmd->text) { free(cmd); return 0; }
    if (length) memcpy(cmd->text, utf8, length);
    cmd->text[length] = 0; cmd->length = length; cmd->type = CMD_CLIPBOARD;
    return enqueue(c, cmd);
}
int vncv_refresh(vncv_client *c) {
    command *cmd = calloc(1, sizeof(*cmd));
    if (!cmd) return 0;
    cmd->type = CMD_REFRESH;
    return enqueue(c, cmd);
}
int vncv_set_view_only(vncv_client *c, int view_only) {
    command *cmd = calloc(1, sizeof(*cmd));
    if (!cmd) return 0;
    cmd->type = CMD_VIEW_ONLY; cmd->a = view_only != 0;
    return enqueue(c, cmd);
}
int vncv_set_update_interval(vncv_client *c, uint32_t milliseconds) {
    command *cmd = calloc(1, sizeof(*cmd));
    if (!cmd) return 0;
    cmd->type = CMD_UPDATE_INTERVAL; cmd->key = milliseconds;
    return enqueue(c, cmd);
}
