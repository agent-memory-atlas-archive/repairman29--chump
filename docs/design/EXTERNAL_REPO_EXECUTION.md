# External-repo execution — design of record (INFRA-3474)

**Status:** design agreed 2026-07-28 (operator + Chump). Phase 1 proven as of 2026-10-10 (`INFRA-8607`).
**Why:** the outward flywheel (MISSION-010 — improving *other* repos) has exactly one
execution path, `chump improve → claude CLI`, and it's non-functional where the
claude CLI isn't installed. Closing the almanac link (comprehend-uat convergence,
INFRA-3468/9/72) requires the fleet to actually *execute* external-repo work.

## Principle 0 — never default to the claude CLI

The OS must **default to its own runtime** (chump-local, riding `ProviderCascade` —
the shared LLM service). Defaulting to the external claude CLI contradicts three
things at once: "own your tools, don't rent your mind"; the swappable-harness design;
and the shared-service discipline (`docs/process/CANONICAL_SERVICES.md`). claude CLI
(and opencode, aider, …) are **opt-in swappable harnesses**, never the default. The
current `chump improve` hardcoding of `claude -p` is the bug.

## Principle 1 — external work is internal work, one clone deeper

The fleet already coordinates many agents on one repo (chump itself). External-repo
work must **reuse that substrate**, not invent a parallel one:

| Concern | Internal (already built) | External (same, one level deeper) |
|---|---|---|
| Gap awareness | canonical `state.db` | same `state.db`, gaps tagged `external_repo:<owner>/<repo>` |
| No collisions | atomic claim (lease) | same claim (local lease → NATS-KV CAS cross-machine) |
| Isolated edits | linked worktree off the shared `.git` | linked worktree off a **shared external clone** |
| Runtime | chump-local (`ProviderCascade`) | **same** |
| Integration | bot-merge + armed-PR-rebaser (merge queue) | same, against the **external repo's origin** |

The only genuinely new primitive is **"a shared clone per external repo, with
per-agent worktrees off it"** — the external analog of the shared `.git`. Everything
else — awareness, claims, isolation, runtime, integration — already exists and is shared.

## The three layers of sharing (each has a *different* distributed truth)

When N agents (across M machines) work the same repo, three things are shared, and
they do **not** share the same way. Conflating them is the design trap.

| Shared thing | Source of truth | How it's distributed |
|---|---|---|
| **Gap list** (what work exists) | `state.db` | `assign` daemon fans it out; git-carried gap state syncs machines |
| **Claims** (who's on what) | **NATS-KV** (CAS + TTL) | live, atomic, cross-machine — the anti-collision primitive |
| **Git state** (the repo itself) | the repo's **GitHub origin** | each machine clones from + pushes to it; PRs are the merge queue |

Do **not** try to share the git clone over NATS. NATS shares *coordination*; GitHub
origin shares *git*; each machine keeps its own local clone.

## The full model (external repo, N agents, M machines)

```
             ┌───────────────── NATS (coordination nervous system) ────────────┐
             │  KV: claims (try_claim_gap CAS)  ·  KV: capability manifests     │
             │  pub/sub: chump.work.<P>.external:<repo>.<machine-with-clone>    │
             └──────────────────────────────┬─────────────────────────────────┘
   machine A                                │                    machine B (helsinki)
   state.db (gaps external_repo:almanac) ───┤── assign fans out ─► state.db
   ~/.chump/external/almanac/clone  ◄── per-machine ──►  ~/.chump/external/almanac/clone
     ├ worktree/agent-1 → gap X                            ├ worktree/agent-3 → gap Z
     └ worktree/agent-2 → gap Y                            └ …
                     │                                             │
                     └────► push branch + PR ──► almanac's GitHub origin ◄──────┘
                                    (cross-machine git truth + merge queue)
```

Per-agent flow:
1. **Claim** an `external_repo:<repo>` gap — locally a lease; cross-machine the
   **NATS-KV CAS** guarantees exactly one winner across all machines.
2. Winner gets a **linked worktree off that machine's local clone** of the target repo.
3. **chump-local** (`ProviderCascade`) edits in the worktree → commit.
4. Push a branch to the **target repo's origin** → open a PR.
5. The **merge queue** (bot-merge rebase/resolve + `armed-pr-rebaser`) serializes PRs
   against the target's main — identical to internal integration.

## Why 1 / N-on-1 / N-on-M is one design

- **1 agent** — local lease, one worktree, PR. (Degenerate case.)
- **N on one machine** — local `state.db` claims, N worktrees off the shared local
  clone, merge queue. **No NATS needed.**
- **N across M machines** — swap the local lease for the **NATS-KV CAS claim**, add
  **NATS routing** (assign → capable, clone-holding worker), keep per-machine
  clones+worktrees. Everything below the claim/routing layer is identical.

NATS is the *only* thing that changes from one machine to many. That factoring is
the sign the design is right.

## NATS role (verified primitives) + the one enhancement

Already built (`crates/chump-coord`): `try_claim_gap` = NATS-KV CAS (distributed
claim); capability manifests in a KV bucket; `assign` daemon publishes `WorkEnvelope`s
to `chump.work.<priority>.<class>.<machine>`; workers subscribe by capability; offline
→ pull-loop fallback. The worker layer already understands `external_repo:` tags for
capability-gating (`worker/capability.rs`).

**Enhancement:** routing is repo-agnostic today. Add **locality-aware routing** — a
subject dimension `chump.work.<P>.external:<repo>.<machine>` and a capability-manifest
field advertising which external clones a machine holds — so `external_repo:almanac`
work routes to a machine that *already has the almanac clone* (avoid re-cloning
everywhere). Natural extension of the existing scheme, not a new system.

## The confirmed blocker (why it's a refactor, not a flag)

`execute_gap` **conflates gap-source and file-root**: it reads the gap via
`repo_path::main_checkout_root()` (git-common-dir from `repo_root`, which follows
`CHUMP_REPO`/cwd) AND roots the agent's file tools at that same place. External work
needs them **decoupled**: gap from chump's canonical `state.db`, files in the target
repo's worktree. Setting `CHUMP_REPO=<clone>` breaks gap lookup (looks in the clone's
state.db, where the gap isn't). So it's a refactor.

## Build plan

**Phase 1 — single-machine substrate (no NATS; proven as of 2026-10-10):**
1. **Shared clone + worktrees:** maintain `~/.chump/external/<owner>/<repo>/clone`;
   a claiming agent gets a linked worktree off it (mirror the internal
   claim→worktree flow). `improve --gap` must ensure the clone exists (scout is skipped).
   - **Proven receipts on `cuphead`:** `~/.chump/external/` clones for `upshift-cli` and
     `olive` (`repairman29/olive`) work end-to-end on `cuphead` (proven 2026-10-07 /
     2026-10-24).
2. **First-class capability & operator gate (`INFRA-8602`, `INFRA-8603`, `INFRA-8604`):**
   - **Node capability declaration (`WorkerCapability`):** `WorkerCapability` declares
     `pub external_repo_enabled: bool` (sourced from `CHUMP_EXTERNAL_REPO_PICK_OK=1|true`,
     default `false`) and exposes `external_repo_enabled` in `CapabilityManifest`. When
     `external_repo_enabled` is `false`, `WorkerCapability::matches()` and
     `_pick_and_claim_gap.py` skip `external_repo` / `external_repo:*` gaps and log
     `N external gaps skipped: gate closed` plus `external_repo gate: closed (N gaps blocked)`
     (or `external_repo gate: open`).
   - **Operator CLI (`chump fleet external-repo`):**
     - `chump fleet external-repo status [--json]` — displays gate state (`open` or `closed`)
       and per-node `external_repo_enabled` capability state.
     - `chump fleet external-repo enable` — writes `CHUMP_EXTERNAL_REPO_PICK_OK=1` (plain
       `KEY=VALUE`, no `export ` prefix) to `~/.chump/node.env`.
     - `chump fleet external-repo disable` — writes `CHUMP_EXTERNAL_REPO_PICK_OK=0` to
       `~/.chump/node.env`.
3. **Decouple gap-source from file-root in `execute_gap`** (the blocker): read the gap
   from chump's canonical `state.db` regardless of the file-root; root the agent's
   file tools at the worktree. New env/param, e.g. `CHUMP_GAP_SOURCE_ROOT` (chump) vs
   `CHUMP_REPO` (worktree).
4. **chump-local runtime, claude opt-in:** `improve` gets `CHUMP_IMPROVE_BACKEND`
   (default `chump-local`). The chump-local path runs the OS's own agent in the
   worktree; claude CLI becomes `CHUMP_IMPROVE_BACKEND=claude`.
   - Recommended primitive: a `chump agent-run --prompt-file <f> [--cwd <dir>]`
     subcommand that runs `build_chump_agent_cli()` (ProviderCascade, full tool set
     incl. `git_push`/`gh`) on an ad-hoc prompt in `cwd` — **no gap lookup, so no
     conflation.** `improve` swaps `claude -p` for it and reuses its ExternalRepoContract
     prompt + `pr_url` extraction verbatim. (Alternative: teach `execute_gap` external
     awareness per (3) and orchestrate push/PR in `improve`.)
5. **Edit-only mode (already prototyped):** `CHUMP_EXECUTE_GAP_NO_SHIP=1` skips
   `execute_gap`'s internal bot-merge so an external caller owns commit/push/PR —
   keep for the `execute_gap`-based path.

**Phase 2 — turn on the M-machine layer (NATS):**
5. Locality-aware routing (subject `chump.work.<P>.external:<repo>.<machine>` + clone
   advertisement in the capability manifest).
6. Reuse the NATS-KV CAS claim for cross-machine external gaps (already the mechanism).

## Safety / discipline

- Dry-run first, `--apply` opt-in — same discipline as the comprehension→work engine.
- The merge queue (bot-merge + `armed-pr-rebaser`) is the integration gate; external
  PRs are reviewed/verify-merged on merit, never blind-merged.
- NATS is currently **off** (`CHUMP_NATS_URL` unset → pull mode). Phase 1 works
  single-machine without it; Phase 2 lights up when NATS is enabled.

## Open reconciliation items (confirm before/while building)

- **How does BEAST-MODE ship today?** The scoreboard shows external BEAST-MODE merges,
  yet claude CLI isn't installed here — determine whether that runs on another
  machine/setup (claude CLI present) or a different path, so we know what we're replacing.
- **Cross-machine `state.db`/gap replication** — is the gap list git-carried
  (`state.sql`) + per-machine, or canonical + synced? Confirm before relying on N-machine
  gap awareness.
