# Pages

Static pages (about, contact, imprint). Same shape as posts minus scheduling;
pages have their own taxonomy tables, fully separate from post taxonomies.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/pages` | List (query: `limit`, `offset`, `status`) |
| POST | `/pages` | Create (defaults to draft) |
| GET | `/pages/{id}` | Read one |
| PUT | `/pages/{id}` | Full update — GET first, merge, PUT the whole object |
| DELETE | `/pages/{id}` | Delete |
| GET | `/pages/categories` | Page categories (POST/PUT/DELETE to manage) |
| GET | `/pages/tags` | Page tags (POST/PUT/DELETE to manage) |

## Common bodies

Create a draft page:

```json
{"title":"About Us","content":"<p>Who we are…</p>","status":"draft"}
```

Publish an existing page (GET → merge → PUT, never a partial body):

```bash
CUR=$(ep --raw GET /pages/7)
echo "$CUR" | jq '. + {"status":"published"}' > /tmp/page-7.json
ep PUT /pages/7 "$(cat /tmp/page-7.json)"
```

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

- **No `scheduled_at`.** Pages cannot be scheduled — only draft or published.
  If the user wants timed publication, it's a post, not a page.
- **Update is PUT, not PATCH.** Same merge discipline as posts: a partial PUT
  body nulls omitted fields. GET → `jq` merge → PUT.
- **Page taxonomies are their own tables.** `/pages/categories` and
  `/pages/tags` share no rows with `/posts/categories` / `/posts/tags`.
  Creating a category for posts does not make it available to pages.
- Taxonomy PUT/DELETE on `/pages/categories` and `/pages/tags` are
  collection-level — the target `id` goes in the request body, not the path.
  See `categories-tags.md`.
- `slug` auto-derives from `title` on create if omitted, same as posts.
- There is no `/pages/slug/{slug}` lookup (unlike posts). To find a page by
  slug, list and filter: `ep --raw GET /pages | jq '.[] | select(.slug=="about-us")'`.
- The spec also exposes legacy `/page-categories` and `/page-tags` aliases —
  prefer the `/pages/...` forms; the aliases exist for older clients only.
