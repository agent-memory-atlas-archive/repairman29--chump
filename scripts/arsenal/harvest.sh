#!/usr/bin/env bash
# scripts/arsenal/harvest.sh — Chump Fleet Cartographer CLI (harness-neutral)
#
# This is the canonical Harvester surface. Any harness (Claude Code,
# opencode-bigpickle, codex, manual) invokes it the same way. The .claude/
# agent + skill wrappers, AND `chump harvest` (src/harvester_cli.rs,
# INFRA-1823), all delegate here; they are convenience/validation fronts,
# not a second implementation of the catalog logic. Prefer `chump harvest`
# for interactive use (it validates args and gives consistent exit codes);
# this script is the shared engine underneath.
#
# Rust-First-Bypass: glue between gh + jq + python3 build.py, < 200 LOC,
# read-mostly (only writes to docs/arsenal/* which is regenerable from
# inputs). INFRA-1823 wraps this in `chump harvest` rather than porting the
# jq catalog logic to Rust — duplicating it would create two sources of
# truth for what counts as an "overlap".
#
# Usage:
#   scripts/arsenal/harvest.sh <subcommand> [args]
#
# Subcommands:
#   scan                   Refresh GLOBAL_ARSENAL.json from `gh repo list`.
#   check <topic>          Print arsenal overlap with a topic — primitives index
#                          match + cluster keyword scan. Exit 0 if matches found,
#                          exit 1 if none.
#   brief <src> <target>   Scaffold a Cross-Pollination Brief (CP-NNN).
#   deep-scan <cluster>    List repos in cluster with health metadata.
#   list-clusters          Print all known cluster names + repo counts.
#   help                   Print this.
#
# Exit codes:
#   0 — success or matches found
#   1 — no matches (for `check`) / missing required arg
#   2 — bad subcommand
#   3 — catalog missing or unreadable (run `scan` first)
#
# Examples:
#   scripts/arsenal/harvest.sh scan
#   scripts/arsenal/harvest.sh check auth
#   scripts/arsenal/harvest.sh check INFRA-1486
#   scripts/arsenal/harvest.sh brief echo-chamber operator-ui-lists
#   scripts/arsenal/harvest.sh deep-scan game-services

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_PY="$ROOT/scripts/arsenal/build.py"
# Two catalogs. This repo is PUBLIC, so docs/arsenal/ holds PUBLIC repos only and no local paths.
# The operator's full catalog (private repos, local clones, cross-pollination briefs, curation)
# lives in PRIVATE_ARSENAL, outside every git tree. `scan` builds both. Every read-side command
# (check, brief, deep-scan) uses the private catalog when it exists and the public one otherwise,
# so a fresh clone still works, against less.
PUBLIC_ARSENAL="$ROOT/docs/arsenal"
PRIVATE_ARSENAL="${CHUMP_ARSENAL_DIR:-$HOME/.chump/arsenal}"
if [ -f "$PRIVATE_ARSENAL/GLOBAL_ARSENAL.json" ] || [ "${1:-}" = "scan" ]; then
  ARSENAL="$PRIVATE_ARSENAL"
else
  ARSENAL="$PUBLIC_ARSENAL"
fi
RAW="$ARSENAL/raw/github_repos.json"
CATALOG="$ARSENAL/GLOBAL_ARSENAL.json"
CP_DIR="$ARSENAL/cross-pollination"

cmd=${1:-help}
[ $# -gt 0 ] && shift || true

require_catalog() {
  if [ ! -f "$CATALOG" ]; then
    echo "harvest: catalog missing at $CATALOG — run 'harvest.sh scan' first" >&2
    exit 3
  fi
}

case "$cmd" in
  scan)
    mkdir -p "$(dirname "$RAW")"; chmod 700 "$ARSENAL" 2>/dev/null || true
    echo "→ refreshing $RAW from gh repo list" >&2
    gh repo list --limit 200 --json name,description,primaryLanguage,visibility,pushedAt,isArchived,isFork,sshUrl,url,createdAt,updatedAt,diskUsage,repositoryTopics > "$RAW.tmp"
    # Operator exclude list. This catalog is committed to a PUBLIC repo, and `gh repo list`
    # returns private repos with their names and descriptions. Names listed in the exclude file
    # never reach $RAW or anything built from it. The file lives OUTSIDE this tree on purpose: a
    # list of what is being kept out of a public repo is itself revealing. One repo name per
    # line, case-insensitive, `#` comments allowed. Fails closed: if the file exists and the
    # filter cannot run, nothing is written.
    EXCLUDE_FILE=${CHUMP_ARSENAL_EXCLUDE_FILE:-$HOME/.chump/arsenal-exclude.txt}
    if [ -s "$EXCLUDE_FILE" ]; then
      if ! jq -c --rawfile ex "$EXCLUDE_FILE" '
            ($ex | split("\n") | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase)
                 | map(select(length > 0 and (startswith("#") | not)))) as $x
            | map(select((.name | ascii_downcase) as $n | ($x | index($n)) == null))' "$RAW.tmp" > "$RAW.filtered"; then
        rm -f "$RAW.tmp" "$RAW.filtered"
        echo "harvest scan: exclude filter failed; refusing to write an unfiltered catalog" >&2
        exit 4
      fi
      echo "→ exclude list applied: $(( $(jq length "$RAW.tmp") - $(jq length "$RAW.filtered") )) repo(s) withheld" >&2
      mv "$RAW.filtered" "$RAW"; rm -f "$RAW.tmp"
    else
      mv "$RAW.tmp" "$RAW"
    fi
    echo "→ rebuilding the operator catalog in $ARSENAL" >&2
    CHUMP_ARSENAL_DIR="$ARSENAL" CHUMP_ARSENAL_PUBLIC_ONLY=0 python3 "$BUILD_PY"
    # The committed catalog: PUBLIC repos only, filtered BEFORE it is written, no local paths.
    mkdir -p "$PUBLIC_ARSENAL/raw"
    jq -c 'map(select((.visibility // "") | ascii_upcase == "PUBLIC"))' "$RAW" > "$PUBLIC_ARSENAL/raw/github_repos.json.tmp" \
      && mv "$PUBLIC_ARSENAL/raw/github_repos.json.tmp" "$PUBLIC_ARSENAL/raw/github_repos.json" \
      || { rm -f "$PUBLIC_ARSENAL/raw/github_repos.json.tmp"; echo "harvest scan: public filter failed; public catalog left untouched" >&2; exit 4; }
    echo "→ rebuilding the public catalog in $PUBLIC_ARSENAL ($(jq length "$PUBLIC_ARSENAL/raw/github_repos.json") public repo(s))" >&2
    CHUMP_ARSENAL_DIR="$PUBLIC_ARSENAL" CHUMP_ARSENAL_PUBLIC_ONLY=1 python3 "$BUILD_PY"
    # The public catalog carries no alerts by design, so the high-severity signal (an embedded
    # token in a clone's remote, INFRA-6616) has to be raised from the operator catalog here.
    high=$(jq '[.alerts[]? | select(.severity == "high")] | length' "$CATALOG" 2>/dev/null || echo 0)
    if [ "${high:-0}" -gt 0 ]; then
      echo "harvest scan: $high high-severity alert(s) in the operator catalog; see .alerts in $CATALOG" >&2
      exit 5
    fi
    ;;

  check)
    require_catalog
    topic=${1:-}
    if [ -z "$topic" ]; then
      echo "harvest check: topic required (a gap ID, a primitive name, or a free-form keyword)" >&2
      exit 1
    fi
    found=0
    echo "=== primitives_index match for '$topic' ==="
    if matches=$(jq -r --arg t "$topic" '
      .primitives_index
      | to_entries
      | map(select(.key | ascii_downcase | contains($t | ascii_downcase)))
      | .[] | "  \(.key) → \(.value | join(", "))"
    ' "$CATALOG"); then
      [ -n "$matches" ] && { echo "$matches"; found=1; }
    fi
    echo
    echo "=== cluster keyword match for '$topic' ==="
    if matches=$(jq -r --arg t "$topic" '
      .clusters | to_entries
      | map(select(
          (.key | ascii_downcase | contains($t | ascii_downcase))
          or (.value.repos | join(" ") | ascii_downcase | contains($t | ascii_downcase))
        ))
      | .[] | "  cluster \(.key) (\(.value.count) repos): \(.value.repos | join(", "))"
    ' "$CATALOG"); then
      [ -n "$matches" ] && { echo "$matches"; found=1; }
    fi
    echo
    echo "=== extracted_primitives (per-file, line-refd) match for '$topic' ==="
    if matches=$(jq -r --arg t "$topic" '
      .repos_by_name | to_entries
      | map(select(
          (.value.extracted_primitives_by_file // [])
          | any(.primitive == $t or (.file | ascii_downcase | contains($t | ascii_downcase)))
        ))
      | .[] | .key as $repo
      | (.value.extracted_primitives_by_file // [])
      | map(select(.primitive == $t or (.file | ascii_downcase | contains($t | ascii_downcase))))
      | .[] | "  \($repo)/\(.file):\(.line) — \(.primitive) (\(.match))"
    ' "$CATALOG"); then
      [ -n "$matches" ] && { echo "$matches"; found=1; }
    fi
    echo
    echo "=== repo-description match for '$topic' ==="
    if matches=$(jq -r --arg t "$topic" '
      .repos_by_name | to_entries
      | map(select(.value.description // "" | ascii_downcase | contains($t | ascii_downcase)))
      | .[] | "  \(.key): \(.value.description)"
    ' "$CATALOG"); then
      [ -n "$matches" ] && { echo "$matches"; found=1; }
    fi
    echo
    echo "=== HARVEST_ROADMAP.md mention of '$topic' (deep-scan findings) ==="
    roadmap="$ARSENAL/HARVEST_ROADMAP.md"
    if [ -f "$roadmap" ]; then
      if matches=$(grep -inE "$topic" "$roadmap" 2>/dev/null | head -10); then
        [ -n "$matches" ] && { echo "$matches" | sed 's/^/  /'; found=1; }
      fi
    fi
    echo
    echo "=== cross-pollination briefs mentioning '$topic' ==="
    if [ -d "$CP_DIR" ] && ls "$CP_DIR"/*.md >/dev/null 2>&1; then
      if matches=$(grep -ilE "$topic" "$CP_DIR"/*.md 2>/dev/null); then
        [ -n "$matches" ] && { echo "$matches" | sed 's|^|  |'; found=1; }
      fi
    fi
    if [ $found -eq 0 ]; then
      echo "no arsenal overlap found for '$topic'" >&2
      exit 1
    fi
    ;;

  brief)
    require_catalog
    src=${1:-}
    target=${2:-}
    if [ -z "$src" ] || [ -z "$target" ]; then
      echo "harvest brief: source repo and target need required" >&2
      echo "  example: harvest.sh brief billing-service stripe-billing-for-marketplace" >&2
      exit 1
    fi
    mkdir -p "$CP_DIR"
    last_cp=$(ls "$CP_DIR" 2>/dev/null | grep -oE '^CP-[0-9]+' | sort -V | tail -1 | grep -oE '[0-9]+' || echo "000")
    next_cp=$(printf "%03d" $((10#$last_cp + 1)))
    slug=$(echo "${src}-into-${target}" | tr 'A-Z _' 'a-z--' | tr -cd 'a-z0-9-')
    out="$CP_DIR/CP-${next_cp}-${slug}.md"
    cat > "$out" <<EOF
# CP-${next_cp}: ${src} into ${target}

**Target need:** ${target}
**Arsenal match:** \`repairman29/${src}\`
**Recommended route:** TODO — Dependency / Microservice / Vendoring
**Status:** proposed ($(date -u +%Y-%m-%d))

## The Target

TODO — what Chump needs, with file paths and the missing capability.

## The Arsenal Match

TODO — where this primitive already lives. Cite repo + file paths + last commit
+ why the existing implementation is mature enough to harvest.

## The Bridge Strategy

TODO — exact CLI commands, Cargo.toml lines, submodule commands, or service
URLs. A new engineer should be able to run this verbatim.

## Lineage / Risk

TODO — what could break. Version drift expectations. How to re-evaluate.
EOF
    echo "$out"
    ;;

  deep-scan)
    require_catalog
    cluster=${1:-}
    if [ -z "$cluster" ]; then
      echo "harvest deep-scan: cluster name required (use 'harvest.sh list-clusters' to see them)" >&2
      exit 1
    fi
    if ! jq -e --arg c "$cluster" '.clusters[$c]' "$CATALOG" > /dev/null; then
      echo "harvest deep-scan: cluster '$cluster' not found" >&2
      jq -r '.clusters | keys[]' "$CATALOG" | sed 's/^/  /' >&2
      exit 1
    fi
    jq -r --arg c "$cluster" '
      .clusters[$c].repos[] as $name
      | .repos_by_name[$name]
      | "\(.name):
    description: \(.description // "(none)")
    language:    \(.language // "?")
    pushed_at:   \(.pushed_at)
    archived:    \(.archived)
    local_clone: \(.local_clone.path // "(none)")
    primitives:  \(.primitives | join(", "))
"
    ' "$CATALOG"
    ;;

  list-clusters)
    require_catalog
    jq -r '.clusters | to_entries | map("\(.key) (\(.value.count) repos, \(.value.active_last_30d) active in 30d)") | .[]' "$CATALOG"
    ;;

  help|--help|-h)
    sed -n '/^# Usage:/,/^# Examples:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;

  *)
    echo "harvest: unknown subcommand '$cmd'" >&2
    echo "run 'harvest.sh help' for usage" >&2
    exit 2
    ;;
esac
