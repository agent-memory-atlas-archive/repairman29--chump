# Batched Merge Train — operator guide

INFRA-2130 SCALE-A. Last updated: 2026-09-16 (INFRA-6988 — LIVE on CJ).

## What this is

The `chump-integrator-daemon` batches `ready_to_ship` gaps through a
preflight gate and (when enabled) pushes an integration branch, opens one PR,
and arms auto-merge. Instead of running CI once per gap, CI runs once for a
batch of up to 5 gaps. At 8 min per CI cycle this shifts the theoretical
ceiling from ~7 PRs/hr toward ~35 PRs/hr for the batched cohort.

**Status: LIVE on CJ (the sole coordinator), as of INFRA-6988.** The go-live
gate (trunk confirmed GREEN — coordination single-writer after RESILIENT-1309,
9 merges/6h, no green-never-lands race) was met, and the systemd `--live`
drop-in (`scripts/setup/install-integrator-daemon-systemd.sh --live`) is
installed on CJ. The drop-in is reversible — see
[Flip to LIVE mode](#flip-to-live-mode) to revert to dry-run immediately if
PRs start sticking. Every other node stays **DRY-RUN by default**; operators
must explicitly opt in to LIVE mode there. This document explains how.

Bot-merge's Mode A/B routing (`scripts/coord/bot-merge.sh`, INFRA-2133) checks
integrator health before routing a gap to the batched queue, and fails open to
per-PR Mode B (INFRA-2523) if the daemon can't actually drain. That health
probe originally only understood launchd (macOS); INFRA-6988 added a systemd
probe (`_bm_integrator_healthy_systemd`, checks `chump-integrator.timer`
active + unit binary executable + last `Result=success`) so the check is
accurate on CJ's systemd install — without it, bot-merge would have
permanently fail-opened to Mode B even after the drop-in flipped the daemon
LIVE, silently defeating the go-live.

---

## Quick state check

```bash
# Is the daemon installed and running?
launchctl print gui/$(id -u)/com.chump.integrator-daemon

# What mode is it in?
launchctl print gui/$(id -u)/com.chump.integrator-daemon \
  | grep CHUMP_INTEGRATOR_LIVE

# Recent cycle output
tail -100 ~/.chump/logs/integrator-daemon.err

# Ambient events from the last hour
grep "integration_cycle" .chump-locks/ambient.jsonl | tail -20
```

---

## Install (dry-run, safe default)

**macOS (launchd):**

```bash
scripts/setup/install-integrator-daemon.sh
```

**Linux primary node — helsinki (systemd):**

```bash
sudo bash scripts/setup/install-integrator-daemon-systemd.sh
```

Either installs with `CHUMP_INTEGRATOR_LIVE=0`. The daemon fires every 15
minutes, selects candidates, builds and preflights an integration branch, then
logs what it would have shipped. No git push, no PR.

On Linux the organ is also part of the RUN-INSTALL roster: a fresh node that runs
`sudo bash scripts/setup/install-helsinki-atc.sh` boots WITH the merge train
(units in `scripts/dispatch/chump-integrator.{service,timer}`, kept enabled by
`scripts/ops/organ-manifest.txt` + `chump-organ-reconcile`).

Linux state check:

```bash
systemctl status chump-integrator.timer        # active?
bash scripts/setup/install-integrator-daemon-systemd.sh --status   # mode (dry-run/live)
tail -100 ~/.chump/logs/integrator-daemon.err  # recent cycle output (or: journalctl -u chump-integrator)
systemctl start chump-integrator.service        # run one cycle now
```

---

## Flip to LIVE mode

LIVE mode pushes the integration branch, opens a PR, and arms `--auto --squash`
merge. Before flipping:

1. Confirm trunk is not RED:
   ```bash
   cat .chump-locks/trunk-red-detector-state.json | python3 -c \
     "import sys,json; d=json.load(sys.stdin); print('RED' if d.get('is_red') else 'GREEN')"
   ```
2. Confirm dry-run cycles have been logging sane manifests for at least one hour:
   ```bash
   tail -20 ~/.chump/logs/integrator-daemon.err | grep DRY-RUN
   ```
3. Flip:

   macOS (launchd):
   ```bash
   scripts/setup/install-integrator-daemon.sh --uninstall
   scripts/setup/install-integrator-daemon.sh --live
   ```

   Linux (systemd, helsinki) — one command, installs a `CHUMP_INTEGRATOR_LIVE=1`
   drop-in over the tracked dry-run unit:
   ```bash
   sudo bash scripts/setup/install-integrator-daemon-systemd.sh --live
   ```

To flip back to dry-run at any time:
```bash
# macOS
scripts/setup/install-integrator-daemon.sh --uninstall
scripts/setup/install-integrator-daemon.sh
# Linux (removes the LIVE drop-in)
sudo bash scripts/setup/install-integrator-daemon-systemd.sh --dry-run
```

---

## Safety rails (always active in LIVE mode)

| Rail | Behavior |
|---|---|
| Trunk-RED gate | Reads `.chump-locks/trunk-red-detector-state.json`. If `is_red=true`, emits `integration_trunk_red_hold` and skips the cycle entirely. |
| Batch cap | `CHUMP_INTEGRATOR_BATCH_MAX` (default 5). Applied on top of the general `CHUMP_INTEGRATOR_MAX_BATCH`. Raise only after observing stable cycles. |
| `do-not-batch` label | Candidates with the configured label (`CHUMP_INTEGRATOR_DO_NOT_BATCH_LABEL`, default `do-not-batch`) are excluded before the batch is assembled. Apply this label to a PR via `gh pr edit <N> --add-label do-not-batch`. |
| Circuit breaker | On any LIVE ship failure (push or merge), the daemon emits `integration_cycle_failed`, rolls back the integration branch, and forces the next cycle into dry-run. Resets automatically on the next successful LIVE cycle. |

---

## Rollback procedure

If a LIVE cycle ships something wrong:

1. The integration PR is just a regular squash-merge PR. Revert it like any other:
   ```bash
   gh pr view <N>   # find the merge commit
   git revert <merge-sha>
   gh pr create --base main --head <revert-branch> --title "revert: integration-<cycle-id>"
   ```
2. Re-queue affected gaps: `chump gap requeue <GAP-ID>` for each gap in the batch.
3. Check the circuit breaker: look for `integration_cycle_failed` in ambient.jsonl.
   The daemon will be in dry-run automatically until the next successful LIVE cycle.
4. If the branch was pushed but the PR was not yet merged, close the PR and delete
   the branch:
   ```bash
   gh pr close <N>
   git push origin --delete chump/integration-<cycle-id>
   ```

---

## When NOT to use the batched merge train

- During a trunk-RED incident (the rail handles this automatically, but if the
  detector is not running, disable LIVE mode manually).
- When a large structural refactor is in flight (conflicts will break batches;
  let the refactor land first).
- When the CI queue is already saturated — batching helps throughput but adds
  one extra PR to the queue per batch.
- For `do-not-batch`-labelled PRs: security fixes, rollbacks, and anything that
  must land atomically on its own should carry this label.

---

## Env knobs reference

| Variable | Default | Purpose |
|---|---|---|
| `CHUMP_INTEGRATOR_LIVE` | `0` | Set to `1` to enable LIVE mode (alias for `DRY_RUN=0`). |
| `CHUMP_INTEGRATOR_DRY_RUN` | `1` | Authoritative dry-run flag. Overrides `LIVE` when set. |
| `CHUMP_INTEGRATOR_BATCH_MAX` | `5` | v1 LIVE-mode batch cap. |
| `CHUMP_INTEGRATOR_VOLUME_THRESHOLD` | `5` | Min candidates before a cycle fires. |
| `CHUMP_INTEGRATOR_LOC_BUDGET` | `1500` | Max total estimated LOC per batch. |
| `CHUMP_INTEGRATOR_MAX_BATCH` | `10` | General selector cap (LIVE cap is the tighter of the two). |
| `CHUMP_INTEGRATOR_PREFLIGHT_TIMEOUT_S` | `480` | Preflight command timeout. |
| `CHUMP_INTEGRATOR_SAMPLING_PCT` | `100` | Phase 2 live-cycle sampling rate 0–100. |
| `CHUMP_INTEGRATOR_DO_NOT_BATCH_LABEL` | `do-not-batch` | GitHub label that opts a PR out of batching. |

---

## Ambient events

| Event | When emitted |
|---|---|
| `integration_cycle_started` | Every cycle, before candidate selection. |
| `integration_trunk_red_hold` | LIVE cycle held because trunk is RED. |
| `cycle_sampling_decision` | After CLAIM; records live vs dry-run decision. |
| `integration_candidates_selected` | After SELECT with candidate list. |
| `integration_branch_merged` | Per-candidate merge into integration branch. |
| `integration_preflight_started` | Before preflight command runs. |
| `integration_preflight_failed` | Preflight exited non-zero. |
| `integration_cycle_completed` | LIVE cycle shipped successfully; carries `pr_url`. |
| `integration_cycle_failed` | LIVE ship failed; circuit breaker armed. |
| `integration_dry_run_skip` | Cycle forced to dry-run by circuit breaker. |
| `integration_cycle_dry_run_completed` | Dry-run cycle completed normally. |
| `integration_cycle_shipped` | Legacy event kept for kpi-report consumers. |

---

## Cross-references

- INFRA-2130 — parent gap (daemon skeleton + LIVE-mode toggle)
- INFRA-2132 — ambient event kinds registered
- INFRA-2136 — C8 SHIP/BISECT step (bisect oracle, deferred)
- INFRA-2139 — Phase 2 sampling gate
- RESILIENT-050 — trunk-RED detector (provides the state file this daemon reads)
- `docs/strategy/INTEGRATION_CYCLE_2026-05-29.md` — architecture + mode taxonomy
