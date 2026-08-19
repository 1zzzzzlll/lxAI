#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
load_env
validate_data_root
archive=${1:-}
[[ -n "$archive" && -f "$archive" ]] || die 'usage: ./restore.sh backup.tar.zst'
case "$archive" in *.tar.zst) ;; *) die 'backup must end with .tar.zst' ;; esac

if [[ -f "${archive}.sha256" ]]; then (cd "$(dirname "$archive")" && sha256sum -c "$(basename "${archive}.sha256")") || die 'backup checksum failed'; fi
if tar --zstd -tf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then die 'unsafe path found in backup archive'; fi

info 'Creating a safety backup before restore'
"$PROJECT_DIR/backup.sh"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
tar --zstd -xf "$archive" -C "$staging"
[[ -f "$staging/MANIFEST" && -f "$staging/postgres.sql" && -d "$staging/data" ]] || die 'invalid backup structure'

compose stop open-webui agent-core office-worker tool-runner nginx qdrant
for name in open-webui qdrant files templates logs config secrets; do
  source_path="$staging/data/$name"
  [[ -e "$source_path" ]] || continue
  target_path="$DATA_ROOT/$name"
  [[ "$target_path" == "$DATA_ROOT"/* ]] || die "unsafe restore target: $target_path"
  rm -rf --one-file-system "$target_path"
  cp -a "$source_path" "$target_path"
done
chown -R 10002:20000 "$DATA_ROOT/files"
chmod -R u+rwX,g+rwX,o-rwx "$DATA_ROOT/files"
compose up -d postgres
deadline=$((SECONDS + 120))
until compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do ((SECONDS < deadline)) || die 'PostgreSQL did not start'; sleep 2; done
compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$staging/postgres.sql"
compose up -d --no-build --pull never
"$PROJECT_DIR/healthcheck.sh" --quick
pass 'Restore completed; pre-restore backup is retained under data backups/'
