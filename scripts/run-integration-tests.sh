#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/.github/docker/docker-compose.swarm.yml"

if [[ "${USE_EXISTING_SWARM:-false}" != "true" ]]; then
  DRONE_HEARTBEAT_SECONDS="${DRONE_HEARTBEAT_SECONDS:-5}" \
  OVERMIND_SPEED_SAMPLE_SECONDS="${OVERMIND_SPEED_SAMPLE_SECONDS:-5}" \
    docker compose -f "$COMPOSE_FILE" up -d --build
fi

python3 -m unittest discover "$ROOT_DIR/.github/tests" "$@"
