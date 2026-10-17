#!/usr/bin/env bash
# scripts/ci/census.sh — CREDIBLE-1514: the scripts/ci test census.
#
# WHY: scripts/ci holds ~1,611 test-*.sh files and the workflows plus
# `chump preflight` reference ~390 of them (ci.yml alone ~190). Nothing runs
# the rest, so they rot: on 2026-10-17 four agents found 40+ tests red on
# untouched origin/main (6 fixed in #5535, 6 in #5542, 28 of 169 in #5548).
# Every agent that touches a script trips over 5-30 of them. The census runs
# every test, publishes who is wired and who is red, and the shrink-only gate
# (scripts/ci/test-census-shrink-only.sh) keeps both lists from growing.
#
# USAGE
#   scripts/ci/census.sh                    run every test, write the docs
#   scripts/ci/census.sh --no-run           classification only (fast); keeps
#                                           the previous run's statuses
#   scripts/ci/census.sh --sample N         run N tests (deterministic spread)
#   scripts/ci/census.sh --only 'GLOB'      run tests whose basename matches
#   scripts/ci/census.sh --wired-only | --unwired-only
#   scripts/ci/census.sh --write            let a partial run (sample/only/
#                                           wired-only/unwired-only) merge into
#                                           docs/observability (default: tempdir)
#   scripts/ci/census.sh --out-dir DIR      write the md + json into DIR
#   scripts/ci/census.sh --known-red FILE   (with --no-run) mark the basenames
#                                           in FILE red; "name<TAB>source" lines
#   scripts/ci/census.sh --check-shrink BASE.json [--head-json HEAD.json]
#                                           shrink-only compare, exit 1 on growth
#
# OUTPUTS (and the only places this script writes)
#   docs/observability/CI_TEST_CENSUS.md      four lists + counts + run date
#   docs/observability/ci-test-census.json    the same, for machines (kpi, gate)
#   a mktemp sandbox (removed on exit unless CHUMP_CENSUS_KEEP_SANDBOX=1)
#
# SANDBOX: every test runs with HOME, CHUMP_HOME, CHUMP_STATE_DB (a copy of a
# fixture db), CHUMP_AMBIENT_LOG, CHUMP_LOCK_DIR, TMPDIR and GIT_CONFIG_GLOBAL
# pointed into its own sandbox dir, so a test cannot append to the real
# ambient log or touch ~/.chump (several did on 2026-10-17). CARGO_HOME and
# RUSTUP_HOME are pinned to the caller's real ones so cargo still resolves.
#
# CLASSIFICATION: a test is WIRED when its basename appears on a non-comment
# line of .github/workflows/*.yml (top level only; GitHub does not run
# subdirectories) or crates/chump-preflight/src/preflight.rs. Indirect wiring
# (a wired script calling a sibling) is not followed.
#
# STATUS: pass (exit 0), fail (non-zero), timeout (exit 124/137 from
# timeout), skip (exit 77, or exit 0 with a SKIP/SKIPPED/SKIPPING line and no
# PASS/ok line). red = fail + timeout.
#
# ENV
#   CHUMP_CENSUS_TIMEOUT_S        per-test timeout, default 120
#   CHUMP_CENSUS_JOBS             parallel tests, default 4
#   CHUMP_CENSUS_ROOT             repo root override (fixture tests)
#   CHUMP_CENSUS_STATE_DB_FIXTURE state.db to copy per test (default
#                                 <root>/.chump/state.db, else an empty db)
#   CHUMP_CENSUS_KEEP_SANDBOX     1 = keep the sandbox and print its path
#   CHUMP_CENSUS_ALLOW_GROWTH     1 = --check-shrink reports growth, exits 0
#                                 (set by CI for the nightly census/* PR)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CHUMP_CENSUS_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TIMEOUT_S="${CHUMP_CENSUS_TIMEOUT_S:-120}"
JOBS="${CHUMP_CENSUS_JOBS:-4}"
PY="$SCRIPT_DIR/lib/census.py"

# ── internal: run one test inside its own sandbox (called via xargs) ───────
if [[ "${1:-}" == "--_run-one" ]]; then
    test_path="$2"; sandbox="$3"
    name="$(basename "$test_path")"
    d="$sandbox/runs/$name"
    mkdir -p "$d/home/.chump" "$d/locks" "$d/tmp"
    cp "$sandbox/state.db" "$d/state.db"
    # Same fleet-GO the CI fast-checks job sets (CREDIBLE-166): claim- and
    # bot-merge-exercising tests refuse at AUTONOMY_LEVEL 0/absent.
    echo 5 > "$d/home/.chump/AUTONOMY_LEVEL"
    printf '[user]\n\tname = chump-census\n\temail = census@chump.local\n' > "$d/gitconfig"
    start=$(date +%s)
    rc=0
    (
        cd "$ROOT"
        export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
        export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
        export HOME="$d/home" CHUMP_HOME="$d/home/.chump"
        export CHUMP_STATE_DB="$d/state.db" CHUMP_AMBIENT_LOG="$d/ambient.jsonl"
        export CHUMP_LOCK_DIR="$d/locks" TMPDIR="$d/tmp"
        export GIT_CONFIG_GLOBAL="$d/gitconfig" CHUMP_CENSUS_IN_PROGRESS=1
        # No live credentials inside a census test: nothing reaches GitHub or
        # a model API on the caller's behalf.
        unset GH_TOKEN GITHUB_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
        # Own session + process group per test, so a test (or a script it
        # drives) that does `kill 0` / kills its group cannot take down the
        # census, and a timeout kills the test's whole tree. perl because
        # macOS has no setsid(1); exit 124 on timeout like timeout(1).
        exec perl -MPOSIX -e '
            my $t = shift; my $pid = fork();
            die "fork: $!" unless defined $pid;
            if ($pid == 0) { POSIX::setsid(); exec @ARGV or exit 127; }
            local $SIG{ALRM} = sub {
                kill "TERM", -$pid; sleep 5; kill "KILL", -$pid;
                waitpid($pid, 0); exit 124;
            };
            alarm $t; waitpid($pid, 0); alarm 0;
            my $st = $?; kill "KILL", -$pid;
            exit(($st & 127) ? 128 + ($st & 127) : $st >> 8);
        ' "$TIMEOUT_S" bash "$test_path"
    ) </dev/null >"$d/out.log" 2>&1 || rc=$?
    dur=$(( $(date +%s) - start ))
    clean="$(sed $'s/\x1b\\[[0-9;]*m//g' "$d/out.log" 2>/dev/null || true)"
    status=fail
    if [[ $rc -eq 0 ]]; then
        status=pass
        if grep -Eq '^[[:space:]]*(\[[^]]*\][[:space:]]*)?\[?SKIP(PED|PING)?\b' <<<"$clean" \
            && ! grep -Eq '\bPASS(ED)?\b|✓|✔|^[[:space:]]*ok\b' <<<"$clean"; then
            status=skip
        fi
    elif [[ $rc -eq 77 ]]; then
        status=skip
    elif [[ $rc -eq 124 ]]; then
        status=timeout
    fi
    tail_line="$(grep -v '^[[:space:]]*$' <<<"$clean" | tail -1 | tr '\t' ' ' | cut -c1-200 || true)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$status" "$rc" "$dur" "$tail_line" \
        > "$sandbox/results/$name.tsv"
    exit 0
fi

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

SAMPLE=""; ONLY=""; FILTER=""; NO_RUN=0; WRITE=0; OUT_DIR=""; KNOWN_RED=""
CHECK_BASE=""; HEAD_JSON=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sample) SAMPLE="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --wired-only) FILTER=wired; shift ;;
        --unwired-only) FILTER=unwired; shift ;;
        --no-run) NO_RUN=1; shift ;;
        --write) WRITE=1; shift ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --known-red) KNOWN_RED="$2"; shift 2 ;;
        --check-shrink) CHECK_BASE="$2"; shift 2 ;;
        --head-json) HEAD_JSON="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "census: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v python3 >/dev/null || { echo "census: python3 required" >&2; exit 2; }
DOCS_DIR="$ROOT/docs/observability"

if [[ -n "$CHECK_BASE" ]]; then
    exec python3 "$PY" check-shrink --root "$ROOT" --base "$CHECK_BASE" \
        --head "${HEAD_JSON:-$DOCS_DIR/ci-test-census.json}"
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/chump-census.XXXXXX")"
if [[ "${CHUMP_CENSUS_KEEP_SANDBOX:-0}" == "1" ]]; then
    echo "census: sandbox kept at $SANDBOX" >&2
else
    trap 'rm -rf "$SANDBOX"' EXIT
fi
mkdir -p "$SANDBOX/results" "$SANDBOX/runs"

partial=0
[[ -n "$SAMPLE$ONLY$FILTER" ]] && partial=1
if [[ -z "$OUT_DIR" ]]; then
    if [[ $partial -eq 1 && $WRITE -eq 0 && $NO_RUN -eq 0 ]]; then
        OUT_DIR="$SANDBOX/out"
        export CHUMP_CENSUS_KEEP_SANDBOX=1; trap - EXIT
        echo "census: partial run; output + per-test logs kept in $SANDBOX (pass --write to merge into docs)" >&2
    else
        OUT_DIR="$DOCS_DIR"
    fi
fi
mkdir -p "$OUT_DIR"

# Classification + selection (python writes the selected list).
python3 "$PY" classify --root "$ROOT" --out "$SANDBOX/classified.json" \
    --select-out "$SANDBOX/selected.txt" \
    ${SAMPLE:+--sample "$SAMPLE"} ${ONLY:+--only "$ONLY"} ${FILTER:+--filter "$FILTER"}

mode=full
[[ $partial -eq 1 ]] && mode=partial
if [[ $NO_RUN -eq 1 ]]; then
    mode=no-run
else
    fixture="${CHUMP_CENSUS_STATE_DB_FIXTURE:-$ROOT/.chump/state.db}"
    if [[ -s "$fixture" ]]; then
        cp "$fixture" "$SANDBOX/state.db"
    elif command -v sqlite3 >/dev/null; then
        sqlite3 "$SANDBOX/state.db" 'PRAGMA user_version=0;' >/dev/null
    else
        : > "$SANDBOX/state.db"
    fi
    n="$(wc -l < "$SANDBOX/selected.txt" | tr -d ' ')"
    echo "census: running $n tests (jobs=$JOBS timeout=${TIMEOUT_S}s)" >&2
    if [[ "$n" -gt 0 ]]; then
        export ROOT TIMEOUT_S
        tr '\n' '\0' < "$SANDBOX/selected.txt" \
            | xargs -0 -P "$JOBS" -I{} bash "${BASH_SOURCE[0]}" --_run-one "{}" "$SANDBOX" \
            || echo "census: xargs exited $? (a runner died; its test is recorded as fail)" >&2
    fi
fi

prev="$OUT_DIR/ci-test-census.json"
[[ -f "$prev" ]] || prev="$DOCS_DIR/ci-test-census.json"
python3 "$PY" report --root "$ROOT" --classified "$SANDBOX/classified.json" \
    --results "$SANDBOX/results" --mode "$mode" --timeout "$TIMEOUT_S" --jobs "$JOBS" \
    --selected "$SANDBOX/selected.txt" --prev "$prev" --out-dir "$OUT_DIR" ${KNOWN_RED:+--known-red "$KNOWN_RED"}
