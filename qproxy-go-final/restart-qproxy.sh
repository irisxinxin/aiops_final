#!/bin/bash

# qproxy 重启脚本
# 功能：停止旧进程，重新编译，启动新进程

set -e

PROJECT_DIR="/home/ubuntu/huixin/aiops_final/qproxy-go-final"
SERVICE_NAME="qproxy"
PORT="8080"

echo "🚀 开始重启 $SERVICE_NAME 服务..."

# 检查是否在正确的目录
if [ "$(pwd)" != "$PROJECT_DIR" ]; then
    echo "📁 切换到项目目录: $PROJECT_DIR"
    cd "$PROJECT_DIR"
fi

# 停止旧进程
echo "💀 停止旧进程..."
# 杀死监听端口的进程
pids=$(lsof -ti tcp:"$PORT" 2>/dev/null || true)
if [ -n "$pids" ]; then
    echo "    杀死监听端口 $PORT 的进程: $pids"
    echo "$pids" | xargs -r sudo kill -9 || true
fi

# 杀死名为 qproxy 的进程（排除当前脚本）
pids=$(pgrep -f "qproxy" | grep -v $$ || true)
if [ -n "$pids" ]; then
    echo "    杀死名为 $SERVICE_NAME 的进程: $pids"
    echo "$pids" | xargs -r sudo kill -9 || true
fi

# 等待进程完全停止
sleep 2

# 重新编译
echo "🔨 重新编译..."
go build -o bin/qproxy cmd/qproxy/main.go
if [ $? -ne 0 ]; then
    echo "❌ 编译失败"
    exit 1
fi

# 设置执行权限
chmod +x bin/qproxy

# 启动新进程
echo "🔄 启动新进程..."
nohup ./bin/qproxy > server.log 2>&1 &
echo $! > qproxy.pid

# 等待服务启动
sleep 3

# 检查服务是否正常启动
if curl -s http://127.0.0.1:$PORT/healthz > /dev/null; then
    echo "✅ $SERVICE_NAME 服务启动成功"
    echo "📊 服务状态:"
    echo "   - PID: $(cat qproxy.pid)"
    echo "   - 端口: $PORT"
    echo "   - 日志: $PROJECT_DIR/server.log"
    echo "   - 健康检查: http://127.0.0.1:$PORT/healthz"
else
    echo "❌ $SERVICE_NAME 服务启动失败"
    echo "📋 查看日志:"
    tail -20 server.log
    exit 1
fi

echo "🎉 $SERVICE_NAME 重启完成！"
