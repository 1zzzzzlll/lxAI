#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_env

call_office() {
  local payload=$1
  compose exec -T office-worker curl -fsS --max-time 240 -H "Authorization: Bearer ${AGENT_SHARED_SECRET}" -H 'Content-Type: application/json' -d "$payload" http://127.0.0.1:8000/tools/execute
}

docx_payload=$(jq -cn '{name:"create_docx",arguments:{path:"outputs/test.docx",title:"离线 AI 办公测试",paragraphs:["中文 English 2026","Office Test"],table:[["项目","数量"],["A",10],["B",20]]}}')
xlsx_payload=$(jq -cn '{name:"create_xlsx",arguments:{path:"outputs/test.xlsx",sheets:{"测试":[["项目","数量"],["A",10],["B",20]]},charts:[{sheet:"测试",title:"数量",category_column:1,value_column:2}]}}')
pptx_payload=$(jq -cn '{name:"create_pptx",arguments:{path:"outputs/test.pptx",slides:[{title:"离线 AI 办公测试",bullets:["中文","English","2026"]},{title:"表格与数字",bullets:["项目 A: 10","项目 B: 20"]}]}}')

docx=$(call_office "$docx_payload")
xlsx=$(call_office "$xlsx_payload")
pptx=$(call_office "$pptx_payload")
jq -e '.ok == true and .validation.libreoffice_pdf == "PASS"' <<<"$docx" >/dev/null || die "DOCX smoke failed: $docx"
jq -e '.ok == true and .validation.openpyxl_reload == "PASS" and .validation.libreoffice_pdf == "PASS"' <<<"$xlsx" >/dev/null || die "XLSX smoke failed: $xlsx"
jq -e '.ok == true and .validation.libreoffice_pdf == "PASS"' <<<"$pptx" >/dev/null || die "PPTX smoke failed: $pptx"
pass 'Office Test: DOCX/XLSX/PPTX/PDF'

python_payload=$(jq -cn '{name:"python_exec",arguments:{code:"import pandas as pd\ndf=pd.DataFrame({\"项目\":[\"A\",\"B\"],\"数量\":[10,20]})\nprint(df[\"数量\"].sum())"}}')
python_result=$(compose exec -T tool-runner curl -fsS --max-time 130 -H "Authorization: Bearer ${AGENT_SHARED_SECRET}" -H 'Content-Type: application/json' -d "$python_payload" http://127.0.0.1:8000/tools/execute)
jq -e '.ok == true and (.stdout | contains("30"))' <<<"$python_result" >/dev/null || die "Python smoke failed: $python_result"
pass 'Python Test: 30'

node_payload=$(jq -cn '{name:"node_exec",arguments:{code:"console.log(JSON.stringify({status:\"ok\",runtime:\"node\"}))"}}')
node_result=$(compose exec -T tool-runner curl -fsS --max-time 130 -H "Authorization: Bearer ${AGENT_SHARED_SECRET}" -H 'Content-Type: application/json' -d "$node_payload" http://127.0.0.1:8000/tools/execute)
jq -e '.ok == true and (.stdout | contains("node"))' <<<"$node_result" >/dev/null || die "Node smoke failed: $node_result"
pass 'Node Test'

agent_payload=$(jq -cn --arg model offline-ai-general '{model:$model,messages:[{role:"user",content:"请调用 get_current_time 工具，并根据工具返回值回复当前时间。"}],stream:false}')
agent_result=$(compose exec -T agent-core curl -fsS --max-time 300 -H "Authorization: Bearer ${AGENT_SHARED_SECRET}" -H 'Content-Type: application/json' -d "$agent_payload" http://127.0.0.1:8000/v1/chat/completions || true)
if jq -e '.choices[0].message.content | length > 0' <<<"$agent_result" >/dev/null 2>&1; then pass 'LLM Tool Calling loop'; else die "Tool Calling smoke failed: $agent_result"; fi

mkdir -p "$DATA_ROOT/files/uploads"
printf '内部测试项目代号：OFFLINE-AI-2026\n' > "$DATA_ROOT/files/uploads/rag-smoke.txt"
pass 'RAG fixture created: uploads/rag-smoke.txt'
