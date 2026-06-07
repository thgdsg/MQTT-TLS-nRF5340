#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WOLFSSL_DIR="${ROOT_DIR}/modules/wolfssl"
WOLFMQTT_DIR="${ROOT_DIR}/modules/wolfmqtt"
BUILD_DIR="${ROOT_DIR}/host/build"
WOLFSSL_PREFIX="${BUILD_DIR}/wolfssl-install"
OUT="${BUILD_DIR}/wolfmqtt-broker"

if [ ! -d "${WOLFSSL_DIR}/wolfssl" ]; then
    printf 'wolfSSL sources not found. Run ./scripts/fetch_wolf_modules.sh first.\n'
    exit 1
fi

if [ ! -d "${WOLFMQTT_DIR}/wolfmqtt" ]; then
    printf 'wolfMQTT sources not found. Run ./scripts/fetch_wolf_modules.sh first.\n'
    exit 1
fi

mkdir -p "${BUILD_DIR}" "${ROOT_DIR}/host/wolfmqtt"

if [ ! -f "${WOLFSSL_PREFIX}/lib/libwolfssl.a" ]; then
    printf 'Building local wolfSSL for host...\n'

    if [ ! -x "${WOLFSSL_DIR}/configure" ]; then
        (cd "${WOLFSSL_DIR}" && ./autogen.sh)
    fi

    (cd "${WOLFSSL_DIR}" && \
        ./configure \
            --prefix="${WOLFSSL_PREFIX}" \
            --enable-static \
            --disable-shared \
            --enable-tls13 \
            --enable-mlkem \
            --enable-pqc-hybrids \
            --enable-tls-mlkem-standalone \
            --disable-examples \
            --disable-crypttests && \
        make -j"$(nproc)" && \
        make install)
fi

cat > "${ROOT_DIR}/host/wolfmqtt/options.h" <<'EOF'
#ifndef WOLFMQTT_OPTIONS_H
#define WOLFMQTT_OPTIONS_H

#define ENABLE_MQTT_TLS
#define WOLFMQTT_BROKER
#define WOLFMQTT_BROKER_NO_INSECURE

#endif
EOF

cc -O2 -Wall -Wextra \
    -I"${ROOT_DIR}/host" \
    -I"${WOLFSSL_PREFIX}/include" \
    -I"${WOLFMQTT_DIR}" \
    "${WOLFMQTT_DIR}/src/mqtt_broker.c" \
    "${WOLFMQTT_DIR}/src/mqtt_client.c" \
    "${WOLFMQTT_DIR}/src/mqtt_packet.c" \
    "${WOLFMQTT_DIR}/src/mqtt_socket.c" \
    -o "${OUT}" \
    "${WOLFSSL_PREFIX}/lib/libwolfssl.a" \
    -lm -lpthread

printf 'Built %s\n' "${OUT}"
