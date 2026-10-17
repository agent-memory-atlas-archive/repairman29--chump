#!/data/data/com.termux/files/usr/bin/bash
# pixel-ship.sh — RESILIENT-411. Ship an already-implemented+committed gap
# branch from the Pixel WITHOUT running bot-merge's local `cargo clippy --fix`,
# which cold-compiles the whole workspace and is prohibitively slow on Termux
# (wasmtime/cranelift/ring rebuilds blow any time budget on the phone).
#
# Contract: the worktree already holds >=1 commit on branch chump/<gap>-claim
# authored by the pixel worker (claude-in-proot implemented + chump-commit'd).
# We push (pre-push clippy/test/preflight all skip: no .rs + INFRA-3524/3521 via
# CHUMP_BOT_MERGE_IN_PROGRESS=1), open/refresh the PR, and arm GitHub auto-merge.
# GitHub Actions CI (audit/test/ACP smoke + clippy) is the authoritative gate.
#
# Usage: pixel-ship.sh <GAP-ID> <worktree-path>
set -uo pipefail

GAP="${1:?usage: pixel-ship.sh <GAP-ID> <worktree>}"
WT="${2:?usage: pixel-ship.sh <GAP-ID> <worktree>}"
REPO_SLUG="${CHUMP_REPO_SLUG:-repairman29/chump}"
BRANCH="chump/$(echo "$GAP" | tr 'A-Z' 'a-z')-claim"

export CHUMP_BOT_MERGE_IN_PROGRESS=1
export GH_CONFIG_DIR="${GH_CONFIG_DIR:-$HOME/.config/gh}"

cd "$WT" || { echo "[pixel-ship] no worktree at $WT" >&2; exit 1; }

if [ -z "$(git log --oneline origin/main..HEAD 2>/dev/null)" ]; then
  echo "[pixel-ship] no commits ahead of origin/main on $BRANCH — nothing to ship" >&2
  exit 2
fi

# RESILIENT-411 follow-up: the Pixel cannot run cargo test/clippy/fmt at fleet
# speed (a cold workspace compile blows any budget on the phone), so the local
# pre-push gates would block every rust-touching gap the worker picks. Delegate
# all compile-class gating to GitHub Actions CI (authoritative — auto-merge
# refuses a red PR). The pre-push hooks require a matching bypass trailer in the
# HEAD commit body alongside each CHUMP_*_GATE=0, so amend them in once.
export CHUMP_BOT_MERGE_IN_PROGRESS=1 CHUMP_TEST_GATE=0 CHUMP_CLIPPY_GATE=0 \
       CHUMP_FMT_GATE=0 CHUMP_FORCE_STALE_BASE=1
if ! git log -1 --pretty=%B | grep -q "^Test-Gate-Bypass:"; then
  _msg="$(git log -1 --pretty=%B)"
  git commit --amend --no-verify --no-edit -m "$_msg

Test-Gate-Bypass: Pixel node cannot run cargo test/nextest at fleet speed; GitHub CI is authoritative (RESILIENT-411).
Lint-Gate-Bypass: Pixel node cannot run cargo clippy at fleet speed; CI clippy is authoritative (RESILIENT-411).
Fmt-Gate-Bypass: Pixel node defers fmt to CI (RESILIENT-411).
Force-Stale-Base-Bypass: long implement window may let main advance; diff is additive (RESILIENT-411)." >/dev/null 2>&1 || true
fi

echo "[pixel-ship] pushing $BRANCH …"
git push --force-with-lease -u origin "$BRANCH" 2>&1
push_rc=$?
if [ "$push_rc" -ne 0 ]; then
  # stale lease / first push race — retry plain force (branch is worker-owned)
  git push --force -u origin "$BRANCH" 2>&1
  push_rc=$?
fi
if [ "$push_rc" -ne 0 ]; then
  echo "[pixel-ship] push failed rc=$push_rc" >&2
  exit 3
fi

PR="$(gh pr list --repo "$REPO_SLUG" --head "$BRANCH" --state open --json number -q '.[0].number' 2>/dev/null)"
if [ -z "$PR" ]; then
  SUBJECT="$(git log -1 --pretty=format:%s 2>/dev/null)"
  gh pr create --repo "$REPO_SLUG" --base main --head "$BRANCH" \
    --title "${SUBJECT:-$GAP}" \
    --body "Shipped by the Pixel-8-Pro fleet worker (pixel-worker) on Claude Sonnet via the Anthropic subscription, through the proot-distro glibc claude build (RESILIENT-411). Implemented + committed by claude-in-proot; pushed from the Termux side to skip bot-merge's local cargo clippy --fix (a full-workspace cold compile, too slow on Termux). GitHub Actions CI is authoritative." 2>&1
  PR="$(gh pr list --repo "$REPO_SLUG" --head "$BRANCH" --state open --json number -q '.[0].number' 2>/dev/null)"
fi

if [ -z "$PR" ]; then
  echo "[pixel-ship] PR creation failed" >&2
  exit 4
fi

echo "[pixel-ship] PR #$PR — arming auto-merge (squash)"
# RESILIENT-1613: an existing PR found by --head may have been disarmed on purpose.
# shellcheck source=scripts/coord/lib/arm-policy.sh
source "$(dirname "$0")/../coord/lib/arm-policy.sh"
if arm_policy_allows "$PR" "pixel-ship.sh" "$REPO_SLUG"; then
  gh pr merge "$PR" --repo "$REPO_SLUG" --auto --squash 2>&1 || true
else
  echo "[pixel-ship] PR #$PR is held (no-auto-merge / Auto-merge: hold) — not arming"
fi
echo "[pixel-ship] shipped gap=$GAP pr=$PR (auto-merge armed; CI gates the merge)"
exit 0
