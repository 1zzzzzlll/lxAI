#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
load_env
validate_data_root
command -v zstd >/dev/null || die 'zstd is required for backup'
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/data" "$staging/project"

info 'Creating consistent PostgreSQL dump'
compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists > "$staging/postgres.sql"
tar --exclude='./postgres' --exclude='./backups' -cf - -C "$DATA_ROOT" . | tar -xf - -C "$staging/data"
cp "$ENV_FILE" "$PROJECT_DIR/docker-compose.yml" "$PROJECT_DIR/VERSION" "$staging/project/"
cp -a "$PROJECT_DIR/config" "$staging/project/"
printf 'created=%s\nplatform_version=%s\n' "$(date -Is)" "${PLATFORM_VERSION}" > "$staging/MANIFEST"

timestamp=$(date +%Y%m%d-%H%M%S)
archive="$DATA_ROOT/backups/offline-ai-${timestamp}.tar.zst"
tmp_archive=$(mktemp --suffix=.tar.zst)
tar --zstd -cf "$tmp_archive" -C "$staging" .
checksum=$(sha256sum "$tmp_archive" | awk '{print $1}')
mv "$tmp_archive" "$archive"
printf '%s  %s\n' "$checksum" "$(basename "$archive")" > "${archive}.sha256"
pass "Backup: $archive"
