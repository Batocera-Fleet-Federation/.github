#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_MTLS_CERTS_DIR="${LOCAL_MTLS_CERTS_DIR:-$ROOT_DIR/.github/local-certs}"
CERT_DAYS="${LOCAL_MTLS_CERT_DAYS:-825}"
CA_DAYS="${LOCAL_MTLS_CA_DAYS:-3650}"
PROFILE="all"

usage() {
  cat <<EOF
Usage:
  .github/scripts/provision-local-mtls-certs.sh [--profile swarm|local|all]

Options:
  --profile=VALUE   Cert profile to provision. Default: all
  --profile VALUE   Same as --profile=VALUE
  --help, -h        Show this help

Environment:
  LOCAL_MTLS_CERTS_DIR  Output directory. Default: .github/local-certs
  LOCAL_DRONE_ID        Local direct-run Drone id. Default: local-drone
  HOSTNAME_OVERRIDE     Additional local direct-run SANs split on comma, semicolon, or whitespace.
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --profile=*)
      PROFILE="${1#*=}"
      shift
      ;;
    --profile)
      if [[ "$#" -lt 2 || "${2:-}" == --* ]]; then
        echo "ERROR: --profile requires a value. Use --profile=swarm, --profile=local, or --profile=all." >&2
        exit 1
      fi
      PROFILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$PROFILE" in
  swarm|local|all) ;;
  *)
    echo "ERROR: --profile must be one of: swarm, local, all." >&2
    exit 1
    ;;
esac

require_command openssl
require_command python3

CA_DIR="$LOCAL_MTLS_CERTS_DIR/ca"
CA_CERT="$CA_DIR/ca.crt"
CA_KEY="$CA_DIR/ca.key"
DRONES_DIR="$LOCAL_MTLS_CERTS_DIR/drones"

mkdir -p "$CA_DIR" "$DRONES_DIR"

ensure_ca() {
  if [[ -s "$CA_CERT" && -s "$CA_KEY" ]]; then
    echo "Using existing local mTLS CA: $CA_CERT"
    return 0
  fi

  echo "Creating local mTLS CA: $CA_CERT"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$CA_KEY" \
    -out "$CA_CERT" \
    -days "$CA_DAYS" \
    -subj "/CN=Batocera Fleet Federation Local Drone mTLS CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    >/dev/null 2>&1
  chmod 600 "$CA_KEY"
}

is_ip_literal() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress
import sys
ipaddress.ip_address(sys.argv[1].strip("[]"))
PY
}

append_unique() {
  local value="$1"
  local file="$2"
  if [[ -n "$value" ]] && ! grep -Fxq "$value" "$file" 2>/dev/null; then
    printf '%s\n' "$value" >> "$file"
  fi
}

add_san_token() {
  local token="$1"
  local dns_file="$2"
  local ip_file="$3"

  token="${token#[}"
  token="${token%]}"
  [[ -z "$token" ]] && return 0

  if is_ip_literal "$token"; then
    append_unique "$token" "$ip_file"
  else
    append_unique "$token" "$dns_file"
  fi
}

add_tokens() {
  local value="$1"
  local dns_file="$2"
  local ip_file="$3"
  local token

  value="${value//,/ }"
  value="${value//;/ }"
  for token in $value; do
    add_san_token "$token" "$dns_file" "$ip_file"
  done
}

cert_has_sans() {
  local cert_file="$1"
  local dns_file="$2"
  local ip_file="$3"
  local cert_text
  local san

  cert_text="$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null || true)"
  [[ -n "$cert_text" ]] || return 1

  while IFS= read -r san; do
    [[ -z "$san" ]] && continue
    if ! grep -Fq "DNS:$san" <<<"$cert_text"; then
      return 1
    fi
  done < "$dns_file"

  while IFS= read -r san; do
    [[ -z "$san" ]] && continue
    if ! grep -Fq "IP Address:$san" <<<"$cert_text"; then
      return 1
    fi
  done < "$ip_file"

  return 0
}

cert_is_reusable() {
  local cert_file="$1"
  local key_file="$2"
  local dns_file="$3"
  local ip_file="$4"
  local cert_modulus
  local key_modulus

  [[ -s "$cert_file" && -s "$key_file" ]] || return 1
  openssl verify -CAfile "$CA_CERT" "$cert_file" >/dev/null 2>&1 || return 1
  openssl x509 -in "$cert_file" -noout -checkend 0 >/dev/null 2>&1 || return 1
  cert_has_sans "$cert_file" "$dns_file" "$ip_file" || return 1

  cert_modulus="$(openssl x509 -noout -modulus -in "$cert_file" | openssl md5)"
  key_modulus="$(openssl rsa -noout -modulus -in "$key_file" 2>/dev/null | openssl md5)"
  [[ "$cert_modulus" == "$key_modulus" ]]
}

provision_drone() {
  local cert_id="$1"
  local common_name="$2"
  local san_values="$3"
  local cert_dir="$DRONES_DIR/$cert_id"
  local cert_file="$cert_dir/drone.crt"
  local key_file="$cert_dir/drone.key"
  local csr_file="$cert_dir/drone.csr"
  local config_file="$cert_dir/openssl.cnf"
  local dns_file
  local ip_file
  local idx
  local value
  local serial

  mkdir -p "$cert_dir"
  rm -f "$cert_dir/ca.key" "$cert_dir/drone.csr" "$cert_dir/openssl.cnf"
  cp "$CA_CERT" "$cert_dir/ca.crt"

  dns_file="$(mktemp)"
  ip_file="$(mktemp)"

  append_unique "$common_name" "$dns_file"
  append_unique "localhost" "$dns_file"
  add_tokens "$san_values" "$dns_file" "$ip_file"
  append_unique "127.0.0.1" "$ip_file"

  if cert_is_reusable "$cert_file" "$key_file" "$dns_file" "$ip_file"; then
    echo "Using existing local Drone cert: $cert_file"
    rm -f "$dns_file" "$ip_file"
    return 0
  fi

  echo "Creating local Drone cert: $cert_file"
  {
    printf '[req]\n'
    printf 'distinguished_name = dn\n'
    printf 'req_extensions = ext\n'
    printf 'prompt = no\n'
    printf '[dn]\n'
    printf 'CN = %s\n' "$common_name"
    printf '[ext]\n'
    printf 'basicConstraints = CA:FALSE\n'
    printf 'keyUsage = critical, digitalSignature, keyEncipherment\n'
    printf 'extendedKeyUsage = serverAuth, clientAuth\n'
    printf 'subjectAltName = @alt_names\n'
    printf '[alt_names]\n'
    idx=1
    while IFS= read -r value; do
      [[ -z "$value" ]] && continue
      printf 'DNS.%s = %s\n' "$idx" "$value"
      idx=$((idx + 1))
    done < "$dns_file"
    idx=1
    while IFS= read -r value; do
      [[ -z "$value" ]] && continue
      printf 'IP.%s = %s\n' "$idx" "$value"
      idx=$((idx + 1))
    done < "$ip_file"
  } > "$config_file"

  openssl req -new -nodes -newkey rsa:2048 \
    -keyout "$key_file" \
    -out "$csr_file" \
    -subj "/CN=$common_name" \
    -config "$config_file" \
    >/dev/null 2>&1

  serial="$(python3 - "$cert_id" <<'PY'
import hashlib
import sys
print(int(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest()[:30], 16))
PY
)"

  openssl x509 -req \
    -in "$csr_file" \
    -CA "$CA_CERT" \
    -CAkey "$CA_KEY" \
    -out "$cert_file" \
    -days "$CERT_DAYS" \
    -sha256 \
    -extfile "$config_file" \
    -extensions ext \
    -set_serial "$serial" \
    >/dev/null 2>&1

  chmod 600 "$key_file"
  rm -f "$csr_file" "$config_file" "$dns_file" "$ip_file"
}

ensure_ca

if [[ "$PROFILE" == "swarm" || "$PROFILE" == "all" ]]; then
  swarm_hosts="bff-drone-a bff-drone-b bff-drone-c bff-drone-d bff-overmind"
  provision_drone "drone-a" "batocera-drone-bff-drone-a" "drone-a $swarm_hosts"
  provision_drone "drone-b" "batocera-drone-bff-drone-b" "drone-b $swarm_hosts"
  provision_drone "drone-c" "batocera-drone-bff-drone-c" "drone-c $swarm_hosts"
  provision_drone "drone-d" "batocera-drone-bff-drone-d" "drone-d $swarm_hosts"
fi

if [[ "$PROFILE" == "local" || "$PROFILE" == "all" ]]; then
  local_id="${LOCAL_DRONE_ID:-local-drone}"
  local_hosts="${HOSTNAME_OVERRIDE:-localhost,local-drone,batocera.local}"
  provision_drone "$local_id" "batocera-drone-$local_id" "$local_id $local_hosts"
fi

echo "Local mTLS certs ready under: $LOCAL_MTLS_CERTS_DIR"
