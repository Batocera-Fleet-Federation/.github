#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-bff-overmind}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
PUBLIC_URL="${PUBLIC_URL:-https://www.batocera-swarm.com}"
SINCE="${SINCE:-1h}"
LOG_FORMAT="${LOG_FORMAT:-short}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBUG_AUTH_EMAIL="${DEBUG_AUTH_EMAIL:-}"
DEBUG_AUTH_PASSWORD="${DEBUG_AUTH_PASSWORD:-}"
RUN_AUTH_PROBE="${RUN_AUTH_PROBE:-auto}"
export DEBUG_AUTH_EMAIL DEBUG_AUTH_PASSWORD

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

next_section_file() {
  local __resultvar="$1"
  shift
  section_index=$((section_index + 1))
  local name
  name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf -v "${__resultvar}" '%s/%02d-%s.log' "${RUN_DIR}" "${section_index}" "${name}"
}

run() {
  local title="$1"
  local file
  next_section_file file "${title}"
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
  next_section_file file "${title}"
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
  sed -E \
    -e 's/((TOKEN|SECRET|PASSWORD|PASS|KEY|AUTH|COOKIE|SESSION|CREDENTIAL|PRIVATE)[A-Z0-9_ -]*[=:])[^\\" ]+/\1<redacted>/Ig' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1<redacted>/g' \
    -e 's/("access_token"[[:space:]]*:[[:space:]]*")[^"]+/\1<redacted>/g'
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
next_section_file metadata_file "debug metadata"
date -u
printf 'aws_region=%s\n' "${AWS_REGION}"
printf 'project_name=%s environment=%s\n' "${PROJECT_NAME}" "${ENVIRONMENT}"
printf 'public_url=%s domain_name=%s api_name=%s since=%s\n' "${PUBLIC_URL}" "${DOMAIN_NAME}" "${API_NAME}" "${SINCE}"
printf 'run_auth_probe=%s auth_email_set=%s\n' "${RUN_AUTH_PROBE}" "$([[ -n "${DEBUG_AUTH_EMAIL}" && -n "${DEBUG_AUTH_PASSWORD}" ]] && echo true || echo false)"
printf 'run_dir=%s\n' "${RUN_DIR}"
printf 'combined_log=%s\n' "${output_file}"
{
  date -u
  printf 'aws_region=%s\n' "${AWS_REGION}"
  printf 'project_name=%s environment=%s\n' "${PROJECT_NAME}" "${ENVIRONMENT}"
  printf 'public_url=%s domain_name=%s api_name=%s since=%s\n' "${PUBLIC_URL}" "${DOMAIN_NAME}" "${API_NAME}" "${SINCE}"
  printf 'run_auth_probe=%s auth_email_set=%s\n' "${RUN_AUTH_PROBE}" "$([[ -n "${DEBUG_AUTH_EMAIL}" && -n "${DEBUG_AUTH_PASSWORD}" ]] && echo true || echo false)"
  printf 'run_dir=%s\n' "${RUN_DIR}"
  printf 'combined_log=%s\n' "${output_file}"
} >"${metadata_file}"

run "aws caller identity" aws sts get-caller-identity

section "discover http api"
next_section_file discover_file "discover http api"
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
  run_shell "api route integration summary" "python3 - '${RUN_DIR}/$(basename "$(ls "${RUN_DIR}"/*-api-routes.log 2>/dev/null | tail -n 1)")' '${RUN_DIR}/$(basename "$(ls "${RUN_DIR}"/*-api-integrations.log 2>/dev/null | tail -n 1)")' <<'PY'
import json, re, sys
routes_path, integrations_path = sys.argv[1], sys.argv[2]
def load(path):
    text = open(path, encoding='utf-8').read()
    start = text.find('{')
    return json.loads(text[start:]) if start >= 0 else {}
routes = load(routes_path).get('Items', [])
integrations = load(integrations_path).get('Items', [])
by_id = {item.get('IntegrationId'): item for item in integrations}
for route in sorted(routes, key=lambda r: r.get('RouteKey', '')):
    target = route.get('Target') or ''
    integration_id = target.split('/')[-1]
    integ = by_id.get(integration_id, {})
    uri = integ.get('IntegrationUri') or ''
    fn = re.search(r':function:([^:/]+)', uri)
    print(f\"{route.get('RouteKey')} -> {fn.group(1) if fn else uri or integration_id}\")
PY"
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

should_run_auth_probe=false
if [[ "${RUN_AUTH_PROBE}" == "true" || "${RUN_AUTH_PROBE}" == "1" || "${RUN_AUTH_PROBE}" == "yes" ]]; then
  should_run_auth_probe=true
elif [[ "${RUN_AUTH_PROBE}" == "auto" && -n "${DEBUG_AUTH_EMAIL}" && -n "${DEBUG_AUTH_PASSWORD}" ]]; then
  should_run_auth_probe=true
fi

if [[ "${should_run_auth_probe}" == "true" ]]; then
  run_shell "authenticated cross tier probe" "python3 - '${PUBLIC_URL}' '${RUN_DIR}' <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

base_url, run_dir = sys.argv[1:3]
email = os.environ.get('DEBUG_AUTH_EMAIL', '')
password = os.environ.get('DEBUG_AUTH_PASSWORD', '')
base_url = base_url.rstrip('/')

def request(method, path, *, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {'Accept': 'application/json'}
    if body is not None:
        headers['Content-Type'] = 'application/json'
    if token:
        headers['Authorization'] = f'Bearer {token}'
    req = urllib.request.Request(f'{base_url}{path}', data=data, headers=headers, method=method)
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            payload = response.read()
            return response.status, dict(response.headers), payload, time.monotonic() - started
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read(), time.monotonic() - started

status, headers, payload, elapsed = request('POST', '/api/auth/login', body={'email': email, 'password': password})
print(f'POST /api/auth/login status={status} seconds={elapsed:.3f} bytes={len(payload)}')
login_body = json.loads(payload.decode() or '{}') if payload else {}
redacted = dict(login_body)
if 'access_token' in redacted:
    redacted['access_token'] = '<redacted>'
print(json.dumps(redacted, indent=2, sort_keys=True))

token = login_body.get('access_token')
if not token:
    sys.exit(0)

paths = [
    ('POST', '/api/auth/refresh'),
    ('GET', '/api/profile'),
    ('GET', '/api/swarms'),
    ('GET', '/api/devices'),
    ('GET', '/api/notifications'),
]
for method, path in paths:
    status, headers, payload, elapsed = request(method, path, token=token)
    text = payload.decode(errors='replace')
    print(f'\\n{method} {path} status={status} seconds={elapsed:.3f} bytes={len(payload)}')
    print(text[:1000])
PY"
else
  section "authenticated cross tier probe skipped"
  next_section_file skipped_file "authenticated cross tier probe skipped"
  {
    echo "Set DEBUG_AUTH_EMAIL and DEBUG_AUTH_PASSWORD to run an authenticated probe across /api/auth/refresh, /api/profile, /api/swarms, /api/devices, and /api/notifications."
    echo "Example:"
    echo "  DEBUG_AUTH_EMAIL=user@example.com DEBUG_AUTH_PASSWORD='...' ${0}"
  } >"${skipped_file}"
  cat "${skipped_file}"
fi

for fn in "${lambda_functions[@]}"; do
  run "lambda configuration ${fn}" aws_json lambda get-function-configuration --function-name "${fn}"
  run "lambda code ${fn}" aws_json lambda get-function --function-name "${fn}" --query 'Code'
  run "lambda recent logs ${fn}" aws logs tail "/aws/lambda/${fn}" --region "${AWS_REGION}" --since "${SINCE}" --format "${LOG_FORMAT}"
  run "lambda log groups ${fn}" aws_json logs describe-log-groups --log-group-name-prefix "/aws/lambda/${fn}"
done

# Extract ECR repository name from any of the resolved image URIs and inspect the container images
ecr_repo_name=""
for fn in "${lambda_functions[@]}"; do
  code_file="$(ls "${RUN_DIR}"/*-lambda-code-*.log 2>/dev/null | head -n 1)"
  if [[ -n "${code_file}" ]]; then
    code_text=$(grep -o '"ResolvedImageUri"[[:space:]]*:[[:space:]]*"[^"]*"' "${code_file}" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -n "${code_text}" && "${code_text}" != "null" ]]; then
      # Handle both tag-based (repo:tag) and digest-based (repo@sha256:digest) URIs
      ecr_repo_name=$(echo "${code_text}" | sed -E 's|^[0-9]+\.dkr\.ecr\.[^/]+/||; s/[@:].*$//')
      break
    fi
  fi
done

if [[ -n "${ecr_repo_name}" ]]; then
  section "container image inspection"
  next_section_file container_file "container image inspection"

  {
    echo "=== ECR Repository Name: ${ecr_repo_name} ==="
    aws_json ecr describe-repositories --repository-names "${ecr_repo_name}" 2>/dev/null || echo "Could not describe ECR repository"
  } >"${container_file}" 2>&1 || true

  # Inspect each Lambda function's container image
  for fn in "${lambda_functions[@]}"; do
    code_file="$(ls "${RUN_DIR}"/*-lambda-code-*.log 2>/dev/null | grep -i "${fn}" | head -n 1 || true)"
    resolved_uri=""
    image_id_arg=""
    if [[ -n "${code_file}" ]]; then
      resolved_uri=$(grep -o '"ResolvedImageUri"[[:space:]]*:[[:space:]]*"[^"]*"' "${code_file}" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    if [[ -n "${resolved_uri}" && "${resolved_uri}" != "null" ]]; then
      # Handle both tag-based (repo:tag) and digest-based (repo@sha256:digest) URIs
      if echo "${resolved_uri}" | grep -q '@'; then
        image_digest="${resolved_uri#*@}"
        image_id_arg="--image-ids imageDigest=${image_digest}"
        image_summary="${resolved_uri#*@}"
      else
        image_tag="${resolved_uri##*:}"
        image_id_arg="--image-ids imageTag=${image_tag}"
        image_summary="tag=${image_tag}"
      fi
      {
        echo "=== Container image for ${fn} ==="
        echo "Image URI: ${resolved_uri}"
        echo ""
        echo "--- Image Manifest ---"
        eval aws_json ecr batch-get-image --repository-name "${ecr_repo_name}" "${image_id_arg}" --accepted-media-types "application/vnd.docker.distribution.manifest.v2+json" 2>/dev/null || echo "Could not get image manifest"
        echo ""
        echo "--- Image Scan Findings ---"
        eval aws_json ecr describe-image-scan-findings --repository-name "${ecr_repo_name}" "${image_id_arg}" 2>/dev/null || echo "No scan findings available"
        echo ""
        echo "--- Image Layers ---"
        eval aws ecr --region '"${AWS_REGION}"' batch-get-image --repository-name '"${ecr_repo_name}"' "${image_id_arg}" --query 'images[0].imageManifest' --output text 2>/dev/null | python3 -c "
import json, sys
manifest = json.loads(sys.stdin.read())
for i, layer in enumerate(manifest.get('layers', [])):
    print(f'  Layer {i}: digest={layer[\"digest\"]} size={layer[\"size\"]} mediaType={layer.get(\"mediaType\", \"unknown\")}')
" 2>/dev/null || echo "Could not parse image layers"
      } >>"${container_file}"
    fi
  done
  cat "${container_file}"
fi

run_shell "lambda image and env summary" "python3 - '${RUN_DIR}' <<'PY'
import glob, json, os, sys
run_dir = sys.argv[1]
for config_path in sorted(glob.glob(os.path.join(run_dir, '*-lambda-configuration-*.log'))):
    text = open(config_path, encoding='utf-8').read()
    start = text.find('{')
    if start < 0:
        continue
    data = json.loads(text[start:])
    name = data.get('FunctionName')
    env = data.get('Environment', {}).get('Variables', {})
    code_path = config_path.replace('lambda-configuration-', 'lambda-code-')
    image = ''
    if os.path.exists(code_path):
        code_text = open(code_path, encoding='utf-8').read()
        code_start = code_text.find('{')
        if code_start >= 0:
            image = json.loads(code_text[code_start:]).get('ResolvedImageUri', '')
    print(f\"{name}: state={data.get('State')} update={data.get('LastUpdateStatus')} timeout={data.get('Timeout')} memory={data.get('MemorySize')} image={image}\")
    print(f\"  subnets={','.join(data.get('VpcConfig', {}).get('SubnetIds', []))}\")
    print(f\"  env_present JWT_SIGNING_SECRET={'JWT_SIGNING_SECRET' in env} runtime_secret={env.get('OVERMIND_RUNTIME_SECRET_NAME')} db_override={env.get('OVERMIND_POSTGRES_HOST_OVERRIDE')}\")
PY"

run "api gateway access logs" aws logs tail "/aws/apigateway/${PROJECT_NAME}-${ENVIRONMENT}-overmind" --region "${AWS_REGION}" --since "${SINCE}" --format "${LOG_FORMAT}"

section "cloudwatch alarms"
next_section_file alarms_file "cloudwatch alarms"
aws_json cloudwatch describe-alarms \
  --alarm-name-prefix "${PROJECT_NAME}-${ENVIRONMENT}" \
  --query 'MetricAlarms[].{AlarmName:AlarmName,StateValue:StateValue,StateReason:StateReason,MetricName:MetricName,Dimensions:Dimensions}' >"${alarms_file}" 2>&1 || true
cat "${alarms_file}"

section "done"
date -u
echo "Saved debug folder: ${RUN_DIR}"
echo "Saved combined log: ${output_file}"
