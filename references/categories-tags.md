# Categories & tags

Two independent taxonomy systems: one for posts, one for pages. They share no
rows. Categories are hierarchical (`parent_id`); tags are flat.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/posts/categories` | List post categories |
| POST | `/posts/categories` | Create post category |
| PUT | `/posts/categories` | Update — target `id` in the BODY, not the path |
| DELETE | `/posts/categories` | Delete — target `id` in the BODY |
| GET | `/posts/categories/{slug}` | Posts in a category |
| GET | `/posts/tags` | List post tags |
| POST | `/posts/tags` | Create post tag |
| PUT | `/posts/tags` | Update (id in body) |
| DELETE | `/posts/tags` | Delete (id in body) |
| GET | `/posts/tags/{slug}` | Posts with a tag |
| GET/POST/PUT/DELETE | `/pages/categories` | Page categories — separate table |
| GET/POST/PUT/DELETE | `/pages/tags` | Page tags — separate table |

## Common bodies

Create a nested post category:

```json
{"name":"Match Reports","slug":"match-reports","parent_id":5}
```

Rename a tag (collection-level PUT, id in body):

```bash
ep PUT /posts/tags '{"id":12,"name":"Features","slug":"features"}'
```

Delete a category (collection-level DELETE, id in body):

```bash
ep DELETE /posts/categories '{"id":9}'
```

## Response shape

```json
{
  "id": 5,
  "name": "Match Reports",
  "slug": "match-reports"
}
```

## Gotchas

- **PUT/DELETE are collection-level.** There is no `/posts/categories/{id}`
  for writes — the target `id` goes in the request body. `{slug}` paths are
  read-only listings of tagged/categorized content.
- **Post and page taxonomies never share rows.** Creating "News" under
  `/posts/categories` does not create it for pages. If the user wants the
  same label on both, create it twice — once per taxonomy.
- **Categories nest via `parent_id`; tags never nest.** Don't send
  `parent_id` on a tag — it's ignored at best.
- Deleting a category does not delete the posts in it; they lose the
  category association. Warn before deleting a populated category
  (check with `GET /posts/categories/{slug}` first).
- `GET /posts/categories/{slug}` and `GET /posts/tags/{slug}` return the
  posts, not the taxonomy row. To read the row, list and filter by slug.
- Podcasts have their own taxonomy too (`/podcasts/categories`,
  `/podcasts/tags`) — a third system, also separate. See `podcasts.md`.
- Legacy aliases `/page-categories` and `/page-tags` exist; prefer the
  `/pages/...` forms.
