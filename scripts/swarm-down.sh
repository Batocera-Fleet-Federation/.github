#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/.github/docker/docker-compose.swarm.yml"

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

docker compose -f "$COMPOSE_FILE" down "$@"
remove_swarm_hosts
