# Templates, Zones & Blocks

Page structure lives behind ONE endpoint: `POST /graphql`. Templates, their
zones, and the block instances inside each zone are the only part of EdgePress
that is not REST. `ep` drives it fine — the body is just JSON.

Model: **Template** (a layout) → **Zones** (named regions, e.g. `header`,
`main`) → **BlockInstances** (a block type + its config, ordered inside a
zone). A template is `draft` until published; pages/posts opt into a template
by assignment.

## Calling it

```bash
ep POST /graphql '{"query":"query { templates { id name slug type status } }"}'
ep POST /graphql '{"query":"mutation C($input: CreateTemplateInput!) { createTemplate(input: $input) { id } }","variables":{"input":{"name":"Landing","slug":"landing","type":"PAGE"}}}'
```

**GraphQL always answers HTTP 200**, so `ep` exits 0 even on failure. After
every call, check for an `errors` array before assuming it worked:

```bash
ep --raw POST /graphql "$BODY" | jq -e '.errors // empty' && echo "FAILED"
```

## Operations

Queries:

| Operation | Purpose |
|---|---|
| `templates(type, isBaseLayout, limit, offset)` | List templates |
| `template(id, slug)` | One template + `zones { blocks }`, `blocks`, `inheritedBlocks` |
| `blockTypes(category, isActive)` / `blockType(type)` | Block catalogue + JSON schema |

Template mutations: `createTemplate(input)`, `updateTemplate(id, input)`,
`deleteTemplate(id)`, `publishTemplate(id)`, `revertTemplate(id)`,
`setDefaultTemplate(id)`, `copyTemplate(id, input)`,
`assignTemplateToPage(pageId, templateId)`, `assignTemplateToPost(postId, templateId)`.

Zone mutations: `createZone(input)`, `updateZone(id, input)`, `deleteZone(id)`,
`reorderZones(templateId, zoneIds)`.

Block mutations: `createBlockInstance(input)`, `updateBlockInstance(id, input)`,
`deleteBlockInstance(id)`, `reorderBlockInstances(zoneSlug, blockIds)`.

## Inputs

```
CreateTemplateInput   name! slug! type! description isDefault isBaseLayout
                      parentTemplateId thumbnail config
                      type ∈ PAGE | POST | ARCHIVE | HOME | ERROR | CUSTOM
UpdateTemplateInput   same fields, all optional, plus status
CreateZoneInput       templateId! name! slug! description maxBlocks orderIndex config
CreateBlockInstanceInput
                      zoneSlug! blockType! config!  (+ one of templateId | pageId | postId)
                      orderIndex visibility isActive
```

`config` must satisfy the block's own schema — fetch it first:

```bash
ep GET /blocks                       # catalogue — 20 types
ep GET /blocks/hero/schema           # the settings 'hero' accepts
ep GET /blocks/featured-post/schema  # 40 fields: source, layout, typography, container, responsive
ep GET /blocks/navigation/schema     # every type has one now, not just these
```

## Build order

1. `ep GET /blocks` — learn what block types exist.
2. `ep GET /blocks/<type>/schema` for each type you plan to use. A `404
   unknown_block_type` means that block's settings are neither documented nor
   validated — its config is free-form, so read the block back to confirm.
3. `createTemplate` → keep the returned `id`.
4. `createZone` per region (`orderIndex` 0..n).
5. `createBlockInstance` per block, `config` built from the block's schema.
6. `reorderBlockInstances(zoneSlug, blockIds)` if the order changed.
7. `publishTemplate(id)` — a draft template does not render.
8. `assignTemplateToPage(pageId, templateId)` to put it on a page.

## Gotchas

- **`config` is REPLACED, not merged.** `updateBlockInstance` writes the object
  you send over the stored one (`config = ?`). Sending `{"config":{"title":"x"}}`
  silently drops every other setting the block had. Read the block first, merge
  your change into its config, send the whole object back — the same
  GET → merge → PUT rule the REST resources follow.
- **Every block type is validated.** All 20 registered types have a schema; a
  violation is a GraphQL error with `extensions.code = "invalid_config"` and a
  `validationErrors` array naming the offending path. Fetch the schema first
  and you will not hit it. (A type added to `block_types` without a schema file
  still skips validation — `GET /blocks/<type>/schema` answering 404 is the
  tell.)
- **Validation runs on the object you send**, so a replacement config must
  satisfy `required` (`source` for featured-post, `title` for hero — most block
  types require nothing) even when you are only changing one field. Another
  reason to send the merged whole.
- **What you send is what is stored.** Schema defaults are applied at render
  time, not written into the row, so reading a block back returns only the keys
  you set. Consult the schema for the effective value of anything you omitted.
- **200 ≠ success.** Always inspect `errors` (see above).
- **Publish is a separate step.** Creating and filling a template leaves it in
  `draft`; nothing renders until `publishTemplate`.
- **`reorderBlockInstances` keys on `zoneSlug` alone.** The write is safe (it
  matches by block id), but the returned list contains every block sharing that
  zone slug across templates — don't treat the response as the template's zone.
- **Read-only PATs get 403** on `POST /graphql` like any other write.
- **Mutations need `editor` or `admin`.** An `author`, `columnist` or
  `contributor` token authenticates fine and then gets
  `editor role required` (`extensions.code: FORBIDDEN`) on every mutation —
  still HTTP 200. Queries are unaffected.
- **Zone slugs are the join key** for blocks (`zoneSlug`), not zone ids.
