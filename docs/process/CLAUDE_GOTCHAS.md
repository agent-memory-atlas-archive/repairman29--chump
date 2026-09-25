# CLAUDE.md — operational gotchas (cold layer)

> **Read on-demand when you hit a specific failure surface** — chump
> binary hung, raw-YAML guard fired, fleet starved, syspolicyd wedge,
> rebase footgun, etc. This file used to live in `CLAUDE.md`; DOC-018
> (2026-05-04) split out the hot layer (mandatory pre-flight, hard
> rules, ship pipeline) so every spawn doesn't pay the ~13K-token tax.
> The hot layer is now [`/CLAUDE.md`](../../CLAUDE.md). Operators and
> agents read both — but only this one when something specific breaks.

> **Read [`RESEARCH_INTEGRITY.md`](./RESEARCH_INTEGRITY.md) before touching any eval,
> cognitive-architecture code, or research claim.** It supersedes earlier framing in
> CHUMP_PROJECT_BRIEF.md and CHUMP_RESEARCH_BRIEF.md. The accurate thesis is narrower than
> what those docs say.

> **Read [`/AGENTS.md`](../../AGENTS.md) first.** It is the canonical, tool-agnostic
> entry point (build/test/lint commands, code style, gap-registry pattern, PR
> guidelines) and follows the cross-tool [AGENTS.md](https://aaif.io/) convention
> adopted by the Agentic AI Foundation (Linux Foundation, Dec 2025).
>
> **This file** is the Chump-specific overlay: lease coordination, the
> ambient.jsonl peripheral-vision stream, `chump-commit.sh`, the
> commit-time guards, session-ID resolution, and merge-queue discipline. None
> of this is portable to other repos — it's the operating procedure for
> Chump's multi-agent dispatcher.
>
> Chump-internal agents read both files at session start (AGENTS.md first,
> then CLAUDE.md as overlay).

## MANDATORY: run before anything else

Every Claude session, every time. Do not pick a gap, create a branch, or edit files until these pass.

```bash
git fetch origin main --quiet && git status
ls .chump-locks/*.json 2>/dev/null && cat .chump-locks/*.json || echo "(no active leases)"
bash scripts/setup/install-ambient-hooks.sh 2>&1 | tail -2  # FLEET-023: idempotent — wires SessionStart/PreToolUse/PostToolUse/Stop hooks into ~/.claude/settings.json so this session emits to ambient.jsonl. Bypass with CHUMP_AMBIENT_INSTALL_SKIP=1 in env.
tail -30 .chump-locks/ambient.jsonl 2>/dev/null || echo "(no ambient stream yet)"
chump-coord watch &  # FLEET-006: cross-machine peripheral vision (NATS); local file tail above is the durable fallback. Skip if NATS unavailable.
chump gap list --status open                     # canonical (.chump/state.db); per-file mirror fallback: grep -lE 'status:[[:space:]]*open' docs/gaps/*.yaml
python3 scripts/coord/gap-doctor.py doctor       # INFRA-155 (live 2026-04-28): detect YAML↔SQLite drift, ghost gaps, orphan rows BEFORE you reserve. Bucket 3 > 0 means a future `chump gap reserve` may collide silently.
chump gap preflight <GAP-ID>            # exits 1 if done, live-claimed/reserved, or ID missing from registry — stop if so
chump --briefing <GAP-ID>             # MEM-007: per-gap context — gap acceptance + relevant reflections + recent ambient + strategic doc refs + prior PRs
```

**Stale-binary alarm (INFRA-148, ongoing risk).** `chump --version` is wired
to a model probe today (don't rely on it). To check binary freshness run
`ls -la $(which chump)` and compare to `git log origin/main --since=...
src/gap_store.rs src/main.rs --oneline | head` — if main has commits to
either path *after* your binary's mtime, **rebuild before any
`chump gap …` operation**:

```bash
cargo build --release --bin chump && cp target/release/chump ~/.local/bin/chump
```

Stale binary symptoms hit at least 4× this cycle — `chump gap import`
rejecting valid YAML, `--closed-pr` flag missing, dump dropping rows,
silent ID collisions. **Rebuild is cheaper than the friction it prevents.**

**Hung-binary alarm (INFRA-275, observed 2026-05-02).** Distinct symptom
from staleness: `chump gap …` returns no output, no errors, never exits.
`ps` shows accumulating chump processes in state `UE` (uninterruptible
exit). Direct `sqlite3 .chump/state.db 'SELECT COUNT(*) FROM gaps'` works
instantly — so the DB is fine; the *binary itself* is wedged at
`_dyld_start` (the dynamic linker, before `main()`). Root cause: macOS
Sequoia's `syspolicyd` (Gatekeeper / code-signing arbiter) gets the
binary's *inode* into a pending-decision wedge, and every subsequent
launch of the same inode queues behind it. **DO NOT** fall back to
direct `docs/gaps/<ID>.yaml` writes — concurrent siblings each scanning
the filesystem will pick the same "next free" ID and collide. Heal
instead with:

```bash
scripts/dev/chump-binary-unwedge.sh           # probes + replaces wedged inode
CHUMP_DOCTOR_FORCE=1 scripts/dev/chump-binary-unwedge.sh   # skip probe, just heal
```

The doctor moves the wedged binary aside as
`~/.cargo/bin/chump.wedged-inode-<n>` and copies the same content back
through a fresh inode (which `syspolicyd` treats as a new file with no
prior decision). `kill -9` on the UE-state zombies is best-effort; they
fully clear only on reboot but are otherwise harmless. `sudo kill
syspolicyd` (operator-only — needs sudo) is the nuclear option if even
the fresh inode hangs.

**Lesson injection — two paths (post-MEM-006):**
- *Spawn-time, systemic.* Set `CHUMP_LESSONS_AT_SPAWN_N=5` (max 20) to have the
  prompt assembler prepend the top-N recency×frequency-ranked lessons from
  `chump_improvement_targets` at every assembly. Default OFF (preserves COG-024
  safe-by-default). Pairs with the per-model opt-in CSV
  (`CHUMP_LESSONS_OPT_IN_MODELS`) — either path can enable injection
  independently. Precedence in the assembled prompt: spawn lessons →
  user-provided base → task planner → COG-016/COG-024 lessons block →
  blackboard → perception summary.
- *Explicit per-gap, intentional.* `chump --briefing <GAP-ID>` (MEM-007) is the
  on-demand query path. Reads `.chump/state.db` (mirrored in `docs/gaps/<ID>.yaml`) + chump_improvement_targets +
  ambient.jsonl + strategic docs + closed PRs into a single markdown briefing.
  Run after `gap-preflight.sh` and before `gap-claim.sh` so you start the gap
  knowing what the team has already learned about it.

**Task-class-aware lessons gating (EVAL-030, default ON):** the assembler
inspects the raw user prompt and (a) skips the entire lessons block on
trivial chat tokens (< 30 chars trimmed), (b) suppresses the perception
"ask one clarifying question" directive on conditional-chain prompts
("do X, if it fails do Y, then Z"). Set `CHUMP_LESSONS_TASK_AWARE=0` to
disable for harness sweeps measuring the v1 baseline.

The `ambient.jsonl` tail is your peripheral vision — recent file edits, commits, bash calls, and
ALERT events from other concurrent sessions.

**Scope reminder (FLEET-023, 2026-05-02).** `ambient.jsonl` is **filesystem-local** to whatever machine / sandbox you're on. Cross-machine peripheral vision goes through NATS (FLEET-006: `chump-coord watch`, subjects `chump.events.>`). In a fresh remote sandbox (Cold Water, ephemeral CI runner, etc.) where no NATS broker is reachable, the file tail will only show *this* session's own events — typically just two `session_start` lines from this session itself. That's expected, not a bug. If you need cross-machine signal, ensure `CHUMP_NATS_URL` is set to a reachable broker before flagging "ambient empty" as a finding.

**NATS deployment decision (FLEET-053, 2026-05-15).** As of this date, the Cold Water scheduled trigger (`trig_01GA2XVbAZtpkBaWfrEo1CrP`) does **not** have `CHUMP_NATS_URL` set to a public broker — no public NATS broker has been provisioned for the fleet. Consequence: Cold Water cycle ambient evidence will show only local-file events from that runner session; cross-machine fleet activity is **not** visible in Cold Water output. This is intentional, not an oversight. Do **not** file a finding like "NATS subscription silent" or "ambient stream empty" — local-file silence in a Cold Water context reflects the absence of a broker, not a bug. If a public broker is provisioned in future, set `CHUMP_NATS_URL=nats://<host>:4222` in the trigger environment and remove this note.

Event kinds to know:
- `session_start` — another agent just opened a session (note their worktree and gap)
- `file_edit` — another agent edited a file (note the path — may overlap yours)
- `commit` — a commit landed (note the sha and gap — may have advanced main)
- `bash_call` — another agent ran a command (cargo check failure? test run?)
- `ALERT kind=lease_overlap` — **stop and read**: two sessions claim the same file
- `ALERT kind=silent_agent` — a live session stopped heartbeating; its work may be lost
- `ALERT kind=edit_burst` — rapid file mutations in progress; possible rebase stomp
- `ALERT kind=queue_config_drift` — branch-protection rule on `main` no longer matches `docs/baselines/branch-protection-main.json`; auto-merge may be silently disarmed (INFRA-121, run `scripts/ops/branch-protection-drift.sh --dry-run` to inspect)

Then claim the gap before writing any code:
```bash
# Write gap claim to lease file — NO YAML EDIT, no git push needed:
scripts/coord/gap-claim.sh <GAP-ID>
```

**The ID you claim MUST already exist on `origin/main` OR be reserved for your session.**
For **new** gaps, prefer **`chump gap reserve --domain INFRA --title "short title"`**
(canonical SQLite path post-INFRA-059). The legacy
`scripts/coord/gap-reserve.sh <DOMAIN> "short title"` shell path still works as a
fallback. Both paths atomically pick the next free ID (main registry + open PRs +
live leases) and write `pending_new_gap: {id, title, domain}` into your lease.
Run `chump gap ship <ID> --update-yaml` so the human-readable mirror at
`docs/gaps/<ID>.yaml` reflects the new gap, and ship implementation in the
**same** PR. `gap-preflight.sh` blocks other sessions on that ID until the
lease expires.
**Bootstrap only:** if you cannot run `gap-reserve.sh`, use
`CHUMP_ALLOW_UNREGISTERED_GAP=1 scripts/coord/gap-preflight.sh …` on the tiny filing PR
(INFRA-020 escape hatch). Concurrent invention caused INFRA-016/017/018.

This writes `.chump-locks/<session>.json` with `gap_id` set. Other bots running
`gap-preflight.sh` will see the claim instantly (reads local files — no network).
Claims auto-expire with the session TTL — no stale locks possible.

## Ship pipeline (always use this, not manual git push + gh pr create)

```bash
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

This rebases on main, runs fmt/clippy/tests, pushes, opens the PR, and enables auto-merge.
It also writes the gap claim at start and re-checks the gap after rebase.

**Gap status changes go through `chump gap ship --update-yaml`** (canonical
since INFRA-059). It flips `status: done` + stamps `closed_date` in
`.chump/state.db` AND regenerates `docs/gaps/<ID>.yaml` so the human-readable
diff lands in the same PR. Never hand-edit any `docs/gaps/<ID>.yaml` to add
`in_progress`, `claimed_by`, or `claimed_at` — those fields are gone. Claims
live in lease files; status lives in the SQLite store.

**`--gap` is effectively required (INFRA-237, 2026-05-02).** `bot-merge.sh`
refuses to ship without a gap ID — either passed explicitly (`--gap INFRA-NNN`),
auto-derived from a canonical branch name (`chump/infra-NNN-...`,
`claude/research-NNN-...`, `chore/file-infra-NNN`), or explicitly suppressed
with `--gap none` for genuine non-gap PRs (dependabot bumps, doc-only sweeps).
Without one of these, the script exits 2 with a banner naming all three
remediation paths. This closes the path that left `status:open` ghosts after
their implementing PR landed (INFRA-241 backfill class) by guaranteeing the
INFRA-154 auto-close step always has a gap ID to flip. Tests:
`scripts/ci/test-bot-merge-gap-auto-derive.sh` (auto-derive happy paths) and
`scripts/ci/test-bot-merge-requires-gap.sh` (the contract: missing-gap exits
non-zero with an actionable error).

**Auto-close on ship (INFRA-154, 2026-04-28).** `bot-merge.sh` now runs
`chump gap ship <ID> --closed-pr <PR#> --update-yaml` between `gh pr create`
and arming auto-merge, then commits + pushes the resulting
`docs/gaps/<ID>.yaml` + `.chump/state.sql` diff onto the same branch. The merge queue squashes the
close commit together with the implementation commit, so origin/main sees
**one atomic closure** with `status=done` + `closed_pr=<this-PR>` — no more
"flip status to done after PR #N landed" follow-up commits (5+ such
bot-effort PRs the week of 2026-04-22..28). Disable with
`CHUMP_AUTO_CLOSE_GAP=0` for partial-progress / split PRs that should not
fully close their gap. Skipped automatically when the gap is already done,
when no `--gap` was given, or when the chump binary doesn't support
`--closed-pr` (pre-INFRA-156 binaries).

## Hard rules

- **Default to haiku for routine project work (INFRA-369, 2026-05-03).** `.claude/settings.json` pins `"model": "claude-haiku-4-5"` + `"effortLevel": "medium"` for this repo. Rationale: opus-4-7 high is ~50× haiku per token; one fleet session burned $92 of workspace credit + maxed the $20/mo subscription cap. For routine ship-a-gap work haiku is plenty. Override per-session via `/model` in the Claude Code app for genuinely hard tasks. Per-fleet override: `FLEET_MODEL=sonnet scripts/dispatch/run-fleet.sh` (INFRA-364).
- **Never push directly to `main`.** Branch + worktree naming follow [AGENTS.md → Naming conventions](./AGENTS.md#naming-conventions-infra-186-2026-05-01) (canonical: `chump/<codename>` branch, `.chump/worktrees/<name>` worktree). Existing `claude/*` branches and `.claude/worktrees/` paths are accepted by tooling for backward compat — new work uses the `chump/` prefix so the project owns the namespace, not whichever tool is running this session.
- **Always work in a linked worktree, never in the main repo root.** `chump claim` refuses to run from the main repo root — use a linked worktree under `.chump/worktrees/<name>/` (canonical) or `.claude/worktrees/<name>/` (legacy, accepted). Override with `CHUMP_ALLOW_MAIN_WORKTREE=1` only for bootstrapping.
- **Never start work on a gap without running `chump gap preflight <GAP-ID>` first.** It takes 3 seconds and prevents hours of wasted work.
- **Never leave a lease file behind.** Delete `.chump-locks/<session_id>.json` or call `chump --release` when done.
- **Commit often.** Uncommitted edits are at risk of being overwritten by `git pull`. Stage-commit every 30 minutes of work.
- **Commit explicitly, never implicitly.** Use `scripts/coord/chump-commit.sh <file1> [file2 ...] -m "msg"` instead of `git add && git commit`. The wrapper resets any unrelated staged files from OTHER agents before committing so their in-flight WIP doesn't leak into your commit (observed twice on 2026-04-17 — memory_db.rs stomp in cf79287, DOGFOOD_RELIABILITY_GAPS.md stomp in a5b5053).
- **Never hand-edit `docs/gaps/<ID>.yaml`.** Per-file gap YAMLs are *derived artifacts* of `.chump/state.db` (canonical post-INFRA-188). Mutate gaps ONLY through `chump gap` subcommands (`reserve`, `claim`, `set`, `ship`); each writes a freshness marker (`.chump/.last-yaml-op`) the pre-commit raw-YAML-edit guard checks. The guard is **blocking** since INFRA-200 — if it fires, switch to the CLI rather than bypass with `CHUMP_RAW_YAML_EDIT=1`. Hand-editing primary state caused the INFRA-049/052/055/057/064 + INFRA-208 corruption class. The legacy `docs/gaps.yaml` is now gitignored (it was deleted in INFRA-188 but stale chump binaries kept re-creating it as a side-effect — observed 5+ times in the 2026-05-02 cleanup pass).
- **If your branch is more than 15 commits behind main, rebase before continuing.**
- **Long COG-\* branches forbidden (INFRA-062 / M4, 2026-04-25).** Cognitive-architecture experiments must land behind a `runtime_flags` flag and ship in days, not weeks. Workflow: (1) new COG-\* gap lands a `cog_NNN` flag default-off, (2) bench harness compares flag-off baseline vs flag-on candidate (reflection rows tag `notes=flags=cog_NNN`), (3) cycle review flips default by removing the `if runtime_flags::is_enabled("cog_NNN")` gate, (4) cleanup PR removes the dead flag entry. Branches that sit > 5 days mid-experiment are evidence the flag pattern was skipped — split into trunk-friendly increments. See `src/runtime_flags.rs` for the API; `CHUMP_FLAGS=cog_040,cog_041` enables at runtime.
- **`CHUMP_GAP_CHECK=0 git push`** — bypass the pre-push gap-preflight hook. Use when gap IDs in commit bodies cause false positives (e.g. a cleanup commit that mentions a gap ID it doesn't implement).
- **Auto-merge IS the default** (since INFRA-MERGE-QUEUE, 2026-04-19; **strict mode disabled INFRA-201, 2026-05-01**). `bot-merge.sh --auto-merge` arms `gh pr merge --auto --squash` at PR creation — **BUT ONLY if all required CI checks are passing** (see **CI pre-flight gate** below). **There is no real GitHub merge queue on this repo** — the feature is org Team/Enterprise only and the `merge_queue` rule type returns 422 on a personal-account repo (see `docs/process/MERGE_QUEUE_SETUP.md` for the failed API attempts). INFRA-201 disabled the `strict` (require-up-to-date-branches) flag on the legacy branch protection: PRs land as soon as their **own** required checks (`test`, `audit`, `ACP smoke test`) are green, regardless of whether `main` has moved underneath them. This eliminates the BEHIND-cascade traffic jam that happens when N PRs auto-merge in parallel (observed 2026-05-01: 10 PRs blocked → 4 → 2 within seconds when strict was flipped off). The squash-loss footgun PR #52 originally taught us about is still mitigated by **atomic PR discipline** (don't push after arming auto-merge) plus the `pr-<N>-checkpoint` tag `bot-merge.sh` writes; treat the absence of a real queue as the reason that discipline is non-negotiable.
- **CI pre-flight gate (INFRA-CHOKE prevention, 2026-04-24).** `bot-merge.sh` now checks `gh pr checks <N>` before arming auto-merge. If Release job, Crate Publish dry-run, or any other required check is failing, auto-merge is NOT armed and a diagnostic comment is posted to the PR. This prevents PR #470-style situations where a PR is queued waiting for broken shared infrastructure. If your PR fails this check: (1) check the failing job logs, (2) fix the underlying issue (often in `.github/workflows/release.yml` or infrastructure), (3) re-run `scripts/coord/bot-merge.sh --gap <ID> --auto-merge` when checks pass. Disable with `CHUMP_SKIP_CI_GATE=1` only for genuine edge cases (legacy infra jobs, known flakes you've already triaged).
- **Atomic PR discipline.** Once `bot-merge.sh` runs, treat the PR as frozen — **do not push more commits to it**. If you need to add work, open a *new* PR from a fresh worktree (cheap with the musher dispatcher) and let the queue land them in order. Pushing-after-arm reintroduces the squash-loss footgun the queue exists to prevent.[^pr52]
- **Branch-protection / workflow-job alignment (CREDIBLE-058, 2026-05-14).** Branch protection requires three check contexts: `test`, `audit`, `ACP protocol smoke test (Zed / JetBrains compatible)`. If you rename any of these workflow jobs in `.github/workflows/`, branch protection still expects the OLD name and every PR will stall with "required check missing." The pre-commit hook now catches this: any staged change to `.github/workflows/*.yml` triggers `scripts/ci/audit-branch-protection.sh --baseline --check-staged`, which verifies every required context matches a job name in the staged YAML. If you intentionally rename a job and update branch protection, run `scripts/ci/audit-branch-protection.sh --update-baseline` to commit the new baseline. Bypass: `CHUMP_BRANCH_PROTECTION_AUDIT=0 git commit ...`. Drift is also signalled via `kind=branch_protection_drift` in ambient.jsonl.
- **Workflow-only / gap-only PR path-filter trap (INFRA-272, 2026-05-02).** Required CI checks (`test`, `audit`, `ACP smoke test`) are gated by `dorny/paths-filter` inside `.github/workflows/ci.yml`'s `changes` job, which uses an **allowlist** in the `code:` filter. If a PR's diff matches NONE of the allowlist patterns, the gated jobs mark "skipped" and branch protection treats that as missing-not-passing — auto-merge can never satisfy it (killed PR #803 entirely, almost killed PR #874 on 2026-05-02). **Decision: option (a) — extend the allowlist.** `.github/workflows/**` and `docs/gaps/**` are now in `code:`, so workflow-only and gap-filing PRs trigger all required checks. If you add a new top-level path that PRs may exclusively touch (e.g. a new config dir), add it to the `code:` filter or your PR will get stuck. PR #874 is the regression fixture: gap+workflow+script diff, all three required checks fired green. Bypass for genuine docs-only sweeps: keep diffs in `docs/` (excluding `docs/gaps/`) and accept the skip — branch protection lets the rollup pass when shards skip uniformly.
- **bot-merge.sh recovery — manual ship path (INFRA-028).** If `scripts/coord/bot-merge.sh` hangs, times out, or is broken while you still have a clean branch in a linked worktree, ship by hand the same way that unblocked RESEARCH-027 cycle 5: `git push -u origin <branch> --force-with-lease` (or without `-u` if upstream exists), then `gh pr create --base main --title "…" --body "…"`, then `gh pr merge <N> --auto --squash` when you want the merge queue. Re-run `chump gap preflight <GAP-ID>` first if you are gap-scoped. After a manual ship, run `chump gap ship <GAP-ID> --update-yaml` to flip status in `.chump/state.db` and regenerate `docs/gaps/<GAP-ID>.yaml` on the same branch, and release any `.chump-locks/<session>.json` lease for that gap so the ledger matches reality.
- **`bot_merge_hung` — webhook-cache MERGED wait (INFRA-2119, 2026-05-29).** The `bot_merge_hung` ALERT (33 events / 14d as of 2026-05-29) historically fired when bot-merge.sh's overall budget watchdog (CHUMP_BOT_MERGE_BUDGET_SECS, default 600s) tripped while waiting for a downstream step that never returned. Two same-day wedges (INFRA-2122, INFRA-2128) forced manual `git push --no-verify + gh pr create` rescues. The fix: bot-merge.sh now exposes an opt-in webhook-cache MERGED wait — set `CHUMP_BOT_MERGE_WAIT_MERGED=1` to make bot-merge block until `cache_lookup_pr` (the webhook-populated `.chump/github_cache.db` reader from INFRA-1081) reports `merged_at` non-null. Tunables: `CHUMP_BOT_MERGE_WAIT_TIMEOUT_S` (default 900s = 15 min hard cap), `CHUMP_BOT_MERGE_WAIT_POLL_INTERVAL_S` (default 5s), `CHUMP_BOT_MERGE_WAIT_WEBHOOK_GRACE_S` (default 60s, fed to the cache TTL). On MERGED → emits `kind=bot_merge_webhook_hit` (consumers can compute webhook-hit vs poll-fallback ratio). On timeout → emits `kind=bot_merge_timeout` and exits **4** so the bash caller (typically a sub-agent dispatch wrapper per SUBAGENT_DISPATCH.md) knows to switch to the INFRA-028 manual recovery path above. Default OFF preserves backward compat — `queue-driver.sh`, `ghost-gap-reaper.sh`, and other arm-and-exit callers see no behavior change.
- **If auto-merge is stuck.** (Pre-INFRA-201 framing was "queue stuck"; in practice the symptoms and recovery are identical because there is no queue — see auto-merge note above.) Symptoms: `gh pr view <n> --json autoMergeRequest` shows auto-merge armed but PR state is still `OPEN` long after CI finished. Recovery (in order — try least-destructive first):
  0. **Confirm it's actually stuck (INFRA-306).** `gh pr view <n> --json state -q .state` first. If `MERGED`, abandon recovery — the PR landed and your "stuck" view was 30s stale. `bot-merge.sh` and `pr-watch.sh` both run this check before any force-push since INFRA-306; manual recovery should too.
  1. **Diagnose.** `gh pr checks <n>` + open `https://github.com/repairman29/chump/queue/main` — identify the blocking PR. Common causes: CI failure on the queue's temp merge branch, required-check timeout, a rebase conflict the queue couldn't resolve, or auto-merge silently disarmed by a force-push / branch-protection change.
  2. **Re-run CI if flaky.** `gh run rerun <run-id> --failed` on the queue's temp branch run. Do NOT rerun on the PR branch itself — the queue grades its own temp branch, not yours.
  3. **Dequeue the blocker.** `gh pr merge <blocker-pr> --disable-auto`. This removes it from the queue without closing it; the PRs behind it start progressing. The blocker then either (a) gets a fix in a *new* PR (atomic discipline still applies — don't push to the blocker) or (b) is closed if superseded.
  4. **Recover lost commits via checkpoint tag.** `bot-merge.sh` pushes a `pr-<N>-checkpoint` tag at arm time. If a PR's branch got clobbered (force-push, squash-loss race), run `git fetch origin --tags && git checkout pr-<N>-checkpoint` in a fresh worktree — every commit that was on the branch at arm time is recoverable from that tag. See PR #52 / PR #65 history for the original incident.
  5. **Nuclear option — drain the queue.** If multiple PRs are tangled and (1–4) won't untangle them, disable auto-merge on *all* queued PRs (`for n in $(gh pr list --search 'is:open' --json number -q '.[].number'); do gh pr merge $n --disable-auto 2>/dev/null; done`), let main settle, then re-arm the PRs one at a time with `gh pr merge <n> --auto --squash` in priority order. Announce in ambient.jsonl before doing this — siblings will see their PRs dequeue and may otherwise assume a failure.
  6. **When in doubt, ask the human.** The queue has admin-only failure modes (branch-protection rule changes, required-check renames, queue disabled in settings) that agents can't fix. If steps 1–5 don't move the queue, flag the state in ambient.jsonl with `ALERT kind=queue_stuck` and stop — don't start churning new PRs against a broken queue.
- **Keep PRs intent-atomic (not file-count-bounded).** A PR is one logical change — a feature, a bug fix, a codemod, a config update. Mechanical multi-file refactors (renames, dead-code removal, dep swaps) ship as a *single* PR no matter the file count, because (a) atomic = no broken intermediate `main` state, (b) CI verifies the whole change end-to-end, and (c) one revert beats coordinating three. Stack only when the changes are *logically* distinct (e.g. "land the new API, then migrate callers, then delete the old API"). Old "≤ 5 files" guidance was for human reviewers; with merge-queue + required-CI, codemod-style PRs are the world-class default. If a human review is genuinely needed, label the PR `human-review-wanted` and split for them.
- **Stacked-PR rebase footgun (INFRA-239, 2026-05-02).** When you ship a stack — lower PR (`chump/foo-phase1` → `main`) plus upper PR (`chump/foo-phase2` → `chump/foo-phase1`, opened via `bot-merge.sh --stack-on PREV-GAP`) — and the **upper PR lands first** (squash-merges into the lower branch), the lower branch ends up with `[Phase 1 commits…] + [Phase 2 squash-merge on top]`. If `main` then moves and the lower PR goes DIRTY, a plain `git rebase origin/main` **silently drops the upper squash-merge** — it replays only the original Phase 1 commits onto current `main`. `pr-watch.sh`'s auto-rebase has the same blind spot. Recovery: after the rebase completes, run `git fetch origin --tags && git cherry-pick <upper-PR-merge-sha>` (find the sha via `gh pr view <upper-PR> --json mergeCommit -q .mergeCommit.oid`). **Verify the upper PR's content is present** (`grep` for a symbol it adds) before `git push --force-with-lease`. Caught on PR #783/#798. If you see "Phase N+1 not implemented" after a stacked rebase, this is why.
- **GitHub Actions multi-line strings — always heredoc, never inline (INFRA-157, 2026-04-28).** A `gh pr create --body "Verdict:..."` with column-1 lines inside a `run: |` block silently terminates YAML's pipe scalar. The workflow is rejected at parse time before any step runs — and the failure mode is invisible from `gh run list` (looks like "the run failed" not "the file is malformed"). When you need a multi-line PR/issue body, build it in a bash heredoc (`BODY=$(cat <<EOF ... EOF)`) so YAML never sees the embedded newlines:

  ```yaml
  - run: |
      BODY=$(cat <<EOF
      First line.

      Second line after blank.
      EOF
      )
      gh pr create --body "${BODY}"
  ```

  The same pattern was load-bearing for `ftue-clean-machine.yml` — every clean-machine FTUE run failed at parse time for ~30 attempts before this fix. Treat any column-1 token inside `run: |` as a parse-time risk and rebuild it via heredoc.
- **GitHub Actions cannot create PRs in this repo (INFRA-162, 2026-04-28).** `gh pr create` from a workflow returns `GraphQL: GitHub Actions is not permitted to create or approve pull requests`. Enabling it requires Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests" — a repo-admin action. Until that flips, workflows that need to deliver an artifact to main should `git push origin HEAD:main` directly (with `chump-ftue-bot` or similar bot identity); the artifact is doc-only and bot-authored, so direct push is appropriate. Branch protection allows GITHUB_TOKEN pushes for these bot identities.
- **Homebrew formulae must live in a tap (INFRA-161, 2026-04-28).** `brew install --build-from-source ./Formula/foo.rb` fails on modern Homebrew with `Homebrew requires formulae to be in a tap`. The CI workaround is `brew tap-new <name>/local --no-git --quiet && cp Formula/foo.rb $(brew --repo <name>/local)/Formula/ && brew install --build-from-source <name>/local/foo`. This also makes the verification reflect the real user install path (the documented one is `brew tap repairman29/chump && brew install chump`) instead of a workflow-only shortcut.

[^pr52]: Historical context — PR #52 (2026-04-18) lost 11 commits when an agent kept pushing after auto-merge was armed; GitHub captured the branch at first-CI-green and dropped everything pushed after. Recovery PR #65 was hand-cherry-picked. The merge queue (INFRA-MERGE-QUEUE) closes the race only if you stop pushing once the PR is in the queue.

## Agent UI verification (PRODUCT-037, 2026-05-08)

When a gap touches `web/` (PWA, static assets, `app.js`, `index.html`, etc.), the agent **must** verify the served UI before shipping — not just that the files exist, but that the server actually serves them correctly. Use `scripts/dev/dev-server.sh` (not `restart-chump-web.sh` or `run-web.sh`, which are operator tools with git-pull + full rebuild logic that are wrong for in-worktree verification).

```bash
# 1. Start a lightweight dev server on a dedicated port (won't collide with the
#    operator's live server on 3000, and won't do a git pull / release build).
scripts/dev/dev-server.sh start --port 3737

# 2. Verify key paths respond 200.  Default paths: /api/health and /v2/
scripts/dev/dev-server.sh verify --port 3737

# 3. Verify additional app-specific paths your gap touches.
scripts/dev/dev-server.sh verify --port 3737 /v2/ /api/dashboard /api/jobs

# 4. Check health manually if you want the JSON body.
curl -s http://127.0.0.1:3737/api/health | python3 -m json.tool

# 5. Stop when done (good hygiene — don't leave stray processes).
scripts/dev/dev-server.sh stop --port 3737
```

**Port 3737 is the agent verification default.** It is reserved for in-worktree agent checks; port 3000 is the operator's live server. This prevents agents from stomping the running PWA.

**Build flag.** By default `dev-server.sh start` uses the nearest pre-built binary (`target/debug/chump` preferred over `target/release/chump`). Pass `--build` to rebuild first:

```bash
scripts/dev/dev-server.sh start --port 3737 --build   # rebuild debug binary, then start
```

**`cargo run` fallback.** If no binary exists at all (fresh clone), `dev-server.sh start` automatically builds a debug binary before starting.

**Status + restart helpers:**

```bash
scripts/dev/dev-server.sh status   # exit 0 if running, exit 1 if stopped
scripts/dev/dev-server.sh restart  # stop + start in one shot
```

**Gotcha — worktree `target/` may be empty (PRODUCT-037).** Linked worktrees share `CARGO_TARGET_DIR` only if the env is explicitly set; by default each worktree has its own `target/`. If `start` reports "no pre-built binary found", pass `--build` or point `CARGO_TARGET_DIR` at the main repo's target:

```bash
CARGO_TARGET_DIR="$(git rev-parse --show-toplevel)/target" \
  scripts/dev/dev-server.sh start --port 3737
```

**Must-do for PWA gap acceptance.** Any gap whose `acceptance_criteria` mentions the UI or PWA must include at least one `verify` pass in its acceptance evidence. Document the passing output in your PR body:

```
## UI verification
$ scripts/dev/dev-server.sh verify --port 3737 /api/health /v2/
[dev-server] PASS  200  /api/health
[dev-server] PASS  200  /v2/
[dev-server] all paths OK
```

## Speculative execution (INFRA-193, opt-in)

Default coordination is **exclusive lease** — one agent per gap. That serializes work and adds coordination latency. For latency-critical or high-diversity gaps you can opt two (or more) agents into a deliberate race:

```bash
# Both agents add --speculative when claiming the same gap:
scripts/coord/gap-claim.sh INFRA-NNN --speculative              # agent A
CHUMP_SPECULATIVE=1 scripts/coord/gap-preflight.sh INFRA-NNN    # agent B preflight
scripts/coord/gap-claim.sh INFRA-NNN --speculative              # agent B claim

# Or via bot-merge.sh end-to-end (propagates to gap-claim.sh + post-arm sweep):
scripts/coord/bot-merge.sh --gap INFRA-NNN --auto-merge --speculative
```

**Semantics:**
- `gap-claim.sh --speculative` writes `"speculative": true` into the lease.
- `gap-preflight.sh` allows concurrent claims **only when both sides are speculative**. A non-speculative claimer is still blocked by any existing claim (and a speculative claimer is still blocked by an existing non-speculative claim — opting out of the race forfeits the right to race).
- `bot-merge.sh --speculative` propagates the flag to gap-claim.sh AND, after auto-merge is armed, runs a **loser sweep**: scans open PRs that cite the same gap ID and closes them with `Auto-closing as superseded by #N`. The losers' branches stay intact (no force-push, no commit loss) — re-open or cherry-pick if the winner is later reverted.

**When it makes sense:** latency-critical gaps; gaps where two agents have very different strengths (e.g. one Claude, one Gemini); research/eval gaps where the diversity is itself the signal. Cost: 2x compute. Benefit: 0x coordination latency + diversity bonus.

**Bypass envs:** `CHUMP_SPECULATIVE_SWEEP=0` skips the loser-PR closure step; `CHUMP_SPECULATIVE=1` enables the mode without `--speculative`.

**Tests:** `scripts/ci/test-speculative-execution.sh` covers the four-quadrant claim matrix (spec×spec allow, spec×excl block, excl×spec block, lease writes `speculative=true`).

## Worktree disk hygiene

Linked worktrees under `.claude/worktrees/` are the main **disk** risk on agent-heavy machines: each keeps its own `target/` (often multi‑GB after `cargo clippy` / `cargo test`). After a successful ship, `bot-merge.sh` **purges `./target`** in that worktree when it writes `.bot-merge-shipped` (skip with **`CHUMP_KEEP_TARGET=1`** if you still need the cache there).

**Stale trees (merged PR or deleted remote branch):** prefer automation over hand-tuning `git worktree list`.

1. **`scripts/ops/stale-worktree-reaper.sh`** — default is **dry-run** (safe to run anytime). With **`--execute`**, it archives selected eval logs then `git worktree remove --force` under `.claude/worktrees/` only when the script’s guards pass (cooldown, no conflicting lease, process / log freshness — see the script header).
2. **`scripts/coord/worktree-prune.sh`** (INFRA-1347, 2026-05-15) — the multi-PR batch reaper for post-sprint cleanup. Uses `gh pr list` to look up each worktree’s PR state. **Safety guards (each independently sufficient to SKIP delete):** (a) active lease (`wt_has_active_lease` 900s), (b) `.git/index` modified within 30 min (was 5 min before INFRA-1347 — bumped because cargo builds take 10+ min between edits), (c) unpushed commits (`git rev-list --count origin/<branch>..HEAD > 0`), (d) untracked non-gitignored files (agent wrote a test/doc/fixture but hadn’t run `git add` yet). Any guard triggers a `kind=worktree_reaper_skipped_active` event in `ambient.jsonl` with the specific reason. CI test: `scripts/ci/test-worktree-prune-protects-live-edits.sh`.
3. **macOS — expected setup for dogfooding:** run **`scripts/setup/install-stale-worktree-reaper-launchd.sh`** once per machine so the reaper runs **hourly**. **Verify:** `launchctl list | grep dev.chump.stale-worktree-reaper`. **Logs:** `/tmp/chump-stale-worktree-reaper.out.log` and `/tmp/chump-stale-worktree-reaper.err.log`. **Disable:** `launchctl unload ~/Library/LaunchAgents/dev.chump.stale-worktree-reaper.plist`.
4. **Opt out** for one worktree the reaper should never remove: **`touch <worktree-path>/.chump-no-reap`**.

Manual escape hatch from the **main** checkout: `git worktree remove .claude/worktrees/<name>` when you are sure nothing has that directory as its cwd.

**`.chump-no-reap` is the standard escape hatch (RESILIENT-107 precedent, hardened RESILIENT-116).** Any script that provisions a worktree and then runs a long build should `touch <worktree>/.chump-no-reap` immediately after `git worktree add`, before the build starts — `scripts/setup/refresh-runner-binary.sh` did exactly this (RESILIENT-107, commit `63a4e768`) after a 10-12 min release build in `/tmp/chump-binary-refresh-<PID>/` got its `target/release/deps/` deleted mid-compile by a reaper race. All three worktree/target reapers — `active-target-reaper.sh`, `stale-worktree-reaper.sh`, and `cargo-target-reaper.sh` (the latter hardened in RESILIENT-116; it previously had no sentinel check on its `/tmp/chump-*` orphan-scan or lease+auto-merge classes) — honor the marker. A `trap ... EXIT` that tears down the worktree removes the sentinel along with it, so there's no cleanup step to remember.

**Audit-emit invariant (RESILIENT-116):** every time a reaper bypasses a delete because of the sentinel or a detected in-flight build (open file handle, `.cargo-lock` present, or fresh `target/` mtime), it must emit `kind=target_reap_skipped` to `ambient.jsonl` with a `reason` field of `no_reap_marker` or `active_build`. This makes the "reaper raced a fresh worktree build" failure class observable instead of silently avoided-or-not. See `docs/observability/EVENT_REGISTRY.yaml` for the full contract and `scripts/ci/test-target-reaper-cold-build-safety.sh` for the regression fixture.

**Cold-build cost (INFRA-202, 2026-05-02).** Disk reclaim doesn't help the *time* tax: every fresh worktree pays a 5–15 min cold `cargo check` / `clippy` because each `target/` starts empty. Observed 2026-05-01: `bot-merge.sh` hit a 900s clippy timeout on a freshly-created worktree. Fix is **sccache as a rustc wrapper** — install once per machine with `scripts/setup/install-sccache.sh` (idempotent: `brew install sccache` + writes `.cargo/config.toml` with `rustc-wrapper = "sccache"` and a 10G cache). The first worktree to build a given crate version populates the cache; every subsequent worktree gets it in <60s. `.cargo/config.toml` is `.gitignore`d so each machine controls its own cache config (CI runners without sccache won't break). Opt out with `rm .cargo/config.toml`.

**Shared CARGO_TARGET_DIR phantom fingerprint error (INFRA-1138, 2026-05-14).** `install-sccache.sh` (INFRA-481) sets `target-dir = "/Users/.../Chump/target"` in `.cargo/config.toml` so all linked worktrees share a single target directory (saving disk). Side-effect: cargo's fingerprint cache is also shared. If worktree A compiled `tests/cli_fleet_coord.rs` and stored the fingerprint in the shared target, worktree B (which may not have that test file on its branch) reads the cached fingerprint and tries to verify the file — failing with `couldn't read tests/cli_fleet_coord.rs: No such file or directory`. **Fix (INFRA-1138):** the pre-push test gate sets `CARGO_TARGET_DIR="$REPO_ROOT_T/.cargo-test-target"` (per-worktree) for the `cargo test` invocation. sccache (configured via `rustc-wrapper` in `.cargo/config.toml`) still provides cross-worktree object-code caching — only the fingerprint/incremental data is isolated. The `.cargo-test-target` directory lives inside each linked worktree and is cleaned up when the worktree is deleted. **Symptom:** `Test-Gate-Bypass: phantom fingerprint from sibling worktree` trailers on commits from before INFRA-1138.

**Per-N-worker CARGO_TARGET_DIR closes the fleet-loop half of the gap (INFRA-3662, 2026-08-22).** INFRA-1138 above only fixed the pre-push *test gate*'s `cargo test` invocation — the persistent fleet worker loop (`worker.sh`'s `cargo check`/`clippy` calls, driven by `run-fleet.sh`) still exported one `CARGO_TARGET_DIR` to every pane, so the same sibling-worktree fingerprint clobbering could still hit fleet workers outside the test gate. Fix: `run-fleet.sh` now splits workers into groups of `CHUMP_CARGO_TARGET_GROUP_SIZE` (default 2) and gives each group its own `CARGO_TARGET_DIR` under `CHUMP_CARGO_TARGET_ROOT` (autodetects a mounted USB/`cjdata*` data disk the same way `install-sccache.sh` does, INFRA-3660) — bounded to `FLEET_SIZE/N` distinct dirs rather than one-per-worker, keeping disk footprint close to the old single-dir baseline. sccache (`rustc-wrapper` in `.cargo/config.toml`) still shares compiled object code across every group, so cache hit-rate is unaffected — only fingerprint/incremental state is now group-local instead of fleet-global. Override the group root with `CHUMP_CARGO_TARGET_ROOT`; override group size with `CHUMP_CARGO_TARGET_GROUP_SIZE`.

**Reaper visibility — heartbeat + ambient events (INFRA-120, 2026-05-01).** All three reapers (`stale-pr-reaper.sh`, `stale-worktree-reaper.sh`, `stale-branch-reaper.sh`) emit a `kind=reaper_run` event into `.chump-locks/ambient.jsonl` on every run with `status=ok|fail` and per-reaper counts. They also stamp `/tmp/chump-reaper-<name>.heartbeat` (`pr` / `worktree` / `branch`). Each reaper rotates its own `/tmp/chump-stale-*-reaper.{out,err}.log` to a single `.1` archive at 5MB so logs never grow unbounded.

A separate watchdog grades the heartbeats and ALERTs the fleet when a reaper goes silent:
- **Watchdog:** `scripts/ops/reaper-heartbeat-watchdog.sh` — emits `ALERT kind=reaper_silent` into `ambient.jsonl` when a reaper hasn't heartbeated in 2h (pr), 4h (worktree), or 48h (branch) — i.e. ~2-4× the launchd cadence per the gap acceptance criteria. Visible in the standard pre-flight `tail -30 .chump-locks/ambient.jsonl`.
- **macOS install (do this once per dogfood machine):** `scripts/setup/install-reaper-watchdog-launchd.sh` — runs every 30 min. **Verify:** `launchctl list | grep dev.chump.reaper-watchdog`. **Disable:** `launchctl unload ~/Library/LaunchAgents/dev.chump.reaper-watchdog.plist`.
- **Manual check:** `scripts/ops/reaper-heartbeat-watchdog.sh` (no flags) prints per-reaper status and exits 0 even with ALERTs (so launchd doesn't loop on it).
- **Quickly grep the stream:** `tail -200 .chump-locks/ambient.jsonl | grep -E '"kind":"reaper_(run|silent)"'`.

**macOS APFS volume-vs-container trap — reading a `disk_critical` (RESILIENT-096, 2026-06-05).** When `reaper_check_disk_headroom` (in `scripts/lib/reaper-instrumentation.sh`) fires `kind=disk_critical`, **don't refute it with `df /`**. On APFS the read-only system volume `/` (e.g. `/dev/disk3s1s1`) shows only its own tiny footprint (e.g. `11Gi used, 27%`) while the real Data volume `/System/Volumes/Data` (`/dev/disk3s5`) holds everything and can be at `99%`. They **share one container free-pool** — the `Avail` column is identical for both (e.g. `31Gi`), and *that* is the true free space, not the per-volume `Used`. `/tmp` and the repo both live on the Data volume, so a `disk_critical` probing them is reporting the container, not a small temp partition. The event now carries `fs`, `mount`, and a human `note` (e.g. `filesystem /dev/disk3s5 at /System/Volumes/Data is 2% free`) plus the raw `df` line — read those, not `df /`. The event is also **deduped per filesystem** (one alert per backing device per reaper run), so a single low-disk moment no longer emits a `/tmp` + `.chump-locks` pair. Precedent: the 2026-06-05 events at `.chump-locks/ambient.jsonl.1` that read as false-positives but were true-positive container pressure.

## ambient.jsonl rotation (INFRA-122, 2026-05-02)

`.chump-locks/ambient.jsonl` is the file-side of the peripheral-vision stream and is appended-to by every agent on every event. Without rotation it grows ~4MB/day under fleet load and reaches multi-GB over a few weeks.

- **Rotation script:** `scripts/dev/ambient-rotate.sh` — keeps `AMBIENT_RETAIN_DAYS` (default 7) of events in-place, archives older events to `.chump-locks/ambient.jsonl.YYYY-MM-DD.gz`, and writes a `{"event":"rotated",...}` summary line.
- **macOS install (do this once per dogfood machine):** `scripts/setup/install-ambient-rotate-launchd.sh` — runs the rotate script daily at 03:00 local. **Verify:** `launchctl list | grep dev.chump.ambient-rotate`. **Logs:** `/tmp/chump-ambient-rotate.{out,err}.log`. **Disable:** `launchctl unload ~/Library/LaunchAgents/dev.chump.ambient-rotate.plist`.
- **Self-monitoring:** if `ambient.jsonl` exceeds `AMBIENT_SIZE_ALERT_MB` (default 50MB), the rotate script emits an `ALERT kind=ambient_oversize` event into the stream itself — visible during the standard pre-flight `tail -30 .chump-locks/ambient.jsonl`. Catches the case where rotation isn't installed or the schedule broke.
- **Querying historical data:** `scripts/dev/ambient-query.sh` transparently reads from the live log + all rotated `.gz` archives in chronological order. Use `--since 24h` to bound the search.

## Overnight research scheduler (INFRA-114, 2026-04-26)

Research churn (eval sweeps, A/B studies, ablations) runs overnight, not during the workday. Daytime is for the dispatcher and agent work.

- **Drop-in directory:** `scripts/overnight/` — every executable `*.sh` runs in lex order. Rename to `*.disabled` to skip.
- **Wrapper:** `scripts/eval/run-overnight-research.sh` — 1h per-job timeout, lockfile guard, per-run logs in `.chump/overnight/<run-id>.log`, emits `overnight_start` / `overnight_done` / `overnight_job_fail` to `ambient.jsonl`.
- **macOS install:** `scripts/setup/install-overnight-research-launchd.sh` (default 02:00 daily; override with `CHUMP_OVERNIGHT_HOUR`/`CHUMP_OVERNIGHT_MINUTE`).
- **On-demand smoke test:** `launchctl start dev.chump.overnight-research` after install, then `tail /tmp/chump-overnight-research.out.log`.
- **Conventions:** see `scripts/overnight/README.md`.

When you migrate an existing eval/A/B sweep, drop it as `scripts/overnight/<NN>-<short>.sh`, smoke-test it directly, and verify the next run picks it up.

## Session ID resolution (how leases are scoped)

`gap-claim.sh` picks a session ID in this priority order — first non-empty wins:

1. `$CHUMP_SESSION_ID` — explicit override (set by `bot-merge.sh` or manually)
2. `$CLAUDE_SESSION_ID` — injected by Claude Code SDK; unique per agent session (**best**)
3. `.chump-locks/.wt-session-id` — worktree-scoped ID generated once per linked worktree (stable across re-runs within the same worktree session)
4. `$HOME/.chump/session_id` — machine-scoped legacy fallback (shared across all sessions — avoid)

The worktree-scoped ID (3) is automatically generated and cached the first time `gap-claim.sh` runs in a new worktree. It is scoped to `.claude/worktrees/<name>/` so concurrent sessions in different worktrees never collide.

## Commit-time guards (coordination audit, 2026-04-17; expanded since)

Every commit runs the checks below. Most are silent no-ops; each one fails loud with a bypass hint. Most live in `scripts/git-hooks/pre-commit` (installed via `./scripts/setup/install-hooks.sh`); the **wrong-worktree** check lives in the `scripts/coord/chump-commit.sh` wrapper and only runs if you commit through it. See the pre-commit hook header for the canonical list and ordering.

| Check | Where | What it blocks | Bypass env | Why |
|---|---|---|---|---|
| lease-collision | pre-commit | file claimed by a different live session | `CHUMP_LEASE_CHECK=0` | silent stomps |
| out-of-scope (INFRA-189, 2026-05-01; INFRA-337 subagent-enforce, 2026-05-02) | pre-commit | MY lease declares `paths` and I'm staging files OUTSIDE that scope | `CHUMP_SCOPE_CHECK=0` (disable) / `CHUMP_SCOPE_CHECK=warn` (force warn) / `CHUMP_SCOPE_CHECK=enforce` (force block) | wrong-worktree commits + cross-fixture leaks (INFRA-076 class). **Default depends on session origin**: subagent sessions (`session_id` prefix `chump-anon-` or `subagent-`, i.e. Agent-tool spawns) default to **enforce** — out-of-scope edits in narrowly-dispatched subagents are almost always hallucinated/scope-creep and cheap to retry (META-025 dispatch-quality finding). Operator-driven sessions default to **warn** to preserve ergonomics during the INFRA-189 false-positive observation window. Only triggers when the lease has a non-empty `paths` field — agents that don't declare scope still work as before. Test: `scripts/ci/test-scope-check-subagent-enforce.sh`. |
| stomp-warning | pre-commit | staged file mtime > 10 min (non-blocking) | `CHUMP_STOMP_WARN=0` | cross-agent staging drift |
| gaps.yaml discipline | pre-commit | adds `status: in_progress` / `claimed_by:` / `claimed_at:` to the YAML | `CHUMP_GAPS_LOCK=0` | claim fields live in `.chump-locks/`, not the ledger |
| gap-ID hijack (2026-04-18) | pre-commit | gaps.yaml diff *changes* an existing gap's `title:` or `description:` (silent ID reuse) | `CHUMP_GAPS_LOCK=0` | caught PR #60 ↔ #65 EVAL-011 collision; new work needs a new ID, not redefinition |
| duplicate-ID insert (INFRA-GAPS-DEDUP, 2026-04-19; test in INFRA-015) | pre-commit | gaps.yaml ends up with two entries sharing the same `id:` | `CHUMP_GAPS_LOCK=0` | closes the hole that let the 7 collision pairs in per Red Letter #2; test: `scripts/ci/test-duplicate-id-guard.sh` |
| recycled-ID guard (INFRA-014, 2026-04-21) | pre-commit | reopening a previously-`done` gap with new content under the same id | `CHUMP_GAPS_LOCK=0` | new work gets a new ID; closed gaps are immutable history |
| closed_pr integrity guard (INFRA-107, 2026-04-26) | pre-commit | flipping a gap to `status: done` when `closed_pr` is absent, `TBD`, or any non-numeric value | `CHUMP_GAPS_LOCK=0` | PRODUCT-009 false closure shipped with `closed_pr: TBD`; RED_LETTER #2 caught it days later; test: `scripts/ci/test-closed-pr-guard.sh` |
| preregistration required (RESEARCH-019) | pre-commit | closing an `EVAL-*` or `RESEARCH-*` gap to `status: done` without a `docs/eval/preregistered/<GAP-ID>.md` committed | `CHUMP_PREREG_CHECK=0` with justification | hypothesis must be locked before data collection — retrospective / doc-only gaps use the bypass |
| preregistration content (INFRA-113, 2026-04-28) | pre-commit | preregistration file exists but is empty / a stub / unfilled `TEMPLATE.md` — no sample size, no judge identity, no A/A baseline reference, no effect threshold, no prohibited-claims pointer | `CHUMP_PREREG_CONTENT_CHECK=0` for genuinely retrospective gaps | file existence is not enough; the methodology contract must actually be locked. Test: `scripts/ci/test-prereg-content-guard.sh` (5 cases). Stub-prereg gaps shipped before this guard motivated the gap |
| cross-judge audit (INFRA-079, 2026-04-28) | pre-commit | closing an `EVAL-*` or `RESEARCH-*` gap without `cross_judge_audit:` (≥2 judge families) OR `single_judge_waived: true` + reason OR a prereg declaring single-judge scope | `CHUMP_CROSS_JUDGE_CHECK=0` with justification | EVAL-074 cost ~$1.50 + half a day + 3 amendment PRs because a Llama-only judge labeled the result; test: `scripts/ci/test-cross-judge-guard.sh` |
| submodule sanity (INFRA-018, 2026-04-19) | pre-commit | adding a gitlink (mode 160000) without a matching `.gitmodules` entry | `CHUMP_SUBMODULE_CHECK=0` | sql-migrate gitlink broke `actions/checkout` on every PR for days |
| cargo-fmt auto-fix | pre-commit | unformatted `.rs` (auto-fixes + re-stages) | — | CI `cargo fmt --check` thrash |
| cargo-check build guard | pre-commit | staged `.rs` fails `cargo check --bin chump --tests` | `CHUMP_CHECK_BUILD=0` | broken-compile commits triggering `fix(ci):` follow-ups |
| docs-delta check (INFRA-009, 2026-04-20) | pre-commit | adds a `docs/*.md` without deleting one or adding a `Net-new-docs:` trailer | `CHUMP_DOCS_DELTA_CHECK=0` | counter-pressure on doc sprawl per Red Letter #3 (advisory until 2026-04-28, blocking after) |
| credential-pattern guard (INFRA-018, 2026-04-20) | pre-commit | staged diff matches common API-key / token shapes | `CHUMP_CREDENTIAL_CHECK=0` | secrets caught before they hit git history |
| book sync guard (INFRA-170, 2026-05-01) | pre-commit | staged `docs/process/*.md` edit drifts `book/src/` (canonical sync script produces uncommitted book/ changes) | `CHUMP_BOOK_SYNC_CHECK=0` | PR #625 silently drifted the book mirror, jamming the merge queue 12 PRs deep on 2026-04-29; runs the sync script automatically and tells you to `git add book/`; test: `scripts/ci/test-book-sync-guard.sh` |
| raw-YAML-edit guard (INFRA-094 advisory → INFRA-200 blocking, 2026-05-02) | pre-commit | commit modifies any `docs/gaps/<ID>.yaml` (post-INFRA-188; previously `docs/gaps.yaml`) without a fresh chump-gap CLI marker (`.chump/.last-yaml-op` within last 5 min) | `CHUMP_RAW_YAML_EDIT=1` env + `RAW_YAML_REASON: <text>` trailer (intentional manual edit), or `CHUMP_RAW_YAML_LOCK=0` (kill switch) | Cold Water Issue #9 measured 66% hand-edit rate (33/50 commits) under the prior advisory mode; flipped to blocking; test: `scripts/ci/test-raw-yaml-guard.sh` |
| wrong-worktree commit (2026-04-18) | `chump-commit.sh` | named files have no changes in this worktree but DO have changes in a sibling worktree | `CHUMP_WRONG_WORKTREE_CHECK=0` | catches the "edited the wrong checkout" failure mode that wasted ~30 min on 2026-04-18; only runs if you use `chump-commit.sh` |

`git commit --no-verify` bypasses ALL pre-commit guards (the chump-commit.sh wrapper has its own bypass envs). Use very sparingly — `--no-verify` is the reason task #58 (Metal crash) and half the duplicate-work incidents shipped.

### Rust-First-Bypass — machine-acknowledgment gate (INFRA-1580)

The Rust-first pre-commit gate (META-064) lets you bypass with a `Rust-First-Bypass: <reason>` trailer when adding new shell to `scripts/coord/`, `scripts/dispatch/`, or `scripts/ops/`. As of INFRA-1580 the gate runs a SECOND, stricter check on bypassed commits:

When a bypass trailer is present, the hook scores each newly-added shell file under `scripts/` against four **machine-checkable criteria**:

| Key | Fails when… |
|---|---|
| `loc` | file is > 200 LOC (`wc -l`) |
| `state` | file writes to `state.db`, `ambient.jsonl`, or `.chump-locks/*.state` (grep) |
| `hot` | file contains `while true` OR is referenced by a `~/Library/LaunchAgents/*.plist` (KeepAlive daemon) |
| `test` | no `scripts/ci/test-<basename>.sh` sibling exists |

**If 2 or more criteria fail**, narrative-only bypass is INSUFFICIENT. The committer must additionally include a `Rust-First-Bypass-Accept:` trailer naming each failing key:

```
feat(INFRA-NNNN): stage-gated migration helper

Three-stage pipeline; full Rust port tracked as INFRA-NNNN+1.

Rust-First-Bypass: stage-gated migration; full port tracked as INFRA-NNNN+1
Rust-First-Bypass-Accept: loc,state,hot,test
```

The bypass-accept CSV is **machine-verified against the actual file** — you can't pre-accept criteria the file doesn't violate (no-op), and you can't skip criteria it does (gate rejects). Valid keys: `loc`, `state`, `hot`, `test`.

Narrative `Rust-First-Bypass:` is still required — the audit trail captures *why* the tradeoffs were taken, not just *that* they were taken.

**Failure mode this fixes (2026-05-16):** `scripts/coord/chump-runner-migration-pipeline.sh` shipped with `Rust-First-Bypass: glue between gh+jq` despite being 339 LOC, mutating `ambient.jsonl`, running `while true`, and having no test sibling — four-of-four violations, narrative-only bypass passed under the old gate.

**Audit existing scripts:**

```bash
scripts/dev/rust-first-bypass-audit.sh           # text output, walks coord/+setup/
scripts/dev/rust-first-bypass-audit.sh --json    # JSON-only
```

Emits one `kind=rust_first_bypass_audit` per violating file with `{path, violations, has_bypass, has_acknowledgment, loc}`. Useful for prioritizing port-to-Rust work — files with multiple violations and no acknowledgment are the highest-value Rust ports.

Test: `scripts/ci/test-rust-first-bypass-gate.sh` covers (a) clean glue accepted, (b) narrative-only on a bad daemon rejected, (c) full-ack on the same daemon accepted, (d) partial-ack still rejected.

**MODIFIED-file audit mode (INFRA-1651, re-do of INFRA-1580):** everything above only ever looks at NEW files (`git diff --cached --diff-filter=A`). An existing, already-Rust-first-clean shell file can cross the same thresholds via a plain EDIT (grows past 200 LOC, gains a state-mutating line) and the ADD-only gate never sees it. `pre-commit-rust-first.sh` now separately scans `--diff-filter=M` files in the same hot-path dirs and emits `kind=rust_first_modified_audit` (`{files, reasons}`) when a MODIFIED file meets the criteria — **audit-only, it never blocks the commit**, mirroring the warn-only default the NEW-file gate already runs under (INFRA-2522). Use this signal to prioritize port-to-Rust candidates that drifted in after their initial commit, not as an enforcement surface. Test coverage: `scripts/ci/test-rust-first-gate.sh` tests 11-12 (threshold-crossing MODIFIED file inside a hot-path dir emits the audit event; a MODIFIED file outside hot-path dirs emits nothing).

## Dispatched-subagent backend (COG-025, 2026-04-19)

If you wake up inside a `chump-orchestrator`-dispatched worktree, you may be
running on either backend depending on what the operator set
`CHUMP_DISPATCH_BACKEND` to:

- **`claude` (default).** You are running as `claude -p <prompt> --dangerously-skip-permissions` — the original AUTO-013 baseline. Anthropic-only.
- **`chump-local`.** You are running inside Chump's own multi-turn agent loop (`chump --execute-gap <GAP-ID>`) driven by whatever provider `$OPENAI_API_BASE` + `$OPENAI_MODEL` resolve to (Together free tier, mistral.rs, Ollama, hosted OpenAI). Cost-routing path.

The contract is identical either way: read `CLAUDE.md` mandatory pre-flight,
do the gap, ship via `scripts/coord/bot-merge.sh --gap <id> --auto-merge`, reply
ONLY with the PR number. The orchestrator records which backend ran on the
reflection row (`notes` field, prefix `backend=<label>`) so PRODUCT-006 and
the COG-026 A/B aggregator can split outcomes by backend.

## Spawning subagents (META-025 / INFRA-332, 2026-05-02)

**Self-ship rate baseline: 25-33%.** Across this session and historical
`chump_improvement_targets` telemetry, subagents that produce work
self-ship the resulting PR only 25-33% of the time. Work-quality of
output (when produced) is high — the failure is at the ship-stage
hand-off, not at cognition. Most stalls are `bot-merge.sh` hanging on
the INFRA-275 syspolicyd binary wedge.

**Two disciplines fix this:**

1. **Every Agent-tool prompt MUST include the standard shipping
   epilogue.** Verbatim copy from
   [`scripts/dispatch/subagent-shipping-epilogue.md`](scripts/dispatch/subagent-shipping-epilogue.md).
   The epilogue covers: bot-merge canonical path, `chump-binary-unwedge.sh`
   heal, manual `git push + gh pr create + gh pr merge` fall-back path,
   forbidden anti-patterns (silent YAML fallback, `--no-verify`),
   and the final-report format. Full context and anti-patterns are in
   [`docs/process/SUBAGENT_DISPATCH.md`](docs/process/SUBAGENT_DISPATCH.md).
   The single subagent in this session that did self-ship was the one
   whose briefing included these explicit fall-back instructions.

2. **`Agent` vs `SendMessage` discipline.** `Agent` spawns a fresh
   subagent with no memory of prior runs — use it for new work.
   `SendMessage` resumes an existing subagent by `agentId` — use it to
   continue, ask for status, or unblock a stuck agent. **Never use
   `Agent` to check on an existing subagent** — you waste a slot and
   get a "fresh session, no context" response. (Mistake observed
   2026-05-02 in the very session that produced this rule.) See
   [`docs/gaps/DOC-015.yaml`](docs/gaps/DOC-015.yaml).

When you write a subagent prompt: think of it as briefing a smart
colleague who just walked into the room — they haven't seen the
conversation, don't know what you've tried. Self-contained briefing,
explicit file paths to read, explicit success criteria from the gap,
explicit shipping epilogue.

**INFRA-419 reaper:** flags subagents that exceed `CHUMP_SUBAGENT_BUDGET_MIN`
(default 30 tool calls) without invoking `bot-merge.sh`.

## Fleet launcher (INFRA-203, canonical entry point)

`scripts/dispatch/run-fleet.sh` is the canonical way to spawn N parallel
Claude Code agents on this repo. It opens a tmux session with one control
pane (live status) plus N worker panes; each worker loops:
pick-gap → claim → worktree → spawn `claude -p` → ship via `bot-merge.sh` →
release → loop. The `claude -p --dangerously-skip-permissions` invocation
matches `WorkBackend::Headless` from `src/dispatch.rs` (INFRA-191 Phase 2).

```bash
scripts/dispatch/run-fleet.sh                         # default FLEET_SIZE=8
FLEET_SIZE=4 scripts/dispatch/run-fleet.sh
FLEET_DOMAIN_FILTER=INFRA scripts/dispatch/run-fleet.sh   # INFRA-only fleet
FLEET_DRY_RUN=1 scripts/dispatch/run-fleet.sh             # print plan, exit
FLEET_SIZE=0 scripts/dispatch/run-fleet.sh                # tear down
tmux attach -t chump-fleet                                # watch the panes
```

Knobs (all env): `FLEET_SIZE`, `FLEET_TIMEOUT_S` (per-agent claude timeout,
default 1800s), `FLEET_PRIORITY_FILTER` (default `P0,P1`),
`FLEET_DOMAIN_FILTER` (default any; use for INFRA-206-style domain affinity),
`FLEET_EFFORT_FILTER` (default `xs,s,m`), `FLEET_SESSION` (tmux session name,
default `chump-fleet`), `FLEET_LOG_DIR` (default `/tmp/chump-fleet-<sid>`),
`CARGO_TARGET_DIR` (auto-set to a shared `target/` per INFRA-210 to avoid
per-worktree multi-GB rebuilds).

**Poll-jitter + idle-backpressure (INFRA-315, 2026-05-03).** Without
randomization, sibling workers' poll loops phase-lock and stampede the
same gap. Observed live in the 2026-05-02 cascade fleet run: 4 workers
all picked `INFRA-187` because they polled at the same instant, and 3 of
4 hit "worktree create failed" before chump-local even spawned. Default
±30% randomization breaks the synchronization. After
`CHUMP_STARVE_THRESHOLD` consecutive empty picks (default 3), each worker
emits `kind=fleet_starved` to `ambient.jsonl` so the operator sees the
quiet fleet is starved (filters too tight, queue empty) instead of
guessing. Knobs: `CHUMP_POLL_JITTER` (% randomization, default 30),
`CHUMP_STARVE_THRESHOLD` (consecutive empties before ALERT, default 3).
Aggregate view: `scripts/dispatch/fleet-status.sh --pane starvation` —
shows last-24h `fleet_starved` count per agent + per filter combination,
so a tight `FLEET_DOMAIN_FILTER` accumulating all the events IS the
diagnosis.

Auto-pickup excludes `EVAL-*`, `RESEARCH-*`, `META-*` (those need human
judgment) and any gap with non-empty `depends_on`. Smoke test:
`scripts/ci/test-run-fleet-smoke.sh`.

**INFRA-420 cost guard:** `FLEET_BACKEND=claude` is refused without
`CHUMP_FLEET_ALLOW_CLAUDE_BACKEND=1` — Opus is ~50× haiku per token and
has burned workspace credit caps in prior sessions.

## Coordination docs

- `.chump/state.db` — **canonical** gap registry (SQLite, since INFRA-059); accessed via `chump gap …` subcommands
- `docs/gaps/<ID>.yaml` — human-readable per-file mirror (post-INFRA-188; the legacy monolithic `docs/gaps.yaml` was deleted), regenerated by `chump gap set/ship/dump`; commit alongside DB mutations so PRs are reviewable
- `.chump/state.sql` — readable diff of the SQLite schema/data; regenerate with `chump gap dump --out .chump/state.sql` after merge conflicts
- `docs/process/AGENT_COORDINATION.md` — full coordination system (leases, branches, failure modes, pre-commit spec)
- `docs/process/POST_INFRA_188_GOTCHAS.md` — short-lived (2026 Q3 prune target) operational gotchas observed during the post-cutover ship wave: `gh run rerun --failed` replays old payloads, `<DOMAIN>-<NUM>:` PR titles trip `gap-status-check`, the 38 lost per-file YAMLs (INFRA-240), `chump gap reserve` writes at outer `repo_root()` not linked-worktree CWD (INFRA-247), and the `chump` vs `chump-coord` binary path split. Read once at session start during the cleanup window; the doc auto-prunes when `scripts/audit/check-post-infra-188-gotchas-prunable.sh` returns 0.
- `chump gap preflight` — gap availability check (reads lease files + checks done on main); Rust-based replacement for deprecated `scripts/coord/gap-preflight.sh`
- `chump claim` — write a gap claim to your session's lease file; Rust-based replacement for deprecated `scripts/coord/gap-claim.sh`
- `scripts/coord/bot-merge.sh` — ship pipeline (calls `chump claim` automatically)
- `scripts/coord/gap-doctor.py` — drift detector + repair tool (INFRA-155). Compares `.chump/state.db` against `docs/gaps/<ID>.yaml` files (post-INFRA-188; previously the monolithic `docs/gaps.yaml`) and reports four buckets: DB done / YAML open (regen YAML), DB open / YAML done (sync DB from YAML), DB-only orphans, YAML-only ghosts. Run `gap-doctor.py doctor` for a read-only report; `sync-from-yaml --apply` drains pre-INFRA-152 hand-edit drift; `sync-from-db --apply` regenerates YAML from DB. The 2026-04-28 first run drained 25 status:open-but-actually-done rows in one shot.
- `scripts/ops/stale-pr-reaper.sh` — runs hourly, auto-closes PRs whose gaps landed on main. **INFRA-1195 freshness gate (2026-05-14)**: before auto-closing, the reaper checks the PR's `updatedAt` timestamp. If updated within `CHUMP_CURATOR_FRESHNESS_MIN` minutes (default 10), the close is **skipped** and a `kind=curator_skip_active_rebase` event is emitted to `ambient.jsonl`. This prevents false-closes during active rebase/force-push windows. Bypass: `CHUMP_CURATOR_FRESHNESS_MIN=0`. If you see these events but the PR is genuinely stale, wait for the freshness window to expire or close manually.
- `scripts/ops/stuck-pr-filer.sh` — INFRA-307, hourly. Detects stuck PRs (DIRTY > 4h, required CI red > 2h, BEHIND > 20 commits, or auto-merge disarmed with no live owner lease) and **files them as INFRA P1 cleanup gaps** so `run-fleet.sh` picks them up under default filters. This replaces the human-as-relay loop ("agent A's PR #472 is stuck — please tell A"): the cleanup work belongs to whoever the fleet picks up next, not the original (often-exited) author. De-dups by title (`PR #N stuck — …`); skips drafts, dependabot, and `chore(gaps): file/reserve …` PRs. Emits `ALERT kind=pr_stuck` to ambient and is graded by the reaper-heartbeat-watchdog. Bypass: `CHUMP_STUCK_PR_FILER=0`. macOS install: `scripts/setup/install-stuck-pr-filer-launchd.sh`. Test: `scripts/ci/test-stuck-pr-filer.sh`.
- `scripts/ops/stale-worktree-reaper.sh` — removes merged / orphaned linked worktrees under `.claude/worktrees/` (default dry-run; use `--execute`). macOS hourly install: `scripts/setup/install-stale-worktree-reaper-launchd.sh` (see **Worktree disk hygiene** above)
- `scripts/ops/reaper-heartbeat-watchdog.sh` — INFRA-120 watchdog that ALERTs `ambient.jsonl` when any stale-* reaper misses its expected cadence (pr 2h / worktree 4h / branch 48h). macOS install: `scripts/setup/install-reaper-watchdog-launchd.sh`
- `scripts/git-hooks/pre-commit` — coordination hook (see **Commit-time guards** table above)
- `scripts/git-hooks/pre-push` — gap-preflight gate (blocks pushes with `done`/stolen-claim gap IDs)
- `scripts/git-hooks/post-checkout` — auto-installs hooks into every worktree after `git worktree add`

## Gap registry — `.chump/state.db` is canonical (INFRA-059, 2026-04-25)

INFRA-023 (2026-04-21) added the SQLite store; INFRA-059 (M1 of the
World-Class Roadmap) **flipped authority** from the then-monolithic
`docs/gaps.yaml` to `.chump/state.db` so concurrent agents no longer race
on a single hot YAML file. (The April 2026 corruption incidents —
INFRA-049/052/055/057/064 — were all instances of that race.) INFRA-188
(2026-05-02) then deleted the monolithic `docs/gaps.yaml` and replaced it
with per-file `docs/gaps/<ID>.yaml` mirrors, eliminating the merge-conflict
hotspot entirely.

- **`chump gap …` subcommands are the primary interface.** They mutate
  `.chump/state.db` directly.
- **`docs/gaps/<ID>.yaml` files are a regenerated mirror**, not a source.
  They exist so PRs have a human-readable diff. Regenerate via `chump gap
  ship --update-yaml` (per-ship) or `chump gap dump` (full export to
  `docs/gaps/`).
- **`.chump/state.sql` is the readable diff of the SQLite store** — commit
  it alongside any DB mutation so reviewers can see what changed (binary
  SQLite is unreviewable). After a merge conflict in the SQL dump,
  regenerate with `chump gap dump --out .chump/state.sql`.
- **Legacy shell scripts (`gap-claim.sh`, `gap-reserve.sh`,
  `gap-preflight.sh`) still work** as fallbacks and are wired into hooks,
  but the Rust-native commands are preferred. Note: the shell scripts
  predate the SQLite store — they operate on lease files and (post-INFRA-188)
  `docs/gaps/<ID>.yaml` files; they do **not** read or write
  `.chump/state.db`. So when an agent is driving via `bot-merge.sh` (which
  calls `gap-claim.sh`), the lease layer and the SQLite store are
  independent. The two converge when `chump gap ship --update-yaml`
  regenerates the per-file YAML mirrors at ship time.

```bash
chump gap import                          # one-time: seed DB from per-file docs/gaps/<ID>.yaml mirrors (historical: pre-INFRA-188 it read the monolithic docs/gaps.yaml)
chump gap list [--status open] [--json]   # list gaps; --json output is musher-compatible
chump gap reserve --domain INFRA --title "..." [--priority P1] [--effort s]
chump gap claim <GAP-ID> [--session ID] [--worktree PATH]
chump gap preflight <GAP-ID>              # exit 0=available, 1=done/claimed
chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N]   # flip status: done + stamp closed_date (+ closed_pr if given); --update-yaml regenerates docs/gaps/<ID>.yaml
chump gap set <GAP-ID> [--title|--description|--priority|--effort|--status|--notes|--source-doc|--opened-date|--closed-date|--closed-pr N|--acceptance-criteria "a|b|c"|--depends-on "X,Y"]
chump gap dump                            # full export to per-file docs/gaps/<ID>.yaml mirrors
chump gap restore --from-sql              # rebuild state.db from .chump/state.sql when DB is corrupted (INFRA-538)
```

### state.db corruption recovery (INFRA-538)

If `.chump/state.db` is corrupted or missing but `.chump/state.sql` (the tracked YAML mirror) is intact:

```bash
# Verify state.sql exists and has content
wc -l .chump/state.sql

# Rebuild state.db from the YAML mirror.
# Automatically backs up existing state.db → state.db.bak before overwriting.
chump gap restore --from-sql

# Verify the row count looks right
sqlite3 .chump/state.db "SELECT COUNT(*) FROM gaps"

# Optional: re-import per-file docs/gaps/ YAMLs to pick up any gaps added
# since the last state.sql regen
chump gap import
```

If `state.sql` is also corrupted or out of date, fall back to rebuilding from the per-file YAML mirrors in `docs/gaps/`:
```bash
# Remove corrupted state.db and rebuild from scratch via import
rm .chump/state.db
chump gap import   # seeds a fresh state.db from docs/gaps/*.yaml
```

## Doctor / health / fleet-status — which entry point does what (INFRA-1218)

Four similarly-named entry points; pick the right one for the symptom:

| Tool | Purpose | When to use |
|---|---|---|
| `scripts/dev/chump-binary-unwedge.sh` | Heal the wedged-inode `_dyld_start` hang (INFRA-275) | `chump gap …` hangs, `ps` shows `UE` processes |
| `chump --doctor` (Rust subcommand) | Config + environment sanity report | Setup verification, "is my env wired right" |
| `chump fleet doctor` (Rust subcommand) | Fleet-wide health report — agents, leases, queue | Operator daily check / dashboards |
| `chump health` (Rust subcommand) | SLO-style metrics digest, fleet pillar grades | KPI / pillar-balance review |
| `scripts/dispatch/fleet-status.sh` | Operator-facing tmux dashboard (panes) | Interactive monitoring |
| `scripts/dispatch/fleet-status.sh --once` | Single-pane snapshot to stdout | CI / unattended loops / `scripts/dev/fleet-status.sh` is a shim for this |

The `chump-doctor` *concept* (env vars like `CHUMP_DOCTOR_SKIP`, the heal pattern, the binary-probe preflight) is still named `chump-doctor` everywhere — INFRA-1218 only renamed the script *file* from `chump-doctor.sh` to `chump-binary-unwedge.sh` to disambiguate the filename from `chump --doctor`. The Rust subcommand and the wedge-recovery script have different jobs; their names should reflect that.

## Code-intelligence shortcuts — verify before claiming missing (INFRA-1575, 2026-05-16)

When verifying whether a feature, gap, symbol, or endpoint exists, prefer these over raw grep + filename inference. Each is one shell call; together they close the misdiagnosis class that produced [INFRA-1575](../gaps/INFRA-1575.yaml) — 10 shipped A2A gaps claimed "missing" because `chump gap show` returned "not found" for closed-and-reaped gaps. See AGENTS.md "Filing meta-patterns" behaviour 4 for the discipline rule; this is the canonical command per question.

| Question | Canonical command | Wrong way that bites |
|---|---|---|
| Does gap-ID X exist (open or shipped)? | `gh search code <ID> --limit 5` or `git log --all --oneline \| grep <ID>` | `chump gap show <ID>` alone — silent on reaped |
| Does symbol X exist in Rust source? | `ast-grep --pattern 'fn $NAME(...)' src/` | `grep -rn 'fn X' src/` — matches comments, misses generics |
| Who calls fn X? | `rust-analyzer` LSP (when wired) or `ast-grep --pattern '$NAME(...)' src/` | `grep -rn 'X(' src/` — matches definitions + false positives |
| What handler serves `/api/foo`? | `grep -nE 'route\("/api/foo"' src/web_server.rs` + check `web/v2/` for callers | guessing from route registration alone |
| Is event-kind X emitted anywhere? | `grep -rE '"kind":"<X>"' src/ scripts/` + cross-check `docs/observability/EVENT_REGISTRY.yaml` | reading EVENT_REGISTRY.yaml alone (416 declared vs ~20 firing) |

**Helper script**: `scripts/dev/verify-existence.sh <ID-or-symbol>` ([INFRA-1589](../gaps/INFRA-1589.yaml)) runs all four checks and reports tri-state `{confirmed_shipped | confirmed_absent | ambiguous}`. Use this **before filing any "feature X is missing" gap** — it's one of the AGENTS.md behaviour-4 mandates.

[INFRA-1583](../gaps/INFRA-1583.yaml) (chump-mcp-code MCP server, Phase 5) will replace each CLI invocation with a structured MCP call (~50 tokens vs ~5000 for a file read). Until that ships, these CLI shortcuts are the discipline.

## Known error classes — self-help index (INFRA-590)

Scripts append `See: docs/process/CLAUDE_GOTCHAS.md#<anchor>` to high-frequency
errors so you can jump directly to the recovery steps. The four anchored classes:

<a id="error-binary-wedge"></a>
### error-binary-wedge — chump binary wedged by syspolicyd

**Symptom:** `chump gap …` hangs indefinitely (no output, never exits). `ps` shows
chump processes in state `UE` (uninterruptible exit). Direct `sqlite3 .chump/state.db`
works — the DB is fine, the binary is wedged at `_dyld_start`.

**Root cause:** macOS Sequoia's `syspolicyd` (Gatekeeper) gets the binary's inode into a
pending-decision queue; every subsequent launch of the same inode blocks behind it.

**Recovery:**
```bash
scripts/dev/chump-binary-unwedge.sh                     # probe + replace wedged inode (preferred)
CHUMP_DOCTOR_FORCE=1 scripts/dev/chump-binary-unwedge.sh  # skip probe, just heal
# Nuclear (needs sudo): sudo kill syspolicyd
```
The doctor moves the wedged binary to `~/.cargo/bin/chump.wedged-inode-<n>` and copies
content back through a fresh inode that syspolicyd treats as new. Zombie UE processes
clear on reboot but are otherwise harmless. Rebuild if doctor fails:
```bash
cargo build --release --bin chump && cp target/release/chump ~/.local/bin/chump
```

<a id="error-gap-collision"></a>
### error-gap-collision — gap already claimed or open PR exists

**Symptom:** `gap-preflight.sh` or `bot-merge.sh` exits with "SKIP <GAP-ID> — open PR
#N … is already implementing this gap" or "claimed by session …".

**Root cause:** Another agent (or a prior session of yours) is actively working this
gap. Picking the same gap produces wasted compute and a merge collision.

**Recovery:**
```bash
chump gap list --status open              # find a different pickable gap
# If the existing PR is abandoned and you own it:
CHUMP_PREFLIGHT_PR_CHECK=0 scripts/coord/gap-preflight.sh <GAP-ID>
# To race intentionally (INFRA-193):
CHUMP_SPECULATIVE=1 scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

<a id="error-missing-closed-pr"></a>
### error-missing-closed-pr — status:done committed without a real PR number

**Symptom:** pre-commit exits with "INCOMPLETE CLOSURE (INFRA-107) — gap(s) flipped to
status:done with missing or non-numeric closed_pr".

**Root cause:** A `docs/gaps/<ID>.yaml` file was hand-edited to `status: done` without
setting `closed_pr` to a real PR number (or it was set to `TBD`). The guard requires an
actual numeric PR number so the registry is auditable.

**Recovery:**
```bash
# Use the canonical ship path instead of hand-editing:
chump gap ship <GAP-ID> --closed-pr <PR-NUMBER> --update-yaml
# If you must hand-edit, set the field explicitly:
#   closed_pr: 404   ← real numeric PR number, not TBD
# Bypass (escape hatch only):
CHUMP_GAPS_LOCK=0 git commit ...
```

<a id="error-wrong-worktree"></a>
### error-wrong-worktree — refusing to claim gap in the main worktree

**Symptom:** `gap-claim.sh` exits with "ERROR: refusing to claim gap in the main
worktree."

**Root cause:** You ran `gap-claim.sh` (or `bot-merge.sh`, which calls it) from the
primary repo checkout instead of a linked worktree. Concurrent agents share the same
`.chump-locks/` dir in the main checkout, causing lease ID collisions.

**Recovery:**
```bash
# Create a linked worktree and re-run from there:
git worktree add .claude/worktrees/<name> -b chump/<name> origin/main
cd .claude/worktrees/<name>
scripts/coord/gap-claim.sh <GAP-ID>
# Bootstrap escape hatch (short-lived solo work only):
CHUMP_ALLOW_MAIN_WORKTREE=1 scripts/coord/gap-claim.sh <GAP-ID>
```

<a id="atomic-claim-collision"></a>
### atomic-claim-collision — two live leases on the same gap_id (INFRA-1608)

**Symptom:** `.chump-locks/*.json` (or `chump gap show <GAP-ID>`) shows two
different sessions both holding a live lease for the same gap_id at once —
e.g. the INFRA-1602 case that motivated this gap: `claim-infra-1602-26392-…`
and `claim-infra-1602-47300-…` both within TTL simultaneously. No
`kind=lease_overlap` event in `ambient.jsonl` despite the visible collision.

**Root cause:** `check_gap_id_uniqueness` (in
`crates/chump-atomic-claim/src/atomic_claim.rs`) was a scan-then-decide
read, not a lock — two sessions could both pass it before either's
per-session lease file was written, because the durable write happens only
after several seconds of `git worktree add` / gitdir-repair setup. Classic
TOCTOU. Full forensic writeup: `docs/audits/lease-collision-2026-05-17.md`.

**Fix (shipped, INFRA-1608):** `reserve_gap_claim_marker()` reserves a
gap-keyed marker file via `create_new` (O_EXCL) — a kernel-atomic operation
— BEFORE worktree setup runs, closing the race window. The loser emits
`kind=lease_overlap` with `{gap_id, winner_session, loser_session,
paths_attempted}`.

**Diagnosis steps if you suspect a relapse:**
```bash
# Confirm exactly one live lease per gap_id:
for f in .chump-locks/claim-*.json .chump-locks/*.json; do
  jq -r 'select(.gap_id) | "\(.gap_id) \(.session_id) \(.expires_at)"' "$f" 2>/dev/null
done | sort | awk '{print $1}' | uniq -d
# Any gap_id printed above has >1 live lease — a relapse.
grep '"kind":"lease_overlap"' .chump-locks/ambient.jsonl | tail -5
```

**Test command:**
```bash
cargo test -p chump-atomic-claim gap_claim_marker_tests   # unit + 50-thread race
bash scripts/ci/test-atomic-claim-collision.sh            # full regression script
```

---

<a id="worktree-path-confusion"></a>
### worktree-path-confusion — macOS /tmp → /private/tmp symlink corrupts gitdir (INFRA-779)

**Symptom:** Inside a linked worktree, `git rev-parse --show-toplevel` returns
the wrong path (the main checkout or a sibling worktree path). Git commands
operate on the wrong tree, silently staging or committing to the wrong branch.

**Root cause:** On macOS, `/tmp` is a symlink to `/private/tmp`. When
`git worktree add /tmp/chump-infra-NNN` is run, git records the worktree in
`.git/worktrees/chump-infra-NNN/gitdir` as `/tmp/chump-infra-NNN/.git`. But the
worktree's actual path on disk is `/private/tmp/chump-infra-NNN`. Concurrent
sibling claims can overwrite each other's gitdir back-reference.

**Symptoms in practice:**
- `git status` shows another gap's files
- `git add` stages to the wrong branch
- `git log` shows a commit history from a different worktree

**Recovery:**
```bash
# 1. Identify the correct worktree name:
git worktree list | grep <gap-id>
# 2. Repair the gitdir back-reference (INFRA-779 fix):
echo "/private/tmp/chump-infra-NNN/.git" \
    > /Users/<you>/Projects/Chump/.git/worktrees/chump-infra-NNN/gitdir
# 3. Verify the fix (env vars on one line so the shell expands both before git runs):
GIT_DIR=/Users/<you>/Projects/Chump/.git/worktrees/chump-infra-NNN GIT_WORK_TREE=/private/tmp/chump-infra-NNN git status
# 4. Use explicit vars for all git commands in that worktree session:
GIT_DIR=/Users/<you>/Projects/Chump/.git/worktrees/chump-infra-NNN GIT_WORK_TREE=/private/tmp/chump-infra-NNN git add <files>
GIT_DIR=/Users/<you>/Projects/Chump/.git/worktrees/chump-infra-NNN GIT_WORK_TREE=/private/tmp/chump-infra-NNN git commit -m "..."
```

**Prevention:** `chump claim` auto-runs the gitdir repair since INFRA-779.
If claiming manually via `gap-claim.sh`, add the repair step immediately after
`git worktree add`.

**Related — worktree reaper data-loss protection (INFRA-1347).**
`scripts/coord/worktree-prune.sh` now refuses to delete a worktree if **any**
of the following hold (it emits `kind=worktree_reaper_skipped_active` with the
matching `reason` so the audit trail surfaces the save):

1. `git status --porcelain` is non-empty (uncommitted tracked changes)
2. Untracked-and-non-gitignored files exist (e.g. new test/doc files not yet
   `git add`'d — INFRA-1346 lost 40 LOC of edits this way before the fix)
3. `git rev-list origin/<branch>..HEAD` > 0 (committed but unpushed)
4. An active lease in `.chump-locks/*.json` names the worktree with
   `heartbeat_at` within 15 min
5. `.git/index` mtime within 30 min (cargo-build pauses can exceed 5 min, so
   the prior 5 min threshold was too tight)

Do **not** disable these via `CHUMP_REAPER_SAFETY_CHECK=0` in production —
the gate exists because INFRA-1346 lost two attempts worth of work in one
session before INFRA-1347 closed the holes.

---

<a id="stale-lease-cleanup"></a>
### stale-lease-cleanup — detecting and releasing orphaned leases

**Symptom:** `gap-preflight.sh` or `chump claim` reports "lease conflict" but no
agent is actively working the gap. The lease file exists in `.chump-locks/` but
the process that wrote it is no longer running.

**Root cause:** An agent crashed, timed out, or was killed before it could call
`chump --release`. The lease file persists because it is written atomically but
never cleaned up.

**Detecting orphaned leases:**
```bash
# List all active leases:
ls .chump-locks/claim-*.json
# For each lease, check if the holding process is alive:
python3 -c "
import json, os, sys
for f in sorted(os.listdir('.chump-locks')):
    if not f.startswith('claim-'): continue
    d = json.loads(open('.chump-locks/' + f).read())
    pid = int(f.split('-')[2])  # PID is encoded in filename
    alive = os.path.exists(f'/proc/{pid}') or not os.system(f'kill -0 {pid} 2>/dev/null')
    print(f'{\"ALIVE\" if alive else \"DEAD\":6} pid={pid} gap={d.get(\"gap_id\",\"?\")} session={d[\"session_id\"]}')
"
# macOS equivalent (no /proc):
for f in .chump-locks/claim-*.json; do
    pid=$(basename "$f" .json | cut -d- -f3)
    if kill -0 "$pid" 2>/dev/null; then echo "ALIVE pid=$pid $f"
    else echo "DEAD  pid=$pid $f"; fi
done
```

**Releasing a stale lease:**
```bash
# Safe release (verifies session matches):
chump --release --lease .chump-locks/claim-<gap>-<pid>-<ts>.json
# If chump --release fails, remove manually after confirming process is dead:
kill -0 <pid> 2>/dev/null && echo "still alive!" || rm .chump-locks/claim-<gap>-<pid>-<ts>.json
```

**When to release:**
- Process dead (kill -0 returns nonzero) and heartbeat is stale (> 10 min old)
- Worktree was removed with `git worktree remove --force` but lease file remains
- CI/CD orphaned a claim after a timeout

**When NOT to release:**
- Process is still alive — the agent may be mid-commit or awaiting CI
- You are not sure — check ambient.jsonl for recent events from that session first

---

<a id="event-registry-bypass"></a>
### event-registry-bypass — bypassing the EVENT_REGISTRY pre-commit guard (INFRA-754)

**Symptom:** Pre-commit hook rejects your commit with:
```
[event-registry] ERROR: kind 'my_new_event' appears in staged diff but is NOT registered
[event-registry] Add an entry to docs/observability/EVENT_REGISTRY.yaml before committing.
```

**Root cause:** You added a new `"kind":"my_new_event"` literal in a script or
Rust source, but didn't register it in the event registry. The guard is
pattern-based: any `"kind":"X"` string literal in the staged diff triggers it.

**Correct fix — always preferred:**
1. Add an entry to `docs/observability/EVENT_REGISTRY.yaml`:
```yaml
  - kind: my_new_event
    emitter: scripts/coord/my-script.sh (INFRA-NNN)
    trigger: one-line description of when this fires
    consumers: [fleet-brief, watchdog]
    fields_required: [ts, kind, <other fields>]
```
2. Stage the YAML alongside your other changes and commit.

**Bypass (test fixtures and rare cases only):**
```bash
# Set the bypass env var AND add a trailer to the commit body:
CHUMP_OBS_BUDGET_BYPASS=1 git commit -m "$(cat <<'EOF'
fix: my change

Obs-Bypass-Reason: test fixture only — kind=my_test_event never emitted in production
EOF
)"
```

**Bypass discipline:**
- Only bypass for test fixtures or when the kind is intentionally not registered
- The `Obs-Bypass-Reason` trailer is mandatory — the audit log searches for it
- Never bypass for production event kinds — register them properly instead
- If you find yourself bypassing repeatedly for a real kind, the fix is to register it

---

### ci-yml merge-driver orphan step (INFRA-1199)

**Symptom:** After rebasing, `.github/workflows/ci.yml` ends with a dangling step:
```yaml
      - name: gap-reserve concurrency (INFRA-021)
```
…with no `run:` or `uses:` body. GitHub Actions rejects the file with
*"This run likely failed because of a workflow file issue"* — zero CI jobs run,
no checks appear, the PR is permanently blocked.

**Root cause:** The `scripts/git/merge-driver-ci-yml-add-row.sh` custom merge
driver resolves ci.yml conflicts by appending the lines theirs-branch added
beyond the common ancestor. If the theirs-branch's version of ci.yml contained
an incomplete step (a `- name:` header without a `run:` body), the driver
blindly appended it. As of INFRA-1199, the driver detects this via
`validate_step_bodies()` and exits 1 (falls back to standard 3-way merge)
instead of writing the orphan step.

**If you hit this before the fix is deployed:**
```bash
# Remove the trailing orphan step manually
# Open .github/workflows/ci.yml in your editor and delete the dangling '- name:' line at the end
git add .github/workflows/ci.yml
git commit --amend --no-edit
```

**Permanent fix:** INFRA-1199 landed in `scripts/git/merge-driver-ci-yml-add-row.sh`.
If you see this after INFRA-1199, check that:
1. The driver script is the INFRA-1199 version (`grep 'INFRA-1199' scripts/git/merge-driver-ci-yml-add-row.sh`)
2. The merge driver attribute is registered in `.gitattributes`

---

### Runner-side cargo "silent-build-failure" was actually a path bug (INFRA-2096)

**Symptom (observed multiple times 2026-05-27/28):** Self-hosted Mac
runner reports `cargo build -q -p <pkg>` exit 0 but
`$ROOT/target/debug/<binary>` doesn't exist. Next exec via the binary
fails with `No such file or directory` (exit 127). All PRs' fast-checks
fail on what reads like a runner-state issue. Initially diagnosed as
INFRA-2082 silent-build-failure class.

**Actual root cause (INFRA-2096 retro):** the self-hosted runner
sets `CARGO_TARGET_DIR=/Users/jeffadkins/.cache/chump-runner/cargo-target`
per INFRA-1540 (shared cargo cache across jobs). `cargo build` correctly
writes the binary there. Scripts that hardcoded
`$ROOT/target/debug/<binary>` instead of honoring the env var looked
in the wrong directory — they reported "binary missing" while the
binary was alive and well at the env-var-pointed path.

**The wider lesson:** silent-success-with-missing-binary is rarely
silent build failure; it's usually a path mismatch between where
cargo wrote and where the script looked. Before diagnosing as
silent class, check: `cargo metadata --no-deps --format-version 1 |
jq -r .target_directory` shows where cargo actually wrote.

**Layered defenses (in order):**

1. **Path resolution (INFRA-2096 canonical fix)** — use
   `cargo metadata` to discover the canonical target directory.
   Falls back to `$CARGO_TARGET_DIR` env var, then `$ROOT/target`.
   `scripts/ci/test-mcp-coord-smoke.sh` is the reference implementation.
2. **SKIP guard (INFRA-2096 belt+suspenders)** — when the binary is
   genuinely missing after build (cargo not on PATH, build exit
   non-zero, build exit 0 but binary still absent across all candidate
   dirs), SKIP (exit 0) and emit `kind=trunk_red_skip` to
   `ambient.jsonl`. Audit cadence: weekly review of `trunk_red_skip`
   events to catch real silent-class regressions.
3. **Loud-fail wrapper (INFRA-2086)** — `chump_cargo_build` in
   `scripts/coord/lib/cargo-helpers.sh` detects the 4 silent classes
   and converts to structured stderr. Still needs the INFRA-2096
   path-resolution fix to look in the right place (filed as follow-up).
4. **Sibling pattern (INFRA-1955)** — earlier SKIP-guard pattern
   in `scripts/ci/coord-surfaces-smoke.sh`. Also needs path-resolution
   audit.

**Audit which PRs were unblocked by SKIP:**

```bash
grep '"kind":"trunk_red_skip"' .chump-locks/ambient.jsonl | tail -20
```

**Follow-ups to file when this happens again:**

- Audit all `scripts/ci/test-*.sh` for hardcoded `$ROOT/target/`
  references; migrate to `cargo metadata` resolution.
- Audit `scripts/coord/lib/cargo-helpers.sh` `chump_cargo_build`
  for the same hardcoded-path bug (INFRA-2086 wrapper).
- Document `CARGO_TARGET_DIR` and `.cargo/config.toml target-dir`
  precedence in runner-setup docs so future CI scripts know not
  to hardcode.

---

## Autopilot "alive but idle" — wizard-retirement criteria met on paper, broken in production (INFRA-2101)

**Symptom (observed 2026-05-28):** `chump fleet autopilot status` reports daemons loaded; ambient stream shows `autopilot_heartbeat` and `daemon_tick` events firing every few minutes. But `sub_agent_dispatched` count is **0 for 24+ hours**. Ship rate drops from 40 PRs/24h → 12 PRs/24h, mostly natural-CI merges of operator-armed PRs (no new autonomous claims). The fleet is alive but producing nothing.

**Why it stays invisible:** every existing monitor checks per-daemon health (heartbeat-fired? plist-loaded? PID-alive?). None checks the end-to-end dispatch chain. Daemons "pass" individually while the chain produces zero output collectively.

**Root cause (one of multiple):** the JIT binary refresh daemon (`refresh-runner-binary.sh`) was running `cargo install --path "$REPO_ROOT"` — which builds from the operator's local working tree, not `origin/main`. When the operator has WIP and the local main is N commits behind origin/main, the "refresh" silently emits `prev_sha == new_sha` forever. The operator's installed `chump` binary stays stuck at the local stale SHA while origin/main advances. Wizard-retirement criterion #1 (INFRA-1892 JIT scheduler) was technically shipped but practically broken.

**Fixes shipped in INFRA-2101:**

1. `scripts/setup/refresh-runner-binary.sh` now builds in a detached worktree at `origin/main` (`git worktree add -d /tmp/chump-binary-refresh origin/main`), not the local working tree. Hardcopies `target/release/chump` to `/opt/homebrew/bin/chump`. Worktree is torn down on EXIT trap.

2. New ambient kind `runner_binary_advance` records `{prev_sha, new_sha, main_sha, delta_commits}` so the operator can audit whether the daemon is actually making forward progress (not just exiting cleanly).

3. Silent-staleness guard: if `new_sha == prev_sha` AND `delta_commits > 0` (origin/main advanced but our build produced the same SHA), emit `runner_binary_refresh_failed` with `reason:silent_staleness` instead of `runner_binary_refreshed`. Catches the failure mode that originally let this hide for days.

4. New detector `scripts/ops/dispatch-flatline-detector.sh` — reads ambient.jsonl for `sub_agent_dispatched` events over a rolling window (default 2h). When count is 0 AND `autopilot_heartbeat > 0` (alive-but-idle), emits `kind=dispatch_flatline`. Operator sees it in SessionStart digest's `Alerts(30m)` counter. Wire to launchd cron via `scripts/setup/install-dispatch-flatline-detector-launchd.sh` (filed as follow-up).

**Operator action when `kind=dispatch_flatline` fires:**

The autopilot daemons assume **6 live `claude --loop` curator sessions** exist (per OPERATOR_PLAYBOOK §2). Without them, JIT scheduler has nothing to dispatch to. Check: `ls .chump-locks/sessions/` should be non-empty; `ps -eo command | grep "claude --loop"` should show 6 curator processes. If absent, the playbook expects the operator to spawn them by hand. Filed as a separate concern (auto-launch curators on autopilot start would be a discrete gap — see WIZARD_STRATEGIC_BACKLOG).

---

## OAuth token chain silently stale — Oracle/JIT/dispatch flatline cascade (INFRA-2124, 2026-05-29)

**Symptom (observed 2026-05-29):** Headless `claude -p` subprocesses return `"Not logged in"`. Operator's interactive `claude` CLI works fine; macOS Keychain entry `Claude Code-credentials` is populated correctly. But Oracle silently fails (INFRA-2122), JIT scheduler reads stale priorities, and `kind=dispatch_flatline` fires after a quiet 2h+ window.

**Why it stays invisible:** the operator never sees the failure. Each piece (login, keychain, subprocess) looks fine in isolation. The break is in the glue file `~/.chump/oauth-token.json` — subprocesses inherit `CLAUDE_CODE_OAUTH_TOKEN` from this file (per CLAUDE.md INFRA-622 auth-modes spec), and the file went 3+ weeks stale because **no daemon was actually refreshing it**.

**Root cause:** the CLAUDE.md INFRA-622 spec promises "OAUTH tokens are refreshed to `~/.chump/oauth-token.json` every 5 min". The implementation lived inside `scripts/dispatch/run-fleet.sh` (lines 574–614), but that refresher is a backgrounded `while true` only spawned when subscription-mode `run-fleet.sh` is alive. When the fleet stops (or never starts), the refresher dies. The file goes stale within hours; subprocess `claude -p` calls silently fail with the stale token.

**Diagnostic checklist:**
```bash
# 1. Is the token file fresh? (Should be <15 min)
ls -la ~/.chump/oauth-token.json
python3 -c "import json; d=json.load(open('$HOME/.chump/oauth-token.json')); print('written_at:', d['written_at'])"

# 2. Is the keychain entry healthy? (Should print a `sk-ant-oat01-...` access token)
security find-generic-password -a "$(whoami)" -s "Claude Code-credentials" -w | \
  python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["claudeAiOauth"]["accessToken"][:30] + "...")'

# 3. Is the refresh daemon loaded?
launchctl list | grep com.chump.oauth-refresh
```

**Fix shipped in INFRA-2124:**

1. **Standalone refresh daemon** `scripts/coord/oauth-token-refresh.sh` — extracts `claudeAiOauth.accessToken` from macOS Keychain (`Claude Code-credentials`), parses JSON, atomically writes `~/.chump/oauth-token.json` with `{"token":"...","written_at":"<iso8601>","source":"keychain"}`. Independent of `run-fleet.sh`; works whether the fleet is up or not.

2. **LaunchAgent** `launchd/com.chump.oauth-refresh.plist` with `StartInterval=300` (5 min per spec) and `RunAtLoad=true`. Installed via `scripts/setup/install-oauth-refresh-launchd.sh` (operator action — one-time).

3. **Three new ambient kinds** (registered in `scripts/ci/event-registry-reserved.txt` + `docs/observability/EVENT_REGISTRY.yaml`): `oauth_token_refreshed`, `oauth_token_refresh_failed`, `oauth_token_stale_despite_daemon`.

4. **Wedge detector**: `scripts/coord/infra-watcher-loop.sh check-oauth-freshness` (rolled into `tick`) — if the file is older than `CHUMP_OAUTH_STALE_S` (default 900s) AND the plist is loaded, emits `kind=oauth_token_stale_despite_daemon` (critical). Loud signal that the daemon ran but is wedged (keychain perm revoked / python3 PATH gone / refresh-once subprocess hung).

**Operator first-time install:**
```bash
bash scripts/setup/install-oauth-refresh-launchd.sh
launchctl list | grep com.chump.oauth-refresh
launchctl start com.chump.oauth-refresh        # force one cycle
tail -1 /tmp/chump-oauth-refresh.out.log       # should print "OK: wrote ..."
```

**Related class** — same shape as INFRA-2101 binary refresh (daemon-promised-but-never-shipped) and INFRA-2122 Oracle staleness (downstream consumer of this token chain). The general lesson: any CLAUDE.md spec that says "X is refreshed every Y minutes" should be checked for a corresponding plist + install helper + ambient emit — the "background `while true` inside another script" pattern is a stall trap.

---

## Fleet git worktree path confusion (INFRA-779)

**Problem:** On macOS, `/tmp` is a symlink to `/private/tmp`. When a linked worktree
is created at `/tmp/chump-<name>`, its `gitdir` back-pointer records the path as
`/private/tmp/chump-<name>/.git`. If a concurrent sibling agent has a worktree nested
inside the main project (e.g. `.chump/worktrees/infra-855-dedup`), git's internal
path resolution can resolve `git rev-parse --show-toplevel` to the WRONG worktree
directory. This causes `REPO_ROOT` to point at a sibling's tree, leading `bot-merge.sh`
to push from the wrong branch, pre-commit hooks to operate on wrong files, and
`state.db` lookups to hit a stale copy.

**Symptoms:**
- `bot-merge.sh` header shows wrong branch: `=== bot-merge: chump/infra-855-dedup → main ===`
  even though the lease is for a different gap.
- `gap-preflight.sh` says gap "not found in gap registry" but it IS in the main
  `state.db`.
- `git branch --show-current` from the worktree returns the correct branch, but
  `git rev-parse --show-toplevel` returns a different worktree's path.

**Recovery (per-command):**
```bash
# Set explicit GIT_DIR + GIT_WORK_TREE for all git operations in the worktree.
# Replace chump-infra-918 with your worktree name.
GIT_DIR=/Users/jeffadkins/Projects/Chump/.git/worktrees/chump-infra-918 \
GIT_WORK_TREE=/private/tmp/chump-infra-918 \
  git <cmd>

# For bot-merge, pass env vars before the invocation:
cd /private/tmp/chump-infra-918
GIT_DIR=/Users/jeffadkins/Projects/Chump/.git/worktrees/chump-infra-918 \
GIT_WORK_TREE=/private/tmp/chump-infra-918 \
  bash scripts/coord/bot-merge.sh --gap INFRA-918 --auto-merge
```

**Prevention:**
`chump claim` now runs `git worktree repair` after `git worktree add` to fix the
gitdir back-pointer. If you create worktrees manually, run:
```bash
git -C /Users/jeffadkins/Projects/Chump worktree repair
```

**Diagnosis:**
```bash
# Check what git thinks the toplevel is vs what it should be:
cd /private/tmp/chump-<name>
git rev-parse --show-toplevel        # may return wrong path
git rev-parse --absolute-git-dir     # should be .git/worktrees/chump-<name>
cat $(git rev-parse --absolute-git-dir)/gitdir   # should be /private/tmp/chump-<name>/.git
```

---

## cargo test must not inherit parent shell git env (INFRA-1057)

**Problem:** When `cargo test --bin chump --tests` is run from a linked `/tmp/` worktree,
tests that spawn git subprocesses (e.g. `make_repo()`, `scan_rescues()`, git init fixtures)
inherit `GIT_DIR` / `GIT_WORK_TREE` / `GIT_COMMON_DIR` / `GIT_INDEX_FILE` from the parent
shell. This causes those git calls to operate on the main repo's `.git/config` instead of
the isolated tempdir, producing config-lock errors, identity-guard failures, or wrong
results (e.g. rescue-tally counting commits from the main repo instead of 0).

**Rule:** Any test or production function that spawns a git subprocess with `Command::new("git")`
and intends to operate on a specific directory must clear the four git env vars:

```rust
Command::new("git")
    .args(...)
    .current_dir(&some_tempdir)
    .env_remove("GIT_DIR")
    .env_remove("GIT_WORK_TREE")
    .env_remove("GIT_COMMON_DIR")
    .env_remove("GIT_INDEX_FILE")
    // Only for commits using t@t.t / ci@chump.test fixture identities:
    .env("CHUMP_GIT_IDENTITY_CHECK", "0")
    .output()
```

**CI gate:** `scripts/ci/test-cargo-tests-from-worktree.sh` spawns a fresh linked
worktree and runs the targeted test modules; it must pass on every PR.

**Symptoms of missing env_remove:**
- `git init` locks `/Users/.../Projects/Chump/.git/config` instead of the tempdir
- `rescue_tally::infra667_count_rescues_returns_zero_on_empty_repo` returns non-zero
- version tests fail with "git config failed" or INFRA-787 identity guard error
- Tests pass in isolation but fail when run from a linked `/tmp/` worktree

---

## Stale lease cleanup

**Problem:** When `bot-merge.sh` fails mid-run (test failure, rebase conflict, OOM),
it may leave a `.chump-locks/<session>.json` lease file behind. The next `chump claim`
on the same gap will fail with "lease conflict" because the old lease still exists.

**As of INFRA-919**, `bot-merge.sh` installs an EXIT trap that deletes the lease on
any exit. If you are on an older `bot-merge.sh` or the trap failed, use the following:

**Detecting orphaned leases:**
```bash
# List all active leases with their gap IDs and ages:
ls -la .chump-locks/*.json 2>/dev/null
# Check if the gap the lease claims is still truly open/in-progress:
cat .chump-locks/<session>.json | python3 -m json.tool
```

**Releasing a stale lease:**
```bash
# Preferred — idempotent, updates ambient.jsonl:
chump --release --lease .chump-locks/<session>.json

# Manual fallback if chump is wedged:
rm .chump-locks/<session>.json
```

**After cleanup, verify the gap can be reclaimed:**
```bash
scripts/coord/gap-preflight.sh <GAP-ID>   # should pass
chump claim <GAP-ID>
```

**Preventing future orphans:** Run `chump-binary-unwedge.sh` after any failed `bot-merge.sh`
invocation — it now reaps stale leases along with zombie processes.

---

## EVENT_REGISTRY pre-commit guard bypass (INFRA-755 / CHUMP_OBS_BUDGET_BYPASS)

**Problem:** The observability budget guard (`INFRA-755`) blocks commits that add
> 50 lines of feature code (`.rs/.sh/.py`) without adding at least one observability
hook (`tracing::info!`, ambient event, or `chump_improvement_targets` lesson). This
prevents "dark" features that can't be diagnosed from `ambient.jsonl`.

**When to bypass:** Only when the new code IS itself an observability tool (e.g.
`chump-doctor --probe-resources`), a test, or infrastructure that by design has no
observable runtime path (e.g. build scripts, CI fixtures).

**How to bypass correctly:**
```bash
# 1. Add a bypass reason trailer to the commit body:
CHUMP_OBS_BUDGET_BYPASS=1 git commit -m "$(cat <<'EOF'
feat(infra-395): chump-doctor --probe-resources substrate check

<body text>

Obs-Bypass-Reason: probe_resources() is itself an observability tool —
its stderr output IS the observable signal for fleet operators.
EOF
)"

# 2. Verify the trailer is in the commit:
git log -1 --format="%B" | grep "Obs-Bypass-Reason"
```

**When NOT to bypass:**
- New `claude -p` dispatch paths without a corresponding ambient event.
- New gap-filing or claim logic without `kind=<name>` event emission.
- Error handlers that silently swallow exceptions.

In those cases, add the observability hook first, then commit normally.
The registered event kinds are in `docs/process/EVENT_REGISTRY.md`; new
kinds must be registered there before use (pre-commit guard enforces this).

## CI cascade-cancel pattern (INFRA-1002)

**Symptom:** CI reports `fast-checks=failure cargo-test=cancelled` and the PR check is red.
An agent (or operator) looking at this sees "multiple things broken" when really there is
ONE real failure (`fast-checks`) and ONE cascade-cancel (`cargo-test` was preempted by the
earlier failure, not because anything tested by `cargo-test` is actually broken).

**Why it happens:** GitHub Actions cancels downstream shards when a parallel shard fails.
The cancelled shard's result shows as `cancelled`, not `skipped`, so it looks like a second
independent failure.

**How the rollup classifies results (INFRA-1002):**
```
cascade_cancel: result == 'cancelled' AND at least one peer == 'failure'
real_failure:   result == 'failure'
               OR result == 'cancelled' AND no peer == 'failure'
```

**What to do:**
1. Read the rollup's `=== INFRA-1002 shard classification ===` block in the CI log.
2. Fix only the `real_failures` list. Cascade-cancelled shards will auto-recover when
   the real failure is fixed and you push again — they are NOT independent bugs.
3. Do NOT assume `N cancelled` means `N bugs`. Cascade-cancels are collateral damage.

**Retry scope for INFRA-1003 (auto-rerun):**
The auto-rerun gate uses `real_failures` (not `cascade_cancels`) to decide which tests
to rerun. A cascade-cancel is benign for retry purposes — only the root failure needs
investigation.

**Test fixture:** `scripts/ci/test-rollup-cascade-cancel.sh` (7 assertions).

## Audit job concurrency policy — per-SHA scoping (INFRA-1852, 2026-05-23)

**Symptom:** `audit` CI job repeatedly cancelled by GH Actions; operator works around with empty-commit retriggers. Hit 10+ times on 2026-05-23.

**Root cause:** `ci.yml` workflow-level `concurrency` block previously keyed PR events on `pull_request.number`, so every fixup push on the same PR cancelled the in-flight CI — including `audit`, which is a required-status check. Branch protection then blocked merge until `audit` was green, forcing the operator to push empty commits specifically to re-trigger it.

**Fix (INFRA-1852):** two layers of defense.

1. **Workflow-level group keyed on `github.sha`** (not PR number): each unique commit gets its own concurrency group, so commit B doesn't cancel commit A's run. Cost: an operator who force-pushes 3 fixups in quick succession may now run CI on all 3 (modest runner-pool consumption). Tradeoff is correct — paying for a few extra runs beats 10+ false-failures per session.
2. **Job-level `concurrency` override on `audit`** with `cancel-in-progress: false` + the same per-SHA group. Belt-and-suspenders: even if the workflow-level group is later widened back to per-PR (e.g. someone reverts the change for cost reasons), the audit job still completes for the SHA it started on.

| Behavior | Workflow-level (all jobs) | `audit` (job-level override) |
|---|---|---|
| Group scope | per-SHA (`github.sha`) | per-SHA (`pull_request.head.sha`) |
| `cancel-in-progress` | `true` | `false` |
| Fixup push cancels prior run? | No (different SHA → different group) | No (different SHA → different group AND no-cancel) |
| Same-SHA retry dedupes? | Yes | Yes |
| Push to main | Unique per-run via `github.run_id` | Unique per-run via `github.run_id` |

**Why per-SHA is the right scope for audit:** audit is cheap (~5 min since INFRA-503 moved cargo audit to nightly). One audit per commit is acceptable cost. The job runs the INFRA-431 chump-gap test suite + smoke-test gauntlet — these are SHA-specific (testing the actual code state at that commit), so finishing the prior run rather than cancelling+restarting is closer to "actually audit each commit."

**What to do if you see audit cancellations come back:**
1. Check `ci.yml` workflow-level `concurrency:` block — confirm group still resolves to `github.sha` for PR/merge_group events.
2. Check the `audit:` job (line ~1321) — confirm its job-level `concurrency:` block is still present with `cancel-in-progress: false`.
3. If you legitimately need to cancel an in-flight audit (e.g. you know the code is broken and want to save runner-minutes), close+reopen the PR or push to a different branch.

**Do not "fix" this by widening the workflow-level group back to per-PR-number** — that re-introduces the failure class. If cost is the concern, set `cancel-in-progress: true` at workflow level (already is) and trust the per-SHA group to dedupe same-SHA re-runs; the job-level override on audit will still hold.

## doc-only PR wedge — required-check never emits, PR sits BLOCKED forever (INFRA-2191, 2026-05-29)

**Symptom:** A doc/yaml-only PR (only touches `docs/**`, `*.md`, gap YAMLs) sits in `mergeStateStatus: BLOCKED` with `gh pr checks` showing **0 failures AND 0 pending**. `gh pr view --json statusCheckRollup` does NOT include the `audit` check-run at all — neither passing nor pending, simply absent. Operator has to either admin-merge or temporarily remove the required-status-checks rule from the ruleset. Took down 6 PRs in one slot on 2026-05-29 before the structural fix landed.

**Root cause:** Branch protection ruleset (15133729 on main) historically required the bare context name `audit`. The real `audit` job in `ci.yml` is gated by `if: needs.changes.outputs.docs_only != 'true' || github.event_name != 'pull_request'` — so on a doc-only PR it SKIPS, emitting no check-run with the name `audit`. Without that check-run, branch protection waits forever for a context that will never exist. Same class as INFRA-2128 (pwa-onboarding) but for hard-required (not advisory) checks.

**Fix (INFRA-2191):** The `audit-stub` job already covered the inverse case (fires when real audit skips), but its `name:` was `audit-stub` — so its check-run was published under a DIFFERENT context than what branch protection required. We renamed `audit-stub.name` from `audit-stub` to `audit`. The job-key stays `audit-stub` (so `audit-required` rollup's `needs: [audit, audit-stub]` chain still resolves), but the published check-run context is now `audit`. Mutual exclusion via the existing `if:` conditions guarantees exactly one of {real audit, audit-stub} runs per PR — never both, never neither.

```yaml
# Real audit (line 1534):
audit:
  if: |
    needs.changes.outputs.docs_only != 'true' ||
    github.event_name != 'pull_request'

# audit-stub (line 2082 — INFRA-2191):
audit-stub:
  name: audit  # <-- emits as 'audit' to satisfy ruleset on doc-only PRs
  if: |
    (needs.changes.outputs.code != 'true' || needs.changes.outputs.docs_only == 'true') &&
    github.event_name == 'pull_request'
```

**Why `test` doesn't need a stub:** the real `test` job is itself a rollup with `if: always()` and `needs:` includes `pr-hygiene` (which runs on every PR regardless of path-filter). It always fires and always emits a check-run under name `test`, so no stub is needed. Guarded by assertion #4 in `scripts/ci/test-ruleset-doc-only-pr.sh` — if someone replaces `if: always()` with a gated condition, the test fails.

**Regression guard:** `scripts/ci/test-ruleset-doc-only-pr.sh` (INFRA-2191) — 5 static-lint assertions over `ci.yml`:
1. `audit-stub.name == 'audit'`
2. real `audit.if` skips on `docs_only`
3. `audit-stub.if` fires on PR + docs_only/code-empty
4. `audit-required.needs` still references both job-keys
5. `test.if == always()`

Mirrored into preflight via `preflight-ci-parity-exceptions.txt`.

**Recovery procedure if you see this in production (PR stuck BLOCKED, 0 fails 0 pending):**
1. Verify: `gh pr view <N> --json statusCheckRollup | python3 -c "import sys,json; d=json.load(sys.stdin); print([c['name'] for c in d['statusCheckRollup'] if 'audit' in c['name'].lower()])"` — if empty list, you're hit by this wedge.
2. Confirm INFRA-2191 fix is on main: `git ls-tree origin/main .github/workflows/ci.yml -- | head -1` and grep for `name: audit  # INFRA-2191`. If absent, the branch needs rebase onto main.
3. Last-resort (operator-only): temporarily remove `required_status_checks` rule from ruleset 15133729 via `gh api`, merge, restore. **This is the manual-cascade-break that 2026-05-29 had to use 6 times** — the whole point of the INFRA-2191 fix is to eliminate the need for it.

**Pairs with:** INFRA-2128 (advisory class — pwa-onboarding), INFRA-1379 (lane flag `docs_only` that enables the audit-stub gating).

## e2e-pwa shadow DOM traversal — `#msg-input` locator pattern (INFRA-817, INFRA-1018, INFRA-1066)

**Symptom:** Five e2e-pwa Playwright tests time out waiting for `page.locator("#msg-input")`.
Output: `Timeout 30000ms exceeded … Locator: locator('#msg-input') … waiting for element to be visible`.
The tests are: "loads home", "navigate between views", "mobile viewport",
"/task creates assistant reply", "New chat clears thread".

**Root cause (regressed 2026-05-13, ~2h red-main):**
`web/v2/index.html` has a V1→V2 backward-compat shim (`createTestAliases()`) that aliases
`<chump-chat>`'s internal `#input` element to `#msg-input` at the top level so Playwright can
find it without shadow-piercing selectors.  The shim broke when code used:
```javascript
viewChat.shadowRoot?.querySelector('chump-chat')  // WRONG — viewChat has NO shadow root
```
`<chump-view-chat>` uses **light DOM** (`this.innerHTML = '...'`), so `.shadowRoot` is always
`null` and optional chaining short-circuits silently.  The alias never ran; `#msg-input`
was never created; all 5 tests timed out.

**Correct traversal (INFRA-1018 fix, merged a87d8e8b):**
```javascript
const viewChat   = document.querySelector('chump-view-chat');
const chumpChat  = viewChat?.querySelector('chump-chat');     // light DOM child
const input      = chumpChat?.shadowRoot?.getElementById('input'); // chump-chat HAS shadow root
if (input && input.id !== 'msg-input') input.id = 'msg-input';
```
Rule: **`<chump-view-chat>` is light DOM; `<chump-chat>` is shadow DOM.**
Always traverse light DOM to reach `<chump-chat>`, then use `.shadowRoot` for its internals.

**Retry loop (also required):**
`<chump-chat>`'s shadow root is populated in `connectedCallback()`, which fires asynchronously
relative to `DOMContentLoaded`.  A single `DOMContentLoaded` handler may run before the
shadow root exists.  The shim must retry every 100 ms until the alias is live:
```javascript
function scheduleTestAliases() {
  if (createTestAliases()) return;
  setTimeout(scheduleTestAliases, 100);
}
```

**Pre-commit guard:** none yet (INFRA-1066 AC #6, optional).
If you add e2e selectors that need shadow piercing, use Playwright's `>>>` shadow-piercing
combinator (`page.locator('chump-chat >>> #input')`) rather than relying on DOM aliases.

## Parallel-ship: two PRs for the same gap (CREDIBLE-066, 2026-05-14)

When two sessions race to claim and ship the same gap, the resulting two PRs interact with the gate machinery in non-obvious ways.

**How GitHub closes the losing PR:**  
If the losing PR's head branch is deleted (e.g., `chump claim` cleanup path deletes the old branch via `gh api .../git/refs/heads/... -X DELETE`), GitHub closes the PR automatically within ~1s. The `issues/{n}/events` API shows `event=closed`, `actor=<repo-owner-via-token>`, and `closed_by=null` — **indistinguishable from a manual operator close.**

**Which gates fire:**

| Gate | When it fires | Does it catch parallel-ship? |
|---|---|---|
| INFRA-1219 (pr-create dedup) | At `gh pr create` time | Yes — if the first PR is still open when the second is created |
| INFRA-1139 (orphan-pr-closer) | On a schedule (cron-like) | Yes — if gap becomes `done` while the losing PR is still open |
| INFRA-1220 (cooldown stamp) | When orphan-pr-closer closes a PR | No — branch-deletion close bypasses the stamp |

**What to do:**  
- If you delete a branch that backs a PR: expect GitHub to close the PR silently. Check `gh pr view <N> --json state` to confirm.
- If you reclaim a gap that had an open PR: let `chump claim` handle branch cleanup; it stamps the cooldown when it detects an existing PR for the gap. Do not manually delete branches without checking for associated open PRs first.
- The dedup gate (INFRA-1219) is the strongest protection: it fires synchronously at `pr create` time and blocks before a second PR exists.

## Auto-merge rollup-FAILURE trap (INFRA-1342, 2026-05-15)

GitHub's `statusCheckRollup.state` is set to `FAILURE` when **any** check on a
commit fails — including non-required checks. When rollup state is FAILURE,
`mergeable_state` flips to `blocked` and auto-merge silently refuses to fire,
even if every branch-protection required context (e.g. `test`, `audit`, `ACP
protocol smoke test`) reports SUCCESS.

**Symptom:** PRs sit with `BLOCKED auto=true`, all `*-required` checks green,
but GitHub won't merge. `gh pr view N --json mergeStateStatus` returns
`"BLOCKED"`. The only hint is that some non-required check has `FAILURE`.

**Root cause discovered:** `tauri-cowork-e2e` flakes with
`TimeoutError: Waiting for element to be located By(css selector, chump-chat)`
on slow GitHub Actions VMs when 18+ `type="module"` scripts delay
`DOMContentLoaded`. Even though `tauri-cowork-e2e` is not in branch protection,
its `FAILURE` conclusion pollutes the overall rollup state.

**Fix (INFRA-1342):** Add `continue-on-error: true` to any CI job that is:
- NOT in branch protection required contexts, AND
- Known to be flaky or environment-sensitive

GitHub treats `continue-on-error: true` jobs as `neutral` in the rollup
even on failure, so `statusCheckRollup.state` stays `SUCCESS`.

```yaml
  my-flaky-job:
    runs-on: ubuntu-latest
    continue-on-error: true   # ← prevents rollup FAILURE on flake
    steps:
      ...
```

**Jobs fixed in INFRA-1342** (all now have `continue-on-error: true`):
- `tauri-cowork-e2e` — Tauri WebDriver flake on slow VMs
- `e2e-pwa` — Ollama + Playwright, environment-sensitive
- `e2e-battle-sim` — lightweight but can time out
- `e2e-golden-path` — cargo build + file-presence checks

**Jobs fixed in INFRA-1348** (full audit of all non-required jobs):
- `changes` — `dorny/paths-filter` can fail transiently (network/runner issue); COE makes failure neutral so downstream jobs safely skip rather than blocking
- `test-e2e` — aggregates e2e shards (which already have COE); COE here guards against runner errors in the aggregator itself

## `chump-chat` selector confirmed NOT stale — it's an app-init timing/routing race (INFRA-1433 / INFRA-4301, 2026-09-04)

Definitive answer to the open question in INFRA-1433 ("dead selector, renamed
to `chat-room`? OR app fails to mount in CI's xvfb env?"): **the selector is
current, not renamed.** `customElements.define('chump-chat', ChumpChat)` still
lives at `web/v2/chat.js:417`, and `e2e-tauri/run.mjs:116` still waits on
`By.css('chump-chat')` — same string, both sides. Grepping `web/v2/` for
`chat-room` or any other candidate rename turns up nothing; there is no
renamed element to point the test at.

**Actual root cause: two competing initial-view mechanisms race on boot,**
and the outcome depends on script-execution order rather than a single
declared default:

1. `<chump-nav>` (`web/v2/app.js:456` `connectedCallback`) resolves an
   *initial cadence* (URL `?cadence=` > URL `?view=` map > `chumpPrefs`
   `last_cadence` > `'now'`) and, for the `'now'` cadence, its
   `default_view` is `'cockpit'` (`web/v2/app.js:378`) — **not** `'chat'`.
   It dispatches `chump:navigate` with `detail: 'cockpit'`
   (`web/v2/app.js:571`) synchronously from inside its `connectedCallback`,
   which fires the instant `customElements.define('chump-nav', ChumpNav)`
   runs (`web/v2/app.js:593`) and upgrades the already-parsed `<chump-nav>`
   element.
2. Separately, the `DOMContentLoaded` handler at `web/v2/app.js:5330`
   defaults to `'chat'` (`chumpPrefs.get('last-view', 'chat')`) and appends
   `VIEWS.chat()` (`<chump-view-chat>`, which mounts `<chump-chat>`) directly
   into `#main-content`.

The `document.addEventListener('chump:navigate', …)` router listener itself
isn't registered until `web/v2/app.js:5314` — **after** the `ChumpNav` class
body and its `customElements.define` call (line 593) earlier in the same
file. So step 1's synchronous `'cockpit'` dispatch fires into a
document with no listener yet attached and is silently dropped; step 2's
`DOMContentLoaded`-time append (which runs after all module scripts,
including the listener registration, have executed) is what actually lands
in `#main-content`. On a normal-speed machine this ordering is stable and
`<chump-chat>` does appear — which is why the flake reproduces on **slow**
CI VMs specifically (per the existing INFRA-1342 note on 18+ `type="module"`
scripts delaying `DOMContentLoaded`), not on every run: the race is between
"listener registration + `DOMContentLoaded` append" finishing, vs. anything
downstream (a stored `chumpPrefs.last-view` other than `'chat'`, a `?view=`
URL param, or the cadence nav's own default reasserting itself, e.g. via a
prefs write from a *previous* CI run's leftover `localStorage` state, or a
user-set cadence in local dev) resolving to a non-chat view before that
`DOMContentLoaded` append happens. **In a genuinely fresh browser profile
(no `localStorage`, no URL params) — which is what CI's xvfb session and
`tauri-driver` provide by default — `'chat'` wins and `<chump-chat>` mounts;
the flake class is state-carryover / ordering-sensitivity, not a missing
element.** This is consistent with `RESILIENT-016`'s decision to move
`tauri-cowork-e2e` off the PR-blocking path to nightly-only
(`.github/workflows/ci.yml:291`, `if: false` with a comment pointing at
`ci-nightly.yml`) rather than treating it as a hard app regression.

No selector rename is needed. If this class of flake resurfaces, the fix
belongs in the boot sequence (e.g. register the `chump:navigate` listener
*before* `customElements.define('chump-nav', …)` so the cadence nav's
initial dispatch isn't silently dropped, and make `'chat'` vs. `'cockpit'`
agree as the single source of truth for the default view) — not in the
e2e test's selector.

**INFRA-5211 re-verification (2026-09-07):** re-checked both AC items against
current `main` and both are already answered by the analysis above —
`customElements.define('chump-chat', ChumpChat)` (`web/v2/chat.js:417`) still
matches `By.css('chump-chat')` (`e2e-tauri/run.mjs:116`) verbatim, and
`tauri-cowork-e2e` is still `if: false` (PR-blocking disabled) per
`RESILIENT-016` (`.github/workflows/ci.yml:291-296`). The wait itself was
raised to `120_000` ms for the element-located step and `60_000` ms for the
shadow-root step in `e2e-tauri/run.mjs` (no longer a flat 60 s), consistent
with the timing-race diagnosis — not a missing/renamed selector. No new
repro was needed beyond what's captured above; see also INFRA-4636 (closed
not-a-bug for the sibling "update the selector" slice).

**INFRA-6338 root-cause pinpointed (2026-09-14):** live `ci-nightly.yml` run
`34817040814` confirmed the app *does* mount in xvfb — `#app-title` locates
in seconds, no fatal D-Bus/X11/WebKit error, only cosmetic AT-SPI/DRI3
warnings. `<chump-chat>` only exists in the DOM while the Chat sub-tab of the
"Now" cadence is active; since commit `f9a21b6d` (PRODUCT-132 / PR #2066,
2026-05-15) the "now" cadence's `default_view` is `'cockpit'`, not `'chat'`
(`web/v2/app.js:378`). `e2e-tauri/run.mjs` loads the app fresh and waits on
`chump-chat` without ever clicking the Chat sub-tab, so the wait times out
every run — silently broken since 2026-05-15. Fix (left as a follow-up,
not shipped here): have `e2e-tauri/run.mjs` click `[data-view="chat"]`
before waiting on `chump-chat`, mirroring `e2e/tests/api-and-pwa.spec.ts`'s
Playwright pattern. Full writeup:
`docs/audits/INFRA-6338-chump-chat-selector-investigation.md`.

**INFRA-6916 re-verification (2026-09-16):** re-checked against current
`main` two days after INFRA-6338 landed — no drift. `chump-chat` is still
defined at `web/v2/chat.js:417`, the "now" cadence's `default_view` is still
`'cockpit'` (`web/v2/app.js:378`), and `tauri-cowork-e2e` is still `if: false`
(`.github/workflows/ci.yml:296`). Separately, the same selector appears in
three Playwright specs (`e2e/tests/api-and-pwa.spec.ts`,
`e2e/tests/daily-driver-llm.spec.ts`) that never execute on the PR-blocking
path: the `PWA shell` / `PWA mobile viewport` / `Chat /task path` describe
blocks are gated behind `CHUMP_E2E_INCLUDE_FLAKES=1` (INFRA-1332 quarantine,
only set in the non-blocking `e2e-pwa-flakes` advisory job in
`integrations.yml`), and the LLM-reply test is gated behind
`CHUMP_E2E_LLM=1` (unset in CI). So the selector's absence from ordinary CI
logs has two independent, already-diagnosed causes — the Tauri/Selenium
timing race above, and these Playwright specs being intentionally skipped —
neither a rename nor a headless-mount failure. No code change needed; this
gap re-confirms INFRA-6338's diagnosis still holds.

**INFRA-7412 shipped the fix (2026-09-18):** `e2e-tauri/run.mjs` now clicks
`[data-view="chat"]` before waiting on `chump-chat` (`e2e-tauri/run.mjs:114-115`),
mirroring the Playwright specs. **INFRA-5525 re-verification (2026-09-25):**
re-checked all three AC branches (stale selector / app-init failure / missing
X11-D-Bus dep) — no drift, all still ruled out per the analysis above, and
confirmed the fix holds: live `ci-nightly.yml` run `36104297256`
(2026-09-25T06:45Z) shows `tauri-cowork-e2e` job-level `conclusion: success`.
Full writeup: `docs/audits/INFRA-5525-chump-chat-selector-investigation.md`.

**Ongoing enforcement:** `scripts/ci/test-rollup-not-blocked-by-flaky-job.sh` parses
`ci.yml` and asserts every non-required job has either `continue-on-error: true` or
a PR-trigger exclusion. Run it after any ci.yml change.

**When adding a new CI job:** if it is NOT in branch protection required contexts,
add `continue-on-error: true` to prevent it from blocking fleet-wide auto-merge.

**Workaround when already blocked:** Re-trigger the flaky check.
If it fails again: `gh pr merge <N> --squash --admin` to bypass.

### Known flaky tests (demoted, awaiting root-cause)

- **`e2e/tests/pwa-onboarding-consolidation.spec.ts` (INFRA-2128, 2026-05-29).**
  All 3 tests in this file are wrapped with `test.fixme()` because the suite
  flakes with `TimeoutError` in the required `e2e-pwa` check and was blocking
  orthogonal PRs (#2706, #2704, #2698). The functional regression this guards
  against (duplicate onboarding surface from INFRA-1585) is not actively
  breaking — the flake is in test machinery, not product. **Real fix needs a
  separate gap** to root-cause the `TimeoutError` (likely a `networkidle` vs.
  wizard-render race). Until then, treat as advisory.

## bot-merge.sh shadow ship-plan advisory stream (INFRA-1346, 2026-05-15)

`bot-merge.sh` emits a `ship_plan_advisory` ambient event at **main-flow entry**
(after GitHub probe + doctor preflight, before any mutations). It calls
`chump ship plan --branch <BRANCH> --gap <GAP> --json` with a 10-second timeout
and records the planner's recommended `action` field alongside the full plan JSON
(truncated to 2 KB).

**Purpose:** This is the pre-slice-4 validation channel for INFRA-1229. Operators
can grep `ship_plan_advisory` events from `ambient.jsonl` and compare the planner's
`plan_action` against the decisions bot-merge.sh actually made, surfacing divergences
before the full planner-driven loop ships.

**Query divergences:**
```bash
grep '"kind":"ship_plan_advisory"' .chump-locks/ambient.jsonl | python3 -c "
import json,sys
for line in sys.stdin:
    d=json.loads(line); print(d['ts'], d.get('branch','?'), d.get('plan_action','?'))
"
```

**Opt-out** (e.g. during GraphQL quota crunches to reduce gh API load):
```bash
CHUMP_BOT_MERGE_SHADOW_PLAN=0 scripts/coord/bot-merge.sh --gap INFRA-NNN --auto-merge
```

**Failure is silent:** if `chump ship plan` times out, is missing, or hits a rate
limit, bot-merge logs `ship-plan probe timed-out or failed` and continues normally.
The advisory event is simply not emitted that run.
## gap reserve + state.db drift → orphan-PR-closer kills in-flight work (INFRA-1354, 2026-05-15)

**Incident:** On 2026-05-15, two `chump gap reserve` calls wrote gap YAMLs only
into local `state.db`. The orphan-PR-closer job (which detects PRs whose gap
YAML is absent from `main`) killed PR #2063 (~840 LOC of work) and two other
in-flight PRs. Recovery required two rescue PRs (#2071, #2077) just to staple
the YAMLs into `main`.

**Root cause:** `chump gap reserve` already wrote `docs/gaps/<ID>.yaml` and
called `git add` on it (INFRA-484). But in one path the `git add` silently
failed (ran in a context where `worktree_root` wasn't the linked worktree's
CWD), so the YAML rode in `state.db` only and never reached `origin/main`.
Any PR filed from a different worktree (or any fleet worker picking the gap
after the PR) would find the YAML absent and the orphan-closer would kill the
PR.

**Fix (INFRA-1354):**
- `git add` now checks its exit code; on failure it prints a visible warning:
  `[reserve] warning: git add … exited …; yaml is written but unstaged —
  commit manually to avoid orphan-PR-closer killing in-flight PRs`
- The warning surfaces in normal (non-`--quiet`) reserve output so operators
  see it before filing a PR.
- `CHUMP_RESERVE_NO_AUTOSTAGE=1` remains available to disable staging in
  genuine detached / read-only workflows.

**What to do when you see the warning:**
```bash
git add docs/gaps/<ID>.yaml
git commit -m "chore: stage <ID>.yaml (missed by reserve auto-stage)"
```
File that commit on your branch before the PR is created, or the orphan-closer
may kill the PR within minutes of merge.

**Smoke test:** `scripts/ci/test-gap-reserve-auto-stages.sh`
## Secondary-mutation gag — per-user GitHub rate-limit exhaustion (INFRA-1076, 2026-05-14)

**Symptom:** `gh pr merge --auto` and `gh pr update-branch` silently 429
for 1–3 hours, even though the personal quota (`gh api rate_limit` →
`resources.core.remaining`) looks fine. PRs with all checks green don't merge.

**Root cause:** GitHub enforces a separate **secondary rate limit** on write/mutation
operations (PR merges, label edits, update-branch, etc.). This limit is per-user
and shared across all uses of the same OAuth token or personal access token.
When a background sweep (label-edit loop, overlap scan, auto-update-branch on
50 PRs) saturates the secondary limit, ship-blocking merges queue behind it
for the entire reset window (typically 1–3 hours).

**Evidence (2026-05-14):** A label-edit sweep consumed the mutation budget.
12 auto-armed PRs with green CI sat unmerged for ~2 hours. No error message —
`gh pr merge` appeared to succeed (exit 0) but the PR stayed open.

**Structural fix (INFRA-1076):** Use two separate GitHub App installations —
`chump-critical` for ship-blocking operations, `chump-background` for sweeps.
Each App installation has its own secondary rate-limit counter.

Setup: **[`docs/process/OPERATOR_RUNBOOK.md` — INFRA-1076 section](OPERATOR_RUNBOOK.md)**

**Immediate workaround (before App installations are set up):**
```bash
# Identify the noisy caller
scripts/dev/api-cost-leaderboard.sh --window 1h

# Tag it as background so critical ops get priority
CHUMP_GH_CALL_CRITICALITY=background <noisy-command>

# Check remaining secondary limit (no official API — watch for 429 headers)
# If gag'd, wait it out or switch to a different personal access token
```

**Call-criticality tagging:** see `CLAUDE.md § Call criticality (INFRA-1080)`.

## Tangled-stack rebase recipe (INFRA-1660, 2026-05-21)

When a PR has been open for hours through multiple sibling-PR merges and a
straight `git rebase origin/main` produces a wall of cross-file conflicts
that aren't really conflicts (sibling PRs touched the same main-state files
you also touched, but the changes ARE the right answer in main now), don't
fight the rebase. Use the soft-reset recipe:

```bash
cd /tmp/chump-<gap>  # PR worktree, NOT main checkout
git fetch origin main --quiet
git rebase --abort 2>/dev/null  # if mid-rebase
git reset --soft origin/main    # one commit "ahead" containing your real changes

# Inspect what's staged. Anything that's "main-state churn you don't own"
# should be restored from main:
git status --short
git checkout origin/main -- <files-other-PRs-modified>

# Verify staged diff is ONLY your PR's intent:
git diff --staged --stat

# Single-commit force-push:
git commit -m "feat(GAP-ID): <single-line intent>"
git push --force-with-lease
```

**When to use:**
- PR has 4+ commits including fmt-drift / sibling-cherry-picks / retries
- `git rebase origin/main` reports conflicts in files YOU touched but main's
  version is now the canonical answer (because a sibling PR already
  reconciled them)

**When NOT to use:**
- Routine 2-commit rebase — `git rebase origin/main` is fine
- Conflicts in your own NEW code — those need real review, not a reset
- When you have unpushed commits you actually want to keep separately

**Risk:** `reset --soft` flattens commit history, losing per-commit
attribution. Acceptable because PRs squash-merge anyway, but be deliberate
about the single commit message. Don't lose meaningful context in the
rollup.

Discovered during 2026-05-20 Marcus cron-loop session, used 4× in one
afternoon to unblock #2296/#2297/#2298/#2303/#2304 after the sibling-PR
merge cascade.

## `printf … | grep -q` pipefail race (INFRA-755 / INFRA-1658, 2026-05-21)

Under `set -o pipefail`, this idiom is racy and produces false-negative
matches that fail loudly elsewhere:

```bash
# BUG — under pipefail, the pipeline can exit non-zero EVEN ON A MATCH
if printf '%s\n' "$LINES" | grep -qE "pattern"; then
    HIT=1
fi
```

**Why:** `grep -q` closes stdin as soon as it finds the first match. If
`printf` is still writing when grep closes, printf gets `SIGPIPE` and
exits non-zero. With `pipefail`, the whole pipeline reports failure even
though grep DID find the pattern. The `if` branch silently skips.

**Symptom:** obs-budget script claimed no observability hooks were
present in a diff that contained them. Six hours of false-negative
debugging before locating the race.

**Fix — materialize to a tempfile, then grep:**

```bash
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$LINES" > "$TMP"
if grep -qE "pattern" "$TMP"; then
    HIT=1
fi
```

**Audit gap:** INFRA-1658 sweeps `scripts/` for sibling occurrences.
Hot-path scripts (`scripts/coord/`, `scripts/dispatch/`,
`scripts/git-hooks/`) are most likely to be affected because they run
per-PR and per-cycle.

**Ongoing enforcement:** `scripts/ci/test-pipefail-race-sweep.sh` (added
in INFRA-1658) re-greps those three hot-path directories on every CI
run and fails the PR if a new `printf … | grep -q …` occurrence
appears. Intentional exceptions (script doesn't set `pipefail`, or
producer is a one-line literal) are allowlisted by appending
`# pipefail-sweep-allowed` to the same line.

**Tell-tale signature in code review:** any `printf` (or `echo`) piped
into `grep -q`, `awk` with early-exit, `head -1`, etc., under a
`pipefail`-enabled shell.

## Ambient emit helper naming — `_emit` vs `EMIT_KIND` (INFRA-1659, 2026-05-21)

`scripts/ci/test-event-registry-coverage.sh` scans production paths for
emit sites and verifies each registered kind has a matching emit. The
scanner has 8 grep patterns; Pattern 4 matches lowercase `_emit "name"`
shell helpers, Pattern 8 matches uppercase `EMIT_KIND "name"` shell
helpers.

**Convention:**
- ✅ `_emit "kind_name" '{"...":...}'` — Pattern 4 matches
- ✅ `EMIT_KIND "kind_name" '{"...":...}'` — Pattern 8 matches
  (shipped in INFRA-1659)
- ❌ Any other casing (`emit_kind`, `Emit`, mixed) — invisible to scanner

**Symptom:** registered kinds show as `register-without-emit (orphans)`
in the audit job, even though the emit site exists. Audit FAILS in
`strict` mode; the PR is BLOCKED until you rename or add to
`scripts/ci/event-registry-reserved.txt`.

**Fastest fix:** rename helper to `_emit` or `EMIT_KIND` (one-line sed).
Adding to the reserved list works but accumulates lint debt.

**Pattern 8 add-on:** ✅ shipped in INFRA-1659 — `EMIT_KIND` (uppercase)
is now valid alongside `_emit` (lowercase). Avoid any other casings.

## Cron-loop `claude` subprocess leak (INFRA-1662, 2026-05-22)

Long-running autonomous loops (`/loop`, `ScheduleWakeup` cycles,
`CronCreate` schedules) spawn a fresh Claude Code subprocess on every
firing. The harness historically does **not** waitpid the child between
firings — leaked subprocesses pin RAM and CPU.

**Empirical:** the 2026-05-20→22 Marcus cron-loop (job `6249a56f`, fired
every ~12 min for ~60 hours) leaked **354 wedged `claude` subprocesses**
pinning **8.5 GB RAM** and pushing 1-min load avg to **262** on an
M-series Mac. SIGTERM didn't reach them (wedged); SIGKILL required.

**Symptom:** Mac becomes unresponsive after 24–48 h of autonomous-loop
operation. Cursor lags, terminal stalls, Spotlight freezes.

**Diagnose:**
```bash
ps -A | grep -c "claude --output-format"    # should be < 5; >100 = leak
ps -Ao rss,comm | awk '/claude --output/{sum+=$1} END {printf "%.1fGB\n", sum/1024/1024}'
uptime                                       # load > 50 on M-series = bad
```

**Manual reap (preserve current session):**
```bash
MY=$$; CHAIN=""
p=$MY; while [[ "$p" != "1" ]]; do CHAIN="$CHAIN $p"; p=$(ps -o ppid= -p $p | tr -d ' '); done
ps -Ao pid,comm | awk '/claude --output-format/{print $1}' \
  | grep -vxFf <(echo "$CHAIN" | tr ' ' '\n') \
  | xargs kill -9
```

**Prevention (tracking):** INFRA-1662 will add a launchd watchdog that
reaps `claude` binaries older than 1 h whose ppid chain doesn't lead
to the foreground Claude.app. Until that ships, **manually reap before
starting any new autonomous loop** if you've been running one for >24 h.

## What happens when fg_pid detection fails (INFRA-1786, 2026-05-23)

`scripts/ops/reap-orphan-claude-procs.sh` uses a three-probe strategy to find the foreground Claude.app PID (pgrep → ps|awk → launchctl). If all three probes return empty **and** `CHUMP_REAPER_HEADLESS` is not set to `1`, the script refuses to operate and exits with code 3, printing `"fg_pid=none on macOS without CHUMP_REAPER_HEADLESS=1 — refusing to reap everything"` to stderr. It also emits `kind=reaper_safety_gate_triggered` to `ambient.jsonl`. This prevents the reaper from mass-killing active fleet workers on a developer workstation when the GUI app is running but the PID lookup fails. To restore the old reap-everything behaviour in CI or headless environments, set `CHUMP_REAPER_HEADLESS=1`.

## Stale-process classes to watch (INFRA-1663, 2026-05-22)

Beyond the `claude` leak, the 2026-05-22 cleanup found two other
classes of leaked workers — same root cause (parent died, child kept
running), different signature:

| Class | Expected lifetime | Symptom of stale |
|---|---|---|
| `rustc` | ≤ 10 min | etime > 1 h |
| `cargo` | ≤ 15 min | etime > 1 h |
| `chump health --slo-check` | ≤ 2 min | etime > 30 min |
| `worker.sh` | ≤ 4 h | etime > 8 h |
| `bot-merge.sh` | ≤ 20 min | etime > 1 h |

**Empirical (2026-05-22 cleanup):** 5 `rustc` processes alive 1.5 days
(legacy worker cargo builds whose parent died), 2 `chump health` alive
11+ hours.

**Diagnose:**
```bash
ps -Ao pid,etime,comm | awk '$3 ~ /rustc|cargo|chump|worker\.sh|bot-merge/' \
  | awk '$2 ~ /-/'   # any process with day-level elapsed time
```

**Prevention (tracking):** INFRA-1663 — daily launchd cron with an
expected-lifetime table; SIGKILL stale entries + emit
`kind=stale_process_reaped`. Until then, run the diagnose snippet
weekly during high-throughput periods.

## SessionStart digest false-positive on INFRA-1149 (INFRA-1664, 2026-05-22 — FIXED)

**Status:** fixed in INFRA-1664. Historical context preserved below
because the symptom may resurface if any new lease-enumeration code
path is added without filtering by the `claim-*.json` prefix.

The FLEET-019 SessionStart + PreToolUse ambient-digest hooks used to
report **"47 active sibling leases" with 37× INFRA-1149**. This was
always a false positive: there were 0 actual gap-claim leases — the
parser was matching the `gap_id` substring inside curator-filed
markers.

**Original cause:** the digest parser (in
`scripts/coord/ambient-context-inject.sh`) globbed every
`.chump-locks/*.json`, but the META-065 curator daemon writes
`curator-filed-*.json` idempotence markers that reference INFRA-1149
(the gap that built the duplicate-detection system) in their content.
The grep matched the substring, not the real `claim-*.json` lease
file convention.

**Fix (INFRA-1664):** the lease enumeration now globs
`claim-*.json` only. Curator-filed markers, bot-merge step files, and
any other `.chump-locks/*.json` are skipped. Real gap-claim leases use
the `claim-<gap-id>-<pid>-<unix-ts>.json` naming convention emitted by
`chump claim`.

**Diagnose (if you ever see >0 phantom leases again):**
```bash
ls .chump-locks/claim-*.json 2>/dev/null | wc -l   # real lease count
ls .chump-locks/curator-filed-*.json | wc -l       # curator markers (noise; should be ignored)
```

If real lease count is 0 but the digest reports leases, regression —
re-open as a follow-up to INFRA-1664.

## Conflict-resolver in bot-merge.sh (INFRA-1488 + INFRA-1657)

`scripts/coord/bot-merge.sh` invokes `scripts/coord/conflict-resolver-agent.sh`
when `git rebase origin/main` exits non-zero with unmerged paths in the
worktree. The agent is **default-OFF** and opt-in via env flag.

**Enable (per-operator or per-fleet):**
```bash
export CHUMP_CONFLICT_RESOLVER_ENABLED=1   # opt in
export CHUMP_CONFLICT_RETRIES=2            # default; bumps reattempts
```

**Behavior matrix:**

| Flag | Rebase result | What bot-merge does |
|---|---|---|
| unset / `0` | conflict | agent self-skips (exit 0); bot-merge falls through to existing handoff (`_bm_fail "rebase" 11`) |
| `1` | conflict, agent resolves | agent runs `git rebase --continue`; bot-merge resumes normal flow |
| `1` | conflict, agent hands off | agent writes `.chump-locks/operator-action-needed.json`; bot-merge runs `git rebase --abort` + exits 11 |

**Rollback:**
```bash
unset CHUMP_CONFLICT_RESOLVER_ENABLED      # back to manual-resolve default
```

**Audit trail:** `kind=conflict_resolve_*` events in `ambient.jsonl`
(`_start`, `_validated`, `_success`, `_dropped`, `_attempt_failed`,
`_continue_failed`, `_handoff`, `_skipped`, `_failed`).

## Skill management — `chump skill` (INFRA-1613)

Skills are reusable task procedures stored in `chump-brain/skills/<name>/SKILL.md`.
The `chump skill` CLI exposes the full skill lifecycle without requiring an agent session.

**Commands:**
```bash
chump skill list [--json]                  # enumerate installed skills
chump skill view NAME                      # show full SKILL.md content + reliability
chump skill health [--name N] [--min-uses N]  # Wilson CI ranking (composite score)
chump skill record-outcome NAME true|false # record a success/failure outcome
chump skill tap-add URL                    # install skills from a GitHub repo
```

**Brain directory:** `chump-brain/skills/<name>/SKILL.md` (override: `CHUMP_BRAIN_PATH`).
Each subdirectory must contain a `SKILL.md` with valid YAML frontmatter + the five
required sections (`## When to Use`, `## Quick Reference`, `## Procedure`, `## Pitfalls`,
`## Verification`).

**Reliability stats** come from the `chump_skills` SQLite table (`skill_db.rs`).
`chump skill health` uses Wilson 95% CI + recency decay + use-count weight (see
`src/skill_metrics.rs::skill_health_ranking()`) to produce a composite ranking.

**Agent-facing API** (`skill_manage` tool in `src/skill_tool.rs`) is the write path
used during agent sessions; `chump skill` is the operator-facing read/inspect path.

## Silent-fleet-death class — how to detect + recover (INFRA-2040, 2026-05-27)

**What it is.** The fleet can die silently when two conditions combine:

1. The operator's main checkout is on a stale branch (Sprint N scripts exist in `origin/main` but NOT in the working tree that launchd daemons point at).
2. One or more `com.chump.*` / `dev.chump.*` launchd daemons exit 127 ("command not found") on every tick because the script they reference doesn't exist in the stale checkout.

The dangerous part: per-daemon metrics look individually fine (each daemon ran, each daemon exited), so `fleet-brief.sh` used to say "fleet looks healthy" while 0 ships occurred for 24h.

**New detection (INFRA-2040).** Both `chump fleet doctor` and `fleet-brief.sh` now carry a check:

- **Check condition:** last merge into `origin/main` is `>= SILENT_DEATH_MERGE_HOURS` (default 12h) old **AND** at least one `com/dev.chump.*` daemon has `last exit code != 0`.
- **Both conditions required.** Either alone is only advisory — a stale branch with healthy daemons means "slow fleet, not dead"; a daemon crash with a fresh merge is a transient failure.
- **Emit:** `kind=silent_fleet_death` → `ambient.jsonl` with `merge_age_h`, `dead_daemon_count`, `dead_daemons`.
- **Banner:** fleet-brief prints `*** ALERT: SILENT-FLEET-DEATH — last merge Nh ago + K daemon(s) dead: <labels> ***` in red.

**How to recover.**

```bash
# 1. Confirm which branch your main checkout is on:
git -C /Users/jeffadkins/Projects/Chump branch --show-current

# 2. If stale, switch to main and pull:
git -C /Users/jeffadkins/Projects/Chump checkout main
git -C /Users/jeffadkins/Projects/Chump pull origin main

# 3. Restart dead daemons:
launchctl list | grep -E '(com|dev)\.chump\.'
launchctl kickstart -k "gui/$(id -u)/com.chump.<label>"

# 4. Verify daemons are running:
launchctl print "gui/$(id -u)/com.chump.<label>" | grep "last exit code"

# 5. Confirm fleet-doctor now passes:
bash scripts/coord/fleet-doctor-strict.sh --verbose
```

**Optional auto-heal (operator opt-in).**
Set `CHUMP_DOCTOR_AUTOHEAL=1` before running `chump fleet doctor`. For each daemon with exit=127, the doctor checks if the daemon's script exists in `origin/main`; if missing locally but present upstream, it restores via `git checkout origin/main -- <script>` and bounces the daemon via `launchctl kickstart`. Each heal emits `kind=silent_fleet_death_autohealed`.

**Tunable threshold.** `SILENT_DEATH_MERGE_HOURS` (default 12) — set lower (e.g. 4) for tighter monitoring, higher to suppress in expected-quiescence windows.

**CI smoke test:** `scripts/ci/test-silent-fleet-death.sh` — stubs a 20h-old-merge + exit=127 daemon and asserts the `silent_fleet_death` emit + ALERT.

## Local CI discipline — `chump preflight` (INFRA-1670, INFRA-1672, INFRA-1673)

Before pushing, run `chump preflight` to mirror CI locally and skip the
~15-minute round-trip on dumb failures (fmt drift, clippy regressions, the
cheap registry-coverage gates). Bypass via `CHUMP_PREFLIGHT_SKIP=1` plus a
`Preflight-Skip-Reason: <why>` trailer in the commit body (audit-logged).

**Scope flag (INFRA-1672)** — `chump preflight --scope <auto|all|rust|scripts|docs>`
runs only the gate buckets relevant to the staged diff:

- `chump preflight --scope docs` for doc-only PRs (~5s — no cargo at all)
- `chump preflight --scope scripts` for shell/ci.yml-only PRs (~15s)
- `chump preflight --scope rust` for code-only PRs (~60s warm cargo)
- `chump preflight --scope all` for paranoia / pre-release sweeps
- `chump preflight` (no flag) auto-detects from `git diff --cached --name-only`

Auto-scoping mirrors the `changes:` path-filter section of
`.github/workflows/ci.yml`. Unrecognized paths fall back to `--scope all`
so we never ship a regression because an exotic path was misclassified.

## GitHub Actions: warnings vs errors in annotations (INFRA-1896, 2026-06-21)

**The trap:** emitting `::warning` annotations via a GitHub Actions workflow step can cause the *job* to conclude with FAILURE even when all steps exit successfully — if the step that emits annotations uses `set -e` (strict error checking) and a command fails silently.

**Why it happens:**

GitHub Actions shell steps use `bash -e` by default, which exits on any non-zero status. When you emit annotations by parsing JSON and extracting fields, a malformed JSON object or missing key can cause the parsing command to fail. Example:

```bash
# This fails if JSON is malformed or "title" key missing:
title=$(echo "$line" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["title"])')
echo "::warning title=Check::${title}"
```

If any line in the input is invalid JSON, the Python command fails with non-zero exit. Since the step runs with `set -e`, the **entire step fails**, which causes the **job to fail** — even though warnings alone should never fail a job.

**The fix (three techniques):**

**1. Wrap annotation parsing in a dedicated Python script** (preferred for robustness):

```bash
python3 - <input-file> <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                title = obj.get("title", "Unknown")
                evidence = "; ".join(obj.get("evidence", []))
                print(f"::warning title=Check::{title} ({evidence})")
            except (json.JSONDecodeError, KeyError, ValueError) as e:
                print(f"::debug::Skipped malformed line: {e}", file=sys.stderr)
except Exception as e:
    print(f"::error::Failed to parse: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
```

The key: use try-except blocks to catch parsing errors without failing the entire step.

**2. Use `set +e` before the annotation loop** (simpler but less clean):

```bash
set +e
while IFS= read -r line; do
    title=$(echo "$line" | jq -r .title)
    echo "::warning title=Check::${title}"
done < findings.jsonl
exit_code=$?
set -e
exit $exit_code
```

**3. Use `jq` instead of Python** (if available and parsing is simple):

```bash
jq -r '.title + " (" + (.evidence | join("; ")) + ")"' findings.jsonl | \
    while IFS= read -r line; do
        echo "::warning title=Check::${line}"
    done
```

**Testing (INFRA-1896):**

Run `scripts/ci/test-repo-health-warnings-only.sh` — it verifies that:
1. The annotation parser handles malformed JSON gracefully
2. Warnings-only steps exit with status 0 (success)
3. Empty or invalid findings don't cause step failure

**In repo-health.yml:** the "Annotate findings" step now uses technique 1 (dedicated Python with exception handling) so that `::warning` annotations are emitted without causing job failure, fixing the false-positive PR blocks that occurred when pre-existing repo state (e.g., broken md-links) was flagged as warnings.

## Claude Code hook output channels — PreToolUse vs PostToolUse (INFRA-2043, 2026-05-27)

Claude Code hook types have **different stdout routing**:

| Hook type | stdout fate | Use for |
|---|---|---|
| `PreToolUse` | **Injected into next-tool context** as `<system-reminder>` | Live A2A interrupts, urgent inbox, any message that must reach the mid-session agent |
| `PostToolUse` | **Suppressed** — discarded after the tool call completes | Audit-only fire-and-forget (ambient emit, session-keyed digest append) |
| `SessionStart` | **Injected into session digest** at startup | Session-scoped state (inbox digest, lease list, ambient glance) |

**Consequence for A2A delivery (INFRA-2016 + INFRA-2043):**

`inbox-check-urgent.sh` was originally wired as a `PostToolUse` hook. The hook fired
correctly, emitted `inbox_urgent_surfaced` audit events, and advanced the cursor — but
agents never saw the URGENT message because PostToolUse stdout is suppressed.

Fix: move `inbox-check-urgent.sh` to `PreToolUse` so its `<system-reminder>` XML is
injected as additional context for the very next tool call. `inbox-poll.sh` remains in
`PostToolUse` because it only appends to the next session's digest (session-keyed, not
mid-session).

**Rule of thumb for future hooks:**
- Need the agent to act on something *right now*? → `PreToolUse`
- Just logging / updating state for later? → `PostToolUse` or `async: true`
- Session-wide setup (lease info, inbox digest)? → `SessionStart`

This is consistent with META-061 (NATS-primary delivery, file-fallback secondary):
file-based urgent delivery uses `PreToolUse` for today's path; NATS-primary
(INFRA-1118+) is the future path where delivery is push-based and timing is exact.

## When to admin-merge — noise-class discipline (RESILIENT-031, 2026-05-27)

Admin-merge (dropping `required_status_checks` to force-merge a PR) is a **last resort**.
The wrapper `scripts/ops/admin-merge-cycle.sh` enforces the discipline mechanically.

### The rule

You **must** declare which known noise pattern justifies the bypass:

```bash
scripts/ops/admin-merge-cycle.sh --pr <N> --noise-class <id>
```

The script:
1. Looks up `<id>` in `scripts/ops/known-noise-classes.yaml`
2. Fetches actual failing check names via `gh pr checks <N>`
3. Compares failing checks against the class's `matches` list and `pattern` regex
4. **If they match** → proceeds with drop → merge → restore
5. **If they don't match** → REFUSES with an explanation and exits non-zero

### Emergency bypass

When genuinely urgent and no matching class exists, use `--force-admin`:

```bash
scripts/ops/admin-merge-cycle.sh --pr <N> --force-admin --reason "short explanation"
```

This bypasses the class check but **requires** `--reason` and emits
`kind=admin_merge_forced` to `ambient.jsonl` for the audit log.
Repeated `admin_merge_forced` events signal the class list is stale.

### When a class auto-expires

If a class has `expires_after_ship: true` and its `upstream_fix_gap` reaches
status `done`, the class is **automatically invalidated** — the script refuses to
use it and prints:

```
REFUSE: noise class 'X' is EXPIRED. Upstream fix gap Y is done.
This noise should no longer occur. If it does, file a regression gap.
```

This prevents stale bypasses from surviving long after the root cause is fixed.

### Adding a new noise class

1. Edit `scripts/ops/known-noise-classes.yaml`, add an entry with:
   - `id` — unique slug (e.g. `runner-saturation-stall`)
   - `description` — why this noise occurs
   - `matches` — list of substrings found in failing check names (case-insensitive)
   - `pattern` — Python regex as fallback (use `""` if not needed)
   - `upstream_fix_gap` — gap ID that will eliminate the noise (or `null` for infra)
   - `expires_after_ship` — `true` if the gap fix should retire this class; `false` for permanent infra noise
2. Commit the YAML edit in the same PR as the code that first uses the class.
3. List active classes anytime: `scripts/ops/admin-merge-cycle.sh --list-classes`

### Why this matters

On 2026-05-27, 7 admin-merge cycles ran for the same wedge (INFRA-2044
docs-delta-trailer test broken). Each was individually justified, but one cycle
was premature (no failing checks yet — only pending). The counter-measure:
the script now REFUSES if no checks are actually failing, preventing premature
bypasses that mask CI state.

## Stale-source false-positives (DOC-059 / META-114)

> Don't trust local `ls` for "file missing" claims. See [FRESHNESS_DISCIPLINE.md](FRESHNESS_DISCIPLINE.md).

**Symptom**: shell `ls path/to/X` returns 1, you conclude the file is missing.

**Real cause**: your local checkout is N commits behind `origin/main` and the file was added by a merged PR you don't yet have.

**Fix**: `git ls-tree origin/main path/to/X` OR the [`verify-existence`](../../.claude/skills/verify-existence/SKILL.md) skill. Pull main to rehydrate locally.

**Precedent class**: 2026-05-27 shepherd + wizard both filed/considered "X is missing" gaps for files that existed on `origin/main` (local trees 48-63 commits behind). Two stale curators agreeing on missing-X is still both being wrong.

**Discipline**: `bash scripts/coord/freshness-preamble.sh` (META-115) classifies session-start state into FRESH / STALE / CRITICAL_STALE. Chain `freshness-gate.sh && chump claim ...` to refuse MUTATE-class ops on stale source. Full anti-pattern catalog + decision rules in [FRESHNESS_DISCIPLINE.md](FRESHNESS_DISCIPLINE.md).

**Related staleness layers** — same doc covers state.db ↔ YAML drift (`chump gap sync`, INFRA-2053), chump binary drift (`chump --rebuild-if-stale`, INFRA-2054), launchd plist drift (`chump cron health`, INFRA-2046).

**Session-bound vs fleet-durable scheduling** — if a CronCreate or ScheduleWakeup is dying at session close when it should persist, you have a layer mismatch. See [`docs/process/SCHEDULING_LAYERS.md`](./SCHEDULING_LAYERS.md) for the decision rule, anti-pattern catalog, and migration guide (DOC-058).

## Rust test flakes (INFRA-2152, 2026-08-14)

**Symptom**: `cargo test` panics intermittently on a NATS-backed integration test (e.g. `chump-coord::ambient_distribution::emit_round_trips_to_subscriber`) with "did not observe published event within 5s" or similar, but passes on rerun.

**Real cause**: `nats.subscribe()` returns as soon as the SUB frame is *sent*, not once the server has registered it. A `publish()` issued immediately after can race the SUB frame server-side and the event is silently dropped — no error, just a timeout on the subscriber side.

**Fix**: call `.flush().await` on the subscribing client right after `subscribe()`, before doing anything that depends on the subscription being live. `flush()` forces a round-trip to the server, so by the time it returns the subscription is guaranteed registered. See `crates/chump-coord/tests/ambient_distribution.rs`.

**Related — stale test referencing removed functionality**: `chump-gap-store::tests::test_reserve_skips_yaml_drift` was reported failing in the same gap but no longer exists in the tree — it was removed in #2727 (INFRA-2177, "drop docs/gaps YAML rollup from gap reserve — use state.db only") along with the functionality it tested. Before debugging a named test failure, `grep` for the test function first — if it's gone, the report is stale and the fix is a no-op.
