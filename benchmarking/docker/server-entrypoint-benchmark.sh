#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/workspace/ipsp_mqtt_tls_wolf}"
BENCH_DIR="${ROOT_DIR}/benchmarking"
OQS_PREFIX="${OQS_PREFIX:-/opt/oqs}"
MQTT_PORT="${MQTT_PORT:-8883}"

export OPENSSL_MODULES="${OPENSSL_MODULES:-${OQS_PREFIX}/lib/ossl-modules}"
export LD_LIBRARY_PATH="${OQS_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
export OPENSSL_CONF="${OPENSSL_CONF:-${BENCH_DIR}/work/openssl-benchmark.cnf}"

cd "${ROOT_DIR}"

usage()
{
    cat <<EOF
Usage: ipsp-benchmark <command> [args]

Commands:
  setup-openssl-conf     create benchmarking/work/openssl-benchmark.cnf
  oqs-check              show OpenSSL providers and benchmark groups
  gen-certs ...          run benchmarking/host/gen_benchmark_certs.py
  build-broker ...       run benchmarking/host/build_benchmark_broker.sh
  broker ...             run benchmarking/host/run_benchmark_broker.sh
  clean-port             clear stale TCP state on MQTT_PORT=${MQTT_PORT}
  shell                  open bash
  help                   show this text
EOF
}

trust_mounted_git_dirs()
{
    git config --global --add safe.directory "${ROOT_DIR}" >/dev/null 2>&1 || true
    git config --global --add safe.directory "${ROOT_DIR}/modules/wolfssl" >/dev/null 2>&1 || true
    git config --global --add safe.directory "${ROOT_DIR}/modules/wolfmqtt" >/dev/null 2>&1 || true
}

setup_openssl_conf()
{
    mkdir -p "${BENCH_DIR}/work"
    cat > "${OPENSSL_CONF}" <<'EOF'
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
EOF
    printf 'Wrote %s\n' "${OPENSSL_CONF}"
}

oqs_check()
{
    local groups

    setup_openssl_conf >/dev/null
    openssl list -providers
    printf '\nTLS groups containing MLKEM:\n'
    groups="$(openssl list -tls1_3 -tls-groups 2>/dev/null || true)"
    printf '%s\n' "${groups}" | tr ':' '\n' | grep -i 'MLKEM' || true

    for group in MLKEM512 MLKEM768 MLKEM1024; do
        if ! printf '%s\n' "${groups}" | grep -q "${group}"; then
            printf 'Missing TLS group: %s\n' "${group}" >&2
            return 1
        fi
    done
}

clean_port()
{
    ss -K "sport = :${MQTT_PORT}" >/dev/null 2>&1 || true
    ss -K "dport = :${MQTT_PORT}" >/dev/null 2>&1 || true
    ss -tnp "sport = :${MQTT_PORT} or dport = :${MQTT_PORT}" || true
}

repo_owner()
{
    stat -c '%u:%g' "${ROOT_DIR}"
}

chown_repo_path()
{
    local path="$1"

    if [ -e "${path}" ]; then
        chown -R "$(repo_owner)" "${path}" >/dev/null 2>&1 || true
    fi
}

get_option_value()
{
    local name="$1"
    shift

    while [ "$#" -gt 0 ]; do
        case "$1" in
        "${name}") printf '%s\n' "${2:-}"; return 0 ;;
        "${name}="*) printf '%s\n' "${1#*=}"; return 0 ;;
        esac
        shift
    done
    return 1
}

cmd="${1:-help}"
shift || true

case "${cmd}" in
setup-openssl-conf)
    setup_openssl_conf
    ;;
oqs-check)
    oqs_check
    ;;
gen-certs)
    setup_openssl_conf >/dev/null
    out_dir="$(get_option_value --out-dir "$@" || true)"
    set +e
    python "${BENCH_DIR}/host/gen_benchmark_certs.py" "$@"
    rc=$?
    set -e
    if [ -n "${out_dir}" ]; then
        chown_repo_path "${out_dir}"
    fi
    exit "${rc}"
    ;;
build-broker)
    trust_mounted_git_dirs
    set +e
    "${BENCH_DIR}/host/build_benchmark_broker.sh" "$@"
    rc=$?
    set -e
    chown_repo_path "${BENCH_DIR}/work"
    exit "${rc}"
    ;;
broker)
    exec "${BENCH_DIR}/host/run_benchmark_broker.sh" "$@"
    ;;
clean-port)
    clean_port
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
