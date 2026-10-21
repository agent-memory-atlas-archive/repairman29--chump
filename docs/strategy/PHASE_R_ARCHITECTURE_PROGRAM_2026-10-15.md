---
doc_tag: decision-record
owner_gap: PHASE-R
last_audited: 2026-10-17
---

# Phase R: the architecture program of record (adopted 2026-10-15)

**Decision (Jeff, 2026-10-15):** Phase R from `~/Projects/FLEET_ROADMAP.md` is the
architecture program of record for ChumpOS, in the order below, with R6 and R7 added.
Outcome `PHASE-R` on the canonical store rolls up the seven gaps. Work starts at R1 and
R3, the ship gate. This document is the architect's statement of *what* and *why*; the
gaps carry the acceptance criteria and get decomposed at claim time.

**The one sentence.** Every recurring failure in this fleet has the same root: the rule
lives in a doc, a memory, or a retro (a reminder) instead of in a type or a state
machine (a constraint), and reminders lose to pressure. Phase R moves the rules that
keep breaking into code that cannot be argued with.

## What the measurement said (2026-10-15, receipts in each gap)

| Gauge | Reading |
|---|---|
| Rust | 349k LOC, 46 crates, `src/main.rs` 22.8k lines |
| Shell | 414k LOC, 2,661 scripts, 1,590 of them `scripts/ci/test-*.sh` |
| Organs | 107 systemd units, about 81 launchd plists |
| Required check on `main` | one (`verified`); `enforce_admins=false`, `strict=false` |
| Last 30 merged PRs with a red check | 26 (the INFRA-849 integration test, outside `verified`) |
| PR merged with `verified` itself red | #5466, by the fleet token, via `pr-shepherd-daemon.sh --admin` |
| Admin merges reported by `floor_temp` that day | 0 |
| Lease writers | 5 pickers (3 Python, 1 Rust, 1 HTTP); the worker bypasses `chump claim` |
| Gap representations | 6 (state.db, 4,192 YAML, tracked 23.9 MB state.sql, PostgREST, Supabase, empty gap_store.db) |
| Uncommitted files on the canonical checkout | 9,223 |
| Worker inference | Claude subscription, `FLEET_MODEL=sonnet`, one token; no ladder, no cascade |

The data plane is Rust. The control plane, the part that decides what is picked,
claimed, shipped and merged, is bash and Python. That is why invariants have nowhere
to live.

## The program, in order

| | Invariant | Kills | Gap | Priority |
|---|---|---|---|---|
| **R1** | Ship is one state transition gated on a landing receipt: a merge SHA reachable from `origin/main` whose PR row links the gap. One function writes `done`/`shipped`. Idempotent. | The re-ship loop (RESILIENT-1562 shipped 87 times in 2h, landing nothing); the false-close class | CREDIBLE-1491 | P1 |
| **R2** | The gap-to-PR link is a typed FK written when the PR opens, read at ship. No title regex anywhere. | `fix(X:)` closing gap X (#5317); three regex readers drifting | INFRA-8192 | P1 |
| **R3** | Honest ship gate: every check is required-and-green or deleted; admin bypass needs a PASSED consensus; `enforce_admins` and `strict` on; admin merges counted. **`strict=true` restored 2026-10-18 between 00:17:56Z and 00:19:02Z** (read back false then true by the architect via `gh api .../branches/main/protection`). It had been off since 2026-10-17 15:20Z for the landing window, and the trigger was zero armed PRs waiting on CI after #5573 merged. The architect's PATCH was refused by its session classifier, and the operator's two attempts failed in gh ("unexpected end of JSON input"); the Chief session applied it. Slices: CREDIBLE-1522/1523 (AC1), CREDIBLE-1524 (AC3+4), CREDIBLE-1525 (AC5), CREDIBLE-1502 (AC2, done), CREDIBLE-1521 (main `verified` on push). | Red checks carrying no information; invisible `--admin` merges | CREDIBLE-1492 | P1 |
| **R3 measurement** (CREDIBLE-1512, hosted-runner starvation) | The honest ship gate is only honest if a green check is *reachable* — under `strict=true` every main merge requeues every armed PR, and the hosted-runner pool could not keep up. Measured 2026-10-17 04:58Z: **22 runs queued, 1 job running, ubuntu-latest pickup 20-40 min, GitHub status clean**; re-measured 12:38Z: **32 queued**; and again ~13:11Z via `chump kpi report --ci-pickup`: **62 runs queued, pickup p95=543s (9m), max=1011s (16m), p50=0** (survivorship — fast jobs complete, starved jobs still queued; `ci_runs_queued` is the leading signal). Fix shipped: PR-event CI runs cut cargo-test shards 4→2, audit shards path-filtered per lane, pwa e2e gated to its own paths; `kind=ci_runner_starved` fires when trailing-30m p50 pickup > 10m. Capacity options A/B/C + recommendation: [`docs/process/CI_RUNNER_CAPACITY.md`](../process/CI_RUNNER_CAPACITY.md). | ubuntu-latest `runner=none` for 20-40m while status reads green; landings gated on runner pickup | CREDIBLE-1512 | P1 |
| **R6** | The invariant boundary. Rust owns invariants (store, leases, gap status, the ship transition, admission); shell owns glue and may stay shell. A CI gate fails any shell that writes an invariant directly; `chump` verbs are the shortest path; agent matched to layer. Metric: shell files that write invariants, target zero. **Receipt 2026-10-18 (RESILIENT-1636), the class R6 exists for:** an invariant decided in shell blocked the ship path. On cuphead, bot-merge's `chump claim` was refused by the farmer RED gate (oauth-token.json stale with no Linux refresher; the farmer heartbeat stale because the farmer is paused by owner decision), and bot-merge exited 1 printing nothing. So since 2026-10-16 every cuphead dispatch implemented but never shipped through bot-merge; all chain landings went through salvage. The fix moves the decision into the Rust gate: it validates the real credentials, reports a paused farmer as PAUSED, refuses new worker claims and never refuses the ship step of claimed work. | Picker sprawl (MISSION-028); 9 scripts writing the store and a dozen writing leases on main (2026-10-17 baseline); Rust-first honored by a bypass trailer | INFRA-8195 (slices R6.1 gate, R6.2 `chump admit`, R6.3 layer-aware dispatch, R6.4 gauge) | P1 |
| **R4** | One canonical store. `state.sql` and `gap_store.db` leave git; the YAML mirror is export-only; the swamp is archived, never deleted. | Split-brain drift; the 9,223-file swamp; `sync --push` blast radius | INFRA-8193; INFRA-8190 landed: one resolver (`crates/chump-store-path` + `scripts/coord/lib/state-store.sh`: `CHUMP_STATE_DB` > main checkout's `.chump/state.db` > root), hard single-source gate (`gap-store-single-source-check.sh` check C); INFRA-8222: `chump store reconcile` merges a node's stale home store into the live one before the pin flips (newest-wins, terminal-status guard). INFRA-8193 slice 1 landed: `state.sql`, `state.sql.lz4`, `gap_store.db` out of git; claim/preflight state.sql self-heal and the state.sql merge driver removed; reserve's canonical max reads the private registry only; `gap sync --pull` is a hard error; export-only gate `test-gap-yaml-export-only.sh` (allowlist may only shrink). Slice 2: archive the YAML tree on cuphead + reconcile stores (INFRA-8222). Slice 3: retire the postgrest backend code paths. | P2 |
| **R5** | Host provisioning is a typed enum; units are rendered from it; no `User=`, `/home`, `/root`, `/opt/homebrew` literals ship. | 217/USER failures, HOME=/root, the abandoned second install, brew-only bootstrap | INFRA-8194 (slice 1 landed: `Host` enum + detector + `chump node host`/`render-unit` in crates/chump-provision; 39 dispatch units incl. gap-close-decomposed and organ-watchdog are placeholder templates with no `User=`; manifest `run-scope=`; no-host-literal CI gate with a dated shrink-only allowlist of 188 files. Slice 2 landed: allowlist 188 -> 3. All 23 dispatch files, 33 launchd/ plists, 24 scripts/plists and 105 of 108 setup files are clean: every unit and plist is a placeholder template, every installer that places one renders it (`chump_render_template`, scripts/lib/host-paths.sh), a fifth placeholder `__BREW_PREFIX__` plus `chump node host --field brew-prefix` replaces the baked Apple Silicon prefix, the gate and `find_host_literals` skip comment lines (not shebangs), and root-only organs are declared by name (`KEEP_ROOT_UNITS`) instead of a baked `User=root`. Setup classification: (a) resolver/env 102, (b) doc/comment 3, (c) named-host 3. Slice 3 landed (INFRA-8571): `organ_unit_host_rewrite` (scripts/ops/lib/organ-unit-install-lib.sh) dropped the four legacy source-home sed rules (`/Users/<name>`, `/home/<name>`, bare-`$HOME`, `User=<name>`) — the rewriter is now placeholder-in, host-resolved-out, and a src carrying a host literal is REFUSED loudly (shell mirror of `render`'s `RenderError::HostLiterals`) instead of silently patched, so the no-host-literal gate is the only path; node-converge.sh carried no such sed rules (it delegates placement to chump-node-install.sh → the shared rewriter), so nothing to delete there. run-scope tags extended beyond organ-deploy to the nine `housekeeping=` loop-services (install-node-housekeeping.sh places them into /etc/systemd/system via sudo on every node, never a --user manager → `run-scope=system`). New manifest-driven render sweep (`manifest_units_render_right_on_every_host`, crates/chump-provision) renders all 45 tracked manifest units on linux-systemd-user / linux-systemd-system / mac-launchd asserting zero literals + the right User= lines (none at user scope, `User=root` for keep-root organ-deploy, else the run user at system scope; HostMismatch on launchd). Remains: the (c) set (claude-proot-guest.sh on pixel, install/uninstall-do-droplet-runner.sh on the DO droplet, each with a reason on its allowlist line)) | P2 |
| **R7** | The eval harness points inward. Every self-report has a ground-truth probe and a calibration score; chronic liars auto-file a gap. **Slice 1 landed (2026-10-17):** `docs/observability/SELF_REPORTS.yaml` (16 pairs), `chump calibrate` (`src/commands/calibrate.rs`, emits `kind=self_report_calibration`), the score line in `fleet brief` and `kpi report`, nightly `chump-self-calibrate.timer` (role=trust). **Slice 2:** auto-file a CREDIBLE gap after 3 consecutive nights of disagreement on one pair; replay the 2026-10-15 cases as fixtures. | Dashboards off by 6x to 100x; "healthy" while organs fail for days | CREDIBLE-1493 | P2 |

**Why this order (revised 2026-10-16).** R1 and R3 first because until a merge means
"tested and landed," nothing else the fleet reports can be trusted, and nothing it builds can
be proven to have shipped. R2 is R1's precondition for the receipt. **R6 moved to third** after
the night of 2026-10-15/16: the fleet wrote correct fixes for every gap it was given and lost the
finished work ten different ways in the bash ship path (orphaned child, expired lease taken as
identity, HEAD lock race, pre-push kill, budget kill, lost session id, `gh pr create` without
`--head`, uncommitted work left behind, a vacuous-guard line cap, and a picker that re-opened the
same slice four times because it bypasses `chump claim`). Four of those are already fixed as
fleet-authored PRs (INFRA-8204, 8207, 8202, 8201); the class only ends when the ship path lives
in types. R4 and R5 follow: they remove the two sources of recurring drift (the store and the
host). R7 is how we know the first six are true without a human reading logs.

**Receipts from the first night.** Trunk unwedged through `verified` (#5476), `enforce_admins`
and `strict` on with a baseline and drift gate (#5479), and at 06:20Z the first gap filed, built,
merged and closed by the fleet with no human terminal (INFRA-8204, #5481). Zero admin merges.

**R3 receipt, 2026-10-17 14:25Z (ZERO-WASTE-135).** During a hosted-runner stall (0 jobs running,
47 non-completed runs) the queue held 14 queued `verified-recompute` runs on main, 3
`pr-triage-bot` and 2 CI Flake Rerun; the architect cancelled 15 duplicates by hand and the queue
fell to 33. Of the 19 workflows triggered by `workflow_run` or `schedule`, 18 already declared a
`concurrency:` block, so the defect was the group key (per-run or per-upstream-sha keys never
dedupe), not a missing block. Fixed in the same gap: stable keys on `verified-recompute`,
`pr-triage-bot`, `repo-health`, `ftue-cold-install`, `integrations` (schedule leg), a block on
`coverage-nightly`, and `scripts/ci/test-workflow-concurrency-groups.sh` (fast-checks and
`chump preflight`) so a per-run key on any `workflow_run`/`schedule` workflow fails CI. Depth:
structural only; it checks the key is stable, not that it is the right one.

**Train receipt, 2026-10-17 20:08Z (merge `47ecda326`, PR #5561).** With the hosted runners
serving a handful of jobs an hour and `strict=true` requeuing every armed PR on each main
landing, 29 fleet PRs sat BLOCKED for most of a day. The architect built one integration branch
from 18 of them (61 commits, later 78 with the fixes), opened it as #5561, cut the 18 component
PRs with `pr-cut` after the merge, and shipped 22 gaps against the train on the node:
PRODUCT-382, CREDIBLE-1496/1499/1509/1511/1513/1514/1493, RESILIENT-1606/1607/1609/1611,
INFRA-8176/8193/8194/8199/8208/8209/8211/8223/8570, ZERO-WASTE-134/135. PHASE-R rollup 52% →
80% (60 of 75). Five CI rounds were needed, each a one-step failure that only CI could see:
the bypass-var debt ceiling (a new `*_NO_GATE` env var, now a `--no-gate` flag), shellcheck
SC2002 in `load-aware-deadman.sh`, two rounds of PyYAML-illegal scalars in
`EVENT_REGISTRY.yaml` (a backtick from #3472 and 24 multi-line plain scalars with `: ` inside,
caught by the new union merge driver because it is the first gate to parse the registry), and
an export-only detector whose `grep -q` pipelines went blind under `pipefail` on GNU grep.
Receipts: classes 28-32 in the ship-path measurement. Zero admin merges. Still open after the
train (13): R6 ×5 (INFRA-8195, RESILIENT-1604/1615/1616/1617), R3 ×4 (CREDIBLE-1492/1516,
INFRA-8203, ZERO-WASTE-133), R1 (CREDIBLE-1491), R5 (INFRA-8571), R7 slice 2, plus the
R6 shell-absorption umbrella. The second train is #5566 (CREDIBLE-1506) and the chain v8/v9
PRs (CREDIBLE-1516, RESILIENT-1617, RESILIENT-1615, RESILIENT-1616, INFRA-8571).

**Opus window receipt, 2026-10-17 21:15Z to 2026-10-18 00:20Z (handoff from the Fable session).**
Eleven PRs landed one at a time with zero admin merges, and each gap was shipped on the node with
`chump gap ship --closed-pr`:
#5569 ZERO-WASTE-133, #5571 CREDIBLE-1516, #5572 RESILIENT-1617, #5574 CREDIBLE-1518,
#5576 RESILIENT-1604, #5577 RESILIENT-1615, #5570 RESILIENT-1608, #5578 RESILIENT-1616,
#5575 CREDIBLE-1491 (R1 umbrella: one receipt-gated writer; gap-doctor Bucket 2 now goes through
it, and the INFRA-308 test was rewritten to assert the refusal), #5573 INFRA-8203, and #5579 INFRA-8571
(R5 slice 3).
- **Rollup:** PHASE-R went from 63 of 76 done to 72 of 93 (77%). The total grew because every finding
  became a linked gap.
- **R1 AC2 is only half met** (merge SHA yes, typed FK no). Filed as CREDIBLE-1520 rather than
  reopening INFRA-8192.
- **Umbrellas sliced by hand** (decompose has no provider on cuphead, INFRA-8573): CREDIBLE-1492
  into CREDIBLE-1522..1525, and INFRA-8195 into INFRA-8574..8577.
- **Ship-path classes found:** classes 33-40 in the ship-path measurement.
- **Two PRs went DIRTY twice** on the union-driver class and were landed by local merges with
  the fixed driver (#5570, #5573).
- **Main protection:** `strict=true` restored 00:19Z (see the R3 row).
- **Chains:** v10 (RESILIENT-1619, CREDIBLE-1520 AC1, RESILIENT-1618, CREDIBLE-1519,
  RESILIENT-1620, INFRA-8573) and v11 (the eight umbrella slices) run on cuphead, one claude at
  a time.

**Opus window, continued (2026-10-18 05:15Z to 16:00Z).**
- **Silent gap:** the Mac hibernated from 05:15Z to 14:50Z, and the session-only loop stopped while chain v11 kept landing work on cuphead (#5588 INFRA-8574, #5591 INFRA-8576, #5592 INFRA-8577, #5597 RESILIENT-1624). Then #5590 CREDIBLE-1524 landed at 15:21Z. The loop becomes an organ under RESILIENT-1634.
- **Phase 1 un-pause** (operator, 2026-10-18 15:30Z): ci-flake-rerun, gap-close-decomposed (unit re-rendered) and next-best-action (advisory producer only) are ON in the ubuntu user scope. **chump-armed-pr-rebaser is DROPPED from the un-pause start list (Chief ruling 2026-10-21, CREDIBLE-1599):** the review organ now reconciles its OWN approved-but-unmergeable heads inline — a BEHIND head gets `update-branch` with `expected_head_sha`, a DIRTY shell-only head gets the shell-only rebase (`gh pr update-branch --rebase`), a DIRTY Rust head is held — and the updated head re-arms next tick without a fresh review when its PR-diff patch-id is unchanged, so the standalone rebaser (which this slice makes redundant) is no longer on the start path and the RESILIENT-1632 one-per-tick-cap precondition no longer gates un-pause. The user-scope conductor is a dry-run self-rescue loop, not a dispatcher. nba-dispatch stays in phase 2 because its allow-list revives workers. Phase 2 preconditions: CREDIBLE-1526, INFRA-8583, INFRA-8588, INFRA-8592, CREDIBLE-1550.
- **Delegated review:** escalated PRs are approved by an independent read-only Opus reviewer (operator, 05:20Z); #5587 was the first.
- **False closes:** CREDIBLE-1492 (reissued as CREDIBLE-1549) and CREDIBLE-1520 (AC2-4 continue under CREDIBLE-1550) were closed by title match. R1 held, R2 failed (receipts classes 42-43).
- **Rollup at 16:00Z:** the store reads 85 of 133; the **honest figure is 83 of 133 (62%)**, two fewer for the false closes. The total grew from 76 because findings and the umbrellas' missing-AC slices were filed, including observation slices with start conditions and probes (CREDIBLE-1546..1548, INFRA-8590/8591).
- **18:15Z:** all five red chain-v11 PRs landed one at a time under strict=true, each repaired by a fleet lane: #5589 CREDIBLE-1522, #5590 CREDIBLE-1524, #5593 CREDIBLE-1525, #5594 CREDIBLE-1523, #5596 INFRA-8575. The reconcile organ shipped CREDIBLE-1522, CREDIBLE-1524, CREDIBLE-1525 and INFRA-8575 itself, with no hand ship, once the node checkout was clean of regenerated lock files (RESILIENT-1637: 212 ship_autofetch_blocked_dirty events across 39 gaps since 2026-10-17T20:13Z). Rollup: store 89 of 136, **honest 87 of 136 (64%)**.

**The honest metric for the whole program.** One gap filed, dispatched, built, merged
and flipped to shipped by the fleet with zero admin merges and zero human terminal.
Until that happens once, the factory is not running. R1 plus R3 is the gate to it.

## R7 slice 1: what the first calibration said (2026-10-17, Mac observer)

`chump calibrate` on the operator's Mac: **12/16 agree, 2 disagree, 2 unprobed** (score 0.75).
The two disagreements were real on that host: fleet-doctor's `dirty-prs` reads the
`github_cache.db` mirror and said pass while GitHub had DIRTY PRs older than 24h, and the kpi
ship gauge read 0 ships in 1d against 31 merges (the Mac's store is stale). The run also found
`chump kpi report --json` emitting invalid JSON (unescaped `depends_on` arrays in the dependency-count
section), fixed in the same PR. The two unprobed pairs need systemd (organ failures); they run
on the Linux nodes. Unprobed pairs stay in the denominator and never count as agreement.

Slice 2 (not landed): a pair that disagrees three nights running files a CREDIBLE gap naming the
instrument and its receipt; the 2026-10-15 cases (floor-temp admin merges vs #5466, the
stale-root-binary deploy reading, fleet-brief healthy over failed organs) replay as fixtures so
the calibration itself is regression-tested against the incidents that motivated it.

## Rules while Phase R runs

1. **Constraint over reminder.** If a fix is "update the doc so agents remember," it is
   not done. The fix is the type, the gate, or the test that makes the mistake
   impossible, with the doc as commentary.
2. **No new shell organ.** A new `.sh` under `scripts/dispatch` or `scripts/coord` that
   defines an organ needs the META-064 `Rust-First-Bypass:` trailer and a one-line reason.
3. **Signals get consumers or get deleted.** An emitted kind with no organ acting on it
   is noise that proves the OS knew (RESILIENT-1603).
4. **Decommissioned means removed.** An organ ratified dead is uninstalled by converge
   and asserted absent by roll-call (RESILIENT-1600).
5. **Archive, never delete.** R4's cleanup goes to `refs/stash` per
   `docs/process/STASHED_WORK.md`.
6. **Decompose at claim, not at filing.** The seven gaps carry rough shapes; slices are
   cut against the live codebase when claimed.
7. **Measure on the node.** The Mac is an observer. Scoreboard, store and organ facts
   come from cuphead.

## R6 redefined (2026-10-17): force the boundary, not the language

The first day proved that "Rust-first" as a blanket rule loses to pressure: 414k lines of shell
against 349k of Rust, the META-064 gate honored by a one-line bypass trailer, and every
Rust-touching Sonnet dispatch on 2026-10-16 dying at the budget or in the ship step while
shell dispatches landed. Agents take the shortest path to green. So R6 now forces the boundary:

1. **Rust owns invariants, shell owns glue.** `state.db`, lease files, gap status, the ship
   transition and the admission ceiling are Rust. Installers, `gh` plus `jq` plumbing and one-shot
   ops may stay shell forever. META-064's criteria stand; the all-Rust aspiration is dropped.
2. **The boundary is a CI gate (R6.1), not a doc.** Any shell or Python under `scripts/` that
   writes the store, a lease, or a status directly fails CI. Shadow mode first with the violator
   list; enforce once the verbs exist. The allowlist starts at the dated baseline and may only shrink.
3. **The Rust verb is the shortest path.** `chump admit` (R6.2), `chump pr cut` (RESILIENT-1607),
   `chump gap link-pr` (R2), one lease-writing verb (INFRA-8176). A shell organ becomes a few lines
   calling a verb, and the shell shrinks on its own.
4. **Agent matched to layer (R6.3).** Rust slices dispatch with Opus and a 3600 second budget into
   a small crate; shell glue dispatches with Sonnet.
5. **The metric is `shell_invariant_writers` (R6.4),** the gate's violator count, target zero for
   seven days. Shell LOC is no longer the measure. Baseline 2026-10-17 on `main`: 9 scripts write
   the store (`bot-merge.sh`, `gap-reserve.sh`, `gap-doctor.py`, `gap-normalize-domains.sh`,
   `backfill-opened-dates.sh`, both stale reapers, a demo, a CI fixture lib), about 12 write lease
   files, 2 set status by raw SQL.

   **Gauge (CREDIBLE-1509, R6.4):** `chump kpi report` carries a
   `shell_invariant_writers` section, also shown alone by `chump kpi report
   --shell-invariant-writers` and in the `fleet-brief` banner. It prints the
   gate's violator file count (`count` on the `kind=invariant_boundary_violation`
   line that `scripts/ci/test-invariant-boundary.sh` prints and records in
   ambient) plus the reading date. A reading under 24h old is reused; otherwise
   the report runs the gate (~20s); the banner never runs it.
   **Baseline 2026-10-17:** 9 store-writing files (enumerated above). The gate
   itself, run in shadow mode on `main` at 40ba8db02 the same day, flags **39
   files**: the store writers plus lease-file and status writers and some
   broad-pattern hits (installers). The gauge reports the gate's number, so 39
   is its starting reading; target 0 for seven days.

## Explicitly not in Phase R

- The AI layer (ladder, cascade, local inference, the sovereignty of the mind). The
  documented DeepSeek ladder and the live Claude-only fleet disagree; that is a separate
  decision for the owner, not an invariant to enforce. It gets its own program once R1
  and R3 land.
- Product work (Olive, Froogle, the living stack). Phase R makes the factory honest; it
  does not point it.
- Queue size. The 3,826 machine slices are dissolved by Phase 3 of the fleet roadmap,
  not worked by hand.

## Provenance

Measured 2026-10-15 from the cuphead canonical checkout, `gh api`, and a read-only code
map of the worktree. Precedents already on `main`: RESILIENT-1592 R1 slice (d1d12ba23),
R2 slice (#5344), INFRA-7760 (#5459/#5460). Open related work: META-195
(admin-merge-by-consensus), INFRA-8184 (the integration test assumes ship without a
receipt), MISSION-028 (picker sprawl), INFRA-8049 (the second `/root` install).
Companion docs: `docs/CODEBASE_REALITY_MAP.md`, `docs/architecture/CANONICAL_GAP_STORE.md`,
`~/Projects/FLEET_ROADMAP.md`.
