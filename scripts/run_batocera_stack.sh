#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OVERMIND_DIR="$ROOT_DIR/batocera.overmind"
DRONE_DIR="$ROOT_DIR/batocera.drone"
OVERMIND_PYTHON_BIN="$OVERMIND_DIR/.venv/bin/python"
DRONE_PYTHON_BIN="$DRONE_DIR/.venv/bin/python"
DRONE_FAKE_USERDATA_ROOT="$DRONE_DIR/local-data/mock-userdata"

OVERMIND_PORT="${OVERMIND_PORT:-8000}"
DRONE_PORT="${DRONE_PORT:-8443}"
STOP_TIMEOUT_SECONDS="${STOP_TIMEOUT_SECONDS:-5}"
BASE_PYTHON_BIN="${BASE_PYTHON_BIN:-python3}"
OVERMIND_TLS_DIR="${OVERMIND_TLS_DIR:-$OVERMIND_DIR/local-data/certs}"
OVERMIND_TLS_KEY_FILE="${OVERMIND_TLS_KEY_FILE:-$OVERMIND_TLS_DIR/server.key}"
OVERMIND_TLS_CERT_FILE="${OVERMIND_TLS_CERT_FILE:-$OVERMIND_TLS_DIR/server.crt}"
LOCAL_MTLS_CERTS_DIR="${LOCAL_MTLS_CERTS_DIR:-$ROOT_DIR/.github/local-certs}"
LOCAL_DRONE_ID="${LOCAL_DRONE_ID:-local-drone}"
LOCAL_DRONE_CERT_DIR="${LOCAL_DRONE_CERT_DIR:-$LOCAL_MTLS_CERTS_DIR/drones/$LOCAL_DRONE_ID}"
DRONE_MTLS_CA_FILE="${DRONE_MTLS_CA_FILE:-$LOCAL_DRONE_CERT_DIR/ca.crt}"
DRONE_TLS_KEY_FILE="${DRONE_TLS_KEY_FILE:-$LOCAL_DRONE_CERT_DIR/drone.key}"
DRONE_TLS_CERT_FILE="${DRONE_TLS_CERT_FILE:-$LOCAL_DRONE_CERT_DIR/drone.crt}"
DRONE_CERT_FILE="${DRONE_CERT_FILE:-$DRONE_TLS_CERT_FILE}"
DRONE_KEY_FILE="${DRONE_KEY_FILE:-$DRONE_TLS_KEY_FILE}"
DRONE_FALLBACK_REQUIREMENTS="${DRONE_FALLBACK_REQUIREMENTS:-fastapi uvicorn[standard] pydantic pydantic-settings python-multipart requests aiofiles}"

OVERMIND_PID=""
DRONE_PID=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--kill-existing]

Starts both local Batocera apps:
  Overmind: https://localhost:${OVERMIND_PORT}
  Drone:    https://localhost:${DRONE_PORT}

Fake data is off by default. Set USE_FAKE_DATA=true to enable demo data.

Options:
  --kill-existing   Kill current listeners on ${OVERMIND_PORT}/${DRONE_PORT} before starting.

The script creates or repairs missing .venv directories, installs dependencies, installs Drone fallback dependencies when needed, verifies imports, and generates local TLS certs when needed.
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

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

ensure_openssl_cert() {
  local cert_dir="$1"
  local key_file="$2"
  local cert_file="$3"

  mkdir -p "$cert_dir"

  if [[ -s "$key_file" && -s "$cert_file" ]]; then
    echo "Using existing TLS cert: $cert_file"
    return 0
  fi

  require_command openssl

  echo "Generating self-signed TLS cert for localhost..."
  openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "$key_file" \
    -out "$cert_file" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
}

verify_python_module() {
  local name="$1"
  local python_bin="$2"
  local module_name="$3"

  echo "Verifying $name module import: $module_name"
  if ! "$python_bin" -c "import ${module_name}" >/dev/null 2>&1; then
    echo "$name could not import module: $module_name" >&2
    echo "Python: $python_bin" >&2
    exit 1
  fi
}

ensure_python_project_env() {
  local name="$1"
  local project_dir="$2"
  local python_bin="$project_dir/.venv/bin/python"
  local pip_bin="$project_dir/.venv/bin/pip"

  if [[ ! -d "$project_dir" ]]; then
    echo "Missing project directory for $name: $project_dir" >&2
    exit 1
  fi

  if [[ ! -x "$python_bin" || ! -x "$pip_bin" ]]; then
    echo "Creating Python virtual environment for $name..."
    rm -rf "$project_dir/.venv"
    (cd "$project_dir" && "$BASE_PYTHON_BIN" -m venv .venv)
  fi

  if [[ ! -x "$python_bin" ]]; then
    echo "Missing Python in $name virtual environment: $python_bin" >&2
    exit 1
  fi

  if [[ ! -x "$pip_bin" ]]; then
    echo "Missing pip in $name virtual environment: $pip_bin" >&2
    exit 1
  fi

  echo "Using $name Python: $($python_bin --version 2>&1)"
  echo "Upgrading Python packaging tools for $name..."
  "$python_bin" -m pip install --upgrade pip setuptools wheel

  if [[ -f "$project_dir/requirements.txt" ]]; then
    echo "Installing $name dependencies from requirements.txt..."
    "$python_bin" -m pip install -r "$project_dir/requirements.txt"
  fi

  if [[ -f "$project_dir/pyproject.toml" ]]; then
    echo "Installing $name project in editable mode..."
    "$python_bin" -m pip install -e "$project_dir"
  fi

  if [[ ! -f "$project_dir/requirements.txt" && ! -f "$project_dir/pyproject.toml" ]]; then
    if [[ "$name" == "Drone" ]]; then
      echo "No requirements.txt or pyproject.toml found for Drone; installing fallback runtime dependencies..."
      "$python_bin" -m pip install $DRONE_FALLBACK_REQUIREMENTS
    else
      echo "No requirements.txt or pyproject.toml found for $name at $project_dir; continuing with virtual environment only."
    fi
  fi
}

ensure_runtime_envs() {
  require_command "$BASE_PYTHON_BIN"

  ensure_python_project_env "Overmind" "$OVERMIND_DIR"
  ensure_python_project_env "Drone" "$DRONE_DIR"

  echo "Ensuring Overmind runtime dependencies are installed..."
  "$OVERMIND_PYTHON_BIN" -m pip install "uvicorn[standard]"

  verify_python_module "Overmind" "$OVERMIND_PYTHON_BIN" "uvicorn"
  PYTHONPATH="$OVERMIND_DIR/src" verify_python_module "Overmind" "$OVERMIND_PYTHON_BIN" "overmind.main"

  verify_python_module "Drone" "$DRONE_PYTHON_BIN" "fastapi"
  verify_python_module "Drone" "$DRONE_PYTHON_BIN" "uvicorn"

  ensure_openssl_cert "$OVERMIND_TLS_DIR" "$OVERMIND_TLS_KEY_FILE" "$OVERMIND_TLS_CERT_FILE"
}

provision_local_drone_mtls_certs() {
  local provision_script="$SCRIPT_DIR/provision-local-mtls-certs.sh"
  local cert_modulus
  local key_modulus

  require_command openssl

  if [[ ! -x "$provision_script" ]]; then
    echo "Missing or non-executable local mTLS provisioning script: $provision_script" >&2
    echo "Expected this script to provision certs outside the Drone runtime." >&2
    exit 1
  fi

  echo "Provisioning local Drone mTLS certs for $LOCAL_DRONE_ID..."
  LOCAL_MTLS_CERTS_DIR="$LOCAL_MTLS_CERTS_DIR" \
  LOCAL_DRONE_ID="$LOCAL_DRONE_ID" \
  HOSTNAME_OVERRIDE="${HOSTNAME_OVERRIDE:-localhost,local-drone,batocera.local}" \
  "$provision_script" --profile local

  require_file "$DRONE_MTLS_CA_FILE"
  require_file "$DRONE_CERT_FILE"
  require_file "$DRONE_KEY_FILE"

  echo "Verifying local Drone mTLS cert chain..."
  openssl verify -CAfile "$DRONE_MTLS_CA_FILE" "$DRONE_CERT_FILE" >/dev/null

  echo "Verifying local Drone cert is not expired..."
  openssl x509 -in "$DRONE_CERT_FILE" -noout -checkend 0 >/dev/null

  echo "Verifying local Drone cert and key match..."
  cert_modulus="$(openssl x509 -noout -modulus -in "$DRONE_CERT_FILE" | openssl md5)"
  key_modulus="$(openssl rsa -noout -modulus -in "$DRONE_KEY_FILE" 2>/dev/null | openssl md5)"

  if [[ "$cert_modulus" != "$key_modulus" ]]; then
    echo "Local Drone cert and key do not match." >&2
    echo "Cert: $DRONE_CERT_FILE" >&2
    echo "Key:  $DRONE_KEY_FILE" >&2
    exit 1
  fi

  if [[ -e "$LOCAL_DRONE_CERT_DIR/ca.key" ]]; then
    echo "Local Drone cert directory must not contain ca.key: $LOCAL_DRONE_CERT_DIR/ca.key" >&2
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

require_file "$DRONE_DIR/app/main.py"
require_file "$OVERMIND_DIR/src/overmind/main.py"
provision_local_drone_mtls_certs
ensure_runtime_envs
require_file "$OVERMIND_PYTHON_BIN"
require_file "$DRONE_PYTHON_BIN"

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

echo "Starting Batocera Drone on https://localhost:${DRONE_PORT}"
(
  cd "$DRONE_DIR"
  ROM_API_USERNAME="${ROM_API_USERNAME:-admin}" \
  ROM_API_PASSWORD="${ROM_API_PASSWORD:-changeme}" \
  HTTPS_PORT="$DRONE_PORT" \
  HTTP_ONLY="false" \
  DRONE_DEVICE_ID="${DRONE_DEVICE_ID:-$LOCAL_DRONE_ID}" \
  HOSTNAME_OVERRIDE="${HOSTNAME_OVERRIDE:-localhost,local-drone,batocera.local}" \
  DRONE_MTLS_MODE="${DRONE_MTLS_MODE:-managed}" \
  DRONE_MTLS_ENABLED="${DRONE_MTLS_ENABLED:-true}" \
  DRONE_MTLS_CA_FILE="$DRONE_MTLS_CA_FILE" \
  DRONE_CERT_FILE="$DRONE_CERT_FILE" \
  DRONE_KEY_FILE="$DRONE_KEY_FILE" \
  TLS_KEY_FILE="$DRONE_TLS_KEY_FILE" \
  TLS_CERT_FILE="$DRONE_TLS_CERT_FILE" \
  USE_FAKE_DATA="${USE_FAKE_DATA:-false}" \
  USERDATA_ROOT="$DRONE_FAKE_USERDATA_ROOT" \
  ROMS_ROOT="$DRONE_FAKE_USERDATA_ROOT/roms" \
  BIOS_ROOT="$DRONE_FAKE_USERDATA_ROOT/bios" \
  THEMES_ROOT="$DRONE_FAKE_USERDATA_ROOT/themes" \
  BATOCERA_CONF_FILE="$DRONE_FAKE_USERDATA_ROOT/system/batocera.conf" \
  ES_SETTINGS_FILE="$DRONE_FAKE_USERDATA_ROOT/system/configs/emulationstation/es_settings.cfg" \
  LOG_DIR="${LOG_DIR:-$DRONE_DIR/local-data/logs}" \
  OVERMIND_URL="${OVERMIND_URL:-https://localhost:${OVERMIND_PORT}}" \
  OVERMIND_EMAIL="${OVERMIND_EMAIL:-demo@example.com}" \
  OVERMIND_AUTH_TOKEN="${OVERMIND_AUTH_TOKEN:-}" \
  OVERMIND_POLL_SECONDS="${OVERMIND_POLL_SECONDS:-60}" \
  "$DRONE_PYTHON_BIN" "$DRONE_DIR/app/main.py"
) &
DRONE_PID="$!"

echo "Starting Batocera Overmind on https://localhost:${OVERMIND_PORT}"
(
  cd "$OVERMIND_DIR"
  PYTHONPATH="$OVERMIND_DIR/src" \
  USE_FAKE_DATA="${USE_FAKE_DATA:-false}" \
  OVERMIND_PORT="$OVERMIND_PORT" \
  EMAIL_PROVIDER="${EMAIL_PROVIDER:-}" \
  EMAIL_FROM="${EMAIL_FROM:-}" \
  SMTP_HOST="${SMTP_HOST:-}" \
  SMTP_PORT="${SMTP_PORT:-}" \
  SMTP_USERNAME="${SMTP_USERNAME:-}" \
  SMTP_PASSWORD="${SMTP_PASSWORD:-}" \
  SMTP_USE_SSL="${SMTP_USE_SSL:-}" \
  SMTP_STARTTLS="${SMTP_STARTTLS:-}" \
  PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}" \
  "$OVERMIND_PYTHON_BIN" -m overmind.main --reload
) &
OVERMIND_PID="$!"

cat <<INFO

Batocera stack is starting.
  Overmind: https://localhost:${OVERMIND_PORT}
  Drone:    https://localhost:${DRONE_PORT}
  Fake data: ${USE_FAKE_DATA:-false}
  Drone fake data root: ${DRONE_FAKE_USERDATA_ROOT}
  Overmind TLS cert: ${OVERMIND_TLS_CERT_FILE}

Overmind email:
  Provider: ${EMAIL_PROVIDER:-"(not set)"}
  From:     ${EMAIL_FROM:-"(not set)"}
  SMTP:     ${SMTP_HOST:-"(not set)"}${SMTP_PORT:+:${SMTP_PORT}}
  Username: ${SMTP_USERNAME:-"(not set)"}
  Password: ${SMTP_PASSWORD:+"(set)"}

  Drone mTLS CA:     ${DRONE_MTLS_CA_FILE}
  Drone TLS cert:    ${DRONE_CERT_FILE}

Drone auth:
  Username: ${ROM_API_USERNAME:-admin}
  Password: ${ROM_API_PASSWORD:-changeme}

Overmind demo login:
  Email:    demo@example.com
  Password: DemoPass123

Drone onboarding:
  Email:    ${OVERMIND_EMAIL:-"(not set)"}
  Token:    ${OVERMIND_AUTH_TOKEN:+"(set)"}

Press Ctrl+C to stop both apps.
INFO

wait "$OVERMIND_PID" "$DRONE_PID"
