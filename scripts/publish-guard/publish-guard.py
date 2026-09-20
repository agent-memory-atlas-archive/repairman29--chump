#!/usr/bin/env python3
"""publish-guard: refuse to publish private or revealing material.

Installed REPORT-ONLY (INFRA-7880): every caller goes through report-only.sh, which logs findings
and ignores the exit code. The engine itself is unchanged by that: it still exits 1 on findings.

One engine, three call sites (pre-commit/commit-msg/pre-push hooks, a required CI check,
and the ship script before it writes a PR title or body). Stdlib only, Python 3.8+.

    git diff --cached -U0 | publish-guard.py --patterns FILE --diff
    publish-guard.py --patterns FILE --text commit-message < .git/COMMIT_EDITMSG
    printf '%s\n\n%s' "$TITLE" "$BODY" | publish-guard.py --patterns FILE --text pr-body
    publish-guard.py --patterns FILE --git-range origin/main..HEAD   # diff + every commit message

Output, one line per finding, on stdout:

    path:line: CLASS rule=<id> via=<how> fp=<12 hex>

It NEVER prints the matched value, the pattern, or the line it matched on: CI logs on a
public repo are public, and a guard that echoes the secret it found has published it.
(The older credential grep in scripts/git-hooks/pre-commit did exactly that until INFRA-7880.)

Exit codes:  0 clean   1 findings   2 the guard could not run (treat as BLOCK)

Fails CLOSED. A missing, unreadable, empty, stale or malformed pattern file is exit 2, not
a pass. There is no environment variable that turns this off and the script reads none.
The only way past a finding is a line in the public overrides file naming the finding's
fingerprint, class, path and a reason. That line is reviewable in git history and contains
no secret: a fingerprint is a hash of something a human has judged fit to publish.

Pattern file (PRIVATE: lives outside the public tree). One rule per line:

    #! publish-guard-patterns v1
    #! version 7
    #! nonce 3b1f...            (random; makes the file's sha256 safe to log)
    # class      kind    pattern
    hostname     term    examplehost          substring, case-insensitive, all evasion views
    hostname     word    pixel                whole word only (for short or common words)
    network      regex   \\bfd7a:115c:a1e0:   Python regex, case-insensitive
    allow        term    noreply@example.com  never a finding, whatever matched it
    severity     bypass-recipe  warn          report a class without blocking

Depth: see DEPTH.md beside this file. Summary: edge plus a named set of adversarial cases.
It stops the ordinary mistake and the lazy evasion. It does not stop encryption, images,
a term split across files, or an agent that edits the guard.
"""
import argparse
import base64
import binascii
import fnmatch
import hashlib
import math
import re
import subprocess
import sys
import unicodedata
from urllib.parse import unquote

EXIT_CLEAN, EXIT_FINDINGS, EXIT_BROKEN = 0, 1, 2
MAX_PRINT = 200

# --------------------------------------------------------------------------------------
# Built-in generic rules. Safe to publish: nothing here is specific to one operator.
# (class, rule id, regex). Case-insensitive unless the regex says otherwise.
# The token prefixes reuse the table in Chump's src/context_firewall.rs:108-124 and the
# pre-commit list at scripts/git-hooks/pre-commit:1706, then extend both.
# --------------------------------------------------------------------------------------
BUILTIN = [
    ("provider-key", "B-anthropic", r"(?-i:sk-ant-[A-Za-z0-9_-]{24,})"),
    ("provider-key", "B-openai", r"(?-i:\bsk-(?:proj-|or-v1-)?[A-Za-z0-9_-]{32,})"),
    ("provider-key", "B-github", r"(?-i:\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{30,}))"),
    ("provider-key", "B-aws", r"(?-i:\b(?:AKIA|ASIA)[0-9A-Z]{16}\b)"),
    ("provider-key", "B-google", r"(?-i:\bAIzaSy[A-Za-z0-9_-]{30,})"),
    ("provider-key", "B-slack", r"(?-i:\bxox[baprs]-[A-Za-z0-9-]{10,})"),
    ("provider-key", "B-stripe", r"(?-i:\b(?:sk|rk|pk)_live_[A-Za-z0-9]{16,}|\bwhsec_[A-Za-z0-9]{24,})"),
    ("provider-key", "B-misc", r"(?-i:\b(?:tgp_v1_[A-Za-z0-9_-]{30,}|hf_[A-Za-z0-9]{30,}|gsk_[A-Za-z0-9]{30,}"
                               r"|r8_[A-Za-z0-9]{30,}|sbp_[a-f0-9]{30,}|re_[A-Za-z0-9_]{24,}|tvly-[A-Za-z0-9_-]{24,}"
                               r"|pplx-[A-Za-z0-9]{30,}|tskey-[a-z]+-[A-Za-z0-9-]{16,}))"),
    ("provider-key", "B-jwt", r"(?-i:\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})"),
    ("private-key", "B-pem", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("private-key", "B-age", r"(?-i:AGE-SECRET-KEY-1[A-Z0-9]{20,})"),
    ("bearer-token", "B-bearer", r"\bbearer\s+[A-Za-z0-9._~+/=-]{20,}"),
    ("bearer-token", "B-authz", r"\bauthorization\b\s*[:=]\s*[\"']?(?:basic|token)\s+[A-Za-z0-9._~+/=-]{16,}"),
    ("webhook-url", "B-discord", r"discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]+"),
    ("webhook-url", "B-slackhook", r"hooks\.slack\.com/services/[A-Za-z0-9/]+"),
    ("webhook-url", "B-urlcreds", r"\b[a-z][a-z0-9+.-]*://[^/\s:@\"']+:[^/\s:@\"']{3,}@"),
    ("webhook-url", "B-urltoken", r"https?://[^\s\"']+[?&](?:token|key|secret|sig|signature|access_token)=[A-Za-z0-9._~%-]{12,}"),
    ("home-path", "B-macos", r"/Users/(?!runner/|you/|me/|user/|username/|name/|example/|shared/|\$|<|\{|\*|%)[A-Za-z0-9._-]+/"),
    ("home-path", "B-linux", r"/home/(?!runner/|you/|me/|user/|username/|name/|example/|ubuntu/|\$|<|\{|\*|%)[A-Za-z0-9._-]+/"),
    ("home-path", "B-windows", r"\b[A-Z]:\\+Users\\+(?!runner|you|user|username|name|example|public)[A-Za-z0-9._-]+\\"),
    ("network", "B-rfc1918", r"(?<![0-9.])(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}(?![0-9.]*\d)"),
    ("network", "B-cgnat", r"(?<![0-9.])100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}(?![0-9.]*\d)"),
    ("network", "B-tsnet", r"\b[a-z0-9-]+\.ts\.net\b"),
    ("network", "B-tsula", r"\bfd7a:115c:a1e0:"),
    ("personal-data", "B-email", r"\b[A-Za-z0-9._%+-]+@(?:gmail|googlemail|icloud|me|mac|yahoo|outlook|hotmail|live|proton|protonmail|pm|fastmail|hey)\.(?:com|me|net)\b"),
    ("personal-data", "B-ssn", r"(?<![\d-])\d{3}-\d{2}-\d{4}(?![\d-])"),
    ("personal-data", "B-phone", r"(?<![\d.-])\(?\d{3}\)?[ .-]\d{3}[ .-]\d{4}(?![\d.-])"),
    ("transcript", "B-cc-transcript", r"\"(?:parentUuid|sessionId)\"\s*:\s*\"[0-9a-f-]{20,}\""),
    ("transcript", "B-chatlog", r"\"role\"\s*:\s*\"(?:user|assistant)\"\s*,\s*\"content\"\s*:"),
    # Recipes for getting past a gate. Default severity for this class is WARN (see below):
    # the repo's own hooks print these strings, so blocking on day one would stop the fleet.
    ("bypass-recipe", "B-noverify", r"(?:commit|push)\b[^\n]{0,60}--no-verify|core\.hooksPath=/dev/null|gh\s+pr\s+merge\b[^\n]{0,60}--admin"),
    ("bypass-recipe", "B-envbypass", r"(?-i:\b[A-Z][A-Z0-9_]{3,}_(?:CHECK|GATE|GUARD|BYPASS[A-Z_]*)=[01]\s+git\s+(?:commit|push))"),
]
# config-style secret: keyword = value, where the value looks random rather than a placeholder
CONFIG_SECRET = re.compile(
    r"\b(?:password|passwd|secret|api[_-]?key|api[_-]?token|auth[_-]?token|access[_-]?token|client[_-]?secret|private[_-]?key)\b"
    r"[\"']?\s*[:=]\s*[\"']?([^\s\"'<>{}$`,;)]{12,})", re.I)
PLACEHOLDER = re.compile(r"redacted|example|placeholder|changeme|your[_-]|xxxx|\*\*\*\*|dummy|fake|test|sample|todo|none|null|true|false", re.I)

# Paths that should not be in a public repo whatever they contain.
PATH_RULES = [
    ("event-log", "BP-locks", r"(?:^|/)\.chump-locks/"),
    ("event-log", "BP-ambient", r"(?:^|/)ambient[^/]*\.jsonl$"),
    ("event-log", "BP-runtime-jsonl", r"(?:^|/)\.chump/[^/]*\.jsonl$"),
    ("transcript", "BP-transcripts", r"(?:^|/)transcripts?/|\.claude/projects/|(?:^|/)[^/]*\.session\.jsonl?$"),
    ("private-key", "BP-dotenv", r"(?:^|/)\.env(?!\.example$|\.minimal$|\.sample$|\.template$)(?:\.[^/]+)?$"),
    ("private-key", "BP-keyfile", r"(?:^|/)id_(?:rsa|ed25519|ecdsa)$|\.(?:pem|p12|pfx|key|age)$"),
    ("opaque-blob", "BP-db", r"\.(?:db|sqlite3?|db-wal|db-shm|lz4|zst|gz|tgz|zip|7z|tar|pdf|docx|xlsx)$"),
]
DEFAULT_SEVERITY = {"bypass-recipe": "warn"}

# Latin look-alikes. NFKC already folds full-width and most compatibility forms.
CONFUSABLES = str.maketrans({
    "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "х": "x", "у": "y", "к": "k", "м": "m", "т": "t", "н": "h",
    "в": "b", "і": "i", "ј": "j", "ѕ": "s", "ԁ": "d", "ԛ": "q", "ԝ": "w", "һ": "h", "ո": "n", "ս": "u", "ց": "g",
    "α": "a", "ε": "e", "ο": "o", "ι": "i", "κ": "k", "ν": "v", "ρ": "p", "τ": "t", "υ": "u", "χ": "x", "ϲ": "c",
    "ı": "i", "ɩ": "i", "ɡ": "g", "ⅼ": "l", "ǀ": "l",
})
ZERO_WIDTH = re.compile("[\u200b-\u200f\u2060-\u2064\ufeff\u00ad\u034f\u180e]")
SQUASH = re.compile(r"[\s\"'`+\\,._\-/|()\[\]{}<>:;=*#~^]+")
B64_TOKEN = re.compile(r"[A-Za-z0-9+/_-]{24,}={0,2}")
HEX_TOKEN = re.compile(r"\b(?:[0-9a-fA-F]{2}){12,}\b")
MIN_EVASION_LEN = 6      # squashed / reversed / base64 views only for terms at least this long


def normalize(text):
    t = ZERO_WIDTH.sub("", text)
    t = unicodedata.normalize("NFKC", t).translate(CONFUSABLES)
    t = "".join(ch for ch in unicodedata.normalize("NFKD", t) if not unicodedata.combining(ch))
    return t.casefold()


def squash(text):
    return SQUASH.sub("", text)


def fingerprint(klass, canonical):
    return hashlib.sha256((klass + "\0" + canonical).encode("utf-8", "replace")).hexdigest()[:12]


def entropy(s):
    if not s:
        return 0.0
    n = float(len(s))
    return -sum((s.count(c) / n) * math.log(s.count(c) / n, 2) for c in set(s))


def b64_alignments(raw):
    """The three byte-alignment encodings of `raw`, trimmed to the characters that do not
    depend on neighbouring bytes. Finds a term inside a longer base64 blob."""
    out = set()
    for enc in (base64.b64encode, base64.urlsafe_b64encode):
        for off in range(3):
            s = enc(b"\0" * off + raw).decode("ascii").rstrip("=")
            s = s[(0, 2, 3)[off]:]
            cut = (0, 1, 1)[(off + len(raw)) % 3]
            if cut:
                s = s[:-cut]
            if len(s) >= 8:
                out.add(s)
    return out


class Broken(Exception):
    pass


class Rules:
    def __init__(self):
        self.terms = {}        # normalized term -> (class, rule id)
        self.words = []        # (compiled, class, rule id)
        self.regexes = []      # (compiled, class, rule id)
        self.allow_terms = []
        self.allow_res = []
        self.severity = dict(DEFAULT_SEVERITY)
        self.b64 = {}          # base64 fragment -> (class, rule id, canonical)
        self.squashed = {}     # squashed term -> (class, rule id, canonical)
        self.version = None
        self.sha = "builtin-only"
        self.term_re = None
        for klass, rid, rx in BUILTIN:
            self.regexes.append((re.compile(rx, re.I), klass, rid))
        self.path_rules = [(re.compile(rx, re.I), k, rid) for k, rid, rx in PATH_RULES]

    def load(self, path, min_version):
        try:
            with open(path, "rb") as fh:
                blob = fh.read()
        except OSError as exc:
            raise Broken("pattern file unreadable: %s" % exc.__class__.__name__)
        self.sha = hashlib.sha256(blob).hexdigest()[:16]
        lines = blob.decode("utf-8", "replace").splitlines()
        if not lines or not lines[0].startswith("#! publish-guard-patterns v1"):
            raise Broken("pattern file has no '#! publish-guard-patterns v1' header")
        operator_rules = 0
        for n, line in enumerate(lines, 1):
            s = line.strip()
            if s.startswith("#! version"):
                try:
                    self.version = int(s.split()[2])
                except (IndexError, ValueError):
                    raise Broken("pattern file line %d: bad version" % n)
                continue
            if not s or s.startswith("#"):
                continue
            parts = s.split(None, 2)
            if len(parts) < 3:
                raise Broken("pattern file line %d: want '<class> <kind> <pattern>'" % n)
            klass, kind, pat = parts
            rid = "P%d" % n
            if klass == "severity":
                if pat not in ("warn", "block"):
                    raise Broken("pattern file line %d: severity is warn or block" % n)
                self.severity[kind] = pat
                continue
            try:
                if klass == "allow":
                    if kind == "regex":
                        self.allow_res.append(re.compile(pat, re.I))
                    else:
                        self.allow_terms.append(normalize(pat))
                    continue
                if kind == "term":
                    canon = normalize(pat)
                    self.terms[canon] = (klass, rid)
                    if len(squash(canon)) >= MIN_EVASION_LEN:
                        self.squashed[squash(canon)] = (klass, rid, canon)
                        for variant in {pat, pat.lower(), pat.upper(), pat.capitalize()}:
                            for frag in b64_alignments(variant.encode("utf-8")):
                                self.b64[frag] = (klass, rid, canon)
                elif kind == "word":
                    self.words.append((re.compile(r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(normalize(pat))), klass, rid))
                elif kind == "regex":
                    self.regexes.append((re.compile(pat, re.I), klass, rid))
                else:
                    raise Broken("pattern file line %d: kind is term, word or regex" % n)
            except re.error:
                raise Broken("pattern file line %d: regex does not compile" % n)
            operator_rules += 1
        if self.version is None:
            raise Broken("pattern file has no '#! version N' line")
        if min_version is not None and self.version < min_version:
            raise Broken("pattern file is version %d, this repo requires at least %d: sync it" % (self.version, min_version))
        if operator_rules == 0:
            raise Broken("pattern file has zero rules (an empty denylist is not a pass)")
        self.finish()

    def finish(self):
        if self.terms:
            alts = sorted(self.terms, key=len, reverse=True)
            self.term_re = re.compile("|".join(re.escape(t) for t in alts))
        self.b64_re = re.compile("|".join(re.escape(f) for f in sorted(self.b64, key=len, reverse=True))) if self.b64 else None

    def allowed(self, matched_norm):
        return any(a in matched_norm or matched_norm in a for a in self.allow_terms) or any(r.search(matched_norm) for r in self.allow_res)


class Scanner:
    def __init__(self, rules, overrides):
        self.rules = rules
        self.overrides = overrides          # list of (fp, class, path glob)
        self.findings = []                  # (path, line, class, rule, via, fp, severity)
        self.seen = set()
        self.overridden = 0
        self.unscannable = 0
        self.force_via = None
        self.tainted = {}                   # path whose NAME contains a denied value -> label

    def label(self, path):
        return self.tainted.get(path, path)

    def add(self, path, line, klass, rid, via, canonical):
        if self.rules.allowed(canonical):
            return
        via = self.force_via or via
        if via == "path" and not rid.startswith("BP-") and path not in self.tainted:
            # the file name itself carries the value: printing the path would echo it
            ext = path.rsplit(".", 1)[-1] if "." in path.rsplit("/", 1)[-1] else "none"
            self.tainted[path] = "<path-withheld#%d depth=%d ext=%s>" % (len(self.tainted) + 1, path.count("/"), ext)
        fp = fingerprint(klass, canonical)
        key = (path, line, klass, fp)
        if key in self.seen:
            return
        self.seen.add(key)
        for ofp, oklass, oglob in self.overrides:
            if ofp == fp and oklass == klass and fnmatch.fnmatch(path, oglob):
                self.overridden += 1
                return
        self.findings.append((path, line, klass, rid, via, fp, self.rules.severity.get(klass, "block")))

    # one piece of text, every view
    def scan_text(self, path, line, raw, depth=0):
        r = self.rules
        views = [("plain", normalize(raw))]
        if "%" in raw:
            u = unquote(raw)
            if u != raw:
                views.append(("urlenc", normalize(u)))
        for via, text in views:
            if r.term_re:
                for m in r.term_re.finditer(text):
                    klass, rid = r.terms[m.group(0)]
                    self.add(path, line, klass, rid, via, m.group(0))
            for rx, klass, rid in r.words:
                for m in rx.finditer(text):
                    self.add(path, line, klass, rid, via, m.group(0))
        # regexes run on the zero-width-stripped original so case-sensitive key shapes still work
        cleaned = ZERO_WIDTH.sub("", unicodedata.normalize("NFKC", raw))
        for rx, klass, rid in r.regexes:
            for m in rx.finditer(cleaned):
                self.add(path, line, klass, rid, "plain" if depth == 0 else "decoded", normalize(m.group(0)))
        for m in CONFIG_SECRET.finditer(cleaned):
            val = m.group(1)
            if not PLACEHOLDER.search(val) and entropy(val) >= 3.2:
                self.add(path, line, "config-secret", "B-config", "plain" if depth == 0 else "decoded", normalize(val))
        if r.b64_re:
            for m in r.b64_re.finditer(raw):
                klass, rid, canon = r.b64[m.group(0)]
                self.add(path, line, klass, rid, "base64", canon)
        if depth < 2:
            for m in B64_TOKEN.finditer(raw):
                dec = try_b64(m.group(0))
                if dec:
                    self.scan_text(path, line, dec, depth + 1)
            for m in HEX_TOKEN.finditer(raw):
                try:
                    dec = binascii.unhexlify(m.group(0)).decode("utf-8")
                except (ValueError, UnicodeDecodeError):
                    continue
                if printable(dec):
                    self.scan_text(path, line, dec, depth + 1)

    # a run of consecutive added lines: catches "zork" + "mid" + "box" and reversed terms
    def scan_run(self, path, first_line, lines):
        r = self.rules
        if not r.squashed:
            return
        blob = squash(normalize("\n".join(lines)))
        if len(blob) < MIN_EVASION_LEN:
            return
        for sq, (klass, rid, canon) in r.squashed.items():
            if sq in blob:
                self.add(path, first_line, klass, rid, "squashed", canon)
            elif sq[::-1] in blob and sq[::-1] != sq:
                self.add(path, first_line, klass, rid, "reversed", canon)

    def scan_path(self, path):
        for rx, klass, rid in self.rules.path_rules:
            if rx.search(path):
                self.add(path, 0, klass, rid, "path", rid)
        self.force_via = "path"                 # a term inside a file or directory name
        try:
            self.scan_text(path, 0, path)
            self.scan_run(path, 0, [path])
        finally:
            self.force_via = None

    def scan_plain(self, name, text):
        lines = text.splitlines()
        for n, line in enumerate(lines, 1):
            self.scan_text(name, n, line)
        self.scan_run(name, 1, lines)

    def scan_diff(self, text):
        path, new_line, run, run_start = "(unknown)", 0, [], 0

        def flush():
            if run:
                self.scan_run(path, run_start, run)
            del run[:]

        for line in text.splitlines():
            if line.startswith("diff --git "):
                flush()
                continue
            if line.startswith("+++ "):
                flush()
                p = line[4:].strip()
                if p != "/dev/null":
                    path = unquote_git_path(p[2:] if p[:2] in ("a/", "b/") else p)
                    self.scan_path(path)
                continue
            if line.startswith("rename to ") or line.startswith("copy to "):
                self.scan_path(unquote_git_path(line.split(" ", 2)[2]))
                continue
            if line.startswith("Binary files ") or line.startswith("GIT binary patch"):
                self.unscannable += 1
                m = re.search(r" and (?:b/)?(.+?) differ$", line)
                if m and m.group(1) != "/dev/null":
                    self.scan_path(unquote_git_path(m.group(1)))
                continue
            if line.startswith("@@"):
                flush()
                m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", line)
                new_line = int(m.group(1)) if m else 0
                continue
            if line.startswith("+") and not line.startswith("+++"):
                if not run:
                    run_start = new_line
                run.append(line[1:])
                self.scan_text(path, new_line, line[1:])
                new_line += 1
            elif line.startswith("-"):
                flush()
            else:
                flush()
                if new_line:
                    new_line += 1
        flush()


def printable(s):
    return bool(s) and sum(1 for c in s if c.isprintable() or c in "\n\t") / float(len(s)) > 0.9


def try_b64(tok):
    t = tok.rstrip("=")
    for dec in (base64.b64decode, base64.urlsafe_b64decode):
        try:
            out = dec(t + "=" * (-len(t) % 4)).decode("utf-8")
        except (ValueError, UnicodeDecodeError, binascii.Error):
            continue
        if printable(out):
            return out
    return None


def unquote_git_path(p):
    if len(p) >= 2 and p[0] == '"' and p[-1] == '"':          # core.quotePath octal escapes
        try:
            return p[1:-1].encode("latin-1", "replace").decode("unicode_escape").encode("latin-1", "replace").decode("utf-8", "replace")
        except UnicodeError:
            return p[1:-1]
    return p


def load_overrides(path):
    """Public file. Each line: <fp> <class> <path glob> <reason...>. Reason is mandatory."""
    out = []
    if not path:
        return out
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                parts = s.split(None, 3)
                if len(parts) < 4 or not re.match(r"^[0-9a-f]{12}$", parts[0]) or len(parts[3]) < 10:
                    raise Broken("overrides line %d: want '<fp> <class> <path glob> <reason of 10+ chars>'" % n)
                out.append((parts[0], parts[1], parts[2]))
    except OSError:
        pass                                                    # no overrides file = no overrides
    return out


def git(*args):
    try:
        p = subprocess.run(("git", "-c", "core.quotePath=false") + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        raise Broken("cannot run git: %s" % exc.__class__.__name__)
    if p.returncode != 0:
        raise Broken("git %s failed (exit %d)" % (args[0], p.returncode))
    return p.stdout.decode("utf-8", "replace")


def main(argv):
    ap = argparse.ArgumentParser(description="Refuse to publish private or revealing material.", add_help=True)
    ap.add_argument("--patterns", help="operator pattern file (private; outside the public tree)")
    ap.add_argument("--builtin-only", action="store_true",
                    help="generic rules only. For outside contributors with no pattern file. CI never uses this.")
    ap.add_argument("--overrides", help="public overrides file (fingerprints a human accepted)")
    ap.add_argument("--min-version", type=int, help="lowest acceptable '#! version' in the pattern file")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--diff", action="store_true", help="stdin is a unified diff; added lines and paths are scanned")
    mode.add_argument("--text", metavar="NAME", help="stdin is prose (commit message, PR title+body); NAME labels findings")
    mode.add_argument("--git-staged", action="store_true", help="scan the staged diff")
    mode.add_argument("--git-range", metavar="BASE..HEAD", help="scan the range's diff and every commit message in it")
    args = ap.parse_args(argv)

    rules = Rules()
    if args.builtin_only:
        if args.patterns:
            raise Broken("--builtin-only and --patterns are mutually exclusive")
        rules.finish()
    elif not args.patterns:
        raise Broken("no --patterns file given (there is no default and no environment fallback)")
    else:
        rules.load(args.patterns, args.min_version)

    sc = Scanner(rules, load_overrides(args.overrides))
    if args.diff:
        sc.scan_diff(sys.stdin.buffer.read().decode("utf-8", "replace"))
    elif args.text:
        sc.scan_plain(args.text, sys.stdin.buffer.read().decode("utf-8", "replace"))
    elif args.git_staged:
        sc.scan_diff(git("diff", "--cached", "-U0", "--no-color", "--no-ext-diff"))
    else:
        rng = args.git_range
        if ".." not in rng:
            raise Broken("--git-range wants BASE..HEAD")
        base, head = rng.split("..", 1)
        sc.scan_diff(git("diff", "-U0", "--no-color", "--no-ext-diff", "%s...%s" % (base, head)))
        for sha in git("rev-list", "%s..%s" % (base, head)).split():
            sc.scan_plain("commit-message:%s" % sha[:10], git("log", "-1", "--format=%B%n%an <%ae>%n%cn <%ce>", sha))

    blocking = [f for f in sc.findings if f[6] == "block"]
    for path, line, klass, rid, via, fp, sev in sc.findings[:MAX_PRINT]:
        print("%s:%d: %s rule=%s via=%s fp=%s%s" % (sc.label(path), line, klass, rid, via, fp, "" if sev == "block" else " (warn)"))
    if len(sc.findings) > MAX_PRINT:
        print("... %d more findings not shown" % (len(sc.findings) - MAX_PRINT))
    sys.stderr.write("publish-guard: %d blocking, %d warn, %d overridden, %d binary hunks not scanned; patterns=%s v%s\n" % (
        len(blocking), len(sc.findings) - len(blocking), sc.overridden, sc.unscannable, rules.sha, rules.version))
    if blocking:
        sys.stderr.write(
            "publish-guard: BLOCKED. Remove or generalise the flagged text (the value is not shown on purpose).\n"
            "  There is no bypass flag. If a finding is a genuine false positive, a human adds one line to the\n"
            "  public overrides file: '<fp> <class> <path glob> <reason>'. Agents do not write that file.\n")
        return EXIT_FINDINGS
    return EXIT_CLEAN


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Broken as exc:
        sys.stderr.write("publish-guard: CANNOT RUN, failing closed: %s\n" % exc)
        sys.exit(EXIT_BROKEN)
    except SystemExit:
        raise
    except Exception as exc:                                    # never fail open, never print data
        sys.stderr.write("publish-guard: INTERNAL ERROR (%s), failing closed\n" % exc.__class__.__name__)
        sys.exit(EXIT_BROKEN)
