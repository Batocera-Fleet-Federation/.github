#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TAG_KEY="${INSTANCE_TAG_KEY:-Project}"
INSTANCE_TAG_VALUE="${INSTANCE_TAG_VALUE:-bff-overmind}"
SERVICE_NAME="${SERVICE_NAME:-overmind.service}"
CONTAINER_NAME="${CONTAINER_NAME:-overmind}"
APP_PORT="${APP_PORT:-8000}"
PUBLIC_URL="${PUBLIC_URL:-https://www.batocera-swarm.com}"
LOG_TAIL="${LOG_TAIL:-300}"
OUTPUT_DIR="${OUTPUT_DIR:-./ec2-debug}"
SSM_OUTPUT_S3_BUCKET="${SSM_OUTPUT_S3_BUCKET:-}"
SSM_OUTPUT_S3_PREFIX="${SSM_OUTPUT_S3_PREFIX:-overmind-debug}"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_dir="${OUTPUT_DIR%/}"
mkdir -p "${output_dir}"

echo "AWS Region:        ${AWS_REGION}"
echo "Instance tag:       ${INSTANCE_TAG_KEY}=${INSTANCE_TAG_VALUE}"
echo "Service:           ${SERVICE_NAME}"
echo "Container:         ${CONTAINER_NAME}"
echo "App port:          ${APP_PORT}"
echo "Public URL:        ${PUBLIC_URL}"
echo "Tail lines:        ${LOG_TAIL}"
echo "Output directory:  ${output_dir}"
if [[ -n "${SSM_OUTPUT_S3_BUCKET}" ]]; then
  echo "SSM S3 output:     s3://${SSM_OUTPUT_S3_BUCKET}/${SSM_OUTPUT_S3_PREFIX}"
else
  echo "SSM S3 output:     disabled (large output may be truncated by SSM)"
fi
echo

INSTANCE_ID="$(
  aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters \
      "Name=tag:${INSTANCE_TAG_KEY},Values=${INSTANCE_TAG_VALUE}" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text
)"

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "ERROR: No running EC2 instance found with tag: ${INSTANCE_TAG_KEY}=${INSTANCE_TAG_VALUE}" >&2
  aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].{InstanceId:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,Project:Tags[?Key==`Project`]|[0].Value,PublicIp:PublicIpAddress}' \
    --output table
  exit 1
fi

INSTANCE_COUNT="$(wc -w <<< "${INSTANCE_ID}" | tr -d ' ')"
if [[ "${INSTANCE_COUNT}" != "1" ]]; then
  echo "ERROR: Multiple running instances matched tag: ${INSTANCE_TAG_KEY}=${INSTANCE_TAG_VALUE}" >&2
  echo "${INSTANCE_ID}" >&2
  exit 1
fi

remote_script_file="$(mktemp)"
parameters_file="$(mktemp)"
trap 'rm -f "${remote_script_file}" "${parameters_file}"' EXIT

cat > "${remote_script_file}" <<REMOTE_SCRIPT
#!/usr/bin/env bash
set +e

CONTAINER_NAME="${CONTAINER_NAME}"
SERVICE_NAME="${SERVICE_NAME}"
APP_PORT="${APP_PORT}"
PUBLIC_URL="${PUBLIC_URL}"
LOG_TAIL="${LOG_TAIL}"

section() {
  printf '\\n\\n===== %s =====\\n' "\$1"
}

run() {
  section "\$1"
  shift
  "\$@" 2>&1 || true
}

run_shell() {
  section "\$1"
  shift
  bash -lc "\$*" 2>&1 || true
}

redact() {
  sed -E 's/((TOKEN|SECRET|PASSWORD|PASS|KEY|AUTH|COOKIE|SESSION|CREDENTIAL|PRIVATE)[A-Z0-9_ -]*[=:])[^\\" ]+/\\1<redacted>/Ig'
}

section "debug metadata"
date -u
hostname
uname -a
printf 'container=%s service=%s app_port=%s public_url=%s log_tail=%s\\n' "\${CONTAINER_NAME}" "\${SERVICE_NAME}" "\${APP_PORT}" "\${PUBLIC_URL}" "\${LOG_TAIL}"

run "uptime" uptime
run "free -m" free -m

run "systemctl status \${SERVICE_NAME}" sudo systemctl status "\${SERVICE_NAME}" --no-pager -l
run "docker version" sudo docker version
run "docker ps -a" sudo docker ps -a
run "docker stats no-stream" sudo docker stats --no-stream
run "docker inspect state \${CONTAINER_NAME}" sudo docker inspect "\${CONTAINER_NAME}" --format '{{json .State}}'
run "docker inspect resources \${CONTAINER_NAME}" sudo docker inspect "\${CONTAINER_NAME}" --format 'Name={{.Name}} RestartCount={{.RestartCount}} Driver={{.Driver}} Platform={{.Platform}} HostConfig={{json .HostConfig}}'

section "docker inspect env redacted \${CONTAINER_NAME}"
sudo docker inspect "\${CONTAINER_NAME}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>&1 | redact || true

run "docker top \${CONTAINER_NAME}" sudo docker top "\${CONTAINER_NAME}" aux
run "docker logs \${CONTAINER_NAME}" sudo docker logs --tail="\${LOG_TAIL}" "\${CONTAINER_NAME}"

run "host ps aux sorted by cpu" ps aux --sort=-%cpu
run "host ps aux sorted by memory" ps aux --sort=-%mem
run "host top snapshot" top -b -n 1
run "listening sockets" ss -ltnp
run "tcp connections for app port" ss -tanp "sport = :\${APP_PORT} or dport = :\${APP_PORT}"
run "all tcp state summary" ss -s

run_shell "local app root curl" "curl -vk --max-time 10 http://127.0.0.1:\${APP_PORT}/"
run_shell "local app health-style curl candidates" "for path in /healthz /health /api/health /docs /api/devices; do echo === \$path ===; curl -sk --max-time 5 -o /tmp/overmind-curl-body -w 'http_code=%{http_code} time_total=%{time_total} size=%{size_download}\\n' http://127.0.0.1:\${APP_PORT}\$path; head -c 1000 /tmp/overmind-curl-body; echo; done"
run_shell "public url curl" "curl -vk --max-time 15 -o /tmp/overmind-public-body -w 'http_code=%{http_code} time_total=%{time_total} size=%{size_download}\\n' \${PUBLIC_URL}/; head -c 1000 /tmp/overmind-public-body; echo"

section "container process snapshot"
sudo docker exec "\${CONTAINER_NAME}" sh -lc 'date -u; ps aux; echo; top -b -n 1; echo; free -m || true; echo; df -h || true' 2>&1 || true

section "container network snapshot"
sudo docker exec "\${CONTAINER_NAME}" sh -lc 'ss -ltnp || netstat -ltnp || true; echo; ss -tanp || netstat -tanp || true' 2>&1 || true

section "python stack dump via py-spy if available"
PY_PID="\$(sudo docker top "\${CONTAINER_NAME}" -eo pid,comm,args 2>/dev/null | awk '/python/ {print \$1; exit}')"
if [[ -n "\${PY_PID}" ]]; then
  echo "host python pid=\${PY_PID}"
  if command -v py-spy >/dev/null 2>&1; then
    sudo py-spy dump --pid "\${PY_PID}" 2>&1 || true
  else
    echo "py-spy is not installed on the host; install with: sudo pip3 install py-spy"
  fi
else
  echo "No python process found via docker top."
fi

section "docker events recent"
timeout 5 sudo docker events --since 30m 2>&1 || true

run_shell "journalctl \${SERVICE_NAME} recent filtered" "sudo journalctl -u '\${SERVICE_NAME}' --no-pager -n '\${LOG_TAIL}' | grep -Ev 'Pulling fs layer|Waiting|Verifying Checksum|Download complete|Pull complete|Already exists' | tail -n 160"
run "df -h" df -h
run "inode usage" df -ih
run_shell "kernel oom / memory pressure hints" "dmesg -T | grep -Ei 'oom|out of memory|killed process|memory pressure|hung task|blocked for more than|docker|overmind' | tail -n 120"
run_shell "kernel recent tail" "dmesg -T | tail -n 80"

section "end"
date -u
REMOTE_SCRIPT

python3 - <<PY > "${parameters_file}"
import json
from pathlib import Path

script = Path("${remote_script_file}").read_text(encoding="utf-8")
print(json.dumps({"commands": [script]}))
PY

echo "Resolved instance: ${INSTANCE_ID}"
echo "Sending debug extraction command..."

send_command_args=(
  ssm send-command
  --region "${AWS_REGION}"
  --instance-ids "${INSTANCE_ID}"
  --document-name "AWS-RunShellScript"
  --comment "Extract ${CONTAINER_NAME} debug bundle"
  --parameters "file://${parameters_file}"
  --query 'Command.CommandId'
  --output text
)

if [[ -n "${SSM_OUTPUT_S3_BUCKET}" ]]; then
  send_command_args+=(
    --output-s3-bucket-name "${SSM_OUTPUT_S3_BUCKET}"
    --output-s3-key-prefix "${SSM_OUTPUT_S3_PREFIX}"
  )
fi

COMMAND_ID="$(aws "${send_command_args[@]}")"

echo "Command ID: ${COMMAND_ID}"
echo "Waiting for command to finish..."

if ! aws ssm wait command-executed \
  --region "${AWS_REGION}" \
  --command-id "${COMMAND_ID}" \
  --instance-id "${INSTANCE_ID}"; then
  echo "WARNING: SSM command did not finish successfully. Fetching captured output anyway..." >&2
fi

debug_file="${output_dir}/${INSTANCE_TAG_VALUE}-${INSTANCE_ID}-${CONTAINER_NAME}-debug-${timestamp}.log"
json_file="${output_dir}/${INSTANCE_TAG_VALUE}-${INSTANCE_ID}-${CONTAINER_NAME}-debug-${timestamp}.json"

aws ssm get-command-invocation \
  --region "${AWS_REGION}" \
  --command-id "${COMMAND_ID}" \
  --instance-id "${INSTANCE_ID}" \
  --query '{Status:Status,StatusDetails:StatusDetails,ResponseCode:ResponseCode,ExecutionStartDateTime:ExecutionStartDateTime,ExecutionElapsedTime:ExecutionElapsedTime,ExecutionEndDateTime:ExecutionEndDateTime,StandardOutputUrl:StandardOutputUrl,StandardErrorUrl:StandardErrorUrl,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
  --output json > "${json_file}"

if [[ -n "${SSM_OUTPUT_S3_BUCKET}" ]]; then
  s3_base="s3://${SSM_OUTPUT_S3_BUCKET}/${SSM_OUTPUT_S3_PREFIX}/${COMMAND_ID}/${INSTANCE_ID}/awsrunShellScript/0.awsrunShellScript"
  s3_stdout_file="${output_dir}/${INSTANCE_TAG_VALUE}-${INSTANCE_ID}-${CONTAINER_NAME}-debug-${timestamp}.s3.stdout"
  s3_stderr_file="${output_dir}/${INSTANCE_TAG_VALUE}-${INSTANCE_ID}-${CONTAINER_NAME}-debug-${timestamp}.s3.stderr"
  aws s3 cp "${s3_base}/stdout" "${s3_stdout_file}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
  aws s3 cp "${s3_base}/stderr" "${s3_stderr_file}" --region "${AWS_REGION}" >/dev/null 2>&1 || true
fi

python3 - <<PY
import json
from pathlib import Path

payload = json.loads(Path("${json_file}").read_text(encoding="utf-8"))
stdout_path = Path("${output_dir}/${INSTANCE_TAG_VALUE}-${INSTANCE_ID}-${CONTAINER_NAME}-debug-${timestamp}.s3.stdout")
stderr_path = Path("${output_dir}/${INSTANCE_TAG_VALUE}-${INSTANCE_ID}-${CONTAINER_NAME}-debug-${timestamp}.s3.stderr")
content = []
content.append(f"SSM Status: {payload.get('Status') or 'Unknown'}\\n")
content.append(f"SSM StatusDetails: {payload.get('StatusDetails') or ''}\\n")
content.append(f"SSM ResponseCode: {payload.get('ResponseCode')}\\n")
content.append(f"SSM ExecutionStartDateTime: {payload.get('ExecutionStartDateTime') or ''}\\n")
content.append(f"SSM ExecutionElapsedTime: {payload.get('ExecutionElapsedTime') or ''}\\n")
content.append(f"SSM ExecutionEndDateTime: {payload.get('ExecutionEndDateTime') or ''}\\n")
content.append(f"SSM StandardOutputUrl: {payload.get('StandardOutputUrl') or ''}\\n")
content.append(f"SSM StandardErrorUrl: {payload.get('StandardErrorUrl') or ''}\\n")
content.append("\\n===== SSM STDOUT =====\\n")
content.append(stdout_path.read_text(encoding="utf-8") if stdout_path.exists() else (payload.get("Stdout") or ""))
content.append("\\n\\n===== SSM STDERR =====\\n")
content.append(stderr_path.read_text(encoding="utf-8") if stderr_path.exists() else (payload.get("Stderr") or ""))
Path("${debug_file}").write_text("".join(content), encoding="utf-8")
print(payload.get("Status") or "Unknown")
PY

echo
echo "Saved command JSON: ${json_file}"
echo "Saved debug file:   ${debug_file}"
echo
echo "Send me the debug file above."
