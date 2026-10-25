#!/bin/sh
# scripts/git-hooks/lib/off-rails-guard.sh
#
# Extracted from scripts/git-hooks/pre-commit (RESILIENT-034, 2026-05-27)
# to keep pre-commit hook under the 2050-line audit-budget guard
# (scripts/ci/test-precommit-guard-audit.sh).
#
# Provides two guards, sourced inline from pre-commit:
#
#   1. RESILIENT-025: Off-rails subject guard
#      Commit subject must mention the claimed gap ID from
#      .chump-locks/claim-*.json. Prevents sub-agent off-rails class
#      (agent dispatched on INFRA-A commits "fix(INFRA-B):" by mistake).
#
#   2. RESILIENT-026: Claim-paths guard
#      Staged files must be a subset of claim.paths. Enforces the FULL
#      claim contract beyond just the subject. Always-allowed:
#      .chump/state.sql, docs/gaps/*.yaml, .gitignore.
#
# Both guards share the same bypass mechanism:
#   - 'Off-Rails-Bypass: <reason>' trailer in commit body, OR
#   - CHUMP_OFF_RAILS_CHECK=0 env var.
#
# Bypass usage is audited via kind=off_rails_bypassed to ambient.jsonl.
#
# Caller must set: $REPO_ROOT
#
# This file is `.` sourced — it does NOT exec; it uses `exit 1` on
# block which terminates the parent (pre-commit) intentionally.

# INFRA-1081: source lease helper
if [ -f "$REPO_ROOT/scripts/coord/lib/lease.sh" ]; then
    . "$REPO_ROOT/scripts/coord/lib/lease.sh"
fi

# ------------------------------------------------------------------
# 1c. Off-rails guard (RESILIENT-025): commit subject must mention claimed gap
# ------------------------------------------------------------------

# CREDIBLE-1566: refuse CHUMP_OFF_RAILS_CHECK=0 or Off-Rails-Bypass: inside agent dispatch sessions
if [ -n "${CHUMP_DISPATCH_GAP:-}${CHUMP_FLEET_SESSION:-}${FLEET_AGENT_ID:-}${CHUMP_WORKER_TICK:-}" ]; then
    _OR_GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || true)
    _OR_EDITMSG="${_OR_GIT_DIR}/COMMIT_EDITMSG"
    _OR_BYPASS_HIT=""
    if [ "${CHUMP_OFF_RAILS_CHECK:-1}" = "0" ]; then
        _OR_BYPASS_HIT="CHUMP_OFF_RAILS_CHECK=0"
    elif [ -n "$_OR_GIT_DIR" ] && [ -f "$_OR_EDITMSG" ] && grep -qE '^Off-Rails-Bypass:' "$_OR_EDITMSG"; then
        _OR_BYPASS_HIT="Off-Rails-Bypass:"
    fi
    if [ -n "$_OR_BYPASS_HIT" ]; then
        _OR_AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
        mkdir -p "$(dirname "$_OR_AMBIENT")" 2>/dev/null || true
        printf '{"ts":"%s","kind":"agent_bypass_refused","hook":"pre-commit","gap_id":"%s","bypass":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CHUMP_DISPATCH_GAP:-${CHUMP_FLEET_SESSION:-agent}}" "$_OR_BYPASS_HIT" \
            >> "$_OR_AMBIENT" 2>/dev/null || true
        echo "[pre-commit] ERROR (CREDIBLE-1566): $_OR_BYPASS_HIT is forbidden in fleet agent / dispatch sessions" >&2
        exit 1
    fi
fi

if [ "${CHUMP_OFF_RAILS_CHECK:-1}" != "0" ]; then
    _CLAIM_FILE=$(get_active_claim_file "$REPO_ROOT")
    if [ -n "$_CLAIM_FILE" ] && [ -f "$_CLAIM_FILE" ]; then
        _CLAIMED_GAP=$(get_claimed_gap "$_CLAIM_FILE")
        if [ -n "$_CLAIMED_GAP" ]; then
            # Use git rev-parse --git-dir to resolve COMMIT_EDITMSG correctly in worktrees
            # (in a worktree .git is a file, not a directory — $REPO_ROOT/.git/COMMIT_EDITMSG fails)
            _GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || true)
            _EDITMSG="${_GIT_DIR}/COMMIT_EDITMSG"
            if [ -n "$_GIT_DIR" ] && [ -f "$_EDITMSG" ]; then
                _COMMIT_MSG=$(cat "$_EDITMSG")
                if grep -qE '^Off-Rails-Bypass:' "$_EDITMSG"; then
                    # Audit the bypass
                    _BYPASS_REASON=$(grep -E '^Off-Rails-Bypass:' "$_EDITMSG" \
                        | head -1 | sed 's/^Off-Rails-Bypass:[[:space:]]*//')
                    printf '{"ts":"%s","kind":"off_rails_bypassed","claimed_gap":"%s","reason":"%s"}\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_CLAIMED_GAP" "$_BYPASS_REASON" \
                        >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
                elif ! echo "$_COMMIT_MSG" | grep -qiE "$_CLAIMED_GAP"; then
                    echo "[pre-commit] BLOCKED (RESILIENT-025): commit subject must mention claimed gap $_CLAIMED_GAP" >&2
                    echo "[pre-commit] Active claim: $_CLAIM_FILE" >&2
                    echo "[pre-commit] Bypass: add 'Off-Rails-Bypass: <reason>' trailer for intentional pre-req integration" >&2
                    echo "[pre-commit] Or: CHUMP_OFF_RAILS_CHECK=0 git commit ..." >&2
                    exit 1
                fi
            fi
        fi
    fi
fi

# ------------------------------------------------------------------
# 1d. Claim-paths guard (RESILIENT-026): staged files must be subset of claim.paths
# ------------------------------------------------------------------

if [ "${CHUMP_OFF_RAILS_CHECK:-1}" != "0" ]; then
    _CLAIM_FILE_CP=$(get_active_claim_file "$REPO_ROOT")
    if [ -n "$_CLAIM_FILE_CP" ] && [ -f "$_CLAIM_FILE_CP" ]; then
        _CLAIMED_GAP_CP=$(get_claimed_gap "$_CLAIM_FILE_CP")
        _CLAIM_PATHS_CP=$(get_claim_paths "$_CLAIM_FILE_CP")
        if [ -n "$_CLAIMED_GAP_CP" ] && [ -n "$_CLAIM_PATHS_CP" ]; then
            # Check for bypass trailer first — same bypass as RESILIENT-025
            _GIT_DIR_CP=$(git rev-parse --git-dir 2>/dev/null || true)
            _EDITMSG_CP="${_GIT_DIR_CP}/COMMIT_EDITMSG"
            _BYPASS_ACTIVE=0
            if [ -n "$_GIT_DIR_CP" ] && [ -f "$_EDITMSG_CP" ] && grep -qE '^Off-Rails-Bypass:' "$_EDITMSG_CP"; then
                _BYPASS_ACTIVE=1
                # Audit: log which field was bypassed
                _BYPASS_REASON_CP=$(grep -E '^Off-Rails-Bypass:' "$_EDITMSG_CP" \
                    | head -1 | sed 's/^Off-Rails-Bypass:[[:space:]]*//')
                printf '{"ts":"%s","kind":"off_rails_bypassed","claimed_gap":"%s","bypassed_field":"paths","reason":"%s"}\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_CLAIMED_GAP_CP" "$_BYPASS_REASON_CP" \
                    >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true
            fi
            if [ "$_BYPASS_ACTIVE" = "0" ]; then
                # Always-allowed auto-generated paths
                _ALLOW_REGEX='^(\.chump/state\.sql|docs/gaps/[^/]+\.yaml|\.gitignore)$'
                _STAGED_FILES_CP=$(git diff --cached --name-only 2>/dev/null || true)
                _BAD_FILES_CP=""
                while IFS= read -r _f; do
                    [ -z "$_f" ] && continue
                    # Always-allowed
                    if echo "$_f" | grep -qE "$_ALLOW_REGEX"; then continue; fi
                    # Check against claim paths
                    _MATCHED=0
                    while IFS= read -r _p; do
                        [ -z "$_p" ] && continue
                        if [ "$_f" = "$_p" ]; then
                            _MATCHED=1; break
                        fi
                        # Support prefix patterns (foo/bar/** or foo/bar/)
                        if [ "${_p%/\*\*}" != "$_p" ]; then
                            _prefix="${_p%/\*\*}/"
                            case "$_f/" in "$_prefix"*) _MATCHED=1; break ;; esac
                        elif [ "${_p%/}" != "$_p" ]; then
                            case "$_f/" in "${_p}"*) _MATCHED=1; break ;; esac
                        fi
                    done <<EOF_PATHS
$_CLAIM_PATHS_CP
EOF_PATHS
                    if [ "$_MATCHED" = "0" ]; then
                        _BAD_FILES_CP="${_BAD_FILES_CP} ${_f}"
                    fi
                done <<EOF_STAGED_CP
$_STAGED_FILES_CP
EOF_STAGED_CP
                if [ -n "$_BAD_FILES_CP" ]; then
                    echo "[pre-commit] BLOCKED (RESILIENT-026): staged files not in claim.paths for $_CLAIMED_GAP_CP:" >&2
                    echo "$_BAD_FILES_CP" | tr ' ' '\n' | grep -v '^$' | sed 's/^/    /' >&2
                    echo "[pre-commit] Claim paths:" >&2
                    echo "$_CLAIM_PATHS_CP" | sed 's/^/    /' >&2
                    echo "[pre-commit] Bypass: add 'Off-Rails-Bypass: <reason>' trailer" >&2
                    echo "[pre-commit] Or: CHUMP_OFF_RAILS_CHECK=0 git commit ..." >&2
                    exit 1
                fi
            fi
        fi
    fi
fi
