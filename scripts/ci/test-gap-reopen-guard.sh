#!/usr/bin/env bash
# RESILIENT-1587: operator-blocked gaps survive every reopen writer.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/chump" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == gap && "$2" == show ]]; then
  [[ "$5" == status ]] && { echo blocked; exit 0; }
  [[ "$5" == notes ]] && { echo "INFRA-3832 auto-block last kind=timeout operator-block: waiting on legal"; exit 0; }
fi
if [[ "$1" == gap && "$2" == set ]]; then echo "SET $*" >> "$STUB_LOG"; exit 0; fi
exit 0
STUB
chmod +x "$T/chump"
export CHUMP_BIN="$T/chump" STUB_LOG="$T/log"; : > "$STUB_LOG"
fail=0
ok() { echo "ok $1"; }; bad() { echo "FAIL $1"; fail=1; }
sets_open() { grep -c -- '--status open' "$STUB_LOG"; }

source "$ROOT/scripts/lib/safe-reopen-gap.sh"
gap_reopen_allowed X-1 2>/dev/null; [[ $? -eq 3 ]] && ok helper-gap_reopen_allowed || bad helper-gap_reopen_allowed
safe_reopen_gap X-1 2>/dev/null; [[ $? -eq 3 && $(sets_open) -eq 0 ]] && ok helper-safe_reopen_gap || bad helper-safe_reopen_gap

# cooldown-transient-sweep --apply against a real sqlite fixture
if command -v sqlite3 >/dev/null; then
  mkdir -p "$T/repo/.chump" "$T/repo/.chump-locks/cooldown"
  sqlite3 "$T/repo/.chump/state.db" "create table gaps(id text, status text, notes text); insert into gaps values('X-1','blocked','INFRA-3832 auto-block last kind=timeout operator-block: legal');"
  CHUMP_REPO="$T/repo" bash "$ROOT/scripts/ops/cooldown-transient-sweep.sh" --apply >/dev/null 2>&1
  [[ $(sets_open) -eq 0 ]] && ok cooldown-transient-sweep || bad cooldown-transient-sweep
fi

# outcome-verify-heal-consumer: reopen must not happen for the blocked gap
: > "$T/amb.jsonl"
echo '{"kind":"outcome_probe_failed","gap_id":"X-1","note":"n"}' >> "$T/amb.jsonl"
CHUMP_OUTCOME_VERIFY_GAP_BIN="$T/chump" CHUMP_AMBIENT_LOG="$T/amb.jsonl" CHUMP_OUTCOME_VERIFY_STATE_DIR="$T/st" \
  timeout 60 bash "$ROOT/scripts/coord/outcome-verify-heal-consumer.sh" >/dev/null 2>&1 </dev/null
[[ $(sets_open) -eq 0 && $(grep -c -- "--add-note" "$STUB_LOG") -ge 1 ]] && ok outcome-verify-heal-consumer || bad outcome-verify-heal-consumer

# writers that need gh/PR fixtures: verify the guard precedes every status-open write
for f in scripts/coord/ghost-gap-reaper.sh scripts/ops/rot-reaper.sh scripts/coord/pr-failure-auto-rescue.sh scripts/triage_bookkeeping_gaps.sh scripts/ops/stuck-pr-filer.sh; do
  grep -q 'safe-reopen-gap.sh' "$ROOT/$f" && grep -qE 'safe_reopen_gap|gap_reopen_allowed' "$ROOT/$f" && ok "guarded $f" || bad "guarded $f"
done
exit $fail
