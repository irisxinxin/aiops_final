#!/usr/bin/env bash
set -euo pipefail

echo "🚀 开始重启 mcp-bridge 服务..."

# 配置
SERVICE_NAME="mcp-bridge"
PORT="7011"
PROJECT_DIR="/home/ubuntu/huixin/aiops_final/mcp-bridge"
BIN_PATH="/usr/local/bin/mcp-bridge"

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

# 按进程名杀死（排除当前脚本）
if pgrep -f "mcp-bridge" >/dev/null 2>&1; then
    echo "   杀死名为 mcp-bridge 的进程"
    # 排除当前脚本进程
    pids=$(pgrep -f "mcp-bridge" | grep -v $$ || true)
    if [ -n "$pids" ]; then
        echo "$pids" | xargs -r sudo kill -9 || true
    fi
fi

# 等待进程完全停止
sleep 2

# 3. 重新编译并安装
echo "🔨 重新编译并安装..."
cd "$(dirname "$0")"

# 确保项目目录存在
sudo mkdir -p "$PROJECT_DIR" /etc/mcp
sudo chown -R "$(whoami):$(whoami)" "$PROJECT_DIR"

# 如果不在项目目录，则复制文件
if [ "$(pwd)" != "$PROJECT_DIR" ]; then
    echo "   复制文件到项目目录..."
    install -m 0644 ./go.mod "$PROJECT_DIR/go.mod"
    install -m 0644 ./main.go "$PROJECT_DIR/main.go"
    install -m 0644 ./mcp.json "$PROJECT_DIR/mcp.json"
    
    # 复制wrapper脚本
    install -m 0755 ./vm-mcp-wrapper.py "$PROJECT_DIR/vm-mcp-wrapper.py"
    install -m 0755 ./cloudwatch-wrapper.py "$PROJECT_DIR/cloudwatch-wrapper.py"
    install -m 0755 ./elasticsearch-wrapper.py "$PROJECT_DIR/elasticsearch-wrapper.py"
    install -m 0755 ./stdio-wrapper.py "$PROJECT_DIR/stdio-wrapper.py"
    
    # 切换到项目目录
    cd "$PROJECT_DIR"
else
    echo "   已在项目目录，直接编译..."
fi

# 编译
go build -o mcp-bridge .

# 安装到系统路径
sudo install -m 0755 mcp-bridge "$BIN_PATH"
sudo install -m 0644 mcp.json /etc/mcp/mcp.json

# 更新环境配置
sudo tee /etc/default/mcp-bridge >/dev/null <<'ENV'
MCP_CONFIG=/etc/mcp/mcp.json
BIND_ADDR=127.0.0.1
BIND_PORT=7011
BACKEND_TIMEOUT=45s
INIT_RETRY=8
ENV

# 更新 systemd 服务文件
cat > /tmp/mcp-bridge.service <<EOF
[Unit]
Description=HTTP MCP Bridge (preheated MCP tools)
Wants=network-online.target
After=network-online.target docker.socket

[Service]
Type=simple
WorkingDirectory=$PROJECT_DIR
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
EOF

sudo cp /tmp/mcp-bridge.service /etc/systemd/system/mcp-bridge.service
rm /tmp/mcp-bridge.service

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
