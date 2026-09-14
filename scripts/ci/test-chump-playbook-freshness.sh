#!/usr/bin/env bash
# scripts/ci/test-chump-playbook-freshness.sh — META-418 (META-172 slice)
#
# CI gate for docs/process/CHUMP_PLAYBOOK.md — the load-bearing "how Chump
# works" reference doc. A doc like this that silently drifts from the code
# it describes is worse than no doc: it actively misleads readers. This gate
# runs 5 assertions and prints the exact divergent line number(s) so the
# owning curator-lane can fix it without re-deriving context.
#
#   1. curator role count in §2 == number of .claude/agents/*.md files
#   2. every plist named in the daemon table exists in launchd/ or
#      ~/Library/LaunchAgents/
#   3. every event kind named in §5 is registered in
#      docs/observability/EVENT_REGISTRY.yaml
#   4. every scripts/*.sh path cited in the doc exists on disk
#   5. every gap ID cited in the doc exists in state.db (or docs/gaps/*.yaml
#      when state.db is unpopulated in this worktree)
#
# Target runtime: <30s. Exits 0 when all assertions pass, non-zero otherwise.
# If CHUMP_PLAYBOOK.md does not exist yet (tracked by META-172), this is a
# no-op PASS — there is nothing to verify until the doc is written.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$REPO/docs/process/CHUMP_PLAYBOOK.md"

FAILED=0

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAILED=1; }

if [[ ! -f "$DOC" ]]; then
    echo "SKIP: $DOC does not exist yet (tracked by META-172) — nothing to verify"
    exit 0
fi

# Section-body helper: prints lines [start_header_line+1, next_header_line-1]
# for a "^## <n>." header, with line numbers preserved via grep -n on the
# result of a subsequent search (callers re-grep the returned range).
section_range() {
    local n="$1"
    local start end
    start=$(grep -nE "^## ${n}\." "$DOC" | head -1 | cut -d: -f1)
    [[ -z "$start" ]] && return 1
    end=$(awk -v s="$start" 'NR>s && /^## [0-9]+\./{print NR; exit}' "$DOC")
    [[ -z "$end" ]] && end=$(wc -l < "$DOC")
    printf '%s %s\n' "$start" "$end"
}

# ── Assertion 1: curator role count (§2) vs .claude/agents/*.md ────────────
if range=$(section_range 2); then
    read -r s2_start s2_end <<<"$range"
    doc_role_count=$(sed -n "${s2_start},${s2_end}p" "$DOC" \
        | grep -cE '^\s*[-*]\s+\*\*|^\|\s*`?curator-')
    actual_role_count=$(ls "$REPO"/.claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$doc_role_count" -eq "$actual_role_count" ]]; then
        ok "assertion 1: curator role count matches ($doc_role_count == $actual_role_count)"
    else
        fail "assertion 1: curator role count mismatch — §2 (lines ${s2_start}-${s2_end}) lists $doc_role_count, .claude/agents/*.md has $actual_role_count"
    fi
else
    fail "assertion 1: no '## 2.' section header found in $DOC"
fi

# ── Assertion 2: every plist named exists in launchd/ or ~/Library/LaunchAgents ─
plist_hits=$(grep -noE '[A-Za-z0-9_.-]+\.plist' "$DOC" || true)
if [[ -z "$plist_hits" ]]; then
    ok "assertion 2: no plist references found (nothing to check)"
else
    miss=0
    while IFS=: read -r lineno name; do
        if [[ -f "$REPO/launchd/$name" || -f "$HOME/Library/LaunchAgents/$name" ]]; then
            :
        else
            fail "assertion 2: $DOC:$lineno — plist '$name' not found in launchd/ or ~/Library/LaunchAgents/"
            miss=1
        fi
    done <<<"$plist_hits"
    [[ "$miss" -eq 0 ]] && ok "assertion 2: all cited plists exist"
fi

# ── Assertion 3: every event kind in §5 is registered in EVENT_REGISTRY.yaml ─
REGISTRY="$REPO/docs/observability/EVENT_REGISTRY.yaml"
if range=$(section_range 5); then
    read -r s5_start s5_end <<<"$range"
    kind_hits=$(sed -n "${s5_start},${s5_end}p" "$DOC" | grep -noE 'kind=[a-z_]+' || true)
    if [[ -z "$kind_hits" ]]; then
        ok "assertion 3: no event kinds cited in §5 (nothing to check)"
    else
        miss=0
        while IFS=: read -r relno match; do
            lineno=$((s5_start + relno - 1))
            k="${match#kind=}"
            if [[ -f "$REGISTRY" ]] && grep -qE "^\s*-\s*kind:\s*${k}\s*$" "$REGISTRY"; then
                :
            else
                fail "assertion 3: $DOC:$lineno — event kind '$k' not registered in docs/observability/EVENT_REGISTRY.yaml"
                miss=1
            fi
        done <<<"$kind_hits"
        [[ "$miss" -eq 0 ]] && ok "assertion 3: all §5 event kinds are registered"
    fi
else
    fail "assertion 3: no '## 5.' section header found in $DOC"
fi

# ── Assertion 4: every scripts/*.sh path cited exists on disk ──────────────
script_hits=$(grep -noE 'scripts/[A-Za-z0-9_./-]+\.sh' "$DOC" | sort -u -t: -k2 || true)
if [[ -z "$script_hits" ]]; then
    ok "assertion 4: no script paths cited (nothing to check)"
else
    miss=0
    while IFS=: read -r lineno path; do
        if [[ -f "$REPO/$path" ]]; then
            :
        else
            fail "assertion 4: $DOC:$lineno — script path '$path' does not exist on disk"
            miss=1
        fi
    done <<<"$script_hits"
    [[ "$miss" -eq 0 ]] && ok "assertion 4: all cited script paths exist"
fi

# ── Assertion 5: every gap ID cited exists in state.db (or docs/gaps/*.yaml) ─
gap_hits=$(grep -noE '\b(INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|ZERO-WASTE|DOC|MISSION|FLEET)-[0-9]+\b' "$DOC" || true)
if [[ -z "$gap_hits" ]]; then
    ok "assertion 5: no gap IDs cited (nothing to check)"
else
    STATE_DB="$REPO/.chump/state.db"
    db_row_count=0
    if [[ -f "$STATE_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
        db_row_count=$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM gaps;" 2>/dev/null || echo 0)
    fi
    miss=0
    while IFS=: read -r lineno gid; do
        found=0
        if [[ "$db_row_count" -gt 0 ]]; then
            cnt=$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM gaps WHERE id = '${gid}';" 2>/dev/null || echo 0)
            [[ "$cnt" -gt 0 ]] && found=1
        else
            # state.db unpopulated in this worktree — fall back to the
            # yaml-on-disk mirror (same fallback as test-operator-playbook-structure.sh)
            [[ -f "$REPO/docs/gaps/${gid}.yaml" ]] && found=1
        fi
        if [[ "$found" -eq 0 ]]; then
            fail "assertion 5: $DOC:$lineno — gap ID '$gid' not found in state.db"
            miss=1
        fi
    done <<<"$gap_hits"
    [[ "$miss" -eq 0 ]] && ok "assertion 5: all cited gap IDs exist"
fi

if [[ "$FAILED" -eq 0 ]]; then
    echo "chump-playbook-freshness: ALL ASSERTIONS PASSED"
    exit 0
else
    echo "chump-playbook-freshness: ONE OR MORE ASSERTIONS FAILED"
    exit 1
fi
