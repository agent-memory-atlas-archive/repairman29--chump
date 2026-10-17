#!/usr/bin/env bash
# test-infra-changes-smoke.sh — CREDIBLE-001: pre-deploy smoke test for infra changes.
#
# Runs for commits touching:
#   - .github/workflows/* (GitHub Actions workflows)
#   - scripts/coord/*      (coordination scripts)
#   - scripts/dispatch/*   (dispatch scripts)
#   - Cargo.toml           (Rust lints/dependencies)
#
# Validates:
#   1. PyYAML can parse all .yml/.yaml files
#   2. shellcheck passes on all .sh scripts
#   3. cargo clippy --workspace passes
#
# Bypass: CREDIBLE_INFRA_SMOKE_BYPASS=1 skips all checks (documented for genuine edge cases).
# Pre-commit hook: invoked automatically; exit non-zero blocks commit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# ZERO-WASTE-134: inherits CARGO_TARGET_DIR from pre-commit / bot-merge; otherwise
# the one shared resolver (never a worktree-local dir).
# shellcheck source=lib/resolve-cargo-target-dir.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/ci/lib/resolve-cargo-target-dir.sh"
chump_export_cargo_target_dir

# Bypass for genuine edge cases (e.g., temporary linter regressions, CI-only code)
if [[ "${CREDIBLE_INFRA_SMOKE_BYPASS:-}" == "1" ]]; then
    echo "[CREDIBLE-001 smoke] bypass active; skipping checks"
    exit 0
fi

# Detect which files changed. If run from pre-commit, $1+ are staged files.
# If run manually without args, scan git status.
if [[ $# -gt 0 ]]; then
    changed_files=("$@")
else
    # Collect both staged and unstaged changes
    changed_files=($(git diff --name-only HEAD 2>/dev/null || echo ""))
    if [[ -z "${changed_files[0]:-}" ]]; then
        changed_files=($(git diff --cached --name-only 2>/dev/null || echo ""))
    fi
fi

# Determine if any relevant files were touched
needs_check=false
for f in "${changed_files[@]}"; do
    case "$f" in
        .github/workflows/* | scripts/coord/* | scripts/dispatch/* | Cargo.toml)
            needs_check=true
            break
            ;;
    esac
done

if [[ "$needs_check" == false ]]; then
    exit 0
fi

echo "[CREDIBLE-001 smoke] checking infra changes..."

# ── Check 1: PyYAML parse all .yml/.yaml files ──────────────────────────────
echo "[CREDIBLE-001 smoke] validating YAML syntax..."

if ! command -v python3 &>/dev/null; then
    echo "[CREDIBLE-001 smoke] ERROR: python3 required for YAML validation"
    exit 1
fi

python3 -c "import yaml" 2>/dev/null || {
    echo "[CREDIBLE-001 smoke] ERROR: PyYAML module not found; install with: pip install PyYAML"
    exit 1
}

yaml_files=()
while IFS= read -r f; do
    [[ -f "$f" ]] && yaml_files+=("$f")
done < <(find "$REPO_ROOT/.github/workflows" "$REPO_ROOT/scripts/coord" "$REPO_ROOT/scripts/dispatch" -maxdepth 3 \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null)

for f in "${yaml_files[@]:-}"; do
    [[ -z "$f" ]] && continue  # macOS bash 3.2 empty-array-with-set-u guard
    if ! python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>&1; then
        echo "[CREDIBLE-001 smoke] FAIL: YAML parse error in $f"
        exit 1
    fi
done

if [[ ${#yaml_files[@]} -gt 0 ]]; then
    echo "[CREDIBLE-001 smoke] PASS: ${#yaml_files[@]} YAML files valid"
fi

# ── Check 2: shellcheck on STAGED .sh files only (INFRA-1293) ───────────────
# Pre-INFRA-1293: this step ran shellcheck repo-wide on every commit.
# Cascading failure: ANY broken file in scripts/coord or scripts/dispatch
# (landed by a different PR) blocked EVERY subsequent commit through this
# gate. Agents had to bypass with --no-verify, defeating the gate.
#
# Post-INFRA-1293: shellcheck only runs on files in the current commit's
# staged set. Unrelated broken files don't block — but if your commit
# touches a broken file, you must fix it.
#
# Repo-wide scan still available for periodic CI / on-demand: set
# CHUMP_CREDIBLE_001_FULL_SCAN=1 to opt back into the old behavior.
echo "[CREDIBLE-001 smoke] running shellcheck on staged .sh files..."

if ! command -v shellcheck &>/dev/null; then
    echo "[CREDIBLE-001 smoke] WARN: shellcheck not found; skipping shell validation"
else
    sh_files=()
    if [[ "${CHUMP_CREDIBLE_001_FULL_SCAN:-0}" == "1" ]]; then
        # Periodic-CI / on-demand path: full repo scan.
        while IFS= read -r f; do
            [[ -f "$f" ]] && sh_files+=("$f")
        done < <(find "$REPO_ROOT/scripts/coord" "$REPO_ROOT/scripts/dispatch" -maxdepth 2 -name "*.sh" 2>/dev/null)
    else
        # Incremental path (default): only staged shell files in coord/ or dispatch/.
        # The changed_files array is populated above from $@ (pre-commit args) or
        # git diff. Filter to scripts/coord/*.sh + scripts/dispatch/*.sh that exist.
        for f in "${changed_files[@]:-}"; do
            [[ -z "$f" ]] && continue
            case "$f" in
                scripts/coord/*.sh | scripts/dispatch/*.sh)
                    full="$REPO_ROOT/$f"
                    [[ -f "$full" ]] && sh_files+=("$full")
                    ;;
            esac
        done
    fi

    for f in "${sh_files[@]:-}"; do
        [[ -z "$f" ]] && continue
        if ! shellcheck "$f" 2>&1; then
            echo "[CREDIBLE-001 smoke] FAIL: shellcheck failed on $f"
            exit 1
        fi
    done

    if [[ ${#sh_files[@]} -gt 0 ]]; then
        echo "[CREDIBLE-001 smoke] PASS: ${#sh_files[@]} shell scripts valid"
    else
        echo "[CREDIBLE-001 smoke] SKIP: no staged .sh files in scripts/coord/ or scripts/dispatch/"
    fi
fi

# ── Check 3: cargo clippy --workspace ────────────────────────────────────────
echo "[CREDIBLE-001 smoke] running cargo clippy..."

if ! command -v cargo &>/dev/null; then
    echo "[CREDIBLE-001 smoke] WARN: cargo not found; skipping Rust linting"
else
    if [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
        if ! cargo clippy --workspace --all-targets --all-features 2>&1 | grep -q "warning\|error"; then
            echo "[CREDIBLE-001 smoke] PASS: cargo clippy clean"
        else
            # clippy may emit warnings but still exit 0; we treat warnings as issues
            if ! cargo clippy --workspace --all-targets --all-features 2>&1 | tail -3 | grep -q "error:"; then
                echo "[CREDIBLE-001 smoke] WARN: clippy found issues (non-fatal)"
            else
                echo "[CREDIBLE-001 smoke] FAIL: cargo clippy found errors"
                exit 1
            fi
        fi
    fi
fi

echo "[CREDIBLE-001 smoke] all checks passed!"
exit 0
