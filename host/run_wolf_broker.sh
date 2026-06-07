#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BROKER="${ROOT_DIR}/host/build/wolfmqtt-broker"
CERT_DIR="${ROOT_DIR}/host/certs"

if [ ! -x "${BROKER}" ]; then
    printf 'Broker not built. Run ./host/build_wolf_broker.sh first.\n'
    exit 1
fi

if [ ! -f "${CERT_DIR}/server.crt" ] || [ ! -f "${CERT_DIR}/server.key" ]; then
    printf 'TLS certs not found. Run ./host/gen_tls_certs.sh first.\n'
    exit 1
fi

exec "${BROKER}" \
    -t \
    -s 8883 \
    -V 13 \
    -c "${CERT_DIR}/server.crt" \
    -K "${CERT_DIR}/server.key"
