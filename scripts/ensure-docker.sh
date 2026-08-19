#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

validate_bool DOCKER_AUTO_INSTALL "${DOCKER_AUTO_INSTALL:-true}"
DOCKER_INSTALL_DIR=${DOCKER_INSTALL_DIR:-/usr/local/bin}
PATH="$DOCKER_INSTALL_DIR:$PATH"
export DOCKER_INSTALL_DIR PATH

start_existing_docker() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl start docker.service >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service docker start >/dev/null 2>&1 || true
  elif [[ -x /etc/init.d/docker ]]; then
    /etc/init.d/docker start >/dev/null 2>&1 || true
  fi
}

if command -v docker >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1; then
    info 'Docker CLI exists; attempting to start the existing Docker service'
    start_existing_docker
  fi
  docker info >/dev/null 2>&1 || die 'Docker is installed but its daemon is unavailable; existing installation was not overwritten'

  if docker compose version >/dev/null 2>&1; then
    pass 'Existing Docker Engine and Compose v2 are available'
    exit 0
  fi
  [[ "${DOCKER_AUTO_INSTALL:-true}" == true ]] || die 'Docker Compose is missing and DOCKER_AUTO_INSTALL=false'
  info 'Docker Engine is healthy; installing the bundled Docker Compose v2 plugin'
  "$PROJECT_DIR/scripts/install-docker-offline.sh"
  docker compose version >/dev/null 2>&1 || die 'bundled Docker Compose plugin installation failed'
  exit 0
fi

[[ "${DOCKER_AUTO_INSTALL:-true}" == true ]] || die 'Docker is missing and DOCKER_AUTO_INSTALL=false'
info 'Docker is not installed; installing Docker Engine and Compose from verified offline assets'
"$PROJECT_DIR/scripts/install-docker-offline.sh"
docker info >/dev/null 2>&1 || die 'Docker daemon is unavailable after offline installation'
docker compose version >/dev/null 2>&1 || die 'Docker Compose is unavailable after offline installation'
