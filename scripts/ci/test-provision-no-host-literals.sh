#!/usr/bin/env bash
# scripts/ci/test-provision-no-host-literals.sh — INFRA-8194 (Phase R, R5)
#
# Every host-assumption incident on the fleet is the same bug: a shipped unit or
# script hardcodes ONE machine, and a different machine runs it.
#   - chump-gap-close-decomposed.service baked a concrete User= and was copied
#     into cuphead's systemd --user manager, where the user is ubuntu: exit
#     217/USER every ten minutes (RESILIENT-1601).
#   - chump-organ-watchdog.service resolved its home to the root home on an
#     owned node (HOME=/root, INFRA-3647).
#   - the abandoned root-owned second install (INFRA-8049), a brew-only Linux
#     bootstrap (INFRA-8112).
#
# This gate fails if any file under the provisioning dirs contains one of four
# host literals (the same rules as crates/chump-provision find_host_literals):
#
#   user-literal      User=<name>   (a concrete name, not User=$VAR)
#   home-literal      /home/<name>
#   root-literal      /root/
#   homebrew-literal  /opt/homebrew
#
# A comment line (first non-blank char `#`, but NOT a `#!` shebang) is skipped:
# it executes nothing, and incident receipts ("the old unit ran ~root's
# checkout") live there (INFRA-8194 slice 2, mirrored in find_host_literals).
# Quoted text in code is never skipped: a quoted string is usually a live path.
# Write documentation examples as /home/<user>, ~root/, "the Homebrew prefix".
#
# Write placeholders instead (__HOME__ __REPO_ROOT__ __BIN_DIR__ __NODE_ENV__
# __BREW_PREFIX__)
# and render through the typed Host enum (`chump node render-unit`, or the shell
# mirror organ_unit_host_rewrite). User= is injected by the renderer for a
# system-scope install only.
#
# Today's offenders live in scripts/ci/provision-host-literal-allowlist.txt. That
# list may ONLY SHRINK:
#   * a file that offends and is not listed fails (no new offenders);
#   * a listed file that no longer offends fails (delete the line, bank the win);
#   * more entries than the header's `baseline-count:` fails;
#   * an entry absent from origin/main's copy of the list fails (no growth).
#
# Usage:
#   bash scripts/ci/test-provision-no-host-literals.sh            # self-test + real scan
#   bash scripts/ci/test-provision-no-host-literals.sh --list     # print current offenders
#   bash scripts/ci/test-provision-no-host-literals.sh --root DIR --allowlist FILE [--no-growth-check]
#
# Hermetic, no network, no chump binary, <2s.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ALLOWLIST_REL="scripts/ci/provision-host-literal-allowlist.txt"

SCAN_DIRS=(scripts/dispatch launchd scripts/plists scripts/setup)
PATTERN='(^|[^A-Za-z0-9_])User=[A-Za-z_]|/home/[a-z_]|/root/|/opt/homebrew'

# COMMENT: a grep -n line whose text is a comment (not a shebang).
COMMENT='^[0-9]+:[[:space:]]*#([^!]|$)'

# literal_lines <file> -> "N:text" for each NON-comment line carrying a literal.
literal_lines() {
  grep -nIE "$PATTERN" "$1" 2>/dev/null | grep -vE "$COMMENT"
}

# offenders <root> -> repo-relative paths of files carrying a host literal
# outside a comment, sorted.
offenders() {
  local root="$1" d f
  (
    cd "$root" || exit 0
    for d in "${SCAN_DIRS[@]}"; do
      [ -d "$d" ] || continue
      grep -rlIE "$PATTERN" "$d" 2>/dev/null
    done | while IFS= read -r f; do
      [ -n "$(literal_lines "$f")" ] && printf '%s\n' "$f"
    done
  ) | LC_ALL=C sort -u
}

allow_entries() {
  [ -f "$1" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$1" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' | LC_ALL=C sort -u
}

# check <root> <allowlist> <growth-check 0|1> -> 0 clean, 1 violations (printed).
check() {
  local root="$1" allow="$2" growth="$3" rc=0
  local found allowed new stale n baseline f
  found="$(offenders "$root")"
  allowed="$(allow_entries "$allow")"

  new="$(LC_ALL=C comm -23 <(printf '%s\n' "$found" | sed '/^$/d') <(printf '%s\n' "$allowed" | sed '/^$/d'))"
  if [ -n "$new" ]; then
    rc=1
    echo "FAIL: new host literal(s); use __HOME__/__REPO_ROOT__/__BIN_DIR__/__NODE_ENV__/__BREW_PREFIX__ and render via the Host enum (chump node render-unit):"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      literal_lines "$root/$f" | head -5 | sed "s|^|  $f:|"
    done <<< "$new"
  fi

  stale="$(LC_ALL=C comm -13 <(printf '%s\n' "$found" | sed '/^$/d') <(printf '%s\n' "$allowed" | sed '/^$/d'))"
  if [ -n "$stale" ]; then
    rc=1
    echo "FAIL: allowlisted file(s) no longer carry a host literal; delete them from $ALLOWLIST_REL so the list shrinks:"
    printf '  %s\n' $stale
  fi

  n="$(printf '%s\n' "$allowed" | sed '/^$/d' | wc -l | tr -d ' ')"
  baseline="$(grep -m1 -E '^# baseline-count:' "$allow" 2>/dev/null | sed -E 's/^# baseline-count:[[:space:]]*//' | tr -d ' ')"
  if [ -z "$baseline" ]; then
    rc=1; echo "FAIL: $allow has no '# baseline-count: N' header"
  elif [ "$n" -gt "$baseline" ]; then
    rc=1; echo "FAIL: allowlist has $n entries, above its baseline-count of $baseline (it may only shrink)"
  fi

  if [ "$growth" = 1 ] && git -C "$root" rev-parse --verify -q origin/main >/dev/null 2>&1; then
    local main_copy grown
    if main_copy="$(git -C "$root" show "origin/main:$ALLOWLIST_REL" 2>/dev/null)"; then
      grown="$(LC_ALL=C comm -23 <(printf '%s\n' "$allowed" | sed '/^$/d') \
                <(printf '%s\n' "$main_copy" | grep -vE '^[[:space:]]*(#|$)' | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' | LC_ALL=C sort -u))"
      if [ -n "$grown" ]; then
        rc=1
        echo "FAIL: allowlist gained entries not on origin/main (it may only shrink):"
        printf '  %s\n' $grown
      fi
    fi
  fi
  return "$rc"
}

self_test() {
  local t; t="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$t'" RETURN
  mkdir -p "$t/scripts/dispatch" "$t/launchd" "$t/scripts/setup"
  printf '[Service]\nEnvironment=HOME=__HOME__\nUser=$RUN_USER\n# User=<name> is a doc mention\n' > "$t/scripts/dispatch/clean.service"
  printf '[Service]\nUser=jeff\n' > "$t/scripts/dispatch/user.service"
  printf '<string>/opt/homebrew/bin/chump</string>\n' > "$t/launchd/brew.plist"
  printf 'cd /home/ubuntu/chump\nsource /root/.chump/providers.env\n' > "$t/scripts/setup/paths.sh"
  # Comment-only literals are documentation, not host assumptions (slice 2).
  printf '#!/usr/bin/env bash\n# the old unit ran /root/Projects/chump as User=root\n  # PATH began with /opt/homebrew/bin\necho ok\n' > "$t/scripts/setup/comments.sh"

  local listed="$t/allow.txt"
  { echo "# baseline-count: 3"; echo "launchd/brew.plist"; echo "scripts/dispatch/user.service"; echo "scripts/setup/paths.sh"; } > "$listed"
  check "$t" "$listed" 0 >/dev/null || { echo "  self-test FAIL: fully allowlisted fixture should pass"; return 1; }

  { echo "# baseline-count: 3"; echo "launchd/brew.plist"; echo "scripts/setup/paths.sh"; } > "$listed"
  { check "$t" "$listed" 0 || true; } | grep -q 'scripts/dispatch/user.service:2:User=jeff' \
    || { echo "  self-test FAIL: unlisted User=jeff offender not reported with file:line"; return 1; }

  { echo "# baseline-count: 4"; echo "launchd/brew.plist"; echo "scripts/dispatch/user.service"; echo "scripts/setup/paths.sh"; echo "scripts/dispatch/clean.service"; } > "$listed"
  { check "$t" "$listed" 0 || true; } | grep -q 'no longer carry' \
    || { echo "  self-test FAIL: stale allowlist entry (clean file) not reported"; return 1; }

  { echo "# baseline-count: 2"; echo "launchd/brew.plist"; echo "scripts/dispatch/user.service"; echo "scripts/setup/paths.sh"; } > "$listed"
  { check "$t" "$listed" 0 || true; } | grep -q 'above its baseline-count' \
    || { echo "  self-test FAIL: allowlist above baseline-count not reported"; return 1; }

  printf 'launchd/brew.plist\n' > "$listed"
  { check "$t" "$listed" 0 || true; } | grep -q "baseline-count: N' header" \
    || { echo "  self-test FAIL: missing baseline header not reported"; return 1; }

  { echo "# baseline-count: 3"; echo "launchd/brew.plist"; echo "scripts/dispatch/user.service"; echo "scripts/setup/paths.sh"; } > "$listed"
  printf '#!/opt/homebrew/bin/bash\necho hi\n' > "$t/scripts/setup/shebang.sh"
  { check "$t" "$listed" 0 || true; } | grep -q 'scripts/setup/shebang.sh:1:#!/opt/homebrew/bin/bash' \
    || { echo "  self-test FAIL: a #! shebang is not a comment and must be flagged"; return 1; }
  { check "$t" "$listed" 0 || true; } | grep -q 'comments.sh' \
    && { echo "  self-test FAIL: comment-only literals must not be flagged"; return 1; }
  printf 'X=1 # see /root/\necho "/opt/homebrew/bin/chump"\n' > "$t/scripts/setup/shebang.sh"
  { check "$t" "$listed" 0 || true; } | grep -q 'shebang.sh:2:echo "/opt/homebrew/bin/chump"' \
    || { echo "  self-test FAIL: quoted text in code must still be flagged"; return 1; }

  echo "  ok self-test: clean placeholders pass; comment lines skipped, shebangs and quoted code still caught; User=<name>, /home/<name>, /root/, /opt/homebrew caught; stale + over-baseline + headerless lists fail"
  return 0
}

ROOT="$REPO_ROOT"; ALLOW=""; GROWTH=1; MODE="gate"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2;;
    --allowlist) ALLOW="$2"; shift 2;;
    --no-growth-check) GROWTH=0; shift;;
    --list) MODE="list"; shift;;
    -h|--help) sed -n '2,45p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$ALLOW" ] || ALLOW="$ROOT/$ALLOWLIST_REL"

if [ "$MODE" = list ]; then offenders "$ROOT"; exit 0; fi

echo "=== test-provision-no-host-literals.sh (INFRA-8194, Phase R R5) ==="
self_test || exit 1
if check "$ROOT" "$ALLOW" "$GROWTH"; then
  echo "  ok no new host literals under ${SCAN_DIRS[*]}; allowlist $(allow_entries "$ALLOW" | wc -l | tr -d ' ') file(s), shrink-only"
  exit 0
fi
exit 1
