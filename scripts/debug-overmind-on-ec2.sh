#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-overmind.service}"
CONTAINER_NAME="${CONTAINER_NAME:-overmind}"
APP_PORT="${APP_PORT:-8000}"
PUBLIC_URL="${PUBLIC_URL:-https://www.batocera-swarm.com}"
LOG_TAIL="${LOG_TAIL:-3000}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/overmind-debug}"
RESTART="${RESTART:-false}"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${OUTPUT_DIR}"
output_file="${OUTPUT_DIR}/overmind-local-debug-${timestamp}.log"

exec > >(tee "${output_file}") 2>&1

section() {
  printf '\n\n===== %s =====\n' "$1"
}

run() {
  section "$1"
  shift
  "$@" || true
}

run_shell() {
  section "$1"
  shift
  bash -lc "$*" || true
}

redact() {
  sed -E 's/((TOKEN|SECRET|PASSWORD|PASS|KEY|AUTH|COOKIE|SESSION|CREDENTIAL|PRIVATE)[A-Z0-9_ -]*[=:])[^\\" ]+/\1<redacted>/Ig'
}

section "debug metadata"
date -u
hostname || true
uname -a || true
printf 'service=%s container=%s app_port=%s public_url=%s restart=%s\n' "${SERVICE_NAME}" "${CONTAINER_NAME}" "${APP_PORT}" "${PUBLIC_URL}" "${RESTART}"
printf 'output_file=%s\n' "${output_file}"

run "uptime" uptime
run "memory" free -m
run "disk" df -h
run "inodes" df -ih
run "load/process summary" top -b -n 1
run "processes by cpu" ps aux --sort=-%cpu
run "processes by memory" ps aux --sort=-%mem

run "systemctl status ${SERVICE_NAME}" sudo systemctl status "${SERVICE_NAME}" --no-pager -l
run "journalctl ${SERVICE_NAME}" sudo journalctl -u "${SERVICE_NAME}" --no-pager -n "${LOG_TAIL}"
run "kernel oom/memory messages" sudo dmesg -T

run "docker ps -a" sudo docker ps -a
run "docker stats no-stream" sudo docker stats --no-stream
run "docker inspect state ${CONTAINER_NAME}" sudo docker inspect "${CONTAINER_NAME}" --format '{{json .State}}'
run "docker inspect resources ${CONTAINER_NAME}" sudo docker inspect "${CONTAINER_NAME}" --format 'Name={{.Name}} RestartCount={{.RestartCount}} HostConfig={{json .HostConfig}}'

section "docker env redacted ${CONTAINER_NAME}"
sudo docker inspect "${CONTAINER_NAME}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>&1 | redact || true

run "docker top ${CONTAINER_NAME}" sudo docker top "${CONTAINER_NAME}" aux
run "docker logs ${CONTAINER_NAME}" sudo docker logs --tail="${LOG_TAIL}" "${CONTAINER_NAME}"

run "listening sockets" ss -ltnp
run "app port connections" ss -tanp "sport = :${APP_PORT} or dport = :${APP_PORT}"
run "tcp summary" ss -s

run_shell "local app curl root" "curl -vk --max-time 8 -o /tmp/overmind-root-body -w 'http_code=%{http_code} time_total=%{time_total} size=%{size_download}\n' http://127.0.0.1:${APP_PORT}/; head -c 1000 /tmp/overmind-root-body; echo"
run_shell "local app curl common endpoints" "for path in /healthz /health /api/health /docs; do echo === \$path ===; curl -sk --max-time 5 -o /tmp/overmind-curl-body -w 'http_code=%{http_code} time_total=%{time_total} size=%{size_download}\n' http://127.0.0.1:${APP_PORT}\$path; head -c 500 /tmp/overmind-curl-body; echo; done"
run_shell "public curl" "curl -vk --max-time 12 -o /tmp/overmind-public-body -w 'http_code=%{http_code} time_total=%{time_total} size=%{size_download}\n' ${PUBLIC_URL}/; head -c 1000 /tmp/overmind-public-body; echo"

section "container process snapshot"
sudo docker exec "${CONTAINER_NAME}" sh -lc 'date -u; ps aux; echo; top -b -n 1 || true; echo; free -m || true; echo; df -h || true' || true

section "container network snapshot"
sudo docker exec "${CONTAINER_NAME}" sh -lc 'ss -ltnp || netstat -ltnp || true; echo; ss -tanp || netstat -tanp || true' || true

section "python stack dump"
PY_PID="$(sudo docker top "${CONTAINER_NAME}" -eo pid,comm,args 2>/dev/null | awk '/python/ {print $1; exit}')"
if [[ -n "${PY_PID}" ]]; then
  echo "host python pid=${PY_PID}"
  if command -v py-spy >/dev/null 2>&1; then
    sudo py-spy dump --pid "${PY_PID}" || true
  else
    echo "py-spy not installed. Attempting gdb-free signal dump is unavailable unless app has faulthandler."
    echo "Install for next time: sudo pip3 install py-spy"
  fi
else
  echo "No python process found via docker top."
fi

section "docker events recent"
timeout 5 sudo docker events --since 30m || true

if [[ "${RESTART}" == "true" || "${RESTART}" == "1" || "${RESTART}" == "yes" ]]; then
  section "restart ${SERVICE_NAME}"
  sudo systemctl restart "${SERVICE_NAME}" || sudo docker restart "${CONTAINER_NAME}" || true
  sleep 5
  run "post-restart systemctl status ${SERVICE_NAME}" sudo systemctl status "${SERVICE_NAME}" --no-pager -l
  run "post-restart docker ps" sudo docker ps -a
  run_shell "post-restart local curl root" "curl -vk --max-time 8 -o /tmp/overmind-root-post-body -w 'http_code=%{http_code} time_total=%{time_total} size=%{size_download}\n' http://127.0.0.1:${APP_PORT}/; head -c 500 /tmp/overmind-root-post-body; echo"
else
  section "restart skipped"
  echo "To capture diagnostics and then restart, rerun with: RESTART=true $0"
fi

section "done"
date -u
echo "Saved debug output: ${output_file}"
