#!/usr/bin/env bash
# test-provision-chumpd-host.sh — RESILIENT-176
#
# Shape/safety smoke test for scripts/setup/provision-chumpd-host.sh.
# This is a PREP-slice gap (chumpd/MISSION-051 hasn't merged), so this test
# does NOT exercise a real provision run — it asserts the script's shape,
# its HOME guard, its dry-run non-mutation contract, and that it embeds no
# credential-looking strings. Mirrors scripts/ci/test-pi-mesh-installer-shape.sh.
#
# Exits 0 if all checks pass, non-zero otherwise.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/setup/provision-chumpd-host.sh"

PASS=0
FAIL=0

ok()   { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== provision-chumpd-host.sh shape smoke test (RESILIENT-176) ==="
echo

# 1. Script presence + executable
echo "-- 1. Script presence"
if [[ -f "$SCRIPT" ]]; then
  ok "script exists at scripts/setup/provision-chumpd-host.sh"
else
  fail "script not found at $SCRIPT"
fi
if [[ -x "$SCRIPT" ]]; then
  ok "script is executable"
else
  fail "script is not executable (chmod +x $SCRIPT)"
fi

# 2. Bash syntax lint
echo
echo "-- 2. Bash syntax lint"
if bash -n "$SCRIPT" 2>/dev/null; then
  ok "bash -n passed (no syntax errors)"
else
  fail "bash -n failed on $SCRIPT"
  bash -n "$SCRIPT" || true
fi

# 3. Refuses to run with unset HOME
echo
echo "-- 3. HOME guard"
if grep -q 'HOME.*unset\|-z.*HOME' "$SCRIPT"; then
  ok "HOME-unset guard present in script source"
else
  fail "no HOME-unset guard found in script source"
fi
HOME_GUARD_OUTPUT="$(env -u HOME bash "$SCRIPT" --check 2>&1)" && HOME_GUARD_EXIT=0 || HOME_GUARD_EXIT=$?
if [[ "$HOME_GUARD_EXIT" -ne 0 ]]; then
  ok "running with HOME unset exits non-zero (exit=$HOME_GUARD_EXIT)"
else
  fail "running with HOME unset did NOT fail (exit=0) — guard is not effective"
fi
if echo "$HOME_GUARD_OUTPUT" | grep -qi 'HOME is unset'; then
  ok "HOME-unset error message is clear"
else
  fail "HOME-unset run produced no clear error message"
fi

# 4. Dry-run mode touches nothing outside a fixture dir
echo
echo "-- 4. Dry-run non-mutation"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# Snapshot files that could plausibly be touched by a non-dry-run provision
# (HOME-scoped state this test's fixture HOME should never gain).
BEFORE_SNAPSHOT="$(find "$FIXTURE_DIR" 2>/dev/null | sort)"

DRYRUN_OUTPUT="$(
  HOME="$FIXTURE_DIR" \
  CHUMPD_PROVISION_DIR="$FIXTURE_DIR/chump-host" \
  bash "$SCRIPT" --dry-run 2>&1
)" && DRYRUN_EXIT=0 || DRYRUN_EXIT=$?

AFTER_SNAPSHOT="$(find "$FIXTURE_DIR" 2>/dev/null | sort)"

# Dry-run may create the fixture HOME's own subdirs it's told to use for
# logging/inventory purposes, but must NOT actually clone a repo (no .git)
# or write a launchd/systemd unit outside intent.
if [[ ! -d "$FIXTURE_DIR/chump-host/.git" ]]; then
  ok "dry-run did not actually clone a repo into CHUMPD_PROVISION_DIR"
else
  fail "dry-run cloned a real repo — mutation occurred under --dry-run"
fi
if echo "$DRYRUN_OUTPUT" | grep -q '\[dry-run\]'; then
  ok "dry-run output uses the [dry-run] would-do marker"
else
  fail "dry-run output missing the [dry-run] marker — can't verify no-op behavior"
fi
# Nothing should be written under the real (test-runner) $HOME/Library/LaunchAgents
# or $HOME/.config/systemd for a chumpd unit as a side effect of this test run.
if [[ ! -f "$HOME/Library/LaunchAgents/com.chump.chumpd.plist" && ! -f "$HOME/.config/systemd/user/chumpd.service" ]]; then
  ok "no chumpd service unit leaked into the real \$HOME during dry-run"
else
  fail "a chumpd service unit was written under the real \$HOME during dry-run — HOME override not honored"
fi
[[ "$DRYRUN_EXIT" -eq 0 ]] && ok "dry-run exits 0" || fail "dry-run exited non-zero ($DRYRUN_EXIT)"

# 5. No credential-looking strings baked into the script
echo
echo "-- 5. No embedded credential-shaped strings"
# GitHub PAT shapes (classic ghp_/gho_/ghu_/ghs_/ghr_ + fine-grained github_pat_),
# generic long base64/hex assignments, and Anthropic key shape sk-ant-.
CRED_PATTERNS='ghp_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|ghu_[A-Za-z0-9]{30,}|ghs_[A-Za-z0-9]{30,}|ghr_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}'
if grep -qE "$CRED_PATTERNS" "$SCRIPT" "$REPO_ROOT/scripts/setup/chumpd.service" 2>/dev/null; then
  fail "credential-shaped string found in provisioning script or service template"
else
  ok "no credential-shaped strings found (checked PAT/oauth/API-key shapes)"
fi
# The script must only CHECK presence of secrets, never echo/print a var's value.
if grep -qE 'echo.*\$GH_TOKEN\b|echo.*\$GITHUB_TOKEN\b|log.*\$GH_TOKEN\b|log.*\$GITHUB_TOKEN\b' "$SCRIPT"; then
  fail "script appears to print a credential env var's VALUE"
else
  ok "script never echoes GH_TOKEN/GITHUB_TOKEN values"
fi

# 6. No secrets-in-argv pattern (RESILIENT-173): no inline KEY=value ... cmd
# constructions with a credential-shaped name immediately before a command.
echo
echo "-- 6. RESILIENT-173 no-secrets-in-argv shape"
if grep -qE '(GH_TOKEN|GITHUB_TOKEN|OAUTH)=[^$ ]+ +[a-zA-Z]' "$SCRIPT"; then
  fail "possible inline credential=value ... cmd pattern found (argv leak shape)"
else
  ok "no inline credential=literal-value ... cmd pattern found"
fi
if grep -q 'EnvironmentFile=' "$REPO_ROOT/scripts/setup/chumpd.service" 2>/dev/null; then
  ok "chumpd.service uses EnvironmentFile= (not inline Environment=KEY=value) for credentials"
else
  fail "chumpd.service does not reference EnvironmentFile= for credential material"
fi
if grep -qE '^User=__RUN_USER__$' "$REPO_ROOT/scripts/setup/chumpd.service" 2>/dev/null; then
  ok "chumpd.service declares an explicit User= (MISSION-072 systemd parity)"
else
  fail "chumpd.service is missing an explicit User= directive"
fi
if grep -q '__RUN_USER__' "$REPO_ROOT/scripts/setup/provision-chumpd-host.sh" 2>/dev/null; then
  ok "provisioner substitutes __RUN_USER__ when writing the unit file"
else
  fail "provisioner does not substitute __RUN_USER__ into the unit file"
fi

# 7. --check / --uninstall / --dry-run / --creds-file flags present (documented usage surface)
echo
echo "-- 7. Documented flags present"
for flag in '\-\-check' '\-\-dry-run' '\-\-uninstall' '\-\-creds-file'; do
  if grep -q -- "$flag" "$SCRIPT"; then
    ok "flag $flag present"
  else
    fail "flag $flag NOT found in script"
  fi
done

# 9. Zero-touch creds (INFRA-7815 / INFRA-3629 slice) shape checks
echo
echo "-- 9. Zero-touch creds materialization shape"
if grep -q 'CHUMP_BOOTSTRAP_CREDS' "$SCRIPT"; then
  ok "\$CHUMP_BOOTSTRAP_CREDS source is wired"
else
  fail "\$CHUMP_BOOTSTRAP_CREDS not referenced in script"
fi
if grep -qE 'CREDS_FILE="\$2"' "$SCRIPT"; then
  ok "--creds-file argument value is parsed"
else
  fail "--creds-file argument value is not parsed"
fi
if grep -qE "missing required keys.*GH_TOKEN|GH_TOKEN.*missing" "$SCRIPT"; then
  ok "missing-required-key error path references GH_TOKEN"
else
  fail "no missing-required-key error path found for GH_TOKEN"
fi
if grep -qE 'log "materialized \$CHUMPD_ENV from' "$SCRIPT"; then
  ok "materialization log line names the source, not the values"
else
  fail "materialization log line not found"
fi
# Functional check: run just the chumpd.env materialization logic in isolation
# (not the full provisioner — that would require a real clone + cargo build).
MAT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/chumpd-creds-mat.XXXXXX")"
trap 'rm -rf "$MAT_TMP"' RETURN 2>/dev/null || true
printf 'GH_TOKEN=ghp_secret_should_not_leak\nCLAUDE_CODE_OAUTH_TOKEN=sk_secret_should_not_leak\n' > "$MAT_TMP/creds.env"
MAT_LOG="$MAT_TMP/out.log"
(
  set -euo pipefail
  CHUMPD_PROVISION_DIR="$MAT_TMP/repo"
  CREDS_FILE="$MAT_TMP/creds.env"
  MODE="run"
  CHUMPD_ENV="$MAT_TMP/chumpd.env"
  fail() { echo "FAIL: $*" >&2; }
  log()  { echo "LOG: $*"; }
  if [[ ! -f "$CHUMPD_ENV" && "$MODE" != "dry-run" && ( -n "$CREDS_FILE" || -n "${CHUMP_BOOTSTRAP_CREDS:-}" ) ]]; then
    mkdir -p "$(dirname "$CHUMPD_ENV")"
    if [[ -n "$CREDS_FILE" ]]; then
      [[ -f "$CREDS_FILE" ]] || { fail "--creds-file not found: $CREDS_FILE"; exit 1; }
      { printf 'CHUMP_REPO=%s\n' "$CHUMPD_PROVISION_DIR"; cat "$CREDS_FILE"; } > "$CHUMPD_ENV"
      log "materialized $CHUMPD_ENV from --creds-file (path only; values not logged)"
    fi
    chmod 600 "$CHUMPD_ENV"
    missing=""
    grep -qE '^(export )?GH_TOKEN=.+' "$CHUMPD_ENV" || missing="$missing GH_TOKEN"
    if [[ -n "$missing" ]]; then
      fail "chumpd.env materialized but missing required keys:$missing"
      exit 1
    fi
  fi
) > "$MAT_LOG" 2>&1
if [[ -f "$MAT_TMP/chumpd.env" ]] && grep -qF 'GH_TOKEN=ghp_secret_should_not_leak' "$MAT_TMP/chumpd.env"; then
  ok "--creds-file materializes chumpd.env with supplied keys"
else
  fail "chumpd.env was not materialized with the supplied --creds-file contents"
fi
if [[ "$(stat -c %a "$MAT_TMP/chumpd.env" 2>/dev/null || stat -f %Lp "$MAT_TMP/chumpd.env" 2>/dev/null)" == "600" ]]; then
  ok "materialized chumpd.env has mode 600"
else
  fail "materialized chumpd.env is not mode 600"
fi
if grep -qF 'ghp_secret_should_not_leak' "$MAT_LOG"; then
  fail "secret value leaked into materialization log output"
else
  ok "secret value never appears in materialization log output"
fi

# 8. Rust-First-Bypass trailer (META-064 shell-OK justification)
echo
echo "-- 8. META-064 compliance"
if grep -q 'Rust-First-Bypass' "$SCRIPT"; then
  ok "Rust-First-Bypass justification present"
else
  fail "Rust-First-Bypass justification NOT found (required by META-064 pre-commit hook)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
