#!/bin/bash

# Fix MCP bridge timeout issue
echo "Fixing MCP bridge timeout issue..."

# Stop the service
sudo systemctl stop mcp-bridge

# Clean up any hanging docker containers
docker ps -q --filter ancestor=ghcr.io/victoriametrics-community/mcp-victoriametrics:latest | xargs -r docker kill

# Create a working configuration with shorter timeout
cat > /tmp/mcp-working.json << 'EOF'
{
  "mcpServers": {
    "victoriametrics": {
      "command": "docker",
      "args": [
        "run",
        "-i",
        "--rm",
        "--network=host",
        "-e",
        "VM_INSTANCE_ENTRYPOINT",
        "-e", 
        "VM_INSTANCE_TYPE",
        "ghcr.io/victoriametrics-community/mcp-victoriametrics:latest",
        "stdio"
      ],
      "env": {
        "VM_INSTANCE_ENTRYPOINT": "http://aps1-vm-internal-1.beta.tplinknbu.com/select/0/prometheus/",
        "VM_INSTANCE_TYPE": "cluster"
      }
    }
  }
}
EOF

# Copy to system location
sudo cp /tmp/mcp-working.json /etc/mcp/mcp.json

# Update environment to use shorter timeout
sudo tee /etc/systemd/system/mcp-bridge.service.d/timeout.conf > /dev/null << 'EOF'
[Service]
Environment="BACKEND_TIMEOUT=10s"
Environment="INIT_RETRY=3"
EOF

# Reload systemd and restart
sudo systemctl daemon-reload
sudo systemctl start mcp-bridge

# Wait a moment and check status
sleep 5
systemctl status mcp-bridge --no-pager
