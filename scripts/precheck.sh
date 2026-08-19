#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

expected_arch=$(target_arch)
detected_arch=$(host_arch)
[[ "$detected_arch" == "$expected_arch" ]] || die "$expected_arch package requires a $expected_arch server; detected $(uname -m)"
pass "Architecture: $(uname -m) ($detected_arch)"
command -v docker >/dev/null || die 'Docker is unavailable after environment preparation'
docker info >/dev/null 2>&1 || die 'Docker daemon is unavailable after environment preparation'
pass 'Docker daemon'
if docker compose version >/dev/null 2>&1; then pass 'Docker Compose v2'; else die 'Docker Compose v2 is missing'; fi
for command in bash curl jq openssl tar zstd sha256sum awk sed grep ss readlink; do command -v "$command" >/dev/null || die "$command is unavailable after environment preparation"; done
pass 'Host deployment commands'

disk_check_path=${DATA_ROOT:-$PROJECT_DIR}
while [[ ! -e "$disk_check_path" && "$disk_check_path" != / ]]; do disk_check_path=$(dirname "$disk_check_path"); done
available_kb=$(df -Pk "$disk_check_path" | awk 'NR==2 {print $4}')
validate_uint MIN_FREE_DISK_GB "${MIN_FREE_DISK_GB:-20}" 1 1048576
required_kb=$((${MIN_FREE_DISK_GB:-20} * 1048576))
(( available_kb >= required_kb )) || die "at least $((required_kb / 1048576)) GiB free disk is required"
pass "Free disk: $((available_kb / 1048576)) GiB"

memory_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
validate_uint MIN_MEMORY_GB "${MIN_MEMORY_GB:-8}" 1 1048576
(( memory_kb >= ${MIN_MEMORY_GB:-8} * 1048576 )) || warn "only $((memory_kb / 1048576)) GiB RAM detected; configured minimum is ${MIN_MEMORY_GB:-8} GiB"
pass "RAM: $((memory_kb / 1048576)) GiB"

if [[ -f "$PROJECT_DIR/checksums.sha256" && -s "$PROJECT_DIR/checksums.sha256" ]]; then
  (cd "$PROJECT_DIR" && sha256sum -c checksums.sha256) || die 'checksum validation failed; deployment stopped'
  pass 'Offline image checksums'
else
  die 'checksums.sha256 is missing or empty'
fi
