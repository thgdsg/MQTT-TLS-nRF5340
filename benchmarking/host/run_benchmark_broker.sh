#!/usr/bin/env bash
set -euo pipefail

PORT="8883"
CERT=""
KEY=""
TLS_GROUP="MLKEM768"
CONFIG=""
OPENSSL_CASE_CONF=""

usage()
{
    cat <<EOF
Usage: $(basename "$0") --cert PATH --key PATH --tls-group GROUP [--port 8883] [--config PATH]

Runs Mosquitto as the benchmark MQTT/TLS broker. TLS providers and the TLS 1.3
group are selected through a generated OpenSSL config that loads oqsprovider.
EOF
}

map_group()
{
    case "$1" in
    MLKEM512|MLKEM768|MLKEM1024) printf '%s\n' "$1" ;;
    SecP256r1MLKEM768|X25519MLKEM768|SecP384r1MLKEM1024) printf '%s\n' "$1" ;;
    ECDHE-P-256) printf 'P-256\n' ;;
    ECDHE-P-384) printf 'P-384\n' ;;
    ECDHE-P-521) printf 'P-521\n' ;;
    *) return 1 ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    --broker) shift 2 ;; # Kept for compatibility with older runner invocations.
    --cert) CERT="${2:-}"; shift 2 ;;
    --key) KEY="${2:-}"; shift 2 ;;
    --tls-group) TLS_GROUP="${2:-}"; shift 2 ;;
    --tls-group=*) TLS_GROUP="${1#--tls-group=}"; shift ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    --openssl-conf) OPENSSL_CASE_CONF="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ ! -f "${CERT}" ] || [ ! -f "${KEY}" ]; then
    printf 'Mosquitto cert/key not found.\n' >&2
    exit 1
fi

OPENSSL_GROUP="$(map_group "${TLS_GROUP}")" || {
    printf 'Unsupported TLS group: %s\n' "${TLS_GROUP}" >&2
    exit 1
}

CONFIG="${CONFIG:-$(mktemp /tmp/ipsp-benchmark-mosquitto.XXXXXX.conf)}"
OPENSSL_CASE_CONF="${OPENSSL_CASE_CONF:-$(mktemp /tmp/ipsp-benchmark-openssl.XXXXXX.cnf)}"

cat > "${OPENSSL_CASE_CONF}" <<EOF
openssl_conf = openssl_init

[openssl_init]
providers = provider_sect
ssl_conf = ssl_sect

[provider_sect]
default = default_sect
oqsprovider = oqsprovider_sect

[default_sect]
activate = 1

[oqsprovider_sect]
activate = 1

[ssl_sect]
system_default = system_default_sect

[system_default_sect]
MinProtocol = TLSv1.3
MaxProtocol = TLSv1.3
Groups = ${OPENSSL_GROUP}
Options = -SessionTicket
NumTickets = 0
EOF

cat > "${CONFIG}" <<EOF
user root
listener ${PORT} ::
protocol mqtt
listener_allow_anonymous true

certfile ${CERT}
keyfile ${KEY}
tls_version tlsv1.3
require_certificate false

connection_messages true
log_dest stdout
log_type error
log_type warning
log_type notice
log_type information
EOF

export OPENSSL_CONF="${OPENSSL_CASE_CONF}"

printf 'broker: TLS 1.3 group %s via OpenSSL group %s\n' "${TLS_GROUP}" "${OPENSSL_GROUP}"
printf 'broker: using mosquitto with OpenSSL_CONF=%s\n' "${OPENSSL_CONF}"
printf 'broker: mosquitto binary %s\n' "$(command -v mosquitto)"
printf 'broker: benchmark pre-CONNECT timeout is provided by the patched Mosquitto build\n'

exec mosquitto -c "${CONFIG}" -v
