/* SPDX-License-Identifier: GPL-2.0-or-later
 * Deterministic unit tests for the real bridge getter, with only its read-only
 * kernel query and monotonic clock replaced. No socket connection or probes. */
#include <assert.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netinet/tcp_fsm.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static struct tcp_connection_info fake_info;
static socklen_t fake_length = sizeof(fake_info);
static int fake_error, query_count;
static double fake_now = 100;
static int test_getsockopt(int fd, int level, int option, void *data, socklen_t *length) {
    assert(fd >= 0 && level == IPPROTO_TCP && option == TCP_CONNECTION_INFO);
    query_count++;
    if (fake_error) { errno = fake_error; return -1; }
    socklen_t copied = fake_length < *length ? fake_length : *length;
    memcpy(data, &fake_info, copied);
    *length = copied;
    return 0;
}
static int test_clock_gettime(clockid_t which, struct timespec *value) {
    assert(which == CLOCK_MONOTONIC);
    value->tv_sec = (time_t)fake_now;
    value->tv_nsec = (long)((fake_now - value->tv_sec) * 1000000000.0);
    return 0;
}
#define getsockopt test_getsockopt
#define clock_gettime test_clock_gettime
#include "../native/VNCBridge.c"
#undef getsockopt
#undef clock_gettime

static void unavailable(vncv_client *client) {
    vncv_network_rtt value = {999, 999, 1, 1};
    assert(!vncv_get_network_rtt(client, &value));
    assert(value.rtt_ms == 0 && value.observed_activity_age_ms == 0 && !value.available && !value.stale);
}
static void near(double actual, double expected) {
    double difference = actual - expected;
    assert(difference > -0.001 && difference < 0.001);
}
static void *reader(void *context) {
    vncv_client *client = context;
    for (int iteration = 0; iteration < 2000; iteration++) {
        vncv_network_rtt value;
        int result = vncv_get_network_rtt(client, &value);
        assert(result == value.available);
        if (result) assert(value.rtt_ms == 7 && !value.stale);
        else assert(value.rtt_ms == 0);
    }
    return NULL;
}
int main(void) {
    unavailable(NULL);
    assert(!vncv_get_network_rtt(NULL, NULL));
    vncv_callbacks callbacks = {0};
    vncv_client *client = vncv_create(callbacks, NULL);
    assert(client);
    unavailable(client);
    assert(query_count == 0);
    client->running = 1;
    client->shutdown_fd = dup(client->wake[0]); /* owned inert descriptor */
    assert(client->shutdown_fd >= 0);
    unavailable(client); /* A TCP descriptor alone must not expose auth/setup. */
    assert(query_count == 0);
    client->network_ready = 1;
    client->network_activity_at = fake_now;
    fake_info.tcpi_state = TCPS_ESTABLISHED;
    fake_info.tcpi_srtt = 37;
    fake_info.tcpi_txpackets = 10; fake_info.tcpi_rxpackets = 20;
    fake_info.tcpi_txbytes = 100; fake_info.tcpi_rxbytes = 200;
    vncv_network_rtt value;
    assert(vncv_get_network_rtt(client, &value));
    assert(value.available && !value.stale);
    near(value.rtt_ms, 37); /* SDK's integer ms must NOT be divided by 1000. */
    near(value.observed_activity_age_ms, 0);
    fake_now = 104;
    assert(vncv_get_network_rtt(client, &value) && !value.stale);
    near(value.observed_activity_age_ms, 4000);
    fake_now = 105;
    assert(vncv_get_network_rtt(client, &value) && value.stale);
    near(value.observed_activity_age_ms, 5000);
    fake_now = 115;
    assert(vncv_get_network_rtt(client, &value) && value.stale);
    near(value.observed_activity_age_ms, 15000); /* Polling never freshens it. */
    fake_now = 116; fake_info.tcpi_rxpackets++;
    assert(vncv_get_network_rtt(client, &value) && !value.stale);
    near(value.observed_activity_age_ms, 0);
    fake_now = 117; fake_info.tcpi_txbytes++;
    assert(vncv_get_network_rtt(client, &value));
    near(value.observed_activity_age_ms, 0);
    fake_now = 118; fake_info.tcpi_srtt = 12;
    assert(vncv_get_network_rtt(client, &value));
    near(value.rtt_ms, 12);
    near(value.observed_activity_age_ms, 1000);
    fake_now = 119; fake_info.tcpi_srtt = 0;
    unavailable(client); /* Zero may mean no sample, not a fake '0 ms'. */
    fake_now = 123; fake_info.tcpi_srtt = 12;
    assert(vncv_get_network_rtt(client, &value) && value.stale);
    fake_error = ENOPROTOOPT;
    unavailable(client);
    fake_error = 0;
    fake_length = offsetof(struct tcp_connection_info, tcpi_rxbytes) + sizeof(fake_info.tcpi_rxbytes) - 1;
    unavailable(client);
    fake_length++; /* Old kernels may omit unused trailing structure fields. */
    assert(vncv_get_network_rtt(client, &value));
    fake_length = sizeof(fake_info);
    fake_info.tcpi_state = TCPS_CLOSE_WAIT;
    unavailable(client);
    fake_info.tcpi_state = TCPS_SYN_SENT;
    unavailable(client);
    fake_info.tcpi_state = TCPS_ESTABLISHED;
    vncv_stop(client);
    int after_stop = query_count;
    unavailable(client);
    assert(query_count == after_stop); /* No OS query after stop. */

    /* A new connection must not inherit another connection's estimate/age. */
    reset_network_rtt_locked(client);
    client->stop_requested = 0; client->running = 1; client->network_ready = 1;
    fake_now = 200; client->network_activity_at = fake_now;
    memset(&fake_info, 0, sizeof(fake_info));
    fake_info.tcpi_state = TCPS_ESTABLISHED; fake_info.tcpi_srtt = 7;
    assert(vncv_get_network_rtt(client, &value) && !value.stale);
    near(value.rtt_ms, 7); near(value.observed_activity_age_ms, 0);
    pthread_t readers[4];
    for (int index = 0; index < 4; index++) assert(!pthread_create(&readers[index], NULL, reader, client));
    vncv_stop(client);
    for (int index = 0; index < 4; index++) pthread_join(readers[index], NULL);
    unavailable(client);
    close(client->shutdown_fd); client->shutdown_fd = -1;
    vncv_destroy(client);
    puts("PASS: passive TCP RTT units, availability, idle age, counter updates, reset, and 8000 concurrent getter calls");
    return 0;
}
