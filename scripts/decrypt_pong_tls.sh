#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PCAP="${1:-${PONG_PCAP:-${ROOT_DIR}/scripts/pong_tls.pcap}}"
KEYLOG="${2:-${WOLFMQTT_BROKER_KEYLOG_FILE:-${ROOT_DIR}/host/broker.sslkeylog}}"
PORT="${MQTT_PORT:-8883}"

if ! command -v tshark >/dev/null 2>&1; then
	printf 'tshark not found. On Arch/CachyOS, install it with:\n' >&2
	printf '  sudo pacman -S wireshark-cli\n' >&2
	exit 1
fi

if [ ! -f "${PCAP}" ]; then
	printf 'pcap not found: %s\n' "${PCAP}" >&2
	exit 1
fi

if [ ! -f "${KEYLOG}" ]; then
	printf 'TLS keylog not found: %s\n' "${KEYLOG}" >&2
	printf 'Start the broker with the rebuilt wolfMQTT broker and run ping again.\n' >&2
	exit 1
fi

printf '[decrypt] pcap: %s\n' "${PCAP}"
printf '[decrypt] keylog: %s\n' "${KEYLOG}"

decoded="$(
	tshark -r "${PCAP}" \
		-o "tls.keylog_file:${KEYLOG}" \
		-d "tcp.port==${PORT},tls" \
		-Y 'mqtt or data-text-lines or tcp' \
		-T fields \
		-e mqtt.topic \
		-e mqtt.msg \
		-e data.text 2>/dev/null || true
)"

if printf '%s\n' "${decoded}" | grep -q 'pong'; then
	printf '[decrypt] success: decrypted capture contains pong\n'
	printf '%s\n' "${decoded}" | grep --color=never -n 'pong'
	exit 0
fi

printf '[decrypt] pong was not found in the decrypted capture.\n' >&2
printf '[decrypt] Showing decoded MQTT/data lines for inspection:\n' >&2
printf '%s\n' "${decoded}" >&2
exit 2
