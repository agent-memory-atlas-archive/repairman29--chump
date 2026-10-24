#!/usr/bin/env bash
# scripts/ci/test-no-title-regex-gap-closers.sh
# CREDIBLE-1550 (Phase R R2, AC4) + CREDIBLE-1553 (AC1): CI grep gate — no gap
# closer may derive the gap it closes from a PR TITLE or commit SUBJECT regex,
# SQLite `title LIKE`, GitHub `in:title` / `gh pr list --search <GAP>`, or
# Python `pr.get("title")`. The gap→PR link is the typed gap_prs FK
# (CREDIBLE-1520 AC1), and that is the ONLY proof a close may trust.
#
# Enforcement is two-tier:
#   TIER 1 (hard, no allowlist): the exact removed title-closer constructs —
#     `_GAP_TITLE_RE`, `merged_pr_gap_map`, and any invocation of the deleted
#     `close-gaps-from-commit-subjects.sh` — must never reappear.
#   TIER 2 (co-occurrence, allowlisted): a closer file across .github/workflows,
#     scripts/ (including lib/), src/, or crates/ that BOTH (a) extracts a gap
#     ID from a PR title / commit subject / title search AND (b) closes a gap
#     within $PROX_WINDOW lines without routing through the gap_prs FK.
#     Every entry in scripts/ci/no-title-regex-gap-closers-allowlist.txt must
#     carry a `# reason` on the same line (target: 0 entries).
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

PROX_WINDOW=20

SCAN_DIRS=(
  "$REPO_ROOT/.github/workflows"
  "$REPO_ROOT/scripts"
  "$REPO_ROOT/src"
  "$REPO_ROOT/crates"
)

VIOLATIONS=0
report() { echo "[no-title-closer] VIOLATION: $*" >&2; VIOLATIONS=$((VIOLATIONS + 1)); }

# Validate allowlist format (every non-comment entry must carry an inline `# reason`)
ALLOWED=()
if [[ -f "$ALLOWLIST" ]]; then
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    [[ "$raw_line" =~ ^[[:space:]]*(#|$) ]] && continue
    entry="$(awk '{print $1}' <<<"$raw_line")"
    if ! grep -qE '#[[:space:]]*[^[:space:]]+' <<<"$raw_line"; then
      report "allowlist entry '$entry' in scripts/ci/no-title-regex-gap-closers-allowlist.txt is missing a written '# reason' on the same line"
    fi
    [[ -n "$entry" ]] && ALLOWED+=("$entry")
  done < "$ALLOWLIST"
fi

is_allowed() {
  local rel="$1"
  for a in "${ALLOWED[@]:-}"; do [[ "$rel" == "$a" ]] && return 0; done
  return 1
}

# Strip comment lines so a doc-comment that merely NAMES the banned token is not a hit.
noncomment() { grep -vE '^\s*(#|//)' "$1" 2>/dev/null || true; }

for dir in "${SCAN_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r -d '' f; do
    rel="${f#"$REPO_ROOT"/}"
    case "$rel" in
      */test-*|*-allowlist.txt|scripts/ci/*) continue ;;
    esac
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
    # (a) title/subject/search source of a gap ID (whole-file — cheap):
    #     Either a direct title-by-gap search (`title LIKE`, `in:title`,
    #     `gh pr list ... --state merged ... --search`), OR a title/subject
    #     fetch (`--format %s`, `--json title`, `pr.get("title")`,
    #     `pull_request.title`) paired with a gap-ID regex in the file.
    src=0
    has_gap_re=0
    if printf '%s\n' "$body" | grep -qE '\[A-Z\]\+-\[0-9\]\+|\[A-Z\]\[A-Z0-9\]\*-|\^\(\[A-Z\]|-\(\[0-9\]\+\)'; then
      has_gap_re=1
    fi
    if [[ $has_gap_re -eq 1 ]]; then
      if printf '%s\n' "$body" | grep -qE "(--format|--pretty)[= ]['\"]?[^'\"]*%s|format:%s"; then src=1; fi
      if printf '%s\n' "$body" | grep -qE "pr (list|view)[^|]*--json[^|]*title"; then src=1; fi
      if printf '%s\n' "$body" | grep -qE "pr\.get\(['\"]title['\"]\)|pull_request\.title"; then src=1; fi
    fi
    if printf '%s\n' "$body" | grep -qE "title[[:space:]]+LIKE|in:title|pr[[:space:]]+list[^|]*(--state[[:space:]]+merged[^|]*--search|--search[^|]*--state[[:space:]]+merged)"; then
      src=1
    fi
    [[ $src -eq 1 ]] || continue

    # (FK) structural allowlist: close routes through the gap_prs reverse lookup.
    if printf '%s\n' "$body" | grep -qE 'gap[[:space:]"'\'',]+gaps-for-pr|gaps-for-pr|FROM[[:space:]]+gap_prs[[:space:]]+WHERE'; then
      continue
    fi

    # Comment-blanked view that PRESERVES line numbers
    blanked="$(sed -E 's/^[[:space:]]*(#|\/\/).*$//' "$f" 2>/dev/null || true)"
    # (b) line numbers of title→gap-ID sources: regex LITERALS, title-FETCH,
    #     SQLite `title LIKE`, GitHub `in:title` / `pr list --search`, or Python `pr.get("title")`
    b_lines="$(printf '%s\n' "$blanked" \
      | grep -nE '\[A-Z\]\+-\[0-9\]\+|\[A-Z\]\[A-Z0-9\]\*-|\^\(\[A-Z\]|-\(\[0-9\]\+\)|(--json[^|]*title)|(--jq[^|]*\.title)|((--format|--pretty)[= ][^|]*%s)|(title[[:space:]]+LIKE)|(in:title)|(pr[[:space:]]+list[^|]*--search)|(pr\.get\(['\''"]title['\''"]\))|(pull_request\.title)' \
      | cut -d: -f1 || true)"
    [[ -n "$b_lines" ]] || continue
    # (c) line numbers of gap close actions (excluding grep/read checks)
    c_lines="$(printf '%s\n' "$blanked" \
      | grep -nE 'gap ship|gap["'\'' ]+,?["'\'' ]*ship|gap[[:space:]]+set[^|]*--status[= ]*done|sed[^|]*status: ?done' \
      | cut -d: -f1 || true)"
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
    report "$rel extracts a gap ID from a PR title/commit subject/search AND closes a gap within $PROX_WINDOW lines without resolving it via the gap_prs FK — route the close through 'chump gap gaps-for-pr' (CREDIBLE-1550/1551/1553: the typed link is the only close proof, never a title), or allowlist with a reason if it ships by lease/branch gap-ID"
  done < <(find "$dir" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.yml' -o -name '*.yaml' -o -name '*.rs' \) -print0)
done

if [[ $VIOLATIONS -gt 0 ]]; then
  echo "[no-title-closer] FAIL: $VIOLATIONS title/subject-regex gap closer(s) found" >&2
  [[ $ADVISORY -eq 1 ]] && { echo "[no-title-closer] advisory mode — exit 0"; exit 0; }
  exit 1
fi
echo "[no-title-closer] PASS: no title/subject-regex gap closers"
exit 0
