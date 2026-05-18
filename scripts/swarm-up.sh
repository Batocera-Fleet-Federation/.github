#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/.github/docker/docker-compose.swarm.yml"
ROM_ROOT="$ROOT_DIR/.github/data/roms"
BROWSER="Google Chrome"

URLS=(
  "https://bff-overmind:8000"
  "https://bff-drone-a:8443"
  "https://bff-drone-b:8444"
  "https://bff-drone-c:8445"
  "https://bff-drone-d:8446"
)

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
  if [[ ! -d "$ROM_ROOT" ]] || ! find "$ROM_ROOT" -type f ! -name ".gitkeep" ! -name "README.md" | grep -q .; then
    cat >&2 <<EOF
No ROM files found in $ROM_ROOT.
Import or place test ROMs under .github/data/roms/<system>/<files> first.
You can run: .github/scripts/import-roms-remotely.sh
EOF
    exit 1
  fi
}

main() {
  validate_roms_exist
  update_hosts_from_urls

  echo "Starting local Batocera Fleet Federation swarm..."
  docker compose -f "$COMPOSE_FILE" up -d --build "$@"

  echo "Current swarm containers:"
  docker compose -f "$COMPOSE_FILE" ps

  open_swarm_urls
}

main "$@"