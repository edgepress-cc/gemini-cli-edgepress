# EdgePress — Gemini CLI extension guidance

This file tells Gemini CLI how to route EdgePress requests through this
extension. Load the skill `SKILL.md` first; it teaches Gemini when to
call each `/api/v1` endpoint and when to hand off to a long-running
workflow (bulk imports, series drafting, site-wide sweeps).

## Env vars required

- `EDGEPRESS_TENANT` — tenant hostname, e.g. `blog.edgepress.cc`
- `EDGEPRESS_TOKEN` — personal access token starting with `epat_`

Set both before invoking any `/edgepress:*` command.

## Long-running work

Gemini CLI does not yet ship a formal subagent contract. For workflows
that need >30 API calls or >3 minutes, the SKILL.md's "Workflow patterns"
section walks Gemini through a work-list + idempotency + rate-limit
loop inline. Upgrade to a proper subagent when Gemini CLI adds one.
