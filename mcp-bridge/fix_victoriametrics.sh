#!/bin/bash

echo "=== VictoriaMetrics MCP 修复脚本 ==="

# 1. 测试VictoriaMetrics端点连接
echo "1. 测试VictoriaMetrics端点连接..."
if curl -s -o /dev/null -w "%{http_code}" http://aps1-vm-internal-1.beta.tplinknbu.com/select/0/prometheus/api/v1/query?query=up | grep -q "200"; then
    echo "✓ VictoriaMetrics端点可访问"
else
    echo "✗ VictoriaMetrics端点不可访问"
    exit 1
fi

# 2. 测试VictoriaMetrics MCP容器
echo "2. 测试VictoriaMetrics MCP容器..."
VM_TEST=$(echo -e 'Content-Length: 52\r\n\r\n{"jsonrpc":"2.0","id":"1","method":"initialize","params":{}}' | \
    timeout 10 docker run -i --rm --network=host \
    -e VM_INSTANCE_ENTRYPOINT=http://aps1-vm-internal-1.beta.tplinknbu.com/select/0/prometheus/ \
    -e VM_INSTANCE_TYPE=cluster \
    ghcr.io/victoriametrics-community/mcp-victoriametrics:latest stdio 2>/dev/null)

if echo "$VM_TEST" | grep -q '"result"'; then
    echo "✓ VictoriaMetrics MCP容器工作正常"
else
    echo "✗ VictoriaMetrics MCP容器测试失败"
    echo "输出: $VM_TEST"
    exit 1
fi

# 3. 启用VictoriaMetrics
echo "3. 启用VictoriaMetrics..."
sudo sed -i '/disabled.*true/d' /etc/mcp/mcp.json

# 4. 增加超时时间
echo "4. 增加初始化超时时间..."
if ! grep -q "INIT_RETRY" /etc/systemd/system/mcp-bridge.service.d/override.conf; then
    sudo mkdir -p /etc/systemd/system/mcp-bridge.service.d/
    echo "[Service]" | sudo tee -a /etc/systemd/system/mcp-bridge.service.d/override.conf
    echo "Environment=INIT_RETRY=15" | sudo tee -a /etc/systemd/system/mcp-bridge.service.d/override.conf
    echo "Environment=BACKEND_TIMEOUT=120s" | sudo tee -a /etc/systemd/system/mcp-bridge.service.d/override.conf
    sudo systemctl daemon-reload
fi

# 5. 重启服务
echo "5. 重启MCP Bridge服务..."
sudo systemctl restart mcp-bridge

# 6. 等待初始化
echo "6. 等待服务初始化（最多2分钟）..."
for i in {1..24}; do
    sleep 5
    if curl -s http://127.0.0.1:7011/healthz | jq -e '.tools > 0' >/dev/null 2>&1; then
        echo "✓ VictoriaMetrics初始化成功！"
        curl -s http://127.0.0.1:7011/healthz | jq .
        exit 0
    fi
    echo "等待中... ($((i*5))s)"
done

# 7. 如果失败，显示日志并回退
echo "✗ VictoriaMetrics初始化超时"
echo "最近的日志:"
journalctl -u mcp-bridge --since "2 minutes ago" --no-pager

echo "回退到禁用VictoriaMetrics..."
sudo sed -i 's/"victoriametrics": {/"victoriametrics": {\n      "disabled": true,/g' /etc/mcp/mcp.json
sudo systemctl restart mcp-bridge

echo "服务已回退到稳定状态"
curl -s http://127.0.0.1:7011/healthz | jq .
