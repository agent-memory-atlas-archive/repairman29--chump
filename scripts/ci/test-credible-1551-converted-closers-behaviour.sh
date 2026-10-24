#!/usr/bin/env bash
# test-credible-1551-converted-closers-behaviour.sh — CREDIBLE-1551 (Phase R R2, AC2).
#
# BEHAVIOURAL proof that the two converted title-regex closers now close a gap
# ONLY from the typed gap_prs FK (`chump gap gaps-for-pr`), never a PR title:
#
#   scripts/ops/stale-pr-reaper.sh      (INFRA-674 "ghost-status" block)
#   scripts/coord/chump-pr-triage.sh    (`--apply <pr> ship-gap`)
#
# The existing test-ghost-status-reaper.sh cannot catch a title-regex relapse:
# its gh stub returns a title AND its chump stub's `gaps-for-pr` returns the
# SAME gap the title names, so a reaper reading either source passes. This test
# DIVERGES the two sources on purpose:
#
#   NO-LINK PR: title names an OPEN gap, but `gaps-for-pr` returns NOTHING.
#               FK closer → must NOT ship. Title-regex relapse → WOULD ship.
#   LINK   PR: title names the gap AND `gaps-for-pr` returns it. Both ship.
#
# So restoring a title regex (reading the gh-stub title instead of the FK)
# flips the NO-LINK assertion red. gh's `pr view --json title` / merged-list
# titles are stubbed precisely so a relapse has a title to parse.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/stale-pr-reaper.sh"
TRIAGE="$REPO_ROOT/scripts/coord/chump-pr-triage.sh"
[[ -x "$REAPER" ]] || { echo "FAIL: reaper not found: $REAPER"; exit 1; }
[[ -f "$TRIAGE" ]] || { echo "FAIL: triage not found: $TRIAGE"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/shipped" "$TMP/.chump-locks" "$TMP/.chump" \
         "$TMP/scripts/lib" "$TMP/scripts/coord/lib"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"; touch "$AMBIENT"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS %s\n' "$*"; }
ko() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

# ── stub: chump ───────────────────────────────────────────────────────────────
# gaps-for-pr is the typed FK reverse lookup; it DIVERGES from the gh titles:
#   9911 (title INFRA-700) and 9921 (title INFRA-710) resolve to NOTHING.
#   9912 (title INFRA-701) and 9922 (title INFRA-711) resolve to the gap.
# `gap ship` records the (gap, pr) it was asked to close so assertions can see
# exactly what closed.
cat > "$TMP/bin/chump" <<STUB
#!/usr/bin/env bash
SHIPPED="$TMP/shipped"
args="\$*"
case "\$args" in
  *"gap gaps-for-pr 9912"*) echo "INFRA-701" ;;
  *"gap gaps-for-pr 9922"*) echo "INFRA-711" ;;
  *"gap gaps-for-pr "*)     : ;;                 # 9911 / 9921 → NO link (empty)
  *"gap show INFRA-700"*) echo "  status: open" ;;
  *"gap show INFRA-701"*) echo "  status: open" ;;
  *"gap show INFRA-710"*) echo "  status: open" ;;
  *"gap show INFRA-711"*) echo "  status: open" ;;
  *"gap ship "*)
    # Record "<gid> <pr-or-none>" for every ship the closer actually issues.
    gid="\$(printf '%s\n' "\$args" | sed -nE 's/.*gap ship ([A-Z0-9-]+).*/\1/p')"
    pr="\$(printf '%s\n' "\$args"  | sed -nE 's/.*--closed-pr ([0-9]+).*/\1/p')"
    echo "\${gid:-?} \${pr:-none}" >> "\$SHIPPED/ships.log"
    ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/chump"

# ── stub: gh ───────────────────────────────────────────────────────────────
# Merged list returns number<TAB>title (reaper reads only the number today; a
# title-regex relapse would read the title field). `pr view N --json title`
# gives a relapsing triage a title to parse.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*"--state merged"*)
    printf '%s\t%s\n' "9911" "INFRA-700: title names an OPEN gap, but NO gap_prs link"
    printf '%s\t%s\n' "9912" "INFRA-701: title names the gap AND it is linked"
    ;;
  *"pr view 9911"*) echo "INFRA-700: title names an OPEN gap, but NO gap_prs link" ;;
  *"pr view 9921"*) echo "INFRA-710: title names an OPEN gap, but NO gap_prs link" ;;
  *"pr view 9912"*) echo "INFRA-701: title names the gap AND it is linked" ;;
  *"pr view 9922"*) echo "INFRA-711: title names the gap AND it is linked" ;;
  *"pr list"*"--state open"*|*"pr list"*) echo "" ;;
  *"pr diff"*) echo "" ;;
  *) echo "" ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"

# ── stub: git (reaper needs fetch + rev-parse + rev-list) ────────────────────
cat > "$TMP/bin/git" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"rev-parse --show-toplevel"*) echo "$TMP" ;;
  *"fetch"*) exit 0 ;;
  *"rev-list --count"*) echo "0" ;;
  *"show "*":docs/gaps/"*|*"show "*":docs/gaps.yaml"*) exit 1 ;;
  *"log"*) echo "" ;;
  *) exit 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/git"

# ── stub: reaper-instrumentation.sh (patched source, as ghost-status test) ───
cat > "$TMP/scripts/lib/reaper-instrumentation.sh" <<STUB
#!/usr/bin/env bash
REAPER_LOCK_DIR="$TMP/.chump-locks"
REAPER_NAME="pr"; REAPER_REPO_ROOT="$TMP"
export REAPER_LOCK_DIR REAPER_NAME REAPER_REPO_ROOT
reaper_setup()               { :; }
reaper_check_disk_headroom() { :; }
reaper_rotate_log()          { :; }
reaper_finish()              { :; }
STUB
# chump-pr-triage sources scripts/coord/lib/github_cache.sh (best-effort); give
# it an empty stub so `source` succeeds in the sandbox repo root.
: > "$TMP/scripts/coord/lib/github_cache.sh"

shipped_has() { grep -qx "$1" "$TMP/shipped/ships.log" 2>/dev/null; }

# ── Part A: stale-pr-reaper ghost-status block ───────────────────────────────
echo "== stale-pr-reaper.sh: closes only from the gap_prs FK =="
PATCHED="$TMP/reaper-patched.sh"
perl -pe "s|^source\b.*reaper-instrumentation\.sh.*|source '$TMP/scripts/lib/reaper-instrumentation.sh'|" \
    "$REAPER" > "$PATCHED"
: > "$TMP/shipped/ships.log"
# CREDIBLE-1553: default run (no --close-merged-gaps) must not ship anything
PATH="$TMP/bin:$PATH" REAPER_LOCK_DIR="$TMP/.chump-locks" REAPER_REPO_ROOT="$TMP" \
    bash "$PATCHED" >/dev/null 2>&1 || true
if [[ -s "$TMP/shipped/ships.log" ]]; then
    ko "reaper shipped gaps by default without --close-merged-gaps"
else
    ok "reaper does NOT close merged gaps by default (requires --close-merged-gaps)"
fi
PATH="$TMP/bin:$PATH" REAPER_LOCK_DIR="$TMP/.chump-locks" REAPER_REPO_ROOT="$TMP" \
    bash "$PATCHED" --close-merged-gaps >/dev/null 2>&1 || true
if shipped_has "INFRA-701 9912"; then
    ok "reaper SHIPS INFRA-701 (PR #9912 is FK-linked)"
else
    ko "reaper did not ship the FK-linked INFRA-701 (log: $(cat "$TMP/shipped/ships.log" 2>/dev/null | tr '\n' ';'))"
fi
if shipped_has "INFRA-700 9911"; then
    ko "reaper SHIPPED INFRA-700 from PR #9911's TITLE with no gap_prs link — title regex relapse"
else
    ok "reaper does NOT ship INFRA-700 (title names it, but PR #9911 has no gap_prs link)"
fi

# ── Part B: chump-pr-triage --apply ship-gap ─────────────────────────────────
echo "== chump-pr-triage.sh --apply ship-gap: closes only from the gap_prs FK =="
: > "$TMP/shipped/ships.log"
# LINK PR #9922 → INFRA-711 (gaps-for-pr resolves it) → must ship.
PATH="$TMP/bin:$PATH" bash "$TRIAGE" --apply 9922 ship-gap >/dev/null 2>&1 || true
# NO-LINK PR #9921 → gaps-for-pr empty; title names INFRA-710 → must NOT ship.
PATH="$TMP/bin:$PATH" bash "$TRIAGE" --apply 9921 ship-gap >/dev/null 2>&1 || true
if shipped_has "INFRA-711 none" || shipped_has "INFRA-711 9922"; then
    ok "triage SHIPS INFRA-711 (PR #9922 is FK-linked via gaps-for-pr)"
else
    ko "triage did not ship the FK-linked INFRA-711 (log: $(cat "$TMP/shipped/ships.log" 2>/dev/null | tr '\n' ';'))"
fi
if grep -q '^INFRA-710 ' "$TMP/shipped/ships.log" 2>/dev/null; then
    ko "triage SHIPPED INFRA-710 from PR #9921's TITLE with no gap_prs link — title regex relapse"
else
    ok "triage does NOT ship INFRA-710 (title names it, but PR #9921 has no gap_prs link)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
