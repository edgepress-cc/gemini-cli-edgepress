---
description: Set up the EdgePress plugin — walks you through creating a personal access token and configuring the env vars.
---

Walk the user through setup:

1. Tell them to open `https://<their-tenant>/admin/settings/api-tokens` in a browser.
2. Explain the reveal-once token flow. If they only need to read (list/get), suggest a read-only token.
3. Print the exact lines to add to `~/.zshrc` or `~/.bashrc` (or their password manager's shell loader):
   ```
   export EDGEPRESS_TENANT=<their-tenant-hostname>
   export EDGEPRESS_TOKEN=epat_...
   ```
4. Tell them to `source` the file or open a new terminal, then run `/edgepress:whoami` to verify.
