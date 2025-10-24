# qproxy 远程部署指南

## 服务重启脚本

### 1. 完整重启脚本 (`restart-qproxy.sh`)
```bash
./restart-qproxy.sh
```
**功能**：
- 停止旧进程
- 重新编译
- 启动新进程
- 健康检查

### 2. 快速重启脚本 (`quick-restart-qproxy.sh`)
```bash
./quick-restart-qproxy.sh
```
**功能**：
- 只停止旧进程
- 启动新进程（不重新编译）
- 健康检查

## 远程部署步骤

### 1. 上传代码到远程服务器
```bash
# 在本地执行
git add .
git commit -m "优化qproxy: 修复sop_id匹配和工作目录设置"
git push origin main
```

### 2. 在远程服务器上拉取代码
```bash
# 在远程服务器执行
cd /home/ubuntu/huixin/aiops_final/qproxy-go-final
git pull origin main
```

### 3. 重启服务
```bash
# 完整重启（推荐）
./restart-qproxy.sh

# 或者快速重启（如果代码没有变化）
./quick-restart-qproxy.sh
```

## 服务管理

### 检查服务状态
```bash
# 健康检查
curl http://127.0.0.1:8080/healthz

# 查看进程
ps aux | grep qproxy

# 查看日志
tail -f server.log
```

### 停止服务
```bash
# 方法1：使用PID文件
kill $(cat qproxy.pid)

# 方法2：杀死所有qproxy进程
pkill -f qproxy

# 方法3：杀死监听端口的进程
lsof -ti tcp:8080 | xargs kill -9
```

## 配置说明

- **工作目录**: `/home/ubuntu/huixin/aiops_final/qproxy-go-final`
- **服务端口**: `8080`
- **日志文件**: `server.log`
- **PID文件**: `qproxy.pid`
- **SOP目录**: `sops/`
- **会话目录**: `q-sessions/`

## 测试接口

### 健康检查
```bash
curl http://127.0.0.1:8080/healthz
```

### 测试告警处理
```bash
curl -X POST http://127.0.0.1:8080/ask_json?dry=1 \
  -H 'Content-Type: application/json' \
  -d '{
    "alert": {
      "status": "firing",
      "env": "dev",
      "region": "dev-nbu-aps1",
      "service": "sdn5",
      "category": "cpu",
      "severity": "critical",
      "title": "sdn5 container CPU usage is too high",
      "group_id": "sdn5_critical",
      "window": "5m",
      "threshold": 0.9,
      "metadata": {
        "current_value": 0.92
      }
    }
  }'
```

## 故障排除

### 1. 编译失败
- 检查Go环境：`go version`
- 检查依赖：`go mod tidy`

### 2. 服务启动失败
- 检查端口占用：`lsof -i :8080`
- 查看日志：`tail -20 server.log`

### 3. SOP加载失败
- 检查SOP文件：`ls -la sops/`
- 检查文件权限：`ls -la sops/sop_*.json`

### 4. 工作目录问题
- 检查会话目录：`ls -la q-sessions/`
- 检查目录权限：`ls -la q-sessions/sop_*/`
