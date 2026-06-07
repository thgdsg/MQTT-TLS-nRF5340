#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Runtime defaults. Override any of these as environment variables.
TTY_DEVICE="${TTY_DEVICE:-/dev/ttyACM1}"
BAUDRATE="${BAUDRATE:-115200}"
MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
MQTT_PORT="${MQTT_PORT:-8883}"
MQTT_CAFILE="${MQTT_CAFILE:-${ROOT_DIR}/host/certs/ca.crt}"
MQTT_COMMAND_TOPIC="${MQTT_COMMAND_TOPIC:-nrf5340/command}"
MQTT_TELEMETRY_TOPIC="${MQTT_TELEMETRY_TOPIC:-nrf5340/telemetry}"
MQTT_INSECURE="${MQTT_INSECURE:-1}"
SHOW_TELEMETRY="${SHOW_TELEMETRY:-1}"
IPSP_ADDR="${IPSP_ADDR:-F8:69:5E:1E:CE:2F}"
IPSP_ADDR_TYPE="${IPSP_ADDR_TYPE:-2}"
NRFUTIL="${NRFUTIL:-/home/thiago/.local/bin/nrfutil}"
SERIAL_NUMBER="${SERIAL_NUMBER:-1050032722}"
NCS_VERSION="${NCS_VERSION:-v2.6.0}"
NCS_CHDIR="${NCS_CHDIR:-/home/thiago/ncs/v2.6.0/nrf}"
BOARD="${BOARD:-nrf5340dk_nrf5340_cpuapp_ns}"

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
Usage: $(basename "$0")

Environment overrides:
  TTY_DEVICE=${TTY_DEVICE}
  BAUDRATE=${BAUDRATE}
  MQTT_HOST=${MQTT_HOST}
  MQTT_PORT=${MQTT_PORT}
  MQTT_CAFILE=${MQTT_CAFILE}
  MQTT_COMMAND_TOPIC=${MQTT_COMMAND_TOPIC}
  MQTT_TELEMETRY_TOPIC=${MQTT_TELEMETRY_TOPIC}
  MQTT_INSECURE=${MQTT_INSECURE}
  SHOW_TELEMETRY=${SHOW_TELEMETRY}
  IPSP_ADDR=${IPSP_ADDR}
  IPSP_ADDR_TYPE=${IPSP_ADDR_TYPE}
  NRFUTIL=${NRFUTIL}
  SERIAL_NUMBER=${SERIAL_NUMBER}
  NCS_VERSION=${NCS_VERSION}
  NCS_CHDIR=${NCS_CHDIR}
  BOARD=${BOARD}

Interactive commands:
  build broker
           build host/build/wolfmqtt-broker
  build firmware
           build firmware/build/merged.hex and merged_CPUNET.hex
  connect [mac] [random|public|1|2]
           run host/ipsp_connect.sh. Defaults: ${IPSP_ADDR} ${IPSP_ADDR_TYPE}
  broker on|off|restart|status
           start, stop, restart, or inspect the local wolfMQTT TLS broker
  flash    flash firmware after checking USB/J-Link connection
  on       publish led:on
  off      publish led:off
  toggle   publish led:toggle
  status   print current connection settings
  help     show this help
  quit     stop monitor and exit
EOF
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

	if [ ! -x "${build_script}" ]; then
		printf '[build] broker build script not found or not executable: %s\n' "${build_script}" >&2
		return 1
	fi

	printf '[build] building broker\n'
	"${build_script}"
}

run_build_firmware()
{
	if [ ! -x "${NRFUTIL}" ]; then
		printf '[build] nrfutil not found at %s\n' "${NRFUTIL}" >&2
		return 1
	fi

	printf '[build] building firmware with NCS %s board %s\n' "${NCS_VERSION}" "${BOARD}"
	env SHELL=/bin/bash "${NRFUTIL}" sdk-manager toolchain launch \
		--ncs-version "${NCS_VERSION}" \
		--chdir "${NCS_CHDIR}" \
		-- west build \
		-d "${ROOT_DIR}/firmware/build" \
		-b "${BOARD}" \
		--sysbuild \
		-p always \
		"${ROOT_DIR}/firmware"
}

handle_build_command()
{
	case "${1:-}" in
	broker)
		run_build_broker
		;;
	firmware)
		run_build_firmware
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
	if [ "${MQTT_INSECURE}" = "1" ]; then
		printf '%s\n' --insecure
	fi
}

publish_led()
{
	local payload="$1"
	local args=()

	# Publish short prompt commands as the firmware's MQTT command payloads.
	mapfile -t args < <(mqtt_args)
	if mosquitto_pub "${args[@]}" -t "${MQTT_COMMAND_TOPIC}" -m "${payload}"; then
		printf '[mqtt] sent %s -> %s\n' "${MQTT_COMMAND_TOPIC}" "${payload}"
	else
		printf '[mqtt] publish failed for payload: %s\n' "${payload}" >&2
	fi
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

	if printf '%s\n' "${devices}" | grep -q "^${SERIAL_NUMBER}$"; then
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
	if NRFUTIL="${NRFUTIL}" SERIAL_NUMBER="${SERIAL_NUMBER}" "${flash_script}" "$@"; then
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

start_broker()
{
	local broker_script="${ROOT_DIR}/host/run_wolf_broker.sh"

	if broker_running; then
		printf '[broker] already running pid=%s\n' "${BROKER_PID}"
		return 0
	fi

	if [ ! -x "${broker_script}" ]; then
		printf '[broker] broker script not found or not executable: %s\n' "${broker_script}" >&2
		return 1
	fi
	if ! command -v setsid >/dev/null 2>&1; then
		printf '[broker] setsid not found; install util-linux\n' >&2
		return 1
	fi

	# Run the TLS broker in its own process group so broker off can stop it.
	setsid bash -c '"$1" 2>&1 | sed -u "s/^/[broker] /"' bash "${broker_script}" &
	BROKER_PID="$!"
	printf '[broker] started pid=%s\n' "${BROKER_PID}"
}

stop_broker()
{
	if ! broker_running; then
		BROKER_PID=""
		return 0
	fi

	printf '[broker] stopping pid=%s\n' "${BROKER_PID}"
	kill -TERM "-${BROKER_PID}" >/dev/null 2>&1 || kill "${BROKER_PID}" >/dev/null 2>&1 || true
	wait "${BROKER_PID}" >/dev/null 2>&1 || true
	BROKER_PID=""
}

restart_broker()
{
	stop_broker
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
[status] default IPSP peer: ${IPSP_ADDR} addr_type=${IPSP_ADDR_TYPE}
[status] nrfutil: ${NRFUTIL}
[status] nRF serial number: ${SERIAL_NUMBER}
[status] NCS version: ${NCS_VERSION}
[status] NCS chdir: ${NCS_CHDIR}
[status] board: ${BOARD}
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

	# Optionally mirror telemetry in the same terminal as the serial logs.
	if [ "${SHOW_TELEMETRY}" != "1" ]; then
		return
	fi

	mapfile -t args < <(mqtt_args)
	(
		mosquitto_sub "${args[@]}" -t "${MQTT_TELEMETRY_TOPIC}" 2>&1 |
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

	trap cleanup EXIT INT TERM

	start_serial_monitor
	start_telemetry_monitor
	print_status
	printf '[help] type build, broker, connect, flash, on, off, toggle, status, help, or quit\n'

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

main "$@"
