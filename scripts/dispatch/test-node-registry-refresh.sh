#!/usr/bin/env bash
# Tests for node-registry-refresh.sh. Fake registry, fake `ssh` on PATH — never
# touches a real node or the real docs/fleet/nodes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d -t noderegtest); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root/docs/fleet/nodes" "$T/root/scripts/dispatch" "$T/bin"
cp "$HERE/node-registry-refresh.sh" "$T/root/scripts/dispatch/"
REG="$T/root/docs/fleet/nodes"

# A describe script that just echoes a valid profile for whatever host it runs on.
cat > "$T/root/scripts/dispatch/node-describe.sh" <<'DESC'
#!/usr/bin/env bash
echo "{\"node_id\":\"probed\",\"probed_at\":\"2026-01-01T00:00:00Z\",\"hardware\":{\"cpu_cores\":9}}"
DESC

# Fake ssh: "up" answers, everything else fails — and it RECORDS its argv so we
# can assert ssh_target was honoured rather than guessed.
cat > "$T/bin/ssh" <<FAKE
#!/usr/bin/env bash
args="\$*"
echo "\$args" >> "$T/ssh-calls.log"
case "\$args" in
  *up*) cat >/dev/null; bash "$T/root/scripts/dispatch/node-describe.sh" ;;
  *)    cat >/dev/null; exit 255 ;;
esac
FAKE
chmod +x "$T/bin/ssh"
export PATH="$T/bin:$PATH"

# Carries a HUMAN decision a probe can never regenerate.
printf '{"node_id":"up","hardware":{"cpu_cores":1},"role_pin":"brain","role_pin_reason":"topology decision 2026-09-07"}\n' > "$REG/up.json"
printf '{"node_id":"down","hardware":{"cpu_cores":2},"services_running":["important"]}\n' > "$REG/down.json"
printf '{"node_id":"odd","ssh_target":"droid@1.2.3.4 -p 8022"}\n' > "$REG/odd.json"

out=$(cd "$T/root" && bash scripts/dispatch/node-registry-refresh.sh 2>&1)
pass=0; fail=0
ck(){ if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1 :: $out"; fail=$((fail+1)); fi; }

ck "N1 a reachable node is rewritten with a fresh probe" 'grep -q "\"cpu_cores\": *9" "$REG/up.json"'
# The load-bearing safety property. A prober cannot tell "terminated" from
# "asleep"; deleting on first failure would erase a sleeping laptop.
ck "N2 an UNREACHABLE node is KEPT, not deleted" '[ -f "$REG/down.json" ]'
ck "N3 ...and is marked unreachable with the time" 'grep -q "\"reachable\": *false" "$REG/down.json" && grep -q last_probe_failed_at "$REG/down.json"'
ck "N4 ...preserving its last known truth for a reader" 'grep -q important "$REG/down.json"'
ck "N5 ssh_target is honoured, not the bare node_id" 'grep -q -- "droid@1.2.3.4 -p 8022" "$T/ssh-calls.log"'
ck "N6 a node with no ssh_target is reached by its id" 'grep -qE "(^| )up( |$)" "$T/ssh-calls.log"'
# The first version wrote the probe straight over the record and destroyed
# role_pin/role_pin_reason on two real nodes. A probe measures hardware; it does
# not get to delete judgements.
ck "N7 a probe MERGES — human role_pin survives" 'grep -q "\"role_pin\": *\"brain\"" "$REG/up.json" && grep -q "topology decision" "$REG/up.json"'
ck "N7b the run reports counts" 'echo "$out" | grep -q "1 probed, 2 unreachable"'

# Dry run must not write.
printf '{"node_id":"down","hardware":{"cpu_cores":2}}\n' > "$REG/down.json"
before=$(md5 -q "$REG/down.json" 2>/dev/null || md5sum "$REG/down.json" | cut -d" " -f1)
out=$(cd "$T/root" && DRY_RUN=1 bash scripts/dispatch/node-registry-refresh.sh 2>&1)
after=$(md5 -q "$REG/down.json" 2>/dev/null || md5sum "$REG/down.json" | cut -d" " -f1)
ck "N8 DRY_RUN writes nothing" '[ "$before" = "$after" ]'

echo; echo "$pass/$((pass+fail)) passed"; [ "$fail" -eq 0 ]
