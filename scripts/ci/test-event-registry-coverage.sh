#!/usr/bin/env bash
# test-event-registry-coverage.sh — INFRA-1237 (CREDIBLE)
#
# Audit docs/observability/EVENT_REGISTRY.yaml drift on every PR. Grep the
# production paths for `kind=` emit literals; diff against the registered
# kinds in the YAML.
#
# The existing scripts/git-hooks/pre-commit-event-registry.sh only checks
# the STAGED diff — emit sites that predate INFRA-754 or were committed
# under a hook bypass slip through. This script audits the FULL tree on
# every CI run and fails the build on drift.
#
# Modes (CHUMP_REGISTRY_GATE_MODE):
#   strict-emit (default) — emit-without-register FAILS; orphans warn-only
#   strict              — both directions fail (use after orphan
#                         reconciliation gap lands)
#   report              — print drift counts, never fail (diagnostic)
#
# Allowlist (scripts/ci/event-registry-reserved.txt) — one kind per line,
# optionally with inline `# reason` comment. Comments + blanks ignored.
#
# Bypass: CHUMP_EVENT_REGISTRY_ALLOW_DRIFT=1 — emergency bypass; must
#         include `Event-Registry-Drift-Bypass: <reason>` in commit body.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

REGISTRY="docs/observability/EVENT_REGISTRY.yaml"
ALLOWLIST="scripts/ci/event-registry-reserved.txt"
MODE="${CHUMP_REGISTRY_GATE_MODE:-strict-emit}"

if [[ ! -f "$REGISTRY" ]]; then
    echo "[event-registry-audit] FAIL: $REGISTRY missing" >&2
    exit 3
fi

# Optional allowlist — empty file is fine for first-run.
[[ -f "$ALLOWLIST" ]] || ALLOWLIST=/dev/null

# Bypass (emergency).
if [[ "${CHUMP_EVENT_REGISTRY_ALLOW_DRIFT:-0}" == "1" ]]; then
    echo "[event-registry-audit] WARN: bypass via CHUMP_EVENT_REGISTRY_ALLOW_DRIFT=1"
    echo "[event-registry-audit]   Commit body must include 'Event-Registry-Drift-Bypass: <reason>'"
    exit 0
fi

exec python3 - "$REGISTRY" "$ALLOWLIST" "$MODE" <<'PYEOF'
import re, subprocess, sys, pathlib

registry_path, allowlist_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
yaml_text = pathlib.Path(registry_path).read_text()

# Registered kinds: each appears as `^  - kind: <name>`.
registered = set(re.findall(r'^\s*-\s+kind:\s*([A-Za-z0-9_]+)', yaml_text, re.M))

# INFRA-1982: Deprecated kinds — entries with `deprecated: true` are excluded
# from orphan checks (register-without-emit) since they are intentionally no
# longer emitted. They remain in registered so emit-without-register doesn't
# complain if old log replays reference them.
_deprecated_blocks = re.findall(
    r'-\s+kind:\s*([A-Za-z0-9_]+)(?:.(?!-\s+kind:))*?deprecated:\s*true',
    yaml_text, re.S
)
deprecated_kinds = set(_deprecated_blocks)

# Production paths. Excludes scripts/ab-harness/, scripts/ci/,
# scripts/git-hooks/, scripts/auto-docs/, etc. — those legitimately mention
# `"kind":"X"` as test fixtures, doc examples, or hook bypass templates.
# INFRA-1287: extended to include scripts/dev/ and scripts/setup/ which
# contain real emit sites (e.g. ambient-watch.sh emits lease_overlap/edit_burst,
# install-chump-fleet-daemon.sh emits daemon_tick via daemon orchestration).
PROD_PATHS = [
    'src/', 'crates/',
    'scripts/coord/', 'scripts/dispatch/', 'scripts/ops/',
    'scripts/dev/', 'scripts/setup/',
    # INFRA-1695 / META-066: Content Bots Suite dispatcher + orchestrator
    # emit content_bot_invoked / content_bot_output / content_bot_pipeline_step
    # from scripts/content-bots/. Same production-emit semantics as the
    # other scripts/ paths above.
    'scripts/content-bots/',
    # INFRA-1823: scripts/arsenal/build.py emits kind=arsenal_rebuilt on
    # every Harvester catalog rebuild (scheduled or via `chump harvest scan`).
    'scripts/arsenal/',
    # RESILIENT-331: scripts/chairman/chairman_pulse.py emits
    # chairman_pulse_tick / organ_zombie_alive to ambient.jsonl.
    'scripts/chairman/',
    # INFRA-7880: scripts/publish-guard/report_only.py emits
    # publish_guard_report (class counts only) from the hook and ship call sites.
    'scripts/publish-guard/',
]
# Also skip per-file patterns that may live inside PROD_PATHS but are tests
# or fixtures (e.g. `src/foo/tests/bar.rs`).
SKIP_PATTERNS = ('/tests/', '/test_', '_test.rs', '/fixtures/')

# INFRA-3583: SKIP_PATTERNS only catches tests that live in their own file
# (path-based). It misses the far more common Rust idiom — an inline
# `#[cfg(test)] mod tests { ... }` block inside an ordinary src/ or crates/
# file. A test fixture string like `"kind":"other_event"` inside that block
# reads as a real emit site to the grep-based scanner, flagging a false
# EMIT-NO-REG every time a PR's test fixture happens to pick an unregistered
# kind name (see CREDIBLE-257 / PR #3583 — the same class fired on
# `other_event` and, in principle, could fire on any never-registered
# fixture string). Rather than reactively renaming fixtures PR by PR,
# precompute the line ranges of inline `#[cfg(test)]` module blocks per
# Rust file and skip any grep hit that falls inside one — the same "this is
# test code" judgment SKIP_PATTERNS already makes for whole files, just
# applied at block granularity via brace-depth tracking (best-effort; does
# not attempt full Rust parsing, e.g. braces inside string/char literals
# are not specially handled).
_TEST_MOD_RANGE_CACHE = {}

def _rust_test_mod_ranges(path):
    if path in _TEST_MOD_RANGE_CACHE:
        return _TEST_MOD_RANGE_CACHE[path]
    ranges = []
    if path.endswith('.rs'):
        try:
            src_lines = pathlib.Path(path).read_text(errors='replace').splitlines()
        except OSError:
            src_lines = []
        n = len(src_lines)
        i = 0
        while i < n:
            if re.match(r'^\s*#\[cfg\(test\)\]\s*$', src_lines[i]):
                j = i + 1
                while j < n and src_lines[j].strip() == '':
                    j += 1
                if j < n and re.search(r'\bmod\s+\w+\s*\{', src_lines[j]):
                    depth = 0
                    started = False
                    k = j
                    while k < n:
                        depth += src_lines[k].count('{') - src_lines[k].count('}')
                        if '{' in src_lines[k]:
                            started = True
                        if started and depth <= 0:
                            break
                        k += 1
                    # 1-indexed inclusive line range covering the whole block.
                    ranges.append((i + 1, k + 1))
                    i = k + 1
                    continue
            i += 1
    _TEST_MOD_RANGE_CACHE[path] = ranges
    return ranges

def _in_rust_test_mod(path, lineno):
    for start, end in _rust_test_mod_ranges(path):
        if start <= lineno <= end:
            return True
    return False

def grep_lines(pattern, paths):
    """Run grep -rEnI, return list of `path:lineno:content` strings."""
    existing = [p for p in paths if pathlib.Path(p).exists()]
    if not existing:
        return []
    proc = subprocess.run(
        ['grep', '-rEnI', pattern, *existing],
        capture_output=True, text=True
    )
    # rc 1 == no matches (OK); rc 2+ == real error
    if proc.returncode > 1:
        return []
    return [ln for ln in proc.stdout.splitlines() if ln]

def extract_kinds(lines, kind_re):
    """From grep output lines, return set of kinds (skipping fixture paths)."""
    out = set()
    for line in lines:
        parts = line.split(':', 2)
        if len(parts) < 3:
            continue
        path, lineno_s = parts[0], parts[1]
        if any(p in path for p in SKIP_PATTERNS):
            continue
        if lineno_s.isdigit() and _in_rust_test_mod(path, int(lineno_s)):
            continue
        m = re.search(kind_re, parts[2])
        if m:
            out.add(m.group(1))
    return out

# Pattern 1: "kind":"<name>" — JSON literals (serde::json! macro,
# shell heredocs, etc.). Search ALL production paths.
emitted = extract_kinds(
    grep_lines(r'"kind"\s*:\s*"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'"kind"\s*:\s*"([a-zA-Z0-9_]+)"',
)
# Pattern 2: kind = "<name>" — Rust struct-init form. Only in src/, crates/.
emitted |= extract_kinds(
    grep_lines(r'kind\s*=\s*"[a-zA-Z0-9_]+"', ['src/', 'crates/']),
    r'kind\s*=\s*"([a-zA-Z0-9_]+)"',
)
# Pattern 3: Rust format-string escaped-quote form: \"kind\":\"fleet_scale_change\"
# Common in format! / write! macros where the JSON is built inline.
# INFRA-1287: adds ~33 new emit sites (daemon_tick, fleet_scale_change, etc.)
emitted |= extract_kinds(
    grep_lines(r'\\"kind\\":\\"[a-zA-Z0-9_]+\\"', ['src/', 'crates/']),
    r'\\"kind\\":\\"([a-zA-Z0-9_]+)\\"',
)
# Pattern 4: Shell _emit "kind_name" — function-mediated emits.
# fleet-wedge-handler.sh, active-target-reaper.sh, etc.
# INFRA-1287: adds ~13 new emit sites.
emitted |= extract_kinds(
    grep_lines(r'_emit\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'_emit\s+"([a-zA-Z0-9_]+)"',
)
# Pattern 5a: emit_alert "kind_name" — ambient-watch.sh.
# INFRA-1287: catches lease_overlap, edit_burst, silent_agent from scripts/dev/.
emitted |= extract_kinds(
    grep_lines(r'emit_alert\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'emit_alert\s+"([a-zA-Z0-9_]+)"',
)
# Pattern 5b: emit_ambient "kind_name" — disk-health-monitor.sh, auto-merge-armer.sh,
# scripts/coord/pr-rescue.sh, and many scripts/ops/ scripts.
# grep -E doesn't support lookbehind, so filter out `_emit_ambient` lines
# in extract_kinds instead of the grep pattern.
# `_emit_ambient` in free-tier-e2e-test.sh takes status codes ("pass","fail"),
# not event kinds — skip those lines.
def extract_kinds_no_prefix_emit(lines, kind_re):
    """Like extract_kinds but skip lines containing _emit_ambient."""
    out = set()
    for line in lines:
        parts = line.split(':', 2)
        if len(parts) < 3:
            continue
        path, lineno_s = parts[0], parts[1]
        if any(p in path for p in SKIP_PATTERNS):
            continue
        if lineno_s.isdigit() and _in_rust_test_mod(path, int(lineno_s)):
            continue
        content = parts[2]
        if '_emit_ambient' in content:
            continue
        m = re.search(kind_re, content)
        if m:
            out.add(m.group(1))
    return out

emitted |= extract_kinds_no_prefix_emit(
    grep_lines(r'emit_ambient\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'emit_ambient\s+"([a-zA-Z0-9_]+)"',
)

# Pattern 5c: emit_event "kind_name" — Content Bots Suite dispatcher +
# orchestrator (INFRA-1695, INFRA-1698) use this shell-function form.
emitted |= extract_kinds_no_prefix_emit(
    grep_lines(r'emit_event\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'emit_event\s+"([a-zA-Z0-9_]+)"',
)

# Pattern 6: known alert_kind= variable assignments.
# Narrowly scoped to `alert_kind=` (reaper-heartbeat-watchdog.sh, watchdogs).
# Avoids the noise from broader `*kind*=` patterns that catch internal state
# variables like _cooldown_kind="wedge" which are NOT event kinds.
emitted |= extract_kinds(
    grep_lines(r'alert_kind\s*=\s*"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'alert_kind\s*=\s*"([a-zA-Z0-9_]+)"',
)
# Pattern 7: emit_reaper_event "kind_name" — reaper observability helper.
# Used in scripts/ops/active-target-reaper.sh, scripts/ops/stale-worktree-reaper.sh,
# scripts/coord/worktree-prune.sh. First quoted argument is the kind name.
# INFRA-1287: catches worktree_reap_protected, worktree_reaper_skipped_active, etc.
emitted |= extract_kinds(
    grep_lines(r'emit_reaper_event\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'emit_reaper_event\s+"([a-zA-Z0-9_]+)"',
)
# Pattern 8: EMIT_KIND "kind_name" — uppercase shell helper variant.
# INFRA-1659: conflict-resolver-agent (INFRA-1488) originally shipped with this
# uppercase helper; scanner missed all 8 of its kinds until the helper was
# renamed to _emit. Accepting both casings is more permissive than enforcing
# a naming convention by silent failure.
emitted |= extract_kinds(
    grep_lines(r'EMIT_KIND\s+"[a-zA-Z0-9_]+"', PROD_PATHS),
    r'EMIT_KIND\s+"([a-zA-Z0-9_]+)"',
)

# Allowlist — kinds exempt from BOTH directions.
allowlist = set()
try:
    with open(allowlist_path) as f:
        for ln in f:
            s = ln.strip()
            if not s or s.startswith('#'):
                continue
            k = s.split('#', 1)[0].strip()
            if k:
                allowlist.add(k)
except FileNotFoundError:
    pass

# Drop obvious noise (placeholders inadvertently caught by the regex).
# 'test' is emitted in #[cfg(test)] blocks in src/ (e.g. ambient_rotate.rs)
# which are stripped in production builds — not a real event kind.
NOISE = {'X', 'kind', 'name', 'value', 'type', 'event', 'other', 'test'}
emitted -= NOISE

emit_without_register = sorted((emitted - registered) - allowlist)
# INFRA-1982: exclude deprecated kinds from orphan check — they are intentionally
# no longer emitted but are kept in the registry for historical query compatibility.
register_without_emit = sorted(((registered - emitted) - allowlist) - deprecated_kinds)

# ── INFRA-1371: effect_metric check ──────────────────────────────────────────
# Parse which registered kinds have an effect_metric declaration.
# A kind entry looks like:
#   - kind: session_start
#     effect_metric: self
# We build a dict: kind_name → True/False (has effect_metric on next line).
lines = yaml_text.splitlines()
kinds_missing_effect_metric = []
i = 0
while i < len(lines):
    line = lines[i]
    m = re.match(r'^\s*-\s+kind:\s*([A-Za-z0-9_]+)', line)
    if m:
        kind_name = m.group(1)
        # Check if any of the next few lines (before next '  - kind:') has effect_metric
        has_em = False
        j = i + 1
        while j < len(lines) and not re.match(r'^\s*-\s+kind:', lines[j]):
            if re.match(r'^\s+effect_metric:\s*\S', lines[j]):
                has_em = True
                break
            j += 1
        if not has_em and kind_name not in allowlist:
            # Only flag kinds that are emitted in code (new-kind check)
            if kind_name in emitted:
                kinds_missing_effect_metric.append(kind_name)
    i += 1

# ── CREDIBLE-275: consumer verification + emitter/trigger drift ────────────
# The gate above only ever says the word "emitter" — it never checks whether
# a declared consumer actually reads the kind it claims to watch, and it
# never checks whether the declared emitter path/function even exists. Both
# gaps let EVENT_REGISTRY.yaml's gap_flipped_done_on_merge entry lie for
# months: three phantom consumers (fleet-brief, ops-audit, waste-tally, none
# of which reference the kind) and an emitter function name
# (_auto_flip_merged_gaps) that was never the real function
# (_auto_flip_gaps_done) — see CREDIBLE-268 for what that hid.
#
# Per-kind consumers + emitter, reusing the same '- kind:' block boundaries
# as the effect_metric scan above.
kind_consumers = {}
kind_emitter = {}
i = 0
while i < len(lines):
    m = re.match(r'^\s*-\s+kind:\s*([A-Za-z0-9_]+)', lines[i])
    if m:
        kind_name = m.group(1)
        j = i + 1
        while j < len(lines) and not re.match(r'^\s*-\s+kind:', lines[j]):
            cm = re.match(r'^\s+consumers:\s*\[(.*)\]\s*$', lines[j])
            if cm:
                kind_consumers[kind_name] = cm.group(1)
            em = re.match(r'^\s+emitter:\s*(\S.*)$', lines[j])
            if em:
                kind_emitter[kind_name] = em.group(1).strip()
            j += 1
    i += 1


def _split_consumers(raw):
    """Split a `consumers: [...]` inner string on top-level commas only —
    entries may contain their own parenthesized commas, e.g.
    'dashboard (future, INFRA-1883)'."""
    parts, buf, depth = [], "", 0
    for ch in raw:
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth = max(0, depth - 1)
        if ch == "," and depth == 0:
            parts.append(buf.strip())
            buf = ""
        else:
            buf += ch
    if buf.strip():
        parts.append(buf.strip())
    return [p for p in parts if p]


_CONSUMER_STOPWORDS = {
    "future", "chump", "dashboard", "panel", "adapter", "messaging",
    "operator", "audit", "findings", "view", "watch", "watchdog",
    "web", "cockpit", "report", "wired", "escalation", "sink",
}


def _consumer_tokens(name):
    base = re.sub(r'\([^)]*\)', '', name)
    base = re.sub(r'<[^>]*>', '', base)
    toks = re.findall(r'[a-zA-Z0-9]+', base.lower())
    return [t for t in toks if len(t) >= 4 and t not in _CONSUMER_STOPWORDS]


_repo_files_cache = None


def _repo_files():
    global _repo_files_cache
    if _repo_files_cache is None:
        proc = subprocess.run(['git', 'ls-files'], capture_output=True, text=True)
        _repo_files_cache = [
            f for f in proc.stdout.splitlines()
            if f and not f.startswith('docs/') and 'node_modules' not in f
        ]
    return _repo_files_cache


_file_content_cache = {}


def _read_cached(path):
    if path not in _file_content_cache:
        try:
            _file_content_cache[path] = pathlib.Path(path).read_text(errors='replace')
        except OSError:
            _file_content_cache[path] = ""
    return _file_content_cache[path]


def _emitter_path(emitter_raw):
    """First whitespace-separated token that looks like a repo-relative path."""
    for tok in emitter_raw.split():
        tok = tok.strip('()')
        if '/' in tok and not tok.startswith('('):
            return tok
    return None


def _consumer_verified(kind_name, consumers_raw, emitter_file):
    for cname in _split_consumers(consumers_raw):
        toks = _consumer_tokens(cname)
        if not toks:
            continue
        candidates = [f for f in _repo_files()
                      if any(t in f.lower() for t in toks) and f != emitter_file]
        for f in candidates:
            if kind_name in _read_cached(f):
                return True, cname, f
    return False, None, None


unverified_consumer_kinds = []
missing_emitter_kinds = []
for kind_name, consumers_raw in kind_consumers.items():
    if not consumers_raw.strip():
        continue
    emitter_raw = kind_emitter.get(kind_name, "")
    emitter_file = _emitter_path(emitter_raw)
    if emitter_file and not pathlib.Path(emitter_file).is_file():
        missing_emitter_kinds.append((kind_name, emitter_file))
    verified, _, _ = _consumer_verified(kind_name, consumers_raw, emitter_file)
    if not verified:
        unverified_consumer_kinds.append(kind_name)

# Ratchet: only these specific kinds FAIL the build on unverified consumers.
# Everything else is reported (see AC2's "large first-run backlog"), not
# enforced — the backlog is real fleet-wide debt, not something one gap
# should mass-fix. Add a kind here only once you've actually wired a real
# consumer for it (see gap_flipped_done_on_merge / CREDIBLE-275 for the
# pattern: scripts/coord/lib/notify-operator.sh via CHUMP_NOTIFY_KIND).
required_consumer_kinds = set()
required_path = pathlib.Path('scripts/ci/event-registry-consumer-required.txt')
if required_path.is_file():
    for ln in required_path.read_text().splitlines():
        s = ln.split('#', 1)[0].strip()
        if s:
            required_consumer_kinds.add(s)
required_consumer_failures = sorted(
    k for k in required_consumer_kinds if k in unverified_consumer_kinds
)

# ── Report ──
print(f"[event-registry-audit] mode={mode}")
print(f"[event-registry-audit] registered={len(registered)} "
      f"emitted={len(emitted)} allowlisted={len(allowlist)}")
print(f"[event-registry-audit] emitted-missing-effect_metric: {len(kinds_missing_effect_metric)}")
for k in sorted(kinds_missing_effect_metric):
    print(f"  MISSING-EFFECT-METRIC: {k}")
print(f"[event-registry-audit] emit-without-register: {len(emit_without_register)}")
for k in emit_without_register:
    print(f"  EMIT-NO-REG: {k}")
print(f"[event-registry-audit] register-without-emit (orphans): "
      f"{len(register_without_emit)}")
# INFRA-1287: always print the full orphan list in report mode (grouped alpha).
# In non-report modes, print first 5 + count for CI log brevity.
if register_without_emit:
    if mode == 'report':
        for k in register_without_emit:
            print(f"  ORPHAN: {k}")
    else:
        head = register_without_emit[:5]
        for k in head:
            print(f"  ORPHAN: {k}")
        if len(register_without_emit) > 5:
            print(f"  ... +{len(register_without_emit)-5} more "
                  f"(run with CHUMP_REGISTRY_GATE_MODE=report for full list)")

# CREDIBLE-275: the size of this count IS the write-only-telemetry finding —
# see AC2. Reported every run regardless of mode; not gated on 'report'.
print(f"[event-registry-audit] missing-emitter-file: {len(missing_emitter_kinds)}")
for k, f in missing_emitter_kinds[:5]:
    print(f"  MISSING-EMITTER: {k} -> {f}")
if len(missing_emitter_kinds) > 5:
    print(f"  ... +{len(missing_emitter_kinds)-5} more")
print(f"[event-registry-audit] unverified-consumers (declared, none reference "
      f"the kind): {len(unverified_consumer_kinds)}")
if mode == 'report':
    for k in sorted(unverified_consumer_kinds):
        print(f"  UNVERIFIED-CONSUMER: {k}")
if required_consumer_failures:
    print(f"[event-registry-audit] REQUIRED consumer verification FAILED for: "
          f"{', '.join(required_consumer_failures)}")

# ── Exit policy ──
if mode == 'report':
    sys.exit(0)
if emit_without_register:
    print("[event-registry-audit] FAIL: emit-without-register violations — "
          "register each kind in docs/observability/EVENT_REGISTRY.yaml or "
          "add to scripts/ci/event-registry-reserved.txt with a reason.",
          file=sys.stderr)
    sys.exit(1)
if mode == 'strict' and register_without_emit:
    print("[event-registry-audit] FAIL: register-without-emit violations — "
          "implement each kind or remove from registry. (Default mode "
          "'strict-emit' only warns on orphans; set CHUMP_REGISTRY_GATE_MODE=strict "
          "to fail on this too.)",
          file=sys.stderr)
    sys.exit(2)
# INFRA-1371: emitted kinds without effect_metric fail in strict-emit mode too.
if kinds_missing_effect_metric:
    print("[event-registry-audit] FAIL: emitted kinds missing effect_metric — "
          "add 'effect_metric: self' (or a specific metric name) to each entry "
          "in docs/observability/EVENT_REGISTRY.yaml. See docs/observability/"
          "EVENT_REGISTRY_FORMAT.md for guidance.",
          file=sys.stderr)
    sys.exit(3)
# CREDIBLE-275: kinds in scripts/ci/event-registry-consumer-required.txt must
# have at least one declared consumer that actually references the kind.
# Ratchet, not a blanket requirement — see the comment at required_path above.
if required_consumer_failures:
    print("[event-registry-audit] FAIL: required-consumer verification — "
          "these kinds are in scripts/ci/event-registry-consumer-required.txt "
          "but none of their declared consumers reference the kind in code. "
          "Wire a real consumer (see gap_flipped_done_on_merge / CREDIBLE-275) "
          "or remove the kind from the required-consumer list.",
          file=sys.stderr)
    sys.exit(4)
print("[event-registry-audit] OK")
sys.exit(0)
PYEOF
