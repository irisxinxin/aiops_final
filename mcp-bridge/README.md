# MCP HTTP Bridge

MCP HTTP Bridge 是一个聚合多个 MCP (Model Context Protocol) 服务器的 HTTP 网关，将多个 MCP 工具统一暴露为 HTTP API。

## 功能特性

- 支持 stdio 和 HTTP 两种 MCP 传输协议
- 自动处理 MCP 初始化和工具发现
- 提供统一的 HTTP API 接口
- 支持工具名称前缀避免冲突
- 内置健康检查端点

## 快速开始

### 1. 编译运行

```bash
# 编译
go build -o mcp-bridge main.go

# 运行 (使用默认配置)
./mcp-bridge

# 或指定配置文件
MCP_CONFIG=./mcp.json ./mcp-bridge

# 或指定端口
BIND_PORT=7012 ./mcp-bridge
```

### 2. 配置文件

配置文件 `mcp.json` 定义了要聚合的 MCP 服务器：

```json
{
  "mcpServers": {
    "victoriametrics": {
      "command": "python3",
      "args": ["./vm-mcp-wrapper.py"],
      "env": {
        "VM_INSTANCE_ENTRYPOINT": "http://aps1-vm-internal-1.beta.tplinknbu.com/select/0/prometheus/"
      }
    },
    "cloudwatch": {
      "command": "python3", 
      "args": ["./cloudwatch-wrapper.py"],
      "env": {
        "AWS_DEFAULT_REGION": "ap-southeast-1"
      }
    },
    "elasticsearch": {
      "command": "python3",
      "args": ["./elasticsearch-wrapper.py"],
      "env": {}
    }
  }
}
```

#### 配置项说明

- `command`: 启动 MCP 服务器的命令
- `args`: 命令行参数数组
- `env`: 环境变量键值对
- `transportType`: 传输类型，支持 "stdio" (默认) 或 "http"
- `url`: HTTP 模式下的服务器 URL
- `headers`: HTTP 模式下的请求头
- `disabled`: 设为 true 可禁用该服务器

### 3. 环境变量

- `MCP_CONFIG`: 配置文件路径 (默认: ./mcp.json)
- `BIND_ADDR`: 绑定地址 (默认: 0.0.0.0)
- `BIND_PORT`: 绑定端口 (默认: 7011)
- `BACKEND_TIMEOUT`: 后端超时时间 (默认: 45s)
- `INIT_RETRY`: 初始化重试次数 (默认: 8)

## API 接口

### 健康检查

```bash
curl http://localhost:7011/healthz
```

响应：
```json
{
  "ok": true,
  "tools": 15,
  "ts": 1761201139
}
```

### 列出所有工具

```bash
curl -X POST http://localhost:7011/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}'
```

### 调用工具

```bash
# VictoriaMetrics 查询
curl -X POST http://localhost:7011/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":"1",
    "method":"tools/call",
    "params":{
      "name":"victoriametrics.query",
      "arguments":{"query":"up"}
    }
  }'

# CloudWatch 获取指标数据
curl -X POST http://localhost:7011/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":"1", 
    "method":"tools/call",
    "params":{
      "name":"cloudwatch.get_metric_data",
      "arguments":{
        "namespace":"AWS/EC2",
        "metric_name":"CPUUtilization",
        "start_time":"2023-01-01T00:00:00Z"
      }
    }
  }'

# Elasticsearch 搜索
curl -X POST http://localhost:7011/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":"1",
    "method":"tools/call", 
    "params":{
      "name":"elasticsearch.search",
      "arguments":{
        "index":"logs-*",
        "queryBody":{"query":{"match_all":{}}}
      }
    }
  }'
```

## 可用工具

当前聚合了 15 个工具：

### VictoriaMetrics (1个)
- `victoriametrics.query`: 执行 PromQL/MetricsQL 查询

### CloudWatch (10个)
- `cloudwatch.analyze_log_group`: 分析日志组异常和模式
- `cloudwatch.execute_log_insights_query`: 执行日志洞察查询
- `cloudwatch.cancel_logs_insight_query`: 取消日志洞察查询
- `cloudwatch.get_metric_metadata`: 获取指标元数据
- `cloudwatch.get_active_alarms`: 获取活跃告警
- `cloudwatch.describe_log_groups`: 描述日志组
- `cloudwatch.get_logs_insight_query_results`: 获取日志查询结果
- `cloudwatch.get_metric_data`: 获取指标数据
- `cloudwatch.get_recommended_metric_alarms`: 获取推荐告警配置
- `cloudwatch.get_alarm_history`: 获取告警历史

### Elasticsearch (4个)
- `elasticsearch.get_mappings`: 获取索引映射
- `elasticsearch.get_shards`: 获取分片信息
- `elasticsearch.list_indices`: 列出索引
- `elasticsearch.search`: 执行搜索查询

## 在 Q CLI 中使用

### 配置 Q CLI

创建或更新 `~/.config/q/mcp.json`:

```json
{
  "mcpServers": {
    "mcp-bridge": {
      "url": "http://localhost:7011/mcp",
      "transportType": "http"
    }
  }
}
```

### 在 Prompt 中调用

```
请帮我查询 VictoriaMetrics 中所有 up 指标的状态

请分析 CloudWatch 中 AWS/EC2 命名空间下的 CPUUtilization 指标

请搜索 Elasticsearch 中最近的错误日志
```

Q CLI 会自动识别并调用相应的 MCP 工具来完成任务。

## 故障排除

### 常见问题

1. **端口被占用**
   ```bash
   BIND_PORT=7012 ./mcp-bridge
   ```

2. **MCP 服务器初始化失败**
   - 检查 wrapper 脚本是否有执行权限
   - 确认依赖服务（如 Docker）正在运行
   - 查看日志输出了解具体错误

3. **工具调用超时**
   ```bash
   BACKEND_TIMEOUT=60s ./mcp-bridge
   ```

### 日志调试

MCP Bridge 会输出详细的日志信息，包括：
- 服务器启动状态
- 工具发现过程
- 错误信息和堆栈跟踪

## 架构说明

MCP Bridge 采用以下架构：

1. **配置加载**: 从 JSON 文件加载 MCP 服务器配置
2. **后端管理**: 为每个 MCP 服务器创建后端实例
3. **工具聚合**: 收集所有后端的工具并添加前缀
4. **HTTP 服务**: 提供统一的 HTTP API 接口
5. **请求路由**: 根据工具名称路由到对应的后端

这种设计确保了高可用性、可扩展性和易用性。
