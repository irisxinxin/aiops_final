#!/bin/bash

echo "=== MCP Bridge 修复脚本 ==="

# 1. 检查服务状态
echo "1. 检查当前服务状态..."
systemctl status mcp-bridge --no-pager

# 2. 修复VictoriaMetrics配置
echo "2. 修复VictoriaMetrics配置..."

# 备份原配置
sudo cp /etc/mcp/mcp.json /etc/mcp/mcp.json.backup.$(date +%Y%m%d_%H%M%S)

# 修复VM_INSTANCE_TYPE
sudo sed -i 's/VM_INSTANCE_TYPE=prometheus/VM_INSTANCE_TYPE=cluster/g' /etc/mcp/mcp.json

# 添加网络参数
sudo sed -i 's/"run","-i","--rm",/"run","-i","--rm","--network=host",/g' /etc/mcp/mcp.json

# 3. 重启服务
echo "3. 重启MCP Bridge服务..."
sudo systemctl restart mcp-bridge

# 4. 等待服务启动
echo "4. 等待服务启动..."
sleep 15

# 5. 检查服务状态
echo "5. 检查服务状态..."
systemctl status mcp-bridge --no-pager

# 6. 测试健康检查
echo "6. 测试健康检查..."
echo "健康检查端点: http://127.0.0.1:7011/healthz"
curl -s http://127.0.0.1:7011/healthz | jq . || echo "健康检查失败"

# 7. 检查日志
echo "7. 最近的服务日志:"
journalctl -u mcp-bridge --since "1 minute ago" --no-pager

echo "=== 修复完成 ==="
echo "如果VictoriaMetrics仍有问题，可以临时禁用它："
echo "sudo sed -i 's/\"victoriametrics\": {/\"victoriametrics\": {\\n      \"disabled\": true,/g' /etc/mcp/mcp.json"
echo "sudo systemctl restart mcp-bridge"
