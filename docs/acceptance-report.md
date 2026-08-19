# Acceptance report

Verification date: 2026-08-19. Build host: Windows Docker Desktop x86_64, with native amd64 containers and ARM64 emulation. Target-only checks remain explicitly `NOT RUN`; emulation results are not presented as native target-server results.

| Check | Status | Evidence |
|---|---|---|
| Source unit tests | PASS | Agent 7 + Tool Runner 7 + Office 7 = 21 tests |
| Deployment configuration tests | PASS | Configurable bind/port/model/data root; occupied-port `next` and `fail`; unsafe path and invalid bind rejection |
| Docker Compose config | PASS | `docker compose --env-file .env.example config --quiet` |
| ARM64 custom image build | PASS | Buildx built and loaded Agent Core, Office Worker and Tool Runner for `linux/arm64` |
| All image architecture | PASS | 7/7 images inspect as `arm64`; every container returned `uname -m = aarch64` |
| x86_64 custom image build | PASS | Buildx built and loaded Agent Core, Office Worker and Tool Runner for `linux/amd64` |
| x86_64 full Compose | PASS | 7/7 services healthy; every container returned `uname -m = x86_64`; Nginx health returned 200 |
| x86_64 tools and Office | PASS | Python `30`, Node `x64`, kubectl v1.33.3, Helm v3.18.4, LibreOffice 7.4.7.2, DOCX/XLSX/PPTX/PDF validation |
| x86_64 Agent loop | PASS (mock integration) | Agent called `get_current_time` through Tool Runner and returned `MOCK_TOOL_OK` |
| Full Compose startup | PASS (emulated) | Nginx, Open WebUI, Agent Core, Office Worker, Tool Runner, PostgreSQL and Qdrant all healthy |
| Unified Web entry | PASS (emulated) | `/healthz` 200, Open WebUI `/` 200, Agent models available through `/api/agent/` |
| Admin bootstrap | PASS (emulated) | PostgreSQL `user` row: `admin@offline.local`, role `admin` |
| Real model API | NOT RUN | `127.0.0.1:6215` is not reachable on the build workstation; target server was not connected |
| Native Tool Calling loop | PASS (mock integration) | Nginx → Agent → mock TT model → `get_current_time` → model returned `MOCK_TOOL_OK` |
| One-click smoke script | PASS (mock integration) | Office/PDF, pandas `30`, Node, Agent tool loop and RAG fixture all passed |
| JSON Tool Calling fallback | PASS (unit) | Fenced/plain JSON parsing and normalized tool message covered |
| Loop/timeout controls | PASS (unit) | Tool timeout and repeated-call guard covered |
| Python | PASS (ARM64 container) | Python 3.12.11, venv, pandas sum returned `30`, runtime `aarch64` |
| Node | PASS (ARM64 container) | Node 22.18.0 returned `{status: ok, runtime: node}`, runtime `arm64` |
| kubectl / Helm / Git / SSH | PASS (ARM64 container) | Version/runtime commands executed successfully |
| File and command safety | PASS | Workspace traversal tests,中文读写, and `docker run` rejection in SAFE_MODE |
| DOCX create/edit/PDF | PASS (ARM64 container) | Python reopen + LibreOffice PDF + PyMuPDF page validation |
| XLSX create/edit/analyze/merge/PDF | PASS (ARM64 container) | OpenPyXL reopen + LibreOffice PDF; styled merge regression covered |
| PPTX create/edit/chart/boxes/PDF | PASS (ARM64 container) | Python-PPTX reopen + LibreOffice PDF + PyMuPDF validation |
| PDF to images | PASS (ARM64 container) | One PDF page rendered to PNG |
| Artifact download/traversal | PASS (emulated) | Download returned expected bytes; plain and encoded `..` returned HTTP 400 |
| Embedding/Qdrant bootstrap | PASS (emulated) | Local embedding config mounted; Open WebUI and Qdrant healthy with offline flags |
| RAG interactive answer | NOT RUN | Requires real target model and authenticated browser knowledge-base workflow |
| Backup/Restore data cycle | NOT RUN | Requires the target `DATA_ROOT`; scripts are syntax/config checked only |
| Physical no-internet test | NOT RUN | Requires target server network isolation |

The target deployment generates `docs/hardware-report.md`. Completion on each physical target server still requires `sudo ./deploy.sh`, real-model tool-call smoke, RAG interaction, backup/restore, and physical offline verification.
