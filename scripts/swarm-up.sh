#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/.github/docker/docker-compose.swarm.yml"
SWARM_ENV_SOURCE="$ROOT_DIR/.github/scripts/.env.swarm"
ROM_ROOT="$ROOT_DIR/.github/data/roms"
BIOS_ROOT="$ROOT_DIR/.github/data/bios"
IMPORT_SCRIPT="$ROOT_DIR/.github/scripts/import-batocera-test-data.sh"
GENERATE_SWARM_DATA_SCRIPT="$ROOT_DIR/.github/scripts/generate-swarm-rom-data.py"
PROVISION_MTLS_SCRIPT="$ROOT_DIR/.github/scripts/provision-local-mtls-certs.sh"
BROWSER="Google Chrome"
IMPORT_DATA="false"
RESET_DATA="false"
SWARM_DATA_SEED=""
MIN_ROMS_PER_SYSTEM="1"
MAX_ROMS_PER_SYSTEM="4"
MIN_BIOS_FILES="1"
MAX_BIOS_FILES="4"
DRONE_COUNT="4"
NORMALIZED_SWARM_ENV_FILE=""
export OVERMIND_VERSION="${OVERMIND_VERSION:-local:swarm}"

URLS=(
  "https://bff-overmind:8000"
  "https://bff-drone-a:8443"
  "https://bff-drone-b:8444"
  "https://bff-drone-c:8445"
  "https://bff-drone-d:8446"
)

usage() {
  cat <<EOF
Usage:
  .github/scripts/swarm-up.sh [--import-data] [--reset-data] [--seed value] [docker compose options]

Options:
  --import-data    Run .github/scripts/import-batocera-test-data.sh before startup.
  --reset-data     Regenerate .github/generated per-Drone ROM data from scratch.
  --seed VALUE     Use deterministic randomized per-Drone ROM layout.
  --min-roms-per-system VALUE
  --max-roms-per-system VALUE
  --min-bios-files VALUE
  --max-bios-files VALUE
  --drone-count VALUE
  --help, -h       Show this help.
EOF
}

cleanup() {
  if [[ -n "$NORMALIZED_SWARM_ENV_FILE" ]]; then
    rm -f "$NORMALIZED_SWARM_ENV_FILE"
  fi
}

trap cleanup EXIT

load_swarm_env() {
  if [[ ! -f "$SWARM_ENV_SOURCE" ]]; then
    echo "No .env.swarm found at $SWARM_ENV_SOURCE; using shell environment and compose defaults."
    return 0
  fi

  echo "Loading swarm environment from $SWARM_ENV_SOURCE"
  set -a
  # shellcheck disable=SC1090
  source "$SWARM_ENV_SOURCE"
  set +a

  NORMALIZED_SWARM_ENV_FILE="$(mktemp)"
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    printf '%s=%s\n' "$key" "${!key}" >> "$NORMALIZED_SWARM_ENV_FILE"
  done < <(
    sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$SWARM_ENV_SOURCE" \
      | sort -u
  )

  export SWARM_CONTAINER_ENV_FILE="$NORMALIZED_SWARM_ENV_FILE"
}

update_hosts_from_urls() {
  local marker_start="# BEGIN batocera-fleet-federation swarm hosts"
  local marker_end="# END batocera-fleet-federation swarm hosts"
  local tmp_file
  local host_entries

  tmp_file="$(mktemp)"
  host_entries=""

  for url in "${URLS[@]}"; do
    local port
    local alias

    port="$(printf '%s\n' "$url" | sed -E 's#^https?://[^:/]+:([0-9]+).*#\1#')"

    case "$port" in
      8000) alias="bff-overmind" ;;
      8443) alias="bff-drone-a" ;;
      8444) alias="bff-drone-b" ;;
      8445) alias="bff-drone-c" ;;
      8446) alias="bff-drone-d" ;;
      *) alias="" ;;
    esac

    if [[ -n "$alias" ]]; then
      host_entries+="127.0.0.1 $alias\n"
    fi
  done

  if [[ -z "$host_entries" ]]; then
    return 0
  fi

  awk \
    -v marker_start="$marker_start" \
    -v marker_end="$marker_end" \
    'BEGIN { skip = 0 }
     $0 == marker_start { skip = 1; next }
     $0 == marker_end { skip = 0; next }
     skip == 0 { print }' \
    /etc/hosts > "$tmp_file"

  {
    cat "$tmp_file"
    printf '\n%s\n' "$marker_start"
    printf '%b' "$host_entries"
    printf '%s\n' "$marker_end"
  } > "${tmp_file}.new"

  echo "Updating /etc/hosts with local swarm hostnames. sudo may prompt for your password."
  sudo cp "${tmp_file}.new" /etc/hosts
  rm -f "$tmp_file" "${tmp_file}.new"

  flush_host_cache
  verify_swarm_hosts_resolve
}

flush_host_cache() {
  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -flushcache >/dev/null 2>&1 || true
  fi

  if command -v killall >/dev/null 2>&1; then
    killall -HUP mDNSResponder >/dev/null 2>&1 || true
  fi
}

verify_swarm_hosts_resolve() {
  local url
  local host
  local missing_hosts=()
  local missing_count=0

  for url in "${URLS[@]}"; do
    host="$(printf '%s\n' "$url" | sed -E 's#^https?://([^:/]+).*$#\1#')"
    if ! dscacheutil -q host -a name "$host" 2>/dev/null | grep -q "ip_address: 127.0.0.1"; then
      missing_hosts+=("$host")
      missing_count=$((missing_count + 1))
    fi
  done

  if [[ "$missing_count" -gt 0 ]]; then
    cat >&2 <<EOF
ERROR: Local swarm hostnames did not resolve after updating /etc/hosts:
  ${missing_hosts[*]}

Check /etc/hosts for the batocera-fleet-federation swarm hosts block, then rerun this script.
EOF
    exit 1
  fi
}

url_origin() {
  local url="$1"

  printf '%s\n' "$url" \
    | sed -E 's#^(https?://[^/]+).*$#\1#' \
    | sed -E 's#/*$##'
}

url_is_open() {
  local url="$1"
  local target_origin
  local open_url
  local open_origin
  local open_urls_file

  target_origin="$(url_origin "$url")"
  open_urls_file="$(mktemp)"

  osascript <<EOF > "$open_urls_file" 2>/dev/null || true
set foundUrls to {}
tell application "$BROWSER"
  repeat with w in windows
    repeat with t in tabs of w
      try
        set end of foundUrls to URL of t
      end try
    end repeat
  end repeat
end tell
set AppleScript's text item delimiters to linefeed
return foundUrls as text
EOF

  while IFS= read -r open_url; do
    [[ -z "$open_url" ]] && continue

    open_origin="$(url_origin "$open_url")"

    if [[ "$open_origin" == "$target_origin" ]]; then
      rm -f "$open_urls_file"
      return 0
    fi
  done < "$open_urls_file"

  rm -f "$open_urls_file"
  return 1
}

open_swarm_urls() {
  for url in "${URLS[@]}"; do
    if url_is_open "$url"; then
      echo "Already open: $url"
    else
      echo "Opening: $url"
      open -a "$BROWSER" "$url"
    fi
  done
}

validate_roms_exist() {
  if [[ ! -d "$ROM_ROOT" ]] || [[ -z "$(find "$ROM_ROOT" -mindepth 2 -type f ! -name ".gitkeep" ! -name "README.md" -print -quit)" ]]; then
    cat >&2 <<EOF
No ROM files found in $ROM_ROOT.
Import or place test ROMs under .github/data/roms/<system>/<files> first.
You can run: .github/scripts/import-batocera-test-data.sh --generate-only
EOF
    exit 1
  fi
}

provision_swarm_mtls_certs() {
  if [[ ! -x "$PROVISION_MTLS_SCRIPT" ]]; then
    echo "ERROR: local mTLS provisioning script is missing or not executable: $PROVISION_MTLS_SCRIPT" >&2
    exit 1
  fi

  echo "Provisioning local swarm Drone mTLS certs..."
  "$PROVISION_MTLS_SCRIPT" --profile swarm
}

generate_swarm_rom_data() {
  if [[ ! -x "$GENERATE_SWARM_DATA_SCRIPT" ]]; then
    echo "ERROR: generated data script is missing or not executable: $GENERATE_SWARM_DATA_SCRIPT" >&2
    exit 1
  fi
  local args=(
    "--source" "$ROM_ROOT"
    "--bios-source" "$BIOS_ROOT"
    "--output" "$ROOT_DIR/.github/generated"
    "--drone-count" "$DRONE_COUNT"
    "--min-roms-per-system" "$MIN_ROMS_PER_SYSTEM"
    "--max-roms-per-system" "$MAX_ROMS_PER_SYSTEM"
    "--min-bios-files" "$MIN_BIOS_FILES"
    "--max-bios-files" "$MAX_BIOS_FILES"
  )
  if [[ "$RESET_DATA" == "true" ]]; then
    args+=("--reset")
  fi
  if [[ -n "$SWARM_DATA_SEED" ]]; then
    args+=("--seed" "$SWARM_DATA_SEED")
  fi
  echo "Generating per-Drone randomized ROM and BIOS data..."
  python3 "$GENERATE_SWARM_DATA_SCRIPT" "${args[@]}"
}

main() {
  local compose_args=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --import-data)
        IMPORT_DATA="true"
        shift
        ;;
      --reset-data)
        RESET_DATA="true"
        shift
        ;;
      --seed)
        SWARM_DATA_SEED="${2:-}"
        shift 2
        ;;
      --min-roms-per-system)
        MIN_ROMS_PER_SYSTEM="${2:-1}"
        shift 2
        ;;
      --max-roms-per-system)
        MAX_ROMS_PER_SYSTEM="${2:-4}"
        shift 2
        ;;
      --min-bios-files)
        MIN_BIOS_FILES="${2:-1}"
        shift 2
        ;;
      --max-bios-files)
        MAX_BIOS_FILES="${2:-4}"
        shift 2
        ;;
      --drone-count)
        DRONE_COUNT="${2:-4}"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        compose_args+=("$1")
        shift
        ;;
    esac
  done

  if [[ "$IMPORT_DATA" == "true" ]]; then
    if [[ ! -x "$IMPORT_SCRIPT" ]]; then
      echo "ERROR: import script is missing or not executable: $IMPORT_SCRIPT" >&2
      exit 1
    fi
    echo "Importing local Batocera test data..."
    "$IMPORT_SCRIPT" --generate-only
  fi

  validate_roms_exist
  load_swarm_env
  generate_swarm_rom_data
  provision_swarm_mtls_certs
  update_hosts_from_urls

  echo "Starting local Batocera Fleet Federation swarm..."
  if [[ "${#compose_args[@]}" -gt 0 ]]; then
    docker compose -f "$COMPOSE_FILE" up -d --build "${compose_args[@]}"
  else
    docker compose -f "$COMPOSE_FILE" up -d --build
  fi

  echo "Current swarm containers:"
  docker compose -f "$COMPOSE_FILE" ps

  open_swarm_urls
}

main "$@"
