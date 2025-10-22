#!/usr/bin/env bash
set -euo pipefail
WORK=${WORK:-/opt/mcp-bridge}
sudo mkdir -p "$WORK/systemd" /etc/mcp
sudo chown -R "$USER":"$USER" "$WORK"

install -m 0644 ./go.mod "$WORK/go.mod"
install -m 0644 ./main.go "$WORK/main.go"
install -m 0644 ./mcp.json "$WORK/mcp.json"

cd "$WORK"
go build -o mcp-bridge .
sudo install -m 0755 mcp-bridge /usr/local/bin/mcp-bridge
sudo install -m 0644 "$WORK/mcp.json" /etc/mcp/mcp.json

sudo tee /etc/default/mcp-bridge >/dev/null <<'ENV'
MCP_CONFIG=/etc/mcp/mcp.json
BIND_ADDR=127.0.0.1
BIND_PORT=7011
BACKEND_TIMEOUT=45s
INIT_RETRY=8
ENV

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

sudo systemctl daemon-reload
sudo systemctl enable --now mcp-bridge
sudo systemctl status mcp-bridge --no-pager
