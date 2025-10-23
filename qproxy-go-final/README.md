
# qproxy (Go)

一个最小化的 **Q 代理服务**，落盘会话到 `q-sessions/{{sop_id}}`，把 SOP 模板渲染为 Prompt，
并通过 **Q CLI** 调用 `--trust-all --no-interactive --resume` 与本地 **MCP HTTP server** 协作完成查询。

> 目录创建时间：2025-10-23T09:05:53.178826

## 目录结构
```
.
├── bin/                 # 构建产物放这里（build.sh 会创建）
├── cmd/qproxy/main.go   # 入口
├── config/config.json   # 配置（包含 sdn5_cpu 固定参数与 MCP 环境变量）
├── q-sessions/          # 每个 sop_id 一个目录，供 --resume 与历史落盘
├── sops/*.json          # SOP 定义（必填参数、默认值、模板）
├── build.sh             # 构建脚本
└── start.sh             # 启动脚本
```

## 先决条件
- 已安装 Go 1.22+
- 已安装 **Q CLI**，例如命令 `q` 可用
- 你的 **MCP HTTP server / mcp-bridge** 已经在本机跑着（如：`http://127.0.0.1:7011`）

## 配置 `config/config.json`
```json
{
  "q_bin": "q",
  "q_args": ["ask"],
  "mcp_env": {"MCP_BRIDGE_URL": "http://127.0.0.1:7011"},
  "sdn5_cpu": {"cluster":"sdn5","namespace":"omada-central","cpu_target_pct":90,"evaluate_window":"5m","vm_endpoint":"http://victoria:8428"}
}
```
- 如需自定义 MCP 的环境变量名/值（取决于你 Q CLI 的接入方式），调整 `mcp_env` 即可。
- `sdn5_cpu` 下的固定参数会注入到模板变量 `.SDN5.*`。

## 构建与启动
```bash
./build.sh
PORT=8080 ./start.sh
# 或直接运行二进制：
# ./bin/qproxy
```

## SOP 模板与必选参数
SOP 定义位于 `./sops/*.json`，字段：
- `id`：sop_id
- `required_params`：必需参数列表（请求体中缺失会 400）
- `defaults`：默认参数（缺省时会使用）
- `template`：Go `text/template` 模板，可用变量：
  - `.Params.<key>` 请求参数（已合并 defaults）
  - `.SDN5.*` 固定参数（来自 `config.json` 的 `sdn5_cpu`）
  - `.Now` 当前时间（RFC3339）

## API
### 健康检查
```bash
curl -s http://127.0.0.1:8080/healthz
```

### 列出可用 SOP
```bash
curl -s http://127.0.0.1:8080/sops | jq .
```

### 执行（核心接口）
```bash
curl -sS http://127.0.0.1:8080/run -H 'Content-Type: application/json' -d '{
  "sop_id": "vm_up",
  "params": {
    "tenant": "omada-central",
    "lookback": "2h",
    "namespace": "omada-central"
  }
}' | jq .
```
- 服务端会：
  1. 合并默认值 → 校验必填参数
  2. 渲染 SOP 模板为 Prompt（含 `.SDN5` 固定参数）
  3. 把历史写入 `q-sessions/{{sop_id}}/history.log`，同时作为 `--resume` 目录给 **Q CLI**
  4. 以 `--trust-all --no-interactive --resume q-sessions/{{sop_id}}` 调用 **Q CLI**
  5. 返回标准输出、错误输出与最终 Prompt 以便排查

### 重置某个 sop 的会话（清空 resume 目录）
```bash
curl -sS http://127.0.0.1:8080/run -H 'Content-Type: application/json' -d '{
  "sop_id": "vm_up",
  "params": {"tenant":"omada-central","lookback":"2h"},
  "reset": true
}' | jq .
```

## 与 MCP 的对接
- 本工程不会直接调用 MCP 工具，而是让 **Q CLI** 在 `--resume` 会话中自行与 MCP 交互（你已有的 `mcp-bridge`/HTTP server 生效）。
- 如果需要通过环境变量指示 Q 使用你的 MCP server，可以在 `config.json -> mcp_env` 中添加或改名，例如：
  - `{"MCP_BRIDGE_URL":"http://127.0.0.1:7011"}`
  - 或你的 Q CLI 所需的任何变量名。

## 示例 SOP
- `vm_up`：VictoriaMetrics up 状态巡检
- `cw_ec2_cpu`：CloudWatch EC2 CPU 利用率分析
- `es_error_search`：Elasticsearch 错误日志搜索

按你的生产 SOP 习惯，可以直接在 `./sops/` 新增更多 `{id}.json`。

## 常见问题
- **Q CLI 没有把 prompt 当 stdin 读？** 本实现把 prompt 当作最后一个参数传入（`q ask "<prompt>"`）。若你使用的 Q CLI 变体需要 stdin，可在 `main.go/runQ` 中改为写入 `cmd.Stdin`。
- **--resume 目录不生效？** 请确认 Q CLI 支持 `--resume <dir>` 的用法，并且在该目录生成了会话状态文件（同时我们也会记录 `history.log` 供排查）。
- **MCP 环境变量名不匹配？** 根据你使用的 Q CLI/bridge，修改 `config.json` 的 `mcp_env` 键名即可。


## 附：来自上传包的文件
- `task_instructions.md` 已合并。
- `sops/` 下已合并上传包中的 SOP 文件（仅 `.json` 会被加载；其他格式保留但当前版本不会读取）。

- 现在支持从 `sops/*.json` 与 `sops/*.jsonl` 加载 SOP；macOS 的 `._*` 文件会被自动忽略。


## 参数与正确性校验
- **参数校验**：以 `sdn5_cpu` 为基准，校验 `namespace/cluster` 是否与基准一致；通用校验包括 `lookback` 时长格式、`instance_id` 形态、`tenant` 命名等，问题会在 `param_validation` 字段返回。
- **配置校验**：检查 `sdn5_cpu` 完整性与 `mcp_env` 配置，结果在 `config_validation` 返回。
- **Q 返回正确性认证**：qproxy 会在渲染后的 prompt 末尾自动追加一个“JSON 校验块”的要求（并以 ```json 代码块包裹）。
  Q 执行后，服务会解析最后一个 JSON 代码块，校验 `verdict=="ok"`、`source` 是否为预期的 `mcp:*`、以及 `evidence_count>=0`，结果在 `q_validation` 字段返回。
- **MCP 调用确认**：通过 `expected_source=mcp:*` 与验证块中的 `source` 一致性来确认，并且响应里会展示传给 Q 进程的 `mcp_env` 键名（值已打码）。
