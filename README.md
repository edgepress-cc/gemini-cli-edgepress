# gemini-cli-edgepress

EdgePress integration for [Gemini CLI](https://github.com/google-gemini/gemini-cli). Talk to your EdgePress tenant in plain English: draft posts, upload media, run bulk imports.

## Install

```
gemini extensions install github://edgepress-cc/gemini-cli-edgepress
```

## Configure

```
export EDGEPRESS_TENANT=your-subdomain.edgepress.cc
export EDGEPRESS_TOKEN=epat_...
```

Mint a token at `<tenant>/admin/account/api-tokens`.

## Use

Any of the `/edgepress:*` slash commands, or ask Gemini in plain English:
- "List my last 5 posts"
- "Import these 30 markdown files as drafts"
- "Bulk-tag every published post from March with 'featured'"

See `SMOKE.md` for post-install verification.

## Related

- [`edgepress-cc/claude-code-edgepress`](https://github.com/edgepress-cc/claude-code-edgepress) — same skill, Claude Code
- [`edgepress-cc/codex-cli-edgepress`](https://github.com/edgepress-cc/codex-cli-edgepress) — same skill, Codex CLI
- [EdgePress API reference](https://api-docs.edgepress.cc)
