#!/usr/bin/env bash
# scripts/ci/test-pr-cut-honored.sh — RESILIENT-1606 / RESILIENT-1607
#
# Proves the deliberate-close contract end to end with a stubbed gh (no network):
#
#   pr-cut.sh (the sanctioned verb)
#     P1  labels BEFORE it closes, closes with the reason in the comment, creates
#         the pr-cut label when missing, emits kind=pr_cut, notes the gap
#     P2  gap store unreachable -> prints the note command, still exits 0
#     P3  refuses a MERGED PR, a missing --reason, a non-numeric PR
#     P4  --dry-run touches nothing
#
#   post-push-integrity-watch.sh (RESILIENT-1606)
#     W1  pr-cut labeled close            -> NOT reopened
#     W2  close with a human comment <60s -> NOT reopened
#     W3  close with only a bot comment   -> reopened
#     W4  human comment far from close    -> reopened
#     W5  close with NO comment (the original INFRA-2026 force-push auto-close)
#                                         -> still reopened
#     W6  comment lookup fails            -> falls back to reopening (fail-open)
#
# The reviver half (pr-cut skipped, rot-reaped label alone not enough) lives in
# scripts/ci/test-trunk-recovery-reviver.sh.
#
# Hermetic: stub gh/chump on PATH, temp sandbox repo, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRCUT="$REPO_ROOT/scripts/coord/pr-cut.sh"
WATCH="$REPO_ROOT/scripts/coord/post-push-integrity-watch.sh"

pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

for f in "$PRCUT" "$WATCH"; do
    [[ -f "$f" ]] || { echo "FAIL: $f missing"; exit 1; }
    bash -n "$f" || { echo "FAIL: bash -n $f"; exit 1; }
done

TMP="$(mktemp -d /tmp/test-pr-cut.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

_iso() {  # <seconds ago>
    python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(seconds=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

# ── Stubs ─────────────────────────────────────────────────────────────────────
# Each scenario gets a fresh dir with: fakebin/gh, fakebin/chump, and fixtures
# view.json, list.json, comments.json, labels.txt, gap.json. Every gh/chump call
# is appended (newlines flattened) to calls.log.
new_scenario() {  # <name> -> echoes dir
    local d="$TMP/$1"
    mkdir -p "$d/fakebin" "$d/repo/.chump-locks" "$d/repo/scripts/coord"
    : > "$d/calls.log"; : > "$d/repo/.chump-locks/ambient.jsonl"
    git -C "$d/repo" init -q
    git -C "$d/repo" remote add origin "git@github.com:testowner/testrepo.git"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/repo/scripts/coord/broadcast-urgent.sh"
    chmod +x "$d/repo/scripts/coord/broadcast-urgent.sh"
    : > "$d/labels.txt"
    cat > "$d/fakebin/gh" <<'STUB'
#!/usr/bin/env bash
D="$(cd "$(dirname "$0")/.." && pwd)"
printf 'gh %s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$D/calls.log"
args="$*"
case "$args" in
  "pr view"*"--json comments"*)
      [[ -f "$D/comments.fail" ]] && exit 1
      cat "$D/comments.json" 2>/dev/null || echo '{"comments":[]}'; exit 0 ;;
  "pr view"*) cat "$D/view.json"; exit 0 ;;
  "pr list"*) cat "$D/list.json"; exit 0 ;;
  "label list"*) cat "$D/labels.txt"; exit 0 ;;
  "label create"*|"pr edit"*|"pr close"*|"pr comment"*|"pr reopen"*) exit 0 ;;
esac
echo "stub gh: unhandled: $args" >&2; exit 1
STUB
    cat > "$d/fakebin/chump" <<'STUB'
#!/usr/bin/env bash
D="$(cd "$(dirname "$0")/.." && pwd)"
printf 'chump %s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "$D/calls.log"
case "$1 $2" in
  "gap show") [[ -f "$D/gap.fail" ]] && exit 1; cat "$D/gap.json"; exit 0 ;;
  "gap set")  exit 0 ;;
esac
exit 1
STUB
    chmod +x "$d/fakebin/gh" "$d/fakebin/chump"
    echo "$d"
}

run_prcut() {  # <dir> args...   (output in $dir/out.txt, exit in $dir/rc)
    local d="$1"; shift
    PATH="$d/fakebin:$PATH" CHUMP_BIN="$d/fakebin/chump" \
        CHUMP_AMBIENT_PATH="$d/repo/.chump-locks/ambient.jsonl" \
        bash "$PRCUT" "$@" > "$d/out.txt" 2>&1
    echo $? > "$d/rc"
}

line_of() {  # <dir> <pattern> -> first matching line number in calls.log (0 if none)
    grep -n -- "$2" "$1/calls.log" | head -1 | cut -d: -f1 | sed 's/^$/0/'
}

OPEN_VIEW='{"state":"OPEN","title":"CREDIBLE-1495: R1 slice (dup)","headRefName":"chump/credible-1495-fleet-1","mergedAt":null}'

# ── P1: the happy path ────────────────────────────────────────────────────────
D="$(new_scenario p1)"
echo "$OPEN_VIEW" > "$D/view.json"
echo '{"notes":"earlier note"}' > "$D/gap.json"
run_prcut "$D" 5478 --reason "duplicate of #5491, cut by the architect" --repo testowner/testrepo
rc="$(cat "$D/rc")"
[[ "$rc" == "0" ]] && ok "P1: exits 0" || bad "P1: rc=$rc; $(cat "$D/out.txt")"
grep -q 'label create pr-cut' "$D/calls.log" && ok "P1: creates the pr-cut label when missing" || bad "P1: label not created"
grep -q -- '--color 6E7781' "$D/calls.log" && ok "P1: label color 6E7781" || bad "P1: label color"
l_add="$(line_of "$D" 'pr edit 5478.*--add-label pr-cut')"
l_close="$(line_of "$D" 'pr close 5478')"
if [[ "$l_add" -gt 0 && "$l_close" -gt 0 && "$l_add" -lt "$l_close" ]]; then
    ok "P1: label added BEFORE the close (organs polling the close window see it)"
else
    bad "P1: ordering wrong (add=$l_add close=$l_close)"
fi
grep 'pr close 5478' "$D/calls.log" | grep -q 'duplicate of #5491, cut by the architect' \
    && ok "P1: close comment carries the reason" || bad "P1: reason missing from close comment"
grep -q '"kind":"pr_cut","pr":5478' "$D/repo/.chump-locks/ambient.jsonl" \
    && ok "P1: kind=pr_cut emitted" || bad "P1: pr_cut not emitted: $(cat "$D/repo/.chump-locks/ambient.jsonl")"
python3 -c "import json;[json.loads(l) for l in open('$D/repo/.chump-locks/ambient.jsonl')]" 2>/dev/null \
    && ok "P1: ambient line is valid JSON" || bad "P1: ambient line is not valid JSON"
grep 'chump gap set CREDIBLE-1495' "$D/calls.log" | grep -q 'earlier note' \
    && grep 'chump gap set CREDIBLE-1495' "$D/calls.log" | grep -q 'PR #5478 closed deliberately' \
    && ok "P1: gap note appended (earlier notes preserved)" || bad "P1: gap note not written: $(cat "$D/calls.log")"

# label already present -> not re-created
D="$(new_scenario p1b)"
echo "$OPEN_VIEW" > "$D/view.json"; echo '{"notes":""}' > "$D/gap.json"
printf 'pr-cut\t\t6E7781\n' > "$D/labels.txt"
run_prcut "$D" 5483 --reason "dup" --repo testowner/testrepo
! grep -q 'label create' "$D/calls.log" && ok "P1b: existing label is not re-created" || bad "P1b: label re-created"

# ── P2: gap store unreachable ────────────────────────────────────────────────
D="$(new_scenario p2)"
echo "$OPEN_VIEW" > "$D/view.json"; touch "$D/gap.fail"
run_prcut "$D" 5478 --reason "dup" --repo testowner/testrepo
rc="$(cat "$D/rc")"
[[ "$rc" == "0" ]] && grep -q 'chump gap set CREDIBLE-1495 --notes' "$D/out.txt" \
    && ok "P2: gap store unreachable -> prints the note command, exit 0" \
    || bad "P2: rc=$rc out=$(cat "$D/out.txt")"
! grep -q 'chump gap set' "$D/calls.log" && ok "P2: no blind gap set when show failed (cannot clobber notes)" || bad "P2: wrote notes blind"

# ── P3: refusals ─────────────────────────────────────────────────────────────
D="$(new_scenario p3a)"
echo '{"state":"MERGED","title":"X-1: y","headRefName":"chump/x-1","mergedAt":"2026-10-16T00:00:00Z"}' > "$D/view.json"
run_prcut "$D" 77 --reason "dup" --repo testowner/testrepo
[[ "$(cat "$D/rc")" == "2" ]] && ! grep -q 'pr close\|pr edit' "$D/calls.log" \
    && ok "P3: MERGED PR refused, nothing touched" || bad "P3: merged PR not refused"
D="$(new_scenario p3b)"; echo "$OPEN_VIEW" > "$D/view.json"
run_prcut "$D" 77 --repo testowner/testrepo
[[ "$(cat "$D/rc")" == "2" ]] && ! grep -q 'pr close' "$D/calls.log" \
    && ok "P3: missing --reason refused" || bad "P3: missing reason not refused"
run_prcut "$D" abc --reason x --repo testowner/testrepo
[[ "$(cat "$D/rc")" == "2" ]] && ok "P3: non-numeric PR refused" || bad "P3: non-numeric PR accepted"

# ── P4: dry run ──────────────────────────────────────────────────────────────
D="$(new_scenario p4)"; echo "$OPEN_VIEW" > "$D/view.json"
run_prcut "$D" 5478 --reason dup --dry-run --repo testowner/testrepo
! grep -q 'pr close\|pr edit\|label create\|chump gap set' "$D/calls.log" \
    && [[ ! -s "$D/repo/.chump-locks/ambient.jsonl" ]] \
    && ok "P4: --dry-run changes nothing" || bad "P4: dry-run wrote something"

# ── Watch scenarios ──────────────────────────────────────────────────────────
run_watch() {  # <dir> -> runs the real (non-dry) watch; reopen calls land in calls.log
    local d="$1"
    CHUMP_REPO="$d/repo" PATH="$d/fakebin:$PATH" bash "$WATCH" > "$d/watch.out" 2>&1 || true
}
closed_pr_json() {  # <labels-json-array> -> one closed chump/* PR closed 5s ago
    python3 - "$1" <<'PY'
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=5)
print(json.dumps([{
    "number": 5478, "headRefName": "chump/credible-1495-fleet-1", "state": "CLOSED",
    "stateReason": "NOT_PLANNED", "closedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "title": "CREDIBLE-1495: R1 slice", "labels": json.loads(sys.argv[1]), "mergedAt": None,
}]))
PY
}
comments_json() {  # <login> <seconds-ago>
    python3 - "$1" "$2" <<'PY'
import json, sys, datetime
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(sys.argv[2]))
print(json.dumps({"comments": [{"author": {"login": sys.argv[1]}, "body": "closing", "createdAt": t.strftime("%Y-%m-%dT%H:%M:%SZ")}]}))
PY
}
reopened() { grep -q 'pr reopen 5478' "$1/calls.log"; }

# W1: pr-cut label
D="$(new_scenario w1)"; closed_pr_json '[{"name":"pr-cut"}]' > "$D/list.json"
run_watch "$D"
! reopened "$D" && grep -q "SKIP reopen PR #5478.*pr-cut" "$D/watch.out" \
    && ok "W1: pr-cut labeled close is NOT reopened" || bad "W1: reopened/unlogged; $(cat "$D/watch.out")"

# W2: human comment within 60s of the close
D="$(new_scenario w2)"; closed_pr_json '[]' > "$D/list.json"; comments_json repairman29 4 > "$D/comments.json"
run_watch "$D"
! reopened "$D" && grep -q "SKIP reopen PR #5478.*repairman29" "$D/watch.out" \
    && ok "W2: close with a human comment inside 60s is NOT reopened" || bad "W2: $(cat "$D/watch.out")"

# W3: only a bot comment
D="$(new_scenario w3)"; closed_pr_json '[]' > "$D/list.json"; comments_json 'github-actions[bot]' 4 > "$D/comments.json"
run_watch "$D"
reopened "$D" && ok "W3: bot-only comment does not exempt the close (reopened)" || bad "W3: not reopened; $(cat "$D/watch.out")"
D="$(new_scenario w3b)"; closed_pr_json '[]' > "$D/list.json"; comments_json chump-fleet-bot 4 > "$D/comments.json"
run_watch "$D"
reopened "$D" && ok "W3b: listed automation login does not exempt the close (reopened)" || bad "W3b: not reopened"

# W4: human comment, but nowhere near the close
D="$(new_scenario w4)"; closed_pr_json '[]' > "$D/list.json"; comments_json repairman29 3600 > "$D/comments.json"
run_watch "$D"
reopened "$D" && ok "W4: stale human comment (1h old) does not exempt the close (reopened)" || bad "W4: not reopened"

# W5: the original INFRA-2026 incident: closed right after a force-push, no comment
D="$(new_scenario w5)"; closed_pr_json '[]' > "$D/list.json"; echo '{"comments":[]}' > "$D/comments.json"
run_watch "$D"
reopened "$D" && grep -q '"kind":"post_push_auto_close_recovered"' "$D/repo/.chump-locks/ambient.jsonl" \
    && ok "W5: uncommented close (stale-push auto-close) is still reopened + ambient recovered" \
    || bad "W5: not reopened; $(cat "$D/watch.out")"

# W6: comment lookup fails -> fail-open to the old behavior
D="$(new_scenario w6)"; closed_pr_json '[]' > "$D/list.json"; touch "$D/comments.fail"
run_watch "$D"
reopened "$D" && ok "W6: comment lookup failure falls back to reopening" || bad "W6: not reopened"

# rot-reaped label is still terminal for the watch (unchanged behavior)
D="$(new_scenario w7)"; closed_pr_json '[{"name":"rot-reaped"}]' > "$D/list.json"
run_watch "$D"
! reopened "$D" && ok "W7: rot-reaped labeled close still not reopened" || bad "W7: regression on rot-reaped"

echo
if [[ "$fail" -eq 0 ]]; then
    echo "test-pr-cut-honored: ALL $pass passed"
    exit 0
fi
echo "test-pr-cut-honored: $pass passed, $fail failed"
exit 1
