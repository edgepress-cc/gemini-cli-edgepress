---
description: Fetch the latest OpenAPI spec from api-docs.edgepress.cc and cache it locally so this session's skill guidance is current.
---

Run:
```
curl -sf https://api-docs.edgepress.cc/openapi.json > /tmp/edgepress-spec.json
jq '.info | {title, version}' /tmp/edgepress-spec.json
echo "Endpoint count: $(jq '[.paths | to_entries[].value | keys[]] | length' /tmp/edgepress-spec.json)"
```

Print the results. On upstream failure: print the URL + status and stop.
