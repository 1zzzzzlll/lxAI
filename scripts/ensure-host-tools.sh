#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

HOST_TOOLS_INSTALL_DIR=${HOST_TOOLS_INSTALL_DIR:-/usr/local/bin}
PATH="$HOST_TOOLS_INSTALL_DIR:$PATH"
export HOST_TOOLS_INSTALL_DIR PATH

if [[ "${HOST_TOOLS_FORCE_INSTALL:-false}" != true ]] && command -v jq >/dev/null 2>&1; then
  jq -e -n 'true' >/dev/null 2>&1 || die "existing jq is not functional: $(command -v jq)"
  pass "Existing jq is available: $(jq --version)"
  exit 0
fi

expected_arch=$(target_arch)
asset_dir="$PROJECT_DIR/runtime/host-tools"
asset_name="jq-linux-${expected_arch}"
asset="$asset_dir/$asset_name"
checksum_file="$asset_dir/checksums.sha256"

[[ -f "$asset" ]] || die "jq is missing and the bundled asset was not found: runtime/host-tools/$asset_name"
[[ -s "$checksum_file" ]] || die 'bundled jq checksum file is missing or empty'
(cd "$asset_dir" && sha256sum -c checksums.sha256 >/dev/null) || die 'bundled jq checksum validation failed'

mkdir -p "$HOST_TOOLS_INSTALL_DIR"
install -m 0755 "$asset" "$HOST_TOOLS_INSTALL_DIR/jq"
hash -r
command -v jq >/dev/null 2>&1 || die "jq was installed but is not available in PATH: $HOST_TOOLS_INSTALL_DIR"
jq -e -n 'true' >/dev/null 2>&1 || die 'bundled jq failed its functional check after installation'
pass "Installed bundled $(jq --version) to $HOST_TOOLS_INSTALL_DIR/jq"
