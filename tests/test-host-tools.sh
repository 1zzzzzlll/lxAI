#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/scripts" "$test_root/runtime/host-tools" "$test_root/install"
cp "$PROJECT_DIR/scripts/common.sh" "$PROJECT_DIR/scripts/ensure-host-tools.sh" "$test_root/scripts/"
printf 'amd64\n' > "$test_root/TARGET_ARCH"
cat > "$test_root/runtime/host-tools/jq-linux-amd64" <<'EOF'
#!/usr/bin/env bash
if [[ "${1-}" == --version ]]; then printf 'jq-test-1.0\n'; exit 0; fi
exit 0
EOF
chmod +x "$test_root/runtime/host-tools/jq-linux-amd64"
(cd "$test_root/runtime/host-tools" && sha256sum jq-linux-amd64 > checksums.sha256)

HOST_TOOLS_FORCE_INSTALL=true \
HOST_TOOLS_INSTALL_DIR="$test_root/install" \
  "$test_root/scripts/ensure-host-tools.sh"

[[ -x "$test_root/install/jq" ]]
[[ "$("$test_root/install/jq" --version)" == jq-test-1.0 ]]

printf 'tampered\n' >> "$test_root/runtime/host-tools/jq-linux-amd64"
if HOST_TOOLS_FORCE_INSTALL=true HOST_TOOLS_INSTALL_DIR="$test_root/install" \
  "$test_root/scripts/ensure-host-tools.sh" >/dev/null 2>&1; then
  echo 'expected checksum validation to reject a modified jq asset' >&2
  exit 1
fi

echo 'HOST TOOLS TESTS PASSED'
