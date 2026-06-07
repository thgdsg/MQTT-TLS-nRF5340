#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
    printf 'Usage: sudo %s <BLE_ADDR> [addr_type]\n' "$0"
    printf 'Example: sudo %s AA:BB:CC:DD:EE:FF 2\n' "$0"
    exit 1
fi

BLE_ADDR="$1"
# Linux bluetooth_6lowpan expects the LE address type as a number.
# For the nRF5340 advertising as a random address, type 2 is the usual value.
ADDR_TYPE="${2:-2}"
DEBUGFS="/sys/kernel/debug"
BT_DEBUG="${DEBUGFS}/bluetooth"
LOWPAN_ENABLE="${BT_DEBUG}/6lowpan_enable"
LOWPAN_CONTROL="${BT_DEBUG}/6lowpan_control"

if [ "$(id -u)" -ne 0 ]; then
    printf 'This script must run as root. Use: sudo %s ...\n' "$0"
    exit 1
fi

# The Bluetooth 6LoWPAN control files are exposed through debugfs.
if ! mountpoint -q "${DEBUGFS}"; then
    mount -t debugfs none "${DEBUGFS}"
fi

# Ensure the host controller is powered before loading/enabling IPSP support.
systemctl start bluetooth 2>/dev/null || true
bluetoothctl power on >/dev/null 2>&1 || true
modprobe bluetooth_6lowpan

# If these files do not exist, the kernel module or debugfs setup failed.
if [ ! -w "${LOWPAN_ENABLE}" ] || [ ! -w "${LOWPAN_CONTROL}" ]; then
    printf 'Bluetooth 6LoWPAN control files are not available.\n'
    printf 'Expected:\n'
    printf '  %s\n' "${LOWPAN_ENABLE}"
    printf '  %s\n' "${LOWPAN_CONTROL}"
    printf '\nLoaded related modules:\n'
    lsmod | grep -E 'bluetooth_6lowpan|6lowpan|bluetooth' || true
    exit 1
fi

printf 'Enabling Bluetooth 6LoWPAN...\n'
printf '1\n' > "${LOWPAN_ENABLE}"

# Print the cached bluetoothctl view before connecting. This is useful to
# confirm the address type, bonding state, and IPSP service UUID.
printf '\nBluetooth info for %s:\n' "${BLE_ADDR}"
bluetoothctl info "${BLE_ADDR}" || true
printf '\n'

# Clear stale BLE/6LoWPAN state so repeated test runs start cleanly.
printf 'Clearing any previous BLE connection to %s...\n' "${BLE_ADDR}"
bluetoothctl disconnect "${BLE_ADDR}" >/dev/null 2>&1 || true
printf 'disconnect %s %s\n' "${BLE_ADDR}" "${ADDR_TYPE}" > "${LOWPAN_CONTROL}" 2>/dev/null || true
sleep 1

# This asks the Linux kernel IPSP implementation to create a bt0 netdev for
# the peer. The firmware must be advertising the Internet Protocol Support UUID.
printf 'Connecting IPSP peer %s addr_type=%s...\n' "${BLE_ADDR}" "${ADDR_TYPE}"
printf 'connect %s %s\n' "${BLE_ADDR}" "${ADDR_TYPE}" > "${LOWPAN_CONTROL}"

# bt0 appears asynchronously after the BLE L2CAP/IPSP setup completes.
for _ in $(seq 1 80); do
    if ip link show bt0 >/dev/null 2>&1; then
        break
    fi
    sleep 0.25
done

if ! ip link show bt0 >/dev/null 2>&1; then
    printf 'bt0 was not created after the IPSP connect request.\n'
    printf '\nCurrent Bluetooth controllers:\n'
    bluetoothctl list || true
    printf '\nBluetooth devices seen by bluetoothctl:\n'
    bluetoothctl devices || true
    printf '\nRecent kernel Bluetooth/6LoWPAN messages:\n'
    dmesg | tail -n 80 | grep -Ei 'bluetooth|6lowpan|l2cap|bt0|hci' || true
    printf '\nTry scanning with: bluetoothctl scan le\n'
    exit 1
fi

# The board firmware uses 2001:db8::1; the host side of this IPSP link is
# 2001:db8::2 and runs the MQTT/TLS broker on port 8883.
ip link set bt0 up
ip address add 2001:db8::2/64 dev bt0 2>/dev/null || true
ip address show dev bt0
