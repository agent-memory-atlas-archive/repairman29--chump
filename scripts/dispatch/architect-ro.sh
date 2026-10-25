#!/usr/bin/env bash
# architect-ro.sh — RESILIENT-1634 (PHASE-R): the architect tick's vetted
# read-only probe.
#
# The headless architect tick (scripts/dispatch/architect-tick.sh) must not hold
# raw `git log*`, `git fetch*` or `sqlite3*` in its claude allowlist: `git fetch
# --upload-pack=` and `git -c` execute commands, `git log --output=` writes
# files, and sqlite3's `.shell` / `.system` / `-cmd` execute commands and an
# UPDATE rewrites state.db. This wrapper is the ONLY way the tick reaches git
# history and the GitHub cache: every subcommand runs one FIXED command line,
# the only caller-supplied values are a validated integer (PR number, hours),
# sqlite3 runs with -readonly and a fixed SQL string (no dot-commands, no
# -cmd), and git runs with no caller-supplied flags at all.
#
# Subcommands (anything else, or any extra argument, exits 2):
#   ship-log <hours>   origin/main commits in the last <hours> (1-168), one line each
#   trunk-head         origin/main tip: sha, commit time, subject
#   fetch              git fetch origin main (bounded at 120 s)
#   open-prs           open PRs from .chump/github_cache.db (number, state, armed, draft, title)
#   pr-checks <n>      cached check runs for PR <n>'s head sha
#   cache-age          newest fetched_at_local in the GitHub cache
set -uo pipefail

# CREDIBLE-1585: scrub non-allowlisted cloud/DB secrets at entry.
unset SUPABASE_SERVICE_ROLE_KEY POSTGRES_PASSWORD AWS_SECRET_ACCESS_KEY STRIPE_SECRET_KEY CHUMP_SUBSTRATE_DB_PASSWORD
while IFS='=' read -r _ro_k _; do
    case "$_ro_k" in
        OCI_*|*PASSWORD*|*SERVICE_ROLE*|*SECRET*) unset "$_ro_k" 2>/dev/null || true ;;
    esac
done < <(env)
unset _ro_k

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
cd "$REPO_ROOT" || exit 1
DB="$REPO_ROOT/.chump/github_cache.db"

die() { echo "architect-ro: $*" >&2; exit 2; }

bounded() { # <secs> cmd... — run under timeout when available
    local s="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "${s}s" "$@"; else "$@"; fi
}

ro_sql() { # <fixed sql> — read-only, batch, no dot-commands, no -cmd
    [[ -r "$DB" ]] || { echo "architect-ro: no GitHub cache at $DB" >&2; exit 1; }
    sqlite3 -init /dev/null -readonly -batch -separator '	' "$DB" "$1"
}

sub="${1:-}"
case "$sub" in
    ship-log)
        (( $# == 2 )) || die "usage: ship-log <hours>"
        [[ "$2" =~ ^[0-9]{1,3}$ ]] && (( 10#$2 >= 1 && 10#$2 <= 168 )) || die "hours must be 1-168"
        git --no-pager log origin/main --since="$((10#$2)) hours ago" --format='%h %cI %s' -n 300
        ;;
    trunk-head)
        (( $# == 1 )) || die "usage: trunk-head"
        git --no-pager log -1 --format='%H %cI %s' origin/main
        ;;
    fetch)
        (( $# == 1 )) || die "usage: fetch"
        bounded 120 git fetch origin main -q
        ;;
    open-prs)
        (( $# == 1 )) || die "usage: open-prs"
        ro_sql "SELECT number, COALESCE(mergeable_state,''), auto_merge_enabled, draft, COALESCE(updated_at_api,''), substr(COALESCE(title,''),1,100) FROM pr_state WHERE merged_at IS NULL ORDER BY number DESC LIMIT 200;"
        ;;
    pr-checks)
        (( $# == 2 )) || die "usage: pr-checks <pr-number>"
        [[ "$2" =~ ^[0-9]{1,7}$ ]] || die "pr-number must be an integer"
        ro_sql "SELECT c.name, COALESCE(c.status,''), COALESCE(c.conclusion,''), COALESCE(c.completed_at,'') FROM check_runs c JOIN pr_state p ON c.head_sha = p.head_sha WHERE p.number = $((10#$2)) ORDER BY c.name;"
        ;;
    cache-age)
        (( $# == 1 )) || die "usage: cache-age"
        ro_sql "SELECT MAX(fetched_at_local) FROM pr_state;"
        ;;
    help|-h|--help)
        sed -n '2,21p' "$0"
        ;;
    *)
        die "unknown subcommand '${sub}' (ship-log|trunk-head|fetch|open-prs|pr-checks|cache-age)"
        ;;
esac
