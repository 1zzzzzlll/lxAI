# ARM64 / x86_64 完全离线 AI Agent 综合办公平台

本项目交付固定版本的 `linux/arm64` 与 `linux/amd64` 两套离线部署包。目标服务器只需已安装 Docker 与 Docker Compose；部署阶段不会执行 `docker pull`、`pip install`、`npm install`、`apt update` 或访问公网。已有模型服务只作为 OpenAI Compatible API 使用，平台不会停止、升级或修改模型 Runtime。

## 三步部署

```bash
tar -I zstd -xf offline-ai-arm64-v1.0.0.tar.zst
cd offline-ai-arm64
sudo ./deploy.sh
```

x86_64 服务器改用：

```bash
tar -I zstd -xf offline-ai-x86_64-v1.0.0.tar.zst
cd offline-ai-x86_64
sudo ./deploy.sh
```

每个包内的 `TARGET_ARCH` 会锁定目标架构，部署前同时核对主机和全部镜像架构，不能交叉部署。

部署脚本会校验 SHA256 和镜像架构、校验模型配置、生成强随机密码、检测 Web 端口冲突、导入镜像、启动服务，并执行 Agent、Python、Node、DOCX、XLSX、PPTX、PDF 烟雾测试。

推荐先复制完整配置模板；`config/deployment.env` 存在时，`deploy.sh` 会自动读取：

```bash
cp config/deployment.env.example config/deployment.env
vi config/deployment.env
sudo ./deploy.sh
```

也可直接通过命令行覆盖，命令行优先级最高：

```bash
sudo ./deploy.sh \
  --web-bind 0.0.0.0 \
  --web-port 8088 \
  --port-conflict next \
  --model-url http://127.0.0.1:6215/v1/chat/completions \
  --model-name TT3.6-27B-0623 \
  --data-root /TRS/lxAI
```

`WEB_PORT_CONFLICT_POLICY=next` 会从指定端口向上寻找空闲端口；设为 `fail` 时发现冲突立即停止。再次修改配置后运行 `sudo ./deploy.sh --reconfigure`，已有随机密钥会被保留。

部署完成后查看 `.env`：

```bash
sudo grep -E '^(WEB_BIND_ADDRESS|WEB_PORT|DATA_ROOT|MODEL_NAME|MODEL_BASE_URL|ADMIN_EMAIL|ADMIN_PASSWORD)=' .env
```

浏览器访问：`http://服务器IP:WEB_PORT`。首次启动会用 `.env` 中的 `ADMIN_EMAIL/ADMIN_PASSWORD` 自动创建管理员，之后 Open WebUI 自动关闭注册。

## 在线准备离线包

在可访问互联网、已安装 Docker Buildx 和 zstd 的构建机执行：

```bash
TARGET_ARCH=arm64 ./prepare-offline-bundle.sh
TARGET_ARCH=amd64 ./prepare-offline-bundle.sh
```

脚本会：

1. 预下载 `BAAI/bge-small-zh-v1.5` 到本地模型目录；
2. 使用 Buildx 构建三个目标架构自定义镜像；已存在且架构正确的同版本镜像会复用，设置 `FORCE_REBUILD=1` 可强制重建；
3. 拉取固定版本的目标架构官方镜像；
4. 对每个镜像执行带平台参数的 `docker image inspect` 并强制验证 Architecture；
5. 使用带平台参数的 `docker save` 导出全部镜像并生成 `checksums.sha256`；
6. 分别输出 `dist/offline-ai-arm64-v1.0.0.tar.zst` 或 `dist/offline-ai-x86_64-v1.0.0.tar.zst` 及其 SHA256。

构建机架构可以与目标架构不同，但跨架构构建必须已启用 Buildx/QEMU；目标服务器不会使用 QEMU。

## 服务与端口

| 服务 | 固定版本 | 暴露方式 |
|---|---:|---|
| Nginx | 1.28.0-bookworm | 唯一宿主机端口，默认 `0.0.0.0:8088`，可配置 |
| Open WebUI | v0.9.5 | 仅容器网络 |
| Agent Core | 1.0.0 | 仅容器网络 |
| Office Worker | 1.0.0 | 仅容器网络 |
| Tool Runner | 1.0.0 | 仅容器网络 |
| PostgreSQL | 17.10-bookworm | 仅容器网络 |
| Qdrant | v1.18.2 | 仅容器网络 |

路由：`/` → Open WebUI，`/api/agent/` → Agent Core，`/artifacts/` → 生成文件。数据默认持久化到 `/TRS/lxAI`，可用 `DATA_ROOT` 或 `--data-root` 改为其他专用绝对目录。

## 模型探测与边界

本项目默认预置 `TT3.6-27B-0623`，接口为宿主机 `http://127.0.0.1:6215/v1/chat/completions` 且无需 API Key。部署时接受完整 completions 地址并自动保存为 OpenAI base URL。模型 URL、完整名称与 API Key 均可配置；只有显式设置 `MODEL_AUTO_DETECT=true` 时，`scripts/detect-model.sh` 才会只读探测 6215、常用端口和监听端口的 `/v1/models`。

容器内访问宿主机模型会把 `127.0.0.1`/`localhost` 转换成 `host.docker.internal`。最终配置统一为：

```env
MODEL_BASE_URL=http://host.docker.internal:6215/v1
MODEL_NAME=TT3.6-27B-0623
MODEL_API_KEY=
MODEL_RUNTIME_MANAGED=false
```

平台不会管理模型 Runtime。如果仅发现权重而没有 API，必须先根据目标服务器 GPU/NPU/CPU 和推理框架做独立评估，本包不会擅自安装 CUDA vLLM 或修改生产启动参数。

注意：容器通过宿主机网关访问模型。如果模型进程严格只监听 Linux loopback（而不是 `0.0.0.0` 或宿主机桥接地址），容器将无法连接；部署健康检查会明确报 `Model API` 失败并停止，不会修改现有模型。此时需由模型服务管理员在保持内网防火墙限制的前提下提供一个 Docker 可达的监听地址。

## 日常命令

```bash
./start.sh
./stop.sh
./restart.sh
./status.sh
./healthcheck.sh
./logs.sh agent       # webui / office / tools / all
./backup.sh
./restore.sh /TRS/lxAI/backups/offline-ai-YYYYMMDD-HHMMSS.tar.zst
./uninstall.sh        # 保留数据
./uninstall.sh --purge
```

`--purge` 会二次要求输入 `PURGE`，且只删除校验后的 `DATA_ROOT`。`/`、系统根目录、系统敏感子目录及不足两级的路径都会被拒绝；恢复前会自动创建一份安全备份。

## 文件与模板

共享目录映射关系：

```text
${DATA_ROOT}/files      -> /workspace
${DATA_ROOT}/templates  -> /templates
${DATA_ROOT}/secrets    -> /secrets（只读）
```

用户文件分为 `users/`、`uploads/`、`outputs/`、`tmp/`。Word、Excel、PPT 模板放入 `${DATA_ROOT}/templates/{word,excel,ppt}/`。生成文件返回 `/artifacts/...` 下载地址。路径会在解析后再次检查必须位于 `/workspace`，阻止 `../` 和符号链接逃逸。

## 安全默认值

```env
SAFE_MODE=true
ALLOW_DANGEROUS_TOOLS=false
DB_WRITE_ENABLED=false
HTTP_ALLOW_PRIVATE_ONLY=true
```

默认允许读取、查询、生成办公文件以及在受限容器内执行 Python/Node；删除文件、重启服务、Docker 删除、Kubernetes 写操作、数据库写入和 Git push 默认关闭。Open WebUI 与 Agent Core 不挂载 Docker Socket。Agent Core、Tool Runner、Office Worker 的 CPU、内存和 PID 上限可分别通过 `*_CPUS`、`*_MEMORY`、`*_PIDS_LIMIT` 配置。

SSH 密钥放在 `${DATA_ROOT}/secrets/ssh/`，Kubeconfig 放在 `${DATA_ROOT}/secrets/kubeconfig`，均只读挂载。`http_request` 默认只允许解析到内网或 loopback 的地址。

## 离线与 RAG

Open WebUI 设置 `OFFLINE_MODE=true`、`HF_HUB_OFFLINE=1`、`TRANSFORMERS_OFFLINE=1`，并关闭版本检查、Web Search、Embedding/Reranker/Whisper 自动更新。Embedding 模型在联网准备阶段预先放入包内，部署阶段只读挂载。

执行物理断公网验收前，先运行：

```bash
./healthcheck.sh
docker compose exec open-webui test -f /models/embedding/config.json
```

然后在 Web UI 上传 `uploads/rag-smoke.txt` 建立知识库并询问“内部测试项目代号是什么？”，预期 `OFFLINE-AI-2026`。由于 Open WebUI 的知识库创建涉及管理员会话，这一步在 `docs/acceptance-report.md` 中保留为目标服务器交互验收项，不能仅凭容器健康状态宣称通过。

## 版本、校验与报告

- `VERSION`：组件固定版本；
- `images/manifest.tsv`：镜像名、Architecture、Image ID、Repo Digest、归档名；
- `checksums.sha256`：部署前强制校验的镜像归档哈希；
- `docs/hardware-report.md`：目标服务器部署时生成；
- `docs/acceptance-report.md`：真实验收状态，未执行的项目必须保持 `NOT RUN`。

更多内容见 [架构说明](docs/架构说明.md)、[工具说明](docs/Agent工具说明.md)、[Office 使用](docs/Office使用说明.md)、[离线部署](docs/离线部署说明.md) 和 [故障排查](docs/故障排查.md)。

## 当前验收边界

联网构建机已完成 7 个 ARM64 镜像实跑、完整 Compose 健康、Office 文件链、工具安全门禁和 mock 模型工具闭环；x86_64 验证结果见 `docs/acceptance-report.md`。真实 `TT3.6-27B-0623`、交互式 RAG、备份恢复以及物理断公网测试必须在目标服务器执行；未连接目标服务器前不会标为通过。
