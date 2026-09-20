#!/usr/bin/env bash
# scripts/ops/lib/organ-manifest-lib.sh — TREK-18 (INFRA-3644), platforms= INFRA-7764
#
# The ONE parser for scripts/ops/organ-manifest.txt, shared by
# organ-reconcile.sh (which converges live systemd state to the manifest)
# and install-helsinki-atc.sh (which now derives its installed roster FROM
# the manifest instead of a second, hand-maintained array). Before this gap,
# the installer's SYSTEM_TIMERS array and the manifest were two independent
# sources of truth — adding an organ to the manifest was NOT sufficient to
# get it installed (chump-conflict-resolution-consumer.timer and
# chump-gap-closure-reconcile.timer were both `enabled` in the manifest but
# absent from the installer's roster until this fix), and RESILIENT-366 had
# to add a standalone CI test just to catch the inverse drift. One parser
# feeding both call sites makes that whole drift class structurally
# impossible instead of separately detected.
#
# Format is documented in scripts/ops/organ-manifest.txt's header comment.
#
# INFRA-7764 (docs/strategy/ONE_COMMAND_INSTALL.md section 1, slice A of the
# one-command-install BOM unification, INFRA-7756): `enabled` lines may also
# carry a `platforms=SYSTEM,SYSTEM,...` token (comma-separated, values
# systemd|launchd|runit). Omitted means `platforms=systemd` — today's
# implicit assumption for every pre-existing line, so nothing regresses.
# This lets organ-manifest.txt absorb bootstrap-manifest.yaml's macOS-only
# capabilities and install-node-housekeeping.sh's roster as ordinary lines
# (`platforms=launchd` / `platforms=systemd` respectively) without a second
# format — the single declared roster every supervisor renders from. Callers
# that don't care about platforms (the 5-arg organ_manifest_parse call) are
# unaffected; a 6th nameref arg opts in to receiving the per-unit platforms
# string so a caller can filter ENABLED to units applicable to the CURRENT
# host (see organ_platform_matches / organ_current_platform below).

# organ_manifest_parse <manifest-file> <paging_off-array-name> <enabled-array-name> <role-assoc-array-name> <requires-assoc-array-name> [<platforms-assoc-array-name>]
#
# Populates the caller-provided array names (via nameref) from the manifest
# file. Caller must declare them first (any prior contents are cleared). The
# 6th (platforms) array name is OPTIONAL — omitting it preserves the original
# 5-arg call signature verbatim for existing callers. Returns 1 (and prints
# an error) if the manifest file is missing.
organ_manifest_parse() {
  local manifest="$1"
  local -n _omp_paging_off="$2"
  local -n _omp_enabled="$3"
  local -n _omp_role="$4"
  local -n _omp_requires="$5"
  local _omp_have_platforms=0
  if [[ $# -ge 6 && -n "${6:-}" ]]; then
    local -n _omp_platforms="$6"
    _omp_have_platforms=1
    _omp_platforms=()
  fi

  _omp_paging_off=()
  _omp_enabled=()
  _omp_role=()
  _omp_requires=()

  if [[ ! -f "$manifest" ]]; then
    echo "ERROR: manifest not found: $manifest" >&2
    return 1
  fi

  local state unit rest role requires platforms tok
  while read -r state unit rest; do
    [[ -z "${state:-}" ]] && continue
    [[ "$state" == \#* ]] && continue
    role="" requires="" platforms=""
    for tok in $rest; do
      case "$tok" in
        role=*)      role="${tok#role=}" ;;
        requires=*)  requires="${tok#requires=}" ;;
        platforms=*) platforms="${tok#platforms=}" ;;
      esac
    done
    case "$state" in
      paging_off) _omp_paging_off+=("$unit") ;;
      enabled)
        _omp_enabled+=("$unit")
        _omp_role["$unit"]="${role:-brain}"
        _omp_requires["$unit"]="$requires"
        if [[ "$_omp_have_platforms" == 1 ]]; then
          _omp_platforms["$unit"]="${platforms:-systemd}"
        fi
        ;;
      *) echo "WARN: unknown state '$state' for '$unit' in manifest; ignoring" >&2 ;;
    esac
  done < "$manifest"
  return 0
}

# organ_current_platform -> echoes this host's supervisor: systemd|launchd|runit.
# Shared detection so every caller (organ-reconcile.sh, a future launchd/runit
# renderer) agrees on what "this platform" means. Termux (runit) is checked
# first since it also reports uname=Linux; Darwin is launchd; everything else
# with systemd unit tooling present is systemd — the pre-INFRA-7764 default
# assumption, kept as the fallback so an environment with neither detector
# (e.g. a minimal CI container) still resolves to the historical behavior.
organ_current_platform() {
  # CHUMP_ORGAN_MANIFEST_PLATFORM: explicit override, mainly for tests that
  # need to exercise a launchd/runit filtering path without actually running
  # on that OS. Real hosts never need to set this.
  if [[ -n "${CHUMP_ORGAN_MANIFEST_PLATFORM:-}" ]]; then
    echo "${CHUMP_ORGAN_MANIFEST_PLATFORM}"
    return 0
  fi
  if [[ -n "${PREFIX:-}" ]] && printf '%s' "${PREFIX:-}" | grep -q com.termux; then
    echo runit
  elif [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    echo launchd
  else
    echo systemd
  fi
}

# organ_platform_matches <platforms-csv> <current-platform>
#
# Is <current-platform> among the comma-separated <platforms-csv>? An empty
# csv means "systemd only" (the implicit default every pre-INFRA-7764 line
# carries), matching organ_manifest_parse's own `${platforms:-systemd}`
# default so the two never disagree.
organ_platform_matches() {
  local csv="${1:-}" current="${2:-}"
  [[ -z "$csv" ]] && csv="systemd"
  local IFS=',' tok
  for tok in $csv; do
    [[ "$tok" == "$current" ]] && return 0
  done
  return 1
}

# organ_is_applicable <unit> <requires-string> <reason-var-name>
#
# RESILIENT-347 / RESILIENT-1055: is <unit> applicable to THIS node given its
# declared `requires=` spec (comma-separated bin:/env:/dep:/file: tokens, see
# organ-manifest.txt's header)? Empty/absent requires means "always applicable".
# Writes the first unmet reason into the nameref target (via printf -v) for the
# caller to log/emit. Lives HERE (shared) so organ-reconcile.sh and
# organ-role-roster.sh compute applicability identically — no drift. Uses
# ${SYSTEMCTL_BIN:-systemctl} so a caller can stub systemctl in tests.
organ_is_applicable() {
  local unit="$1" requires="$2" reason_var="$3"
  [[ -z "$requires" ]] && return 0
  local systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
  local tok IFS=','
  for tok in $requires; do
    case "$tok" in
      bin:*)
        local bin="${tok#bin:}"
        if ! command -v "$bin" >/dev/null 2>&1; then
          printf -v "$reason_var" 'missing_bin:%s' "$bin"; return 1
        fi
        ;;
      env:*)
        local var="${tok#env:}"
        if [[ -z "${!var:-}" ]]; then
          printf -v "$reason_var" 'missing_env:%s' "$var"; return 1
        fi
        ;;
      dep:*)
        local dep="${tok#dep:}"
        if ! "$systemctl_bin" is-active --quiet "$dep" 2>/dev/null; then
          printf -v "$reason_var" 'missing_dep:%s' "$dep"; return 1
        fi
        ;;
      file:*)
        # An organ that only APPLIES where a host-specific asset exists (chiefly
        # the CJ-legacy hand-installed chump-cj-* units, whose ExecStart points
        # at a /home/<user>/cj-*-run.sh that exists only on that one box and has
        # no tracked unit file — so a fresh `--role` bring-up must SKIP them, not
        # `enable --now` a file-less unit into an eternal backoff). A leading ~/
        # or $HOME/ expands against the effective HOME.
        local path="${tok#file:}"
        case "$path" in
          '~/'*)      path="${HOME:-/root}/${path#\~/}";;
          '$HOME/'*)  path="${HOME:-/root}/${path#\$HOME/}";;
        esac
        if [[ ! -e "$path" ]]; then
          printf -v "$reason_var" 'missing_file:%s' "$path"; return 1
        fi
        ;;
      *)
        printf -v "$reason_var" 'unknown_requires_spec:%s' "$tok"; return 1
        ;;
    esac
  done
  return 0
}

# organ_role_filter_for <role> -> echoes the comma-separated organ-manifest role=
# tags a node with that --role should carry (RESILIENT-746 / RESILIENT-1083).
# Shared by chump-node-install.sh (install-time scoping) and organ-reconcile.sh
# (recurring self-scope from ~/.chump/node.env's CHUMP_NODE_ROLE). Keep in sync
# with chump-node-install.sh's organ_role_filter(). brain = coordination /
# registry / reporting (everything the manifest does not tag muscle); muscle =
# the worker/ship-code organs only; all / empty = whole manifest (no scoping).
organ_role_filter_for() {
  case "${1:-}" in
    brain)   echo "brain,data,janitor,trust";;
    muscle)  echo "muscle";;
    all|"")  echo "";;
    *)       echo "";;
  esac
}
