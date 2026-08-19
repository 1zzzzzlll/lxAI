#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root=$(mktemp -d)
test_server_pid=''
cleanup() {
  [[ -z "$test_server_pid" ]] || kill "$test_server_pid" 2>/dev/null || true
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$test_root/scripts" "$test_root/docs"
cp "$PROJECT_DIR/scripts/common.sh" "$PROJECT_DIR/scripts/generate-env.sh" "$PROJECT_DIR/scripts/detect-model.sh" "$test_root/scripts/"

python3 -m http.server 39201 --bind 127.0.0.1 >/dev/null 2>&1 &
test_server_pid=$!
for _ in 1 2 3 4 5; do
  ss -H -lnt | grep -q ':39201 ' && break
  sleep 0.2
done

WEB_BIND_ADDRESS=127.0.0.1 \
WEB_PORT=39201 \
WEB_PORT_CONFLICT_POLICY=next \
DATA_ROOT=/srv/lxai-test \
IMAGE_ARCH=amd64 \
MODEL_BASE_URL=http://127.0.0.1:6215/v1/chat/completions \
MODEL_NAME=Custom-27B \
MODEL_AUTO_DETECT=false \
  "$test_root/scripts/generate-env.sh"

grep -Fx 'WEB_BIND_ADDRESS=127.0.0.1' "$test_root/.env"
grep -Fx 'WEB_PORT=39202' "$test_root/.env"
grep -Fx 'IMAGE_ARCH=amd64' "$test_root/.env"
grep -Fx "DATA_ROOT='/srv/lxai-test'" "$test_root/.env"
grep -Fx "MODEL_BASE_URL='http://host.docker.internal:6215/v1'" "$test_root/.env"
grep -Fx "MODEL_NAME='Custom-27B'" "$test_root/.env"

if WEB_BIND_ADDRESS=127.0.0.1 \
  WEB_PORT=39201 \
  WEB_PORT_CONFLICT_POLICY=fail \
  DATA_ROOT=/srv/lxai-test \
  MODEL_BASE_URL=http://127.0.0.1:6215/v1 \
  MODEL_NAME=Custom-27B \
  MODEL_AUTO_DETECT=false \
  "$test_root/scripts/generate-env.sh" >/dev/null 2>&1; then
  echo 'expected occupied-port fail policy to stop generation' >&2
  exit 40
fi

# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/common.sh"
[[ "$(IMAGE_ARCH=amd64 target_arch)" == arm64 ]] || exit 44
DATA_ROOT=/data/lxai-test validate_data_root
if (DATA_ROOT=/ validate_data_root >/dev/null 2>&1); then exit 41; fi
if (DATA_ROOT=/etc/lxai validate_data_root >/dev/null 2>&1); then exit 42; fi
if (WEB_BIND_ADDRESS=999.1.1.1 validate_web_bind_address >/dev/null 2>&1); then exit 43; fi

echo 'CONFIG TESTS PASSED'
