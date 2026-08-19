# Agent 工具说明

工具类别包括 File、Python、Node、Shell、HTTP、SSH/SCP、Kubernetes、Git、Database 和 Office。

- File：list/read/write/copy/move/mkdir/delete/info/search，强制限制在 `/workspace`。
- Python/Node：临时脚本在 Tool Runner 内运行，捕获 stdout/stderr，超时后终止。
- Shell：`SAFE_MODE=true` 时只允许只读命令白名单，并阻止管道、命令替换及危险动词。
- HTTP：默认仅 GET/HEAD 且目标所有解析地址必须是 private 或 loopback。
- SSH/SCP：使用只读 `/secrets/ssh/config` 与密钥；BatchMode 禁止密码提示。远程命令也经过只读命令门禁，SCP 需设置 `SAFE_MODE=false`。
- Kubernetes：仅 get/describe/logs；写操作默认关闭。
- Git：仅 status/diff/log/branch/show。
- Database：PostgreSQL/Kingbase/MySQL 默认只允许单条 SELECT/SHOW/EXPLAIN/WITH 查询；Redis 只允许只读命令；Elasticsearch 只暴露 `_search` 查询。
- Office：创建/读取/修改 DOCX，创建/读取/修改/合并/分析 XLSX，创建/读取/修改 PPTX，读取/提取/转图片/合并/拆分 PDF，Office 转 PDF。

危险能力只有管理员明确修改 `.env` 并重启相关容器后才启用。不要将生产密钥写入 Prompt 或普通用户文件。
