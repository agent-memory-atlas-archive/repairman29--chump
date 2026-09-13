#!/usr/bin/env python3
"""classify-blocked-pr.py — decide why a PR is mergeStateStatus=BLOCKED.

The stale-pr-reaper's INFRA-1410 auto-respawn loop used to close ANY PR that
sat BLOCKED past its SLO. But `mergeStateStatus=BLOCKED` is a catch-all — it
covers recoverable states (required checks still QUEUED/IN_PROGRESS, or a
required check that failed ONLY because a known flake exhausted its INFRA-304
rerun budget while the PR is otherwise green) as well as genuinely-dead states
(a hard non-flake check FAILURE, or a merge conflict). Closing a recoverable
BLOCKED PR destroys correct, in-flight work — the PR #4589 incident, where a
green PR was reaped after three flake reruns tripped the budget.

This is the pure decision function so it can be exercised directly by a test
with synthetic fixtures (Receipt Law). It reads a PR's `statusCheckRollup`
(as `gh pr view --json statusCheckRollup` returns it) plus `mergeable`, and
prints exactly one verdict to stdout:

  pending             at least one required check is still running (QUEUED /
                      IN_PROGRESS / not-yet-reported) — CI hasn't finished, so
                      the block is transient. RECOVERABLE → spare.
  flake_exhausted     every completed check that failed is attributable to a
                      known flake whose rerun budget is spent — the PR is
                      otherwise green. RECOVERABLE → re-arm the budget, spare.
  blocked_no_failure  no check is pending and none failed, yet the PR is
                      BLOCKED (e.g. a required review, or a required check that
                      has not reported). No CI death to justify a destructive
                      close. RECOVERABLE → spare.
  hard_fail           a completed check FAILED and it is NOT a known-flake
                      budget block — a real failure. DEAD → close-eligible.
  conflict            mergeable == CONFLICTING — a genuine merge conflict.
                      DEAD → close-eligible.

The reaper spares the first three and only bounces `hard_fail` / `conflict`.

── RESILIENT-311 rot-reaper reuse (green-underneath / cancelled) ──────────────
The rot-reaper's CLASS 2 closes a PR whose SOLE branch-protection-required check
`verified` (a slow AGGREGATE over cargo-test/clippy/audit/parity sub-jobs) sits
RED past an SLO. But an aggregate going red does NOT mean the work is dead: the
real gates underneath may be GREEN while `verified` is red only because a parity
mirror reported late, a sub-job was CI-cancelled, or the aggregate itself
glitched. Closing that PR destroys correct work that only needs a re-run (the
#4598/#4615/#4618 incident). To let the rot-reaper look *underneath* the
aggregate, pass `--blocking-check <regex>` naming the REAL gate checks (e.g.
`-required$|^audit-shard|^fast-checks$`, deliberately NOT `verified`). With it
set, two further verdicts become reachable:

  green_underneath    every real (blocking) gate is GREEN and only a non-blocking
                      check — the `verified` aggregate or a parity job — is red.
                      RECOVERABLE → spare (re-arm auto-merge; escalate if stuck).
  cancelled           the only failing signal is a CI-CANCELLED / STALE run (a
                      superseded push or infra cancel), not a code failure.
                      RECOVERABLE → spare (re-run will clear it).

`--blocking-check` is OPT-IN: with it ABSENT (every pre-existing caller and the
stale-pr-reaper), classification is byte-identical to the five-verdict behavior
above — the new verdicts are never emitted, so no existing consumer changes.
"""
import argparse
import json
import os
import re
import sys

# CheckRun.status values that mean "not finished yet".
_PENDING_STATUSES = {"QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED", ""}
# CheckRun.conclusion values that mean the completed check failed the gate.
_FAILING_CONCLUSIONS = {
    "FAILURE",
    "TIMED_OUT",
    "CANCELLED",
    "STARTUP_FAILURE",
    "ACTION_REQUIRED",
    "STALE",
    "ERROR",
}
# Legacy StatusContext.state values.
_STATUS_PENDING = {"PENDING", "EXPECTED", ""}
_STATUS_FAILING = {"FAILURE", "ERROR"}

# ── blocking-aware buckets (only consulted when --blocking-check is given) ─────
# A CI-CANCELLED / STALE run is a superseded push or an infra cancel, NOT a code
# failure — kept OUT of the hard-fail bucket so a cancel can be spared. (The
# legacy path, which has no --blocking-check, still treats CANCELLED via
# _FAILING_CONCLUSIONS exactly as before — this split changes nothing there.)
_HARD_FAIL_CONCLUSIONS = {
    "FAILURE",
    "TIMED_OUT",
    "STARTUP_FAILURE",
    "ACTION_REQUIRED",
    "ERROR",
}
_CANCEL_CONCLUSIONS = {"CANCELLED", "STALE"}
# Conclusions that count as a green/OK completion (a passed real gate).
_GREEN_CONCLUSIONS = {"SUCCESS", "NEUTRAL", "SKIPPED"}
_STATUS_GREEN = {"SUCCESS"}


def _rollup_states(rollup):
    """Return (any_pending, any_failing) across a statusCheckRollup list."""
    any_pending = False
    any_failing = False
    if not isinstance(rollup, list):
        return any_pending, any_failing
    for c in rollup:
        if not isinstance(c, dict):
            continue
        typ = c.get("__typename") or ""
        if typ == "StatusContext":
            state = (c.get("state") or "").upper()
            if state in _STATUS_PENDING:
                any_pending = True
            elif state in _STATUS_FAILING:
                any_failing = True
            continue
        # CheckRun (default) and any other check-shaped entry.
        status = (c.get("status") or "").upper()
        concl = (c.get("conclusion") or "").upper()
        if status != "COMPLETED":
            any_pending = True
        elif concl in _FAILING_CONCLUSIONS:
            any_failing = True
    return any_pending, any_failing


def _flake_exhausted_from_markers(cooldown_dir, pr, flake_budget):
    """Mirror ci-flake-rerun.sh's INFRA-304 budget markers.

    Exhausted iff the one-time `pr-<N>.commented` marker exists (the budget
    check posted its diagnostic), OR the `pr-<N>.count` counter has reached
    the budget. flake_budget<=0 means "unlimited reruns" — never exhausted.
    """
    if not cooldown_dir or pr is None:
        return False
    commented = os.path.join(cooldown_dir, "pr-{}.commented".format(pr))
    if os.path.isfile(commented):
        return True
    if flake_budget and flake_budget > 0:
        count_file = os.path.join(cooldown_dir, "pr-{}.count".format(pr))
        try:
            with open(count_file) as fh:
                n = int((fh.read() or "0").strip() or "0")
            if n >= flake_budget:
                return True
        except (OSError, ValueError):
            return False
    return False


def classify(rollup, mergeable, flake_exhausted):
    """Pure verdict from parsed inputs (LEGACY five-verdict path)."""
    if (mergeable or "").upper() == "CONFLICTING":
        return "conflict"
    any_pending, any_failing = _rollup_states(rollup)
    if any_pending:
        return "pending"
    if any_failing:
        return "flake_exhausted" if flake_exhausted else "hard_fail"
    return "blocked_no_failure"


def _check_name(c):
    return c.get("name") or c.get("context") or ""


def _check_kind(c):
    """Return (is_pending, is_hardfail, is_cancel, is_green) for one check."""
    typ = c.get("__typename") or ""
    if typ == "StatusContext":
        state = (c.get("state") or "").upper()
        return (
            state in _STATUS_PENDING,
            state in _STATUS_FAILING,
            False,  # StatusContext has no cancelled state
            state in _STATUS_GREEN,
        )
    # CheckRun (default) and any other check-shaped entry.
    status = (c.get("status") or "").upper()
    concl = (c.get("conclusion") or "").upper()
    if status != "COMPLETED":
        return (True, False, False, False)
    return (
        False,
        concl in _HARD_FAIL_CONCLUSIONS,
        concl in _CANCEL_CONCLUSIONS,
        concl in _GREEN_CONCLUSIONS,
    )


def classify_with_blocking(rollup, mergeable, flake_exhausted, blocking_re):
    """Aggregate-aware verdict — reachable ONLY when a blocking-check regex is
    supplied. Looks *underneath* a red aggregate: a check whose name matches
    `blocking_re` is a REAL gate (its state is decisive); every other check
    (the `verified` aggregate, a parity job) is non-blocking (informational
    about the aggregate, not proof the work is dead).

    Precedence, most-serious first:
      1. mergeable CONFLICTING                         → conflict   (dead)
      2. a blocking gate HARD-failed                   → hard_fail  (dead)
         (or flake_exhausted when the failure is a budget-spent known flake)
      3. a blocking gate is still pending              → pending    (spare)
      4. a blocking gate was CI-cancelled              → cancelled  (spare)
      5. all blocking gates green/absent, but a
         non-blocking check hard-failed AND at least
         one real gate actually passed                 → green_underneath (spare)
      6. a non-blocking check is still pending          → pending    (spare)
      7. a non-blocking check was cancelled            → cancelled  (spare)
      8. otherwise                                      → blocked_no_failure
    A lone non-blocking hard-fail with NO green real gate to vouch for the work
    (case 5's guard fails) is NOT assumed recoverable — it falls through to
    hard_fail (or flake_exhausted), so a genuinely broken PR is never spared.
    """
    if (mergeable or "").upper() == "CONFLICTING":
        return "conflict"
    try:
        pat = re.compile(blocking_re)
    except re.error:
        # A bad regex must not spare a dead PR — fall back to legacy semantics.
        return classify(rollup, mergeable, flake_exhausted)

    blk_pending = blk_hardfail = blk_cancel = blk_green = False
    non_pending = non_hardfail = non_cancel = False
    if isinstance(rollup, list):
        for c in rollup:
            if not isinstance(c, dict):
                continue
            is_pending, is_hardfail, is_cancel, is_green = _check_kind(c)
            if pat.search(_check_name(c)):
                blk_pending = blk_pending or is_pending
                blk_hardfail = blk_hardfail or is_hardfail
                blk_cancel = blk_cancel or is_cancel
                blk_green = blk_green or is_green
            else:
                non_pending = non_pending or is_pending
                non_hardfail = non_hardfail or is_hardfail
                non_cancel = non_cancel or is_cancel

    if blk_hardfail:
        return "flake_exhausted" if flake_exhausted else "hard_fail"
    if blk_pending:
        return "pending"
    if blk_cancel:
        return "cancelled"
    # No blocking gate is failing/pending/cancelled. Is the redness only on the
    # aggregate / a parity job while the real gates passed? That is green-
    # underneath — spare. Guarded on blk_green so a PR with NO passing real gate
    # can't masquerade as green-underneath.
    if non_hardfail:
        if blk_green:
            return "green_underneath"
        return "flake_exhausted" if flake_exhausted else "hard_fail"
    if non_pending:
        return "pending"
    if non_cancel:
        return "cancelled"
    return "blocked_no_failure"


def _load_rollup(path):
    if path in (None, "", "-"):
        raw = sys.stdin.read()
    else:
        with open(path) as fh:
            raw = fh.read()
    try:
        data = json.loads(raw) if raw.strip() else []
    except (ValueError, TypeError):
        return []
    # Accept either a bare rollup list or a full `gh pr view` object.
    if isinstance(data, dict):
        return data.get("statusCheckRollup") or []
    return data


def main(argv=None):
    ap = argparse.ArgumentParser(description="Classify why a PR is BLOCKED.")
    ap.add_argument("--rollup-file", default="-",
                    help="JSON file with statusCheckRollup array (or a full "
                         "gh-pr-view object); '-' for stdin.")
    ap.add_argument("--mergeable", default="",
                    help="mergeable state: MERGEABLE | CONFLICTING | UNKNOWN")
    ap.add_argument("--flake-exhausted", default=None,
                    help="explicit 0|1 override; wins over marker computation")
    ap.add_argument("--pr", default=None, help="PR number (for marker lookup)")
    ap.add_argument("--cooldown-dir", default=None,
                    help="ci-flake-cooldown dir holding pr-<N>.count / .commented")
    ap.add_argument("--flake-budget", type=int, default=3,
                    help="CHUMP_FLAKE_BUDGET (default 3); <=0 means unlimited")
    ap.add_argument("--blocking-check", default=None,
                    help="regex naming the REAL gate checks (e.g. "
                         "'-required$|^audit-shard|^fast-checks$'). When set, "
                         "enables the green_underneath / cancelled verdicts by "
                         "treating every other check as a non-decisive "
                         "aggregate. Absent (default) = legacy five-verdict "
                         "behavior, byte-identical for existing callers.")
    args = ap.parse_args(argv)

    if args.flake_exhausted is not None:
        flake_exhausted = args.flake_exhausted.strip() in ("1", "true", "True", "yes")
    else:
        flake_exhausted = _flake_exhausted_from_markers(
            args.cooldown_dir, args.pr, args.flake_budget
        )

    try:
        rollup = _load_rollup(args.rollup_file)
    except OSError:
        # Missing/unreadable rollup: no evidence of a hard failure, so treat as
        # recoverable rather than reaping on a fetch error (fail-safe: preserve
        # work). The reaper still won't close on blocked_no_failure.
        rollup = []

    if args.blocking_check:
        print(classify_with_blocking(
            rollup, args.mergeable, flake_exhausted, args.blocking_check))
    else:
        print(classify(rollup, args.mergeable, flake_exhausted))
    return 0


if __name__ == "__main__":
    sys.exit(main())
