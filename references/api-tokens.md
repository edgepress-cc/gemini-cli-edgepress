# API tokens

Personal access tokens (PATs, `epat_...`). The plugin can LIST tokens for an
audit, and that is all: creating and revoking tokens is session-only.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/api-tokens` | List tokens — works with a PAT |
| POST | `/api-tokens` | Create — **403 `session_required` via PAT** |
| DELETE | `/api-tokens/{id}` | Revoke — **403 `session_required` via PAT** |

## Common bodies

Audit the tenant's tokens (the only call the plugin can make here):

```bash
ep GET /api-tokens
```

Find stale tokens worth flagging:

```bash
ep --raw GET /api-tokens | jq '.[] | select(.revoked == false and .lastUsedAt == null)'
```

## Response shape

```json
[
  {
    "id": 4,
    "name": "ci-deploy",
    "prefix": "epat_a1b2",
    "readOnly": false,
    "expiresAt": null,
    "lastUsedAt": 1735100000,
    "revoked": false,
    "createdAt": 1735000000
  }
]
```

Note the camelCase fields — this domain does not use snake_case like the
content APIs. Timestamps are unix seconds; `expiresAt`/`lastUsedAt` may be
`null`.

## Gotchas

- **The plugin CANNOT mint or revoke tokens.** `POST /api-tokens` and
  `DELETE /api-tokens/{id}` return 403 `session_required` when called with a
  PAT — by design, so a leaked token can't create more tokens or destroy
  evidence. When the user asks to create or revoke a token, do NOT retry or
  look for a workaround: send them to the admin UI at
  `https://<tenant>/admin/settings/api-tokens`.
- The full secret is shown exactly once, at creation time in the admin UI.
  The API only ever returns the `prefix` — if the user lost a token, it
  cannot be recovered; revoke it and mint a new one (in the UI).
- `readOnly: true` tokens cannot write anywhere on the API. If
  `GET /users/me` reported `readOnly: true` at setup, refuse mutations up
  front instead of letting them 403.
- **PATs are per-tenant.** A token minted on one tenant is worthless on
  every other tenant. Changing `EDGEPRESS_TENANT` means matching a new
  `EDGEPRESS_TOKEN` — re-run the setup check.
- `revoked: true` rows stay in the list for audit history; filter them out
  when reporting active tokens.
- A 401 on any call mid-session means THIS token is dead (revoked or
  expired) — stop writing and tell the user to re-run `/edgepress:setup`.
