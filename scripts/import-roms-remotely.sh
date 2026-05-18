#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="root@batocera.local"
REMOTE_BASE="/userdata/roms"
MAX_SIZE_KB="10240"
MAX_FILES="5"
REMOTE_PASS=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_GITHUB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_ROM_BASE="${PROJECT_GITHUB_DIR}/data/roms"

usage() {
  cat <<EOF
Usage:
  ./import-roms-remotely.sh --password=linux [options]

Required:
  --password=VALUE            SSH password for remote host

Options:
  --remote-host=VALUE         Remote SSH host. Default: ${REMOTE_HOST}
  --max-size-kb=VALUE         Max ROM file size in KB. Default: ${MAX_SIZE_KB}
  --max-files=VALUE           Max files per system. Default: ${MAX_FILES}
  --local-rom-base=VALUE      Local target ROM base. Default: ${LOCAL_ROM_BASE}
  --help                      Show this help

Examples:
  ./import-roms-remotely.sh --password=linux
  ./import-roms-remotely.sh --password=linux --max-files=10 --max-size-kb=20480
EOF
}

for arg in "$@"; do
  case "$arg" in
    --password=*)
      REMOTE_PASS="${arg#*=}"
      ;;
    --remote-host=*)
      REMOTE_HOST="${arg#*=}"
      ;;
    --max-size-kb=*)
      MAX_SIZE_KB="${arg#*=}"
      ;;
    --max-files=*)
      MAX_FILES="${arg#*=}"
      ;;
    --local-rom-base=*)
      LOCAL_ROM_BASE="${arg#*=}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $arg"
      echo
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$REMOTE_PASS" ]]; then
  echo "ERROR: --password=VALUE is required."
  echo
  usage
  exit 1
fi

if ! [[ "$MAX_SIZE_KB" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --max-size-kb must be a number."
  exit 1
fi

if ! [[ "$MAX_FILES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --max-files must be a number."
  exit 1
fi

if [[ ! -d "$LOCAL_ROM_BASE" ]]; then
  echo "ERROR: local ROM base does not exist: $LOCAL_ROM_BASE"
  exit 1
fi

if ! command -v sshpass >/dev/null 2>&1; then
  echo "ERROR: sshpass is required."
  echo "Install it first:"
  echo "  brew install hudochenkov/sshpass/sshpass"
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "ERROR: rsync is required."
  exit 1
fi

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

echo "Local target: $LOCAL_ROM_BASE"
echo "Remote source: ${REMOTE_HOST}:${REMOTE_BASE}"
echo "Max size: ${MAX_SIZE_KB} KB"
echo "Max files per system: ${MAX_FILES}"
echo

tmp_files="$(mktemp)"
cleanup() {
  rm -f "$tmp_files"
}
trap cleanup EXIT

find "$LOCAL_ROM_BASE" -mindepth 1 -maxdepth 1 -type d | sort | while IFS= read -r local_dir; do
  system="$(basename "$local_dir")"

  [[ -z "$system" ]] && continue

  if [[ "$system" == *.old ]]; then
    echo "SKIP .old folder: $system"
    continue
  fi

  remote_dir="${REMOTE_BASE}/${system}"

  : > "$tmp_files"

  echo "Checking: $system"

  sshpass -p "$REMOTE_PASS" ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "
    if [ ! -d '$remote_dir' ]; then
      exit 0
    fi

    cd '$remote_dir' || exit 0

    find . -maxdepth 1 -type f -size -${MAX_SIZE_KB}k \( \
      -iname '*.zip' -o \
      -iname '*.7z' -o \
      -iname '*.rar' -o \
      -iname '*.bin' -o \
      -iname '*.cue' -o \
      -iname '*.iso' -o \
      -iname '*.chd' -o \
      -iname '*.nes' -o \
      -iname '*.fds' -o \
      -iname '*.sfc' -o \
      -iname '*.smc' -o \
      -iname '*.gb' -o \
      -iname '*.gbc' -o \
      -iname '*.gba' -o \
      -iname '*.n64' -o \
      -iname '*.z64' -o \
      -iname '*.v64' -o \
      -iname '*.a26' -o \
      -iname '*.a52' -o \
      -iname '*.a78' -o \
      -iname '*.sms' -o \
      -iname '*.gg' -o \
      -iname '*.md' -o \
      -iname '*.gen' -o \
      -iname '*.32x' -o \
      -iname '*.pce' -o \
      -iname '*.ngp' -o \
      -iname '*.ngc' -o \
      -iname '*.ws' -o \
      -iname '*.wsc' \
    \) | sort | head -n ${MAX_FILES} | sed 's#^\./##'
  " </dev/null > "$tmp_files"

  if [[ ! -s "$tmp_files" ]]; then
    echo "  No ROM files found under ${MAX_SIZE_KB} KB."
    continue
  fi

  echo "  Downloading to: $local_dir"
  sed 's/^/    - /' "$tmp_files"

  sshpass -p "$REMOTE_PASS" rsync -av \
    --files-from="$tmp_files" \
    -e "ssh ${SSH_OPTS[*]}" \
    "${REMOTE_HOST}:${remote_dir}/" \
    "${local_dir}/"

  echo
done

echo "Done."