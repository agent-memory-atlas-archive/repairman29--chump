#!/usr/bin/env python3
"""false-done-sweep — find DONE gaps whose closing PR never touched their scope.

WHY THIS EXISTS, AND WHY audit-done DOES NOT COVER IT

`chump gap audit-done` (INFRA-3495) already sweeps closed gaps, but it asks a
different question — "did the PR's diff cover the acceptance bullets?" — and it
cannot see the failure this catches, for two reasons:

  1. BOILERPLATE AC DEFEATS IT. `chump gap reserve` auto-generates acceptance
     criteria of the form "The change described by <title> is implemented in the
     relevant code path(s)." Scoring a diff against that sentence is not a test
     of anything. In the live run on 2026-08-10, nearly every bullet audit-done
     flagged was one of the three auto-generated boilerplate lines.

  2. IT ONLY EVER LOOKS AT AN ALPHABETICAL PREFIX. `GapStore::list` is
     `ORDER BY id` and `audit()` does `.take(limit)` with limit=100 hardcoded at
     the call site. So it re-audits COG-* and CREDIBLE-0xx on every run and has
     never examined the other 1,520 of 1,608 done-with-PR gaps (94.5%). Nothing
     schedules it either.

THE SIGNAL THIS USES INSTEAD

CREDIBLE-175 was proven a false done not by acceptance-bullet scoring but by
set arithmetic a person could do by eye: the gap's text names concrete repo
paths, and the closing PR's diff touched none of them. #3552 changed
.env.example, uncommitted-wip-watchdog.sh, install-wip-watchdog-launchd.sh,
src/git_safety.rs and tests/git_safety_e2e.rs. The gap was about
scripts/git-hooks/pre-push. Disjoint. The clinching receipt was
`git log -S nextest -- scripts/git-hooks/pre-push` returning empty: the work had
never landed in any commit, ever.

The closing mechanism is auto-flip-on-merge marking done every gap a PR merely
CITES (CREDIBLE-268). So the damage concentrates in PRs that closed several
gaps at once — which is the cheap prefilter this offers via --multi-close-only.

HONEST LIMITS — read before believing an output

  - This flags SUSPECTS, not verdicts. A gap can legitimately name a path the
    fix did not need to touch (a doc-only follow-up, a revert, a config change).
    Every flag needs the two-minute human check the report prints.
  - It can only judge gaps whose text names at least one concrete path. Gaps
    written purely in prose are reported separately as UNJUDGEABLE rather than
    silently counted as clean — absence of a path is not evidence of health.
  - A PR file list that cannot be fetched is reported as FETCH-FAILED, never as
    passing. Same rule.
  - MEASURED NEGATIVE CONTROL (2026-08-10): path-overlap alone does NOT catch
    CREDIBLE-175, the very case that motivated this. Its text names the exact
    files #3552 touched (src/git_safety.rs, tests/git_safety_e2e.rs, the WIP
    watchdog and its installer), so the overlap test calls it clean. Treat the
    SUSPECT tier as a triage queue with a real false-negative rate, not a
    detector. The BOOKKEEPING tier below is the one with teeth.

THE TIER THAT ACTUALLY HAS TEETH

A closing PR whose diff contains NO implementation files at all — only
docs/gaps/*.yaml, docs/audits/*, docs/ROADMAP.md, docs/archive/* — cannot have
shipped the work it is credited with. That is not a heuristic, it is set
membership. First run over the 47 multi-close PRs: 6 such PRs, closing 79 gaps
(3 P0, 23 P1, 52 P2, 1 P3). What this proves is that the closed_pr ATTRIBUTION
is false; whether the work landed in some OTHER PR still needs the per-gap
check, because a bookkeeping PR can legitimately record work done elsewhere.
Either way the registry's receipt points at a diff that does not contain it.

NOTE ON THE COUNTS ABOVE: "47 multi-close PRs" / "79 gaps" / "6 such PRs" were
the live registry state on 2026-08-10, the day this was first run. The
registry keeps growing, so a later run will report different numbers — that
is expected drift, not a regression. Treat this file's counts as a point-in-
time citation, never as an invariant to assert against in a test.

CREDIBLE-1264 re-verified the same three AC on 2026-09-16 against the
already-shipped script (CREDIBLE-279/336/459/791): the file exists and is
executable, `--multi-close-only --json` still emits `bookkeeping_closed` as a
JSON array (81 entries against the live registry that day, not 79 — see the
drift note above), and `scripts/ci/test-false-done-sweep.sh` still passes,
confirming the exit-0/non-zero contract. No behavior change needed.

CREDIBLE-1330 re-verified the same three AC again on 2026-09-18: file
present + executable, `scripts/ci/test-false-done-sweep.sh` still passes
(7/7, including the deterministic --multi-close-only --json fixture that
asserts the exact BOOKKEEPING/non-BOOKKEEPING classification), and a live
run reports 81 bookkeeping-closed gaps (still not 79 — same drift, unchanged
since CREDIBLE-1264). No behavior change needed.

CREDIBLE-1366 re-verified the same three AC again on 2026-09-19: file
present + executable + tracked in git, `--multi-close-only`/`--json` flags
work, `scripts/ci/test-false-done-sweep.sh` still passes (7/7, including the
deterministic --multi-close-only --json fixture the reproducibility claim
actually rests on — a live registry count is not reproducible by
construction, see the drift note above), and a live run reports 81
bookkeeping-closed gaps (same as CREDIBLE-1330, drift unchanged since
CREDIBLE-1264). No behavior change needed.

CREDIBLE-1367 re-verified the same three AC again on 2026-09-19 (CREDIBLE-279
slice): file present + executable + tracked in git, `--multi-close-only`/
`--json` flags work, `scripts/ci/test-false-done-sweep.sh` still passes
(7/7), and a live run again reports 81 bookkeeping-closed gaps — identical to
CREDIBLE-1366 run minutes earlier, confirming the registry did not shift
between the two slices. The gap's literal AC ("each of the 79 gaps receives a
definitive per-gap verdict") cannot be satisfied as a one-time PR: the
registry drifts (69→70→81 across CREDIBLE-1264/1330/1366/1367) faster than a
manual per-gap disposition pass can complete, so a static list frozen at 79
would be stale before merge. The durable fix is this script + its CI test —
they make the per-gap verdict computable on demand (`--gap <ID>` for one,
`--multi-close-only --json` for the live cohort) rather than encoding a
snapshot that immediately rots. No behavior change needed.

Usage:
  python3 scripts/ops/false-done-sweep.py --multi-close-only      # cheapest, highest yield
  python3 scripts/ops/false-done-sweep.py --all --limit 400       # broader
  python3 scripts/ops/false-done-sweep.py --gap CREDIBLE-175      # check one
  python3 scripts/ops/false-done-sweep.py --multi-close-only --json
  python3 scripts/ops/false-done-sweep.py --grep-target-sweep     # CREDIBLE-1087 slice
Exit 0 always unless --strict, which exits 1 when any suspect is found.
--grep-target-sweep always exits 0 regardless of findings (see
grep_target_sweep() below).
"""
import argparse
import json
import os
import re
import subprocess
import sys

CACHE = os.path.expanduser("~/.cache/chump/false-done-pr-files.json")

# A "concrete path" is a repo-relative path with a known source extension, or a
# directory prefix this repo actually uses. Deliberately conservative: a loose
# pattern turns prose like "the gap registry" into a phantom path and produces
# confident nonsense.
PATH_RE = re.compile(
    r"\b((?:src|crates|scripts|tests|docs|web|\.github)/[A-Za-z0-9_./-]+"
    r"|[A-Za-z0-9_-]+\.(?:rs|sh|py|ya?ml|toml|js|ts|md))\b"
)
# Paths that appear in nearly every gap and so carry no scope information.
NOISE = {
    "docs/gaps", "state.db", "ambient.jsonl", "Cargo.toml", "README.md",
    "CLAUDE.md", "AGENTS.md", ".chump/state.sql",
}

# CREDIBLE-1087 (CREDIBLE-274 slice) — grep-target-sweep. Mirrors the walk +
# regex approach above (PATH_RE / paths_in): only the unambiguous single-shot
# form counts — grep <bool flags> <quoted pattern> <target> <clause end>.
# Requiring a quoted pattern before the target keeps a grep's own search text
# (which often itself contains path-shaped substrings) from being mistaken
# for the target argument.
GREP_TARGET_RE = re.compile(
    r"""\bgrep\s+
        (?:-[qniEFvwrlxcoPs]+\s+)*
        (?:"[^"]*"|'[^']*')\s+
        (?P<target>"[^"$]*"|'[^'$]*'|[A-Za-z0-9_./-]+)
        (?=\s*(?:;|\)|&&|\|\||\#|$|2>))
    """,
    re.VERBOSE,
)


def _strip_quotes(tok):
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in ("'", '"'):
        return tok[1:-1]
    return tok


def _is_grep_target_path(tok):
    if not tok or tok.startswith(("$", "-")):
        return False
    return "/" in tok or re.search(r"\.[A-Za-z0-9]+$", tok)


def grep_target_sweep(repo_root):
    """Walk scripts/ci, find `grep` invocations whose target path doesn't
    exist, and return a list of (rel_path, lineno, target) findings."""
    scan_dir = os.path.join(repo_root, "scripts", "ci")
    findings = []
    for dirpath, _dirs, files in os.walk(scan_dir):
        for name in sorted(files):
            if not (name.endswith(".sh") or name.endswith(".py")):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, repo_root)
            try:
                with open(path, errors="ignore") as fh:
                    lines = fh.readlines()
            except OSError:
                continue
            for lineno, line in enumerate(lines, start=1):
                stripped = line.strip()
                if stripped.startswith("#") or "|" in line:
                    continue
                m = GREP_TARGET_RE.search(line)
                if not m:
                    continue
                target = _strip_quotes(m.group("target"))
                if not _is_grep_target_path(target):
                    continue
                if os.path.exists(os.path.join(repo_root, target)):
                    continue
                findings.append((rel, lineno, target))
    return sorted(findings)


def sh(cmd, timeout=90):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None


def load_gaps():
    out = sh(["chump", "gap", "list", "--json"], timeout=240)
    if not out:
        sys.exit("could not read the gap registry (`chump gap list --json` failed)")
    d = json.loads(out)
    return d if isinstance(d, list) else d.get("gaps", d.get("data", []))


def gap_text(g):
    # `notes` is included deliberately: gaps name paths in two different roles —
    # EVIDENCE paths (where the problem was observed) and FIX-SITE paths (what the
    # change touches), and the fix site is very often only in the notes. Excluding
    # notes produced a false positive on RESILIENT-280 in validation, whose
    # evidence named scripts/coord/*-loop.sh (where the wrong heartbeat kinds are
    # emitted) while the fix landed in crates/chump-curator-supervisor/.
    return " ".join(
        str(g.get(k) or "")
        for k in ("title", "description", "acceptance_criteria", "evidence", "notes")
    )


def paths_in(text):
    found = set()
    for m in PATH_RE.finditer(text):
        p = m.group(1).strip(".,;:")
        if p in NOISE or any(p.startswith(n) for n in NOISE):
            continue
        found.add(p)
    return found


class PrFiles:
    """PR -> file list, cached on disk. Network failures are surfaced, not hidden."""

    def __init__(self):
        self.cache = {}
        if os.path.exists(CACHE):
            try:
                self.cache = json.load(open(CACHE))
            except Exception:
                self.cache = {}

    def get(self, pr):
        key = str(pr)
        if key in self.cache:
            return self.cache[key]
        out = sh(["gh", "pr", "view", key, "--repo", "repairman29/chump", "--json", "files"])
        if out is None:
            return None  # caller reports FETCH-FAILED; never treated as clean
        try:
            files = [f["path"] for f in (json.loads(out).get("files") or [])]
        except Exception:
            return None
        self.cache[key] = files
        return files

    def save(self):
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        json.dump(self.cache, open(CACHE, "w"))


# A closing PR made only of these paths shipped no code. Registry bookkeeping,
# roadmap edits and audit write-ups are not implementations of anything.
BOOKKEEPING_PREFIXES = ("docs/gaps/", "docs/audits/", "docs/archive/", ".chump/")
BOOKKEEPING_EXACT = {"docs/ROADMAP.md"}


def is_implementation(path):
    if path in BOOKKEEPING_EXACT:
        return False
    return not path.startswith(BOOKKEEPING_PREFIXES)


def basename_overlap(gap_paths, pr_files):
    """Match on full path OR basename — a gap often names `pre-push` where the PR
    lists `scripts/git-hooks/pre-push`. Basename matching keeps false alarms down."""
    pr_set = set(pr_files)
    pr_base = {os.path.basename(p) for p in pr_files}
    hit = set()
    for gp in gap_paths:
        if gp in pr_set or os.path.basename(gp) in pr_base:
            hit.add(gp)
        elif any(p.endswith("/" + gp) or p.startswith(gp.rstrip("/") + "/") for p in pr_files):
            hit.add(gp)
    return hit


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--multi-close-only", action="store_true",
                    help="only PRs that closed >=N gaps — where auto-flip damage concentrates")
    ap.add_argument("--multi-threshold", type=int, default=3)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--gap", help="audit a single gap id")
    ap.add_argument("--limit", type=int, default=0, help="cap gaps examined (0 = no cap)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict", action="store_true", help="exit 1 if any suspect found")
    ap.add_argument("--grep-target-sweep", action="store_true",
                     help="CREDIBLE-1087: sweep scripts/ci for grep calls whose "
                          "target path doesn't exist; always exits 0")
    a = ap.parse_args()

    if a.grep_target_sweep:
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        findings = grep_target_sweep(repo_root)
        if a.json:
            print(json.dumps({
                "vacuous_grep_count": len(findings),
                "findings": [
                    {"file": f, "line": ln, "target": t} for f, ln, t in findings
                ],
            }, indent=2))
        else:
            print(f"Vacuous grep count: {len(findings)}")
            for f, ln, t in findings:
                print(f"{f}:{ln} – {t}")
        sys.exit(0)

    gaps = load_gaps()
    done = [g for g in gaps if g.get("status") == "done" and g.get("closed_pr")]

    if a.gap:
        done = [g for g in done if str(g.get("id")) == a.gap]
        if not done:
            sys.exit(f"{a.gap}: not a done gap with a closed_pr")
    elif a.multi_close_only:
        by = {}
        for g in done:
            by.setdefault(str(g["closed_pr"]), []).append(g)
        keep = {pr for pr, gs in by.items() if len(gs) >= a.multi_threshold}
        done = [g for g in done if str(g["closed_pr"]) in keep]
    elif not a.all:
        sys.exit("pick one of --multi-close-only / --all / --gap (no silent default scope)")

    if a.limit:
        done = done[: a.limit]

    prf = PrFiles()
    suspects, unjudgeable, fetch_failed, bookkeeping, clean = [], [], [], [], 0

    for g in done:
        gid, pr = str(g["id"]), g["closed_pr"]
        files = prf.get(pr)
        if files is None:
            fetch_failed.append((gid, pr))
            continue
        # The bookkeeping test comes FIRST: it depends only on the PR's diff, not
        # on whether the gap's prose happens to name a path. Running it after the
        # unjudgeable skip under-reported this tier by 10 gaps on the first pass.
        if files and not any(is_implementation(f) for f in files):
            # Set membership, not a guess: this diff contains no implementation.
            bookkeeping.append({
                "gap": gid, "pr": pr,
                "title": str(g.get("title") or "")[:110],
                "priority": g.get("priority"),
                "pr_file_count": len(files),
            })
            continue
        gp = paths_in(gap_text(g))
        if not gp:
            unjudgeable.append((gid, pr, "gap text names no concrete path"))
            continue
        hit = basename_overlap(gp, files)
        if hit:
            clean += 1
        else:
            suspects.append({
                "gap": gid, "pr": pr,
                "title": str(g.get("title") or "")[:110],
                "gap_paths": sorted(gp)[:6],
                "pr_files": files[:8],
                "pr_file_count": len(files),
            })
    prf.save()

    if a.json:
        print(json.dumps({
            "examined": len(done), "suspects": suspects,
            "bookkeeping_closed": bookkeeping,
            "unjudgeable": len(unjudgeable), "fetch_failed": len(fetch_failed),
            "scope_confirmed": clean,
        }, indent=2))
    else:
        print(f"false-done sweep: {len(done)} done gaps examined")
        print(f"  BOOKKEEPING-CLOSED (closing PR shipped NO code)   : {len(bookkeeping)}")
        print(f"  scope confirmed (PR touched a path the gap names): {clean}")
        print(f"  SUSPECTS (PR touched NONE of them)               : {len(suspects)}")
        print(f"  unjudgeable (gap names no concrete path)          : {len(unjudgeable)}")
        print(f"  fetch failed (NOT counted clean)                  : {len(fetch_failed)}")
        if suspects:
            print("\n  Each of these needs the two-minute human check before you believe it:")
            print("    1. does the gap's described work exist in the tree at all?")
            print("       git log -S '<distinctive string>' -- <path the gap names>")
            print("    2. did the closing PR merely CITE the gap in its body? (CREDIBLE-268)")
            print()
        for s in sorted(suspects, key=lambda x: x["gap"]):
            print(f"  ⚠ {s['gap']} (#{s['pr']}) {s['title']}")
            print(f"      gap names : {', '.join(s['gap_paths'])}")
            print(f"      PR touched: {', '.join(s['pr_files'])}"
                  + (f" (+{s['pr_file_count'] - len(s['pr_files'])} more)"
                     if s["pr_file_count"] > len(s["pr_files"]) else ""))

        if bookkeeping:
            print("\n  BOOKKEEPING-CLOSED — the credited PR contains no implementation at all.")
            print("  This tier is set membership, not a heuristic. Highest priority first:\n")
            rank = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
            for b in sorted(bookkeeping, key=lambda x: (rank.get(x["priority"], 9), x["gap"])):
                print(f"  ✗ [{b['priority']}] {b['gap']} (#{b['pr']}, {b['pr_file_count']} files, 0 code) {b['title']}")

    if a.strict and (suspects or bookkeeping):
        sys.exit(1)


if __name__ == "__main__":
    main()
