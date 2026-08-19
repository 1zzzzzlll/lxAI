#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_DIR/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./deploy.sh [options]

Configuration:
  --config FILE                  Load a deployment config file
  --reconfigure                 Regenerate .env while preserving existing secrets
  --web-bind IPV4               Host bind address (default: 0.0.0.0)
  --web-port PORT               Preferred Web port (default: 8088)
  --port-conflict next|fail     Try the next port or fail on conflict
  --model-url URL               OpenAI-compatible /v1 or /chat/completions URL
  --model-name NAME             Full model name
  --model-api-key KEY           Optional model API key
  --model-auto-detect BOOL      Enable read-only model API discovery
  --data-root PATH              Persistent data root
  --docker-auto-install BOOL    Install missing Docker/Compose from this bundle
  --docker-data-root PATH       Data root for a newly installed Docker Engine
  --host-tools-install-dir PATH Install bundled host tools such as jq here
  --timezone TZ                 Container timezone
  --admin-email EMAIL           Initial administrator email
  --admin-password PASSWORD     Initial administrator password
  --safe-mode BOOL              Enable Tool Runner safe mode
  --allow-dangerous-tools BOOL  Permit dangerous tools
  --db-write-enabled BOOL       Permit database writes
  --http-private-only BOOL      Restrict HTTP tool to private addresses
  --agent-max-steps NUMBER      Maximum tool-call loop steps
  --tool-timeout SECONDS        Tool execution timeout
  -h, --help                    Show this help

Existing .env values are retained unless configuration options, --config, or
--reconfigure are supplied. A local config/deployment.env is loaded automatically.
EOF
}

declare -A cli=()
config_file=''
configuration_requested=false
reconfigure=false
set_cli() {
  local key=$1
  local value=${2-}
  [[ -n "$value" ]] || die "$key requires a value"
  cli["$key"]=$value
  configuration_requested=true
}
while (($#)); do
  case "$1" in
    --config) [[ $# -ge 2 ]] || die '--config requires a file'; config_file=$2; configuration_requested=true; shift 2 ;;
    --reconfigure) reconfigure=true; configuration_requested=true; shift ;;
    --web-bind) set_cli WEB_BIND_ADDRESS "${2-}"; shift 2 ;;
    --web-port) set_cli WEB_PORT "${2-}"; shift 2 ;;
    --port-conflict) set_cli WEB_PORT_CONFLICT_POLICY "${2-}"; shift 2 ;;
    --model-url) set_cli MODEL_BASE_URL "${2-}"; shift 2 ;;
    --model-name) set_cli MODEL_NAME "${2-}"; shift 2 ;;
    --model-api-key) set_cli MODEL_API_KEY "${2-}"; shift 2 ;;
    --model-auto-detect) set_cli MODEL_AUTO_DETECT "${2-}"; shift 2 ;;
    --data-root) set_cli DATA_ROOT "${2-}"; shift 2 ;;
    --docker-auto-install) set_cli DOCKER_AUTO_INSTALL "${2-}"; shift 2 ;;
    --docker-data-root) set_cli DOCKER_DATA_ROOT "${2-}"; shift 2 ;;
    --host-tools-install-dir) set_cli HOST_TOOLS_INSTALL_DIR "${2-}"; shift 2 ;;
    --timezone) set_cli TZ "${2-}"; shift 2 ;;
    --admin-email) set_cli ADMIN_EMAIL "${2-}"; shift 2 ;;
    --admin-password) set_cli ADMIN_PASSWORD "${2-}"; shift 2 ;;
    --safe-mode) set_cli SAFE_MODE "${2-}"; shift 2 ;;
    --allow-dangerous-tools) set_cli ALLOW_DANGEROUS_TOOLS "${2-}"; shift 2 ;;
    --db-write-enabled) set_cli DB_WRITE_ENABLED "${2-}"; shift 2 ;;
    --http-private-only) set_cli HTTP_ALLOW_PRIVATE_ONLY "${2-}"; shift 2 ;;
    --agent-max-steps) set_cli AGENT_MAX_STEPS "${2-}"; shift 2 ;;
    --tool-timeout) set_cli TOOL_TIMEOUT "${2-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (run ./deploy.sh --help)" ;;
  esac
done

if [[ -z "$config_file" && -f "$PROJECT_DIR/config/deployment.env" ]]; then
  config_file="$PROJECT_DIR/config/deployment.env"
  configuration_requested=true
fi

existing_postgres_password=''
existing_webui_secret=''
existing_agent_secret=''
existing_admin_password=''
if [[ -f "$ENV_FILE" ]]; then
  load_env
  existing_postgres_password=${POSTGRES_PASSWORD:-}
  existing_webui_secret=${WEBUI_SECRET_KEY:-}
  existing_agent_secret=${AGENT_SHARED_SECRET:-}
  existing_admin_password=${ADMIN_PASSWORD:-}
fi
if [[ -n "$config_file" ]]; then
  [[ "$config_file" == /* ]] || config_file="$PROJECT_DIR/$config_file"
  [[ -f "$config_file" ]] || die "configuration file not found: $config_file"
  info "Loading configuration: $config_file"
  set -a
  # shellcheck disable=SC1090
  source "$config_file"
  set +a
fi
for key in "${!cli[@]}"; do printf -v "$key" '%s' "${cli[$key]}"; export "$key"; done
[[ -n "${POSTGRES_PASSWORD:-}" ]] || POSTGRES_PASSWORD=$existing_postgres_password
[[ -n "${WEBUI_SECRET_KEY:-}" ]] || WEBUI_SECRET_KEY=$existing_webui_secret
[[ -n "${AGENT_SHARED_SECRET:-}" ]] || AGENT_SHARED_SECRET=$existing_agent_secret
[[ -n "${ADMIN_PASSWORD:-}" ]] || ADMIN_PASSWORD=$existing_admin_password
export POSTGRES_PASSWORD WEBUI_SECRET_KEY AGENT_SHARED_SECRET ADMIN_PASSWORD
DATA_ROOT=${DATA_ROOT:-/TRS/lxAI}
IMAGE_ARCH=$(target_arch)
export DATA_ROOT IMAGE_ARCH

if (( EUID != 0 )); then
  die 'run deployment as root: sudo ./deploy.sh [options]'
fi

validate_data_root
HOST_TOOLS_INSTALL_DIR=${HOST_TOOLS_INSTALL_DIR:-/usr/local/bin}
DOCKER_DATA_ROOT=${DOCKER_DATA_ROOT:-$DATA_ROOT/docker-engine}
DOCKER_INSTALL_DIR=${DOCKER_INSTALL_DIR:-/usr/local/bin}
PATH="$HOST_TOOLS_INSTALL_DIR:$DOCKER_INSTALL_DIR:$PATH"
export HOST_TOOLS_INSTALL_DIR DOCKER_DATA_ROOT DOCKER_INSTALL_DIR PATH
validate_docker_data_root
"$PROJECT_DIR/scripts/ensure-host-tools.sh"
"$PROJECT_DIR/scripts/ensure-docker.sh"
"$PROJECT_DIR/scripts/precheck.sh"
if [[ ! -f "$ENV_FILE" || "$configuration_requested" == true || "$reconfigure" == true ]]; then
  "$PROJECT_DIR/scripts/generate-env.sh"
else
  info 'Keeping existing .env'
fi
load_env
validate_data_root

for dir in postgres open-webui qdrant files/users files/uploads files/outputs files/tmp templates/word templates/excel templates/ppt logs config secrets/ssh backups; do
  mkdir -p "$DATA_ROOT/$dir"
done
if [[ -d "$PROJECT_DIR/templates" ]]; then cp -a "$PROJECT_DIR/templates/." "$DATA_ROOT/templates/"; fi
if [[ -d "$PROJECT_DIR/secrets/ssh" ]]; then cp -an "$PROJECT_DIR/secrets/ssh/." "$DATA_ROOT/secrets/ssh/" || true; fi
[[ -f "$DATA_ROOT/secrets/kubeconfig" ]] || install -m 0600 "$PROJECT_DIR/secrets/kubeconfig.example" "$DATA_ROOT/secrets/kubeconfig"
chown -R 10002:20000 "$DATA_ROOT/files"
chmod -R u+rwX,g+rwX,o-rwx "$DATA_ROOT/files"
chmod 0700 "$DATA_ROOT/secrets" "$DATA_ROOT/secrets/ssh"

"$PROJECT_DIR/scripts/import-images.sh"
compose up -d --no-build --pull never

info 'Waiting for services (up to 10 minutes)'
deadline=$((SECONDS + 600))
until "$PROJECT_DIR/healthcheck.sh" --quick >/dev/null 2>&1; do
  (( SECONDS < deadline )) || { compose ps; compose logs --tail=100; die 'services did not become healthy'; }
  sleep 5
done
"$PROJECT_DIR/scripts/smoke-test.sh"
"$PROJECT_DIR/healthcheck.sh"

host_ip=$(hostname -I 2>/dev/null | awk '{print$1}')
if [[ "$WEB_BIND_ADDRESS" != 0.0.0.0 ]]; then host_ip=$WEB_BIND_ADDRESS; fi
host_ip=${host_ip:-SERVER_IP}
cat <<EOF
========================================
 Offline AI Platform deployment success
 Web: http://${host_ip}:${WEB_PORT}
 Model: ${MODEL_NAME}
 Model API: ${MODEL_BASE_URL}
 Architecture: ${IMAGE_ARCH}
 Data: ${DATA_ROOT}
========================================
EOF
