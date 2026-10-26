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
orders API under `/api/v1/orders`, the payment-method CRUD under
`/api/v1/payment-methods`, the shipping-zone and shipping-method CRUD under
`/api/v1/shipping-zones` and `/api/v1/shipping-methods`, the customers API
under `/api/v1/customers`,
the store's settings at
`/api/v1/settings`, the same API-token list at `/api/v1/api-tokens`
as the CMS, a read-only audit log at `/api/v1/audit-log` and the review
moderation queue at `/api/v1/reviews` (see Store operations). Shopper
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
404s; there are no PAT cart endpoints, and no PAT can create an order.
`POST /api/shop/payment/callback/{provider}` is the payment gateway's
server-to-server notification (payplus only in this release; hyp and any
other provider are a 404): the tenant verifies the claimed transaction
against the provider's own API before recording anything, and a well-formed
callback is always acknowledged with 200 whether or not it verified — so
the response tells a caller nothing, and there is nothing an agent can do
with this endpoint. Attempting any CMS
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

- `readOnly: true` → this token cannot write, and cannot read the SIX
  privileged reads listed under "Read-only tokens" in Common pitfalls. Answer
  every other read normally; for any mutation, refuse and explain the token is
  read-only.
- `role` → on a **store** tenant every `/api/v1` route requires `admin`. There
  is no partial access: an editor (or anything below) gets
  `403 {"error":"insufficient_role","required":"admin"}` on the very first
  call. Say so immediately and do not begin the task — the token needs to be
  reissued by an admin. On a **CMS** tenant the ladder still applies: a role
  below `editor` can work, but user management, settings writes and other
  users' content are off-limits. Either way, if the API returns 403, report it
  plainly — don't retry.

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
  A read-only token ALSO cannot GET these six, which is a change — it could
  until the P5 authorization layer shipped. On each the read is itself the
  privileged act, so the token is 403 `read_only_token` in the middleware,
  before the handler runs:
  `/customers/{id}/export`, `/customers/{id}/tax-ids/{tid}`,
  `/email-credentials`, `/gateway-credentials`,
  `/suppliers/{supplierId}/credentials`, `/tax/provider-credentials`.
  Everything else a read-only token could GET, it still can — including
  `/customers`, `/customers/{id}` (tax IDs MASKED), the exemptions list and
  the exemption document. Ask for a full-access token for those six rather
  than retrying, and never present the 403 as the route being unavailable.
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

### API tokens — BOTH products

```
GET    /api-tokens        list tokens — works with a PAT
POST   /api-tokens        403 session_required — admin UI only
DELETE /api-tokens/:id    403 session_required — admin UI only
```

Same paths, same envelope and same rules on a store tenant (`ep` already
prefixes `/api/v1`). You can audit tokens but never mint or revoke them.
Refer the user to `https://<tenant>/admin/settings/api-tokens` — the same
URL on both products.

### Audit log — STORE

```
GET    /audit-log                       newest first; { rows, next_before }
GET    /audit-log?limit=50&before=<id>  next (older) page — before = previous next_before
GET    /audit-log?action=delete&resource_type=api_token&user_email=…   exact-match filters, AND'd
```

`limit` defaults to 50, caps at 200. `next_before` is null on the last
page. `details` is already parsed (object or null). Only the PAT lifecycle
(create/delete of `api_token`) is audited in this release. Works with a
read-only PAT. On a CMS tenant `/api/v1/audit-log` is the mirror of the
CMS's own offset-paged `/api/audit-log` — a different envelope
(`{entries, total, limit, offset}`), so product-detect first. The operator's
view of the same rows is `https://<tenant>/admin/settings/audit-log`.

### Variants — STORE

```
GET    /products/<id>/variants          { product_id, options: ["Size","Glaze"], variants: [...] }
PUT    /products/<id>/variants          REPLACE: { options, variants: [{ id?, values: {Size:"M"}, price, compare_at_price, stock, allow_oversell }] }
GET    /products?include_variants=1     lists variant rows too (default: parents only, with variant_count)
```

A variant is a product row (own price / stock / oversell) under a parent;
its name and slug derive from the parent's plus the option values
("Ash Mug — Small / Ash"), and PATCHing the parent's name/status/visibility
re-derives and propagates. Add a variant to a cart by ITS product id;
checkout takes ITS stock. Rows missing from a PUT are deleted.

### Reviews — STORE

```
GET    /reviews                         moderation queue: pending, newest first; { rows, next_before }
GET    /reviews?status=approved|rejected|all&product_id=<id>&limit=50&before=<id>
PATCH  /reviews/<id>   { "status": "approved" | "rejected" | "pending" }
DELETE /reviews/<id>                    remove outright (spam)
```

Shoppers post reviews from the product page (`POST /api/shop/reviews`,
cookie/CSRF-guarded, rate-limited, honeypot); every one lands `pending`.
Only approved reviews render on the product page, and the page's star
rating IS their average — there is no rating to set by hand. Moderation is
audited (`review.status`, `review.delete`). Listing works with a read-only
PAT; PATCH/DELETE need a write-capable one.
### Onboarding — CMS

```
GET  /onboarding                 first-run wizard state + dashboard checklist (admin)
PUT  /onboarding                 { state?, step?, checklist_dismissed? } — nothing else is writable
POST /onboarding/design          { design, lang, pages?, palette?, fonts?, removeSamples? } — apply a starter design
POST /onboarding/wp-scan         { url?, username?, app_password? } — WordPress preflight scan, 5 per site per hour
```

All four are admin only. The scan stores its report (counts, theme, fidelity, palette) on the
onboarding row and returns it; a site that cannot be scanned is a 422 whose
`detail` says why. The Application Password (https only) is used for that one
request and is **never stored or returned** — never log it or echo it back
to the user either.

### WordPress import — CMS

```
POST /import/wordpress               { url?, username?, app_password? } — start; 201 { job }, 5 per site per hour
GET  /import/wordpress/{id}          { job: { id, source_url, state, counts, last_error, report, … } }
POST /import/wordpress/{id}/step     one unit of work; call until state is "done" ({ busy: true } = retry)
POST /import/wordpress/{id}/pause    POST …/resume    POST …/cancel
```

All admin only; one active import per site (409 `import_active` with its
`job_id`). Add-only: content already on the site is never modified; a re-run
imports only what is new. Three failed steps in a row pause the job — read
`last_error`, then resume. The Application Password (https only) is stored
encrypted only until the import finishes or is cancelled, then deleted; it is
**never returned** — never log or echo it. 503 `import_unavailable` is an
operator problem (tables or key), not something to retry in a loop.

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
identity call, the catalogue API (categories + products), the suppliers API,
the store's
settings, an orders API, the payment-method CRUD, the write-only
gateway-credentials API, the write-only email-credentials API, the
read-only email-log API, the customers API (list, detail, the
operator-owned profile fields, tax IDs, read-only address book, the
account-integrity actions and the data export), the API-token list, and the read-only audit log — nothing else. **Cost and margin are OPERATOR-ONLY data: `cost_price`
(products), `cost_snapshot` and `margin` (orders/order items) exist ONLY in
these `/api/v1` operator endpoints and appear on NO shopper-facing surface —
not the storefront catalogue, not the cart, not the checkout confirmation,
not any customer-facing render. Never suggest exposing them to a shopper,
and never assume a figure quoted to a customer includes them.** Orders are created by shopper checkout on the storefront, never
through a PAT: there is no POST /api/v1/orders, and there
are no PAT cart endpoints. The order writes are exactly two: the
lifecycle PATCH and recording payment receipt (both below) — an order's
line items, totals and captured contact details are never editable.
Customers are created by storefront registration, never through a PAT:
the operator surface is the list, the detail GET, the PATCH (enable/disable
plus the three operator-owned profile fields — `customer_type`,
`business_verification`, `operator_notes`), the tax-ID sub-resources,
the read-only address book and the ACCOUNT INTEGRITY actions (force-verify,
resend verification, cancel deletion, export) — no identity edits (email, name, phone are the
shopper's), no password writes, no address writes. See CUSTOMER TAX
IDENTITY below. The users API is just the read-only
`users/me` identity call (no user list, no profile writes). Do not guess at endpoints beyond these, and tell
the user plainly when a request needs an API the store does not have yet.

```
GET    /api/store                  the store's public profile (no auth, and NOT under /api/v1)
GET    /api/v1/users/me            who am I: your user row + readOnly, authMethod, product: "store" (GET only — no PATCH on a store)
GET    /api/v1/categories          list categories (sort_order, then name); every row has product_count (direct members) and rules (null = manual, see SMART CATEGORIES below)
POST   /api/v1/categories          create a category ({name} required; slug derived from name unless given; image_url shows as the category page banner and in the category-nav block's `cards` layout; rules: {match, conditions} makes it automatic)
GET    /api/v1/categories/{id}     one category (+ product_count, rules, field_presets)
PATCH  /api/v1/categories/{id}     partial update (send only changed fields); rules: {…} re-derives membership now, rules: null makes it manual again (rows kept); field_presets: [{key?, label, type, options?, unit?, required?, storefront?}] REPLACES the category's product detail fields (see PRODUCT DETAIL FIELDS below), null clears
DELETE /api/v1/categories/{id}     delete; children are detached (parent_id → null), not deleted
PUT    /api/v1/categories/tree     move/reorder many categories in ONE write: {nodes: [{id, parent_id, sort_order}]} — only the nodes that changed; the resulting tree must be acyclic (400), ids must be this store's (404); all-or-nothing
GET    /api/v1/categories/{id}/products   the category's products in ITS storefront order (position), each with is_primary and category_count
PUT    /api/v1/categories/{id}/products   {product_ids: [...]} REPLACES membership + order (array position = position; [] empties it); on a smart category the rules re-assert membership right after, so it is a reorder
POST   /api/v1/categories/rules/preview   {rules} → {count, products[≤50]} — dry-run a rule set, writes nothing
POST   /api/v1/categories/bulk     {ids, action: show|hide|delete}
POST   /api/v1/categories/{id}/image      multipart `file` (JPEG/PNG/WebP/AVIF ≤25 MB) → AVIF variants in the media bucket, image_url set to the large one; replaces a previous upload
DELETE /api/v1/categories/{id}/image      clear image_url and delete the uploaded variants
GET    /api/v1/products            list products; DEFAULT is active+visible only — add ?status=draft|active|archived|all for the rest, ?category={id} to filter by category (+ &include_children=1 for the whole branch), ?tag={slug}, ?q= for a name/slug match; every row has category_ids, primary_category_id and tags
POST   /api/v1/products            create a product ({name} required; slug derived; status defaults to draft; shipping_exempt? (0|1, default 0 — never adds a delivery charge); tax_class_id? (one of this store's tax classes, null = standard — see TAX ENGINE below; another store's id is a 400 invalid_tax_class); categories: [ids] sets membership and primary_category_id (one of them) picks the breadcrumb category; stock defaults to null = NOT TRACKED — checkout never refuses an untracked product; allow_oversell defaults to 0 and backorder_notice to null — see per-item oversell below; supplier_id, cost_price and supplier_external_id default to null — see suppliers/cost and sourcing below; supplier_stock and supplier_synced_at are never client-writable — see SYNC below)
GET    /api/v1/products/{id}       one product, any status; includes categories: [ids], primary_category_id, tags: [names] and custom_fields ({key: value} or null); also supplier_stock and supplier_synced_at — OPERATOR-ONLY, read-only, see SYNC below
PATCH  /api/v1/products/{id}       partial update; categories REPLACES membership ([] clears it; omit to keep) and keeps the primary while it is still a member; tags REPLACES the tag list (names; omit to keep); primary_category_id may be sent alone (must be one of the product's categories, 400 otherwise); stock: non-negative integer tracks inventory, null turns tracking off (negatives/floats are a 400) — and a stock write SETTLES any `backordered` debt against the count you send (20 against 3 owed stores 17/0; null clears the debt too), which is the only way to clear one; allow_oversell and backorder_notice are writable, `backordered` is NOT (it is checkout's and the restock's arithmetic — a 400 as an unwritable field); supplier_id, cost_price and supplier_external_id are writable (see suppliers/cost and sourcing below); tax_class_id is writable (null = standard; 400 invalid_tax_class for a class that is not this store's); supplier_stock and supplier_synced_at are NOT in this endpoint's updatable-field list — naming them alongside real updatable fields is silently ignored, but a PATCH body containing ONLY those fields returns 400 "No updatable fields provided"; only the sync endpoint below ever sets them
DELETE /api/v1/products/{id}       delete; its category-membership rows go with it
POST   /api/v1/products/bulk       {ids, action: enable|disable|delete|add_category|remove_category|add_tag|remove_tag, category_id?, tag?} — the category actions are idempotent and refused (409 category_is_smart) on an automatic category; add_tag creates the tag if new
GET    /api/v1/tags                list tags with product_count (most used first); tags are born on products, never created here
PATCH  /api/v1/tags/{id}           rename ({name}; slug follows; 409 on a clash)
DELETE /api/v1/tags/{id}           drop the tag from every product
GET    /api/v1/discounts           list discounts (?status=; rows carry parsed scope/conditions, usage_count, redemption_count)
POST   /api/v1/discounts           create ({title, kind: percent|fixed|free_shipping|bxgy (with reward: {buy:{scope, quantity|spend}, get:{scope, quantity, percent}, repeats?, max_rewards?}), value (bp | minor units | 0), applies_to? (goods|shipping — percent/fixed only), code? (A-Z0-9_- 3-32, uppercased; omit for AUTOMATIC), scope?, conditions? (incl. shipping_methods?: [method ids]), combinable?, priority?, starts_at?, ends_at?})
GET/PATCH/DELETE /api/v1/discounts/{id}   read / partial update / delete (409 has_redemptions — archive instead)
POST   /api/v1/discounts/bulk      {ids, action: pause|resume|archive|delete}
GET    /api/v1/discounts/{id}/redemptions   who used it: order_id, email, amount, created_at (newest first)
POST   /api/v1/discounts/validate  {code, subtotal?, email?, country?} → {valid, reason?, discount?} — dry-run a code the way the cart would; omit subtotal to check eligibility only (discount.amount comes back 0), pass subtotal (minor units) to get the figure
GET    /api/v1/suppliers           list suppliers (sort: name); who this store buys from — name, provider ('manual' or 'aliexpress', default 'manual'), contact_email, notes; the credential fields below are NEVER included in this list or the single-supplier GET
POST   /api/v1/suppliers           create a supplier ({name} required, 1-200 chars; contact_email optional, validated; notes optional, up to 2000 chars; provider optional, 'manual' or 'aliexpress', defaults 'manual')
GET    /api/v1/suppliers/{id}      one supplier
PATCH  /api/v1/suppliers/{id}      partial update (send only changed fields: name, provider, contact_email, notes)
DELETE /api/v1/suppliers/{id}      delete; any product naming this supplier keeps selling — its supplier_id goes null (ON DELETE SET NULL), the product itself is never touched; its stored credential (below), if any, is deleted with it (ON DELETE CASCADE)
GET    /api/v1/suppliers/{supplierId}/credentials  whether THIS supplier has a stored AliExpress credential: configured, app_key, expires_at, timestamps ONLY — app_secret and access_token are NEVER returned by any endpoint, there is no read-back call; NOT readable by a read-only PAT (403 read_only_token)
PUT    /api/v1/suppliers/{supplierId}/credentials  store (create or replace) this supplier's AliExpress credential; body is exactly {app_key, app_secret, access_token}, every field a non-empty string ≤500 chars, no control characters; unknown field is a 400 unknown_field:<name>; 400 supplier_has_no_adapter on a 'manual' supplier (there is no adapter to use a credential with); success body is {"success": true, "configured": true} and nothing more; 503 supplier_credentials_unavailable until the platform encryption key is configured
DELETE /api/v1/suppliers/{supplierId}/credentials  clear this supplier's stored credential ({"success": true, "configured": false, "removed": true|false}, never a 404 for "nothing to delete")
POST   /api/v1/suppliers/{supplierId}/verify       "Test connection" — makes ONE real call to AliExpress with the stored credential; {"success": true} on a genuine reply, or {"success": false, "error": "verification_failed", "message": <provider's own text, capped, credential stripped out>} on any rejection — NEVER a 5xx for a bad credential; 400 supplier_credentials_not_configured if nothing is stored, 503 supplier_credentials_unreadable if the stored credential cannot be decrypted (e.g. the platform key rotated since it was saved), 400 supplier_has_no_adapter on a 'manual' supplier. **Do not tell a store owner AliExpress is "connected" on the strength of a saved credential alone — say so only once this has actually returned {"success": true}.**
POST   /api/v1/suppliers/{supplierId}/sync         pull current cost and stock from AliExpress onto this supplier's LINKED products (supplier_external_id set) — see SYNC below for what it writes, its batch size, and why nothing is ever scheduled
GET    /api/v1/orders              list orders, NEWEST FIRST, all statuses by default — ?status=pending_payment|paid|processing|shipped|completed|cancelled|refunded|all, ?limit= (1-100, default 50), ?offset=
GET    /api/v1/orders/{id}         one order + its items; items are purchase-time SNAPSHOTS (name, unit_price, and the TAX ENGINE four: tax_amount, tax_rate_bp, tax_class_slug, tax_jurisdiction_id) — later product edits never change them; the order carries tax_breakdown (parsed object), tax_provider and tax_adjustment — see TAX ENGINE below; also payments: the order's payment rows (payments[].kind tells a charge from a refund/orphan/orphan_refund row, and payments[].refunds_payment_id names the payment a refund row refunds; payments[].id is the paymentId for the PATCH below) and refundable_amount: minor units still refundable, derived on every read; also each item's cost_snapshot and margin, and the order's own margin object — OPERATOR-ONLY, see cost/margin below; also the discount snapshot — discount_total, discounts (the list that applied; shipping: true = delivery waived, shipping_amount still the method's price) and each item's discount_snapshot (its share of the goods discount; margin is net of it) — render it, never recompute; also sources — OPERATOR-ONLY, see sourcing below
PATCH  /api/v1/orders/{id}         move the order through its lifecycle: {status} only — processing|shipped|completed|cancelled|refunded; illegal moves are a 409; NEVER "paid" (that is the payments PATCH below); cancelled/refunded return TRACKED stock exactly once (an untracked product, stock null, stays untracked); "refunded" on an order whose charge is a payplus one is a 409 until confirmed refunds cover the captured amount — the money moves ONLY through the refunds POST below, never by marking the status
PATCH  /api/v1/orders/{orderId}/payments/{paymentId} record that the money arrived: {status: "received", reference?} — the payment goes received, the order goes pending_payment → paid; ALSO the release for a refund reservation stranded pending (kind refund OR kind orphan_refund) after checking the provider's dashboard: {status: "failed"} (money never moved — balance returns, no reference allowed) or {status: "received", reference} (it moved — the provider's own REFUND reference, required); "refunded" is never settable here — an orphan row's money goes back through the refunds POST below with payment_id, and the orphan row itself never mutates
POST   /api/v1/orders/{orderId}/refunds refund a settled payplus charge — or, with {payment_id}, ORPHAN money (see below): {amount} in minor units, or {} for the full remaining balance — amount above refundable_amount is a 400 and the gateway is never called; the row is reserved (kind refund, status pending) before the gateway call, confirmed received on success, and marked failed ONLY on a DEFINITIVE gateway refusal (failed rows hold no balance). An AMBIGUOUS failure — a 5xx, a timeout, or a refunded amount coming back different from the one asked for — leaves the row pending on purpose, because nobody knows whether the money moved; a lingering pending row blocks all further refunds until it is reconciled with the provider and released with the payments PATCH above. Never tell a merchant to retry a 502 from this endpoint: read the order back, and if the refund row is still pending the money may already be gone; a partial refund leaves the order paid, a full one moves it to refunded and restocks; offline charges are a 409 (refund out-of-band, then PATCH the order). ORPHAN money (a kind orphan row — a verified extra payment on an already-settled order) is refunded through this same endpoint with {payment_id} naming that row (+ optional {amount}): same reserve-first guard and ambiguous-failure handling, rows carry kind orphan_refund, the gateway is called against the ORPHAN row's own transaction uid, and the order's status NEVER moves. The orphan balance is its own AND it is PER ROW: what one orphan still holds is its own amount minus the non-failed orphan_refund rows naming it (refunds_payment_id), so each orphan on an order is refundable exactly once, up to what it took; orphan activity never changes refundable_amount in either direction. {payment_id, reference} instead RECORDS a return the merchant already made in the provider's dashboard (orphan_refund row lands received with that reference; no gateway call; reference without payment_id is a 400). A 200 for an orphan refund returns orphan_outstanding instead of refundable_amount. An order holding several received orphans is refunded row by row, each against its own balance; the one 409 left is an order carrying a non-failed orphan_refund whose refunds_payment_id is null (only a pre-0033 row) — nothing can say which orphan it returned, so no orphan there may be targeted; resolve in the provider's dashboard. An out-of-band record is FINAL: it consumes the outstanding balance and cannot be undone
GET    /api/v1/payment-methods     list payment methods (sort_order, then name); ALL rows, disabled included — the operator view, not the checkout offer
POST   /api/v1/payment-methods     create ({provider, name} required; instructions null, enabled 1, sort_order 0 by default)
GET    /api/v1/payment-methods/{id} one method
PATCH  /api/v1/payment-methods/{id} partial update (send only changed fields); an unknown field is a 400 unknown_field:<name>, never ignored
DELETE /api/v1/payment-methods/{id} delete; past payments keep their provider/name snapshots, their method_id goes null
GET    /api/v1/shipping-zones      list shipping zones (sort_order, then name); ALL rows, disabled included — matched against a shopper address at checkout by country then region, most specific wins
POST   /api/v1/shipping-zones      create ({name, countries} required; countries is '*' or a comma-separated list of ISO 3166-1 alpha-2 codes, case-insensitive on input and upper-cased on write — a country NAME like "Israel" is a 400, not stored; regions optional/comma-separated, null = whole country; enabled 1, sort_order 0 by default)
GET    /api/v1/shipping-zones/{id} one zone
PATCH  /api/v1/shipping-zones/{id} partial update (send only changed fields); an unknown field is a 400 unknown_field:<name>, never ignored
DELETE /api/v1/shipping-zones/{id} delete; its methods are deleted with it (cascade) — any order that used one keeps its own shipping_label/shipping_amount snapshot and just has shipping_method_id set to null
GET    /api/v1/shipping-methods    list shipping methods across all zones (sort_order, then name); ALL rows, disabled included
POST   /api/v1/shipping-methods    create ({zone_id, name} required; zone_id MUST name a shipping zone belonging to this store — a non-existent id or another store's zone id is a 400, never a foreign-key error; description null, price 0, free_over null, enabled 1, sort_order 0 by default; price/free_over are integer minor units — a float or negative value is a 400)
GET    /api/v1/shipping-methods/{id} one method
PATCH  /api/v1/shipping-methods/{id} partial update (send only changed fields), including re-pointing zone_id at a different zone of the SAME store (validated the same way as create); an unknown field is a 400 unknown_field:<name>, never ignored
DELETE /api/v1/shipping-methods/{id} delete; any order that used it keeps its own shipping_label/shipping_amount snapshot and just has shipping_method_id set to null
GET    /api/v1/gateway-credentials  which gateway credentials are configured: provider, mode, timestamps ONLY — stored credentials are NEVER returned by any endpoint, there is no read-back call; NOT readable by a read-only PAT (403 read_only_token)
PUT    /api/v1/gateway-credentials/{provider}?mode=test|live  store (create or replace) a provider's credentials for one mode; body is the provider's exact field set (payplus: api_key+secret_key+payment_page_uid; hyp: user+password; bank_transfer/cash_on_delivery: {}), every field a non-empty string ≤500 chars; unknown field is a 400 unknown_field:<name>; success body is {"success": true, "configured": true} and nothing more; 503 gateway_credentials_unavailable until the platform encryption key is configured
DELETE /api/v1/gateway-credentials/{provider}?mode=test|live  delete that provider+mode's stored credentials (404 if none)
GET    /api/v1/tax/classes         this store's tax classes (sort_order, then id) — always at least `standard` and `zero`; {data, total}; an empty list while the store is finishing the tax-engine upgrade
POST   /api/v1/tax/classes         create a class: {slug (1-40 of a-z 0-9 -, IMMUTABLE), name (1-80), product_tax_code? (provider category code, ≤40, null = provider default), sort_order?}; 409 class_exists on a duplicate slug; 503 tax_rules_unavailable mid-upgrade; audited tax.class.create
GET    /api/v1/tax/classes/{id}    one class (another store's id is a plain 404)
PATCH  /api/v1/tax/classes/{id}    partial update of name, product_tax_code, sort_order — slug is 400 unknown_field:slug; audited tax.class.update
DELETE /api/v1/tax/classes/{id}    delete an unused class: `standard`/`zero` are 400 class_protected; a class that products or rates still name is 409 class_in_use {products, rates} — re-point them first; past orders only carry the slug and never block; audited tax.class.delete
GET    /api/v1/tax/jurisdictions   this store's jurisdictions, each with rates: [{class_id, class_slug, rate_bp, applies_to_shipping}] (sort_order, then id; disabled rows included); {data, total}
POST   /api/v1/tax/jurisdictions   create: {name, country (ISO alpha-2, any case), region_code? ("TX" / "US-TX" / "Texas" → US-TX; null = whole country; a country with no subdivision list takes null only), enabled? (0|1, default 1), sort_order?, rates?: [{class_id, rate_bp (0-10000), applies_to_shipping? (0|1, default 1)}]}; 409 jurisdiction_exists on the same (country, region); 400 invalid_tax_class / invalid_rate on the rate set; audited tax.jurisdiction.create
GET    /api/v1/tax/jurisdictions/{id}   one jurisdiction with its rates
PATCH  /api/v1/tax/jurisdictions/{id}   partial update of name, country, region_code, enabled, sort_order — the region is re-resolved against the country the row will have (moving the country keeps the region only if it still belongs; send region_code: null otherwise); `rates` is 400 unknown_field:rates here; audited tax.jurisdiction.update
DELETE /api/v1/tax/jurisdictions/{id}   delete it AND its rates; past orders keep their tax_jurisdiction_id snapshot (no FK) and never block; audited tax.jurisdiction.delete
PUT    /api/v1/tax/jurisdictions/{id}/rates   REPLACE the rate set with the body array [{class_id, rate_bp, applies_to_shipping?}] — [] clears it (registered at 0%); one transaction, so a refused set (400 invalid_tax_class for a class that is not this store's, 400 invalid_rate for rate_bp outside 0-10000, a non-integer, a duplicate class, a stray key or a non-array body) leaves the old set untouched; returns {success, id, rates}; audited tax.rates.replace
GET    /api/v1/tax/registrations  this store's MERCHANT TAX REGISTRATIONS — what authorises it to charge tax anywhere; {data, total}, ordered kind then country then id, rows outside their window included and flagged active: false; empty (never 503) during the upgrade window
POST   /api/v1/tax/registrations  declare one: {kind ("country"|"oss"), scheme, country, number, name?, valid_from?, valid_to? (YYYY-MM-DD or unix seconds; valid_to EXCLUSIVE)} — kind/scheme/country/number all required; 201 with the whole Registration; 400 invalid_kind / invalid_scheme / invalid_country / invalid_number (with `reason`, the scheme's expected format) / invalid_name / invalid_window / unknown_field:<name>; 409 registration_exists (an existing row for that country OVERLAPS the window given — successive, non-overlapping periods are fine — or the store already has an OSS row); 503 registrations_unavailable during the window; audited tax.registration.create
GET    /api/v1/tax/registrations/{id}   one registration
PATCH  /api/v1/tax/registrations/{id}   partial update — the body is MERGED onto the stored row and the WHOLE result re-validated, so a PATCH can never write a row a POST would have refused (sending only `country` on a row whose number belongs to the old one is 400 invalid_number, not a half-edit); `kind` is immutable (400 unknown_field:kind); the row never collides with itself; audited tax.registration.update
DELETE /api/v1/tax/registrations/{id}   delete it and NOTHING else — jurisdictions, rates and past orders' snapshots are untouched; the store simply stops charging where this row was the authority (see MERCHANT TAX REGISTRATIONS below); audited tax.registration.delete
GET    /api/v1/tax/provider-credentials   whether a TaxJar token is stored, per mode: {provider: "taxjar", configured: {test, live}} — the token is NEVER returned by any endpoint, there is no read-back call; NOT readable by a read-only PAT (403 read_only_token)
PUT    /api/v1/tax/provider-credentials   store (create or replace) the TaxJar token for one mode: exactly {provider: "taxjar", mode: "test"|"live", api_token} (non-empty, ≤500 chars); unknown field is a 400 unknown_field:<name>; success body is {"success": true, "configured": true} and nothing more; 503 gateway_credentials_unavailable until the platform encryption key is configured; audited tax.credentials.set (provider + mode only, never the token)
DELETE /api/v1/tax/provider-credentials?mode=test|live   delete the stored token for that mode (404 if none); audited tax.credentials.delete
POST   /api/v1/tax/preview         DRY-RUN the tax engine: {address: {country, region_code?, postcode?}, lines: [{amount (minor units, net of discounts), tax_class_id?}], shipping? (minor units), customer_type? (individual|business), tax_id_valid_country? (simulate a valid eu_vat ID from that country — how reverse charge is previewed), exemption_country? + exemption_region_code? (simulate an APPROVED exemption certificate for that country / subdivision — how `exempt` is previewed; exemption beats reverse charge)} → the engine result (amount, bp, total, treatment, jurisdiction {basis, country, region_code, id}, provider (local|taxjar|local_fallback), fallback_reason, lines[] {id, amount, charged, rateBp, classSlug, jurisdictionId, tax}, shippingTax, shippingSplit, adjustment, breakdown — the same object an order's tax_breakdown holds); TaxJar is called for real when configured, nothing is written and nothing is audited (a provider failure quotes local as local_fallback with NO audit row); validates like checkout (400 invalid_tax_class for a class that is not this store's); a full-access token is required — the middleware treats every POST as a write
GET    /api/v1/email-credentials   whether this store has a connected Brevo account: configured, from_address, from_name, timestamps ONLY — the API key is NEVER returned by any endpoint, there is no read-back call; no master-key gate, so this always answers even before the platform key is configured; NOT readable by a read-only PAT (403 read_only_token)
PUT    /api/v1/email-credentials   connect (or replace) this store's own Brevo account; body is exactly {api_key, from_address, from_name?} — unknown field is a 400 unknown_field:<name>; the key is verified against Brevo BEFORE it is stored (invalid_api_key if Brevo rejects it, sender_not_verified if from_address is not a verified sender on that account, verification_unavailable (503) if Brevo cannot be reached); success body is {"success": true, "configured": true} and nothing more; 503 email_credentials_unavailable until the platform encryption key is configured
DELETE /api/v1/email-credentials   disconnect this store's Brevo account (removed: false, not an error, if nothing was configured); no master-key gate — clearing it decrypts nothing
GET    /api/v1/customers           list shopper accounts, NEWEST FIRST, active and disabled alike; rows carry id, email, name, phone, status, email_verified_at, created_at, updated_at plus customer_type, tax_status (best across the customer's tax IDs: valid > manual_review > unavailable > unverified > invalid, else none) and company (business legal_name) — NEVER password_hash; C2 (1.23.0): rows also carry tags (names, []) and pending_exemptions (count, 0); filters ?tag=<slug> (unknown tag → empty page) and ?pending_exemptions=1 (both empty pre-0227/0230, never a 503); A1 (1.24.0): rows also carry deletion_requested_at (null when none / pre-0235) and gated (same rule as the detail's gated, from the store switch + stamp read once per request; false pre-0237) — the admin's "Unverified" badge is `gated`, NOT `email_verified_at IS NULL`
GET    /api/v1/customers/{id}      one shopper in full: identity + profile {customer_type, business_verification, default_shipping_address_id, default_billing_address_id, preferred_language, preferred_currency, operator_notes} + business {legal_name, trading_name, registration_number, country, address_id, website, contact_name, contact_phone} + tax_ids (MASKED) + addresses + orders_count / total_spend (orders whose status is not cancelled, refunded or pending_payment); profile is null and tax_ids [] only on a tenant still finishing migration 0177 — the GET never 503s; C2 (1.23.1) adds exemptions (the list above, with operator document URLs) and tags (names) — BOTH are null on a tenant that predates their table (0227 / 0230; the admin hides the card and the tags editor), [] when present and empty; A1 (1.24.0) adds pending_email, deletion_requested_at and gated (true = the shopper must verify their email before member checkout / tax writes; always false pre-0237)
PATCH  /api/v1/customers/{id}      any of {status: "active"|"disabled", customer_type: "individual"|"business", business_verification: "manually_verified"|"self_declared", operator_notes: text|null} — disabling kills EVERY live storefront session immediately, and re-enabling does NOT revive them (the shopper logs in again); idempotent; unknown field is a 400 unknown_field:<name>; bad enum is 400 invalid_customer_type / invalid_business_verification; profile fields are 503 customer_profiles_unavailable pre-0177 (status alone still works); C2 (1.23.0): tags: [names] | null REPLACES the customer's operator-only tag set (same normalisation and 30-tag / 40-char limits as product tags; unknown names create store tags; null or [] clears; 503 customer_tags_unavailable pre-0230) and the response carries tags; audited as customer.profile.update (the tag names in details)
GET    /api/v1/customers/{id}/tax-ids            the customer's tax IDs, newest first, value MASKED (DE12••••89)
POST   /api/v1/customers/{id}/tax-ids            add one on the shopper's behalf: exactly {type, country, value} — runs the same pipeline as the shopper's add (format → duplicate → provider per the store's tax_id_verification); 201 {tax_id (masked), verification: {status, name}} — name is VIES's registered name, shown once, never stored; 400 invalid_tax_id (+ reason), 409 tax_id_exists
GET    /api/v1/customers/{id}/tax-ids/{tid}      the ONE unmasked read — the full value; use it only when the operator needs the value itself; NOT readable by a read-only PAT (403 read_only_token) — the masked value on the list above is, and is usually what you want
PATCH  /api/v1/customers/{id}/tax-ids/{tid}      operator override: exactly {status: "valid"|"invalid"|"manual_review"} → provider "operator"; valid also stamps verified_at and lifts business_verification to tax_id_verified; audited as customer.tax_id.override
POST   /api/v1/customers/{id}/tax-ids/{tid}/verify   re-run the provider now (no body, no rate limit for operators) and persist the verdict; audited as customer.tax_id.verify
DELETE /api/v1/customers/{id}/tax-ids/{tid}      remove it; orders keep their own tax_id_snapshot; audited as customer.tax_id.delete
GET    /api/v1/customers/{id}/exemptions         the customer's tax exemptions, newest first, {data: [Exemption], total} — {data: [], total: 0} pre-0227; read-only tokens may GET
POST   /api/v1/customers/{id}/exemptions         create one on the customer's behalf (submitted_by "operator"): JSON {type: resale|nonprofit|government|diplomatic|other, country, region_code?, certificate_number, issuer?, expires_at? (YYYY-MM-DD), status?: "pending" (default) | "approved"} — no file needed (operator-vouched) — OR multipart/form-data with the same fields plus `document` (PDF/JPEG/PNG/WebP ≤ 8 MB); status "approved" skips review (reviewed_by = you, D5 ladder bump); 201 Exemption; 400 invalid_status / invalid_type / invalid_country / invalid_region / invalid_certificate_number / invalid_issuer / invalid_expires_at / expires_in_past / document_type_unsupported / document_too_large; 409 exemption_exists (a pending or approved row already covers that country + region); 503 exemptions_unavailable pre-0227; audited customer.exemption.create
GET    /api/v1/customers/{id}/exemptions/{eid}   one exemption (bare Exemption shape); another customer's id is a 404 "Exemption not found"
PATCH  /api/v1/customers/{id}/exemptions/{eid}   REVIEW: {status: "approved"|"rejected"|"revoked", review_note? (≤500, shown to the shopper on rejected/revoked), expires_at? (ONLY with approved: sets, null clears, absent keeps)} along pending → approved|rejected, approved → revoked, rejected → approved; anything else 400 invalid_transition (revoked is final — create a new row); approving with a past/today expiry is 400 expires_in_past; approval lifts business_verification to document_verified when below; audited customer.exemption.approve|reject|revoke
DELETE /api/v1/customers/{id}/exemptions/{eid}   delete the row AND its certificate object; placed orders keep their exemption_snapshot; {success, id}; audited customer.exemption.delete
GET    /api/v1/customers/{id}/exemptions/{eid}/document   download the certificate (attachment, private/no-store, content-type = the stored type); 404 when the row has no document; read-only tokens may GET
PUT    /api/v1/customers/{id}/exemptions/{eid}/document   attach or REPLACE the certificate: multipart `document` only; the old object is deleted; 400 document_required / document_type_unsupported / document_too_large; 503 document_store_unavailable (row untouched); audited customer.exemption.document_replace
GET    /api/v1/customers/{id}/addresses          the shopper's address book, READ ONLY (name, company, phone, region_code, kind alongside the six address fields; is_default = default shipping, the default billing address is profile.default_billing_address_id)
POST   /api/v1/customers/{id}/verify             force-verify the email address (A1): {success, email_verified_at} — idempotent, a repeat echoes the ORIGINAL stamp; lifts `gated`; audited customer.verify.force
POST   /api/v1/customers/{id}/resend-verification   mail a fresh verification link (A1): {success, sent} — sent false when the store has no email credentials or Brevo refused; 409 already_verified once verified; no operator limiter; audited customer.verify.resend
POST   /api/v1/customers/{id}/cancel-deletion    cancel the shopper's pending deletion request (A1): {success}; clears deletion_requested_at and kills the shopper's cancel link; 409 not_pending when nothing is pending; audited customer.deletion.cancel
GET    /api/v1/customers/{id}/export             the shopper's data-export document (A1, D9), byte-identical to the shopper's own /account/export: identity, profile, business, addresses, tax IDs UNMASKED, exemptions with certificate links, every order with items, reviews, plus (spec 1.38.0, P9) form_submissions (their contact-form enquiries, matched case-insensitively on the address — user_agent included, ip_hash never), privacy_requests (their DSAR register rows, without subject_email_hash), tags (operator-applied labels) and consent_records — consent_records is ALWAYS [] on this operator route, because the consent ledger is keyed to a hash of the shopper's own consent cookie and has no account link; only the shopper's own /account/export can return those rows — as an attachment (private, no-store); NOT readable by a read-only PAT (403 read_only_token) — this used to say "read-only tokens may GET" and the P5 authorization layer narrowed it, because the document carries every tax ID UNMASKED; audited customer.export {customer_id}
GET    /api/v1/settings            the store's settings: exactly 44 writable fields (identity, contact, currency/locale/timezone, tax, shipping, checkout, email, email log retention, analytics, gateway_mode, theme, PDP trust strip + policy HTML, customers + tax identity, tax engine, email verification) plus the read-only email_verification_since
PATCH  /api/v1/settings            partial update of those 44 fields (email_verification_since is read-only → 400 unknown_field); any other key in the body is a 400 unknown_field:<name>, never ignored
GET    /api/v1/settings/privacy-jurisdictions   the PRIVACY JURISDICTIONS the merchant declares itself subject to (P6): {data: [{jurisdiction_id, basis, declared_at}], available: [{id, name}]} — `data` is the merchant's own assertion, treated by the privacy engine as an authoritative `configured` signal; `available` (P10 task 7) is every id+name the PUT below will accept, straight from the same ledger table it validates against; neither is personal data
PUT    /api/v1/settings/privacy-jurisdictions   REPLACE the set with {jurisdictions: [{jurisdiction_id, basis? ('manual' default | 'threshold_test')}]} — ids left out are withdrawn (audited privacy.jurisdiction.withdraw), new ids or a changed basis declared (audited privacy.jurisdiction.declare), unchanged rows untouched, [] clears; every id is checked against the jurisdiction ledger and the WHOLE request is refused on the first unknown one (400 unknown_jurisdiction:<id>, nothing persists) — a typo'd US-XX never lands; also 400 unknown_field / invalid_jurisdiction / invalid_basis:<id> / duplicate_jurisdiction:<id>
GET    /api/v1/api-tokens          list this store's personal access tokens — prefix, name, readOnly, expiresAt, lastUsedAt, revoked; same camelCase envelope as the CMS (references/api-tokens.md); works with a PAT, for audits
POST   /api/v1/api-tokens          403 session_required via PAT — the operator mints tokens in the admin UI at https://<tenant>/admin/settings/api-tokens (same URL on both products)
DELETE /api/v1/api-tokens/{id}     403 session_required via PAT — revoke in the same admin UI
GET    /api/v1/email-log           this store's mailer activity: `?order_id=N` returns that order's own log rows (`entries`, newest first); no parameter returns a store-wide summary (`summary` counts by status, `last_attempt`, up to 50 `recent_failures`); a malformed `order_id` is a 400; `message_id` is NEVER returned by either shape
```

**EVERY LIVE PRODUCT HAS A CATEGORY.** A product with status `active` must
belong to at least one category: POST refuses `status: active` without
`categories` (400), and PATCH refuses a write that sets status active, or
rewrites `categories`, when the result would leave an active product bare —
membership a smart category holds counts. Drafts and archived products may
be uncategorized. So: create as a draft, pick categories, then go active —
or send both in one PATCH. **TAGS** are free-form labels (`tags: [names]` on a
product; created on first use, matched by slug); shoppers browse them at
/tags/{slug}, and a smart category can match `{field: "tag", op: "has",
value: "summer"}`.

**PRODUCT DETAIL FIELDS.** A category's `field_presets` are the questions
every product listed in it — or in any subcategory — is asked (Mobile phones
→ screen_size number "in", storage select, 5g boolean). A product's answers
live in its `custom_fields` object, keyed by the preset keys; any other key is
an ad-hoc field of that product alone. Types: text, textarea, number (+unit),
select (+options), boolean, url. To fill a product's details: GET its
categories' field_presets (walk parent_id up — presets inherit, root wins on a
duplicate key), then PATCH the product with the WHOLE custom_fields object
(it replaces). The storefront lists them under Specifications on the product
page (fields with storefront:false stay operator-only). `required` is an
admin-side publish gate, not enforced by the API.

**SMART CATEGORIES.** A category with `rules` is automatic: its products are
exactly those matching `{match: all|any, conditions: [{field, op, value}]}`
(fields: name, price, compare_at_price, stock, featured, on_sale,
product_type, status, supplier_id, created_days_ago; money in minor units).
Membership is materialized when the rules are saved and re-checked for a
product on every product create/edit — so never "add a product to" a smart
category by hand (the bulk endpoint refuses, 409); change the product or the
rules instead. Preview a rule set with POST /categories/rules/preview before
saving it. **Per-category order:** PUT /categories/{id}/products sets the order
shoppers see inside THAT category (the storefront's default "Recommended"
sort); the product's own sort_order is the fallback. **Primary category:** a
product in several categories has one primary (primary_category_id) — the
storefront breadcrumb and category-nav highlight follow it.

**DISCOUNTS.** A discount with a `code` is a coupon the shopper types; one
without is AUTOMATIC and applies to every qualifying cart on its own.
`kind` sets what `value` means: percent → basis points (1000 = 10%), fixed →
integer minor units spread across the eligible lines (largest remainder),
free_shipping → value 0 (waives the chosen method's price at checkout).
`scope` is `{type: order}` (default), `{type: products, ids}`,
`{type: categories, ids, include_children?}` or `{type: tags, slugs}` — every
id/slug must be this store's (400 `scope ids not found`). `conditions` is an
object of optional rules: min_subtotal, min_quantity (over eligible lines),
countries (ISO-2; pending until the shopper enters an address), customer
(anyone|signed_in|first_order|listed + customer_emails), per_customer_limit
(by email), total_limit (against usage_count). `combinable: false` makes the
discount apply alone when it wins (priority, then amount); a paused/archived
or out-of-window discount is never evaluated. Effects are never stored on the
cart — they are recomputed on EVERY cart read against the live lines, so a
code that stops qualifying shows up in the cart's `discounts.rejected` with
its reason. Tax is charged on the discounted goods. Caps are enforced again
inside the checkout write (a code can't be over-redeemed by two carts
racing), and each use lands in /discounts/{id}/redemptions and bumps
usage_count — never write usage_count yourself (400). An order's `total =
subtotal − discount_total + shipping_amount + exclusive tax`; the order keeps
its own snapshot (`discounts`, per-item `discount_snapshot`) — render that,
never recompute. To change `value`, send `kind` with it. `kind: bxgy` is
Buy X get Y: `reward.buy` (a scope plus `quantity` or `spend` in minor units)
is what the cart must hold, `reward.get` (scope, `quantity`, `percent` in bp —
10000 = free) is what comes off; the row's own value is forced to 0 and scope
to order, `repeats` (default true) rewards every full set, `max_rewards` caps
the units. Rewards go to the CHEAPEST un-rewarded units in get.scope, and
when buy and get share a scope a unit is either bought or rewarded, never
both (buy 2 get 1 needs 3 in the cart). POST /discounts/validate answers
ELIGIBILITY only for a bxgy code — amount comes back 0 with a `note`; the
shopper's cart shows the real reward. A DELIVERY discount is a percent/fixed
row with `applies_to: shipping` (refused on bxgy/free_shipping; sent alone on
PATCH the stored kind stands in): it comes off the delivery price the shopper
is actually charged — after free_over and any earlier shipping discount —
capped at that price, and lands in the order's `discounts` as a
`shipping: true` entry (amount 0 when delivery was already free). The
`conditions.shipping_methods` rule ([ids of this store's shipping methods],
400 `shipping method ids not found`) works on ANY kind: the code is pending
until the shopper chooses one of those delivery options and rejected for any
other — so POST /discounts/validate always answers it valid:false,
pending:true. A product with `shipping_exempt: 1` (products API, not a
discount) never adds a delivery charge: free_over is judged on the non-exempt
goods and an all-exempt cart pays 0 delivery. Shoppers apply
codes through POST /api/shop/cart/discount {code} and DELETE
/api/shop/cart/discount/{code} — the cart's session/guest cookie world, NOT a
PAT surface; as an operator, dry-run a code with POST /discounts/validate.

Every `/api/v1` endpoint (users/me included) uses the same
`Authorization: Bearer epat_...` PAT auth as the CMS, with the same
read-only rule: a read-only token gets 403
`read_only_token` on any non-GET. A duplicate slug is a 409. Categories form
a tree via `parent_id` (integer id or null); `is_visible` is 0/1.
Categories writes return `{"success": true, "id", "slug"}`; GETs return
the raw row / array of rows. Other endpoints vary: settings PATCH returns
`{"success": true}` alone; product/order/payment PATCH return an updated
row without a `success` wrapper; error responses across the surface use
`{"success": false, "error": "..."}`. Check per-endpoint response shape.

Product money — `price` and `compare_at_price` — is INTEGER MINOR UNITS
(1999 = 19.99 in the product currency). A float or negative is rejected with
400, never rounded: multiply before sending, divide when displaying.
`currency` must be a 3-letter uppercase ISO 4217 code (anything else is a
400) and defaults to the store's own currency when omitted on create. A new
product defaults to `status: "draft"`, which the default product list does
NOT show — pass `status: "active"` (and leave `visible` alone) to make it
live, and use `?status=all` when auditing the whole catalogue. Product
`visible` and `featured` are 0/1.

CUSTOMER TAX IDENTITY (customer profile C1, spec 1.21.0). A customer is
`individual` or `business` (`customer_type`, stored on the profile, never
inferred from a company name). A tax identifier is a ROW, not a column —
many per customer, each `{type, country, value, status}`: types are `eu_vat`
(VAT ID — EU + XI, the only VIES-verifiable kind), `gb_vat` (VAT number),
`au_abn` (ABN, checksummed), `ca_bn` (Business number), `in_gstin` (GSTIN,
checksummed), `us_ein` (EIN), `il_company` (Company number), `nz_gst` (GST
number), `ch_uid` (UID) and `other` (Tax ID); the `label` on every row is
that human name, and a type that does not apply to the given country is a
400 `invalid_tax_id` (the `reason` sentence names the label, never the
value). `status` is SERVER-SIDE ONLY — the shopper adds and removes IDs and
never sets it: `unverified` (format passed, no provider check — every
non-EU type, or a store with `tax_id_verification: "format_only"`),
`valid` / `invalid` (the provider's verdict), `unavailable` (VIES could not
answer — the row is KEPT and retried, and it never blocks a save or a
checkout), `manual_review` (an operator parked it). `provider` says who
decided: `format`, `vies`, or `operator`. What an operator may do: override
to `valid`, `invalid` or `manual_review` (PATCH …/tax-ids/{tid}), re-run
the provider (POST …/verify), add or delete rows, and set
`business_verification` to `manually_verified` or back to `self_declared`
— the other states (`unverified` → `self_declared` on the first business
save → `tax_id_verified` when an ID reaches valid; `document_verified` is
C2) are the pipeline's and never move DOWN automatically. MASKING: every
LIST (customer detail, …/tax-ids, the admin table) shows `DE12••••89` —
first 4, ••••, last 2 — and the audit log records only the masked form;
the full value is on `GET …/tax-ids/{tid}` and on the order that used it
(`tax_id_snapshot`). VIES: with the default `tax_id_verification: "vies"`
an `eu_vat` ID is POSTed to the EU VIES REST API with a 4 s timeout; its
registered `name` is returned once in `verification` for confirmation and
never stored. Orders snapshot the facts checkout used (`customer_type`,
`tax_treatment` — `reverse_charge` needs a business customer with a valid
`eu_vat` ID in a different EU country than the store's `origin_country` —
`tax_jurisdiction`, `tax_id_snapshot`) and are never rewritten by later
profile edits. The six settings: `allow_business_customers`,
`require_company_for_business`, `require_phone_at_checkout` (0/1, no
boolean coercion), `tax_id_verification` (`vies` | `format_only`),
`tax_address_basis` (`shipping` | `billing` — which address decides the
taxable jurisdiction), `origin_country` (ISO alpha-2 or null; null
disables reverse charge). Shopper side (session + CSRF, action-style
POSTs): `GET/POST /api/shop/profile` (`{action: "update", …}`),
`GET/POST /api/shop/business` (`{action: "save", legal_name, …}`),
`GET/POST /api/shop/tax-ids` (`{action: "add", type, country, value}` /
`{action: "delete", id}`) — the shopper's own list is unmasked; a business
action while `allow_business_customers` is 0 is 403
`business_customers_disabled` there, and 400 with the same code at
checkout.

TAX EXEMPTIONS AND CUSTOMER TAGS (C2, spec 1.23.0). A tax EXEMPTION is a
certificate (resale, non-profit, government, diplomatic, other) scoped to a
`country` plus an optional `region_code` (ISO 3166-2, resolved like the
address forms: "TX" / "US-TX" / "Texas"; a country with no subdivision list
takes null only) with a `certificate_number`, optional `issuer` and optional
`expires_at`. Shoppers submit one from `/account/business` with the file
(required for them; `POST /api/shop/exemptions`, multipart, action `add`;
`{action: "delete", id}` withdraws a PENDING row only; the shopper shape
never carries `reviewed_by`, only `review_note`); operators create,
review, revoke and delete through `/api/v1/customers/{id}/exemptions` and may
create WITHOUT a file (operator-vouched). WHAT IT DOES: an APPROVED, unexpired
exemption whose country (and region, when set) matches the order's taxable
address makes the order `exempt` — tax 0, `exemption_snapshot` {id, type,
country, region_code, certificate_number, expires_at} on the order, the
receipt prints "Tax exempt — certificate <number>"; it BEATS reverse charge
when both apply; on an inclusive store the net is charged and
`tax_adjustment` is owed (T1's zero-treatment rule). A mismatched country /
region, or a pending / rejected / revoked / expired row, changes nothing.
STATUS is stored, EXPIRY is lazy: `status` ∈ pending | approved | rejected |
revoked never flips by itself; every reader adds `effective_status`, which
reads `expired` for an approved row past `expires_at` (the last valid DATE,
exclusive — expired from 00:00Z of that day). TRANSITIONS (PATCH
…/exemptions/{eid}): pending → approved | rejected; approved → revoked;
rejected → approved (re-review); revoked is final; anything else is 400
`invalid_transition`. ONE LIVE ROW PER SCOPE: a second pending or approved
row for the same (country, region_code) is 409 `exemption_exists` — reject,
revoke or let it expire first. LADDER: approving (or creating with
`status: "approved"`) lifts `business_verification` to `document_verified`
when it is below — never down, `manually_verified` stays. DOCUMENTS: PDF,
JPEG, PNG or WebP up to 8 MB, sniffed (a renamed HTML file is 400
`document_type_unsupported` with `detail` `unsupported_type:unknown`; over the
cap is `document_too_large` with `detail` `too_large:<bytes>`); stored under a
PRIVATE prefix that the public media route refuses — the file never appears
on the media domain and the API never returns its key; download it ONLY
through `GET …/exemptions/{eid}/document` (operator; read-only tokens may)
or the shopper's own `/account/tax/exemptions/{id}/document`; replace it
with `PUT …/document` (multipart `document`; the old object is deleted).
Audit rows (`customer_exemption`: customer.exemption.submit | withdraw |
create | approve | reject | revoke | delete | document_replace) carry {customer_id,
exemption_id, type, country, region_code, status} — never the bytes or the
key. Preview an exemption without one on file: `POST /api/v1/tax/preview`
with `exemption_country` (+ `exemption_region_code`). CUSTOMER TAGS are
OPERATOR-ONLY labels ("VIP", "wholesale") on a shopper account, sharing the
store's tag rows with products: set the whole list with `PATCH
/api/v1/customers/{id} {tags: [...]}` (unknown names are created; null
clears), read them on the list rows and the detail, filter the list with
`?tag=<slug>`; the shopper never sees them. Pre-migration (0227–0231 still
running): lists answer `[]` / `0`, the shopper card is hidden, filters give
an empty page, and creates are 503 `exemptions_unavailable` /
`customer_tags_unavailable` — never a 500.

ACCOUNT INTEGRITY (A1, spec 1.24.0). EMAIL VERIFICATION is a store switch:
`PATCH /api/v1/settings {require_email_verification: 1}` stamps the read-only
`email_verification_since` ONCE (turning it off later clears nothing, turning
it on again keeps the first stamp). A shopper is GATED when the switch is on
AND their account was created at or after the stamp AND `email_verified_at`
is null — accounts that predate the stamp are never gated, guest checkout is
never gated. A gated shopper cannot place a member checkout, add a tax ID,
save a business profile or submit an exemption (403 `email_unverified`; the
storefront shows a banner with a resend button, 3 mails per hour); reads,
deletes, the cart and browsing are untouched. `GET /api/v1/customers/{id}`
reports `gated` and `email_verified_at` (the list rows carry `gated` too); WHEN A SHOPPER CANNOT RECEIVE THE
MAIL, `POST …/verify` force-verifies (audited) and lifts the gate at once,
`POST …/resend-verification` re-mails the link (409 once verified). WHAT
SHOPPERS DO THEMSELVES (never through a PAT — the operator has no write on
email, password or identity): change their password (every OTHER session
dies, a "secure my account" link goes to the address — using it kills every
session, voids an unconfirmed email change, mails a reset to THAT address
and restores it if it was changed meanwhile — so for 14 days a secure link
can restore the address it was mailed to, the same exposure as the revert
link; a revert or a completed password reset kills it), change their EMAIL (5
requests per hour; `pending_email` on the detail until the shopper confirms
from the NEW inbox; the OLD inbox gets a 14-day REVERT link that restores
the old address, kills every session, mails a password reset and locks
email changes for 24 h — so a support case "my email was changed and I did
not do it" is answered by the revert mail or the secure mail, and one email
change per revert window is the rule; a completed password reset also voids
an unconfirmed change), and request DELETION
(re-authenticated; refused 409 `open_orders` while an order is
pending_payment / paid / processing or a refund is pending; sessions die,
`deletion_requested_at` is stamped and the account is PURGED 14 DAYS LATER —
row gone, certificates gone, orders/reviews kept with the contact fields
anonymised as "Deleted customer" / deleted-<id>@anonymised.invalid). Signing
in again, the shopper's cancel link, or the operator's `POST
…/cancel-deletion` (409 `not_pending`) cancels it; after the purge nothing
can. EXPORT: `GET …/export` (full-access token only — a read-only PAT is 403
`read_only_token`) is the operator's copy of
the shopper's own download — the full account as one JSON attachment with
tax IDs unmasked; every export is audited (`customer.export`). Audit actions
to look for: customer.verify.force | verify.resend | deletion.cancel |
export (operator), customer.email.change_requested | confirmed | reverted,
customer.password.changed, customer.secured, customer.deletion.requested |
cancelled (shopper). Pre-migration (0232–0238 still running): every field
reads null / `gated: false`; the shopper's verify resend answers 503
`unavailable`, their email-change and deletion requests (and the operator's
resend-verification) 503 `account_tokens_unavailable` with nothing written;
a password change still works (its secure-link mail is skipped); force-verify
answers as usual and cancel-deletion is 409 `not_pending` — never a 500.

TAX ENGINE (T1, spec 1.22.0). Tax is resolved PER LINE from the store's own
rules, not from one flat rate. RESOLUTION: the taxable address (the store's
`tax_address_basis`, shipping by default) is matched against the store's
JURISDICTIONS (`/api/v1/tax/jurisdictions` — a country, or one ISO 3166-2
region of it; enabled rows only, region row over country row); the matched
row's RATE for the line's CLASS prices the line (a class the row has no rate
for falls to the row's `standard` rate; a row with no rates at all is
"registered at 0%"). CLASSES (`/api/v1/tax/classes`): every store has
`standard` (what a product with `tax_class_id: null` is) and `zero`
(zero-rated; TaxJar category 99999) — both protected — plus whatever the
operator adds (`reduced`, `books`, …); a product names one with
`tax_class_id`, a variant inherits its parent's, and order items snapshot the
EFFECTIVE slug (`tax_class_slug`) plus `tax_amount`, `tax_rate_bp` and
`tax_jurisdiction_id`. NO RULE for the address → `tax_no_rule_fallback`:
`flat` (default — the legacy `tax_rate`/`tax_shipping` stand in as a
synthetic home rule, so a store that never adds a jurisdiction behaves
exactly as before; the seeded "Home" jurisdiction IS that flat rate turned
into a row) or `none` (not registered there — no tax; the order's
`tax_breakdown.treatment` says `not_registered` while its `tax_treatment`
column reads `not_taxable`, the enum being fixed). exempt / reverse_charge
(CUSTOMER TAX IDENTITY above) are decided BEFORE the fallback. Shipping is
split across the order's rate groups in proportion to charged goods, and
each part is taxed only if that rate's `applies_to_shipping` is 1.
INCLUSIVE stores (`tax_inclusive: 1`) pick `tax_inclusive_mode`:
`fixed_gross` (default — the listed gross price is what the shopper pays,
the destination rate is extracted from it) or `fixed_net` (the net — list
price less the HOME rate, which is the Home jurisdiction's rate for the
line's class, else the legacy `tax_rate` — is fixed and the destination
rate is added on top); either way the difference between the listed and the charged price is
recorded as the order's signed `tax_adjustment` (positive = the shopper paid
less than listed) and receipts print it as "Price adjustment" so they add
up. PROVIDER: `tax_provider` `local` (the engine above) or `taxjar` (the
token from PUT /api/v1/tax/provider-credentials for the store's
`gateway_mode`, plus `origin_country` and — for a US origin —
`origin_region_code` + `origin_postcode`; exclusive pricing only — PATCH
/api/v1/settings refuses `tax_provider: taxjar` on a `tax_inclusive` store
and `tax_inclusive: 1` on a taxjar store with 400 `tax_provider taxjar
requires exclusive pricing`). The
engine always runs first and only a `standard` treatment reaches TaxJar;
any provider failure ends in the local result as `tax_provider:
local_fallback` with one `tax.provider.fallback` audit row — so an order is
never blocked by the provider, but a `local_fallback` order deserves a look.
The order's `tax_breakdown` (parsed object on GET /api/v1/orders and
/api/v1/orders/{id}) is the snapshot: {basis, country, region_code,
jurisdiction_id, provider, mode (exclusive|fixed_gross|fixed_net),
home_rate_bp, treatment, groups: [{class, rate_bp, goods, goods_tax,
shipping, shipping_tax, shipping_taxed}], adjustment} — one receipt line per
rate (groups sharing a rate merge); render it, never recompute. PREVIEW: POST /api/v1/tax/preview answers
"what would an order to this address be charged" with exactly that result
shape and writes nothing — use it to check a rule before telling a merchant
it works. Deleting a class or jurisdiction that past orders reference is
allowed (snapshots carry slugs and ids without FKs); deleting a class that
products or rates still name is a 409 class_in_use. Every tax write is
audited (tax.class.*, tax.jurisdiction.*, tax.rates.replace,
tax.credentials.*). The five settings: `tax_provider` (local|taxjar),
`tax_no_rule_fallback` (none|flat), `tax_inclusive_mode`
(fixed_gross|fixed_net), `origin_region_code` (a subdivision of
`origin_country` — "TX", "US-TX" or "Texas" → US-TX; a region for a country
with no list, or with no `origin_country`, is a 400; moving the country
clears a region that no longer fits), `origin_postcode` (≤20 chars). The classes,
jurisdictions and rates routes answer 503 tax_rules_unavailable on writes and
empty lists on reads while a store is still finishing the upgrade that adds
the tables; provider-credentials and preview do not (preview quotes the flat
fallback until the rules land).

MERCHANT TAX REGISTRATIONS (M1, spec 1.26.0). A jurisdiction says what a
destination's RATE is; a REGISTRATION (`/api/v1/tax/registrations`) is the
operator's own declaration that they are legally registered to COLLECT there
— and without one the rate is not charged. RESOLUTION, for a taxable
destination: an active `country` row for the destination's country; else,
when the destination is another EU member state, the store's active `oss`
row (the One-Stop-Shop, whose `country` is the member state of
identification); else NONE — and with none the destination's jurisdiction
rule is IGNORED and the order takes `tax_no_rule_fallback` exactly as if no
rule existed (`flat` → the home rate, `none` → treatment `not_registered`,
tax 0). **THE ZERO-ROWS RULE: a store with NO registrations at all is not
gated** — it charges exactly as it did before M1, everywhere. The gate turns
on the moment the operator saves their FIRST row, so telling a merchant
"just add your home registration" silently stops charging in every other
country they had rules for. Add every country they collect in, in the same
sitting. The store's own `origin_country` is always treated as registered,
row or no row. Registrations are DECLARED, never inferred: there are no
thresholds, no "approaching the EU 10k limit" warnings, and no US state
nexus in this release.

`kind` is `country` or `oss` and is IMMUTABLE. `scheme` is a key of the same
tax-ID registry customer tax IDs use — `eu_vat`, `gb_vat`, `au_abn`,
`ca_bn`, `in_gstin`, `us_ein`, `il_company`, `nz_gst`, `ch_uid`, `other` —
and the number is validated by that scheme's format rules for the country,
so a mis-keyed scheme is a 400 (`au_abn`, not `abn`; `in_gstin`, not
`gstin`; `nz_gst`, not `gst`). An `oss` row's `country` must be an EU
member state, and its number may be the non-Union `EU#########` identifier
or that state's own VAT number. At most one ACTIVE country row per country at
any instant, and one OSS row per store: an overlapping window is 409
`registration_exists`, but SUCCESSIVE periods for the same country are
allowed and expected — `valid_to` is exclusive, so closing a row at the day
the next one opens keeps both, and the old one stays on the page greyed.
That is how a merchant who re-registers under a new number keeps their
history; never tell them to delete the old row.

EFFECTIVE DATING IS EVALUATED, NEVER ENFORCED: `valid_from` (inclusive) and
`valid_to` (EXCLUSIVE) are read at charge time, so a row outside its window
is still listed — with `active: false` — and simply ignored by the engine.
Nothing expires anything, and a future-dated row is accepted on purpose.

REVERSE CHARGE now needs a registration too: an active `eu_vat` `country`
row for the store's own `origin_country`. A store with rows but none for its
origin no longer reverse-charges — it charges standard. (A store with zero
rows keeps today's `origin_country`-only rule.)

**THE GATE BINDS TAXJAR (D4a).** It is applied BEFORE the provider seam, not
after, and WHEN IT FIRES THE PROVIDER IS NEVER CALLED — under either
fallback. An unregistered destination is decided locally: `none` →
`not_registered` at 0, `flat` → the store's home rate. TaxJar is called only
for a destination the operator IS registered in, and there its numbers win.
TaxJar does not know what the merchant is registered for, and charging a
shopper tax the merchant cannot remit is the worse failure. So "we use
TaxJar" is not a reason to skip registrations.

DELETING one deletes NOTHING else (D8): the jurisdiction, its rates and
every past order's snapshot stay exactly as they were. What changes is that
the store silently STOPS CHARGING in whatever that row authorised. That is
the answer when a merchant says tax disappeared for a country whose rule is
still on the Tax page — check the registrations, not the rates. Keeping
rates for a country the merchant is about to register in is a legitimate
setup, which is why nothing cascades.

The order records WHICH registration priced it in
`seller_registration_snapshot` (parsed object on GET /api/v1/orders/{id}
ONLY — the list does not carry it):
`{id, kind, scheme, country, number}`, NULL when none applied — every pre-M1
order, every order on a store with no rows, and every order that resolved to
none. On a reverse-charge order it is the ORIGIN registration, the number
that sentence cites; otherwise the destination's. The number is the
MERCHANT's own, not customer PII: it is returned in full and never masked.
While a store is still finishing the upgrade that adds the table, the LIST
reads empty (200 `{data: [], total: 0}`) and every other route — POST, and
GET/PATCH/DELETE on an id — answers 503 `registrations_unavailable`. A 404
there would claim the row does not exist; it has nowhere to live yet. (A
malformed id is still a plain 404.)

SUPPLIERS AND COST (slice 6a). `store_suppliers` (`/api/v1/suppliers`) holds
`name`, `contact_email`, `notes`, and (since slice 6b-a) `provider` — see
SOURCING below for `provider`, and SYNC below for the AliExpress credential,
verify and sync endpoints that arrived in slice 6b-b. A product's
`supplier_id` names one, and is a plain FK: it must belong to THIS store or
the write is a 400 `supplier_id must name a supplier of this store`, null is
"no supplier", and deleting a supplier sets every product naming it back to
null (`ON DELETE SET NULL`) — the product itself, and any order already
placed against it, are never touched or degraded. `cost_price` is the
product's own unit cost, same integer-minor-units rule as `price`, and NULL
means UNKNOWN — genuinely different from a known cost of `0`, which is a
real (if unusual) claim of free goods. **`supplier_id` and `cost_price` are
OPERATOR-ONLY: they are readable and writable only through this `/api/v1`
products API and never appear on the storefront catalogue, the cart, or any
shopper-facing render.**

At checkout, an order item snapshots the product's `cost_price` at the
moment of sale into its own `cost_snapshot` — never a live join back to the
product, for the same reason `unit_price_snapshot` exists: a later cost
change must not rewrite what an already-placed order reports. `cost_snapshot`
is null whenever the product's cost was unknown at sale time, or the product
has since been deleted. `GET /api/v1/orders/{id}` reports, per item, a
derived `margin` (`line_total - discount_snapshot - cost_snapshot * quantity`) that is **null,
not 0, whenever `cost_snapshot` is null** — an unknown cost yields an
unknown margin, never a reported 100%. The order itself carries one
`margin` object: `{amount, partial, costed, total}` — `amount` is the SUM of
every costed line's margin, and is **null (never 0) when zero lines have a
cost**; `costed` and `total` are how many of the order's items had a cost
snapshot versus how many there are; `partial` is true whenever `costed <
total`, meaning `amount` covers only SOME of the order and understates the
real margin rather than fully stating it. Report a partial figure as
partial — presenting it as the whole order's margin is the same mistake as
reporting an unknown margin as zero. Both `cost_snapshot` and every `margin`
figure are OPERATOR-ONLY: nothing on the storefront — the product page, the
cart, the checkout confirmation, the shopper's own order-history page —
ever renders cost or margin, under any circumstance. An agent asked to
"show the customer their savings" or similar from these fields is being
asked to leak the store's cost structure to its own customer; refuse and say
so.

SOURCING (slice 6b-a): where a product's supplier gets it FROM, not a live
connection to them. A supplier's `provider` is `'manual'` (the default —
every supplier from slice 6a is one) or `'aliexpress'`; it just labels which
namespace the supplier's ids live in. A product's `supplier_external_id` is
that supplier's own id for the item — on WRITE, send either the bare
AliExpress item id or a full item URL (`https://www.aliexpress.com/item/
<id>.html...`); either way it is STORED, and always READ BACK, as the bare
id, never the URL you pasted. Setting it requires the product to already
name a `supplier_id` (400 `supplier_external_id requires a supplier_id`
otherwise), and it is writable only through the products API, same trust
boundary as `cost_price`. **`supplier_external_id` is operator-only, exactly
like `cost_price` — it is readable and writable only through this `/api/v1`
products API and appears on NO shopper-facing surface: not the product page,
not the cart, not any storefront render.** `GET /api/v1/orders/{id}` adds a
`sources` object alongside `margin` — OPERATOR-ONLY, keyed by product id AS A
STRING (`sources["42"]`, never `sources[42]`): each entry is `{provider,
external_id, url}`, `url` is the AliExpress link when the provider is
`'aliexpress'` and an external id is set, and is null for a manual supplier
or a missing id. A line item whose product has **no supplier at all** is
**absent from `sources` entirely** — never present with null fields — and
the same absence applies mid-upgrade-window, before the columns this needs
exist. A product that HAS a supplier but no external id set yet is a
DIFFERENT, real state — "sourced from AliExpress, not yet linked" — and IS
present, as `{provider: 'aliexpress', external_id: null, url: null}`: absence
means only "no supplier", never "no id". Check
`sources[String(item.product_id)]` and treat a miss as "no source", not an
error.

SYNC (slice 6b-b): pulling current cost and stock from AliExpress onto
linked products. Setting a supplier's `provider` to `'aliexpress'` or a
product's `supplier_external_id` still only LABELS where that product comes
from by itself (bookkeeping, same as SOURCING above) — the sync endpoint
below is the one thing that actually calls out to AliExpress.

An `aliexpress`-provider supplier can hold ONE stored credential —
`app_key` (plaintext), `app_secret` and `access_token` (sealed, same
encryption as the gateway/email credentials) — via the credentials endpoints
above. `POST /api/v1/suppliers/{supplierId}/verify` makes one real call with
that credential and is the ONLY way to know it actually works; `POST
/api/v1/suppliers/{supplierId}/sync` is the one that pulls data, up to 25 of
the supplier's LINKED products (`supplier_external_id` set) per call, never-
synced products first and then the longest-unsynced, so repeated calls make
progress through a whole catalogue rather than re-touching the same 25. Its
response — `{synced, skipped, failed, remaining, results}` — tells you
`remaining`: more calls are needed whenever it is above 0. A per-item cost
more than 10x the product's own `price` is refused as `skipped` /
`cost_out_of_range` rather than trusted outright (a defence against a
unit-mismatch, not a real price). A product's own `sources` entry (see
SOURCING above) is unaffected by any of this — it still just names where the
product comes from, not whether it has ever synced.

Three things an agent MUST get right about this feature, because getting any
of them wrong misleads a store owner about their own inventory or money:

1. **`supplier_stock` is what the supplier LAST REPORTED — it is NOT the
   store's sellable stock, and a sync NEVER writes `stock`.** `stock` alone
   drives reservation, oversell and backorder logic and decides what the
   storefront will actually sell; `supplier_stock` is informational only,
   visible next to it as a hint. Do not tell an owner they "have" the
   quantity in `supplier_stock` — they have `stock` (or unlimited, if
   `stock` is null), whatever `supplier_stock` says.
2. **Nothing is scheduled.** There is no cron, no background job, no
   automatic re-check. A sync happens ONLY when someone calls the sync
   endpoint — never on a timer, never on a page view, never "in the
   background" because a credential is configured.
3. **This integration is UNVERIFIED.** No real AliExpress credentials
   existed when it was built, so the adapter's request shape, its signing,
   and its response parsing are all best-guess and have never run against
   the real API (see `utils/suppliers/aliexpress.js`'s own header comment
   for exactly which assumptions). **Do not tell a store owner their prices
   or stock are "syncing" — or that their AliExpress account is
   "connected" — on the strength of a saved credential or a set
   `supplier_external_id` alone. Say so only after `verify` has actually
   returned `{"success": true}`, and even then, a synced `cost_price` is
   worth a second look against the supplier's own listing until this has
   run against real traffic.** An agent that skips this and reports syncing
   as already working is reporting inventory or pricing the owner may not
   actually have.

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

Order rows also carry the order's TAX SNAPSHOT: `tax_amount` (integer minor
units), `tax_rate_bp` (the rate in basis points — 1700 = 17%, 825 = 8.25%)
and `tax_inclusive` (0/1). These are what the order was charged and under
which terms, captured at checkout — never the store's current tax settings,
so raising the rate does not rewrite an issued receipt. `tax_inclusive` 0
means the listed prices EXCLUDED tax and `total` is `subtotal +
tax_amount`; 1 means they already CONTAINED it, `tax_amount` was extracted
out of `subtotal` for the record, and `total` equals `subtotal`. Report them
the way the order says: presenting inclusive tax as if it were added
overstates what the customer paid by the whole rate. An untaxed order reports
0/0/0; an order placed before these columns existed omits them entirely.
TAX ENGINE (T1) adds `tax_breakdown` (parsed object, null on a pre-T1 order),
`tax_provider` (local | taxjar | local_fallback) and `tax_adjustment` (signed
minor units, see TAX ENGINE above) on the order — both the list and the
detail — and `tax_amount`, `tax_rate_bp`, `tax_class_slug`,
`tax_jurisdiction_id` on every item (0 / 0 / null / null on a pre-T1 row).
When `tax_breakdown.groups` has more than one rate the receipt shows one tax
line per rate; `bp` on the order is then the blended display rate. The
three order keys are omitted on a tenant that predates the columns.

Order rows also carry the order's SHIPPING SNAPSHOT: `shipping_amount`
(integer minor units, and INCLUDED in `total`), `shipping_label` (what the
delivery line was called on the page the shopper agreed to — the chosen
method's name, or "Shipping" when the store-level flat rate applied), the six
delivery-address fields `shipping_line1`, `shipping_line2`, `shipping_city`,
`shipping_region`, `shipping_postcode` and `shipping_country` (ISO 3166-1
alpha-2, upper case), and `shipping_method_id` — a REFERENCE to the method
chosen, for operator reporting ("how many chose Express") and nothing else.
Never render it or look it up to build the delivery line: `shipping_label` is
the display, and `shipping_method_id` is null under the flat rate and goes
null if that method is later deleted, while the label and amount stay put.
Like the tax
snapshot these are facts about THAT order — where the parcel went and what
delivery cost — never the store's current shipping settings and never a
customer's current saved address, so neither an operator changing the rate
nor a customer editing their address rewrites an issued receipt.
`shipping_label`, not the amount, says whether the order has a delivery
line: a store shipping free at a zero rate has a label with a 0 amount and
genuinely shows "Shipping: 0.00", while a store that does not ship has a
null label and no line at all. `shipping_region` and `shipping_line2` are
optional at checkout, so null there is ordinary.

**So `total` = `subtotal` + `shipping_amount` + `tax_amount` when
`tax_inclusive` is 0, and `subtotal` + `shipping_amount` when it is 1.**
Deriving the tax as `total - subtotal` is WRONG on any shipped order — it
reports the delivery charge as tax. Read the fields.

The store's shipping settings are three of the 21 in `/api/v1/settings`:
`shipping_enabled` (0/1, default 0), `shipping_flat_amount` (integer MINOR
units, the store-wide flat delivery charge) and `tax_shipping` (0/1 —
whether delivery is taxed). They are LIVE: checkout applies them from the
next order on. `shipping_enabled` and `tax_shipping` are STRICTLY 0 or 1
here — unlike `tax_enabled`/`tax_inclusive`, `true`/`false` and `"1"` are a
400 — and `shipping_flat_amount` must be a non-negative INTEGER (a float is
a 400, never rounded). With `shipping_enabled` on, the storefront checkout
requires a delivery address; with it off, no address is collected, no
shipping line renders anywhere, and orders record `shipping_amount` 0.
`shipping_flat_amount` applies ONLY while the store has no shipping ZONES
(`/api/v1/shipping-zones`). Once one zone exists the flat rate is dead: the
shopper's address is matched to a zone and charged one of that zone's
methods, and an address no zone covers is REFUSED rather than charged the
flat rate. That is the first thing to check when a merchant says their flat
rate stopped applying.

A fourth field, `emails_enabled` (0/1, default 0, slice 5c-a), is also LIVE
and also STRICTLY 0 or 1 (no boolean coercion): while 1, a successful
checkout emails the shopper an order confirmation and — when the store has
an email address set — the operator a new-order alert, both rendering the
ORDER's own snapshot so a later settings change cannot rewrite a receipt
already sent. Slice 5c-b adds, to the same switch: a payment-confirmed
email when the order reaches `paid` (by gateway callback or by the
operator recording receipt), and a status email on every subsequent
transition (`processing`, `shipped`, `completed`, `cancelled`,
`refunded`). Each is sent once, by the call that actually caused the
transition, and every attempt is recorded. Slice 5c-c: this toggle no
longer implies a sender — mail requires the store's OWN connected Brevo
account (`PUT /api/v1/email-credentials`) and is sent from that account's
verified address and name, never a shared platform address; replies still
go to the store's own email. A store with `emails_enabled` on but no
connected account sends nothing — every attempt is still recorded, as
`skipped`/`no_credentials` — and a send that fails is recorded without
affecting the order. Slice 5c-d adds a FIFTH kind, `refund_confirmed`, sent
by a call that causes NO status transition: when a stranded refund
reservation (a released `orphan_refund`, or a `refund` reservation released
after the order was already `refunded`) confirms and its confirmed total
now completes coverage of the capture, this mail corrects a refunded figure
that the `status_refunded` mail quoted too low. It is sent at most once per
order.

Order rows (list and detail) carry `awaiting_gateway` (0/1): 1 exactly when
the order is `pending_payment` AND an online-provider attempt (`payplus`,
`hyp`) is still `pending` — the shopper was handed to the gateway and no
result came back, typically an abandoned checkout, and the order holds any
tracked stock it decremented until paid or cancelled. Offline
`pending_payment` orders (a bank transfer that has not arrived) are 0: they
wait on a human, not a machine. There is no automatic expiry in this
release, so `?status=pending_payment` plus this flag is how to find orders
holding stock for an abandoned online payment.

Payment methods are operator-defined rows backed by a FIXED provider
registry: `provider` must be one of `bank_transfer`, `cash_on_delivery`,
`hyp`, `payplus` — anything else is a 400, and the operator owns only the
display text (`name` 1-120 chars, `instructions` up to 4000 chars or null,
`enabled` 0/1, `sort_order` 0-9999). `payplus` is IMPLEMENTED via the
redirect flow: the storefront checkout creates the provider payment session
server-side and 302s the shopper to the PayPlus-hosted payment page, and the
payment is recorded only after the tenant verifies the transaction against
PayPlus's own API (gateway callback, or the shopper's return page
re-triggering the same verification). `hyp` is REGISTERED but NOT YET
IMPLEMENTED: you may create and configure a method for it, but checkout
refuses to take money through it until a later release — do not tell a
merchant such a method is live. The checkout offer itself is the
storefront's `GET /api/shop/payment-methods` (no auth, for shopper
browsers, not PATs): only rows that are enabled, backed by an implemented
provider, AND — for a gateway provider — backed by credentials actually
stored for the store's CURRENT gateway mode. A configured `hyp` method
never appears there; an enabled `payplus` method appears only once its
credentials for that mode are saved (`PUT /api/v1/gateway-credentials/payplus?mode=…`).
If a merchant asks why their PayPlus option is missing at checkout, that
is the first thing to check — offering it unconfigured would place an
order and hold stock for a payment that could never start. Payment-method writes return
`{"success": true, "id"}` (no slug). Unlike other store writes, an unknown
body field is rejected with 400 `unknown_field:<name>`, never silently
ignored.

Shopper checkout (`POST /api/shop/checkout`) takes an optional
`payment_method_id` — an id from that offer. While the store has NO enabled
method on an implemented provider, checkout works exactly as before and
records no payment; once it has one, a valid id is REQUIRED (400
`payment_method_required` without it, `invalid_payment_method` for an
unknown/disabled id). Posting the id of a method the offer excludes — `hyp`, or a `payplus`
method with no credentials stored for the store's current gateway mode —
is refused with 400 `payment_method_unavailable` and writes nothing: the
offer and the checkout gate share one rule. A
successful choice books a `pending` payment on the order — provider and
method name snapshotted, amount/currency always the server's own numbers —
and the response gains `payment: {method_name, instructions}` for the
confirmation page.

The same checkout takes `shipping_address` (required whenever
`shipping_enabled` is 1) and, once the store has zones, `shipping_method_id`
— an id from the zone that address matches. The zone is RE-DERIVED from the
submitted address before the id is honoured, so the checkout gate and the
options the storefront offered share one rule: a method from another zone is
400 `invalid_shipping_method` however its id was obtained, no method at all
is 400 `shipping_method_required`, and an address no zone covers is 400
`no_delivery_coverage` — the store does not deliver there, and the fix is an
operator adding a zone (a catch-all is `countries: "*"`), never a client
retry. Nothing is written on any of them. The delivery PRICE is never taken
from the request: it comes off the method row, with that method's own
`free_over` applied against the goods subtotal, and the order snapshots
`shipping_amount`, `shipping_label` (the method's name) and
`shipping_method_id`. With no zones configured the store's flat rate applies
and `shipping_method_id` is not needed — a posted one is ACCEPTED by the
allowlist and then ignored, not refused, so do not read a 200 as proof that a
method id was honoured. The checkout RESPONSE does not carry
`shipping_method_id` — it is operator reporting, and that response is
shopper-facing — so check it with `GET /api/v1/orders/{orderId}` on the id the
checkout returned.

Recording receipt (`PATCH /api/v1/orders/{orderId}/payments/{paymentId}`)
is the loop: list orders with `?status=pending_payment`, GET the order,
read `payments[].id` off it, PATCH. On a charge row it accepts ONLY
`status: "received"`, and for OFFLINE money only: a charge whose
provider is an online gateway (`payplus`) is refused with 409 whatever
the order's status, and nothing is written. Never offer a merchant to
"just mark it paid" for a card order — that payment settles only when
the tenant itself verifies the transaction against the gateway, and its
`reference` holds the gateway's transaction id that verification depends
on. The one other thing this PATCH does is release a STRANDED REFUND
RESERVATION: a `kind: "refund"` or `kind: "orphan_refund"`,
`status: "pending"` row (a refund
interrupted between reserving and confirming, or one whose gateway call
failed AMBIGUOUSLY — a 5xx, a timeout, a mismatched amount) blocks all
further refunds on its order until resolved. After the merchant checks the provider's
dashboard, send `{status: "failed"}` if the money never moved (the
balance returns; a reference here is a 400) or `{status: "received",
reference}` with the provider's own REFUND reference — not the charge's
transaction uid — if it did. Only pending refund/orphan_refund rows release (409
otherwise), and the order's status is untouched: once confirmed refunds
cover the capture, the lifecycle PATCH below can mark the order refunded.
ORPHAN PAYMENT money is handled elsewhere: a `kind: "orphan"`,
`status: "received"` row is a verified EXTRA payment that arrived on an
already-settled order (a real double charge). It never counts toward
`refundable_amount`, and this PATCH never mutates it — `"refunded"` is a
400 on every row. Send the money back through
`POST /api/v1/orders/{orderId}/refunds` with `{payment_id}` (the orphan
row's id): the gateway refunds against the orphan's own transaction uid
and a `kind: "orphan_refund"` row records it; or, if the merchant already
returned it in the provider's dashboard, `{payment_id, reference}` records
that instead. Outstanding orphan money on ONE row = that row's amount minus the
non-failed orphan_refund rows naming it (`refunds_payment_id`); the orphan row itself stays `received` as
the record of what arrived, and the order's status is never touched.
Order lifecycle moves —
processing, shipping, completion, cancel, refund — are made with
`PATCH /api/v1/orders/{id}` and `{status}` alone: legal moves are
pending_payment → cancelled; paid → processing | cancelled | refunded;
processing → shipped | cancelled | refunded; shipped → completed |
refunded (no cancel once shipped — the goods are gone); completed →
refunded; cancelled → refunded; refunded is terminal. An illegal move is
a 409 and changes nothing, and `"paid"` is NEVER accepted there —
recording receipt on the payment is the only route to paid. `"refunded"`
carries one extra gate: on an order whose settled charge is a `payplus`
one it is a 409 until refund rows the gateway confirmed cover the
captured amount — the status move never contacts the gateway, so
accepting it earlier would mark the order refunded while the customer is
still out of pocket; send the money back with the refunds POST instead
(a full refund transitions the order itself). Cancelling
or refunding returns each line's quantity to its product's stock exactly
once per order (cancel-then-refund does not restock twice) — but ONLY
for tracked products: an untracked product (stock null) stays untracked,
nothing is written to it. A refund restocks even when the goods were not
returned — for a tracked product, edit its stock down afterwards if they
weren't; never "correct" an untracked product by writing a number, that
silently turns tracking on for stock the merchant never counted.
Before switching a product from untracked to tracked, settle or cancel
its open orders FIRST: an order placed while the product was untracked
decremented nothing, so cancelling or refunding it after a count is set
adds units that were never taken — the system cannot tell such an order
apart from one that really decremented. Note also that checkout
decrements stock when the ORDER is placed, not when payment arrives:
an abandoned `pending_payment` order holds its units until it is
cancelled, and nothing expires it automatically.

PER-ITEM OVERSELL. A product with `allow_oversell: 1` is sold PAST its stock
instead of being refused: stock floors at 0 and the units owed accrue in
`backordered`, a separate non-negative column both product reads return. D1
cannot store a negative stock, so "three units in the hole" reads back as
`stock: 0, backordered: 3`, which an admin presents as −3. NEVER report that
row as "sold out" — it owes three units, a different state from
`stock: 0, backordered: 0`. Cancelling or refunding pays the debt down FIRST
and credits stock only with what is left over, so restocking a backordered
item never invents inventory. A PATCH of `stock` settles the debt the same
way: the count you send is the units the merchant now HAS, so what is owed
comes off the top — `{stock: 20}` against a debt of 3 stores `stock: 17,
backordered: 0`, and `{stock: null}` clears the debt along with the tracking.
Tell a merchant that before they save, or the 17 looks like the API losing
their number; `stock` and `backordered` are NEVER both positive, and this
PATCH is the only way an operator can clear a debt. During the minutes after
a store upgrade and before its migrations run, a PATCH naming ONLY
allow_oversell/backorder_notice answers 503 — retry it; it never silently
reports success. `backorder_notice` is the operator's own copy, shown to
shoppers whenever the line is short: on the product page once stock is 0, and
in the cart whenever the quantity exceeds stock (5 in stock, 10 in the cart is
a backorder). null means they are told nothing, which is a deliberate choice —
never write copy in for them. Products without the flag are still refused for
insufficient stock, exactly as before.

`reference` is optional plain text up to 200 characters (control bytes
and angle brackets rejected; anything longer is a 400, NEVER truncated —
it must match a bank statement byte for byte); omit it to keep a
previously stored one, send null or blank to clear it. Like
payment-method writes, an unknown body field is a 400
`unknown_field:<name>`, never silently ignored — a typo'd `refrence`
would otherwise record no reference and tell you nothing. The call is
idempotent — repeating it returns 200 and never moves an order that has
already gone past `pending_payment` (a `shipped` order stays `shipped`;
only the payment row updates) — but a `cancelled` or `refunded` order is
a 409: the money already left, and receipt cannot be recorded on it. The
payment must belong to the order in the URL and to this store: any
mismatch, unknown id or malformed id is a plain 404.

Store settings (`/api/v1/settings`) cover exactly 44 writable fields: `name`,
`description`, `logo_url`, `favicon_url`, `currency`, `locale`, `timezone`,
`email`, `phone`, `address`, `tax_enabled`, `tax_rate`, `tax_inclusive`,
`shipping_enabled`, `shipping_flat_amount`, `tax_shipping`,
`emails_enabled`, `email_log_retention_days`, `google_analytics_id`,
`facebook_pixel_id`, `gateway_mode`, `theme`, `allow_split_checkout`,
`collects_shipping_address`, `require_customer_account`,
`postal_code_required`, `international_shipping`, `default_country`,
`trust_strip_line_1`, `trust_strip_line_2`, `shipping_policy_html`,
`returns_policy_html`, `allow_business_customers`,
`require_company_for_business`, `require_phone_at_checkout`,
`tax_id_verification`, `tax_address_basis`, `origin_country`,
`tax_provider`, `tax_no_rule_fallback`, `tax_inclusive_mode`,
`origin_region_code`, `origin_postcode`, `require_email_verification` (the
`StoreSettings` schema in the OpenAPI spec is the per-field authority; the
six before the tax-engine five are CUSTOMER TAX IDENTITY above, those five are
TAX ENGINE above, the last one is ACCOUNT INTEGRITY above — whose read-only
companion `email_verification_since` appears on GET only). The PDP four (migrations 0121-0124), all nullable:
`trust_strip_line_1`/`trust_strip_line_2` are plain text — newlines and
tabs collapse to a single space, then trimmed, at most 120 characters (a
400 beyond), empty or whitespace-only clears to null;
`shipping_policy_html`/`returns_policy_html` are sanitized at WRITE time to
a fixed allowlist — `p`, `br`, `strong`, `em`, `ul`, `ol`, `li`, `a[href]`
(http, https, mailto or relative) — every other tag is dropped and its text
kept, at most 4000 characters after sanitization (a 400 beyond), empty
clears to null, and GET returns the stored (already sanitized) value.
`gateway_mode` is `"test"` (the default) or `"live"` — it
decides store-wide which gateway credential rows checkout uses; it is never
selectable per request, and a store that has not chosen cannot accidentally
take live cards. PATCH returns
`{"success": true, "settings": {...}}` with the updated row; a body with
nothing updatable is a 400, and a PATCH with `id`, `slug` or any other
non-listed field is a 400 `unknown_field:<name>` — nothing is written. `currency` follows the same
ISO 4217 rule as products; `tax_enabled`/`tax_inclusive` are 0/1 (booleans
accepted, strings rejected); `tax_rate` is a number 0-100;
`shipping_enabled`/`tax_shipping`/`emails_enabled` are 0/1 with NO boolean
coercion (`true` is a 400 here, unlike the tax flags); `shipping_flat_amount`
is a non-negative integer in minor units (a float is a 400);
`email_log_retention_days` is a non-negative INTEGER number of days (default
90, `0` means keep forever; a negative or fractional value is a 400). Length caps:
`name` is 1-60 characters, and every free-text field (description, the URLs,
contact fields, analytics ids) caps at 2000 — longer is a 400. Both verbs
return 503 `store_not_provisioned` until the store row exists (same signal
as `GET /api/store`). The tax fields, the shipping fields and
`emails_enabled` are LIVE: checkout applies the tax and shipping fields and
snapshots the result onto every order placed after the change, and — while
`emails_enabled` is 1 — emails the shopper an order confirmation and, when
the store has an email set, the operator a new-order alert (slice 5c-a).
Slice 5c-b adds, to the same switch: a payment-confirmed email when the
order reaches `paid` (by gateway callback or by the operator recording
receipt), and a status email on every subsequent transition (`processing`,
`shipped`, `completed`, `cancelled`, `refunded`) — each sent once, by the
call that actually caused the transition, with every attempt recorded.
Slice 5c-c: `emails_enabled` alone is not enough — mail requires the store's
own connected Brevo account (see `/api/v1/email-credentials` below); a store
with the toggle on but no connected account sends nothing, and every
attempt is still recorded (`skipped`/`no_credentials`). Slice 5c-d adds a
FIFTH kind, `refund_confirmed`, sent by a call that causes NO status
transition: when a stranded refund reservation confirms and its confirmed
total now completes coverage of the capture, this mail corrects a refunded
figure that `status_refunded` quoted too low. Sent at most once per order.
`email_log_retention_days` is also LIVE, but its PRUNING is not until
migration 0061 lands — checked once after every send batch to delete
`store_email_log` rows older than that many days; `0` means keep forever;
a `sent` row of kind `refund_confirmed` is never pruned at any setting,
because it is the guard against a duplicate refund-correction email;
during the 0061 migration window nothing is pruned. Every attempt, whatever
it did, is a row in that log, and
`GET /api/v1/email-log` is how an operator reads it: `?order_id=N` returns
that order's own rows (`entries`, newest first — "did this customer get
their receipt"), and no parameter returns a store-wide summary (`summary`
counts by status, `last_attempt`, up to 50 `recent_failures`, all newest
first — "is my mail working at all"). A malformed `order_id` is a 400,
never silently treated as absent. `message_id` — Brevo's own id for a sent
message — is NEVER returned by either shape; it answers no question an
operator has here.
Only the analytics ids are STORED BUT NOT YET APPLIED — the
storefront emits them in slice 6 — so never tell a user that setting THOSE
changes live behaviour today.

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
