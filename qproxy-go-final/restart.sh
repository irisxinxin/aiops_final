#!/usr/bin/env bash
set -euo pipefail

PORT=${PORT:-8081}
SERVICE=${SERVICE:-qproxy}
BIN_DIR=$(cd "$(dirname "$0")" && pwd)/bin

kill_by_port() {
  local p=$1
  if command -v lsof >/dev/null 2>&1; then
    local pids
    pids=$(lsof -ti tcp:"$p" || true)
    if [ -n "$pids" ]; then
      echo "Killing processes on port $p: $pids"
      kill -9 $pids || true
    fi
  fi
}

kill_by_name() {
  local name=$1
  if pgrep -f "$name" >/dev/null 2>&1; then
    echo "Killing processes named $name"
    pkill -9 -f "$name" || true
  fi
}

if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl stop "$SERVICE" || true
fi

kill_by_port "$PORT"
kill_by_name "$BIN_DIR/qproxy"

if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl start "$SERVICE"
  sudo systemctl status "$SERVICE" --no-pager || true
else
  echo "Starting locally on port $PORT (DRY_RUN=${QPROXY_DRY_RUN:-0})"
  (cd "$BIN_DIR/.." && PORT="$PORT" nohup ./bin/qproxy >server.log 2>&1 & echo $! > qproxy.pid)
fi

echo "Health:"
curl -sS http://127.0.0.1:"$PORT"/healthz || true
