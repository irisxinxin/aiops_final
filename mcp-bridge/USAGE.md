# MCP Bridge 使用指南

## 配置说明

### 1. MCP Bridge 配置 (mcp.json)

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

**配置项含义：**
- `mcpServers`: 定义所有MCP服务器的配置
- `command`: 启动MCP服务器的命令（如python3, docker等）
- `args`: 命令行参数数组
- `env`: 环境变量，用于配置各个服务的连接信息
- `transportType`: 传输协议类型（stdio/http），默认stdio
- `disabled`: 是否禁用该服务器

### 2. Q CLI 配置 (q-mcp-config.json)

将此文件复制到 `~/.config/q/mcp.json`:

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

**配置项含义：**
- `mcp-bridge`: MCP服务器名称（可自定义）
- `url`: MCP Bridge的HTTP API地址
- `transportType`: 必须设为"http"

## 启动步骤

### 1. 启动 MCP Bridge

```bash
cd /home/ubuntu/huixin/aiops_final/mcp-bridge

# 方式1: 使用默认端口7011
./mcp-bridge

# 方式2: 指定端口
BIND_PORT=7012 ./mcp-bridge

# 方式3: 指定配置文件
MCP_CONFIG=./mcp.json ./mcp-bridge
```

### 2. 配置 Q CLI

```bash
# 复制配置文件到Q CLI配置目录
cp q-mcp-config.json ~/.config/q/mcp.json

# 或者手动创建配置文件
mkdir -p ~/.config/q
cat > ~/.config/q/mcp.json << 'EOF'
{
  "mcpServers": {
    "mcp-bridge": {
      "url": "http://localhost:7011/mcp",
      "transportType": "http"
    }
  }
}
EOF
```

### 3. 验证连接

```bash
# 检查MCP Bridge健康状态
curl http://localhost:7011/healthz

# 列出所有可用工具
curl -X POST http://localhost:7011/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}'
```

## 在 Q CLI 中使用

### VictoriaMetrics 查询示例

```
请帮我查询VictoriaMetrics中所有up指标的状态

请查询过去1小时内CPU使用率超过80%的服务器

请分析内存使用情况的趋势
```

### CloudWatch 监控示例

```
请获取AWS EC2实例的CPU利用率数据

请分析CloudWatch中的活跃告警

请查询过去24小时的日志组异常情况

请获取RDS数据库的性能指标
```

### Elasticsearch 日志分析示例

```
请搜索Elasticsearch中包含"error"的日志

请列出所有可用的日志索引

请分析最近1小时的错误日志模式

请查询特定时间范围内的应用日志
```

## 工具列表

### VictoriaMetrics (1个工具)
- `victoriametrics.query`: 执行PromQL/MetricsQL查询

### CloudWatch (10个工具)
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

### Elasticsearch (4个工具)
- `elasticsearch.get_mappings`: 获取索引映射
- `elasticsearch.get_shards`: 获取分片信息
- `elasticsearch.list_indices`: 列出索引
- `elasticsearch.search`: 执行搜索查询

## 常用Prompt模板

### 监控查询类
```
请查询[服务名]的[指标名称]在过去[时间范围]内的数据
请分析[系统/服务]的性能趋势
请检查是否有任何活跃的告警
```

### 日志分析类
```
请搜索包含"[关键词]"的日志
请分析过去[时间范围]内的错误日志
请查找[应用名称]的异常日志模式
```

### 故障排查类
```
请帮我排查[服务名称]的性能问题
请分析[时间范围]内的系统异常
请检查[服务]的健康状态和相关告警
```

## 故障排除

### 1. MCP Bridge无法启动
- 检查端口是否被占用：`netstat -tlnp | grep 7011`
- 检查Python依赖：`pip install requests`
- 查看详细错误日志

### 2. Q CLI无法连接
- 确认MCP Bridge正在运行：`curl http://localhost:7011/healthz`
- 检查Q CLI配置文件路径：`~/.config/q/mcp.json`
- 验证配置文件格式是否正确

### 3. 工具调用失败
- 检查对应服务的连接配置（如VictoriaMetrics URL、AWS凭证等）
- 查看MCP Bridge日志输出
- 确认网络连接正常

### 4. 权限问题
```bash
# 确保wrapper脚本有执行权限
chmod +x *.py

# 检查AWS凭证配置
aws configure list

# 检查Docker是否运行
docker ps
```
