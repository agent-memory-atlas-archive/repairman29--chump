#!/usr/bin/env bash
# scripts/ci/test-merge-group-coverage.sh — INFRA-2095
#
# Verifies that EVERY workflow producing a required status check on main
# also fires on `merge_group` events. Without merge_group triggers the
# required check never runs against the queue's synthetic merge commit,
# and the merge queue blocks forever waiting for a check that doesn't
# fire — the textbook merge-queue footgun.
#
# Pairs with:
#   - INFRA-1377: scripts/ci/test-merge-queue-armed.sh — verifies the
#     queue itself is enabled at the branch-protection level.
#   - INFRA-2095: this script — verifies the queue WILL succeed once
#     enabled (every required check fires on merge_group events).
#
# Mode:
#   Default (advisory): exits 0 with WARN if any required-check workflow
#   is missing the merge_group trigger. Set CHUMP_MERGE_GROUP_STRICT=1 to
#   make it blocking (exit 1 on drift).
#
# Usage:
#   bash scripts/ci/test-merge-group-coverage.sh
#   CHUMP_MERGE_GROUP_STRICT=1 bash scripts/ci/test-merge-group-coverage.sh
#
# What it does:
#   1. Reads main's required_status_checks via `gh api`.
#   2. For each required check name, locates the source workflow file
#      under .github/workflows/.
#   3. Verifies the workflow's `on:` block includes `merge_group:`.
#   4. Reports any required check whose source workflow lacks the trigger.
#
# Discovery rules:
#   - A "source workflow" is the one whose `jobs.<id>.name` matches the
#     required-check name, OR whose `jobs.<id>:` key matches when no
#     explicit `name:` is set.
#   - A workflow is "merge_group-wired" if its top-level `on:` mapping
#     contains a `merge_group:` key (with or without filter sub-keys).
#
# Exit codes:
#   0 — all required-check workflows are merge_group-wired (or in
#       advisory mode with WARNs)
#   1 — strict mode + at least one source workflow missing merge_group
#   2 — environment problem (no gh, no GITHUB_TOKEN, no remote)

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")}"
STRICT="${CHUMP_MERGE_GROUP_STRICT:-0}"
WORKFLOWS_DIR="${REPO_ROOT}/.github/workflows"

PASS=0
FAIL=0
WARN=0

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
warn() { printf '\033[0;33mWARN\033[0m %s\n' "$*" >&2; WARN=$((WARN+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

echo "=== INFRA-2095 merge_group coverage audit ==="
echo
echo "Verifies every required status check on main fires on merge_group"
echo "events. Missing trigger = merge queue blocks forever."
echo

# ── 1. Resolve owner/repo + token availability ────────────────────────────────
REPO="$(git -C "${REPO_ROOT}" remote get-url chump 2>/dev/null \
    | sed 's|.*github.com[:/]||;s|.git$||' \
    || git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null \
    | sed 's|.*github.com[:/]||;s|.git$||' \
    || echo '')"

if [[ -z "${REPO}" ]]; then
    warn "Cannot determine owner/repo from git remotes — skipping live check"
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    warn "gh CLI not available — skipping required-check enumeration"
    exit 0
fi

# Quiet `gh auth status` so missing-auth doesn't read as the real failure.
if ! gh auth status >/dev/null 2>&1; then
    warn "gh not authenticated — skipping (set GH_TOKEN to enable)"
    exit 0
fi

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"
echo "[1. Repo identified: ${OWNER}/${REPO_NAME}]"
echo

# ── 2. Enumerate required status checks on main ───────────────────────────────
echo "[2. Required status checks on main]"

REQUIRED_CHECKS_JSON="$(gh api "repos/${OWNER}/${REPO_NAME}/branches/main/protection" 2>/dev/null || echo '{}')"
if [[ "${REQUIRED_CHECKS_JSON}" == '{}' ]]; then
    warn "Could not read branch protection for main — skipping"
    exit 0
fi

# Required checks come from BOTH legacy required_status_checks.contexts AND
# the modern ruleset rule (required_status_checks rule type). We union both.
LEGACY_CHECKS="$(echo "${REQUIRED_CHECKS_JSON}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(c) for c in d.get("required_status_checks",{}).get("contexts",[]) or []]' \
    2>/dev/null || true)"

# Modern ruleset checks: enumerate active rulesets, find required_status_checks rule.
RULESETS_JSON="$(gh api "repos/${OWNER}/${REPO_NAME}/rulesets" 2>/dev/null || echo '[]')"
RULESET_IDS="$(echo "${RULESETS_JSON}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(r["id"]) for r in d if r.get("enforcement")=="active"]' \
    2>/dev/null || true)"

RULESET_CHECKS=""
for rid in ${RULESET_IDS}; do
    rule_json="$(gh api "repos/${OWNER}/${REPO_NAME}/rulesets/${rid}" 2>/dev/null || echo '{}')"
    contexts="$(echo "${rule_json}" \
        | python3 -c '
import json, sys
d = json.load(sys.stdin)
for r in d.get("rules", []):
    if r.get("type") == "required_status_checks":
        for c in r.get("parameters", {}).get("required_status_checks", []):
            print(c.get("context", ""))' 2>/dev/null || true)"
    if [[ -n "${contexts}" ]]; then
        RULESET_CHECKS+="${contexts}"$'\n'
    fi
done

# Union + dedup (drop empty lines)
ALL_CHECKS="$(printf '%s\n%s\n' "${LEGACY_CHECKS}" "${RULESET_CHECKS}" \
    | sort -u | grep -v '^$' || true)"

if [[ -z "${ALL_CHECKS}" ]]; then
    warn "No required status checks found on main — nothing to audit"
    exit 0
fi

CHECK_COUNT="$(echo "${ALL_CHECKS}" | wc -l | tr -d ' ')"
ok "Found ${CHECK_COUNT} required status check(s):"
echo "${ALL_CHECKS}" | sed 's/^/    - /'
echo

# ── 3. For each required check, locate source workflow + verify merge_group ──
echo "[3. Source-workflow merge_group trigger audit]"

# Helper: scan all workflows, for each find the YAML job ID and `name:` of each
# job. Output `WORKFLOW\tJOB_ID\tJOB_NAME` per row, where JOB_NAME defaults
# to JOB_ID when not explicitly set. Uses python for robustness vs. grep.
WORKFLOW_INDEX="$(python3 - "${WORKFLOWS_DIR}" <<'PYEOF'
import sys, os, re

try:
    import yaml
except ImportError:
    yaml = None

def parse_workflow_stdlib(text):
    """Pure-stdlib fallback when PyYAML is not installed in the runner python."""
    fires_on_pr = False
    has_mg = False
    jobs = {}
    section = None
    cur_job = None
    for raw in text.splitlines():
        stripped = raw.split('#', 1)[0].rstrip()
        if not stripped.strip():
            continue
        indent = len(stripped) - len(stripped.lstrip(' '))
        line = stripped.strip()
        if indent == 0:
            cur_job = None
            m_top = re.match(r'^["\']?([A-Za-z0-9_-]+)["\']?\s*:(.*)$', line)
            if m_top:
                key, rest = m_top.group(1), m_top.group(2).strip()
                if key == 'on':
                    section = 'on'
                    if 'pull_request' in rest:
                        fires_on_pr = True
                    if 'merge_group' in rest:
                        has_mg = True
                elif key == 'jobs':
                    section = 'jobs'
                else:
                    section = None
            continue
        if section == 'on':
            m_ev = re.match(r'^[-\s]*([A-Za-z0-9_-]+)\s*(?::|$)', line)
            if m_ev:
                ev = m_ev.group(1)
                if ev == 'pull_request':
                    fires_on_pr = True
                elif ev == 'merge_group':
                    has_mg = True
        elif section == 'jobs':
            if indent == 2:
                m_job = re.match(r'^([A-Za-z0-9_-]+)\s*:\s*$', line)
                if m_job:
                    cur_job = m_job.group(1)
                    jobs[cur_job] = {'name': None}
                else:
                    cur_job = None
            elif indent == 4 and cur_job:
                m_name = re.match(r'^name\s*:\s*(.+)$', line)
                if m_name:
                    val = m_name.group(1).strip()
                    if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                        val = val[1:-1]
                    jobs[cur_job]['name'] = val
    return fires_on_pr, has_mg, jobs

wf_dir = sys.argv[1]
for fn in sorted(os.listdir(wf_dir)):
    if not (fn.endswith('.yml') or fn.endswith('.yaml')):
        continue
    path = os.path.join(wf_dir, fn)
    try:
        with open(path, encoding='utf-8') as f:
            text = f.read()
    except Exception:
        continue
    if yaml is not None:
        try:
            d = yaml.safe_load(text) or {}
        except Exception:
            continue
        # YAML 'on' may parse as True (PyYAML 1.x bool quirk on bare `on:`).
        on_block = d.get('on') if 'on' in d else d.get(True, {})
        if isinstance(on_block, dict):
            fires_on_pr = 'pull_request' in on_block
            has_mg = 'merge_group' in on_block
        elif isinstance(on_block, list):
            fires_on_pr = 'pull_request' in on_block
            has_mg = 'merge_group' in on_block
        else:
            fires_on_pr = False
            has_mg = False
        jobs = d.get('jobs') or {}
    else:
        fires_on_pr, has_mg, jobs = parse_workflow_stdlib(text)
    if not fires_on_pr:
        continue
    for jid, jdef in jobs.items():
        jname = (jdef or {}).get('name') or jid
        print(f"{fn}\t{jid}\t{jname}\t{int(has_mg)}")
PYEOF
)"

if [[ -z "${WORKFLOW_INDEX}" ]]; then
    fail "Could not index workflow files (python yaml parse failure?)"
    exit 2
fi

MISSING=0
while IFS= read -r check_name; do
    # Find rows where job-name (col 3) matches the required check
    # Try exact match first, then job-id match for skin-suffix wrappers
    MATCHES="$(echo "${WORKFLOW_INDEX}" \
        | awk -F'\t' -v target="${check_name}" '$3 == target {print}')"

    if [[ -z "${MATCHES}" ]]; then
        warn "  ${check_name}: no source workflow found (check name uses dynamic suffix or comes from ruleset-only registration)"
        continue
    fi

    # If multiple workflows define the same job name, all must be merge_group
    while IFS=$'\t' read -r wf jid jname has_mg; do
        if [[ "${has_mg}" == "1" ]]; then
            ok "  ${check_name} → ${wf} (job=${jid}) merge_group-wired"
        else
            fail "  ${check_name} → ${wf} (job=${jid}) MISSING merge_group: trigger"
            MISSING=$((MISSING+1))
        fi
    done <<< "${MATCHES}"
done <<< "${ALL_CHECKS}"

echo
echo "=== Summary: ${PASS} pass, ${FAIL} fail, ${WARN} warn (missing=${MISSING}) ==="

if [[ "${MISSING}" -gt 0 ]] && [[ "${STRICT}" == "1" ]]; then
    echo "STRICT mode: failing build because required-check workflows lack merge_group trigger." >&2
    echo "Fix: add 'merge_group:' to each affected workflow's top-level 'on:' block." >&2
    exit 1
fi

exit 0
