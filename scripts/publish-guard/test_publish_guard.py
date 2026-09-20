#!/usr/bin/env python3
"""Table test for publish-guard.py. Synthetic terms only: nothing real is in this file.

Run:  python3 scripts/publish-guard/test_publish_guard.py          (exit 0 = every case behaved as listed)

Depth tiers are named per case and summarised in DEPTH.md. Cases marked KNOWN-MISS assert
that the guard does NOT catch something, so the gap is pinned by a test instead of implied.
"""
import base64
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "publish-guard.py")
PY = sys.executable

PATTERNS = """#! publish-guard-patterns v1
#! version 3
#! nonce 0000-test-only
hostname   term   zorkmidbox
hostname   word   quux
personal   term   pat.example.person@corp.invalid
employer   term   Initech Global
repo-name  term   secret-sauce-repo
network    regex  \\bzz-[0-9]{4}\\.mesh\\b
allow      term   noreply@gmail.com
"""


def diff(path, *added, **kw):
    start = kw.get("start", 1)
    body = "".join("+%s\n" % a for a in added)
    return "diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -0,0 +%d,%d @@\n%s" % (path, path, path, path, start, len(added), body)


def run(args, stdin, patterns=PATTERNS, env=None):
    with tempfile.TemporaryDirectory() as d:
        pf = os.path.join(d, "p")
        if patterns is not None:
            with open(pf, "w") as fh:
                fh.write(patterns)
        argv = [PY, GUARD] + [a.replace("@P", pf).replace("@D", d) for a in args]
        e = dict(os.environ)
        e.update(env or {})
        p = subprocess.run(argv, input=stdin.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e)
        return p.returncode, p.stdout.decode(), p.stderr.decode()


D = ["--patterns", "@P", "--diff"]
T = ["--patterns", "@P", "--text", "commit-message"]
b64 = lambda s: base64.b64encode(s.encode()).decode()
KEY = "sk-ant-" + "A1b2C3d4" * 5                      # shaped like a key, is not one

# (tier, name, args, stdin, want exit, must appear in stdout, must NOT appear anywhere)
CASES = [
    ("smoke", "clean diff passes", D, diff("src/a.rs", "fn main() {}"), 0, None, None),
    ("smoke", "clean commit message passes", T, "INFRA-1: tidy the parser\n", 0, None, None),
    ("happy", "operator term in a diff, with file:line", D, diff("docs/x.md", "ok", "ssh zorkmidbox uptime", start=10), 1, "docs/x.md:11: hostname", "zorkmidbox"),
    ("happy", "provider key shape", D, diff("a.env.example", "KEY=" + KEY), 1, "provider-key", KEY),
    ("happy", "home path", D, diff("s.sh", "cd /Users/realperson/Projects/x"), 1, "home-path", "realperson"),
    ("happy", "tailnet CGNAT address", D, diff("n.json", '"ip": "100.101.102.103"'), 1, "network", "100.101"),
    ("happy", "personal email provider", D, diff("a.md", "mail someone.real@gmail.com"), 1, "personal-data", "someone.real"),
    ("happy", "webhook url", D, diff("a.sh", "curl https://discord.com/api/webhooks/123456/abcDEF_ghi"), 1, "webhook-url", "abcDEF"),
    ("happy", "bearer token", D, diff("a.sh", "-H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345'"), 1, "bearer-token", "abcdefghijkl"),
    ("happy", "term ONLY in the commit message", T, "INFRA-2: fix deploy\n\nbroke on zorkmidbox last night\n", 1, "commit-message:3: hostname", "zorkmidbox"),
    ("happy", "term in a PR body", ["--patterns", "@P", "--text", "pr-body"], "Title\n\nTested against Initech Global staging", 1, "pr-body:3: employer", "Initech"),
    ("happy", "event log path", D, diff(".chump-locks/ambient.jsonl", "{}"), 1, "event-log", None),
    ("happy", "session transcript content", D, diff("x.json", '{"parentUuid":"0123abcd-0123-0123-0123-0123456789ab"}'), 1, "transcript", None),
    ("edge", "removed lines are not scanned", D, "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,1 +0,0 @@\n-ssh zorkmidbox\n", 0, None, None),
    ("edge", "word rule needs a boundary (quuxly is fine)", D, diff("a.md", "a quuxly thing"), 0, None, None),
    ("edge", "word rule hits the whole word", D, diff("a.md", "ssh quux"), 1, "hostname", None),
    ("edge", "case-insensitive term", D, diff("a.md", "ZorkMidBox"), 1, "hostname", None),
    ("edge", "placeholder home path allowed", D, diff("a.md", "cd /Users/you/Projects && ls $HOME"), 0, None, None),
    ("edge", "allow-listed address is not a finding", D, diff("a.md", "Co-Authored-By: x <noreply@gmail.com>"), 0, None, None),
    ("edge", "placeholder config secret ignored", D, diff("a.md", "api_key=your-api-key-here-example"), 0, None, None),
    ("edge", "random-looking config secret caught", D, diff("a.toml", 'client_secret = "q7Zp2Lw9Xk4Vt8Rb3Nf6"'), 1, "config-secret", "q7Zp2Lw9"),
    ("edge", "bypass recipe is WARN by default, exit 0", D, diff("d.md", "CHUMP_CREDENTIAL_CHECK=0 git commit -m x"), 0, "(warn)", None),
    ("edge", "version string is not an IP", D, diff("a.md", "needs macOS 10.15.7 or later"), 0, None, None),
    ("edge", "override accepts one fingerprint on one path", None, None, 0, None, None),          # filled below
    ("edge", "override for another path does not apply", None, None, 1, None, None),              # filled below
    ("adversarial", "term inside a file PATH", D, diff("docs/zorkmidbox-notes.md", "hello"), 1, "<path-withheld#1 depth=1 ext=md>:0: hostname rule=P4 via=path", "zorkmidbox"),
    ("adversarial", "term in a rename target", D, "diff --git a/a.md b/x/secret-sauce-repo.md\nrename from a.md\nrename to x/secret-sauce-repo.md\n", 1, "repo-name", None),
    ("adversarial", "base64 of the whole term", D, diff("a.txt", "blob=" + b64("zorkmidbox")), 1, "via=base64", None),
    ("adversarial", "term inside a longer base64 blob, any alignment", D, diff("a.txt", b64("x host=zorkmidbox; port=22 and more text")), 1, "hostname", None),
    ("adversarial", "base64 of a provider key", D, diff("a.txt", b64("token " + KEY)), 1, "provider-key", None),
    ("adversarial", "hex of a home path", D, diff("a.txt", "/Users/realperson/x".encode().hex()), 1, "home-path", None),
    ("adversarial", "string split with concatenation", D, diff("a.py", 'h = "zork" + "mid" + "box"'), 1, "via=squashed", None),
    ("adversarial", "string split across added lines", D, diff("a.py", 'h = ("zork"', '     "midbox")'), 1, "via=squashed", None),
    ("adversarial", "reversed term", D, diff("a.py", 'h = "xobdimkroz"[::-1]'), 1, "via=reversed", None),
    ("adversarial", "Cyrillic look-alikes (o, c)", D, diff("a.md", "zоrkmidbоx"), 1, "hostname", None),
    ("adversarial", "full-width letters", D, diff("a.md", "ｚｏｒｋmidbox"), 1, "hostname", None),
    ("adversarial", "zero-width joiner inside the term", D, diff("a.md", "zork​mid‍box"), 1, "hostname", None),
    ("adversarial", "url-encoded term", D, diff("a.md", "http://x/?h=zorkmid%62ox"), 1, "hostname", None),
    ("adversarial", "email term with dots survives squashing", D, diff("a.md", "pat . example . person @ corp . invalid"), 1, "personal", None),
    ("adversarial", "author line in a commit (via --text)", T, "x\n\nReal Person <someone.real@gmail.com>\n", 1, "personal-data", None),
    ("adversarial", "fail closed: pattern file missing", ["--patterns", "@D/nope", "--diff"], diff("a", "x"), 2, None, None),
    ("adversarial", "fail closed: pattern file empty of rules", D, diff("a", "x"), 2, None, None),      # patched below
    ("adversarial", "fail closed: stale pattern version", ["--patterns", "@P", "--min-version", "9", "--diff"], diff("a", "x"), 2, None, None),
    ("adversarial", "fail closed: no --patterns at all", ["--diff"], diff("a", "x"), 2, None, None),
    ("adversarial", "no env var disables it", D, diff("a.md", "zorkmidbox"), 1, None, None),          # env patched below
    ("adversarial", "KNOWN-MISS rot13 (documented gap)", D, diff("a.md", "mbexzvqobk"), 0, None, None),
    ("adversarial", "KNOWN-MISS gzip+base64 (documented gap)", D, diff("a.md", "H4sIAAAAAAAAA6vKL8rOzUzJT6oEAJ3z1HkKAAAA"), 0, None, None),
    ("adversarial", "KNOWN-MISS term split across two FILES (documented gap)", D, diff("a.py", 'A="zorkm"') + diff("b.py", 'B="idbox"'), 0, None, None),
]


def main():
    bad = 0
    tally = {}
    for tier, name, args, stdin, want, must, must_not in CASES:
        patterns, env, extra = PATTERNS, None, None
        if name.startswith("fail closed: pattern file empty"):
            patterns = "#! publish-guard-patterns v1\n#! version 3\n# nothing\n"
        if name.startswith("no env var"):
            env = {"PUBLISH_GUARD": "0", "CHUMP_PUBLISH_GUARD": "0", "PUBLISH_GUARD_BYPASS": "1", "CHUMP_CREDENTIAL_CHECK": "0", "CI": "true"}
        if name.startswith("override"):
            # learn the fingerprint from a first run, then supply it
            rc, out, _ = run(D, diff("docs/ok.md", "zorkmidbox"))
            fp = out.split("fp=")[1].split()[0]
            glob = "docs/*.md" if "accepts" in name else "src/*"
            with tempfile.NamedTemporaryFile("w", suffix=".ov", delete=False) as fh:
                fh.write("%s hostname %s documented example host, approved by operator\n" % (fp, glob))
                extra = fh.name
            args, stdin = ["--patterns", "@P", "--overrides", extra, "--diff"], diff("docs/ok.md", "zorkmidbox")
        rc, out, err = run(args, stdin, patterns=patterns, env=env)
        if extra:
            os.unlink(extra)
        ok = rc == want and (must is None or must in out) and (must_not is None or must_not not in (out + err))
        tally.setdefault(tier, [0, 0])
        tally[tier][0] += ok
        tally[tier][1] += 1
        bad += (not ok)
        print("%s %-11s %s%s" % ("PASS" if ok else "FAIL", tier, name, "" if ok else "   (exit %d, out=%r, err=%r)" % (rc, out[:160], err[:160])))
    print()
    for tier in ("smoke", "happy", "edge", "adversarial"):
        if tier in tally:
            print("%-11s %d/%d" % (tier, tally[tier][0], tally[tier][1]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
