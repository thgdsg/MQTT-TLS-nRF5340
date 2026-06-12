#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WOLFSSL_DIR="${ROOT_DIR}/modules/wolfssl"
WOLFMQTT_DIR="${ROOT_DIR}/modules/wolfmqtt"
BUILD_DIR="${ROOT_DIR}/host/build"
PQC="${PQC:-on}"
KEYLOG="${KEYLOG:-off}"
OUT="${BUILD_DIR}/wolfmqtt-broker"
BROKER_MLKEM_PATCH="${ROOT_DIR}/patches/wolfmqtt-broker-force-mlkem-group.patch"

usage()
{
    cat <<EOF
Usage: $(basename "$0") [--pqc on|off] [--keylog on|off]

Options:
  --pqc on    build broker with TLS 1.3 standalone MLKEM768 key exchange
  --pqc off   build broker with classic TLS 1.3 key exchange
  --keylog on enable TLS keylog callback for pcap decryption
  --keylog off disable TLS keylog callback. Default
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    --pqc)
        if [ "$#" -lt 2 ]; then
            printf 'Missing value for --pqc. Use: --pqc on or --pqc off\n' >&2
            exit 1
        fi
        PQC="${2:-}"
        shift 2
        ;;
    --pqc=*)
        PQC="${1#--pqc=}"
        shift
        ;;
    --keylog)
        if [ "$#" -lt 2 ]; then
            printf 'Missing value for --keylog. Use: --keylog on or --keylog off\n' >&2
            exit 1
        fi
        KEYLOG="${2:-}"
        shift 2
        ;;
    --keylog=*)
        KEYLOG="${1#--keylog=}"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
done

case "${PQC}" in
on | off)
    ;;
*)
    printf 'Invalid --pqc value: %s\n' "${PQC}" >&2
    printf 'Use: --pqc on or --pqc off\n' >&2
    exit 1
    ;;
esac

case "${KEYLOG}" in
on | off)
    ;;
*)
    printf 'Invalid --keylog value: %s\n' "${KEYLOG}" >&2
    printf 'Use: --keylog on or --keylog off\n' >&2
    exit 1
    ;;
esac

if [ "${PQC}" = "on" ] && [ "${KEYLOG}" = "on" ]; then
    WOLFSSL_PREFIX="${BUILD_DIR}/wolfssl-mlkem768-keylog-install"
elif [ "${PQC}" = "on" ]; then
    WOLFSSL_PREFIX="${BUILD_DIR}/wolfssl-mlkem768-nokeylog-install"
else
    WOLFSSL_PREFIX="${BUILD_DIR}/wolfssl-off-install"
fi

if [ ! -d "${WOLFSSL_DIR}/wolfssl" ]; then
    printf 'wolfSSL sources not found. Run ./scripts/fetch_wolf_modules.sh first.\n'
    exit 1
fi

if [ ! -d "${WOLFMQTT_DIR}/wolfmqtt" ]; then
    printf 'wolfMQTT sources not found. Run ./scripts/fetch_wolf_modules.sh first.\n'
    exit 1
fi

if [ "${PQC}" = "on" ] && ! grep -q 'WOLFMQTT_BROKER_FORCE_MLKEM_GROUP' "${WOLFMQTT_DIR}/src/mqtt_broker.c"; then
    if [ ! -f "${BROKER_MLKEM_PATCH}" ]; then
        printf 'wolfMQTT ML-KEM broker patch not found: %s\n' "${BROKER_MLKEM_PATCH}"
        exit 1
    fi
    printf 'Patching wolfMQTT broker for forced ML-KEM TLS group...\n'
    patch --forward --silent -d "${WOLFMQTT_DIR}" -p1 < "${BROKER_MLKEM_PATCH}"
fi

mkdir -p "${BUILD_DIR}" "${ROOT_DIR}/host/wolfmqtt"

if [ ! -f "${WOLFSSL_PREFIX}/lib/libwolfssl.a" ]; then
    printf 'Building local wolfSSL for host (PQC=%s)...\n' "${PQC}"

    if [ ! -x "${WOLFSSL_DIR}/configure" ]; then
        (cd "${WOLFSSL_DIR}" && ./autogen.sh)
    fi

    configure_args=(
        --prefix="${WOLFSSL_PREFIX}"
        --enable-static
        --disable-shared
        --enable-tls13
        --disable-examples
        --disable-crypttests
    )

    if [ "${PQC}" = "on" ]; then
        configure_args+=(
            --enable-mlkem
            --enable-tls-mlkem-standalone
            --disable-pqc-hybrids
            --enable-opensslextra
        )
        if [ "${KEYLOG}" = "on" ]; then
            configure_args+=(--enable-keylog-export)
        fi
    else
        configure_args+=(
            --disable-mlkem
        )
    fi

    (cd "${WOLFSSL_DIR}" && \
        ./configure "${configure_args[@]}" && \
        make -j"$(nproc)" && \
        make install)
fi

cat > "${ROOT_DIR}/host/wolfmqtt/options.h" <<'EOF'
#ifndef WOLFMQTT_OPTIONS_H
#define WOLFMQTT_OPTIONS_H

#define ENABLE_MQTT_TLS
#define WOLFMQTT_BROKER
#define WOLFMQTT_BROKER_NO_INSECURE
EOF

if [ "${PQC}" = "on" ]; then
    cat >> "${ROOT_DIR}/host/wolfmqtt/options.h" <<'EOF'
#define WOLFMQTT_BROKER_FORCE_MLKEM_GROUP
#define WOLFMQTT_BROKER_MLKEM_GROUP WOLFSSL_ML_KEM_768
#define WOLFMQTT_BROKER_TLS_GROUPS WOLFMQTT_BROKER_MLKEM_GROUP
#define WOLFMQTT_BROKER_TLS_HANDSHAKE_TIMEOUT_S 30
EOF
fi

if [ "${KEYLOG}" = "on" ]; then
    cat >> "${ROOT_DIR}/host/wolfmqtt/options.h" <<'EOF'
#define WOLFMQTT_BROKER_KEYLOG_EXPORT
EOF
fi

cat >> "${ROOT_DIR}/host/wolfmqtt/options.h" <<'EOF'
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

printf 'Built %s (PQC=%s, KEYLOG=%s)\n' "${OUT}" "${PQC}" "${KEYLOG}"
