#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.server.yml"

compose_cmd=()

if docker compose version >/dev/null 2>&1; then
    compose_cmd=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    compose_cmd=(docker-compose)
else
    cat >&2 <<'EOF'
Docker Compose was not found.

On Arch/CachyOS, install it with:
  sudo pacman -S docker docker-compose

Then enable Docker:
  sudo systemctl enable --now docker

Check with:
  docker compose version
  docker-compose version
EOF
    exit 1
fi

if [ "$#" -eq 0 ]; then
    cat <<EOF
Usage: $(basename "$0") <compose args>

Examples:
  $(basename "$0") build
  $(basename "$0") run --rm ipsp-server setup
  $(basename "$0") run --rm ipsp-server broker
EOF
    exit 0
fi

exec "${compose_cmd[@]}" -f "${COMPOSE_FILE}" "$@"
