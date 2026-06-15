/*
 * nRF5340 IPSP MQTT/TLS benchmark client.
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
#include <zephyr/net/net_config.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/socket.h>
#include <zephyr/posix/fcntl.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/util.h>

#include <wolfssl/options.h>
#include <wolfssl/ssl.h>
#include <wolfmqtt/mqtt_client.h>
#include <wolfmqtt/mqtt_socket.h>

#include "benchmark_cert.h"

#define MQTT_BUFFER_SIZE 4096
#define MQTT_CMD_TIMEOUT_MS 5000
#define MQTT_TLS_HANDSHAKE_TIMEOUT_MS 120000
#define MQTT_TLS_IO_TIMEOUT_MS 20000
#define MQTT_KEEPALIVE_SEC 10
#define BLE_IPSP_WRITE_CHUNK 64
#define BLE_IPSP_WRITE_PAUSE_MS 20

#ifndef APP_TLS_GROUP_ID
#define APP_TLS_GROUP_ID WOLFSSL_ML_KEM_768
#endif

#ifndef APP_TLS_GROUP_NAME
#define APP_TLS_GROUP_NAME "MLKEM768"
#endif

struct socket_context {
	int fd;
};

struct bench_metrics {
	int tcp_connect_ms;
	int tls_handshake_ms;
	int mqtt_connect_ms;
	int full_connect_ms;
	int error_code;
};

static byte tx_buf[MQTT_BUFFER_SIZE];
static byte rx_buf[MQTT_BUFFER_SIZE];
static MqttClient mqtt_client;
static MqttNet mqtt_net;
static struct socket_context sock_ctx = {
	.fd = -1,
};
static int last_tcp_connect_ms;

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
		printk("invalid broker IPv6 address %s\n", host);
		return MQTT_CODE_ERROR_NETWORK;
	}

	sock->fd = zsock_socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
	if (sock->fd < 0) {
		printk("socket failed: errno=%d\n", errno);
		return MQTT_CODE_ERROR_NETWORK;
	}

	(void)set_socket_timeout(sock->fd, SO_RCVTIMEO, timeout_ms);
	(void)set_socket_timeout(sock->fd, SO_SNDTIMEO, timeout_ms);

	start = k_uptime_get();
	rc = zsock_connect(sock->fd, (struct sockaddr *)&addr6, sizeof(addr6));
	last_tcp_connect_ms = (int)k_uptime_delta(&start);
	if (rc < 0) {
		printk("connect failed: errno=%d\n", errno);
		(void)zsock_close(sock->fd);
		sock->fd = -1;
		return MQTT_CODE_ERROR_NETWORK;
	}

	printk("TCP connected in %d ms\n", last_tcp_connect_ms);
	{
		int one = 1;

		rc = zsock_setsockopt(sock->fd, IPPROTO_TCP, TCP_NODELAY,
				      &one, sizeof(one));
		if (rc < 0) {
			printk("TCP_NODELAY failed: errno=%d\n", errno);
		}
	}
	rc = zsock_fcntl(sock->fd, F_GETFL, 0);
	if (rc >= 0) {
		rc = zsock_fcntl(sock->fd, F_SETFL, rc | O_NONBLOCK);
		if (rc < 0) {
			printk("fcntl O_NONBLOCK failed: errno=%d\n", errno);
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
				printk("net_write timeout: errno=%d total=%d requested=%d\n",
				       err, total, buf_len);
				return MQTT_CODE_ERROR_NETWORK;
			}

			printk("net_write failed: errno=%d total=%d requested=%d\n",
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
		printk("TLS verify failed: error=%d depth=%d\n",
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
	int rc;

	client->tls.ctx = wolfSSL_CTX_new(wolfTLSv1_3_client_method());
	if (!client->tls.ctx) {
		printk("wolfSSL_CTX_new failed\n");
		return WOLFSSL_FAILURE;
	}

	wolfSSL_CTX_set_verify(client->tls.ctx, WOLFSSL_VERIFY_PEER,
			       tls_verify_cb);

	rc = wolfSSL_CTX_load_verify_buffer(client->tls.ctx,
					    (const unsigned char *)ca_cert_pem,
					    sizeof(ca_cert_pem) - 1,
					    WOLFSSL_FILETYPE_PEM);
	if (rc != WOLFSSL_SUCCESS) {
		printk("wolfSSL_CTX_load_verify_buffer failed: %d\n", rc);
		return WOLFSSL_FAILURE;
	}

	rc = wolfSSL_CTX_set_groups(client->tls.ctx, groups, ARRAY_SIZE(groups));
	if (rc != WOLFSSL_SUCCESS) {
		printk("wolfSSL_CTX_set_groups failed: %d\n", rc);
		return WOLFSSL_FAILURE;
	}

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
			metrics->tls_handshake_ms =
				MAX(0, tls_net_ms - metrics->tcp_connect_ms);
			return MQTT_CODE_SUCCESS;
		}

		if (rc != MQTT_CODE_CONTINUE &&
		    rc != MQTT_CODE_ERROR_TIMEOUT) {
			printk("MqttClient_NetConnect TLS failed: %d "
			       "lastError=%d sockRcRead=%d sockRcWrite=%d\n",
			       rc, mqtt_client.tls.lastError,
			       mqtt_client.tls.sockRcRead,
			       mqtt_client.tls.sockRcWrite);
			metrics->error_code = rc;
			(void)MqttClient_NetDisconnect(&mqtt_client);
			return rc;
		}

		k_sleep(K_MSEC(100));
	} while (k_uptime_get() < deadline);

	metrics->error_code = MQTT_CODE_ERROR_TIMEOUT;
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
		metrics->error_code = rc;
		return rc;
	}

	metrics->mqtt_connect_ms = (int)k_uptime_delta(&start);
	return MQTT_CODE_SUCCESS;
}

static int run_one_attempt(struct bench_metrics *metrics)
{
	int64_t start;
	int rc;

	memset(metrics, 0, sizeof(*metrics));
	mqtt_net_init();

	rc = MqttClient_Init(&mqtt_client, &mqtt_net, mqtt_message_cb,
			     tx_buf, sizeof(tx_buf), rx_buf, sizeof(rx_buf),
			     MQTT_CMD_TIMEOUT_MS);
	if (rc != MQTT_CODE_SUCCESS) {
		metrics->error_code = rc;
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
	return rc;
}

static int run_one_attempt_with_retries(int attempt_index,
					struct bench_metrics *metrics)
{
	int rc = MQTT_CODE_ERROR_NETWORK;

	for (int try_index = 1; try_index <= CONFIG_APP_BENCH_CONNECT_RETRIES;
	     try_index++) {
		rc = run_one_attempt(metrics);
		if (rc == MQTT_CODE_SUCCESS) {
			if (try_index > 1) {
				printk("BENCH_RETRY_OK,%d,%d\n", attempt_index,
				       try_index);
			}
			return rc;
		}

		printk("BENCH_RETRY,%d,%d,%d,connect_failed\n",
		       attempt_index, try_index, rc);

		if (try_index < CONFIG_APP_BENCH_CONNECT_RETRIES) {
			k_sleep(K_MSEC(CONFIG_APP_BENCH_CONNECT_RETRY_DELAY_MS));
		}
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
		printk("No default network interface for static IPv6\n");
		return;
	}

	rc = zsock_inet_pton(AF_INET6, CONFIG_NET_CONFIG_MY_IPV6_ADDR, &addr);
	if (rc != 1) {
		printk("Invalid board IPv6 address: %s\n",
		       CONFIG_NET_CONFIG_MY_IPV6_ADDR);
		return;
	}

	ifaddr = net_if_ipv6_addr_lookup_by_iface(iface, &addr);
	if (ifaddr) {
		printk("Static IPv6 already configured: %s\n",
		       CONFIG_NET_CONFIG_MY_IPV6_ADDR);
		return;
	}

	ifaddr = net_if_ipv6_addr_add(iface, &addr, NET_ADDR_MANUAL, 0);
	if (!ifaddr) {
		printk("Failed to add static IPv6: %s\n",
		       CONFIG_NET_CONFIG_MY_IPV6_ADDR);
		return;
	}

	printk("Static IPv6 configured manually: %s\n",
	       CONFIG_NET_CONFIG_MY_IPV6_ADDR);
}

int main(void)
{
	const int warmups = CONFIG_APP_BENCH_WARMUP_ITERATIONS;
	const int iterations = CONFIG_APP_BENCH_ITERATIONS;
	const int total_attempts = warmups + iterations;
	struct bench_metrics metrics;
	int rc;

	printk("BENCH_START,group,%s,warmups,%d,iterations,%d\n",
	       APP_TLS_GROUP_NAME, warmups, iterations);
	printk("Board IPv6: %s\n", CONFIG_NET_CONFIG_MY_IPV6_ADDR);
	printk("Broker: [%s]:%d\n", CONFIG_APP_MQTT_BROKER_HOST,
	       CONFIG_APP_MQTT_BROKER_PORT);

	rc = net_config_init_app(NULL, "Initializing IPSP benchmark network");
	printk("net_config_init_app returned: %d\n", rc);
	ensure_static_ipv6_address();

	while (!network_ready()) {
		printk("Waiting for IPSP network interface...\n");
		k_sleep(K_SECONDS(5));
	}

	printk("BENCH_READY,initial_delay_ms,%d\n",
	       CONFIG_APP_BENCH_INITIAL_DELAY_MS);
	k_sleep(K_MSEC(CONFIG_APP_BENCH_INITIAL_DELAY_MS));

	for (int i = 1; i <= total_attempts; i++) {
		int warmup = i <= warmups ? 1 : 0;

		rc = run_one_attempt_with_retries(i, &metrics);
		printk("BENCH_ATTEMPT,%d,%d,%s,%d,%d,%d,%d,%d,%s\n",
		       i, warmup,
		       rc == MQTT_CODE_SUCCESS ? "success" :
		       rc == MQTT_CODE_ERROR_TIMEOUT ? "timeout" : "error",
		       metrics.tcp_connect_ms,
		       metrics.tls_handshake_ms,
		       metrics.mqtt_connect_ms,
		       metrics.full_connect_ms,
		       metrics.error_code,
		       rc == MQTT_CODE_SUCCESS ? "ok" : "connect_failed");
		k_sleep(K_MSEC(CONFIG_APP_BENCH_PAUSE_MS));
	}

	printk("BENCH_DONE,total,%d\n", total_attempts);
	while (1) {
		k_sleep(K_SECONDS(60));
	}
}
