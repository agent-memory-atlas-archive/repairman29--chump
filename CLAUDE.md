# Claude Code — Chump session rules (hot overlay)

> **Canonical agent rules live in [`AGENTS.md`](./AGENTS.md)** (Linux Foundation AGENTS.md spec). This file is the **Claude-Code-specific overlay** — Chump session flow + Claude-Code-only mechanics (subagent spawning, OAUTH token paths, `.claude/` directory conventions).
>
> A non-Claude harness (opencode-bigpickle, codex, manual, etc.) reads `AGENTS.md` + the two contract specs (links activate once #1718 + #1721 land):
> - `docs/process/HARNESS_CONTRACT.md` (INFRA-1044) — what Chump needs FROM the agent (file tools, shell, git, gh)
> - `docs/process/AGENT_API.md` (INFRA-1050) — what Chump gives TO the agent (`--briefing`, `--execute-gap`, `ambient emit`, `health`)
>
> Read order for Claude Code sessions: `AGENTS.md` first, then this file. (INFRA-1046)

## Mission

> **RIBBON-ONLY FOCUS (operator decision, Jeff 2026-08-22):** the job is the
> factory — all other products are **parked** until we cut the ribbon (a
> clean-install, hands-off factory that lands a real outcome in a person's hands
> on owned iron). Cutting the ribbon is the only thing that matters. This is the
> **current singular focus of MISSION-010**, not a new mission — see
> [`docs/MISSION.md` → Ribbon-only focus](./docs/MISSION.md#ribbon-only-focus-operator-decision-jeff-2026-08-22).

> **The load-bearing mission of record lives in [`docs/MISSION.md`](./docs/MISSION.md)**
> (MISSION-014). Canonical mission gap: **MISSION-010** (self-coordinating fleet, proof on
> `repairman29/BEAST-MODE`). The Scoreboard in that doc is the one honest measure —
> if a day's work didn't move it, it didn't count.
>
> Active mission pointer: `~/.chump/ACTIVE_MISSION` (currently `MISSION-010`).
> Run the scoreboard anytime (read-only, safe): `bash scripts/dev/mission-scoreboard.sh`.

The 4 pillars are **how** we move toward the mission (the *qualities* every
gap is graded on); the mission is **what** "done" looks like (the *outcome*
every ship rolls up to). When in doubt, the mission wins.

Build agents that are **Credible**, **Effective**, **Resilient**, and **Zero-Waste**.
Canonical pillar definitions: [`AGENTS.md` → The 4 pillars](./AGENTS.md#the-4-pillars-resilient-259);
coordination docs: [`docs/process/CLAUDE_GOTCHAS.md`](./docs/process/CLAUDE_GOTCHAS.md).
Eval/research work also reads [`docs/process/RESEARCH_INTEGRITY.md`](./docs/process/RESEARCH_INTEGRITY.md).

## Air Traffic Control — the Chief-of-Staff role (operator decision, Jeff 2026-08-10)

**The Opus session driving the standing loop is Air Traffic Control (ATC)** — the
Chief of Staff, not a worker and not an orchestrator-who-does-the-work.
**Orchestrating is not the job; traffic-cop work is.** Keep the machine healthy
and *keep looping, forever* — and **dogfood ChumpOS by making it do its own work,
never doing that work for it.** This governs the standing loop and the ATC's own
agents; it extends "Feed the fleet first" (`docs/process/SUBAGENT_DISPATCH.md`) and
is the operating stance of the duty officer (`docs/design/DUTY_OFFICER.md`, RESILIENT-274).

**ATC DOES (traffic cop):**
- **Keep looping.** The loop is your beat. Each cycle: scan health — ship-rate
  (`git log origin/main --since=1h`), disk, auth, wedges, dead daemons, stuck/BLOCKED
  PRs, orphaned leases — and act to keep flow.
- **Revive + unstick.** Restart dead daemons, re-arm stalled auto-merge, rebase/rerun
  BLOCKED PRs, clear wedges, free orphaned leases, bounce a hung worker. Keep the
  queue *moving*.
- **Feed the fleet.** Turn work into gaps with clear AC and **dispatch it**
  (`chump dispatch <GAP> --backend headless`, or file it for a worker to pick). You
  route work; the fleet builds it.
- **Escalate only through the quiet gate** (RESILIENT-274 /
  `scripts/coord/operator-escalation-registry.txt`): page the operator only when a
  signal is halt-class or has no playbook. Otherwise stay quiet (updates ≠ pages).

**ATC does NOT do (the hard line):**
- **NEVER do ChumpOS's job for it.** Do not hand-write the PR the fleet should write.
  When you catch yourself implementing a gap by hand, STOP — file it and dispatch it.
  Hand-work is allowed ONLY to bootstrap a capability the fleet *structurally lacks*
  (it literally cannot dispatch the work yet); even then the deliverable is **making
  the fleet able to do it next time** — the fix returns through the fleet the moment
  the capability exists (dogfood → fix the tool → let the tool do it). Tonight's
  hand-built dispatch/gateway fixes were that bootstrap; the standing mode is ATC.
- **Don't hand-hold every ship.** Arm auto-merge and let go. A stuck PR is an
  *unstick* job, not a *re-implement* job.

**Through-line:** the human is at ring-0, ATC is the standing traffic cop that keeps
the machine running and honest, and ChumpOS does the building. If a day's work was
ATC *doing the fleet's job*, the machine didn't get more autonomous — it got a more
expensive babysitter. **Dogfood forevermore.**

## No-escalation overlay (Claude-Code-specific)

> **Canonical rule lives in [`AGENTS.md` → No-operator-escalation discipline](./AGENTS.md#no-operator-escalation-discipline-operator-decision-of-record-2026-05-30).** This is the Claude-Code-only overlay.

The 4 legitimate escalation triggers (T1 irreversible-third-party / T2 credential-rotation / T3 operator-explicit-domain / T4 halt-class-fleet-unsafe) apply equally to Claude-Code sessions.

**Claude-Code-specific tooling discipline:**
- **`AskUserQuestion` tool** — invoke ONLY when one of T1-T4 matches. If you're tempted to use it for a "which approach should we use" decision, that's almost certainly team-consensus territory: broadcast `FEEDBACK kind=proposal` via `scripts/coord/broadcast.sh` instead.
- **Operator-recall surface** — `scripts/dispatch/operator-recall.sh` is for T4 only (halt-class detector). Don't invoke it for routine decisions.
- **Sub-agent dispatches** inherit this rule via `docs/process/SUBAGENT_DISPATCH.md` — when you write a Sonnet brief, the no-clarifying-questions discipline already says don't ask the operator; this overlay extends it to "and don't ask the operator from within the sub-agent's PR either".

**Self-check before any `AskUserQuestion` call**: which of T1-T4 does this match? If none, broadcast `FEEDBACK kind=proposal` instead.

## Mission Driver — every session, not just when asked

You are responsible for **driving the 4 pillars**, not just servicing gaps as they appear. The fleet defaults to filing gaps about itself (because that's what's easy to notice) — Resilient and Zero-Waste pile up while Effective and Credible starve. Counteract that on purpose.

**At session start AND every iter of any loop:**

1. **Pillar inventory.** Count fleet-pickable gaps per pillar (INFRA P0|P1 xs|s|m, no deps). Quick scan via title prefix tags `EFFECTIVE:` / `CREDIBLE:` / `RESILIENT:` / `ZERO-WASTE:` / `MISSION:`.
2. **Balance lever — surface, do NOT manufacture (anti-bloat, 2026-07-26).** Pillar imbalance is a **metric**, not a work order. It is already surfaced by `chump fleet brief` + `fleet_health.pillars_starved`. **Do NOT "file 1-2 gaps to refill a starved pillar"** — that instruction manufactured 146 self-referential "pillar starved" gaps (filed as INFRA, which never refill the *named* pillar) and was the #1 driver of the 2026-07-26 gap-bankruptcy (1,214 → 25). A pillar refills by pointing the fleet at a real **outcome** whose work happens to be that pillar — not by conjuring gaps to hit a count. If a pillar is genuinely starved of *real* work, that is a signal to pick a different **outcome**, not to inflate the queue.
3. **Every P0/P1 gap must trace to an outcome (MISSION-045).** `chump gap reserve --priority P0|P1` **requires `--outcome <id>`** (a row in the outcomes table; `chump outcome list`) and refuses without it. This is the intake firewall against orphan meta-work. Bypass (audited): `--no-outcome-required` or `CHUMP_GAP_RESERVE_NO_OUTCOME=1`. P2/P3 stay permissionless for exploration. Also **title-tag every new gap** with the pillar prefix so the *why* is visible to picker + reviewer.
4. **P0 budget = 5 max.** Reserve P0 for true unblockers across all 4 pillars; demote inflation.
5. **Roadmap-before-gaps.** When unsure what to file, re-read `docs/ROADMAP.md` first. Gaps implement the roadmap, not the other way around. If the roadmap is missing or stale, write/update it before refilling.
6. **Don't optimize the engine while the car sits in the driveway.** Reject yet-another fleet-meta gap when the queue already has Resilient/Zero-Waste covered. Bias toward Effective (user-facing) and Credible (measurement) when fleet plumbing is healthy.

7. **Rate surprising outcomes.** After ship, rate the gap with `chump gap rate <ID> <1-5>` — the picker uses class-aggregate ratings to bias future selection. Low-rated classes (mean < 2.5, min 2 samples) are demoted one priority tier in tie-breaks. Check current class standings with `chump kpi report --impact`.

PM-curation role: see **META-046**. Honest pillar-grade reports are part of the job, not an aside.

Explicit SLO targets for each pillar and layer: [`docs/process/FLEET_SLOS.md`](./docs/process/FLEET_SLOS.md).
Check current vs. target at any time: `chump health --slo-check` (exits non-zero on breach).

## MANDATORY pre-flight (every session, before any work)

```bash
git fetch origin main --quiet && git status
ls .chump-locks/*.json 2>/dev/null && cat .chump-locks/*.json || echo "(no active leases)"
bash scripts/setup/chump-fleet-bootstrap.sh --check  # META-066, must exit 0
bash scripts/coord/auth-status.sh                    # RESILIENT-086: VALIDITY probe — "can the fleet transact?" Catches the trap where a depleted/stale credential outranks a valid one (exit 2) and prints the exact fix. Don't re-diagnose auth by hand — read this line.
chump farmer status                                  # RESILIENT-069: lights-on check — sentinel absent + zero exit-78 supervisors + oauth fresh + farmer heartbeat <120s. RED (exit 1) means no NEW claims (chump claim / chump gap reserve refuse); the Farmer's own recovery routes around it.
tail -30 .chump-locks/ambient.jsonl 2>/dev/null || echo "(no ambient stream yet)"
scripts/coord/chump-inbox.sh read --no-advance   # INFRA-1115: peer DMs (per OPUS_MESSAGE_PROTOCOL.md)
chump-coord watch &                              # FLEET-006 (skip if NATS unavailable)
chump gap list --status open                     # canonical .chump/state.db
chump gap preflight <GAP-ID>                     # exits 1 if not pickable — stop if so
chump --briefing <GAP-ID>                        # MEM-007 per-gap context
bash scripts/coord/freshness-preamble.sh         # META-115: FRESH/STALE/CRITICAL_STALE session-start gate
bash scripts/dev/mission-scoreboard.sh           # MISSION-014: did yesterday move docs/MISSION.md?
```

**Freshness discipline** — before any "X is missing" claim, run [`verify-existence`](./.claude/skills/verify-existence/SKILL.md)
or `git ls-tree origin/main path/to/X`. Local `ls` lies when your checkout is 40+
commits behind. Full rules + anti-patterns + decision table in
[`docs/process/FRESHNESS_DISCIPLINE.md`](./docs/process/FRESHNESS_DISCIPLINE.md) (DOC-059 / META-114).

The SessionStart hook (INFRA-1150 a2a-inbox-inject) auto-surfaces unread
peer broadcasts at the top of every session digest under a `Pending
broadcasts` header. Process + reply per
[`docs/process/OPUS_MESSAGE_PROTOCOL.md`](./docs/process/OPUS_MESSAGE_PROTOCOL.md)
**before** picking up a new gap. Send addressed DMs via
`scripts/coord/broadcast.sh --to <session-id> WARN "..."`; read with
`scripts/coord/chump-inbox.sh read`.

## A2A consensus is always-on and mandatory (INFRA-2515, operator decision 2026-06-05)

The agent-to-agent coordination layer (`FEEDBACK kind=proposal` → curator votes
→ deliberator tally → `consensus_result`) must **always be on and always be in
use**. A proposal that dies at `NO_QUORUM` because nobody voted is the fleet
*failing to coordinate* — and after the grace window it needlessly pages the
operator. So:

- **Vote on every open proposal in your inbox, every cycle.** When the
  SessionStart digest (or a `VOTE NEEDED` nudge) surfaces an open
  `FEEDBACK kind=proposal`, cast `chump vote <corr_id> +1|-1|0 --reason '<why>'`
  **before** picking up a gap. Abstain (`0`) with a reason if it's out of your
  lane — that still counts toward quorum. Silence is not an option.
- **Route routine fleet decisions through consensus, not unilaterally** —
  priority/class re-rankings, scale changes, doctrine tweaks: broadcast a
  proposal and let the fleet vote (this is the same reason `AskUserQuestion` is
  a T1–T4-only tool, above).
- **It self-enforces.** The deliberator (`com.chump.deliberator`, every 30 min)
  re-surfaces starved proposals to your inbox to solicit votes, and
  `fleet-doctor`'s `a2a-consensus` check turns **RED** if the recv-side flag is
  off or the tallier is dead. Don't disable `CHUMP_FLEET_RECV_SIDE_V0` /
  `CHUMP_A2A_LAYER` — the bootstrap sets them; the farmer/daemon team keeps the
  deliberator scheduled.

If `chump-fleet-bootstrap.sh --check` exits non-zero, run without `--check` to
install missing launchd plists + git hooks. Without this, the productization
layer (META-063 redundancy gate, META-064 Rust-first gate, META-065 curator,
INFRA-1257 hourly planner) is dormant code-on-disk, not active discipline.

**Hourly auto-bootstrap (INFRA-1808).** The first manual `chump-fleet-bootstrap.sh`
install run self-installs an `com.chump.bootstrap-auto-install` LaunchAgent
that re-runs `chump-fleet-bootstrap.sh --install` every hour (installers are
idempotent, so this is safe) and emits `kind=fleet_bootstrap_auto_install`
per cycle. This closes the "shipped installer script, nobody ran it" gap
that let pr-auto-rebase / claude-reaper / bot-merge-watchdog sit uninstalled
for days after landing. **It does not remove the need for the manual run
above on a fresh machine** — something has to bootstrap the bootstrapper
before the hourly job exists to take over.

`ambient.jsonl` is your peripheral vision — watch for `lease_overlap`, `silent_agent`,
`edit_burst`, `queue_config_drift`, `pr_stuck`, `subagent_budget_exceeded`,
`lessons_injection_active`. Full event-kind guide: [CLAUDE_GOTCHAS.md](./docs/process/CLAUDE_GOTCHAS.md).

## Two-phase decomposition (don't pre-slice into sub-gaps)

**At filing time**: write the rough decomposition intent into the gap *description*, not as filed sub-gaps. Sub-gaps filed in advance age badly — the codebase shifts before they're picked.

Example description for a large gap:
```
Rough shape: (a) DB query layer in src/gap_store.rs,
(b) CLI handler with --apply/--dry-run/--json flags (see consolidate arm as model),
(c) ambient event registered in EVENT_REGISTRY.yaml,
(d) CI test using synthetic state.db fixture.
Key constraint: depends_on is stored as JSON array — use parse_json_ac_list pattern.
```

**At claim time**: run `chump gap decompose <ID>` — it reads the description as LLM context and generates sub-gaps against the *current* codebase. Use `--dry-run` to inspect the full prompt before calling the LLM; use `--no-description` if the description is stale.

Never file sub-gaps manually in advance. The filing agent's context is valuable input to decompose, not a substitute for it.

## Bootstrap a new product (INFRA-2265, META-067 outcome 3)

SUBSTRATE-layer entrypoint: empty dir → git init → scaffold → first commit → umbrella gap.
Consumer surfaces (founder pitch lane, roadmap UI) build on top. Sister of `chump ingest` (INFRA-1746).

```bash
mkdir /tmp/myproject
chump bootstrap "A CLI tool that syncs files across machines" \
  --dir /tmp/myproject --skip-arch-decision
# → .git/ + Cargo.toml + README.md + first commit + umbrella gap in state.db
```

## Claim before writing any code

```bash
chump claim <GAP-ID> --role <role> [--scope <module-or-concern>] [--paths CSV]   # atomic: fetch + verify + doctor + worktree + lease; --role is mandatory (INFRA-5486)
chump gap reserve --domain INFRA --title "short title"    # new gap
```

Run `chump gap preflight <GAP-ID>` first to verify pickability. If preflight fails, **stop** — do not bypass.

## Ship pipeline (always)

```bash
scripts/coord/bot-merge.sh --gap <GAP-ID> --auto-merge
```

Manual fallback if broken:
```bash
git push -u origin <branch> --force-with-lease
gh pr create --base main
gh pr merge <N> --auto --squash
chump gap ship <ID> --update-yaml
```

## Scheduling discipline — session-bound vs fleet-durable

For the full scheduling rule, decision table, anti-patterns, and migration guide from CronCreate to launchd, see **[`docs/process/SCHEDULING_LAYERS.md`](./docs/process/SCHEDULING_LAYERS.md)** (DOC-058).

Quick rule: if the work must run after you close this Claude Code session → use a launchd plist (`chump cron install`). If it only needs to run while you're present → CronCreate / ScheduleWakeup / Monitor.

## Spawning subagents (META-027) — Claude-Code-only

> Uses Claude Code's `Agent` tool. Non-Claude harnesses parallelize via the fleet (multiple workers) — see harness contract doc §Out-of-scope.

> **Feed the fleet first (dispatch doctrine, ratified 2026-06-05 — KAIZEN).**
> The conductor *feeds* the fleet; it does not *become* a worker. **Default for
> any shippable gap = file it with clear AC and let a tmux worker pick it.**
> Workers are instrumented (emit `sub_agent_dispatched`/ambient), farmer-protected
> (auto-revived), and pty-isolated (own pane). Agent-tool sub-agents are **none**
> of those: they emit no ambient event (invisible to the farmer → un-revivable),
> leak ~60-94 ptys *into your session* (machine-wide pty-exhaustion blast radius),
> and stall at the ship-wall needing hand-salvage. **Reserve Agent-tool dispatch
> for: (a) the fleet is down, (b) read-only analysis, or (c) a one-shot the fleet
> structurally cannot pick.** Evidence (2026-06-05 KAIZEN): the worker loop shipped
> 85 PRs/24h while in-session Agent dispatches cost ~38 min / 94 ptys / 106k tok
> each and tripped the 30-min `step=init` ship-wall. Reaching past the fleet to
> drive Agent-tool Sonnets is "opus in a trench coat" wearing a dispatch badge.
> Full rationale + comparison table: `docs/process/SUBAGENT_DISPATCH.md` §Feed the fleet first.

When spawning via the `Agent` tool, paste the full shipping epilogue **AND** the
pre-push checklist from `docs/process/SUBAGENT_DISPATCH.md` into every subagent
prompt. The checklist (META-069, 2026-05-23) catches the 5 most common
deterministic CI-fail classes locally — saves ~5-10 min CI round-trip per push.

**Dispatch defaults by model** (per SUBAGENT_DISPATCH.md):
Opus orchestrates and reviews; Sonnet implements per-gap; Haiku does mechanical
sweeps. When an Opus instance picks an `xs` or `s` gap, the default move is to
dispatch a Sonnet rather than hand-implement.

**Wall-clock budget:** `CHUMP_SUBAGENT_BOT_MERGE_BUDGET_S` (default 900s = 15 min).
If `bot-merge.sh` has been running for 15 min without progress markers, the
subagent **must** switch to manual recovery — passive waiting is a stall pattern.
See the SUBAGENT_DISPATCH.md "STOP" block for the exact mandate.

**Model:** always sonnet (INFRA-515). Haiku hesitates in `--dangerously-skip-permissions`
mode and burns the slot waiting for stdin that never comes.

## Auth modes (INFRA-622) — Claude-Code-specific OAUTH path

> `ANTHROPIC_API_KEY` is the universal path any harness uses to call Anthropic. `CLAUDE_CODE_OAUTH_TOKEN` is Claude Code's subscription-OAUTH path. Non-Claude harnesses calling Anthropic use the API key only.

Both `ANTHROPIC_API_KEY` (API-key) and `CLAUDE_CODE_OAUTH_TOKEN` (subscription OAUTH) are first-class.

| Mode | Env | Notes |
|---|---|---|
| `auto` (default) | — | Prefer `ANTHROPIC_API_KEY` if non-empty; else OAUTH |
| `api-key` | `CHUMP_AUTH_MODE=api-key` | Force API key; error if absent |
| `oauth` | `CHUMP_AUTH_MODE=oauth` | Force subscription token; error if absent |

Workers re-evaluate credentials before each `claude -p` spawn and read `~/.chump/oauth-token.json`. The "refreshed every 5 min" promise is **not implicit** — it only holds while the standalone refresher daemon is installed and alive:

- **Substrate:** `scripts/coord/oauth-token-refresh.sh` (INFRA-2124, hardened INFRA-1865) — extracts the token from the macOS Keychain entry `Claude Code-credentials`, hash-compares against the current file (rewrites + emits `kind=oauth_token_refreshed` only when the token actually changed — no log spam), and validates the extracted token against a real `claude -p` call before it's allowed to overwrite a still-good file (failure → `kind=oauth_token_invalid`, old file kept).
- **Cadence:** `launchd/com.chump.oauth-refresh.plist`, `StartInterval=300` (5 min). Install (idempotent): `bash scripts/setup/install-oauth-refresh-launchd.sh`. Verify it's actually loaded: `launchctl list | grep com.chump.oauth-refresh` — an installed-but-unloaded plist is exactly how the token went 16d stale (INFRA-1865).
- **Platform:** macOS-only (Keychain-backed). Linux hosts get a loud `kind=oauth_refresh_unsupported_platform` error rather than a silent no-op — a Linux-native keystore/env-fallback path is still an open operator decision.
- **Smoke test:** `bash scripts/ci/test-oauth-refresher.sh`.
- **Staleness detector:** `scripts/coord/infra-watcher-loop.sh` emits `kind=oauth_token_stale_despite_daemon` when the file is stale despite the plist showing loaded — read that event before re-diagnosing this by hand.

Validate: `chump fleet doctor` — exits non-zero if no valid auth path found.

## GitHub credentials for agents (INFRA-AGENT-CREDS)

Autonomous agents spawned via `chump --execute-gap` or `/api/gap/work` need GitHub access to commit, push, and merge PRs.

Two modes:

**1. Implicit (local dev)** — agent inherits parent process environment:
- `gh` CLI token from macOS keyring (or system credential helper)
- SSH keys from `~/.ssh/` 
- No explicit configuration needed; works on developer machines
- **Limitation:** breaks in Docker, sandboxed workers, different-user processes

**2. Explicit (production)** — agent uses environment variables:
```bash
export GH_TOKEN="ghp_..."                    # GitHub API token (overrides keyring)
export SSH_KEY_PATH="~/.ssh/id_ed25519"     # Path to SSH key for git ops
export GITHUB_TOKEN="ghp_..."                # Alternative to GH_TOKEN (some tools)
```

Pass these to the workflow:
```bash
GH_TOKEN="..." chump --execute-gap <ID>
# or via PWA:
GH_TOKEN="..." curl -X POST http://localhost:3000/api/gap/work/<ID>
```

**Sanitization:** credential values never appear in logs. Only `"forwarding explicit GH_TOKEN"` debug messages confirm presence.

**Backwards compatible:** if env vars unset, agent falls back to keyring (implicit mode).

## Hard rules

> **The core ship-discipline hard rules (never push to `main`, auto-merge
> default, PR atomicity, `--no-verify` ban, mutate-gaps-via-`chump-gap`,
> commit-often, rebase-if-behind, lease hygiene, off-rails guard,
> uncommitted-work/`wip-snapshot`) are canonical in
> [`AGENTS.md` → Ship discipline](./AGENTS.md#ship-discipline--core-hard-rules-resilient-259-harness-agnostic)
> — they apply to every harness, not just Claude Code. This section covers
> only the rules that are Claude-Code-session-specific or not yet promoted.**

- **A2A consensus is always-on (INFRA-2515).** Vote on every open `FEEDBACK kind=proposal` in your inbox each cycle — `chump vote <corr_id> +1|-1|0 --reason …` (abstain `0` on out-of-lane ones; still counts toward quorum). Route routine priority/class/scale decisions through a proposal, not unilaterally. Never disable `CHUMP_FLEET_RECV_SIDE_V0` / `CHUMP_A2A_LAYER`; `fleet-doctor` goes RED if consensus is dormant. See "A2A consensus is always-on" above.
- **`proprietary/` — NEVER commit here.** Private sibling repo; stray copies must not be staged or referenced.
- **Default model: haiku for IDE sessions, sonnet for fleet workers.** Cost-sensitive sweeps: `FLEET_MODEL=haiku`. Opus is ~50× haiku per token.
- **Always work in a linked worktree** — `chump claim` refuses the main checkout.
- **Linked worktree git path confusion (INFRA-779):** On macOS, `/tmp` → `/private/tmp` symlink plus concurrent sibling claims can corrupt a worktree's gitdir back-reference, causing `git rev-parse --show-toplevel` to return the wrong path. Recovery: `GIT_DIR=/Users/jeffadkins/Projects/Chump/.git/worktrees/<wt-name> GIT_WORK_TREE=/private/tmp/<wt-name> git <cmd>`. Prevention: `chump claim` now auto-repairs the gitdir after `git worktree add`.
- **Never start a gap without `chump gap preflight <GAP-ID>` first.**
- **Session close-out — no parked diff without a pointer (DOC-082).** Before a session ends, every work-in-progress must reach one of three states: (a) **shipped** (merged), (b) a **branch WITH a gap** pointing at it (so the fleet's picker/detectors can see it), or (c) **deliberately dropped** (`git checkout`/`--discard-wip`). Never leave real work uncommitted in the main checkout — it's invisible to every gate, detector, and session-start digest, and freshness gauges then lie about it. Precedent (2026-08-05): the almanac Phase D integration (+313 lines) sat dirty in `~/Projects/chump` for 4-5 days, unseen by the fleet, while the checkout drifted 15 commits behind origin (ZERO-WASTE-039, CREDIBLE-202).
- **Verify-before-alarm (Pattern 14 in `SHEPHERD_LOOP_PLAYBOOK.md`).** Before broadcasting any ALERT-class "CI is broken" / "queue is unverified" / "deepest CI-rot" message, **run the 4-step rollup check on a real recently-merged PR first**. `gh run list --workflow=X.yml` failing ≠ check-runs failing — named checks like `fast-checks`/`gap-status-check`/`gaps-integrity` are typically produced by *other* workflows than `ci.yml`, and the PR's `statusCheckRollup` (with `.workflowName` per check) is the only ground truth.
- **Reality-check, durable-fix doctrine, and no-idle-curators-in-loops are canonical in AGENTS.md** — see [Reality-check](./AGENTS.md#reality-check-before-alarm-class-beliefs--ship-check-first-credible-090), [Durable-fix doctrine](./AGENTS.md#durable-fix-doctrine--no-band-aids-credible-105), and [Mission Driver — loop discipline](./AGENTS.md#mission-driver--loop-discipline-infra-2208-2026-05-29).
- **`chump gap reserve` applies title similarity check (INFRA-1149).** Jaccard similarity >= `CHUMP_GAP_RESERVE_SIMILARITY_WARN` (default 0.65) prompts y/N to continue; >= `CHUMP_GAP_RESERVE_SIMILARITY_BLOCK` (default 0.85) blocks the reserve. Thresholds are tunable via env. Bypass: `--force-duplicate` flag or `CHUMP_GAP_RESERVE_NO_SIMILARITY=1`.
- **CSS token discipline (INFRA-1590).** New `web/**/*.{js,html,css}` commits must not introduce raw hex / color literals outside `:root`, non-canonical `--*-primary` / `--*-secondary` token names, or mismatched `var()` fallbacks. Gate fires at pre-commit. Bypass: `Token-Discipline-Bypass: <reason>` commit trailer (logs to `ambient.jsonl`). Full rules and canonical token list: [`docs/process/CSS_TOKEN_DISCIPLINE.md`](./docs/process/CSS_TOKEN_DISCIPLINE.md).

## Local CI discipline (mandatory, INFRA-1673)

**Run local CI before every push that touches Rust or scripts.**

Operator philosophy: every push that fails CI on GitHub costs ~15 minutes round-trip. The same failure caught locally costs <60 seconds. Multiply over a day of work and the difference is hours. Long-term direction is **fully local execution, no GH dependencies** — local CI is the first step.

```bash
# Before EVERY push that touches Rust or scripts:
chump preflight              # INFRA-1670; runs cargo fmt/clippy/check + relevant test-*.sh
                             # Target: <60s warm, <120s cold.
                             # Bypass: CHUMP_PREFLIGHT_SKIP=1 + add a body trailer:
                             #   Preflight-Skip-Reason: <one sentence why>
```

Until INFRA-1670 ships the tool, manually run these in sequence — they're what the tool will wrap:

```bash
cd <worktree>
PATH=$HOME/.cargo/bin:$PATH cargo fmt --all -- --check
PATH=$HOME/.cargo/bin:$PATH cargo clippy --workspace --all-targets -- -D warnings
PATH=$HOME/.cargo/bin:$PATH cargo check --workspace
# Then any scripts/ci/test-*.sh that match files you touched.
```

**Why this is mandatory, not advisory:** the last 48h surfaced 6 different CI failure classes (cargo fmt drift, clippy dead_code, INFRA-682 path-filter missing, INFRA-1274 raw-gh allowlist missing, INFRA-1287 registry-orphan, INFRA-755 obs-budget) — every one a 1-line fix that would have taken <30s locally. The slow round-trip is a discipline failure, not a CI failure.

**Bypass discipline:** `--no-verify` and `CHUMP_PREFLIGHT_SKIP=1` are operator escape hatches. Each use emits `kind=preflight_bypassed` to `ambient.jsonl` for audit. Don't skip routinely; the audit log will show patterns and force a conversation.

**Pairs with:** INFRA-1670 (the tool), INFRA-1671 (pre-push hook enforcement), INFRA-1672 (smart scoping for speed).

### preflight-vs-CI parity allowlist (INFRA-2120 / INFRA-1867)

When you add a new `run:` step to `.github/workflows/ci.yml`, the pre-commit
hook (`scripts/git-hooks/pre-commit`, block 18) and the CI step
`preflight-vs-CI parity smoke (INFRA-1867)` will both fail unless the new
gate satisfies **one** of three classifications:

1. **Mirrored in preflight** — add the same `scripts/ci/test-foo.sh` (or
   `cargo fmt|clippy|check` invocation) to `src/preflight.rs` so it also
   runs in `chump preflight`. Preferred path — local + CI stay in sync.
2. **Tier-D (cannot mirror)** — if the gate genuinely can't run locally
   (e.g. it talks to GitHub APIs or the merge queue), add it to the
   `## Tier D` section of `docs/process/CI_GATES_INVENTORY.md` with a
   reason. The parity script's matcher uses substring matching against
   the step name + run command, so a Tier-D entry like
   `gap-status-guard.yml` matches any step whose name or run-line
   contains that string.
3. **Allowlist exception** — last-resort escape hatch. Append a line to
   `scripts/ci/preflight-ci-parity-exceptions.txt` of the form:
   ```
   <step-name-or-script-basename>       # reason: <why this can't mirror>
   ```
   Bare entries match the step name, the `scripts/ci/...sh` path, OR a
   substring of either. Keep entries narrow (prefer the exact script
   basename) so the allowlist doesn't silently absorb future drift.

Adding a step without doing one of (1)/(2)/(3) is what produces the
"unmirrored gate in job=" failure surface (rank-2 CI-rot class per
`docs/strategy/CI_REVIEW_2026-05-29.md` Lever 4). The pre-commit hook
fires *only* when ci.yml is staged, so the cost is paid by the contributor
making the change, not by every push.

Bypass (rare): `CHUMP_PREFLIGHT_PARITY_CHECK=0 git commit ...` — file a
follow-up gap to add a proper classification, don't leave it bypassed.

## Rust-first vs. shell-OK (META-064, 2026-05-14)

When you reach for `nano scripts/coord/foo.sh`, pause and check the criteria
below first. The codebase has shipped 16k+ LOC of "this was shell, now we
port it to Rust" gaps in the last quarter. Most of that work could have
been Rust from the start.

**Rust-first IF *any* of these hold:**
- Mutates canonical state: `state.db`, `.chump-locks/*.json`, `ambient.jsonl`, `docs/gaps/*.yaml`
- Called from a hot path: `worker.sh` per-cycle, `bot-merge.sh` per-ship, every claim
- Shares a process boundary with a Rust caller (subprocess-race candidate)
- Will outlive 3 months (durable tooling, not exploratory)
- > 200 LOC at first commit (size predicts maintenance compounding)

**Shell is OK IF *all* of these hold:**
- Glue between existing CLI tools (`gh` + `git` + `jq`)
- One-shot or exploratory
- < 200 LOC, no state mutation
- No regression-test maintenance burden (no `scripts/ci/test-<name>.sh` sibling required)

**Bypass:** when adding shell that hits the Rust-first criteria intentionally
(e.g. a 30-line `gh + jq` glue shim that legitimately doesn't need types),
add this trailer to the commit body:
```
Rust-First-Bypass: <one-sentence reason>
```
The pre-commit gate at `scripts/git-hooks/pre-commit-rust-first.sh` checks
for the trailer when the criteria match; bypass goes into the audit log.

Sibling rules: META-063 (no new duplicates), META-065 (auto-prioritization).

## Cache-first reads (INFRA-1081, 2026-05-14)

> **🚨 DEFAULT to `cache_lookup_pr` / `sqlite3 .chump/github_cache.db`. `gh pr view` and `gh api` ONLY on cache miss.**
>
> The cache is fed in real-time by a smee.io tunnel → Python webhook receiver
> → SQLite. Reading from it is **< 100 ms** per query. Polling `gh` is
> **5-30 s per call** AND burns the global rate limit AND triggers
> `graphql_exhausted` cascades that blind every other curator. There is **no
> excuse** for `gh pr view <N>` when `.chump/github_cache.db` has the answer
> with fresher data than gh's own GraphQL.
>
> If you find yourself running `gh pr view` / `gh api repos/.../check-runs`
> in a loop — **stop**, read this section, and use the cache. Failure to do
> so is anti-pattern #9 in [`docs/process/OPERATOR_PLAYBOOK.md`](./docs/process/OPERATOR_PLAYBOOK.md). Operator-paged 2026-05-30T09:27Z.

The fleet has a **local SQLite cache** at `.chump/github_cache.db` populated by a
**webhook receiver** (`scripts/ops/github-webhook-receiver.py`) via a smee.io
tunnel. Every fleet script that wants PR state should **read from the cache first**, fall back to
direct `gh api` only on miss.

**Setup + healthcheck:** see [OPERATOR_PLAYBOOK.md §7.5 Local Infrastructure](./docs/process/OPERATOR_PLAYBOOK.md#75-local-infrastructure--webhook--smee--cache--docker). Quick check before any "polling gh":

```bash
pgrep -fa 'smee-client'      # tunnel alive?
pgrep -fa 'github-webhook'   # receiver alive?
sqlite3 .chump/github_cache.db "SELECT MAX(fetched_at_local) FROM pr_state;"  # last update?
```

```bash
source "$(dirname "$0")/lib/github_cache.sh"

# PR state — replaces gh pr view
cache_lookup_pr "<number>"           # returns JSON; falls back to REST on miss

# BEHIND scan — replaces gh pr list with mergeStateStatus filter
cache_query_behind_prs               # returns one number per line

# Per-PR check status — replaces gh api repos/X/commits/SHA/check-runs
cache_lookup_checks "<head_sha>"     # returns `name\tstatus\tconclusion` per check
```

Additional helpers (INFRA-1275):

```bash
# List open PRs — replaces gh pr list with mergeStateStatus=BEHIND filter off
cache_query_open_prs                 # returns `number\ttitle\thead_ref` per row

# Title-substring search — replaces gh pr list --search
cache_query_open_prs_by_title "X"    # same shape, filtered by LOWER(title) LIKE

# Per-PR file list — replaces gh api repos/X/pulls/N/files
cache_lookup_pr_files "<number>"     # background-tagged REST under the hood

# Bulk refill — call once on cold cache, REST not GraphQL
cache_refresh_open_prs               # writes up to 100 open PRs into pr_state
```

**Already migrated:** queue-driver.sh (BEHIND scan), bot-merge.sh FLEET-029
overlap scan, pr-rescue.sh per-PR meta fetch, chump-ambient-glance.sh
(INFRA-1275), gap-preflight.sh (INFRA-1275).
**Next consumers** (filed as gaps): bot-merge per-PR check-runs polling
(INFRA-1130), ghost-gap-reaper (INFRA-1082 audit).

**When in doubt:** read from cache. Cache miss is cheap (1 REST call, REST
core bucket stays healthy during GraphQL exhaustion). Polling GraphQL is the
costly path.

## Call criticality (INFRA-1080, 2026-05-14)

`chump_gh` now classifies each call as **critical** (default) or **background**.
Background calls get preempted when `remaining_graphql < 10%` so critical-path
operations never starve.

```bash
# Default — proceeds even when bucket is tight
chump_gh pr merge "$PR" --auto --squash

# Tag as background — yields the bucket to critical callers
CHUMP_GH_CALL_CRITICALITY=background chump_gh pr list ...
```

| Critical (default) | Background (opt-in) |
|---|---|
| `gh pr create` / `gh pr merge` | label edits |
| `gh pr update-branch` | overlap scans |
| ship-blocking REST writes | dashboard refreshes |
| operator-initiated rescue | cache reconcile per-PR fetches |

**Why it matters:** GraphQL exhaustion is multiple-times-per-day during fleet
peaks. Without criticality tags, a background dashboard poll can starve a
ship-blocking merge. With them, the merge fires, the poll waits.

## GraphQL exhaustion handling (INFRA-1040 / INFRA-1079)

Automated:
- **Secondary rate-limit self-throttle** — `chump_gh` caps to
  `CHUMP_GH_MAX_CALLS_PER_MIN` (default 60) across the fleet via a shared
  sliding window. Per-script override: `CHUMP_GH_THROTTLE_<UPPERCASE_SCRIPT>=N`.
- **Exhaustion signal** — first call to see `remaining_graphql ≤ 100` emits
  `kind=graphql_exhausted` to `ambient.jsonl` (debounced once per reset window).
  Every fleet agent reading ambient pivots to REST-only paths simultaneously.

Manual operator actions when you see repeated `graphql_exhausted` or
`gh_self_throttled` events:
- Run `scripts/dev/api-cost-leaderboard.sh --window 1h` to find the burner.
- Background-tag the noisiest non-critical caller via `CHUMP_GH_CALL_CRITICALITY=background`.
- If structural: file an INFRA-NEW-MIGRATE-<script>-TO-CACHE follow-up.

## Push routing — opt-in (FLEET-034, 2026-05-14)

Default work distribution remains **pull**: each worker polls `state.db`, picks
the first eligible gap, and claims atomically. That model degrades past ~30
workers (every worker performs O(open-gap) sqlite reads per cycle).

**Push tier (opt-in).** When NATS is reachable, run one `chump-coord assign`
daemon per fleet — it watches `state.db`, and for each `status:open` gap
publishes a `WorkEnvelope` to:

```
chump.work.<priority>.<class>.<machine>
   priority  P0 | P1 | P2 | P3
   class     derived from gap.skills_required (runtime, coord, docs, …),
             falling back to lowercased gap.domain. "any" if neither.
   machine   gap.preferred_machine if set, else "any"
```

Workers run `chump-coord worker` with capability env vars:

```bash
WORKER_SKILLS=rust,sqlite,macos WORKER_MACHINE=macbook WORKER_BACKEND=claude \
  chump-coord worker --subjects 'chump.work.>.runtime.macbook,chump.work.>.coord.>'
```

**Ack semantics.** First worker to win the existing NATS-KV atomic claim
(`try_claim_gap`) wins the lease — that *is* the ack. Lost-race workers fall
through and drain the next envelope. Worker death is detected via the existing
KV TTL on the claim key (`CHUMP_GAP_CLAIM_TTL_SECS`).

**Speculative override (INFRA-311).** A gap with `replicas: N` in `notes`
publishes N envelopes for the same gap; the first N workers to ack share the
race but only one wins the CAS — others discard.

**Offline fallback.** When `CHUMP_NATS_URL` is unset or the broker is
unreachable, **both** sides degrade cleanly: `chump-coord assign` logs the
condition and exits 0 (a supervisor can restart it on broker recovery), and
`chump-coord worker` exits 0 with a `falling back to pull loop` message so the
existing `scripts/dispatch/worker.sh` PULL path takes over without manual
intervention. **state.db remains the source of truth** in both modes — NATS
only routes the question of *which* worker should pick *which* open gap.

**Cognitive model.** The old docs implied "dispatcher dispatches"; in reality
the system pulls when offline and pushes when a broker is available. The push
daemon publishes hints; the pull-side atomic claim remains the authoritative
hand-off.

## Fleet scaling gate (INFRA-518)

Scaling fleet size is a deliberate stress test of prior-tier fixes. Each step-up requires the
previous tier to be stable; each step-down trigger must be respected without operator override.

### Scale-up criteria (all must hold)

| Metric | 2 → 3 workers | 3 → 4 workers |
|---|---|---|
| Waste rate (`chump waste-tally --window 2h`) | < 20 % | < 15 % |
| Ship rate (PRs merged / PRs opened, last 10) | ≥ 70 % | ≥ 80 % |
| `fleet_wedge` events in ambient.jsonl (last 2 h) | 0 | 0 |
| `silent_agent` events (last 2 h) | ≤ 1 | 0 |
| `pr_stuck` events (last 2 h) | ≤ 1 | 0 |
| Open INFRA gaps blocking fleet (P0/P1 kind=fleet) | 0 | 0 |

Run before any scale-up:
```bash
chump waste-tally --window 2h          # check waste rate
scripts/dispatch/fleet-status.sh       # check ship rate + agent health
tail -200 .chump-locks/ambient.jsonl | grep -E '"kind":"(fleet_wedge|silent_agent|pr_stuck)"'
```

### Logging requirement (mandatory)

Every scale-up **and** scale-down must emit to `ambient.jsonl`:
```bash
printf '{"ts":"%s","kind":"fleet_scale_change","from":%d,"to":%d,"rationale":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <old_size> <new_size> "<reason>" \
  >> .chump-locks/ambient.jsonl
```

### Back-off triggers (immediate, no debate)

- **`fleet_wedge` event appears** → drop to 2 workers; hold until 0 wedges for 30 min.
- **`silent_agent` count > 1 in 1 h** → drop to 2 workers; investigate picker/lease race.
- **`pr_stuck` cluster (≥ 3 in 2 h)** → drop to 2 workers; diagnose bot-merge contention.
- **Waste rate > 30 % at any size** → drop to 2 workers; file a gap for the dominant waste kind.
- **CI failure rate > 25 % (last 8 PRs)** → hold current size; do not scale up until resolved.

### Rollback procedure

```bash
# 1. Kill excess workers (tmux pane names fleet-worker-N)
tmux kill-pane -t fleet-worker-<N>
# 2. Release orphaned leases
ls .chump-locks/*.json | xargs -I{} chump --release --lease {}
# 3. Log the scale-down (see Logging requirement above)
# 4. Update FLEET_SIZE in run-fleet.sh invocation or env
```

Full retrospective: [`docs/syntheses/fleet-scaling-2026-05-06.md`](./docs/syntheses/fleet-scaling-2026-05-06.md)

## MISSION-PM: gap registry health (META-046)

Run `chump gap audit-priorities [--json]` to get a PM health snapshot.
Exits non-zero if **P0 count > 5**, any **open P0 stuck > 7 d**, or any
**vague (no AC) pickable gap** exists.

Metrics reported:

| Metric | Meaning |
|---|---|
| P0 count + ages | Open P0 gaps and how long they have been open |
| Vague pickable | Open gaps with no acceptance_criteria — unpickable in practice |
| Double-encoded depends_on | `depends_on` stored as JSON-string-of-JSON — import bug |
| Missing-dep refs | `depends_on` entries pointing at non-existent gap IDs |
| Open with closed_pr | status:open but closed_pr set — needs `chump gap ship` |
| race-* test pollution | Open gaps with title starting `race-` — test fixture leak |

Incorporate into the pre-ship checklist for any gap that touches the registry
or picker logic:

```bash
chump gap audit-priorities          # non-zero = stop and fix
```

CI gate: `scripts/ci/test-gap-audit-priorities.sh`

## On-demand docs (read only when you hit the failure surface)

- **Orientation — read once to understand what this repo *actually is*** (cross-cutting capability synthesis, the credibility discipline of claimed-vs-verified, the negative space bucketed scans miss, and the keystone that unlocks productization): [`docs/CODEBASE_REALITY_MAP.md`](./docs/CODEBASE_REALITY_MAP.md) (DOC-068)
- PWA design-system style guide — token reference (dark/light/high-contrast), full `chump-*` component inventory, composition rules (header/footer/view-chrome/overlay), mobile breakpoints, a11y minimums: [`docs/design/PWA_STYLE_GUIDE.md`](./docs/design/PWA_STYLE_GUIDE.md) (INFRA-1593). Read before touching `web/v2/**`.
- Ship-assist playbook — wedge taxonomy (7 classes), tooling inventory, decision flow for picking the right rescue tool, top-3 highest-leverage missing gaps, reliability lessons: [`docs/process/SHIP_ASSIST_PLAYBOOK.md`](./docs/process/SHIP_ASSIST_PLAYBOOK.md) (INFRA-2256)
- bot-merge doc-only fastpath observability — events emitted on success (no failure/timeout class exists — detection is a pure local `git diff` classification), cost tracking, failure-class taxonomy, smoke test command: [`docs/process/BOT_MERGE_DOC_ONLY_OBSERVABILITY.md`](./docs/process/BOT_MERGE_DOC_ONLY_OBSERVABILITY.md) (INFRA-920)
- Subagents, fleet launcher, disk hygiene, operational gotchas (binary wedge, rebase footgun, syspolicyd, etc.): [`docs/process/CLAUDE_GOTCHAS.md`](./docs/process/CLAUDE_GOTCHAS.md)
- Subagent dispatch: model defaults, no-clarifying-questions directive, shipping epilogue, WIP-rescue: [`docs/process/SUBAGENT_DISPATCH.md`](./docs/process/SUBAGENT_DISPATCH.md)
- Script taxonomy, canonical tool per task, entry points per directory: [`scripts/README.md`](./scripts/README.md)
- Coordination script entry points, decision guide, full coord/ reference: [`scripts/coord/README.md`](./scripts/coord/README.md)
- A2A frontier roadmap — six layers from NATS-primary delivery to signed provenance, mapped onto today's chump-coord primitives: [`docs/design/A2A_ROADMAP.md`](./docs/design/A2A_ROADMAP.md) (META-061; sub-gaps INFRA-1118 through INFRA-1123)
- Integration-cycle ship pipeline — strategy + architecture for batched fleet output (Mode A/B/C/D), bisect-on-red, migration phases, and metrics: [`docs/strategy/INTEGRATION_CYCLE_2026-05-29.md`](./docs/strategy/INTEGRATION_CYCLE_2026-05-29.md)
- Disk-aware fleet — 4-layer architecture (inventory daemon / cost model / `chump disk plan` / adaptive scaler), 4-wave migration, open questions: [`docs/strategy/DISK_AWARE_FLEET_2026-05-29.md`](./docs/strategy/DISK_AWARE_FLEET_2026-05-29.md) (META-128)
- `chump voice` — file voice-of-agent signals (VOA) to surface friction, mistakes, or emergent patterns without filing a formal gap: [`docs/process/VOICE_OF_AGENT.md`](./docs/process/VOICE_OF_AGENT.md)
- `chump scratch` — shared ephemeral state for multi-agent coordination (session-scoped `.chump-locks/scratch` KV store): [`scripts/coord/scratch.sh`](./scripts/coord/scratch.sh) (`chump scratch get|set|del <key>`)
- `chump claim --discard-wip` — safe-destroy flag to abandon a WIP claim and release the lease for others to pick: [`docs/process/SHIP_ASSIST_PLAYBOOK.md`](./docs/process/SHIP_ASSIST_PLAYBOOK.md) (INFRA-2235; CLAIMING_DISCIPLINE.md never shipped)
- Voice-lint policy and curator role docs — curator role docs (`.claude/agents/ci-audit.md`, `.claude/agents/handoff.md`, `.claude/agents/target.md`) define lane scope + discipline for CI, handoff, and demo-target curators: [`.claude/agents/`](./.claude/agents/)
- The Harvester (fleet cartographer) — catalogs load-bearing primitives across the repairman29 fleet so Chump never re-implements what already exists. Three equivalent surfaces: `chump harvest <scan|check|brief|deep-scan|list-clusters>` (INFRA-1823, harness-neutral CLI — the productized capability, wraps `scripts/arsenal/harvest.sh`), the `harvester` skill (`/harvester`), and the `.claude/agents/harvester.md` curator agent. `chump gap decompose` calls `chump harvest check` internally as a pre-flight and cites any prior-art overlap in the sub-gap's notes. Full surface + exit codes: [`docs/arsenal/HARVESTER.md`](./docs/arsenal/HARVESTER.md)
