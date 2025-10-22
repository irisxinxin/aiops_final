#!/usr/bin/env bash
set -euo pipefail
q chat --agent aiops --no-interactive --resume --trust-all-tools "$@"
