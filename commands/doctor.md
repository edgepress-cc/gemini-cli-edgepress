---
description: Health check — verifies env vars, tenant reachability, PAT validity, OpenAPI spec fetchability, `ep` on PATH, `jq` available.
---

Run through these checks in order; print pass/fail per line. Stop at the first failure and show remediation.

1. `EDGEPRESS_TENANT` set (else: /edgepress:setup)
2. `EDGEPRESS_TOKEN` set (else: /edgepress:setup)
3. `ep --endpoint GET /users/me` (script installed and env-var construction works)
4. `ep GET /users/me` returns 200 (else: PAT invalid — /edgepress:setup)
5. `curl -sf https://api-docs.edgepress.cc/openapi.json > /dev/null` (docs site reachable)
6. `command -v jq` (nice-to-have; skill still works without it, output just less pretty)

End with a one-line summary + extension version from `gemini-extension.json`.
