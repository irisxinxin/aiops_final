#!/bin/bash

# MCP Bridge 启动脚本

echo "Starting MCP Bridge..."

# 检查端口是否被占用
if lsof -Pi :7011 -sTCP:LISTEN -t >/dev/null ; then
    echo "Port 7011 is already in use. Trying port 7012..."
    export BIND_PORT=7012
fi

# 启动MCP Bridge
./mcp-bridge
