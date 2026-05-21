#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TAG_KEY="${INSTANCE_TAG_KEY:-Project}"
INSTANCE_TAG_VALUE="${INSTANCE_TAG_VALUE:-bff-overmind}"
SERVICE_NAME="${SERVICE_NAME:-overmind.service}"

echo "AWS Region:        ${AWS_REGION}"
echo "Instance tag:       ${INSTANCE_TAG_KEY}=${INSTANCE_TAG_VALUE}"
echo "Service:           ${SERVICE_NAME}"
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
echo "Sending restart command..."

COMMAND_ID="$(
  aws ssm send-command \
    --region "${AWS_REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --comment "Restart ${SERVICE_NAME}" \
    --parameters "commands=[
      \"sudo systemctl restart ${SERVICE_NAME}\",
      \"sudo systemctl status ${SERVICE_NAME} --no-pager -l\",
      \"sudo docker ps -a\",
      \"sudo docker logs --tail=100 overmind\"
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

echo
echo "Command output:"
aws ssm get-command-invocation \
  --region "${AWS_REGION}" \
  --command-id "${COMMAND_ID}" \
  --instance-id "${INSTANCE_ID}" \
  --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
  --output text