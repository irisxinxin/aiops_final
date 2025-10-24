#!/usr/bin/env bash
set -euo pipefail

echo "Debug restart script..."

# 配置
SERVICE_NAME="mcp-bridge"
PORT="7011"
PROJECT_DIR="/home/ubuntu/huixin/aiops_final/mcp-bridge"
BIN_PATH="/usr/local/bin/mcp-bridge"

echo "Variables:"
echo "SERVICE_NAME=$SERVICE_NAME"
echo "PORT=$PORT"
echo "PROJECT_DIR=$PROJECT_DIR"
echo "BIN_PATH=$BIN_PATH"

echo "Creating systemd file with expanded variables:"
sudo tee /etc/systemd/system/mcp-bridge.service >/dev/null <<UNIT
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
UNIT

echo "Generated systemd file:"
cat /etc/systemd/system/mcp-bridge.service

echo "Testing systemd config:"
sudo systemctl daemon-reload
sudo systemctl show mcp-bridge.service --property=WorkingDirectory || true
