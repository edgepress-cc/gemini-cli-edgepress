# Writing an EdgePress plugin

A plugin is one JavaScript file (the **bundle**) plus a JSON **manifest**. It runs on EdgePress
servers in its own sandbox, never in the visitor's browser, and can do only what its manifest
declares. Both products (CMS and store) take plugins; the manifest says which.

**You can write a plugin; you cannot install it.** Installing, approving, configuring, setting
secrets, rolling back and uninstalling happen only in the admin UI (Settings → Plugins), by an
admin who signed in within the last 10 minutes. Every token, PAT or plugin token, is refused
on `/api/v1/plugins`. Hand the user the two files and tell them where to upload them.

## Manifest

```json
{
  "slug": "order-to-crm",
  "version": "1.0.0",
  "products": ["store"],
  "scopes": ["orders:read"],
  "egress": ["api.crm.example"],
  "secrets": [{ "name": "CRM_KEY", "hosts": ["api.crm.example"] }],
  "hooks": ["order.created"],
  "routes": ["webhook"],
  "cron": ["@daily"]
}
```

| Key | Rule |
|---|---|
| `slug` | `^[a-z][a-z0-9-]{1,39}$`. Identifies the install; uploading the same slug updates it. |
| `version` | `N.N.N` (1-4 digits each). |
| `products` | Must include the product it is uploaded to: `"cms"` or `"store"`. |
| `scopes` | What its API calls may touch (table below). Default deny. |
| `egress` | Lowercase public hostnames it may `fetch`. No IPs, no localhost. |
| `secrets` | `{ name, hosts }`. Name `^[A-Z][A-Z0-9_]{0,39}$`; every host must also be in `egress`. |
| `hooks` | Events it receives (table below). |
| `routes` | Public URL names, `^[a-z0-9][a-z0-9-]{0,39}$`. |
| `cron` | `"@hourly"` and/or `"@daily"`. |
| `blocks` | Page blocks, see Blocks below. |

Any other key is refused (`adminPanels`, `widgets` only as empty arrays). `blocks` is described under Blocks. Manifest ≤ 32 KB.
A new version that asks for anything the admin has not approved yet (a scope, host, hook, route,
schedule, or a secret on a new host) waits for fresh approval; the old version keeps running. Approval is
of that exact code AND manifest: re-uploading the same code with a different manifest needs approving again.
A plugin the admin disabled stays disabled after approving an update (Enable turns it on); Discard drops a
waiting upload.

### Scopes

| Product | Scope | Allows |
|---|---|---|
| store | `catalog:read` | GET products, categories (incl. tree), tags |
| store | `catalog:write` | POST products, PATCH products/categories |
| store | `orders:read` | GET orders |
| store | `content:read` / `content:write` | GET / POST, PATCH, DELETE blog posts |
| store | `submissions:read` | GET form submissions |
| cms | `posts:read` / `posts:write` | GET / POST, PUT, DELETE posts |
| cms | `pages:read` / `pages:write` | GET / POST, PUT, DELETE pages |
| cms | `media:read` | GET media |
| cms | `comments:read` / `comments:write` | GET / PATCH, DELETE comments |

Its own storage (`env.storage`) needs no scope.

### Events

| Product | Event | `data` | Needs scope |
|---|---|---|---|
| store | `order.created` | `{ status }` | `orders:read` |
| store | `order.status_changed` | `{ from, to }` | `orders:read` |
| store | `form.submitted` | `{}` | `submissions:read` |
| cms | `post.published` | `{}` | `posts:read` |
| cms | `comment.created` | `{ post_id, status }` | `comments:read` |

A hook without its scope validates but is never delivered. `entityId` is the order / submission /
post / comment id; read the full record through `env.api`.

## Bundle

One self-contained ES module, ≤ 1 MB, **no `import` or `export … from`** (refused at upload,
including dynamic `import()`; even a string that looks like one). Bundle dependencies in yourself.

```js
export default {
  async onEvent(event, env) {
    // event = { id, type, entityId, data, createdAt }
    if (await env.storage.get(`seen.${event.id}`)) return;          // at-least-once: dedupe
    const { status, body: order } = await env.api.get(`/api/v1/orders/${event.entityId}`);
    if (status !== 200) throw new Error(`order ${status}`);           // throw = retry later
    const res = await fetch('https://api.crm.example/contacts', {
      method: 'POST',
      headers: { Authorization: 'Bearer ep-secret-CRM_KEY', 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: order.email, list: env.settings.list ?? 'buyers' }),
    });
    if (!res.ok) throw new Error(`crm ${res.status}`);
    await env.storage.put(`seen.${event.id}`, '1');
  },
  async onRequest(request, env) {                       // https://<site>/api/plugin-routes/<slug>/<route>
    return Response.json({ ok: true });
  },
  async onSchedule(name, env) {                         // name is '@hourly' or '@daily'
    await env.log.info('tick', name);
  },
};
```

All three handlers are optional; omit the ones the manifest does not use.

### `env`

- **`env.api.get|post|put|patch|delete(path, body?)`** → `{ status, body }` (body is parsed JSON,
  or `null`). `path` must be lowercase `/api/v1/...` (query string allowed). It calls the site with
  the plugin's own token, limited to its approved scopes; anything else answers 403.
- **`env.storage.get(key)`** → value or `null`; **`put(key, value)`** (throws on refusal);
  **`delete(key)`**; **`list()`** → keys. Keys `[a-z0-9_.-]{1,128}`; values are strings ≤ 256 KB
  (UTF-8 bytes); at most 10 MB and 10,000 keys per install. Uninstall deletes it all.
- **`env.log.info|warn|error(...args)`** → shown under Logs in the admin (newest 100; each line
  ≤ 2,000 chars). Never log secrets or personal data.
- **`env.settings`** → the JSON object the admin saved under Settings, `{}` until then. Defaults
  belong in your code; the manifest's `settings` key is not applied.

### `fetch` and secrets

`fetch` reaches only hosts in `egress`, over `https` on port 443, no credentials in the URL;
redirects are followed only to allowed hosts (3 hops). Request body ≤ 1 MB, response ≤ 5 MB.

The bundle never sees a secret. Write the placeholder **`ep-secret-NAME`** in the URL or a header;
it is replaced on the way out, and only when the request goes to one of that secret's `hosts`
(otherwise the request is refused). Secrets are not substituted in the body. The admin types
the value in Settings → Plugins; it is write-only there too.

### Public routes

`https://<site>/api/plugin-routes/<slug>/<route>[/more][?query]` (also under `/api/v1/`). Anyone can
call it; 60 requests a minute per IP; request body ≤ 1 MB; cookies, `Authorization` and proxy
headers are stripped before the plugin sees the request. `onRequest` must return a `Response`. It is
sent as `application/json` if your `Content-Type` says so, otherwise as `text/plain` — never
HTML, and your other headers are dropped. Verify webhook signatures yourself, with a signing key the
admin saves under Settings (read it from `env.settings`): a secret cannot do this job, because the
bundle never sees one — secrets are only substituted into outgoing requests. Settings are stored in
plain text and shown to admins, so use a key meant for verifying, not one that grants access.

## Blocks

A plugin can offer page blocks that the admin places in the editor, like any built-in block. Declare them in the
manifest, render them from `onBlock`:

```json
"blocks": [
  { "slug": "reviews", "title": "Customer reviews",
    "props": {
      "count": { "type": "integer", "title": "How many", "minimum": 1, "maximum": 20, "default": 5 }
    },
    "required": [] }
]
```

- At most 10 blocks per plugin; `slug` `^[a-z][a-z0-9-]{1,39}$`, `title` ≤ 60 characters.
- `props` is a flat object of at most 20 properties. Each has a `type` of `string`, `number`, `integer` or `boolean`, and
  optionally `title` (≤ 60), `description` (≤ 200), `enum` (≤ 50 values), `minimum`/`maximum`, `maxLength` (strings, ≤ 2000,
  default 500) and `default`. `required` lists property names. Anything else is refused at upload.
- Adding a block, or changing a block's props, needs the admin's approval again ("Shows content on your pages").

`onBlock(name, props, env)` returns `{ html, css? }`. `props` are the admin's validated values. `env.storage` is
**read-only** and its values are strings (store JSON with `JSON.stringify`, read it with `JSON.parse`); `env.settings` and
`env.locale` are available. There is **no `env.api`, no `fetch` and no secrets** in a block. A block gets 20 ms of CPU and
1 second; `html` ≤ 64 KB, `css` ≤ 16 KB.

Because a block cannot fetch, fill storage from `onSchedule`, `onEvent` or `onRequest` and render from storage. EdgePress
renders ahead of time, not per visitor: the page shows the stored rendering. A storage write updates the block within
about a minute; time-based content (a relative date, "open now") is re-rendered hourly while a page has shown it in the
last two days. Block renders have their own daily budget per site, separate from events, routes and schedules. If a render fails, visitors keep
the last good one and the admin sees the error under Logs.

The output is sanitised, so write plain markup:

- Kept: layout and text tags, `class`, `style` (filtered), links, and images. An image (`src` and each `srcset` entry) is
  kept only when it is site-relative (`/media/…`) or `https://` from a host in your manifest's `egress` list; any other
  image is dropped. Links to other sites get `rel="noopener nofollow"`.
- Dropped: `<script>`, forms and inputs, iframes and embeds, `on*` handlers, `javascript:` URLs, `http` images, and any `url(...)`
  inside a `style` attribute.
- CSS is scoped under the block's wrapper automatically. Plain rules and `@media` only (`@import`, `@font-face` and other
  at-rules are dropped; `:root`, `html` and `body` mean the block's own element, which sits inside the clipping wrapper), a declaration with `!important` is dropped, and so is
  one with a remote `url(...)` (inline `data:image/` URLs are allowed in the CSS you return, not in `style` attributes). The wrapper clips anything painted outside its box.

Worked example, "Customer reviews": the schedule fetches into storage, the block renders from it.

```json
{
  "slug": "reviews", "version": "1.0.0", "products": ["cms"],
  "egress": ["api.reviews.example"],
  "cron": ["@hourly"],
  "blocks": [{ "slug": "reviews", "title": "Customer reviews",
    "props": { "count": { "type": "integer", "title": "How many", "minimum": 1, "maximum": 20, "default": 5 } } }]
}
```

```js
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

export default {
  async onSchedule(name, env) {
    const res = await fetch('https://api.reviews.example/v1/reviews?limit=20');
    if (!res.ok) throw new Error(`reviews ${res.status}`);
    const list = await res.json();                           // [{ author, stars, text }]
    await env.storage.put('reviews', JSON.stringify(list));  // a storage write re-renders the block within ~1 minute
  },
  async onBlock(name, props, env) {
    const list = JSON.parse((await env.storage.get('reviews')) ?? '[]').slice(0, props.count ?? 5);
    const items = list.map((r) =>
      `<li><strong>${esc(r.author)}</strong> ${'★'.repeat(r.stars)}<p>${esc(r.text)}</p></li>`).join('');
    return {
      html: `<ul class="reviews">${items}</ul>`,
      css: '.reviews{list-style:none;padding:0;display:grid;gap:1rem} @media (min-width:700px){.reviews{grid-template-columns:1fr 1fr}}',
    };
  },
};
```

Escape every value you put in `html`: it comes from outside, and the sanitiser is a backstop, not a substitute.

## Limits and delivery

| Handler | CPU | Wall time | Subrequests |
|---|---|---|---|
| `onEvent` | 50 ms | 30 s | 20 |
| `onRequest` | 50 ms | 10 s | 20 |
| `onSchedule` | 500 ms | 60 s | 100 |

- **Events are delivered at least once.** If `onEvent` throws or times out, the event is tried
  again about 1 minute and then about 10 minutes later, and dropped after the third failure (an
  outage on EdgePress's side does not use up attempts; those retry for up to a day). When any
  subscriber fails, the retry goes to every subscriber of that event again. Always dedupe on
  `event.id`, and make writes idempotent.
- **Schedules**: checked every 15 minutes; `@hourly` runs about once an hour, `@daily` once a day,
  never exactly on the hour.
- **50 failures in a row** auto-disable the plugin ("Disabled after errors"); the admin re-enables it.
- Per-site daily budgets cap invocations and outbound requests; over budget, calls are refused
  until the next day.

## Handing it over

Give the user `manifest.json` and `plugin.js`, then: Settings → Plugins → choose both files →
Upload → read what it asks for → Approve → set any secrets and settings. The last 5 approved versions
are kept for Roll back. Managing plugins needs a sign-in from the last 10 minutes; the page's "Sign in again"
button renews it.
