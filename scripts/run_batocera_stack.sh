#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERMIND_DIR="$ROOT_DIR/batocera.overmind"
DRONE_DIR="$ROOT_DIR/batocera.drone"
PYTHON_BIN="$OVERMIND_DIR/.venv/bin/python"
DRONE_FAKE_USERDATA_ROOT="$DRONE_DIR/local-data/mock-userdata"

OVERMIND_PORT="${OVERMIND_PORT:-8000}"
DRONE_PORT="${DRONE_PORT:-8443}"
STOP_TIMEOUT_SECONDS="${STOP_TIMEOUT_SECONDS:-5}"

OVERMIND_PID=""
DRONE_PID=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--kill-existing]

Starts both local Batocera apps:
  Overmind: http://localhost:${OVERMIND_PORT}
  Drone:    http://localhost:${DRONE_PORT}

Fake data is forced on for both apps.

Options:
  --kill-existing   Kill current listeners on ${OVERMIND_PORT}/${DRONE_PORT} before starting.
USAGE
}

port_in_use() {
  local port="$1"
  lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

kill_port() {
  local port="$1"
  local pids
  pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    echo "Stopping existing process on port $port"
    echo "$pids" | xargs kill
  fi
}

kill_process_tree() {
  local pid="$1"
  local signal="${2:-TERM}"
  local child

  if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi

  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_process_tree "$child" "$signal"
  done

  kill "-$signal" "$pid" >/dev/null 2>&1 || true
}

kill_child_processes() {
  local pid="$1"
  local signal="${2:-TERM}"
  local child

  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_process_tree "$child" "$signal"
  done
}

wait_for_exit() {
  local pid="$1"
  local deadline=$((SECONDS + STOP_TIMEOUT_SECONDS))

  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 0.2
  done

  return 0
}

stop_process_tree() {
  local name="$1"
  local pid="$2"

  if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi

  echo "Stopping $name..."
  kill_child_processes "$pid" TERM
  if wait_for_exit "$pid"; then
    wait "$pid" >/dev/null 2>&1 || true
    return 0
  else
    echo "$name did not stop after ${STOP_TIMEOUT_SECONDS}s; forcing it down..."
    kill_process_tree "$pid" KILL
    wait "$pid" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  trap - INT TERM EXIT
  echo
  echo "Stopping Batocera stack..."
  stop_process_tree "Overmind" "$OVERMIND_PID"
  stop_process_tree "Drone" "$DRONE_PID"
  wait "$OVERMIND_PID" "$DRONE_PID" >/dev/null 2>&1 || true
}

require_file() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "Missing required path: $path" >&2
    exit 1
  fi
}

KILL_EXISTING=false
for arg in "$@"; do
  case "$arg" in
    --kill-existing)
      KILL_EXISTING=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      usage
      exit 1
      ;;
  esac
done

require_file "$PYTHON_BIN"
require_file "$DRONE_DIR/app/main.py"
require_file "$OVERMIND_DIR/src/overmind/main.py"

if [[ "$KILL_EXISTING" == true ]]; then
  kill_port "$OVERMIND_PORT"
  kill_port "$DRONE_PORT"
fi

if port_in_use "$OVERMIND_PORT"; then
  echo "Port $OVERMIND_PORT is already in use. Stop that process or rerun with --kill-existing." >&2
  exit 1
fi

if port_in_use "$DRONE_PORT"; then
  echo "Port $DRONE_PORT is already in use. Stop that process or rerun with --kill-existing." >&2
  exit 1
fi

trap cleanup INT TERM EXIT

echo "Starting Batocera Drone on http://localhost:${DRONE_PORT}"
(
  cd "$DRONE_DIR"
  ROM_API_USERNAME="${ROM_API_USERNAME:-admin}" \
  ROM_API_PASSWORD="${ROM_API_PASSWORD:-changeme}" \
  HTTPS_PORT="$DRONE_PORT" \
  HTTP_ONLY="${HTTP_ONLY:-true}" \
  USE_FAKE_DATA="true" \
  USERDATA_ROOT="$DRONE_FAKE_USERDATA_ROOT" \
  ROMS_ROOT="$DRONE_FAKE_USERDATA_ROOT/roms" \
  BIOS_ROOT="$DRONE_FAKE_USERDATA_ROOT/bios" \
  THEMES_ROOT="$DRONE_FAKE_USERDATA_ROOT/themes" \
  BATOCERA_CONF_FILE="$DRONE_FAKE_USERDATA_ROOT/system/batocera.conf" \
  ES_SETTINGS_FILE="$DRONE_FAKE_USERDATA_ROOT/system/configs/emulationstation/es_settings.cfg" \
  TLS_SELF_SIGNED_DIR="${TLS_SELF_SIGNED_DIR:-$DRONE_DIR/local-data/certs}" \
  LOG_DIR="${LOG_DIR:-$DRONE_DIR/local-data/logs}" \
  OVERMIND_URL="${OVERMIND_URL:-http://localhost:${OVERMIND_PORT}}" \
  OVERMIND_EMAIL="${OVERMIND_EMAIL:-demo@example.com}" \
  OVERMIND_PASSWORD="${OVERMIND_PASSWORD:-DemoPass123}" \
  OVERMIND_DEVICE_ID="${OVERMIND_DEVICE_ID:-local-dev-drone}" \
  OVERMIND_POLL_SECONDS="${OVERMIND_POLL_SECONDS:-60}" \
  "$PYTHON_BIN" "$DRONE_DIR/app/main.py"
) &
DRONE_PID="$!"

echo "Starting Batocera Overmind on http://localhost:${OVERMIND_PORT}"
(
  cd "$OVERMIND_DIR"
  PYTHONPATH="$OVERMIND_DIR/src" \
  USE_FAKE_DATA="true" \
  "$PYTHON_BIN" -m uvicorn overmind.main:app --reload --host 0.0.0.0 --port "$OVERMIND_PORT"
) &
OVERMIND_PID="$!"

cat <<INFO

Batocera stack is starting.
  Overmind: http://localhost:${OVERMIND_PORT}
  Drone:    http://localhost:${DRONE_PORT}
  Fake data: forced on
  Drone fake data root: ${DRONE_FAKE_USERDATA_ROOT}

Drone auth:
  Username: ${ROM_API_USERNAME:-admin}
  Password: ${ROM_API_PASSWORD:-changeme}

Overmind demo login:
  Email:    demo@example.com
  Password: DemoPass123

Drone fake integration login:
  Email:    ${OVERMIND_EMAIL:-arcade@example.com}
  Password: ${OVERMIND_PASSWORD:-ArcadePass123}
  Device:   ${OVERMIND_DEVICE_ID:-arcade-cabinet-002}

Press Ctrl+C to stop both apps.
INFO

wait "$OVERMIND_PID" "$DRONE_PID"
