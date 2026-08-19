#!/usr/bin/env bash
set -Eeuo pipefail

OUTPUT_FILE="${1:-}"
REPORT_FILE="${2:-}"
command -v curl >/dev/null || { echo 'curl is required' >&2; exit 1; }
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }

candidates=()
configured_url=${MODEL_BASE_URL:-}
configured_url=${configured_url%/}
configured_url=${configured_url%/chat/completions}
configured_url=${configured_url%/}
[[ -n "$configured_url" ]] && candidates+=("$configured_url")
for port in 6215 8000 8080 11434; do candidates+=("http://127.0.0.1:${port}/v1"); done
while read -r port; do
  [[ -n "$port" ]] && candidates+=("http://127.0.0.1:${port}/v1")
done < <(ss -lntH 2>/dev/null | awk '{sub(/.*:/,"",$4); if ($4 ~ /^[0-9]+$/) print $4}' | sort -nu)

selected_url="$configured_url"
selected_name="${MODEL_NAME:-}"
all_models=''
seen=' '
for base in "${candidates[@]}"; do
  [[ "$seen" == *" $base "* ]] && continue
  seen+="$base "
  auth_args=()
  [[ -n "${MODEL_API_KEY:-}" ]] && auth_args=(-H "Authorization: Bearer ${MODEL_API_KEY}")
  body=$(curl -fsS --connect-timeout 2 --max-time 5 "${auth_args[@]}" "$base/models" 2>/dev/null || true)
  [[ -n "$body" ]] || continue
  names=$(jq -r '.data[]?.id // .models[]?.name // .models[]?.model // empty' <<<"$body" 2>/dev/null || true)
  [[ -n "$names" ]] || continue
  all_models+="URL: $base\n$names\n"
  preferred=$(grep -Ei '^(TT3\.6-27B(-0623)?|Qwen3\.6-27B)$' <<<"$names" | head -n1 || true)
  if [[ -n "$preferred" ]]; then selected_url="$base"; selected_name="$preferred"; break; fi
  if [[ -z "$selected_url" ]]; then selected_url="$base"; selected_name=$(head -n1 <<<"$names"); fi
done

if [[ -z "$selected_url" || -z "$selected_name" ]]; then
  if [[ -t 0 ]]; then
    read -r -p 'Model API base URL (ending in /v1): ' selected_url
    read -r -p 'Model name: ' selected_name
  else
    echo 'No OpenAI-compatible model API detected and no interactive terminal is available.' >&2
    exit 2
  fi
fi

container_url="$selected_url"
container_url="${container_url/127.0.0.1/host.docker.internal}"
container_url="${container_url/localhost/host.docker.internal}"

if [[ -n "$OUTPUT_FILE" ]]; then
  printf 'MODEL_BASE_URL=%s\nMODEL_NAME=%s\nMODEL_API_KEY=%s\n' "$container_url" "$selected_name" "${MODEL_API_KEY:-}" > "$OUTPUT_FILE"
else
  printf 'MODEL_BASE_URL=%s\nMODEL_NAME=%s\n' "$container_url" "$selected_name"
fi

if [[ -n "$REPORT_FILE" ]]; then
  mkdir -p "$(dirname "$REPORT_FILE")"
  {
    echo '# Hardware and model report'
    echo
    echo "Generated: $(date -Is)"
    echo
    echo '```text'
    echo "Architecture: $(uname -m)"
    echo "Kernel: $(uname -srmo)"
    echo "CPU: $(awk -F: '/model name|Model/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)"
    echo "RAM: $(free -h | awk '/Mem:/ {print $2}')"
    echo "Disk: $(df -h / | awk 'NR==2 {print $2 " total, " $4 " free"}')"
    echo "Docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unavailable)"
    echo "NVIDIA: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd, - || echo not-detected)"
    echo "NPU: $(npu-smi info 2>/dev/null | head -n5 | tr '\n' ' ' || echo not-detected)"
    echo "Selected model: $selected_name"
    echo "Selected API: $selected_url"
    printf 'Detected APIs/models:\n%b' "$all_models"
    echo '```'
    echo
    echo 'Existing runtime processes (read-only snapshot):'
    echo '```text'
    ps -ef | grep -Ei 'vllm|sglang|ollama|llama|qwen|transformers' | grep -v grep || true
    echo '```'
    echo
    echo 'Existing model containers (read-only snapshot):'
    echo '```text'
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null || true
    echo '```'
  } > "$REPORT_FILE"
fi
