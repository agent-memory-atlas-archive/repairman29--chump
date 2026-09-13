---
doc_tag: contract
owner_gap: INFRA-766
last_audited: 2026-05-11
---

# Canonical State Contract

This document names every place gap-registry and coordination state lives,
declares which store is authoritative for each fact, enumerates the drift
modes that have actually been observed in production, and specifies the
single reconciliation contract that prevents them.

It exists because three separate gaps were filed during one rescue session
(2026-05-11) — [CREDIBLE-028](../gaps/CREDIBLE-028.yaml),
[CREDIBLE-029](../gaps/CREDIBLE-029.yaml),
[INFRA-825](../gaps/INFRA-825.yaml) — that are all symptoms of one
underlying problem: nobody had written down which store wins when they
disagree. Implementers were patching individual drift modes as they
surfaced. This doc gives those gaps a shared target, and it's the
specification [INFRA-766](../gaps/INFRA-766.yaml) (state-drift detector)
implements.

## 1 — The stores

Six places gap-registry / coordination state lives. Five are co-located
in the repo; one is the GitHub remote.

| # | Store | Path | Schema | Role |
|---|---|---|---|---|
| 1 | **state.db** | `.chump/state.db` | SQLite (gaps, leases, intents, gap_counters, routing_outcomes) | **Canonical live state.** All writes go here first. |
| 2 | **state.sql** | `.chump/state.sql` | SQL dump of state.db | **Tracked mirror.** Committed; the rebuild source if state.db is corrupt. |
| 3 | **per-gap YAMLs** | `docs/gaps/<ID>.yaml` | YAML, one file per gap | **Human-readable mirror.** Reviewed in PRs; what PR authors edit. |
| 4 | **legacy monolith** | `docs/gaps.yaml` | YAML, all gaps in one file | **Deprecated mirror.** Still read by some CI scripts for backward compat. |
| 5 | **lease files** | `.chump-locks/*.json` | JSON per session | **Live lease bookkeeping** for active claims, mirrored from `leases` table. |
| 6 | **origin/main** | GitHub | git tree | **Cross-session canonical** — the only store all sibling agents can see. |
| 7 | **fleet-server `/api/gap`** | HTTP, `127.0.0.1:<port>` | N/A (not a store) | **Delegated write path** (INFRA-3689) — not itself authoritative; it shells `chump gap reserve\|set\|ship` against store #1 on the machine it runs on. Exists so a non-canonical client can write #1 without holding a writable local copy of it. |

`state.db` tables and their purposes:

| Table | Purpose | Canonical for |
|---|---|---|
| `gaps` | One row per gap with id, domain, title, status, AC, etc. | All gap content |
| `leases` | Active claims (session → gap) with expires_at | Who's working on what right now |
| `intents` | History of declared file-touch intents per (session, gap) | Conflict detection across sibling sessions |
| `gap_counters` | Per-domain next-free ID counters (e.g., INFRA=826) | ID allocation |
| `routing_outcomes` | Worker-dispatch outcomes (success / fail / waste) | Fleet-quality telemetry |

## 2 — Canonical authority

**For every fact, one store wins.** When stores disagree, the canonical one
is correct and the others must be reconciled to it.

| Fact | Canonical store | Mirrors that must follow |
|---|---|---|
| Gap content (title, status, AC, closed_pr, …) | **state.db** | state.sql, per-gap YAML, legacy monolith |
| Active lease (who owns gap X right now) | **state.db.leases** | `.chump-locks/<session>.json` |
| Next-free gap ID for domain D | **state.db.gap_counters**, intersected with **origin/main** open PR branches | local `chump gap reserve` output |
| Closed-state of a PR | **GitHub** (`gh pr view`) | `gaps.closed_pr` + `gaps.status` |
| Worker model + harness running a gap | **ambient.jsonl** (`kind=session_start` + first claim) | derived metrics |

Two of these are non-obvious and load-bearing:

- **Gap content is authored in the YAML at PR-review time but lands in
  state.db at merge time.** Pre-merge, the YAML on the PR branch is the
  proposal; merge promotes it. Post-merge, the row in main's state.db is
  truth, and any locally-stale YAML is wrong.

- **ID allocation needs *both* state.db and origin/main.** state.db alone
  can't see what sibling sessions have reserved on un-merged PR branches.
  The allocator must intersect (see § 4 / Drift Mode D).

## 2a — Network write path for non-canonical clients (INFRA-3689)

`state.db` (store #1) is canonical, but it only holds that authority for the
machine whose disk it lives on. A client whose local checkout has drifted behind `origin/main` (the
operator's Mac being the recurring case, per operator decision to move
canonical fleet operation onto owned iron) writing to its own `state.db`
would be writing to a **non-canonical replica**, silently reintroducing
Drift Mode C/E's root cause (a stale local view diverging from the
checkout everyone else reads).

Rather than requiring every client to hold a writable, always-fresh
canonical replica, `chump gap reserve|set|ship` can delegate the write over
HTTP to a **fleet-server running on a machine that already has one** (owned
iron, e.g. CJ):

- **Server side**: `POST /api/gap` (`crates/chump-fleet-server/src/routes.rs`
  `post_gap`, `crates/chump-fleet-server/src/gap_write.rs`
  `execute_gap_write`) — bearer-authed (`CHUMP_BATPHONE_TOKEN`, fail-closed,
  same auth as `POST /api/mission`), localhost-bind only. It runs the exact
  `chump gap <op>` command against **its own** `repo_root`'s state.db — the
  write still goes through the normal CLI path into store #1, just on a
  different machine.
- **Client side**: `src/gap_route.rs` supports two explicit modes. With only
  `CHUMP_GAP_SERVER` set, a client routes only when its local `main` is
  verifiably behind `origin/main` (`gap_route::should_route_to_server`). Set
  `CHUMP_GAP_SERVER_MODE=canonical` on the Mac after CJ is ready: all
  `reserve|set|ship` mutations route before opening the local `state.db`, so
  a stale or damaged replica cannot block recovery. Canonical mode requires a
  non-empty server URL and fails closed; an unset server keeps the default
  local-first behavior for offline-capable fleet nodes.
- **Fail-closed on routing failure**: if the server is unreachable or errors,
  canonical mode never opens or falls back to the local replica. Stale-only
  compatibility mode retains its original local-first behavior when staleness
  cannot be established.
- **Observability**: every successful route emits `kind=gap_mutation_routed_to_server`
  to `ambient.jsonl` (`docs/observability/EVENT_REGISTRY.yaml`) with `op`,
  `server`, and `behind` — so a reconcile pass can distinguish
  server-delegated writes from ones the client made against its own replica.

This does not add an eighth authoritative store: the server's `state.db` is
still store #1, just addressed over loopback HTTP from a client that
shouldn't trust its own copy.

## 3 — The reconciliation routine

A single canonical command must reconcile every store to its canonical
authority. Today this is partially implemented across several scripts.
The contract is:

```
chump gap reconcile [--check-only] [--auto-fix]
```

Steps (in order, fail-fast unless `--auto-fix`):

1. **state.db internal consistency**
   - Trigger constraints pass (id non-empty, etc.)
   - Every `closed_pr` references a PR that exists on GitHub
   - Every lease has `expires_at > now()` or is marked expired

2. **state.db ↔ origin/main consistency**
   - `gh pr view <closed_pr>` → if `state=MERGED`, gap status must be `done`
   - If `state=OPEN`/`CLOSED`-unmerged, gap status must NOT be `done`
   - **Premature closure** (status=done, PR unmerged) → [CREDIBLE-028](../gaps/CREDIBLE-028.yaml)
   - **Stale post-merge** (PR merged, status≠done) → CREDIBLE-028 reverse-mode

3. **state.db ↔ YAML consistency**
   - For every row in state.db.gaps, the per-gap YAML must match (status, closed_pr, closed_date, AC)
   - For every per-gap YAML on disk, a corresponding state.db row must exist
   - **YAML drift** (mismatch) → re-render YAML from state.db (state.db wins)
   - **Orphan YAML** (file on disk, no row) → import to state.db OR delete YAML (operator picks)

4. **state.db ↔ lease-files consistency**
   - Every `.chump-locks/*.json` has a corresponding row in `state.db.leases` or is stale
   - **Orphan lock file** → log + remove (lock files are mirrors, not authoritative)

5. **Cross-session ID allocation**
   - Before issuing a new ID, intersect `state.db.gap_counters` with `gh pr list --json files` to detect IDs claimed on un-merged PR branches
   - **ID collision** (two PRs file the same `docs/gaps/<ID>.yaml`) → [CREDIBLE-029](../gaps/CREDIBLE-029.yaml)

6. **Binary freshness for destructive ops**
   - Any operation that writes >1 YAML in a single invocation (full regen, `chump gap ship --update-yaml`, `chump gap dump --per-file`) must verify the chump binary is no more than N gap-store-affecting commits behind origin/main
   - **Stale binary regenerates from stale state.db** → [INFRA-825](../gaps/INFRA-825.yaml)

## 4 — Observed drift modes

Each drift mode is named, has a reproducer, and points to the gap that
prevents it. Implementers of INFRA-766 should ensure all of these are
covered.

### Drift Mode A — Premature gap closure
**Symptom**: state.db has `status=done` and `closed_pr=N` but PR N is still
open or unmerged. `gap-status-check` CI fails on N because the YAML on the
branch hasn't been updated.

**How it happens**: an agent runs `chump gap ship --update-yaml` before
the PR has actually merged, marking the gap done in state.db while the
PR is still in CI.

**Real incident**: PR [#1433](https://github.com/repairman29/chump/pull/1433) (INFRA-538) sat 17h
BLOCKED because state.db said done but the PR was still pending. Required
manual `chump gap set INFRA-538 --status in_progress` (with `CHUMP_ALLOW_RECYCLE=1`
to defeat the recycled-ID guard) + a YAML status-flip commit on the PR branch.

**Prevention**: [CREDIBLE-028](../gaps/CREDIBLE-028.yaml) — premature-closure detector.

### Drift Mode B — Gap-ID allocator race
**Symptom**: two PRs each create `docs/gaps/INFRA-XXX.yaml` with the same
ID but different content. Whichever PR merges first wins; the second
PR's file-add becomes a content collision on rebase.

**How it happens**: two concurrent `chump gap reserve` calls read
state.db.gap_counters at the same value, both increment locally, neither
sees the other's reservation until push time. The pre-push hook only
checks state.db, not open sibling PRs.

**Real incident**: 2026-05-11 — PR [#1448](https://github.com/repairman29/chump/pull/1448) (this rescue session)
and PR [#1449](https://github.com/repairman29/chump/pull/1449) (cold-water audit) both reserved INFRA-819
for different content. Required manual rename (INFRA-819 → INFRA-824 on
the loser) post-hoc. INFRA-820/821 also collided in the same session.

**Prevention**: [CREDIBLE-029](../gaps/CREDIBLE-029.yaml) — atomic gap-ID allocator
that intersects state.db.gap_counters with open PR branches before issuing.

### Drift Mode C — Stale-binary YAML regen
**Symptom**: a single `chump gap ship --update-yaml` (or any bulk YAML
regen) silently reverts recently-merged gap content that the running
chump binary doesn't know about. The reverted content appears as a
deletion in the next PR's diff under an unrelated title.

**How it happens**: the running chump binary was built N+ commits behind
origin/main. Its in-memory understanding of gap-store schema or content
is outdated. A bulk-regen command writes "what the binary thinks main
should look like" → overwrites newer content from main.

**Real incident**: PR [#1444](https://github.com/repairman29/chump/pull/1444) (chore: add AC to 16 gaps)
silently reverted META-044 (merged 18h prior in [#1443](https://github.com/repairman29/chump/pull/1443)) because
its `d698e9cd` commit was generated by `chump gap ship --update-yaml`
with a 9-commit-stale binary. Caused the rescue split into [#1455](https://github.com/repairman29/chump/pull/1455)
(clean AC) and operator-close on #1444.

**Prevention**: [INFRA-825](../gaps/INFRA-825.yaml) — hard-fail destructive
ops when binary is stale. Soft warning exists today (`CHUMP_BINARY_STALENESS_CHECK`);
needs to become a hard exit for bulk-YAML-regen invocations.

### Drift Mode D — Orphan lease (lock file outlives session)
**Symptom**: `.chump-locks/<session>.json` exists with `expires_at` in
the past, but no matching row in `state.db.leases` (or vice versa). A
gap looks claimed forever; preflight refuses to issue new claims for it.

**How it happens**: a session crashes mid-flight, leaving its `.chump-locks/*.json`
on disk. The lease in state.db hits its expiry and reaps; the lock file
doesn't. Or vice versa — state.db schema rebuild loses the leases row
but the lock file remains.

**Real incident**: pervasive. Today's session had 4 active leases in
`.chump-locks/` of which 3 had `null` started/expires fields (orphaned
lock-file remnants from prior sessions). Stale-gap-lock-reaper
(`dev.chump.stale-gap-lock-reaper`) was specifically built for this.

**Prevention**: reconcile step 4 above (canonical = state.db.leases);
already partially implemented; INFRA-766's audit should formalize it.

### Drift Mode E — YAML drift (content mismatch state.db vs per-gap YAML)
**Symptom**: `docs/gaps/<ID>.yaml` on main contains different field values
than `state.db.gaps` row for the same ID. Tools reading from YAML get one
answer, tools reading state.db get another.

**How it happens**: a PR edits a per-gap YAML directly (operator or agent
hand-edit) without going through `chump gap set`. The YAML lands on main
but state.db isn't updated. Or the reverse: `chump gap set` updated state.db
but the YAML regen didn't run.

**Real incident**: low-grade but pervasive — `chump gap audit-priorities`
sees vague-pickable gaps in state.db whose per-gap YAML has TODO ACs,
because `chump gap reserve` writes both but later `chump gap set` updates
only state.db. Today's INFRA-819 / CREDIBLE-025 backfill was an instance
that needed both files updated.

**Prevention**: every state.db write must trigger a per-gap YAML re-render
in the same transaction. Tested by `scripts/ci/test-gap-yaml-state-parity.sh`
(to be built; the gap is part of INFRA-766's scope).

### Drift Mode F — Ghost closed_pr (gap marked done with PR that doesn't exist)
**Symptom**: `gaps.closed_pr = 99999` (or any non-existent number),
`gaps.status = done`. The gap looks shipped but no PR ever closed it.

**How it happens**: agent runs `chump gap ship <ID> --closed-pr <wrong>`
with a typo. Or a `chump gap import` from a hand-edited YAML carries a
stale PR number.

**Real incident**: low-frequency but observed. `scripts/dev/check-premature-closures.sh`
(part of CREDIBLE-028 AC) detects this class by calling `gh pr view`.

**Prevention**: CREDIBLE-028 (same checker handles A and F).

### Drift Mode G — Stale-checkout canonical-ID collision (fixed, INFRA-3687)
**Symptom**: `chump gap reserve` on a checkout that is behind `origin/main`
re-issues an ID that canonically already belongs to an already-merged gap.
Distinct from Drift Mode B (allocator race between two concurrent
reserves): here there is no race at all — a single checkout's local
`gaps` table is simply stale relative to `origin/main`.

**How it happens**: `reserve_with_external()`'s allocation ceiling
(`combined_max`) used to come from only two sources: `existing_max`
(`SELECT MAX(id)` on the LOCAL `.chump/state.db`) and `extra_max`
(`.chump-locks/*.json` leases + open-PR titles, via
`external_pending_ids()`). Neither consults `origin/main`'s canonical,
git-tracked `.chump/state.sql` (the full dump of every gap ever reserved
or merged — see `load_state_sql()` / `restore_from_state_sql()`). A
checkout N commits behind `origin/main` has a stale local `gaps` table,
so `existing_max` under-counts and the naive `existing_max + 1` can equal
an ID that already shipped upstream.

**Real incident**: a checkout 177 commits behind reserved `INFRA-3680`,
which canonically is a merged "parse_verdict" gap — collision, stranding
the new gap in the stale local rep.

**Prevention (fixed, INFRA-3687)** — three parts, all in
`crates/chump-gap-store/src/lib.rs`:
1. `GapStore::canonical_max_id(domain)` best-effort `git fetch origin
   main --quiet` (mirrors the INFRA-2423 auto-fetch pattern), then reads
   `origin/main:.chump/state.sql` via `git show` and extracts the max
   `<DOMAIN>-N` from the **`id` column only** (deliberately not a raw
   text scan — `state.sql` carries `<DOMAIN>-N`-shaped junk substrings
   outside the `id` field, e.g. a stray `INFRA-9999999` quoted in a
   note, and a naive scan would rocket the allocator to that instead).
   `reserve_with_external` folds this into `combined_max`, so a stale
   local checkout can no longer under-allocate whenever origin refs are
   reachable.
2. Fail-closed: if this checkout is genuinely behind `origin/main`
   (`git rev-list --count main..origin/main` > 0) AND
   `canonical_max_id()` could not verify canonical truth (offline,
   unreachable ref, or the file is absent at that ref — distinct from
   "verified and this domain has zero canonical gaps", which returns
   `Some(0)`), `reserve_with_external` returns `Err` rather than trust a
   possibly-stale local counter. Audited escape hatch:
   `CHUMP_RESERVE_ALLOW_STALE=1` (emits `gap_reserve_stale_bypass_used`
   to `ambient.jsonl`, registered in `docs/observability/EVENT_REGISTRY.yaml`).
3. `chump gap list` prints a loud, non-blocking `stderr` warning when the
   checkout is behind `origin/main` (`GapStore::behind_origin_main()`) —
   stdout output (`--json`/`--csv`/plain) is untouched since scripts
   parse it.

**Regression lock**: `scripts/ci/test-gap-reserve-no-stale-collision.sh`
(wired in both `.github/workflows/ci.yml` and `chump preflight` per the
INFRA-2120 parity rule) runs the `chump-gap-store` unit tests that
reproduce the exact drift (local max stuck low, canonical max high) and
assert the allocator beats canonical truth, plus the fail-closed +
bypass paths and the junk-ID-immune extraction.

## 5 — Stores that look load-bearing but aren't

To keep the contract clean, these surfaces are explicitly **not canonical**
for anything. Anyone treating them as authoritative is wrong.

- `docs/gaps.yaml` (the monolithic legacy) — mirror only. Will be deleted
  once all CI scripts read per-gap YAMLs or state.db.
- `docs/process/WORK_QUEUE.md` — stub by design. The doc explicitly
  redirects to `chump gap list`. Any "active work" content here is drift.
- Ambient.jsonl events — high-fidelity but not authoritative. Useful for
  telemetry, queries, post-hoc forensics. Never the source of truth for
  current state.
- Per-worktree `.chump/state.db` copies — these exist (each `chump claim`
  creates a worktree with its own state.db copy). Treat them as **read-mostly
  caches** of main's state.db. Writes must round-trip through `chump gap`
  commands, which write to the repo's state.db.

## 6 — Implementation order

Implementers of INFRA-766 (and the symptom gaps that prevent each drift
mode) should ship in this order so each step builds on the last:

1. **CREDIBLE-028 (premature-closure / ghost-PR detector)** — drift modes A and F. Smallest scope (effort: xs). Detection-only.
2. **INFRA-825 (stale-binary hard-fail)** — drift mode C. Stops the worst silent corruption from recurring. Small (effort: xs).
3. **CREDIBLE-029 (atomic ID allocator)** — drift mode B. Includes the cross-PR check. Medium (effort: s).
4. **INFRA-766 (umbrella state-drift detector)** — formalizes drift modes D and E plus glues the above into `chump gap reconcile`. Medium (effort: m).
5. **(future) Reconciliation auto-fix** — `chump gap reconcile --auto-fix` for safe cases (orphan lock files, regen-stale YAML from state.db). Operator-gated for risky cases.

## 7 — Pre-existing references (do not duplicate)

- [`docs/process/WORK_QUEUE.md`](./WORK_QUEUE.md) — declares state.db as canonical, redirects to CLI.
- [`docs/process/AGENT_COORDINATION.md`](./AGENT_COORDINATION.md) — describes the *coordination layer* (leases, locks, ambient.jsonl) but not the *state contract*.
- [`docs/process/FAILURE_MODES.yaml`](./FAILURE_MODES.yaml) — failure-classification catalog used by `chump classify-failure`; the drift modes here are a strict subset of failure modes and should not duplicate that file.
- `src/gap_store.rs` — implements the state.db side of the contract. Comments there reference historical gap IDs (INFRA-059, INFRA-156, INFRA-233, INFRA-498) that are the operational scars this doc names.

## 8 — When to update this doc

Whenever a new drift mode is observed in production (a new gap filed that
fits the pattern "state X and state Y disagreed and an agent shipped
something wrong"), add it to § 4 with the incident PR and the prevention
gap. Don't file a sibling contract doc; this one grows.
