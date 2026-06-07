#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_DIR="${ROOT_DIR}/modules"

mkdir -p "${MODULE_DIR}"

if [ ! -d "${MODULE_DIR}/wolfssl/.git" ]; then
    git clone --depth 1 https://github.com/wolfSSL/wolfssl.git "${MODULE_DIR}/wolfssl"
else
    git -C "${MODULE_DIR}/wolfssl" pull --ff-only
fi

if [ ! -d "${MODULE_DIR}/wolfmqtt/.git" ]; then
    git clone --depth 1 https://github.com/wolfSSL/wolfMQTT.git "${MODULE_DIR}/wolfmqtt"
else
    git -C "${MODULE_DIR}/wolfmqtt" pull --ff-only
fi

printf 'wolfSSL:  %s\n' "${MODULE_DIR}/wolfssl"
printf 'wolfMQTT: %s\n' "${MODULE_DIR}/wolfmqtt"
