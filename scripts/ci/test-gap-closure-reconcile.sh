#!/usr/bin/env bash
# scripts/ci/test-gap-closure-reconcile.sh — META-059
#
# Verifies the --check-closure-drift mode of gap-doctor-reconcile.py:
#   1. dry-run reports drift cases without emitting
#   2. apply mode emits kind=gap_closure_drift to ambient.jsonl with all
#      required fields, one event per drifted gap
#   3. exits non-zero (rc=3) when drift is detected so cron can alert
#   4. exits 0 with no event when every closed_pr-bearing gap's PR is open
#
# Uses a fake `gh` on PATH so the test doesn't need network/auth and
# doesn't count against the REST bucket.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/gap-doctor-reconcile.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Fake `gh` and `chump` on PATH.
# `gh repo view ... -q .nameWithOwner` → "test/repo"
# `gh api repos/test/repo/pulls/9999 --jq ...` → "closed 2026-05-13T19:00:00Z" (merged)
# `gh api repos/test/repo/pulls/9998 --jq ...` → "closed -" (closed but not merged)
# `gh api repos/test/repo/pulls/9997 --jq ...` → "open -" (still open)
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "view" ]]; then
    echo "test/repo"; exit 0
fi
if [[ "$1" == "api" ]]; then
    case "$2" in
        */pulls/9999) echo "closed 2026-05-13T19:00:00Z"; exit 0 ;;
        */pulls/9998) echo "closed -"; exit 0 ;;
        */pulls/9997) echo "open -"; exit 0 ;;
        *) echo "fake-gh: unhandled $2" >&2; exit 1 ;;
    esac
fi
exit 0
EOF
chmod +x "$TMP/fakebin/gh"

# Fake `chump` — only `chump gap list --json` is called by gap-doctor-reconcile.
# We craft a JSON response with 3 gaps mapping to the 3 fake PRs above.
cat >"$TMP/fakebin/chump" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "gap" && "$2" == "list" && "$3" == "--json" ]]; then
    cat <<JSON
[
  {"id":"DRIFT-001","status":"open","closed_pr":9999,"title":"merged but still open"},
  {"id":"OK-001","status":"open","closed_pr":9998,"title":"closed-not-merged is fine"},
  {"id":"OK-002","status":"open","closed_pr":9997,"title":"still-open PR is fine"},
  {"id":"NO-PR","status":"open","title":"no closed_pr set"}
]
JSON
    exit 0
fi
exit 0
EOF
chmod +x "$TMP/fakebin/chump"

# REPO_ROOT must be a directory with a .chump-locks/ that the script can write to.
# The script computes REPO_ROOT from `git rev-parse --show-toplevel`, so we run
# it from a tiny git repo we initialize in $TMP.
GIT_REPO="$TMP/repo"
mkdir -p "$GIT_REPO/docs/gaps" "$GIT_REPO/.chump-locks"
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" config user.email t@t
git -C "$GIT_REPO" config user.name t

AMB="$GIT_REPO/.chump-locks/ambient.jsonl"

run_drift() {
    local flags="$1"
    (cd "$GIT_REPO" && PATH="$TMP/fakebin:$PATH" python3 "$SCRIPT" --check-closure-drift $flags)
    return $?
}

# ── Test 1: dry-run reports drift but doesn't emit ──────────────────────────
rm -f "$AMB"
set +e
out="$(run_drift --dry-run 2>&1)"
rc=$?
set -e
grep -q "DRIFT-001" <<<"$out" || fail "dry-run missed DRIFT-001: $out"
grep -q "OK-001" <<<"$out" && fail "dry-run shouldn't flag closed-not-merged OK-001: $out"
grep -q "OK-002" <<<"$out" && fail "dry-run shouldn't flag still-open OK-002: $out"
[[ ! -s "$AMB" ]] || fail "dry-run wrote to ambient: $(cat "$AMB")"
[[ "$rc" -eq 3 ]] || fail "dry-run rc=$rc (want 3 to alert cron)"
ok "dry-run flags merged-but-open gap, ignores other states, no ambient write"

# ── Test 2: apply mode emits one event per drift ─────────────────────────────
rm -f "$AMB"
set +e
out="$(run_drift "" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 3 ]] || fail "apply rc=$rc (want 3 — drift detected)"
[[ -s "$AMB" ]] || fail "apply mode did not write ambient line"
line="$(cat "$AMB")"
for f in '"kind":"gap_closure_drift"' '"gap_id":"DRIFT-001"' '"pr_number":9999' \
         '"merged_at":"2026-05-13T19:00:00Z"' '"source":"gap-doctor-reconcile"' '"ts":' ; do
    grep -q "$f" <<<"$line" || fail "ambient line missing $f: $line"
done
nlines=$(wc -l <"$AMB" | tr -d ' ')
[[ "$nlines" -eq 1 ]] || fail "expected 1 ambient line, got $nlines: $(cat "$AMB")"
ok "apply mode emits exactly one gap_closure_drift event with all required fields"

# ── Test 3: no-drift case (closed_pr unset everywhere) — exits 0 ────────────
# Swap chump fake to one with no closed_pr fields.
cat >"$TMP/fakebin/chump" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "gap" && "$2" == "list" && "$3" == "--json" ]]; then
    echo '[{"id":"NO-PR-1","status":"open","title":"clean"}]'
    exit 0
fi
EOF
chmod +x "$TMP/fakebin/chump"
rm -f "$AMB"
set +e
out="$(run_drift "" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "no-drift rc=$rc (want 0)"
grep -q "no open gaps with closed_pr" <<<"$out" || fail "no-drift summary missing: $out"
[[ ! -s "$AMB" ]] || fail "no-drift wrote ambient: $(cat "$AMB")"
ok "no-drift case: exit 0, no ambient writes, clean summary"

# ── Test 4: EVENT_REGISTRY.yaml registers gap_closure_drift ─────────────────
grep -q "kind: gap_closure_drift" "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" \
    || fail "gap_closure_drift not registered in EVENT_REGISTRY.yaml"
ok "EVENT_REGISTRY.yaml registers gap_closure_drift"

# ── Test 5 (CREDIBLE-1551 AC2): closure-drift closes only when the gap_prs FK ─
# links the PR to the gap. A drifted gap whose merged PR IS gap_prs-linked gets
# shipped; one whose merged PR is NOT linked is SKIPped (the ship FK-gate would
# refuse it anyway) — the drift is still surfaced for an operator to add a link.
# Fake chump answers `gaps-for-pr` and records every `gap ship` so we can see
# which drift actually closed.
cat >"$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "view" ]]; then echo "test/repo"; exit 0; fi
if [[ "$1" == "api" ]]; then
    case "$2" in
        */pulls/9999) echo "closed 2026-05-13T19:00:00Z"; exit 0 ;;  # merged, LINKED gap
        */pulls/9996) echo "closed 2026-05-14T19:00:00Z"; exit 0 ;;  # merged, UNLINKED gap
        *) echo "fake-gh: unhandled $2" >&2; exit 1 ;;
    esac
fi
exit 0
EOF
chmod +x "$TMP/fakebin/gh"
SHIPS="$TMP/ships.log"; : >"$SHIPS"
cat >"$TMP/fakebin/chump" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "gap" && "\$2" == "list" && "\$3" == "--json" ]]; then
  cat <<JSON
[
  {"id":"DRIFT-LINKED","status":"open","closed_pr":9999,"title":"linked drift"},
  {"id":"DRIFT-UNLINKED","status":"open","closed_pr":9996,"title":"unlinked drift"}
]
JSON
  exit 0
fi
if [[ "\$1" == "gap" && "\$2" == "gaps-for-pr" ]]; then
  case "\$3" in
    9999) echo "DRIFT-LINKED" ;;   # the (gap, PR) pair exists
    *) : ;;                         # 9996 → no gap_prs row (empty)
  esac
  exit 0
fi
if [[ "\$1" == "gap" && "\$2" == "ship" ]]; then
  echo "\$3 \$5" >> "$SHIPS"        # gid  --closed-pr-value
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/fakebin/chump"
rm -f "$AMB"
set +e
out="$(run_drift "" 2>&1)"
rc=$?
set -e
grep -qx "DRIFT-LINKED 9999" "$SHIPS" \
    || fail "closure-drift did not ship the FK-linked DRIFT-LINKED (ships: $(cat "$SHIPS"); out: $out)"
grep -q '^DRIFT-UNLINKED ' "$SHIPS" \
    && fail "closure-drift SHIPPED the unlinked DRIFT-UNLINKED — FK gate not consulted (ships: $(cat "$SHIPS"))"
grep -q "SKIP DRIFT-UNLINKED" <<<"$out" \
    || fail "closure-drift did not print a SKIP for the unlinked gap: $out"
# The drift is still SURFACED for both (detection precedes the link check).
grep -q '"gap_id":"DRIFT-UNLINKED"' "$AMB" \
    || fail "closure-drift did not emit gap_closure_drift for the unlinked gap: $(cat "$AMB")"
ok "closure-drift closes only the FK-linked drift; skips (but still surfaces) the unlinked one"

# 4. RESILIENT-1637: when `chump gap ship` exits non-zero, reconcile logs the
#    subprocess stderr and emits `kind=gap_close_failed` with `stderr` to ambient.
cat > "$TMP/fakebin/chump" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "gap" && "\$2" == "list" && "\$3" == "--json" ]]; then
  cat <<JSON
[
  {"id":"DRIFT-LINKED","status":"open","closed_pr":9999,"title":"linked drift"}
]
JSON
  exit 0
fi
if [[ "\$1" == "gap" && "\$2" == "gaps-for-pr" ]]; then
  echo "DRIFT-LINKED"
  exit 0
fi
if [[ "\$1" == "gap" && "\$2" == "ship" ]]; then
  echo "refusing to ship DRIFT-LINKED: simulated ship refusal reason" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$TMP/fakebin/chump"
rm -f "$AMB"
set +e
out="$(run_drift "" 2>&1)"
rc=$?
set -e
grep -q "simulated ship refusal reason" <<<"$out" \
    || fail "closure-drift did not include ship stderr in warning output: $out"
grep -q '"kind":"gap_close_failed"' "$AMB" \
    || fail "closure-drift did not emit kind=gap_close_failed on ship failure: $(cat "$AMB" 2>/dev/null || true)"
grep -q '"stderr":"refusing to ship DRIFT-LINKED: simulated ship refusal reason"' "$AMB" \
    || fail "gap_close_failed event missing stderr detail: $(cat "$AMB")"
ok "closure-drift emits kind=gap_close_failed with stderr when chump gap ship fails (RESILIENT-1637)"

echo
echo "All META-059 / CREDIBLE-1551 / RESILIENT-1637 gap-closure-reconcile tests passed."
