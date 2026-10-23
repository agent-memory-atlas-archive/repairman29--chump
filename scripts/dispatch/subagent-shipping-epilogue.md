## Shipping (CRITICAL — read in full before ending)

**Canonical path:**
```bash
scripts/coord/bot-merge.sh --gap <YOUR-GAP-ID> --auto-merge
```

**If `bot-merge.sh` hangs > 30s** (no output):
```bash
scripts/dev/chump-binary-unwedge.sh  # Heal INFRA-275 binary wedge (idempotent)
```

**If still hung — manual recovery:**
```bash
CHUMP_GAP_CHECK=0 git push -u origin <your-branch> --force-with-lease
gh pr create --base main --title "..." --body "..."
chump gap link-pr <GAP-ID> <PR-number> --sha "$(git rev-parse HEAD)"  # CREDIBLE-1550 AC1: ship refuses without this link (CREDIBLE-1551 AC2)
gh pr merge <PR-number> --auto --squash
chump gap ship <GAP-ID> --closed-pr <PR-number> --update-yaml
```

**Forbidden:** Do NOT use `--no-verify` or silently hand-edit `docs/gaps/<ID>.yaml` (INFRA-301).

**Final report:**
```
PR number: #NNNN
Files changed: N
Tests added: Y or none
CI state: green/pending/failed
Open TBDs: none or (bullet list)
```
