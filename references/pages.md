# Pages

Static pages (about, contact, imprint). Same shape as posts minus scheduling;
pages have their own taxonomy tables, fully separate from post taxonomies.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/pages` | List (query: `limit`, `offset`, `status`) |
| POST | `/pages` | Create (defaults to draft) |
| GET | `/pages/{id}` | Read one |
| PUT | `/pages/{id}` | Partial update — send only the fields you change |
| DELETE | `/pages/{id}` | Delete |
| GET | `/pages/categories` | Page categories (POST/PUT/DELETE to manage) |
| GET | `/pages/tags` | Page tags (POST/PUT/DELETE to manage) |
| GET | `/pages/{id}/preview-url` | Private preview link for a draft (or any page) — see below |

## Common bodies

Create a draft page:

```json
{"title":"About Us","content":"<p>Who we are…</p>","status":"draft"}
```

Publish an existing page (a partial body is enough):

```bash
ep PUT /pages/7 '{"status":"published"}'
```

Keep a draft out of search engines even after it is published: set its
`robots` field (`"noindex, nofollow"`). The value is rendered as the page's
robots meta tag and its `X-Robots-Tag` header.

Preview a draft without publishing it:

```bash
ep GET '/pages/7/preview-url?ttlMinutes=120'
# {"url":"https://<site>/page/about-us?_preview=…","expiresAt":…,"status":"draft"}
```

The link renders the page as it is now, always `noindex, nofollow` and never
cached, opens only that page, and expires. It stores nothing, so it is a GET
and a read-only token can use it; it needs role editor or admin.

## Response shape

```json
{
  "id": 7,
  "title": "About Us",
  "slug": "about-us",
  "content": "<p>Who we are…</p>",
  "status": "published"
}
```

## Gotchas

- **One page can be the home page** (`front_page_id`, see `settings.md`): it renders at `/` and
  its own `/page/<slug>` redirects there. `GET /settings` tells you which one it is.
- **No `scheduled_at`.** Pages cannot be scheduled — only draft or published.
  If the user wants timed publication, it's a post, not a page.
- **Update is PUT, and it is partial.** Omitted fields keep their stored
  value (`'{"content":"…"}'` alone is fine). The title can't be blanked, and
  publishing needs content — the stored one counts.
- **Page taxonomies are their own tables.** `/pages/categories` and
  `/pages/tags` share no rows with `/posts/categories` / `/posts/tags`.
  Creating a category for posts does not make it available to pages.
- Taxonomy PUT/DELETE on `/pages/categories` and `/pages/tags` are
  collection-level: PUT takes the `id` in the body, DELETE as `?id=` in the
  query string. See `categories-tags.md`.
- A slug changed through PUT is normalised per `/` segment and keeps Hebrew
  (`"Docs/מדריך התקנה"` → `docs/מדריך-התקנה`); one with no letters or digits
  left is a 400.
- `slug` auto-derives from `title` on create if omitted, same as posts.
- There is no `/pages/slug/{slug}` lookup (unlike posts). To find a page by
  slug, list and filter: `ep --raw GET /pages | jq '.[] | select(.slug=="about-us")'`.
- The spec also exposes legacy `/page-categories` and `/page-tags` aliases —
  prefer the `/pages/...` forms; the aliases exist for older clients only.
