#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="root@batocera.local"
REMOTE_ROM_BASE="/userdata/roms"
REMOTE_BIOS_BASE="/userdata/bios"
MAX_SIZE_KB="10240"
MAX_FILES="5"
MAX_BIOS_SIZE_KB="51200"
MAX_BIOS_FILES="200"
REMOTE_PASS="${BATOCERA_SSH_PASSWORD:-}"
GENERATE_ONLY="false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DATA_ROOT="${ROOT_DIR}/.github/data"
LOCAL_ROM_BASE="${DATA_ROOT}/roms"
LOCAL_BIOS_BASE="${DATA_ROOT}/bios"

usage() {
  cat <<EOF
Usage:
  .github/scripts/import-batocera-test-data.sh [options]

Options:
  --password=VALUE            SSH password for optional remote ROM import
                              Can also be set with BATOCERA_SSH_PASSWORD.
  --remote-host=VALUE         Remote SSH host. Default: ${REMOTE_HOST}
  --remote-rom-base=VALUE     Remote ROM base. Default: ${REMOTE_ROM_BASE}
  --remote-bios-base=VALUE    Remote BIOS base. Default: ${REMOTE_BIOS_BASE}
  --max-size-kb=VALUE         Max remote ROM file size in KB. Default: ${MAX_SIZE_KB}
  --max-files=VALUE           Max remote files per system. Default: ${MAX_FILES}
  --max-bios-size-kb=VALUE    Max remote BIOS file size in KB. Default: ${MAX_BIOS_SIZE_KB}
  --max-bios-files=VALUE      Max remote BIOS files. Default: ${MAX_BIOS_FILES}
  --data-root=VALUE           Local Batocera-like data root. Default: ${DATA_ROOT}
  --local-rom-base=VALUE      Local target ROM base. Default: ${LOCAL_ROM_BASE}
  --generate-only             Create deterministic placeholder data without remote import
  --help                      Show this help

Examples:
  .github/scripts/import-batocera-test-data.sh --generate-only
  .github/scripts/import-batocera-test-data.sh --password=linux --max-files=10
EOF
}

for arg in "$@"; do
  case "$arg" in
    --password=*) REMOTE_PASS="${arg#*=}" ;;
    --remote-host=*) REMOTE_HOST="${arg#*=}" ;;
    --remote-base=*) REMOTE_ROM_BASE="${arg#*=}" ;;
    --remote-rom-base=*) REMOTE_ROM_BASE="${arg#*=}" ;;
    --remote-bios-base=*) REMOTE_BIOS_BASE="${arg#*=}" ;;
    --max-size-kb=*) MAX_SIZE_KB="${arg#*=}" ;;
    --max-files=*) MAX_FILES="${arg#*=}" ;;
    --max-bios-size-kb=*) MAX_BIOS_SIZE_KB="${arg#*=}" ;;
    --max-bios-files=*) MAX_BIOS_FILES="${arg#*=}" ;;
    --data-root=*)
      DATA_ROOT="${arg#*=}"
      LOCAL_ROM_BASE="${DATA_ROOT}/roms"
      LOCAL_BIOS_BASE="${DATA_ROOT}/bios"
      ;;
    --local-rom-base=*) LOCAL_ROM_BASE="${arg#*=}" ;;
    --generate-only) GENERATE_ONLY="true" ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $arg" >&2
      echo >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! [[ "$MAX_SIZE_KB" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --max-size-kb must be a number." >&2
  exit 1
fi

if ! [[ "$MAX_FILES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --max-files must be a number." >&2
  exit 1
fi

if ! [[ "$MAX_BIOS_SIZE_KB" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --max-bios-size-kb must be a number." >&2
  exit 1
fi

if ! [[ "$MAX_BIOS_FILES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --max-bios-files must be a number." >&2
  exit 1
fi

mkdir -p \
  "$LOCAL_ROM_BASE" \
  "$LOCAL_BIOS_BASE" \
  "$DATA_ROOT/system/configs/emulationstation" \
  "$DATA_ROOT/system/configs/retroarch" \
  "$DATA_ROOT/system/logs" \
  "$DATA_ROOT/system/drone-app/logs" \
  "$DATA_ROOT/themes/default"

cat > "$DATA_ROOT/system/batocera.conf" <<'EOF'
global.theme=default
global.retroarch.video_driver=gl
system.hostname=bff-local-test
wifi.enabled=0
EOF

cat > "$DATA_ROOT/system/batocera.version" <<'EOF'
local-test-2026.05
EOF

cat > "$DATA_ROOT/system/configs/emulationstation/es_settings.cfg" <<'EOF'
<?xml version="1.0"?>
<config>
  <string name="ThemeSet" value="default" />
  <bool name="ScrapeRatings" value="true" />
</config>
EOF

cat > "$DATA_ROOT/system/configs/retroarch/retroarchcustom.cfg" <<'EOF'
video_driver = "gl"
audio_driver = "alsathread"
EOF

cat > "$DATA_ROOT/system/logs/es_launch_stdout.log" <<'EOF'
2026-05-19 10:00:00 INFO emulator=snes rom=/userdata/roms/snes/Chrono Trigger (USA).zip
2026-05-19 10:03:00 INFO emulator=gba rom=/userdata/roms/gba/Metroid Fusion (USA).gba
EOF

cat > "$DATA_ROOT/system/logs/es_launch_stderr.log" <<'EOF'
2026-05-19 10:00:01 WARN local test stderr placeholder
EOF

cat > "$DATA_ROOT/system/logs/retroarch.log" <<'EOF'
[INFO] Batocera Fleet Federation local test emulator log.
[INFO] Video driver: gl
EOF

create_rom() {
  local system="$1"
  local file="$2"
  local title="$3"
  local system_dir="$LOCAL_ROM_BASE/$system"

  mkdir -p "$system_dir/images" "$system_dir/videos" "$system_dir/manuals"
  if [[ ! -f "$system_dir/$file" ]]; then
    printf 'BFF-TEST-ROM:%s:%s\n' "$system" "$file" > "$system_dir/$file"
  fi
  if [[ ! -f "$system_dir/images/${file%.*}.png" ]]; then
    printf 'placeholder image for %s\n' "$title" > "$system_dir/images/${file%.*}.png"
  fi
}

create_gamelist() {
  local system="$1"
  shift
  local system_dir="$LOCAL_ROM_BASE/$system"
  local gamelist="$system_dir/gamelist.xml"

  {
    printf '<gameList>\n'
    while [[ "$#" -gt 0 ]]; do
      local file="$1"
      local title="$2"
      shift 2
      printf '  <game>\n'
      printf '    <path>./%s</path>\n' "$file"
      printf '    <name>%s</name>\n' "$title"
      printf '    <desc>Deterministic local test metadata for %s.</desc>\n' "$title"
      printf '    <image>./images/%s.png</image>\n' "${file%.*}"
      printf '    <thumbnail>./images/%s.png</thumbnail>\n' "${file%.*}"
      printf '  </game>\n'
    done
    printf '</gameList>\n'
  } > "$gamelist"
}

create_bios() {
  local file="$1"
  local target="$LOCAL_BIOS_BASE/$file"

  mkdir -p "$(dirname "$target")"
  if [[ ! -f "$target" ]]; then
    printf 'BFF-TEST-BIOS:%s\n' "$file" > "$target"
  fi
}

prepare_remote_gamelist_artwork_import() {
  local system="$1"
  local selected_roms_file="$2"
  local remote_gamelist="$3"
  local local_gamelist="$4"
  local artwork_files="$5"
  local merged_gamelist="$6"

  python3 - "$system" "$selected_roms_file" "$remote_gamelist" "$local_gamelist" "$artwork_files" "$merged_gamelist" <<'PY'
import copy
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import PurePosixPath
from urllib.parse import unquote, urlparse


ARTWORK_FIELDS = ("image", "thumbnail", "marquee", "fanart", "boxart", "video", "wheel", "manual")


system, selected_roms_file, remote_gamelist, local_gamelist, artwork_files, merged_gamelist = sys.argv[1:]


def normalize_gamelist_path(value: str) -> str:
    raw = str(value or "").strip().replace("\\", "/")
    while raw.startswith("./"):
        raw = raw[2:]
    return raw.lstrip("/")


def load_root(path: str) -> ET.Element:
    if not path or not os.path.exists(path) or os.path.getsize(path) == 0:
        return ET.Element("gameList")
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return ET.Element("gameList")
    return root if root.tag == "gameList" else ET.Element("gameList")


def child_text(parent: ET.Element, tag: str) -> str:
    child = parent.find(tag)
    return (child.text or "").strip() if child is not None else ""


def set_child_text(parent: ET.Element, tag: str, value: str) -> None:
    child = parent.find(tag)
    if child is None:
        child = ET.SubElement(parent, tag)
    child.text = value


def remove_child(parent: ET.Element, tag: str) -> None:
    child = parent.find(tag)
    if child is not None:
        parent.remove(child)


def remote_artwork_to_system_relative(value: str) -> str:
    raw = str(value or "").strip().replace("\\", "/")
    if not raw:
        return ""
    parsed = urlparse(raw)
    if parsed.scheme and parsed.scheme.lower() not in {"file"}:
        return ""
    if parsed.scheme.lower() == "file":
        raw = unquote(parsed.path)
    while raw.startswith("./"):
        raw = raw[2:]
    userdata_prefix = f"/userdata/roms/{system}/"
    roms_prefix = f"/roms/{system}/"
    if raw.startswith(userdata_prefix):
        raw = raw[len(userdata_prefix):]
    elif raw.startswith(roms_prefix):
        raw = raw[len(roms_prefix):]
    elif raw.startswith("/"):
        return ""
    normalized = os.path.normpath(raw).replace("\\", "/")
    if normalized in {"", "."} or normalized.startswith("../") or normalized == "..":
        return ""
    return PurePosixPath(normalized).as_posix()


with open(selected_roms_file, "r", encoding="utf-8", errors="replace") as handle:
    selected = {normalize_gamelist_path(line) for line in handle.read().splitlines() if line.strip()}

local_root = load_root(local_gamelist)
remote_root = load_root(remote_gamelist)
entries_by_path = {}

for game in local_root.findall("game"):
    path = normalize_gamelist_path(child_text(game, "path"))
    if path:
        entries_by_path[path] = copy.deepcopy(game)

artwork = []
seen_artwork = set()
for game in remote_root.findall("game"):
    rom_path = normalize_gamelist_path(child_text(game, "path"))
    if rom_path not in selected:
        continue
    merged_game = copy.deepcopy(game)
    set_child_text(merged_game, "path", f"./{rom_path}")
    for field in ARTWORK_FIELDS:
        value = child_text(merged_game, field)
        if not value:
            continue
        relative = remote_artwork_to_system_relative(value)
        if not relative:
            remove_child(merged_game, field)
            continue
        set_child_text(merged_game, field, f"./{relative}")
        if relative not in seen_artwork:
            artwork.append(relative)
            seen_artwork.add(relative)
    entries_by_path[rom_path] = merged_game

new_root = ET.Element("gameList")
for path in sorted(entries_by_path, key=str.lower):
    new_root.append(entries_by_path[path])

tree = ET.ElementTree(new_root)
try:
    ET.indent(tree, space="  ")
except AttributeError:
    pass
tree.write(merged_gamelist, encoding="utf-8", xml_declaration=True)

with open(artwork_files, "w", encoding="utf-8") as handle:
    for item in artwork:
        handle.write(f"{item}\n")
PY
}

sample_file_list() {
  local source_file="$1"
  local max_files="$2"

  python3 - "$source_file" "$max_files" <<'PY'
import random
import sys

source_file, max_files = sys.argv[1:]
try:
    limit = max(0, int(max_files))
except ValueError:
    limit = 0

if limit <= 0:
    raise SystemExit(0)

with open(source_file, "r", encoding="utf-8", errors="replace") as handle:
    files = [line.rstrip("\n") for line in handle if line.strip()]

if len(files) > limit:
    files = random.sample(files, limit)

for item in sorted(files, key=str.lower):
    print(item)
PY
}

create_rom "snes" "Chrono Trigger (USA).zip" "Chrono Trigger"
create_rom "snes" "Super Metroid (USA).zip" "Super Metroid"
create_rom "snes" "EarthBound (USA).zip" "EarthBound"
create_gamelist "snes" \
  "Chrono Trigger (USA).zip" "Chrono Trigger" \
  "Super Metroid (USA).zip" "Super Metroid" \
  "EarthBound (USA).zip" "EarthBound"

create_rom "gba" "Metroid Fusion (USA).gba" "Metroid Fusion"
create_rom "gba" "Mario Kart Super Circuit (USA).gba" "Mario Kart Super Circuit"
create_rom "gba" "Advance Wars (USA).gba" "Advance Wars"
create_gamelist "gba" \
  "Metroid Fusion (USA).gba" "Metroid Fusion" \
  "Mario Kart Super Circuit (USA).gba" "Mario Kart Super Circuit" \
  "Advance Wars (USA).gba" "Advance Wars"

create_rom "psx" "Castlevania - Symphony of the Night (USA).chd" "Castlevania - Symphony of the Night"
create_rom "psx" "Ridge Racer Type 4 (USA).chd" "Ridge Racer Type 4"
create_gamelist "psx" \
  "Castlevania - Symphony of the Night (USA).chd" "Castlevania - Symphony of the Night" \
  "Ridge Racer Type 4 (USA).chd" "Ridge Racer Type 4"

create_bios "gba/gba_bios.bin"
create_bios "psx/scph5501.bin"

if [[ -n "$REMOTE_PASS" && "$GENERATE_ONLY" != "true" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass is required for remote import." >&2
    echo "Install it first: brew install hudochenkov/sshpass/sshpass" >&2
    exit 1
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    echo "ERROR: rsync is required for remote import." >&2
    exit 1
  fi

  SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o BatchMode=no
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=password
    -o NumberOfPasswordPrompts=1
    -o ConnectTimeout=10
  )

  tmp_files="$(mktemp)"
  tmp_gamelist="$(mktemp)"
  tmp_artwork_files="$(mktemp)"
  tmp_merged_gamelist="$(mktemp)"
  cleanup() {
    rm -f "$tmp_files" "$tmp_gamelist" "$tmp_artwork_files" "$tmp_merged_gamelist"
  }
  trap cleanup EXIT

  auth_output="$(
    sshpass -p "$REMOTE_PASS" ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "printf ok" 2>&1 >/dev/null
  )" || {
    echo "ERROR: Could not authenticate to ${REMOTE_HOST}." >&2
    if [[ -n "$auth_output" ]]; then
      echo "$auth_output" >&2
    fi
    cat >&2 <<EOF

Batocera usually uses:
  host: root@batocera.local
  password: linux

Try:
  .github/scripts/import-batocera-test-data.sh --password=linux

If your Batocera host is at a different address, add:
  --remote-host=root@<ip-or-hostname>
EOF
    exit 1
  }

  echo "Importing optional remote ROMs from ${REMOTE_HOST}:${REMOTE_ROM_BASE}"
  find "$LOCAL_ROM_BASE" -mindepth 1 -maxdepth 1 -type d | sort | while IFS= read -r local_dir; do
    system="$(basename "$local_dir")"
    [[ -z "$system" || "$system" == *.old ]] && continue
    remote_dir="${REMOTE_ROM_BASE}/${system}"
    : > "$tmp_files"
    sshpass -p "$REMOTE_PASS" ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "
      if [ ! -d '$remote_dir' ]; then exit 0; fi
      cd '$remote_dir' || exit 0
      find . -maxdepth 1 -type f -size -${MAX_SIZE_KB}k \( -iname '*.zip' -o -iname '*.7z' -o -iname '*.bin' -o -iname '*.cue' -o -iname '*.iso' -o -iname '*.chd' -o -iname '*.nes' -o -iname '*.sfc' -o -iname '*.smc' -o -iname '*.gb' -o -iname '*.gbc' -o -iname '*.gba' \) | sort | head -n ${MAX_FILES} | sed 's#^\./##'
    " </dev/null > "$tmp_files"
    if [[ -s "$tmp_files" ]]; then
      echo "  ${system}: importing $(wc -l < "$tmp_files" | tr -d ' ') file(s)"
      sshpass -p "$REMOTE_PASS" rsync -av --files-from="$tmp_files" -e "ssh ${SSH_OPTS[*]}" "${REMOTE_HOST}:${remote_dir}/" "${local_dir}/"
      : > "$tmp_gamelist"
      : > "$tmp_artwork_files"
      : > "$tmp_merged_gamelist"
      if sshpass -p "$REMOTE_PASS" rsync -a -e "ssh ${SSH_OPTS[*]}" "${REMOTE_HOST}:${remote_dir}/gamelist.xml" "$tmp_gamelist" >/dev/null 2>&1; then
        prepare_remote_gamelist_artwork_import "$system" "$tmp_files" "$tmp_gamelist" "$local_dir/gamelist.xml" "$tmp_artwork_files" "$tmp_merged_gamelist"
        if [[ -s "$tmp_artwork_files" ]]; then
          echo "  ${system}: importing $(wc -l < "$tmp_artwork_files" | tr -d ' ') artwork file(s)"
          sshpass -p "$REMOTE_PASS" rsync -av --files-from="$tmp_artwork_files" -e "ssh ${SSH_OPTS[*]}" "${REMOTE_HOST}:${remote_dir}/" "${local_dir}/"
        fi
        mv "$tmp_merged_gamelist" "$local_dir/gamelist.xml"
      else
        echo "  ${system}: no remote gamelist.xml found; skipped artwork import"
      fi
    fi
  done

  echo "Importing optional remote BIOS files from ${REMOTE_HOST}:${REMOTE_BIOS_BASE}"
  : > "$tmp_files"
  sshpass -p "$REMOTE_PASS" ssh "${SSH_OPTS[@]}" "$REMOTE_HOST" "
    if [ ! -d '$REMOTE_BIOS_BASE' ]; then exit 0; fi
    cd '$REMOTE_BIOS_BASE' || exit 0
    find . -type f -size -${MAX_BIOS_SIZE_KB}k | sort | sed 's#^\./##'
  " </dev/null > "$tmp_files"
  sampled_bios_files="$(mktemp)"
  sample_file_list "$tmp_files" "$MAX_BIOS_FILES" > "$sampled_bios_files"
  mv "$sampled_bios_files" "$tmp_files"
  if [[ -s "$tmp_files" ]]; then
    echo "  bios: importing $(wc -l < "$tmp_files" | tr -d ' ') file(s)"
    sshpass -p "$REMOTE_PASS" rsync -av --files-from="$tmp_files" -e "ssh ${SSH_OPTS[*]}" "${REMOTE_HOST}:${REMOTE_BIOS_BASE}/" "${LOCAL_BIOS_BASE}/"
  fi
elif [[ "$GENERATE_ONLY" != "true" ]]; then
  echo "No SSH password provided; skipped optional remote ROM and BIOS import."
  echo "Pass --password=linux or set BATOCERA_SSH_PASSWORD to import from ${REMOTE_HOST}."
fi

echo "Batocera-like test data ready under: $DATA_ROOT"
