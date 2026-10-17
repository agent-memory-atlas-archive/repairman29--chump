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
| **R3** | Honest ship gate: every check is required-and-green or deleted; admin bypass needs a PASSED consensus; `enforce_admins` and `strict` on; admin merges counted. | Red checks carrying no information; invisible `--admin` merges | CREDIBLE-1492 | P1 |
| **R6** | The invariant boundary. Rust owns invariants (store, leases, gap status, the ship transition, admission); shell owns glue and may stay shell. A CI gate fails any shell that writes an invariant directly; `chump` verbs are the shortest path; agent matched to layer. Metric: shell files that write invariants, target zero. | Picker sprawl (MISSION-028); 9 scripts writing the store and a dozen writing leases on main (2026-10-17 baseline); Rust-first honored by a bypass trailer | INFRA-8195 (slices R6.1 gate, R6.2 `chump admit`, R6.3 layer-aware dispatch, R6.4 gauge) | P1 |
| **R4** | One canonical store. `state.sql` and `gap_store.db` leave git; the YAML mirror is export-only; the swamp is archived, never deleted. | Split-brain drift; the 9,223-file swamp; `sync --push` blast radius | INFRA-8193; INFRA-8190 landed: one resolver (`crates/chump-store-path` + `scripts/coord/lib/state-store.sh`: `CHUMP_STATE_DB` > main checkout's `.chump/state.db` > root), hard single-source gate (`gap-store-single-source-check.sh` check C) | P2 |
| **R5** | Host provisioning is a typed enum; units are rendered from it; no `User=`, `/home`, `/root`, `/opt/homebrew` literals ship. | 217/USER failures, HOME=/root, the abandoned second install, brew-only bootstrap | INFRA-8194 | P2 |
| **R7** | The eval harness points inward. Every self-report has a ground-truth probe and a calibration score; chronic liars auto-file a gap. | Dashboards off by 6x to 100x; "healthy" while organs fail for days | CREDIBLE-1493 | P2 |

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

**The honest metric for the whole program.** One gap filed, dispatched, built, merged
and flipped to shipped by the fleet with zero admin merges and zero human terminal.
Until that happens once, the factory is not running. R1 plus R3 is the gate to it.

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
