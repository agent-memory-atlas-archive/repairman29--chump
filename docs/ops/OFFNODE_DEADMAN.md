# Off-node dead-man's switch for CJ (RESILIENT-1247)

## The hole this closes
On 2026-09-16 CJ (`closetjunky`) — the **single** fleet coordinator + worker —
went dark for ~13h. Its worker log dir vanished, every dispatch failed `rc=1`,
the fleet produced nothing, and **nothing paged**, because CJ's own
duty-officer / discord-gateway runs *on CJ*: a CJ-wide failure has no off-node
witness. With Oracle coordination retired, CJ is a single point of failure with
no external watcher.

## Recommendation: B (off-node watcher), because A can't be finished without you
Two paths were on the table:

| | A — external dead-man (healthchecks.io-style) | **B — off-node watcher (chosen)** |
|---|---|---|
| Robustness | Highest (survives a full Oracle teardown) | High (dies only if the watcher box dies) |
| Credential needed from Jeff | **Yes** — create the check + wire its alert channel | **No** — reuses cuphead's own Discord token |
| Buildable + live tonight | No (blocked on your account step) | **Yes** |

The measured deciding fact: **CJ and the Oracle boxes are mutually
network-isolated** — no ssh either way, no reachable tailnet port (verified:
`cuphead→CJ:22` times out, `CJ→cuphead:22` publickey-denied, `CJ→cuphead:7070`
`http=000`). So an off-node watcher **cannot pull** CJ's health. The only
rendezvous both can reach is the public internet. Both CJ and cuphead reach
GitHub (`200`) with `gh` auth, and cuphead holds its **own** live Discord bot
token (`~/.chump/providers.env`, verified `users/@me → 200`) — so cuphead can
page you with CJ entirely down, through no CJ-owned channel.

B is fully live now. **A is the recommended robustness upgrade** — see the last
section; it needs one step only you can do.

## Architecture (push-based dead-man over a GitHub gist)
```
  CJ (closetjunky)                 GitHub (secret gist)            cuphead (muscle)
  cj-deadman-push.sh   --push-->   deadman.json          <--read-- offnode-deadman-watch.sh
   every 5m (systemd)              {pushed_epoch,                   every 10m (systemd)
   reads farmer-heartbeat          farmer_hb_epoch}                 grades freshness;
   writes both epochs                                               pages via cuphead's
                                                                    OWN Discord token
```
- **Absence of a push == CJ dark.** If CJ is down the pusher can't run and
  `pushed_epoch` freezes → watcher pages (`cj_deadman_dark`).
- **Worker-wedge is also caught.** If the box stays up but the worker loop dies,
  the pusher keeps beating but `farmer_hb_epoch` freezes → watcher pages
  (`cj_deadman_worker_wedged`). This is the exact 2026-09-16 mode.
- **Fail-loud + blip-tolerant.** An unreadable gist falls back to the locally
  cached last-good beat; only sustained absence past the stale window pages, so
  a transient GitHub blip doesn't cry wolf. No cache + unreadable → page
  (`cj_deadman_unreadable`: health UNKNOWN).
- **Stale window** = 20m (`CHUMP_DEADMAN_STALE_SECS`, 4× the 5m push cadence) —
  absorbs a couple of missed pushes, far shorter than the 13h hole.
- The page is **halt-class**, so it forces past the escalation registry and
  lands on your phone.

## Files
- `scripts/ops/cj-deadman-push.sh` — CJ side (the beat).
- `scripts/ops/offnode-deadman-watch.sh` — cuphead side (the witness + pager).
- `scripts/ops/systemd/chump-cj-deadman-push.{service,timer}` — CJ, every 5m.
- `scripts/ops/systemd/chump-offnode-deadman-watch.{service,timer}` — cuphead, every 10m.
- `scripts/ci/test-offnode-deadman.sh` — simulates CJ-dark (node-dark /
  worker-wedge / 13h drought / unreadable) → asserts the watcher pages to a test
  sink; asserts a healthy CJ and a transient blip do NOT page.

## The one non-committed config
The rendezvous gist id is **not** in the repo (keeps the public repo clean). It
lives in `~/.chump/providers.env` on both nodes as `CHUMP_DEADMAN_GIST_ID=…`.
The gist is secret and holds only a hostname + timestamps (zero secrets).

## Install
On **CJ** (`ssh closetjunky`):
```
echo 'CHUMP_DEADMAN_GIST_ID=<id>' >> ~/.chump/providers.env
cp scripts/ops/systemd/chump-cj-deadman-push.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now chump-cj-deadman-push.timer
```
On **cuphead** (the off-node witness):
```
echo 'CHUMP_DEADMAN_GIST_ID=<id>' >> ~/.chump/providers.env
cp scripts/ops/systemd/chump-offnode-deadman-watch.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now chump-offnode-deadman-watch.timer
```
The watcher is a pure read+page observer. It re-enables **no** coordination
organ and is safe on `CHUMP_NODE_ROLE=muscle`.

## Revert (clean, both nodes)
```
# CJ:
systemctl --user disable --now chump-cj-deadman-push.timer
rm ~/.config/systemd/user/chump-cj-deadman-push.{service,timer}
# cuphead:
systemctl --user disable --now chump-offnode-deadman-watch.timer
rm ~/.config/systemd/user/chump-offnode-deadman-watch.{service,timer}
# both: drop CHUMP_DEADMAN_GIST_ID from ~/.chump/providers.env
systemctl --user daemon-reload
gh gist delete <id> --yes    # optional: remove the rendezvous gist
```

## Recommended upgrade — Option A (needs one Jeff step)
B dies if cuphead is ever decommissioned (you're rethinking the Oracle boxes).
To make the watch survive a full Oracle teardown, add an **external** dead-man
in parallel: point CJ's pusher at a healthchecks.io (or Cronitor / Better Stack)
check — CJ `curl`s the check URL every 5m; the service pages you if the pings
stop. This is `$0` on the free tier and independent of every box we own.

**The one step only you can do:** create the check and wire its alert channel
(email / SMS / your Discord webhook) in that account — I cannot enter your
account credentials or contact details. Give me the check's ping URL and I'll
add a `curl -fsS "$HC_PING_URL"` line to `cj-deadman-push.sh` (guarded by
`CHUMP_DEADMAN_HC_URL` in providers.env) so both watchers run side by side.
