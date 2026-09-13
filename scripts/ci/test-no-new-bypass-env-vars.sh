#!/usr/bin/env bash
# scripts/ci/test-no-new-bypass-env-vars.sh — INFRA-2429
#
# CI lint: forbids NEW CHUMP_*_BYPASS, CHUMP_*_SKIP, and CHUMP_IGNORE_*
# env var introductions in PR diffs.
#
# WHAT THIS DOES:
#   1. Computes a diff of added lines vs origin/main (or BASE_REF).
#   2. Scans for newly-introduced bypass-class env var names in:
#      - Rust source: std::env::var("CHUMP_..._BYPASS|SKIP"), env! macros
#      - Shell source: ${CHUMP_..._BYPASS|SKIP}, $CHUMP_..._BYPASS|SKIP
#      - scripts/ci/env-vars-internal.txt: new lines matching the patterns
#   3. For each found var name, checks scripts/ci/bypass-env-var-allowlist.txt.
#   4. Exits 1 if any unallowlisted bypass-class var is introduced.
#   5. *_DISABLED vars are NOT scanned — those are Category B operator
#      emergency kill-switches that are intentionally permitted.
#
# OPERATOR ZERO-BYPASS THESIS (INFRA-2429):
#   This script has NO env-var bypass of its own. If you need a short-term
#   exception, add the var name to bypass-env-var-allowlist.txt with a
#   Bypass-Justification: comment referencing a gap_id for tracking.
#
# Usage:
#   bash scripts/ci/test-no-new-bypass-env-vars.sh         # full mode
#   BASE_REF=some-branch bash scripts/ci/...               # custom base ref
#
# Self-test mode (AC step 5):
#   TEST_SELF_TEST=1 bash scripts/ci/test-no-new-bypass-env-vars.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALLOWLIST="$REPO_ROOT/scripts/ci/bypass-env-var-allowlist.txt"

# ── Self-test mode ─────────────────────────────────────────────────────────────
if [[ "${TEST_SELF_TEST:-0}" == "1" ]]; then
  bash "$REPO_ROOT/scripts/ci/test-no-new-bypass-env-vars.sh" --self-test
  exit $?
fi

# ── EFFECTIVE-094: bypass-var DEBT-CEILING (the addition tax) ────────────────────
# The allowlist logic below permits growth-with-paperwork — which is exactly how
# the count climbed 113 → 233. This is the hard ceiling: the TOTAL distinct
# bypass/skip/check CHUMP_* var count must not EXCEED scripts/ci/bypass-var-ceiling.txt.
# To add a var you must delete one (net-negative). The only way UP is the operator
# editing the ceiling file with a reason. A cull (count < ceiling) prints a nudge to
# ratchet the ceiling down, so the floor only ever falls. Skipped in --self-test.
# DELIBERATELY no env bypass: an anti-bypass gate must not ship its own bypass var
# (that would both defeat the purpose AND add to the count). The ONLY way up is the
# operator editing the ceiling file — a visible, reviewed, single source of truth.
# ── RESILIENT-298: functional read-site detector (shared by the debt-ceiling
# counter above and its self-test below). Returns 0 (true) iff the given bypass
# var name is READ somewhere under the given roots — shell $VAR/${VAR}, an inline
# `VAR=... cmd` assignment, or an env accessor (Rust env::var / this repo's
# env_trim_eq|env_flags|env_bool helpers, C getenv, Python os.environ|os.getenv,
# JS process.env, Deno.env). A name that appears ONLY as a bare string mention
# (doc/registry/comment/absence-assertion/concat-fragment) has no read-site and is
# NOT a functional bypass. Feed it a COMMENT-STRIPPED haystack (see _strip_comments
# + _count_bypass_debt) so a read-shaped string inside a comment is never a hit.
_bypass_var_has_readsite() {
  local _v="$1"; shift
  local _tmpl='(\$\{?VAR\b|env::var(_os)?\([[:space:]]*"?VAR|env_trim_eq\([[:space:]]*"?VAR|env_flags::[a-z_]+\([[:space:]]*"?VAR|env_bool\([[:space:]]*"?VAR|getenv\([[:space:]]*"?VAR|os\.getenv\([[:space:]]*"?VAR|os\.environ[^)]*VAR|process\.env[.\[][[:space:]]*"?VAR|Deno\.env[^)]*VAR|(^|[^A-Za-z0-9_])VAR=)'
  local _rx="${_tmpl//VAR/$_v}"
  grep -rqE "$_rx" "$@" 2>/dev/null
}

# ── INFRA-6073: comment stripper (the honest-counting fix). RESILIENT-298 made the
# counter require a functional read-site, but it tested that read-site against a RAW
# haystack that still included COMMENT lines — so a read-SHAPED string sitting inside
# a comment (e.g. a `// see env::var("CHUMP_X_BYPASS")` doc line, or a `# CHUMP_X_SKIP=1`
# usage note) matched the read-site regex and counted as a phantom. That is the exact
# self-defeating failure INFRA-6073 tracks: PR #4637 tripped `count 219 > ceiling 218`
# purely by NAMING CHUMP_ROT_REAPER_SPARE_RECOVERABLE in a code comment, blocking the
# very rot-reaper fix meant to reduce debt. This filter removes comment content before
# the read-site test, so ONLY real code reads are counted. It removes: full-line comments
# (leading #, //, *, /*, or > markdown-quote) and trailing inline # / // comments.
# Deterministic, language-agnostic, one awk pass (fast in CI). Over-stripping can only
# ever DROP a would-be hit (never invent one), so it cannot hide a genuine bypass.
_strip_comments() {
  awk '
    {
      s = $0; sub(/^[ \t]+/, "", s)
      if (s ~ /^#/)    next   # shell / python / yaml / toml full-line comment
      if (s ~ /^\/\//) next   # rust / js / c++ full-line comment
      if (s ~ /^\*/)   next   # block-comment body line
      if (s ~ /^\/\*/) next   # block-comment opener
      if (s ~ /^>/)    next   # markdown blockquote
      line = $0
      sub(/[ \t]+#.*$/,   "", line)   # trailing shell/py comment
      sub(/[ \t]+\/\/.*$/, "", line)  # trailing rust/js comment
      print line
    }'
}

# ── INFRA-6073: count DISTINCT bypass-class vars that have a real read-site under
# the given source roots. Shared by the debt-ceiling block and its self-test so the
# test exercises the real counting path. Excludes this gate's own bookkeeping files
# (self-test fixtures, ceiling changelog, allowlist, env registry) and docs/*.md, and
# strips comments before matching — so the count is real read-backed bypass debt, not
# string-mentions in prose. NOTE: scripts/ci/test-*.sh files are NOT excluded — in this
# repo those ARE the real CI gate implementations (e.g. this file, test-silent-failure-
# tax.sh), so their bypass reads are genuine debt. Prints the integer count to stdout.
_count_bypass_debt() {
  local _cands _hayfile _v _n=0
  _cands="$(grep -rhoE 'CHUMP_[A-Z0-9_]*(BYPASS|SKIP|IGNORE|_CHECK|NO_)[A-Z0-9_]*' \
            "$@" 2>/dev/null \
            --exclude='test-no-new-bypass-env-vars.sh' \
            --exclude='bypass-var-ceiling.txt' \
            --exclude='bypass-env-var-allowlist.txt' \
            --exclude='env-vars-internal.txt' \
            --exclude='*.md' \
            | grep -vE '_CMD$' | sort -u)"
  # Speed: build a one-pass, comment-stripped haystack of every line mentioning a
  # candidate token, then read-site-test each candidate against that small file.
  _hayfile="$(mktemp)"
  grep -rhE 'CHUMP_[A-Z0-9_]*(BYPASS|SKIP|IGNORE|_CHECK|NO_)' \
    "$@" 2>/dev/null \
    --exclude='test-no-new-bypass-env-vars.sh' \
    --exclude='bypass-var-ceiling.txt' \
    --exclude='bypass-env-var-allowlist.txt' \
    --exclude='env-vars-internal.txt' \
    --exclude='*.md' \
    | _strip_comments > "$_hayfile" || true
  while IFS= read -r _v; do
    [ -z "$_v" ] && continue
    if _bypass_var_has_readsite "$_v" "$_hayfile"; then
      _n=$((_n + 1))
    fi
  done <<< "$_cands"
  rm -f "$_hayfile"
  printf '%s\n' "$_n"
}

if [[ "${1:-}" != "--self-test" ]]; then
  _ceiling_file="$REPO_ROOT/scripts/ci/bypass-var-ceiling.txt"
  _ceiling="$(grep -oE '^[0-9]+' "$_ceiling_file" 2>/dev/null | head -1 || true)"
  _ceiling="${_ceiling:-99999}"
  # Counter correctness lineage:
  #   RESILIENT-297: exclude this linter's own file + the ceiling file (their prose
  #     names vars), and drop command-VALUED …_CMD false positives.
  #   RESILIENT-298: count only vars with a FUNCTIONAL READ-SITE, not bare string
  #     mentions (registry lines, absence-assertion guards, concat fragments).
  #   INFRA-6073: strip COMMENTS before the read-site test (via _count_bypass_debt),
  #     and also exclude the allowlist file, env-vars-internal.txt, and docs/*.md.
  #     RESILIENT-298 still tested read-sites against comment lines, so a read-shaped
  #     string in a comment (`// env::var("CHUMP_X_BYPASS")`, `# CHUMP_X_SKIP=1`) still
  #     counted — the self-defeating bug where merely DOCUMENTING a var raised the count
  #     it documents, blocking debt-reducing fixes (PR #4637). The gate's INTENT is
  #     unchanged and NOT weakened: it still caps real read-backed bypass debt, and the
  #     per-PR diff-scanner below still blocks any NEW unallowlisted var at add-time. This
  #     only stops counting phantoms, so the honest count legitimately falls (218 -> 216).
  _now="$(_count_bypass_debt "$REPO_ROOT/scripts" "$REPO_ROOT/src" "$REPO_ROOT/crates")"
  if [ "${_now:-0}" -gt "$_ceiling" ]; then
    {
      echo "[bypass-lint] FAIL (EFFECTIVE-094 debt-ceiling): bypass/skip/check var count ${_now} > ceiling ${_ceiling}."
      echo "  To ADD a bypass var you must DELETE one — the count must ratchet DOWN, not up."
      echo "  The only way to RAISE the ceiling is an operator editing scripts/ci/bypass-var-ceiling.txt with a reason."
      echo "  This is the thing that reverses the 113 → 233 climb. See EFFECTIVE-089."
    } >&2
    exit 1
  fi
  if [ "${_now:-0}" -lt "$_ceiling" ]; then
    echo "[bypass-lint] debt-ceiling OK: ${_now} < ceiling ${_ceiling} — culled $((_ceiling - _now)). Ratchet it down: echo ${_now} > scripts/ci/bypass-var-ceiling.txt" >&2
  fi
fi

if [[ "${1:-}" == "--self-test" ]]; then
  PASS=0
  FAIL=0

  run_case() {
    local label="$1"
    local diff_input="$2"
    local expect_exit="$3"
    local tmpdir
    tmpdir="$(mktemp -d)"
    local fake_list="$tmpdir/allowlist.txt"
    # Use a minimal allowlist for self-tests. CHUMP_PREFLIGHT_SKIP is deleted
    # (INFRA-2422) so we use CHUMP_AUDIT_BYPASS as the allowlist-hit test case.
    printf '%s\n' \
      '# self-test allowlist' \
      'CHUMP_AUDIT_BYPASS  # grandfathered; deletion gap TBD' \
      > "$fake_list"
    local out
    local actual_exit=0
    out=$(BYPASS_ALLOWLIST_OVERRIDE="$fake_list" \
          BYPASS_DIFF_OVERRIDE="$diff_input" \
          bash "$REPO_ROOT/scripts/ci/test-no-new-bypass-env-vars.sh" 2>&1) \
      || actual_exit=$?
    if [[ "$actual_exit" -eq "$expect_exit" ]]; then
      echo "  PASS: $label (exit=$actual_exit)"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $label — expected exit $expect_exit, got $actual_exit"
      echo "        output: $out"
      FAIL=$((FAIL + 1))
    fi
    rm -rf "$tmpdir"
  }

  echo "[bypass-lint self-test] running 4 synthetic cases..."

  # Case 1: New bypass var NOT in allowlist → exit 1
  run_case "new CHUMP_NEW_BYPASS not in allowlist" \
    '+CHUMP_NEW_BYPASS=foo' \
    1

  # Case 2: New bypass var IN allowlist → exit 0
  # (CHUMP_PREFLIGHT_SKIP deleted per INFRA-2422; using CHUMP_AUDIT_BYPASS as allowlist-hit test)
  run_case "new CHUMP_AUDIT_BYPASS in allowlist" \
    '+CHUMP_AUDIT_BYPASS=1' \
    0

  # Case 3: *_DISABLED var (Category B kill-switch) → exit 0 (exempt)
  run_case "CHUMP_FLEET_DOCTOR_DISABLED is Category B, exempt" \
    '+CHUMP_FLEET_DOCTOR_DISABLED=1' \
    0

  # Case 4: Diff with no bypass vars → exit 0
  run_case "clean diff with no bypass vars" \
    '+CHUMP_LOG_LEVEL=debug' \
    0

  # ── INFRA-2438: comment-context cases ────────────────────────────────────
  # These cases exercise the comment-only-line filter added by INFRA-2438
  # (this script was over-matching: any + line mentioning the var name was
  # flagged, including PRs whose entire purpose was DOCUMENTING the deletion).
  # The lint must distinguish actual env::var() / shell-dereference / bare-
  # env-vars-internal-line introductions from comments mentioning the var.

  # Case 5: + line in a shell comment → NOT flagged (exit 0)
  run_case "shell comment mentioning bypass var name → exit 0" \
    '+# CHUMP_OBS_BUDGET_BYPASS is deleted (INFRA-2425) — guard is warn-only.' \
    0

  # Case 6: + line in a Rust comment → NOT flagged (exit 0)
  run_case "Rust // comment mentioning bypass var name → exit 0" \
    '+// CHUMP_CLAIM_IGNORE_MAIN_HEALTH is removed (INFRA-2428).' \
    0

  # Case 7: + line as block-comment body → NOT flagged (exit 0)
  run_case "block-comment body line mentioning bypass var → exit 0" \
    '+ * CHUMP_PREFLIGHT_SKIP_PIPEFAIL removed per INFRA-2427.' \
    0

  # Case 8: + line as actual shell dereference → IS flagged (exit 1, unless allowlisted)
  run_case "actual shell dereference of bypass var → exit 1" \
    '+    if [[ -n "${CHUMP_BRAND_NEW_BYPASS:-}" ]]; then' \
    1

  # ── RESILIENT-298: read-site counter cases. Prove the debt-ceiling counter counts
  # a var ONLY when it has a functional read-site, so phantom mentions never inflate it.
  _rs_root="$(mktemp -d)"
  # A real read: shell dereference.
  printf '%s\n' 'if [ "${CHUMP_RS_REAL_SKIP:-0}" = "1" ]; then :; fi' > "$_rs_root/real.sh"
  # A phantom: bare name in a registry-style doc + an absence-assertion grep — no read.
  printf '%s\n' 'CHUMP_RS_PHANTOM_SKIP' > "$_rs_root/registry.txt"
  printf '%s\n' 'grep -q "CHUMP_RS_PHANTOM_SKIP" "$f" && fail "must be absent"' > "$_rs_root/guard.sh"
  if _bypass_var_has_readsite "CHUMP_RS_REAL_SKIP" "$_rs_root"; then
    echo "  PASS: read-backed var is counted (has read-site)"; PASS=$((PASS + 1))
  else
    echo "  FAIL: read-backed var CHUMP_RS_REAL_SKIP was not detected"; FAIL=$((FAIL + 1))
  fi
  if _bypass_var_has_readsite "CHUMP_RS_PHANTOM_SKIP" "$_rs_root"; then
    echo "  FAIL: phantom var CHUMP_RS_PHANTOM_SKIP counted despite no read-site"; FAIL=$((FAIL + 1))
  else
    echo "  PASS: phantom (mention-only) var is NOT counted"; PASS=$((PASS + 1))
  fi
  # The env_trim_eq helper form (this repo's Rust accessor) must count as a read.
  printf '%s\n' 'crate::env_flags::env_trim_eq("CHUMP_RS_HELPER_SKIP", "1")' > "$_rs_root/helper.rs"
  if _bypass_var_has_readsite "CHUMP_RS_HELPER_SKIP" "$_rs_root"; then
    echo "  PASS: env_trim_eq read-site is counted"; PASS=$((PASS + 1))
  else
    echo "  FAIL: env_trim_eq read-site not detected (would undercount live vars)"; FAIL=$((FAIL + 1))
  fi
  rm -rf "$_rs_root"

  # ── INFRA-6073: the count must exclude COMMENT-mention phantoms. This is the exact
  # bug INFRA-6073 tracks — a var named only in a comment (with a read-SHAPED string)
  # inflated the ceiling and blocked the fix that named it (PR #4637). Exercise the real
  # counting path (_count_bypass_debt, which strips comments) against a synthetic tree:
  # one var with a genuine read, plus two vars that appear ONLY inside comments.
  _cm_root="$(mktemp -d)"
  # A real read (shell dereference of the var) — MUST count.
  printf '%s\n' 'if [ "${CHUMP_CM_REAL_SKIP:-0}" = "1" ]; then :; fi' > "$_cm_root/real.sh"
  # Comment mentions containing read-SHAPED strings — must NOT count. Without the
  # comment-strip these matched the read-site regex (env::var(...) and VAR=...).
  {
    printf '%s\n' '// documented: env::var("CHUMP_CM_RUST_COMMENT_SKIP") is read elsewhere, not here'
    printf '%s\n' 'let ok = true; // trailing note: CHUMP_CM_TRAILING_BYPASS=1 would skip (prose)'
  } > "$_cm_root/mod.rs"
  printf '%s\n' '# usage note: CHUMP_CM_SHELL_COMMENT_SKIP=1 disables it (a comment, not a read)' > "$_cm_root/notes.sh"
  _cm_count="$(_count_bypass_debt "$_cm_root")"
  if [[ "$_cm_count" == "1" ]]; then
    echo "  PASS: only the real read counts; comment-mention phantoms excluded (count=1)"; PASS=$((PASS + 1))
  else
    echo "  FAIL: expected count 1 (real read only), got '$_cm_count' — comment phantom leaked"; FAIL=$((FAIL + 1))
  fi
  rm -rf "$_cm_root"

  echo ""
  if [[ $FAIL -gt 0 ]]; then
    echo "[bypass-lint self-test] FAIL: $FAIL/$((PASS+FAIL)) cases failed"
    exit 1
  else
    echo "[bypass-lint self-test] PASS: all $PASS cases passed"
    exit 0
  fi
fi

# ── Load allowlist ─────────────────────────────────────────────────────────────
# Support override for self-test injection.
ALLOWLIST="${BYPASS_ALLOWLIST_OVERRIDE:-$ALLOWLIST}"

load_allowlist() {
  if [[ ! -f "$ALLOWLIST" ]]; then
    echo "[bypass-lint] WARN: allowlist not found at $ALLOWLIST — treating as empty" >&2
    return
  fi
  # Strip comment-only lines and blank lines; take first whitespace-delimited token.
  grep -v '^\s*#' "$ALLOWLIST" | grep -v '^\s*$' | awk '{print $1}'
}

ALLOWED_VARS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && ALLOWED_VARS+=("$line")
done < <(load_allowlist)

is_allowed() {
  local varname="$1"
  local v
  for v in "${ALLOWED_VARS[@]:-}"; do
    if [[ "$v" == "$varname" ]]; then
      return 0
    fi
  done
  return 1
}

# ── Compute diff ───────────────────────────────────────────────────────────────
# BYPASS_DIFF_OVERRIDE allows self-test to inject a synthetic diff string.
get_diff_lines() {
  if [[ -n "${BYPASS_DIFF_OVERRIDE:-}" ]]; then
    printf '%s\n' "$BYPASS_DIFF_OVERRIDE"
    return
  fi
  local base="${BASE_REF:-origin/main}"
  # In CI pull_request context git diff origin/main...HEAD gives the PR diff.
  # Locally (or merge_group) fall back to origin/main..HEAD.
  local diff_output
  diff_output="$(git diff "${base}...HEAD" 2>/dev/null)" \
    || diff_output="$(git diff "${base}..HEAD" 2>/dev/null)" \
    || diff_output=""
  printf '%s\n' "$diff_output"
}

# ── Pattern matching ───────────────────────────────────────────────────────────
# We want to find ADDED lines (starting with +, not ++) that contain
# bypass-class env var names. The DISABLED category is intentionally exempt.
#
# Patterns we scan for (as var name extractions):
#   Rust:  std::env::var("CHUMP_XYZ_BYPASS")
#          std::env::var("CHUMP_XYZ_SKIP")
#          std::env::var("CHUMP_IGNORE_XYZ")
#          env!("CHUMP_XYZ_BYPASS")
#   Shell: ${CHUMP_XYZ_BYPASS}, $CHUMP_XYZ_BYPASS
#          ${CHUMP_XYZ_SKIP},   $CHUMP_XYZ_SKIP
#          ${CHUMP_IGNORE_XYZ}, $CHUMP_IGNORE_XYZ
#   env-vars-internal.txt bare names: CHUMP_XYZ_BYPASS, CHUMP_XYZ_SKIP,
#                                     CHUMP_IGNORE_XYZ
#
# _DISABLED is excluded from all patterns.

extract_bypass_varnames() {
  local diff_text="$1"
  local tmpfile
  tmpfile="$(mktemp)"
  printf '%s\n' "$diff_text" > "$tmpfile"

  # Strip diff hunks that belong to this lint script or the allowlist file —
  # these legitimately contain bypass var names for documentation/self-test
  # purposes and should not be flagged. The diff format uses
  # "diff --git a/path b/path" headers; we blank out lines between matching
  # headers and the next "diff --git" header.
  # Strategy: pipe through awk to suppress lines from exempt files.
  local filtered_file
  filtered_file="$(mktemp)"
  awk '
    /^diff --git / {
      # Exempt files that legitimately contain bypass var names:
      #   - this lint script itself (self-test case strings)
      #   - the allowlist file (grandfathered var documentation)
      #   - env-vars-internal.txt (var documentation registry, not code)
      #   - the ceiling file (INFRA-6073): its changelog names every var it
      #     signs off on — bookkeeping prose, not a real introduction
      suppress = ($0 ~ /scripts\/ci\/test-no-new-bypass-env-vars\.sh/ ||
                  $0 ~ /scripts\/ci\/bypass-env-var-allowlist\.txt/ ||
                  $0 ~ /scripts\/ci\/bypass-var-ceiling\.txt/ ||
                  $0 ~ /scripts\/ci\/env-vars-internal\.txt/)
    }
    !suppress { print }
  ' "$tmpfile" > "$filtered_file"
  rm -f "$tmpfile"

  # Only look at added lines (+ prefix, not ++ which is the diff header).
  # Use grep -E; avoid pipe-to-grep-q (INFRA-1658).
  local added_lines
  added_lines="$(grep -E '^\+[^+]' "$filtered_file" 2>/dev/null)" || added_lines=""
  rm -f "$filtered_file"

  local added_file
  added_file="$(mktemp)"
  printf '%s\n' "$added_lines" > "$added_file"

  # INFRA-2438: filter out comment-only lines before pattern-matching. A `+`
  # diff line whose body (after stripping leading whitespace) begins with `#`
  # (shell/yaml/toml), `//` (Rust/JS), `*` (block-comment body), or `>` (md
  # quote) is documentation/explanation of a deletion — NOT an introduction.
  # Without this filter, deletion-PRs that document what they removed (e.g.
  # "# CHUMP_X_BYPASS is deleted") self-flag and the lint blocks the very
  # change it's meant to encourage.
  local code_only_file
  code_only_file="$(mktemp)"
  awk '
    {
      # Strip the leading "+" prefix.
      line = substr($0, 2)
      # Trim leading whitespace.
      stripped = line
      sub(/^[ \t]+/, "", stripped)
      # Skip comment-only lines.
      if (stripped ~ /^#/)  next
      if (stripped ~ /^\/\//) next
      if (stripped ~ /^\*/) next
      if (stripped ~ /^>/) next
      # Keep the original "+"-prefixed line.
      print $0
    }
  ' "$added_file" > "$code_only_file"
  rm -f "$added_file"

  # Extract var names matching the bypass patterns.
  # Strategy: grep for the CHUMP_*_BYPASS|SKIP|IGNORE_* substrings using -o.
  # CHUMP_IGNORE_ requires at least one trailing [A-Z0-9] to avoid matching
  # bare pattern-description text like "CHUMP_IGNORE_*" in comments.
  # Then filter out _DISABLED (Category B exempt).
  local raw_hits
  raw_hits="$(grep -oE 'CHUMP_[A-Z0-9_]*(BYPASS|SKIP)[A-Z0-9_]*|CHUMP_IGNORE_[A-Z0-9][A-Z0-9_]*' \
    "$code_only_file" 2>/dev/null || true)"
  rm -f "$code_only_file"

  if [[ -z "$raw_hits" ]]; then
    return
  fi

  # Filter out _DISABLED vars (Category B exempt).
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    # Skip if the var name itself ends in _DISABLED — this shouldn't happen
    # since _DISABLED doesn't match our grep patterns above, but belt+suspenders.
    case "$name" in
      *_DISABLED) continue ;;
    esac
    printf '%s\n' "$name"
  done <<< "$raw_hits" | sort -u
}

# ── Main scan ──────────────────────────────────────────────────────────────────
DIFF_TEXT="$(get_diff_lines)"

if [[ -z "$DIFF_TEXT" ]]; then
  echo "[bypass-lint] INFO: empty diff — nothing to scan"
  exit 0
fi

FOUND_VARS=()
while IFS= read -r varname; do
  [[ -n "$varname" ]] && FOUND_VARS+=("$varname")
done < <(extract_bypass_varnames "$DIFF_TEXT")

if [[ ${#FOUND_VARS[@]} -eq 0 ]]; then
  echo "[bypass-lint] PASS: no new bypass-class env vars in diff (${#ALLOWED_VARS[@]} allowlisted)"
  exit 0
fi

# ── Allowlist check ────────────────────────────────────────────────────────────
VIOLATIONS=()
for varname in "${FOUND_VARS[@]}"; do
  if ! is_allowed "$varname"; then
    VIOLATIONS+=("$varname")
  fi
done

if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
  echo "[bypass-lint] PASS: all new bypass-class vars are allowlisted (${#FOUND_VARS[@]} found, all OK)"
  exit 0
fi

# ── Report violations ──────────────────────────────────────────────────────────
{
  echo "[bypass-lint] FAIL: ${#VIOLATIONS[@]} new bypass-class env var(s) not in allowlist"
  echo ""
  echo "  Violations:"
  for v in "${VIOLATIONS[@]}"; do
    echo "    $v"
  done
  echo ""
  echo "  Bypass-class patterns covered by this lint:"
  echo "    CHUMP_*_BYPASS, CHUMP_*_SKIP, CHUMP_IGNORE_*"
  echo "  (CHUMP_*_DISABLED vars are exempt — those are Category B kill-switches)"
  echo ""
  echo "  Remediation (pick one):"
  echo "    1. Add the var name to scripts/ci/bypass-env-var-allowlist.txt with a"
  echo "       Bypass-Justification: comment referencing a deletion gap ID."
  echo "       Operator review is required for all new allowlist entries."
  echo "    2. Remove the env var and fix the underlying gate — the preferred path."
  echo "       See INFRA-2422 through INFRA-2428 for the deletion pattern."
  echo ""
  echo "  See docs/process/BYPASS_TRAILER_SCHEMA.md (INFRA-2407) for bypass policy."
  echo "  See INFRA-2429 for the zero-bypass thesis that drives this lint."
} >&2

exit 1
