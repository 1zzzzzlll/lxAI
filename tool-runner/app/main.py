import asyncio
import ipaddress
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx
import psycopg
import pymysql
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

ROOT = Path(os.getenv("WORKSPACE_ROOT", "/workspace")).resolve()
SSH_ROOT = Path(os.getenv("SSH_ROOT", "/secrets/ssh")).resolve()
SHARED_SECRET = os.getenv("AGENT_SHARED_SECRET", "")
SAFE_MODE = os.getenv("SAFE_MODE", "true").lower() == "true"
ALLOW_DANGEROUS = os.getenv("ALLOW_DANGEROUS_TOOLS", "false").lower() == "true"
DB_WRITE = os.getenv("DB_WRITE_ENABLED", "false").lower() == "true"
PRIVATE_HTTP_ONLY = os.getenv("HTTP_ALLOW_PRIVATE_ONLY", "true").lower() == "true"
DEFAULT_TIMEOUT = int(os.getenv("TOOL_TIMEOUT", "120"))

app = FastAPI(title="Offline AI Tool Runner", version="1.0.0")

READ_ONLY_COMMANDS = {"awk", "cat", "curl", "df", "dig", "docker", "du", "find", "free", "git", "grep", "head", "helm", "ip", "journalctl", "jq", "kubectl", "ls", "mtr", "nc", "nginx", "nslookup", "ping", "ps", "sed", "ss", "stat", "systemctl", "tail", "top", "traceroute", "uname", "wc"}
DANGEROUS_PATTERN = re.compile(r"[;&|`$()\n]|\b(rm|reboot|shutdown|poweroff|mkfs|fdisk|parted|dd|mount|umount|systemctl\s+(restart|stop|disable)|docker\s+(rm|rmi|stop|restart|kill|system\s+prune)|kubectl\s+(delete|apply|patch|replace|scale)|git\s+(push|clean|reset))\b", re.I)
SAFE_SUBCOMMANDS = {
    "docker": {"ps", "inspect", "logs", "stats", "images", "info", "version"},
    "git": {"status", "diff", "log", "branch", "show", "rev-parse"},
    "helm": {"list", "status", "get", "history", "version"},
    "kubectl": {"get", "describe", "logs", "version", "cluster-info"},
    "systemctl": {"status", "show", "is-active", "is-enabled", "list-units"},
}


class ToolRequest(BaseModel):
    name: str
    arguments: dict[str, Any] = {}


def authorize(value: str | None) -> None:
    if SHARED_SECRET and value != f"Bearer {SHARED_SECRET}":
        raise HTTPException(status_code=401, detail="invalid API key")


def safe_path(value: str, must_exist: bool = False) -> Path:
    candidate = (ROOT / value.lstrip("/\\")).resolve(strict=must_exist)
    if candidate != ROOT and ROOT not in candidate.parents:
        raise ValueError("path escapes /workspace")
    return candidate


def timeout(args: dict[str, Any]) -> int:
    return max(1, min(int(args.get("timeout", DEFAULT_TIMEOUT)), 1800))


def enforce_safe_command(command: str) -> None:
    if DANGEROUS_PATTERN.search(command) and not ALLOW_DANGEROUS:
        raise PermissionError("dangerous command blocked")
    try:
        parts = shlex.split(command)
    except ValueError as exc:
        raise ValueError(f"invalid shell quoting: {exc}") from exc
    if not parts:
        raise ValueError("empty command")
    first = Path(parts[0]).name
    if not SAFE_MODE:
        return
    if first not in READ_ONLY_COMMANDS:
        raise PermissionError(f"command not in SAFE_MODE allowlist: {first}")
    if first in SAFE_SUBCOMMANDS:
        subcommand = next((part for part in parts[1:] if not part.startswith("-")), "")
        if subcommand not in SAFE_SUBCOMMANDS[first]:
            raise PermissionError(f"{first} subcommand not allowed in SAFE_MODE: {subcommand or '<missing>'}")
    if first == "nginx" and "-t" not in parts:
        raise PermissionError("SAFE_MODE allows only nginx -t")
    if first == "curl" and any(part == "-X" or part.startswith("--request") or part in {"-d", "--data", "--data-raw", "--data-binary", "-T", "--upload-file"} for part in parts[1:]):
        raise PermissionError("SAFE_MODE allows only read-only curl requests")


async def run_process(argv: list[str], seconds: int, cwd: Path = ROOT, stdin: str | None = None) -> dict[str, Any]:
    proc = await asyncio.create_subprocess_exec(*argv, cwd=cwd, stdin=asyncio.subprocess.PIPE if stdin is not None else None, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env={**os.environ, "HOME": "/tmp/tool-home"}, start_new_session=True)
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(stdin.encode() if stdin is not None else None), timeout=seconds)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return {"ok": False, "error": f"timeout after {seconds}s", "exit_code": -1}
    return {"ok": proc.returncode == 0, "exit_code": proc.returncode, "stdout": stdout.decode(errors="replace")[-100000:], "stderr": stderr.decode(errors="replace")[-100000:]}


async def file_tool(name: str, a: dict[str, Any]) -> dict[str, Any]:
    if name == "list_files":
        path = safe_path(a.get("path", "."), True)
        if not path.is_dir():
            raise ValueError("not a directory")
        items = [{"name": item.name, "path": str(item.relative_to(ROOT)), "type": "directory" if item.is_dir() else "file", "size": item.stat().st_size if item.is_file() else None} for item in sorted(path.iterdir())[:1000]]
        return {"ok": True, "items": items}
    if name == "read_text_file":
        path = safe_path(a["path"], True)
        return {"ok": True, "content": path.read_text(encoding=a.get("encoding", "utf-8"), errors="replace")[:1_000_000]}
    if name == "write_text_file":
        path = safe_path(a["path"])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(str(a.get("content", "")), encoding=a.get("encoding", "utf-8"))
        return {"ok": True, "path": str(path.relative_to(ROOT)), "size": path.stat().st_size}
    if name == "copy_file":
        src, dst = safe_path(a["source"], True), safe_path(a["destination"])
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        return {"ok": True, "path": str(dst.relative_to(ROOT))}
    if name == "move_file":
        src, dst = safe_path(a["source"], True), safe_path(a["destination"])
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(src, dst)
        return {"ok": True, "path": str(dst.relative_to(ROOT))}
    if name == "create_directory":
        path = safe_path(a["path"])
        path.mkdir(parents=True, exist_ok=True)
        return {"ok": True, "path": str(path.relative_to(ROOT))}
    if name == "delete_file":
        if not ALLOW_DANGEROUS:
            raise PermissionError("delete_file requires ALLOW_DANGEROUS_TOOLS=true")
        path = safe_path(a["path"], True)
        if not path.is_file() or path.is_symlink():
            raise ValueError("only regular files can be deleted")
        path.unlink()
        return {"ok": True}
    if name == "file_info":
        path = safe_path(a["path"], True)
        stat = path.stat()
        return {"ok": True, "path": str(path.relative_to(ROOT)), "size": stat.st_size, "is_file": path.is_file(), "is_dir": path.is_dir(), "mode": oct(stat.st_mode & 0o777)}
    if name == "search_files":
        base = safe_path(a.get("path", "."), True)
        pattern = re.compile(a["pattern"], re.I if a.get("ignore_case", True) else 0)
        results = []
        for path in base.rglob("*"):
            if len(results) >= 500 or not path.is_file() or path.stat().st_size > 5_000_000:
                continue
            try:
                for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                    if pattern.search(line):
                        results.append({"path": str(path.relative_to(ROOT)), "line": number, "text": line[:500]})
            except OSError:
                continue
        return {"ok": True, "matches": results}
    raise KeyError(name)


async def python_exec(a: dict[str, Any]) -> dict[str, Any]:
    with tempfile.NamedTemporaryFile("w", suffix=".py", dir=ROOT, encoding="utf-8", delete=False) as handle:
        handle.write(a["code"])
        script = Path(handle.name)
    try:
        return await run_process(["python3", "-I", str(script)], timeout(a))
    finally:
        script.unlink(missing_ok=True)


async def node_exec(a: dict[str, Any]) -> dict[str, Any]:
    with tempfile.NamedTemporaryFile("w", suffix=".mjs", dir=ROOT, encoding="utf-8", delete=False) as handle:
        handle.write(a["code"])
        script = Path(handle.name)
    try:
        return await run_process(["node", str(script)], timeout(a))
    finally:
        script.unlink(missing_ok=True)


async def shell_exec(a: dict[str, Any]) -> dict[str, Any]:
    command = str(a["command"]).strip()
    enforce_safe_command(command)
    return await run_process(["bash", "-lc", command], timeout(a))


async def http_request(a: dict[str, Any]) -> dict[str, Any]:
    method = a.get("method", "GET").upper()
    if method not in {"GET", "HEAD"} and SAFE_MODE:
        raise PermissionError("SAFE_MODE allows only GET and HEAD")
    parsed = urlparse(a["url"])
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("only http/https URLs are allowed")
    if PRIVATE_HTTP_ONLY:
        addresses = {item[4][0] for item in socket.getaddrinfo(parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80), type=socket.SOCK_STREAM)}
        if not addresses or any(not (ipaddress.ip_address(ip).is_private or ipaddress.ip_address(ip).is_loopback) for ip in addresses):
            raise PermissionError("HTTP target must resolve only to private/loopback addresses")
    async with httpx.AsyncClient(verify=a.get("verify_tls", True), timeout=timeout(a), follow_redirects=False) as client:
        response = await client.request(method, a["url"], headers=a.get("headers"), json=a.get("json"), data=a.get("form"))
    return {"ok": response.is_success, "status_code": response.status_code, "headers": dict(response.headers), "body": response.text[:1_000_000]}


async def ssh_exec(a: dict[str, Any]) -> dict[str, Any]:
    host = a["host"]
    if not re.fullmatch(r"[A-Za-z0-9_.@:-]+", host):
        raise ValueError("invalid SSH host")
    enforce_safe_command(str(a["command"]))
    argv = ["ssh", "-F", str(SSH_ROOT / "config"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, a["command"]]
    return await run_process(argv, timeout(a))


async def k8s_get(a: dict[str, Any]) -> dict[str, Any]:
    resource = a["resource"]
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", resource):
        raise ValueError("invalid Kubernetes resource")
    argv = ["kubectl", "get", resource]
    if a.get("name"):
        argv.append(a["name"])
    if a.get("namespace"):
        argv += ["-n", a["namespace"]]
    argv += ["-o", a.get("output", "wide")]
    return await run_process(argv, timeout(a))


async def k8s_read(a: dict[str, Any]) -> dict[str, Any]:
    operation = a.get("operation", "get")
    if operation not in {"get", "describe", "logs"}:
        raise PermissionError("only get/describe/logs are allowed")
    resource = a.get("resource", "pods")
    name = a.get("name")
    namespace = a.get("namespace")
    argv = ["kubectl", operation]
    if operation == "logs":
        if not name:
            raise ValueError("logs requires pod name")
        argv.append(name)
        if a.get("container"):
            argv += ["-c", a["container"]]
        argv += ["--tail", str(min(int(a.get("tail", 500)), 5000))]
    else:
        argv.append(resource)
        if name:
            argv.append(name)
        if operation == "get":
            argv += ["-o", a.get("output", "wide")]
    if namespace:
        argv += ["-n", namespace]
    return await run_process(argv, timeout(a))


async def scp_transfer(a: dict[str, Any], upload: bool) -> dict[str, Any]:
    if SAFE_MODE:
        raise PermissionError("SCP requires SAFE_MODE=false")
    host = a["host"]
    if not re.fullmatch(r"[A-Za-z0-9_.@:-]+", host):
        raise ValueError("invalid SSH host")
    local = safe_path(a["local_path"], must_exist=upload)
    remote = a["remote_path"]
    if "\n" in remote or "\r" in remote:
        raise ValueError("invalid remote path")
    if not upload:
        local.parent.mkdir(parents=True, exist_ok=True)
    source, destination = (str(local), f"{host}:{remote}") if upload else (f"{host}:{remote}", str(local))
    return await run_process(["scp", "-F", str(SSH_ROOT / "config"), "-o", "BatchMode=yes", source, destination], timeout(a))


def _readonly_sql(sql: str) -> bool:
    stripped = re.sub(r"/\*[\s\S]*?\*/|--[^\n]*", "", sql).strip().lower()
    return stripped.startswith(("select", "show", "explain", "with")) and ";" not in stripped.rstrip(";")


async def db_query(a: dict[str, Any]) -> dict[str, Any]:
    sql = str(a.get("sql", ""))
    write = bool(a.get("write", False))
    engine = str(a.get("engine", "postgresql")).lower()
    if engine in {"postgres", "postgresql", "kingbase", "mysql"} and (write or not _readonly_sql(sql)) and not DB_WRITE:
        raise PermissionError("database writes require DB_WRITE_ENABLED=true")

    def execute_sync():
        if engine in {"postgres", "postgresql", "kingbase"}:
            with psycopg.connect(a["dsn"], connect_timeout=10) as connection:
                with connection.cursor() as cursor:
                    cursor.execute(sql, a.get("parameters"))
                    rows = cursor.fetchmany(min(int(a.get("limit", 1000)), 10000)) if cursor.description else []
                    columns = [item.name for item in cursor.description] if cursor.description else []
                    if write:
                        connection.commit()
        elif engine == "mysql":
            parsed = urlparse(a["dsn"])
            connection = pymysql.connect(host=parsed.hostname, port=parsed.port or 3306, user=parsed.username, password=parsed.password, database=parsed.path.lstrip("/"), connect_timeout=10)
            try:
                with connection.cursor() as cursor:
                    cursor.execute(sql, a.get("parameters"))
                    rows = cursor.fetchmany(min(int(a.get("limit", 1000)), 10000)) if cursor.description else []
                    columns = [item[0] for item in cursor.description] if cursor.description else []
                    if write:
                        connection.commit()
            finally:
                connection.close()
        elif engine == "redis":
            import redis as redis_client

            command = shlex.split(sql)
            if not command:
                raise ValueError("Redis command is empty")
            read_commands = {"GET", "MGET", "HGET", "HGETALL", "LRANGE", "SMEMBERS", "ZRANGE", "TTL", "TYPE", "EXISTS", "SCAN"}
            if command[0].upper() not in read_commands:
                raise PermissionError("Redis writes require a dedicated write tool")
            connection = redis_client.Redis.from_url(a["dsn"], socket_connect_timeout=10, socket_timeout=timeout(a), decode_responses=True)
            value = connection.execute_command(*command)
            rows = value if isinstance(value, list) else [value]
            columns = ["value"]
        elif engine in {"elasticsearch", "es"}:
            parsed = urlparse(a["dsn"])
            if parsed.scheme not in {"http", "https"} or not parsed.hostname:
                raise ValueError("Elasticsearch DSN must be http(s)")
            index = str(a.get("index", "_all")).strip("/")
            body = a.get("query") or {"query": {"query_string": {"query": sql or "*"}}, "size": min(int(a.get("limit", 100)), 1000)}
            with httpx.Client(timeout=timeout(a), verify=a.get("verify_tls", True)) as client:
                response = client.post(f"{a['dsn'].rstrip('/')}/{index}/_search", json=body)
                response.raise_for_status()
                data = response.json()
            rows = [hit.get("_source", hit) for hit in data.get("hits", {}).get("hits", [])]
            columns = sorted({key for row in rows if isinstance(row, dict) for key in row})
        else:
            raise ValueError("supported engines: postgresql/kingbase/mysql/redis/elasticsearch")
        return {"ok": True, "columns": columns, "rows": rows, "row_count": len(rows)}

    return await asyncio.wait_for(asyncio.to_thread(execute_sync), timeout=timeout(a))


async def git_read(a: dict[str, Any]) -> dict[str, Any]:
    operation = a.get("operation", "status")
    if operation not in {"status", "diff", "log", "branch", "show"}:
        raise PermissionError("git operation is read-only")
    path = safe_path(a.get("path", "."), True)
    argv = ["git", "-C", str(path), operation]
    if operation == "log":
        argv += ["--oneline", "-n", str(min(int(a.get("limit", 20)), 100))]
    return await run_process(argv, timeout(a))


async def get_current_time(a: dict[str, Any]) -> dict[str, Any]:
    now = datetime.now(timezone.utc).astimezone()
    return {"ok": True, "iso8601": now.isoformat(), "timezone": str(now.tzinfo)}


TOOLS = {"list_files", "read_text_file", "write_text_file", "copy_file", "move_file", "create_directory", "delete_file", "file_info", "search_files"}


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"status": "ok", "workspace": str(ROOT), "safe_mode": SAFE_MODE, "dangerous_tools": ALLOW_DANGEROUS}


@app.post("/tools/execute")
async def execute(request: ToolRequest, authorization: str | None = Header(default=None)) -> dict[str, Any]:
    authorize(authorization)
    try:
        if request.name in TOOLS:
            return await file_tool(request.name, request.arguments)
        handlers = {"python_exec": python_exec, "node_exec": node_exec, "shell_exec": shell_exec, "http_request": http_request, "ssh_exec": ssh_exec, "scp_get": lambda a: scp_transfer(a, False), "scp_put": lambda a: scp_transfer(a, True), "k8s_get": k8s_get, "k8s_read": k8s_read, "git_read": git_read, "db_query": db_query, "get_current_time": get_current_time}
        if request.name not in handlers:
            raise KeyError(f"unknown tool: {request.name}")
        return await handlers[request.name](request.arguments)
    except (KeyError, ValueError, PermissionError, OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
