from pathlib import Path
import asyncio

import pytest

from app import main


def test_safe_path_blocks_escape(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "ROOT", tmp_path.resolve())
    with pytest.raises(ValueError):
        main.safe_path("../../etc/passwd")


def test_safe_path_accepts_child(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "ROOT", tmp_path.resolve())
    assert main.safe_path("outputs/a.txt") == tmp_path / "outputs" / "a.txt"


def test_dangerous_command_pattern():
    assert main.DANGEROUS_PATTERN.search("rm -rf x")
    assert main.DANGEROUS_PATTERN.search("kubectl delete pod x")
    assert not main.DANGEROUS_PATTERN.search("kubectl get pods")


def test_file_write_and_read(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "ROOT", tmp_path.resolve())
    result = asyncio.run(main.file_tool("write_text_file", {"path": "outputs/a.txt", "content": "中文"}))
    assert result["ok"] is True
    read = asyncio.run(main.file_tool("read_text_file", {"path": "outputs/a.txt"}))
    assert read["content"] == "中文"


def test_readonly_sql_gate():
    assert main._readonly_sql("SELECT 1")
    assert main._readonly_sql("WITH x AS (SELECT 1) SELECT * FROM x")
    assert not main._readonly_sql("UPDATE x SET y=1")
    assert not main._readonly_sql("SELECT 1; DELETE FROM x")


def test_safe_command_subcommand_gate(monkeypatch):
    monkeypatch.setattr(main, "SAFE_MODE", True)
    monkeypatch.setattr(main, "ALLOW_DANGEROUS", False)
    main.enforce_safe_command("docker ps")
    main.enforce_safe_command("systemctl status nginx")
    with pytest.raises(PermissionError):
        main.enforce_safe_command("docker run nginx")
    with pytest.raises(PermissionError):
        main.enforce_safe_command("systemctl restart nginx")


def test_scp_requires_safe_mode_opt_out(monkeypatch):
    monkeypatch.setattr(main, "SAFE_MODE", True)
    with pytest.raises(PermissionError):
        asyncio.run(main.scp_transfer({"host": "server", "local_path": "a", "remote_path": "/tmp/a"}, upload=False))
