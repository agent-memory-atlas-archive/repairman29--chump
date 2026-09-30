# Discord configuration (current)

Summary of how Discord is wired and what is configured by default.

## Token and env

| Source | What's configured |
|--------|-------------------|
| **Required** | `DISCORD_TOKEN` — bot token from [Discord Developer Portal](https://discord.com/developers/applications) → your app → Bot → Reset Token. |
| **Where** | `.env` in the Chump repo root (copy from `.env.example`). Not committed. |
| **Load order** | `run-discord.sh` and `run-discord-ollama.sh` source `.env` then export `CHUMP_HOME`; Rust `main` loads `.env` from current dir, then `runtime_base()/.env` (CHUMP_HOME), then executable dir. |

No other Discord-specific env vars are required. Optional: `CHUMP_READY_DM_USER_ID`, `CHUMP_NOTIFY_FULLY_ARMORED`, `CHUMP_WARM_SERVERS`, `CHUMP_PROJECT_MODE` (see `.env.example` and OPERATIONS.md).

## Gateway intents (code)

In `src/discord.rs`, the client is built with:

- **Serenity** `Client::builder(token, intents)` with:
  - `GatewayIntents::non_privileged()` (guilds, guild members, etc.)
  - `GatewayIntents::MESSAGE_CONTENT` — **must be enabled in the Developer Portal** (Bot → Privileged Gateway Intents → Message Content Intent ON)
  - `GatewayIntents::DIRECT_MESSAGES`

So the bot is configured to read message content (required for replies) and DMs. No other intents are requested in code.

## When the bot replies

- **DMs:** Always (if message content is not empty).
- **Guild channels:** Only when the bot is **@mentioned** (or the message is a DM). Other guild messages are ignored.

No slash commands; it's mention-based in servers.

## Model and API (default when using run scripts)

Set by `run-discord.sh` and `run-discord-ollama.sh` (unless overridden in `.env`):

- `OPENAI_API_BASE` = `http://localhost:11434/v1` (Ollama)
- `OPENAI_API_KEY` = `ollama`
- `OPENAI_MODEL` = `qwen2.5:14b`

So by default Discord uses **Ollama** at 11434 with **qwen2.5:14b**. Override in `.env` to use another server/model.

## Run scripts

**Recommended: Use the unified control script**

| Script | Purpose |
|--------|--------|
| `scripts/discord.sh` | Unified Discord bot control: `start`, `stop`, `restart`, `status`. Auto-selects variant (Ollama, vLLM, mistral.rs) based on .env and system config. |

**Individual scripts (for advanced use)**

| Script | Purpose |
|--------|--------|
| `run-discord.sh` | Sources `.env`, sets `CHUMP_HOME` to repo root, exports Ollama defaults, runs `cargo run -- --discord`. Exits if `DISCORD_TOKEN` unset or if another `chump`/legacy `rust-agent` Discord process is running. |
| `run-discord-ollama.sh` | Same as above; also runs a preflight (Ollama reachable) and exits with instructions if not. |
| `run-discord-full.sh` | Builds with `inprocess-embed` feature for full tools (repo access, semantic search, battle QA). |
| `scripts/ci/check-discord-preflight.sh` | Checks: `.env` exists, `DISCORD_TOKEN` set, no duplicate bot process, model server reachable (Ollama 11434 or `OPENAI_API_BASE`). |

## ChumpMenu (menu bar app)

- **Start Discord:** Runs `cd '<repoPath>' && nohup ./run-discord.sh >> '<repoPath>/logs/discord.log' 2>&1 &` with `currentDirectoryURL` and `CHUMP_HOME` = `repoPath`. Does **not** source `.env` in the Swift process; `run-discord.sh` sources it when the script runs.
- **Stop Discord:** `pkill -f "chump.*--discord"` (and `pkill -f "rust-agent.*--discord"` if upgrading from older builds).
- **Repo path:** Stored in `UserDefaults` under key `ChumpRepoPath`; if unset, falls back to **defaultRepoPath** in code: `~/Projects/Chump`. Change it in the menu only if your clone is elsewhere.
- **PATH:** ChumpMenu adds `/opt/homebrew/bin`, `~/.cargo/bin`, `~/.local/bin` to `PATH` when starting the script.

So when started from ChumpMenu, Discord runs with CWD and `CHUMP_HOME` equal to the chosen repo path; `.env` is loaded by `run-discord.sh` from that repo.

## Session and logs (Rust)

- **Sessions:** Per-channel Discord sessions under `runtime_base()/sessions/discord` (where `runtime_base()` is `CHUMP_HOME` or `CHUMP_REPO` or current dir). Created on first use.
- **Logs:** `chump_log` writes to `runtime_base()/logs/chump.log`; ChumpMenu shows activity from `repoPath/logs/discord.log` (stdout/stderr of `run-discord.sh`).

## Optional limits and concurrency

- **Rate limit:** `CHUMP_RATE_LIMIT_TURNS_PER_MIN` (per channel; 0 = off).
- **Concurrent turns:** `CHUMP_MAX_CONCURRENT_TURNS` (0 = no cap, 1..32 = semaphore).
- **Kill switch:** `logs/pause` file or `CHUMP_PAUSED=1` → bot replies "I'm paused." without calling the model.
- **Message length:** Enforced by `limits::check_message_len` (configurable via env; see limits.rs).

## Checklist: what you must do

1. **Developer Portal:** Create/use an application, add a Bot, copy the token. Under Bot → Privileged Gateway Intents, enable **Message Content Intent**.
2. **Repo:** In Chump repo root, `cp .env.example .env` and set `DISCORD_TOKEN=<token>`.
3. **Model:** Run Ollama (e.g. `ollama serve && ollama pull qwen2.5:14b`) or set `OPENAI_API_BASE`/`OPENAI_MODEL` in `.env` to another server.
4. **Start:** From repo root run `./run-discord.sh` or `./run-discord-ollama.sh`, or use ChumpMenu with repo path set to that root (e.g. `~/Projects/Chump`).

If the bot doesn’t reply: see [DISCORD_TROUBLESHOOTING.md](../operations/DISCORD_TROUBLESHOOTING.md).

## Operator digests (RESILIENT-376 / RESILIENT-1496)

Both digest paths deliver through the **same canonical destination** —
`DISCORD_TOKEN` + `CHUMP_READY_DM_USER_ID` via
`scripts/coord/lib/notify-operator.sh` — not a separate webhook config file:

- `scripts/dispatch/digest-beat.sh` (fired by `chump-digest.timer`, twice daily).
- `scripts/coord/operator-digest.sh --discord-webhook` falls back to the same
  path when `.chump/discord-config.json` doesn't exist (it prefers the webhook
  file only if an operator has explicitly set one up).

`notify_operator` returns 0 both for a real Discord send **and** for
deliberate no-ops (the `CHUMP_OPERATOR_AUTOPOST_DM` kill-switch off, missing
token/user-id, curation-queue defer) — a 0 exit code alone does not mean the
message reached the phone. `digest-beat.sh` distinguishes the two by grepping
notify-operator's own stderr for `delivered`, and emits `kind=chump_digest_posted`
only on a real send, `kind=chump_digest_suppressed` otherwise. Check whether the
organ is actually landing: `bash scripts/coord/digest-delivery-liveness.sh`
(alarms only when `CHUMP_OPERATOR_AUTOPOST_DM` is on but the last cycle was
suppressed — quiet-by-design when the kill-switch is off).
