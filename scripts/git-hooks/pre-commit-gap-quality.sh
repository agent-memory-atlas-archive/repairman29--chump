#!/usr/bin/env bash
# RESILIENT-037: Pre-commit gap quality gate.
# Rejects staged docs/gaps/*.yaml files where acceptance_criteria contains
# placeholder TODO/TBD tokens or description is < 200 characters.
#
# Bypass: add commit trailer `Vague-AC-Bypass: <one-sentence reason>`
# (emits kind=vague_ac_bypass_used to ambient.jsonl).
# Rust-First-Bypass: <120 LOC pre-commit hook inspecting staged git index blobs.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT_FILE="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

STAGED_GAPS=()
while IFS= read -r f; do
    [[ -n "$f" ]] && STAGED_GAPS+=("$f")
done < <(git diff --cached --name-only --diff-filter=AM -- 'docs/gaps/*.yaml' 2>/dev/null || true)

if [[ ${#STAGED_GAPS[@]} -eq 0 ]]; then
    exit 0
fi

# Check commit message / trailer bypass if COMMIT_EDITMSG or CHUMP_COMMIT_MSG_FILE is available
COMMIT_MSG_FILE="${CHUMP_COMMIT_MSG_FILE:-$REPO_ROOT/.git/COMMIT_EDITMSG}"
BYPASS_REASON=""
if [[ -f "$COMMIT_MSG_FILE" ]]; then
    BYPASS_REASON="$(sed -nE 's/^Vague-AC-Bypass:[[:space:]]*(.+)$/\1/p' "$COMMIT_MSG_FILE" | head -n1 || true)"
fi

# scanner-anchor: "kind":"vague_ac_bypass_used"
python3 - "$REPO_ROOT" "$AMBIENT_FILE" "$BYPASS_REASON" "${STAGED_GAPS[@]}" <<'PY'
import datetime
import json
import pathlib
import re
import subprocess
import sys

repo_root = pathlib.Path(sys.argv[1])
ambient_path = pathlib.Path(sys.argv[2])
bypass_reason = sys.argv[3].strip()
files = sys.argv[4:]

violations = []

for rel in files:
    try:
        raw = subprocess.check_output(
            ["git", "-C", str(repo_root), "show", f":{rel}"],
            stderr=subprocess.DEVNULL,
        ).decode("utf-8", errors="replace")
    except Exception:
        p = repo_root / rel
        if not p.is_file():
            continue
        raw = p.read_text(errors="replace")

    # Extract description and acceptance_criteria text
    desc_text = ""
    ac_text = ""
    section = None
    for line in raw.splitlines():
        if re.match(r"^description:\s*", line):
            section = "description"
            val = re.sub(r"^description:\s*[>|+-]*\s*", "", line).strip()
            if val:
                desc_text += val + " "
            continue
        elif re.match(r"^acceptance_criteria:\s*", line):
            section = "ac"
            val = re.sub(r"^acceptance_criteria:\s*", "", line).strip()
            if val:
                ac_text += val + " "
            continue
        elif re.match(r"^[A-Za-z0-9_]+:\s*", line):
            section = None
            continue

        if section == "description":
            desc_text += line.strip() + " "
        elif section == "ac":
            ac_text += line.strip() + " "

    desc_clean = desc_text.strip()
    ac_clean = ac_text.strip()

    if re.search(r"\b(TODO|TBD)\b", ac_clean):
        violations.append(f"{rel}: acceptance_criteria contains placeholder TODO/TBD")
    if len(desc_clean) < 200:
        violations.append(
            f"{rel}: description is {len(desc_clean)} chars (< 200 char minimum; RESILIENT-037)"
        )

if not violations:
    sys.exit(0)

if bypass_reason:
    ambient_path.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ev = {
        "ts": ts,
        "kind": "vague_ac_bypass_used",
        "files": files,
        "reason": bypass_reason,
    }
    with ambient_path.open("a", encoding="utf-8") as af:
        af.write(json.dumps(ev) + "\n")
    print(f"[pre-commit-gap-quality] WARN: bypassed via Vague-AC-Bypass ({bypass_reason})", file=sys.stderr)
    sys.exit(0)

print("[pre-commit-gap-quality] ERROR: staged gap YAML failed RESILIENT-037 quality gate:", file=sys.stderr)
for v in violations:
    print(f"  - {v}", file=sys.stderr)
print("Add substantive description (>=200 chars) and concrete acceptance_criteria (no TODO/TBD),", file=sys.stderr)
print("or include commit trailer: Vague-AC-Bypass: <one-sentence reason>", file=sys.stderr)
sys.exit(1)
PY
