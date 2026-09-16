#!/usr/bin/env bash
# scripts/ci/test-system-invariants-launchd.sh — META-556 (META-033 slice)
#
# Static verification of the system-invariants-monitor LaunchAgent assets:
# plist exists, is well-formed, scheduled at a 10-minute cadence, and wired
# to invoke system-invariants-monitor.sh; installer loads it via launchctl.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$REPO_ROOT/launchd/dev.chump.system-invariants-monitor.plist"
INST="$REPO_ROOT/scripts/setup/install-system-invariants-launchd.sh"
MONITOR="$REPO_ROOT/scripts/ops/system-invariants-monitor.sh"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[[ -f "$PLIST" ]] || fail "plist missing: $PLIST"
grep -q 'dev.chump.system-invariants-monitor' "$PLIST" || fail "plist label wrong"
grep -q '<integer>600</integer>' "$PLIST" || fail "plist interval not 600s (10 min)"
grep -q 'system-invariants-monitor.sh' "$PLIST" || fail "plist doesn't reference monitor script"
ok "plist present with label + 10min interval + correct script reference"

if command -v python3 >/dev/null 2>&1; then
  python3 -c "import xml.dom.minidom as m; m.parse('$PLIST')" \
    || fail "plist is not well-formed XML"
  ok "plist is well-formed XML"
fi

[[ -x "$INST" ]] || fail "installer missing or not executable"
grep -q 'resolve_main_worktree' "$INST" || fail "installer not using INFRA-451 resolver"
grep -q 'launchctl load' "$INST" || fail "installer doesn't launchctl load the plist"
ok "installer present + uses resolve_main_worktree + loads via launchctl"

[[ -x "$MONITOR" ]] || fail "system-invariants-monitor.sh missing (META-033 dep)"
ok "META-033 monitor script present in main"

echo
echo "All META-556 system-invariants-launchd tests passed."
