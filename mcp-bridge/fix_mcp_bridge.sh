#!/usr/bin/env bash
set -euo pipefail

log(){ printf "\e[36m[fix]\e[0m %s\n" "$*"; }
die(){ printf "\e[31m[err]\e[0m %s\n" "$*" >&2; exit 1; }

# --- 0) 前置检查 ---
[[ $EUID -eq 0 ]] || die "请用 sudo 运行：sudo bash fix_mcp_bridge.sh"

MCP_ENV=/etc/default/mcp-bridge
MCP_JSON=/etc/mcp/mcp.json
SERVICE=mcp-bridge

[[ -f "$MCP_JSON" ]] || die "未找到 $MCP_JSON，请先安装 mcp-bridge"

# --- 1) 安装 uvx (若缺失) 并准备 PATH ---
if ! command -v uvx >/dev/null 2>&1; then
  log "未发现 uvx，开始安装 uv ..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
else
  log "已检测到 uvx：$(command -v uvx)"
fi

# 统一给 systemd 注入 PATH（包含 root 与 ubuntu 常见路径）
PATH_LINE='PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/root/.local/bin:/home/ubuntu/.local/bin'
log "写入/更新 $MCP_ENV"
mkdir -p "$(dirname "$MCP_ENV")"
touch "$MCP_ENV"
# 覆盖/追加关键项（幂等）
grep -q '^PATH=' "$MCP_ENV" && sed -i "s|^PATH=.*|$PATH_LINE|" "$MCP_ENV" || echo "$PATH_LINE" >> "$MCP_ENV"
grep -q '^BACKEND_TIMEOUT=' "$MCP_ENV" && sed -i "s|^BACKEND_TIMEOUT=.*|BACKEND_TIMEOUT=180s|" "$MCP_ENV" || echo "BACKEND_TIMEOUT=180s" >> "$MCP_ENV"
grep -q '^INIT_RETRY=' "$MCP_ENV" && sed -i "s|^INIT_RETRY=.*|INIT_RETRY=12|" "$MCP_ENV" || echo "INIT_RETRY=12" >> "$MCP_ENV"

# --- 2) 修改 /etc/mcp/mcp.json：给需要内网的容器加 --network=host ---
# 用 python 可靠改 JSON（避免 sed 破坏结构）
log "备份并修改 $MCP_JSON 以添加 --network=host（elasticsearch / victoriametrics）"
cp -a "$MCP_JSON" "${MCP_JSON}.bak.$(date +%F-%H%M%S)"

python3 - "$MCP_JSON" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, 'r', encoding='utf-8') as f:
    data = json.load(f)

def add_host_net(name: str):
    srv = data.get('mcpServers', {}).get(name)
    if not srv: 
        return
    args = srv.get('args')
    if not isinstance(args, list):
        return
    if '--network=host' in args:
        return
    #插在 '--rm' 之后；若不存在，则尽量靠前
    idx = 0
    try:
        idx = args.index('--rm') + 1
    except ValueError:
        try:
            idx = args.index('run') + 1
        except ValueError:
            idx = 0
    args[idx:idx] = ['--network=host']
    srv['args'] = args

for key in ('elasticsearch-mcp-server', 'victoriametrics'):
    add_host_net(key)

with open(p, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

# --- 3) 预拉常用镜像（加速初始化；若失败不影响执行） ---
if command -v docker >/dev/null 2>&1; then
  log "预拉相关镜像（若已存在会跳过）..."
  docker pull docker.elastic.co/mcp/elasticsearch:0.3.1 || true
  docker pull ghcr.io/victoriametrics-community/mcp-victoriametrics || true
  docker pull ghcr.io/kaznak/alertmanager-mcp:latest || true
else
  log "未检测到 docker，跳过预拉镜像"
fi

# --- 4) 重载并重启服务 ---
log "重启 $SERVICE"
systemctl daemon-reload
systemctl restart "$SERVICE"

# --- 5) 自检：健康检查 & 列工具 ---
log "等待服务就绪 ..."
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
  systemctl status "$SERVICE" --no-pager || true
  die "服务未处于 active 状态，请查看日志：journalctl -u $SERVICE -n 200 --no-pager"
fi

HEALTH=$(curl -fsS http://127.0.0.1:7011/healthz || true)
log "healthz: ${HEALTH:-<请求失败>}"

log "尝试调用 tools/list（MCP JSON-RPC）..."
curl -fsS -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  http://127.0.0.1:7011/mcp || true

log "完成 ✅ 如仍有初始化超时，请执行：journalctl -u $SERVICE -n 200 --no-pager"
