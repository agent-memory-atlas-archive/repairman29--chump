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
# organ_unit_host_rewrite detects each unit's OWN baked-in source user and
# rewrites THAT home, then injects a uniform host-agnostic runtime context, so
# the SAME manifest wires correctly on any host.

# organ_unit_host_rewrite <src-file> <dest-file> <run-user> <run-home> [keep_root] [repo_root]
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
#   Returns non-zero if <src-file> is missing.
organ_unit_host_rewrite() {
  local src="$1" dest="$2" run_user="$3" run_home="$4" keep_root="${5:-0}" repo_root="${6:-}"
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

  # Detect the unit's OWN baked-in source user (its `User=` line; default root
  # when absent, matching the historical helsinki shape) and rewrite THAT home.
  local src_user src_home
  src_user="$(grep -m1 -E '^User=' "$src" | cut -d= -f2 || true)"
  [[ -z "$src_user" ]] && src_user="root"
  if [[ "$src_user" == "root" ]]; then
    src_home="/root"
  else
    src_home="$(getent passwd "$src_user" 2>/dev/null | cut -d: -f6 || true)"
    [[ -z "$src_home" ]] && src_home="/home/$src_user"
  fi

  # s#$SRC_HOME/Projects/chump#$REPO_ON_HOST#g -> the repo path itself, wherever
  #   it appears (WorkingDirectory=, ExecStart=, an inline `cd …`, CHUMP_REPO_ROOT=,
  #   a PATH entry). It runs FIRST — BEFORE the home-prefix swap — so the whole
  #   baked repo path is redirected to this box's ACTUAL checkout, not merely
  #   home-prefix-swapped into a $HOME/Projects/chump that may not exist on an
  #   owned node (the 200/CHDIR root, RESILIENT-1102). `chump` is always a
  #   complete path segment here (the char after it is always /, ;, ), ", space,
  #   or EOL — never `chumpX`), so a plain global swap cannot over-match a
  #   sibling token. Assumes run-user == REPO_ROOT's owner (both placers derive
  #   run-user via stat %U of the checkout), so the later home-swap never re-hits
  #   $REPO_ON_HOST.
  # s#$SRC_HOME/#...#g  -> remaining path PREFIXES ($SRC_HOME/.chump, $SRC_HOME/.cargo, …)
  # s#=$SRC_HOME$#...#  -> a BARE $SRC_HOME as the WHOLE value of an assignment
  #                       (chiefly `Environment=HOME=/root`, no trailing slash).
  # s#^User=$SRC_USER$# -> the User= line itself.
  sed -e "s#${src_home%/}/Projects/chump#${repo_on_host}#g" \
      -e "s#${src_home%/}/#${run_home%/}/#g" \
      -e "s#=${src_home%/}\$#=${run_home%/}#" \
      -e "s#^User=${src_user}\$#User=${run_user}#" "$src" > "$dest"

  # Uniform host-agnostic runtime context for EVERY generated organ (one
  # pattern, not per-service): run as the repo-owning user (git/ssh/cargo), that
  # user's real HOME, ~/.cargo/bin on PATH, cwd at the repo root — so cwd-based
  # tools (chump gap, gh repo view) don't run from / and $HOME-based tools (gh,
  # almanac) read the run-user's config, on any host.
  if grep -q "^\[Service\]" "$dest"; then
    grep -q "^User=" "$dest"             || sed -i "/^\[Service\]/a User=${run_user}" "$dest"
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
