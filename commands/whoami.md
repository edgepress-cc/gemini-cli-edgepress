---
description: Verify EdgePress auth — fetches /api/v1/users/me and prints tenant, user, role, and token mode.
---

Run `ep GET /users/me` and print a single friendly line:
`Connected to <tenant> as <email> (<role>, <full-access|read-only> token). Rate limit: 60 req/min.`

On HTTP 401: point the user to `/edgepress:setup`.
On unreachable (curl fails / DNS): print the failing URL + error and suggest checking `EDGEPRESS_TENANT`.
