#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BENCH_DIR="${ROOT_DIR}/benchmarking"
WORK_DIR="${BENCH_DIR}/work"
SRC_WOLFSSL="${ROOT_DIR}/modules/wolfssl"
SRC_WOLFMQTT="${ROOT_DIR}/modules/wolfmqtt"
PATCH_FILE="${BENCH_DIR}/patches/wolfmqtt-benchmark-tls-groups.patch"
TLS_GROUP="MLKEM768"
CERT_SIG="RSA-PSS-3072"
KEYLOG="off"

usage()
{
    cat <<EOF
Usage: $(basename "$0") --tls-group MLKEM512|MLKEM768|MLKEM1024|ECDHE-P-256|ECDHE-P-384|ECDHE-P-521 --cert-sig ALG [--keylog on|off]

Builds a benchmark-only wolfMQTT broker under benchmarking/work/build/.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    --tls-group) TLS_GROUP="${2:-}"; shift 2 ;;
    --tls-group=*) TLS_GROUP="${1#--tls-group=}"; shift ;;
    --cert-sig) CERT_SIG="${2:-}"; shift 2 ;;
    --cert-sig=*) CERT_SIG="${1#--cert-sig=}"; shift ;;
    --keylog) KEYLOG="${2:-}"; shift 2 ;;
    --keylog=*) KEYLOG="${1#--keylog=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

case "${TLS_GROUP}" in
MLKEM512) TLS_GROUP_MACRO="WOLFSSL_ML_KEM_512"; MLKEM_OPT="ml-kem,make,encapsulate,decapsulate,512"; NEEDS_MLKEM="yes" ;;
MLKEM768) TLS_GROUP_MACRO="WOLFSSL_ML_KEM_768"; MLKEM_OPT="ml-kem,make,encapsulate,decapsulate,768"; NEEDS_MLKEM="yes" ;;
MLKEM1024) TLS_GROUP_MACRO="WOLFSSL_ML_KEM_1024"; MLKEM_OPT="ml-kem,make,encapsulate,decapsulate,1024"; NEEDS_MLKEM="yes" ;;
ECDHE-P-256) TLS_GROUP_MACRO="WOLFSSL_ECC_SECP256R1"; MLKEM_OPT=""; NEEDS_MLKEM="no" ;;
ECDHE-P-384) TLS_GROUP_MACRO="WOLFSSL_ECC_SECP384R1"; MLKEM_OPT=""; NEEDS_MLKEM="no" ;;
ECDHE-P-521) TLS_GROUP_MACRO="WOLFSSL_ECC_SECP521R1"; MLKEM_OPT=""; NEEDS_MLKEM="no" ;;
*) printf 'Unsupported TLS group: %s\n' "${TLS_GROUP}" >&2; exit 1 ;;
esac

case "${KEYLOG}" in
on|off) ;;
*) printf 'Invalid --keylog value: %s\n' "${KEYLOG}" >&2; exit 1 ;;
esac

if [ ! -d "${SRC_WOLFSSL}/wolfssl" ] || [ ! -d "${SRC_WOLFMQTT}/wolfmqtt" ]; then
    printf 'wolfSSL/wolfMQTT modules are missing. Run scripts/fetch_wolf_modules.sh first.\n' >&2
    exit 1
fi

variant_key="v3:${TLS_GROUP}:${CERT_SIG}:${KEYLOG}"
variant_hash="$(printf '%s' "${variant_key}" | sha256sum | awk '{print substr($1,1,16)}')"
BUILD_DIR="${WORK_DIR}/build/${variant_hash}"
MODULE_DIR="${WORK_DIR}/modules/${variant_hash}"
WOLFSSL_DIR="${MODULE_DIR}/wolfssl"
WOLFMQTT_DIR="${MODULE_DIR}/wolfmqtt"
WOLFSSL_PREFIX="${BUILD_DIR}/wolfssl-install"
OUT="${BUILD_DIR}/wolfmqtt-broker"
INCLUDE_DIR="${BUILD_DIR}/include"
OPTIONS_DIR="${INCLUDE_DIR}/wolfmqtt"

mkdir -p "${BUILD_DIR}" "${MODULE_DIR}" "${OPTIONS_DIR}"

if [ ! -d "${WOLFSSL_DIR}" ]; then
    cp -a "${SRC_WOLFSSL}" "${WOLFSSL_DIR}"
fi
if [ ! -d "${WOLFMQTT_DIR}" ]; then
    cp -a "${SRC_WOLFMQTT}" "${WOLFMQTT_DIR}"
fi

if ! grep -q 'WOLFMQTT_BROKER_TLS_GROUPS' "${WOLFMQTT_DIR}/src/mqtt_broker.c"; then
    patch --forward --silent -d "${WOLFMQTT_DIR}" -p1 < "${PATCH_FILE}"
fi

if grep -q 'broker: TLS 1.3 group MLKEM768' "${WOLFMQTT_DIR}/src/mqtt_broker.c"; then
    perl -0pi -e 's/WBLOG_INFO\(broker,\s*"broker: TLS 1\.3 group MLKEM768"\);/WBLOG_INFO(broker, "broker: TLS 1.3 group %s", WOLFMQTT_BROKER_TLS_GROUP_NAME);/s; s/WBLOG_INFO\(broker,\s*\n\s*"broker: TLS 1\.3 group MLKEM768"\);/WBLOG_INFO(broker, "broker: TLS 1.3 group %s", WOLFMQTT_BROKER_TLS_GROUP_NAME);/s' \
        "${WOLFMQTT_DIR}/src/mqtt_broker.c"
fi

if [ ! -f "${WOLFSSL_PREFIX}/lib/libwolfssl.a" ]; then
    # The benchmark works from disposable copies under benchmarking/work/.
    # Clean generated Autotools/config headers between attempts so a failed
    # variant cannot poison the next configure run with stale PQC macros.
    if git -C "${WOLFSSL_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "${WOLFSSL_DIR}" clean -fdx >/dev/null
    else
        rm -f "${WOLFSSL_DIR}/config.h" "${WOLFSSL_DIR}/wolfssl/options.h"
        rm -f "${WOLFSSL_DIR}/Makefile" "${WOLFSSL_DIR}/wolfssl/version.h"
    fi

    if [ ! -x "${WOLFSSL_DIR}/configure" ]; then
        (cd "${WOLFSSL_DIR}" && ./autogen.sh)
    fi

    configure_args=(
        --prefix="${WOLFSSL_PREFIX}"
        --enable-static
        --disable-shared
        --enable-tls13
        --enable-ecc
        --enable-supportedcurves
        --disable-examples
        --disable-crypttests
        --enable-opensslextra
        --enable-rsapss
        --with-max-rsa-bits=16384
    )

    if [ "${NEEDS_MLKEM}" = "yes" ]; then
        configure_args+=(
            --enable-mlkem="${MLKEM_OPT}"
            --enable-tls-mlkem-standalone
            --disable-pqc-hybrids
        )
    fi

    case "${CERT_SIG}" in
    ML-DSA-*) configure_args+=(--enable-mldsa=yes) ;;
    SLH-DSA-SHAKE-128s) configure_args+=(--enable-slhdsa=yes,128s --enable-mldsa=yes) ;;
    SLH-DSA-SHAKE-192s) configure_args+=(--enable-slhdsa=yes,192s --enable-mldsa=yes) ;;
    SLH-DSA-SHAKE-256s) configure_args+=(--enable-slhdsa=yes,256s --enable-mldsa=yes) ;;
    ECDSA-*) configure_args+=(--enable-ecc) ;;
    RSA-PSS-*) ;;
    esac

    if [ "${KEYLOG}" = "on" ]; then
        configure_args+=(--enable-keylog-export)
    fi

    (cd "${WOLFSSL_DIR}" && ./configure "${configure_args[@]}" && make -j"$(nproc)" && make install)
fi

cat > "${OPTIONS_DIR}/options.h" <<EOF
#ifndef WOLFMQTT_OPTIONS_H
#define WOLFMQTT_OPTIONS_H

#define ENABLE_MQTT_TLS
#define WOLFMQTT_BROKER
#define WOLFMQTT_BROKER_NO_INSECURE
#define WOLFMQTT_BROKER_FORCE_MLKEM_GROUP
#define WOLFMQTT_BROKER_TLS_GROUPS ${TLS_GROUP_MACRO}
#define WOLFMQTT_BROKER_TLS_GROUP_NAME "${TLS_GROUP}"
#define WOLFMQTT_BROKER_TLS_HANDSHAKE_TIMEOUT_S 120
EOF

if [ "${KEYLOG}" = "on" ]; then
    printf '#define WOLFMQTT_BROKER_KEYLOG_EXPORT\n' >> "${OPTIONS_DIR}/options.h"
fi

cat >> "${OPTIONS_DIR}/options.h" <<'EOF'

#endif
EOF

cc -O2 -Wall -Wextra \
    -I"${INCLUDE_DIR}" \
    -I"${WOLFSSL_PREFIX}/include" \
    -I"${WOLFMQTT_DIR}" \
    "${WOLFMQTT_DIR}/src/mqtt_broker.c" \
    "${WOLFMQTT_DIR}/src/mqtt_client.c" \
    "${WOLFMQTT_DIR}/src/mqtt_packet.c" \
    "${WOLFMQTT_DIR}/src/mqtt_socket.c" \
    -o "${OUT}" \
    "${WOLFSSL_PREFIX}/lib/libwolfssl.a" \
    -lm -lpthread

printf 'variant_hash=%s\n' "${variant_hash}"
printf 'broker=%s\n' "${OUT}"
