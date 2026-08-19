#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/scripts" "$test_root/bin"
cp "$PROJECT_DIR/scripts/common.sh" "$PROJECT_DIR/scripts/ensure-docker.sh" "$test_root/scripts/"
cp "$PROJECT_DIR/tests/fixtures/fake-docker-healthy.sh" "$test_root/bin/docker"
chmod +x "$test_root/bin/docker"

PATH="$test_root/bin:/usr/bin:/bin" DOCKER_AUTO_INSTALL=true "$test_root/scripts/ensure-docker.sh"

if PATH="$test_root/bin:/usr/bin:/bin" DOCKER_AUTO_INSTALL=invalid "$test_root/scripts/ensure-docker.sh" >/dev/null 2>&1; then
  echo 'expected invalid DOCKER_AUTO_INSTALL to fail' >&2
  exit 50
fi

echo 'DOCKER DETECTION TESTS PASSED'
