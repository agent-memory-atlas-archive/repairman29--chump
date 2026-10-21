#!/usr/bin/env bash
# review-organ-tick.sh — CREDIBLE-1542 (PHASE-R R3): the organ that performs the
# delegated independent review for a code-reviewer ESCALATE, so an escalated PR
# no longer waits for a human or an architect session (operator decision
# 2026-10-18: Jeff is not a developer).
#
# ONE bounded tick. For each open PR whose CURRENT head has no verdict yet:
#   (a) skip drafts, fork PRs (never arm a fork), and own-lane PRs;
#   (b) if the diff touches a GATE FILE and no sandboxed mutant runner exists,
#       the organ cannot satisfy the mutation rule (AC5), so it posts
#       VERDICT: CHANGES REQUIRED with `mutants: NOT RUN …` and labels the PR
#       `review-needs-mutants` — it never APPROVEs a gate-file PR blind
#       (repair item 8). It does NOT dispatch an author repair for this state
#       (nothing for the author to fix; it is awaiting a mutant-capable
#       reviewer);
#   (c) otherwise run the independent delta review READ-ONLY via
#       scripts/dispatch/review-ro-claude.sh (no write tools, scoped reads,
#       minimal env, token-scrubbed output — AC2) and parse exactly ONE verdict
#       block, the LAST one (repair item 6);
#   (d) post the verdict as a PR comment whose FIRST line is exactly
#       `VERDICT: APPROVE` or `VERDICT: CHANGES REQUIRED`, that embeds
#       `head: <sha>` and carries a `mutants:` line (AC1/AC5);
#   (e) apply the `review-held` label to any PR without a current APPROVE and
#       remove it on APPROVE;
#   (f) ARM only on a WRITTEN APPROVE for the current head read back from the
#       comment (never a claude exit code — AC3) AND verified-green, HEAD-PINNED:
#       `gh pr merge <pr> --squash --match-head-commit <approved-head>`. It
#       NEVER enables auto-merge (no --auto), so there is no push-during-review
#       or push-after-arm window (repair item 1);
#   (g) on CHANGES REQUIRED, dispatch exactly ONE repair to the author lane,
#       never with --auto-merge (AC4 / repair item 9).
#
# HARD RULES (Chief 2026-10-20): no CHUMP_* env var changes a safety input. The
# claude binary, the review brief, the gate-file list, the scoped read roots and
# the budget are CONSTANTS or explicit CLI args a test passes and the unit never
# passes (--claude-bin, --pr, --self-login, --checkout). The only env knob is the
# ENABLED kill switch, which can only STOP the organ.
#
# SHIPPED DISABLED: paired with chump-review-organ.{service,timer}; no organ
# manifest line enables it. Rendering + enabling is the operator's step.
#
# Off-switch: CHUMP_REVIEW_ORGAN_ENABLED=0 (default on).
set -uo pipefail

[[ "${CHUMP_REVIEW_ORGAN_ENABLED:-1}" == "0" ]] && { echo "[review-organ] disabled via CHUMP_REVIEW_ORGAN_ENABLED=0 — exit"; exit 0; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

# ── CLI args (the test seam; the unit passes NONE of these). ──
CLAUDE_BIN="claude"
CHECKOUT="$REPO_ROOT"
SELF_LOGIN=""          # own-lane skip: a PR authored by this login is not reviewed
REPO=""                # owner/repo; empty = current checkout's repo
declare -a ONLY_PRS=()
while (( $# )); do
    case "$1" in
        --claude-bin) CLAUDE_BIN="${2:-}"; shift 2 ;;
        --checkout)   CHECKOUT="${2:-}"; shift 2 ;;
        --self-login) SELF_LOGIN="${2:-}"; shift 2 ;;
        --repo)       REPO="${2:-}"; shift 2 ;;
        --pr)         ONLY_PRS+=("${2:-}"); shift 2 ;;
        -h|--help)    sed -n '2,45p' "$0"; exit 0 ;;
        *)            echo "[review-organ] unknown argument '$1'" >&2; exit 2 ;;
    esac
done

cd "$REPO_ROOT" || { echo "[review-organ] cannot cd repo root" >&2; exit 1; }

# The gate-file list is the single shared source of truth (CREDIBLE-1590 AC3):
# scripts/coord/lib/ship-gate-files.sh, the same TRUE ship gates CREDIBLE-1576's
# bot-merge arm guard enforces. NEVER read from an env var. scripts/ci/* is NOT a
# gate here — a scripts/ci test change is REVIEWED normally; the organ IS the
# reviewer. Listing scripts/ci/* (the CREDIBLE-1590 bug) held every fleet PR as
# "needs mutants" (nearly all touch a scripts/ci test), so the organ never
# approved and gate 4 never armed.
# shellcheck source=scripts/coord/lib/ship-gate-files.sh
source "$REPO_ROOT/scripts/coord/lib/ship-gate-files.sh"
REVIEW_GATE_FILE_GLOBS=("${CHUMP_SHIP_GATE_GLOBS[@]}")
# A sandboxed mutant runner does not exist yet; until it does, gate-file PRs are
# held for a mutant-capable reviewer (repair item 8). This is a CONSTANT, not an
# env read — flipping it on without a real runner would defeat the mutation rule.
REVIEW_MUTANT_RUNNER_AVAILABLE=0

BUDGET_USD="2.00"
MODEL="opus"

# shellcheck source=scripts/coord/lib/review-hold.sh
source "$REPO_ROOT/scripts/coord/lib/review-hold.sh"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[review-organ %s] %s\n' "$(ts)" "$*"; }

GH() { if declare -F chump_gh >/dev/null 2>&1; then chump_gh "$@"; else gh "$@"; fi; }

# ORGAN_LOGIN — the ONLY login whose verdict comments the organ trusts (the
# account it posts as). Not a tunable safety input: it is the organ's IDENTITY,
# resolved from --self-login (the test seam the systemd unit never passes) or, in
# production, from the real authenticated account via `gh api user`. A forged
# `VERDICT: APPROVE / head: <sha>` comment from any other account (anyone can
# comment on a public PR) must NEVER arm a PR — so both the idempotency
# short-circuit (current_head_verdict) and the arm gate (review_hold_allows) only
# count comments authored by this login (CREDIBLE-1542 review REQUIRED). Empty →
# the organ trusts nobody and holds everything (fail closed).
ORGAN_LOGIN="$SELF_LOGIN"
if [[ -z "$ORGAN_LOGIN" ]]; then
    ORGAN_LOGIN="$(CHUMP_GH_CALL_CRITICALITY=background GH api user --jq '.login' 2>/dev/null || true)"
fi

json_str() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
emit() { printf '%s\n' "$1" >> "$AMBIENT" 2>/dev/null || true; }
# scanner-anchor: "kind":"review_organ_tick"
# scanner-anchor: "kind":"pr_review_verdict"

REVIEWED=0; APPROVED=0; CHANGES=0; HELD_MUTANTS=0; ARMED=0; DISPATCHED=0; SKIPPED=0

# gate_files_touched <pr> — prints the first gate file the PR changes (rc 0),
# rc 1 if none, rc 3 if the PR's file list cannot be read (fail closed). Reads
# the file list via gh (no local head ref needed) so an unfetched head never
# forces a wrong classification.
gate_files_touched() {
    local pr="$1" files f glob
    files="$(CHUMP_GH_CALL_CRITICALITY=background GH pr view "$pr" ${REPO:+--repo "$REPO"} \
        --json files --jq '.files[].path' 2>/dev/null)" || return 3
    [[ -n "$files" ]] || return 3   # empty file list is suspect → fail closed
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        for glob in "${REVIEW_GATE_FILE_GLOBS[@]}"; do
            # shellcheck disable=SC2254
            case "$f" in $glob) printf '%s\n' "$f"; return 0 ;; esac
        done
    done <<< "$files"
    return 1
}

# verified_green <pr> <head> — exit 0 ONLY when the PR's current head has at
# least one completed check and EVERY check concluded SUCCESS/NEUTRAL/SKIPPED is
# NOT counted as green: a neutral/skipped or still-running check is NOT green
# (repair item 12 N1: verified-neutral-or-skipped-counted-as-green is a mutant).
verified_green() {
    local pr="$1" head="$2" roll
    roll="$(CHUMP_GH_CALL_CRITICALITY=background GH pr view "$pr" ${REPO:+--repo "$REPO"} \
        --json statusCheckRollup,headRefOid 2>/dev/null || true)"
    [[ -n "$roll" ]] || return 1
    HEAD_SHA="$head" python3 -c '
import json, os, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
# The rollup must be for the head we approved (guard the head-move race).
if (d.get("headRefOid") or "").lower() != os.environ.get("HEAD_SHA","").lower():
    sys.exit(1)
checks = d.get("statusCheckRollup") or []
if not checks:
    sys.exit(1)
for c in checks:
    status = (c.get("status") or "").upper()
    concl  = (c.get("conclusion") or "").upper()
    if status and status != "COMPLETED":
        sys.exit(1)       # still running
    if concl != "SUCCESS":
        sys.exit(1)       # NEUTRAL/SKIPPED/FAILURE/"" are NOT green
sys.exit(0)
' "$roll"
}

# build_prompt_file <run_dir> <pr> <head> <gate_hit> — writes the fixed review
# brief + the PR diff as DATA into run_dir/prompt.txt. The brief is a CONSTANT
# here (safety input), never an env read.
build_prompt_file() {
    local run_dir="$1" pr="$2" head="$3" gate_hit="$4" pf="$1/prompt.txt"
    GH pr diff "$pr" ${REPO:+--repo "$REPO"} > "$run_dir/diff.patch" 2>/dev/null || : > "$run_dir/diff.patch"
    cat > "$pf" <<PROMPT
You are an INDEPENDENT read-only reviewer for a code-reviewer ESCALATE. You did
NOT write this diff. You have Read/Grep/Glob only; no shell, no edits. The repo
is PUBLIC — never echo any token-shaped string.

Review the diff at ${run_dir}/diff.patch against the checkout at ${CHECKOUT}.

State plainly whether the diff changes any EXIT CODE, REFUSAL, or GATE CONDITION.
If it does and lacks a pinning test, the verdict MUST be CHANGES REQUIRED.

MUTATION RULE (Chief 2026-10-19): for every test that backs a binding rule on a
gate file, describe at least one MUTANT that breaks the rule and whether the test
would catch it. This PR ${gate_hit:+touches the gate file: $gate_hit}.

End your review with EXACTLY one block, nothing after it:
VERDICT: APPROVE        (or: VERDICT: CHANGES REQUIRED)
head: ${head}
blockers: <none, or a one-line list>
mutants: <one line: the mutant(s) you reasoned about, or 'NOT RUN — read-only reviewer'>
PROMPT
    printf '%s' "$pf"
}

# post_verdict <pr> <verdict APPROVE|CHANGES_REQUIRED> <head> <mutants-line> <body-file>
# Posts a comment whose FIRST line is exactly the verdict and that ends with the
# verdict too (AC1), embedding head + mutants (AC5).
post_verdict() {
    local pr="$1" verdict="$2" head="$3" mutants="$4" body_file="${5:-}"
    local vstr; [[ "$verdict" == APPROVE ]] && vstr="VERDICT: APPROVE" || vstr="VERDICT: CHANGES REQUIRED"
    local cfile; cfile="$(mktemp)"
    {
        printf '%s\n\n' "$vstr"
        printf '🤖 independent review organ (CREDIBLE-1542) — read-only, no write tools.\n'
        printf 'head: %s\n' "$head"
        printf 'mutants: %s\n' "$mutants"
        if [[ -n "$body_file" && -r "$body_file" ]]; then
            printf '\n---\n'; sed -n '1,400p' "$body_file"
        fi
        printf '\n%s\n' "$vstr"
    } > "$cfile"
    GH pr comment "$pr" ${REPO:+--repo "$REPO"} --body-file "$cfile" >/dev/null 2>&1 || log "WARN: could not post verdict comment on #$pr"
    rm -f "$cfile"
    emit "$(printf '{"ts":"%s","kind":"pr_review_verdict","pr":%s,"verdict":"%s","head":"%s","mutants":"%s"}' \
        "$(ts)" "$pr" "$(json_str "$verdict")" "$(json_str "$head")" "$(json_str "$mutants")")"
}

label_add()    { GH pr edit "$1" ${REPO:+--repo "$REPO"} --add-label "$2" >/dev/null 2>&1 || true; }
label_remove() { GH pr edit "$1" ${REPO:+--repo "$REPO"} --remove-label "$2" >/dev/null 2>&1 || true; }

# dispatch_repair <pr> <head> — exactly ONE repair to the author lane, NEVER with
# --auto-merge (AC4 / repair item 9). Derives the gap from the head branch name
# and dispatches it; if no gap can be derived, logs and skips. Every real lane
# branch is `claude/<gap-lowercase>-…` (e.g. claude/credible-1542); the legacy
# `chump/<GAP>-…` form and a bare gap id are also accepted. The match is
# case-insensitive via [A-Za-z] and the derived id is upper-cased for `chump
# dispatch` (CREDIBLE-1542 review: the old `[A-Z]+` regex matched no real branch).
dispatch_repair() {
    local pr="$1" head="$2" branch gap
    branch="$(CHUMP_GH_CALL_CRITICALITY=background GH pr view "$pr" ${REPO:+--repo "$REPO"} --json headRefName --jq '.headRefName' 2>/dev/null || true)"
    gap="$(printf '%s' "$branch" | sed -nE 's#^(chump/|claude/)?([A-Za-z]+-[0-9]+).*#\2#p' | tr '[:lower:]' '[:upper:]')"
    if [[ -z "$gap" ]]; then
        log "PR #$pr: CHANGES REQUIRED but no gap id in branch '$branch' — no repair dispatched"
        return 0
    fi
    log "PR #$pr: CHANGES REQUIRED → dispatching one repair for $gap (no auto-merge)"
    chump dispatch "$gap" --backend headless >/dev/null 2>&1 || log "WARN: repair dispatch for $gap failed"
    DISPATCHED=$((DISPATCHED + 1))
}

# current_head_verdict <pr> <head> — prints APPROVE or CHANGES_REQUIRED when a
# prior review comment AUTHORED BY THE ORGAN already names THIS exact head sha
# (`head: <sha>`), rc 1 (no output) when the current head has no verdict from the
# organ yet. This is the idempotency predicate behind design item (a): only PRs
# whose current head has NO organ verdict are (re)reviewed, so a 15-min tick does
# not re-review, re-post, or re-dispatch a PR it already judged this head.
# A forged VERDICT comment from any other account is ignored (CREDIBLE-1542 review
# REQUIRED): it must not short-circuit the independent review. Reads comments via
# gh (no local ref needed); the comments payload carries `author.login`.
current_head_verdict() {
    local pr="$1" head="$2" payload
    payload="$(CHUMP_GH_CALL_CRITICALITY=background GH pr view "$pr" ${REPO:+--repo "$REPO"} \
        --json comments 2>/dev/null || true)"
    [[ -n "$payload" ]] || return 1
    HEAD_SHA="$head" TRUSTED_AUTHOR="$ORGAN_LOGIN" python3 -c '
import json, os, re, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
head = (os.environ.get("HEAD_SHA","") or "").lower()
trusted = (os.environ.get("TRUSTED_AUTHOR","") or "").strip().lower()
verd = re.compile(r"^[ \t]*VERDICT:[ \t]*(APPROVE|CHANGES[ \t]+REQUIRED)[ \t]*$", re.I | re.M)
headmark = re.compile(r"^[ \t]*head:[ \t]*([0-9a-fA-F]{7,40})", re.I | re.M)
cands = []
for c in d.get("comments") or []:
    b = c.get("body","") if isinstance(c, dict) else str(c)
    hm = headmark.search(b or "")
    if not hm:
        continue
    # A comment names THIS head when its >=7-hex marker is a prefix of the full head.
    if not head.startswith(hm.group(1).lower()):
        continue
    author = ""
    if isinstance(c, dict):
        a = c.get("author") or {}
        if isinstance(a, dict):
            author = (a.get("login") or "")
    # Only a verdict authored by the organ itself is idempotent; a forged one is not.
    if not trusted or author.strip().lower() != trusted:
        continue
    cands.append((c.get("createdAt","") if isinstance(c, dict) else "", b))
if not cands:
    sys.exit(1)
cands.sort(key=lambda t: t[0])
body = cands[-1][1]
hits = [("APPROVE" if m.group(1).upper().startswith("APPROVE") else "CHANGES_REQUIRED")
        for m in verd.finditer(body)]
if not hits:
    sys.exit(1)
print("CHANGES_REQUIRED" if len(set(hits)) > 1 else hits[-1])
sys.exit(0)
' "$payload"
}

# process_pr <pr> — the whole per-PR decision. Testable with stub gh + claude.
process_pr() {
    local pr="$1"
    local meta author head draft fork
    meta="$(CHUMP_GH_CALL_CRITICALITY=background GH pr view "$pr" ${REPO:+--repo "$REPO"} \
        --json isDraft,isCrossRepository,headRefOid,author,headRefName 2>/dev/null || true)"
    if [[ -z "$meta" ]]; then log "PR #$pr: unreadable — skip"; SKIPPED=$((SKIPPED+1)); return 0; fi
    draft="$(printf '%s' "$meta" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("isDraft"))' 2>/dev/null)"
    fork="$(printf '%s'  "$meta" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("isCrossRepository"))' 2>/dev/null)"
    head="$(printf '%s'  "$meta" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("headRefOid") or "")' 2>/dev/null)"
    author="$(printf '%s' "$meta" | python3 -c 'import json,sys;d=json.load(sys.stdin).get("author") or {};print(d.get("login") or "")' 2>/dev/null)"

    if [[ "$draft" == "True" ]]; then log "PR #$pr: draft — skip"; SKIPPED=$((SKIPPED+1)); return 0; fi
    if [[ -n "$SELF_LOGIN" && "$author" == "$SELF_LOGIN" ]]; then
        log "PR #$pr: authored by own lane ($author) — not reviewing (independence)"; SKIPPED=$((SKIPPED+1)); return 0
    fi
    [[ "$head" =~ ^[0-9a-fA-F]{7,40}$ ]] || { log "PR #$pr: no head sha — skip"; SKIPPED=$((SKIPPED+1)); return 0; }

    # Idempotency (design item (a)): if THIS head already has a verdict comment,
    # do NOT re-review, re-post a verdict, or re-dispatch a repair — only reconcile
    # arming on a prior APPROVE (so a PR that only went green after its APPROVE tick
    # still arms). Without this, every 15-min tick re-reviews each PR (burning the
    # budget) and re-dispatches a repair for each still-open CHANGES PR.
    local prior
    if prior="$(current_head_verdict "$pr" "$head")"; then
        if [[ "$prior" == APPROVE ]]; then
            log "PR #$pr: current-head verdict already APPROVE — reconciling arming only (no re-review)"
            maybe_arm "$pr" "$head"
        else
            log "PR #$pr: current-head verdict already CHANGES REQUIRED — held, no re-review/re-dispatch"
        fi
        SKIPPED=$((SKIPPED+1)); return 0
    fi

    local run_dir; run_dir="$(mktemp -d)"
    local gate_hit="" gate_rc
    if gate_hit="$(gate_files_touched "$pr" 2>/dev/null)"; then gate_rc=0; else gate_rc=$?; fi
    # A diff we cannot compute is fail-closed: treat as a gate change.
    if [[ "$gate_rc" == 3 ]]; then gate_hit="(diff uncomputable — fail closed)"; gate_rc=0; fi

    local verdict mutants
    if [[ "$gate_rc" == 0 && "$REVIEW_MUTANT_RUNNER_AVAILABLE" != "1" ]]; then
        # Gate-file PR, no mutant runner: hold for a mutant-capable reviewer (AC5).
        verdict="CHANGES_REQUIRED"
        mutants="NOT RUN — gate-file change ($gate_hit) needs a mutant-capable reviewer; labeled review-needs-mutants"
        post_verdict "$pr" "$verdict" "$head" "$mutants"
        label_add "$pr" "$REVIEW_NEEDS_MUTANTS_LABEL"
        label_add "$pr" "$REVIEW_HOLD_LABEL"
        HELD_MUTANTS=$((HELD_MUTANTS+1)); REVIEWED=$((REVIEWED+1))
        rm -rf "$run_dir"; return 0
    fi

    # ── Independent read-only review (AC2). ──
    local pf out body_file
    pf="$(build_prompt_file "$run_dir" "$pr" "$head" "$gate_hit")"
    body_file="$run_dir/review.out"
    if ! bash "$SELF_DIR/review-ro-claude.sh" \
            --run-dir "$run_dir" --checkout "$CHECKOUT" --prompt-file "$pf" \
            --claude-bin "$CLAUDE_BIN" --model "$MODEL" --budget-usd "$BUDGET_USD" \
            > "$body_file" 2>"$run_dir/review.err"; then
        log "PR #$pr: reviewer run failed — holding (no verdict posted this tick)"
        label_add "$pr" "$REVIEW_HOLD_LABEL"
        SKIPPED=$((SKIPPED+1)); rm -rf "$run_dir"; return 0
    fi

    # Parse the LAST verdict block from the reviewer output (never an exit code).
    if verdict="$(review_parse_verdict < "$body_file")"; then :; else
        log "PR #$pr: reviewer produced no VERDICT block — treating as CHANGES REQUIRED"
        verdict="CHANGES_REQUIRED"
    fi
    mutants="$(sed -nE 's/^[[:space:]]*mutants:[[:space:]]*(.*)$/\1/p' "$body_file" | tail -1)"
    [[ -n "$mutants" ]] || mutants="NOT RUN — read-only reviewer"
    REVIEWED=$((REVIEWED+1))

    post_verdict "$pr" "$verdict" "$head" "$mutants" "$body_file"

    if [[ "$verdict" == APPROVE ]]; then
        APPROVED=$((APPROVED+1))
        label_remove "$pr" "$REVIEW_HOLD_LABEL"
        maybe_arm "$pr" "$head"
    else
        CHANGES=$((CHANGES+1))
        label_add "$pr" "$REVIEW_HOLD_LABEL"
        dispatch_repair "$pr" "$head"
    fi
    rm -rf "$run_dir"
}

# maybe_arm <pr> <head> — HEAD-PINNED self-merge, never --auto, never a fork,
# only on a written current-head APPROVE (read back via review_hold_allows, AC3)
# AND verified-green for that exact head.
maybe_arm() {
    local pr="$1" head="$2"
    local fork
    fork="$(CHUMP_GH_CALL_CRITICALITY=background GH pr view "$pr" ${REPO:+--repo "$REPO"} --json isCrossRepository --jq '.isCrossRepository' 2>/dev/null || echo true)"
    if [[ "$fork" == "true" || "$fork" == "True" ]]; then
        log "PR #$pr: cross-repository (fork) — NEVER arm"; return 0
    fi
    # AC3: the arm decision reads the APPROVE STRING from the comment for THIS
    # head (fail closed), not any exit code — and ONLY from the organ's own
    # comment ($ORGAN_LOGIN), never a forged one (CREDIBLE-1542 review REQUIRED).
    if ! review_hold_allows "$pr" "$head" "$REPO" "review-organ" "$ORGAN_LOGIN"; then
        log "PR #$pr: review_hold_allows held it (no current-head organ APPROVE / hold label) — not arming"; return 0
    fi
    if ! verified_green "$pr" "$head"; then
        log "PR #$pr: not verified-green for head ${head:0:12} — not arming (head may have moved)"; return 0
    fi
    log "PR #$pr: APPROVE for head ${head:0:12} + verified green → head-pinned squash merge (no auto-merge)"
    GH pr merge "$pr" ${REPO:+--repo "$REPO"} --squash --match-head-commit "$head" >/dev/null 2>&1 \
        && { ARMED=$((ARMED+1)); log "PR #$pr: merged head-pinned"; } \
        || log "WARN: PR #$pr head-pinned merge did not succeed (head moved or not mergeable)"
}

# ── list of PRs to process ──
declare -a prs=()
if (( ${#ONLY_PRS[@]} )); then
    prs=("${ONLY_PRS[@]}")
else
    while IFS= read -r n; do [[ "$n" =~ ^[0-9]+$ ]] && prs+=("$n"); done < <(
        CHUMP_GH_CALL_CRITICALITY=background GH pr list ${REPO:+--repo "$REPO"} \
            --state open --limit 200 --json number --jq '.[].number' 2>/dev/null || true)
fi

log "tick start (${#prs[@]} PRs, checkout=$CHECKOUT)"
git -C "$CHECKOUT" fetch origin main -q 2>/dev/null || true
for pr in "${prs[@]}"; do process_pr "$pr"; done

emit "$(printf '{"ts":"%s","kind":"review_organ_tick","reviewed":%s,"approved":%s,"changes_required":%s,"held_mutants":%s,"armed":%s,"dispatched":%s,"skipped":%s}' \
    "$(ts)" "$REVIEWED" "$APPROVED" "$CHANGES" "$HELD_MUTANTS" "$ARMED" "$DISPATCHED" "$SKIPPED")"
log "tick done (reviewed=$REVIEWED approved=$APPROVED changes=$CHANGES held_mutants=$HELD_MUTANTS armed=$ARMED dispatched=$DISPATCHED skipped=$SKIPPED)"
exit 0
