#!/usr/bin/env python3
"""report_only.py: run publish-guard.py, log what it found, never block. (INFRA-7880)

The one entry point for every local caller while the guard is in its measuring phase:

    report_only.py staged                  pre-commit: the staged diff
    report_only.py message <file>          commit-msg: the real message file
    report_only.py text <label>            ship script: PR title + body on stdin
    report_only.py range <base> <head>     CI: the range's diff, then its messages and identities

  --summary-only (first argument) prints the summary line and nothing else. CI uses it: Actions
  logs on a public repo are public, and a list of path:line pointers is a map to the findings.

What it does with the result:
  - stderr: the engine's finding lines (path:line: CLASS rule= via= fp=) and one summary line.
    The engine never prints a matched value, a pattern or the matched line; neither does this.
  - ambient stream: one "publish_guard_report" event with counts per class. No paths, no
    fingerprints, no text.
  - exit code: ALWAYS 0. A finding, a broken pattern file, a missing python or an exception in
    here all end in exit 0. Callers additionally ignore the exit code.

Pattern file: ~/.config/chump/publish-guard.patterns (private, outside every repo). If it is
absent the engine runs with --builtin-only and the summary line says so.

Registry paths are skipped in `staged` mode. They are more than 99% of all findings and are
published by a separate sync job that does not go through hooks; including them buries the
signal this phase exists to measure. This skip belongs to report-only mode. A blocking caller
must not inherit it.

Reads no environment variable of its own and offers no off switch: there is nothing to switch
off, because it cannot fail a commit.
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(HERE, "publish-guard.py")
PATTERNS = os.path.join(os.path.expanduser("~"), ".config", "chump", "publish-guard.patterns")
REGISTRY_EXCLUDES = [":(exclude).chump/state.sql", ":(exclude).chump/state.sql.lz4", ":(exclude)docs/gaps"]
FINDING = re.compile(r"^.*:\d+: (\S+) rule=\S+ via=\S+ fp=[0-9a-f]{12}( \(warn\))?$")


def git(*args):
    p = subprocess.run(("git",) + args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.stdout if p.returncode == 0 else None


def repo_roots():
    top = git("rev-parse", "--show-toplevel")
    common = git("rev-parse", "--git-common-dir")
    top = top.decode().strip() if top else os.getcwd()
    # the ambient stream lives in the MAIN checkout, also when called from a linked worktree
    main = os.path.dirname(os.path.abspath(common.decode().strip())) if common else top
    return top, main


def emit(main_root, event):
    log = os.path.join(main_root, ".chump-locks", "ambient.jsonl")
    if not os.path.isdir(os.path.dirname(log)):
        return
    line = (json.dumps(event, separators=(",", ":")) + "\n").encode()
    fd = os.open(log, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line)                      # one short O_APPEND write: no interleaving
    finally:
        os.close(fd)


def main(argv):
    summary_only = bool(argv) and argv[0] == "--summary-only"
    if summary_only:
        argv = argv[1:]
    if not argv or argv[0] not in ("staged", "message", "text", "range"):
        sys.stderr.write("[publish-guard] report-only: usage: [--summary-only] staged | message <file> | text <label> | range <base> <head>\n")
        return
    site = argv[0]
    top, main_root = repo_roots()
    if site == "range":
        base, head = argv[1], argv[2]
        diff = git("diff", "-U0", "--no-color", "--no-ext-diff", "%s...%s" % (base, head), "--", ".", *REGISTRY_EXCLUDES)
        msgs = git("log", "--format=%B%n%an <%ae>%n%cn <%ce>", "%s..%s" % (base, head))
        scan(top, main_root, "range-diff", diff, ["--diff"], summary_only)
        scan(top, main_root, "range-messages", msgs, ["--text", "commit-messages"], summary_only)
        return

    if site == "staged":
        data = git("diff", "--cached", "-U0", "--no-color", "--no-ext-diff", "--", ".", *REGISTRY_EXCLUDES)
        mode = ["--diff"]
    elif site == "message":
        with open(argv[1], "rb") as fh:
            # drop comment lines and everything under the scissors line, as git itself will
            raw = fh.read().decode("utf-8", "replace").split("# ------------------------ >8")[0]
        data = "".join(l for l in raw.splitlines(True) if not l.startswith("#")).encode()
        mode = ["--text", "commit-message"]
    else:
        data = sys.stdin.buffer.read()
        mode = ["--text", argv[1] if len(argv) > 1 else "pr-title-and-body"]
    scan(top, main_root, site, data, mode, summary_only)


def scan(top, main_root, site, data, mode, summary_only):
    if not data:
        return
    cmd = [sys.executable, ENGINE]
    if os.path.isfile(PATTERNS):
        patterns = "full"
        cmd += ["--patterns", PATTERNS]
        try:
            with open(os.path.join(top, ".publish-guard", "MIN_PATTERNS_VERSION")) as fh:
                cmd += ["--min-version", str(int(fh.read().strip()))]
        except (OSError, ValueError):
            pass
    else:
        patterns = "builtin-only"
        cmd += ["--builtin-only"]
    overrides = os.path.join(top, ".publish-guard", "overrides.txt")
    if os.path.isfile(overrides):
        cmd += ["--overrides", overrides]

    p = subprocess.run(cmd + mode, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = p.stdout.decode("utf-8", "replace")
    classes, blocking, warn = {}, 0, 0
    for line in out.splitlines():
        m = FINDING.match(line)
        if not m:
            continue
        classes[m.group(1)] = classes.get(m.group(1), 0) + 1
        if m.group(2):
            warn += 1
        else:
            blocking += 1
    # the engine prints at most 200 finding lines; its summary line carries the true totals
    tot = re.search(r"publish-guard: (\d+) blocking, (\d+) warn", p.stderr.decode("utf-8", "replace"))
    if tot:
        blocking, warn = int(tot.group(1)), int(tot.group(2))
    status = {0: "clean", 1: "findings"}.get(p.returncode, "could-not-run")

    if status != "clean" and not summary_only:
        for line in out.splitlines()[:40]:
            sys.stderr.write("[publish-guard] %s\n" % line)
    note = "" if patterns == "full" else " (no pattern file at ~/.config/chump: generic rules only)"
    by_class = ",".join("%s=%d" % kv for kv in sorted(classes.items()))
    sys.stderr.write("[publish-guard] report-only %s: %s, %d would-block, %d warn%s%s. Nothing is blocked.\n"
                     % (site, status, blocking, warn, " [%s]" % by_class if by_class else "", note))
    if status == "could-not-run":
        tail = p.stderr.decode("utf-8", "replace").strip().splitlines()[-1:]
        sys.stderr.write("[publish-guard] engine said: %s\n" % (tail[0] if tail else "(nothing)"))

    emit(main_root, {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kind": "publish_guard_report",          # scanner-anchor: "kind":"publish_guard_report"
        "site": site, "status": status, "patterns": patterns,
        "blocking": blocking, "warn": warn,
        "classes": by_class,
    })


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except BaseException as exc:                 # report-only: nothing in here may stop a commit
        sys.stderr.write("[publish-guard] report-only wrapper error (%s); continuing\n" % exc.__class__.__name__)
    sys.exit(0)
