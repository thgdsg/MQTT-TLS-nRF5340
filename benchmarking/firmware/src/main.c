/*
 * nRF52840 IPSP MQTT/TLS benchmark client.
 *
 * This application is isolated under benchmarking/ and does not replace the
 * main project firmware. It repeatedly connects to the broker, measures the
 * TCP/TLS/MQTT phases, emits CSV-style serial lines, and disconnects.
 */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <zephyr/kernel.h>
#include <zephyr/linker/section_tags.h>
#include <zephyr/net/net_config.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/socket.h>
#include <zephyr/posix/fcntl.h>
#include <zephyr/sys/sys_heap.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/sys/time_units.h>
#include <zephyr/sys/util.h>
#include <zephyr/timing/timing.h>

#include <wolfssl/options.h>
#include <wolfssl/ssl.h>
#include <wolfmqtt/mqtt_client.h>
#include <wolfmqtt/mqtt_socket.h>

#include <benchmark_cert.h>

#if defined(CONFIG_APP_BENCH_MLKEM_BACKEND_PQM4_CLEAN)
#include "pqm4_mlkem_backend.h"
#endif

#define MQTT_BUFFER_SIZE 4096
#define MQTT_CMD_TIMEOUT_MS CONFIG_APP_MQTT_CMD_TIMEOUT_MS
#define MQTT_TLS_HANDSHAKE_TIMEOUT_MS CONFIG_APP_TLS_HANDSHAKE_TIMEOUT_MS
#define MQTT_TLS_IO_TIMEOUT_MS CONFIG_APP_TLS_IO_TIMEOUT_MS
#define MQTT_KEEPALIVE_SEC CONFIG_APP_MQTT_KEEPALIVE_SEC
#define BLE_IPSP_WRITE_CHUNK 256
#define BLE_IPSP_WRITE_PAUSE_MS 1

#ifndef APP_TLS_GROUP_ID
#define APP_TLS_GROUP_ID WOLFSSL_ML_KEM_512
#endif

#ifndef APP_TLS_GROUP_NAME
#define APP_TLS_GROUP_NAME "MLKEM512"
#endif

#define BENCH_EVENT(...) printk(__VA_ARGS__)

#if defined(CONFIG_APP_BENCH_VERBOSE_LOGS)
#define BENCH_DEBUG(...) printk(__VA_ARGS__)
#else
#define BENCH_DEBUG(...) do { } while (0)
#endif

struct socket_context {
	int fd;
};

#define BENCH_REBOOT_STATE_MAGIC 0x42454e43u

struct bench_reboot_state {
	uint32_t magic;
	int total_attempts;
	int next_attempt;
};

static struct bench_reboot_state reboot_state __noinit;

struct bench_metrics {
	int tcp_connect_ms;
	int tls_setup_ms;
	int tls_handshake_ms;
	int raw_handshake_ms;
	int mqtt_connect_ms;
	int full_connect_ms;
	uint64_t client_wall_cycles;
	uint64_t client_cpu_cycles;
	uint64_t client_cpu_ms;
	uint32_t client_cpu_pct_x100;
	size_t client_wolfssl_peak_bytes;
	size_t client_wolfssl_failures;
	size_t client_heap_current_bytes;
	size_t client_heap_peak_bytes;
	int error_code;
	int tls_last_error;
};

static byte tx_buf[MQTT_BUFFER_SIZE];
static byte rx_buf[MQTT_BUFFER_SIZE];
static MqttClient mqtt_client;
static MqttNet mqtt_net;
static struct socket_context sock_ctx = {
	.fd = -1,
};
static int last_tcp_connect_ms;
static int last_tls_setup_ms;

struct wolfssl_alloc_header {
	size_t size;
	uint32_t magic;
};

#define WOLFSSL_ALLOC_MAGIC 0x5746534cu

static size_t wolfssl_allocated;
static size_t wolfssl_max_allocated;
static size_t wolfssl_alloc_failures;

#if defined(CONFIG_SYS_HEAP_RUNTIME_STATS)
extern struct k_heap _system_heap;
#endif

struct client_runtime_snapshot {
	uint64_t wall_cycles;
	uint64_t cpu_cycles;
};

void *XMALLOC(size_t n, void *heap, int type)
{
	struct wolfssl_alloc_header *hdr;
	size_t total;

	ARG_UNUSED(heap);

	if (n == 0) {
		n = 1;
	}

	total = sizeof(*hdr) + n;
	hdr = k_malloc(total);
	if (!hdr) {
		wolfssl_alloc_failures++;
		BENCH_DEBUG("wolfSSL XMALLOC failed: size=%zu type=%d current=%zu max=%zu failures=%zu\n",
			    n, type, wolfssl_allocated, wolfssl_max_allocated,
			    wolfssl_alloc_failures);
		return NULL;
	}

	hdr->size = n;
	hdr->magic = WOLFSSL_ALLOC_MAGIC;
	wolfssl_allocated += n;
	if (wolfssl_allocated > wolfssl_max_allocated) {
		wolfssl_max_allocated = wolfssl_allocated;
	}

	return hdr + 1;
}

void XFREE(void *p, void *heap, int type)
{
	struct wolfssl_alloc_header *hdr;

	ARG_UNUSED(heap);
	ARG_UNUSED(type);

	if (!p) {
		return;
	}

	hdr = ((struct wolfssl_alloc_header *)p) - 1;
	if (hdr->magic == WOLFSSL_ALLOC_MAGIC) {
		wolfssl_allocated -= hdr->size;
		hdr->magic = 0;
		k_free(hdr);
	}
}

void *XREALLOC(void *p, size_t n, void *heap, int type)
{
	struct wolfssl_alloc_header *hdr;
	void *new_ptr;
	size_t old_size = 0;

	ARG_UNUSED(heap);

	if (!p) {
		return XMALLOC(n, heap, type);
	}

	if (n == 0) {
		XFREE(p, heap, type);
		return NULL;
	}

	hdr = ((struct wolfssl_alloc_header *)p) - 1;
	if (hdr->magic == WOLFSSL_ALLOC_MAGIC) {
		old_size = hdr->size;
	}

	new_ptr = XMALLOC(n, heap, type);
	if (!new_ptr) {
		return NULL;
	}

	memcpy(new_ptr, p, MIN(old_size, n));
	XFREE(p, heap, type);

	return new_ptr;
}

#if defined(CONFIG_APP_BENCH_VERBOSE_LOGS)
static void print_wolfssl_mem(const char *tag)
{
	BENCH_DEBUG("wolfssl_mem[%s]: current=%zu max=%zu failures=%zu\n",
		    tag, wolfssl_allocated, wolfssl_max_allocated,
		    wolfssl_alloc_failures);
}

#if defined(CONFIG_SYS_HEAP_RUNTIME_STATS)
static void print_heap_stats(const char *tag)
{
	struct sys_memory_stats stats;
	int rc;

	rc = sys_heap_runtime_stats_get(&_system_heap.heap, &stats);
	if (rc == 0) {
		BENCH_DEBUG("heap[%s]: free=%zu allocated=%zu max_allocated=%zu\n",
			    tag, stats.free_bytes, stats.allocated_bytes,
			    stats.max_allocated_bytes);
	} else {
		BENCH_DEBUG("heap[%s]: stats unavailable rc=%d\n", tag, rc);
	}
}
#else
static void print_heap_stats(const char *tag)
{
	ARG_UNUSED(tag);
}
#endif

static void print_memory_stats(const char *tag)
{
	print_heap_stats(tag);
	print_wolfssl_mem(tag);
}
#else
static void print_memory_stats(const char *tag)
{
	ARG_UNUSED(tag);
}
#endif

static uint64_t runtime_cycles_to_ms(uint64_t cycles)
{
#if defined(CONFIG_THREAD_RUNTIME_STATS_USE_TIMING_FUNCTIONS)
	return timing_cycles_to_ns(cycles) / 1000000U;
#else
	uint64_t hz = sys_clock_hw_cycles_per_sec();

	return hz > 0 ? (cycles * 1000U) / hz : 0;
#endif
}

static int bench_start_attempt(int total_attempts)
{
	if (!IS_ENABLED(CONFIG_APP_BENCH_REBOOT_AFTER_ATTEMPT)) {
		return 1;
	}

	if (reboot_state.magic != BENCH_REBOOT_STATE_MAGIC ||
	    reboot_state.total_attempts != total_attempts ||
	    reboot_state.next_attempt < 1 ||
	    reboot_state.next_attempt > total_attempts) {
		reboot_state.magic = BENCH_REBOOT_STATE_MAGIC;
		reboot_state.total_attempts = total_attempts;
		reboot_state.next_attempt = 1;
	}

	return reboot_state.next_attempt;
}

static void bench_store_next_attempt(int next_attempt, int total_attempts)
{
	if (!IS_ENABLED(CONFIG_APP_BENCH_REBOOT_AFTER_ATTEMPT)) {
		return;
	}

	if (next_attempt > total_attempts) {
		memset(&reboot_state, 0, sizeof(reboot_state));
		return;
	}

	reboot_state.magic = BENCH_REBOOT_STATE_MAGIC;
	reboot_state.total_attempts = total_attempts;
	reboot_state.next_attempt = next_attempt;
}

static struct client_runtime_snapshot client_runtime_now(void)
{
	struct client_runtime_snapshot snapshot = { 0 };

#if defined(CONFIG_SCHED_THREAD_USAGE_ALL)
	k_thread_runtime_stats_t stats;

	if (k_thread_runtime_stats_all_get(&stats) == 0) {
		snapshot.wall_cycles = stats.execution_cycles;
		snapshot.cpu_cycles = stats.total_cycles;
	}
#endif

	return snapshot;
}

static void reset_attempt_resource_stats(void)
{
	wolfssl_max_allocated = wolfssl_allocated;
	wolfssl_alloc_failures = 0;

#if defined(CONFIG_SYS_HEAP_RUNTIME_STATS)
	(void)sys_heap_runtime_stats_reset_max(&_system_heap.heap);
#endif
}

static void capture_attempt_resource_stats(struct bench_metrics *metrics,
					   struct client_runtime_snapshot start)
{
	struct client_runtime_snapshot end = client_runtime_now();
	uint64_t wall_delta = end.wall_cycles >= start.wall_cycles ?
		end.wall_cycles - start.wall_cycles : 0;
	uint64_t cpu_delta = end.cpu_cycles >= start.cpu_cycles ?
		end.cpu_cycles - start.cpu_cycles : 0;

	metrics->client_wall_cycles = wall_delta;
	metrics->client_cpu_cycles = cpu_delta;
	metrics->client_cpu_ms = runtime_cycles_to_ms(cpu_delta);
	metrics->client_cpu_pct_x100 = wall_delta > 0 ?
		(uint32_t)((cpu_delta * 10000U) / wall_delta) : 0;
	metrics->client_wolfssl_peak_bytes = wolfssl_max_allocated;
	metrics->client_wolfssl_failures = wolfssl_alloc_failures;

#if defined(CONFIG_SYS_HEAP_RUNTIME_STATS)
	{
		struct sys_memory_stats stats;

		if (sys_heap_runtime_stats_get(&_system_heap.heap, &stats) == 0) {
			metrics->client_heap_current_bytes = stats.allocated_bytes;
			metrics->client_heap_peak_bytes = stats.max_allocated_bytes;
		}
	}
#endif
}

static int set_socket_timeout(int fd, int optname, int timeout_ms)
{
	struct timeval tv = {
		.tv_sec = timeout_ms / 1000,
		.tv_usec = (timeout_ms % 1000) * 1000,
	};

	return zsock_setsockopt(fd, SOL_SOCKET, optname, &tv, sizeof(tv));
}

static bool socket_errno_is_timeout(int err)
{
	return err == EAGAIN || err == EWOULDBLOCK || err == ETIMEDOUT;
}

static bool socket_errno_is_transient_write(int err)
{
	return socket_errno_is_timeout(err) || err == ENOBUFS ||
	       err == ENOMEM || err == EINTR || err == EINPROGRESS;
}

static int net_connect(void *context, const char *host, word16 port,
		       int timeout_ms)
{
	struct socket_context *sock = context;
	struct sockaddr_in6 addr6;
	int64_t start;
	int rc;

	last_tcp_connect_ms = 0;

	if (!sock || !host) {
		return MQTT_CODE_ERROR_BAD_ARG;
	}

	memset(&addr6, 0, sizeof(addr6));
	addr6.sin6_family = AF_INET6;
	addr6.sin6_port = htons(port);

	rc = zsock_inet_pton(AF_INET6, host, &addr6.sin6_addr);
	if (rc != 1) {
		BENCH_DEBUG("invalid broker IPv6 address %s\n", host);
		return MQTT_CODE_ERROR_NETWORK;
	}

	sock->fd = zsock_socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
	if (sock->fd < 0) {
		BENCH_DEBUG("socket failed: errno=%d\n", errno);
		return MQTT_CODE_ERROR_NETWORK;
	}

	(void)set_socket_timeout(sock->fd, SO_RCVTIMEO, timeout_ms);
	(void)set_socket_timeout(sock->fd, SO_SNDTIMEO, timeout_ms);

	start = k_uptime_get();
	rc = zsock_connect(sock->fd, (struct sockaddr *)&addr6, sizeof(addr6));
	last_tcp_connect_ms = (int)k_uptime_delta(&start);
	if (rc < 0) {
		BENCH_DEBUG("connect failed: errno=%d\n", errno);
		(void)zsock_close(sock->fd);
		sock->fd = -1;
		return MQTT_CODE_ERROR_NETWORK;
	}

	BENCH_DEBUG("TCP connected in %d ms\n", last_tcp_connect_ms);
	{
		int one = 1;

		rc = zsock_setsockopt(sock->fd, IPPROTO_TCP, TCP_NODELAY,
				      &one, sizeof(one));
		if (rc < 0) {
			BENCH_DEBUG("TCP_NODELAY failed: errno=%d\n", errno);
		}
	}
	return MQTT_CODE_SUCCESS;
}

static int net_read(void *context, byte *buf, int buf_len, int timeout_ms)
{
	struct socket_context *sock = context;
	int64_t deadline;

	if (!sock || sock->fd < 0 || !buf || buf_len <= 0) {
		return MQTT_CODE_ERROR_BAD_ARG;
	}

	deadline = k_uptime_get() + timeout_ms;
	while (k_uptime_get() < deadline) {
		int rc = zsock_recv(sock->fd, buf, buf_len, ZSOCK_MSG_DONTWAIT);

		if (rc < 0) {
			if (socket_errno_is_timeout(errno) || errno == EINPROGRESS) {
				k_sleep(K_MSEC(10));
				continue;
			}
			BENCH_DEBUG("recv failed: errno=%d\n", errno);
			return MQTT_CODE_ERROR_NETWORK;
		}

		if (rc == 0) {
			return MQTT_CODE_ERROR_NETWORK;
		}

		return rc;
	}

	return MQTT_CODE_ERROR_TIMEOUT;
}

static int net_write(void *context, const byte *buf, int buf_len, int timeout_ms)
{
	struct socket_context *sock = context;
	int64_t deadline;
	int total = 0;

	if (!sock || sock->fd < 0 || !buf || buf_len <= 0) {
		return MQTT_CODE_ERROR_BAD_ARG;
	}

	deadline = k_uptime_get() + timeout_ms;

	while (total < buf_len) {
		int chunk_len = MIN(buf_len - total, BLE_IPSP_WRITE_CHUNK);
		int rc = zsock_send(sock->fd, buf + total, chunk_len,
				    ZSOCK_MSG_DONTWAIT);

		if (rc < 0) {
			int err = errno;

			if (socket_errno_is_transient_write(err)) {
				if (k_uptime_get() < deadline) {
					k_sleep(K_MSEC(BLE_IPSP_WRITE_PAUSE_MS));
					continue;
				}
				BENCH_DEBUG("net_write timeout: errno=%d total=%d requested=%d\n",
					    err, total, buf_len);
				return MQTT_CODE_ERROR_NETWORK;
			}

			BENCH_DEBUG("net_write failed: errno=%d total=%d requested=%d\n",
				    err, total, buf_len);
			return total > 0 ? total : MQTT_CODE_ERROR_NETWORK;
		}

		if (rc == 0) {
			return total > 0 ? total : MQTT_CODE_ERROR_NETWORK;
		}

		total += rc;
		if (total < buf_len) {
			k_sleep(K_MSEC(BLE_IPSP_WRITE_PAUSE_MS));
		}
	}

	return total;
}

static int net_disconnect(void *context)
{
	struct socket_context *sock = context;

	if (sock && sock->fd >= 0) {
		(void)zsock_shutdown(sock->fd, SHUT_RDWR);
		(void)zsock_close(sock->fd);
		sock->fd = -1;
	}

	return MQTT_CODE_SUCCESS;
}

static void reset_benchmark_client_state(void)
{
	if (sock_ctx.fd >= 0) {
		(void)net_disconnect(&sock_ctx);
	}

	memset(&mqtt_client, 0, sizeof(mqtt_client));
	memset(&mqtt_net, 0, sizeof(mqtt_net));
	memset(tx_buf, 0, sizeof(tx_buf));
	memset(rx_buf, 0, sizeof(rx_buf));
	sock_ctx.fd = -1;
	last_tcp_connect_ms = 0;
	last_tls_setup_ms = 0;
}

static int mqtt_message_cb(MqttClient *client, MqttMessage *message,
			   byte msg_new, byte msg_done)
{
	ARG_UNUSED(client);
	ARG_UNUSED(message);
	ARG_UNUSED(msg_new);
	ARG_UNUSED(msg_done);

	return MQTT_CODE_SUCCESS;
}

static int tls_verify_cb(int preverify, WOLFSSL_X509_STORE_CTX *store)
{
	if (!preverify && store && store->error != 0) {
		BENCH_DEBUG("TLS verify failed: error=%d depth=%d\n",
		    store->error, store->error_depth);
	}

	/*
	 * Some wolfSSL Zephyr builds call the verify callback with preverify=0
	 * and error=0 for a chain that was otherwise parsed and matched. Keep
	 * rejecting concrete X.509 errors, but allow this no-error state.
	 */
	return preverify || (store && store->error == 0);
}

static int tls_setup_cb(MqttClient *client)
{
	int groups[] = {
		APP_TLS_GROUP_ID,
	};
	int64_t start = k_uptime_get();
	int rc;

	print_memory_stats("tls_setup_start");

	client->tls.ctx = wolfSSL_CTX_new(wolfTLSv1_3_client_method());
	if (!client->tls.ctx) {
		BENCH_DEBUG("wolfSSL_CTX_new failed\n");
		print_memory_stats("ctx_new_failed");
		last_tls_setup_ms = (int)k_uptime_delta(&start);
		return WOLFSSL_FAILURE;
	}

	wolfSSL_CTX_set_verify(client->tls.ctx, WOLFSSL_VERIFY_PEER,
			       tls_verify_cb);

	rc = wolfSSL_CTX_load_verify_buffer(client->tls.ctx,
					    ca_cert_der, ca_cert_der_len,
					    WOLFSSL_FILETYPE_ASN1);
	if (rc != WOLFSSL_SUCCESS) {
		BENCH_DEBUG("wolfSSL_CTX_load_verify_buffer failed: %d\n", rc);
		print_memory_stats("load_ca_failed");
		wolfSSL_CTX_free(client->tls.ctx);
		client->tls.ctx = NULL;
		last_tls_setup_ms = (int)k_uptime_delta(&start);
		return WOLFSSL_FAILURE;
	}

	rc = wolfSSL_CTX_set_groups(client->tls.ctx, groups, ARRAY_SIZE(groups));
	if (rc != WOLFSSL_SUCCESS) {
		BENCH_DEBUG("wolfSSL_CTX_set_groups failed: %d\n", rc);
		print_memory_stats("set_groups_failed");
		wolfSSL_CTX_free(client->tls.ctx);
		client->tls.ctx = NULL;
		last_tls_setup_ms = (int)k_uptime_delta(&start);
		return WOLFSSL_FAILURE;
	}

#if defined(CONFIG_APP_BENCH_MLKEM_BACKEND_PQM4_CLEAN)
	rc = wolfSSL_CTX_SetDevId(client->tls.ctx, pqm4_mlkem_backend_dev_id());
	if (rc != WOLFSSL_SUCCESS) {
		BENCH_DEBUG("wolfSSL_CTX_SetDevId failed: %d\n", rc);
		print_memory_stats("set_devid_failed");
		wolfSSL_CTX_free(client->tls.ctx);
		client->tls.ctx = NULL;
		last_tls_setup_ms = (int)k_uptime_delta(&start);
		return WOLFSSL_FAILURE;
	}
#endif

	BENCH_DEBUG("TLS 1.3 key exchange group: %s\n", APP_TLS_GROUP_NAME);
	BENCH_DEBUG("ML-KEM backend: %s\n", APP_MLKEM_BACKEND_NAME);
	print_memory_stats("tls_setup_done");
	last_tls_setup_ms = (int)k_uptime_delta(&start);

	return WOLFSSL_SUCCESS;
}

static void mqtt_net_init(void)
{
	memset(&mqtt_net, 0, sizeof(mqtt_net));
	mqtt_net.context = &sock_ctx;
	mqtt_net.connect = net_connect;
	mqtt_net.read = net_read;
	mqtt_net.write = net_write;
	mqtt_net.disconnect = net_disconnect;
}

static int mqtt_tls_net_connect(struct bench_metrics *metrics)
{
	int64_t deadline = k_uptime_get() + MQTT_TLS_HANDSHAKE_TIMEOUT_MS;
	int64_t start = k_uptime_get();
	int rc;

	do {
		rc = MqttClient_NetConnect(&mqtt_client,
					   CONFIG_APP_MQTT_BROKER_HOST,
					   CONFIG_APP_MQTT_BROKER_PORT,
					   MQTT_TLS_IO_TIMEOUT_MS, 1,
					   tls_setup_cb);
		if (rc == MQTT_CODE_SUCCESS) {
			int tls_net_ms = (int)k_uptime_delta(&start);

			metrics->tcp_connect_ms = last_tcp_connect_ms;
			metrics->tls_setup_ms = last_tls_setup_ms;
			metrics->tls_handshake_ms =
				MAX(0, tls_net_ms - metrics->tcp_connect_ms);
			metrics->raw_handshake_ms =
				MAX(0, metrics->tls_handshake_ms - metrics->tls_setup_ms);
			return MQTT_CODE_SUCCESS;
		}

		if (rc != MQTT_CODE_CONTINUE &&
		    rc != MQTT_CODE_ERROR_TIMEOUT) {
			BENCH_DEBUG("MqttClient_NetConnect TLS failed: %d "
				    "lastError=%d sockRcRead=%d sockRcWrite=%d\n",
				    rc, mqtt_client.tls.lastError,
				    mqtt_client.tls.sockRcRead,
				    mqtt_client.tls.sockRcWrite);
			print_memory_stats("tls_connect_failed");
			metrics->error_code = rc;
			metrics->tls_last_error = mqtt_client.tls.lastError;
			(void)MqttClient_NetDisconnect(&mqtt_client);
			return rc;
		}

	} while (k_uptime_get() < deadline);

	metrics->error_code = MQTT_CODE_ERROR_TIMEOUT;
	metrics->tls_last_error = mqtt_client.tls.lastError;
	print_memory_stats("tls_connect_timeout");
	(void)MqttClient_NetDisconnect(&mqtt_client);
	return MQTT_CODE_ERROR_TIMEOUT;
}

static int mqtt_connect_subscribe_publish(struct bench_metrics *metrics)
{
	MqttConnect connect;
	MqttSubscribe subscribe;
	MqttTopic topic;
	MqttPublish publish;
	static const char payload[] = "benchmark";
	int64_t start;
	int rc;

	start = k_uptime_get();

	memset(&connect, 0, sizeof(connect));
	connect.keep_alive_sec = MQTT_KEEPALIVE_SEC;
	connect.clean_session = 1;
	connect.client_id = CONFIG_APP_MQTT_CLIENT_ID;

	rc = MqttClient_Connect(&mqtt_client, &connect);
	if (rc != MQTT_CODE_SUCCESS) {
		BENCH_DEBUG("MqttClient_Connect failed: %d ack=%u\n",
		    rc, connect.ack.return_code);
		metrics->error_code = rc;
		return rc;
	}

	memset(&topic, 0, sizeof(topic));
	topic.topic_filter = CONFIG_APP_MQTT_COMMAND_TOPIC;
	topic.qos = MQTT_QOS_0;

	memset(&subscribe, 0, sizeof(subscribe));
	subscribe.packet_id = 1;
	subscribe.topic_count = 1;
	subscribe.topics = &topic;

	rc = MqttClient_Subscribe(&mqtt_client, &subscribe);
	if (rc != MQTT_CODE_SUCCESS) {
		BENCH_DEBUG("MqttClient_Subscribe failed: %d\n", rc);
		metrics->error_code = rc;
		return rc;
	}

	memset(&publish, 0, sizeof(publish));
	publish.topic_name = CONFIG_APP_MQTT_TELEMETRY_TOPIC;
	publish.topic_name_len = strlen(CONFIG_APP_MQTT_TELEMETRY_TOPIC);
	publish.qos = MQTT_QOS_0;
	publish.buffer = (byte *)payload;
	publish.buffer_len = strlen(payload);
	publish.total_len = strlen(payload);

	rc = MqttClient_Publish(&mqtt_client, &publish);
	if (rc != MQTT_CODE_SUCCESS) {
		BENCH_DEBUG("MqttClient_Publish failed: %d\n", rc);
		metrics->error_code = rc;
		return rc;
	}

	metrics->mqtt_connect_ms = (int)k_uptime_delta(&start);
	return MQTT_CODE_SUCCESS;
}

static int run_one_attempt(struct bench_metrics *metrics)
{
	struct client_runtime_snapshot runtime_start;
	int64_t start;
	int rc;

	memset(metrics, 0, sizeof(*metrics));
	reset_benchmark_client_state();
	reset_attempt_resource_stats();
	runtime_start = client_runtime_now();
	mqtt_net_init();

	rc = MqttClient_Init(&mqtt_client, &mqtt_net, mqtt_message_cb,
			     tx_buf, sizeof(tx_buf), rx_buf, sizeof(rx_buf),
			     MQTT_CMD_TIMEOUT_MS);
	if (rc != MQTT_CODE_SUCCESS) {
		metrics->error_code = rc;
		reset_benchmark_client_state();
		capture_attempt_resource_stats(metrics, runtime_start);
		return rc;
	}

	start = k_uptime_get();
	rc = mqtt_tls_net_connect(metrics);
	if (rc == MQTT_CODE_SUCCESS) {
		rc = mqtt_connect_subscribe_publish(metrics);
	}
	metrics->full_connect_ms = (int)k_uptime_delta(&start);

	if (rc == MQTT_CODE_SUCCESS) {
		(void)MqttClient_Disconnect(&mqtt_client);
	}
	(void)MqttClient_NetDisconnect(&mqtt_client);
	MqttClient_DeInit(&mqtt_client);
	capture_attempt_resource_stats(metrics, runtime_start);
	reset_benchmark_client_state();
	print_memory_stats(rc == MQTT_CODE_SUCCESS ? "attempt_done" : "attempt_failed");
	return rc;
}

static int run_one_attempt_with_retries(int attempt_index,
					struct bench_metrics *metrics)
{
	struct bench_metrics first_tls_error_metrics;
	bool have_tls_error = false;
	int rc = MQTT_CODE_ERROR_NETWORK;

	memset(&first_tls_error_metrics, 0, sizeof(first_tls_error_metrics));

	for (int try_index = 1; try_index <= CONFIG_APP_BENCH_CONNECT_RETRIES;
	     try_index++) {
		rc = run_one_attempt(metrics);
		if (rc == MQTT_CODE_SUCCESS) {
			if (try_index > 1) {
				BENCH_DEBUG("BENCH_RETRY_OK,%d,%d\n",
					    attempt_index, try_index);
			}
			return rc;
		}

		if (!have_tls_error && metrics->tls_last_error != 0) {
			first_tls_error_metrics = *metrics;
			have_tls_error = true;
		}

		BENCH_DEBUG("BENCH_RETRY,%d,%d,%d,connect_failed\n",
			    attempt_index, try_index, rc);

		if (try_index < CONFIG_APP_BENCH_CONNECT_RETRIES) {
			k_sleep(K_MSEC(CONFIG_APP_BENCH_CONNECT_RETRY_DELAY_MS));
		}
	}

	if (have_tls_error && metrics->tls_last_error == 0) {
		*metrics = first_tls_error_metrics;
		rc = metrics->error_code;
	}

	return rc;
}

static bool network_ready(void)
{
	struct net_if *iface = net_if_get_default();

	return iface && net_if_is_up(iface);
}

static void ensure_static_ipv6_address(void)
{
	struct net_if *iface = net_if_get_default();
	struct in6_addr addr;
	struct net_if_addr *ifaddr;
	int rc;

	if (!iface) {
		BENCH_DEBUG("No default network interface for static IPv6\n");
		return;
	}

	rc = zsock_inet_pton(AF_INET6, CONFIG_NET_CONFIG_MY_IPV6_ADDR, &addr);
	if (rc != 1) {
		BENCH_DEBUG("Invalid board IPv6 address: %s\n",
		    CONFIG_NET_CONFIG_MY_IPV6_ADDR);
		return;
	}

	ifaddr = net_if_ipv6_addr_lookup_by_iface(iface, &addr);
	if (ifaddr) {
		BENCH_DEBUG("Static IPv6 already configured: %s\n",
		    CONFIG_NET_CONFIG_MY_IPV6_ADDR);
		return;
	}

	ifaddr = net_if_ipv6_addr_add(iface, &addr, NET_ADDR_MANUAL, 0);
	if (!ifaddr) {
		BENCH_DEBUG("Failed to add static IPv6: %s\n",
		    CONFIG_NET_CONFIG_MY_IPV6_ADDR);
		return;
	}

	BENCH_DEBUG("Static IPv6 configured manually: %s\n",
	    CONFIG_NET_CONFIG_MY_IPV6_ADDR);
}

int main(void)
{
	const int warmups = CONFIG_APP_BENCH_WARMUP_ITERATIONS;
	const int iterations = CONFIG_APP_BENCH_ITERATIONS;
	const int total_attempts = warmups + iterations;
	int start_attempt;
	struct bench_metrics metrics;
	int rc;

	BENCH_EVENT("BENCH_START,group,%s,warmups,%d,iterations,%d\n",
	       APP_TLS_GROUP_NAME, warmups, iterations);
	BENCH_DEBUG("Board IPv6: %s\n", CONFIG_NET_CONFIG_MY_IPV6_ADDR);
	BENCH_DEBUG("Broker: [%s]:%d\n", CONFIG_APP_MQTT_BROKER_HOST,
	    CONFIG_APP_MQTT_BROKER_PORT);
	BENCH_DEBUG("ML-KEM backend: %s\n", APP_MLKEM_BACKEND_NAME);
	print_memory_stats("boot");

#if defined(CONFIG_APP_BENCH_MLKEM_BACKEND_PQM4_CLEAN)
	rc = pqm4_mlkem_backend_init();
	if (rc != 0) {
		BENCH_EVENT("BENCH_FATAL,pqm4_backend_init,%d\n", rc);
		return rc;
	}
#endif

	rc = net_config_init_app(NULL, "Initializing IPSP benchmark network");
	BENCH_DEBUG("net_config_init_app returned: %d\n", rc);
	ensure_static_ipv6_address();

	while (!network_ready()) {
		BENCH_DEBUG("Waiting for IPSP network interface...\n");
		k_sleep(K_SECONDS(5));
	}

	BENCH_EVENT("BENCH_READY,initial_delay_ms,%d\n",
	       CONFIG_APP_BENCH_INITIAL_DELAY_MS);
	k_sleep(K_MSEC(CONFIG_APP_BENCH_INITIAL_DELAY_MS));

	start_attempt = bench_start_attempt(total_attempts);
	if (start_attempt > 1) {
		BENCH_EVENT("BENCH_RESUME,next_attempt,%d,total,%d\n",
			    start_attempt, total_attempts);
	}

	for (int i = start_attempt; i <= total_attempts; i++) {
		int warmup = i <= warmups ? 1 : 0;
		char message[80];

		rc = run_one_attempt_with_retries(i, &metrics);
		if (rc == MQTT_CODE_SUCCESS) {
			snprintf(message, sizeof(message),
				 "ok;tls_setup_ms=%d;raw_handshake_ms=%d",
				 metrics.tls_setup_ms,
				 metrics.raw_handshake_ms);
		} else if (metrics.tls_last_error != 0) {
			snprintf(message, sizeof(message), "tls_last_error=%d",
				 metrics.tls_last_error);
		} else {
			snprintf(message, sizeof(message), "connect_failed");
		}

		BENCH_EVENT("BENCH_ATTEMPT,%d,%d,%s,%d,%d,%d,%d,%d,%d,%s,"
			    "%llu,%llu,%llu,%u,%zu,%zu,%zu,%zu\n",
		       i, warmup,
		       rc == MQTT_CODE_SUCCESS ? "success" :
		       rc == MQTT_CODE_ERROR_TIMEOUT ? "timeout" : "error",
		       metrics.tcp_connect_ms,
		       metrics.tls_handshake_ms,
		       metrics.raw_handshake_ms,
		       metrics.mqtt_connect_ms,
		       metrics.full_connect_ms,
		       metrics.error_code,
		       message,
		       (unsigned long long)metrics.client_wall_cycles,
		       (unsigned long long)metrics.client_cpu_cycles,
		       (unsigned long long)metrics.client_cpu_ms,
		       metrics.client_cpu_pct_x100,
		       metrics.client_wolfssl_peak_bytes,
		       metrics.client_wolfssl_failures,
		       metrics.client_heap_current_bytes,
		       metrics.client_heap_peak_bytes);

		if (IS_ENABLED(CONFIG_APP_BENCH_REBOOT_AFTER_ATTEMPT)) {
			bench_store_next_attempt(i + 1, total_attempts);
			k_sleep(K_MSEC(1500));
			if (i < total_attempts) {
				sys_reboot(SYS_REBOOT_COLD);
			}
		}

		k_sleep(K_MSEC(CONFIG_APP_BENCH_PAUSE_MS));
	}

	bench_store_next_attempt(total_attempts + 1, total_attempts);
	BENCH_EVENT("BENCH_DONE,total,%d\n", total_attempts);
	while (1) {
		k_sleep(K_SECONDS(60));
	}
}
