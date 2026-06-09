#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEDERATION_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CREDENTIALS_FILE="${BFF_CREDENTIALS_FILE:-${FEDERATION_ROOT}/.github/.credentials}"

usage() {
  cat <<'EOF'
Usage: .github/scripts/run-with-aws-credentials.sh <command> [args...]

Loads only AWS_* export assignments from .github/.credentials, then executes
the requested command. Credential values are never printed.

Examples:
  .github/scripts/run-with-aws-credentials.sh aws sts get-caller-identity
  .github/scripts/run-with-aws-credentials.sh .github/scripts/debug-overmind-lambda.sh
EOF
}

if [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ ! -r "${CREDENTIALS_FILE}" ]]; then
  echo "ERROR: Credentials file is not readable: ${CREDENTIALS_FILE}" >&2
  exit 1
fi

loaded=0
while IFS='=' read -r key value; do
  case "${key}" in
    AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AWS_DEFAULT_REGION|AWS_REGION)
      value="${value%$'\r'}"
      if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
      fi
      export "${key}=${value}"
      loaded=$((loaded + 1))
      ;;
  esac
done < <(sed -n -E 's/^[[:space:]]*export[[:space:]]+(AWS_[A-Z0-9_]+)=(.*)$/\1=\2/p' "${CREDENTIALS_FILE}")

if [[ "${loaded}" -eq 0 ]]; then
  echo "ERROR: No supported AWS export assignments found in ${CREDENTIALS_FILE}" >&2
  exit 1
fi

cd "${FEDERATION_ROOT}"
exec "$@"
