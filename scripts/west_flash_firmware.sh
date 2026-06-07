#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIRMWARE_DIR="${ROOT_DIR}/firmware"
NRFUTIL="${NRFUTIL:-/home/thiago/.local/bin/nrfutil}"
NCS_VERSION="${NCS_VERSION:-v2.6.0}"
export PATH="${ROOT_DIR}/tools:${PATH}"
export REAL_NRFUTIL="${NRFUTIL}"

if [ ! -x "${NRFUTIL}" ]; then
    printf 'nrfutil not found at %s\n' "${NRFUTIL}"
    printf 'Set NRFUTIL=/path/to/nrfutil or add nrfutil to PATH.\n'
    exit 1
fi

exec "${NRFUTIL}" sdk-manager toolchain launch \
    --ncs-version "${NCS_VERSION}" \
    --chdir "${FIRMWARE_DIR}" \
    -- west flash -d build --runner nrfutil "$@"
