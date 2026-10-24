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
7. `ep POST /templates/<id>/publish` — stamps a published snapshot and flips
   `status`. Note: this is bookkeeping the admin UI reads, NOT a render gate —
   no renderer consults `templates.status`, so a template renders whether or
   not you call this.
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

## Bundle import/export

Move a whole design — one template or a site's worth — as a single JSON file,
instead of ~9 round-trips per landing page through the REST calls above.
Three routes, all under `/api/templates`:

| Route | Role | Purpose |
|---|---|---|
| `GET /templates/export?templates=<slug,…>&pages=<slug,…>&content=0\|1&siteWide=0\|1&theme=0\|1` | `editor` | Build and download a bundle. `Content-Disposition: attachment`. Read-only PATs allowed (it is a GET). At least one of `templates`, `pages`, `siteWide` must be given. |
| `POST /templates/import/preview` | `editor` | Body is a bundle (or `{"bundle":{…}, "onCollision":{…}, "onUnresolved":"fail\|drop"}`). Writes nothing; returns the plan: per-template/page action, unresolved refs, external media, rejected fields, theme status. `valid:false` is a normal 200 — only an unreadable request is 4xx. |
| `POST /templates/import/apply` | **`admin`** | Body is `{"bundle":{…}, "onCollision":{"templates":{…},"pages":{…}}, "onUnresolved":"fail\|drop"}`. Validates everything, then writes in one atomic `db.batch` — nothing lands on any failure. |

`apply` needs `admin`, stricter than every sibling template route (`editor`
is enough for export and preview): it is a bulk operation that can overwrite
many designs in one call, so the gate is intentionally higher than a single
block edit.

### Bundle shape: `config` is byte-exact, `refs` carries portability

A block's `config` travels **exactly** as stored — no rewriting. Every
cross-entity id in it (`categoryId`, `tagId`, `postIds`, an `ImageRef`
`mediaId`) is a tenant-local autoincrement integer that means nothing in
another database, but every block schema is `additionalProperties: false`
and types those fields as numbers — so swapping in a portable value (a slug
string) would fail the block's own schema on import. Instead each block
carries a sibling `refs` array, `{ at, kind, …identity }`, where `at` is an
RFC 6901 JSON Pointer into that block's `config` (e.g. `/categoryId`,
`/backgroundImage/mediaId`) and the identity fields are things that DO
survive a move — a category's `slug`, a media item's `url`/`filename`. On
import, each ref is resolved to a local id on the target site and `config` is
patched at that pointer *before* validation. `kind` is one of `media`,
`category`, `tag`, `post`, `page`. A ref that cannot be resolved on the
target site is reported — in `externalMedia` for `media`, in `unresolved`
for everything else — never silently dropped unless `onUnresolved:"drop"`
was explicitly sent.

### Parent chains complete automatically

A template with no header/footer looks broken, and those blocks live on the
base layout (`default-base`), not on the page template itself. So exporting
a template whose `parent_template_id` points elsewhere walks that chain and
includes every ancestor, each marked `"included": "dependency"` in the
bundle so a reader can tell what was asked for from what was dragged along
to make the design render correctly. Import refuses a bundle whose `parent`
ref cannot be resolved, and refuses a parent cycle.

### A create is inert; an overwrite is live immediately

**Only a CREATE is inert.** A template `apply` creates lands
`status='draft'`, `is_default=0`, and a page it creates lands
`status='draft'` — so a newly imported page is not served until you publish
it with `POST /pages/<id>` or the page editor.

**An OVERWRITE is not inert, and cannot be undone.** It replaces the target
template's zones and blocks — or the target page's title, body and template
assignment — in place, and deliberately leaves `status` and `is_default` as the
operator set them. So overwriting a published template or page changes what
visitors see on the next request, and the CMS keeps no template history to roll
back to. Preview first (`POST /api/templates/import/preview`), and prefer
`create-new` unless the operator has asked for the existing design to be
replaced.

**`parent` is always present on an export: a `ref` string, or `null`.** A
template with a base layout names it; one genuinely without a base layout says
`"parent": null`. So an exported bundle always states the design's inheritance
explicitly, and re-importing it reproduces it.

**On an overwrite, an OMITTED `parent` is preserved; an explicit
`parent: null` clears it.** Leave the key out and the target keeps whatever base
layout it already had; send `"parent": null` to deliberately detach it. That
asymmetry is on purpose: since every export states the key, a bundle missing it
is one you or another agent wrote by hand and simply left out — "I did not say",
not "no base layout" — and clearing the link there would strip the header and
footer off a live design. On a CREATE the two are the same thing: no parent.

The one case where an export omits `parent` is a template whose parent row could
not be read. That is not reported as `null`, which would be a false claim; the
key is left out (so import preserves) and the bundle carries an `anomalies`
entry naming the template. If you see `anomalies` in a bundle, read it before
importing.

Do not reason about an imported template's visibility from `templates.status`:
**no renderer reads that column.** It is a label the admin UI shows, written by
`POST /templates/<id>/publish`; a template with `status='draft'` renders
exactly like a published one, and on a freshly provisioned site every seeded
template is `'draft'`. The column that does gate rendering is `pages.status`.

What actually protects the target site from imported markup is the
import-side sanitiser, not a flag: every HTML and `customCss` field in a
bundle is run through the renderer's allowlist before anything is written, and
each removal is reported in the response's `rejected` array. Read it.

### Collisions have no default — the caller must choose

If a bundle's template or page slug already exists on the target site, the
plan reports `action: "collision"` and the import is invalid until the
caller supplies a decision in `onCollision`: `"create-new"` (suffix the
slug), `"overwrite"` (replace that template's zones/blocks in place, keeping
its id and any page assignments), or `"skip"`. There is deliberately no silent
default —
overwriting is destructive and a suffixed slug leaves the old URL 404ing, so
guessing either way would be wrong some of the time. `create-new` suffixes
start at **`-2`** (`landing` → `landing-2` → `landing-3`, …), matching
`store-app`'s `design/migrate/apply.js` rather than `copyTemplate`'s `-1`
convention — `-1` beside the original reads as "the first of something,"
which it isn't.

**`onCollision` has TWO keyspaces, and a flat map is a 400.** Send

```json
{"onCollision": {"templates": {"<ref>": "overwrite"}, "pages": {"<slug>": "skip"}}}
```

`templates` is keyed by each template's `ref` (its `slug` is accepted as a
second lookup); `pages` is keyed by the page's `slug`. A template and a page
may legitimately share a slug — `about` is the usual pair — and a single flat
map could not say which one a decision was for, so a decision meant for the
page was applied to the template too and deleted its zones and blocks.
Overwrite is the only irreversible path in this feature (the CMS keeps no
template version history), so an ambiguous key is refused rather than guessed:
any key other than `templates`/`pages` makes the request a 400 that names both
keyspaces and the offending key.

**A reserved slug is skipped, not refused — it means "use the one this site
already has".** The eight seeded slugs (`default-base`, `default-home`,
`single-post`, `single-page`, `category-archive`, `tag-archive`, `search`,
`default-404`) come back as `action: "skip"`, `reason: "reserved_slug"`, with
a `detail` saying the site's existing seeded template was used. Nothing is
written for that entry, the existing row is left exactly as it is, and any
child in the same bundle whose `parent` names that ref gets the **target
site's own** row as its `parent_template_id`. Other entries in the same bundle
proceed normally.

Do not send an `onCollision` choice for a reserved slug — it is ignored. The
eight stay un-creatable and un-renamable (control-plane migrations target them
by name, so a `default-base-2` or a renamed `single-post` breaks upgrades
fleet-wide), so `"overwrite"` and `"create-new"` are overridden to the skip.

This previously read "refused outright — `action: "refused"`", which was
wrong and made the feature unusable: export auto-includes the whole parent
chain and every seeded design descends from `default-base`, so EVERY exported
bundle carried a reserved slug and apply answered 400 for all of them. Worse,
`refused` never reached `plan.errors`, so preview reported `valid: true` on a
bundle apply then rejected. **Preview's `valid` and apply's status always
agree now**: `valid: true` ⇒ 200, `valid: false` ⇒ 400. If you see them
disagree, that is a bug, not a decision to work around with `onCollision`.

### Theme tokens are reported, never applied

A bundle may carry a `theme.tokens` section (whatever the source site had).
Both preview and apply report `theme: { present, applied: false, note }` —
this product has no per-tenant theme to write into, so the section is
informational only and is never persisted.

### Imported HTML is sanitised, and imported slugs must be unique in the file

`config.html`/`config.content` fields in an imported bundle are run through
the renderer's `layout` allowlist before being stored, reported as
`rejected`/`reason: "html_sanitised"`. Script, iframe, style and similar tags
go with their contents, every event-handler attribute goes, and structural
markup (div/section/table/class/style) survives — the same grammar the SSR
renderer applies, applied once at the only writer so every renderer reads
clean data. An imported bundle is a file someone else wrote; the SPA's HTML
renderer puts the stored string straight into the DOM on the public routes,
same origin as `/admin`.

Two templates (or two pages, or two zones in one template) claiming the same
`slug` inside one bundle are a 400 naming both refs and the slug, raised
before any write. Previously this reached the database and returned a bare
409 naming nothing.

### Imported slugs are charset- and length-checked, and nesting is capped

An imported `slug` (template, zone or page) must be Unicode letters, digits,
underscores and hyphens only, and at most 200 characters — the same charset
every other creation path produces, because import is the one writer that
stores the submitted slug verbatim and a slug reaches a URL. `../../x` and a
10 KB slug are both a 400 naming the rule.

A bundle may not nest deeper than **64** levels counted from the bundle object
(a real block config nests about a dozen). Deeper than that is a 400 naming
the limit: `JSON.parse` accepts any nesting, but cloning and serialising the
config do not, and that used to surface as an undiagnosable 500 on both
routes.

### `onUnresolved: "drop"` nulls or skips — it never keeps the foreign id

With `"drop"`, each reference this site cannot resolve is either nulled in
place — where that block's own schema permits null, reported in `unresolved`
as `"action": "nulled"` — or the whole block is left out, where the schema has
no null to write there, reported as `"action": "block_skipped"`. It does not
leave the exporting site's local id in `config`: that id resolves to an
unrelated row on this site, so the block would render against the wrong
category or post and look fine doing it. `"fail"` (the default) still refuses
the whole import instead, and `preview` accepts `onUnresolved` too, so the
plan shows per block what `"drop"` would actually do.

### Imported HTML is stripped of form-control attributes

`config.html`/`config.content` fields in an imported bundle have
`action`, `formaction`, `method`, `name` and `value` removed from any
`form`/`input`/`button`/`label`/`select`/`textarea` tag before the field is
stored — each removal is reported (`rejected`, `reason: "form_attrs_stripped"`).
An imported file is untrusted input; a form `action`/`formaction` is an
exfiltration endpoint its author chose. The renderer deliberately does NOT
strip these from operator-authored content edited directly in the CMS — by
the time content is stored, the renderer can no longer tell an imported
field from a hand-typed one, so import is the only place left to draw the
line.

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
