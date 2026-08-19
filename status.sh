#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
load_env
printf '%-18s %s\n' SERVICE STATUS
for service in nginx open-webui agent-core office-worker tool-runner postgres qdrant; do
  state=$(compose ps --format json "$service" 2>/dev/null | jq -r 'if type=="array" then .[0].State // "DOWN" else .State // "DOWN" end' 2>/dev/null || echo DOWN)
  printf '%-18s %s\n' "$service" "${state^^}"
done
model_args=(-fsS)
[[ -n "${MODEL_API_KEY:-}" ]] && model_args+=(-H "Authorization: Bearer ${MODEL_API_KEY}")
if compose exec -T agent-core curl "${model_args[@]}" "$MODEL_BASE_URL/models" >/dev/null 2>&1; then
  model=EXTERNAL/UP
else
  payload=$(jq -cn --arg model "$MODEL_NAME" '{model:$model,messages:[{role:"user",content:"OK"}],max_tokens:4,stream:false}')
  if compose exec -T agent-core curl "${model_args[@]}" -H 'Content-Type: application/json' -d "$payload" "$MODEL_BASE_URL/chat/completions" >/dev/null 2>&1; then model=EXTERNAL/UP; else model=EXTERNAL/DOWN; fi
fi
printf '%-18s %s\n' model "$model"
