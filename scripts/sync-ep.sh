#!/usr/bin/env bash
# Refresh vendored `ep` from gemini-cli-edgepress main.
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/edgepress-cc/gemini-cli-edgepress/main/scripts/ep -o "$(dirname "$0")/ep"
chmod +x "$(dirname "$0")/ep"
echo "ep updated ($(wc -c < "$(dirname "$0")/ep") bytes)"
