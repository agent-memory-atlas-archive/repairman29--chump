#!/usr/bin/env bash
# scripts/coord/trunk-recovery-reviver.sh — RESILIENT-1190
#
# The RECOVERY counterpart to RESILIENT-1188 (rot-reaper systemic-red HOLD).
#
# RESILIENT-1188 stopped NEW victims: when the trunk-sentinel says main is RED,
# the rot-reaper HOLDS required-red PRs instead of closing them (their redness is
# inherited from the broken trunk, not their own work). But that guard only
# protects PRs while it is live. PRs that already died to a LEGACY trunk-red
# (before the hold existed) — or to any non-trunk-aware closer — stay closed
# forever, their branches rotting. This organ reopens exactly those.
#
# TRIGGER: a trunk RECOVERY. The trunk-sentinel-daemon emits, on a RED→GREEN
# transition, kind=trunk_recovered AND (unconditionally) kind=trunk_state_change
# from=TRUNK_RED to=TRUNK_GREEN. We consume EITHER as the recovery signal — the
# state_change fires even for short reds that never filed a fix-trunk gap (where
# the daemon's own trunk_recovered emit is skipped), so keying off both makes the
# reviver robust on legacy ambient data with no daemon-augmented fields.
#
# THE RED WINDOW: [onset, recovered]. recovered = the recovery event's ts. onset
# = the most recent trunk-red event (trunk_state_change to=TRUNK_RED or
# trunk_red_persistent) STRICTLY BEFORE that recovery. Derived purely from
# ambient.jsonl — no dependency on daemon state files, so legacy windows resolve.
#
# VICTIM SELECTION (all must hold — conservative on purpose):
#   1. Closed (state=CLOSED, mergedAt empty) within the red window (± margin).
#   2. Reaper-closed: bears the `rot-reaped` label OR has a pr_reaped ambient
#      event. NEVER a human-close (those carry no such marker).
#   3. NOT genuinely dead NOW: re-classified via classify-blocked-pr.py against
#      the PR's CURRENT statusCheckRollup + mergeable. A verdict of hard_fail or
#      conflict => the PR's OWN work is broken (not a trunk victim) => SKIP. Any
#      recoverable verdict (pending / flake_exhausted / blocked_no_failure) or a
#      clean MERGEABLE => green-underneath => a true trunk-red victim => REVIVE.
#      This re-classification is the discriminator that keeps legitimately-dead
#      PRs closed: a PR reaped for a real conflict is still CONFLICTING now.
#   4. NOT superseded: its gap is not already done/shipped (a fresh PR replaced
#      it, or it was an intentional dupe-close).
#
# REVIVE: `gh pr reopen`; on GitHub's "Could not open the pull request" limbo,
# fall back to opening a FRESH PR for the same branch (the branch still exists);
# then re-arm auto-merge (via the sanctioned auto-merge-armer.sh) so it lands
# once green. Emits
# kind=pr_revived_post_trunk_recovery per PR.
#
# BOUNDED + IDEMPOTENT: caps revives per run (CHUMP_TRUNK_REVIVE_MAX_PER_RUN,
# default 5); a state file records processed recovery keys + revived PRs so a
# re-revive (or reviving an already-open / re-closed PR) can't happen.
#
# scanner-anchor: "kind":"pr_revived_post_trunk_recovery"
# scanner-anchor: "kind":"trunk_recovery_reviver_tick"
#
# Usage:
#   bash scripts/coord/trunk-recovery-reviver.sh              # one beat
#   bash scripts/coord/trunk-recovery-reviver.sh --dry-run    # detect only
#   bash scripts/coord/trunk-recovery-reviver.sh --decide FIXTURE.json
#                                                # pure victim-decision (test)
#   bash scripts/coord/trunk-recovery-reviver.sh --window     # print red window
#   bash scripts/coord/trunk-recovery-reviver.sh --help
#
# Env knobs (all optional; NONE is a bypass/skip/ignore switch):
#   CHUMP_TRUNK_REVIVE_DRY_RUN            non-empty → no gh writes
#   CHUMP_TRUNK_REVIVE_MAX_PER_RUN        cap revives per beat (default 5)
#   CHUMP_TRUNK_REVIVE_WINDOW_MARGIN_S    slop added to each window edge (default 300)
#   CHUMP_TRUNK_REVIVE_RECOVERY_MAX_AGE_MIN  ignore recoveries older than this so a
#                                         long-past recovery never re-revives (default 180)
#   CHUMP_TRUNK_REVIVE_STATE_FILE         state path (default $REPO_ROOT/.chump-locks/trunk-recovery-reviver-state.json)
#   CHUMP_TRUNK_REVIVE_MOCK_PRS_JSON      test: closed-PR fixture (array) instead of gh
#   CHUMP_ROT_REAPER_LABEL                terminal-close label (default rot-reaped)
#   CHUMP_AMBIENT_PATH / CHUMP_AMBIENT_LOG  ambient.jsonl override (META-248)
#   CHUMP_TRUNK_REVIVE_REPO               owner/repo (default repairman29/chump)

set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AMBIENT="${CHUMP_AMBIENT_PATH:-${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}}"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true

STATE_FILE="${CHUMP_TRUNK_REVIVE_STATE_FILE:-$REPO_ROOT/.chump-locks/trunk-recovery-reviver-state.json}"
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

CLASSIFIER="$REPO_ROOT/scripts/ops/lib/classify-blocked-pr.py"
LABEL="${CHUMP_ROT_REAPER_LABEL:-rot-reaped}"
REPO="${CHUMP_TRUNK_REVIVE_REPO:-repairman29/chump}"

MAX_PER_RUN="${CHUMP_TRUNK_REVIVE_MAX_PER_RUN:-5}"
WINDOW_MARGIN_S="${CHUMP_TRUNK_REVIVE_WINDOW_MARGIN_S:-300}"
RECOVERY_MAX_AGE_MIN="${CHUMP_TRUNK_REVIVE_RECOVERY_MAX_AGE_MIN:-180}"

DRY_RUN="${CHUMP_TRUNK_REVIVE_DRY_RUN:-}"
MODE="beat"
DECIDE_FIXTURE=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        --window)   MODE="window" ;;
        --decide)   MODE="decide" ;;
        --help|-h)  sed -n '2,60p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)          [[ "$MODE" == "decide" && -z "$DECIDE_FIXTURE" ]] && DECIDE_FIXTURE="$arg" ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[trunk-revive] %s\n' "$*" >&2; }

emit() {  # $1=kind  $2=extra-json (no leading comma)
    local kind="$1" extra="${2:-}" ts; ts="$(_ts)"
    local dry; if [[ -n "$DRY_RUN" ]]; then dry="true"; else dry="false"; fi
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"dry_run\":$dry,$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"dry_run\":$dry}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
}

# ── (1) Derive the red window from ambient trunk events ───────────────────────
# Echoes three space-separated fields: <recovered_epoch> <onset_epoch> <recovered_iso>
# recovered_epoch=0 means "no fresh recovery to act on". onset_epoch=0 means the
# onset could not be located (a recovery with no preceding red event in ambient)
# — treated as "no actionable window" (fail-safe: revive nothing).
_derive_window() {
    AMBIENT="$AMBIENT" MAXAGE="$RECOVERY_MAX_AGE_MIN" python3 <<'PY' 2>/dev/null || echo "0 0 "
import json, os, sys
from datetime import datetime, timezone

path = os.environ.get("AMBIENT", "")
try:
    maxage = float(os.environ.get("MAXAGE", "180") or "180")
except ValueError:
    maxage = 180.0

def parse(ts):
    try:
        return datetime.fromisoformat((ts or "").replace("Z", "+00:00"))
    except Exception:
        return None

events = []
try:
    fh = open(path)
except OSError:
    print("0 0 ")
    sys.exit(0)
with fh:
    for line in fh:
        line = line.strip()
        if not line or "trunk" not in line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        kind = e.get("kind", "")
        ts = parse(e.get("ts"))
        if ts is None:
            continue
        # Classify each trunk event as a recovery (green), a red-onset, or neither.
        rec = False
        red = False
        if kind == "trunk_recovered":
            rec = True
        elif kind == "trunk_red_persistent":
            red = True
        elif kind == "trunk_state_change":
            to = (e.get("to") or "").upper()
            if to == "TRUNK_GREEN":
                rec = True
            elif to == "TRUNK_RED":
                red = True
        else:
            continue
        events.append((ts, rec, red))

if not events:
    print("0 0 ")
    sys.exit(0)

events.sort(key=lambda x: x[0])
# Freshest recovery event.
rec_ts = None
for ts, rec, _red in reversed(events):
    if rec:
        rec_ts = ts
        break
if rec_ts is None:
    print("0 0 ")
    sys.exit(0)

age_min = (datetime.now(timezone.utc) - rec_ts).total_seconds() / 60.0
if age_min > maxage:
    print("0 0 ")
    sys.exit(0)

# Onset = the most recent red event strictly before the recovery.
onset_ts = None
for ts, _rec, red in reversed(events):
    if red and ts < rec_ts:
        onset_ts = ts
        break

rec_epoch = int(rec_ts.timestamp())
onset_epoch = int(onset_ts.timestamp()) if onset_ts is not None else 0
print("%d %d %s" % (rec_epoch, onset_epoch,
                    rec_ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")))
PY
}

# ── (2) Pure victim decision ─────────────────────────────────────────────────
# Reads a single PR's JSON on stdin plus window bounds + reaper-marker flag in
# the environment; prints "revive" or "skip:<reason>". Hermetic (no gh) so a
# test can drive every branch with fixtures.
#
# The PR JSON is passed via the PR_JSON env var (NOT stdin): the python program
# body itself arrives on stdin via the heredoc, so stdin is unavailable for data.
# Env in: PR_JSON (the PR object), WIN_LO WIN_HI (epoch, inclusive, already
# margin-padded), REAPER_MARKED (1|0), GAP_STATUS (lowercase gap status or ""),
# CLASSIFY_VERDICT (the classify-blocked-pr.py verdict from the live rollup, or
# "" when unknown → treated as recoverable, since a reaper-marked in-window PR
# with no live evidence of a hard fail is a likely victim).
_decide_one() {  # <pr_json> <win_lo> <win_hi> <reaper_marked> <gap_status> <classify_verdict>
    PR_JSON="$1" WIN_LO="$2" WIN_HI="$3" REAPER_MARKED="$4" GAP_STATUS="$5" CLASSIFY_VERDICT="$6" \
    python3 <<'PY' 2>/dev/null || echo "skip:decider_error"
import json, os, sys
lo = int(os.environ.get("WIN_LO", "0") or "0")
hi = int(os.environ.get("WIN_HI", "0") or "0")
reaper_marked = os.environ.get("REAPER_MARKED", "0") == "1"
gap_status = (os.environ.get("GAP_STATUS", "") or "").lower()
verdict = (os.environ.get("CLASSIFY_VERDICT", "") or "").lower()

from datetime import datetime, timezone
def epoch(ts):
    try:
        return int(datetime.fromisoformat((ts or "").replace("Z", "+00:00")).timestamp())
    except Exception:
        return None

try:
    pr = json.loads(os.environ.get("PR_JSON", "") or "{}")
except Exception:
    print("skip:bad_pr_json"); sys.exit(0)

state = (pr.get("state") or "").upper()
merged_at = pr.get("mergedAt") or pr.get("mergedat") or ""
closed_at = pr.get("closedAt") or pr.get("closedat") or ""

# Must be a closed-not-merged PR.
if merged_at:
    print("skip:merged"); sys.exit(0)
if state and state != "CLOSED":
    print("skip:not_closed"); sys.exit(0)

# Closed within the red window (± margin already applied to lo/hi).
ce = epoch(closed_at)
if ce is None:
    print("skip:no_closed_at"); sys.exit(0)
if not (lo <= ce <= hi):
    print("skip:out_of_window"); sys.exit(0)

# Reaper-closed (label or ambient pr_reaped event). A human close has neither.
if not reaper_marked:
    print("skip:not_reaper_closed"); sys.exit(0)

# Not superseded: gap already done/shipped => a fresh PR replaced it.
if gap_status in ("done", "shipped", "closed", "merged"):
    print("skip:gap_%s" % gap_status); sys.exit(0)

# Genuinely-dead discriminator: hard_fail / conflict NOW => the PR's own work is
# broken, not a trunk victim. Any other verdict (incl. unknown) is recoverable.
if verdict in ("hard_fail", "conflict"):
    print("skip:still_%s" % verdict); sys.exit(0)

print("revive")
PY
}

# ── State (idempotency) helpers ───────────────────────────────────────────────
_load_state() { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" 2>/dev/null || echo '{}'; }

_already_revived() {  # <recovery_key> <pr_num>
    local key="$1" pr="$2"
    KEY="$key" PR="$pr" STATE="$(_load_state)" python3 <<'PY' 2>/dev/null
import json, os
s = json.loads(os.environ.get("STATE", "{}") or "{}")
rev = s.get("revived", {})
prs = set(str(x) for x in rev.get(os.environ.get("KEY", ""), []))
raise SystemExit(0 if os.environ.get("PR", "") in prs else 1)
PY
}

_record_revived() {  # <recovery_key> <pr_num>
    local key="$1" pr="$2"
    local body
    body="$(KEY="$key" PR="$pr" STATE="$(_load_state)" python3 <<'PY' 2>/dev/null
import json, os
s = json.loads(os.environ.get("STATE", "{}") or "{}")
rev = s.setdefault("revived", {})
lst = rev.setdefault(os.environ.get("KEY", ""), [])
pr = os.environ.get("PR", "")
if pr and pr not in [str(x) for x in lst]:
    lst.append(pr)
# Keep only the 20 most-recent recovery keys so the file cannot grow unbounded.
if len(rev) > 20:
    for k in list(rev.keys())[:-20]:
        rev.pop(k, None)
print(json.dumps(s))
PY
)"
    [[ -n "$body" ]] && printf '%s\n' "$body" > "$STATE_FILE"
}

# ── --decide mode: fixture-driven pure decision (for the test) ────────────────
# Fixture JSON: {"win_lo":E,"win_hi":E,"prs":[{pr fields, "reaper_marked":1,
# "gap_status":"", "classify_verdict":""}, ...]}. Prints "<pr> <decision>" lines.
if [[ "$MODE" == "decide" ]]; then
    [[ -z "$DECIDE_FIXTURE" || ! -f "$DECIDE_FIXTURE" ]] && { echo "ERROR: --decide needs a fixture path" >&2; exit 2; }
    win_lo="$(python3 -c "import json,sys; print(json.load(open('$DECIDE_FIXTURE')).get('win_lo',0))")"
    win_hi="$(python3 -c "import json,sys; print(json.load(open('$DECIDE_FIXTURE')).get('win_hi',0))")"
    n="$(python3 -c "import json,sys; print(len(json.load(open('$DECIDE_FIXTURE')).get('prs',[])))")"
    for i in $(seq 0 $((n - 1))); do
        pr_json="$(python3 -c "import json,sys; print(json.dumps(json.load(open('$DECIDE_FIXTURE'))['prs'][$i]))")"
        num="$(printf '%s' "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))")"
        rm_flag="$(printf '%s' "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('reaper_marked',0))")"
        gstat="$(printf '%s' "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('gap_status',''))")"
        cverd="$(printf '%s' "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('classify_verdict',''))")"
        decision="$(_decide_one "$pr_json" "$win_lo" "$win_hi" "$rm_flag" "$gstat" "$cverd")"
        printf '%s %s\n' "$num" "$decision"
    done
    exit 0
fi

# ── --window mode: print the derived red window and exit ──────────────────────
if [[ "$MODE" == "window" ]]; then
    read -r rec_epoch onset_epoch rec_iso < <(_derive_window)
    printf 'recovered_epoch=%s onset_epoch=%s recovered_iso=%s\n' \
        "${rec_epoch:-0}" "${onset_epoch:-0}" "${rec_iso:-}"
    exit 0
fi

# ── (3) Beat: derive window → find victims → revive ───────────────────────────
main_beat() {
    local rec_epoch onset_epoch rec_iso
    read -r rec_epoch onset_epoch rec_iso < <(_derive_window)
    rec_epoch="${rec_epoch:-0}"; onset_epoch="${onset_epoch:-0}"

    if [[ "$rec_epoch" -eq 0 || "$onset_epoch" -eq 0 ]]; then
        log "no actionable trunk-recovery window (rec=$rec_epoch onset=$onset_epoch) — nothing to revive"
        emit "trunk_recovery_reviver_tick" "\"actionable\":false,\"revived\":0"
        return 0
    fi

    local win_lo=$(( onset_epoch - WINDOW_MARGIN_S ))
    local win_hi=$(( rec_epoch + WINDOW_MARGIN_S ))
    local recovery_key="$rec_iso"
    log "trunk recovered at $rec_iso; red window [$onset_epoch,$rec_epoch] (±${WINDOW_MARGIN_S}s) key=$recovery_key"

    # Fetch closed-not-merged PRs (mock in tests). We over-fetch (last 100
    # closed) and window-filter in the decision function.
    local prs_json
    if [[ -n "${CHUMP_TRUNK_REVIVE_MOCK_PRS_JSON:-}" && -f "${CHUMP_TRUNK_REVIVE_MOCK_PRS_JSON}" ]]; then
        prs_json="$(cat "$CHUMP_TRUNK_REVIVE_MOCK_PRS_JSON")"
    else
        prs_json="$(gh pr list --repo "$REPO" --state closed --limit 100 \
            --json number,headRefName,state,closedAt,mergedAt,title,labels 2>/dev/null || echo '[]')"
    fi

    local revived=0 examined=0
    while IFS= read -r pr_json; do
        [[ -z "$pr_json" ]] && continue
        [[ "$revived" -ge "$MAX_PER_RUN" ]] && { log "hit MAX_PER_RUN=$MAX_PER_RUN cap — stopping"; break; }
        examined=$((examined + 1))

        local num branch
        num="$(printf '%s' "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))" 2>/dev/null)"
        branch="$(printf '%s' "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('headRefName',''))" 2>/dev/null)"
        [[ -z "$num" ]] && continue

        # Idempotency: skip if we already revived this PR for this recovery.
        if _already_revived "$recovery_key" "$num"; then
            continue
        fi

        # Reaper-marker: label on the PR, OR a pr_reaped ambient event for it.
        local reaper_marked=0
        if printf '%s' "$pr_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
labels=[ (l.get('name') if isinstance(l,dict) else l) for l in (d.get('labels') or []) ]
sys.exit(0 if '$LABEL' in labels else 1)
" 2>/dev/null; then
            reaper_marked=1
        elif grep -q "\"kind\":\"pr_reaped\".*\"pr\":$num\b" "$AMBIENT" 2>/dev/null; then
            reaper_marked=1
        fi

        # Gap status (superseded check): look up the gap this PR's branch encodes
        # (chump/<gap>-...). Best-effort; unknown => "" (not superseded).
        local gap_status=""
        local gap_id
        gap_id="$(printf '%s' "$branch" | sed -n 's#^chump/\([A-Za-z]*-*[0-9]\{1,\}\).*#\1#p' | tr '[:lower:]' '[:upper:]')"
        if [[ -n "$gap_id" ]] && command -v chump >/dev/null 2>&1 && [[ -z "${CHUMP_TRUNK_REVIVE_MOCK_PRS_JSON:-}" ]]; then
            gap_status="$(chump gap show "$gap_id" --json 2>/dev/null | python3 -c "import json,sys; print((json.load(sys.stdin).get('status') or '').lower())" 2>/dev/null || echo "")"
        fi

        # Live re-classification (skip in mock mode; fixture carries the verdict).
        local classify_verdict=""
        if [[ -z "${CHUMP_TRUNK_REVIVE_MOCK_PRS_JSON:-}" ]]; then
            local view_json
            view_json="$(gh pr view "$num" --repo "$REPO" --json statusCheckRollup,mergeable 2>/dev/null || echo '{}')"
            local mergeable
            mergeable="$(printf '%s' "$view_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mergeable','') or '')" 2>/dev/null)"
            classify_verdict="$(printf '%s' "$view_json" | python3 "$CLASSIFIER" --rollup-file - --mergeable "$mergeable" 2>/dev/null || echo "")"
        else
            classify_verdict="$(printf '%s' "$pr_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('classify_verdict','') or '')" 2>/dev/null)"
        fi

        local decision
        decision="$(_decide_one "$pr_json" "$win_lo" "$win_hi" "$reaper_marked" "$gap_status" "$classify_verdict")"
        if [[ "$decision" != "revive" ]]; then
            log "PR #$num: $decision"
            continue
        fi

        log "PR #$num ($branch): trunk-red victim — reviving"
        if [[ -n "$DRY_RUN" ]]; then
            log "  DRY_RUN: would reopen (or fresh-PR) + re-arm auto-merge for #$num"
            emit "pr_revived_post_trunk_recovery" \
                "\"pr\":$num,\"branch\":\"$(printf '%s' "$branch" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip())[1:-1])')\",\"method\":\"dry_run\",\"recovered_at\":\"$rec_iso\""
            revived=$((revived + 1))
            _record_revived "$recovery_key" "$num"
            continue
        fi

        # Reopen; on GitHub's reopen-limbo, open a FRESH PR for the same branch.
        local method="reopen" ok=0
        if gh pr reopen "$num" --repo "$REPO" >/dev/null 2>&1; then
            ok=1
        else
            log "  reopen #$num refused — opening a fresh PR for branch $branch"
            local new_pr
            new_pr="$(gh pr create --repo "$REPO" --base main --head "$branch" \
                --title "revive: trunk-red victim (was #$num)" \
                --body "Reopened by the trunk-recovery reviver (RESILIENT-1190): #$num was closed during a trunk-red window and is green-underneath now. Original branch \`$branch\`." \
                2>/dev/null | sed -n 's#.*/pull/\([0-9]\{1,\}\).*#\1#p' | tail -1)"
            if [[ -n "$new_pr" ]]; then
                method="fresh_pr"; num="$new_pr"; ok=1
            fi
        fi

        if [[ "$ok" -ne 1 ]]; then
            log "  WARN: could not reopen or fresh-PR #$num (branch may be gone) — surfacing only"
            emit "pr_revived_post_trunk_recovery" \
                "\"pr\":$num,\"branch\":\"$(printf '%s' "$branch" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip())[1:-1])')\",\"method\":\"failed\",\"recovered_at\":\"$rec_iso\""
            _record_revived "$recovery_key" "$num"
            continue
        fi

        # Re-arm auto-merge so the revived PR lands once green. Route through the
        # sanctioned single-owner armer (INFRA-1113) — NOT a raw `gh pr merge`
        # (INFRA-1274 hot-path lint): it enforces arm-spacing against GitHub
        # secondary rate limits AND picks squash-vs-merge-queue correctly
        # (INFRA-1377), which a raw `--squash` gets wrong under an active queue.
        ARMER="$SCRIPT_DIR/auto-merge-armer.sh"
        if [[ -x "$ARMER" ]]; then
            bash "$ARMER" --pr "$num" --repo "$REPO" >/dev/null 2>&1 \
                || log "  WARN: re-arm auto-merge failed for #$num (left open)"
        else
            log "  WARN: auto-merge-armer.sh missing — #$num left open (not armed)"
        fi

        emit "pr_revived_post_trunk_recovery" \
            "\"pr\":$num,\"branch\":\"$(printf '%s' "$branch" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip())[1:-1])')\",\"method\":\"$method\",\"recovered_at\":\"$rec_iso\""
        log "  revived #$num ($method) + re-armed auto-merge"
        revived=$((revived + 1))
        _record_revived "$recovery_key" "$num"
    done < <(printf '%s' "$prs_json" | python3 -c "
import json, sys
try:
    prs = json.load(sys.stdin)
except Exception:
    prs = []
for p in (prs or []):
    print(json.dumps(p))
")

    log "beat complete: examined=$examined revived=$revived (window $onset_epoch..$rec_epoch)"
    emit "trunk_recovery_reviver_tick" "\"actionable\":true,\"examined\":$examined,\"revived\":$revived,\"recovered_at\":\"$rec_iso\""
    return 0
}

main_beat
