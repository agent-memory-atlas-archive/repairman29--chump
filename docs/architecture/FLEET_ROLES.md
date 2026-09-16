---
doc_tag: canonical
owner_gap: RESILIENT-1309
last_audited: 2026-09-16
---

# Fleet Roles — Chump + Mabel + Scout

Summary of the Fleet Roles proposal: turning the agent fleet from "agents that build agents" into a **personal operations team** that does real work. Full proposal text: [PROPOSAL_FLEET_ROLES.md](PROPOSAL_FLEET_ROLES.md).

---

## Coordination home — single-writer (authoritative, current fleet, 2026-09-16)

> This section is authoritative for **which node coordinates the fleet** and
> supersedes the older Mac/Pixel/iPhone ("Chump/Mabel/Scout") proposal below,
> which predates the move onto owned iron (helsinki decommissioned 2026-08-17).

**CJ (`closetjunky`) is the SINGLE coordination home.** It is co-located with
the LIVE canonical gap store (`~/chump/.chump/state.db`) and the worker, so the
node that decides merges and pages reads the same state the fleet actually
writes. The coordination organs run **only on CJ**:

| Organ (systemd unit) | Manifest role | Runs on |
|---|---|---|
| `chump-merge-serializer.timer` (RESILIENT-372 native-merge-queue substitute) | `brain` | **CJ only** |
| `chump-duty-officer.timer` (RESILIENT-274 health-signal router / pager) | `brain` | **CJ only** |
| `chump-board-cycle.timer` (board tick + paging) | `brain` | **CJ only** |
| `chump-nba-dispatch.timer` (next-best-action auto-dispatch consumer) | `brain` | **CJ only** |
| `chump-next-best-action.timer` (EV-ranked advisory router) | `data` | **CJ only** |

**The Oracle nodes `cuphead` (161.153.42.233) and `mugman` (137.131.14.145) are
NON-coordination** — role `muscle` (worker/spare) pending Jeff's later rethink
of the Oracle boxes. They stay running; only their coordination organs are
retired. Do NOT decommission them.

### Why (RESILIENT-1309, split-brain confirmed 2026-09-16)

cuphead + mugman each still ran `merge-serializer` + `duty-officer` +
`board-cycle` + `nba-dispatch` + `next-best-action` **against a `state.db`
frozen at 2026-09-12** (5,646 gaps) while CJ's store was live (10,812 gaps,
same day). cuphead was gh-logged-in as `repairman29` and actively paging
(`board_cycle_page_sent` + `duty_officer_action` in the last 24h) on the dead
snapshot — a prime source of the cross-node merge-race
(`merge-race-green-but-never-lands`) and phantom-paging incident classes. One
serializer + one duty-officer fleet-wide is the invariant.

### Durable mechanism — how "CJ only" is enforced (survives `git reset --hard`)

Each node's role lives in `~/.chump/node.env` as `CHUMP_NODE_ROLE`
(RESILIENT-1083) — OUTSIDE the repo, so it survives the deploy mirror's
`git reset --hard origin/main`. `scripts/ops/organ-reconcile.sh` reads it and
self-scopes via `organ_role_filter_for` (`scripts/ops/lib/organ-manifest-lib.sh`):

- `muscle` → filter `muscle` — only `role=muscle` manifest organs are kept; the
  drift-removal pass **disables + reaps** any live coordination organ that is
  out-of-role. So on cuphead/mugman (`CHUMP_NODE_ROLE=muscle`) the five organs
  above are never reconciled back — a role-scoped reconcile reaps them instead
  of resurrecting them.
- `brain` (CJ) → filter `brain,data,janitor,trust` — the coordination organs
  stay enabled.

The five organs are already tagged `role=brain`/`role=data` (never `muscle`) in
`scripts/ops/organ-manifest.txt`, so no manifest edit is required — setting a
node to `CHUMP_NODE_ROLE=muscle` is sufficient to retire coordination there. The
recurring `chump-node-refresh` path also defaults to `muscle`
(`scripts/ops/node-refresh-chump.sh`), so a refresh never re-brains a muscle node.


## The three roles

| Node | Current | Proposed |
|------|---------|----------|
| **Chump (Mac)** | Self-improvement coding agent | **Forge:** builder, analyst, researcher, code reviewer, data cruncher; `CHUMP_REPO` can point at other projects. |
| **Mabel (Pixel)** | Fleet monitor + research | **Sentinel:** 24/7 ops, deal/finance/GitHub/news watchers, uptime, calendar reminders, ADB automation. |
| **Scout (iPhone)** | Inferrlm mesh node, barely used | **Interface:** you + iOS Shortcuts + Chump Web PWA (chat, quick capture, briefings, Shortcut triggers). No headless agent on device. |

Cross-cutting: **shared brain** (`research/`, `watch/`, `capture/`, `projects/`, `reports/`), **task assignee** (chump | mabel | jeff | any), **Chump Web API** (ingest, briefing, research, watch, projects), **notify** routing (push vs Discord vs silent).

## Implementation priority (from proposal)

| # | What | Effort | Depends on | Unlocks |
|---|------|--------|------------|---------|
| 1 | Chump Web PWA (full Tier 2 spec) | 12 d | Nothing | Everything below |
| 2 | Research pipeline (Chump round + brain storage) | 2 d | #1 (for triggering/viewing) | Briefs, competitive analysis, learning |
| 3 | Brain watchlists + Mabel watch rounds (deals, finance, github) | 2 d | Nothing | Passive monitoring |
| 4 | Morning briefing (Mabel synthesis round) | 1 d | #1 (for push), #3 | Daily value delivery |
| 5 | Quick capture (iPhone → Chump Web → brain) | 1 d | #1 | Personal knowledge base |
| 6 | External project work (Chump multi-repo) | 1 d | Nothing | Chump does real work for you |
| 7 | iOS Shortcuts (deploy, status, create task, capture) | 0.5 d each | #1 | Voice-driven fleet control |
| 8 | Task routing with assignee | 1 d | Nothing | Multi-agent coordination |
| 9 | Calendar integration | 2 d | #1 | Smart reminders |
| 10 | Learning assistant | 1 d | #2 | Skill development |

**Critical path:** Chump Web PWA is the gateway; everything else layers on top. See [CHUMP_BRAIN.md](CHUMP_BRAIN.md) for the expanded brain layout (`research/`, `watch/`, `capture/`, `projects/`, `reports/`).

## Fleet transport spike (design)

**Problem:** Today much of Mac↔Pixel coordination is **inbound SSH** (Mabel patrol reaches into the Mac). That fits a home lab but is awkward for strict networks, sleeping Macs, and “who initiates?” clarity.

**Spike direction (time-boxed prototype, optional):** Add an **outbound** channel from the **Pixel (Mabel)** to the **Mac** over **Tailscale** — e.g. **WebSocket** or **MQTT** — so the phone can push status, task hints, or “wake work” signals without the Mac exposing SSH to the internet. The Mac would run a small listener (sidecar or Chump web extension) authenticated via Tailscale identity or a shared secret.

**Mac behavior when sentinel is stale:** When the Mac has **not** heard from Mabel (or last-seen exceeds a threshold), treat **sentinel-delegated repair** as **paused or degraded** — log a single clear reason, **notify** once, and **do not** loop forever on SSH-based fixes that assume the Pixel path is live. Detailed scheduling lives with Mabel patrol / heartbeat scripts; this doc captures the **contract**: outbound liveness complements inbound SSH.

**Non-goals for the spike:** Replacing SSH entirely on day one; multi-tenant broker in the cloud. See [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) for the same note in the Mabel roadmap.

**Concrete spike steps:** [FLEET_WS_SPIKE_RUNBOOK.md](FLEET_WS_SPIKE_RUNBOOK.md) and `./scripts/dev/fleet-ws-spike.sh` (requires `websocat` on PATH).

## Mutual supervision (FLEET-001)

Mac and Pixel supervise each other. Both directions are implemented:

### Mac → Pixel: restart Mabel

```bash
# From Mac — SSH restart the Mabel Discord bot on the Pixel
scripts/setup/restart-mabel.sh
```

Env: `PIXEL_SSH_HOST` (default: `termux`), `PIXEL_SSH_PORT` (default: `8022`).
Supports ADB-over-USB (auto-detected) and Tailscale/WiFi (`PIXEL_SSH_FORCE_NETWORK=1`).
Retries up to `RESTART_MABEL_MAX_ATTEMPTS` (default: 3) and verifies the bot is running.
Full implementation: `scripts/setup/restart-mabel-bot-on-pixel.sh`.

### Pixel → Mac: health probe

```bash
# From Pixel (Termux) — probe Mac's Chump web API
MAC_TAILSCALE_IP=100.x.y.z MAC_WEB_PORT=3000 CHUMP_WEB_TOKEN=token scripts/dev/probe-mac-health.sh
```

Returns exit 0 on HTTP 200, exit 1 on failure. `--json` flag prints the dashboard JSON.
`mabel-farmer.sh` calls this automatically when `MAC_WEB_PORT` is set.

### Integration test

Verify both directions with the fleet running:

```bash
# 1. Mac heartbeat up — check Pixel can reach Mac dashboard
ssh termux 'MAC_TAILSCALE_IP=100.x.y.z MAC_WEB_PORT=3000 CHUMP_WEB_TOKEN=token \
    ~/chump/scripts/dev/probe-mac-health.sh'
# Expected: probe-mac-health: OK — Mac /api/dashboard responded 200

# 2. Mabel bot up — check Mac can SSH-restart it
scripts/setup/restart-mabel.sh
# Expected: "Mabel bot started." + "Done."

# 3. Full fleet health including both sides
scripts/dev/fleet-health.sh
# Expected: all checks pass
```

## Relation to existing roadmaps

- **Chump:** [ROADMAP.md](ROADMAP.md) — Fleet expansion (external work, research rounds, review round) is the next horizon after current unchecked items.
- **Mabel:** [ROADMAP_MABEL_DRIVER.md](ROADMAP_MABEL_DRIVER.md) — Extends with watch rounds (deal_watch, finance_watch, github_watch, news_brief) and Scout/PWA as primary UI.
- **Long-term technical vision** (in-process inference, eBPF, browser, task decomposition, WASM): [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md).

---

## Mutual Supervision (FLEET-001)

Mac and Pixel supervise each other via two scripts shipped in `scripts/`:

### Mac → Pixel: restart Mabel

```bash
bash scripts/setup/restart-mabel.sh [--force] [--dry-run]
```

Env vars (from `.env`): `PIXEL_SSH_HOST` (default `termux`), `PIXEL_SSH_PORT` (default `8022`).

Stops any running `chump --discord` process on Pixel, calls `ensure-mabel-bot-up.sh`,
then polls until `pgrep -f 'chump.*--discord'` confirms Mabel is running (up to 15s).
Exit 0 = success, exit 1 = SSH unreachable, exit 2 = Mabel didn't come up.

### Pixel → Mac: health probe

```bash
bash scripts/dev/probe-mac-health.sh [--quiet]
```

Env vars: `MAC_WEB_HOST` (default `mac`), `MAC_WEB_PORT` (default `3000`),
`CHUMP_WEB_TOKEN` (Bearer token, optional).

Calls `GET /api/dashboard` on Mac, parses `fleet_status` from the JSON response.
Exit 0 = green, exit 1 = yellow/unreachable, exit 2 = red.

### Integration test checklist

1. Start Chump on Mac with `CHUMP_WEB_TOKEN=test bash ./chump --web`.
2. From Pixel: `MAC_WEB_HOST=<mac-tailscale-ip> MAC_WEB_PORT=3000 CHUMP_WEB_TOKEN=test bash scripts/dev/probe-mac-health.sh` → expect exit 0.
3. From Mac: `bash scripts/setup/restart-mabel.sh --dry-run` → confirm printed SSH commands look correct.
4. From Mac with live Pixel: `bash scripts/setup/restart-mabel.sh` → confirm Mabel restarts and comes up within 15s.
5. Simulate degraded fleet: stop Chump heartbeat on Mac, re-run probe → expect exit 1 or 2.
