---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Operations

**External adopters:** Minimal first-time path (Ollama + web health + optional CLI) is [`docs/process/EXTERNAL_GOLDEN_PATH.md`](https://github.com/repairman29/chump/blob/main/docs/process/EXTERNAL_GOLDEN_PATH.md).

## Run

**Inference profile:** See **[`docs/operations/INFERENCE_PROFILES.md`](https://github.com/repairman29/chump/blob/main/docs/operations/INFERENCE_PROFILES.md)** for **vLLM-MLX on 8000** (primary Mac), **Ollama on 11434** (dev), optional **in-process mistral.rs** (§2b: **`HF_TOKEN`**, Metal vs CPU, failure modes, **Pixel → HTTP llama-server only**; §**2b.8** upstream **`mistralrs tune`** for ISQ/RAM hints), and startup order. Mistral.rs env + health/stack-status contract: [`docs/api/WEB_API_REFERENCE.md`](https://github.com/repairman29/chump/blob/main/docs/api/WEB_API_REFERENCE.md).

All of the following are run **from the Chump repo root** (the directory containing `Cargo.toml` and `run-discord.sh`).

| Mode           | Command                                                                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| CLI (one shot) | `cargo run -- --chump "message"` or `./run-local.sh --chump "message"`                                                                           |
| CLI (repl)     | `cargo run -- --chump` or `./run-local.sh --chump`                                                                                               |
| Discord        | `./run-discord.sh` (loads .env) or `./run-discord-ollama.sh` (Ollama preflight)                                                                  |
| Slack          | `chump --slack` — Socket Mode; requires `SLACK_APP_TOKEN` + `SLACK_BOT_TOKEN` in `.env`. No public URL needed. See [`docs/architecture/MESSAGING_ADAPTERS.md`](https://github.com/repairman29/chump/blob/main/docs/architecture/MESSAGING_ADAPTERS.md#slack-socket-mode-details). |
| Web (PWA)      | **Preferred:** `./run-web.sh` (when `.env` **`OPENAI_API_BASE`** is **127.0.0.1:8000** or **:8001**, tries to start vLLM-MLX on that port via `restart-vllm-if-down.sh` / `restart-vllm-8001-if-down.sh`; then serves on port 3000 unless `CHUMP_WEB_PORT` / `--port`). Or `./run-web.sh --port 3001`. Raw: `./target/release/chump --web`. Serves `web/`, `/api/health`, `/api/chat`. Set `CHUMP_HOME` to repo so `web/` is found. The PWA talks to **one** agent per process: Chump by default, or Mabel if you start with `CHUMP_MABEL=1`. No in-app bot selector yet. |
| Desktop (Tauri) | **HTTP sidecar:** start the web server first (`./run-web.sh` or `chump --web` on port **3000**). Build the shell: `cargo build -p chump-desktop`, then `cargo run --bin chump -- --desktop` (re-execs `chump-desktop` next to `chump`). The WebView loads the same `web/` assets; API calls use **`CHUMP_DESKTOP_API_BASE`** (default `http://127.0.0.1:3000`). IPC: `get_desktop_api_base`, `health_snapshot`, `ping_orchestrator`. **Single instance:** a new Dock/CLI launch focuses the existing **Chump.app** (avoids stacking shells that each auto-spawn `chump --web`). Audit stray processes: `./scripts/dev/chump-macos-process-list.sh`. macOS Dock icon: `./scripts/setup/macos-cowork-dock-app.sh`. **MLX / vLLM dev fleet:** `./scripts/setup/tauri-desktop-mlx-fleet.sh` (checks `8000/v1/models`, `cargo test`/`clippy` for `chump-desktop`, `cargo check --bin chump`). Optional env: `CHUMP_TAURI_FLEET_USE_MAX_M4=1`, `CHUMP_TAURI_FLEET_WEB=1`; `CHUMP_TAURI_FLEET_SKIP_FMT=1` / `CHUMP_TAURI_FLEET_SKIP_CLIPPY=1` to skip steps already run in CI. |

### Preflight (daily driver / CI)

After **`chump --web`** is up, run **`./scripts/ci/chump-preflight.sh`** from repo root (or **`./target/debug/chump --preflight`** / **`./target/release/chump --preflight`**, same args). It checks:

- `GET /api/health` (chump-web)
- `GET /api/stack-status` — `status: ok`, **`tool_policy.tools_ask`** present
- When **`CHUMP_WEB_TOKEN`** is set in `.env`, uses **`Authorization: Bearer`** on stack-status
- **`logs/`** writable under the repo
- Local OpenAI-compatible **`/v1/models`** reachability when primary backend is **openai_compatible** (fails loud unless **`--warn-only`**)

Override base URL: **`CHUMP_PREFLIGHT_BASE_URL`** or **`CHUMP_E2E_BASE_URL`**. **CI:** `.github/workflows/ci.yml` runs this after the web server health loop (Playwright job).

**Quick machine strip (after web is up):** `./scripts/dev/chump-operational-sanity.sh` curls **`/api/health`** and **`/api/stack-status`**, then runs **`chump --preflight`** when a `target/{debug,release}/chump` binary exists. Override base URL with **`CHUMP_E2E_BASE_URL`**. In environments without a full `.env`, set **`CHUMP_OPERATIONAL_SKIP_PREFLIGHT=1`** to only hit the HTTP checks.

### Operator hardening (ports, Cowork, CI parity)

- **`CHUMP_DESKTOP_API_BASE`** must match the **`chump --web` port** (e.g. `http://127.0.0.1:3000` or `3848` in CI). Mismatch → offline gate or empty chat. **`CHUMP_WEB_PORT`** / **`--port`** on the sidecar must be the same port embedded in that URL.
- **`CHUMP_DESKTOP_AUTO_WEB=0`** when you start the web server yourself (recommended for predictable debugging); leave unset for auto-spawn from the desktop binary.
- **Parity with GitHub Actions:** from repo root, `cargo fmt --all -- --check`, `node scripts/ci/verify-web-index-inline-scripts.cjs`, `node scripts/ci/run-web-ui-selftests.cjs`, `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings`, `bash scripts/ci/run-ui-e2e.sh`, `bash scripts/ci/verify-external-golden-path.sh`. The **test** workflow also runs **`scripts/ci/chump-preflight.sh`** once `chump --web` is healthy (before Playwright). Tauri WebDriver (Linux): see `.github/workflows/ci.yml` **`tauri-cowork-e2e`**; locally **`bash scripts/ci/run-tauri-e2e.sh`** when you change `web/index.html` IPC or `desktop/src-tauri/`.
- **Manual pass:** Open the PWA, send a chat message, verify tool approval flow, check `/api/health` and `/api/stack-status`.

### Inference stability (ops)

- **Degraded inference / OOM / flap:** [`docs/operations/INFERENCE_STABILITY.md`](https://github.com/repairman29/chump/blob/main/docs/operations/INFERENCE_STABILITY.md) + Farmer Brown (`./scripts/dev/farmer-brown.sh` or launchd role). **Profiles and mistral.rs env:** [`docs/operations/INFERENCE_PROFILES.md`](https://github.com/repairman29/chump/blob/main/docs/operations/INFERENCE_PROFILES.md) §2b, [`docs/architecture/MISTRALRS.md`](https://github.com/repairman29/chump/blob/main/docs/architecture/MISTRALRS.md) (Tier A env ↔ `src/mistralrs_provider.rs`). Cowork chat uses the same **`chump --web`** sidecar for **`/api/chat`**; in-process **mistral.rs** behaves like the PWA for primary backend selection.
- **PWA / interactive chat latency:** **`CHUMP_LIGHT_CONTEXT=1`** with **`CHUMP_HEARTBEAT_TYPE`** unset trims `assemble_context`, caps completion tokens, shortens sliding-window history when **`CHUMP_MAX_CONTEXT_MESSAGES`** is unset, and defaults **`CHUMP_THINKING_XML`** mandate off until you set **`CHUMP_THINKING_XML=1`**. Three layers of optimization apply in light mode: (1) **tool schema compaction** — descriptions truncated, property descriptions stripped; (2) **tool-free fast path** — conversational messages skip tools entirely (315 vs 776 tokens), with auto-retry if the model narrates instead of answering; threshold is neuromodulation-aware (serotonin modulates patience); (3) **Ollama KV cache keep-alive** — `CHUMP_OLLAMA_KEEP_ALIVE` (default `"30m"`) keeps the model warm between requests. **Cognitive loop overhead** (EFE scoring, belief updates, surprise tracking, regime checks) adds <1ms per tool call — see [`docs/operations/PERFORMANCE.md`](https://github.com/repairman29/chump/blob/main/docs/operations/PERFORMANCE.md). Tunables: **`CHUMP_LIGHT_CHAT_HISTORY_MESSAGES`**, **`CHUMP_LIGHT_COMPLETION_MAX_TOKENS`**, **`CHUMP_OLLAMA_KEEP_ALIVE`**, **`CHUMP_LOG_TIMING=1`** (stderr `api_request_ms`). See **`.env.example`** and **`src/env_flags.rs`**.
- **Context-window compaction (COG-019):** For long `--chat` or `--web` sessions where conversation history would exceed the model's context window, Chump summarises the oldest turns into a `[PRIOR CONTEXT SUMMARY]` block and replaces them. Fail-open: a provider error keeps the original messages. Controls: **`CHUMP_COMPACT_ENABLED=0`** disables (default: on); **`CHUMP_COMPACT_THRESHOLD`** sets the char trigger (default: 40000, ≈10k tokens); **`CHUMP_COMPACT_KEEP_TURNS`** sets how many recent turn-pairs are kept verbatim (default: 6). Implemented in `src/session_compact.rs`, wired into `orchestrator.rs` after each user message.
- **Scripts:** `./run-local.sh` (Ollama), `./run-discord.sh` (loads .env), `./run-discord-ollama.sh` (Discord + Ollama).

### PWA as primary interface (chat with different bots)

You don't have to stop using Discord: both can run. The roadmap treats **Scout/PWA as the primary interface** (see [`docs/architecture/FLEET_ROLES.md`](https://github.com/repairman29/chump/blob/main/docs/architecture/FLEET_ROLES.md)). To get "chat with Chump vs Mabel" in one place:

- **Today:** Use `./run-web.sh` so the model (8000 or Ollama) is started if down, then the PWA runs. For two bots in one place, run two web processes: one with default env (Chump) and one with `CHUMP_MABEL=1` on different ports (e.g. 3000 and 3001). No UI bot selector yet.
- **Next step:** Add a **bot** (or **agent**) parameter to `POST /api/chat` (e.g. `bot: "chump" | "mabel"`) and have the backend build the right agent per request; then add a bot switcher in the PWA UI and separate sessions per bot. That gives one PWA URL, one place for all chats, and no dependency on Discord for daily use.

### Morning briefing DM (cron-friendly)

**`./scripts/eval/morning-briefing-dm.sh`** (repo root): calls **`GET /api/briefing`** with **`Authorization: Bearer $CHUMP_WEB_TOKEN`**, formats tasks / recent episodes / watchlists / **watch alerts** with **`jq`**, truncates to ~1900 characters, pipes to **`chump --notify`** so **`CHUMP_READY_DM_USER_ID`** gets a Discord DM. Requires web server up (`./run-web.sh`), **`DISCORD_TOKEN`**, **`jq`**, and a built **`chump`** binary. Schedule with **launchd** or **cron** if you want a daily push without opening the PWA.

### Ship autopilot (API + ChumpMenu)

**Scope:** Autopilot only **keeps the product-shipping loop** (`heartbeat-ship.sh` via `ensure-ship-heartbeat.sh`) aligned with **desired on** in `logs/autopilot-state.json`. It does **not** replace Farmer Brown, Mabel patrol, or self-improve heartbeats — those handle broader **repair and auto-improve**.

- **Control plane:** `GET/POST /api/autopilot/status|start|stop` on the **Chump web** process (see [`docs/api/WEB_API_REFERENCE.md`](https://github.com/repairman29/chump/blob/main/docs/api/WEB_API_REFERENCE.md)). Set `CHUMP_WEB_TOKEN` in `.env` for Bearer auth.
- **Automatic reconcile:** After you enable autopilot once, restarting `chump --web` or losing the ship process triggers **startup** and **every-3-minute** reconcile attempts, with **backoff** (pause auto-retries for 1 hour after 3 consecutive start failures). A manual **POST /api/autopilot/start** (or ChumpMenu **Enable Autopilot**) clears backoff.
- **ChumpMenu** uses **`CHUMP_WEB_HOST`** (default `127.0.0.1`), **`CHUMP_WEB_PORT`** (default `3000`), and **`CHUMP_WEB_TOKEN`** from the repo `.env` — match the port you pass to `./run-web.sh` / `--port`.
- **Remote / Mabel:** From any machine that can reach the Mac web port (e.g. Tailscale), call the same endpoints with the same Bearer token. Helper: `./scripts/dev/autopilot-remote.sh status|start|stop` (env: `CHUMP_AUTOPILOT_URL`, `CHUMP_WEB_TOKEN`).

### Chump stability recovery (git, env, battle QA, ship logs)

Use this when **clone/pull fails**, **`OPENAI_API_BASE` looks wrong**, **battle QA is opaque**, or **ship rounds show “no project log updated”.**

**GitHub / multi-repo (e.g. `repairman29/chump-chassis`):**

- Ensure the repo **exists** on GitHub and **`CHUMP_GITHUB_REPOS`** in `.env` includes `owner/name` exactly.
- If `gh` or `git` fails with a narrow PAT, **`unset GITHUB_TOKEN`** in the shell so git uses the credential helper or a token with **repo** scope.
- In the clone: `cd repos/owner_repo && git remote -v`. Fix with `git remote set-url origin https://github.com/owner/name.git` if needed.
- If **`Cargo.toml` was emptied or corrupted**, restore from git: `git checkout -- Cargo.toml` (or reset to last good commit), then `cargo check`.

**`OPENAI_API_BASE` (local):**

- Do not point at nonsense ports (e.g. `127.0.0.1:9`). Use **`http://localhost:8000/v1`** (vLLM-MLX), **`http://localhost:11434/v1`** (Ollama), or cloud inference via cascade. `scripts/ci/check-heartbeat-preflight.sh` rejects **localhost/127.0.0.1** ports other than **11434**, **8000**, and **8001**.

**Battle QA (`run_battle_qa` / `./scripts/ci/battle-qa.sh`):**

- Read **`logs/battle-qa-failures.txt`** and **`logs/battle-qa.log`** after a run. The tool JSON includes **`script_stdout_tail`**, **`script_stderr_tail`**, and **`log_tail`** for self-heal.
- Smoke: `BATTLE_QA_MAX=5 ./scripts/ci/battle-qa.sh` from repo root.

**Ship heartbeat — no `log.md` update:**

- Set **`HEARTBEAT_DEBUG=1`** and restart the ship script so round output is easier to inspect (see `scripts/dev/heartbeat-ship.sh`). The playbook already requires **`memory_brain append_file` to `projects/{slug}/log.md`** every ship round.

## Keeping the stack running (Farmer Brown + Mabel)

The PWA and Discord need the **model server** (e.g. vLLM on 8000 or Ollama on 11434) to be up. Two layers keep it that way:

1. **Farmer Brown (Mac)** — Diagnoses model (8000), embed, Discord; if something is down, kills stale processes and runs **keep-chump-online**, which starts vLLM (via `restart-vllm-if-down.sh`) when `.env` points at 8000, or Ollama when not. Run once: `./scripts/dev/farmer-brown.sh`. For **self-heal every 2 min**, install the launchd role: `./scripts/setup/install-roles-launchd.sh` (includes Farmer Brown). Then the Mac stack recovers automatically after crashes or reboot.

2. **Mabel (Pixel)** — She keeps the Chump stack running by running **mabel-farmer.sh** in her **patrol** round (from `heartbeat-mabel.sh`). Mabel SSHs to the Mac and runs **farmer-brown.sh** when the stack is unhealthy, so the Mac gets fixed even if you're not at the Mac. When her own Pixel model (llama-server) or Discord bot is down, she **self-heals** by running **start-companion.sh** locally: `mabel-farmer.sh` sets `need_fix_local=1` when local checks fail and, when `MABEL_FARMER_FIX_LOCAL=1` (default in `~/chump/.env`), calls `run_local_fix`, which starts `./start-companion.sh` in the background. See script header and "Mabel self-heal" in the Roadmap chapter (`./roadmap.md`) Fleet symbiosis. For Mac-side fixes to work:
   - **On the Pixel:** In `~/chump/.env` set **`MAC_TAILSCALE_IP`** to your Mac's Tailscale IP (e.g. `100.x.y.z`). Optionally `MAC_CHUMP_HOME` (e.g. `~/Projects/Chump`), `MAC_TAILSCALE_USER`, `MAC_SSH_PORT`.
   - **On the Mac:** SSH must allow the Pixel's key (e.g. add Pixel's `~/.ssh/id_ed25519.pub` to Mac's `~/.ssh/authorized_keys`). Tailscale (or reachable network) so the Pixel can reach the Mac.
   - **Run Mabel's heartbeat on the Pixel:** `./scripts/dev/heartbeat-mabel.sh` (in tmux or Termux:Boot). Patrol rounds run `mabel-farmer.sh`; when the Mac stack is down, Mabel SSHs in and runs `farmer-brown.sh`, which runs keep-chump-online and brings up vLLM/Discord.

Using **both** — Farmer Brown on the Mac (launchd every 2 min) and Mabel's patrol on the Pixel — means the stack stays up even when the model crashes or the Mac reboots, and Mabel can fix the Mac remotely when you're away.

### Mutual supervision (Chump and Mabel restart each other's heartbeat)

**Checklist:** Mac has `PIXEL_SSH_HOST` (and optionally `PIXEL_SSH_PORT`); Pixel has `MAC_TAILSCALE_IP`, `MAC_SSH_PORT`, `MAC_CHUMP_HOME`; Pixel's SSH key is on the Mac. Both restart scripts (`restart-chump-heartbeat.sh`, `restart-mabel-heartbeat.sh`) run and exit 0 when heartbeats are up.

**`./scripts/ci/verify-mutual-supervision.sh` (Mac):** Exits **0** only when Mac→Pixel SSH and the Chump restart script on the Mac succeed. If **`PIXEL_SSH_HOST`** is unset (Mac-only dev), the script reports **SKIP** for Pixel checks and may still **FAIL** on the local Chump restart step until `restart-chump-heartbeat.sh` is installed and runnable — that is expected until fleet env is configured.

**Validation gate:** From the Mac run `./scripts/ci/verify-mutual-supervision.sh`. Both checks (Mac→Pixel restart Mabel, Chump restart on Mac) must pass (exit 0). Consider mutual supervision validated only after this passes; document in runbook if needed.

### Mabel deployment issues (what goes wrong and how to fix)

**Mabel responsiveness:** Mabel responds much faster when cascade is enabled on the Pixel. Run `apply-mabel-badass-env.sh` with `MAC_ENV` pointing at a file that has provider keys (e.g. after `deploy-all-to-pixel.sh`, or SCP keys to `~/chump/.env.mac` and run with `MAC_ENV=$HOME/chump/.env.mac`). See [`docs/architecture/PROVIDER_CASCADE.md`](https://github.com/repairman29/chump/blob/main/docs/architecture/PROVIDER_CASCADE.md).

| What went wrong | Cause | Fix |
| ----------------- | ----- | --- |
| **SSH connection refused** to Pixel | Termux or **sshd** was killed (battery/Doze, app swiped). Nothing is listening on 8022. | See [Mabel down, Pixel unreachable](#mabel-down-pixel-unreachable-connection-refused) below. One-time: open Termux on Pixel, run `sshd`; then from Mac run `PIXEL_SSH_FORCE_NETWORK=1 ./scripts/setup/restart-mabel-bot-on-pixel.sh`. Reduce recurrence: Termux:Boot + Battery Unrestricted. |
| **Deploy or restart fails** (timeout / connection refused) when Pixel is on Tailscale | Script may be using ADB (USB) instead of network, or host/port not set. | From Mac run deploy/restart with **`PIXEL_SSH_FORCE_NETWORK=1`** so SSH goes over Tailscale. Ensure `~/.ssh/config` has `Host termux` → Pixel Tailscale IP, or set **`PIXEL_SSH_HOST`** (and **`PIXEL_SSH_PORT`** if not 8022) in `.env`; deploy scripts use these when set. |
| **Android build fails** (e.g. `ring` crate: "failed to find aarch64-linux-android-clang") | Android target was built without NDK env (e.g. raw `cargo build --target aarch64-linux-android`). | Always use **`./scripts/setup/build-android.sh`** for Android; it sets `CC`, `AR`, `CARGO_TARGET_*` and uses `ANDROID_TARGET_DIR`. Deploy scripts call it automatically. |
| **Android build fails** (openssl-sys: "Could not find directory of OpenSSL") | Transitive dep (axonerai) pulls reqwest with default native-tls, which needs OpenSSL for cross-compile. | Chump patches axonerai via **`[patch.crates-io]`** in `Cargo.toml` (vendored `repos/axonerai` with reqwest rustls). Ensure that patch is present; do not remove `repos/axonerai` or the patch. |
| **Upload or replace fails** (e.g. "dest open … Failure") | The running Mabel binary holds `~/chump/chump` open. | Use **`./scripts/setup/deploy-mabel-to-pixel.sh`** (or deploy-all); they stop the bot, upload to `chump.new`, then `mv` and restart. Do not `scp` directly to `chump` while the bot is running. |
| **ChumpMenu deploy/restart** uses wrong host or port | ChumpMenu runs scripts after `source .env` but scripts previously ignored `PIXEL_SSH_HOST`/`PIXEL_SSH_PORT`. | Deploy and restart scripts now respect **`PIXEL_SSH_HOST`** and **`PIXEL_SSH_PORT`** (and **`PIXEL_SSH_FORCE_NETWORK`** for restart) when set in `.env`. Ensure `.env` is correct and ChumpMenu’s repo path is the Chump repo. |

### Mabel down, Pixel unreachable (connection refused)

If the Pixel is on Tailscale but `ssh -p 8022 termux 'echo ok'` gets **connection refused**, nothing on the Pixel is listening on 8022: Termux was likely killed (battery/Doze, or app swiped away), so **sshd** stopped. We cannot fix this remotely until SSH is back.

- **One-time fix (when someone can touch the Pixel):** Open the Termux app, run `sshd`, then from the Mac run `PIXEL_SSH_FORCE_NETWORK=1 ./scripts/setup/restart-mabel-bot-on-pixel.sh` (and optionally `ssh -p 8022 termux 'cd ~/chump && bash scripts/setup/restart-mabel-heartbeat.sh'`).
- **To reduce recurrence:** On the Pixel, use **Termux:Boot** (F-Droid) and `~/.termux/boot/01-sshd.sh` so sshd starts when Termux starts; set **Settings → Apps → Termux → Battery → Unrestricted** so Android is less likely to kill Termux.

Each node can restart the other's heartbeat when it detects a stale or failing run. For this to work:

1. **Mac `.env`:** Set `PIXEL_SSH_HOST` (e.g. `termux` or the host from `~/.ssh/config`). Optionally `PIXEL_SSH_PORT=8022` if not 22. Chump's work round in heartbeat-self-improve.sh SSHs to the Pixel and runs `scripts/setup/restart-mabel-heartbeat.sh` when Mabel's heartbeat log is stale (>30 min).
2. **Pixel `~/chump/.env`:** Set `MAC_TAILSCALE_IP`, `MAC_SSH_PORT` (default 22), `MAC_CHUMP_HOME` (e.g. `~/Projects/Chump`). Mabel's patrol round SSHs to the Mac and runs `scripts/setup/restart-chump-heartbeat.sh` when Chump's heartbeat log is stale or shows repeated failures.
3. **SSH access:** Add the Pixel's SSH public key (`~/.ssh/id_ed25519.pub` on the Pixel) to the Mac's `~/.ssh/authorized_keys` so Mabel can run the restart script on the Mac. Ensure the Mac can SSH to the Pixel (e.g. `ssh -p 8022 termux` or your `PIXEL_SSH_HOST`).
4. **Test:** From the Mac run: `ssh -p 8022 termux 'cd ~/chump && bash scripts/setup/restart-mabel-heartbeat.sh'` — should exit 0 when Mabel's heartbeat is (re)started. From the Pixel (or from the Mac with Pixel env), run: `ssh -o ConnectTimeout=10 -p ${MAC_SSH_PORT} ${MAC_USER}@${MAC_TAILSCALE_IP} 'cd ${MAC_CHUMP_HOME} && bash scripts/setup/restart-chump-heartbeat.sh'` — should exit 0 when Chump's heartbeat is (re)started. Optional: run `./scripts/ci/verify-mutual-supervision.sh` to check both directions.

### Single fleet report (done criterion)

Mabel's report round produces the unified fleet report (`logs/mabel-report-YYYY-MM-DD.md`) and sends it via notify. **Done criterion for retiring Mac hourly-update:** When the report format has been stable (same section headers: FLEET HEALTH, CHUMP, MABEL, NEEDS ATTENTION) for at least a few days and on-demand **`!status`** works in Discord, unload the Mac hourly-update LaunchAgent. **Script (Mac, repo root):** `./scripts/setup/retire-mac-hourly-fleet-report.sh` — runs `launchctl bootout gui/$(id -u)/ai.chump.hourly-update-to-discord` (idempotent). **On-demand status:** Both **Chump** and **Mabel** bots respond to **`!status`** or **`status report`**. If `logs/mabel-report-*.md` exists on that host (newest by mtime), they paste it (truncated to Discord limits). If not, Chump explains that the canonical file lives on the Pixel / Mabel; Mabel says the report round has not written a file yet. Chump keeps **notify** for ad-hoc (blocked, PR ready) after you retire hourly-update.

**Soft gate (FLEET-002):** To disable Chump's hourly updates without touching launchd, set `CHUMP_FLEET_REPORT_ROLE=notify_only` in `.env`. The `hourly-update-to-discord.sh` script exits immediately when this is set, leaving Chump's notify tool for ad-hoc events only. This is the recommended approach when Mabel's report round has been stable for several days.

### CHUMP_CLI_ALLOWLIST (Mabel on Pixel)

Mabel's heartbeat uses `run_cli` for patrol (curl, ssh), research (ssh, read_url), report (ssh, sqlite3), and verify (ssh, sqlite3). On the Pixel set a sensible allowlist in `~/chump/.env`, e.g. `CHUMP_CLI_ALLOWLIST=curl,ssh,sqlite3,date,uptime`. **Required for Mabel rounds:** `ssh`, `curl`; `sqlite3` for report and verify. Empty allowlist allows any command (security risk on device). See [`scripts/dev/heartbeat-mabel.sh`](https://github.com/repairman29/chump/blob/main/scripts/dev/heartbeat-mabel.sh).

### Two-key safety (Fleet Commander peer approval)

When Chump requests approval for tools in **CHUMP_PEER_APPROVE_TOOLS** (e.g. `git_push`, `merge_pr`), he writes `brain/a2a/pending_approval.json` with `request_id`, `tool_name`, and `tool_input`. Mabel's **Verify** round reads that file; if present, she runs tests on the Mac via SSH and, if tests pass, calls **POST /api/approve** with the same Bearer token (`CHUMP_WEB_TOKEN` on the Pixel). Chump then proceeds without waiting for a human. Set `CHUMP_PEER_APPROVE_TOOLS=git_push,merge_pr` on the Mac and ensure the Pixel has `CHUMP_WEB_TOKEN` and `MAC_WEB_PORT` so Mabel can reach the Mac API. Human approval (Discord/web) still works. See [`scripts/dev/heartbeat-mabel.sh`](https://github.com/repairman29/chump/blob/main/scripts/dev/heartbeat-mabel.sh) VERIFY_PROMPT step 0.

### Progress-based monitoring (Fleet Commander zombie hunter)

When the ship heartbeat is "alive" but not making progress (same round/status for too long), Mabel can restart it. On the Pixel set `MABEL_FARMER_PROGRESS_CHECK=1` and ensure `MAC_WEB_PORT`, `CHUMP_WEB_TOKEN`, and `jq` are available. [`scripts/dev/mabel-farmer.sh`](https://github.com/repairman29/chump/blob/main/scripts/dev/mabel-farmer.sh) then fetches `GET /api/dashboard` each run, compares `ship_summary` (round, round_type, status) to the previous run; if unchanged for `MABEL_FARMER_STUCK_MINUTES` (default 25) and status is "in progress" for a high-activity round (ship, review, maintain), it SSHs to the Mac and runs [`scripts/setup/restart-ship-heartbeat.sh`](https://github.com/repairman29/chump/blob/main/scripts/setup/restart-ship-heartbeat.sh), which kills and restarts `heartbeat-ship.sh`. If the dashboard request returns 504 or times out (Tailscale up but web server dead), mabel-farmer sets need_fix and runs the full remote fix (farmer-brown.sh). The Mac dashboard response includes `timestamp_secs` for client-side age checks.

### Hybrid inference (Mabel: research/report on Mac 14B)

When Mabel runs on the Pixel, **research** and **report** rounds can use the Mac's larger model (e.g. 14B) while **patrol**, **intel**, **verify**, and **peer_sync** stay on the Pixel's local model (e.g. Qwen3-4B). No code change is required: `heartbeat-mabel.sh` already switches `API_BASE` for research and report when `MABEL_HEAVY_MODEL_BASE` is set.

- **On the Pixel** in `~/chump/.env`: set `MABEL_HEAVY_MODEL_BASE=http://<MAC_TAILSCALE_IP>:8000/v1` (use your Mac's Tailscale IP). Research and report rounds then call the Mac; other rounds use local `OPENAI_API_BASE`.
- **On the Mac:** The model server (vLLM-MLX or other) on port 8000 must be reachable from the Pixel — bind to `0.0.0.0` or ensure Tailscale can reach it.

### Mabel cascade setup

Mabel can use the same provider cascade as the Mac (Groq, Cerebras, OpenRouter, Gemini, etc.). Slot 0 stays local (Pixel llama-server) or Mac (when `MABEL_HEAVY_MODEL_BASE` is set for research/report); cloud slots are used when local is slow or rate-limited.

- **On the Pixel** in `~/chump/.env`: set `CHUMP_CASCADE_ENABLED=1` and the same (or a subset of) `CHUMP_PROVIDER_{1..N}_*` vars as the Mac: `CHUMP_PROVIDER_N_ENABLED=1`, `CHUMP_PROVIDER_N_BASE`, `CHUMP_PROVIDER_N_KEY`, `CHUMP_PROVIDER_N_MODEL`, `CHUMP_PROVIDER_N_RPM`, `CHUMP_PROVIDER_N_RPD`, etc. The binary reads these from the environment; `heartbeat-mabel.sh` sources `.env` and passes `OPENAI_API_BASE` per round (local or Mac), so the cascade gets slot 0 from that and slots 1+ from the provider vars.
- **Free-tier first:** Prefer free-tier slots so Mabel's cloud use stays at zero or minimal cost. Set RPD/RPM to actual free limits. Example slots:

| Provider   | Base / model (examples)              | Free-tier notes                    |
| ---------- | ------------------------------------ | ---------------------------------- |
| Groq       | api.groq.com, llama-3.3-70b-versatile | RPM/RPD limits apply               |
| Cerebras   | api.cerebras.ai, llama-3.3-70b       | Generous free tier                  |
| OpenRouter | openrouter.ai, meta-llama/...:free   | Use `:free` models only            |
| Gemini     | generativelanguage.googleapis.com    | Free limits; set RPD to actual cap |

- **Key sync:** Copy provider API keys to the Pixel securely. Do not commit secrets. Options: manual paste into `~/chump/.env` on the Pixel, 1Password CLI on device, or from the Mac run `./scripts/setup/deploy-all-to-pixel.sh` which pushes cascade keys to `~/chump/.env.mac` and the apply step can merge them into Mabel's `.env`.
- **When local is down:** If `CHUMP_CASCADE_ENABLED=1` and at least one cloud slot is enabled, `heartbeat-mabel.sh` can continue without the local model (see script: preflight is skipped and rounds use cascade-only). Optional: set `MABEL_USE_CLOUD_ONLY=1` to always use cloud-only (no local, no Mac); preflight is skipped and every round uses only cascade cloud slots.

### Resiliency and failure handling

- **run-web.sh:** If `.env` points at 8000, after trying to start vLLM it checks that 8000 responds; if not, it warns and still starts the PWA so you can fix the model separately.
- **restart-mabel-bot-on-pixel.sh:** When the Pixel is on USB, uses **ADB forward** so SSH goes over the cable (no WiFi). Otherwise SSH to termux. Retries; two short SSHs.
- **deploy-mabel-to-pixel.sh / deploy-all-to-pixel.sh:** SCP and SSH steps retry; robust timeouts and keepalives. Run full deploy from a terminal so the Android build (5–10 min) isn't killed.
- **Circuit breaker (model client):** After repeated failures to the model API, the client stops calling for a cooldown. Configure with `CHUMP_CIRCUIT_COOLDOWN_SECS` (default 30) and `CHUMP_CIRCUIT_FAILURE_THRESHOLD` (default 3). See [`docs/operations/DISCORD_TROUBLESHOOTING.md`](https://github.com/repairman29/chump/blob/main/docs/operations/DISCORD_TROUBLESHOOTING.md).
- **Per-tool circuit breaker:** After N consecutive failures of a single tool, that tool is skipped for M seconds. Env **CHUMP_TOOL_CIRCUIT_FAILURES** (default 3), **CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS** (default 60). Error returned: "tool X temporarily unavailable (circuit open)".
- **Global tool concurrency:** **CHUMP_TOOL_MAX_IN_FLIGHT** — max concurrent `execute()` calls across all tools and sessions in one process (`0` = unlimited, default). When set, extra callers **await** a slot (helps under multi-session web load or future parallel batches). Exposed on **GET /health** as **`tool_max_in_flight`**.
- **Web server:** Chat runs in a background task; if a chat run fails, the error is logged to stderr (`[web] chat run failed: ...`). For 401 / "models permission required", see [`docs/architecture/PROVIDER_CASCADE.md`](https://github.com/repairman29/chump/blob/main/docs/architecture/PROVIDER_CASCADE.md) and run `./scripts/ci/check-providers.sh`. Static dir creation failures are logged and the server still starts.
- **restart-vllm-if-down.sh:** On timeout (4 min), exits 1 and prints the log path and retry command so you can fix and re-run.

## Observability (GET /health)

When `CHUMP_HEALTH_PORT` is set, Chump serves **GET /health** with JSON status. Use it for ChumpMenu, load balancers, or scripts.

**Fields:**

- **model** — `ok` / `down` / `n/a`. Normally probes `OPENAI_API_BASE/models`. When **`CHUMP_INFERENCE_BACKEND=mistralrs`** and **`CHUMP_MISTRALRS_MODEL`** is set (same predicate as `/api/stack-status`), **`model` is `ok`** without that HTTP probe so in-process mistral.rs is not marked down.
- **inference_backend** — `"mistralrs"` or `"openai_compatible"` (env predicate only; mirrors stack-status `primary_backend`).
- **embed** — `ok` / `down` / `n/a` (probe of embed server).
- **memory** — `ok` / `down` (SQLite memory DB).
- **version** — Chump version string.
- **model_circuit** — `closed` (healthy) / `open` (cooldown after model API failures) / `n/a` (no model base configured). When `open`, the client has stopped calling the model for the cooldown period (`CHUMP_CIRCUIT_COOLDOWN_SECS`, default 30).
- **status** — `healthy` or `degraded`. `degraded` when model is `down` or model_circuit is `open`. Consumers can treat `status: degraded` as unhealthy (e.g. ChumpMenu, alerts).
- **tool_max_in_flight** — Integer cap when **CHUMP_TOOL_MAX_IN_FLIGHT** is set; omitted or `null` when unlimited (`0`).
- **tool_rate_limit** — When **`CHUMP_TOOL_RATE_LIMIT_TOOLS`** is set: object with **`tools`** (list), **`max_per_window`**, **`window_secs`** (sliding window per tool name). Otherwise **`null`**. See the published Rust infrastructure chapter (`./rust-infrastructure.md`).
- **tool_calls** — Object of tool name → total call count (success + failure) since process start. Example: `{"run_cli": 42, "read_file": 10}`.
- **recent_tool_calls** — Last 15 rows from `chump_tool_health` (same ring buffer as the **introspect** tool): `tool`, `args_snippet`, `outcome`, `called_at`. Empty array if the DB is unavailable.

**Example:** `curl http://localhost:CHUMP_HEALTH_PORT/health`. HTTP 200 is always returned; check `status` and `model_circuit` for health.

### JSONL RPC log mirror

When running **`chump --rpc`**, set **`CHUMP_RPC_JSONL_LOG`** to a file path (e.g. `logs/rpc-events.jsonl`). Every JSONL line written to stdout is also appended to that file for auditing.

### Autonomy cron

**`scripts/dev/autonomy-cron.sh`** runs **`--reap-leases`** then one **`--autonomy-once`**; appends to **`logs/autonomy-cron.log`**. Uses **`target/release/chump`** when present. Env: **`CHUMP_AUTONOMY_ASSIGNEE`**, **`CHUMP_AUTONOMY_OWNER`**, **`CHUMP_TASK_LEASE_TTL_SECS`**. Copy-paste **cron / launchd** wrappers (including notify-on-failure): see `scripts/*.plist.example`. Each **`--autonomy-once`** outcome is also appended to **`chump_async_jobs`** in `chump_memory.db` — inspect via **`GET /api/jobs`** or **`GET /api/pilot-summary`** (`recent_async_jobs`) when web is up ([`docs/api/WEB_API_REFERENCE.md`](https://github.com/repairman29/chump/blob/main/docs/api/WEB_API_REFERENCE.md)).

### Web Push (PWA)

**Subscribe:** The PWA calls **`GET /api/push/vapid-public-key`**, then `pushManager.subscribe` with that public key, then **`POST /api/push/subscribe`** (see [`docs/api/WEB_API_REFERENCE.md`](https://github.com/repairman29/chump/blob/main/docs/api/WEB_API_REFERENCE.md)). Keys are stored in **`chump_push_subscriptions`**.

**Generate a VAPID key pair (openssl):**

```bash
openssl ecparam -genkey -name prime256v1 -noout -out vapid-private.pem
openssl ec -in vapid-private.pem -pubout -outform DER | tail -c 65 | base64 | tr '/+' '_-' | tr -d '\n'
```

Put the one-line base64 output in **`CHUMP_VAPID_PUBLIC_KEY`** (what the browser sees). Put the PEM path in **`CHUMP_VAPID_PRIVATE_KEY_FILE`** (server only; never commit the PEM). Optional **`CHUMP_VAPID_SUBJECT=mailto:you@example.com`** for the VAPID JWT.

**Server-initiated notifications:** Set **`CHUMP_WEB_PUSH_AUTONOMY=1`** so that after each **`chump --autonomy-once`** run, subscribers receive a push when the outcome is **done**, **blocked**, or **error** (title + truncated detail). Requires the private key file and at least one subscription. The service worker **`web/sw.js`** shows **`showNotification`** from the JSON payload.

### Inference stability (OOM / crash loops)

See **[`docs/operations/INFERENCE_STABILITY.md`](https://github.com/repairman29/chump/blob/main/docs/operations/INFERENCE_STABILITY.md)** (vLLM/Ollama triage, Farmer Brown, links to GPU tuning).

**Degraded mode:** When local `/v1/models` fails but Chump is still up, treat the stack as **degraded**—chat and heartbeats may block or error until inference recovers. Follow **INFERENCE_STABILITY.md → Degraded mode playbook** (Ollama fallback, OOM mitigations, `farmer-brown` scope, cloud-only option). The PWA **Providers** sidecar shows `stack-status` errors when present.

### Tracing (RUST_LOG)

Chump uses **`tracing`** with **`tracing_subscriber::EnvFilter`** (see `src/tracing_init.rs`, called from `main.rs`). The crates.io / Cargo package name is **`chump`**; `RUST_LOG` filters use the **`chump::…`** module prefix (e.g. `RUST_LOG=chump::agent_loop=debug`). Set **`RUST_LOG`** (e.g. `RUST_LOG=info`, `RUST_LOG=chump=debug`, or `RUST_LOG=debug` for verbose). Optional env: **`CHUMP_TRACING_FILE`** (write structured logs to file), **`CHUMP_TRACING_JSON_STDERR`** (JSON lines on stderr), **`CHUMP_WEB_HTTP_TRACE`** (log HTTP requests). Hot paths emit spans for **`ChumpAgent::run`**, **`execute_tool_calls_with_approval`**, **`StreamingProvider::complete`** (LLM round), and **`autonomy_once`**. There is no span DB yet; use log aggregation, JSONL tracing, or `RUST_LOG` for latency debugging.

## Tool approval (CHUMP_TOOLS_ASK)

When you want certain tools to require explicit approval before execution (e.g. `run_cli`, `write_file`), set **CHUMP_TOOLS_ASK** to a comma-separated list of tool names. Example: `CHUMP_TOOLS_ASK=run_cli,write_file`. If unset or empty, no tools require approval.

- **Approval timeout:** Env **CHUMP_APPROVAL_TIMEOUT_SECS** (default 60, min 5, max 600). If the user does not Allow or Deny within this time, the tool is treated as denied and the turn continues with a "User denied the tool (or approval timed out)" result.
- **Where to see pending approvals:**
  - **Discord:** When a tool in CHUMP_TOOLS_ASK is about to run, the bot sends a message in the channel with "Allow once" and "Deny" buttons. Click to approve or deny.
  - **Web/PWA:** Use the approval card in the chat UI and click Allow or Deny; or POST to **/api/approve** with body `{"request_id": "<uuid>", "allowed": true|false}`.
  - **ChumpMenu:** Chat tab streams `/api/chat`; when a tool needs approval, use **Allow once** or **Deny** (same bearer token as chat).
  - **Heartbeat interrupt policy:** Set **`CHUMP_INTERRUPT_NOTIFY_POLICY=restrict`** to allow `notify` only when the message matches interrupt tags/phrases. Optional **`CHUMP_NOTIFY_INTERRUPT_EXTRA`** for extra substrings.
- **Audit:** Every approval decision (allowed, denied, timeout, or env-based auto-approve) is logged to **logs/chump.log** with event `tool_approval_audit` (tool name, args preview, risk level, result). With `CHUMP_LOG_STRUCTURED=1` the line is JSON. Result values include **`auto_approved_cli_low`** (see below) and **`auto_approved_tools_env`**.
- **Audit export (web):** `GET /api/tool-approval-audit` (optional `format=csv`) returns recent tail-parsed rows; PWA **Settings** includes a text snapshot. See [`docs/api/WEB_API_REFERENCE.md`](https://github.com/repairman29/chump/blob/main/docs/api/WEB_API_REFERENCE.md).
- **Autonomy / headless auto-approve (explicit opt-in):** For **`chump --rpc`**, cron **`--autonomy-once`**, or any run where blocking on Discord/PWA approval is impractical, you can narrow the gap with:
  - **`CHUMP_AUTO_APPROVE_LOW_RISK=1`** — If **`run_cli`** is in **`CHUMP_TOOLS_ASK`**, skip the approval wait when **`cli_tool::heuristic_risk`** classifies the command as **low** (e.g. typical `cargo test` / `cargo check` without destructive patterns). Still written to **`tool_approval_audit`** with result **`auto_approved_cli_low`**.
  - **`CHUMP_AUTO_APPROVE_TOOLS=read_file,calc`** — Comma-separated tool names; if a tool is listed here **and** in **`CHUMP_TOOLS_ASK`**, it runs without a prompt. Audit result **`auto_approved_tools_env`**. Use only for tools you accept running unattended.

## Air-gap mode (CHUMP_AIR_GAP_MODE)

When **`CHUMP_AIR_GAP_MODE=1`** (or **`true`**, case-insensitive), Chump does **not** register the general-Internet agent tools **`web_search`** (Tavily) and **`read_url`**. Discord/CLI/web agents use the same registration path. Startup config logs **`air_gap_mode`** and warns if **`TAVILY_API_KEY`** is set (the key has no effect on tools while air-gap is on). **`run_cli`** is unchanged — combine with **`CHUMP_TOOLS_ASK`** / allowlists for high-assurance posture. **`GET /api/stack-status`** includes **`air_gap_mode`** (boolean).

## Serve (model)

- **Ollama (default):** No Python in agent runtime. `ollama serve`, `ollama pull qwen2.5:14b`. Chump defaults to `OPENAI_API_BASE=http://localhost:11434/v1`, `OPENAI_API_KEY=ollama`, `OPENAI_MODEL=qwen2.5:14b`. Run `./run-discord.sh` or `./run-local.sh`. **Speed:** use `./scripts/setup/ollama-serve-fast.sh` or see [`docs/OLLAMA_SPEED.md`](https://github.com/repairman29/chump/blob/main/docs/OLLAMA_SPEED.md).
- **Ollama (default):** `ollama serve` (port 11434). Set `OPENAI_API_BASE=http://localhost:11434/v1` (default in run scripts). Pull a model: `ollama pull qwen2.5:14b`.

### Keep Chump running (14B on 8000 only)

Minimal setup: one model (14B) on port 8000, no Ollama, no scout/triage, no launchd roles. Start the model and Chump manually when you need them.

1. **.env:** Set `OPENAI_API_BASE=http://localhost:8000/v1` and `OPENAI_MODEL=mlx-community/Qwen2.5-14B-Instruct-4bit` (see `.env.example` M4-max section).
2. **Start the model:** From repo root, `./scripts/setup/restart-vllm-if-down.sh`. If 8000 is down it starts vLLM-MLX 14B and waits until ready (up to 4 min). If 8000 is already up it exits immediately.
3. **Run Chump:** `./run-discord.sh` (Discord) or `./run-local.sh --chump "message"` (CLI). To keep the Discord bot running after closing the terminal: run in **tmux** or **screen** (e.g. `tmux new -s chump && cd ~/Projects/Chump && ./run-discord.sh`), or use Chump Menu → Start.
4. **If 8000 dies (OOM/crash):** Run `./scripts/setup/restart-vllm-if-down.sh` again. Check `logs/vllm-mlx-8000.log` and see [`docs/operations/INFERENCE_STABILITY.md`](https://github.com/repairman29/chump/blob/main/docs/operations/INFERENCE_STABILITY.md) if it keeps crashing.

**Fine-tuning and keeping it steady:** See [`docs/operations/STEADY_RUN.md`](https://github.com/repairman29/chump/blob/main/docs/operations/STEADY_RUN.md) for vLLM/Chump .env tuning, retries, and optional launchd/cron so 8000 and Discord stay up.

## Discord

Create bot at Discord Developer Portal; enable Message Content Intent. Set `DISCORD_TOKEN` in `.env`. Invite bot; it replies in DMs and when @mentioned. `CHUMP_READY_DM_USER_ID`: ready DM + notify target (and hourly updates / "reach out when stuck"). To send a proactive "I'm up" DM on demand (same idea as Mabel's `mabel-explain.sh`), run `./scripts/dev/chump-explain.sh`. `CHUMP_WARM_SERVERS=1`: start Ollama on first message (warm-the-ovens). `CHUMP_PROJECT_MODE=1`: project-focused soul.

**Proactive DMs from Chump and Mabel:** Set your Discord user ID in `CHUMP_READY_DM_USER_ID` (Developer Mode → right‑click your profile → Copy User ID). Use the same ID in both Mac and Pixel `.env`. When each bot connects to Discord it will DM you once: Chump with a "Chump is online and ready" message, Mabel (when `CHUMP_MABEL=1` on Pixel) with "Mabel is online and watching." So: **Mac** `.env`: `DISCORD_TOKEN` (Chump bot) + `CHUMP_READY_DM_USER_ID=<your-id>`. **Pixel** `.env` (Mabel): `DISCORD_TOKEN` (Mabel bot) + `CHUMP_READY_DM_USER_ID=<your-id>` + `CHUMP_MABEL=1`. Restart each bot (or start it) to trigger the ready DM. For one-off DMs without restart: `./scripts/dev/chump-explain.sh` (Mac), `./scripts/dev/mabel-explain.sh` (Pixel or Mac with Mabel env).

**Hourly updates:** Install the hourly-update launchd job (see Roles below) so Chump sends you a brief DM every hour (episode recent, task list, blockers). Requires `CHUMP_READY_DM_USER_ID` and `DISCORD_TOKEN` in `.env`. **Single fleet report:** When Mabel's report round is stable, run **`./scripts/setup/retire-mac-hourly-fleet-report.sh`** on the Mac (or `launchctl bootout gui/$(id -u)/ai.chump.hourly-update-to-discord`). **`!status`** in Discord returns the latest `mabel-report-*.md` from **either** bot when the file exists on that host (see **Single fleet report** above). Chump keeps the notify tool for ad-hoc DMs.

**When you message while Chump is busy:** Set `CHUMP_MAX_CONCURRENT_TURNS=1` (recommended for autopilot). If you message while a turn is in progress, Chump replies that your message is queued and will respond at the next available moment. Messages are stored in `logs/discord-message-queue.jsonl` and processed one-by-one after each turn (no need to retry).

## Heartbeat

**Two scripts:**

- **heartbeat-learn.sh** — Learning-only: runs Chump on a timer (e.g. 8h, 45min interval) with rotating web-search prompts; stores learnings in memory. Needs model + TAVILY_API_KEY. No codebase work.
- **heartbeat-ship.sh** — Product-shipping: portfolio, playbooks, one step per round (ship / review / research / maintain). Default 8h, 5m rounds with cascade. Progress: `chump-brain/projects/{slug}/log.md` and `logs/chump.log`. **Only one instance** (script uses a lockfile; second start exits cleanly). After `cargo build --release` (e.g. after empty-remote or other fixes), restart ship so the new binary is used: `pkill -f heartbeat-ship; nohup bash scripts/dev/heartbeat-ship.sh >> logs/heartbeat-ship.log 2>&1 &`. **Stale lock:** If the lock is held by a dead or wrong process (e.g. a one-off test), run `scripts/setup/ensure-ship-heartbeat.sh` to clear it and start ship; Mabel's patrol does this automatically when the ship log is stale. **Autopilot (short sleep, repeat):** `CHUMP_AUTOPILOT=1 ./scripts/dev/heartbeat-ship.sh` — sleep 5s between rounds instead of 5m; use `AUTOPILOT_SLEEP_SECS=10` for 10s. More rounds = more API/cascade usage. **Environment:** Start the ship heartbeat from repo root (or set `CHUMP_HOME`) so the script can load `.env`; if you run from cron or a minimal env, ensure the script's `CHUMP_HOME` points at the repo and that `.env` exists there (the script sources it). **Preflight FAIL:** If the log shows "Preflight FAIL: no model reachable", the run exited before any rounds. Verify (1) that line is from this run (same startup block in the log); (2) run `./scripts/ci/check-heartbeat-preflight.sh` and `./scripts/ci/check-providers.sh` from the same shell after `source .env`; (3) for cascade, ensure provider keys and scopes are valid (e.g. GitHub needs `models:read`). **Optional flags:** `HEARTBEAT_STRICT_LOG=1` — log a warning when a ship round exits ok but no `chump-brain/projects/*/log.md` was updated this round. `HEARTBEAT_DEBUG=1` — write the last 80 lines of each round's agent output to `logs/heartbeat-ship-round-N.log` for debugging "ok but no log update" runs. **24h autonomy:** Run with `HEARTBEAT_DURATION=24h` for one 24h run (~288 rounds at 5m); when the run ends, start the next with `ensure-ship-heartbeat.sh` or cron so Chump keeps going. Ensure cascade (or local) has enough quota; empty-reply ship rounds are retried once automatically.
- **heartbeat-self-improve.sh** — Work heartbeat: task queue, PRs, opportunity scans, research, **cursor_improve**, tool discovery, **battle QA self-heal**. Round types cycle: work, work, cursor_improve, opportunity, work, cursor_improve, research, work, discovery, battle_qa. Default: **8 min** between rounds (8h, ~60 rounds). Set `HEARTBEAT_INTERVAL=5m` or `3m` to top out; watch logs for `exit non-zero` and back off if rounds fail.
- **heartbeat-cursor-improve-loop.sh** — Runs **cursor_improve** rounds back-to-back (default 8h, **5 min** between rounds, ~96 rounds). Respects **logs/pause**; start/stop from Chump Menu or `pkill -f heartbeat-cursor-improve-loop`. Set `HEARTBEAT_INTERVAL=3m` to top out. Max aggressive self-improve: `HEARTBEAT_INTERVAL=1m HEARTBEAT_DURATION=8h ./scripts/dev/heartbeat-self-improve.sh`; or `HEARTBEAT_QUICK_TEST=1` for 30s interval (2m total). Run in tmux or nohup so it keeps going after you close the terminal.
- **heartbeat-mabel.sh** (runs on Pixel) — Mabel's autonomous heartbeat: patrol (mabel-farmer + Chump heartbeat check), research, report (unified fleet report + notify), intel, **verify** (QA after Chump code changes), peer_sync. Start/stop from Chump Menu → **Mabel (Pixel)** or via SSH. Shared brain: git pull/push to `chump-brain`; optional hybrid inference via `MABEL_HEAVY_MODEL_BASE`. **Deploy and verify:** run `./scripts/setup/deploy-all-to-pixel.sh`, then `diagnose-mabel-model.sh` on the Pixel to confirm model and API.

**What to work on:** The current roadmap is **[`docs/ROADMAP.md`](https://github.com/repairman29/chump/blob/main/docs/ROADMAP.md)** (the ChumpOS arc + weekly-cycle workstreams; prioritized, dated). The file this line used to point at, `docs/archive/strategy-2026-04/ROADMAP-superseded.md`, is exactly what its name says — a superseded snapshot from the 2026-04 strategy, kept for history, not for picking work. **docs/briefs/CHUMP_PROJECT_BRIEF.md** has focus and conventions. Heartbeat, Discord bot, and Cursor agents should read `docs/ROADMAP.md`; edit it to add or check off items.

### Reliable one-shot run (self-improve)

Prereqs: Ollama running (`ollama serve`), model pulled (`ollama pull qwen2.5:14b`), and `cargo build --release` once. Run only one heartbeat process (multiple processes cause duplicate rounds and mixed env).

```bash
pkill -f heartbeat-self-improve
HEARTBEAT_INTERVAL=1m HEARTBEAT_DURATION=8h nohup bash scripts/dev/heartbeat-self-improve.sh >> logs/heartbeat-self-improve.log 2>&1 &
```

Check that rounds succeed: `grep "Round.*: ok" logs/heartbeat-self-improve.log | tail -5`. If you see "Round X: exit non-zero" and connection or model errors in the log, fix env (Ollama 11434, OPENAI_MODEL=qwen2.5:14b) and ensure only one heartbeat is running.

**Auto self-improve (launchd):** To run self-improve on a schedule (e.g. every 8h), copy `scripts/plists/heartbeat-self-improve.plist.example` to `~/Library/LaunchAgents/ai.chump.heartbeat-self-improve.plist`, replace `/path/to/Chump` with your repo path (e.g. `~/Projects/Chump`) and fix StandardOutPath/StandardErrorPath, then run `launchctl load ~/Library/LaunchAgents/ai.chump.heartbeat-self-improve.plist`. Each run executes one full 8h self-improve session. Adjust `StartInterval` (e.g. 86400 for daily). Ensure PATH in the plist includes `~/.local/bin`.

**Discord DM updates from heartbeat:** Set `CHUMP_READY_DM_USER_ID` (your Discord user ID) and `DISCORD_TOKEN` in `.env`. When Chump uses the notify tool during a heartbeat round (e.g. blocked, PR ready, or end-of-run summary), you get a DM. You do not need to run the Discord bot for these DMs.

**Publish autonomy:** With `CHUMP_AUTO_PUBLISH=1`, the self-improve heartbeat and CLI soul allow Chump to push to main and create releases: bump version in `Cargo.toml`, update `CHANGELOG` (move [Unreleased] to the new version), `git tag vX.Y.Z`, `git push origin main --tags`. One release per logical batch; Chump notifies when released. Without it, Chump uses chump/* branches only and never pushes to main.

**Pause / Resume (navbar app):** Chump Menu → **Pause self-improve** creates `logs/pause` so the self-improve heartbeat and the cursor-improve loop skip rounds (they sleep until the file is removed). **Resume self-improve** removes `logs/pause` so rounds run again. Same effect from the shell: `touch logs/pause` to pause, `rm logs/pause` to resume.

**Cursor-improve loop (one round after another):** From the menu: **Start cursor-improve loop (8h)** or **Cursor-improve loop (quick 2m)**. This runs only cursor_improve rounds back-to-back (default **5 min** between rounds). Set `HEARTBEAT_INTERVAL=3m` in .env to top out. Pause/Resume applies to this loop too.

**Mode B: Cloud-Only Heartbeat** — When the Mac is sleeping or Ollama/8000 is down, run `./scripts/dev/heartbeat-cloud-only.sh`. It sources `.env`, sets `CHUMP_CASCADE_ENABLED=1` and `CHUMP_CLOUD_ONLY=1`, unsets `OPENAI_API_BASE`, and runs the same self-improve loop as `heartbeat-self-improve.sh` but **skips local model preflight**. Rounds use the provider cascade only (Groq, Cerebras, Mistral, etc.). Use from a cron job on the Pixel or a headless host; ensure `.env` has cascade slot keys (e.g. `CHUMP_PROVIDER_1_KEY`, `CHUMP_PROVIDER_2_KEY`). Logs: `logs/heartbeat-self-improve.log`.

**Check every 20m and tune for peak:** Run `./scripts/ci/check-heartbeat-health.sh` every 20 minutes to see recent ok vs fail counts and a recommendation (back off, hold, or try a shorter interval). To automate: copy `scripts/plists/heartbeat-health-check.plist.example` to `~/Library/LaunchAgents/ai.chump.heartbeat-health-check.plist`, replace `/path/to/Chump` with your repo path, then `launchctl load ~/Library/LaunchAgents/ai.chump.heartbeat-health-check.plist`. It runs the check every 20 min and appends to `logs/heartbeat-health.log`. Use the recommendations and adjust `HEARTBEAT_INTERVAL` (then restart the heartbeat) until you see mostly "all recent rounds ok" and optional "try 5m/3m to top out".

**Push to Chump repo and self-reboot:** To let the bot push to the Chump repo and restart with new capabilities: set `CHUMP_GITHUB_REPOS` (include the Chump repo, e.g. `owner/Chump`), `GITHUB_TOKEN`, and `CHUMP_AUTO_PUSH=1`. The bot can then git_commit and git_push to chump/* branches. After pushing changes that affect the bot (soul, tools, src), the bot may run `scripts/setup/self-reboot.sh` to kill the current Discord process, rebuild release, and start the new bot. You can also say "reboot yourself" or "self-reboot" in Discord to trigger it. Script: `scripts/setup/self-reboot.sh` (invoked as `nohup bash scripts/setup/self-reboot.sh >> logs/self-reboot.log 2>&1 &`). Optional: `CHUMP_SELF_REBOOT_DELAY=10` (seconds before kill, default 10). Logs: `logs/self-reboot.log`, `logs/discord.log`.

### GitHub credentials and git push

**Why does "Git push failed due to authentication issue" or "Need valid token" keep happening?** The bot uses the token in `.env` to push. If that token is missing, wrong scope, not SSO-authorized for the org, or expired, every push will fail. **One-time fix so it stops:** (1) Create a PAT: GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) → generate with **repo** scope; for org repos click **Configure SSO** and authorize. (2) In Chump's `.env` set `GITHUB_TOKEN=<token>`. (3) Restart the Discord bot so it loads the new token. After that, the bot can push and the message stops.

The **git_push** tool (and clone/pull) use `GITHUB_TOKEN` from `.env`. Before each push, the tool sets the repo's `origin` remote to `https://x-access-token:<token>@github.com/<owner>/<repo>.git` so push works even when the repo was created without credentials (e.g. by a script). The token must have push access to the repo.

- **Classic PAT:** Needs the **repo** scope. Create or edit at GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic).
- **Fine-grained PAT:** Repository access must include the repo (or All repositories); Permissions → Repository permissions → **Contents** = Read and write.
- **Organization repos:** If the repo is under an org with SAML SSO, the token must be **authorized for SSO** for that org: in the token list, click **Configure SSO** or **Authorize** next to the org and complete the flow. Without that, push returns 403 even if the token has admin scope.
- **403 "Permission denied":** Check scope (repo or Contents write), SSO authorization for the org, and that the token in `.env` is the one with access. If the tool returns "Set GITHUB_TOKEN in .env for HTTPS push", add or fix the token in `.env`. After changing the token in `.env`, restart the Discord bot (or the process that runs Chump) so it loads the new token.

**Manual pushes from the same machine:** If you run `git push` from the shell after sourcing Chump's `.env`, git may use `GITHUB_TOKEN` and fail (e.g. 403 or invalid token). Alternatives: (1) Use the GitHub CLI: run `gh auth setup-git`, then for that push unset the token so git uses gh's credential helper: `unset GITHUB_TOKEN; git -C repos/<owner>_<repo> push origin main`. (2) Use SSH: set remote to `git@github.com:owner/repo.git`, run `ssh-add ~/.ssh/id_ed25519` (or your key), then push. The bot's git_push is unaffected; it always uses the token from `.env` when set.

**You're logged in to GitHub but push still returns 403:** Git is using the token from `.env` (or a token embedded in the remote URL) instead of your gh login. Use your logged-in account for the push: run `gh auth setup-git` once, then for each push from the Chump repo run `unset GITHUB_TOKEN; git push origin main`. That forces git to use the keyring/gh credential (your logged-in account) so push succeeds.

## Keep-alive (MacBook)

`./scripts/dev/keep-chump-online.sh` (if present) can ensure Ollama, optional embed server (18765), and Chump Discord stay up. For "always on" on a MacBook, use launchd or run `ollama serve` in the background. Logs: `logs/keep-chump-online.log`.

## Roles (should be running in the background)

Farmer Brown and the other roles (Heartbeat Shepherd, Memory Keeper, Sentinel, Oven Tender) **should be running** on a schedule so the stack stays healthy, Chump stays online, and heartbeat/models are tended. Use the **Chump Menu → Roles** tab to run each script once or open logs; for 24/7 help, schedule them with launchd or cron as below.

**Bring up the whole stack (after reboot or updates):** Run `./scripts/dev/bring-up-stack.sh` to build release, install/load the five launchd roles, run keep-chump-online once (Ollama + optional embed/Discord), and start the self-improve and cursor-improve heartbeats. With `PULL=1 ./scripts/dev/bring-up-stack.sh` you git pull first, then build and start. With `BUILD_ONLY=1` only `cargo build --release` runs. See script header for env (ROLES=0, KEEPALIVE=0, HEARTBEATS=0 to skip parts). After the bot pushes code, `scripts/setup/self-reboot.sh` restarts only the Discord bot (kill, build, start); use bring-up-stack if you want the full stack restarted (e.g. after you pull locally).

## Farmer Brown (diagnose + fix)

**Farmer Brown** is a Chump keeper that diagnoses the stack (model, worker, embed, Discord), kills stale processes when a port is in use but the service is unhealthy, then runs `keep-chump-online.sh` to bring everything up.

- **Diagnose only:** `FARMER_BROWN_DIAGNOSE_ONLY=1 ./scripts/dev/farmer-brown.sh` — prints and logs status for each component (up/down/stale); no starts or kills.
- **Diagnose + fix once:** `./scripts/dev/farmer-brown.sh`
- **Loop (e.g. every 2 min):** `FARMER_BROWN_INTERVAL=120 ./scripts/dev/farmer-brown.sh`
- **launchd:** Copy `scripts/plists/farmer-brown.plist.example` to `~/Library/LaunchAgents/dev.chump.farmer-brown.plist`, replace the path placeholder with your repo path (e.g. ~/Projects/Chump), then `launchctl load ~/Library/LaunchAgents/dev.chump.farmer-brown.plist`. Runs every 120s by default.

Uses the same env as keep-chump-online (`CHUMP_KEEPALIVE_EMBED`, `CHUMP_KEEPALIVE_DISCORD`, `CHUMP_KEEPALIVE_WORKER`, `WARM_PORT_2`, `.env`). Logs: `logs/farmer-brown.log`. If `CHUMP_HEALTH_PORT` is set, diagnosis includes Chump health JSON.

## Hourly update to Discord

When you want a brief DM from Chump every hour (what he did recently, tasks, blockers): install the hourly-update launchd job. Run `./scripts/setup/install-roles-launchd.sh` (it includes `hourly-update-to-discord.plist.example`). Or copy `scripts/plists/hourly-update-to-discord.plist.example` to `~/Library/LaunchAgents/ai.chump.hourly-update-to-discord.plist`, replace `/path/to/Chump` and `/Users/you`, then `launchctl load ...`. Requires `CHUMP_READY_DM_USER_ID` and `DISCORD_TOKEN` in `.env`. Logs: `logs/hourly-update.log`. When Mabel's report round is stable, unload this job so Mabel's report is the single fleet report: `launchctl bootout gui/$(id -u)/ai.chump.hourly-update-to-discord` (see "Single fleet report" in Discord section).

## Other roles (shepherd, memory keeper, sentinel, oven tender)

Chump Menu **Roles** tab shows all five roles; Run once and Open log from there. To **auto-start all five** on this Mac, run once from the Chump repo:

```bash
./scripts/setup/install-roles-launchd.sh
```

This installs launchd plists into `~/Library/LaunchAgents` (with your repo path), loads them, and they run at: Farmer Brown every 2 min, Heartbeat Shepherd every 15 min, Memory Keeper every 15 min, Doc Keeper every 6 h, Sentinel every 5 min, Oven Tender every 1 hour. To stop: `./scripts/setup/unload-roles-launchd.sh` or unload each plist. Plist examples: `scripts/*.plist.example`; edit and re-run the install script if you need different intervals. To keep them helping in the background manually, schedule each as below.

- **Heartbeat Shepherd** (`./scripts/dev/heartbeat-shepherd.sh`): Checks last run in `logs/heartbeat-learn.log`; if the last round failed, optionally runs one quick round (`HEARTBEAT_SHEPHERD_RETRY=1`). Schedule via cron/launchd every 15–30 min. Logs: `logs/heartbeat-shepherd.log`.
- **Memory Keeper** (`./scripts/dev/memory-keeper.sh`): Checks memory DB exists and is readable; optionally pings embed server. Does not edit memory. Logs: `logs/memory-keeper.log`. Env: `MEMORY_KEEPER_CHECK_EMBED=1` to also check embed.
- **Doc Keeper** (`./scripts/dev/doc-keeper.sh`): **Read-only** doc hygiene (unlike heartbeats that use the LLM). Scans Markdown under `docs/` (and `.cursor/rules` when present) for **broken relative links**; resolves both doc-relative and repo-root paths (`scripts/…`, `src/…`, `../ChumpMenu/`). Logs: `logs/doc-keeper.log`. Optional: `DOC_KEEPER_STALE_SCAN=1` with `DOC_KEEPER_STALE_TERMS` / `DOC_KEEPER_FAIL_ON_STALE` to grep for legacy terminology. Does **not** auto-edit roadmaps. Schedule: `scripts/plists/doc-keeper.plist.example` (default 6 h), or `./scripts/setup/install-roles-launchd.sh` (includes Doc Keeper).
- **Doc hygiene (LLM editor):** `heartbeat-self-improve.sh` runs **`doc_hygiene`** rounds (twice per full cycle) using the shared prompt in `scripts/eval/doc-hygiene-round-prompt.bash` — Chump runs `doc-keeper.sh`, then edits `docs/`, `AGENTS.md`, and `.cursor/rules` with **patch_file** / **write_file**. For a **docs-only** marathon without other round types, use `./scripts/dev/heartbeat-doc-hygiene-loop.sh` (log: `logs/heartbeat-doc-hygiene-loop.log`). Uses `CHUMP_ROUND_PRIVACY=safe` when cascade is on (same as `cursor_improve`).
- **Sentinel** (`./scripts/dev/sentinel.sh`): When Farmer Brown or heartbeat show recent failures, writes `logs/sentinel-alert.txt` with a short summary and last log lines. Optional: `NTFY_TOPIC` (ntfy send), `SENTINEL_WEBHOOK_URL` (POST JSON). **Self-heal:** set `SENTINEL_SELF_HEAL_CMD` to a command to run when the alert fires (e.g. `./scripts/dev/farmer-brown.sh` locally, or `ssh user@my-mac "cd ~/Projects/Chump && ./scripts/dev/farmer-brown.sh"` to trigger repair on the Chump host). Runs in background; output in `logs/sentinel-self-heal.log`.
- **Oven Tender** (`./scripts/dev/oven-tender.sh`): If Ollama is not warm, runs `warm-the-ovens.sh` (starts `ollama serve`). Schedule via cron/launchd (e.g. 7:45) so Chump is ready by a chosen time. Logs: `logs/oven-tender.log`.

## What slows rounds (speed)

Round latency is affected by: **prompt size** (system prompt + assembled context: memory, episodes, health DB, file watch); **number of context messages** (recent conversation); **model** (local vs remote, model size); **network** (if API is remote). To speed up: trim context assembly (e.g. fewer episodes, shorter memory snippets), use a smaller/faster model for simple turns, reduce `CHUMP_MAX_CONTEXT_MESSAGES`, and ensure the model server is local (Ollama/vLLM on same machine). See [`docs/OLLAMA_SPEED.md`](https://github.com/repairman29/chump/blob/main/docs/OLLAMA_SPEED.md) and [`docs/operations/INFERENCE_STABILITY.md`](https://github.com/repairman29/chump/blob/main/docs/operations/INFERENCE_STABILITY.md) for model-side tuning.

## Retention and audit

Recommended retention for ops and compliance (adjust to local policy):

- **logs/chump.log** — 30 days (messages, replies, CLI runs, tool_approval_audit). Rotate or prune (e.g. cron: keep last 30 days).
- **tool_health_db** (in `sessions/chump_memory.db`, table `chump_tool_health`) and **session DBs** — 90 days. Optional prune script or manual cleanup of old rows.
- **Approval/audit** — Tool approval decisions are in chump.log (event `tool_approval_audit`). Retain 365 days if required for compliance; use the same log rotation or a dedicated audit log copy.

Append-only policy for audit: do not edit or delete lines in chump.log; only rotate or archive by date. Optional: `logrotate` (Linux) or a simple cron wrapper around `find logs/ -mtime +N -delete` if you want retention — keep it explicit and documented.

## Chief of staff weekly snapshot

To feed COS planning from the task DB without opening Discord:

- **Run once:** `./scripts/eval/generate-cos-weekly-snapshot.sh` — writes `logs/cos-weekly-YYYY-MM-DD.md` (uses `sqlite3` on `sessions/chump_memory.db`; override DB with first arg or set `CHUMP_HOME`).
- **Schedule:** `./scripts/setup/install-roles-launchd.sh` installs **`ai.chump.cos-weekly-snapshot`** (Monday 08:00) from `scripts/plists/cos-weekly-snapshot.plist.example`, or add your own cron/launchd; log to `logs/cos-weekly-launchd.*.log`.
- **Agent context:** Heartbeat rounds `work`, `cursor_improve`, `discovery`, `opportunity` auto-include the newest `logs/cos-weekly-*.md` in assembled context when the file exists. Env: `CHUMP_INCLUDE_COS_WEEKLY` (`0` off, `1` always on), `CHUMP_COS_WEEKLY_MAX_CHARS` (default 8000).

For prioritized product context and story backlog, see the published Roadmap chapter (`./roadmap.md`).

## Battle QA (500 queries)

`./scripts/ci/battle-qa.sh` runs 500 user queries against Chump CLI and reports pass/fail. Use to harden before release.

- **Once:** `./scripts/ci/battle-qa.sh`
- **Smoke (50):** `BATTLE_QA_MAX=50 ./scripts/ci/battle-qa.sh`
- **Until ready:** `BATTLE_QA_ITERATIONS=5 ./scripts/ci/battle-qa.sh` — re-run up to 5 times; exit 0 when all pass. Fix failures (see `logs/battle-qa-failures.txt`) between runs.

Requires Ollama on 11434. Logs: `logs/battle-qa.log`, `logs/battle-qa-failures.txt`. **Live tail** (battle QA + web): `./scripts/eval/tail-model-dogfood.sh`. See [`docs/BATTLE_QA.md`](https://github.com/repairman29/chump/blob/main/docs/BATTLE_QA.md). To run tests against **default** (Ollama) or **max M4** (vLLM-MLX 8000) without editing .env: `./scripts/ci/run-tests-with-config.sh <default|max_m4> battle-qa.sh` — see [`docs/BATTLE_QA.md`](https://github.com/repairman29/chump/blob/main/docs/BATTLE_QA.md) “Testing against a specific config.”

## Env reference

| Env                                           | Default / note             |
| --------------------------------------------- | -------------------------- |
| `OPENAI_API_BASE`                             | Model server URL           |
| `OPENAI_API_KEY`                              | `not-needed` local         |
| `OPENAI_MODEL`                                | `qwen2.5:14b` (Ollama); `default` for vLLM single-model |
| `CHUMP_FALLBACK_API_BASE`                     | Fallback model URL         |
| `CHUMP_DELEGATE`                              | `1` = delegate tool (summarize, extract, classify, validate) |
| `CHUMP_DELEGATE_PREPROCESS`                   | `1` = enable DelegatePreProcessorWrapper; compresses tool outputs over threshold via worker model before returning to main model. Requires `CHUMP_DELEGATE_CONCURRENT=1` (concurrent LLM calls must be safe). Fail-open: raw output returned if worker summarise fails. |
| `CHUMP_DELEGATE_PREPROCESS_CHARS`             | Character threshold above which DelegatePreProcessorWrapper compresses output (default 4000). |
| `CHUMP_DELEGATE_CONCURRENT`                   | `1` = concurrent LLM calls permitted (required co-flag for DelegatePreProcessorWrapper). |
| `CHUMP_WORKER_API_BASE`, `CHUMP_WORKER_MODEL` | Worker endpoint/model      |
| `CHUMP_CONTEXT_SUMMARY_THRESHOLD`             | When set (e.g. 6000), oldest messages are summarized via delegate when approx tokens exceed this; 0 = no summarize-before-trim |
| `CHUMP_CONTEXT_MAX_TOKENS`                    | Hard ceiling for context (system + messages); 0 = no limit     |
| `CHUMP_TOOL_EXAMPLES`                         | Override for worked tool-call examples in system prompt        |
| `CHUMP_HEARTBEAT_TYPE`                        | work / research / cursor_improve; assemble_context injects only relevant sections; unset = all sections (CLI) |
| `CHUMP_READ_FILE_MAX_CHARS`                   | Files over this get delegate auto-summary + last 500 chars (default 4000) |
| `CHUMP_REPO`, `CHUMP_HOME`                    | Repo path (tools + cwd)    |
| `CHUMP_BRAIN_PATH`                            | Brain wiki root            |
| `CHUMP_BRAIN_AUTOLOAD`                        | Comma-separated paths relative to the brain dir (e.g. `self.md,rust-codebase-patterns.md`) injected into agent context each turn. Use for small models that skip `memory_brain` calls. Dogfood default in `scripts/eval/dogfood-run.sh`. |
| `CHUMP_READY_DM_USER_ID`                      | Ready DM when bot connects; notify DMs (Discord + heartbeat when DISCORD_TOKEN set) |
| `CHUMP_EXECUTIVE_MODE`                        | No allowlist, 300s timeout |
| `CHUMP_RATE_LIMIT_TURNS_PER_MIN`              | Per-channel cap (0=off)    |
| `CHUMP_MAX_CONCURRENT_TURNS`                  | Global cap (0=off); 1 recommended for autopilot |
| `CHUMP_MAX_MESSAGE_LEN`                       | 16384                      |
| `CHUMP_MAX_TOOL_ARGS_LEN`                     | 32768                      |
| **Performance**                               | See [`docs/operations/PERFORMANCE.md`](https://github.com/repairman29/chump/blob/main/docs/operations/PERFORMANCE.md) for review and tuning. |
| `CHUMP_EMBED_URL`                             | Embed server (optional)    |
| `CHUMP_PAUSED`                                | `1` = kill switch          |
| `CHUMP_AUTO_PUBLISH`                         | `1` = may push to main and create releases (bump Cargo.toml, CHANGELOG, tag, push --tags). Heartbeat uses this for publish autonomy. |
| `CHUMP_TOOL_CIRCUIT_FAILURES`                | Consecutive failures before per-tool circuit opens (default 3). |
| `CHUMP_TOOL_CIRCUIT_COOLDOWN_SECS`           | Seconds a tool is unavailable after circuit opens (default 60). |
| `CHUMP_BROWSER_AUTOAPPROVE`                   | `1` = browser tool runs without per-action approval gate. Alternative: add `browser` to `CHUMP_TOOLS_ASK` for explicit approval UI before each action. If neither is set, browser actions are refused at runtime. |
| `SLACK_APP_TOKEN`                             | Socket Mode token (xapp-…) — required for `chump --slack`. |
| `SLACK_BOT_TOKEN`                             | Bot OAuth token (xoxb-…) — used for Slack REST API calls (chat.postMessage, etc.). |
| `SLACK_API_BASE`                              | Override Slack REST base URL (default `https://slack.com/api`). Useful for local testing. |
| `CHUMP_AIR_GAP_MODE`                          | `1` / `true` = disable `web_search` and `read_url` tools; see [Air-gap mode](#air-gap-mode-chump_air_gap_mode) section below |
| `CHUMP_CLUSTER_MODE`                          | `1` = enable cluster/fleet swarm routing via `CHUMP_WORKER_API_BASE`; unset = local path |
| `CHUMP_BELIEF_TOOL_BUDGET`                    | `1` = tighten tool call budget under high task epistemic uncertainty (WP-6.1 precision-controller hook) |
| `CHUMP_LIGHT_CONTEXT`                         | `1` = always slim context (12 tools, minimal blocks); `auto` = dynamic (scales with precision regime); unset = always full |
| `CHUMP_LIGHT_INCLUDE_STATE_DB`                | `1` = include ego/mood lines from state DB when light mode is active (default off for speed) |
| `CHUMP_LIGHT_INCLUDE_BRAIN_AUTOLOAD`          | `1` = include brain autoload snippets in prompt when light mode is active (default off) |
| `CHUMP_LIGHT_CHAT_HISTORY_MESSAGES`           | Sliding-window cap for user/assistant messages in light interactive mode (default 16, clamped 4–64) |
| `CHUMP_LIGHT_COMPLETION_MAX_TOKENS`           | Max tokens for completions in light interactive mode (default 1024, clamped 256–8192) |
| `CHUMP_COMPLETION_MAX_TOKENS`                 | Override max tokens for all completions regardless of mode (min 64, max 32768); takes precedence over light cap |
| `CHUMP_THINKING_XML`                          | `0` / `false` = force off; `1` / `true` = force on; unset = off in light interactive, on for heartbeat/agents |
| `CHUMP_TOOL_PROFILE`                          | `core` (default) / `coding` / `full` — selects which tool surface tier is registered at startup |
| `CHUMP_WEB_HTTP_TRACE`                        | `1` = attach `tower_http::TraceLayer` to `/api/*` routes for HTTP request spans (verbose; pair with `RUST_LOG`) |
| `CHUMP_SPECULATIVE_BATCH`                     | `0` = disable speculative execution around ≥3-tool batches; unset = enabled. See `src/agent_loop/types.rs` and `ADR-001`. |
| `CHUMP_SPECULATIVE_SURPRISE_DELTA_MAX`        | Max surprisal EMA delta before a speculative batch is rolled back (default `0.25`). See `src/speculative_execution.rs`. |
| `CHUMP_SANDBOX_SPECULATION`                   | `1` = speculative tool batches run in an isolated git worktree sandbox; changes are applied or discarded on commit/rollback. Off by default. |
| **Feature gates**                             | Enable optional tool surfaces and runtime modes. |
| `CHUMP_SANDBOX_ENABLED`                       | `1` = enable `sandbox` tool (shell commands run in isolated git worktree). Off by default — worktree creation has disk cost. |
| `CHUMP_SCREEN_VISION_ENABLED`                 | `1` = enable `screen_vision` tool. Requires `screencapture` (macOS) or ADB (Android). Off by default. |
| `CHUMP_SPAWN_WORKERS_ENABLED`                 | `1` = enable `spawn_worker` tool. Workers run as ephemeral sub-agents with restricted tools in isolated worktrees. |
| `CHUMP_MULTI_REPO_ENABLED`                    | `1` = enable `set_working_repo` tool for multi-repo mode. Allows switching the active repo root per session. |
| `CHUMP_FLEET_REPORT_ROLE`                     | `notify_only` = hourly Discord update script no-ops (Mabel won't send fleet reports). Lets you silence fleet noise without touching launchd. |
| `CHUMP_ALLOW_MAIN_WORKTREE`                   | `1` = allow `gap-claim.sh` to run from main repo root (default requires a linked worktree). Bootstrapping only — see `CLAUDE.md`. |
| `CHUMP_GAP_CHECK`                             | `0` = bypass pre-push gap-preflight hook. Use when gap IDs in commit messages cause false positives (cleanup commits). |
| `CHUMP_LEASE_CHECK`                           | `0` = bypass lease-collision pre-commit check. |
| `CHUMP_GAPS_LOCK`                             | `0` = bypass gaps.yaml discipline check (allows `claimed_by:` / `status: in_progress` writes; use when testing hook behavior). |
| `CHUMP_SESSION_ID`                            | Explicit session ID for lease scoping. Overrides `$CLAUDE_SESSION_ID`. See `CLAUDE.md` §Session ID resolution. |
| `CHUMP_NOTIFY_INTERRUPT_EXTRA`                | Comma-separated extra channels for high-priority COS decision log entries when `CHUMP_INTERRUPT_NOTIFY_POLICY=restrict`. |
| `CHUMP_INTERRUPT_NOTIFY_POLICY`               | `restrict` = only `[COS]`-tagged interrupts create decision log entries; unset = all interrupts. |
| `TAVILY_API_KEY`                              | Web search                 |

## vLLM-MLX on 8000 (max mode) and Python crash recovery

The default model on 8000 is **14B** (`mlx-community/Qwen2.5-14B-Instruct-4bit`), which runs on typical Apple Silicon without Metal OOM. Start with `./serve-vllm-mlx.sh`.

- **Restart 8000 after a crash:** Chump Menu → **Start** next to 8000 (vLLM-MLX), or run `./scripts/setup/restart-vllm-if-down.sh`. Oven Tender (when scheduled via launchd) will also restart vLLM if 8000 is down.
- **Defaults in serve-vllm-mlx.sh** are conservative (max_num_seqs=1, max_tokens=8192, cache 15%). If runs are stable, you can override: `VLLM_MAX_NUM_SEQS=2 VLLM_MAX_TOKENS=16384 ./serve-vllm-mlx.sh`.
- **Shed load + GPU tuning:** To free GPU/RAM and squeeze more from the MacBook, use the **shed-load** role (runs Enter Chump mode every 2 h) and tune vLLM env vars. See [`docs/operations/INFERENCE_STABILITY.md`](https://github.com/repairman29/chump/blob/main/docs/operations/INFERENCE_STABILITY.md) for OOM investigation and tuning.
- **Heartbeats on 8000** use longer intervals and a shared lock; see `scripts/dev/env-max_m4.sh`.

**Other models**  
- **7B:** `VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit ./serve-vllm-mlx.sh` — lightest.
- **20B:** `VLLM_MODEL=mlx-community/gpt-oss-20b-MXFP4-Q4 ./serve-vllm-mlx.sh` — different family; try if 14B is too small.

Set `OPENAI_MODEL` in `.env` to the same model name so Chump uses it.

## Troubleshooting

**Bot not working?** Run `./scripts/ci/check-discord-preflight.sh` from repo root. It checks: `DISCORD_TOKEN` in `.env`, no duplicate bot running, and model server (Ollama at 11434 by default, or OPENAI_API_BASE port). Fix any FAIL, then `./run-discord.sh`. For Ollama: `ollama serve && ollama pull qwen2.5:14b`. If the bot starts but doesn’t reply: ensure the bot is invited, Message Content Intent is enabled in the Discord Developer Portal, and the model server is up.

- **Connection closed / 5xx:** Restart model server; check `CHUMP_FALLBACK_API_BASE` if using fallback.
- **When vLLM crashes (OOM):** Run `./scripts/dev/capture-oom-context.sh` (and optionally `./scripts/dev/list-heavy-processes.sh`) to capture context for the next crash; then see [`docs/operations/INFERENCE_STABILITY.md`](https://github.com/repairman29/chump/blob/main/docs/operations/INFERENCE_STABILITY.md) for the full OOM runbook.
- **Python crashed (Metal OOM), Mac stayed up:** Restart vLLM with Chump Menu → Start 8000 or `./scripts/setup/restart-vllm-if-down.sh`. Schedule Oven Tender (launchd) so 8000 is restarted automatically when down.
- **Python keeps crashing or 14B never finishes loading:** If 14B exits during “Fetching 10 files” / load (e.g. “leaked semaphore” and restarts in `logs/vllm-mlx-8000.log`), kill all vLLM (`pkill -f “vllm-mlx serve”`), then start once by hand and watch: `./serve-vllm-mlx.sh`. If it still exits during load, try CPU fallback: `MLX_DEVICE=cpu ./serve-vllm-mlx.sh` (slower but avoids Metal init bugs). While debugging, unload Oven Tender so it doesn’t restart on top of you: `launchctl bootout gui/$(id -u)/ai.chump.oven-tender`. See [`docs/operations/INFERENCE_STABILITY.md`](https://github.com/repairman29/chump/blob/main/docs/operations/INFERENCE_STABILITY.md) for the OOM investigation runbook.
- **Port in use but not responding (stale process):** Run `./scripts/dev/farmer-brown.sh` — it will diagnose, kill stale processes on 11434/18765 if needed, then run keep-chump-online to bring services back up.
- **Memory:** Embed server can OOM with large models; use smaller main model or in-process embeddings (`--features inprocess-embed`, unset `CHUMP_EMBED_URL`).
- **SQLite missing:** Memory uses JSON fallback; state/episode/task/schedule need `sessions/` writable.
- **Pause:** Create `logs/pause` or set `CHUMP_PAUSED=1`; bot replies "I'm paused."
- **"Blocked: cannot proceed with deleting clone directory under repos/":** Chump tried to remove a repo dir (e.g. to fix a broken clone) but `run_cli` blocks `rm` under `repos/` for safety. You can fix it: from the Chump repo root run `rm -rf repos/owner_name` (e.g. `rm -rf repos/repairman29_chump-chassis`). Then tell Chump to re-clone or continue; it can run `github_clone_or_pull` again.

---

## Vercel Web Analytics & Product-Repo Trunk Sentinel Checks (`PRODUCT-376`, `PRODUCT-380`)

`scripts/ops/fleet-health-sentinel.sh` includes two product-surface monitors:

1. **Daily Vercel Web Analytics check (`PRODUCT-376`, `--check-sites` / `CHUMP_SENTINEL_CHECK_SITES=1`):**
   - Hits `https://<site>/_vercel/insights/script.js` on every live Vercel Analytics site in `SITES.md` (`jeffadkins.dev`, `jeffadkins.me`, `chooseotherwise.org`, `beast-mode.dev`, `echeo.ai`, `playsmuggler.com`, `peakvinyl.club`, `shopolive.xyz`; configurable via `CHUMP_SENTINEL_INSIGHTS_SITES`) and asserts HTTP `200`.
   - When `VERCEL_TOKEN` is set, also queries `https://api.vercel.com/v9/projects/<site>` and verifies `webAnalytics.enabledAt` is populated.
   - If a site returns `404` or `webAnalytics.enabledAt` is unset, the sentinel pages the operator with the exact one-line remediation recipe:
     ```bash
     vercel api '/web/insights/toggle?projectId=...&teamId=' -X POST -F value=true && vercel redeploy
     ```
2. **Product-repo trunk CI monitor (`PRODUCT-380` AC3, `--check-product-trunks` / `CHUMP_SENTINEL_CHECK_PRODUCT_TRUNKS=1`):**
   - Checks the latest `main` branch workflow run for `repairman29/olive` (configurable via `CHUMP_SENTINEL_PRODUCT_REPOS`) via `gh run list --repo repairman29/olive --branch main --limit 1 --json conclusion,headSha,url`.
   - Emits a halt-severity board page (`product_trunk_red`) within one hour whenever `repairman29/olive` `main` goes red (`conclusion=failure|timed_out|startup_failure|action_required`), matching Chump's own trunk-red alerting.
