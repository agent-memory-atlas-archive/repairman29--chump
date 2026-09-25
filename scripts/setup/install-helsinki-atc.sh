#!/usr/bin/env bash
# scripts/setup/install-helsinki-atc.sh — RESILIENT-300, auto-deploy path INFRA-3593
#
# Establishes the full "ATC roster" on the primary node (helsinki) from a
# fresh clone: the self-maintenance daemons that keep the shipping pipeline
# moving without an agent having to remember them:
#
#   chump-pr-lander      (RESILIENT-288) — arms green-but-unarmed PRs so they merge
#   chump-armed-rebaser  (INFRA-3473)    — rebases armed PRs that drift BEHIND/DIRTY
#   chump-rot-reaper     (RESILIENT-324) — closes CONFLICTING+old PRs (which the
#                                           rebaser CANNOT rebase) + re-queues
#                                           their gaps, so the back-pressure
#                                           breaker can never deadlock in the
#                                           4–5 hysteresis dead-zone
#   chump-node-refresh   (RESILIENT-200) — keeps the installed chump binary current
#   chump-board-cycle    (INFRA-3590)    — Sonnet board-cycle agent: SLA score +
#                                           stall classify + Discord report, zero
#                                           desktop session required
#   chump-sla-scorecard  (RESILIENT-302) — flags PRs open >30m unmerged with no
#                                           owner as a board BREACH
#   chump-organ-watchdog (INFRA-3595)    — self-heals any failed chump-*
#                                           organ (reset-failed + restart), no
#                                           human step required
#   chump-board-ceo-briefing (INFRA-3601) — board strategy layer: one thing,
#                                           bottleneck, operator-only
#                                           decisions, on-mission drift check,
#                                           on boot + hourly. Distinct from
#                                           chump-board-cycle (the ops SLA
#                                           scorecard, which watches the
#                                           factory) — this watches the
#                                           mission.
#   chump-organ-reconcile (RESILIENT-305) — converges live systemd organ state
#                                           to the repo-declared manifest
#                                           (scripts/ops/organ-manifest.txt):
#                                           enables the organs that must run and
#                                           neuters the auto-pagers that must
#                                           stay OFF. Runs on a timer so drift
#                                           between the repo and the node self-
#                                           heals — including a pager this very
#                                           installer just re-enabled.
#
# Before RESILIENT-300, these were live-hacked directly into /etc/systemd/system
# and ~/.config/systemd/user — a node rebuild silently lost ATC. This script is
# the single, idempotent entrypoint that re-establishes the whole roster from
# tracked repo files.
#
# pr-lander, armed-rebaser, sla-scorecard, board-cycle, organ-watchdog,
# board-ceo-briefing are SYSTEM units
# (root-owned, /etc/systemd/system) — this script must run as root (or via
# sudo). node-refresh is a USER unit (systemd --user) — installed by
# delegating to install-node-refresh-systemd.sh.
#
# Idempotent: safe to re-run any time (e.g. after a node rebuild, or to pick up
# unit-file changes) — copies + daemon-reload + enable --now every time.
#
# INFRA-3593: this is also the AUTO-DEPLOY entrypoint. node-refresh-chump.sh
# (RESILIENT-200) calls this script with --auto after every fast-forward to
# origin/main, so a merge that touches a chump-*.service/.timer file installs
# on helsinki with no human step — mirroring how node-refresh already
# auto-deploys binary changes. --auto diffs each tracked unit file against
# what's live in /etc/systemd/system BEFORE copying, and emits
# kind=organ_units_deployed (listing only the units that actually changed)
# so the board can verify the auto-deploy ran (AC 7). If nothing changed, it
# emits kind=organ_units_deploy_skipped instead — quiet on the common path,
# but still observable that the check happened (INFRA-3593 AC 1/7).
# --auto degrades to a warning (not a hard failure) when not root, since it
# may be invoked from a non-privileged refresh context — see
# kind=organ_units_deploy_failed reason=not_root.
#
# Usage:
#   sudo bash scripts/setup/install-helsinki-atc.sh
#   sudo bash scripts/setup/install-helsinki-atc.sh --check   # exit 0 iff all timers active
#   bash scripts/setup/install-helsinki-atc.sh --auto         # merge-triggered auto-deploy

set -euo pipefail

# pwd -P (physical) not the logical pwd: organ-deploy invokes this installer via
# a symlinked path (the hand-bootstrapped /home/ubuntu/Projects/chump ->
# /home/ubuntu/chump), and a logical pwd would preserve that symlink in REPO_ROOT
# — which then gets baked into every organ's WorkingDirectory/ExecStart, keeping
# the bootstrap symlink permanently load-bearing (RESILIENT-1102 residue). The
# organ-unit test computes its own REPO_ROOT with pwd -P for the same reason.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd -P)"
AMBIENT_LOG="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
LIB_AMBIENT="$REPO_ROOT/scripts/coord/lib/ambient-write.sh"
[[ -f "$LIB_AMBIENT" ]] && source "$LIB_AMBIENT"
# RESILIENT-1055: the ONE host-agnostic unit rewriter, shared with
# chump-node-install.sh's fresh-node --role placer. Extracted verbatim from the
# inline rewrite this script used to carry (byte-identical output, guarded by
# scripts/ci/test-organ-unit-install-lib.sh) so both placers can never drift.
LIB_ORGAN_UNIT="$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh"
[[ -f "$LIB_ORGAN_UNIT" ]] && source "$LIB_ORGAN_UNIT"

emit() {  # kind, extra-json (no leading/trailing comma)
  local kind="$1" extra="${2:-}"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
  else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
  if command -v _ambient_write >/dev/null 2>&1; then
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && _ambient_write "$AMBIENT_LOG" "$line"
  else
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
  fi
}

SYSTEM_UNITS=(
  chump-pr-lander.service
  chump-pr-lander.timer
  # RESILIENT-1054/1055: chump-armed-rebaser is REMOVED from the roster. The
  # cross-node rebaser swarm (armed-rebaser / armed-pr-rebaser / pr-auto-rebase)
  # caused the merge-race — multiple nodes rebasing armed PRs reset each other's
  # `verified`. chump-merge-serializer.timer is the SOLE merge driver now. The
  # tracked scripts/dispatch/chump-armed-rebaser.{service,timer} files remain in
  # the tree (nothing references them) but are neither copied nor enabled here.
  chump-board-cycle.service
  chump-board-cycle.timer
  chump-sla-scorecard.service
  chump-sla-scorecard.timer
  chump-organ-watchdog.service
  chump-organ-watchdog.timer
  # RESILIENT-1098: apex watchdog-of-the-watchdog — cross-node peer heartbeat
  # check. Watches OTHER nodes, not this one, so a whole-node wedge (this
  # node's own organ-watchdog/organ-reconcile dead) is still caught by a peer.
  chump-apex-watchdog.service
  chump-apex-watchdog.timer
  chump-board-ceo-briefing.service
  chump-board-ceo-briefing.timer
  # RESILIENT-376: the Discord digest organ — twice-daily phone-readable
  # factory pulse to the operator DM. SYSTEM unit so it survives the
  # deploy-mirror reset and boots on a fresh node.
  chump-digest.service
  chump-digest.timer
  chump-organ-reconcile.service
  chump-organ-reconcile.timer
  chump-pr-approval.service
  chump-pr-approval.timer
  # RESILIENT-313: the persistent farmer runner — keeps the worker-gate heartbeat
  # fresh every 30s so the fleet never silently darks out. Retires the transient
  # chump-farmer-bridge hack.
  chump-farmer.service
  chump-farmer.timer
  # RESILIENT-324: the rot-reaper — drains CONFLICTING+old PRs the armed-rebaser
  # can't rebase, so the back-pressure breaker never deadlocks in the 4–5
  # hysteresis dead-zone. Shipped as part of the ATC roster so `run the install`
  # boots a fresh node WITH auto-draining (RUN-INSTALL mission).
  chump-rot-reaper.service
  chump-rot-reaper.timer
  # RESILIENT-1190: the trunk-recovery reviver — the RECOVERY counterpart to
  # RESILIENT-1188's systemic-red HOLD. On a trunk RED→GREEN recovery it reopens
  # the PRs that were reaped as victims of the just-ended trunk-red (closed
  # in-window, reaper-marked, green-underneath now) and re-arms their
  # auto-merge. Both-rosters-required: reconcile reaps non-manifest units, so a
  # SYSTEM_UNITS entry without the matching organ-manifest line would be undone.
  chump-trunk-recovery-reviver.service
  chump-trunk-recovery-reviver.timer
  # RESILIENT-318 / INFRA-2130: the Batched Merge Train (chump-integrator) — a
  # Mac-launchd-only organ ported to systemd. Batches up to 5 ready_to_ship gaps
  # through a preflight gate into ONE integration branch so CI runs once per
  # batch instead of once per gap (~7 -> ~35 PRs/hr). Installed DRY-RUN
  # (CHUMP_INTEGRATOR_LIVE=0 in the unit) — LIVE is an operator flip gated on
  # trunk-GREEN (docs/process/SCALING.md). Shipped in the ATC roster so a fresh
  # Linux node boots WITH the merge train (RUN-INSTALL mission). Requires the
  # chump-integrator binary at ~/.cargo/bin (node-refresh builds+installs it, or
  # install-integrator-daemon-systemd.sh does); the timer no-ops safely until then.
  chump-integrator.service
  chump-integrator.timer
  # CREDIBLE-292: the backlog-sync single writer — publishes registry truth
  # (.chump/state.sql) to origin/main so cluster-wide `chump gap reserve`
  # collision avoidance (the origin-fetch git-history check) and every other
  # node's --reader actually see current state. Designed (RESILIENT-194) but
  # never installed on any node until this gap — that gap is what let the
  # 2026-08-15 registry split-brain go undetected for 21 days.
  chump-backlog-sync-writer.service
  chump-backlog-sync-writer.timer
  # CREDIBLE-296: Race Control — hourly merge-mix board (user-value% /
  # self-maintenance% / reconcile-waste%) + waste-over-threshold alarm.
  # Nobody was watching the tape; this organ is the tape.
  chump-race-control.service
  chump-race-control.timer
  # RESILIENT-376: the two merge-flow organs were declared `enabled` in
  # scripts/ops/organ-manifest.txt but NEVER added to this installer roster (nor
  # given any Linux systemd installer), so on an owned node the unit files were
  # never copied into /etc/systemd/system and organ-reconcile's `enable --now`
  # failed on a missing unit -> backoff -> DARK (the merged-not-running class).
  # The Roll-Call test only guarded installer->manifest, so the manifest->installer
  # gap went unseen. conflict-resolution-consumer (RESILIENT-360): drains
  # real-conflict DIRTY PRs (Linux port of the Mac-only launchd installer).
  # merge-serializer (RESILIENT-372): native-merge-queue substitute that
  # serializes the final merge so each PR gets a clean `verified` pass.
  chump-conflict-resolution-consumer.service
  chump-conflict-resolution-consumer.timer
  chump-merge-serializer.service
  chump-merge-serializer.timer
  # gap-drain (EFFECTIVE-464): the DRAIN LOOP — enriches thin gaps + decomposes
  # broad ones into surgical, flash-landable specs so the cheap DeepSeek floor
  # (EFFECTIVE-445) always has landable work. Both LLM calls route to
  # deepseek-v4-pro, not the contended local ollama.
  chump-gap-drain.service
  chump-gap-drain.timer
  # gap-closure-reconcile (INFRA-303 / INFRA-3826): the durable GitHub-truth
  # backstop that closes open-but-landed gaps (closed_pr merged) AND
  # already-satisfied gaps (closed_pr NULL, work already on main). Declared
  # `enabled` in organ-manifest.txt since INFRA-303 but MISSING from this roster
  # — so the deploy never cp'd/enabled it and organ-reconcile could not revive a
  # wedged timer (it sees the wedged unit as `active` and skips). Dead on the
  # node 2026-08-21 → 2026-08-26; re-rostered here so every deploy re-arms it.
  # Same silent-disable class RESILIENT-376 fixed for the merge-flow organs.
  chump-gap-closure-reconcile.service
  chump-gap-closure-reconcile.timer
  # chump-fleet-server (INFRA-2175): metric-gauge API + bat-phone intake.
  # Serves 127.0.0.1:7070; role=data. Declared `enabled` in organ-manifest.txt
  # — MUST be rostered here or the unit file never lands and the gauges stay
  # dark (RESILIENT-376 merged-not-running class). Service-only, no timer.
  chump-fleet-server.service
  # chump-nba-dispatch (EFFECTIVE-509): the AUTO-DISPATCH CONSUMER for the
  # next-best-action router - reads the top EV-ranked bet and takes a SAFE,
  # reversible, allow-listed action (heal a dead organ / ensure workers building
  # / wait_ci) or DEFERS everything else to the human (kind=nba_deferred_to_human).
  # Lets the OS aim itself between human check-ins. Declared `enabled` in
  # organ-manifest.txt - MUST be rostered here or the unit never lands and the
  # loop stays open (RESILIENT-376 merged-not-running class). Paired timer below.
  chump-nba-dispatch.service
  chump-nba-dispatch.timer
  # INFRA-3643 (TREK-17): systemd complement to the macOS-only
  # almanac-summarize-watchdog (RESILIENT-354) — binary presence + index
  # freshness for the almanac fusion-search organ on the Linux factory.
  chump-almanac-liveness.service
  chump-almanac-liveness.timer
  # META-900 (Mirror in the OS, Phase A): the conversation-bus inbound
  # ingester — tails Claude Code transcripts into chump_web_messages so the
  # operator<->fleet conversation is legible from one store on the hub.
  # Runs as the run-user (reads its ~/.claude, writes the repo db); NOT in
  # the keep-root set.
  chump-jeff-bus-ingest.service
  chump-jeff-bus-ingest.timer
  # RESILIENT-365: wires the INFRA-249 recurring-gap-pattern-detector as a
  # live organ instead of a script only ever run by hand — was DARK/0 units,
  # human-ALERT-only, while 44 symptom PRs shipped in one night with 0 root
  # gaps filed. CHUMP_RCA_REFLEX_ENABLED defaults OFF (see the .service file);
  # detection + ambient ALERT run regardless.
  chump-rca-reflex.service
  chump-rca-reflex.timer
  # cascade-unblock-detector (RESILIENT-418 / INFRA-2070): the launchd
  # installer (install-meta-118-daemons.sh) only wired this on Mac/helsinki;
  # on CJ nothing fanned a merged wedge_auto_fix PR out to sibling PRs blocked
  # on the same failure signature, so those PRs sat stale until a human ran
  # `gh pr update-branch` by hand. Linux port so every node self-heals.
  chump-cascade-unblock-detector.service
  chump-cascade-unblock-detector.timer
  # RESILIENT-1058: wires the RESILIENT-1057 gap-store split-brain guard
  # (scripts/coord/gap-store-single-source-check.sh) into a scheduled organ
  # instead of a script only ever run by hand.
  chump-gap-store-single-source-check.service
  chump-gap-store-single-source-check.timer
  # RESILIENT-1108 (umbrella RESILIENT-1103): the organ-success verifier — reads
  # each manifest-enabled organ's last-run systemctl Result/ExecMainStatus and
  # pages on any FAILED run. Rostered here (AND declared `enabled` in organ-
  # manifest.txt) so it can never repeat the merged-not-running class it was
  # built to catch: a unit in only ONE of the two rosters is either never
  # installed (absent from this list) or never revivable (absent from the
  # manifest). Both required; the RESILIENT-366 Roll-Call test enforces it.
  chump-organ-success-verifier.service
  chump-organ-success-verifier.timer
  # chump-effect-verifier: RESILIENT-1109, the sibling that catches the
  # exit-0-but-no-op class (organ-success-verifier only sees exit-FAIL).
  # Same both-rosters-required discipline applies.
  chump-effect-verifier.service
  chump-effect-verifier.timer
  # chump-node-converge (RESILIENT-1189): the node auto-converge organ — every
  # 10 min it hard-resets this node's SOURCE checkout to origin/main so a merged
  # BASH-organ fix actually reaches the iron. THE fix for the #1 systemic wound
  # (merged != deployed): node-refresh-chump.sh's binary-SHA idempotency skip
  # never resets the source when the binary is already current, so a bash-only
  # merge (which never bumps the binary SHA) leaves every `bash scripts/…/foo.sh`
  # organ running a stale script. Rostered here AND declared `enabled` in
  # organ-manifest.txt — both-rosters-required (a unit in only ONE is either
  # never installed or never revivable); the RESILIENT-366 Roll-Call test
  # enforces it.
  chump-node-converge.service
  chump-node-converge.timer
)
SYSTEM_TIMERS=(chump-pr-lander.timer chump-board-cycle.timer chump-duty-officer.timer chump-sla-scorecard.timer chump-organ-watchdog.timer chump-apex-watchdog.timer chump-board-ceo-briefing.timer chump-organ-reconcile.timer chump-pr-approval.timer chump-farmer.timer chump-rot-reaper.timer chump-trunk-recovery-reviver.timer chump-integrator.timer chump-backlog-sync-writer.timer chump-race-control.timer chump-conflict-resolution-consumer.timer chump-merge-serializer.timer chump-gap-drain.timer chump-gap-closure-reconcile.timer chump-nba-dispatch.timer chump-digest.timer chump-almanac-liveness.timer chump-rca-reflex.timer chump-cascade-unblock-detector.timer chump-gap-store-single-source-check.timer chump-organ-success-verifier.timer chump-effect-verifier.timer chump-node-converge.timer)

# ── --check mode ─────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
  fail=0
  for t in "${SYSTEM_TIMERS[@]}"; do
    if ! systemctl is-active --quiet "$t" 2>/dev/null; then
      echo "MISSING: $t not active"; fail=1
    fi
  done
  if ! systemctl --user is-active --quiet chump-node-refresh.timer 2>/dev/null; then
    echo "MISSING: chump-node-refresh.timer (user) not active"; fail=1
  fi
  [[ "$fail" == 0 ]] && echo "ok: full ATC roster active"
  exit "$fail"
fi

AUTO=0
[[ "${1:-}" == "--auto" ]] && AUTO=1

# RESILIENT-347: stubbable systemd dest-dir + systemctl + root-check (test
# hooks, mirror organ-reconcile.sh's CHUMP_ORGAN_RECONCILE_* pattern) so the
# full --auto roster-install path — including a per-unit enable failure —
# can be exercised in CI without touching a real /etc/systemd/system.
SYSTEMD_DEST_DIR="${CHUMP_INSTALL_ATC_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL_BIN="${CHUMP_INSTALL_ATC_SYSTEMCTL_BIN:-systemctl}"

if [[ "$(id -u)" != "0" && "${CHUMP_INSTALL_ATC_ALLOW_NONROOT:-0}" != "1" ]]; then
  if [[ "$AUTO" == "1" ]]; then
    echo "WARN: --auto invoked without root; skipping system-unit deploy (this worker context cannot install system units)" >&2
    # scanner-anchor: "kind":"organ_units_deploy_failed"  (INFRA-3593; fires
    # when the auto-deploy caller lacks root and cannot write /etc/systemd/system)
    emit organ_units_deploy_failed "\"reason\":\"not_root\""
    exit 0
  fi
  echo "ERROR: system units require root (sudo bash $0)" >&2
  exit 1
fi

echo "== installing system units (pr-lander, armed-rebaser, sla-scorecard, board-cycle, organ-watchdog, board-ceo-briefing, organ-reconcile, pr-approval) =="
# RESILIENT-353: HOST-AGNOSTIC reconcile. The tracked units are helsinki-shaped
# (User=root, /root/.chump, /root/.cargo). Verbatim-copying them onto an owned
# node (CJ=jeff, Termux, ...) installs broken units that source a nonexistent
# /root/.chump and run as the wrong user (no git/ssh/cargo). Rewrite per-host on
# copy so the SAME manifest wires correctly everywhere — this is what lets
# organ-watchdog end the shipped-but-dark disease on any node, not just helsinki.
#
# RESILIENT-1446: a hub whose privileged placer/deploy runs as ROOT from a
# ROOT-OWNED checkout (e.g. an Oracle hub brought up by a root install:
# /root/.chumpnode/repo) must still emit units shaped for the node's real
# worker/store identity, NOT root — otherwise the farmer + organs run as root
# and read /root/.chump while the worker + canonical gap store + oauth token
# live under the worker user, splitting the node's identity (the farmer writes
# its heartbeat to /root/.chump, the worker reads /home/<user>/.chump -> gated
# off RED -> fleet dark, RESILIENT-069). The node declares that identity in
# ~/.chump/node.env's CHUMP_RUN_USER (chump-node-install.sh's write_node_env);
# honor it here so a root-run deploy emits run-user-shaped units. An explicit
# CHUMP_RUN_USER already in the environment still wins (test hook / override).
if [[ -z "${CHUMP_RUN_USER:-}" ]]; then
  _node_env="${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}/node.env"
  [[ -f "$_node_env" ]] && CHUMP_RUN_USER="$(grep -E '^(export )?CHUMP_RUN_USER=' "$_node_env" 2>/dev/null | tail -1 | sed -E 's/^(export )?CHUMP_RUN_USER=//; s/^"(.*)"$/\1/')"
  [[ -z "${CHUMP_RUN_USER:-}" ]] && unset CHUMP_RUN_USER
fi
RUN_USER="${CHUMP_RUN_USER:-$(stat -c %U "$REPO_ROOT" 2>/dev/null || echo root)}"
RUN_HOME="$(getent passwd "$RUN_USER" 2>/dev/null | cut -d: -f6 || true)"; [[ -z "$RUN_HOME" ]] && RUN_HOME="/home/$RUN_USER"

# RESILIENT-1102: the repo path baked into every organ's WorkingDirectory/
# ExecStart. It MUST be this box's REAL checkout — owned nodes live at
# $HOME/chump (no Projects segment), and the pre-fix rewriter preserved a baked
# `Projects/chump` suffix that pointed at a non-existent dir, so systemd killed
# every organ at CHDIR (status=200/CHDIR) before it ran. Normally $REPO_ROOT is
# exactly right (organ-deploy runs this installer from the persistent checkout).
# The ONE exception is the INFRA-3598 class: a manual run from an ephemeral
# .claude/worktrees/<gap>/ dir would bake a path that vanishes at session end,
# reintroducing the same break — so when $REPO_ROOT looks ephemeral, fall back
# to a stable on-disk checkout ($HOME/chump, then the legacy $HOME/Projects/chump,
# then $HOME/chump-host) rather than the worktree.
UNIT_REPO_ROOT="$REPO_ROOT"
if [[ "$REPO_ROOT" == *"/.claude/worktrees/"* ]]; then
  for _cand in "${RUN_HOME%/}/chump" "${RUN_HOME%/}/Projects/chump" "${RUN_HOME%/}/chump-host"; do
    if [[ -e "$_cand/.git" ]]; then UNIT_REPO_ROOT="$_cand"; break; fi
  done
  echo "  NOTE: ephemeral worktree ($REPO_ROOT) — baking stable repo path $UNIT_REPO_ROOT into organ units"
fi
# RESILIENT-1446: if the checkout this installer runs from is owned by a
# DIFFERENT user than the run-user (the split-identity hub: a root deploy from
# /root/.chumpnode/repo but CHUMP_RUN_USER=<worker>), the run-user cannot cd
# into that root-owned tree (WorkingDirectory -> 200/CHDIR) and $HOME-based
# tools would read the wrong ~/.chump. Re-target the baked repo path to the
# run-user's OWN checkout so every placed unit points at a tree the run-user
# actually owns. Only re-target to a run-user-owned checkout that exists on
# disk; a same-user fresh node (owner == run-user) is already correct and is
# left untouched.
_checkout_owner="$(stat -c %U "$UNIT_REPO_ROOT" 2>/dev/null || echo "")"
if [[ -n "$_checkout_owner" && "$_checkout_owner" != "$RUN_USER" ]]; then
  for _cand in "${RUN_HOME%/}/chump" "${RUN_HOME%/}/Projects/chump" "${RUN_HOME%/}/chump-host"; do
    if [[ -e "$_cand/.git" && "$(stat -c %U "$_cand" 2>/dev/null)" == "$RUN_USER" ]]; then
      UNIT_REPO_ROOT="$_cand"
      echo "  NOTE: checkout $REPO_ROOT owned by $_checkout_owner != run-user $RUN_USER — baking run-user checkout $UNIT_REPO_ROOT into organ units (RESILIENT-1446)"
      break
    fi
  done
fi
echo "  host-rewrite target: User=$RUN_USER HOME=$RUN_HOME repo=$UNIT_REPO_ROOT"
mkdir -p "$SYSTEMD_DEST_DIR"
CHANGED_UNITS=()
# RESILIENT-374: organs whose JOB is the privileged system-unit deploy itself
# must stay User=root even on an owned node. The generic host-rewrite below
# flips User=root -> the run-user for every unit — correct for organs that do
# git/cargo/gh work in the owner's home, but FATAL for a deploy organ: a
# de-privileged deployer cannot write /etc/systemd/system, which is exactly
# what left CJ's merged organ units DARK (organ-reconcile/organ-watchdog both
# log "needs root ... skipping" every cycle). Keep this narrow set root; paths
# are still /root-rewritten so they find the repo on an owned node.
#
# RESILIENT-1327: chump-organ-reconcile belongs in this set too.
# organ-reconcile.sh's own guard (`id -u != 0` -> `organ_reconcile_skipped
# reason=not_root`) proves it needs root to write /etc/systemd/system, exactly
# like organ-deploy — but it was missing from this exemption, so the generic
# host-rewrite demoted it to the run-user on Oracle nodes cuphead/mugman
# (User=ubuntu). The unit ran every cycle but silently no-op'd instead of
# converging systemd state to the manifest — a latent enforcement hole masked
# only because RESILIENT-1309 made the role-aware health-sentinel the actual
# resurrector on muscle nodes. Fix it at the source so reconcile enforces the
# manifest again wherever it's deployed.
declare -A _KEEP_ROOT_ORGANS=(
  [chump-organ-deploy.service]=1
  [chump-organ-deploy.timer]=1
  [chump-organ-reconcile.service]=1
  [chump-organ-reconcile.timer]=1
)
for unit in "${SYSTEM_UNITS[@]}"; do
  src="$REPO_ROOT/scripts/dispatch/$unit"
  dest="$SYSTEMD_DEST_DIR/$unit"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: $src not found" >&2
    exit 1
  fi
  tmp="$(mktemp)"
  # RESILIENT-353 / INFRA-3647 / RESILIENT-1051 host-rewrite — now the shared
  # organ_unit_host_rewrite (scripts/ops/lib/organ-unit-install-lib.sh), the
  # SAME rewriter chump-node-install.sh's --role placer uses. It detects each
  # unit's OWN baked-in source user + home, rewrites path prefixes AND a bare
  # `Environment=HOME=/root` (the "instruments lie" keystone), injects the
  # uniform host-agnostic runtime context (User/HOME/WorkingDirectory/PATH), and
  # (for the keep-root deploy organ) re-asserts User=root.
  _keep_root=0; [[ -n "${_KEEP_ROOT_ORGANS[$unit]:-}" ]] && _keep_root=1
  organ_unit_host_rewrite "$src" "$tmp" "$RUN_USER" "$RUN_HOME" "$_keep_root" "$UNIT_REPO_ROOT"
  if [[ ! -f "$dest" ]] || ! cmp -s "$tmp" "$dest"; then
    CHANGED_UNITS+=("$unit")
  fi
  cp -f "$tmp" "$dest"; rm -f "$tmp"
  echo "  installed $unit (host-rewritten -> $RUN_USER)"
done

# RESILIENT-318 / INFRA-2130: the Batched Merge Train needs its own binary, which
# node-refresh-chump.sh does NOT build (it only refreshes `chump`). Ensure it
# exists so a fresh node boots with a WORKING merge train, not a timer that
# fails on a missing binary. Best-effort + non-fatal: a build failure must never
# block the rest of the ATC roster (the timer safely no-ops until the binary
# lands). Idempotent: only builds when the binary is absent.
INTEGRATOR_BIN_DEST="${CARGO_BIN_DIR:-/root/.cargo/bin}/chump-integrator"
if [[ ! -x "$INTEGRATOR_BIN_DEST" ]]; then
  _staged=""
  for cand in "$REPO_ROOT/target/release/chump-integrator" "$REPO_ROOT/target/debug/chump-integrator"; do
    [[ -x "$cand" ]] && { _staged="$cand"; break; }
  done
  if [[ -z "$_staged" ]] && command -v cargo >/dev/null 2>&1; then
    echo "== building chump-integrator binary (Batched Merge Train) =="
    if (cd "$REPO_ROOT" && cargo build --release -p chump-integrator --bin chump-integrator) 2>&1; then
      _staged="$REPO_ROOT/target/release/chump-integrator"
    else
      echo "WARN: chump-integrator build failed (non-fatal; timer no-ops until binary lands)" >&2
    fi
  fi
  if [[ -n "$_staged" && -x "$_staged" ]]; then
    install -m 0755 "$_staged" "$INTEGRATOR_BIN_DEST" \
      && echo "  installed chump-integrator -> $INTEGRATOR_BIN_DEST"
  fi
fi

if ! "$SYSTEMCTL_BIN" daemon-reload 2>&1; then
  echo "ERROR: systemctl daemon-reload failed (no systemd bus reachable?)" >&2
  emit organ_units_deploy_failed "\"reason\":\"systemctl_daemon_reload_failed\""
  [[ "$AUTO" == "1" ]] && exit 0
  exit 1
fi
# RESILIENT-347: a single timer failing to `enable --now` (e.g.
# chump-integrator.timer/chump-backlog-sync-writer.timer/chump-farmer.timer
# on a node missing that organ's binary/deps) must NOT abort the whole
# --auto roster install. Before this fix, `exit 0` here under --auto meant
# the run stopped dead on the FIRST failing unit and never reached the
# ORGAN_RECONCILE call below — so the curated per-node-applicable reconcile
# (which backs the failing unit off cleanly instead of re-churning it) never
# even got a chance to run. Non---auto (manual sudo invocation) still hard-
# fails, since an operator running this by hand wants to see the error stop
# the script rather than have it silently continue.
for t in "${SYSTEM_TIMERS[@]}"; do
  if ! "$SYSTEMCTL_BIN" enable --now "$t" 2>&1; then
    echo "ERROR: systemctl enable --now $t failed" >&2
    emit organ_units_deploy_failed "\"reason\":\"systemctl_enable_failed\",\"unit\":\"$t\""
    if [[ "$AUTO" == "1" ]]; then
      continue
    fi
    exit 1
  fi
  echo "  enabled + started $t"
done

# RESILIENT-305: converge organ state to the repo manifest immediately, rather
# than waiting for chump-organ-reconcile.timer's first tick. Critically, THIS
# installer's own enable-loop just (re-)started the pager timers
# (sla-scorecard, board-ceo-briefing); the reconcile re-neuters them from the
# repo-declared manifest so a deploy can never resurrect the auto-pagers. Best
# -effort: a failure here must not block the roster install above.
ORGAN_RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"
if [[ -x "$ORGAN_RECONCILE" ]]; then
  echo "== reconciling organ manifest (enabled organs up, auto-pagers OFF) =="
  bash "$ORGAN_RECONCILE" --apply || echo "WARN: organ-reconcile failed (non-fatal; roster units still installed)" >&2
fi

echo "== installing user unit (node-refresh) =="
# node-refresh runs as the operator user (not root's systemd --user unless
# helsinki genuinely operates as root), so hand off to its own installer,
# which generates the unit files directly rather than tracking static copies.
NODE_REFRESH_INSTALLER="$REPO_ROOT/scripts/setup/install-node-refresh-systemd.sh"
if [[ ! -f "$NODE_REFRESH_INSTALLER" ]]; then
  echo "ERROR: $NODE_REFRESH_INSTALLER not found" >&2
  exit 1
fi
# INFRA-3598: never bake an EPHEMERAL session worktree
# (.claude/worktrees/<gap>-<ts>/) into the persisted node-refresh unit's
# CHUMP_NODE_REPO. This script's own REPO_ROOT is "wherever this file
# currently lives on disk" — fine for the SYSTEM_UNITS copy step above
# (idempotent, re-copies from wherever it's invoked), but fatal for
# node-refresh: that env var gets written into ~/.config/systemd/user's
# Environment= line and persists there until the next install. A worktree
# invocation (e.g. an agent session manually re-running this script to test
# a change) would clobber the shared timer to build from a scratch dir that
# gets deleted at session end, silently breaking "helsinki clone auto-stays-
# current" until someone notices and reinstalls from a stable mirror. Proof:
# exactly this happened on 2026-08-11 (unit found pointing at an
# infra-3593-fleet-1-* worktree that no longer matched a live checkout).
#
# If REPO_ROOT looks ephemeral, DON'T pass CHUMP_NODE_REPO at all — the
# installer's own fallback chain (CHUMP_NODE_REPO env -> $HOME/chump-host ->
# $HOME/Projects/Chump -> its own $0-relative path) already tries
# $HOME/chump-host next, which is the stable mirror on helsinki.
if [[ "$REPO_ROOT" == *"/.claude/worktrees/"* ]]; then
  echo "  NOTE: this script is running from an ephemeral worktree ($REPO_ROOT)."
  echo "        Not propagating it as CHUMP_NODE_REPO — letting the installer"
  echo "        fall back to a stable mirror (\$HOME/chump-host or similar)."
  bash "$NODE_REFRESH_INSTALLER" \
    || echo "WARN: node-refresh user-unit install failed (non-fatal; system units above still installed)" >&2
else
  CHUMP_NODE_REPO="$REPO_ROOT" bash "$NODE_REFRESH_INSTALLER" \
    || echo "WARN: node-refresh user-unit install failed (non-fatal; system units above still installed)" >&2
fi

echo ""
echo "== ATC roster status =="
systemctl list-timers "${SYSTEM_TIMERS[@]}" --no-pager 2>/dev/null || true
systemctl --user list-timers chump-node-refresh.timer --no-pager 2>/dev/null || true

if [[ "${#CHANGED_UNITS[@]}" -gt 0 ]]; then
  units_json="$(printf '"%s",' "${CHANGED_UNITS[@]}")"
  units_json="[${units_json%,}]"
  # scanner-anchor: "kind":"organ_units_deployed"  (INFRA-3593; fires only
  # when a chump-*.service/.timer diff was actually installed — the
  # merge-triggered auto-deploy signal the board polls to verify AC 1/7)
  emit organ_units_deployed "\"units\":$units_json,\"auto\":$([[ "$AUTO" == 1 ]] && echo true || echo false)"
  echo ""
  echo "deployed (changed): ${CHANGED_UNITS[*]}"
else
  # scanner-anchor: "kind":"organ_units_deploy_skipped"  (INFRA-3593; no unit
  # diff found — roster already current, no-op on the common auto-deploy path)
  emit organ_units_deploy_skipped "\"auto\":$([[ "$AUTO" == 1 ]] && echo true || echo false)"
fi

echo ""
echo "Verify: bash $0 --check"
