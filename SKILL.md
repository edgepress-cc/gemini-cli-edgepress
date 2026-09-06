---
name: edgepress
description: Author, publish, and manage EdgePress tenant content (posts, pages, media, categories, tags, users, podcasts, daily cartoons, settings, API tokens) via the tenant's /api/v1 REST API. Trigger for any request that reads or writes to an EdgePress site.
---

# EdgePress

## Preamble

EdgePress is a multi-tenant publishing platform on Cloudflare Workers. Each
tenant is a site (e.g. `blog.edgepress.cc`) exposing a REST API at
`https://<tenant>/api/v1`. This skill drives that API with a personal access
token (PAT, `epat_...`) through the bundled `ep` script.

Domains you can operate on:

- **Posts** — articles: draft/published/scheduled lifecycle, slugs, featured
  images, per-post categories and tags, pen-name attribution.
- **Pages** — static pages (about, contact). Same shape as posts minus
  scheduling; pages have their own separate taxonomy.
- **Media** — image/file uploads to R2. Upload is multipart, not JSON. Other
  resources reference media by `id`.
- **Categories & tags** — post taxonomies AND page taxonomies are separate
  tables with separate endpoints. Categories are hierarchical, tags are flat.
- **Users** — staff accounts with roles (admin/editor/author/columnist/
  contributor/subscriber), pen names, avatars, `/users/me` self-updates.
- **Podcasts** — episodes with platform links (Apple, Spotify, YouTube).
- **Daily cartoons** — ordered collections of cartoon items.
- **Settings** — tenant key-value store (`site_title`, `site_description`,
  `public_signup_enabled`, ...).
- **API tokens** — PATs. Listing works with a PAT; creating/revoking is
  session-only (admin UI), the plugin cannot do it.
- **Templates** — page layouts: zones (named regions) holding ordered block
  instances, draft/published lifecycle, assignment to pages and posts. This is
  the one domain served by GraphQL (`POST /graphql`), not REST.

Everything below assumes you act on ONE tenant per session — the one named by
`EDGEPRESS_TENANT`.

## First: which product is this tenant?

EdgePress serves two products, and they expose DIFFERENT API surfaces.
Identify the product before any other call — one call does it:

`GET /api/v1/users/me` (the setup check below). BOTH products serve it, and
its `product` field names the tenant's product: `"cms"` (absent also means
cms) — everything in this skill applies — or `"store"` — only the Store
operations section applies. A **404** here means the tenant hostname is
wrong or the tenant is broken — `/edgepress:doctor`, don't guess.

`GET /api/store` (no auth, not under /api/v1) remains the store's public
identity endpoint: it returns `product: "store"` without credentials — even
its 503 `store_not_provisioned` response carries it. Use it when you have no
working token and need to tell a store from a dead tenant.

A store tenant exposes `GET /api/store`, `GET /api/v1/users/me`, the
catalogue API under `/api/v1/categories` and `/api/v1/products`, the
read-only orders API under `/api/v1/orders`, and the store's settings at
`/api/v1/settings` (see Store operations). Shopper
account endpoints (register/login/logout/me) live under `/api/shop` — they
are cookie-authenticated (`__Host-shop_session` + `__Host-shop_csrf`) for storefront
browsers. A PAT confers no SHOPPER identity on these routes, but it is NOT
ignored: the shared Bearer branch runs before the shop routes' auth
exemption is consulted, so a presented PAT is still validated and charged
its per-token 60 req/min budget, an invalid or revoked PAT is a 401
`invalid_token` before the route ever runs, and a read-only PAT is a 403
`read_only_token` on any POST there (login, cart, checkout). A valid
non-read-only PAT reaches the route as an anonymous shopper client with no
session — `GET /api/shop/me` with only a PAT is a 401 `auth_required` — so
do not use these routes to act for the merchant, and do not burn PAT rate
budget on them. Every
other store `/api/*` path requires PAT auth and then
404s; there are no cart or payment endpoints, and orders are read-only. Attempting any CMS
operation on a store tenant returns a bare 404.

## Setup check

Mandatory first step of EVERY session that touches EdgePress. Do this before
any other API call.

1. Verify environment:

```bash
printenv EDGEPRESS_TENANT EDGEPRESS_TOKEN
```

If either is missing or empty, tell the user to run `/edgepress:setup` and
STOP. Do not guess a tenant hostname. Do not ask the user to paste a token
into chat.

2. Verify the token actually works and learn who you are:

```bash
ep GET /users/me
```

- **200** → note the `role`, the `readOnly` flag and `product` from the
  response. `product: "cms"` (absent also means cms) → everything in this
  skill applies; `product: "store"` → only the Store operations section
  applies. Cache them for the rest of the session.
- **401** → token invalid/revoked. Tell the user to run `/edgepress:setup`
  (or check the token in the tenant admin UI) and STOP. If you need to know
  the product anyway, `curl -sS "https://$EDGEPRESS_TENANT/api/store"`
  answers `product: "store"` without auth on a store tenant.
- **404** → wrong hostname or broken tenant (both products serve this
  endpoint); suggest `/edgepress:doctor`.
- Network error → print the tenant URL and the error; suggest
  `/edgepress:doctor`.

3. Gate your suggestions on what you learned:

- `readOnly: true` → this token cannot write. Answer read requests normally;
  for any mutation, refuse and explain the token is read-only.
- `role` below `editor` → user management, settings writes, and other users'
  content are off-limits. Suggest only what the role can do; if the API
  returns 403 anyway, report it plainly — don't retry.

Never re-check env vars on every call; once per session is enough. But if any
call returns 401 mid-session, treat the token as dead and stop writing.

## The `ep` script

`scripts/ep` (bundled with this skill, on PATH after plugin install) is a thin
curl wrapper around `https://$EDGEPRESS_TENANT/api/v1`. It adds the
`Authorization: Bearer $EDGEPRESS_TOKEN` header, sets JSON content type when a
body is given, pretty-prints via `jq`, and turns HTTP >= 400 into exit code 1
with the status and body on stderr.

```bash
# Read
ep GET /posts?limit=10
ep GET /posts/42

# Create (body is a JSON string, single-quoted)
ep POST /posts '{"title":"Hello","status":"draft"}'

# Update
ep PUT /posts/42 '{"title":"Hello again","status":"published"}'
ep PATCH /users/me '{"display_name":"New Name"}'

# Delete
ep DELETE /posts/42

# --raw: skip jq pretty-printing (pipe to your own jq filter)
ep --raw GET /posts | jq '.[].slug'

# --endpoint: print the resolved URL without executing (debugging)
ep --endpoint GET /posts?limit=5
# -> GET https://blog.edgepress.cc/api/v1/posts?limit=5
```

Notes:

- Exit codes: `0` success, `1` HTTP error (status + body on stderr), `2` usage
  error, `3` missing env vars.
- If `jq` is not installed, `ep` falls back to raw output automatically —
  don't fail a task over missing `jq`, just read the raw JSON.
- Query strings go in the path argument; quote the whole path if it contains
  `&` or spaces.
- The one thing `ep` does NOT do: multipart uploads. For `POST /media/upload`
  use raw `curl` (see Media in the quick reference).

## When to load a reference

Hard rule: **if the task touches domain X, Read `references/X.md` before
writing any code or composing any non-trivial request body.** The quick
reference below covers simple one-shot calls; anything with bodies, taxonomy
links, or lifecycle transitions needs the reference file.

Triggers per domain:

- Creating/editing/publishing/scheduling articles → `references/posts.md`
- Static pages or page taxonomy → `references/pages.md`
- Uploading files, thumbnails, featured images → `references/media.md`
- Creating or reorganizing categories/tags (post OR page) →
  `references/categories-tags.md`
- User accounts, roles, pen names, avatars → `references/users.md`
- Podcast episodes or platform links → `references/podcasts.md`
- Cartoon collections/items → `references/daily-cartoons.md`
- Site settings keys → `references/settings.md`
- Anything about tokens/auth → `references/api-tokens.md`
- Building or editing page layouts — templates, zones, block instances →
  `references/templates.md`

Simple GETs (list posts, show a page, read settings) don't need a reference
load — use the quick reference and go.

## Top-level workflows

### Publish flow

Never create straight to `published` unless the user explicitly says
"publish". Default lifecycle:

1. `ep POST /posts '{"title":"...","content":"...","status":"draft"}'`
2. Show the user the created slug/ID; iterate on content with updates.
3. On approval: GET the current post, merge `{"status":"published"}` into it,
   PUT it back. Publishing is a status change on the resource — there is no
   separate publish endpoint.
4. For future publishing, set `scheduled_at` (ISO 8601) with
   `status: "scheduled"` instead.

### Media flow

1. Upload the file (multipart — raw curl, see quick reference). The response
   contains both `url` and `id`.
2. Use the `id` — e.g. as `featured_image_id` on a post. The `url` is for
   humans; the `id` is what resources reference.
3. Never delete media without first checking what references it.

### Never overwrite

For every edit of an existing resource: **GET the current version, merge your
changes into it, send the merged object back.** Content updates are
full-object PUTs on this API — sending a partial body can null out fields you
didn't mention. This is the single most common way to destroy content.

```bash
CUR=$(ep --raw GET /posts/42)
echo "$CUR" | jq '. + {"status":"published"}' > /tmp/merged.json
ep PUT /posts/42 "$(cat /tmp/merged.json)"
```

### Rate limit

60 requests/min per token. A 429 response carries `Retry-After` — `ep`
surfaces the full error body on stderr. If a task will need more than ~30
calls, don't do it in the main loop: batch what the API supports (e.g.
`POST /podcasts/bulk`) or hand off to the subagent.

### Bulk import

Importing many items (a JSON/CSV of posts, a podcast back-catalog) is ALWAYS
subagent work — never loop it in the main conversation. See the next section.

## When to hand off to the subagent

Hand off to the `edgepress-workflow` subagent when the task is any of:

- Bulk operations on more than ~10 items (imports, mass re-tagging, mass
  deletes).
- Multi-step publish sequences (a series of linked, scheduled posts).
- Site-wide sweeps (paginate every post, PATCH each).
- Anything you estimate at more than 30 API calls or more than ~3 minutes of
  wall time.

Two ways to dispatch:

1. The user runs `/edgepress:workflow "<task description>"`.
2. You spawn it yourself via the `Agent` tool with
   `subagent_type: "edgepress-workflow"` and a precise task prompt: what to
   do, the exact item list or its source, and what "done" looks like.

The subagent owns pacing (sleep between calls), idempotent retries, and the
work-list file. You own the decision to dispatch and the summary back to the
user. Do not shadow it by making the same calls yourself while it runs.

## Common pitfalls

- **PATs are per-tenant.** A token minted on `blog.edgepress.cc` is worthless
  on any other tenant. If the user changes `EDGEPRESS_TENANT`, they need a
  matching `EDGEPRESS_TOKEN` — re-run the setup check.
- **Read-only tokens.** `/users/me` returns `readOnly: true` for read-only
  PATs. Refuse writes up front instead of letting them 403 one by one.
- **Token management is session-only.** `POST /api-tokens` and
  `DELETE /api-tokens/:id` return 403 `session_required` for PATs. The plugin
  can LIST tokens but never create or revoke them — send the user to
  `https://<tenant>/admin/settings/api-tokens`.
- **Publishing is a status change,** not an endpoint. There is no
  `/posts/42/publish`. Merge `{"status":"published"}` and PUT.
- **Post and page taxonomies are separate.** `/posts/categories` and
  `/pages/categories` are different tables. Creating a category under one does
  not make it available to the other. Same for tags.
- **429 back-off.** On a 429, read `Retry-After` from the error output, sleep
  that many seconds, retry ONCE. Two 429s in a row → stop and tell the user.
- **Deleting referenced media breaks content.** A post whose
  `featured_image_id` points at deleted media renders broken. Before
  `DELETE /media/:id`, check for references and warn the user.
- **Templates are GraphQL, not REST.** Templates, zones and block instances
  live behind `POST /graphql` — see `references/templates.md`. GraphQL answers
  HTTP 200 even when it fails, so `ep` exits 0: always check the `errors` array.
  Block content inside a single post/page body is still admin-UI territory.
- **Partial updates null fields.** See "Never overwrite" above — always
  GET → merge → PUT for content resources.

## Domain quick reference

Every section below is labelled with the product it applies to. Identify the
product first (see "First: which product is this tenant?") — CMS endpoints
404 on a store tenant, with one exception: `GET /users/me` is served by both
products (on a store, GET only) and is how you tell them apart.

Enough for simple calls. For request bodies and gotchas, load the domain's
reference file first.

### Posts — CMS

```
GET    /posts                list (query: limit, offset, status)
GET    /posts/:id            one post
GET    /posts/slug/:slug     lookup by slug
POST   /posts                create (title required; slug auto-derived)
PUT    /posts/:id            full update (GET → merge → PUT)
DELETE /posts/:id            delete
```

Common fields: `title`, `slug`, `content`, `excerpt`, `status`
(`draft|published|scheduled`), `scheduled_at`, `featured_image_id`,
`category_ids`, `tag_ids`, `pen_name_id`. Non-obvious: `slug` is derived from
`title` on create if omitted — set it explicitly for stable URLs.

### Pages — CMS

```
GET    /pages          list
GET    /pages/:id      one page
POST   /pages          create
PUT    /pages/:id      full update
DELETE /pages/:id      delete
```

Same shape as posts but no `scheduled_at`. Page taxonomy endpoints are
`/pages/categories` and `/pages/tags` — never the post ones.

### Media — CMS

```
GET    /media          list
GET    /media/:id      one item
POST   /media/upload   upload — multipart/form-data, NOT JSON
PUT    /media/:id      update metadata (alt text, title)
DELETE /media/:id      delete (check references first!)
```

Upload with raw curl (the one call `ep` can't make):

```bash
curl -sS -X POST "https://$EDGEPRESS_TENANT/api/v1/media/upload" \
  -H "Authorization: Bearer $EDGEPRESS_TOKEN" \
  -F "file=@/path/to/image.jpg"
```

Response has `id` and `url`; use `id` in `featured_image_id` etc.

### Categories & tags — CMS

```
GET/POST/PUT/DELETE  /posts/categories    post categories (hierarchical: parent_id)
GET/POST/PUT/DELETE  /posts/tags          post tags (flat)
GET/POST/PUT/DELETE  /pages/categories    page categories — separate table
GET/POST/PUT/DELETE  /pages/tags          page tags — separate table
GET    /posts/categories/:slug            posts in a category
GET    /posts/tags/:slug                  posts with a tag
```

Categories nest via `parent_id`; tags never nest. Post and page taxonomies do
not share rows.

### Users — CMS

```
GET    /users              list (admin/editor)
POST   /users              create (admin only)
PATCH  /users/:id          update a user (admin only)
PATCH  /users/me           self-update (any role)
GET    /users/me           who am I (also the setup check)
GET    /users/pen-names    pen names; POST/PUT/DELETE to manage
POST   /users/avatar       set avatar; DELETE to clear
```

`role` enum: `admin`, `editor`, `author`, `columnist`, `contributor`,
`subscriber`. Only admins create/edit other users; everyone can PATCH
`/users/me`.

### Podcasts — CMS

```
GET    /podcasts           list episodes
GET    /podcasts/:id       one episode
POST   /podcasts           create
PUT    /podcasts/:id       full update
DELETE /podcasts/:id       delete
POST   /podcasts/bulk      bulk create (use for imports ≤ rate limit)
GET    /podcasts/categories, /podcasts/tags   podcast taxonomy
```

Episodes carry platform links: `apple_url`, `spotify_url`, `youtube_url`.

### Daily cartoons — CMS

```
GET    /daily-cartoons               list collections
GET    /daily-cartoons/:id           one collection (with items)
POST   /daily-cartoons               create collection
PUT    /daily-cartoons/:id           update
DELETE /daily-cartoons/:id           delete
POST   /daily-cartoons/:id/reorder   reorder items
```

Collections contain ordered `daily_cartoon_items`; ordering changes go through
`/reorder`, not by rewriting the collection.

### Settings — CMS

```
GET    /settings                  all settings (auth'd)
GET    /settings/public           public subset (no auth)
PUT    /settings                  update keys (admin)
GET/PUT /settings/public-signup   public signup toggle
```

Key-value store. Common keys: `site_title`, `site_description`,
`public_signup_enabled`. PUT only the keys you're changing.

### API tokens — CMS

```
GET    /api-tokens        list tokens — works with a PAT
POST   /api-tokens        403 session_required — admin UI only
DELETE /api-tokens/:id    403 session_required — admin UI only
```

You can audit tokens but never mint or revoke them. Refer the user to
`https://<tenant>/admin/settings/api-tokens`.

### Templates (GraphQL) — CMS

```
GET  /blocks                 block catalogue
GET  /blocks/:type/schema    settings a block type accepts
POST /graphql                templates, zones, block instances — the only non-REST domain
```

```bash
ep POST /graphql '{"query":"query { templates { id name slug status } }"}'
```

Flow: `createTemplate` → `createZone` → `createBlockInstance` →
`reorderBlockInstances` → `publishTemplate` → `assignTemplateToPage`.
HTTP is always 200 — check `errors`. Load `references/templates.md` before
writing any mutation.

## Store operations

Store tenants in this release expose the public profile endpoint, the
identity call, the catalogue API (categories + products), the store's
settings, and a READ-ONLY orders API — nothing else. Orders are created by
shopper checkout on the storefront, never through a PAT: there is no POST,
no PATCH and no status change yet (those arrive in a later release), and
there are no cart or payment endpoints. The users API is just the read-only
`users/me` identity call (no user list, no profile writes). Do not guess at endpoints beyond these, and tell
the user plainly when a request needs an API the store does not have yet.

```
GET    /api/store                  the store's public profile (no auth, and NOT under /api/v1)
GET    /api/v1/users/me            who am I: your user row + readOnly, authMethod, product: "store" (GET only — no PATCH on a store)
GET    /api/v1/categories          list categories (sort_order, then name)
POST   /api/v1/categories          create a category ({name} required; slug derived from name unless given)
GET    /api/v1/categories/{id}     one category
PATCH  /api/v1/categories/{id}     partial update (send only changed fields)
DELETE /api/v1/categories/{id}     delete; children are detached (parent_id → null), not deleted
GET    /api/v1/products            list products; DEFAULT is active+visible only — add ?status=draft|active|archived|all for the rest, ?category={id} to filter by category
POST   /api/v1/products            create a product ({name} required; slug derived; status defaults to draft; categories: [ids] sets membership)
GET    /api/v1/products/{id}       one product, any status; includes categories: [ids]
PATCH  /api/v1/products/{id}       partial update; categories REPLACES membership ([] clears it; omit to keep)
DELETE /api/v1/products/{id}       delete; its category-membership rows go with it
GET    /api/v1/orders              list orders, NEWEST FIRST, all statuses by default — ?status=pending_payment|paid|processing|shipped|completed|cancelled|refunded|all, ?limit= (1-100, default 50), ?offset=
GET    /api/v1/orders/{id}         one order + its items; items are purchase-time SNAPSHOTS (name, unit_price) — later product edits never change them
GET    /api/v1/settings            the store's settings: exactly 15 fields (identity, contact, currency/locale/timezone, tax, analytics)
PATCH  /api/v1/settings            partial update of those 15 fields; anything else in the body is ignored, not an error
```

Every `/api/v1` endpoint (users/me included) uses the same
`Authorization: Bearer epat_...` PAT auth as the CMS, with the same
read-only rule: a read-only token gets 403
`read_only_token` on any non-GET. A duplicate slug is a 409. Categories form
a tree via `parent_id` (integer id or null); `is_visible` is 0/1.
Writes return `{"success": true, "id", "slug"}`; GETs return the raw row /
array of rows.

Product money — `price` and `compare_at_price` — is INTEGER MINOR UNITS
(1999 = 19.99 in the product currency). A float or negative is rejected with
400, never rounded: multiply before sending, divide when displaying.
`currency` must be a 3-letter uppercase ISO 4217 code (anything else is a
400) and defaults to the store's own currency when omitted on create. A new
product defaults to `status: "draft"`, which the default product list does
NOT show — pass `status: "active"` (and leave `visible` alone) to make it
live, and use `?status=all` when auditing the whole catalogue. Product
`visible` and `featured` are 0/1.

Order money (`subtotal`, `total`, each item's `unit_price` and
`line_total`) is the same integer-minor-units rule, in the order's own
`currency` — it is what was actually charged at checkout and is never
recomputed from live product rows. `customer_id` and `customer_email` are
null on guest orders — a null customer is a normal, complete order, not an
error. The order's own `email`/`name` are the checkout contact details and
are present on guest orders too; `phone` is copied from the shopper's
account at checkout time, and guest checkout collects no phone — so it is
always null on guest orders and null for account holders who never gave
one. Unknown ids from another store
and malformed ids are a plain 404.

Store settings (`/api/v1/settings`) cover exactly 15 fields: `name`,
`description`, `logo_url`, `favicon_url`, `currency`, `locale`, `timezone`,
`email`, `phone`, `address`, `tax_enabled`, `tax_rate`, `tax_inclusive`,
`google_analytics_id`, `facebook_pixel_id`. PATCH returns
`{"success": true, "settings": {...}}` with the updated row; a body with
nothing updatable is a 400, and a PATCH with `id`, `slug` or any other
non-listed field silently ignores those fields. `currency` follows the same
ISO 4217 rule as products; `tax_enabled`/`tax_inclusive` are 0/1 (booleans
accepted, strings rejected); `tax_rate` is a number 0-100. Length caps:
`name` is 1-60 characters, and every free-text field (description, the URLs,
contact fields, analytics ids) caps at 2000 — longer is a 400. Both verbs
return 503 `store_not_provisioned` until the store row exists (same signal
as `GET /api/store`). The tax fields
and the analytics ids are STORED BUT NOT YET APPLIED — tax is applied at
checkout (slices 3-4) and analytics are emitted by the storefront in slice 6
— so never tell a user that setting them changes live behaviour today.

`GET /api/store` is the one unauthenticated endpoint, and `ep` cannot call it
(it prefixes `/api/v1`); use raw curl:

```bash
curl -sS "https://$EDGEPRESS_TENANT/api/store"
```

Returns `{"product": "store", "store": {"name", "description", "logo_url",
"currency", "locale", "timezone", "status"}}`, or 503
`{"product": "store", "error": "store_not_provisioned"}` before provisioning
completes — either way, `product: "store"` confirms the tenant is a store.

## Reference index

Load one of these before generating code for its domain:

| Domain | File | When to read |
|---|---|---|
| Posts | `references/posts.md` | drafts, publishing, scheduled_at, featured images, taxonomies, revisions |
| Pages | `references/pages.md` | static pages, page taxonomy (separate from posts) |
| Media | `references/media.md` | uploads (multipart!), thumbnails, R2 references |
| Categories & tags | `references/categories-tags.md` | post vs page taxonomies (separate), hierarchical categories, flat tags |
| Users | `references/users.md` | roles, pen names, avatars, /users/me self-updates |
| Podcasts | `references/podcasts.md` | episodes with platform links |
| Daily cartoons | `references/daily-cartoons.md` | collections + items (ordered) |
| Settings | `references/settings.md` | key-value store, public_signup_enabled, site_title |
| API tokens | `references/api-tokens.md` | list works via PAT; POST/DELETE need session — refer to admin UI |
| Templates | `references/templates.md` | page layouts via `POST /graphql`: templates, zones, block instances, publish, assignment |

## Session output style

Short, terse, direct.

- Name resources by **slug + title**: `hello-world — "Hello World"`, never by
  bare numeric ID alone.
- After creating or publishing anything, **quote back the new URL**:
  `https://<tenant>/posts/hello-world`.
- **Never dump raw API JSON** at the user. Summarize what changed: "Published
  hello-world — 'Hello World'. Now live at https://blog.edgepress.cc/posts/hello-world."
- For lists, show a compact table (slug, title, status) — not the response
  body.
- On errors, give the HTTP status, the API's error message, and ONE concrete
  next step. No stack traces, no full curl transcripts.
- When you refused a write (read-only token, session-only endpoint, role too
  low), say why in one sentence and name the place it CAN be done (usually the
  admin UI).
