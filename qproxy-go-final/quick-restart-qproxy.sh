#!/bin/bash

# qproxy 快速重启脚本
# 功能：只停止旧进程，启动新进程（不重新编译）

set -e

PROJECT_DIR="/home/ubuntu/huixin/aiops_final/qproxy-go-final"
SERVICE_NAME="qproxy"
PORT="8080"

echo "🚀 开始快速重启 $SERVICE_NAME 服务..."

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

# 检查二进制文件是否存在
if [ ! -f "bin/qproxy" ]; then
    echo "❌ 二进制文件不存在，请先运行 restart-qproxy.sh"
    exit 1
fi

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
else
    echo "❌ $SERVICE_NAME 服务启动失败"
    echo "📋 查看日志:"
    tail -20 server.log
    exit 1
fi

echo "🎉 $SERVICE_NAME 快速重启完成！"
