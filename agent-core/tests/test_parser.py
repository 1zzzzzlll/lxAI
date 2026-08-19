from app.main import json_fallback
import asyncio
import json

from app import main


def test_json_fallback_plain():
    call = json_fallback('{"tool":"python_exec","arguments":{"code":"print(1)"}}')
    assert call["function"]["name"] == "python_exec"


def test_json_fallback_fenced():
    call = json_fallback('```json\n{"name":"list_files","args":{}}\n```')
    assert call["function"]["name"] == "list_files"


def test_json_fallback_invalid():
    assert json_fallback("normal answer") is None


def test_agent_native_tool_loop(monkeypatch):
    replies = iter([
        {"role": "assistant", "content": None, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "get_current_time", "arguments": "{}"}}]},
        {"role": "assistant", "content": "完成"},
    ])

    async def fake_model(messages, tools):
        return next(replies)

    async def fake_tool(name, arguments):
        assert name == "get_current_time"
        return {"ok": True, "iso8601": "2026-08-19T10:00:00+08:00"}

    monkeypatch.setattr(main, "call_model", fake_model)
    monkeypatch.setattr(main, "execute_tool", fake_tool)
    request = main.ChatRequest(messages=[{"role": "user", "content": "几点"}])
    result = asyncio.run(main.run_agent(request))
    assert result["content"] == "完成"


def test_agent_json_fallback_normalizes_tool_message(monkeypatch):
    captured = []

    async def fake_model(messages, tools):
        captured.append(messages)
        if len(captured) == 1:
            return {"role": "assistant", "content": '{"tool":"get_current_time","arguments":{}}'}
        assert messages[-2]["tool_calls"][0]["function"]["name"] == "get_current_time"
        assert json.loads(messages[-1]["content"])["ok"] is True
        return {"role": "assistant", "content": "完成"}

    async def fake_tool(name, arguments):
        return {"ok": True}

    monkeypatch.setattr(main, "call_model", fake_model)
    monkeypatch.setattr(main, "execute_tool", fake_tool)
    result = asyncio.run(main.run_agent(main.ChatRequest(messages=[{"role": "user", "content": "几点"}])))
    assert result["content"] == "完成"


def test_agent_tool_timeout_is_returned_to_model(monkeypatch):
    calls = 0

    async def fake_model(messages, tools):
        nonlocal calls
        calls += 1
        if calls == 1:
            return {"role": "assistant", "content": None, "tool_calls": [{"id": "slow", "type": "function", "function": {"name": "get_current_time", "arguments": "{}"}}]}
        assert "tool timeout" in messages[-1]["content"]
        return {"role": "assistant", "content": "超时已处理"}

    async def slow_tool(name, arguments):
        await asyncio.sleep(0.05)
        return {"ok": True}

    monkeypatch.setattr(main, "call_model", fake_model)
    monkeypatch.setattr(main, "execute_tool", slow_tool)
    monkeypatch.setattr(main, "TOOL_TIMEOUT", 0.001)
    result = asyncio.run(main.run_agent(main.ChatRequest(messages=[{"role": "user", "content": "测试超时"}])))
    assert result["content"] == "超时已处理"


def test_repeated_tool_call_is_blocked(monkeypatch):
    calls = 0

    async def fake_model(messages, tools):
        nonlocal calls
        calls += 1
        if calls <= 3:
            return {"role": "assistant", "content": None, "tool_calls": [{"id": f"same-{calls}", "type": "function", "function": {"name": "get_current_time", "arguments": "{}"}}]}
        assert "repeated tool call blocked" in messages[-1]["content"]
        return {"role": "assistant", "content": "重复调用已阻止"}

    async def fake_tool(name, arguments):
        return {"ok": True}

    monkeypatch.setattr(main, "call_model", fake_model)
    monkeypatch.setattr(main, "execute_tool", fake_tool)
    result = asyncio.run(main.run_agent(main.ChatRequest(messages=[{"role": "user", "content": "重复"}])))
    assert result["content"] == "重复调用已阻止"
