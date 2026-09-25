#!/usr/bin/env bash
# scripts/coord/capability.sh — unified register/query CLI for session
# capability manifests (INFRA-5765, INFRA-1862 slice).
#
# Thin front door over the existing file-backed capability primitives
# (publish-capability.sh / capability-lookup.sh) so a session can register
# its role + skill list and other sessions can query "who can do X" without
# needing to know which underlying script owns which half of the flow.
#
# Usage:
#   scripts/coord/capability.sh register --role <role> --skills a,b,c [--session <id>]
#   scripts/coord/capability.sh query --skill <skill> [--role <role>]
#
# register: writes .chump-locks/capabilities/<session>.json (last-write-wins,
#           advisory metadata — no lease needed).
# query:    prints matching session IDs (tab-separated with role), most
#           recently-updated first. Manifests older than
#           CHUMP_CAPABILITY_STALE_MIN (default 60 min) are excluded
#           automatically.
#
# Exit codes:
#   register: 0 success, 1 usage error
#   query:    0 at least one match, 1 no match / usage error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    register)
        shift
        exec "$SCRIPT_DIR/publish-capability.sh" "$@"
        ;;
    query)
        shift
        exec "$SCRIPT_DIR/capability-lookup.sh" "$@"
        ;;
    -h|--help|"")
        usage
        exit 0
        ;;
    *)
        echo "capability.sh: unknown command '$1' (want register|query)" >&2
        usage >&2
        exit 1
        ;;
esac
