#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_env
payload=$(jq -cn '{model:"offline-ai-general",messages:[{role:"user",content:"你好，请回复 OK"}],stream:false}')
compose exec -T agent-core curl -fsS --max-time 300 -H "Authorization: Bearer${AGENT_SHARED_SECRET}" -H 'Content-Type: application/json' -d "$payload" http://127.0.0.1:8000/v1/chat/completions | jq .
