#!/usr/bin/env bash
set -euo pipefail

TLS_GROUP="MLKEM768"
CERT_SIG="RSA-PSS-3072"

usage()
{
    cat <<EOF
Usage: $(basename "$0") --tls-group MLKEM512|MLKEM768|MLKEM1024|ECDHE-P-256|ECDHE-P-384|ECDHE-P-521 --cert-sig ALG

Validates that Mosquitto/OpenSSL/OQS can be used for this benchmark case.
No wolfSSL or wolfMQTT broker is built on the server side.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    --tls-group) TLS_GROUP="${2:-}"; shift 2 ;;
    --tls-group=*) TLS_GROUP="${1#--tls-group=}"; shift ;;
    --cert-sig) CERT_SIG="${2:-}"; shift 2 ;;
    --cert-sig=*) CERT_SIG="${1#--cert-sig=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

case "${TLS_GROUP}" in
MLKEM512|MLKEM768|MLKEM1024|ECDHE-P-256|ECDHE-P-384|ECDHE-P-521) ;;
*) printf 'Unsupported TLS group: %s\n' "${TLS_GROUP}" >&2; exit 1 ;;
esac

case "${CERT_SIG}" in
ML-DSA-*|SLH-DSA-SHAKE-*|ECDSA-*|RSA-PSS-*) ;;
*) printf 'Unsupported certificate signature algorithm: %s\n' "${CERT_SIG}" >&2; exit 1 ;;
esac

if ! command -v mosquitto >/dev/null 2>&1; then
    printf 'mosquitto was not found in PATH\n' >&2
    exit 1
fi

if ! openssl list -providers 2>/dev/null | grep -q 'oqsprovider'; then
    printf 'OpenSSL OQS provider is not active. Check OPENSSL_CONF/OPENSSL_MODULES.\n' >&2
    exit 1
fi

printf 'broker=mosquitto\n'
