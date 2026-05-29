#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/.github/docker/docker-compose.swarm.yml"

POSTGRES_CONTAINER_NAME="${POSTGRES_CONTAINER_NAME:-bff-postgres}"
REMOVE_POSTGRES_VOLUME="${REMOVE_POSTGRES_VOLUME:-true}"
POSTGRES_VOLUME_NAME="${POSTGRES_VOLUME_NAME:-docker_postgres-data}"

remove_swarm_hosts() {
  local marker_start="# BEGIN batocera-fleet-federation swarm hosts"
  local marker_end="# END batocera-fleet-federation swarm hosts"
  local tmp_file

  tmp_file="$(mktemp)"

  awk \
    -v marker_start="$marker_start" \
    -v marker_end="$marker_end" \
    'BEGIN { skip = 0 }
     $0 == marker_start { skip = 1; next }
     $0 == marker_end { skip = 0; next }
     skip == 0 { print }' \
    /etc/hosts > "$tmp_file"

  if ! cmp -s /etc/hosts "$tmp_file"; then
    echo "Removing local swarm hostnames from /etc/hosts. sudo may prompt for your password."
    sudo cp "$tmp_file" /etc/hosts
  else
    echo "No local swarm hostnames found in /etc/hosts."
  fi

  rm -f "$tmp_file"
}


remove_swarm_postgres_container() {
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${POSTGRES_CONTAINER_NAME}$"; then
    echo "Removing swarm PostgreSQL container '${POSTGRES_CONTAINER_NAME}'..."
    docker rm -f "${POSTGRES_CONTAINER_NAME}" >/dev/null 2>&1 || true
  else
    echo "No swarm PostgreSQL container named '${POSTGRES_CONTAINER_NAME}' found."
  fi

  if [[ "$REMOVE_POSTGRES_VOLUME" == "true" ]]; then
    if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -q "^${POSTGRES_VOLUME_NAME}$"; then
      echo "Removing swarm PostgreSQL volume '${POSTGRES_VOLUME_NAME}'..."
      docker volume rm "${POSTGRES_VOLUME_NAME}" >/dev/null 2>&1 || true
    else
      echo "No swarm PostgreSQL volume named '${POSTGRES_VOLUME_NAME}' found."
    fi
  else
    echo "Leaving swarm PostgreSQL volume intact because REMOVE_POSTGRES_VOLUME=false."
  fi
}

docker compose -f "$COMPOSE_FILE" down "$@"
remove_swarm_postgres_container
remove_swarm_hosts
