# Users

Staff accounts with roles, pen names, and avatars. Most user management is
admin-only; every role can update itself via `/users/me`.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/users` | List users (admin/editor) |
| POST | `/users` | Create user (admin only) |
| PATCH | `/users/{id}` | Update a user (admin only) — real PATCH, partial body OK |
| PATCH | `/users/me` | Self-update (any role) |
| GET | `/users/me` | Who am I — also the session setup check |
| POST | `/users/reset-password` | Trigger a password reset |
| GET | `/users/pen-names` | List pen names (POST/PUT/DELETE to manage) |
| POST | `/users/avatar` | Set avatar (DELETE `/users/avatar` to clear) |

## Common bodies

Create a staff user (admin only):

```json
{"email":"dana@example.com","name":"Dana Levi","role":"author"}
```

Self-update display name:

```bash
ep PATCH /users/me '{"name":"New Name"}'
```

Change another user's role (admin only):

```bash
ep PATCH /users/3 '{"role":"editor"}'
```

## Response shape

```json
{
  "id": 3,
  "email": "dana@example.com",
  "name": "Dana Levi",
  "role": "author",
  "status": "active"
}
```

`GET /users/me` additionally reports the token's `readOnly` flag — cache it
at session start and refuse writes up front when it is `true`.

## Gotchas

- **Users are the PATCH exception.** Unlike posts/pages (full-object PUT),
  `/users/{id}` and `/users/me` accept true PATCH semantics — send only the
  fields you're changing. No GET-merge dance needed here.
- **Role enum:** `admin`, `editor`, `author`, `columnist`, `contributor`,
  `subscriber`. Only admins create or edit other users; everyone can PATCH
  `/users/me`.
- A non-admin token calling admin-only endpoints gets a 403 — report it
  plainly and don't retry. Gate suggestions on the role learned at setup.
- **Pen names are a sub-resource**, not a user field: manage them via
  `/users/pen-names` and reference them from posts via `pen_name_id`.
  PUT/DELETE on pen-names are collection-level (id in the body).
- Avatar upload goes through `POST /users/avatar` (not `/media/upload`);
  `DELETE /users/avatar` clears it.
- Tenant identity is SSO-only — there is no password-login CRUD here.
  `POST /users/reset-password` triggers the platform reset flow; it does not
  set a password directly.
- Deactivating vs deleting: prefer PATCHing `status` over destructive
  deletes so content attribution survives.
