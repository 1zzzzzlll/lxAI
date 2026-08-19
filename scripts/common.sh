#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
info() { printf '[INFO] %s\n' "$*"; }

target_arch() {
  local arch=''
  if [[ -f "$PROJECT_DIR/TARGET_ARCH" ]]; then arch=$(tr -d '[:space:]' < "$PROJECT_DIR/TARGET_ARCH"); fi
  arch=${arch:-${IMAGE_ARCH:-}}
  arch=${arch:-arm64}
  case "$arch" in
    arm64|aarch64) printf 'arm64\n' ;;
    amd64|x86_64) printf 'amd64\n' ;;
    *) die "unsupported target architecture: $arch" ;;
  esac
}

host_arch() {
  case "$(uname -m)" in
    arm64|aarch64) printf 'arm64\n' ;;
    amd64|x86_64) printf 'amd64\n' ;;
    *) printf '%s\n' "$(uname -m)" ;;
  esac
}

compose() {
  local project_arg=$PROJECT_DIR
  local env_arg=$ENV_FILE
  if command -v cygpath >/dev/null 2>&1; then
    project_arg=$(cygpath -w "$PROJECT_DIR")
    env_arg=$(cygpath -w "$ENV_FILE")
  fi
  if docker compose version >/dev/null 2>&1; then
    MSYS_NO_PATHCONV=1 docker compose --project-directory "$project_arg" --env-file "$env_arg" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    MSYS_NO_PATHCONV=1 docker-compose --project-directory "$project_arg" --env-file "$env_arg" "$@"
  else
    die 'Docker Compose v2 or docker-compose is required'
  fi
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die ".env not found; run ./deploy.sh first"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

validate_bool() {
  local name=$1
  local value=${2:-}
  [[ "$value" == true || "$value" == false ]] || die "$name must be true or false; got: ${value:-<empty>}"
}

validate_uint() {
  local name=$1
  local value=${2:-}
  local minimum=${3:-0}
  local maximum=${4:-2147483647}
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be an integer; got: ${value:-<empty>}"
  (( value >= minimum && value <= maximum )) || die "$name must be between $minimum and $maximum; got: $value"
}

validate_positive_number() {
  local name=$1
  local value=${2:-}
  [[ "$value" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || die "$name must be a positive number; got: ${value:-<empty>}"
  awk -v value="$value" 'BEGIN { exit(value > 0 ? 0 : 1) }' || die "$name must be greater than zero; got: $value"
}

validate_memory_limit() {
  local name=$1
  local value=${2:-}
  [[ "$value" =~ ^[1-9][0-9]*([bkmgBKMG]|[kKmMgG][bB])?$ ]] || die "$name must be a Docker memory value such as 4096m or 4g; got: ${value:-<empty>}"
}

validate_web_bind_address() {
  local value=${WEB_BIND_ADDRESS:-0.0.0.0}
  local octet
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "WEB_BIND_ADDRESS must be an IPv4 address; got: $value"
  IFS=. read -r -a octets <<<"$value"
  for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || die "invalid WEB_BIND_ADDRESS: $value"; done
}

port_is_listening() {
  local port=$1
  ss -H -lnt 2>/dev/null | awk -v expected="$port" '
    {
      address=$4
      sub(/^.*:/, "", address)
      gsub(/[^0-9]/, "", address)
      if (address == expected) found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

port_owned_by_current_stack() {
  local port=$1
  local container_id
  command -v docker >/dev/null 2>&1 || return 1
  container_id=$(docker ps -q \
    --filter 'label=com.docker.compose.project=offline-ai' \
    --filter 'label=com.docker.compose.service=nginx' 2>/dev/null | head -n1)
  [[ -n "$container_id" ]] || return 1
  docker inspect --format '{{range $key, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostPort}}{{end}}{{end}}' "$container_id" 2>/dev/null \
    | grep -Fxq "$port"
}

web_probe_host() {
  case "${WEB_BIND_ADDRESS:-0.0.0.0}" in
    0.0.0.0) printf '127.0.0.1\n' ;;
    *) printf '%s\n' "$WEB_BIND_ADDRESS" ;;
  esac
}

validate_data_root() {
  local candidate=${DATA_ROOT:-}
  [[ -n "$candidate" && "$candidate" == /* ]] || die "DATA_ROOT must be a non-empty absolute path; got: ${candidate:-<empty>}"
  if command -v readlink >/dev/null 2>&1; then candidate=$(readlink -m -- "$candidate"); fi
  candidate=${candidate%/}
  [[ -n "$candidate" && "$candidate" != / ]] || die 'DATA_ROOT cannot be /'
  case "$candidate" in
    /bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "DATA_ROOT cannot be a system root: $candidate"
      ;;
    /bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib64/*|/proc/*|/root/*|/run/*|/sbin/*|/sys/*|/usr/*)
      die "DATA_ROOT cannot be inside a protected system path: $candidate"
      ;;
  esac
  [[ "$candidate" =~ ^/[^/]+/[^/]+ ]] || die "DATA_ROOT must contain at least two path components; got: $candidate"
  DATA_ROOT=$candidate
  export DATA_ROOT
}
