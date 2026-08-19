#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
load_env
quick=false
[[ "${1:-}" == '--quick' ]] && quick=true
failures=0
probe_host=$(web_probe_host)

check() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$label"; else printf '[FAIL] %s\n' "$label" >&2; failures=$((failures + 1)); fi
}

model_health() {
  local args=(-fsS --max-time 20)
  [[ -n "${MODEL_API_KEY:-}" ]] && args+=(-H "Authorization: Bearer ${MODEL_API_KEY}")
  if compose exec -T agent-core curl "${args[@]}" "${MODEL_BASE_URL}/models" >/dev/null 2>&1; then return 0; fi
  local payload
  payload=$(jq -cn --arg model "$MODEL_NAME" '{model:$model,messages:[{role:"user",content:"你好，请只回复 OK"}],max_tokens:8,stream:false}')
  compose exec -T agent-core curl "${args[@]}" -H 'Content-Type: application/json' -d "$payload" "${MODEL_BASE_URL}/chat/completions"
}

check Docker docker info
check 'Nginx' curl -fsS --max-time 5 "http://${probe_host}:${WEB_PORT}/healthz"
check 'Open WebUI' compose exec -T open-webui curl -fsS --max-time 10 http://127.0.0.1:8080/health
check 'Agent Core' compose exec -T agent-core curl -fsS --max-time 10 http://127.0.0.1:8000/health
check 'Tool Runner' compose exec -T tool-runner curl -fsS --max-time 10 http://127.0.0.1:8000/health
check 'Office Worker' compose exec -T office-worker curl -fsS --max-time 10 http://127.0.0.1:8000/health
check PostgreSQL compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
check 'Vector DB' compose exec -T agent-core curl -fsS --max-time 10 http://qdrant:6333/healthz
check 'Model API' model_health
check 'Artifact Storage' compose exec -T tool-runner test -w /workspace/outputs
check LibreOffice compose exec -T office-worker libreoffice --headless --version

if ! $quick; then
  python_payload=$(jq -cn '{name:"python_exec",arguments:{code:"import pandas as pd\ndf=pd.DataFrame({\"项目\":[\"A\",\"B\"],\"数量\":[10,20]})\nprint(df[\"数量\"].sum())"}}')
  node_payload=$(jq -cn '{name:"node_exec",arguments:{code:"console.log(JSON.stringify({status:\"ok\",runtime:\"node\"}))"}}')
  time_payload=$(jq -cn '{name:"get_current_time",arguments:{}}')
  tool_result() {
    local payload=$1
    local filter=$2
    local response
    response=$(compose exec -T tool-runner curl -fsS --max-time 130 -H "Authorization: Bearer ${AGENT_SHARED_SECRET}" -H 'Content-Type: application/json' -d "$payload" http://127.0.0.1:8000/tools/execute) || return 1
    jq -e "$filter" <<<"$response" >/dev/null
  }
  check Python tool_result "$python_payload" '.ok == true and (.stdout | contains("30"))'
  check Node tool_result "$node_payload" '.ok == true and (.stdout | contains("node"))'
  check 'Tool API' tool_result "$time_payload" '.ok == true and (.iso8601 | length > 0)'
  check 'Embedding files' compose exec -T open-webui test -f /models/embedding/config.json
fi

if ((failures == 0)); then echo 'ALL SERVICES HEALTHY'; else echo "$failures CHECK(S) FAILED" >&2; exit 1; fi
