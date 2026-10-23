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

# TIER-2 proximity window: a title→gap-ID extraction this many non-comment
# lines (or fewer) from a gap close is treated as a title→close dataflow.
# Tight enough that display/respawn title parsing far from any close is exempt,
# but WIDE enough to catch the real closer shapes: main's original
# chump-pr-triage `--apply` block puts the `gh pr view --json title | extract_gap_id`
# source 16-17 lines from the `chump gap ship` it feeds, so a 15-line window (the
# CREDIBLE-1551 R2 initial value) silently MISSED it (and any regex 17+ lines
# above a ship). The meta-test scripts/ci/test-no-title-regex-gate-fixtures.sh
# PROVES this value: it drives the gate against verbatim-M2 and 17-line fixtures
# and FAILS if the window is set to 0 or 15. Raise only with a fixture that
# proves the new value is still tight enough.
PROX_WINDOW=20

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

    # ── TIER 2: title→gap-ID extraction in PROXIMITY to a gap close ─────────
    # A title-regex CLOSER sources a gap ID from a PR title / commit subject and
    # feeds it to a close. A file that merely parses a PR title for DISPLAY /
    # RESPAWN / dispatch FAR from any close (stale-pr-reaper's respawn+retire
    # loops, chump-pr-triage's advisory remediation table) is not a closer and
    # must not trip the gate. CREDIBLE-1551 converted both legacy closers' close
    # paths to the gap_prs FK (`chump gap gaps-for-pr`) — that reverse lookup is
    # what proves a close is FK-resolved, not title-derived.
    #
    # Detection has three parts, in order:
    #   (a) src  — does the file source a gap ID from a PR title/commit subject
    #              at all? If not, it cannot be a title closer → skip.
    #   (FK)     — STRUCTURAL ALLOWLIST (CREDIBLE-1551, replaces the path
    #              allowlist so it can stay at TRUE ZERO): a file that resolves
    #              the gap it closes through the typed gap_prs FK
    #              (`chump gap gaps-for-pr`) is route-correct by construction —
    #              its close trusts the FK, and the title parse it still does is
    #              for display/respawn. Exempt it. (The ship-gate FK refusal in
    #              `chump gap ship` is the real backstop; this gate is
    #              defense-in-depth, so a file that both calls gaps-for-pr AND
    #              smuggles a title close is a tolerated blind spot here, caught
    #              at ship.)
    #   (b/c)    — PROXIMITY: a title→gap-ID source (b) within $PROX_WINDOW
    #              non-comment lines of a close action (c). b is the gap-ID
    #              regex LITERAL (the direct `grep -oE '[A-Z]+-[0-9]+'` case,
    #              incl. MG2: a regex 17 lines above a ship) OR the title-FETCH
    #              line itself (`--json title`, `--jq '.title'`, `--format/
    #              --pretty %s`) — main's original chump-pr-triage closer put
    #              `gh pr view --json title --jq .title` ~16 lines from the
    #              `chump gap ship` string it feeds (M2), which the initial
    #              15-line window silently missed.
    #              (b deliberately does NOT match a bare `extract_gap_id`/
    #              `_extract_gap_ids` token: that also appears in docstrings and
    #              function definitions — e.g. github-webhook-receiver.py — and
    #              naming it there is not a title→close dataflow. The title-fetch
    #              line + regex literal are enough to anchor M2 and MG2.)
    #
    # (a) title/subject source of a gap ID (whole-file — cheap)
    src=0
    if printf '%s\n' "$body" | grep -qE "(--format|--pretty)[= ]['\"]?[^'\"]*%s|format:%s"; then src=1; fi
    if printf '%s\n' "$body" | grep -qE "pr (list|view)[^|]*--json[^|]*title"; then src=1; fi
    [[ $src -eq 1 ]] || continue

    # (FK) structural allowlist: close routes through the gap_prs reverse lookup.
    if printf '%s\n' "$body" | grep -qE 'gap[[:space:]"'\'',]+gaps-for-pr|gaps-for-pr'; then
      continue
    fi

    # Comment-blanked view that PRESERVES line numbers (so proximity is measured
    # on real code, and a doc-comment naming a token is never a hit — same intent
    # as noncomment() above).
    blanked="$(sed -E 's/^[[:space:]]*#.*$//' "$f" 2>/dev/null || true)"
    # (b) line numbers of title→gap-ID sources: regex LITERALS that pull an ID
    #     out of a title, PLUS the title-FETCH line that hands a title to one.
    b_lines="$(printf '%s\n' "$blanked" \
      | grep -nE '\[A-Z\]\+-\[0-9\]\+|\[A-Z\]\[A-Z0-9\]\*-|\^\(\[A-Z\]|(--json[^|]*title)|(--jq[^|]*\.title)|((--format|--pretty)[= ][^|]*%s)' \
      | cut -d: -f1 || true)"
    [[ -n "$b_lines" ]] || continue
    # (c) line numbers of gap close actions
    c_lines="$(printf '%s\n' "$blanked" | grep -nE 'gap ship|gap["'\'' ]+,?["'\'' ]*ship|status: ?done' | cut -d: -f1 || true)"
    [[ -n "$c_lines" ]] || continue
    # Proximity: any (title-source line, close line) pair within $PROX_WINDOW lines?
    near=0
    for bl in $b_lines; do
      for cl in $c_lines; do
        d=$(( bl > cl ? bl - cl : cl - bl ))
        if [[ $d -le $PROX_WINDOW ]]; then near=1; break 2; fi
      done
    done
    [[ $near -eq 1 ]] || continue

    if is_allowed "$rel"; then continue; fi
    report "$rel extracts a gap ID from a PR title/commit subject AND closes a gap within $PROX_WINDOW lines without resolving it via the gap_prs FK — route the close through 'chump gap gaps-for-pr' (CREDIBLE-1550/1551: the typed link is the only close proof, never a title), or allowlist with a reason if it ships by lease/branch gap-ID"
  done < <(find "$dir" -type f \( -name '*.sh' -o -name '*.py' \) -print0)
done

if [[ $VIOLATIONS -gt 0 ]]; then
  echo "[no-title-closer] FAIL: $VIOLATIONS title/subject-regex gap closer(s) found" >&2
  [[ $ADVISORY -eq 1 ]] && { echo "[no-title-closer] advisory mode — exit 0"; exit 0; }
  exit 1
fi
echo "[no-title-closer] PASS: no title/subject-regex gap closers"
exit 0
