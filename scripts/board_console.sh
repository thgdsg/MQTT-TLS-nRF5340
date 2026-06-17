#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Runtime defaults. Override any of these as environment variables.
TTY_DEVICE="${TTY_DEVICE:-/dev/ttyACM0}"
BAUDRATE="${BAUDRATE:-115200}"
MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
MQTT_PORT="${MQTT_PORT:-8883}"
MQTT_CAFILE="${MQTT_CAFILE:-${ROOT_DIR}/host/certs/ca.crt}"
MQTT_COMMAND_TOPIC="${MQTT_COMMAND_TOPIC:-nrf52840/command}"
MQTT_TELEMETRY_TOPIC="${MQTT_TELEMETRY_TOPIC:-nrf52840/telemetry}"
MQTT_INSECURE="${MQTT_INSECURE:-1}"
MQTT_TLS_VERSION="${MQTT_TLS_VERSION:-tlsv1.3}"
SHOW_TELEMETRY="${SHOW_TELEMETRY:-1}"
PING_TIMEOUT_SEC="${PING_TIMEOUT_SEC:-8}"
PING_CAPTURE_IFACE="${PING_CAPTURE_IFACE:-bt0}"
PONG_LOG="${PONG_LOG:-${ROOT_DIR}/scripts/pong.log}"
PONG_PCAP="${PONG_PCAP:-${ROOT_DIR}/scripts/pong_tls.pcap}"
PONG_CAPTURE_LOG="${PONG_CAPTURE_LOG:-${ROOT_DIR}/scripts/pong_tcpdump.log}"
PONG_LOG_MODE="${PONG_LOG_MODE:-tls_capture}"
PONG_KEY_FILE="${PONG_KEY_FILE:-${ROOT_DIR}/scripts/pong.key}"
BROKER_STOP_TIMEOUT_SEC="${BROKER_STOP_TIMEOUT_SEC:-1}"
IPSP_ADDR="${IPSP_ADDR:-F9:79:AE:2A:9A:1E}"
IPSP_ADDR_TYPE="${IPSP_ADDR_TYPE:-2}"
NRFUTIL="${NRFUTIL:-/home/thiago/.local/bin/nrfutil}"
SERIAL_NUMBER="${SERIAL_NUMBER:-auto}"
NRF_FAMILY="${NRF_FAMILY:-nrf52}"
NCS_VERSION="${NCS_VERSION:-v2.6.0}"
NCS_CHDIR="${NCS_CHDIR:-/home/thiago/ncs/v2.6.0/nrf}"
BOARD="${BOARD:-nrf52840dk_nrf52840}"
SYSBUILD="${SYSBUILD:-0}"
PQC="${PQC:-on}"
PQC_GROUP="${PQC_GROUP:-MLKEM512}"
BROKER_KEYLOG="${BROKER_KEYLOG:-off}"
OQS_PREFIX="${OQS_PREFIX:-/home/thiago/Documents/canada/pesquisa/oqs-openssl/install}"
OPENSSL_OQS_CONF="${OPENSSL_OQS_CONF:-${ROOT_DIR}/host/openssl-oqs.cnf}"

SERIAL_PID=""
TELEMETRY_PID=""
BROKER_PID=""

cleanup()
{
	# Stop background broker, serial, and telemetry monitors when the prompt exits.
	stop_broker
	if [ -n "${SERIAL_PID}" ]; then
		kill "${SERIAL_PID}" >/dev/null 2>&1 || true
	fi
	if [ -n "${TELEMETRY_PID}" ]; then
		kill "${TELEMETRY_PID}" >/dev/null 2>&1 || true
	fi
}

usage()
{
	cat <<EOF
Usage: $(basename "$0") [--docker|docker]

Launcher modes:
  --docker, docker
           run this console inside the Docker server-side container

Environment overrides:
  TTY_DEVICE=${TTY_DEVICE}
  BAUDRATE=${BAUDRATE}
  MQTT_HOST=${MQTT_HOST}
  MQTT_PORT=${MQTT_PORT}
  MQTT_CAFILE=${MQTT_CAFILE}
  MQTT_COMMAND_TOPIC=${MQTT_COMMAND_TOPIC}
  MQTT_TELEMETRY_TOPIC=${MQTT_TELEMETRY_TOPIC}
  MQTT_INSECURE=${MQTT_INSECURE}
  MQTT_TLS_VERSION=${MQTT_TLS_VERSION}
  SHOW_TELEMETRY=${SHOW_TELEMETRY}
  PING_TIMEOUT_SEC=${PING_TIMEOUT_SEC}
  PING_CAPTURE_IFACE=${PING_CAPTURE_IFACE}
  PONG_LOG=${PONG_LOG}
  PONG_PCAP=${PONG_PCAP}
  PONG_CAPTURE_LOG=${PONG_CAPTURE_LOG}
  PONG_LOG_MODE=${PONG_LOG_MODE}
  PONG_KEY_FILE=${PONG_KEY_FILE}
  BROKER_STOP_TIMEOUT_SEC=${BROKER_STOP_TIMEOUT_SEC}
  IPSP_ADDR=${IPSP_ADDR}
  IPSP_ADDR_TYPE=${IPSP_ADDR_TYPE}
  NRFUTIL=${NRFUTIL}
  SERIAL_NUMBER=${SERIAL_NUMBER}
  NRF_FAMILY=${NRF_FAMILY}
  NCS_VERSION=${NCS_VERSION}
  NCS_CHDIR=${NCS_CHDIR}
  BOARD=${BOARD}
  SYSBUILD=${SYSBUILD}
  PQC=${PQC}
  PQC_GROUP=${PQC_GROUP}
  BROKER_KEYLOG=${BROKER_KEYLOG}
  OQS_PREFIX=${OQS_PREFIX}
  OPENSSL_OQS_CONF=${OPENSSL_OQS_CONF}

Interactive commands:
  build broker [--pqc on|off] [--pqc-group MLKEM512|MLKEM768|MLKEM1024] [--keylog on|off]
           build host/build/wolfmqtt-broker. Default PQC=${PQC}, GROUP=${PQC_GROUP}, KEYLOG=${BROKER_KEYLOG}
  build firmware [--pqc on|off]
           build firmware/build/zephyr/zephyr.hex. Default PQC=${PQC}
  connect [mac] [random|public|1|2]
           run host/ipsp_connect.sh. Defaults: ${IPSP_ADDR} ${IPSP_ADDR_TYPE}
  broker on|off|restart|status
           start, stop, restart, or inspect the local wolfMQTT TLS broker
  broker clean-port
           clear stale TCP state on ${MQTT_PORT} and refresh bt0 if needed
  flash    flash firmware after checking USB/J-Link connection
  on       publish led:on
  off      publish led:off
  toggle   publish led:toggle
  ping     publish ping, wait for pong, and save an encrypted pong.log
  status   print current connection settings
  help     show this help
  quit     stop monitor and exit
EOF
}

docker_env_args()
{
	# Pass only portable runtime settings into the container. Path-like values
	# such as ROOT_DIR, OQS_PREFIX, OPENSSL_OQS_CONF, and MQTT_CAFILE are owned
	# by docker-compose/server-entrypoint inside the container.
	printf '%s\n' \
		-e "BOARD_CONSOLE_IN_DOCKER=1" \
		-e "TTY_DEVICE=${TTY_DEVICE}" \
		-e "BAUDRATE=${BAUDRATE}" \
		-e "MQTT_HOST=${MQTT_HOST}" \
		-e "MQTT_PORT=${MQTT_PORT}" \
		-e "MQTT_COMMAND_TOPIC=${MQTT_COMMAND_TOPIC}" \
		-e "MQTT_TELEMETRY_TOPIC=${MQTT_TELEMETRY_TOPIC}" \
		-e "MQTT_INSECURE=${MQTT_INSECURE}" \
		-e "MQTT_TLS_VERSION=${MQTT_TLS_VERSION}" \
		-e "SHOW_TELEMETRY=${SHOW_TELEMETRY}" \
		-e "PING_TIMEOUT_SEC=${PING_TIMEOUT_SEC}" \
		-e "PING_CAPTURE_IFACE=${PING_CAPTURE_IFACE}" \
		-e "PONG_LOG_MODE=${PONG_LOG_MODE}" \
		-e "BROKER_STOP_TIMEOUT_SEC=${BROKER_STOP_TIMEOUT_SEC}" \
		-e "IPSP_ADDR=${IPSP_ADDR}" \
		-e "IPSP_ADDR_TYPE=${IPSP_ADDR_TYPE}" \
		-e "SERIAL_NUMBER=${SERIAL_NUMBER}" \
		-e "NRF_FAMILY=${NRF_FAMILY}" \
		-e "PQC=${PQC}" \
		-e "PQC_GROUP=${PQC_GROUP}" \
		-e "BROKER_KEYLOG=${BROKER_KEYLOG}"
}

run_docker_console()
{
	local docker_script="${ROOT_DIR}/scripts/docker_server.sh"
	local env_args=()

	if [ "${BOARD_CONSOLE_IN_DOCKER:-0}" = "1" ]; then
		printf 'Already running inside the Docker console container.\n' >&2
		return 1
	fi
	if [ ! -x "${docker_script}" ]; then
		printf 'Docker helper not found or not executable: %s\n' "${docker_script}" >&2
		return 1
	fi

	mapfile -t env_args < <(docker_env_args)
	printf '[docker] launching board console inside the server-side container\n'
	exec "${docker_script}" run --rm "${env_args[@]}" ipsp-server console
}

require_command()
{
	if ! command -v "$1" >/dev/null 2>&1; then
		printf 'Required command not found: %s\n' "$1" >&2
		exit 1
	fi
}

run_build_broker()
{
	local build_script="${ROOT_DIR}/host/build_wolf_broker.sh"
	local pqc
	local keylog
	local pqc_group="${PQC_GROUP}"

	if [ ! -x "${build_script}" ]; then
		printf '[build] broker build script not found or not executable: %s\n' "${build_script}" >&2
		return 1
	fi

	pqc="$(parse_pqc_option "$@")" || return 1
	keylog="$(parse_keylog_option "$@")" || return 1
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--pqc-group)
			if [ "$#" -lt 2 ]; then
				printf '[build] missing value for --pqc-group\n' >&2
				return 1
			fi
			pqc_group="$2"
			shift 2
			;;
		--pqc-group=*)
			pqc_group="${1#--pqc-group=}"
			shift
			;;
		*)
			shift
			;;
		esac
	done

	printf '[build] building broker PQC=%s GROUP=%s KEYLOG=%s\n' "${pqc}" "${pqc_group}" "${keylog}"
	"${build_script}" --pqc "${pqc}" --pqc-group "${pqc_group}" --keylog "${keylog}"
}

run_build_firmware()
{
	local pqc
	local cmake_args=()
	local build_args=()

	if [ ! -x "${NRFUTIL}" ]; then
		printf '[build] nrfutil not found at %s\n' "${NRFUTIL}" >&2
		return 1
	fi

	pqc="$(parse_pqc_option "$@")" || return 1
	if [ "${pqc}" = "on" ]; then
		cmake_args=()
	else
		cmake_args=(-DEXTRA_CONF_FILE="${ROOT_DIR}/firmware/pqc_off.conf")
	fi

	printf '[build] building firmware with NCS %s board %s PQC=%s\n' "${NCS_VERSION}" "${BOARD}" "${pqc}"
	build_args=(
		-d "${ROOT_DIR}/firmware/build"
		-b "${BOARD}"
		-p always
		"${ROOT_DIR}/firmware"
	)
	if [ "${SYSBUILD}" = "1" ]; then
		build_args=(--sysbuild "${build_args[@]}")
	fi
	env SHELL=/bin/bash "${NRFUTIL}" sdk-manager toolchain launch \
		--ncs-version "${NCS_VERSION}" \
		--chdir "${NCS_CHDIR}" \
		-- west build \
		"${build_args[@]}" \
		-- "${cmake_args[@]}"
}

parse_pqc_option()
{
	local pqc="${PQC}"

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--pqc)
			if [ "$#" -lt 2 ]; then
				printf 'Missing value for --pqc. Use: --pqc on or --pqc off.\n' >&2
				return 1
			fi
			pqc="${2:-}"
			shift 2
			;;
		--pqc=*)
			pqc="${1#--pqc=}"
			shift
			;;
		--keylog)
			if [ "$#" -lt 2 ]; then
				printf 'Missing value for --keylog. Use: --keylog on or --keylog off.\n' >&2
				return 1
			fi
			shift 2
			;;
		--keylog=*)
			shift
			;;
		--pqc-group)
			if [ "$#" -lt 2 ]; then
				printf 'Missing value for --pqc-group.\n' >&2
				return 1
			fi
			shift 2
			;;
		--pqc-group=*)
			shift
			;;
		*)
			printf 'Unknown build option: %s\n' "$1" >&2
			printf 'Use: --pqc on|off, --pqc-group MLKEM512|MLKEM768|MLKEM1024, or --keylog on|off.\n' >&2
			return 1
			;;
		esac
	done

	case "${pqc}" in
	on | off)
		printf '%s\n' "${pqc}"
		;;
	*)
		printf 'Invalid PQC value: %s\n' "${pqc}" >&2
		printf 'Use: --pqc on or --pqc off.\n' >&2
		return 1
		;;
	esac
}

parse_keylog_option()
{
	local keylog="${BROKER_KEYLOG}"

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--keylog)
			if [ "$#" -lt 2 ]; then
				printf 'Missing value for --keylog. Use: --keylog on or --keylog off.\n' >&2
				return 1
			fi
			keylog="${2:-}"
			shift 2
			;;
		--keylog=*)
			keylog="${1#--keylog=}"
			shift
			;;
		--pqc)
			if [ "$#" -lt 2 ]; then
				printf 'Missing value for --pqc. Use: --pqc on or --pqc off.\n' >&2
				return 1
			fi
			shift 2
			;;
		--pqc=*)
			shift
			;;
		--pqc-group)
			if [ "$#" -lt 2 ]; then
				printf 'Missing value for --pqc-group.\n' >&2
				return 1
			fi
			shift 2
			;;
		--pqc-group=*)
			shift
			;;
		*)
			printf 'Unknown build option: %s\n' "$1" >&2
			printf 'Use: --pqc on|off, --pqc-group MLKEM512|MLKEM768|MLKEM1024, or --keylog on|off.\n' >&2
			return 1
			;;
		esac
	done

	case "${keylog}" in
	on | off)
		printf '%s\n' "${keylog}"
		;;
	*)
		printf 'Invalid keylog value: %s\n' "${keylog}" >&2
		printf 'Use: --keylog on or --keylog off.\n' >&2
		return 1
		;;
	esac
}

handle_build_command()
{
	case "${1:-}" in
	broker)
		shift
		run_build_broker "$@"
		;;
	firmware)
		shift
		run_build_firmware "$@"
		;;
	*)
		printf 'Unknown build command: %s\n' "${1:-}" >&2
		printf 'Use: build broker or build firmware.\n' >&2
		return 1
		;;
	esac
}

mqtt_args()
{
	# Print one MQTT CLI argument per line so callers can mapfile safely.
	printf '%s\n' -h "${MQTT_HOST}" -p "${MQTT_PORT}" --cafile "${MQTT_CAFILE}"
	if [ -n "${MQTT_TLS_VERSION}" ]; then
		printf '%s\n' --tls-version "${MQTT_TLS_VERSION}"
	fi
	if [ "${MQTT_INSECURE}" = "1" ]; then
		printf '%s\n' --insecure
	fi
}

mqtt_env_args()
{
	# In PQC mode, force Mosquitto/OpenSSL through the OQS provider and the
	# same ML-KEM group used by the wolfMQTT broker/firmware.
	if [ "${PQC}" != "on" ]; then
		return
	fi

	printf '%s\n' \
		"OPENSSL_CONF=${OPENSSL_OQS_CONF}" \
		"OPENSSL_MODULES=${OQS_PREFIX}/lib/ossl-modules" \
		"LD_LIBRARY_PATH=${OQS_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
}

check_oqs_runtime()
{
	local env_args=()
	local tls_groups

	if [ "${PQC}" != "on" ]; then
		return 0
	fi

	if [ ! -f "${OPENSSL_OQS_CONF}" ]; then
		printf '[mqtt] OQS OpenSSL config not found: %s\n' "${OPENSSL_OQS_CONF}" >&2
		return 1
	fi

	if [ ! -f "${OQS_PREFIX}/lib/ossl-modules/oqsprovider.so" ]; then
		printf '[mqtt] oqsprovider.so not found under: %s\n' "${OQS_PREFIX}/lib/ossl-modules" >&2
		return 1
	fi

	if [ ! -f "${OQS_PREFIX}/lib/liboqs.so" ] && [ ! -f "${OQS_PREFIX}/lib/liboqs.so.9" ]; then
		printf '[mqtt] liboqs not found under: %s\n' "${OQS_PREFIX}/lib" >&2
		return 1
	fi

	if ! command -v openssl >/dev/null 2>&1; then
		printf '[mqtt] openssl not found; cannot verify OQS TLS groups\n' >&2
		return 1
	fi

	mapfile -t env_args < <(mqtt_env_args)
	tls_groups="$(env "${env_args[@]}" openssl list -tls1_3 -tls-groups 2>/dev/null || true)"
	if ! printf '%s\n' "${tls_groups}" | grep -qi "${PQC_GROUP}"; then
		printf '[mqtt] OpenSSL/OQS is loaded, but %s is not available as a TLS 1.3 group.\n' "${PQC_GROUP}" >&2
		printf '[mqtt] Rebuild the Docker server image or fix your local OpenSSL/OQS provider before publishing.\n' >&2
		return 1
	fi
}

publish_mqtt_payload()
{
	local payload="$1"
	local args=()
	local env_args=()

	if ! check_oqs_runtime; then
		printf '[mqtt] publish failed before connect: OQS runtime is not ready\n' >&2
		return 1
	fi

	mapfile -t args < <(mqtt_args)
	mapfile -t env_args < <(mqtt_env_args)
	env "${env_args[@]}" mosquitto_pub "${args[@]}" -t "${MQTT_COMMAND_TOPIC}" -m "${payload}"
}

publish_led()
{
	local payload="$1"

	# Publish short prompt commands as the firmware's MQTT command payloads.
	if publish_mqtt_payload "${payload}"; then
		printf '[mqtt] sent %s -> %s\n' "${MQTT_COMMAND_TOPIC}" "${payload}"
	else
		printf '[mqtt] publish failed for payload: %s\n' "${payload}" >&2
	fi
}

start_pong_capture()
{
	local capture_timeout="$((PING_TIMEOUT_SEC + 2))"
	local tcpdump_cmd=()
	local launch_cmd=()

	rm -f "${PONG_PCAP}"
	: > "${PONG_CAPTURE_LOG}"

	if ! command -v tcpdump >/dev/null 2>&1; then
		printf '[ping] tcpdump not found; encrypted capture not available\n' >&2
		return 1
	fi
	if ! command -v timeout >/dev/null 2>&1; then
		printf '[ping] timeout not found; encrypted capture not available\n' >&2
		return 1
	fi
	if ! command -v setsid >/dev/null 2>&1; then
		printf '[ping] setsid not found; encrypted capture not available\n' >&2
		return 1
	fi

	tcpdump_cmd=(tcpdump -Z root -i "${PING_CAPTURE_IFACE}" -s 0 -U -w "${PONG_PCAP}" 'tcp port 8883')

	if [ "$(id -u)" -eq 0 ]; then
		launch_cmd=(setsid timeout "${capture_timeout}" "${tcpdump_cmd[@]}")
	elif sudo -n true >/dev/null 2>&1; then
		# Keep sudo outside setsid. Some sudo configs bind the timestamp to the
		# terminal/session, so running sudo inside setsid can still ask for a
		# password even after the user ran sudo -v.
		launch_cmd=(sudo -n setsid timeout "${capture_timeout}" "${tcpdump_cmd[@]}")
	else
		printf '[ping] sudo is required for tcpdump; run sudo -v immediately before board_console.sh to fill %s\n' "${PONG_PCAP}" >&2
		printf 'sudo timestamp was not available for non-interactive tcpdump\n' > "${PONG_CAPTURE_LOG}"
		return 1
	fi

	# This pcap stores the encrypted TLS records seen on bt0.
	"${launch_cmd[@]}" > "${PONG_CAPTURE_LOG}" 2>&1 &
	printf '%s\n' "$!"
}

stop_pong_capture()
{
	local pid="$1"

	if [ -n "${pid}" ]; then
		kill -TERM "-${pid}" >/dev/null 2>&1 || kill "${pid}" >/dev/null 2>&1 || true
		wait "${pid}" >/dev/null 2>&1 || true
	fi
}

ensure_pong_key()
{
	if [ -f "${PONG_KEY_FILE}" ]; then
		chmod 600 "${PONG_KEY_FILE}" 2>/dev/null || true
		return 0
	fi

	if ! command -v openssl >/dev/null 2>&1; then
		printf '[ping] openssl not found; cannot encrypt pong.log\n' >&2
		return 1
	fi

	umask 077
	openssl rand -base64 48 > "${PONG_KEY_FILE}"
	chmod 600 "${PONG_KEY_FILE}" 2>/dev/null || true
	printf '[ping] generated local pong log key: %s\n' "${PONG_KEY_FILE}"
}

save_encrypted_pong()
{
	if ! ensure_pong_key; then
		return 1
	fi

	printf 'pong' |
		openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 \
			-pass "file:${PONG_KEY_FILE}" \
			-out "${PONG_LOG}"
}

ping_board()
{
	local args=()
	local env_args=()
	local sub_log
	local sub_pid=""
	local capture_pid=""
	local deadline

	if ! command -v mosquitto_sub >/dev/null 2>&1; then
		printf '[ping] mosquitto_sub not found\n' >&2
		return 1
	fi
	if ! check_oqs_runtime; then
		printf '[ping] OQS runtime is not ready\n' >&2
		return 1
	fi

	sub_log="$(mktemp)"
	mapfile -t args < <(mqtt_args)
	mapfile -t env_args < <(mqtt_env_args)

	(
		env "${env_args[@]}" mosquitto_sub "${args[@]}" -t "${MQTT_TELEMETRY_TOPIC}" 2>/dev/null
	) > "${sub_log}" &
	sub_pid="$!"

	if [ "${PONG_LOG_MODE}" = "tls_capture" ]; then
		capture_pid="$(start_pong_capture || true)"
		sleep 0.4
		if [ -n "${capture_pid}" ] && ! kill -0 "${capture_pid}" >/dev/null 2>&1; then
			printf '[ping] tcpdump exited before ping; see %s\n' "${PONG_CAPTURE_LOG}" >&2
		fi
	else
		: > "${PONG_LOG}"
	fi
	sleep 0.2

	if publish_mqtt_payload ping; then
		printf '[ping] sent %s -> ping\n' "${MQTT_COMMAND_TOPIC}"
	else
		printf '[ping] publish failed\n' >&2
		kill "${sub_pid}" >/dev/null 2>&1 || true
		wait "${sub_pid}" >/dev/null 2>&1 || true
		stop_pong_capture "${capture_pid}"
		rm -f "${sub_log}"
		return 1
	fi

	deadline=$((SECONDS + PING_TIMEOUT_SEC))
	while [ "${SECONDS}" -lt "${deadline}" ]; do
		if grep -qx 'pong' "${sub_log}"; then
			printf '[ping] received pong\n'
			stop_pong_capture "${capture_pid}"
			if [ "${PONG_LOG_MODE}" = "tls_capture" ]; then
				if [ -s "${PONG_PCAP}" ]; then
					printf '[ping] encrypted TLS pcap saved to %s\n' "${PONG_PCAP}"
				else
					printf '[ping] TLS pcap was not created; see %s\n' "${PONG_CAPTURE_LOG}" >&2
				fi
			elif save_encrypted_pong; then
				printf '[ping] encrypted pong saved to %s\n' "${PONG_LOG}"
			else
				printf '[ping] failed to encrypt pong into %s\n' "${PONG_LOG}" >&2
			fi
			kill "${sub_pid}" >/dev/null 2>&1 || true
			wait "${sub_pid}" >/dev/null 2>&1 || true
			rm -f "${sub_log}"
			return 0
		fi
		sleep 0.2
	done

	printf '[ping] timed out waiting for pong on %s\n' "${MQTT_TELEMETRY_TOPIC}" >&2
	if [ "${PONG_LOG_MODE}" = "tls_capture" ]; then
		printf '[ping] encrypted TLS pcap saved to %s if tcpdump was available\n' "${PONG_PCAP}" >&2
	fi
	kill "${sub_pid}" >/dev/null 2>&1 || true
	wait "${sub_pid}" >/dev/null 2>&1 || true
	stop_pong_capture "${capture_pid}"
	rm -f "${sub_log}"
	return 1
}

addr_type_to_number()
{
	case "$1" in
	random | 2)
		printf '2\n'
		;;
	public | 1)
		printf '1\n'
		;;
	*)
		printf 'Invalid address type: %s\n' "$1" >&2
		printf 'Use random, public, 2, or 1.\n' >&2
		return 1
		;;
	esac
}

run_ipsp_connect()
{
	local addr="${1:-${IPSP_ADDR}}"
	local type="${2:-${IPSP_ADDR_TYPE}}"
	local type_num
	local connect_script="${ROOT_DIR}/host/ipsp_connect.sh"
	local cmd=()

	if [ "$#" -eq 1 ]; then
		case "$1" in
		random | public | 1 | 2)
			addr="${IPSP_ADDR}"
			type="$1"
			;;
		esac
	fi

	if [ -z "${addr}" ]; then
		printf 'No IPSP BLE address configured.\n' >&2
		printf 'Use: connect <BLE_MAC> [random|public|1|2]\n' >&2
		printf 'Or start with: IPSP_ADDR=<BLE_MAC> %s\n' "$0" >&2
		return 1
	fi

	type_num="$(addr_type_to_number "${type}")"

	if [ ! -x "${connect_script}" ]; then
		printf 'IPSP connect script not found or not executable: %s\n' "${connect_script}" >&2
		return 1
	fi

	# The IPSP helper needs root because it writes kernel bluetooth_6lowpan files.
	if [ "$(id -u)" -eq 0 ]; then
		cmd=("${connect_script}" "${addr}" "${type_num}")
	else
		cmd=(sudo "${connect_script}" "${addr}" "${type_num}")
	fi

	printf '[ipsp] connecting %s addr_type=%s\n' "${addr}" "${type_num}"
	"${cmd[@]}"
}

nrf_device_connected()
{
	local devices

	if [ ! -x "${NRFUTIL}" ]; then
		printf '[flash] nrfutil not found at %s\n' "${NRFUTIL}" >&2
		return 1
	fi

	# Query nrfutil first so flash fails before touching the board or serial.
	if ! devices="$("${NRFUTIL}" device list 2>/dev/null)"; then
		printf '[flash] failed to query nrfutil device list\n' >&2
		return 1
	fi

	if [ "${SERIAL_NUMBER}" = "auto" ] &&
	   [ "$(printf '%s\n' "${devices}" | sed -n 's/^\([0-9][0-9]*\)$/\1/p' | wc -l)" -eq 1 ]; then
		return 0
	fi

	if [ "${SERIAL_NUMBER}" != "auto" ] && printf '%s\n' "${devices}" | grep -q "^${SERIAL_NUMBER}$"; then
		return 0
	fi

	printf '[flash] nRF device %s was not found over USB/J-Link\n' "${SERIAL_NUMBER}" >&2
	printf '[flash] connected devices reported by nrfutil:\n%s\n' "${devices}" >&2
	return 1
}

stop_serial_monitor()
{
	if [ -n "${SERIAL_PID}" ]; then
		kill "${SERIAL_PID}" >/dev/null 2>&1 || true
		wait "${SERIAL_PID}" >/dev/null 2>&1 || true
		SERIAL_PID=""
	fi
}

run_flash()
{
	local flash_script="${ROOT_DIR}/scripts/flash_firmware.sh"

	if [ ! -x "${flash_script}" ]; then
		printf '[flash] flash script not found or not executable: %s\n' "${flash_script}" >&2
		return 1
	fi

	if ! nrf_device_connected; then
		return 1
	fi

	# Release the serial port while the board resets during flashing.
	stop_serial_monitor

	printf '[flash] flashing nRF device %s\n' "${SERIAL_NUMBER}"
	if NRFUTIL="${NRFUTIL}" SERIAL_NUMBER="${SERIAL_NUMBER}" NRF_FAMILY="${NRF_FAMILY}" "${flash_script}" "$@"; then
		printf '[flash] done\n'
	else
		printf '[flash] failed\n' >&2
		start_serial_monitor
		return 1
	fi

	start_serial_monitor
}

broker_running()
{
	[ -n "${BROKER_PID}" ] && kill -0 "${BROKER_PID}" >/dev/null 2>&1
}

broker_port_busy()
{
	ss -ltn "sport = :${MQTT_PORT}" 2>/dev/null | grep -q ":${MQTT_PORT}"
}

broker_port_has_stale_tcp()
{
	ss -tn "sport = :${MQTT_PORT} or dport = :${MQTT_PORT}" 2>/dev/null |
		awk 'NR > 1 { found = 1 } END { exit found ? 0 : 1 }'
}

run_root_best_effort()
{
	if [ "$(id -u)" -eq 0 ]; then
		"$@" >/dev/null 2>&1 || true
	elif sudo -n true >/dev/null 2>&1; then
		sudo -n "$@" >/dev/null 2>&1 || true
	fi
}

clean_broker_port()
{
	printf '[broker] cleaning TCP state for port %s\n' "${MQTT_PORT}"

	# ss -K asks the kernel to kill matching TCP sockets. It needs root, so it
	# is best-effort unless the user already ran sudo -v or launched as root.
	run_root_best_effort ss -K "sport = :${MQTT_PORT}"
	run_root_best_effort ss -K "dport = :${MQTT_PORT}"

	if broker_port_has_stale_tcp; then
		printf '[broker] stale TCP state remains on %s:\n' "${MQTT_PORT}" >&2
		ss -tnp "sport = :${MQTT_PORT} or dport = :${MQTT_PORT}" >&2 || true

		# FIN-WAIT sockets on bt0 may persist when the BLE IPSP link died before
		# TCP could finish closing. Cycling bt0 drops the dead path cleanly.
		if ip link show bt0 >/dev/null 2>&1; then
			printf '[broker] refreshing bt0 to drop stale IPSP socket state\n'
			run_root_best_effort ip link set bt0 down
			sleep 0.5
			run_root_best_effort ip link set bt0 up
			run_root_best_effort ip address add 2001:db8::2/64 dev bt0
		fi
	fi
}

wait_broker_port_free()
{
	local deadline=$((SECONDS + BROKER_STOP_TIMEOUT_SEC))

	while broker_port_busy; do
		if [ "${SECONDS}" -ge "${deadline}" ]; then
			return 1
		fi
		sleep 0.2
	done

	return 0
}

start_broker()
{
	local broker_script="${ROOT_DIR}/host/run_wolf_broker.sh"
	local connect_script="${ROOT_DIR}/host/ipsp_connect.sh"

	if broker_running; then
		printf '[broker] already running pid=%s\n' "${BROKER_PID}"
		return 0
	fi

	if [ ! -x "${broker_script}" ]; then
		printf '[broker] broker script not found or not executable: %s\n' "${broker_script}" >&2
		return 1
	fi
	if [ ! -x "${connect_script}" ]; then
		printf '[broker] IPSP connect script not found or not executable: %s\n' "${connect_script}" >&2
		return 1
	fi
	if ! command -v setsid >/dev/null 2>&1; then
		printf '[broker] setsid not found; install util-linux\n' >&2
		return 1
	fi
	if ! command -v ss >/dev/null 2>&1; then
		printf '[broker] ss not found; install iproute2\n' >&2
		return 1
	fi

	clean_broker_port

	if broker_port_busy; then
		printf '[broker] waiting for port %s to become free\n' "${MQTT_PORT}"
		if ! wait_broker_port_free; then
			printf '[broker] port %s is still busy; current listener:\n' "${MQTT_PORT}" >&2
			ss -ltnp "sport = :${MQTT_PORT}" >&2 || true
			return 1
		fi
	fi

	# Run a broker supervisor in its own process group. If the TLS handshake
	# times out, the supervisor restarts the broker and recreates the IPSP link.
	setsid bash -c '
set -euo pipefail

broker_script="$1"
connect_script="$2"
ipsp_addr="$3"
ipsp_type="$4"
mqtt_port="$5"

kill_port_state()
{
	ss -K "sport = :${mqtt_port}" >/dev/null 2>&1 || true
	ss -K "dport = :${mqtt_port}" >/dev/null 2>&1 || true
}

wait_port_available()
{
	deadline=$((SECONDS + 8))

	while ss -ltn "sport = :${mqtt_port}" 2>/dev/null | grep -q ":${mqtt_port}"; do
		if [ "${SECONDS}" -ge "${deadline}" ]; then
			printf "[broker] fail-safe: port %s still has a listener\n" "${mqtt_port}"
			ss -ltnp "sport = :${mqtt_port}" || true
			return 1
		fi
		sleep 0.2
	done

	return 0
}

run_reconnect()
{
	printf "[broker] fail-safe: reconnecting IPSP %s addr_type=%s\n" "${ipsp_addr}" "${ipsp_type}"
	if [ "$(id -u)" -eq 0 ]; then
		"${connect_script}" "${ipsp_addr}" "${ipsp_type}" 2>&1 | sed -u "s/^/[ipsp] /" || true
	elif sudo -n true >/dev/null 2>&1; then
		sudo -n "${connect_script}" "${ipsp_addr}" "${ipsp_type}" 2>&1 | sed -u "s/^/[ipsp] /" || true
	else
		printf "[broker] fail-safe: sudo timestamp unavailable; run sudo -v before starting broker\n"
	fi
}

while true; do
	recover_reason=""
	kill_port_state
	wait_port_available || true

	coproc BROKER_PROC { "${broker_script}" 2>&1; }
	broker_pid="${BROKER_PROC_PID}"

	while IFS= read -r line <&"${BROKER_PROC[0]}"; do
		printf "[broker] %s\n" "${line}"
		case "${line}" in
		*"TLS handshake timeout"*)
			recover_reason="TLS handshake timeout"
			printf "[broker] fail-safe: TLS handshake timeout detected, restarting broker and IPSP\n"
			kill -TERM "${broker_pid}" >/dev/null 2>&1 || true
			break
			;;
		*"bind failed"*|*"listen (TLS) failed"*|*"listen failed"*)
			recover_reason="broker listen failure"
			printf "[broker] fail-safe: broker listen failure detected, cleaning port and retrying\n"
			kill -TERM "${broker_pid}" >/dev/null 2>&1 || true
			break
			;;
		esac
	done

	kill -TERM "${broker_pid}" >/dev/null 2>&1 || true
	wait "${broker_pid}" >/dev/null 2>&1 || true

	if [ -z "${recover_reason}" ]; then
		break
	fi

	kill_port_state
	if [ "${recover_reason}" = "TLS handshake timeout" ]; then
		run_reconnect
	else
		wait_port_available || sleep 2
	fi
	sleep 1
done
' bash "${broker_script}" "${connect_script}" "${IPSP_ADDR}" "${IPSP_ADDR_TYPE}" "${MQTT_PORT}" &
	BROKER_PID="$!"
	printf '[broker] supervisor started pid=%s\n' "${BROKER_PID}"
}

stop_broker()
{
	if ! broker_running; then
		BROKER_PID=""
		return 0
	fi

	printf '[broker] stopping pid=%s\n' "${BROKER_PID}"
	kill -TERM "-${BROKER_PID}" >/dev/null 2>&1 || kill "${BROKER_PID}" >/dev/null 2>&1 || true

	local deadline=$((SECONDS + BROKER_STOP_TIMEOUT_SEC))
	while kill -0 "${BROKER_PID}" >/dev/null 2>&1 && [ "${SECONDS}" -lt "${deadline}" ]; do
		sleep 0.2
	done
	if kill -0 "${BROKER_PID}" >/dev/null 2>&1; then
		printf '[broker] broker did not stop after %ss; killing process group\n' "${BROKER_STOP_TIMEOUT_SEC}" >&2
		kill -KILL "-${BROKER_PID}" >/dev/null 2>&1 || kill -KILL "${BROKER_PID}" >/dev/null 2>&1 || true
	fi
	wait "${BROKER_PID}" >/dev/null 2>&1 || true
	BROKER_PID=""

	if ! wait_broker_port_free; then
		printf '[broker] port %s is still busy after stopping broker:\n' "${MQTT_PORT}" >&2
		ss -ltnp "sport = :${MQTT_PORT}" >&2 || true
		return 1
	fi
}

restart_broker()
{
	stop_broker
	clean_broker_port
	start_broker
}

broker_status()
{
	if broker_running; then
		printf '[broker] running pid=%s\n' "${BROKER_PID}"
	else
		printf '[broker] not running from this console\n'
	fi
}

handle_broker_command()
{
	case "${1:-status}" in
	on | start)
		start_broker
		;;
	off | stop)
		stop_broker
		;;
	restart)
		restart_broker
		;;
	clean-port)
		clean_broker_port
		;;
	status)
		broker_status
		;;
	*)
		printf 'Unknown broker command: %s\n' "$1" >&2
		printf 'Use: broker on, broker off, broker restart, or broker status.\n' >&2
		return 1
		;;
	esac
}

print_status()
{
	cat <<EOF
[status] serial: ${TTY_DEVICE} @ ${BAUDRATE}
[status] mqtt: ${MQTT_HOST}:${MQTT_PORT}
[status] ca: ${MQTT_CAFILE}
[status] command topic: ${MQTT_COMMAND_TOPIC}
[status] telemetry topic: ${MQTT_TELEMETRY_TOPIC}
[status] mqtt insecure verify: ${MQTT_INSECURE}
[status] mqtt TLS version: ${MQTT_TLS_VERSION}
[status] ping timeout: ${PING_TIMEOUT_SEC}s
[status] ping capture iface: ${PING_CAPTURE_IFACE}
[status] pong encrypted log: ${PONG_LOG}
[status] pong TLS pcap: ${PONG_PCAP}
[status] pong log mode: ${PONG_LOG_MODE}
[status] default IPSP peer: ${IPSP_ADDR} addr_type=${IPSP_ADDR_TYPE}
[status] nrfutil: ${NRFUTIL}
[status] nRF serial number: ${SERIAL_NUMBER}
[status] nRF family: ${NRF_FAMILY}
[status] NCS version: ${NCS_VERSION}
[status] NCS chdir: ${NCS_CHDIR}
[status] board: ${BOARD}
[status] sysbuild: ${SYSBUILD}
[status] default PQC build mode: ${PQC}
[status] broker keylog build mode: ${BROKER_KEYLOG}
[status] OQS prefix: ${OQS_PREFIX}
[status] OpenSSL OQS config: ${OPENSSL_OQS_CONF}
EOF
	broker_status
}

start_serial_monitor()
{
	# Keep the board UART visible while the prompt accepts MQTT/IPSP commands.
	if [ ! -e "${TTY_DEVICE}" ]; then
		printf '[serial] warning: %s does not exist yet\n' "${TTY_DEVICE}" >&2
	fi

	if command -v tio >/dev/null 2>&1; then
		(
			tio --mute --timestamp "${TTY_DEVICE}" -b "${BAUDRATE}" < /dev/null 2>&1 |
				sed -u 's/^/[serial] /'
		) &
		SERIAL_PID="$!"
		return
	fi

	printf '[serial] tio not found, falling back to direct serial read\n'
	stty -F "${TTY_DEVICE}" "${BAUDRATE}" raw -echo -ixon -ixoff -crtscts
	(
		cat "${TTY_DEVICE}" 2>&1 | sed -u 's/^/[serial] /'
	) &
	SERIAL_PID="$!"
}

start_telemetry_monitor()
{
	local args=()
	local env_args=()

	# Optionally mirror telemetry in the same terminal as the serial logs.
	if [ "${SHOW_TELEMETRY}" != "1" ]; then
		return
	fi

	if ! check_oqs_runtime; then
		printf '[telemetry] OQS runtime is not ready; telemetry monitor not started\n' >&2
		return
	fi

	mapfile -t args < <(mqtt_args)
	mapfile -t env_args < <(mqtt_env_args)
	(
		env "${env_args[@]}" mosquitto_sub "${args[@]}" -t "${MQTT_TELEMETRY_TOPIC}" 2>&1 |
			sed -u 's/^/[telemetry] /'
	) &
	TELEMETRY_PID="$!"
}

main()
{
	local line

	require_command mosquitto_pub
	if [ "${SHOW_TELEMETRY}" = "1" ]; then
		require_command mosquitto_sub
	fi

	if [ ! -f "${MQTT_CAFILE}" ]; then
		printf 'CA file not found: %s\n' "${MQTT_CAFILE}" >&2
		exit 1
	fi
	if ! check_oqs_runtime; then
		exit 1
	fi

	trap cleanup EXIT INT TERM

	start_serial_monitor
	start_telemetry_monitor
	print_status
	printf '[help] type build, broker, connect, flash, on, off, toggle, ping, status, help, or quit\n'

	while true; do
		printf '> '
		if ! IFS= read -r line; then
			break
		fi

		set -- ${line}

		case "${1:-}" in
		build)
			shift
			if ! handle_build_command "$@"; then
				printf '[build] command failed\n' >&2
			fi
			;;
		connect)
			shift
			if ! run_ipsp_connect "$@"; then
				printf '[ipsp] connect failed\n' >&2
			fi
			;;
		broker)
			shift
			if ! handle_broker_command "$@"; then
				printf '[broker] command failed\n' >&2
			fi
			;;
		flash)
			shift
			if ! run_flash "$@"; then
				printf '[flash] command failed\n' >&2
			fi
			;;
		on)
			publish_led led:on
			;;
		off)
			publish_led led:off
			;;
		toggle)
			publish_led led:toggle
			;;
		ping)
			if ! ping_board; then
				printf '[ping] command failed\n' >&2
			fi
			;;
		status)
			print_status
			;;
		help)
			usage
			;;
		quit | exit | q)
			break
			;;
		"")
			;;
		*)
			printf 'Unknown command: %s\n' "${line}"
			printf 'Type help for available commands.\n'
			;;
		esac
	done
}

case "${1:-}" in
--docker | docker)
	shift
	if [ "$#" -gt 0 ]; then
		printf 'Docker console mode does not accept extra arguments yet: %s\n' "$*" >&2
		exit 1
	fi
	run_docker_console
	;;
--help | -h)
	usage
	;;
*)
	main "$@"
	;;
esac
