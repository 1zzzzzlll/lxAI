#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
load_env
compose restart
"$PROJECT_DIR/healthcheck.sh" --quick
