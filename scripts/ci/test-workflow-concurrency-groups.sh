#!/usr/bin/env bash
# scripts/ci/test-workflow-concurrency-groups.sh — ZERO-WASTE-135
#
# Every workflow triggered by `workflow_run` or `schedule` must declare a
# top-level `concurrency:` block with a STABLE group key. A key that varies per
# run (github.run_id, run_number, run_attempt, workflow_run.id,
# workflow_run.head_sha) never dedupes: during a hosted-runner stall each
# upstream completion queues its own run (measured 2026-10-17 14:25Z: 14 queued
# verified-recompute runs on main, 3 pr-triage-bot, 2 CI Flake Rerun).
#
# Depth: static/structural only (smoke + adversarial self-check of the checker
# against synthetic good/bad fixtures). It does NOT prove the key is the RIGHT
# stable key, nor that cancel-in-progress is semantically safe for a given
# workflow; that is a per-workflow review call recorded in the PR that sets it.
#
# Exemptions: scripts/ci/workflow-concurrency-allowlist.txt (shrink-only; a stale
# entry for a workflow that now complies is itself a failure).
#
# Usage: test-workflow-concurrency-groups.sh [WORKFLOW_DIR] [ALLOWLIST_FILE]
#        (args exist so the self-check can point at synthetic fixtures)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BAD_KEY_RE='run_id|run_number|run_attempt|workflow_run\.id|workflow_run\.head_sha'

# Prints the lines of the top-level block starting at "^<key>:" (inclusive),
# until the next top-level key.
top_block() { # file key
    awk -v k="$2" '
        $0 ~ "^\"?" k "\"?:" { f=1; print; next }
        f && /^[A-Za-z"]/ { f=0 }
        f { print }
    ' "$1"
}

# 0 if the workflow is triggered by workflow_run or schedule.
is_target() { # file
    # Inline forms: on: [schedule] / on: schedule / on: {schedule: ...}
    if grep -qE '^"?on"?:.*\b(workflow_run|schedule)\b' "$1"; then return 0; fi
    top_block "$1" on | grep -vE '^\s*#' | grep -qE '^\s+(workflow_run|schedule)\s*:'
}

# Echoes "ok" or a failure reason for one workflow file.
check_one() { # file
    local blk
    blk="$(top_block "$1" concurrency)"
    if [ -z "$blk" ]; then echo "no top-level concurrency: block"; return; fi
    # Inline scalar form `concurrency: some-group` has no group:/cancel lines to check.
    local group
    group="$(printf '%s\n' "$blk" | grep -vE '^\s*#' | grep -E '^\s+group\s*:|^concurrency:\s*\S' | head -1)"
    if [ -z "$group" ]; then echo "concurrency block has no group: key"; return; fi
    if printf '%s\n' "$group" | grep -qE "$BAD_KEY_RE"; then
        echo "group key varies per run (never dedupes): $(printf '%s' "$group" | sed 's/^[[:space:]]*//')"
        return
    fi
    echo ok
}

run_checks() { # wf_dir allowlist -> echoes FAIL lines, returns failure count
    local dir="$1" allow="$2" f name res fails=0 listed
    for f in "$dir"/*.yml; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        is_target "$f" || continue
        res="$(check_one "$f")"
        listed=0
        grep -qE "^${name//./\\.}([[:space:]]|$)" "$allow" 2>/dev/null && listed=1
        if [ "$res" = ok ]; then
            if [ "$listed" = 1 ]; then
                echo "FAIL $name: allowlisted but now compliant; delete its line from $(basename "$allow") (shrink-only)"
                fails=$((fails+1))
            else
                echo "PASS $name"
            fi
        elif [ "$listed" = 1 ]; then
            echo "SKIP $name: allowlisted ($res)"
        else
            echo "FAIL $name: $res"
            fails=$((fails+1))
        fi
    done
    return "$fails"
}

selfcheck() {
    local t; t="$(mktemp -d)"
    trap 'rm -rf "$t"' RETURN
    : > "$t/allow.txt"
    local good bad rc
    cat > "$t/good.yml" <<'Y'
on:
  workflow_run:
    workflows: [CI]
concurrency:
  group: good-${{ github.event.workflow_run.head_branch }}
  cancel-in-progress: true
jobs: {}
Y
    cat > "$t/runid.yml" <<'Y'
on:
  schedule:
    - cron: '0 6 * * *'
concurrency:
  group: x-${{ github.head_ref || github.run_id }}
  cancel-in-progress: true
jobs: {}
Y
    cat > "$t/upstream.yml" <<'Y'
on:
  workflow_run:
    workflows: [CI]
concurrency:
  group: x-${{ github.event.workflow_run.id }}
  cancel-in-progress: false
jobs: {}
Y
    cat > "$t/headsha.yml" <<'Y'
on:
  workflow_run:
    workflows: [CI]
concurrency:
  group: x-${{ github.event.workflow_run.head_sha }}
  cancel-in-progress: false
jobs: {}
Y
    cat > "$t/missing.yml" <<'Y'
on:
  schedule:
    - cron: '0 6 * * *'
jobs: {}
Y
    cat > "$t/notarget.yml" <<'Y'
on:
  push:
concurrency:
  group: x-${{ github.run_id }}
jobs: {}
Y
    cat > "$t/jobonly.yml" <<'Y'
on:
  schedule:
    - cron: '0 6 * * *'
jobs:
  a:
    concurrency:
      group: stable
Y
    run_checks "$t" "$t/allow.txt" > "$t/out.txt"; rc=$?
    local want=5 ok=1
    [ "$rc" = "$want" ] || { echo "selfcheck: expected $want failures, got $rc"; cat "$t/out.txt"; ok=0; }
    grep -q '^PASS good.yml' "$t/out.txt" || { echo "selfcheck: good.yml should pass"; ok=0; }
    grep -q 'notarget.yml' "$t/out.txt" && { echo "selfcheck: push-only workflow must be ignored"; ok=0; }
    for n in runid upstream headsha missing jobonly; do
        grep -q "^FAIL $n.yml" "$t/out.txt" || { echo "selfcheck: $n.yml should fail"; ok=0; }
    done
    # allowlist: a bad entry is skipped, a stale entry (compliant file) fails
    printf 'runid.yml # test\ngood.yml # stale\n' > "$t/allow.txt"
    run_checks "$t" "$t/allow.txt" > "$t/out2.txt"; rc=$?
    grep -q '^SKIP runid.yml' "$t/out2.txt" || { echo "selfcheck: allowlisted runid.yml should SKIP"; ok=0; }
    grep -q '^FAIL good.yml: allowlisted but now compliant' "$t/out2.txt" || { echo "selfcheck: stale allowlist entry should fail"; ok=0; }
    [ "$ok" = 1 ]
}

echo "=== ZERO-WASTE-135: workflow_run/schedule concurrency groups ==="
if ! selfcheck; then
    echo "FAIL: checker self-check failed (the test itself is broken)"
    exit 1
fi
echo "self-check ok (synthetic good/bad fixtures behave)"

WF_DIR="${1:-$REPO_ROOT/.github/workflows}"
ALLOW="${2:-$REPO_ROOT/scripts/ci/workflow-concurrency-allowlist.txt}"
run_checks "$WF_DIR" "$ALLOW"
fails=$?
echo
if [ "$fails" -ne 0 ]; then
    echo "=== $fails workflow(s) failed ==="
    echo "Fix: add/repair a top-level concurrency: block keyed per workflow + branch/PR"
    echo "(e.g. \${{ github.workflow }}-\${{ github.ref }}), never run_id/workflow_run.id/head_sha."
    exit 1
fi
echo "=== all workflow_run/schedule workflows have stable concurrency groups ==="
