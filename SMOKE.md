# Local smoke test

Post-install manual verification. Run through this once after
`gemini extensions install`, and again after any release bump.

## Prerequisites

- Gemini CLI.
- An EdgePress tenant you can log into (a plain `admin` role is enough).
- `jq` on your PATH (optional but improves `ep` output).

## 1. Install

```
gemini extensions install github://edgepress-cc/gemini-cli-edgepress
```

Restart Gemini CLI so the extension loads.

## 2. Set up auth

```
/edgepress:setup
```

Follow the printed instructions:

1. Open `https://<your-tenant>/admin/settings/api-tokens` and create a token.
2. Add two lines to `~/.zshrc` / `~/.bashrc`:
   ```
   export EDGEPRESS_TENANT=<your-tenant-hostname>
   export EDGEPRESS_TOKEN=epat_...
   ```
3. Open a new terminal (or `source` the file), then restart Gemini CLI.

## 3. Verify

```
/edgepress:whoami
```

Expected: one line like `Connected to blog.edgepress.cc as me@example.com (admin, full-access token). Rate limit: 60 req/min.`

If you see `HTTP 401`, run `/edgepress:setup` again — the token or hostname is wrong.

```
/edgepress:doctor
```

Expected: six pass lines + plugin version.

## 4. Natural-language read

> "list my 3 most recent drafts"

Expected: Gemini loads the `edgepress` skill, reads `references/posts.md`, runs `ep GET /posts?status=draft&limit=3`, and summarises the 3 posts by slug + title.

## 5. Natural-language write

> "create a draft titled 'Smoke test — safe to delete' with content 'This is a smoke test.'"

Expected: Gemini runs `ep POST /posts …` and reports the new post's id + URL. You can verify at `https://<your-tenant>/admin/posts` and delete it.

## 6. Subagent dispatch

```
/edgepress:workflow "list all published posts and report only the count"
```

Expected: `edgepress-workflow` subagent spawns, runs paginated GETs, returns one summary line like `DONE: 0 writes / … / Published posts: <N>`.

## 7. Cleanup

- Delete the smoke test draft via `/admin/posts`.
- If you created a smoke-only PAT, revoke it via `/admin/settings/api-tokens`.

## If anything fails

File an issue at https://github.com/edgepress-cc/gemini-cli-edgepress/issues with:

- Which step failed.
- Exact command + output (redact your token).
- Output of `/edgepress:doctor`.
