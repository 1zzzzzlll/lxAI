#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
load_env
compose down --remove-orphans
if [[ "${1:-}" == '--purge' ]]; then
  validate_data_root
  read -r -p "Type PURGE to permanently delete $DATA_ROOT: " answer
  [[ "$answer" == PURGE ]] || die 'purge cancelled'
  rm -rf --one-file-system "$DATA_ROOT"
  info "Deleted $DATA_ROOT; recovery requires a backup archive"
else
  info "Containers removed; user data retained at $DATA_ROOT"
fi
