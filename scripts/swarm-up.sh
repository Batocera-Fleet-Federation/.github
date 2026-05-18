#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/.github/docker/docker-compose.swarm.yml"
ROM_ROOT="$ROOT_DIR/.github/data/roms"

if ! find "$ROM_ROOT" -type f ! -name ".gitkeep" ! -name "README.md" | grep -q .; then
  cat >&2 <<EOF
No ROM files found in $ROM_ROOT.
Import or place test ROMs under .github/data/roms/<system>/<files> first.
You can run: .github/scripts/import-roms-remotely.sh
EOF
  exit 1
fi

docker compose -f "$COMPOSE_FILE" up -d --build "$@"
