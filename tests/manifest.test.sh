#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

test -f gemini-extension.json || { echo "missing gemini-extension.json"; exit 1; }
test -f SKILL.md || exit 1
test -f GEMINI.md || exit 1
test -x scripts/ep || exit 1
test $(ls references/*.md | wc -l) -eq 9 || exit 1
test $(ls commands/*.md | wc -l) -eq 5 || exit 1
jq -e '.name == "edgepress" and .version == "0.1.0"' gemini-extension.json > /dev/null || exit 1
echo "manifest OK"
