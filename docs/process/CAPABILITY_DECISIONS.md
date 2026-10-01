# Capability decisions log

Tracks opt-in flags that gate a *new enforcement capability* — a check that
used to be advisory (warn-only) or absent, now made real, but ratcheted
behind an env var until the fleet has run it in observation mode long enough
to trust the false-positive rate. One entry per flag. When a flag flips to
default-on, update its entry rather than deleting it — the history of why a
gate was cautious is as load-bearing as the gate itself.

## `CHUMP_VERIFY_LIVE_BLOCKING` (PEER-VERI-08, INFRA-3655)

- **Default:** off (unset / any value other than `1`).
- **What it does:** when a PR's proof AC bullet (`PROVEN-BY <unit|kind=event|URL>`)
  fails `check_live_outcome` (crates/chump-verify/src/pr_ac_coverage.rs), the
  PR-close path treats that as a **blocking** `Miss` instead of falling through
  to `CHUMP_AC_GATE_ADVISORY`'s warn-and-continue behavior. Non-proof AC
  misses are unaffected by this flag — they keep their existing
  advisory/blocking behavior either way.
- **Why gated:** `check_live_outcome` shells out to `systemctl` / reads
  `ambient.jsonl` / curls a URL at PR-close time. Until the proof-AC
  synthesizer (same gap, AC#1 — `maybe_inject_proof_ac` in
  `pr_ac_coverage.rs`) has run in production for a stretch and the
  false-positive rate on synthesized targets is known, a blocking failure on
  a flaky probe (systemd unit mid-restart, ambient log rotated, transient
  network blip) could wedge a otherwise-good PR. Advisory-first lets the
  fleet observe `ac_coverage_proof_miss` / `ac_coverage_live_blocking`
  ambient volume before it can hold a merge.
- **Ratchet plan:** flip to default-on once a full week of
  `ac_coverage_proof_miss` events on synthesized (not hand-written) proof
  bullets shows a near-zero false-positive rate (spot-checked against the
  actual unit/event/endpoint state at the time of the miss).
- **Where it's read:**
  `crates/chump-verify/src/pr_ac_coverage.rs::score_against_bullets`.
- **DEPTH tier:** D2 (opt-in enforcement flag, single-crate blast radius,
  fails closed to the pre-existing advisory path when unset).

## Related capabilities

- `CHUMP_AC_GATE_ADVISORY` — the pre-existing advisory-vs-blocking switch for
  the AC-coverage gate as a whole (CREDIBLE-178). `CHUMP_VERIFY_LIVE_BLOCKING`
  only carves proof-bullet misses out of that switch's fail-open path; it
  does not replace it.
- `CHUMP_AC_JUDGE_LLM` — the LLM judge overlay (EFFECTIVE-373). Explicitly
  cannot override a proof bullet's verdict (CREDIBLE-281) — the live-outcome
  check is the only authority for proof bullets, blocking or not.

## `CHUMP_RCA_REFLEX_ENABLED` (RESILIENT-365, INFRA-249)

- **Default:** OFF (`0`)
- **Where:** `scripts/coord/recurring-gap-pattern-detector.sh` (INFRA-249),
  wired as the `chump-rca-reflex.timer` / `.service` organ (RESILIENT-365).
- **What ON does:** when a cluster of ≥threshold gaps shares a title keyword
  in the detection window, the reflex (a) reserves a META RCA gap with an
  LLM-generated COMMAND/OUTPUT/THEORY/ALT evidence blob, and (b) sets
  `depends_on` on every symptom gap in the cluster to point at the new root
  gap, so the fleet's pickable-gate stops handing out the next symptom until
  the root lands. Idempotent — re-running on the same cluster reuses the
  existing open root gap (dedup by keyword in
  `.chump-locks/pattern-detector-state.json`) rather than filing a
  duplicate.
- **What OFF does:** the detector still runs on its timer, still detects
  clusters, and still emits the human-facing `ALERT`
  (`kind=recurring_gap_pattern`) to `ambient.jsonl` — only the auto-file +
  auto-block side effects are suppressed.
- **Why gated:** this is the first Chump capability that both files gap-store
  writes AND blocks other gaps from being picked, entirely on a timer with no
  human review. A wrong root-cause hypothesis or a keyword collision (e.g. a
  common English word clustering unrelated gaps) would file a bogus RCA gap
  and stall real symptom work behind it. Ship the organ live (so detection
  itself is never dark again — the RESILIENT-365 evidence was 44 symptom PRs
  and 0 root gaps in one night) but keep the autonomous half opt-in until it
  has a track record.
- **Log:**
  - 2026-08-22 — shipped default OFF (RESILIENT-365, first ship). No operator
    has flipped it on yet.
- **DEPTH tier:** D2 (opt-in autonomous-write flag, gap-store blast radius,
  fails closed to detect-and-ALERT-only when unset).

## `CHUMP_STARVE_AUTO_RELAX` (INFRA-391) — flipped default-ON for workers

- **Default (as of this entry):** ON (`1`) for any worker, set as fleet policy
  in the tracked `scripts/setup/worker-policy.env`, which `scripts/dispatch/
  worker.sh` sources each cycle. The code-level fallback in worker.sh remains
  `:-0` (off) so a checkout without the policy file is unchanged; the policy
  file uses `:=` so an explicit per-node/env value still wins (opt-out honored).
- **What ON does:** after `CHUMP_STARVE_THRESHOLD` consecutive empty picks, the
  worker widens its OWN filter in place — drop `FLEET_DOMAIN_FILTER`, then bump
  the effort tier, then the priority tier (smallest meaningful blast-radius
  increase each step) — and resets its starve counter, instead of ramping
  toward the INFRA-613 stand-down (`exit 0`).
- **What OFF does:** the pre-existing behavior — emit the `fleet_starved`
  suggestion to ambient + log, keep polling with exponential backoff, and stand
  down after `CHUMP_STAND_DOWN_THRESHOLD` empty cycles.
- **Why flipped on:** the toggle shipped default-OFF and then lived nowhere in
  git — it was simply absent from every node's hand-deployed, git-untracked
  `~/node1-worker-run.sh`. On 2026-09-08 a hand-edited
  `FLEET_DOMAIN_FILTER=EFFECTIVE,CREDIBLE` on mugman narrowed the worker to a
  domain with no pickable gaps; with auto-relax unset, the worker stood down
  138x over ~15h while the fleet sat frozen, and nothing in git could review,
  reproduce, or heal the policy. Making it fleet policy (a) brings the toggle
  under management so a drifted filter self-corrects instead of freezing, and
  (b) leaves stand-down reachable only when the filter is genuinely maximally
  relaxed and the backlog is truly empty.
- **Risk / blast radius:** a relaxing worker can pick up work OUTSIDE its
  originally-configured domain/effort/priority once starved. That is the
  intended trade (a broader pick beats a dark worker), and it only takes effect
  AFTER starvation — a worker with pickable in-filter work is unaffected. The
  single-merge-driver invariant (RESILIENT-1054) is untouched: relax changes
  only which GAPS a muscle worker builds, never the merge path.
- **Log:**
  - 2026-09-09 — flipped default-ON for workers via `worker-policy.env`
    (config-under-management). Guarded by
    `scripts/ci/test-worker-policy-env.sh`.
- **DEPTH tier:** D2 (behavior-flip via tracked config; blast radius = which
  gaps a starved worker picks; fails safe to the prior off-path when the policy
  file is absent, and honors an explicit opt-out).

## `check_live_outcome` node resolution — no silent localhost fallback (INFRA-3652, PEER-VERI-05)

- **What changed:** `check_systemd_unit_live` (crates/chump-verify/src/
  pr_ac_coverage.rs, used by `check_live_outcome`) used to call
  `resolve_target_node_for_unit` (INFRA-7098) and, on `None` (no NATS, no
  manifest, stale manifest, no machine field), silently fall back to probing
  `systemctl` on the **local** host. That fallback was the exact
  "assume localhost" anti-pattern this gap exists to remove: a proof-AC
  bullet naming a unit that lives on a different node (e.g. `closetjunky`)
  could be "verified" by checking the wrong box entirely. Unresolvable
  targets now fail CLOSED with `"target node unresolved for <unit>"` instead.
  Resolving to a non-current host now always runs `ssh <node> systemctl
  is-active <unit>` (INFRA-3728); resolving to the current host still runs
  local `systemctl`.
- **Why not gated:** this tightens a gate that was already fail-closed on the
  *diff-keyword-match* axis (CREDIBLE-281) — it only removes a path that
  could silently produce a false pass by checking the wrong host, never a
  path that could produce a false fail on a previously-passing claim (a
  bullet naming a unit nobody can place was already a dubious proof claim).
  `CHUMP_VERIFY_LIVE_BLOCKING` (above) remains the separate ratchet for
  whether a proof-AC miss blocks the PR at all; this change only affects
  whether a miss is *correctly classified* as a miss.
- **Gaps named:** INFRA-3652 (this slice, PEER-VERI-05), INFRA-7098 (node
  resolution via capability-manifest KV), INFRA-3728 (remote `ssh systemctl`
  probe). Mission: MISSION-010.
- **DEPTH tier:** D1 (pure classification fix inside an existing gate's
  decision function; no new flag, no new blast radius — a bullet that was
  already failing closed on an unverifiable claim now fails closed for the
  correct reason instead of the wrong one).
