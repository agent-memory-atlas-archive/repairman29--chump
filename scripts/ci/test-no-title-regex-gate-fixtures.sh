#!/usr/bin/env bash
# test-no-title-regex-gate-fixtures.sh — CREDIBLE-1551 (Phase R R2, AC4 proof).
#
# The META-TEST for scripts/ci/test-no-title-regex-gap-closers.sh. It PROVES the
# TIER-2 proximity window is strong enough by driving the real gate (a copy with
# only its PROX_WINDOW literal sed-patched — same "patch a copy" idiom as
# test-ghost-status-reaper.sh) against a fixture tree of synthetic closers:
#
#   POSITIVE (the gate MUST flag — title-regex closers, no gap_prs FK):
#     m2-closer.sh   — main's original chump-pr-triage `--apply` closer shape,
#                      verbatim: `gh pr view --json title --jq .title` feeding a
#                      `chump gap ship` ~16 lines away. The initial 15-line
#                      window MISSED this (M2 survived the review).
#     mg2-closer.sh  — a gap-ID regex literal exactly 17 lines above a
#                      `chump gap ship` (MG2). A 15-line window MISSES it.
#   NEGATIVE (the gate MUST pass — route-correct, not title closers):
#     fk-ok-closer.sh  — parses a PR title for display but resolves the gap it
#                        closes through the gap_prs FK (`chump gap gaps-for-pr`).
#     display-only.sh  — parses a PR title for a dispatch table far (>window)
#                        from a lease-gap-ID ship; no title→close dataflow.
#
# The meta-test FAILS if the gate's production PROX_WINDOW is set to 0 or 15:
# it reads the window the gate ships with and asserts the positives are flagged
# AT THAT WINDOW (0/15 miss the 16/17-line closers), and separately pins that
# window 0 and window 15 under-detect while window 20 detects. So a regression
# that narrows the window back to 15 turns this gate RED.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
GATE="$REPO_ROOT/scripts/ci/test-no-title-regex-gap-closers.sh"
[[ -f "$GATE" ]] || { echo "FAIL: gate not found: $GATE"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS %s\n' "$*"; }
ko()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

# ── build the fixture tree ───────────────────────────────────────────────────
FIX="$TMP/fixtree"
mkdir -p "$FIX/scripts/ci" "$FIX/scripts/coord" "$FIX/scripts/dispatch" \
         "$FIX/scripts/ops" "$FIX/scripts/overnight"
# empty allowlist (true zero) — the structural FK exemption is what passes the
# negatives, not a path entry.
: > "$FIX/scripts/ci/no-title-regex-gap-closers-allowlist.txt"

# POSITIVE m2: main's chump-pr-triage closer shape with its REAL spacing — the
# gap-ID regex literal lives in a helper function FAR (>20 lines) from the ship
# (main: extract_gap_id:112, ship:179 → 67 apart), while the `gh pr view --json
# title --jq .title` extraction site that feeds the ship sits ~16 lines from it
# (main: 179 ship ↔ 195 title). So the ONLY in-window title→close signal is the
# title FETCH at distance 16 — which a 15-line window missed (M2 survived) and a
# 20-line window catches. Built programmatically so the two distances are exact.
{
  echo '#!/usr/bin/env bash'
  echo '# chump-pr-triage.sh (main shape) — derives the gap from the PR title.'
  echo 'set -euo pipefail'
  echo 'extract_gap_id() {'
  echo '    local title="$1"'
  echo "    echo \"\$title\" | grep -oE '[A-Z]+-[0-9]+' | head -1 || true   # regex literal — FAR from any ship"
  echo '}'
  # padding so the ship string below is >20 lines from the regex literal above.
  for i in $(seq 1 22); do echo "filler_helper_$i() { :; }   # main has remediation_cmd + fetch helpers here"; done
  echo 'remediation_cmd() {'
  echo '    case "$2" in'
  echo '        ship-gap) echo "chump gap ship $3" ;;   # SHIP string (S)'
  echo '    esac'
  echo '}'
  # exactly 15 filler lines between the ship (S) and the title FETCH (S+16).
  for i in $(seq 1 15); do echo "pad_between_$i=1"; done
  echo '    gap_id="$(gh pr view "$APPLY_PR" --json title --jq '"'"'.title'"'"' | { read -r t; extract_gap_id "$t"; })"  # title FETCH = S+16'
} > "$FIX/scripts/coord/m2-closer.sh"

# POSITIVE mg2: a gap-ID regex literal EXACTLY 17 lines above the ship.
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'gh pr list --state merged --json number,title --jq ".[] | \"\(.number)\t\(.title)\"" | while IFS=$'"'"'\t'"'"' read -r num title; do'
  echo '    gid="$(echo "$title" | grep -oE '"'"'[A-Z]+-[0-9]+'"'"' | head -1)"   # regex literal (R)'
  for i in $(seq 1 16); do echo "    echo \"filler line $i — not a close\""; done
  echo '    chump gap ship "$gid" --closed-pr "$num"                                 # ship = R+17'
  echo 'done'
} > "$FIX/scripts/coord/mg2-closer.sh"

# POSITIVE credible-1553 classes:
mkdir -p "$FIX/.github/workflows" "$FIX/scripts/lib"
cat > "$FIX/scripts/coord/sqlite-like-closer.sh" <<'SQLC'
#!/usr/bin/env bash
pr=$(sqlite3 .chump/github_cache.db "SELECT pr_number FROM pr_state WHERE state='MERGED' AND title LIKE '%$_gid%' LIMIT 1;")
chump gap ship "$_gid" --closed-pr "$pr"
SQLC

cat > "$FIX/scripts/ops/in-title-closer.sh" <<'INTC'
#!/usr/bin/env bash
pr=$(gh pr list --state merged --search "$gap in:title" --json number -q '.[0].number')
chump gap set "$gap" --status done
INTC

cat > "$FIX/scripts/ops/py-title-closer.py" <<'PYTC'
import subprocess, re
def f(pr):
    m = re.findall(r'[A-Z]+-[0-9]+', pr.get("title") or "")
    for gid in m:
        subprocess.run(["chump", "gap", "ship", gid, "--closed-pr", str(pr["number"])])
PYTC

cat > "$FIX/.github/workflows/wf-title-closer.yml" <<'WFTC'
name: test
jobs:
  flip:
    steps:
      - env:
          PR_TITLE: ${{ github.event.pull_request.title }}
        run: |
          if [[ "$PR_TITLE" =~ ^([A-Z]+-[0-9]+) ]]; then
            chump gap ship "${BASH_REMATCH[1]}" --closed-pr 123
          fi
WFTC

# NEGATIVE fk-ok: resolves the closed gap via the gap_prs FK reverse lookup.
cat > "$FIX/scripts/coord/fk-ok-closer.sh" <<'FK'
#!/usr/bin/env bash
set -euo pipefail
command gh pr list --state merged --json number,title --jq '.[].number' | while read -r num; do
    # Parse the title only for a human-readable log line (display, not close).
    title="$(gh pr view "$num" --json title --jq '.title')"
    echo "processing PR #$num ($title)"
    # The CLOSE resolves the gap from the typed gap_prs FK, never the title:
    gid="$(chump gap gaps-for-pr "$num" | head -1)"
    [[ -n "$gid" ]] && chump gap ship "$gid" --closed-pr "$num"
done
FK

# NEGATIVE display-only: title parse for a dispatch table far from a
# lease-gap-ID ship (no title→close dataflow within the window).
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'gh pr list --state open --json number,title --jq ".[] | \"\(.number)\t\(.title)\"" | while IFS=$'"'"'\t'"'"' read -r num title; do'
  echo '    printf "%s\t%s\n" "$num" "$title"   # advisory display table only'
  echo 'done'
  for i in $(seq 1 30); do echo "# gap between the title display and any close ($i)"; done
  echo 'LEASE_GID="$(jq -r .gap_id .chump-locks/claim-*.json 2>/dev/null | head -1)"'
  echo 'chump gap ship "$LEASE_GID" --closed-pr 999   # ships by LEASE gap-id, not a title'
} > "$FIX/scripts/coord/display-only.sh"

# ── run the gate copy at a chosen window, return its output ───────────────────
run_gate_at() {
  local win="$1"
  local gcopy="$FIX/scripts/ci/test-no-title-regex-gap-closers.sh"
  cp "$GATE" "$gcopy"
  if [[ "$win" != "asis" ]]; then
    # Patch ONLY the PROX_WINDOW literal (the "patch a copy" idiom). sed -E so
    # the literal-only form `PROX_WINDOW=NN` matches regardless of value.
    sed -E -i "s/^PROX_WINDOW=[0-9]+/PROX_WINDOW=${win}/" "$gcopy"
  fi
  bash "$gcopy" 2>&1 || true
}
flagged() { grep -q "VIOLATION: scripts/coord/$1" <<<"$2"; }

# Production window the gate ships with (what CI actually runs).
PROD_WIN="$(grep -oE '^PROX_WINDOW=[0-9]+' "$GATE" | head -1 | cut -d= -f2)"
echo "== gate ships with PROX_WINDOW=$PROD_WIN =="

# ── core: at the PRODUCTION window, positives flag, negatives pass ────────────
# (This is the assertion that turns the gate RED if someone sets the window to
#  0 or 15 — the 16/17-line positives would then go undetected here.)
OUT_PROD="$(run_gate_at asis)"
flagged m2-closer.sh  "$OUT_PROD" && ok "prod window flags m2-closer.sh (main's chump-pr-triage shape)" \
  || ko "prod window (PROX_WINDOW=$PROD_WIN) MISSED m2-closer.sh — window too narrow (must be >= 17)"
flagged mg2-closer.sh "$OUT_PROD" && ok "prod window flags mg2-closer.sh (regex 17 lines above ship)" \
  || ko "prod window (PROX_WINDOW=$PROD_WIN) MISSED mg2-closer.sh — window too narrow (must be >= 17)"
grep -q "VIOLATION: scripts/coord/sqlite-like-closer.sh" <<<"$OUT_PROD" && ok "prod window flags sqlite-like-closer.sh (title LIKE)" \
  || ko "prod window MISSED sqlite-like-closer.sh"
grep -q "VIOLATION: scripts/ops/in-title-closer.sh" <<<"$OUT_PROD" && ok "prod window flags in-title-closer.sh (in:title + gap set --status done)" \
  || ko "prod window MISSED in-title-closer.sh"
grep -q "VIOLATION: scripts/ops/py-title-closer.py" <<<"$OUT_PROD" && ok "prod window flags py-title-closer.py (pr.get('title'))" \
  || ko "prod window MISSED py-title-closer.py"
grep -q "VIOLATION: .github/workflows/wf-title-closer.yml" <<<"$OUT_PROD" && ok "prod window flags wf-title-closer.yml (pull_request.title in .github/workflows)" \
  || ko "prod window MISSED wf-title-closer.yml"
flagged fk-ok-closer.sh "$OUT_PROD" && ko "prod window WRONGLY flagged fk-ok-closer.sh (FK-resolved close)" \
  || ok "prod window passes fk-ok-closer.sh (close resolved via gap_prs FK)"
flagged display-only.sh "$OUT_PROD" && ko "prod window WRONGLY flagged display-only.sh (title far from close)" \
  || ok "prod window passes display-only.sh (title display far from a lease-gap-ID ship)"

# ── window-sensitivity proof: 0 and 15 under-detect; 20 detects ──────────────
OUT0="$(run_gate_at 0)"
if ! flagged m2-closer.sh "$OUT0" && ! flagged mg2-closer.sh "$OUT0"; then
  ok "window=0 MISSES both positives (confirms a 0 window is too small)"
else
  ko "window=0 flagged a positive (impossible — proximity broken)"
fi

OUT15="$(run_gate_at 15)"
if ! flagged m2-closer.sh "$OUT15" && ! flagged mg2-closer.sh "$OUT15"; then
  ok "window=15 MISSES both positives (this is exactly why 15 is insufficient)"
else
  ko "window=15 unexpectedly flagged a positive (fixture distances drifted < 16)"
fi

OUT20="$(run_gate_at 20)"
if flagged m2-closer.sh "$OUT20" && flagged mg2-closer.sh "$OUT20"; then
  ok "window=20 flags BOTH positives (16- and 17-line dataflows)"
else
  ko "window=20 did not flag both positives (M2/MG2 distances wrong)"
fi
# And 20 must still pass the negatives.
if ! flagged fk-ok-closer.sh "$OUT20" && ! flagged display-only.sh "$OUT20"; then
  ok "window=20 passes BOTH negatives (FK-resolved + display-only)"
else
  ko "window=20 wrongly flagged a negative"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
