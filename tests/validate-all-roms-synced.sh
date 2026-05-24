#!/usr/bin/env bash
###############################################################################
# validate-all-roms-synced.sh
#
# Validates that all Batocera Drone containers have the same ROM files under:
#
#   /userdata/roms
#
# The script:
#   - Scans each configured Drone container.
#   - Builds a relative file list of ROMs from /userdata/roms.
#   - Ignores common metadata/media files such as:
#       gamelist.xml
#       *.txt
#       *.log
#       images/
#       videos/
#       manuals/
#       media/
#   - Compares the ROM inventory across all Drones.
#   - Clearly reports:
#       - Which ROM is missing.
#       - Which Drone is missing it.
#       - Which Drone(s) currently have it.
#   - Prints a per-Drone summary.
#   - Exits with:
#       0 if all Drones have matching ROM file lists.
#       1 if any Drone is missing one or more ROMs.
#
# Usage:
#   chmod +x validate-all-roms-synced.sh
#   ./validate-all-roms-synced.sh
#
# Expected containers:
#   bff-drone-a
#   bff-drone-b
#   bff-drone-c
#   bff-drone-d
###############################################################################

set -euo pipefail

DRONES=(
  "bff-drone-a"
  "bff-drone-b"
  "bff-drone-c"
  "bff-drone-d"
)

ROM_ROOT="/userdata/roms"
TMP_DIR="$(mktemp -d)"
OUT_DIR="${TMP_DIR}/rom-sync"
mkdir -p "$OUT_DIR"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "Scanning ROM files from containers..."
echo

for drone in "${DRONES[@]}"; do
  echo "Scanning ${drone}..."

  if ! docker inspect "$drone" >/dev/null 2>&1; then
    echo "ERROR: Container not found: ${drone}" >&2
    exit 1
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx "$drone"; then
    echo "ERROR: Container is not running: ${drone}" >&2
    exit 1
  fi

  docker exec "$drone" sh -c "
    if [ ! -d '$ROM_ROOT' ]; then
      echo 'ERROR: $ROM_ROOT not found' >&2
      exit 2
    fi

    find '$ROM_ROOT' -type f \
      ! -name 'gamelist.xml' \
      ! -name '*.txt' \
      ! -name '*.log' \
      ! -path '*/images/*' \
      ! -path '*/videos/*' \
      ! -path '*/manuals/*' \
      ! -path '*/media/*' \
      -printf '%P\n'
  " | LC_ALL=C sort -u > "${OUT_DIR}/${drone}.files"

  count="$(wc -l < "${OUT_DIR}/${drone}.files" | tr -d ' ')"
  echo "  ${count} ROM files"
done

echo
echo "Building master ROM list..."

cat "${OUT_DIR}"/*.files | LC_ALL=C sort -u > "${OUT_DIR}/all-roms.files"

TOTAL_ROMS="$(wc -l < "${OUT_DIR}/all-roms.files" | tr -d ' ')"
echo "Total unique ROM files across all drones: ${TOTAL_ROMS}"
echo

echo "ROM count by drone:"
for drone in "${DRONES[@]}"; do
  count="$(wc -l < "${OUT_DIR}/${drone}.files" | tr -d ' ')"
  echo "  ${drone}: ${count}"
done

echo
echo "Checking ROM sync gaps..."
echo

FAILED=0

# One counter file per drone to avoid Bash 4 associative arrays.
for drone in "${DRONES[@]}"; do
  echo 0 > "${OUT_DIR}/${drone}.missing_count"
done

while IFS= read -r rom; do
  existing_drones=()
  missing_drones=()

  for drone in "${DRONES[@]}"; do
    if grep -Fxq -- "$rom" "${OUT_DIR}/${drone}.files"; then
      existing_drones+=("$drone")
    else
      missing_drones+=("$drone")
    fi
  done

  if [ "${#missing_drones[@]}" -gt 0 ]; then
    FAILED=1

    for missing_drone in "${missing_drones[@]}"; do
      current_count="$(cat "${OUT_DIR}/${missing_drone}.missing_count")"
      echo $((current_count + 1)) > "${OUT_DIR}/${missing_drone}.missing_count"

      echo "MISSING:"
      echo "  ROM: ${rom}"
      echo "  Missing from: ${missing_drone}"
      echo "  Exists on:"
      for existing_drone in "${existing_drones[@]}"; do
        echo "    - ${existing_drone}"
      done
      echo
    done
  fi
done < "${OUT_DIR}/all-roms.files"

echo
echo "Summary by drone:"
echo

for drone in "${DRONES[@]}"; do
  missing_count="$(cat "${OUT_DIR}/${drone}.missing_count")"

  if [ "$missing_count" -eq 0 ]; then
    echo "PASS: ${drone} has all ROMs"
  else
    echo "FAIL: ${drone} is missing ${missing_count} ROM(s)"
  fi
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "SUCCESS: All drones have matching ROM file lists."
else
  echo "FAILED: One or more drones are missing ROMs."
  exit 1
fi