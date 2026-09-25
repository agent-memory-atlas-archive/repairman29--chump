#!/usr/bin/env bash
#
# code-reviewer-agent.sh — automated code review for src/* PRs (INFRA-AGENT-CODEREVIEW MVP)
#
# Usage:
#   scripts/coord/code-reviewer-agent.sh <PR_NUMBER> [--gap GAP-ID] [--dry-run] [--post]
#
# Default behaviour: prints the review verdict to stdout. Pass --post to actually
# call gh pr review / gh pr comment. --dry-run skips all gh writes AND skips the
# Anthropic API call (uses a stub response) — for offline smoke testing.
#
# Exit codes:
#   0  APPROVE  (auto-approval criteria met)
#   1  CONCERN  (concerns raised; merge should be blocked)
#   2  ESCALATE (escalation required — human eyes needed)
#   3  SKIP     (docs-only PR; no review needed)
#   4  ERROR    (could not fetch diff, missing API key, etc.)
#
# See docs/process/CODEREVIEW_POLICY.md for the auto-approve / concern / escalate matrix.

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
PR=""
GAP_ID=""
DRY_RUN=0
POST=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gap)     GAP_ID="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --post)    POST=1; shift ;;
        --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
        *)         PR="$1"; shift ;;
    esac
done

if [[ -z "$PR" ]]; then
    echo "usage: $0 <PR_NUMBER> [--gap GAP-ID] [--dry-run] [--post]" >&2
    exit 4
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
green() { printf '\033[0;32m%s\033[0m\n' "$*" >&2; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*" >&2; }
info()  { printf '  %s\n' "$*" >&2; }

# ── 1. Fetch changed file list — skip docs-only PRs ──────────────────────────
info "Fetching changed file list for PR #$PR …"
CHANGED_FILES=$(gh pr diff "$PR" --name-only 2>/dev/null || true)
if [[ -z "$CHANGED_FILES" ]]; then
    red "Could not fetch file list for PR #$PR (does it exist?)."
    exit 4
fi

# Docs-only filter: every line matches docs/, *.md, or .yaml in docs/.
DOCS_ONLY=1
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ ! "$f" =~ ^docs/ ]] && [[ ! "$f" =~ \.md$ ]] && [[ ! "$f" =~ ^README ]]; then
        DOCS_ONLY=0
        break
    fi
done <<< "$CHANGED_FILES"

if [[ $DOCS_ONLY -eq 1 ]]; then
    yellow "PR #$PR is docs-only — skipping code review."
    echo "SKIP: docs-only PR"
    exit 3
fi

# ── 2. Check for sensitive paths — escalate immediately ──────────────────────
ESCALATE_REASON=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
        scripts/git-hooks/*|scripts/coord/bot-merge.sh|scripts/coord/code-reviewer-agent.sh|.claude/*|*CHUMP_TOOLS_ASK*)
            ESCALATE_REASON="touches sensitive infra path: $f"
            break ;;
    esac
done <<< "$CHANGED_FILES"

if [[ -n "$ESCALATE_REASON" ]]; then
    yellow "ESCALATE: $ESCALATE_REASON"
    echo "ESCALATE: $ESCALATE_REASON"
    if [[ $POST -eq 1 ]]; then
        gh pr comment "$PR" --body "🤖 **code-reviewer-agent**: ESCALATE — $ESCALATE_REASON. Human review required (per docs/process/CODEREVIEW_POLICY.md)." >&2 || true
    fi
    exit 2
fi

# ── 3. Fetch diff + LOC count ────────────────────────────────────────────────
DIFF=$(gh pr diff "$PR" 2>/dev/null || true)
if [[ -z "$DIFF" ]]; then
    red "Empty diff for PR #$PR."
    exit 4
fi
LOC=$(echo "$DIFF" | grep -cE '^[+-][^+-]' || true)
info "Diff size: $LOC LOC changed."

# ── 4. Pull gap acceptance criteria (if --gap given) ─────────────────────────
GAP_CRITERIA=""
REPO_ROOT="$(git rev-parse --show-toplevel)"
if [[ -n "$GAP_ID" ]]; then
    if [[ -f "$REPO_ROOT/docs/gaps.yaml" ]]; then
        # NB: regex is /^- id:/ (no leading spaces) — top-level YAML entries
        # in docs/gaps.yaml start at column 0. With a leading-space regex,
        # awk never matched the next gap and processed the entire 11k-line
        # file; `head -80` then closed the pipe early and awk SIGPIPE'd
        # (exit 141) under `set -euo pipefail`, breaking auto-merge on
        # every src/* PR. (INFRA-072, 2026-04-25.)
        GAP_CRITERIA=$(awk -v id="$GAP_ID" '
            $0 ~ "id: " id { found=1; print; next }
            found && /^- id:/ { exit }
            found { print }
        ' "$REPO_ROOT/docs/gaps.yaml" | head -80)
    fi
fi

# ── 4b. Workspace dependency pre-check ───────────────────────────────────────
# Extract new dependency names added to any Cargo.toml in the diff, then
# cross-reference against the workspace Cargo.toml. Only genuinely new
# dependencies (not already present in the workspace) should be flagged.
# This prevents false-positive CONCERN verdicts for deps like `serde` or
# `rusqlite` that are added to a crate-level Cargo.toml but already exist
# in the workspace root Cargo.toml.
NEW_DEPS_IN_DIFF=()
GENUINELY_NEW_DEPS=()
WORKSPACE_KNOWN_DEPS=()

if [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    # Parse added Cargo.toml lines from the diff (lines starting with + inside a
    # Cargo.toml file context). Match dep name at start of line: ^+<name> = ...
    # Also handles: ^+<name> = { ... }  and  ^+<name>.workspace = true
    while IFS= read -r line; do
        # Strip leading + and whitespace
        dep_line="${line#+}"
        dep_line="${dep_line# }"
        # Extract the dependency name: everything before the first = or .
        dep_name=$(echo "$dep_line" | sed -E 's/^([a-zA-Z0-9_-]+)[ ]*[.=].*/\1/')
        [[ -z "$dep_name" ]] && continue
        # Skip TOML section headers like [dependencies], [dev-dependencies], etc.
        [[ "$dep_name" == "["* ]] && continue
        NEW_DEPS_IN_DIFF+=("$dep_name")
    done < <(echo "$DIFF" | grep -E '^\+[a-zA-Z0-9_-]+[ ]*[.=]' | grep -v '^+++')

    # For each new dep name found in the diff, check the workspace Cargo.toml.
    # Guard the iteration: under bash 3.2 (default macOS) + `set -u`, expanding
    # an empty array via "${arr[@]}" errors with "unbound variable", which
    # caused PR #465 (REMOVAL-003) to fail review with no actual concerns.
    if (( ${#NEW_DEPS_IN_DIFF[@]} > 0 )); then
        for dep in "${NEW_DEPS_IN_DIFF[@]}"; do
            if grep -qE "^${dep}[ ]*[.=]" "$REPO_ROOT/Cargo.toml" 2>/dev/null; then
                WORKSPACE_KNOWN_DEPS+=("$dep")
            else
                GENUINELY_NEW_DEPS+=("$dep")
            fi
        done
    fi
fi

# Build a human-readable note for the LLM prompt
DEPS_NOTE=""
if [[ ${#NEW_DEPS_IN_DIFF[@]} -gt 0 ]]; then
    if [[ ${#WORKSPACE_KNOWN_DEPS[@]} -gt 0 ]]; then
        DEPS_NOTE+="Dependencies in diff already present in workspace Cargo.toml (do NOT flag these): ${WORKSPACE_KNOWN_DEPS[*]}"$'\n'
    fi
    if [[ ${#GENUINELY_NEW_DEPS[@]} -gt 0 ]]; then
        DEPS_NOTE+="Genuinely new dependencies NOT in workspace Cargo.toml (flag these as CONCERN): ${GENUINELY_NEW_DEPS[*]}"$'\n'
    fi
    if [[ ${#GENUINELY_NEW_DEPS[@]} -eq 0 && ${#NEW_DEPS_IN_DIFF[@]} -gt 0 ]]; then
        DEPS_NOTE+="All new Cargo.toml dependency entries in this diff already exist in the workspace Cargo.toml — no new external dependencies introduced."$'\n'
    fi
fi

# ── 5. Build review prompt ───────────────────────────────────────────────────
# Cap diff at ~80KB to keep prompt under model context limits.
DIFF_TRIMMED=$(echo "$DIFF" | head -c 80000)

PROMPT=$(cat <<EOF
You are reviewing this Chump PR. Reply on TWO lines:

Line 1 — the verdict, EXACTLY one of:
APPROVE: <one-sentence reason>
CONCERN: <comma-separated list of concerns, EACH one citing the specific file:line it applies to, e.g. "src/foo.rs:42 unwrap() on a Result from an untrusted source">
ESCALATE: <reason this needs human review>

Every CONCERN you raise MUST point at a specific file:line in the diff above. Do
NOT reuse a boilerplate concern (e.g. "new unwrap()/expect() in production",
"new external dependencies added") unless you can point at the exact line that
justifies it. A concern with no file:line citation will be treated as
ungrounded and will NOT block the merge on its own — it only wastes the
reviewer's credibility. Cite evidence, don't recite a checklist.

Line 2 — the SPIRIT lens, EXACTLY one of:
SPIRIT: GENUINE - <why the change genuinely does what the gap needs>
SPIRIT: PARTIAL - <what real behaviour is still missing>
SPIRIT: STUB - <what is faked: TODO/unimplemented!()/hardcoded-return/empty-body/assert-nothing test/shim that makes the AC only LOOK met>

Line 3 — the CORRECTNESS lens, EXACTLY one of:
CORRECTNESS: SOUND - <why the logic is actually right>
CORRECTNESS: UNSURE - <what you could not verify>
CORRECTNESS: FALSE-GREEN - <the change compiles / passes a shallow test but is logically WRONG: off-by-one, inverted condition, wrong variable, unhandled case the test doesn't hit, a test tautology that would pass even if the code were broken>

Line 4 — the HARMONY lens, EXACTLY one of:
HARMONY: FITS - <why it fits existing patterns and touches nothing it shouldn't>
HARMONY: HACKY - <a workaround/band-aid that fits but adds debt (informational, not blocking)>
HARMONY: REGRESSION-RISK - <a concrete existing behaviour this plausibly breaks: a caller not updated, a contract changed, a removed guard>

Auto-approve criteria (ALL must hold):
  - Diff is under 200 LOC
  - No new unwrap()/expect() in production code paths (test code is fine)
  - No genuinely new external dependencies added (workspace-inherited deps are fine)
  - Diff matches gap acceptance criteria
  - No obvious bugs, security issues, or panics

Raise CONCERN if any of the above fail or if you spot bugs/issues worth a fix-up.
ESCALATE if changes touch security boundaries, change behaviour in non-obvious ways,
or you cannot confidently judge the change.

SPIRIT lens (CREDIBLE-191) — letter-correct is not enough. Judge whether the diff
GENUINELY does what the gap needs, not merely something that compiles and passes a
shallow test. Answer STUB when the change FAKES satisfaction: an unimplemented!()/todo!(),
a hardcoded or placeholder return that dodges the real logic, an empty function body, a
test that asserts nothing, or a shim that makes the AC only LOOK met without the behaviour.
A STUB verdict downgrades a would-be APPROVE to a blocking CONCERN even when every letter
criterion above holds — this is the guard against the stub-false-green class (EFFECTIVE-351).

CORRECTNESS lens (CREDIBLE-191) — separate from STUB. A change can be a genuine attempt
(not a stub) and still be WRONG. Answer FALSE-GREEN when the diff compiles / passes its
test but the logic is actually broken — an inverted condition, off-by-one, wrong variable,
a case the test never exercises, or a tautological test that would pass even against broken
code. FALSE-GREEN downgrades a would-be APPROVE to a blocking CONCERN (the broken-but-green
half of EFFECTIVE-351). SOUND/UNSURE never block.

HARMONY lens (CREDIBLE-191) — does the change fit without collateral damage. Answer
REGRESSION-RISK when it plausibly breaks concrete existing behaviour (a caller left
unupdated, a changed contract, a removed guard); that downgrades a would-be APPROVE to a
blocking CONCERN. HACKY (fits but adds debt) and FITS are informational only.

IMPORTANT — dependency evaluation: The pre-checker has already analysed Cargo.toml
changes in this diff. Use the workspace dependency notes below (if present) as the
authoritative source for whether a dependency is new. Do NOT flag a dep as new if it
appears in the "already present in workspace" list.

Gap ID: ${GAP_ID:-<none specified>}
Diff LOC: $LOC
Changed files:
$CHANGED_FILES

Workspace dependency analysis:
${DEPS_NOTE:-No Cargo.toml dependency changes detected.}

Gap acceptance criteria:
$GAP_CRITERIA

Diff:
\`\`\`diff
$DIFF_TRIMMED
\`\`\`

Your review (line 1 = APPROVE/CONCERN/ESCALATE, line 2 = SPIRIT, line 3 = CORRECTNESS, line 4 = HARMONY):
EOF
)

# ── 5b. Tier 1: cascade pre-check (INFRA-264, migrated to shared gateway INFRA-3466) ──
# For trivially small / clean PRs, ask a cheap model class for a verdict before
# paying for the Anthropic Tier-2 call. Short-circuit ONLY on confident APPROVE
# for small diffs — any CONCERN, ESCALATE, parse failure, or larger diff falls
# through to the Anthropic Tier-2 call below.
#
# This is a cost optimization, not a quality gate: Anthropic Tier-2 still
# runs on every PR that's not obviously trivial. The Tier-1 model never
# blocks a merge; it only short-circuits the APPROVE path.
#
# INFRA-3466: routed through `chump llm-complete` (the shared ProviderCascade
# gateway, same as Tier-2 per INFRA-3462) instead of hand-walking
# CHUMP_PROVIDER_1..10 and hand-rolling a `curl` + raw API key call. This kills
# the slot-duplication between Tier-1 and Tier-2 auth paths — one gateway, one
# auth ladder (incl. OAuth, 429 backoff, slot fallback) for both tiers.
#
# Tunables:
#   CHUMP_TWO_TIER_REVIEW=0        disable Tier 1 entirely (always use Anthropic)
#   CHUMP_TWO_TIER_LOC_LIMIT=N     max LOC for Tier-1 short-circuit (default 50)
#   CHUMP_TWO_TIER_MODEL_CLASS=x   cascade model class for Tier-1 (default: haiku)
TIER1_RESPONSE=""
TIER1_VERDICT=""
# shellcheck disable=SC2034  # TIER1_RAN reserved for future telemetry callers
TIER1_RAN=0
TIER1_LOC_LIMIT="${CHUMP_TWO_TIER_LOC_LIMIT:-50}"
TIER1_MODEL_CLASS="${CHUMP_TWO_TIER_MODEL_CLASS:-haiku}"
if [[ $DRY_RUN -eq 0 ]] \
   && [[ "${CHUMP_TWO_TIER_REVIEW:-1}" != "0" ]] \
   && (( LOC <= TIER1_LOC_LIMIT )); then

    CHUMP_BIN="${CHUMP_LLM_BIN:-chump}"
    info "Tier 1: cascade pre-check via ${CHUMP_BIN} llm-complete --model $TIER1_MODEL_CLASS (LOC=$LOC ≤ $TIER1_LOC_LIMIT) …"
    if TIER1_RESPONSE=$(printf '%s' "$PROMPT" | "$CHUMP_BIN" llm-complete --model "$TIER1_MODEL_CLASS" --max-tokens 256 2>/dev/null) \
        && [[ -n "${TIER1_RESPONSE//[[:space:]]/}" ]]; then
        # shellcheck disable=SC2034  # TIER1_RAN reserved for future telemetry callers
        TIER1_RAN=1
        # Extract first APPROVE/CONCERN/ESCALATE line
        _t1_verdict_line=$(echo "$TIER1_RESPONSE" | grep -E '^(APPROVE|CONCERN|ESCALATE):' | head -1)
        if [[ -n "$_t1_verdict_line" ]]; then
            TIER1_VERDICT=$(echo "$_t1_verdict_line" | cut -d: -f1)
            info "Tier 1 verdict: $TIER1_VERDICT"
        else
            info "Tier 1 verdict: <unparseable> (will fall through to Tier 2)"
        fi
    else
        info "Tier 1: llm-complete produced no response — falling through to Tier 2"
    fi
fi

# Decide whether to short-circuit Tier 2.
SKIP_TIER2=0
if [[ "$TIER1_VERDICT" == "APPROVE" ]]; then
    info "Tier 1 short-circuit: APPROVE on small diff (LOC=$LOC) — skipping Anthropic Tier 2"
    RESPONSE="$TIER1_RESPONSE"
    SKIP_TIER2=1
fi

# ── 6. Call Anthropic API (or stub for --dry-run) ────────────────────────────
if [[ $SKIP_TIER2 -eq 1 ]]; then
    info "(Tier 2 Anthropic call skipped — Tier 1 cascade short-circuit on APPROVE)"
elif [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] skipping API call — using stub response."
    RESPONSE="APPROVE: dry-run stub response (LOC=$LOC, files=$(echo "$CHANGED_FILES" | wc -l | tr -d ' '))"
else
    # Source .env for ANTHROPIC_API_KEY if not already set. Check the worktree
    # root first, then the common-dir parent (main repo) since .env typically
    # lives in the main checkout, not in linked worktrees.
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        for _root in "$(git rev-parse --show-toplevel)" "$(git rev-parse --git-common-dir | xargs dirname 2>/dev/null)"; do
            if [[ -n "$_root" && -f "$_root/.env" ]]; then
                set -a
                # shellcheck disable=SC1091  # .env path is dynamic, not statically resolvable
                source "$_root/.env"
                set +a
                [[ -n "${ANTHROPIC_API_KEY:-}" ]] && break
            fi
        done
    fi

    # INFRA-5005: fast-fail when NO llm auth path is configured at all — an
    # OAuth-only environment with no ANTHROPIC_API_KEY, no OAuth token on
    # disk, and no other provider slot enabled. Without this check the
    # gateway call below still runs and provider_cascade's exhaustion path
    # sleeps up to CHUMP_CASCADE_EXHAUSTED_BACKOFF_S (default 30s) retrying
    # once before giving up (INFRA-363) — wasted latency when there is
    # nothing to retry. Detecting the fully-unconfigured case up front lets
    # the reviewer SKIP immediately instead of stalling bot-merge for ~30s.
    # Any other configured path (API key, OAuth token, local/cloud provider
    # slot) still goes through the gateway unchanged — this only short-
    # circuits the genuinely-nothing-configured case.
    _has_llm_auth=0
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && _has_llm_auth=1
    [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && _has_llm_auth=1
    [[ -n "${OPENAI_API_KEY:-}" ]] && _has_llm_auth=1
    [[ -n "${OPENAI_API_BASE:-}" ]] && _has_llm_auth=1
    if [[ $_has_llm_auth -eq 0 && -s "${CHUMP_OAUTH_TOKEN_PATH:-$HOME/.chump/oauth-token.json}" ]]; then
        _has_llm_auth=1
    fi
    if [[ $_has_llm_auth -eq 0 ]]; then
        for _n in 1 2 3 4 5 6 7 8 9; do
            _var="CHUMP_PROVIDER_${_n}_ENABLED"
            if [[ "${!_var:-}" == "1" ]]; then
                _has_llm_auth=1
                break
            fi
        done
    fi
    if [[ $_has_llm_auth -eq 0 ]]; then
        yellow "No LLM auth path configured (no ANTHROPIC_API_KEY, no OAuth token, no provider slot) — SKIPPING (GitHub required checks still gate this merge)."
        echo "SKIP: reviewer gateway unavailable (no provider configured for chump llm-complete)"
        exit 3
    fi

    # INFRA-3462: route the Tier-2 review through the SHARED LLM service via the
    # `chump llm-complete` gateway (ProviderCascade — full auth ladder incl OAuth,
    # 429 backoff, slot fallback) instead of a bespoke `curl` + `x-api-key` that
    # only worked with a raw API key. `--model opus` asks the cascade for a strong
    # slot and degrades gracefully to the cascade default if opus is unavailable.
    # No ANTHROPIC_API_KEY check here: the gateway owns auth.
    CHUMP_BIN="${CHUMP_LLM_BIN:-chump}"
    info "Tier-2 review via ${CHUMP_BIN} llm-complete (shared cascade, --model opus) …"
    if RESPONSE=$(printf '%s' "$PROMPT" | "$CHUMP_BIN" llm-complete --model opus --max-tokens 1024 2>/dev/null) \
        && [[ -n "${RESPONSE//[[:space:]]/}" ]]; then
        : # got a review
    else
        # The gateway itself couldn't produce a review (no provider configured at
        # all). Same INFRA-3457 rationale: the reviewer is a BONUS gate and
        # GitHub's required checks are the real protection, so SKIP (exit 3,
        # non-blocking) rather than block auto-merge. The 'SKIP:' line is captured
        # in bot-merge's log so a chronically-skipping reviewer stays visible.
        yellow "chump llm-complete produced no review — SKIPPING (GitHub required checks still gate this merge)."
        echo "SKIP: reviewer gateway unavailable (no provider configured for chump llm-complete)"
        exit 3
    fi
fi

# ── 7. Parse verdict ─────────────────────────────────────────────────────────
VERDICT_LINE=$(echo "$RESPONSE" | grep -E '^(APPROVE|CONCERN|ESCALATE):' | head -1)
if [[ -z "$VERDICT_LINE" ]]; then
    VERDICT_LINE="ESCALATE: code-reviewer response did not match expected format"
fi

VERDICT=$(echo "$VERDICT_LINE" | cut -d: -f1)
REASON=$(echo "$VERDICT_LINE" | cut -d: -f2- | sed 's/^ //')

# ── 7b. SPIRIT lens (CREDIBLE-191): stub-detection axis ──────────────────────
# Additive + fail-open. An absent or unparseable SPIRIT line leaves the verdict
# unchanged (preserves pre-CREDIBLE-191 behaviour, so a reviewer/model that
# doesn't emit the line never blocks a merge). Only an explicit SPIRIT: STUB
# downgrades a would-be APPROVE to a blocking CONCERN — the diff looks
# letter-correct but fakes the behaviour (the EFFECTIVE-351 stub-false-green
# class). STUB never *upgrades* a CONCERN/ESCALATE, and GENUINE/PARTIAL are
# informational only in this slice.
SPIRIT_LINE=$(echo "$RESPONSE" | grep -E '^SPIRIT:[[:space:]]*(GENUINE|PARTIAL|STUB)' | head -1)
SPIRIT=$(echo "$SPIRIT_LINE" | sed -E 's/^SPIRIT:[[:space:]]*([A-Z]+).*/\1/')
[[ -n "$SPIRIT" ]] && info "Spirit lens: $SPIRIT"
if [[ "$SPIRIT" == "STUB" && "$VERDICT" == "APPROVE" ]]; then
    _spirit_reason=$(echo "$SPIRIT_LINE" | cut -d: -f2- | sed 's/^ *//')
    yellow "SPIRIT: STUB overrides APPROVE — letter-correct but fakes the behaviour (CREDIBLE-191)."
    VERDICT="CONCERN"
    REASON="stub/faked implementation (SPIRIT lens): ${_spirit_reason:-no genuine behaviour}"
    VERDICT_LINE="CONCERN: $REASON"
fi

# ── 7c. CORRECTNESS + HARMONY lenses (CREDIBLE-191 slice-2) ───────────────────
# Same additive + fail-open contract as SPIRIT above: an absent/unparseable line
# never blocks; only an explicit FALSE-GREEN (logic wrong though it compiles/passes)
# or REGRESSION-RISK (plausibly breaks existing behaviour) downgrades a would-be
# APPROVE to a blocking CONCERN. SOUND/UNSURE/FITS/HACKY are informational. These
# never upgrade a CONCERN/ESCALATE. Together with SPIRIT they complete the
# multi-lens SCORING of stage B; the voting-PANEL restructure remains a later slice.
CORRECTNESS_LINE=$(echo "$RESPONSE" | grep -E '^CORRECTNESS:[[:space:]]*(SOUND|UNSURE|FALSE-GREEN)' | head -1)
CORRECTNESS=$(echo "$CORRECTNESS_LINE" | sed -E 's/^CORRECTNESS:[[:space:]]*([A-Z-]+).*/\1/')
[[ -n "$CORRECTNESS" ]] && info "Correctness lens: $CORRECTNESS"
if [[ "$CORRECTNESS" == "FALSE-GREEN" && "$VERDICT" == "APPROVE" ]]; then
    _corr_reason=$(echo "$CORRECTNESS_LINE" | cut -d: -f2- | sed 's/^ *//')
    yellow "CORRECTNESS: FALSE-GREEN overrides APPROVE — compiles/passes but logic is wrong (CREDIBLE-191)."
    VERDICT="CONCERN"
    REASON="broken-but-green (CORRECTNESS lens): ${_corr_reason:-logic wrong}"
    VERDICT_LINE="CONCERN: $REASON"
fi

HARMONY_LINE=$(echo "$RESPONSE" | grep -E '^HARMONY:[[:space:]]*(FITS|HACKY|REGRESSION-RISK)' | head -1)
HARMONY=$(echo "$HARMONY_LINE" | sed -E 's/^HARMONY:[[:space:]]*([A-Z-]+).*/\1/')
[[ -n "$HARMONY" ]] && info "Harmony lens: $HARMONY"
if [[ "$HARMONY" == "REGRESSION-RISK" && "$VERDICT" == "APPROVE" ]]; then
    _harm_reason=$(echo "$HARMONY_LINE" | cut -d: -f2- | sed 's/^ *//')
    yellow "HARMONY: REGRESSION-RISK overrides APPROVE — plausibly breaks existing behaviour (CREDIBLE-191)."
    VERDICT="CONCERN"
    REASON="regression risk (HARMONY lens): ${_harm_reason:-breaks existing behaviour}"
    VERDICT_LINE="CONCERN: $REASON"
fi


# ── 7d. Grounding check (CREDIBLE-207): CONCERN must cite file:line evidence ──
# The prompt now requires each concern to point at specific file:line evidence
# in the diff. A CONCERN with no such citation is treated as ungrounded — not
# proof the change is fine (still worth a human look), but not something that
# should silently auto-block a clean PR on a hallucinated boilerplate reason
# either. (CREDIBLE-207, PR #3495 EFFECTIVE-373: reviewer raised CONCERN citing
# "new unwrap()/expect() in production" + "new external dependencies added" —
# BOTH demonstrably false in that diff — because it dumped its entire
# boilerplate concern-reason list instead of specific verified findings.) An
# ungrounded CONCERN downgrades to ESCALATE so a human decides, instead of
# blocking the merge on an unverifiable claim.
if [[ "$VERDICT" == "CONCERN" ]] && ! echo "$REASON" | grep -qE '[A-Za-z0-9_./-]+\.[A-Za-z0-9_]+:[0-9]+'; then
    yellow "CONCERN has no file:line citation — treating as ungrounded, downgrading to ESCALATE (CREDIBLE-207)."
    _orig_reason="$REASON"
    REASON="reviewer raised CONCERN without citing file:line evidence — ungrounded, needs human triage. Original: ${_orig_reason}"
    VERDICT="ESCALATE"
    VERDICT_LINE="ESCALATE: $REASON"
fi

green "Verdict: $VERDICT"
info "Reason: $REASON"
echo "$VERDICT_LINE"

# ── 7d. Emit the structured verdict to ambient (CREDIBLE-191) ─────────────────
# Make the judgment organ's decision a QUERYABLE signal, not just prose buried in
# the PR comment's $RESPONSE dump: one review_verdict event per review carrying the
# final letter verdict AND each lens outcome (spirit/correctness/harmony). This is
# what feeds the learning loop — which lens caught what, over time — and gives the
# fleet observability into review decisions. Fire-and-forget: it runs after the
# verdict is final, never blocks or changes the review, and swallows any write
# error. Registered in docs/observability/EVENT_REGISTRY.yaml (emit↔register gate).
_rv_amb="${CHUMP_AMBIENT_LOG:-${REPO_ROOT}/.chump-locks/ambient.jsonl}"
if [[ -n "$_rv_amb" ]]; then
    # scanner-anchor: "kind":"review_verdict"
    printf '{"ts":"%s","kind":"review_verdict","gap_id":"%s","pr":"%s","verdict":"%s","spirit":"%s","correctness":"%s","harmony":"%s","loc":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GAP_ID:-}" "${PR:-}" "$VERDICT" "${SPIRIT:-}" "${CORRECTNESS:-}" "${HARMONY:-}" "${LOC:-0}" \
        >> "$_rv_amb" 2>/dev/null || true
fi

# ── 8. Post review to GitHub (if --post) ─────────────────────────────────────
COMMENT_BODY="🤖 **code-reviewer-agent** (automated, INFRA-AGENT-CODEREVIEW MVP):

**Verdict:** $VERDICT
**Reason:** $REASON

Diff size: $LOC LOC. Changed files: $(echo "$CHANGED_FILES" | wc -l | tr -d ' ').

Full reasoning:
\`\`\`
$RESPONSE
\`\`\`

See \`docs/process/CODEREVIEW_POLICY.md\` for the auto-approve criteria."

if [[ $POST -eq 1 ]]; then
    case "$VERDICT" in
        APPROVE)
            info "Posting approval review …"
            gh pr review "$PR" --approve --body "$COMMENT_BODY" >&2 || \
                gh pr comment "$PR" --body "$COMMENT_BODY" >&2 ;;
        CONCERN)
            info "Posting concern as request-changes review …"
            gh pr review "$PR" --request-changes --body "$COMMENT_BODY" >&2 || \
                gh pr comment "$PR" --body "$COMMENT_BODY" >&2 ;;
        ESCALATE)
            info "Posting escalation comment …"
            gh pr comment "$PR" --body "$COMMENT_BODY" >&2 ;;
    esac
fi

# ── 9. Exit code ─────────────────────────────────────────────────────────────
case "$VERDICT" in
    APPROVE)  exit 0 ;;
    CONCERN)  exit 1 ;;
    ESCALATE) exit 2 ;;
    *)        exit 4 ;;
esac
