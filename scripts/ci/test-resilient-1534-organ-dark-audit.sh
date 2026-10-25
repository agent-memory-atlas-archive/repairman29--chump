#!/usr/bin/env bash
# RESILIENT-1534: organ-deploy's post-deploy audit must NAME why each enabled organ is
# not running — scoped off this node, unmet requires=, unit missing/not installed,
# ExecStart target missing, or genuinely inactive — instead of counting every
# non-active manifest row as an unexplained "STILL DARK". Also proves the 14 organs
# the gap reported dark are correctly scoped off a systemd hub (platforms=launchd).
#
# RESILIENT-1535: extends the same mechanism with a `node=` manifest field —
# chump-postgrest.service (dormant BY DESIGN, RESILIENT-1057) and the
# chump-cj-* organs belong on closetjunky, not the hub, and were previously
# miscounted as UNEXPECTED-DARK via their requires= (missing_bin/missing_file)
# rather than recognized as expected-dark-elsewhere. Proves the real manifest's
# node=closetjunky lines read as scoped-off (not UNEXPECTED-DARK) on any other
# node, so the dark-count the enforcement alarm reads is honest.
# Stubbed systemctl; pure local.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY="$ROOT/scripts/ops/organ-deploy.sh"
LIB="$ROOT/scripts/ops/lib/organ-manifest-lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# ── Fixture repo ─────────────────────────────────────────────────────────────
R="$T/repo"; SD="$T/systemd"; mkdir -p "$R/scripts/ops" "$R/scripts/dispatch" "$R/scripts/coord" "$SD"
cp -r "$ROOT/scripts/ops/lib" "$R/scripts/ops/lib"
unit() { printf '[Service]\nExecStart=/bin/bash /root/Projects/chump/scripts/coord/%s\n' "$2" > "$R/scripts/dispatch/$1"; }
# healthy: unit + timer + script, installed, active
unit chump-good.service good.sh; printf '[Timer]\nOnCalendar=daily\n' > "$R/scripts/dispatch/chump-good.timer"; echo 'true' > "$R/scripts/coord/good.sh"
cp "$R/scripts/dispatch/chump-good.timer" "$SD/"
# inactive: everything present, but not active
unit chump-sick.service sick.sh; printf '[Timer]\nOnCalendar=daily\n' > "$R/scripts/dispatch/chump-sick.timer"; echo 'true' > "$R/scripts/coord/sick.sh"
cp "$R/scripts/dispatch/chump-sick.timer" "$SD/"
# not installed: repo has it, systemd dir does not
unit chump-uninstalled.service un.sh; printf '[Timer]\nOnCalendar=daily\n' > "$R/scripts/dispatch/chump-uninstalled.timer"; echo 'true' > "$R/scripts/coord/un.sh"
# exec missing: installed, but ExecStart script absent from the repo
unit chump-noexec.service gone.sh; printf '[Timer]\nOnCalendar=daily\n' > "$R/scripts/dispatch/chump-noexec.timer"; cp "$R/scripts/dispatch/chump-noexec.timer" "$SD/"
cat > "$R/scripts/ops/organ-manifest.txt" <<'M'
enabled  chump-good.timer
enabled  chump-sick.timer
enabled  chump-uninstalled.timer
enabled  chump-noexec.timer
enabled  chump-nounit.timer
enabled  chump-needs-bin.timer  requires=bin:definitely-not-a-real-binary-xyz
enabled  chump-mac-only.timer  platforms=launchd
M
cat > "$T/systemctl" <<'S'
#!/usr/bin/env bash
# stub: `systemctl is-active --quiet <unit>` — active only for units listed in $ACTIVE
[[ "$1" == "is-active" ]] && { grep -qxF "${@: -1}" "$ACTIVE" 2>/dev/null; exit $?; }
exit 0
S
chmod +x "$T/systemctl"; echo "chump-good.timer" > "$T/active"
export ACTIVE="$T/active" SYSTEMCTL_BIN="$T/systemctl" CHUMP_ORGAN_DEPLOY_SYSTEMCTL_BIN="$T/systemctl" CHUMP_ORGAN_MANIFEST_PLATFORM=systemd

cause() { # <unit> <platforms> <requires>  (against the fixture repo)
  bash -c "source '$LIB'; organ_dark_cause '$1' '$2' '$3' systemd '$R' '$SD'"
}
[[ "$(cause chump-good.timer '' '')" == "active" ]] && ok "active organ -> active" || bad "good: $(cause chump-good.timer '' '')"
[[ "$(cause chump-mac-only.timer launchd '')" == "scoped-off:platforms=launchd" ]] && ok "launchd-only organ on a systemd node -> scoped-off (expected dark, not a fault)" || bad "mac-only"
[[ "$(cause chump-needs-bin.timer '' 'bin:definitely-not-a-real-binary-xyz')" == "unmet-requires:missing_bin:definitely-not-a-real-binary-xyz" ]] && ok "unmet requires= -> unmet-requires:<reason>" || bad "needs-bin"
[[ "$(cause chump-nounit.timer '' '')" == "unit-missing" ]] && ok "no unit file in the repo -> unit-missing" || bad "nounit"
[[ "$(cause chump-uninstalled.timer '' '')" == "unit-not-installed" ]] && ok "unit in repo but not installed -> unit-not-installed" || bad "uninstalled"
[[ "$(cause chump-noexec.timer '' '')" == "exec-missing:scripts/coord/gone.sh" ]] && ok "ExecStart script absent -> exec-missing:<path>" || bad "noexec: $(cause chump-noexec.timer '' '')"
[[ "$(cause chump-sick.timer '' '')" == "inactive" ]] && ok "everything present but not active -> inactive (a real fault)" || bad "sick"

# RESILIENT-1535: node= scoping. organ_dark_cause takes an optional node-csv
# (arg 7) and current-node (arg 8) — a mismatch must read as scoped-off:node=,
# BEFORE requires= is even evaluated (a node-scoped organ's unmet requires=
# is expected, not a fault).
cause_node() { # <unit> <node-csv> <requires> <current-node>
  bash -c "source '$LIB'; organ_dark_cause '$1' '' '$3' systemd '$R' '$SD' '$2' '$4'"
}
[[ "$(cause_node chump-sick.timer closetjunky '' cuphead)" == "scoped-off:node=closetjunky" ]] \
  && ok "node=closetjunky organ on a different current-node -> scoped-off:node=<csv> (expected dark elsewhere)" || bad "node-mismatch"
[[ "$(cause_node chump-sick.timer closetjunky '' closetjunky)" == "inactive" ]] \
  && ok "node=closetjunky organ ON closetjunky -> evaluated normally (inactive, not scoped)" || bad "node-match"
[[ "$(cause_node chump-needs-bin.timer closetjunky 'bin:definitely-not-a-real-binary-xyz' cuphead)" == "scoped-off:node=closetjunky" ]] \
  && ok "node mismatch wins over an unmet requires= — the organ is scoped off, not flagged unmet-requires" || bad "node-mismatch-vs-requires"
[[ "$(cause_node chump-needs-bin.timer '' 'bin:definitely-not-a-real-binary-xyz' cuphead)" == "unmet-requires:missing_bin:definitely-not-a-real-binary-xyz" ]] \
  && ok "no node= scope (empty) -> unmet requires= still reported as a real fault (no regression for node-agnostic organs)" || bad "no-node-scope"

# ── The audit: summary line, per-organ causes, exit code ─────────────────────
out="$(CHUMP_REPO_ROOT="$R" CHUMP_ORGAN_DEPLOY_SYSTEMD_DIR="$SD" bash "$DEPLOY" --audit-only 2>&1)"; rc=$?
grep -q 'post-deploy manifest audit: 1/7 enabled organs active, 1 scoped off this node (platform=systemd), 5 UNEXPECTED-DARK' <<<"$out" \
  && ok "audit summary separates active / scoped-off / UNEXPECTED-DARK" || bad "summary: $out"
for want in "chump-sick.timer — inactive" "chump-uninstalled.timer — unit-not-installed" "chump-noexec.timer — exec-missing:scripts/coord/gone.sh" \
            "chump-nounit.timer — unit-missing" "chump-needs-bin.timer — unmet-requires:missing_bin"; do
  grep -qF "UNEXPECTED-DARK: $want" <<<"$out" || bad "missing per-organ cause line: $want"
done
grep -q 'scoped off this node: chump-mac-only.timer' <<<"$out" && ok "every dark organ gets a named root cause line (none silently skipped)" || bad "no cause lines"
[[ $rc -eq 1 ]] && ok "--audit-only exits 1 while UNEXPECTED-DARK organs remain" || bad "rc=$rc"
grep -q 'chump-mac-only.timer' <<<"$(grep UNEXPECTED-DARK <<<"$out")" && bad "scoped-off organ wrongly counted as UNEXPECTED-DARK" || ok "scoped-off organ is not counted as UNEXPECTED-DARK"

# A fully healthy/scoped manifest -> exit 0
printf 'enabled  chump-good.timer\nenabled  chump-mac-only.timer  platforms=launchd\n' > "$R/scripts/ops/organ-manifest.txt"
out="$(CHUMP_REPO_ROOT="$R" CHUMP_ORGAN_DEPLOY_SYSTEMD_DIR="$SD" bash "$DEPLOY" --audit-only 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q '0 UNEXPECTED-DARK' <<<"$out" && ok "all organs active or scoped off -> real 0 unexpected-dark, exit 0" || bad "clean audit rc=$rc: $out"

# ── Parser regression: a trailing comment must never overwrite a real field ──
printf 'enabled  chump-quoted.timer  role=data requires=bin:chump platforms=launchd  # comment quotes fields: platforms= stays launchd, requires=bin:other role=muscle\n' > "$T/quoted-manifest.txt"
got="$(bash -c "source '$LIB'; declare -a po en; declare -A ro rq pl; organ_manifest_parse '$T/quoted-manifest.txt' po en ro rq pl; echo \"\${pl[chump-quoted.timer]}|\${rq[chump-quoted.timer]}|\${ro[chump-quoted.timer]}\"")"
[[ "$got" == "launchd|bin:chump|data" ]] && ok "manifest parser ignores field-like tokens inside a trailing # comment (the mission-grade mis-parse)" || bad "comment tokens leaked into fields: $got"

# ── The real manifest: the remaining launchd-only organs + 4 newly Linux-ported (INFRA-8126/8146) ──
REPORTED="main-worktree-drift-detector planner distill-pr-skills almanac-code-intel a2a-dead-letter-reaper decomposition-hint-tracker refresh-model-prices fleet-version-skew-detect mission-grade quartermaster-audit"
: > "$T/active"   # nothing is active in CI
bad14=0
for o in $REPORTED; do
  unit="chump-$o.timer"
  line="$(grep -E "^enabled[[:space:]]+$unit([[:space:]]|$)" "$ROOT/scripts/ops/organ-manifest.txt")"
  [[ -n "$line" ]] || { echo "    not in manifest: $unit"; bad14=1; continue; }
  plats="$(bash -c "source '$LIB'; declare -a po en; declare -A ro rq pl; organ_manifest_parse '$ROOT/scripts/ops/organ-manifest.txt' po en ro rq pl; printf %s \"\${pl[$unit]:-}\"")"
  c="$(bash -c "source '$LIB'; organ_dark_cause '$unit' '$plats' '' systemd '$ROOT' '$SD'")"
  [[ "$c" == "scoped-off:platforms=launchd" ]] || { echo "    $unit -> $c"; bad14=1; }
done
[[ $bad14 -eq 0 ]] && ok "remaining launchd-only organs are correctly scoped off a systemd hub (platforms=launchd), with root cause named — not 'dark'" || bad "some launchd-only organs are not scoped off (see above)"

# INFRA-8126 / INFRA-8146: github-liaison, ghost-pr-closer, stale-branch-reaper, daemon-activator
# are now ported to Linux (platforms=systemd,launchd with tracked scripts/dispatch/ units).
PORTED_LINUX="github-liaison ghost-pr-closer stale-branch-reaper branch-reaper daemon-activator"
bad_ported=0
for o in $PORTED_LINUX; do
  unit="chump-$o.timer"
  [[ -f "$ROOT/scripts/dispatch/chump-$o.service" && -f "$ROOT/scripts/dispatch/chump-$o.timer" ]] || { echo "    missing unit files: $o"; bad_ported=1; continue; }
  plats="$(bash -c "source '$LIB'; declare -a po en; declare -A ro rq pl; organ_manifest_parse '$ROOT/scripts/ops/organ-manifest.txt' po en ro rq pl; printf %s \"\${pl[$unit]:-}\"")"
  [[ ",$plats," == *",systemd,"* ]] || { echo "    $unit not systemd-enabled: $plats"; bad_ported=1; }
done
[[ $bad_ported -eq 0 ]] && ok "INFRA-8126/INFRA-8146 ported organs have tracked systemd .service+.timer units and platforms=systemd,launchd" || bad "some ported organs missing systemd units or platform tag"

# The audit on the real manifest never lists any of the 14 as UNEXPECTED-DARK.
out="$(CHUMP_REPO_ROOT="$ROOT" CHUMP_ORGAN_DEPLOY_SYSTEMD_DIR="$SD" bash "$DEPLOY" --audit-only 2>&1 || true)"
leak=0; for o in $REPORTED; do grep -q "UNEXPECTED-DARK: chump-$o.timer" <<<"$out" && { echo "    leaked: $o"; leak=1; }; done
[[ $leak -eq 0 ]] && ok "the real audit no longer reports any of the 14 as UNEXPECTED-DARK" || bad "reported organs still UNEXPECTED-DARK"

# ── RESILIENT-1535: chump-postgrest + chump-cj-* are node=closetjunky-scoped,
#    excluded from the hub dark-count ─────────────────────────────────────────
CJ_ONLY="chump-cj-worker.service chump-cj-disk-monitor.service chump-cj-sync.service chump-postgrest.service"
for u in $CJ_ONLY; do
  line="$(grep -E "^enabled[[:space:]]+${u//./\\.}([[:space:]]|$)" "$ROOT/scripts/ops/organ-manifest.txt")"
  [[ "$line" == *"node=closetjunky"* ]] || { echo "    missing node=closetjunky: $u"; bad "$u not scoped"; }
done
ok "chump-postgrest.service + chump-cj-* manifest lines carry node=closetjunky"

out_hub="$(CHUMP_REPO_ROOT="$ROOT" CHUMP_ORGAN_DEPLOY_SYSTEMD_DIR="$SD" CHUMP_ORGAN_MANIFEST_NODE=cuphead bash "$DEPLOY" --audit-only 2>&1 || true)"
leak=0; for u in $CJ_ONLY; do
  grep -q "UNEXPECTED-DARK: $u" <<<"$out_hub" && { echo "    leaked: $u"; leak=1; }
  grep -q "scoped off this node: $u (scoped-off:node=closetjunky)" <<<"$out_hub" || { echo "    not reported scoped-off: $u"; leak=1; }
done
[[ $leak -eq 0 ]] && ok "on a non-CJ node (cuphead), chump-postgrest.service + chump-cj-* read as scoped-off, never UNEXPECTED-DARK — the dishonest dark-count this gap fixes" || bad "cj-only organs still inflate the hub dark-count"

echo "=== organ dark audit: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
