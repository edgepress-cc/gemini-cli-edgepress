# Settings

The tenant's key-value store: site title, description, signup toggle, and
other option rows. Each setting is an `{option_name, option_value}` pair.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/settings` | All settings (authenticated) |
| GET | `/settings/public` | Public subset — no auth required |
| POST | `/settings` | Create a setting row |
| PUT | `/settings` | Update settings (admin) — only the keys you send change |
| DELETE | `/settings` | Remove a setting row (option_name in body) |
| GET | `/settings/public-signup` | Read the public-signup toggle |
| PUT | `/settings/public-signup` | Flip the public-signup toggle |

## Common bodies

Update one setting:

```json
{"option_name":"site_title","option_value":"The Daily Kick"}
```

Toggle public signup:

```bash
ep PUT /settings/public-signup '{"enabled":true}'
```

## Response shape

`GET /settings` returns the full list of option rows:

```json
[
  {"option_name": "site_title", "option_value": "The Daily Kick"},
  {"option_name": "site_description", "option_value": "Football, daily."},
  {"option_name": "public_signup_enabled", "option_value": "false"}
]
```

## Gotchas

- **All values are strings.** Booleans arrive as `"true"`/`"false"`, numbers
  as `"42"`. Compare and write them as strings; don't send raw JSON booleans
  in `option_value`.
- **Update is PUT `/settings`** (not PATCH) with `{option_name,
  option_value}`. Unlike content PUTs, this touches only the key you name —
  other settings are untouched. Still: send one key at a time and read back.
- **Settings writes are admin-only.** Lower roles get 403 — check the
  session role from setup before suggesting a settings change.
- `GET /settings/public` is the unauthenticated subset for the public site.
  Don't use it to verify writes — the key you changed may not be in it.
  Verify with the authenticated `GET /settings`.
- The public-signup toggle has its own endpoint pair
  (`/settings/public-signup`) — prefer it over writing
  `public_signup_enabled` directly, since it applies validation.
- There is no schema for option names: a typo'd `option_name` on PUT/POST
  quietly creates a new, unused row instead of erroring. Read the existing
  keys first and match names exactly.
- Deleting a load-bearing key (e.g. `site_title`) breaks rendering with no
  API-side guard. Only DELETE rows the user explicitly names, and confirm.
