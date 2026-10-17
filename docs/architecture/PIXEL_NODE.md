# Pixel Node — the Android fleet node (RESILIENT-336)

The Pixel 8 Pro runs as a **third fleet node** — an express-lane worker + witness
probe. This doc captures the reproducible install and the resilience model so the
node can be rebuilt (or a second device onboarded) without re-deriving the setup.

> Companion to [`ANDROID_COMPANION.md`](ANDROID_COMPANION.md) (Mabel the Sentinel).
> That doc is the companion-agent role; this one is the **fleet-node** role.

## What runs on the node

| Process | Script | Role |
|---|---|---|
| `pixel-node-supervisor.sh` | `scripts/setup/pixel-node-supervisor.sh` | restarts the two below on death; takes the wake-lock |
| `pixel-worker.sh` | `scripts/setup/pixel-worker.sh` | express-lane gap worker (`chump --execute-gap`, cascade LLM) |
| witness probe | `scripts/setup/witness/probe.py` + `run.sh` | 5-min helsinki/NATS + trunk-age watch; DM-alerts on darkness |
| `sshd` | (boot hook) | SSH :8022 for Mac-side management |

The worker is **express-lane only**: `WORKER_SKILLS=docs,shell,scripts,md` (no
`rust`), effort `xs`/`s`, P1/P2. A failed gap gets a **cooldown** (default 1h) so
the loop advances instead of re-hammering one hard gap — the weak-model failure
saga is documented in [`docs/syntheses/free-tier-dispatch-testing-2026-05-08.md`](../syntheses/free-tier-dispatch-testing-2026-05-08.md)
(0/6 free-tier providers produced a commit).

## LLM model choice (the saga lesson)

Free-tier models fail gap work — even the simplest gap. The node therefore routes
the worker through **`opencode-go/deepseek-v4-pro`** (priority 1 in the cascade),
not the slim free-tier profile:

- cascade slots 12–14 = `deepseek-v4-pro` / `kimi-k2.7-code` / `qwen3.8-max` at
  `https://opencode.ai/zen/go/v1` (key `OPENCODE_API_KEY`), priorities 1–3
- `CHUMP_FREE_TIER_PROVIDERS` is **unset** (that env var switches `execute-gap`
  into the slim 5-tool profile that failed 6/6)
- slots 1–11 remain the free-tier fallbacks (prio 10–35)

## Install (one command)

In Termux on the phone, with `~/chump-repo` checked out:

```bash
bash ~/chump-repo/scripts/setup/setup-pixel-node.sh
```

That installs the scripts into `~/`, stages the boot hook, sets env defaults, and
starts the supervisor. Idempotent.

### Prereqs (done before/once, from the Mac)

1. **Cross-compile + deploy the binary** — `scripts/setup/build-android.sh` builds
   `aarch64-linux-android` with `--no-default-features` + openssl-vendored
   (the `RANLIB_aarch64_linux_android=llvm-ranlib` export is required), then
   `scp` to `~/chump/chump`.
2. **Sync provider keys** — `~/chump/.env` needs the cascade roster
   (`CHUMP_PROVIDER_*`) + `OPENCODE_API_KEY`. These are secrets; sync from the
   Mac, never commit.
3. **Witness creds** — `~/.witness-env` needs `DISCORD_TOKEN` +
   `CHUMP_READY_DM_USER_ID` (chmod 600). The probe reads them at runtime; they
   are never committed.
4. **Fresh gap registry** — the worker keeps `~/chump-repo/.chump/state.db` in
   sync with origin/main automatically: every 30 min it does `git fetch origin
   main --depth 1` + `reset --hard origin/main` + the insert-only
   `chump gap import --yaml ~/chump-repo/docs/gaps` (adds gaps the store has
   never seen; INFRA-3628). INFRA-8193 retired `chump gap sync --pull`, so status
   changes no longer flow in from the YAML mirror; `chump store reconcile`
   (INFRA-8222) replaces that half.
5. **Termux:Boot (F-Droid)** — the boot hook is staged; the app fires it on boot.
   Note: `adb install` of Termux:Boot v0.8.1 fails (`INSTALL_FAILED_SHARED_USER_INCOMPATIBLE`)
   — its signing key predates the installed Termux 0.119.0-beta.3. Fix = reinstall
   Termux stable v0.118.3 + Termux:Boot v0.8.1 from the same signing era, or
   defer (the node survives normal ops without it).
6. **Phantom-process bypass (Android 14)** — once, over USB:
   ```bash
   adb shell device_config put activity_manager max_phantom_processes 2147483647
   adb shell settings put global settings_enable_monitor_phantom_procs false
   adb shell device_config set_sync_disabled_for_tests persistent
   ```
   Without this Android may kill the loops under memory pressure.

## Resilience model

| Failure | Recovery |
|---|---|
| worker/witness loop dies (OOM, phantom-kill) | `pixel-node-supervisor.sh` respawns within 60s |
| reboot | Termux:Boot hook starts `sshd` + supervisor |
| Doze/sleep | `termux-wake-lock` held by the supervisor |
| gap too hard for the model | worker cooldown (1h) → advances to next gap |
| provider rate-limit/404 | cascade falls through 14 slots |

## Cross-compile path

`scripts/setup/build-android.sh` produces the aarch64 binary from the Mac. The
two changes that made it work again (2026-08-16, RESILIENT-336):
- `--no-default-features` drops `web-push` (which pulls `ece` → `openssl-sys`)
- target-scoped `openssl = { features = ["vendored"] }` in `Cargo.toml` compiles
  OpenSSL from source for `axonerai`'s `native-tls` chain (durable fix =
  [INFRA-3627](gaps/INFRA-3627.yaml): patch axonerai to rustls-tls).

## Binary deploy — warm then hot-swap

`scripts/setup/deploy-pixel-node.sh` does the validated cutover so a new binary
is never swapped in blind:

1. `build-android.sh` cross-compiles.
2. `scp` to `~/chump/chump.new` (the running binary is untouched).
3. **Warm:** `chump.new` must answer a cascade smoke prompt (`WARM_OK`).
   Abort on failure — the old binary keeps running.
4. **Hot:** `mv chump.new chump` + bounce the worker; the supervisor respawns
   it on the new binary next cycle.

## Free model backends — no metered API key required (2026-08-22)

> The standing worker's documented "arm it" step (`claude setup-token` on the
> phone) is **not** the only way, and on a phone it is the *hardest* way: the
> `@anthropic-ai/claude-code` npm package has **no `linux-arm64-android` native
> binary** (postinstall ships darwin-arm64, linux-x64/arm64 glibc,
> linux-*-musl, win32 — no Android), so the bare `claude` command on Termux is
> an install-error stub. Two FREE backends were proven end-to-end on this node
> and route around that. FREE = flat-rate subscription or a $0 provider free
> tier; **not** a metered `ANTHROPIC_API_KEY`.

### The real wall: the farmer gate assumes Claude is the only backend

The worker never reaches an LLM on a token-less phone — it idles at
`chump farmer status` = RED (`oauth_fresh: FAIL`). Root cause is a **host
assumption**, not a missing model: `scripts/coord/auth-status.sh` probes the
auth path by running a real `claude -p` call. On the Pixel the broken `claude`
stub returns no `PONG`, so auth-status writes `rc=1` (BROKEN) to
`~/.chump/auth-status-cache`; `farmer_status.rs::check_oauth_fresh` reads that
cached BROKEN and fails the gate *before* its no-signal fail-open branch. A node
configured for a $0 backend needs **zero** Anthropic credentials, yet the gate
RED-locks it anyway.

**Permanent fix (specified):** teach `auth-status.sh` that a *live free-tier
provider* is a usable auth path. Guard it on `CHUMP_FREE_TIER_PROVIDERS` being
non-empty (empty on Claude nodes → their verdict is unchanged): probe each
`model@base_url:KEY_ENV` entry's `${base}/models` with its key; first `200`
→ print `AUTH ✓ OK — free-tier <provider> live` and `exit 0`. That writes
`rc=0` to the cache and the farmer goes GREEN with no Anthropic token. (Gemini's
`generativelanguage` base won't answer `/models` with a Bearer probe — iterate
the list so an OpenAI-compatible entry like Groq/Cerebras satisfies it.)

### Backend A — proot + claude-code on the subscription (proven)

`claude-code` has no Android binary, but its **linux-arm64 glibc** binary runs
fine inside a proot distro:

```bash
pkg install -y proot-distro
proot-distro install ubuntu
proot-distro login ubuntu -- bash -lc '
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
  npm i -g @anthropic-ai/claude-code'      # postinstall fetches linux-arm64 glibc native
```

Verified 2026-08-22: `claude --version` → `2.1.241 (Claude Code)` inside proot,
and `claude -p` returned a real completion using the subscription token
(`CLAUDE_CODE_OAUTH_TOKEN`, already synced in `~/.chump/providers.env`). To wire
it as the worker's Headless backend, put a `claude` shim early on the Termux PATH
that forwards into proot:

```sh
#!/data/data/com.termux/files/usr/bin/sh
exec proot-distro login ubuntu --termux-home -- \
  env CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" claude "$@"
```

The shim also fixes the farmer gate for free — `auth-status.sh`'s `claude -p`
probe now succeeds on the subscription. **Operator step (one, minimal):** mint a
subscription token on the Mac (`claude setup-token`) and sync it into
`~/.chump/providers.env` as `CLAUDE_CODE_OAUTH_TOKEN=` on the Pixel — the same
secret already present today; never commit it.

### Backend B — Groq `gpt-oss-120b`, $0, plugs into the existing worker (proven)

`chump --execute-gap` (the chump-local backend the worker already runs) never
shells to `claude`; it drives `ChumpAgent::run` in-process against the
OpenAI-compatible cascade (`OPENAI_API_BASE`/`OPENAI_API_KEY`/`OPENAI_MODEL`),
so **no `claude` binary is needed for gap-building at all.** The
`free-tier-dispatch-testing-2026-05-08` saga (0/6 commits) had two root causes:
tight rate limits (INFRA-784) and Llama-3.3-70B's malformed `patch_file` diffs
(INFRA-785). The model-quality cause is now beaten — Groq serves
`openai/gpt-oss-120b` (a 120B agentic model) on its free tier.

Verified 2026-08-22 on the Pixel (`GROQ_API_KEY` in `~/.chump/providers.env`,
live `HTTP 200`): with `gpt-oss-120b` as cascade slot 1, `chump gen` drove the
real agent loop — called `patch_file`/`read_file`, edited the target file
exactly as asked, and committed. Cost ~$0.00. The only friction was Groq
per-minute rate limits (`429`) mid-loop; the cascade self-recovered via backoff
(the INFRA-784 inter-request-delay fix would smooth it).

Config (already staged in `~/.chump/providers.env` / `~/chump/.env`, needs the
slot-order fix): put a $0 OpenAI-compatible provider at cascade priority 1 —
`openai/gpt-oss-120b @ https://api.groq.com/openai/v1 : GROQ_API_KEY` — and drop
the metered `codestral` (returns `402 Payment Required`) and empty-key `nvidia`
slots. No operator credential step: the Groq free key is already synced.

### Recommended posture

Backend B is the true $0 path and requires no Anthropic account; Backend A gives
Claude-grade quality on the flat-rate subscription and is the robust fallback.
Either one, plus the `auth-status.sh` free-tier fix above, lets this node claim
and ship fleet gaps for free — deleting the `claude setup-token`-only assumption.
