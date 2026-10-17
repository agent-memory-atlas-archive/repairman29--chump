---
doc_tag: process-playbook
audience: shepherd, ci-audit, handoff, target curators; any operator running /loop
purpose: Distilled tooling + decision-flow for shipping PRs through the queue. Captures the wedge taxonomy, ship-assist tooling inventory, and reliability lessons from the 2026-05-29 operator loop session that ran 17 cycles, shipped 7 PRs, and uncovered 7 distinct wedge classes.
status: v1 (2026-05-29) — operator-reviewed
last_audited: 2026-05-29
---

# Ship-Assist Playbook

> **Why this doc exists.** Today's loop session (2026-05-29) ran 17 cycles, queued 40 PRs at peak, drained back to 33 + 7 mine landed on main. Along the way it surfaced 7 distinct wedge classes that each blocked real ships, and demonstrated which tools work / which silently wedge / which don't exist yet. Future shepherds shouldn't re-discover all of this from scratch.

## 1. Wedge taxonomy (7 classes from today's incident chain)

Each class names the failure mode, the symptom you'll see, and the surgical fix shape. Pattern-14 evidence required before any "queue wedged" broadcast — never sound the alarm without rollup-level data from the failing PR.

### Class 1 — `fmt-drift` on main (queue-wide fast-checks wedge)
**Symptom.** Every Rust PR fails `fast-checks` with `cargo fmt --check` flagging files the PR didn't touch. The failure pattern is identical across PRs — they all inherit the same dirty state from main.
**Detection.** Drill into any failing `fast-checks` job log: look for `Diff in /path/to/file.rs:LINE`. If multiple PRs show the same diff list against files outside their own changeset, main has fmt drift.
**Fix.** Reserve a `fmt-sweep` gap, claim, `cargo fmt --all` in a clean worktree, commit, ship as P0/xs single-file PR. Auto-merge fires once it lands. Today's evidence: INFRA-2216 / PR #2782.
**Prevention.** `chump preflight` (INFRA-1670) catches before push; INFRA-2120 preflight-vs-CI parity ensures the gate exists locally. If both pass and CI still fails, that's a parity bug — file accordingly.

### Class 2 — `raw-gh-allowlist-miss` (queue-wide audit wedge)
**Symptom.** Every PR fails `audit` job on step `raw-gh lint gate — no new direct gh calls in hot-path scripts outside lib/ (INFRA-1274)`. Locally reproducible via `bash scripts/ci/test-no-raw-gh-in-hot-paths.sh`.
**Detection.** Drill into the audit job log → find the line `[raw-gh-lint] FAIL: ... scripts/path/foo.sh:LINE: gh pr list \`. That script needs to be in `scripts/ci/raw-gh-allowlist.txt` with a migration-gap reference.
**Fix.** One-line append to `raw-gh-allowlist.txt` with `# INFRA-NNNN: <reason>` comment. P0/xs ship. Today's evidence: INFRA-2218 / PR #2784.
**Prevention.** Pre-merge gate that flags new `scripts/ops|coord|dispatch/*.sh` files with raw gh calls — already in `test-no-raw-gh-in-hot-paths.sh`; tighten when a script lands without allowlist sibling.

### Class 3 — `sccache-R2-pair-mismatch` (queue-wide Rust wedge)
**Symptom.** Every Rust CI job (cargo-test, coverage, fast-checks via embedded pre-push gate) fails with `sccache: error: Server startup failed: cache storage failed to read: ... S3Error { code: "Unauthorized" }` followed by `cargo metadata exit 101`.
**Detection.** Two-step Pattern-14 evidence:
1. `gh secret list -R repairman29/chump | grep R2_` — confirm timestamps of `R2_ACCESS_KEY_ID`, `R2_ACCOUNT_ID`, `R2_SECRET_ACCESS_KEY`. If they don't all share a recent timestamp (within minutes), the key+secret pair was half-rotated.
2. If timestamps look fine, the Cloudflare-side token may have been revoked OR the pasted value has a typo. Cloudflare R2 access key IDs are 32-char hex; secret access keys are 64-char hex. Length-mismatch = invalid value.
**Fix (primary, daily-driver).** `bash scripts/ops/rotate-sccache-r2-gh-only.sh --execute` after dropping new pair values into `~/.chump/r2-new-token.txt`. Atomic GH-secret update; INFRA-2240, shipped today.
**Fix (advanced backup).** `bash scripts/ops/rotate-sccache-r2-token.sh --execute` — also automates the CF dashboard regen via the CF API. Requires `CHUMP_CF_API_TOKEN` with `User API Tokens: Edit` scope. INFRA-2237, shipped today.
**Operator note.** R2 tokens are issued as a PAIR. If you regenerate, both halves get new strings — update BOTH in GH Secrets in one sitting. Half-rotation = 90 min queue wedge (today's incident).
**Prevention.** None at the GH layer today; CI step that verifies sccache health post-install before any cargo invocation would catch this — see INFRA-2184-class pattern.

### Class 4 — `bot-merge.sh` silent wedge
**Symptom.** `bot-merge.sh --gap X --auto-merge` runs >4 minutes with zero stdout/stderr output. Background task shows process is alive (PID in `S` state) but no network activity, no progress markers.
**Detection.** Watch the output file (`tasks/<id>.output`); if empty after 4 min, it's wedged.
**Fix.** Kill bot-merge processes, manual recovery:
```bash
git push -u origin <branch> --force-with-lease   # may need CHUMP_BYPASS_BOT_MERGE=1 + Bot-Merge-Bypass trailer
gh pr create --base main --head <branch> --title ... --body ...
gh pr merge <N> --auto --squash
rm -f .chump-locks/claim-<gap>-*.json
```
Today's evidence: 3 occurrences (cycle 5, 6, 13 of today's loop). Trailer `Bot-Merge-Bypass: <reason>` in commit body documents intentional bypass for audit.
**Prevention.** `INFRA-1399` (bot-merge stall detection) — filed, not shipped. Wall-clock progress monitor with auto-bail after 5 min no-output would save ~15-20 min per wedge.

### Class 5 — Sonnet sub-agent stalls mid-task (~600s no progress)
**Symptom.** Sonnet sub-agent dispatched via Agent tool stops emitting tool calls after a long stretch — typically while debugging a smoke test or working through a complex AC. Stream watchdog kills it.
**Detection.** Task notification with `<status>failed</status>` and `Agent stalled: no progress for 600s`.
**Fix.** If the Sonnet had a worktree with uncommitted progress, **do NOT use `chump claim --force-recover`** to re-claim (Class 6 below). Instead:
1. Check `.chump-locks/` for the stalled lease — if expired, the system already cleaned it up
2. `cd /tmp/chump-<gap-id>` — see if the worktree still has WIP
3. If WIP exists: commit-as-WIP first, then ship/iterate from there
4. If WIP gone or too entangled: re-dispatch with explicit recovery notes from the prior attempt
**Today's evidence.** INFRA-2071 cycle-13 (Sonnet stalled at 7/8 smoke tests on a test-design bug; my recovery attempt wiped the work via `--force-recover`; documented in INFRA-2071 notes + INFRA-2235 follow-up).

### Class 6 — `chump claim --force-recover` wipes uncommitted state
**Symptom.** You see the error `worktree path already exists: /tmp/chump-X / Remove it first OR re-run with --force-recover to auto-clean`. You run `--force-recover`. Worktree gets destroyed including any uncommitted changes.
**Detection.** Too late — already happened. The lesson: don't auto-recover without checking for WIP first.
**Fix (prevention).** INFRA-2235 (filed 2026-05-29): `chump claim --force-recover` should refuse by default when target worktree has uncommitted changes; offer `--discard-wip` for legitimate destroy-state. Emits `kind=force_recover_wip_loss` audit event.
**Workaround (today).** Before re-running with `--force-recover`: `cd /tmp/chump-<gap>; git status; git stash` to preserve any WIP. Then `--force-recover`. Then re-apply the stash post-claim.

### Class 7 — gap-status auto-flip silently no-ops
**Symptom.** A PR merges to main with `INFRA-XXXX` in its subject line. The expected auto-flip via INFRA-2121 (auto-flip-on-merge action) doesn't fire. Gap stays `status: open` in state.db even though the work shipped.
**Detection.** `chump gap show INFRA-XXXX | grep status` — shows `open` despite verified merge. Today's evidence: 6 gaps in this state across cycles 7+10 (INFRA-2202, 2200, 2151, 2184, DOC-058, 2208).
**Fix (per-occurrence).** Manual flip: `CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 chump gap ship INFRA-XXXX --closed-pr <N> --update-yaml`. (INFRA-2423: `CHUMP_BYPASS_PROOF_OF_MERGE` is deleted — `chump gap ship` now auto-fetches `origin/main` before the proof-of-merge check, so no bypass is needed.)
**Fix (root cause).** INFRA-2230 (filed 2026-05-29): diagnose why INFRA-2121 silently misses certain PR/gap pairs. Add `kind=auto_flip_skipped` ambient with reason field (regex_miss / workflow_skip / state_db_error). Either fix the trigger OR add nightly catch-up scan.

### Class 8 — Shelfware (operationalization gap)
**Symptom.** A new daemon, CLI, ambient kind, scanner anchor, or protocol doc lands on `main` — but no curator role doc (`.claude/agents/*.md`, `CLAUDE.md`, `AGENTS.md`, `docs/process/*.md`) references it. The artifact is present on disk but absent from every workflow. Curators never reach for it. Effect: the investment that shipped the feature is wasted because the "elite machines" (operator's words) don't know the new tool exists.
**Detection.** Run `bash scripts/coord/quartermaster-audit-loop.sh trigger-check` — if FIRE, run `bash scripts/coord/quartermaster-audit-loop.sh run`. The audit greps all role docs for the gap_id and each artifact basename from the merged commit; zero hits = shelfware finding. Ambient stream: `kind=shelfware_detected {gap_id, artifact, role_candidate}` followed by `kind=shelfware_audit_run {ships_checked, shelfware_found, gaps_filed, deferred_count}`.
**Fix (per-finding).** The Quartermaster daemon files a follow-up gap automatically: `EFFECTIVE: Wire <artifact> into role <curator>`. The gap's AC specifies the exact role-doc location and paragraph. Claim it, add the reference (usually a 1–3 line edit), ship.
**Fix (inline, obvious cases).** If the wiring is a trivial one-liner (e.g. adding a new daemon to a Cross-references table), an agent with access to both the PR context and the role doc may wire it inline within the same PR rather than waiting for a follow-up gap. Emit `kind=shelfware_detected` before the inline edit so the audit log is complete.
**Prevention.** `com.chump.quartermaster-audit.plist` (META-205) — 5-min launchd daemon, ship-count-triggered (fires at ≥5 ships or ≥30min+1ship). Verify daemon is loaded: `launchctl list | grep quartermaster`. Verify checkpoint: `cat .chump/quartermaster-checkpoint.json`.
**Role owner.** `curator-opus-quartermaster` (`.claude/agents/quartermaster.md`). Lane: shelfware audit + procedure authoring + role-doc sync. Out of lane: PR rescue, CI gates, gap slicing.

## 2. Ship-assist tooling inventory

### Tier 1 — Per-PR operator actions (you'll use these every session)
| Tool | Purpose | When to reach |
|---|---|---|
| `chump preflight` (INFRA-1670) | Local CI gate; ~60s warm | Before every push touching Rust or `scripts/` |
| `chump claim INFRA-X --paths <CSV>` | Atomic gap claim + worktree + lease | Before any work on a gap |
| `scripts/coord/bot-merge.sh --gap X --auto-merge` | Push + PR + arm + release lease (one-shot) | Default ship path |
| `gh pr merge N --auto --squash` | Manual auto-merge arm | Fallback when bot-merge wedges (Class 4) |
| `scripts/coord/auto-merge-armer.sh` | Bulk arm auto-merge across queue | When multiple PRs need re-arming after rebase |
| `rm -f .chump-locks/claim-<gap>-*.json` | Manual lease release | When bot-merge didn't release; cleaner than `chump --release` for orphaned leases |

### Tier 2 — Wedge response (you'll use these when something is stuck)
| Tool | Wedge class | Today's evidence |
|---|---|---|
| `scripts/ops/break-trunk-cascade.sh --pr N --reason "..."` (INFRA-2087) | Trunk-RED cascade — operator-button for the drop-rulesets + admin-merge + restore dance | Rate-limited 1/hr |
| `scripts/ops/rotate-sccache-r2-gh-only.sh --execute` (INFRA-2240) | Class 3 sccache R2 pair-mismatch (PRIMARY rotation path) | Shipped today, PR #2795 |
| `scripts/ops/rotate-sccache-r2-token.sh --execute` (INFRA-2237) | Class 3 sccache R2 (CF-API automation backup) | Shipped today, PR #2793 |
| `bash scripts/ci/check-required-checks-non-empty.sh` (INFRA-2201) | Empty `required_status_checks` (silent open gates) | Shipped INFRA-2201 today |
| Manual sed-scrub + `chump gap set --acceptance-criteria` with `CHUMP_ALLOW_GAP_REWRITE=1` | Gap registry hygiene drift | Used today on INFRA-2246-cluster scrub |

### Tier 3 — Curator skills (slash commands; per role-lane orchestration)
| Skill | Lane | Best for |
|---|---|---|
| `/shepherd` | PR rescue + merge health | Pattern-14 evidence-gathering + Pattern-15 ship-something-every-cycle |
| `/ci-audit` | CI failure decomposition | Classify wedge into flake / logic-bug / missing-gate; dispatch Sonnet on flakes |
| `/handoff` | Typed dispatch | DecomposeContract / CodeFixContract / GapReviewContract instead of free-form prompts |
| `/fleet-doctor` | Strict health invariants | Single command yes/no answer on fleet health (7 invariants) |
| `/fleet-brief` | 60-sec operator briefing | Session start; pillar mix; stalls; alerts |
| `/operator-recall` | Halt-class paging | AUTH_DEAD / COST_CAP / CI_BROKEN / QUEUE_STARVE |
| `/decompose` | Umbrella → sub-gap slicing | Two-phase decomposition at claim time |
| `/md-links` | Docs link integrity | Stale gap references, broken cross-refs |
| `/infra-watcher` | SRE-lane substrate health | Daemon plists, runner ghost-online, disk pressure |
| `/observability` | Telemetry tuning | Event registry hygiene, reaper cadence, cost leaderboard |

### Tier 4 — Tooling that DOES NOT EXIST YET (filed gaps)
| Missing tool | Gap | Priority |
|---|---|---|
| Local CI gate (no network) | INFRA-2251 | P0 (today's incident → 10× urgency) |
| Local merge queue (offline) | INFRA-2252 | P1 |
| Auto-wedge-file from ambient `kind=wedge_class_detected` | INFRA-2068 | P1 |
| Wedge-fixer auto-dispatch with template library | INFRA-2069 | P1 |
| Cascade-unblock detector (auto-rebase queue after fix lands) | INFRA-2070 | P1 |
| Admin-merge frequency circuit-breaker | INFRA-2071 | P1 |
| No-revert-loop guard for auto-fixer | INFRA-2075 | P1 |
| `chump paramedic CI_FAILURE` action | INFRA-1713 | P1 |
| bot-merge stall wall-clock monitor + auto-bail | INFRA-1399 | P1 |
| `chump claim --force-recover --discard-wip` safety + audit | INFRA-2235 | P1 |
| Auto-flip-on-merge silent miss + nightly catch-up | INFRA-2230 | P1 |
| Network sync daemon (offline→online replay) | INFRA-1322 | P1 |
| `CHUMP_GITHUB_MODE=offline` auto-detect knob | INFRA-1325 | P2 |

## 3. Decision flow — given a wedge, which tool first?

```
Wedge symptom → identify class → first-tool → fallback chain

fmt-drift queue-wide
  → fmt-sweep gap (xs/P0) → ship via bot-merge → drains queue
  → fallback: manual gh pr merge if bot-merge wedges

raw-gh-allowlist queue-wide
  → 1-line allowlist add (xs/P0) → bot-merge → drains queue

sccache R2 unauthorized cross-PR
  → check `gh secret list -R repairman29/chump | grep R2_`
  → if pair-mismatch: rotate-sccache-r2-gh-only.sh (primary, INFRA-2240)
  → if pair was rotated recently but still failing: rotate-sccache-r2-token.sh (CF-API, INFRA-2237) OR re-rotate
  → operator action; cannot agent-fix without CF API token

trunk-RED + queue-blocked >20m
  → /ci-audit decompose
  → if classified flake: dispatch Sonnet rerun
  → if classified logic bug: file gap, dispatch Sonnet fix
  → if classified missing-gate: break-trunk-cascade.sh + INFRA-1274-style allowlist add

bot-merge.sh runs >4 min no output
  → SIGTERM the bot-merge process
  → manual recovery: gh push + create + merge --auto + rm lease file
  → bypass trailers in commit: Bot-Merge-Bypass + Test-Gate-Bypass

Sonnet sub-agent stalled (600s no progress)
  → check /tmp/chump-<gap-id> for WIP
  → if WIP exists: commit-as-WIP, don't --force-recover
  → re-dispatch with recovery notes documenting the stall point

gap status:open after merge to main
  → manual flip: CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 chump gap ship X --closed-pr N --update-yaml
  → (INFRA-2423: CHUMP_BYPASS_PROOF_OF_MERGE deleted; auto-fetch runs at ship time)
  → batch-sweep recent merges weekly (until INFRA-2230 ships)
```

## 4. Top-3 highest-leverage missing gaps (file/promote/ship-next)

Today's evidence ranked by "would have saved how much time today":

1. **INFRA-2251 (P0/s) — local CI gate `scripts/ci/run-local-ci.sh`** — eliminates the entire "remote service hiccup wedges queue" class. ~50% of today's pain disappears with this gap shipped. Was previously a ghost reference in OFFLINE_FIRST.md as INFRA-1320; filed for real today.

2. **META-118 chain (INFRA-2068/2069/2070/2071/2075) — auto-wedge-classify-and-dispatch** — turns each Pattern-14 incident I drilled today into a fleet-level reflex. Each sub-gap is filed; INFRA-2071 is ~90% done (Sonnet pickup in flight from this dispatch). Combined effect: today's manual cycles 5/6/7/12 become "Sonnet auto-fixed it before operator noticed."

3. **INFRA-1713 (P1/s) — `chump paramedic CI_FAILURE` action** — diagnose top failing check, dispatch rescue Sonnet, close the BLOCKED-with-CI-failure class. Pairs with INFRA-1429 (stale-branch auto-rebase) for the full auto-rescue layer. Sonnet dispatched on this in the current parallel wave.

**Bonus P1 — INFRA-1399 (bot-merge stall wall-clock monitor)** — today's 3 occurrences cost ~15-20 min each. Wall-clock progress monitor with auto-bail to manual fallback would save ~1 hr / day in heavy ship sessions.

## 5. Reliability lessons + audit log

Each of these is captured in the cited gap; this section is the index:

- **bot-merge.sh silent wedge** → INFRA-1399 (filed pre-today)
- **`--force-recover` destroys WIP** → INFRA-2235 (filed today, cycle 14)
- **Sonnet stall recovery pattern** → INFRA-2071 notes (cycle 13 evidence) + INFRA-2235 cross-ref
- **gap-status auto-flip silently no-ops** → INFRA-2230 (filed today, cycle 11)
- **OFFLINE_FIRST.md ghost gap IDs (INFRA-1320, 1321 never filed)** → INFRA-2251 + INFRA-2252 (filed today, cycle 16-ish)
- **`chump-proprietary` exposure in PR titles/bodies** → 17 hits scrubbed via mass sed + state.db AC/notes overwrite (cycle 16); future `chump gap set` ops use `CHUMP_ALLOW_GAP_REWRITE=1` to bypass INFRA-456 hijack guard
- **Sccache R2 pair-mismatch root cause** → both rotation scripts shipped today (INFRA-2237 CF-API + INFRA-2240 GH-only); operator runbook in `docs/process/SCCACHE_R2_CACHE.md`
- **`chump gap reserve` boilerplate TODO ACs** → operator memory `feedback_gaps_always_have_ac.md` — fill concrete AC immediately on every reserve
- **Pattern 14 (verify before alarm)** → `docs/process/SHEPHERD_LOOP_PLAYBOOK.md` + `CLAUDE.md` L196 (shipped earlier today via PR #2762)
- **Pattern 15 (no idle curators)** → same playbook (shipped today)

## 6. Today's session — what shipped, what didn't

This section is the audit trail. Future shepherds reading the wedge-class table above can cross-reference here for "did Opus actually ship that fix today, or is it still a gap?"

| Gap | Status | PR | Class addressed |
|---|---|---|---|
| INFRA-2188 (reaper extension + disk-critical mode) | ✅ merged → main | #2774 | fleet-quality (disk pressure) |
| INFRA-2216 (fmt sweep on chump-integrator) | ✅ merged → main | #2782 | Class 1 fmt-drift |
| INFRA-2218 (allowlist add for backfill-shipped-gaps.sh) | ✅ merged → main | #2784 | Class 2 raw-gh allowlist miss |
| INFRA-1758 (chump-coord subscribe_events stub) | ✅ merged → main | #2787 | A2A Layer 1a foundation |
| INFRA-2237 (rotate-sccache-r2-token.sh CF-API automation) | ✅ merged → main | #2793 | Class 3 sccache R2 (backup path) |
| INFRA-2240 (rotate-sccache-r2-gh-only.sh primary) | ARMED | #2795 | Class 3 sccache R2 (primary path) |
| INFRA-2246 (offline-first roadmap consolidation) | ARMED | #2796 | Strategic; offline-first scope boundary doc |
| INFRA-1797 (opus-message SessionStart hook) | ARMED | #2769 | Inbox surface |
| INFRA-1883 (PWA /api/dashboard-summary, Sonnet ship) | ARMED | #2777 | Marcus-arc demo #3 |
| INFRA-2071 (admin-merge circuit-breaker, Sonnet cycle-13 stall + cycle-17 pickup) | in-flight (Sonnet) | TBD | META-118 sub-gap 5 |
| INFRA-2251 (local CI gate) | in-flight (Sonnet) | TBD | Class 1-4 prevention; offline-first Phase 1 |
| INFRA-2069 (wedge-fixer template library scoped-down) | in-flight (Sonnet) | TBD | META-118 sub-gap 3 |
| INFRA-1713 (chump paramedic CI_FAILURE action) | in-flight (Sonnet) | TBD | auto-rescue layer |
| INFRA-2230 (gap-status auto-flip drift diagnosis) | filed, not claimed | TBD | Class 7 prevention |
| INFRA-2235 (force-recover WIP-loss safety) | filed, not claimed | TBD | Class 6 prevention |
| INFRA-2247/2248 (Mission + MeshTransport interface lift) | filed under INFRA-2246 umbrella | TBD | Offline-first Phase 2 |
| INFRA-2252 (local merge queue) | filed under INFRA-2246 umbrella | TBD | Offline-first Phase 3 |
| INFRA-2253 (behavior-tree lift) | filed, P2 follow-up | TBD | curator loop refactor experiment |

## 7. Cross-references

- `docs/process/SHEPHERD_LOOP_PLAYBOOK.md` — Pattern 14 + Pattern 15 hard rules
- `docs/process/SUBAGENT_DISPATCH.md` — META-069 sub-agent dispatch contract
- `docs/process/SCCACHE_R2_CACHE.md` — sccache R2 rotation runbook
- `docs/process/CLAUDE_GOTCHAS.md` — operational gotcha catalog
- `docs/strategy/OFFLINE_ROADMAP_2026Q2.md` — phased plan (INFRA-2246, this PR's predecessor)
- `docs/design/MISSION_LAYER_INTERFACE.md` — public interface design for mission layer
- `CLAUDE.md` — session rules, hard rules, pre-flight checklist, bypass trailers

## Class 8 — Shelfware (daemon shipped but never wired into any curator doc)

**Symptom.** A daemon, CLI, or plist exists on disk and runs via launchd, but no `.claude/agents/*.md`, `CLAUDE.md`, or `docs/process/*.md` mentions it. The operator discovers it only when something breaks.
**Detection.** `bash scripts/coord/quartermaster-audit-loop.sh run` — scans merged commits, greps role-doc tree, emits `kind=shelfware_detected` for orphaned artifacts.
**Fix.** File a wiring gap (EFFECTIVE, P1/s) via the Quartermaster daemon. The gap AC is: add a section to the appropriate curator role doc, add the artifact to `scripts/setup/bootstrap-manifest.yaml` if it's a launchd plist.
**Prevention.** Quartermaster daemon fires after every 5 ships or after 30 min idle. Any new `scripts/coord/*.sh` or `scripts/launchd/*.plist` that doesn't appear in a role doc within 24h of merge generates a `shelfware_detected` event.

## Class 9 — Quartermaster auto-fixers (META-225)

Three daemons that eliminate the three manual unwedging classes the operator had to approve on 2026-05-30. These run continuously without operator involvement.

**Operator-visible cheat sheet:**

| Daemon | Cadence | Detects | Auto-action | Ambient kind |
|---|---|---|---|---|
| `daemon-activator-loop.sh` | Every 5 min | New `install-*.sh` or `*.plist` on `origin/main` with label not in `launchctl list` | Runs the installer | `daemon_auto_activated` / `daemon_activator_failed` |
| `ghost-pr-closer.sh` | Every 15 min | Open PR (DIRTY or CONFLICTING) whose gap is `status:done` | Closes PR with comment | `ghost_pr_closed` |
| `main-worktree-drift-detector.sh` | Every 30 min | >50 untracked yaml OR >20 commits behind `origin/main` in main worktree | Emits alert + reserves cleanup gap | `main_worktree_drift_detected` |

**Install / verify:**
```bash
# Install once after META-225 merges:
bash scripts/setup/install-daemon-activator.sh
bash scripts/setup/install-ghost-pr-closer.sh
bash scripts/setup/install-main-worktree-drift-detector.sh

# Verify all three are running:
launchctl list | grep -E "com.chump.(daemon-activator|ghost-pr-closer|main-worktree-drift-detector)"
```

**Logs:**
```
~/.chump/logs/daemon-activator.{out,err}
~/.chump/logs/ghost-pr-closer.{out,err}
~/.chump/logs/main-worktree-drift-detector.{out,err}
```

**Ambient stream monitoring:**
```bash
tail -50 .chump-locks/ambient.jsonl | grep -E '"kind":"(daemon_auto_activated|daemon_activator_failed|ghost_pr_closed|main_worktree_drift_detected)"'
```

**Decision doctrine:** `docs/process/SHEPHERD_AUTONOMY_LADDER.md` — full approval matrix for which unwedging moves are auto-execute vs. operator-approve.

**If a daemon is not running:**
```bash
# Reinstall (idempotent):
bash scripts/setup/install-<daemon-name>.sh

# Or check bootstrap manifest:
bash scripts/setup/chump-fleet-bootstrap.sh --check
```

---

## Class 10 — PR BLOCKED with zero failures: cancelled required checks

**Symptom.** A PR is `BLOCKED`, auto-merge is armed, and no check shows a failure — yet it never merges. A *required* check (audit, test, ACP smoke) ended with conclusion `CANCELLED`: concurrency-cancelled required checks block silently, because a cancelled run is neither green nor red.
**Receipt.** PR #3488 (2026-08-06).
**Diagnose** (replace `<N>` / `<RUN_ID>`):
```bash
# Required checks and their conclusions — look for CANCELLED (not FAILURE)
gh pr checks <N> --required
gh pr view <N> --json statusCheckRollup \
  --jq '.statusCheckRollup[] | select(.conclusion=="CANCELLED") | {name, detailsUrl}'
# Find the cancelled run on the PR branch
gh run list --branch <BRANCH> --json databaseId,name,conclusion \
  --jq '.[] | select(.conclusion=="cancelled")'
```
**Fix.** Re-run only the cancelled run: `gh run rerun <RUN_ID>` (add `--failed` only if some jobs failed; a cancelled run needs a plain rerun). Do not push an empty commit to kick CI.

## Class 11 — superseded-sweep orphans a live second-slice PR

**Symptom.** A second-slice PR for a gap is closed by `scripts/coord/close-superseded-prs.sh` even though its work is verified and unmerged. The sweep keys on the gap ID: when the gap is bookkept `done` against slice 1, every other open PR carrying that gap ID looks "superseded" and is closed.
**Receipts.** #3488 was closed while its required-check reruns were still queued (CREDIBLE-204).
**Detect.** A closed PR with `pr_auto_closed_superseded` in `.chump-locks/ambient.jsonl` whose branch still carries a diff over main: `git diff --stat origin/main origin/<BRANCH>`.
**Prevention.** Before marking a multi-slice gap done on slice 1, check for other open PRs with the gap ID (`gh pr list --search "<GAP-ID> in:title" --state open`) and run `close-superseded-prs.sh <GAP-ID> --dry-run` first.

## Class 12 — clean second-slice recovery: re-mint under a fresh gap ID

**Symptom.** Slice 2 of an already-shipped gap reuses the branch name; `bot-merge.sh` stops with exit 22 and the `INFRA-3532: <branch> has a MERGED PR but HEAD carries an unshipped diff over main` message.
**Why not the printed recovery.** The INFRA-3532 gate message prints a recovery that needs `Bot-Merge-Bypass` trailers and `CHUMP_BYPASS_BOT_MERGE=1`. Prefer the re-mint, which needs no bypass trailers:
1. Reserve a slice-2 gap (`chump gap reserve ...`) and claim it.
2. Create a fresh branch from `origin/main` for the new gap.
3. Cherry-pick the unshipped commit(s) from the poisoned branch.
4. Retitle the commit/PR to the new gap ID.
5. Ship normally with `scripts/coord/bot-merge.sh`.
**Receipt.** CREDIBLE-205 / PR #3491 shipped this way. Cross-reference: the gate lives in `scripts/coord/bot-merge.sh` (INFRA-3532, regression test `scripts/ci/test-botmerge-poisoned-branch.sh`).

## Class 13 — a deliberate disarm is undone by an arm sweeper

**Symptom.** You run `gh pr merge <N> --disable-auto` on purpose (a PR must not land yet) and within half an hour the timeline shows `auto_squash_enabled` again, attributed to the fleet's own token. Every armer (bot-merge, the sweeper, rebasers, rescuers, revivers) used to decide on its own whether a PR was "held", and most never checked.
**Receipt.** #5494 (CREDIBLE-1496): disarmed by the architect at 02:27Z with an explaining comment; force-pushed at 02:52:27Z and re-armed at 02:52:37Z by `scripts/ops/pr-repair-rebase.sh` (worker loop, 30-min cooldown: the same push-then-arm pair at 02:20 and 03:26). RESILIENT-1613.
**Hold a PR (the one way).** Add the label `no-auto-merge`, or put a line `Auto-merge: hold` (case-insensitive, optional reason after it) in the PR body or any comment. Disarming alone is not enough: GitHub also disarms on every failed required check, so a bare disarm is indistinguishable from gate noise.
```bash
gh pr edit <N> --add-label no-auto-merge && gh pr merge <N> --disable-auto
```
**Release.** Remove the label (`gh pr edit <N> --remove-label no-auto-merge`) or edit the marker line out; the next armer tick re-arms.
**How it is enforced.** `scripts/coord/lib/arm-policy.sh` `arm_policy_allows <pr> [armer] [repo]` is called by every shell armer (gate: `scripts/ci/test-arm-policy.sh`, allowlist `scripts/ci/arm-policy-allowlist.txt`, shrink-only). Legacy labels `hold`, `do-not-merge` and `CHUMP_HOLD` are honored too. A blocked arm emits `kind=pr_arm_skipped_hold`; an arm that undoes a disarm emits `kind=pr_rearmed` naming the armer (`auto-merge-armer.sh<-<caller>`), so `grep pr_rearmed .chump-locks/ambient.jsonl` names the next re-arm war's source.

## Maintenance

This playbook should be **updated whenever a new wedge class is discovered** (new entry in §1), a **new ship-assist tool ships** (entry added to §2), or a **lesson-learning gap closes** (move from §4/§5 in-flight to §6 shipped + cross-link the doc to the fix's PR).

If a future loop session uncovers ≥3 new wedge classes that aren't here, the playbook should be re-audited rather than just appended — the taxonomy may need restructuring.
