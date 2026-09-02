# Daily cartoons

Ordered collections of cartoon items. A collection (e.g. one day's strip set)
contains `daily_cartoon_items` whose order matters; ordering changes go
through the dedicated `/reorder` endpoint, never by rewriting the collection.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/daily-cartoons` | List collections |
| GET | `/daily-cartoons/{id}` | One collection, with its items in order |
| POST | `/daily-cartoons` | Create a collection (items inline) |
| PUT | `/daily-cartoons/{id}` | Full update — GET first, merge, PUT |
| DELETE | `/daily-cartoons/{id}` | Delete a collection |
| POST | `/daily-cartoons/{id}/reorder` | Reorder items within a collection |

## Common bodies

Create a collection with items (media uploaded first — see `media.md`):

```json
{
  "title": "Cartoons — Sep 2",
  "items": [
    {"media_id": 201, "caption": "Monday's strip"},
    {"media_id": 202, "caption": "The follow-up"}
  ]
}
```

Reorder items (array of item ids in the desired order):

```json
{"item_ids": [502, 501, 503]}
```

## Response shape

```json
{
  "id": 31,
  "title": "Cartoons — Sep 2",
  "items": [
    {"id": 501, "media_id": 201, "caption": "Monday's strip", "position": 0},
    {"id": 502, "media_id": 202, "caption": "The follow-up", "position": 1}
  ]
}
```

## Gotchas

- **Reordering is its own endpoint.** Never reorder by PUTting the
  collection with items shuffled — use `POST /daily-cartoons/{id}/reorder`.
  Rewriting the collection to move items risks recreating item rows and
  breaking their ids.
- **Update is PUT** with the usual GET → merge → PUT discipline. Omitting
  `items` in a PUT body can wipe the collection's items — always send the
  full object.
- Items reference uploaded media by `media_id` — upload via
  `POST /media/upload` (multipart, raw curl — see `media.md`) BEFORE
  creating the collection, then use the returned ids.
- Item `position` in responses is informational; the authoritative way to
  change it is `/reorder`. Don't PATCH positions — there is no PATCH here.
- Deleting a collection deletes its items but NOT the underlying media —
  the images stay in `/media` for reuse.
- Deleting media that a cartoon item references breaks the strip's render;
  check item references before any `DELETE /media/{id}`.
