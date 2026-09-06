# Templates, Zones & Blocks

Page structure now has a REST façade: 18 operations under `/api/v1`, covering
the full build chain. **Use REST.** It returns real HTTP status codes, so `ep`
exits non-zero when something fails — no error-array spelunking. GraphQL
(`POST /graphql`) remains for full-power use and for the operations the façade
deliberately omits (see the GraphQL section); it answers **HTTP 200 even on
failure**, which is exactly why REST is now the recommended path for agents.

Model: **Template** (a layout) → **Zones** (named regions, e.g. `header`,
`main`) → **BlockInstances** (a block type + its config, ordered inside a
zone). A template is `draft` until published; pages opt into a template by
assignment.

## REST surface

| Route | Purpose |
|---|---|
| `GET /templates?type=&isBaseLayout=&limit=&offset=` | List — defaults first, then newest |
| `POST /templates` | Create → 201. `name!` `type!` (`PAGE\|POST\|ARCHIVE\|HOME\|ERROR\|CUSTOM`); slug generated from name when omitted, duplicate slug → 409 |
| `GET /templates/<id>` | One template, `zones[].blocks[]` inlined (REST has no field selection) |
| `PATCH /templates/<id>` | Partial update — only supplied fields change (+`status`); slug collision → 409 |
| `DELETE /templates/<id>` | 204. **Not idempotent**: unknown id → 404, default template → 409 (set another default first) |
| `POST /templates/<id>/publish` | Sets `published`, stamps `publishedAt`, snapshots `publishedVersion` — the commit point |
| `GET /templates/<id>/zones` | The template's zones |
| `POST /templates/<id>/zones` | Create zone → 201. `name!`; `templateId` comes from the path (one in the body is ignored); slug already in this template → 409 |
| `GET /zones/<zoneId>` `PATCH /zones/<zoneId>` | One zone; PATCH is partial |
| `DELETE /zones/<zoneId>` | 204 — deletes the zone **and every block in it**; idempotent (unknown id still 204) |
| `POST /templates/<id>/zones/reorder` | Body `{"zoneIds":[…]}` — array order becomes `orderIndex` 0..n; ids not in this template are ignored |
| `GET /templates/<id>/blocks?zone=<slug>` | The template's blocks, optionally one zone's |
| `POST /templates/<id>/blocks` | Add block → 201. `zoneSlug!` `blockType!` `config!`; unknown `blockType` → 404 |
| `PATCH /blocks/<blockId>` | Partial update; `config` **merges** — see Gotchas |
| `DELETE /blocks/<blockId>` | 204, idempotent (unknown id still 204) |
| `POST /templates/<id>/zones/<zoneSlug>/blocks/reorder` | Body `{"blockIds":[…]}` |
| `PUT /pages/<id>/template` | Body `{"templateId":"…"}` — assign or replace the page's template; `{"templateId":null}` detaches it; 404 if page or template missing |

Every mutating operation requires role **editor or above**: an `author`,
`columnist` or `contributor` token gets a real **403** (GraphQL gives 200 +
`FORBIDDEN` for the same thing). Read-only PATs get 403 on any non-GET.
Errors carry real codes — invalid config → **400** with `validationErrors`,
missing resource → **404**, slug/default conflicts → **409**. Success bodies
use the standard envelope: `{"success":true,"template":{…}}`.

## Build order

1. `ep GET /blocks` — learn what block types exist (20 registered).
2. `ep GET /blocks/<type>/schema` for each type you plan to use. A
   `404 unknown_block_type` means that block's settings are neither documented
   nor validated — its config is free-form, so read the block back to confirm.
3. Create the template, keep the returned `id`:

   ```bash
   ep POST /templates '{"name":"Landing","slug":"landing","type":"PAGE"}'
   ```

4. One zone per region (`orderIndex` 0..n):

   ```bash
   ep POST /templates/<id>/zones '{"name":"Main","slug":"main","orderIndex":0}'
   ```

5. One call per block, `config` built from the block's schema:

   ```bash
   ep POST /templates/<id>/blocks '{"zoneSlug":"main","blockType":"hero","config":{"title":"Hi"}}'
   ```

6. If the order changed:
   `ep POST /templates/<id>/zones/main/blocks/reorder '{"blockIds":["b2","b1"]}'`
7. `ep POST /templates/<id>/publish` — a draft template does not render.
8. `ep PUT /pages/<pageId>/template '{"templateId":"<id>"}'` to put it on a page
   (`{"templateId":null}` to take it off again).

## GraphQL — full power and what REST omits

The façade deliberately omits: **`revertTemplate`**, **`assignTemplateToPost`**,
a composite "create whole template" call, block-level `GET` by id, and
pagination on zones/blocks. For those — and for field selection or anything
batched — use `POST /graphql`; the mutations `copyTemplate(id, input)` and
`setDefaultTemplate(id)` also live only there (though `PATCH /templates/<id>`
with `{"isDefault":true}` covers the latter).

```bash
ep POST /graphql '{"query":"mutation R($id: ID!) { revertTemplate(id: $id) { id status } }","variables":{"id":"..."}}'
```

**GraphQL always answers HTTP 200**, so `ep` exits 0 even on failure. After
every call, check for an `errors` array before assuming it worked:

```bash
ep --raw POST /graphql "$BODY" | jq -e '.errors // empty' && echo "FAILED"
```

Queries: `templates(type, isBaseLayout, limit, offset)`, `template(id, slug)`
(+ `zones { blocks }`, `blocks`, `inheritedBlocks`), `zone(id)`,
`blockTypes(category, isActive)` / `blockType(type)`. Mutations mirror the REST
surface (`createTemplate`, `updateTemplate`, `deleteTemplate`,
`publishTemplate`, `createZone`, `updateZone`, `deleteZone`, `reorderZones`,
`createBlockInstance`, `updateBlockInstance`, `deleteBlockInstance`,
`reorderBlockInstances`, `assignTemplateToPage`) plus the omitted ones above.
`CreateBlockInstanceInput` takes `zoneSlug! blockType! config!` + one of
`templateId | pageId | postId` — the REST façade only covers `templateId`.

## Gotchas

- **REST `PATCH /blocks/<id>` MERGES config; GraphQL `updateBlockInstance`
  REPLACES it. This divergence is deliberate.** Over REST, incoming top-level
  keys overwrite or add, omitted keys are kept — send just the key you are
  changing. The merge is SHALLOW: a nested object you pass replaces the entire
  stored object at that key. Over GraphQL, the object you send is written over
  the stored one wholesale — `{"config":{"title":"x"}}` silently drops every
  other setting, so read the block first, merge, and send the whole object.
- **Every registered block type is validated.** REST: 400 with
  `validationErrors` naming the offending path (the *merged* result is
  re-validated). GraphQL: 200 with `extensions.code = "invalid_config"`. Fetch
  the schema first and you will not hit either. A GraphQL replacement config
  must itself satisfy `required` (`source` for featured-post, `title` for
  hero); a REST merge keeps existing keys, so this bites only full replaces.
- **DELETE semantics differ by resource.** Zone and block deletes are
  idempotent — an unknown id still returns 204. Template delete is not: 404 on
  an unknown id, 409 if the template is the default for its type.
- **What you send is what is stored.** Schema defaults are applied at render
  time, not written into the row; reading a block back returns only the keys
  you set. Consult the schema for the effective value of anything you omitted.
- **Publish is a separate step.** Creating and filling a template leaves it in
  `draft`; nothing renders until you `POST /templates/<id>/publish`.
- **Block reorder over GraphQL keys on `zoneSlug` alone** and returns every
  block sharing that slug across templates. The REST route carries the template
  id in its path and returns only that template's blocks — trust its response.
- **Mutations need `editor` or `admin`.** REST answers a real 403; GraphQL
  answers 200 with `editor role required` (`extensions.code: FORBIDDEN`).
  Queries are unaffected. Read-only PATs get 403 on any write either way.
- **Zone slugs are the join key** for blocks (`zoneSlug`), not zone ids.
