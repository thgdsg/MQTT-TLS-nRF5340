#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIRMWARE_DIR="${ROOT_DIR}/firmware"
NRFUTIL="${NRFUTIL:-/home/thiago/.local/bin/nrfutil}"
SERIAL_NUMBER="${SERIAL_NUMBER:-1050032722}"
SWD_CLOCK_FREQUENCY="${SWD_CLOCK_FREQUENCY:-1000}"
APP_HEX="${FIRMWARE_DIR}/build/merged.hex"
NET_HEX="${FIRMWARE_DIR}/build/merged_CPUNET.hex"

if [ ! -x "${NRFUTIL}" ]; then
    printf 'nrfutil not found at %s\n' "${NRFUTIL}"
    printf 'Set NRFUTIL=/path/to/nrfutil or add nrfutil to PATH.\n'
    exit 1
fi

if [ ! -f "${APP_HEX}" ] || [ ! -f "${NET_HEX}" ]; then
    printf 'Firmware HEX files not found.\n'
    printf 'Build first from %s.\n' "${FIRMWARE_DIR}"
    exit 1
fi

printf 'Programming application core: %s\n' "${APP_HEX}"
"${NRFUTIL}" device program \
    --serial-number "${SERIAL_NUMBER}" \
    --family nrf53 \
    --core application \
    --firmware "${APP_HEX}" \
    --options chip_erase_mode=ERASE_ALL,verify=VERIFY_READ,reset=RESET_NONE \
    --swd-clock-frequency "${SWD_CLOCK_FREQUENCY}" \
    "$@"

printf 'Programming network core: %s\n' "${NET_HEX}"
"${NRFUTIL}" device program \
    --serial-number "${SERIAL_NUMBER}" \
    --family nrf53 \
    --core network \
    --firmware "${NET_HEX}" \
    --options chip_erase_mode=ERASE_ALL,verify=VERIFY_READ,reset=RESET_NONE \
    --swd-clock-frequency "${SWD_CLOCK_FREQUENCY}" \
    "$@"

printf 'Resetting device %s\n' "${SERIAL_NUMBER}"
"${NRFUTIL}" device reset \
    --serial-number "${SERIAL_NUMBER}" \
    --family nrf53
