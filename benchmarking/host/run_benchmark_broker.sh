#!/usr/bin/env bash
set -euo pipefail

PORT="8883"
BROKER=""
CERT=""
KEY=""
KEYLOG_FILE=""

usage()
{
    cat <<EOF
Usage: $(basename "$0") --broker PATH --cert PATH --key PATH [--port 8883] [--keylog-file PATH]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    --broker) BROKER="${2:-}"; shift 2 ;;
    --cert) CERT="${2:-}"; shift 2 ;;
    --key) KEY="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --keylog-file) KEYLOG_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ ! -x "${BROKER}" ]; then
    printf 'Broker executable not found: %s\n' "${BROKER}" >&2
    exit 1
fi
if [ ! -f "${CERT}" ] || [ ! -f "${KEY}" ]; then
    printf 'Broker cert/key not found.\n' >&2
    exit 1
fi

if [ -n "${KEYLOG_FILE}" ]; then
    export WOLFMQTT_BROKER_KEYLOG_FILE="${KEYLOG_FILE}"
fi

exec "${BROKER}" -t -s "${PORT}" -V 13 -c "${CERT}" -K "${KEY}"
