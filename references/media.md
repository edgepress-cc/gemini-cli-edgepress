# Media

Image and file uploads, stored in R2. Other resources reference media by `id`
(e.g. a post's `featured_image_id`), never by URL.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/media` | List (query: `limit`, `offset`) |
| GET | `/media/{id}` | Read one item's metadata |
| POST | `/media/upload` | Upload — `multipart/form-data`, NOT JSON |
| POST | `/media/uploads` | Start a chunked upload (files over 20 MB) — JSON `{name, type, size}` → `{id, partSize, parts}`; `purpose: "wordpress_export"` (admin, `.xml` ≤ 500 MB) stores a WordPress export privately for `POST /import/wordpress {export_id}` and complete answers `{export_id, size}` |
| PUT | `/media/uploads/{id}/parts/{n}` | One part (1-based), raw bytes, `partSize` each but the last → `{partNumber, etag}` |
| POST | `/media/uploads/{id}/complete` | `{parts: [{partNumber, etag}]}` → same answer as `/media/upload` |
| PUT | `/media/{id}` | Update metadata (alt text, title) |
| DELETE | `/media/{id}` | Delete — check references first! |
| POST | `/media/{id}/og-variant` | Generate an Open Graph variant of an image |

## Common bodies

Upload — **`ep` cannot do multipart**; this is the one call that needs raw
`curl`:

```bash
curl -sS -X POST "https://$EDGEPRESS_TENANT/api/v1/media/upload" \
  -H "Authorization: Bearer $EDGEPRESS_TOKEN" \
  -F "file=@/path/to/hero.jpg"
```

Update metadata (JSON, via `ep`):

```json
{"alt_text":"Sunrise over the harbor","title":"Harbor sunrise"}
```

## Response shape

```json
{
  "id": 108,
  "url": "https://blog.edgepress.cc/media/hero.jpg",
  "mime_type": "image/jpeg",
  "size_bytes": 245812
}
```

## Gotchas

- **Upload is multipart, not JSON.** `POST /media/upload` takes
  `multipart/form-data` with the file in the `file` field. The `ep` wrapper
  only speaks JSON — use the raw `curl -F` form above. Everything else
  (list, read, metadata update, delete) works through `ep` normally.
- **Over 20 MB, upload in parts.** A single request over 100 MB never reaches
  the site. Default caps: image 20 MB, video 20 MB, audio 20 MB, other files 50 MB; a site may differ, so read `GET /api/media/limits`.
  Split the file with `split -b <partSize>`, PUT each piece with
  `curl --data-binary @piece`, keep each `etag`, then POST `complete`. A failed
  part can be re-sent; an upload never completed is dropped after 24 h.
- **Reference media by `id`.** The upload response contains both `id` and
  `url`. Use the `id` in fields like `featured_image_id`; the `url` is for
  humans and rendered output.
- **Deleting referenced media breaks content.** A post whose
  `featured_image_id` points at deleted media renders broken. Before
  `DELETE /media/{id}`, check what references it and warn the user.
- The metadata update is `PUT /media/{id}` — it changes alt text/title only,
  never the binary. To replace an image, upload a new file and repoint
  references to the new `id`.
- `POST /media/{id}/og-variant` produces a social-card-sized variant of an
  existing image; it returns a new media record — use its `id` where an OG
  image is expected.
- Large uploads count against the 60 req/min rate limit like any call; for a
  batch of uploads, hand off to the workflow subagent rather than looping.
