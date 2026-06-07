/*
 * nRF5340 IPSP MQTT/TLS client using wolfMQTT + wolfSSL.
 *
 * The Linux host is expected to connect over BLE IPSP and assign 2001:db8::2
 * to bt0. The board uses 2001:db8::1.
 */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/net/net_config.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/socket.h>
#include <zephyr/sys/printk.h>

#include <wolfssl/options.h>
#include <wolfssl/ssl.h>
#include <wolfmqtt/mqtt_client.h>
#include <wolfmqtt/mqtt_socket.h>

#define LED0_NODE DT_ALIAS(led0)

#if DT_NODE_HAS_STATUS(LED0_NODE, okay)
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(LED0_NODE, gpios);
#define HAS_STATUS_LED 1
#else
#define HAS_STATUS_LED 0
#endif

#define MQTT_BUFFER_SIZE 2048
#define MQTT_CMD_TIMEOUT_MS 5000
#define MQTT_KEEPALIVE_SEC 30
#define MQTT_WAIT_TIMEOUT_MS 1000
#define MQTT_POLL_TIMEOUT_MS 500
#define MQTT_PING_IDLE_MS 20000
#define MQTT_TELEMETRY_INTERVAL_MS 10000
#define BLE_IPSP_WRITE_CHUNK 96

/* Must match host/certs/ca.crt. Regenerate and replace if host certs change. */
static const char ca_cert_pem[] =
"-----BEGIN CERTIFICATE-----\n"
"MIIBhTCCASugAwIBAgIUZnrr9RICtIu6fFaInN0+zQ7Dq58wCgYIKoZIzj0EAwIw\n"
"GDEWMBQGA1UEAwwNaXBzcC1sb2NhbC1jYTAeFw0yNjA2MDYwMjE2MTBaFw0zNjA2\n"
"MDMwMjE2MTBaMBgxFjAUBgNVBAMMDWlwc3AtbG9jYWwtY2EwWTATBgcqhkjOPQIB\n"
"BggqhkjOPQMBBwNCAAROsU80hahC70SZhS1AWrO1RD3ih18/ocS+b/m0pcxDUHAc\n"
"ryW9rr2LXkK0itqNKA2XTS69SvAOHt6+SXj3j8kyo1MwUTAdBgNVHQ4EFgQUvMjt\n"
"9a+gUm4YuB66rQBu2CY9mTkwHwYDVR0jBBgwFoAUvMjt9a+gUm4YuB66rQBu2CY9\n"
"mTkwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAzPz9aKDvx3W2\n"
"AYKiku1feWik6iBoGZAWWCY4mJKDUDkCICRKI71KE2PO1ROCuwPj8a0JjUvAG/q9\n"
"E/limeSIiScs\n"
"-----END CERTIFICATE-----\n";

struct socket_context {
	int fd;
};

static byte tx_buf[MQTT_BUFFER_SIZE];
static byte rx_buf[MQTT_BUFFER_SIZE];
static MqttClient mqtt_client;
static MqttNet mqtt_net;
static struct socket_context sock_ctx = {
	.fd = -1,
};

static void update_led(bool on)
{
#if HAS_STATUS_LED
	if (gpio_is_ready_dt(&led)) {
		(void)gpio_pin_set_dt(&led, on ? 1 : 0);
	}
#else
	ARG_UNUSED(on);
#endif
}

static void handle_command(const byte *payload, word32 len)
{
	char msg[64];
	size_t copy_len = MIN((size_t)len, sizeof(msg) - 1);

	memcpy(msg, payload, copy_len);
	msg[copy_len] = '\0';

	printk("MQTT command: %s\n", msg);

	if (strcmp(msg, "led:on") == 0) {
		update_led(true);
	} else if (strcmp(msg, "led:off") == 0) {
		update_led(false);
	} else if (strcmp(msg, "led:toggle") == 0) {
#if HAS_STATUS_LED
		if (gpio_is_ready_dt(&led)) {
			(void)gpio_pin_toggle_dt(&led);
		}
#endif
	}
}

static int mqtt_message_cb(MqttClient *client, MqttMessage *message,
			   byte msg_new, byte msg_done)
{
	ARG_UNUSED(client);

	if (msg_new) {
		printk("MQTT RX topic: %.*s, total_len=%u\n",
		       message->topic_name_len, message->topic_name,
		       message->total_len);
	}

	if (message->buffer && message->buffer_len > 0) {
		handle_command(message->buffer, message->buffer_len);
	}

	if (msg_done) {
		printk("MQTT RX done\n");
	}

	return MQTT_CODE_SUCCESS;
}

static int set_socket_timeout(int fd, int optname, int timeout_ms)
{
	struct timeval tv = {
		.tv_sec = timeout_ms / 1000,
		.tv_usec = (timeout_ms % 1000) * 1000,
	};

	return zsock_setsockopt(fd, SOL_SOCKET, optname, &tv, sizeof(tv));
}

static int net_connect(void *context, const char *host, word16 port,
		       int timeout_ms)
{
	struct socket_context *sock = context;
	struct sockaddr_in6 addr6;
	int rc;

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

	printk("Connecting TCP socket to [%s]:%u\n", host, port);
	rc = zsock_connect(sock->fd, (struct sockaddr *)&addr6, sizeof(addr6));
	if (rc < 0) {
		printk("connect failed: errno=%d\n", errno);
		(void)zsock_close(sock->fd);
		sock->fd = -1;
		return MQTT_CODE_ERROR_NETWORK;
	}

	return MQTT_CODE_SUCCESS;
}

static int net_read(void *context, byte *buf, int buf_len, int timeout_ms)
{
	struct socket_context *sock = context;
	int rc;

	if (!sock || sock->fd < 0 || !buf || buf_len <= 0) {
		return MQTT_CODE_ERROR_BAD_ARG;
	}

	(void)set_socket_timeout(sock->fd, SO_RCVTIMEO, timeout_ms);
	rc = zsock_recv(sock->fd, buf, buf_len, 0);
	if (rc < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK) {
			return MQTT_CODE_ERROR_TIMEOUT;
		}
		printk("recv failed: errno=%d\n", errno);
		return MQTT_CODE_ERROR_NETWORK;
	}

	if (rc == 0) {
		return MQTT_CODE_ERROR_NETWORK;
	}

	return rc;
}

static int net_write(void *context, const byte *buf, int buf_len, int timeout_ms)
{
	struct socket_context *sock = context;
	int rc;
	int chunk_len;

	if (!sock || sock->fd < 0 || !buf || buf_len <= 0) {
		return MQTT_CODE_ERROR_BAD_ARG;
	}

	(void)set_socket_timeout(sock->fd, SO_SNDTIMEO, timeout_ms);
	chunk_len = MIN(buf_len, BLE_IPSP_WRITE_CHUNK);
	rc = zsock_send(sock->fd, buf, chunk_len, 0);
	if (rc < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK) {
			return MQTT_CODE_ERROR_TIMEOUT;
		}
		printk("send failed: errno=%d\n", errno);
		return MQTT_CODE_ERROR_NETWORK;
	}

	return rc;
}

static int net_disconnect(void *context)
{
	struct socket_context *sock = context;

	if (sock && sock->fd >= 0) {
		(void)zsock_close(sock->fd);
		sock->fd = -1;
	}

	return MQTT_CODE_SUCCESS;
}

static int tls_setup_cb(MqttClient *client)
{
	int rc;

	client->tls.ctx = wolfSSL_CTX_new(wolfTLSv1_3_client_method());
	if (!client->tls.ctx) {
		printk("wolfSSL_CTX_new failed\n");
		return WOLFSSL_FAILURE;
	}

	wolfSSL_CTX_set_verify(client->tls.ctx, WOLFSSL_VERIFY_PEER, NULL);

	rc = wolfSSL_CTX_load_verify_buffer(client->tls.ctx,
					    (const unsigned char *)ca_cert_pem,
					    sizeof(ca_cert_pem) - 1,
					    WOLFSSL_FILETYPE_PEM);
	if (rc != WOLFSSL_SUCCESS) {
		printk("wolfSSL_CTX_load_verify_buffer failed: %d\n", rc);
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

static int mqtt_connect_and_subscribe(void)
{
	MqttConnect connect;
	MqttSubscribe subscribe;
	MqttTopic topic;
	int rc;

	mqtt_net_init();

	rc = MqttClient_Init(&mqtt_client, &mqtt_net, mqtt_message_cb,
			     tx_buf, sizeof(tx_buf), rx_buf, sizeof(rx_buf),
			     MQTT_CMD_TIMEOUT_MS);
	if (rc != MQTT_CODE_SUCCESS) {
		printk("MqttClient_Init failed: %d\n", rc);
		return rc;
	}

	rc = MqttClient_NetConnect(&mqtt_client,
				   CONFIG_APP_MQTT_BROKER_HOST,
				   CONFIG_APP_MQTT_BROKER_PORT,
				   MQTT_CMD_TIMEOUT_MS, 1, tls_setup_cb);
	if (rc != MQTT_CODE_SUCCESS) {
		printk("MqttClient_NetConnect TLS failed: %d\n", rc);
		return rc;
	}

	memset(&connect, 0, sizeof(connect));
	connect.keep_alive_sec = MQTT_KEEPALIVE_SEC;
	connect.clean_session = 1;
	connect.client_id = CONFIG_APP_MQTT_CLIENT_ID;

	rc = MqttClient_Connect(&mqtt_client, &connect);
	if (rc != MQTT_CODE_SUCCESS) {
		printk("MqttClient_Connect failed: %d, ack=%u\n", rc,
		       connect.ack.return_code);
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
		printk("MqttClient_Subscribe failed: %d\n", rc);
		return rc;
	}

	printk("MQTT/TLS connected and subscribed to %s\n",
	       CONFIG_APP_MQTT_COMMAND_TOPIC);

	return MQTT_CODE_SUCCESS;
}

static int mqtt_publish_counter(uint32_t counter)
{
	MqttPublish publish;
	char payload[64];
	int len;
	int rc;

	len = snprintk(payload, sizeof(payload), "counter:%u", counter);

	memset(&publish, 0, sizeof(publish));
	publish.topic_name = CONFIG_APP_MQTT_TELEMETRY_TOPIC;
	publish.topic_name_len = strlen(CONFIG_APP_MQTT_TELEMETRY_TOPIC);
	publish.qos = MQTT_QOS_0;
	publish.buffer = (byte *)payload;
	publish.buffer_len = len;
	publish.total_len = len;

	rc = MqttClient_Publish(&mqtt_client, &publish);
	if (rc == MQTT_CODE_SUCCESS) {
		printk("MQTT TX %s: %s\n", CONFIG_APP_MQTT_TELEMETRY_TOPIC,
		       payload);
	}

	return rc;
}

static int mqtt_socket_poll(int timeout_ms)
{
	struct zsock_pollfd pfd = {
		.fd = sock_ctx.fd,
		.events = ZSOCK_POLLIN,
	};
	int rc;

	if (sock_ctx.fd < 0) {
		return MQTT_CODE_ERROR_NETWORK;
	}

	rc = zsock_poll(&pfd, 1, timeout_ms);
	if (rc < 0) {
		printk("poll failed: errno=%d\n", errno);
		return MQTT_CODE_ERROR_NETWORK;
	}

	if (rc == 0) {
		return MQTT_CODE_ERROR_TIMEOUT;
	}

	if (pfd.revents & (ZSOCK_POLLERR | ZSOCK_POLLHUP | ZSOCK_POLLNVAL)) {
		printk("poll socket error: revents=0x%x\n", pfd.revents);
		return MQTT_CODE_ERROR_NETWORK;
	}

	if (pfd.revents & ZSOCK_POLLIN) {
		return MQTT_CODE_SUCCESS;
	}

	return MQTT_CODE_ERROR_TIMEOUT;
}

static bool network_ready(void)
{
	struct net_if *iface = net_if_get_default();

	return iface && net_if_is_up(iface);
}

int main(void)
{
	uint32_t counter = 0;
	int rc;

	printk("APP main entered\n");

	printk("Configuring status LED...\n");
#if HAS_STATUS_LED
	if (gpio_is_ready_dt(&led)) {
		rc = gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE);
		if (rc) {
			printk("Failed to configure LED: %d\n", rc);
		}
	} else {
		printk("LED GPIO device is not ready\n");
	}
#else
	printk("No led0 alias found\n");
#endif
	printk("Status LED setup done\n");

	printk("nRF5340 IPSP wolfMQTT/wolfSSL client starting\n");
	printk("Board IPv6: %s\n", CONFIG_NET_CONFIG_MY_IPV6_ADDR);
	printk("Broker: [%s]:%d\n", CONFIG_APP_MQTT_BROKER_HOST,
	       CONFIG_APP_MQTT_BROKER_PORT);

	printk("Initializing IPSP network...\n");
	rc = net_config_init_app(NULL, "Initializing IPSP network");
	printk("net_config_init_app returned: %d\n", rc);

	while (!network_ready()) {
		printk("Waiting for IPSP network interface...\n");
		k_sleep(K_SECONDS(5));
	}

	while (1) {
		rc = mqtt_connect_and_subscribe();
		if (rc != MQTT_CODE_SUCCESS) {
			MqttClient_NetDisconnect(&mqtt_client);
			MqttClient_DeInit(&mqtt_client);
			k_sleep(K_SECONDS(5));
			continue;
		}

		int64_t next_telemetry = k_uptime_get() +
					 MQTT_TELEMETRY_INTERVAL_MS;
		int64_t last_mqtt_tx = k_uptime_get();

		while (1) {
			rc = mqtt_socket_poll(MQTT_POLL_TIMEOUT_MS);
			if (rc == MQTT_CODE_SUCCESS) {
				rc = MqttClient_WaitMessage(&mqtt_client,
							    MQTT_WAIT_TIMEOUT_MS);
				if (rc != MQTT_CODE_SUCCESS &&
				    rc != MQTT_CODE_ERROR_TIMEOUT) {
					printk("wait message failed: %d\n", rc);
					break;
				}
			} else if (rc != MQTT_CODE_ERROR_TIMEOUT) {
				printk("socket poll failed: %d\n", rc);
				break;
			}

			if (k_uptime_get() - last_mqtt_tx >= MQTT_PING_IDLE_MS) {
				rc = MqttClient_Ping(&mqtt_client);
				if (rc != MQTT_CODE_SUCCESS) {
					printk("MQTT ping failed: %d\n", rc);
					break;
				}
				printk("MQTT ping ok\n");
				last_mqtt_tx = k_uptime_get();
			}

			if (k_uptime_get() >= next_telemetry) {
				rc = mqtt_publish_counter(counter++);
				if (rc != MQTT_CODE_SUCCESS) {
					printk("publish failed: %d\n", rc);
					break;
				}
				next_telemetry = k_uptime_get() +
						 MQTT_TELEMETRY_INTERVAL_MS;
				last_mqtt_tx = k_uptime_get();
			}

			k_sleep(K_MSEC(100));
		}

		(void)MqttClient_Disconnect(&mqtt_client);
		(void)MqttClient_NetDisconnect(&mqtt_client);
		MqttClient_DeInit(&mqtt_client);
		k_sleep(K_SECONDS(5));
	}
}
