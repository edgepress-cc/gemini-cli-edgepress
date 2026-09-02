# Podcasts

Podcast episodes with per-platform links (Apple, Spotify, YouTube) and their
own taxonomy. Bulk create exists for back-catalog imports.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/podcasts` | List episodes (query: `limit`, `offset`) |
| GET | `/podcasts/{id}` | Read one episode |
| POST | `/podcasts` | Create episode |
| PUT | `/podcasts/{id}` | Full update — GET first, merge, PUT |
| DELETE | `/podcasts/{id}` | Delete episode |
| POST | `/podcasts/bulk` | Bulk create — use for imports |
| GET | `/podcasts/admin` | Admin listing (includes unpublished) |
| POST | `/podcasts/{id}/short-url` | Generate a short URL for an episode |
| GET | `/podcasts/categories` | Podcast categories (read-only) |
| GET | `/podcasts/tags` | Podcast tags (POST/DELETE to manage) |

## Common bodies

Create an episode:

```json
{
  "title": "Episode 12: The Transfer Window",
  "description": "<p>We break down the deadline-day moves…</p>",
  "apple_url": "https://podcasts.apple.com/…",
  "spotify_url": "https://open.spotify.com/episode/…",
  "youtube_url": "https://youtube.com/watch?v=…"
}
```

Bulk import (array body):

```json
[
  {"title":"Episode 1","spotify_url":"https://…"},
  {"title":"Episode 2","spotify_url":"https://…"}
]
```

## Response shape

```json
{
  "id": 12,
  "title": "Episode 12: The Transfer Window",
  "slug": "episode-12-the-transfer-window",
  "description": "<p>…</p>",
  "apple_url": "https://podcasts.apple.com/…",
  "spotify_url": "https://open.spotify.com/…",
  "youtube_url": "https://youtube.com/…",
  "created_at": 1735000000
}
```

## Gotchas

- **Update is PUT** — same GET → merge → PUT discipline as posts; a partial
  body nulls the platform links you omit, which silently strips an episode
  from platform pages.
- **Use `/podcasts/bulk` for imports**, one array body instead of N POSTs.
  It's the difference between 1 request and blowing the 60/min rate limit.
  Anything over ~10 episodes is still workflow-subagent territory.
- Platform links are plain URL fields (`apple_url`, `spotify_url`,
  `youtube_url`) — no validation beyond URL shape; a wrong link publishes
  fine and 404s for listeners. Echo them back to the user before publishing.
- **Podcast taxonomy is its own (third) system** — separate from both post
  and page taxonomies. Categories are read-only via the API; tags support
  POST/DELETE (collection-level, id in body) but no PUT — to rename a tag,
  delete and recreate it.
- `GET /podcasts` is the public listing; use `GET /podcasts/admin` when the
  user needs drafts/unpublished episodes too.
- Short URLs are generated on demand via `POST /podcasts/{id}/short-url`,
  not stored on create.
