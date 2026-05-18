#!/usr/bin/env bash
set -euo pipefail

# Pushes Batocera QEMU Docker images to GitHub Container Registry.
# Uses input parameters for configuration instead of environment variables.

COMMAND="push"

IMAGE_REGISTRY="ghcr.io"
IMAGE_OWNER="Batocera-Fleet-Federation"
IMAGE_NAME="batocera-emulator"
IMAGE_TAG="v43"

DOCKERFILE="Dockerfile"
BUILD_CONTEXT="."
BUILDER_NAME="batocera-qemu-builder"
PLATFORMS="linux/amd64,linux/arm64"

GHCR_USERNAME=""
GHCR_TOKEN=""

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

  cat <<EOF
Usage:
  ./push.sh [command] [options]

Commands:
  login        Login to GitHub Container Registry
  push         Build and push multi-platform image [default]
  push-x86     Build and push linux/amd64 image only
  push-arm     Build and push linux/arm64 image only
  push-apple   Build and push linux/arm64 image with Apple Silicon tag
  inspect      Show pushed manifest details
  clean        Remove the buildx builder created by this script
  help         Show this help

Options:
  --image-registry <value>          Default: ghcr.io
  --image-owner <value>             Default: Batocera-Fleet-Federation
  --image-name <value>              Default: batocera-emulator
  --image-tag <value>               Default: v43
  --dockerfile <path>               Default: Dockerfile
  --build-context <path>            Default: .
  --builder-name <value>            Default: batocera-qemu-builder
  --platforms <value>               Default: linux/amd64,linux/arm64
  --ghcr-username <value>           GitHub username for GHCR login. If omitted during login, you will be prompted.
  --ghcr-token <value>              GitHub token with write:packages permission. If omitted during login, you will be prompted securely.
  -h, --help                        Show this help

Published tags:
  ${IMAGE_REF}:${IMAGE_TAG}
  ${IMAGE_REF}:latest
  ${IMAGE_REF}:${IMAGE_TAG}-x86_64
  ${IMAGE_REF}:${IMAGE_TAG}-amd64
  ${IMAGE_REF}:${IMAGE_TAG}-arm64
  ${IMAGE_REF}:${IMAGE_TAG}-apple-silicon

Examples:
  ./push.sh login
  ./push.sh login --ghcr-username mynameisjerrod
  ./push.sh login --ghcr-username mynameisjerrod --ghcr-token ghp_xxx
  ./push.sh push
  ./push.sh push-x86
  ./push.sh push-arm
  ./push.sh push-apple
  ./push.sh inspect

  ./push.sh push --image-tag v43
  ./push.sh push --image-owner mynameisjerrod --image-name batocera-emulator --image-tag v43
  ./push.sh push --platforms linux/amd64

Note:
  Batocera .img files are intentionally not copied into pushed Docker images.
  The Docker image contains the QEMU runner only.
  Mount the Batocera .img at runtime with run.sh --batocera-img <path>.
EOF
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      login|push|push-x86|push-arm|push-apple|inspect|clean|help|-h|--help)
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
      --dockerfile)
        DOCKERFILE="${2:-}"
        shift 2
        ;;
      --build-context)
        BUILD_CONTEXT="${2:-}"
        shift 2
        ;;
      --builder-name)
        BUILDER_NAME="${2:-}"
        shift 2
        ;;
      --platforms)
        PLATFORMS="${2:-}"
        shift 2
        ;;
      --ghcr-username)
        GHCR_USERNAME="${2:-}"
        shift 2
        ;;
      --ghcr-token)
        GHCR_TOKEN="${2:-}"
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

  if [[ -z "${DOCKERFILE}" ]]; then
    echo "ERROR: --dockerfile cannot be empty"
    exit 1
  fi

  if [[ -z "${BUILD_CONTEXT}" ]]; then
    echo "ERROR: --build-context cannot be empty"
    exit 1
  fi

  if [[ -z "${BUILDER_NAME}" ]]; then
    echo "ERROR: --builder-name cannot be empty"
    exit 1
  fi

  if [[ -z "${PLATFORMS}" ]]; then
    echo "ERROR: --platforms cannot be empty"
    exit 1
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: Missing required command: ${command_name}"
    exit 1
  fi
}

validate_docker() {
  require_command docker

  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not running or is not reachable."
    echo
    echo "If using Rancher Desktop, make sure it is running and Container Engine is set to dockerd/moby."
    echo "Then verify with: docker info"
    exit 1
  fi

  if ! docker buildx version >/dev/null 2>&1; then
    echo "ERROR: docker buildx is not available."
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

print_login_instructions() {
  cat <<EOF
=======================================
GitHub Container Registry Login
=======================================
You need your GitHub username and a GitHub token.

Your GitHub username is the account handle shown on your GitHub profile URL:
  https://github.com/<username>

Examples:
  https://github.com/mynameisjerrod  -> username is mynameisjerrod
  @mynameisjerrod                   -> username is mynameisjerrod

The token is NOT your GitHub password.
Create a token with package publishing permissions:
  GitHub -> Settings -> Developer settings -> Personal access tokens

For a classic personal access token, enable:
  write:packages
  read:packages

If publishing to an organization, your GitHub user also needs permission to publish packages under that org.

EOF
}

prompt_for_ghcr_credentials() {
  if [[ -z "${GHCR_USERNAME}" ]]; then
    printf 'GitHub username: '
    read -r GHCR_USERNAME
  fi

  if [[ -z "${GHCR_TOKEN}" ]]; then
    echo
    echo "Paste your GitHub token. Input will be hidden."
    printf 'GitHub token: '
    stty -echo
    read -r GHCR_TOKEN
    stty echo
    echo
  fi
}

login_ghcr() {
  validate_docker
  print_login_instructions
  prompt_for_ghcr_credentials

  if [[ -z "${GHCR_USERNAME}" || -z "${GHCR_TOKEN}" ]]; then
    echo "ERROR: GitHub username and token are required for GHCR login."
    echo
    echo "Example:"
    echo '  ./push.sh login --ghcr-username my-github-user'
    exit 1
  fi

  echo
  echo "Logging in to ${IMAGE_REGISTRY} as ${GHCR_USERNAME}..."
  printf '%s' "${GHCR_TOKEN}" | docker login "${IMAGE_REGISTRY}" -u "${GHCR_USERNAME}" --password-stdin
}

ensure_builder() {
  validate_docker

  if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
    echo "Creating buildx builder: ${BUILDER_NAME}"
    docker buildx create --name "${BUILDER_NAME}" --use >/dev/null
  else
    docker buildx use "${BUILDER_NAME}" >/dev/null
  fi

  docker buildx inspect --bootstrap >/dev/null
}

print_config() {
  echo "======================================="
  echo "Batocera QEMU image push"
  echo "======================================="
  echo "Image:       ${IMAGE_REF}"
  echo "Tag:         ${IMAGE_TAG}"
  echo "Platforms:   ${PLATFORMS}"
  echo "Dockerfile:  ${DOCKERFILE}"
  echo "Context:     ${BUILD_CONTEXT}"
  echo "Builder:     ${BUILDER_NAME}"
  echo "======================================="
}

push_multiarch() {
  validate_files
  ensure_builder
  print_config

  docker buildx build \
    --platform "${PLATFORMS}" \
    --tag "${IMAGE_REF}:${IMAGE_TAG}" \
    --tag "${IMAGE_REF}:latest" \
    --file "${DOCKERFILE}" \
    --push \
    "${BUILD_CONTEXT}"
}

push_single_platform() {
  local platform="$1"
  local tag_suffix="$2"
  shift 2

  validate_files
  ensure_builder

  echo "======================================="
  echo "Building/pushing single-platform image"
  echo "======================================="
  echo "Image:      ${IMAGE_REF}"
  echo "Tag:        ${IMAGE_TAG}-${tag_suffix}"
  echo "Platform:   ${platform}"
  echo "Dockerfile: ${DOCKERFILE}"
  echo "Context:    ${BUILD_CONTEXT}"
  echo "======================================="

  docker buildx build \
    --platform "${platform}" \
    --tag "${IMAGE_REF}:${IMAGE_TAG}-${tag_suffix}" \
    "$@" \
    --file "${DOCKERFILE}" \
    --push \
    "${BUILD_CONTEXT}"
}

push_x86() {
  push_single_platform "linux/amd64" "x86_64" --tag "${IMAGE_REF}:${IMAGE_TAG}-amd64"
}

push_arm() {
  push_single_platform "linux/arm64" "arm64"
}

push_apple() {
  push_single_platform "linux/arm64" "apple-silicon"
}

inspect_manifest() {
  validate_docker

  echo "Inspecting: ${IMAGE_REF}:${IMAGE_TAG}"
  docker buildx imagetools inspect "${IMAGE_REF}:${IMAGE_TAG}"
}

clean_builder() {
  validate_docker

  if docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
    echo "Removing buildx builder: ${BUILDER_NAME}"
    docker buildx rm "${BUILDER_NAME}" >/dev/null
  else
    echo "Builder does not exist: ${BUILDER_NAME}"
  fi
}

main() {
  parse_args "$@"
  validate_args

  case "${COMMAND}" in
    login)
      login_ghcr
      ;;
    push)
      push_multiarch
      ;;
    push-x86)
      push_x86
      ;;
    push-arm)
      push_arm
      ;;
    push-apple)
      push_apple
      ;;
    inspect)
      inspect_manifest
      ;;
    clean)
      clean_builder
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