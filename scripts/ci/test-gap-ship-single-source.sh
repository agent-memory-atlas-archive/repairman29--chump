#!/usr/bin/env bash
# test-gap-ship-single-source.sh — CREDIBLE-1499, rewritten for PHASE-R R1 (CREDIBLE-1491)
#
# Invariant: exactly ONE function in the workspace writes gaps.status to
# 'done' or 'shipped': GapStore::finalize_status_done in
# crates/chump-gap-store/src/lib.rs. Every other closer (ship, gap set,
# decomposed auto-close, YAML backfill, sync_pull, canonical-peer reconcile,
# gap-doctor.py) calls it, directly or through `chump gap ship`.
#
# No line-range allowlist. The scanner classifies code structurally:
#   * Rust: a lexer (strings, raw strings, chars, nested comments) tracks the
#     brace frame of every `fn` and every item under #[test] / #[cfg(test)] /
#     #[cfg(any(test, ...))]. A writer inside a test item is test code. A
#     production writer is allowed only when its enclosing fn is
#     finalize_status_done in crates/chump-gap-store/src/lib.rs.
#   * Shell / Python under scripts/: any writer is a stray, except under
#     scripts/ci/ (CI fixtures seed their own throwaway databases).
#   * Paths under a tests/ directory and files named tests.rs are test code.
#
# Writer patterns: SQL `status = 'done'|'shipped'` outside a WHERE/AND/OR/
# CASE comparison (shell/Python comment lines skipped), and, inside the store
# crate, Rust `.status = "done"|"shipped"` row assignment (a GapRow that
# upsert_gap would persist; elsewhere that is a view model).
# Known blind spot: a status bound as a SQL parameter (`SET status=?1` with
# "done" in params!). The single writer itself uses literals, so a second
# parameterised writer is the remaining hole; noted on CREDIBLE-1491.
#
# Self-test first: a synthetic tree with the one writer passes, a synthetic
# tree with a second writer (Rust, shell, Python) fails, a writer inside a
# #[cfg(test)] mod passes, and braces inside strings do not confuse scope.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCANNER="$(mktemp -t single-done-writer-XXXXXX).py"
FIX="$(mktemp -d -t single-done-writer-fix-XXXXXX)"
trap 'rm -rf "$SCANNER" "$FIX"' EXIT

cat > "$SCANNER" <<'PY'
import os, re, sys

ROOT = sys.argv[1]
ALLOWED = ("crates/chump-gap-store/src/lib.rs", "finalize_status_done")

SQL_RE = re.compile(r"status\s*=\s*'(done|shipped)'", re.I)
RUST_ASSIGN_RE = re.compile(r"\.status\s*(?<![=!<>])=(?!=)\s*\"(done|shipped)\"")
COMPARE_CTX = re.compile(r"\b(WHERE|AND|OR|WHEN|CASE|NOT|IN|IF|HAVING|ON)\b[^,;]*$", re.I)


def is_writer_match(line_prefix):
    # A SQL match is a comparison when, on the same line, the nearest clause
    # keyword before it is a predicate keyword (WHERE/AND/...), not SET.
    tail = line_prefix
    set_pos = max(tail.upper().rfind(" SET "), tail.upper().rfind("SET "))
    pred = COMPARE_CTX.search(tail)
    if pred and pred.start() > set_pos:
        return False
    return True


def lex_contexts(text, offsets):
    """Return {offset: (in_test, fn_name)} for each offset (sorted)."""
    out = {}
    targets = sorted(set(offsets))
    ti = 0
    stack = []  # frames: (is_test, fn_name)
    pending_test = False
    pending_fn = None
    i, n = 0, len(text)

    def ctx():
        t = any(f[0] for f in stack)
        fn = None
        for f in reversed(stack):
            if f[1]:
                fn = f[1]
                break
        return (t, fn)

    while i < n:
        while ti < len(targets) and targets[ti] <= i:
            out[targets[ti]] = ctx()
            ti += 1
        c = text[i]
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if two == "/*":
            depth, i = 1, i + 2
            while i < n and depth:
                if text[i:i + 2] == "/*":
                    depth, i = depth + 1, i + 2
                elif text[i:i + 2] == "*/":
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            continue
        m = re.match(r'b?r(#*)"', text[i:i + 12])
        if m and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            close = '"' + m.group(1)
            j = text.find(close, i + m.end())
            j = n if j < 0 else j + len(close)
            while ti < len(targets) and targets[ti] < j:
                out[targets[ti]] = ctx()
                ti += 1
            i = j
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j += 1
            while ti < len(targets) and targets[ti] < j:
                out[targets[ti]] = ctx()
                ti += 1
            i = j
            continue
        if c == "'":
            m = re.match(r"'(\\.[^']*|[^\\'])'", text[i:i + 12])
            if m:
                i += m.end()
                continue
            i += 1
            continue
        if two == "#[" or text[i:i + 3] == "#![":
            j = text.find("[", i)
            depth, k = 0, j
            while k < n:
                if text[k] == "[":
                    depth += 1
                elif text[k] == "]":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            attr = re.sub(r"\s+", "", text[j + 1:k])
            if attr == "test" or attr.startswith("cfg(test") or attr.startswith("cfg(any(test"):
                pending_test = True
            i = k + 1
            continue
        if c.isalpha() or c == "_":
            m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[i:])
            word = m.group(0)
            if word == "fn":
                m2 = re.match(r"fn\s+([A-Za-z_][A-Za-z0-9_]*)", text[i:])
                if m2:
                    pending_fn = m2.group(1)
            i += len(word)
            continue
        if c == "{":
            stack.append((pending_test, pending_fn))
            pending_test, pending_fn = False, None
        elif c == "}":
            if stack:
                stack.pop()
        elif c == ";":
            pending_test, pending_fn = False, None
        i += 1
    while ti < len(targets):
        out[targets[ti]] = ctx()
        ti += 1
    return out


def scan_file(rel, path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    hits = []
    line_starts = [0]
    for idx, ch in enumerate(text):
        if ch == "\n":
            line_starts.append(idx + 1)
    import bisect
    cands = []
    # Row-struct assignment only means a persisted write inside the store
    # crate (GapRow -> upsert_gap); elsewhere `.status = "shipped"` is a
    # view model (roadmap rendering), not gaps.status.
    assign = rel.endswith(".rs") and rel.startswith("crates/chump-gap-store/")
    for rx in (SQL_RE,) + ((RUST_ASSIGN_RE,) if assign else ()):
        for m in rx.finditer(text):
            ln = bisect.bisect_right(line_starts, m.start()) - 1
            prefix = text[line_starts[ln]:m.start()]
            if rx is SQL_RE and not is_writer_match(prefix):
                continue
            if not rel.endswith(".rs") and prefix.lstrip().startswith("#"):
                continue  # shell / Python comment line
            cands.append((m.start(), ln + 1))
    if not cands:
        return []
    if rel.endswith(".rs"):
        ctxs = lex_contexts(text, [o for o, _ in cands])
        for off, ln in cands:
            in_test, fn = ctxs[off]
            if in_test:
                continue
            hits.append((rel, ln, fn or "<module>"))
    else:
        for off, ln in cands:
            hits.append((rel, ln, "<script>"))
    return hits


def is_test_path(rel):
    parts = rel.split("/")
    if "tests" in parts[:-1] or parts[-1] == "tests.rs":
        return True
    if rel.startswith("scripts/ci/"):
        return True
    return False


writers = []
for top, exts in (("crates", (".rs",)), ("src", (".rs",)), ("scripts", (".sh", ".py"))):
    base = os.path.join(ROOT, top)
    for dp, dns, fns in os.walk(base):
        dns[:] = [d for d in dns if d not in ("target", ".git", "node_modules")]
        for f in fns:
            if not f.endswith(exts):
                continue
            path = os.path.join(dp, f)
            rel = os.path.relpath(path, ROOT)
            if is_test_path(rel):
                continue
            writers.extend(scan_file(rel, path))

fns = sorted({(r, fn) for r, _, fn in writers})
for r, ln, fn in writers:
    tag = "ALLOWED" if (r, fn) == ALLOWED else "STRAY  "
    print(f"  {tag} {r}:{ln} fn={fn}")
strays = [w for w in fns if w != ALLOWED]
if strays:
    print(f"FAIL: {len(strays)} done/shipped writer function(s) besides {ALLOWED[0]}::{ALLOWED[1]}")
    sys.exit(1)
if ALLOWED not in fns:
    print(f"FAIL: the single writer {ALLOWED[0]}::{ALLOWED[1]} was not found (scanner blind or writer moved)")
    sys.exit(2)
print(f"OK: exactly one done/shipped writer: {ALLOWED[0]}::{ALLOWED[1]}")
PY

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
ko() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

PY=python3
command -v "$PY" >/dev/null 2>&1 || { echo "FAIL: python3 required"; exit 1; }

echo "=== PHASE-R R1: single status=done writer (CREDIBLE-1499 / CREDIBLE-1491) ==="

# ── self-test fixtures ──────────────────────────────────────────────────────
mk_good() {
    local d="$1"
    mkdir -p "$d/crates/chump-gap-store/src" "$d/src" "$d/scripts/coord" "$d/scripts/ci"
    cat > "$d/crates/chump-gap-store/src/lib.rs" <<'RS'
impl GapStore {
    fn finalize_status_done(&self, id: &str) -> Result<bool> {
        let line = format!("{{\"kind\":\"x\"}}\n");
        self.conn.execute("UPDATE gaps SET status='done', closed_at=?1 WHERE id=?2 AND status NOT IN ('done')", params![1, id])?;
        Ok(true)
    }
    fn reader(&self) { let _ = "SELECT id FROM gaps WHERE status='done'"; }
}
#[cfg(test)]
mod tests {
    #[test]
    fn seeds() { conn.execute("UPDATE gaps SET status='done' WHERE id=?1", []).unwrap(); }
}
RS
    # shellcheck disable=SC2016  # literal fixture text
    echo 'sqlite3 "$db" "SELECT COUNT(*) FROM gaps WHERE status='"'"'done'"'"'"' > "$d/scripts/coord/reader.sh"
    # shellcheck disable=SC2016  # literal fixture text
    echo 'sqlite3 "$db" "UPDATE gaps SET status='"'"'done'"'"' WHERE id=1"' > "$d/scripts/ci/test-fixture.sh"
}

mk_good "$FIX/good"
if out=$("$PY" "$SCANNER" "$FIX/good" 2>&1); then
    ok "self-test: one writer + test-mod seed + CI fixture + readers passes"
else
    ko "self-test: good tree should pass: $out"
fi

mk_good "$FIX/rust2"
cat >> "$FIX/rust2/src/closer.rs" <<'RS'
pub fn sneaky_close(conn: &Connection, id: &str) {
    let _ = "{ not a brace frame }";
    conn.execute("UPDATE gaps SET status='done' WHERE id=?1", [id]).unwrap();
}
RS
if out=$("$PY" "$SCANNER" "$FIX/rust2" 2>&1); then
    ko "self-test: a second Rust writer must fail: $out"
else
    case "$out" in *"src/closer.rs"*"sneaky_close"*) ok "self-test: second Rust writer fails and is named" ;;
        *) ko "self-test: second Rust writer failed but not named: $out" ;; esac
fi

mk_good "$FIX/sh2"
# shellcheck disable=SC2016  # literal fixture text
echo 'sqlite3 "$db" "UPDATE gaps SET status='"'"'shipped'"'"' WHERE id='"'"'X'"'"'"' > "$FIX/sh2/scripts/coord/closer.sh"
if out=$("$PY" "$SCANNER" "$FIX/sh2" 2>&1); then
    ko "self-test: a shell writer must fail: $out"
else
    ok "self-test: shell writer of 'shipped' fails"
fi

mk_good "$FIX/py2"
printf 'cur.execute(\n    "UPDATE gaps SET status=%sdone%s, closed_at=? "\n    "WHERE id=?", (1, gid))\n' "'" "'" > "$FIX/py2/scripts/coord/closer.py"
if out=$("$PY" "$SCANNER" "$FIX/py2" 2>&1); then
    ko "self-test: a Python writer must fail: $out"
else
    ok "self-test: Python writer fails"
fi

mk_good "$FIX/assign"
cat >> "$FIX/assign/crates/chump-gap-store/src/row.rs" <<'RS'
fn flip(row: &mut GapRow) { if row.status == "done" { return; } row.status = "done".to_string(); }
RS
if out=$("$PY" "$SCANNER" "$FIX/assign" 2>&1); then
    ko "self-test: a Rust row.status = \"done\" assignment must fail: $out"
else
    ok "self-test: Rust .status = \"done\" assignment fails (== comparison does not)"
fi

mk_good "$FIX/none"
sed -i.bak "s/status='done', closed_at/closed_at/" "$FIX/none/crates/chump-gap-store/src/lib.rs"
if out=$("$PY" "$SCANNER" "$FIX/none" 2>&1); then
    ko "self-test: a tree with no writer must fail (blind scanner): $out"
else
    ok "self-test: missing single writer fails"
fi

# ── the real tree ───────────────────────────────────────────────────────────
echo
echo "Scanning $REPO_ROOT (crates/ src/ scripts/) ..."
if out=$("$PY" "$SCANNER" "$REPO_ROOT" 2>&1); then
    echo "$out"
    ok "real tree: exactly one status=done/shipped writer"
else
    echo "$out"
    ko "real tree: single-writer invariant violated"
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
