#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-bff-overmind}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
PUBLIC_URL="${PUBLIC_URL:-https://www.batocera-swarm.com}"
SINCE="${SINCE:-1h}"
LOG_FORMAT="${LOG_FORMAT:-short}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

API_NAME="${API_NAME:-${PROJECT_NAME}-${ENVIRONMENT}}"
DOMAIN_NAME="${DOMAIN_NAME:-${PUBLIC_URL#https://}}"
DOMAIN_NAME="${DOMAIN_NAME#http://}"
DOMAIN_NAME="${DOMAIN_NAME%%/*}"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_ROOT="${OUTPUT_ROOT:-${SCRIPT_DIR}/debug-output/overmind-lambda}"
RUN_DIR="${RUN_DIR:-${OUTPUT_ROOT}/${timestamp}}"
mkdir -p "${RUN_DIR}"
output_file="${RUN_DIR}/combined.log"

exec > >(tee "${output_file}") 2>&1

section_index=0

section() {
  printf '\n\n===== %s =====\n' "$1"
}

section_file() {
  section_index=$((section_index + 1))
  local name
  name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s/%02d-%s.log' "${RUN_DIR}" "${section_index}" "${name}"
}

run() {
  local title="$1"
  local file
  file="$(section_file "${title}")"
  section "${title}"
  printf 'file=%s\n' "${file}"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } >"${file}" 2>&1 || true
  cat "${file}"
}

run_shell() {
  local title="$1"
  local file
  file="$(section_file "${title}")"
  section "${title}"
  printf 'file=%s\n' "${file}"
  shift
  {
    printf '$ bash -lc %q\n\n' "$*"
    bash -lc "$*"
  } >"${file}" 2>&1 || true
  cat "${file}"
}

redact() {
  sed -E 's/((TOKEN|SECRET|PASSWORD|PASS|KEY|AUTH|COOKIE|SESSION|CREDENTIAL|PRIVATE)[A-Z0-9_ -]*[=:])[^\\" ]+/\1<redacted>/Ig'
}

aws_json() {
  aws --region "${AWS_REGION}" "$@" --output json | redact
}

lambda_functions=(
  "${PROJECT_NAME}-${ENVIRONMENT}-low"
  "${PROJECT_NAME}-${ENVIRONMENT}-medium"
  "${PROJECT_NAME}-${ENVIRONMENT}-high"
  "${PROJECT_NAME}-${ENVIRONMENT}-scheduled"
)

section "debug metadata"
metadata_file="$(section_file "debug metadata")"
date -u
printf 'aws_region=%s\n' "${AWS_REGION}"
printf 'project_name=%s environment=%s\n' "${PROJECT_NAME}" "${ENVIRONMENT}"
printf 'public_url=%s domain_name=%s api_name=%s since=%s\n' "${PUBLIC_URL}" "${DOMAIN_NAME}" "${API_NAME}" "${SINCE}"
printf 'run_dir=%s\n' "${RUN_DIR}"
printf 'combined_log=%s\n' "${output_file}"
{
  date -u
  printf 'aws_region=%s\n' "${AWS_REGION}"
  printf 'project_name=%s environment=%s\n' "${PROJECT_NAME}" "${ENVIRONMENT}"
  printf 'public_url=%s domain_name=%s api_name=%s since=%s\n' "${PUBLIC_URL}" "${DOMAIN_NAME}" "${API_NAME}" "${SINCE}"
  printf 'run_dir=%s\n' "${RUN_DIR}"
  printf 'combined_log=%s\n' "${output_file}"
} >"${metadata_file}"

run "aws caller identity" aws sts get-caller-identity

section "discover http api"
discover_file="$(section_file "discover http api")"
api_json="$(aws_json apigatewayv2 get-apis --query "Items[?Name=='${API_NAME}'] | [0]")"
printf '%s\n' "${api_json}"
printf '%s\n' "${api_json}" >"${discover_file}"
api_id="$(aws --region "${AWS_REGION}" apigatewayv2 get-apis --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null || true)"
api_endpoint="$(aws --region "${AWS_REGION}" apigatewayv2 get-apis --query "Items[?Name=='${API_NAME}'].ApiEndpoint | [0]" --output text 2>/dev/null || true)"
if [[ "${api_id}" == "None" ]]; then
  api_id=""
fi
if [[ "${api_endpoint}" == "None" ]]; then
  api_endpoint=""
fi

if [[ -n "${api_id}" ]]; then
  run "api routes" aws_json apigatewayv2 get-routes --api-id "${api_id}"
  run "api integrations" aws_json apigatewayv2 get-integrations --api-id "${api_id}"
  run "api stages" aws_json apigatewayv2 get-stages --api-id "${api_id}"
else
  echo "No API found with name ${API_NAME}."
fi

run "custom domain" aws_json apigatewayv2 get-domain-name --domain-name "${DOMAIN_NAME}"
run "custom domain mappings" aws_json apigatewayv2 get-api-mappings --domain-name "${DOMAIN_NAME}"

run_shell "dns public domain" "dig +short ${DOMAIN_NAME} A; dig +short ${DOMAIN_NAME} AAAA; dig +short ${DOMAIN_NAME} CNAME"
if [[ -n "${api_endpoint}" ]]; then
  run_shell "dns raw api endpoint" "dig +short ${api_endpoint#https://} A"
fi

run_shell "curl public root" "curl -vk --max-time 20 -o '${RUN_DIR}/public-root-body.html' -w 'http_code=%{http_code} time_connect=%{time_connect} time_tls=%{time_appconnect} time_starttransfer=%{time_starttransfer} time_total=%{time_total} size=%{size_download}\n' '${PUBLIC_URL}/'; head -c 1500 '${RUN_DIR}/public-root-body.html'; echo"
if [[ -n "${api_endpoint}" ]]; then
  run_shell "curl raw api root" "curl -vk --max-time 20 -o '${RUN_DIR}/raw-api-root-body.html' -w 'http_code=%{http_code} time_connect=%{time_connect} time_tls=%{time_appconnect} time_starttransfer=%{time_starttransfer} time_total=%{time_total} size=%{size_download}\n' '${api_endpoint}/'; head -c 1500 '${RUN_DIR}/raw-api-root-body.html'; echo"
fi

for fn in "${lambda_functions[@]}"; do
  run "lambda configuration ${fn}" aws_json lambda get-function-configuration --function-name "${fn}"
  run "lambda code ${fn}" aws_json lambda get-function --function-name "${fn}" --query 'Code'
  run "lambda recent logs ${fn}" aws logs tail "/aws/lambda/${fn}" --region "${AWS_REGION}" --since "${SINCE}" --format "${LOG_FORMAT}"
done

run "api gateway access logs" aws logs tail "/aws/apigateway/${PROJECT_NAME}-${ENVIRONMENT}-overmind" --region "${AWS_REGION}" --since "${SINCE}" --format "${LOG_FORMAT}"

section "cloudwatch alarms"
alarms_file="$(section_file "cloudwatch alarms")"
aws_json cloudwatch describe-alarms \
  --alarm-name-prefix "${PROJECT_NAME}-${ENVIRONMENT}" \
  --query 'MetricAlarms[].{AlarmName:AlarmName,StateValue:StateValue,StateReason:StateReason,MetricName:MetricName,Dimensions:Dimensions}' >"${alarms_file}" 2>&1 || true
cat "${alarms_file}"

section "done"
date -u
echo "Saved debug folder: ${RUN_DIR}"
echo "Saved combined log: ${output_file}"
