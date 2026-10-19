#!/usr/bin/env bash
# scripts/ci/test-no-title-regex-gap-closers.sh
# CREDIBLE-1550 (Phase R R2, AC4): CI grep gate — no gap closer may derive the
# gap it closes from a PR TITLE or commit SUBJECT regex. The gap→PR link is the
# typed gap_prs FK (CREDIBLE-1520 AC1), and that is the ONLY proof a close may
# trust. A title match is not proof the PR implemented the gap: on 2026-10-18 it
# falsely closed the R3 umbrella CREDIBLE-1492 from a docs-only receipt PR and
# closed CREDIBLE-1520 whole from its AC1-only slice PR.
#
# Enforcement is two-tier:
#   TIER 1 (hard, no allowlist): the exact removed title-closer constructs —
#     `_GAP_TITLE_RE`, `merged_pr_gap_map`, and any invocation of the deleted
#     `close-gaps-from-commit-subjects.sh` — must never reappear.
#   TIER 2 (co-occurrence, allowlisted): a closer file that BOTH (a) extracts a
#     gap ID from a PR title / commit subject AND (b) closes a gap. Legitimate
#     co-occurrers that ship by lease/branch gap-ID (not by title) are listed in
#     scripts/ci/no-title-regex-gap-closers-allowlist.txt with a reason.
#
# Exit 0 = no new title/subject-regex closer. Exit 1 = a violation (printed).
#
# Usage:
#   bash scripts/ci/test-no-title-regex-gap-closers.sh            # full scan
#   bash scripts/ci/test-no-title-regex-gap-closers.sh --advisory # always exit 0

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALLOWLIST="$REPO_ROOT/scripts/ci/no-title-regex-gap-closers-allowlist.txt"
ADVISORY=0
[[ "${1:-}" == "--advisory" ]] && ADVISORY=1

SCAN_DIRS=(
  "$REPO_ROOT/scripts/coord"
  "$REPO_ROOT/scripts/dispatch"
  "$REPO_ROOT/scripts/ops"
  "$REPO_ROOT/scripts/overnight"
)

# Files that may legitimately co-occur title/subject parsing with a gap close
# (they ship by lease/branch gap-ID, not by PR title). One repo-relative path
# per non-comment line.
load_allowlist() {
  [[ -f "$ALLOWLIST" ]] || return 0
  grep -vE '^\s*(#|$)' "$ALLOWLIST" | awk '{print $1}'
}
ALLOWED=()
while IFS= read -r line; do [[ -n "$line" ]] && ALLOWED+=("$line"); done < <(load_allowlist)
is_allowed() {
  local rel="$1"
  for a in "${ALLOWED[@]:-}"; do [[ "$rel" == "$a" ]] && return 0; done
  return 1
}

# Strip comment lines so a doc-comment that merely NAMES the banned token (like
# this gate's own header, or the reconciler's explanatory comment) is not a hit.
# Shell: lines whose first non-space char is '#'. Python: likewise '#'.
noncomment() { grep -vE '^\s*#' "$1" 2>/dev/null || true; }

VIOLATIONS=0
report() { echo "[no-title-closer] VIOLATION: $*" >&2; VIOLATIONS=$((VIOLATIONS + 1)); }

for dir in "${SCAN_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r -d '' f; do
    rel="${f#"$REPO_ROOT"/}"
    case "$rel" in
      */test-*|*/lib/*|*-allowlist.txt) continue ;;
    esac
    [[ "$rel" == "scripts/ci/"* ]] && continue
    body="$(noncomment "$f")"

    # ── TIER 1: exact removed title-closer constructs (no allowlist escape) ──
    if printf '%s\n' "$body" | grep -qE '_GAP_TITLE_RE|merged_pr_gap_map'; then
      report "$rel references a removed title-regex closer symbol (_GAP_TITLE_RE / merged_pr_gap_map)"
      continue
    fi
    if printf '%s\n' "$body" | grep -qE 'close-gaps-from-commit-subjects(\.sh)?'; then
      report "$rel invokes the deleted subject-regex closer close-gaps-from-commit-subjects.sh"
      continue
    fi

    # ── TIER 2: gap-ID derived from a PR title / commit subject + a close ────
    # (a) title/subject source of a gap ID
    src=0
    if printf '%s\n' "$body" | grep -qE "(--format|--pretty)[= ]['\"]?[^'\"]*%s|format:%s"; then src=1; fi
    if printf '%s\n' "$body" | grep -qE "pr (list|view)[^|]*--json[^|]*title"; then src=1; fi
    [[ $src -eq 1 ]] || continue
    # (b) a gap-ID regex literal (what pulls the ID out of that title/subject)
    printf '%s\n' "$body" | grep -qE '\[A-Z\]\+-\[0-9\]\+|\[A-Z\]\[A-Z0-9\]\*-|\^\(\[A-Z\]' || continue
    # (c) a gap close action
    printf '%s\n' "$body" | grep -qE 'gap ship|gap["'\'' ]+,?["'\'' ]*ship|status: ?done' || continue

    if is_allowed "$rel"; then continue; fi
    report "$rel derives a gap ID from a PR title/commit subject AND closes a gap — route the close through the gap_prs FK (CREDIBLE-1550), or allowlist with a reason if it ships by lease/branch gap-ID"
  done < <(find "$dir" -type f \( -name '*.sh' -o -name '*.py' \) -print0)
done

if [[ $VIOLATIONS -gt 0 ]]; then
  echo "[no-title-closer] FAIL: $VIOLATIONS title/subject-regex gap closer(s) found" >&2
  [[ $ADVISORY -eq 1 ]] && { echo "[no-title-closer] advisory mode — exit 0"; exit 0; }
  exit 1
fi
echo "[no-title-closer] PASS: no title/subject-regex gap closers"
exit 0
