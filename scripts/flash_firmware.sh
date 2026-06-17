#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIRMWARE_DIR="${ROOT_DIR}/firmware"
NRFUTIL="${NRFUTIL:-/home/thiago/.local/bin/nrfutil}"
SERIAL_NUMBER="${SERIAL_NUMBER:-auto}"
NRF_FAMILY="${NRF_FAMILY:-nrf52}"
SWD_CLOCK_FREQUENCY="${SWD_CLOCK_FREQUENCY:-1000}"

if [ ! -x "${NRFUTIL}" ]; then
    printf 'nrfutil not found at %s\n' "${NRFUTIL}"
    printf 'Set NRFUTIL=/path/to/nrfutil or add nrfutil to PATH.\n'
    exit 1
fi

resolve_serial_number()
{
    local devices
    local serials

    if [ "${SERIAL_NUMBER}" != "auto" ]; then
        printf '%s\n' "${SERIAL_NUMBER}"
        return 0
    fi

    devices="$("${NRFUTIL}" device list)"
    serials="$(printf '%s\n' "${devices}" | sed -n 's/^\([0-9][0-9]*\)$/\1/p')"

    if [ "$(printf '%s\n' "${serials}" | sed '/^$/d' | wc -l)" -ne 1 ]; then
        printf 'Could not auto-detect exactly one nRF device.\n' >&2
        printf 'Set SERIAL_NUMBER=<serial> and try again.\n' >&2
        printf 'Connected devices:\n%s\n' "${devices}" >&2
        return 1
    fi

    printf '%s\n' "${serials}"
}

find_app_hex()
{
    local candidate

    for candidate in \
        "${FIRMWARE_DIR}/build/merged.hex" \
        "${FIRMWARE_DIR}/build/zephyr/merged.hex" \
        "${FIRMWARE_DIR}/build/zephyr/zephyr.hex"
    do
        if [ -f "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

SERIAL_NUMBER="$(resolve_serial_number)"
APP_HEX="$(find_app_hex || true)"

if [ -z "${APP_HEX}" ]; then
    printf 'Firmware HEX files not found.\n'
    printf 'Build first from %s.\n' "${FIRMWARE_DIR}"
    exit 1
fi

printf 'Programming %s firmware: %s\n' "${NRF_FAMILY}" "${APP_HEX}"
"${NRFUTIL}" device program \
    --serial-number "${SERIAL_NUMBER}" \
    --family "${NRF_FAMILY}" \
    --firmware "${APP_HEX}" \
    --options chip_erase_mode=ERASE_ALL,verify=VERIFY_READ,reset=RESET_NONE \
    --swd-clock-frequency "${SWD_CLOCK_FREQUENCY}" \
    "$@"

printf 'Resetting device %s\n' "${SERIAL_NUMBER}"
"${NRFUTIL}" device reset \
    --serial-number "${SERIAL_NUMBER}" \
    --family "${NRF_FAMILY}"
