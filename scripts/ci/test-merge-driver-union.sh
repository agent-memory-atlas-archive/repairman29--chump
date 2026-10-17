#!/usr/bin/env bash
# test-merge-driver-union.sh — INFRA-8223
#
# Rebases a real two-sided append conflict on docs/observability/EVENT_REGISTRY.yaml
# and scripts/ci/env-vars-internal.txt through the `union` driver that
# scripts/setup/install-merge-drivers.sh registers, and asserts both sides
# survive with no conflict markers and a parseable registry.
#
# Depth: happy-path + edge (identical-line dedup, same-kind-edited-both-sides
# real conflict, negative control with the old broken command). Gap: no
# multi-commit rebases, no CRLF, no files > the real registry size.

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
PASS=0; FAIL=0
ok()   { echo "  PASS $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
REG=docs/observability/EVENT_REGISTRY.yaml
ENV=scripts/ci/env-vars-internal.txt

# 0. The installer must register the script, never the truncating redirect.
if grep -Eq '^git config .*merge-file' "$REPO_ROOT/scripts/setup/install-merge-drivers.sh"; then
  fail "installer still registers the truncating '> %A' command"
else ok "installer does not register '> %A'"; fi

new_fixture() {  # $1 = dir ; $2 = driver command
  local d="$1" drv="$2"
  rm -rf "$d"; mkdir -p "$d/docs/observability" "$d/scripts/ci"
  ( cd "$d" && git init -q -b main && git config user.email t@t && git config user.name t \
    && git config merge.union.driver "$drv" && git config advice.mergeConflict false )
  cp "$REPO_ROOT/$REG" "$d/$REG"; cp "$REPO_ROOT/$ENV" "$d/$ENV"
  printf '%s merge=union\n%s merge=union\n' "$REG" "$ENV" > "$d/.gitattributes"
  ( cd "$d" && git add -A && git commit -qm base )
}
blk() { printf '  - kind: %s\n    status: active\n    emitter: x.sh\n    trigger: t\n    consumers: [ambient]\n    fields_required: [ts, kind]\n\n' "$1"; }
two_sided() {  # append different entries to both files on branch feat and main
  local d="$1"; cd "$d" || return 1
  git checkout -q -b feat
  blk feat_kind_1 >> $REG; blk feat_kind_2 >> $REG; echo "FEAT_ENV_1" >> $ENV; echo "SHARED_ENV" >> $ENV
  git commit -qam feat
  git checkout -q main
  blk main_kind_1 >> $REG; echo "MAIN_ENV_1" >> $ENV; echo "SHARED_ENV" >> $ENV
  git commit -qam main
  git checkout -q feat
}

DRV="$REPO_ROOT/scripts/git/merge-driver-union.sh %O %A %B %L %P"

# 1. Negative control: the old INFRA-1419 command reproduces the bug.
new_fixture "$W/old" 'git merge-file -p -L LEFT -L BASE -L RIGHT %A %O %B > %A'
( two_sided "$W/old" && git rebase main >/dev/null 2>&1 )
if grep -q '^<<<<<<< LEFT' "$W/old/$ENV" 2>/dev/null; then
  ok "negative control: old driver wraps the file in LEFT/RIGHT markers (bug reproduced)"
else fail "negative control: old driver did not reproduce the bug (fixture insensitive)"; fi

# 2. New driver: two-sided append on both files.
new_fixture "$W/new" "$DRV"
if ( two_sided "$W/new" && git rebase main >"$W/rebase.log" 2>&1 ); then ok "rebase onto main exits 0"
else fail "rebase onto main did not complete"; echo "  --- git rebase output:"; tail -20 "$W/rebase.log" | sed 's/^/  | /'; ( cd "$W/new" && git status --short | sed 's/^/  | status: /'; git rebase --abort >/dev/null 2>&1 || true ); fi
cd "$W/new" || exit 1
for f in $REG $ENV; do
  if grep -qE '^(<{7}|>{7}|={7})' "$f"; then fail "$f has conflict markers"; else ok "$f has no conflict markers"; fi
done
for k in feat_kind_1 feat_kind_2 main_kind_1; do
  [[ "$(grep -c "^  - kind: $k\$" $REG)" == 1 ]] && ok "registry has $k exactly once" || fail "registry kind $k count != 1"
done
for l in FEAT_ENV_1 MAIN_ENV_1; do
  [[ "$(grep -cx "$l" $ENV)" == 1 ]] && ok "env file has $l" || fail "env file missing $l"
done
[[ "$(grep -cx SHARED_ENV $ENV)" == 1 ]] && ok "identical line added on both sides appears once" || fail "SHARED_ENV duplicated or lost"
# upstream (base) content untouched: every line of origin base still present, same count
base_lines="$(git show main~1:$REG | wc -l)"; head_lines="$(wc -l < $REG)"
[[ $head_lines -eq $((base_lines + 21)) ]] && ok "registry line count = base + three 7-line blocks" || fail "registry line count $head_lines unexpected (base $base_lines)"
# order: main's entry (ours during rebase) before feat's replayed entries
m=$(grep -n 'kind: main_kind_1' $REG | cut -d: -f1); f1=$(grep -n 'kind: feat_kind_1' $REG | cut -d: -f1)
[[ $m -lt $f1 ]] && ok "order: upstream entry precedes replayed entries" || fail "order wrong ($m vs $f1)"
# blocks intact: each kind line followed by its status line
bad=$(grep -A1 '^  - kind: \(feat_kind_[12]\|main_kind_1\)$' $REG | grep -c 'status: active')
[[ $bad -eq 3 ]] && ok "no block was split" || fail "blocks split ($bad/3 intact)"
# parse
python3 - "$REG" <<'PY' && ok "registry parses (yaml if available, else shape check)" || fail "registry does not parse"
import re, sys
t = open(sys.argv[1]).read()
try:
    import yaml; d = yaml.safe_load(t); kinds = [e['kind'] for e in d['events']]
except ImportError:
    kinds = re.findall(r'^  - kind:\s*(\S+)', t, re.M)
assert kinds and all(kinds.count(k) == 1 for k in kinds if k.startswith(('feat_kind', 'main_kind')))
PY

# 3. Same kind edited differently on both sides => a real conflict (exit 1), not a silent pick.
new_fixture "$W/conf" "$DRV"
cd "$W/conf" || exit 1
git checkout -q -b feat
sed -i.bak '0,/^  - kind: /s//  - kind: /' $REG && rm -f $REG.bak
first_kind="$(grep -m1 '^  - kind:' $REG | awk '{print $3}')"
awk -v k="$first_kind" '$0=="  - kind: "k {print; print "    trigger_feat_edit: 1"; next} {print}' $REG > r && mv r $REG
git commit -qam feat
git checkout -q main
awk -v k="$first_kind" '$0=="  - kind: "k {print; print "    trigger_main_edit: 1"; next} {print}' $REG > r && mv r $REG
git commit -qam main
git checkout -q feat
if git rebase main >/dev/null 2>&1; then fail "conflicting edit was silently merged"
else
  grep -q '^<<<<<<<' $REG && ok "same-kind both-edited surfaces a real conflict" || fail "conflict left no markers"
  git rebase --abort >/dev/null 2>&1
fi

echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
