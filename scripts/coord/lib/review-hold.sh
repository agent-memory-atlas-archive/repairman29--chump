#!/usr/bin/env bash
# scripts/coord/lib/review-hold.sh — CREDIBLE-1542 (PHASE-R R3): the fail-CLOSED
# independent-review predicate the review organ consults before it arms a PR.
#
# This is a SIBLING of arm-policy.sh (RESILIENT-1613), not a replacement:
#   * arm_policy_allows (arm-policy.sh) honours a DELIBERATE hold (a no-auto-merge
#     label / `Auto-merge: hold` marker) and FAILS OPEN — a transient API error
#     must not freeze the whole fleet over a hold that may not exist.
#   * review_hold_allows (here) answers a different, stricter question: "has an
#     INDEPENDENT reviewer written VERDICT: APPROVE for THIS exact head sha?"
#     and FAILS CLOSED — a brand-new PR with no review yet is HELD, and an
#     unreadable API is HELD, because we cannot prove the diff was reviewed
#     (repair item 2: fail closed on NO APPROVE for the current head, not only
#     when the review-held label is present).
#
# THE CONTRACT
#   review_hold_allows <pr-number> <head-sha> [owner/repo] [armer-name] [trusted-author]
#     returns 0 (arming allowed) ONLY when ALL hold conditions are clear:
#       * the PR carries neither `review-held` nor `review-needs-mutants`;
#       * a review comment AUTHORED BY the trusted-author login exists that names
#         head-sha (`head: <sha>`) and whose LAST verdict block is VERDICT: APPROVE
#         with no outstanding blockers.
#     returns 1 (HELD) otherwise, including when the PR/labels/comments cannot
#     be read. Emits kind=pr_arm_skipped_review_hold on a hold.
#
#     trusted-author (CREDIBLE-1542 review REQUIRED): the login whose verdict
#     comments are trusted — the organ's OWN authenticated account. A forged
#     `VERDICT: APPROVE / head: <sha>` comment from any other account (anyone can
#     comment on a public PR) must NEVER satisfy the gate, so a comment whose
#     `author.login` is not the trusted-author is ignored and HELD with reason
#     `verdict-author-untrusted`. An empty trusted-author trusts nobody → HELD
#     (fail closed: we cannot prove the diff was reviewed by us).
#
#   review_parse_verdict  (reads a comment body on stdin)
#     prints APPROVE or CHANGES_REQUIRED and returns 0 when at least one
#     `VERDICT:` line is present; returns 1 when none. Rules (repair item 6):
#       * take the LAST verdict block;
#       * if two blocks DISAGREE, treat the whole comment as CHANGES_REQUIRED;
#       * downgrade an APPROVE whose `blockers:` line lists anything but none.
#
# scanner-anchor: "kind":"pr_arm_skipped_review_hold"

# Guard against double-sourcing.
# shellcheck disable=SC2317
if [[ -n "${_CHUMP_REVIEW_HOLD_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_CHUMP_REVIEW_HOLD_SOURCED=1

# shellcheck disable=SC2034  # public constants for callers/tests
REVIEW_HOLD_LABEL="review-held"
# shellcheck disable=SC2034
REVIEW_NEEDS_MUTANTS_LABEL="review-needs-mutants"
REVIEW_HOLD_LABELS="review-held review-needs-mutants"

_review_hold_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_review_hold_ambient_path() {
    if [[ -n "${CHUMP_AMBIENT_LOG:-}" ]]; then
        printf '%s' "$CHUMP_AMBIENT_LOG"; return
    fi
    local common root
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common" && -d "$common" ]]; then
        root="$(cd "$common/.." && pwd)"
    else
        root="$(cd "${_review_hold_lib_dir}/../../.." && pwd)"
    fi
    printf '%s/.chump-locks/ambient.jsonl' "$root"
}

_review_hold_append() { # <json-line> — observability sink; path is not an env safety input
    local amb
    amb="$(_review_hold_ambient_path)"
    mkdir -p "$(dirname "$amb")" 2>/dev/null || true
    printf '%s\n' "$1" >> "$amb" 2>/dev/null \
        || echo "[review-hold] WARN: ambient write failed ($amb)" >&2
}

_review_hold_json_str() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

_review_hold_gh() {
    if declare -F chump_gh >/dev/null 2>&1; then chump_gh "$@"; else gh "$@"; fi
}

_review_hold_emit() { # <pr> <armer> <reason>
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _review_hold_append "$(printf '{"ts":"%s","kind":"pr_arm_skipped_review_hold","pr":%s,"armer":"%s","reason":"%s"}' \
        "$ts" "$1" "$(_review_hold_json_str "$2")" "$(_review_hold_json_str "$3")")"
}

# review_parse_verdict — stdin: one comment body. stdout: APPROVE|CHANGES_REQUIRED.
review_parse_verdict() {
    python3 -c '
import re, sys
body = sys.stdin.read()
verd = re.compile(r"^[ \t]*VERDICT:[ \t]*(APPROVE|CHANGES[ \t]+REQUIRED)[ \t]*$", re.I | re.M)
hits = [("APPROVE" if m.group(1).upper().startswith("APPROVE") else "CHANGES_REQUIRED")
        for m in verd.finditer(body)]
if not hits:
    sys.exit(1)
# Two blocks that disagree -> CHANGES_REQUIRED (repair item 6).
if len(set(hits)) > 1:
    print("CHANGES_REQUIRED"); sys.exit(0)
result = hits[-1]  # the LAST verdict block wins

# An empty-blockers line reads as "no blockers". The prompt template invites a
# handful of placeholder shapes (<none>, <none, or a one-line list>, (none),
# none., n/a, -) and a model often echoes one verbatim; treat every such shape
# as none so an APPROVE is not downgraded by its own template boilerplate
# (CREDIBLE-1594: #5615 bb2d12c96 ended "blockers: <none>" yet was downgraded).
def _blockers_none(raw):
    v = raw.strip().lower()
    # peel any surrounding quotes/backticks the reviewer may have wrapped it in
    while len(v) >= 2 and v[0] == v[-1] and v[0] in "\x27\x22\x60":
        v = v[1:-1].strip()
    v = v.strip(".").strip()
    return v in ("", "none", "<none>", "<none, or a one-line list>",
                 "(none)", "n/a", "na", "-")

if result == "APPROVE":
    # Downgrade an APPROVE whose blockers line lists a real blocker.
    for m in re.finditer(r"^[ \t]*blockers?:[ \t]*(.*)$", body, re.I | re.M):
        if not _blockers_none(m.group(1)):
            print("CHANGES_REQUIRED"); sys.exit(0)
print(result)
'
}

# review_hold_allows <pr> <head-sha> [owner/repo] [armer]
review_hold_allows() {
    local pr="${1:-}" head="${2:-}" repo="${3:-}" armer="${4:-review-organ}" trusted="${5:-}"
    if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
        echo "[review-hold] WARN: review_hold_allows needs a PR number ('$pr') — HELD" >&2
        return 1
    fi
    if [[ ! "$head" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
        echo "[review-hold] WARN: review_hold_allows needs a head sha ('$head') — HELD" >&2
        _review_hold_emit "$pr" "$armer" "no-head-sha"
        return 1
    fi

    local -a repo_arg=()
    [[ -n "$repo" ]] && repo_arg=(--repo "$repo")
    local payload
    payload="$(CHUMP_GH_CALL_CRITICALITY=background _review_hold_gh pr view "$pr" \
        ${repo_arg[@]+"${repo_arg[@]}"} --json labels,comments 2>/dev/null || true)"
    if [[ -z "$payload" ]]; then
        echo "[review-hold] PR #${pr}: labels/comments unreadable — HELD (fail closed)" >&2
        _review_hold_emit "$pr" "$armer" "unreadable-fail-closed"
        return 1
    fi

    local reason
    reason="$(HEAD_SHA="$head" HOLD_LABELS="$REVIEW_HOLD_LABELS" TRUSTED_AUTHOR="$trusted" python3 -c '
import json, os, re, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("unparseable"); sys.exit(0)
holds = {h.lower() for h in os.environ.get("HOLD_LABELS", "").split()}
for l in d.get("labels") or []:
    name = l.get("name", "") if isinstance(l, dict) else str(l)
    if name.lower() in holds:
        print("label:" + name); sys.exit(0)
head = os.environ.get("HEAD_SHA", "")
trusted = (os.environ.get("TRUSTED_AUTHOR", "") or "").strip().lower()
verd = re.compile(r"^[ \t]*VERDICT:[ \t]*(APPROVE|CHANGES[ \t]+REQUIRED)[ \t]*$", re.I | re.M)
headmark = re.compile(r"^[ \t]*head:[ \t]*([0-9a-fA-F]{7,40})", re.I | re.M)
blocker = re.compile(r"^[ \t]*blockers?:[ \t]*(.*)$", re.I | re.M)
# Comments that name THIS head, newest last — and ONLY those authored by the
# trusted login (the organ itself). A forged VERDICT comment from any other
# account must never satisfy the gate (CREDIBLE-1542 review REQUIRED).
cands = []
saw_untrusted = False
head = head.lower()
for c in d.get("comments") or []:
    b = c.get("body", "") if isinstance(c, dict) else str(c)
    hm = headmark.search(b or "")
    if not hm:
        continue
    marked = hm.group(1).lower()
    # A comment names THIS head when its `head:` marker (>=7 hex) is a prefix of
    # the full head sha (or equal). A marker for a different head never matches.
    if not head.startswith(marked):
        continue
    author = ""
    if isinstance(c, dict):
        a = c.get("author") or {}
        if isinstance(a, dict):
            author = (a.get("login") or "")
    if not trusted or author.strip().lower() != trusted:
        # A head-marked VERDICT from a non-organ author is a forged/untrusted
        # approval — ignore it and remember we saw one (for the hold reason).
        if verd.search(b or ""):
            saw_untrusted = True
        continue
    cands.append((c.get("createdAt", "") if isinstance(c, dict) else "", b))
if not cands:
    print("verdict-author-untrusted" if saw_untrusted else "no-verdict-for-head"); sys.exit(0)
cands.sort(key=lambda t: t[0])
body = cands[-1][1]
hits = [("APPROVE" if m.group(1).upper().startswith("APPROVE") else "CHANGES_REQUIRED")
        for m in verd.finditer(body)]
if not hits:
    print("no-verdict-for-head"); sys.exit(0)
if len(set(hits)) > 1:
    print("changes-required"); sys.exit(0)
if hits[-1] != "APPROVE":
    print("changes-required"); sys.exit(0)
def _blockers_none(raw):
    # Mirror review_parse_verdict: every empty-blockers placeholder shape the
    # prompt template could invite reads as none (CREDIBLE-1594).
    v = raw.strip().lower()
    while len(v) >= 2 and v[0] == v[-1] and v[0] in "\x27\x22\x60":
        v = v[1:-1].strip()
    v = v.strip(".").strip()
    return v in ("", "none", "<none>", "<none, or a one-line list>",
                 "(none)", "n/a", "na", "-")
for m in blocker.finditer(body):
    if not _blockers_none(m.group(1)):
        print("changes-required-blockers"); sys.exit(0)
print("")  # clear: a current-head APPROVE with no blockers
' "$payload")"

    if [[ -n "$reason" ]]; then
        _review_hold_emit "$pr" "$armer" "$reason"
        echo "[review-hold] PR #${pr}: HELD (${reason}) — ${armer} will not arm it" >&2
        return 1
    fi
    return 0
}
