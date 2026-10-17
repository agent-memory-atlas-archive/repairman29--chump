# Stashed work — durable, agent-referenceable (not on any branch)

When a local branch holds **unmerged work worth keeping** but we don't want it
cluttering the branch list (or auto-shipping), we push it to a custom
**`refs/stash/<date>/<name>`** ref on `origin` instead of `refs/heads/*`.

Why `refs/stash/*` and not a branch:
- **Durable** — it lives on `origin` (GitHub), survives local branch pruning and
  disk wipes; any node/agent can fetch it.
- **No CI, no clutter** — it is not `refs/heads/*`, so it does not trigger
  `on: push` workflows and does not appear in `git branch -r` / PR pickers.
- **Recoverable** — checkout to a real branch when someone resumes the work.

## Machine-appended stash manifest

`scripts/coord/orphan-branch-sweeper.sh` (ZERO-WASTE-136) automatically stashes
**unmerged, stale** remote branches here before deleting them: it pushes the tip
to `refs/stash/<branch>` on origin and appends a row to
[`docs/process/STASHED_BRANCHES.md`](./STASHED_BRANCHES.md). That file is the
machine-readable counterpart of the curated table below — same durability
guarantees, same recovery procedure.

## How agents fetch + inspect the stash

```bash
# list what's stashed on origin
git ls-remote origin 'refs/stash/*'

# fetch all stash refs into local refs/stash/*
git fetch origin 'refs/stash/*:refs/stash/*'

# inspect one
git log --oneline main..refs/stash/2026-07-27/<name>
git diff main...refs/stash/2026-07-27/<name>

# resume it as a real branch
git checkout -b resume/<name> refs/stash/2026-07-27/<name>
```

## Current stash (2026-07-27) — branch bankruptcy cleanup

Context: a local-branch audit found 2,289 branches (fleet exhaust — spent claim
branches + `wip/unknown-*` auto-snapshots). 2,285 were provably-safe to drop
(PR merged / gap terminal / gapless auto-snapshot). Three held **genuine
unmerged work** and were stashed here before the drop:

| Stash ref | What it is | Why it matters |
|---|---|---|
| `refs/stash/2026-07-27/almanac-integration` | almanac↔chump **MCP wiring** + FTUE bootstrap entry + agent directive (`chump-mcp.json`, `crates/chump-coord/src/{mesh,rpc}.rs`) | integrates the [almanac](https://github.com/repairman29/almanac) tool into chump's MCP/coord layer; unmerged |
| `refs/stash/2026-07-27/infra-2248-mesh-localprocess-transport` | `feat(INFRA-2248)`: `LocalProcessTransport` + `BandwidthBudget` + `MessageQueue` + named channels for `chump-coord` mesh | **load-bearing** two-node fleet mesh coordination (Helsinki↔closetjunky); unmerged |
| `refs/stash/2026-07-27/infra-2248-mesh-respawn-3309` | further `chump-coord` mesh work (same INFRA-2248 lineage) | companion to the above |

The other ~2,282 dropped branches were spent exhaust and are **locally
reflog-recoverable for ~90 days** if anything was misjudged
(`git reflog` / `git fsck --lost-found`).

Recurrence of the branch pile-up is addressed by **ZERO-WASTE-033** (post-merge
local-branch pruning in the ship pipeline + stop the `wip/*` snapshot spam).
