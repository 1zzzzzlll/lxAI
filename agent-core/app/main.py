import asyncio
import json
import os
import re
import time
import uuid
from typing import Any

import httpx
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

MODEL_BASE_URL = os.getenv("MODEL_BASE_URL", "http://host.docker.internal:6215/v1").removesuffix("/chat/completions").rstrip("/")
MODEL_NAME = os.getenv("MODEL_NAME", "TT3.6-27B-0623")
MODEL_API_KEY = os.getenv("MODEL_API_KEY", "")
SHARED_SECRET = os.getenv("AGENT_SHARED_SECRET", "")
MAX_STEPS = int(os.getenv("AGENT_MAX_STEPS", "10"))
TOOL_TIMEOUT = float(os.getenv("TOOL_TIMEOUT", "120"))
TOOL_RUNNER_URL = os.getenv("TOOL_RUNNER_URL", "http://tool-runner:8000").rstrip("/")
OFFICE_WORKER_URL = os.getenv("OFFICE_WORKER_URL", "http://office-worker:8000").rstrip("/")

app = FastAPI(title="Offline AI Agent Core", version="1.0.0")

AGENTS = {
    "offline-ai-general": "你是完全离线的通用助手。回答准确简洁；需要工具时必须调用工具，不得虚构执行结果。",
    "offline-ai-office": "你是综合办公助手，擅长 Word、Excel、PPT、PDF 和数据分析。生成文件时必须调用 Office 工具并返回下载链接。",
    "offline-ai-ops": "你是运维开发助手，擅长 Linux、Docker、Kubernetes、网络、日志、Python、Node、Git 和数据库。先读后写，危险操作必须说明且服从安全策略。",
}

TOOLS = [
    {"type": "function", "function": {"name": "get_current_time", "description": "获取当前服务器时间；询问当前时间时必须调用", "parameters": {"type": "object", "properties": {}, "additionalProperties": False}}},
    {"type": "function", "function": {"name": "list_files", "description": "列出工作区文件", "parameters": {"type": "object", "properties": {"path": {"type": "string", "default": "."}}, "additionalProperties": False}}},
    {"type": "function", "function": {"name": "read_text_file", "description": "读取工作区文本文件", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "write_text_file", "description": "写入工作区文本文件", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "search_files", "description": "在工作区文本文件中搜索", "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}, "path": {"type": "string", "default": "."}}, "required": ["pattern"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "python_exec", "description": "在受限工作区执行 Python", "parameters": {"type": "object", "properties": {"code": {"type": "string"}, "timeout": {"type": "integer"}}, "required": ["code"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "node_exec", "description": "在受限工作区执行 JavaScript", "parameters": {"type": "object", "properties": {"code": {"type": "string"}, "timeout": {"type": "integer"}}, "required": ["code"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "shell_exec", "description": "执行只读或安全的 Shell 命令", "parameters": {"type": "object", "properties": {"command": {"type": "string"}, "timeout": {"type": "integer"}}, "required": ["command"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "http_request", "description": "访问内网 HTTP/HTTPS API", "parameters": {"type": "object", "properties": {"method": {"type": "string"}, "url": {"type": "string"}, "headers": {"type": "object"}, "json": {}, "verify_tls": {"type": "boolean"}}, "required": ["method", "url"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "ssh_exec", "description": "通过已配置 SSH 执行命令", "parameters": {"type": "object", "properties": {"host": {"type": "string"}, "command": {"type": "string"}}, "required": ["host", "command"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "k8s_get", "description": "只读查询 Kubernetes 资源", "parameters": {"type": "object", "properties": {"resource": {"type": "string"}, "namespace": {"type": "string"}, "name": {"type": "string"}}, "required": ["resource"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "create_docx", "description": "创建并验证 Word 文件", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "title": {"type": "string"}, "paragraphs": {"type": "array", "items": {"type": "string"}}, "table": {"type": "array", "items": {"type": "array"}}}, "required": ["path", "title"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "create_xlsx", "description": "创建并验证 Excel 文件", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "sheets": {"type": "object"}}, "required": ["path", "sheets"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "create_pptx", "description": "创建并验证 PPT 文件", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "slides": {"type": "array", "items": {"type": "object"}}}, "required": ["path", "slides"], "additionalProperties": False}}},
    {"type": "function", "function": {"name": "office_to_pdf", "description": "将 DOCX/XLSX/PPTX 转换并验证为 PDF", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"], "additionalProperties": False}}},
]

TOOLS.extend([
    {"type": "function", "function": {"name": "copy_file", "description": "复制工作区文件", "parameters": {"type": "object", "properties": {"source": {"type": "string"}, "destination": {"type": "string"}}, "required": ["source", "destination"]}}},
    {"type": "function", "function": {"name": "move_file", "description": "移动工作区文件", "parameters": {"type": "object", "properties": {"source": {"type": "string"}, "destination": {"type": "string"}}, "required": ["source", "destination"]}}},
    {"type": "function", "function": {"name": "create_directory", "description": "创建工作区目录", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "delete_file", "description": "删除工作区文件；受安全开关限制", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "file_info", "description": "读取工作区文件元数据", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "scp_get", "description": "通过 SSH 配置从内网主机下载文件", "parameters": {"type": "object", "properties": {"host": {"type": "string"}, "remote_path": {"type": "string"}, "local_path": {"type": "string"}}, "required": ["host", "remote_path", "local_path"]}}},
    {"type": "function", "function": {"name": "scp_put", "description": "通过 SSH 配置上传工作区文件", "parameters": {"type": "object", "properties": {"host": {"type": "string"}, "local_path": {"type": "string"}, "remote_path": {"type": "string"}}, "required": ["host", "local_path", "remote_path"]}}},
    {"type": "function", "function": {"name": "k8s_read", "description": "执行 get、describe、logs 等 Kubernetes 只读操作；events 使用 get events", "parameters": {"type": "object", "properties": {"operation": {"type": "string"}, "resource": {"type": "string"}, "name": {"type": "string"}, "namespace": {"type": "string"}}, "required": ["operation"]}}},
    {"type": "function", "function": {"name": "git_read", "description": "执行 status、diff、log、branch、show 等 Git 只读操作", "parameters": {"type": "object", "properties": {"operation": {"type": "string"}, "path": {"type": "string"}, "limit": {"type": "integer"}}, "required": ["operation"]}}},
    {"type": "function", "function": {"name": "db_query", "description": "查询 PostgreSQL、Kingbase、MySQL、Redis 或 Elasticsearch；写操作默认关闭", "parameters": {"type": "object", "properties": {"engine": {"type": "string"}, "dsn": {"type": "string"}, "sql": {"type": "string"}, "parameters": {"type": "array"}, "limit": {"type": "integer"}}, "required": ["dsn", "sql"]}}},
    {"type": "function", "function": {"name": "read_docx", "description": "读取 Word 文档", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "edit_docx", "description": "替换或追加 Word 内容并重新验证", "parameters": {"type": "object", "properties": {"source": {"type": "string"}, "output": {"type": "string"}, "replace": {"type": "object"}, "append_paragraphs": {"type": "array"}}, "required": ["source"]}}},
    {"type": "function", "function": {"name": "read_xlsx", "description": "读取 Excel 工作簿", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "edit_xlsx", "description": "修改 Excel 单元格、公式、Sheet 或追加数据", "parameters": {"type": "object", "properties": {"source": {"type": "string"}, "output": {"type": "string"}, "set_cells": {"type": "array"}, "formulas": {"type": "array"}, "append_rows": {"type": "object"}}, "required": ["source"]}}},
    {"type": "function", "function": {"name": "merge_xlsx", "description": "合并多个 Excel 工作簿", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "sources": {"type": "array", "items": {"type": "string"}}}, "required": ["path", "sources"]}}},
    {"type": "function", "function": {"name": "analyze_xlsx", "description": "分析 Excel 行列及数值统计，可生成汇总文件", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "output": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "read_pptx", "description": "读取 PPT 文本", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "edit_pptx", "description": "替换 PPT 文本或追加幻灯片并重新验证", "parameters": {"type": "object", "properties": {"source": {"type": "string"}, "output": {"type": "string"}, "replace": {"type": "object"}, "append_slides": {"type": "array"}}, "required": ["source"]}}},
    {"type": "function", "function": {"name": "read_pdf", "description": "读取 PDF 文本", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "pdf_to_images", "description": "把 PDF 各页渲染为 PNG", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "output_dir": {"type": "string"}, "dpi": {"type": "integer"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "merge_pdf", "description": "合并 PDF", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "sources": {"type": "array", "items": {"type": "string"}}}, "required": ["path", "sources"]}}},
    {"type": "function", "function": {"name": "split_pdf", "description": "按页拆分 PDF", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
])

OFFICE_TOOLS = {
    "create_docx", "edit_docx", "read_docx", "docx_to_pdf",
    "create_xlsx", "edit_xlsx", "merge_xlsx", "analyze_xlsx", "read_xlsx",
    "create_pptx", "edit_pptx", "read_pptx", "pptx_to_pdf",
    "office_to_pdf", "read_pdf", "extract_pdf_text", "pdf_to_images", "merge_pdf", "split_pdf",
}


class ChatRequest(BaseModel):
    model: str = "offline-ai-general"
    messages: list[dict[str, Any]]
    stream: bool = False
    temperature: float | None = None
    max_tokens: int | None = None
    tools: list[dict[str, Any]] | None = None
    tool_choice: Any = None


def authorize(authorization: str | None) -> None:
    if SHARED_SECRET and authorization != f"Bearer {SHARED_SECRET}":
        raise HTTPException(status_code=401, detail="invalid API key")


def json_fallback(content: str | None) -> dict[str, Any] | None:
    if not content:
        return None
    candidates = [content.strip()]
    match = re.search(r"```(?:json)?\s*([\s\S]*?)```", content, re.I)
    if match:
        candidates.insert(0, match.group(1).strip())
    for candidate in candidates:
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            name = value.get("tool") or value.get("name")
            args = value.get("arguments", value.get("args", {}))
            if isinstance(name, str) and isinstance(args, dict):
                return {"id": f"fallback_{uuid.uuid4().hex[:12]}", "type": "function", "function": {"name": name, "arguments": json.dumps(args, ensure_ascii=False)}}
    return None


async def call_model(messages: list[dict[str, Any]], tools: list[dict[str, Any]]) -> dict[str, Any]:
    payload = {"model": MODEL_NAME, "messages": messages, "tools": tools, "tool_choice": "auto", "stream": False}
    headers = {"Authorization": f"Bearer {MODEL_API_KEY}"} if MODEL_API_KEY else {}
    timeout = httpx.Timeout(600.0, connect=20.0)
    async with httpx.AsyncClient(timeout=timeout) as client:
        response = await client.post(f"{MODEL_BASE_URL}/chat/completions", headers=headers, json=payload)
        if response.status_code in {400, 404, 422}:
            fallback_messages = [dict(item) for item in messages]
            instruction = "原生工具调用不可用。需要工具时只输出严格 JSON：{\"tool\":\"工具名\",\"arguments\":{...}}，不要使用 Markdown。可用工具：" + ", ".join(item["function"]["name"] for item in tools)
            fallback_messages[0] = {"role": "system", "content": str(fallback_messages[0].get("content", "")) + "\n\n" + instruction}
            response = await client.post(f"{MODEL_BASE_URL}/chat/completions", headers=headers, json={"model": MODEL_NAME, "messages": fallback_messages, "stream": False})
        response.raise_for_status()
        data = response.json()
    choices = data.get("choices") or []
    if not choices or not isinstance(choices[0].get("message"), dict):
        raise RuntimeError("model returned no assistant message")
    return choices[0]["message"]


async def execute_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    base = OFFICE_WORKER_URL if name in OFFICE_TOOLS else TOOL_RUNNER_URL
    headers = {"Authorization": f"Bearer {SHARED_SECRET}"} if SHARED_SECRET else {}
    async with httpx.AsyncClient(timeout=TOOL_TIMEOUT + 5) as client:
        response = await client.post(f"{base}/tools/execute", headers=headers, json={"name": name, "arguments": arguments})
        response.raise_for_status()
        return response.json()


async def run_agent(request: ChatRequest) -> dict[str, Any]:
    system_prompt = AGENTS.get(request.model, AGENTS["offline-ai-general"])
    messages = list(request.messages)
    if not messages or messages[0].get("role") != "system":
        messages.insert(0, {"role": "system", "content": system_prompt})
    else:
        messages[0] = {"role": "system", "content": system_prompt + "\n\n" + str(messages[0].get("content", ""))}
    tool_defs = TOOLS + (request.tools or [])
    seen: dict[str, int] = {}
    for _ in range(MAX_STEPS):
        assistant = await call_model(messages, tool_defs)
        calls = assistant.get("tool_calls") or []
        if not calls:
            fallback = json_fallback(assistant.get("content"))
            calls = [fallback] if fallback else []
        if not calls:
            return assistant
        if not assistant.get("tool_calls"):
            assistant = {"role": "assistant", "content": None, "tool_calls": calls}
        messages.append(assistant)
        for call in calls:
            function = call.get("function", {})
            name = function.get("name", "")
            raw_args = function.get("arguments") or "{}"
            try:
                arguments = raw_args if isinstance(raw_args, dict) else json.loads(raw_args)
            except json.JSONDecodeError as exc:
                result = {"ok": False, "error": f"tool arguments JSON parse failed: {exc}"}
            else:
                signature = json.dumps([name, arguments], ensure_ascii=False, sort_keys=True)
                seen[signature] = seen.get(signature, 0) + 1
                if seen[signature] > 2:
                    result = {"ok": False, "error": "repeated tool call blocked"}
                else:
                    try:
                        result = await asyncio.wait_for(execute_tool(name, arguments), timeout=TOOL_TIMEOUT)
                    except asyncio.TimeoutError:
                        result = {"ok": False, "error": f"tool timeout after {TOOL_TIMEOUT}s"}
                    except Exception as exc:
                        result = {"ok": False, "error": f"tool exception: {type(exc).__name__}: {exc}"}
            messages.append({"role": "tool", "tool_call_id": call.get("id", "fallback"), "name": name, "content": json.dumps(result, ensure_ascii=False)})
    return {"role": "assistant", "content": f"Agent stopped after {MAX_STEPS} steps to prevent an infinite loop."}


def completion(message: dict[str, Any], model: str) -> dict[str, Any]:
    return {"id": f"chatcmpl-{uuid.uuid4().hex}", "object": "chat.completion", "created": int(time.time()), "model": model, "choices": [{"index": 0, "message": message, "finish_reason": "stop"}], "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}}


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"status": "ok", "model_base_url": MODEL_BASE_URL, "model_name": MODEL_NAME}


@app.get("/v1/models")
async def models(authorization: str | None = Header(default=None)) -> dict[str, Any]:
    authorize(authorization)
    return {"object": "list", "data": [{"id": key, "object": "model", "owned_by": "offline-ai"} for key in AGENTS]}


@app.post("/v1/chat/completions")
async def chat(request: ChatRequest, authorization: str | None = Header(default=None)):
    authorize(authorization)
    try:
        message = await run_agent(request)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=f"model API error: {exc.response.status_code} {exc.response.text[:500]}") from exc
    except (httpx.HTTPError, RuntimeError) as exc:
        raise HTTPException(status_code=502, detail=f"model API unavailable: {exc}") from exc
    body = completion(message, request.model)
    if not request.stream:
        return body

    async def stream():
        chunk = {"id": body["id"], "object": "chat.completion.chunk", "created": body["created"], "model": request.model, "choices": [{"index": 0, "delta": {"role": "assistant", "content": message.get("content") or ""}, "finish_reason": None}]}
        yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"
        final = {**chunk, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
        yield f"data: {json.dumps(final, ensure_ascii=False)}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(stream(), media_type="text/event-stream")
