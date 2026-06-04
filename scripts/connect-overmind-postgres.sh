#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
SECRET_ID="${SECRET_ID:-bff-overmind/prod/runtime}"
SECRET_PASSWORD_KEY="${SECRET_PASSWORD_KEY:-OVERMIND_POSTGRES_PASSWORD}"
RDSHOST="${RDSHOST:-bff-overmind-prod.c2r6u6mq0c2n.us-east-1.rds.amazonaws.com}"
RDS_PORT="${RDS_PORT:-5432}"
RDS_DBNAME="${RDS_DBNAME:-overmind}"
RDS_USER="${RDS_USER:-overmind}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_FILE="${CERT_FILE:-${SCRIPT_DIR}/global-bundle.pem}"
CERT_URL="${CERT_URL:-https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command aws
require_command curl
require_command psql
require_command python3

if [[ ! -s "${CERT_FILE}" ]]; then
  echo "Downloading RDS CA bundle to ${CERT_FILE}" >&2
  curl -fsSL -o "${CERT_FILE}" "${CERT_URL}"
fi

echo "Reading ${SECRET_PASSWORD_KEY} from AWS Secrets Manager secret ${SECRET_ID}" >&2
secret_json="$(
  aws --region "${AWS_REGION}" secretsmanager get-secret-value \
    --secret-id "${SECRET_ID}" \
    --query SecretString \
    --output text
)"

export PGPASSWORD="$(
  SECRET_JSON="${secret_json}" python3 - "${SECRET_PASSWORD_KEY}" <<'PY'
import json
import os
import sys

key = sys.argv[1]
payload = json.loads(os.environ["SECRET_JSON"])
value = payload.get(key)
if not value:
    raise SystemExit(f"Secret key not found or empty: {key}")
print(value)
PY
)"

connection_string="host=${RDSHOST} port=${RDS_PORT} dbname=${RDS_DBNAME} user=${RDS_USER} sslmode=verify-full sslrootcert=${CERT_FILE}"

echo "Connecting to ${RDS_DBNAME} on ${RDSHOST}:${RDS_PORT} as ${RDS_USER}" >&2
exec psql "${connection_string}" "$@"
