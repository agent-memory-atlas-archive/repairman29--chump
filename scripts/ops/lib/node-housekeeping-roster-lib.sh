#!/usr/bin/env bash
# scripts/ops/lib/node-housekeeping-roster-lib.sh — INFRA-7766
#
# docs/strategy/ONE_COMMAND_INSTALL.md section 1 (one-command-install BOM
# unification, INFRA-7756): install-node-housekeeping.sh's hardcoded 10-organ
# ORGANS= heredoc was one of three unlinked rosters (the other two being
# organ-manifest.txt and bootstrap-manifest.yaml) that silently drifted apart
# for months because nothing cross-referenced them. This library derives the
# SAME (name, script, cadence) triples from scripts/ops/organ-manifest.txt's
# `housekeeping=<script>|<cadence>|<args>` tokens (added to the matching
# `enabled chump-<name>.service` lines) instead — so there is exactly ONE
# declared roster, and organ-reconcile.sh's self-heal roll-call sees 8 of the
# 10 organs install-node-housekeeping.sh actually installs (the other 2 are a
# documented, deliberate carve-out — see below).
#
# Extracted into its own sourceable library (rather than inlined in
# install-node-housekeeping.sh) so it can be unit-tested in isolation without
# executing that script's real install side effects (mkdir/systemctl/sv up).
#
# DISCOVERY (2026-09-20, this audit): install-node-housekeeping.sh's
# install_systemd() writes unit files at the fixed path
# /etc/systemd/system/chump-$name.service for whatever bare `$name` is in its
# ORGANS table — and two of the ten names it has always used ("pr-lander",
# "rot-reaper") COLLIDE with unit names two OTHER, older, independently
# installed organs already claim: chump-pr-lander.timer's sibling .service
# (RESILIENT-288, "Chump PR-lander beat — arm green PRs so they merge") and a
# standalone RESILIENT-324 chump-rot-reaper.service ("drain CONFLICTING+old
# PRs"). Verified live on CJ: both units exist, both currently `inactive
# dead`, and their `systemctl status` description text does NOT match the
# housekeeping-installed "ChumpOS housekeeping organ: <name> (RESILIENT-318)"
# wording — whichever installer wrote last silently clobbered the other's
# unit file at the same path. This is a PRE-EXISTING bug this audit
# surfaced, not introduced here, and fixing the collision (e.g. renaming the
# housekeeping side to chump-hk-pr-lander.service) is real behavior-changing
# work explicitly out of scope for this "zero runtime behavior change"
# slice — filed as INFRA-7772 for a dedicated fix.
#
# So these two are deliberately NOT given `enabled` organ-manifest.txt lines
# in this slice — doing so would make organ-reconcile.sh (self-heal) start
# `systemctl enable --now`-ing a unit name that's ambiguous between two
# unrelated capabilities, a NEW behavior, not a preserved one. They stay in
# this function's hardcoded carve-out below so install-node-housekeeping.sh's
# own installed roster is byte-identical to before — only their
# organ-manifest.txt self-heal visibility is deferred to INFRA-7772.
_HOUSEKEEPING_COLLISION_CARVEOUT="pr-lander|scripts/dispatch/pr-lander-beat.sh|600
rot-reaper|scripts/ops/rot-reaper.sh|1800"

# housekeeping_organs_from_manifest <manifest-path>
#
# Echoes the ORGANS table (one "name|script[ args]|cadence" line per organ,
# newline-separated) sourced from <manifest-path>'s `housekeeping=` tokens,
# plus the two collision-carveout organs above. Falls back to the
# pre-INFRA-7766 built-in 10-organ roster (with a WARN on stderr) if the
# manifest is missing or carries zero housekeeping= lines — this is
# deliberate, not silent: install-node-housekeeping.sh must keep working
# standalone (e.g. during bring-up before the repo clone settles), and a
# manifest that has REGRESSED to the old pre-unification shape (no
# housekeeping= tokens at all) should visibly fall back rather than silently
# install nothing.
housekeeping_organs_from_manifest() {
  local manifest="$1"
  local organs=""
  if [ -f "$manifest" ]; then
    local state unit rest
    while read -r state unit rest; do
      case "${state:-}" in ""|\#*) continue ;; esac
      [ "$state" = "enabled" ] || continue
      local hk="" tok
      for tok in $rest; do
        case "$tok" in housekeeping=*) hk="${tok#housekeeping=}" ;; esac
      done
      [ -z "$hk" ] && continue
      local name="${unit#chump-}"; name="${name%.service}"
      local script="${hk%%|*}" rest2="${hk#*|}"
      local cadence="${rest2%%|*}" args="${rest2#*|}"
      [ -n "$args" ] && script="$script $args"
      organs="${organs}${organs:+
}${name}|${script}|${cadence}"
    done < "$manifest"
  fi
  if [ -n "$organs" ]; then
    printf '%s\n%s\n' "$organs" "$_HOUSEKEEPING_COLLISION_CARVEOUT"
    return 0
  fi
  echo "WARN (INFRA-7766): no housekeeping= lines found in $manifest — falling back to the built-in 10-organ roster" >&2
  organs="node-orchestrator|scripts/ops/node-orchestrator.sh|0
rot-reaper|scripts/ops/rot-reaper.sh|1800
worktree-reaper|scripts/ops/stale-worktree-reaper.sh --execute|900
disk-monitor|scripts/ops/disk-health-monitor.sh|300
main-health-watchdog|scripts/ops/main-health-watchdog.sh|600
pr-lander|scripts/dispatch/pr-lander-beat.sh|600
cargo-sweep-gc|scripts/ops/cargo-sweep-gc.sh|3600
reviver|scripts/coord/post-push-integrity-watch.sh|60
pr-stuck-live-scan|scripts/ops/stuck-pr-filer.sh|3600
pr-stuck-cluster-detector|scripts/coord/pr-stuck-cluster-detector.sh --apply|1800"
  printf '%s\n' "$organs"
}
