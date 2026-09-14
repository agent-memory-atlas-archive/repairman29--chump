#!/usr/bin/env bash
# gap-store-prototype.sh — INFRA-022 proof-of-concept for per-gap-file store.
#
# Operates on docs/gaps/INFRA/ alongside the existing docs/gaps.yaml.
# Fully additive — does NOT modify or remove docs/gaps.yaml.
#
# Commands:
#   init          Extract INFRA gaps from docs/gaps.yaml into docs/gaps/INFRA/
#   scaffold <title>  Reserve next INFRA ID + write template file
#   list [--open|--done]  List INFRA gaps
#   get <ID>      Print a gap file
#   done <ID>     Mark a gap done (sets status: done + closed_date)
#   search <term> Grep across all INFRA gap files
#
# ID reservation uses Python fcntl.flock (cross-platform: macOS + Linux).
# bash flock(1) is Linux-only; this script avoids it.
#
# Usage:
#   scripts/coord/gap-store-prototype.sh init
#   scripts/coord/gap-store-prototype.sh scaffold "Fix log rotation in ambient stream"
#   scripts/coord/gap-store-prototype.sh list --open
#   scripts/coord/gap-store-prototype.sh get INFRA-022
#   scripts/coord/gap-store-prototype.sh done INFRA-023
#   scripts/coord/gap-store-prototype.sh search "merge conflict"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/common.sh
# In linked worktrees, git rev-parse --show-toplevel returns the main worktree.
# We use the main repo root (REPO_ROOT, from common.sh) for shared state
# (.chump/, docs/gaps/) and the script's parent directory for the local
# worktree's gaps.yaml.
source "$SCRIPT_DIR/../lib/common.sh"
WT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GAPS_DIR="$REPO_ROOT/docs/gaps"
DOMAIN_DIR="$GAPS_DIR/INFRA"
COUNTER_DIR="$REPO_ROOT/.chump/id-counters"
LOCK_FILE="$COUNTER_DIR/.lock"
COUNTER_FILE="$COUNTER_DIR/INFRA"
# Use the local worktree's gaps.yaml if it exists; fall back to main repo's.
GAPS_YAML="$WT_ROOT/docs/gaps.yaml"
[[ -f "$GAPS_YAML" ]] || GAPS_YAML="$REPO_ROOT/docs/gaps.yaml"

# ── Helpers ────────────────────────────────────────────────────────────────────
# die() comes from common.sh (sourced above).
info()  { echo "  $*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }

ensure_dirs() {
    mkdir -p "$DOMAIN_DIR" "$COUNTER_DIR"
    touch "$LOCK_FILE"
}

# ── ID reservation ─────────────────────────────────────────────────────────────
# Returns the next INFRA-NNN via Python's fcntl.flock (cross-platform; works on
# macOS and Linux; flock(1) CLI is Linux-only).
reserve_id() {
    ensure_dirs
    python3 - "$COUNTER_FILE" "$LOCK_FILE" "$GAPS_YAML" <<'PYEOF'
import sys, os, fcntl, re

counter_file, lock_file, gaps_yaml = sys.argv[1], sys.argv[2], sys.argv[3]

def bootstrap_n():
    """Scan gaps.yaml for highest INFRA-NNN to seed the counter."""
    try:
        import yaml
        with open(gaps_yaml) as f:
            data = yaml.safe_load(f)
        nums = []
        for g in data.get('gaps', []):
            if isinstance(g, dict):
                m = re.match(r'INFRA-(\d+)$', g.get('id', ''))
                if m:
                    nums.append(int(m.group(1)))
        # Also scan existing files in DOMAIN_DIR.
        domain_dir = os.path.join(os.path.dirname(os.path.dirname(gaps_yaml)), 'docs', 'gaps', 'INFRA')
        if os.path.isdir(domain_dir):
            for fn in os.listdir(domain_dir):
                m2 = re.match(r'INFRA-(\d+)\.md$', fn)
                if m2:
                    nums.append(int(m2.group(1)))
        return max(nums, default=0) + 1
    except Exception:
        return 1

with open(lock_file, 'a') as lf:
    for attempt in range(5):
        try:
            fcntl.flock(lf.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except (BlockingIOError, OSError):
            import time; time.sleep(0.3)
    else:
        print("ERROR: Could not acquire ID lock", file=sys.stderr)
        sys.exit(1)

    n = 1
    if os.path.exists(counter_file):
        try:
            n = int(open(counter_file).read().strip()) + 1
        except (ValueError, OSError):
            n = bootstrap_n()
    else:
        n = bootstrap_n()

    with open(counter_file, 'w') as cf:
        cf.write(str(n))

print(f"INFRA-{n:03d}")
PYEOF
}

# ── init: extract INFRA gaps from gaps.yaml ─────────────────────────────────────
cmd_init() {
    ensure_dirs
    command -v python3 >/dev/null 2>&1 || die "python3 required for init"
    [[ -f "$GAPS_YAML" ]] || die "gaps.yaml not found at $GAPS_YAML"

    python3 - "$GAPS_YAML" "$DOMAIN_DIR" <<'PYEOF'
import yaml, sys, os, textwrap

gaps_yaml, domain_dir = sys.argv[1], sys.argv[2]
os.makedirs(domain_dir, exist_ok=True)

with open(gaps_yaml) as f:
    data = yaml.safe_load(f)

count = 0
for g in data.get('gaps', []):
    if not isinstance(g, dict):
        continue
    gid = g.get('id', '')
    if not gid.startswith('INFRA-'):
        continue
    out = os.path.join(domain_dir, f"{gid}.md")
    if os.path.exists(out):
        print(f"  skip (exists): {gid}")
        continue
    title = g.get('title', '').replace('"', '\\"')
    status = g.get('status', 'open')
    priority = g.get('priority', 'P2')
    effort = g.get('effort', 'm')
    closed_date = g.get('closed_date', '')
    desc = str(g.get('description', '')).strip()
    criteria = g.get('acceptance_criteria', [])

    lines = ['---', f'id: {gid}', f'title: "{title}"', 'domain: infra',
             f'priority: {priority}', f'effort: {effort}', f'status: {status}']
    if closed_date:
        lines.append(f"closed_date: '{closed_date}'")
    lines += ['---', '', f'# {title}', '']
    if desc:
        lines += ['## Description', '', textwrap.fill(desc, width=100), '']
    if criteria:
        lines += ['## Acceptance Criteria', '']
        for c in (criteria if isinstance(criteria, list) else [criteria]):
            if isinstance(c, dict):
                for k, v in c.items():
                    lines.append(f'- {k}: {v}')
            else:
                lines.append(f'- {c}')
        lines.append('')

    with open(out, 'w') as fh:
        fh.write('\n'.join(lines))
    print(f"  created: {gid}.md")
    count += 1

print(f"\nTotal: {count} INFRA gap files written to {domain_dir}")
PYEOF
}

# ── scaffold: reserve ID + write template ─────────────────────────────────────
cmd_scaffold() {
    local title="${1:-}"
    [[ -n "$title" ]] || die "Usage: $0 scaffold <title>"
    ensure_dirs
    local id
    id="$(reserve_id)"
    local out="$DOMAIN_DIR/${id}.md"
    {
        echo "---"
        echo "id: $id"
        printf 'title: "%s"\n' "${title//\"/\\\"}"
        echo "domain: infra"
        echo "priority: P2"
        echo "effort: m"
        echo "status: open"
        echo "---"
        echo ""
        echo "# $title"
        echo ""
        echo "## Description"
        echo ""
        echo "_TODO: describe the gap._"
        echo ""
        echo "## Acceptance Criteria"
        echo ""
        echo "- [ ] _TODO: add acceptance criteria_"
        echo ""
    } > "$out"
    green "Scaffolded: $out"
    echo "$id"
}

# ── list ────────────────────────────────────────────────────────────────────────
cmd_list() {
    local filter="${1:-}"
    if [[ ! -d "$DOMAIN_DIR" ]] || [[ -z "$(ls -A "$DOMAIN_DIR" 2>/dev/null)" ]]; then
        echo "No INFRA gaps yet. Run: $0 init"
        return
    fi
    local found=0
    for f in "$DOMAIN_DIR"/INFRA-*.md; do
        [[ -f "$f" ]] || continue
        local id status title
        id="$(basename "$f" .md)"
        status="$(grep -m1 '^status:' "$f" | awk '{print $2}' || echo '?')"
        title="$(grep -m1 '^title:' "$f" | sed 's/^title: *//; s/^"//; s/"$//' || echo '?')"
        if [[ -n "$filter" ]]; then
            [[ "$filter" == "--open" && "$status" != "open" ]] && continue
            [[ "$filter" == "--done" && "$status" != "done" ]] && continue
        fi
        printf '  [%-4s] %-14s %s\n' "$status" "$id" "${title:0:65}"
        found=1
    done
    [[ $found -eq 0 ]] && echo "  (no matching gaps)"
}

# ── get ────────────────────────────────────────────────────────────────────────
cmd_get() {
    local id="${1:-}"
    [[ -n "$id" ]] || die "Usage: $0 get <ID>"
    local f="$DOMAIN_DIR/${id}.md"
    [[ -f "$f" ]] || die "$f not found. Run '$0 init' first."
    cat "$f"
}

# ── done ───────────────────────────────────────────────────────────────────────
cmd_done() {
    local id="${1:-}"
    [[ -n "$id" ]] || die "Usage: $0 done <ID>"
    local f="$DOMAIN_DIR/${id}.md"
    [[ -f "$f" ]] || die "$f not found"
    python3 - "$f" "$(date +%Y-%m-%d)" <<'PYEOF'
import sys, re

path, today = sys.argv[1], sys.argv[2]
with open(path) as fh:
    content = fh.read()

content = re.sub(r'^status: \S+', 'status: done', content, flags=re.MULTILINE)
if 'closed_date:' in content:
    content = re.sub(r"^closed_date: .*$", f"closed_date: '{today}'", content, flags=re.MULTILINE)
else:
    content = re.sub(r'^(status: done)', f"\\1\nclosed_date: '{today}'", content, flags=re.MULTILINE)

with open(path, 'w') as fh:
    fh.write(content)
print(f"Marked done: {path} ({today})")
PYEOF
}

# ── search ──────────────────────────────────────────────────────────────────────
cmd_search() {
    local term="${1:-}"
    [[ -n "$term" ]] || die "Usage: $0 search <term>"
    [[ -d "$DOMAIN_DIR" ]] || die "Run '$0 init' first."
    if command -v rg >/dev/null 2>&1; then
        rg -i "$term" "$DOMAIN_DIR" --type md || echo "(no matches)"
    else
        grep -ril "$term" "$DOMAIN_DIR" || echo "(no matches)"
    fi
}

# ── Dispatch ───────────────────────────────────────────────────────────────────
cd "$REPO_ROOT"
CMD="${1:-}"
shift || true

case "$CMD" in
    init)     cmd_init ;;
    scaffold) cmd_scaffold "$@" ;;
    list)     cmd_list "$@" ;;
    get)      cmd_get "$@" ;;
    done)     cmd_done "$@" ;;
    search)   cmd_search "$@" ;;
    "")       echo "Usage: $0 {init|scaffold|list|get|done|search} [args]" >&2; exit 1 ;;
    *)        die "Unknown command: $CMD" ;;
esac
