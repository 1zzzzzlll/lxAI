#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
load_env
case "${1:-all}" in
  agent) service=agent-core ;;
  webui) service=open-webui ;;
  office) service=office-worker ;;
  tools) service=tool-runner ;;
  all) service='' ;;
  *) service="$1" ;;
esac
if [[ -n "$service" ]]; then compose logs --tail="${TAIL:-200}" -f "$service"; else compose logs --tail="${TAIL:-200}" -f; fi
