#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/workspace/ipsp_mqtt_tls_wolf}"
OQS_PREFIX="${OQS_PREFIX:-/opt/oqs}"
PQC="${PQC:-on}"
BROKER_KEYLOG="${BROKER_KEYLOG:-off}"
MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
MQTT_PORT="${MQTT_PORT:-8883}"
MQTT_COMMAND_TOPIC="${MQTT_COMMAND_TOPIC:-nrf52840/command}"
MQTT_TELEMETRY_TOPIC="${MQTT_TELEMETRY_TOPIC:-nrf52840/telemetry}"
IPSP_ADDR="${IPSP_ADDR:-F9:79:AE:2A:9A:1E}"
IPSP_ADDR_TYPE="${IPSP_ADDR_TYPE:-2}"
MQTT_CAFILE="${MQTT_CAFILE:-${ROOT_DIR}/host/certs/ca.crt}"
MQTT_INSECURE="${MQTT_INSECURE:-1}"
MQTT_TLS_VERSION="${MQTT_TLS_VERSION:-tlsv1.3}"
NCS_ZEPHYR_DIR="${NCS_ZEPHYR_DIR:-/ncs/v2.6.0/zephyr}"

export OPENSSL_MODULES="${OPENSSL_MODULES:-${OQS_PREFIX}/lib/ossl-modules}"
export LD_LIBRARY_PATH="${OQS_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
export OPENSSL_CONF="${OPENSSL_CONF:-${ROOT_DIR}/host/openssl-oqs.cnf}"

cd "${ROOT_DIR}"

usage()
{
    cat <<EOF
Usage: ipsp-server <command> [args]

Commands:
  setup                 fetch wolf modules, generate certs if needed, build broker
  build-broker          build host/build/wolfmqtt-broker with PQC=${PQC}, KEYLOG=${BROKER_KEYLOG}
  broker                run the wolfMQTT TLS broker on port ${MQTT_PORT}
  connect [mac] [type]  create bt0 using host/ipsp_connect.sh
  console               run scripts/board_console.sh inside the container
  pub <payload>         publish one MQTT command payload
  sub                   subscribe to telemetry
  ping                  publish ping and wait for one telemetry message
  clean-port            kill stale TCP sockets on port ${MQTT_PORT}
  apply-ncs-patch       apply patches/zephyr-v2.6.0-l2cap-tx-metadata.patch
  oqs-check             show OpenSSL providers and MLKEM groups
  shell                 open bash in the project directory
  help                  show this text

Container notes:
  - Run with host networking and privileges; IPSP/bt0 is a host-kernel feature.
  - Mount /var/run/dbus, /sys/kernel/debug, /lib/modules, and /dev from host.
  - For NCS patching, mount your NCS v2.6.0 at /ncs/v2.6.0.
EOF
}

ensure_project()
{
    if [ ! -f "${ROOT_DIR}/host/build_wolf_broker.sh" ]; then
        printf 'Project not mounted at ROOT_DIR=%s\n' "${ROOT_DIR}" >&2
        exit 1
    fi
}

trust_mounted_git_dirs()
{
    # The container usually runs as root while the bind-mounted repository and
    # wolf modules are owned by the host user. Limit Git's safe.directory
    # exception to the project paths this container is expected to manage.
    git config --global --add safe.directory "${ROOT_DIR}" >/dev/null 2>&1 || true
    git config --global --add safe.directory "${ROOT_DIR}/modules/wolfssl" >/dev/null 2>&1 || true
    git config --global --add safe.directory "${ROOT_DIR}/modules/wolfmqtt" >/dev/null 2>&1 || true
    git config --global --add safe.directory "${NCS_ZEPHYR_DIR}" >/dev/null 2>&1 || true
}

ensure_certs()
{
    if [ ! -f "${ROOT_DIR}/host/certs/server.crt" ] ||
       [ ! -f "${ROOT_DIR}/host/certs/server.key" ]; then
        "${ROOT_DIR}/host/gen_tls_certs.sh" 2001:db8::2 localhost
        printf '\nGenerated new TLS certs. Rebuild/reflash firmware if its embedded CA differs.\n' >&2
    fi
}

setup_runtime()
{
    ensure_project
    trust_mounted_git_dirs
    "${ROOT_DIR}/scripts/fetch_wolf_modules.sh"
    ensure_certs
    "${ROOT_DIR}/host/build_wolf_broker.sh" --pqc "${PQC}" --keylog "${BROKER_KEYLOG}"
}

mqtt_args()
{
    printf '%s\n' -h "${MQTT_HOST}" -p "${MQTT_PORT}" --cafile "${MQTT_CAFILE}"
    if [ -n "${MQTT_TLS_VERSION}" ]; then
        printf '%s\n' --tls-version "${MQTT_TLS_VERSION}"
    fi
    if [ "${MQTT_INSECURE}" = "1" ]; then
        printf '%s\n' --insecure
    fi
}

run_pub()
{
    local payload="${1:-}"
    local args=()

    if [ -z "${payload}" ]; then
        printf 'Usage: ipsp-server pub <payload>\n' >&2
        exit 1
    fi

    mapfile -t args < <(mqtt_args)
    mosquitto_pub "${args[@]}" -t "${MQTT_COMMAND_TOPIC}" -m "${payload}"
}

run_sub()
{
    local args=()

    mapfile -t args < <(mqtt_args)
    exec mosquitto_sub "${args[@]}" -t "${MQTT_TELEMETRY_TOPIC}"
}

run_ping()
{
    local args=()

    mapfile -t args < <(mqtt_args)
    timeout 10 mosquitto_sub "${args[@]}" -C 1 -t "${MQTT_TELEMETRY_TOPIC}" &
    local sub_pid="$!"
    sleep 0.3
    run_pub ping
    wait "${sub_pid}"
}

clean_port()
{
    ss -K "sport = :${MQTT_PORT}" >/dev/null 2>&1 || true
    ss -K "dport = :${MQTT_PORT}" >/dev/null 2>&1 || true
    ss -tnp "sport = :${MQTT_PORT} or dport = :${MQTT_PORT}" || true
}

apply_ncs_patch()
{
    local patch_file="${ROOT_DIR}/patches/zephyr-v2.6.0-l2cap-tx-metadata.patch"

    if [ ! -d "${NCS_ZEPHYR_DIR}" ]; then
        printf 'NCS Zephyr directory not found: %s\n' "${NCS_ZEPHYR_DIR}" >&2
        printf 'Mount your host NCS v2.6.0 at /ncs/v2.6.0 or set NCS_ZEPHYR_DIR.\n' >&2
        exit 1
    fi

    if git -C "${NCS_ZEPHYR_DIR}" apply --check "${patch_file}" >/dev/null 2>&1; then
        git -C "${NCS_ZEPHYR_DIR}" apply "${patch_file}"
        printf 'Applied Zephyr IPSP L2CAP patch to %s\n' "${NCS_ZEPHYR_DIR}"
    else
        printf 'Patch did not apply cleanly. It may already be applied. Current diff:\n'
        git -C "${NCS_ZEPHYR_DIR}" diff -- subsys/bluetooth/host/l2cap.c || true
    fi
}

oqs_check()
{
    local tls_groups

    openssl list -providers
    printf '\nTLS groups containing MLKEM:\n'
    tls_groups="$(openssl list -tls1_3 -tls-groups 2>/dev/null || true)"
    printf '%s\n' "${tls_groups}" | grep -i 'mlkem\|kem' || true

    if ! printf '%s\n' "${tls_groups}" | grep -qi 'MLKEM768'; then
        printf '\nERROR: MLKEM768 is not available as an OpenSSL TLS 1.3 group.\n' >&2
        printf 'Rebuild this Docker image with the Arch-based Dockerfile.server.\n' >&2
        return 1
    fi
}

cmd="${1:-help}"
shift || true

case "${cmd}" in
setup)
    setup_runtime
    ;;
build-broker)
    ensure_project
    trust_mounted_git_dirs
    "${ROOT_DIR}/host/build_wolf_broker.sh" --pqc "${PQC}" --keylog "${BROKER_KEYLOG}"
    ;;
broker)
    ensure_project
    ensure_certs
    exec "${ROOT_DIR}/host/run_wolf_broker.sh"
    ;;
connect)
    ensure_project
    exec "${ROOT_DIR}/host/ipsp_connect.sh" "${1:-${IPSP_ADDR}}" "${2:-${IPSP_ADDR_TYPE}}"
    ;;
console)
    ensure_project
    export BOARD_CONSOLE_IN_DOCKER=1
    exec "${ROOT_DIR}/scripts/board_console.sh"
    ;;
pub)
    run_pub "${1:-}"
    ;;
sub)
    run_sub
    ;;
ping)
    run_ping
    ;;
clean-port)
    clean_port
    ;;
apply-ncs-patch)
    trust_mounted_git_dirs
    apply_ncs_patch
    ;;
oqs-check)
    oqs_check
    ;;
shell)
    exec bash
    ;;
help|-h|--help)
    usage
    ;;
*)
    printf 'Unknown command: %s\n\n' "${cmd}" >&2
    usage >&2
    exit 1
    ;;
esac
