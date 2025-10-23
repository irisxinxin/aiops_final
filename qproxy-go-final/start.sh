#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

: "${PORT:=8081}"
: "${QPROXY_DRY_RUN:=1}"
export QPROXY_DRY_RUN

echo "==> Starting qproxy on :$PORT"
exec ./bin/qproxy
