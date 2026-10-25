#!/usr/bin/env bash
# vercel-resolve.sh — INFRA-8174: canonical Vercel project/domain resolver.
# Rust-Twin: src/main.rs
#
# Resolves a repo slug, project name, alias, or domain against the verified
# registry in config/vercel-targets.json and (when VERCEL_TOKEN is available
# and CHUMP_VERCEL_RESOLVE_OFFLINE is unset) live https://api.vercel.com/v9/projects.
#
# NEVER guesses `<repo>.vercel.app`. Exits 1 with resolution instructions on
# stderr if a target cannot be verified. Never prints VERCEL_TOKEN.
#
# Usage:
#   scripts/ops/vercel-resolve.sh [--json] <repo-or-alias-or-domain>
set -uo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
TARGETS_FILE="${CHUMP_VERCEL_TARGETS_FILE:-$REPO_ROOT/config/vercel-targets.json}"

JSON_MODE=0
QUERY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--json] <repo-or-alias-or-domain>"
      exit 0
      ;;
    *)
      if [[ -z "$QUERY" ]]; then
        QUERY="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  echo "[vercel-resolve] ERROR: missing target argument. Usage: scripts/ops/vercel-resolve.sh [--json] <repo-or-alias-or-domain>" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "[vercel-resolve] ERROR: jq is required" >&2
  exit 1
}

# Normalize query: strip scheme and trailing slash, lowercase for comparison.
NORM_QUERY="$(printf '%s' "$QUERY" | sed -E 's#^https?://##; s#/+$##' | tr '[:upper:]' '[:lower:]')"

RESOLVED_JSON=""
if [[ -f "$TARGETS_FILE" ]]; then
  RESOLVED_JSON="$(jq -c --arg q "$NORM_QUERY" '
    (.targets // [])
    | map(select(
        ((.project_id // "") | ascii_downcase) == $q or
        ((.project_name // "") | ascii_downcase) == $q or
        ((.repo // "") | ascii_downcase) == $q or
        ((.prod_domain // "") | ascii_downcase) == $q or
        ((.prod_alias // "") | ascii_downcase) == $q or
        ((.aliases // []) | map(ascii_downcase) | index($q) != null)
      ))
    | .[0] // empty
    | if . == null then empty else {
        project_id: .project_id,
        project_name: .project_name,
        repo: .repo,
        prod_domain: .prod_domain,
        prod_alias: .prod_alias
      } end
  ' "$TARGETS_FILE" 2>/dev/null || true)"
fi

# Optional live verification / enrichment via Vercel API when VERCEL_TOKEN is available
# and CHUMP_VERCEL_RESOLVE_OFFLINE is not set. Never print VERCEL_TOKEN.
if [[ -z "${CHUMP_VERCEL_RESOLVE_OFFLINE:-}" ]]; then
  if [[ -z "${VERCEL_TOKEN:-}" && -f "$HOME/.chump/providers.env" ]]; then
    VERCEL_TOKEN="$(grep -E '^VERCEL_TOKEN=' "$HOME/.chump/providers.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'\''' || true)"
  fi
  if [[ -n "${VERCEL_TOKEN:-}" ]] && command -v curl >/dev/null 2>&1; then
    API_URL="${CHUMP_VERCEL_API_URL:-https://api.vercel.com/v9/projects}"
    api_resp="$(curl -fsSL --max-time 8 -H "Authorization: Bearer ${VERCEL_TOKEN}" "$API_URL" 2>/dev/null || true)"
    if [[ -n "$api_resp" ]] && printf '%s' "$api_resp" | jq -e . >/dev/null 2>&1; then
      lookup_name="$NORM_QUERY"
      if [[ -n "$RESOLVED_JSON" ]]; then
        lookup_name="$(printf '%s' "$RESOLVED_JSON" | jq -r '.project_name | ascii_downcase')"
      fi
      api_match="$(printf '%s' "$api_resp" | jq -c --arg q "$NORM_QUERY" --arg ln "$lookup_name" '
        (.projects // [])
        | map(select(
            ((.name // "") | ascii_downcase) == $q or
            ((.name // "") | ascii_downcase) == $ln or
            ((.id // "") | ascii_downcase) == $q or
            (((.link.org // "") + "/" + (.link.repo // "")) | ascii_downcase) == $q
          ))
        | .[0] // empty
      ' 2>/dev/null || true)"
      if [[ -n "$api_match" ]]; then
        if [[ -n "$RESOLVED_JSON" ]]; then
          RESOLVED_JSON="$(jq -c -n --argjson base "$RESOLVED_JSON" --argjson api "$api_match" '
            $base + {
              project_id: ($api.id // $base.project_id),
              project_name: ($api.name // $base.project_name)
            }
          ')"
        else
          RESOLVED_JSON="$(printf '%s' "$api_match" | jq -c '{
            project_id: (.id // ""),
            project_name: (.name // ""),
            repo: (if (.link.org and .link.repo) then (.link.org + "/" + .link.repo) else "" end),
            prod_domain: ((.targets.production.alias // [])[0] // ((.name // "") + ".vercel.app")),
            prod_alias: ((.name // "") + ".vercel.app")
          }')"
        fi
      fi
    fi
  fi
fi

if [[ -z "$RESOLVED_JSON" ]]; then
  cat >&2 <<'EOF'
[vercel-resolve] ERROR: target could not be verified against config/vercel-targets.json or https://api.vercel.com/v9/projects.
[vercel-resolve] Resolution instructions:
  1. Query live Vercel projects: curl -sH "Authorization: Bearer $VERCEL_TOKEN" https://api.vercel.com/v9/projects | jq '.projects[] | {id, name, link, alias: .targets.production.alias}'
  2. Add the verified {project_id, project_name, repo, prod_domain, prod_alias, aliases} entry to config/vercel-targets.json.
  3. Never guess <repo>.vercel.app (e.g. repairman29/olive deploys to project 'cartpilot' / shopolive.xyz, not olive.vercel.app).
EOF
  exit 1
fi

if [[ "$JSON_MODE" -eq 1 ]]; then
  printf '%s\n' "$RESOLVED_JSON"
else
  printf '%s\n' "$RESOLVED_JSON"
fi
