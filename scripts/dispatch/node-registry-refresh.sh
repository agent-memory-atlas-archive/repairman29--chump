#!/usr/bin/env bash
# node-registry-refresh.sh — make docs/fleet/nodes/*.json a READING, not a memory.
#
# DESIGN_GAPS_HARDWARE_AWARE.md Gap 2: the registry is "git-committed static JSON,
# written by a *manual* node-describe.sh run ... no periodic re-probe". The cost of
# that came due on 2026-09-19: mugman.json still advertised three running services
# for a machine terminated that morning, and cuphead.json claimed 2 cores / 11 GB /
# 45 GB for a box that had been 4 / 23 / 146 for hours. Both were written 09-11.
# An agent asking "what hardware do we have" got confident wrong answers.
#
# This probes each node over SSH and rewrites its record with a probed_at stamp.
#
# It does NOT delete a node that fails to answer, and that is deliberate: the Mac
# sleeps, tablets drop off wifi, an Oracle box reboots. Deleting on first failure
# would erase live machines and would itself be a confident wrong answer. Instead
# an unreachable node keeps its record, marked `reachable: false` with the time of
# the failed probe, so a reader sees BOTH the last known truth and how old it is.
#
# Removing a node you KNOW is gone is a separate, deliberate act — delete the file
# in a commit that says why. A prober cannot tell "terminated" from "asleep"; a
# human can.
#
# Usage:
#   bash node-registry-refresh.sh              # probe every node in the registry
#   NODES="cuphead closetjunky" bash ...       # probe a specific set
#   DRY_RUN=1 bash ...                         # report, write nothing
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REG="$ROOT/docs/fleet/nodes"
DESCRIBE="$ROOT/scripts/dispatch/node-describe.sh"
DRY="${DRY_RUN:-}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=${SSH_TIMEOUT:-15} -o StrictHostKeyChecking=accept-new"

[ -d "$REG" ] || { echo "no registry at $REG" >&2; exit 2; }
[ -f "$DESCRIBE" ] || { echo "no $DESCRIBE" >&2; exit 2; }

# Roster: explicit NODES wins, else every record we already have.
if [ -n "${NODES:-}" ]; then
  roster="$NODES"
else
  roster="$(ls "$REG"/*.json 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.json$//' | tr '\n' ' ')"
fi
[ -n "$roster" ] || { echo "roster empty"; exit 0; }

# Merger lives in its own file so it is invoked with plain argv — see the note
# at the call site for why a heredoc there was silently a no-op.
MERGER="$(mktemp -t nodemerge)"
trap 'rm -f "$MERGER"' EXIT
cat > "$MERGER" <<'MERGE'
import json, sys
path, probe = sys.argv[1], sys.argv[2]
probed = json.load(open(probe))
try:
    record = json.load(open(path))
except Exception:
    record = {}
record.update(probed)          # probed fields win over the stored ones
record.pop("reachable", None)  # it answered, so clear any stale unreachable mark
record.pop("last_probe_failed_at", None)
json.dump(record, open(path, "w"), indent=2)
open(path, "a").write("\n")
MERGE

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ok=0; failed=0
for node in $roster; do
  # Probe by running the CURRENT describe script on the node, so one edit here
  # fixes every node at once — no copy of the script to drift on each host.
  # A node's record may carry `ssh_target` for hosts a bare name cannot reach.
  # Receipt: the Pixel answers only as `droid@100.84.132.93 -p 8022`, so a plain
  # `ssh pixel` reported it MISSING while it was up and serving — a live node
  # would have been marked dead by a naming detail. Absent the field, the node_id
  # is the ssh host, which is what the Linux boxes already use.
  target="$(/usr/bin/env python3 -c '
import json,sys
try: print(json.load(open(sys.argv[1])).get("ssh_target","") or "")
except Exception: print("")
' "$REG/$node.json" 2>/dev/null)"
  [ -z "$target" ] && target="$node"
  # shellcheck disable=SC2086 — target may legitimately carry flags like -p 8022
  json="$(ssh $SSH_OPTS $target 'bash -s' < "$DESCRIBE" 2>/dev/null)"
  if [ -n "$json" ] && printf '%s' "$json" | /usr/bin/env python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    if [ -n "$DRY" ]; then
      echo "  OK   $node (dry run, not written)"
    else
      # MERGE, never replace. A probe measures hardware; it cannot regenerate the
      # human decisions living in the same file. The first version of this script
      # wrote the profile straight over the record and silently destroyed
      # role_pin / role_pin_reason / role_assigned on cuphead and closetjunky --
      # "always-on coordination node (topology decision 2026-09-07)" is a judgement
      # nothing can re-derive. Probed keys win; everything else is preserved.
      # The probe goes in a temp FILE, not a pipe: `python3 - file <<HEREDOC`
      # takes its program from the heredoc, which consumes the same stdin the
      # pipe was using, so the merge silently never ran and the loop still
      # printed OK. Caught by the test, not by reading it.
      probe_tmp="$(mktemp -t nodeprobe)"
      printf '%s' "$json" > "$probe_tmp"
      if /usr/bin/env python3 "$MERGER" "$REG/$node.json" "$probe_tmp"; then
        echo "  OK   $node — probed $now"
      else
        echo "  WARN $node — probed but merge FAILED, record left untouched"
        failed=$((failed + 1)); ok=$((ok - 1))
      fi
      rm -f "$probe_tmp"
    fi
    ok=$((ok + 1))
  else
    failed=$((failed + 1))
    if [ -n "$DRY" ]; then
      echo "  MISS $node (dry run, would mark unreachable)"
    elif [ -f "$REG/$node.json" ]; then
      # Mark, never delete. Keeps the last known truth AND its age.
      /usr/bin/env python3 - "$REG/$node.json" "$now" <<'PY'
import json, sys
path, now = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(0)
d["reachable"] = False
d["last_probe_failed_at"] = now
json.dump(d, open(path, "w"), indent=2)
open(path, "a").write("\n")
PY
      echo "  MISS $node — kept, marked unreachable at $now (asleep? rebooting? gone?)"
    else
      echo "  MISS $node — no existing record"
    fi
  fi
done
echo "node-registry-refresh: $ok probed, $failed unreachable, $now"
