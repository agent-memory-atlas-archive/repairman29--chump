---
name: tailscale
description: Check Tailscale / node reachability the RIGHT way and report it precisely. Use whenever an agent needs to know if a node is up/down/offline, a node's ssh or ping times out, `almanac_status` says `embed_reachable:false`, embeddings are reported down, or anyone is about to say "node X is down". Encodes the checks that avoid false "down" reports (which waste the operator's time and money).
---

# tailscale — know if a node is really reachable, and say so precisely

**Why this exists (a real incident):** an agent checked Tailscale with `pgrep -x tailscaled` on a Mac, got a false negative (macOS has no such process), and reported the operator's Tailscale "down." It wasn't. Separately, "offline on the tailnet" got reported as "the box is down" — which can't be known remotely. Both wasted a round-trip. This skill stops them.

## Rule 0 — NEVER check Tailscale with `pgrep`/`ps`
macOS App Store Tailscale runs as a **network extension**, not a `tailscaled` daemon, so `pgrep tailscaled` on a Mac is a **false negative every time**. Always use the CLI:
- Find it: `command -v tailscale`, or on macOS `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.
- Linux runs the real `tailscaled` under systemd; `tailscale status` still works there.
- `tailscale status` is the source of truth. If your own node is listed with its IP, your Tailscale is up. Get the live node map from this command — don't trust a hardcoded one.

## Rule 1 — "offline on the tailnet" ≠ "the machine is down"
`tailscale status` showing `offline, last seen Nh ago` with `rx 0` means ONE thing: **unreachable over the tailnet.** It does NOT tell you if the box is powered off, up-but-tailscaled-dead, or alive-on-LAN-but-off-tailnet. Report "**X is off the tailnet / unreachable**," not "X is down," unless someone **local to the box** confirms its state. Box-dead vs tailscale-dead need different fixes (resurrect vs restart-tailscale), and only local eyes or a non-tailnet path tell them apart.

## Rule 2 — "I can't reach it" ≠ "it's down" — prove your path, then cross-check
1. Prove YOUR path first: `ping -c1 1.1.1.1` (internet up?), then `tailscale status` (you're listed = your tailnet is up). A dead local path makes every node look down.
2. Confirm the target from a **second, independent box** before blaming it — ideally one reachable without your tailnet. Both see it offline → it's the target. Only you can't → it's you.

## Rule 3 — some hosts intercept tailnet ssh
On some hosts, tailnet port 22 is handled by Tailscale SSH and a plain `ssh` to the tailnet IP **hangs**. If ssh hangs but ping/HTTP to the node work, reach it by its direct/non-tailnet address instead.

## Playbook — "is node X reachable?"
1. `tailscale status | grep -i X` → online / offline / last-seen.
2. If offline, confirm from a second box (Rule 2).
3. Probe: `ping -c2 <ip>`; a known service port, e.g. `curl -m5 http://<ip>:<port>/health`.
4. Report PRECISELY: "X unreachable over tailnet (confirmed from A and B), service :P dead" — and name what you can't know ("can't tell box-dead vs tailscale-dead; no one's local") instead of flattening to "down."

## Embeddings / almanac
`almanac_status` → `embed_reachable:false` usually means the **embed node is unreachable** — check that node first (its embedding service port). Almanac still serves **keyword** search; only the semantic layer (embeddings, fusion ranking, dedup) is down until the embed node returns.

## The money rule
A wrong "node is down" wastes the operator's time and spins agents on a non-problem. Before you report a node down or dispatch a fix: use the right tool (not `pgrep`), check from two vantages, and state the limits of what you actually know. Verify the pipe; don't trust one signal.
