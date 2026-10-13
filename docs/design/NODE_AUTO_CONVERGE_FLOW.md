# Node Auto-Converge: Design Overview (RESILIENT-1197)

**Status**: Live on `main`  
**Related Issues**: RESILIENT-1189 (organ), RESILIENT-1207 (analysis), RESILIENT-1215/1216 (duplicate slices)  
**Last Updated**: 2026-10-13

## Summary

The **node auto-converge** flow keeps fleet nodes' SOURCE checkouts byte-for-byte current with `origin/main`, so merged fixes (especially bash-only fixes that don't bump the binary SHA) actually reach and run on the iron.

This document identifies the source files, entry points, and state machines involved.

---

## The Problem: "Merged ≠ Deployed"

Before auto-converge, merged bash-only fixes (e.g., `scripts/ops/rot-reaper.sh` edits, `scripts/coord/` improvements) **never reached the nodes** because:

1. **Binary idempotency short-circuit** — `scripts/ops/node-refresh-chump.sh` exits early when the installed `chump` binary already matches the green-main pointer, skipping the source tree reset entirely.
2. **Bash-only merges don't bump binary SHA** — A merged edit to `scripts/ops/foo.sh` doesn't change the build artifact SHA, so node-refresh treats the node as "already current" and leaves the checkout stale for hours/days.
3. **Organs run stale scripts** — Every systemd ExecStart that runs `bash scripts/coord/bar.sh` pulls from the stale tree, executing yesterday's code.

Real-world example: CJ's `/home/jeff/Projects/Chump` had to be hand `git reset --hard origin/main` to surface the rot-reaper fix (#4637).

---

## The Solution: Unconditional Source Converge

The **node-converge organ** adds an independent, unconditional convergence step:
- Runs on a ~10-min systemd timer (faster than the binary refresh cadence)
- Fetches `origin/main` and resets the SOURCE checkout via `converge_mirror_hard_reset origin/main`
- Never touches the binary; binary-SHA idempotency stays in effect
- Auth-independent (public-repo fetch, no GitHub credentials needed)
- Active-worker-safe (resets only the main checkout; worker worktrees in `.claude/worktrees/*` are untouched)

---

## Key Files and Entry Points

### 1. **The Node Auto-Converge Organ** — `scripts/ops/node-converge.sh`

**What it does**: The primary organ that converges the SOURCE tree to `origin/main` on each tick.

**Key sections**:
- **Lines 1–73**: Header explaining the problem, the fix, and safety guarantees
- **Lines 76–87**: Loads the shared `converge_mirror_hard_reset` primitive from `scripts/coord/lib/converge-mirror.sh` (RESILIENT-001), with a fallback to bare `git reset --hard`
- **Lines 90–100**: Resolves the source checkout (`CHUMP_NODE_REPO`) — looks in `$HOME/chump-host`, `$HOME/Projects/Chump`, `$HOME/chump`
- **Lines 113–133**: Defines `_reconcile_role_organs()` — calls `chump-node-install.sh --reconcile-organs-only` after a successful converge to wire up any newly-merged organs (RESILIENT-1215)
- **Lines 208–232**: **Preconditions**: checks that the repo exists, the cwd is valid, and no rebase/merge/cherry-pick is in progress (DEFER if true)
- **Lines 234–251**: **Stale lock guard** (RESILIENT-1567) — clears crashed git's `index.lock` if it's >2 min old and no git process is running
- **Lines 253–260**: **Fetch** — `git fetch origin main` (auth-independent; offline is a skip, not a fatal)
- **Lines 262–308**: **Idempotency** — if HEAD already == target SHA, exit 0 (fast path); still reconciles organs and checks for stale workers
- **Lines 310–328**: **Converge** — calls `converge_mirror_hard_reset origin/main`, then reconciles organs
- **Lines 330–339**: **Worker restart** (RESILIENT-1453) — if the reset changed `worker.sh`, bounces any running `chump-node*-worker.service` so it reloads the new code

**Emitted events** (appended to `$NODE_AMBIENT`, default `.chump-locks/ambient.jsonl`):
- `node_converged` — checkout was behind and is now at `origin/main`
- `node_converge_skipped` — already current / no repo / operation-in-progress / offline
- `node_converge_failed` — fetch-then-reset failed
- `node_organs_reconciled` — organ reconcile succeeded after converge
- `node_organs_reconcile_failed` — organ reconcile failed (non-fatal)
- `worker_restarted_on_code_change` — a running worker was bounced because `worker.sh` changed under it
- `node_converge_stale_lock_cleared` — a stale git index.lock was cleared
- `node_converge_far_behind` — node is >50 commits behind for >30 min (RESILIENT-1567, alarm)

**Environment overrides**:
- `CHUMP_NODE_REPO` — source checkout to converge (default: auto-discover)
- `NODE_AMBIENT` — ambient stream path (default: `$REPO_ROOT/.chump-locks/ambient.jsonl`)
- `CHUMP_NODE_CONVERGE_REF` — ref to converge to (default: `origin/main`; test hook)
- `CHUMP_NODE_CONVERGE_REMOTE` / `CHUMP_NODE_CONVERGE_BRANCH` — remote + branch (default: `origin` / `main`)
- `CHUMP_NODE_ROLE` — role for organ reconcile (default: `muscle`; read from `$HOME/.chump/node.env` if unset)
- `CHUMP_NODE_CONVERGE_LOCK_MIN_AGE_S` — min age for a stale `index.lock` to clear (default: 120 sec)
- `CHUMP_NODE_CONVERGE_FAR_BEHIND_N` — far-behind threshold (default: 50 commits)
- `CHUMP_NODE_CONVERGE_FAR_BEHIND_MIN` — far-behind alarm delay (default: 30 min)

---

### 2. **The Shared Mirror Converge Primitive** — `scripts/coord/lib/converge-mirror.sh`

**What it does**: The canonical implementation of "advance a pure build-mirror working tree without using a merge."

**Key function**: `converge_mirror_hard_reset <ref>`
- Advances the current working tree to `<ref>` via `git reset --hard`
- Survives untracked files that collide with incoming tracked paths (overwriting them)
- Preserves gitignored files (`.chump/state.db`, `.chump-locks/`, runtime DBs)
- Reports (to stderr) what divergence it had to discard (lines 57–70)
- Returns git's exit status (0 on success)

**Why not `git merge`?** — Merge aborts on "untracked working tree files would be overwritten by merge" (the RESILIENT-001 jam). On nodes with auto-generated `docs/gaps/*.yaml` mirrors and local `chore(backlog)` auto-commits, a merge-based advance silently fails and leaves the node stale.

**RESILIENT-1217 fix** (lines 72–85): When converging to `origin/main`, the function ensures the checkout ends on the `main` BRANCH, not detached HEAD. A bare `reset --hard` can leave you detached; this fix ensures branch continuity.

**Who else uses this?**
- `scripts/ops/node-converge.sh` — the primary organ (above)
- `scripts/ops/node-refresh-chump.sh` — converges the mirror checkout (source tree) to `origin/main` every cycle, before binary-build decisions
- `scripts/coord/backlog-sync.sh --reader` — reader mode converges a reader's mirror to stay in sync

---

### 3. **Node Binary Refresh** — `scripts/ops/node-refresh-chump.sh` (lines 589–611)

**What it does**: Keeps the installed `chump` BINARY current with the "green-main" pointer (the last commit that passed CI).

**The two-phase architecture** (delivered in RESILIENT-1205, #4641):
- **Phase 1 (UNCONDITIONAL)** — Converge SOURCE tree to `origin/main` via `converge_mirror_hard_reset origin/main` every cycle, BEFORE any binary-idempotency check. This is the critical fix: the source is now ALWAYS current, so a newly-merged organ manifest or installer entry is ALWAYS present on disk.
- **Phase 2 (CONDITIONAL)** — Build or pull the binary, pinned to green-main SHA. If the binary is already current, skip the build (fast no-op). If the binary is stale, try to pull a pre-built artifact from CI, fall back to local `cargo build --release`.

**Lines 589–611** (from the actual file):
```bash
# Always converge the source tree to origin/main first, BEFORE binary decisions
converge_mirror_hard_reset origin/main
# (Then binary-refresh logic follows, possibly exiting early if binary is already current)
```

**Why separate from node-converge?** — Because binary refresh also handles the green-main pin (RESILIENT-327), artifact pulling (INFRA-3677), and cold builds. node-converge is the lightweight, gh-independent first-hop; node-refresh is the full binary pipeline.

---

### 4. **Organ Manifest** — `scripts/ops/organ-manifest.txt` (lines 416–438)

**The declaration that makes auto-converge real on the iron**:

```
enabled     chump-node-converge.timer  role=muscle requires=bin:git
```

- **`enabled`** — this organ must be active and auto-healing
- **`chump-node-converge.timer`** — the systemd timer that drives `scripts/ops/node-converge.sh`
- **`role=muscle`** — tagged for muscle (worker) nodes; unfiltered brain reconcile enables every line regardless of role
- **`requires=bin:git`** — organ is inapplicable if `git` is not found; skips with a `not_applicable` event, never retries

**Lines 416–438** also document:
- Why the organ exists (bash-only fix problem, the #1 systemic wound)
- How it differs from node-refresh (independent, auth-free, fast)
- Safety guarantees (main checkout only, gitignored files preserved, defers mid-operation, idempotent)
- Worker-restart safety (RESILIENT-1453)

---

### 5. **Organ Installer** — `scripts/setup/install-helsinki-atc.sh`

**What it does**: Places the systemd timer unit file for `chump-node-converge.timer` on the node.

**Invoked by**: `chump-node-install.sh --reconcile-organs-only` (called by node-converge after a successful converge)

**The unit files** (tracked in repo):
- `scripts/dispatch/chump-node-converge.timer` — the timer definition (cadence ~10 min, persistent across reboots)
- `scripts/dispatch/chump-node-converge.service` — the oneshot service that runs `scripts/ops/node-converge.sh`

The installer reads the organ manifest, verifies applicability (`requires=bin:git`), and `systemctl enable --now` the timer if it's not already active.

---

## State Machine: "Merged" → "Deployed"

### Condition: A bash-only fix merges into `origin/main`

**Example**: Fix to `scripts/ops/rot-reaper.sh` lands in PR #4999

### Tick 1 (node-converge.sh runs)

1. **Fetch**: `git fetch origin main` → local refs are now current
2. **Check idempotency**: `HEAD` is behind `origin/main`, so reset is not a no-op
3. **Converge**: `converge_mirror_hard_reset origin/main` → working tree now has the fix
4. **Reconcile organs**: `chump-node-install.sh --reconcile-organs-only` — if the fix also touched organ manifests, they're installed now
5. **Emit**: `kind=node_converged` to ambient

### Tick 2+ (any bash organ that runs)

- The rot-reaper or any other `bash scripts/ops/foo.sh` organ now runs from the current tree
- **The fix is live on the iron**

### Comparison: Old path (without auto-converge)

1. PR merges, `origin/main` HEAD moves
2. node-refresh checks: binary SHA hasn't changed, so `exit 0` (fast idempotency short-circuit)
3. Working tree is never reset
4. Every bash organ continues running the old script for hours/days
5. **The fix is dead code**

---

## Safety Guarantees

### Active-Worker Safe

- **What**: A worker is building a gap in a linked worktree under `.claude/worktrees/chump-<id>` when the converge happens
- **Why safe**: Converge resets ONLY the main checkout. Linked worktrees have their own `.git/objects`, `.git/HEAD`, working-tree files — independent of the main checkout
- **Proof**: `.claude/worktrees/` is gitignored, so `git reset --hard` in the main checkout never sees it as a collision or deletion
- **Result**: Worker's in-flight gap is untouched; converge and work happen in parallel

### Live DB Safe

- **What**: `.chump/state.db` (and its WAL files `-wal`, `-shm`) are being written during a converge
- **Why safe**: `converge_mirror_hard_reset` uses `git reset --hard`, never `git clean -x`; gitignored files survive
- **Result**: DB write is not corrupted; DB read/write continues across the reset

### Defers on In-Progress Rebase

- **What**: An operator or another organ is mid-rebase in the main checkout
- **Why**: Never reset a tree someone is actively editing
- **How**: Checks for `.git/rebase-merge`, `.git/rebase-apply`, `.git/MERGE_HEAD`, etc. (lines 220–232)
- **Result**: Converge tries again on the next tick; the operator is not surprised

### Idempotent

- **What**: Tree already at `origin/main`
- **Result**: Reset is a no-op; exits 0 with `node_converge_skipped "reason": "already_current"`

---

## Integration Points

### With Binary Refresh (node-refresh-chump.sh)

**Before RESILIENT-1205**: node-refresh was the ONLY place source trees got reset, and only AFTER a binary idempotency check (which often skipped it).

**After RESILIENT-1205**: Two independent organs, same primitive:
1. **node-refresh** (binary-focused) — converges source, then builds/pulls binary pinned to green-main
2. **node-converge** (source-focused) — converges source unconditionally, independent cadence

**Why two?** — Decoupling concerns: binary can be cold/slow (cargo build); source must be fast and auth-free.

### With Organ Reconcile

**After a successful converge**, the `_reconcile_role_organs()` function (lines 119–133) immediately calls `chump-node-install.sh --reconcile-organs-only`.

**Why**: If a merged PR added a new organ (e.g., new systemd unit in `scripts/dispatch/`, new line in `organ-manifest.txt`), the organ must be installed BEFORE the next timer tick, not on the slower `chump-organ-reconcile.timer` cadence.

**Example**: PR #5350 adds `chump-new-organ.timer`. Converge tick lands the new unit files. Reconcile installs them immediately. Next organ-watchdog tick verifies them alive. **No gap.**

### With Worker Restart (RESILIENT-1453)

**Problem**: A running `chump-node*-worker.service` was exec'd ONCE at service start. A merged `worker.sh` fix stays inert for the entire duration of an in-flight gap.

**Solution**: After converge, `_maybe_restart_stale_workers()` (lines 161–206) detects if `worker.sh` changed and bounces the running service via `systemctl restart`.

**Grace**: SIGTERM + WIP checkpoint (INFRA-686) — worker handles restart gracefully, saving in-flight state.

---

## Testing

### Unit Tests

- **`scripts/ci/test-node-converge.sh`** — exercises the organ's converge + idempotency paths, verifies ambient events
- **`scripts/ci/test-node-refresh-green-main.sh`** — verifies source tree lands on `origin/main` HEAD while binary stays pinned to green (the split introduced by RESILIENT-1205)

### Integration

- **Roll-Call gate** (scripts/ci/test-resilient-366-organ-roll-call.sh) — ensures `chump-node-converge.timer` is declared in organ-manifest.txt and doesn't go dark silently
- **Fleet doctor** (scripts/dispatch/fleet-doctor.sh) — checks if organs listed in manifest are actually active on the node

---

## Related Gaps and Resolutions

### RESILIENT-1215 — "Wire organ merge into auto-converge" (closed as superseded)

Proposed: Add explicit wiring to ensure a newly-merged organ is installed during auto-converge.

**Resolution**: Already satisfied by `_reconcile_role_organs()` in node-converge.sh (lines 119–133), called unconditionally after every successful converge (line 328).

### RESILIENT-1216 — "Enable installation and fire step on CJ" (closed as superseded)

Proposed: Verify organs actually fire after converge.

**Resolution**: Already satisfied:
1. `_reconcile_role_organs()` calls `chump-node-install.sh --reconcile-organs-only` (line 126)
2. That installer fires each organ with `systemctl enable --now 'chump-$name'` (line 198 of chump-node-install.sh)
3. `scripts/ci/test-resilient-1215-converge-reconciles-organs.sh` (#5227) verifies the path and passes

---

## Runbook: "Merged Bash Fix Not Running"

1. **Check if converge ran**: Look at the node's ambient stream (`.chump-locks/ambient.jsonl`) for `kind=node_converged` or `node_converge_skipped` events in the last 15 min
2. **Force a converge**: Run `bash scripts/ops/node-converge.sh` by hand (requires git, no auth needed)
3. **Check systemd timer**: `systemctl status chump-node-converge.timer` — is it enabled and active?
4. **Check preconditions**: Is a rebase/merge in progress? (`git status`)
5. **Check stale lock**: Is `.git/index.lock` stuck? (node-converge auto-clears it after 2 min)
6. **Check organ reconcile**: After converge, did organs reconcile? Look for `kind=node_organs_reconciled` or `node_organs_reconcile_failed`

---

## References

- **RESILIENT-1189** (parent gap) — the umbrella for node auto-converge
- **RESILIENT-1207** (analysis) — root-cause analysis of the binary-SHA idempotency bug
- **RESILIENT-001** (converge primitive) — why `git reset --hard` instead of merge
- **RESILIENT-200** (node-refresh) — binary-focused refresh, separate from source
- **RESILIENT-327** (green-main pin) — binary build is pinned to green, not HEAD
- **RESILIENT-1215/1216** (dup slices) — already-satisfied organ-install requirements
- **RESILIENT-1453** (worker restart) — bounce workers when worker.sh changes under them
- **RESILIENT-1567** (stale lock) — clear crashed git's index.lock to unblock converge
- **RESILIENT-345** (CJ node sync) — complementary: sync the gap-store state.db from origin
- **RESILIENT-347** (per-node-applicable) — applicability filtering in organ reconcile
- **INFRA-3677** (artifact pull) — speed binary refresh via GH-hosted CI artifacts

---

## Future Work

- **INFRA-7756** (one-command-install unification) — fold node-converge into the master organ manifest alongside launchd organs
- **Mesh propagation** — coordinate converge across multiple nodes so main always leads
- **Converge analytics** — track "time from merge to live" per fix type (bash, Rust, manifest, etc.)
