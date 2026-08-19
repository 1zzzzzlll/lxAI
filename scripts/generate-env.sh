#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MODEL_BASE_URL=${MODEL_BASE_URL:-http://127.0.0.1:6215/v1/chat/completions}
MODEL_BASE_URL=${MODEL_BASE_URL%/}
MODEL_BASE_URL=${MODEL_BASE_URL%/chat/completions}
MODEL_BASE_URL=${MODEL_BASE_URL%/}
MODEL_NAME=${MODEL_NAME:-TT3.6-27B-0623}
MODEL_API_KEY=${MODEL_API_KEY:-}
MODEL_AUTO_DETECT=${MODEL_AUTO_DETECT:-false}
WEB_BIND_ADDRESS=${WEB_BIND_ADDRESS:-0.0.0.0}
WEB_PORT=${WEB_PORT:-8088}
WEB_PORT_CONFLICT_POLICY=${WEB_PORT_CONFLICT_POLICY:-next}
DATA_ROOT=${DATA_ROOT:-/TRS/lxAI}
IMAGE_ARCH=$(target_arch)

validate_bool MODEL_AUTO_DETECT "$MODEL_AUTO_DETECT"
validate_web_bind_address
validate_uint WEB_PORT "$WEB_PORT" 1 65535
validate_data_root
case "$WEB_PORT_CONFLICT_POLICY" in next|fail) ;; *) die "WEB_PORT_CONFLICT_POLICY must be next or fail; got: $WEB_PORT_CONFLICT_POLICY" ;; esac

if [[ "$MODEL_AUTO_DETECT" == true ]]; then
  detected=$(mktemp)
  trap 'rm -f "$detected"' EXIT
  export MODEL_BASE_URL MODEL_NAME MODEL_API_KEY
  "$PROJECT_DIR/scripts/detect-model.sh" "$detected" "$PROJECT_DIR/docs/hardware-report.md"
  # shellcheck disable=SC1090
  source "$detected"
else
  MODEL_BASE_URL=${MODEL_BASE_URL/127.0.0.1/host.docker.internal}
  MODEL_BASE_URL=${MODEL_BASE_URL/localhost/host.docker.internal}
fi

port=$WEB_PORT
while port_is_listening "$port" && ! port_owned_by_current_stack "$port"; do
  if [[ "$WEB_PORT_CONFLICT_POLICY" == fail ]]; then
    die "Web port $port is already in use; choose another WEB_PORT or set WEB_PORT_CONFLICT_POLICY=next"
  fi
  warn "Web port $port is already in use; trying $((port + 1))"
  (( port < 65535 )) || die 'no available Web port remains in the configured range'
  port=$((port + 1))
done

validate_bool SAFE_MODE "${SAFE_MODE:-true}"
validate_bool ALLOW_DANGEROUS_TOOLS "${ALLOW_DANGEROUS_TOOLS:-false}"
validate_bool DB_WRITE_ENABLED "${DB_WRITE_ENABLED:-false}"
validate_bool HTTP_ALLOW_PRIVATE_ONLY "${HTTP_ALLOW_PRIVATE_ONLY:-true}"
validate_uint AGENT_MAX_STEPS "${AGENT_MAX_STEPS:-10}" 1 100
validate_uint TOOL_TIMEOUT "${TOOL_TIMEOUT:-120}" 1 3600
validate_uint TOOL_PIDS_LIMIT "${TOOL_PIDS_LIMIT:-256}" 16 32768
validate_uint OFFICE_PIDS_LIMIT "${OFFICE_PIDS_LIMIT:-256}" 16 32768
validate_uint AGENT_PIDS_LIMIT "${AGENT_PIDS_LIMIT:-256}" 16 32768
validate_positive_number AGENT_CPUS "${AGENT_CPUS:-2.0}"
validate_positive_number TOOL_CPUS "${TOOL_CPUS:-2.0}"
validate_positive_number OFFICE_CPUS "${OFFICE_CPUS:-2.0}"
validate_memory_limit AGENT_MEMORY "${AGENT_MEMORY:-4g}"
validate_memory_limit TOOL_MEMORY "${TOOL_MEMORY:-4g}"
validate_memory_limit OFFICE_MEMORY "${OFFICE_MEMORY:-4g}"
validate_uint MIN_FREE_DISK_GB "${MIN_FREE_DISK_GB:-20}" 1 1048576
validate_uint MIN_MEMORY_GB "${MIN_MEMORY_GB:-8}" 1 1048576

postgres_password=${POSTGRES_PASSWORD:-}
[[ -n "$postgres_password" && "$postgres_password" != CHANGE_ME ]] || postgres_password=$(openssl rand -hex 24)
webui_secret=${WEBUI_SECRET_KEY:-}
[[ -n "$webui_secret" && "$webui_secret" != CHANGE_ME ]] || webui_secret=$(openssl rand -hex 32)
shared_secret=${AGENT_SHARED_SECRET:-}
[[ -n "$shared_secret" && "$shared_secret" != CHANGE_ME ]] || shared_secret=$(openssl rand -hex 32)
admin_password=${ADMIN_PASSWORD:-}
[[ -n "$admin_password" && "$admin_password" != CHANGE_ME ]] || admin_password=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)

env_quote() {
  local value=$1
  [[ "$value" != *"'"* ]] || die "configuration values cannot contain a single quote: $value"
  printf "'%s'" "$value"
}
for value in "$MODEL_BASE_URL" "$MODEL_NAME" "$MODEL_API_KEY" "$DATA_ROOT" "${POSTGRES_DB:-offline_ai}" "${POSTGRES_USER:-offline_ai}" "$postgres_password" "$webui_secret" "${ADMIN_EMAIL:-admin@offline.local}" "$admin_password" "$shared_secret" "${EMBEDDING_MODEL_PATH:-/models/embedding}" "${TZ:-Asia/Shanghai}"; do
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die 'configuration values cannot contain newlines'
  [[ "$value" != *"'"* ]] || die "configuration values cannot contain a single quote: $value"
done

cat > "$ENV_FILE" <<EOF
PLATFORM_VERSION=1.0.0
IMAGE_ARCH=$IMAGE_ARCH
WEB_BIND_ADDRESS=$WEB_BIND_ADDRESS
WEB_PORT=$port
WEB_PORT_CONFLICT_POLICY=$WEB_PORT_CONFLICT_POLICY
DATA_ROOT=$(env_quote "$DATA_ROOT")
MODEL_BASE_URL=$(env_quote "$MODEL_BASE_URL")
MODEL_NAME=$(env_quote "$MODEL_NAME")
MODEL_API_KEY=$(env_quote "$MODEL_API_KEY")
MODEL_AUTO_DETECT=$MODEL_AUTO_DETECT
MODEL_RUNTIME_MANAGED=false
AGENT_MAX_STEPS=${AGENT_MAX_STEPS:-10}
TOOL_TIMEOUT=${TOOL_TIMEOUT:-120}
SAFE_MODE=${SAFE_MODE:-true}
ALLOW_DANGEROUS_TOOLS=${ALLOW_DANGEROUS_TOOLS:-false}
DB_WRITE_ENABLED=${DB_WRITE_ENABLED:-false}
HTTP_ALLOW_PRIVATE_ONLY=${HTTP_ALLOW_PRIVATE_ONLY:-true}
AGENT_CPUS=${AGENT_CPUS:-2.0}
AGENT_MEMORY=${AGENT_MEMORY:-4g}
AGENT_PIDS_LIMIT=${AGENT_PIDS_LIMIT:-256}
TOOL_CPUS=${TOOL_CPUS:-2.0}
TOOL_MEMORY=${TOOL_MEMORY:-4g}
TOOL_PIDS_LIMIT=${TOOL_PIDS_LIMIT:-256}
OFFICE_CPUS=${OFFICE_CPUS:-2.0}
OFFICE_MEMORY=${OFFICE_MEMORY:-4g}
OFFICE_PIDS_LIMIT=${OFFICE_PIDS_LIMIT:-256}
MIN_FREE_DISK_GB=${MIN_FREE_DISK_GB:-20}
MIN_MEMORY_GB=${MIN_MEMORY_GB:-8}
POSTGRES_DB=$(env_quote "${POSTGRES_DB:-offline_ai}")
POSTGRES_USER=$(env_quote "${POSTGRES_USER:-offline_ai}")
POSTGRES_PASSWORD=$(env_quote "$postgres_password")
WEBUI_SECRET_KEY=$(env_quote "$webui_secret")
ADMIN_EMAIL=$(env_quote "${ADMIN_EMAIL:-admin@offline.local}")
ADMIN_PASSWORD=$(env_quote "$admin_password")
AGENT_SHARED_SECRET=$(env_quote "$shared_secret")
EMBEDDING_MODEL_PATH=$(env_quote "${EMBEDDING_MODEL_PATH:-/models/embedding}")
TZ=$(env_quote "${TZ:-Asia/Shanghai}")
EOF
chmod 600 "$ENV_FILE"
pass "Generated .env; bind $WEB_BIND_ADDRESS; Web port $port; model $MODEL_NAME; data $DATA_ROOT"
