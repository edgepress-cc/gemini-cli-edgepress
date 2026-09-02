#!/usr/bin/env bash
# Refresh vendored OpenAPI snapshot from live api-docs.
set -euo pipefail
curl -fsSL https://api-docs.edgepress.cc/openapi.json -o "$(dirname "$0")/../openapi.snapshot.json"
echo "openapi.snapshot.json updated ($(wc -c < "$(dirname "$0")/../openapi.snapshot.json") bytes)"
