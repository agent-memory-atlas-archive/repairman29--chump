# Node registry

The registry itself is not in this repo. It names machines, tailnet addresses and which services
run where, and this repo is public.

- Location: `$CHUMP_NODE_REGISTRY_DIR`, default `~/.chump/fleet/nodes/`, one `<node_id>.json` per node.
- Written by `scripts/dispatch/node-registry-refresh.sh` (from `node-describe.sh` readings) and
  `scripts/dispatch/node-role-assign.sh`.
- Read by `scripts/ops/apex-watchdog.sh`, `scripts/ops/node-capacity-plan.sh` and the role kernel.
- Shape: see `example-node.json`.

The same rule covers `scripts/ops/fleet-nodes.conf`: the real file is `~/.chump/fleet-nodes.conf`
(or `$CHUMP_FLEET_NODES_CONF`); `fleet-nodes.conf.example` shows the format.
