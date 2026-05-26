#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TAG_KEY="${INSTANCE_TAG_KEY:-Project}"
INSTANCE_TAG_VALUE="${INSTANCE_TAG_VALUE:-bff-overmind}"
SERVICE_NAME="${SERVICE_NAME:-overmind.service}"
CONTAINER_NAME="${CONTAINER_NAME:-overmind}"
LOG_TAIL="${LOG_TAIL:-1000}"
OUTPUT_DIR="${OUTPUT_DIR:-./ec2-logs}"
FULL_LOGS="${FULL_LOGS:-false}"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_dir="${OUTPUT_DIR%/}"
mkdir -p "${output_dir}"

echo "AWS Region:        ${AWS_REGION}"
echo "Instance tag:       ${INSTANCE_TAG_KEY}=${INSTANCE_TAG_VALUE}"
echo "Service:           ${SERVICE_NAME}"
echo "Container:         ${CONTAINER_NAME}"
echo "Tail lines:        ${LOG_TAIL}"
echo "Output directory:  ${output_dir}"
echo "Full logs:         ${FULL_LOGS}"
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
  echo
  echo "Available running instances:"
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

echo "Resolved instance: ${INSTANCE_ID}"
echo "Sending log extraction command..."

if [[ "${FULL_LOGS}" == "true" || "${FULL_LOGS}" == "1" || "${FULL_LOGS}" == "yes" ]]; then
  DOCKER_LOG_COMMAND="sudo docker logs ${CONTAINER_NAME}"
else
  DOCKER_LOG_COMMAND="sudo docker logs --tail=${LOG_TAIL} ${CONTAINER_NAME}"
fi

COMMAND_ID="$(
  aws ssm send-command \
    --region "${AWS_REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --comment "Extract ${CONTAINER_NAME} logs" \
    --parameters "commands=[
      \"set -euo pipefail\",
      \"echo '=== systemctl status ${SERVICE_NAME} ==='\",
      \"sudo systemctl status ${SERVICE_NAME} --no-pager -l || true\",
      \"echo\",
      \"echo '=== docker ps -a ==='\",
      \"sudo docker ps -a\",
      \"echo\",
      \"echo '=== docker inspect ${CONTAINER_NAME} ==='\",
      \"sudo docker inspect ${CONTAINER_NAME} --format '{{json .State}}' || true\",
      \"echo\",
      \"echo '=== docker logs ${CONTAINER_NAME} ==='\",
      \"${DOCKER_LOG_COMMAND}\"
    ]" \
    --query 'Command.CommandId' \
    --output text
)"

echo "Command ID: ${COMMAND_ID}"
echo "Waiting for command to finish..."

aws ssm wait command-executed \
  --region "${AWS_REGION}" \
  --command-id "${COMMAND_ID}" \
  --instance-id "${INSTANCE_ID}"

stdout_file="${output_dir}/${INSTANCE_TAG_VALUE}-${INSTANCE_ID}-${CONTAINER_NAME}-${timestamp}.log"
stderr_file="${output_dir}/${INSTANCE_TAG_VALUE}-${INSTANCE_ID}-${CONTAINER_NAME}-${timestamp}.stderr.log"
json_file="${output_dir}/${INSTANCE_TAG_VALUE}-${INSTANCE_ID}-${CONTAINER_NAME}-${timestamp}.json"

aws ssm get-command-invocation \
  --region "${AWS_REGION}" \
  --command-id "${COMMAND_ID}" \
  --instance-id "${INSTANCE_ID}" \
  --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
  --output json > "${json_file}"

python3 - <<PY
import json
from pathlib import Path

payload = json.loads(Path("${json_file}").read_text(encoding="utf-8"))
Path("${stdout_file}").write_text(payload.get("Stdout") or "", encoding="utf-8")
Path("${stderr_file}").write_text(payload.get("Stderr") or "", encoding="utf-8")
print(payload.get("Status") or "Unknown")
PY

echo
echo "Saved command JSON: ${json_file}"
echo "Saved stdout log:   ${stdout_file}"
echo "Saved stderr log:   ${stderr_file}"
