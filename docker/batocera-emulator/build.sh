#!/usr/bin/env bash
set -euo pipefail

COMMAND="build"

IMAGE_REGISTRY="ghcr.io"
IMAGE_OWNER="Batocera-Fleet-Federation"
IMAGE_NAME="batocera-emulator"
IMAGE_TAG="v43"
LOCAL_IMAGE_NAME="batocera-qemu:test"

DOCKERFILE="Dockerfile"
BUILD_CONTEXT="."
PLATFORM=""
TAG_LOCAL_SHORT="true"

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

refresh_image_ref() {
  IMAGE_OWNER_LOWER="$(lowercase "${IMAGE_OWNER}")"
  IMAGE_NAME_LOWER="$(lowercase "${IMAGE_NAME}")"
  IMAGE_REF="${IMAGE_REGISTRY}/${IMAGE_OWNER_LOWER}/${IMAGE_NAME_LOWER}"
}

usage() {
  refresh_image_ref

  cat <<EOF_USAGE
Usage:
  ./build.sh [command] [options]

Commands:
  build   Build local Docker image [default]
  clean   Remove local image tags
  help    Show this help

Options:
  --image-registry <value>       Default: ghcr.io
  --image-owner <value>          Default: Batocera-Fleet-Federation
  --image-name <value>           Default: batocera-emulator
  --image-tag <value>            Default: v43
  --local-image-name <value>     Default: batocera-qemu:test
  --dockerfile <path>            Default: Dockerfile
  --build-context <path>         Default: .
  --platform <platform>          Default: auto-detect
  --tag-local-short <true|false> Default: true
  -h, --help                     Show this help

Resulting tags:
  ${IMAGE_REF}:${IMAGE_TAG}
  ${IMAGE_REF}:latest
  ${LOCAL_IMAGE_NAME}

Examples:
  ./build.sh
  ./build.sh build --platform linux/amd64
  ./build.sh build --image-tag v43
  ./build.sh clean

Note:
  This build does not copy a Batocera .img into the Docker image.
  The Docker image contains the QEMU runner only.
  Mount the Batocera .img at runtime with:
    ./run.sh --batocera-img <path-to-batocera.img>
EOF_USAGE
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      build|clean|help|-h|--help)
        COMMAND="$1"
        shift
        ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image-registry)
        IMAGE_REGISTRY="${2:-}"
        shift 2
        ;;
      --image-owner)
        IMAGE_OWNER="${2:-}"
        shift 2
        ;;
      --image-name)
        IMAGE_NAME="${2:-}"
        shift 2
        ;;
      --image-tag)
        IMAGE_TAG="${2:-}"
        shift 2
        ;;
      --local-image-name)
        LOCAL_IMAGE_NAME="${2:-}"
        shift 2
        ;;
      --dockerfile)
        DOCKERFILE="${2:-}"
        shift 2
        ;;
      --build-context)
        BUILD_CONTEXT="${2:-}"
        shift 2
        ;;
      --platform)
        PLATFORM="${2:-}"
        shift 2
        ;;
      --tag-local-short)
        TAG_LOCAL_SHORT="${2:-}"
        shift 2
        ;;
      -h|--help)
        COMMAND="help"
        shift
        ;;
      *)
        echo "ERROR: Unknown argument: $1"
        echo
        usage
        exit 1
        ;;
    esac
  done

  refresh_image_ref
}

validate_args() {
  if [[ -z "${IMAGE_REGISTRY}" ]]; then
    echo "ERROR: --image-registry cannot be empty"
    exit 1
  fi

  if [[ -z "${IMAGE_OWNER}" ]]; then
    echo "ERROR: --image-owner cannot be empty"
    exit 1
  fi

  if [[ -z "${IMAGE_NAME}" ]]; then
    echo "ERROR: --image-name cannot be empty"
    exit 1
  fi

  if [[ -z "${IMAGE_TAG}" ]]; then
    echo "ERROR: --image-tag cannot be empty"
    exit 1
  fi

  if [[ -z "${LOCAL_IMAGE_NAME}" ]]; then
    echo "ERROR: --local-image-name cannot be empty"
    exit 1
  fi

  if [[ -z "${DOCKERFILE}" ]]; then
    echo "ERROR: --dockerfile cannot be empty"
    exit 1
  fi

  if [[ -z "${BUILD_CONTEXT}" ]]; then
    echo "ERROR: --build-context cannot be empty"
    exit 1
  fi

  if [[ "${TAG_LOCAL_SHORT}" != "true" && "${TAG_LOCAL_SHORT}" != "false" ]]; then
    echo "ERROR: --tag-local-short must be true or false"
    exit 1
  fi
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

validate_files() {
  if [[ ! -f "${DOCKERFILE}" ]]; then
    echo "ERROR: Missing Dockerfile: ${DOCKERFILE}"
    exit 1
  fi

  if [[ ! -f "entrypoint.sh" ]]; then
    echo "ERROR: Missing entrypoint.sh"
    exit 1
  fi
}

build_image() {
  local platform
  platform="$(detect_platform)"

  validate_docker
  validate_files

  echo "======================================="
  echo "Building Batocera QEMU runner image"
  echo "======================================="
  echo "Image:       ${IMAGE_REF}:${IMAGE_TAG}"
  echo "Latest:      ${IMAGE_REF}:latest"
  echo "Local short: ${LOCAL_IMAGE_NAME}"
  echo "Platform:    ${platform}"
  echo "Dockerfile:  ${DOCKERFILE}"
  echo "Context:     ${BUILD_CONTEXT}"
  echo "Batocera:    mounted at runtime, not copied into image"
  echo "======================================="

  docker build \
    --platform "${platform}" \
    -t "${IMAGE_REF}:${IMAGE_TAG}" \
    -t "${IMAGE_REF}:latest" \
    -f "${DOCKERFILE}" \
    "${BUILD_CONTEXT}"

  if [[ "${TAG_LOCAL_SHORT}" == "true" ]]; then
    docker tag "${IMAGE_REF}:${IMAGE_TAG}" "${LOCAL_IMAGE_NAME}"
  fi
}

clean_images() {
  validate_docker

  docker rmi -f "${IMAGE_REF}:${IMAGE_TAG}" 2>/dev/null || true
  docker rmi -f "${IMAGE_REF}:latest" 2>/dev/null || true
  docker rmi -f "${LOCAL_IMAGE_NAME}" 2>/dev/null || true
}

main() {
  parse_args "$@"
  validate_args

  case "${COMMAND}" in
    build)
      build_image
      ;;
    clean)
      clean_images
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "ERROR: Unknown command: ${COMMAND}"
      echo
      usage
      exit 1
      ;;
  esac
}

main "$@"