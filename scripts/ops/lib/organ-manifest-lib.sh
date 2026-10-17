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

# organ_manifest_parse <manifest-file> <paging_off-array-name> <enabled-array-name> <role-assoc-array-name> <requires-assoc-array-name> [<platforms-assoc-array-name>] [<node-assoc-array-name>] [<run-scope-assoc-array-name>]
#
# Populates the caller-provided array names (via nameref) from the manifest
# file. Caller must declare them first (any prior contents are cleared). The
# 6th (platforms) and 7th (node) array names are OPTIONAL — omitting either
# preserves the original 5-arg call signature verbatim for existing callers.
# Returns 1 (and prints an error) if the manifest file is missing.
#
# RESILIENT-1535: `enabled` lines may also carry a `node=NAME,NAME,...`
# token (comma-separated hostnames). Omitted means "any node" — the
# implicit default every pre-existing line carries, so nothing regresses.
# This is distinct from `platforms=` (which scopes by OS/supervisor): `node=`
# scopes an organ to the specific owned machine(s) it is installed on (e.g.
# CJ's chump-cj-worker.service, or chump-postgrest.service which per
# RESILIENT-1057 only ever runs on the gap-substrate's host) so a hub node
# that merely LACKS that organ's node-local binary/file does not report it
# as an unexplained dark organ (see organ_dark_cause below).
#
# INFRA-8194 (Phase R R5): `enabled` lines may also carry `run-scope=user|
# system|any`. Omitted means `any` (every pre-existing line), so nothing
# regresses. It names the systemd manager scope an organ can actually work in:
# `system` for organs whose job needs root (chump-organ-deploy writes
# /etc/systemd/system), `user` for organs that only exist in a --user manager.
# The 8th (optional) nameref receives it; installers skip a unit whose
# run-scope does not match the scope they install into, with a logged reason
# (organ_run_scope_matches below), instead of placing a unit that can only
# fail there. The host's scope comes from the typed Host enum
# (`chump node host --field run-scope`, crates/chump-provision).
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
  local _omp_have_node=0
  if [[ $# -ge 7 && -n "${7:-}" ]]; then
    local -n _omp_node="$7"
    _omp_have_node=1
    _omp_node=()
  fi
  local _omp_have_scope=0
  if [[ $# -ge 8 && -n "${8:-}" ]]; then
    local -n _omp_scope="$8"
    _omp_have_scope=1
    _omp_scope=()
  fi

  _omp_paging_off=()
  _omp_enabled=()
  _omp_role=()
  _omp_requires=()

  if [[ ! -f "$manifest" ]]; then
    echo "ERROR: manifest not found: $manifest" >&2
    return 1
  fi

  local state unit rest role requires platforms node runscope tok
  while read -r state unit rest; do
    [[ -z "${state:-}" ]] && continue
    [[ "$state" == \#* ]] && continue
    role="" requires="" platforms="" node="" runscope=""
    for tok in $rest; do
      # RESILIENT-1534: a trailing `# ...` comment is NOT part of the directive.
      # Several rows quote field names in their comments (e.g. "platforms= stays
      # launchd-only"), and without this break that stray token overwrote the real
      # field — chump-mission-grade.timer's `platforms=launchd` became `platforms=`
      # (empty -> default systemd), so the reconcile tried to enable a unit that only
      # exists at --user scope and the organ sat permanently dark.
      [[ "$tok" == \#* ]] && break
      case "$tok" in
        role=*)      role="${tok#role=}" ;;
        requires=*)  requires="${tok#requires=}" ;;
        platforms=*) platforms="${tok#platforms=}" ;;
        node=*)      node="${tok#node=}" ;;
        run-scope=*) runscope="${tok#run-scope=}" ;;
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
        if [[ "$_omp_have_node" == 1 ]]; then
          _omp_node["$unit"]="$node"
        fi
        if [[ "$_omp_have_scope" == 1 ]]; then
          _omp_scope["$unit"]="${runscope:-any}"
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

# organ_current_run_scope -> echoes this host's systemd manager scope: user|system.
# INFRA-8194: the typed Host enum is the source of truth (`chump node host
# --field run-scope`); the euid fallback mirrors its rule (root -> system,
# anyone else -> user) for an installer running before the binary exists.
organ_current_run_scope() {
  # CHUMP_ORGAN_MANIFEST_RUN_SCOPE: explicit override for tests and for an
  # installer that already knows which manager it writes into.
  if [[ -n "${CHUMP_ORGAN_MANIFEST_RUN_SCOPE:-}" ]]; then
    echo "${CHUMP_ORGAN_MANIFEST_RUN_SCOPE}"
    return 0
  fi
  local _s=""
  if command -v chump >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      _s="$(timeout 10 chump node host --field run-scope 2>/dev/null </dev/null || true)"
    else
      _s="$(chump node host --field run-scope 2>/dev/null </dev/null || true)"
    fi
  fi
  case "$_s" in
    user|system) echo "$_s"; return 0;;
  esac
  if [[ "$(id -u 2>/dev/null)" == "0" ]]; then echo system; else echo user; fi
}

# organ_run_scope_matches <run-scope> <current-scope>
#
# Does a manifest run-scope (user|system|any; empty = any) allow installing at
# <current-scope>? `any` matches everything, so every pre-INFRA-8194 line is
# unaffected.
organ_run_scope_matches() {
  local want="${1:-any}" current="${2:-}"
  [[ -z "$want" || "$want" == "any" ]] && return 0
  [[ "$want" == "$current" ]]
}

# organ_current_node -> echoes this host's short hostname. Shared detection so
# every caller (organ-reconcile.sh, organ-deploy.sh's audit) agrees on what
# "this node" means for a manifest `node=` scope (RESILIENT-1535).
organ_current_node() {
  # CHUMP_ORGAN_MANIFEST_NODE: explicit override, mainly for tests that need
  # to exercise node-scoped filtering without actually running on that host.
  if [[ -n "${CHUMP_ORGAN_MANIFEST_NODE:-}" ]]; then
    echo "${CHUMP_ORGAN_MANIFEST_NODE}"
    return 0
  fi
  hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown
}

# organ_node_matches <node-csv> <current-node>
#
# Is <current-node> among the comma-separated <node-csv>? An empty csv means
# "any node" (the implicit default every node-agnostic line carries) — unlike
# organ_platform_matches, there is no default-restrict here: node= is an
# opt-in scope, only entries that NAME a node are restricted to it.
organ_node_matches() {
  local csv="${1:-}" current="${2:-}"
  [[ -z "$csv" ]] && return 0
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

# organ_dark_cause <unit> <platforms-csv> <requires> <current-platform> <repo-root> [<systemd-dir>] [<node-csv>] [<current-node>]
#
# RESILIENT-1534: name WHY an `enabled` manifest organ is not running, so a dark
# organ is never an unexplained "no-op". Echoes exactly one token:
#   active                        systemctl says it is active
#   scoped-off:platforms=<csv>    manifest scopes it off this platform (EXPECTED dark,
#                                 e.g. a launchd-only Mac organ on a systemd hub)
#   scoped-off:node=<csv>         manifest scopes it to a different owned node (EXPECTED
#                                 dark on every other node; RESILIENT-1535 — e.g.
#                                 chump-postgrest.service, dormant-by-design and only
#                                 ever installed on closetjunky, no longer reads as
#                                 dark on the hub)
#   unmet-requires:<reason>       a requires= precondition fails (missing_bin:gh, ...)
#   unit-missing                  no unit file for it in scripts/dispatch/ (never shipped)
#   unit-not-installed            the repo has the unit, the node's systemd dir does not
#   exec-missing:<path>           its service's ExecStart script is not in the repo
#   inactive                      unit + deps all present, still not active (a real fault)
# Everything except `active` and `scoped-off:*` is an UNEXPECTED dark organ.
# Uses ${SYSTEMCTL_BIN:-systemctl} (stub-able). <systemd-dir> defaults to
# /etc/systemd/system. <node-csv> (the manifest's node= scope for this unit,
# empty if node-agnostic) and <current-node> (defaults to organ_current_node())
# are both optional so pre-RESILIENT-1535 callers are unaffected.
organ_dark_cause() {
  local unit="$1" platforms="$2" requires="$3" current="$4" repo="$5"
  local sysdir="${6:-/etc/systemd/system}"
  local node="${7:-}"
  local current_node="${8:-$(organ_current_node)}"
  local systemctl_bin="${SYSTEMCTL_BIN:-systemctl}"
  if "$systemctl_bin" is-active --quiet "$unit" 2>/dev/null; then echo active; return 0; fi
  if ! organ_platform_matches "$platforms" "$current"; then
    echo "scoped-off:platforms=${platforms:-systemd}"; return 0
  fi
  if [[ -n "$node" ]] && ! organ_node_matches "$node" "$current_node"; then
    echo "scoped-off:node=${node}"; return 0
  fi
  local reason=""
  if ! organ_is_applicable "$unit" "$requires" reason; then
    echo "unmet-requires:$reason"; return 0
  fi
  local unitfile="$repo/scripts/dispatch/$unit"
  if [[ ! -f "$unitfile" ]]; then echo unit-missing; return 0; fi
  if [[ ! -f "$sysdir/$unit" ]]; then echo unit-not-installed; return 0; fi
  # A .timer fires its same-named .service; that is where ExecStart lives.
  local svc="$unitfile"
  [[ "$unit" == *.timer ]] && svc="$repo/scripts/dispatch/${unit%.timer}.service"
  if [[ -f "$svc" ]]; then
    local exec_path
    exec_path="$(grep -E '^ExecStart=' "$svc" 2>/dev/null | head -1 | grep -oE '[^ "'"'"']*scripts/[^ "'"'"']+\.(sh|py)' | head -1)"
    if [[ -n "$exec_path" && ! -f "$repo/scripts/${exec_path#*scripts/}" ]]; then
      echo "exec-missing:scripts/${exec_path#*scripts/}"; return 0
    fi
  fi
  echo inactive
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
    # RESILIENT-320: capacity roles. Tags are broad; organ_role_units_for
    # narrows to the exact unit roster.
    factory|data|embed) echo "brain,data,janitor,trust,muscle";;
    all|"")  echo "";;
    *)       echo "";;
  esac
}

# organ_role_units_for <role> -> space-separated manifest unit names a capacity
# role (RESILIENT-320: factory|data|embed) installs. Empty for brain/muscle/all
# (those are scoped by role tag alone). A unit absent from the manifest is simply
# never matched, so the roster can name organs that only exist on some hosts.
#   factory = workers + pr-lander + reapers + integrator + orchestrator +
#             disk-monitor + main-health-watchdog
#   data    = orchestrator + disk-monitor + main-health-watchdog + postgres(t);
#             NO pr-lander / PR reapers
#   embed   = orchestrator + disk-monitor
organ_role_units_for() {
  local _common="chump-node-orchestrator.service chump-disk-monitor.service"
  case "${1:-}" in
    factory) echo "chump-cj-worker.service chump-pr-lander.timer chump-integrator.timer chump-rot-reaper.timer chump-stale-worktree-reaper.timer chump-cargo-target-reaper.timer chump-worktree-reaper.service chump-main-health-watchdog.service $_common";;
    data)    echo "$_common chump-main-health-watchdog.service chump-postgrest.service";;
    embed)   echo "$_common";;
    *)       echo "";;
  esac
}

# organ_worker_count <cores> <runs_embeds 0|1> -> worker count for a factory
# node: clamp(1, cores-1), minus 1 if the node also runs embeds (floor 1).
# CJ (4 cores + embeds) -> 2.
organ_worker_count() {
  local cores="${1:-1}" embeds="${2:-0}"
  [ "$cores" -ge 1 ] 2>/dev/null || cores=1
  local n=$(( cores - 1 ))
  [ "$n" -lt 1 ] && n=1
  [ "$embeds" = 1 ] && n=$(( n - 1 ))
  [ "$n" -lt 1 ] && n=1
  echo "$n"
}
