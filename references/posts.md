# Posts

The primary content type. Blog articles with title, slug, HTML content,
excerpt, featured image, author, category, tags, publication status, and
optional scheduling.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/posts` | List (query: `limit`, `offset`, `status`) |
| POST | `/posts` | Create (defaults to draft) |
| GET | `/posts/{id}` | Read one |
| PUT | `/posts/{id}` | Full update — GET first, merge, PUT the whole object |
| DELETE | `/posts/{id}` | Move to trash (soft delete) |
| GET | `/posts/slug/{slug}` | Read by slug |
| GET | `/posts/categories` | Post categories (separate from page categories) |
| GET | `/posts/tags` | Post tags |
| POST | `/posts/{id}/short-url` | Generate short URL for one post |
| POST | `/posts/bulk-short-url` | Batch short-URL generation |

## Common bodies

Create a draft:

```json
{"title":"Hero of the Season","content":"<p>…</p>","status":"draft"}
```

Publish an existing post (fetch first, merge, PUT — never send a partial body):

```bash
CUR=$(ep --raw GET /posts/42)
echo "$CUR" | jq '. + {"status":"published"}' > /tmp/post-42.json
ep PUT /posts/42 "$(cat /tmp/post-42.json)"
```

Schedule for future publishing (`scheduled_at` ISO 8601, per SKILL publish flow):

```json
{"status":"scheduled","scheduled_at":"2026-10-01T09:00:00Z"}
```

## Response shape

```json
{
  "id": 42,
  "title": "Hero of the Season",
  "slug": "hero-of-the-season",
  "content": "<p>…</p>",
  "excerpt": "…",
  "status": "published",
  "featured_image": "https://blog.edgepress.cc/media/108.jpg",
  "author_id": 3,
  "category_id": 5,
  "created_at": 1735000000,
  "updated_at": 1735100000
}
```

`created_at` / `updated_at` are unix seconds.

## Gotchas

- **Update is PUT, not PATCH.** `/posts/{id}` only accepts PUT. A partial body
  nulls out every field you omit — always GET → merge with `jq` → PUT.
- `slug` is auto-derived from `title` if omitted. Passing an explicit slug
  wins; set it explicitly when a stable URL matters.
- Publishing is `status: "published"` via PUT — there is NO
  `/posts/{id}/publish` endpoint.
- `status` values in responses: `draft`, `published`, `trash`. DELETE sets
  `trash` (soft delete); permanent delete is an admin-UI action, not exposed
  here.
- `featured_image_id` on write refers to `media.id`, not the media URL. The
  read shape echoes a resolved `featured_image` URL string.
- Post categories/tags are SEPARATE from page taxonomies — `/posts/tags` and
  `/pages/tags` are different tables. See `categories-tags.md`.
- List responses are plain JSON arrays (no envelope); page with
  `?limit=N&offset=M`.
