#!/usr/bin/env bash
# merge-driver-union.sh — INFRA-8223
#
# Replacement for the INFRA-1419 `union` driver, whose registered command was
#
#   git merge-file -p -L LEFT -L BASE -L RIGHT %A %O %B > %A
#
# That command is broken twice over:
#   1. `> %A` makes the shell truncate %A (our side) BEFORE git merge-file
#      reads it, so "ours" is always empty. Every append-only file then looks
#      like "we deleted the whole file, they edited it" and comes out wrapped
#      whole-file in LEFT/RIGHT conflict markers with our side missing.
#   2. Even without the truncation, `-p` without `--union` writes conflict
#      markers rather than the union the driver name promises.
# (Receipts: PRs #5536, #5529, #5527 on 2026-10-17; each agent rebuilt
# docs/observability/EVENT_REGISTRY.yaml or scripts/ci/env-vars-internal.txt
# from origin/main by hand.)
#
# This driver copies %O %A %B to private temp files before writing anything,
# builds the result in a temp file next to %A, and `mv`s it into place.
#
# Modes (chosen by the path git passes as %P):
#   *EVENT_REGISTRY.yaml  list-item aware: the file is split into `  - kind:`
#                         blocks and merged per block, so a block is never
#                         split. Order: ours, then theirs-only blocks. A kind
#                         edited differently on both sides is a real conflict.
#   anything else         `git merge-file --union` (keep both sides of every
#                         hunk), then newly-introduced exact-duplicate lines
#                         (not present in the base) are dropped, keeping the
#                         first occurrence. Blank and comment lines are never
#                         deduplicated.
#
# Exit 0 only when the result has no conflict markers and (registry mode)
# passes a structural parse check. Otherwise the best-effort result, with real
# conflict markers where needed, is left in %A and the driver exits 1.
#
# Args (git merge-driver convention): %O %A %B [%L marker-size] [%P path]

set -uo pipefail

O="${1:?usage: merge-driver-union.sh %O %A %B [%L] [%P]}"
A="${2:?}"
B="${3:?}"
P="${5:-$A}"

[[ -f "$O" && -f "$A" && -f "$B" ]] || exit 1

work="$(mktemp -d "${TMPDIR:-/tmp}/merge-union.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT

# Private copies FIRST: nothing below reads a file that is also written.
cp "$O" "$work/base"
cp "$A" "$work/ours"
cp "$B" "$work/theirs"
out="$(mktemp "$(dirname "$A")/.merge-union-out.XXXXXX")" || exit 1

install_result() {  # $1 = file to install over %A
  cat "$1" > "$out" && mv -f "$out" "$A"
}

fallback_conflict() {  # real 3-way markers, driver reports conflict
  cp "$work/ours" "$work/cur"
  git merge-file -p -L ours -L base -L theirs "$work/cur" "$work/base" "$work/theirs" > "$work/conflict" 2>/dev/null
  install_result "$work/conflict"
  exit 1
}

case "$P" in
  *EVENT_REGISTRY.yaml)
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$work/base" "$work/ours" "$work/theirs" "$work/result" <<'PY'
import re, sys
base_p, ours_p, theirs_p, out_p = sys.argv[1:5]
KIND = re.compile(r'^  - kind:\s*(\S+)')

def split(path):
    text = open(path, encoding='utf-8').read()
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith('\n'):
        lines[-1] += '\n'
    header, blocks, order, cur, seen = [], {}, [], None, {}
    for ln in lines:
        m = KIND.match(ln)
        if m:
            # The shipped registry has repeated kinds, so key = kind#occurrence.
            seen[m.group(1)] = seen.get(m.group(1), 0) + 1
            cur = '%s#%d' % (m.group(1), seen[m.group(1)])
            blocks[cur] = []
            order.append(cur)
        (blocks[cur] if cur is not None else header).append(ln)
    return ''.join(header), {k: ''.join(v) for k, v in blocks.items()}, order

hb, bb, bo = split(base_p)
ho, ob, oo = split(ours_p)
ht, tb, to = split(theirs_p)

def pick(b, o, t):
    if o == t: return o
    if o == b: return t
    if t == b: return o
    return None

h = pick(hb, ho, ht)
if h is None:
    sys.exit(3)

res, seen = [], set()
def emit(kind, text):
    if text is not None and kind not in seen:
        seen.add(kind); res.append(text)

for k in oo:                                    # ours order first
    o = ob[k]; b = bb.get(k); t = tb.get(k)
    if k in bb:
        if k not in tb:                          # theirs deleted it
            if o != b: sys.exit(3)               # ours edited, theirs deleted
            continue
        v = pick(b, o, t)
        if v is None: sys.exit(3)
        emit(k, v)
    else:                                        # added by ours
        if k in tb and tb[k] != o: sys.exit(3)   # same kind, different text
        emit(k, o)
for k in to:                                     # then theirs-only blocks
    if k in seen: continue
    if k in ob: continue
    if k in bb:                                  # ours deleted it
        if tb[k] != bb[k]: sys.exit(3)
        continue
    emit(k, tb[k])

body = ''.join(res)
if body and not h.endswith('\n') and h: h += '\n'
open(out_p, 'w', encoding='utf-8').write(h + body)
PY
      rc=$?
      if [[ $rc -ne 0 ]]; then fallback_conflict; fi
      cp "$work/result" "$work/merged"
    else
      cp "$work/ours" "$work/cur"
      git merge-file --union -p "$work/cur" "$work/base" "$work/theirs" > "$work/merged" || true
    fi
    ;;
  *)
    cp "$work/ours" "$work/cur"
    git merge-file --union -p "$work/cur" "$work/base" "$work/theirs" > "$work/merged"
    mrc=$?
    [[ $mrc -lt 127 ]] || fallback_conflict
    # Drop newly-introduced exact duplicate lines (keep first occurrence).
    awk 'NR==FNR { base[$0]=1; next }
         /^[[:space:]]*$/ || /^[[:space:]]*#/ { print; next }
         ($0 in base) { print; next }
         ($0 in seen) { next }
         { seen[$0]=1; print }' "$work/base" "$work/merged" > "$work/deduped" \
      && mv -f "$work/deduped" "$work/merged"
    ;;
esac

# ── Validation ────────────────────────────────────────────────────────────────
if grep -qE '^(<{7}|>{7}|={7})( |$)' "$work/merged"; then
  install_result "$work/merged"; exit 1
fi
case "$P" in
  *EVENT_REGISTRY.yaml)
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$work/merged" "$work/base" "$work/ours" "$work/theirs" <<'PY' || { install_result "$work/merged"; exit 1; }
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
from collections import Counter
def counts(path):
    return Counter(re.findall(r'^  - kind:\s*(\S+)', open(path, encoding='utf-8').read(), re.M))
allowed = Counter()
for p in sys.argv[2:5]:
    for k, n in counts(p).items():
        allowed[k] = max(allowed[k], n)
try:
    import yaml
    doc = yaml.safe_load(text)
    kinds = [e['kind'] for e in doc['events']]
except ImportError:
    kinds, in_events = [], False
    for n, ln in enumerate(text.splitlines(), 1):
        if ln.startswith('events:'): in_events = True; continue
        s = ln.strip()
        if not s or s.startswith('#'): continue
        if in_events and not (ln.startswith('  ') or ln.startswith('- ')):
            continue                      # a new top-level key after events
        if in_events and ln.startswith('  - kind:'):
            kinds.append(re.match(r'^  - kind:\s*(\S+)', ln).group(1))
        elif in_events and not re.match(r'^(  - | {4,}|\t)', ln) and not ln.startswith('  #'):
            print(f'unexpected line shape at {n}: {ln!r}', file=sys.stderr); sys.exit(1)
except Exception as e:
    print(f'registry does not parse: {e}', file=sys.stderr); sys.exit(1)
for k, n in Counter(kinds).items():
    if n > allowed[k]:     # the merge itself must not introduce a repeated kind
        print('merge introduced duplicate kind %s' % k, file=sys.stderr); sys.exit(1)
PY
    fi
    ;;
esac

install_result "$work/merged"
exit 0
