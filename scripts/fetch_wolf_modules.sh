#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_DIR="${ROOT_DIR}/modules"
UPDATE="${UPDATE_WOLF_MODULES:-0}"

usage()
{
    cat <<EOF
Usage: $(basename "$0") [--update]

Without --update, this script only clones missing wolfSSL/wolfMQTT modules.
Existing modules are left untouched so local project patches are preserved.

Options:
  --update   run git pull --ff-only in existing clean module checkouts
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
    --update)
        UPDATE=1
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
done

update_module()
{
    local dir="$1"
    local name="$2"

    if [ "${UPDATE}" != "1" ]; then
        printf '%s already exists; leaving it untouched. Use --update to pull.\n' "${name}"
        return
    fi

    if [ -n "$(git -C "${dir}" status --porcelain)" ]; then
        printf '%s has local changes; refusing to pull:\n' "${name}" >&2
        git -C "${dir}" status --short >&2
        printf 'Commit, stash, or reset that module before using --update.\n' >&2
        return 1
    fi

    git -C "${dir}" pull --ff-only
}

mkdir -p "${MODULE_DIR}"

if [ ! -d "${MODULE_DIR}/wolfssl/.git" ]; then
    git clone --depth 1 https://github.com/wolfSSL/wolfssl.git "${MODULE_DIR}/wolfssl"
else
    update_module "${MODULE_DIR}/wolfssl" wolfSSL
fi

if [ ! -d "${MODULE_DIR}/wolfmqtt/.git" ]; then
    git clone --depth 1 https://github.com/wolfSSL/wolfMQTT.git "${MODULE_DIR}/wolfmqtt"
else
    update_module "${MODULE_DIR}/wolfmqtt" wolfMQTT
fi

printf 'wolfSSL:  %s\n' "${MODULE_DIR}/wolfssl"
printf 'wolfMQTT: %s\n' "${MODULE_DIR}/wolfmqtt"
