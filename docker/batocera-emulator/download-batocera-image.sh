#!/usr/bin/env bash
set -euo pipefail

# Multi-threaded Batocera image downloader for macOS.
# Uses Homebrew to install aria2 if missing.
#
# Usage:
#   ./download-batocera-image.sh
#   ./download-batocera-image.sh x86_64
#   ./download-batocera-image.sh rpi5
#   ./download-batocera-image.sh "https://updates.batocera.org/x86_64/stable/last/batocera-x86_64-43-20260430.img.gz"
#
# Downloads are decompressed by default. The original .gz or .zip file is deleted after successful extraction.
#
# Notes:
#   macOS ships with Bash 3.x, so this script intentionally avoids associative arrays.

BATOCERA_INPUT="${1:-}"

OUTPUT_DIR="${OUTPUT_DIR:-.}"
OUTPUT_NAME="${OUTPUT_NAME:-}"
CONNECTIONS="${CONNECTIONS:-8}"
SPLITS="${SPLITS:-8}"
DECOMPRESS="${DECOMPRESS:-true}"
DELETE_ARCHIVE_AFTER_DECOMPRESS="${DELETE_ARCHIVE_AFTER_DECOMPRESS:-true}"
BATOCERA_VERSION="${BATOCERA_VERSION:-43}"
BATOCERA_DATE="${BATOCERA_DATE:-20260430}"

image_url_for_key() {
  local key="$1"

  case "${key}" in
    x86_64|pc|desktop)
      echo "https://updates.batocera.org/x86_64/stable/last/batocera-x86_64-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    steamdeck)
      echo "https://updates.batocera.org/steamdeck/stable/last/batocera-steamdeck-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    rpi5)
      echo "https://updates.batocera.org/bcm2712/stable/last/batocera-bcm2712-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    rpi4|rpi400)
      echo "https://updates.batocera.org/bcm2711/stable/last/batocera-bcm2711-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    rpi3)
      echo "https://updates.batocera.org/bcm2837/stable/last/batocera-bcm2837-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    rpi2)
      echo "https://updates.batocera.org/bcm2836/stable/last/batocera-bcm2836-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    rpi0|rpi1)
      echo "https://updates.batocera.org/rpi1/stable/last/batocera-rpi1-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    odroid-goa)
      echo "https://updates.batocera.org/odroidgoa/stable/last/batocera-odroidgoa-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    odroid-c2)
      echo "https://updates.batocera.org/odroidc2/stable/last/batocera-odroidc2-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    odroid-c4)
      echo "https://updates.batocera.org/odroidc4/stable/last/batocera-odroidc4-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    odroid-n2)
      echo "https://updates.batocera.org/odroidn2/stable/last/batocera-odroidn2-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    odroid-xu4)
      echo "https://updates.batocera.org/odroidxu4/stable/last/batocera-odroidxu4-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    rg351p)
      echo "https://updates.batocera.org/rg351p/stable/last/batocera-rg351p-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    rg353)
      echo "https://updates.batocera.org/rg353/stable/last/batocera-rg353-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    rg552)
      echo "https://updates.batocera.org/rg552/stable/last/batocera-rg552-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    orangepi5)
      echo "https://updates.batocera.org/orangepi-5/stable/last/batocera-orangepi-5-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    orangepi5b)
      echo "https://updates.batocera.org/orangepi-5b/stable/last/batocera-orangepi-5b-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    orangepi5plus)
      echo "https://updates.batocera.org/orangepi-5-plus/stable/last/batocera-orangepi-5-plus-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    rock5b)
      echo "https://updates.batocera.org/rock-5b/stable/last/batocera-rock-5b-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    rockpro64)
      echo "https://updates.batocera.org/rockpro64/stable/last/batocera-rockpro64-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    khadas-vim3)
      echo "https://updates.batocera.org/khadas-vim3/stable/last/batocera-khadas-vim3-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    khadas-edge2)
      echo "https://updates.batocera.org/khadas-edge2/stable/last/batocera-khadas-edge2-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"
      ;;
    *)
      return 1
      ;;
  esac
}

print_image_keys() {
  cat <<EOF
  desktop           https://updates.batocera.org/x86_64/stable/last/batocera-x86_64-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  khadas-edge2      https://updates.batocera.org/khadas-edge2/stable/last/batocera-khadas-edge2-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  khadas-vim3       https://updates.batocera.org/khadas-vim3/stable/last/batocera-khadas-vim3-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  odroid-c2         https://updates.batocera.org/odroidc2/stable/last/batocera-odroidc2-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  odroid-c4         https://updates.batocera.org/odroidc4/stable/last/batocera-odroidc4-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  odroid-goa        https://updates.batocera.org/odroidgoa/stable/last/batocera-odroidgoa-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  odroid-n2         https://updates.batocera.org/odroidn2/stable/last/batocera-odroidn2-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  odroid-xu4        https://updates.batocera.org/odroidxu4/stable/last/batocera-odroidxu4-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  orangepi5         https://updates.batocera.org/orangepi-5/stable/last/batocera-orangepi-5-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  orangepi5b        https://updates.batocera.org/orangepi-5b/stable/last/batocera-orangepi-5b-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  orangepi5plus     https://updates.batocera.org/orangepi-5-plus/stable/last/batocera-orangepi-5-plus-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  pc                https://updates.batocera.org/x86_64/stable/last/batocera-x86_64-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rg351p            https://updates.batocera.org/rg351p/stable/last/batocera-rg351p-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rg353             https://updates.batocera.org/rg353/stable/last/batocera-rg353-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rg552             https://updates.batocera.org/rg552/stable/last/batocera-rg552-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rock5b            https://updates.batocera.org/rock-5b/stable/last/batocera-rock-5b-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rockpro64         https://updates.batocera.org/rockpro64/stable/last/batocera-rockpro64-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rpi0              https://updates.batocera.org/rpi1/stable/last/batocera-rpi1-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rpi1              https://updates.batocera.org/rpi1/stable/last/batocera-rpi1-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rpi2              https://updates.batocera.org/bcm2836/stable/last/batocera-bcm2836-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rpi3              https://updates.batocera.org/bcm2837/stable/last/batocera-bcm2837-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rpi4              https://updates.batocera.org/bcm2711/stable/last/batocera-bcm2711-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rpi400            https://updates.batocera.org/bcm2711/stable/last/batocera-bcm2711-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  rpi5              https://updates.batocera.org/bcm2712/stable/last/batocera-bcm2712-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  steamdeck         https://updates.batocera.org/steamdeck/stable/last/batocera-steamdeck-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
  x86_64            https://updates.batocera.org/x86_64/stable/last/batocera-x86_64-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz
EOF
}

usage() {
  cat <<EOF
Usage:
  ./download-batocera-image.sh <image-key-or-url>

Examples:
  ./download-batocera-image.sh x86_64
  ./download-batocera-image.sh rpi5
  ./download-batocera-image.sh steamdeck
  ./download-batocera-image.sh "https://updates.batocera.org/x86_64/stable/last/batocera-x86_64-${BATOCERA_VERSION}-${BATOCERA_DATE}.img.gz"

Optional environment variables:
  OUTPUT_DIR                       Directory to save image. Default: .
  OUTPUT_NAME                      Output filename. Default: derived from URL
  CONNECTIONS                      Connections per server. Default: 8
  SPLITS                           Download splits. Default: 8
  DECOMPRESS                       Decompress .gz or .zip after download. Default: true
  DELETE_ARCHIVE_AFTER_DECOMPRESS  Delete archive after successful decompression. Default: true
  BATOCERA_VERSION                 Batocera version. Default: 43
  BATOCERA_DATE                    Batocera build date. Default: 20260430

Available image keys:
EOF

  print_image_keys
}

require_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew is not installed."
    echo "Install Homebrew first:"
    echo "  https://brew.sh"
    exit 1
  fi
}

ensure_aria2() {
  require_brew

  if command -v aria2c >/dev/null 2>&1; then
    return
  fi

  echo "aria2c not found. Installing aria2 with Homebrew..."
  brew install aria2

  if ! command -v aria2c >/dev/null 2>&1; then
    echo "ERROR: aria2c still not found after brew install aria2"
    exit 1
  fi
}

resolve_url() {
  local input="$1"
  local url=""

  if [[ "${input}" =~ ^https?:// ]]; then
    echo "${input}"
    return
  fi

  if url="$(image_url_for_key "${input}")"; then
    echo "${url}"
    return
  fi

  echo "ERROR: Unknown Batocera image key: ${input}" >&2
  echo >&2
  usage >&2
  exit 1
}

derive_output_name() {
  local url="$1"

  if [[ -n "${OUTPUT_NAME}" ]]; then
    echo "${OUTPUT_NAME}"
    return
  fi

  basename "${url%%\?*}"
}

download_image() {
  local url="$1"
  local filename=""
  local output_path=""

  filename="$(derive_output_name "${url}")"
  output_path="${OUTPUT_DIR}/${filename}"

  mkdir -p "${OUTPUT_DIR}"

  echo "======================================="
  echo "Downloading Batocera image"
  echo "======================================="
  echo "Input:        ${BATOCERA_INPUT}"
  echo "URL:          ${url}"
  echo "Output:       ${output_path}"
  echo "Connections:  ${CONNECTIONS}"
  echo "Splits:       ${SPLITS}"
  echo "Decompress:   ${DECOMPRESS}"
  echo "Delete archive after decompress: ${DELETE_ARCHIVE_AFTER_DECOMPRESS}"
  echo "======================================="

  aria2c \
    --continue=true \
    --max-connection-per-server="${CONNECTIONS}" \
    --split="${SPLITS}" \
    --min-split-size=1M \
    --file-allocation=none \
    --summary-interval=10 \
    --dir="${OUTPUT_DIR}" \
    --out="${filename}" \
    "${url}"

  if [[ "${DECOMPRESS}" == "true" && "${output_path}" == *.gz ]]; then
    local decompressed_path="${output_path%.gz}"

    echo "Decompressing gzip archive: ${output_path}"

    if [[ "${DELETE_ARCHIVE_AFTER_DECOMPRESS}" == "true" ]]; then
      gunzip -f "${output_path}"
    else
      gunzip -c "${output_path}" > "${decompressed_path}"
    fi

    echo "Decompressed image:"
    ls -lh "${decompressed_path}"

    if [[ "${DELETE_ARCHIVE_AFTER_DECOMPRESS}" == "true" ]]; then
      echo "Deleted archive: ${output_path}"
    else
      echo "Kept archive: ${output_path}"
    fi
  elif [[ "${DECOMPRESS}" == "true" && "${output_path}" == *.zip ]]; then
    local extract_dir="${OUTPUT_DIR}"

    echo "Decompressing zip archive: ${output_path}"
    unzip -o "${output_path}" -d "${extract_dir}"

    if [[ "${DELETE_ARCHIVE_AFTER_DECOMPRESS}" == "true" ]]; then
      rm -f "${output_path}"
      echo "Deleted archive: ${output_path}"
    else
      echo "Kept archive: ${output_path}"
    fi

    echo "Extracted files in: ${extract_dir}"
    ls -lh "${extract_dir}"
  else
    echo "Downloaded image:"
    ls -lh "${output_path}"
  fi
}

main() {
  if [[ -z "${BATOCERA_INPUT}" ]]; then
    usage
    exit 0
  fi

  ensure_aria2

  local url=""
  url="$(resolve_url "${BATOCERA_INPUT}")"

  download_image "${url}"
}

main "$@"