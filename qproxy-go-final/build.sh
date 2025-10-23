#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
echo "==> Building qproxy (Go 1.22+)"
go build -o bin/qproxy ./cmd/qproxy
echo "Built: bin/qproxy"
