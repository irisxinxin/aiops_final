#!/usr/bin/env bash
set -euo pipefail

log(){ printf "\e[36m[fix]\e[0m %s\n" "$*"; }
warn(){ printf "\e[33m[warn]\e[0m %s\n" "$*"; }
die(){ printf "\e[31m[err]\e[0m %s\n" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 sudo 运行：sudo bash fix_mcp_bridge_v2.sh"

SERVICE=mcp-bridge
MCP_ENV=/etc/default/mcp-bridge
MCP_JSON=/etc/mcp/mcp.json
BIND_ADDR=127.0.0.1
BIND_PORT=7011

[[ -f "$MCP_JSON" ]] || die "未找到 $MCP_JSON，请先安装 mcp-bridge"

# 1) uvx（若缺）
if ! command -v uvx >/dev/null 2>&1; then
  log "未发现 uvx，开始安装 uv ..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
else
  log "已检测到 uvx：$(command -v uvx)"
fi

# 2) 写入 /etc/default/mcp-bridge：PATH / 超时 / AWS 区域
mkdir -p "$(dirname "$MCP_ENV")"; touch "$MCP_ENV"
PATH_LINE='PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/root/.local/bin:/home/ubuntu/.local/bin'
grep -q '^PATH=' "$MCP_ENV" && sed -i "s|^PATH=.*|$PATH_LINE|" "$MCP_ENV" || echo "$PATH_LINE" >> "$MCP_ENV"
grep -q '^BACKEND_TIMEOUT=' "$MCP_ENV" && sed -i 's|^BACKEND_TIMEOUT=.*|BACKEND_TIMEOUT=300s|' "$MCP_ENV" || echo 'BACKEND_TIMEOUT=300s' >> "$MCP_ENV"
grep -q '^INIT_RETRY=' "$MCP_ENV" && sed -i 's|^INIT_RETRY=.*|INIT_RETRY=20|' "$MCP_ENV" || echo 'INIT_RETRY=20' >> "$MCP_ENV"

detect_region(){
  local r=""
  # EC2 元数据优先
  if command -v curl >/dev/null 2>&1; then
    r=$(curl -s --max-time 1 http://169.254.169.254/latest/dynamic/instance-identity/document \
        | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') || true
  fi
  # 本机 aws cli 配置
  if [[ -z "$r" ]] && command -v aws >/dev/null 2>&1; then
    r=$(aws configure get region 2>/dev/null || true)
  fi
  # 兜底
  [[ -z "$r" ]] && r="ap-southeast-1"
  echo "$r"
}
REGION=$(detect_region)
log "设置 AWS 区域：$REGION"
grep -q '^AWS_REGION=' "$MCP_ENV" && sed -i "s|^AWS_REGION=.*|AWS_REGION=$REGION|" "$MCP_ENV" || echo "AWS_REGION=$REGION" >> "$MCP_ENV"
grep -q '^AWS_DEFAULT_REGION=' "$MCP_ENV" && sed -i "s|^AWS_DEFAULT_REGION=.*|AWS_DEFAULT_REGION=$REGION|" "$MCP_ENV" || echo "AWS_DEFAULT_REGION=$REGION" >> "$MCP_ENV"

# 3) 修改 /etc/mcp/mcp.json：确保 docker backends 均有 --network=host
cp -a "$MCP_JSON" "${MCP_JSON}.bak.$(date +%F-%H%M%S)"
python3 - "$MCP_JSON" <<'PY'
import json, sys
p=sys.argv[1]
with open(p,'r',encoding='utf-8') as f: data=json.load(f)

def add_host_net(name):
    s=data.get('mcpServers',{}).get(name)
    if not s: return
    a=s.get('args')
    if not isinstance(a,list): return
    if '--network=host' in a: return
    try: idx=a.index('--rm')+1
    except ValueError:
        try: idx=a.index('run')+1
        except ValueError: idx=0
    a[idx:idx]=['--network=host']
    s['args']=a

for key in ('elasticsearch-mcp-server','victoriametrics','alertmanager'):
    add_host_net(key)

with open(p,'w',encoding='utf-8') as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
PY

# 4) 重启服务
log "重启 $SERVICE"
systemctl daemon-reload
systemctl restart "$SERVICE"

# 5) 等待监听端口就绪（最多 90 秒）
log "等待 $BIND_ADDR:$BIND_PORT 就绪 ..."
for i in $(seq 1 90); do
  if curl -fsS "http://$BIND_ADDR:$BIND_PORT/healthz" >/dev/null 2>&1; then
    READY=1; break
  fi
  sleep 1
done
if [[ "${READY:-0}" -ne 1 ]]; then
  warn "健康检查暂未成功，打印最近日志："
  journalctl -u "$SERVICE" -n 200 --no-pager || true
  die "bridge 未在 ${BIND_ADDR}:${BIND_PORT} 就绪，请根据上面日志定位（多为后端初始化慢/网络不通/凭据缺失）"
fi

# 6) 自检输出
log "healthz:"
curl -fsS "http://$BIND_ADDR:$BIND_PORT/healthz" || true
echo
log "tools/list:"
curl -fsS -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  "http://$BIND_ADDR:$BIND_PORT/mcp" || true
echo
log "完成 ✅"
