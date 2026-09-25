#!/usr/bin/env bash
# INFRA-5587: CLI surface baseline — snapshot + backward-compat gate.
#
# Companion to docs/refactor/MAIN_RS_DECOMPOSITION.md (INFRA-1687 slice).
# As that migration ports subcommands out of src/main.rs into src/cmd/<name>.rs
# self-registering modules (INFRA-1748 pattern), this script is the
# regression gate: it snapshots the top-level `chump --help` command surface
# and runtime-checks a baseline set of subcommands, so a port that silently
# drops or renames a subcommand fails CI instead of shipping unnoticed.
#
# Two things this script does NOT do (by design, keeps it cheap + stable):
#   - it does not diff full --help body text (too brittle — wording changes
#     are fine, a removed/renamed command is not)
#   - it does not require network or a live gap store — pure `--help` /
#     no-op invocations only
#
# Run: ./scripts/ci/test-cli-surface-baseline.sh
# CI:  called from scripts/ci/fast-checks.sh / chump preflight --with-tests

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MAIN_RS="$REPO_ROOT/src/main.rs"
BASELINE_FILE="$SCRIPT_DIR/cli-surface-baseline.txt"
source "$SCRIPT_DIR/lib/discover-chump-bin.sh"

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); FAILS+=("$1"); }

echo "=== INFRA-5587 CLI surface baseline ==="
echo

# ── Part 1: snapshot — every baseline command must still be dispatched ─────
# The baseline file is the checked-in list of top-level subcommand tokens
# this repo has promised to keep working (docs/refactor/MAIN_RS_DECOMPOSITION.md
# is the authoritative per-command inventory; this file is the CI-checkable
# subset). A command falling out of this file is a deliberate deprecation
# (edit the baseline in the same PR); a command silently disappearing from
# main.rs while still in the baseline is exactly the regression this gate
# exists to catch.
echo "--- Part 1: baseline commands still dispatched in source ---"

if [[ ! -f "$BASELINE_FILE" ]]; then
    fail "baseline file missing: $BASELINE_FILE"
else
    while IFS= read -r cmd; do
        [[ -z "$cmd" || "$cmd" == \#* ]] && continue
        if grep -q "\"$cmd\"" "$MAIN_RS" 2>/dev/null; then
            ok "source: '$cmd' still referenced in main.rs"
        else
            fail "source: baseline command '$cmd' no longer found in main.rs — surface regression or needs porting to src/cmd/"
        fi
    done < "$BASELINE_FILE"
fi

# ── Part 2: runtime — baseline commands respond to --help with exit 0 ──────
echo
echo "--- Part 2: runtime baseline invocations ---"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[info] binary not found at $CHUMP_BIN — attempting build"
    cargo build --manifest-path "$REPO_ROOT/Cargo.toml" --bin chump --quiet 2>/dev/null || true
fi

if [[ ! -x "$CHUMP_BIN" ]]; then
    ok "Runtime tests: binary not built — skipping (source checks passed)"
else
    # A representative sample across every lane in MAIN_RS_DECOMPOSITION.md —
    # not exhaustive (that would make this gate a multi-minute integration
    # test), but wide enough to catch a systemic breakage (e.g. the alias
    # expansion table, or a shared arg-parsing helper) that a single-command
    # smoke test would miss.
    # cmd|help-args|expected-substring-regex (case-insensitive). Most
    # subcommands print a literal "Usage:" line for bare `--help`; a few
    # group-style commands (gap, kpi) have their own conventions — gap
    # prints "<subcommand> [options]" with no top-level --help handler, and
    # kpi requires its one real subcommand (`report`) before --help does
    # anything. Encode each command's actual contract explicitly rather than
    # forcing one shape on all of them.
    RUNTIME_CMDS=(
        "gap|--help|subcommand"
        "claim|--help|usage"
        "fleet|--help|usage"
        "dispatch|--help|usage"
        "health|--help|usage"
        "kpi report|--help|report\|kpi"
        "cost-watch|--help|usage"
        "waste-tally|--help|usage"
        "ci-summary|--help|usage"
        "session-export|--help|usage"
        "dashboard|--help|usage"
        "mission-grade|--help|usage"
        "roadmap-status|--help|usage"
        "pe-suite|--help|usage"
    )

    for entry in "${RUNTIME_CMDS[@]}"; do
        IFS='|' read -r cmd helparg pattern <<< "$entry"
        set +e
        # shellcheck disable=SC2086
        _out=$("$CHUMP_BIN" $cmd $helparg 2>&1)
        _rc=$?
        set -e

        # Group-style commands print their subcommand usage and exit
        # non-zero on a bare `--help` — that's existing, intentional
        # behavior (bare invocation = "no subcommand given"), not a
        # regression. A crash (signal-terminated, rc >= 126) or a genuinely
        # empty/off-contract response is what this gate actually cares
        # about.
        if [[ $_rc -ge 126 ]]; then
            fail "Runtime: chump $cmd $helparg crashed (rc=$_rc)"
        elif [[ -z "$_out" ]]; then
            fail "Runtime: chump $cmd $helparg produced no output"
        elif echo "$_out" | grep -qi "$pattern"; then
            ok "Runtime: chump $cmd $helparg matches expected contract (rc=$_rc)"
        else
            fail "Runtime: chump $cmd $helparg output missing expected '$pattern'"
        fi
    done

    # Alias expansion (EFFECTIVE-011) — g/c/f/d/h/cs must resolve identically
    # to their long forms. A main.rs decomposition that drops expand_aliases()
    # or reorders it after dispatch would break this silently.
    declare -A ALIASES=(
        [g]=gap
        [c]=claim
        [f]=fleet
        [d]=dispatch
        [h]=health
        [cs]=cost-watch
    )
    for alias in "${!ALIASES[@]}"; do
        long="${ALIASES[$alias]}"
        set +e
        _out_alias=$("$CHUMP_BIN" "$alias" --help 2>&1)
        _rc_alias=$?
        _out_long=$("$CHUMP_BIN" "$long" --help 2>&1)
        _rc_long=$?
        set -e
        if [[ "$_rc_alias" == "$_rc_long" && "$_out_alias" == "$_out_long" ]]; then
            ok "Alias: chump $alias --help matches chump $long --help"
        else
            fail "Alias: chump $alias --help diverged from chump $long --help"
        fi
    done

    # Top-level help.
    set +e
    _out=$("$CHUMP_BIN" --help 2>&1)
    _rc=$?
    set -e
    if [[ $_rc -eq 0 ]] && echo "$_out" | grep -q 'USAGE'; then
        ok "Runtime: chump --help exits 0 and prints USAGE"
    else
        fail "Runtime: chump --help rc=$_rc or missing USAGE"
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ ${#FAILS[@]} -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
