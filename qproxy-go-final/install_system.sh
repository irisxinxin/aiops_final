#!/usr/bin/env bash
set -euo pipefail

WORK=${WORK:-/opt/qproxy}
SRC_DIR=$(cd "$(dirname "$0")" && pwd)

sudo mkdir -p "$WORK/bin" "$WORK/sops" "$WORK/config" "$WORK/q-sessions"
sudo chown -R "$USER":"$USER" "$WORK"

# install binary and configs
install -m 0755 "$SRC_DIR/bin/qproxy" "$WORK/bin/qproxy"
install -m 0644 "$SRC_DIR/config/config.json" "$WORK/config/config.json"
install -m 0644 "$SRC_DIR/sops"/*.json "$WORK/sops/" || true

# systemd unit and env
sudo install -m 0644 "$SRC_DIR/system/qproxy.service" /etc/systemd/system/qproxy.service
sudo install -m 0644 "$SRC_DIR/system/qproxy.env" /etc/default/qproxy

sudo systemctl daemon-reload
sudo systemctl enable --now qproxy
sudo systemctl status qproxy --no-pager
