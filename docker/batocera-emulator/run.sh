#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="ghcr.io/batocera-fleet-federation/batocera-emulator:latest"
CONTAINER_NAME="batocera-qemu-test"

VM_MEM="4096"
VM_CPUS="2"

SSH_HOST_PORT="2222"
VNC_HOST_PORT="5901"

PLATFORM=""
BATOCERA_IMG=""

usage() {
  cat <<EOF
Usage:
  ./run.sh [options]

Options:
  --image-name <value>       Docker image name. Default: batocera-emulator:test
  --container-name <value>   Container name. Default: batocera-qemu-test
  --memory <mb>              VM memory in MB. Default: 4096
  --cpus <count>             VM CPU count. Default: 2
  --ssh-port <port>          Host SSH port. Default: 2222
  --vnc-port <port>          Host VNC port. Default: 5901
  --platform <platform>      Docker platform. Default: auto-detect
  --batocera-img <path>      Batocera .img file. Default: auto-detect exactly one batocera*.img file
  --clean                    Stop/remove existing container and exit
  -h, --help                 Show this help

Examples:
  ./run.sh
  ./run.sh --memory 8192 --cpus 4
  ./run.sh --platform linux/amd64
  ./run.sh --batocera-img ./batocera-v43_x86_64.img
  ./run.sh \\
    --image-name ghcr.io/batocera-fleet-federation/batocera-emulator:v43 \\
    --memory 4096 \\
    --cpus 2
  ./run.sh --clean
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image-name)
        IMAGE_NAME="${2:-}"
        shift 2
        ;;
      --container-name)
        CONTAINER_NAME="${2:-}"
        shift 2
        ;;
      --memory)
        VM_MEM="${2:-}"
        shift 2
        ;;
      --cpus)
        VM_CPUS="${2:-}"
        shift 2
        ;;
      --ssh-port)
        SSH_HOST_PORT="${2:-}"
        shift 2
        ;;
      --vnc-port)
        VNC_HOST_PORT="${2:-}"
        shift 2
        ;;
      --platform)
        PLATFORM="${2:-}"
        shift 2
        ;;
      --batocera-img)
        BATOCERA_IMG="${2:-}"
        shift 2
        ;;
      --clean)
        ACTION="clean"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: Unknown argument: $1"
        echo
        usage
        exit 1
        ;;
    esac
  done
}

detect_platform() {
  if [[ -n "${PLATFORM}" ]]; then
    echo "${PLATFORM}"
    return
  fi

  local kernel
  local arch

  kernel="$(uname -s)"
  arch="$(uname -m)"

  case "${kernel}:${arch}" in
    Darwin:arm64)
      echo "linux/amd64"
      ;;
    Darwin:x86_64)
      echo "linux/amd64"
      ;;
    Linux:x86_64)
      echo "linux/amd64"
      ;;
    Linux:aarch64|Linux:arm64)
      echo "linux/arm64"
      ;;
    *)
      echo "linux/amd64"
      ;;
  esac
}

validate_args() {
  if [[ -z "${IMAGE_NAME}" ]]; then
    echo "ERROR: --image-name cannot be empty"
    exit 1
  fi

  if [[ -z "${CONTAINER_NAME}" ]]; then
    echo "ERROR: --container-name cannot be empty"
    exit 1
  fi

  if ! [[ "${VM_MEM}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --memory must be a number in MB"
    exit 1
  fi

  if ! [[ "${VM_CPUS}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --cpus must be a number"
    exit 1
  fi

  if ! [[ "${SSH_HOST_PORT}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --ssh-port must be a number"
    exit 1
  fi

  if ! [[ "${VNC_HOST_PORT}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --vnc-port must be a number"
    exit 1
  fi
}

validate_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker command not found."
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not running or is not reachable."
    echo
    echo "If using Rancher Desktop, make sure it is running and Container Engine is set to dockerd/moby."
    echo "Then verify with: docker info"
    exit 1
  fi
}

validate_image() {
  if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    echo "ERROR: Docker image not found: ${IMAGE_NAME}"
    echo
    echo "Build it first:"
    echo "  ./build.sh"
    echo
    echo "Or pass a pushed image:"
    echo "  ./run.sh --image-name ghcr.io/batocera-fleet-federation/batocera-emulator:v43"
    exit 1
  fi
}

resolve_batocera_img() {
  if [[ -n "${BATOCERA_IMG}" ]]; then
    if [[ ! -f "${BATOCERA_IMG}" ]]; then
      echo "ERROR: Batocera image not found: ${BATOCERA_IMG}"
      exit 1
    fi
    return
  fi

  local matches=()
  local match

  shopt -s nullglob
  matches=(batocera*.img)
  shopt -u nullglob

  if [[ ${#matches[@]} -eq 1 ]]; then
    BATOCERA_IMG="${matches[0]}"
    return
  fi

  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "ERROR: No Batocera image found."
    echo
    echo "Expected exactly one file matching: batocera*.img"
    echo "Or specify the image explicitly:"
    echo "  ./run.sh --batocera-img <path-to-batocera.img>"
    echo
    echo "Current directory: $(pwd)"
    echo
    echo "Files:"
    ls -lh
    exit 1
  fi

  echo "ERROR: Multiple Batocera images found."
  echo
  echo "Expected exactly one file matching: batocera*.img"
  echo "Specify the image explicitly:"
  echo "  ./run.sh --batocera-img <path-to-batocera.img>"
  echo
  echo "Matches:"
  for match in "${matches[@]}"; do
    echo "  ${match}"
  done
  exit 1
}

clean_container() {
  validate_docker

  if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Removing existing container: ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null
  else
    echo "No existing container found: ${CONTAINER_NAME}"
  fi
}

run_container() {
  local platform
  platform="$(detect_platform)"

  validate_docker
  validate_image
  resolve_batocera_img

  if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Removing existing container: ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null
  fi

  echo "======================================="
  echo "Running Batocera QEMU container"
  echo "======================================="
  echo "Image:      ${IMAGE_NAME}"
  echo "Batocera:   ${BATOCERA_IMG}"
  echo "Container:  ${CONTAINER_NAME}"
  echo "Platform:   ${platform}"
  echo "Memory:     ${VM_MEM} MB"
  echo "CPUs:       ${VM_CPUS}"
  echo "SSH:        ssh -p ${SSH_HOST_PORT} root@localhost"
  echo "Password:   linux"
  echo "VNC:        localhost:${VNC_HOST_PORT}"
  echo "======================================="

  docker run --rm -it \
    --name "${CONTAINER_NAME}" \
    --platform "${platform}" \
    -p "${SSH_HOST_PORT}:2222" \
    -p "${VNC_HOST_PORT}:5901" \
    -v "$(cd "$(dirname "${BATOCERA_IMG}")" && pwd)/$(basename "${BATOCERA_IMG}"):/vms/batocera.img:ro" \
    -e VM_MEM="${VM_MEM}" \
    -e VM_CPUS="${VM_CPUS}" \
    "${IMAGE_NAME}"
}

main() {
  ACTION="run"

  parse_args "$@"
  validate_args

  case "${ACTION}" in
    run)
      run_container
      ;;
    clean)
      clean_container
      ;;
    *)
      echo "ERROR: Unknown action: ${ACTION}"
      exit 1
      ;;
  esac
}

main "$@"