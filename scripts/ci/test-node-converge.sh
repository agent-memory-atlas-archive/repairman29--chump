#!/usr/bin/env bash
# scripts/ci/test-node-converge.sh — RESILIENT-1189
#
# Proves the node auto-converge organ (scripts/ops/node-converge.sh) does the
# one job it exists for, safely:
#   1. a checkout BEHIND origin/main converges to origin/main (merged reaches
#      the iron), emitting node_converged;
#   2. a gitignored runtime file (.chump/state.db) SURVIVES the converge — the
#      converge is a `git reset --hard`, never a `git clean -x`, so a live DB /
#      lease dir is never wiped (RESILIENT-001 preserve-gitignored contract);
#   3. an already-current tree is an idempotent no-op (node_converge_skipped),
#      not a needless reset;
#   4. a rebase-in-progress DEFERS (node_converge_skipped, no reset) — never
#      yanks the tree out from under an in-flight operation.
#
# Fails without node-converge.sh: there is no other organ that unconditionally
# converges the SOURCE checkout (node-refresh-chump.sh skips the source reset
# whenever the binary SHA already matches green-main — the exact bash-only-merge
# hole this organ closes).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-converge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$SCRIPT" ] || fail "missing $SCRIPT"
bash -n "$SCRIPT" || fail "syntax error in $SCRIPT"
ok "bash -n passes"

# ── Fixture: bare origin + a checkout clone, origin advanced ahead ──────────
ORIGIN="$TMP/origin.git"
CHECKOUT="$TMP/checkout"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$CHECKOUT"
git -C "$CHECKOUT" config user.email test@example.com
git -C "$CHECKOUT" config user.name "Test"

# Commit a .gitignore that ignores .chump/ (mirrors the real repo) + a tracked
# organ script, then push as the base main the checkout starts on.
printf '.chump/\n' > "$CHECKOUT/.gitignore"
mkdir -p "$CHECKOUT/scripts/ops"
printf 'echo OLD\n' > "$CHECKOUT/scripts/ops/organ.sh"
git -C "$CHECKOUT" add .gitignore scripts/ops/organ.sh
git -C "$CHECKOUT" commit -q -m "base"
git -C "$CHECKOUT" push -q origin HEAD:main
BASE_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"

# Advance origin/main with a merged BASH-organ fix (the #4637 class): the
# checkout is now BEHIND by one commit.
printf 'echo NEW\n' > "$CHECKOUT/scripts/ops/organ.sh"
git -C "$CHECKOUT" commit -q -am "merged bash-organ fix"
git -C "$CHECKOUT" push -q origin HEAD:main
NEW_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"

# Roll the checkout's working tree back to base so it is genuinely behind
# origin/main (as a stale node would be), and drop a gitignored runtime DB.
git -C "$CHECKOUT" reset --hard -q "$BASE_SHA"
mkdir -p "$CHECKOUT/.chump"
printf 'LIVE-DB-BYTES' > "$CHECKOUT/.chump/state.db"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"

run_converge() {
    CHUMP_NODE_REPO="$CHECKOUT" \
    NODE_AMBIENT="$AMBIENT" \
    CHUMP_NODE_CONVERGE_LOGDIR="$TMP/logs" \
    HOME="$TMP/fakehome" \
        bash "$SCRIPT" > "$1" 2>&1
}

# ── Test 1: behind checkout converges to origin/main ───────────────────────
run_converge "$TMP/out1.log" || fail "converge run 1 exited non-zero: $(cat "$TMP/out1.log")"
LANDED="$(git -C "$CHECKOUT" rev-parse HEAD)"
[ "$LANDED" = "$NEW_SHA" ] \
    || fail "checkout landed on $LANDED, expected origin/main $NEW_SHA (base was $BASE_SHA)"
grep -q 'echo NEW' "$CHECKOUT/scripts/ops/organ.sh" \
    || fail "converged tree still has the OLD organ script body"
ok "behind checkout converged to origin/main (merged bash-organ fix reached the tree)"

grep -q '"kind":"node_converged"' "$AMBIENT" \
    || fail "expected a node_converged ambient event: $(cat "$AMBIENT" 2>/dev/null)"
ok "emitted node_converged"

# ── Test 2: gitignored runtime file survived the converge ──────────────────
[ -f "$CHECKOUT/.chump/state.db" ] \
    || fail ".chump/state.db was WIPED by the converge (must survive a reset --hard)"
[ "$(cat "$CHECKOUT/.chump/state.db")" = "LIVE-DB-BYTES" ] \
    || fail ".chump/state.db content changed across the converge"
ok "gitignored .chump/state.db survived the converge intact"

# ── Test 3: idempotent no-op on an already-current tree ────────────────────
: > "$AMBIENT"
run_converge "$TMP/out3.log" || fail "converge run 2 (idempotent) exited non-zero: $(cat "$TMP/out3.log")"
[ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$NEW_SHA" ] \
    || fail "idempotent run moved HEAD off origin/main"
grep -q '"kind":"node_converge_skipped"' "$AMBIENT" \
    || fail "expected node_converge_skipped on an already-current tree: $(cat "$AMBIENT" 2>/dev/null)"
grep -q '"reason":"already_current"' "$AMBIENT" \
    || fail "expected reason=already_current on the idempotent skip"
ok "already-current tree is an idempotent no-op skip (no needless reset)"

# ── Test 4: defers when a rebase is in progress ────────────────────────────
# Simulate an in-flight operation by creating the rebase-merge state dir, and
# put the checkout behind again so a reset WOULD move HEAD if not deferred.
git -C "$CHECKOUT" reset --hard -q "$BASE_SHA"
GITDIR="$(git -C "$CHECKOUT" rev-parse --git-dir)"
[ "${GITDIR#/}" = "$GITDIR" ] && GITDIR="$CHECKOUT/$GITDIR"
mkdir -p "$GITDIR/rebase-merge"
: > "$AMBIENT"
run_converge "$TMP/out4.log" || fail "converge run 3 (defer) exited non-zero: $(cat "$TMP/out4.log")"
[ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$BASE_SHA" ] \
    || fail "converge did NOT defer during a rebase-in-progress (HEAD moved off base)"
grep -q '"reason":"operation_in_progress"' "$AMBIENT" \
    || fail "expected reason=operation_in_progress skip during a rebase: $(cat "$AMBIENT" 2>/dev/null)"
rmdir "$GITDIR/rebase-merge"
ok "defers cleanly while a rebase is in progress (never yanks the tree mid-op)"

# ── Test 5: stale index.lock self-heals within one converge ────────────────
git -C "$CHECKOUT" reset --hard -q "$BASE_SHA"
GITDIR="$(git -C "$CHECKOUT" rev-parse --absolute-git-dir)"
: > "$GITDIR/index.lock"
: > "$AMBIENT"
CHUMP_NODE_CONVERGE_LOCK_MIN_AGE_S=0 run_converge "$TMP/out5.log" || fail "converge with stale lock exited non-zero: $(cat "$TMP/out5.log")"
[ ! -e "$GITDIR/index.lock" ] || fail "stale index.lock not cleared"
[ "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$NEW_SHA" ] || fail "converge did not complete after clearing lock"
grep -q '"kind":"node_converge_stale_lock_cleared"' "$AMBIENT" || fail "missing stale_lock_cleared event"
ok "stale index.lock cleared and converge completed in one cycle"

# ── Test 6: far-behind for >M min alarms ───────────────────────────────────
git -C "$CHECKOUT" reset --hard -q "$BASE_SHA"
: > "$AMBIENT"
CHUMP_NODE_CONVERGE_FAR_BEHIND_N=0 CHUMP_NODE_CONVERGE_FAR_BEHIND_MIN=0 run_converge "$TMP/out6.log" || fail "far-behind run failed"
grep -q '"kind":"node_converge_far_behind"' "$AMBIENT" || fail "missing node_converge_far_behind alarm: $(cat "$AMBIENT")"
ok "far-behind node raises node_converge_far_behind alarm"

# ── Test 7: _ensure_cargo_nextest idempotently provisions cargo-nextest (INFRA-8572) ──
NEXTEST_HOME="$TMP/nextest-home"
NEXTEST_CARGO="$NEXTEST_HOME/.cargo"
NEXTEST_STUB="$TMP/nextest-stub"
mkdir -p "$NEXTEST_HOME" "$NEXTEST_STUB"
cat > "$NEXTEST_STUB/cargo" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "install" && "\$2" == "cargo-nextest" ]]; then
    mkdir -p "$NEXTEST_CARGO/bin"
    printf '#!/usr/bin/env bash\necho stub-nextest\n' > "$NEXTEST_CARGO/bin/cargo-nextest"
    chmod +x "$NEXTEST_CARGO/bin/cargo-nextest"
    echo "cargo-install-invoked" >> "$TMP/nextest-install.log"
    exit 0
fi
exit 1
EOF
cat > "$NEXTEST_STUB/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$NEXTEST_STUB/cargo" "$NEXTEST_STUB/curl"

# Strip any existing cargo-nextest from PATH so the missing-then-idempotent cycle is exercised.
_CLEAN_PATH=""
IFS=: read -ra _PDIRS <<< "$PATH"
for _d in "${_PDIRS[@]}"; do
    [[ -x "$_d/cargo-nextest" ]] && continue
    _CLEAN_PATH="${_CLEAN_PATH:+$_CLEAN_PATH:}$_d"
done

(
    export HOME="$NEXTEST_HOME"
    export CARGO_HOME="$NEXTEST_CARGO"
    export PATH="$NEXTEST_STUB:$_CLEAN_PATH"
    export CHUMP_NODE_REPO="$CHECKOUT"
    export CHUMP_NODE_CONVERGE_LOGDIR="$TMP/logs"
    # shellcheck disable=SC1090
    source "$SCRIPT"
    _ensure_cargo_nextest
    [[ -x "$NEXTEST_CARGO/bin/cargo-nextest" ]] || exit 11
    # Second invocation must be idempotent (must not invoke cargo install a second time).
    _ensure_cargo_nextest
) || fail "_ensure_cargo_nextest failed to provision cargo-nextest (rc=$?)"
[[ "$(wc -l < "$TMP/nextest-install.log" | tr -d ' ')" == "1" ]] \
    || fail "_ensure_cargo_nextest was not idempotent (log: $(cat "$TMP/nextest-install.log" 2>/dev/null))"
ok "_ensure_cargo_nextest provisions cargo-nextest when absent and is idempotent when present (INFRA-8572)"

# ── Test 8: _rerender_installed_units replaces foreign host literals in installed units (INFRA-8589) ──
RERENDER_HOME="$TMP/rerender-home"
RERENDER_XDG="$RERENDER_HOME/.config"
RERENDER_UNIT_DIR="$RERENDER_XDG/systemd/user"
mkdir -p "$RERENDER_UNIT_DIR" "$CHECKOUT/scripts/dispatch" "$CHECKOUT/scripts/ops/lib"
cp "$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh" "$CHECKOUT/scripts/ops/lib/organ-unit-install-lib.sh"

cat > "$CHECKOUT/scripts/dispatch/chump-gap-close-decomposed.service" <<'EOF'
[Unit]
Description=Decomposed gap closer
[Service]
WorkingDirectory=__REPO_ROOT__
Environment=HOME=__HOME__
Environment=PATH=__BIN_DIR__:/usr/bin
ExecStart=/bin/bash __REPO_ROOT__/scripts/coord/gap-close-decomposed.sh
EOF

FOREIGN_HOME="/home/""otherhost"
cat > "$RERENDER_UNIT_DIR/chump-gap-close-decomposed.service" <<EOF
[Unit]
Description=Decomposed gap closer
[Service]
User=otherhost
WorkingDirectory=${FOREIGN_HOME}/chump
Environment=HOME=${FOREIGN_HOME}
Environment=PATH=${FOREIGN_HOME}/bin:/opt/homebrew/bin:/usr/bin
ExecStart=/bin/bash ${FOREIGN_HOME}/chump/scripts/coord/gap-close-decomposed.sh
EOF

(
    export HOME="$RERENDER_HOME"
    export XDG_CONFIG_HOME="$RERENDER_XDG"
    export USER="ubuntu"
    export PATH="$NEXTEST_STUB:$_CLEAN_PATH"
    export CHUMP_NODE_REPO="$CHECKOUT"
    export CHUMP_NODE_CONVERGE_LOGDIR="$TMP/logs"
    # shellcheck disable=SC1090
    source "$SCRIPT"
    _rerender_installed_units
) || fail "_rerender_installed_units failed (rc=$?)"

if grep -qE "${FOREIGN_HOME}|/opt/homebrew|^User=" "$RERENDER_UNIT_DIR/chump-gap-close-decomposed.service"; then
    fail "installed unit still carries foreign host literals after _rerender_installed_units: $(cat "$RERENDER_UNIT_DIR/chump-gap-close-decomposed.service")"
fi
CHECKOUT_REAL="$(cd "$CHECKOUT" && pwd -P)"
grep -qF "WorkingDirectory=$CHECKOUT_REAL" "$RERENDER_UNIT_DIR/chump-gap-close-decomposed.service"     || fail "installed unit was not rewritten with CHECKOUT WorkingDirectory: $(cat "$RERENDER_UNIT_DIR/chump-gap-close-decomposed.service")"
ok "_rerender_installed_units replaces foreign host literals in installed units from repo templates (INFRA-8589)"

# ── Test 9: RESILIENT-1684 + INFRA-8104: node.env bare KEY=VALUE parity + listener-gated team store keys ──
# Helper: compare keys+values parsed by systemd EnvironmentFile rules vs bash `set -a; source`.
_assert_systemd_shell_env_parity() {
    local env_file="$1"
    python3 - "$env_file" <<'PY'
import re, sys

path = sys.argv[1]
systemd_map = {}
shell_map = {}
ident_re = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')

with open(path, "r", encoding="utf-8") as f:
    for raw in f:
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        # systemd EnvironmentFile rule: rejects `export KEY=VALUE`
        if "=" in s and not s.startswith(";"):
            k, v = s.split("=", 1)
            if ident_re.match(k):
                if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
                    v = v[1:-1]
                systemd_map[k] = v
        # shell `set -a; source` rule: accepts optional leading `export `
        sh = re.sub(r'^export[\s]+', '', s)
        if "=" in sh:
            k, v = sh.split("=", 1)
            if ident_re.match(k):
                if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
                    v = v[1:-1]
                shell_map[k] = v

if systemd_map != shell_map:
    sys.exit(1)
PY
}

T9_ENV="$TMP/t9-node.env"
cat > "$T9_ENV" <<'EOF'
# mixed export and bare lines + team store keys
export CHUMP_NODE_ROLE=muscle
export CHUMP_RUN_USER=ubuntu
CHUMP_NODE_WORK_ENABLED=1
export CHUMP_STORE_BACKEND=team
export CHUMP_TEAM_URL=http://127.0.0.1:59999
export CHUMP_TEAM_API_KEY=blind-team-key
EOF

# Mutant check first: raw file with `export ` MUST fail systemd vs shell parity.
if _assert_systemd_shell_env_parity "$T9_ENV"; then
    fail "RESILIENT-1684 mutant: file with `export ` lines unexpectedly passed systemd/shell parity"
fi

# Sanitize with store NOT listening -> strips `export ` AND omits team-store keys.
(
    export CHUMP_TEAM_STORE_LISTENING=0
    # shellcheck disable=SC1090
    source "$SCRIPT"
    _sanitize_node_env "$T9_ENV"
) || fail "_sanitize_node_env (store down) failed"

_assert_systemd_shell_env_parity "$T9_ENV" \
    || fail "RESILIENT-1684: sanitized node.env failed systemd vs shell parity: $(cat "$T9_ENV")"
grep -qE '^(CHUMP_STORE_BACKEND|CHUMP_TEAM_URL|CHUMP_TEAM_API_KEY)=' "$T9_ENV" \
    && fail "INFRA-8104: team-store keys were emitted when store was not listening: $(cat "$T9_ENV")"

# Now re-add team-store keys and sanitize with store LISTENING -> bare KEY=VALUE kept.
cat >> "$T9_ENV" <<'EOF'
export CHUMP_STORE_BACKEND=team
export CHUMP_TEAM_URL=http://127.0.0.1:8788
export CHUMP_TEAM_API_KEY=live-team-key
EOF
(
    export CHUMP_TEAM_STORE_LISTENING=1
    # shellcheck disable=SC1090
    source "$SCRIPT"
    _sanitize_node_env "$T9_ENV"
) || fail "_sanitize_node_env (store up) failed"

_assert_systemd_shell_env_parity "$T9_ENV" \
    || fail "RESILIENT-1684: sanitized node.env (store up) failed systemd vs shell parity: $(cat "$T9_ENV")"
grep -qx 'CHUMP_STORE_BACKEND=team' "$T9_ENV" \
    && grep -qx 'CHUMP_TEAM_URL=http://127.0.0.1:8788' "$T9_ENV" \
    && grep -qx 'CHUMP_TEAM_API_KEY=live-team-key' "$T9_ENV" \
    || fail "INFRA-8104: bare team-store keys missing when store is listening: $(cat "$T9_ENV")"
ok "RESILIENT-1684 + INFRA-8104: node.env is bare KEY=VALUE (systemd == shell parity, mutant-killed) and team-store keys are gated on a live listener"

# ── Test 10: RESILIENT-1684: organ-reconcile & node-converge single-scope deduplication ──
T10_SYS="$TMP/t10-sys"
T10_USR="$TMP/t10-usr"
mkdir -p "$T10_SYS" "$T10_USR"
touch "$T10_SYS/chump-organ-reconcile.timer" "$T10_SYS/chump-organ-reconcile.service"
touch "$T10_SYS/chump-node-converge.timer" "$T10_SYS/chump-node-converge.service"
touch "$T10_USR/chump-organ-reconcile.timer" "$T10_USR/chump-organ-reconcile.service"
touch "$T10_USR/chump-node-converge.timer" "$T10_USR/chump-node-converge.service"

(
    export CHUMP_NODE_CONVERGE_LOGDIR="$TMP/logs"
    export NODE_AMBIENT="$AMBIENT"
    # shellcheck disable=SC1090
    source "$SCRIPT"
    _dedupe_single_scope_organs "$T10_SYS" "$T10_USR" "/bin/true"
) || fail "_dedupe_single_scope_organs failed"

[[ ! -e "$T10_USR/chump-organ-reconcile.timer" && ! -e "$T10_USR/chump-node-converge.timer" ]] \
    || fail "RESILIENT-1684: duplicate --user units were not removed when --system units exist"
[[ -f "$T10_SYS/chump-organ-reconcile.timer" && -f "$T10_SYS/chump-node-converge.timer" ]] \
    || fail "RESILIENT-1684: canonical --system units were unexpectedly removed"
ok "RESILIENT-1684: organ-reconcile and node-converge are deduplicated to one systemd scope"

# ── Test 11: RESILIENT-1682: converge scrubs bypass env assignments from live worker launchers ──
T11_HOME="$TMP/t11-home"
mkdir -p "$T11_HOME/.chump/organs"
_T11_PF_SKIP="CHUMP_PREFLIGHT_""SKIP"
cat > "$T11_HOME/node1-worker-run.sh" <<EOF
#!/usr/bin/env bash
export AGENT_ID="node1-worker"
export CHUMP_TEST_GATE=0
export ${_T11_PF_SKIP}=1
exec bash scripts/dispatch/worker.sh
EOF
chmod +x "$T11_HOME/node1-worker-run.sh"

(
    export HOME="$T11_HOME"
    export CHUMP_STATE_DIR="$T11_HOME/.chump"
    export CHUMP_NODE_CONVERGE_LOGDIR="$TMP/logs"
    export NODE_AMBIENT="$AMBIENT"
    # shellcheck disable=SC1090
    source "$SCRIPT"
    if _validate_worker_launcher_no_bypass "$T11_HOME/node1-worker-run.sh"; then
        exit 21
    fi
    _converge_worker_launchers
    _validate_worker_launcher_no_bypass "$T11_HOME/node1-worker-run.sh" || exit 22
) || fail "RESILIENT-1682: _converge_worker_launchers failed to detect and scrub bypass assignments (rc=$?)"
ok "RESILIENT-1682: live worker launcher bypass assignments (CHUMP_TEST_GATE=0 / preflight skip) are rejected and scrubbed"

# ── Test 12: CREDIBLE-1585: headless claude secret scrubbing + grep gate against wholesale `set -a` on providers.env ──
# 12a. Grep gate: no unit file under scripts/dispatch or scripts/ops may source providers.env under `set -a`.
_check_units_no_wholesale_providers_env() {
    grep -nE 'set -a.*providers\.env' "$@" 2>/dev/null
}
_bad_units="$(_check_units_no_wholesale_providers_env "$REPO_ROOT"/scripts/dispatch/*.service "$REPO_ROOT"/scripts/ops/*.service "$REPO_ROOT"/scripts/ops/systemd/*.service)"
[[ -z "$_bad_units" ]] \
    || fail "CREDIBLE-1585: unit file(s) source providers.env wholesale with set -a: $_bad_units"

# Mutant check for the grep gate.
T12_MUT_UNIT="$TMP/t12-mutant.service"
printf '[Service]\nExecStart=/bin/bash -lc "set -a; source __HOME__/.chump/providers.env; set +a; exec true"\n' > "$T12_MUT_UNIT"
if [[ -z "$(_check_units_no_wholesale_providers_env "$T12_MUT_UNIT")" ]]; then
    fail "CREDIBLE-1585 mutant: grep gate failed to catch a unit sourcing providers.env with set -a"
fi

# 12b. Behavioral check: plant SUPABASE_SERVICE_ROLE_KEY=fake-secret and
# POSTGRES_PASSWORD=fake-db-pass in parent env + providers.env and prove they
# are absent in the spawned headless claude child environment.
T12_PROVIDERS="$TMP/t12-providers.env"
cat > "$T12_PROVIDERS" <<'EOF'
export ANTHROPIC_API_KEY=fake-model-key
export GH_TOKEN=fake-gh-tok
export SUPABASE_SERVICE_ROLE_KEY=fake-secret
export POSTGRES_PASSWORD=fake-db-pass
export OCI_CLI_KEY_CONTENT=fake-oci
export AWS_SECRET_ACCESS_KEY=fake-aws
export STRIPE_SECRET_KEY=fake-stripe
export CHUMP_SUBSTRATE_DB_PASSWORD=fake-sub-pass
EOF

T12_CHILD_ENV="$(
    export SUPABASE_SERVICE_ROLE_KEY="fake-secret"
    export POSTGRES_PASSWORD="fake-db-pass"
    export OCI_CLI_KEY_CONTENT="fake-oci"
    export AWS_SECRET_ACCESS_KEY="fake-aws"
    export STRIPE_SECRET_KEY="fake-stripe"
    export CHUMP_SUBSTRATE_DB_PASSWORD="fake-sub-pass"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/scripts/dispatch/lib/load-provider-auth.env" "$T12_PROVIDERS"
    # Extract and run the headless claude env scrubber from architect-tick.sh
    eval "$(awk '/^_scrub_headless_claude_env\(\)/{f=1} f{print} f && /^\}/{exit}' "$REPO_ROOT/scripts/dispatch/architect-tick.sh")"
    _scrub_headless_claude_env
    env
)"

for _leaked in SUPABASE_SERVICE_ROLE_KEY POSTGRES_PASSWORD OCI_CLI_KEY_CONTENT AWS_SECRET_ACCESS_KEY STRIPE_SECRET_KEY CHUMP_SUBSTRATE_DB_PASSWORD; do
    if printf '%s\n' "$T12_CHILD_ENV" | grep -qE "^${_leaked}="; then
        fail "CREDIBLE-1585: forbidden secret $_leaked leaked into headless claude child env"
    fi
done
printf '%s\n' "$T12_CHILD_ENV" | grep -qx 'ANTHROPIC_API_KEY=fake-model-key' \
    || fail "CREDIBLE-1585: allowlisted ANTHROPIC_API_KEY missing in headless claude child env"
printf '%s\n' "$T12_CHILD_ENV" | grep -qx 'GH_TOKEN=fake-gh-tok' \
    || fail "CREDIBLE-1585: allowlisted GH_TOKEN missing in headless claude child env"
ok "CREDIBLE-1585: SUPABASE_SERVICE_ROLE_KEY and POSTGRES_PASSWORD are scrubbed from headless claude spawns and no unit sources providers.env with set -a"

# ── Test 13: INFRA-8089: _converge_git_noreply_identity sets global noreply and resets local non-noreply overrides ──
T13_HOME="$TMP/t13-home"
T13_REPO="$TMP/t13-repo"
T13_AMBIENT="$TMP/t13-ambient.jsonl"
mkdir -p "$T13_HOME" "$T13_REPO"
git init -q "$T13_REPO"
git -C "$T13_REPO" config --local user.email "private-leak@gmail.com"
mkdir -p "$T13_REPO/.git/worktrees/wt1"
git config --file "$T13_REPO/.git/worktrees/wt1/config.worktree" user.email "t@t.t"

(
    export HOME="$T13_HOME"
    export CHUMP_NODE_REPO="$T13_REPO"
    export CHUMP_NODE_CONVERGE_LOGDIR="$TMP/logs"
    export NODE_AMBIENT="$T13_AMBIENT"
    # shellcheck disable=SC1090
    source "$SCRIPT"
    _converge_git_noreply_identity "$T13_REPO"
) > "$TMP/t13.out" 2>&1 || fail "INFRA-8089: _converge_git_noreply_identity failed"

EXPECT_NOREPLY="204632470+repairman29@users.noreply.github.com"
[[ "$(HOME="$T13_HOME" git config --global user.email)" == "$EXPECT_NOREPLY" ]] \
    || fail "INFRA-8089: global user.email not set to $EXPECT_NOREPLY"
[[ "$(git -C "$T13_REPO" config --local user.email)" == "$EXPECT_NOREPLY" ]] \
    || fail "INFRA-8089: local user.email override in $T13_REPO was not reset to $EXPECT_NOREPLY"
[[ "$(git config --file "$T13_REPO/.git/worktrees/wt1/config.worktree" user.email)" == "$EXPECT_NOREPLY" ]] \
    || fail "INFRA-8089: worktree config user.email override was not reset to $EXPECT_NOREPLY"
grep -q 'INFRA-8089: reset non-noreply local user.email' "$TMP/t13.out" \
    || fail "INFRA-8089: expected report of non-noreply local user.email reset: $(cat "$TMP/t13.out")"
grep -q '"kind":"identity_residue_swept"' "$T13_AMBIENT" \
    || fail "INFRA-8089: expected identity_residue_swept ambient event"
ok "INFRA-8089: _converge_git_noreply_identity sets global noreply and resets/reports local non-noreply overrides"

# ── Test 14: INFRA-8106: _ensure_pr_book_timer installs chump-pr-book.{service,timer} alongside settle timer ──
T14_UNITS="$TMP/t14-units"
mkdir -p "$T14_UNITS"
touch "$T14_UNITS/chump-pr-book-settle.timer"
cp "$REPO_ROOT/scripts/dispatch/chump-pr-book.service" "$CHECKOUT/scripts/dispatch/chump-pr-book.service"
cp "$REPO_ROOT/scripts/dispatch/chump-pr-book.timer" "$CHECKOUT/scripts/dispatch/chump-pr-book.timer"
(
    export HOME="$RERENDER_HOME"
    export USER="ubuntu"
    export CHUMP_NODE_REPO="$CHECKOUT"
    export CHUMP_NODE_CONVERGE_LOGDIR="$TMP/logs"
    # shellcheck disable=SC1090
    source "$SCRIPT"
    _ensure_pr_book_timer "$T14_UNITS"
) || fail "INFRA-8106: _ensure_pr_book_timer failed"
[[ -f "$T14_UNITS/chump-pr-book.service" && -f "$T14_UNITS/chump-pr-book.timer" ]] \
    || fail "INFRA-8106: chump-pr-book.{service,timer} not installed into $T14_UNITS"
grep -qF "$CHECKOUT_REAL/scripts/coord/pr-book.sh" "$T14_UNITS/chump-pr-book.service" \
    || fail "INFRA-8106: rendered chump-pr-book.service missing host-rewritten pr-book.sh ExecStart"
ok "INFRA-8106: _ensure_pr_book_timer renders and installs chump-pr-book.{service,timer} alongside settle timer"

printf '\033[0;32mALL PASS\033[0m scripts/ci/test-node-converge.sh\n'
