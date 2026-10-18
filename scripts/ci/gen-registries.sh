#!/usr/bin/env bash
# RESILIENT-1618: generator for the append-only registries that no longer need a
# merge driver. GitHub's server-side merge (mergeability, update-branch, the
# merge itself) never runs the local merge=union driver, so two PRs that each
# append one entry to EVENT_REGISTRY.yaml / env-vars-internal.txt always
# conflict after the first lands. The fix: new entries land as a NEW file under
# docs/observability/events.d/ or scripts/ci/env-vars.d/ (new files never
# collide on GitHub). This generator produces the COMPLETE view consumers read:
# the frozen monolith base + every fragment, deterministically sorted.
#
# Usage:
#   scripts/ci/gen-registries.sh events     # prints EVENT_REGISTRY base + fragments
#   scripts/ci/gen-registries.sh env-vars   # prints env-vars-internal base + fragments
#
# Pure glue (cat + find + sort); no state mutation. The validity/freshness
# invariant lives in scripts/ci/test-registry-fragments.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

emit_fragments() {
  # $1 = fragment dir, $2 = find name-glob (e.g. '*.yaml' or '*')
  local dir="$1" glob="$2" f bn
  [[ -d "$dir" ]] || return 0
  # Deterministic order so the generated output is reproducible across hosts.
  while IFS= read -r f; do
    bn="$(basename "$f")"
    case "$bn" in
      .gitkeep | README.md) continue ;;
    esac
    cat "$f"
  done < <(find "$dir" -maxdepth 1 -type f -name "$glob" | LC_ALL=C sort)
}

case "${1:-}" in
  events)
    cat "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
    emit_fragments "$REPO_ROOT/docs/observability/events.d" '*.yaml'
    ;;
  env-vars)
    cat "$REPO_ROOT/scripts/ci/env-vars-internal.txt"
    emit_fragments "$REPO_ROOT/scripts/ci/env-vars.d" '*'
    ;;
  *)
    echo "usage: gen-registries.sh events|env-vars" >&2
    exit 2
    ;;
esac
