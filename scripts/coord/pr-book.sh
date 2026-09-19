#!/usr/bin/env bash
# pr-book.sh — the PR casino book. "Manage PRs like it's your life." (INFRA-1688 lineage;
# sibling to race-control.sh which classifies the work-MIX; this prices the ODDS + EV.)
# Prices every open PR P(merge) via pr-book-model.jq (inspectable), names the cheapest
# EV-raising action, prints portfolio EV + bands, appends each prediction to
# ~/.chump/pr-book-ledger.jsonl, and emits a kind=pr_book_odds ambient event so the OS can
# consume the score (sibling to race-control.sh's race_control_mix on the same board).
#
#   pr-book.sh            price the open board, log predictions, emit odds
#   pr-book.sh --settle   score ledger predictions vs merged(=1)/closed(=0) outcomes
#                         (Brier = mean squared error), log calibration, print running Brier
#
# Ledger:      ~/.chump/pr-book-ledger.jsonl      (append-only predictions)
# Calibration: ~/.chump/pr-book-calibration.log   (REWRITTEN each --settle; a snapshot of one
#              {predicted,outcome} row per resolved PR — the shape vital-signs.sh slurps to
#              light the calibration_brier sign — plus a trailing {kind:pr_book_calibration,
#              brier} summary row that faculty-collector reads via tail -n1. Rewriting, not
#              appending, keeps vital-signs from double-counting a PR across settle runs.)
#
# Env (test/override):
#   PR_BOOK_LEDGER              ledger path
#   PR_BOOK_CALIB              calibration-log path
#   CHUMP_AMBIENT_LOG           ambient stream (default: <main-repo>/.chump-locks/ambient.jsonl,
#                               exactly where race-control.sh writes race_control_mix)
#   PR_BOOK_RAW_FIXTURE         board mode: JSON array of gh-pr-list objects, skips gh
#   PR_BOOK_OUTCOMES_FIXTURE    settle mode: JSON array of {number,state}, skips gh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; M="$(cat "$DIR/pr-book-model.jq")"
# shellcheck source=lib/calibration.sh
source "$DIR/lib/calibration.sh"
LEDGER="${PR_BOOK_LEDGER:-$HOME/.chump/pr-book-ledger.jsonl}"
CALIB="${PR_BOOK_CALIB:-$HOME/.chump/pr-book-calibration.log}"
mkdir -p "$(dirname "$LEDGER")" "$(dirname "$CALIB")" 2>/dev/null || true
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Ambient stream: default to the canonical fleet board race-control.sh writes to (the
# duty-officer/board scans .chump-locks/ambient.jsonl at the MAIN repo root), so a worktree
# still lands its odds on the shared board. Overridable via CHUMP_AMBIENT_LOG.
_GC="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)"
case "$_GC" in
  .git|"$PWD/.git") MAIN_REPO="$PWD" ;;
  *)                MAIN_REPO="$(cd "$_GC/.." && pwd 2>/dev/null || echo "$PWD")" ;;
esac
AMBIENT="${CHUMP_AMBIENT_LOG:-$MAIN_REPO/.chump-locks/ambient.jsonl}"

# ── mode select ──────────────────────────────────────────────────────────────
MODE=board
case "${1:-}" in
  --settle) MODE=settle ;;
  "")       ;;
  *)        echo "usage: pr-book.sh [--settle]" >&2; exit 2 ;;
esac

# ── settle: score the ledger's predictions against realized outcomes ──────────
if [[ "$MODE" == "settle" ]]; then
  if [[ ! -s "$LEDGER" ]]; then
    echo "== PR BOOK settle  $TS =="; echo "  ledger empty ($LEDGER) — nothing to settle"; exit 0
  fi
  # realized outcome per PR number: MERGED->1, CLOSED->0, OPEN->unresolved (excluded)
  if [[ -n "${PR_BOOK_OUTCOMES_FIXTURE:-}" ]]; then
    OUTJSON="$(cat "$PR_BOOK_OUTCOMES_FIXTURE")"
  else
    UNIQ="$(jq -r '.pr' "$LEDGER" 2>/dev/null | grep -E '^[0-9]+$' | sort -un)"
    OUTJSON="["; _first=1
    for pr in $UNIQ; do
      st="$(CHUMP_GH_CALL_CRITICALITY=background timeout 30 gh pr view "$pr" \
            --json number,state --jq '{number:.number,state:.state}' 2>/dev/null)" || st=""
      [[ -z "$st" ]] && continue
      if [[ $_first -eq 1 ]]; then _first=0; else OUTJSON+=","; fi
      OUTJSON+="$st"
    done
    OUTJSON+="]"
  fi
  OMAP="$(echo "$OUTJSON" | jq -c 'reduce .[] as $p ({};
            if   $p.state=="MERGED" then .[($p.number|tostring)]=1
            elif $p.state=="CLOSED" then .[($p.number|tostring)]=0
            else . end)' 2>/dev/null)"
  [[ -z "$OMAP" ]] && OMAP='{}'
  # Join the LATEST prediction per PR to its realized outcome, score via the
  # generic calibration component (RESILIENT-974), and rewrite the calibration
  # log — same shape as before this refactor: one {predicted,outcome} row per
  # resolved PR plus a trailing {kind:pr_book_calibration,brier} summary row.
  RES="$(calibration_settle "$LEDGER" "$OMAP" "$CALIB" pr price pr_book_prediction pr_book_calibration)"
  BRIER="$(echo "$RES" | jq -r '.brier // "n/a"')"
  RESOLVED="$(echo "$RES" | jq -r '.resolved')"
  PREDS="$(echo "$RES" | jq -r '.predictions')"
  MERGED="$(echo "$RES" | jq -r '.matched')"; CLOSED="$(echo "$RES" | jq -r '.unmatched')"
  echo "== PR BOOK settle  $TS =="
  printf "  resolved %s of %s predictions (%s merged / %s closed)\n" \
    "$RESOLVED" "$PREDS" "$MERGED" "$CLOSED"
  printf "  running Brier: %s   (0=perfect · 0.25=coin-flip · 1=worst)\n" "$BRIER"
  exit 0
fi

# ── board: price every open PR, log predictions, emit odds ────────────────────
RAW=""
if [[ -n "${PR_BOOK_RAW_FIXTURE:-}" ]]; then
  RAW="$(cat "$PR_BOOK_RAW_FIXTURE")"
else
  RAW="$(gh pr list --state open --limit 40 \
        --json number,title,mergeStateStatus,createdAt,isDraft,statusCheckRollup,headRefOid 2>/dev/null)"
fi
[[ -z "${RAW// }" ]] && RAW='[]'

echo "== PR BOOK  $TS =="
printf "  %-6s %-4s %-8s %-2s %-4s %-22s %s\n" PR P MERGE F AGE ACTION TITLE
echo "$RAW" | jq -r "$M"' [.[]|{n:.number,p:((price*100)|floor),ms:.mergeStateStatus,f:(fails|length),a:(age|floor),act:action,t:(.title[0:38])}]|sort_by(-.p)|.[]|"\(.n)\t\(.p)\t\(.ms)\t\(.f)\t\(.a)\t\(.act)\t\(.t)"' 2>/dev/null | \
  while IFS=$'\t' read -r n p ms f a act t; do printf "  #%-5s %-4s %-8s %-2s %-4s %-22s %s\n" "$n" "${p}%" "$ms" "$f" "$a" "$act" "$t"; done

EV="$(echo "$RAW" | jq "$M"' [.[]|price]|add' 2>/dev/null)"; [[ -z "$EV" || "$EV" == "null" ]] && EV=0
N="$(echo "$RAW" | jq 'length' 2>/dev/null)"; [[ -z "$N" ]] && N=0
LOCK="$(echo "$RAW" | jq "$M"' [.[]|select(price>=0.70)]|length' 2>/dev/null)"; [[ -z "$LOCK" ]] && LOCK=0
FLIP="$(echo "$RAW" | jq "$M"' [.[]|select(price>=0.40 and price<0.70)]|length' 2>/dev/null)"; [[ -z "$FLIP" ]] && FLIP=0
LONG="$(echo "$RAW" | jq "$M"' [.[]|select(price<0.40)]|length' 2>/dev/null)"; [[ -z "$LONG" ]] && LONG=0
printf "  -- EV %.1f of %s open  |  lock>=70:%s flip:%s long<40:%s\n" "$EV" "$N" "$LOCK" "$FLIP" "$LONG"

# append predictions to the ledger (fuel for --settle)
echo "$RAW" | jq -c "$M"' .[]|{ts:"'"$TS"'",pr:.number,sha:.headRefOid,price:(price),state:.mergeStateStatus}' 2>/dev/null >> "$LEDGER"

# emit odds onto the shared ambient board so the OS can consume the score.
# Brier: read the SAME canonical trailing {kind:pr_book_calibration,brier}
# summary row (by reference, tail -n1) that vital-signs.sh/faculty-collector.sh
# cite — cockpit is a third reader of the one column, never a recompute.
CAL_BRIER="$(tail -n1 "$CALIB" 2>/dev/null | jq -r 'select(.kind=="pr_book_calibration") | .brier // empty' 2>/dev/null)"
[[ "$CAL_BRIER" =~ ^[0-9]+([.][0-9]+)?$ ]] || CAL_BRIER="null"

# emit odds onto the shared ambient board so the OS can consume the score
# scanner-anchor: "kind":"pr_book_odds"
ODDS="$(jq -cn --arg ts "$TS" --argjson ev "$(printf %.1f "$EV")" --argjson open "$N" \
  --argjson lock "$LOCK" --argjson flip "$FLIP" --argjson long "$LONG" \
  --argjson brier "$CAL_BRIER" \
  '{ts:$ts,kind:"pr_book_odds",ev:$ev,open:$open,bands:{lock:$lock,flip:$flip,long:$long},brier:$brier}')"
if [[ -n "$ODDS" ]]; then
  mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
  echo "$ODDS" >> "$AMBIENT" 2>/dev/null || true
fi
