---
description: Dispatch a multi-step content workflow to the edgepress-workflow subagent — for bulk imports, series drafting, site-wide sweeps.
---

Task: $1

Dispatch the `edgepress-workflow` subagent via the Agent tool with the above task as its prompt. When the subagent returns, relay its structured summary (WORKFLOW / DONE / NEW / FAILED / WORKLIST lines) back to the user verbatim. Do not paraphrase or truncate the summary.
