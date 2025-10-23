#!/usr/bin/env bash
set -euo pipefail

echo "🚀 开始重启 mcp-bridge 服务..."

# 配置
SERVICE_NAME="mcp-bridge"
PORT="7011"
WORK_DIR="/opt/mcp-bridge"
BIN_PATH="/usr/local/bin/mcp-bridge"

# 1. 停止 systemctl 服务
echo "📋 停止 systemctl 服务..."
sudo systemctl stop "$SERVICE_NAME" || true

# 2. 杀死所有相关进程
echo "💀 杀死旧进程..."

# 按端口杀死进程
if command -v lsof >/dev/null 2>&1; then
    local pids
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

# 3. 重新编译并安装
echo "🔨 重新编译并安装..."
cd "$(dirname "$0")"

# 确保工作目录存在
sudo mkdir -p "$WORK_DIR" /etc/mcp
sudo chown -R "$(whoami):$(whoami)" "$WORK_DIR"

# 复制文件到工作目录
install -m 0644 ./go.mod "$WORK_DIR/go.mod"
install -m 0644 ./main.go "$WORK_DIR/main.go"
install -m 0644 ./mcp.json "$WORK_DIR/mcp.json"

# 编译
cd "$WORK_DIR"
go build -o mcp-bridge .

# 安装到系统路径
sudo install -m 0755 mcp-bridge "$BIN_PATH"
sudo install -m 0644 "$WORK_DIR/mcp.json" /etc/mcp/mcp.json

# 更新环境配置
sudo tee /etc/default/mcp-bridge >/dev/null <<'ENV'
MCP_CONFIG=/etc/mcp/mcp.json
BIND_ADDR=127.0.0.1
BIND_PORT=7011
BACKEND_TIMEOUT=45s
INIT_RETRY=8
ENV

# 更新 systemd 服务文件
sudo tee /etc/systemd/system/mcp-bridge.service >/dev/null <<'UNIT'
[Unit]
Description=HTTP MCP Bridge (preheated MCP tools)
Wants=network-online.target
After=network-online.target docker.socket

[Service]
Type=simple
EnvironmentFile=-/etc/default/mcp-bridge
ExecStart=/usr/local/bin/mcp-bridge
Restart=on-failure
RestartSec=2s
User=root
Group=root
NoNewPrivileges=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

# 4. 重新加载 systemd 并启动服务
echo "🔄 重新加载 systemd 并启动服务..."
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl start "$SERVICE_NAME"

# 5. 等待服务启动
echo "⏳ 等待服务启动..."
sleep 3

# 6. 检查服务状态
echo "📊 服务状态:"
sudo systemctl status "$SERVICE_NAME" --no-pager || true

# 7. 健康检查
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
