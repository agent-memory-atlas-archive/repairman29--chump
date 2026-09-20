#!/usr/bin/env bash
# scripts/ops/organ-reconcile.sh — RESILIENT-305 (reproducible-deploy, slice 1)
#
# Converge the PRIMARY node's live systemd state to the repo-declared organ
# manifest (scripts/ops/organ-manifest.txt): enable/start the organs that must
# run, and neuter+stop the auto-pagers that must stay OFF. Idempotent — safe to
# re-run any time; a second run with no drift is a no-op.
#
# WHY: tonight's pager DM-spam + failed-organ resurrection were one root cause —
# deployed systemd state DRIFTED from the repo, and the fixes were host-level
# edits (/etc/systemd/system/*.d/zz-autopage-off.conf) that are invisible to the
# repo and get reverted by the deploy mirror's `git reset --hard origin/main`.
# This reconcile keeps the desired state IN the repo (the manifest) and re-applies
# it, so drift self-heals and nothing is a snowflake.
#
# The pager-OFF mechanism is a systemd drop-in that overrides ExecStart to
# /bin/true. A drop-in beats mask/disable for durability here because:
#   * install-helsinki-atc.sh does `cp -f` of the BASE unit file every deploy —
#     that would clobber a mask symlink, but it never touches the unit's `.d/`
#     drop-in directory, so the override survives.
#   * `git reset --hard` reverts working-tree edits, but the drop-in content is
#     re-applied by THIS script from the repo on every reconcile.
# Neutering to /bin/true (rather than disabling the timer) also means a oneshot
# pager exits SUCCESS, so chump-organ-watchdog never sees it "failed" and never
# restarts it — closing the 5-minute resurrection loop.
#
# Usage:
#   sudo bash scripts/ops/organ-reconcile.sh --apply    # converge (default)
#   sudo bash scripts/ops/organ-reconcile.sh --check    # exit 0 iff state==manifest
#
# Runs as root (writes /etc/systemd/system). Under a non-root/--auto-style
# context it warns and exits 0 rather than hard-failing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="${CHUMP_ORGAN_MANIFEST:-$REPO_ROOT/scripts/ops/organ-manifest.txt}"
SYSTEMD_DIR="/etc/systemd/system"
DROPIN_NAME="zz-organ-reconcile-pager-off.conf"
LEGACY_DROPIN="zz-autopage-off.conf"   # tonight's host-only snowflake — remove it

# RESILIENT-347: stubbable systemctl (test hook, mirrors organ-watchdog.sh's
# CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN pattern) + per-node-applicable reconcile
# tunables.
SYSTEMCTL_BIN="${CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN:-systemctl}"
BACKOFF_DIR="${CHUMP_ORGAN_RECONCILE_BACKOFF_DIR:-$REPO_ROOT/.chump-locks/organ-backoff}"
BACKOFF_COOLDOWN_S="${CHUMP_ORGAN_RECONCILE_BACKOFF_COOLDOWN_S:-3600}"
VERIFY_DELAY_S="${CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S:-2}"

AMBIENT_LOG="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
LIB_AMBIENT="$REPO_ROOT/scripts/coord/lib/ambient-write.sh"
[[ -f "$LIB_AMBIENT" ]] && source "$LIB_AMBIENT"

# TREK-18 (INFRA-3644): the manifest parser is shared with install-helsinki-atc.sh
LIB_ORGAN_MANIFEST="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
if [[ ! -f "$LIB_ORGAN_MANIFEST" ]]; then
  echo "ERROR: missing $LIB_ORGAN_MANIFEST" >&2
  exit 1
fi
source "$LIB_ORGAN_MANIFEST"

emit() {  # kind, extra-json (no leading/trailing comma)
  local kind="$1" extra="${2:-}"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
  else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
  if command -v _ambient_write >/dev/null 2>&1; then
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && _ambient_write "$AMBIENT_LOG" "$line" || true
  else
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
  fi
  return 0  # emit is best-effort telemetry; it must never sink the reconcile (set -e)
}

# RESILIENT-347 / RESILIENT-1055: organ_is_applicable now lives in
# organ-manifest-lib.sh (sourced above) so it and scripts/ops/organ-role-roster.sh
# compute applicability identically. It honors bin:/env:/dep:/file: requires
# tokens; see that lib + the manifest header.

# RESILIENT-1055: node-LOCAL organs the role-scoped drift-removal must NEVER
# reap. These are units chump-node-install.sh installs directly (not via the
# manifest) — the worker, heartbeat, the common self-heal organs — plus the
# reconcile's OWN beat (chump-organ-reconcile, intentionally self-excluded from
# the manifest) and the --user refresh timers. Without this exemption a
# role-scoped reconcile saw them as "active/enabled but out-of-role" and
# disabled them on its very first pass — reaping the worker it was meant to keep
# alive and its own timer (VERIFIED in the FTUE container: worker + reconcile
# went inactive immediately after a `--role muscle` bring-up).
NODE_LOCAL_ORGAN_BASES=(
  chump-organ-reconcile
  chump-worker
  chump-node-heartbeat
  chump-process-organ-heal
  chump-fleet-health-sentinel
  chump-node-refresh
  chump-node-deploy-lag-watchdog
  chump-fleet-server
  # RESILIENT-1083: node-lifecycle INFRA installed directly by chump-node-install.sh
  # / install-node-housekeeping.sh (NOT the manifest). Reaping any of these breaks
  # the node itself — auth/token refresh, the self-hosted-runner binary refresh,
  # worker autoscaling, and disk / build / process hygiene — so a role-scoped
  # reconcile must never treat them as "out-of-role drift". (Brain COORDINATION
  # daemons that leak onto a muscle node are deliberately NOT listed: those SHOULD
  # be reaped by the drift-removal pass.)
  chump-oauth-refresh
  chump-oracle-refresh
  chump-refresh-runner-binary
  chump-node-orchestrator
  chump-disk-health-monitor
  chump-disk-monitor
  chump-worktree-reaper
  chump-stale-worktree-reaper
  chump-cargo-sweep-gc
  chump-cargo-target-reaper
  chump-active-target-reaper
  chump-stale-process-watchdog
)
organ_is_node_local() {
  local base="${1%.service}"; base="${base%.timer}"
  # RESILIENT-1083 (worker-orphan class): a muscle node's concrete worker unit and
  # its node-orchestrator autoscale peers (chump-cj-worker, chump-node1-worker,
  # chump-cj-worker2/3, chump-worker@N, ...) are ALWAYS node-local — installed by
  # chump-node-install.sh / node-orchestrator.sh and driven by a node-local run
  # script (~/cj-worker-run.sh, ~/node1-worker-run.sh), never a manifest organ.
  # This glob is the GENERAL replacement for the per-node manifest reap-protection
  # lines (the CJ-shaped chump-cj-worker / chump-node1-worker lines): a NEW muscle
  # node's worker survives a role-scoped reconcile with ZERO manifest or node-local
  # hand-edit. Without it, removing the per-node manifest line let the drift-removal
  # pass reap the worker (mugman went dark 2026-09-08 after a manifest reset --hard).
  case "$base" in
    chump-*worker|chump-*worker[0-9]*|chump-worker@*) return 0;;
  esac
  local n
  for n in "${NODE_LOCAL_ORGAN_BASES[@]}"; do [[ "$base" == "$n" ]] && return 0; done
  return 1
}

# RESILIENT-347: is `unit` still cooling down from a prior verify failure?
# Returns 0 (true, skip it) while now - since < BACKOFF_COOLDOWN_S.
organ_in_backoff() {
  local unit="$1" f="$BACKOFF_DIR/${unit}.json"
  [[ -f "$f" ]] || return 1
  local since; since="$(grep -o '"since":[0-9]*' "$f" 2>/dev/null | head -1 | cut -d: -f2)"
  [[ "$since" =~ ^[0-9]+$ ]] || return 1
  local now; now="$(date +%s)"
  (( now - since < BACKOFF_COOLDOWN_S ))
}

record_backoff() {  # unit, reason
  local unit="$1" reason="$2"
  mkdir -p "$BACKOFF_DIR" 2>/dev/null || return 0
  printf '{"unit":"%s","since":%d,"reason":"%s"}\n' "$unit" "$(date +%s)" "$reason" \
    > "$BACKOFF_DIR/${unit}.json" 2>/dev/null || true
}

clear_backoff() {  # unit
  rm -f "$BACKOFF_DIR/${1}.json" 2>/dev/null || true
}

# RESILIENT-1016 (a): drift-REMOVAL discovery. Lists every chump-managed unit
# FILE present on the host (installed, whether active or not) so the caller
# can diff it against the role-filtered manifest's expected set. Only
# meaningful for a role-scoped reconcile (ROLE_FILTER set) — the unfiltered
# reconcile already manages the WHOLE manifest, so there is no "out of role"
# unit to reap there.
#
# RESILIENT-1016 follow-up (timer-aware): enumerate BOTH .service and .timer
# units. The original discovery listed only .service files, so the paired
# .timer of an out-of-role unit was never a reap candidate — disabling the
# service alone left the timer enabled, and it re-triggered the service every
# cycle. VERIFIED on mugman (2026-09-07): 28 out-of-role Mac-path launchd
# ports "reaped" via the .service alone climbed straight back to 28 because
# their .timer units stayed enabled and kept re-firing the CHDIR-failing
# services.
discover_live_chump_units() {
  {
    "$SYSTEMCTL_BIN" list-unit-files --type=service --no-legend 'chump-*.service' 2>/dev/null
    "$SYSTEMCTL_BIN" list-unit-files --type=timer   --no-legend 'chump-*.timer'   2>/dev/null
  } | awk '{print $1}'
}

# A unit is a drift-removal candidate if systemd still considers it active OR
# enabled — a unit that's merely present-on-disk-but-inactive-and-disabled
# isn't drift, it's just a dormant unit file left by history. A unit stuck in
# the `failed` state also counts as live: it pollutes `systemctl --failed`
# forever and must be cleared, even if it is now neither active nor enabled
# (a oneshot that crashed, or a service whose timer was disabled but whose last
# run left it failed).
organ_is_live() {
  local unit="$1"
  "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null && return 0
  "$SYSTEMCTL_BIN" is-enabled --quiet "$unit" 2>/dev/null && return 0
  [[ "$("$SYSTEMCTL_BIN" is-failed "$unit" 2>/dev/null)" == "failed" ]] && return 0
  return 1
}

# RESILIENT-1016 follow-up: reap a chump unit AND its paired timer/service
# sibling — disable+stop+reset-failed both halves — so a reap actually sticks
# (the paired .timer can no longer re-trigger a just-disabled .service, and a
# lingering `failed` state is cleared so the unit leaves `systemctl --failed`).
reap_unit_and_sibling() {
  local unit="$1" base s
  base="${unit%.service}"; base="${base%.timer}"
  for s in "${base}.timer" "${base}.service"; do
    "$SYSTEMCTL_BIN" disable --now "$s" 2>/dev/null || true
    "$SYSTEMCTL_BIN" stop "$s" 2>/dev/null || true
    "$SYSTEMCTL_BIN" reset-failed "$s" 2>/dev/null || true
  done
}

# Repo-declared drop-in body that neuters an auto-pager's ExecStart.
dropin_body() {
  local unit="$1"
  cat <<EOF
# Managed by scripts/ops/organ-reconcile.sh (RESILIENT-305) — DO NOT EDIT BY HAND.
# Desired state is declared in scripts/ops/organ-manifest.txt (state=paging_off).
# Neuters $unit's ExecStart so its auto-paging stays OFF. Survives
# install-helsinki-atc.sh's cp of the base unit (the .d/ dir is untouched) and
# the deploy mirror's \`git reset --hard origin/main\` (re-applied from the repo).
[Service]
ExecStart=
ExecStart=/bin/true
EOF
}

# INFRA-7838 (INFRA-3648 slice): scripts/ops/organ-registry.txt (INFRA-7586)
# declares CJ's process-level node-housekeeping organs (cargo-sweep-gc,
# disk-monitor, main-health-watchdog, node-orchestrator, pr-lander,
# pr-stuck-live-scan, reviver, rot-reaper, worktree-reaper, ...) in the same
# `enabled  <name>  launcher=...  pgrep=...  heartbeat=...` grammar this
# manifest uses for systemd units — but until now nothing PARSED it: the
# generator (generate-organ-registry.sh) writes the file and a CI test checks
# its shape, but no live loop ever pgreps the organs it declares. That's the
# "designed but never wired into the revivable gate" hole this closes.
# organ_registry_parse populates 4 caller-provided arrays (nameref, mirrors
# organ_manifest_parse's calling convention) from a registry file in that
# format; blank lines and lines not starting with `enabled` are ignored.
PROCESS_ORGAN_REGISTRY="${CHUMP_PROCESS_ORGAN_REGISTRY_FILE:-$REPO_ROOT/scripts/ops/organ-registry.txt}"
organ_registry_parse() {  # registry-file, names-array-name, launcher-assoc-name, pgrep-assoc-name, heartbeat-assoc-name
  local registry="$1"
  local -n _orp_names="$2"
  local -n _orp_launcher="$3"
  local -n _orp_pgrep="$4"
  local -n _orp_heartbeat="$5"
  _orp_names=()

  if [[ ! -f "$registry" ]]; then
    echo "ERROR: process-organ registry not found: $registry" >&2
    return 1
  fi

  local state name rest tok launcher pgrep heartbeat
  while read -r state name rest; do
    [[ -z "${state:-}" ]] && continue
    [[ "$state" == \#* ]] && continue
    [[ "$state" != "enabled" ]] && continue
    [[ -z "${name:-}" ]] && continue
    launcher="" pgrep="" heartbeat=""
    for tok in $rest; do
      case "$tok" in
        launcher=*)  launcher="${tok#launcher=}" ;;
        pgrep=*)     pgrep="${tok#pgrep=}" ;;
        heartbeat=*) heartbeat="${tok#heartbeat=}" ;;
      esac
    done
    [[ -z "$pgrep" ]] && continue
    _orp_names+=("$name")
    _orp_launcher["$name"]="$launcher"
    _orp_pgrep["$name"]="$pgrep"
    _orp_heartbeat["$name"]="$heartbeat"
  done < "$registry"
  return 0
}

# organ_registry_check <registry-file>: read-only pgrep audit of every organ
# declared in a registry (organ_registry_parse's format). Prints one
# DETECTED-ALIVE/DETECTED-DEAD/UNKNOWN line per organ (mirrors
# process-organ-heal.sh's --check output shape for the sibling almanac
# registry) and returns 1 if any organ is DETECTED-DEAD. Never spawns
# anything — audit only.
organ_registry_check() {
  local registry="$1"
  local names=() launcher pgrep_pat heartbeat
  declare -A launchers pgreps heartbeats
  organ_registry_parse "$registry" names launchers pgreps heartbeats || return 2

  local any_dead=0 name status
  for name in "${names[@]}"; do
    pgrep_pat="${pgreps[$name]}"
    status="UNKNOWN"
    if command -v pgrep >/dev/null 2>&1; then
      if pgrep -f "$pgrep_pat" >/dev/null 2>&1; then
        status="DETECTED-ALIVE"
      else
        status="DETECTED-DEAD"
        any_dead=1
      fi
    fi
    printf '[organ-reconcile] %s: %s (%s)\n' "$status" "$name" "$pgrep_pat"
  done
  return "$any_dead"
}

# ── read manifest into arrays (+ per-unit role/requires, RESILIENT-347) ─────
# TREK-18: parsed by the shared organ_manifest_parse() helper (organ-manifest-lib.sh)
PAGING_OFF=()
ENABLED=()
declare -A ORGAN_ROLE
declare -A ORGAN_REQUIRES
declare -A ORGAN_PLATFORMS
organ_manifest_parse "$MANIFEST" PAGING_OFF ENABLED ORGAN_ROLE ORGAN_REQUIRES ORGAN_PLATFORMS || exit 1

# INFRA-7764 (docs/strategy/ONE_COMMAND_INSTALL.md section 1): platform
# scoping. organ-manifest.txt is becoming the single unified roster —
# bootstrap-manifest.yaml's macOS-only capabilities and
# install-node-housekeeping.sh's roster fold in as ordinary `enabled` lines
# tagged `platforms=launchd` / `platforms=systemd` respectively (slices
# INFRA-7765/INFRA-7766). This reconcile only ever drives systemd, so any
# line NOT applicable to systemd must never reach ENABLED below — otherwise
# folding in a platforms=launchd-only line (e.g. the mac-only curator/
# self-doctor/paramedic/conductor capabilities) would make this reconcile
# attempt `systemctl enable --now` on a unit name that only ever existed as
# a launchd plist, a pure regression the design doc requires "zero runtime
# behavior change" to avoid. Every pre-existing line has no platforms= token
# and defaults to systemd (organ_platform_matches' own default), so this
# filter is a no-op today and only starts doing work once INFRA-7765/7766
# add non-systemd lines.
THIS_PLATFORM="$(organ_current_platform)"
PLATFORM_FILTERED_ENABLED=()
for unit in "${ENABLED[@]}"; do
  if organ_platform_matches "${ORGAN_PLATFORMS[$unit]:-}" "$THIS_PLATFORM"; then
    PLATFORM_FILTERED_ENABLED+=("$unit")
  fi
done
ENABLED=("${PLATFORM_FILTERED_ENABLED[@]}")

# RESILIENT-746: optional per-role scoping. chump-node-install.sh's ORGANS
# phase (--role brain|muscle|all) sets this so a freshly-installed node only
# reconciles the organs that belong to its declared role instead of every
# `enabled` line in the manifest (the "install ORGANS but never wire the role
# split into the reconcile" hole from the helsinki teardown). Comma-separated
# list of role= values (as declared in organ-manifest.txt); empty/unset means
# "all roles" — the pre-existing, back-compat behavior for the primary node's
# own timer-driven reconcile, which is not role-scoped.
# RESILIENT-1083: node role identity lives OUTSIDE the repo in ~/.chump/node.env
# (written by chump-node-install.sh's write_node_env), so it SURVIVES the deploy
# mirror's `git reset --hard origin/main` that reverts any tracked-manifest edit.
# Sourcing it lets a muscle node's recurring (root-run) chump-organ-reconcile.timer
# self-scope to its role even when the systemd role drop-in (zz-node-role.conf) is
# absent — the exact mugman hole where an UNSCOPED root timer kept re-enabling
# (resurrecting) role=brain organs on a muscle node, which the fragile STOPGAP
# manifest hand-edits used to comment out by hand. An explicit
# CHUMP_ORGAN_RECONCILE_ROLE in the environment still WINS (back-compat: the
# install-time reconcile and the drop-in path are unchanged); node.env's
# CHUMP_NODE_ROLE is only the fallback when nothing else scoped this run, and an
# absent/empty value keeps the pre-existing whole-manifest behavior.
_NODE_ENV="${CHUMP_STATE_DIR:-$HOME/.chump}/node.env"
# shellcheck disable=SC1090
[[ -f "$_NODE_ENV" ]] && source "$_NODE_ENV" 2>/dev/null || true
ROLE_FILTER="${CHUMP_ORGAN_RECONCILE_ROLE:-}"
if [[ -z "$ROLE_FILTER" && -n "${CHUMP_NODE_ROLE:-}" && "${CHUMP_NODE_ROLE}" != "all" ]]; then
  ROLE_FILTER="$(organ_role_filter_for "${CHUMP_NODE_ROLE}")"
fi
if [[ -n "$ROLE_FILTER" ]]; then
  FILTERED_ENABLED=()
  IFS=',' read -ra _role_filter_toks <<< "$ROLE_FILTER"
  for unit in "${ENABLED[@]}"; do
    role="${ORGAN_ROLE[$unit]:-brain}"
    for tok in "${_role_filter_toks[@]}"; do
      if [[ "$tok" == "$role" ]]; then
        FILTERED_ENABLED+=("$unit")
        break
      fi
    done
  done
  ENABLED=("${FILTERED_ENABLED[@]}")
fi

MODE="${1:---apply}"

# ── --check-process-organs mode: read-only pgrep audit of organ-registry.txt
# (INFRA-7838). Independent of --check/--apply below (those drive systemd
# units only); exits 1 if any registered process-organ is DETECTED-DEAD, 2 if
# the registry itself is missing/unreadable.
if [[ "$MODE" == "--check-process-organs" ]]; then
  organ_registry_check "$PROCESS_ORGAN_REGISTRY"
  exit $?
fi

# ── --check mode: verify live state matches the manifest, change nothing ─────
if [[ "$MODE" == "--check" ]]; then
  fail=0
  for unit in "${PAGING_OFF[@]}"; do
    # RESILIENT-1055: only assert neutered for pager units that ACTUALLY EXIST on
    # this box. A role-scoped node never installs the pagers (they're primary-
    # node organs), so `systemctl show` returns an empty ExecStart and the old
    # grep read that as "not neutered" DRIFT for a unit that simply isn't here.
    "$SYSTEMCTL_BIN" cat "$unit" >/dev/null 2>&1 || continue
    # effective ExecStart must be neutered to /bin/true
    if ! "$SYSTEMCTL_BIN" show "$unit" -p ExecStart 2>/dev/null | grep -q '/bin/true'; then
      echo "DRIFT: $unit auto-paging is NOT neutered"; fail=1
    fi
  done
  for unit in "${ENABLED[@]}"; do
    requires="${ORGAN_REQUIRES[$unit]:-}"
    reason=""
    if ! organ_is_applicable "$unit" "$requires" reason; then
      echo "SKIP: $unit not applicable to this node ($reason)"
      continue
    fi
    if organ_in_backoff "$unit"; then
      echo "SKIP: $unit is backed off (cooling down after a prior failure)"
      continue
    fi
    if ! "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null; then
      echo "DRIFT: $unit is not active"; fail=1
    fi
  done
  # RESILIENT-1016 (a): role-scoped drift check — flag any chump unit that is
  # still active/enabled but NOT in the role-filtered manifest (present but
  # out-of-role, or dropped from the manifest entirely). Unfiltered (whole
  # manifest) reconciles have nothing "out of role" to flag.
  if [[ -n "$ROLE_FILTER" ]]; then
    declare -A _EXPECTED_UNIT
    for unit in "${ENABLED[@]}"; do _EXPECTED_UNIT["$unit"]=1; done
    for unit in "${PAGING_OFF[@]}"; do _EXPECTED_UNIT["$unit"]=1; done
    while IFS= read -r unit; do
      [[ -z "$unit" ]] && continue
      [[ -n "${_EXPECTED_UNIT[$unit]:-}" ]] && continue
      # Sibling protection (mirrors --apply): an in-role .timer implies its
      # paired .service is in-role too, and vice versa — don't flag it as drift.
      _base="${unit%.service}"; _base="${_base%.timer}"
      [[ -n "${_EXPECTED_UNIT[${_base}.timer]:-}" ]] && continue
      [[ -n "${_EXPECTED_UNIT[${_base}.service]:-}" ]] && continue
      # RESILIENT-1055: never flag node-local organs (worker/heartbeat/sentinel/
      # the reconcile's own beat) — chump-node-install installs them directly,
      # they're not manifest units and are NOT drift.
      organ_is_node_local "$unit" && continue
      if organ_is_live "$unit"; then
        echo "DRIFT: $unit is active/enabled but out-of-role (not in role-filtered manifest)"; fail=1
      fi
    done < <(discover_live_chump_units)
  fi
  [[ "$fail" == 0 ]] && echo "ok: live systemd state matches organ-manifest.txt"
  exit "$fail"
fi

# ── --apply mode ─────────────────────────────────────────────────────────────
# CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT is a test-only hook (mirrors the stub
# pattern organ-watchdog.sh uses for its own tests) so scripts/ci/test-organ-reconcile.sh
# can exercise the applicability/backoff logic against a stubbed systemctl
# without needing real root / a real systemd bus.
if [[ "$(id -u)" != "0" && "${CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT:-0}" != "1" ]]; then
  echo "WARN: organ-reconcile needs root to write $SYSTEMD_DIR; skipping (non-root context)" >&2
  # scanner-anchor: "kind":"organ_reconcile_skipped" (RESILIENT-305; fires when
  # the reconcile is invoked without root and cannot write /etc/systemd/system)
  emit organ_reconcile_skipped "\"reason\":\"not_root\""
  exit 0
fi

CHANGED=()
NEED_RELOAD=0

# 1) Auto-pagers → neuter (repo-declared drop-in) + stop; drop the legacy snowflake.
for unit in "${PAGING_OFF[@]}"; do
  # RESILIENT-1055: only neuter pagers that ACTUALLY EXIST on this box. A
  # role-scoped node never installs the primary-node pagers, so there is no unit
  # to neuter — skip rather than litter /etc/systemd/system with a .d/ drop-in
  # dir for a non-existent unit.
  "$SYSTEMCTL_BIN" cat "$unit" >/dev/null 2>&1 || continue
  dropin_dir="$SYSTEMD_DIR/${unit}.d"
  dropin="$dropin_dir/$DROPIN_NAME"
  want="$(dropin_body "$unit")"
  if [[ ! -f "$dropin" ]] || [[ "$(cat "$dropin" 2>/dev/null)" != "$want" ]]; then
    mkdir -p "$dropin_dir"
    printf '%s\n' "$want" > "$dropin"
    CHANGED+=("dropin:$unit")
    NEED_RELOAD=1
  fi
  # Remove tonight's host-only snowflake drop-in — end state is fully repo-declared.
  legacy="$dropin_dir/$LEGACY_DROPIN"
  if [[ -f "$legacy" ]]; then
    rm -f "$legacy"
    CHANGED+=("legacy-rm:$unit")
    NEED_RELOAD=1
  fi
done

if [[ "$NEED_RELOAD" == 1 ]]; then
  "$SYSTEMCTL_BIN" daemon-reload
fi

# Stop any pager still running so an in-flight page cycle halts. (Oneshot pagers
# are usually already inactive; this is the belt for the suspenders.)
for unit in "${PAGING_OFF[@]}"; do
  if "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null; then
    "$SYSTEMCTL_BIN" stop "$unit" 2>/dev/null || true
    CHANGED+=("stopped:$unit")
  fi
done

# 2) Enabled organs → per-node-applicable reconcile (RESILIENT-347).
#    a. Not applicable to this node (unmet `requires=`)? Skip — silently, no
#       churn, one advisory event. This is the blast-all -> curated-per-node
#       fix: the pre-347 reconcile tried `enable --now` on every `enabled`
#       line regardless of whether the node could ever run it.
#    b. Still cooling down from a prior verify failure? Skip — this is what
#       stops a structurally-broken organ (wrong binary/role/deps) from being
#       re-installed and re-failing every single cycle.
#    c. Otherwise enable --now, then VERIFY it is actually active a moment
#       later (not just that the systemctl call exited 0 — a oneshot unit can
#       "enable" fine and still fail inside ExecStart). A verify failure
#       disables the unit and starts a backoff cooldown instead of leaving it
#       to churn identically forever.
for unit in "${ENABLED[@]}"; do
  role="${ORGAN_ROLE[$unit]:-brain}"
  requires="${ORGAN_REQUIRES[$unit]:-}"
  reason=""

  if ! organ_is_applicable "$unit" "$requires" reason; then
    echo "SKIP (not applicable to this node): $unit ($reason)"
    # scanner-anchor: "kind":"organ_reconcile_not_applicable" (RESILIENT-347;
    # fires when an `enabled` organ's requires= are unmet on this node — the
    # curated-per-node skip that replaces blast-all install)
    emit organ_reconcile_not_applicable "\"unit\":\"$unit\",\"role\":\"$role\",\"reason\":\"$reason\""
    continue
  fi

  if organ_in_backoff "$unit"; then
    echo "SKIP (backed off, cooling down after a prior failure): $unit"
    # scanner-anchor: "kind":"organ_reconcile_backoff_skip" (RESILIENT-347;
    # fires when a previously-failed organ is still inside its backoff
    # cooldown — proof the reconcile is NOT re-churning it every cycle)
    emit organ_reconcile_backoff_skip "\"unit\":\"$unit\",\"role\":\"$role\""
    continue
  fi

  if "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null; then
    clear_backoff "$unit"
    continue
  fi

  if ! "$SYSTEMCTL_BIN" enable --now "$unit" 2>/dev/null; then
    echo "WARN: could not enable --now $unit" >&2
    # scanner-anchor: "kind":"organ_reconcile_unit_failed" (RESILIENT-305; an
    # organ the manifest marks `enabled` could not be enable --now'd)
    emit organ_reconcile_unit_failed "\"unit\":\"$unit\""
    record_backoff "$unit" "enable_failed"
    CHANGED+=("backoff:$unit")
    # scanner-anchor: "kind":"organ_reconcile_backoff" (RESILIENT-347; fires
    # when an applicable organ fails to enable/verify and the reconcile backs
    # it off instead of retrying it every cycle)
    emit organ_reconcile_backoff "\"unit\":\"$unit\",\"role\":\"$role\",\"reason\":\"enable_failed\""
    continue
  fi

  sleep "$VERIFY_DELAY_S"
  if "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null; then
    CHANGED+=("started:$unit")
    clear_backoff "$unit"
  else
    echo "WARN: $unit enabled but did not verify active — disabling + backing off" >&2
    "$SYSTEMCTL_BIN" disable --now "$unit" 2>/dev/null || true
    record_backoff "$unit" "verify_failed"
    CHANGED+=("backoff:$unit")
    emit organ_reconcile_backoff "\"unit\":\"$unit\",\"role\":\"$role\",\"reason\":\"verify_failed\""
  fi
done

# 3) Drift-REMOVAL pass (RESILIENT-1016 part a). Role-scoped reconcile only:
#    the loop above only ENABLES in-role manifest units, it never
#    disables/reaps units that are present-but-out-of-role (left behind by a
#    prior role install/switch) or no longer in the manifest at all — so
#    stray units persist and fail forever (VERIFIED on mugman: 28 leftover
#    out-of-role brain units stayed failed until hand-reaped, then 28->1).
#    This makes a role install (or role switch) self-cleaning: any chump
#    unit still active/enabled that is NOT in the role-filtered expected set
#    gets disabled --now + reset-failed. Unfiltered (whole-manifest)
#    reconciles skip this — there's nothing "out of role" to reap there.
if [[ -n "$ROLE_FILTER" ]]; then
  declare -A EXPECTED_UNIT
  for unit in "${ENABLED[@]}"; do EXPECTED_UNIT["$unit"]=1; done
  for unit in "${PAGING_OFF[@]}"; do EXPECTED_UNIT["$unit"]=1; done
  declare -A REAPED_BASE
  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    [[ -n "${EXPECTED_UNIT[$unit]:-}" ]] && continue
    # Sibling protection: never reap a unit whose paired .service OR .timer is
    # itself in the role-filtered expected set. The manifest declares most
    # organs by their .timer (e.g. `chump-farmer.timer`), so the paired
    # .service (`chump-farmer.service`) that the timer drives is in-role too and
    # must not be reaped just because it isn't literally in the manifest.
    base="${unit%.service}"; base="${base%.timer}"
    [[ -n "${EXPECTED_UNIT[${base}.timer]:-}" ]] && continue
    [[ -n "${EXPECTED_UNIT[${base}.service]:-}" ]] && continue
    # RESILIENT-1055: never reap node-local organs (worker/heartbeat/sentinel/
    # the reconcile's own beat) — chump-node-install installs them directly.
    # Reaping them was the FTUE-verified bug: a `--role muscle` reconcile
    # disabled the very worker + reconcile timer the bring-up had just started.
    organ_is_node_local "$unit" && continue
    [[ -n "${REAPED_BASE[$base]:-}" ]] && continue   # already reaped via its sibling
    organ_is_live "$unit" || continue
    echo "DRIFT-REMOVE: $unit is active/enabled/failed but out-of-role (not in role-filtered manifest) — disabling + reaping (with paired timer/service)"
    reap_unit_and_sibling "$unit"
    REAPED_BASE["$base"]=1
    CHANGED+=("removed:$unit")
    # scanner-anchor: "kind":"organ_reconcile_drift_removed" (RESILIENT-1016;
    # fires when a role-scoped reconcile disables+reaps a stray chump unit
    # that is present-but-out-of-role or no longer in the manifest at all —
    # the self-cleaning pass that replaces the 28-unit hand-reap on mugman)
    emit organ_reconcile_drift_removed "\"unit\":\"$unit\""
  done < <(discover_live_chump_units)
fi

# ── report ───────────────────────────────────────────────────────────────────
if [[ "${#CHANGED[@]}" -gt 0 ]]; then
  changed_json="$(printf '"%s",' "${CHANGED[@]}")"
  changed_json="[${changed_json%,}]"
  # scanner-anchor: "kind":"organ_reconcile_applied" (RESILIENT-305; fires only
  # when the reconcile actually changed live systemd state — the drift-healing
  # signal the board can verify)
  emit organ_reconcile_applied "\"changed\":$changed_json"
  echo "organ-reconcile: applied — ${CHANGED[*]}"
else
  # scanner-anchor: "kind":"organ_reconcile_noop" (RESILIENT-305; live state
  # already matched the manifest — the idempotent common path)
  emit organ_reconcile_noop
  echo "organ-reconcile: no-op — live state already matches organ-manifest.txt"
fi
