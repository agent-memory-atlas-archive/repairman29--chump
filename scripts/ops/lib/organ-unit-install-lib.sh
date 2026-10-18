#!/usr/bin/env bash
# scripts/ops/lib/organ-unit-install-lib.sh — RESILIENT-1055
#
# The ONE host-agnostic systemd-unit rewriter, shared by install-helsinki-atc.sh
# (the primary-node ATC roster placer) and chump-node-install.sh (the --role
# fresh-node bring-up placer). Before this lib, the host-rewrite sed logic lived
# ONLY inside install-helsinki-atc.sh, so a fresh `chump-node-install --role`
# never placed the role's tracked unit files at all — it only ran
# organ-reconcile's `systemctl enable --now`, which fails on a unit whose file
# was never copied into /etc/systemd/system (-> perpetual `backoff:` for every
# manifest organ that had no file on the box). Extracting the rewriter here lets
# the fresh-node installer PLACE the role roster from the same tracked source,
# host-rewritten identically, so `enable --now` finds a real unit.
#
# WHY host-rewrite at all (RESILIENT-353 / INFRA-3647 / RESILIENT-1051): the
# tracked units in scripts/dispatch/ are NOT all one shape — several are
# helsinki-shaped (User=root, HOME=/root, /root/.cargo) and several are
# CJ-native (User=jeff, /home/jeff/...). Verbatim-copying either shape onto a
# THIRD box (e.g. an ubuntu Oracle node, User=ubuntu, /home/ubuntu) installs a
# unit whose WorkingDirectory/HOME/User don't exist there -> CHDIR/127 every
# cycle, or (the "instruments lie" keystone) a bare `Environment=HOME=/root`
# that survives a naive prefix-rewrite and makes every tool read /root/.config.
# organ_unit_host_rewrite resolves each unit's placeholder template to this
# host and injects a uniform host-agnostic runtime context, so the SAME
# manifest wires correctly on any host. INFRA-8571 (Phase R R5 slice 3) retired
# the legacy source-home sed rules that used to PATCH a baked /Users/<name> or
# /home/<name> path: now that every tracked unit is a placeholder template (the
# no-host-literal gate holds the line), a literal reaching this rewriter is a
# regression and fails LOUDLY instead of being silently patched (which hid
# exactly that class of regression).

# organ_unit_host_rewrite <src-file> <dest-file> <run-user> <run-home> [keep_root] [repo_root] [scope]
#   Writes the host-rewritten unit from <src-file> to <dest-file>.
#   run-user / run-home: the box's repo-owning user + that user's real HOME.
#   keep_root (optional, "1"): force User=root even after the rewrite — for the
#     one narrow class of organs whose JOB is the privileged system-unit deploy
#     (chump-organ-deploy.*), which a de-privileged rewrite would break
#     (RESILIENT-374). Everything else runs as the repo-owning user.
#   repo_root (optional): the repo's ACTUAL checkout path on this host, baked
#     into every WorkingDirectory=/ExecStart=/cd/CHUMP_REPO_ROOT= that names the
#     repo. Historically the rewriter only prefix-swapped the source HOME and
#     PRESERVED the baked `Projects/chump` suffix, so an owned node whose repo
#     lives at $HOME/chump (NO Projects segment — the standard owned-iron layout)
#     got units pointing at a non-existent $HOME/Projects/chump and systemd
#     killed every organ at CHDIR (status=200/CHDIR) before it ran — the true
#     root of the fleet-wide "merged != running" disease (RESILIENT-1102). Pass
#     the real checkout root (install-helsinki-atc.sh -> $REPO_ROOT;
#     chump-node-install.sh -> $NODE_DIR/repo) so the paths resolve on any node.
#     Omitting it falls back to the legacy $HOME/Projects/chump assumption, so
#     pre-existing 5-arg callers keep their exact prior behavior.
#   scope (optional, default "system"): "user" when the unit is destined for
#     ~/.config/systemd/user (systemd --user, i.e. chump-node-install.sh). A
#     user-scope manager runs unprivileged and CANNOT switch identity, so ANY
#     User=/Group= line makes the unit die at spawn with
#     "Failed to determine supplementary groups: Operation not permitted" ->
#     status=216/GROUP, every tick, even when User= names the very user the
#     manager already runs as (RESILIENT-1571: 44 cuphead organs crash-looped,
#     incl. pr-shepherd and ci-health-gate, so the OS could not clear its own
#     stuck-PR backlog). In scope=user the rewriter therefore NEVER emits or
#     keeps a User=/Group= line, and keep_root is ignored (root cannot be
#     asserted from a user manager). "system" (install-helsinki-atc.sh, run as
#     root into /etc/systemd/system) is unchanged.
#   Returns non-zero if <src-file> is missing.
organ_unit_host_rewrite() {
  local src="$1" dest="$2" run_user="$3" run_home="$4" keep_root="${5:-0}" repo_root="${6:-}" scope="${7:-system}"
  [[ -f "$src" ]] || { echo "organ_unit_host_rewrite: missing src $src" >&2; return 1; }

  local repo_on_host="${repo_root:-${run_home%/}/Projects/chump}"
  repo_on_host="${repo_on_host%/}"

  # RESILIENT-1102 residue: collapse any symlink in the passed repo root to the
  # REAL on-disk checkout BEFORE baking it into the units. A bring-up may hand a
  # placer a symlinked repo path (e.g. the hand-bootstrapped
  # /home/ubuntu/Projects/chump -> /home/ubuntu/chump used to unwedge the
  # fleet-wide CHDIR jam): install-helsinki-atc.sh derives its REPO_ROOT with a
  # LOGICAL `pwd`, and organ-deploy passes CHUMP_REPO_ROOT verbatim, so the
  # symlink path flowed straight through this rewriter and every organ baked
  # WorkingDirectory=.../Projects/chump — keeping that bootstrap symlink
  # permanently load-bearing. Resolving here (the ONE chokepoint both placers
  # share) makes the units name the real checkout, so the symlink can be retired.
  # Only resolve a path that actually EXISTS on disk: the legacy no-repo_root
  # fallback ($HOME/Projects/chump) and the lib's synthetic-path unit tests pass
  # roots that may not exist, and must keep their exact prior (verbatim) behavior.
  if [[ -d "$repo_on_host" ]]; then
    repo_on_host="$(cd "$repo_on_host" 2>/dev/null && pwd -P || echo "$repo_on_host")"
  fi

  # INFRA-8571 (Phase R R5 slice 3): the source MUST be a placeholder template.
  # The legacy source-home rewrite rules that used to PATCH a baked /Users/<name>
  # or /home/<name> path (and a baked `User=<name>`) into the run host are gone;
  # with every tracked unit a placeholder template (the no-host-literal gate,
  # scripts/ci/test-provision-no-host-literals.sh), a literal reaching this
  # rewriter is a regression that must fail LOUDLY, not be silently patched —
  # patching is exactly what hid the regression before. The typed renderer
  # refuses the same template (crates/chump-provision::render ->
  # RenderError::HostLiterals); this is its shell mirror. Same four rules as
  # find_host_literals / the gate; a comment line (first non-blank char `#`, NOT
  # a `#!` shebang) executes nothing and is skipped, so an incident receipt in a
  # comment is fine. User= is injected below for system scope only — a template
  # never carries one.
  local _host_literals
  _host_literals="$(grep -nIE '(^|[^A-Za-z0-9_])User=[A-Za-z_]|/home/[a-z_]|/root/|/opt/homebrew' "$src" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#([^!]|$)' || true)"
  if [[ -n "$_host_literals" ]]; then
    {
      echo "organ_unit_host_rewrite: refusing $src — it carries a host literal (INFRA-8571)."
      echo "  Write a placeholder template (__HOME__ __REPO_ROOT__ __BIN_DIR__ __NODE_ENV__ __BREW_PREFIX__); User= is injected at system scope."
      echo "$_host_literals" | sed 's/^/    /'
    } >&2
    return 1
  fi

  # __BREW_PREFIX__ resolves through the shared host-path mirror
  # (scripts/lib/host-paths.sh, same rule as chump_provision::brew_prefix: the
  # Apple Silicon prefix only on a Mac that has it, /usr/local elsewhere). A copy
  # of this lib sourced on its own (synthetic tests) falls back to the non-Darwin
  # answer, which is what every systemd host gets anyway.
  local brew_prefix="/usr/local"
  if ! declare -F chump_brew_prefix >/dev/null 2>&1; then
    # shellcheck source=../../lib/host-paths.sh
    . "$(dirname "${BASH_SOURCE[0]}")/../../lib/host-paths.sh" 2>/dev/null || true
  fi
  if declare -F chump_brew_prefix >/dev/null 2>&1; then
    brew_prefix="$(chump_brew_prefix)"
  fi

  # Resolve the placeholder template to this host — the ONLY rewrites left
  # (INFRA-8571): placeholder-in, host-resolved-out, every host literal already
  # refused above. __REPO_ROOT__ gets the realpath-resolved checkout so a
  # bootstrap symlink is never baked in (RESILIENT-1102); it resolves exactly as
  # the typed renderer does (`chump node render-unit`; same tokens, same values).
  sed -e "s#__REPO_ROOT__#${repo_on_host}#g" \
      -e "s#__BIN_DIR__#${run_home%/}/.cargo/bin#g" \
      -e "s#__NODE_ENV__#${run_home%/}/.chump/node.env#g" \
      -e "s#__BREW_PREFIX__#${brew_prefix}#g" \
      -e "s#__HOME__#${run_home%/}#g" "$src" > "$dest"

  # Uniform host-agnostic runtime context for EVERY generated organ (one
  # pattern, not per-service): run as the repo-owning user (git/ssh/cargo), that
  # user's real HOME, ~/.cargo/bin on PATH, cwd at the repo root — so cwd-based
  # tools (chump gap, gh repo view) don't run from / and $HOME-based tools (gh,
  # almanac) read the run-user's config, on any host.
  if grep -q "^\[Service\]" "$dest"; then
    if [[ "$scope" != "user" ]]; then
      grep -q "^User=" "$dest"           || sed -i "/^\[Service\]/a User=${run_user}" "$dest"
    fi
    grep -q "^Environment=HOME=" "$dest" || sed -i "/^\[Service\]/a Environment=HOME=${run_home%/}" "$dest"
    grep -q "^WorkingDirectory=" "$dest" || sed -i "/^\[Service\]/a WorkingDirectory=${repo_on_host}" "$dest"
    grep -q "^Environment=PATH=" "$dest" || sed -i "/^\[Service\]/a Environment=PATH=${run_home%/}/.cargo/bin:/usr/local/bin:/usr/bin:/bin" "$dest"
    # INFRA-3632: every organ resolves the ONE canonical gap store via
    # ~/.chump/node.env (CHUMP_STATE_DIR/CHUMP_STATE_DB/CHUMP_TEAM_URL/
    # CHUMP_TEAM_API_KEY/CHUMP_STORE_BACKEND) instead of falling back to a
    # repo-local .chump/state.db. The leading `-` makes it optional so a box
    # mid-bootstrap (node.env not written yet) doesn't fail unit activation.
    grep -q "^EnvironmentFile=.*node\.env" "$dest" || sed -i "/^\[Service\]/a EnvironmentFile=-${run_home%/}/.chump/node.env" "$dest"
  fi

  # Operator-ordered organ oneshot timeout (2026-10-10): systemd gives a
  # Type=oneshot unit NO start timeout by default (TimeoutStartSec=infinity), so
  # one hung script wedged chump-organ-watchdog + the outcome-verify heal
  # consumer for 20+ min each, blocking the fleet's stay-on enforcement, and the
  # timer never re-fired (a timer cannot re-trigger a unit still "activating").
  # Every generated oneshot organ that does not already pin its OWN
  # TimeoutStartSec gets a bounded default here, so systemd kills a hung run and
  # the timer re-fires cleanly. Units with an explicit value (builds, drains)
  # keep it. Override the default with CHUMP_ORGAN_ONESHOT_TIMEOUT_S.
  if grep -q "^Type=oneshot" "$dest" && ! grep -q "^TimeoutStartSec=" "$dest"; then
    sed -i "/^\[Service\]/a TimeoutStartSec=${CHUMP_ORGAN_ONESHOT_TIMEOUT_S:-600}" "$dest"
  fi

  # RESILIENT-1571: a user-scope unit must carry no User=/Group= at all (see
  # the `scope` doc above). Strip whatever the tracked source baked in, AFTER
  # the injection block so nothing can re-add it, and BEFORE keep-root so a
  # keep_root request cannot resurrect it.
  if [[ "$scope" == "user" ]]; then
    sed -i -E '/^(User|Group)=/d' "$dest"
    return 0
  fi

  # RESILIENT-374: re-assert User=root for keep-root organs (the deploy organ).
  # Narrow, explicit, and the ONLY place a unit is forced back to root.
  if [[ "$keep_root" == "1" ]]; then
    if grep -q "^User=" "$dest"; then
      sed -i "s#^User=.*#User=root#" "$dest"
    else
      sed -i "/^\[Service\]/a User=root" "$dest"
    fi
  fi
  return 0
}

# organ_unit_execstart_resolves <rewritten-unit-file> <reason-var-name>
#
# RESILIENT-1508: before a placer `enable --now`s a just-rewritten unit, prove
# the binary its ExecStart invokes actually resolves on the PATH that unit
# itself carries — not the invoking installer's shell PATH, which routinely
# disagrees (an installer run as root with ~/.cargo/bin on ITS PATH will
# happily `command -v chump` even when the unit's own injected
# `Environment=PATH=` points at a user/home whose ~/.cargo/bin never got the
# binary symlinked in, e.g. a `User=root` unit left over from an abandoned
# /root/.chumpnode bring-up while the box's real, built binary lives under a
# different user's checkout). That exact drift produced four cuphead organs
# stuck at exit 127 ("exec: chump: not found") on every tick with no local
# signal until a human read the journal.
#
# Parses the unit's OWN `ExecStart=` line (handling both a direct
# `ExecStart=/path/to/bin ...` and the common
# `ExecStart=/bin/bash -c '...; exec <bin> ...'` wrapper), resolves a bare
# command name against the unit's own `Environment=PATH=` (falling back to
# the caller's PATH only when the unit sets none — matching systemd's own
# inherit-from-PID1 behavior), and an absolute/relative path directly via
# `-x`. Writes a short machine-parseable reason into the nameref target on
# failure. Returns 0 (resolves) / 1 (does not).
organ_unit_execstart_resolves() {
  local unit_file="$1" reason_var="$2"
  if [[ ! -f "$unit_file" ]]; then
    printf -v "$reason_var" 'unit_file_missing:%s' "$unit_file"; return 1
  fi

  local exec_line bin
  exec_line="$(grep -m1 '^ExecStart=' "$unit_file" || true)"
  if [[ -z "$exec_line" ]]; then
    printf -v "$reason_var" 'no_execstart'; return 1
  fi

  # Prefer the LAST `exec <word>` inside the command (the
  # `/bin/bash -c '...; exec chump ...'` wrapper shape every organ uses) —
  # that's the binary systemd's child process actually becomes. Fall back to
  # the first whitespace token of ExecStart itself for a direct invocation.
  # RESILIENT-1513: strip a trailing closing quote (`'` or `"`) off the
  # captured token. When `exec <bin>` is the LAST thing inside a
  # single-quoted `bash -c '...'` wrapper with no trailing args — exactly the
  # real chump-fleet-server.service shape, `exec .../chump-fleet-server'` —
  # the match's `[^ "]+` happily swallows that trailing `'` as part of the
  # path, so the `-x` test below always fails even once the binary is built.
  bin="$(printf '%s\n' "$exec_line" | grep -oE 'exec "?[^ "]+' | tail -1 | sed -E 's/^exec "?//')"
  if [[ -z "$bin" ]]; then
    bin="$(printf '%s\n' "${exec_line#ExecStart=}" | awk '{print $1}')"
  fi
  if [[ -z "$bin" ]]; then
    printf -v "$reason_var" 'cannot_parse_execstart'; return 1
  fi
  # RESILIENT-1513: strip a single trailing closing quote (' or "). When
  # `exec <bin>` is the LAST thing inside a single-quoted `bash -c '...'`
  # wrapper with no trailing args — exactly the real chump-fleet-server.service
  # shape, `exec .../chump-fleet-server'` — the match above happily swallows
  # that trailing quote as part of the path, so the `-x` test below would
  # always fail even once the binary is actually built.
  bin="${bin%\'}"
  bin="${bin%\"}"

  # Absolute or relative (contains a slash): resolve directly, no PATH search.
  if [[ "$bin" == */* ]]; then
    if [[ -x "$bin" ]]; then return 0; fi
    printf -v "$reason_var" 'binary_not_executable:%s' "$bin"; return 1
  fi

  local unit_path
  unit_path="$(grep -m1 '^Environment=PATH=' "$unit_file" | sed -E 's/^Environment=PATH=//')"
  [[ -z "$unit_path" ]] && unit_path="$PATH"

  local dir IFS=':'
  for dir in $unit_path; do
    [[ -n "$dir" && -x "$dir/$bin" ]] && return 0
  done
  printf -v "$reason_var" 'missing_bin_on_unit_path:%s' "$bin"
  return 1
}

# organ_unit_run_user <repo-root> — the box's repo-owning user (git/ssh/cargo
# identity) that units should run as. Mirrors install-helsinki-atc.sh's
# CHUMP_RUN_USER derivation so both placers agree on the host identity.
organ_unit_run_user() {
  local repo_root="$1"
  echo "${CHUMP_RUN_USER:-$(stat -c %U "$repo_root" 2>/dev/null || echo root)}"
}

# organ_unit_run_home <run-user> — that user's real HOME (passwd), falling back
# to /home/<user>.
organ_unit_run_home() {
  local run_user="$1" h
  h="$(getent passwd "$run_user" 2>/dev/null | cut -d: -f6 || true)"
  [[ -z "$h" ]] && h="/home/$run_user"
  echo "$h"
}
