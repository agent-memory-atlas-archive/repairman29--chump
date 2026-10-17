#!/usr/bin/env bash
# test-gap-sync.sh — INFRA-2053, export-only since INFRA-8193
#
# Verifies `chump gap sync` (state.db -> YAML mirror) across five drift
# classes on a synthetic fixture. state.db is the only truth: YAML never
# writes back into it.
#   1. YAML-only          : YAML exists, no DB row.        Stays drift (never imported).
#   2. DB-only            : DB row exists, no YAML.         Push creates YAML.
#   3. AC divergence      : DB has TODO ACs, YAML concrete. Push repaints YAML from DB.
#   4. Title divergence   : Both exist, titles differ.      Push repaints YAML from DB.
#   5. Shipped gap        : DB done, YAML stale open.       Push repaints YAML to done.
#
# Smoke test contract:
#   - `sync --check` exits non-zero + lists all 5 drift instances.
#   - `sync --pull` (and `--pull --dry-run`) is REFUSED with exit 2, names
#     `chump store reconcile`, and leaves the DB untouched (INFRA-8193).
#   - `sync --push` writes YAML for cases 2-5 from the DB.
#   - `sync --check` rerun reports only case1 (yaml-only), never imported.
#
# Uses a tempdir + temp state.db; never touches the real .chump/state.db
# or docs/gaps/. Disables ambient.jsonl writes via CHUMP_AMBIENT_DISABLE.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

# Locate the chump binary (built in target/debug after cargo check or test).
CHUMP_BIN=""
for cand in \
    "$REPO_ROOT/target/debug/chump" \
    "$REPO_ROOT/target/release/chump" \
    "$HOME/.cargo/bin/chump"; do
    if [[ -x "$cand" ]]; then
        CHUMP_BIN="$cand"
        break
    fi
done
if [[ -z "$CHUMP_BIN" ]]; then
    info "chump binary not found in target/debug, building..."
    (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --bin chump --quiet)
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
fi
info "using chump: $CHUMP_BIN"

TMP="$(mktemp -d -t test-infra-2053.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Set up a fake worktree layout so chump can find docs/gaps/ ────────────
FAKE_ROOT="$TMP/fake-root"
mkdir -p "$FAKE_ROOT/docs/gaps" "$FAKE_ROOT/.chump"
FAKE_DB="$FAKE_ROOT/.chump/state.db"

# Disable ambient emit so the test doesn't write to the real ambient.jsonl
# or any side-channel telemetry.
export CHUMP_AMBIENT_DISABLE=1
# Override the canonical state.db location.
export CHUMP_STATE_DB="$FAKE_DB"

# Bootstrap an empty state.db with the minimal `gaps` table the sync module
# needs. We can't use `chump gap list` to do this because it would trigger
# INFRA-821 auto-seed-if-empty, which imports the *real* repo's docs/gaps/
# into the test DB. So we create the schema directly. Columns mirror the
# canonical schema in chump-gap-store/src/lib.rs `migrate()`; sync only
# touches the gaps table.
sqlite3 "$FAKE_DB" <<'SCHEMA'
CREATE TABLE IF NOT EXISTS gaps (
    id                  TEXT PRIMARY KEY,
    domain              TEXT NOT NULL DEFAULT '',
    title               TEXT NOT NULL DEFAULT '',
    description         TEXT NOT NULL DEFAULT '',
    priority            TEXT NOT NULL DEFAULT '',
    effort              TEXT NOT NULL DEFAULT '',
    status              TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on          TEXT NOT NULL DEFAULT '',
    notes               TEXT NOT NULL DEFAULT '',
    source_doc          TEXT NOT NULL DEFAULT '',
    created_at          INTEGER NOT NULL DEFAULT 0,
    closed_at           INTEGER,
    opened_date         TEXT NOT NULL DEFAULT '',
    closed_date         TEXT NOT NULL DEFAULT '',
    closed_pr           INTEGER,
    skills_required     TEXT NOT NULL DEFAULT '',
    preferred_backend   TEXT NOT NULL DEFAULT '',
    preferred_machine   TEXT NOT NULL DEFAULT '',
    estimated_minutes   TEXT NOT NULL DEFAULT '',
    required_model      TEXT NOT NULL DEFAULT ''
);
SCHEMA

# Sanity: was the DB created?
if [[ ! -f "$FAKE_DB" ]]; then
    fail "state.db was not initialised at $FAKE_DB"
fi
info "state.db initialised: $FAKE_DB"

# ── Seed the four drift cases ───────────────────────────────────────────
# Case 1: YAML-only (no DB row).
cat > "$FAKE_ROOT/docs/gaps/INFRA-9101.yaml" <<'EOF'
- id: INFRA-9101
  domain: INFRA
  title: case1-yaml-only
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - first AC
    - second AC
EOF

# Case 2: DB-only (no YAML on disk).
sqlite3 "$FAKE_DB" "INSERT INTO gaps(id, domain, title, status, priority, effort, acceptance_criteria, depends_on, created_at) VALUES ('INFRA-9102', 'INFRA', 'case2-db-only', 'open', 'P1', 's', '[\"only-in-db\"]', '[]', 100);"

# Case 3: TODO-AC overwrite — DB has TODO ACs, YAML has concrete ACs.
sqlite3 "$FAKE_DB" "INSERT INTO gaps(id, domain, title, status, priority, effort, acceptance_criteria, depends_on, created_at) VALUES ('INFRA-9103', 'INFRA', 'case3-todo-ac', 'open', 'P1', 's', '[\"TODO: define acceptance criteria\"]', '[]', 100);"
cat > "$FAKE_ROOT/docs/gaps/INFRA-9103.yaml" <<'EOF'
- id: INFRA-9103
  domain: INFRA
  title: case3-todo-ac
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - concrete recovered AC 1
    - concrete recovered AC 2
EOF

# Case 4: Title divergence — both exist, titles differ.
sqlite3 "$FAKE_DB" "INSERT INTO gaps(id, domain, title, status, priority, effort, acceptance_criteria, depends_on, created_at) VALUES ('INFRA-9104', 'INFRA', 'case4-DB-WAS-HERE', 'open', 'P1', 's', '[\"the AC\"]', '[]', 100);"
cat > "$FAKE_ROOT/docs/gaps/INFRA-9104.yaml" <<'EOF'
- id: INFRA-9104
  domain: INFRA
  title: case4-YAML-NOW-WINS
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - the AC
EOF

# Case 5 (INFRA-3606): shipped gap — DB status=done, YAML mirror stale at
# open (push never rewrites terminal-status YAMLs). Pull must NOT revert
# the done status — this is the canonical-store split-brain fix.
sqlite3 "$FAKE_DB" "INSERT INTO gaps(id, domain, title, status, priority, effort, acceptance_criteria, depends_on, created_at) VALUES ('INFRA-9105', 'INFRA', 'case5-shipped', 'done', 'P1', 's', '[\"the AC\"]', '[]', 100);"
cat > "$FAKE_ROOT/docs/gaps/INFRA-9105.yaml" <<'EOF'
- id: INFRA-9105
  domain: INFRA
  title: case5-shipped
  status: open
  priority: P1
  effort: s
  acceptance_criteria:
    - the AC
EOF

# ── 1. `sync --check` reports 5 drift entries, exits non-zero ───────────
info "step 1: chump gap sync --check (expect 5 drift entries, non-zero exit)"
set +e
CHECK_OUT="$("$CHUMP_BIN" gap sync --check --state-db "$FAKE_DB" --gaps-dir "$FAKE_ROOT/docs/gaps" --json 2>&1)"
CHECK_RC=$?
set -e

if [[ $CHECK_RC -eq 0 ]]; then
    fail "expected non-zero exit on drift, got 0. Output:\n$CHECK_OUT"
fi
echo "$CHECK_OUT" | grep -q 'INFRA-9101' || fail "case1 missing from check output"
echo "$CHECK_OUT" | grep -q 'INFRA-9102' || fail "case2 missing from check output"
echo "$CHECK_OUT" | grep -q 'INFRA-9103' || fail "case3 missing from check output"
echo "$CHECK_OUT" | grep -q 'INFRA-9104' || fail "case4 missing from check output"
echo "$CHECK_OUT" | grep -q 'INFRA-9105' || fail "case5 missing from check output"
echo "$CHECK_OUT" | grep -q 'yaml-only' || fail "case1 expected kind 'yaml-only' missing"
echo "$CHECK_OUT" | grep -q 'db-only' || fail "case2 expected kind 'db-only' missing"
echo "$CHECK_OUT" | grep -q 'divergent' || fail "divergent kind missing (case3+case4+case5)"
pass "check reported all 5 drift cases + non-zero exit ($CHECK_RC)"

# ── 2. `sync --pull` is refused and the DB is untouched (INFRA-8193) ────
info "step 2: chump gap sync --pull (expect exit 2, no DB mutation)"
DB_BEFORE="$(sqlite3 "$FAKE_DB" "SELECT id||'|'||title||'|'||status||'|'||acceptance_criteria FROM gaps ORDER BY id;")"
for pull_args in "--pull" "--pull --dry-run" "--pull --json"; do
    set +e
    # shellcheck disable=SC2086
    PULL_OUT="$("$CHUMP_BIN" gap sync $pull_args --state-db "$FAKE_DB" --gaps-dir "$FAKE_ROOT/docs/gaps" 2>&1)"
    PULL_RC=$?
    set -e
    [[ $PULL_RC -eq 2 ]] || fail "'sync $pull_args' should exit 2 (refused); got $PULL_RC. Output:\n$PULL_OUT"
    echo "$PULL_OUT" | grep -q 'chump store reconcile' \
        || fail "'sync $pull_args' refusal must point at chump store reconcile. Output:\n$PULL_OUT"
done
DB_AFTER="$(sqlite3 "$FAKE_DB" "SELECT id||'|'||title||'|'||status||'|'||acceptance_criteria FROM gaps ORDER BY id;")"
[[ "$DB_BEFORE" == "$DB_AFTER" ]] || fail "refused --pull mutated the DB"
[[ -z "$(sqlite3 "$FAKE_DB" "SELECT id FROM gaps WHERE id='INFRA-9101';")" ]] \
    || fail "case1 YAML-only gap was imported into the DB"
pass "--pull refused (exit 2, names chump store reconcile), DB untouched"

# ── 3. `sync --push` repaints YAML from the DB for cases 2-5 ────────────
info "step 3: chump gap sync --push (expect case2..case5 YAML written from DB)"
set +e
PUSH_OUT="$("$CHUMP_BIN" gap sync --push --state-db "$FAKE_DB" --gaps-dir "$FAKE_ROOT/docs/gaps" --json 2>&1)"
PUSH_RC=$?
set -e
[[ $PUSH_RC -eq 0 ]] || fail "push exited non-zero: $PUSH_RC. Output:\n$PUSH_OUT"
[[ -f "$FAKE_ROOT/docs/gaps/INFRA-9102.yaml" ]] \
    || fail "case2 YAML not created at $FAKE_ROOT/docs/gaps/INFRA-9102.yaml"
grep -q 'case2-db-only' "$FAKE_ROOT/docs/gaps/INFRA-9102.yaml" || fail "case2 YAML missing title"
grep -q 'only-in-db' "$FAKE_ROOT/docs/gaps/INFRA-9102.yaml" || fail "case2 YAML missing AC"
pass "case2 YAML written by push"
grep -q 'case4-DB-WAS-HERE' "$FAKE_ROOT/docs/gaps/INFRA-9104.yaml" \
    || fail "case4 YAML should carry the DB title after push: $(cat "$FAKE_ROOT/docs/gaps/INFRA-9104.yaml")"
pass "case4 YAML repainted from the DB (the store wins)"
grep -q 'status: done' "$FAKE_ROOT/docs/gaps/INFRA-9105.yaml" \
    || fail "case5 YAML still says status != done after push: $(cat "$FAKE_ROOT/docs/gaps/INFRA-9105.yaml")"
pass "case5 YAML refreshed to status: done by push"
CASE4_TITLE=$(sqlite3 "$FAKE_DB" "SELECT title FROM gaps WHERE id='INFRA-9104';")
[[ "$CASE4_TITLE" == "case4-DB-WAS-HERE" ]] || fail "push must never write the DB (case4 title now '$CASE4_TITLE')"

# ── 4. Final `sync --check`: only the never-imported case1 remains ─────
info "step 4: chump gap sync --check after push (expect only case1 yaml-only)"
set +e
CHECK_OUT2="$("$CHUMP_BIN" gap sync --check --state-db "$FAKE_DB" --gaps-dir "$FAKE_ROOT/docs/gaps" --json 2>&1)"
CHECK_RC2=$?
set -e
[[ $CHECK_RC2 -ne 0 ]] || fail "expected non-zero (case1 yaml-only still drifted); got 0"
echo "$CHECK_OUT2" | grep -q '"drift_count":1' || fail "expected exactly 1 drift entry: $CHECK_OUT2"
echo "$CHECK_OUT2" | grep -q 'INFRA-9101' || fail "case1 should remain as yaml-only drift: $CHECK_OUT2"
echo "$CHECK_OUT2" | grep -q 'yaml-only' || fail "case1 drift kind should be yaml-only: $CHECK_OUT2"
pass "post-push check: only case1 (yaml-only, never imported) remains"

printf '\n[ALL PASS] test-gap-sync.sh\n'
