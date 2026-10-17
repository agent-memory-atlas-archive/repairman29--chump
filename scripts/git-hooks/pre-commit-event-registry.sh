#!/usr/bin/env bash
# pre-commit-event-registry.sh — INFRA-754
#
# Enforces "observability before scale": refuses any commit that introduces
# a new `"kind":"X"` ambient-event literal unless X is registered in
# docs/observability/EVENT_REGISTRY.yaml.
#
# Rationale:
#   - The fleet emits events into .chump-locks/ambient.jsonl as the
#     load-bearing peripheral-vision substrate. Consumers (fleet-brief,
#     waste-tally, kpi-report, watchdogs) parse these by `kind=`.
#   - When a contributor invents a new `kind` without registering it,
#     consumers silently miss it and the operator loses visibility.
#   - A registry + commit-time guard makes "observability before scale"
#     mechanically enforceable instead of a doctrine doc nobody reads.
#
# Bypass:
#   CHUMP_EVENT_REGISTRY_CHECK=0 git commit ...
#   (commit body should include `Event-Registry-Bypass: <reason>` trailer)
#
# Output: exits 0 silently when no new kinds appear or all are registered;
# exits non-zero with a diagnostic listing offending kind values.

set -uo pipefail

# Bypass switch — keep parity with other Chump guards
if [[ "${CHUMP_EVENT_REGISTRY_CHECK:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REGISTRY="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"

# If the registry doesn't exist (e.g. on a branch that predates INFRA-754),
# bail out silently rather than blocking unrelated commits.
if [[ ! -f "$REGISTRY" ]]; then
    exit 0
fi

# CREDIBLE-1516: YAML-parse gate. The rest of this hook (and every other
# registry gate) only greps `kind:` lines and never parses the document, so an
# illegal scalar — e.g. a backtick-led plain scalar — sailed through for months
# and broke the INFRA-8223 union merge driver. Parse the STAGED content of each
# observability registry with yaml.safe_load when PyYAML is available. Skips
# silently when PyYAML is absent (the authoritative gate is the CI/preflight
# step scripts/ci/test-event-registry-yaml-parse.sh, which installs PyYAML).
if python3 -c 'import yaml' >/dev/null 2>&1; then
    for rel in docs/observability/EVENT_REGISTRY.yaml docs/observability/SELF_REPORTS.yaml; do
        # Only check files actually staged in this commit. Capture-then-test
        # rather than piping into `grep -q` (SIGPIPE under `set -o pipefail`).
        staged_names="$(git diff --cached --name-only --diff-filter=ACM -- "$rel")"
        if [[ -z "$staged_names" ]]; then
            continue
        fi
        parse_err=""
        if ! parse_err="$(git show ":$rel" 2>/dev/null | python3 -c '
import sys, yaml
try:
    yaml.safe_load(sys.stdin)
except yaml.YAMLError as e:
    sys.stderr.write(str(e))
    sys.exit(1)
' 2>&1)"; then
            echo "──────────────────────────────────────────────────────────────────────" >&2
            echo "❌ CREDIBLE-1516 registry YAML-parse guard blocked this commit." >&2
            echo "" >&2
            echo "$rel does not parse as YAML:" >&2
            printf '%s\n' "$parse_err" | sed 's/^/    /' >&2
            echo "" >&2
            echo "Fix the offending scalar. A plain scalar may not start with a" >&2
            echo "backtick/@/%/etc. and may not contain ': ' — convert multi-line" >&2
            echo "plain scalars to a '>-' folded block (content unchanged)." >&2
            echo "Bypass once (sparingly): CHUMP_EVENT_REGISTRY_CHECK=0 git commit ..." >&2
            echo "──────────────────────────────────────────────────────────────────────" >&2
            exit 1
        fi
    done
fi

# Collect staged additions (we only care about added lines — removing a
# kind never breaks the consumer contract that this guard enforces).
STAGED_DIFF="$(git diff --cached --no-color --diff-filter=ACM -U0 -- \
    '*.rs' '*.sh' '*.py' '*.ts' '*.tsx' '*.js' '*.yml' '*.yaml' 2>/dev/null || true)"

if [[ -z "$STAGED_DIFF" ]]; then
    exit 0
fi

# Extract `"kind":"<value>"` from added lines (lines starting with + and
# not the +++ header). Tolerates whitespace around the colon.
NEW_KINDS=$(printf '%s\n' "$STAGED_DIFF" \
    | grep -E '^\+[^+]' \
    | grep -oE '"kind"[[:space:]]*:[[:space:]]*"[a-zA-Z_][a-zA-Z0-9_]*"' \
    | sed -E 's/.*"kind"[[:space:]]*:[[:space:]]*"([a-zA-Z_][a-zA-Z0-9_]*)".*/\1/' \
    | sort -u)

if [[ -z "$NEW_KINDS" ]]; then
    exit 0
fi

# Extract registered kinds from the YAML. Lazy regex parse to avoid a
# pyyaml dep — the schema is shallow enough that `^  - kind: <name>` is
# unambiguous.
REGISTERED=$(grep -E '^  - kind:[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*' "$REGISTRY" \
    | sed -E 's/^  - kind:[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*).*/\1/' \
    | sort -u)

# Find any new kind that isn't in the registry.
UNREGISTERED=()
while IFS= read -r kind; do
    [[ -z "$kind" ]] && continue
    if ! grep -qxF "$kind" <<< "$REGISTERED"; then
        UNREGISTERED+=("$kind")
    fi
done <<< "$NEW_KINDS"

if [[ "${#UNREGISTERED[@]}" -eq 0 ]]; then
    exit 0
fi

# Block the commit with a diagnostic.
echo "──────────────────────────────────────────────────────────────────────" >&2
echo "❌ INFRA-754 event-registry guard blocked this commit." >&2
echo "" >&2
echo "Unregistered ambient.jsonl kinds in your staged diff:" >&2
for k in "${UNREGISTERED[@]}"; do
    echo "    \"kind\":\"$k\"" >&2
done
echo "" >&2
echo "Why: every emitter must be discoverable from one place so consumers" >&2
echo "(fleet-brief, waste-tally, kpi-report, watchdogs) can parse it. See" >&2
echo "docs/process/OBSERVABILITY_DOCTRINE.md for the rationale." >&2
echo "" >&2
echo "Fix one of:" >&2
echo "  1. Add an entry to docs/observability/EVENT_REGISTRY.yaml:" >&2
echo "        - kind: <name>" >&2
echo "          emitter: <file or component>" >&2
echo "          trigger: <one-line description>" >&2
echo "          consumers: [<list>]   # optional but encouraged" >&2
echo "          fields_required: [<list>]   # optional but encouraged" >&2
echo "" >&2
echo "  2. Reuse an existing kind that already covers your case." >&2
echo "" >&2
echo "  3. Bypass once (sparingly):" >&2
echo "        CHUMP_EVENT_REGISTRY_CHECK=0 git commit ..." >&2
echo "     and add a trailer to the commit body:" >&2
echo "        Event-Registry-Bypass: <reason>" >&2
echo "──────────────────────────────────────────────────────────────────────" >&2

exit 1
