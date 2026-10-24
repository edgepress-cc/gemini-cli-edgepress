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

## Theme settings

Two keys are validated on PUT/POST (the only ones that are):

| Key | Shape |
|---|---|
| `theme_palette` | `{primary, accent, text, background, muted, surface}` — each `#rrggbb` |
| `theme_fonts` | `{body, heading, mono}` — each a self-hosted family name or `"system"` |

Every key inside is optional; unknown keys are rejected. Send the object or
its JSON string — both are accepted, and both are stored as the JSON string:

```json
{"option_name":"theme_palette","option_value":{"primary":"#1d4ed8","accent":"#f59e0b"}}
```

`""` or `null` clears the key (the site falls back to its defaults). A bad
value returns `400 {"success":false,"error":"invalid_theme_setting","detail":"theme_palette.primary: invalid value."}`
and writes nothing — in a multi-key PUT, none of the keys in that body are
written. Read the stored result back with `GET /settings`.

## Weather key

`weather_api_key` is the site's own weatherapi.com key, used by the ticker
block's weather readout. It is **write-only**: set it with
`PUT /settings {"option_name":"weather_api_key","option_value":"<key>","autoload":"no"}`
(admin only). `GET /settings`, `GET /settings/public` and `?name=weather_api_key`
never return it; the name lookup answers 404. To check it works, call
`GET /api/weather?city=<ticker city>`: 200 with `{city, temp_c, is_day}`, or
404 `{"error":"not_configured"}` when no key is set. Never put a key in the
ticker block config; the schema rejects `weatherApiKey`.

## Gotchas

- **All values are strings** — except the two theme keys above, which also
  accept an object. Booleans arrive as `"true"`/`"false"`, numbers as `"42"`.
  Compare and write them as strings; don't send raw JSON booleans in
  `option_value`.
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
  quietly creates a new, unused row instead of erroring (only the values of
  `theme_palette`/`theme_fonts` are checked, and only under those exact
  names). Read the existing keys first and match names exactly.
- Deleting a load-bearing key (e.g. `site_title`) breaks rendering with no
  API-side guard. Only DELETE rows the user explicitly names, and confirm.
