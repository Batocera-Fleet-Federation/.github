#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEDERATION_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CREDENTIALS_FILE="${BFF_CREDENTIALS_FILE:-${FEDERATION_ROOT}/.github/.credentials}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${SCRIPT_DIR}/debug-output/batocera-drone}"
TARGET_HOST="${BATOCERA_SSH_HOST:-}"
TARGET_USER="${BATOCERA_SSH_USER:-}"
TARGET_PASSWORD="${BATOCERA_SSH_PASSWORD:-}"
LOG_TAIL="${LOG_TAIL:-500}"

usage() {
  cat <<'EOF'
Usage: .github/scripts/debug-batocera-drone.sh

Collects read-only Batocera and Drone diagnostics over SSH. Connection defaults
are read from the "batocera machine" section of .github/.credentials and may be
overridden with BATOCERA_SSH_HOST, BATOCERA_SSH_USER, and BATOCERA_SSH_PASSWORD.

Output is saved under .github/scripts/debug-output/batocera-drone/<timestamp>/.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

for command in sshpass ssh; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: ${command}" >&2
    exit 1
  fi
done

if [[ ! -r "${CREDENTIALS_FILE}" ]]; then
  echo "ERROR: Credentials file is not readable: ${CREDENTIALS_FILE}" >&2
  exit 1
fi

read_credential_field() {
  local field="$1"
  awk -v field="${field}" '
    /^batocera machine[[:space:]]*$/ { in_section=1; next }
    in_section && /^[[:space:]]*$/ { exit }
    in_section {
      split($0, parts, ":")
      key=parts[1]
      sub(/^[[:space:]]+/, "", key)
      sub(/[[:space:]]+$/, "", key)
      if (key == field) {
        sub(/^[^:]*:[[:space:]]*/, "", $0)
        print $0
        exit
      }
    }
  ' "${CREDENTIALS_FILE}"
}

TARGET_HOST="${TARGET_HOST:-$(read_credential_field host)}"
TARGET_USER="${TARGET_USER:-$(read_credential_field u)}"
TARGET_PASSWORD="${TARGET_PASSWORD:-$(read_credential_field p)}"

if [[ -z "${TARGET_HOST}" || -z "${TARGET_USER}" || -z "${TARGET_PASSWORD}" ]]; then
  echo "ERROR: Batocera SSH host, user, and password are required." >&2
  exit 1
fi
if [[ ! "${LOG_TAIL}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: LOG_TAIL must be a non-negative integer." >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${OUTPUT_ROOT}/${timestamp}"
mkdir -p "${run_dir}"
output_file="${run_dir}/combined.log"
raw_file="${run_dir}/.raw.log"
trap 'rm -f "${raw_file}"' EXIT

redact() {
  sed -E \
    -e 's/((TOKEN|SECRET|PASSWORD|PASS|KEY|AUTH|COOKIE|SESSION|CREDENTIAL|PRIVATE)[A-Z0-9_ -]*[=:])[^\\" ]+/\1<redacted>/Ig' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1<redacted>/g' \
    -e 's/("access_token"[[:space:]]*:[[:space:]]*")[^"]+/\1<redacted>/g'
}

ssh_opts=(
  -o PubkeyAuthentication=no
  -o PreferredAuthentications=password
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
)

remote_script="$(cat <<EOF
set +e
section() { printf '\\n\\n===== %s =====\\n' "\$1"; }
section metadata
date -u
hostname
uname -a
cat /usr/share/batocera/batocera.version 2>/dev/null
uptime
section storage
df -h
df -ih
section memory
free -m
section drone-service
/userdata/system/services/DRONE_SERVER status 2>&1
section drone-processes
ps aux | grep -E '[d]rone|[p]ython'
section drone-listeners
ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null
section drone-app-version
cat /userdata/system/drone-app/app/VERSION 2>/dev/null
section drone-service-log
tail -n ${LOG_TAIL} /userdata/system/logs/DRONE_SERVER.log 2>/dev/null
section drone-app-logs
find /userdata/system/drone-app -maxdepth 3 -type f -name '*.log' -print 2>/dev/null | while IFS= read -r log; do
  printf '\\n--- %s ---\\n' "\$log"
  tail -n ${LOG_TAIL} "\$log"
done
EOF
)"

echo "Collecting read-only Drone diagnostics from ${TARGET_USER}@${TARGET_HOST}"
if ! SSHPASS="${TARGET_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" "${TARGET_USER}@${TARGET_HOST}" "${remote_script}" >"${raw_file}" 2>&1; then
  redact <"${raw_file}" >"${output_file}"
  echo "ERROR: SSH diagnostics failed. Partial output: ${output_file}" >&2
  exit 1
fi
redact <"${raw_file}" >"${output_file}"

echo "Saved Drone diagnostics: ${output_file}"
