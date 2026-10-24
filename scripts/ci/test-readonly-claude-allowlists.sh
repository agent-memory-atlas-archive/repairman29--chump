#!/usr/bin/env bash
# test-readonly-claude-allowlists.sh — CREDIBLE-1567 (PHASE-R R6):
# Shared allowlist/denylist lint + runtime stubbed-claude argv verification
# for every read-only/bounded `claude -p` allowlist site:
#   - scripts/dispatch/discord-command-agent.sh
#   - scripts/dispatch/discord-advisor-agent.sh
#   - scripts/coord/duty-officer-loop.sh
#   - scripts/dispatch/architect-tick.sh
#   - scripts/dispatch/review-ro-claude.sh
#   - src/dispatch.rs
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

PASS=0
FAIL=0
ok()   { printf "  ok   %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "  FAIL %s\n" "$1" >&2; FAIL=$((FAIL + 1)); }

# Shared python3 lint engine: scans a shell script that defines an allowlist
# (*ALLOWED_TOOLS=(...) or local allowed=(...)) and fails if:
#   (a) any allowed entry matches a known escape-capable binary/subcommand:
#       sqlite3, git fetch/log/diff/-c/push/commit or bare git, find, awk,
#       gawk, xargs, sed, tee, env, sudo, bash, sh, zsh, python, perl, ruby,
#       node, eval, exec, gh pr merge, gh api, or bare Bash / Bash(*)
#   (b) the script allows any Bash(...) entry without an explicit denylist
#       (*DENIED_TOOLS / *DISALLOWED_TOOLS / local denied) containing all
#       required denies:
#       Bash(gh pr merge*), Bash(gh api*), Bash(git push*),
#       Bash(bash*), Bash(sh*), Bash(env*), Bash(python*), Bash(perl*),
#       Bash(sqlite3*), Bash(git fetch*), Bash(git log*)
#       AND wiring --disallowedTools to that array variable.
lint_shell_allowlist_file() {
    local target="$1"
    python3 - "$target" <<'PYEOF'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

allow_blocks = re.findall(
    r"(?:(?<!DIS)ALLOWED_TOOLS|local\s+allowed)\s*=\s*\((.*?)\n\s*\)",
    text,
    flags=re.S,
)
if not allow_blocks:
    print(f"{path}: no allowlist array found", file=sys.stderr)
    sys.exit(2)

entries = []
for blk in allow_blocks:
    for line in blk.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        for m in re.finditer(r"'([^']+)'|\"([^\"]+)\"|(\S+)", line):
            tok = m.group(1) or m.group(2) or m.group(3)
            entries.append(tok)

FORBIDDEN_ALLOW_RES = [
    (r"^Bash\((\*\s*)?sqlite3([*\s)]|$)", "sqlite3 in allowlist permits .shell/.system/-cmd"),
    (r"^Bash\(git\s+(fetch|log|diff|-c|push|commit)([*\s)]|$)", "git fetch/log/diff/-c/push/commit in allowlist"),
    (r"^Bash\(git\*?\)$", "unscoped git in allowlist"),
    (r"^Bash\((find|awk|gawk|xargs|sed|tee|env|sudo|bash|sh|zsh|python[0-9.]*|perl|ruby|node|eval|exec)([*\s)]|$)", "interpreter/escape binary in allowlist"),
    (r"^Bash\(gh\s+(pr\s+merge|api)([*\s)]|$)", "gh pr merge / gh api in allowlist"),
    (r"^Bash(\(\*?\))?$", "bare Bash in allowlist"),
]

errors = []
has_bash_allow = False
for e in entries:
    if e.startswith("Bash"):
        has_bash_allow = True
    for pat, reason in FORBIDDEN_ALLOW_RES:
        if re.search(pat, e):
            errors.append(f"{path}: forbidden allowlist entry {e!r} ({reason})")

if has_bash_allow:
    deny_blocks = re.findall(
        r"(?:[A-Z_]*(?:DENIED|DISALLOWED)_TOOLS|local\s+denied)\s*=\s*\((.*?)\n\s*\)",
        text,
        flags=re.S,
    )
    deny_entries = set()
    for blk in deny_blocks:
        for line in blk.splitlines():
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            for m in re.finditer(r"'([^']+)'|\"([^\"]+)\"|(\S+)", line):
                tok = m.group(1) or m.group(2) or m.group(3)
                deny_entries.add(tok)

    REQUIRED_DENIES = [
        "Bash(gh pr merge*)",
        "Bash(gh api*)",
        "Bash(git push*)",
        "Bash(bash*)",
        "Bash(sh*)",
        "Bash(env*)",
        "Bash(python*)",
        "Bash(perl*)",
        "Bash(sqlite3*)",
        "Bash(git fetch*)",
        "Bash(git log*)",
    ]
    for req in REQUIRED_DENIES:
        if req not in deny_entries:
            errors.append(f"{path}: missing required deny {req!r}")

    if not re.search(r"--disallowedTools\s+\"\$\{(?:[A-Z_]*(?:DENIED|DISALLOWED)_TOOLS|denied)\[@\]\}\"", text):
        errors.append(f"{path}: --disallowedTools is not wired to the denied array")

if errors:
    for err in errors:
        print(err, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF
}

if [[ "${1:-}" == "--lint-file" ]]; then
    shift
    rc=0
    for f in "$@"; do
        lint_shell_allowlist_file "$f" || rc=1
    done
    exit "$rc"
fi

echo "=== 1. Live allowlist sites pass the shared CREDIBLE-1567 lint ==="
LIVE_SITES=(
    "scripts/dispatch/discord-command-agent.sh"
    "scripts/dispatch/discord-advisor-agent.sh"
    "scripts/coord/duty-officer-loop.sh"
    "scripts/dispatch/architect-tick.sh"
    "scripts/dispatch/review-ro-claude.sh"
)
for site in "${LIVE_SITES[@]}"; do
    if lint_shell_allowlist_file "$REPO_ROOT/$site"; then
        ok "live allowlist clean: $site"
    else
        fail "live allowlist failed lint: $site"
    fi
done

if grep -q 'cmd.args(\["--disallowedTools", HEADLESS_DISALLOWED_TOOLS\]);' "$REPO_ROOT/src/dispatch.rs" \
   && ! grep -qE 'Bash\((sqlite3|git (fetch|log|diff|-c))' "$REPO_ROOT/src/dispatch.rs"; then
    ok "live allowlist clean: src/dispatch.rs"
else
    fail "src/dispatch.rs missing HEADLESS_DISALLOWED_TOOLS or has forbidden allowlist entry"
fi

echo "=== 2. AC1: Lint fails on synthetic fixtures with escape-capable entries ==="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_fixture() {
    local out="$1" extra_allow="$2" omit_deny="${3:-}"
    python3 - "$REPO_ROOT/scripts/dispatch/discord-command-agent.sh" "$out" "$extra_allow" "$omit_deny" <<'PYEOF'
import sys
from pathlib import Path

src = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
extra_allow = sys.argv[3]
omit_deny = sys.argv[4]

if extra_allow:
    src = src.replace("ALLOWED_TOOLS=(\n", f"ALLOWED_TOOLS=(\n    \x27{extra_allow}\x27\n", 1)
if omit_deny:
    src = src.replace(f"\x27{omit_deny}\x27", "", 1)
out.write_text(src)
PYEOF
}

for bad_entry in 'Bash(sqlite3*)' 'Bash(git fetch*)' 'Bash(git log*)' 'Bash(git diff*)' 'Bash(git -c*)' 'Bash(find*)' 'Bash(awk*)' 'Bash(xargs*)' 'Bash(python*)' 'Bash(bash*)' 'Bash(env*)'; do
    fx="$TMP/fixture-allow.sh"
    make_fixture "$fx" "$bad_entry"
    if lint_shell_allowlist_file "$fx" 2>/dev/null; then
        fail "lint unexpectedly passed on forbidden allowlist entry: $bad_entry"
    else
        ok "lint fails on forbidden allowlist entry: $bad_entry"
    fi
done

for missing_deny in 'Bash(gh pr merge*)' 'Bash(gh api*)' 'Bash(git push*)' 'Bash(sqlite3*)' 'Bash(git fetch*)' 'Bash(git log*)' 'Bash(python*)' 'Bash(bash*)'; do
    fx="$TMP/fixture-deny.sh"
    make_fixture "$fx" "" "$missing_deny"
    if lint_shell_allowlist_file "$fx" 2>/dev/null; then
        fail "lint unexpectedly passed when required deny omitted: $missing_deny"
    else
        ok "lint fails when required deny omitted: $missing_deny"
    fi
done

echo "=== 3. AC2: Stubbed agent runs record runtime claude argv and reject escapes ==="
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/claude" <<'STUBEOF'
#!/usr/bin/env bash
if [[ -n "${STUB_CLAUDE_ARGV_OUT:-}" ]]; then
    printf "%s\0" "$@" > "$STUB_CLAUDE_ARGV_OUT"
fi
echo "stub-claude-ok"
exit 0
STUBEOF
chmod +x "$STUB_BIN/claude"

cat > "$STUB_BIN/git" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "fetch" ]]; then exit 0; fi
exec /usr/bin/git "$@"
STUBEOF
chmod +x "$STUB_BIN/git"

verify_runtime_argv() {
    local label="$1" argv_file="$2"
    python3 - "$label" "$argv_file" <<'PYEOF'
import fnmatch
import sys
from pathlib import Path

label = sys.argv[1]
raw = Path(sys.argv[2]).read_bytes()
args = [a.decode("utf-8", "replace") for a in raw.split(b"\0") if a]

def flag_vals(flag):
    vals = []
    on = False
    for a in args:
        if on:
            if a.startswith("--"):
                break
            vals.append(a)
        elif a == flag:
            on = True
    return vals

allowed = flag_vals("--allowedTools")
denied = flag_vals("--disallowedTools")
if not allowed:
    print(f"{label}: runtime argv has empty --allowedTools", file=sys.stderr)
    sys.exit(1)
if not denied:
    print(f"{label}: runtime argv has empty --disallowedTools", file=sys.stderr)
    sys.exit(1)

REQUIRED_DENIES = [
    "Bash(gh pr merge*)",
    "Bash(gh api*)",
    "Bash(git push*)",
    "Bash(bash*)",
    "Bash(sh*)",
    "Bash(env*)",
    "Bash(python*)",
    "Bash(perl*)",
    "Bash(sqlite3*)",
    "Bash(git fetch*)",
    "Bash(git log*)",
]
for req in REQUIRED_DENIES:
    if req not in denied:
        print(f"{label}: runtime --disallowedTools missing {req}", file=sys.stderr)
        sys.exit(1)

def bash_pats(entries):
    out = []
    for e in entries:
        if e.startswith("Bash(") and e.endswith(")"):
            out.append(e[5:-1])
    return out

allow_pats = bash_pats(allowed)
deny_pats = bash_pats(denied)

def is_permitted(cmd: str) -> bool:
    if any(fnmatch.fnmatchcase(cmd, p) for p in deny_pats):
        return False
    return any(fnmatch.fnmatchcase(cmd, p) for p in allow_pats)

ESCAPES = [
    "sqlite3 :memory: .shell id",
    "sqlite3 -cmd id .chump/state.db",
    "git fetch --upload-pack=id origin main",
    "git log --output=/tmp/pwn -n 1",
    "git diff --output=/tmp/pwn",
    "git -c core.pager=id log",
    "gh pr merge 1 --admin",
    "gh api repos/x/y -X PUT",
    "git push origin HEAD:main",
    "bash -c id",
    "sh -c id",
    "env bash -c id",
    "python3 -c import os",
    "perl -e system",
]
for esc in ESCAPES:
    if is_permitted(esc):
        print(f"{label}: runtime allowlist/denylist permitted escape: {esc}", file=sys.stderr)
        sys.exit(1)

if not is_permitted("scripts/dispatch/architect-ro.sh open-prs"):
    print(f"{label}: runtime allowlist did not permit vetted wrapper scripts/dispatch/architect-ro.sh", file=sys.stderr)
    sys.exit(1)

sys.exit(0)
PYEOF
}

CMD_ARGV="$TMP/cmd.argv"
PATH="$STUB_BIN:$PATH" STUB_CLAUDE_ARGV_OUT="$CMD_ARGV" \
    CHUMP_DISCORD_AGENT_TIMEOUT_S=10 \
    bash "$REPO_ROOT/scripts/dispatch/discord-command-agent.sh" "status check" >/dev/null 2>&1 || true
if [[ -s "$CMD_ARGV" ]] && verify_runtime_argv "discord-command-agent" "$CMD_ARGV"; then
    ok "discord-command-agent runtime claude argv rejects all escapes and carries required denies"
else
    fail "discord-command-agent runtime claude argv verification failed"
fi

ADV_ARGV="$TMP/adv.argv"
PATH="$STUB_BIN:$PATH" STUB_CLAUDE_ARGV_OUT="$ADV_ARGV" \
    CHUMP_DISCORD_ADVISOR_TIMEOUT_S=10 \
    bash "$REPO_ROOT/scripts/dispatch/discord-advisor-agent.sh" "what is open?" >/dev/null 2>&1 || true
if [[ -s "$ADV_ARGV" ]] && verify_runtime_argv "discord-advisor-agent" "$ADV_ARGV"; then
    ok "discord-advisor-agent runtime claude argv rejects all escapes and carries required denies"
else
    fail "discord-advisor-agent runtime claude argv verification failed"
fi

DO_ARGV="$TMP/do.argv"
STUB_CLAUDE_ARGV_OUT="$DO_ARGV" \
    CHUMP_AMBIENT_LOG="$TMP/do-ambient.jsonl" \
    CHUMP_MEMORY_DB="$TMP/do-memory.db" \
    CHUMP_PEER_EXECUTE=1 \
    CHUMP_PEER_CLAUDE_BIN="$STUB_BIN/claude" \
    bash "$REPO_ROOT/scripts/coord/duty-officer-loop.sh" judgment-tick >/dev/null 2>&1 || true
if [[ -s "$DO_ARGV" ]] && verify_runtime_argv "duty-officer-loop" "$DO_ARGV"; then
    ok "duty-officer-loop runtime claude argv rejects all escapes and carries required denies"
else
    fail "duty-officer-loop runtime claude argv verification failed"
fi

for bad_ro in "ship-log 1;id" "pr-checks 1;id" ".shell id" "fetch --upload-pack=id"; do
    # shellcheck disable=SC2086
    if bash "$REPO_ROOT/scripts/dispatch/architect-ro.sh" $bad_ro >/dev/null 2>&1; then
        fail "architect-ro.sh accepted unsafe invocation: $bad_ro"
    else
        ok "architect-ro.sh rejected unsafe invocation: $bad_ro"
    fi
done

echo
printf "[test-readonly-claude-allowlists] %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "[test-readonly-claude-allowlists] PASS"
