#!/usr/bin/env bash
set -euo pipefail

echo "🚀 快速重启 mcp-bridge 服务..."

SERVICE_NAME="mcp-bridge"
PORT="7011"

# 1. 停止 systemctl 服务
echo "📋 停止 systemctl 服务..."
sudo systemctl stop "$SERVICE_NAME" || true

# 2. 杀死所有相关进程
echo "💀 杀死旧进程..."

# 按端口杀死进程
if command -v lsof >/dev/null 2>&1; then
    pids=$(lsof -ti tcp:"$PORT" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo "   杀死端口 $PORT 上的进程: $pids"
        echo "$pids" | xargs -r sudo kill -9 || true
    fi
fi

# 按进程名杀死
if pgrep -f "mcp-bridge" >/dev/null 2>&1; then
    echo "   杀死名为 mcp-bridge 的进程"
    sudo pkill -9 -f "mcp-bridge" || true
fi

# 等待进程完全停止
sleep 2

# 3. 重新加载 systemd 并启动服务
echo "🔄 重新加载 systemd 并启动服务..."
sudo systemctl daemon-reload
sudo systemctl start "$SERVICE_NAME"

# 4. 等待服务启动
echo "⏳ 等待服务启动..."
sleep 3

# 5. 检查服务状态
echo "📊 服务状态:"
sudo systemctl status "$SERVICE_NAME" --no-pager || true

# 6. 健康检查
echo "🏥 健康检查:"
if curl -sS http://127.0.0.1:"$PORT"/healthz >/dev/null 2>&1; then
    echo "✅ mcp-bridge 服务运行正常！"
    curl -sS http://127.0.0.1:"$PORT"/healthz | jq . 2>/dev/null || curl -sS http://127.0.0.1:"$PORT"/healthz
else
    echo "❌ mcp-bridge 服务健康检查失败！"
    echo "📋 查看日志:"
    sudo journalctl -u "$SERVICE_NAME" --no-pager -n 20
    exit 1
fi

echo "🎉 mcp-bridge 服务重启完成！"
