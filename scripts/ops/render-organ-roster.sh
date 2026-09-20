#!/usr/bin/env bash
# scripts/ops/render-organ-roster.sh — INFRA-7767
#
# docs/strategy/ONE_COMMAND_INSTALL.md section 1 (one-command-install BOM
# unification, INFRA-7756): "One renderer per supervisor ... reads the SAME
# manifest and SAME role=/platforms= filter — this is what organ_unit_host_
# rewrite already half-does for systemd; slice A only unions the DATA, slice
# B teaches the renderer to also target --user scope and the other two
# supervisors." This is that renderer's slice-A shape: a small, read-only CLI
# over the shared organ-manifest-lib.sh parser that prints the roster
# APPLICABLE to a given platform/role, generated from the one unified
# scripts/ops/organ-manifest.txt — the same filter organ-reconcile.sh applies
# inline (INFRA-7764), exposed as a standalone utility so a future slice-B
# launchd/runit renderer (or a human auditing the roster) doesn't have to
# re-derive the filter logic or spin up organ-reconcile.sh itself.
#
# Usage:
#   render-organ-roster.sh [--platform systemd|launchd|runit] [--role ROLE] [--manifest PATH]
#
#   --platform   Filter to organs applicable to this platform (default: this
#                host's detected platform, via organ_current_platform).
#   --role       Further filter to a comma-separated role= list (e.g.
#                brain,data). Default: no role filtering (every role).
#   --manifest   Manifest path (default: scripts/ops/organ-manifest.txt next
#                to this script's repo root).
#
# Output: one line per applicable organ, "<unit>  role=<role>  platforms=<platforms>  requires=<requires>".
# Exit 0 always (a manifest with zero matches is not an error — it's an
# empty roster, e.g. `--platform runit` today).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/organ-manifest-lib.sh
source "$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"

MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
PLATFORM=""
ROLE_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) PLATFORM="$2"; shift 2 ;;
    --role) ROLE_FILTER="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$PLATFORM" ]] && PLATFORM="$(organ_current_platform)"

PAGING_OFF=(); ENABLED=()
declare -A ORGAN_ROLE
declare -A ORGAN_REQUIRES
declare -A ORGAN_PLATFORMS
organ_manifest_parse "$MANIFEST" PAGING_OFF ENABLED ORGAN_ROLE ORGAN_REQUIRES ORGAN_PLATFORMS || exit 1

declare -a role_toks=()
if [[ -n "$ROLE_FILTER" ]]; then
  IFS=',' read -ra role_toks <<< "$ROLE_FILTER"
fi

for unit in "${ENABLED[@]}"; do
  organ_platform_matches "${ORGAN_PLATFORMS[$unit]:-}" "$PLATFORM" || continue
  role="${ORGAN_ROLE[$unit]:-brain}"
  if [[ ${#role_toks[@]} -gt 0 ]]; then
    match=0
    for r in "${role_toks[@]}"; do [[ "$r" == "$role" ]] && { match=1; break; }; done
    [[ "$match" == 1 ]] || continue
  fi
  printf '%s  role=%s  platforms=%s  requires=%s\n' \
    "$unit" "$role" "${ORGAN_PLATFORMS[$unit]:-systemd}" "${ORGAN_REQUIRES[$unit]:-}"
done
